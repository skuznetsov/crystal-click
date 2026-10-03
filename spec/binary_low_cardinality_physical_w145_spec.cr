require "./spec_helper"

private def w145_low(type : CrystalClick::BinaryDataType) : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.low_cardinality(type)
end

private def w145_physical_limits(
  max_depth : Int = 8,
  max_nodes : Int = 100,
  max_elements : Int = 100,
  max_bytes : Int = 1_000,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: max_depth,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes
  )
end

describe "W145 LowCardinality physical stream binding" do
  it "binds root LC String and LC Nullable(String) to dictionary and index lanes only" do
    string = CrystalClick::BinaryDataType.primitive("String")
    types = [
      w145_low(string),
      w145_low(CrystalClick::BinaryDataType.nullable(string)),
    ] of CrystalClick::BinaryDataType
    expected = {"root.dictionary" => "x.dict", "root.indexes" => "x"}

    types.each do |type|
      single = CrystalClick::BinaryBulkPhysicalPlan.new(type, "x")
      sized = CrystalClick::BinaryBulkPhysicalPlan.new(
        type, "x", profile: CrystalClick::BinaryBulkProfile.with_size_stream
      )
      single.stream_names.should eq(expected)
      sized.stream_names.should eq(expected)
    end
  end

  it "binds every raw Float LC width to exactly two profile-independent lanes" do
    ["Float32", "Float64", "BFloat16"].each do |name|
      type = w145_low(CrystalClick::BinaryDataType.primitive(name))
      expected = {"root.dictionary" => "float.dict", "root.indexes" => "float"}
      [CrystalClick::BinaryBulkProfile.single_stream, CrystalClick::BinaryBulkProfile.with_size_stream].each do |profile|
        plan = CrystalClick::BinaryBulkPhysicalPlan.new(type, "float", profile: profile)
        plan.stream_names.should eq(expected)
      end
    end
  end

  it "binds LC sites through Map, named and unnamed Tuple, nested Arrays, and a sized String sibling" do
    string = CrystalClick::BinaryDataType.primitive("String")
    named = CrystalClick::BinaryDataType.tuple(
      [
        CrystalClick::BinaryDataType.map(
          w145_low(string),
          w145_low(CrystalClick::BinaryDataType.nullable(string))
        ),
        CrystalClick::BinaryDataType.array(
          CrystalClick::BinaryDataType.array(
            CrystalClick::BinaryDataType.tuple([
              w145_low(CrystalClick::BinaryDataType.primitive("Float32")),
            ] of CrystalClick::BinaryDataType)
          )
        ),
        string,
      ] of CrystalClick::BinaryDataType,
      ["lookup", "nested", "plain"] of String
    )
    plan = CrystalClick::BinaryBulkPhysicalPlan.new(
      named, "root", profile: CrystalClick::BinaryBulkProfile.with_size_stream
    )

    plan.stream_names.should eq({
      "root.field.0.sizes"                                => "root%2Elookup.size0",
      "root.field.0.elements.field.0.dictionary"          => "root%2Elookup%2Ekeys.dict",
      "root.field.0.elements.field.0.indexes"             => "root%2Elookup%2Ekeys",
      "root.field.0.elements.field.1.dictionary"          => "root%2Elookup%2Evalues.dict",
      "root.field.0.elements.field.1.indexes"             => "root%2Elookup%2Evalues",
      "root.field.1.sizes"                                => "root%2Enested.size0",
      "root.field.1.elements.sizes"                       => "root%2Enested.size1",
      "root.field.1.elements.elements.field.0.dictionary" => "root%2Enested%2E1.dict",
      "root.field.1.elements.elements.field.0.indexes"    => "root%2Enested%2E1",
      "root.field.2.data"                                 => "root%2Eplain",
      "root.field.2.string_sizes"                         => "root%2Eplain.size",
    })
  end

  it "escapes raw prefixes once, preserves validated escaped prefixes, and hashes complete LC basenames" do
    type = w145_low(CrystalClick::BinaryDataType.primitive("String"))
    raw = CrystalClick::BinaryBulkPhysicalPlan.new(type, "doc.path/name%")
    escaped = CrystalClick::BinaryBulkPhysicalPlan.from_escaped_prefix(type, "doc.path%2Fname%25")

    raw.stream_names.should eq({
      "root.dictionary" => "doc%2Epath%2Fname%25.dict",
      "root.indexes"    => "doc%2Epath%2Fname%25",
    })
    escaped.stream_names.should eq({
      "root.dictionary" => "doc.path%2Fname%25.dict",
      "root.indexes"    => "doc.path%2Fname%25",
    })
    raw.data_file_for("root.dictionary").should eq("doc%2Epath%2Fname%25.dict.bin")
    raw.marks_file_for("root.dictionary").should eq("doc%2Epath%2Fname%25.dict.mrk2")
    raw.data_file_for("root.indexes").should eq("doc%2Epath%2Fname%25.bin")
    raw.marks_file_for("root.indexes").should eq("doc%2Epath%2Fname%25.mrk2")
    raw.data_file_for("root.dictionary", hashed: true).should eq(
      "#{CrystalClick::StreamName.hash("doc%2Epath%2Fname%25.dict")}.bin"
    )
    raw.marks_file_for("root.dictionary", hashed: true).should eq(
      "#{CrystalClick::StreamName.hash("doc%2Epath%2Fname%25.dict")}.mrk2"
    )
    raw.data_file_for("root.indexes", hashed: true).should eq(
      "#{CrystalClick::StreamName.hash("doc%2Epath%2Fname%25")}.bin"
    )
    raw.marks_file_for("root.indexes", hashed: true).should eq(
      "#{CrystalClick::StreamName.hash("doc%2Epath%2Fname%25")}.mrk2"
    )
  end

  it "returns detached role names and retained bindings after caller mutation" do
    column = String.new("detached".to_slice)
    type = w145_low(CrystalClick::BinaryDataType.primitive("String"))
    plan = CrystalClick::BinaryBulkPhysicalPlan.new(type, column)
    column.to_unsafe[0] = 'X'.ord.to_u8

    snapshot = plan.stream_names
    snapshot["root.dictionary"].to_unsafe[0] = 'Y'.ord.to_u8
    snapshot["root.indexes"].to_unsafe[0] = 'Z'.ord.to_u8
    snapshot.clear
    returned = plan.stream_name_for("root.dictionary")
    returned.to_unsafe[0] = 'Q'.ord.to_u8

    plan.stream_names.should eq({
      "root.dictionary" => "detached.dict",
      "root.indexes"    => "detached",
    })
    plan.stream_name_for("root.dictionary").should eq("detached.dict")
    plan.stream_name_for("root.indexes").should eq("detached")
  end

  it "preflights the exact root LC roster budget and each descriptor axis" do
    type = w145_low(CrystalClick::BinaryDataType.primitive("String"))
    # root.dictionary/root.indexes are 15+12 role bytes; x.dict/x are 6+1
    # basename bytes. The descriptor contributes two nodes and one child edge;
    # the two retained roles contribute two more elements.
    exact = w145_physical_limits(max_depth: 1, max_nodes: 2, max_elements: 3, max_bytes: 34)
    CrystalClick::BinaryBulkPhysicalPlan.new(type, "x", limits: exact).stream_names.should eq({
      "root.dictionary" => "x.dict",
      "root.indexes"    => "x",
    })

    [
      w145_physical_limits(max_depth: 0, max_nodes: 2, max_elements: 3, max_bytes: 34),
      w145_physical_limits(max_depth: 1, max_nodes: 1, max_elements: 3, max_bytes: 34),
      w145_physical_limits(max_depth: 1, max_nodes: 2, max_elements: 2, max_bytes: 34),
      w145_physical_limits(max_depth: 1, max_nodes: 2, max_elements: 3, max_bytes: 33),
    ].each do |short|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::BinaryBulkPhysicalPlan.new(type, "x", limits: short)
      end
    end
  end

  it "charges descriptor, element, and retained-name work across shared physical contexts" do
    type = w145_low(CrystalClick::BinaryDataType.primitive("String"))

    bytes_context = CrystalClick::PhysicalStreamPlanContext.new(
      w145_physical_limits(max_bytes: 67)
    )
    CrystalClick::BinaryBulkPhysicalPlan.new(type, "a", context: bytes_context)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkPhysicalPlan.new(type, "b", context: bytes_context)
    end

    nodes_context = CrystalClick::PhysicalStreamPlanContext.new(
      w145_physical_limits(max_nodes: 3)
    )
    CrystalClick::BinaryBulkPhysicalPlan.new(type, "a", context: nodes_context)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkPhysicalPlan.new(type, "b", context: nodes_context)
    end

    elements_context = CrystalClick::PhysicalStreamPlanContext.new(
      w145_physical_limits(max_elements: 5)
    )
    CrystalClick::BinaryBulkPhysicalPlan.new(type, "a", context: elements_context)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkPhysicalPlan.new(type, "b", context: elements_context)
    end
  end

  it "keeps escaped Tuple dots distinct from the literal LC dictionary suffix and rejects true nested path collisions" do
    scalar = CrystalClick::BinaryDataType.primitive("String")
    escaped_name = CrystalClick::BinaryDataType.tuple(
      [scalar, w145_low(scalar)] of CrystalClick::BinaryDataType,
      ["a.dict", "a"] of String
    )
    noncolliding = CrystalClick::BinaryBulkPhysicalPlan.new(escaped_name, "column")
    noncolliding.stream_names.should eq({
      "root.field.0.data"       => "column%2Ea%2Edict",
      "root.field.1.dictionary" => "column%2Ea.dict",
      "root.field.1.indexes"    => "column%2Ea",
    })

    low = w145_low(scalar)
    nested_path = CrystalClick::BinaryDataType.tuple(
      [
        low,
        CrystalClick::BinaryDataType.tuple([low] of CrystalClick::BinaryDataType, ["b"] of String),
      ] of CrystalClick::BinaryDataType,
      ["a.b", "a"] of String
    )
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkPhysicalPlan.new(nested_path, "collision")
    end
  end

  it "keeps typed Object and Dynamic physical LC consumers rejected at root and nested sites" do
    string = CrystalClick::BinaryDataType.primitive("String")
    low = w145_low(string)
    empty_structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure
    )

    [low, CrystalClick::BinaryDataType.array(low)].each do |type|
      typed = CrystalClick::ObjectDocumentPlan.new(empty_structures, {"typed" => type})
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentPhysicalPlan.new("doc", typed)
      end

      structures = CrystalClick::ObjectDynamicStructureSet.new(
        CrystalClick::ObjectStructure.new(["dynamic"] of String),
        {"dynamic" => CrystalClick::DynamicStructure.new([type] of CrystalClick::BinaryDataType)}
      )
      dynamic = CrystalClick::ObjectDocumentPlan.new(
        structures, {} of String => CrystalClick::BinaryDataType
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentPhysicalPlan.new("doc", dynamic)
      end
    end
  end
end
