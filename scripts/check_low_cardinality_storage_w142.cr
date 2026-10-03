# W142 storage-level LowCardinality oracle. The retained W141 ClickHouse
# parts are the physical reference; all logical expectations below are
# authored literals. Native input consumes the library's exact dictionary and
# ID payloads after the documented global-to-additional flag conversion. This
# is not direct Native global-dictionary consumption or a standalone part
# writer certificate.
require "file_utils"
require "set"
require "./check_binary_w117"

W142_SOURCE_REVISION    = "9007d227b64a3f8b667fc5258ceb2923f3cf477d"
W142_CLICKHOUSE_VERSION = "ClickHouse local version 26.10.1.1201 (official build)."
W142_RUNTIME_SHA256     = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
W142_BUILD_HASH         = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"

class W142StorageMismatch < Exception
end

struct W142StorageVector
  getter label : String
  getter child_type : CrystalClick::BinaryDataType
  getter native_type_name : String
  getter values_per_mark : Array(Array(String?))
  getter dictionary_substream : String
  getter index_substream : String
  getter dictionary_basename : String
  getter index_basename : String
  getter expected_index_offsets : Array(UInt64)

  def initialize(
    @label : String,
    @child_type : CrystalClick::BinaryDataType,
    @native_type_name : String,
    @values_per_mark : Array(Array(String?)),
    @dictionary_substream : String,
    @index_substream : String,
    @dictionary_basename : String,
    @index_basename : String,
    @expected_index_offsets : Array(UInt64),
  )
  end

  def type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.low_cardinality(child_type)
  end

  def expected_values : Array(Array(CrystalClick::BinaryValue))
    values_per_mark.map do |mark|
      mark.map do |display|
        child = w142_child_value(child_type, display)
        CrystalClick::BinaryValue.low_cardinality(type, child)
      end
    end
  end

  def occurrences : Array(UInt64)
    values_per_mark.map(&.size.to_u64)
  end

  def flattened_display : Array(String?)
    values_per_mark.flatten
  end
end

struct W142PartLanes
  getter part_path : String
  getter dictionary_path : String
  getter index_path : String
  getter streams : CrystalClick::BinaryBulkStreams

  def initialize(@part_path : String, @dictionary_path : String, @index_path : String,
                 @streams : CrystalClick::BinaryBulkStreams)
  end
end

def w142_fail(message : String) : NoReturn
  raise W142StorageMismatch.new(message)
end

def w142_assert(condition : Bool, message : String) : Nil
  w142_fail(message) unless condition
end

def w142_read_bytes(path : String, label : String) : Bytes
  w142_assert(File.file?(path) && !File.symlink?(path), "#{label}: missing file or symlink")
  File.open(path, "rb") do |file|
    bytes = Bytes.new(file.size.to_i32)
    file.read_fully(bytes)
    bytes
  end
end

def w142_u64_le(bytes : Bytes, offset : Int, label : String) : UInt64
  w142_assert(offset >= 0 && offset <= bytes.size - 8, "#{label}: UInt64 read outside bytes")
  value = 0_u64
  8.times do |index|
    value |= bytes[offset + index].to_u64 << (index * 8)
  end
  value
end

def w142_hex(bytes : Bytes) : String
  String.build do |io|
    bytes.each { |byte| io << byte.to_s(16).rjust(2, '0') }
  end
end

def w142_bytes_from_array(bytes : Array(UInt8)) : Bytes
  Bytes.new(bytes.size) { |index| bytes[index] }
end

def w142_write_bytes(path : String, bytes : Bytes) : Nil
  w142_assert(!File.exists?(path) && !File.symlink?(path), "refusing to overwrite W142 output: #{path}")
  File.open(path, "wb") { |file| file.write(bytes) }
end

def w142_write_text(path : String, value : String) : Nil
  w142_assert(!File.exists?(path) && !File.symlink?(path), "refusing to overwrite W142 output: #{path}")
  File.open(path, "w") { |file| file << value }
end

def w142_mark(values : Array(String?)) : Array(String?)
  values
end

