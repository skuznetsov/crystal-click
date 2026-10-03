require "./spec_helper"

private def w139_root_types : Hash(String, CrystalClick::BinaryDataType)
  {
    "datetime_bare"   => CrystalClick::BinaryDataType.datetime,
    "datetime_utc"    => CrystalClick::BinaryDataType.datetime("UTC"),
    "datetime_alias"  => CrystalClick::BinaryDataType.datetime("Etc/UTC"),
    "datetime_fixed"  => CrystalClick::BinaryDataType.datetime("Fixed/UTC+05:30:00"),
    "datetime64_bare" => CrystalClick::BinaryDataType.datetime64(0),
    "datetime64_zone" => CrystalClick::BinaryDataType.datetime64(9, "America/New_York"),
    "time"            => CrystalClick::BinaryDataType.primitive("Time"),
    "time64"          => CrystalClick::BinaryDataType.time64(9),
  } of String => CrystalClick::BinaryDataType
end

private def w139_root_schema(
  types : Hash(String, CrystalClick::BinaryDataType) = w139_root_types,
) : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.new(types, max_dynamic_paths: 0, max_dynamic_types: 0)
end

private def w139_root_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
  w139_root_plan_types(schema.typed_paths)
end

private def w139_root_plan_types(types : Hash(String, CrystalClick::BinaryDataType)) : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    types,
  )
end

private def with_w139_root(&)
  root = File.tempname("crystal-click-w139-root-")
  Dir.mkdir(root)
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

private def w139_root_catalog(root : String, declaration : String) : String
  database_uuid = "a1390000-0000-4000-8000-000000000139"
  table_uuid = "b1390000-0000-4000-8000-000000000139"
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

private def w139_root_u32_bytes(value : UInt32) : Bytes
  Bytes.new(4) { |index| ((value >> (index * 8)) & 0xff_u32).to_u8 }
end

private def w139_root_u64_bytes(value : UInt64) : Bytes
  Bytes.new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w139_root_datetime_bits(row : Int32) : UInt32
  case row
  when 0 then 0_u32
  when 1 then 0x0102_0304_u32
  when 2 then 0x8000_0000_u32
  else        0xffff_ffff_u32
  end
end

private def w139_root_datetime64_bits(row : Int32) : UInt64
  case row
  when 0 then 0_u64
  when 1 then 0x0102_0304_0506_0708_u64
  when 2 then 0x8000_0000_0000_0000_u64
  else        0xffff_ffff_ffff_ffff_u64
  end
end

private def w139_root_time_bits(row : Int32) : UInt32
  case row
  when 0 then 0_u32
  when 1 then 1_u32
  when 2 then 0x7fff_ffff_u32
  else        0x8000_0000_u32
  end
end

private def w139_root_time64_bits(row : Int32) : UInt64
  case row
  when 0 then 0_u64
  when 1 then 1_u64
  when 2 then 0x7fff_ffff_ffff_ffff_u64
  else        0x8000_0000_0000_0000_u64
  end
end

private def w139_root_bytes(path : String, row : Int32) : Bytes
  case path
  when "datetime_bare", "datetime_utc", "datetime_alias", "datetime_fixed"
    w139_root_u32_bytes(w139_root_datetime_bits(row))
  when "datetime64_bare", "datetime64_zone"
    w139_root_u64_bytes(w139_root_datetime64_bits(row))
  when "time"
    w139_root_u32_bytes(w139_root_time_bits(row))
  when "time64"
    w139_root_u64_bytes(w139_root_time64_bits(row))
  else
    raise ArgumentError.new("unsupported W139 temporal path")
  end
end

private def w139_root_document(
  schema : CrystalClick::ObjectDocumentSchema,
  row : Int32,
  wrong_time_type : Bool = false,
) : CrystalClick::ObjectDocument
  types = schema.typed_paths
  values = {} of String => CrystalClick::BinaryValue
  types.each do |path, type|
    value_type = path == "time" && wrong_time_type ? CrystalClick::BinaryDataType.primitive("Int32") : type
    values[path] = CrystalClick::BinaryValue.fixed(value_type, w139_root_bytes(path, row))
  end
  CrystalClick::ObjectDocument.new(values)
end

private def w139_root_granules(
  schema : CrystalClick::ObjectDocumentSchema,
  wrong_time_type : Bool = false,
) : Array(Array(CrystalClick::ObjectDocument))
  rows = Array(CrystalClick::ObjectDocument).new(4) do |row|
    w139_root_document(schema, row, wrong_time_type)
  end
  [rows[0, 2], rows[2, 2]] of Array(CrystalClick::ObjectDocument)
end

private def w139_root_write(
  path : String,
  schema : CrystalClick::ObjectDocumentSchema,
  keys : Slice(UInt64) = Slice[0_u64, 2_u64, 8_u64, 10_u64],
  wrong_time_type : Bool = false,
) : String
  CrystalClick::WidePartWriter.write_uint64_object_pair(
    path,
    "pk",
    keys,
    "payload",
    schema,
    w139_root_plan(schema),
    w139_root_granules(schema, wrong_time_type),
    rows_per_mark: 2,
    frame_bytes: 16,
  )
end

private def w139_root_assert_document(
  document : CrystalClick::ObjectDocument,
  schema : CrystalClick::ObjectDocumentSchema,
  row : Int32,
) : Nil
  types = schema.typed_paths
  document.paths.should eq(types.keys.sort)
  types.each do |path, type|
    actual = document.value_for(path)
    actual.type.should eq(type)
    actual.bytes.should eq(w139_root_bytes(path, row))
  end
  nil
