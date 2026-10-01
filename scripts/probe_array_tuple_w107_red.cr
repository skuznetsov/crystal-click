# W107 pinned-stock RED for Array(recursively named Tuple) composition.
# Expected stream bytes, marks and RowBinary are encoded from literal fixture
# carriers; no reader or writer output supplies the expected values.
# The ArraySizes stream is row-local here: pinned ISerialization.h:460 defaults
# position_independent_encoding to true, and
# MergeTreeDataPartWriterWide.cpp:560-578 does not override it. In that mode,
# SerializationArray.cpp:329-348 writes each row's element count, not the
# cumulative offsets kept below for slicing element-axis streams.
require "json"
require "file_utils"
require "../src/crystal_click"

W107_STOCK_VERSION       = "26.7.1.1315"
W107_TYPE                = "Array(Tuple(id UInt64, left Tuple(details Tuple(state Nullable(Enum8('neg' = -7, 'pos' = 7)), flag Nullable(Bool), note Nullable(String), event DateTime64(3, 'America/New_York'), amount Nullable(Decimal(9, 2))), fixed FixedString(3), count UInt32), right Tuple(details Tuple(state Nullable(Enum8('neg' = -7, 'pos' = 7)), note Nullable(String), event DateTime64(9, 'UTC')), fixed FixedString(3), count UInt64)))"
W107_SOURCE_TABLE        = "w107_array_tuple_source"
W107_ATTACH_TABLE        = "w107_array_tuple_attached"
W107_KEYS                = [10_u64, 20_u64, 30_u64, 40_u64, 50_u64, 60_u64, 70_u64, 80_u64, 90_u64]
W107_ROW_ELEMENT_INDICES = [
  [] of Int32,
  [] of Int32,
  [0_i32, 1_i32],
  [] of Int32,
  [] of Int32,
  [] of Int32,
  [2_i32],
  [3_i32],
  [] of Int32,
]
# ArraySizes bytes: per-outer-row element counts, including empty rows.
W107_ROW_SIZES = [0, 0, 2, 0, 0, 0, 1, 1, 0]
# Cumulative element offsets used to select child streams at outer boundaries.
W107_SIZE0           = [0, 0, 2, 2, 2, 2, 3, 4, 4]
W107_MARK_BOUNDARIES = [0, 2, 4, 6, 8, 9]
W107_MARK_ROWS       = [2_u64, 2_u64, 2_u64, 2_u64, 1_u64, 0_u64]
W107_ENUM_HIDDEN_RAW = [0x00_u8, 0xf9_u8, 0x07_u8, 0x00_u8]

class W107ByteMismatchError < Exception
end

struct W107Stream
  getter name : String
  getter fragments : Array(String)
  getter outer_axis : Bool

  def initialize(@name : String, @fragments : Array(String), @outer_axis : Bool)
  end
end

class W107Field
  getter name : String
  getter type_name : String
  getter base_type : String
  getter nullable : Bool
  getter payloads : Array(String)
  getter nulls : Array(Bool)

  def initialize(@name : String, @type_name : String, @base_type : String, @payloads : Array(String), nulls : Array(Bool)? = nil)
    @nulls = nulls || Array(Bool).new(payloads.size, false)
    raise "#{name}: expected four flattened Tuple elements" unless payloads.size == 4
    raise "#{name}: null mask length differs from payload length" unless @nulls.size == payloads.size
    @nullable = type_name.starts_with?("Nullable(")
    raise "#{name}: bare fixture has a NULL" if !nullable && @nulls.any?
  end

  def string? : Bool
    base_type == "String"
  end

  def stream_prefix : String
    "payload%2E#{name.gsub(".", "%2E")}"
  end

  def rowbinary_fragment(index : Int32) : String
    return "\x01" if nullable && nulls[index]
    payload = payloads[index]
    prefix = nullable ? "\x00" : ""
    prefix + (string? ? w107_varuint(payload.bytesize.to_u64) + payload : payload)
  end
end

def w107_byte(value : UInt8) : String
  String.new(Bytes[value])
end