def w142_cases : Array(W142StorageVector)
  string_type = CrystalClick::BinaryDataType.primitive("String")
  nullable_string_type = CrystalClick::BinaryDataType.nullable(string_type)
  int64_type = CrystalClick::BinaryDataType.primitive("Int64")
  date_type = CrystalClick::BinaryDataType.primitive("Date")
  ipv4_type = CrystalClick::BinaryDataType.primitive("IPv4")
  fixed_string_type = CrystalClick::BinaryDataType.fixed_string(3)

  cases = [] of W142StorageVector
  cases << W142StorageVector.new(
    "lc-string", string_type, "LowCardinality(String)",
    [
      w142_mark(["red", "blue", "red", "green"] of String?),
      w142_mark(["blue", "", "red", "雪"] of String?),
      w142_mark(["green"] of String?),
    ],
    "j.v.dict", "j.v", "44c7b1beffff8a7b139857964e5e01d9", "9f73de78faa16746f8905bcd1bd2dc16",
    [0_u64, 20_u64, 40_u64],
  )
  cases << W142StorageVector.new(
    "lc-nullable-string", nullable_string_type, "LowCardinality(Nullable(String))",
    [
      w142_mark(["a", nil, "a", ""] of String?),
      w142_mark([nil, "b", "a", "c"] of String?),
      w142_mark([nil] of String?),
    ],
    "j.v.dict", "j.v", "44c7b1beffff8a7b139857964e5e01d9", "9f73de78faa16746f8905bcd1bd2dc16",
    [0_u64, 20_u64, 40_u64],
  )
  cases << W142StorageVector.new(
    "lc-int64", int64_type, "LowCardinality(Int64)",
    [
      w142_mark(["-81985529216486896", "81985529216486895", "0", "-81985529216486896"] of String?),
      w142_mark(["81985529216486895", "-1", "0", "81985529216486895"] of String?),
      w142_mark(["-81985529216486896"] of String?),
    ],
    "j.v.dict", "j.v", "44c7b1beffff8a7b139857964e5e01d9", "9f73de78faa16746f8905bcd1bd2dc16",
    [0_u64, 20_u64, 40_u64],
  )
  cases << W142StorageVector.new(
    "lc-date", date_type, "LowCardinality(Date)",
    [
      w142_mark(["2024-12-31", "1970-01-02", "2024-12-31", "2000-02-29"] of String?),
      w142_mark(["1970-01-02", "2024-12-31", "2000-02-29", "1970-01-02"] of String?),
      w142_mark(["2024-12-31"] of String?),
    ],
    "j.v.dict", "j.v", "44c7b1beffff8a7b139857964e5e01d9", "9f73de78faa16746f8905bcd1bd2dc16",
    [0_u64, 20_u64, 40_u64],
  )
  cases << W142StorageVector.new(
    "lc-ipv4", ipv4_type, "LowCardinality(IPv4)",
    [
      w142_mark(["192.0.2.1", "198.51.100.7", "192.0.2.1", "203.0.113.9"] of String?),
      w142_mark(["198.51.100.7", "192.0.2.1", "203.0.113.9", "198.51.100.7"] of String?),
      w142_mark(["192.0.2.1"] of String?),
    ],
    "j.v.dict", "j.v", "44c7b1beffff8a7b139857964e5e01d9", "9f73de78faa16746f8905bcd1bd2dc16",
    [0_u64, 20_u64, 40_u64],
  )
  cases << W142StorageVector.new(
    "lc-fixed-string", fixed_string_type, "LowCardinality(FixedString(3))",
    [
      w142_mark(["cat", "dog", "cat", "owl"] of String?),
      w142_mark(["dog", "fox", "cat", "owl"] of String?),
      w142_mark(["dog"] of String?),
    ],
    "j.v.dict", "j.v", "44c7b1beffff8a7b139857964e5e01d9", "9f73de78faa16746f8905bcd1bd2dc16",
    [0_u64, 20_u64, 40_u64],
  )
  cases << W142StorageVector.new(
    "array-lc-string", string_type, "LowCardinality(String)",
    [
      w142_mark(["red", "blue", "red", "green", "blue"] of String?),
      w142_mark(["blue", "", "red", "雪", "雪"] of String?),
      w142_mark(["green"] of String?),
    ],
    "j.v.dict", "j.v", "44c7b1beffff8a7b139857964e5e01d9", "9f73de78faa16746f8905bcd1bd2dc16",
    [0_u64, 21_u64, 42_u64],
  )
  cases << W142StorageVector.new(
    "map-lc-string", string_type, "LowCardinality(String)",
    [
      w142_mark(["red", "blue", "red", "green", "blue"] of String?),
      w142_mark(["blue", "", "red", "雪", "雪"] of String?),
      w142_mark(["green"] of String?),
    ],
    "j.v%2Evalues.dict", "j.v%2Evalues", "99390d84521a900a8e2df19f4c766dc6", "fb2145d39122827046f1d8d403bfdc44",
    [0_u64, 21_u64, 42_u64],
  )
  cases << W142StorageVector.new(
    "tuple-lc-string", string_type, "LowCardinality(String)",
    [
      w142_mark(["red", "blue", "red", "green"] of String?),
      w142_mark(["blue", "", "red", "雪"] of String?),
      w142_mark(["green"] of String?),
    ],
    "j.v%2Es.dict", "j.v%2Es", "2439c63873ae01ce880012fcfcbd70e3", "acf978187e84253692d0566517f4c3f5",
    [0_u64, 20_u64, 40_u64],
  )
  cases
end

