# Independent stock and Crystal-writer certificates for BASIC Map(K, Tuple).
# String and UInt64 are physical anchors; the fifth profile also checks an
# external PK equal to its UInt64 default. The 53-key stock census in the RED
# probe is admission evidence, not a Cartesian physical codec certificate.
# Run each mode in a fresh store with probe_map_tuple_w108_green.sh.
require "json"
require "file_utils"
require "../src/crystal_click"

W108G_STOCK_VERSION    = "26.7.1.1315"
W108G_VALUE_TYPE       = "Tuple(left Tuple(code UInt64, note Nullable(String)), right Tuple(code DateTime64(9, 'America/New_York'), state Nullable(Enum8('negative' = -7, 'positive' = 4))))"
W108G_SETTINGS         = "index_granularity = 2, index_granularity_bytes = 10485760, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, ratio_of_defaults_for_sparse_serialization = 0.9375, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, default_compression_codec = 'LZ4'"
W108G_BOUNDARIES       = [0, 2, 4, 6, 8, 9]
W108G_EMPTY_BOUNDARIES = [0, 2, 4, 5]
W108G_MARK_ROWS        = [2_u64, 2_u64, 2_u64, 2_u64, 1_u64, 0_u64]
W108G_EMPTY_MARK_ROWS  = [2_u64, 2_u64, 1_u64, 0_u64]
W108G_KEYS             = [10_u64, 20_u64, 30_u64, 40_u64, 50_u64, 60_u64, 70_u64, 80_u64, 90_u64]
W108G_PK_ZERO_KEYS     = [0_u64, 11_u64, 12_u64, 13_u64, 14_u64, 15_u64, 16_u64, 17_u64, 18_u64]
W108G_EMPTY_KEYS       = [101_u64, 102_u64, 103_u64, 104_u64, 105_u64]
W108G_SIZES            = [0_u64, 0_u64, 3_u64, 0_u64, 0_u64, 0_u64, 2_u64, 1_u64, 0_u64]
W108G_EMPTY_SIZES      = Array(UInt64).new(5, 0_u64)

class W108GByteMismatch < Exception
end

struct W108GEntry
  getter key : String | UInt64
  getter left_code : UInt64
  getter note : String?
  getter ticks : Int64
  getter state : Int8?

  def initialize(@key : String | UInt64, @left_code : UInt64, @note : String?, @ticks : Int64, @state : Int8?)
  end
end

class W108GProfile
  getter name : String
  getter table : String
  getter attached_table : String
  getter key_type : String
  getter type_name : String
  getter keys : Array(UInt64)
  getter rows : Array(Array(W108GEntry))
  getter row_sizes : Array(UInt64)
  getter boundaries : Array(Int32)
  getter mark_rows : Array(UInt64)
  getter selected_begin : UInt64
  getter selected_end : UInt64
  getter all_empty : Bool

  def initialize(@name : String, @table : String, @attached_table : String, @key_type : String, @keys : Array(UInt64), @rows : Array(Array(W108GEntry)), @row_sizes : Array(UInt64), @boundaries : Array(Int32), @mark_rows : Array(UInt64), @selected_begin : UInt64, @selected_end : UInt64, @all_empty : Bool = false)
    @type_name = "Map(#{key_type}, #{W108G_VALUE_TYPE})"
    raise "#{name}: unsupported fixture key type" unless key_type == "String" || key_type == "UInt64"
    raise "#{name}: profile vectors differ" unless keys.size == rows.size && rows.size == row_sizes.size
    raise "#{name}: entry row sizes differ" unless rows.map(&.size.to_u64) == row_sizes
    raise "#{name}: all-empty profile contains entries" if all_empty && row_sizes.sum != 0
    raise "#{name}: boundary/mark schedules differ" unless boundaries.size == mark_rows.size
  end
end

W108G_STRING_ROWS = [
  [] of W108GEntry,
  [] of W108GEntry,
  [
    W108GEntry.new("dup", 11_u64, nil, -1_i64, nil),
    W108GEntry.new("dup", 12_u64, "", 0_i64, -7_i8),
    W108GEntry.new("", 13_u64, "a\0b", Int64::MIN, 4_i8),
  ],
  [] of W108GEntry,
  [] of W108GEntry,
  [] of W108GEntry,
  [
    W108GEntry.new("\0k", UInt64::MAX, "tail", Int64::MAX, nil),
    W108GEntry.new("x", 42_u64, nil, 1_i64, 4_i8),
  ],
  [W108GEntry.new("dup", 0_u64, "end", -1_000_i64, -7_i8)],
  [] of W108GEntry,
]
W108G_U64_ROWS = [
  [] of W108GEntry,
  [] of W108GEntry,
  [
    W108GEntry.new(0_u64, 11_u64, nil, -1_i64, nil),
    W108GEntry.new(0_u64, 12_u64, "", 0_i64, -7_i8),
    W108GEntry.new(UInt64::MAX, 13_u64, "a\0b", Int64::MIN, 4_i8),
  ],
  [] of W108GEntry,
  [] of W108GEntry,
  [] of W108GEntry,
  [
    W108GEntry.new(UInt64::MIN, UInt64::MAX, "tail", Int64::MAX, nil),
    W108GEntry.new(42_u64, 42_u64, nil, 1_i64, 4_i8),
  ],
  [W108GEntry.new(UInt64::MAX, 0_u64, "end", -1_000_i64, -7_i8)],
  [] of W108GEntry,
]

def w108g_profiles : Array(W108GProfile)
  empty_string_rows = Array(Array(W108GEntry)).new(W108G_EMPTY_KEYS.size) { [] of W108GEntry }
  empty_u64_rows = Array(Array(W108GEntry)).new(W108G_EMPTY_KEYS.size) { [] of W108GEntry }
  [
    W108GProfile.new("mixed-string", "w108g_string_mixed", "w108g_string_mixed_attached", "String", W108G_KEYS, W108G_STRING_ROWS, W108G_SIZES, W108G_BOUNDARIES, W108G_MARK_ROWS, 30_u64, 80_u64),
    W108GProfile.new("empty-string", "w108g_string_empty", "w108g_string_empty_attached", "String", W108G_EMPTY_KEYS, empty_string_rows, W108G_EMPTY_SIZES, W108G_EMPTY_BOUNDARIES, W108G_EMPTY_MARK_ROWS, 102_u64, 105_u64, true),
    W108GProfile.new("mixed-uint64", "w108g_u64_mixed", "w108g_u64_mixed_attached", "UInt64", W108G_KEYS, W108G_U64_ROWS, W108G_SIZES, W108G_BOUNDARIES, W108G_MARK_ROWS, 30_u64, 80_u64),
    W108GProfile.new("empty-uint64", "w108g_u64_empty", "w108g_u64_empty_attached", "UInt64", W108G_EMPTY_KEYS, empty_u64_rows, W108G_EMPTY_SIZES, W108G_EMPTY_BOUNDARIES, W108G_EMPTY_MARK_ROWS, 102_u64, 105_u64, true),
    W108GProfile.new("mixed-string-pk-zero", "w108g_string_pk_zero", "w108g_string_pk_zero_attached", "String", W108G_PK_ZERO_KEYS, W108G_STRING_ROWS, W108G_SIZES, W108G_BOUNDARIES, W108G_MARK_ROWS, 0_u64, 18_u64),
  ]
