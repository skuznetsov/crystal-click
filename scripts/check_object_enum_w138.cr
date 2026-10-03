# W138 declared Enum8/Enum16 Object interoperability oracle.
#
# Enum label text, signed raw storage bytes, and nominal map identity are
# separate literal expectations. Stock ClickHouse produces four cells and
# attaches four library-owned cells across the normalized W137 Object corridor.
require "file_utils"
require "json"
require "../src/crystal_click"
require "./w122_bulk_vectors"

class W138Oracle
  class Mismatch < Exception
  end

  VERSION           = "26.10.1.1201"
  BUILD_HASH        = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
  EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
  FRAME_BYTES       = 16

  # These declarations are literal canonical witnesses. The maps are sorted
  # by signed code; labels exercise all eight canonical escapes, UTF-8, an
  # empty label, and delimiters that require declaration quoting.
  ENUM8_DECLARATION  = "Enum8('min8' = -128, 'quote\\'λ' = -7, 'ctl\\0\\b\\t\\n\\f\\r' = -1, '' = 0, 'back\\\\slash' = 1, 'a,=(x)`' = 7, 'max8' = 127)"
  ENUM16_DECLARATION = "Enum16('min16' = -32768, 'quote\\'雪' = -300, 'ctl16\\0\\b\\t\\n\\f\\r' = -1, '' = 0, 'back\\\\sixteen' = 1, 'a16,=(x)`' = 7, 'max16' = 32767)"
  DECLARATION        = "JSON(max_dynamic_types=1, max_dynamic_paths=1, e16 #{ENUM16_DECLARATION}, e8 #{ENUM8_DECLARATION}, t String)"
  SETTINGS_BASE      = "index_granularity=2, index_granularity_bytes=10485760, enable_mixed_granularity_parts=1, min_rows_for_wide_part=0, min_bytes_for_wide_part=0, compress_marks=0, compress_primary_key=0, min_compress_block_size=0, max_compress_block_size=4096, ratio_of_defaults_for_sparse_serialization=1, default_compression_codec='LZ4', object_serialization_version='v3', object_shared_data_serialization_version_for_zero_level_parts='map', propagate_types_serialization_versions_to_nested_types=true"

  ENUM8_ENTRIES = [
    {"min8", -128_i16}, {"quote'λ", -7_i16}, {"ctl\0\b\t\n\f\r", -1_i16},
    {"", 0_i16}, {"back\\slash", 1_i16}, {"a,=(x)`", 7_i16},
    {"max8", 127_i16},
  ]
  ENUM16_ENTRIES = [
    {"min16", -32_768_i16}, {"quote'雪", -300_i16}, {"ctl16\0\b\t\n\f\r", -1_i16},
    {"", 0_i16}, {"back\\sixteen", 1_i16}, {"a16,=(x)`", 7_i16},
    {"max16", 32_767_i16},
  ]
  ENUM8_TYPE  = CrystalClick::BinaryDataType.enum8(ENUM8_ENTRIES)
  ENUM16_TYPE = CrystalClick::BinaryDataType.enum16(ENUM16_ENTRIES)

  KEYS           = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
  ENUM8_LABELS   = ["", "ctl\0\b\t\n\f\r", "a,=(x)`", "quote'λ", "back\\slash", "min8", "max8"]
  ENUM16_LABELS  = ["", "ctl16\0\b\t\n\f\r", "a16,=(x)`", "quote'雪", "back\\sixteen", "min16", "max16"]
  ENUM8_RAW_HEX  = ["00", "ff", "07", "f9", "01", "80", "7f"]
  ENUM16_RAW_HEX = ["0000", "ffff", "0700", "d4fe", "0100", "0080", "ff7f"]
  TEXT           = ["zero", "a\0b", "λ雪", "é", "終", "", "tail"]
  DYNAMIC        = [11_i64, 22_i64, 33_i64, 44_i64, 55_i64, 66_i64, 77_i64]
  ROWS_PER_MARK  = [2_u64, 2_u64, 2_u64, 1_u64]

  PROFILES = [
    {"single_stream", CrystalClick::BinaryBulkProfile.single_stream},
    {"with_size_stream", CrystalClick::BinaryBulkProfile.with_size_stream},
  ]
  MODES = [
    {"basic", CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE},
    {"compact", CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE},
  ]

  # JSONEachRow source bytes are authored independently of the expected enum
  # maps and raw RowBinary fixtures above.
  NATIVE_JSON_ROWS = [
    %({"pk":1,"payload":{"e8":"","e16":"","t":"zero","d":11,"spill":"alpha"}}),
    %({"pk":2,"payload":{"e8":"ctl\\u0000\\b\\t\\n\\f\\r","e16":"ctl16\\u0000\\b\\t\\n\\f\\r","t":"a\\u0000b","d":22}}),
    %({"pk":3,"payload":{"e8":"a,=(x)`","e16":"a16,=(x)`","t":"λ雪","d":33}}),
    %({"pk":4,"payload":{"e8":"quote'λ","e16":"quote'雪","t":"é","d":44}}),
    %({"pk":5,"payload":{"e8":"back\\\\slash","e16":"back\\\\sixteen","t":"終","d":55}}),
    %({"pk":6,"payload":{"e8":"min8","e16":"min16","t":"","d":66}}),
    %({"pk":7,"payload":{"e8":"max8","e16":"max16","t":"tail","d":77,"spill":"omega"}}),
  ]

  # Retained as a stand-alone handoff artifact for an independent checker.
  # Map entries, row labels, and signed little-endian bytes are literal rather
  # than projected from BinaryDataType, BinaryValue, or a codec.
  FIXTURE_MANIFEST = <<-JSON
  {
    "enum8": {
      "width_bytes": 1,
      "entries": [
        {"label":"min8","code":-128}, {"label":"quote'λ","code":-7},
        {"label":"ctl\\u0000\\b\\t\\n\\f\\r","code":-1}, {"label":"","code":0},
        {"label":"back\\\\slash","code":1}, {"label":"a,=(x)`","code":7}, {"label":"max8","code":127}
      ]
    },
    "enum16": {
      "width_bytes": 2,
      "entries": [
        {"label":"min16","code":-32768}, {"label":"quote'雪","code":-300},
        {"label":"ctl16\\u0000\\b\\t\\n\\f\\r","code":-1}, {"label":"","code":0},
        {"label":"back\\\\sixteen","code":1}, {"label":"a16,=(x)`","code":7}, {"label":"max16","code":32767}
      ]
    },
    "rows": [
      {"pk":1,"enum8_label":"","enum8_raw_hex":"00","enum16_label":"","enum16_raw_hex":"0000"},
      {"pk":2,"enum8_label":"ctl\\u0000\\b\\t\\n\\f\\r","enum8_raw_hex":"ff","enum16_label":"ctl16\\u0000\\b\\t\\n\\f\\r","enum16_raw_hex":"ffff"},
      {"pk":3,"enum8_label":"a,=(x)`","enum8_raw_hex":"07","enum16_label":"a16,=(x)`","enum16_raw_hex":"0700"},
      {"pk":4,"enum8_label":"quote'λ","enum8_raw_hex":"f9","enum16_label":"quote'雪","enum16_raw_hex":"d4fe"},
      {"pk":5,"enum8_label":"back\\\\slash","enum8_raw_hex":"01","enum16_label":"back\\\\sixteen","enum16_raw_hex":"0100"},
      {"pk":6,"enum8_label":"min8","enum8_raw_hex":"80","enum16_label":"min16","enum16_raw_hex":"0080"},
      {"pk":7,"enum8_label":"max8","enum8_raw_hex":"7f","enum16_label":"max16","enum16_raw_hex":"ff7f"}
    ]
  }
  JSON

  alias Part = NamedTuple(name: String, path: String, rows: UInt64)
  alias CapturedBatch = NamedTuple(
    part_index: Int32,
    part_name: String,
    part_path: String,
    mark_index: Int32,
    mark_row_offset: UInt64,
    part_row_offset: UInt64,
    source_row_offset: UInt64,
    keys: Array(UInt64),
    payload: Array(CrystalClick::ObjectDocument),
  )

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
      puts "PASS W138 seeded comparator failure: #{label}"
      return
    end
    fail("#{label}: seeded mismatch passed the oracle comparator")
  end

  private def expect_argument_error(label : String, &)
    begin
      yield
    rescue error : ArgumentError
      puts "PASS W138 enum admission rejects: #{label}"
      return
    end
    fail("#{label}: invalid Enum descriptor was admitted")
  end

  private def run(binary : String, store : String, query : String, input : IO? = nil) : String
    output = IO::Memory.new
    error = IO::Memory.new
    arguments = ["local", "--path", store, "--multiquery", "--query", query]
    status = if input
               Process.run(binary, arguments, input: input, output: output, error: error)
             else
               Process.run(binary, arguments, output: output, error: error)
             end
    raise "ClickHouse local query failed: #{error}\n#{query}" unless status.success?
    output.to_s
  end

  private def run_status(binary : String, arguments : Array(String)) : String
    output = IO::Memory.new
    error = IO::Memory.new
    status = Process.run(binary, arguments, output: output, error: error)
    raise "ClickHouse command failed: #{error}" unless status.success?
    output.to_s
  end

  private def verify_runtime(binary : String, store : String) : Nil
    digest = run_status("shasum", ["-a", "256", binary]).split(' ').first? || ""
    assert(digest == EXECUTABLE_SHA256, "unexpected ClickHouse executable SHA-256")
    version = run_status(binary, ["local", "--version"]).strip
    assert(version == "ClickHouse local version #{VERSION} (official build).",
      "unexpected ClickHouse version: #{version.inspect}")
    build = run(binary, store,
      "SELECT name || '=' || value FROM system.build_options WHERE name IN ('GIT_HASH', 'VERSION_GITHASH') ORDER BY name FORMAT TSVRaw").lines.map(&.strip)
    assert(build == ["GIT_HASH=#{BUILD_HASH}", "VERSION_GITHASH=#{BUILD_HASH}"],
      "unexpected ClickHouse build identity")
  end

  private def store_child(path : String, store : String, label : String) : String
    real_store = File.realpath(store)
    real_path = File.realpath(path)
    unless real_path.starts_with?(real_store + "/") && !File.symlink?(path)
      fail("#{label}: path escapes isolated store or is a symlink")
    end
    relative = real_path[(real_store.size + 1)..]
    cursor = real_store
    relative.split('/').each do |component|
      cursor = File.join(cursor, component)
      fail("#{label}: symlink in store path") if File.symlink?(cursor)
    end
    real_path
  end

  private def assert_tree(path : String, label : String) : Nil
    assert(Dir.exists?(path) && !File.symlink?(path), "#{label}: unsafe/missing directory")
    Dir.children(path).each do |name|
      child = File.join(path, name)
      assert(!File.symlink?(child), "#{label}: symlink child #{name.inspect}")
      if Dir.exists?(child)
        assert_tree(child, "#{label}/#{name}")
      else
        assert(File.file?(child), "#{label}: non-file child #{name.inspect}")
      end
    end
  end

  private def enum_type(path : String) : CrystalClick::BinaryDataType
    case path
    when "e8"  then ENUM8_TYPE
    when "e16" then ENUM16_TYPE
    else            raise ArgumentError.new("unknown W138 enum path")
    end
  end

  private def enum_declaration(path : String) : String
    path == "e8" ? ENUM8_DECLARATION : ENUM16_DECLARATION
  end

  private def enum_labels(path : String) : Array(String)
    path == "e8" ? ENUM8_LABELS : ENUM16_LABELS
  end

  private def enum_raw_hex(path : String) : Array(String)
    path == "e8" ? ENUM8_RAW_HEX : ENUM16_RAW_HEX
  end

  private def typed_schema : Hash(String, CrystalClick::BinaryDataType)
    {
      "e8"  => ENUM8_TYPE,
      "e16" => ENUM16_TYPE,
      "t"   => CrystalClick::BinaryDataType.primitive("String"),
    }
  end

  private def table_name(label : String) : String
    "w138_#{label.gsub('-', "_")}"
  end

  private def create_table(
    binary : String, store : String, table : String, profile_name : String, mode : UInt64, label : String,
  ) : Nil
    compact = mode == CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE ? 1 : 0
    settings = "#{SETTINGS_BASE}, use_compact_variant_discriminators_serialization=#{compact}, string_serialization_version='#{profile_name}'"
    run(binary, store,
      "CREATE TABLE default.#{table} (pk UInt64, payload #{DECLARATION}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings}")
    actual = run(binary, store,
      "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
    expected = "pk UInt64\npayload #{DECLARATION}\n"
    assert(actual == expected, "#{label}: live columns differ from the literal DDL: #{actual.inspect}")
    schema = CrystalClick::ObjectDocumentSchema.parse_declaration(DECLARATION)
    assert(schema.declaration == DECLARATION, "#{label}: canonical parser declaration differs from authored DDL")
    assert(schema.typed_paths == typed_schema, "#{label}: typed path roster or enum map differs from authored DDL")
  end

  private def table_data_path(binary : String, store : String, table : String, label : String) : String
    path = run(binary, store,
      "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
    store_child(path, store, "#{label} data path")
  end

  private def stock_part(binary : String, store : String, table : String, label : String) : Part
    rows = run(binary, store,
      "SELECT name, path, part_type, toString(rows) FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines
    assert(rows.size == 1, "#{label}: expected exactly one active part, got #{rows.size}")
    fields = rows.first.split('\t')
    assert(fields.size == 4 && fields[2] == "Wide" && fields[3] == KEYS.size.to_s,
      "#{label}: expected one seven-row Wide part, got #{rows.first.inspect}")
    path = store_child(fields[1], store, "#{label} part")
    assert_tree(path, "#{label} part")
    assert(File.file?(File.join(path, "checksums.txt")), "#{label}: part lacks checksums.txt")
    {name: fields[0], path: path, rows: KEYS.size.to_u64}
  end

  private def hex_nibble(byte : UInt8) : UInt8
    if byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8
      byte - '0'.ord.to_u8
    elsif byte >= 'a'.ord.to_u8 && byte <= 'f'.ord.to_u8
      byte - 'a'.ord.to_u8 + 10_u8
    else
      fail("invalid literal hex fixture byte #{byte}")
    end
  end

  private def raw_bytes(path : String, index : Int32) : Bytes
    hex = enum_raw_hex(path)[index]
    source = hex.to_slice
    width = path == "e8" ? 1 : 2
    assert(source.size == width * 2, "#{path} row #{index}: literal raw width differs from Enum wire width")
    Bytes.new(width) do |offset|
      (hex_nibble(source[offset * 2]) << 4) | hex_nibble(source[offset * 2 + 1])
    end
  end

  private def typed_value(path : String, index : Int32) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.fixed(enum_type(path), raw_bytes(path, index))
  end

  private def document(index : Int32) : CrystalClick::ObjectDocument
    fields = {
      "e8"  => typed_value("e8", index),
      "e16" => typed_value("e16", index),
      "t"   => CrystalClick::BinaryValue.string(TEXT[index]),
      "d"   => CrystalClick::BinaryValue.int64(DYNAMIC[index]),
    } of String => CrystalClick::BinaryValue
    if index == 0
      fields["spill"] = CrystalClick::BinaryValue.string("alpha")
    elsif index == 6
      fields["spill"] = CrystalClick::BinaryValue.string("omega")
    end
    CrystalClick::ObjectDocument.new(fields)
  end

  private def expected_documents : Array(CrystalClick::ObjectDocument)
    Array(CrystalClick::ObjectDocument).new(KEYS.size) { |index| document(index.to_i32) }
  end

  private def granules(documents : Array(CrystalClick::ObjectDocument)) : Array(Array(CrystalClick::ObjectDocument))
    [documents[0, 2], documents[2, 2], documents[4, 2], documents[6, 1]]
  end

  private def plan : CrystalClick::ObjectDocumentPlan
    int64 = CrystalClick::BinaryDataType.primitive("Int64")
    object = CrystalClick::ObjectStructure.new(["d"] of String)
    dynamics = {"d" => CrystalClick::DynamicStructure.new([int64])} of String => CrystalClick::DynamicStructure
    CrystalClick::ObjectDocumentPlan.new(
      CrystalClick::ObjectDynamicStructureSet.new(object, dynamics), typed_schema
    )
  end

  private def assert_documents(
    expected : Array(CrystalClick::ObjectDocument), actual : Array(CrystalClick::ObjectDocument), label : String,
  ) : Nil
    assert(expected.size == actual.size, "#{label}: document count differs")
    expected.each_with_index do |document, row|
      found = actual[row]
      assert(document.paths == found.paths, "#{label}: path roster differs at row #{row}")
      document.paths.each do |path|
        assert(W122BulkVectors.value_equal?(document.value_for(path), found.value_for(path)),
          "#{label}: nominal type/map or exact bytes differ at row #{row}, path #{path.inspect}")
      end
    end
  end

  private def assert_granules(
    expected : Array(Array(CrystalClick::ObjectDocument)), actual : Array(Array(CrystalClick::ObjectDocument)), label : String,
  ) : Nil
    assert(expected.size == actual.size, "#{label}: mark count differs")
    expected.each_with_index { |rows, mark| assert_documents(rows, actual[mark], "#{label} mark #{mark}") }
  end

  private def assert_grid(actual : Array(UInt64), label : String) : Nil
    assert(actual == ROWS_PER_MARK, "#{label}: actual Object mark grid differs: #{actual.inspect}")
  end

  private def assert_default_serializers(serialization : JSON::Any, label : String) : Nil
    info = serialization.as_h
    serializer_columns = info["columns"]?.try(&.as_a) ||
                         raise Mismatch.new("#{label}: serializer columns are missing or malformed")
    serializer_columns.each_with_index do |entry, index|
      kind = entry.as_h["kind"]?.try(&.as_s) ||
             raise Mismatch.new("#{label}: serializer kind is missing or malformed at entry #{index}")
      assert(kind == "Default", "#{label}: serializer kind is not Default at entry #{index}: #{kind.inspect}")
    end
  end

  private def write_varuint(io : IO, value : UInt64) : Nil
    remaining = value
    while remaining >= 0x80_u64
      io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
      remaining >>= 7
    end
    io.write_byte(remaining.to_u8)
  end

  private def write_u64_le(io : IO, value : UInt64) : Nil
    8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
  end

  private def write_string_binary(io : IO, value : String) : Nil
    write_varuint(io, value.bytesize.to_u64)
    io.write(value.to_slice)
  end

  private def expected_rowbinary(indices : Array(Int32)) : String
    String.build do |io|
      indices.each do |index|
        write_u64_le(io, KEYS[index])
        # These two literal hex fixtures are signed little-endian Enum payloads.
        io.write(raw_bytes("e8", index))
        io.write(raw_bytes("e16", index))
        write_string_binary(io, TEXT[index])
        io.write_byte(0x0a_u8) # Dynamic Int64 type discriminator.
        write_u64_le(io, DYNAMIC[index].unsafe_as(UInt64))
      end
    end
  end

  private def rowbinary_mismatch_summary(expected : String, actual : String) : String
    expected_bytes = expected.to_slice
    actual_bytes = actual.to_slice
    common_size = Math.min(expected_bytes.size, actual_bytes.size)
    offset = 0
    while offset < common_size && expected_bytes[offset] == actual_bytes[offset]
      offset += 1
    end
    start = offset > 8 ? offset - 8 : 0
    expected_end = Math.min(expected_bytes.size, offset + 8)
    actual_end = Math.min(actual_bytes.size, offset + 8)
    expected_window = expected_bytes[start, expected_end - start].hexstring
    actual_window = actual_bytes[start, actual_end - start].hexstring
    "expected_bytes=#{expected_bytes.size}, actual_bytes=#{actual_bytes.size}, first_difference=#{offset}, " +
      "expected[#{start}...#{expected_end}]=#{expected_window}, actual[#{start}...#{actual_end}]=#{actual_window}"
  end

  private def assert_rowbinary(actual : String, indices : Array(Int32), label : String) : Nil
    expected = expected_rowbinary(indices)
    assert(actual.to_slice == expected.to_slice,
      "#{label}: raw Enum8/Enum16 signed bytes or neighboring RowBinary differ; #{rowbinary_mismatch_summary(expected, actual)}")
  end

  private def compare_label_rows(
    actual : String, indices : Array(Int32), expected8 : Array(String), expected16 : Array(String), label : String,
  ) : Nil
    lines = actual.lines.map(&.chomp)
    assert(lines.size == indices.size, "#{label}: JSONCompactEachRow count differs")
    indices.each_with_index do |index, position|
      row = JSON.parse(lines[position]).as_a
      assert(row.size == 3, "#{label}: expected pk plus two Enum labels at row #{position}")
      assert(row[0].as_i64.to_u64 == KEYS[index], "#{label}: key differs at row #{position}")
      assert(row[1].as_s == expected8[index], "#{label}: Enum8 label differs at row #{position}")
      assert(row[2].as_s == expected16[index], "#{label}: Enum16 label differs at row #{position}")
    end
  end

  private def assert_label_sql(actual : String, indices : Array(Int32), label : String) : Nil
    compare_label_rows(actual, indices, ENUM8_LABELS, ENUM16_LABELS, label)
  end

  private def expected_object_sql_line(index : Int32) : String
    fields = [KEYS[index].to_s, TEXT[index].to_slice.hexstring.upcase, TEXT[index].bytesize.to_s,
              DYNAMIC[index].to_s, "Int64"]
    if index == 0
      fields.concat(["String", "616C706861"])
    elsif index == 6
      fields.concat(["String", "6F6D656761"])
    else
      fields.concat(["None", ""])
    end
    fields.join('\t')
  end

  private def assert_object_sql(actual : String, indices : Array(Int32), label : String) : Nil
    lines = actual.lines.map(&.chomp)
    expected = indices.map { |index| expected_object_sql_line(index) }
    assert(lines == expected, "#{label}: String/Dynamic SQL rows differ: expected #{expected.inspect}, got #{lines.inspect}")
  end

  private def assert_type_labels(binary : String, store : String, table : String, label : String) : Nil
    actual = run(binary, store,
      "SELECT toTypeName(payload.e8), toTypeName(payload.e16), toTypeName(payload.t), dynamicType(payload.d) FROM default.#{table} ORDER BY pk LIMIT 1 FORMAT TSVRaw").strip
    expected = [ENUM8_DECLARATION, ENUM16_DECLARATION, "String", "Int64"].join('\t')
    assert(actual == expected, "#{label}: exact nominal Enum/type labels differ: #{actual.inspect}")
  end

  private def assert_check(actual : String, part_name : String, label : String) : Nil
    expected = "#{part_name}\t1\t\n"
    assert(actual == expected, "#{label}: CHECK TABLE row differs: #{actual.inspect}")
  end

  private def assert_stock_sql(
    binary : String, store : String, table : String, part_name : String, label : String,
  ) : {String, String, String}
    check = run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated")
    assert_check(check, part_name, "#{label} CHECK TABLE")

    full_labels = run(binary, store,
      "SELECT pk, payload.e8, payload.e16 FROM default.#{table} ORDER BY pk FORMAT JSONCompactEachRow")
    assert_label_sql(full_labels, (0...KEYS.size).to_a, "#{label} all Enum label output")
    selected_labels = run(binary, store,
      "SELECT pk, payload.e8, payload.e16 FROM default.#{table} WHERE pk >= 3 AND pk <= 4 ORDER BY pk FORMAT JSONCompactEachRow")
    assert_label_sql(selected_labels, [2, 3], "#{label} middle Enum label output")

    object_projection = "pk, hex(payload.t), length(payload.t), payload.d, dynamicType(payload.d), dynamicType(payload.spill), ifNull(hex(dynamicElement(payload.spill, 'String')), '')"
    full_object = run(binary, store,
      "SELECT #{object_projection} FROM default.#{table} ORDER BY pk FORMAT TSVRaw")
    assert_object_sql(full_object, (0...KEYS.size).to_a, "#{label} all String/Dynamic SQL")
    selected_object = run(binary, store,
      "SELECT #{object_projection} FROM default.#{table} WHERE pk >= 3 AND pk <= 4 ORDER BY pk FORMAT TSVRaw")
    assert_object_sql(selected_object, [2, 3], "#{label} middle String/Dynamic SQL")
    assert_type_labels(binary, store, table, label)

    rowbinary_projection = "pk, payload.e8, payload.e16, payload.t, payload.d"
    full_binary = run(binary, store,
      "SELECT #{rowbinary_projection} FROM default.#{table} ORDER BY pk FORMAT RowBinary")
    assert_rowbinary(full_binary, (0...KEYS.size).to_a, "#{label} full RowBinary")
    selected_binary = run(binary, store,
      "SELECT #{rowbinary_projection} FROM default.#{table} WHERE pk >= 3 AND pk <= 4 ORDER BY pk FORMAT RowBinary")
    assert_rowbinary(selected_binary, [2, 3], "#{label} middle RowBinary")
    {check, full_binary, full_labels}
  end

  private def read_u64_le(bytes : Bytes, offset : Int32) : UInt64
    assert(offset >= 0 && offset <= bytes.size - 8, "truncated Dynamic discriminator mode header")
    value = 0_u64
    8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
    value
  end

  private def assert_part_profile(
    part : Part, schema : CrystalClick::ObjectDocumentSchema, profile : CrystalClick::BinaryBulkProfile,
    mode : UInt64, label : String,
  ) : {Array(UInt64), Array(Int32)}
    codec = File.read(File.join(part[:path], "default_compression_codec.txt")).strip
    assert(codec == "CODEC(LZ4)", "#{label}: actual part codec differs from LZ4: #{codec.inspect}")
    assert(File.file?(File.join(part[:path], "primary.idx")) && !File.exists?(File.join(part[:path], "primary.cidx")),
      "#{label}: expected a plain primary.idx")
    basenames = Dir.children(part[:path])
    assert(basenames.any?(&.ends_with?(".mrk2")), "#{label}: no plain mark files found")
    assert(basenames.none?(&.ends_with?(".cmrk2")), "#{label}: compressed mark file found")
    serialization = JSON.parse(File.read(File.join(part[:path], "serialization.json")))
    assert_default_serializers(serialization, "#{label} actual part")

    reader = CrystalClick::ObjectColumnReader.open(part[:path], "payload", schema)
    assert(reader.row_count == KEYS.size.to_u64, "#{label}: Object reader row count differs")
    assert(reader.ordinary_profile == profile, "#{label}: actual ordinary String profile differs")
    assert(reader.source_declaration == DECLARATION, "#{label}: source DDL bytes differ from authored declaration")
    grid = reader.mark_row_counts
    assert_grid(grid, "#{label} ObjectColumnReader")
    descriptor = CrystalClick::ObjectDocumentFileReader.inspect(
      part[:path], "payload", schema.typed_paths, reader.ordinary_profile,
      CrystalClick::BinaryBulkProfile.single_stream, true
    )
    object = descriptor.plan.structures.object
    assert(object.version == 4_u64 && object.shared_data_version == 0_u64 && object.bucket_count == 1_u64,
      "#{label}: actual Object structure is not V3 with one shared MAP bucket")
    assert(descriptor.plan.structures.dynamic_count == 1 && object.dynamic_paths == ["d"],
      "#{label}: actual Dynamic path roster differs")
    assert(descriptor.plan.typed_paths == typed_schema, "#{label}: actual typed schema or Enum map differs")
    assert(descriptor.plan.typed_paths.size == 3, "#{label}: expected exactly Enum8, Enum16, and String typed fields")
    assert(descriptor.plan.typed_type_for("e8") == ENUM8_TYPE, "#{label}: Enum8 declaration/map differs in part")
    assert(descriptor.plan.typed_type_for("e16") == ENUM16_TYPE, "#{label}: Enum16 declaration/map differs in part")
    dynamics = descriptor.plan.structures.dynamics
    assert(dynamics["d"].types == [CrystalClick::BinaryDataType.primitive("Int64")],
      "#{label}: actual Dynamic arm differs from Int64")

    physical = CrystalClick::ObjectDocumentPhysicalPlan.new(
      "payload", descriptor.plan, reader.ordinary_profile, CrystalClick::BinaryBulkProfile.single_stream
    )
    discriminator_name = CrystalClick::StreamName.hash(physical.discriminator_stream("d")) + ".bin"
    discriminator_bytes = CrystalClick::PartStreamSource.new(part[:path]).read_all(discriminator_name)
    actual_mode = read_u64_le(discriminator_bytes, 0)
    assert(actual_mode == mode, "#{label}: actual Dynamic discriminator mode differs: #{actual_mode}")

    checksums = CrystalClick::PartChecksums.open(part[:path])
    primary = CrystalClick::PrimaryKeyIndex.open(part[:path], grid.size, checksums, verify_recorded_hash: true)
    assert(primary.keys == [1_u64, 3_u64, 5_u64, 7_u64, 7_u64],
      "#{label}: actual primary index keys/sentinel differ: #{primary.keys.inspect}")
    schedule = primary.candidate_marks(6_u64, 6_u64)
    assert(schedule == [2_i32], "#{label}: actual PK=6 candidate schedule differs: #{schedule.inspect}")
    {grid, schedule}
  end

  private def assert_object_reader(part : Part, schema : CrystalClick::ObjectDocumentSchema, label : String) : Nil
    reader = CrystalClick::ObjectColumnReader.open(part[:path], "payload", schema)
    expected = granules(expected_documents)
    grid = reader.mark_row_counts
    assert_grid(grid, "#{label} ObjectColumnReader")
    assert_granules(expected, reader.read_marks(0, grid.size), "#{label} ObjectColumnReader full")
    assert_granules([expected[1]], reader.read_marks(1, 1), "#{label} ObjectColumnReader middle mark")
    assert_granules([] of Array(CrystalClick::ObjectDocument), reader.read_marks(grid.size, 0),
      "#{label} ObjectColumnReader zero marks")
    full = CrystalClick::ObjectDocumentFileReader.read(
      part[:path], "payload", schema.typed_paths, first_mark: 0, mark_count: grid.size,
      profile: reader.ordinary_profile, shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      hashed: true, limits: CrystalClick::BinaryCodecLimits.default,
      transport_limits: CrystalClick::CompressedStreamLimits.new
    )
    assert_granules(expected, full, "#{label} ObjectDocumentFileReader full")
    middle = CrystalClick::ObjectDocumentFileReader.read(
      part[:path], "payload", schema.typed_paths, first_mark: 1, mark_count: 1,
      profile: reader.ordinary_profile, shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      hashed: true, limits: CrystalClick::BinaryCodecLimits.default,
      transport_limits: CrystalClick::CompressedStreamLimits.new
    )
    assert_granules([expected[1]], middle, "#{label} ObjectDocumentFileReader middle mark")
    zero = CrystalClick::ObjectDocumentFileReader.read(
      part[:path], "payload", schema.typed_paths, first_mark: grid.size, mark_count: 0,
      profile: reader.ordinary_profile, shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      hashed: true, limits: CrystalClick::BinaryCodecLimits.default,
      transport_limits: CrystalClick::CompressedStreamLimits.new
    )
    assert_granules([] of Array(CrystalClick::ObjectDocument), zero, "#{label} ObjectDocumentFileReader zero marks")
  end

  private def catalog_root(root : String, label : String, table_number : Int32, part : Part) : {root: String, part_path: String}
    catalog = File.join(root, "catalog", label)
    assert(!File.exists?(catalog) && !File.symlink?(File.dirname(catalog)), "#{label}: catalog path occupied or unsafe")
    metadata = File.join(catalog, "metadata")
    FileUtils.mkdir_p(metadata)
    FileUtils.mkdir_p(File.join(catalog, "store"))
    database_uuid = "13800000-0000-4000-8000-000000000001"
    table_uuid = "13810000-0000-4000-8000-00000000000#{table_number}"
    File.write(File.join(metadata, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
    database_dir = File.join(catalog, "store", database_uuid[0, 3], database_uuid)
    FileUtils.mkdir_p(database_dir)
    File.write(File.join(database_dir, "events.sql"),
      "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` #{DECLARATION}\n)\nENGINE = MergeTree\nORDER BY `pk`\n")
    table_dir = File.join(catalog, "store", table_uuid[0, 3], table_uuid)
    FileUtils.mkdir_p(table_dir)
    FileUtils.mkdir_p(File.join(table_dir, "detached"))
    File.write(File.join(table_dir, "format_version.txt"), "1\n")
    destination = File.join(table_dir, part[:name])
    assert(!File.exists?(destination) && !File.symlink?(destination),
      "#{label}: independent catalog destination is occupied before copy")
    FileUtils.cp_r(part[:path], destination)
    assert_tree(destination, "#{label} copied catalog part")
    {root: catalog, part_path: File.realpath(destination)}
  end

  private def catalog_values(catalog_root : String, label : String) : Nil
    selection = CrystalClick::OfflineCatalog.open(catalog_root)["lab"]["events"]["payload"]
    values = selection.values.map(&.as(CrystalClick::ObjectDocument))
    assert_documents(expected_documents, values, "#{label} OfflineCatalog.values")
    owned_bytes = values[1].value_for("e8").bytes
    owned_bytes[0] ^= 1_u8
    assert(values[1].value_for("e8").bytes == raw_bytes("e8", 1),
      "#{label}: mutating a detached Enum byte snapshot changed the returned document")
    values.clear
    assert_documents(expected_documents,
      selection.values.map(&.as(CrystalClick::ObjectDocument)), "#{label} owned re-materialization")
  end

  private def capture(batch : CrystalClick::WidePartTableBatch) : CapturedBatch
    {
      part_index: batch.part_index, part_name: batch.part_name, part_path: batch.part_path,
      mark_index: batch.mark_index, mark_row_offset: batch.mark_row_offset,
      part_row_offset: batch.part_row_offset, source_row_offset: batch.source_row_offset,
      keys: batch.values_for("pk").to_a, payload: batch.object_documents_for("payload").to_a,
    }
  end

  private def assert_batches(
    actual : Array(CapturedBatch), part_name : String, part_path : String,
    mark_indices : Array(Int32), mark_offsets : Array(UInt64), part_offsets : Array(UInt64),
    expected_keys : Array(Array(UInt64)), label : String,
  ) : Nil
    count = expected_keys.size
    assert(actual.size == count && mark_indices.size == count && mark_offsets.size == count && part_offsets.size == count,
      "#{label}: callback count differs")
    documents = expected_documents
    count.times do |index|
      batch = actual[index]
      assert(batch[:part_index] == 0_i32 && batch[:part_name] == part_name && batch[:part_path] == part_path,
        "#{label}: part provenance differs at callback #{index}")
      assert(batch[:mark_index] == mark_indices[index] && batch[:mark_row_offset] == mark_offsets[index],
        "#{label}: physical mark location differs at callback #{index}")
      assert(batch[:part_row_offset] == part_offsets[index] && batch[:source_row_offset] == part_offsets[index],
        "#{label}: table row offset differs at callback #{index}")
      assert(batch[:keys] == expected_keys[index], "#{label}: key rows differ at callback #{index}")
      assert_documents(batch[:keys].map { |key| documents[key.to_i - 1] }, batch[:payload], "#{label} callback #{index}")
    end
  end

  private def assert_table_delivery(catalog_root : String, expected_part_path : String, part : Part, label : String) : Nil
    table = CrystalClick::OfflineCatalog.open(catalog_root).table("lab", "events")
    resolved = table.resolved_scan_parts
    assert(resolved.map(&.name) == [part[:name]], "#{label}: table catalog part inventory differs")
    resolved_path = resolved[0].path
    assert(resolved_path == expected_part_path,
      "#{label}: catalog resolved part differs from the independently copied destination")
    full = [] of CapturedBatch
    table.scan_typed(["pk", "payload"], batch_rows: 2) do |batch|
      assert(batch.column_names == ["pk", "payload"], "#{label}: typed table changed caller column order")
      full << capture(batch)
      nil
    end
    assert_batches(full, part[:name], resolved_path,
      [0_i32, 1_i32, 2_i32, 3_i32], [0_u64, 0_u64, 0_u64, 0_u64],
      [0_u64, 2_u64, 4_u64, 6_u64], [[1_u64, 2_u64], [3_u64, 4_u64], [5_u64, 6_u64], [7_u64]],
      "#{label} full table scan")
    window = [] of CapturedBatch
    table.scan_typed_window(["pk", "payload"], 1_u64, max_rows: 3) { |batch| window << capture(batch); nil }
    assert_batches(window, part[:name], resolved_path,
      [0_i32, 1_i32], [1_u64, 0_u64], [1_u64, 2_u64], [[2_u64], [3_u64, 4_u64]],
      "#{label} physical window")
    candidates = [] of CapturedBatch
    table.scan_uint64_pk_candidates(["pk", "payload"], lower_bound: 6_u64, upper_bound: 6_u64) do |batch|
      candidates << capture(batch)
      nil
    end
    assert(candidates.map(&.[:mark_index]) == [2_i32], "#{label}: table candidate callback schedule differs")
    assert_batches(candidates, part[:name], resolved_path,
      [2_i32], [0_u64], [4_u64], [[5_u64, 6_u64]], "#{label} whole PK candidate granule")
    assert(candidates.sum(&.[:keys].size) == 2, "#{label}: PK=6 candidate did not retain its full granule")
    residual_keys = [] of UInt64
    residual_documents = [] of CrystalClick::ObjectDocument
    rejected_keys = [] of UInt64
    candidates.each do |batch|
      batch[:keys].each_with_index do |key, row|
        if key == 6_u64
          residual_keys << key
          residual_documents << batch[:payload][row]
        else
          rejected_keys << key
        end
      end
    end
    assert(residual_keys == [6_u64] && rejected_keys == [5_u64],
      "#{label}: exact PK residual did not separate row 6 from candidate row 5")
    assert_documents([expected_documents[5]], residual_documents, "#{label} exact PK residual")
  end

  private def replace_field(
    document : CrystalClick::ObjectDocument, path : String, replacement : CrystalClick::BinaryValue,
  ) : CrystalClick::ObjectDocument
    fields = {} of String => CrystalClick::BinaryValue
    document.paths.each { |field| fields[field] = field == path ? replacement : document.value_for(field) }
    CrystalClick::ObjectDocument.new(fields)
  end

  private def replace_document(
    documents : Array(CrystalClick::ObjectDocument), row : Int32, path : String,
    replacement : CrystalClick::BinaryValue,
  ) : Array(CrystalClick::ObjectDocument)
    mutated = documents.dup
    mutated[row] = replace_field(documents[row], path, replacement)
    mutated
  end

  private def assert_comparator_sensitivity(
    check : String, full_binary : String, full_labels : String, part_name : String,
  ) : Nil
    expected = expected_documents

    changed8 = raw_bytes("e8", 2)
    changed8[0] ^= 1_u8
    expect_mismatch("changed Enum8 signed raw byte") do
      assert_documents(expected, replace_document(expected, 2, "e8",
        CrystalClick::BinaryValue.fixed(ENUM8_TYPE, changed8)), "seeded Enum8 raw byte defect")
    end

    wrong_endian16 = Bytes.new(2) { |offset| raw_bytes("e16", 5)[1 - offset] }
    expect_mismatch("reversed Enum16 signed raw bytes") do
      assert_documents(expected, replace_document(expected, 5, "e16",
        CrystalClick::BinaryValue.fixed(ENUM16_TYPE, wrong_endian16)), "seeded Enum16 endian defect")
    end

    expect_mismatch("same-width Int8 alias for Enum8") do
      alias_value = CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("Int8"), raw_bytes("e8", 1))
      assert_documents(expected, replace_document(expected, 1, "e8", alias_value), "seeded Int8 alias")
    end

    expect_mismatch("same-width Int16 alias for Enum16") do
      alias_value = CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("Int16"), raw_bytes("e16", 1))
      assert_documents(expected, replace_document(expected, 1, "e16", alias_value), "seeded Int16 alias")
    end

    drift8_entries = ENUM8_ENTRIES.map { |label, code| {code == -7_i16 ? "wrong'λ" : label, code} }
    drift8 = CrystalClick::BinaryDataType.enum8(drift8_entries)
    expect_mismatch("Enum8 same-code label map drift") do
      assert_documents(expected, replace_document(expected, 3, "e8",
        CrystalClick::BinaryValue.fixed(drift8, raw_bytes("e8", 3))), "seeded Enum8 map drift")
    end

    drift16_entries = ENUM16_ENTRIES.map { |label, code| {label, code == 7_i16 ? 8_i16 : code} }
    drift16 = CrystalClick::BinaryDataType.enum16(drift16_entries)
    expect_mismatch("Enum16 same-label code map drift with unchanged raw bytes") do
      assert_documents(expected, replace_document(expected, 2, "e16",
        CrystalClick::BinaryValue.fixed(drift16, raw_bytes("e16", 2))), "seeded Enum16 code-map drift")
    end

    wrong_labels8 = ENUM8_LABELS.dup
    wrong_labels8[0] = "not-empty"
    expect_mismatch("label output compared independently of raw codes") do
      compare_label_rows(full_labels, (0...KEYS.size).to_a, wrong_labels8, ENUM16_LABELS, "seeded wrong label expectation")
    end

    sparse_serializer = JSON.parse(%({"columns":[{"name":"payload.e8","kind":"Sparse"}]}))
    expect_mismatch("Sparse serializer metadata") do
      assert_default_serializers(sparse_serializer, "seeded Sparse serializer")
    end

    wrong_check = check.gsub("\t1\t", "\t0\t")
    assert(wrong_check != check, "CHECK comparator control did not mutate its positive row")
    expect_mismatch("wrong CHECK TABLE result") { assert_check(wrong_check, part_name, "seeded wrong CHECK") }

    truncated = String.new(full_binary.to_slice[0, full_binary.bytesize - 1])
    expect_mismatch("truncated Enum RowBinary") do
      assert_rowbinary(truncated, (0...KEYS.size).to_a, "seeded truncated RowBinary")
    end

    wrong_grid = [2_u64, 1_u64, 3_u64, 1_u64]
    assert(wrong_grid.sum == KEYS.size.to_u64, "seeded mark-grid control changed the total row count")
    assert(wrong_grid != ROWS_PER_MARK, "seeded mark-grid control did not change the distribution")
    expect_mismatch("wrong physical mark grid with unchanged seven-row total") do
      assert_grid(wrong_grid, "seeded wrong physical grid")
    end
  end

  private def write_fixture_manifest(root : String) : Nil
    manifest = JSON.parse(FIXTURE_MANIFEST).as_h
    enum8 = manifest["enum8"].as_h
    enum16 = manifest["enum16"].as_h
    assert(enum8["width_bytes"].as_i64 == 1 && enum16["width_bytes"].as_i64 == 2,
      "W138 fixture manifest enum widths differ")
    manifest8 = enum8["entries"].as_a.map do |entry|
      fields = entry.as_h
      {fields["label"].as_s, fields["code"].as_i64.to_i16}
    end
    manifest16 = enum16["entries"].as_a.map do |entry|
      fields = entry.as_h
      {fields["label"].as_s, fields["code"].as_i64.to_i16}
    end
    assert(manifest8 == ENUM8_ENTRIES && manifest16 == ENUM16_ENTRIES,
      "literal manifest Enum maps differ from the separately authored label/code tables")
    manifest_rows = manifest["rows"].as_a
    assert(manifest_rows.size == KEYS.size, "W138 fixture manifest row count differs")
    KEYS.each_with_index do |key, index|
      fields = manifest_rows[index].as_h
      assert(fields["pk"].as_i64.to_u64 == key &&
             fields["enum8_label"].as_s == ENUM8_LABELS[index] &&
             fields["enum8_raw_hex"].as_s == ENUM8_RAW_HEX[index] &&
             fields["enum16_label"].as_s == ENUM16_LABELS[index] &&
             fields["enum16_raw_hex"].as_s == ENUM16_RAW_HEX[index],
        "literal manifest label/raw channels differ at row #{index}")
    end

    path = File.join(root, "fixture_manifest.json")
    assert(!File.exists?(path) && !File.symlink?(path), "W138 fixture manifest path is occupied or unsafe")
    File.write(path, FIXTURE_MANIFEST)
    assert(File.read(path) == FIXTURE_MANIFEST, "W138 fixture manifest bytes differ from the authored literal")
    puts "W138 independent fixture manifest: #{path}"
  end

  private def assert_full_enum16_schema_capacity : Nil
    entries = (0...65_536).map do |index|
      {"full_#{index}", (index - 32_768).to_i16}
    end
    full_type = CrystalClick::BinaryDataType.enum16(entries)
    full_entries = full_type.enum_definition.not_nil!.entries
    assert(full_entries.size == 65_536, "Enum16 schema check did not retain all 65,536 distinct codes")
    assert(full_entries.first == {"full_0", -32_768_i16} && full_entries.last == {"full_65535", 32_767_i16},
      "Enum16 full-domain schema check lost one signed endpoint")
    full_schema = CrystalClick::ObjectDocumentSchema.new({"full" => full_type})
    assert(full_schema.typed_paths["full"] == full_type,
      "Object schema admission changed the full Enum16 map")
    puts "PASS W138 full Enum16 schema map admission: 65,536 entries"
  end

  private def assert_schema_guards(schema : CrystalClick::ObjectDocumentSchema) : Nil
    assert(ENUM8_TYPE.name == ENUM8_DECLARATION, "literal Enum8 canonical table ordering or escaping differs")
    assert(ENUM16_TYPE.name == ENUM16_DECLARATION, "literal Enum16 canonical table ordering or escaping differs")
    assert(ENUM8_TYPE.enum_definition.not_nil!.entries == ENUM8_ENTRIES,
      "Enum8 label/code table differs from its independently authored entries")
    assert(ENUM16_TYPE.enum_definition.not_nil!.entries == ENUM16_ENTRIES,
      "Enum16 label/code table differs from its independently authored entries")
    assert(schema.typed_paths == typed_schema, "canonical schema lost an Enum map or typed path")
    assert(schema.typed_paths["e8"].enum_definition.not_nil!.entries == ENUM8_ENTRIES,
      "parsed Enum8 map drifted from the literal oracle")
    assert(schema.typed_paths["e16"].enum_definition.not_nil!.entries == ENUM16_ENTRIES,
      "parsed Enum16 map drifted from the literal oracle")
    assert(schema.typed_paths.size == 3, "W138 declaration must retain exactly two Enums and String")

    expect_argument_error("Enum8 code above 127") do
      CrystalClick::BinaryDataType.enum8([{"outside", 128_i16}])
    end
    expect_argument_error("duplicate Enum16 code") do
      CrystalClick::BinaryDataType.enum16([{"first", 1_i16}, {"second", 1_i16}])
    end
    begin
      CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(bad Enum16('outside' = -32769))")
      fail("Object schema parser admitted an Enum16 code below -32768")
    rescue error : CrystalClick::UnsupportedFormatError
      puts "PASS W138 declaration parser rejects an Enum16 code below -32768"
    end
    assert_full_enum16_schema_capacity
    puts "PASS W138 signed code domains and exact label/code map admission"
  end

  private def native_case(
    binary : String, root : String, profile_name : String, profile : CrystalClick::BinaryBulkProfile,
    mode_name : String, mode : UInt64, case_number : Int32, check_negative_controls : Bool,
  ) : Nil
    label = "native_#{profile_name}_#{mode_name}"
    store = File.join(root, "stores", label)
    FileUtils.mkdir_p(store)
    table = table_name(label)
    create_table(binary, store, table, profile_name, mode, label)
    run(binary, store, "INSERT INTO default.#{table} FORMAT JSONEachRow",
      IO::Memory.new(NATIVE_JSON_ROWS.join("\n") + "\n"))
    part = stock_part(binary, store, table, label)
    check, full_binary, full_labels = assert_stock_sql(binary, store, table, part[:name], label)
    assert_comparator_sensitivity(check, full_binary, full_labels, part[:name]) if check_negative_controls
    schema = CrystalClick::ObjectDocumentSchema.parse_declaration(DECLARATION)
    assert_part_profile(part, schema, profile, mode, label)
    assert_object_reader(part, schema, label)
    catalog = catalog_root(root, label, case_number, part)
    catalog_values(catalog[:root], label)
    assert_table_delivery(catalog[:root], catalog[:part_path], part, label)
    puts "PASS W138 native label JSON -> stock CHECK/label SQL/raw Enum RowBinary -> Object reader/catalog/table: #{label}"
  end

  private def library_case(
    binary : String, root : String, profile_name : String, profile : CrystalClick::BinaryBulkProfile,
    mode_name : String, mode : UInt64, table_number : Int32,
  ) : Nil
    label = "library_#{profile_name}_#{mode_name}"
    store = File.join(root, "stores", label)
    FileUtils.mkdir_p(store)
    table = table_name(label)
    create_table(binary, store, table, profile_name, mode, label)
    active = run(binary, store,
      "SELECT count() FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").strip
    assert(active == "0", "#{label}: target table is not empty before library part publication")
    data_path = table_data_path(binary, store, table, label)
    detached = File.join(data_path, "detached")
    FileUtils.mkdir_p(detached)
    detached = store_child(detached, store, "#{label} detached directory")
    part_name = "all_1_1_0"
    part_path = File.join(detached, part_name)
    assert(!File.exists?(part_path) && !File.symlink?(part_path), "#{label}: detached part path is occupied")
    schema = CrystalClick::ObjectDocumentSchema.parse_declaration(DECLARATION)
    CrystalClick::WidePartWriter.write_uint64_object_pair(
      part_path, "pk", Slice(UInt64).new(KEYS.size) { |index| KEYS[index] },
      "payload", schema, plan, granules(expected_documents), rows_per_mark: 2, mode: mode,
      profile: profile, shared_profile: CrystalClick::BinaryBulkProfile.single_stream, frame_bytes: FRAME_BYTES
    )
    part_path = store_child(part_path, store, "#{label} library-written part")
    run(binary, store, "ALTER TABLE default.#{table} ATTACH PART '#{part_name}'")
    part = stock_part(binary, store, table, label)
    assert(part[:name] == part_name, "#{label}: ATTACH changed the library part identity")
    assert_stock_sql(binary, store, table, part[:name], label)
    assert_part_profile(part, schema, profile, mode, label)
    assert_object_reader(part, schema, label)
    catalog = catalog_root(root, label, table_number, part)
    catalog_values(catalog[:root], label)
    assert_table_delivery(catalog[:root], catalog[:part_path], part, label)
    puts "PASS W138 library part -> stock ATTACH/CHECK/label SQL/raw Enum RowBinary -> Object reader/catalog/table: #{label}"
  end

  def check : Nil
    binary = ENV["CLICKHOUSE_BIN"]? || raise "CLICKHOUSE_BIN is required"
    root = ENV["W138_TMP_ROOT"]? || raise "W138_TMP_ROOT is required"
    assert(!File.symlink?(root) && Dir.exists?(root), "W138 temporary root must be an existing non-symlink directory")
    root = File.realpath(root)
    assert(root.starts_with?("/private/tmp/crystal-click-object-enum-w138."), "unsafe W138 temporary root")
    write_fixture_manifest(root)
    assert(KEYS.size == 7 && ENUM8_RAW_HEX.size == 7 && ENUM16_RAW_HEX.size == 7 && NATIVE_JSON_ROWS.size == 7,
      "W138 independent seven-row fixture inventory changed")
    assert(ROWS_PER_MARK == [2_u64, 2_u64, 2_u64, 1_u64], "W138 physical mark fixture changed")
    {"e8", "e16"}.each do |path|
      labels = enum_labels(path)
      hexes = enum_raw_hex(path)
      assert(labels.size == 7 && hexes.size == 7, "#{path}: literal label/raw fixture count differs")
      7.times do |index|
        assert(raw_bytes(path, index).size == (path == "e8" ? 1 : 2), "#{path} row #{index}: raw width differs")
      end
    end
    schema = CrystalClick::ObjectDocumentSchema.parse_declaration(DECLARATION)
    assert(schema.declaration == DECLARATION && schema.typed_paths == typed_schema,
      "W138 canonical declared Enum maps differ from authored schema")
    assert_schema_guards(schema)

    bootstrap_store = File.join(root, "bootstrap")
    FileUtils.mkdir_p(bootstrap_store)
    verify_runtime(binary, bootstrap_store)

    puts "W138 literal domain: Enum8 -128..127 and Enum16 -32768..32767; independent map, label-text, and signed-byte channels; empty/UTF-8/punctuation plus all eight string escapes"
    puts "W138 bounded corridor: 4 stock JSONEachRow + 4 library ATTACH cells; String single_stream/with_size_stream x Dynamic BASIC/COMPACT; Object V3 one MAP bucket; LZ4 Wide; grid 2,2,2,1; plain .mrk2 and primary.idx"
    case_number = 1
    PROFILES.each do |profile_name, profile|
      MODES.each do |mode_name, mode|
        native_case(binary, root, profile_name, profile, mode_name, mode, case_number,
          check_negative_controls: case_number == 1)
        case_number += 1
      end
    end
    library_table_number = 5
    PROFILES.each do |profile_name, profile|
      MODES.each do |mode_name, mode|
        library_case(binary, root, profile_name, profile, mode_name, mode, library_table_number)
        library_table_number += 1
      end
    end
    puts "PASS W138 scope: paired canonical bare Enum8/Enum16 declared Object fields; no Nullable, alias, nested, enum arithmetic, or general MergeTree claim"
  end
end

W138Oracle.new.check
