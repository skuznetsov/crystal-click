# W148 finite Variant bulk-lane and Native-consumer checker.
# It compares only two manually bound stock Wide fixtures. The normalized
# lanes are not a complete part format or a generic physical filename binder.
require "json"
require "../src/crystal_click"

W148_SOURCE_REVISION = "9007d227b64a3f8b667fc5258ceb2923f3cf477d"
W148_RUNTIME_SHA256  = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
W148_RUNTIME_VERSION = "26.10.1.1201"
W148_BUILD_HASH      = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
W148_ROOT_PREFIX     = "/private/tmp/crystal-click-w148."
W148_MAX_FILE        = 8 * 1024 * 1024

class W148Mismatch < Exception
end

struct W148Fixture
  getter label : String
  getter type : CrystalClick::BinaryDataType
  getter declared_type : String
  getter rows : Array(Array(CrystalClick::BinaryValue))
  getter profile : CrystalClick::BinaryBulkProfile

  def initialize(@label : String, @type : CrystalClick::BinaryDataType,
                 @declared_type : String,
                 @rows : Array(Array(CrystalClick::BinaryValue)),
                 @profile : CrystalClick::BinaryBulkProfile)
  end

  def rows_per_mark : Array(UInt64)
    rows.map { |mark| mark.size.to_u64 }
  end

  def flat_values : Array(CrystalClick::BinaryValue)
    rows.flatten
  end
end

def w148_fail(message : String) : NoReturn
  raise W148Mismatch.new(message)
end

def w148_assert(condition : Bool, message : String) : Nil
  w148_fail(message) unless condition
end

def w148_read_bytes(path : String, label : String) : Bytes
  w148_assert(File.file?(path) && !File.symlink?(path), "#{label}: missing regular file or symlink")
  size = File.size(path)
  w148_assert(size <= W148_MAX_FILE, "#{label}: file exceeds 8 MiB evidence bound")
  File.open(path, "rb") do |file|
    bytes = Bytes.new(size.to_i32)
    file.read_fully(bytes)
    bytes
  end
end

def w148_write_bytes(path : String, bytes : Bytes) : Nil
  w148_assert(!File.exists?(path) && !File.symlink?(path), "refusing to overwrite W148 output: #{path}")
  File.open(path, "wb") { |file| file.write(bytes) }
end

def w148_write_text(path : String, value : String) : Nil
  w148_write_bytes(path, value.to_slice)
end

def w148_bytes_from_array(values : Array(UInt8)) : Bytes
  Bytes.new(values.size) { |index| values[index] }
end

def w148_concat(values : Array(Bytes)) : Bytes
  total = values.sum(&.size)
  bytes = Bytes.new(total) { 0_u8 }
  offset = 0
  values.each do |value|
    value.each_with_index { |byte, index| bytes[offset + index] = byte }
    offset += value.size
  end
  bytes
end

def w148_u64(value : UInt64) : Bytes
  Bytes.new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

def w148_string_scalar(prefix : UInt8, value : String) : Bytes
  bytes = Array(UInt8).new(value.bytesize + 1, 0_u8)
  bytes[0] = prefix
  value.to_slice.each_with_index { |byte, index| bytes[index + 1] = byte }
  w148_bytes_from_array(bytes)
end

def w148_u64_at(bytes : Bytes, offset : Int, label : String) : UInt64
  w148_assert(offset >= 0 && offset <= bytes.size - 8, "#{label}: UInt64 read exceeds lane")
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

def w148_var_uint(value : UInt64, destination : Array(UInt8)) : Nil
  remaining = value
  while remaining >= 0x80_u64
    destination << ((remaining & 0x7f_u64).to_u8 | 0x80_u8)
    remaining >>= 7
  end
  destination << remaining.to_u8
end

def w148_native_string(value : String, destination : Array(UInt8)) : Nil
  w148_var_uint(value.bytesize.to_u64, destination)
  value.to_slice.each { |byte| destination << byte }
end

def w148_append_u64(value : UInt64, destination : Array(UInt8)) : Nil
  w148_u64(value).each { |byte| destination << byte }
end

def w148_hex(bytes : Bytes) : String
  String.build do |io|
    bytes.each { |byte| io << byte.to_s(16).rjust(2, '0').upcase }
  end
end

