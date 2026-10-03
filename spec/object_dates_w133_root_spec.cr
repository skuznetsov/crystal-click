require "./spec_helper"

private def w133_root_date_schema : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.new(
    {
      "d"   => CrystalClick::BinaryDataType.primitive("Date"),
      "d32" => CrystalClick::BinaryDataType.primitive("Date32"),
    },
    max_dynamic_paths: 0,
    max_dynamic_types: 0,
  )
end

private def w133_root_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    schema.typed_paths,
  )
end

private def w133_root_date_bytes(day : UInt16) : Bytes
  Bytes.new(2) { |index| ((day.to_u32 >> (index * 8)) & 0xff_u32).to_u8 }
end

private def w133_root_date32_bytes(day : Int32) : Bytes
  bits = day.unsafe_as(UInt32)
  Bytes.new(4) { |index| ((bits >> (index * 8)) & 0xff_u32).to_u8 }
end

private def w133_root_join_bytes(parts : Array(Bytes)) : Bytes
  size = 0
  parts.each { |part| size += part.size }
  joined = Bytes.new(size)
  offset = 0
  parts.each do |part|
    part.each do |byte|
      joined[offset] = byte
      offset += 1
    end
  end
  joined
end

private def w133_root_date_day(row : Int32) : UInt16
  case row
  when 0 then 0x0201_u16
  when 1 then 0x3412_u16
  when 2 then 0x7856_u16
  else        0xbc9a_u16
  end
end

private def w133_root_date32_day(row : Int32) : Int32
  case row
  when 0 then -513
  when 1 then 513
    # Raw carrier extrema only; this does not claim calendar-domain validity.
  when 2 then Int32::MIN
  else        Int32::MAX
  end
end

private def w133_root_documents(schema : CrystalClick::ObjectDocumentSchema) : Array(CrystalClick::ObjectDocument)
  date = schema.typed_paths["d"]
  date32 = schema.typed_paths["d32"]
  Array(CrystalClick::ObjectDocument).new(4) do |row|
    CrystalClick::ObjectDocument.new({
      "d"   => CrystalClick::BinaryValue.fixed(date, w133_root_date_bytes(w133_root_date_day(row))),
      "d32" => CrystalClick::BinaryValue.fixed(date32, w133_root_date32_bytes(w133_root_date32_day(row))),
    })
  end
end

private def w133_root_granules(schema : CrystalClick::ObjectDocumentSchema) : Array(Array(CrystalClick::ObjectDocument))
  documents = w133_root_documents(schema)
  [documents[0, 2], documents[2, 2]]
end

private def w133_root_write(
  destination : String,
  schema : CrystalClick::ObjectDocumentSchema,
  granules : Array(Array(CrystalClick::ObjectDocument)) = w133_root_granules(schema),
  keys : Slice(UInt64) = Slice[10_u64, 20_u64, 30_u64, 40_u64],
) : String
  CrystalClick::WidePartWriter.write_uint64_object_pair(
    destination,
    "pk",
    keys,
    "payload",
    schema,
    w133_root_plan(schema),
    granules,
    rows_per_mark: 2,
    frame_bytes: 1024,
  )
end

