# W151 bounded declared-Variant whole-part falsifier.
# Root-owned execution only; the stock executable and shallow source checkout
# are pinned independently. This does not claim a ClickHouse source build.
require "file_utils"
require "digest/sha256"
require "../src/crystal_click"

class W151ObjectVariantOracle
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
  SOURCE_ROOT       = "/Users/sergey/SrcArchives/clickhouse-2026-10-04-depth1-37a251ff"
  SOURCE_REVISION   = "37a251ffa2805b33201486306db980bfa96d73e7"

  KEYS           = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
  ROWS_PER_MARK  = [2_u64, 2_u64, 2_u64]
  FRAME_BYTES    = 16
  ARTIFACT_LIMIT = 8 * 1024 * 1024

  SETTINGS_BASE = "index_granularity=2, index_granularity_bytes=10485760, enable_mixed_granularity_parts=1, min_rows_for_wide_part=0, min_bytes_for_wide_part=0, compress_marks=0, compress_primary_key=0, min_compress_block_size=0, max_compress_block_size=4096, ratio_of_defaults_for_sparse_serialization=1, default_compression_codec='LZ4', object_serialization_version='v3', object_shared_data_serialization_version='map', object_shared_data_serialization_version_for_zero_level_parts='map', propagate_types_serialization_versions_to_nested_types=true, map_serialization_version='basic', map_serialization_version_for_zero_level_parts='basic'"

  ROWS = [
    %({"pk":1,"j":{"aav":[],"av":[],"d":11,"mv":{"one":"alpha"},"nested":null,"ntv":null,"tv":null,"v":null}}),
    %({"pk":2,"j":{"aav":[[[1,2],3],[]],"av":["alpha",2],"d":22,"mv":{"a":2,"z":"two"},"nested":["nested2",200],"ntv":["inner2","note2"],"tv":["row2",22],"v":42,"spill":"spill-two"}}),
    %({"pk":3,"j":{"aav":[[],[[9]]],"av":["alpha",3],"d":33,"mv":{},"nested":300,"ntv":[3,"note3"],"tv":33,"v":"three"}}),
    %({"pk":4,"j":{"aav":[[[]]],"av":["mid"],"d":44,"mv":{"b":4},"nested":[],"ntv":null,"tv":44,"v":[4,5],"spill":"spill-four"}}),
    %({"pk":5,"j":{"aav":[],"av":["last",5],"d":55,"mv":{"z":"five"},"nested":[null,"nested5"],"ntv":[null,"note5"],"tv":["row5",55],"v":null}}),
    %({"pk":6,"j":{"aav":[[6,[6]]],"av":[6],"d":66,"mv":{"a":18446744073709551615},"nested":600,"ntv":["six","note6"],"tv":66,"v":18446744073709551615,"spill":"spill-six"}}),
  ]

  alias DataType = CrystalClick::BinaryDataType
  alias Value = CrystalClick::BinaryValue
  alias Document = CrystalClick::ObjectDocument

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
      puts "PASS W151 comparator sensitivity: #{label}"
      return
    end
    fail("#{label}: altered value passed the original literal comparator")
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
    sql_path = "#{evidence}.sql"
    stdout_path = "#{evidence}.stdout"
    stderr_path = "#{evidence}.stderr"
    [sql_path, stdout_path, stderr_path].each do |path|
      assert(!File.exists?(path) && !File.symlink?(path), "refusing to overwrite evidence file #{path}")
    end
    File.write(sql_path, query + ";\n")
    arguments = [
      "local", "--path", store, "--session_timezone=UTC", "--enable_time_time64_type=1",
      "--print_pretty_type_names=0", "--allow_suspicious_variant_types=1",
      "--allow_suspicious_low_cardinality_types=1", "--max_threads=1",
      "--max_memory_usage=536870912", "--query", query,
    ]
    output = IO::Memory.new
    error = IO::Memory.new
    status = if body = input
               Process.run(binary, arguments, env: process_env, input: IO::Memory.new(body), output: output, error: error)
             else
               Process.run(binary, arguments, env: process_env, output: output, error: error)
             end
    File.write(stdout_path, output.to_s)
    File.write(stderr_path, error.to_s)
    assert(File.size(sql_path) <= ARTIFACT_LIMIT && File.size(stdout_path) <= ARTIFACT_LIMIT &&
           File.size(stderr_path) <= ARTIFACT_LIMIT, "evidence artifact exceeded the 8 MiB bound")
    raise "ClickHouse local query failed (#{evidence}): #{error}\n#{query}" unless status.success?
    output.to_s
  end

  private def le(value : UInt64, width : Int) : Bytes
    Bytes.new(width) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
  end

  private def uint8(value : UInt8) : Value
    Value.fixed(DataType.primitive("UInt8"), Bytes[value])
  end

  private def uint32(value : UInt32) : Value
    Value.fixed(DataType.primitive("UInt32"), le(value.to_u64, 4))
  end

  private def variant_index(type : DataType, arm_name : String) : Int32
    type.child_count.times do |index|
      return index.to_i32 if type.child_at(index).name == arm_name
    end
    fail("#{type.name}: expected canonical arm #{arm_name.inspect} is absent")
  end

  private def arm(type : DataType, arm_name : String, child : Value) : Value
    Value.variant(type, variant_index(type, arm_name), child)
  end

  private def null_variant(type : DataType) : Value
    Value.variant_null(type)
  end

  private def array(type : DataType, children : Array(Value)) : Value
    Value.array(type, children)
  end

  private def low(type : DataType, child : Value) : Value
    Value.low_cardinality(type, child)
  end

  private def nullable(type : DataType, child : Value? = nil) : Value
    Value.nullable(type, child)
  end

  private def fields : Array(Field)
    string = DataType.primitive("String")
    uint8_type = DataType.primitive("UInt8")
    uint32_type = DataType.primitive("UInt32")
    uint64 = DataType.primitive("UInt64")
    variant_string_u64 = DataType.variant([string, uint64] of DataType)
    variant_array_u64 = DataType.variant([DataType.array(uint8_type), uint64] of DataType)
    variant_array_string_u64 = DataType.variant([DataType.array(uint8_type), string, uint64] of DataType)
    lc_string = DataType.low_cardinality(string)
    variant_lc_string_u64 = DataType.variant([lc_string, uint64] of DataType)
    named_tuple = DataType.tuple(
      [string, uint32_type] of DataType,
      ["label", "score"] of String,
    )
    variant_tuple_u64 = DataType.variant([named_tuple, uint64] of DataType)
    inner_variant = DataType.variant([string, uint64] of DataType)
    nested_variant = DataType.variant([DataType.array(inner_variant), uint64] of DataType)
    nullable_tuple = DataType.nullable(DataType.tuple(
      [variant_string_u64, string] of DataType,
      ["v", "note"] of String,
    ))
    aav_type = DataType.array(DataType.array(variant_array_u64))
    av_type = DataType.array(variant_lc_string_u64)
    mv_type = DataType.map(string, variant_string_u64)
    declaration_types = [
      Field.new("aav", "Array(Array(Variant(Array(UInt8), UInt64)))", aav_type),
      Field.new("av", "Array(Variant(LowCardinality(String), UInt64))", av_type),
      Field.new("mv", "Map(String, Variant(String, UInt64))", mv_type),
      Field.new("nested", "Variant(Array(Variant(String, UInt64)), UInt64)", nested_variant),
      Field.new("ntv", "Nullable(Tuple(v Variant(String, UInt64), note String))", nullable_tuple),
      Field.new("tv", "Variant(Tuple(label String, score UInt32), UInt64)", variant_tuple_u64),
      Field.new("v", "Variant(Array(UInt8), String, UInt64)", variant_array_string_u64),
    ]
    assert(variant_index(variant_array_string_u64, "Array(UInt8)") == 0 &&
           variant_index(variant_array_string_u64, "String") == 1 &&
           variant_index(variant_array_string_u64, "UInt64") == 2,
      "canonical nominal-order witness for Variant(Array(UInt8), String, UInt64) changed")
    declaration_types
  end

  private def expected_declaration(roster : Array(Field)) : String
    "JSON(max_dynamic_types=1, max_dynamic_paths=1, #{roster.map { |field| "#{field.name} #{field.type_name}" }.join(", ")})"
  end

  private def schema_for(roster : Array(Field)) : CrystalClick::ObjectDocumentSchema
    typed = {} of String => DataType
    roster.each { |field| typed[field.name] = field.type }
    schema = CrystalClick::ObjectDocumentSchema.new(typed, max_dynamic_paths: 1, max_dynamic_types: 1)
    expected = expected_declaration(roster)
    assert(schema.declaration == expected, "Object schema declaration differs from the exact W151 roster: #{schema.declaration.inspect}")
    reparsed = CrystalClick::ObjectDocumentSchema.parse_declaration(expected)
    assert(reparsed.declaration == expected && reparsed.typed_paths == schema.typed_paths,
      "JSON Object declaration parser changed the W151 nominal typed paths")
    schema
  end

  private def variant_u64(type : DataType, number : UInt64) : Value
    arm(type, "UInt64", Value.uint64(number))
  end

  private def variant_string(type : DataType, text : String) : Value
    arm(type, "String", Value.string(text))
  end

  private def variant_u8_array(type : DataType, numbers : Array(UInt8)) : Value
    array_type = type.child_at(variant_index(type, "Array(UInt8)"))
    payload = array(array_type, numbers.map { |number| uint8(number) })
    arm(type, "Array(UInt8)", payload)
  end

  private def variant_lc_string(type : DataType, text : String) : Value
    lc_type = type.child_at(variant_index(type, "LowCardinality(String)"))
    arm(type, "LowCardinality(String)", low(lc_type, Value.string(text)))
  end

  private def map_value(type : DataType, entries : Array(Tuple(String, Value))) : Value
    flat = [] of Value
    entries.sort_by(&.[0]).each do |key, child|
      flat << Value.string(key)
      flat << child
    end
    Value.map(type, flat)
  end

  private def variant_inner_array(type : DataType, children : Array(Value)) : Value
    array_type = type.child_at(variant_index(type, "Array(Variant(String, UInt64))"))
    arm(type, "Array(Variant(String, UInt64))", array(array_type, children))
  end

  private def variant_tuple(type : DataType, label : String, score : UInt32) : Value
    tuple_type = type.child_at(variant_index(type, "Tuple(label String, score UInt32)"))
    tuple = Value.tuple(tuple_type, [Value.string(label), uint32(score)] of Value)
    arm(type, "Tuple(label String, score UInt32)", tuple)
  end

  private def document(
    roster : Array(Field), aav : Value, av : Value, mv : Value, nested : Value,
    ntv : Value, tv : Value, v : Value, dynamic_value : Int64, spill : String?,
  ) : Document
    values = {} of String => Value
    values["aav"] = aav
    values["av"] = av
    values["mv"] = mv
    values["nested"] = nested
    values["ntv"] = ntv
    values["tv"] = tv
    values["v"] = v
    values["d"] = Value.int64(dynamic_value)
    values["spill"] = Value.string(spill) if spill
    Document.new(values)
  end

  private def expected_documents(roster : Array(Field)) : Array(Document)
    typed = {} of String => DataType
    roster.each { |field| typed[field.name] = field.type }
    aav_type = typed["aav"]
    aav_inner = aav_type.child_at(0)
    aav_variant = aav_inner.child_at(0)
    av_type = typed["av"]
    av_variant = av_type.child_at(0)
    mv_type = typed["mv"]
    mv_variant = mv_type.child_at(1)
    nested_type = typed["nested"]
    nested_inner_variant = nested_type.child_at(variant_index(nested_type, "Array(Variant(String, UInt64))")).child_at(0)
    ntv_type = typed["ntv"]
    ntv_tuple_type = ntv_type.child_at(0)
    ntv_variant = ntv_tuple_type.child_at(0)
    tv_type = typed["tv"]
    v_type = typed["v"]

    empty_aav = array(aav_type, [] of Value)
    empty_av = array(av_type, [] of Value)
    empty_mv = Value.map(mv_type, [] of Value)
    empty_nested_array = variant_inner_array(nested_type, [] of Value)
    empty_aav_inner = array(aav_inner, [] of Value)

    rows = [] of Document
    rows << document(roster, empty_aav, empty_av,
      map_value(mv_type, [({"one", variant_string(mv_variant, "alpha")})] of Tuple(String, Value)),
      null_variant(nested_type), nullable(ntv_type), null_variant(tv_type), null_variant(v_type), 11_i64, nil)

    row2_aav = array(aav_type, [
      array(aav_inner, [variant_u8_array(aav_variant, [1_u8, 2_u8]), variant_u64(aav_variant, 3_u64)] of Value),
      empty_aav_inner,
    ] of Value)
    row2_av = array(av_type, [
      variant_lc_string(av_variant, "alpha"),
      variant_u64(av_variant, 2_u64),
    ] of Value)
    row2_nested = variant_inner_array(nested_type, [
      variant_string(nested_inner_variant, "nested2"),
      variant_u64(nested_inner_variant, 200_u64),
    ] of Value)
    row2_ntv = nullable(ntv_type, Value.tuple(ntv_tuple_type, [
      variant_string(ntv_variant, "inner2"), Value.string("note2"),
    ] of Value))
    rows << document(roster, row2_aav, row2_av,
      map_value(mv_type, [
        ({"a", variant_u64(mv_variant, 2_u64)}),
        ({"z", variant_string(mv_variant, "two")}),
      ] of Tuple(String, Value)),
      row2_nested, row2_ntv, variant_tuple(tv_type, "row2", 22_u32),
      variant_u64(v_type, 42_u64), 22_i64, "spill-two")

    row3_aav = array(aav_type, [
      empty_aav_inner,
      array(aav_inner, [variant_u8_array(aav_variant, [9_u8])] of Value),
    ] of Value)
    row3_av = array(av_type, [
      variant_lc_string(av_variant, "alpha"), variant_u64(av_variant, 3_u64),
    ] of Value)
    row3_ntv = nullable(ntv_type, Value.tuple(ntv_tuple_type, [
      variant_u64(ntv_variant, 3_u64), Value.string("note3"),
    ] of Value))
    rows << document(roster, row3_aav, row3_av, empty_mv,
      variant_u64(nested_type, 300_u64), row3_ntv, variant_u64(tv_type, 33_u64),
      variant_string(v_type, "three"), 33_i64, nil)

    row4_aav = array(aav_type, [
      array(aav_inner, [variant_u8_array(aav_variant, [] of UInt8)] of Value),
    ] of Value)
    row4_av = array(av_type, [variant_lc_string(av_variant, "mid")] of Value)
    row4_nested = variant_inner_array(nested_type, [] of Value)
    rows << document(roster, row4_aav, row4_av,
      map_value(mv_type, [({"b", variant_u64(mv_variant, 4_u64)})] of Tuple(String, Value)),
      row4_nested, nullable(ntv_type), variant_u64(tv_type, 44_u64),
      variant_u8_array(v_type, [4_u8, 5_u8]), 44_i64, "spill-four")

    row5_nested = variant_inner_array(nested_type, [
      null_variant(nested_inner_variant), variant_string(nested_inner_variant, "nested5"),
    ] of Value)
    row5_ntv = nullable(ntv_type, Value.tuple(ntv_tuple_type, [
      null_variant(ntv_variant), Value.string("note5"),
    ] of Value))
    rows << document(roster, empty_aav,
      array(av_type, [variant_lc_string(av_variant, "last"), variant_u64(av_variant, 5_u64)] of Value),
      map_value(mv_type, [({"z", variant_string(mv_variant, "five")})] of Tuple(String, Value)),
      row5_nested, row5_ntv, variant_tuple(tv_type, "row5", 55_u32),
      null_variant(v_type), 55_i64, nil)

    row6_aav = array(aav_type, [
      array(aav_inner, [variant_u64(aav_variant, 6_u64), variant_u8_array(aav_variant, [6_u8])] of Value),
    ] of Value)
    rows << document(roster, row6_aav,
      array(av_type, [variant_u64(av_variant, 6_u64)] of Value),
      map_value(mv_type, [({"a", variant_u64(mv_variant, UInt64::MAX)})] of Tuple(String, Value)),
      variant_u64(nested_type, 600_u64),
      nullable(ntv_type, Value.tuple(ntv_tuple_type, [
        variant_string(ntv_variant, "six"), Value.string("note6"),
      ] of Value)),
      variant_u64(tv_type, 66_u64),
      variant_u64(v_type, UInt64::MAX), 66_i64, "spill-six")

    assert(rows.size == ROWS.size, "W151 literal document count differs from the six-row fixture")
    rows
  end

  private def var_uint(io : IO, value : UInt64) : Nil
    remaining = value
    while remaining >= 0x80_u64
      io.write_byte((remaining & 0x7f_u64).to_u8 | 0x80_u8)
      remaining >>= 7
    end
    io.write_byte(remaining.to_u8)
  end

  # Independent row-oriented literal encoder. Variant emits its canonical
  # UInt8 tag (255 for NULL); LowCardinality is transparent in RowBinary.
  private def encode_rowbinary(io : IO, value : Value) : Nil
    type = value.type
    case type.tag
    when DataType::TAG_LOW_CARDINALITY
      encode_rowbinary(io, value.element_at(0))
    when DataType::TAG_VARIANT
      if value.is_null?
        io.write_byte(0xff_u8)
      else
        index = value.variant_index? || raise Mismatch.new("non-NULL Variant literal has no discriminator")
        io.write_byte(index)
        child = value.variant_child? || raise Mismatch.new("non-NULL Variant literal has no child")
        encode_rowbinary(io, child)
      end
    when DataType::TAG_ARRAY
      var_uint(io, value.element_count.to_u64)
      value.element_count.times { |index| encode_rowbinary(io, value.element_at(index)) }
    when DataType::TAG_MAP
      assert(value.element_count.even?, "literal Map is not a complete sequence of pairs")
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
    when DataType::TAG_UINT8, DataType::TAG_UINT32, DataType::TAG_UINT64, DataType::TAG_INT64
      io.write(value.bytes)
    else
      fail("W151 literal RowBinary encoder has no mapping for #{type.name}")
    end
    nil
  end

  private def expected_rowbinary(indices : Array(Int32), docs : Array(Document), roster : Array(Field)) : String
    String.build do |io|
      indices.each do |index|
        io.write(le(KEYS[index], 8))
        roster.each { |field| encode_rowbinary(io, docs[index].value_for(field.name)) }
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
    if expected.type.tag == DataType::TAG_VARIANT
      if expected.is_null?
        assert(expected.variant_index?.nil? && actual.variant_index?.nil?, "#{label}: NULL Variant exposes an arm tag")
        assert(expected.variant_child?.nil? && actual.variant_child?.nil?, "#{label}: NULL Variant exposes a child")
        return
      end
      assert(expected.variant_index? == actual.variant_index?, "#{label}: Variant arm index differs")
      left = expected.variant_child? || fail("#{label}: expected Variant child is absent")
      right = actual.variant_child? || fail("#{label}: actual Variant child is absent")
      assert_value(left, right, "#{label} arm")
      return
    end
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
      assert(expected.bytes == actual.bytes, "#{label}: exact scalar bytes differ")
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
    assert(expected.size == actual.size, "#{label}: mark count differs")
    expected.each_with_index do |documents, index|
      assert_documents(documents, actual[index], "#{label} mark #{index}")
    end
  end

  private def expected_marks(docs : Array(Document)) : Array(Array(Document))
    [docs[0, 2], docs[2, 2], docs[4, 2]]
  end

  private def verify_runtime(binary : String, identity_store : String, evidence : String) : Nil
    digest = command_output("shasum", ["-a", "256", binary]).split(' ').first? || ""
    assert(digest == EXECUTABLE_SHA256, "pinned ClickHouse SHA-256 differs: #{digest}")
    source_revision = command_output("git", ["-C", SOURCE_ROOT, "rev-parse", "HEAD"]).strip
    assert(source_revision == SOURCE_REVISION, "shallow source reference revision differs: #{source_revision}")
    version = execute(binary, identity_store, "SELECT version() FORMAT TSVRaw", "#{evidence}/version").strip
    assert(version == VERSION, "unexpected ClickHouse runtime version #{version.inspect}")
    identity = execute(binary, identity_store,
      "SELECT concat(name, '=', value) FROM system.build_options WHERE name IN ('GIT_HASH','VERSION_GITHASH') ORDER BY name FORMAT TSVRaw",
      "#{evidence}/build-identity")
    expected = "GIT_HASH=#{BUILD_HASH}\nVERSION_GITHASH=#{BUILD_HASH}\n"
    assert(identity == expected, "unexpected ClickHouse runtime build identity #{identity.inspect}")
    File.write(File.join(evidence, "run.txt"), [
      "runtime_version=#{version}", "runtime_sha256=#{digest}", "runtime_build_hash=#{BUILD_HASH}",
      "source_reference_checkout=#{SOURCE_ROOT}", "source_reference_revision=#{SOURCE_REVISION}",
      "source_is_not_asserted_to_build_runtime=true", "timezone=UTC",
    ].join("\n") + "\n")
  end

  private def click(binary : String, store : String, query : String, evidence : String, input : String? = nil) : String
    execute(binary, store, query, evidence, input)
  end

  private def table_settings(profile_name : String, compact_variant : Int32 = 0) : String
    "#{SETTINGS_BASE}, use_compact_variant_discriminators_serialization=#{compact_variant}, string_serialization_version='#{profile_name}'"
  end

  private def create_table(
    binary : String, store : String, evidence : String, table : String,
    declaration : String, profile_name : String, label : String, compact_variant : Int32 = 0,
  ) : Nil
    ddl = "CREATE TABLE default.#{table} (pk UInt64, j #{declaration}) ENGINE=MergeTree ORDER BY pk SETTINGS #{table_settings(profile_name, compact_variant)}"
    click(binary, store, ddl, "#{evidence}/create")
    actual = click(binary, store,
      "SELECT name, type, position FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw",
      "#{evidence}/system-columns")
    expected = "pk\tUInt64\t1\nj\t#{declaration}\t2\n"
    assert(actual == expected, "#{label}: exact system.columns schema differs: #{actual.inspect}")
  end

  private def type_witness(
    binary : String, store : String, table : String, roster : Array(Field), evidence : String, label : String,
  ) : Nil
    projection = roster.map { |field| "toTypeName(j.#{field.name})" }.join(", ")
    actual = click(binary, store,
      "SELECT #{projection} FROM default.#{table} ORDER BY pk LIMIT 1 FORMAT TSVRaw",
      "#{evidence}/type-witness")
    expected = roster.map(&.type_name).join('\t') + "\n"
    assert(actual == expected, "#{label}: exact canonical nominal type witness differs: #{actual.inspect}")
  end

  private def dynamic_witness(binary : String, store : String, table : String, evidence : String, label : String) : Nil
    ordinary = click(binary, store,
      "SELECT pk, dynamicType(j.d), isDynamicElementInSharedData(j.d) FROM default.#{table} ORDER BY pk FORMAT TSVRaw",
      "#{evidence}/dynamic-ordinary")
    expected = KEYS.map { |key| "#{key}\tInt64\tfalse\n" }.join
    assert(ordinary == expected, "#{label}: ordinary Dynamic d type/shared discriminator witness differs: #{ordinary.inspect}")
    paths = click(binary, store,
      "SELECT pk, toJSONString(JSONDynamicPaths(j)), toJSONString(JSONSharedDataPaths(j)) FROM default.#{table} ORDER BY pk FORMAT TSVRaw",
      "#{evidence}/object-path-layout")
    expected_paths = KEYS.map do |key|
      shared_paths = [2_u64, 4_u64, 6_u64].includes?(key) ? "[\"spill\"]" : "[]"
      "#{key}\t[\"d\"]\t#{shared_paths}\n"
    end.join
    assert(paths == expected_paths,
      "#{label}: Object dynamic/shared path roster differs: #{paths.inspect}")
    spilled = click(binary, store,
      "SELECT pk, CAST(j.spill AS String), dynamicType(j.spill), isDynamicElementInSharedData(j.spill) FROM default.#{table} WHERE pk IN (2,4,6) ORDER BY pk FORMAT TSVRaw",
      "#{evidence}/object-shared-spill")
    assert(spilled == "2\tspill-two\tString\tfalse\n4\tspill-four\tString\tfalse\n6\tspill-six\tString\tfalse\n",
      "#{label}: Object-shared spill path / Dynamic-element discriminator witness differs: #{spilled.inspect}")
  end

  private def sql_rowbinary(
    binary : String, store : String, table : String, roster : Array(Field),
    docs : Array(Document), evidence : String, label : String,
  ) : String
    projection = (["pk"] + roster.map { |field| "j.#{field.name}" }).join(", ")
    full = expected_rowbinary((0...KEYS.size).to_a, docs, roster)
    middle = expected_rowbinary([2, 3], docs, roster)
    File.write(File.join(evidence, "expected-full.rowbinary"), full)
    File.write(File.join(evidence, "expected-middle.rowbinary"), middle)
    actual_full = click(binary, store,
      "SELECT #{projection} FROM default.#{table} ORDER BY pk FORMAT RowBinary",
      "#{evidence}/actual-full")
    actual_middle = click(binary, store,
      "SELECT #{projection} FROM default.#{table} WHERE pk IN (3,4) ORDER BY pk FORMAT RowBinary",
      "#{evidence}/actual-middle")
    actual_zero = click(binary, store,
      "SELECT #{projection} FROM default.#{table} WHERE 0 ORDER BY pk FORMAT RowBinary",
      "#{evidence}/actual-zero")
    File.write(File.join(evidence, "actual-full.rowbinary"), actual_full)
    File.write(File.join(evidence, "actual-middle.rowbinary"), actual_middle)
    File.write(File.join(evidence, "actual-zero.rowbinary"), actual_zero)
    assert_rowbinary(actual_full, full, "#{label} full")
    assert_rowbinary(actual_middle, middle, "#{label} middle")
    assert(actual_zero.empty?, "#{label}: zero-row RowBinary query emitted bytes")
    actual_full
  end

  private def collect_table_window(
    table : CrystalClick::WidePartTable, start_row : UInt64, max_rows : Int,
  ) : {Array(UInt64), Array(Document)}
    keys = [] of UInt64
    documents = [] of Document
    table.scan_typed_window(start_row, max_rows) do |batch|
      keys.concat(batch.values_for("pk").to_a)
      documents.concat(batch.object_documents_for("j").to_a)
      nil
    end
    {keys, documents}
  end

  private def collect_offline_window(
    table : CrystalClick::OfflineTable, start_row : UInt64, max_rows : Int,
  ) : {Array(UInt64), Array(Document)}
    keys = [] of UInt64
    documents = [] of Document
    table.scan_typed_window(["pk", "j"], start_row, max_rows) do |batch|
      keys.concat(batch.values_for("pk").to_a)
      documents.concat(batch.object_documents_for("j").to_a)
      nil
    end
    {keys, documents}
  end

  private def assert_windows(
    window_reader : Proc(UInt64, Int32, Tuple(Array(UInt64), Array(Document))),
    docs : Array(Document), label : String,
  ) : Nil
    full_keys, full_docs = window_reader.call(0_u64, KEYS.size)
    assert(full_keys == KEYS, "#{label}: full window primary keys differ")
    assert_documents(docs, full_docs, "#{label} full window")
    middle_keys, middle_docs = window_reader.call(2_u64, 2)
    assert(middle_keys == [3_u64, 4_u64], "#{label}: middle window primary keys differ")
    assert_documents([docs[2], docs[3]], middle_docs, "#{label} middle window")
    zero_keys, zero_docs = window_reader.call(KEYS.size.to_u64, 1)
    assert(zero_keys.empty? && zero_docs.empty?, "#{label}: zero-row window emitted data")
  end

  private def assert_public_readers(
    part : Part, schema : CrystalClick::ObjectDocumentSchema, roster : Array(Field),
    docs : Array(Document), profile : CrystalClick::BinaryBulkProfile, label : String,
  ) : Nil
    expected_marks = expected_marks(docs)
    column = CrystalClick::ObjectColumnReader.open(part.path, "j", schema)
    assert(column.row_count == KEYS.size.to_u64, "#{label}: ObjectColumnReader row count differs")
    assert(column.ordinary_profile == profile, "#{label}: ObjectColumnReader String profile differs")
    grid = column.mark_row_counts
    assert(grid == ROWS_PER_MARK, "#{label}: ObjectColumnReader real mark grid differs: #{grid.inspect}")
    assert_granules(expected_marks, column.read_marks(0, grid.size), "#{label} ObjectColumnReader full")
    assert_granules([expected_marks[1]], column.read_marks(1, 1), "#{label} ObjectColumnReader middle")
    assert_granules([] of Array(Document), column.read_marks(grid.size, 0), "#{label} ObjectColumnReader zero")

    read_file = ->(first_mark : Int32, mark_count : Int32) do
      CrystalClick::ObjectDocumentFileReader.read(
        part.path, "j", schema.typed_paths, first_mark: first_mark, mark_count: mark_count,
        profile: profile, shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
        hashed: true, limits: CrystalClick::BinaryCodecLimits.default,
        transport_limits: CrystalClick::CompressedStreamLimits.new,
      )
    end
    assert_granules(expected_marks, read_file.call(0, grid.size), "#{label} ObjectDocumentFileReader full")
    assert_granules([expected_marks[1]], read_file.call(1, 1), "#{label} ObjectDocumentFileReader middle")
    assert_granules([] of Array(Document), read_file.call(grid.size, 0), "#{label} ObjectDocumentFileReader zero")

    table = CrystalClick::WidePartTable.open_selected_typed([part.path], ["pk", "j"])
    assert_windows(->(start_row : UInt64, count : Int32) { collect_table_window(table, start_row, count) },
      docs, "#{label} WidePartTable")
    nil
  end

  private def make_catalog(
    root : String, label : String, number : Int32, part : Part, declaration : String,
  ) : {String, String}
    catalog = File.join(root, "catalog", label)
    assert(!File.exists?(catalog) && !File.symlink?(File.dirname(catalog)), "#{label}: catalog destination exists or is unsafe")
    metadata = File.join(catalog, "metadata")
    FileUtils.mkdir_p(metadata)
    FileUtils.mkdir_p(File.join(catalog, "store"))
    database_uuid = "15100000-0000-4000-8000-000000000001"
    table_uuid = "15110000-0000-4000-8000-#{number.to_s.rjust(12, '0')}"
    File.write(File.join(metadata, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
    database_dir = File.join(catalog, "store", database_uuid[0, 3], database_uuid)
    FileUtils.mkdir_p(database_dir)
    File.write(File.join(database_dir, "events.sql"),
      "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `j` #{declaration}\n)\nENGINE = MergeTree\nORDER BY `pk`\n")
    table_dir = File.join(catalog, "store", table_uuid[0, 3], table_uuid)
    FileUtils.mkdir_p(File.join(table_dir, "detached"))
    File.write(File.join(table_dir, "format_version.txt"), "1\n")
    destination = File.join(table_dir, part.name)
    assert(!File.exists?(destination) && !File.symlink?(destination), "#{label}: catalog part destination is occupied")
    FileUtils.cp_r(part.path, destination)
    {catalog, File.realpath(destination)}
  end

  private def assert_catalog(
    catalog_root : String, catalog_part : String, part : Part, docs : Array(Document), label : String,
  ) : Nil
    catalog = CrystalClick::OfflineCatalog.open(catalog_root)
    values = catalog["lab"]["events"]["j"].values.map(&.as(Document))
    assert_documents(docs, values, "#{label} OfflineCatalog full values")
    table = catalog.table("lab", "events")
    candidates = table.resolved_scan_parts
    assert(candidates.map(&.name) == [part.name] && candidates.first.path == catalog_part,
      "#{label}: OfflineCatalog selected part differs")
    assert_windows(->(start_row : UInt64, count : Int32) { collect_offline_window(table, start_row, count) },
      docs, "#{label} OfflineCatalog")
    nil
  end

  private def verified_path(path : String, store : String, label : String) : String
    real_store = File.realpath(store)
    real_path = File.realpath(path)
    assert(real_path.starts_with?(real_store + "/") && !File.symlink?(path),
      "#{label}: resolved path escaped the isolated stock store")
    cursor = real_store
    real_path[(real_store.size + 1)..].split('/').each do |component|
      cursor = File.join(cursor, component)
      assert(!File.symlink?(cursor), "#{label}: symlink in part path")
    end
    real_path
  end

  private def active_part(binary : String, store : String, evidence : String, label : String) : Part
    rows = click(binary, store,
      "SELECT name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='p' AND active ORDER BY name FORMAT TSVRaw",
      "#{evidence}/active-parts").lines.map(&.chomp)
    assert(rows.size == 1, "#{label}: expected exactly one active part, got #{rows.size}")
    columns = rows.first.split('\t')
    assert(columns.size == 5 && columns[2] == "Wide" && columns[3] == "6" && columns[4] == "4",
      "#{label}: expected six rows, three real granules, terminal mark and Wide part: #{rows.first.inspect}")
    part_path = verified_path(columns[1], store, label)
    assert(File.file?(File.join(part_path, "checksums.txt")), "#{label}: part lacks checksums.txt")
    inventory = Dir.children(part_path).sort.map do |name|
      entry = File.join(part_path, name)
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
    File.write(File.join(evidence, "part-files.tsv"), inventory)
    Part.new(columns[0], part_path, columns[3].to_u64, columns[4].to_u64)
  end

  private def check_stock(binary : String, store : String, evidence : String, part_name : String, label : String) : Nil
    output = click(binary, store, "CHECK TABLE default.p FORMAT TabSeparated", "#{evidence}/check-table")
    expected = "#{part_name}\t1\t\n"
    assert(output == expected, "#{label}: raw CHECK TABLE output differs: #{output.inspect}")
  end

  private def table_data_path(binary : String, store : String, evidence : String, label : String) : String
    path = click(binary, store,
      "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='p' FORMAT TSVRaw",
      "#{evidence}/table-data-path").strip
    real = verified_path(path, store, label)
    assert(Dir.exists?(real), "#{label}: table data directory is missing")
    real
  end

  private def object_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
    int64 = DataType.primitive("Int64")
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["d"] of String),
      {"d" => CrystalClick::DynamicStructure.new([int64])} of String => CrystalClick::DynamicStructure,
    )
    CrystalClick::ObjectDocumentPlan.new(structures, schema.typed_paths)
  end

  private def write_library_part(
    destination : String, schema : CrystalClick::ObjectDocumentSchema,
    docs : Array(Document), profile : CrystalClick::BinaryBulkProfile, mode : UInt64,
  ) : String
    CrystalClick::WidePartWriter.write_uint64_object_pair(
      destination, "pk", Slice(UInt64).new(KEYS.size) { |index| KEYS[index] },
      "j", schema, object_plan(schema), expected_marks(docs), rows_per_mark: 2,
      mode: mode, profile: profile, shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      frame_bytes: FRAME_BYTES,
    )
  end

  private def stock_cell_assertions(
    binary : String, store : String, evidence : String, label : String,
    part : Part, roster : Array(Field), docs : Array(Document),
    profile : CrystalClick::BinaryBulkProfile, declaration : String, catalog_id : Int32,
  ) : String
    check_stock(binary, store, evidence, part.name, label)
    type_witness(binary, store, "p", roster, evidence, label)
    dynamic_witness(binary, store, "p", evidence, label)
    output = sql_rowbinary(binary, store, "p", roster, docs, evidence, label)
    assert_public_readers(part, schema_for(roster), roster, docs, profile, label)
    root = ENV["W151_PAIR_ROOT"] || fail("W151_PAIR_ROOT is absent while creating catalog evidence")
    catalog, catalog_part = make_catalog(root, label, catalog_id, part, declaration)
    assert_catalog(catalog, catalog_part, part, docs, label)
    output
  end

  private def catalog_number(label : String) : Int32
    {
      "native-s0"      => 1,
      "native-s1"      => 2,
      "library-s0-d0"  => 3,
      "library-s0-d1"  => 4,
      "library-s1-d0"  => 5,
      "library-s1-d1"  => 6,
      "library-mutant" => 7,
    }[label]? || fail("W151 unknown cell for OfflineCatalog identity: #{label}")
  end

  private def make_cell_dirs(root : String, label : String) : {String, String}
    store = File.join(root, "stores", label)
    evidence = File.join(root, "results", label)
    FileUtils.mkdir_p(store)
    FileUtils.mkdir_p(evidence)
    {store, evidence}
  end

  private def native_cell(
    binary : String, root : String, roster : Array(Field), schema : CrystalClick::ObjectDocumentSchema,
    docs : Array(Document), profile_name : String, profile : CrystalClick::BinaryBulkProfile,
  ) : Nil
    label = "native-#{profile_name == "single_stream" ? "s0" : "s1"}"
    store, evidence = make_cell_dirs(root, label)
    create_table(binary, store, evidence, "p", schema.declaration, profile_name, label)
    input = ROWS.join("\n") + "\n"
    File.write(File.join(evidence, "input.jsonl"), input)
    click(binary, store, "INSERT INTO default.p FORMAT JSONEachRow", "#{evidence}/insert", input)
    part = active_part(binary, store, evidence, label)
    stock_cell_assertions(binary, store, evidence, label, part, roster, docs,
      profile, schema.declaration, catalog_number(label))
    File.open(File.join(root, "cells.tsv"), "a") do |io|
      io.puts("#{label}\tnative-json\t#{profile_name}\tbasic\t#{store}\tdefault.p\t#{part.path}")
    end
    puts "PASS W151 stock JSONEachRow/Variant literal cell #{label}"
  end

  private def compact_variant_guard(
    binary : String, root : String, roster : Array(Field),
    schema : CrystalClick::ObjectDocumentSchema, docs : Array(Document),
  ) : Nil
    label = "native-compact-typed"
    store, evidence = make_cell_dirs(root, label)
    create_table(binary, store, evidence, "p", schema.declaration, "single_stream", label, 1)
    input = ROWS.join("\n") + "\n"
    File.write(File.join(evidence, "input.jsonl"), input)
    click(binary, store, "INSERT INTO default.p FORMAT JSONEachRow", "#{evidence}/insert", input)
    part = active_part(binary, store, evidence, label)
    check_stock(binary, store, evidence, part.name, label)
    type_witness(binary, store, "p", roster, evidence, label)
    dynamic_witness(binary, store, "p", evidence, label)
    sql_rowbinary(binary, store, "p", roster, docs, evidence, label)

    rejected = false
    begin
      CrystalClick::ObjectDocumentFileReader.read(
        part.path, "j", schema.typed_paths, first_mark: 0, mark_count: 1,
        profile: CrystalClick::BinaryBulkProfile.single_stream,
        shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
        hashed: true, limits: CrystalClick::BinaryCodecLimits.default,
        transport_limits: CrystalClick::CompressedStreamLimits.new,
      )
    rescue ex : CrystalClick::CorruptPartError
      assert(ex.to_s.includes?("nonzero BASIC mode header"),
        "#{label}: expected BASIC Variant mode-header refusal, got #{ex}")
      rejected = true
    end
    assert(rejected, "#{label}: BASIC Object reader accepted COMPACT typed Variant discriminator")
    File.open(File.join(root, "cells.tsv"), "a") do |io|
      io.puts("#{label}\tnative-compact-guard\tsingle_stream\tcompact\t#{store}\tdefault.p\t#{part.path}")
    end
    puts "PASS W151 native typed-COMPACT guard: stock accepts; BASIC Object reader refuses the nonzero mode header"
  end

  private def attach_library_part(
    binary : String, store : String, evidence : String, data_path : String,
    schema : CrystalClick::ObjectDocumentSchema, docs : Array(Document),
    profile : CrystalClick::BinaryBulkProfile, mode : UInt64, label : String,
  ) : Part
    active_before = click(binary, store,
      "SELECT count() FROM system.parts WHERE database='default' AND table='p' AND active FORMAT TSVRaw",
      "#{evidence}/active-before").strip
    assert(active_before == "0", "#{label}: stock target is not empty before library part creation")
    detached = File.join(data_path, "detached")
    FileUtils.mkdir_p(detached)
    part_name = "all_1_1_0"
    destination = File.join(detached, part_name)
    assert(!File.exists?(destination) && !File.symlink?(destination), "#{label}: refusing occupied library part destination")
    write_library_part(destination, schema, docs, profile, mode)
    verified_path(destination, store, "#{label} library part")
    click(binary, store, "ALTER TABLE default.p ATTACH PART '#{part_name}'", "#{evidence}/attach")
    part = active_part(binary, store, evidence, label)
    assert(part.name == part_name, "#{label}: stock ATTACH changed library part identity")
    part
  end

  private def library_cell(
    binary : String, root : String, roster : Array(Field), schema : CrystalClick::ObjectDocumentSchema,
    docs : Array(Document), profile_name : String, profile : CrystalClick::BinaryBulkProfile,
    mode_name : String, mode : UInt64,
  ) : Nil
    profile_id = profile_name == "single_stream" ? "s0" : "s1"
    mode_id = mode_name == "basic" ? "d0" : "d1"
    label = "library-#{profile_id}-#{mode_id}"
    store, evidence = make_cell_dirs(root, label)
    create_table(binary, store, evidence, "p", schema.declaration, profile_name, label)
    path = table_data_path(binary, store, evidence, label)
    part = attach_library_part(binary, store, evidence, path, schema, docs, profile, mode, label)
    stock_cell_assertions(binary, store, evidence, label, part, roster, docs,
      profile, schema.declaration, catalog_number(label))
    File.open(File.join(root, "cells.tsv"), "a") do |io|
      io.puts("#{label}\tlibrary-part\t#{profile_name}\t#{mode_name}\t#{store}\tdefault.p\t#{part.path}")
    end
    puts "PASS W151 library whole-part/stock ATTACH/Variant literal cell #{label}"
  end

  private def replace_value(document : Document, path : String, replacement : Value) : Document
    values = {} of String => Value
    document.paths.each { |name| values[name] = name == path ? replacement : document.value_for(name) }
    Document.new(values)
  end

  private def mutant_cell(
    binary : String, root : String, roster : Array(Field), schema : CrystalClick::ObjectDocumentSchema,
    docs : Array(Document),
  ) : Nil
    label = "library-mutant"
    store, evidence = make_cell_dirs(root, label)
    profile = CrystalClick::BinaryBulkProfile.single_stream
    create_table(binary, store, evidence, "p", schema.declaration, "single_stream", label)
    path = table_data_path(binary, store, evidence, label)
    wrong_docs = docs.dup
    original = docs[1].value_for("v")
    wrong_docs[1] = replace_value(docs[1], "v", arm(original.type, "UInt64", Value.uint64(43_u64)))
    part = attach_library_part(binary, store, evidence, path, schema, wrong_docs, profile,
      CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE, label)
    actual = stock_cell_assertions(binary, store, evidence, label, part, roster, wrong_docs,
      profile, schema.declaration, catalog_number(label))
    wrong_literal = expected_rowbinary((0...KEYS.size).to_a, wrong_docs, roster)
    original_literal = expected_rowbinary((0...KEYS.size).to_a, docs, roster)
    assert_rowbinary(actual, wrong_literal, "#{label} changed v=43")
    expect_mismatch("stock CHECK accepts valid v=43, original v=42 literal rejects it") do
      assert_rowbinary(actual, original_literal, "#{label} original v=42")
    end
    File.open(File.join(root, "cells.tsv"), "a") do |io|
      io.puts("#{label}\tvalid-mutant\tsingle_stream\tbasic\t#{store}\tdefault.p\t#{part.path}")
    end
    puts "PASS W151 valid wrong-value part: stock CHECK accepted v=43; original literal rejected"
  end

  private def safe_root?(root : String) : Bool
    prefix = "/private/tmp/crystal-click-object-variant-w151."
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
    assert(Dir.exists?(root) && !File.symlink?(root), "W151 evidence root must be an existing non-symlink directory")
    canonical = File.realpath(root)
    assert(canonical == root && safe_root?(root), "W151 evidence root escaped its direct /private/tmp namespace")
    %w[stores results cells.tsv frontier.txt summary.txt].each do |child|
      path = File.join(root, child)
      assert(!File.exists?(path) && !File.symlink?(path), "refusing to overwrite W151 evidence: #{path}")
    end
    root
  end

  private def validate_fixture(roster : Array(Field), docs : Array(Document)) : Nil
    expected_names = ["aav", "av", "mv", "nested", "ntv", "tv", "v"]
    assert(roster.map(&.name) == expected_names, "W151 typed field roster/order changed")
    assert(KEYS.size == ROWS.size && ROWS_PER_MARK == [2_u64, 2_u64, 2_u64],
      "W151 six-row/three-real-mark fixture changed")
    assert(docs.size == 6, "W151 expected document count differs")
    # The repeated LC string is in the selected middle mark, after first
    # appearing in the preceding mark; this distinguishes selected-only reset.
    previous = docs[1].value_for("av").element_at(0).variant_child?.not_nil!.element_at(0)
    current = docs[2].value_for("av").element_at(0).variant_child?.not_nil!.element_at(0)
    assert(previous.as_string == "alpha" && current.as_string == "alpha",
      "W151 middle LC witness no longer repeats the earlier dictionary key")
    assert(docs[0].value_for("v").variant_index?.nil? &&
           docs[0].value_for("v").variant_child?.nil?, "W151 NULL Variant literal is not the no-arm sentinel")
  end

  def check : Nil
    raise "refusing W151 whole-part oracle without root-owned W151_EXECUTE_AS_ROOT=YES" unless ENV["W151_EXECUTE_AS_ROOT"]? == "YES"
    root_arg = ENV["W151_PAIR_ROOT"]? || raise "W151_PAIR_ROOT must name a fresh paired evidence directory"
    root = validate_root(root_arg)
    binary = ENV["CLICKHOUSE_BIN"]? || "/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped"
    assert(File.file?(binary) && File.executable?(binary) && !File.symlink?(binary),
      "pinned ClickHouse executable is unavailable or unsafe: #{binary}")
    Dir.mkdir(File.join(root, "stores"), 0o700)
    Dir.mkdir(File.join(root, "results"), 0o700)
    File.write(File.join(root, "cells.tsv"),
      "label\tdirection\tstring_profile\tdynamic_mode\tstore\ttable\tpart_path\n")
    File.write(File.join(root, "results", "fixture.jsonl"), ROWS.join("\n") + "\n")

    identity_store = File.join(root, "stores", "identity")
    Dir.mkdir(identity_store, 0o700)
    roster = fields
    schema = schema_for(roster)
    docs = expected_documents(roster)
    validate_fixture(roster, docs)
    verify_runtime(binary, identity_store, File.join(root, "results"))
    File.write(File.join(root, "frontier.txt"), <<-TEXT
      source_reference=#{SOURCE_ROOT}@#{SOURCE_REVISION}
      runtime=#{VERSION} build=#{BUILD_HASH} sha256=#{EXECUTABLE_SHA256}
      source_is_not_asserted_to_build_runtime=true
      claim_scope=seven declared Variant Object paths in Object V3 / MAP / one-bucket / hashed Wide parts
      native_cells=stock JSONEachRow; library_cells=complete library-owned parts attached and checked by stock
      profiles=single_stream and with_size_stream; positive typed Variant setting=0
      dynamic_modes=library Dynamic BASIC and COMPACT; positive Object setting explicitly pins compact Variant=0
      typed_compact_guard=native setting=1; stock checks values; BASIC reader must refuse nonzero mode header
      rows=6; real_granule_grid=[2,2,2]; system.parts marks=4 includes terminal EOF record
      Dynamic=d Int64 each row; spill is an Object-shared path with Dynamic String elements on rows 2,4,6
      typed_paths=aav,av,mv,nested,ntv,tv,v
      literals=canonical Variant tags, NULL=255, named tuple retained, LC repeated in middle mark
      checks=CHECK TABLE, exact nominal types, Dynamic witness, full/middle/zero literal RowBinary
      excluded=compact typed Variant acceptance, Compact parts, WITH_BUCKETS MAP, performance and general Object layouts
    TEXT
    )

    profiles = [
      {"single_stream", CrystalClick::BinaryBulkProfile.single_stream},
      {"with_size_stream", CrystalClick::BinaryBulkProfile.with_size_stream},
    ]
    profiles.each do |profile_name, profile|
      native_cell(binary, root, roster, schema, docs, profile_name, profile)
    end
    compact_variant_guard(binary, root, roster, schema, docs)
    modes = [
      {"basic", CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE},
      {"compact", CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE},
    ]
    profiles.each do |profile_name, profile|
      modes.each do |mode_name, mode|
        library_cell(binary, root, roster, schema, docs, profile_name, profile, mode_name, mode)
      end
    end
    mutant_cell(binary, root, roster, schema, docs)

    lines = File.read(File.join(root, "cells.tsv")).lines
    assert(lines.size == 9, "W151 cell roster must contain six matrix cells, one typed-COMPACT guard, one mutant, and header")
    File.write(File.join(root, "summary.txt"), <<-TEXT
      PASS W151 stock/native and library whole-part matrix (2 native + 4 library cells), one COMPACT typed guard
      PASS seven exact declared nominal Variant/Object paths and independent literal RowBinary full/middle/zero
      PASS stock ATTACH/CHECK, exact Object dynamic/shared path layout, and Dynamic-element discriminator witnesses for every matrix cell
      PASS native typed-COMPACT control is accepted by stock but rejected by the BASIC reader for its nonzero mode header
      PASS valid wrong-value part changes row 2 v UInt64 42 to 43; stock CHECK passes and original literal rejects
      public_consumers=ObjectColumnReader,ObjectDocumentFileReader,WidePartTable,OfflineCatalog full/middle/zero windows
    TEXT
    )
    puts "PASS W151 declared Object Variant whole-part/native frontier: #{root}"
  end
end

W151ObjectVariantOracle.new.check