def w148_basic_fixture : W148Fixture
  string = CrystalClick::BinaryDataType.primitive("String")
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  type = CrystalClick::BinaryDataType.variant([uint64, string] of CrystalClick::BinaryDataType)
  w148_assert(type.children.map(&.name) == ["String", "UInt64"] of String,
    "basic witness does not use canonical String-before-UInt64 arm order")
  declared = "Variant(UInt64, String)"
  string_value = ->(value : String) {
    CrystalClick::BinaryValue.variant(type, 0, CrystalClick::BinaryValue.string(value))
  }
  uint_value = ->(value : UInt64) {
    CrystalClick::BinaryValue.variant(type, 1, CrystalClick::BinaryValue.uint64(value))
  }
  null_value = CrystalClick::BinaryValue.variant_null(type)
  rows = [
    [string_value.call("alpha"), uint_value.call(42_u64)],
    [string_value.call("omega"), null_value],
    [null_value, null_value],
  ] of Array(CrystalClick::BinaryValue)
  W148Fixture.new("basic", type, declared, rows, CrystalClick::BinaryBulkProfile.with_size_stream)
end

def w148_array_lc_fixture : W148Fixture
  string = CrystalClick::BinaryDataType.primitive("String")
  low = CrystalClick::BinaryDataType.low_cardinality(string)
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  variant = CrystalClick::BinaryDataType.variant([uint64, low] of CrystalClick::BinaryDataType)
  w148_assert(variant.children.map(&.name) == ["LowCardinality(String)", "UInt64"] of String,
    "Array witness does not use canonical LowCardinality-before-UInt64 arm order")
  array = CrystalClick::BinaryDataType.array(variant)
  declared = "Array(Variant(UInt64, LowCardinality(String)))"
  lc_value = ->(value : String) {
    child = CrystalClick::BinaryValue.low_cardinality(low, CrystalClick::BinaryValue.string(value))
    CrystalClick::BinaryValue.variant(variant, 0, child)
  }
  uint_value = ->(value : UInt64) {
    CrystalClick::BinaryValue.variant(variant, 1, CrystalClick::BinaryValue.uint64(value))
  }
  array_value = ->(values : Array(CrystalClick::BinaryValue)) {
    CrystalClick::BinaryValue.array(array, values)
  }
  rows = [
    [array_value.call([lc_value.call("red"), uint_value.call(42_u64)] of CrystalClick::BinaryValue),
     array_value.call([uint_value.call(7_u64)] of CrystalClick::BinaryValue)],
    [array_value.call([lc_value.call("blue"), uint_value.call(9_u64), lc_value.call("red")] of CrystalClick::BinaryValue),
     array_value.call([lc_value.call("green")] of CrystalClick::BinaryValue)],
    [array_value.call([] of CrystalClick::BinaryValue), array_value.call([] of CrystalClick::BinaryValue)],
  ] of Array(CrystalClick::BinaryValue)
  W148Fixture.new("array_lc", array, declared, rows, CrystalClick::BinaryBulkProfile.with_size_stream)
end

def w148_fixture(label : String, profile_name : String) : W148Fixture
  profile = case profile_name
            when "with_size_stream" then CrystalClick::BinaryBulkProfile.with_size_stream
            when "single_stream"    then CrystalClick::BinaryBulkProfile.single_stream
            else                         w148_fail("#{label}: unsupported authored String profile #{profile_name.inspect}")
            end
  fixture = label == "basic" ? w148_basic_fixture : label == "array_lc" ? w148_array_lc_fixture : w148_fail("unknown W148 fixture #{label.inspect}")
  W148Fixture.new(fixture.label, fixture.type, fixture.declared_type, fixture.rows, profile)
end

