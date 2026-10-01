# W108 independent ClickHouse stock RED for Map(K, recursively named Tuple).
# Expected bytes, marks and RowBinary come only from this literal fixture.
require "json"
require "file_utils"
require "../src/crystal_click"

W108_STOCK_VERSION = "26.7.1.1315"
W108_VALUE_TYPE    = "Tuple(left Tuple(code UInt64, note Nullable(String)), right Tuple(code DateTime64(9, 'America/New_York'), state Nullable(Enum8('negative' = -7, 'positive' = 4))))"
# Source anchor: Oct 1 ClickHouse b762d6d7, DataTypeMap.cpp:130-140 wraps
# keys and values in TupleElement names; ISerialization.cpp:337-348 escapes
# each TupleElement edge independently as %2E in the persisted stream path.
# The list below is an independent prediction to qualify against pinned stock.
W108_SOURCE           = "w108_map_tuple_source"
W108_ATTACHED         = "w108_map_tuple_attached"
W108_EMPTY_SOURCE     = "w108_map_tuple_empty_source"
W108_EMPTY_ATTACHED   = "w108_map_tuple_empty_attached"
W108_MAP_SETTINGS     = ["map_serialization_version", "map_serialization_version_for_zero_level_parts"]
W108_SETTINGS         = "index_granularity = 2, index_granularity_bytes = 10485760, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, ratio_of_defaults_for_sparse_serialization = 0.9375, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, default_compression_codec = 'LZ4'"
W108_ROWSIZES         = [0_u64, 0_u64, 3_u64, 0_u64, 0_u64, 0_u64, 2_u64, 1_u64, 0_u64]
W108_KEYS             = [10_u64, 20_u64, 30_u64, 40_u64, 50_u64, 60_u64, 70_u64, 80_u64, 90_u64]
W108_BOUNDARIES       = [0, 2, 4, 6, 8, 9]
W108_MARKROWS         = [2_u64, 2_u64, 2_u64, 2_u64, 1_u64, 0_u64]
W108_EMPTY_KEYS       = [101_u64, 102_u64, 103_u64, 104_u64, 105_u64]
W108_EMPTY_SIZES      = [0_u64, 0_u64, 0_u64, 0_u64, 0_u64]
W108_EMPTY_BOUNDARIES = [0, 2, 4, 5]
W108_EMPTY_MARKROWS   = [2_u64, 2_u64, 1_u64, 0_u64]

class W108ByteMismatchError < Exception
end

struct W108Entry
  getter key : String | UInt64
  getter left_code : UInt64
  getter note : String?
  getter ticks : Int64
  getter state : Int8?

  def initialize(@key : String | UInt64, @left_code : UInt64, @note : String?, @ticks : Int64, @state : Int8?)
  end
end

struct W108Profile
  getter name : String
  getter table : String
  getter attached_table : String
  getter map_key_type : String
  getter type_name : String
  getter keys : Array(UInt64)
  getter rows : Array(Array(W108Entry))
  getter row_sizes : Array(UInt64)
  getter boundaries : Array(Int32)
  getter mark_rows : Array(UInt64)
  getter selected_range : Range(UInt64, UInt64)

  def initialize(@name : String, @table : String, @attached_table : String, @map_key_type : String, @keys : Array(UInt64), @rows : Array(Array(W108Entry)), @row_sizes : Array(UInt64), @boundaries : Array(Int32), @mark_rows : Array(UInt64), @selected_range : Range(UInt64, UInt64))
    raise "#{name}: unsupported fixture Map key type #{map_key_type}" unless map_key_type == "String" || map_key_type == "UInt64"
    @type_name = "Map(#{map_key_type}, #{W108_VALUE_TYPE})"
    raise "#{name}: key/row/size vectors differ" unless keys.size == rows.size && rows.size == row_sizes.size
    raise "#{name}: fixture sizes differ from entry rows" unless rows.map(&.size.to_u64) == row_sizes
    raise "#{name}: mark schedule differs" unless boundaries.size == mark_rows.size
  end
end

