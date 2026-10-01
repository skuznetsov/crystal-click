# W105 stock-first discriminator for Nullable scalar leaves in a named-flat
# Tuple. This profile is inserted through RowBinary: in particular, the
# Nullable(Enum8) NULL rows exercise SerializationNullable's RowBinary
# `insertDefault` route, not SQL CAST's first-enumerator route. Every typed
# reader attempt is delayed until stock schema, metadata, bytes, marks, CHECK,
# and full/selected RowBinary have independently matched.
require "json"
require "../src/crystal_click"

W105_STOCK_VERSION                    = "26.7.1.1315"
W105_KEYS                             = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
W105_MARK_ROWS                        = [2_u64, 2_u64, 1_u64, 0_u64]
W105_MARK_BOUNDARIES                  = [0, 2, 4, 5]
W105_ENUM_NULL_ROW_BINARY_EXPECTATION = [0x00_u8, 0xf9_u8, 0x07_u8, 0x00_u8, 0xf9_u8]
W105_TUPLE_TYPE                       = "Tuple(u64 Nullable(UInt64), text Nullable(String), state Nullable(Enum8('neg' = -7, 'pos' = 7)), fixed Nullable(FixedString(3)), event Nullable(DateTime64(3, 'America/New_York')), amount Nullable(Decimal(9, 2)))"
W105_TABLE                            = "w105_nullable_tuple_source"

class W105ByteMismatchError < Exception
end

struct W105Field
  getter name : String
  getter type_name : String
  getter streams : Array({String, Array(String)})
  getter rowbinary_rows : Array(String)
  getter null_count : Int32

  def initialize(@name : String, @type_name : String, streams : Array({String, Array(String)}), @rowbinary_rows : Array(String), @null_count : Int32)
    raise "#{@name}: expected five RowBinary rows" unless @rowbinary_rows.size == W105_KEYS.size
    raise "#{@name}: no physical streams" if streams.empty?
    streams.each do |(_, fragments)|
      raise "#{@name}: physical fragment count differs" unless fragments.size == W105_KEYS.size
    end
    @streams = streams.dup
  end

  def substreams : Array(String)
    @streams.map(&.[0])
  end
end

def w105_unsigned_le(value : UInt64, width : Int32) : String
  String.build do |output|
    width.times do |index|
      output.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8)
    end
  end
end

def w105_signed_le(value : Int64, width : Int32) : String
  w105_unsigned_le(value.unsafe_as(UInt64), width)
end

def w105_byte(value : UInt8) : String
  String.new(Bytes[value])
end

def w105_varuint(value : UInt64) : String
  String.build do |output|
    remaining = value
    while remaining >= 0x80_u64
      output.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
      remaining >>= 7
    end
    output.write_byte(remaining.to_u8)
  end
end

def w105_nullable_rowbinary(value : String?) : String
  if value
    "\x00" + value
  else
    "\x01"
  end
end

def w105_scalar_field(name : String, type_name : String, values : Array(String?), width : Int32) : W105Field
  raise "#{name}: expected five values" unless values.size == W105_KEYS.size
  base = "payload%2E#{name}"
  nulls = values.map { |value| w105_byte(value ? 0_u8 : 1_u8) }
  default = String.new(Bytes.new(width, 0_u8))
  nested = values.map { |value| value || default }
  streams = [
    {"#{base}.null", nulls},
    {base, nested},
  ]
  W105Field.new(name, type_name, streams, values.map { |value| w105_nullable_rowbinary(value) }, values.count(&.nil?).to_i32)
end

def w105_string_field(name : String, type_name : String, values : Array(String?)) : W105Field
  raise "#{name}: expected five values" unless values.size == W105_KEYS.size
  base = "payload%2E#{name}"
  nulls = values.map { |value| w105_byte(value ? 0_u8 : 1_u8) }
  lengths = values.map { |value| w105_unsigned_le((value ? value.bytesize : 0).to_u64, 8) }
  contents = values.map { |value| value || "" }
  streams = [
    {"#{base}.null", nulls},
    {"#{base}.size", lengths},
    {base, contents},
  ]
  rowbinary = values.map do |value|
    if value
      "\x00" + w105_varuint(value.bytesize.to_u64) + value
    else
      "\x01"
    end
  end
  W105Field.new(name, type_name, streams, rowbinary, values.count(&.nil?).to_i32)
