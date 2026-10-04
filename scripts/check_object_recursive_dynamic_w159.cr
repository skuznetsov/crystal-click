# W159 recursive declared-Object Dynamic complete-part stock qualifier.
# Root-owned execution only; the paired Ruby oracle pins and checks stock
# behavior independently from this library-authored writer.
require "file_utils"
require "../src/crystal_click"

class W159RecursiveDynamicQualifier
  class Failure < Exception
  end

  alias DataType = CrystalClick::BinaryDataType
  alias Value = CrystalClick::BinaryValue
  alias Document = CrystalClick::ObjectDocument

  VERSION          = "26.10.1.1201"
  BUILD_HASH       = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
  RUNTIME_SHA      = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
  SOURCE_ROOT      = "/Users/sergey/SrcArchives/clickhouse-2026-10-04-depth1-895d13ea"
  SOURCE_REV       = "895d13ea4ce8abb811b3b1b3d51b23a466a342a9"
  TYPE_DECLARATION = "JSON(arr Array(Dynamic(max_types=1)), declared String, direct Dynamic(max_types=1), lookup Map(String, Dynamic(max_types=1)), pair Tuple(left Dynamic(max_types=1), right Dynamic(max_types=1)))"
  TABLE_SETTINGS   = "index_granularity=2, index_granularity_bytes=10485760, enable_mixed_granularity_parts=1, min_rows_for_wide_part=0, min_bytes_for_wide_part=0, min_level_for_wide_part=0, compress_marks=0, compress_primary_key=0, min_compress_block_size=0, max_compress_block_size=4096, default_compression_codec='LZ4', serialization_info_version='with_types', string_serialization_version='single_stream', dynamic_serialization_version='v3', object_serialization_version='v3', object_shared_data_serialization_version='map', object_shared_data_serialization_version_for_zero_level_parts='map', map_serialization_version='basic', map_serialization_version_for_zero_level_parts='basic', propagate_types_serialization_versions_to_nested_types=1, use_compact_variant_discriminators_serialization=0"
  KEYS             = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
  ROWS_PER_MARK    = [2_u64, 2_u64, 2_u64]
  FRAME_BYTES      = 16
  ARTIFACT_LIMIT   = 8 * 1024 * 1024
  INPUT_ROWS       = [
    %({"pk":1,"j":{"arr":[10],"declared":"declared-alpha","direct":42,"lookup":{"key-one":200},"pair":[100,"right-alpha"],"legacy":"legacy-alpha"}}),
    %({"pk":2,"j":{"arr":[11,12],"declared":"declared-beta","direct":43,"lookup":{"key-two":"map-spill"},"pair":[101,"right-beta"],"legacy":"legacy-beta"}}),
    %({"pk":3,"j":{"arr":[],"declared":"declared-gamma","direct":null,"lookup":{},"pair":[null,"right-gamma"],"legacy":"legacy-gamma"}}),
    %({"pk":4,"j":{"arr":["array-spill"],"declared":"declared-delta","direct":44,"lookup":{"key-four":204},"pair":[103,true],"legacy":"legacy-delta"}}),
    %({"pk":5,"j":{"arr":[15,16,17],"declared":"declared-epsilon","direct":45,"lookup":{"key-five":205},"pair":[104,"right-epsilon"],"legacy":"legacy-epsilon"}}),
    %({"pk":6,"j":{"arr":[null],"declared":"declared-zeta","direct":46,"lookup":{"key-six":null},"pair":[null,null],"legacy":"legacy-zeta"}}),
  ]
  EXPECTED_SITES = [
    {"arr", "root.elements", "j.arr.dynamic_structure", ["Int64"] of String},
    {"direct", "root", "j.direct.dynamic_structure", ["Int64"] of String},
    {"lookup", "root.elements.field.1", "j.lookup%2Evalues.dynamic_structure", ["Int64"] of String},
    {"pair", "root.field.0", "j.pair%2Eleft.dynamic_structure", ["Int64"] of String},
    {"pair", "root.field.1", "j.pair%2Eright.dynamic_structure", ["String"] of String},
  ] of Tuple(String, String, String, Array(String))

  def initialize
    @root = ENV.fetch("W159_PAIR_ROOT")
    @binary = ENV.fetch("CLICKHOUSE_BIN")
    @query_index = 0
    @evidence = File.join(@root, "results", "crystal-writer")
  end

  def run : Nil
    require_true(ENV["W159_EXECUTE_AS_ROOT"]? == "YES", "root execution requires W159_EXECUTE_AS_ROOT=YES")
    require_true(@root.starts_with?("/private/tmp/crystal-click-object-recursive-dynamic-w159.") &&
                 File.realpath(@root) == @root && !File.symlink?(@root), "W159 root is unsafe or noncanonical")
    %w[stores results].each { |name| make_dir(File.join(@root, name)) }
    %w[identity native library library-mutant].each { |name| make_dir(File.join(@root, "stores", name)) }
    make_dir(@evidence)
    verify_runtime_reference

    schema = object_schema
    native_part = make_native_part(schema)
    plan = object_plan(schema)
    library_part = make_library_part(schema, plan, false)
    assert_reader_values(library_part, schema, documents, "library-authored part")
    validate_dynamic_metadata(native_part, schema, plan, false, "stock-authored")
    validate_dynamic_metadata(library_part, schema, plan, true, "library-authored")

    mutant_plan = object_plan(schema)
    mutant_part = make_library_part(schema, mutant_plan, true)
    assert_reader_values(mutant_part, schema, documents(true), "library mutant part")
    validate_dynamic_metadata(mutant_part, schema, mutant_plan, true, "library-mutant")

    File.write(File.join(@root, "cells.tsv"),
      "label\tdirection\tmode\tstore\ttable\tpart_path\n" +
      "native\tstock-json-each-row\tbasic\t#{File.join(@root, "stores", "native")}\tdefault.p\t#{native_part}\n" +
      "library\tcrystal-complete-part\tbasic\t#{File.join(@root, "stores", "library")}\tdefault.p\t#{library_part}\n" +
      "library-mutant\tcrystal-complete-part-mutant\tbasic\t#{File.join(@root, "stores", "library-mutant")}\tdefault.p\t#{mutant_part}\n")
    puts "PASS W159 stock-authored and complete library-authored Array/Tuple/Map/direct Dynamic parts checked against explicit site rosters and literal values"
  end

  private def fail(message : String) : NoReturn
    raise Failure.new("W159 recursive declared Object Dynamic qualifier: #{message}")
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

  private def click(store : String, sql : String, label : String, input : String? = nil) : String
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

  private def field_types : NamedTuple(arr: DataType, declared: DataType, direct: DataType, lookup: DataType, pair: DataType)
    dynamic_for_array = DataType.dynamic(1)
    dynamic_for_direct = DataType.dynamic(1)
    dynamic_for_lookup = DataType.dynamic(1)
    dynamic_for_pair_left = DataType.dynamic(1)
    dynamic_for_pair_right = DataType.dynamic(1)
    string = DataType.primitive("String")
    {
      arr:      DataType.array(dynamic_for_array),
      declared: DataType.primitive("String"),
      direct:   dynamic_for_direct,
      lookup:   DataType.map(string, dynamic_for_lookup),
      pair:     DataType.tuple(
        [dynamic_for_pair_left, dynamic_for_pair_right] of DataType,
        ["left", "right"] of String,
      ),
    }
  end

  private def object_schema : CrystalClick::ObjectDocumentSchema
    schema = CrystalClick::ObjectDocumentSchema.new({
      "arr"      => field_types[:arr],
      "declared" => field_types[:declared],
      "direct"   => field_types[:direct],
      "lookup"   => field_types[:lookup],
      "pair"     => field_types[:pair],
    } of String => DataType)
    require_true(schema.declaration == TYPE_DECLARATION,
      "recursive Dynamic schema declaration differs: #{schema.declaration.inspect}")
    schema
  end

  private def object_structures : CrystalClick::ObjectDynamicStructureSet
    string = DataType.primitive("String")
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["legacy"] of String),
      {"legacy" => CrystalClick::DynamicStructure.new([string] of DataType)} of String => CrystalClick::DynamicStructure,
    )
  end

  private def object_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
    int64 = DataType.primitive("Int64")
    string = DataType.primitive("String")
    direct = {"direct" => CrystalClick::DynamicStructure.new([int64] of DataType)} of String => CrystalClick::DynamicStructure
    sites = {
      "arr"    => {"root.elements" => CrystalClick::DynamicStructure.new([int64] of DataType)},
      "lookup" => {"root.elements.field.1" => CrystalClick::DynamicStructure.new([int64] of DataType)},
      "pair"   => {
        "root.field.0" => CrystalClick::DynamicStructure.new([int64] of DataType),
        "root.field.1" => CrystalClick::DynamicStructure.new([string] of DataType),
      },
    }
    # All child rosters are authored here from the finite fixture literals.
    # Stock-decoded metadata is compared against, never used to build, them.
    CrystalClick::ObjectDocumentPlan.new(
      object_structures, schema.typed_paths, direct,
      typed_dynamic_sites: sites,
    )
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

  private def int64(value : Int64) : Value
    Value.int64(value)
  end

  private def dynamic(type : DataType, child : Value? = nil) : Value
    Value.dynamic(type, child)
  end

  private def documents(mutant : Bool = false) : Array(Document)
    types = field_types
    array_dynamic = types[:arr].child_at(0)
    direct_dynamic = types[:direct]
    lookup_dynamic = types[:lookup].child_at(1)
    pair_left_dynamic = types[:pair].child_at(0)
    pair_right_dynamic = types[:pair].child_at(1)
    int64_type = DataType.primitive("Int64")
    string_type = DataType.primitive("String")
    array_value = ->(children : Array(Value)) { Value.array(types[:arr], children) }
    pair_value = ->(left : Value, right : Value) { Value.tuple(types[:pair], [left, right] of Value) }
    lookup_value = ->(entries : Array(Value)) { Value.map(types[:lookup], entries) }
    first_direct = mutant ? 43_i64 : 42_i64
    [
      Document.new({
        "arr"      => array_value.call([dynamic(array_dynamic, int64(10_i64))] of Value),
        "declared" => Value.string("declared-alpha"),
        "direct"   => dynamic(direct_dynamic, int64(first_direct)),
        "lookup"   => lookup_value.call([Value.string("key-one"), dynamic(lookup_dynamic, int64(200_i64))] of Value),
        "pair"     => pair_value.call(dynamic(pair_left_dynamic, int64(100_i64)), dynamic(pair_right_dynamic, Value.string("right-alpha"))),
        "legacy"   => Value.string("legacy-alpha"),
      }),
      Document.new({
        "arr"      => array_value.call([dynamic(array_dynamic, int64(11_i64)), dynamic(array_dynamic, int64(12_i64))] of Value),
        "declared" => Value.string("declared-beta"),
        "direct"   => dynamic(direct_dynamic, int64(43_i64)),
        "lookup"   => lookup_value.call([Value.string("key-two"), dynamic(lookup_dynamic, Value.string("map-spill"))] of Value),
        "pair"     => pair_value.call(dynamic(pair_left_dynamic, int64(101_i64)), dynamic(pair_right_dynamic, Value.string("right-beta"))),
        "legacy"   => Value.string("legacy-beta"),
      }),
      Document.new({
        "arr"      => array_value.call([] of Value),
        "declared" => Value.string("declared-gamma"),
        "direct"   => dynamic(direct_dynamic),
        "lookup"   => lookup_value.call([] of Value),
        "pair"     => pair_value.call(dynamic(pair_left_dynamic), dynamic(pair_right_dynamic, Value.string("right-gamma"))),
        "legacy"   => Value.string("legacy-gamma"),
      }),
      Document.new({
        "arr"      => array_value.call([dynamic(array_dynamic, Value.string("array-spill"))] of Value),
        "declared" => Value.string("declared-delta"),
        "direct"   => dynamic(direct_dynamic, int64(44_i64)),
        "lookup"   => lookup_value.call([Value.string("key-four"), dynamic(lookup_dynamic, int64(204_i64))] of Value),
        "pair"     => pair_value.call(dynamic(pair_left_dynamic, int64(103_i64)), dynamic(pair_right_dynamic, Value.bool(true))),
        "legacy"   => Value.string("legacy-delta"),
      }),
      Document.new({
        "arr"      => array_value.call([dynamic(array_dynamic, int64(15_i64)), dynamic(array_dynamic, int64(16_i64)), dynamic(array_dynamic, int64(17_i64))] of Value),
        "declared" => Value.string("declared-epsilon"),
        "direct"   => dynamic(direct_dynamic, int64(45_i64)),
        "lookup"   => lookup_value.call([Value.string("key-five"), dynamic(lookup_dynamic, int64(205_i64))] of Value),
        "pair"     => pair_value.call(dynamic(pair_left_dynamic, int64(104_i64)), dynamic(pair_right_dynamic, Value.string("right-epsilon"))),
        "legacy"   => Value.string("legacy-epsilon"),
      }),
      Document.new({
        "arr"      => array_value.call([dynamic(array_dynamic)] of Value),
        "declared" => Value.string("declared-zeta"),
        "direct"   => dynamic(direct_dynamic, int64(46_i64)),
        "lookup"   => lookup_value.call([Value.string("key-six"), dynamic(lookup_dynamic)] of Value),
        "pair"     => pair_value.call(dynamic(pair_left_dynamic), dynamic(pair_right_dynamic)),
        "legacy"   => Value.string("legacy-zeta"),
      }),
    ] of Document
  end

  private def create_granules(docs : Array(Document)) : Array(Array(Document))
    [docs[0, 2], docs[2, 2], docs[4, 2]] of Array(Document)
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

  private def make_library_part(schema : CrystalClick::ObjectDocumentSchema,
                                plan : CrystalClick::ObjectDocumentPlan, mutant : Bool) : String
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
    docs = documents(mutant)
    CrystalClick::WidePartWriter.write_uint64_object_pair(
      destination, "pk", Slice(UInt64).new(KEYS.size) { |index| KEYS[index] },
      "j", schema, plan, create_granules(docs),
      rows_per_mark: 2, mode: 0_u64,
      profile: CrystalClick::BinaryBulkProfile.single_stream,
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      frame_bytes: FRAME_BYTES,
    )
    verified_path(destination, store, "#{label} library part")
    click(store, "ALTER TABLE default.p ATTACH PART 'all_1_1_0'", "#{label}-attach")
    part = active_part(store, label)
    assert_reader_values(part, schema, docs, "#{label} complete library part")
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

  private def read_file(path : String, label : String) : Bytes
    require_true(File.file?(path) && !File.symlink?(path), "#{label}: missing regular file or symlink")
    size = File.size(path)
    require_true(size >= 0 && size <= ARTIFACT_LIMIT, "#{label}: file exceeds 8 MiB")
    text = File.read(path)
    Bytes.new(text.bytesize) { |index| text.to_slice[index] }
  end

  private def compressed_budget : CrystalClick::CompressedStreamBudget
    limits = CrystalClick::CompressedStreamLimits.new(
      max_file_bytes: ARTIFACT_LIMIT.to_i64,
      max_mark_bytes: 1024 * 1024,
      max_frame_compressed_bytes: ARTIFACT_LIMIT.to_i64,
      max_frame_decompressed_bytes: ARTIFACT_LIMIT.to_i64,
      max_records: 100_000,
      max_decoded_bytes: ARTIFACT_LIMIT.to_i64,
      max_result_bytes: ARTIFACT_LIMIT.to_i64,
    )
    CrystalClick::CompressedStreamBudget.new(limits)
  end

  private def hashed_path(part : String, physical_name : String, extension : String) : String
    File.join(part, "#{CrystalClick::StreamName.hash(physical_name)}#{extension}")
  end

  private def substreams(part : String) : Array(String)
    path = File.join(part, "columns_substreams.txt")
    read = read_file(path, "columns_substreams.txt")
    String.new(read).lines.select(&.starts_with?("\t")).map(&.strip).reject(&.empty?).sort!
  end

  private def expected_type(path : String) : DataType
    types = field_types
    case path
    when "arr"    then types[:arr]
    when "direct" then types[:direct]
    when "lookup" then types[:lookup]
    when "pair"   then types[:pair]
    else               raise KeyError.new("unknown W159 typed field #{path.inspect}")
    end
  end

  private def validate_dynamic_metadata(part : String, schema : CrystalClick::ObjectDocumentSchema,
                                        plan : CrystalClick::ObjectDocumentPlan,
                                        library_owned : Bool, label : String) : Nil
    physical = CrystalClick::ObjectDocumentPhysicalPlan.new("j", plan)
    all_physical_names = physical.stream_names
    require_true(all_physical_names.size == physical.stream_count &&
                 all_physical_names == all_physical_names.uniq.sort!,
      "#{label}: ordinary, inferred legacy, and declared Dynamic lanes are not one collision-free physical roster")
    actual_substreams = substreams(part)
    bindings_by_field = Hash(String, Array(Tuple(String, String, String, Array(String)))).new
    EXPECTED_SITES.each do |binding|
      (bindings_by_field[binding[0]] ||= [] of Tuple(String, String, String, Array(String))) << binding
    end

    bindings_by_field.each do |field, bindings|
      child_physical = physical.typed_dynamic(field)
      expected_structures = Hash(String, String).new
      bindings.each { |binding| expected_structures["#{binding[1]}.dynamic_structure"] = binding[2] }
      require_true(child_physical.structure_stream_names == expected_structures,
        "#{label} #{field}: exact structure site-to-physical-name map differs from independent literals")

      structure_bytes = Hash(String, Bytes).new
      bindings.each do |binding|
        _field, site, physical_name, _expected_types = binding
        require_true(child_physical.structure_name_for(site) == physical_name,
          "#{label} #{field} #{site}: physical metadata name differs from independent literal")
        require_true(actual_substreams.includes?(physical_name),
          "#{label} #{field} #{site}: columns_substreams.txt omits literal metadata name #{physical_name}")
        compressed = read_file(hashed_path(part, physical_name, ".bin"), "#{label} #{field} #{site} structure")
        raw = CrystalClick::CompressedBlock.decode_all(compressed, max_output_size: ARTIFACT_LIMIT)
        structure_bytes[site] = raw
      end

      decoded = CrystalClick::BinaryDynamicBulkPlan.decode_structure_streams(
        expected_type(field),
        CrystalClick::BinaryDynamicStructureStreams.new(structure_bytes),
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
        CrystalClick::BinaryBulkProfile.single_stream,
      )
      expected_sites = bindings.map(&.[1]).sort!
      require_true(decoded.site_paths == expected_sites,
        "#{label} #{field}: metadata Decoder sites differ from explicit declared grammar")
      bindings.each do |binding|
        _field, site, physical_name, expected_types = binding
        structure = decoded.structure_for(site)
        require_true(structure.types.map(&.name) == expected_types,
          "#{label} #{field} #{site}: actual ordinary roster differs from independent literal")
        canonical = expected_types == ["Int64"] ? ["Int64", "SharedVariant"] : ["SharedVariant", "String"]
        require_true(structure.canonical_variant_names == canonical,
          "#{label} #{field} #{site}: canonical SharedVariant ordering differs from independent literal")
        offset = decoded.statistics_offset_for(site)
        require_true(offset == 10_i32,
          "#{label} #{field} #{site}: V3 statistics boundary differs from the admitted literal prefix")
        raw = structure_bytes[site]
        require_true(raw.size > offset && raw[offset] <= 1_u8,
          "#{label} #{field} #{site}: V3 statistics presence flag is absent or invalid")
        if library_owned
          require_true(structure.statistics.nil? && raw[offset] == 0_u8,
            "#{label} #{field} #{site}: library child metadata must use absent V3 statistics")
        end

        metadata_data = hashed_path(part, physical_name, ".bin")
        metadata_marks = hashed_path(part, physical_name, ".mrk2")
        grid = CrystalClick::CompressedMarkReader.inspect(
          metadata_data, metadata_marks, File.size(metadata_data), File.size(metadata_marks), prefix_size: offset
        )
        require_true(grid.prefix_size == offset && grid.logical_size == raw.size.to_i64 &&
                     grid.rows_per_mark == ROWS_PER_MARK,
          "#{label} #{field} #{site}: metadata statistics suffix or K+1 grid boundary differs")
        require_true(grid.positions.size == 4 && grid.positions[0] == offset.to_i64 &&
                     grid.positions[1] == offset.to_i64 && grid.positions[2] == offset.to_i64 &&
                     grid.positions[3] == grid.logical_size,
          "#{label} #{field} #{site}: all three real marks must point to the stats offset and terminal to EOF")
        puts "SITE\t#{label}\t#{field}\t#{site}\t#{physical_name}\toffset=#{offset}\ttypes=#{expected_types.join(",")}"
      end

      expected_discriminator_roles = bindings.map { |binding| "#{binding[1]}.discriminators" }.sort!
      discriminator_roles = child_physical.data_stream_names.keys.select(&.ends_with?(".discriminators")).sort!
      require_true(discriminator_roles == expected_discriminator_roles,
        "#{label} #{field}: BASIC discriminator role map differs from the exact site roster")
      child_physical.data_stream_names.each do |role, physical_name|
        prefix_size = child_physical.prefix_size_for(role)
        if role.ends_with?(".discriminators")
          require_true(prefix_size == 8_i32 && physical_name.ends_with?(".variant_discr"),
            "#{label} #{field} #{role}: BASIC discriminator physical prefix is not eight bytes")
          require_true(actual_substreams.includes?(physical_name),
            "#{label} #{field} #{role}: columns_substreams.txt omits discriminator lane")
          data_path = File.join(part, child_physical.data_file_for(role, hashed: true))
          marks_path = File.join(part, child_physical.marks_file_for(role, hashed: true))
          grid = CrystalClick::CompressedMarkReader.inspect(
            data_path, marks_path, File.size(data_path), File.size(marks_path), prefix_size: prefix_size
          )
          require_true(grid.prefix_size == 8_i32 && grid.rows_per_mark == ROWS_PER_MARK &&
                       grid.positions.size == 4 && grid.positions.last == grid.logical_size,
            "#{label} #{field} #{role}: BASIC physical prefix or complete discriminator K+1 grid differs")
        else
          require_true(prefix_size == 0_i32, "#{label} #{field} #{role}: non-discriminator lane has a prefix")
        end
      end
    end
    require_true(bindings_by_field.keys.sort == ["arr", "direct", "lookup", "pair"],
      "#{label}: explicit field/site fixture coverage differs")
    nil
  end

  private def assert_value(expected : Value, actual : Value, label : String) : Nil
    require_true(expected.type == actual.type,
      "#{label}: nominal value type differs (expected #{expected.type.name}, got #{actual.type.name})")
    require_true(expected.is_null? == actual.is_null?, "#{label}: NULL state differs")
    return if expected.is_null?
    case expected.type.tag
    when DataType::TAG_DYNAMIC, DataType::TAG_ARRAY, DataType::TAG_MAP,
         DataType::TAG_UNNAMED_TUPLE, DataType::TAG_NAMED_TUPLE,
         DataType::TAG_NULLABLE
      require_true(expected.child_count == actual.child_count, "#{label}: child count differs")
      expected.child_count.times { |index| assert_value(expected.child_at(index), actual.child_at(index), "#{label}[#{index}]") }
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
    profile = CrystalClick::BinaryBulkProfile.single_stream
    limits = CrystalClick::BinaryCodecLimits.default
    transport_limits = CrystalClick::CompressedStreamLimits.new
    full = CrystalClick::ObjectDocumentFileReader.read(
      part, "j", schema.typed_paths, first_mark: 0, mark_count: ROWS_PER_MARK.size,
      profile: profile, shared_profile: profile,
      hashed: true, limits: limits, transport_limits: transport_limits,
    )
    assert_granules(create_granules(docs), full, "#{label} full")
    middle = CrystalClick::ObjectDocumentFileReader.read(
      part, "j", schema.typed_paths, first_mark: 1, mark_count: 1,
      profile: profile, shared_profile: profile,
      hashed: true, limits: limits, transport_limits: transport_limits,
    )
    assert_granules([create_granules(docs)[1]], middle, "#{label} rows 3-4 middle")
    empty = CrystalClick::ObjectDocumentFileReader.read(
      part, "j", schema.typed_paths, first_mark: 3, mark_count: 0,
      profile: profile, shared_profile: profile,
      hashed: true, limits: limits, transport_limits: transport_limits,
    )
    require_true(empty.empty?, "#{label}: terminal zero-window selection is not empty")
    puts "PASS W159 Crystal complete-part reader full/middle/zero literals: #{label}"
    nil
  end
end

W159RecursiveDynamicQualifier.new.run