def w142_child_value(type : CrystalClick::BinaryDataType, display : String?) : CrystalClick::BinaryValue
  case type.tag
  when CrystalClick::BinaryDataType::TAG_STRING
    CrystalClick::BinaryValue.string(display || "")
  when CrystalClick::BinaryDataType::TAG_NULLABLE
    if value = display
      CrystalClick::BinaryValue.nullable(type, w142_child_value(type.child_at(0), value))
    else
      CrystalClick::BinaryValue.nullable(type)
    end
  when CrystalClick::BinaryDataType::TAG_INT64
    CrystalClick::BinaryValue.int64((display || "0").to_i64)
  when CrystalClick::BinaryDataType::TAG_DATE
    payload = case display
              when "2024-12-31" then "784e"
              when "1970-01-02" then "0100"
              when "2000-02-29" then "082b"
              else                   w142_fail("unrecognized authored W142 Date literal: #{display.inspect}")
              end
    CrystalClick::BinaryValue.fixed(type, w117_bytes(payload))
  when CrystalClick::BinaryDataType::TAG_IPV4
    payload = case display
              when "192.0.2.1"    then "010200c0"
              when "198.51.100.7" then "076433c6"
              when "203.0.113.9"  then "097100cb"
              else                     w142_fail("unrecognized authored W142 IPv4 literal: #{display.inspect}")
              end
    CrystalClick::BinaryValue.fixed(type, w117_bytes(payload))
  when CrystalClick::BinaryDataType::TAG_FIXED_STRING
    payload = case display
              when "cat" then "636174"
              when "dog" then "646f67"
              when "owl" then "6f776c"
              when "fox" then "666f78"
              else            w142_fail("unrecognized authored W142 FixedString literal: #{display.inspect}")
              end
    CrystalClick::BinaryValue.fixed(type, w117_bytes(payload))
  else
    w142_fail("unsupported W142 literal type #{type.name}")
  end
end

def w142_assert_value(actual : CrystalClick::BinaryValue, expected : CrystalClick::BinaryValue, label : String) : Nil
  w142_assert(actual.type.name == expected.type.name, "#{label}: type #{actual.type.name.inspect} != literal #{expected.type.name.inspect}")
  w142_assert(actual.type.tag == expected.type.tag, "#{label}: type tag differs from literal")
  w142_assert(actual.is_null? == expected.is_null?, "#{label}: NULL state differs from literal")
  w142_assert(actual.child_count == expected.child_count, "#{label}: child count differs from literal")
  if actual.child_count > 0
    actual.child_count.times do |index|
      w142_assert_value(actual.child_at(index), expected.child_at(index), "#{label}[#{index}]")
    end
  elsif !actual.is_null?
    unless actual.bytes == expected.bytes
      w142_fail("#{label}: scalar bytes expected #{w142_hex(expected.bytes)} got #{w142_hex(actual.bytes)}")
    end
  end
end

def w142_assert_granules(actual : Array(Array(CrystalClick::BinaryValue)), vector : W142StorageVector, label : String) : Nil
  expected = vector.expected_values
  w142_assert(actual.size == expected.size, "#{label}: mark count #{actual.size} != literal #{expected.size}")
  actual.each_with_index do |mark, mark_index|
    w142_assert(mark.size == expected[mark_index].size, "#{label}: mark #{mark_index} occurrence count differs")
    mark.each_with_index do |value, row_index|
      w142_assert_value(value, expected[mark_index][row_index], "#{label} mark #{mark_index} row #{row_index}")
    end
  end
end

def w142_compressed_file(path : String, label : String) : Bytes
  compressed = w142_read_bytes(path, label)
  CrystalClick::CompressedBlock.decode_all(compressed)
end

def w142_offsets_from_marks(cmrk_path : String, lane_bytes : Bytes, expected_real : Array(UInt64), label : String) : Array(UInt64)
  decoded = w142_compressed_file(cmrk_path, "#{label} compressed marks")
  w142_assert(decoded.size == expected_real.size * 16, "#{label}: expected #{expected_real.size} mark records, got #{decoded.size}")
  offsets = [] of UInt64
  expected_real.size.times do |index|
    compressed_offset = w142_u64_le(decoded, index * 16, "#{label} mark #{index} compressed offset")
    decompressed_offset = w142_u64_le(decoded, index * 16 + 8, "#{label} mark #{index} decompressed offset")
    w142_assert(compressed_offset == 0_u64, "#{label}: retained fixture is expected to have a single compressed data frame")
    w142_assert(decompressed_offset == expected_real[index], "#{label}: mark #{index} offset #{decompressed_offset} != authored physical coordinate #{expected_real[index]}")
    offsets << decompressed_offset
  end
  offsets << lane_bytes.size.to_u64
  w142_assert(offsets.each_cons(2).all? { |pair| pair[0] <= pair[1] }, "#{label}: mark coordinates are not monotone")
  offsets
end

