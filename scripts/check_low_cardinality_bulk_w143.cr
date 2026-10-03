# W143 full-container oracle for recursive BinaryBulk LowCardinality lanes.
# The logical vectors are authored below; retained W141 parts provide the
# independent decompressed lane/mark witnesses, and stock Native consumes a
# separately documented recursive framing adapter. This is not an Object
# reader, ATTACH test, complete part writer, or direct global-Native reader.
require "file_utils"
require "../src/crystal_click"

W143_SOURCE_REVISION    = "9007d227b64a3f8b667fc5258ceb2923f3cf477d"
W143_CLICKHOUSE_VERSION = "ClickHouse local version 26.10.1.1201 (official build)."
W143_RUNTIME_SHA256     = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
W143_BUILD_HASH         = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"

class W143Mismatch < Exception
end

struct W143PhysicalLaneSpec
  getter role : String
  getter substream : String
  getter basename : String
  getter real_mark_offsets : Array(UInt64)
  getter expected_hex : String

  def initialize(@role : String, @substream : String, @basename : String,
                 @real_mark_offsets : Array(UInt64), @expected_hex : String)
  end
end

struct W143Fixture
  getter label : String
  getter type : CrystalClick::BinaryDataType
  getter native_type_name : String
  getter stock_type_name : String
  getter values_per_mark : Array(Array(CrystalClick::BinaryValue))
  getter low_cardinality_path : String
  getter dictionary_substream : String
  getter index_substream : String
  getter dictionary_basename : String
  getter index_basename : String
  getter expected_index_offsets : Array(UInt64)
  getter expected_lc_occurrences_per_mark : Array(UInt64)
  getter physical_lanes : Array(W143PhysicalLaneSpec)

  def initialize(@label : String, @type : CrystalClick::BinaryDataType,
                 @native_type_name : String, @stock_type_name : String,
                 @values_per_mark : Array(Array(CrystalClick::BinaryValue)),
                 @low_cardinality_path : String,
                 @dictionary_substream : String, @index_substream : String,
                 @dictionary_basename : String, @index_basename : String,
                 @expected_index_offsets : Array(UInt64),
                 @expected_lc_occurrences_per_mark : Array(UInt64),
                 @physical_lanes : Array(W143PhysicalLaneSpec))
  end

  def rows_per_mark : Array(UInt64)
    values_per_mark.map { |mark| mark.size.to_u64 }
  end

  def flattened_values : Array(CrystalClick::BinaryValue)
    values_per_mark.flatten
  end

  def dictionary_role : String
    "#{low_cardinality_path}.dictionary"
  end

  def index_role : String
    "#{low_cardinality_path}.indexes"
  end
end

def w143_fail(message : String) : NoReturn
  raise W143Mismatch.new(message)
end

def w143_assert(condition : Bool, message : String) : Nil
  w143_fail(message) unless condition
end

def w143_read_bytes(path : String, label : String) : Bytes
  w143_assert(File.file?(path) && !File.symlink?(path), "#{label}: missing file or symlink")
  File.open(path, "rb") do |file|
    unless file.size <= Int32::MAX
      w143_fail("#{label}: retained witness exceeds the supported in-memory lane size")
    end
    bytes = Bytes.new(file.size.to_i32)
    file.read_fully(bytes)
    bytes
  end
end

