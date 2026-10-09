require "./spec_helper"

private def w240_inline_schedule_fixture(
  nested : Bool = false,
  profile : CrystalClick::BinaryBulkProfile = CrystalClick::BinaryBulkProfile.single_stream,
)
  string = CrystalClick::BinaryDataType.primitive("String")
  bool = CrystalClick::BinaryDataType.primitive("Bool")
  variant = CrystalClick::BinaryDataType.variant([bool, string])
  dictionary = CrystalClick::BinaryDataType.low_cardinality(string)
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new(["z"]),
    {"z" => CrystalClick::DynamicStructure.new([string])},
  )
  plan = CrystalClick::ObjectDocumentPlan.new(
    structures, {"b" => dictionary, "a" => variant},
  )
  granules = [[CrystalClick::ObjectDocument.new({
    "a" => CrystalClick::BinaryValue.variant(variant, 0, CrystalClick::BinaryValue.bool(true)),
    "b" => CrystalClick::BinaryValue.low_cardinality(dictionary, CrystalClick::BinaryValue.string("dictionary")),
    "z" => CrystalClick::BinaryValue.string("ordinary"),
  })]]
  budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
  grid = CrystalClick::StorageOccurrenceGrid.new([1_u64], [1_u64], budget)
  streams = if nested
              context = CrystalClick::ObjectSharedNestedSerializationContext.for_write(
                0_u64, 2_i32, profile,
              )
              CrystalClick::ObjectDocumentCodec.encode_child_site_with_nested_context_and_budget(
                plan, granules, grid, budget, context,
              )
            else
              CrystalClick::ObjectDocumentCodec.encode_child_site_with_budget(
                plan, granules, grid, budget, profile: profile)
            end
  physical = CrystalClick::ObjectDocumentPhysicalPlan.from_escaped_prefix(".child", plan, profile)
  {plan, streams, grid, budget, physical}
end

