require "./spec_helper"

private def w136_root_widths(n3 : Int32 = 3) : Hash(String, Int32)
  {"n1" => 1, "n3" => n3, "n16" => 16, "n17" => 17, "n31" => 31}
end

private def w136_root_schema(widths : Hash(String, Int32) = w136_root_widths) : CrystalClick::ObjectDocumentSchema
  types = Hash(String, CrystalClick::BinaryDataType).new(initial_capacity: widths.size)
  widths.each do |path, width|
    types[path] = CrystalClick::BinaryDataType.fixed_string(width)
  end
  CrystalClick::ObjectDocumentSchema.new(types)
end

private def w136_root_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    schema.typed_paths,
  )
end

private def w136_root_payload(width : Int32, row : Int32) : Bytes
  Bytes.new(width) do |index|
    case row
    when 0
      # An empty textual value is represented explicitly as N zero bytes.
      0_u8
    when 1
      # The UTF-8 bytes for "é" are explicit; the remaining fixed-width bytes
      # are explicit NUL padding owned by the caller.
      if index == 0
        0xc3_u8
      elsif index == 1
        0xa9_u8
      else
        0_u8
      end
    when 2
      # This includes an embedded NUL between visible ASCII bytes when N >= 3.
      case index
      when 0 then 0x41_u8
      when 1 then 0_u8
      when 2 then 0x42_u8
      else        ((index * 19 + width) & 0xff).to_u8
      end
    when 3
      0xff_u8
    else
      raise ArgumentError.new("unknown W136 fixture row")
    end
  end
end

private def w136_root_document(widths : Hash(String, Int32), row : Int32) : CrystalClick::ObjectDocument
  fields = Hash(String, CrystalClick::BinaryValue).new(initial_capacity: widths.size)
  widths.each do |path, width|
    type = CrystalClick::BinaryDataType.fixed_string(width)
    fields[path] = CrystalClick::BinaryValue.fixed(type, w136_root_payload(width, row))
  end
  CrystalClick::ObjectDocument.new(fields)
end

private def w136_root_documents(
  widths : Hash(String, Int32) = w136_root_widths,
) : Array(Array(CrystalClick::ObjectDocument))
  [
    [w136_root_document(widths, 0), w136_root_document(widths, 1)],
    [w136_root_document(widths, 2), w136_root_document(widths, 3)],
  ] of Array(CrystalClick::ObjectDocument)
end

private def w136_root_assert_document(
  actual : CrystalClick::ObjectDocument,
  widths : Hash(String, Int32),
  row : Int32,
) : Nil
  actual.paths.should eq(widths.keys.sort)
  widths.each do |path, width|
    actual.value_for(path).type.should eq(CrystalClick::BinaryDataType.fixed_string(width))
    actual.value_for(path).bytes.should eq(w136_root_payload(width, row))
  end
  nil
end

private def w136_root_assert_marks(
  actual : Array(Array(CrystalClick::ObjectDocument)),
  widths : Hash(String, Int32),
  first_row : Int32,
  expected_mark_count : Int32,
) : Nil
  actual.size.should eq(expected_mark_count)
  row = first_row
  actual.each do |mark|
    mark.size.should eq(2)
    mark.each do |document|
      w136_root_assert_document(document, widths, row)
      row += 1
    end
  end
  nil
end

private def with_w136_root(&)
  root = File.tempname("crystal-click-w136-root-")
  Dir.mkdir(root)
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

private def w136_root_write(
  path : String,
  keys : Slice(UInt64),
  widths : Hash(String, Int32) = w136_root_widths,
  documents : Array(Array(CrystalClick::ObjectDocument)) = w136_root_documents(widths),
) : String
  schema = w136_root_schema(widths)
  CrystalClick::WidePartWriter.write_uint64_object_pair(
    path,
    "pk",
    keys,
    "payload",
    schema,
    w136_root_plan(schema),
    documents,
    rows_per_mark: 2,
    frame_bytes: 64,
  )
