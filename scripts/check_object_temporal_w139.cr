# W139 declared temporal Object interoperability oracle.
#
# The fixture keeps calendar-safe JSON text, exact RowBinary carrier bytes,
# canonical nominal names, and local raw-carrier extrema as separate channels.
# It reuses the W138 Object V3/Wide/MAP corridor and exercises four native
# JSONEachRow cells plus four library-written ATTACH cells.
require "file_utils"
require "json"
require "../src/crystal_click"

class W139TemporalOracle
  class Mismatch < Exception
  end

  struct TemporalField
    getter name : String
    getter type_name : String
    getter type : CrystalClick::BinaryDataType
    getter width : Int32
    getter pair_hex : String
    getter wall_value : String
    getter instant_value : String

    def initialize(
      @name : String, @type_name : String, @type : CrystalClick::BinaryDataType,
      @width : Int32, @pair_hex : String, @wall_value : String, @instant_value : String,
    )
      raise ArgumentError.new("temporal fixture width disagrees with descriptor") unless @type.fixed_width == @width
      raise ArgumentError.new("temporal fixture must contain two literal carriers") unless @pair_hex.bytesize == @width * 4
    end

    def raw_hex(row : Int32) : String
      offset = row.even? ? 0 : @width * 2
      @pair_hex[offset, @width * 2]
    end

    def value(row : Int32) : String
      row.even? ? @wall_value : @instant_value
    end
  end

  VERSION           = "26.10.1.1201"
  BUILD_HASH        = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
  EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
  FRAME_BYTES       = 16

  SETTINGS_BASE = "index_granularity=2, index_granularity_bytes=10485760, enable_mixed_granularity_parts=1, min_rows_for_wide_part=0, min_bytes_for_wide_part=0, compress_marks=0, compress_primary_key=0, min_compress_block_size=0, max_compress_block_size=4096, ratio_of_defaults_for_sparse_serialization=1, default_compression_codec='LZ4', object_serialization_version='v3', object_shared_data_serialization_version_for_zero_level_parts='map', propagate_types_serialization_versions_to_nested_types=true"

  KEYS          = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
  TEXT          = ["zero", "first", "λ雪", "café", "終", "", "tail"]
  DYNAMIC       = [11_i64, 22_i64, 33_i64, 44_i64, 55_i64, 66_i64, 77_i64]
  ROWS_PER_MARK = [2_u64, 2_u64, 2_u64, 1_u64]

  DT64_HEX = [
    "a55d0d5e00000000a55d0d5e00000000",
    "73a885ac0300000073a885ac03000000",
    "809438bd24000000809438bd24000000",
    "03cd35646f01000003cd35646f010000",
    "22021aea590e000022021aea590e0000",
    "59150425838f000059150425838f0000",
    "80d528721f9b050080d528721f9b0500",
    "075798753a0f3800075798753a0f3800",
    "4e66f397489830024e66f39748983002",
    "15ff81efd5f2e51515ff81efd5f2e515",
  ]
  TIME64_HEX = [
    "f0b00000000000008b0e000000000000",
    "61e90600000000007791000000000000",
    "cc1d450000000000aeae050000000000",
    "fb29b30200000000d3d2380000000000",
    "d2a3ff1a00000000443c380200000000",
    "3966fc0d01000000ad5a321600000000",
    "40fedb8b0a000000c68af7dd00000000",
    "87ee977669000000bf6babab08000000",
    "4e51efa11e0400007835b2b456000000",
    "152d595332290000b116f60e63030000",
  ]

  FIELDS = begin
    fields = [] of TemporalField
    fields << TemporalField.new("dt_bare", "DateTime", CrystalClick::BinaryDataType.datetime,
      4, "a55d0d5ea55d0d5e", "2020-01-02 03:04:05", "2020-01-02 03:04:05")
    fields << TemporalField.new("dt_utc", "DateTime('UTC')", CrystalClick::BinaryDataType.datetime("UTC"),
      4, "a55d0d5ea55d0d5e", "2020-01-02 03:04:05", "2020-01-02 03:04:05")
    fields << TemporalField.new("dt_ny", "DateTime('America/New_York')", CrystalClick::BinaryDataType.datetime("America/New_York"),
      4, "f5a30d5ea55d0d5e", "2020-01-02 03:04:05", "2020-01-01 22:04:05")
    fields << TemporalField.new("dt_fixed", "DateTime('Fixed/UTC+05:45:00')", CrystalClick::BinaryDataType.datetime("Fixed/UTC+05:45:00"),
      4, "c90c0d5ea55d0d5e", "2020-01-02 03:04:05", "2020-01-02 08:49:05")

    DT64_HEX.each_with_index do |pair, scale|
      fields << TemporalField.new("dt64_bare_p#{scale}", "DateTime64(#{scale})",
        CrystalClick::BinaryDataType.datetime64(scale), 8, pair,
        "2020-01-02 03:04:05.123456789", "2020-01-02 03:04:05.123456789")
    end
    DT64_HEX.each_with_index do |pair, scale|
      fields << TemporalField.new("dt64_utc_p#{scale}", "DateTime64(#{scale}, 'UTC')",
        CrystalClick::BinaryDataType.datetime64(scale, "UTC"), 8, pair,
        "2020-01-02 03:04:05.123456789", "2020-01-02 03:04:05.123456789")
    end
    fields << TemporalField.new("dt64_alias_p3", "DateTime64(3, 'US/Eastern')",
      CrystalClick::BinaryDataType.datetime64(3, "US/Eastern"), 8,
      "837548656f01000003cd35646f010000",
      "2020-01-02 03:04:05.123456789", "2020-01-01 22:04:05.123456789")
    fields << TemporalField.new("dt64_fixed_p3", "DateTime64(3, 'Fixed/UTC+05:45:00')",
      CrystalClick::BinaryDataType.datetime64(3, "Fixed/UTC+05:45:00"), 8,
      "a3f1f9626f01000003cd35646f010000",
      "2020-01-02 03:04:05.123456789", "2020-01-02 08:49:05.123456789")

    fields << TemporalField.new("time_value", "Time", CrystalClick::BinaryDataType.primitive("Time"),
      4, "f0b000008b0e0000", "12:34:56", "01:02:03")
    TIME64_HEX.each_with_index do |pair, scale|
      fields << TemporalField.new("time64_p#{scale}", "Time64(#{scale})",
        CrystalClick::BinaryDataType.time64(scale), 8, pair,
        "12:34:56.123456789", "01:02:03.987654321")
    end
    fields
  end

  PROFILES = [
    {"single_stream", CrystalClick::BinaryBulkProfile.single_stream},
    {"with_size_stream", CrystalClick::BinaryBulkProfile.with_size_stream},
  ]
  MODES = [
    {"basic", CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE},
    {"compact", CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE},
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
      puts "PASS W139 seeded comparator failure: #{label}"
      return
    end
    fail("#{label}: seeded mismatch passed the oracle comparator")
  end

  private def process_env : Hash(String, String)
    environment = ENV.to_h
    environment["TZ"] = "UTC"
    environment
  end

  private def query_prefix : String
    "SET enable_time_time64_type = 1; SET session_timezone = 'UTC'; "
  end

  private def run(binary : String, store : String, query : String, input : IO? = nil) : String
    output = IO::Memory.new
    error = IO::Memory.new
    arguments = ["local", "--path", store, "--multiquery", "--query", query_prefix + query]
    status = if input
               Process.run(binary, arguments, env: process_env, input: input, output: output, error: error)
             else
               Process.run(binary, arguments, env: process_env, output: output, error: error)
             end
    raise "ClickHouse local query failed: #{error}\n#{query}" unless status.success?
    output.to_s
  end

  private def run_status(binary : String, arguments : Array(String)) : String
    output = IO::Memory.new
    error = IO::Memory.new
    status = Process.run(binary, arguments, env: process_env, output: output, error: error)
    raise "command failed: #{error}" unless status.success?
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
    timezone = run(binary, store,
      "SELECT timezone(), timezoneOf(toDateTime('2020-01-02 03:04:05')) FORMAT TSVRaw").strip
    assert(timezone == "UTC\tUTC", "ClickHouse session/process bare-type timezone is not UTC: #{timezone.inspect}")
    puts "W139 pinned runtime: #{version}; sha256=#{digest}; build=#{BUILD_HASH}; session/process bare-type timezone=UTC"
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

  private def typed_schema : Hash(String, CrystalClick::BinaryDataType)
    result = {} of String => CrystalClick::BinaryDataType
    FIELDS.each { |field| result[field.name] = field.type }
    result["t"] = CrystalClick::BinaryDataType.primitive("String")
    result
  end

  private def expected_declaration : String
    entries = FIELDS.map { |field| "#{field.name} #{field.type_name}" } + ["t String"]
    entries.sort!
    "JSON(max_dynamic_types=1, max_dynamic_paths=1, #{entries.join(", ")})"
  end

  private def schema : CrystalClick::ObjectDocumentSchema
    declaration = expected_declaration
    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(declaration)
    assert(parsed.declaration == declaration, "canonical Object declaration differs from literal field roster")
    assert(parsed.typed_paths == typed_schema, "canonical Object declaration changed a temporal or String path identity")
    assert(parsed.typed_paths.size == 38, "W139 schema must retain 37 temporal paths plus explicit t String")
    parsed
  end

  private def table_name(label : String) : String
    "w139_#{label.gsub('-', "_")}"
  end

  private def create_table(
    binary : String, store : String, table : String, declaration : String,
    profile_name : String, mode : UInt64, label : String,
  ) : Nil
    compact = mode == CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE ? 1 : 0
    settings = "#{SETTINGS_BASE}, use_compact_variant_discriminators_serialization=#{compact}, string_serialization_version='#{profile_name}'"
    run(binary, store,
      "CREATE TABLE default.#{table} (pk UInt64, payload #{declaration}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings}")
    actual = run(binary, store,
      "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
    expected = "pk UInt64\npayload #{declaration}\n"
    assert(actual == expected, "#{label}: live columns differ from the canonical declaration: #{actual.inspect}")
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

  private def bytes_from_hex(hex : String) : Bytes
    source = hex.to_slice
    assert(source.size.even?, "literal hex fixture has an odd number of digits")
    Bytes.new(source.size // 2) do |offset|
      (hex_nibble(source[offset * 2]) << 4) | hex_nibble(source[offset * 2 + 1])
    end
  end

  private def raw_bytes(field : TemporalField, row : Int32) : Bytes
    bytes = bytes_from_hex(field.raw_hex(row))
    assert(bytes.size == field.width, "#{field.name} row #{row}: literal raw width differs")
    bytes
  end

  private def temporal_value(field : TemporalField, row : Int32) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.fixed(field.type, raw_bytes(field, row))
  end

  private def document(index : Int32) : CrystalClick::ObjectDocument
    fields = {} of String => CrystalClick::BinaryValue
    FIELDS.each { |field| fields[field.name] = temporal_value(field, index) }
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

  private def object_plan : CrystalClick::ObjectDocumentPlan
    int64 = CrystalClick::BinaryDataType.primitive("Int64")
    object = CrystalClick::ObjectStructure.new(["d"] of String)
    dynamics = {"d" => CrystalClick::DynamicStructure.new([int64])} of String => CrystalClick::DynamicStructure
    CrystalClick::ObjectDocumentPlan.new(CrystalClick::ObjectDynamicStructureSet.new(object, dynamics), typed_schema)
  end

  private def assert_documents(
    expected : Array(CrystalClick::ObjectDocument), actual : Array(CrystalClick::ObjectDocument), label : String,
  ) : Nil
    assert(expected.size == actual.size, "#{label}: document count differs")
    expected.each_with_index do |document, row|
      found = actual[row]
      assert(document.paths == found.paths, "#{label}: path roster differs at row #{row}")
      document.paths.each do |path|
        left = document.value_for(path)
        right = found.value_for(path)
        assert(left.type == right.type && left.is_null? == right.is_null? && left.bytes == right.bytes,
          "#{label}: nominal type or exact raw bytes differ at row #{row}, path #{path.inspect}")
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

  private def native_json_rows : String
    String.build do |io|
      KEYS.each_with_index do |key, index|
        io << "{\"pk\":" << key << ",\"payload\":{"
        FIELDS.each_with_index do |field, field_index|
          io << ',' unless field_index == 0
          io << '"' << field.name << "\":\"" << field.value(index) << '"'
        end
        io << ",\"t\":\"" << TEXT[index] << "\",\"d\":" << DYNAMIC[index]
        if index == 0
          io << ",\"spill\":\"alpha\""
        elsif index == 6
          io << ",\"spill\":\"omega\""
        end
        io << "}}\n"
      end
    end
  end

  private def expected_rowbinary(indices : Array(Int32)) : String
    String.build do |io|
      indices.each do |row|
        FIELDS.each { |field| io.write(raw_bytes(field, row)) }
      end
    end
  end

  private def assert_temporal_rowbinary(actual : String, indices : Array(Int32), label : String) : Nil
    expected = expected_rowbinary(indices)
    assert(actual.to_slice == expected.to_slice,
      "#{label}: temporal RowBinary seconds/ticks differ from independent literal carriers")
  end

  private def assert_check(actual : String, part_name : String, label : String) : Nil
    expected = "#{part_name}\t1\t\n"
    assert(actual == expected, "#{label}: CHECK TABLE row differs: #{actual.inspect}")
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
    assert(lines == expected, "#{label}: String/Dynamic rows differ: expected #{expected.inspect}, got #{lines.inspect}")
  end

  private def assert_type_names(binary : String, store : String, table : String, label : String) : Nil
    projection = (FIELDS.map { |field| "toTypeName(payload.#{field.name})" } + ["toTypeName(payload.t)"]).join(", ")
    actual = run(binary, store,
      "SELECT #{projection} FROM default.#{table} ORDER BY pk LIMIT 1 FORMAT TSVRaw").strip
    expected = (FIELDS.map(&.type_name) + ["String"]).join('\t')
    assert(actual == expected, "#{label}: canonical temporal nominal names differ")
  end

  private def expected_temporal_text(field : TemporalField, row : Int32) : String
    value = field.value(row)
    return value unless field.name.starts_with?("dt64_") || field.name.starts_with?("time64_")
    precision = field.name.split("_p").last.to_i
    parts = value.split('.')
    assert(parts.size == 2 && precision >= 0 && precision <= 9,
      "#{field.name}: malformed precision-specific text fixture")
    precision == 0 ? parts[0] : "#{parts[0]}.#{parts[1][0, precision]}"
  end

  private def assert_text_witnesses(binary : String, store : String, table : String, label : String) : Nil
    projection = FIELDS.map { |field| "toString(payload.#{field.name})" }.join(", ")
    actual = run(binary, store,
      "SELECT #{projection} FROM default.#{table} WHERE pk IN (1, 2) ORDER BY pk FORMAT TSVRaw").lines.map(&.chomp)
    wall = FIELDS.map { |field| expected_temporal_text(field, 0) }.join('\t')
    instant = FIELDS.map { |field| expected_temporal_text(field, 1) }.join('\t')
    assert(actual == [wall, instant], "#{label}: timezone/scale-sensitive text witnesses differ: #{actual.inspect}")
  end

  private def assert_stock_sql(
    binary : String, store : String, table : String, part_name : String, label : String,
  ) : {String, String}
    check = run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated")
    assert_check(check, part_name, "#{label} CHECK TABLE")
    assert_type_names(binary, store, table, label)
    assert_text_witnesses(binary, store, table, label)

    bare_zone_projection = ["payload.dt_bare"] + (0..9).map { |scale| "payload.dt64_bare_p#{scale}" }
    bare_zones = run(binary, store,
      "SELECT timezoneOf(toDateTime('2020-01-02 03:04:05')), #{bare_zone_projection.map { |field| "timezoneOf(#{field})" }.join(", ")} FROM default.#{table} LIMIT 1 FORMAT TSVRaw").strip
    assert(bare_zones.split('\t') == Array(String).new(bare_zone_projection.size + 1, "UTC"),
      "#{label}: a bare descriptor timezone is not process UTC: #{bare_zones.inspect}")

    temporal_projection = FIELDS.map { |field| "payload.#{field.name}" }.join(", ")
    full_binary = run(binary, store,
      "SELECT #{temporal_projection} FROM default.#{table} ORDER BY pk FORMAT RowBinary")
    assert_temporal_rowbinary(full_binary, (0...KEYS.size).to_a, "#{label} full temporal RowBinary")
    selected_binary = run(binary, store,
      "SELECT #{temporal_projection} FROM default.#{table} WHERE pk >= 3 AND pk <= 4 ORDER BY pk FORMAT RowBinary")
    assert_temporal_rowbinary(selected_binary, [2, 3], "#{label} selected temporal RowBinary")

    object_projection = "pk, hex(payload.t), length(payload.t), payload.d, dynamicType(payload.d), dynamicType(payload.spill), ifNull(hex(dynamicElement(payload.spill, 'String')), '')"
    full_object = run(binary, store,
      "SELECT #{object_projection} FROM default.#{table} ORDER BY pk FORMAT TSVRaw")
    assert_object_sql(full_object, (0...KEYS.size).to_a, "#{label} full String/Dynamic SQL")
    selected_object = run(binary, store,
      "SELECT #{object_projection} FROM default.#{table} WHERE pk >= 3 AND pk <= 4 ORDER BY pk FORMAT TSVRaw")
    assert_object_sql(selected_object, [2, 3], "#{label} selected String/Dynamic SQL")
    {check, full_binary}
  end

  private def assert_default_serializers(serialization : JSON::Any, label : String) : Nil
    info = serialization.as_h
    columns = info["columns"]?.try(&.as_a) || raise Mismatch.new("#{label}: serializer columns are missing")
    columns.each_with_index do |entry, index|
      kind = entry.as_h["kind"]?.try(&.as_s) || raise Mismatch.new("#{label}: serializer kind missing at #{index}")
      assert(kind == "Default", "#{label}: serializer kind is not Default at entry #{index}: #{kind.inspect}")
    end
  end

  private def read_u64_le(bytes : Bytes, offset : Int32) : UInt64
    assert(offset >= 0 && offset <= bytes.size - 8, "truncated Dynamic discriminator mode header")
    value = 0_u64
    8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
    value
  end

  private def assert_part_profile(
    part : Part, expected_schema : CrystalClick::ObjectDocumentSchema,
    profile : CrystalClick::BinaryBulkProfile, mode : UInt64, label : String,
  ) : {Array(UInt64), Array(Int32)}
    codec = File.read(File.join(part[:path], "default_compression_codec.txt")).strip
    assert(codec == "CODEC(LZ4)", "#{label}: actual part codec differs from LZ4: #{codec.inspect}")
    assert(File.file?(File.join(part[:path], "primary.idx")) && !File.exists?(File.join(part[:path], "primary.cidx")),
      "#{label}: expected a plain primary.idx")
    basenames = Dir.children(part[:path])
    assert(basenames.any?(&.ends_with?(".mrk2")), "#{label}: no plain mark files found")
    assert(basenames.none?(&.ends_with?(".cmrk2")), "#{label}: compressed mark file found")
    assert_default_serializers(JSON.parse(File.read(File.join(part[:path], "serialization.json"))), "#{label} actual part")

    reader = CrystalClick::ObjectColumnReader.open(part[:path], "payload", expected_schema)
    assert(reader.row_count == KEYS.size.to_u64, "#{label}: Object reader row count differs")
    assert(reader.ordinary_profile == profile, "#{label}: actual ordinary String profile differs")
    assert(reader.source_declaration == expected_schema.declaration, "#{label}: source DDL differs from canonical declaration")
    grid = reader.mark_row_counts
    assert_grid(grid, "#{label} ObjectColumnReader")
    descriptor = CrystalClick::ObjectDocumentFileReader.inspect(
      part[:path], "payload", expected_schema.typed_paths, reader.ordinary_profile,
      CrystalClick::BinaryBulkProfile.single_stream, true
    )
    object = descriptor.plan.structures.object
    assert(object.version == 4_u64 && object.shared_data_version == 0_u64 && object.bucket_count == 1_u64,
      "#{label}: actual Object structure is not V3 with one shared MAP bucket")
    assert(descriptor.plan.structures.dynamic_count == 1 && object.dynamic_paths == ["d"],
      "#{label}: actual Dynamic path roster differs")
    assert(descriptor.plan.typed_paths == typed_schema && descriptor.plan.typed_paths.size == 38,
      "#{label}: actual 37-temporal-plus-String type roster or nominal identities differ")
    FIELDS.each do |field|
      assert(descriptor.plan.typed_type_for(field.name) == field.type,
        "#{label}: temporal descriptor changed at #{field.name}")
    end
    assert(descriptor.plan.typed_type_for("t") == CrystalClick::BinaryDataType.primitive("String"),
      "#{label}: explicit t String declaration changed or became Dynamic")
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

  private def assert_object_reader(part : Part, expected_schema : CrystalClick::ObjectDocumentSchema, label : String) : Nil
    reader = CrystalClick::ObjectColumnReader.open(part[:path], "payload", expected_schema)
    expected = granules(expected_documents)
    grid = reader.mark_row_counts
    assert_grid(grid, "#{label} ObjectColumnReader")
    assert_granules(expected, reader.read_marks(0, grid.size), "#{label} ObjectColumnReader full")
    assert_granules([expected[1]], reader.read_marks(1, 1), "#{label} ObjectColumnReader selected mark")
    assert_granules([] of Array(CrystalClick::ObjectDocument), reader.read_marks(grid.size, 0),
      "#{label} ObjectColumnReader zero marks")
    full = CrystalClick::ObjectDocumentFileReader.read(
      part[:path], "payload", expected_schema.typed_paths, first_mark: 0, mark_count: grid.size,
      profile: reader.ordinary_profile, shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      hashed: true, limits: CrystalClick::BinaryCodecLimits.default,
      transport_limits: CrystalClick::CompressedStreamLimits.new
    )
    assert_granules(expected, full, "#{label} ObjectDocumentFileReader full")
    middle = CrystalClick::ObjectDocumentFileReader.read(
      part[:path], "payload", expected_schema.typed_paths, first_mark: 1, mark_count: 1,
      profile: reader.ordinary_profile, shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      hashed: true, limits: CrystalClick::BinaryCodecLimits.default,
      transport_limits: CrystalClick::CompressedStreamLimits.new
    )
    assert_granules([expected[1]], middle, "#{label} ObjectDocumentFileReader selected mark")
    zero = CrystalClick::ObjectDocumentFileReader.read(
      part[:path], "payload", expected_schema.typed_paths, first_mark: grid.size, mark_count: 0,
      profile: reader.ordinary_profile, shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      hashed: true, limits: CrystalClick::BinaryCodecLimits.default,
      transport_limits: CrystalClick::CompressedStreamLimits.new
    )
    assert_granules([] of Array(CrystalClick::ObjectDocument), zero, "#{label} ObjectDocumentFileReader zero marks")
  end

  private def catalog_root(
    root : String, label : String, table_number : Int32, part : Part, declaration : String,
  ) : {root: String, part_path: String}
    catalog = File.join(root, "catalog", label)
    assert(!File.exists?(catalog) && !File.symlink?(File.dirname(catalog)), "#{label}: catalog path occupied or unsafe")
    metadata = File.join(catalog, "metadata")
    FileUtils.mkdir_p(metadata)
    FileUtils.mkdir_p(File.join(catalog, "store"))
    database_uuid = "13900000-0000-4000-8000-000000000001"
    table_uuid = "13910000-0000-4000-8000-00000000000#{table_number}"
    File.write(File.join(metadata, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
    database_dir = File.join(catalog, "store", database_uuid[0, 3], database_uuid)
    FileUtils.mkdir_p(database_dir)
    File.write(File.join(database_dir, "events.sql"),
      "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` #{declaration}\n)\nENGINE = MergeTree\nORDER BY `pk`\n")
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
    owned = values[1].value_for("dt64_utc_p3").bytes
    owned[0] ^= 1_u8
    assert(values[1].value_for("dt64_utc_p3").bytes == raw_bytes(FIELDS.find! { |field| field.name == "dt64_utc_p3" }, 1),
      "#{label}: mutating a detached temporal byte snapshot changed the document")
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

  private def assert_table_delivery(
    catalog_root : String, expected_part_path : String, part : Part, label : String,
  ) : Nil
    table = CrystalClick::OfflineCatalog.open(catalog_root).table("lab", "events")
    resolved = table.resolved_scan_parts
    assert(resolved.map(&.name) == [part[:name]], "#{label}: table catalog part inventory differs")
    resolved_path = resolved[0].path
    assert(resolved_path == expected_part_path,
      "#{label}: catalog resolved part differs from its independently copied destination")
    full = [] of CapturedBatch
    table.scan_typed(["pk", "payload"], batch_rows: 2) do |batch|
      assert(batch.column_names == ["pk", "payload"], "#{label}: typed table changed caller column order")
      full << capture(batch)
      nil
    end
    assert_batches(full, part[:name], resolved_path,
      [0_i32, 1_i32, 2_i32, 3_i32], [0_u64, 0_u64, 0_u64, 0_u64],
      [0_u64, 2_u64, 4_u64, 6_u64], [[1_u64, 2_u64], [3_u64, 4_u64], [5_u64, 6_u64], [7_u64]],
      "#{label} full typed-table scan")
    window = [] of CapturedBatch
    table.scan_typed_window(["pk", "payload"], 1_u64, max_rows: 3) { |batch| window << capture(batch); nil }
    assert_batches(window, part[:name], resolved_path,
      [0_i32, 1_i32], [1_u64, 0_u64], [1_u64, 2_u64], [[2_u64], [3_u64, 4_u64]],
      "#{label} physical typed-table window")
    candidates = [] of CapturedBatch
    table.scan_uint64_pk_candidates(["pk", "payload"], lower_bound: 6_u64, upper_bound: 6_u64) do |batch|
      candidates << capture(batch)
      nil
    end
    assert(candidates.map(&.[:mark_index]) == [2_i32], "#{label}: PK candidate callback schedule differs")
    assert_batches(candidates, part[:name], resolved_path, [2_i32], [0_u64], [4_u64],
      [[5_u64, 6_u64]], "#{label} whole PK candidate granule")
    assert(candidates.sum(&.[:keys].size) == 2, "#{label}: PK=6 candidate did not retain its full granule")
    exact = [] of CrystalClick::ObjectDocument
    rejected = [] of UInt64
    candidates.each do |batch|
      batch[:keys].each_with_index do |key, row|
        key == 6_u64 ? exact << batch[:payload][row] : rejected << key
      end
    end
    assert(exact.size == 1 && rejected == [5_u64], "#{label}: exact PK residual did not isolate key 6")
    assert_documents([expected_documents[5]], exact, "#{label} exact PK residual")
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

  private def assert_comparator_sensitivity(check : String, full_binary : String, part_name : String) : Nil
    expected = expected_documents
    field = FIELDS.find! { |entry| entry.name == "dt_bare" }
    changed = raw_bytes(field, 2)
    changed[0] ^= 1_u8
    expect_mismatch("temporal raw-byte mutation") do
      assert_documents(expected, replace_document(expected, 2, field.name,
        CrystalClick::BinaryValue.fixed(field.type, changed)), "seeded temporal raw-byte defect")
    end

    scale_field = FIELDS.find! { |entry| entry.name == "dt64_utc_p3" }
    expect_mismatch("same-width DateTime64 scale mismatch") do
      wrong_scale = CrystalClick::BinaryDataType.datetime64(4, "UTC")
      assert_documents(expected, replace_document(expected, 1, scale_field.name,
        CrystalClick::BinaryValue.fixed(wrong_scale, raw_bytes(scale_field, 1))), "seeded temporal scale defect")
    end

    expect_mismatch("same-width DateTime64 timezone mismatch") do
      wrong_zone = CrystalClick::BinaryDataType.datetime64(3, "America/New_York")
      assert_documents(expected, replace_document(expected, 1, scale_field.name,
        CrystalClick::BinaryValue.fixed(wrong_zone, raw_bytes(scale_field, 1))), "seeded temporal zone defect")
    end

    expect_mismatch("same-width Int64 alias for DateTime64") do
      alias_type = CrystalClick::BinaryDataType.primitive("Int64")
      assert_documents(expected, replace_document(expected, 1, scale_field.name,
        CrystalClick::BinaryValue.fixed(alias_type, raw_bytes(scale_field, 1))), "seeded temporal integer alias")
    end

    wrong_check = check.gsub("\t1\t", "\t0\t")
    assert(wrong_check != check, "seeded CHECK control did not mutate the positive result")
    expect_mismatch("wrong CHECK TABLE result") { assert_check(wrong_check, part_name, "seeded wrong CHECK") }

    wrong_grid = [2_u64, 1_u64, 3_u64, 1_u64]
    assert(wrong_grid.sum == KEYS.size.to_u64 && wrong_grid != ROWS_PER_MARK,
      "seeded mark-grid control did not preserve row total while changing distribution")
    expect_mismatch("wrong physical mark grid with unchanged row total") { assert_grid(wrong_grid, "seeded wrong grid") }

    truncated = String.new(full_binary.to_slice[0, full_binary.bytesize - 1])
    expect_mismatch("truncated temporal RowBinary") do
      assert_temporal_rowbinary(truncated, (0...KEYS.size).to_a, "seeded truncated RowBinary")
    end
  end

  private def assert_raw_carrier_extrema : Nil
    date_time = CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.datetime, bytes_from_hex("ffffffff"))
    assert(date_time.bytes == bytes_from_hex("ffffffff"), "local DateTime UInt32 maximum carrier changed")
    date_time_zone = CrystalClick::BinaryValue.fixed(
      CrystalClick::BinaryDataType.datetime("America/New_York"), bytes_from_hex("ffffffff")
    )
    assert(date_time_zone.bytes == bytes_from_hex("ffffffff"), "local zoned DateTime UInt32 maximum carrier changed")
    time_min = CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("Time"), bytes_from_hex("00000080"))
    time_max = CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("Time"), bytes_from_hex("ffffff7f"))
    assert(time_min.bytes == bytes_from_hex("00000080") && time_max.bytes == bytes_from_hex("ffffff7f"),
      "local Time Int32 endpoint carriers changed")
    assert(CrystalClick::DateTimeValue.new(UInt32::MAX).raw == UInt32::MAX &&
           CrystalClick::TimeValue.new(Int32::MIN).raw == Int32::MIN &&
           CrystalClick::TimeValue.new(Int32::MAX).raw == Int32::MAX,
      "local second-carrier endpoint wrappers changed raw values")

    10.times do |scale|
      datetime_type = CrystalClick::BinaryDataType.datetime64(scale)
      time_type = CrystalClick::BinaryDataType.time64(scale)
      {"0000000000000080", "ffffffffffffff7f"}.each do |hex|
        bytes = bytes_from_hex(hex)
        assert(CrystalClick::BinaryValue.fixed(datetime_type, bytes).bytes == bytes,
          "local DateTime64(#{scale}) endpoint bytes changed")
        assert(CrystalClick::BinaryValue.fixed(time_type, bytes).bytes == bytes,
          "local Time64(#{scale}) endpoint bytes changed")
      end
      assert(CrystalClick::DateTime64Value.new(Int64::MIN, scale).raw == Int64::MIN &&
             CrystalClick::DateTime64Value.new(Int64::MAX, scale).precision == scale.to_u8,
        "local DateTime64(#{scale}) carrier wrapper changed endpoint or precision")
      assert(CrystalClick::Time64Value.new(Int64::MIN, scale).raw == Int64::MIN &&
             CrystalClick::Time64Value.new(Int64::MAX, scale).precision == scale.to_u8,
        "local Time64(#{scale}) carrier wrapper changed endpoint or precision")
    end
    puts "PASS W139 local raw carrier extrema; no extreme carrier is passed through native calendar text formatting"
  end

  private def native_case(
    binary : String, root : String, profile_name : String, profile : CrystalClick::BinaryBulkProfile,
    mode_name : String, mode : UInt64, case_number : Int32, check_negative_controls : Bool,
    expected_schema : CrystalClick::ObjectDocumentSchema,
  ) : Nil
    label = "native_#{profile_name}_#{mode_name}"
    store = File.join(root, "stores", label)
    FileUtils.mkdir_p(store)
    table = table_name(label)
    create_table(binary, store, table, expected_schema.declaration, profile_name, mode, label)
    run(binary, store, "INSERT INTO default.#{table} FORMAT JSONEachRow", IO::Memory.new(native_json_rows))
    part = stock_part(binary, store, table, label)
    check, full_binary = assert_stock_sql(binary, store, table, part[:name], label)
    assert_comparator_sensitivity(check, full_binary, part[:name]) if check_negative_controls
    assert_part_profile(part, expected_schema, profile, mode, label)
    assert_object_reader(part, expected_schema, label)
    catalog = catalog_root(root, label, case_number, part, expected_schema.declaration)
    catalog_values(catalog[:root], label)
    assert_table_delivery(catalog[:root], catalog[:part_path], part, label)
    puts "PASS W139 native JSONEachRow -> stock CHECK/raw temporal RowBinary/nominal text -> Object reader/catalog/table: #{label}"
  end

  private def library_case(
    binary : String, root : String, profile_name : String, profile : CrystalClick::BinaryBulkProfile,
    mode_name : String, mode : UInt64, table_number : Int32,
    expected_schema : CrystalClick::ObjectDocumentSchema,
  ) : Nil
    label = "library_#{profile_name}_#{mode_name}"
    store = File.join(root, "stores", label)
    FileUtils.mkdir_p(store)
    table = table_name(label)
    create_table(binary, store, table, expected_schema.declaration, profile_name, mode, label)
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
    CrystalClick::WidePartWriter.write_uint64_object_pair(
      part_path, "pk", Slice(UInt64).new(KEYS.size) { |index| KEYS[index] },
      "payload", expected_schema, object_plan, granules(expected_documents), rows_per_mark: 2,
      mode: mode, profile: profile, shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      frame_bytes: FRAME_BYTES
    )
    part_path = store_child(part_path, store, "#{label} library-written part")
    run(binary, store, "ALTER TABLE default.#{table} ATTACH PART '#{part_name}'")
    part = stock_part(binary, store, table, label)
    assert(part[:name] == part_name, "#{label}: ATTACH changed the library part identity")
    assert_stock_sql(binary, store, table, part[:name], label)
    assert_part_profile(part, expected_schema, profile, mode, label)
    assert_object_reader(part, expected_schema, label)
    catalog = catalog_root(root, label, table_number, part, expected_schema.declaration)
    catalog_values(catalog[:root], label)
    assert_table_delivery(catalog[:root], catalog[:part_path], part, label)
    puts "PASS W139 library temporal part -> stock ATTACH/CHECK/raw temporal RowBinary/nominal text -> Object reader/catalog/table: #{label}"
  end

  def check : Nil
    binary = ENV["CLICKHOUSE_BIN"]? || raise "CLICKHOUSE_BIN is required"
    root = ENV["W139_TMP_ROOT"]? || raise "W139_TMP_ROOT is required"
    assert(!File.symlink?(root) && Dir.exists?(root), "W139 temporary root must be an existing non-symlink directory")
    root = File.realpath(root)
    assert(root.starts_with?("/private/tmp/crystal-click-object-temporal-w139."), "unsafe W139 temporary root")

    assert(KEYS.size == 7 && TEXT.size == 7 && DYNAMIC.size == 7, "W139 seven-row fixture inventory changed")
    assert(ROWS_PER_MARK == [2_u64, 2_u64, 2_u64, 1_u64], "W139 physical mark fixture changed")
    assert(DT64_HEX.size == 10 && TIME64_HEX.size == 10 && FIELDS.size == 37,
      "W139 declared temporal family/scale inventory changed")
    assert(FIELDS.map(&.name).uniq.size == FIELDS.size, "W139 temporal field names are not unique")
    FIELDS.each do |field|
      7.times { |row| assert(raw_bytes(field, row).size == field.width, "#{field.name}: literal carrier width differs") }
    end

    assert_raw_carrier_extrema
    expected_schema = schema
    bootstrap_store = File.join(root, "bootstrap")
    FileUtils.mkdir_p(bootstrap_store)
    verify_runtime(binary, bootstrap_store)

    puts "W139 canonical typed roster: 37 declared temporal fields plus explicit t String; separate d Int64 Dynamic and spill shared paths"
    puts "W139 bounded corridor: 4 native JSONEachRow + 4 library ATTACH cells; String single_stream/with_size_stream x Dynamic BASIC/COMPACT; Object V3 one MAP bucket; LZ4 Wide; grid 2,2,2,1"
    case_number = 1
    PROFILES.each do |profile_name, profile|
      MODES.each do |mode_name, mode|
        native_case(binary, root, profile_name, profile, mode_name, mode, case_number,
          check_negative_controls: case_number == 1, expected_schema: expected_schema)
        case_number += 1
      end
    end
    table_number = 5
    PROFILES.each do |profile_name, profile|
      MODES.each do |mode_name, mode|
        library_case(binary, root, profile_name, profile, mode_name, mode, table_number, expected_schema)
        table_number += 1
      end
    end
    puts "PASS W139 scope: declared DateTime/DateTime64/Time/Time64 Object temporal paths, exact nominal types and raw carriers; no Nullable, nested temporal paths, defaults, or general MergeTree claim"
  end
end

W139TemporalOracle.new.check
