require "./spec_helper"

private def w138_root_types(
  e8_top_label : String = "top",
) : Hash(String, CrystalClick::BinaryDataType)
  {
    "e8" => CrystalClick::BinaryDataType.enum8([
      {e8_top_label, 127_i16},
      {"zero", 0_i16},
      {"negative", -1_i16},
      {"minimum", -128_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry),
    "e16" => CrystalClick::BinaryDataType.enum16([
      {"maximum", 32_767_i16},
      {"zero", 0_i16},
      {"negative", -1_i16},
      {"minimum", -32_768_i16},
    ] of CrystalClick::BinaryEnumDefinition::Entry),
  }
end

private def w138_root_schema(
  types : Hash(String, CrystalClick::BinaryDataType) = w138_root_types,
) : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.new(types, max_dynamic_paths: 0, max_dynamic_types: 0)
end

private def w138_root_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
  w138_root_plan_types(schema.typed_paths)
end

private def w138_root_plan_types(types : Hash(String, CrystalClick::BinaryDataType)) : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    types,
  )
end

private def w138_root_enum8_code(row : Int32) : Int16
  case row
  when 0 then -128_i16
  when 1 then -1_i16
  when 2 then 0_i16
  when 3 then 127_i16
  else
    raise ArgumentError.new("unsupported W138 Enum row")
  end
end

private def w138_root_enum16_code(row : Int32) : Int16
  case row
  when 0 then -32_768_i16
  when 1 then -1_i16
  when 2 then 0_i16
  when 3 then 32_767_i16
  else
    raise ArgumentError.new("unsupported W138 Enum row")
  end
end

private def w138_root_enum8_bytes(row : Int32) : Bytes
  Bytes[w138_root_enum8_code(row).to_i8.unsafe_as(UInt8)]
end

private def w138_root_enum16_bytes(row : Int32) : Bytes
  bits = w138_root_enum16_code(row).unsafe_as(UInt16)
  Bytes[(bits & 0xff_u16).to_u8, (bits >> 8).to_u8]
end

private def w138_root_document(row : Int32, schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocument
  types = schema.typed_paths
  CrystalClick::ObjectDocument.new({
    "e8"  => CrystalClick::BinaryValue.fixed(types["e8"], w138_root_enum8_bytes(row)),
    "e16" => CrystalClick::BinaryValue.fixed(types["e16"], w138_root_enum16_bytes(row)),
  } of String => CrystalClick::BinaryValue)
end

private def w138_root_documents_with_enum8_type(
  schema : CrystalClick::ObjectDocumentSchema,
  enum8_type : CrystalClick::BinaryDataType,
) : Array(Array(CrystalClick::ObjectDocument))
  rows = (0..3).map do |row|
    CrystalClick::ObjectDocument.new({
      "e8"  => CrystalClick::BinaryValue.fixed(enum8_type, w138_root_enum8_bytes(row)),
      "e16" => CrystalClick::BinaryValue.fixed(schema.typed_paths["e16"], w138_root_enum16_bytes(row)),
    } of String => CrystalClick::BinaryValue)
  end
  [rows[0, 2], rows[2, 2]] of Array(CrystalClick::ObjectDocument)
end

private def w138_root_documents(schema : CrystalClick::ObjectDocumentSchema) : Array(Array(CrystalClick::ObjectDocument))
  rows = (0..3).map { |row| w138_root_document(row, schema) }
  [rows[0, 2], rows[2, 2]] of Array(CrystalClick::ObjectDocument)
end

private def w138_root_assert_document(
  actual : CrystalClick::ObjectDocument,
  schema : CrystalClick::ObjectDocumentSchema,
  row : Int32,
) : Nil
  actual.paths.should eq(["e16", "e8"])
  actual.value_for("e8").type.should eq(schema.typed_paths["e8"])
  actual.value_for("e8").bytes.should eq(w138_root_enum8_bytes(row))
  actual.value_for("e16").type.should eq(schema.typed_paths["e16"])
  actual.value_for("e16").bytes.should eq(w138_root_enum16_bytes(row))
  nil
end

private def w138_root_assert_marks(
  actual : Array(Array(CrystalClick::ObjectDocument)),
  schema : CrystalClick::ObjectDocumentSchema,
  first_row : Int32,
  expected_mark_count : Int32,
) : Nil
  actual.size.should eq(expected_mark_count)
  row = first_row
  actual.each do |mark|
    mark.size.should eq(2)
    mark.each do |document|
      w138_root_assert_document(document, schema, row)
      row += 1
    end
  end
  nil
end

private def with_w138_root(&)
  root = File.tempname("crystal-click-w138-root-")
  Dir.mkdir(root)
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

private def w138_root_write(
  path : String,
  schema : CrystalClick::ObjectDocumentSchema,
  keys : Slice(UInt64) = Slice[0_u64, 2_u64, 8_u64, 10_u64],
) : String
  CrystalClick::WidePartWriter.write_uint64_object_pair(
    path,
    "pk",
    keys,
    "payload",
    schema,
    w138_root_plan(schema),
    w138_root_documents(schema),
    rows_per_mark: 2,
    frame_bytes: 16,
  )
end

private def w138_root_catalog(root : String, declaration : String) : String
  database_uuid = "a1380000-0000-4000-8000-000000000138"
  table_uuid = "b1380000-0000-4000-8000-000000000138"
  FileUtils.mkdir_p(File.join(root, "metadata"))
  database = File.join(root, "store", "a13", database_uuid)
  table = File.join(root, "store", "b13", table_uuid)
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

describe "W138 declared Enum8 and Enum16 Object consumers" do
  it "preserves signed Enum codes through paired, file, and column full and selected reads" do
    schema = w138_root_schema
    streams = CrystalClick::ObjectDocumentCodec.encode(w138_root_plan(schema), w138_root_documents(schema))
    streams.mark_count.should eq(2)

    enum8 = streams.typed_for("e8").stream("root.data")
    enum8.bytes.should eq(Bytes[0x80_u8, 0xff_u8, 0x00_u8, 0x7f_u8])
    enum8.offsets.should eq([0_u64, 2_u64, 4_u64])
    enum16 = streams.typed_for("e16").stream("root.data")
    enum16.bytes.should eq(Bytes[
      0x00_u8, 0x80_u8, 0xff_u8, 0xff_u8,
      0x00_u8, 0x00_u8, 0xff_u8, 0x7f_u8,
    ])
    enum16.offsets.should eq([0_u64, 4_u64, 8_u64])

    w138_root_assert_marks(CrystalClick::ObjectDocumentCodec.decode(schema.typed_paths, streams), schema, 0, 2)
    w138_root_assert_marks(
      CrystalClick::ObjectDocumentCodec.decode(schema.typed_paths, streams, first_mark: 1, mark_count: 1),
      schema,
      2,
      1,
    )
    CrystalClick::ObjectDocumentCodec.decode(schema.typed_paths, streams, first_mark: 2, mark_count: 0).should be_empty

    with_w138_root do |root|
      part = w138_root_write(File.join(root, "all_1_1_0"), schema)
      w138_root_assert_marks(
        CrystalClick::ObjectDocumentFileReader.read(part, "payload", schema.typed_paths, hashed: true),
        schema,
        0,
        2,
      )
      w138_root_assert_marks(
        CrystalClick::ObjectDocumentFileReader.read(
          part, "payload", schema.typed_paths, first_mark: 1, mark_count: 1, hashed: true
        ),
        schema,
        2,
        1,
      )
      CrystalClick::ObjectDocumentFileReader.read(
        part, "payload", schema.typed_paths, first_mark: 2, mark_count: 0, hashed: true
      ).should be_empty

      column = CrystalClick::ObjectColumnReader.open(part, "payload", schema)
      column.row_count.should eq(4_u64)
      w138_root_assert_marks(column.read_marks(0, 2), schema, 0, 2)
      w138_root_assert_marks(column.read_marks(1, 1), schema, 2, 1)
      column.read_marks(2, 0).should be_empty
    end
  end

  it "materializes catalog and table Object documents across windows and UInt64 primary-key candidates" do
    schema = w138_root_schema
    with_w138_root do |root|
      table_path = w138_root_catalog(root, schema.declaration)
      w138_root_write(File.join(table_path, "all_1_1_0"), schema)
      catalog_table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      selected = catalog_table["payload"]
      documents = selected.values(max_rows: 4_u64).map(&.as(CrystalClick::ObjectDocument))
      documents.size.should eq(4)
      documents.each_with_index { |document, row| w138_root_assert_document(document, schema, row) }

      documents[1].paths.clear
      detached = documents[1].value_for("e16").bytes
      detached[0] ^= 0xff_u8
      w138_root_assert_document(documents[1], schema, 1)
      selected.values(max_rows: 4_u64).map(&.as(CrystalClick::ObjectDocument)).each_with_index do |document, row|
        w138_root_assert_document(document, schema, row)
      end

      table = CrystalClick::WidePartTable.open_selected_typed([File.join(table_path, "all_1_1_0")], ["payload", "pk"])
      table.columns.should eq(["payload", "pk"])
      table.column_types.should eq([{"payload", schema.declaration}, {"pk", "UInt64"}])

      keys = [] of UInt64
      table_documents = [] of CrystalClick::ObjectDocument
      table.scan_typed do |batch|
        keys.concat(batch.values_for("pk"))
        batch.object_documents_for("payload").each { |document| table_documents << document }
        nil
      end
      keys.should eq([0_u64, 2_u64, 8_u64, 10_u64])
      table_documents.each_with_index { |document, row| w138_root_assert_document(document, schema, row) }

      window_keys = [] of UInt64
      window_documents = [] of CrystalClick::ObjectDocument
      catalog_table.scan_typed_window(["payload", "pk"], 1_u64, 2) do |batch|
        window_keys.concat(batch.values_for("pk"))
        batch.object_documents_for("payload").each { |document| window_documents << document }
        nil
      end
      window_keys.should eq([2_u64, 8_u64])
      window_documents.size.should eq(2)
      w138_root_assert_document(window_documents[0], schema, 1)
      w138_root_assert_document(window_documents[1], schema, 2)

      candidate_keys = [] of UInt64
      candidate_codes = [] of Tuple(UInt64, Bytes)
      catalog_table.scan_uint64_pk_candidates(["pk", "payload"], lower_bound: 2_u64, upper_bound: 8_u64) do |batch|
        batch_keys = batch.values_for("pk")
        batch_documents = batch.object_documents_for("payload")
        batch_documents.size.should eq(batch_keys.size)
        candidate_keys.concat(batch_keys)
        batch_keys.each_with_index do |key, index|
          next unless 2_u64 <= key <= 8_u64
          candidate_codes << {key, batch_documents[index].value_for("e8").bytes}
        end
        nil
      end
      candidate_keys.should eq([0_u64, 2_u64, 8_u64, 10_u64])
      candidate_codes.should eq([
        {2_u64, w138_root_enum8_bytes(1)},
        {8_u64, w138_root_enum8_bytes(2)},
      ])
    end
  end

  it "refuses publication on enum-map mismatch and stops on later-part map drift before callbacks" do
    schema = w138_root_schema
    with_w138_root do |root|
      target = File.join(root, "rejected_1_1_0")
      changed_types = schema.typed_paths
      changed_enum = CrystalClick::BinaryDataType.enum8([
        {"renamed", 127_i16},
        {"zero", 0_i16},
        {"negative", -1_i16},
        {"minimum", -128_i16},
      ] of CrystalClick::BinaryEnumDefinition::Entry)
      changed_enum.should_not eq(schema.typed_paths["e8"])
      changed_types["e8"] = changed_enum
      error = expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_object_pair(
          target,
          "pk",
          Slice[0_u64, 2_u64, 8_u64, 10_u64],
          "payload",
          schema,
          w138_root_plan_types(changed_types),
          w138_root_documents(schema),
          rows_per_mark: 2,
          frame_bytes: 16,
        )
      end
      error.message.should eq("Object plan typed type differs from the declared JSON schema")
      File.exists?(target).should be_false
      Dir.children(root).should be_empty
    end

    with_w138_root do |root|
      target = File.join(root, "rejected_value_1_1_0")
      changed_enum = CrystalClick::BinaryDataType.enum8([
        {"renamed", 127_i16},
        {"zero", 0_i16},
        {"negative", -1_i16},
        {"minimum", -128_i16},
      ] of CrystalClick::BinaryEnumDefinition::Entry)
      changed_enum.should_not eq(schema.typed_paths["e8"])
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_object_pair(
          target,
          "pk",
          Slice[0_u64, 2_u64, 8_u64, 10_u64],
          "payload",
          schema,
          w138_root_plan(schema),
          w138_root_documents_with_enum8_type(schema, changed_enum),
          rows_per_mark: 2,
          frame_bytes: 16,
        )
      end
      File.exists?(target).should be_false
      Dir.children(root).should be_empty
    end

    with_w138_root do |root|
      first_schema = w138_root_schema
      first = w138_root_write(File.join(root, "all_1_1_0"), first_schema)
      changed_types = w138_root_types("renamed")
      later_schema = w138_root_schema(changed_types)
      later = w138_root_write(File.join(root, "all_2_2_0"), later_schema, Slice[20_u64, 22_u64, 28_u64, 30_u64])
      CrystalClick::ObjectColumnReader.open(later, "payload", later_schema).row_count.should eq(4_u64)

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([first, later], ["pk", "payload"])
        table.scan_typed_candidate_marks([[0], [] of Int32]) { |_batch| callbacks += 1; nil }
      end
      callbacks.should eq(0)
    end
  end
end
