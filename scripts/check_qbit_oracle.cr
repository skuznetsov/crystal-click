# W103 independent stock -> reader -> writer -> stock oracle. Expected QBit
# planes are derived from ClickHouse's published transpose equation below; this
# file never calls the production QBit planner or codec to build expectations.
require "json"
require "file_utils"
require "../src/crystal_click"

W103O_VERSION    = "26.7.1.1315"
W103O_KEYS       = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
W103O_MARK_ROWS  = [2_u64, 2_u64, 1_u64, 0_u64]
W103O_FULL       = [0_i32, 1_i32, 2_i32, 3_i32, 4_i32]
W103O_KEY_RANGE  = [1_i32, 2_i32, 3_i32]
W103O_WINDOW     = [1_i32, 2_i32, 3_i32]
W103O_CANDIDATE  = [2_i32, 3_i32]
W103O_SPLIT_ROWS =   3000
W103O_SPLIT_DIM  = 17_u64
W103O_ELEMENTS   = [
  {"Int8", 1_i32, 8_i32},
  {"BFloat16", 2_i32, 16_i32},
  {"Float32", 4_i32, 32_i32},
  {"Float64", 8_i32, 64_i32},
]
W103O_SHAPES = [
  {1_u64, nil.as(UInt64?)}, {7_u64, nil.as(UInt64?)}, {8_u64, nil.as(UInt64?)},
  {9_u64, nil.as(UInt64?)}, {10_u64, nil.as(UInt64?)}, {16_u64, nil.as(UInt64?)},
  {16_u64, 8_u64.as(UInt64?)}, {24_u64, 8_u64.as(UInt64?)}, {32_u64, 16_u64.as(UInt64?)},
]

class W103OByteMismatchError < Exception
end