def w143_bytes_from_hex(hex : String) : Bytes
  w143_assert(hex.bytesize.even?, "authored W143 hex literal has an odd length")
  source = hex.to_slice
  bytes = Bytes.new(source.size // 2, 0_u8)
  bytes.size.times do |index|
    high = case source[index * 2]
           when 48_u8..57_u8  then source[index * 2] - 48_u8
           when 65_u8..70_u8  then source[index * 2] - 55_u8
           when 97_u8..102_u8 then source[index * 2] - 87_u8
           else                    w143_fail("authored W143 literal contains a non-hex byte")
           end
    low = case source[index * 2 + 1]
          when 48_u8..57_u8  then source[index * 2 + 1] - 48_u8
          when 65_u8..70_u8  then source[index * 2 + 1] - 55_u8
          when 97_u8..102_u8 then source[index * 2 + 1] - 87_u8
          else                    w143_fail("authored W143 literal contains a non-hex byte")
          end
    bytes[index] = (high << 4) | low
  end
  bytes
end

def w143_hex(bytes : Bytes) : String
  String.build do |io|
    bytes.each { |byte| io << byte.to_s(16).rjust(2, '0') }
  end
end

def w143_concat(parts : Array(Bytes)) : Bytes
  size = parts.sum(&.size)
  bytes = Bytes.new(size) { 0_u8 }
  offset = 0
  parts.each do |part|
    part.each_with_index { |byte, index| bytes[offset + index] = byte }
    offset += part.size
  end
  bytes
end

def w143_u64_bytes(value : UInt64) : Bytes
  Bytes.new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

def w143_u64_array(values : Array(UInt64)) : Bytes
  w143_concat(values.map { |value| w143_u64_bytes(value) })
end

def w143_u64_le(bytes : Bytes, offset : Int, label : String) : UInt64
  w143_assert(offset >= 0 && offset <= bytes.size - 8, "#{label}: UInt64 read outside bytes")
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

def w143_slice(bytes : Bytes, offset : Int, length : Int, label : String) : Bytes
  w143_assert(offset >= 0 && length >= 0 && offset <= bytes.size - length, "#{label}: slice outside bytes")
  Bytes.new(length) { |index| bytes[offset + index] }
end

def w143_var_uint(value : UInt64, destination : Array(UInt8)) : Nil
  remaining = value
  while remaining >= 0x80_u64
    destination << ((remaining & 0x7f_u64).to_u8 | 0x80_u8)
    remaining >>= 7
  end
  destination << remaining.to_u8
end

def w143_native_string(value : String, destination : Array(UInt8)) : Nil
  w143_var_uint(value.bytesize.to_u64, destination)
  value.to_slice.each { |byte| destination << byte }
end

def w143_native_u64(value : UInt64, destination : Array(UInt8)) : Nil
  w143_u64_bytes(value).each { |byte| destination << byte }
end

def w143_bytes_from_array(bytes : Array(UInt8)) : Bytes
  Bytes.new(bytes.size) { |index| bytes[index] }
end

def w143_write_bytes(path : String, bytes : Bytes) : Nil
  w143_assert(!File.exists?(path) && !File.symlink?(path), "refusing to overwrite W143 output: #{path}")
  File.open(path, "wb") { |file| file.write(bytes) }
end

def w143_write_text(path : String, value : String) : Nil
  w143_assert(!File.exists?(path) && !File.symlink?(path), "refusing to overwrite W143 output: #{path}")
  File.open(path, "w") { |file| file << value }
end

def w143_low(low_type : CrystalClick::BinaryDataType, value : String) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.low_cardinality(low_type, CrystalClick::BinaryValue.string(value))
end

def w143_array_value(type : CrystalClick::BinaryDataType, low_type : CrystalClick::BinaryDataType,
                     values : Array(String)) : CrystalClick::BinaryValue
  items = values.map { |value| w143_low(low_type, value) }
  CrystalClick::BinaryValue.array(type, items)
end

def w143_map_value(type : CrystalClick::BinaryDataType, low_type : CrystalClick::BinaryDataType,
                   pairs : Array(Tuple(String, String))) : CrystalClick::BinaryValue
  flat = [] of CrystalClick::BinaryValue
  pairs.each do |pair|
    flat << CrystalClick::BinaryValue.string(pair[0])
    flat << w143_low(low_type, pair[1])
  end
  CrystalClick::BinaryValue.map(type, flat)
end

def w143_tuple_value(type : CrystalClick::BinaryDataType, low_type : CrystalClick::BinaryDataType,
                     label : String, number_hex : String) : CrystalClick::BinaryValue
  uint32_type = type.child_at(1)
  CrystalClick::BinaryValue.tuple(type, [
    w143_low(low_type, label),
    CrystalClick::BinaryValue.fixed(uint32_type, w143_bytes_from_hex(number_hex)),
  ] of CrystalClick::BinaryValue)
end

def w143_dictionary_literal : String
  # v1, five entries: empty default, then red, blue, green, UTF-8 snow.
  "01000000000000000500000000000000000372656404626c756505677265656e03e99baa"
end

def w143_array_fixture : W143Fixture
  string_type = CrystalClick::BinaryDataType.primitive("String")
  low_type = CrystalClick::BinaryDataType.low_cardinality(string_type)
  type = CrystalClick::BinaryDataType.array(low_type)
  values = [
    [w143_array_value(type, low_type, ["red", "blue"]), w143_array_value(type, low_type, [] of String),
     w143_array_value(type, low_type, ["red"]), w143_array_value(type, low_type, ["green", "blue"])],
    [w143_array_value(type, low_type, ["blue"]), w143_array_value(type, low_type, [""]),
     w143_array_value(type, low_type, ["red", "雪"]), w143_array_value(type, low_type, ["雪"])],
    [w143_array_value(type, low_type, ["green"])],
  ] of Array(CrystalClick::BinaryValue)

  lanes = [
    W143PhysicalLaneSpec.new("root.sizes", "j.v.size0", "f11860813383030253b950ed805faf59",
      [0_u64, 32_u64, 64_u64], "020000000000000000000000000000000100000000000000020000000000000001000000000000000100000000000000020000000000000001000000000000000100000000000000"),
    W143PhysicalLaneSpec.new("root.elements.dictionary", "j.v.dict", "44c7b1beffff8a7b139857964e5e01d9",
      [8_u64, 8_u64, 8_u64], w143_dictionary_literal),
    W143PhysicalLaneSpec.new("root.elements.indexes", "j.v", "9f73de78faa16746f8905bcd1bd2dc16",
      [0_u64, 21_u64, 42_u64], "0005000000000000050000000000000001020103020001000000000000050000000000000002000104040001000000000000010000000000000003"),
  ] of W143PhysicalLaneSpec

  W143Fixture.new("array-lc-string", type, "Array(LowCardinality(String))",
    "Array(LowCardinality(String))", values, "root.elements", "j.v.dict", "j.v",
    "44c7b1beffff8a7b139857964e5e01d9", "9f73de78faa16746f8905bcd1bd2dc16",
    [0_u64, 21_u64, 42_u64], [5_u64, 5_u64, 1_u64], lanes)
end

def w143_map_fixture : W143Fixture
  string_type = CrystalClick::BinaryDataType.primitive("String")
  low_type = CrystalClick::BinaryDataType.low_cardinality(string_type)
  type = CrystalClick::BinaryDataType.map(string_type, low_type)
  values = [
    [w143_map_value(type, low_type, [{"a", "red"}, {"b", "blue"}]),
     w143_map_value(type, low_type, [] of Tuple(String, String)),
     w143_map_value(type, low_type, [{"a", "red"}]),
     w143_map_value(type, low_type, [{"a", "green"}, {"b", "blue"}])],
    [w143_map_value(type, low_type, [{"b", "blue"}]), w143_map_value(type, low_type, [{"a", ""}]),
     w143_map_value(type, low_type, [{"a", "red"}, {"b", "雪"}]),
     w143_map_value(type, low_type, [{"a", "雪"}])],
    [w143_map_value(type, low_type, [{"a", "green"}])],
  ] of Array(CrystalClick::BinaryValue)

  lanes = [
    W143PhysicalLaneSpec.new("root.sizes", "j.v.size0", "f11860813383030253b950ed805faf59",
      [0_u64, 32_u64, 64_u64], "020000000000000000000000000000000100000000000000020000000000000001000000000000000100000000000000020000000000000001000000000000000100000000000000"),
    W143PhysicalLaneSpec.new("root.elements.field.0.string_sizes", "j.v%2Ekeys.size", "205df02da5a02ea691bed22b8d552f15",
      [0_u64, 40_u64, 80_u64], "01000000000000000100000000000000010000000000000001000000000000000100000000000000010000000000000001000000000000000100000000000000010000000000000001000000000000000100000000000000"),
    W143PhysicalLaneSpec.new("root.elements.field.0.data", "j.v%2Ekeys", "95e683f82e455a1bb995a8daa5bb8e14",
      [0_u64, 5_u64, 10_u64], "6162616162626161626161"),
    W143PhysicalLaneSpec.new("root.elements.field.1.dictionary", "j.v%2Evalues.dict", "99390d84521a900a8e2df19f4c766dc6",
      [8_u64, 8_u64, 8_u64], w143_dictionary_literal),
    W143PhysicalLaneSpec.new("root.elements.field.1.indexes", "j.v%2Evalues", "fb2145d39122827046f1d8d403bfdc44",
      [0_u64, 21_u64, 42_u64], "0005000000000000050000000000000001020103020001000000000000050000000000000002000104040001000000000000010000000000000003"),
  ] of W143PhysicalLaneSpec

  W143Fixture.new("map-lc-string", type, "Map(String, LowCardinality(String))",
    "Map(String, LowCardinality(String))", values, "root.elements.field.1", "j.v%2Evalues.dict",
    "j.v%2Evalues", "99390d84521a900a8e2df19f4c766dc6", "fb2145d39122827046f1d8d403bfdc44",
    [0_u64, 21_u64, 42_u64], [5_u64, 5_u64, 1_u64], lanes)
end

def w143_tuple_fixture : W143Fixture
  low_string = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive("String"))
  uint32 = CrystalClick::BinaryDataType.primitive("UInt32")
  type = CrystalClick::BinaryDataType.tuple([low_string, uint32] of CrystalClick::BinaryDataType, ["s", "n"] of String)
  values = [
    [w143_tuple_value(type, low_string, "red", "34120000"),
     w143_tuple_value(type, low_string, "blue", "01000000"),
     w143_tuple_value(type, low_string, "red", "34120000"),
     w143_tuple_value(type, low_string, "green", "ffffffff")],
    [w143_tuple_value(type, low_string, "blue", "01000000"),
     w143_tuple_value(type, low_string, "", "ffff0000"),
     w143_tuple_value(type, low_string, "red", "34120000"),
     w143_tuple_value(type, low_string, "雪", "2a000000")],
    [w143_tuple_value(type, low_string, "green", "ffffffff")],
  ] of Array(CrystalClick::BinaryValue)

  lanes = [
    W143PhysicalLaneSpec.new("root.field.0.dictionary", "j.v%2Es.dict", "2439c63873ae01ce880012fcfcbd70e3",
      [8_u64, 8_u64, 8_u64], w143_dictionary_literal),
    W143PhysicalLaneSpec.new("root.field.0.indexes", "j.v%2Es", "acf978187e84253692d0566517f4c3f5",
      [0_u64, 20_u64, 40_u64], "000500000000000004000000000000000102010300010000000000000400000000000000020001040001000000000000010000000000000003"),
    W143PhysicalLaneSpec.new("root.field.1.data", "j.v%2En", "690ea6dd9278aefde7438ec97e4b49e4",
      [0_u64, 16_u64, 32_u64], "341200000100000034120000ffffffff01000000ffff0000341200002a000000ffffffff"),
  ] of W143PhysicalLaneSpec

  W143Fixture.new("tuple-lc-string", type, "Tuple(s LowCardinality(String), n UInt32)",
    "Tuple(\n    s LowCardinality(String),\n    n UInt32)", values, "root.field.0", "j.v%2Es.dict",
    "j.v%2Es", "2439c63873ae01ce880012fcfcbd70e3", "acf978187e84253692d0566517f4c3f5",
    [0_u64, 20_u64, 40_u64], [4_u64, 4_u64, 1_u64], lanes)