def w148_assert_value(actual : CrystalClick::BinaryValue,
                      expected : CrystalClick::BinaryValue,
                      label : String) : Nil
  w148_assert(actual.type == expected.type, "#{label}: nominal descriptor differs: #{actual.type.name} != #{expected.type.name}")
  w148_assert(actual.is_null? == expected.is_null?, "#{label}: NULL state differs")
  if actual.type.tag == CrystalClick::BinaryDataType::TAG_VARIANT
    actual_index = actual.variant_index?
    expected_index = expected.variant_index?
    w148_assert(actual_index == expected_index, "#{label}: Variant discriminator differs: #{actual_index.inspect} != #{expected_index.inspect}")
    actual_child = actual.variant_child?
    expected_child = expected.variant_child?
    w148_assert(actual_child.nil? == expected_child.nil?, "#{label}: Variant child presence differs")
    if actual.is_null?
      w148_assert(actual_index.nil? && expected_index.nil? && actual_child.nil? && expected_child.nil?,
        "#{label}: Variant NULL must have neither an arm index nor child")
      return
    end
    w148_assert(!actual_index.nil? && !expected_index.nil?, "#{label}: selected Variant has no discriminator")
    w148_assert(!actual_child.nil? && !expected_child.nil?, "#{label}: selected Variant has no child")
    w148_assert_value(actual_child.not_nil!, expected_child.not_nil!, "#{label}.arm[#{actual_index.not_nil!}]")
    return
  end

  return if actual.is_null?
  case actual.type.tag
  when CrystalClick::BinaryDataType::TAG_ARRAY,
       CrystalClick::BinaryDataType::TAG_MAP,
       CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE,
       CrystalClick::BinaryDataType::TAG_NAMED_TUPLE,
       CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY,
       CrystalClick::BinaryDataType::TAG_NULLABLE
    w148_assert(actual.element_count == expected.element_count,
      "#{label}: child count differs: #{actual.element_count} != #{expected.element_count}")
    actual.element_count.times do |index|
      w148_assert_value(actual.element_at(index), expected.element_at(index), "#{label}[#{index}]")
    end
  else
    w148_assert(actual.bytes == expected.bytes,
      "#{label}: exact scalar bytes differ: #{w148_hex(actual.bytes)} != #{w148_hex(expected.bytes)}")
  end
  nil
end

def w148_assert_rows(actual : Array(Array(CrystalClick::BinaryValue)),
                     expected : Array(Array(CrystalClick::BinaryValue)), label : String) : Nil
  w148_assert(actual.size == expected.size, "#{label}: mark count differs")
  actual.each_with_index do |mark, mark_index|
    expected_mark = expected[mark_index]
    w148_assert(mark.size == expected_mark.size, "#{label} mark #{mark_index}: row count differs")
    mark.each_with_index do |value, row_index|
      w148_assert_value(value, expected_mark[row_index], "#{label} mark #{mark_index} row #{row_index}")
    end
  end
  nil
end

def w148_streams_equal(actual : CrystalClick::BinaryBulkStreams,
                       expected : CrystalClick::BinaryBulkStreams, label : String) : Nil
  w148_assert(actual.mark_count == expected.mark_count, "#{label}: mark count differs")
  w148_assert(actual.roles == expected.roles, "#{label}: exact role set differs: #{actual.roles.inspect} != #{expected.roles.inspect}")
  actual.roles.each do |role|
    left = actual.stream(role)
    right = expected.stream(role)
    w148_assert(left.offsets == right.offsets,
      "#{label} #{role}: K+1 offset grid differs: #{left.offsets.inspect} != #{right.offsets.inspect}")
    # The finite stock LC consumer is checked below by decoding its actual
    # lanes to independent values. Dictionary ordering and LC flags are a
    # separate profile, so do not elevate their byte equality into a claim.
    unless role.ends_with?(".dictionary") || role.ends_with?(".indexes")
      w148_assert(left.bytes == right.bytes,
        "#{label} #{role}: bytes differ: #{w148_hex(left.bytes)} != #{w148_hex(right.bytes)}")
    end
  end
  nil
end

def w148_manifest_streams(root : String, label : String) : Tuple(CrystalClick::BinaryBulkStreams, JSON::Any)
  manifest_path = File.join(root, "inputs", label, "manifest.json")
  manifest = JSON.parse(String.new(w148_read_bytes(manifest_path, "#{label} manifest")))
  w148_assert(manifest["label"].as_s == label, "#{label}: manifest label differs")
  lanes = manifest["lanes"].as_a
  stream_map = Hash(String, CrystalClick::BinaryBulkStream).new
  lanes.each do |lane|
    role = lane["role"].as_s
    next if role == "transport.variant_prefix"
    relative = lane["bytes_file"].as_s
    w148_assert(relative.starts_with?("lane-") && !relative.includes?('/') && !relative.includes?(".."),
      "#{label} #{role}: manifest lane path escaped its input directory")
    bytes = w148_read_bytes(File.join(root, "inputs", label, relative), "#{label} #{role}")
    offsets = lane["normalized_offsets"].as_a.map { |value| value.as_i64.to_u64 }
    w148_assert(!stream_map.has_key?(role), "#{label}: duplicate normalized role #{role}")
    stream_map[role] = CrystalClick::BinaryBulkStream.new(bytes, offsets)
  end
  mark_count = manifest["mark_count"].as_i64.to_i
  {CrystalClick::BinaryBulkStreams.new(mark_count: mark_count, streams: stream_map), manifest}
end

