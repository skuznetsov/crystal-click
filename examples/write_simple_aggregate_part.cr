require "../src/crystal_click"

# Writes an ordinary MergeTree Wide part. The aggregate function is nominal
# storage metadata; this example neither computes nor merges aggregate values.
destination = ARGV[0]? || abort("Usage: crystal run examples/write_simple_aggregate_part.cr -- /existing/table/all_1_1_0")
function = CrystalClick::BinarySimpleAggregateType::Function::Sum
keys = [1_u64, 2_u64, 3_u64]
values = [0_u64, 42_u64, UInt64::MAX]

CrystalClick::WidePartWriter.write_uint64_simple_aggregate_pair(
  destination, "pk", keys.to_unsafe.to_slice(keys.size),
  "v", values.to_unsafe.to_slice(values.size), function, rows_per_mark: 2
)
part = CrystalClick::WidePart.open_typed(destination, "v")
puts part.column_type
puts part.read_simple_aggregate_uint64_mark_range("v", 0, part.mark_count)
