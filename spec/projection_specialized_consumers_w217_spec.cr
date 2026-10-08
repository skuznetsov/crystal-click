require "./spec_helper"

private def w217_parent(root : String, name : String, keys : Slice(UInt64) = Slice[1_u64]) : String
  path = File.join(root, name)
  values = keys.to_a
  CrystalClick::WidePartWriter.write_uint64_pair(
    path, "pk", keys, "base", values.to_unsafe.to_slice(values.size), rows_per_mark: 1
  )
end

private def w217_object_schema : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(t UInt64)")
end

private def w217_object_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    schema.typed_paths,
  )
end

private def w217_object_document(value : UInt64) : CrystalClick::ObjectDocument
  CrystalClick::ObjectDocument.new({"t" => CrystalClick::BinaryValue.uint64(value)})
end

private def w217_write_object_part(
  path : String,
  keys : Slice(UInt64),
  document_values : Array(UInt64),
) : String
  schema = w217_object_schema
  documents = document_values.map { |value| w217_object_document(value) }
  granules = [] of Array(CrystalClick::ObjectDocument)
  documents.each_slice(2) { |mark| granules << mark.to_a }
  CrystalClick::WidePartWriter.write_uint64_object_pair(
    path, "pk", keys, "payload", schema, w217_object_plan(schema), granules,
    rows_per_mark: 2,
  )
end

private def w217_array_schema : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.new(
    {"t" => CrystalClick::BinaryDataType.primitive("UInt8")},
    max_dynamic_paths: 0,
    max_dynamic_types: 0,
  )
end

private def w217_array_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
  w217_object_plan(schema)
end

private def w217_array_document(value : UInt8) : CrystalClick::ObjectDocument
  type = CrystalClick::BinaryDataType.primitive("UInt8")
  CrystalClick::ObjectDocument.new({"t" => CrystalClick::BinaryValue.fixed(type, Bytes[value])})
end

private def w217_recursive_schema : CrystalClick::StorageColumnSchema
  object_schema = CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(t UInt8)")
  CrystalClick::StorageColumnSchema.parse("Tuple(doc #{object_schema.declaration}, n UInt64)")
end

private def w217_recursive_plan(schema : CrystalClick::StorageColumnSchema) : Hash(String, CrystalClick::ObjectDocumentPlan)
  object_schema = CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(t UInt8)")
  {"root/tuple[0]" => w217_object_plan(object_schema)}
end

private def w217_recursive_value(value : UInt64) : CrystalClick::StorageColumnValue
  object = CrystalClick::ObjectDocument.new({
    "t" => CrystalClick::BinaryValue.fixed(
      CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[value.to_u8]
    ),
  })
  CrystalClick::StorageColumnValue.tuple([
    CrystalClick::StorageColumnValue.object_document(object),
    CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.uint64(value * 10_u64)),
  ] of CrystalClick::StorageColumnValue)
end

private def w217_dynamic_value(type : CrystalClick::BinaryDataType, value : UInt64) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.dynamic(type, CrystalClick::BinaryValue.uint64(value))
end

private def w217_binary_signature(value : CrystalClick::BinaryValue) : Bytes
  CrystalClick::BinaryValueCodec.encode(value)
end

