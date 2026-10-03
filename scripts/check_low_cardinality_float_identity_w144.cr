# W144 measures raw floating-point identity at Native ingestion, LC construction,
# and stock Wide-part persistence. It does not prescribe a canonicalization rule.
require "file_utils"
require "../src/crystal_click"

W144_SOURCE_REVISION    = "9007d227b64a3f8b667fc5258ceb2923f3cf477d"
W144_CLICKHOUSE_VERSION = "ClickHouse local version 26.10.1.1201 (official build)."
W144_RUNTIME_SHA256     = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
W144_BUILD_HASH         = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
W144_ORDER_A            = [0, 1, 2, 3, 4, 5, 0, 2, 1, 3, 4, 5]
W144_ORDER_B            = [3, 5, 1, 4, 2, 0, 3, 1, 5, 2, 4, 0]
W144_EXPECTED_ROWS      = 12
W144_EXPECTED_MARK_ROWS =  4
W144_MAX_FILE_BYTES     = 64_i64 * 1024 * 1024

class W144Mismatch < Exception
end

struct W144FloatFormat
  getter label : String
  getter native_type : String
  getter raw_unsigned_type : String
  getter byte_width : Int32
  getter key_hexes : Array(String)

  def initialize(@label : String, @native_type : String, @raw_unsigned_type : String,
                 @byte_width : Int32, @key_hexes : Array(String))
  end
end

struct W144IndexMark
  getter mark : Int32
  getter flags : UInt64
  getter width_code : UInt64
  getter occurrence_count : UInt64
  getter dictionary_offset : UInt64
  getter ids : Array(UInt64)

  def initialize(@mark : Int32, @flags : UInt64, @width_code : UInt64,
                 @occurrence_count : UInt64, @dictionary_offset : UInt64,
                 @ids : Array(UInt64))
  end
end

def w144_fail(message : String) : NoReturn
  raise W144Mismatch.new(message)
end

def w144_assert(condition : Bool, message : String) : Nil
  w144_fail(message) unless condition
end

def w144_formats : Array(W144FloatFormat)
  [
    W144FloatFormat.new("float32", "Float32", "UInt32", 4,
      ["00000000", "00000080", "0100c07f", "0200c0ff", "0000803f", "000000c0"]),
    W144FloatFormat.new("float64", "Float64", "UInt64", 8,
      ["0000000000000000", "0000000000000080", "010000000000f87f", "020000000000f8ff", "000000000000f03f", "00000000000000c0"]),
    W144FloatFormat.new("bfloat16", "BFloat16", "UInt16", 2,
      ["0000", "0080", "c17f", "c2ff", "803f", "00c0"]),
  ]
end

def w144_orders : Array(Tuple(String, Array(Int32)))
  [{"order-a", W144_ORDER_A}, {"order-b", W144_ORDER_B}]
end

def w144_read_bytes(path : String, label : String) : Bytes
  w144_assert(File.file?(path) && !File.symlink?(path), "#{label}: missing file or symlink")
  File.open(path, "rb") do |file|
    w144_assert(file.size <= W144_MAX_FILE_BYTES, "#{label}: input exceeds bounded 64 MiB evidence limit")
    bytes = Bytes.new(file.size.to_i32)
    file.read_fully(bytes)
    bytes
  end
end

def w144_hex_bytes(hex : String, label = "authored hex") : Bytes
  w144_assert(hex.bytesize.even?, "#{label}: odd hex length")
  source = hex.to_slice
  bytes = Bytes.new(source.size // 2, 0_u8)
  bytes.size.times do |index|
    high = case source[index * 2]
           when 48_u8..57_u8  then source[index * 2] - 48_u8
           when 65_u8..70_u8  then source[index * 2] - 55_u8
           when 97_u8..102_u8 then source[index * 2] - 87_u8
           else                    w144_fail("#{label}: non-hex byte")
           end
    low = case source[index * 2 + 1]
          when 48_u8..57_u8  then source[index * 2 + 1] - 48_u8
          when 65_u8..70_u8  then source[index * 2 + 1] - 55_u8
          when 97_u8..102_u8 then source[index * 2 + 1] - 87_u8
          else                    w144_fail("#{label}: non-hex byte")
          end
    bytes[index] = (high << 4) | low
  end
  bytes
end

def w144_hex(bytes : Bytes) : String
  String.build { |io| bytes.each { |byte| io << byte.to_s(16).rjust(2, '0') } }
end

def w144_u64_le(bytes : Bytes, offset : Int, label : String) : UInt64
  w144_assert(offset >= 0 && offset <= bytes.size - 8, "#{label}: UInt64 outside byte lane")
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (8 * index) }
  value
end

def w144_uint_le(bytes : Bytes, offset : Int, width : Int, label : String) : UInt64
  w144_assert(width == 1 || width == 2 || width == 4 || width == 8, "#{label}: invalid scalar width")
  w144_assert(offset >= 0 && offset <= bytes.size - width, "#{label}: integer outside byte lane")
  value = 0_u64
  width.times { |index| value |= bytes[offset + index].to_u64 << (8 * index) }
  value
end