def w148_assert_literal_lane_witness(fixture : W148Fixture,
                                     streams : CrystalClick::BinaryBulkStreams) : Nil
  if fixture.label == "basic"
    w148_assert(streams.stream("root.discriminators").bytes == Bytes[0_u8, 1_u8, 0_u8, 0xff_u8, 0xff_u8, 0xff_u8],
      "basic literal discriminator lane differs")
    w148_assert(streams.stream("root.discriminators").offsets == [0_u64, 2_u64, 4_u64, 6_u64],
      "basic literal discriminator K+1 grid differs")
    w148_assert(streams.stream("root.arm.1.data").bytes == w148_u64(42_u64),
      "basic literal sparse UInt64 arm differs")
    if fixture.profile.with_size_stream?
      w148_assert(streams.stream("root.arm.0.data").bytes == "alphaomega".to_slice,
        "basic WithSize literal String bytes differ")
      w148_assert(streams.stream("root.arm.0.string_sizes").bytes == w148_concat([w148_u64(5_u64), w148_u64(5_u64)] of Bytes),
        "basic WithSize literal String sizes differ")
      w148_assert(streams.stream("root.arm.0.string_sizes").offsets == [0_u64, 8_u64, 16_u64, 16_u64],
        "basic WithSize String-size K+1 grid differs")
    else
      expected = [5_u8] of UInt8
      "alpha".to_slice.each { |byte| expected << byte }
      expected << 5_u8
      "omega".to_slice.each { |byte| expected << byte }
      w148_assert(streams.stream("root.arm.0.data").bytes == w148_bytes_from_array(expected),
        "basic SingleStream literal String bytes differ")
    end
  else
    w148_assert(streams.stream("root.sizes").bytes == w148_concat([2_u64, 1_u64, 3_u64, 1_u64, 0_u64, 0_u64].map { |value| w148_u64(value) }),
      "Array literal sizes lane differs")
    w148_assert(streams.stream("root.sizes").offsets == [0_u64, 16_u64, 32_u64, 48_u64],
      "Array literal parent K+1 grid differs")
    w148_assert(streams.stream("root.elements.discriminators").bytes == Bytes[0_u8, 1_u8, 1_u8, 0_u8, 1_u8, 0_u8, 0_u8],
      "Array literal child discriminator lane differs")
    w148_assert(streams.stream("root.elements.discriminators").offsets == [0_u64, 3_u64, 7_u64, 7_u64],
      "Array flattened-child discriminator K+1 grid differs")
    dictionary = w148_concat([
      w148_u64(1_u64), w148_u64(4_u64), Bytes[0_u8],
      w148_string_scalar(3_u8, "red"), w148_string_scalar(4_u8, "blue"),
      w148_string_scalar(5_u8, "green"),
    ] of Bytes)
    w148_assert(streams.stream("root.elements.arm.0.dictionary").bytes == dictionary,
      "Array literal LC dictionary differs")
    expected_indexes = w148_concat([
      w148_u64(0x500_u64), w148_u64(1_u64), Bytes[1_u8],
      w148_u64(0x100_u64), w148_u64(3_u64), Bytes[2_u8, 1_u8, 3_u8],
    ] of Bytes)
    w148_assert(streams.stream("root.elements.arm.0.indexes").bytes == expected_indexes,
      "Array literal LC index records differ")
    w148_assert(streams.stream("root.elements.arm.0.indexes").offsets == [0_u64, 17_u64, 36_u64, 36_u64],
      "Array LC occurrence-index K+1 grid differs")
  end
  nil
end

def w148_check_prefix_evidence(root : String, manifest : JSON::Any, label : String) : Nil
  transport = manifest["prefix_transport"].as_s
  if transport == "separate"
    file = manifest["lanes"].as_a.find { |lane| lane["role"].as_s == "transport.variant_prefix" }
    w148_assert(!file.nil?, "#{label}: separate prefix transport has no manifest record")
    artifact = file.not_nil!["bytes_artifact"].as_s
    w148_assert(artifact == "variant-prefix.bin", "#{label}: unexpected separate prefix artifact name")
    bytes = w148_read_bytes(File.join(root, "results", "stock-#{label}", artifact), "#{label} separate prefix")
    w148_assert(bytes == w148_u64(0_u64), "#{label}: separate Variant prefix is not BASIC u64 zero")
  elsif transport == "combined"
    hex = manifest["combined_variant_prefix_hex"].as_s
    w148_assert(hex == "0000000000000000", "#{label}: combined Variant prefix is not BASIC u64 zero")
  else
    w148_fail("#{label}: Variant BASIC prefix transport was not observed")
  end
  nil
end