private def w217_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w217_rewrite_count_key_mark_rows!(part : String, rows : Array(UInt64)) : Nil
  marks_path = File.join(part, "#{CrystalClick::StreamName.hash("pk")}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  mark_size = CrystalClick::WidePart::MARK_SIZE
  offset = 0_u64
  rows.each_with_index do |mark_rows, index|
    w217_write_u64(marks, index * mark_size + 8, offset)
    w217_write_u64(marks, index * mark_size + 16, mark_rows)
    offset += mark_rows * 8_u64
  end
  w217_write_u64(marks, rows.size * mark_size + 8, offset)
  File.write(marks_path, marks)
end

private def w217_catalog_paths(root : String) : Tuple(String, String)
  database_uuid = "d2170000-0000-4000-8000-000000000001"
  table_uuid = "d2170000-0000-4000-8000-000000000002"
  FileUtils.mkdir_p(File.join(root, "metadata"))
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(database_path)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  declaration = w217_object_schema.declaration
  ddl = <<-DDL
  ATTACH TABLE _ UUID '#{table_uuid}'
  (
      `pk` UInt64,
      `payload` #{declaration},
      PROJECTION `by_payload` (SELECT payload ORDER BY pk)
  )
  ENGINE = MergeTree
  ORDER BY pk
  DDL
  File.write(File.join(database_path, "events.sql"), ddl)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  {table_path, declaration}
end

private def w217_write_dynamic_json_part(path : String, key_values : Slice(UInt64), json_values : Array(UInt8)) : Nil
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  json = CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 0,
    max_dynamic_types: 0,
    typed_paths: {"t" => uint8} of String => CrystalClick::BinaryDataType,
  )
  schema = json.json_type.not_nil!.typed_paths
  plan = CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    schema,
  )
  structure = CrystalClick::DynamicStructure.new([json] of CrystalClick::BinaryDataType)
  dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
  rows = json_values.map do |value|
    row = CrystalClick::BinaryJsonRow.new(
      json,
      [{"t", CrystalClick::BinaryValue.fixed(uint8, Bytes[value])}] of Tuple(String, CrystalClick::BinaryValue),
    )
    actual = CrystalClick::BinaryValue.json(json, row)
    CrystalClick::BinaryValue.dynamic(dynamic, actual)
  end
  granules = [] of Array(CrystalClick::BinaryValue)
  rows.each_slice(2) { |mark| granules << mark.to_a }
  plans = [{"root", structure.canonical_index_for(json), plan}] of Tuple(String, Int32, CrystalClick::ObjectDocumentPlan)
  CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
    path,
    "pk",
    key_values,
    "payload",
    dynamic,
    {"root" => structure},
    granules,
    rows_per_mark: 2,
    json_object_plans: plans,
  )
end

private def w217_truncate_dynamic_json_structure!(part : String) : Nil
  uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
  json = CrystalClick::BinaryDataType.json(
    max_dynamic_paths: 0,
    max_dynamic_types: 0,
    typed_paths: {"t" => uint8} of String => CrystalClick::BinaryDataType,
  )
  structure = CrystalClick::DynamicStructure.new([json] of CrystalClick::BinaryDataType)
  dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
  plan = CrystalClick::BinaryDynamicBulkPlan.new_with_budget(
    dynamic,
    {"root" => structure},
    CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
    json_object_plans: [{"root", structure.canonical_index_for(json), w217_object_plan(
      CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(t UInt8)"),
    )}] of Tuple(String, Int32, CrystalClick::ObjectDocumentPlan),
  )
  physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(plan, "payload", CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS)
  site = physical.json_object_site("root", structure.canonical_index_for(json))
  stream = site.physical_plan.stream_names.find(&.ends_with?("object_structure")).not_nil!
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  bytes = File.read(path).to_slice
  raise "W217 Dynamic JSON structure stream is unexpectedly short" if bytes.size < 2
  File.write(path, bytes[0, bytes.size - 1])
end