end

struct W108GStream
  getter name : String
  getter fragments : Array(String)
  getter outer_axis : Bool

  def initialize(@name : String, @fragments : Array(String), @outer_axis : Bool)
  end
end

def w108g_byte(value : UInt8) : String
  String.new(Bytes[value])
end

def w108g_unsigned_le(value : UInt64, width : Int32) : String
  raise "negative byte width" if width < 0
  low_width = Math.min(width, 8)
  String.build do |output|
    low_width.times { |index| output.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
    (width - low_width).times { output.write_byte(0_u8) }
  end
end

def w108g_signed_le(value : Int64, width : Int32) : String
  low_width = Math.min(width, 8)
  low = w108g_unsigned_le(value.unsafe_as(UInt64), low_width)
  low + String.new(Bytes.new(width - low_width, value < 0 ? 0xff_u8 : 0_u8))
end

def w108g_varuint(value : UInt64) : String
  String.build do |output|
    remaining = value
    while remaining >= 0x80_u64
      output.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
      remaining >>= 7
    end
    output.write_byte(remaining.to_u8)
  end
end

def w108g_entries(profile : W108GProfile) : Array(W108GEntry)
  profile.rows.flatten
end

def w108g_note(entry : W108GEntry, index : Int32, writer_profile : Bool) : String
  return entry.note || "" unless writer_profile && entry.note.nil?
  index == 0 ? "hidden-null-note-first" : "hidden-null-note-later"
end

def w108g_state(entry : W108GEntry, index : Int32, writer_profile : Bool) : Int8
  return entry.state || 0_i8 unless writer_profile && entry.state.nil?
  index == 0 ? 127_i8 : -128_i8
end

def w108g_streams(profile : W108GProfile, writer_profile : Bool = false) : Array(W108GStream)
  entries = w108g_entries(profile)
  key_streams = if profile.key_type == "String"
                  [
                    W108GStream.new("payload%2Ekeys.size", entries.map { |entry| w108g_unsigned_le(entry.key.as(String).bytesize.to_u64, 8) }, false),
                    W108GStream.new("payload%2Ekeys", entries.map { |entry| entry.key.as(String) }, false),
                  ]
                else
                  [W108GStream.new("payload%2Ekeys", entries.map { |entry| w108g_unsigned_le(entry.key.as(UInt64), 8) }, false)]
                end
  streams = [
    W108GStream.new("pk", profile.keys.map { |key| w108g_unsigned_le(key, 8) }, true),
    W108GStream.new("payload.size0", profile.row_sizes.map { |size| w108g_unsigned_le(size, 8) }, true),
  ]
  streams.concat(key_streams)
  notes = entries.map_with_index { |entry, index| w108g_note(entry, index.to_i32, writer_profile) }
  states = entries.map_with_index { |entry, index| w108g_state(entry, index.to_i32, writer_profile) }
  streams.concat([
    W108GStream.new("payload%2Evalues%2Eleft%2Ecode", entries.map { |entry| w108g_unsigned_le(entry.left_code, 8) }, false),
    W108GStream.new("payload%2Evalues%2Eleft%2Enote.null", entries.map { |entry| w108g_byte(entry.note.nil? ? 1_u8 : 0_u8) }, false),
    W108GStream.new("payload%2Evalues%2Eleft%2Enote.size", notes.map { |note| w108g_unsigned_le(note.bytesize.to_u64, 8) }, false),
    W108GStream.new("payload%2Evalues%2Eleft%2Enote", notes, false),
    W108GStream.new("payload%2Evalues%2Eright%2Ecode", entries.map { |entry| w108g_signed_le(entry.ticks, 8) }, false),
    W108GStream.new("payload%2Evalues%2Eright%2Estate.null", entries.map { |entry| w108g_byte(entry.state.nil? ? 1_u8 : 0_u8) }, false),
    W108GStream.new("payload%2Evalues%2Eright%2Estate", states.map { |state| w108g_byte(state.unsafe_as(UInt8)) }, false),
  ])
  streams
end

def w108g_columns(profile : W108GProfile) : Array(String)
  ["columns format version: 1", "2 columns:", "`pk` UInt64", "`payload` #{profile.type_name}"]
end

def w108g_substreams(profile : W108GProfile) : String
  names = w108g_streams(profile)[1..].map(&.name)
  lines = ["columns substreams version: 1", "2 columns:", "1 substreams for column `pk`:", "\tpk", "#{names.size} substreams for column `payload`:"]
  names.each { |name| lines << "\t#{name}" }
  lines.join("\n") + "\n"
end

def w108g_lz4_literal_frame_size(raw_size : Int32) : UInt64
  raise "empty LZ4 chunk has no frame" if raw_size <= 0
  extensions = raw_size < 15 ? 0 : ((raw_size - 15) // 255) + 1
  (25 + 1 + raw_size + extensions).to_u64
end

def w108g_flat_boundary(profile : W108GProfile, outer_boundary : Int32) : Int32
  profile.row_sizes[0, outer_boundary].sum.to_i32
end

def w108g_expected_marks(profile : W108GProfile, stream : W108GStream, writer_profile : Bool) : Array({UInt64, UInt64, UInt64})
  if writer_profile
    marks = [] of {UInt64, UInt64, UInt64}
    compressed_offset = 0_u64
    (profile.mark_rows.size - 1).times do |mark|
      outer_first = profile.boundaries[mark]
      outer_after = profile.boundaries[mark + 1]
      first = stream.outer_axis ? outer_first : w108g_flat_boundary(profile, outer_first)
      after = stream.outer_axis ? outer_after : w108g_flat_boundary(profile, outer_after)
      raw_chunk = stream.fragments[first, after - first].join
      marks << {compressed_offset, 0_u64, profile.mark_rows[mark]}
      compressed_offset += w108g_lz4_literal_frame_size(raw_chunk.bytesize) unless raw_chunk.empty?
    end
    marks << {compressed_offset, 0_u64, 0_u64}
    return marks
  end

  profile.boundaries.map_with_index do |boundary, index|
    consumed = stream.outer_axis ? boundary : w108g_flat_boundary(profile, boundary)
    decompressed_offset = stream.fragments[0, consumed].sum(&.bytesize).to_u64
    {0_u64, decompressed_offset, profile.mark_rows[index]}
  end.to_a
end

def w108g_actual_marks(part : String, stream : String) : Array({UInt64, UInt64, UInt64})
  bytes = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  size = CrystalClick::WidePart::MARK_SIZE
  raise "#{stream}: partial .mrk2 row" unless bytes.size % size == 0
  Array({UInt64, UInt64, UInt64}).new(bytes.size // size) do |index|
    offset = index * size
    fields = Array(UInt64).new(3) do |field|
      start = offset + field * 8
      8.times.reduce(0_u64) { |value, byte| value | (bytes[start + byte].to_u64 << (byte * 8)) }
    end
    {fields[0], fields[1], fields[2]}
  end
end

def w108g_raw_stream(part : String, name : String) : String
  encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(name)}.bin")).to_slice
  return "" if encoded.empty?
  String.new(CrystalClick::CompressedBlock.decode_all(encoded))
end

def w108g_assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual == expected
  offset = 0
  limit = Math.min(actual.bytesize, expected.bytesize)
  while offset < limit && actual.to_slice[offset] == expected.to_slice[offset]
    offset += 1
  end
  got = offset < actual.bytesize ? actual.to_slice[offset].to_s(16).rjust(2, '0') : "<eof>"
  wanted = offset < expected.bytesize ? expected.to_slice[offset].to_s(16).rjust(2, '0') : "<eof>"
  raise W108GByteMismatch.new("#{label}: expected #{expected.bytesize} bytes, got #{actual.bytesize}; first diff #{offset}: expected #{wanted}, got #{got}")
end

def w108g_seeded_comparator(actual : String, expected : String, label : String) : Nil
  w108g_assert_bytes(actual, expected, "#{label} baseline")
  raise "#{label}: cannot seed a mismatch in empty bytes" if expected.empty?
  damaged = String.new(expected.to_slice)
  damaged.to_unsafe[0] = damaged.to_slice[0] ^ 1_u8
  begin
    w108g_assert_bytes(actual, damaged, "#{label} seeded")
    raise "#{label}: one-byte drift was accepted"
  rescue ex : W108GByteMismatch
  end
  puts "PASS #{label}: seeded physical mismatch rejected"
  nil
end

def w108g_run(binary : String, store : String, query : String, input : IO? = nil) : String
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

def w108g_basic_settings(binary : String, store : String) : String
  query = "SELECT name || '\\t' || value FROM system.merge_tree_settings WHERE name IN ('map_serialization_version', 'map_serialization_version_for_zero_level_parts') ORDER BY name FORMAT TSVRaw"
  rows = w108g_run(binary, store, query).lines.map(&.strip).reject(&.empty?)
  unless rows.empty?
    pairs = rows.map(&.split('\t', 2))
    names = pairs.map(&.[0]).sort
    raise "only one of the two Map serialization settings is exposed: #{pairs.inspect}" unless names == ["map_serialization_version", "map_serialization_version_for_zero_level_parts"]
    raise "Map serialization settings differ from BASIC: #{pairs.inspect}" unless pairs.size == 2 && pairs.all? { |pair| pair.size == 2 && pair[1].downcase == "basic" }
  end
  ", map_serialization_version = 'basic', map_serialization_version_for_zero_level_parts = 'basic'"
end

def w108g_create_table(binary : String, store : String, table : String, type_name : String, map_settings : String) : Nil
  w108g_run(binary, store, "CREATE TABLE default.#{table} (pk UInt64, payload #{type_name}) ENGINE = MergeTree ORDER BY pk SETTINGS #{W108G_SETTINGS}#{map_settings}")
  nil
end

def w108g_part_path(binary : String, store : String, table : String, row_count : Int32) : String
  rows = w108g_run(binary, store, "SELECT path, part_type, rows FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines.map(&.strip).reject(&.empty?)
  raise "#{table}: expected one #{row_count}-row Wide part; got #{rows.inspect}" unless rows.size == 1
  parts = rows.first.split('\t')
  raise "#{table}: malformed active part #{rows.first.inspect}" unless parts.size == 3 && parts[1] == "Wide" && parts[2] == row_count.to_s
  parts[0]
end

def w108g_assert_schema(binary : String, store : String, table : String, profile : W108GProfile) : Nil
  rows = w108g_run(binary, store, "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw").lines.map(&.strip)
  expected = ["pk UInt64", "payload #{profile.type_name}"]
  raise "#{table}: exact declaration differs: #{rows.inspect}" unless rows == expected
end

def w108g_assert_metadata(part : String, profile : W108GProfile, label : String) : Nil
  info = JSON.parse(File.read(File.join(part, "serialization.json"))).as_h
  keys = ["columns", "propagate_types_serialization_versions_to_nested_types", "types_serialization_versions", "version"].sort
  raise "#{label}: exact serialization envelope keys differ" unless info.keys.sort == keys
  raise "#{label}: serializer version differs" unless info["version"]?.try(&.as_i) == 1
  raise "#{label}: nested version propagation differs" unless info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  versions = info["types_serialization_versions"]?.try(&.as_h) || raise "#{label}: missing type versions"
  raise "#{label}: BASIC Map envelope must retain only String-v1" unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
  records = info["columns"]?.try(&.as_a) || raise "#{label}: missing stock Default record"
  raise "#{label}: only PK Default statistics are independently qualified" unless records.size == 1
  pk = records.first.as_h
  raise "#{label}: PK statistic keys differ" unless pk.keys.sort == ["kind", "name", "num_defaults", "num_rows"].sort
  expected_pk_defaults = profile.keys.count { |key| key == 0_u64 }.to_i64
  unless pk["kind"]?.try(&.as_s) == "Default" && pk["name"]?.try(&.as_s) == "pk" &&
         pk["num_defaults"]?.try(&.as_i) == expected_pk_defaults && pk["num_rows"]?.try(&.as_i) == profile.keys.size.to_i64
    raise "#{label}: PK Default statistics differ (expected #{expected_pk_defaults} defaults)"
  end
  nil
end

def w108g_assert_layout(part : String, profile : W108GProfile, label : String, writer_profile : Bool = false) : Nil
  actual_columns = File.read(File.join(part, "columns.txt")).lines.map(&.strip)
  raise "#{label}: columns.txt differs: #{actual_columns.inspect}" unless actual_columns == w108g_columns(profile)
  actual_substreams = File.read(File.join(part, "columns_substreams.txt"))
  raise "#{label}: exact stream inventory/order differs:\nexpected:\n#{w108g_substreams(profile)}actual:\n#{actual_substreams}" unless actual_substreams == w108g_substreams(profile)
  raise "#{label}: codec differs" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"
  raise "#{label}: metadata version differs" unless File.read(File.join(part, "metadata_version.txt")) == "0"
  raise "#{label}: row count differs" unless File.read(File.join(part, "count.txt")) == profile.keys.size.to_s

  streams = w108g_streams(profile, writer_profile)
  expected_files = ["checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt", "default_compression_codec.txt", "metadata_version.txt", "primary.idx", "serialization.json"]
  streams.each do |stream|
    hash = CrystalClick::StreamName.hash(stream.name)
    expected_files << "#{hash}.bin" << "#{hash}.mrk2"
  end
  actual_files = Dir.children(part).sort
  raise "#{label}: exact part inventory differs (missing=#{(expected_files - actual_files).sort.inspect}, extra=#{(actual_files - expected_files).sort.inspect})" unless actual_files == expected_files.sort
  checksums = CrystalClick::PartChecksums.open(part)
  checked_files = expected_files - ["checksums.txt", "columns.txt", "columns_substreams.txt", "default_compression_codec.txt", "metadata_version.txt"]
  raise "#{label}: checksum member inventory differs" unless checksums.entries.keys.sort == checked_files.sort
  checksums.entries.each_key { |file| checksums.validate_selected_entries(part, file) }

  primary_keys = profile.boundaries[0, profile.boundaries.size - 1].map { |boundary| w108g_unsigned_le(profile.keys[boundary], 8) }
  primary_keys << w108g_unsigned_le(profile.keys.last, 8)
  primary_raw = File.read(File.join(part, "primary.idx"))
  primary_expected = primary_keys.join
  w108g_seeded_comparator(primary_raw, primary_expected, "#{label} primary.idx")

  streams.each do |stream|
    expected_raw = stream.fragments.join
    actual_raw = w108g_raw_stream(part, stream.name)
    if stream.name == "payload%2Ekeys" && !expected_raw.empty?
      w108g_seeded_comparator(actual_raw, expected_raw, "#{label} #{stream.name}")
    else
      w108g_assert_bytes(actual_raw, expected_raw, "#{label} #{stream.name}")
    end
    expected_marks = w108g_expected_marks(profile, stream, writer_profile)
    actual_marks = w108g_actual_marks(part, stream.name)
    raise "#{label} #{stream.name}: marks differ; expected #{expected_marks.inspect}, got #{actual_marks.inspect}" unless actual_marks == expected_marks
  end
  w108g_assert_metadata(part, profile, label)
  puts "PASS #{label}: exact schema, #{streams.size - 1} Map payload streams, independent bytes/marks/checksums/metadata"
  nil
end

def w108g_entry_rowbinary(output : IO, entry : W108GEntry) : Nil
  case key = entry.key
  when String
    output << w108g_varuint(key.bytesize.to_u64) << key
  when UInt64
    output << w108g_unsigned_le(key, 8)
  end
  output << w108g_unsigned_le(entry.left_code, 8)
  if note = entry.note
    output << w108g_byte(0_u8) << w108g_varuint(note.bytesize.to_u64) << note
  else
    output << w108g_byte(1_u8)
  end
  output << w108g_signed_le(entry.ticks, 8)
  if state = entry.state
    output << w108g_byte(0_u8) << w108g_byte(state.unsafe_as(UInt8))
  else
    output << w108g_byte(1_u8)
  end
  nil
end

def w108g_expected_rowbinary(profile : W108GProfile, indexes : Array(Int32)) : String
  String.build do |output|
    indexes.each do |index|
      entries = profile.rows[index]
      output << w108g_unsigned_le(profile.keys[index], 8) << w108g_varuint(entries.size.to_u64)
      entries.each { |entry| w108g_entry_rowbinary(output, entry) }
    end
  end
end

def w108g_selected_indexes(profile : W108GProfile) : Array(Int32)
  profile.keys.each_with_index.select { |key, _index| key >= profile.selected_begin && key < profile.selected_end }.map { |_key, index| index.to_i32 }.to_a
end

def w108g_query_rowbinary(binary : String, store : String, table : String, profile : W108GProfile, selected : Bool) : String
  predicate = selected ? " WHERE pk >= #{profile.selected_begin} AND pk < #{profile.selected_end}" : ""
  w108g_run(binary, store, "SELECT pk, payload FROM default.#{table}#{predicate} ORDER BY pk FORMAT RowBinary")
end

def w108g_assert_rowbinary(binary : String, store : String, table : String, profile : W108GProfile, label : String) : Nil
  full_indexes = (0...profile.keys.size).map(&.to_i32)
  w108g_assert_bytes(w108g_query_rowbinary(binary, store, table, profile, false), w108g_expected_rowbinary(profile, full_indexes), "#{label} full RowBinary")
  w108g_assert_bytes(w108g_query_rowbinary(binary, store, table, profile, true), w108g_expected_rowbinary(profile, w108g_selected_indexes(profile)), "#{label} selected-PK RowBinary")
  puts "PASS #{label}: independent full and selected RowBinary preserves ordered duplicate keys and NULLs"
  nil
end

def w108g_insert(binary : String, store : String, table : String, profile : W108GProfile) : Nil
  indexes = (0...profile.keys.size).map(&.to_i32)
  wire = w108g_expected_rowbinary(profile, indexes)
  w108g_run(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", IO::Memory.new(wire.to_slice))
  nil
end

def w108g_check(binary : String, store : String, table : String, part : String) : Nil
  actual = w108g_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  raise "#{table}: CHECK TABLE failed: #{actual.inspect}" unless actual == "#{File.basename(part.chomp("/"))}\t1"
  nil
end

def w108g_attach(binary : String, store : String, profile : W108GProfile, source_part : String, map_settings : String, table : String? = nil, writer_profile : Bool = false) : String
  attached_table = table || profile.attached_table
  w108g_create_table(binary, store, attached_table, profile.type_name, map_settings)
  data_path = w108g_run(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{attached_table}' FORMAT TSVRaw").strip
  raise "#{attached_table}: empty data path" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(source_part, File.join(detached, "all_1_1_0"))
  w108g_run(binary, store, "ALTER TABLE default.#{attached_table} ATTACH PART 'all_1_1_0'")
  part = w108g_part_path(binary, store, attached_table, profile.keys.size)
  w108g_assert_schema(binary, store, attached_table, profile)
  w108g_assert_layout(part, profile, "W108G #{profile.name} fresh ATTACH", writer_profile)
  w108g_check(binary, store, attached_table, part)
  w108g_assert_rowbinary(binary, store, attached_table, profile, "W108G #{profile.name} fresh ATTACH")
  part
end

def w108g_stock_seed(binary : String, store : String, profile : W108GProfile, map_settings : String) : String
  w108g_create_table(binary, store, profile.table, profile.type_name, map_settings)
  w108g_insert(binary, store, profile.table, profile)
  part = w108g_part_path(binary, store, profile.table, profile.keys.size)
  w108g_assert_schema(binary, store, profile.table, profile)
  w108g_assert_layout(part, profile, "W108G #{profile.name} stock source")
  w108g_check(binary, store, profile.table, part)
  w108g_assert_rowbinary(binary, store, profile.table, profile, "W108G #{profile.name} stock source")
  part
end

def w108g_expected_offsets(sizes : Array(UInt64)) : Array(UInt64)
  offsets = [0_u64]
  sizes.each { |size| offsets << offsets.last + size }
  offsets
end

def w108g_expected_masks(profile : W108GProfile, field : String, first_entry : Int32, count : Int32) : Array(UInt8)
  entries = w108g_entries(profile)[first_entry, count]
  case field
  when "left.note"
    entries.map { |entry| entry.note.nil? ? 1_u8 : 0_u8 }
  when "right.state"
    entries.map { |entry| entry.state.nil? ? 1_u8 : 0_u8 }
  else
    [] of UInt8
  end
end

def w108g_field_fragments(profile : W108GProfile, field : String, writer_profile : Bool) : Array(String)
  entries = w108g_entries(profile)
  case field
  when "left.code"
    entries.map { |entry| w108g_unsigned_le(entry.left_code, 8) }
  when "left.note"
    entries.map_with_index { |entry, index| w108g_note(entry, index.to_i32, writer_profile) }
  when "right.code"
    entries.map { |entry| w108g_signed_le(entry.ticks, 8) }
  when "right.state"
    entries.map_with_index { |entry, index| w108g_byte(w108g_state(entry, index.to_i32, writer_profile).unsafe_as(UInt8)) }
  else
    raise "missing independent W108 field #{field}"
  end
end

def w108g_column_fragment(column : CrystalClick::WideTupleLeafColumn, field : String, index : Int32) : String
  physical = column.physical_values
  case field
  when "left.code"
    w108g_unsigned_le(physical.as(Array(UInt64))[index], 8)
  when "left.note"
    physical.as(Array(String))[index]
  when "right.code"
    value = physical.as(Array(CrystalClick::DateTime64Value))[index]
    raise "DateTime64 precision changed in W108 value leaf" unless value.precision == 9_u8
    w108g_signed_le(value.raw, 8)
  when "right.state"
    w108g_byte(physical.as(Array(Int8))[index].unsafe_as(UInt8))
  else
    raise "missing W108 physical converter for #{field}"
  end
end

def w108g_assert_tuple_data(tuple_data : CrystalClick::WideTupleColumnData, profile : W108GProfile, first_entry : Int32, count : Int32, writer_profile : Bool, label : String) : Nil
  raise "#{label}: exact recursive Tuple declaration differs" unless tuple_data.type_name == W108G_VALUE_TYPE
  expected_fields = [
    {"left.code", "UInt64"},
    {"left.note", "Nullable(String)"},
    {"right.code", "DateTime64(9, 'America/New_York')"},
    {"right.state", "Nullable(Enum8('negative' = -7, 'positive' = 4))"},
  ]
  raise "#{label}: nested flattened descriptor paths/order differ" unless tuple_data.fields.map { |field| {field.name, field.type_name} } == expected_fields
  raise "#{label}: flat Tuple element count differs" unless tuple_data.row_count == count

  tuple_data.columns.each_with_index do |column, field_index|
    field_name, type_name = expected_fields[field_index]
    raise "#{label}: exact leaf path/type differs for #{field_name}" unless column.name == field_name && column.type_name == type_name
    fragments = w108g_field_fragments(profile, field_name, writer_profile)[first_entry, count]
    count.times do |index|
      w108g_assert_bytes(w108g_column_fragment(column, field_name, index), fragments[index], "#{label} #{field_name} raw carrier[#{index}]")
    end
    if column.leaf_type.nullable?
      expected_mask = w108g_expected_masks(profile, field_name, first_entry, count)
      raise "#{label}: exact Nullable mask differs for #{field_name}" unless column.null_map.try(&.bytes) == expected_mask
    else
      raise "#{label}: bare leaf unexpectedly has a Nullable mask" if column.null_map
    end
    copy = column.owned_copy
    raise "#{label}: immutable leaf copy lost descriptor" unless copy.name == field_name && copy.type_name == type_name
    count.times do |index|
      w108g_assert_bytes(w108g_column_fragment(copy, field_name, index), fragments[index], "#{label} copied #{field_name}[#{index}]")
    end
  end
  nil
end

def w108g_assert_value_row(value_row : CrystalClick::WideTupleRow, entry : W108GEntry, label : String) : Nil
  raise "#{label}: nested Map value identity is not the exact Tuple" unless value_row.type_name == W108G_VALUE_TYPE
  left = value_row.tuple("left")
  right = value_row.tuple("right")
  raise "#{label}: left repeated-name scope differs" unless left.fields.map(&.name) == ["code", "note"]
  raise "#{label}: right repeated-name scope differs" unless right.fields.map(&.name) == ["code", "state"]
  raise "#{label}: UInt64 value differs" unless left.value_as("code", UInt64) == entry.left_code
  note = left["note"]
  if expected_note = entry.note
    raise "#{label}: String value differs" unless note.as?(String) == expected_note
  else
    raise "#{label}: NULL String value changed" unless note.nil?
  end
  ticks = right.value_as("code", CrystalClick::DateTime64Value)
  raise "#{label}: DateTime64 raw ticks/precision differ" unless ticks.raw == entry.ticks && ticks.precision == 9_u8
  state = right["state"]
  if expected_state = entry.state
    actual = state.as?(CrystalClick::Enum8Value) || raise "#{label}: Enum8 value disappeared"
    expected_label = expected_state == -7_i8 ? "negative" : "positive"
    raise "#{label}: Enum8 code/label differs" unless actual.code == expected_state && actual.label == expected_label
  else
    raise "#{label}: NULL Enum8 value changed" unless state.nil?
  end
  nil
end

def w108g_assert_map_row(row : CrystalClick::WideMapTupleRow, profile : W108GProfile, outer_index : Int32, writer_profile : Bool, label : String) : Nil
  expected_entries = profile.rows[outer_index]
  raise "#{label}: exact Map row identity differs" unless row.type_name == profile.type_name
  raise "#{label}: row entry count differs at outer row #{outer_index}" unless row.size == expected_entries.size
  expected_entries.each_with_index do |entry, entry_index|
    if profile.key_type == "String"
      raise "#{label}: ordered String key differs" unless row.key_as(entry_index, String) == entry.key.as(String)
    else
      raise "#{label}: ordered UInt64 key differs" unless row.key_as(entry_index, UInt64) == entry.key.as(UInt64)
    end
    w108g_assert_value_row(row.value_at(entry_index), entry, "#{label} outer=#{outer_index} entry=#{entry_index}")
  end
  iterated = 0
  row.each do |key, value_row|
    entry = expected_entries[iterated]? || raise "#{label}: Map each yielded an extra entry"
    if profile.key_type == "String"
      raise "#{label}: Map each changed ordered String key" unless key.as?(String) == entry.key.as(String)
    else
      raise "#{label}: Map each changed ordered UInt64 key" unless key.as?(UInt64) == entry.key.as(UInt64)
    end
    w108g_assert_value_row(value_row, entry, "#{label} each outer=#{outer_index} entry=#{iterated}")
    iterated += 1
  end
  raise "#{label}: Map each lost an entry" unless iterated == expected_entries.size
  nil
end

def w108g_assert_map_data(data : CrystalClick::WideMapTupleColumnData, profile : W108GProfile, outer_first : Int32, outer_count : Int32, flat_first : Int32, flat_count : Int32, writer_profile : Bool, label : String) : Nil
  expected_sizes = profile.row_sizes[outer_first, outer_count]
  raise "#{label}: exact Map declaration differs" unless data.plan.column_type == profile.type_name
  raise "#{label}: outer/entry row counts differ" unless data.row_count == outer_count && data.entry_count == flat_count
  raise "#{label}: detached outer size vector differs" unless data.row_sizes == expected_sizes
  raise "#{label}: local entry offsets differ" unless data.offsets == w108g_expected_offsets(expected_sizes)
  raise "#{label}: exact key descriptor/path differs" unless data.key_column.name == "keys" && data.key_column.type_name == profile.key_type

  flat_entries = w108g_entries(profile)[flat_first, flat_count]
  key_raw = data.key_column.physical_values
  if profile.key_type == "String"
    raise "#{label}: key physical carrier is not String" unless key_raw.is_a?(Array(String))
    got = key_raw.as(Array(String))
    wanted = flat_entries.map { |entry| entry.key.as(String) }
    raise "#{label}: exact String key bytes/order differ" unless got == wanted
  else
    raise "#{label}: key physical carrier is not UInt64" unless key_raw.is_a?(Array(UInt64))
    got = key_raw.as(Array(UInt64))
    wanted = flat_entries.map { |entry| entry.key.as(UInt64) }
    raise "#{label}: exact UInt64 key order differs" unless got == wanted
  end
  key_copy = data.key_column.owned_copy
  raise "#{label}: owned key copy lost exact declaration" unless key_copy.name == "keys" && key_copy.type_name == profile.key_type
  if profile.key_type == "String"
    raise "#{label}: owned String key copy differs" unless key_copy.physical_values.as(Array(String)) == key_raw.as(Array(String))
  else
    raise "#{label}: owned UInt64 key copy differs" unless key_copy.physical_values.as(Array(UInt64)) == key_raw.as(Array(UInt64))
  end

  w108g_assert_tuple_data(data.tuple_data, profile, flat_first, flat_count, writer_profile, label)
  flat_cursor = flat_first
  outer_count.times do |offset|
    map_row = data.row(offset)
    w108g_assert_map_row(map_row, profile, outer_first + offset, writer_profile, "#{label} row #{offset}")
    raise "#{label}: row/flattened schedule diverged" unless map_row.size == expected_sizes[offset].to_i32
    flat_cursor += map_row.size
  end
  raise "#{label}: exact ordered entry cardinality differs" unless flat_cursor == flat_first + flat_count
  nil
end

def w108g_assert_typed(part : String, profile : W108GProfile, label : String, writer_profile : Bool = false) : CrystalClick::WidePart
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  raise "#{label}: exact persisted Map type differs" unless reader.column_type == profile.type_name
  expected_marks = profile.mark_rows[0, profile.mark_rows.size - 1]
  raise "#{label}: outer mark rows differ" unless reader.mark_row_counts == expected_marks
  data = reader.read_map_tuple_mark_range("payload", 0, reader.mark_count)
  raise "#{label}: full Map range lost outer rows/entries" unless data.row_count == profile.keys.size && data.entry_count == profile.row_sizes.sum.to_i32
  w108g_assert_map_data(data, profile, 0, profile.keys.size, 0, data.entry_count, writer_profile, label)

  # Mark 1 begins at flat origin zero. Mixed fixtures also select mark 3,
  # which begins after three entries; the shorter all-empty part selects its
  # final one-row data mark instead and remains at flat origin zero.
  selected = reader.read_map_tuple_mark_range("payload", 1, 1)
  w108g_assert_map_data(selected, profile, 2, 2, 0, profile.all_empty ? 0 : 3, writer_profile, "#{label} selected mark 1")
  offset_mark = profile.all_empty ? 2 : 3
  offset_outer = profile.boundaries[offset_mark]
  offset_rows = profile.mark_rows[offset_mark].to_i32
  flat_origin = w108g_flat_boundary(profile, offset_outer)
  offset_entries = profile.row_sizes[offset_outer, offset_rows].sum.to_i32
  offset = reader.read_map_tuple_mark_range("payload", offset_mark, 1)
  w108g_assert_map_data(offset, profile, offset_outer, offset_rows, flat_origin, offset_entries, writer_profile, "#{label} selected offset mark #{offset_mark}")

  callbacks = [] of {Int32, Int32, Int32}
  outer_cursor = 0_i32
  flat_cursor = 0_i32
  reader.each_map_tuple_mark_range("payload", 0, reader.mark_count) do |mark_data, mark_index|
    rows = expected_marks[mark_index].to_i32
    entries = if rows == 0
                0_i32
              else
                profile.row_sizes[outer_cursor, rows].sum.to_i32
              end
    w108g_assert_map_data(mark_data, profile, outer_cursor, rows, flat_cursor, entries, writer_profile, "#{label} lazy mark #{mark_index}")
    callbacks << {mark_index, rows, entries}
    outer_cursor += rows
    flat_cursor += entries
  end
  expected_callbacks = [] of {Int32, Int32, Int32}
  (0...expected_marks.size).each do |index|
    rows = expected_marks[index].to_i32
    entries = rows == 0 ? 0_i32 : profile.row_sizes[profile.boundaries[index], rows].sum.to_i32
    expected_callbacks << {index.to_i32, rows, entries}
  end
  raise "#{label}: lazy mark callback schedule differs: #{callbacks.inspect}" unless callbacks == expected_callbacks
  raise "#{label}: lazy schedule lost outer/entry rows" unless outer_cursor == profile.keys.size && flat_cursor == profile.row_sizes.sum.to_i32
  puts "PASS #{label}: full, selected, nonzero-origin and lazy typed reads preserve Map identity, duplicate order and both axes"
  reader
end

def w108g_assert_consumers(part : String, profile : W108GProfile, label : String, writer_profile : Bool = false) : Nil
  table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
  raise "#{label}: table exact Map declaration differs" unless table.column_types.any? { |name, type| name == "payload" && type == profile.type_name }

  table_rows = [] of CrystalClick::WideMapTupleRow
  table_keys = [] of UInt64
  table.scan_typed(batch_rows: 3) do |batch|
    keys = batch.values_for("pk")
    rows = batch.map_tuple_rows_for("payload")
    raise "#{label}: table batch key/Map row counts differ" unless keys.size == rows.size
    keys.each_with_index do |key, offset|
      outer_index = profile.keys.index(key).try(&.to_i32) || raise "#{label}: table produced an unknown primary key"
      row = rows[offset]
      w108g_assert_map_row(row, profile, outer_index, writer_profile, "#{label} table row #{outer_index}")
      table_rows << row
      table_keys << key
    end
  end
  raise "#{label}: table full scan lost/reordered outer rows" unless table_rows.size == profile.keys.size && table_keys == profile.keys

  table_window = [] of CrystalClick::WideMapTupleRow
  table_window_keys = [] of UInt64
  table.scan_typed_window(2_u64, 3) do |batch|
    table_window.concat(batch.map_tuple_rows_for("payload"))
    batch.values_for("pk").each { |key| table_window_keys << key }
  end
  expected_window_sizes = profile.row_sizes[2, 3].map(&.to_i32)
  raise "#{label}: table window lost/reordered outer/entry rows" unless table_window.size == 3 && table_window.map(&.size) == expected_window_sizes && table_window_keys == profile.keys[2, 3]
  table_window.each_with_index do |row, offset|
    w108g_assert_map_row(row, profile, offset + 2, writer_profile, "#{label} table window row #{offset + 2}")
  end

  catalog_base = ENV["W108G_CATALOG_ROOT"]? || raise "set W108G_CATALOG_ROOT to an isolated temporary catalog directory"
  catalog_suffix = label.downcase.gsub(/[^a-z0-9]+/, "-").strip('-')
  catalog_root = File.join(catalog_base, catalog_suffix)
  w108g_catalog_root(catalog_root, part, profile)
  offline = CrystalClick::OfflineCatalog.open(catalog_root)["lab"]["events"]
  values = offline["payload"].values
  raise "#{label}: catalog materialized outer row count differs" unless values.size == profile.keys.size
  catalog_rows = values.map do |value|
    value.as?(CrystalClick::WideMapTupleRow) || raise "#{label}: catalog returned a non-Map value"
  end
  catalog_rows.each_with_index do |row, index|
    w108g_assert_map_row(row, profile, index.to_i32, writer_profile, "#{label} catalog value #{index}")
  end

  catalog_scan = [] of CrystalClick::WideMapTupleRow
  catalog_scan_keys = [] of UInt64
  offline.scan_typed(["pk", "payload"], batch_rows: 3) do |batch|
    catalog_scan.concat(batch.map_tuple_rows_for("payload"))
    batch.values_for("pk").each { |key| catalog_scan_keys << key }
  end
  raise "#{label}: catalog full scan lost/reordered outer rows" unless catalog_scan.size == profile.keys.size && catalog_scan_keys == profile.keys
  catalog_scan.each_with_index do |row, index|
    w108g_assert_map_row(row, profile, index.to_i32, writer_profile, "#{label} catalog scan row #{index}")
  end

  catalog_window = [] of CrystalClick::WideMapTupleRow
  catalog_window_keys = [] of UInt64
  offline.scan_typed_window(["pk", "payload"], 2_u64, 3) do |batch|
    catalog_window.concat(batch.map_tuple_rows_for("payload"))
    batch.values_for("pk").each { |key| catalog_window_keys << key }
  end
  raise "#{label}: catalog window lost/reordered rows or differs from table window" unless catalog_window.size == table_window.size && catalog_window.map(&.size) == table_window.map(&.size) && catalog_window_keys == profile.keys[2, 3]
  catalog_window.each_with_index do |row, offset|
    w108g_assert_map_row(row, profile, offset + 2, writer_profile, "#{label} catalog window row #{offset + 2}")
  end

  puts "PASS #{label}: table/catalog values, full scans and windows retain ordered Map entries and empty outer rows"
  nil
end

def w108g_catalog_root(root : String, part : String, profile : W108GProfile) : String
  raise "refusing existing W108 catalog path: #{root}" if Dir.exists?(root)
  metadata = File.join(root, "metadata")
  database_uuid = "10800000-0000-4000-8000-000000000001"
  table_uuid = "10800000-0000-4000-8000-000000000002"
  database = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(metadata)
  FileUtils.mkdir_p(database)
  FileUtils.mkdir_p(table)
  File.write(File.join(metadata, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(File.join(database, "events.sql"), "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` #{profile.type_name}\n)\nENGINE = MergeTree\nORDER BY pk\n")
  File.write(File.join(table, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table, "detached"))
  FileUtils.cp_r(part, File.join(table, "all_1_1_0"))
  root
end

def w108g_null_map(nulls : Array(UInt8)) : CrystalClick::ScalarNullMap
  bytes = Bytes.new(nulls.size) { |index| nulls[index] }
  CrystalClick::ScalarNullMap.new(bytes, nulls.size.to_u64)
end

def w108g_leaf_type(type_name : String) : CrystalClick::WideTupleLeafType
  CrystalClick::WideTupleLeafType.parse(type_name) || raise "W108 writer fixture type is not an admitted leaf: #{type_name}"
end

def w108g_writer_columns(profile : W108GProfile) : {CrystalClick::WideTupleLeafColumn, Array(CrystalClick::WideTupleLeafColumn)}
  entries = w108g_entries(profile)
  key_type = w108g_leaf_type(profile.key_type)
  key_column = if profile.key_type == "String"
                 CrystalClick::WideTupleLeafColumn.new("keys", key_type, entries.map { |entry| entry.key.as(String) }, nil)
               else
                 CrystalClick::WideTupleLeafColumn.new("keys", key_type, entries.map { |entry| entry.key.as(UInt64) }, nil)
               end

  left_code_type = w108g_leaf_type("UInt64")
  note_type = w108g_leaf_type("Nullable(String)")
  datetime_type = w108g_leaf_type("DateTime64(9, 'America/New_York')")
  state_type = w108g_leaf_type("Nullable(Enum8('negative' = -7, 'positive' = 4))")

  left_codes = entries.map(&.left_code)
  note_values = entries.map_with_index do |entry, index|
    entry.note || (index == 0 ? "hidden-null-note-first" : "hidden-null-note-later")
  end
  note_mask = w108g_null_map(entries.map { |entry| entry.note.nil? ? 1_u8 : 0_u8 })
  ticks = entries.map { |entry| CrystalClick::DateTime64Value.new(entry.ticks, 9) }
  state_values = entries.map_with_index do |entry, index|
    entry.state || (index == 0 ? 127_i8 : -128_i8)
  end
  state_mask = w108g_null_map(entries.map { |entry| entry.state.nil? ? 1_u8 : 0_u8 })

  columns = [
    CrystalClick::WideTupleLeafColumn.new("left.code", left_code_type, left_codes, nil),
    CrystalClick::WideTupleLeafColumn.new("left.note", note_type, note_values, note_mask),
    CrystalClick::WideTupleLeafColumn.new("right.code", datetime_type, ticks, nil),
    CrystalClick::WideTupleLeafColumn.new("right.state", state_type, state_values, state_mask),
  ]
  {key_column, columns}
end

def w108g_assert_writer_input(profile : W108GProfile, key_column : CrystalClick::WideTupleLeafColumn, columns : Array(CrystalClick::WideTupleLeafColumn)) : Nil
  entries = w108g_entries(profile)
  raise "W108 writer fixture lost exact key path/type" unless key_column.name == "keys" && key_column.type_name == profile.key_type
  key_raw = key_column.physical_values
  if profile.key_type == "String"
    raise "W108 writer input key bytes differ" unless key_raw.as(Array(String)) == entries.map { |entry| entry.key.as(String) }
  else
    raise "W108 writer input key codes differ" unless key_raw.as(Array(UInt64)) == entries.map { |entry| entry.key.as(UInt64) }
  end
  expected_names = ["left.code", "left.note", "right.code", "right.state"]
  expected_types = ["UInt64", "Nullable(String)", "DateTime64(9, 'America/New_York')", "Nullable(Enum8('negative' = -7, 'positive' = 4))"]
  raise "W108 writer input leaf order differs" unless columns.map(&.name) == expected_names && columns.map(&.type_name) == expected_types
  columns.each_with_index do |column, field_index|
    field = expected_names[field_index]
    fragments = w108g_field_fragments(profile, field, true)
    raise "W108 writer input leaf length differs for #{field}" unless column.size == entries.size
    entries.size.times do |index|
      w108g_assert_bytes(w108g_column_fragment(column, field, index), fragments[index], "independent writer input #{field}[#{index}]")
    end
    if column.leaf_type.nullable?
      mask = w108g_expected_masks(profile, field, 0, entries.size)
      raise "W108 writer input mask differs for #{field}" unless column.null_map.try(&.bytes) == mask
    else
      raise "W108 writer input unexpectedly has a mask for #{field}" if column.null_map
    end
  end
  puts "PASS #{profile.name}: writer inputs match independent key/value carriers and exact NULL masks"
  nil
end

def w108g_writer_part(profile : W108GProfile, destination : String) : String
  key_column, columns = w108g_writer_columns(profile)
  w108g_assert_writer_input(profile, key_column, columns)
  raise "refusing existing W108 writer target: #{destination}" if File.exists?(destination) || File.symlink?(destination)
  FileUtils.mkdir_p(File.dirname(destination))
  CrystalClick::WidePartWriter.write_uint64_map_tuple_part(
    destination,
    "pk",
    profile.keys.to_unsafe.to_slice(profile.keys.size),
    "payload",
    profile.type_name,
    profile.row_sizes.to_unsafe.to_slice(profile.row_sizes.size),
    key_column,
    columns,
    2
  )
end

def w108g_run_reader(binary : String, store : String, map_settings : String) : Nil
  w108g_profiles.each do |profile|
    puts "PROFILE reader #{profile.name}: stock source, fresh ATTACH, typed and consumer checks"
    source = w108g_stock_seed(binary, store, profile, map_settings)
    attached = w108g_attach(binary, store, profile, source, map_settings)
    w108g_assert_typed(attached, profile, "W108G reader #{profile.name} attached stock")
    w108g_assert_consumers(attached, profile, "W108G reader #{profile.name} consumers")
  end
  puts "PASS W108 GREEN reader: 5 stock profiles, 2 key families, mixed + whole-empty + external PK zero; exact source/ATTACH and typed consumers"
  nil
end

def w108g_run_writer(binary : String, store : String, map_settings : String) : Nil
  w108g_profiles.each do |profile|
    puts "PROFILE writer #{profile.name}: stock seed, independent Crystal input, fresh stock ATTACH"
    stock = w108g_stock_seed(binary, store, profile, map_settings)
    w108g_assert_typed(stock, profile, "W108G writer #{profile.name} stock seed")
    source = File.join(store, "writer-parts", profile.name)
    part = w108g_writer_part(profile, source)
    w108g_assert_layout(part, profile, "W108G writer #{profile.name} Crystal part", true)
    writer_table = "#{profile.attached_table}_writer"
    attached = w108g_attach(binary, store, profile, part, map_settings, writer_table, true)
    w108g_assert_typed(attached, profile, "W108G writer #{profile.name} ATTACHED", true)
    w108g_assert_consumers(attached, profile, "W108G writer #{profile.name} consumers", true)
  end
  puts "PASS W108 GREEN writer: 5 stock-seeded writer profiles, 2 key families, mixed + whole-empty + external PK zero; exact writer bytes/marks and stock ATTACH"
  nil
end

def w108g_main : Nil
  mode = ARGV[0]? || raise "usage: probe_map_tuple_w108_green.cr --green-reader | --green-writer"
  raise "unknown W108 GREEN mode #{mode}" unless mode == "--green-reader" || mode == "--green-writer"
  binary = ENV["CLICKHOUSE_BIN"]? || "/Users/sergey/.local/bin/clickhouse"
  store = ENV["W108G_STORE"]? || raise "set W108G_STORE to a fresh isolated local store"
  catalog = ENV["W108G_CATALOG_ROOT"]? || raise "set W108G_CATALOG_ROOT to an isolated catalog root"
  raise "W108G_STORE must be empty before this phase" unless Dir.children(store).empty?
  raise "W108G_CATALOG_ROOT must be empty before this phase" unless Dir.children(catalog).empty?
  version_output = IO::Memory.new
  status = Process.run(binary, ["local", "--version"], output: version_output)
  version = version_output.to_s.strip
  raise "ClickHouse version probe failed: #{version.inspect}" unless status.success?
  raise "W108 GREEN requires ClickHouse #{W108G_STOCK_VERSION}; got #{version}" unless version.includes?(W108G_STOCK_VERSION)
  map_settings = w108g_basic_settings(binary, store)
  if mode == "--green-reader"
    w108g_run_reader(binary, store, map_settings)
  else
    w108g_run_writer(binary, store, map_settings)
  end
end

w108g_main