W108_MIXED_ROWS = [
  [] of W108Entry,
  [] of W108Entry,
  [
    W108Entry.new("dup", 11_u64, nil, -1_i64, nil),
    W108Entry.new("dup", 12_u64, "", 0_i64, -7_i8),
    W108Entry.new("", 13_u64, "a\0b", Int64::MIN, 4_i8),
  ],
  [] of W108Entry,
  [] of W108Entry,
  [] of W108Entry,
  [
    W108Entry.new("\0k", UInt64::MAX, "tail", Int64::MAX, nil),
    W108Entry.new("x", 42_u64, nil, 1_i64, 4_i8),
  ],
  [W108Entry.new("dup", 0_u64, "end", -1_000_i64, -7_i8)],
  [] of W108Entry,
]
W108_MIXED      = W108Profile.new("mixed-string", W108_SOURCE, W108_ATTACHED, "String", W108_KEYS, W108_MIXED_ROWS, W108_ROWSIZES, W108_BOUNDARIES, W108_MARKROWS, 30_u64...80_u64)
W108_EMPTY_ROWS = Array(Array(W108Entry)).new(W108_EMPTY_KEYS.size) { [] of W108Entry }
W108_EMPTY      = W108Profile.new("all-empty-string", W108_EMPTY_SOURCE, W108_EMPTY_ATTACHED, "String", W108_EMPTY_KEYS, W108_EMPTY_ROWS, W108_EMPTY_SIZES, W108_EMPTY_BOUNDARIES, W108_EMPTY_MARKROWS, 102_u64...105_u64)

W108_U64_MIXED_ROWS = [
  [] of W108Entry,
  [] of W108Entry,
  [
    W108Entry.new(0_u64, 11_u64, nil, -1_i64, nil),
    W108Entry.new(0_u64, 12_u64, "", 0_i64, -7_i8),
    W108Entry.new(UInt64::MAX, 13_u64, "a\0b", Int64::MIN, 4_i8),
  ],
  [] of W108Entry,
  [] of W108Entry,
  [] of W108Entry,
  [
    W108Entry.new(UInt64::MIN, UInt64::MAX, "tail", Int64::MAX, nil),
    W108Entry.new(42_u64, 42_u64, nil, 1_i64, 4_i8),
  ],
  [W108Entry.new(UInt64::MAX, 0_u64, "end", -1_000_i64, -7_i8)],
  [] of W108Entry,
]
W108_U64_MIXED = W108Profile.new("mixed-uint64", "w108_map_tuple_u64_source", "w108_map_tuple_u64_attached", "UInt64", W108_KEYS, W108_U64_MIXED_ROWS, W108_ROWSIZES, W108_BOUNDARIES, W108_MARKROWS, 30_u64...80_u64)
W108_U64_EMPTY = W108Profile.new("all-empty-uint64", "w108_map_tuple_u64_empty_source", "w108_map_tuple_u64_empty_attached", "UInt64", W108_EMPTY_KEYS, W108_EMPTY_ROWS, W108_EMPTY_SIZES, W108_EMPTY_BOUNDARIES, W108_EMPTY_MARKROWS, 102_u64...105_u64)

struct W108Stream
  getter name : String
  getter fragments : Array(String)
  getter outer_axis : Bool

  def initialize(@name : String, @fragments : Array(String), @outer_axis : Bool)
  end
end

def w108_byte(value : UInt8) : String
  String.new(Bytes[value])
end

def w108_unsigned_le(value : UInt64, width : Int32) : String
  String.build do |output|
    width.times { |index| output.write_byte(index < 8 ? ((value >> (index * 8)) & 0xff_u64).to_u8 : 0_u8) }
  end
end

def w108_signed_le(value : Int64, width : Int32) : String
  low_width = Math.min(width, 8)
  low = w108_unsigned_le(value.unsafe_as(UInt64), low_width)
  low + String.new(Bytes.new(width - low_width, value < 0 ? 0xff_u8 : 0_u8))
end

