require "./spec_helper"

private def with_w131_root(&)
  root = File.tempname("crystal-click-w131-root-")
  Dir.mkdir(root)
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

private def w131_root_schema : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.new({
    "s" => CrystalClick::BinaryDataType.primitive("Int64"),
    "u" => CrystalClick::BinaryDataType.primitive("UInt64"),
    "t" => CrystalClick::BinaryDataType.primitive("String"),
  }, max_dynamic_paths: 0, max_dynamic_types: 0)
end

private def w131_root_plan : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    w131_root_schema.typed_paths,
  )
end

private def w131_root_values : Array(Int64)
  [Int64::MIN, -1_i64, 0_i64, 1_i64, Int64::MAX]
end

private def w131_root_documents : Array(Array(CrystalClick::ObjectDocument))
  documents = w131_root_values.map_with_index do |value, index|
    CrystalClick::ObjectDocument.new({
      "s" => CrystalClick::BinaryValue.int64(value),
      "u" => CrystalClick::BinaryValue.uint64(index.to_u64),
      "t" => CrystalClick::BinaryValue.string("row#{index}\0é"),
    })
  end
  [documents[0, 2], documents[2, 2], documents[4, 1]]
end

private def w131_root_write(destination : String, documents = w131_root_documents) : String
  CrystalClick::WidePartWriter.write_uint64_object_pair(
    destination, "pk", Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64],
    "payload", w131_root_schema, w131_root_plan, documents,
    rows_per_mark: 2, frame_bytes: 16,
  )
end

private def w131_root_catalog(root : String, declaration : String) : String
  database_uuid = "a1310000-0000-4000-8000-000000000131"
  table_uuid = "b1310000-0000-4000-8000-000000000131"
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

describe "W131 independent signed Object consumer contract" do
  it "pairs whole-part writing and file/column reads without unsigned reinterpretation" do
    with_w131_root do |root|
      part = w131_root_write(File.join(root, "all_1_1_0"))
      reader = CrystalClick::ObjectColumnReader.open(part, "payload", w131_root_schema)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      actual = reader.read_marks(0, 3).flatten
      actual.map { |document| document.value_for("s").as_int64 }.should eq(w131_root_values)
      actual.each_with_index do |document, index|
        document.value_for("s").type.should eq(CrystalClick::BinaryDataType.primitive("Int64"))
        expect_raises(ArgumentError) { document.value_for("s").as_uint64 }
        document.value_for("u").as_uint64.should eq(index.to_u64)
        document.value_for("t").bytes.should eq("row#{index}\0é".to_slice)
      end
      middle = CrystalClick::ObjectDocumentFileReader.read(part, "payload", w131_root_schema.typed_paths,
        first_mark: 1, mark_count: 1, hashed: true)
      middle.flatten.map { |document| document.value_for("s").as_int64 }.should eq([0_i64, 1_i64])
      reader.read_marks(3, 0).should be_empty
    end
  end

  it "exposes canonical catalog values, signed table windows and whole PK candidates" do
    with_w131_root do |root|
      directory = w131_root_catalog(root, "JSON(t String, u UInt64, s Int64, max_dynamic_paths=0, max_dynamic_types=0)")
      w131_root_write(File.join(directory, "all_1_1_0"))
      table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      values = table["payload"].values.map(&.as(CrystalClick::ObjectDocument))
      values.map { |document| document.value_for("s").as_int64 }.should eq(w131_root_values)
      window = [] of Tuple(UInt64, Int64)
      retained = [] of CrystalClick::ObjectDocument
      table.scan_typed_window(["payload", "pk"], 1_u64, 3) do |batch|
        batch.column_type_for("payload").should eq(w131_root_schema.declaration)
        keys = batch.values_for("pk")
        documents = batch.object_documents_for("payload")
        keys.size.times do |index|
          window << {keys[index], documents[index].value_for("s").as_int64}
          retained << documents[index]
        end
        nil
      end
      window.should eq([{2_u64, -1_i64}, {3_u64, 0_i64}, {4_u64, 1_i64}])
      retained.map { |document| document.value_for("s").as_int64 }.should eq([-1_i64, 0_i64, 1_i64])
      candidates = [] of UInt64
      residual = [] of Tuple(UInt64, Int64)
      table.scan_uint64_pk_candidates(["pk", "payload"], lower_bound: 3_u64, upper_bound: 4_u64) do |batch|
        keys = batch.values_for("pk")
        documents = batch.object_documents_for("payload")
        candidates.concat(keys)
        keys.size.times do |index|
          key = keys[index]
          residual << {key, documents[index].value_for("s").as_int64} if 3_u64 <= key <= 4_u64
        end
        nil
      end
      candidates.should eq([1_u64, 2_u64, 3_u64, 4_u64])
      residual.should eq([{3_u64, 0_i64}, {4_u64, 1_i64}])
    end
  end

  it "refuses UInt64 document values before publication rather than coercing them" do
    with_w131_root do |root|
      granules = w131_root_documents
      granules[0][0] = CrystalClick::ObjectDocument.new({
        "s" => CrystalClick::BinaryValue.uint64(0_u64),
        "u" => CrystalClick::BinaryValue.uint64(0_u64),
        "t" => CrystalClick::BinaryValue.string("wrong nominal type"),
      })
      expect_raises(CrystalClick::UnsupportedFormatError) { w131_root_write(File.join(root, "all_1_1_0"), granules) }
      Dir.children(root).should be_empty
    end
  end

  it "rejects later-part signedness drift before any table callback" do
    with_w131_root do |root|
      first = w131_root_write(File.join(root, "all_1_1_0"))
      later = w131_root_write(File.join(root, "all_2_2_0"))
      columns = File.join(later, "columns.txt")
      File.write(columns, File.read(columns).sub("s Int64", "s UInt64"))
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([first, later], ["payload"])
        table.scan_typed { |_batch| callbacks += 1; nil }
      end
      callbacks.should eq(0)
    end
  end

  it "does not decode a corrupt skipped signed frame but rejects a selected one" do
    with_w131_root do |root|
      part = w131_root_write(File.join(root, "all_1_1_0"))
      data_file = File.join(part, "#{CrystalClick::StreamName.hash("payload.s")}.bin")
      bytes = writable_file_bytes(data_file)
      bytes[0] ^= 0xff_u8
      File.write(data_file, bytes)
      reader = CrystalClick::ObjectColumnReader.open(part, "payload", w131_root_schema)
      reader.read_marks(2, 1)[0][0].value_for("s").as_int64.should eq(Int64::MAX)
      reader.read_marks(3, 0).should be_empty
      expect_raises(CrystalClick::CorruptPartError) { reader.read_marks(0, 1) }
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload", "pk"])
      observed = [] of Int64
      table.scan_typed_window(4_u64, 1) do |batch|
        observed << batch.object_documents_for("payload")[0].value_for("s").as_int64
        nil
      end
      observed.should eq([Int64::MAX])
    end
  end
end
