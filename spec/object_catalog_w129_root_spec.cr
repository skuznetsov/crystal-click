require "./spec_helper"

private def w129_root_schema : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(t UInt64, max_dynamic_paths=1, max_dynamic_types=1)")
end

private def w129_root_docs : Array(Array(CrystalClick::ObjectDocument))
  [
    [CrystalClick::ObjectDocument.new({"t" => CrystalClick::BinaryValue.uint64(4_u64), "d" => CrystalClick::BinaryValue.string("a\0b")}),
     CrystalClick::ObjectDocument.new({"t" => CrystalClick::BinaryValue.uint64(5_u64), "shared.x" => CrystalClick::BinaryValue.bool(true)})],
    [CrystalClick::ObjectDocument.new({"t" => CrystalClick::BinaryValue.uint64(6_u64), "d" => CrystalClick::BinaryValue.int64(-7_i64)})],
  ]
end

private def w129_root_write(path : String, profile = CrystalClick::BinaryBulkProfile.single_stream) : String
  schema = w129_root_schema
  plan = CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["d"]),
      {"d" => CrystalClick::DynamicStructure.new([CrystalClick::BinaryDataType.primitive("String")])}),
    schema.typed_paths)
  CrystalClick::WidePartWriter.write_uint64_object_pair(path, "pk", Slice[0_u64, 2_u64, 8_u64], "payload", schema, plan, w129_root_docs,
    rows_per_mark: 2, frame_bytes: 16, profile: profile)
end

private def with_w129_root(&)
  root = File.tempname("crystal-click-w129-root-")
  Dir.mkdir(root)
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

private def w129_root_catalog(root : String, declaration : String = w129_root_schema.declaration) : String
  database_uuid = "a1310000-0000-4000-8000-000000000129"
  table_uuid = "b1310000-0000-4000-8000-000000000129"
  FileUtils.mkdir_p(File.join(root, "metadata"))
  database = File.join(root, "store", "a13", database_uuid)
  table = File.join(root, "store", "b13", table_uuid)
  FileUtils.mkdir_p(database)
  FileUtils.mkdir_p(table)
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(File.join(database, "events.sql"), "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n`pk` UInt64,\n`payload` #{declaration}\n)\nENGINE = MergeTree\nORDER BY pk\n")
  File.write(File.join(table, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table, "detached"))
  table
end

private def w129_root_values_equal(values : Array(CrystalClick::OfflineColumnValue)) : Nil
  values.size.should eq(3)
  docs = values.map(&.as(CrystalClick::ObjectDocument))
  docs.map { |doc| doc.value_for("t").bytes }.should eq([
    Bytes[4, 0, 0, 0, 0, 0, 0, 0], Bytes[5, 0, 0, 0, 0, 0, 0, 0], Bytes[6, 0, 0, 0, 0, 0, 0, 0],
  ])
  docs[0].value_for("d").bytes.should eq(Bytes[97, 0, 98])
  docs[1].value_for("shared.x").bytes.should eq(Bytes[1])
  docs[2].value_for("d").bytes.should eq(Bytes[249, 255, 255, 255, 255, 255, 255, 255])
end

