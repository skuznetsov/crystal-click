# W109 paired Point GREEN oracle. All raw bytes, marks, PK indexes, metadata
# counters and RowBinary are derived from these literal fixtures, not from the
# Crystal reader/writer. Reader and writer phases use the pinned stock binary
# only as an independent storage producer/consumer.
require "json"
require "file_utils"
require "../src/crystal_click"

W109G_STOCK_VERSION = "26.7.1.1315"
W109G_TYPE          = "Point"
W109G_SETTINGS      = "index_granularity = 2, index_granularity_bytes = 10485760, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, default_compression_codec = 'LZ4'"

struct W109GProfile
  getter name : String
  getter keys : Array(UInt64)
  getter x_bits : Array(UInt64)
  getter y_bits : Array(UInt64)
  getter boundaries : Array(Int32)
  getter mark_rows : Array(UInt64)
  getter selected_begin : UInt64
  getter selected_end : UInt64
  getter ratio : String
  getter key_name : String
  getter value_name : String
  getter stock_no_statistics : Bool

  def initialize(
    @name : String,
    @keys : Array(UInt64),
    @x_bits : Array(UInt64),
    @y_bits : Array(UInt64),
    @boundaries : Array(Int32),
    @mark_rows : Array(UInt64),
    @selected_begin : UInt64,
    @selected_end : UInt64,
    @ratio : String,
    @key_name : String = "pk",
    @value_name : String = "payload",
    @stock_no_statistics : Bool = false,
  )
  end

  def data_mark_count : Int32
    mark_rows.size.to_i32 - 1
  end

  def rows : Int32
    keys.size.to_i32
  end

  def settings : String
    "#{W109G_SETTINGS}, ratio_of_defaults_for_sparse_serialization = #{@ratio}"
  end
end

# Mixed profile: duplicate and zero keys, duplicate Point rows, raw +0 defaults,
# signed zero, distinct quiet-NaN payloads, infinities, subnormals and signaling
# NaN bits. Equal-key rows are identical, avoiding unstable tie ordering.
W109G_MIXED = W109GProfile.new(
  "mixed_ieee",
  [0_u64, 0_u64, 2_u64, 3_u64, 4_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64],
  [
    0x8000_0000_0000_0000_u64, 0x8000_0000_0000_0000_u64,
    0x7ff8_0000_0000_1234_u64, 0x4002_0000_0000_0000_u64,
    0_u64, 0_u64, 0_u64, 0x7ff0_0000_0000_0000_u64,
    0x0000_0000_0000_0001_u64, 0x7ff0_0000_0000_0001_u64,
  ],
  [
    0_u64, 0_u64, 0x400c_0000_0000_0000_u64,
    0x7ff8_0000_0000_5678_u64, 0_u64, 0_u64,
    0x8000_0000_0000_0000_u64, 0xfff0_0000_0000_0000_u64,
    0x8000_0000_0000_0001_u64, 0xfff0_0000_0000_0042_u64,
  ],
  [0, 2, 4, 6, 8, 10],
  [2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 0_u64],
  2_u64, 7_u64, "0.9375"
)

# Every coordinate is raw positive-zero. For the stock source profile, ratio=1.0
# suppresses serialization column records; the GREEN oracle asserts columns=[]
# exactly. The Crystal writer profile still must emit its full counters.
W109G_ALL_DEFAULT = W109GProfile.new(
  "all_default",
  [0_u64, 0_u64, 1_u64, 2_u64, 2_u64],
  Array(UInt64).new(5, 0_u64), Array(UInt64).new(5, 0_u64),
  [0, 2, 4, 5], [2_u64, 2_u64, 1_u64, 0_u64],
  1_u64, 3_u64, "1.0", stock_no_statistics: true
)

# The same mixed IEEE rows under the always-Default ratio distinguish omitted
# statistics from the all-positive-zero data case. Physical streams and marks
# remain governed by the same literal fixture as the ordinary mixed profile.
W109G_MIXED_NO_STATISTICS = W109GProfile.new(
  "mixed_ieee_no_statistics",
  W109G_MIXED.keys,
  W109G_MIXED.x_bits,
  W109G_MIXED.y_bits,
  W109G_MIXED.boundaries,
  W109G_MIXED.mark_rows,
  W109G_MIXED.selected_begin,
  W109G_MIXED.selected_end,
  "1.0",
  stock_no_statistics: true
)

