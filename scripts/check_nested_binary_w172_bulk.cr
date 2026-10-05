require "../src/crystal_click"
require "json"
require "digest/sha256"

# Compare the logical Nested bulk codec to a retained stock-created W171 part.
# The fixture is authored here independently of either codec's output.
raise "usage: check_nested_binary_w172_bulk.cr STOCK_SOURCE_MANIFEST" unless ARGV.size == 1
manifest = JSON.parse(File.read(ARGV[0]))
pin = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
raise "stock pin changed" unless manifest["clickhouse_binary_sha256_before"].as_s == pin &&
                                 manifest["clickhouse_binary_sha256_after"].as_s == pin &&
                                 Digest::SHA256.hexdigest(File.read(manifest["clickhouse_binary"].as_s)) == pin
profile = manifest["profiles"].as_a.find { |item| item["label"].as_s == "nested-flat0" }.not_nil!
part = File.realpath(profile["part_path"].as_s)
run_root = File.realpath(manifest["run_root"].as_s)
raise "part escapes retained capture" unless part.starts_with?(run_root + "/stores/nested-flat0/")
profile["part_roster"].as_a.each do |entry|
  next unless entry["kind"].as_s == "file"
  file = File.join(part, entry["name"].as_s)
  raise "symlinked stock input" if File.symlink?(file)
  raise "stock input changed" unless Digest::SHA256.hexdigest(File.read(file)) == entry["sha256"].as_s
end

u64 = CrystalClick::BinaryDataType.primitive("UInt64")
text = CrystalClick::BinaryDataType.primitive("String")
i32 = CrystalClick::BinaryDataType.primitive("Int32")
nullable = CrystalClick::BinaryDataType.nullable(i32)
type = CrystalClick::BinaryDataType.nested([u64, text, nullable], ["a", "b", "c"])
tuple = type.child_at(0)
fixture = [
  [{11_u64, "r0-A", nil}, {103_u64, "r0-B", -17_i32}],
  [] of {UInt64, String, Int32?},
  [{211_u64, "mid-x", 31_i32}],
  [{307_u64, "r3-A", 0_i32}, {310_u64, "r3-B", 32_i32}, {311_u64, "r3-C", nil}],
  [{409_u64, "last-A", -41_i32}, {419_u64, "last-B", 41_i32}],
]
values = fixture.map do |records|
  children = records.map do |a, b, c|
    child = c.nil? ? nil : CrystalClick::BinaryValue.fixed(i32, Bytes.new(4) { |j| ((c.not_nil!.unsafe_as(UInt32) >> (8 * j)) & 255).to_u8 })
    CrystalClick::BinaryValue.tuple(tuple, [
      CrystalClick::BinaryValue.uint64(a), CrystalClick::BinaryValue.string(b),
      CrystalClick::BinaryValue.nullable(nullable, child),
    ])
  end
  CrystalClick::BinaryValue.nested(type, children)
end
granules = [values[0, 2], values[2, 2], values[4, 1]]
bulk_profile = CrystalClick::BinaryBulkProfile.with_size_stream
physical = CrystalClick::BinaryBulkPhysicalPlan.new(type, "nested", bulk_profile)
encoded = CrystalClick::BinaryBulkCodec.encode(type, granules, profile: bulk_profile)
lanes = Hash(String, CrystalClick::BinaryBulkStream).new
encoded.roles.each do |role|
  data = File.join(part, physical.data_file_for(role, hashed: true))
  marks = File.join(part, physical.marks_file_for(role, hashed: true))
  lane = CrystalClick::CompressedMarkReader.read(data, marks, File.size(data), File.size(marks))
  raise "wrong stock outer row grid" unless lane.rows_per_mark == [2_u64, 2_u64, 1_u64]
  raise "bulk lane bytes differ: #{role}" unless lane.bytes == encoded.stream(role).bytes
  raise "bulk lane offsets differ: #{role}" unless lane.offsets == encoded.stream(role).offsets
  lanes[role] = CrystalClick::BinaryBulkStream.new(lane.bytes, lane.offsets)
end
stock = CrystalClick::BinaryBulkStreams.new(3, lanes)
[{0, 3}, {1, 1}, {1, 2}, {3, 0}].each do |first, count|
  decoded = CrystalClick::BinaryBulkCodec.decode(type, stock, [2_u64, 2_u64, 1_u64], first, count, profile: bulk_profile)
  expected = granules[first, count]
  raise "wrong window size" unless decoded.size == expected.size
  decoded.each_with_index do |rows, mark|
    raise "wrong window rows" unless rows.size == expected[mark].size
    rows.each_with_index do |value, row|
      raise "lost Nested identity" unless value.type == type
      raise "wrong decoded value" unless CrystalClick::BinaryValueCodec.encode_value(value) ==
                                           CrystalClick::BinaryValueCodec.encode_value(expected[mark][row])
    end
  end
end
puts "W172 stock Nested bulk: #{encoded.role_count} exact lanes and 4 nominal windows passed"
