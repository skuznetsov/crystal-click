require "./spec_helper"

private def w186_table_object_schema : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(t UInt8)")
end

private def w186_table_recursive_schema : CrystalClick::StorageColumnSchema
  object_schema = w186_table_object_schema
  CrystalClick::StorageColumnSchema.parse("Tuple(doc #{object_schema.declaration}, n UInt64)")
end

private def w186_table_object_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
  CrystalClick::ObjectDocumentPlan.new(structures, schema.typed_paths)
end

private def w186_table_recursive_value(pk : UInt64) : CrystalClick::StorageColumnValue
  document = CrystalClick::ObjectDocument.new({
    "t" => CrystalClick::BinaryValue.fixed(
      CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[pk.to_u8]
    ),
  })
  CrystalClick::StorageColumnValue.tuple([
    CrystalClick::StorageColumnValue.object_document(document),
    CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.uint64(pk * 10_u64)),
  ] of CrystalClick::StorageColumnValue)
end

private def with_w186_recursive_table_directory(& : String ->)
  root = File.tempname("crystal-click-w186-recursive-table-")
  Dir.mkdir(root)
  yield root
ensure
  FileUtils.rm_rf(root) if root && Dir.exists?(root)
end

describe "W186 recursive Tuple typed table" do
  it "materializes only selected marks and returns ordinary values for control types" do
    with_w186_recursive_table_directory do |root|
      recursive_part = File.join(root, "all_1_1_0")
      schema = w186_table_recursive_schema
      object_schema = w186_table_object_schema
      object_plans = {"root/tuple[0]" => w186_table_object_plan(object_schema)}
      keys = Slice[1_u64, 2_u64, 3_u64, 4_u64]
      granules = [
        [w186_table_recursive_value(1_u64), w186_table_recursive_value(2_u64)] of CrystalClick::StorageColumnValue,
        [w186_table_recursive_value(3_u64), w186_table_recursive_value(4_u64)] of CrystalClick::StorageColumnValue,
      ] of Array(CrystalClick::StorageColumnValue)

      CrystalClick::WidePartWriter.write_uint64_recursive_pair(
        recursive_part, "pk", keys, "payload", schema, object_plans, granules,
        rows_per_mark: 2,
      ).should eq(recursive_part)

      table = CrystalClick::WidePartTable.open_selected_typed([recursive_part], ["payload"])
      table.part_mark_row_counts.should eq([[2_u64, 2_u64]])
      selected = [] of Tuple(UInt64, UInt8)
      selected_marks = [] of Int32
      table.scan_typed_candidate_marks([[1]]) do |batch|
        selected_marks << batch.mark_index
        batch.recursive_values_for("payload").each do |value|
          value.tuple?.should be_true
          value.child_count.should eq(2)
          document = value.child_at(0).object_document
          selected << {
            value.child_at(1).bulk_value.as_uint64,
            document.value_for("t").bytes[0],
          }
        end
      end
      selected_marks.should eq([1])
      selected.should eq([{30_u64, 3_u8}, {40_u64, 4_u8}])

      empty_selection_callbacks = 0
      table.scan_typed_candidate_marks([[] of Int32]) do |_batch|
        empty_selection_callbacks += 1
      end
      empty_selection_callbacks.should eq(0)

      tuple_part = File.join(root, "all_2_2_0")
      tuple_values = [
        {10_u64, "ten"},
        {20_u64, "twenty"},
      ] of Tuple(UInt64, String)
      CrystalClick::WidePartWriter.write_uint64_tuple_string_pair(
        tuple_part, "pk", Slice[1_u64, 2_u64], "payload", tuple_values,
        rows_per_mark: 1,
      ).should eq(tuple_part)
      tuple_table = CrystalClick::WidePartTable.open_selected_typed([tuple_part], ["payload"])
      ordinary_tuples = [] of Tuple(UInt64, String)
      tuple_table.scan_typed(batch_rows: 2) do |batch|
        batch.tuples_for("payload").each do |value|
          ordinary_tuples << {value[0], String.new(value[1].to_slice)}
        end
      end
      ordinary_tuples.should eq(tuple_values)

      scalar_part = File.join(root, "all_3_3_0")
      scalar_values = Slice[7_u64, 8_u64]
      CrystalClick::WidePartWriter.write_uint64_pair(
        scalar_part, "pk", Slice[1_u64, 2_u64], "payload", scalar_values,
        rows_per_mark: 1,
      ).should eq(scalar_part)
      scalar_table = CrystalClick::WidePartTable.open_selected_typed([scalar_part], ["payload"])
      ordinary_scalars = [] of UInt64
      scalar_table.scan_typed(batch_rows: 2) do |batch|
        batch.values_for("payload").each { |value| ordinary_scalars << value }
      end
      ordinary_scalars.should eq([7_u64, 8_u64])
    end
  end
end
