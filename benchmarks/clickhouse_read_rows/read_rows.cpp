#include <algorithm>
#include <array>
#include <bit>
#include <charconv>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <exception>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <iterator>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <span>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

#include "NativeReadAllocations.h"

#ifdef CLICKHOUSE_READ_ROWS_PROFILE
#include <ReadRowsProfile.h>
#endif

#include <Columns/ColumnVector.h>
#include <Common/ErrorCodes.h>
#include <Common/Exception.h>
#include <Common/ThreadStatus.h>
#include <Core/NamesAndTypes.h>
#include <DataTypes/DataTypeArray.h>
#include <DataTypes/DataTypeMap.h>
#include <DataTypes/DataTypeNullable.h>
#include <DataTypes/DataTypeObject.h>
#include <DataTypes/DataTypeString.h>
#include <DataTypes/DataTypeTuple.h>
#include <DataTypes/DataTypesNumber.h>
#include <Databases/LoadingStrictnessLevel.h>
#include <IO/SharedThreadPools.h>
#include <Interpreters/Context.h>
#include <Interpreters/StorageID.h>
#include <Formats/FormatFactory.h>
#include <Functions/registerFunctions.h>
#include <IO/WriteBufferFromString.h>
#include <IO/WriteHelpers.h>
#include <Parsers/ASTFunction.h>
#include <Parsers/ASTIdentifier.h>
#include <Parsers/ASTLiteral.h>
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
    std::string schema = "uint64";
    std::vector<size_t> marks;
    size_t mark_rows = 0;
    size_t workers = 0;
    fs::path oracle;
    fs::path work_dir;
    bool native_read_allocations = false;
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
    if (value.empty())
        return result;
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
    if (argc != 15 && argc != 17 && argc != 19)
        fail("usage: clickhouse-read-rows --part PATH --layout wide|compact --marks 0,1,... --mark-rows N --workers 1|4 --oracle PATH --work-dir PATH [--schema uint64|json] [--native-read-allocations 1]");

    Options options;
    for (int i = 1; i < argc; i += 2)
    {
        const std::string_view key(argv[i]);
        const std::string_view value(argv[i + 1]);
        if (key == "--part")
            options.part = value;
        else if (key == "--layout")
            options.layout = value;
        else if (key == "--schema")
            options.schema = value;
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
        else if (key == "--native-read-allocations" && value == "1")
            options.native_read_allocations = true;
        else
            fail("unknown argument: " + std::string(key));
    }

    if (options.layout != "wide" && options.layout != "compact")
        fail("--layout must be wide or compact");
    if (options.schema != "uint64" && options.schema != "json")
        fail("--schema must be uint64 or json");
    if (options.schema == "json" && options.layout != "compact")
        fail("--schema json requires --layout compact");
    if (options.native_read_allocations && options.schema != "json")
        fail("--native-read-allocations requires --schema json");
    if (options.workers != 1 && options.workers != 4)
        fail("--workers must be 1 or 4");
    if (!options.mark_rows)
        fail("--mark-rows must be positive");
    if (options.schema == "uint64" && options.marks.empty())
        fail("--marks must contain at least one mark for --schema uint64");
    if (!options.marks.empty() && options.marks.size() < options.workers)
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
    const uintmax_t file_bytes = fs::file_size(options.oracle);
    if (file_bytes > static_cast<uintmax_t>(std::numeric_limits<std::streamsize>::max()))
        fail("oracle is too large to read");
    const size_t bytes = static_cast<size_t>(file_bytes);
    if (static_cast<uintmax_t>(bytes) != file_bytes)
        fail("oracle is too large for this platform");
    if (options.schema == "uint64")
    {
        if (options.marks.size() > std::numeric_limits<size_t>::max() / options.mark_rows)
            fail("requested row count overflows size_t");
        const size_t rows = options.marks.size() * options.mark_rows;
        if (rows > std::numeric_limits<size_t>::max() / (2 * sizeof(UInt64)))
            fail("oracle size overflows size_t");
        if (bytes != rows * 2 * sizeof(UInt64))
            fail("oracle byte length does not match requested rows");
    }

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