def w108_varuint(value : UInt64) : String
  String.build do |output|
    remaining = value
    while remaining >= 0x80_u64
      output.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
      remaining >>= 7
    end
    output.write_byte(remaining.to_u8)
  end
end

def w108_entries(profile : W108Profile) : Array(W108Entry)
  profile.rows.flatten
end

def w108_streams(profile : W108Profile) : Array(W108Stream)
  entries = w108_entries(profile)
  key_streams = case profile.map_key_type
                when "String"
                  [
                    W108Stream.new("payload%2Ekeys.size", entries.map { |entry| w108_unsigned_le(entry.key.as(String).bytesize.to_u64, 8) }, false),
                    W108Stream.new("payload%2Ekeys", entries.map { |entry| entry.key.as(String) }, false),
                  ]
                when "UInt64"
                  [W108Stream.new("payload%2Ekeys", entries.map { |entry| w108_unsigned_le(entry.key.as(UInt64), 8) }, false)]
                else
                  raise "unsupported independently encoded Map key #{profile.map_key_type}"
                end
  streams = [
    W108Stream.new("pk", profile.keys.map { |key| w108_unsigned_le(key, 8) }, true),
    W108Stream.new("payload.size0", profile.row_sizes.map { |size| w108_unsigned_le(size, 8) }, true),
  ]
  streams.concat(key_streams)
  streams.concat([
    W108Stream.new("payload%2Evalues%2Eleft%2Ecode", entries.map { |entry| w108_unsigned_le(entry.left_code, 8) }, false),
    W108Stream.new("payload%2Evalues%2Eleft%2Enote.null", entries.map { |entry| w108_byte(entry.note.nil? ? 1_u8 : 0_u8) }, false),
    W108Stream.new("payload%2Evalues%2Eleft%2Enote.size", entries.map { |entry| w108_unsigned_le((entry.note.try(&.bytesize) || 0).to_u64, 8) }, false),
    W108Stream.new("payload%2Evalues%2Eleft%2Enote", entries.map { |entry| entry.note || "" }, false),
    W108Stream.new("payload%2Evalues%2Eright%2Ecode", entries.map { |entry| w108_signed_le(entry.ticks, 8) }, false),
    W108Stream.new("payload%2Evalues%2Eright%2Estate.null", entries.map { |entry| w108_byte(entry.state.nil? ? 1_u8 : 0_u8) }, false),
    W108Stream.new("payload%2Evalues%2Eright%2Estate", entries.map { |entry| w108_byte(entry.state.try(&.unsafe_as(UInt8)) || 0_u8) }, false),
  ])
  streams
end

def w108_columns(profile : W108Profile) : Array(String)
  ["columns format version: 1", "2 columns:", "`pk` UInt64", "`payload` #{profile.type_name}"]
end

def w108_substreams(profile : W108Profile) : String
  names = w108_streams(profile)[1..].map(&.name)
  lines = ["columns substreams version: 1", "2 columns:", "1 substreams for column `pk`:", "\tpk", "#{names.size} substreams for column `payload`:"]
  names.each { |name| lines << "\t#{name}" }
  lines.join("\n") + "\n"
end

def w108_expected_marks(profile : W108Profile, stream : W108Stream) : Array({UInt64, UInt64, UInt64})
  profile.boundaries.map_with_index do |boundary, index|
    consumed = stream.outer_axis ? boundary : profile.row_sizes[0, boundary].sum(&.to_i32)
    decompressed = stream.fragments[0, consumed].sum(&.bytesize).to_u64
    {0_u64, decompressed, profile.mark_rows[index]}
  end
end

