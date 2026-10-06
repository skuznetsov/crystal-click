require "./spec_helper"

private def w187_frame_limits(
  max_nodes : Int64 = 4_096_i64,
  max_elements : Int64 = 8_192_i64,
  max_bytes : Int64 = 1_048_576_i64,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(16, max_nodes, max_elements, max_bytes)
end

private def w187_recursive_object_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    schema.typed_paths,
  )
end

describe "W187 common Array/Tuple storage schema" do
  it "admits Array(JSON) through the common recursive owner" do
    source = "Array(JSON(t UInt8))"
    CrystalClick::StorageColumnSchema.parse(source).declaration.should eq(source)
  end

  it "admits an Array of Tuple with independently addressed JSON leaves" do
    source = "Array(Tuple(l JSON(t UInt8), r JSON(t UInt8), n UInt64))"
    CrystalClick::StorageColumnSchema.parse(source).declaration.should eq(source)
  end

  it "composes repeated Array edges rather than a separate product codec" do
    source = "Tuple(items Array(Array(Tuple(doc JSON(t UInt8), n UInt64))))"
    CrystalClick::StorageColumnSchema.parse(source).declaration.should eq(source)
  end

  it "preserves ordinary Tuple admission and rejects JSON-free recursive roots" do
    source = "Tuple(doc JSON(t UInt8), n UInt64)"
    CrystalClick::StorageColumnSchema.parse(source).declaration.should eq(source)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::StorageColumnSchema.parse("Array(UInt8)")
    end
  end

  it "rejects COMPACT Array composition before payload encoding while admitting BASIC" do
    object_schema = CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(t UInt8)")
    schema = CrystalClick::StorageColumnSchema.parse("Array(#{object_schema.declaration})")
    plans = {"root/array[0]" => w187_recursive_object_plan(object_schema)}

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::RecursiveStorageColumnPlan.for_column(
        "payload", schema, plans,
        mode: CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE,
      )
    end
    plan = CrystalClick::RecursiveStorageColumnPlan.for_column(
      "payload", schema, plans,
      mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
    )
    plan.array_site_count.should eq(1)
  end

  it "accepts valid same-total per-parent size redistributions as distinct Array values" do
    physical = [2_u64]
    parents = [2_u64]
    first_sizes = [[0_u64, 2_u64]] of Array(UInt64)
    second_sizes = [[1_u64, 1_u64]] of Array(UInt64)
    first = CrystalClick::StorageArrayOccurrenceFrame.for_write(
      0_u64, physical, parents, first_sizes, CrystalClick::BinaryCodecBudget.new(w187_frame_limits, true)
    )
    second = CrystalClick::StorageArrayOccurrenceFrame.for_write(
      0_u64, physical, parents, second_sizes, CrystalClick::BinaryCodecBudget.new(w187_frame_limits, true)
    )

    first.child_count_at(0).should eq(2_u64)
    second.child_count_at(0).should eq(2_u64)
    {first.size_at(0, 0), first.size_at(0, 1)}.should eq({0_u64, 2_u64})
    {second.size_at(0, 0), second.size_at(0, 1)}.should eq({1_u64, 1_u64})
  end

  it "detaches its complete parent schedule from mutable caller arrays" do
    physical = [1_u64]
    parents = [2_u64]
    sizes = [[0_u64, 2_u64]] of Array(UInt64)
    frame = CrystalClick::StorageArrayOccurrenceFrame.for_write(
      0_u64, physical, parents, sizes, CrystalClick::BinaryCodecBudget.new(w187_frame_limits, true)
    )

    physical[0] = 9_u64
    parents[0] = 1_u64
    sizes[0][0] = 1_u64
    frame.physical_rows_at(0).should eq(1_u64)
    frame.parent_count_at(0).should eq(2_u64)
    frame.child_count_at(0).should eq(2_u64)
    frame.size_at(0, 0).should eq(0_u64)
  end

  it "preflights frame nodes, elements, and wire bytes at exact boundaries" do
    physical = [1_u64]
    parents = [1_u64]
    sizes = [[2_u64]] of Array(UInt64)
    exact = CrystalClick::BinaryCodecBudget.new(w187_frame_limits(7_i64, 7_i64, 8_i64), true)
    frame = CrystalClick::StorageArrayOccurrenceFrame.for_write(0_u64, physical, parents, sizes, exact)
    frame.size_at(0, 0).should eq(2_u64)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::StorageArrayOccurrenceFrame.for_write(
        0_u64, physical, parents, sizes,
        CrystalClick::BinaryCodecBudget.new(w187_frame_limits(6_i64, 7_i64, 8_i64), true)
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::StorageArrayOccurrenceFrame.for_write(
        0_u64, physical, parents, sizes,
        CrystalClick::BinaryCodecBudget.new(w187_frame_limits(7_i64, 6_i64, 8_i64), true)
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::StorageArrayOccurrenceFrame.for_write(
        0_u64, physical, parents, sizes,
        CrystalClick::BinaryCodecBudget.new(w187_frame_limits(7_i64, 7_i64, 7_i64), true)
      )
    end
  end

  it "rejects a nested Array schedule with a parent-count mismatch" do
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::StorageArrayOccurrenceFrame.for_write(
        1_u64,
        [2_u64],
        [2_u64],
        [[1_u64]] of Array(UInt64),
        CrystalClick::BinaryCodecBudget.new(w187_frame_limits, true)
      )
    end
  end
end