DB::DataTypePtr makeFixtureJsonDocType()
{
    std::unordered_map<DB::String, DB::DataTypePtr> typed_paths;
    typed_paths.emplace("rank", std::make_shared<DB::DataTypeNullable>(std::make_shared<DB::DataTypeUInt32>()));
    typed_paths.emplace("tenant_id", std::make_shared<DB::DataTypeUInt32>());
    typed_paths.emplace("title", std::make_shared<DB::DataTypeString>());
    return std::make_shared<DB::DataTypeObject>(
        DB::DataTypeObject::SchemaFormat::JSON,
        std::move(typed_paths),
        std::unordered_set<DB::String>{},
        std::vector<DB::String>{},
        /*max_dynamic_paths=*/4,
        /*max_dynamic_types=*/2);
}

DB::DataTypePtr makeFixtureEventsType()
{
    auto tuple = std::make_shared<DB::DataTypeTuple>(
        DB::DataTypes{std::make_shared<DB::DataTypeUInt64>(), std::make_shared<DB::DataTypeString>()},
        DB::Strings{"a", "b"});
    return std::make_shared<DB::DataTypeArray>(tuple);
}

DB::DataTypePtr makeFixtureAttrsType()
{
    auto nullable_u64 = std::make_shared<DB::DataTypeNullable>(std::make_shared<DB::DataTypeUInt64>());
    return std::make_shared<DB::DataTypeMap>(
        std::make_shared<DB::DataTypeString>(),
        std::make_shared<DB::DataTypeArray>(nullable_u64));
}