end

def w143_fixtures : Array(W143Fixture)
  [w143_array_fixture, w143_map_fixture, w143_tuple_fixture]
end

def w143_assert_value(actual : CrystalClick::BinaryValue, expected : CrystalClick::BinaryValue, label : String) : Nil
  w143_assert(actual.type.name == expected.type.name, "#{label}: nominal type differs: #{actual.type.name} != #{expected.type.name}")
  w143_assert(actual.type.tag == expected.type.tag, "#{label}: type tag differs")
  w143_assert(actual.is_null? == expected.is_null?, "#{label}: NULL state differs")
  w143_assert(actual.child_count == expected.child_count, "#{label}: child count differs")
  if actual.is_null?
    w143_assert(actual.child_count == 0, "#{label}: NULL value unexpectedly has children")
    return
  end

  case actual.type.tag
  when CrystalClick::BinaryDataType::TAG_ARRAY,
       CrystalClick::BinaryDataType::TAG_MAP,
       CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE,
       CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
    actual.child_count.times do |index|
      w143_assert_value(actual.child_at(index), expected.child_at(index), "#{label}[#{index}]")
    end
  when CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY
    w143_assert(actual.child_count == 1, "#{label}: LowCardinality value must have one child")
    w143_assert_value(actual.child_at(0), expected.child_at(0), "#{label}.value")
  when CrystalClick::BinaryDataType::TAG_NULLABLE
    w143_assert(actual.child_count == 1, "#{label}: non-NULL Nullable value must have one child")
    w143_assert_value(actual.child_at(0), expected.child_at(0), "#{label}.value")
  when CrystalClick::BinaryDataType::TAG_BOOL
    w143_assert(actual.as_bool == expected.as_bool, "#{label}: Bool value differs")
  else
    w143_assert(actual.child_count == 0, "#{label}: scalar value unexpectedly has children")
    unless actual.bytes == expected.bytes
      w143_fail("#{label}: bytes expected #{w143_hex(expected.bytes)}, got #{w143_hex(actual.bytes)}")
    end
  end
end

def w143_assert_values(actual : Array(Array(CrystalClick::BinaryValue)),
                       expected : Array(Array(CrystalClick::BinaryValue)), label : String) : Nil
  w143_assert(actual.size == expected.size, "#{label}: mark count #{actual.size} != literal #{expected.size}")
  actual.each_with_index do |mark, mark_index|
    w143_assert(mark.size == expected[mark_index].size, "#{label}: mark #{mark_index} root row count differs")
    mark.each_with_index do |value, row_index|
      w143_assert_value(value, expected[mark_index][row_index], "#{label} mark #{mark_index} row #{row_index}")
    end
  end
end

def w143_compressed(path : String, label : String) : Bytes
  CrystalClick::CompressedBlock.decode_all(w143_read_bytes(path, label))
end

def w143_mark_offsets(path : String, bytes : Bytes, expected : Array(UInt64), label : String) : Array(UInt64)
  marks = w143_compressed(path, "#{label} compressed marks")
  w143_assert(marks.size == expected.size * 16, "#{label}: mark record count differs from authored native schedule")
  offsets = [] of UInt64
  expected.each_with_index do |expected_offset, index|
    compressed = w143_u64_le(marks, index * 16, "#{label} mark #{index} compressed offset")
    decompressed = w143_u64_le(marks, index * 16 + 8, "#{label} mark #{index} decompressed offset")
    w143_assert(compressed == 0_u64, "#{label}: W141 fixture is expected to use one compressed data frame")
    w143_assert(decompressed == expected_offset, "#{label}: mark #{index} offset #{decompressed} != authored #{expected_offset}")
    offsets << decompressed
  end
  offsets << bytes.size.to_u64
  w143_assert(offsets.each_cons(2).all? { |pair| pair[0] <= pair[1] }, "#{label}: mark offsets are not monotone")
  offsets
end

