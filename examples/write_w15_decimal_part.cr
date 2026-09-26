require "../src/crystal_click"

unless ARGV.size == 1
  STDERR.puts "usage: crystal run examples/write_w15_decimal_part.cr -- NEW_PART_PATH"
  exit 2
end

keys = [1_u64, 2_u64, 3_u64]
# Decimal32(2) stores signed integers scaled by 100. No Float conversion occurs.
amounts = [123_i32, -456_i32, 0_i32]
path = ARGV[0]

CrystalClick::WidePartWriter.write_uint64_decimal32_pair(
  path,
  "pk",
  keys.to_unsafe.to_slice(keys.size),
  "amount",
  amounts.to_unsafe.to_slice(amounts.size),
  scale: 2,
  rows_per_mark: 2
)

part = CrystalClick::WidePart.open_typed(path, "amount")
raw = part.read_decimal32_raw_mark_range("amount", 0, part.mark_count)
puts "#{part.column_type}: #{raw.inspect}"