end

def w105_fields : Array(W105Field)
  fields = [] of W105Field
  fields << w105_scalar_field(
    "u64", "Nullable(UInt64)",
    [nil, w105_unsigned_le(0_u64, 8), w105_unsigned_le(7_u64, 8), w105_unsigned_le(99_u64, 8), w105_unsigned_le(UInt64::MAX, 8)] of String?, 8
  )
  fields << w105_string_field(
    "text", "Nullable(String)",
    [nil, "", "a\0b", "tail", nil] of String?
  )
  fields << w105_scalar_field(
    "state", "Nullable(Enum8('neg' = -7, 'pos' = 7))",
    [nil, w105_signed_le(-7_i64, 1), w105_signed_le(7_i64, 1), nil, w105_signed_le(-7_i64, 1)] of String?, 1
  )
  fields << w105_scalar_field(
    "fixed", "Nullable(FixedString(3))",
    [nil, "\0\0\0", "abc", "xyz", "end"] of String?, 3
  )
  fields << w105_scalar_field(
    "event", "Nullable(DateTime64(3, 'America/New_York'))",
    [nil, w105_signed_le(0_i64, 8), w105_signed_le(-1_i64, 8), w105_signed_le(1_615_705_200_001_i64, 8), w105_signed_le(1_636_264_800_001_i64, 8)] of String?, 8
  )
  fields << w105_scalar_field(
    "amount", "Nullable(Decimal(9, 2))",
    [nil, w105_signed_le(0_i64, 4), w105_signed_le(-123_i64, 4), w105_signed_le(1_234_i64, 4), nil] of String?, 4
  )
  raise "W105 field matrix differs: #{fields.size}" unless fields.size == 6
  fields
end

def w105_tuple_default_count(fields : Array(W105Field)) : Int32
  # Row 1 is all NULL; other rows each have at least one non-NULL leaf.
  fields.each { |field| raise "W105 discriminator requires a NULL in every child" if field.null_count == 0 }
  1
end

def w105_expected_rowbinary(fields : Array(W105Field), indexes : Array(Int32)) : String
  String.build do |output|
    indexes.each do |index|
      output << w105_unsigned_le(W105_KEYS[index], 8)
      fields.each { |field| output << field.rowbinary_rows[index] }
    end
  end
end

def w105_expected_streams(fields : Array(W105Field)) : Array({String, Array(String)})
  streams = [{"pk", W105_KEYS.map { |key| w105_unsigned_le(key, 8) }}]
  fields.each { |field| streams.concat(field.streams) }
  streams
end

def w105_attempt_clickhouse(binary : String, store : String, query : String, input : IO? = nil) : {Bool, String, String}
  output = IO::Memory.new
  error = IO::Memory.new
  status = if input
             Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: error)
           else
             Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
           end
  {status.success?, output.to_s, error.to_s}
end

def w105_clickhouse(binary : String, store : String, query : String, input : IO? = nil) : String
  succeeded, output, error = w105_attempt_clickhouse(binary, store, query, input)
  raise "ClickHouse local query failed: #{error}\n#{query}" unless succeeded
  output
end

def w105_settings : String
  "index_granularity = 2, index_granularity_bytes = 10485760, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, ratio_of_defaults_for_sparse_serialization = 0.9375, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, default_compression_codec = 'LZ4'"
end

def w105_insert(binary : String, store : String, fields : Array(W105Field)) : String
  input = IO::Memory.new(w105_expected_rowbinary(fields, [0, 1, 2, 3, 4]).to_slice)
  w105_clickhouse(binary, store, "INSERT INTO default.#{W105_TABLE} FORMAT RowBinary", input)
end

def w105_part_path(binary : String, store : String) : String
  rows = w105_clickhouse(
    binary, store,
    "SELECT path, part_type, rows FROM system.parts WHERE database='default' AND table='#{W105_TABLE}' AND active FORMAT TSVRaw"
  ).lines.map(&.strip).reject(&.empty?)
  raise "#{W105_TABLE}: expected exactly one active part, got #{rows.inspect}" unless rows.size == 1
  columns = rows[0].split('\t')
  raise "#{W105_TABLE}: malformed system.parts row #{rows[0].inspect}" unless columns.size == 3
  raise "#{W105_TABLE}: expected a Wide part, got #{columns[1]}" unless columns[1] == "Wide"
  raise "#{W105_TABLE}: expected five rows, got #{columns[2]}" unless columns[2] == W105_KEYS.size.to_s
  columns[0]
