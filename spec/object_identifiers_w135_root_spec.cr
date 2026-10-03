require "./spec_helper"

private def w135_root_type(name : String) : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.primitive(name)
end

private def w135_root_schema(uuid_type_name : String = "UUID") : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(ip4 IPv4, ip6 IPv6, uuid #{uuid_type_name})")
end

private def w135_root_plan(uuid_type_name : String = "UUID") : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    w135_root_schema(uuid_type_name).typed_paths,
  )
end

private def w135_root_payloads(row : Int32) : Tuple(Bytes, Bytes, Bytes)
  case row
  when 0
    {
      Bytes[0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8],
      Bytes[0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
        0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8],
      Bytes[0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
        0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8],
    }
  when 1
    {
      # RowBinary IPv4 scalar bytes for 1.2.3.4 on the stock little-endian
      # path, plus an IPv6 address and independent UUID high/low halves.
      Bytes[0x04_u8, 0x03_u8, 0x02_u8, 0x01_u8],
      Bytes[0x20_u8, 0x01_u8, 0x0d_u8, 0xb8_u8, 0x12_u8, 0x34_u8, 0x56_u8, 0x78_u8,
        0x90_u8, 0xab_u8, 0xcd_u8, 0xef_u8, 0x11_u8, 0x22_u8, 0x33_u8, 0x44_u8],
      Bytes[0x77_u8, 0x66_u8, 0x55_u8, 0x44_u8, 0x33_u8, 0x22_u8, 0x11_u8, 0x00_u8,
        0xff_u8, 0xee_u8, 0xdd_u8, 0xcc_u8, 0xbb_u8, 0xaa_u8, 0x99_u8, 0x88_u8],
    }
  when 2
    {
      Bytes[0x09_u8, 0x02_u8, 0x00_u8, 0xc0_u8],
      Bytes[0x20_u8, 0x01_u8, 0x0d_u8, 0xb8_u8, 0xff_u8, 0xff_u8, 0xee_u8, 0xee_u8,
        0xdd_u8, 0xdd_u8, 0xcc_u8, 0xcc_u8, 0xbb_u8, 0xbb_u8, 0xaa_u8, 0xaa_u8],
      Bytes[0xef_u8, 0xcd_u8, 0xab_u8, 0x89_u8, 0x67_u8, 0x45_u8, 0x23_u8, 0x01_u8,
        0x10_u8, 0x32_u8, 0x54_u8, 0x76_u8, 0x98_u8, 0xba_u8, 0xdc_u8, 0xfe_u8],
    }
  when 3
    {
      Bytes[0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8],
      Bytes[0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8,
        0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8],
      Bytes[0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8,
        0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8],
    }
  else
    raise ArgumentError.new("unsupported W135 fixture row")
  end
end

private def w135_root_document(row : Int32, uuid_type_name : String = "UUID") : CrystalClick::ObjectDocument
  ipv4_bytes, ipv6_bytes, uuid_bytes = w135_root_payloads(row)
  CrystalClick::ObjectDocument.new({
    "ip4"  => CrystalClick::BinaryValue.fixed(w135_root_type("IPv4"), ipv4_bytes),
    "ip6"  => CrystalClick::BinaryValue.fixed(w135_root_type("IPv6"), ipv6_bytes),
    "uuid" => CrystalClick::BinaryValue.fixed(w135_root_type(uuid_type_name), uuid_bytes),
  } of String => CrystalClick::BinaryValue)
end

private def w135_root_documents(uuid_type_name : String = "UUID") : Array(Array(CrystalClick::ObjectDocument))
  [
    [w135_root_document(0, uuid_type_name), w135_root_document(1, uuid_type_name)],
    [w135_root_document(2, uuid_type_name), w135_root_document(3, uuid_type_name)],
  ] of Array(CrystalClick::ObjectDocument)
end

