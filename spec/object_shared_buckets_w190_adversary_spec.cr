require "./spec_helper"

private def w190_adversary_bucket_plan(count : UInt64) : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String, shared_data_version: 1_u64, bucket_count: count),
      {} of String => CrystalClick::DynamicStructure,
    ),
    {"t" => CrystalClick::BinaryDataType.primitive("UInt8")},
  )
end

describe "W190 root-authored shared bucket adversaries" do
  it "preserves exact escaped-site and inherited Array coordinates" do
    physical = CrystalClick::ObjectDocumentPhysicalPlan.from_escaped_prefix(
      "pair%2Eleft", w190_adversary_bucket_plan(2_u64), initial_array_level: 4_u64,
    )
    names = physical.stream_names
    names.includes?("pair%2Eleft.object_shared_data.0.size4").should be_true
    names.includes?("pair%2Eleft.object_shared_data.1.size4").should be_true
    names.includes?("pair%252Eleft.object_shared_data.0.size4").should be_false
    names.includes?("pair%2Eleft.object_shared_data.size4.0").should be_false
    expect_raises(ArgumentError) { physical.shared }
  end

  it "rejects one misplaced entry despite valid map bytes, sorted paths, totals and grids" do
    # Independent native hash captures establish alpha % 2 == 1 and aa % 2 == 0.
    documents = [
      CrystalClick::ObjectDocument.new({
        "t" => CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[7_u8]),
        "aa" => CrystalClick::BinaryValue.string("even"),
        "alpha" => CrystalClick::BinaryValue.string("odd"),
      } of String => CrystalClick::BinaryValue),
      CrystalClick::ObjectDocument.new({
        "t" => CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[9_u8]),
        "alpha" => CrystalClick::BinaryValue.string("untouched"),
      } of String => CrystalClick::BinaryValue),
    ]
    source = CrystalClick::ObjectDocumentCodec.encode(w190_adversary_bucket_plan(2_u64), [documents])
    string = CrystalClick::BinaryDataType.primitive("String")
    map_type = CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.tuple([string, string], ["paths", "values"] of String),
    )
    zero = CrystalClick::BinaryBulkCodec.decode(map_type, source.shared_bucket(0), [2_u64])
    one = CrystalClick::BinaryBulkCodec.decode(map_type, source.shared_bucket(1), [2_u64])
    zero[0][0].element_at(0).element_at(0).as_string.should eq("aa")
    one[0][0].element_at(0).element_at(0).as_string.should eq("alpha")
    moved = one[0][0].element_at(0)
    zero[0][0] = CrystalClick::BinaryValue.array(map_type, zero[0][0].elements + [moved])
    one[0][0] = CrystalClick::BinaryValue.array(map_type, [] of CrystalClick::BinaryValue)
    # Only one entry moves; the second row and its original bucket are unchanged.
    zero[0][0].element_count.should eq(2)
    one[0][1].element_count.should eq(1)
    mutated = CrystalClick::ObjectDocumentStreams.new(
      source.structures, source.rows_per_mark, {"t" => source.typed_for("t")},
      {} of String => CrystalClick::DynamicValueStreams,
      [CrystalClick::BinaryBulkCodec.encode(map_type, zero), CrystalClick::BinaryBulkCodec.encode(map_type, one)],
    )
    expect_raises(CrystalClick::CorruptPartError, /bucket/) do
      CrystalClick::ObjectDocumentCodec.decode({"t" => CrystalClick::BinaryDataType.primitive("UInt8")}, mutated)
    end
  end

  it "retains distinct bucket counts for equal nominal JSON siblings in one plan" do
    schema = CrystalClick::StorageColumnSchema.parse("Tuple(l JSON(t UInt8), r JSON(t UInt8))")
    plans = {
      "root/tuple[0]" => w190_adversary_bucket_plan(1_u64),
      "root/tuple[1]" => w190_adversary_bucket_plan(32_u64),
    }
    recursive = CrystalClick::RecursiveStorageColumnPlan.for_column("payload", schema, plans)
    recursive.object_site_count.should eq(2)
    left = recursive.object_site_at(0)
    right = recursive.object_site_at(1)
    left.schema.declaration.should eq(right.schema.declaration)
    left.physical.shared_bucket_count.should eq(1)
    right.physical.shared_bucket_count.should eq(32)
    left.physical.stream_names.any? { |name| name.includes?(".31.") }.should be_false
    right.physical.stream_names.any? { |name| name.includes?(".31.") }.should be_true
  end
end
