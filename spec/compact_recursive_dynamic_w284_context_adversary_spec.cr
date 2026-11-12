require "./spec_helper"

module CompactRecursiveDynamicW284ContextAdversaryFixture
  extend self

  JSON_DECLARATION               = "JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8)"
  STATIC_SCHEMA_DECLARATION      = "Tuple(doc #{JSON_DECLARATION})"
  ONE_DYNAMIC_SCHEMA_DECLARATION = "Array(Tuple(doc #{JSON_DECLARATION}, sample Dynamic(max_types=1)))"
  TWO_DYNAMIC_SCHEMA_DECLARATION = "Tuple(doc #{JSON_DECLARATION}, left Dynamic(max_types=1), right Dynamic(max_types=1))"

  JSON_SITE          = "root/array[0]/tuple[0]"
  DYNAMIC_SITE       = "root/array[0]/tuple[1]"
  LEFT_DYNAMIC_SITE  = "root/tuple[1]"
  RIGHT_DYNAMIC_SITE = "root/tuple[2]"

  def static_schema : CrystalClick::StorageColumnSchema
    CrystalClick::StorageColumnSchema.parse(STATIC_SCHEMA_DECLARATION)
  end

  def one_dynamic_schema : CrystalClick::StorageColumnSchema
    CrystalClick::StorageColumnSchema.parse(ONE_DYNAMIC_SCHEMA_DECLARATION)
  end

  def two_dynamic_schema : CrystalClick::StorageColumnSchema
    CrystalClick::StorageColumnSchema.parse(TWO_DYNAMIC_SCHEMA_DECLARATION)
  end

  def json_context(site_path : String) : CrystalClick::CompactJsonWriteContext
    schema = CrystalClick::ObjectDocumentSchema.parse_declaration(JSON_DECLARATION)
    object = CrystalClick::ObjectStructure.new(
      [] of String,
      version: 4_u64,
      shared_data_version: 0_u64,
      bucket_count: 1_u64,
      statistics: CrystalClick::StructureStatistics.new(
        [] of UInt64,
        [] of CrystalClick::StructureStatistic,
      ),
    )
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      object,
      {} of String => CrystalClick::DynamicStructure,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(structures, schema.typed_paths)
    CrystalClick::CompactJsonWriteContext.new(
      {site_path => plan} of String => CrystalClick::ObjectDocumentPlan,
    )
  end

  def dynamic_context(
    ordinary_type : String = "UInt8",
    counts : Array(UInt64) = [0_u64, 1_u64],
  ) : CrystalClick::CompactDynamicWriteContext
    type = CrystalClick::BinaryDataType.primitive(ordinary_type)
    structure = CrystalClick::DynamicStructure.new(
      [type] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new(counts, [] of CrystalClick::StructureStatistic),
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
    CrystalClick::CompactDynamicWriteContext.new(
      {"root" => structure} of String => CrystalClick::DynamicStructure,
    )
  end

  def column(
    schema : CrystalClick::StorageColumnSchema,
    json_site : String,
    dynamic_contexts : Hash(String, CrystalClick::CompactDynamicWriteContext) = {} of String => CrystalClick::CompactDynamicWriteContext,
  ) : CrystalClick::CompactPartColumn
    CrystalClick::CompactPartColumn.json(
      "trace",
      schema,
      [] of Array(CrystalClick::StorageColumnValue),
      json_context(json_site),
      dynamic_contexts: dynamic_contexts,
    )
  end
end

describe "W284 recursive Dynamic context ownership" do
  it "keeps default-empty contexts valid for existing static Compact JSON" do
    fixture = CompactRecursiveDynamicW284ContextAdversaryFixture
    column = fixture.column(fixture.static_schema, "root/tuple[0]")
    context = column.json_input.recursive_dynamic_context

    context.site_count.should eq(0)
    context.has_site?(CompactRecursiveDynamicW284ContextAdversaryFixture::DYNAMIC_SITE).should be_false
  end

  it "rejects missing and surplus bindings through the public factory and preflight helper" do
    fixture = CompactRecursiveDynamicW284ContextAdversaryFixture
    schema = fixture.one_dynamic_schema
    valid = fixture.dynamic_context
    empty = {} of String => CrystalClick::CompactDynamicWriteContext
    surplus = {
      CompactRecursiveDynamicW284ContextAdversaryFixture::DYNAMIC_SITE => valid,
      "root/array[0]/tuple[0]"                                         => valid,
    } of String => CrystalClick::CompactDynamicWriteContext

    expect_raises(CrystalClick::UnsupportedFormatError) do
      fixture.column(schema, CompactRecursiveDynamicW284ContextAdversaryFixture::JSON_SITE, empty)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      fixture.column(schema, CompactRecursiveDynamicW284ContextAdversaryFixture::JSON_SITE, surplus)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::CompactRecursiveDynamicWriteContext.validate_site_contexts!(schema, surplus)
    end
  end

  it "rejects wrong-node and noncanonical outer paths" do
    fixture = CompactRecursiveDynamicW284ContextAdversaryFixture
    schema = fixture.one_dynamic_schema
    valid = fixture.dynamic_context
    invalid_paths = [
      "root/array[0]/tuple[0]",
      "root/array[0]/tuple[01]",
      "root/array[0]/tuple[2147483648]",
      "root/array[0]/tuple[1]/array[0]",
    ] of String

    invalid_paths.each do |path|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        fixture.column(
          schema,
          CompactRecursiveDynamicW284ContextAdversaryFixture::JSON_SITE,
          {path => valid} of String => CrystalClick::CompactDynamicWriteContext,
        )
      end
    end
  end

  it "allows exact immutable context reuse at two compatible Dynamic sites" do
    fixture = CompactRecursiveDynamicW284ContextAdversaryFixture
    shared = fixture.dynamic_context
    supplied = {
      CompactRecursiveDynamicW284ContextAdversaryFixture::LEFT_DYNAMIC_SITE  => shared,
      CompactRecursiveDynamicW284ContextAdversaryFixture::RIGHT_DYNAMIC_SITE => shared,
    } of String => CrystalClick::CompactDynamicWriteContext
    column = fixture.column(fixture.two_dynamic_schema, "root/tuple[0]", supplied)
    context = column.json_input.recursive_dynamic_context

    context.site_count.should eq(2)
    context.site_context_for(CompactRecursiveDynamicW284ContextAdversaryFixture::LEFT_DYNAMIC_SITE).same?(shared).should be_true
    context.site_context_for(CompactRecursiveDynamicW284ContextAdversaryFixture::RIGHT_DYNAMIC_SITE).same?(shared).should be_true
    context.same_context?(
      CrystalClick::CompactRecursiveDynamicWriteContext.new(
        fixture.two_dynamic_schema,
        {
          CompactRecursiveDynamicW284ContextAdversaryFixture::RIGHT_DYNAMIC_SITE => fixture.dynamic_context,
          CompactRecursiveDynamicW284ContextAdversaryFixture::LEFT_DYNAMIC_SITE  => fixture.dynamic_context,
        } of String => CrystalClick::CompactDynamicWriteContext,
      ),
    ).should be_true
  end

  it "detaches caller keys and maps and isolates returned mutable accessors" do
    fixture = CompactRecursiveDynamicW284ContextAdversaryFixture
    caller_key = String.new(CompactRecursiveDynamicW284ContextAdversaryFixture::DYNAMIC_SITE.to_slice)
    inner = fixture.dynamic_context
    caller_map = {caller_key => inner} of String => CrystalClick::CompactDynamicWriteContext
    column = fixture.column(
      fixture.one_dynamic_schema,
      CompactRecursiveDynamicW284ContextAdversaryFixture::JSON_SITE,
      caller_map,
    )

    caller_key.to_unsafe[0] = 'X'.ord.to_u8
    caller_map.clear
    context = column.json_input.recursive_dynamic_context
    context.has_site?(CompactRecursiveDynamicW284ContextAdversaryFixture::DYNAMIC_SITE).should be_true
    context.has_site?(caller_key).should be_false

    exposed = context.site_contexts
    exposed_key = exposed.keys.first
    exposed_key.to_unsafe[0] = 'X'.ord.to_u8
    exposed.clear
    context.has_site?(CompactRecursiveDynamicW284ContextAdversaryFixture::DYNAMIC_SITE).should be_true

    exposed_inner_sites = inner.site_structures
    exposed_inner_sites.clear
    structure = inner.structure_at?("root").not_nil!
    changed_types = structure.types
    changed_types.clear
    structure.type_count.should eq(1)
    changed_counts = structure.statistics.not_nil!.counts
    changed_counts[0] = 99_u64
    structure.statistics.not_nil!.count_at(0).should eq(0_u64)
  end

  it "compares recursive contexts by complete Dynamic roster and statistics values" do
    fixture = CompactRecursiveDynamicW284ContextAdversaryFixture
    schema = fixture.one_dynamic_schema

    original = CrystalClick::CompactRecursiveDynamicWriteContext.new(
      schema,
      {CompactRecursiveDynamicW284ContextAdversaryFixture::DYNAMIC_SITE => fixture.dynamic_context} of String => CrystalClick::CompactDynamicWriteContext,
    )
    equal_value = CrystalClick::CompactRecursiveDynamicWriteContext.new(
      schema,
      {CompactRecursiveDynamicW284ContextAdversaryFixture::DYNAMIC_SITE => fixture.dynamic_context} of String => CrystalClick::CompactDynamicWriteContext,
    )
    changed_roster = CrystalClick::CompactRecursiveDynamicWriteContext.new(
      schema,
      {CompactRecursiveDynamicW284ContextAdversaryFixture::DYNAMIC_SITE => fixture.dynamic_context("UInt16")} of String => CrystalClick::CompactDynamicWriteContext,
    )
    changed_statistics = CrystalClick::CompactRecursiveDynamicWriteContext.new(
      schema,
      {CompactRecursiveDynamicW284ContextAdversaryFixture::DYNAMIC_SITE => fixture.dynamic_context("UInt8", [1_u64, 0_u64])} of String => CrystalClick::CompactDynamicWriteContext,
    )

    original.same_context?(equal_value).should be_true
    original.same_context?(changed_roster).should be_false
    original.same_context?(changed_statistics).should be_false
  end

  it "validates the source declaration before direct-input context checks" do
    fixture = CompactRecursiveDynamicW284ContextAdversaryFixture
    actual_json_schema = CrystalClick::ObjectDocumentSchema.parse_declaration(
      CompactRecursiveDynamicW284ContextAdversaryFixture::JSON_DECLARATION,
    )
    mismatched_source = CrystalClick::StorageColumnSchema.object(actual_json_schema, "JSON")
    document = CrystalClick::ObjectDocument.new({} of String => CrystalClick::BinaryValue)
    granules = [
      [CrystalClick::StorageColumnValue.object_document(document)] of CrystalClick::StorageColumnValue,
    ] of Array(CrystalClick::StorageColumnValue)
    mismatched_context = CrystalClick::CompactRecursiveDynamicWriteContext.new(
      fixture.one_dynamic_schema,
      {CompactRecursiveDynamicW284ContextAdversaryFixture::DYNAMIC_SITE => fixture.dynamic_context} of String => CrystalClick::CompactDynamicWriteContext,
    )

    error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::CompactJsonColumnInput.new(
        "trace",
        mismatched_source,
        granules,
        fixture.json_context("root"),
        recursive_dynamic_context: mismatched_context,
      )
    end
    error.message.should eq("Compact JSON root schema differs from its source declaration")
  end
end