def w144_push_uint_le(value : UInt64, width : Int, destination : Array(UInt8)) : Nil
  w144_assert(width == 1 || width == 2 || width == 4 || width == 8, "invalid Native integer width")
  width.times { |index| destination << ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

def w144_var_uint(value : UInt64, destination : Array(UInt8)) : Nil
  remaining = value
  while remaining >= 0x80_u64
    destination << ((remaining & 0x7f_u64).to_u8 | 0x80_u8)
    remaining >>= 7
  end
  destination << remaining.to_u8
end

def w144_native_string(value : String, destination : Array(UInt8)) : Nil
  w144_var_uint(value.bytesize.to_u64, destination)
  value.to_slice.each { |byte| destination << byte }
end

def w144_write_bytes(path : String, bytes : Bytes) : Nil
  w144_assert(!File.exists?(path) && !File.symlink?(path), "refusing to overwrite W144 evidence: #{path}")
  File.open(path, "wb") { |file| file.write(bytes) }
end

def w144_write_text(path : String, text : String) : Nil
  w144_assert(!File.exists?(path) && !File.symlink?(path), "refusing to overwrite W144 evidence: #{path}")
  File.open(path, "w") { |file| file << text }
end

def w144_bits_from_hex(hex : String) : UInt64
  bytes = w144_hex_bytes(hex)
  w144_uint_le(bytes, 0, bytes.size, "literal raw bits")
end

def w144_vector(format : W144FloatFormat, order : Array(Int32)) : Array(String)
  order.map do |key_id|
    w144_assert(key_id >= 0 && key_id < format.key_hexes.size, "invalid authored key id")
    format.key_hexes[key_id]
  end
end

def w144_native_prefix(columns : UInt64, rows : UInt64, destination : Array(UInt8)) : Nil
  w144_var_uint(columns, destination)
  w144_var_uint(rows, destination)
end

def w144_raw_native(format : W144FloatFormat, values : Array(String)) : Bytes
  w144_assert(values.size == W144_EXPECTED_ROWS, "raw Native vector must contain 12 rows")
  bytes = [] of UInt8
  w144_native_prefix(2_u64, values.size.to_u64, bytes)
  w144_native_string("k", bytes)
  w144_native_string("UInt64", bytes)
  values.size.times { |index| w144_push_uint_le(index.to_u64, 8, bytes) }
  w144_native_string("x", bytes)
  w144_native_string(format.native_type, bytes)
  values.each do |hex|
    key = w144_hex_bytes(hex, "#{format.label} raw Native key")
    w144_assert(key.size == format.byte_width, "#{format.label}: key byte width differs")
    key.each { |byte| bytes << byte }
  end
  Bytes.new(bytes.size) { |index| bytes[index] }
end

def w144_additional_native(format : W144FloatFormat, values : Array(String)) : Tuple(Bytes, Array(String), Array(UInt64))
  w144_assert(values.size == W144_EXPECTED_ROWS, "additional-only Native vector must contain 12 rows")
  unique = [] of String
  ids_by_key = Hash(String, UInt64).new
  ids = values.map do |hex|
    # Identity is the authored raw key byte string, never Float equality.
    if index = ids_by_key[hex]?
      index
    else
      index = unique.size.to_u64
      ids_by_key[hex] = index
      unique << hex
      index
    end
  end

  bytes = [] of UInt8
  w144_native_prefix(2_u64, values.size.to_u64, bytes)
  w144_native_string("k", bytes)
  w144_native_string("UInt64", bytes)
  values.size.times { |index| w144_push_uint_le(index.to_u64, 8, bytes) }
  w144_native_string("x", bytes)
  w144_native_string("LowCardinality(#{format.native_type})", bytes)
  w144_push_uint_le(1_u64, 8, bytes)     # LowCardinality shared-dictionary version 1.
  w144_push_uint_le(0x600_u64, 8, bytes) # additional keys + update, UInt8 indexes, no global dictionary.
  w144_push_uint_le(unique.size.to_u64, 8, bytes)
  unique.each do |hex|
    key = w144_hex_bytes(hex, "#{format.label} additional key")
    w144_assert(key.size == format.byte_width, "#{format.label}: additional key width differs")
    key.each { |byte| bytes << byte }
  end
  w144_push_uint_le(ids.size.to_u64, 8, bytes)
  ids.each { |id| w144_push_uint_le(id, 1, bytes) }
  {Bytes.new(bytes.size) { |index| bytes[index] }, unique, ids}
end

def w144_sql_bits(format : W144FloatFormat, column = "x") : String
  width = format.raw_unsigned_type
  "toString(reinterpretAs#{width}(#{column}))"
end

def w144_merge_tree_ddl(table : String, format : W144FloatFormat, lc : Bool) : String
  scalar = lc ? "LowCardinality(#{format.native_type})" : format.native_type
  "CREATE TABLE #{table} (k UInt64, x #{scalar}) ENGINE=MergeTree ORDER BY k SETTINGS index_granularity=4, index_granularity_bytes=10485760, enable_mixed_granularity_parts=1, min_rows_for_wide_part=0, min_bytes_for_wide_part=0, ratio_of_defaults_for_sparse_serialization=1.0, compress_marks=0, write_final_mark=1, min_compress_block_size=0, max_compress_block_size=4096, default_compression_codec='LZ4'"
end

def w144_store(output_root : String, label : String) : String
  path = File.join(output_root, "stores", label)
  w144_assert(!File.exists?(path) && !File.symlink?(path), "refusing to reuse W144 stock store: #{path}")
  Dir.mkdir(path)
  path
end

def w144_run(binary : String, store : String, native_type : String,
             input_path : String, query : String, label : String) : Tuple(Bool, String, String)
  args = [
    "local", "--path", store,
    "--input-format", "Native",
    "--structure", "k UInt64, x #{native_type}",
    "--allow_suspicious_low_cardinality_types=1",
    "--multiquery",
    "--query", query,
  ]
  output = IO::Memory.new
  error = IO::Memory.new
  status = File.open(input_path, "rb") do |input|
    Process.run(binary, args, input: input, output: output, error: error)
  end
  {status.success?, output.to_s, error.to_s}
end

def w144_parse_observations(output : String, expected_routes : Array(String), label : String) : Hash(String, Array(UInt64))
  rows_by_route = Hash(String, Array(Tuple(UInt64, UInt64))).new
  output.lines.map(&.strip).reject(&.empty?).each_with_index do |line, line_index|
    fields = line.split('\t')
    w144_assert(fields.size == 3, "#{label}: malformed TSVRaw line #{line_index}: #{line.inspect}")
    route = fields[0]
    w144_assert(expected_routes.includes?(route), "#{label}: unknown observation route #{route.inspect}")
    begin
      key = fields[1].to_u64
      bits = fields[2].to_u64
      rows_by_route[route] ||= [] of Tuple(UInt64, UInt64)
      rows_by_route[route] << {key, bits}
    rescue ex : ArgumentError
      w144_fail("#{label}: TSVRaw numeric parse failed on line #{line_index}: #{ex.message}")
    end
  end
  result = Hash(String, Array(UInt64)).new
  expected_routes.each do |route|
    rows = rows_by_route[route]?
    w144_assert(!rows.nil? && rows.size == W144_EXPECTED_ROWS, "#{label}: #{route} returned #{rows.try(&.size) || 0} rows, expected 12")
    actual = rows.not_nil!
    W144_EXPECTED_ROWS.times do |index|
      w144_assert(actual[index][0] == index.to_u64, "#{label}: #{route} row key #{actual[index][0]} at slot #{index}, expected #{index}")
    end
    result[route] = actual.map(&.[1])
  end
  result
end

def w144_assert_bits(actual : Array(UInt64), expected : Array(UInt64), label : String) : Nil
  w144_assert(actual.size == expected.size, "#{label}: row count #{actual.size} != expected #{expected.size}")
  actual.each_with_index do |bits, index|
    if bits != expected[index]
      w144_fail("#{label}: row #{index} raw bits expected 0x#{expected[index].to_s(16)}, got 0x#{bits.to_s(16)}")
    end
  end
end

def w144_expect_seeded_mismatch(actual : Array(UInt64), label : String) : Nil
  wrong = actual.dup
  w144_assert(!wrong.empty?, "#{label}: cannot seed mismatch for empty vector")
  wrong[0] ^= 1_u64
  begin
    w144_assert_bits(wrong, actual, "#{label} seeded payload-bit mismatch")
  rescue error : W144Mismatch
    puts "PASS W144 full-vector comparator rejected seeded one-bit mismatch: #{label}: #{error.message}"
    return
  end
  w144_fail("#{label}: seeded raw-bit mismatch escaped comparator")
end

def w144_decompressed(path : String, label : String) : Bytes
  compressed = w144_read_bytes(path, label)
  CrystalClick::CompressedBlock.decode_all(compressed, max_output_size: W144_MAX_FILE_BYTES)
end

def w144_lane_mark_file(part : String, basename : String, data_size : Int,
                        expected_prefix_size : Int, label : String) : Tuple(Bytes, Array(UInt64), String, Array(Tuple(UInt64, UInt64, UInt64)))
  data_name = w144_stream_filename(basename, "bin")
  data_path = File.join(part, data_name)
  name = w144_stream_filename(basename, "mrk2")
  marks_path = File.join(part, name)
  w144_assert(File.file?(data_path) && !File.symlink?(data_path), "#{label}: compressed stream missing or symlinked: #{data_name}")
  w144_assert(File.file?(marks_path) && !File.symlink?(marks_path), "#{label}: expected explicit uncompressed Wide mark file #{name}")
  compressed_size = File.size(data_path)
  mark_size = File.size(marks_path)
  w144_assert(compressed_size > 0 && compressed_size <= W144_MAX_FILE_BYTES, "#{label}: compressed stream size is outside the bounded profile")
  w144_assert(mark_size > 0 && mark_size <= 1024_i64 * 1024, "#{label}: mark file size is outside the bounded profile")
  bytes = w144_read_bytes(marks_path, "#{label} marks")
  stride = 24
  w144_assert(bytes.size % stride == 0, "#{label}: mark lane byte length is not a whole #{stride}-byte record")
  count = bytes.size // stride
  w144_assert(count == 4, "#{label}: expected 3 real marks plus final mark, found #{count} records")
  raw_marks = [] of Tuple(UInt64, UInt64, UInt64)
  count.times do |mark|
    compressed_offset = w144_u64_le(bytes, mark * stride, "#{label} compressed mark offset")
    decompressed_offset = w144_u64_le(bytes, mark * stride + 8, "#{label} decompressed mark offset")
    rows = w144_u64_le(bytes, mark * stride + 16, "#{label} mark row count")
    expected_rows = mark < 3 ? W144_EXPECTED_MARK_ROWS.to_u64 : 0_u64
    w144_assert(rows == expected_rows, "#{label}: mark #{mark} row count #{rows} != #{expected_rows}")
    raw_marks << {compressed_offset, decompressed_offset, rows}
  end
  limits = CrystalClick::CompressedStreamLimits.new(
    max_file_bytes: 64 * 1024 * 1024,
    max_mark_bytes: 1024 * 1024,
    max_frame_compressed_bytes: 16 * 1024 * 1024,
    max_frame_decompressed_bytes: 64 * 1024 * 1024,
    max_records: 100,
    max_decoded_bytes: 64 * 1024 * 1024,
    max_result_bytes: 64 * 1024 * 1024,
  )
  grid = CrystalClick::CompressedMarkReader.inspect(
    data_path,
    marks_path,
    compressed_size,
    mark_size,
    expected_prefix_size,
    CrystalClick::CompressedStreamBudget.new(limits)
  )
  w144_assert(grid.mark_count == 3, "#{label}: inspected mark grid has #{grid.mark_count} rows, expected 3")
  w144_assert(grid.rows_per_mark == [4_u64, 4_u64, 4_u64], "#{label}: inspected outer row schedule is not [4,4,4]")
  w144_assert(grid.logical_size == data_size.to_i64, "#{label}: frame-walked logical EOF #{grid.logical_size} differs from fully decompressed lane size #{data_size}")
  logical_offsets = grid.positions.map(&.to_u64)
  w144_assert(logical_offsets.size == 4 && logical_offsets.last == data_size.to_u64, "#{label}: frame-aware logical mark positions do not terminate at lane EOF")
  {bytes, logical_offsets, name, raw_marks}
end

def w144_find_part(store : String, label : String) : String
  candidates = Dir.glob(File.join(store, "**", "all_1_1_0"))
  w144_assert(candidates.size == 1, "#{label}: expected one unpartitioned stock part all_1_1_0, found #{candidates.size}")
  part = candidates.first
  w144_assert(File.directory?(part) && !File.symlink?(part), "#{label}: stock part is absent or symlinked")
  part
end

def w144_stream_filename(logical_name : String, extension : String) : String
  "#{CrystalClick::StreamName.hash(logical_name)}.#{extension}"
end

def w144_validate_part_metadata(part : String, format : W144FloatFormat, label : String) : Nil
  columns_path = File.join(part, "columns.txt")
  substreams_path = File.join(part, "columns_substreams.txt")
  codec_path = File.join(part, "default_compression_codec.txt")
  checksums_path = File.join(part, "checksums.txt")
  w144_assert(File.file?(columns_path) && !File.symlink?(columns_path), "#{label}: Wide part columns.txt missing or symlinked")
  w144_assert(File.file?(substreams_path) && !File.symlink?(substreams_path), "#{label}: Wide part columns_substreams.txt missing or symlinked")
  w144_assert(File.file?(codec_path) && !File.symlink?(codec_path), "#{label}: Wide part default compression codec metadata missing or symlinked")
  w144_assert(File.file?(checksums_path) && !File.symlink?(checksums_path), "#{label}: Wide part checksums.txt missing or symlinked")
  expected_columns = "columns format version: 1\n2 columns:\n`k` UInt64\n`x` LowCardinality(#{format.native_type})\n"
  w144_assert(File.read(columns_path) == expected_columns, "#{label}: stock part columns differ from exact two-column schema")
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `k`:\n\tk\n2 substreams for column `x`:\n\tx.dict\n\tx\n"
  w144_assert(File.read(substreams_path) == expected_substreams, "#{label}: LC substream metadata differs from k, x.dict, x")
  w144_assert(File.read(codec_path) == "CODEC(LZ4)", "#{label}: part codec is not the expected explicit LZ4 profile")
  checksums = CrystalClick::PartChecksums.open(part)
  w144_assert(!checksums.entries.empty?, "#{label}: stock checksums contain no entries")
  checksums.entries.each_key do |name|
    checksums.validate_selected_entries(part, name)
  end
  w144_assert(!File.file?(File.join(part, "data.bin")), "#{label}: compact data.bin present; this witness requires per-column Wide lanes")
  {"k", "x", "x.dict"}.each do |logical_name|
    %w(bin mrk2).each do |extension|
      filename = w144_stream_filename(logical_name, extension)
      w144_assert(checksums.entries.has_key?(filename), "#{label}: checksums omit physical stream #{filename}")
    end
  end
end

def w144_read_data_file(part : String, basename : String, label : String) : Bytes
  path = File.join(part, w144_stream_filename(basename, "bin"))
  w144_decompressed(path, "#{label} compressed #{basename}.bin")
end

def w144_dictionary_records(format : W144FloatFormat, bytes : Bytes, offsets : Array(UInt64), label : String) : Hash(UInt64, Array(UInt64))
  w144_assert(bytes.size >= 8, "#{label}: dictionary lane lacks v1 prefix")
  version = w144_u64_le(bytes, 0, "#{label} dictionary version")
  w144_assert(version == 1_u64, "#{label}: unsupported dictionary version #{version}")
  real_offsets = offsets[0, offsets.size - 1].uniq.sort
  records = Hash(UInt64, Array(UInt64)).new
  real_offsets.each_with_index do |start_u64, index|
    start = start_u64.to_i
    finish = if index + 1 < real_offsets.size
               real_offsets[index + 1].to_i
             else
               bytes.size
             end
    w144_assert(start >= 8 && finish >= start && finish <= bytes.size, "#{label}: dictionary record coordinates are outside lane")
    w144_assert(finish - start >= 8, "#{label}: dictionary record is shorter than its key count")
    count = w144_u64_le(bytes, start, "#{label} dictionary key count")
    w144_assert(count <= Int32::MAX.to_u64, "#{label}: dictionary key count exceeds bounded parser domain")
    key_bytes = count.to_i * format.byte_width
    w144_assert(key_bytes == finish - start - 8, "#{label}: dictionary record does not consume its coordinate window exactly")
    keys = [] of UInt64
    count.to_i.times do |key_index|
      offset = start + 8 + key_index * format.byte_width
      keys << w144_uint_le(bytes, offset, format.byte_width, "#{label} dictionary key #{key_index}")
    end
    records[start_u64] = keys
  end
  records
end

def w144_read_index_marks(format : W144FloatFormat, bytes : Bytes,
                          index_offsets : Array(UInt64), dictionary_offsets : Array(UInt64),
                          dictionary_records : Hash(UInt64, Array(UInt64)), label : String) : Tuple(Array(W144IndexMark), Array(UInt64), Array(UInt64))
  w144_assert(index_offsets.size == 4 && dictionary_offsets.size == 4, "#{label}: expected K+1 index and dictionary coordinates")
  active_dictionary : Array(UInt64)? = nil
  mark_results = [] of W144IndexMark
  logical = [] of UInt64
  all_ids = [] of UInt64
  3.times do |mark|
    start = index_offsets[mark].to_i
    finish = index_offsets[mark + 1].to_i
    w144_assert(finish > start, "#{label}: mark #{mark} has no aligned index record")
    w144_assert(finish - start >= 16, "#{label}: mark #{mark} record shorter than flags/count")
    flags = w144_u64_le(bytes, start, "#{label} flags")
    w144_assert((flags & ~0x703_u64) == 0_u64, "#{label}: flags use bits outside width/global/additional/update mask 0x703")
    width_code = flags & 0xff_u64
    w144_assert(width_code <= 3_u64, "#{label}: invalid index width code #{width_code}")
    index_width = 1 << width_code.to_i
    global = (flags & 0x100_u64) != 0_u64
    additional = (flags & 0x200_u64) != 0_u64
    update = (flags & 0x400_u64) != 0_u64
    cursor = start + 8
    additional_keys = [] of UInt64
    if additional
      w144_assert(cursor <= finish - 8, "#{label}: truncated additional-key count")
      count = w144_u64_le(bytes, cursor, "#{label} additional key count")
      cursor += 8
      w144_assert(count <= Int32::MAX.to_u64, "#{label}: additional-key count exceeds bounded parser domain")
      key_bytes = count.to_i * format.byte_width
      w144_assert(key_bytes <= finish - cursor, "#{label}: additional keys exceed index mark window")
      count.to_i.times do |key_index|
        additional_keys << w144_uint_le(bytes, cursor + key_index * format.byte_width, format.byte_width,
          "#{label} mark #{mark} additional key #{key_index}")
      end
      cursor += key_bytes
    end

    dictionary_offset = dictionary_offsets[mark]
    if global && (active_dictionary.nil? || update)
      loaded = dictionary_records[dictionary_offset]?
      w144_assert(loaded != nil, "#{label}: global dictionary update at mark #{mark} does not name an exact record coordinate #{dictionary_offset}")
      active_dictionary = loaded
    end
    w144_assert(global || additional, "#{label}: mark #{mark} has neither a global nor additional dictionary")
    w144_assert(!global || active_dictionary != nil, "#{label}: global dictionary state unavailable at mark #{mark}")
    w144_assert(cursor <= finish - 8, "#{label}: truncated index occurrence count")
    occurrence_count = w144_u64_le(bytes, cursor, "#{label} occurrence count")
    cursor += 8
    w144_assert(occurrence_count == W144_EXPECTED_MARK_ROWS.to_u64, "#{label}: mark #{mark} occurrence count #{occurrence_count} != 4")
    payload_bytes = occurrence_count.to_i * index_width
    w144_assert(cursor + payload_bytes == finish, "#{label}: index payload does not consume one exact mark-aligned record")
    ids = [] of UInt64
    occurrence_count.to_i.times do |row|
      id = w144_uint_le(bytes, cursor + row * index_width, index_width, "#{label} mark #{mark} row #{row} index")
      ids << id
      all_ids << id
      bits = if global
               dictionary = active_dictionary.not_nil!
               if id < dictionary.size.to_u64
                 dictionary[id.to_i]
               else
                 additional_index = id - dictionary.size.to_u64
                 w144_assert(additional && additional_index < additional_keys.size.to_u64,
                   "#{label}: global index #{id} is outside dictionary and additional keys")
                 additional_keys[additional_index.to_i]
               end
             else
               w144_assert(id < additional_keys.size.to_u64, "#{label}: additional-only index #{id} outside key set")
               additional_keys[id.to_i]
             end
      logical << bits
    end
    mark_results << W144IndexMark.new(mark, flags, width_code, occurrence_count, dictionary_offset, ids)
  end
  {mark_results, logical, all_ids}
end

def w144_capture_part(format : W144FloatFormat, case_label : String, route : String,
                      store : String, output_root : String) : Array(UInt64)
  source_part = w144_find_part(store, "#{case_label}/#{route}")
  case_dir = File.join(output_root, "parts", case_label, route)
  Dir.mkdir_p(case_dir)
  copied_part = File.join(case_dir, "all_1_1_0")
  w144_assert(!File.exists?(copied_part) && !File.symlink?(copied_part), "refusing to overwrite copied W144 stock part")
  FileUtils.cp_r(source_part, copied_part)
  w144_validate_part_metadata(copied_part, format, "#{case_label}/#{route}")

  k_bytes = w144_read_data_file(copied_part, "k", "#{case_label}/#{route}")
  w144_assert(k_bytes.size == W144_EXPECTED_ROWS * 8, "#{case_label}/#{route}: physical UInt64 k lane is not 12 rows")
  k_marks_bytes, k_offsets, k_marks_name, k_raw_marks = w144_lane_mark_file(copied_part, "k", k_bytes.size, 0, "#{case_label}/#{route} k")
  k_values = [] of UInt64
  W144_EXPECTED_ROWS.times do |row|
    key = w144_u64_le(k_bytes, row * 8, "#{case_label}/#{route} physical k row #{row}")
    w144_assert(key == row.to_u64, "#{case_label}/#{route}: physical k lane is not canonical 0..11 row order")
    k_values << key
  end

  index_bytes = w144_read_data_file(copied_part, "x", "#{case_label}/#{route}")
  dictionary_bytes = w144_read_data_file(copied_part, "x.dict", "#{case_label}/#{route}")
  _, index_offsets, index_marks_name, index_raw_marks = w144_lane_mark_file(copied_part, "x", index_bytes.size, 0, "#{case_label}/#{route} x indexes")
  _, dictionary_offsets, dictionary_marks_name, dictionary_raw_marks = w144_lane_mark_file(copied_part, "x.dict", dictionary_bytes.size, 8, "#{case_label}/#{route} x dictionary")
  dictionaries = w144_dictionary_records(format, dictionary_bytes, dictionary_offsets, "#{case_label}/#{route}")
  records, logical, ids = w144_read_index_marks(format, index_bytes, index_offsets, dictionary_offsets, dictionaries,
    "#{case_label}/#{route}")
  w144_assert(logical.size == W144_EXPECTED_ROWS, "#{case_label}/#{route}: physical index replay yielded #{logical.size} values")
  w144_assert(k_values.size == logical.size, "#{case_label}/#{route}: key lane and LC value counts differ")

  dump = String.build do |io|
    io << "case=#{case_label}\nroute=#{route}\nsource_part=#{source_part}\ncopied_part=#{copied_part}\n"
    io << "part_type=Wide-required-by-independent-12-row-stream-layout\n"
    io << "checksum_validation=size-only via PartChecksums.validate_selected_entries; hashes and compressed payload checksums are not claimed\n"
    io << "k_marks_file=#{k_marks_name}\nk_physical_mark_coords=#{k_raw_marks.inspect}\nk_frame_walked_logical_positions=#{k_offsets.inspect}\n"
    io << "x_indexes_marks_file=#{index_marks_name}\nx_index_physical_mark_coords=#{index_raw_marks.inspect}\nx_index_frame_walked_logical_positions=#{index_offsets.inspect}\n"
    io << "x_dictionary_marks_file=#{dictionary_marks_name}\nx_dictionary_physical_mark_coords=#{dictionary_raw_marks.inspect}\nx_dictionary_frame_walked_logical_positions=#{dictionary_offsets.inspect}\n"
    io << "k.bin.decompressed_hex=#{w144_hex(k_bytes)}\n"
    io << "x.bin.decompressed_hex=#{w144_hex(index_bytes)}\n"
    io << "x.dict.bin.decompressed_hex=#{w144_hex(dictionary_bytes)}\n"
    io << "dictionary_version=#{w144_u64_le(dictionary_bytes, 0, "dictionary version")}\n"
    dictionaries.each do |offset, keys|
      io << "global_dictionary_offset=#{offset}\n"
      io << "global_dictionary_raw_bits=#{keys.map { |bits| "0x#{bits.to_s(16)}" }.join(",")}\n"
    end
    records.each do |record|
      io << "mark=#{record.mark}\tflags=0x#{record.flags.to_s(16)}\twidth_code=#{record.width_code}\toccurrences=#{record.occurrence_count}\tdictionary_offset=#{record.dictionary_offset}\tids=#{record.ids.join(",")}\n"
    end
    io << "all_ids=#{ids.join(",")}\n"
    io << "logical_raw_bits=#{logical.map { |bits| "0x#{bits.to_s(16)}" }.join(",")}\n"
  end
  w144_write_text(File.join(case_dir, "lane-dump.txt"), dump)
  logical
end

def w144_check_runtime(binary : String, output_root : String) : Nil
  version_out = IO::Memory.new
  version_status = Process.run(binary, ["local", "--version"], output: version_out, error: Process::Redirect::Close)
  w144_assert(version_status.success? && version_out.to_s.strip == W144_CLICKHOUSE_VERSION, "pinned W144 runtime version differs")

  hash_out = IO::Memory.new
  hash_status = Process.run("shasum", ["-a", "256", binary], output: hash_out, error: Process::Redirect::Close)
  w144_assert(hash_status.success? && hash_out.to_s.split(' ').first? == W144_RUNTIME_SHA256, "pinned W144 runtime executable SHA differs")

  identity_store = w144_store(output_root, "identity")
  identity = IO::Memory.new
  identity_status = Process.run(binary,
    ["local", "--path", identity_store, "--query",
     "SELECT concat(name, '=', value) FROM system.build_options WHERE name IN ('GIT_HASH', 'VERSION_GITHASH') ORDER BY name FORMAT TSVRaw"],
    output: identity, error: Process::Redirect::Close)
  expected = ["GIT_HASH=#{W144_BUILD_HASH}", "VERSION_GITHASH=#{W144_BUILD_HASH}"]
  actual = identity.to_s.lines.map(&.strip).reject(&.empty?)
  w144_assert(identity_status.success? && actual == expected, "pinned W144 runtime build identity differs: #{actual.inspect}")
  puts "PASS W144 identities: source=#{W144_SOURCE_REVISION} version=#{W144_CLICKHOUSE_VERSION} sha256=#{W144_RUNTIME_SHA256} build=#{W144_BUILD_HASH}; runtime is not asserted to have been built from the source checkout"
end

def w144_validate_roots : String
  output_arg = ENV["W144_CHECK_ROOT"]? || w144_fail("W144_CHECK_ROOT is required")
  w144_assert(File.directory?(output_arg) && !File.symlink?(output_arg), "W144_CHECK_ROOT must be a new non-symlink output directory")
  output = File.realpath(output_arg)
  w144_assert(output.starts_with?("/private/tmp/crystal-click-low-cardinality-float-w144."), "W144 output root is outside its pinned prefix")
  %w(native-input stores parts results crystal-cache).each do |child|
    path = File.join(output, child)
    w144_assert(File.directory?(path) && !File.symlink?(path), "W144 output child #{child} must be a direct non-symlink directory")
    if child != "crystal-cache"
      w144_assert(Dir.empty?(path), "W144 output child #{child} must be fresh and empty")
    end
  end
  output
end

def w144_prepare_case(format : W144FloatFormat, order_name : String, order : Array(Int32),
                      binary : String, output_root : String) : Tuple(String, String)
  case_label = "#{format.label}-#{order_name}"
  values = w144_vector(format, order)
  expected_bits = values.map { |hex| w144_bits_from_hex(hex) }
  w144_assert(values.size == W144_EXPECTED_ROWS, "#{case_label}: authored vector length differs")
  frequencies = Hash(String, Int32).new(0)
  values.each { |hex| frequencies[hex] += 1 }
  w144_assert(frequencies.size == 6 && frequencies.values.all?(&.==(2)), "#{case_label}: expected six raw patterns twice each")

  raw_path = File.join(output_root, "native-input", "#{case_label}.raw.native")
  lc_path = File.join(output_root, "native-input", "#{case_label}.lc.native")
  w144_write_bytes(raw_path, w144_raw_native(format, values))
  lc_native, native_dictionary, native_ids = w144_additional_native(format, values)
  w144_write_bytes(lc_path, lc_native)

  raw_store = w144_store(output_root, "#{case_label}-memory")
  lc_type = "LowCardinality(#{format.native_type})"
  raw_query = [
    "CREATE TABLE raw (k UInt64, x #{format.native_type}) ENGINE=Memory",
    w144_merge_tree_ddl("from_memory", format, true),
    "INSERT INTO raw SELECT * FROM table",
    "INSERT INTO from_memory SELECT k, x FROM raw",
    "SELECT 'memory' AS route, k, #{w144_sql_bits(format)} AS bits FROM raw UNION ALL SELECT 'from-memory' AS route, k, #{w144_sql_bits(format)} AS bits FROM from_memory ORDER BY route, k FORMAT TSVRaw",
  ].join("; ")
  ok, output, error = w144_run(binary, raw_store, format.native_type, raw_path, raw_query, case_label)
  w144_write_text(File.join(output_root, "results", "#{case_label}.memory.stderr"), error)
  w144_write_text(File.join(output_root, "results", "#{case_label}.memory.stdout"), output)
  w144_assert(ok, "#{case_label}: plain Native Memory / INSERT SELECT route failed: #{error.strip}")
  memory_vectors = w144_parse_observations(output, ["from-memory", "memory"], "#{case_label} Memory control")
  memory_bits = memory_vectors["memory"]
  w144_assert_bits(memory_bits, expected_bits, "#{case_label} raw Native -> Memory bit-preservation control")
  w144_expect_seeded_mismatch(memory_bits, case_label)

  from_memory_bits = memory_vectors["from-memory"]
  from_memory_store = raw_store
  physical_from_memory = w144_capture_part(format, case_label, "from-memory", from_memory_store, output_root)
  w144_assert_bits(physical_from_memory, from_memory_bits, "#{case_label} from-memory SQL bits vs retained part dictionary/index replay")

  direct_store = w144_store(output_root, "#{case_label}-direct")
  direct_query = [
    w144_merge_tree_ddl("direct", format, true),
    "INSERT INTO direct SELECT * FROM table",
    "SELECT 'direct' AS route, k, #{w144_sql_bits(format)} AS bits FROM direct ORDER BY k FORMAT TSVRaw",
  ].join("; ")
  direct_ok, direct_output, direct_error = w144_run(binary, direct_store, lc_type, lc_path, direct_query, case_label)
  w144_write_text(File.join(output_root, "results", "#{case_label}.direct.stderr"), direct_error)
  w144_write_text(File.join(output_root, "results", "#{case_label}.direct.stdout"), direct_output)
  w144_assert(direct_ok, "#{case_label}: additional-only LC Native -> MergeTree route failed: #{direct_error.strip}")
  direct_vectors = w144_parse_observations(direct_output, ["direct"], "#{case_label} direct LC Native")
  direct_bits = direct_vectors["direct"]
  physical_direct = w144_capture_part(format, case_label, "direct", direct_store, output_root)
  w144_assert_bits(physical_direct, direct_bits, "#{case_label} direct Native SQL bits vs retained part dictionary/index replay")

  vector_rows = String.build do |io|
    W144_EXPECTED_ROWS.times do |index|
      io << case_label << "\t" << format.native_type << "\t" << order_name << "\t" << index << "\t"
      io << values[index] << "\t" << expected_bits[index] << "\t" << memory_bits[index] << "\t"
      io << from_memory_bits[index] << "\t" << physical_from_memory[index] << "\t"
      io << direct_bits[index] << "\t" << physical_direct[index] << "\n"
    end
  end
  manifest_row = String.build do |io|
    io << case_label << "\t" << format.native_type << "\t" << order_name << "\t"
    io << values.join(",") << "\t" << native_dictionary.join(",") << "\t" << native_ids.join(",") << "\n"
  end

  puts "PASS W144 raw Memory control and part reconciliation: #{case_label} rows=12 marks=3 raw-keys=6 direct_additional_keys=#{native_dictionary.size}"
  {vector_rows, manifest_row}
end

def w144_main : Nil
  output_root = w144_validate_roots
  binary = ENV["CLICKHOUSE_BIN"]? || w144_fail("CLICKHOUSE_BIN is required")
  source_root = ENV["CLICKHOUSE_SOURCE_ROOT"]? || w144_fail("CLICKHOUSE_SOURCE_ROOT is required")
  w144_assert(File.directory?(source_root) && !File.symlink?(source_root), "pinned ClickHouse source root is unavailable")
  source_rev_output = IO::Memory.new
  source_status = Process.run("git", ["-C", source_root, "rev-parse", "HEAD"], output: source_rev_output, error: Process::Redirect::Close)
  w144_assert(source_status.success? && source_rev_output.to_s.strip == W144_SOURCE_REVISION, "pinned ClickHouse source revision differs")
  w144_check_runtime(binary, output_root)

  vector_rows = [] of String
  manifest_rows = [] of String
  w144_formats.each do |format|
    w144_orders.each do |order_name, order|
      case_vectors, case_manifest = w144_prepare_case(format, order_name, order, binary, output_root)
      vector_rows << case_vectors
      manifest_rows << case_manifest
    end
  end

  combined_vectors = String.build do |io|
    io << "case\ttype\torder\tk\tauthored_raw_bytes_le\tauthored_bits\tmemory_bits\tfrom_memory_lc_bits\tfrom_memory_part_bits\tdirect_lc_bits\tdirect_lc_part_bits\n"
    vector_rows.each { |rows| io << rows }
  end
  combined_manifest = String.build do |io|
    io << "case\ttype\torder\trow_raw_bytes_le\tadditional_dictionary_first_seen_raw_bytes_le\tadditional_ids\n"
    manifest_rows.each { |row| io << row }
  end
  w144_write_text(File.join(output_root, "results", "vectors.tsv"), combined_vectors)
  w144_write_text(File.join(output_root, "results", "manifest.tsv"), combined_manifest)
  record = [
    "clickhouse_source_revision=#{W144_SOURCE_REVISION}",
    "runtime_version=#{W144_CLICKHOUSE_VERSION}",
    "runtime_sha256=#{W144_RUNTIME_SHA256}",
    "runtime_build_hash=#{W144_BUILD_HASH}",
    "runtime_built_from_pinned_source=false",
    "native_format=revision_zero_self_describing_block; scalar_data_little_endian; LowCardinality_v1_prefix; additional_only_flags_0x600_and_UInt8_indexes",
    "float_vectors=Float32_Float64_BFloat16; +0_-0; positive_and_negative_distinct_qNaN_payloads; +1_-2; 12_rows; each_raw_key_twice; two_first_occurrence_orders",
    "consumer_routes=plain_Float_Native_to_Memory_then_INSERT_SELECT_to_LowCardinality_Wide; additional_only_LowCardinality_Native_to_LowCardinality_Wide",
    "part_profile=two_columns_k_UInt64_and_x_LowCardinality_Float; ORDER_BY_k; 12_rows; 3_marks_of_4; copied_full_stock_parts; one mark-aligned index record per mark",
    "source_evidence=NativeWriter.cpp:60-95,NativeReader.cpp:91-124,SerializationLowCardinality.cpp:115-185,271-288,534-627,629-785,ColumnUnique.h:790ff,ISerialization.cpp:300-345",
    "claim_scope=measured_input_and_part_bit_vectors_for_these_six_type-order_cases; no_general_float_identity_rule; no_claim_that_additional_only_Native_preserves_dictionary_bits; no_complete_Attach_or_writer_claim",
    "failure_policy=fail_closed_on_runtime_identity,non-Wide_or_unexpected_part_streams,unsupported_marks,non-exact_lane_records,SQL-vs-part-replay mismatch,or seeded-comparator acceptance",
  ].join("\n") + "\n"
  w144_write_text(File.join(output_root, "results", "run.txt"), record)
  puts "PASS W144 bounded float-identity observation: 6 type/order cases; raw-bit Memory control; both LC ingestion routes reconciled to full retained part dictionaries and IDs; no NaN text used"
end

w144_main
