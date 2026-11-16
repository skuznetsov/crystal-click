#include <algorithm>
#include <array>
#include <bit>
#include <charconv>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <exception>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <memory>
#include <optional>
#include <span>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

#include <Columns/ColumnVector.h>
#include <Common/ErrorCodes.h>
#include <Common/Exception.h>
#include <Common/ThreadStatus.h>
#include <Core/NamesAndTypes.h>
#include <DataTypes/DataTypesNumber.h>
#include <Databases/LoadingStrictnessLevel.h>
#include <IO/SharedThreadPools.h>
#include <Interpreters/Context.h>
#include <Interpreters/StorageID.h>
#include <Parsers/ASTIdentifier.h>
#include <Poco/Util/MapConfiguration.h>
#include <Storages/KeyDescription.h>
#include <Storages/MergeTree/AlterConversions.h>
#include <Storages/MergeTree/IMergeTreeReader.h>
#include <Storages/MergeTree/LoadedMergeTreeDataPartInfoForReader.h>
#include <Storages/MergeTree/MergeTreeIOSettings.h>
#include <Storages/MergeTree/MergeTreeSettings.h>
#include <Storages/StorageInMemoryMetadata.h>
#include <Storages/StorageMergeTree.h>
#include <Storages/StorageSnapshot.h>
#include <IO/ReadHelpers.h>
#include <base/types.h>

namespace fs = std::filesystem;

namespace DB::ErrorCodes
{
extern const int CHECKSUM_DOESNT_MATCH;
}