end

def w105_assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual == expected
  limit = Math.min(actual.bytesize, expected.bytesize)
  difference = 0
  while difference < limit && actual.to_slice[difference] == expected.to_slice[difference]
    difference += 1
  end
  got = difference < actual.bytesize ? actual.to_slice[difference].to_s(16).rjust(2, '0') : "<eof>"
  wanted = difference < expected.bytesize ? expected.to_slice[difference].to_s(16).rjust(2, '0') : "<eof>"
  raise W105ByteMismatchError.new("#{label}: expected #{expected.bytesize} bytes, got #{actual.bytesize}; first difference #{difference}: expected #{wanted}, got #{got}")
end

def w105_seeded_wrong_expectation_rejected(actual : String, expected : String, label : String) : Nil
  raise "#{label}: baseline comparator did not match" unless actual == expected
  damaged = String.new(expected.to_slice)
  raise "#{label}: cannot seed an empty byte string" if damaged.empty?
  damaged.to_unsafe[0] = damaged.to_slice[0] ^ 0x01_u8
  begin
    w105_assert_bytes(actual, damaged, "#{label} seeded wrong bytes")
    raise "#{label}: comparator accepted a seeded mismatch"
  rescue ex : W105ByteMismatchError
  end
  puts "PASS #{label}: comparator rejects seeded one-byte mismatch"
end

def w105_schema(binary : String, store : String, fields : Array(W105Field)) : Array(String)
  actual = w105_clickhouse(
    binary, store,
    "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{W105_TABLE}' ORDER BY position FORMAT TSVRaw"
  ).lines.map(&.strip)
  expected = ["pk UInt64", "payload #{W105_TUPLE_TYPE}"]
  raise "W105 system.columns differs: #{actual.inspect}" unless actual == expected
  raise "W105 six-leaf source profile differs" unless fields.size == 6
  actual
end

def w105_expected_substreams(fields : Array(W105Field)) : String
  children = fields.flat_map(&.substreams)
  lines = [
    "columns substreams version: 1",
    "2 columns:",
    "1 substreams for column `pk`:",
    "\tpk",
    "#{children.size} substreams for column `payload`:",
  ]
  children.each { |stream| lines << "\t#{stream}" }
  lines.join("\n") + "\n"
end