def w107_unsigned_le(value : UInt64, width : Int32) : String
  raise "negative W107 byte width" if width < 0
  String.build do |output|
    width.times do |index|
      byte = index < 8 ? ((value >> (index * 8)) & 0xff_u64).to_u8 : 0_u8
      output.write_byte(byte)
    end
  end
end

def w107_signed_le(value : Int64, width : Int32) : String
  low_width = Math.min(width, 8)
  low = w107_unsigned_le(value.unsafe_as(UInt64), low_width)
  extension = value < 0 ? 0xff_u8 : 0_u8
  low + String.new(Bytes.new(width - low_width, extension))
end

def w107_varuint(value : UInt64) : String
  String.build do |output|
    remaining = value
    while remaining >= 0x80_u64
      output.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
      remaining >>= 7
    end
    output.write_byte(remaining.to_u8)
  end
end

def w107_fields : Array(W107Field)
  enum8 = "Nullable(Enum8('neg' = -7, 'pos' = 7))"
  [
    W107Field.new("id", "UInt64", "UInt64", [
      w107_unsigned_le(0_u64, 8), w107_unsigned_le(UInt64::MAX, 8),
      w107_unsigned_le(7_u64, 8), w107_unsigned_le(2_u64, 8),
    ]),
    W107Field.new("left.details.state", enum8, "Enum8('neg' = -7, 'pos' = 7)", [
      w107_signed_le(0_i64, 1), w107_signed_le(-7_i64, 1),
      w107_signed_le(7_i64, 1), w107_signed_le(0_i64, 1),
    ], [true, false, false, true]),
    W107Field.new("left.details.flag", "Nullable(Bool)", "Bool", [
      w107_byte(0_u8), w107_byte(0_u8), w107_byte(1_u8), w107_byte(0_u8),
    ], [true, false, false, true]),
    W107Field.new("left.details.note", "Nullable(String)", "String", [
      "", "", "a\u0000b", "tail",
    ], [true, false, false, false]),
    W107Field.new("left.details.event", "DateTime64(3, 'America/New_York')", "DateTime64", [
      w107_signed_le(0_i64, 8), w107_signed_le(-1_i64, 8),
      w107_signed_le(1_615_705_200_001_i64, 8), w107_signed_le(Int64::MAX, 8),
    ]),
    W107Field.new("left.details.amount", "Nullable(Decimal(9, 2))", "Decimal(9, 2)", [
      w107_signed_le(0_i64, 4), w107_signed_le(100_i64, 4),
      w107_signed_le(-22_i64, 4), w107_signed_le(0_i64, 4),
    ], [true, false, false, true]),
    W107Field.new("left.fixed", "FixedString(3)", "FixedString(3)", [
      "\0\0\0", "abc", "xyz", "end",
    ]),
    W107Field.new("left.count", "UInt32", "UInt32", [
      w107_unsigned_le(0_u64, 4), w107_unsigned_le(UInt32::MAX.to_u64, 4),
      w107_unsigned_le(7_u64, 4), w107_unsigned_le(0_u64, 4),
    ]),
    W107Field.new("right.details.state", enum8, "Enum8('neg' = -7, 'pos' = 7)", [
      w107_signed_le(0_i64, 1), w107_signed_le(7_i64, 1),
      w107_signed_le(-7_i64, 1), w107_signed_le(0_i64, 1),
    ], [true, false, false, true]),
    W107Field.new("right.details.note", "Nullable(String)", "String", [
      "", "", "right", "",
    ], [false, true, false, false]),
    W107Field.new("right.details.event", "DateTime64(9, 'UTC')", "DateTime64", [
      w107_signed_le(Int64::MIN, 8), w107_signed_le(-1_i64, 8),
      w107_signed_le(1_636_264_800_000_000_001_i64, 8), w107_signed_le(Int64::MAX, 8),
    ]),
    W107Field.new("right.fixed", "FixedString(3)", "FixedString(3)", [
      "abc", "\0\0\0", "def", "xyz",
    ]),
    W107Field.new("right.count", "UInt64", "UInt64", [
      w107_unsigned_le(UInt64::MAX, 8), w107_unsigned_le(0_u64, 8),
      w107_unsigned_le(0_u64, 8), w107_unsigned_le(10_u64, 8),
    ]),
  ]
