require "./spec_helper"

module CompactTypedDynamicReadBindingW270Fixture
  extend self

  SITE = "root.elements"

  def limits : CrystalClick::BinaryCodecLimits
    CrystalClick::BinaryCodecLimits.default
  end

  def primitive(name : String) : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive(name)
  end

  def dynamic(max_types : Int = 2) : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.dynamic(max_types: max_types)
  end

  def array_dynamic(max_types : Int = 2) : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.array(dynamic(max_types))
  end

  def structure(
    types : Array(CrystalClick::BinaryDataType),
    version : UInt64 = CrystalClick::DynamicStructure::VERSION_V3,
    legacy_cap : UInt64? = nil,
  ) : CrystalClick::DynamicStructure
    shape = CrystalClick::DynamicStructure.new(
      types,
      nil,
      version: version,
      legacy_max_dynamic_types: legacy_cap,
    )
    counts = Array(UInt64).new(shape.canonical_variant_count) do |index|
      101_u64 + index.to_u64
    end
    statistics = CrystalClick::StructureStatistics.new(
      counts,
      [] of CrystalClick::StructureStatistic,
    )
    CrystalClick::DynamicStructure.new(
      types,
      statistics,
      version: version,
      legacy_max_dynamic_types: legacy_cap,
    )
  end

  def sites(
    path : String,
    structure : CrystalClick::DynamicStructure,
  ) : Hash(String, CrystalClick::DynamicStructure)
    {path => structure} of String => CrystalClick::DynamicStructure
  end

  def write_plan(
    type : CrystalClick::BinaryDataType,
    structures : Hash(String, CrystalClick::DynamicStructure),
    profile : CrystalClick::BinaryBulkProfile = CrystalClick::BinaryBulkProfile.single_stream,
    root_depth : Int = 2,
  ) : CrystalClick::BinaryDynamicBulkPlan
    CrystalClick::ObjectDeclaredDynamicDeclaration.prepare_write_sites_plan(
      type,
      structures,
      CrystalClick::BinaryCodecBudget.new(limits, true),
      profile,
      root_depth,
    )
  end

  def physical(
    type : CrystalClick::BinaryDataType,
    structures : Hash(String, CrystalClick::DynamicStructure),
    profile : CrystalClick::BinaryBulkProfile = CrystalClick::BinaryBulkProfile.single_stream,
    root_depth : Int = 2,
  ) : CrystalClick::BinaryDynamicBulkPhysicalPlan
    prepared = write_plan(type, structures, profile, root_depth)
    CrystalClick::BinaryDynamicBulkPhysicalPlan.new(
      prepared,
      "layout_binding_w270",
      limits,
      initial_descriptor_depth: root_depth.to_i32,
    )
  end

  def read_plan(
    type : CrystalClick::BinaryDataType,
    structures : Hash(String, CrystalClick::DynamicStructure),
    profile : CrystalClick::BinaryBulkProfile = CrystalClick::BinaryBulkProfile.single_stream,
    root_depth : Int = 2,
  ) : CrystalClick::BinaryDynamicBulkPlan
    full_source = CrystalClick::BinaryDynamicBulkPlan.new(type, structures, profile, limits)
    streams = full_source.encode_structure_streams(
      CrystalClick::BinaryCodecBudget.new(limits, true),
    )
    CrystalClick::ObjectDeclaredDynamicDeclaration.prepare_read_sites_plan(
      type,
      streams,
      CrystalClick::BinaryCodecBudget.new(limits, false),
      profile,
      root_depth,
    )
  end
end

