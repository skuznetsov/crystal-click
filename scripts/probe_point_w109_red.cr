# W109 stock-first RED probe for the custom Point data type. Expected IEEE
# coordinate bytes, mark boundaries, primary index and RowBinary are derived
# from the literal fixture, not from the Crystal reader or writer. The Point
# stream names and recursive serialization-info envelope are source-informed
# predictions and remain strict pinned-stock assertions until qualified.
require "json"
require "file_utils"
require "../src/crystal_click"

W109_STOCK_VERSION = "26.7.1.1315"
W109_TYPE          = "Point"
W109_SOURCE_TABLE  = "w109_point_source"
W109_ATTACH_TABLE  = "w109_point_attached"
W109_SETTINGS      = "index_granularity = 2, index_granularity_bytes = 10485760, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, ratio_of_defaults_for_sparse_serialization = 0.9375, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, default_compression_codec = 'LZ4'"

# Two identical rows for each repeated external key avoid nondeterministic tie
# ordering in RowBinary while still exercising duplicate and zero PK values.
# Float64 values are stored as raw IEEE bit patterns so NaN payloads and signed
# zero remain independently testable without arithmetic Float equality.
W109_KEYS = [0_u64, 0_u64, 2_u64, 3_u64, 4_u64, 4_u64, 5_u64]
W109_X_BITS = [
  0x8000_0000_0000_0000_u64, # -0.0
  0x8000_0000_0000_0000_u64, # duplicate-key tie row, identical Point
  0x7ff8_0000_0000_1234_u64, # quiet NaN with X-specific payload
  0x4002_0000_0000_0000_u64, # 2.25
  0x0000_0000_0000_0000_u64, # all-default Point row
  0x0000_0000_0000_0000_u64, # duplicate-key tie row, identical Point
  0x0000_0000_0000_0000_u64, # +0.0
]
W109_Y_BITS = [
  0x0000_0000_0000_0000_u64, # +0.0
  0x0000_0000_0000_0000_u64, # duplicate-key tie row, identical Point
  0x400c_0000_0000_0000_u64, # 3.5
  0x7ff8_0000_0000_5678_u64, # quiet NaN with distinct Y-specific payload
  0x0000_0000_0000_0000_u64, # all-default Point row
  0x0000_0000_0000_0000_u64, # duplicate-key tie row, identical Point
  0x8000_0000_0000_0000_u64, # -0.0 opposite to X
]
W109_BOUNDARIES = [0, 2, 4, 6, 7]
W109_MARK_ROWS  = [2_u64, 2_u64, 2_u64, 1_u64, 0_u64]
W109_SELECTED   = 2_u64...5_u64

class W109ByteMismatchError < Exception
end

struct W109Stream
  getter name : String
  getter fragments : Array(String)

  def initialize(@name : String, @fragments : Array(String))
  end
end

