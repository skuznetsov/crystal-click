# W133 declared Date/Date32 Object interoperability oracle.
#
# Calendar strings, numeric day codes, and expected little-endian bytes are
# separately authored fixtures. The Date32 Int32 extrema lane checks raw
# transport only and never asks ClickHouse to format them as calendar dates.
require "file_utils"
require "json"
require "../src/crystal_click"
require "./w122_bulk_vectors"

class W133Oracle
  class Mismatch < Exception
  end

  VERSION             = "26.10.1.1201"
  BUILD_HASH          = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
  EXECUTABLE_SHA256   = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
  FRAME_BYTES         = 16
  DECLARATION         = "JSON(max_dynamic_types=1, max_dynamic_paths=1, date Date, date32 Date32, t String)"
  CARRIER_DECLARATION = "JSON(max_dynamic_types=1, max_dynamic_paths=1, date32 Date32)"
  SETTINGS_BASE       = "index_granularity=2, index_granularity_bytes=10485760, enable_mixed_granularity_parts=1, min_rows_for_wide_part=0, min_bytes_for_wide_part=0, compress_marks=0, compress_primary_key=0, min_compress_block_size=0, max_compress_block_size=4096, ratio_of_defaults_for_sparse_serialization=1, default_compression_codec='LZ4', object_serialization_version='v3', object_shared_data_serialization_version_for_zero_level_parts='map', propagate_types_serialization_versions_to_nested_types=true"
  KEYS                = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
  DATE_DAY_CODES      = [0_u16, 1_u16, 513_u16, 65_535_u16, 256_u16, 10_000_u16, 365_u16]
  DATE_BYTES          = [
    [0x00_u8, 0x00_u8], [0x01_u8, 0x00_u8], [0x01_u8, 0x02_u8],
    [0xff_u8, 0xff_u8], [0x00_u8, 0x01_u8], [0x10_u8, 0x27_u8],
    [0x6d_u8, 0x01_u8],
  ]
  DATE_CALENDAR    = ["1970-01-01", "1970-01-02", "1971-05-29", "2149-06-06", "1970-09-14", "1997-05-19", "1971-01-01"]
  DATE32_DAY_CODES = [-25_567_i32, -513_i32, -1_i32, 0_i32, 1_i32, 120_529_i32, 513_i32]
  DATE32_BYTES     = [
    [0x21_u8, 0x9c_u8, 0xff_u8, 0xff_u8], [0xff_u8, 0xfd_u8, 0xff_u8, 0xff_u8],
    [0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8], [0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8],
    [0x01_u8, 0x00_u8, 0x00_u8, 0x00_u8], [0xd1_u8, 0xd6_u8, 0x01_u8, 0x00_u8],
    [0x01_u8, 0x02_u8, 0x00_u8, 0x00_u8],
  ]
  DATE32_CALENDAR = ["1900-01-01", "1968-08-06", "1969-12-31", "1970-01-01", "1970-01-02", "2299-12-31", "1971-05-29"]
  TEXT            = ["zero", "a\0b", "λ雪", "é", "終", "", "tail"]
  DYNAMIC         = [11_i64, 22_i64, 33_i64, 44_i64, 55_i64, 66_i64, 77_i64]
  ROWS_PER_MARK   = [2_u64, 2_u64, 2_u64, 1_u64]
  CARRIER_KEYS    = [1_u64, 2_u64]
  CARRIER_BYTES   = [
    [0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8],
    [0xff_u8, 0xff_u8, 0xff_u8, 0x7f_u8],
  ]
  # Independently authored complete RowBinary for two rows of the declared `date32 Date32` path.
  CARRIER_ROW_BINARY_HEX = "010000000000000001066461746533320000008002000000000000000106646174653332ffffff7f"
  TYPES                  = [
    {"date", "Date", :date, 2},
    {"date32", "Date32", :date32, 4},
    {"t", "String", :string, 0},
  ]
  PROFILES = [
    {"single_stream", CrystalClick::BinaryBulkProfile.single_stream},
    {"with_size_stream", CrystalClick::BinaryBulkProfile.with_size_stream},
  ]
  MODES = [
    {"basic", CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE},
    {"compact", CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE},
  ]
  NATIVE_JSON_ROWS = [
    %({"pk":1,"payload":{"date":"1970-01-01","date32":"1900-01-01","t":"zero","d":11,"spill":"alpha"}}),
    %({"pk":2,"payload":{"date":"1970-01-02","date32":"1968-08-06","t":"a\\u0000b","d":22}}),
    %({"pk":3,"payload":{"date":"1971-05-29","date32":"1969-12-31","t":"λ雪","d":33}}),
    %({"pk":4,"payload":{"date":"2149-06-06","date32":"1970-01-01","t":"é","d":44}}),
    %({"pk":5,"payload":{"date":"1970-09-14","date32":"1970-01-02","t":"終","d":55}}),
    %({"pk":6,"payload":{"date":"1997-05-19","date32":"2299-12-31","t":"","d":66}}),
    %({"pk":7,"payload":{"date":"1971-01-01","date32":"1971-05-29","t":"tail","d":77,"spill":"omega"}}),
  ]

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
      puts "PASS W133 seeded comparator failure: #{label}"
      return
    end
    fail("#{label}: seeded mismatch passed the oracle comparator")
  end

  private def run(binary : String, store : String, query : String, input : IO? = nil) : String
    output = IO::Memory.new
    error = IO::Memory.new
    arguments = ["local", "--path", store, "--query", query]
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
    version = run_status(binary, ["local", "--version"]).strip
    assert(version == "ClickHouse local version #{VERSION} (official build).",
      "unexpected ClickHouse version: #{version.inspect}")
    digest = run_status("shasum", ["-a", "256", binary]).split(' ').first? || ""
    assert(digest == EXECUTABLE_SHA256, "unexpected ClickHouse executable SHA-256")
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
    "w133_#{label.gsub('-', "_")}"
  end

  private def typed_schema : Hash(String, CrystalClick::BinaryDataType)
    fields = {} of String => CrystalClick::BinaryDataType
    TYPES.each { |spec| fields[spec[0]] = CrystalClick::BinaryDataType.primitive(spec[1]) }
    fields
  end

  private def create_table(binary : String, store : String, table : String, profile_name : String, mode : UInt64, label : String) : Nil
    compact = mode == CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE ? 1 : 0
    settings = "#{SETTINGS_BASE}, use_compact_variant_discriminators_serialization=#{compact}, string_serialization_version='#{profile_name}'"
    run(binary, store,
      "CREATE TABLE default.#{table} (`pk` UInt64, `payload` #{DECLARATION}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings}")
    actual = run(binary, store,
      "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
    expected = "pk UInt64\npayload #{DECLARATION}\n"
    assert(actual == expected, "#{label}: live columns differ from the independently authored DDL: #{actual.inspect}")
    schema = CrystalClick::ObjectDocumentSchema.parse_declaration(DECLARATION)
    assert(schema.declaration == DECLARATION, "#{label}: canonical parser declaration differs from authored DDL")
    assert(schema.typed_paths == typed_schema, "#{label}: typed path roster differs from authored DDL")
  end

  private def create_carrier_table(binary : String, store : String, table : String, label : String) : Nil
    settings = "#{SETTINGS_BASE}, use_compact_variant_discriminators_serialization=0, string_serialization_version='single_stream'"
    run(binary, store,
      "CREATE TABLE default.#{table} (`pk` UInt64, `payload` #{CARRIER_DECLARATION}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings}")
    actual = run(binary, store,
      "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
    expected = "pk UInt64\npayload #{CARRIER_DECLARATION}\n"
    assert(actual == expected, "#{label}: live carrier columns differ from authored DDL: #{actual.inspect}")
  end

  private def table_data_path(binary : String, store : String, table : String, label : String) : String
    path = run(binary, store,
      "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
    store_child(path, store, "#{label} data path")
  end

  private def stock_part(binary : String, store : String, table : String, label : String, row_count : Int32 = KEYS.size) : Part
    rows = run(binary, store,
      "SELECT name, path, part_type, toString(rows) FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines
    assert(rows.size == 1, "#{label}: expected exactly one active part, got #{rows.size}")
    fields = rows.first.split('\t')
    assert(fields.size == 4 && fields[2] == "Wide" && fields[3] == row_count.to_s,
      "#{label}: expected one #{row_count}-row Wide part, got #{rows.first.inspect}")
    path = store_child(fields[1], store, "#{label} part")
    assert_tree(path, "#{label} part")
    assert(File.file?(File.join(path, "checksums.txt")), "#{label}: part lacks checksums.txt")
    {name: fields[0], path: path, rows: row_count.to_u64}
  end

  private def bytes_for(spec : Tuple(String, String, Symbol, Int32), index : Int32) : Bytes
    rows = case spec[2]
           when :date
             DATE_BYTES
           when :date32
             DATE32_BYTES
           else
             return Bytes.new(TEXT[index].bytesize) { |offset| TEXT[index].to_slice[offset] }
           end
    Bytes.new(spec[3]) { |offset| rows[index][offset] }
  end

  private def carrier_bytes(index : Int32) : Bytes
    Bytes.new(4) { |offset| CARRIER_BYTES[index][offset] }
  end

  private def typed_value(spec : Tuple(String, String, Symbol, Int32), index : Int32) : CrystalClick::BinaryValue
    if spec[2] == :string
      CrystalClick::BinaryValue.string(TEXT[index])
    else
      CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive(spec[1]), bytes_for(spec, index))
    end
  end

  private def document(index : Int32, corrupt_path : String? = nil) : CrystalClick::ObjectDocument
    fields = {} of String => CrystalClick::BinaryValue
    TYPES.each do |spec|
      value = typed_value(spec, index)
      if corrupt_path == spec[0] && spec[2] != :string
        bytes = value.bytes
        bytes[0] ^= 1_u8
        value = CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive(spec[1]), bytes)
      end
      fields[spec[0]] = value
    end
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
          "#{label}: value differs at row #{row}, path #{path.inspect}")
      end
    end
  end

  private def assert_granules(
    expected : Array(Array(CrystalClick::ObjectDocument)), actual : Array(Array(CrystalClick::ObjectDocument)), label : String,
  ) : Nil
    assert(expected.size == actual.size, "#{label}: mark count differs")
    expected.each_with_index { |rows, mark| assert_documents(rows, actual[mark], "#{label} mark #{mark}") }
  end

  private def assert_grid(actual : Array(UInt64), expected : Array(UInt64), label : String) : Nil
    assert(actual == expected, "#{label}: actual Object mark grid differs: #{actual.inspect}")
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

  private def write_carrier_row(io : IO, index : Int32) : Nil
    write_u64_le(io, CARRIER_KEYS[index])
    write_varuint(io, 1_u64)
    write_string_binary(io, "date32")
    # Declared typed paths carry their typed payload directly, without a Dynamic discriminator tag.
    io.write(carrier_bytes(index))
  end

  private def write_carrier_file(path : String) : Nil
    File.open(path, "w") { |io| CARRIER_KEYS.each_index { |index| write_carrier_row(io, index.to_i32) } }
    actual_hex = File.read(path).to_slice.hexstring
    assert(actual_hex == CARRIER_ROW_BINARY_HEX,
      "raw Date32 typed-path RowBinary input differs from the independent literal: #{actual_hex}")
  end

  private def expected_rowbinary(indices : Array(Int32), corrupt_date : Bool = false) : String
    String.build do |io|
      indices.each do |index|
        write_u64_le(io, KEYS[index])
        TYPES.each do |spec|
          if spec[2] == :string
            write_string_binary(io, TEXT[index])
          else
            bytes = bytes_for(spec, index)
            bytes[0] ^= 1_u8 if corrupt_date && spec[0] == "date" && index == indices.first
            io.write(bytes)
          end
        end
      end
    end
  end

  private def assert_rowbinary(actual : String, indices : Array(Int32), label : String, corrupt_date : Bool = false) : Nil
    expected = expected_rowbinary(indices, corrupt_date)
    assert(actual.to_slice == expected.to_slice,
      "#{label}: exact Date/Date32 RowBinary differs; expected #{expected.to_slice.hexstring}, got #{actual.to_slice.hexstring}")
  end

  private def expected_carrier_rowbinary(indices : Array(Int32)) : String
    String.build do |io|
      indices.each do |index|
        write_u64_le(io, CARRIER_KEYS[index])
        io.write(carrier_bytes(index))
      end
    end
  end

  private def assert_carrier_rowbinary(actual : String, indices : Array(Int32), label : String) : Nil
    expected = expected_carrier_rowbinary(indices)
    assert(actual.to_slice == expected.to_slice,
      "#{label}: raw signed Date32 RowBinary differs; expected #{expected.to_slice.hexstring}, got #{actual.to_slice.hexstring}")
  end

  private def assert_check(actual : String, part_name : String, label : String) : Nil
    expected = "#{part_name}\t1\t\n"
    assert(actual == expected, "#{label}: CHECK TABLE row differs: #{actual.inspect}")
  end

  private def expected_sql_line(index : Int32) : String
    fields = [
      KEYS[index].to_s,
      bytes_for(TYPES[0], index).hexstring.upcase,
      bytes_for(TYPES[1], index).hexstring.upcase,
      DATE_DAY_CODES[index].to_s,
      DATE32_DAY_CODES[index].to_s,
      DATE_CALENDAR[index],
      DATE32_CALENDAR[index],
      TEXT[index].to_slice.hexstring.upcase,
      DYNAMIC[index].to_s,
      "Int64",
    ]
    fields.join('\t')
  end

  private def assert_sql_rows(actual : String, indices : Array(Int32), label : String) : Nil
    lines = actual.lines.map(&.chomp)
    expected = indices.map { |index| expected_sql_line(index) }
    assert(lines == expected, "#{label}: exact typed/calendar SQL rows differ; expected #{expected.inspect}, got #{lines.inspect}")
  end

  private def assert_type_labels(binary : String, store : String, table : String, label : String) : Nil
    expressions = TYPES.map { |spec| "toTypeName(payload.#{spec[0]})" }
    expressions << "dynamicType(payload.d)"
    actual = run(binary, store,
      "SELECT #{expressions.join(", ")} FROM default.#{table} ORDER BY pk LIMIT 1 FORMAT TSVRaw").strip
    expected = (TYPES.map(&.[1]) + ["Int64"]).join('\t')
    assert(actual == expected, "#{label}: actual nominal type labels differ: #{actual.inspect}")
  end

  private def assert_stock_sql(binary : String, store : String, table : String, part_name : String, label : String) : {String, String}
    check = run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated")
    assert_check(check, part_name, "#{label} CHECK TABLE")
    projection = [
      "pk",
      "hex(reinterpretAsFixedString(payload.date))",
      "hex(reinterpretAsFixedString(payload.date32))",
      "toUInt16(payload.date)",
      "toInt32(payload.date32)",
      "toString(payload.date)",
      "toString(payload.date32)",
      "hex(payload.t)",
      "payload.d",
      "dynamicType(payload.d)",
    ].join(", ")
    full_sql = run(binary, store,
      "SELECT #{projection} FROM default.#{table} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw")
    assert_sql_rows(full_sql, (0...KEYS.size).to_a, "#{label} full SQL")
    selected_sql = run(binary, store,
      "SELECT #{projection} FROM default.#{table} WHERE pk >= 3 AND pk <= 4 ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw")
    assert_sql_rows(selected_sql, [2, 3], "#{label} PK 3..4 SQL")
    assert_type_labels(binary, store, table, label)

    rowbinary_columns = TYPES.map { |spec| "payload.#{spec[0]}" }
    rowbinary_projection = (["pk"] + rowbinary_columns).join(", ")
    full_binary = run(binary, store,
      "SELECT #{rowbinary_projection} FROM default.#{table} ORDER BY pk FORMAT RowBinary")
    assert_rowbinary(full_binary, (0...KEYS.size).to_a, "#{label} full RowBinary")
    selected_binary = run(binary, store,
      "SELECT #{rowbinary_projection} FROM default.#{table} WHERE pk >= 3 AND pk <= 4 ORDER BY pk FORMAT RowBinary")
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
    assert_grid(grid, ROWS_PER_MARK, "#{label} ObjectColumnReader")
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

  private def object_reader(part : Part, schema : CrystalClick::ObjectDocumentSchema, label : String) : Nil
    reader = CrystalClick::ObjectColumnReader.open(part[:path], "payload", schema)
    expected = granules(expected_documents)
    grid = reader.mark_row_counts
    assert_grid(grid, ROWS_PER_MARK, "#{label} ObjectColumnReader")
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
    database_uuid = "13300000-0000-4000-8000-000000000001"
    table_uuid = "13310000-0000-4000-8000-00000000000#{table_number}"
    File.write(File.join(metadata, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
    database_dir = File.join(catalog, "store", database_uuid[0, 3], database_uuid)
    FileUtils.mkdir_p(database_dir)
    File.write(File.join(database_dir, "events.sql"),
      "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` #{DECLARATION}\n)\nENGINE = MergeTree\nORDER BY pk\n")
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
    owned_bytes = values[1].value_for("t").bytes
    owned_bytes[0] = 'X'.ord.to_u8
    assert(values[1].value_for("t").as_string == "a\0b",
      "#{label}: mutating a detached String byte snapshot changed the returned document")
    date_snapshot = values[2].value_for("date").bytes
    date_snapshot[0] ^= 0xff_u8
    assert(values[2].value_for("date").bytes == bytes_for(TYPES[0], 2),
      "#{label}: mutating a detached Date byte snapshot changed the returned document")
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
      [0_i32, 1_i32], [1_u64, 0_u64], [1_u64, 2_u64],
      [[2_u64], [3_u64, 4_u64]], "#{label} physical window")
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

  private def assert_comparator_sensitivity(check : String, full_binary : String, part_name : String) : Nil
    expected = expected_documents
    wrong_byte = expected.dup
    wrong_byte[0] = document(0, "date")
    expect_mismatch("wrong numeric day byte") do
      assert_documents(expected, wrong_byte, "seeded wrong Date day code")
    end
    wrong_nominal_fields = {} of String => CrystalClick::BinaryValue
    expected[0].paths.each do |path|
      value = expected[0].value_for(path)
      if path == "date"
        wrong_nominal_fields[path] = CrystalClick::BinaryValue.fixed(
          CrystalClick::BinaryDataType.primitive("UInt16"), value.bytes
        )
      else
        wrong_nominal_fields[path] = value
      end
    end
    wrong_nominal_documents = expected.dup
    wrong_nominal_documents[0] = CrystalClick::ObjectDocument.new(wrong_nominal_fields)
    expect_mismatch("same bytes with nominal Date to UInt16 mismatch") do
      assert_documents(expected, wrong_nominal_documents, "seeded wrong nominal Date document")
    end
    wrong_date32_fields = {} of String => CrystalClick::BinaryValue
    expected[0].paths.each do |path|
      value = expected[0].value_for(path)
      wrong_date32_fields[path] = if path == "date32"
                                    CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("Int32"), value.bytes)
                                  else
                                    value
                                  end
    end
    wrong_date32_documents = expected.dup
    wrong_date32_documents[0] = CrystalClick::ObjectDocument.new(wrong_date32_fields)
    expect_mismatch("same bytes with nominal Date32 to Int32 mismatch") do
      assert_documents(expected, wrong_date32_documents, "seeded wrong nominal Date32 document")
    end
    expect_mismatch("Sparse serializer kind") do
      assert_default_serializers(JSON.parse(%({"columns":[{"name":"payload.date","kind":"Sparse"}]})), "seeded Sparse serializer")
    end
    expect_mismatch("wrong physical mark grid") do
      assert_grid([2_u64, 1_u64, 2_u64, 2_u64], ROWS_PER_MARK, "seeded wrong physical grid")
    end
    wrong_check = check.gsub("\t1\t", "\t0\t")
    assert(wrong_check != check, "CHECK comparator control did not mutate its positive row")
    expect_mismatch("wrong CHECK TABLE row") { assert_check(wrong_check, part_name, "seeded wrong CHECK") }
    expect_mismatch("Date RowBinary mismatch") do
      assert_rowbinary(full_binary, (0...KEYS.size).to_a, "seeded wrong Date bytes", corrupt_date: true)
    end
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
    input = IO::Memory.new(NATIVE_JSON_ROWS.join("\n") + "\n")
    run(binary, store, "INSERT INTO default.#{table} FORMAT JSONEachRow", input)
    part = stock_part(binary, store, table, label)
    check, full_binary = assert_stock_sql(binary, store, table, part[:name], label)
    assert_comparator_sensitivity(check, full_binary, part[:name]) if check_negative_controls
    schema = CrystalClick::ObjectDocumentSchema.parse_declaration(DECLARATION)
    assert_part_profile(part, schema, profile, mode, label)
    object_reader(part, schema, label)
    catalog = catalog_root(root, label, case_number, part)
    catalog_values(catalog[:root], label)
    assert_table_delivery(catalog[:root], catalog[:part_path], part, label)
    puts "PASS W133 native date-string JSON -> stock CHECK/full/PK calendar SQL and exact RowBinary -> Object reader/catalog/table: #{label}"
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
    object_reader(part, schema, label)
    catalog = catalog_root(root, label, table_number, part)
    catalog_values(catalog[:root], label)
    assert_table_delivery(catalog[:root], catalog[:part_path], part, label)
    puts "PASS W133 library-owned matrix cell (String #{profile_name}, Dynamic #{mode_name}) -> stock ATTACH/CHECK/full/PK calendar SQL/RowBinary -> reader/catalog/table: #{label}"
  end

  private def carrier_schema : CrystalClick::ObjectDocumentSchema
    CrystalClick::ObjectDocumentSchema.parse_declaration(CARRIER_DECLARATION)
  end

  private def carrier_documents : Array(CrystalClick::ObjectDocument)
    Array(CrystalClick::ObjectDocument).new(CARRIER_KEYS.size) do |index|
      value = CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("Date32"), carrier_bytes(index.to_i32))
      CrystalClick::ObjectDocument.new({"date32" => value} of String => CrystalClick::BinaryValue)
    end
  end

  private def carrier_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String), {} of String => CrystalClick::DynamicStructure
    )
    CrystalClick::ObjectDocumentPlan.new(structures, schema.typed_paths)
  end

  private def assert_carrier_table(binary : String, store : String, table : String, label : String) : Part
    part = stock_part(binary, store, table, label, CARRIER_KEYS.size)
    check = run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated")
    assert_check(check, part[:name], "#{label} CHECK TABLE")
    raw_sql = run(binary, store,
      "SELECT toTypeName(payload.date32), hex(reinterpretAsFixedString(payload.date32)) FROM default.#{table} ORDER BY pk FORMAT TSVRaw")
    expected_hex = CARRIER_BYTES.map { |bytes| bytes.map(&.to_s(16).rjust(2, '0')).join.upcase }
    expected_sql = CARRIER_KEYS.map { |key| "Date32\t#{expected_hex[key.to_i - 1]}" }.join("\n") + "\n"
    assert(raw_sql == expected_sql, "#{label}: raw Date32 SQL differs: #{raw_sql.inspect}")
    binary_output = run(binary, store,
      "SELECT pk, payload.date32 FROM default.#{table} ORDER BY pk FORMAT RowBinary")
    assert_carrier_rowbinary(binary_output, [0, 1], "#{label} exact RowBinary")
    schema = carrier_schema
    reader = CrystalClick::ObjectColumnReader.open(part[:path], "payload", schema)
    assert(reader.row_count == CARRIER_KEYS.size.to_u64, "#{label}: Date32 carrier Object row count differs")
    docs = reader.read_marks(0, reader.mark_row_counts.size).flatten
    assert_documents(carrier_documents, docs, "#{label} raw Date32 carrier Object reader")
    part
  end

  private def native_carrier_case(binary : String, root : String) : Nil
    label = "native_raw_date32_extrema"
    store = File.join(root, "stores", label)
    FileUtils.mkdir_p(store)
    table = table_name(label)
    create_carrier_table(binary, store, table, label)
    input_path = File.join(store, "carrier-input.rowbinary")
    write_carrier_file(input_path)
    input_path = store_child(input_path, store, "#{label} RowBinary input")
    run(binary, store, "INSERT INTO default.#{table} (pk, payload) FROM INFILE '#{input_path}' FORMAT RowBinary")
    assert_carrier_table(binary, store, table, label)
    puts "PASS W133 stock-origin raw Date32 Int32 MIN/MAX -> Object reader and exact RowBinary/CHECK; no calendar formatting"
  end

  private def library_carrier_case(binary : String, root : String) : Nil
    label = "library_raw_date32_extrema"
    store = File.join(root, "stores", label)
    FileUtils.mkdir_p(store)
    table = table_name(label)
    create_carrier_table(binary, store, table, label)
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
    schema = carrier_schema
    CrystalClick::WidePartWriter.write_uint64_object_pair(
      part_path, "pk", Slice(UInt64).new(CARRIER_KEYS.size) { |index| CARRIER_KEYS[index] },
      "payload", schema, carrier_plan(schema), [carrier_documents], rows_per_mark: 2,
      mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
      profile: CrystalClick::BinaryBulkProfile.single_stream,
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream, frame_bytes: FRAME_BYTES
    )
    store_child(part_path, store, "#{label} library-written part")
    run(binary, store, "ALTER TABLE default.#{table} ATTACH PART '#{part_name}'")
    part = assert_carrier_table(binary, store, table, label)
    assert(part[:name] == part_name, "#{label}: ATTACH changed the library part identity")
    puts "PASS W133 library-origin raw Date32 Int32 MIN/MAX -> stock ATTACH/CHECK/exact RowBinary; no calendar formatting"
  end

  def check : Nil
    binary = ENV["CLICKHOUSE_BIN"]? || raise "CLICKHOUSE_BIN is required"
    root = ENV["W133_TMP_ROOT"]? || raise "W133_TMP_ROOT is required"
    assert(!File.symlink?(root) && Dir.exists?(root), "W133 temporary root must be an existing non-symlink directory")
    root = File.realpath(root)
    assert(root.starts_with?("/private/tmp/crystal-click-object-dates-w133."), "unsafe W133 temporary root")
    assert(KEYS.size == 7 && DATE_DAY_CODES.size == 7 && DATE_BYTES.size == 7 && DATE_CALENDAR.size == 7 &&
           DATE32_DAY_CODES.size == 7 && DATE32_BYTES.size == 7 && DATE32_CALENDAR.size == 7 &&
           TEXT.size == 7 && DYNAMIC.size == 7 && NATIVE_JSON_ROWS.size == 7,
      "W133 independent seven-row fixture inventory changed")
    assert(DATE_DAY_CODES == [0_u16, 1_u16, 513_u16, 65_535_u16, 256_u16, 10_000_u16, 365_u16],
      "W133 Date raw day-code fixture changed")
    assert(DATE32_DAY_CODES == [-25_567_i32, -513_i32, -1_i32, 0_i32, 1_i32, 120_529_i32, 513_i32],
      "W133 Date32 raw signed day-code fixture changed")
    assert(ROWS_PER_MARK == [2_u64, 2_u64, 2_u64, 1_u64], "W133 physical mark fixture changed")
    schema = CrystalClick::ObjectDocumentSchema.parse_declaration(DECLARATION)
    assert(schema.declaration == DECLARATION && schema.typed_paths == typed_schema,
      "W133 nominal typed declaration differs from authored schema")
    assert(CrystalClick::BinaryDataType.primitive("Date") != CrystalClick::BinaryDataType.primitive("UInt16") &&
           CrystalClick::BinaryDataType.primitive("Date32") != CrystalClick::BinaryDataType.primitive("Int32"),
      "W133 temporal descriptors are not nominally distinct from their numeric carriers")
    carrier = carrier_schema
    assert(carrier.typed_paths == {"date32" => CrystalClick::BinaryDataType.primitive("Date32")},
      "W133 raw-extrema carrier schema differs from Date32")

    bootstrap_store = File.join(root, "bootstrap")
    FileUtils.mkdir_p(bootstrap_store)
    run(binary, bootstrap_store, "SELECT 1")
    verify_runtime(binary, bootstrap_store)

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
    native_carrier_case(binary, root)
    library_carrier_case(binary, root)
    puts "PASS W133 scope: declared Date/Date32 paired Object support; seven independent calendar/day/byte fixtures; four native and four library-owned String 0/1 × BASIC/COMPACT cells; signed Date32 extrema are raw transport only; no DateTime/Time, wrappers, containers, BFloat16, new layouts, projections, MV widening, Compact parts or performance claim"
  end
end

W133Oracle.new.check