def w148_native_prefix(type : CrystalClick::BinaryDataType, path : String,
                       destination : Array(UInt8)) : Nil
  case type.tag
  when CrystalClick::BinaryDataType::TAG_VARIANT
    # Native BASIC mode is transport framing, not a row discriminator.
    w148_append_u64(0_u64, destination)
    type.child_count.times do |index|
      w148_native_prefix(type.child_at(index), "#{path}.arm.#{index}", destination)
    end
  when CrystalClick::BinaryDataType::TAG_ARRAY
    w148_native_prefix(type.child_at(0), "#{path}.elements", destination)
  when CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY
    # ClickHouse Native LowCardinality v1 prefix; emitted even when that arm
    # has no occurrences in the body.
    w148_append_u64(1_u64, destination)
  end
  nil
end

def w148_append_native_lc(path : String, expected_count : UInt64,
                          streams : CrystalClick::BinaryBulkStreams,
                          destination : Array(UInt8)) : Nil
  dictionary = streams.stream("#{path}.dictionary")
  indexes = streams.stream("#{path}.indexes")
  dict_bytes = dictionary.bytes
  index_bytes = indexes.bytes
  w148_assert(dict_bytes.size >= 8 && w148_u64_at(dict_bytes, 0, "#{path} version") == 1_u64,
    "#{path}: library LC lane is missing its v1 prefix")
  if expected_count == 0_u64
    w148_assert(dict_bytes.size == 8 && index_bytes.empty?,
      "#{path}: inactive LC arm must contain only the v1 prefix and no index body")
    return
  end
  w148_assert(dictionary.offset_at(0) == 8_u64 && dict_bytes.size >= 16,
    "#{path}: active LC arm lacks its global dictionary record")
  width_code : UInt64? = nil
  ids = [] of UInt8
  found = 0_u64
  indexes.mark_count.times do |mark|
    start = indexes.offset_at(mark).to_i
    finish = indexes.offset_at(mark + 1).to_i
    next if start == finish
    w148_assert(finish - start >= 16, "#{path} mark #{mark}: truncated index record")
    flags = w148_u64_at(index_bytes, start, "#{path} mark #{mark} flags")
    count = w148_u64_at(index_bytes, start + 8, "#{path} mark #{mark} count")
    width = flags & 0xff_u64
    w148_assert(width <= 3_u64 && (flags & 0x100_u64) != 0_u64 && (flags & 0x200_u64) == 0_u64,
      "#{path} mark #{mark}: unexpected shared LC index flags")
    w148_assert((flags & ~0x703_u64) == 0_u64, "#{path} mark #{mark}: LC flags exceed known mask")
    if current = width_code
      w148_assert(current == width, "#{path}: LC index width changed across marks")
    else
      width_code = width
    end
    width_bytes = 1 << width.to_i
    expected_size = 16 + (count * width_bytes.to_u64).to_i
    w148_assert(finish - start == expected_size, "#{path} mark #{mark}: LC count and index payload size differ")
    count.to_i.times do |index|
      width_bytes.times do |byte|
        ids << index_bytes[start + 16 + index * width_bytes + byte]
      end
    end
    found += count
  end
  w148_assert(found == expected_count, "#{path}: LC IDs #{found} != Variant-selected occurrences #{expected_count}")
  width = width_code || w148_fail("#{path}: nonempty LC arm has no index record")
  # Convert the normalized W142 global-only dictionary/index lanes to one
  # Native additional-key record. This is a finite consumer adapter; it is not
  # a physical part writer and does not claim arbitrary dictionary profiles.
  w148_append_u64(0x600_u64 | width, destination)
  dict_bytes[8, dict_bytes.size - 8].each { |byte| destination << byte }
  w148_append_u64(found, destination)
  ids.each { |byte| destination << byte }
  nil
end