def w142_part_lanes(probe_root : String, vector : W142StorageVector) : W142PartLanes
  candidates = Dir.glob(File.join(probe_root, "stores", vector.label, "store", "**", "all_1_1_0"))
  w142_assert(candidates.size == 1, "#{vector.label}: expected one retained W141 part, got #{candidates.size}")
  part = candidates.first
  w142_assert(File.directory?(part) && !File.symlink?(part), "#{vector.label}: retained W141 part missing or symlinked")
  metadata_path = File.join(part, "columns_substreams.txt")
  w142_assert(File.file?(metadata_path) && !File.symlink?(metadata_path), "#{vector.label}: retained substream metadata missing or symlinked")
  metadata = File.read(metadata_path)
  substreams = metadata.lines.map(&.strip)
  w142_assert(substreams.includes?(vector.dictionary_substream), "#{vector.label}: metadata omits #{vector.dictionary_substream}")
  w142_assert(substreams.includes?(vector.index_substream), "#{vector.label}: metadata omits #{vector.index_substream}")
  w142_assert(CrystalClick::StreamName.hash(vector.dictionary_substream) == vector.dictionary_basename, "#{vector.label}: dictionary basename does not hash from its retained substream name")
  w142_assert(CrystalClick::StreamName.hash(vector.index_substream) == vector.index_basename, "#{vector.label}: index basename does not hash from its retained substream name")

  dictionary_path = File.join(part, "#{vector.dictionary_basename}.bin")
  dictionary_cmrk_path = File.join(part, "#{vector.dictionary_basename}.cmrk")
  index_path = File.join(part, "#{vector.index_basename}.bin")
  index_cmrk_path = File.join(part, "#{vector.index_basename}.cmrk")
  dictionary = w142_compressed_file(dictionary_path, "#{vector.label} W141 dictionary lane")
  indexes = w142_compressed_file(index_path, "#{vector.label} W141 index lane")
  dictionary_offsets = w142_offsets_from_marks(dictionary_cmrk_path, dictionary, [8_u64, 8_u64, 8_u64], "#{vector.label} dictionary")
  index_offsets = w142_offsets_from_marks(index_cmrk_path, indexes, vector.expected_index_offsets, "#{vector.label} indexes")
  w142_assert(dictionary_offsets == [8_u64, 8_u64, 8_u64, dictionary.size.to_u64], "#{vector.label}: dictionary K+1 global-suffix/EOF coordinates differ")
  w142_assert(index_offsets.last == indexes.size.to_u64, "#{vector.label}: index EOF coordinate differs")

  roles = {
    "root.dictionary" => CrystalClick::BinaryBulkStream.new(dictionary, dictionary_offsets),
    "root.indexes"    => CrystalClick::BinaryBulkStream.new(indexes, index_offsets),
  } of String => CrystalClick::BinaryBulkStream
  streams = CrystalClick::BinaryBulkStreams.new(mark_count: 3, streams: roles)
  W142PartLanes.new(part, dictionary_path, index_path, streams)
end

def w142_assert_streams_equal(actual : CrystalClick::BinaryBulkStreams, expected : CrystalClick::BinaryBulkStreams, label : String) : Nil
  w142_assert(actual.mark_count == expected.mark_count, "#{label}: mark count differs")
  w142_assert(actual.roles == ["root.dictionary", "root.indexes"], "#{label}: unexpected stream roles #{actual.roles.inspect}")
  actual.roles.each do |role|
    actual_stream = actual.stream(role)
    expected_stream = expected.stream(role)
    w142_assert(actual_stream.offsets == expected_stream.offsets, "#{label} #{role}: physical mark coordinates differ: #{actual_stream.offsets.inspect} != #{expected_stream.offsets.inspect}")
    unless actual_stream.bytes == expected_stream.bytes
      w142_fail("#{label} #{role}: decompressed lane differs (actual #{w142_hex(actual_stream.bytes)}, codec #{w142_hex(expected_stream.bytes)})")
    end
  end
end