DB::DataTypePtr getStoredDocType(const DB::MergeTreeData::DataPartPtr & part)
{
    const auto stored_columns = part->getColumns();
    auto it = stored_columns.begin();
    if (it == stored_columns.end())
        fail("native JSON part has no id column");
    ++it;
    if (it == stored_columns.end())
        fail("native JSON part has no doc column");
    return it->type;
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
    const std::string key_column = options.schema == "json" ? "id" : "pk";
    columns.add(DB::ColumnDescription(key_column, std::make_shared<DB::DataTypeUInt64>()));
    if (options.schema == "json")
    {
        columns.add(DB::ColumnDescription("doc", makeFixtureJsonDocType()));
        columns.add(DB::ColumnDescription("events", makeFixtureEventsType()));
        columns.add(DB::ColumnDescription("attrs", makeFixtureAttrsType()));
    }
    else
        columns.add(DB::ColumnDescription("value", std::make_shared<DB::DataTypeUInt64>()));
    in_memory_metadata.setColumns(columns);

    DB::ASTPtr key_ast(new DB::ASTIdentifier(key_column));
    in_memory_metadata.sorting_key = DB::KeyDescription::getKeyFromAST(key_ast, in_memory_metadata.columns, {}, context);
    in_memory_metadata.primary_key = DB::KeyDescription::getKeyFromAST(key_ast->clone(), in_memory_metadata.columns, {}, context);
    if (options.schema == "json")
    {
        /// Reproduce the Compact fixture's PARTITION BY expression so ATTACH
        /// validates the on-disk partition ID against its actual metadata.
        DB::registerFunctions();
        auto partition_ast = DB::makeASTFunction(
            "intDiv",
            DB::make_intrusive<DB::ASTIdentifier>("id"),
            DB::make_intrusive<DB::ASTLiteral>(UInt64(8192)));
        in_memory_metadata.partition_key = DB::KeyDescription::getKeyFromAST(
            partition_ast,
            in_memory_metadata.columns,
            DB::MergeTreeData::createVirtuals(nullptr),
            context);
    }
    else
        in_memory_metadata.partition_key = DB::KeyDescription::getKeyFromAST(nullptr, in_memory_metadata.columns, {}, context);
    in_memory_metadata.virtuals = DB::MergeTreeData::createVirtuals(
        in_memory_metadata.partition_key.sample_block.columns() ? &in_memory_metadata.partition_key : nullptr);

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
    if (options.schema == "uint64" && loaded_parts.size() != 1)
        fail("expected exactly one active native part in the requested table directory");

    DB::MergeTreeData::DataPartPtr selected_part;
    size_t selected_part_count = 0;
    for (const auto & candidate : loaded_parts)
    {
        if (candidate->name != options.part.filename().string())
            continue;
        const fs::path candidate_path = fs::canonical(candidate->getDataPartStorage().getFullPath());
        if (candidate_path == options.part)
        {
            selected_part = candidate;
            ++selected_part_count;
        }
    }
    if (selected_part_count != 1)
    {
        std::ostringstream message;
        message << "expected exactly one active native part matching --part path and name (loaded="
                << loaded_parts.size() << ", matching=" << selected_part_count << ')';
        for (const auto & candidate : loaded_parts)
            message << "\nloaded " << candidate->name << " at " << candidate->getDataPartStorage().getFullPath();
        fail(message.str());
    }
    const auto & part = selected_part;

    const bool part_is_wide = DB::isWidePart(part);
    const bool part_is_compact = DB::isCompactPart(part);
    if ((options.layout == "wide") != part_is_wide || (options.layout == "compact") != part_is_compact)
        fail("--layout does not match the native part type");
    if (options.schema == "json" && part->getMarksFileExtension() != ".mrk4" && part->getMarksFileExtension() != ".cmrk4")
        fail("--schema json requires Advanced Compact MRK4 marks");

    const auto & stored_columns = part->getColumns();
    const size_t expected_physical_columns = options.schema == "json" ? 4 : 2;
    if (stored_columns.size() != expected_physical_columns)
        fail(options.schema == "json"
            ? "native JSON fixture must contain its four stored columns: id, doc, events, attrs"
            : "native part schema must contain exactly two columns");
    auto column_it = stored_columns.begin();
    if (options.schema == "json")
    {
        if (column_it->name != "id" || !column_it->type->equals(DB::DataTypeUInt64()))
            fail("native JSON part must start with id UInt64, doc JSON, events, attrs");
        ++column_it;
        const DB::DataTypePtr expected_doc_type = makeFixtureJsonDocType();
        if (column_it->name != "doc" || !column_it->type->equals(*expected_doc_type)
            || column_it->type->getName() != expected_doc_type->getName())
            fail("native doc column type does not match the fixture's JSON schema and typed paths");
        ++column_it;
        const DB::DataTypePtr expected_events_type = makeFixtureEventsType();
        if (column_it->name != "events" || !column_it->type->equals(*expected_events_type))
            fail("native events column type does not match the fixture metadata");
        ++column_it;
        const DB::DataTypePtr expected_attrs_type = makeFixtureAttrsType();
        if (column_it->name != "attrs" || !column_it->type->equals(*expected_attrs_type))
            fail("native attrs column type does not match the fixture metadata");
        ++column_it;
        if (column_it != stored_columns.end())
            fail("native JSON fixture contains unexpected physical columns");
    }
    else
    {
        if (column_it->name != "pk" || column_it->type->getName() != "UInt64")
            fail("native part schema must be exactly pk UInt64, value UInt64 in that order");
        ++column_it;
        if (column_it->name != "value" || column_it->type->getName() != "UInt64")
            fail("native part schema must be exactly pk UInt64, value UInt64 in that order");
    }

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

std::vector<UInt8> selectJsonOracleRows(
    const Options & options,
    const std::vector<UInt8> & oracle,
    const DB::MergeTreeData::DataPartPtr & part)
{
    std::vector<std::pair<size_t, size_t>> row_ranges;
    size_t offset = 0;
    while (offset < oracle.size())
    {
        const size_t row_begin = offset;
        if (oracle.size() - offset < sizeof(UInt64))
            fail("RowBinary JSON oracle ends inside a UInt64 id");
        offset += sizeof(UInt64);

        UInt64 string_size = 0;
        unsigned shift = 0;
        bool decoded = false;
        for (size_t byte_index = 0; byte_index < 10; ++byte_index)
        {
            if (offset == oracle.size())
                fail("RowBinary JSON oracle ends inside a String length");
            const UInt8 byte = oracle[offset++];
            const UInt8 payload = byte & 0x7f;
            if (shift == 63 && payload > 1)
                fail("RowBinary JSON oracle contains an overflowing String length");
            string_size |= static_cast<UInt64>(payload) << shift;
            if ((byte & 0x80) == 0)
            {
                decoded = true;
                break;
            }
            shift += 7;
        }
        if (!decoded)
            fail("RowBinary JSON oracle contains an unterminated String length");
        if (string_size > oracle.size() - offset)
            fail("RowBinary JSON oracle ends inside a String value");
        offset += static_cast<size_t>(string_size);
        row_ranges.emplace_back(row_begin, offset);
    }

    if (options.marks.size() > std::numeric_limits<size_t>::max() / options.mark_rows)
        fail("requested JSON row count overflows size_t");
    const size_t selected_rows = options.marks.size() * options.mark_rows;
    if (row_ranges.size() == selected_rows)
        return oracle;
    if (row_ranges.size() != part->rows_count)
        fail("RowBinary JSON oracle row count matches neither the selected rows nor the native part");

    std::vector<UInt8> selected;
    for (size_t mark : options.marks)
    {
        const size_t first_row = part->index_granularity->getMarkStartingRow(mark);
        if (first_row > row_ranges.size() || options.mark_rows > row_ranges.size() - first_row)
            fail("selected mark rows are outside the RowBinary JSON oracle");
        const size_t first_byte = row_ranges[first_row].first;
        const size_t last_byte = row_ranges[first_row + options.mark_rows - 1].second;
        if (last_byte - first_byte > std::numeric_limits<size_t>::max() - selected.size())
            fail("selected RowBinary JSON oracle size overflows size_t");
        selected.insert(selected.end(), oracle.begin() + first_byte, oracle.begin() + last_byte);
    }
    return selected;
}

struct WorkerState
{
    size_t begin = 0;
    size_t end = 0;
    std::thread::id native_thread_id;
    DB::MergeTreeReaderPtr reader;
    std::vector<size_t> processed_marks;
    std::exception_ptr exception;
#ifdef CLICKHOUSE_READ_ROWS_PROFILE
    DB::ReadRowsProfile::WorkerCounters profile;
#endif
};

#ifdef CLICKHOUSE_READ_ROWS_PROFILE
void copyToOrderedOutput(UInt64 * destination, const UInt64 * source, size_t bytes)
{
    DB::ReadRowsProfile::Timer timer(DB::ReadRowsProfile::Operation::OutputCopy);
    std::memcpy(destination, source, bytes);
    timer.finish();
    DB::ReadRowsProfile::addOutputCopyBytes(bytes);
}
#endif

void prepareWorkers(
    std::vector<WorkerState> & workers,
    const Options & options,
    const NativeTable & native_table)
{
    const DB::NamesAndTypesList stored_columns = native_table.part->getColumns();
    DB::NamesAndTypesList columns = stored_columns;
    if (options.schema == "json")
        columns = DB::NamesAndTypesList(stored_columns.begin(), std::next(stored_columns.begin(), 2));
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

class JsonWorkerPool
{
public:
    JsonWorkerPool(const Options & options_, const NativeTable & native_table_, std::vector<WorkerState> & workers_)
        : options(options_), native_table(native_table_), workers(workers_), materialized(options_.marks.size())
    {
        if (!options.marks.empty())
        {
            const auto stored_columns = native_table.part->getColumns();
            requested_columns = DB::NamesAndTypesList(stored_columns.begin(), std::next(stored_columns.begin(), 2));
            for (auto & mark_columns : materialized)
            {
                mark_columns.reserve(requested_columns.size());
                for (const auto & stored_column : requested_columns)
                {
                    mark_columns.emplace_back(stored_column.type->createColumn());
                    mark_columns.back()->reserve(options.mark_rows);
                }
            }
        }

        threads.reserve(workers.size());
        try
        {
            for (size_t worker_index = 0; worker_index < workers.size(); ++worker_index)
                threads.emplace_back([this, worker_index] { workerLoop(worker_index); });
            if (!workers.empty())
            {
                std::unique_lock lock(mutex);
                workers_started.wait(lock, [this] { return started_workers == workers.size(); });
            }
            native_thread_ids.reserve(workers.size());
            for (const auto & worker : workers)
                native_thread_ids.push_back(worker.native_thread_id);
        }
        catch (...)
        {
            stop();
            throw;
        }
    }

    JsonWorkerPool(const JsonWorkerPool &) = delete;
    JsonWorkerPool & operator=(const JsonWorkerPool &) = delete;

    ~JsonWorkerPool()
    {
        stop();
    }

    UInt64 read()
    {
        if (workers.empty())
            return 0;

        for (auto & worker : workers)
        {
            worker.processed_marks.clear();
            worker.exception = nullptr;
#ifdef CLICKHOUSE_READ_ROWS_PROFILE
            worker.profile = {};
#endif
        }

        const auto started = Clock::now();
        {
            std::lock_guard lock(mutex);
            completed_workers = 0;
#ifdef CLICKHOUSE_READ_ROWS_PROFILE
            current_scan_started = started;
#endif
            ++work_generation;
        }
        work_available.notify_all();

        {
            std::unique_lock lock(mutex);
            work_complete.wait(lock, [this] { return completed_workers == workers.size(); });
        }
        const UInt64 elapsed_ns = static_cast<UInt64>(
            std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - started).count());
        for (const auto & worker : workers)
        {
            if (worker.exception)
                std::rethrow_exception(worker.exception);
            if (worker.processed_marks.size() != worker.end - worker.begin)
                fail("JSON reader processed an unexpected number of marks");
            for (size_t offset = 0; offset < worker.processed_marks.size(); ++offset)
                if (worker.processed_marks[offset] != options.marks[worker.begin + offset])
                    fail("JSON reader processed a mark outside its assigned schedule");
        }
        for (size_t worker_index = 0; worker_index < workers.size(); ++worker_index)
            if (workers[worker_index].native_thread_id != native_thread_ids[worker_index])
                fail("JSON reader worker thread identity changed between scans");
        return elapsed_ns ? elapsed_ns : 1;
    }

    const std::vector<DB::MutableColumns> & getMaterialized() const
    {
        return materialized;
    }

    const std::vector<WorkerState> & getWorkers() const
    {
        return workers;
    }

    size_t effectiveWorkerCount() const
    {
        size_t count = 0;
        for (const auto & worker : workers)
            count += worker.begin < worker.end;
        return count;
    }

    void clearMaterialized()
    {
        for (auto & columns : materialized)
            for (auto & column : columns)
                if (column && column->size())
                    column->popBack(column->size());
    }

private:
    void workerLoop(size_t worker_index)
    {
        DB::ThreadStatus thread_status;
        {
            std::lock_guard lock(mutex);
            workers[worker_index].native_thread_id = std::this_thread::get_id();
            ++started_workers;
        }
        workers_started.notify_one();
        size_t observed_generation = 0;
        while (true)
        {
#ifdef CLICKHOUSE_READ_ROWS_PROFILE
            Clock::time_point scan_started;
#endif
            {
                std::unique_lock lock(mutex);
                work_available.wait(lock, [this, observed_generation]
                {
                    return stopping || work_generation != observed_generation;
                });
                if (stopping)
                    return;
                observed_generation = work_generation;
#ifdef CLICKHOUSE_READ_ROWS_PROFILE
                scan_started = current_scan_started;
#endif
            }

            {
#ifdef CLICKHOUSE_READ_ROWS_PROFILE
                auto & worker = workers[worker_index];
                DB::ReadRowsProfile::WorkerScope profile_scope(worker.profile, scan_started);
#else
                auto & worker = workers[worker_index];
#endif
                try
                {
                    for (size_t selected_index = worker.begin; selected_index < worker.end; ++selected_index)
                    {
                        const size_t mark = options.marks[selected_index];
                        const bool continue_reading = selected_index > worker.begin
                            && options.marks[selected_index - 1] + 1 == mark;
                        auto & columns = materialized[selected_index];
                        const size_t rows_read = worker.reader->readRows(mark, continue_reading, options.mark_rows, columns);
                        if (rows_read != options.mark_rows)
                            fail("readRows returned a partial JSON mark");
                        if (columns.size() != 2 || !columns[0] || !columns[1])
                            fail("readRows invalidated a requested JSON column");
                        if (columns[0]->size() != options.mark_rows || columns[1]->size() != options.mark_rows)
                            fail("readRows materialized an unexpected number of JSON rows");

                        worker.processed_marks.push_back(mark);
                    }
                }
                catch (...)
                {
                    worker.exception = std::current_exception();
                }
            }

            {
                std::lock_guard lock(mutex);
                ++completed_workers;
            }
            work_complete.notify_one();
        }
    }

    void stop()
    {
        {
            std::lock_guard lock(mutex);
            stopping = true;
        }
        work_available.notify_all();
        for (auto & thread : threads)
            if (thread.joinable())
                thread.join();
        threads.clear();
    }

    const Options & options;
    const NativeTable & native_table;
    std::vector<WorkerState> & workers;
    DB::NamesAndTypesList requested_columns;
    std::vector<DB::MutableColumns> materialized;
    std::vector<std::thread> threads;
    std::vector<std::thread::id> native_thread_ids;
    std::mutex mutex;
    std::condition_variable work_available;
    std::condition_variable work_complete;
    std::condition_variable workers_started;
    size_t work_generation = 0;
    size_t completed_workers = 0;
    size_t started_workers = 0;
#ifdef CLICKHOUSE_READ_ROWS_PROFILE
    Clock::time_point current_scan_started{};
#endif
    bool stopping = false;
};

UInt64 elapsedNanoseconds(Clock::time_point started)
{
    const UInt64 elapsed = static_cast<UInt64>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - started).count());
    return elapsed ? elapsed : 1;
}

