# W102 independent stock -> reader -> writer -> stock oracle. All decimal
# expectations are built from signed little-endian coefficient bytes, never
# from CrystalClick's parser or serializers.
require "json"
require "file_utils"
require "../src/crystal_click"

W102O_VERSION     = "26.7.1.1315"
W102O_KEYS        = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
W102O_MARK_ROWS   = [2_u64, 2_u64, 1_u64, 0_u64]
W102O_READER_ROWS = [2_u64, 2_u64, 1_u64]
W102O_PS          = [1, 9, 10, 18, 19, 38, 39, 76, 7, 15, 25, 50]

alias W102ORow = Array(Array(String?))

struct W102OShape
  getter id : Int32
  getter label : String

  def initialize(@id : Int32, @label : String)
  end

  def type_name(p : Int32, s : Int32) : String
    leaf = "Decimal(#{p}, #{s})"
    case @id
    when 0 then leaf
    when 1 then "Nullable(#{leaf})"
    when 2 then "Array(#{leaf})"
    when 3 then "Array(Nullable(#{leaf}))"
    when 4 then "Array(Array(#{leaf}))"
    when 5 then "Array(Array(Nullable(#{leaf})))"
    else        raise "unknown W102 shape #{@id}"
    end
  end

  def streams : Array(String)
    case @id
    when 0 then ["payload"]
    when 1 then ["payload.null", "payload"]
    when 2 then ["payload.size0", "payload"]
    when 3 then ["payload.size0", "payload.null", "payload"]
    when 4 then ["payload.size0", "payload.size1", "payload"]
    when 5 then ["payload.size0", "payload.size1", "payload.null", "payload"]
    else        raise "unknown W102 shape #{@id}"
    end
  end
end

W102O_SHAPES = [
  W102OShape.new(0, "scalar"),
  W102OShape.new(1, "nullable_scalar"),
  W102OShape.new(2, "array"),
  W102OShape.new(3, "array_nullable"),
  W102OShape.new(4, "array_array"),
  W102OShape.new(5, "array_array_nullable"),
]

struct W102OFixture
  getter label : String
  getter shape : W102OShape
  getter precision : Int32
  getter scale : Int32
  getter width : Int32
  getter rows : Array(W102ORow)
  getter ratio : String

  def initialize(@label : String, @shape : W102OShape, @precision : Int32, @scale : Int32, @width : Int32, @rows : Array(W102ORow), @ratio : String = "1.0")
    raise "#{@label}: expected five rows" unless @rows.size == W102O_KEYS.size
  end

  def type_name : String
    @shape.type_name(@precision, @scale)
  end

  def source_table : String
    "w102s_#{@label}"
  end

  def writer_table : String
    "w102w_#{@label}"
  end

  def streams : Array(String)
    ["pk"] + @shape.streams
  end
end

class W102OByteMismatchError < Exception
end