# Same literal mixed IEEE vectors, but the declaration is key-first and the
# names sort key-first too. This distinguishes name-sorted metadata from a
# hard-coded Point-before-key record sequence.
W109G_MIXED_RENAMED = W109GProfile.new(
  "mixed_renamed",
  W109G_MIXED.keys,
  W109G_MIXED.x_bits,
  W109G_MIXED.y_bits,
  W109G_MIXED.boundaries,
  W109G_MIXED.mark_rows,
  W109G_MIXED.selected_begin,
  W109G_MIXED.selected_end,
  W109G_MIXED.ratio,
  key_name: "a_key",
  value_name: "z_point",
)

W109G_PROFILES = [W109G_MIXED, W109G_ALL_DEFAULT, W109G_MIXED_NO_STATISTICS, W109G_MIXED_RENAMED]

struct W109GStream
  getter name : String
  getter fragments : Array(String)

  def initialize(@name : String, @fragments : Array(String))
  end
end

def w109g_u64_le(value : UInt64) : String
  String.build do |output|
    8.times { |index| output.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
  end
end

def w109g_streams(profile : W109GProfile) : Array(W109GStream)
  [
    W109GStream.new(profile.key_name, profile.keys.map { |value| w109g_u64_le(value) }),
    W109GStream.new("#{profile.value_name}%2E1", profile.x_bits.map { |bits| w109g_u64_le(bits) }),
    W109GStream.new("#{profile.value_name}%2E2", profile.y_bits.map { |bits| w109g_u64_le(bits) }),
  ]
end

def w109g_expected_columns(profile : W109GProfile) : Array(String)
  ["columns format version: 1", "2 columns:", "`#{profile.key_name}` UInt64", "`#{profile.value_name}` #{W109G_TYPE}"]
end

def w109g_expected_substreams(profile : W109GProfile) : String
  [
    "columns substreams version: 1", "2 columns:",
    "1 substreams for column `#{profile.key_name}`:", "\t#{profile.key_name}",
    "2 substreams for column `#{profile.value_name}`:", "\t#{profile.value_name}%2E1", "\t#{profile.value_name}%2E2",
  ].join("\n") + "\n"
end

def w109g_expected_stock_marks(profile : W109GProfile, fragments : Array(String)) : Array({UInt64, UInt64, UInt64})
  profile.boundaries.map_with_index do |boundary, index|
    raw_offset = fragments[0, boundary].sum(&.bytesize).to_u64
    {0_u64, raw_offset, profile.mark_rows[index]}
  end.to_a
end

def w109g_lz4_literal_frame_size(raw_size : Int32) : UInt64
  raise "writer mark fixture has an empty frame" if raw_size <= 0
  extensions = raw_size < 15 ? 0 : ((raw_size - 15) // 255) + 1
  # 16-byte ClickHouse checksum, 9-byte LZ4 frame header, one literal token,
  # raw literal bytes and independent literal-length extension bytes.
  (25 + 1 + raw_size + extensions).to_u64
end

def w109g_expected_writer_marks(profile : W109GProfile, fragments : Array(String)) : Array({UInt64, UInt64, UInt64})
  marks = [] of {UInt64, UInt64, UInt64}
  compressed_offset = 0_u64
  profile.data_mark_count.times do |mark|
    first = profile.boundaries[mark]
    after = profile.boundaries[mark + 1]
    count = after - first
    raise "writer mark schedule mismatch at #{mark}" unless count.to_u64 == profile.mark_rows[mark]
    raw = fragments[first, count].join
    marks << {compressed_offset, 0_u64, count.to_u64}
    compressed_offset += w109g_lz4_literal_frame_size(raw.bytesize) unless raw.empty?
  end
  marks << {compressed_offset, 0_u64, 0_u64}
  marks
end

class W109GByteMismatchError < Exception
end

def w109g_assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual == expected
  limit = Math.min(actual.bytesize, expected.bytesize)
  difference = 0
  while difference < limit && actual.to_slice[difference] == expected.to_slice[difference]
    difference += 1
  end
  got = difference < actual.bytesize ? actual.to_slice[difference].to_s(16).rjust(2, '0') : "<eof>"
  wanted = difference < expected.bytesize ? expected.to_slice[difference].to_s(16).rjust(2, '0') : "<eof>"
  raise W109GByteMismatchError.new("#{label}: expected #{expected.bytesize} bytes, got #{actual.bytesize}; first diff #{difference}: expected #{wanted}, got #{got}")
end

def w109g_seeded_comparator(actual : String, expected : String, label : String) : Nil
  raise "#{label}: actual differs from independent fixture bytes" unless actual == expected
  raise "#{label}: cannot seed byte drift with empty stream" if expected.empty?
  damaged = String.new(expected.to_slice)
  damaged.to_unsafe[0] = damaged.to_slice[0] ^ 0x01_u8
  begin
    w109g_assert_bytes(actual, damaged, label)
    raise "#{label}: comparator accepted seeded one-byte drift"
  rescue ex : W109GByteMismatchError
  end
  puts "PASS #{label}: seeded wrong-byte comparator control"
end

def w109g_run(binary : String, store : String, query : String, input : IO? = nil) : String
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

def w109g_create_table(binary : String, store : String, table : String, profile : W109GProfile) : Nil
  w109g_run(binary, store, "CREATE TABLE default.#{table} (#{profile.key_name} UInt64, #{profile.value_name} #{W109G_TYPE}) ENGINE = MergeTree ORDER BY #{profile.key_name} SETTINGS #{profile.settings}")
  nil
end

def w109g_expected_rowbinary(profile : W109GProfile, indexes : Array(Int32)) : String
  String.build do |output|
    indexes.each do |index|
      output << w109g_u64_le(profile.keys[index])
      output << w109g_u64_le(profile.x_bits[index])
      output << w109g_u64_le(profile.y_bits[index])
    end
  end
end

def w109g_all_indexes(profile : W109GProfile) : Array(Int32)
  (0...profile.rows).map(&.to_i32).to_a
end

def w109g_selected_indexes(profile : W109GProfile) : Array(Int32)
  profile.keys.each_with_index.select { |key, _index| key >= profile.selected_begin && key < profile.selected_end }
    .map { |_key, index| index.to_i32 }.to_a
end

def w109g_insert(binary : String, store : String, table : String, profile : W109GProfile) : Nil
  input = IO::Memory.new(w109g_expected_rowbinary(profile, w109g_all_indexes(profile)).to_slice)
  w109g_run(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", input)
  nil
end

def w109g_part_path(binary : String, store : String, table : String, profile : W109GProfile) : String
  rows = w109g_run(binary, store, "SELECT path, part_type, rows FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines.map(&.strip).reject(&.empty?)
  raise "#{table}: expected one #{profile.rows}-row Wide part, got #{rows.inspect}" unless rows.size == 1
  columns = rows[0].split('\t')
  raise "#{table}: malformed/non-Wide part #{rows[0].inspect}" unless columns.size == 3 && columns[1] == "Wide" && columns[2] == profile.rows.to_s
  columns[0]
end

def w109g_raw_stream(part : String, name : String) : String
  encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(name)}.bin")).to_slice
  String.new(CrystalClick::CompressedBlock.decode_all(encoded))
end

def w109g_actual_marks(part : String, stream : String) : Array({UInt64, UInt64, UInt64})
  bytes = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  mark_size = CrystalClick::WidePart::MARK_SIZE
  raise "#{stream}: partial .mrk2 record" unless bytes.size % mark_size == 0
  Array({UInt64, UInt64, UInt64}).new(bytes.size // mark_size) do |index|
    offset = index * mark_size
    fields = Array(UInt64).new(3) do |field|
      start = offset + field * 8
      8.times.reduce(0_u64) { |value, byte| value | (bytes[start + byte].to_u64 << (byte * 8)) }
    end
    {fields[0], fields[1], fields[2]}
  end
end

def w109g_validate_counter(row : Hash(String, JSON::Any), defaults : Int32, rows : Int32, label : String, keys : Array(String) = ["kind", "num_defaults", "num_rows"]) : Nil
  expected_keys = keys.sort
  actual_keys = row.keys.sort
  raise "#{label}: exact metadata keys differ: #{actual_keys.inspect}" unless actual_keys == expected_keys
  raise "#{label}: kind differs" unless row["kind"]?.try(&.as_s) == "Default"
  raise "#{label}: expected #{rows} rows, got #{row["num_rows"]?.try(&.as_i).inspect}" unless row["num_rows"]?.try(&.as_i) == rows.to_i64
  raise "#{label}: expected #{defaults} defaults, got #{row["num_defaults"]?.try(&.as_i).inspect}" unless row["num_defaults"]?.try(&.as_i) == defaults.to_i64
end

def w109g_zero_count(values : Array(UInt64)) : Int32
  values.count { |bits| bits == 0_u64 }.to_i32
end

def w109g_point_default_count(profile : W109GProfile) : Int32
  profile.rows.times.count { |index| profile.x_bits[index] == 0_u64 && profile.y_bits[index] == 0_u64 }.to_i32
end

def w109g_assert_serialization(part : String, profile : W109GProfile, label : String, expect_no_statistics : Bool = false) : Nil
  info = JSON.parse(File.read(File.join(part, "serialization.json"))).as_h
  expected_envelope = ["columns", "propagate_types_serialization_versions_to_nested_types", "types_serialization_versions", "version"].sort
  raise "#{label}: serialization envelope differs" unless info.keys.sort == expected_envelope
  raise "#{label}: metadata version differs" unless info["version"]?.try(&.as_i) == 1_i64
  raise "#{label}: nested version propagation differs" unless info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  versions = info["types_serialization_versions"]?.try(&.as_h) || raise "#{label}: version map missing"
  raise "#{label}: exact version map differs: #{versions.to_json}" unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1_i64
  records = info["columns"]?.try(&.as_a) || raise "#{label}: serialization records missing"
  if expect_no_statistics
    raise "#{label}: expected exact empty serialization columns, got #{records.to_json}" unless records.empty?
    puts "PASS #{label}: exact serialization envelope with no stock column records for #{profile.name}"
    return nil
  end
  names = records.map { |record| record.as_h["name"]?.try(&.as_s) || raise "#{label}: top-level record name missing" }
  expected_names = [profile.key_name, profile.value_name].sort
  raise "#{label}: exact name-sorted serializer order differs: #{names.inspect}" unless names == expected_names
  point_record = records.find { |record| record.as_h["name"]?.try(&.as_s) == profile.value_name } || raise "#{label}: Point serializer record missing"
  key_record = records.find { |record| record.as_h["name"]?.try(&.as_s) == profile.key_name } || raise "#{label}: key serializer record missing"
  point_hash = point_record.as_h
  key_hash = key_record.as_h
  w109g_validate_counter(point_hash, w109g_point_default_count(profile), profile.rows, "#{label} Point root", ["kind", "name", "num_defaults", "num_rows", "subcolumns"])
  children = point_hash["subcolumns"]?.try(&.as_a) || raise "#{label}: Point coordinate records missing"
  raise "#{label}: expected two unnamed Point coordinate records" unless children.size == 2
  w109g_validate_counter(children[0].as_h, w109g_zero_count(profile.x_bits), profile.rows, "#{label} Point X")
  w109g_validate_counter(children[1].as_h, w109g_zero_count(profile.y_bits), profile.rows, "#{label} Point Y")
  pk_defaults = profile.keys.count { |key| key == 0_u64 }.to_i32
  w109g_validate_counter(key_hash, pk_defaults, profile.rows, "#{label} primary key", ["kind", "name", "num_defaults", "num_rows"])
  puts "PASS #{label}: exact recursive Default metadata counters for #{profile.name}"
end

def w109g_assert_layout(part : String, profile : W109GProfile, writer_profile : Bool, label : String) : Nil
  actual_columns = File.read(File.join(part, "columns.txt")).lines.map(&.strip)
  raise "#{label}: exact columns.txt differs: #{actual_columns.inspect}" unless actual_columns == w109g_expected_columns(profile)
  actual_substreams = File.read(File.join(part, "columns_substreams.txt"))
  expected_substreams = w109g_expected_substreams(profile)
  raise "#{label}: exact Point stream topology/order differs:\nexpected:\n#{expected_substreams}actual:\n#{actual_substreams}" unless actual_substreams == expected_substreams
  raise "#{label}: LZ4 codec differs" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"
  raise "#{label}: metadata_version differs" unless File.read(File.join(part, "metadata_version.txt")) == "0"
  raise "#{label}: count differs" unless File.read(File.join(part, "count.txt")) == profile.rows.to_s

  streams = w109g_streams(profile)
  expected_files = ["checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt", "default_compression_codec.txt", "metadata_version.txt", "primary.idx", "serialization.json"]
  streams.each do |stream|
    base = CrystalClick::StreamName.hash(stream.name)
    expected_files << "#{base}.bin" << "#{base}.mrk2"
  end
  actual_files = Dir.children(part).sort
  raise "#{label}: exact file inventory differs (missing=#{(expected_files - actual_files).sort.inspect}, extra=#{(actual_files - expected_files).sort.inspect})" unless actual_files == expected_files.sort
  checksums = CrystalClick::PartChecksums.open(part)
  checksum_files = expected_files - ["checksums.txt", "columns.txt", "columns_substreams.txt", "default_compression_codec.txt", "metadata_version.txt"]
  raise "#{label}: exact checksum inventory differs" unless checksums.entries.keys.sort == checksum_files.sort
  checksums.entries.each_key { |name| checksums.validate_selected_entries(part, name) }

  expected_pk = profile.boundaries[0, profile.boundaries.size - 1].map { |row| w109g_u64_le(profile.keys[row]) }
  expected_pk << w109g_u64_le(profile.keys.last)
  primary = File.read(File.join(part, "primary.idx"))
  w109g_assert_bytes(primary, expected_pk.join, "#{label} independent primary.idx")
  w109g_seeded_comparator(primary, expected_pk.join, "#{label} primary.idx")

  streams.each do |stream|
    expected_raw = stream.fragments.join
    actual_raw = w109g_raw_stream(part, stream.name)
    w109g_assert_bytes(actual_raw, expected_raw, "#{label} #{stream.name} raw bytes")
    expected_marks = writer_profile ? w109g_expected_writer_marks(profile, stream.fragments) : w109g_expected_stock_marks(profile, stream.fragments)
    actual_marks = w109g_actual_marks(part, stream.name)
    raise "#{label} #{stream.name}: exact mark tuples differ; expected #{expected_marks.inspect}, got #{actual_marks.inspect}" unless actual_marks == expected_marks
    if stream.name == "#{profile.value_name}%2E1"
      w109g_seeded_comparator(actual_raw, expected_raw, "#{label} X coordinate")
    end
  end
  w109g_assert_serialization(part, profile, label, expect_no_statistics: profile.stock_no_statistics && !writer_profile)
  puts "PASS #{label}: exact Point streams, #{writer_profile ? "independently calculated per-mark frames" : "stock adaptive marks"}, checksums and raw IEEE bits"
end

def w109g_check_table(binary : String, store : String, table : String, part : String) : Nil
  actual = w109g_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  expected = "#{File.basename(part.chomp("/"))}\t1"
  raise "#{table}: CHECK TABLE must return part and 1, got #{actual.inspect}" unless actual == expected
  puts "PASS #{table}: CHECK TABLE result exactly 1"
end

def w109g_assert_rowbinary(binary : String, store : String, table : String, profile : W109GProfile, label : String) : Nil
  full = w109g_run(binary, store, "SELECT #{profile.key_name}, #{profile.value_name} FROM default.#{table} ORDER BY #{profile.key_name} FORMAT RowBinary")
  w109g_assert_bytes(full, w109g_expected_rowbinary(profile, w109g_all_indexes(profile)), "#{label} full RowBinary")
  selected = w109g_run(binary, store, "SELECT #{profile.key_name}, #{profile.value_name} FROM default.#{table} WHERE #{profile.key_name} >= #{profile.selected_begin} AND #{profile.key_name} < #{profile.selected_end} ORDER BY #{profile.key_name} FORMAT RowBinary")
  w109g_assert_bytes(selected, w109g_expected_rowbinary(profile, w109g_selected_indexes(profile)), "#{label} selected-PK RowBinary")
  puts "PASS #{label}: literal full and selected-PK RowBinary"
end

def w109g_attach(binary : String, store : String, table : String, profile : W109GProfile, source_part : String) : String
  w109g_create_table(binary, store, table, profile)
  data_path = w109g_run(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  raise "#{table}: data path missing" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(source_part, File.join(detached, "all_1_1_0"))
  w109g_run(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  w109g_part_path(binary, store, table, profile)
end

def w109g_qualify_stock_part(binary : String, store : String, table : String, profile : W109GProfile, part : String, label : String, writer_profile : Bool = false) : Nil
  actual_schema = w109g_run(binary, store, "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw").lines.map(&.strip)
  raise "#{label}: exact declarations differ: #{actual_schema.inspect}" unless actual_schema == ["#{profile.key_name} UInt64", "#{profile.value_name} Point"]
  w109g_assert_layout(part, profile, writer_profile, label)
  w109g_check_table(binary, store, table, part)
  w109g_assert_rowbinary(binary, store, table, profile, label)
  nil
end

def w109g_read_expected(profile : W109GProfile, first_row : Int32, count : Int32) : Array(CrystalClick::WidePointValue)
  Array(CrystalClick::WidePointValue).new(count) do |offset|
    row = first_row + offset
    CrystalClick::WidePointValue.from_bits(profile.x_bits[row], profile.y_bits[row])
  end
end

def w109g_assert_values(actual : Array(CrystalClick::WidePointValue), expected : Array(CrystalClick::WidePointValue), label : String) : Nil
  raise "#{label}: value count differs: expected #{expected.size}, got #{actual.size}" unless actual.size == expected.size
  actual.each_with_index do |value, index|
    wanted = expected[index]
    unless value.x_bits == wanted.x_bits && value.y_bits == wanted.y_bits
      raise "#{label}[#{index}]: expected bits (#{wanted.x_bits.to_s(16)}, #{wanted.y_bits.to_s(16)}), got (#{value.x_bits.to_s(16)}, #{value.y_bits.to_s(16)})"
    end
  end
end

def w109g_assert_typed_read(profile : W109GProfile, part_path : String, label : String) : Nil
  part = CrystalClick::WidePart.open_typed(part_path, profile.value_name)
  raise "#{label}: exact typed identity differs: #{part.column_type.inspect}" unless part.column_type == "Point"
  full = part.read_point_mark_range(profile.value_name, 0, profile.data_mark_count)
  w109g_assert_values(full, w109g_read_expected(profile, 0, profile.rows), "#{label} full selected range")

  # Marks 1 and 2 cover exactly two granules. This selected range checks a
  # nonzero raw source-row origin without deriving expected bits from the API.
  if profile.data_mark_count >= 3
    selected = part.read_point_mark_range(profile.value_name, 1, 2)
    first_row = profile.boundaries[1]
    count = profile.boundaries[3] - first_row
    w109g_assert_values(selected, w109g_read_expected(profile, first_row, count), "#{label} selected mark range")
  end

  seen = 0
  part.each_point_mark_range(profile.value_name, 0, profile.data_mark_count) do |values, mark_index|
    first_row = profile.boundaries[mark_index]
    count = profile.boundaries[mark_index + 1] - first_row
    w109g_assert_values(values, w109g_read_expected(profile, first_row, count), "#{label} lazy mark #{mark_index}")
    seen += 1
  end
  raise "#{label}: lazy iterator yielded #{seen} marks, expected #{profile.data_mark_count}" unless seen == profile.data_mark_count
  puts "PASS #{label}: exact identity, full/selected raw-bit reads and each-mark lazy reads"
end

def w109g_stock_seed(binary : String, store : String, table : String, profile : W109GProfile) : String
  w109g_create_table(binary, store, table, profile)
  w109g_insert(binary, store, table, profile)
  w109g_part_path(binary, store, table, profile)
end

def w109g_run_reader(binary : String, store : String) : Nil
  profiles = W109G_PROFILES
  attached = [] of {W109GProfile, String}
  profiles.each do |profile|
    source = w109g_stock_seed(binary, store, "w109g_reader_#{profile.name}_source", profile)
    w109g_qualify_stock_part(binary, store, "w109g_reader_#{profile.name}_source", profile, source, "W109 reader stock source #{profile.name}")
    attached_part = w109g_attach(binary, store, "w109g_reader_#{profile.name}_attached", profile, source)
    w109g_qualify_stock_part(binary, store, "w109g_reader_#{profile.name}_attached", profile, attached_part, "W109 reader fresh ATTACH #{profile.name}")
    attached << {profile, attached_part}
  end
  attached.each do |profile, part|
    w109g_assert_typed_read(profile, part, "W109 typed stock #{profile.name}")
  end
  puts "PASS W109 --green-reader: #{attached.size} profiles, source and fresh ATTACH each CHECK=1 before typed reads"
  nil
end

def w109g_writer_values(profile : W109GProfile) : Array(CrystalClick::WidePointValue)
  Array(CrystalClick::WidePointValue).new(profile.rows) do |index|
    CrystalClick::WidePointValue.from_bits(profile.x_bits[index], profile.y_bits[index])
  end
end

def w109g_run_writer(binary : String, store : String) : Nil
  profiles = W109G_PROFILES
  profiles.each do |profile|
    parent = File.join(store, "w109g_writer_#{profile.name}")
    FileUtils.mkdir_p(parent)
    output_part = File.join(parent, "all_1_1_0")
    values = w109g_writer_values(profile)
    actual_path = CrystalClick::WidePartWriter.write_uint64_point_pair(
      output_part, profile.key_name, profile.keys.to_unsafe.to_slice(profile.keys.size),
      profile.value_name, values.to_unsafe.to_slice(values.size), rows_per_mark: 2
    )
    raise "W109 writer returned a different path" unless actual_path == output_part
    w109g_assert_layout(output_part, profile, true, "W109 Crystal writer #{profile.name}")
    attached = w109g_attach(binary, store, "w109g_writer_#{profile.name}_attached", profile, output_part)
    w109g_qualify_stock_part(binary, store, "w109g_writer_#{profile.name}_attached", profile, attached, "W109 writer stock ATTACH #{profile.name}", writer_profile: true)
    w109g_assert_typed_read(profile, attached, "W109 typed writer roundtrip #{profile.name}")
  end
  puts "PASS W109 --green-writer: #{profiles.size} independently qualified writer profiles, fresh ATTACH CHECK=1 and literal RowBinary"
  nil
end

binary = ENV["CLICKHOUSE_BIN"]? || raise "set CLICKHOUSE_BIN to pinned ClickHouse 26.7.1.1315"
store = ENV["W109G_STORE"]? || raise "set W109G_STORE to an empty temporary ClickHouse store"
unless store.starts_with?("/private/tmp/") || store.starts_with?("/tmp/")
  raise "refusing non-temporary W109G_STORE path: #{store}"
end
if Dir.exists?(store)
  raise "W109G_STORE must be empty: #{store}" unless Dir.empty?(store)
else
  Dir.mkdir_p(store)
end
mode = ARGV.shift? || raise "usage: reader | writer"
mode = case mode
       when "reader", "--green-reader" then "reader"
       when "writer", "--green-writer" then "writer"
       else                                 raise "usage: reader | writer"
       end
raise "usage: reader | writer" unless mode == "reader" || mode == "writer"
raise "unexpected extra arguments" unless ARGV.empty?

version_output = IO::Memory.new
version_status = Process.run(binary, ["local", "--version"], output: version_output)
raise "could not read ClickHouse local version" unless version_status.success?
expected_version = "ClickHouse local version #{W109G_STOCK_VERSION} (official build)."
raise "W109 requires #{expected_version}, got #{version_output.to_s.strip}" unless version_output.to_s.strip == expected_version
W109G_PROFILES.each do |profile|
  expects_no_statistics = profile.name == "all_default" || profile.name == "mixed_ieee_no_statistics"
  raise "#{profile.name}: no-statistics expectation differs from the explicit stock profiles" unless profile.stock_no_statistics == expects_no_statistics
  raise "#{profile.name}: Point fixture vectors are misaligned" unless profile.keys.size == profile.x_bits.size && profile.x_bits.size == profile.y_bits.size
  raise "#{profile.name}: marks do not include terminal empty record" unless profile.mark_rows.last == 0_u64 && profile.mark_rows.size == profile.boundaries.size
  raise "#{profile.name}: boundary row count mismatch" unless profile.boundaries.last == profile.rows
end
puts "Pinned stock consumer: #{version_output.to_s.strip}"

case mode
when "reader"
  w109g_run_reader(binary, store)
when "writer"
  w109g_run_writer(binary, store)
end
