require "./spec_helper"

private def w128_schema_type(name : String) : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.primitive(name)
end

private def w128_schema_plan(
  typed : Hash(String, CrystalClick::BinaryDataType) = {"t" => w128_schema_type("UInt64")},
  paths : Array(String) = ["d"],
  types : Array(CrystalClick::BinaryDataType) = [w128_schema_type("String")],
  version : UInt64 = 4_u64,
  shared_version : UInt64 = 0_u64,
  buckets : UInt64 = 1_u64,
) : CrystalClick::ObjectDocumentPlan
  dynamics = Hash(String, CrystalClick::DynamicStructure).new
  paths.each do |path|
    dynamics[path] = CrystalClick::DynamicStructure.new(types)
  end
  object = CrystalClick::ObjectStructure.new(paths, version, shared_version, buckets)
  CrystalClick::ObjectDocumentPlan.new(CrystalClick::ObjectDynamicStructureSet.new(object, dynamics), typed)
end

private def w128_schema_limits(max_bytes : Int = 1024) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(max_depth: 32, max_nodes: 1024, max_elements: 1024, max_bytes: max_bytes)
end

describe "W128 ObjectDocumentSchema" do
  it "renders default and explicit capacities in canonical order with sorted typed paths" do
    defaults = CrystalClick::ObjectDocumentSchema.new({
      "t" => w128_schema_type("String"),
      "a" => w128_schema_type("UInt64"),
    })
    defaults.declaration.should eq("JSON(a UInt64, t String)")

    explicit = CrystalClick::ObjectDocumentSchema.new({
      "t"      => w128_schema_type("String"),
      "select" => w128_schema_type("UInt64"),
      "a.b"    => w128_schema_type("String"),
      "SKIP"   => w128_schema_type("UInt64"),
    }, max_dynamic_paths: 7, max_dynamic_types: 3)
    explicit.declaration.should eq("JSON(max_dynamic_types=3, max_dynamic_paths=7, `SKIP` UInt64, `a.b` String, `select` UInt64, t String)")
  end

  it "keeps constructor inputs and returned typed-path snapshots detached" do
    input = {"t" => w128_schema_type("UInt64")}
    schema = CrystalClick::ObjectDocumentSchema.new(input)
    input.clear
    schema.typed_paths.should eq({"t" => w128_schema_type("UInt64")})

    snapshot = schema.typed_paths
    snapshot.clear
    schema.typed_paths.should eq({"t" => w128_schema_type("UInt64")})
  end

  it "rejects non-ASCII, malformed, and non-identifier path spellings" do
    ["", ".a", "a.", "a..b", "a/b", "a\\b", "a b", "a`b", "a'b", "café", "a%2Eb"].each do |path|
      expect_raises(ArgumentError) do
        CrystalClick::ObjectDocumentSchema.new({path => w128_schema_type("UInt64")})
      end
    end
  end

  it "admits only the two sealed nominal typed descriptors" do
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentSchema.new({"t" => w128_schema_type("UInt32")})
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentSchema.new({"t" => CrystalClick::BinaryDataType.array(w128_schema_type("UInt64"))})
    end
  end

  it "checks nonnegative and protocol-bounded dynamic capacities" do
    expect_raises(ArgumentError) { CrystalClick::ObjectDocumentSchema.new({} of String => CrystalClick::BinaryDataType, max_dynamic_paths: -1) }
    expect_raises(ArgumentError) { CrystalClick::ObjectDocumentSchema.new({} of String => CrystalClick::BinaryDataType, max_dynamic_types: -1) }
    expect_raises(ArgumentError) { CrystalClick::ObjectDocumentSchema.new({} of String => CrystalClick::BinaryDataType, max_dynamic_paths: 10_001) }
    expect_raises(ArgumentError) { CrystalClick::ObjectDocumentSchema.new({} of String => CrystalClick::BinaryDataType, max_dynamic_types: 255) }
    CrystalClick::ObjectDocumentSchema.new({} of String => CrystalClick::BinaryDataType, max_dynamic_paths: 10_000, max_dynamic_types: 254).should_not be_nil
  end

  it "rejects aggregate name copies that exceed codec limits before retaining a schema" do
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::ObjectDocumentSchema.new({"a" => w128_schema_type("UInt64")}, limits: w128_schema_limits(4))
    end
  end

  it "requires exact typed paths and nominal types and enforces both dynamic capacities" do
    schema = CrystalClick::ObjectDocumentSchema.new({"t" => w128_schema_type("UInt64")}, max_dynamic_paths: 1, max_dynamic_types: 1)
    schema.validate_plan(w128_schema_plan).should be_nil

    expect_raises(ArgumentError) do
      schema.validate_plan(w128_schema_plan(typed: {"t" => w128_schema_type("String")}))
    end
    expect_raises(ArgumentError) do
      schema.validate_plan(w128_schema_plan(typed: {"other" => w128_schema_type("UInt64")}))
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentSchema.new({"t" => w128_schema_type("UInt64")}, max_dynamic_paths: 0, max_dynamic_types: 1).validate_plan(w128_schema_plan)
    end
    expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentSchema.new({"t" => w128_schema_type("UInt64")}, max_dynamic_paths: 1, max_dynamic_types: 1).validate_plan(
        w128_schema_plan(types: [w128_schema_type("String"), w128_schema_type("UInt64")]))
    end
  end

  it "rejects non-normalized Object layouts without inferring or rewriting the roster" do
    schema = CrystalClick::ObjectDocumentSchema.new({"t" => w128_schema_type("UInt64")})
    expect_raises(ArgumentError) do
      schema.validate_plan(w128_schema_plan(shared_version: 1_u64, buckets: 2_u64))
    end
  end
end
