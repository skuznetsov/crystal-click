require "../src/crystal_click"
require "json"
require "digest/sha256"

# Independently reconcile the retained stock capture with library-authored
# descriptor and RowBinary bytes. Do not trust the probe's check booleans.
raise "usage: check_nested_binary_w172_source.cr MANIFEST" unless ARGV.size == 1
manifest = JSON.parse(File.read(ARGV[0]))
root = File.realpath(File.dirname(ARGV[0]))
pin = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
runtime = manifest["runtime"]
raise "runtime pin changed" unless runtime["sha256_before"].as_s == pin &&
                                   runtime["sha256_after"].as_s == pin &&
                                   Digest::SHA256.hexdigest(File.read(runtime["path"].as_s)) == pin
records = manifest["fixture"]["commands"].as_a
raise "unexpected command count" unless records.size == 9 && manifest["native_call_count"].as_i == 9
captures = Hash(String, JSON::Any).new
records.each do |record|
  status = record["status"]
  raise "native command failed" unless status["success"].as_bool && status["exitstatus"].as_i == 0 && status["termsig"].raw.nil?
  label = record["label"].as_s
  raise "duplicate capture label" if captures.has_key?(label)
  captures[label] = record
  record["files"].as_h.each do |kind, value|
    next if value.raw.nil?
    path = value.as_s
    raise "capture escapes run directory" unless File.realpath(path).starts_with?(root + "/commands/") && !File.symlink?(path)
    digest_key = kind == "argv" ? "argv_json" : kind
    bytes = File.read(path)
    raise "capture changed: #{label}/#{kind}" unless Digest::SHA256.hexdigest(bytes) == record["sha256"][digest_key].as_s
    if kind == "argv"
      raise "argv capture differs" unless JSON.parse(bytes) == record["argv"]
    elsif kind == "sql"
      raise "SQL capture differs" unless bytes == record["sql"].as_s && record["argv"].as_a.last.as_s == bytes
    end
  end
end

u64 = CrystalClick::BinaryDataType.primitive("UInt64")
text = CrystalClick::BinaryDataType.primitive("String")
i32 = CrystalClick::BinaryDataType.primitive("Int32")
nullable = CrystalClick::BinaryDataType.nullable(i32)
type = CrystalClick::BinaryDataType.nested([u64, text, nullable], ["a", "b", "c"])
tuple = type.child_at(0)
array_type = CrystalClick::BinaryDataType.array(tuple)
literal_nested = Bytes[0x2f, 3, 1, 0x61, 4, 1, 0x62, 0x15, 1, 0x63, 0x23, 9]
literal_array = Bytes[0x1e, 0x20, 3, 1, 0x61, 4, 1, 0x62, 0x15, 1, 0x63, 0x23, 9]
raise "wrong Nested descriptor" unless CrystalClick::BinaryDataTypeCodec.encode(type) == literal_nested
raise "wrong Array(Tuple) descriptor" unless CrystalClick::BinaryDataTypeCodec.encode(array_type) == literal_array
raise "lost Nested descriptor identity" unless CrystalClick::BinaryDataTypeCodec.decode(literal_nested) == type
raise "lost Array descriptor identity" unless CrystalClick::BinaryDataTypeCodec.decode(literal_array) == array_type
fixture = [
  [{11_u64, "north-0", nil}, {103_u64, "south", -17_i32}],
  [] of {UInt64, String, Int32?},
  [{211_u64, "tail", 31_i32}],
]
keys = [7_u64, 13_u64, 22_u64]
payload = IO::Memory.new
fixture.each_with_index do |records, row|
  children = records.map do |a, b, c|
    child = c.nil? ? nil : CrystalClick::BinaryValue.fixed(i32, Bytes.new(4) { |j| ((c.not_nil!.unsafe_as(UInt32) >> (8 * j)) & 255).to_u8 })
    CrystalClick::BinaryValue.tuple(tuple, [
      CrystalClick::BinaryValue.uint64(a), CrystalClick::BinaryValue.string(b),
      CrystalClick::BinaryValue.nullable(nullable, child),
    ])
  end
  nested_value = CrystalClick::BinaryValue.nested(type, children)
  array_value = CrystalClick::BinaryValue.array(array_type, children)
  bytes = CrystalClick::BinaryValueCodec.encode_value(nested_value)
  raise "carrier payload diverged" unless bytes == CrystalClick::BinaryValueCodec.encode_value(array_value)
  restored = CrystalClick::BinaryValueCodec.decode_value(type, bytes)
  raise "lost row identity" unless restored.type == type && restored.element_count == children.size
  records.each_with_index do |a_b_c, index|
    a, b, c = a_b_c
    record = restored.child_at(index)
    raise "wrong decoded record" unless record.type == tuple && record.child_at(0).as_uint64 == a && record.child_at(1).as_string == b
    number = record.child_at(2)
    raise "wrong decoded NULL" unless number.is_null? == c.nil?
    unless c.nil?
      raw = Bytes.new(4) { |j| ((c.not_nil!.unsafe_as(UInt32) >> (8 * j)) & 255).to_u8 }
      raise "wrong decoded signed carrier" unless number.child_at(0).bytes == raw
    end
  end
  payload.write(CrystalClick::BinaryValueCodec.encode_value(CrystalClick::BinaryValue.uint64(keys[row])))
  payload.write(bytes)
end
header_prefix = Bytes[2, 2, 0x70, 0x6b, 6, 0x6e, 0x65, 0x73, 0x74, 0x65, 0x64, 4]
nested_output = IO::Memory.new
nested_output.write(header_prefix)
nested_output.write(literal_nested)
nested_output.write(payload.to_slice)
array_output = IO::Memory.new
array_output.write(header_prefix)
array_output.write(literal_array)
array_output.write(payload.to_slice)
expected = {
  "nested-rowbinary-with-types"      => nested_output.to_slice,
  "nested-rowbinary-values"          => payload.to_slice,
  "array-tuple-rowbinary-with-types" => array_output.to_slice,
  "array-tuple-rowbinary-values"     => payload.to_slice,
  "reverse-rowbinary-with-types"     => nested_output.to_slice,
}
expected.each do |label, bytes|
  actual = File.read(captures[label]["files"]["stdout"].as_s).to_slice
  raise "native/library bytes differ: #{label}" unless actual == bytes
end
reverse = captures["insert-independent-binary"]["files"]["stdin"].as_s
raise "native input differs from library writer" unless File.read(reverse).to_slice == nested_output.to_slice
puts "W172 root reconciliation: 9 native statuses, 6 exact input/output buffers, 2 nominal descriptors passed"