def w148_append_native_body(type : CrystalClick::BinaryDataType, path : String,
                            occurrence_count : UInt64,
                            streams : CrystalClick::BinaryBulkStreams,
                            profile : CrystalClick::BinaryBulkProfile,
                            destination : Array(UInt8)) : Nil
  case type.tag
  when CrystalClick::BinaryDataType::TAG_ARRAY
    sizes = streams.stream("#{path}.sizes")
    w148_assert(sizes.bytes.size == occurrence_count.to_i * 8, "#{path}: Array size lane count differs")
    cumulative = 0_u64
    occurrence_count.to_i.times do |index|
      cumulative += w148_u64_at(sizes.bytes, index * 8, "#{path} size #{index}")
      w148_append_u64(cumulative, destination)
    end
    w148_append_native_body(type.child_at(0), "#{path}.elements", cumulative, streams, profile, destination)
  when CrystalClick::BinaryDataType::TAG_VARIANT
    discriminators = streams.stream("#{path}.discriminators").bytes
    w148_assert(discriminators.size.to_u64 == occurrence_count,
      "#{path}: Variant discriminator count differs from selected parent occurrences")
    counts = Array(UInt64).new(type.child_count, 0_u64)
    discriminators.each do |tag|
      next if tag == 0xff_u8
      w148_assert(tag.to_i < type.child_count, "#{path}: invalid Native Variant discriminator #{tag}")
      counts[tag.to_i] += 1_u64
    end
    discriminators.each { |byte| destination << byte }
    type.child_count.times do |index|
      w148_append_native_body(type.child_at(index), "#{path}.arm.#{index}", counts[index], streams, profile, destination)
    end
  when CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY
    w148_append_native_lc(path, occurrence_count, streams, destination)
  when CrystalClick::BinaryDataType::TAG_STRING
    data = streams.stream("#{path}.data").bytes
    if profile.with_size_stream?
      sizes = streams.stream("#{path}.string_sizes")
      w148_assert(sizes.bytes.size == occurrence_count.to_i * 8, "#{path}: WithSize string count differs")
      data_offset = 0
      occurrence_count.to_i.times do |index|
        size = w148_u64_at(sizes.bytes, index * 8, "#{path} String size #{index}")
        w148_assert(size <= Int32::MAX.to_u64, "#{path}: String exceeds adapter domain")
        w148_var_uint(size, destination)
        w148_assert(data_offset <= data.size - size.to_i, "#{path}: String size exceeds data lane")
        size.to_i.times { |byte| destination << data[data_offset + byte] }
        data_offset += size.to_i
      end
      w148_assert(data_offset == data.size, "#{path}: unconsumed String bytes")
    else
      data.each { |byte| destination << byte }
    end
  when CrystalClick::BinaryDataType::TAG_UINT64
    data = streams.stream("#{path}.data").bytes
    w148_assert(data.size.to_u64 == occurrence_count * 8_u64, "#{path}: UInt64 arm byte count differs")
    data.each { |byte| destination << byte }
  else
    w148_fail("Native adapter does not support finite W148 type #{type.name}")
  end
  nil
end

def w148_native_payload(fixture : W148Fixture,
                        streams : CrystalClick::BinaryBulkStreams) : Bytes
  rows = fixture.rows_per_mark.sum
  destination = [] of UInt8
  w148_var_uint(1_u64, destination)
  w148_var_uint(rows, destination)
  w148_native_string("x", destination)
  w148_native_string(fixture.type.name, destination)
  w148_native_prefix(fixture.type, "root", destination)
  w148_append_native_body(fixture.type, "root", rows, streams, fixture.profile, destination)
  w148_bytes_from_array(destination)
end

def w148_row_binary(value : CrystalClick::BinaryValue,
                    destination : Array(UInt8)) : Nil
  type = value.type
  case type.tag
  when CrystalClick::BinaryDataType::TAG_VARIANT
    if index = value.variant_index?
      destination << index
      child = value.variant_child? || w148_fail("expected literal Variant child")
      w148_row_binary(child, destination)
    else
      destination << 0xff_u8
    end
  when CrystalClick::BinaryDataType::TAG_ARRAY
    w148_var_uint(value.element_count.to_u64, destination)
    value.elements.each { |child| w148_row_binary(child, destination) }
  when CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY
    w148_row_binary(value.child_at(0), destination)
  when CrystalClick::BinaryDataType::TAG_STRING
    payload = value.bytes
    w148_var_uint(payload.size.to_u64, destination)
    payload.each { |byte| destination << byte }
  else
    value.bytes.each { |byte| destination << byte }
  end
  nil
end

def w148_expected_native_tsv(fixture : W148Fixture,
                             rows : Array(Array(CrystalClick::BinaryValue)) = fixture.rows) : String
  type_hex = w148_hex(fixture.type.name.to_slice)
  String.build do |io|
    rows.flatten.each do |value|
      payload = [] of UInt8
      w148_row_binary(value, payload)
      io << type_hex << '\t' << w148_hex(w148_bytes_from_array(payload)) << '\n'
    end
  end
end