def w109_u64_le(value : UInt64) : String
  String.build do |output|
    8.times { |index| output.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
  end
end

def w109_streams : Array(W109Stream)
  [
    W109Stream.new("pk", W109_KEYS.map { |value| w109_u64_le(value) }),
    W109Stream.new("payload%2E1", W109_X_BITS.map { |bits| w109_u64_le(bits) }),
    W109Stream.new("payload%2E2", W109_Y_BITS.map { |bits| w109_u64_le(bits) }),
  ]
end

def w109_expected_columns : Array(String)
  ["columns format version: 1", "2 columns:", "`pk` UInt64", "`payload` #{W109_TYPE}"]
end

def w109_expected_substreams : String
  lines = [
    "columns substreams version: 1",
    "2 columns:",
    "1 substreams for column `pk`:",
    "\tpk",
    "2 substreams for column `payload`:",
    "\tpayload%2E1",
    "\tpayload%2E2",
  ]
  lines.join("\n") + "\n"
end

def w109_expected_marks(fragments : Array(String)) : Array({UInt64, UInt64, UInt64})
  W109_BOUNDARIES.map_with_index do |boundary, index|
    decompressed_offset = fragments[0, boundary].sum(&.bytesize).to_u64
    {0_u64, decompressed_offset, W109_MARK_ROWS[index]}
  end.to_a
end

def w109_actual_marks(part : String, stream : String) : Array({UInt64, UInt64, UInt64})
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

def w109_assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual == expected
  limit = Math.min(actual.bytesize, expected.bytesize)
  difference = 0
  while difference < limit && actual.to_slice[difference] == expected.to_slice[difference]
    difference += 1
  end
  got = difference < actual.bytesize ? actual.to_slice[difference].to_s(16).rjust(2, '0') : "<eof>"
  wanted = difference < expected.bytesize ? expected.to_slice[difference].to_s(16).rjust(2, '0') : "<eof>"
  raise W109ByteMismatchError.new("#{label}: expected #{expected.bytesize} bytes, got #{actual.bytesize}; first diff #{difference}: expected #{wanted}, got #{got}")
end

def w109_seeded_comparator(actual : String, expected : String, label : String) : Nil
  raise "#{label}: fixture differs from independent expected bytes" unless actual == expected
  raise "#{label}: cannot seed an empty byte control" if expected.empty?
  damaged = String.new(expected.to_slice)
  damaged.to_unsafe[0] = damaged.to_slice[0] ^ 0x01_u8
  begin
    w109_assert_bytes(actual, damaged, label)
    raise "#{label}: comparator accepted seeded one-byte drift"
  rescue ex : W109ByteMismatchError
  end
  puts "PASS #{label}: seeded wrong-byte comparator control"
end

def w109_run(binary : String, store : String, query : String, input : IO? = nil) : String
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

def w109_create_table(binary : String, store : String, table : String) : Nil
  w109_run(binary, store, "CREATE TABLE default.#{table} (pk UInt64, payload #{W109_TYPE}) ENGINE = MergeTree ORDER BY pk SETTINGS #{W109_SETTINGS}")
  nil
end

def w109_expected_rowbinary(indexes : Array(Int32)) : String
  String.build do |output|
    indexes.each do |index|
      output << w109_u64_le(W109_KEYS[index])
      output << w109_u64_le(W109_X_BITS[index])
      output << w109_u64_le(W109_Y_BITS[index])
    end
  end
end

def w109_insert(binary : String, store : String, table : String) : Nil
  input = IO::Memory.new(w109_expected_rowbinary((0...W109_KEYS.size).map(&.to_i32)).to_slice)
  w109_run(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", input)
  nil
end

def w109_part_path(binary : String, store : String, table : String) : String
  rows = w109_run(binary, store, "SELECT path, part_type, rows FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines.map(&.strip).reject(&.empty?)
  raise "#{table}: expected exactly one seven-row Wide part, got #{rows.inspect}" unless rows.size == 1
  columns = rows[0].split('\t')
  raise "#{table}: malformed/non-Wide system.parts row #{rows[0].inspect}" unless columns.size == 3 && columns[1] == "Wide" && columns[2] == W109_KEYS.size.to_s
  columns[0]
end

def w109_assert_schema(binary : String, store : String, table : String) : Nil
  actual = w109_run(binary, store, "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw").lines.map(&.strip)
  expected = ["pk UInt64", "payload #{W109_TYPE}"]
  raise "#{table}: exact declarations differ; expected #{expected.inspect}, got #{actual.inspect}" unless actual == expected
end

def w109_raw_stream(part : String, name : String) : String
  encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(name)}.bin")).to_slice
  String.new(CrystalClick::CompressedBlock.decode_all(encoded))
end

def w109_validate_counter(row : Hash(String, JSON::Any), expected_defaults : Int32, expected_rows : Int32, label : String, keys : Array(String) = ["kind", "num_defaults", "num_rows"]) : Nil
  actual_keys = row.keys.sort
  expected_keys = keys.sort
  raise "#{label}: exact serialization keys differ; expected #{expected_keys.inspect}, got #{actual_keys.inspect}" unless actual_keys == expected_keys
  raise "#{label}: expected Default kind, got #{row["kind"]?.try(&.as_s).inspect}" unless row["kind"]?.try(&.as_s) == "Default"
  raise "#{label}: expected #{expected_rows} rows, got #{row["num_rows"]?.try(&.as_i).inspect}" unless row["num_rows"]?.try(&.as_i) == expected_rows.to_i64
  raise "#{label}: expected #{expected_defaults} defaults, got #{row["num_defaults"]?.try(&.as_i).inspect}" unless row["num_defaults"]?.try(&.as_i) == expected_defaults.to_i64
end

def w109_assert_serialization(part : String, label : String) : Nil
  info = JSON.parse(File.read(File.join(part, "serialization.json"))).as_h
  puts "OBSERVED #{label} serialization.json=#{info.to_json}"
  expected_envelope = ["columns", "propagate_types_serialization_versions_to_nested_types", "types_serialization_versions", "version"].sort
  raise "#{label}: serialization envelope differs: #{info.keys.sort.inspect}" unless info.keys.sort == expected_envelope
  raise "#{label}: serialization envelope version differs" unless info["version"]?.try(&.as_i) == 1
  raise "#{label}: type-version propagation differs" unless info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  versions = info["types_serialization_versions"]?.try(&.as_h) || raise "#{label}: type-version map missing"
  raise "#{label}: pinned stock serializer-version map differs: #{versions.to_json}" unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1_i64
  records = info["columns"]?.try(&.as_a) || raise "#{label}: serialization records missing"
  names = records.map { |record| record.as_h["name"]?.try(&.as_s) || raise "#{label}: top-level serialization name missing" }
  raise "#{label}: recursive Point record roots/order differ: #{names.inspect}" unless names == ["payload", "pk"]

  point = records[0].as_h
  w109_validate_counter(point, 2, W109_KEYS.size, "#{label} Point root", ["kind", "name", "num_defaults", "num_rows", "subcolumns"])
  children = point["subcolumns"]?.try(&.as_a) || raise "#{label}: Point coordinate records missing"
  raise "#{label}: expected exactly the two unnamed Point coordinates" unless children.size == 2
  # ColumnVector::isDefaultAt compares floating values by exact IEEE bit
  # pattern (ColumnVector.h:292-311): -0 is not the +0 default. The fixture's
  # child and tuple defaults are therefore independently counted from bits.
  w109_validate_counter(children[0].as_h, 3, W109_KEYS.size, "#{label} Point X")
  w109_validate_counter(children[1].as_h, 4, W109_KEYS.size, "#{label} Point Y")
  # Stock serialization metadata counts the two literal UInt64 zero keys as
  # defaults, independently of the payload's tuple default conjunction.
  w109_validate_counter(records[1].as_h, 2, W109_KEYS.size, "#{label} primary key", ["kind", "name", "num_defaults", "num_rows"])
end

def w109_assert_layout(part : String, label : String) : Nil
  actual_columns = File.read(File.join(part, "columns.txt")).lines.map(&.strip)
  raise "#{label}: exact columns.txt declaration differs: #{actual_columns.inspect}" unless actual_columns == w109_expected_columns
  actual_substreams = File.read(File.join(part, "columns_substreams.txt"))
  raise "#{label}: exact Point child stream topology/order differs:\nexpected:\n#{w109_expected_substreams}actual:\n#{actual_substreams}" unless actual_substreams == w109_expected_substreams
  raise "#{label}: codec differs" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"
  raise "#{label}: metadata version differs" unless File.read(File.join(part, "metadata_version.txt")) == "0"
  raise "#{label}: row count differs" unless File.read(File.join(part, "count.txt")) == W109_KEYS.size.to_s

  streams = w109_streams
  expected_files = ["checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt", "default_compression_codec.txt", "metadata_version.txt", "primary.idx", "serialization.json"]
  streams.each do |stream|
    base = CrystalClick::StreamName.hash(stream.name)
    expected_files << "#{base}.bin" << "#{base}.mrk2"
  end
  actual_files = Dir.children(part).sort
  raise "#{label}: exact part file inventory differs (missing=#{(expected_files - actual_files).sort.inspect}, extra=#{(actual_files - expected_files).sort.inspect})" unless actual_files == expected_files.sort

  checksums = CrystalClick::PartChecksums.open(part)
  checksum_files = expected_files - ["checksums.txt", "columns.txt", "columns_substreams.txt", "default_compression_codec.txt", "metadata_version.txt"]
  raise "#{label}: exact checksum inventory differs" unless checksums.entries.keys.sort == checksum_files.sort
  checksums.entries.each_key { |name| checksums.validate_selected_entries(part, name) }

  # With compress_primary_key=0, MergeTreeDataPartWriterOnDisk persists the
  # PK mark-start values plus the terminal last-key value as plain UInt64s.
  pk_indexes = W109_BOUNDARIES[0, W109_BOUNDARIES.size - 1].map { |boundary| w109_u64_le(W109_KEYS[boundary]) }
  pk_indexes << w109_u64_le(W109_KEYS.last)
  primary = File.read(File.join(part, "primary.idx"))
  primary_expected = pk_indexes.join
  w109_assert_bytes(primary, primary_expected, "#{label} independent primary.idx")
  w109_seeded_comparator(primary, primary_expected, "#{label} primary.idx")

  streams.each do |stream|
    expected_raw = stream.fragments.join
    actual_raw = w109_raw_stream(part, stream.name)
    w109_assert_bytes(actual_raw, expected_raw, "#{label} #{stream.name} raw physical bytes")
    w109_assert_bytes(actual_raw, stream.fragments.join, "#{label} #{stream.name} independently concatenated fragments")
    expected_marks = w109_expected_marks(stream.fragments)
    actual_marks = w109_actual_marks(part, stream.name)
    raise "#{label} #{stream.name}: exact mark tuples differ; expected #{expected_marks.inspect}, got #{actual_marks.inspect}" unless actual_marks == expected_marks
    if stream.name == "payload%2E1" || stream.name == "payload%2E2"
      w109_seeded_comparator(actual_raw, expected_raw, "#{label} #{stream.name}")
    end
  end
  w109_assert_serialization(part, label)
  puts "PASS #{label}: Point identity, two coordinate substreams, exact raw bits, adaptive marks, checksums, and recursive defaults"
end

def w109_check_table(binary : String, store : String, table : String, part : String) : Nil
  actual = w109_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  expected = "#{File.basename(part.chomp("/"))}\t1"
  raise "#{table}: CHECK TABLE did not return the qualified part and 1: #{actual.inspect}" unless actual == expected
end

def w109_assert_rowbinary(binary : String, store : String, table : String, label : String) : Nil
  full = w109_run(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w109_assert_bytes(full, w109_expected_rowbinary((0...W109_KEYS.size).map(&.to_i32)), "#{label} full RowBinary")
  selected_indexes = W109_KEYS.each_with_index.select { |key, _index| key >= W109_SELECTED.begin && key < W109_SELECTED.end }.map { |_key, index| index.to_i32 }.to_a
  selected = w109_run(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= #{W109_SELECTED.begin} AND pk < #{W109_SELECTED.end} ORDER BY pk FORMAT RowBinary")
  w109_assert_bytes(selected, w109_expected_rowbinary(selected_indexes), "#{label} selected-PK RowBinary")
  puts "PASS #{label}: independent full and selected RowBinary preserves X/Y order, NaN payloads and signed zeros"
end

def w109_attach(binary : String, store : String, source_part : String) : String
  w109_create_table(binary, store, W109_ATTACH_TABLE)
  data_path = w109_run(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{W109_ATTACH_TABLE}' FORMAT TSVRaw").strip
  raise "W109 ATTACH table has no data path" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(source_part, File.join(detached, "all_1_1_0"))
  w109_run(binary, store, "ALTER TABLE default.#{W109_ATTACH_TABLE} ATTACH PART 'all_1_1_0'")
  w109_part_path(binary, store, W109_ATTACH_TABLE)
end

def w109_expect_reader_red(part : String) : Nil
  begin
    CrystalClick::WidePart.open_typed(part, "payload")
  rescue ex : CrystalClick::UnsupportedFormatError
    raise "reader refused for an unrelated reason: #{ex.message}" unless ex.message == "unsupported exact typed column"
    puts "EXPECTED RED W109: fully stock-qualified Point refused by the current exact typed-type admission gate"
    return
  end
  raise "W109 RED failed: current typed reader admitted Point"
end

binary = ENV["CLICKHOUSE_BIN"]? || raise "set CLICKHOUSE_BIN to pinned ClickHouse 26.7.1.1315"
store = ENV["W109_STORE"]? || raise "set W109_STORE to a fresh temporary ClickHouse store"
unless store.starts_with?("/private/tmp/") || store.starts_with?("/tmp/")
  raise "refusing non-temporary W109_STORE path: #{store}"
end
if Dir.exists?(store)
  raise "W109_STORE must be empty: #{store}" unless Dir.empty?(store)
else
  Dir.mkdir_p(store)
end

version_output = IO::Memory.new
version_status = Process.run(binary, ["local", "--version"], output: version_output)
raise "could not read ClickHouse local version" unless version_status.success?
expected_version = "ClickHouse local version #{W109_STOCK_VERSION} (official build)."
raise "W109 requires #{expected_version}, got #{version_output.to_s.strip}" unless version_output.to_s.strip == expected_version
raise "Point fixture vectors are not row-aligned" unless W109_KEYS.size == W109_X_BITS.size && W109_X_BITS.size == W109_Y_BITS.size
raise "W109 mark schedule must end with a terminal empty mark" unless W109_BOUNDARIES.size == W109_MARK_ROWS.size && W109_MARK_ROWS.last == 0
puts "Stock oracle: #{version_output.to_s.strip}"

w109_create_table(binary, store, W109_SOURCE_TABLE)
w109_insert(binary, store, W109_SOURCE_TABLE)
source_part = w109_part_path(binary, store, W109_SOURCE_TABLE)
w109_assert_schema(binary, store, W109_SOURCE_TABLE)
w109_assert_layout(source_part, "W109 Point stock source")
w109_check_table(binary, store, W109_SOURCE_TABLE, source_part)
w109_assert_rowbinary(binary, store, W109_SOURCE_TABLE, "W109 Point stock source")

attached_part = w109_attach(binary, store, source_part)
w109_assert_schema(binary, store, W109_ATTACH_TABLE)
w109_assert_layout(attached_part, "W109 Point fresh ATTACH")
w109_check_table(binary, store, W109_ATTACH_TABLE, attached_part)
w109_assert_rowbinary(binary, store, W109_ATTACH_TABLE, "W109 Point fresh ATTACH")

# The only typed-reader call follows exact stock source and ATTACH qualification,
# literal independent coordinate and PK bytes/marks, CHECK=1, and RowBinary.
w109_expect_reader_red(attached_part)
puts "EXPECTED W109 RED: source and ATTACH stock certificates passed before typed Point refusal"
exit 1