def w108_actual_marks(part : String, name : String) : Array({UInt64, UInt64, UInt64})
  bytes = File.read(File.join(part, "#{CrystalClick::StreamName.hash(name)}.mrk2")).to_slice
  size = CrystalClick::WidePart::MARK_SIZE
  raise "#{name}: partial .mrk2 record" unless bytes.size % size == 0
  Array({UInt64, UInt64, UInt64}).new(bytes.size // size) do |index|
    offset = index * size
    fields = Array(UInt64).new(3) do |field|
      start = offset + field * 8
      8.times.reduce(0_u64) { |value, byte| value | (bytes[start + byte].to_u64 << (byte * 8)) }
    end
    {fields[0], fields[1], fields[2]}
  end
end

def w108_assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual == expected
  limit = Math.min(actual.bytesize, expected.bytesize)
  difference = 0
  while difference < limit && actual.to_slice[difference] == expected.to_slice[difference]
    difference += 1
  end
  got = difference < actual.bytesize ? actual.to_slice[difference].to_s(16).rjust(2, '0') : "<eof>"
  wanted = difference < expected.bytesize ? expected.to_slice[difference].to_s(16).rjust(2, '0') : "<eof>"
  raise W108ByteMismatchError.new("#{label}: expected #{expected.bytesize} bytes, got #{actual.bytesize}; first diff #{difference}: expected #{wanted}, got #{got}")
end

def w108_seeded_comparator(actual : String, expected : String, label : String) : Nil
  raise "#{label}: fixture did not match expected bytes" unless actual == expected
  raise "#{label}: cannot seed mismatch on empty bytes" if expected.empty?
  damaged = String.new(expected.to_slice)
  damaged.to_unsafe[0] = damaged.to_slice[0] ^ 0x01_u8
  begin
    w108_assert_bytes(actual, damaged, label)
    raise "#{label}: comparator accepted seeded byte defect"
  rescue ex : W108ByteMismatchError
  end
  puts "PASS #{label}: seeded wrong-byte comparator control"
end

def w108_run(binary : String, store : String, query : String, input : IO? = nil) : String
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

def w108_expect_failure(binary : String, store : String, query : String) : String
  error = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], output: IO::Memory.new, error: error)
  raise "query unexpectedly succeeded: #{query}" if status.success?
  error.to_s
end

def w108_key_types : Array(String)
  leaves = %w(Int8 UInt8 Int16 UInt16 Int32 UInt32 Int64 UInt64 Int128 UInt128 Int256 UInt256 Float32 Float64 BFloat16 Bool String UUID IPv4 IPv6 Date Date32 DateTime Time)
  10.times do |precision|
    leaves << "DateTime64(#{precision})"
    leaves << "Time64(#{precision})"
  end
  leaves.concat([
    "DateTime('UTC')", "DateTime64(9, 'America/New_York')", "FixedString(5)",
    "Enum8('negative' = -7, 'positive' = 4)", "Enum16('negative' = -300, 'positive' = 400)",
    "Decimal(9, 2)", "Decimal(18, 3)", "Decimal(38, 4)", "Decimal(76, 5)",
  ])
end

def w108_key_census(binary : String, store : String) : Nil
  leaves = w108_key_types
  raise "W105 scalar descriptor census changed: #{leaves.size}, expected 53" unless leaves.size == 53
  table = "w108_map_key_census"
  columns = leaves.map_with_index { |leaf, index| "k#{index.to_s.rjust(2, '0')} Map(#{leaf}, UInt8)" }
  w108_run(binary, store, "CREATE TABLE default.#{table} (#{columns.join(", ")}) ENGINE = Memory")
  observed = w108_run(binary, store, "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw").lines.map(&.strip)
  expected = leaves.map_with_index { |leaf, index| "k#{index.to_s.rjust(2, '0')} Map(#{leaf}, UInt8)" }
  raise "pinned stock did not admit the exact 53 bare scalar Map key declarations: #{observed.inspect}" unless observed == expected
  puts "PASS pinned stock key census: all #{observed.size}/53 exact bare W105 scalar declarations"

  error = w108_expect_failure(binary, store, "CREATE TABLE default.w108_nullable_map_key (m Map(Nullable(UInt64), UInt8)) ENGINE = Memory")
  raise "Nullable Map-key rejection appears unrelated to key type: #{error}" unless error.includes?("Nullable") || error.includes?("key")
  puts "PASS pinned stock rejects Nullable Map key"
  nil
end

