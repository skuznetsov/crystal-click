require "./spec_helper"

describe "W185 Array(JSON) core composition" do
  it "unwraps Array(JSON) declarations by byte boundaries without losing Unicode enum labels" do
    enum_type = CrystalClick::BinaryDataType.enum8([
      {"café", 1_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry)
    schema = CrystalClick::ObjectDocumentSchema.new({"state" => enum_type})
    declaration = "Array(#{schema.declaration})"

    parsed = CrystalClick::ArrayObjectColumnReader.schema_for_source_declaration(declaration)
    parsed.should_not be_nil
    parsed.not_nil!.declaration.should eq(schema.declaration)
    parsed.not_nil!.typed_paths.should eq(schema.typed_paths)
  end

  it "threads the outer Array name level into nested typed lanes without spending logical depth twice" do
    limits = CrystalClick::BinaryCodecLimits.default
    element_type = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("String"))
    schema = CrystalClick::ObjectDocumentSchema.new({"items" => element_type}, limits: limits)
    plan = CrystalClick::ObjectDocumentPlan.new(
      CrystalClick::ObjectDynamicStructureSet.new(
        CrystalClick::ObjectStructure.new([] of String),
        {} of String => CrystalClick::DynamicStructure,
      ),
      schema.typed_paths,
    )

    physical = CrystalClick::ObjectDocumentPhysicalPlan.new(
      "a", plan, limits: limits, initial_array_level: 1_u64
    )
    physical.typed("items").stream_name_for("root.sizes").should eq("a.items.size1")

    # A level is a physical naming coordinate: level 1 remains legal with
    # zero remaining recursive depth for a scalar. An additional nested type
    # is still rejected by the logical type-depth validator.
    zero_depth = CrystalClick::BinaryCodecLimits.new(0, 64, 64, 4096)
    scalar = CrystalClick::BinaryBulkPhysicalPlan.from_escaped_prefix(
      CrystalClick::BinaryDataType.primitive("UInt8"),
      "a.t",
      limits: zero_depth,
      initial_array_level: 1_u64,
    )
    scalar.stream_name_for("root.data").should eq("a.t")
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkPhysicalPlan.from_escaped_prefix(
        CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("UInt8")),
        "a.t",
        limits: zero_depth,
        initial_array_level: 1_u64,
      )
    end
  end

  it "charges all-empty parent rows to one aggregate writer budget before flattening" do
    limits = CrystalClick::BinaryCodecLimits.new(8, 16, 512, 65_536)
    schema = CrystalClick::ObjectDocumentSchema.new(
      {"t" => CrystalClick::BinaryDataType.primitive("UInt8")},
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      limits: limits,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(
      CrystalClick::ObjectDynamicStructureSet.new(
        CrystalClick::ObjectStructure.new([] of String),
        {} of String => CrystalClick::DynamicStructure,
      ),
      schema.typed_paths,
    )
    # No inner documents exist to make child cardinality proportional to P;
    # the outer parent schedule alone must still consume the caller's budget.
    empty_parents = Array(Array(CrystalClick::ObjectDocument)).new(64) do
      [] of CrystalClick::ObjectDocument
    end
    granules = [empty_parents] of Array(Array(CrystalClick::ObjectDocument))

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ArrayObjectColumnWriter.encode("a", plan, granules, limits: limits)
    end

    sufficient_limits = CrystalClick::BinaryCodecLimits.new(8, 4096, 4096, 65_536)
    sufficient_schema = CrystalClick::ObjectDocumentSchema.new(
      {"t" => CrystalClick::BinaryDataType.primitive("UInt8")},
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      limits: sufficient_limits,
    )
    sufficient_plan = CrystalClick::ObjectDocumentPlan.new(
      CrystalClick::ObjectDynamicStructureSet.new(
        CrystalClick::ObjectStructure.new([] of String),
        {} of String => CrystalClick::DynamicStructure,
      ),
      sufficient_schema.typed_paths,
    )
    files = CrystalClick::ArrayObjectColumnWriter.encode(
      "a", sufficient_plan, granules, limits: sufficient_limits
    )
    files.stream_names.should contain("a.size0")
  end
end
