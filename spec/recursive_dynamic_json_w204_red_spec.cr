require "./spec_helper"

private def w204_red_object_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    schema.typed_paths,
  )
end

describe "W204 mixed recursive JSON/Dynamic planner transition" do
  it "retains the baseline rejection when a declared Dynamic site has no prepared write plan" do
    json_schema = CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(t UInt8)")
    schema = CrystalClick::StorageColumnSchema.parse(
      "Tuple(doc JSON(t UInt8), d Dynamic(max_types=1))"
    )
    object_plan = w204_red_object_plan(json_schema)

    expect_raises(ArgumentError) do
      CrystalClick::RecursiveStorageColumnPlan.for_column(
        "payload", schema, {"root/tuple[0]" => object_plan}
      )
    end
  end

  it "binds the legal Dynamic child when its exact recursive site plan is supplied" do
    json_schema = CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(t UInt8)")
    schema = CrystalClick::StorageColumnSchema.parse(
      "Tuple(doc JSON(t UInt8), d Dynamic(max_types=1))"
    )
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    object_plan = w204_red_object_plan(json_schema)
    dynamic_plan = CrystalClick::BinaryDynamicBulkPlan.new(
      dynamic,
      {"root" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType)},
    )

    plan = CrystalClick::RecursiveStorageColumnPlan.for_column(
      "payload",
      schema,
      {"root/tuple[0]" => object_plan},
      dynamic_plans: {"root/tuple[1]" => dynamic_plan},
    )
    plan.object_site_count.should eq(1)
    plan.dynamic_site_count.should eq(1)
    plan.physical_stream_names.should contain("payload%2Ed.dynamic_structure")
  end
end
