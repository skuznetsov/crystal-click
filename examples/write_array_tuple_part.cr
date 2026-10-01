require "../src/crystal_click"

unless ARGV.size == 1
  STDERR.puts "usage: crystal run examples/write_array_tuple_part.cr -- NEW_PART_PATH"
  exit 2
end

type_name = "Array(Tuple(id UInt64, details Tuple(note Nullable(String))))"
keys = [1_u64, 2_u64, 3_u64]
# Outer row 1 contains two elements, row 2 is empty, row 3 has one element.
row_sizes = [2_u64, 0_u64, 1_u64]
mask = CrystalClick::ScalarNullMap.new(Bytes[0_u8, 1_u8, 0_u8], 3_u64)
columns = [
  CrystalClick::WideTupleLeafColumn.new("id", [10_u64, 20_u64, 30_u64]),
  CrystalClick::WideTupleLeafColumn.new("details.note", ["hello", "hidden", ""]).as_nullable(mask),
]

CrystalClick::WidePartWriter.write_uint64_array_tuple_part(
  ARGV[0], "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name,
  row_sizes.to_unsafe.to_slice(row_sizes.size), columns, rows_per_mark: 2
)

part = CrystalClick::WidePart.open_typed(ARGV[0], "payload")
data = part.read_array_tuple_mark_range("payload", 0, part.mark_count)
puts "#{data.type_name}: #{data.row_count} rows, #{data.element_count} elements"
data.row_count.times do |index|
  row = data.row(index)
  puts "pk=#{keys[index]}: #{row.size} elements"
  row.each do |element|
    puts "  id=#{element["id"]}, note=#{element.tuple("details")["note"].inspect}"
  end
end