def w108_basic_map_settings(binary : String, store : String) : String
  query = "SELECT name || '\\t' || value FROM system.merge_tree_settings WHERE name IN ('map_serialization_version', 'map_serialization_version_for_zero_level_parts') ORDER BY name FORMAT TSVRaw"
  rows = w108_run(binary, store, query).lines.map(&.strip).reject(&.empty?)
  if rows.empty?
    puts "OBSERVED pinned runtime does not expose Map serialization settings; exact BASIC stream topology will be the executable profile check"
    return ""
  end
  pairs = rows.map(&.split('\t', 2))
  names = pairs.map(&.[0]).sort
  raise "only one of the two Map serialization settings is exposed: #{pairs.inspect}" unless names == W108_MAP_SETTINGS.sort
  pairs.each { |pair| raise "Map setting is not BASIC: #{pair.inspect}" unless pair.size == 2 && pair[1].downcase == "basic" }
  puts "PASS pinned runtime explicitly reports BASIC Map settings: #{pairs.inspect}"
  ", map_serialization_version = 'basic', map_serialization_version_for_zero_level_parts = 'basic'"
end

def w108_create_table(binary : String, store : String, table : String, type_name : String, map_settings : String) : Nil
  w108_run(binary, store, "CREATE TABLE default.#{table} (pk UInt64, payload #{type_name}) ENGINE = MergeTree ORDER BY pk SETTINGS #{W108_SETTINGS}#{map_settings}")
  nil
end

def w108_part_path(binary : String, store : String, table : String, row_count : Int32) : String
  rows = w108_run(binary, store, "SELECT path, part_type, rows FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines.map(&.strip).reject(&.empty?)
  raise "#{table}: expected one #{row_count}-row Wide part; got #{rows.inspect}" unless rows.size == 1
  columns = rows[0].split('\t')
  raise "#{table}: malformed/non-Wide system.parts row #{rows[0].inspect}" unless columns.size == 3 && columns[1] == "Wide" && columns[2] == row_count.to_s
  columns[0]
end

def w108_assert_schema(binary : String, store : String, profile : W108Profile, table : String) : Nil
  actual = w108_run(binary, store, "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw").lines.map(&.strip)
  expected = ["pk UInt64", "payload #{profile.type_name}"]
  raise "#{table}: exact declarations differ; expected #{expected.inspect}, got #{actual.inspect}" unless actual == expected
end

def w108_raw_stream(part : String, name : String) : String
  encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(name)}.bin")).to_slice
  return "" if encoded.empty?
  String.new(CrystalClick::CompressedBlock.decode_all(encoded))
end

def w108_assert_metadata(part : String, label : String, row_count : Int32) : Nil
  actual = File.read(File.join(part, "serialization.json")).strip
  puts "OBSERVED #{label} serialization.json=#{actual}"
  # Source-side version prediction: SerializationInfo.cpp:592-596 omits the
  # BASIC Map version and records the String-v1 setting. The exact
  # envelope and PK-only Default record remain pinned-stock assertions here.
  info = JSON.parse(actual).as_h
  expected_keys = ["columns", "propagate_types_serialization_versions_to_nested_types", "types_serialization_versions", "version"].sort
  raise "#{label}: exact serialization envelope differs" unless info.keys.sort == expected_keys
  raise "#{label}: info version differs" unless info["version"]?.try(&.as_i) == 1
  raise "#{label}: nested version propagation differs" unless info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  versions = info["types_serialization_versions"]?.try(&.as_h) || raise "#{label}: serialization type versions missing"
  raise "#{label}: expected only the independently sourced String-v1 setting: #{versions.to_json}" unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
  records = info["columns"]?.try(&.as_a) || raise "#{label}: Default statistics records missing"
  names = records.map { |item| item.as_h["name"]?.try(&.as_s) }.compact
  raise "#{label}: Map must not be promoted into an unobserved sparse-recursive metadata tree: #{names.inspect}" unless names == ["pk"]
  pk = records.first?.try(&.as_h) || raise "#{label}: PK stats missing"
  raise "#{label}: PK stats keys differ" unless pk.keys.sort == ["kind", "name", "num_defaults", "num_rows"].sort
  raise "#{label}: PK default stats differ" unless pk["kind"]?.try(&.as_s) == "Default" && pk["name"]?.try(&.as_s) == "pk" && pk["num_rows"]?.try(&.as_i) == row_count.to_i64 && pk["num_defaults"]?.try(&.as_i) == 0_i64
  nil