def w105_read_mark_entries(part : String, stream : String) : Array({UInt64, UInt64, UInt64})
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  bytes = File.read(path).to_slice
  mark_size = CrystalClick::WidePart::MARK_SIZE
  raise "#{stream}: truncated .mrk2 record" unless bytes.size % mark_size == 0
  Array({UInt64, UInt64, UInt64}).new(bytes.size // mark_size) do |index|
    offset = index * mark_size
    fields = Array(UInt64).new(3) do |field|
      start = offset + field * 8
      8.times.reduce(0_u64) { |value, byte| value | (bytes[start + byte].to_u64 << (byte * 8)) }
    end
    {fields[0], fields[1], fields[2]}
  end
end

def w105_expected_marks(fragments : Array(String)) : Array({UInt64, UInt64, UInt64})
  W105_MARK_BOUNDARIES.each_with_index.map do |boundary, index|
    decompressed = fragments[0, boundary].sum(&.bytesize).to_u64
    {0_u64, decompressed, W105_MARK_ROWS[index]}
  end.to_a
end

def w105_validate_counter(row : Hash(String, JSON::Any), expected_defaults : Int32, label : String) : Nil
  kind = row["kind"]?.try(&.as_s) || raise "#{label}: serializer kind missing"
  raise "#{label}: expected Default serializer, got #{kind}" unless kind == "Default"
  rows = row["num_rows"]?.try(&.as_i) || raise "#{label}: num_rows missing"
  defaults = row["num_defaults"]?.try(&.as_i) || raise "#{label}: num_defaults missing"
  raise "#{label}: num_rows=#{rows}, expected five" unless rows == W105_KEYS.size.to_i64
  raise "#{label}: num_defaults=#{defaults}, expected #{expected_defaults}" unless defaults == expected_defaults.to_i64
end

def w105_assert_metadata(part : String, fields : Array(W105Field)) : Nil
  info = JSON.parse(File.read(File.join(part, "serialization.json"))).as_h
  puts "OBSERVED W105 stock serialization.json=#{info.to_json}"
  expected_keys = ["columns", "propagate_types_serialization_versions_to_nested_types", "types_serialization_versions", "version"].sort
  raise "W105 serialization.json envelope differs: #{info.keys.sort.inspect}" unless info.keys.sort == expected_keys
  raise "W105 serialization version differs" unless info["version"]?.try(&.as_i) == 1
  raise "W105 nested type-version propagation differs" unless info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  versions = info["types_serialization_versions"]?.try(&.as_h) || raise "W105 type-version map missing"
  raise "W105 type-version map differs: #{versions.to_json}" unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
  records = info["columns"]?.try(&.as_a) || raise "W105 serialization columns missing"
  names = records.map { |entry| entry.as_h["name"]?.try(&.as_s) || raise "W105 serializer name missing" }
  raise "W105 serializer roots/order differ: #{names.inspect}" unless names == ["payload", "pk"]
  payload = records[0].as_h
  children = payload["subcolumns"]?.try(&.as_a) || raise "W105 Tuple child metadata missing"
  raise "W105 Tuple child count differs: #{children.size}" unless children.size == fields.size
  w105_validate_counter(payload, w105_tuple_default_count(fields), "W105 Tuple root")
  fields.each_with_index do |field, index|
    w105_validate_counter(children[index].as_h, field.null_count, "W105 nullable Tuple child #{field.name}")
  end
  w105_validate_counter(records[1].as_h, 0, "W105 primary key")
end

def w105_assert_layout(part : String, schema : Array(String), fields : Array(W105Field)) : Nil
  expected_columns = ["columns format version: 1", "2 columns:", "`pk` UInt64", "`payload` #{W105_TUPLE_TYPE}"]
  actual_columns = File.read(File.join(part, "columns.txt")).lines.map(&.strip)
  raise "W105 columns.txt differs: #{actual_columns.inspect}" unless actual_columns == expected_columns
  actual_substreams = File.read(File.join(part, "columns_substreams.txt"))
  expected_substreams = w105_expected_substreams(fields)
  raise "W105 columns_substreams.txt differs: #{actual_substreams.inspect}" unless actual_substreams == expected_substreams
  codec = File.read(File.join(part, "default_compression_codec.txt"))
  raise "W105 part codec differs: #{codec.inspect}" unless codec == "CODEC(LZ4)"

  streams = w105_expected_streams(fields)
  expected_bins = streams.map { |(name, _)| "#{CrystalClick::StreamName.hash(name)}.bin" }.sort
  expected_marks = streams.map { |(name, _)| "#{CrystalClick::StreamName.hash(name)}.mrk2" }.sort
  entries = Dir.children(part)
  actual_bins = entries.select(&.ends_with?(".bin")).sort
  actual_marks = entries.select(&.ends_with?(".mrk2")).sort
  raise "W105 complete .bin inventory differs: #{actual_bins.inspect}" unless actual_bins == expected_bins
  raise "W105 complete .mrk2 inventory differs: #{actual_marks.inspect}" unless actual_marks == expected_marks

  streams.each do |(name, fragments)|
    expected_raw = fragments.join
    encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(name)}.bin")).to_slice
    actual_raw = String.new(CrystalClick::CompressedBlock.decode_all(encoded))
    w105_assert_bytes(actual_raw, expected_raw, "W105 #{name} stock physical bytes")
    observed_marks = w105_read_mark_entries(part, name)
    expected_marks_for_stream = w105_expected_marks(fragments)
    raise "W105 #{name} exact mark entries differ: observed #{observed_marks.inspect}; expected #{expected_marks_for_stream.inspect}" unless observed_marks == expected_marks_for_stream
    if name == "payload%2Estate"
      observed = actual_raw.to_slice.to_a
      puts "OBSERVED W105 RowBinary Nullable(Enum8) nested raw bytes=#{observed.inspect}; null-map route is RowBinary"
      raise "W105 RowBinary Nullable(Enum8) nested NULL defaults differ: #{observed.inspect}" unless observed == W105_ENUM_NULL_ROW_BINARY_EXPECTATION
      w105_seeded_wrong_expectation_rejected(actual_raw, expected_raw, "W105 Enum nested stream")
    end
  end
  w105_assert_metadata(part, fields)
  puts "PASS W105 exact source schema/substreams, complete #{streams.size}-stream .bin/.mrk2 inventories, raw bytes, full mark tuples, and serialization defaults"