describe "W240 source-authored inline Object schedule adversary" do
  it "keeps typed recursive prefixes ahead of each Dynamic structure and Variant prefix" do
    plan, streams, grid, budget, physical = w240_inline_schedule_fixture
    prefixes, _bodies = CrystalClick::ObjectDocumentColumnWriter.inline_fragments_at_child_site(
      physical, plan, streams, grid, budget,
    )

    # Object.cpp:336,488-506; Dynamic.cpp:190,322; Variant.cpp:204,223.
    # This literal distinguishes native callback order from Wide LaneBinder
    # order even if a paired local reader accepts the latter.
    prefixes.map(&.[0]).should eq([
      ".child.object_structure",
      ".child.a.variant_discr_prefix",
      ".child.b.dict_prefix",
      ".child.z.dynamic_structure",
      ".child.z.variant_discr_prefix",
    ])
  end

  it "writes typed bodies before Dynamic bodies and shared MAP in descriptor order" do
    plan, streams, grid, budget, physical = w240_inline_schedule_fixture
    _prefixes, bodies = CrystalClick::ObjectDocumentColumnWriter.inline_fragments_at_child_site(
      physical, plan, streams, grid, budget,
    )

    # Object.cpp:917-943 and the child serializers determine body order;
    # neither sorted filenames nor sorted logical role names determine it.
    bodies.map(&.[0]).should eq([
      ".child.a.variant_discr",
      ".child.a.Bool",
      ".child.a.String",
      ".child.b.dict",
      ".child.b",
      ".child.z.variant_discr",
      ".child.z.SharedVariant",
      ".child.z.String",
      ".child.object_shared_data.size0",
      ".child.object_shared_data%2Epaths",
      ".child.object_shared_data%2Evalues",
    ])
  end

  it "omits Wide statistics flags and suffixes from inline metadata prefixes" do
    plan, streams, grid, budget, physical = w240_inline_schedule_fixture
    prefixes, bodies = CrystalClick::ObjectDocumentColumnWriter.inline_fragments_at_child_site(
      physical, plan, streams, grid, budget,
    )
    metadata = prefixes.to_h
    object_offset = streams.structures.object_statistics_offset.not_nil!
    dynamic_offset = streams.structures.dynamic_statistics_offset("z").not_nil!
    metadata[".child.object_structure"].should eq(streams.structures.borrowed_object[0, object_offset])
    metadata[".child.z.dynamic_structure"].should eq(streams.structures.borrowed_dynamic("z")[0, dynamic_offset])
    bodies.map(&.[0]).should_not contain(".child.object_structure")
    bodies.map(&.[0]).should_not contain(".child.z.dynamic_structure")
  end

  it "uses Compact discriminator framing independently of the String profile" do
    plan, streams, grid, budget, physical = w240_inline_schedule_fixture(nested: true)
    prefixes, _bodies = CrystalClick::ObjectDocumentColumnWriter.inline_fragments_at_child_site(
      physical, plan, streams, grid, budget,
    )
    metadata = prefixes.to_h
    # SharedData.cpp:381 forces Compact discriminators. The String profile
    # remains independently inherited through serialization-info settings.
    compact = Bytes[1, 0, 0, 0, 0, 0, 0, 0]
    metadata[".child.a.variant_discr_prefix"].should eq(compact)
    metadata[".child.z.variant_discr_prefix"].should eq(compact)
  end

  it "inherits String1 for ordinary fields but retains String0 for internal shared MAP lanes" do
    plan, streams, grid, budget, physical = w240_inline_schedule_fixture(
      nested: true, profile: CrystalClick::BinaryBulkProfile.with_size_stream,
    )
    _prefixes, bodies = CrystalClick::ObjectDocumentColumnWriter.inline_fragments_at_child_site(
      physical, plan, streams, grid, budget,
      profile: CrystalClick::BinaryBulkProfile.with_size_stream,
    )
    names = bodies.map(&.[0])
    names.should contain(".child.a.String.size")
    names.should contain(".child.z.String.size")
    names.should contain(".child.z.SharedVariant.size")
    # SharedData.cpp:48 -> IDataType.cpp:456 -> InfoSettings.h:23 chooses the
    # default String serializer for this internal Map, not inherited String1.
    names.should_not contain(".child.object_shared_data%2Epaths.size")
    names.should_not contain(".child.object_shared_data%2Evalues.size")
  end

  it "uses the caller's read-direction budget for the same callback schedule" do
    plan, _streams, _grid, _writer_budget, physical = w240_inline_schedule_fixture
    budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, false)
    CrystalClick::ObjectDocumentInlineCallbackOrder.prefix_names(physical, plan, budget).should eq([
      ".child.object_structure", ".child.a.variant_discr_prefix", ".child.b.dict_prefix",
      ".child.z.dynamic_structure", ".child.z.variant_discr_prefix",
    ])
    budget.writing?.should be_false
    budget.node_count.should be > 0
    budget.wire_byte_count.should be > 0

    limits = CrystalClick::BinaryCodecLimits.new(64, 4096, 1_000_000, 0)
    exhausted = CrystalClick::BinaryCodecBudget.new(limits, false)
    expect_raises(CrystalClick::CorruptPartError, "byte limit exceeded") do
      CrystalClick::ObjectDocumentInlineCallbackOrder.prefix_names(physical, plan, exhausted)
    end
  end

  it "preserves root Dynamic discriminator and canonical arm identity when normalizing callbacks" do
    plan, _streams, _grid, _writer_budget, physical = w240_inline_schedule_fixture
    budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, false)
    bindings = CrystalClick::ObjectDocumentInlineCallbackOrder.body_lane_bindings(
      physical, plan, CrystalClick::BinaryBulkProfile.single_stream, budget,
    )
    bindings.select { |binding| binding[1] == :root_dynamic }.should eq([
      {".child.z.variant_discr", :root_dynamic, "z", "root.discriminators"},
      {".child.z.SharedVariant", :root_dynamic, "z", "root.arm.0.data"},
      {".child.z.String", :root_dynamic, "z", "root.arm.1.data"},
    ])
  end

  it "preserves Tuple declaration order and String sizes-before-data order" do
    string = CrystalClick::BinaryDataType.primitive("String")
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    tuple = CrystalClick::BinaryDataType.tuple([string, uint8], ["z", "a"])
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(structures, {"t" => tuple})
    value = CrystalClick::BinaryValue.tuple(tuple, [
      CrystalClick::BinaryValue.string("first"),
      CrystalClick::BinaryValue.fixed(uint8, Bytes[7]),
    ] of CrystalClick::BinaryValue)
    granules = [[CrystalClick::ObjectDocument.new({"t" => value})]]
    budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true)
    grid = CrystalClick::StorageOccurrenceGrid.new([1_u64], [1_u64], budget)
    profile = CrystalClick::BinaryBulkProfile.with_size_stream
    streams = CrystalClick::ObjectDocumentCodec.encode_child_site_with_budget(
      plan, granules, grid, budget, profile: profile)
    physical = CrystalClick::ObjectDocumentPhysicalPlan.from_escaped_prefix(".child", plan, profile)
    _prefixes, bodies = CrystalClick::ObjectDocumentColumnWriter.inline_fragments_at_child_site(
      physical, plan, streams, grid, budget, profile: profile)
    # ISerialization.cpp:340-350 escapes the Tuple separator itself, including
    # the paths/values Tuple used internally by shared MAP serialization.
    bodies.map(&.[0]).should eq([
      ".child.t%2Ez.size", ".child.t%2Ez", ".child.t%2Ea",
      ".child.object_shared_data.size0",
      ".child.object_shared_data%2Epaths",
      ".child.object_shared_data%2Evalues",
    ])
  end
end