end

def w108_assert_layout(part : String, profile : W108Profile, label : String) : Nil
  columns = File.read(File.join(part, "columns.txt")).lines.map(&.strip)
  raise "#{label}: exact columns.txt differs: #{columns.inspect}" unless columns == w108_columns(profile)
  substreams = File.read(File.join(part, "columns_substreams.txt"))
  expected_substreams = w108_substreams(profile)
  raise "#{label}: exact substream topology/order differs:\nexpected:\n#{expected_substreams}actual:\n#{substreams}" unless substreams == expected_substreams
  raise "#{label}: codec differs" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"
  raise "#{label}: metadata version differs" unless File.read(File.join(part, "metadata_version.txt")) == "0"
  raise "#{label}: count differs" unless File.read(File.join(part, "count.txt")) == profile.keys.size.to_s

  streams = w108_streams(profile)
  expected_files = ["checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt", "default_compression_codec.txt", "metadata_version.txt", "primary.idx", "serialization.json"]
  streams.each do |stream|
    base = CrystalClick::StreamName.hash(stream.name)
    expected_files << "#{base}.bin" << "#{base}.mrk2"
  end
  actual_files = Dir.children(part).sort
  missing = expected_files - actual_files
  extra = actual_files - expected_files
  raise "#{label}: exact part file inventory differs (missing=#{missing.sort.inspect}, extra=#{extra.sort.inspect})" unless actual_files == expected_files.sort

  checksums = CrystalClick::PartChecksums.open(part)
  checksum_files = expected_files - ["checksums.txt", "columns.txt", "columns_substreams.txt", "default_compression_codec.txt", "metadata_version.txt"]
  raise "#{label}: checksum file inventory differs" unless checksums.entries.keys.sort == checksum_files.sort
  checksums.entries.each_key { |name| checksums.validate_selected_entries(part, name) }

  # MergeTreeDataPartWriterOnDisk.cpp:278-283 writes one primary-key row per
  # data granule start; :359-372 appends the final row as the terminal mark.
  # With compress_primary_key=0 this profile's independent UInt64 encoding is
  # the raw primary.idx file, including the last-key terminal duplicate.
  primary_indexes = profile.boundaries[0, profile.boundaries.size - 1].map { |boundary| w108_unsigned_le(profile.keys[boundary], 8) }
  primary_indexes << w108_unsigned_le(profile.keys.last, 8)
  primary_raw = File.read(File.join(part, "primary.idx"))
  primary_expected = primary_indexes.join
  w108_assert_bytes(primary_raw, primary_expected, "#{label} independent primary.idx")
  w108_seeded_comparator(primary_raw, primary_expected, "#{label} primary.idx")

  streams.each do |stream|
    expected_raw = stream.fragments.join
    actual_raw = w108_raw_stream(part, stream.name)
    w108_assert_bytes(actual_raw, expected_raw, "#{label} #{stream.name} physical bytes")
    expected_marks = w108_expected_marks(profile, stream)
    actual_marks = w108_actual_marks(part, stream.name)
    raise "#{label} #{stream.name}: exact marks differ; expected #{expected_marks.inspect}, got #{actual_marks.inspect}" unless actual_marks == expected_marks
  end

  if profile.row_sizes.sum > 0
    enum_raw = w108_raw_stream(part, "payload%2Evalues%2Eright%2Estate")
    observed = enum_raw.to_slice.to_a
    expected = [0_u8, 0xf9_u8, 4_u8, 0_u8, 4_u8, 0xf9_u8]
    puts "OBSERVED #{label} Enum8 raw including hidden NULL carriers=#{observed.inspect}"
    raise "#{label}: Enum8 bytes differ from independently seeded RowBinary carriers" unless observed == expected
    w108_seeded_comparator(enum_raw, expected.map { |byte| w108_byte(byte) }.join, "#{label} Enum8 stream")
  end
  w108_assert_metadata(part, label, profile.keys.size)
  puts "PASS #{label}: exact schema/topology, #{streams.size - 1} BASIC Map streams, independent bytes/marks, checksums, metadata"
  nil
