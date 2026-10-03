require "./spec_helper"

private def w146_decl_limits(
  max_depth : Int = 32,
  max_nodes : Int = 128,
  max_elements : Int = 128,
  max_bytes : Int = 16 * 1024,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: max_depth,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes,
  )
end

private def w146_decl_low_string : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive("String"))
end

private def w146_decl_low_nullable_string : CrystalClick::BinaryDataType
  string = CrystalClick::BinaryDataType.primitive("String")
  CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.nullable(string))
end

private def w146_decl_empty_structures : CrystalClick::ObjectDynamicStructureSet
  CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
end

describe "W146 declared Object LowCardinality admission" do
  it "round-trips LC through recursive Array, named Tuple, and Map declarations" do
    string = CrystalClick::BinaryDataType.primitive("String")
    low_string = CrystalClick::BinaryDataType.low_cardinality(string)
    low_nullable = CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.nullable(string))
    tuple = CrystalClick::BinaryDataType.tuple(
      [CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.array(low_string)), low_nullable, string] of CrystalClick::BinaryDataType,
      ["items", "maybe", "note"] of String,
    )
    type = CrystalClick::BinaryDataType.map(string, tuple)
    declaration = "JSON(value Map(String, Tuple(items Array(Array(LowCardinality(String))), maybe LowCardinality(Nullable(String)), note String)))"

    schema = CrystalClick::ObjectDocumentSchema.new({"value" => type})
    schema.declaration.should eq(declaration)
    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(declaration)
    parsed.declaration.should eq(declaration)
    parsed.typed_paths.should eq({"value" => type})

    metrics = CrystalClick::ObjectRecursiveDeclaration.measure_descriptor(type).not_nil!
    metrics.max_depth.should eq(6)
    metrics.byte_size.should eq("Map(String, Tuple(items Array(Array(LowCardinality(String))), maybe LowCardinality(Nullable(String)), note String))".bytesize.to_u64)
    metrics.descriptor_node_count.should eq(11_u64)
    metrics.child_edge_count.should eq(10_u64)
    metrics.tuple_name_count.should eq(3_u64)
    metrics.tuple_name_bytes.should eq(14_u64)
  end

  it "accounts the LowCardinality child once in Object schema logical usage" do
    string = CrystalClick::BinaryDataType.primitive("String")
    low_string = CrystalClick::BinaryDataType.low_cardinality(string)
    plain_schema = CrystalClick::ObjectDocumentSchema.new({"payload" => string})
    low_schema = CrystalClick::ObjectDocumentSchema.new({"payload" => low_string})
    plain = CrystalClick::ObjectSchemaLogicalUsage.measure(plain_schema, plain_schema.typed_paths)
    low = CrystalClick::ObjectSchemaLogicalUsage.measure(low_schema, low_schema.typed_paths)

    plain.nodes.should eq(3_u64)
    plain.elements.should eq(2_u64)
    low.nodes.should eq(4_u64)
    low.elements.should eq(3_u64)

    # The LC root adds one child edge and one String descriptor owner. Its
    # canonical name grows both retained baseline copies: declaration and
    # detached type name are each doubled by the estimate.
    name_delta = "LowCardinality(String)".bytesize - "String".bytesize
    child_owner_bytes = sizeof(Pointer(CrystalClick::BinaryDataType)).to_u64
    child_owner_bytes += instance_sizeof(CrystalClick::BinaryDataType).to_u64
    child_owner_bytes += instance_sizeof(Array(CrystalClick::BinaryDataType)).to_u64
    child_owner_bytes += instance_sizeof(Array(String)).to_u64
    child_owner_bytes += instance_sizeof(String).to_u64 + "String".bytesize.to_u64 + 1_u64
    (low.bytes - plain.bytes).should eq(4_u64 * name_delta.to_u64 + child_owner_bytes)
  end

  it "keeps Object-specific LowCardinality and Nullable wrappers closed outside the intersection" do
    bfloat = CrystalClick::BinaryDataType.primitive("BFloat16")
    low_bfloat = CrystalClick::BinaryDataType.low_cardinality(bfloat)
    plan = CrystalClick::ObjectDocumentPlan.new(w146_decl_empty_structures, {"value" => low_bfloat})
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentPhysicalPlan.new("payload", plan)
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentSchema.new({"value" => low_bfloat})
    end

    # The general descriptor constructor itself excludes Nullable(LC), and
    # the bounded Object declaration parser must preserve that boundary.
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.nullable(w146_decl_low_string)
    end

    [
      "JSON(value LowCardinality(BFloat16))",
      "JSON(value Nullable(LowCardinality(String)))",
      "JSON(value LowCardinality(Array(String)))",
      "JSON(value LowCardinality(Map(String, String)))",
      "JSON(value LowCardinality(Tuple(String, String)))",
      "JSON(value LowCardinality(Decimal(9, 2)))",
      "JSON(value LowCardinality(Enum8('a' = 1)))",
      "JSON(value LowCardinality(DateTime64(3)))",
      "JSON(value LowCardinality(Time64(3)))",
      "JSON(value LowCardinality(LowCardinality(String)))",
    ].each do |declaration|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.parse_declaration(declaration)
      end
    end
  end

  it "charges recursive sibling declarations against one exact schema budget" do
    fields = {
      "a" => w146_decl_low_string,
      "b" => w146_decl_low_nullable_string,
    }
    declaration = "JSON(a LowCardinality(String), b LowCardinality(Nullable(String)))"

    # Direct schema: root + two path records + three LC descendants; two
    # path edges + three descriptor edges. Retained path/declaration bytes
    # are two raw key bytes plus two complete declaration copies.
    direct = w146_decl_limits(max_depth: 4, max_nodes: 6, max_elements: 5, max_bytes: 134)
    CrystalClick::ObjectDocumentSchema.new(fields, limits: direct).declaration.should eq(declaration)
    parsed = w146_decl_limits(max_depth: 4, max_nodes: 6, max_elements: 5, max_bytes: 258)
    CrystalClick::ObjectDocumentSchema.parse_declaration(declaration, parsed).typed_paths.should eq(fields)

    [
      w146_decl_limits(max_depth: 3, max_nodes: 6, max_elements: 5, max_bytes: 134),
      w146_decl_limits(max_depth: 4, max_nodes: 5, max_elements: 5, max_bytes: 134),
      w146_decl_limits(max_depth: 4, max_nodes: 6, max_elements: 4, max_bytes: 134),
      w146_decl_limits(max_depth: 4, max_nodes: 6, max_elements: 5, max_bytes: 133),
    ].each do |one_short|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.new(fields, limits: one_short)
      end
    end

    [
      w146_decl_limits(max_depth: 3, max_nodes: 6, max_elements: 5, max_bytes: 258),
      w146_decl_limits(max_depth: 4, max_nodes: 5, max_elements: 5, max_bytes: 258),
      w146_decl_limits(max_depth: 4, max_nodes: 6, max_elements: 4, max_bytes: 258),
      w146_decl_limits(max_depth: 4, max_nodes: 6, max_elements: 5, max_bytes: 257),
    ].each do |one_short|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.parse_declaration(declaration, one_short)
      end
    end
  end

  it "revalidates a borrowed LowCardinality declaration before materialization" do
    bytes = "LowCardinality(String)".to_slice.dup
    preflight = CrystalClick::ObjectRecursiveDeclaration.preflight_slice(bytes, 0, bytes.size, root_depth: 2).not_nil!
    bytes[bytes.size - 2] = 'x'.ord.to_u8

    expect_raises(ArgumentError) { preflight.materialize }
  end

  it "rejects forged recursive preflight aggregates before accounting or materialization" do
    bytes = "LowCardinality(String)".to_slice
    preflight = CrystalClick::ObjectRecursiveDeclaration.preflight_slice(bytes, 0, bytes.size, root_depth: 2).not_nil!
    forged = CrystalClick::ObjectRecursiveDeclaration::Preflight.new(
      preflight.byte_size + 1_u64,
      preflight.descriptor_node_count,
      preflight.child_edge_count,
      preflight.metadata_edge_count,
      preflight.enum_entry_count,
      preflight.decoded_label_bytes,
      preflight.explicit_zone_bytes,
      preflight.tuple_name_count,
      preflight.tuple_name_bytes,
      preflight.max_depth,
      preflight.root_depth,
      preflight.source,
      preflight.first,
      preflight.after,
      preflight.limits,
    )

    expect_raises(ArgumentError) { forged.materialize }
    expect_raises(ArgumentError) do
      forged.account(CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true))
    end
  end
end