end

def w105_check_table(binary : String, store : String, part : String) : Nil
  actual = w105_clickhouse(binary, store, "CHECK TABLE default.#{W105_TABLE} FORMAT TabSeparated").strip
  expected = "#{File.basename(part.chomp("/"))}\t1"
  raise "W105 CHECK TABLE differs: #{actual.inspect}" unless actual == expected
  nil
end

def w105_select(binary : String, store : String, fields : Array(W105Field), key_range : Bool = false) : String
  projection = ["pk"] + fields.map { |field| "payload.#{field.name}" }
  predicate = key_range ? " WHERE pk >= 2 AND pk < 5" : ""
  w105_clickhouse(binary, store, "SELECT #{projection.join(", ")} FROM default.#{W105_TABLE}#{predicate} ORDER BY pk FORMAT RowBinary")
end

def w105_expect_typed_reader_red(part : String) : Nil
  begin
    reader = CrystalClick::WidePart.open_typed(part, "payload")
    reader.read_tuple_mark_range("payload", 0, reader.mark_count)
  rescue ex : CrystalClick::UnsupportedFormatError
    allowed = [
      "unsupported exact typed column",
      "compositional Tuple accessor requires named supported scalar leaves",
    ]
    raise "W105 typed-reader rejection is unrelated: #{ex.message}" unless allowed.includes?(ex.message)
    puts "EXPECTED RED W105: stock-qualified Nullable Tuple rejected by typed reader: #{ex.class}: #{ex.message}"
    return
  end
  raise "W105 RED failed: current reader admitted Nullable Tuple scalar leaves"
end

binary = ENV["CLICKHOUSE_BIN"]? || raise "set CLICKHOUSE_BIN to pinned ClickHouse 26.7.1.1315"
store = ENV["W105_STORE"]? || raise "set W105_STORE to a fresh temporary ClickHouse store directory"
unless store.starts_with?("/private/tmp/") || store.starts_with?("/tmp/")
  raise "refusing non-temporary W105_STORE path: #{store}"
end
if Dir.exists?(store)
  raise "W105_STORE must be empty: #{store}" unless Dir.empty?(store)
else
  Dir.mkdir_p(store)
end

version_output = IO::Memory.new
version_status = Process.run(binary, ["local", "--version"], output: version_output)
raise "could not read ClickHouse local version" unless version_status.success?
expected_version = "ClickHouse local version #{W105_STOCK_VERSION} (official build)."
raise "W105 requires #{expected_version}, got #{version_output.to_s.strip}" unless version_output.to_s.strip == expected_version
puts "Stock oracle: #{version_output.to_s.strip}"

fields = w105_fields
schema_type = "Tuple(#{fields.map { |field| "#{field.name} #{field.type_name}" }.join(", ")})"
raise "W105 schema fixture differs" unless schema_type == W105_TUPLE_TYPE
settings = w105_settings
w105_clickhouse(binary, store, "CREATE TABLE default.#{W105_TABLE} (pk UInt64, payload #{W105_TUPLE_TYPE}) ENGINE = MergeTree ORDER BY pk SETTINGS #{settings}")
w105_insert(binary, store, fields)
part = w105_part_path(binary, store)
schema = w105_schema(binary, store, fields)
w105_assert_layout(part, schema, fields)
w105_check_table(binary, store, part)

full_expected = w105_expected_rowbinary(fields, [0, 1, 2, 3, 4])
w105_assert_bytes(w105_select(binary, store, fields), full_expected, "W105 stock full RowBinary")
selected_expected = w105_expected_rowbinary(fields, [1, 2, 3])
w105_assert_bytes(w105_select(binary, store, fields, true), selected_expected, "W105 stock selected RowBinary")
puts "PASS W105 stock CHECK and independent full/selected RowBinary"

# This is the only typed-reader call and it occurs after every stock-side
# assertion above. Its failure is the requested baseline RED discriminator.
w105_expect_typed_reader_red(part)
puts "EXPECTED W105 RED: six Nullable scalar leaves passed stock qualification before reader rejection"
exit 1