def w148_mutated_streams(streams : CrystalClick::BinaryBulkStreams,
                         role : String, byte_offset : Int, replacement : UInt8) : CrystalClick::BinaryBulkStreams
  roles = Hash(String, CrystalClick::BinaryBulkStream).new
  streams.roles.each do |name|
    stream = streams.stream(name)
    bytes = stream.bytes
    if name == role
      w148_assert(byte_offset >= 0 && byte_offset < bytes.size, "mutation is outside #{role}")
      bytes[byte_offset] = replacement
    end
    roles[name] = CrystalClick::BinaryBulkStream.new(bytes, stream.offsets)
  end
  w148_assert(roles.has_key?(role), "mutation target #{role} does not exist")
  CrystalClick::BinaryBulkStreams.new(mark_count: streams.mark_count, streams: roles)
end

def w148_expect_original_rejected(actual : Array(Array(CrystalClick::BinaryValue)),
                                  expected : Array(Array(CrystalClick::BinaryValue))) : Nil
  begin
    w148_assert_rows(actual, expected, "valid wrong-value mutation versus original literal")
  rescue error : W148Mismatch
    return
  end
  w148_fail("valid wrong-value mutation unexpectedly matched original literal")
end

def w148_library_artifacts(root : String, fixture : W148Fixture,
                           streams : CrystalClick::BinaryBulkStreams,
                           expected_tsv : String, native_name : String,
                           artifact_key : String) : Nil
  lane_root = File.join(root, "lanes")
  fixture_dir = File.join(lane_root, artifact_key)
  Dir.mkdir(fixture_dir, 0o700)
  streams.roles.each do |role|
    suffix = role.gsub('.', '_')
    stream = streams.stream(role)
    w148_write_bytes(File.join(fixture_dir, "#{suffix}.bin"), stream.bytes)
    w148_write_text(File.join(fixture_dir, "#{suffix}.grid.txt"),
      "role=#{role}\noffsets=#{stream.offsets.inspect}\nbytes_hex=#{w148_hex(stream.bytes)}\n")
  end
  native = w148_native_payload(fixture, streams)
  w148_write_bytes(File.join(root, "native-input", native_name), native)
  w148_write_text(File.join(root, "results", "exchange", "expected-#{native_name.sub(".native", ".tsv")}"), expected_tsv)
  nil
end

def w148_check_fixture(root : String, label : String) : Tuple(W148Fixture, CrystalClick::BinaryBulkStreams)
  stock, manifest = w148_manifest_streams(root, label)
  profile_name = manifest["logical_profile"].as_s
  fixture = w148_fixture(label, profile_name)
  w148_assert(manifest["canonical_type"].as_s == fixture.type.name,
    "#{label}: stock canonical type differs: #{manifest["canonical_type"].as_s.inspect} != #{fixture.type.name.inspect}")
  w148_assert(manifest["declared_type"].as_s == fixture.declared_type,
    "#{label}: reversed stock declaration witness differs")
  rows_per_mark = manifest["rows_per_mark"].as_a.map { |value| value.as_i64.to_u64 }
  w148_assert(rows_per_mark == fixture.rows_per_mark, "#{label}: independently observed row grid differs")
  w148_assert(manifest["mark_count"].as_i64.to_i == fixture.rows.size,
    "#{label}: stock mark count differs from authored literal marks")
  w148_check_prefix_evidence(root, manifest, label)

  encoded = CrystalClick::BinaryBulkCodec.encode(fixture.type, fixture.rows, profile: fixture.profile)
  w148_streams_equal(stock, encoded, "#{label} stock normalized lanes vs library encoder")
  w148_assert_literal_lane_witness(fixture, encoded)
  decoded = CrystalClick::BinaryBulkCodec.decode(fixture.type, stock, rows_per_mark, profile: fixture.profile)
  w148_assert_rows(decoded, fixture.rows, "#{label} stock normalized lane decoder")
  middle = CrystalClick::BinaryBulkCodec.decode(fixture.type, stock, rows_per_mark,
    first_mark: 1, mark_count: 1, profile: fixture.profile)
  w148_assert_rows(middle, [fixture.rows[1]] of Array(CrystalClick::BinaryValue), "#{label} selected middle mark")
  empty_mark = CrystalClick::BinaryBulkCodec.decode(fixture.type, stock, rows_per_mark,
    first_mark: 2, mark_count: 1, profile: fixture.profile)
  w148_assert_rows(empty_mark, [fixture.rows[2]] of Array(CrystalClick::BinaryValue), "#{label} selected empty/NULL mark")

  expected = w148_expected_native_tsv(fixture)
  native_name = "library-#{label}.native"
  w148_library_artifacts(root, fixture, encoded, expected, native_name, label)
  puts "PASS W148 finite stock/library lane match: #{label} roles=#{encoded.roles.size} marks=#{encoded.mark_count}"
  {fixture, encoded}
end

