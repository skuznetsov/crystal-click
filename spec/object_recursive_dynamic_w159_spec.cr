require "./spec_helper"

private def w159_main_fixture : Tuple(
  CrystalClick::ObjectDocumentSchema,
  CrystalClick::ObjectDocumentPlan,
  Array(Array(CrystalClick::ObjectDocument)),
)
  string = CrystalClick::BinaryDataType.primitive("String")
  bool = CrystalClick::BinaryDataType.primitive("Bool")
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")

  array_dynamic = CrystalClick::BinaryDataType.dynamic(2)
  array_type = CrystalClick::BinaryDataType.array(array_dynamic)
  pair_dynamic = CrystalClick::BinaryDataType.dynamic(2)
  pair_type = CrystalClick::BinaryDataType.tuple(
    [pair_dynamic, pair_dynamic] of CrystalClick::BinaryDataType,
    ["left", "right"] of String,
  )
  lookup_dynamic = CrystalClick::BinaryDataType.dynamic(1)
  lookup_type = CrystalClick::BinaryDataType.map(string, lookup_dynamic)
  nullable_dynamic = CrystalClick::BinaryDataType.dynamic(1)
  low_cardinality = CrystalClick::BinaryDataType.low_cardinality(string)
  nullable_inner = CrystalClick::BinaryDataType.tuple(
    [nullable_dynamic, low_cardinality] of CrystalClick::BinaryDataType,
    ["item", "tag"] of String,
  )
  nullable_type = CrystalClick::BinaryDataType.nullable(nullable_inner)
  choice_dynamic = CrystalClick::BinaryDataType.dynamic(1)
  choice_array = CrystalClick::BinaryDataType.array(choice_dynamic)
  choice_type = CrystalClick::BinaryDataType.variant(
    [choice_array, string] of CrystalClick::BinaryDataType,
  )
  choice_array_arm = choice_type.children.index(choice_array).not_nil!
  choice_string_arm = choice_type.children.index(string).not_nil!
  zero_dynamic = CrystalClick::BinaryDataType.dynamic(0)
  zero_array = CrystalClick::BinaryDataType.array(zero_dynamic)

  schema = CrystalClick::ObjectDocumentSchema.new({
    "array"  => array_type,
    "choice" => choice_type,
    "label"  => low_cardinality,
    "lookup" => lookup_type,
    "maybe"  => nullable_type,
    "pair"   => pair_type,
    "zeroes" => zero_array,
  })
  schema.declaration.should eq(
    "JSON(array Array(Dynamic(max_types=2)), " +
    "choice Variant(Array(Dynamic(max_types=1)), String), " +
    "label LowCardinality(String), lookup Map(String, Dynamic(max_types=1)), " +
    "maybe Nullable(Tuple(item Dynamic(max_types=1), tag LowCardinality(String))), " +
    "pair Tuple(left Dynamic(max_types=2), right Dynamic(max_types=2)), " +
    "zeroes Array(Dynamic(max_types=0)))"
  )
  CrystalClick::ObjectDocumentSchema.parse_declaration(schema.declaration).typed_paths.should eq(schema.typed_paths)

  choice_site = "root.arm.#{choice_array_arm}.elements"
  sites = {
    "array" => {
      "root.elements" => CrystalClick::DynamicStructure.new([uint64, bool] of CrystalClick::BinaryDataType),
    },
    "choice" => {
      choice_site => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType),
    },
    "lookup" => {
      "root.elements.field.1" => CrystalClick::DynamicStructure.new([bool] of CrystalClick::BinaryDataType),
    },
    "maybe" => {
      "root.nested.field.0" => CrystalClick::DynamicStructure.new([uint64] of CrystalClick::BinaryDataType),
    },
    "pair" => {
      "root.field.0" => CrystalClick::DynamicStructure.new([string, uint64] of CrystalClick::BinaryDataType),
      "root.field.1" => CrystalClick::DynamicStructure.new([bool, uint64] of CrystalClick::BinaryDataType),
    },
    "zeroes" => {
      "root.elements" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType),
    },
  }
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
  plan = CrystalClick::ObjectDocumentPlan.new(
    structures,
    schema.typed_paths,
    typed_dynamic_sites: sites,
  )
  plan.typed_dynamic_count.should eq(6)
  plan.typed_dynamic_sites_for("pair").keys.sort.should eq(["root.field.0", "root.field.1"])
  plan.typed_dynamic_sites_for("choice").keys.should eq([choice_site])
  plan.has_typed_dynamic?("label").should be_false

  dyn = ->(type : CrystalClick::BinaryDataType, child : CrystalClick::BinaryValue?) {
    CrystalClick::BinaryValue.dynamic(type, child)
  }
  array_value = ->(values : Array(CrystalClick::BinaryValue)) {
    CrystalClick::BinaryValue.array(array_type, values)
  }
  pair_value = ->(left : CrystalClick::BinaryValue, right : CrystalClick::BinaryValue) {
    CrystalClick::BinaryValue.tuple(pair_type, [left, right] of CrystalClick::BinaryValue)
  }
  lookup_value = ->(values : Array(CrystalClick::BinaryValue)) {
    CrystalClick::BinaryValue.map(lookup_type, values)
  }
  maybe_value = ->(child : CrystalClick::BinaryValue?) {
    CrystalClick::BinaryValue.nullable(nullable_type, child)
  }
  choice_array_value = ->(values : Array(CrystalClick::BinaryValue)) {
    array_child = CrystalClick::BinaryValue.array(choice_array, values)
    CrystalClick::BinaryValue.variant(choice_type, choice_array_arm, array_child)
  }
  choice_string_value = ->(text : String) {
    CrystalClick::BinaryValue.variant(
      choice_type, choice_string_arm, CrystalClick::BinaryValue.string(text)
    )
  }
  label_value = ->(text : String) {
    CrystalClick::BinaryValue.low_cardinality(low_cardinality, CrystalClick::BinaryValue.string(text))
  }
  zero_value = ->(values : Array(CrystalClick::BinaryValue)) {
    CrystalClick::BinaryValue.array(zero_array, values)
  }

  documents = [
    [CrystalClick::ObjectDocument.new({
      "array" => array_value.call([
        dyn.call(array_dynamic, CrystalClick::BinaryValue.uint64(7_u64)),
        dyn.call(array_dynamic, nil),
      ] of CrystalClick::BinaryValue),
      "choice" => choice_array_value.call([
        dyn.call(choice_dynamic, CrystalClick::BinaryValue.uint64(42_u64)),
      ] of CrystalClick::BinaryValue),
      "label"  => label_value.call("repeat"),
      "lookup" => lookup_value.call([
        CrystalClick::BinaryValue.string("a"), dyn.call(lookup_dynamic, CrystalClick::BinaryValue.bool(false)),
      ] of CrystalClick::BinaryValue),
      "maybe" => maybe_value.call(CrystalClick::BinaryValue.tuple(nullable_inner, [
        dyn.call(nullable_dynamic, CrystalClick::BinaryValue.uint64(4_u64)),
        CrystalClick::BinaryValue.low_cardinality(low_cardinality, CrystalClick::BinaryValue.string("repeat")),
      ] of CrystalClick::BinaryValue)),
      "pair" => pair_value.call(
        dyn.call(pair_dynamic, CrystalClick::BinaryValue.string("left-0")),
        dyn.call(pair_dynamic, CrystalClick::BinaryValue.bool(true)),
      ),
      "zeroes" => zero_value.call([dyn.call(zero_dynamic, nil)] of CrystalClick::BinaryValue),
    })] of CrystalClick::ObjectDocument,
    [CrystalClick::ObjectDocument.new({
      "array"  => array_value.call([] of CrystalClick::BinaryValue),
      "choice" => choice_string_value.call("plain"),
      "label"  => label_value.call("repeat"),
      "lookup" => lookup_value.call([] of CrystalClick::BinaryValue),
      "maybe"  => maybe_value.call(nil),
      "pair"   => pair_value.call(
        dyn.call(pair_dynamic, CrystalClick::BinaryValue.uint64(8_u64)),
        dyn.call(pair_dynamic, CrystalClick::BinaryValue.uint64(9_u64)),
      ),
      "zeroes" => zero_value.call([] of CrystalClick::BinaryValue),
    })] of CrystalClick::ObjectDocument,
    [CrystalClick::ObjectDocument.new({
      "array" => array_value.call([
        dyn.call(array_dynamic, CrystalClick::BinaryValue.bool(false)),
        dyn.call(array_dynamic, CrystalClick::BinaryValue.string("array-spill")),
      ] of CrystalClick::BinaryValue),
      "choice" => choice_array_value.call([
        dyn.call(choice_dynamic, nil),
        dyn.call(choice_dynamic, CrystalClick::BinaryValue.string("variant-spill")),
      ] of CrystalClick::BinaryValue),
      "label"  => label_value.call("other"),
      "lookup" => lookup_value.call([
        CrystalClick::BinaryValue.string("x"), dyn.call(lookup_dynamic, CrystalClick::BinaryValue.bool(true)),
      ] of CrystalClick::BinaryValue),
      "maybe" => maybe_value.call(CrystalClick::BinaryValue.tuple(nullable_inner, [
        dyn.call(nullable_dynamic, CrystalClick::BinaryValue.string("tuple-spill")),
        CrystalClick::BinaryValue.low_cardinality(low_cardinality, CrystalClick::BinaryValue.string("repeat")),
      ] of CrystalClick::BinaryValue)),
      "pair" => pair_value.call(
        dyn.call(pair_dynamic, CrystalClick::BinaryValue.string("left-2")),
        dyn.call(pair_dynamic, CrystalClick::BinaryValue.string("right-spill")),
      ),
      "zeroes" => zero_value.call([
        dyn.call(zero_dynamic, CrystalClick::BinaryValue.string("zero-spill")),
      ] of CrystalClick::BinaryValue),
    })] of CrystalClick::ObjectDocument,
  ] of Array(CrystalClick::ObjectDocument)

  {schema, plan, documents}
