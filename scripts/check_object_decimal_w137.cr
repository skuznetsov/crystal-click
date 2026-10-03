# W137 declared Decimal Object interoperability oracle.
#
# Native JSON decimal strings and library-owned signed little-endian
# coefficients are independent fixtures. The matrix covers all four wire
# widths and their precision boundaries; it does not exercise Decimal
# arithmetic, conversion, or rounding.
require "file_utils"
require "json"
require "../src/crystal_click"
require "./w122_bulk_vectors"

class W137Oracle
  class Mismatch < Exception
  end

  VERSION           = "26.10.1.1201"
  BUILD_HASH        = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
  EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
  FRAME_BYTES       = 16
  DECLARATION       = "JSON(max_dynamic_types=1, max_dynamic_paths=1, p10_s4 Decimal(10, 4), p18_s18 Decimal(18, 18), p19_s6 Decimal(19, 6), p1_s0 Decimal(1, 0), p38_s38 Decimal(38, 38), p39_s8 Decimal(39, 8), p76_s76 Decimal(76, 76), p8_s2 Decimal(8, 2), p9_s9 Decimal(9, 9), t String)"
  SETTINGS_BASE     = "index_granularity=2, index_granularity_bytes=10485760, enable_mixed_granularity_parts=1, min_rows_for_wide_part=0, min_bytes_for_wide_part=0, compress_marks=0, compress_primary_key=0, min_compress_block_size=0, max_compress_block_size=4096, ratio_of_defaults_for_sparse_serialization=1, default_compression_codec='LZ4', object_serialization_version='v3', object_shared_data_serialization_version_for_zero_level_parts='map', propagate_types_serialization_versions_to_nested_types=true"
  KEYS              = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
  TEXT              = ["zero", "alpha", "λ雪", "é", "終", "", "tail"]
  DYNAMIC           = [11_i64, 22_i64, 33_i64, 44_i64, 55_i64, 66_i64, 77_i64]
  ROWS_PER_MARK     = [2_u64, 2_u64, 2_u64, 1_u64]
  TYPE_SPECS        = [
    {"p1_s0", "Decimal(1, 0)", 32, 1, 0},
    {"p8_s2", "Decimal(8, 2)", 32, 8, 2},
    {"p9_s9", "Decimal(9, 9)", 32, 9, 9},
    {"p10_s4", "Decimal(10, 4)", 64, 10, 4},
    {"p18_s18", "Decimal(18, 18)", 64, 18, 18},
    {"p19_s6", "Decimal(19, 6)", 128, 19, 6},
    {"p38_s38", "Decimal(38, 38)", 128, 38, 38},
    {"p39_s8", "Decimal(39, 8)", 256, 39, 8},
    {"p76_s76", "Decimal(76, 76)", 256, 76, 76},
  ] of Tuple(String, String, Int32, Int32, Int32)

  # These display strings are an independent oracle for stock SQL output.
  DECIMAL_TEXT = {
    "p1_s0"   => ["0", "-4", "1", "-1", "2", "9", "-9"],
    "p8_s2"   => ["0.00", "-234567.89", "0.01", "-0.01", "123456.78", "999999.99", "-999999.99"],
    "p9_s9"   => ["0.000000000", "-0.234567890", "0.000000001", "-0.000000001", "0.123456789", "0.999999999", "-0.999999999"],
    "p10_s4"  => ["0.0000", "-234567.8901", "0.0001", "-0.0001", "123456.7890", "999999.9999", "-999999.9999"],
    "p18_s18" => ["0.000000000000000000", "-0.234567890123456789", "0.000000000000000001", "-0.000000000000000001", "0.123456789012345678", "0.999999999999999999", "-0.999999999999999999"],
    "p19_s6"  => ["0.000000", "-2345678901234.567890", "0.000001", "-0.000001", "1234567890123.456789", "9999999999999.999999", "-9999999999999.999999"],
    "p38_s38" => ["0.00000000000000000000000000000000000000", "-0.23456789012345678901234567890123456789", "0.00000000000000000000000000000000000001", "-0.00000000000000000000000000000000000001", "0.12345678901234567890123456789012345678", "0.99999999999999999999999999999999999999", "-0.99999999999999999999999999999999999999"],
    "p39_s8"  => ["0.00000000", "-2345678901234567890123456789012.34567890", "0.00000001", "-0.00000001", "1234567890123456789012345678901.23456789", "9999999999999999999999999999999.99999999", "-9999999999999999999999999999999.99999999"],
    "p76_s76" => ["0.0000000000000000000000000000000000000000000000000000000000000000000000000000", "-0.2345678901234567890123456789012345678901234567890123456789012345678901234567", "0.0000000000000000000000000000000000000000000000000000000000000000000000000001", "-0.0000000000000000000000000000000000000000000000000000000000000000000000000001", "0.1234567890123456789012345678901234567890123456789012345678901234567890123456", "0.9999999999999999999999999999999999999999999999999999999999999999999999999999", "-0.9999999999999999999999999999999999999999999999999999999999999999999999999999"],
  } of String => Array(String)

  # Signed coefficient bytes are independently literal little-endian two's
  # complement. No production conversion code derives these expectations.
  DECIMAL_HEX = {
    "p1_s0"   => ["00000000", "fcffffff", "01000000", "ffffffff", "02000000", "09000000", "f7ffffff"],
    "p8_s2"   => ["00000000", "eb139afe", "01000000", "ffffffff", "4e61bc00", "ffe0f505", "011f0afa"],
    "p9_s9"   => ["00000000", "2ec704f2", "01000000", "ffffffff", "15cd5b07", "ffc99a3b", "013665c4"],
    "p10_s4"  => ["0000000000000000", "cbc72f74ffffffff", "0100000000000000", "ffffffffffffffff", "d202964900000000", "ffe30b5402000000", "011cf4abfdffffff"],
    "p18_s18" => ["0000000000000000", "eb7e7a29bfa5befc", "0100000000000000", "ffffffffffffffff", "4ef330a64b9bb601", "ffff63a7b3b6e00d", "01009c584c491ff2"],
    "p19_s6"  => ["00000000000000000000000000000000", "2ef5c89e777972dfffffffffffffffff", "01000000000000000000000000000000", "ffffffffffffffffffffffffffffffff", "1581e97df41022110000000000000000", "ffffe7890423c78a0000000000000000", "01001876fbdc3875ffffffffffffffff"],
    "p38_s38" => ["00000000000000000000000000000000", "eb7ec651177faa5eb4c570fa02635aee", "01000000000000000000000000000000", "ffffffffffffffffffffffffffffffff", "4ef338de509049c4133302f0f6b04909", "ffffffff3f228a097ac4865aa84c3b4b", "01000000c0dd75f6853b79a557b3c4b4"],
    "p39_s8"  => ["0000000000000000000000000000000000000000000000000000000000000000", "2ef5c031e9f6a8b20bb967c81dde874fffffffffffffffffffffffffffffffff", "0100000000000000000000000000000000000000000000000000000000000000", "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "158139ae28a3dfaac5fe1560a5e9e05c00000000000000000000000000000000", "ffffffff7f56655fc4ac438993fe50f002000000000000000000000000000000", "0100000080a99aa03b53bc766c01af0ffdffffffffffffffffffffffffffffff"],
    "p76_s76" => ["0000000000000000000000000000000000000000000000000000000000000000", "79b460835162ee4e70b752249bb3b1909e3fe9858aead4e6ca1a87eb8d64d0fa", "0100000000000000000000000000000000000000000000000000000000000000", "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "c0badc72915c1bf8a7d5b9076fcb464afc30d98936944103b132681d9cbdba02", "ffffffffffffffffff0f9571f1a57577792965e8abb46407b5159911a7cc1b16", "010000000000000000f06a8e0e5a8a8886d69a17544b9bf84aea66ee5833e4e9"],
  } of String => Array(String)

  PROFILES = [
    {"single_stream", CrystalClick::BinaryBulkProfile.single_stream},
    {"with_size_stream", CrystalClick::BinaryBulkProfile.with_size_stream},
  ]
  MODES = [
    {"basic", CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE},
    {"compact", CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE},
  ]

  # Stock JSONEachRow input is deliberately written as decimal strings; it is
  # not generated from DECIMAL_TEXT or from the raw binary carrier fixtures.
  NATIVE_JSON_ROWS = [
    %({"pk":1,"payload":{"p1_s0":"0","p8_s2":"0.00","p9_s9":"0.000000000","p10_s4":"0.0000","p18_s18":"0.000000000000000000","p19_s6":"0.000000","p38_s38":"0.00000000000000000000000000000000000000","p39_s8":"0.00000000","p76_s76":"0.0000000000000000000000000000000000000000000000000000000000000000000000000000","t":"zero","d":11,"spill":"alpha"}}),
    %({"pk":2,"payload":{"p1_s0":"-4","p8_s2":"-234567.89","p9_s9":"-0.234567890","p10_s4":"-234567.8901","p18_s18":"-0.234567890123456789","p19_s6":"-2345678901234.567890","p38_s38":"-0.23456789012345678901234567890123456789","p39_s8":"-2345678901234567890123456789012.34567890","p76_s76":"-0.2345678901234567890123456789012345678901234567890123456789012345678901234567","t":"alpha","d":22}}),
    %({"pk":3,"payload":{"p1_s0":"1","p8_s2":"0.01","p9_s9":"0.000000001","p10_s4":"0.0001","p18_s18":"0.000000000000000001","p19_s6":"0.000001","p38_s38":"0.00000000000000000000000000000000000001","p39_s8":"0.00000001","p76_s76":"0.0000000000000000000000000000000000000000000000000000000000000000000000000001","t":"λ雪","d":33}}),
    %({"pk":4,"payload":{"p1_s0":"-1","p8_s2":"-0.01","p9_s9":"-0.000000001","p10_s4":"-0.0001","p18_s18":"-0.000000000000000001","p19_s6":"-0.000001","p38_s38":"-0.00000000000000000000000000000000000001","p39_s8":"-0.00000001","p76_s76":"-0.0000000000000000000000000000000000000000000000000000000000000000000000000001","t":"é","d":44}}),
    %({"pk":5,"payload":{"p1_s0":"2","p8_s2":"123456.78","p9_s9":"0.123456789","p10_s4":"123456.7890","p18_s18":"0.123456789012345678","p19_s6":"1234567890123.456789","p38_s38":"0.12345678901234567890123456789012345678","p39_s8":"1234567890123456789012345678901.23456789","p76_s76":"0.1234567890123456789012345678901234567890123456789012345678901234567890123456","t":"終","d":55}}),
    %({"pk":6,"payload":{"p1_s0":"9","p8_s2":"999999.99","p9_s9":"0.999999999","p10_s4":"999999.9999","p18_s18":"0.999999999999999999","p19_s6":"9999999999999.999999","p38_s38":"0.99999999999999999999999999999999999999","p39_s8":"9999999999999999999999999999999.99999999","p76_s76":"0.9999999999999999999999999999999999999999999999999999999999999999999999999999","t":"","d":66}}),
    %({"pk":7,"payload":{"p1_s0":"-9","p8_s2":"-999999.99","p9_s9":"-0.999999999","p10_s4":"-999999.9999","p18_s18":"-0.999999999999999999","p19_s6":"-9999999999999.999999","p38_s38":"-0.99999999999999999999999999999999999999","p39_s8":"-9999999999999999999999999999999.99999999","p76_s76":"-0.9999999999999999999999999999999999999999999999999999999999999999999999999999","t":"tail","d":77,"spill":"omega"}}),
  ]

  alias TypeSpec = Tuple(String, String, Int32, Int32, Int32)
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
      puts "PASS W137 seeded comparator failure: #{label}"
      return
    end
    fail("#{label}: seeded mismatch passed the oracle comparator")
  end

  private def expect_argument_error(label : String, &)
    begin
      yield
    rescue error : ArgumentError
      puts "PASS W137 schema admission rejects: #{label}"
      return
    end
    fail("#{label}: invalid Decimal schema was admitted")
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

  private def table_name(label : String) : String
    "w137_#{label.gsub('-', "_")}"
  end

  private def decimal_type(spec : TypeSpec) : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.decimal(spec[2], spec[3], spec[4])
  end

  private def typed_schema : Hash(String, CrystalClick::BinaryDataType)
    fields = {} of String => CrystalClick::BinaryDataType
    TYPE_SPECS.each { |spec| fields[spec[0]] = decimal_type(spec) }
    fields["t"] = CrystalClick::BinaryDataType.primitive("String")
    fields
  end

  private def create_table(binary : String, store : String, table : String, profile_name : String, mode : UInt64, label : String) : Nil
    compact = mode == CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE ? 1 : 0
    settings = "#{SETTINGS_BASE}, use_compact_variant_discriminators_serialization=#{compact}, string_serialization_version='#{profile_name}'"
    run(binary, store,
      "CREATE TABLE default.#{table} (`pk` UInt64, `payload` #{DECLARATION}) ENGINE=MergeTree ORDER BY `pk` SETTINGS #{settings}")
    actual = run(binary, store,
      "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
    expected = "pk UInt64\npayload #{DECLARATION}\n"
    assert(actual == expected, "#{label}: live columns differ from the independently authored DDL: #{actual.inspect}")
    schema = CrystalClick::ObjectDocumentSchema.parse_declaration(DECLARATION)
    assert(schema.declaration == DECLARATION, "#{label}: canonical parser declaration differs from authored DDL")
    assert(schema.typed_paths == typed_schema, "#{label}: typed path roster differs from authored DDL")
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

  private def raw_bytes(spec : TypeSpec, index : Int32) : Bytes
    hex = DECIMAL_HEX[spec[0]][index]
    source = hex.to_slice
    width = spec[2] // 8
    assert(source.size == width * 2, "#{spec[0]} row #{index}: literal coefficient width differs from Decimal wire width")
    Bytes.new(width) do |offset|
      (hex_nibble(source[offset * 2]) << 4) | hex_nibble(source[offset * 2 + 1])
    end
  end

  private def typed_value(spec : TypeSpec, index : Int32) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.fixed(decimal_type(spec), raw_bytes(spec, index))
  end

  private def document(index : Int32) : CrystalClick::ObjectDocument
    fields = {} of String => CrystalClick::BinaryValue
    TYPE_SPECS.each { |spec| fields[spec[0]] = typed_value(spec, index) }
    fields["t"] = CrystalClick::BinaryValue.string(TEXT[index])
    fields["d"] = CrystalClick::BinaryValue.int64(DYNAMIC[index])
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
          "#{label}: nominal type or exact bytes differ at row #{row}, path #{path.inspect}")
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
        TYPE_SPECS.each { |spec| io.write(raw_bytes(spec, index)) }
        write_string_binary(io, TEXT[index])
        # RowBinary Dynamic includes the independently authored Int64 type tag.
        io.write_byte(0x0a_u8)
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
    expected_start = offset > 8 ? offset - 8 : 0
    actual_start = expected_start
    expected_end = Math.min(expected_bytes.size, offset + 8)
    actual_end = Math.min(actual_bytes.size, offset + 8)
    expected_window = expected_bytes[expected_start, expected_end - expected_start].hexstring
    actual_window = actual_bytes[actual_start, actual_end - actual_start].hexstring
    "expected_bytes=#{expected_bytes.size}, actual_bytes=#{actual_bytes.size}, first_difference=#{offset}, " +
      "expected[#{expected_start}...#{expected_end}]=#{expected_window}, actual[#{actual_start}...#{actual_end}]=#{actual_window}"
  end

  private def assert_rowbinary(actual : String, indices : Array(Int32), label : String) : Nil
    expected = expected_rowbinary(indices)
    assert(actual.to_slice == expected.to_slice,
      "#{label}: exact Decimal/String/Dynamic RowBinary differs; #{rowbinary_mismatch_summary(expected, actual)}")
  end

  private def assert_check(actual : String, part_name : String, label : String) : Nil
    expected = "#{part_name}\t1\t\n"
    assert(actual == expected, "#{label}: CHECK TABLE row differs: #{actual.inspect}")
  end

  private def expected_sql_line(index : Int32) : String
    fields = [KEYS[index].to_s]
    TYPE_SPECS.each do |spec|
      fields << spec[1]
      fields << DECIMAL_TEXT[spec[0]][index]
    end
    fields << "String"
    fields << TEXT[index].to_slice.hexstring.upcase
    fields << TEXT[index].bytesize.to_s
    fields << DYNAMIC[index].to_s
    fields << "Int64"
    if index == 0
      fields << "String"
      fields << "616C706861"
    elsif index == 6
      fields << "String"
      fields << "6F6D656761"
    else
      fields << "None"
      fields << ""
    end
    fields.join('\t')
  end

  private def assert_sql_rows(actual : String, indices : Array(Int32), label : String) : Nil
    lines = actual.lines.map(&.chomp)
    expected = indices.map { |index| expected_sql_line(index) }
    assert(lines == expected, "#{label}: exact nominal Decimal/text SQL rows differ; expected #{expected.inspect}, got #{lines.inspect}")
  end

  private def assert_type_labels(binary : String, store : String, table : String, label : String) : Nil
    expressions = TYPE_SPECS.map { |spec| "toTypeName(payload.#{spec[0]})" }
    expressions << "toTypeName(payload.t)"
    expressions << "dynamicType(payload.d)"
    actual = run(binary, store,
      "SELECT #{expressions.join(", ")} FROM default.#{table} ORDER BY pk LIMIT 1 FORMAT TSVRaw").strip
    expected = (TYPE_SPECS.map(&.[1]) + ["String", "Int64"]).join('\t')
    assert(actual == expected, "#{label}: actual nominal type labels differ: #{actual.inspect}")
  end

  private def assert_stock_sql(binary : String, store : String, table : String, part_name : String, label : String) : {String, String}
    check = run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated")
    assert_check(check, part_name, "#{label} CHECK TABLE")
    projection = ["pk"]
    TYPE_SPECS.each do |spec|
      projection << "toTypeName(payload.#{spec[0]})"
      # Read the native Decimal value with trailing-zero preservation so the
      # oracle checks its declared scale, rather than toString's default form.
      projection << "payload.#{spec[0]}"
    end
    projection.concat([
      "toTypeName(payload.t)", "hex(payload.t)", "length(payload.t)", "payload.d", "dynamicType(payload.d)",
      "dynamicType(payload.spill)", "ifNull(hex(dynamicElement(payload.spill, 'String')), '')",
    ])
    full_sql = run(binary, store,
      "SELECT #{projection.join(", ")} FROM default.#{table} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0, output_format_decimal_trailing_zeros=1 FORMAT TSVRaw")
    assert_sql_rows(full_sql, (0...KEYS.size).to_a, "#{label} full SQL")
    selected_sql = run(binary, store,
      "SELECT #{projection.join(", ")} FROM default.#{table} WHERE pk >= 3 AND pk <= 4 ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0, output_format_decimal_trailing_zeros=1 FORMAT TSVRaw")
    assert_sql_rows(selected_sql, [2, 3], "#{label} PK 3..4 SQL")
    assert_type_labels(binary, store, table, label)

    rowbinary_projection = ["pk"] + TYPE_SPECS.map { |spec| "payload.#{spec[0]}" } + ["payload.t", "payload.d"]
    full_binary = run(binary, store,
      "SELECT #{rowbinary_projection.join(", ")} FROM default.#{table} ORDER BY pk FORMAT RowBinary")
    assert_rowbinary(full_binary, (0...KEYS.size).to_a, "#{label} full RowBinary")
    selected_binary = run(binary, store,
      "SELECT #{rowbinary_projection.join(", ")} FROM default.#{table} WHERE pk >= 3 AND pk <= 4 ORDER BY pk FORMAT RowBinary")
    assert_rowbinary(selected_binary, [2, 3], "#{label} PK RowBinary")
    {check, full_binary}
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
    assert(descriptor.plan.typed_paths == typed_schema, "#{label}: actual typed schema plan differs")
    assert(descriptor.plan.typed_paths.size == 10, "#{label}: actual Object schema must have nine Decimal fields plus String")
    TYPE_SPECS.each do |spec|
      actual_type = descriptor.plan.typed_type_for(spec[0])
      assert(actual_type == decimal_type(spec), "#{label}: actual Decimal descriptor differs for #{spec[0]}")
    end
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
    database_uuid = "13700000-0000-4000-8000-000000000001"
    table_uuid = "13710000-0000-4000-8000-00000000000#{table_number}"
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
    field = TYPE_SPECS.last[0]
    owned_bytes = values[1].value_for(field).bytes
    owned_bytes[0] ^= 1_u8
    assert(values[1].value_for(field).bytes == raw_bytes(TYPE_SPECS.last, 1),
      "#{label}: mutating a detached Decimal byte snapshot changed the returned document")
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
    assert(candidates.sum(&.[:keys].size) == 2, "#{label}: PK=6 candidate did not retain the full granule")
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

  private def replace_field(document : CrystalClick::ObjectDocument, path : String, replacement : CrystalClick::BinaryValue) : CrystalClick::ObjectDocument
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

  private def assert_comparator_sensitivity(check : String, full_binary : String, part_name : String) : Nil
    expected = expected_documents
    p76 = TYPE_SPECS.last
    negative = expected[1].value_for(p76[0]).bytes
    changed_sign = negative.dup
    changed_sign[changed_sign.size - 1] ^= 0x80_u8
    sign_value = CrystalClick::BinaryValue.fixed(decimal_type(p76), changed_sign)
    expect_mismatch("flipped raw Decimal sign bit") do
      assert_documents(expected, replace_document(expected, 1, p76[0], sign_value), "seeded sign-bit defect")
    end

    wrong_endian = Bytes.new(negative.size) { |offset| negative[negative.size - offset - 1] }
    endian_value = CrystalClick::BinaryValue.fixed(decimal_type(p76), wrong_endian)
    expect_mismatch("reversed Decimal coefficient byte order") do
      assert_documents(expected, replace_document(expected, 1, p76[0], endian_value), "seeded endian defect")
    end

    altered = expected[0].value_for(p76[0]).bytes
    altered[0] ^= 1_u8
    altered_value = CrystalClick::BinaryValue.fixed(decimal_type(p76), altered)
    expect_mismatch("changed raw Decimal coefficient bytes") do
      assert_documents(expected, replace_document(expected, 0, p76[0], altered_value), "seeded raw-byte defect")
    end

    d1 = TYPE_SPECS.first
    d1_bytes = expected[2].value_for(d1[0]).bytes
    int_alias = CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("Int32"), d1_bytes)
    expect_mismatch("same-width Int32 alias for Decimal32") do
      assert_documents(expected, replace_document(expected, 2, d1[0], int_alias), "seeded Int32 alias")
    end

    d8 = TYPE_SPECS[1]
    precision_only = CrystalClick::BinaryDataType.decimal(32, 7, 2)
    precision_value = CrystalClick::BinaryValue.fixed(precision_only, expected[2].value_for(d8[0]).bytes)
    expect_mismatch("same-width Decimal with different precision only") do
      assert_documents(expected, replace_document(expected, 2, d8[0], precision_value), "seeded Decimal precision alias")
    end
    scale_only = CrystalClick::BinaryDataType.decimal(32, 8, 1)
    scale_value = CrystalClick::BinaryValue.fixed(scale_only, expected[2].value_for(d8[0]).bytes)
    expect_mismatch("same-width Decimal with different scale only") do
      assert_documents(expected, replace_document(expected, 2, d8[0], scale_value), "seeded Decimal scale alias")
    end

    expect_mismatch("Sparse serializer metadata") do
      assert_default_serializers(JSON.parse(%({"columns":[{"name":"payload.p76_s76","kind":"Sparse"}]})), "seeded Sparse serializer")
    end
    expect_mismatch("wrong physical mark grid") do
      assert_grid([2_u64, 1_u64, 2_u64, 2_u64], "seeded wrong physical grid")
    end
    wrong_check = check.gsub("\t1\t", "\t0\t")
    assert(wrong_check != check, "CHECK comparator control did not mutate its positive row")
    expect_mismatch("wrong CHECK TABLE row") { assert_check(wrong_check, part_name, "seeded wrong CHECK") }
    truncated = String.new(full_binary.to_slice[0, full_binary.bytesize - 1])
    expect_mismatch("truncated Decimal RowBinary") do
      assert_rowbinary(truncated, (0...KEYS.size).to_a, "seeded truncated RowBinary")
    end
  end

  private def assert_schema_guards(schema : CrystalClick::ObjectDocumentSchema) : Nil
    TYPE_SPECS.each do |spec|
      width = spec[3] <= 9 ? 32 : (spec[3] <= 18 ? 64 : (spec[3] <= 38 ? 128 : 256))
      assert(spec[2] == width, "#{spec[0]} fixture does not sit in its precision-derived Decimal width")
      assert(schema.typed_paths[spec[0]] == decimal_type(spec), "#{spec[0]} canonical descriptor differs")
    end
    assert(schema.typed_paths.size == 10, "W137 must retain nine Decimal typed paths plus String")
    same_display_32 = CrystalClick::BinaryDataType.decimal(32, 9, 2)
    same_display_64 = CrystalClick::BinaryDataType.decimal(64, 9, 2)
    assert(same_display_32.name == same_display_64.name && same_display_32 != same_display_64,
      "global Decimal descriptors must retain wire width despite identical displayed P/S")

    # These descriptors are globally valid binary transports. Object schema
    # admission alone rejects a width/P mismatch or S>P; no malformed part is
    # generated or offered to stock ClickHouse.
    global_width_mismatch = CrystalClick::BinaryDataType.decimal(64, 9, 2)
    global_scale_mismatch = CrystalClick::BinaryDataType.decimal(32, 8, 9)
    expect_argument_error("globally valid Decimal64 descriptor with P=9 canonical Decimal32 width") do
      CrystalClick::ObjectDocumentSchema.new({"bad" => global_width_mismatch})
    end
    expect_argument_error("globally valid Decimal(8, 9) descriptor with S>P") do
      CrystalClick::ObjectDocumentSchema.new({"bad" => global_scale_mismatch})
    end
    begin
      CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(bad Decimal(8, 9))")
      fail("parser admitted Decimal with scale greater than precision")
    rescue error : CrystalClick::UnsupportedFormatError
      puts "PASS W137 schema parser rejects Decimal(8, 9) before part construction"
    end
    puts "PASS W137 descriptor guard scope: global transport descriptors remain constructible; only Object schema admission rejects invalid declaration descriptors"
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
    run(binary, store, "INSERT INTO default.#{table} FORMAT JSONEachRow", IO::Memory.new(NATIVE_JSON_ROWS.join("\n") + "\n"))
    part = stock_part(binary, store, table, label)
    check, full_binary = assert_stock_sql(binary, store, table, part[:name], label)
    assert_comparator_sensitivity(check, full_binary, part[:name]) if check_negative_controls
    schema = CrystalClick::ObjectDocumentSchema.parse_declaration(DECLARATION)
    assert_part_profile(part, schema, profile, mode, label)
    assert_object_reader(part, schema, label)
    catalog = catalog_root(root, label, case_number, part)
    catalog_values(catalog[:root], label)
    assert_table_delivery(catalog[:root], catalog[:part_path], part, label)
    puts "PASS W137 native decimal-string JSON -> stock CHECK/full/PK exact Decimal SQL and RowBinary -> Object reader/catalog/table: #{label}"
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
    puts "PASS W137 library-owned cell (String #{profile_name}, Dynamic #{mode_name}) -> stock ATTACH/CHECK/full/PK exact Decimal SQL/RowBinary -> reader/catalog/table: #{label}"
  end

  def check : Nil
    binary = ENV["CLICKHOUSE_BIN"]? || raise "CLICKHOUSE_BIN is required"
    root = ENV["W137_TMP_ROOT"]? || raise "W137_TMP_ROOT is required"
    assert(!File.symlink?(root) && Dir.exists?(root), "W137 temporary root must be an existing non-symlink directory")
    root = File.realpath(root)
    assert(root.starts_with?("/private/tmp/crystal-click-object-decimal-w137."), "unsafe W137 temporary root")
    assert(KEYS.size == 7 && TEXT.size == 7 && DYNAMIC.size == 7 && NATIVE_JSON_ROWS.size == 7,
      "W137 independent seven-row fixture inventory changed")
    TYPE_SPECS.each do |spec|
      assert(DECIMAL_TEXT[spec[0]].size == 7 && DECIMAL_HEX[spec[0]].size == 7,
        "#{spec[0]} Decimal fixture vector count differs")
      7.times do |row|
        assert(raw_bytes(spec, row).size == spec[2] // 8, "#{spec[0]} row #{row}: raw width differs")
      end
    end
    assert(ROWS_PER_MARK == [2_u64, 2_u64, 2_u64, 1_u64], "W137 physical mark fixture changed")
    schema = CrystalClick::ObjectDocumentSchema.parse_declaration(DECLARATION)
    assert(schema.declaration == DECLARATION && schema.typed_paths == typed_schema,
      "W137 canonical typed Decimal declaration differs from authored schema")
    assert_schema_guards(schema)

    bootstrap_store = File.join(root, "bootstrap")
    FileUtils.mkdir_p(bootstrap_store)
    verify_runtime(binary, bootstrap_store)

    puts "W137 fixture scope: P/S=1/0,8/2,9/9,10/4,18/18,19/6,38/38,39/8,76/76; canonical widths=32/64/128/256; seven rows per type include zero, signed, least-scaled-unit, asymmetric, and maximum-precision coefficients"
    puts "W137 bounded storage profile: 4 native + 4 library cells; String single_stream/with_size_stream x Dynamic BASIC/COMPACT; Object V3 one MAP bucket; LZ4 hashedWide; grid 2,2,2,1; plain .mrk2 and primary.idx; limits default BinaryCodecLimits and CompressedStreamLimits"
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
    puts "PASS W137 scope: normalized bare declared Decimal(P, S) Object interoperability at selected threshold/submaximal witnesses; raw carrier and Decimal arithmetic/conversion/rounding are separate claims; other combinations and malformed physical parts are not inferred"
  end
end

W137Oracle.new.check
