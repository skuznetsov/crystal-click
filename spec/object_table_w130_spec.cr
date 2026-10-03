require "./spec_helper"

private def w130_budget_schema : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.new(
    {"t" => CrystalClick::BinaryDataType.primitive("UInt64")},
    max_dynamic_paths: 1,
    max_dynamic_types: 1,
  )
end

private def with_w130_budget_reader(&)
  root = File.tempname("crystal-click-w130-budget-")
  Dir.mkdir(root)
  begin
    schema = w130_budget_schema
    plan = CrystalClick::ObjectDocumentPlan.new(
      CrystalClick::ObjectDynamicStructureSet.new(
        CrystalClick::ObjectStructure.new(["d"]),
        {"d" => CrystalClick::DynamicStructure.new([CrystalClick::BinaryDataType.primitive("String")])},
      ),
      schema.typed_paths,
    )
    documents = [[
      CrystalClick::ObjectDocument.new({
        "t" => CrystalClick::BinaryValue.uint64(1_u64),
        "d" => CrystalClick::BinaryValue.string("first document payload"),
      }),
      CrystalClick::ObjectDocument.new({
        "t" => CrystalClick::BinaryValue.uint64(2_u64),
        "d" => CrystalClick::BinaryValue.string("second document payload"),
      }),
    ]]
    second_documents = [[
      CrystalClick::ObjectDocument.new({
        "t" => CrystalClick::BinaryValue.uint64(3_u64),
        "d" => CrystalClick::BinaryValue.string("a larger second selected Object lane"),
      }),
      CrystalClick::ObjectDocument.new({
        "t" => CrystalClick::BinaryValue.uint64(4_u64),
        "d" => CrystalClick::BinaryValue.string("another larger second-lane payload"),
      }),
    ]]
    first_part = CrystalClick::WidePartWriter.write_uint64_object_pair(
      File.join(root, "all_1_1_0"),
      "pk",
      Slice[1_u64, 2_u64],
      "first",
      schema,
      plan,
      documents,
      rows_per_mark: 2,
    )
    second_part = CrystalClick::WidePartWriter.write_uint64_object_pair(
      File.join(root, "all_2_2_0"),
      "pk",
      Slice[3_u64, 4_u64],
      "second",
      schema,
      plan,
      second_documents,
      rows_per_mark: 2,
    )
    first_reader = CrystalClick::ObjectColumnReader.open(first_part, "first", schema)
    second_reader = CrystalClick::ObjectColumnReader.open(second_part, "second", schema)
    yield first_reader, second_reader
  ensure
    FileUtils.rm_rf(root)
  end
end

class CrystalClick::WidePartTable
  # Test-only access to the per-mark Object adapter's logical owner admission.
  def self.w130_test_object_preflight(rows : UInt64, remaining_bytes : UInt64) : UInt64
    ObjectColumnAdapter.preflight_owner(rows, remaining_bytes)
  end

  def self.w130_test_object_materialize(
    reader : ObjectColumnReader,
    mark_index : Int32,
    rows : UInt64,
    remaining_bytes : UInt64,
  ) : {Array(ObjectDocument), UInt64}
    ObjectColumnAdapter.materialize_mark(reader, mark_index, rows, remaining_bytes)
  end
end

describe "W130 Object mark ownership adapter" do
  it "preflights a conservative row-handle base and admits the complete pending mark atomically" do
    with_w130_budget_reader do |reader, _second_reader|
      rows = reader.mark_row_counts[0]
      base_bytes = CrystalClick::WidePartTable.w130_test_object_preflight(rows, 1_000_000_u64)
      base_bytes.should be > 0_u64
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartTable.w130_test_object_preflight(rows, base_bytes - 1_u64)
      end

      documents, complete_charge = CrystalClick::WidePartTable.w130_test_object_materialize(
        reader, 0, rows, 1_000_000_u64
      )
      documents.size.to_u64.should eq(rows)
      complete_charge.should be > base_bytes

      # This limit admits the row-handle base but not both decoded owners. The
      # adapter must reject the pending mark before it can be exposed.
      pending_limit = complete_charge - 1_u64
      pending_limit.should be >= base_bytes
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartTable.w130_test_object_materialize(reader, 0, rows, pending_limit)
      end
    end
  end

  it "shares the remaining logical mark budget across sequential Object lanes" do
    with_w130_budget_reader do |reader, second_reader|
      rows = reader.mark_row_counts[0]
      _first_documents, first_charge = CrystalClick::WidePartTable.w130_test_object_materialize(
        reader, 0, rows, 1_000_000_u64
      )
      _second_documents, second_charge = CrystalClick::WidePartTable.w130_test_object_materialize(
        second_reader, 0, rows, 1_000_000_u64
      )

      combined_limit = first_charge + second_charge - 1_u64
      _documents, observed_first_charge = CrystalClick::WidePartTable.w130_test_object_materialize(
        reader, 0, rows, combined_limit
      )
      observed_first_charge.should eq(first_charge)
      remaining = combined_limit - observed_first_charge
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartTable.w130_test_object_materialize(second_reader, 0, rows, remaining)
      end
    end
  end
end