describe CrystalClick::BinaryDynamicBulkPhysicalPlan do
  it "binds a full-statistics read prefix to an independently prepared no-statistics physical plan" do
    fixture = CompactTypedDynamicReadBindingW270Fixture
    site = CompactTypedDynamicReadBindingW270Fixture::SITE
    type = fixture.array_dynamic
    structures = fixture.sites(
      site,
      fixture.structure([fixture.primitive("UInt8")] of CrystalClick::BinaryDataType),
    )

    write_plan = fixture.write_plan(type, structures)
    write_plan.structure_for(site).statistics.should be_nil
    physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(
      write_plan,
      "layout_binding_w270",
      fixture.limits,
      initial_descriptor_depth: 2,
    )

    read_plan = fixture.read_plan(type, structures)
    read_plan.structure_for(site).statistics.not_nil!.counts.should eq([101_u64, 102_u64])
    read_plan.statistics_offset_for(site).should be >= 0
    physical.same_prepared_plan?(read_plan).should be_false
    physical.same_prepared_layout?(read_plan).should be_true
  end

  it "rejects changed actual descriptors, roster order, root descriptors, profiles, and site depth" do
    fixture = CompactTypedDynamicReadBindingW270Fixture
    site = CompactTypedDynamicReadBindingW270Fixture::SITE
    uint8 = fixture.primitive("UInt8")
    int8 = fixture.primitive("Int8")
    string = fixture.primitive("String")
    type = fixture.array_dynamic
    original = fixture.sites(site, fixture.structure([uint8] of CrystalClick::BinaryDataType))
    physical = fixture.physical(type, original)

    changed_actual = fixture.sites(site, fixture.structure([int8] of CrystalClick::BinaryDataType))
    physical.data_stream_names.keys.sort.should eq(fixture.read_plan(type, changed_actual).data_roles.sort)
    physical.same_prepared_layout?(fixture.read_plan(type, changed_actual)).should be_false

    ordered = fixture.sites(
      site,
      fixture.structure([uint8, string] of CrystalClick::BinaryDataType),
    )
    reordered = fixture.sites(
      site,
      fixture.structure([string, uint8] of CrystalClick::BinaryDataType),
    )
    ordered_physical = fixture.physical(type, ordered)
    reordered_read = fixture.read_plan(type, reordered)
    ordered_physical.data_stream_names.keys.sort.should eq(reordered_read.data_roles.sort)
    ordered_physical.same_prepared_layout?(reordered_read).should be_false

    wider_root = fixture.array_dynamic(3)
    physical.same_prepared_layout?(fixture.read_plan(wider_root, original)).should be_false

    size_profile_read = fixture.read_plan(
      type,
      fixture.sites(site, fixture.structure([string] of CrystalClick::BinaryDataType)),
      CrystalClick::BinaryBulkProfile.with_size_stream,
    )
    physical.same_prepared_layout?(size_profile_read).should be_false

    nested_type = CrystalClick::BinaryDataType.array(fixture.array_dynamic)
    nested_path = "root.elements.elements"
    nested_read = fixture.read_plan(
      nested_type,
      fixture.sites(nested_path, fixture.structure([uint8] of CrystalClick::BinaryDataType)),
    )
    physical.same_prepared_layout?(nested_read).should be_false
  end

  it "rejects changed Dynamic versions and the V1 legacy cap" do
    fixture = CompactTypedDynamicReadBindingW270Fixture
    site = CompactTypedDynamicReadBindingW270Fixture::SITE
    type = fixture.array_dynamic
    uint8 = fixture.primitive("UInt8")
    v3_physical = fixture.physical(
      type,
      fixture.sites(site, fixture.structure([uint8] of CrystalClick::BinaryDataType)),
    )
    v2_read = fixture.read_plan(
      type,
      fixture.sites(
        site,
        fixture.structure(([uint8] of CrystalClick::BinaryDataType), CrystalClick::DynamicStructure::VERSION_V2),
      ),
    )
    v3_physical.same_prepared_layout?(v2_read).should be_false

    v1_physical = fixture.physical(
      type,
      fixture.sites(
        site,
        fixture.structure(([uint8] of CrystalClick::BinaryDataType), CrystalClick::DynamicStructure::VERSION_V1, 17_u64),
      ),
    )
    other_cap_read = fixture.read_plan(
      type,
      fixture.sites(
        site,
        fixture.structure(([uint8] of CrystalClick::BinaryDataType), CrystalClick::DynamicStructure::VERSION_V1, 18_u64),
      ),
    )
    v1_physical.same_prepared_layout?(other_cap_read).should be_false
  end

  it "fails closed when either plan owns a Dynamic-to-Object JSON binding" do
    fixture = CompactTypedDynamicReadBindingW270Fixture
    dynamic = fixture.dynamic(1)
    uint8 = fixture.primitive("UInt8")
    physical = fixture.physical(
      dynamic,
      fixture.sites("root", fixture.structure([uint8] of CrystalClick::BinaryDataType)),
    )

    json = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {"value" => uint8} of String => CrystalClick::BinaryDataType,
    )
    json_structure = fixture.structure([json] of CrystalClick::BinaryDataType)
    child_structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      Hash(String, CrystalClick::DynamicStructure).new,
    )
    child_plan = CrystalClick::ObjectDocumentPlan.new(
      child_structures,
      json.json_type.not_nil!.typed_paths,
    )
    binding = {
      CrystalClick::BinaryDynamicJsonLeafKey.new(
        "root",
        json_structure.canonical_index_for(json),
        [] of Int32,
      ),
      child_plan,
    }
    bindings = [binding] of Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan)
    json_bound_plan = CrystalClick::ObjectDeclaredDynamicDeclaration.prepare_write_sites_plan(
      dynamic,
      fixture.sites("root", json_structure),
      CrystalClick::BinaryCodecBudget.new(fixture.limits, true),
      CrystalClick::BinaryBulkProfile.single_stream,
      2,
      bindings,
    )

    json_bound_plan.has_json_object_bindings?.should be_true
    physical.same_prepared_layout?(json_bound_plan).should be_false
  end
end