def w148_exchange(root : String) : Nil
  w148_assert(root.starts_with?(W148_ROOT_PREFIX) && File.expand_path(root) == root,
    "W148 exchange root must be an absolute direct namespace child of #{W148_ROOT_PREFIX}")
  w148_assert(File.directory?(root) && !File.symlink?(root) && File.realpath(root) == root,
    "W148 exchange root must be a canonical non-symlink directory")
  discovery = File.join(root, "results", "discovery.txt")
  w148_assert(File.file?(discovery) && !File.symlink?(discovery), "W148 stock discovery record is required")
  record = String.new(w148_read_bytes(discovery, "discovery identity"))
  w148_assert(record.includes?("source_reference_revision=#{W148_SOURCE_REVISION}"), "W148 source revision pin differs")
  w148_assert(record.includes?("runtime_sha256=#{W148_RUNTIME_SHA256}"), "W148 runtime SHA pin differs")
  w148_assert(record.includes?("runtime_version=#{W148_RUNTIME_VERSION}"), "W148 runtime version pin differs")
  w148_assert(record.includes?("GIT_HASH=#{W148_BUILD_HASH}"), "W148 runtime build hash pin differs")
  %w(lanes native-input).each do |name|
    path = File.join(root, name)
    w148_assert(!File.exists?(path) && !File.symlink?(path), "refusing existing W148 exchange directory #{path}")
    Dir.mkdir(path, 0o700)
  end
  results = File.join(root, "results", "exchange")
  # Ruby owns the parent exchange directory and its source/runtime capture;
  # the checker writes only fresh child artifact directories/files here.
  w148_assert(File.directory?(results) && !File.symlink?(results),
    "Ruby-created W148 exchange result directory is missing or symlinked")

  basic_fixture, basic_streams = w148_check_fixture(root, "basic")
  array_fixture, array_streams = w148_check_fixture(root, "array_lc")

  # Valid-value negative control: the UInt64 payload remains structurally valid
  # but changes 42 to 43. The decoder must accept it, the original literal
  # comparator must reject it, and the independent mutant literal must match.
  changed = w148_mutated_streams(basic_streams, "root.arm.1.data", 0, 43_u8)
  changed_values = w148_basic_fixture.rows.map(&.dup)
  changed_value = CrystalClick::BinaryValue.variant(basic_fixture.type, 1, CrystalClick::BinaryValue.uint64(43_u64))
  changed_values[0][1] = changed_value
  changed_decoded = CrystalClick::BinaryBulkCodec.decode(basic_fixture.type, changed,
    basic_fixture.rows_per_mark, profile: basic_fixture.profile)
  w148_expect_original_rejected(changed_decoded, basic_fixture.rows)
  w148_assert_rows(changed_decoded, changed_values, "valid UInt64 42->43 mutant literal")
  mutant_expected = w148_expected_native_tsv(basic_fixture, changed_values)
  original_expected = w148_expected_native_tsv(basic_fixture)
  w148_assert(mutant_expected != original_expected, "valid wrong-value control did not change native TSV literal")
  w148_library_artifacts(root, basic_fixture, changed, mutant_expected,
    "library-basic-mutant.native", "basic-mutant")

  w148_write_text(File.join(results, "library-checker.txt"), [
    "status=library-logical-lane-and-native-payloads-emitted",
    "source_reference_revision=#{W148_SOURCE_REVISION}", "runtime_version=#{W148_RUNTIME_VERSION}",
    "runtime_sha256=#{W148_RUNTIME_SHA256}", "runtime_build_hash=#{W148_BUILD_HASH}",
    "types=#{basic_fixture.type.name};#{array_fixture.type.name}",
    "native_payloads=library-basic.native,library-array_lc.native,library-basic-mutant.native",
    "lc_equality=stock LC dictionary/index bytes are not asserted identical; role sets and K+1 grids compare, and stock decode must match exact independent values",
    "control=UInt64 42->43 is structurally valid, rejected against original literal, matched against explicit mutant literal",
    "scope=two finite stock Wide normalized-lane fixtures and library Native-consumer payloads; not complete part writer or generic binder",
  ].join("\n") + "\n")
  puts "PASS W148 library encoding/decoding, stock lane comparison, Native payload adaptation, and valid wrong-value control"
end

def w148_main : Nil
  args = ARGV
  unless args.size == 2 && args[0] == "exchange"
    w148_fail("usage: check_variant_bulk_w148.cr exchange /absolute/private/tmp/crystal-click-w148.ROOT")
  end
  w148_exchange(args[1])
end

w148_main