def w142_u64_array(value : UInt64, destination : Array(UInt8)) : Nil
  8.times { |index| destination << ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

def w142_varuint(value : UInt64, destination : Array(UInt8)) : Nil
  remaining = value
  while remaining >= 0x80_u64
    destination << ((remaining & 0x7f_u64).to_u8 | 0x80_u8)
    remaining >>= 7
  end
  destination << remaining.to_u8
end

def w142_native_string(value : String, destination : Array(UInt8)) : Nil
  w142_varuint(value.bytesize.to_u64, destination)
  value.to_slice.each { |byte| destination << byte }
end

def w142_native_input(vector : W142StorageVector, streams : CrystalClick::BinaryBulkStreams) : Bytes
  dictionary = streams.stream("root.dictionary").bytes
  indexes = streams.stream("root.indexes").bytes
  dictionary_offsets = streams.stream("root.dictionary").offsets
  index_offsets = streams.stream("root.indexes").offsets
  w142_assert(dictionary_offsets.first == 8_u64 && dictionary.size >= 16, "#{vector.label}: codec dictionary lane lacks version prefix/global key body")
  w142_assert(w142_u64_le(dictionary, 0, "#{vector.label} dictionary version") == 1_u64, "#{vector.label}: unsupported codec dictionary version")
  width_code : UInt64? = nil
  ids = [] of UInt8
  occurrences = vector.occurrences
  occurrences.each_with_index do |count, mark|
    start = index_offsets[mark].to_i
    finish = index_offsets[mark + 1].to_i
    w142_assert(finish - start >= 16, "#{vector.label}: codec index mark is shorter than its header")
    flags = w142_u64_le(indexes, start, "#{vector.label} index mark #{mark} flags")
    row_count = w142_u64_le(indexes, start + 8, "#{vector.label} index mark #{mark} count")
    w142_assert(row_count == count, "#{vector.label}: index mark #{mark} count #{row_count} != literal occurrence count #{count}")
    current_width = flags & 0xff_u64
    w142_assert(current_width <= 3_u64, "#{vector.label}: Native supports an unexpected LC width code #{current_width}")
    if known_width = width_code
      w142_assert(known_width == current_width, "#{vector.label}: LC index width changed between marks")
    else
      width_code = current_width
    end
    w142_assert((flags & 0x100_u64) != 0_u64, "#{vector.label}: library index segment is not global-dictionary encoded")
    w142_assert((flags & 0x200_u64) == 0_u64, "#{vector.label}: global segment unexpectedly has additional-key framing")
    payload_size = row_count.to_i * (1 << current_width.to_i)
    w142_assert(finish - start == 16 + payload_size, "#{vector.label}: index mark #{mark} payload length differs from width/count")
    (start + 16).upto(finish - 1) { |offset| ids << indexes[offset] }
  end

  width = width_code || w142_fail("#{vector.label}: no LC index width")
  native = [] of UInt8
  # One-column, one-block Native header. `local` uses the legacy Native
  # structure path (no custom-serialization marker) for this input.
  w142_varuint(1_u64, native)
  w142_varuint(occurrences.sum, native)
  w142_native_string("x", native)
  w142_native_string(vector.native_type_name, native)
  w142_u64_array(1_u64, native) # LowCardinality version
  # Native forbids NeedGlobalDictionary. Preserve the codec-selected ID width,
  # convert only the flags to HasAdditionalKeys|NeedUpdateDictionary, and
  # provide the exact dictionary body and IDs emitted in the global lanes.
  w142_u64_array(0x600_u64 | width, native)
  dictionary[8, dictionary.size - 8].each { |byte| native << byte }
  w142_u64_array(occurrences.sum, native)
  ids.each { |byte| native << byte }
  w142_bytes_from_array(native)
end

def w142_expected_payload_hex(type : CrystalClick::BinaryDataType, display : String?) : String
  if type.tag == CrystalClick::BinaryDataType::TAG_STRING
    text = display || ""
    bytes = [] of UInt8
    w142_varuint(text.bytesize.to_u64, bytes)
    text.to_slice.each { |byte| bytes << byte }
    return w142_hex(w142_bytes_from_array(bytes))
  elsif type.tag == CrystalClick::BinaryDataType::TAG_NULLABLE
    return "01" unless display
    text = display.not_nil!
    bytes = [0_u8] of UInt8
    w142_varuint(text.bytesize.to_u64, bytes)
    text.to_slice.each { |byte| bytes << byte }
    return w142_hex(w142_bytes_from_array(bytes))
  end

  case type.tag
  when CrystalClick::BinaryDataType::TAG_INT64
    case display
    when "-81985529216486896" then "1032547698badcfe"
    when "81985529216486895"  then "efcdab8967452301"
    when "0"                  then "0000000000000000"
    when "-1"                 then "ffffffffffffffff"
    else                           w142_fail("unrecognized authored W142 Int64 literal: #{display.inspect}")
    end
  when CrystalClick::BinaryDataType::TAG_DATE
    case display
    when "2024-12-31" then "784e"
    when "1970-01-02" then "0100"
    when "2000-02-29" then "082b"
    else                   w142_fail("unrecognized authored W142 Date literal: #{display.inspect}")
    end
  when CrystalClick::BinaryDataType::TAG_IPV4
    case display
    when "192.0.2.1"    then "010200c0"
    when "198.51.100.7" then "076433c6"
    when "203.0.113.9"  then "097100cb"
    else                     w142_fail("unrecognized authored W142 IPv4 literal: #{display.inspect}")
    end
  when CrystalClick::BinaryDataType::TAG_FIXED_STRING
    case display
    when "cat" then "636174"
    when "dog" then "646f67"
    when "owl" then "6f776c"
    when "fox" then "666f78"
    else            w142_fail("unrecognized authored W142 FixedString literal: #{display.inspect}")
    end
  else
    w142_fail("unsupported authored W142 row payload type #{type.name}")
  end
end

def w142_assert_stock_rows(output : String, vector : W142StorageVector, label : String) : Nil
  rows = output.lines.map(&.strip).reject(&.empty?)
  expected_displays = vector.flattened_display
  w142_assert(rows.size == expected_displays.size, "#{label}: stock output row count #{rows.size} != literal #{expected_displays.size}")
  expected_type_hex = w142_hex(vector.native_type_name.to_slice)
  rows.each_with_index do |row, index|
    fields = row.split('\t')
    w142_assert(fields.size == 2, "#{label}: malformed stock RowBinary oracle row #{row.inspect}")
    w142_assert(fields[0].downcase == expected_type_hex.downcase, "#{label} row #{index}: toTypeName differs: #{fields[0].inspect}")
    expected_payload = w142_expected_payload_hex(vector.child_type, expected_displays[index])
    w142_assert(fields[1].downcase == expected_payload.downcase, "#{label} row #{index}: RowBinary payload expected #{expected_payload} got #{fields[1]}")
  end
end

def w142_store(output_root : String, label : String) : String
  path = File.join(output_root, "stores", label)
  Dir.mkdir(path)
  path
end

def w142_run_stock(binary : String, store : String, vector : W142StorageVector, input_path : String) : Tuple(Bool, String, String)
  args = [
    "local", "--path", store,
    "--input-format", "Native",
    "--structure", "x #{vector.native_type_name}",
    "--allow_suspicious_low_cardinality_types=1",
    "--query", "SELECT hex(toTypeName(x)), hex(formatRow('RowBinary', x)) FROM table FORMAT TSVRaw",
  ]
  output = IO::Memory.new
  error = IO::Memory.new
  status = File.open(input_path, "rb") do |input|
    Process.run(binary, args, input: input, output: output, error: error)
  end
  {status.success?, output.to_s, error.to_s}
end

def w142_mutated_streams(streams : CrystalClick::BinaryBulkStreams, role : String, byte_offset : Int, replacement : UInt8) : CrystalClick::BinaryBulkStreams
  roles = Hash(String, CrystalClick::BinaryBulkStream).new
  streams.roles.each do |name|
    stream = streams.stream(name)
    bytes = stream.bytes
    if name == role
      w142_assert(byte_offset >= 0 && byte_offset < bytes.size, "negative control mutation is outside #{role}")
      bytes[byte_offset] = replacement
    end
    roles[name] = CrystalClick::BinaryBulkStream.new(bytes, stream.offsets)
  end
  CrystalClick::BinaryBulkStreams.new(mark_count: streams.mark_count, streams: roles)
end

def w142_expect_value_mismatch(streams : CrystalClick::BinaryBulkStreams, vector : W142StorageVector, label : String) : Nil
  decoded = CrystalClick::BinaryLowCardinalityStorageCodec.decode(vector.type, streams, vector.occurrences)
  begin
    w142_assert_granules(decoded, vector, label)
  rescue error : W142StorageMismatch
    message = error.message || ""
    w142_assert(message.includes?("expected"), "#{label}: value negative control lacked exact expected/got diagnostic: #{message}")
    puts "PASS W142 comparator rejects validly framed #{label}: #{message}"
    return
  end
  w142_fail("#{label}: valid mutation unexpectedly matched authored literal values")
end

def w142_negative_controls(vector : W142StorageVector, streams : CrystalClick::BinaryBulkStreams) : Nil
  return unless vector.label == "lc-string"

  # Keep the encoding structurally valid but mutate one dictionary key and one
  # in-range index ID. The independent literal comparator must identify the
  # first changed logical row in each case.
  bad_dictionary = w142_mutated_streams(streams, "root.dictionary", 18, 'b'.ord.to_u8)
  w142_expect_value_mismatch(bad_dictionary, vector, "dictionary-key mutation")
  bad_index = w142_mutated_streams(streams, "root.indexes", 16, 2_u8)
  w142_expect_value_mismatch(bad_index, vector, "index-ID mutation")
  bad_flags = w142_mutated_streams(streams, "root.indexes", 1, 0x15_u8)
  begin
    CrystalClick::BinaryLowCardinalityStorageCodec.decode(vector.type, bad_flags, vector.occurrences)
  rescue error : CrystalClick::CorruptPartError
    message = error.message || ""
    w142_assert(message.downcase.includes?("flag"), "reserved-flag negative control failed without a cause-specific flag diagnostic: #{message}")
    puts "PASS W142 LC flag negative control: reserved 0x1500 flags rejected specifically: #{message}"
    return
  end
  w142_fail("#{vector.label}: storage decoder accepted reserved global-index flag bits")
end

def w142_assert_stock_wrong_output(output : String, vector : W142StorageVector, label : String) : Nil
  rows = output.lines.map(&.strip).reject(&.empty?)
  displays = vector.flattened_display
  w142_assert(rows.size == displays.size, "#{label}: stock negative-control row count differs")
  expected_type_hex = w142_hex(vector.native_type_name.to_slice)
  rows.each_with_index do |row, index|
    fields = row.split('\t')
    w142_assert(fields.size == 2, "#{label}: malformed stock RowBinary negative-control row #{row.inspect}")
    w142_assert(fields[0].downcase == expected_type_hex.downcase, "#{label} row #{index}: stock type changed under payload mutation")
    expected = w142_expected_payload_hex(vector.child_type, displays[index])
    if index == 0
      changed = w142_expected_payload_hex(vector.child_type, "blue")
      w142_assert(changed != expected, "#{label}: negative-control literals did not distinguish red from blue")
      w142_assert(fields[1].downcase == changed.downcase, "#{label}: stock row 0 payload #{fields[1]} != mutated literal blue #{changed}")
      w142_assert(fields[1].downcase != expected.downcase, "#{label}: stock RowBinary output unexpectedly matched original row-0 literal")
    else
      w142_assert(fields[1].downcase == expected.downcase, "#{label} row #{index}: unrelated stock RowBinary payload changed")
    end
  end
  red_payload = w142_expected_payload_hex(vector.child_type, "red")
  blue_payload = w142_expected_payload_hex(vector.child_type, "blue")
  puts "PASS W142 stock RowBinary wrong-output control: row 0 expected red payload #{red_payload}, got blue payload #{blue_payload}; type and remaining rows unchanged"
end

def w142_stock_negative_control(binary : String, output_root : String, vector : W142StorageVector, streams : CrystalClick::BinaryBulkStreams) : Nil
  return unless vector.label == "lc-string"

  mutated = w142_mutated_streams(streams, "root.indexes", 16, 2_u8)
  native = w142_native_input(vector, mutated)
  input_path = File.join(output_root, "native-input", "lc-string.mutated-index.native")
  w142_write_bytes(input_path, native)
  store = w142_store(output_root, "native-negative-index-lc-string")
  ok, output, error = w142_run_stock(binary, store, vector, input_path)
  w142_write_text(File.join(output_root, "results", "lc-string.mutated-index.tsv"), output)
  w142_write_text(File.join(output_root, "results", "lc-string.mutated-index.stderr"), error)
  w142_assert(ok, "stock rejected validly framed index mutation before it could expose the logical wrong output: #{error.strip}")
  w142_assert_stock_wrong_output(output, vector, "stock native LC index mutation")
end

def w142_check_runtime(binary : String, store : String) : Nil
  version_output = IO::Memory.new
  version_status = Process.run(binary, ["local", "--version"], output: version_output, error: Process::Redirect::Close)
  w142_assert(version_status.success? && version_output.to_s.strip == W142_CLICKHOUSE_VERSION, "pinned W142 ClickHouse version mismatch")
  hash_output = IO::Memory.new
  hash_status = Process.run("shasum", ["-a", "256", binary], output: hash_output, error: Process::Redirect::Close)
  w142_assert(hash_status.success? && hash_output.to_s.split(' ').first? == W142_RUNTIME_SHA256, "pinned W142 ClickHouse executable SHA mismatch")
  identity_query = "SELECT concat(name, '=', value) FROM system.build_options WHERE name IN ('GIT_HASH', 'VERSION_GITHASH') ORDER BY name FORMAT TSVRaw"
  identity = w117_run(binary, store, identity_query).lines.map(&.strip).reject(&.empty?)
  expected = ["GIT_HASH=#{W142_BUILD_HASH}", "VERSION_GITHASH=#{W142_BUILD_HASH}"]
  w142_assert(identity == expected, "pinned W142 ClickHouse build identity mismatch: #{identity.inspect}")
  puts "PASS W142 pinned stock identity: source=#{W142_SOURCE_REVISION} version=#{W142_CLICKHOUSE_VERSION} sha256=#{W142_RUNTIME_SHA256} build=#{W142_BUILD_HASH}"
end

def w142_validate_roots : Tuple(String, String)
  probe_arg = ENV["W141_PROBE_ROOT"]? || w142_fail("W141_PROBE_ROOT is required")
  output_arg = ENV["W142_CHECK_ROOT"]? || w142_fail("W142_CHECK_ROOT is required")
  w142_assert(File.directory?(probe_arg) && !File.symlink?(probe_arg), "W141_PROBE_ROOT must be an existing non-symlink retained fixture")
  probe = File.realpath(probe_arg)
  w142_assert(probe.starts_with?("/private/tmp/crystal-click-object-low-cardinality-w141."), "W141 fixture root is outside its pinned prefix")
  w142_assert(File.directory?(output_arg) && !File.symlink?(output_arg), "W142_CHECK_ROOT must be a freshly created non-symlink output root")
  output = File.realpath(output_arg)
  w142_assert(output.starts_with?("/private/tmp/crystal-click-object-low-cardinality-w142."), "W142 output root is outside its pinned prefix")
  %w(native-input lanes stores results).each do |child|
    path = File.join(output, child)
    w142_assert(File.directory?(path) && !File.symlink?(path) && Dir.empty?(path), "W142 output child #{child} must be a fresh empty directory")
  end
  store_root = File.join(output, "stores")
  w142_assert(Dir.empty?(store_root), "W142 stock stores output must be empty")

  record_path = File.join(probe, "results", "run.txt")
  w142_assert(File.file?(record_path) && !File.symlink?(record_path), "retained W141 run identity record is missing")
  record = File.read(record_path)
  w142_assert(record.lines.any? { |line| line.strip == "source_reference_revision=#{W142_SOURCE_REVISION}" }, "W141 source reference revision differs from the W142 pin")
  w142_assert(record.lines.any? { |line| line.strip == "runtime_sha256=#{W142_RUNTIME_SHA256}" }, "W141 runtime SHA differs from the W142 pin")
  w142_assert(record.lines.any? { |line| line.strip == "runtime_version=#{W142_CLICKHOUSE_VERSION}" }, "W141 runtime version differs from the W142 pin")
  {probe, output}
end

def w142_main : Nil
  probe_root, output_root = w142_validate_roots
  binary = ENV["CLICKHOUSE_BIN"]? || w142_fail("CLICKHOUSE_BIN is required")
  identity_store = w142_store(output_root, "identity")
  w142_check_runtime(binary, identity_store)
  identity_record = [
    "fixture_root=#{probe_root}",
    "clickhouse_source_revision=#{W142_SOURCE_REVISION}",
    "clickhouse_build_hash=#{W142_BUILD_HASH}",
    "runtime_version=#{W142_CLICKHOUSE_VERSION}",
    "runtime_sha256=#{W142_RUNTIME_SHA256}",
    "claim_scope=retained_native_decompressed_lc_lanes_and_stock_native_consumer_after_global_to_additional_flag_conversion",
    "excluded=direct_global_native_consumption,standalone_part_writer,compressed_frame_checksum_validation",
  ].join("\n") + "\n"
  w142_write_text(File.join(output_root, "results", "run.txt"), identity_record)

  vectors = w142_cases
  vectors.each do |vector|
    lanes = w142_part_lanes(probe_root, vector)
    encoded = CrystalClick::BinaryLowCardinalityStorageCodec.encode(vector.type, vector.expected_values)
    w142_assert_streams_equal(encoded, lanes.streams, "#{vector.label}: codec output vs retained W141 native lanes")

    decoded = CrystalClick::BinaryLowCardinalityStorageCodec.decode(vector.type, lanes.streams, vector.occurrences)
    w142_assert_granules(decoded, vector, "#{vector.label} retained ClickHouse lanes")
    middle = CrystalClick::BinaryLowCardinalityStorageCodec.decode(vector.type, lanes.streams, vector.occurrences, first_mark: 1, mark_count: 1)
    w142_assert(middle.size == 1, "#{vector.label}: middle-mark selection returned wrong mark count")
    w142_assert_granules([middle[0]] of Array(CrystalClick::BinaryValue), W142StorageVector.new(
      "#{vector.label}-middle", vector.child_type, vector.native_type_name,
      [vector.values_per_mark[1]] of Array(String?), vector.dictionary_substream, vector.index_substream,
      vector.dictionary_basename, vector.index_basename, [vector.expected_index_offsets[1]],
    ), "#{vector.label} selected middle mark")

    codec_dictionary_path = File.join(output_root, "lanes", "#{vector.label}.dictionary.global.bin")
    codec_index_path = File.join(output_root, "lanes", "#{vector.label}.indexes.global.bin")
    codec_dictionary = encoded.stream("root.dictionary")
    codec_indexes = encoded.stream("root.indexes")
    retained_dictionary = lanes.streams.stream("root.dictionary")
    retained_indexes = lanes.streams.stream("root.indexes")
    w142_write_bytes(codec_dictionary_path, codec_dictionary.bytes)
    w142_write_bytes(codec_index_path, codec_indexes.bytes)
    w142_write_bytes(File.join(output_root, "lanes", "#{vector.label}.dictionary.retained-native.bin"), retained_dictionary.bytes)
    w142_write_bytes(File.join(output_root, "lanes", "#{vector.label}.indexes.retained-native.bin"), retained_indexes.bytes)
    offset_record = [
      "dictionary=#{codec_dictionary.offsets.inspect}",
      "indexes=#{codec_indexes.offsets.inspect}",
      "retained_dictionary=#{retained_dictionary.offsets.inspect}",
      "retained_indexes=#{retained_indexes.offsets.inspect}",
    ].join("\n") + "\n"
    w142_write_text(File.join(output_root, "results", "#{vector.label}.offsets.txt"), offset_record)

    native_input = w142_native_input(vector, encoded)
    native_path = File.join(output_root, "native-input", "#{vector.label}.native")
    w142_write_bytes(native_path, native_input)
    store = w142_store(output_root, "native-#{vector.label}")
    ok, output, error = w142_run_stock(binary, store, vector, native_path)
    w142_write_text(File.join(output_root, "results", "#{vector.label}.tsv"), output)
    w142_write_text(File.join(output_root, "results", "#{vector.label}.stderr"), error)
    w142_assert(ok, "#{vector.label}: pinned ClickHouse rejected codec-generated Native dictionary/ID payloads: #{error.strip}")
    w142_assert_stock_rows(output, vector, "#{vector.label} codec bytes -> stock Native input")
    w142_negative_controls(vector, lanes.streams)
    w142_stock_negative_control(binary, output_root, vector, lanes.streams)
    puts "PASS W142 physical LC codec <-> retained native lanes + stock Native consumer: #{vector.label} (#{vector.occurrences.sum} leaf occurrences)"
  end

  puts "PASS W142 bounded physical LowCardinality storage oracle: #{vectors.size} exact two-lane matches, #{vectors.size} stock Native consumers, all rows and middle marks checked. Native conversion changes global flags to additional/update framing; no direct global-Native or standalone-part-writer claim. CH compression checksums are not validated by the current decompressor."
end

w142_main
