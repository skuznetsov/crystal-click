# W135 declared UUID/IPv4/IPv6 Object interoperability oracle.
#
# Text, canonical labels, numeric IPv4 values, and exact identifier bytes are
# independently authored fixtures. UUID halves, IPv4 integer order, and IPv6
# network bytes are compared against stock SQL and RowBinary.
require "file_utils"
require "json"
require "../src/crystal_click"
require "./w122_bulk_vectors"

class W135Oracle
  class Mismatch < Exception
  end

  VERSION           = "26.10.1.1201"
  BUILD_HASH        = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
  EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
  FRAME_BYTES       = 16
  DECLARATION       = "JSON(max_dynamic_types=1, max_dynamic_paths=1, ip4 IPv4, ip6 IPv6, t String, uuid UUID)"
  SETTINGS_BASE     = "index_granularity=2, index_granularity_bytes=10485760, enable_mixed_granularity_parts=1, min_rows_for_wide_part=0, min_bytes_for_wide_part=0, compress_marks=0, compress_primary_key=0, min_compress_block_size=0, max_compress_block_size=4096, ratio_of_defaults_for_sparse_serialization=1, default_compression_codec='LZ4', object_serialization_version='v3', object_shared_data_serialization_version_for_zero_level_parts='map', propagate_types_serialization_versions_to_nested_types=true"
  KEYS              = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
  IPV4_UINT32       = [0_u32, 16_909_060_u32, 3_221_225_985_u32, 4_294_967_295_u32, 2_130_706_433_u32, 3_405_803_793_u32, 67_305_985_u32]
  IPV4_BYTES        = [
    [0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8], [0x04_u8, 0x03_u8, 0x02_u8, 0x01_u8],
    [0x01_u8, 0x02_u8, 0x00_u8, 0xc0_u8], [0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8],
    [0x01_u8, 0x00_u8, 0x00_u8, 0x7f_u8], [0x11_u8, 0x71_u8, 0x00_u8, 0xcb_u8],
    [0x01_u8, 0x02_u8, 0x03_u8, 0x04_u8],
  ]
  IPV4_TEXT  = ["0.0.0.0", "1.2.3.4", "192.0.2.1", "255.255.255.255", "127.0.0.1", "203.0.113.17", "4.3.2.1"]
  IPV6_BYTES = [
    [0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
     0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8],
    [0x20_u8, 0x01_u8, 0x0d_u8, 0xb8_u8, 0x12_u8, 0x34_u8, 0x56_u8, 0x78_u8,
     0x90_u8, 0xab_u8, 0xcd_u8, 0xef_u8, 0x11_u8, 0x22_u8, 0x33_u8, 0x44_u8],
    [0x01_u8, 0x23_u8, 0x45_u8, 0x67_u8, 0x89_u8, 0xab_u8, 0xcd_u8, 0xef_u8,
     0xfe_u8, 0xdc_u8, 0xba_u8, 0x98_u8, 0x76_u8, 0x54_u8, 0x32_u8, 0x10_u8],
    [0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8,
     0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8],
    [0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
     0x00_u8, 0x00_u8, 0xff_u8, 0xff_u8, 0xc0_u8, 0x00_u8, 0x02_u8, 0x01_u8],
    [0x20_u8, 0x01_u8, 0x0d_u8, 0xb8_u8, 0x85_u8, 0xa3_u8, 0x00_u8, 0x00_u8,
     0x00_u8, 0x00_u8, 0x8a_u8, 0x2e_u8, 0x03_u8, 0x70_u8, 0x73_u8, 0x34_u8],
    [0xfe_u8, 0xdc_u8, 0xba_u8, 0x98_u8, 0x76_u8, 0x54_u8, 0x32_u8, 0x10_u8,
     0x01_u8, 0x23_u8, 0x45_u8, 0x67_u8, 0x89_u8, 0xab_u8, 0xcd_u8, 0xef_u8],
  ]
  IPV6_TEXT = [
    "::", "2001:db8:1234:5678:90ab:cdef:1122:3344",
    "123:4567:89ab:cdef:fedc:ba98:7654:3210",
    "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
    "::ffff:192.0.2.1", "2001:db8:85a3::8a2e:370:7334",
    "fedc:ba98:7654:3210:123:4567:89ab:cdef",
  ]
  UUID_BYTES = [
    [0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
     0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8],
    [0x77_u8, 0x66_u8, 0x55_u8, 0x44_u8, 0x33_u8, 0x22_u8, 0x11_u8, 0x00_u8,
     0xff_u8, 0xee_u8, 0xdd_u8, 0xcc_u8, 0xbb_u8, 0xaa_u8, 0x99_u8, 0x88_u8],
    [0xef_u8, 0xcd_u8, 0xab_u8, 0x89_u8, 0x67_u8, 0x45_u8, 0x23_u8, 0x01_u8,
     0x10_u8, 0x32_u8, 0x54_u8, 0x76_u8, 0x98_u8, 0xba_u8, 0xdc_u8, 0xfe_u8],
    [0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8,
     0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8],
    [0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x80_u8,
     0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8],
    [0xbe_u8, 0xba_u8, 0xfe_u8, 0xca_u8, 0xef_u8, 0xbe_u8, 0xad_u8, 0xde_u8,
     0xef_u8, 0xcd_u8, 0xab_u8, 0x89_u8, 0x67_u8, 0x45_u8, 0x23_u8, 0x01_u8],
    [0x03_u8, 0xfd_u8, 0x02_u8, 0xfe_u8, 0x01_u8, 0xff_u8, 0x00_u8, 0x7f_u8,
     0xf9_u8, 0x07_u8, 0xfa_u8, 0x06_u8, 0xfb_u8, 0x05_u8, 0xfc_u8, 0x04_u8],
  ]
  UUID_TEXT = [
    "00000000-0000-0000-0000-000000000000",
    "00112233-4455-6677-8899-aabbccddeeff",
    "01234567-89ab-cdef-fedc-ba9876543210",
    "ffffffff-ffff-ffff-ffff-ffffffffffff",
    "80000000-0000-0000-0000-000000000000",
    "deadbeef-cafe-babe-0123-456789abcdef",
    "7f00ff01-fe02-fd03-04fc-05fb06fa07f9",
  ]
  TEXT          = ["zero", "a\0b", "λ雪", "é", "終", "", "tail"]
  DYNAMIC       = [11_i64, 22_i64, 33_i64, 44_i64, 55_i64, 66_i64, 77_i64]
  ROWS_PER_MARK = [2_u64, 2_u64, 2_u64, 1_u64]
  TYPES         = [
    {"ip4", "IPv4", :ipv4, 4},
    {"ip6", "IPv6", :ipv6, 16},
    {"t", "String", :string, 0},
    {"uuid", "UUID", :uuid, 16},
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
    %({"pk":1,"payload":{"ip4":"0.0.0.0","ip6":"::","t":"zero","uuid":"00000000-0000-0000-0000-000000000000","d":11,"spill":"alpha"}}),
    %({"pk":2,"payload":{"ip4":"1.2.3.4","ip6":"2001:db8:1234:5678:90ab:cdef:1122:3344","t":"a\\u0000b","uuid":"00112233-4455-6677-8899-aabbccddeeff","d":22}}),
    %({"pk":3,"payload":{"ip4":"192.0.2.1","ip6":"0123:4567:89ab:cdef:fedc:ba98:7654:3210","t":"λ雪","uuid":"01234567-89ab-cdef-fedc-ba9876543210","d":33}}),
    %({"pk":4,"payload":{"ip4":"255.255.255.255","ip6":"ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff","t":"é","uuid":"ffffffff-ffff-ffff-ffff-ffffffffffff","d":44}}),
    %({"pk":5,"payload":{"ip4":"127.0.0.1","ip6":"::ffff:192.0.2.1","t":"終","uuid":"80000000-0000-0000-0000-000000000000","d":55}}),
    %({"pk":6,"payload":{"ip4":"203.0.113.17","ip6":"2001:db8:85a3::8a2e:370:7334","t":"","uuid":"deadbeef-cafe-babe-0123-456789abcdef","d":66}}),
    %({"pk":7,"payload":{"ip4":"4.3.2.1","ip6":"fedc:ba98:7654:3210:123:4567:89ab:cdef","t":"tail","uuid":"7f00ff01-fe02-fd03-04fc-05fb06fa07f9","d":77,"spill":"omega"}}),
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
      puts "PASS W135 seeded comparator failure: #{label}"
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
    "w135_#{label.gsub('-', "_")}"
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
           when :ipv4
             IPV4_BYTES
           when :ipv6
             IPV6_BYTES
           when :uuid
             UUID_BYTES
           else
             return Bytes.new(TEXT[index].bytesize) { |offset| TEXT[index].to_slice[offset] }
           end
    Bytes.new(spec[3]) { |offset| rows[index][offset] }
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

  private def expected_rowbinary(
    indices : Array(Int32), corrupt_field : String? = nil, corrupt_row : Int32 = -1, corruption : Symbol = :byte,
  ) : String
    String.build do |io|
      indices.each do |index|
        write_u64_le(io, KEYS[index])
        TYPES.each do |spec|
          if spec[2] == :string
            write_string_binary(io, TEXT[index])
          else
            bytes = bytes_for(spec, index)
            if spec[0] == corrupt_field && index == corrupt_row
              case corruption
              when :byte
                bytes[0] ^= 1_u8
              when :reverse
                8.times do |offset|
                  other = 15 - offset
                  first = bytes[offset]
                  bytes[offset] = bytes[other]
                  bytes[other] = first
                end
              when :uuid_halves
                8.times do |offset|
                  first = bytes[offset]
                  bytes[offset] = bytes[offset + 8]
                  bytes[offset + 8] = first
                end
              else
                fail("unknown RowBinary mutation #{corruption.inspect}")
              end
            end
            io.write(bytes)
          end
        end
      end
    end
  end

  private def assert_rowbinary(
    actual : String, indices : Array(Int32), label : String,
    corrupt_field : String? = nil, corrupt_row : Int32 = -1, corruption : Symbol = :byte,
  ) : Nil
    expected = expected_rowbinary(indices, corrupt_field, corrupt_row, corruption)
    assert(actual.to_slice == expected.to_slice,
      "#{label}: exact identifier RowBinary differs; expected #{expected.to_slice.hexstring}, got #{actual.to_slice.hexstring}")
  end

  private def assert_check(actual : String, part_name : String, label : String) : Nil
    expected = "#{part_name}\t1\t\n"
    assert(actual == expected, "#{label}: CHECK TABLE row differs: #{actual.inspect}")
  end

  private def expected_sql_line(index : Int32) : String
    fields = [
      KEYS[index].to_s,
      "IPv4",
      bytes_for(TYPES[0], index).hexstring.upcase,
      IPV4_UINT32[index].to_s,
      IPV4_TEXT[index],
      "IPv6",
      bytes_for(TYPES[1], index).hexstring.upcase,
      IPV6_TEXT[index],
      "String",
      TEXT[index].to_slice.hexstring.upcase,
      "UUID",
      bytes_for(TYPES[3], index).hexstring.upcase,
      UUID_TEXT[index],
      DYNAMIC[index].to_s,
      "Int64",
    ]
    fields.join('\t')
  end

  private def assert_sql_rows(actual : String, indices : Array(Int32), label : String) : Nil
    lines = actual.lines.map(&.chomp)
    expected = indices.map { |index| expected_sql_line(index) }
    assert(lines == expected, "#{label}: exact nominal/canonical identifier SQL rows differ; expected #{expected.inspect}, got #{lines.inspect}")
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
      "toTypeName(payload.ip4)",
      "hex(reinterpretAsFixedString(payload.ip4))",
      "toUInt32(payload.ip4)",
      "toString(payload.ip4)",
      "toTypeName(payload.ip6)",
      "hex(reinterpretAsFixedString(payload.ip6))",
      "toString(payload.ip6)",
      "toTypeName(payload.t)",
      "hex(payload.t)",
      "toTypeName(payload.uuid)",
      "hex(reinterpretAsFixedString(payload.uuid))",
      "toString(payload.uuid)",
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
    database_uuid = "13500000-0000-4000-8000-000000000001"
    table_uuid = "13510000-0000-4000-8000-00000000000#{table_number}"
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
    ipv6_snapshot = values[2].value_for("ip6").bytes
    ipv6_snapshot[0] ^= 0xff_u8
    assert(values[2].value_for("ip6").bytes == bytes_for(TYPES[1], 2),
      "#{label}: mutating a detached IPv6 byte snapshot changed the returned document")
    uuid_snapshot = values[2].value_for("uuid").bytes
    uuid_snapshot[0] ^= 0xff_u8
    assert(values[2].value_for("uuid").bytes == bytes_for(TYPES[3], 2),
      "#{label}: mutating a detached UUID byte snapshot changed the returned document")
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
    wrong_byte[0] = document(0, "ip4")
    expect_mismatch("wrong IPv4 byte") do
      assert_documents(expected, wrong_byte, "seeded wrong IPv4 bytes")
    end

    {
      {"UUID to UInt128", "uuid", "UInt128"},
      {"UUID to IPv6", "uuid", "IPv6"},
      {"IPv6 to UUID", "ip6", "UUID"},
      {"IPv6 to UInt128", "ip6", "UInt128"},
      {"IPv4 to UInt32", "ip4", "UInt32"},
    }.each do |control|
      wrong_fields = {} of String => CrystalClick::BinaryValue
      expected[0].paths.each do |path|
        value = expected[0].value_for(path)
        wrong_fields[path] = if path == control[1]
                               CrystalClick::BinaryValue.fixed(
                                 CrystalClick::BinaryDataType.primitive(control[2]), value.bytes
                               )
                             else
                               value
                             end
      end
      wrong_documents = expected.dup
      wrong_documents[0] = CrystalClick::ObjectDocument.new(wrong_fields)
      expect_mismatch("same bytes with nominal #{control[0]} mismatch") do
        assert_documents(expected, wrong_documents, "seeded wrong nominal #{control[0]}")
      end
    end

    expect_mismatch("Sparse serializer kind") do
      assert_default_serializers(JSON.parse(%({"columns":[{"name":"payload.uuid","kind":"Sparse"}]})), "seeded Sparse serializer")
    end
    expect_mismatch("wrong physical mark grid") do
      assert_grid([2_u64, 1_u64, 2_u64, 2_u64], ROWS_PER_MARK, "seeded wrong physical grid")
    end
    wrong_check = check.gsub("\t1\t", "\t0\t")
    assert(wrong_check != check, "CHECK comparator control did not mutate its positive row")
    expect_mismatch("wrong CHECK TABLE row") { assert_check(wrong_check, part_name, "seeded wrong CHECK") }
    all_indices = (0...KEYS.size).to_a
    expect_mismatch("IPv4 RowBinary byte mismatch") do
      assert_rowbinary(full_binary, all_indices, "seeded wrong IPv4 RowBinary", "ip4", 0, :byte)
    end
    expect_mismatch("UUID RowBinary half-order mismatch") do
      assert_rowbinary(full_binary, all_indices, "seeded swapped UUID RowBinary halves", "uuid", 2, :uuid_halves)
    end
    expect_mismatch("IPv6 RowBinary byte-order mismatch") do
      assert_rowbinary(full_binary, all_indices, "seeded reversed IPv6 RowBinary", "ip6", 2, :reverse)
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
    puts "PASS W135 native identifier JSON -> stock CHECK/full/PK nominal/canonical SQL and exact RowBinary -> Object reader/catalog/table: #{label}"
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
    puts "PASS W135 library-owned matrix cell (String #{profile_name}, Dynamic #{mode_name}) -> stock ATTACH/CHECK/full/PK nominal/canonical SQL/RowBinary -> reader/catalog/table: #{label}"
  end

  def check : Nil
    binary = ENV["CLICKHOUSE_BIN"]? || raise "CLICKHOUSE_BIN is required"
    root = ENV["W135_TMP_ROOT"]? || raise "W135_TMP_ROOT is required"
    assert(!File.symlink?(root) && Dir.exists?(root), "W135 temporary root must be an existing non-symlink directory")
    root = File.realpath(root)
    assert(root.starts_with?("/private/tmp/crystal-click-object-identifiers-w135."), "unsafe W135 temporary root")
    assert(KEYS.size == 7 && IPV4_UINT32.size == 7 && IPV4_BYTES.size == 7 && IPV4_TEXT.size == 7 &&
           IPV6_BYTES.size == 7 && IPV6_TEXT.size == 7 && UUID_BYTES.size == 7 && UUID_TEXT.size == 7 &&
           TEXT.size == 7 && DYNAMIC.size == 7 && NATIVE_JSON_ROWS.size == 7,
      "W135 independent seven-row fixture inventory changed")
    assert(IPV4_UINT32 == [0_u32, 16_909_060_u32, 3_221_225_985_u32, 4_294_967_295_u32, 2_130_706_433_u32, 3_405_803_793_u32, 67_305_985_u32],
      "W135 independent IPv4 numeric fixtures changed")
    assert(ROWS_PER_MARK == [2_u64, 2_u64, 2_u64, 1_u64], "W135 physical mark fixture changed")
    schema = CrystalClick::ObjectDocumentSchema.parse_declaration(DECLARATION)
    assert(schema.declaration == DECLARATION && schema.typed_paths == typed_schema,
      "W135 nominal typed declaration differs from authored schema")
    assert(CrystalClick::BinaryDataType.primitive("UUID") != CrystalClick::BinaryDataType.primitive("UInt128") &&
           CrystalClick::BinaryDataType.primitive("UUID") != CrystalClick::BinaryDataType.primitive("IPv6") &&
           CrystalClick::BinaryDataType.primitive("IPv4") != CrystalClick::BinaryDataType.primitive("UInt32"),
      "W135 identifier descriptors are not nominally distinct from same-width aliases")

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
    puts "PASS W135 scope: declared UUID/IPv4/IPv6 paired Object support; seven independent nominal/text/byte fixtures; four native and four library-owned String 0/1 × BASIC/COMPACT cells; exact stock type/text/SQL/RowBinary/CHECK plus seeded byte/nominal/order/grid/serializer controls; no wrappers, containers, FixedString, Decimal, Enum, new layouts, projections, MV widening, Compact parts or performance claim"
  end
end

W135Oracle.new.check
