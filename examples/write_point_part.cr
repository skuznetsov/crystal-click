require "../src/crystal_click"

unless ARGV.size == 1
  STDERR.puts "usage: crystal run examples/write_point_part.cr -- NEW_PART_PATH"
  exit 2
end

keys = [0_u64, 1_u64, 2_u64]
points = [
  CrystalClick::WidePointValue.new(1.5, -2.25),
  CrystalClick::WidePointValue.from_bits(0x8000_0000_0000_0000_u64, 0_u64),
  CrystalClick::WidePointValue.from_bits(0x7ff8_0000_0000_002a_u64, 0x7ff0_0000_0000_0000_u64),
]
CrystalClick::WidePartWriter.write_uint64_point_pair(
  ARGV[0], "pk", keys.to_unsafe.to_slice(keys.size),
  "location", points.to_unsafe.to_slice(points.size), rows_per_mark: 2
)

part = CrystalClick::WidePart.open_typed(ARGV[0], "location")
part.each_point_mark_range("location", 0, part.mark_count) do |values, mark|
  values.each do |point|
    puts "mark=#{mark} x_bits=0x#{point.x_bits.to_s(16)} y_bits=0x#{point.y_bits.to_s(16)}"
  end
  nil
end