end

def w107_streams : Array(W107Stream)
  fields = w107_fields
  streams = [] of W107Stream
  streams << W107Stream.new("pk", W107_KEYS.map { |key| w107_unsigned_le(key, 8) }, true)
  streams << W107Stream.new("payload.size0", W107_ROW_SIZES.map { |size| w107_unsigned_le(size.to_u64, 8) }, true)
  fields.each do |field|
    prefix = field.stream_prefix
    if field.nullable
      streams << W107Stream.new("#{prefix}.null", field.nulls.map { |is_null| w107_byte(is_null ? 1_u8 : 0_u8) }, false)
    end
    if field.string?
      streams << W107Stream.new("#{prefix}.size", field.payloads.map { |value| w107_unsigned_le(value.bytesize.to_u64, 8) }, false)
    end
    streams << W107Stream.new(prefix, field.payloads, false)
  end
  streams
end

def w107_expected_columns : Array(String)
  [
    "columns format version: 1",
    "2 columns:",
    "\u0060pk\u0060 UInt64",
    "\u0060payload\u0060 #{W107_TYPE}",
  ]
end

def w107_expected_substreams : String
  streams = w107_streams
  payload_names = streams[1..].map(&.name)
  lines = [
    "columns substreams version: 1",
    "2 columns:",
    "1 substreams for column \u0060pk\u0060:",
    "\tpk",
    "#{payload_names.size} substreams for column \u0060payload\u0060:",
  ]
  payload_names.each { |name| lines << "\t#{name}" }
  lines.join("\n") + "\n"
end

def w107_expected_marks(stream : W107Stream) : Array({UInt64, UInt64, UInt64})
  W107_MARK_BOUNDARIES.map_with_index do |boundary, index|
    consumed = if stream.outer_axis
                 boundary
               elsif boundary == 0
                 0
               else
                 W107_SIZE0[boundary - 1]
               end
    decompressed = stream.fragments[0, consumed].sum(&.bytesize).to_u64
    {0_u64, decompressed, W107_MARK_ROWS[index]}
  end
end

def w107_actual_marks(part : String, stream : String) : Array({UInt64, UInt64, UInt64})
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  bytes = File.read(path).to_slice
  mark_size = CrystalClick::WidePart::MARK_SIZE
  raise "#{stream}: truncated .mrk2 records" unless bytes.size % mark_size == 0
  Array({UInt64, UInt64, UInt64}).new(bytes.size // mark_size) do |index|
    offset = index * mark_size
    fields = Array(UInt64).new(3) do |field|
      start = offset + field * 8
      8.times.reduce(0_u64) { |value, byte| value | (bytes[start + byte].to_u64 << (byte * 8)) }
    end
    {fields[0], fields[1], fields[2]}
  end
end

def w107_assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual == expected
  limit = Math.min(actual.bytesize, expected.bytesize)
  difference = 0
  while difference < limit && actual.to_slice[difference] == expected.to_slice[difference]
    difference += 1
  end
  got = difference < actual.bytesize ? actual.to_slice[difference].to_s(16).rjust(2, '0') : "<eof>"
  wanted = difference < expected.bytesize ? expected.to_slice[difference].to_s(16).rjust(2, '0') : "<eof>"
  raise W107ByteMismatchError.new("#{label}: expected #{expected.bytesize} bytes, got #{actual.bytesize}; first difference #{difference}: expected #{wanted}, got #{got}")
end

def w107_seeded_comparator_control(actual : String, expected : String, label : String) : Nil
  raise "#{label}: baseline bytes did not match" unless actual == expected
  raise "#{label}: cannot seed an empty stream" if expected.empty?
  damaged = String.new(expected.to_slice)
  damaged.to_unsafe[0] = damaged.to_slice[0] ^ 0x01_u8
  begin
    w107_assert_bytes(actual, damaged, "#{label} seeded mismatch")
    raise "#{label}: comparator accepted a seeded mismatch"
  rescue ex : W107ByteMismatchError
  end
  puts "PASS #{label}: comparator rejects seeded one-byte defect"
end

def w107_run(binary : String, store : String, query : String, input : IO? = nil) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = if input
             Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: error)
           else
             Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
           end
  raise "ClickHouse query failed: #{error}\n#{query}" unless status.success?
  output.to_s