private def w133_root_catalog(root : String, declaration : String) : String
  database_uuid = "a1330000-0000-4000-8000-000000000133"
  table_uuid = "b1330000-0000-4000-8000-000000000133"
  FileUtils.mkdir_p(File.join(root, "metadata"))
  database = File.join(root, "store", "a13", database_uuid)
  table = File.join(root, "store", "b13", table_uuid)
  FileUtils.mkdir_p(database)
  FileUtils.mkdir_p(table)
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(
    File.join(database, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n#{96.chr}pk#{96.chr} UInt64,\n#{96.chr}payload#{96.chr} #{declaration}\n)\nENGINE = MergeTree\nORDER BY pk\n",
  )
  File.write(File.join(table, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table, "detached"))
  table
end

private def with_w133_root(&)
  root = File.tempname("crystal-click-w133-root-")
  Dir.mkdir(root)
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

private def w133_root_assert_document(document : CrystalClick::ObjectDocument, row : Int32) : Nil
  document.value_for("d").type.should eq(CrystalClick::BinaryDataType.primitive("Date"))
  document.value_for("d").bytes.should eq(w133_root_date_bytes(w133_root_date_day(row)))
  document.value_for("d32").type.should eq(CrystalClick::BinaryDataType.primitive("Date32"))
  document.value_for("d32").bytes.should eq(w133_root_date32_bytes(w133_root_date32_day(row)))
  nil
end

describe "W133 declared Date and Date32 Object consumers" do
  it "preserves asymmetric raw day words through whole-part and file/column reads" do
    with_w133_root do |root|
      schema = w133_root_date_schema
      plan = w133_root_plan(schema)
      granules = w133_root_granules(schema)
      encoded = CrystalClick::ObjectDocumentCodec.encode(plan, granules)
      encoded.typed_for("d").stream("root.data").bytes.should eq(w133_root_join_bytes([
        w133_root_date_bytes(0x0201_u16), w133_root_date_bytes(0x3412_u16),
        w133_root_date_bytes(0x7856_u16), w133_root_date_bytes(0xbc9a_u16),
      ]))
      encoded.typed_for("d32").stream("root.data").bytes.should eq(w133_root_join_bytes([
        w133_root_date32_bytes(-513), w133_root_date32_bytes(513),
        w133_root_date32_bytes(Int32::MIN), w133_root_date32_bytes(Int32::MAX),
      ]))

      part = w133_root_write(File.join(root, "all_1_1_0"), schema, granules)
      reader = CrystalClick::ObjectColumnReader.open(part, "payload", schema)
      reader.mark_row_counts.should eq([2_u64, 2_u64])
      full = reader.read_marks(0, 2).flatten
      full.size.should eq(4)
      full.each_with_index { |document, row| w133_root_assert_document(document, row) }

      middle = CrystalClick::ObjectDocumentFileReader.read(
        part, "payload", schema.typed_paths, first_mark: 1, mark_count: 1, hashed: true
      )
      middle.flatten.each_with_index { |document, index| w133_root_assert_document(document, index + 2) }
      reader.read_marks(2, 0).should be_empty
    end
  end

  it "keeps nominal wrong-type values from publishing any part" do
    with_w133_root do |root|
      schema = w133_root_date_schema
      [
        {"d", CrystalClick::BinaryDataType.primitive("UInt16")},
        {"d32", CrystalClick::BinaryDataType.primitive("Int32")},
      ].each do |wrong_path, wrong_type|
        granules = w133_root_granules(schema)
        first = granules[0][0]
        values = {} of String => CrystalClick::BinaryValue
        first.paths.each do |path|
          original = first.value_for(path)
          values[path] = if path == wrong_path
                           CrystalClick::BinaryValue.fixed(wrong_type, original.bytes)
                         else
                           original
                         end
        end
        granules[0][0] = CrystalClick::ObjectDocument.new(values)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          w133_root_write(File.join(root, "rejected_#{wrong_path}_1_1_0"), schema, granules)
        end
        Dir.children(root).should be_empty
      end
    end
  end

  it "preserves owned documents across catalog and table full, middle, zero, and reread paths" do
    with_w133_root do |root|
      schema = w133_root_date_schema
      directory = w133_root_catalog(root, schema.declaration)
      part = w133_root_write(File.join(directory, "all_1_1_0"), schema)
      table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]

      column_documents = table["payload"].values.map(&.as(CrystalClick::ObjectDocument))
      column_documents.each_with_index { |document, row| w133_root_assert_document(document, row) }

      full_rows = [] of UInt64
      full_row_index = 0
      table.scan_typed_window(["payload", "pk"], 0_u64, 4) do |batch|
        batch.column_names.should eq(["payload", "pk"])
        batch.column_type_for("payload").should eq(schema.declaration)
        keys = batch.values_for("pk")
        documents = batch.object_documents_for("payload")
        keys.size.should eq(documents.size)
        keys.each_with_index do |key, index|
          full_rows << key
          w133_root_assert_document(documents[index], full_row_index)
          full_row_index += 1
        end
        nil
      end
      full_rows.should eq([10_u64, 20_u64, 30_u64, 40_u64])

      retained = [] of CrystalClick::ObjectDocument
      middle_rows = [] of UInt64
      middle_row_index = 1
      table.scan_typed_window(["payload", "pk"], 1_u64, 2) do |batch|
        keys = batch.values_for("pk")
        documents = batch.object_documents_for("payload")
        keys.each_with_index do |key, index|
          middle_rows << key
          retained << documents[index]
          w133_root_assert_document(documents[index], middle_row_index)
          middle_row_index += 1
        end
        nil
      end
      middle_rows.should eq([20_u64, 30_u64])
      retained.size.should eq(2)
      detached = retained[0].value_for("d32").bytes
      detached[0] ^= 0xff_u8
      retained[0].value_for("d32").bytes.should eq(w133_root_date32_bytes(513))
      reread = table["payload"].values[1].as(CrystalClick::ObjectDocument)
      w133_root_assert_document(reread, 1)

      zero_callbacks = 0
      table.scan_typed_window(["payload", "pk"], 4_u64, 1) do |_batch|
        zero_callbacks += 1
        nil
      end
      zero_callbacks.should eq(0)
      expect_raises(CrystalClick::BoundsError) do
        table.scan_typed_window(["payload", "pk"], 4_u64, 0) do |_batch|
          zero_callbacks += 1
          nil
        end
      end
      zero_callbacks.should eq(0)

      physical_table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload", "pk"])
      physical_callbacks = 0
      physical_table.scan_typed_window(4_u64, 1) { |_batch| physical_callbacks += 1; nil }
      physical_callbacks.should eq(0)
      expect_raises(CrystalClick::BoundsError) do
        physical_table.scan_typed_window(4_u64, 0) { |_batch| physical_callbacks += 1; nil }
      end
      physical_callbacks.should eq(0)
    end
  end

  it "returns whole PK granules for exact residual filtering and checks later-part type drift before callbacks" do
    with_w133_root do |root|
      schema = w133_root_date_schema
      directory = w133_root_catalog(root, schema.declaration)
      first = w133_root_write(File.join(directory, "all_1_1_0"), schema)
      later = w133_root_write(
        File.join(directory, "all_2_2_0"), schema,
        keys: Slice[50_u64, 60_u64, 70_u64, 80_u64],
      )
      columns = File.join(later, "columns.txt")
      File.write(columns, File.read(columns).sub("d Date", "d UInt16"))

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        drifted = CrystalClick::WidePartTable.open_selected_typed([first, later], ["payload", "pk"])
        drifted.scan_typed { |_batch| callbacks += 1; nil }
      end
      callbacks.should eq(0)

      File.write(columns, File.read(columns).sub("d UInt16", "d Date"))
      table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      candidates = [] of UInt64
      residual = [] of Tuple(UInt64, Bytes)
      table.scan_uint64_pk_candidates(["pk", "payload"], lower_bound: 20_u64, upper_bound: 30_u64) do |batch|
        keys = batch.values_for("pk")
        documents = batch.object_documents_for("payload")
        keys.size.should eq(documents.size)
        candidates.concat(keys)
        keys.each_with_index do |key, index|
          next unless 20_u64 <= key <= 30_u64
          residual << {key, documents[index].value_for("d32").bytes}
        end
        nil
      end
      candidates.should eq([10_u64, 20_u64, 30_u64, 40_u64])
      residual.should eq([
        {20_u64, w133_root_date32_bytes(513)},
        {30_u64, w133_root_date32_bytes(Int32::MIN)},
      ])
    end
  end
end
