require "./spec_helper"

private def w140_consumers_tuple_type(leaf : CrystalClick::BinaryDataType) : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.tuple(
    [leaf, CrystalClick::BinaryDataType.primitive("String")] of CrystalClick::BinaryDataType,
    ["n", "s"] of String,
  )
end

private def w140_consumers_type : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.array(w140_consumers_tuple_type(CrystalClick::BinaryDataType.primitive("UInt16")))
end

private def w140_consumers_enum_type : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.enum16([
    {"zero", 0_i16}, {"one", 1_i16},
  ] of CrystalClick::BinaryEnumDefinition::Entry)
end

private def w140_consumers_enum_nested_type : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.array(w140_consumers_tuple_type(w140_consumers_enum_type))
end

private def w140_consumers_schema(type : CrystalClick::BinaryDataType) : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.new({"items" => type})
end

private def w140_consumers_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    schema.typed_paths,
  )
end

private def w140_consumers_array(
  type : CrystalClick::BinaryDataType,
  entries : Array(Tuple(UInt16, String)),
) : CrystalClick::BinaryValue
  tuple_type = type.child_at(0)
  values = entries.map do |entry|
    number = entry[0]
    number_value = CrystalClick::BinaryValue.fixed(
      tuple_type.child_at(0),
      Bytes[number.to_u8, (number >> 8).to_u8],
    )
    CrystalClick::BinaryValue.tuple(
      tuple_type,
      [number_value, CrystalClick::BinaryValue.string(entry[1])],
    )
  end
  CrystalClick::BinaryValue.array(type, values)
end

private def w140_consumers_document(
  type : CrystalClick::BinaryDataType,
  entries : Array(Tuple(UInt16, String)),
) : CrystalClick::ObjectDocument
  CrystalClick::ObjectDocument.new({"items" => w140_consumers_array(type, entries)})
end

private def w140_consumers_granules(
  type : CrystalClick::BinaryDataType,
  rows : Array(Array(Tuple(UInt16, String))),
) : Array(Array(CrystalClick::ObjectDocument))
  rows.map do |entries|
    [w140_consumers_document(type, entries)]
  end
end

private def w140_consumers_read_items(value : CrystalClick::BinaryValue) : Array(Tuple(UInt16, String))
  value.type.should eq(w140_consumers_type)
  rows = [] of Tuple(UInt16, String)
  value.element_count.times do |index|
    tuple = value.element_at(index)
    tuple.type.should eq(w140_consumers_tuple_type(CrystalClick::BinaryDataType.primitive("UInt16")))
    number = tuple.element_at(0)
    decoded = number.byte_at(0).to_u16 | (number.byte_at(1).to_u16 << 8)
    rows << {decoded, tuple.element_at(1).as_string}
  end
  rows
end

private def with_w140_consumers_root(&)
  root = File.tempname("crystal-click-w140-recursive-consumers-")
  Dir.mkdir(root)
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

private def w140_consumers_catalog(root : String, declaration : String) : String
  database_uuid = "a1400000-0000-4000-8000-000000000140"
  table_uuid = "b1400000-0000-4000-8000-000000000140"
  FileUtils.mkdir_p(File.join(root, "metadata"))
  database = File.join(root, "store", "a14", database_uuid)
  table = File.join(root, "store", "b14", table_uuid)
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

private def w140_consumers_write(
  path : String,
  keys : Slice(UInt64),
  schema : CrystalClick::ObjectDocumentSchema,
  granules : Array(Array(CrystalClick::ObjectDocument)),
) : String
  CrystalClick::WidePartWriter.write_uint64_object_pair(
    path, "pk", keys, "payload", schema, w140_consumers_plan(schema), granules,
    rows_per_mark: 1,
  )
end