private def w103o_independent_plane_bytes(raw : String, dimension : UInt64, stride : UInt64, element_width : Int32, element_bits : Int32, plane : Int32) : String
  plane_width = ((stride + 7_u64) // 8_u64).to_i32
  group = plane // element_bits
  bit_in_group = plane % element_bits
  source_bit = element_bits - 1 - bit_in_group
  output = Array(UInt8).new(plane_width, 0_u8)
  total_bits = plane_width * 8
  dimension.to_i.times do |global_i|
    row_group = global_i.to_u64 // stride
    next unless row_group == group.to_u64
    local_i = global_i.to_u64 - row_group * stride
    bit_index = total_bits - 1 - (local_i.to_i32 ^ 7)
    source_byte = global_i * element_width + source_bit // 8
    source_mask = 1_u8 << (source_bit % 8)
    next if (raw.to_slice[source_byte] & source_mask) == 0
    output[bit_index // 8] |= 1_u8 << (bit_index % 8)
  end
  String.new(output.to_unsafe, output.size)
end

struct W103OFixture
  getter label : String
  getter element_type : String
  getter element_width : Int32
  getter element_bits : Int32
  getter dimension : UInt64
  getter explicit_stride : UInt64?
  getter nullable : Bool
  getter raw_rows : Array(String?)

  def initialize(
    @label : String,
    @element_type : String,
    @element_width : Int32,
    @element_bits : Int32,
    @dimension : UInt64,
    @explicit_stride : UInt64?,
    @nullable : Bool,
    raw_rows : Array(String?),
  )
    raise "#{@label}: fixture must have five rows" unless raw_rows.size == W103O_KEYS.size
    @raw_rows = raw_rows.map { |raw| raw.try { |bytes| String.new(bytes.to_slice) } }
    @raw_rows.each_with_index do |raw, row|
      next if raw.nil?
      expected = (@dimension * @element_width.to_u64).to_i
      raise "#{@label}: row #{row} has #{raw.bytesize} bytes, expected #{expected}" unless raw.bytesize == expected
    end
    raise "#{@label}: NULL row in non-Nullable fixture" if !@nullable && @raw_rows.any?(&.nil?)
  end

  def stride : UInt64
    @explicit_stride || @dimension
  end

  def groups : UInt64
    @dimension // stride
  end

  def plane_width : Int32
    ((stride + 7_u64) // 8_u64).to_i32
  end

  def plane_count : Int32
    (@element_bits.to_u64 * groups).to_i32
  end

  def qbit_type_name : String
    if explicit = @explicit_stride
      "QBit(#{@element_type}, #{@dimension}, #{explicit})"
    else
      "QBit(#{@element_type}, #{@dimension})"
    end
  end

  def type_name : String
    @nullable ? "Nullable(#{qbit_type_name})" : qbit_type_name
  end

  def qbit_type : CrystalClick::QBitType
    CrystalClick::QBitType.new(@element_type, @dimension, @explicit_stride)
  end

  def source_table : String
    "w103s_#{@label}"
  end

  def writer_table : String
    "w103w_#{@label}"
  end

  def plane_stream(index : Int32) : String
    "payload%2E#{index + 1}"
  end

  def streams : Array(String)
    names = ["pk"]
    names << "payload.null" if @nullable
    plane_count.times { |index| names << plane_stream(index) }
    names
  end

  def zero_raw : String
    String.new(Bytes.new((@dimension * @element_width.to_u64).to_i, 0_u8))
  end

  def raw_at(index : Int32) : String?
    @raw_rows[index]
  end

  def physical_raw_at(index : Int32) : String
    @raw_rows[index] || zero_raw
  end

  def values : Array(CrystalClick::QBitValue)
    raise "#{@label}: Nullable values require nullable_values" if @nullable
    type = qbit_type
    @raw_rows.map do |raw|
      CrystalClick::QBitValue.new(type, (raw || raise "#{@label}: missing scalar raw row").to_slice)
    end
  end

  def nullable_values : Array(CrystalClick::QBitValue?)
    raise "#{@label}: non-Nullable values do not use nullable_values" unless @nullable
    type = qbit_type
    @raw_rows.map do |raw|
      raw ? CrystalClick::QBitValue.new(type, raw.to_slice) : nil
    end
  end

  # Independently map a raw element word to its QBit plane bytes. Source law:
  # SerializationQBit.cpp transposeBits(): plane 0 is the element MSB;
  # bit_index=(ceil(stride/8)*8-1)-(local_i XOR 7). Group order is increasing.
  def plane_bytes(raw : String, plane : Int32) : String
    w103o_independent_plane_bytes(raw, @dimension, stride, @element_width, @element_bits, plane)
  end

  def expected_segments : Hash(String, Array(String))
    segments = Hash(String, Array(String)).new
    streams.each { |stream| segments[stream] = [] of String }
    3.times do |mark|
      first = mark * 2
      finish = Math.min(first + 2, @raw_rows.size)
      pk = IO::Memory.new
      nulls = IO::Memory.new
      planes = Array(IO::Memory).new(plane_count) { IO::Memory.new }
      (first...finish).each do |row|
        w103o_append_u64(pk, W103O_KEYS[row])
        raw = physical_raw_at(row)
        nulls.write_byte(@nullable && @raw_rows[row].nil? ? 1_u8 : 0_u8) if @nullable
        plane_count.times do |plane|
          planes[plane] << plane_bytes(raw, plane)
        end
      end
      segments["pk"] << pk.to_s
      segments["payload.null"] << nulls.to_s if @nullable
      plane_count.times { |plane| segments[plane_stream(plane)] << planes[plane].to_s }
    end
    segments.each_value { |parts| parts << "" }
    segments
  end

  def expected_streams : Hash(String, String)
    expected_segments.transform_values(&.join)
  end

  def expected_rowbinary(indexes : Array(Int32)) : String
    output = IO::Memory.new
    indexes.each do |index|
      w103o_append_u64(output, W103O_KEYS[index])
      append_rowbinary_value(output, index)
    end
    output.to_s
  end

  def expected_payload_rowbinary(indexes : Array(Int32)) : String
    output = IO::Memory.new
    indexes.each { |index| append_rowbinary_value(output, index) }
    output.to_s
  end

  def append_rowbinary_value(output : IO, index : Int32) : Nil
    raw = @raw_rows[index]
    if @nullable
      output.write_byte(raw.nil? ? 1_u8 : 0_u8)
      return if raw.nil?
    else
      raise "#{@label}: non-Nullable RowBinary row is missing" unless raw
    end
    w103o_varuint(output, @dimension)
    output << (raw || raise "#{@label}: non-NULL row has no payload")
  end

  def expected_substreams : String
    payload_streams = streams.reject { |stream| stream == "pk" }
    lines = [
      "columns substreams version: 1", "2 columns:",
      "1 substreams for column `pk`:", "\tpk",
      "#{payload_streams.size} substreams for column `payload`:",
    ]
    payload_streams.each { |stream| lines << "\t#{stream}" }
    lines.join("\n") + "\n"
  end
end

private def w103o_append_u64(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

private def w103o_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w103o_bytes_u8(bytes : Array(UInt8)) : String
  return "" if bytes.empty?
  String.new(bytes.to_unsafe, bytes.size)
end

private def w103o_le_word(word : UInt64, width : Int32) : String
  output = IO::Memory.new
  width.times { |index| output.write_byte(((word >> (index * 8)) & 0xff_u64).to_u8) }
  output.to_s
end

private def w103o_pattern_word(element : String, row : Int32, index : Int32, bits : Int32) : UInt64
  if element == "Int8"
    case row
    when 0 then index == 0 ? 0x80_u64 : index == 1 ? 0x7f_u64 : 0x55_u64
    when 1 then index == 0 ? 0xff_u64 : index == 1 ? 0x81_u64 : 0x01_u64
    when 2 then 0_u64
    when 3 then 1_u64 << ((index * 5 + 3) % bits)
    else        index.odd? ? 0xaa_u64 : 0x55_u64
    end
  else
    case row
    when 0
      index == 0 ? (1_u64 << (bits - 1)) : index == 1 ? (bits == 16 ? 0x7f80_u64 : bits == 32 ? 0x7f800000_u64 : 0x7ff0000000000000_u64) : index == 2 ? (bits == 16 ? 0x7f7f_u64 : bits == 32 ? 0x7f7fffff_u64 : 0x7fefffffffffffff_u64) : (bits == 16 ? 0x3f80_u64 : bits == 32 ? 0x3f800000_u64 : 0x3ff0000000000000_u64)
    when 1
      index == 0 ? (bits == 16 ? 0xff80_u64 : bits == 32 ? 0xff800000_u64 : 0xfff0000000000000_u64) : index == 1 ? (bits == 16 ? 0x7fc1_u64 : bits == 32 ? 0x7fc01234_u64 : 0x7ff8000000001234_u64) : index == 2 ? (bits == 16 ? 0xff7f_u64 : bits == 32 ? 0xff7fffff_u64 : 0xffefffffffffffff_u64) : 1_u64 << ((index * 7 + 2) % bits)
    when 2 then 0_u64
    when 3 then 1_u64 << ((index * 7 + 1) % bits)
    else
      case index % 4
      when 0 then 1_u64 << (bits - 1) # negative zero
      when 1 then bits == 16 ? 0x3f80_u64 : bits == 32 ? 0x3f800000_u64 : 0x3ff0000000000000_u64
      when 2 then 0xaaaaaaaaaaaaaaaa_u64
      else        0x5555555555555555_u64
      end
    end
  end
end

private def w103o_raw_rows(element : String, width : Int32, bits : Int32, dimension : UInt64) : Array(String?)
  Array(String?).new(5) do |row|
    raw = IO::Memory.new
    dimension.to_i.times do |index|
      raw << w103o_le_word(w103o_pattern_word(element, row, index, bits), width)
    end
    raw.to_s
  end
end

private def w103o_fixture(label : String, element : String, width : Int32, bits : Int32, dimension : UInt64, stride : UInt64?, nullable : Bool, rows : Array(String?)) : W103OFixture
  W103OFixture.new(label, element, width, bits, dimension, stride, nullable, rows)
end

private def w103o_core_fixtures : Array(W103OFixture)
  fixtures = [] of W103OFixture
  W103O_ELEMENTS.each do |element, width, bits|
    W103O_SHAPES.each do |dimension, stride|
      shape_label = stride ? "d#{dimension}_s#{stride}" : "d#{dimension}"
      raw_rows = w103o_raw_rows(element, width, bits, dimension)
      fixtures << w103o_fixture("#{element.downcase}_#{shape_label}_scalar", element, width, bits, dimension, stride, false, raw_rows)
      nullable_rows = raw_rows.dup
      nullable_rows[1] = nil
      fixtures << w103o_fixture("#{element.downcase}_#{shape_label}_nullable", element, width, bits, dimension, stride, true, nullable_rows)
    end
  end
  raise "W103 core profile drift: expected 72, got #{fixtures.size}" unless fixtures.size == 72
  fixtures
end

private def w103o_guard_fixtures : Array(W103OFixture)
  fixtures = [] of W103OFixture
  W103O_ELEMENTS.each do |element, width, bits|
    zero = String.new(Bytes.new(10 * width, 0_u8))
    zeros = Array(String?).new(5, zero)
    fixtures << w103o_fixture("#{element.downcase}_allzero", element, width, bits, 10_u64, nil, false, zeros)
    all_null = Array(String?).new(5) { nil }
    fixtures << w103o_fixture("#{element.downcase}_allnull", element, width, bits, 10_u64, nil, true, all_null)
  end
  raise "W103 guard profile drift: expected 8, got #{fixtures.size}" unless fixtures.size == 8
  fixtures
end

private def w103o_assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual == expected
  limit = Math.min(actual.bytesize, expected.bytesize)
  index = 0
  while index < limit && actual.to_slice[index] == expected.to_slice[index]
    index += 1
  end
  got = index < actual.bytesize ? actual.to_slice[index].to_s(16).rjust(2, '0') : "<eof>"
  want = index < expected.bytesize ? expected.to_slice[index].to_s(16).rjust(2, '0') : "<eof>"
  raise W103OByteMismatchError.new("#{label}: expected #{expected.bytesize} bytes, got #{actual.bytesize}; first difference #{index}: expected #{want}, got #{got}")
end

private def w103o_seeded_plane_comparator(actual : String, expected : String, label : String) : Nil
  w103o_assert_bytes(actual, expected, "#{label} independent plane")
  raise "#{label}: empty plane fixture" if expected.empty?
  damaged = String.new(expected.to_slice)
  damaged.to_unsafe[0] = damaged.to_slice[0] ^ 0x01_u8
  rejected = false
  begin
    w103o_assert_bytes(actual, damaged, "#{label} seeded wrong-plane control")
  rescue ex : W103OByteMismatchError
    rejected = true
  end
  raise "#{label}: seeded wrong plane byte was accepted" unless rejected
  puts "PASS #{label}: seeded wrong-plane byte is rejected"
end

private def w103o_clickhouse(binary : String, store : String, query : String, input : IO? = nil) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], input: input || Process::Redirect::Close, output: output, error: error)
  raise "ClickHouse command failed (#{status.exit_code}): #{error}\n#{query}" unless status.success?
  output.to_s
end

private def w103o_settings : String
  "index_granularity = 2, index_granularity_bytes = 10485760, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, ratio_of_defaults_for_sparse_serialization = 1.0, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, default_compression_codec = 'LZ4'"
end

private def w103o_create_table(binary : String, store : String, table : String, fixture : W103OFixture) : Nil
  w103o_clickhouse(binary, store, "CREATE TABLE default.#{table} (pk UInt64, payload #{fixture.type_name}) ENGINE = MergeTree ORDER BY pk SETTINGS #{w103o_settings}")
  nil
end

private def w103o_insert_input(fixture : W103OFixture, indexes : Array(Int32) = W103O_FULL) : IO::Memory
  output = IO::Memory.new
  indexes.each do |index|
    w103o_append_u64(output, W103O_KEYS[index])
    fixture.append_rowbinary_value(output, index)
  end
  output.rewind
  output
end

private def w103o_part_path(binary : String, store : String, table : String, label : String, expected_rows : UInt64 = W103O_KEYS.size.to_u64) : String
  lines = w103o_clickhouse(binary, store, "SELECT path, part_type, rows FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines.map(&.strip).reject(&.empty?)
  raise "#{label}: expected one active part, got #{lines.inspect}" unless lines.size == 1
  fields = lines[0].split('\t')
  raise "#{label}: malformed system.parts row" unless fields.size == 3
  raise "#{label}: expected Wide part, got #{fields[1]}" unless fields[1] == "Wide"
  raise "#{label}: expected #{expected_rows} rows, got #{fields[2]}" unless fields[2] == expected_rows.to_s
  fields[0]
end

private def w103o_u64_at(bytes : Bytes, offset : Int32) : UInt64
  8.times.reduce(0_u64) { |value, index| value | (bytes[offset + index].to_u64 << (index * 8)) }
end

private def w103o_mark_records(part : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  raise "#{part}: missing mark file for #{stream}" unless File.file?(path)
  bytes = File.read(path).to_slice
  raise "#{stream}: partial .mrk2 record" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {w103o_u64_at(bytes, offset), w103o_u64_at(bytes, offset + 8), w103o_u64_at(bytes, offset + 16)}
  end
end

private def w103o_validate_metadata(part : String, label : String) : Nil
  info = JSON.parse(File.read(File.join(part, "serialization.json"))).as_h
  keys = ["columns", "propagate_types_serialization_versions_to_nested_types", "types_serialization_versions", "version"].sort
  raise "#{label}: serialization metadata top-level keys differ" unless info.keys.sort == keys
  raise "#{label}: serialization version differs" unless info["version"]?.try(&.as_i) == 1
  raise "#{label}: nested serialization versions are not propagated" unless info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  versions = info["types_serialization_versions"]?.try(&.as_h) || raise "#{label}: type-version map absent"
  raise "#{label}: type-version map differs: #{versions.to_json}" unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
  records = info["columns"]?.try(&.as_a) || raise "#{label}: columns metadata is not an array"
  raise "#{label}: ratio-1 profile unexpectedly exposes serializer counters" unless records.empty?
  nil
end

private def w103o_expected_columns(fixture : W103OFixture) : String
  "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{fixture.type_name}\n"
end

private def w103o_decoded(encoded : Bytes, label : String) : String
  return "" if encoded.empty?
  String.new(CrystalClick::CompressedBlock.decode_all(encoded))
end

private def w103o_assert_stream_mark_windows(label : String, part : String, stream : String, expected_segments : Array(String), expected_mark_rows : Array(UInt64), injected : Array(Tuple(UInt64, UInt64, UInt64))? = nil) : Nil
  records = injected || w103o_mark_records(part, stream)
  encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  raise "#{label} #{stream}: mark row schedule differs" unless records.map(&.[2]) == expected_mark_rows
  raise "#{label} #{stream}: data mark count differs" unless expected_segments.size == records.size
  decoded_stream = w103o_decoded(encoded, "#{label} #{stream}")

  # Decode each frame once and resolve mark offsets to absolute decoded bytes.
  frame_ranges = [] of Tuple(UInt64, UInt64, UInt64, UInt64)
  compressed = 0_u64
  decoded = 0_u64
  while compressed < encoded.size
    frame = CrystalClick::CompressedBlock.decode_frame(encoded, compressed.to_i64)
    ending = frame.end_offset.to_u64
    raise "#{label} #{stream}: invalid frame boundary" unless ending > compressed && ending <= encoded.size.to_u64
    frame_ranges << {compressed, ending, decoded, frame.output.size.to_u64}
    compressed = ending
    decoded &+= frame.output.size.to_u64
  end
  raise "#{label} #{stream}: frames do not consume encoded stream" unless compressed == encoded.size.to_u64

  expected_prefix = 0_u64
  expected_segments.each_index do |index|
    compressed_offset, decompressed_offset, _rows = records[index]
    raise "#{label} #{stream} mark #{index}: compressed offset outside file" if compressed_offset > encoded.size.to_u64
    absolute = if compressed_offset == encoded.size.to_u64
                 raise "#{label} #{stream} mark #{index}: nonzero offset at EOF" unless decompressed_offset == 0_u64
                 decoded
               else
                 range = frame_ranges.find { |candidate| candidate[0] == compressed_offset } || raise "#{label} #{stream} mark #{index}: offset is not a frame start"
                 raise "#{label} #{stream} mark #{index}: decompressed offset outside frame" if decompressed_offset > range[3]
                 range[2] &+ decompressed_offset
               end
    raise "#{label} #{stream} mark #{index}: logical prefix differs" unless absolute == expected_prefix
    segment = expected_segments[index]
    raise "#{label} #{stream} mark #{index}: logical prefix exceeds decoded bytes" if expected_prefix > decoded
    raise "#{label} #{stream} mark #{index}: segment extends beyond decoded bytes" if segment.bytesize.to_u64 > decoded - expected_prefix
    if segment.bytesize > 0
      actual_window = decoded_stream.byte_slice(expected_prefix.to_i, segment.bytesize)
      w103o_assert_bytes(actual_window, segment, "#{label} #{stream} mark #{index} bytes")
    end
    expected_prefix &+= segment.bytesize.to_u64
  end
  raise "#{label} #{stream}: logical EOF differs" unless expected_prefix == decoded
  nil
end

private def w103o_assert_mark_windows(fixture : W103OFixture, part : String, stream : String, injected : Array(Tuple(UInt64, UInt64, UInt64))? = nil) : Nil
  w103o_assert_stream_mark_windows(fixture.label, part, stream, fixture.expected_segments[stream], W103O_MARK_ROWS, injected)
end

private def w103o_assert_part(fixture : W103OFixture, part : String, writer : Bool = false) : Nil
  raise "#{fixture.label}: columns.txt differs" unless File.read(File.join(part, "columns.txt")) == w103o_expected_columns(fixture)
  raise "#{fixture.label}: columns_substreams.txt differs" unless File.read(File.join(part, "columns_substreams.txt")) == fixture.expected_substreams
  expected = fixture.expected_streams
  entries = Dir.children(part)
  bins = entries.select(&.ends_with?(".bin")).sort
  marks = entries.select(&.ends_with?(".mrk2")).sort
  expected_bins = expected.keys.map { |stream| "#{CrystalClick::StreamName.hash(stream)}.bin" }.sort
  expected_marks = expected.keys.map { |stream| "#{CrystalClick::StreamName.hash(stream)}.mrk2" }.sort
  raise "#{fixture.label}: full .bin inventory differs" unless bins == expected_bins
  raise "#{fixture.label}: full .mrk2 inventory differs" unless marks == expected_marks
  alternate_suffixes = [".mrk", ".mrk3", ".cmrk", ".cmrk2", ".cmrk3"]
  raise "#{fixture.label}: alternate mark files are outside this profile" unless entries.none? { |name| alternate_suffixes.any? { |suffix| name.ends_with?(suffix) } }
  expected.each do |stream, bytes|
    encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
    actual = w103o_decoded(encoded, "#{fixture.label} #{stream}")
    w103o_assert_bytes(actual, bytes, "#{fixture.label} #{stream} complete physical bytes")
    w103o_assert_mark_windows(fixture, part, stream)
  end
  w103o_validate_metadata(part, fixture.label)
  nil
end

private def w103o_check_table(binary : String, store : String, table : String, part : String) : Nil
  result = w103o_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  expected = "#{File.basename(part.chomp("/"))}\t1"
  raise "#{table}: stock CHECK TABLE differs: #{result.inspect}" unless result == expected
  nil
end

private def w103o_stock_rowbinary(binary : String, store : String, table : String, fixture : W103OFixture, indexes : Array(Int32), key_range : Bool = false) : Nil
  predicate = key_range ? " WHERE pk >= 2 AND pk < 5" : ""
  actual = w103o_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table}#{predicate} ORDER BY pk FORMAT RowBinary")
  w103o_assert_bytes(actual, fixture.expected_rowbinary(indexes), "#{fixture.label} stock #{key_range ? "key-range" : "full"} RowBinary")
  nil
end

private def w103o_create_stock(binary : String, store : String, fixture : W103OFixture) : String
  w103o_create_table(binary, store, fixture.source_table, fixture)
  w103o_clickhouse(binary, store, "INSERT INTO default.#{fixture.source_table} FORMAT RowBinary", w103o_insert_input(fixture))
  part = w103o_part_path(binary, store, fixture.source_table, fixture.label)
  columns = w103o_clickhouse(binary, store, "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{fixture.source_table}' ORDER BY position FORMAT TSVRaw").lines.map(&.strip)
  raise "#{fixture.label}: stock system.columns differs: #{columns.inspect}" unless columns == ["pk UInt64", "payload #{fixture.type_name}"]
  w103o_assert_part(fixture, part)
  w103o_check_table(binary, store, fixture.source_table, part)
  w103o_stock_rowbinary(binary, store, fixture.source_table, fixture, W103O_FULL)
  w103o_stock_rowbinary(binary, store, fixture.source_table, fixture, W103O_KEY_RANGE, true)
  part
end

private def w103o_assert_value(fixture : W103OFixture, value : CrystalClick::QBitValue, index : Int32, label : String) : Nil
  expected_type = fixture.qbit_type_name
  raise "#{label}: QBit identity differs: #{value.type.type_name.inspect}" unless value.type.type_name == expected_type
  expected = fixture.raw_at(index) || raise "#{label}: expected NULL but reader returned a value"
  actual = String.new(value.raw_bytes)
  w103o_assert_bytes(actual, expected, "#{label} raw element bits")
  nil
end

private def w103o_assert_nullable_value(fixture : W103OFixture, value : CrystalClick::QBitValue?, index : Int32, label : String) : Nil
  expected = fixture.raw_at(index)
  if expected.nil?
    raise "#{label}: expected NULL" unless value.nil?
  else
    w103o_assert_value(fixture, value || raise("#{label}: expected QBit value"), index, label)
  end
  nil
end

private def w103o_check_reader(part : String, fixture : W103OFixture) : Nil
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  raise "#{fixture.label}: typed reader schema differs" unless reader.column_type == fixture.type_name
  raise "#{fixture.label}: typed reader row count differs" unless reader.row_count == W103O_KEYS.size.to_u64
  raise "#{fixture.label}: reader mark counts differ" unless reader.mark_row_counts == [2_u64, 2_u64, 1_u64]
  if fixture.nullable
    values = reader.read_nullable_qbit_mark_range("payload", 0, 3)
    raise "#{fixture.label}: nullable reader row count differs" unless values.size == 5
    values.each_with_index { |value, index| w103o_assert_nullable_value(fixture, value, index, "#{fixture.label} reader row #{index}") }
    selected = reader.read_nullable_qbit_mark_range("payload", 1, 2)
    raise "#{fixture.label}: selected nullable mark range differs" unless selected.size == 3
    selected.each_with_index { |value, index| w103o_assert_nullable_value(fixture, value, index + 2, "#{fixture.label} reader selected row #{index + 2}") }
  else
    values = reader.read_qbit_mark_range("payload", 0, 3)
    raise "#{fixture.label}: reader row count differs" unless values.size == 5
    values.each_with_index { |value, index| w103o_assert_value(fixture, value, index, "#{fixture.label} reader row #{index}") }
    selected = reader.read_qbit_mark_range("payload", 1, 2)
    raise "#{fixture.label}: selected mark range differs" unless selected.size == 3
    selected.each_with_index { |value, index| w103o_assert_value(fixture, value, index + 2, "#{fixture.label} reader selected row #{index + 2}") }
  end
  nil
end

private def w103o_assert_batch_value(fixture : W103OFixture, batch : CrystalClick::WidePartTableBatch, indexes : Array(Int32), label : String) : Nil
  keys = batch.values_for("pk")
  raise "#{label}: batch key count differs" unless keys.size == indexes.size
  keys.each_with_index do |key, offset|
    index = indexes[offset]
    raise "#{label}: batch key order differs" unless key == W103O_KEYS[index]
  end
  if fixture.nullable
    values = batch.nullable_qbits_for("payload")
    raise "#{label}: Nullable QBit batch size differs" unless values.size == indexes.size
    values.each_with_index { |value, offset| w103o_assert_nullable_value(fixture, value, indexes[offset], "#{label} row #{indexes[offset]}") }
  else
    values = batch.qbits_for("payload")
    raise "#{label}: QBit batch size differs" unless values.size == indexes.size
    values.each_with_index { |value, offset| w103o_assert_value(fixture, value, indexes[offset], "#{label} row #{indexes[offset]}") }
  end
  nil
end

private def w103o_check_table_consumers(part : String, fixture : W103OFixture) : Nil
  table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
  raise "#{fixture.label}: table total row count differs" unless table.total_row_count == 5_u64
  full = [] of UInt64
  table.scan_typed(batch_rows: 2) do |batch|
    keys = batch.values_for("pk")
    indexes = keys.map { |key| (key - 1_u64).to_i32 }.to_a
    w103o_assert_batch_value(fixture, batch, indexes, "#{fixture.label} table full")
    full.concat(keys)
    nil
  end
  raise "#{fixture.label}: table full key order differs" unless full == W103O_KEYS

  window_keys = [] of UInt64
  table.scan_typed_window(1_u64, 3) do |batch|
    keys = batch.values_for("pk")
    indexes = keys.map { |key| (key - 1_u64).to_i32 }.to_a
    w103o_assert_batch_value(fixture, batch, indexes, "#{fixture.label} table window")
    window_keys.concat(keys)
    nil
  end
  raise "#{fixture.label}: table window keys differ" unless window_keys == [2_u64, 3_u64, 4_u64]

  reader = CrystalClick::WidePart.open_typed(part, "payload")
  checksums = CrystalClick::PartChecksums.open(part)
  primary = CrystalClick::PrimaryKeyIndex.open(part, reader.mark_count, checksums, verify_recorded_hash: true)
  candidates = primary.candidate_marks(4_u64, 4_u64)
  raise "#{fixture.label}: primary-key candidate granules differ" unless candidates == [1_i32]
  candidate_keys = [] of UInt64
  table.scan_typed_candidate_marks([candidates]) do |batch|
    keys = batch.values_for("pk")
    indexes = keys.map { |key| (key - 1_u64).to_i32 }.to_a
    w103o_assert_batch_value(fixture, batch, indexes, "#{fixture.label} table PK candidate")
    candidate_keys.concat(keys)
    nil
  end
  raise "#{fixture.label}: candidate mark superset differs" unless candidate_keys == [3_u64, 4_u64]
  exact = candidate_keys.select { |key| key >= 4_u64 && key <= 4_u64 }
  raise "#{fixture.label}: exact PK predicate differs" unless exact == [4_u64]
  nil
end

private def w103o_catalog_root(root : String, part : String, fixture : W103OFixture) : String
  table_tag = fixture.label.bytes.reduce(0_u64) { |sum, byte| sum + byte.to_u64 }.to_s(16).rjust(12, '0')
  database_uuid = "10300000-0000-4000-8000-#{table_tag[0, 12]}"
  table_uuid = "10310000-0000-4000-8000-#{table_tag[0, 12]}"
  metadata = File.join(root, "metadata")
  database = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(metadata)
  FileUtils.mkdir_p(database)
  FileUtils.mkdir_p(table)
  File.write(File.join(metadata, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(File.join(database, "events.sql"), "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` #{fixture.type_name}\n)\nENGINE = MergeTree\nORDER BY pk\n")
  File.write(File.join(table, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table, "detached"))
  copied = File.join(table, "all_1_1_0")
  FileUtils.cp_r(part, copied)
  copied
end

private def w103o_assert_stale_primary_index_rejected(root : String, copied : String, fixture : W103OFixture) : Nil
  path = File.join(copied, "primary.idx")
  raise "#{fixture.label}: raw primary.idx is required for the stale-hash guard" unless File.file?(path)

  original = File.read(path)
  raise "#{fixture.label}: primary.idx size differs from the expected mark inventory" unless original.bytesize == W103O_MARK_ROWS.size * 8

  # Keep the byte count and sorted-index shape valid while moving every index
  # key above the queried value. Without recorded-hash verification this would
  # silently select no marks and omit the matching pk=4 row.
  tampered = IO::Memory.new
  tampered_keys = [5_u64, 5_u64, 5_u64, 5_u64]
  tampered_keys.each { |key| w103o_append_u64(tampered, key) }
  damaged = tampered.to_s
  raise "#{fixture.label}: stale-index mutation changed the primary.idx size" unless damaged.bytesize == original.bytesize
  raise "#{fixture.label}: stale-index mutation did not alter primary.idx" if damaged == original
  previous_key = 0_u64
  tampered_keys.each do |key|
    raise "#{fixture.label}: stale-index keys are not monotone and above the query" if key < previous_key || key <= 4_u64
    previous_key = key
  end

  callbacks = 0
  rejected = false
  begin
    File.write(path, damaged)
    corrupt_offline = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
    corrupt_offline.scan_uint64_pk_candidates(["pk", "payload"], 4_u64, 4_u64) do |_batch|
      callbacks += 1
      nil
    end
  rescue ex : CrystalClick::CorruptPartError
    rejected = true
  ensure
    File.write(path, original)
  end

  raise "#{fixture.label}: stale-hash primary.idx was accepted before callback" unless rejected
  raise "#{fixture.label}: stale-hash primary.idx reached #{callbacks} callback(s) before rejection" unless callbacks == 0
  nil
end

private def w103o_check_catalog(root : String, part : String, fixture : W103OFixture) : Nil
  copied = w103o_catalog_root(root, part, fixture)
  offline = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
  parts = offline.resolved_scan_parts
  raise "#{fixture.label}: offline part resolution differs" unless parts.size == 1 && File.realpath(parts[0].path) == File.realpath(copied)
  full_keys = [] of UInt64
  offline.scan_typed(["pk", "payload"], batch_rows: 2) do |batch|
    keys = batch.values_for("pk")
    indexes = keys.map { |key| (key - 1_u64).to_i32 }.to_a
    w103o_assert_batch_value(fixture, batch, indexes, "#{fixture.label} catalog full")
    full_keys.concat(keys)
    nil
  end
  raise "#{fixture.label}: catalog full keys differ" unless full_keys == W103O_KEYS
  window_keys = [] of UInt64
  offline.scan_typed_window(["pk", "payload"], 1_u64, 3) do |batch|
    keys = batch.values_for("pk")
    indexes = keys.map { |key| (key - 1_u64).to_i32 }.to_a
    w103o_assert_batch_value(fixture, batch, indexes, "#{fixture.label} catalog window")
    window_keys.concat(keys)
    nil
  end
  raise "#{fixture.label}: catalog window differs" unless window_keys == [2_u64, 3_u64, 4_u64]

  values = offline["payload"].values(max_tuple_cells: 1000_u64)
  raise "#{fixture.label}: offline materialized value count differs" unless values.size == 5
  values.each_with_index do |raw_value, index|
    value = raw_value.as(CrystalClick::QBitValue?)
    w103o_assert_nullable_value(fixture, value, index, "#{fixture.label} catalog value #{index}") if fixture.nullable
    w103o_assert_value(fixture, value || raise("#{fixture.label}: unexpected NULL catalog value"), index, "#{fixture.label} catalog value #{index}") unless fixture.nullable
  end

  candidate_keys = [] of UInt64
  residual_indexes = [] of Int32
  offline.scan_uint64_pk_candidates(["pk", "payload"], 4_u64, 4_u64) do |batch|
    keys = batch.values_for("pk")
    indexes = keys.map { |key| (key - 1_u64).to_i32 }.to_a
    w103o_assert_batch_value(fixture, batch, indexes, "#{fixture.label} offline PK candidate")
    candidate_keys.concat(keys)
    keys.each_with_index do |key, offset|
      residual_indexes << indexes[offset] if key == 4_u64
    end
    nil
  end
  raise "#{fixture.label}: offline PK candidate granule differs" unless candidate_keys == [3_u64, 4_u64]
  raise "#{fixture.label}: offline exact PK predicate differs" unless residual_indexes == [3_i32]
  if fixture.element_type == "Int8" && fixture.dimension == 10_u64 && fixture.explicit_stride.nil? && !fixture.nullable
    w103o_assert_stale_primary_index_rejected(root, copied, fixture)
  end
  nil
end

private def w103o_check_stock_profile(binary : String, store : String, catalog_root : String, fixture : W103OFixture, consumers : Bool) : String
  part = w103o_create_stock(binary, store, fixture)
  w103o_check_reader(part, fixture)
  if consumers
    w103o_check_table_consumers(part, fixture)
    w103o_check_catalog(File.join(catalog_root, fixture.label), part, fixture)
  end
  puts "PASS stock #{fixture.label}: exact schema, #{fixture.plane_count} planes, independent bytes/marks, CHECK and RowBinary"
  part
end

private def w103o_assert_writer_frames(fixture : W103OFixture, part : String) : Nil
  expected_segments = fixture.expected_segments
  expected_segments.each_key do |stream|
    records = w103o_mark_records(part, stream)
    raise "#{fixture.label} #{stream}: writer mark rows differ" unless records.map(&.[2]) == W103O_MARK_ROWS
    encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
    offset = 0_u64
    3.times do |index|
      compressed, decompressed, _rows = records[index]
      raise "#{fixture.label} #{stream} mark #{index}: writer frame start differs" unless compressed == offset && decompressed == 0_u64
      expected = expected_segments[stream][index]
      raise "#{fixture.label} #{stream} mark #{index}: empty writer frame is unsupported" if expected.empty?
      raise "#{fixture.label} #{stream} mark #{index}: frame missing" if offset >= encoded.size
      frame = CrystalClick::CompressedBlock.decode_frame(encoded, offset.to_i64)
      w103o_assert_bytes(String.new(frame.output), expected, "#{fixture.label} #{stream} writer frame #{index}")
      offset = frame.end_offset.to_u64
    end
    sentinel = records.last
    raise "#{fixture.label} #{stream}: writer sentinel differs from physical EOF" unless sentinel == {offset, 0_u64, 0_u64} && offset == encoded.size.to_u64
  end
  nil
end

private def w103o_write_fixture(writer_root : String, fixture : W103OFixture) : String
  path = File.join(writer_root, fixture.label, "all_1_1_0")
  FileUtils.mkdir_p(File.dirname(path))
  keys = W103O_KEYS
  key_slice = keys.to_unsafe.to_slice(keys.size)
  type_name = fixture.type_name
  if fixture.nullable
    values = fixture.nullable_values
    CrystalClick::WidePartWriter.write_uint64_nullable_qbit_pair(path, "pk", key_slice, "payload", type_name, values.to_unsafe.to_slice(values.size), 2)
  else
    values = fixture.values
    CrystalClick::WidePartWriter.write_uint64_qbit_pair(path, "pk", key_slice, "payload", type_name, values.to_unsafe.to_slice(values.size), 2)
  end
  w103o_assert_part(fixture, path, writer: true)
  w103o_assert_writer_frames(fixture, path)
  path
end

private def w103o_attach_writer(binary : String, store : String, fixture : W103OFixture, part : String) : Nil
  table = fixture.writer_table
  w103o_create_table(binary, store, table, fixture)
  data_path = w103o_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  raise "#{table}: ClickHouse data path absent" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w103o_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  attached = w103o_part_path(binary, store, table, fixture.label)
  columns = w103o_clickhouse(binary, store, "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw").lines.map(&.strip)
  raise "#{table}: attached exact type differs" unless columns == ["pk UInt64", "payload #{fixture.type_name}"]
  w103o_check_table(binary, store, table, attached)
  w103o_stock_rowbinary(binary, store, table, fixture, W103O_FULL)
  w103o_stock_rowbinary(binary, store, table, fixture, W103O_KEY_RANGE, true)
  puts "PASS writer #{fixture.label}: independent streams/marks, ATTACH CHECK and full/key RowBinary"
  nil
end

private def w103o_split_raw_rows : Array(String)
  Array(String).new(W103O_SPLIT_ROWS) do |row|
    raw = IO::Memory.new
    W103O_SPLIT_DIM.to_i.times do |dimension|
      byte = (row * 73 + dimension * 29 + (row >> 2)) & 0xff
      raw.write_byte(byte.to_u8)
    end
    raw.to_s
  end
end

private def w103o_split_segments(raw_rows : Array(String)) : Hash(String, Array(String))
  segments = Hash(String, Array(String)).new
  segments["pk"] = [] of String
  8.times { |plane| segments["payload%2E#{plane + 1}"] = [] of String }
  1500.times do |mark|
    first = mark * 2
    finish = Math.min(first + 2, raw_rows.size)
    pk = IO::Memory.new
    planes = Array(IO::Memory).new(8) { IO::Memory.new }
    (first...finish).each do |row|
      w103o_append_u64(pk, row.to_u64 + 1_u64)
      8.times do |plane|
        planes[plane] << w103o_independent_plane_bytes(raw_rows[row], W103O_SPLIT_DIM, W103O_SPLIT_DIM, 1, 8, plane)
      end
    end
    segments["pk"] << pk.to_s
    8.times { |plane| segments["payload%2E#{plane + 1}"] << planes[plane].to_s }
  end
  segments.each_value { |parts| parts << "" }
  segments
end

private def w103o_split_mark_rows : Array(UInt64)
  rows = Array(UInt64).new(1500, 2_u64)
  rows << 0_u64
  rows
end

private def w103o_split_rowbinary(raw_rows : Array(String)) : String
  output = IO::Memory.new
  raw_rows.each_with_index do |raw, row|
    w103o_append_u64(output, row.to_u64 + 1_u64)
    w103o_varuint(output, W103O_SPLIT_DIM)
    output << raw
  end
  output.to_s
end

private def w103o_assert_split_plane_frame_window(label : String, part : String, stream : String, logical_start : UInt64, logical_end : UInt64, element_width : UInt64) : Nil
  raise "#{label} #{stream}: invalid logical range" unless logical_start < logical_end
  encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  compressed = 0_u64
  logical = 0_u64
  cuts = [] of UInt64
  while compressed < encoded.size.to_u64
    frame = CrystalClick::CompressedBlock.decode_frame(encoded, compressed.to_i64)
    ending = frame.end_offset.to_u64
    raise "#{label} #{stream}: invalid frame boundary" unless ending > compressed && ending <= encoded.size.to_u64
    logical &+= frame.output.size.to_u64
    cuts << logical if logical_start < logical && logical < logical_end
    compressed = ending
  end
  raise "#{label} #{stream}: selected range does not cross exactly one frame boundary" unless cuts.size == 1
  first_chunk = cuts[0] - logical_start
  second_chunk = logical_end - cuts[0]
  raise "#{label} #{stream}: expected 4/20-byte frame split, got #{first_chunk}/#{second_chunk}" unless first_chunk == 4_u64 && second_chunk == 20_u64
  raise "#{label} #{stream}: first frame chunk is accidentally element-aligned" if first_chunk % element_width == 0_u64
  nil
end

private def w103o_check_split_reader(part : String, raw_rows : Array(String)) : Nil
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  raise "cross-frame control: typed reader schema differs" unless reader.column_type == "QBit(Int8, 17)"
  raise "cross-frame control: row count differs" unless reader.row_count == W103O_SPLIT_ROWS.to_u64
  raise "cross-frame control: mark row counts differ" unless reader.mark_row_counts == Array(UInt64).new(1500, 2_u64)
  [{682_i32, 4_i32}, {1200_i32, 4_i32}, {1497_i32, 3_i32}].each do |first_mark, mark_count|
    if first_mark == 682_i32
      logical_start = first_mark.to_u64 * 2_u64 * 3_u64
      logical_end = (first_mark + mark_count).to_u64 * 2_u64 * 3_u64
      raise "cross-frame control: selected range bounds differ" unless logical_start == 4092_u64 && logical_end == 4116_u64
      (1..8).each do |plane|
        stream = "payload%2E#{plane}"
        w103o_assert_split_plane_frame_window("cross-frame control", part, stream, logical_start, logical_end, 3_u64)
      end
    end
    values = reader.read_qbit_mark_range("payload", first_mark, mark_count)
    first_row = first_mark * 2
    expected_count = mark_count * 2
    raise "cross-frame control: late selected value count differs at mark #{first_mark}" unless values.size == expected_count
    values.each_with_index do |value, offset|
      row = first_row + offset
      raise "cross-frame control: QBit identity differs at row #{row}" unless value.type.type_name == "QBit(Int8, 17)"
      w103o_assert_bytes(String.new(value.raw_bytes), raw_rows[row], "cross-frame selected raw row #{row}")
    end
  end
  nil
end

private def w103o_cross_frame_control(binary : String, store : String) : Nil
  table = "w103_cross_frame"
  label = "3000-row QBit(Int8, 17) split-plane control"
  raw_rows = w103o_split_raw_rows
  w103o_clickhouse(binary, store, "CREATE TABLE default.#{table} (pk UInt64, payload QBit(Int8, 17)) ENGINE = MergeTree ORDER BY pk SETTINGS #{w103o_settings}")
  input = IO::Memory.new
  raw_rows.each_with_index do |raw, row|
    w103o_append_u64(input, row.to_u64 + 1_u64)
    w103o_varuint(input, W103O_SPLIT_DIM)
    input << raw
  end
  input.rewind
  w103o_clickhouse(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", input)
  part = w103o_part_path(binary, store, table, label, W103O_SPLIT_ROWS.to_u64)
  columns = w103o_clickhouse(binary, store, "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw").lines.map(&.strip)
  raise "#{label}: stock system.columns differs: #{columns.inspect}" unless columns == ["pk UInt64", "payload QBit(Int8, 17)"]

  streams = ["pk"] + (1..8).map { |plane| "payload%2E#{plane}" }
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` QBit(Int8, 17)\n"
  raise "#{label}: columns.txt differs" unless File.read(File.join(part, "columns.txt")) == expected_columns
  substream_lines = ["columns substreams version: 1", "2 columns:", "1 substreams for column `pk`:", "\tpk", "8 substreams for column `payload`:"]
  (1..8).each { |plane| substream_lines << "\tpayload%2E#{plane}" }
  raise "#{label}: columns_substreams.txt differs" unless File.read(File.join(part, "columns_substreams.txt")) == substream_lines.join("\n") + "\n"

  segments = w103o_split_segments(raw_rows)
  expected = segments.transform_values(&.join)
  entries = Dir.children(part)
  expected_bins = streams.map { |stream| "#{CrystalClick::StreamName.hash(stream)}.bin" }.sort
  expected_marks = streams.map { |stream| "#{CrystalClick::StreamName.hash(stream)}.mrk2" }.sort
  raise "#{label}: .bin inventory differs" unless entries.select(&.ends_with?(".bin")).sort == expected_bins
  raise "#{label}: .mrk2 inventory differs" unless entries.select(&.ends_with?(".mrk2")).sort == expected_marks
  mark_rows = w103o_split_mark_rows
  unaligned_per_plane = [] of Int32
  expected.each do |stream, bytes|
    encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
    w103o_assert_bytes(w103o_decoded(encoded, "#{label} #{stream}"), bytes, "#{label} #{stream} exact bytes")
    w103o_assert_stream_mark_windows(label, part, stream, segments[stream], mark_rows)
    next unless stream.starts_with?("payload%2E")
    records = w103o_mark_records(part, stream)
    unaligned = records[0...-1].count { |record| record[1] % 3_u64 != 0_u64 }
    raise "#{label} #{stream}: expected at least one byte offset not divisible by plane width 3" if unaligned == 0
    unaligned_per_plane << unaligned
  end
  w103o_validate_metadata(part, label)
  raise "#{label}: expected eight plane streams" unless unaligned_per_plane.size == 8
  w103o_check_table(binary, store, table, part)
  actual_rows = w103o_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w103o_assert_bytes(actual_rows, w103o_split_rowbinary(raw_rows), "#{label} stock RowBinary")
  w103o_check_split_reader(part, raw_rows)
  puts "PASS #{label}: all eight planes contain unaligned frame-relative marks; exact logical positions, bytes and late selected ranges"
  nil
end

private def w103o_writer_profiles(core : Array(W103OFixture), guards : Array(W103OFixture)) : Array(W103OFixture)
  selected = core + guards
  raise "W103 writer profile drift: expected 80, got #{selected.size}" unless selected.size == 80
  selected
end

private def w103o_main : Nil
  binary = ENV["CLICKHOUSE_BIN"]? || raise "CLICKHOUSE_BIN is required"
  store = ENV["W103O_STORE"]? || raise "W103O_STORE is required"
  writer_root = ENV["W103O_WRITER_ROOT"]? || raise "W103O_WRITER_ROOT is required"
  catalog_root = ENV["W103O_CATALOG_ROOT"]? || raise "W103O_CATALOG_ROOT is required"
  version = w103o_clickhouse(binary, store, "SELECT version() FORMAT TSVRaw").strip
  raise "W103 requires ClickHouse #{W103O_VERSION}, got #{version}" unless version == W103O_VERSION

  core = w103o_core_fixtures
  guards = w103o_guard_fixtures
  all = core + guards
  raise "W103 profile count differs" unless all.size == 80
  first_core_part = ""
  consumer_labels = core.select do |fixture|
    (fixture.dimension == 10_u64 && fixture.explicit_stride.nil?) ||
      (fixture.dimension == 16_u64 && fixture.explicit_stride == 8_u64)
  end.map(&.label)
  all.each do |fixture|
    part = w103o_check_stock_profile(binary, store, catalog_root, fixture, consumer_labels.includes?(fixture.label))
    first_core_part = part if fixture.label == core[0].label
  end

  first_plane = core[0].plane_stream(0)
  actual_plane = w103o_decoded(File.read(File.join(first_core_part, "#{CrystalClick::StreamName.hash(first_plane)}.bin")).to_slice, "W103 first measured plane")
  w103o_seeded_plane_comparator(
    actual_plane,
    core[0].expected_streams[first_plane],
    "W103 independent transposition",
  )

  w103o_cross_frame_control(binary, store)

  w103o_writer_profiles(core, guards).each do |fixture|
    part = w103o_write_fixture(writer_root, fixture)
    w103o_attach_writer(binary, store, fixture, part)
  end
  puts "PASS W103: 72 canonical scalar/Nullable profiles, 8 zero/NULL controls, all 80 writer profiles, one 3000-row split-plane control"
  nil
end

w103o_main
