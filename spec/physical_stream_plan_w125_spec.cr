require "./spec_helper"

describe "W125 generic physical stream plans" do
  it "binds recursive array and tuple roles without resetting array level" do
    string = CrystalClick::BinaryDataType.primitive("String")
    inner = CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.nullable(string))
    tuple = CrystalClick::BinaryDataType.tuple([inner, string], ["a.b", "plain"])
    type = CrystalClick::BinaryDataType.array(tuple)
    plan = CrystalClick::BinaryBulkPhysicalPlan.new(
      type, "col.name", profile: CrystalClick::BinaryBulkProfile.with_size_stream
    )
    plan.stream_names.should eq({
      "root.sizes"                                         => "col%2Ename.size0",
      "root.elements.field.0.sizes"                        => "col%2Ename%2Ea%2Eb.size1",
      "root.elements.field.0.elements.nulls"               => "col%2Ename%2Ea%2Eb.null",
      "root.elements.field.0.elements.nested.data"         => "col%2Ename%2Ea%2Eb",
      "root.elements.field.0.elements.nested.string_sizes" => "col%2Ename%2Ea%2Eb.size",
      "root.elements.field.1.data"                         => "col%2Ename%2Eplain",
      "root.elements.field.1.string_sizes"                 => "col%2Ename%2Eplain.size",
    })
  end

  it "uses BASIC Map keys and values while preserving descendant array depth" do
    string = CrystalClick::BinaryDataType.primitive("String")
    type = CrystalClick::BinaryDataType.map(string, CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.nullable(string)))
    plan = CrystalClick::BinaryBulkPhysicalPlan.new(type, "m", profile: CrystalClick::BinaryBulkProfile.with_size_stream)
    plan.stream_names.should eq({
      "root.sizes"                                         => "m.size0",
      "root.elements.field.0.data"                         => "m%2Ekeys",
      "root.elements.field.0.string_sizes"                 => "m%2Ekeys.size",
      "root.elements.field.1.sizes"                        => "m%2Evalues.size1",
      "root.elements.field.1.elements.nulls"               => "m%2Evalues.null",
      "root.elements.field.1.elements.nested.data"         => "m%2Evalues",
      "root.elements.field.1.elements.nested.string_sizes" => "m%2Evalues.size",
    })
  end

  it "numbers unnamed Tuple fields from one and retains empty Tuple lanes" do
    scalar = CrystalClick::BinaryDataType.primitive("UInt64")
    tuple = CrystalClick::BinaryDataType.tuple([CrystalClick::BinaryDataType.array(scalar), scalar])
    CrystalClick::BinaryBulkPhysicalPlan.new(tuple, "t").stream_names.should eq({
      "root.field.0.sizes"         => "t%2E1.size0",
      "root.field.0.elements.data" => "t%2E1",
      "root.field.1.data"          => "t%2E2",
    })
    empty = CrystalClick::BinaryDataType.tuple([] of CrystalClick::BinaryDataType)
    CrystalClick::BinaryBulkPhysicalPlan.new(empty, "empty").stream_names.should eq({"root.data" => "empty"})
  end

  it "escapes opaque raw column bytes exactly once before hashing" do
    type = CrystalClick::BinaryDataType.primitive("UInt8")
    plan = CrystalClick::BinaryBulkPhysicalPlan.new(type, "a.%/東京\0")
    expected = "a%2E%25%2F%E6%9D%B1%E4%BA%AC%00"
    plan.stream_name_for("root.data").should eq(expected)
    plan.data_file_for("root.data").should eq("#{expected}.bin")
    plan.marks_file_for("root.data").should eq("#{expected}.mrk2")
    plan.data_file_for("root.data", hashed: true).should eq("#{CrystalClick::StreamName.hash(expected)}.bin")
    plan.marks_file_for("root.data", hashed: true).should eq("#{CrystalClick::StreamName.hash(expected)}.mrk2")
  end

  it "keeps the explicitly supplied String layout separate from type identity" do
    string = CrystalClick::BinaryDataType.primitive("String")
    single = CrystalClick::BinaryBulkPhysicalPlan.new(string, "s")
    sized = CrystalClick::BinaryBulkPhysicalPlan.new(string, "s", profile: CrystalClick::BinaryBulkProfile.with_size_stream)
    single.stream_names.should eq({"root.data" => "s"})
    sized.stream_names.should eq({"root.data" => "s", "root.string_sizes" => "s.size"})
  end

  it "returns detached names and maps without changing retained bindings" do
    column = String.new("detached".to_slice)
    plan = CrystalClick::BinaryBulkPhysicalPlan.new(CrystalClick::BinaryDataType.primitive("String"), column)
    column.to_unsafe[0] = 'X'.ord.to_u8
    snapshot = plan.stream_names
    snapshot["root.data"].to_unsafe[0] = 'Y'.ord.to_u8
    snapshot.clear
    name = plan.stream_name_for("root.data")
    name.to_unsafe[0] = 'Z'.ord.to_u8
    plan.stream_names.should eq({"root.data" => "detached"})
  end

  it "rejects two distinct Tuple roles that render to the same physical name" do
    scalar = CrystalClick::BinaryDataType.primitive("UInt64")
    nested = CrystalClick::BinaryDataType.tuple([scalar], ["b"])
    type = CrystalClick::BinaryDataType.tuple([scalar, nested], ["a.b", "a"])
    expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::BinaryBulkPhysicalPlan.new(type, "collision") }
  end

  it "bounds descriptor depth and count-derived role work" do
    type = CrystalClick::BinaryDataType.primitive("UInt64")
    32.times { type = CrystalClick::BinaryDataType.array(type) }
    limits = CrystalClick::BinaryCodecLimits.new(max_depth: 8, max_nodes: 10_000, max_elements: 10_000, max_bytes: 1_000_000)
    expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::BinaryBulkPhysicalPlan.new(type, "deep", limits: limits) }
    expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::BinaryBulkPhysicalPlan.from_escaped_prefix(type, "deep", limits: limits) }
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["v"]), {"v" => CrystalClick::DynamicStructure.new([type])}
    )
    logical = CrystalClick::ObjectDocumentPlan.new(structures, {} of String => CrystalClick::BinaryDataType)
    expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::ObjectDocumentPhysicalPlan.new("doc", logical, limits: limits) }
    tuple = CrystalClick::BinaryDataType.tuple([CrystalClick::BinaryDataType.primitive("UInt64"), CrystalClick::BinaryDataType.primitive("UInt8")])
    tiny = CrystalClick::BinaryCodecLimits.new(max_depth: 8, max_nodes: 1, max_elements: 10_000, max_bytes: 1_000_000)
    expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::BinaryBulkPhysicalPlan.new(tuple, "count", limits: tiny) }
  end

  it "rejects an oversized escaped name before materializing its expansion" do
    limits = CrystalClick::BinaryCodecLimits.new(max_depth: 8, max_nodes: 10_000, max_elements: 10_000, max_bytes: 100)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkPhysicalPlan.new(CrystalClick::BinaryDataType.primitive("UInt64"), "/" * 101, limits: limits)
    end
  end

  it "binds non-fixture Object paths, Dynamic Map arms and sibling metadata" do
    string = CrystalClick::BinaryDataType.primitive("String")
    map = CrystalClick::BinaryDataType.map(CrystalClick::BinaryDataType.primitive("UInt64"), string)
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["p.q"]),
      {"p.q" => CrystalClick::DynamicStructure.new([map])}
    )
    logical = CrystalClick::ObjectDocumentPlan.new(structures, {"user.id" => string})
    physical = CrystalClick::ObjectDocumentPhysicalPlan.new(
      "doc.column", logical, profile: CrystalClick::BinaryBulkProfile.with_size_stream,
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream
    )
    physical.object_structure_stream.should eq("doc%2Ecolumn.object_structure")
    physical.dynamic_structure_stream("p.q").should eq("doc%2Ecolumn.p%2Eq.dynamic_structure")
    physical.discriminator_stream("p.q").should eq("doc%2Ecolumn.p%2Eq.variant_discr")
    physical.typed("user.id").stream_names.should eq({
      "root.data"         => "doc%2Ecolumn.user%2Eid",
      "root.string_sizes" => "doc%2Ecolumn.user%2Eid.size",
    })
    physical.dynamic_arm("p.q", "Map(UInt64, String)").stream_names.should eq({
      "root.sizes"                         => "doc%2Ecolumn.p%2Eq.Map%28UInt64%2C%20String%29.size0",
      "root.elements.field.0.data"         => "doc%2Ecolumn.p%2Eq.Map%28UInt64%2C%20String%29%2Ekeys",
      "root.elements.field.1.data"         => "doc%2Ecolumn.p%2Eq.Map%28UInt64%2C%20String%29%2Evalues",
      "root.elements.field.1.string_sizes" => "doc%2Ecolumn.p%2Eq.Map%28UInt64%2C%20String%29%2Evalues.size",
    })
    physical.dynamic_arm("p.q", "SharedVariant").stream_names.should eq({
      "root.data"         => "doc%2Ecolumn.p%2Eq.SharedVariant",
      "root.string_sizes" => "doc%2Ecolumn.p%2Eq.SharedVariant.size",
    })
    physical.shared.stream_names.should eq({
      "root.sizes"                 => "doc%2Ecolumn.object_shared_data.size0",
      "root.elements.field.0.data" => "doc%2Ecolumn.object_shared_data%2Epaths",
      "root.elements.field.1.data" => "doc%2Ecolumn.object_shared_data%2Evalues",
    })
    physical.stream_names.should eq(physical.stream_names.sort)
    physical.stream_names.uniq.size.should eq(physical.stream_names.size)
  end

  it "rejects Object typed lanes colliding with structure or shared files" do
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String), {} of String => CrystalClick::DynamicStructure
    )
    scalar = CrystalClick::BinaryDataType.primitive("UInt64")
    {"object_structure" => scalar, "object_shared_data" => CrystalClick::BinaryDataType.array(scalar)}.each do |path, type|
      logical = CrystalClick::ObjectDocumentPlan.new(structures, {path => type})
      expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::ObjectDocumentPhysicalPlan.new("doc", logical) }
    end
  end

  it "detects collisions across independently built typed path plans" do
    scalar = CrystalClick::BinaryDataType.primitive("UInt64")
    tuple = CrystalClick::BinaryDataType.tuple([scalar], ["b"])
    structures = CrystalClick::ObjectDynamicStructureSet.new(CrystalClick::ObjectStructure.new([] of String), {} of String => CrystalClick::DynamicStructure)
    logical = CrystalClick::ObjectDocumentPlan.new(structures, {"a" => tuple, "a.b" => scalar})
    expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::ObjectDocumentPhysicalPlan.new("doc", logical) }
  end

  it "distinguishes literal percent encoding from a raw dotted Object path" do
    scalar = CrystalClick::BinaryDataType.primitive("UInt64")
    structures = CrystalClick::ObjectDynamicStructureSet.new(CrystalClick::ObjectStructure.new([] of String), {} of String => CrystalClick::DynamicStructure)
    logical = CrystalClick::ObjectDocumentPlan.new(structures, {"a.b" => scalar, "a%2Eb" => scalar})
    physical = CrystalClick::ObjectDocumentPhysicalPlan.new("doc", logical)
    physical.typed("a.b").stream_name_for("root.data").should eq("doc.a%2Eb")
    physical.typed("a%2Eb").stream_name_for("root.data").should eq("doc.a%252Eb")
    names = physical.stream_names
    names.first.to_unsafe[0] = 'X'.ord.to_u8
    names.clear
    physical.object_structure_stream.should eq("doc.object_structure")
    physical.stream_names.size.should eq(6)
  end

  it "shares aggregate name bounds across all Object path plans" do
    scalar = CrystalClick::BinaryDataType.primitive("UInt64")
    structures = CrystalClick::ObjectDynamicStructureSet.new(CrystalClick::ObjectStructure.new([] of String), {} of String => CrystalClick::DynamicStructure)
    schema = Hash(String, CrystalClick::BinaryDataType).new
    16.times { |index| schema["arbitrary_#{index}"] = scalar }
    logical = CrystalClick::ObjectDocumentPlan.new(structures, schema)
    limits = CrystalClick::BinaryCodecLimits.new(max_depth: 8, max_nodes: 10_000, max_elements: 10_000, max_bytes: 100)
    expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::ObjectDocumentPhysicalPlan.new("doc", logical, limits: limits) }
  end

  it "rejects legacy and bucketed Object layouts instead of borrowing MAP names" do
    stats = CrystalClick::StructureStatistics.new([] of UInt64, [] of CrystalClick::StructureStatistic)
    objects = [
      CrystalClick::ObjectStructure.new([] of String, version: 2_u64, statistics: stats),
      CrystalClick::ObjectStructure.new([] of String, shared_data_version: 1_u64, bucket_count: 2_u64),
    ]
    objects.each do |object|
      logical = CrystalClick::ObjectDocumentPlan.new(CrystalClick::ObjectDynamicStructureSet.new(object, {} of String => CrystalClick::DynamicStructure), {} of String => CrystalClick::BinaryDataType)
      expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::ObjectDocumentPhysicalPlan.new("doc", logical) }
    end
  end

  it "does not guess nonexistent roles or Dynamic alternatives" do
    structures = CrystalClick::ObjectDynamicStructureSet.new(CrystalClick::ObjectStructure.new(["v"]), {"v" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)})
    logical = CrystalClick::ObjectDocumentPlan.new(structures, {} of String => CrystalClick::BinaryDataType)
    physical = CrystalClick::ObjectDocumentPhysicalPlan.new("doc", logical)
    expect_raises(KeyError) { physical.shared.stream_name_for("root.unknown") }
    expect_raises(KeyError) { physical.dynamic_arm("v", "UInt64") }
    expect_raises(KeyError) { physical.dynamic_structure_stream("unknown") }
  end

  it "escapes Dynamic SQL names separately from nested Tuple fields" do
    tuple = CrystalClick::BinaryDataType.tuple([CrystalClick::BinaryDataType.primitive("String")], ["a.b"])
    enum_type = CrystalClick::BinaryDataType.enum8([{"a'b", -1_i16}] of CrystalClick::BinaryEnumDefinition::Entry)
    temporal = CrystalClick::BinaryDataType.datetime64(3, "UTC")
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["v"]),
      {"v" => CrystalClick::DynamicStructure.new([tuple, enum_type, temporal])}
    )
    logical = CrystalClick::ObjectDocumentPlan.new(structures, {} of String => CrystalClick::BinaryDataType)
    physical = CrystalClick::ObjectDocumentPhysicalPlan.new("doc", logical, profile: CrystalClick::BinaryBulkProfile.with_size_stream)
    physical.dynamic_arm("v", "Tuple(`a.b` String)").stream_names.should eq({
      "root.field.0.data"         => "doc.v.Tuple%28%60a%2Eb%60%20String%29%2Ea%2Eb",
      "root.field.0.string_sizes" => "doc.v.Tuple%28%60a%2Eb%60%20String%29%2Ea%2Eb.size",
    })
    physical.dynamic_arm("v", "Enum8('a\\'b' = -1)").stream_name_for("root.data").should eq("doc.v.Enum8%28%27a%5C%27b%27%20%3D%20%2D1%29")
    physical.dynamic_arm("v", "DateTime64(3, 'UTC')").stream_name_for("root.data").should eq("doc.v.DateTime64%283%2C%20%27UTC%27%29")
  end

  it "bounds metadata-dependent Dynamic display names as well as lane names" do
    tuple = CrystalClick::BinaryDataType.tuple([CrystalClick::BinaryDataType.primitive("UInt64")], ["opaque/" * 100])
    enum_type = CrystalClick::BinaryDataType.enum8([{"opaque/" * 100, 1_i16}] of CrystalClick::BinaryEnumDefinition::Entry)
    limits = CrystalClick::BinaryCodecLimits.new(max_depth: 8, max_nodes: 10_000, max_elements: 10_000, max_bytes: 500)
    [tuple, enum_type].each do |type|
      structures = CrystalClick::ObjectDynamicStructureSet.new(
        CrystalClick::ObjectStructure.new(["v"]), {"v" => CrystalClick::DynamicStructure.new([type])}
      )
      logical = CrystalClick::ObjectDocumentPlan.new(structures, {} of String => CrystalClick::BinaryDataType)
      expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::ObjectDocumentPhysicalPlan.new("doc", logical, limits: limits) }
    end
  end

  it "preserves the admitted Nothing role even when its payload is empty" do
    nothing = CrystalClick::BinaryDataType.primitive("Nothing")
    CrystalClick::BinaryBulkPhysicalPlan.new(nothing, "n").stream_names.should eq({"root.data" => "n"})
    CrystalClick::BinaryBulkPhysicalPlan.new(CrystalClick::BinaryDataType.array(nothing), "n").stream_names.should eq({
      "root.sizes"         => "n.size0",
      "root.elements.data" => "n",
    })
  end

  it "validates internal escaped prefixes instead of accepting raw filesystem syntax" do
    type = CrystalClick::BinaryDataType.primitive("UInt8")
    ["a/b", "a\\b", "a\0b", "a%", "a%2", "a%GG", "a%2f"].each do |prefix|
      expect_raises(ArgumentError) { CrystalClick::BinaryBulkPhysicalPlan.from_escaped_prefix(type, prefix) }
    end
    CrystalClick::BinaryBulkPhysicalPlan.from_escaped_prefix(type, "doc.path%2Ename").stream_name_for("root.data").should eq("doc.path%2Ename")
    CrystalClick::BinaryBulkPhysicalPlan.new(type, "doc%2Ename").stream_name_for("root.data").should eq("doc%252Ename")
  end

  it "keeps completed plan getters independent of later shared budget consumption" do
    limits = CrystalClick::BinaryCodecLimits.new(max_depth: 8, max_nodes: 10_000, max_elements: 10_000, max_bytes: 100)
    context = CrystalClick::PhysicalStreamPlanContext.new(limits)
    plan = CrystalClick::BinaryBulkPhysicalPlan.from_escaped_prefix(
      CrystalClick::BinaryDataType.primitive("UInt8"), "p", limits: limits, context: context
    )
    context.charge_name_bytes(context.remaining_name_bytes)
    plan.stream_name_for("root.data").should eq("p")
    plan.data_file_for("root.data").should eq("p.bin")
    plan.marks_file_for("root.data", hashed: true).should eq("#{CrystalClick::StreamName.hash("p")}.mrk2")
  end
end