describe "W217 specialized projection child consumers" do
  it "reads whole JSON/Object children through the declared catalog projection, independent of parent rows" do
    root = File.tempname("crystal-click-w217-catalog-object-projection-")
    begin
      table_path, declaration = w217_catalog_paths(root)
      parent_a = File.join(table_path, "all_1_1_0")
      parent_b = File.join(table_path, "all_2_2_0")
      w217_write_object_part(parent_a, Slice[1_u64], [1_u64])
      w217_write_object_part(parent_b, Slice[2_u64, 3_u64], [2_u64, 3_u64])
      w217_write_object_part(File.join(parent_a, "by_payload.proj"), Slice[101_u64, 102_u64, 103_u64], [101_u64, 102_u64, 103_u64])
      w217_write_object_part(File.join(parent_b, "by_payload.proj"), Slice[201_u64], [201_u64])

      File.read(File.join(parent_a, "columns.txt")).should contain("`payload` #{declaration}")
      table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
      observed = [] of UInt64
      parent_paths = [] of String
      mark_rows = [] of Tuple(Int32, Int32, UInt64)
      table.scan_projection_typed("by_payload", ["payload"], batch_rows: 2) do |batch|
        parent_paths << batch.part_path
        mark_rows << {batch.part_index, batch.mark_index, batch.source_row_offset}
        batch.object_documents_for("payload").each do |document|
          observed << document.value_for("t").as_uint64
        end
      end
      observed.should eq([101_u64, 102_u64, 103_u64, 201_u64])
      parent_paths.uniq.should eq([parent_a, parent_b])
      mark_rows.should eq([{0, 0, 0_u64}, {0, 1, 2_u64}, {1, 0, 3_u64}])

      physical = CrystalClick::WidePartTable.open_selected_projection_typed(
        [parent_a, parent_b], "by_payload", ["payload"]
      )
      physical.part_mark_row_counts.should eq([[2_u64, 1_u64], [1_u64]])
      physical.total_row_count.should eq(4_u64)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "reads Array(JSON) children with child-owned rows and mark grids" do
    root = File.tempname("crystal-click-w217-array-object-projection-")
    Dir.mkdir(root)
    begin
      parent_a = w217_parent(root, "all_1_1_0")
      parent_b = w217_parent(root, "all_2_2_0", Slice[2_u64, 3_u64])
      schema = w217_array_schema
      plan = w217_array_plan(schema)
      a_values = [
        [w217_array_document(7_u8)] of CrystalClick::ObjectDocument,
        [] of CrystalClick::ObjectDocument,
        [w217_array_document(8_u8), w217_array_document(9_u8)] of CrystalClick::ObjectDocument,
      ] of Array(CrystalClick::ObjectDocument)
      CrystalClick::WidePartWriter.write_uint64_array_object_pair(
        File.join(parent_a, "by_array.proj"), "pk", Slice[101_u64, 102_u64, 103_u64], "a", schema, plan,
        [a_values[0..1], a_values[2..2]] of Array(Array(CrystalClick::ObjectDocument)), rows_per_mark: 2)
      CrystalClick::WidePartWriter.write_uint64_array_object_pair(
        File.join(parent_b, "by_array.proj"), "pk", Slice[201_u64], "a", schema, plan,
        [[[] of CrystalClick::ObjectDocument] of Array(CrystalClick::ObjectDocument)], rows_per_mark: 2)

      table = CrystalClick::WidePartTable.open_selected_projection_typed([parent_a, parent_b], "by_array", ["a"])
      table.total_row_count.should eq(4_u64)
      table.part_mark_row_counts.should eq([[2_u64, 1_u64], [1_u64]])
      rows = [] of Array(UInt8)
      parent_paths = [] of String
      table.scan_typed(batch_rows: 2) do |batch|
        parent_paths << batch.part_path unless parent_paths.last? == batch.part_path
        batch.array_object_documents_for("a").each do |documents|
          rows << documents.map { |document| document.value_for("t").bytes[0] }
        end
      end
      rows.should eq([[7_u8], [] of UInt8, [8_u8, 9_u8], [] of UInt8])
      parent_paths.should eq([parent_a, parent_b])
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "reads recursive Tuple/Array JSON children without substituting parent rows" do
    root = File.tempname("crystal-click-w217-recursive-projection-")
    Dir.mkdir(root)
    begin
      parent_a = w217_parent(root, "all_1_1_0")
      parent_b = w217_parent(root, "all_2_2_0", Slice[2_u64, 3_u64])
      schema = w217_recursive_schema
      plans = w217_recursive_plan(schema)
      a_values = [1_u64, 2_u64, 3_u64].map { |value| w217_recursive_value(value) }
      b_values = [7_u64].map { |value| w217_recursive_value(value) }
      CrystalClick::WidePartWriter.write_uint64_recursive_pair(
        File.join(parent_a, "by_recursive.proj"), "pk", Slice[101_u64, 102_u64, 103_u64], "payload", schema, plans,
        [a_values[0..1], a_values[2..2]] of Array(CrystalClick::StorageColumnValue), rows_per_mark: 2)
      CrystalClick::WidePartWriter.write_uint64_recursive_pair(
        File.join(parent_b, "by_recursive.proj"), "pk", Slice[201_u64], "payload", schema, plans,
        [b_values] of Array(CrystalClick::StorageColumnValue), rows_per_mark: 2)

      table = CrystalClick::WidePartTable.open_selected_projection_typed([parent_a, parent_b], "by_recursive", ["payload"])
      observed = [] of Tuple(UInt64, UInt8)
      parent_paths = [] of String
      table.scan_typed(batch_rows: 2) do |batch|
        parent_paths << batch.part_path
        batch.recursive_values_for("payload").each do |value|
          document = value.child_at(0).object_document
          observed << {value.child_at(1).bulk_value.as_uint64, document.value_for("t").bytes[0]}
        end
      end
      observed.should eq([{10_u64, 1_u8}, {20_u64, 2_u8}, {30_u64, 3_u8}, {70_u64, 7_u8}])
      parent_paths.uniq.should eq([parent_a, parent_b])
      table.total_row_count.should eq(4_u64)
      table.part_mark_row_counts.should eq([[2_u64, 1_u64], [1_u64]])
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "reads both root Dynamic and wrapped Array(Dynamic) child payloads" do
    root = File.tempname("crystal-click-w217-dynamic-projection-")
    Dir.mkdir(root)
    begin
      parent_a = w217_parent(root, "all_1_1_0")
      parent_b = w217_parent(root, "all_2_2_0", Slice[2_u64, 3_u64])
      uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
      dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
      structure = CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)
      structures = {"root" => structure}
      root_rows = [101_u64, 102_u64, 103_u64, 201_u64].map { |value| w217_dynamic_value(dynamic, value) }
      CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
        File.join(parent_a, "by_dynamic.proj"), "pk", Slice[101_u64, 102_u64, 103_u64], "payload", dynamic,
        structures, [root_rows[0..1], root_rows[2..2]] of Array(CrystalClick::BinaryValue), rows_per_mark: 2)
      CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
        File.join(parent_b, "by_dynamic.proj"), "pk", Slice[201_u64], "payload", dynamic,
        structures, [[root_rows[3]]] of Array(CrystalClick::BinaryValue), rows_per_mark: 2)
      root_table = CrystalClick::WidePartTable.open_selected_projection_typed([parent_a, parent_b], "by_dynamic", ["payload"])
      root_values = [] of Bytes
      root_paths = [] of String
      root_table.scan_typed do |batch|
        root_paths << batch.part_path
        batch.dynamic_bulk_values_for("payload").each { |value| root_values << w217_binary_signature(value) }
      end
      root_values.should eq(root_rows.map { |value| w217_binary_signature(value) })
      root_paths.uniq.should eq([parent_a, parent_b])
      root_table.part_mark_row_counts.should eq([[2_u64, 1_u64], [1_u64]])

      array_type = CrystalClick::BinaryDataType.array(dynamic)
      array_structure = CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)
      array_structures = {"root.elements" => array_structure}
      wrapped = [
        CrystalClick::BinaryValue.array(array_type, [w217_dynamic_value(dynamic, 11_u64)] of CrystalClick::BinaryValue),
        CrystalClick::BinaryValue.array(array_type, [w217_dynamic_value(dynamic, 12_u64)] of CrystalClick::BinaryValue),
        CrystalClick::BinaryValue.array(array_type, [w217_dynamic_value(dynamic, 13_u64)] of CrystalClick::BinaryValue),
        CrystalClick::BinaryValue.array(array_type, [w217_dynamic_value(dynamic, 21_u64)] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue
      CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
        File.join(parent_a, "by_array_dynamic.proj"), "pk", Slice[111_u64, 112_u64, 113_u64], "wrapped", array_type,
        array_structures, [wrapped[0..1], wrapped[2..2]] of Array(CrystalClick::BinaryValue), rows_per_mark: 2)
      CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
        File.join(parent_b, "by_array_dynamic.proj"), "pk", Slice[121_u64], "wrapped", array_type,
        array_structures, [[wrapped[3]]] of Array(CrystalClick::BinaryValue), rows_per_mark: 2)
      wrapped_table = CrystalClick::WidePartTable.open_selected_projection_typed([parent_a, parent_b], "by_array_dynamic", ["wrapped"])
      wrapped_values = [] of Bytes
      wrapped_paths = [] of String
      wrapped_table.scan_typed do |batch|
        wrapped_paths << batch.part_path
        batch.dynamic_bulk_values_for("wrapped").each { |value| wrapped_values << w217_binary_signature(value) }
      end
      wrapped_values.should eq(wrapped.map { |value| w217_binary_signature(value) })
      wrapped_paths.uniq.should eq([parent_a, parent_b])
      wrapped_table.part_mark_row_counts.should eq([[2_u64, 1_u64], [1_u64]])
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "reads only the exact Count state while validating its hidden child-local UInt64 sibling" do
    root = File.tempname("crystal-click-w217-count-projection-")
    Dir.mkdir(root)
    begin
      parent_a = w217_parent(root, "all_1_1_0")
      parent_b = w217_parent(root, "all_2_2_0", Slice[2_u64, 3_u64])
      type = CrystalClick::BinaryDataType.aggregate_count(CrystalClick::BinaryDataType.primitive("UInt64"))
      counts = [0_u64, 127_u64, 128_u64, UInt64::MAX]
      values = counts.map { |count| CrystalClick::BinaryValue.aggregate_count_state(type, count) }
      CrystalClick::WidePartWriter.write_uint64_aggregate_count_pair(
        File.join(parent_a, "by_count.proj"), "pk", Slice[101_u64, 102_u64, 103_u64], "c", type,
        values[0..2].to_unsafe.to_slice(3), rows_per_mark: 2)
      CrystalClick::WidePartWriter.write_uint64_aggregate_count_pair(
        File.join(parent_b, "by_count.proj"), "pk", Slice[201_u64], "c", type,
        values[3..3].to_unsafe.to_slice(1), rows_per_mark: 1)

      table = CrystalClick::WidePartTable.open_selected_projection_typed([parent_a, parent_b], "by_count", ["c"])
      table.columns.should eq(["c"])
      table.total_row_count.should eq(4_u64)
      table.part_mark_row_counts.should eq([[2_u64, 1_u64], [1_u64]])
      observed = [] of UInt64
      parent_paths = [] of String
      table.scan_typed(batch_rows: 2) do |batch|
        parent_paths << batch.part_path
        batch.column_names.should eq(["c"])
        batch.aggregate_count_states_for("c", type).each { |state| observed << state.count_state }
      end
      observed.should eq(counts)
      parent_paths.uniq.should eq([parent_a, parent_b])
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "keeps missing children, unsupported child metadata, malformed Count siblings, and damaged excluded schedules fail-closed" do
    root = File.tempname("crystal-click-w217-projection-negative-")
    Dir.mkdir(root)
    begin
      parent_a = w217_parent(root, "all_1_1_0")
      parent_b = w217_parent(root, "all_2_2_0", Slice[2_u64, 3_u64])
      tag_path = File.join(parent_a, "by_tag.proj")
      CrystalClick::WidePartWriter.write_uint64_string_pair(
        tag_path, "tag", Slice[10_u64], "label", Slice["only-a"], rows_per_mark: 1)
      callbacks = 0
      expect_raises(CrystalClick::InvalidPartError) do
        table = CrystalClick::WidePartTable.open_selected_projection_typed([parent_a, parent_b], "by_tag", ["tag"])
        table.scan_typed { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)

      bad_object = File.join(parent_a, "by_bad_object.proj")
      w217_write_object_part(bad_object, Slice[101_u64], [101_u64])
      File.write(
        File.join(bad_object, "columns.txt"),
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` JSON(t BFloat16)\n",
      )
      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        table = CrystalClick::WidePartTable.open_selected_projection_typed([parent_a], "by_bad_object", ["payload"])
        table.scan_typed { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)

      count_type = CrystalClick::BinaryDataType.aggregate_count(CrystalClick::BinaryDataType.primitive("UInt64"))
      count_values = Slice[CrystalClick::BinaryValue.aggregate_count_state(count_type, 4_u64)]
      [
        {"by_missing_count_key", "columns format version: 1\n1 columns:\n`c` #{count_type.name}\n"},
        {"by_wrong_count_key", "columns format version: 1\n2 columns:\n`pk` UInt32\n`c` #{count_type.name}\n"},
      ].each do |projection_name, bad_columns|
        child = File.join(parent_a, "#{projection_name}.proj")
        CrystalClick::WidePartWriter.write_uint64_aggregate_count_pair(
          child, "pk", Slice[101_u64], "c", count_type, count_values, rows_per_mark: 1)
        File.write(File.join(child, "columns.txt"), bad_columns)
        callbacks = 0
        expect_raises(CrystalClick::UnsupportedFormatError) do
          table = CrystalClick::WidePartTable.open_selected_projection_typed([parent_a], projection_name, ["c"])
          table.scan_typed { |_batch| callbacks += 1 }
        end
        callbacks.should eq(0)
      end

      {
        {"by_count_row_axis", [1_u64, 1_u64]},
        {"by_count_mark_axis", [1_u64, 2_u64]},
      }.each do |projection_name, key_mark_rows|
        child = File.join(parent_a, "#{projection_name}.proj")
        CrystalClick::WidePartWriter.write_uint64_aggregate_count_pair(
          child, "pk", Slice[101_u64, 102_u64, 103_u64], "c", count_type,
          Slice[
            CrystalClick::BinaryValue.aggregate_count_state(count_type, 4_u64),
            CrystalClick::BinaryValue.aggregate_count_state(count_type, 5_u64),
            CrystalClick::BinaryValue.aggregate_count_state(count_type, 6_u64),
          ],
          rows_per_mark: 2,
        )
        w217_rewrite_count_key_mark_rows!(child, key_mark_rows)
        callbacks = 0
        expect_raises(CrystalClick::CorruptPartError) do
          table = CrystalClick::WidePartTable.open_selected_projection_typed([parent_a], projection_name, ["c"])
          table.scan_typed { |_batch| callbacks += 1 }
        end
        callbacks.should eq(0)
      end

      identity_child_a = File.join(parent_a, "by_count_identity.proj")
      identity_child_b = File.join(parent_b, "by_count_identity.proj")
      CrystalClick::WidePartWriter.write_uint64_aggregate_count_pair(
        identity_child_a, "pk", Slice[101_u64], "c", count_type,
        Slice[CrystalClick::BinaryValue.aggregate_count_state(count_type, 7_u64)], rows_per_mark: 1)
      CrystalClick::WidePartWriter.write_uint64_aggregate_count_pair(
        identity_child_b, "id", Slice[201_u64], "c", count_type,
        Slice[CrystalClick::BinaryValue.aggregate_count_state(count_type, 8_u64)], rows_per_mark: 1)
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError, "AggregateFunction(count) UInt64 sibling name differs across parts") do
        table = CrystalClick::WidePartTable.open_selected_projection_typed(
          [parent_a, parent_b], "by_count_identity", ["c"]
        )
        table.scan_typed { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)

      # Bound Dynamic(JSON) child state is replayed even if the caller excludes
      # every mark or starts at EOF. Damage the unselected Object stream after
      # table construction so the assertion exercises scan-time preflight.
      [
        {"by_empty_schedule", :empty, parent_a, Slice[101_u64, 102_u64, 103_u64], [31_u8, 32_u8, 33_u8]},
        {"by_eof_schedule", :eof, parent_b, Slice[201_u64], [41_u8]},
      ].each do |projection_name, schedule, parent, keys, json_values|
        child = File.join(parent, "#{projection_name}.proj")
        w217_write_dynamic_json_part(child, keys, json_values)
        table = CrystalClick::WidePartTable.open_selected_projection_typed([parent], projection_name, ["payload"])
        w217_truncate_dynamic_json_structure!(child)
        callbacks = 0
        expect_raises(CrystalClick::CorruptPartError) do
          if schedule == :empty
            table.scan_typed_candidate_marks([[] of Int32]) { |_batch| callbacks += 1 }
          else
            table.scan_typed_window(table.total_row_count, 1) { |_batch| callbacks += 1 }
          end
        end
        callbacks.should eq(0)
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