describe "W140 recursive Object consumer boundaries" do
  it "rejects a nested nominal value mismatch before publishing a part or leaving a stage" do
    with_w140_consumers_root do |root|
      schema = w140_consumers_schema(w140_consumers_type)
      wrong_tuple = CrystalClick::BinaryDataType.tuple(
        [CrystalClick::BinaryDataType.primitive("UInt16"), CrystalClick::BinaryDataType.primitive("String")] of CrystalClick::BinaryDataType,
      )
      wrong_type = CrystalClick::BinaryDataType.array(wrong_tuple)
      wrong_document = w140_consumers_document(wrong_type, [{0_u16, "same two-byte carrier"}])
      target = File.join(root, "all_1_1_0")

      expect_raises(CrystalClick::UnsupportedFormatError, "typed Object field has a descriptor that differs from its schema") do
        w140_consumers_write(target, Slice[1_u64], schema, [[wrong_document]])
      end
      Dir.children(root).should be_empty
    end
  end

  it "rejects same-carrier nested Object schema drift before callbacks, even when the later part has no candidate marks" do
    with_w140_consumers_root do |root|
      schema = w140_consumers_schema(w140_consumers_type)
      type = w140_consumers_type
      table_path = w140_consumers_catalog(root, schema.declaration)
      first_values = [
        [{0_u16, "zero"}, {1_u16, "one"}],
        [] of Tuple(UInt16, String),
      ]
      later_values = [
        [{0_u16, "later-zero"}],
        [{1_u16, "later-one"}],
      ]
      first = w140_consumers_write(
        File.join(table_path, "all_1_1_0"), Slice[1_u64, 2_u64], schema,
        w140_consumers_granules(type, first_values),
      )
      later = w140_consumers_write(
        File.join(table_path, "all_2_2_0"), Slice[10_u64, 11_u64], schema,
        w140_consumers_granules(type, later_values),
      )

      # First establish exact nested values and retained document ownership
      # with both matching parts, then show the bounded range leaves the later
      # part unselected before corrupting only its nominal descriptor.
      table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      observed = [] of Tuple(UInt64, Array(Tuple(UInt16, String)))
      retained = [] of CrystalClick::ObjectDocument
      table.scan_uint64_pk_candidates(["pk", "payload"], lower_bound: 1_u64, upper_bound: 11_u64) do |batch|
        keys = batch.values_for("pk")
        documents = batch.object_documents_for("payload")
        keys.size.should eq(documents.size)
        keys.each_with_index do |key, index|
          document = documents[index]
          observed << {key, w140_consumers_read_items(document.value_for("items"))}
          retained << document
        end
        nil
      end
      observed.should eq([
        {1_u64, [{0_u16, "zero"}, {1_u16, "one"}]},
        {2_u64, [] of Tuple(UInt16, String)},
        {10_u64, [{0_u16, "later-zero"}]},
        {11_u64, [{1_u16, "later-one"}]},
      ])
      retained.map { |document| w140_consumers_read_items(document.value_for("items")) }.should eq(observed.map(&.[1]))

      selected_keys = [] of UInt64
      table.scan_uint64_pk_candidates(["pk", "payload"], lower_bound: 1_u64, upper_bound: 2_u64) do |batch|
        selected_keys.concat(batch.values_for("pk"))
        nil
      end
      selected_keys.should eq([1_u64, 2_u64])

      enum_schema = w140_consumers_schema(w140_consumers_enum_nested_type)
      columns_path = File.join(later, "columns.txt")
      columns = File.read(columns_path)
      columns.includes?(schema.declaration).should be_true
      changed = columns.sub(schema.declaration, enum_schema.declaration)
      changed.should_not eq(columns)
      File.write(columns_path, changed)

      callbacks = 0
      drifted_table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      expect_raises(CrystalClick::CorruptPartError, "selected columns have different types across parts") do
        drifted_table.scan_uint64_pk_candidates(["pk", "payload"], lower_bound: 1_u64, upper_bound: 2_u64) do |_batch|
          callbacks += 1
          nil
        end
      end
      callbacks.should eq(0)
      File.directory?(first).should be_true
    end
  end
end