private def w135_root_assert_document(actual : CrystalClick::ObjectDocument, row : Int32) : Nil
  expected_ipv4, expected_ipv6, expected_uuid = w135_root_payloads(row)
  actual.paths.should eq(["ip4", "ip6", "uuid"])
  actual.value_for("ip4").type.should eq(w135_root_type("IPv4"))
  actual.value_for("ip6").type.should eq(w135_root_type("IPv6"))
  actual.value_for("uuid").type.should eq(w135_root_type("UUID"))
  actual.value_for("ip4").bytes.should eq(expected_ipv4)
  actual.value_for("ip6").bytes.should eq(expected_ipv6)
  actual.value_for("uuid").bytes.should eq(expected_uuid)
end

private def w135_root_assert_marks(
  actual : Array(Array(CrystalClick::ObjectDocument)),
  first_row : Int32,
  expected_mark_count : Int32,
) : Nil
  actual.size.should eq(expected_mark_count)
  row = first_row
  actual.each do |mark|
    mark.size.should eq(2)
    mark.each do |document|
      w135_root_assert_document(document, row)
      row += 1
    end
  end
  nil
end

private def with_w135_root(&)
  root = File.tempname("crystal-click-w135-root-")
  Dir.mkdir(root)
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

private def w135_root_write(
  path : String,
  keys : Slice(UInt64),
  documents : Array(Array(CrystalClick::ObjectDocument)) = w135_root_documents,
  uuid_type_name : String = "UUID",
) : String
  CrystalClick::WidePartWriter.write_uint64_object_pair(
    path,
    "pk",
    keys,
    "payload",
    w135_root_schema(uuid_type_name),
    w135_root_plan(uuid_type_name),
    documents,
    rows_per_mark: 2,
    frame_bytes: 16,
  )
end