describe "W129 independently authored catalog contract" do
  it "matches the stock maximum of 1000 typed paths in explicit writer schemas" do
    fields = Hash(String, CrystalClick::BinaryDataType).new
    1000.times { |index| fields["p#{index}"] = CrystalClick::BinaryDataType.primitive("UInt64") }
    CrystalClick::ObjectDocumentSchema.new(fields).typed_paths.size.should eq(1000)
    fields["p1000"] = CrystalClick::BinaryDataType.primitive("UInt64")
    error = expect_raises(ArgumentError) { CrystalClick::ObjectDocumentSchema.new(fields) }
    error.message.not_nil!.should contain("typed paths")
  end

  it "does not let declaration parsing or larger codec limits widen the stock typed-path maximum" do
    fields = (0...1000).map { |index| "p#{index} UInt64" }
    CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(#{fields.join(',')})").typed_paths.size.should eq(1000)
    fields << "p1000 UInt64"
    declaration = "JSON(#{fields.join(',')})"
    error = expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::ObjectDocumentSchema.parse_declaration(declaration) }
    error.message.not_nil!.should contain("typed paths")
    generous = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 100_000, max_elements: 1_000_000, max_bytes: 64 * 1024 * 1024)
    expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::ObjectDocumentSchema.parse_declaration(declaration, generous) }
  end

  it "canonicalizes declaration semantics without permitting unsupported schemas" do
    w129_root_schema.declaration.should eq("JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt64)")
    ["JSON(max_dynamic_paths=1,max_dynamic_paths=1)", "JSON(t UInt64,t UInt64)",
     "JSON(t Nullable(UInt64))", "JSON(SKIP t)", "JSON(max_dynamic_types=255)", "JSON(unknown=1)"].each do |name|
      expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::ObjectDocumentSchema.parse_declaration(name) }
    end
  end

  it "inspects detached row grids and binds a bounded declared schema before reading" do
    with_w129_root do |root|
      part = w129_root_write(File.join(root, "all_1_1_0"))
      descriptor = CrystalClick::ObjectDocumentFileReader.inspect(part, "payload", w129_root_schema.typed_paths, hashed: true)
      descriptor.row_count.should eq(3_u64)
      descriptor.mark_row_counts.should eq([2_u64, 1_u64])
      exposed = descriptor.mark_row_counts
      exposed[0] = 999_u64
      descriptor.mark_row_counts.should eq([2_u64, 1_u64])
      reader = CrystalClick::ObjectColumnReader.open(part, "payload", w129_root_schema)
      reader.row_count.should eq(3_u64)
      reader.read_marks(1, 1)[0][0].value_for("t").bytes.should eq(Bytes[6, 0, 0, 0, 0, 0, 0, 0])
      reader.read_marks(1_i64, 1_i64)[0][0].value_for("t").as_uint64.should eq(6_u64)
      expect_raises(ArgumentError) { reader.read_marks(Int64::MAX, 0_i64) }
      reader.read_marks(2, 0).should eq([] of Array(CrystalClick::ObjectDocument))
    end
  end

  it "materializes owned normalized documents through the existing catalog indexer" do
    [CrystalClick::BinaryBulkProfile.single_stream, CrystalClick::BinaryBulkProfile.with_size_stream].each do |profile|
      with_w129_root do |root|
        path = w129_root_catalog(root, "JSON(t UInt64, max_dynamic_types=1, max_dynamic_paths=1)")
        w129_root_write(File.join(path, "all_1_1_0"), profile)
        selected = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["payload"]
        values = selected.values
        w129_root_values_equal(values)
        document = values[0].as(CrystalClick::ObjectDocument)
        document.paths.clear
        payload = document.value_for("d").bytes
        payload[0] = 0_u8
        document.value_for("d").bytes.should eq(Bytes[97, 0, 98])
        expect_raises(CrystalClick::BoundsError) { selected.values(max_rows: 2_u64) }
        expect_raises(CrystalClick::BoundsError) { selected.values(max_string_bytes: 2_u64) }
        expect_raises(CrystalClick::BoundsError) { selected.values(max_tuple_cells: 1_u64) }
      end
    end
  end

  it "accepts semantically reordered physical JSON declarations and preserves their source spelling" do
    with_w129_root do |root|
      path = w129_root_catalog(root)
      part = w129_root_write(File.join(path, "all_1_1_0"))
      columns_path = File.join(part, "columns.txt")
      original = File.read(columns_path)
      canonical = w129_root_schema.declaration
      reordered = "JSON(t UInt64, max_dynamic_paths=1, max_dynamic_types=1)"
      original.should contain(canonical)
      File.write(columns_path, original.gsub(canonical, reordered))

      reader = CrystalClick::ObjectColumnReader.open(part, "payload", w129_root_schema)
      reader.source_declaration.should eq(reordered)
      reader.schema_declaration.should eq(canonical)
      selected = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["payload"]
      w129_root_values_equal(selected.values)

      File.write(columns_path, original.gsub(canonical, "JSON(t BFloat16)"))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["payload"].values
      end

      File.write(columns_path, original.gsub(canonical, "JSON(t UInt64, max_dynamic_paths=2, max_dynamic_types=1)"))
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["payload"].values
      end
    end
  end

  it "inspects structural grids without authenticating or decoding document payloads" do
    with_w129_root do |root|
      part = w129_root_write(File.join(root, "all_1_1_0"))
      data_path = File.join(part, "#{CrystalClick::StreamName.hash("payload.t")}.bin")
      bytes = writable_file_bytes(data_path)
      bytes[0] ^= 1_u8 # Wrong frame checksum, unchanged header and coordinates.
      File.write(data_path, bytes)
      descriptor = CrystalClick::ObjectDocumentFileReader.inspect(part, "payload", w129_root_schema.typed_paths, hashed: true)
      descriptor.mark_row_counts.should eq([2_u64, 1_u64])
      reader = CrystalClick::ObjectColumnReader.open(part, "payload", w129_root_schema)
      expect_raises(CrystalClick::CorruptPartError) { reader.read_marks(0, 1) }
    end
  end

  it "does not reset retained String limits at the next part boundary" do
    with_w129_root do |root|
      path = w129_root_catalog(root)
      w129_root_write(File.join(path, "all_1_1_0"))
      one_part = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["payload"]
      one_part.values(max_string_bytes: 3_u64).size.should eq(3)
      w129_root_write(File.join(path, "all_2_2_0"))
      two_parts = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["payload"]
      expect_raises(CrystalClick::BoundsError) { two_parts.values(max_string_bytes: 3_u64) }
      two_parts.values(max_string_bytes: 6_u64).size.should eq(6)
    end
  end

  it "rejects differing catalog and part capacities rather than silently returning documents" do
    with_w129_root do |root|
      path = w129_root_catalog(root, "JSON(t UInt64, max_dynamic_types=2, max_dynamic_paths=1)")
      w129_root_write(File.join(path, "all_1_1_0"))
      expect_raises(CrystalClick::CorruptPartError) { CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["payload"].values }
    end
  end

  it "rejects an unknown String version semantically without a file-size mismatch" do
    with_w129_root do |root|
      part = w129_root_write(File.join(root, "all_1_1_0"))
      path = File.join(part, "serialization.json")
      original = File.read(path)
      original.should contain("\"string\":0")
      changed = original.gsub("\"string\":0", "\"string\":2")
      changed.bytesize.should eq(original.bytesize)
      File.write(path, changed)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::ObjectColumnReader.open(part, "payload", w129_root_schema)
      end
    end
  end

  it "validates an unsupported JSON declaration even when no part exists" do
    with_w129_root do |root|
      w129_root_catalog(root, "JSON(t BFloat16)")
      expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["payload"].values }
    end
  end

  it "keeps an absent selected plain mark file classified as corruption" do
    with_w129_root do |root|
      part = w129_root_write(File.join(root, "all_1_1_0"))
      File.delete(File.join(part, "#{CrystalClick::StreamName.hash("payload.t")}.mrk2"))
      expect_raises(CrystalClick::CorruptPartError) { CrystalClick::ObjectColumnReader.open(part, "payload", w129_root_schema) }
    end
  end

  it "rejects an altered count and later-part physical row grid" do
    with_w129_root do |root|
      path = w129_root_catalog(root)
      first = w129_root_write(File.join(path, "all_1_1_0"))
      last = w129_root_write(File.join(path, "all_2_2_0"))
      File.write(File.join(first, "count.txt"), "4")
      expect_raises(CrystalClick::CorruptPartError) { CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["payload"].values }
      File.write(File.join(first, "count.txt"), "3")
      mark_name = "#{CrystalClick::StreamName.hash("payload.t")}.mrk2"
      mark_path = File.join(last, mark_name)
      bytes = writable_file_bytes(mark_path)
      bytes[40] = 2_u8
      File.write(mark_path, bytes)
      expect_raises(CrystalClick::CorruptPartError) { CrystalClick::OfflineCatalog.open(root)["lab"]["events"]["payload"].values }
    end
  end