namespace
{

using Clock = std::chrono::steady_clock;

struct Options
{
    fs::path part;
    std::string layout;
    std::vector<size_t> marks;
    size_t mark_rows = 0;
    size_t workers = 0;
    fs::path oracle;
    fs::path work_dir;
};

[[noreturn]] void fail(const std::string & message)
{
    throw std::runtime_error(message);
}

size_t parseSize(std::string_view value, std::string_view field)
{
    size_t parsed = 0;
    const auto result = std::from_chars(value.data(), value.data() + value.size(), parsed);
    if (value.empty() || result.ec != std::errc{} || result.ptr != value.data() + value.size())
        fail("invalid " + std::string(field) + ": " + std::string(value));
    return parsed;
}

std::vector<size_t> parseMarks(std::string_view value)
{
    std::vector<size_t> result;
    size_t begin = 0;
    while (begin <= value.size())
    {
        const size_t comma = value.find(',', begin);
        const size_t end = comma == std::string_view::npos ? value.size() : comma;
        const std::string_view token = value.substr(begin, end - begin);
        if (token.empty())
            fail("--marks must be a comma-separated list of mark IDs");
        const size_t mark = parseSize(token, "mark ID");
        if (!result.empty() && mark <= result.back())
            fail("--marks must be strictly increasing");
        result.push_back(mark);
        if (comma == std::string_view::npos)
            break;
        begin = comma + 1;
    }
    if (result.empty())
        fail("--marks must contain at least one mark");
    return result;
}

Options parseOptions(int argc, char ** argv)
{
    if (argc != 15)
        fail("usage: clickhouse-read-rows --part PATH --layout wide|compact --marks 0,1,... --mark-rows N --workers 1|4 --oracle PATH --work-dir PATH");

    Options options;
    for (int i = 1; i < argc; i += 2)
    {
        const std::string_view key(argv[i]);
        const std::string_view value(argv[i + 1]);
        if (key == "--part")
            options.part = value;
        else if (key == "--layout")
            options.layout = value;
        else if (key == "--marks")
            options.marks = parseMarks(value);
        else if (key == "--mark-rows")
            options.mark_rows = parseSize(value, "--mark-rows");
        else if (key == "--workers")
            options.workers = parseSize(value, "--workers");
        else if (key == "--oracle")
            options.oracle = value;
        else if (key == "--work-dir")
            options.work_dir = value;
        else
            fail("unknown argument: " + std::string(key));
    }

    if (options.layout != "wide" && options.layout != "compact")
        fail("--layout must be wide or compact");
    if (options.workers != 1 && options.workers != 4)
        fail("--workers must be 1 or 4");
    if (!options.mark_rows)
        fail("--mark-rows must be positive");
    if (options.marks.size() < options.workers)
        fail("--marks must provide at least one mark per worker");
    if (options.part.empty() || options.oracle.empty() || options.work_dir.empty())
        fail("--part, --oracle, and --work-dir must be non-empty paths");

    options.part = fs::canonical(options.part);
    options.oracle = fs::canonical(options.oracle);
    options.work_dir = fs::canonical(options.work_dir);
    if (!fs::is_directory(options.part))
        fail("--part must be a directory");
    if (!fs::is_regular_file(options.oracle))
        fail("--oracle must be a regular file");
    if (!fs::is_directory(options.work_dir))
        fail("--work-dir must be an existing directory");
    if (fs::directory_iterator(options.work_dir) != fs::directory_iterator{})
        fail("--work-dir must be empty at startup");
    return options;
}

std::vector<UInt8> readOracle(const Options & options)
{
    if (options.marks.size() > std::numeric_limits<size_t>::max() / options.mark_rows)
        fail("requested row count overflows size_t");
    const size_t rows = options.marks.size() * options.mark_rows;
    if (rows > std::numeric_limits<size_t>::max() / (2 * sizeof(UInt64)))
        fail("oracle size overflows size_t");
    const size_t bytes = rows * 2 * sizeof(UInt64);
    if (fs::file_size(options.oracle) != bytes)
        fail("oracle byte length does not match requested rows");

    std::vector<UInt8> data(bytes);
    std::ifstream input(options.oracle, std::ios::binary);
    if (!input || !input.read(reinterpret_cast<char *>(data.data()), static_cast<std::streamsize>(data.size())))
        fail("failed to read oracle");
    return data;
}

std::string withTrailingSlash(fs::path path)
{
    std::string value = path.lexically_normal().string();
    if (value.empty() || value.back() != '/')
        value.push_back('/');
    return value;
}

void initializeMergeTreePools()
{
    DB::getActivePartsLoadingThreadPool().initializeWithDefaultSettingsIfNotInitialized();
    DB::getOutdatedPartsLoadingThreadPool().initializeWithDefaultSettingsIfNotInitialized();
    DB::getUnexpectedPartsLoadingThreadPool().initializeWithDefaultSettingsIfNotInitialized();
    DB::getPartsCleaningThreadPool().initializeWithDefaultSettingsIfNotInitialized();
}

struct NativeTable
{
    /// This owns ContextSharedPart; it must outlive every Context below.
    DB::SharedContextHolder shared_context;
    DB::ContextMutablePtr context;
    std::shared_ptr<DB::StorageMergeTree> storage;
    DB::StorageMetadataPtr metadata;
    DB::StorageSnapshotPtr snapshot;
    DB::MergeTreeData::DataPartPtr part;
    DB::MergeTreeSettingsPtr settings;
};

NativeTable loadNativePart(const Options & options)
{
    initializeMergeTreePools();

    const fs::path table_path = options.part.parent_path();
    const fs::path disk_root = table_path.parent_path().parent_path().parent_path();
    if (!fs::is_directory(disk_root / "store"))
        fail("part path does not have the expected native MergeTree table layout");
    const fs::path relative_table_path = fs::relative(table_path, disk_root);
    if (relative_table_path.empty() || relative_table_path.native().starts_with(".."))
        fail("part table path is outside its derived disk root");

    auto shared_context = DB::Context::createShared();
    auto context = DB::Context::createGlobal(shared_context.get());
    context->makeGlobalContext();
    context->setConfig(new Poco::Util::MapConfiguration());
    context->setApplicationType(DB::Context::ApplicationType::LOCAL);
    context->setPath(withTrailingSlash(disk_root));

    const fs::path temporary_path = options.work_dir / "tmp";
    context->setTemporaryStoragePath(withTrailingSlash(temporary_path), 1024ULL * 1024ULL * 1024ULL);

    DB::StorageInMemoryMetadata in_memory_metadata;
    DB::ColumnsDescription columns;
    columns.add(DB::ColumnDescription("pk", std::make_shared<DB::DataTypeUInt64>()));
    columns.add(DB::ColumnDescription("value", std::make_shared<DB::DataTypeUInt64>()));
    in_memory_metadata.setColumns(columns);

    DB::ASTPtr key_ast(new DB::ASTIdentifier("pk"));
    in_memory_metadata.sorting_key = DB::KeyDescription::getKeyFromAST(key_ast, in_memory_metadata.columns, {}, context);
    in_memory_metadata.primary_key = DB::KeyDescription::getKeyFromAST(key_ast->clone(), in_memory_metadata.columns, {}, context);
    in_memory_metadata.partition_key = DB::KeyDescription::getKeyFromAST(nullptr, in_memory_metadata.columns, {}, context);

    const std::string table_uuid_text = table_path.filename().string();
    DB::UUID table_uuid = DB::parseUUID(std::span<const UInt8>(
        reinterpret_cast<const UInt8 *>(table_uuid_text.data()), table_uuid_text.size()));

    auto storage_settings = std::make_unique<DB::MergeTreeSettings>(context->getMergeTreeSettings());
    auto storage = std::make_shared<DB::StorageMergeTree>(
        DB::StorageID("default", "read_rows_fixture", table_uuid),
        withTrailingSlash(relative_table_path),
        in_memory_metadata,
        DB::LoadingStrictnessLevel::ATTACH,
        context,
        /*date_column_name=*/"",
        DB::MergeTreeData::MergingParams{},
        std::move(storage_settings));

    const auto loaded_parts = storage->getDataPartsForInternalUsage();
    if (loaded_parts.size() != 1)
        fail("expected exactly one active native part in the requested table directory");
    const auto & part = *loaded_parts.begin();
    if (part->name != options.part.filename().string())
        fail("loaded part name does not match --part");
    const fs::path loaded_path = fs::canonical(part->getDataPartStorage().getFullPath());
    if (loaded_path != options.part)
        fail("loaded native part path does not match --part");

    const bool part_is_wide = DB::isWidePart(part);
    const bool part_is_compact = DB::isCompactPart(part);
    if ((options.layout == "wide") != part_is_wide || (options.layout == "compact") != part_is_compact)
        fail("--layout does not match the native part type");

    const auto & stored_columns = part->getColumns();
    if (stored_columns.size() != 2)
        fail("native part schema must be exactly pk UInt64, value UInt64 in that order");
    auto column_it = stored_columns.begin();
    if (column_it->name != "pk" || column_it->type->getName() != "UInt64")
        fail("native part schema must be exactly pk UInt64, value UInt64 in that order");
    ++column_it;
    if (column_it->name != "value" || column_it->type->getName() != "UInt64")
        fail("native part schema must be exactly pk UInt64, value UInt64 in that order");

    for (size_t mark : options.marks)
    {
        if (mark >= part->getMarksCount())
            fail("selected mark is outside the native part's positive mark grid");
        if (part->index_granularity->getMarkRows(mark) != options.mark_rows)
            fail("selected mark does not have the requested uniform --mark-rows geometry");
    }

    auto metadata_handle = storage->getInMemoryMetadataPtr(context, false);
    DB::StorageMetadataPtr metadata = metadata_handle;
    auto snapshot = storage->getStorageSnapshot(metadata, context);

    auto settings = storage->getSettings();
    return NativeTable{
        std::move(shared_context), std::move(context), std::move(storage), std::move(metadata),
        std::move(snapshot), part, settings};
}

struct WorkerState
{
    size_t begin = 0;
    size_t end = 0;
    DB::MergeTreeReaderPtr reader;
    std::vector<size_t> processed_marks;
    std::exception_ptr exception;
};

void prepareWorkers(
    std::vector<WorkerState> & workers,
    const Options & options,
    const NativeTable & native_table)
{
    const DB::NamesAndTypesList columns = native_table.part->getColumns();
    for (size_t worker_index = 0; worker_index < options.workers; ++worker_index)
    {
        auto & worker = workers[worker_index];
        worker.begin = options.marks.size() * worker_index / options.workers;
        worker.end = options.marks.size() * (worker_index + 1) / options.workers;
        worker.processed_marks.reserve(worker.end - worker.begin);

        DB::MarkRanges ranges;
        ranges.reserve(worker.end - worker.begin);
        for (size_t selected_index = worker.begin; selected_index < worker.end; ++selected_index)
        {
            const size_t mark = options.marks[selected_index];
            if (!ranges.empty() && ranges.back().end == mark)
                ++ranges.back().end;
            else
                ranges.emplace_back(mark, mark + 1);
        }

        auto part_info = std::make_shared<DB::LoadedMergeTreeDataPartInfoForReader>(
            native_table.part, std::make_shared<DB::AlterConversions>());
        auto reader_settings = DB::MergeTreeReaderSettings::createFromSettings(native_table.context->getReadSettings());
        reader_settings.checksum_on_read = true;
        reader_settings.read_settings.local_fs_settings.method = DB::LocalFSReadMethod::pread;
        reader_settings.read_settings.local_fs_settings.prefetch = false;
        reader_settings.use_deserialization_prefixes_cache = false;
        reader_settings.use_prefixes_deserialization_thread_pool = false;
        reader_settings.use_asynchronous_read_from_pool = false;
        reader_settings.load_marks_asynchronously = false;
        reader_settings.can_read_part_without_marks = false;

        worker.reader = DB::createMergeTreeReader(
            part_info,
            columns,
            native_table.snapshot,
            native_table.settings,
            ranges,
            DB::VirtualFields{},
            /*uncompressed_cache=*/nullptr,
            /*mark_cache=*/nullptr,
            /*deserialization_prefixes_cache=*/nullptr,
            reader_settings,
            DB::ValueSizeMap{},
            DB::ReadBufferFromFileBase::ProfileCallback{});
    }
}

void runWorker(
    WorkerState & worker,
    const Options & options,
    std::vector<UInt64> & ordered_pk,
    std::vector<UInt64> & ordered_values)
{
    DB::MutableColumns columns;
    columns.reserve(2);
    columns.emplace_back(DB::ColumnUInt64::create());
    columns.emplace_back(DB::ColumnUInt64::create());
    columns[0]->reserve(options.mark_rows);
    columns[1]->reserve(options.mark_rows);

    for (size_t selected_index = worker.begin; selected_index < worker.end; ++selected_index)
    {
        const size_t mark = options.marks[selected_index];
        const bool continue_reading = selected_index > worker.begin
            && options.marks[selected_index - 1] + 1 == mark;
        const size_t rows_read = worker.reader->readRows(mark, continue_reading, options.mark_rows, columns);
        if (rows_read != options.mark_rows)
            fail("readRows returned a partial mark");

        if (!columns[0] || !columns[1])
            fail("readRows invalidated a requested UInt64 column");
        const auto & pk_column = assert_cast<const DB::ColumnUInt64 &>(*columns[0]);
        const auto & value_column = assert_cast<const DB::ColumnUInt64 &>(*columns[1]);
        const size_t current_rows = pk_column.size();
        if (current_rows != options.mark_rows || value_column.size() != current_rows)
            fail("readRows materialized an unexpected number of UInt64 values");

        const size_t destination_offset = selected_index * options.mark_rows;
        const size_t copy_bytes = options.mark_rows * sizeof(UInt64);
        std::memcpy(ordered_pk.data() + destination_offset, pk_column.getData().data(), copy_bytes);
        std::memcpy(ordered_values.data() + destination_offset, value_column.getData().data(), copy_bytes);
        columns[0]->popBack(current_rows);
        columns[1]->popBack(current_rows);
        worker.processed_marks.push_back(mark);
    }

    worker.reader.reset();
}

void scanOnce(
    const Options & options,
    const NativeTable & native_table,
    const std::vector<UInt8> & oracle,
    std::vector<UInt64> & ordered_pk,
    std::vector<UInt64> & ordered_values)
{
    const auto prepare_started = Clock::now();
    std::vector<WorkerState> workers(options.workers);
    prepareWorkers(workers, options, native_table);
    const UInt64 prepare_ns = static_cast<UInt64>(std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - prepare_started).count());