private def w135_root_catalog(root : String) : String
  database_uuid = "a1350000-0000-4000-8000-000000000135"
  table_uuid = "b1350000-0000-4000-8000-000000000135"
  FileUtils.mkdir_p(File.join(root, "metadata"))
  database = File.join(root, "store", "a13", database_uuid)
  table = File.join(root, "store", "b13", table_uuid)
  FileUtils.mkdir_p(database)
  FileUtils.mkdir_p(table)
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(
    File.join(database, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n`pk` UInt64,\n`payload` #{w135_root_schema.declaration}\n)\nENGINE = MergeTree\nORDER BY pk\n",
  )
  File.write(File.join(table, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table, "detached"))
  table
end

describe "W135 declared UUID and IP Object consumers" do
  it "preserves exact root.data bytes and supports full, middle, and empty paired windows" do
    documents = w135_root_documents
    streams = CrystalClick::ObjectDocumentCodec.encode(w135_root_plan, documents)
    streams.mark_count.should eq(2)

    ipv4 = streams.typed_for("ip4").stream("root.data")
    ipv4.bytes.should eq(Bytes[
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x04_u8, 0x03_u8, 0x02_u8, 0x01_u8,
      0x09_u8, 0x02_u8, 0x00_u8, 0xc0_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8,
    ])
    ipv4.offsets.should eq([0_u64, 8_u64, 16_u64])

    ipv6 = streams.typed_for("ip6").stream("root.data")
    ipv6.bytes.should eq(Bytes[
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x20_u8, 0x01_u8, 0x0d_u8, 0xb8_u8, 0x12_u8, 0x34_u8, 0x56_u8, 0x78_u8,
      0x90_u8, 0xab_u8, 0xcd_u8, 0xef_u8, 0x11_u8, 0x22_u8, 0x33_u8, 0x44_u8,
      0x20_u8, 0x01_u8, 0x0d_u8, 0xb8_u8, 0xff_u8, 0xff_u8, 0xee_u8, 0xee_u8,
      0xdd_u8, 0xdd_u8, 0xcc_u8, 0xcc_u8, 0xbb_u8, 0xbb_u8, 0xaa_u8, 0xaa_u8,
      0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8,
      0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8,
    ])
    ipv6.offsets.should eq([0_u64, 32_u64, 64_u64])

    uuid = streams.typed_for("uuid").stream("root.data")
    uuid.bytes.should eq(Bytes[
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x77_u8, 0x66_u8, 0x55_u8, 0x44_u8, 0x33_u8, 0x22_u8, 0x11_u8, 0x00_u8,
      0xff_u8, 0xee_u8, 0xdd_u8, 0xcc_u8, 0xbb_u8, 0xaa_u8, 0x99_u8, 0x88_u8,
      0xef_u8, 0xcd_u8, 0xab_u8, 0x89_u8, 0x67_u8, 0x45_u8, 0x23_u8, 0x01_u8,
      0x10_u8, 0x32_u8, 0x54_u8, 0x76_u8, 0x98_u8, 0xba_u8, 0xdc_u8, 0xfe_u8,
      0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8,
      0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8,
    ])
    uuid.offsets.should eq([0_u64, 32_u64, 64_u64])

    full = CrystalClick::ObjectDocumentCodec.decode(w135_root_schema.typed_paths, streams)
    w135_root_assert_marks(full, 0, 2)
    middle = CrystalClick::ObjectDocumentCodec.decode(w135_root_schema.typed_paths, streams, first_mark: 1, mark_count: 1)
    w135_root_assert_marks(middle, 2, 1)
    empty = CrystalClick::ObjectDocumentCodec.decode(w135_root_schema.typed_paths, streams, first_mark: 2, mark_count: 0)
    empty.should be_empty

    with_w135_root do |root|
      part = w135_root_write(File.join(root, "all_1_1_0"), Slice[0_u64, 2_u64, 8_u64, 10_u64])
      file_rows = CrystalClick::ObjectDocumentFileReader.read(part, "payload", w135_root_schema.typed_paths, hashed: true)
      w135_root_assert_marks(file_rows, 0, 2)
      file_middle = CrystalClick::ObjectDocumentFileReader.read(
        part, "payload", w135_root_schema.typed_paths, first_mark: 1, mark_count: 1, hashed: true
      )
      w135_root_assert_marks(file_middle, 2, 1)
      CrystalClick::ObjectDocumentFileReader.read(
        part, "payload", w135_root_schema.typed_paths, first_mark: 2, mark_count: 0, hashed: true
      ).should be_empty
      column = CrystalClick::ObjectColumnReader.open(part, "payload", w135_root_schema)
      column.row_count.should eq(4_u64)
      w135_root_assert_marks(column.read_marks(0, 2), 0, 2)
      w135_root_assert_marks(column.read_marks(1, 1), 2, 1)
      column.read_marks(2, 0).should be_empty
    end
  end

  it "materializes owned typed table documents across full scans, windows, and whole key granules" do
    with_w135_root do |root|
      part = w135_root_write(File.join(root, "all_1_1_0"), Slice[0_u64, 2_u64, 8_u64, 10_u64])
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload", "pk"])
      table.columns.should eq(["payload", "pk"])
      table.column_types.should eq([{"payload", w135_root_schema.declaration}, {"pk", "UInt64"}])

      keys = [] of UInt64
      retained = [] of CrystalClick::ObjectDocument
      table.scan_typed do |batch|
        batch.column_names.should eq(["payload", "pk"])
        batch_keys = batch.values_for("pk")
        batch_documents = batch.object_documents_for("payload")
        batch_keys.size.should eq(batch_documents.size)
        keys.concat(batch_keys)
        batch_documents.each { |document| retained << document }
        nil
      end
      keys.should eq([0_u64, 2_u64, 8_u64, 10_u64])
      retained.size.should eq(4)
      retained.each_with_index { |document, row| w135_root_assert_document(document, row) }

      detached_paths = retained[1].paths
      detached_paths.clear
      detached_uuid = retained[1].value_for("uuid").bytes
      detached_uuid[0] = 0_u8
      w135_root_assert_document(retained[1], 1)

      window_keys = [] of UInt64
      window_documents = [] of CrystalClick::ObjectDocument
      table.scan_typed_window(1_u64, max_rows: 2) do |batch|
        window_keys.concat(batch.values_for("pk"))
        batch.object_documents_for("payload").each { |document| window_documents << document }
        nil
      end
      window_keys.should eq([2_u64, 8_u64])
      window_documents.size.should eq(2)
      w135_root_assert_document(window_documents[0], 1)
      w135_root_assert_document(window_documents[1], 2)

      callbacks = 0
      table.scan_typed_window(4_u64, max_rows: 1) { |_batch| callbacks += 1; nil }
      callbacks.should eq(0)
      expect_raises(CrystalClick::BoundsError) do
        table.scan_typed_window(4_u64, max_rows: 0) { |_batch| callbacks += 1; nil }
      end
      callbacks.should eq(0)

      candidate_keys = [] of UInt64
      residual_keys = [] of UInt64
      table.scan_typed_candidate_marks([[0, 1]]) do |batch|
        batch_keys = batch.values_for("pk")
        batch_documents = batch.object_documents_for("payload")
        batch_keys.size.should eq(batch_documents.size)
        candidate_keys.concat(batch_keys)
        batch_keys.each { |key| residual_keys << key if key >= 2_u64 && key <= 8_u64 }
        nil
      end
      candidate_keys.should eq([0_u64, 2_u64, 8_u64, 10_u64])
      residual_keys.should eq([2_u64, 8_u64])
    end
  end

  it "rereads owned catalog snapshots and serves bounded windows and PK candidates" do
    with_w135_root do |root|
      table_path = w135_root_catalog(root)
      w135_root_write(File.join(table_path, "all_1_1_0"), Slice[0_u64, 2_u64, 8_u64, 10_u64])
      catalog_table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      selected = catalog_table["payload"]
      values = selected.values(max_rows: 4_u64)
      documents = values.map(&.as(CrystalClick::ObjectDocument))
      documents.size.should eq(4)
      documents.each_with_index { |document, row| w135_root_assert_document(document, row) }

      documents[1].paths.clear
      detached = documents[1].value_for("uuid").bytes
      detached[0] = 0_u8
      w135_root_assert_document(documents[1], 1)
      reread = selected.values(max_rows: 4_u64).map(&.as(CrystalClick::ObjectDocument))
      reread.each_with_index { |document, row| w135_root_assert_document(document, row) }
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
      w135_root_assert_document(window_documents[0], 1)
      w135_root_assert_document(window_documents[1], 2)

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

  it "refuses equal-width wrong nominal writers before publishing a part" do
    with_w135_root do |root|
      target = File.join(root, "all_1_1_0")
      expect_raises(CrystalClick::UnsupportedFormatError) do
        w135_root_write(target, Slice[0_u64, 2_u64, 8_u64, 10_u64], w135_root_documents("UInt128"))
      end
      File.exists?(target).should be_false
      Dir.children(root).should be_empty
    end
  end

  it "rejects valid later-part UUID versus IPv6 nominal drift before callbacks" do
    with_w135_root do |root|
      first = w135_root_write(File.join(root, "all_1_1_0"), Slice[0_u64, 2_u64, 8_u64, 10_u64])
      later = w135_root_write(
        File.join(root, "all_2_2_0"),
        Slice[20_u64, 22_u64, 28_u64, 30_u64],
        w135_root_documents("IPv6"),
        "IPv6",
      )
      File.read(File.join(later, "columns.txt")).should contain("uuid IPv6")

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([first, later], ["pk", "payload"])
        table.scan_typed_candidate_marks([[0], [] of Int32]) { |_batch| callbacks += 1; nil }
      end
      callbacks.should eq(0)
    end
  end
end