end

def w107_settings : String
  "index_granularity = 2, index_granularity_bytes = 10485760, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, ratio_of_defaults_for_sparse_serialization = 0.9375, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, default_compression_codec = 'LZ4'"
end

def w107_create_table(binary : String, store : String, table : String) : Nil
  w107_run(binary, store, "CREATE TABLE default.#{table} (pk UInt64, payload #{W107_TYPE}) ENGINE = MergeTree ORDER BY pk SETTINGS #{w107_settings}")
  nil
end

def w107_part_path(binary : String, store : String, table : String) : String
  rows = w107_run(binary, store, "SELECT path, part_type, rows FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines.map(&.strip).reject(&.empty?)
  raise "#{table}: expected exactly one nine-row Wide part, got #{rows.inspect}" unless rows.size == 1
  columns = rows[0].split('\t')
  raise "#{table}: malformed system.parts row #{rows[0].inspect}" unless columns.size == 3 && columns[1] == "Wide" && columns[2] == W107_KEYS.size.to_s
  columns[0]
end

def w107_assert_schema(binary : String, store : String, table : String) : Nil
  actual = w107_run(binary, store, "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw").lines.map(&.strip)
  expected = ["pk UInt64", "payload #{W107_TYPE}"]
  raise "#{table}: exact system.columns declarations differ: #{actual.inspect}" unless actual == expected
end

def w107_assert_json_keys(row : Hash(String, JSON::Any), expected : Array(String), label : String) : Nil
  actual = row.keys.sort
  wanted = expected.sort
  raise "#{label}: serializer keys differ; expected #{wanted.inspect}, got #{actual.inspect}" unless actual == wanted
end

def w107_assert_serialization(part : String, label : String) : Nil
  info = JSON.parse(File.read(File.join(part, "serialization.json"))).as_h
  puts "OBSERVED #{label} serialization.json=#{info.to_json}"
  expected_keys = ["columns", "propagate_types_serialization_versions_to_nested_types", "types_serialization_versions", "version"].sort
  raise "#{label}: serialization.json envelope differs: #{info.keys.sort.inspect}" unless info.keys.sort == expected_keys
  raise "#{label}: serialization version differs" unless info["version"]?.try(&.as_i) == 1
  raise "#{label}: nested serialization-version propagation differs" unless info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  versions = info["types_serialization_versions"]?.try(&.as_h) || raise "#{label}: type-version map missing"
  raise "#{label}: type-version map differs: #{versions.to_json}" unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1

  records = info["columns"]?.try(&.as_a) || raise "#{label}: serialization columns missing"
  names = records.map { |entry| entry.as_h["name"]?.try(&.as_s) || raise "#{label}: top-level serializer name missing" }
  # Pinned 26.7 uses the generic Array serializer, which is not sparse
  # eligible and has no recursive Tuple statistics record. The sparse-capable
  # primary key is the only serialized Default record for this profile.
  raise "#{label}: generic Array metadata roots differ: #{names.inspect}" unless names == ["pk"]
  key = records[0].as_h
  w107_assert_json_keys(key, ["kind", "name", "num_defaults", "num_rows"], "#{label} PK statistics")
  raise "#{label}: primary-key serializer kind differs" unless key["kind"]?.try(&.as_s) == "Default"
  raise "#{label}: primary-key row/default counters differ" unless key["num_rows"]?.try(&.as_i) == W107_KEYS.size.to_i64 && key["num_defaults"]?.try(&.as_i) == 0_i64
  nil
end

def w107_assert_layout(part : String, label : String) : Nil
  actual_columns = File.read(File.join(part, "columns.txt")).lines.map(&.strip)
  raise "#{label}: exact columns.txt declaration differs: #{actual_columns.inspect}" unless actual_columns == w107_expected_columns
  actual_substreams = File.read(File.join(part, "columns_substreams.txt"))
  expected_substreams = w107_expected_substreams
  raise "#{label}: exact columns_substreams.txt differs:\nexpected:\n#{expected_substreams}actual:\n#{actual_substreams}" unless actual_substreams == expected_substreams
  raise "#{label}: codec differs" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"
  raise "#{label}: metadata version differs" unless File.read(File.join(part, "metadata_version.txt")) == "0"
  raise "#{label}: count.txt differs" unless File.read(File.join(part, "count.txt")) == W107_KEYS.size.to_s

  streams = w107_streams
  expected_bins = streams.map { |stream| "#{CrystalClick::StreamName.hash(stream.name)}.bin" }.sort
  expected_marks = streams.map { |stream| "#{CrystalClick::StreamName.hash(stream.name)}.mrk2" }.sort
  entries = Dir.children(part)
  actual_bins = entries.select(&.ends_with?(".bin")).sort
  actual_marks = entries.select(&.ends_with?(".mrk2")).sort
  raise "#{label}: exact .bin stream inventory differs: #{actual_bins.inspect}" unless actual_bins == expected_bins
  raise "#{label}: exact .mrk2 stream inventory differs: #{actual_marks.inspect}" unless actual_marks == expected_marks

  streams.each do |stream|
    expected_raw = stream.fragments.join
    encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream.name)}.bin")).to_slice
    actual_raw = String.new(CrystalClick::CompressedBlock.decode_all(encoded))
    w107_assert_bytes(actual_raw, expected_raw, "#{label} #{stream.name} physical bytes")
    wanted_marks = w107_expected_marks(stream)
    actual_marks = w107_actual_marks(part, stream.name)
    raise "#{label} #{stream.name}: exact marks differ; expected #{wanted_marks.inspect}, got #{actual_marks.inspect}" unless actual_marks == wanted_marks

    if stream.name == "payload%2Eleft%2Edetails%2Estate"
      observed = actual_raw.to_slice.to_a
      puts "OBSERVED #{label} left Nullable(Enum8) raw=#{observed.inspect}"
      raise "#{label}: RowBinary NULL-route Enum hidden carrier differs" unless observed == W107_ENUM_HIDDEN_RAW
      w107_seeded_comparator_control(actual_raw, expected_raw, "#{label} nested Enum stream")
    end
  end
  w107_assert_serialization(part, label)
  puts "PASS #{label}: exact recursive Array/Tuple declarations, #{streams.size} stream layouts, literal bytes, ragged-axis marks and serializer metadata"
  nil