def w143_part_streams(probe_root : String, fixture : W143Fixture) : Tuple(String, CrystalClick::BinaryBulkStreams)
  candidates = Dir.glob(File.join(probe_root, "stores", fixture.label, "store", "**", "all_1_1_0"))
  w143_assert(candidates.size == 1, "#{fixture.label}: expected one retained W141 part, found #{candidates.size}")
  part = candidates.first
  w143_assert(File.directory?(part) && !File.symlink?(part), "#{fixture.label}: part directory missing or symlinked")
  metadata_path = File.join(part, "columns_substreams.txt")
  w143_assert(File.file?(metadata_path) && !File.symlink?(metadata_path), "#{fixture.label}: substream metadata missing or symlinked")
  substreams = File.read(metadata_path).lines.map(&.strip)
  streams = Hash(String, CrystalClick::BinaryBulkStream).new

  fixture.physical_lanes.each do |lane|
    w143_assert(substreams.includes?(lane.substream), "#{fixture.label}: retained part omits #{lane.substream}")
    w143_assert(CrystalClick::StreamName.hash(lane.substream) == lane.basename,
      "#{fixture.label}: retained basename does not hash from #{lane.substream}")
    bytes_path = File.join(part, "#{lane.basename}.bin")
    marks_path = File.join(part, "#{lane.basename}.cmrk")
    bytes = w143_compressed(bytes_path, "#{fixture.label} #{lane.role} data")
    actual_hex = w143_hex(bytes)
    w143_assert(actual_hex == lane.expected_hex,
      "#{fixture.label} #{lane.role}: retained bytes differ from authored witness (#{actual_hex})")
    offsets = w143_mark_offsets(marks_path, bytes, lane.real_mark_offsets, "#{fixture.label} #{lane.role}")
    streams[lane.role] = CrystalClick::BinaryBulkStream.new(bytes, offsets)
  end

  expected_roles = fixture.physical_lanes.map(&.role).sort
  actual_roles = streams.keys.sort
  w143_assert(actual_roles == expected_roles, "#{fixture.label}: retained recursive roles differ")
  {part, CrystalClick::BinaryBulkStreams.new(mark_count: 3, streams: streams)}
end

def w143_assert_streams_equal(actual : CrystalClick::BinaryBulkStreams,
                              expected : CrystalClick::BinaryBulkStreams,
                              label : String) : Nil
  w143_assert(actual.mark_count == expected.mark_count, "#{label}: mark count differs")
  w143_assert(actual.roles == expected.roles, "#{label}: role set differs: #{actual.roles.inspect} != #{expected.roles.inspect}")
  actual.roles.each do |role|
    a = actual.stream(role)
    e = expected.stream(role)
    w143_assert(a.offsets == e.offsets, "#{label} #{role}: mark grid #{a.offsets.inspect} != retained #{e.offsets.inspect}")
    unless a.bytes == e.bytes
      w143_fail("#{label} #{role}: bytes expected retained #{w143_hex(e.bytes)}, got codec #{w143_hex(a.bytes)}")
    end
  end
end

def w143_read_u64_lane(stream : CrystalClick::BinaryBulkStream, index : Int, label : String) : UInt64
  w143_u64_le(stream.bytes, index * 8, label)
end

def w143_index_occurrences(stream : CrystalClick::BinaryBulkStream, label : String) : Array(UInt64)
  bytes = stream.bytes
  counts = [] of UInt64
  stream.mark_count.times do |mark|
    start = stream.offset_at(mark).to_i
    finish = stream.offset_at(mark + 1).to_i
    if start == finish
      counts << 0_u64
      next
    end
    w143_assert(finish - start >= 16, "#{label}: mark #{mark} index record is shorter than its header")
    counts << w143_u64_le(bytes, start + 8, "#{label} mark #{mark} occurrence count")
  end
  counts
end

def w143_append_lc_prefixes(type : CrystalClick::BinaryDataType, path : String,
                            streams : CrystalClick::BinaryBulkStreams,
                            destination : Array(UInt8)) : Nil
  case type.tag
  when CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY
    dictionary = streams.stream("#{path}.dictionary").bytes
    w143_assert(dictionary.size >= 8, "#{path}: LowCardinality version prefix is missing")
    version = w143_u64_le(dictionary, 0, "#{path} dictionary version")
    w143_assert(version == 1_u64, "#{path}: unsupported LowCardinality version #{version}")
    w143_slice(dictionary, 0, 8, "#{path} dictionary version").each { |byte| destination << byte }
  when CrystalClick::BinaryDataType::TAG_ARRAY
    w143_append_lc_prefixes(type.child_at(0), "#{path}.elements", streams, destination)
  when CrystalClick::BinaryDataType::TAG_NULLABLE
    w143_append_lc_prefixes(type.child_at(0), "#{path}.nested", streams, destination)
  when CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE, CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
    type.child_count.times do |index|
      w143_append_lc_prefixes(type.child_at(index), "#{path}.field.#{index}", streams, destination)
    end
  when CrystalClick::BinaryDataType::TAG_MAP
    w143_append_lc_prefixes(type.child_at(0), "#{path}.elements.field.0", streams, destination)
    w143_append_lc_prefixes(type.child_at(1), "#{path}.elements.field.1", streams, destination)
  end
  nil
end