    const auto elapsed_started = Clock::now();
    if (options.workers == 1)
    {
        runWorker(workers[0], options, ordered_pk, ordered_values);
    }
    else
    {
        std::vector<std::jthread> threads;
        threads.reserve(options.workers);
        for (size_t worker_index = 0; worker_index < options.workers; ++worker_index)
        {
            threads.emplace_back([&, worker_index]
            {
                try
                {
                    DB::ThreadStatus thread_status;
                    runWorker(workers[worker_index], options, ordered_pk, ordered_values);
                }
                catch (...)
                {
                    workers[worker_index].exception = std::current_exception();
                }
            });
        }
        for (auto & thread : threads)
            thread.join();
        for (const auto & worker : workers)
            if (worker.exception)
                std::rethrow_exception(worker.exception);
    }
    UInt64 elapsed_ns = static_cast<UInt64>(std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - elapsed_started).count());
    if (elapsed_ns == 0)
        elapsed_ns = 1;

    const size_t rows = ordered_pk.size();
    const size_t column_bytes = rows * sizeof(UInt64);
    if (std::memcmp(ordered_pk.data(), oracle.data(), column_bytes) != 0
        || std::memcmp(ordered_values.data(), oracle.data() + column_bytes, column_bytes) != 0)
        fail("materialized result differs bytewise from the native oracle");

    std::cout << "{\"prepare_ns\":" << prepare_ns
              << ",\"elapsed_ns\":" << elapsed_ns
              << ",\"rows\":" << rows
              << ",\"effective_workers\":" << options.workers
              << ",\"worker_marks\":[";
    for (size_t worker_index = 0; worker_index < workers.size(); ++worker_index)
    {
        if (worker_index)
            std::cout << ',';
        std::cout << '[';
        const auto & marks = workers[worker_index].processed_marks;
        for (size_t i = 0; i < marks.size(); ++i)
        {
            if (i)
                std::cout << ',';
            std::cout << marks[i];
        }
        std::cout << ']';
    }
    std::cout << "],\"checksum_on_read\":true}\n" << std::flush;
}

