# W146 paired native/library oracle for declared Object LowCardinality leaves.
# This script is root-executed under the serial ClickHouse guard; authoring
# workers must not run Crystal or ClickHouse here.
require "file_utils"
require "digest/sha256"
require "json"
require "../src/crystal_click"

class W146ObjectLowCardinalityOracle
  class Mismatch < Exception
  end

  struct Field
    getter name : String
    getter type_name : String
    getter type : CrystalClick::BinaryDataType

    def initialize(@name : String, @type_name : String, @type : CrystalClick::BinaryDataType)
    end
  end

  struct Part
    getter name : String
    getter path : String
    getter rows : UInt64
    getter marks : UInt64

    def initialize(@name : String, @path : String, @rows : UInt64, @marks : UInt64)
    end
  end

  VERSION           = "26.10.1.1201"
  BUILD_HASH        = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
  EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
  SOURCE_ROOT       = "/Users/sergey/SrcArchives/clickhouse-2026-10-03-depth1-9007d227"
  SOURCE_REVISION   = "9007d227b64a3f8b667fc5258ceb2923f3cf477d"

  KEYS          = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
  ROWS_PER_MARK = [2_u64, 2_u64, 2_u64, 1_u64]
  FRAME_BYTES   = 16

  SETTINGS_BASE = "index_granularity=2, index_granularity_bytes=10485760, enable_mixed_granularity_parts=1, min_rows_for_wide_part=0, min_bytes_for_wide_part=0, compress_marks=0, compress_primary_key=0, min_compress_block_size=0, max_compress_block_size=4096, ratio_of_defaults_for_sparse_serialization=1, default_compression_codec='LZ4', object_serialization_version='v3', object_shared_data_serialization_version_for_zero_level_parts='map', propagate_types_serialization_versions_to_nested_types=true, map_serialization_version='basic', map_serialization_version_for_zero_level_parts='basic'"

  EXPECTED_JSON_TYPE = "JSON(max_dynamic_types=1, max_dynamic_paths=1, arr Array(LowCardinality(String)), f LowCardinality(Float32), mp Map(String, LowCardinality(String)), n LowCardinality(UInt64), ns LowCardinality(Nullable(String)), s LowCardinality(String), t Tuple(maybe LowCardinality(Nullable(UInt64)), label String))"

  ROWS = [
    %({"pk":1,"payload":{"arr":["red","blue"],"d":11,"f":1.25,"mp":{"a":"red","b":"blue"},"n":11,"ns":"a","s":"red","t":[null,"t0"],"spill":"alpha"}}),
    %({"pk":2,"payload":{"arr":[],"d":22,"f":-3.5,"mp":{},"n":22,"ns":null,"s":"blue","t":[11,"t1"]}}),
    %({"pk":3,"payload":{"arr":["red"],"d":11,"f":1.25,"mp":{"a":"red"},"n":11,"ns":"a","s":"red","t":[null,"t2"]}}),
    %({"pk":4,"payload":{"arr":["green",""],"d":33,"f":0.0,"mp":{"a":"green","c":""},"n":33,"ns":"","s":"","t":[33,"t3"]}}),
    %({"pk":5,"payload":{"arr":["blue","red"],"d":22,"f":1.25,"mp":{"b":"blue"},"n":22,"ns":null,"s":"green","t":[22,"t4"]}}),
    %({"pk":6,"payload":{"arr":[""],"d":44,"f":-3.5,"mp":{"a":""},"n":44,"ns":"b","s":"blue","t":[null,"t5"]}}),
    %({"pk":7,"payload":{"arr":["雪"],"d":11,"f":2.5,"mp":{"z":"雪"},"n":11,"ns":"a","s":"雪","t":[44,"t6"],"spill":"omega"}}),
  ]

  alias DataType = CrystalClick::BinaryDataType
  alias Value = CrystalClick::BinaryValue
  alias Document = CrystalClick::ObjectDocument

  @manifest_rows : Array(String)

  private def fail(message : String) : NoReturn
    raise Mismatch.new(message)
  end

  private def assert(condition : Bool, message : String) : Nil
    fail(message) unless condition
  end

  private def expect_mismatch(label : String, &)
    begin
      yield
    rescue error : Mismatch
      puts "PASS W146 seeded comparator rejection: #{label}"
      return
    end
    fail("#{label}: seeded mismatch passed the oracle comparator")
  end

  private def process_env : Hash(String, String)
    environment = ENV.to_h
    environment["TZ"] = "UTC"
    environment
  end

  private def command_output(binary : String, arguments : Array(String)) : String
    output = IO::Memory.new
    error = IO::Memory.new
    status = Process.run(binary, arguments, env: process_env, output: output, error: error)
    raise "command failed: #{binary} #{arguments.join(" ")}\n#{error}" unless status.success?
    output.to_s
  end

  private def execute(
    binary : String, store : String, query : String, evidence : String, input : String? = nil,
  ) : String
    arguments = [
      "local", "--path", store, "--session_timezone=UTC", "--enable_time_time64_type=1",
      "--print_pretty_type_names=0", "--allow_suspicious_low_cardinality_types=1", "--query", query,
    ]
    output = IO::Memory.new
    error = IO::Memory.new
    status = if body = input
               Process.run(binary, arguments, env: process_env, input: IO::Memory.new(body), output: output, error: error)
             else
               Process.run(binary, arguments, env: process_env, output: output, error: error)
             end
    File.write("#{evidence}.stdout", output.to_s)
    File.write("#{evidence}.stderr", error.to_s)
    raise "ClickHouse local query failed (#{evidence}): #{error}\n#{query}" unless status.success?
    output.to_s
  end

  private def var_uint(io : IO, value : UInt64) : Nil
    remaining = value
    while remaining >= 0x80_u64
      io.write_byte((remaining & 0x7f_u64).to_u8 | 0x80_u8)
      remaining >>= 7
    end
    io.write_byte(remaining.to_u8)
  end

  private def uint_bytes(value : UInt64, width : Int) : Bytes
    Bytes.new(width) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
  end

  private def float32_bits(value : Float64) : UInt32
    case value
    when 1.25 then 0x3fa0_0000_u32
    when -3.5 then 0xc060_0000_u32
    when  0.0 then 0x0000_0000_u32
    when  2.5 then 0x4020_0000_u32
    else
      fail("W146 fixture contains an unrecognized Float32 literal #{value}")
    end
  end

  private def fields : Array(Field)
    string = DataType.primitive("String")
    nullable_string = DataType.nullable(string)
    nullable_uint64 = DataType.nullable(DataType.primitive("UInt64"))
    low_string = DataType.low_cardinality(string)
    low_nullable_string = DataType.low_cardinality(nullable_string)
    low_uint64 = DataType.low_cardinality(DataType.primitive("UInt64"))
    low_float32 = DataType.low_cardinality(DataType.primitive("Float32"))
    low_nullable_uint64 = DataType.low_cardinality(nullable_uint64)
    array_string = DataType.array(low_string)
    map_string = DataType.map(string, low_string)
    named_tuple = DataType.tuple(
      [low_nullable_uint64, string] of DataType,
      ["maybe", "label"] of String,
    )
    [
      Field.new("arr", "Array(LowCardinality(String))", array_string),
      Field.new("f", "LowCardinality(Float32)", low_float32),
      Field.new("mp", "Map(String, LowCardinality(String))", map_string),
      Field.new("n", "LowCardinality(UInt64)", low_uint64),
      Field.new("ns", "LowCardinality(Nullable(String))", low_nullable_string),
      Field.new("s", "LowCardinality(String)", low_string),
      Field.new("t", "Tuple(maybe LowCardinality(Nullable(UInt64)), label String)", named_tuple),
    ]
  end

  private def expected_declaration(roster : Array(Field)) : String
    "JSON(max_dynamic_types=1, max_dynamic_paths=1, #{roster.map { |field| "#{field.name} #{field.type_name}" }.join(", ")})"
  end

  private def schema_for(roster : Array(Field)) : CrystalClick::ObjectDocumentSchema
    typed = {} of String => DataType
    roster.each { |field| typed[field.name] = field.type }
    schema = CrystalClick::ObjectDocumentSchema.new(typed, max_dynamic_paths: 1, max_dynamic_types: 1)
    expected = expected_declaration(roster)
    assert(schema.declaration == expected, "Object schema declaration differs from the exact W146 roster: #{schema.declaration.inspect}")
    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(expected)
    assert(parsed.declaration == expected && parsed.typed_paths == schema.typed_paths,
      "Object JSON declaration parser changed W146 typed nominal identities")
    schema
  end

  private def value_for(json : JSON::Any, type : DataType) : Value
    case type.tag
    when DataType::TAG_LOW_CARDINALITY
      Value.low_cardinality(type, value_for(json, type.child_at(0)))
    when DataType::TAG_ARRAY
      children = json.as_a.map { |entry| value_for(entry, type.child_at(0)) }
      Value.array(type, children)
    when DataType::TAG_MAP
      flat = [] of Value
      json.as_h.to_a.sort_by { |entry| entry[0] }.each do |key, child|
        flat << Value.string(key)
        flat << value_for(child, type.child_at(1))
      end
      Value.map(type, flat)
    when DataType::TAG_NAMED_TUPLE, DataType::TAG_UNNAMED_TUPLE
      children = json.as_a
      assert(children.size == type.child_count, "W146 literal tuple arity differs from the declared descriptor")
      Value.tuple(type, children.each_with_index.map { |child, index| value_for(child, type.child_at(index)) }.to_a)
    when DataType::TAG_NULLABLE
      if json.raw.nil?
        Value.nullable(type)
      else
        Value.nullable(type, value_for(json, type.child_at(0)))
      end
    when DataType::TAG_STRING
      Value.string(json.as_s)
    when DataType::TAG_UINT64
      Value.fixed(type, uint_bytes(json.as_i.to_u64, 8))
    when DataType::TAG_FLOAT32
      Value.fixed(type, uint_bytes(float32_bits(json.as_f).to_u64, 4))
    else
      fail("W146 literal builder has no independent mapping for type tag #{type.tag}")
    end
  end

  private def document_at(index : Int32, roster : Array(Field)) : Document
    row = JSON.parse(ROWS[index]).as_h
    payload = row["payload"].as_h
    values = {} of String => Value
    roster.each { |field| values[field.name] = value_for(payload[field.name], field.type) }
    values["d"] = Value.int64(payload["d"].as_i.to_i64)
    if spill = payload["spill"]?
      values["spill"] = Value.string(spill.as_s)
    end
    Document.new(values)
  end

  private def expected_documents(roster : Array(Field)) : Array(Document)
    Array(Document).new(KEYS.size) { |index| document_at(index.to_i32, roster) }
  end

  private def expected_marks(documents : Array(Document)) : Array(Array(Document))
    [documents[0, 2], documents[2, 2], documents[4, 2], documents[6, 1]]
  end

  # Independent RowBinary encoder for only this finite literal grammar. LC is
  # transparent in row-oriented output; its storage dictionary is checked by
  # the part readers, not by this logical-value encoder.
  private def encode_rowbinary(io : IO, value : Value) : Nil
    type = value.type
    case type.tag
    when DataType::TAG_LOW_CARDINALITY
      encode_rowbinary(io, value.element_at(0))
    when DataType::TAG_ARRAY
      var_uint(io, value.element_count.to_u64)
      value.element_count.times { |index| encode_rowbinary(io, value.element_at(index)) }
    when DataType::TAG_MAP
      assert(value.element_count.even?, "literal Map does not contain complete key/value pairs")
      var_uint(io, (value.element_count // 2).to_u64)
      value.element_count.times { |index| encode_rowbinary(io, value.element_at(index)) }
    when DataType::TAG_NAMED_TUPLE, DataType::TAG_UNNAMED_TUPLE
      value.element_count.times { |index| encode_rowbinary(io, value.element_at(index)) }
    when DataType::TAG_NULLABLE
      if value.is_null?
        io.write_byte(1_u8)
      else
        io.write_byte(0_u8)
        encode_rowbinary(io, value.element_at(0))
      end
    when DataType::TAG_STRING
      bytes = value.bytes
      var_uint(io, bytes.size.to_u64)
      io.write(bytes)
    when DataType::TAG_UINT64, DataType::TAG_FLOAT32
      io.write(value.bytes)
    else
      fail("W146 independent RowBinary encoder has no mapping for type tag #{type.tag}")
    end
    nil
  end

  private def expected_rowbinary(indices : Array(Int32), documents : Array(Document), roster : Array(Field)) : String
    String.build do |io|
      indices.each do |index|
        io.write(uint_bytes(KEYS[index], 8))
        roster.each { |field| encode_rowbinary(io, documents[index].value_for(field.name)) }
      end
    end
  end

  private def assert_rowbinary(actual : String, expected : String, label : String) : Nil
    assert(actual.to_slice == expected.to_slice,
      "#{label}: independent literal RowBinary differs (expected #{expected.bytesize} bytes, got #{actual.bytesize})")
  end

  private def assert_value(expected : Value, actual : Value, label : String) : Nil
    assert(expected.type == actual.type, "#{label}: nominal type identity differs")
    assert(expected.is_null? == actual.is_null?, "#{label}: NULL state differs")
    return if expected.is_null?
    tag = expected.type.tag
    if tag == DataType::TAG_LOW_CARDINALITY || tag == DataType::TAG_NULLABLE ||
       tag == DataType::TAG_ARRAY || tag == DataType::TAG_MAP ||
       tag == DataType::TAG_NAMED_TUPLE || tag == DataType::TAG_UNNAMED_TUPLE
      assert(expected.element_count == actual.element_count, "#{label}: child count differs")
      expected.element_count.times do |index|
        assert_value(expected.element_at(index), actual.element_at(index), "#{label}[#{index}]")
      end
    else
      assert(expected.bytes == actual.bytes, "#{label}: exact raw scalar bytes differ")
    end
  end

  private def assert_documents(expected : Array(Document), actual : Array(Document), label : String) : Nil
    assert(expected.size == actual.size, "#{label}: row count differs")
    expected.each_with_index do |document, index|
      observed = actual[index]
      assert(document.paths == observed.paths, "#{label}: path roster differs at row #{index}")
      document.paths.each do |path|
        assert_value(document.value_for(path), observed.value_for(path), "#{label} row #{index} #{path}")
      end
    end
  end

  private def assert_granules(expected : Array(Array(Document)), actual : Array(Array(Document)), label : String) : Nil
    assert(expected.size == actual.size, "#{label}: granule count differs")
    expected.each_with_index { |rows, mark| assert_documents(rows, actual[mark], "#{label} granule #{mark}") }
  end

  private def verify_runtime(binary : String, store : String, evidence : String) : Nil
    digest = command_output("shasum", ["-a", "256", binary]).split(' ').first? || ""
    assert(digest == EXECUTABLE_SHA256, "pinned ClickHouse SHA-256 differs: #{digest}")
    version = execute(binary, store, "SELECT version() FORMAT TSVRaw", "#{evidence}/version").strip
    assert(version == VERSION, "unexpected ClickHouse runtime version #{version.inspect}")
    identity = execute(binary, store,
      "SELECT concat(name, '=', value) FROM system.build_options WHERE name IN ('GIT_HASH','VERSION_GITHASH') ORDER BY name FORMAT TSVRaw",
      "#{evidence}/build-identity")
    expected = "GIT_HASH=#{BUILD_HASH}\nVERSION_GITHASH=#{BUILD_HASH}\n"
    assert(identity == expected, "unexpected ClickHouse runtime build identity #{identity.inspect}")
    File.write("#{evidence}/run.txt", [
      "runtime_version=#{version}", "runtime_sha256=#{digest}", "runtime_build_hash=#{BUILD_HASH}",
      "source_reference_checkout=#{SOURCE_ROOT}", "source_reference_revision=#{SOURCE_REVISION}",
      "source_is_not_asserted_to_build_runtime=true", "timezone=UTC",
    ].join("\n") + "\n")
  end

  private def table_settings(profile_name : String, mode : UInt64) : String
    compact = mode == CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE ? 1 : 0
    "#{SETTINGS_BASE}, use_compact_variant_discriminators_serialization=#{compact}, string_serialization_version='#{profile_name}'"
  end

  private def click(
    binary : String, store : String, query : String, evidence : String, input : String? = nil,
  ) : String
    execute(binary, store, query, evidence, input)
  end

  private def create_table(
    binary : String, store : String, table : String, declaration : String,
    profile_name : String, mode : UInt64, evidence : String, label : String,
  ) : Nil
    settings = table_settings(profile_name, mode)
    ddl = "CREATE TABLE default.#{table} (pk UInt64, payload #{declaration}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings}"
    File.write("#{evidence}/ddl.sql", ddl + ";\n")
    click(binary, store, ddl, "#{evidence}/create")
    columns = click(binary, store,
      "SELECT name, type, position FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw",
      "#{evidence}/system-columns")
    expected = "pk\tUInt64\t1\npayload\t#{EXPECTED_JSON_TYPE}\t2\n"
    assert(columns == expected, "#{label}: exact system.columns schema differs: #{columns.inspect}")
  end

  private def verify_part_path(path : String, store : String, label : String) : String
    real_store = File.realpath(store)
    real_path = File.realpath(path)
    assert(real_path.starts_with?(real_store + "/") && !File.symlink?(path), "#{label}: part path escapes its isolated store")
    cursor = real_store
    real_path[(real_store.size + 1)..].split('/').each do |component|
      cursor = File.join(cursor, component)
      assert(!File.symlink?(cursor), "#{label}: symlink in isolated part path")
    end
    real_path
  end

  private def active_part(binary : String, store : String, table : String, evidence : String, label : String) : Part
    rows = click(binary, store,
      "SELECT name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw",
      "#{evidence}/active-parts").lines.map(&.chomp)
    assert(rows.size == 1, "#{label}: expected one active part, got #{rows.size}")
    columns = rows.first.split('\t')
    assert(columns.size == 5 && columns[2] == "Wide" && columns[3] == "7" && columns[4] == "5",
      "#{label}: expected 7 rows, 4 real granules plus terminal mark record, and Wide part: #{rows.first.inspect}")
    path = verify_part_path(columns[1], store, label)
    assert(File.file?(File.join(path, "checksums.txt")), "#{label}: part lacks checksums.txt")
    inventory = Dir.children(path).sort.map do |name|
      entry = File.join(path, name)
      assert(!File.symlink?(entry) && File.file?(entry), "#{label}: unexpected non-regular part entry #{name.inspect}")
      digest = Digest::SHA256.new
      File.open(entry, "rb") do |io|
        buffer = Bytes.new(64 * 1024)
        while (size = io.read(buffer)) > 0
          digest.update(buffer[0, size])
        end
      end
      "#{digest.final.hexstring}\t#{File.size(entry)}\t#{name}\n"
    end.join
    File.write("#{evidence}/part-files.tsv", inventory)
    Part.new(columns[0], path, columns[3].to_u64, columns[4].to_u64)
  end

  private def assert_check(binary : String, store : String, table : String, evidence : String, label : String, part_name : String) : Nil
    output = click(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated", "#{evidence}/check-table")
    expected = "#{part_name}\t1\t\n"
    assert(output == expected, "#{label}: raw CHECK TABLE output differs: expected #{expected.inspect}, got #{output.inspect}")
  end

  private def type_query(roster : Array(Field)) : String
    roster.map { |field| "toTypeName(payload.#{field.name})" }.join(", ")
  end

  private def assert_type_names(binary : String, store : String, table : String, roster : Array(Field), evidence : String, label : String) : Nil
    actual = click(binary, store,
      "SELECT #{type_query(roster)} FROM default.#{table} ORDER BY pk LIMIT 1 FORMAT TSVRaw", evidence)
    expected = roster.map(&.type_name).join('\t') + "\n"
    assert(actual == expected, "#{label}: canonical nominal path types differ: #{actual.inspect}")
  end

  private def assert_sql_rowbinary(
    binary : String, store : String, table : String, roster : Array(Field), docs : Array(Document),
    result_dir : String, label : String,
  ) : Nil
    projection = (["pk"] + roster.map { |field| "payload.#{field.name}" }).join(", ")
    full_indices = (0...KEYS.size).to_a
    middle_indices = [2, 3]
    expected_full = expected_rowbinary(full_indices, docs, roster)
    expected_middle = expected_rowbinary(middle_indices, docs, roster)
    File.write(File.join(result_dir, "expected-full.rowbinary"), expected_full)
    File.write(File.join(result_dir, "expected-middle.rowbinary"), expected_middle)
    actual_full = click(binary, store,
      "SELECT #{projection} FROM default.#{table} ORDER BY pk FORMAT RowBinary", "#{result_dir}/actual-full")
    actual_middle = click(binary, store,
      "SELECT #{projection} FROM default.#{table} WHERE pk IN (3,4) ORDER BY pk FORMAT RowBinary", "#{result_dir}/actual-middle")
    File.write(File.join(result_dir, "actual-full.rowbinary"), actual_full)
    File.write(File.join(result_dir, "actual-middle.rowbinary"), actual_middle)
    assert_rowbinary(actual_full, expected_full, "#{label} full RowBinary")
    assert_rowbinary(actual_middle, expected_middle, "#{label} middle RowBinary")
  end

  private def assert_dynamic_shared_values(binary : String, store : String, table : String, result_dir : String, label : String) : Nil
    # Restrict to rows where both paths are present so the stock SQL assertion
    # is independent of missing-path conversion defaults. The library readers
    # separately compare the complete seven-row documents, including absence.
    expected = "1\t11\talpha\n7\t11\tomega\n"
    actual = click(binary, store,
      "SELECT pk, CAST(payload.d AS Int64), CAST(payload.spill AS String) FROM default.#{table} WHERE pk IN (1,7) ORDER BY pk FORMAT TSVRaw",
      "#{result_dir}/dynamic-shared-tsv")
    File.write(File.join(result_dir, "expected-dynamic-shared.tsv"), expected)
    File.write(File.join(result_dir, "actual-dynamic-shared.tsv"), actual)
    assert(actual == expected, "#{label}: stock Dynamic/shared present-value projection differs: #{actual.inspect}")
  end

  private def assert_reader(
    part : Part, schema : CrystalClick::ObjectDocumentSchema, roster : Array(Field), docs : Array(Document),
    profile : CrystalClick::BinaryBulkProfile, label : String, evidence : String,
  ) : {Array(String), Array(String)}
    reader = CrystalClick::ObjectColumnReader.open(part.path, "payload", schema)
    assert(reader.row_count == KEYS.size.to_u64, "#{label}: ObjectColumnReader row count differs")
    assert(reader.ordinary_profile == profile, "#{label}: stock ordinary String profile differs")
    grid = reader.mark_row_counts
    assert(grid == ROWS_PER_MARK, "#{label}: real Object mark grid differs: #{grid.inspect}")
    marks = expected_marks(docs)
    assert_granules(marks, reader.read_marks(0, grid.size), "#{label} ObjectColumnReader full")
    assert_granules([marks[1]], reader.read_marks(1, 1), "#{label} ObjectColumnReader middle")
    assert_granules([] of Array(Document), reader.read_marks(grid.size, 0), "#{label} ObjectColumnReader zero")

    full = CrystalClick::ObjectDocumentFileReader.read(
      part.path, "payload", schema.typed_paths, first_mark: 0, mark_count: grid.size,
      profile: profile, shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      hashed: true, limits: CrystalClick::BinaryCodecLimits.default,
      transport_limits: CrystalClick::CompressedStreamLimits.new,
    )
    middle = CrystalClick::ObjectDocumentFileReader.read(
      part.path, "payload", schema.typed_paths, first_mark: 1, mark_count: 1,
      profile: profile, shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      hashed: true, limits: CrystalClick::BinaryCodecLimits.default,
      transport_limits: CrystalClick::CompressedStreamLimits.new,
    )
    zero = CrystalClick::ObjectDocumentFileReader.read(
      part.path, "payload", schema.typed_paths, first_mark: grid.size, mark_count: 0,
      profile: profile, shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      hashed: true, limits: CrystalClick::BinaryCodecLimits.default,
      transport_limits: CrystalClick::CompressedStreamLimits.new,
    )
    assert_granules(marks, full, "#{label} ObjectDocumentFileReader full")
    assert_granules([marks[1]], middle, "#{label} ObjectDocumentFileReader middle")
    assert_granules([] of Array(Document), zero, "#{label} ObjectDocumentFileReader zero")

    plan = object_plan(schema)
    physical = CrystalClick::ObjectDocumentPhysicalPlan.new(
      "payload", plan, profile, CrystalClick::BinaryBulkProfile.single_stream,
    )
    descriptor = CrystalClick::ObjectDocumentFileReader.inspect(
      part.path, "payload", schema.typed_paths, profile,
      CrystalClick::BinaryBulkProfile.single_stream, true,
    )
    assert(descriptor.row_count == part.rows && descriptor.mark_row_counts == ROWS_PER_MARK,
      "#{label}: inspected Object descriptor row/mark grid differs")
    assert(descriptor.plan.typed_paths == schema.typed_paths && roster.all? { |field| descriptor.plan.typed_type_for(field.name) == field.type },
      "#{label}: Object descriptor changed declared nominal typed paths")
    object = descriptor.plan.structures.object
    assert(object.version == 4_u64 && object.shared_data_version == 0_u64 && object.bucket_count == 1_u64,
      "#{label}: part is not Object V3 / MAP / one bucket")
    assert(descriptor.plan.structures.dynamic_count == 1 && descriptor.plan.structures.object.dynamic_paths == ["d"],
      "#{label}: Dynamic Object roster differs")
    assert(descriptor.plan.structures.dynamics["d"].types == [DataType.primitive("Int64")],
      "#{label}: Dynamic d arm is not Int64")

    actual_names = reader.physical_stream_names
    expected_names = physical.stream_names
    actual_names.sort!
    expected_names.sort!
    assert(actual_names == expected_names, "#{label}: physical columns_substreams inventory differs from the LC-aware plan")
    checksums = reader.selected_checksum_names
    expected_checksums = [] of String
    expected_names.each do |logical|
      hashed = CrystalClick::StreamName.hash(logical)
      expected_checksums << "#{hashed}.bin"
      expected_checksums << "#{hashed}.mrk2"
    end
    expected_checksums.sort!
    assert(checksums == expected_checksums, "#{label}: actual selected hashed data/mark roster differs")
    entries = Dir.children(part.path)
    checksums.each do |name|
      assert(entries.includes?(name) && File.file?(File.join(part.path, name)), "#{label}: selected physical file is missing #{name}")
    end
    assert(entries.any?(&.ends_with?(".mrk2")) && entries.none?(&.ends_with?(".cmrk2")),
      "#{label}: part is not using the pinned plain adaptive .mrk2 profile")
    File.write(File.join(evidence, "logical-streams.txt"), expected_names.join("\n") + "\n")
    File.write(File.join(evidence, "selected-checksums.txt"), expected_checksums.join("\n") + "\n")
    {expected_names, expected_checksums}
  end

  private def collect_table_window(table : CrystalClick::WidePartTable, start_row : UInt64, max_rows : Int) : {Array(UInt64), Array(Document)}
    keys = [] of UInt64
    docs = [] of Document
    table.scan_typed_window(start_row, max_rows) do |batch|
      keys.concat(batch.values_for("pk").to_a)
      docs.concat(batch.object_documents_for("payload").to_a)
      nil
    end
    {keys, docs}
  end

  private def assert_windows(
    window_reader : Proc(UInt64, Int32, Tuple(Array(UInt64), Array(Document))), docs : Array(Document), label : String,
  ) : Nil
    full_keys, full_docs = window_reader.call(0_u64, KEYS.size)
    assert(full_keys == KEYS, "#{label} full window primary keys differ")
    assert_documents(docs, full_docs, "#{label} full window")
    middle_keys, middle_docs = window_reader.call(2_u64, 2)
    assert(middle_keys == [3_u64, 4_u64], "#{label} middle window primary keys differ")
    assert_documents([docs[2], docs[3]], middle_docs, "#{label} middle window")
    zero_keys, zero_docs = window_reader.call(KEYS.size.to_u64, 1)
    assert(zero_keys.empty? && zero_docs.empty?, "#{label} zero-row window emitted data")
  end

  private def catalog_root(root : String, label : String, number : Int32, part : Part, declaration : String) : {String, String}
    catalog = File.join(root, "catalog", label)
    assert(!File.exists?(catalog) && !File.symlink?(File.dirname(catalog)), "#{label}: catalog destination exists or is unsafe")
    metadata = File.join(catalog, "metadata")
    FileUtils.mkdir_p(metadata)
    FileUtils.mkdir_p(File.join(catalog, "store"))
    database_uuid = "14600000-0000-4000-8000-000000000001"
    suffix = number.to_s.rjust(12, '0')
    table_uuid = "14610000-0000-4000-8000-#{suffix}"
    File.write(File.join(metadata, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
    database_dir = File.join(catalog, "store", database_uuid[0, 3], database_uuid)
    FileUtils.mkdir_p(database_dir)
    File.write(File.join(database_dir, "events.sql"),
      "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` #{declaration}\n)\nENGINE = MergeTree\nORDER BY `pk`\n")
    table_dir = File.join(catalog, "store", table_uuid[0, 3], table_uuid)
    FileUtils.mkdir_p(table_dir)
    FileUtils.mkdir_p(File.join(table_dir, "detached"))
    File.write(File.join(table_dir, "format_version.txt"), "1\n")
    destination = File.join(table_dir, part.name)
    assert(!File.exists?(destination) && !File.symlink?(destination), "#{label}: catalog part destination is occupied")
    FileUtils.cp_r(part.path, destination)
    {catalog, File.realpath(destination)}
  end

  private def collect_offline_window(table : CrystalClick::OfflineTable, start_row : UInt64, max_rows : Int) : {Array(UInt64), Array(Document)}
    keys = [] of UInt64
    docs = [] of Document
    table.scan_typed_window(["pk", "payload"], start_row, max_rows) do |batch|
      keys.concat(batch.values_for("pk").to_a)
      docs.concat(batch.object_documents_for("payload").to_a)
      nil
    end
    {keys, docs}
  end

  private def assert_catalog(catalog_root : String, catalog_part : String, part : Part, docs : Array(Document), label : String) : Nil
    catalog = CrystalClick::OfflineCatalog.open(catalog_root)
    selection = catalog["lab"]["events"]["payload"]
    values = selection.values.map(&.as(Document))
    assert_documents(docs, values, "#{label} OfflineCatalog full values")
    table = catalog.table("lab", "events")
    candidates = table.resolved_scan_parts
    assert(candidates.map(&.name) == [part.name] && candidates.first.path == catalog_part,
      "#{label}: detached catalog part resolution differs")
    assert_windows(
      ->(start_row : UInt64, count : Int32) { collect_offline_window(table, start_row, count) },
      docs, "#{label} OfflineCatalog table",
    )
  end

  private def assert_library_table_windows(part : Part, docs : Array(Document), label : String) : Nil
    table = CrystalClick::WidePartTable.open_selected_typed([part.path], ["pk", "payload"])
    assert_windows(
      ->(start_row : UInt64, count : Int32) { collect_table_window(table, start_row, count) },
      docs, "#{label} WidePartTable",
    )
  end

  private def assert_native_table_windows(part : Part, docs : Array(Document), label : String) : Nil
    assert_library_table_windows(part, docs, label)
  end

  private def replace_field(document : Document, path : String, replacement : Value) : Document
    values = {} of String => Value
    document.paths.each { |name| values[name] = name == path ? replacement : document.value_for(name) }
    Document.new(values)
  end

  private def assert_comparator_controls(roster : Array(Field), docs : Array(Document)) : Nil
    original = docs[0].value_for("n")
    altered = Value.low_cardinality(original.type, Value.uint64(999_u64))
    wrong = replace_field(docs[0], "n", altered)
    expect_mismatch("LC(UInt64) nested logical value") do
      assert_documents([docs[0]], [wrong], "W146 seeded LC value mismatch")
    end
    wrong_docs = docs.dup
    wrong_docs[0] = wrong
    expected = expected_rowbinary((0...KEYS.size).to_a, docs, roster)
    altered_binary = expected_rowbinary((0...KEYS.size).to_a, wrong_docs, roster)
    expect_mismatch("literal RowBinary changes for n[0]=999") do
      assert_rowbinary(altered_binary, expected, "W146 seeded LC RowBinary mutation")
    end
  end

  private def write_library_part(
    part_path : String, schema : CrystalClick::ObjectDocumentSchema,
    docs : Array(Document), profile : CrystalClick::BinaryBulkProfile, mode : UInt64,
  ) : String
    CrystalClick::WidePartWriter.write_uint64_object_pair(
      part_path, "pk", Slice(UInt64).new(KEYS.size) { |index| KEYS[index] },
      "payload", schema, object_plan(schema), expected_marks(docs), rows_per_mark: 2,
      mode: mode, profile: profile, shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      frame_bytes: FRAME_BYTES,
    )
  end

  private def table_data_path(binary : String, store : String, table : String, evidence : String) : String
    path = click(binary, store,
      "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw",
      evidence).strip
    real = verify_part_path(path, store, "#{table} data path")
    assert(Dir.exists?(real), "#{table}: table data path is missing")
    real
  end

  private def attach_library_part(
    binary : String, store : String, table : String, data_path : String, roster : Array(Field),
    schema : CrystalClick::ObjectDocumentSchema, docs : Array(Document), profile : CrystalClick::BinaryBulkProfile,
    mode : UInt64, evidence : String, label : String,
  ) : Part
    active_before = click(binary, store,
      "SELECT count() FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw",
      "#{evidence}/active-before").strip
    assert(active_before == "0", "#{label}: target table is not empty before writing a library-owned part")
    detached = File.join(data_path, "detached")
    FileUtils.mkdir_p(detached)
    part_name = "all_1_1_0"
    part_path = File.join(detached, part_name)
    assert(!File.exists?(part_path) && !File.symlink?(part_path), "#{label}: library part destination is already occupied")
    write_library_part(part_path, schema, docs, profile, mode)
    verify_part_path(part_path, store, "#{label} library part")
    click(binary, store, "ALTER TABLE default.#{table} ATTACH PART '#{part_name}'", "#{evidence}/attach")
    part = active_part(binary, store, table, evidence, label)
    assert(part.name == part_name, "#{label}: stock ATTACH changed the library part identity")
    assert_check(binary, store, table, evidence, label, part.name)
    part
  end

  private def make_cell_dirs(root : String, label : String) : {String, String}
    store = File.join(root, "stores", label)
    evidence = File.join(root, "results", label)
    FileUtils.mkdir_p(store)
    FileUtils.mkdir_p(evidence)
    {store, evidence}
  end

  private def finish_cell(
    root : String, label : String, direction : String, profile_name : String, mode_name : String,
    store : String, table : String, part : Part, catalog : String, catalog_part : String,
  ) : Nil
    @manifest_rows << [label, direction, profile_name, mode_name, store, table, part.path, catalog, catalog_part].join('\t')
    File.write(File.join(root, "cells.tsv"),
      "label\tdirection\tstring_profile\tdynamic_mode\tstore\ttable\tpart_path\tcatalog_root\tcatalog_part_path\n" +
      @manifest_rows.join("\n") + "\n")
  end

  private def native_cell(
    binary : String, root : String, roster : Array(Field), schema : CrystalClick::ObjectDocumentSchema,
    docs : Array(Document), profile_name : String, profile : CrystalClick::BinaryBulkProfile,
    mode_name : String, mode : UInt64, number : Int32,
  ) : Nil
    label = "native_#{profile_name}_#{mode_name}"
    store, evidence = make_cell_dirs(root, label)
    declaration = schema.declaration
    create_table(binary, store, "p", declaration, profile_name, mode, evidence, label)
    rows_json = ROWS.join("\n") + "\n"
    File.write(File.join(evidence, "input.jsonl"), rows_json)
    click(binary, store, "INSERT INTO default.p FORMAT JSONEachRow", "#{evidence}/insert", rows_json)
    part = active_part(binary, store, "p", evidence, label)
    assert_check(binary, store, "p", evidence, label, part.name)
    assert_type_names(binary, store, "p", roster, "#{evidence}/type-names", label)
    assert_sql_rowbinary(binary, store, "p", roster, docs, evidence, label)
    assert_dynamic_shared_values(binary, store, "p", evidence, label)
    assert_reader(part, schema, roster, docs, profile, label, evidence)
    assert_native_table_windows(part, docs, label)
    catalog, catalog_part = catalog_root(root, label, number, part, declaration)
    assert_catalog(catalog, catalog_part, part, docs, label)
    finish_cell(root, label, "native JSONEachRow -> library readers", profile_name, mode_name,
      store, "default.p", part, catalog, catalog_part)
    puts "PASS W146 native JSONEachRow -> LC-aware Object reader/table/catalog: #{label}"
  end

  private def library_cell(
    binary : String, root : String, roster : Array(Field), schema : CrystalClick::ObjectDocumentSchema,
    docs : Array(Document), profile_name : String, profile : CrystalClick::BinaryBulkProfile,
    mode_name : String, mode : UInt64, number : Int32,
  ) : Nil
    label = "library_#{profile_name}_#{mode_name}"
    store, evidence = make_cell_dirs(root, label)
    declaration = schema.declaration
    create_table(binary, store, "p", declaration, profile_name, mode, evidence, label)
    data_path = table_data_path(binary, store, "p", "#{evidence}/table-data-path")
    part = attach_library_part(binary, store, "p", data_path, roster, schema, docs, profile, mode, evidence, label)
    assert_type_names(binary, store, "p", roster, "#{evidence}/type-names", label)
    assert_sql_rowbinary(binary, store, "p", roster, docs, evidence, label)
    assert_dynamic_shared_values(binary, store, "p", evidence, label)
    assert_reader(part, schema, roster, docs, profile, label, evidence)
    assert_library_table_windows(part, docs, label)
    catalog, catalog_part = catalog_root(root, label, number, part, declaration)
    assert_catalog(catalog, catalog_part, part, docs, label)
    finish_cell(root, label, "library-owned part -> stock ATTACH", profile_name, mode_name,
      store, "default.p", part, catalog, catalog_part)
    if profile_name == "single_stream" && mode_name == "basic"
      seeded_wrong_lc_control(binary, root, roster, schema, docs, profile_name, profile, mode)
    end
    puts "PASS W146 library-owned Object part -> stock ATTACH/CHECK + LC-aware readers: #{label}"
  end

  private def seeded_wrong_lc_control(
    binary : String, root : String, roster : Array(Field), schema : CrystalClick::ObjectDocumentSchema,
    docs : Array(Document), profile_name : String, profile : CrystalClick::BinaryBulkProfile,
    mode : UInt64,
  ) : Nil
    label = "seeded_wrong_lc_n999"
    store, evidence = make_cell_dirs(root, label)
    create_table(binary, store, "p", schema.declaration, profile_name, mode, evidence, label)
    data_path = table_data_path(binary, store, "p", "#{evidence}/table-data-path")
    wrong_docs = docs.dup
    original_n = docs[0].value_for("n")
    wrong_docs[0] = replace_field(
      docs[0], "n", Value.low_cardinality(original_n.type, Value.uint64(999_u64)),
    )
    part = attach_library_part(binary, store, "p", data_path, roster, schema, wrong_docs, profile, mode, evidence, label)
    assert_type_names(binary, store, "p", roster, "#{evidence}/type-names", label)
    projection = (["pk"] + roster.map { |field| "payload.#{field.name}" }).join(", ")
    actual = click(binary, store,
      "SELECT #{projection} FROM default.p ORDER BY pk FORMAT RowBinary", "#{evidence}/actual-rowbinary")
    original = expected_rowbinary((0...KEYS.size).to_a, docs, roster)
    wrong_expected = expected_rowbinary((0...KEYS.size).to_a, wrong_docs, roster)
    assert(actual.to_slice == wrong_expected.to_slice, "#{label}: stock RowBinary does not equal the seeded LC(UInt64)=999 literal")
    expect_mismatch("stock accepts/checks altered LC UInt64 but literal original comparator rejects") do
      assert_rowbinary(actual, original, "#{label} original expected RowBinary")
    end
    puts "PASS W146 valid-wrong LC part: stock ATTACH/CHECK accepted #{part.name}; n[0]=999 changes exact literal RowBinary"
    nil
  end

  private def object_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
    int64 = DataType.primitive("Int64")
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["d"] of String),
      {"d" => CrystalClick::DynamicStructure.new([int64])} of String => CrystalClick::DynamicStructure,
    )
    CrystalClick::ObjectDocumentPlan.new(structures, schema.typed_paths)
  end

  private def validate_fixture(roster : Array(Field), docs : Array(Document)) : Nil
    assert(roster.map(&.name) == ["arr", "f", "mp", "n", "ns", "s", "t"], "W146 typed field roster changed")
    assert(KEYS.size == ROWS.size && ROWS_PER_MARK == [2_u64, 2_u64, 2_u64, 1_u64], "W146 literal row/grid roster changed")
    ROWS.each_with_index do |row, index|
      parsed = JSON.parse(row).as_h
      assert(parsed["pk"].as_i.to_u64 == KEYS[index], "W146 fixture primary-key order differs at #{index}")
      payload = parsed["payload"].as_h
      assert(payload.keys.includes?("d"), "W146 fixture is missing dynamic d at row #{index}")
      assert(!payload.keys.includes?("spill") || payload["spill"].as_s == (index == 0 ? "alpha" : "omega"),
        "W146 fixture spill value differs at row #{index}")
    end
    assert(docs.size == 7, "W146 expected document count differs")
  end

  private def safe_output_root?(root : String) : Bool
    prefix = "/private/tmp/crystal-click-object-low-cardinality-w146-paired."
    return false unless root.starts_with?(prefix) && root.bytesize > prefix.bytesize
    suffix = root.byte_slice(prefix.bytesize, root.bytesize - prefix.bytesize)
    suffix.each_byte.all? do |byte|
      (byte >= 0x41_u8 && byte <= 0x5a_u8) ||
        (byte >= 0x61_u8 && byte <= 0x7a_u8) ||
        (byte >= 0x30_u8 && byte <= 0x39_u8) ||
        byte == 0x5f_u8 || byte == 0x2d_u8
    end
  end

  private def validate_root(root : String) : String
    assert(Dir.exists?(root) && !File.symlink?(root), "W146 paired output root must be an existing non-symlink directory")
    canonical = File.realpath(root)
    assert(canonical == root, "W146 paired output root is not canonical")
    assert(safe_output_root?(root), "W146 paired output root escaped the direct /private/tmp namespace")
    %w[stores results catalog cells.tsv run.txt].each do |child|
      path = File.join(root, child)
      assert(!File.exists?(path) && !File.symlink?(path), "W146 paired output already exists: #{path}")
    end
    root
  end

  def initialize
    @manifest_rows = [] of String
  end

  def check : Nil
    raise "refusing W146 native paired oracle without root-owned W146_EXECUTE_AS_ROOT=YES" unless ENV["W146_EXECUTE_AS_ROOT"]? == "YES"
    root_arg = ENV["W146_PAIR_ROOT"]? || raise "W146_PAIR_ROOT must name a fresh paired evidence directory"
    root = validate_root(root_arg)
    binary = ENV["CLICKHOUSE_BIN"]? || "/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped"
    assert(File.file?(binary) && File.executable?(binary) && !File.symlink?(binary), "pinned ClickHouse executable is unavailable: #{binary}")
    Dir.mkdir(File.join(root, "stores"), 0o700)
    Dir.mkdir(File.join(root, "results"), 0o700)
    Dir.mkdir(File.join(root, "catalog"), 0o700)
    identity_store = File.join(root, "stores", "identity")
    Dir.mkdir(identity_store, 0o700)
    File.write(File.join(root, "results", "fixture.jsonl"), ROWS.join("\n") + "\n")

    roster = fields
    schema = schema_for(roster)
    docs = expected_documents(roster)
    validate_fixture(roster, docs)
    verify_runtime(binary, identity_store, File.join(root, "results"))
    File.write(File.join(root, "results", "frontier.txt"), <<-TEXT
      source_reference=#{SOURCE_ROOT}@#{SOURCE_REVISION}
      runtime=#{VERSION} build=#{BUILD_HASH} sha256=#{EXECUTABLE_SHA256}
      claim_scope=declared Object LowCardinality typed leaves in JSON V3 Wide MAP one-bucket parts
      matrices=native JSONEachRow -> owned reader; library-owned full part -> stock ATTACH/CHECK
      axes=7 typed LC fields; 7 rows; 4 real granules [2,2,2,1]; terminal mark record is not a row granule
      dynamic_limits=max_dynamic_paths=1,max_dynamic_types=1
      dynamic=d Int64 ordinary arm plus optional spill SharedVariant; mode BASIC/COMPACT
      string_profiles=single_stream/with_size_stream; shared Object String profile remains single_stream
      map_profile=BASIC; Map WITH_BUCKETS and Compact part formats are outside this helper
      writer_scope=independently owned part, no borrowed stock part envelope
    TEXT
    )

    profiles = [
      {"single_stream", CrystalClick::BinaryBulkProfile.single_stream},
      {"with_size_stream", CrystalClick::BinaryBulkProfile.with_size_stream},
    ]
    modes = [
      {"basic", CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE},
      {"compact", CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE},
    ]
    cell_number = 1
    profiles.each do |profile_name, profile|
      modes.each do |mode_name, mode|
        native_cell(binary, root, roster, schema, docs, profile_name, profile, mode_name, mode, cell_number)
        cell_number += 1
      end
    end
    profiles.each do |profile_name, profile|
      modes.each do |mode_name, mode|
        library_cell(binary, root, roster, schema, docs, profile_name, profile, mode_name, mode, cell_number)
        cell_number += 1
      end
    end
    assert(@manifest_rows.size == 8, "W146 manifest does not contain exactly eight main cells")
    assert_comparator_controls(roster, docs)
    File.write(File.join(root, "results", "summary.txt"), <<-TEXT
      PASS native JSONEachRow / library-owned part × String profile × Dynamic discriminator matrix (8 cells)
      PASS full, middle, and empty selected reads via ObjectColumnReader, ObjectDocumentFileReader, WidePartTable, and OfflineCatalog
      PASS independent literal RowBinary oracle and exact canonical nominal types/raw CHECK for every cell
      PASS exact stock values for present Dynamic d and shared spill rows; library full-document comparison also checks absent spill paths
      PASS seeded LC(UInt64) n[0]=999 part accepted by stock ATTACH/CHECK and rejected by original-value comparator
      residual=does not claim Compact parts, MAP WITH_BUCKETS, wider LC/Object type intersection, or performance coverage
    TEXT
    )
    puts "PASS W146 paired declared Object LowCardinality oracle: #{root}"
  end
end

W146ObjectLowCardinalityOracle.new.check