end

private def w139_root_assert_marks(
  marks : Array(Array(CrystalClick::ObjectDocument)),
  schema : CrystalClick::ObjectDocumentSchema,
  first_row : Int32,
  mark_count : Int32,
) : Nil
  marks.size.should eq(mark_count)
  row = first_row
  marks.each do |mark|
    mark.size.should eq(2)
    mark.each do |document|
      w139_root_assert_document(document, schema, row)
      row += 1
    end
  end
  nil
end

describe "W139 declared temporal Object consumers" do
  it "preserves exact temporal raw carriers through whole-part, file, and column reads" do
    schema = w139_root_schema
    with_w139_root do |root|
      part = w139_root_write(File.join(root, "all_1_1_0"), schema)

      w139_root_assert_marks(
        CrystalClick::ObjectDocumentFileReader.read(part, "payload", schema.typed_paths, hashed: true),
        schema,
        0,
        2,
      )
      w139_root_assert_marks(
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
      w139_root_assert_marks(column.read_marks(0, 2), schema, 0, 2)
      w139_root_assert_marks(column.read_marks(1, 1), schema, 2, 1)
      column.read_marks(2, 0).should be_empty
    end
  end

  it "preserves temporal Object documents through catalog, table windows, and PK candidates" do
    schema = w139_root_schema
    with_w139_root do |root|
      table_path = w139_root_catalog(root, schema.declaration)
      w139_root_write(File.join(table_path, "all_1_1_0"), schema)
      catalog_table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]

      documents = catalog_table["payload"].values(max_rows: 4_u64).map(&.as(CrystalClick::ObjectDocument))
      documents.size.should eq(4)
      documents.each_with_index { |document, row| w139_root_assert_document(document, schema, row) }

      table = CrystalClick::WidePartTable.open_selected_typed(
        [File.join(table_path, "all_1_1_0")],
        ["payload", "pk"],
      )
      table.column_types.should eq([{"payload", schema.declaration}, {"pk", "UInt64"}])
      keys = [] of UInt64
      table_documents = [] of CrystalClick::ObjectDocument
      table.scan_typed do |batch|
        keys.concat(batch.values_for("pk"))
        batch.object_documents_for("payload").each { |document| table_documents << document }
        nil
      end
      keys.should eq([0_u64, 2_u64, 8_u64, 10_u64])
      table_documents.each_with_index { |document, row| w139_root_assert_document(document, schema, row) }

      window_keys = [] of UInt64
      window_documents = [] of CrystalClick::ObjectDocument
      catalog_table.scan_typed_window(["payload", "pk"], 1_u64, 2) do |batch|
        window_keys.concat(batch.values_for("pk"))
        batch.object_documents_for("payload").each { |document| window_documents << document }
        nil
      end
      window_keys.should eq([2_u64, 8_u64])
      window_documents.each_with_index { |document, index| w139_root_assert_document(document, schema, index + 1) }

      candidates = [] of Tuple(UInt64, Bytes)
      candidate_keys = [] of UInt64
      catalog_table.scan_uint64_pk_candidates(["pk", "payload"], lower_bound: 2_u64, upper_bound: 8_u64) do |batch|
        batch_keys = batch.values_for("pk")
        batch_documents = batch.object_documents_for("payload")
        batch_keys.size.should eq(batch_documents.size)
        candidate_keys.concat(batch_keys)
        batch_keys.each_with_index do |key, index|
          candidates << {key, batch_documents[index].value_for("datetime64_zone").bytes} if 2_u64 <= key <= 8_u64
        end
        nil
      end
      candidate_keys.should eq([0_u64, 2_u64, 8_u64, 10_u64])
      candidates.should eq([
        {2_u64, w139_root_bytes("datetime64_zone", 1)},
        {8_u64, w139_root_bytes("datetime64_zone", 2)},
      ])
    end
  end

  it "refuses zone or raw-carrier type drift before publication and later-part callbacks" do
    schema = w139_root_schema
    with_w139_root do |root|
      target = File.join(root, "rejected_plan_1_1_0")
      changed_types = schema.typed_paths
      changed_types["datetime_utc"] = CrystalClick::BinaryDataType.datetime("Etc/UTC")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_object_pair(
          target,
          "pk",
          Slice[0_u64, 2_u64, 8_u64, 10_u64],
          "payload",
          schema,
          w139_root_plan_types(changed_types),
          w139_root_granules(schema),
          rows_per_mark: 2,
          frame_bytes: 16,
        )
      end
      File.exists?(target).should be_false
      Dir.children(root).should be_empty
    end

    with_w139_root do |root|
      target = File.join(root, "rejected_value_1_1_0")
      expect_raises(CrystalClick::UnsupportedFormatError) do
        w139_root_write(target, schema, wrong_time_type: true)
      end
      File.exists?(target).should be_false
      Dir.children(root).should be_empty
    end

    with_w139_root do |root|
      first = w139_root_write(File.join(root, "all_1_1_0"), schema)
      changed_types = schema.typed_paths
      changed_types["datetime_utc"] = CrystalClick::BinaryDataType.datetime("Etc/UTC")
      later_schema = w139_root_schema(changed_types)
      later = w139_root_write(
        File.join(root, "all_2_2_0"),
        later_schema,
        Slice[20_u64, 22_u64, 28_u64, 30_u64],
      )
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