end

private def w136_root_catalog(root : String) : String
  database_uuid = "a1360000-0000-4000-8000-000000000136"
  table_uuid = "b1360000-0000-4000-8000-000000000136"
  schema = w136_root_schema
  FileUtils.mkdir_p(File.join(root, "metadata"))
  database = File.join(root, "store", "a13", database_uuid)
  table = File.join(root, "store", "b13", table_uuid)
  FileUtils.mkdir_p(database)
  FileUtils.mkdir_p(table)
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(
    File.join(database, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n`pk` UInt64,\n`payload` #{schema.declaration}\n)\nENGINE = MergeTree\nORDER BY pk\n",
  )
  File.write(File.join(table, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table, "detached"))
  table
end

describe "W136 declared FixedString(N) Object consumers" do
  it "preserves exact paired root.data bytes and supports full, middle, and zero file/column windows" do
    widths = w136_root_widths
    schema = w136_root_schema(widths)
    plan = w136_root_plan(schema)
    streams = CrystalClick::ObjectDocumentCodec.encode(plan, w136_root_documents(widths))
    streams.mark_count.should eq(2)

    widths.each do |path, width|
      stream = streams.typed_for(path).stream("root.data")
      expected = Bytes.new(width * 4) do |index|
        row = index // width
        byte_index = index % width
        w136_root_payload(width, row)[byte_index]
      end
      stream.bytes.should eq(expected)
      stream.offsets.should eq([0_u64, (width * 2).to_u64, (width * 4).to_u64])
    end

    full = CrystalClick::ObjectDocumentCodec.decode(schema.typed_paths, streams)
    w136_root_assert_marks(full, widths, 0, 2)
    middle = CrystalClick::ObjectDocumentCodec.decode(schema.typed_paths, streams, first_mark: 1, mark_count: 1)
    w136_root_assert_marks(middle, widths, 2, 1)
    CrystalClick::ObjectDocumentCodec.decode(schema.typed_paths, streams, first_mark: 2, mark_count: 0).should be_empty

    with_w136_root do |root|
      part = w136_root_write(File.join(root, "all_1_1_0"), Slice[0_u64, 2_u64, 8_u64, 10_u64], widths)
      file_rows = CrystalClick::ObjectDocumentFileReader.read(part, "payload", schema.typed_paths, hashed: true)
      w136_root_assert_marks(file_rows, widths, 0, 2)
      file_middle = CrystalClick::ObjectDocumentFileReader.read(
        part, "payload", schema.typed_paths, first_mark: 1, mark_count: 1, hashed: true
      )
      w136_root_assert_marks(file_middle, widths, 2, 1)
      CrystalClick::ObjectDocumentFileReader.read(
        part, "payload", schema.typed_paths, first_mark: 2, mark_count: 0, hashed: true
      ).should be_empty

      column = CrystalClick::ObjectColumnReader.open(part, "payload", schema)
      column.row_count.should eq(4_u64)
      w136_root_assert_marks(column.read_marks(0, 2), widths, 0, 2)
      w136_root_assert_marks(column.read_marks(1, 1), widths, 2, 1)
      column.read_marks(2, 0).should be_empty
    end
  end

  it "materializes owned catalog values and serves table windows and UInt64 key candidates" do
    widths = w136_root_widths
    with_w136_root do |root|
      table_path = w136_root_catalog(root)
      w136_root_write(File.join(table_path, "all_1_1_0"), Slice[0_u64, 2_u64, 8_u64, 10_u64], widths)
      catalog_table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      selected = catalog_table["payload"]
      documents = selected.values(max_rows: 4_u64).map(&.as(CrystalClick::ObjectDocument))
      documents.size.should eq(4)
      documents.each_with_index { |document, row| w136_root_assert_document(document, widths, row) }

      documents[1].paths.clear
      detached = documents[1].value_for("n3").bytes
      detached[0] ^= 0xff_u8
      w136_root_assert_document(documents[1], widths, 1)
      reread = selected.values(max_rows: 4_u64).map(&.as(CrystalClick::ObjectDocument))
      reread.each_with_index { |document, row| w136_root_assert_document(document, widths, row) }
      expect_raises(CrystalClick::BoundsError) { selected.values(max_rows: 0_u64) }

      window_keys = [] of UInt64
      window_documents = [] of CrystalClick::ObjectDocument
      catalog_table.scan_typed_window(["payload", "pk"], 1_u64, 2) do |batch|
        window_keys.concat(batch.values_for("pk"))
        batch.object_documents_for("payload").each { |document| window_documents << document }
        nil
      end
      window_keys.should eq([2_u64, 8_u64])
      window_documents.size.should eq(2)
      w136_root_assert_document(window_documents[0], widths, 1)
      w136_root_assert_document(window_documents[1], widths, 2)

      callbacks = 0
      catalog_table.scan_typed_window(["payload", "pk"], 4_u64, 1) { |_batch| callbacks += 1; nil }
      callbacks.should eq(0)
      expect_raises(CrystalClick::BoundsError) do
        catalog_table.scan_typed_window(["payload", "pk"], 4_u64, 0) { |_batch| callbacks += 1; nil }
      end
      callbacks.should eq(0)

      candidate_keys = [] of UInt64
      residual_keys = [] of UInt64
      catalog_table.scan_uint64_pk_candidates(["pk", "payload"], lower_bound: 2_u64, upper_bound: 8_u64) do |batch|
        batch_keys = batch.values_for("pk")
        batch.object_documents_for("payload").size.should eq(batch_keys.size)
        candidate_keys.concat(batch_keys)
        batch_keys.each { |key| residual_keys << key if key >= 2_u64 && key <= 8_u64 }
        nil
      end
      candidate_keys.should eq([0_u64, 2_u64, 8_u64, 10_u64])
      residual_keys.should eq([2_u64, 8_u64])
    end
  end

  it "refuses width/type disagreement before publication and catches later-part width drift before callbacks" do
    widths = w136_root_widths
    with_w136_root do |root|
      target = File.join(root, "bad_1_1_0")
      bad_widths = widths.dup
      bad_widths["n3"] = 4
      bad_documents = w136_root_documents(widths)
      bad_documents[0][0] = w136_root_document(bad_widths, 0)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        w136_root_write(target, Slice[0_u64, 2_u64, 8_u64, 10_u64], widths, bad_documents)
      end
      File.exists?(target).should be_false
      Dir.children(root).should be_empty
    end

    with_w136_root do |root|
      first = w136_root_write(File.join(root, "all_1_1_0"), Slice[0_u64, 2_u64, 8_u64, 10_u64], widths)
      later_widths = w136_root_widths(4)
      later = w136_root_write(
        File.join(root, "all_2_2_0"), Slice[20_u64, 22_u64, 28_u64, 30_u64], later_widths
      )
      File.read(File.join(later, "columns.txt")).should contain("n3 FixedString(4)")
      CrystalClick::ObjectColumnReader.open(later, "payload", w136_root_schema(later_widths)).row_count.should eq(4_u64)

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([first, later], ["pk", "payload"])
        table.scan_typed_candidate_marks([[0], [] of Int32]) { |_batch| callbacks += 1; nil }
      end
      callbacks.should eq(0)
    end
  end

  it "rejects malformed FixedString declarations in selected part metadata" do
    widths = w136_root_widths
    schema = w136_root_schema(widths)
    with_w136_root do |root|
      part = w136_root_write(File.join(root, "all_1_1_0"), Slice[0_u64, 2_u64, 8_u64, 10_u64], widths)
      columns_path = File.join(part, "columns.txt")
      malformed = schema.declaration.sub("FixedString(3)", "FixedString(03)")
      File.write(columns_path, File.read(columns_path).gsub(schema.declaration, malformed))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
      end
    end
  end
end
