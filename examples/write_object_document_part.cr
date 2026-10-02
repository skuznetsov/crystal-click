require "../src/crystal_click"

abort "Usage: crystal run examples/write_object_document_part.cr -- NEW_PART_DIRECTORY" unless ARGV.size == 1

include CrystalClick

typed = {"sequence" => BinaryDataType.primitive("UInt64")}
schema = ObjectDocumentSchema.new(typed, max_dynamic_paths: 1, max_dynamic_types: 1)
plan = ObjectDocumentPlan.new(
  ObjectDynamicStructureSet.new(
    ObjectStructure.new(["message"]),
    {"message" => DynamicStructure.new([BinaryDataType.primitive("String")])}),
  typed)

# Paths and ordinary Dynamic alternatives are explicit; later values of other
# nominal types are stored in SharedVariant, not inferred into the roster.
granules = [
  [ObjectDocument.new({"sequence" => BinaryValue.uint64(1_u64), "message" => BinaryValue.string("hello")}),
   ObjectDocument.new({"sequence" => BinaryValue.uint64(2_u64), "message" => BinaryValue.int64(42_i64), "extra.flag" => BinaryValue.bool(true)})],
  [ObjectDocument.new({"sequence" => BinaryValue.uint64(3_u64)})],
]
keys = Slice[10_u64, 20_u64, 30_u64]
part = WidePartWriter.write_uint64_object_pair(ARGV[0], "pk", keys, "payload", schema, plan, granules, rows_per_mark: 2)
puts "Published standalone part: #{part}"

# The explicit file reader is qualified separately from the table/catalog API.
ObjectDocumentFileReader.read(part, "payload", schema.typed_paths, hashed: true).each_with_index do |rows, mark|
  puts "mark #{mark}: #{rows.size} documents"
  rows.each { |document| puts document.paths.join(", ") }
end
