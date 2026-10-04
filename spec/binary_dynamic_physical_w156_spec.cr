require "./spec_helper"

describe "W156 Dynamic physical bindings" do
  it "keeps Map size streams sibling to an escaped Dynamic value role" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    map = CrystalClick::BinaryDataType.map(
      CrystalClick::BinaryDataType.primitive("UInt64"),
      dynamic,
    )
    prepared = CrystalClick::BinaryDynamicBulkPlan.new(map, {
      "root.elements.field.1" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
    })

    physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(prepared, "m")
    physical.stream_names.should eq({
      "root.sizes"                              => "m.size0",
      "root.elements.field.0.data"              => "m%2Ekeys",
      "root.elements.field.1.discriminators"    => "m%2Evalues.variant_discr",
      "root.elements.field.1.arm.0.data"        => "m%2Evalues.SharedVariant",
      "root.elements.field.1.dynamic_structure" => "m%2Evalues.dynamic_structure",
    })
    physical.prefix_size_for("root.elements.field.1.discriminators").should eq(8)
    physical.prefix_size_for("root.elements.field.1.arm.0.data").should eq(0)
    expect_raises(KeyError) do
      physical.prefix_size_for("root.elements.field.1.dynamic_structure")
    end
  end

  it "uses canonical actual roster names and preserves LC prefix ownership under WithSize" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    low_cardinality = CrystalClick::BinaryDataType.low_cardinality(
      CrystalClick::BinaryDataType.primitive("String"),
    )
    prepared = CrystalClick::BinaryDynamicBulkPlan.new(
      dynamic,
      {"root" => CrystalClick::DynamicStructure.new([low_cardinality] of CrystalClick::BinaryDataType)},
      CrystalClick::BinaryBulkProfile.with_size_stream,
    )

    prepared.shared_index("root").should eq(1)
    prepared.arm_type("root", 0).should eq(low_cardinality)
    physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(prepared, "state")
    physical.stream_names.should eq({
      "root.discriminators"     => "state.variant_discr",
      "root.arm.0.dictionary"   => "state.LowCardinality%28String%29.dict",
      "root.arm.0.indexes"      => "state.LowCardinality%28String%29",
      "root.arm.1.data"         => "state.SharedVariant",
      "root.arm.1.string_sizes" => "state.SharedVariant.size",
      "root.dynamic_structure"  => "state.dynamic_structure",
    })
    physical.prefix_size_for("root.discriminators").should eq(8)
    physical.prefix_size_for("root.arm.0.dictionary").should eq(8)
    physical.prefix_size_for("root.arm.0.indexes").should eq(0)
    physical.prefix_size_for("root.arm.1.data").should eq(0)
    physical.prefix_size_for("root.arm.1.string_sizes").should eq(0)
    physical.stream_names.has_key?("root.arm.0.string_sizes").should be_false
  end

  it "keeps Nullable's null lane sibling while recursing into named Tuple fields" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    string = CrystalClick::BinaryDataType.primitive("String")
    tuple = CrystalClick::BinaryDataType.tuple(
      [dynamic, string] of CrystalClick::BinaryDataType,
      ["payload.value", "plain"] of String,
    )
    nullable = CrystalClick::BinaryDataType.nullable(tuple)
    prepared = CrystalClick::BinaryDynamicBulkPlan.new(nullable, {
      "root.nested.field.0" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType),
    }, CrystalClick::BinaryBulkProfile.with_size_stream)

    physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(prepared, "row")
    physical.stream_names.should eq({
      "root.nulls"                             => "row.null",
      "root.nested.field.0.discriminators"     => "row%2Epayload%2Evalue.variant_discr",
      "root.nested.field.0.arm.0.data"         => "row%2Epayload%2Evalue.SharedVariant",
      "root.nested.field.0.arm.0.string_sizes" => "row%2Epayload%2Evalue.SharedVariant.size",
      "root.nested.field.0.arm.1.data"         => "row%2Epayload%2Evalue.UInt64",
      "root.nested.field.0.dynamic_structure"  => "row%2Epayload%2Evalue.dynamic_structure",
      "root.nested.field.1.data"               => "row%2Eplain",
      "root.nested.field.1.string_sizes"       => "row%2Eplain.size",
    })
    physical.prefix_size_for("root.nested.field.0.discriminators").should eq(8)
    physical.prefix_size_for("root.nested.field.0.arm.1.data").should eq(0)
  end

  it "accepts only validated escaped prefixes at the composition boundary" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    prepared = CrystalClick::BinaryDynamicBulkPlan.new(dynamic, {
      "root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
    })

    physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.from_escaped_prefix(prepared, "outer%2Einner")
    physical.stream_name_for("root.arm.0.data").should eq("outer%2Einner.SharedVariant")
    physical.structure_name_for("root").should eq("outer%2Einner.dynamic_structure")

    expect_raises(ArgumentError) do
      CrystalClick::BinaryDynamicBulkPhysicalPlan.from_escaped_prefix(prepared, "outer%2einner")
    end
  end
end