struct JsonMaterializer
{
    DB::SerializationPtr doc_serializer;
    DB::FormatSettings format_settings;

    explicit JsonMaterializer(const NativeTable & native_table)
        : doc_serializer(getStoredDocType(native_table.part)->getDefaultSerialization())
        , format_settings(DB::getFormatSettings(native_table.context))
    {
    }
};

std::string materializeJsonRowBinary(
    const Options & options,
    const std::vector<DB::MutableColumns> & columns_by_mark,
    const JsonMaterializer & materializer)
{
    std::string rowbinary;
    DB::WriteBufferFromString output(rowbinary);
    for (size_t selected_index = 0; selected_index < options.marks.size(); ++selected_index)
    {
        const auto & columns = columns_by_mark[selected_index];
        if (columns.size() != 2 || !columns[0] || !columns[1])
            fail("JSON mark output is missing a column");
        const auto & ids = assert_cast<const DB::ColumnUInt64 &>(*columns[0]);
        if (ids.size() != options.mark_rows || columns[1]->size() != options.mark_rows)
            fail("JSON mark output has an unexpected row count");

        for (size_t row = 0; row < options.mark_rows; ++row)
        {
            DB::writeBinary(ids.getData()[row], output);
            DB::WriteBufferFromOwnString json;
            materializer.doc_serializer->serializeTextJSON(*columns[1], row, json, materializer.format_settings);
            DB::writeStringBinary(json.stringView(), output);
        }
    }
    output.finalize();
    return rowbinary;
}