end

def w108_entry_rowbinary(output : IO, entry : W108Entry) : Nil
  case key = entry.key
  when String
    output << w108_varuint(key.bytesize.to_u64) << key
  when UInt64
    output << w108_unsigned_le(key, 8)
  else
    raise "unsupported RowBinary Map key carrier #{entry.key.class}"
  end
  output << w108_unsigned_le(entry.left_code, 8)
  if note = entry.note
    output << w108_byte(0_u8) << w108_varuint(note.bytesize.to_u64) << note
  else
    output << w108_byte(1_u8)
  end
  output << w108_signed_le(entry.ticks, 8)
  if state = entry.state
    output << w108_byte(0_u8) << w108_byte(state.unsafe_as(UInt8))
  else
    output << w108_byte(1_u8)
  end
  nil
end

def w108_expected_rowbinary(profile : W108Profile, row_indexes : Array(Int32)) : String
  String.build do |output|
    row_indexes.each do |index|
      entries = profile.rows[index]
      output << w108_unsigned_le(profile.keys[index], 8) << w108_varuint(entries.size.to_u64)
      entries.each { |entry| w108_entry_rowbinary(output, entry) }
    end
  end
end

def w108_check_table(binary : String, store : String, table : String, part : String) : Nil
  actual = w108_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  expected = "#{File.basename(part.chomp("/"))}\t1"
  raise "#{table}: CHECK TABLE differs: #{actual.inspect}" unless actual == expected
end

def w108_query_rowbinary(binary : String, store : String, table : String, profile : W108Profile, selected : Bool) : String
  predicate = selected ? " WHERE pk >= #{profile.selected_range.begin} AND pk < #{profile.selected_range.end}" : ""
  w108_run(binary, store, "SELECT pk, payload FROM default.#{table}#{predicate} ORDER BY pk FORMAT RowBinary")
end

def w108_assert_rowbinary(binary : String, store : String, table : String, profile : W108Profile, label : String) : Nil
  full_indexes = (0...profile.keys.size).map(&.to_i32)
  w108_assert_bytes(w108_query_rowbinary(binary, store, table, profile, false), w108_expected_rowbinary(profile, full_indexes), "#{label} full RowBinary")
  selected_indexes = profile.keys.each_with_index.select { |key, _i| key >= profile.selected_range.begin && key < profile.selected_range.end }.map { |_key, i| i.to_i32 }.to_a
  w108_assert_bytes(w108_query_rowbinary(binary, store, table, profile, true), w108_expected_rowbinary(profile, selected_indexes), "#{label} selected-PK RowBinary")
  puts "PASS #{label}: independent full/selected RowBinary preserves Map-key encoding, entry order, duplicates and empty maps"
  nil
end