end

private def w159_signature(value : CrystalClick::BinaryValue) : String
  type = value.type
  case type.tag
  when CrystalClick::BinaryDataType::TAG_DYNAMIC
    value.is_null? ? "DNULL" : "D#{w159_signature(value.child_at(0))}"
  when CrystalClick::BinaryDataType::TAG_ARRAY
    "A[#{(0...value.element_count).map { |index| w159_signature(value.element_at(index)) }.join(",")}]"
  when CrystalClick::BinaryDataType::TAG_MAP
    entries = (0...value.child_count).step(by: 2).map do |index|
      "#{w159_signature(value.child_at(index))}=#{w159_signature(value.child_at(index + 1))}"
    end
    "M[#{entries.join(",")}]"
  when CrystalClick::BinaryDataType::TAG_NAMED_TUPLE, CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE
    "(#{(0...value.child_count).map { |index| w159_signature(value.child_at(index)) }.join(",")})"
  when CrystalClick::BinaryDataType::TAG_NULLABLE
    value.is_null? ? "NULL" : "N#{w159_signature(value.child_at(0))}"
  when CrystalClick::BinaryDataType::TAG_VARIANT
    value.is_null? ? "VNULL" : "V#{value.variant_index?}:#{w159_signature(value.child_at(0))}"
  when CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY
    "LC#{w159_signature(value.child_at(0))}"
  when CrystalClick::BinaryDataType::TAG_STRING
    "S#{value.as_string}"
  when CrystalClick::BinaryDataType::TAG_BOOL
    "B#{value.as_bool}"
  when CrystalClick::BinaryDataType::TAG_UINT64
    "U#{value.as_uint64}"
  else
    raise "unexpected W159 value type: #{type.name}"
  end