void exportRowBinary(const fs::path & path, std::string_view bytes)
{
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    if (!output || !output.write(bytes.data(), static_cast<std::streamsize>(bytes.size())))
        fail("failed to export materialized RowBinary bytes");
    output.close();
    if (!output)
        fail("failed to close exported RowBinary bytes");
}

void scanJsonOnce(
    const Options & options,
    JsonWorkerPool & worker_pool,
    const JsonMaterializer & materializer,
    const std::vector<UInt8> & expected_oracle,
    const NativeReadAllocations & allocations,
    UInt64 load_part_ns,
    UInt64 prepare_ns,
    bool & rowbinary_exported)
{
    const auto before = allocations.snapshot();
    const UInt64 read_ns = worker_pool.read();
    const auto after = allocations.snapshot();
    const auto materialize_started = Clock::now();
    const std::string rowbinary = materializeJsonRowBinary(
        options, worker_pool.getMaterialized(), materializer);
    const UInt64 materialize_ns = elapsedNanoseconds(materialize_started);
    const auto reset_started = Clock::now();
    worker_pool.clearMaterialized();
    const UInt64 reset_ns = elapsedNanoseconds(reset_started);

    if (rowbinary.size() != expected_oracle.size()
        || (!rowbinary.empty() && std::memcmp(rowbinary.data(), expected_oracle.data(), rowbinary.size()) != 0))
        fail("materialized RowBinary id,toJSONString(doc) differs bytewise from the native oracle");

    if (!rowbinary_exported)
    {
        exportRowBinary(options.work_dir / "rowbinary.bin", rowbinary);
        rowbinary_exported = true;
    }
    const size_t rows = options.marks.size() * options.mark_rows;
    std::cout << "{\"load_part_ns\":" << load_part_ns
              << ",\"prepare_ns\":" << prepare_ns
              << ",\"read_ns\":" << read_ns
              << ",\"materialize_ns\":" << materialize_ns
              << ",\"reset_ns\":" << reset_ns
              << ",\"rows\":" << rows
              << ",\"effective_workers\":" << worker_pool.effectiveWorkerCount()
              << ",\"worker_marks\":[";
    bool first_worker = true;
    for (const auto & worker : worker_pool.getWorkers())
    {
        if (worker.begin == worker.end)
            continue;
        if (!first_worker)
            std::cout << ',';
        first_worker = false;
        std::cout << '[';
        for (size_t mark_index = 0; mark_index < worker.processed_marks.size(); ++mark_index)
        {
            if (mark_index)
                std::cout << ',';
            std::cout << worker.processed_marks[mark_index];
        }
        std::cout << ']';
    }
    std::cout << "],\"checksum_on_read_policy\":"
              << (options.marks.empty() ? "\"not_applicable_empty_schedule\"" : "\"enabled\"")
              << ",\"rowbinary_bytes\":" << rowbinary.size()
              << ",\"worker_thread_ids\":[";
    bool first_thread_id = true;
    for (const auto & worker : worker_pool.getWorkers())
    {
        if (worker.begin == worker.end)
            continue;
        if (!first_thread_id)
            std::cout << ',';
        first_thread_id = false;
        std::cout << std::hash<std::thread::id>{}(worker.native_thread_id);
    }
    std::cout << ']';
    if (options.native_read_allocations)
        std::cout << ",\"native_read_allocation_requests\":" << after.requests - before.requests
                  << ",\"native_read_requested_bytes\":" << after.bytes - before.bytes;
#ifdef CLICKHOUSE_READ_ROWS_PROFILE
    std::cout << ",\"profile\":{\"version\":1,\"checksum_semantics\":\"actual_CityHash128_calls\",\"workers\":[";
    bool first_profile_worker = true;
    for (size_t worker_index = 0; worker_index < worker_pool.getWorkers().size(); ++worker_index)
    {
        const auto & worker = worker_pool.getWorkers()[worker_index];
        if (worker.begin == worker.end)
            continue;
        if (!first_profile_worker)
            std::cout << ',';
        first_profile_worker = false;
        std::cout << "{\"index\":" << worker_index
                  << ",\"checksum_ns\":" << worker.profile.checksum_ns
                  << ",\"checksum_calls\":" << worker.profile.checksum_calls
                  << ",\"lz4_ns\":" << worker.profile.lz4_ns
                  << ",\"lz4_calls\":" << worker.profile.lz4_calls
                  << ",\"transport_calls\":" << worker.profile.transport_calls
                  << ",\"transport_bytes\":" << worker.profile.transport_bytes << '}';
    }
    std::cout << "]}";
#endif
    std::cout << ",\"rowbinary_file\":\"rowbinary.bin\"}\n" << std::flush;
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
#ifdef CLICKHOUSE_READ_ROWS_PROFILE
        copyToOrderedOutput(ordered_pk.data() + destination_offset, pk_column.getData().data(), copy_bytes);
        copyToOrderedOutput(ordered_values.data() + destination_offset, value_column.getData().data(), copy_bytes);
#else
        std::memcpy(ordered_pk.data() + destination_offset, pk_column.getData().data(), copy_bytes);
        std::memcpy(ordered_values.data() + destination_offset, value_column.getData().data(), copy_bytes);
#endif
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
#ifdef CLICKHOUSE_READ_ROWS_PROFILE
    UInt64 launch_ns = 0;
    UInt64 join_ns = 0;
#endif
    if (options.workers == 1)
    {
#ifdef CLICKHOUSE_READ_ROWS_PROFILE
        DB::ReadRowsProfile::WorkerScope worker_scope(workers[0].profile, elapsed_started);
#endif
        runWorker(workers[0], options, ordered_pk, ordered_values);
    }
    else
    {
#ifdef CLICKHOUSE_READ_ROWS_PROFILE
        const auto launch_started = Clock::now();
#endif
        std::vector<std::jthread> threads;
        threads.reserve(options.workers);
        for (size_t worker_index = 0; worker_index < options.workers; ++worker_index)
        {
            threads.emplace_back([&, worker_index]
            {
#ifdef CLICKHOUSE_READ_ROWS_PROFILE
                DB::ReadRowsProfile::WorkerScope worker_scope(workers[worker_index].profile, elapsed_started);
#endif
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
#ifdef CLICKHOUSE_READ_ROWS_PROFILE
        launch_ns = static_cast<UInt64>(std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - launch_started).count());
        const auto join_started = Clock::now();
#endif
        for (auto & thread : threads)
            thread.join();
#ifdef CLICKHOUSE_READ_ROWS_PROFILE
        join_ns = static_cast<UInt64>(std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - join_started).count());
#endif
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
    std::cout << "],\"checksum_on_read\":true";
#ifdef CLICKHOUSE_READ_ROWS_PROFILE
    std::cout << ",\"profile\":{\"version\":1,\"transport_kind\":\"pread\",\"launch_ns\":" << launch_ns
              << ",\"join_ns\":" << join_ns << ",\"workers\":[";
    for (size_t worker_index = 0; worker_index < workers.size(); ++worker_index)
    {
        if (worker_index)
            std::cout << ',';
        const auto & profile = workers[worker_index].profile;
        const UInt64 io_lifecycle_ns = profile.open_ns + profile.fstat_ns + profile.close_ns;
        std::cout << "{\"index\":" << worker_index
                  << ",\"start_ns\":" << profile.start_ns
                  << ",\"end_ns\":" << profile.end_ns
                  << ",\"transport_ns\":" << profile.transport_ns
                  << ",\"transport_calls\":" << profile.transport_calls
                  << ",\"transport_bytes\":" << profile.transport_bytes
                  << ",\"checksum_ns\":" << profile.checksum_ns
                  << ",\"checksum_calls\":" << profile.checksum_calls
                  << ",\"lz4_ns\":" << profile.lz4_ns
                  << ",\"lz4_calls\":" << profile.lz4_calls
                  << ",\"materialize_copy_ns\":" << profile.materialize_copy_ns
                  << ",\"materialize_copy_calls\":" << profile.materialize_copy_calls
                  << ",\"materialize_copy_bytes\":" << profile.materialize_copy_bytes
                  << ",\"direct_decode_calls\":" << profile.direct_decode_calls
                  << ",\"direct_decode_bytes\":" << profile.direct_decode_bytes
                  << ",\"output_copy_ns\":" << profile.output_copy_ns
                  << ",\"output_copy_calls\":" << profile.output_copy_calls
                  << ",\"output_copy_bytes\":" << profile.output_copy_bytes
                  << ",\"io_lifecycle_ns\":" << io_lifecycle_ns
                  << ",\"open_ns\":" << profile.open_ns
                  << ",\"open_calls\":" << profile.open_calls
                  << ",\"fstat_ns\":" << profile.fstat_ns
                  << ",\"fstat_calls\":" << profile.fstat_calls
                  << ",\"close_ns\":" << profile.close_ns
                  << ",\"close_calls\":" << profile.close_calls << '}';
    }
    std::cout << "]}";
#endif
    std::cout << "}\n" << std::flush;
}

int runJson(const Options & options, const std::vector<UInt8> & oracle)
{
    const NativeReadAllocations allocations(options.native_read_allocations);
    const auto load_started = Clock::now();
    NativeTable native_table = loadNativePart(options);
    const UInt64 load_part_ns = static_cast<UInt64>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - load_started).count());
    const std::vector<UInt8> expected_oracle = selectJsonOracleRows(options, oracle, native_table.part);
    {
        const auto prepare_started = Clock::now();
        JsonMaterializer materializer(native_table);
        std::vector<WorkerState> workers;
        if (!options.marks.empty())
        {
            workers.resize(options.workers);
            prepareWorkers(workers, options, native_table);
        }
        JsonWorkerPool worker_pool(options, native_table, workers);
        const UInt64 prepare_ns = static_cast<UInt64>(
            std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - prepare_started).count());

        std::cout << "READY\n" << std::flush;
        std::string command;
        bool rowbinary_exported = false;
        while (std::getline(std::cin, command))
        {
            if (command == "quit")
                break;
            if (command != "scan")
                fail("stdin command must be scan or quit");
            scanJsonOnce(options, worker_pool, materializer, expected_oracle, allocations, load_part_ns, prepare_ns, rowbinary_exported);
        }
    }
    native_table.storage->flushAndShutdown();

    std::error_code remove_error;
    fs::remove_all(options.work_dir / "tmp", remove_error);
    if (remove_error)
        std::cerr << "temporary directory cleanup failed: " << remove_error.message() << '\n';
    return 0;
}

int run(const Options & options)
{
    static_assert(std::endian::native == std::endian::little, "the oracle protocol uses little-endian UInt64 arrays");
    const std::vector<UInt8> oracle = readOracle(options);
    if (options.schema == "json")
        return runJson(options, oracle);

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