int run(const Options & options)
{
    static_assert(std::endian::native == std::endian::little, "the oracle protocol uses little-endian UInt64 arrays");
    const std::vector<UInt8> oracle = readOracle(options);
    const size_t rows = options.marks.size() * options.mark_rows;
    std::vector<UInt64> ordered_pk(rows);
    std::vector<UInt64> ordered_values(rows);
    {
        NativeTable native_table = loadNativePart(options);

        std::cout << "READY\n" << std::flush;
        std::string command;
        while (std::getline(std::cin, command))
        {
            if (command == "quit")
                break;
            if (command != "scan")
                fail("stdin command must be scan or quit");
            scanOnce(options, native_table, oracle, ordered_pk, ordered_values);
        }

        native_table.storage->flushAndShutdown();
    }

    std::error_code remove_error;
    fs::remove_all(options.work_dir / "tmp", remove_error);
    if (remove_error)
        std::cerr << "temporary directory cleanup failed: " << remove_error.message() << '\n';
    return 0;
}

} // namespace

int main(int argc, char ** argv)
{
    try
    {
        DB::MainThreadStatus::getInstance();
        Options options = parseOptions(argc, argv);
        return run(options);
    }
    catch (const DB::Exception & exception)
    {
        if (exception.code() == DB::ErrorCodes::CHECKSUM_DOESNT_MATCH)
        {
            std::cerr << "checksum mismatch: " << exception.displayText() << '\n';
            return 3;
        }
        std::cerr << exception.displayText() << '\n';
        return 1;
    }
    catch (const std::exception & exception)
    {
        std::cerr << exception.what() << '\n';
        return 1;
    }
}