private def w102o_u64(value : UInt64) : String
  output = IO::Memory.new
  8.times { |index| output.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
  output.to_s
end

private def w102o_append_u64(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

private def w102o_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w102o_signed_le(value : Int128, width : Int32) : String
  bits = value.unsafe_as(UInt128)
  output = IO::Memory.new
  width.times { |index| output.write_byte(((bits >> (index * 8)) & 0xff_u128).to_u8) }
  output.to_s
end

private def w102o_unsigned_le(value : UInt128, width : Int32) : String
  output = IO::Memory.new
  width.times { |index| output.write_byte(((value >> (index * 8)) & 0xff_u128).to_u8) }
  output.to_s
end

private def w102o_bytes_from_u8(bytes : Array(UInt8)) : String
  return "" if bytes.empty?
  String.new(bytes.to_unsafe, bytes.size)
end

private def w102o_positive_max(p : Int32, width : Int32) : Array(UInt8)
  bytes = Array(UInt8).new(width, 0_u8)
  p.times do
    carry = 9_u16
    bytes.each_index do |index|
      value = bytes[index].to_u16 * 10_u16 + carry
      bytes[index] = (value & 0xff_u16).to_u8
      carry = value >> 8
    end
    raise "P=#{p} does not fit width #{width}" unless carry == 0
  end
  bytes
end

private def w102o_negate(bytes : Array(UInt8)) : Array(UInt8)
  output = bytes.map { |byte| ~byte }
  carry = 1_u16
  output.each_index do |index|
    value = output[index].to_u16 + carry
    output[index] = (value & 0xff_u16).to_u8
    carry = value >> 8
  end
  raise "two's-complement negate overflow" unless carry == 0
  output
end

private def w102o_width(p : Int32) : Int32
  case p
  when 1..9   then 4
  when 10..18 then 8
  when 19..38 then 16
  when 39..76 then 32
  else             raise "precision outside W102 bounds: #{p}"
  end
end

private def w102o_coefficients(p : Int32, width : Int32, native_extrema : Bool = false) : Array(String)
  if native_extrema
    minimum = Array(UInt8).new(width, 0_u8)
    maximum = Array(UInt8).new(width, 0xff_u8)
    minimum[width - 1] = 0x80_u8
    maximum[width - 1] = 0x7f_u8
    negative_one = Array(UInt8).new(width, 0xff_u8)
    zero = Array(UInt8).new(width, 0_u8)
    positive_one = Array(UInt8).new(width, 0_u8)
    positive_one[0] = 1_u8
    return [minimum, negative_one, zero, positive_one, maximum].map { |bytes| w102o_bytes_from_u8(bytes) }
  end
  maximum = w102o_positive_max(p, width)
  negative_maximum = w102o_negate(maximum)
  negative_one = Array(UInt8).new(width, 0xff_u8)
  zero = Array(UInt8).new(width, 0_u8)
  positive_one = Array(UInt8).new(width, 0_u8)
  positive_one[0] = 1_u8
  [negative_maximum, negative_one, zero, positive_one, maximum].map { |bytes| w102o_bytes_from_u8(bytes) }
end

private def w102o_rows(shape : W102OShape, coefficients : Array(String)) : Array(W102ORow)
  negative_max, negative_one, zero, positive_one, maximum = coefficients
  nm = negative_max.as(String?)
  no = negative_one.as(String?)
  z = zero.as(String?)
  po = positive_one.as(String?)
  mx = maximum.as(String?)
  rows = [] of W102ORow
  case shape.id
  when 0
    rows << [[nm]]
    rows << [[no]]
    rows << [[z]]
    rows << [[po]]
    rows << [[mx]]
  when 1
    rows << [[nm]]
    rows << [[nil] of String?]
    rows << [[z]]
    rows << [[po]]
    rows << [[mx]]
  when 2
    rows << [[] of String?]
    rows << [[nm, mx]]
    rows << [[z]]
    rows << [[po]]
    rows << [[no, mx]]
  when 3
    rows << [[] of String?]
    rows << [[nm, nil, mx] of String?]
    rows << [[nil, nil] of String?]
    rows << [[z]]
    rows << [[po, no]]
  when 4
    rows << ([] of Array(String?))
    rows << [([] of String?), [nm, mx]]
    rows << [([] of String?)]
    rows << [[z], ([] of String?)]
    rows << [[po, no]]
  when 5
    rows << ([] of Array(String?))
    rows << [([] of String?), [nm, nil, mx] of String?]
    rows << [([] of String?)]
    rows << [[nil, nil] of String?, [z]]
    rows << [[po, no]]
  else
    raise "unknown W102 shape #{shape.id}"
  end
  rows
end

private def w102o_scale(shape : W102OShape, p : Int32) : Int32
  case shape.id % 3
  when 0 then 0
  when 1 then p // 2
  else        p
  end
end

private def w102o_fixture(shape : W102OShape, p : Int32, label : String, native_extrema : Bool = false, ratio : String = "1.0") : W102OFixture
  width = w102o_width(p)
  coefficients = w102o_coefficients(p, width, native_extrema)
  W102OFixture.new(label, shape, p, w102o_scale(shape, p), width, w102o_rows(shape, coefficients), ratio)
end

private def w102o_all_zero_fixture(p : Int32, label : String, ratio : String = "1.0") : W102OFixture
  shape = W102O_SHAPES[0]
  zero = String.new(Bytes.new(w102o_width(p), 0_u8))
  rows = Array(W102ORow).new(W102O_KEYS.size) { [[zero] of String?] }
  W102OFixture.new(label, shape, p, 0, w102o_width(p), rows, ratio)
end

private def w102o_all_null_fixture(p : Int32, label : String) : W102OFixture
  shape = W102O_SHAPES[1]
  rows = Array(W102ORow).new(W102O_KEYS.size) { [[nil] of String?] }
  W102OFixture.new(label, shape, p, p // 2, w102o_width(p), rows)
end

private def w102o_all_empty_array_fixture(p : Int32, label : String, nested : Bool = false) : W102OFixture
  shape = nested ? W102O_SHAPES[4] : W102O_SHAPES[2]
  rows = if nested
           [
             [] of Array(String?),
             [[] of String?],
             [([] of String?), ([] of String?)],
             [] of Array(String?),
             [[] of String?],
           ] of W102ORow
         else
           Array(W102ORow).new(W102O_KEYS.size) { [[] of String?] }
         end
  W102OFixture.new(label, shape, p, nested ? p : 0, w102o_width(p), rows)
end

private def w102o_required(value : String?, fixture : W102OFixture) : String
  value || raise "#{fixture.label}: unexpected NULL leaf"
end

private def w102o_append_nullable(io : IO, value : String?) : Nil
  if raw = value
    io.write_byte(0_u8)
    io << raw
  else
    io.write_byte(1_u8)
  end
end

private def w102o_append_rowbinary_payload(io : IO, fixture : W102OFixture, row : W102ORow) : Nil
  case fixture.shape.id
  when 0 then io << w102o_required(row[0][0], fixture)
  when 1 then w102o_append_nullable(io, row[0][0])
  when 2
    values = row[0]
    w102o_varuint(io, values.size.to_u64)
    values.each { |value| io << w102o_required(value, fixture) }
  when 3
    values = row[0]
    w102o_varuint(io, values.size.to_u64)
    values.each { |value| w102o_append_nullable(io, value) }
  when 4
    w102o_varuint(io, row.size.to_u64)
    row.each do |inner|
      w102o_varuint(io, inner.size.to_u64)
      inner.each { |value| io << w102o_required(value, fixture) }
    end
  when 5
    w102o_varuint(io, row.size.to_u64)
    row.each do |inner|
      w102o_varuint(io, inner.size.to_u64)
      inner.each { |value| w102o_append_nullable(io, value) }
    end
  else
    raise "unknown W102 shape #{fixture.shape.id}"
  end
end

private def w102o_expected_rowbinary(fixture : W102OFixture, indexes : Array(Int32)) : String
  output = IO::Memory.new
  indexes.each do |index|
    w102o_append_u64(output, W102O_KEYS[index])
    w102o_append_rowbinary_payload(output, fixture, fixture.rows[index])
  end
  output.to_s
end

private def w102o_expected_payload(fixture : W102OFixture, indexes : Array(Int32)) : String
  output = IO::Memory.new
  indexes.each { |index| w102o_append_rowbinary_payload(output, fixture, fixture.rows[index]) }
  output.to_s
end

private def w102o_stream_segments(fixture : W102OFixture) : Hash(String, Array(String))
  segments = Hash(String, Array(String)).new
  segments["pk"] = [] of String
  fixture.streams.each { |stream| segments[stream] ||= [] of String }
  3.times do |mark|
    first = mark * 2
    finish = Math.min(first + 2, fixture.rows.size)
    pk = IO::Memory.new
    payload = IO::Memory.new
    null_map = IO::Memory.new
    size0 = IO::Memory.new
    size1 = IO::Memory.new
    (first...finish).each { |index| w102o_append_u64(pk, W102O_KEYS[index]) }
    (first...finish).each do |index|
      row = fixture.rows[index]
      case fixture.shape.id
      when 0
        payload << w102o_required(row[0][0], fixture)
      when 1
        value = row[0][0]
        null_map.write_byte(value.nil? ? 1_u8 : 0_u8)
        payload << (value || String.new(Bytes.new(fixture.width, 0_u8)))
      when 2
        values = row[0]
        w102o_append_u64(size0, values.size.to_u64)
        values.each { |value| payload << w102o_required(value, fixture) }
      when 3
        values = row[0]
        w102o_append_u64(size0, values.size.to_u64)
        values.each do |value|
          null_map.write_byte(value.nil? ? 1_u8 : 0_u8)
          payload << (value || String.new(Bytes.new(fixture.width, 0_u8)))
        end
      when 4
        w102o_append_u64(size0, row.size.to_u64)
        row.each do |inner|
          w102o_append_u64(size1, inner.size.to_u64)
          inner.each { |value| payload << w102o_required(value, fixture) }
        end
      when 5
        w102o_append_u64(size0, row.size.to_u64)
        row.each do |inner|
          w102o_append_u64(size1, inner.size.to_u64)
          inner.each do |value|
            null_map.write_byte(value.nil? ? 1_u8 : 0_u8)
            payload << (value || String.new(Bytes.new(fixture.width, 0_u8)))
          end
        end
      else
        raise "unknown W102 shape #{fixture.shape.id}"
      end
    end
    segments["pk"] << pk.to_s
    segments["payload"] << payload.to_s
    segments["payload.null"] << null_map.to_s unless fixture.shape.id == 0 || fixture.shape.id == 2 || fixture.shape.id == 4
    segments["payload.size0"] << size0.to_s if fixture.shape.id >= 2
    segments["payload.size1"] << size1.to_s if fixture.shape.id >= 4
  end
  segments.each_value { |parts| parts << "" }
  segments
end

private def w102o_expected_streams(fixture : W102OFixture) : Hash(String, String)
  w102o_stream_segments(fixture).transform_values(&.join)
end

private def w102o_assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual == expected
  limit = Math.min(actual.bytesize, expected.bytesize)
  index = 0
  while index < limit && actual.to_slice[index] == expected.to_slice[index]
    index += 1
  end
  got = index < actual.bytesize ? actual.to_slice[index].to_s(16).rjust(2, '0') : "<eof>"
  want = index < expected.bytesize ? expected.to_slice[index].to_s(16).rjust(2, '0') : "<eof>"
  raise W102OByteMismatchError.new("#{label}: expected #{expected.bytesize} bytes, got #{actual.bytesize}; first difference #{index}: expected #{want}, got #{got}")
end

private def w102o_u64_at(bytes : Bytes, offset : Int32) : UInt64
  8.times.reduce(0_u64) { |value, index| value | (bytes[offset + index].to_u64 << (index * 8)) }
end

private def w102o_mark_records(part : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  raise "#{part} missing mark file for #{stream}" unless File.file?(path)
  bytes = File.read(path).to_slice
  raise "#{stream}: partial .mrk2 row" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {w102o_u64_at(bytes, offset), w102o_u64_at(bytes, offset + 8), w102o_u64_at(bytes, offset + 16)}
  end
end

private def w102o_clickhouse(binary : String, store : String, query : String, input : IO? = nil) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", query], input: input || Process::Redirect::Close, output: output, error: error)
  raise "ClickHouse command failed (#{status.exit_code}): #{error}\n#{query}" unless status.success?
  output.to_s
end

private def w102o_settings(ratio : String) : String
  "index_granularity = 2, index_granularity_bytes = 10485760, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, ratio_of_defaults_for_sparse_serialization = #{ratio}, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, default_compression_codec = 'LZ4'"
end

private def w102o_create_table(binary : String, store : String, table : String, fixture : W102OFixture) : Nil
  w102o_clickhouse(binary, store, "CREATE TABLE default.#{table} (pk UInt64, payload #{fixture.type_name}) ENGINE = MergeTree ORDER BY pk SETTINGS #{w102o_settings(fixture.ratio)}")
  nil
end

private def w102o_part_path(binary : String, store : String, table : String, label : String) : String
  lines = w102o_clickhouse(binary, store, "SELECT path, part_type, rows FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines.map(&.strip).reject(&.empty?)
  raise "#{label}: expected one active part, got #{lines.inspect}" unless lines.size == 1
  fields = lines[0].split('\t')
  raise "#{label}: malformed system.parts row" unless fields.size == 3
  raise "#{label}: expected Wide part, got #{fields[1]}" unless fields[1] == "Wide"
  raise "#{label}: expected five rows, got #{fields[2]}" unless fields[2] == W102O_KEYS.size.to_s
  fields[0]
end

private def w102o_expected_columns(fixture : W102OFixture) : String
  "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{fixture.type_name}\n"
end

private def w102o_expected_substreams(fixture : W102OFixture) : String
  streams = fixture.shape.streams
  lines = ["columns substreams version: 1", "2 columns:", "1 substreams for column `pk`:", "\tpk", "#{streams.size} substreams for column `payload`:"]
  streams.each { |stream| lines << "\t#{stream}" }
  lines.join("\n") + "\n"
end

private def w102o_validate_metadata(part : String, fixture : W102OFixture, stats_defaults : Bool = false, require_empty_records : Bool = false) : Nil
  info = JSON.parse(File.read(File.join(part, "serialization.json"))).as_h
  required_keys = ["columns", "propagate_types_serialization_versions_to_nested_types", "types_serialization_versions", "version"].sort
  raise "#{fixture.label}: serialization metadata keys differ" unless info.keys.sort == required_keys
  raise "#{fixture.label}: serialization version differs" unless info["version"]?.try(&.as_i) == 1
  raise "#{fixture.label}: type version propagation differs" unless info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  versions = info["types_serialization_versions"]?.try(&.as_h) || raise "#{fixture.label}: type versions absent"
  raise "#{fixture.label}: expected pinned type version map {string: 1}" unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
  records = info["columns"]?.try(&.as_a) || raise "#{fixture.label}: columns metadata is not an array"
  if stats_defaults
    raise "#{fixture.label}: statistics profile omitted serializer records" if records.empty?
    payload = records.find { |record| record.as_h["name"]?.try(&.as_s) == "payload" }.try(&.as_h) || raise "#{fixture.label}: Decimal serializer record absent"
    raise "#{fixture.label}: Decimal default serializer kind differs: #{payload["kind"]?.try(&.as_s)}" unless payload["kind"]?.try(&.as_s) == "Sparse"
    raise "#{fixture.label}: Decimal num_rows differs" unless payload["num_rows"]?.try(&.as_i) == W102O_KEYS.size.to_i64
    raise "#{fixture.label}: Decimal raw-zero default count differs" unless payload["num_defaults"]?.try(&.as_i) == W102O_KEYS.size.to_i64
  elsif require_empty_records
    raise "#{fixture.label}: writer metadata records differ" unless records.empty?
  elsif records.empty?
    raise "#{fixture.label}: ratio-1 columns=[] is permitted only without a default-counter claim" unless fixture.ratio == "1.0"
    puts "OBSERVED #{fixture.label}: ratio-1 columns=[]; no serialization counter claim"
  else
    names = records.map { |record| record.as_h["name"]?.try(&.as_s) || raise "#{fixture.label}: serializer name absent" }.sort
    raise "#{fixture.label}: serializer roots differ: #{names.inspect}" unless names == ["payload", "pk"]
  end
  nil
end

# Stock may co-pack rows from adjacent granules in one compressed frame, or
# represent an empty mark with no frame at all. Resolve every mark to an
# absolute decompressed position, then compare it with independently assembled
# per-granule bytes. This validates empty marks and frame bounds without
# assuming a frame boundary at every mark.
private def w102o_decode_expected_stream(encoded : Bytes, expected_empty : Bool, label : String) : String
  if encoded.empty?
    raise "#{label}: missing bytes for nonempty expected stream" unless expected_empty
    return ""
  end
  String.new(CrystalClick::CompressedBlock.decode_all(encoded))
end

private def w102o_assert_mark_windows(fixture : W102OFixture, part : String, stream : String, injected_marks : Array(Tuple(UInt64, UInt64, UInt64))? = nil) : Nil
  segments = w102o_stream_segments(fixture)[stream]
  records = injected_marks || w102o_mark_records(part, stream)
  encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  raise "#{fixture.label} #{stream}: mark rows differ" unless records.map(&.[2]) == W102O_MARK_ROWS
  raise "#{fixture.label} #{stream}: expected three data granules and sentinel" unless segments.size == 4 && records.size == 4
  decoded_stream = w102o_decode_expected_stream(encoded, segments.all?(&.empty?), "#{fixture.label} #{stream}")

  # CompressedBlock::Frame.end_offset is absolute in `encoded`; retain each
  # independently decoded frame's absolute input and output interval.
  frame_ranges = [] of Tuple(UInt64, UInt64, UInt64, UInt64)
  compressed_offset = 0_u64
  decoded_offset = 0_u64
  while compressed_offset < encoded.size
    frame = CrystalClick::CompressedBlock.decode_frame(encoded, compressed_offset.to_i64)
    ending = frame.end_offset.to_u64
    raise "#{fixture.label} #{stream}: invalid compressed frame boundary" unless ending > compressed_offset && ending <= encoded.size.to_u64
    frame_ranges << {compressed_offset, ending, decoded_offset, frame.output.size.to_u64}
    compressed_offset = ending
    decoded_offset &+= frame.output.size.to_u64
  end
  raise "#{fixture.label} #{stream}: frame inventory does not consume the complete stream" unless compressed_offset == encoded.size.to_u64

  expected_prefix = 0_u64
  # The sentinel may address the end of the final buffered frame, not only
  # {compressed_file_size, 0}. It must resolve to the same exact logical EOF.
  4.times do |index|
    compressed_offset, decompressed_offset, _ = records[index]
    raise "#{fixture.label} #{stream} mark #{index}: compressed offset outside stream" if compressed_offset > encoded.size.to_u64
    absolute_offset = if compressed_offset == encoded.size.to_u64
                        raise "#{fixture.label} #{stream} mark #{index}: nonzero offset at EOF" unless decompressed_offset == 0_u64
                        decoded_offset
                      else
                        range = frame_ranges.find { |entry| entry[0] == compressed_offset } || raise "#{fixture.label} #{stream} mark #{index}: compressed offset is not a frame start"
                        raise "#{fixture.label} #{stream} mark #{index}: decompressed offset outside frame" if decompressed_offset > range[3]
                        range[2] &+ decompressed_offset
                      end
    raise "#{fixture.label} #{stream} mark #{index}: logical byte boundary differs" unless absolute_offset == expected_prefix
    segment = segments[index]
    raise "#{fixture.label} #{stream} mark #{index}: expected segment does not match independent decoded window" if segment.bytesize.to_u64 > decoded_offset - expected_prefix
    if segment.bytesize > 0
      actual = decoded_stream.byte_slice(expected_prefix.to_i, segment.bytesize)
      w102o_assert_bytes(actual, segment, "#{fixture.label} #{stream} mark #{index} window")
    end
    expected_prefix &+= segment.bytesize.to_u64
  end
  raise "#{fixture.label} #{stream}: mark byte coverage differs" unless expected_prefix == decoded_offset
  nil
end

private def w102o_assert_part(fixture : W102OFixture, part : String, stats_defaults : Bool = false, writer_metadata : Bool = false) : Nil
  raise "#{fixture.label}: columns.txt differs" unless File.read(File.join(part, "columns.txt")) == w102o_expected_columns(fixture)
  raise "#{fixture.label}: columns_substreams.txt differs" unless File.read(File.join(part, "columns_substreams.txt")) == w102o_expected_substreams(fixture)
  raise "#{fixture.label}: compression codec differs" unless File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)"
  w102o_validate_metadata(part, fixture, stats_defaults, writer_metadata)
  expected = w102o_expected_streams(fixture)
  expected_bins = expected.keys.map { |stream| "#{CrystalClick::StreamName.hash(stream)}.bin" }.sort
  expected_marks = expected.keys.map { |stream| "#{CrystalClick::StreamName.hash(stream)}.mrk2" }.sort
  entries = Dir.children(part)
  raise "#{fixture.label}: complete .bin inventory differs" unless entries.select(&.ends_with?(".bin")).sort == expected_bins
  raise "#{fixture.label}: complete .mrk2 inventory differs" unless entries.select(&.ends_with?(".mrk2")).sort == expected_marks
  raise "#{fixture.label}: compressed marks are outside this profile" unless Dir.glob(File.join(part, "*.cmrk*")).empty?
  raise "#{fixture.label}: alternate mark format is outside this profile" unless Dir.glob(File.join(part, "*.mrk")).empty? && Dir.glob(File.join(part, "*.mrk3")).empty?
  expected.each do |stream, raw|
    encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
    decoded = w102o_decode_expected_stream(encoded, raw.empty?, "#{fixture.label} #{stream}")
    w102o_assert_bytes(decoded, raw, "#{fixture.label} #{stream} full physical stream")
    w102o_assert_mark_windows(fixture, part, stream)
  end
  nil
end

private def w102o_insert_input(fixture : W102OFixture, indexes : Array(Int32) = (0...W102O_KEYS.size).map(&.to_i32)) : IO::Memory
  IO::Memory.new(w102o_expected_rowbinary(fixture, indexes).to_slice).tap(&.rewind)
end

private def w102o_check(binary : String, store : String, table : String, part : String) : Nil
  actual = w102o_clickhouse(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  expected = "#{File.basename(part.chomp("/"))}\t1"
  raise "#{table}: stock CHECK TABLE differs: #{actual.inspect}" unless actual == expected
  nil
end

private def w102o_stock_rowbinary(binary : String, store : String, table : String, fixture : W102OFixture, indexes : Array(Int32), key_range : Bool = false) : Nil
  predicate = key_range ? " WHERE pk >= 2 AND pk < 5" : ""
  actual = w102o_clickhouse(binary, store, "SELECT pk, payload FROM default.#{table}#{predicate} ORDER BY pk FORMAT RowBinary")
  w102o_assert_bytes(actual, w102o_expected_rowbinary(fixture, indexes), "#{fixture.label} stock #{key_range ? "key-range" : "full"} RowBinary")
  nil
end

private def w102o_check_scalar_text(binary : String, store : String, fixture : W102OFixture) : Nil
  raise "#{fixture.label}: decimal text anchor requires a scale-zero scalar" unless fixture.shape.id == 0 && fixture.scale == 0
  actual = w102o_clickhouse(binary, store, "SELECT toString(payload) FROM default.#{fixture.source_table} WHERE pk IN (1, 5) ORDER BY pk FORMAT TSVRaw")
  nines = String.build { |text| fixture.precision.times { text << '9' } }
  expected = "-#{nines}\n#{nines}\n"
  w102o_assert_bytes(actual, expected, "#{fixture.label} independent decimal text endpoints")
  puts "PASS #{fixture.label}: stock decimal text agrees with independent P-digit endpoints"
  nil
end

private def w102o_create_stock(binary : String, store : String, fixture : W102OFixture, stats_defaults : Bool = false) : String
  w102o_create_table(binary, store, fixture.source_table, fixture)
  w102o_clickhouse(binary, store, "INSERT INTO default.#{fixture.source_table} FORMAT RowBinary", w102o_insert_input(fixture))
  part = w102o_part_path(binary, store, fixture.source_table, fixture.label)
  columns = w102o_clickhouse(binary, store, "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{fixture.source_table}' ORDER BY position FORMAT TSVRaw").lines.map(&.strip)
  raise "#{fixture.label}: system.columns did not preserve exact P/S" unless columns == ["pk UInt64", "payload #{fixture.type_name}"]
  if stats_defaults
    w102o_assert_stock_stats_layout(fixture, part)
  else
    w102o_assert_part(fixture, part)
  end
  w102o_check(binary, store, fixture.source_table, part)
  indexes = (0...W102O_KEYS.size).map(&.to_i32)
  w102o_stock_rowbinary(binary, store, fixture.source_table, fixture, indexes)
  w102o_stock_rowbinary(binary, store, fixture.source_table, fixture, [1_i32, 2_i32, 3_i32], true)
  if stats_defaults
    puts "PASS stock stats #{fixture.label}: exact schema, default counters, CHECK and independent RowBinary"
  else
    puts "PASS stock #{fixture.label}: exact P/S, independent streams/marks, CHECK and RowBinary"
  end
  part
end

private def w102o_append_value(io : IO, value : Int32) : Nil
  io << w102o_signed_le(value.to_i128, 4)
end

private def w102o_append_value(io : IO, value : Int64) : Nil
  io << w102o_signed_le(value.to_i128, 8)
end

private def w102o_append_value(io : IO, value : Int128) : Nil
  io << w102o_signed_le(value, 16)
end

private def w102o_decimal256_bytes(value : CrystalClick::Decimal256Value) : String
  w102o_unsigned_le(value.low, 16) + w102o_unsigned_le(value.high, 16)
end

private def w102o_append_value(io : IO, value : CrystalClick::Decimal256Value) : Nil
  io << w102o_decimal256_bytes(value)
end

private def w102o_append_nullable_value(io : IO, value : T?) : Nil forall T
  if item = value
    io.write_byte(0_u8)
    w102o_append_value(io, item)
  else
    io.write_byte(1_u8)
  end
end

private def w102o_append_value(io : IO, values : Array(T)) : Nil forall T
  w102o_varuint(io, values.size.to_u64)
  values.each { |value| w102o_append_value(io, value) }
end

private def w102o_append_schema_value(io : IO, value : Int32, nullable : Bool) : Nil
  io.write_byte(0_u8) if nullable
  w102o_append_value(io, value)
end

private def w102o_append_schema_value(io : IO, value : Int64, nullable : Bool) : Nil
  io.write_byte(0_u8) if nullable
  w102o_append_value(io, value)
end

private def w102o_append_schema_value(io : IO, value : Int128, nullable : Bool) : Nil
  io.write_byte(0_u8) if nullable
  w102o_append_value(io, value)
end

private def w102o_append_schema_value(io : IO, value : CrystalClick::Decimal256Value, nullable : Bool) : Nil
  io.write_byte(0_u8) if nullable
  w102o_append_value(io, value)
end

private def w102o_append_schema_value(io : IO, value : Nil, nullable : Bool) : Nil
  raise "Nil leaf is not admitted by the declared Decimal schema" unless nullable
  io.write_byte(1_u8)
end

private def w102o_append_schema_value(io : IO, value : Int32?, nullable : Bool) : Nil
  if item = value
    w102o_append_schema_value(io, item, nullable)
  else
    w102o_append_schema_value(io, nil.as(Nil), nullable)
  end
end

private def w102o_append_schema_value(io : IO, value : Int64?, nullable : Bool) : Nil
  if item = value
    w102o_append_schema_value(io, item, nullable)
  else
    w102o_append_schema_value(io, nil.as(Nil), nullable)
  end
end

private def w102o_append_schema_value(io : IO, value : Int128?, nullable : Bool) : Nil
  if item = value
    w102o_append_schema_value(io, item, nullable)
  else
    w102o_append_schema_value(io, nil.as(Nil), nullable)
  end
end

private def w102o_append_schema_value(io : IO, value : CrystalClick::Decimal256Value?, nullable : Bool) : Nil
  if item = value
    w102o_append_schema_value(io, item, nullable)
  else
    w102o_append_schema_value(io, nil.as(Nil), nullable)
  end
end

private def w102o_append_schema_value(io : IO, values : Array(T), nullable : Bool) : Nil forall T
  w102o_varuint(io, values.size.to_u64)
  values.each { |value| w102o_append_schema_value(io, value, nullable) }
end

private def w102o_append_nullable_array(io : IO, values : Array(T?)) : Nil forall T
  w102o_varuint(io, values.size.to_u64)
  values.each { |value| w102o_append_nullable_value(io, value) }
end

private def w102o_append_nested_nullable_array(io : IO, values : Array(Array(T?))) : Nil forall T
  w102o_varuint(io, values.size.to_u64)
  values.each { |inner| w102o_append_nullable_array(io, inner) }
end

private def w102o_append_typed_value(io : IO, value : T, fixture : W102OFixture) : Nil forall T
  raise "#{fixture.label}: unsupported Decimal width" unless {4, 8, 16, 32}.includes?(fixture.width)
  nullable = case fixture.shape.id
             when 0, 2, 4 then false
             when 1, 3, 5 then true
             else              raise "#{fixture.label}: unsupported Decimal shape"
             end
  w102o_append_schema_value(io, value, nullable)
end

private def w102o_check_values(values : Array(T), fixture : W102OFixture, indexes : Array(Int32), label : String) : Nil forall T
  actual = IO::Memory.new
  values.each { |value| w102o_append_typed_value(actual, value, fixture) }
  w102o_assert_bytes(actual.to_s, w102o_expected_payload(fixture, indexes), label)
end

private def w102o_check_reader(part : String, fixture : W102OFixture) : CrystalClick::WidePart
  reader = CrystalClick::WidePart.open_typed(part, "payload")
  raise "#{fixture.label}: reader exact type differs: #{reader.column_type}" unless reader.column_type == fixture.type_name
  raise "#{fixture.label}: logical mark row counts differ" unless reader.mark_row_counts == W102O_READER_ROWS
  w102o_read_ranges(reader, fixture, [0_i32, 1_i32, 2_i32, 3_i32, 4_i32], "full")
  w102o_read_ranges(reader, fixture, [2_i32, 3_i32, 4_i32], "selected marks 1..2", 1, 2)
  reader
end

private def w102o_read_ranges(reader : CrystalClick::WidePart, fixture : W102OFixture, indexes : Array(Int32), label : String, first_mark : Int32 = 0, mark_count : Int32 = 3) : Nil
  case fixture.width
  when 4
    case fixture.shape.id
    when 0 then w102o_check_values(reader.read_decimal32_raw_mark_range("payload", first_mark, mark_count), fixture, indexes, "#{fixture.label} #{label}")
    when 1 then w102o_check_values(reader.read_nullable_decimal32_raw_mark_range("payload", first_mark, mark_count), fixture, indexes, "#{fixture.label} #{label}")
    when 2 then w102o_check_values(reader.read_array_decimal32_raw_mark_range("payload", first_mark, mark_count), fixture, indexes, "#{fixture.label} #{label}")
    when 3 then w102o_check_values(reader.read_array_nullable_decimal32_raw_mark_range("payload", first_mark, mark_count), fixture, indexes, "#{fixture.label} #{label}")
    when 4 then w102o_check_values(reader.read_array_array_decimal32_mark_range("payload", first_mark, mark_count), fixture, indexes, "#{fixture.label} #{label}")
    when 5 then w102o_check_values(reader.read_array_array_nullable_decimal32_mark_range("payload", first_mark, mark_count), fixture, indexes, "#{fixture.label} #{label}")
    else        raise "#{fixture.label}: unknown shape"
    end
  when 8
    case fixture.shape.id
    when 0 then w102o_check_values(reader.read_decimal64_raw_mark_range("payload", first_mark, mark_count), fixture, indexes, "#{fixture.label} #{label}")
    when 1 then w102o_check_values(reader.read_nullable_decimal64_raw_mark_range("payload", first_mark, mark_count), fixture, indexes, "#{fixture.label} #{label}")
    when 2 then w102o_check_values(reader.read_array_decimal64_raw_mark_range("payload", first_mark, mark_count), fixture, indexes, "#{fixture.label} #{label}")
    when 3 then w102o_check_values(reader.read_array_nullable_decimal64_raw_mark_range("payload", first_mark, mark_count), fixture, indexes, "#{fixture.label} #{label}")
    when 4 then w102o_check_values(reader.read_array_array_decimal64_mark_range("payload", first_mark, mark_count), fixture, indexes, "#{fixture.label} #{label}")
    when 5 then w102o_check_values(reader.read_array_array_nullable_decimal64_mark_range("payload", first_mark, mark_count), fixture, indexes, "#{fixture.label} #{label}")
    else        raise "#{fixture.label}: unknown shape"
    end
  when 16
    case fixture.shape.id
    when 0 then w102o_check_values(reader.read_decimal128_raw_mark_range("payload", first_mark, mark_count), fixture, indexes, "#{fixture.label} #{label}")
    when 1 then w102o_check_values(reader.read_nullable_decimal128_raw_mark_range("payload", first_mark, mark_count), fixture, indexes, "#{fixture.label} #{label}")
    when 2 then w102o_check_values(reader.read_array_decimal128_raw_mark_range("payload", first_mark, mark_count), fixture, indexes, "#{fixture.label} #{label}")
    when 3 then w102o_check_values(reader.read_array_nullable_decimal128_raw_mark_range("payload", first_mark, mark_count), fixture, indexes, "#{fixture.label} #{label}")
    when 4 then w102o_check_values(reader.read_array_array_decimal128_mark_range("payload", first_mark, mark_count), fixture, indexes, "#{fixture.label} #{label}")
    when 5 then w102o_check_values(reader.read_array_array_nullable_decimal128_mark_range("payload", first_mark, mark_count), fixture, indexes, "#{fixture.label} #{label}")
    else        raise "#{fixture.label}: unknown shape"
    end
  when 32
    case fixture.shape.id
    when 0 then w102o_check_values(reader.read_decimal256_raw_mark_range("payload", first_mark, mark_count), fixture, indexes, "#{fixture.label} #{label}")
    when 1 then w102o_check_values(reader.read_nullable_decimal256_raw_mark_range("payload", first_mark, mark_count), fixture, indexes, "#{fixture.label} #{label}")
    when 2 then w102o_check_values(reader.read_array_decimal256_raw_mark_range("payload", first_mark, mark_count), fixture, indexes, "#{fixture.label} #{label}")
    when 3 then w102o_check_values(reader.read_array_nullable_decimal256_raw_mark_range("payload", first_mark, mark_count), fixture, indexes, "#{fixture.label} #{label}")
    when 4 then w102o_check_values(reader.read_array_array_decimal256_mark_range("payload", first_mark, mark_count), fixture, indexes, "#{fixture.label} #{label}")
    when 5 then w102o_check_values(reader.read_array_array_nullable_decimal256_mark_range("payload", first_mark, mark_count), fixture, indexes, "#{fixture.label} #{label}")
    else        raise "#{fixture.label}: unknown shape"
    end
  else
    raise "#{fixture.label}: unsupported storage width"
  end
  nil
end

private def w102o_write_from_reader(writer_root : String, fixture : W102OFixture, source_part : String, keys : Array(UInt64)) : String
  reader = CrystalClick::WidePart.open_typed(source_part, "payload")
  path = File.join(writer_root, fixture.label, "all_1_1_0")
  FileUtils.mkdir_p(File.dirname(path))
  key_slice = keys.to_unsafe.to_slice(keys.size)
  case fixture.width
  when 4
    case fixture.shape.id
    when 0 then CrystalClick::WidePartWriter.write_uint64_decimal32_pair(path, "pk", key_slice, "payload", reader.read_decimal32_raw_mark_range("payload", 0, 3).to_unsafe.to_slice(5), fixture.scale, 2, precision: fixture.precision)
    when 1 then CrystalClick::WidePartWriter.write_uint64_nullable_decimal32_pair(path, "pk", key_slice, "payload", reader.read_nullable_decimal32_raw_mark_range("payload", 0, 3).to_unsafe.to_slice(5), fixture.scale, 2, precision: fixture.precision)
    when 2 then CrystalClick::WidePartWriter.write_uint64_array_decimal32_pair(path, "pk", key_slice, "payload", reader.read_array_decimal32_raw_mark_range("payload", 0, 3).to_unsafe.to_slice(5), fixture.scale, 2, precision: fixture.precision)
    when 3 then CrystalClick::WidePartWriter.write_uint64_array_nullable_decimal32_pair(path, "pk", key_slice, "payload", reader.read_array_nullable_decimal32_raw_mark_range("payload", 0, 3).to_unsafe.to_slice(5), fixture.scale, 2, precision: fixture.precision)
    when 4 then CrystalClick::WidePartWriter.write_uint64_array_array_decimal32_pair(path, "pk", key_slice, "payload", reader.read_array_array_decimal32_mark_range("payload", 0, 3).to_unsafe.to_slice(5), fixture.scale, 2, precision: fixture.precision)
    when 5 then CrystalClick::WidePartWriter.write_uint64_array_array_nullable_decimal32_pair(path, "pk", key_slice, "payload", reader.read_array_array_nullable_decimal32_mark_range("payload", 0, 3).to_unsafe.to_slice(5), fixture.scale, 2, precision: fixture.precision)
    else        raise "#{fixture.label}: unknown shape"
    end
  when 8
    case fixture.shape.id
    when 0 then CrystalClick::WidePartWriter.write_uint64_decimal64_pair(path, "pk", key_slice, "payload", reader.read_decimal64_raw_mark_range("payload", 0, 3).to_unsafe.to_slice(5), fixture.scale, 2, precision: fixture.precision)
    when 1 then CrystalClick::WidePartWriter.write_uint64_nullable_decimal64_pair(path, "pk", key_slice, "payload", reader.read_nullable_decimal64_raw_mark_range("payload", 0, 3).to_unsafe.to_slice(5), fixture.scale, 2, precision: fixture.precision)
    when 2 then CrystalClick::WidePartWriter.write_uint64_array_decimal64_pair(path, "pk", key_slice, "payload", reader.read_array_decimal64_raw_mark_range("payload", 0, 3).to_unsafe.to_slice(5), fixture.scale, 2, precision: fixture.precision)
    when 3 then CrystalClick::WidePartWriter.write_uint64_array_nullable_decimal64_pair(path, "pk", key_slice, "payload", reader.read_array_nullable_decimal64_raw_mark_range("payload", 0, 3).to_unsafe.to_slice(5), fixture.scale, 2, precision: fixture.precision)
    when 4 then CrystalClick::WidePartWriter.write_uint64_array_array_decimal64_pair(path, "pk", key_slice, "payload", reader.read_array_array_decimal64_mark_range("payload", 0, 3).to_unsafe.to_slice(5), fixture.scale, 2, precision: fixture.precision)
    when 5 then CrystalClick::WidePartWriter.write_uint64_array_array_nullable_decimal64_pair(path, "pk", key_slice, "payload", reader.read_array_array_nullable_decimal64_mark_range("payload", 0, 3).to_unsafe.to_slice(5), fixture.scale, 2, precision: fixture.precision)
    else        raise "#{fixture.label}: unknown shape"
    end
  when 16
    case fixture.shape.id
    when 0 then CrystalClick::WidePartWriter.write_uint64_decimal128_pair(path, "pk", key_slice, "payload", reader.read_decimal128_raw_mark_range("payload", 0, 3).to_unsafe.to_slice(5), fixture.scale, 2, precision: fixture.precision)
    when 1 then CrystalClick::WidePartWriter.write_uint64_nullable_decimal128_pair(path, "pk", key_slice, "payload", reader.read_nullable_decimal128_raw_mark_range("payload", 0, 3).to_unsafe.to_slice(5), fixture.scale, 2, precision: fixture.precision)
    when 2 then CrystalClick::WidePartWriter.write_uint64_array_decimal128_pair(path, "pk", key_slice, "payload", reader.read_array_decimal128_raw_mark_range("payload", 0, 3).to_unsafe.to_slice(5), fixture.scale, 2, precision: fixture.precision)
    when 3 then CrystalClick::WidePartWriter.write_uint64_array_nullable_decimal128_pair(path, "pk", key_slice, "payload", reader.read_array_nullable_decimal128_raw_mark_range("payload", 0, 3).to_unsafe.to_slice(5), fixture.scale, 2, precision: fixture.precision)
    when 4 then CrystalClick::WidePartWriter.write_uint64_array_array_decimal128_pair(path, "pk", key_slice, "payload", reader.read_array_array_decimal128_mark_range("payload", 0, 3).to_unsafe.to_slice(5), fixture.scale, 2, precision: fixture.precision)
    when 5 then CrystalClick::WidePartWriter.write_uint64_array_array_nullable_decimal128_pair(path, "pk", key_slice, "payload", reader.read_array_array_nullable_decimal128_mark_range("payload", 0, 3).to_unsafe.to_slice(5), fixture.scale, 2, precision: fixture.precision)
    else        raise "#{fixture.label}: unknown shape"
    end
  when 32
    case fixture.shape.id
    when 0 then CrystalClick::WidePartWriter.write_uint64_decimal256_pair(path, "pk", key_slice, "payload", reader.read_decimal256_raw_mark_range("payload", 0, 3).to_unsafe.to_slice(5), fixture.scale, 2, precision: fixture.precision)
    when 1 then CrystalClick::WidePartWriter.write_uint64_nullable_decimal256_pair(path, "pk", key_slice, "payload", reader.read_nullable_decimal256_raw_mark_range("payload", 0, 3).to_unsafe.to_slice(5), fixture.scale, 2, precision: fixture.precision)
    when 2 then CrystalClick::WidePartWriter.write_uint64_array_decimal256_pair(path, "pk", key_slice, "payload", reader.read_array_decimal256_raw_mark_range("payload", 0, 3).to_unsafe.to_slice(5), fixture.scale, 2, precision: fixture.precision)
    when 3 then CrystalClick::WidePartWriter.write_uint64_array_nullable_decimal256_pair(path, "pk", key_slice, "payload", reader.read_array_nullable_decimal256_raw_mark_range("payload", 0, 3).to_unsafe.to_slice(5), fixture.scale, 2, precision: fixture.precision)
    when 4 then CrystalClick::WidePartWriter.write_uint64_array_array_decimal256_pair(path, "pk", key_slice, "payload", reader.read_array_array_decimal256_mark_range("payload", 0, 3).to_unsafe.to_slice(5), fixture.scale, 2, precision: fixture.precision)
    when 5 then CrystalClick::WidePartWriter.write_uint64_array_array_nullable_decimal256_pair(path, "pk", key_slice, "payload", reader.read_array_array_nullable_decimal256_mark_range("payload", 0, 3).to_unsafe.to_slice(5), fixture.scale, 2, precision: fixture.precision)
    else        raise "#{fixture.label}: unknown shape"
    end
  else
    raise "#{fixture.label}: unsupported writer width"
  end
  w102o_assert_part(fixture, path, writer_metadata: true)
  w102o_assert_writer_frames(fixture, path)
  w102o_check_reader(path, fixture)
  puts "PASS writer #{fixture.label}: exact P/S metadata, independent full bytes/marks, and reader round-trip"
  path
end

private def w102o_write_guard_direct(writer_root : String, fixture : W102OFixture) : String
  path = File.join(writer_root, fixture.label, "all_1_1_0")
  FileUtils.mkdir_p(File.dirname(path))
  keys = W102O_KEYS
  key_slice = keys.to_unsafe.to_slice(keys.size)
  case {fixture.width, fixture.shape.id}
  when {4, 0}
    values = Array(Int32).new(keys.size, 0_i32)
    CrystalClick::WidePartWriter.write_uint64_decimal32_pair(path, "pk", key_slice, "payload", values.to_unsafe.to_slice(values.size), fixture.scale, 2, precision: fixture.precision)
  when {8, 0}
    values = Array(Int64).new(keys.size, 0_i64)
    CrystalClick::WidePartWriter.write_uint64_decimal64_pair(path, "pk", key_slice, "payload", values.to_unsafe.to_slice(values.size), fixture.scale, 2, precision: fixture.precision)
  when {16, 0}
    values = Array(Int128).new(keys.size, 0_i128)
    CrystalClick::WidePartWriter.write_uint64_decimal128_pair(path, "pk", key_slice, "payload", values.to_unsafe.to_slice(values.size), fixture.scale, 2, precision: fixture.precision)
  when {32, 0}
    values = Array(CrystalClick::Decimal256Value).new(keys.size) { CrystalClick::Decimal256Value.from_int128(0_i128) }
    CrystalClick::WidePartWriter.write_uint64_decimal256_pair(path, "pk", key_slice, "payload", values.to_unsafe.to_slice(values.size), fixture.scale, 2, precision: fixture.precision)
  when {4, 1}
    values = Array(Int32?).new(keys.size) { nil }
    CrystalClick::WidePartWriter.write_uint64_nullable_decimal32_pair(path, "pk", key_slice, "payload", values.to_unsafe.to_slice(values.size), fixture.scale, 2, precision: fixture.precision)
  when {8, 1}
    values = Array(Int64?).new(keys.size) { nil }
    CrystalClick::WidePartWriter.write_uint64_nullable_decimal64_pair(path, "pk", key_slice, "payload", values.to_unsafe.to_slice(values.size), fixture.scale, 2, precision: fixture.precision)
  when {16, 1}
    values = Array(Int128?).new(keys.size) { nil }
    CrystalClick::WidePartWriter.write_uint64_nullable_decimal128_pair(path, "pk", key_slice, "payload", values.to_unsafe.to_slice(values.size), fixture.scale, 2, precision: fixture.precision)
  when {32, 1}
    values = Array(CrystalClick::Decimal256Value?).new(keys.size) { nil }
    CrystalClick::WidePartWriter.write_uint64_nullable_decimal256_pair(path, "pk", key_slice, "payload", values.to_unsafe.to_slice(values.size), fixture.scale, 2, precision: fixture.precision)
  when {4, 2}
    values = Array(Array(Int32)).new(keys.size) { [] of Int32 }
    CrystalClick::WidePartWriter.write_uint64_array_decimal32_pair(path, "pk", key_slice, "payload", values.to_unsafe.to_slice(values.size), fixture.scale, 2, precision: fixture.precision)
  when {8, 2}
    values = Array(Array(Int64)).new(keys.size) { [] of Int64 }
    CrystalClick::WidePartWriter.write_uint64_array_decimal64_pair(path, "pk", key_slice, "payload", values.to_unsafe.to_slice(values.size), fixture.scale, 2, precision: fixture.precision)
  when {16, 2}
    values = Array(Array(Int128)).new(keys.size) { [] of Int128 }
    CrystalClick::WidePartWriter.write_uint64_array_decimal128_pair(path, "pk", key_slice, "payload", values.to_unsafe.to_slice(values.size), fixture.scale, 2, precision: fixture.precision)
  when {32, 2}
    values = Array(Array(CrystalClick::Decimal256Value)).new(keys.size) { [] of CrystalClick::Decimal256Value }
    CrystalClick::WidePartWriter.write_uint64_array_decimal256_pair(path, "pk", key_slice, "payload", values.to_unsafe.to_slice(values.size), fixture.scale, 2, precision: fixture.precision)
  when {4, 4}
    values = [
      [] of Array(Int32), [[] of Int32], [([] of Int32), ([] of Int32)], [] of Array(Int32), [[] of Int32],
    ] of Array(Array(Int32))
    CrystalClick::WidePartWriter.write_uint64_array_array_decimal32_pair(path, "pk", key_slice, "payload", values.to_unsafe.to_slice(values.size), fixture.scale, 2, precision: fixture.precision)
  when {8, 4}
    values = [
      [] of Array(Int64), [[] of Int64], [([] of Int64), ([] of Int64)], [] of Array(Int64), [[] of Int64],
    ] of Array(Array(Int64))
    CrystalClick::WidePartWriter.write_uint64_array_array_decimal64_pair(path, "pk", key_slice, "payload", values.to_unsafe.to_slice(values.size), fixture.scale, 2, precision: fixture.precision)
  when {16, 4}
    values = [
      [] of Array(Int128), [[] of Int128], [([] of Int128), ([] of Int128)], [] of Array(Int128), [[] of Int128],
    ] of Array(Array(Int128))
    CrystalClick::WidePartWriter.write_uint64_array_array_decimal128_pair(path, "pk", key_slice, "payload", values.to_unsafe.to_slice(values.size), fixture.scale, 2, precision: fixture.precision)
  when {32, 4}
    values = [
      [] of Array(CrystalClick::Decimal256Value), [[] of CrystalClick::Decimal256Value],
      [([] of CrystalClick::Decimal256Value), ([] of CrystalClick::Decimal256Value)],
      [] of Array(CrystalClick::Decimal256Value), [[] of CrystalClick::Decimal256Value],
    ] of Array(Array(CrystalClick::Decimal256Value))
    CrystalClick::WidePartWriter.write_uint64_array_array_decimal256_pair(path, "pk", key_slice, "payload", values.to_unsafe.to_slice(values.size), fixture.scale, 2, precision: fixture.precision)
  else
    raise "#{fixture.label}: unsupported direct guard profile"
  end
  w102o_assert_part(fixture, path, writer_metadata: true)
  w102o_assert_writer_frames(fixture, path)
  w102o_check_reader(path, fixture)
  puts "PASS direct writer guard #{fixture.label}: physical bytes, marks, and typed readback"
  path
end

private def w102o_assert_writer_frames(fixture : W102OFixture, part : String) : Nil
  w102o_expected_streams(fixture).each_key do |stream|
    expected_segments = w102o_stream_segments(fixture)[stream]
    encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
    records = w102o_mark_records(part, stream)
    raise "#{fixture.label} #{stream}: writer mark rows differ" unless records.map(&.[2]) == W102O_MARK_ROWS
    offset = 0_u64
    3.times do |index|
      compressed, decompressed, _ = records[index]
      raise "#{fixture.label} #{stream} mark #{index}: writer frame offset differs" unless compressed == offset && decompressed == 0_u64
      expected = expected_segments[index]
      if expected.empty?
        next
      end
      raise "#{fixture.label} #{stream} mark #{index}: missing writer frame" if offset >= encoded.size
      frame = CrystalClick::CompressedBlock.decode_frame(encoded, offset.to_i64)
      w102o_assert_bytes(String.new(frame.output), expected, "#{fixture.label} #{stream} writer frame #{index}")
      offset = frame.end_offset.to_u64
    end
    sentinel = records.last
    raise "#{fixture.label} #{stream}: writer sentinel differs" unless sentinel == {offset, 0_u64, 0_u64} && offset == encoded.size.to_u64
  end
  nil
end

private def w102o_attach_writer(binary : String, store : String, fixture : W102OFixture, part : String) : String
  table = fixture.writer_table
  w102o_create_table(binary, store, table, fixture)
  data_path = w102o_clickhouse(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  raise "#{table}: ClickHouse table path absent" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(part, File.join(detached, "all_1_1_0"))
  w102o_clickhouse(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  attached = w102o_part_path(binary, store, table, fixture.label)
  columns = w102o_clickhouse(binary, store, "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw").lines.map(&.strip)
  raise "#{table}: attached exact type differs" unless columns == ["pk UInt64", "payload #{fixture.type_name}"]
  w102o_check(binary, store, table, attached)
  w102o_stock_rowbinary(binary, store, table, fixture, [0_i32, 1_i32, 2_i32, 3_i32, 4_i32])
  w102o_stock_rowbinary(binary, store, table, fixture, [1_i32, 2_i32, 3_i32], true)
  puts "PASS attached #{fixture.label}: exact DDL, CHECK, and independent full/key-range RowBinary"
  attached
end

private def w102o_append_keyed_values(io : IO, keys : Slice(UInt64), values : Slice(T), fixture : W102OFixture) : Nil forall T
  raise "typed batch key/value lengths differ" unless keys.size == values.size
  keys.each_with_index do |key, index|
    w102o_append_u64(io, key)
    w102o_append_typed_value(io, values[index], fixture)
  end
end

private def w102o_append_batch(io : IO, batch : CrystalClick::WidePartTableBatch, fixture : W102OFixture) : Nil
  keys = batch.values_for("pk")
  case fixture.width
  when 4
    case fixture.shape.id
    when 0 then w102o_append_keyed_values(io, keys, batch.decimal32_raw_for("payload"), fixture)
    when 1 then w102o_append_keyed_values(io, keys, batch.nullable_decimal32_raw_for("payload"), fixture)
    when 2 then w102o_append_keyed_values(io, keys, batch.array_decimal32_raw_for("payload"), fixture)
    when 3 then w102o_append_keyed_values(io, keys, batch.array_nullable_decimal32_raw_for("payload"), fixture)
    when 4 then w102o_append_keyed_values(io, keys, batch.array_array_decimal32_raw_for("payload"), fixture)
    when 5 then w102o_append_keyed_values(io, keys, batch.array_array_nullable_decimal32_raw_for("payload"), fixture)
    else        raise "#{fixture.label}: unknown batch shape"
    end
  when 8
    case fixture.shape.id
    when 0 then w102o_append_keyed_values(io, keys, batch.decimal64_raw_for("payload"), fixture)
    when 1 then w102o_append_keyed_values(io, keys, batch.nullable_decimal64_raw_for("payload"), fixture)
    when 2 then w102o_append_keyed_values(io, keys, batch.array_decimal64_raw_for("payload"), fixture)
    when 3 then w102o_append_keyed_values(io, keys, batch.array_nullable_decimal64_raw_for("payload"), fixture)
    when 4 then w102o_append_keyed_values(io, keys, batch.array_array_decimal64_raw_for("payload"), fixture)
    when 5 then w102o_append_keyed_values(io, keys, batch.array_array_nullable_decimal64_raw_for("payload"), fixture)
    else        raise "#{fixture.label}: unknown batch shape"
    end
  when 16
    case fixture.shape.id
    when 0 then w102o_append_keyed_values(io, keys, batch.decimal128_raw_for("payload"), fixture)
    when 1 then w102o_append_keyed_values(io, keys, batch.nullable_decimal128_raw_for("payload"), fixture)
    when 2 then w102o_append_keyed_values(io, keys, batch.array_decimal128_raw_for("payload"), fixture)
    when 3 then w102o_append_keyed_values(io, keys, batch.array_nullable_decimal128_raw_for("payload"), fixture)
    when 4 then w102o_append_keyed_values(io, keys, batch.array_array_decimal128_raw_for("payload"), fixture)
    when 5 then w102o_append_keyed_values(io, keys, batch.array_array_nullable_decimal128_raw_for("payload"), fixture)
    else        raise "#{fixture.label}: unknown batch shape"
    end
  when 32
    case fixture.shape.id
    when 0 then w102o_append_keyed_values(io, keys, batch.decimal256_raw_for("payload"), fixture)
    when 1 then w102o_append_keyed_values(io, keys, batch.nullable_decimal256_raw_for("payload"), fixture)
    when 2 then w102o_append_keyed_values(io, keys, batch.array_decimal256_raw_for("payload"), fixture)
    when 3 then w102o_append_keyed_values(io, keys, batch.array_nullable_decimal256_raw_for("payload"), fixture)
    when 4 then w102o_append_keyed_values(io, keys, batch.array_array_decimal256_raw_for("payload"), fixture)
    when 5 then w102o_append_keyed_values(io, keys, batch.array_array_nullable_decimal256_raw_for("payload"), fixture)
    else        raise "#{fixture.label}: unknown batch shape"
    end
  else
    raise "#{fixture.label}: unsupported table Decimal width"
  end
  nil
end

private def w102o_check_table(part : String, fixture : W102OFixture) : Nil
  table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
  raise "#{fixture.label}: table row count differs" unless table.total_row_count == W102O_KEYS.size.to_u64
  full = IO::Memory.new
  table.scan_typed(batch_rows: 2) { |batch| w102o_append_batch(full, batch, fixture) }
  w102o_assert_bytes(full.to_s, w102o_expected_rowbinary(fixture, [0_i32, 1_i32, 2_i32, 3_i32, 4_i32]), "#{fixture.label} table full scan")

  window = IO::Memory.new
  table.scan_typed_window(1_u64, 3) { |batch| w102o_append_batch(window, batch, fixture) }
  w102o_assert_bytes(window.to_s, w102o_expected_rowbinary(fixture, [1_i32, 2_i32, 3_i32]), "#{fixture.label} table window")

  selected = IO::Memory.new
  table.scan_typed_candidate_marks([[1_i32, 2_i32]]) { |batch| w102o_append_batch(selected, batch, fixture) }
  w102o_assert_bytes(selected.to_s, w102o_expected_rowbinary(fixture, [2_i32, 3_i32, 4_i32]), "#{fixture.label} selected candidate granules")
  nil
end

private def w102o_catalog_root(root : String, part : String, fixture : W102OFixture) : String
  database_uuid = "10210000-0000-4000-8000-000000000001"
  table_uuid = "10210000-0000-4000-8000-000000000002"
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

private def w102o_append_catalog_value(io : IO, value : CrystalClick::OfflineColumnValue, fixture : W102OFixture) : Nil
  case fixture.shape.id
  when 0
    case fixture.width
    when  4 then w102o_append_value(io, value.as(Int32))
    when  8 then w102o_append_value(io, value.as(Int64))
    when 16 then w102o_append_value(io, value.as(Int128))
    when 32 then w102o_append_value(io, value.as(CrystalClick::Decimal256Value))
    else         raise "#{fixture.label}: unsupported catalog scalar width"
    end
  when 1
    case fixture.width
    when  4 then w102o_append_nullable_value(io, value.as(Int32?))
    when  8 then w102o_append_nullable_value(io, value.as(Int64?))
    when 16 then w102o_append_nullable_value(io, value.as(Int128?))
    when 32 then w102o_append_nullable_value(io, value.as(CrystalClick::Decimal256Value?))
    else         raise "#{fixture.label}: unsupported catalog nullable width"
    end
  when 2
    case fixture.width
    when  4 then w102o_append_value(io, value.as(Array(Int32)))
    when  8 then w102o_append_value(io, value.as(Array(Int64)))
    when 16 then w102o_append_value(io, value.as(Array(Int128)))
    when 32 then w102o_append_value(io, value.as(Array(CrystalClick::Decimal256Value)))
    else         raise "#{fixture.label}: unsupported catalog Array width"
    end
  when 3
    case fixture.width
    when  4 then w102o_append_nullable_array(io, value.as(Array(Int32?)))
    when  8 then w102o_append_nullable_array(io, value.as(Array(Int64?)))
    when 16 then w102o_append_nullable_array(io, value.as(Array(Int128?)))
    when 32 then w102o_append_nullable_array(io, value.as(Array(CrystalClick::Decimal256Value?)))
    else         raise "#{fixture.label}: unsupported catalog nullable Array width"
    end
  when 4
    case fixture.width
    when  4 then w102o_append_value(io, value.as(Array(Array(Int32))))
    when  8 then w102o_append_value(io, value.as(Array(Array(Int64))))
    when 16 then w102o_append_value(io, value.as(Array(Array(Int128))))
    when 32 then w102o_append_value(io, value.as(Array(Array(CrystalClick::Decimal256Value))))
    else         raise "#{fixture.label}: unsupported catalog nested Array width"
    end
  when 5
    case fixture.width
    when  4 then w102o_append_nested_nullable_array(io, value.as(Array(Array(Int32?))))
    when  8 then w102o_append_nested_nullable_array(io, value.as(Array(Array(Int64?))))
    when 16 then w102o_append_nested_nullable_array(io, value.as(Array(Array(Int128?))))
    when 32 then w102o_append_nested_nullable_array(io, value.as(Array(Array(CrystalClick::Decimal256Value?))))
    else         raise "#{fixture.label}: unsupported catalog nested nullable width"
    end
  else
    raise "#{fixture.label}: unsupported catalog shape"
  end
  nil
end

private def w102o_check_catalog(root : String, part : String, fixture : W102OFixture) : Nil
  copied = w102o_catalog_root(root, part, fixture)
  offline = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
  candidates = offline.resolved_scan_parts
  raise "#{fixture.label}: catalog part resolution differs" unless candidates.size == 1 && File.realpath(candidates[0].path) == File.realpath(copied)

  full = IO::Memory.new
  offline.scan_typed(["pk", "payload"], batch_rows: 2) { |batch| w102o_append_batch(full, batch, fixture) }
  w102o_assert_bytes(full.to_s, w102o_expected_rowbinary(fixture, [0_i32, 1_i32, 2_i32, 3_i32, 4_i32]), "#{fixture.label} catalog full scan")

  window = IO::Memory.new
  offline.scan_typed_window(["pk", "payload"], 1_u64, 3) { |batch| w102o_append_batch(window, batch, fixture) }
  w102o_assert_bytes(window.to_s, w102o_expected_rowbinary(fixture, [1_i32, 2_i32, 3_i32]), "#{fixture.label} catalog window")

  values = offline["payload"].values(max_tuple_cells: 100_u64)
  raise "#{fixture.label}: catalog materialized row count differs" unless values.size == W102O_KEYS.size
  actual_values = IO::Memory.new
  values.each { |value| w102o_append_catalog_value(actual_values, value, fixture) }
  w102o_assert_bytes(actual_values.to_s, w102o_expected_payload(fixture, [0_i32, 1_i32, 2_i32, 3_i32, 4_i32]), "#{fixture.label} catalog values")

  candidate_keys = [] of UInt64
  offline.scan_uint64_pk_candidates(["pk"], 3_u64, 5_u64) do |batch|
    candidate_keys.concat(batch.values_for("pk"))
    nil
  end
  raise "#{fixture.label}: candidate mark superset differs" unless candidate_keys == W102O_KEYS
  raise "#{fixture.label}: exact candidate predicate differs" unless candidate_keys.select { |key| key >= 3_u64 && key <= 5_u64 } == [3_u64, 4_u64, 5_u64]
  nil
end

private def w102o_assert_stock_stats_layout(fixture : W102OFixture, part : String) : Nil
  actual = File.read(File.join(part, "columns.txt")).lines.map(&.strip)
  expected = ["columns format version: 1", "2 columns:", "`pk` UInt64", "`payload` #{fixture.type_name}"]
  raise "#{fixture.label}: statistics columns.txt differs" unless actual == expected
  entries = Dir.children(part)
  pk_bin = "#{CrystalClick::StreamName.hash("pk")}.bin"
  pk_mark = "#{CrystalClick::StreamName.hash("pk")}.mrk2"
  raise "#{fixture.label}: primary-key streams absent" unless entries.includes?(pk_bin) && entries.includes?(pk_mark)
  marks = w102o_mark_records(part, "pk")
  raise "#{fixture.label}: primary-key mark rows differ" unless marks.map(&.[2]) == W102O_MARK_ROWS
  actual_pk = CrystalClick::CompressedBlock.decode_all(File.read(File.join(part, pk_bin)).to_slice)
  expected_pk = W102O_KEYS.map { |key| w102o_u64(key) }.join
  w102o_assert_bytes(String.new(actual_pk), expected_pk, "#{fixture.label} primary-key physical bytes")
  # Do not decode or constrain Sparse payload streams here. Only serializer
  # default counters plus independent SQL RowBinary and CHECK qualify them.
  payload_streams = entries.select(&.ends_with?(".bin")).reject { |name| name == pk_bin }.sort
  payload_marks = entries.select(&.ends_with?(".mrk2")).reject { |name| name == pk_mark }.sort
  puts "OBSERVED #{fixture.label}: Sparse stream inventory bins=#{payload_streams.inspect}, marks=#{payload_marks.inspect}"
  w102o_validate_metadata(part, fixture, true)
  nil
end

private def w102o_seed_comparator(part : String, fixture : W102OFixture) : Nil
  expected = w102o_expected_streams(fixture)["payload"]
  actual = String.new(CrystalClick::CompressedBlock.decode_all(File.read(File.join(part, "#{CrystalClick::StreamName.hash("payload")}.bin")).to_slice))
  w102o_assert_bytes(actual, expected, "#{fixture.label} seeded comparator positive control")
  raise "#{fixture.label}: seeded comparator profile unexpectedly empty" if expected.empty?
  corrupted = Array(UInt8).new(expected.bytesize) { |index| expected.to_slice[index] }
  corrupted[0] ^= 1_u8
  rejected = false
  begin
    w102o_assert_bytes(actual, w102o_bytes_from_u8(corrupted), "#{fixture.label} seeded defect")
  rescue W102OByteMismatchError
    rejected = true
  end
  raise "#{fixture.label}: seeded one-byte defect escaped the byte comparator" unless rejected
  puts "PASS seeded byte comparator falsifier"

  raise "empty expected stream positive control differs" unless w102o_decode_expected_stream(Bytes.empty, true, "seeded empty stream") == ""
  rejected_empty = false
  begin
    w102o_decode_expected_stream(Bytes.empty, false, "seeded empty stream")
  rescue error : Exception
    raise error unless error.message == "seeded empty stream: missing bytes for nonempty expected stream"
    rejected_empty = true
  end
  raise "missing nonempty stream escaped the decoder guard" unless rejected_empty
  puts "PASS seeded empty stream falsifier: missing nonempty payload rejected"
end

private def w102o_seed_eof_marks(part : String, fixture : W102OFixture) : Nil
  records = w102o_mark_records(part, "pk")
  compressed, decompressed, rows = records.last
  raise "#{fixture.label}: EOF falsifier requires the qualified buffered stock sentinel" unless decompressed > 0_u64 && rows == 0_u64
  w102o_assert_mark_windows(fixture, part, "pk")
  {-1, 1}.each do |delta|
    injected = records.dup
    offset = delta < 0 ? decompressed - 1_u64 : decompressed + 1_u64
    injected[injected.size - 1] = {compressed, offset, rows}
    reason = delta < 0 ? "logical byte boundary differs" : "decompressed offset outside frame"
    expected = "#{fixture.label} pk mark 3: #{reason}"
    rejected = false
    begin
      w102o_assert_mark_windows(fixture, part, "pk", injected)
    rescue error : Exception
      raise error unless error.message == expected
      rejected = true
    end
    raise "#{fixture.label}: seeded EOF offset #{delta} escaped the mark validator" unless rejected
  end
  puts "PASS seeded EOF mark falsifiers: early logical end and out-of-frame end rejected"
end

private def w102o_run_reader_writer_profile(binary : String, store : String, writer_root : String, catalog_root : String, fixture : W102OFixture, scalar_text_anchor : Bool = false) : Nil
  source = w102o_create_stock(binary, store, fixture)
  w102o_check_scalar_text(binary, store, fixture) if scalar_text_anchor
  w102o_check_reader(source, fixture)
  w102o_check_table(source, fixture)
  w102o_check_catalog(File.join(catalog_root, fixture.label), source, fixture)
  writer_part = w102o_write_from_reader(writer_root, fixture, source, W102O_KEYS)
  w102o_attach_writer(binary, store, fixture, writer_part)
  nil
end

private def w102o_version(binary : String) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(binary, ["local", "--version"], output: output, error: error)
  raise "ClickHouse version check failed: #{error}" unless status.success?
  output.to_s.strip
end

private def w102o_main : Int32
  binary = ENV["CLICKHOUSE_BIN"]? || "/Users/sergey/.local/bin/clickhouse"
  expected_version = "ClickHouse local version #{W102O_VERSION} (official build)."
  actual_version = w102o_version(binary)
  raise "W102 oracle requires #{expected_version}, got #{actual_version}" unless actual_version == expected_version

  store = ENV["W102_STORE"]? || raise "W102_STORE is required"
  writer_root = ENV["W102_WRITER_ROOT"]? || raise "W102_WRITER_ROOT is required"
  catalog_root = ENV["W102_ORACLE_ROOT"]? || raise "W102_ORACLE_ROOT is required"
  FileUtils.mkdir_p(store)
  FileUtils.mkdir_p(writer_root)
  FileUtils.mkdir_p(catalog_root)

  core_count = 0
  W102O_SHAPES.each do |shape|
    W102O_PS.each do |precision|
      scale = w102o_scale(shape, precision)
      label = "#{shape.label}_p#{precision}_s#{scale}"
      fixture = w102o_fixture(shape, precision, label)
      w102o_run_reader_writer_profile(binary, store, writer_root, catalog_root, fixture, scalar_text_anchor: shape.id == 0)
      core_count += 1
      if core_count == 1
        part = w102o_part_path(binary, store, fixture.source_table, label)
        w102o_seed_comparator(part, fixture)
        w102o_seed_eof_marks(part, fixture)
      end
      puts "PASS W102 profile #{core_count}/72: #{fixture.type_name}"
    end
  end
  raise "W102 core profile count differs" unless core_count == 72

  native_count = 0
  {1, 10, 19, 39}.each do |precision|
    label = "native_extrema_p#{precision}"
    fixture = w102o_fixture(W102O_SHAPES[0], precision, label, native_extrema: true)
    w102o_run_reader_writer_profile(binary, store, writer_root, catalog_root, fixture)
    native_count += 1
    puts "PASS guard-only native carrier extrema #{fixture.type_name}"
  end

  stats_count = 0
  {1, 10, 19, 39}.each do |precision|
    fixture = w102o_all_zero_fixture(precision, "stats_raw_zero_p#{precision}", "0.9375")
    w102o_create_stock(binary, store, fixture, stats_defaults: true)
    stats_count += 1
  end

  direct_guard_count = 0
  {1, 10, 19, 39}.each do |precision|
    [
      w102o_all_zero_fixture(precision, "writer_all_zero_p#{precision}"),
      w102o_all_null_fixture(precision, "writer_all_null_p#{precision}"),
      w102o_all_empty_array_fixture(precision, "writer_empty_array_p#{precision}"),
      w102o_all_empty_array_fixture(precision, "writer_empty_nested_p#{precision}", nested: true),
    ].each do |fixture|
      part = w102o_write_guard_direct(writer_root, fixture)
      w102o_attach_writer(binary, store, fixture, part)
      direct_guard_count += 1
    end
  end

  raise "W102 native extrema guard count differs" unless native_count == 4
  raise "W102 raw-zero statistics profile count differs" unless stats_count == 4
  raise "W102 direct writer guard count differs" unless direct_guard_count == 16
  puts "PASS W102 final oracle: stock-backed profiles=#{core_count + native_count}, stats-only raw-zero=#{stats_count}, direct writer guards=#{direct_guard_count}"
  0
end

exit w102o_main