def w143_append_lc_native_record(path : String, streams : CrystalClick::BinaryBulkStreams,
                                 expected_count : UInt64, destination : Array(UInt8)) : Nil
  dictionary = streams.stream("#{path}.dictionary")
  indexes = streams.stream("#{path}.indexes")
  dict_bytes = dictionary.bytes
  index_bytes = indexes.bytes
  w143_assert(dictionary.offset_at(0) == 8_u64 && dict_bytes.size >= 16,
    "#{path}: expected a v1 prefix followed by a dictionary record")
  w143_assert(w143_u64_le(dict_bytes, 0, "#{path} version") == 1_u64, "#{path}: dictionary version is not v1")

  width_code : UInt64? = nil
  ids = [] of UInt8
  id_count = 0_u64
  indexes.mark_count.times do |mark|
    start = indexes.offset_at(mark).to_i
    finish = indexes.offset_at(mark + 1).to_i
    next if finish == start
    w143_assert(finish - start >= 16, "#{path}: mark #{mark} index record is shorter than its header")
    flags = w143_u64_le(index_bytes, start, "#{path} mark #{mark} flags")
    count = w143_u64_le(index_bytes, start + 8, "#{path} mark #{mark} occurrence count")
    width = flags & 0xff_u64
    w143_assert(width <= 3_u64, "#{path}: unsupported dictionary index width #{width}")
    w143_assert((flags & 0x100_u64) != 0_u64 && (flags & 0x200_u64) == 0_u64,
      "#{path}: expected global-only codec dictionary flags before Native conversion")
    w143_assert((flags & ~0x703_u64) == 0_u64, "#{path}: flags include bits outside width/global/update profile mask 0x703")
    if known = width_code
      w143_assert(known == width, "#{path}: LC index width changed across marks")
    else
      width_code = width
    end
    bytes_per_id = 1 << width.to_i
    w143_assert(count <= UInt64::MAX // bytes_per_id.to_u64, "#{path}: index payload size overflows")
    payload_size = (count * bytes_per_id.to_u64).to_i
    w143_assert(finish - start == 16 + payload_size, "#{path}: mark #{mark} index record size/count mismatch")
    count.times do |index|
      byte_offset = start + 16 + index.to_i * bytes_per_id
      bytes_per_id.times { |byte| ids << index_bytes[byte_offset + byte] }
    end
    id_count += count
  end
  w143_assert(id_count == expected_count, "#{path}: flattened index count #{id_count} != structural occurrence count #{expected_count}")
  width = width_code || 0_u64
  w143_assert(width_code != nil || expected_count == 0_u64, "#{path}: nonempty LC value has no index record")

  # Native FORMAT uses one additional-key record with flags 0x600|width.
  # The W143 dictionary suffix already is the exact count+scalar-key payload;
  # only the representation state/record boundary changes. This does not claim
  # direct global-dictionary Native consumption or a part writer.
  w143_native_u64(0x600_u64 | width, destination)
  w143_slice(dict_bytes, 8, dict_bytes.size - 8, "#{path} dictionary keys").each { |byte| destination << byte }
  w143_native_u64(id_count, destination)
  ids.each { |byte| destination << byte }
end

def w143_append_native_body(type : CrystalClick::BinaryDataType, path : String,
                            occurrence_count : UInt64, streams : CrystalClick::BinaryBulkStreams,
                            profile : CrystalClick::BinaryBulkProfile,
                            destination : Array(UInt8)) : Nil
  case type.tag
  when CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY
    w143_append_lc_native_record(path, streams, occurrence_count, destination)
  when CrystalClick::BinaryDataType::TAG_ARRAY, CrystalClick::BinaryDataType::TAG_MAP
    size_lane = streams.stream("#{path}.sizes")
    w143_assert(size_lane.bytes.size == occurrence_count.to_i * 8, "#{path}: per-row size lane length differs from occurrence count")
    cumulative = 0_u64
    sizes = [] of UInt64
    occurrence_count.times do |index|
      cumulative += w143_read_u64_lane(size_lane, index.to_i, "#{path} size #{index}")
      sizes << cumulative
    end
    # Native Array/Map BASIC serializers write cumulative offsets, whereas the
    # W143 part profile writes independent per-row size values.
    w143_u64_array(sizes).each { |byte| destination << byte }
    child_count = if type.tag == CrystalClick::BinaryDataType::TAG_ARRAY
                    cumulative
                  else
                    # Map sizes count key/value pairs, but each child lane has
                    # one key/value occurrence per pair.
                    cumulative
                  end
    if type.tag == CrystalClick::BinaryDataType::TAG_ARRAY
      w143_append_native_body(type.child_at(0), "#{path}.elements", child_count, streams, profile, destination)
    else
      w143_append_native_body(type.child_at(0), "#{path}.elements.field.0", child_count, streams, profile, destination)
      w143_append_native_body(type.child_at(1), "#{path}.elements.field.1", child_count, streams, profile, destination)
    end
  when CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE, CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
    if type.child_count == 0
      occurrence_count.times { destination << '0'.ord.to_u8 }
    else
      type.child_count.times do |index|
        w143_append_native_body(type.child_at(index), "#{path}.field.#{index}", occurrence_count, streams, profile, destination)
      end
    end
  when CrystalClick::BinaryDataType::TAG_STRING
    data = streams.stream("#{path}.data").bytes
    if profile.with_size_stream?
      sizes = streams.stream("#{path}.string_sizes")
      w143_assert(sizes.bytes.size == occurrence_count.to_i * 8, "#{path}: String size lane length differs from occurrence count")
      data_offset = 0
      occurrence_count.times do |index|
        size = w143_read_u64_lane(sizes, index.to_i, "#{path} string size #{index}")
        w143_assert(size <= Int32::MAX.to_u64, "#{path}: Native String length exceeds the supported adapter domain")
        w143_var_uint(size, destination)
        w143_slice(data, data_offset, size.to_i, "#{path} String bytes").each { |byte| destination << byte }
        data_offset += size.to_i
      end
      w143_assert(data_offset == data.size, "#{path}: WithSize data lane has unconsumed bytes")
    else
      data.each { |byte| destination << byte }
    end
  when CrystalClick::BinaryDataType::TAG_NULLABLE
    # Included for path completeness; the retained W141 recursive witnesses
    # in this slice do not contain an ordinary Nullable leaf.
    nulls = streams.stream("#{path}.nulls").bytes
    w143_assert(nulls.size == occurrence_count.to_i, "#{path}: Nullable null-map length differs")
    nulls.each { |byte| destination << byte }
    w143_append_native_body(type.child_at(0), "#{path}.nested", occurrence_count, streams, profile, destination)
  when CrystalClick::BinaryDataType::TAG_NOTHING
    occurrence_count.times { destination << '0'.ord.to_u8 }
  else
    data = streams.stream("#{path}.data").bytes
    width = type.fixed_width || raise CrystalClick::UnsupportedFormatError.new("W143 Native adapter does not support #{type.name}")
    expected_size = occurrence_count * width.to_u64
    w143_assert(expected_size == data.size.to_u64, "#{path}: fixed-width lane length differs from occurrence count")
    data.each { |byte| destination << byte }
  end
  nil
end

def w143_native_input(fixture : W143Fixture, streams : CrystalClick::BinaryBulkStreams,
                      profile : CrystalClick::BinaryBulkProfile) : Bytes
  rows = fixture.rows_per_mark.sum
  native = [] of UInt8
  w143_var_uint(1_u64, native)
  w143_var_uint(rows, native)
  w143_native_string("x", native)
  w143_native_string(fixture.native_type_name, native)
  # NativeWriter recursively writes serialization state prefixes before the
  # data callback: LC v1 precedes Array offsets / Tuple fields / Map body.
  w143_append_lc_prefixes(fixture.type, "root", streams, native)
  w143_append_native_body(fixture.type, "root", rows, streams, profile, native)
  w143_bytes_from_array(native)
end

def w143_expected_row_binary(value : CrystalClick::BinaryValue, destination : Array(UInt8)) : Nil
  type = value.type
  case type.tag
  when CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY
    w143_expected_row_binary(value.child_at(0), destination)
  when CrystalClick::BinaryDataType::TAG_STRING
    payload = value.bytes
    w143_var_uint(payload.size.to_u64, destination)
    payload.each { |byte| destination << byte }
  when CrystalClick::BinaryDataType::TAG_ARRAY
    w143_var_uint(value.element_count.to_u64, destination)
    value.elements.each { |child| w143_expected_row_binary(child, destination) }
  when CrystalClick::BinaryDataType::TAG_MAP
    w143_var_uint((value.element_count // 2).to_u64, destination)
    value.elements.each { |child| w143_expected_row_binary(child, destination) }
  when CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE, CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
    value.elements.each { |child| w143_expected_row_binary(child, destination) }
  when CrystalClick::BinaryDataType::TAG_NULLABLE
    if value.is_null?
      destination << 0x01_u8
    else
      destination << 0x00_u8
      w143_expected_row_binary(value.child_at(0), destination)
    end
  when CrystalClick::BinaryDataType::TAG_NOTHING
    destination << '0'.ord.to_u8
  else
    value.bytes.each { |byte| destination << byte }
  end
  nil
end

def w143_assert_stock_rows(output : String, fixture : W143Fixture,
                           expected_values : Array(Array(CrystalClick::BinaryValue)), label : String) : Nil
  rows = output.lines.map(&.strip).reject(&.empty?)
  flattened = expected_values.flatten
  w143_assert(rows.size == flattened.size, "#{label}: stock row count #{rows.size} != authored #{flattened.size}")
  expected_type_hex = w143_hex(fixture.stock_type_name.to_slice)
  rows.each_with_index do |row, index|
    fields = row.split('\t')
    w143_assert(fields.size == 2, "#{label}: malformed stock TSVRaw row #{row.inspect}")
    w143_assert(fields[0].downcase == expected_type_hex.downcase,
      "#{label} row #{index}: stock toTypeName expected #{expected_type_hex}, got #{fields[0]}")
    payload = [] of UInt8
    w143_expected_row_binary(flattened[index], payload)
    expected_hex = w143_hex(w143_bytes_from_array(payload))
    w143_assert(fields[1].downcase == expected_hex.downcase,
      "#{label} row #{index}: RowBinary expected #{expected_hex}, got #{fields[1]}")
  end
end

def w143_store(output_root : String, label : String) : String
  path = File.join(output_root, "stores", label)
  w143_assert(!File.exists?(path) && !File.symlink?(path), "refusing to reuse W143 stock store: #{path}")
  Dir.mkdir(path)
  path
end

def w143_run_stock(binary : String, store : String, fixture : W143Fixture,
                   input_path : String) : Tuple(Bool, String, String)
  args = [
    "local", "--path", store,
    "--input-format", "Native",
    "--structure", "x #{fixture.native_type_name}",
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

def w143_stock_check(binary : String, output_root : String, fixture : W143Fixture,
                     streams : CrystalClick::BinaryBulkStreams,
                     profile : CrystalClick::BinaryBulkProfile,
                     expected_values : Array(Array(CrystalClick::BinaryValue)),
                     label : String) : Nil
  native = w143_native_input(fixture, streams, profile)
  input_path = File.join(output_root, "native-input", "#{label}.native")
  w143_write_bytes(input_path, native)
  store = w143_store(output_root, label)
  ok, output, error = w143_run_stock(binary, store, fixture, input_path)
  w143_write_text(File.join(output_root, "results", "#{label}.tsv"), output)
  w143_write_text(File.join(output_root, "results", "#{label}.stderr"), error)
  w143_assert(ok, "#{label}: pinned stock ClickHouse rejected adapted full-container Native body: #{error.strip}")
  w143_assert_stock_rows(output, fixture, expected_values, label)
  puts "PASS W143 complete recursive Native input -> stock consumer: #{label} rows=#{expected_values.sum(&.size)}"
end

def w143_mutated_streams(streams : CrystalClick::BinaryBulkStreams, role : String,
                         byte_offset : Int, replacement : UInt8) : CrystalClick::BinaryBulkStreams
  roles = Hash(String, CrystalClick::BinaryBulkStream).new
  streams.roles.each do |name|
    stream = streams.stream(name)
    bytes = stream.bytes
    if name == role
      w143_assert(byte_offset >= 0 && byte_offset < bytes.size, "negative-control mutation outside #{role}")
      bytes[byte_offset] = replacement
    end
    roles[name] = CrystalClick::BinaryBulkStream.new(bytes, stream.offsets)
  end
  CrystalClick::BinaryBulkStreams.new(mark_count: streams.mark_count, streams: roles)
end

def w143_expect_data_comparator(streams : CrystalClick::BinaryBulkStreams,
                                fixture : W143Fixture,
                                label : String,
                                profile : CrystalClick::BinaryBulkProfile) : Nil
  decoded = CrystalClick::BinaryBulkCodec.decode(fixture.type, streams, fixture.rows_per_mark, profile: profile)
  begin
    w143_assert_values(decoded, fixture.values_per_mark, label)
  rescue error : W143Mismatch
    puts "PASS W143 literal comparator rejects seeded data mutation: #{label}: #{error.message}"
    return
  end
  w143_fail("#{label}: data mutation unexpectedly matched authored full-container values")
end

def w143_expect_corrupt(type : CrystalClick::BinaryDataType,
                        streams : CrystalClick::BinaryBulkStreams,
                        row_counts : Array(UInt64), label : String,
                        profile : CrystalClick::BinaryBulkProfile) : Nil
  begin
    CrystalClick::BinaryBulkCodec.decode(type, streams, row_counts, profile: profile)
  rescue error : CrystalClick::CorruptPartError
    puts "PASS W143 structural comparator rejects seeded #{label}: #{error.message}"
    return
  end
  w143_fail("#{label}: malformed structural input was accepted")
end

def w143_negative_controls(fixture : W143Fixture,
                           streams : CrystalClick::BinaryBulkStreams) : Nil
  return unless fixture.label == "array-lc-string"

  # First LC ID is red (1); changing it to blue (2) remains a valid physical
  # record but must fail the independent full-value comparator.
  data_role = fixture.index_role
  mutated_data = w143_mutated_streams(streams, data_role, 16, 2_u8)
  w143_expect_data_comparator(mutated_data, fixture, "LC ID 1->2", CrystalClick::BinaryBulkProfile.single_stream)

  missing_roles = Hash(String, CrystalClick::BinaryBulkStream).new
  streams.roles.each do |role|
    missing_roles[role] = streams.stream(role) unless role == data_role
  end
  missing = CrystalClick::BinaryBulkStreams.new(mark_count: streams.mark_count, streams: missing_roles)
  w143_expect_corrupt(fixture.type, missing, fixture.rows_per_mark, "missing LC index role", CrystalClick::BinaryBulkProfile.single_stream)

  # Lower the first LC occurrence count while keeping the byte grid fixed;
  # the record's physical payload length must no longer match its header.
  bad_count = w143_mutated_streams(streams, data_role, 8, 4_u8)
  w143_expect_corrupt(fixture.type, bad_count, fixture.rows_per_mark,
    "LC occurrence count / index payload length mismatch", CrystalClick::BinaryBulkProfile.single_stream)

  # Change the first Array size from 2 to 1 without changing the LC schedule;
  # the recursive ancestor/flattened-count binding must reject the leftover ID.
  bad_sizes = w143_mutated_streams(streams, "root.sizes", 0, 1_u8)
  w143_expect_corrupt(fixture.type, bad_sizes, fixture.rows_per_mark, "ancestor size / flattened-count mismatch", CrystalClick::BinaryBulkProfile.single_stream)
end

def w143_empty_nested_selection : Nil
  string = CrystalClick::BinaryDataType.primitive("String")
  low = CrystalClick::BinaryDataType.low_cardinality(string)
  array_type = CrystalClick::BinaryDataType.array(low)
  empty = CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue)
  rows = [[empty], [empty, empty], [empty]] of Array(CrystalClick::BinaryValue)
  streams = CrystalClick::BinaryBulkCodec.encode(array_type, rows)
  w143_assert(streams.stream("root.elements.dictionary").bytes == w143_u64_bytes(1_u64),
    "all-empty nested marks must retain only the v1 LC prefix")
  w143_assert(streams.stream("root.elements.dictionary").offsets == [8_u64, 8_u64, 8_u64, 8_u64],
    "all-empty LC dictionary coordinates must remain at the prefix through EOF")
  w143_assert(streams.stream("root.elements.indexes").offsets == [0_u64, 0_u64, 0_u64, 0_u64],
    "all-empty LC indexes must preserve all zero-byte mark records")
  selected = CrystalClick::BinaryBulkCodec.decode(array_type, streams, [1_u64, 2_u64, 1_u64],
    first_mark: 1, mark_count: 1)
  w143_assert(selected.size == 1 && selected[0].size == 2, "selected empty nested mark lost its two parent rows")
  selected[0].each_with_index do |value, index|
    w143_assert(value.element_count == 0, "selected all-empty nested row #{index} was not empty")
  end
  puts "PASS W143 selected all-empty nested mark retains rows while LC index lane has zero bytes"
end

def w143_check_runtime(binary : String, output_root : String) : Nil
  version_out = IO::Memory.new
  version_status = Process.run(binary, ["local", "--version"], output: version_out, error: Process::Redirect::Close)
  w143_assert(version_status.success? && version_out.to_s.strip == W143_CLICKHOUSE_VERSION,
    "pinned W143 stock version differs")
  hash_out = IO::Memory.new
  hash_status = Process.run("shasum", ["-a", "256", binary], output: hash_out, error: Process::Redirect::Close)
  w143_assert(hash_status.success? && hash_out.to_s.split(' ').first? == W143_RUNTIME_SHA256,
    "pinned W143 stock executable SHA differs")
  identity_store = w143_store(output_root, "identity")
  identity = IO::Memory.new
  identity_status = Process.run(binary, ["local", "--path", identity_store,
                                         "--query", "SELECT concat(name, '=', value) FROM system.build_options WHERE name IN ('GIT_HASH', 'VERSION_GITHASH') ORDER BY name FORMAT TSVRaw"],
    output: identity, error: Process::Redirect::Close)
  expected = ["GIT_HASH=#{W143_BUILD_HASH}", "VERSION_GITHASH=#{W143_BUILD_HASH}"]
  actual = identity.to_s.lines.map(&.strip).reject(&.empty?)
  w143_assert(identity_status.success? && actual == expected,
    "pinned W143 stock build identity differs: #{actual.inspect}")
  puts "PASS W143 stock identity: source=#{W143_SOURCE_REVISION} version=#{W143_CLICKHOUSE_VERSION} sha256=#{W143_RUNTIME_SHA256} build=#{W143_BUILD_HASH}"
end

def w143_validate_roots : Tuple(String, String)
  probe_arg = ENV["W141_PROBE_ROOT"]? || w143_fail("W141_PROBE_ROOT is required")
  output_arg = ENV["W143_CHECK_ROOT"]? || w143_fail("W143_CHECK_ROOT is required")
  w143_assert(File.directory?(probe_arg) && !File.symlink?(probe_arg), "W141_PROBE_ROOT must be a retained non-symlink fixture")
  probe = File.realpath(probe_arg)
  w143_assert(probe.starts_with?("/private/tmp/crystal-click-object-low-cardinality-w141."), "W141 fixture root is outside its pinned evidence prefix")
  w143_assert(File.directory?(output_arg) && !File.symlink?(output_arg), "W143_CHECK_ROOT must be a fresh non-symlink output directory")
  output = File.realpath(output_arg)
  w143_assert(output.starts_with?("/private/tmp/crystal-click-object-low-cardinality-w143."), "W143 output root is outside its pinned prefix")
  %w(native-input lanes stores results crystal-cache).each do |child|
    path = File.join(output, child)
    w143_assert(File.directory?(path) && !File.symlink?(path), "W143 output child #{child} must be a direct non-symlink directory")
    if child != "crystal-cache"
      w143_assert(Dir.empty?(path), "W143 output child #{child} must be fresh and empty")
    end
  end
  record_path = File.join(probe, "results", "run.txt")
  w143_assert(File.file?(record_path) && !File.symlink?(record_path), "retained W141 run identity record is missing")
  record = File.read(record_path)
  w143_assert(record.lines.any? { |line| line.strip == "source_reference_revision=#{W143_SOURCE_REVISION}" }, "W141 source reference revision differs")
  w143_assert(record.lines.any? { |line| line.strip == "runtime_sha256=#{W143_RUNTIME_SHA256}" }, "W141 runtime SHA differs")
  w143_assert(record.lines.any? { |line| line.strip == "runtime_version=#{W143_CLICKHOUSE_VERSION}" }, "W141 runtime version differs")
  {probe, output}
end

def w143_write_lane_artifacts(output_root : String, fixture : W143Fixture,
                              encoded : CrystalClick::BinaryBulkStreams,
                              retained : CrystalClick::BinaryBulkStreams) : Nil
  fixture.physical_lanes.each do |lane|
    encoded_stream = encoded.stream(lane.role)
    retained_stream = retained.stream(lane.role)
    suffix = lane.role.gsub('.', '_')
    w143_write_bytes(File.join(output_root, "lanes", "#{fixture.label}.#{suffix}.codec.bin"), encoded_stream.bytes)
    w143_write_bytes(File.join(output_root, "lanes", "#{fixture.label}.#{suffix}.retained.bin"), retained_stream.bytes)
    w143_write_text(File.join(output_root, "results", "#{fixture.label}.#{suffix}.grid.txt"),
      "role=#{lane.role}\nsubstream=#{lane.substream}\nretained_basename=#{lane.basename}\ncodec_offsets=#{encoded_stream.offsets.inspect}\nretained_offsets=#{retained_stream.offsets.inspect}\n")
  end
end

def w143_main : Nil
  probe_root, output_root = w143_validate_roots
  binary = ENV["CLICKHOUSE_BIN"]? || w143_fail("CLICKHOUSE_BIN is required")
  w143_check_runtime(binary, output_root)
  record = [
    "fixture_root=#{probe_root}",
    "clickhouse_source_revision=#{W143_SOURCE_REVISION}",
    "clickhouse_build_hash=#{W143_BUILD_HASH}",
    "runtime_version=#{W143_CLICKHOUSE_VERSION}",
    "runtime_sha256=#{W143_RUNTIME_SHA256}",
    "claim_scope=authored_recursive_Array_Map_Tuple_LC_role_and_grid_match_to_retained_W141_decompressed_lanes_plus_stock_Native_consumer_after_explicit_representation_adapter",
    "excluded=Object_or_Dynamic_envelope_binding,ATTACH_or_complete_part_writer,direct_global_dictionary_Native_consumption,Map_WITH_BUCKETS,unretained_formats,compressed_frame_checksum_validation",
    "native_adapter=recursive_LC_v1_prefixes_then_container_body; per-row_Array_Map_sizes_to_cumulative_Native_offsets; WithSize_String_keys_to_varUInt_plus_bytes; global_LC_index_segments_to_one_additional-only_Native_record",
    "sources=NativeWriter.cpp:92-95; SerializationLowCardinality.cpp:271-288,534-627; SerializationArray.cpp:297-305,352-396; SerializationTuple.cpp:794-805,832-861; SerializationMap.cpp:756-765,1334-1345; SerializationInfoSettings.h:25",
    "retained_part_note=W141_Object_part_Object_structure_and_shared-data_sidecars_are_not_bound_or_claimed_by_this_ordinary-recursive_lane_oracle",
  ].join("\n") + "\n"
  w143_write_text(File.join(output_root, "results", "run.txt"), record)

  fixtures = w143_fixtures
  fixtures.each do |fixture|
    part, retained = w143_part_streams(probe_root, fixture)
    expected_roles = fixture.physical_lanes.map(&.role).sort
    rows = fixture.values_per_mark
    profile = fixture.label == "map-lc-string" ? CrystalClick::BinaryBulkProfile.with_size_stream : CrystalClick::BinaryBulkProfile.single_stream
    encoded = CrystalClick::BinaryBulkCodec.encode(fixture.type, rows, profile: profile)
    w143_assert(encoded.roles == expected_roles, "#{fixture.label}: codec role set includes or omits a physical role: #{encoded.roles.inspect}")
    w143_assert_streams_equal(encoded, retained, "#{fixture.label} codec vs literal W141 physical lanes")
    index_counts = w143_index_occurrences(encoded.stream(fixture.index_role), fixture.label)
    w143_assert(index_counts == fixture.expected_lc_occurrences_per_mark,
      "#{fixture.label}: LC occurrence schedule #{index_counts.inspect} != authored #{fixture.expected_lc_occurrences_per_mark.inspect}")
    decoded = CrystalClick::BinaryBulkCodec.decode(fixture.type, retained, fixture.rows_per_mark, profile: profile)
    w143_assert_values(decoded, fixture.values_per_mark, "#{fixture.label} retained W141 lanes")

    middle = CrystalClick::BinaryBulkCodec.decode(fixture.type, retained, fixture.rows_per_mark,
      first_mark: 1, mark_count: 1, profile: profile)
    w143_assert(middle.size == 1 && middle[0].size == 4, "#{fixture.label}: middle mark selection returned the wrong parent row count")
    w143_assert_values([middle[0]] of Array(CrystalClick::BinaryValue),
      [fixture.values_per_mark[1]] of Array(CrystalClick::BinaryValue), "#{fixture.label} selected middle mark")
    w143_write_lane_artifacts(output_root, fixture, encoded, retained)

    label = "stock-#{fixture.label}"
    w143_stock_check(binary, output_root, fixture, encoded, profile, fixture.values_per_mark, label)
    w143_negative_controls(fixture, encoded) if fixture.label == "array-lc-string"

    # SingleStream/WithSizeStream changes only ordinary String lanes. For
    # Array/LC and Tuple(LC, UInt32), nested LC dictionary keys stay in their
    # scalar varUInt stream and must not gain artificial string_sizes roles.
    if fixture.label == "array-lc-string" || fixture.label == "tuple-lc-string"
      alternate = fixture.label == "array-lc-string" ? CrystalClick::BinaryBulkProfile.with_size_stream : CrystalClick::BinaryBulkProfile.with_size_stream
      alternate_streams = CrystalClick::BinaryBulkCodec.encode(fixture.type, rows, profile: alternate)
      w143_assert_streams_equal(alternate_streams, retained, "#{fixture.label} alternate ordinary String profile")
      w143_stock_check(binary, output_root, fixture, alternate_streams, alternate, fixture.values_per_mark,
        "stock-#{fixture.label}-with-size-profile")
    elsif fixture.label == "map-lc-string"
      # W141 Map keys use the explicit WithSize ordinary String role. Also
      # consume a separately encoded SingleStream map to qualify the other
      # generic String profile through the same complete Native shape.
      alternate = CrystalClick::BinaryBulkProfile.single_stream
      alternate_streams = CrystalClick::BinaryBulkCodec.encode(fixture.type, rows, profile: alternate)
      w143_assert(!alternate_streams.has_role?("root.elements.field.0.string_sizes"),
        "single-stream Map keys unexpectedly exposed a String size role")
      w143_stock_check(binary, output_root, fixture, alternate_streams, alternate, fixture.values_per_mark,
        "stock-map-lc-string-single-profile")
    end

    puts "PASS W143 recursive lane witness: #{fixture.label} rows=#{fixture.rows_per_mark.inspect} lc_occurrences=#{index_counts.inspect} roles=#{expected_roles.inspect} part=#{part}"
  end

  w143_empty_nested_selection

  # Seeded stock-side control: the validly framed first LC ID changes from red
  # to blue. The full Native reader must consume it, and RowBinary must reveal
  # exactly one changed array item while every other authored row stays fixed.
  array_fixture = fixtures.first
  array_streams = CrystalClick::BinaryBulkCodec.encode(array_fixture.type, array_fixture.values_per_mark)
  changed = w143_mutated_streams(array_streams, array_fixture.index_role, 16, 2_u8)
  changed_values = array_fixture.values_per_mark.map(&.dup)
  changed_values[0][0] = w143_array_value(array_fixture.type, array_fixture.type.child_at(0), ["blue", "blue"])
  changed_decoded = CrystalClick::BinaryBulkCodec.decode(array_fixture.type, changed, array_fixture.rows_per_mark)
  w143_assert_values(changed_decoded, changed_values, "W143 expected valid mutated array value")
  w143_stock_check(binary, output_root, array_fixture, changed, CrystalClick::BinaryBulkProfile.single_stream,
    changed_values, "stock-array-lc-string-seeded-id-mutation")

  puts "PASS W143 bounded recursive LowCardinality oracle: 3 complete W141 container lane matches; selected middle marks; all-empty nested mark; both ordinary String profiles; 6 stock baseline/profile consumers plus valid wrong-output control. W141 Object sidecars and complete part interoperability remain excluded."
end

w143_main