end

private def w159_document_signature(document : CrystalClick::ObjectDocument) : Array(String)
  ["array", "choice", "label", "lookup", "maybe", "pair", "zeroes"].map do |path|
    w159_signature(document.value_for(path))
  end
end

private def w159_document_signatures(
  marks : Array(Array(CrystalClick::ObjectDocument)),
) : Array(Array(Array(String)))
  marks.map { |mark| mark.map { |document| w159_document_signature(document) } }
end

private def w159_catalog_part_root(root : String, declaration : String) : String
  database_uuid = "a1590000-0000-4000-8000-000000000159"
  table_uuid = "b1590000-0000-4000-8000-000000000159"
  FileUtils.mkdir_p(File.join(root, "metadata"))
  database = File.join(root, "store", "a15", database_uuid)
  table = File.join(root, "store", "b15", table_uuid)
  FileUtils.mkdir_p(database)
  FileUtils.mkdir_p(table)
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(
    File.join(database, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n`pk` UInt64,\n`payload` #{declaration}\n)\nENGINE = MergeTree\nORDER BY pk\n",
  )
  File.write(File.join(table, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table, "detached"))
  table
end

describe "W159 recursive declared Dynamic Object fields" do
  it "pairs per-site rosters through codec windows and complete public part consumers" do
    schema, plan, marks = w159_main_fixture
    expected = [
      [["A[DU7,DNULL]", "V0:A[DU42]", "LCSrepeat", "M[Sa=DBfalse]", "N(DU4,LCSrepeat)", "(DSleft-0,DBtrue)", "A[DNULL]"]],
      [["A[]", "V1:Splain", "LCSrepeat", "M[]", "NULL", "(DU8,DU9)", "A[]"]],
      [["A[DBfalse,DSarray-spill]", "V0:A[DNULL,DSvariant-spill]", "LCSother", "M[Sx=DBtrue]", "N(DStuple-spill,LCSrepeat)", "(DSleft-2,DSright-spill)", "A[DSzero-spill]"]],
    ]

    streams = CrystalClick::ObjectDocumentCodec.encode(plan, marks, mode: 0_u64)
    physical = CrystalClick::ObjectDocumentPhysicalPlan.new("payload", plan)
    physical.typed_dynamic("array").prefix_size_for("root.elements.discriminators").should eq(8)
    physical.typed_dynamic("pair").prefix_size_for("root.field.0.discriminators").should eq(8)
    physical.typed_dynamic("pair").prefix_size_for("root.field.1.discriminators").should eq(8)
    physical.typed_dynamic("pair").structure_name_for("root.field.1").should end_with(".dynamic_structure")
    w159_document_signatures(CrystalClick::ObjectDocumentCodec.decode(schema.typed_paths, streams)).should eq(expected)
    w159_document_signatures(
      CrystalClick::ObjectDocumentCodec.decode(schema.typed_paths, streams, first_mark: 1, mark_count: 1),
    ).should eq([expected[1]])
    CrystalClick::ObjectDocumentCodec.decode(schema.typed_paths, streams, first_mark: 3, mark_count: 0).should be_empty

    root = File.tempname("crystal-click-w159-recursive-dynamic-catalog-")
    Dir.mkdir(root)
    begin
      table_path = w159_catalog_part_root(root, schema.declaration)
      part = File.join(table_path, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_object_pair(
        part,
        "pk",
        Slice[1_u64, 2_u64, 3_u64],
        "payload",
        schema,
        plan,
        marks,
        rows_per_mark: 1,
        mode: 0_u64,
        frame_bytes: 64,
      ).should eq(part)

      descriptor = CrystalClick::ObjectDocumentFileReader.inspect(part, "payload", schema.typed_paths, hashed: true)
      descriptor.row_count.should eq(3_u64)
      descriptor.mark_row_counts.should eq([1_u64, 1_u64, 1_u64])
      full = CrystalClick::ObjectDocumentFileReader.read(part, "payload", schema.typed_paths, hashed: true)
      w159_document_signatures(full).should eq(expected)
      middle = CrystalClick::ObjectDocumentFileReader.read(
        part, "payload", schema.typed_paths, first_mark: 1, mark_count: 1, hashed: true
      )
      w159_document_signatures(middle).should eq([expected[1]])
      late = CrystalClick::ObjectDocumentFileReader.read(
        part, "payload", schema.typed_paths, first_mark: 2, mark_count: 1, hashed: true
      )
      w159_document_signatures(late).should eq([expected[2]])
      CrystalClick::ObjectDocumentFileReader.read(
        part, "payload", schema.typed_paths, first_mark: 3, mark_count: 0, hashed: true
      ).should be_empty

      column = CrystalClick::ObjectColumnReader.open(part, "payload", schema)
      w159_document_signatures(column.read_marks(0, 3)).should eq(expected)
      w159_document_signatures(column.read_marks(2, 1)).should eq([expected[2]])
      column.read_marks(3, 0).should be_empty

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
      observed = [] of Array(String)
      table.scan_typed_window(0_u64, 3) do |batch|
        batch.object_documents_for("payload").each do |document|
          observed << w159_document_signature(document)
        end
      end
      observed.should eq(expected.map(&.first))
      middle_table = [] of Array(String)
      table.scan_typed_window(2_u64, 1) do |batch|
        batch.object_documents_for("payload").each do |document|
          middle_table << w159_document_signature(document)
        end
      end
      middle_table.should eq([expected[2][0]])
      table.scan_typed_window(3_u64, 1) { raise "zero-row table window unexpectedly materialized a batch" }

      catalog_values = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["payload"].values
      catalog_values.map { |value| w159_document_signature(value.as(CrystalClick::ObjectDocument)) }
        .should eq(expected.map(&.first))
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