def w108_insert(binary : String, store : String, table : String, profile : W108Profile) : Nil
  indexes = (0...profile.keys.size).map(&.to_i32)
  input = IO::Memory.new(w108_expected_rowbinary(profile, indexes).to_slice)
  w108_run(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", input)
  nil
end

def w108_attach(binary : String, store : String, profile : W108Profile, source_part : String, map_settings : String) : Tuple(String, String)
  table = profile.attached_table
  w108_create_table(binary, store, table, profile.type_name, map_settings)
  data_path = w108_run(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  raise "#{table}: ATTACH table has no data path" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(source_part, File.join(detached, "all_1_1_0"))
  w108_run(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  {table, w108_part_path(binary, store, table, profile.keys.size)}
end

def w108_run_profile(binary : String, store : String, profile : W108Profile, map_settings : String) : String
  w108_create_table(binary, store, profile.table, profile.type_name, map_settings)
  w108_insert(binary, store, profile.table, profile)
  source_part = w108_part_path(binary, store, profile.table, profile.keys.size)
  w108_assert_schema(binary, store, profile, profile.table)
  w108_assert_layout(source_part, profile, "W108 #{profile.name} stock source")
  w108_check_table(binary, store, profile.table, source_part)
  w108_assert_rowbinary(binary, store, profile.table, profile, "W108 #{profile.name} stock source")

  attached_table, attached_part = w108_attach(binary, store, profile, source_part, map_settings)
  w108_assert_schema(binary, store, profile, attached_table)
  w108_assert_layout(attached_part, profile, "W108 #{profile.name} stock ATTACH")
  w108_check_table(binary, store, attached_table, attached_part)
  w108_assert_rowbinary(binary, store, attached_table, profile, "W108 #{profile.name} stock ATTACH")
  attached_part
end

def w108_expect_reader_red(part : String, profile : W108Profile) : Nil
  begin
    CrystalClick::WidePart.open_typed(part, "payload")
  rescue ex : CrystalClick::UnsupportedFormatError
    raise "typed reader refused for unrelated reason: #{ex.message}" unless ex.message == "unsupported exact typed column"
    puts "EXPECTED RED W108: predecessor typed reader refuses stock-qualified #{profile.type_name} (#{profile.name})"
    return
  end
  raise "W108 RED failed: predecessor typed reader admitted #{profile.type_name} (#{profile.name})"
end

binary = ENV["CLICKHOUSE_BIN"]? || raise "set CLICKHOUSE_BIN to pinned ClickHouse 26.7.1.1315"
store = ENV["W108_STORE"]? || raise "set W108_STORE to a fresh temporary ClickHouse store"
unless store.starts_with?("/private/tmp/") || store.starts_with?("/tmp/")
  raise "refusing non-temporary W108 store: #{store}"
end
if Dir.exists?(store)
  raise "W108 store must be empty: #{store}" unless Dir.empty?(store)
else
  Dir.mkdir_p(store)
end

version_output = IO::Memory.new
version_status = Process.run(binary, ["local", "--version"], output: version_output)
raise "could not read stock ClickHouse version" unless version_status.success?
expected_version = "ClickHouse local version #{W108_STOCK_VERSION} (official build)."
raise "W108 requires #{expected_version}, got #{version_output.to_s.strip}" unless version_output.to_s.strip == expected_version
puts "Stock oracle: #{version_output.to_s.strip}"
puts "Qualified declarations: #{W108_MIXED.type_name}; #{W108_U64_MIXED.type_name}"

# Stock admission census is separate from storage qualification: all 53 exact
# non-nullable W105 scalar descriptors must survive Map's key-type gate, while
# Nullable keys are a negative control. This does not claim 53 physical proofs.
w108_key_census(binary, store)
map_settings = w108_basic_map_settings(binary, store)

mixed_attached = w108_run_profile(binary, store, W108_MIXED, map_settings)
empty_attached = w108_run_profile(binary, store, W108_EMPTY, map_settings)
u64_mixed_attached = w108_run_profile(binary, store, W108_U64_MIXED, map_settings)
u64_empty_attached = w108_run_profile(binary, store, W108_U64_EMPTY, map_settings)
puts "PASS W108 whole all-empty String-key and UInt64-key Map parts independently qualified: #{empty_attached}; #{u64_empty_attached}"

# Feature RED is counted only after independent stock-source and fresh-ATTACH
# certificates, exact metadata/checksums, raw streams/marks, CHECK, full and
# selected RowBinary, and the seeded wrong-byte comparison all pass.
w108_expect_reader_red(mixed_attached, W108_MIXED)
w108_expect_reader_red(empty_attached, W108_EMPTY)
w108_expect_reader_red(u64_mixed_attached, W108_U64_MIXED)
w108_expect_reader_red(u64_empty_attached, W108_U64_EMPTY)
puts "EXPECTED W108 RED: four stock Map(Tuple) source/ATTACH physical and logical certificates precede typed refusal"
exit 1
