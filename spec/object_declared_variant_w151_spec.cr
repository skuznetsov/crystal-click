require "./spec_helper"

private def w151_decl_limits(
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

private def w151_variant_choice : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.variant([
    CrystalClick::BinaryDataType.primitive("UInt64"),
    CrystalClick::BinaryDataType.low_cardinality(CrystalClick::BinaryDataType.primitive("String")),
  ] of CrystalClick::BinaryDataType)
end

private def w151_variant_map_value : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.variant([
    CrystalClick::BinaryDataType.primitive("UInt64"),
    CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("UInt8")),
  ] of CrystalClick::BinaryDataType)
end

describe "W151 declared Object Variant admission" do
  it "round-trips canonical Variant through recursive Array, Map, named Tuple, and Nullable Tuple paths" do
    choice = w151_variant_choice
    map_value = w151_variant_map_value
    map = CrystalClick::BinaryDataType.map(CrystalClick::BinaryDataType.primitive("String"), map_value)
    record = CrystalClick::BinaryDataType.tuple(
      [choice, map] of CrystalClick::BinaryDataType,
      ["choice", "lookup"] of String,
    )
    nullable_record = CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.tuple(
      [choice, CrystalClick::BinaryDataType.primitive("UInt8")] of CrystalClick::BinaryDataType,
      ["choice", "code"] of String,
    ))
    fields = {
      "items"  => CrystalClick::BinaryDataType.array(choice),
      "lookup" => map,
      "maybe"  => nullable_record,
      "record" => record,
    }
    declaration = "JSON(items Array(Variant(LowCardinality(String), UInt64)), lookup Map(String, Variant(Array(UInt8), UInt64)), maybe Nullable(Tuple(choice Variant(LowCardinality(String), UInt64), code UInt8)), record Tuple(choice Variant(LowCardinality(String), UInt64), lookup Map(String, Variant(Array(UInt8), UInt64))))"

    schema = CrystalClick::ObjectDocumentSchema.new(fields)
    schema.declaration.should eq(declaration)
    parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(declaration)
    parsed.declaration.should eq(declaration)
    parsed.typed_paths.should eq(fields)
  end

  it "admits exact aggregate limits and rejects one-short depth, nodes, elements, and bytes" do
    type = CrystalClick::BinaryDataType.variant([
      CrystalClick::BinaryDataType.primitive("UInt64"),
      CrystalClick::BinaryDataType.primitive("String"),
    ] of CrystalClick::BinaryDataType)
    declaration = "JSON(v Variant(String, UInt64))"
    fields = {"v" => type}

    # Direct schema accounting includes its root/path and both Variant arms:
    # depth 3, four nodes, three edges, and one key plus two 31-byte schemas.
    direct = w151_decl_limits(max_depth: 3, max_nodes: 4, max_elements: 3, max_bytes: 63)
    CrystalClick::ObjectDocumentSchema.new(fields, limits: direct).declaration.should eq(declaration)
    [
      w151_decl_limits(max_depth: 2, max_nodes: 4, max_elements: 3, max_bytes: 63),
      w151_decl_limits(max_depth: 3, max_nodes: 3, max_elements: 3, max_bytes: 63),
      w151_decl_limits(max_depth: 3, max_nodes: 4, max_elements: 2, max_bytes: 63),
      w151_decl_limits(max_depth: 3, max_nodes: 4, max_elements: 3, max_bytes: 62),
    ].each do |one_short|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.new(fields, limits: one_short)
      end
    end

    # Parser accounting additionally charges the 31-byte borrowed declaration,
    # a 24-byte recursive preflight, the path, and two retained declarations.
    parsed_exact = w151_decl_limits(max_depth: 3, max_nodes: 4, max_elements: 3, max_bytes: 119)
    CrystalClick::ObjectDocumentSchema.parse_declaration(declaration, parsed_exact).typed_paths.should eq(fields)
    [
      w151_decl_limits(max_depth: 2, max_nodes: 4, max_elements: 3, max_bytes: 119),
      w151_decl_limits(max_depth: 3, max_nodes: 3, max_elements: 3, max_bytes: 119),
      w151_decl_limits(max_depth: 3, max_nodes: 4, max_elements: 2, max_bytes: 119),
      w151_decl_limits(max_depth: 3, max_nodes: 4, max_elements: 3, max_bytes: 118),
    ].each do |one_short|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.parse_declaration(declaration, one_short)
      end
    end
  end

  it "revalidates borrowed Variant text and forged aggregates before materialization" do
    bytes = "Variant(String, UInt64)".to_slice.dup
    preflight = CrystalClick::ObjectRecursiveDeclaration.preflight_slice(
      bytes, 0, bytes.size, root_depth: 2
    ).not_nil!
    bytes[bytes.size - 2] = '5'.ord.to_u8
    expect_raises(ArgumentError) { preflight.materialize }

    stable = "Variant(String, UInt64)".to_slice
    original = CrystalClick::ObjectRecursiveDeclaration.preflight_slice(
      stable, 0, stable.size, root_depth: 2
    ).not_nil!
    forged = CrystalClick::ObjectRecursiveDeclaration::Preflight.new(
      original.byte_size + 1_u64,
      original.descriptor_node_count,
      original.child_edge_count,
      original.metadata_edge_count,
      original.enum_entry_count,
      original.decoded_label_bytes,
      original.explicit_zone_bytes,
      original.tuple_name_count,
      original.tuple_name_bytes,
      original.max_depth,
      original.root_depth,
      original.source,
      original.first,
      original.after,
      original.limits,
    )
    expect_raises(ArgumentError) { forged.materialize }
    expect_raises(ArgumentError) do
      forged.account(CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true))
    end
  end

  it "rejects noncanonical and forbidden direct-arm rosters without widening Dynamic" do
    [
      "JSON(v Variant(UInt64, String))",
      "JSON(v Variant(String, String))",
      "JSON(v Variant(Nothing, String))",
      "JSON(v Variant(Nullable(String), UInt64))",
      "JSON(v Variant(Variant(String, UInt8), UInt64))",
      "JSON(v Variant(LowCardinality(Nullable(String)), UInt64))",
      "JSON(v Nullable(Variant(String, UInt64)))",
      "JSON(v Dynamic)",
    ].each do |declaration|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectDocumentSchema.parse_declaration(declaration)
      end
    end

    variant = CrystalClick::BinaryDataType.variant([
      CrystalClick::BinaryDataType.primitive("String"),
      CrystalClick::BinaryDataType.primitive("UInt64"),
    ] of CrystalClick::BinaryDataType)
    expect_raises(ArgumentError) do
      CrystalClick::DynamicStructure.new([variant] of CrystalClick::BinaryDataType)
    end
  end
end