end

describe "W129 independent aggregate accounting overflow guard" do
  it "admits all pending mark documents atomically before retaining any of them" do
    document = CrystalClick::ObjectDocument.new({"s" => CrystalClick::BinaryValue.string("abc")})
    reference = CrystalClick::ObjectValuesMaterializationBudget.new
    reference.reserve_base(2_u64, 0_u64)
    reference.charge_document(document)
    budget = CrystalClick::ObjectValuesMaterializationBudget.new(logical_limit: reference.retained_logical_bytes)
    budget.reserve_base(2_u64, 0_u64)
    before = {budget.retained_logical_bytes, budget.string_payload_bytes, budget.tuple_cells, budget.node_count, budget.element_count}
    expect_raises(CrystalClick::BoundsError) { budget.charge_documents([document, document]) }
    {budget.retained_logical_bytes, budget.string_payload_bytes, budget.tuple_cells, budget.node_count, budget.element_count}.should eq(before)
    budget.charge_documents([document])
    budget.retained_logical_bytes.should eq(reference.retained_logical_bytes)
    budget.string_payload_bytes.should eq(3_u64)
  end

  it "rejects overflowing reservations without consuming the one-shot reservation" do
    budget = CrystalClick::ObjectValuesMaterializationBudget.new
    expect_raises(CrystalClick::BoundsError) { budget.reserve_base(UInt64::MAX, 0_u64) }
    budget.retained_logical_bytes.should eq(0_u64)
    budget.node_count.should eq(0_u64)
    budget.element_count.should eq(0_u64)
    expect_raises(CrystalClick::BoundsError) { budget.reserve_base(0_u64, 1_u64, UInt64::MAX) }
    budget.retained_logical_bytes.should eq(0_u64)
    budget.reserve_base(0_u64, 0_u64)
    budget.retained_logical_bytes.should be > 0_u64
    expect_raises(CrystalClick::BoundsError) { budget.ensure_workspace(UInt64::MAX) }
  end
end