end

def w107_append_rowbinary(io : IO, indexes : Array(Int32)) : Nil
  indexes.each do |element_index|
    w107_fields.each { |field| io << field.rowbinary_fragment(element_index) }
  end
end

def w107_expected_rowbinary(row_indexes : Array(Int32)) : String
  String.build do |output|
    row_indexes.each do |row_index|
      output << w107_unsigned_le(W107_KEYS[row_index], 8)
      elements = W107_ROW_ELEMENT_INDICES[row_index]
      output << w107_varuint(elements.size.to_u64)
      w107_append_rowbinary(output, elements)
    end
  end
end

def w107_insert(binary : String, store : String, table : String) : Nil
  input = IO::Memory.new(w107_expected_rowbinary((0...W107_KEYS.size).map(&.to_i32)).to_slice)
  w107_run(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", input)
  nil
end

def w107_check_table(binary : String, store : String, table : String, part : String) : Nil
  actual = w107_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  expected = "#{File.basename(part.chomp("/"))}\t1"
  raise "#{table}: CHECK TABLE differs: #{actual.inspect}" unless actual == expected
end

def w107_selected_query(binary : String, store : String, table : String, selected : Bool = false) : String
  predicate = selected ? " WHERE pk >= 30 AND pk < 80" : ""
  w107_run(binary, store, "SELECT pk, payload FROM default.#{table}#{predicate} ORDER BY pk FORMAT RowBinary")
end

def w107_assert_rowbinary(binary : String, store : String, table : String, label : String) : Nil
  full = w107_selected_query(binary, store, table)
  w107_assert_bytes(full, w107_expected_rowbinary((0...W107_KEYS.size).map(&.to_i32)), "#{label} full RowBinary")
  selected = w107_selected_query(binary, store, table, true)
  w107_assert_bytes(selected, w107_expected_rowbinary([2_i32, 3_i32, 4_i32, 5_i32, 6_i32]), "#{label} selected RowBinary")
  puts "PASS #{label}: independently encoded full/PK-selected Array(Tuple) RowBinary"
  nil
end

def w107_attach(binary : String, store : String, source_part : String) : String
  w107_create_table(binary, store, W107_ATTACH_TABLE)
  data_path = w107_run(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{W107_ATTACH_TABLE}' FORMAT TSVRaw").strip
  raise "W107 ATTACH target has no data path" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(source_part, File.join(detached, "all_1_1_0"))
  w107_run(binary, store, "ALTER TABLE default.#{W107_ATTACH_TABLE} ATTACH PART 'all_1_1_0'")
  w107_part_path(binary, store, W107_ATTACH_TABLE)
end

def w107_expect_reader_red(part : String) : Nil
  begin
    CrystalClick::WidePart.open_typed(part, "payload")
  rescue ex : CrystalClick::UnsupportedFormatError
    raise "W107 reader rejected for an unrelated reason: #{ex.message}" unless ex.message == "unsupported exact typed column"
    puts "EXPECTED RED W107: independently stock-qualified Array(Tuple) rejected by predecessor typed-reader gate"
    return
  end
  raise "W107 RED failed: current typed reader admitted the Array(Tuple) declaration"
end

binary = ENV["CLICKHOUSE_BIN"]? || raise "set CLICKHOUSE_BIN to pinned ClickHouse 26.7.1.1315"
store = ENV["W107_STORE"]? || raise "set W107_STORE to a fresh temporary ClickHouse store directory"
unless store.starts_with?("/private/tmp/") || store.starts_with?("/tmp/")
  raise "refusing non-temporary W107_STORE path: #{store}"
end
if Dir.exists?(store)
  raise "W107_STORE must be empty: #{store}" unless Dir.empty?(store)
else
  Dir.mkdir_p(store)
end

version_output = IO::Memory.new
version_status = Process.run(binary, ["local", "--version"], output: version_output)
raise "could not read stock ClickHouse version" unless version_status.success?
expected_version = "ClickHouse local version #{W107_STOCK_VERSION} (official build)."
raise "W107 requires #{expected_version}, got #{version_output.to_s.strip}" unless version_output.to_s.strip == expected_version
puts "Stock oracle: #{version_output.to_s.strip}"
raise "W107 fixture declaration differs" unless W107_TYPE.starts_with?("Array(Tuple(id UInt64, left Tuple(")

w107_create_table(binary, store, W107_SOURCE_TABLE)
w107_insert(binary, store, W107_SOURCE_TABLE)
source_part = w107_part_path(binary, store, W107_SOURCE_TABLE)
w107_assert_schema(binary, store, W107_SOURCE_TABLE)
w107_assert_layout(source_part, "W107 stock source")
w107_check_table(binary, store, W107_SOURCE_TABLE, source_part)
w107_assert_rowbinary(binary, store, W107_SOURCE_TABLE, "W107 stock source")

attached_part = w107_attach(binary, store, source_part)
w107_assert_schema(binary, store, W107_ATTACH_TABLE)
w107_assert_layout(attached_part, "W107 stock ATTACH")
w107_check_table(binary, store, W107_ATTACH_TABLE, attached_part)
w107_assert_rowbinary(binary, store, W107_ATTACH_TABLE, "W107 stock ATTACH")

# The existing admission failure counts as feature RED only after all
# independent source and attached physical/logical certificates above pass.
w107_expect_reader_red(attached_part)
puts "EXPECTED W107 RED: source + ATTACH exact metadata, bytes, marks, CHECK, and RowBinary qualified before typed rejection"
exit 1
