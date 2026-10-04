# W158 direct declared-Object Dynamic whole-part stock qualifier.
# Root-owned execution only; stock runtime and source reference are pinned
# independently by the paired Ruby oracle.
require "file_utils"
require "../src/crystal_click"

class W158ObjectDynamicQualifier
  class Failure < Exception
  end

  alias DataType = CrystalClick::BinaryDataType
  alias Value = CrystalClick::BinaryValue
  alias Document = CrystalClick::ObjectDocument

  VERSION        = "26.10.1.1201"
  BUILD_HASH     = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
  RUNTIME_SHA    = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
  SOURCE_ROOT    = "/Users/sergey/SrcArchives/clickhouse-2026-10-04-depth1-895d13ea"
  SOURCE_REV     = "895d13ea4ce8abb811b3b1b3d51b23a466a342a9"
  TABLE_SETTINGS = "index_granularity=2, index_granularity_bytes=10485760, enable_mixed_granularity_parts=1, min_rows_for_wide_part=0, min_bytes_for_wide_part=0, min_level_for_wide_part=0, compress_marks=0, compress_primary_key=0, min_compress_block_size=0, max_compress_block_size=4096, default_compression_codec='LZ4', serialization_info_version='with_types', string_serialization_version='single_stream', dynamic_serialization_version='v3', object_serialization_version='v3', object_shared_data_serialization_version='map', object_shared_data_serialization_version_for_zero_level_parts='map', propagate_types_serialization_versions_to_nested_types=1, use_compact_variant_discriminators_serialization=0"
  KEYS           = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
  ROWS_PER_MARK  = [2, 2, 2]
  FRAME_BYTES    = 16
  ARTIFACT_LIMIT = 8 * 1024 * 1024
  INPUT_ROWS     = [
    %({"pk":1,"j":{"a":42}}),
    %({"pk":2,"j":{"a":[1,2,3]}}),
    %({"pk":3,"j":{"a":44}}),
    %({"pk":4,"j":{"a":45}}),
    %({"pk":5,"j":{"a":[4,5]}}),
    %({"pk":6,"j":{"a":47}}),
  ]
  TYPE_DECLARATION = "JSON(a Dynamic(max_types=1))"

  def initialize
    @root = ENV.fetch("W158_PAIR_ROOT")
    @binary = ENV.fetch("CLICKHOUSE_BIN")
    @query_index = 0
    @evidence = File.join(@root, "results", "crystal-writer")
  end

  def run : Nil
    require_true(ENV["W158_EXECUTE_AS_ROOT"]? == "YES", "root execution requires W158_EXECUTE_AS_ROOT=YES")
    require_true(@root.starts_with?("/private/tmp/crystal-click-object-dynamic-w158.") &&
                 File.realpath(@root) == @root && !File.symlink?(@root), "W158 root is unsafe or noncanonical")
    %w[stores results].each { |name| make_dir(File.join(@root, name)) }
    %w[identity native library library-mutant].each { |name| make_dir(File.join(@root, "stores", name)) }
    make_dir(@evidence)
    verify_runtime_reference

    schema = object_schema
    native_part = make_native_part(schema)
    library_part = make_library_part(schema, false)
    assert_reader_values(library_part, schema, documents, "library-authored part")
    mutant_part = make_library_part(schema, true)
    assert_reader_values(mutant_part, schema, documents(true), "library mutant part")

    File.write(File.join(@root, "cells.tsv"),
      "label\tdirection\tmode\tstore\ttable\tpart_path\n" +
      "native\tstock-json-each-row\tbasic\t#{File.join(@root, "stores", "native")}\tdefault.p\t#{native_part}\n" +
      "library\tcrystal-complete-part\tbasic\t#{File.join(@root, "stores", "library")}\tdefault.p\t#{library_part}\n" +
      "library-mutant\tcrystal-complete-part-mutant\tbasic\t#{File.join(@root, "stores", "library-mutant")}\tdefault.p\t#{mutant_part}\n")
    puts "PASS W158 stock-authored and complete library-authored declared-Dynamic parts decoded against literal Int64/Array(Nullable(Int64)) values"
  end

  private def fail(message : String) : NoReturn
    raise Failure.new("W158 declared Object Dynamic qualifier: #{message}")
  end

  private def require_true(condition : Bool, message : String) : Nil
    fail(message) unless condition
  end

  private def make_dir(path : String) : Nil
    require_true(!File.exists?(path) && !File.symlink?(path), "refusing to reuse directory #{path}")
    Dir.mkdir(path, 0o700)
  end

  private def process_env : Hash(String, String)
    environment = ENV.to_h
    environment["TZ"] = "UTC"
    environment
  end

  private def click(
    store : String, sql : String, label : String, input : String? = nil,
  ) : String
    @query_index += 1
    base = File.join(@evidence, "#{@query_index}-#{label.gsub(/[^A-Za-z0-9_.-]/, "_")}")
    sql_path = base + ".sql"
    stdout_path = base + ".stdout"
    stderr_path = base + ".stderr"
    [sql_path, stdout_path, stderr_path].each do |path|
      require_true(!File.exists?(path) && !File.symlink?(path), "refusing to overwrite evidence #{path}")
    end
    File.write(sql_path, sql + ";\n")
    arguments = [
      "local", "--path", store, "--session_timezone=UTC", "--enable_json_type=1",
      "--allow_experimental_dynamic_type=1", "--print_pretty_type_names=0",
      "--output_format_json_quote_64bit_integers=0", "--max_threads=1",
      "--max_insert_threads=1", "--max_block_size=1000", "--max_memory_usage=536870912",
      "--max_query_size=1048576", "--query", sql,
    ]
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = if input
               Process.run(@binary, arguments, env: process_env, input: IO::Memory.new(input), output: stdout, error: stderr)
             else
               Process.run(@binary, arguments, env: process_env, output: stdout, error: stderr)
             end
    File.write(stdout_path, stdout.to_s)
    File.write(stderr_path, stderr.to_s)
    [sql_path, stdout_path, stderr_path].each do |path|
      require_true(File.size(path) <= ARTIFACT_LIMIT, "evidence exceeds 8 MiB: #{path}")
    end
    raise "ClickHouse failed at #{label}: #{stderr}\n#{sql}" unless status.success?
    stdout.to_s
  end

  private def verify_runtime_reference : Nil
    output = IO::Memory.new
    status = Process.run("shasum", ["-a", "256", @binary], env: process_env, output: output, error: IO::Memory.new)
    require_true(status.success? && output.to_s.split(' ').first? == RUNTIME_SHA,
      "pinned ClickHouse executable SHA-256 differs")
    revision_output = IO::Memory.new
    revision_status = Process.run("git", ["-C", SOURCE_ROOT, "rev-parse", "HEAD"],
      env: process_env, output: revision_output, error: IO::Memory.new)
    require_true(revision_status.success? && revision_output.to_s.strip == SOURCE_REV,
      "source reference checkout revision differs")
    version = click(File.join(@root, "stores", "identity"), "SELECT version() FORMAT TSVRaw", "version").strip
    require_true(version == VERSION, "pinned stock runtime version differs: #{version.inspect}")
    build = click(File.join(@root, "stores", "identity"),
      "SELECT concat(name, '=', value) FROM system.build_options WHERE name IN ('GIT_HASH','VERSION_GITHASH') ORDER BY name FORMAT TSVRaw",
      "build-identity")
    expected = "GIT_HASH=#{BUILD_HASH}\nVERSION_GITHASH=#{BUILD_HASH}\n"
    require_true(build == expected, "pinned stock runtime build identity differs: #{build.inspect}")
    File.write(File.join(@evidence, "pins.txt"), [
      "runtime_version=#{VERSION}", "runtime_sha256=#{RUNTIME_SHA}", "runtime_build_hash=#{BUILD_HASH}",
      "source_reference=#{SOURCE_ROOT}@#{SOURCE_REV}", "source_is_not_asserted_to_build_runtime=true",
    ].join("\n") + "\n")
    nil
  end

  private def object_schema : CrystalClick::ObjectDocumentSchema
    type = DataType.dynamic(1)
    schema = CrystalClick::ObjectDocumentSchema.new({"a" => type} of String => DataType)
    require_true(schema.declaration == TYPE_DECLARATION,
      "direct Dynamic schema declaration differs: #{schema.declaration.inspect}")
    schema
  end

  private def create_table(store : String, schema : CrystalClick::ObjectDocumentSchema, label : String) : Nil
    ddl = "CREATE TABLE default.p (pk UInt64, j #{schema.declaration}) ENGINE=MergeTree ORDER BY pk SETTINGS #{TABLE_SETTINGS}"
    click(store, ddl, "#{label}-create")
    columns = click(store,
      "SELECT name, type, position FROM system.columns WHERE database='default' AND table='p' ORDER BY position FORMAT TSVRaw",
      "#{label}-system-columns")
    expected = "pk\tUInt64\t1\nj\t#{TYPE_DECLARATION}\t2\n"
    require_true(columns == expected, "#{label}: native declared Object schema differs: #{columns.inspect}")
    nil
  end

  private def documents(mutant : Bool = false) : Array(Document)
    dynamic_type = DataType.dynamic(1)
    int64 = DataType.primitive("Int64")
    nullable_int64 = DataType.nullable(int64)
    nullable_int_array = DataType.array(nullable_int64)
    values = [] of Value
    first = mutant ? 43_i64 : 42_i64
    values << Value.dynamic(dynamic_type, Value.int64(first))
    values << Value.dynamic(dynamic_type, Value.array(nullable_int_array, [
      Value.nullable(nullable_int64, Value.int64(1_i64)),
      Value.nullable(nullable_int64, Value.int64(2_i64)),
      Value.nullable(nullable_int64, Value.int64(3_i64)),
    ] of Value))
    values << Value.dynamic(dynamic_type, Value.int64(44_i64))
    values << Value.dynamic(dynamic_type, Value.int64(45_i64))
    values << Value.dynamic(dynamic_type, Value.array(nullable_int_array, [
      Value.nullable(nullable_int64, Value.int64(4_i64)),
      Value.nullable(nullable_int64, Value.int64(5_i64)),
    ] of Value))
    values << Value.dynamic(dynamic_type, Value.int64(47_i64))
    values.map { |value| Document.new({"a" => value} of String => Value) }
  end

  private def structure_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    dynamic_type = DataType.primitive("Int64")
    CrystalClick::ObjectDocumentPlan.new(
      structures, schema.typed_paths,
      typed_dynamics: {"a" => CrystalClick::DynamicStructure.new([dynamic_type] of DataType)},
    )
  end

  private def marks(docs : Array(Document)) : Array(Array(Document))
    [docs[0, 2], docs[2, 2], docs[4, 2]]
  end

  private def make_native_part(schema : CrystalClick::ObjectDocumentSchema) : String
    label = "native"
    store = File.join(@root, "stores", label)
    evidence = File.join(@root, "results", label)
    make_dir(evidence)
    create_table(store, schema, label)
    input = INPUT_ROWS.join("\n") + "\n"
    input_path = File.join(evidence, "input.jsonl")
    require_true(!File.exists?(input_path) && !File.symlink?(input_path), "native input artifact already exists")
    File.write(input_path, input)
    click(store, "INSERT INTO default.p FORMAT JSONEachRow", "#{label}-insert", input)
    part = active_part(store, label)
    assert_reader_values(part, schema, documents, "native stock-authored part")
    part
  end

  private def make_library_part(schema : CrystalClick::ObjectDocumentSchema, mutant : Bool) : String
    label = mutant ? "library-mutant" : "library"
    store = File.join(@root, "stores", label)
    evidence = File.join(@root, "results", label)
    make_dir(evidence)
    create_table(store, schema, label)
    empty = click(store,
      "SELECT count() FROM system.parts WHERE database='default' AND table='p' AND active FORMAT TSVRaw",
      "#{label}-empty-parts").strip
    require_true(empty == "0", "#{label}: target table is not empty before detached part publication")
    table_data = click(store,
      "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='p' FORMAT TSVRaw",
      "#{label}-table-data-path").strip
    data_path = verified_path(table_data, store, label)
    detached = File.join(data_path, "detached")
    require_true(!File.symlink?(detached), "#{label}: detached directory is a symlink")
    Dir.mkdir(detached, 0o700) unless Dir.exists?(detached)
    destination = File.join(detached, "all_1_1_0")
    require_true(!File.exists?(destination) && !File.symlink?(destination), "#{label}: part target is occupied")
    CrystalClick::WidePartWriter.write_uint64_object_pair(
      destination, "pk", Slice(UInt64).new(KEYS.size) { |index| KEYS[index] },
      "j", schema, structure_plan(schema), marks(documents(mutant)),
      rows_per_mark: 2, mode: 0_u64,
      profile: CrystalClick::BinaryBulkProfile.single_stream,
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      frame_bytes: FRAME_BYTES,
    )
    verified_path(destination, store, "#{label} library part")
    click(store, "ALTER TABLE default.p ATTACH PART 'all_1_1_0'", "#{label}-attach")
    part = active_part(store, label)
    assert_reader_values(part, schema, documents(mutant), "#{label} complete library part")
    part
  end

  private def verified_path(path : String, store : String, label : String) : String
    real_store = File.realpath(store)
    real_path = File.realpath(path)
    require_true(real_path.starts_with?(real_store + "/") && !File.symlink?(path),
      "#{label}: resolved path escaped the isolated stock store")
    cursor = real_store
    real_path[(real_store.size + 1)..].split('/').each do |component|
      cursor = File.join(cursor, component)
      require_true(!File.symlink?(cursor), "#{label}: symlink in part path")
    end
    real_path
  end

  private def active_part(store : String, label : String) : String
    output = click(store,
      "SELECT name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='p' AND active ORDER BY name FORMAT TSVRaw",
      "#{label}-active-part")
    rows = output.lines.map(&.chomp)
    require_true(rows.size == 1, "#{label}: expected exactly one active part")
    fields = rows[0].split('\t')
    require_true(fields.size == 5 && fields[0] == "all_1_1_0" && fields[2] == "Wide" &&
                 fields[3] == "6" && fields[4] == "4", "#{label}: expected one six-row Wide part with three real marks")
    part = verified_path(fields[1], store, label)
    require_true(File.file?(File.join(part, "checksums.txt")), "#{label}: whole part lacks checksums")
    part
  end

  private def assert_value(expected : Value, actual : Value, label : String) : Nil
    require_true(expected.type == actual.type,
      "#{label}: nominal value type differs (expected #{expected.type.name}, got #{actual.type.name})")
    require_true(expected.is_null? == actual.is_null?, "#{label}: NULL state differs")
    return if expected.is_null?
    if expected.type.tag == DataType::TAG_DYNAMIC
      require_true(expected.element_count == 1 && actual.element_count == 1, "#{label}: Dynamic child is absent")
      assert_value(expected.element_at(0), actual.element_at(0), "#{label} Dynamic child")
    elsif expected.type.tag == DataType::TAG_ARRAY
      require_true(expected.element_count == actual.element_count, "#{label}: Array length differs")
      expected.element_count.times { |index| assert_value(expected.element_at(index), actual.element_at(index), "#{label}[#{index}]") }
    elsif expected.type.tag == DataType::TAG_NULLABLE
      require_true(expected.element_count == 1 && actual.element_count == 1,
        "#{label}: non-NULL Nullable child is absent")
      assert_value(expected.element_at(0), actual.element_at(0), "#{label} Nullable child")
    else
      require_true(expected.bytes == actual.bytes, "#{label}: exact scalar bytes differ")
    end
    nil
  end

  private def assert_documents(expected : Array(Document), actual : Array(Document), label : String) : Nil
    require_true(expected.size == actual.size, "#{label}: row count differs")
    expected.each_with_index do |document, index|
      observed = actual[index]
      require_true(document.paths == observed.paths, "#{label}: path roster differs at row #{index}")
      document.paths.each do |path|
        assert_value(document.value_for(path), observed.value_for(path), "#{label} row #{index} #{path}")
      end
    end
    nil
  end

  private def assert_granules(expected : Array(Array(Document)), actual : Array(Array(Document)), label : String) : Nil
    require_true(expected.size == actual.size, "#{label}: mark count differs")
    expected.each_with_index do |docs, index|
      assert_documents(docs, actual[index], "#{label} mark #{index}")
    end
    nil
  end

  private def assert_reader_values(part : String, schema : CrystalClick::ObjectDocumentSchema,
                                   docs : Array(Document), label : String) : Nil
    full = CrystalClick::ObjectDocumentFileReader.read(
      part, "j", schema.typed_paths, first_mark: 0, mark_count: ROWS_PER_MARK.size,
      profile: CrystalClick::BinaryBulkProfile.single_stream,
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      hashed: true, limits: CrystalClick::BinaryCodecLimits.default,
      transport_limits: CrystalClick::CompressedStreamLimits.new,
    )
    assert_granules(marks(docs), full, "#{label} full")
    middle = CrystalClick::ObjectDocumentFileReader.read(
      part, "j", schema.typed_paths, first_mark: 1, mark_count: 1,
      profile: CrystalClick::BinaryBulkProfile.single_stream,
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      hashed: true, limits: CrystalClick::BinaryCodecLimits.default,
      transport_limits: CrystalClick::CompressedStreamLimits.new,
    )
    assert_granules([marks(docs)[1]], middle, "#{label} middle")
    puts "PASS W158 Crystal complete-part reader literals: #{label}"
    nil
  end
end

W158ObjectDynamicQualifier.new.run
