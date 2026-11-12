require "./spec_helper"
require "./support/projection_checksum_fixture"

private def with_w130_root(&)
  root = File.tempname("crystal-click-w130-root-")
  Dir.mkdir(root)
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

private def w130_root_schema : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.new(
    {"t" => CrystalClick::BinaryDataType.primitive("UInt64")},
    max_dynamic_paths: 1,
    max_dynamic_types: 1,
  )
end

private def w130_root_write(path : String, keys : Slice(UInt64) = Slice[0_u64, 2_u64, 8_u64]) : String
  schema = w130_root_schema
  plan = CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["d"]),
      {"d" => CrystalClick::DynamicStructure.new([CrystalClick::BinaryDataType.primitive("String")])},
    ),
    schema.typed_paths,
  )
  documents = [
    [CrystalClick::ObjectDocument.new({"t" => CrystalClick::BinaryValue.uint64(4_u64), "d" => CrystalClick::BinaryValue.string("a\0b")}),
     CrystalClick::ObjectDocument.new({"t" => CrystalClick::BinaryValue.uint64(5_u64), "shared.x" => CrystalClick::BinaryValue.bool(true)})],
    [CrystalClick::ObjectDocument.new({"t" => CrystalClick::BinaryValue.uint64(6_u64), "d" => CrystalClick::BinaryValue.int64(-7_i64)})],
  ]
  CrystalClick::WidePartWriter.write_uint64_object_pair(
    path, "pk", keys, "payload", schema, plan, documents,
    rows_per_mark: 2, frame_bytes: 16,
  )
end

private def w130_root_catalog(root : String, declaration : String) : String
  database_uuid = "a1300000-0000-4000-8000-000000000130"
  table_uuid = "b1300000-0000-4000-8000-000000000130"
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

describe "W130 independently authored Object table contract" do
  it "opens a normalized whole-Object column beside its scalar key" do
    with_w130_root do |root|
      part = w130_root_write(File.join(root, "all_1_1_0"))
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      table.total_row_count.should eq(3_u64)
      table.part_mark_row_counts.should eq([[2_u64, 1_u64]])
      table.column_types.should eq([{"pk", "UInt64"}, {"payload", w130_root_schema.declaration}])
    end
  end

  it "aligns cross-part windows, caller order and retained document handles" do
    with_w130_root do |root|
      a = w130_root_write(File.join(root, "all_1_1_0"))
      b = w130_root_write(File.join(root, "all_2_2_0"), Slice[10_u64, 12_u64, 18_u64])
      table = CrystalClick::WidePartTable.open_selected_typed([a, b], ["payload", "pk"])
      table.columns.should eq(["payload", "pk"])
      retained = [] of CrystalClick::ObjectDocument
      observed = [] of Tuple(UInt64, UInt64, UInt64, Int32, Int32)
      table.scan_typed_window(1_u64, 3) do |batch|
        documents = batch.object_documents_for("payload")
        documents.size.should eq(1)
        retained << documents[0]
        observed << {batch.values_for("pk")[0], documents[0].value_for("t").as_uint64,
                     batch.source_row_offset, batch.part_index, batch.mark_index}
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.object_documents_for("pk") }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.object_documents_for("absent") }
        nil
      end
      observed.should eq([{2_u64, 5_u64, 1_u64, 0, 0}, {8_u64, 6_u64, 2_u64, 0, 1}, {10_u64, 4_u64, 3_u64, 1, 0}])
      retained.map { |document| document.value_for("t").as_uint64 }.should eq([5_u64, 6_u64, 4_u64])
      detached = retained[2].value_for("d").bytes
      detached[0] = 0_u8
      retained[2].value_for("d").bytes.should eq(Bytes[97, 0, 98])

      reversed = CrystalClick::WidePartTable.open_selected_typed([b, a], ["pk", "payload"])
      keys = [] of UInt64
      reversed.scan_typed { |batch| keys.concat(batch.values_for("pk")); nil }
      keys.should eq([10_u64, 12_u64, 18_u64, 0_u64, 2_u64, 8_u64])
      callbacks = 0
      table.scan_typed_window(6_u64, 1) { |_batch| callbacks += 1; nil }
      callbacks.should eq(0)
      expect_raises(CrystalClick::BoundsError) { table.scan_typed_window(7_u64, 1) { |_batch| nil } }
      expect_raises(CrystalClick::BoundsError) { table.scan_typed_window(6_u64, 0) { |_batch| nil } }
    end
  end

  it "returns whole candidate granules separately from exact residual rows" do
    with_w130_root do |root|
      a = w130_root_write(File.join(root, "all_1_1_0"))
      b = w130_root_write(File.join(root, "all_2_2_0"), Slice[10_u64, 12_u64, 18_u64])
      table = CrystalClick::WidePartTable.open_selected_typed([a, b], ["pk", "payload"])
      candidates = [] of UInt64
      exact = [] of UInt64
      offsets = [] of Tuple(Int32, Int32, UInt64)
      table.scan_typed_candidate_marks([[0, 1], [0]]) do |batch|
        offsets << {batch.part_index, batch.mark_index, batch.source_row_offset}
        keys = batch.values_for("pk")
        documents = batch.object_documents_for("payload")
        keys.size.should eq(documents.size)
        candidates.concat(keys)
        keys.each { |key| exact << key if key >= 8_u64 && key <= 10_u64 }
        nil
      end
      candidates.should eq([0_u64, 2_u64, 8_u64, 10_u64, 12_u64])
      exact.should eq([8_u64, 10_u64])
      offsets.should eq([{0, 0, 0_u64}, {0, 1, 2_u64}, {1, 0, 3_u64}])
      callbacks = 0
      expect_raises(CrystalClick::BoundsError) do
        table.scan_typed_candidate_marks([[0], [2]]) { |_batch| callbacks += 1; nil }
      end
      callbacks.should eq(0)
    end
  end

  it "does not parse or decode an unselected sibling Object declaration" do
    with_w130_root do |root|
      part = w130_root_write(File.join(root, "all_1_1_0"))
      path = File.join(part, "columns.txt")
      File.write(path, File.read(path).gsub(w130_root_schema.declaration, "JSON(t BFloat16)"))
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk"])
      keys = [] of UInt64
      table.scan_typed { |batch| keys.concat(batch.values_for("pk")); nil }
      keys.should eq([0_u64, 2_u64, 8_u64])
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
      end
    end
  end

  it "retains dotted-literal versus virtual typed-path ambiguity before Object dispatch" do
    with_w130_root do |root|
      part = w130_root_write(File.join(root, "all_1_1_0"))
      path = File.join(part, "columns.txt")
      # Exercise the legacy virtual-path grammar without widening it to the
      # canonical whole-Object schema grammar (caps and quoted paths).
      columns = File.read(path).sub("2 columns:\n", "3 columns:\n")
        .sub(w130_root_schema.declaration, "JSON(t UInt64)")
      columns += "`payload.t` #{w130_root_schema.declaration}\n"
      File.write(path, columns)
      expect_raises(CrystalClick::UnsupportedFormatError, "ambiguous between a literal dotted column and a JSON typed path") do
        CrystalClick::WidePartTable.open_selected_typed([part], ["payload.t"])
      end
    end
  end

  it "rejects later-part Object schema drift before any candidate callback" do
    with_w130_root do |root|
      a = w130_root_write(File.join(root, "all_1_1_0"))
      b = w130_root_write(File.join(root, "all_2_2_0"))
      path = File.join(b, "columns.txt")
      File.write(path, File.read(path).gsub("max_dynamic_paths=1", "max_dynamic_paths=2"))
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([a, b], ["pk", "payload"])
        table.scan_typed_candidate_marks([[0], [] of Int32]) { |_batch| callbacks += 1; nil }
      end
      callbacks.should eq(0)
    end
  end

  it "does not decode a corrupt Object granule outside a selected window or schedule" do
    with_w130_root do |root|
      part = w130_root_write(File.join(root, "all_1_1_0"))
      basename = CrystalClick::StreamName.hash("payload.t")
      marks = File.read(File.join(part, "#{basename}.mrk2")).to_slice
      next_frame = 0_u64
      8.times { |index| next_frame |= marks[24 + index].to_u64 << (index * 8) }
      next_frame.should be > 0_u64 # The chosen skipped and selected frames are disjoint.
      path = File.join(part, "#{basename}.bin")
      bytes = File.read(path).to_slice.dup
      bytes[0] ^= 1_u8 # Bad checksum only; framing and physical size stay intact.
      File.write(path, bytes)

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      keys = [] of UInt64
      table.scan_typed_window(2_u64, 1) do |batch|
        keys.concat(batch.values_for("pk"))
        batch.object_documents_for("payload")[0].value_for("t").as_uint64.should eq(6_u64)
        nil
      end
      keys.should eq([8_u64])
      keys.clear
      table.scan_typed_candidate_marks([[1]]) { |batch| keys.concat(batch.values_for("pk")); nil }
      keys.should eq([8_u64])
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed { |_batch| callbacks += 1; nil }
      end
      callbacks.should eq(0)
    end
  end

  it "rejects later-part selected-column grid drift before any candidate callback" do
    with_w130_root do |root|
      a = w130_root_write(File.join(root, "all_1_1_0"))
      b = w130_root_write(File.join(root, "all_2_2_0"))
      basename = CrystalClick::StreamName.hash("pk")
      path = File.join(b, "#{basename}.mrk2")
      bytes = File.read(path).to_slice.dup
      bytes[16] = 1_u8
      bytes[40] = 2_u8
      File.write(path, bytes)
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([a, b], ["payload", "pk"])
        table.scan_typed_candidate_marks([[0], [] of Int32]) { |_batch| callbacks += 1; nil }
      end
      callbacks.should eq(0)
    end
  end

  it "reads whole-Object projection child values and preserves parent identity" do
    with_w130_root do |root|
      parent = w130_root_write(File.join(root, "all_1_1_0"))
      w130_root_write(File.join(parent, "by_payload.proj"), Slice[100_u64, 101_u64, 102_u64])
      ProjectionChecksumFixture.rebind!(parent, "by_payload")
      table = CrystalClick::WidePartTable.open_selected_projection_typed([parent], "by_payload", ["pk", "payload"])
      table.total_row_count.should eq(3_u64)
      table.part_mark_row_counts.should eq([[2_u64, 1_u64]])
      observed = [] of Tuple(UInt64, UInt64)
      parent_paths = [] of String
      table.scan_typed do |batch|
        parent_paths << batch.part_path
        batch.column_names.should eq(["pk", "payload"])
        documents = batch.object_documents_for("payload")
        keys = batch.values_for("pk", UInt64)
        keys.each_with_index { |key, index| observed << {key, documents[index].value_for("t").as_uint64} }
      end
      observed.should eq([{100_u64, 4_u64}, {101_u64, 5_u64}, {102_u64, 6_u64}])
      parent_paths.uniq.should eq([parent])
    end
  end

  it "does not reinterpret a callback exception as an Object read failure" do
    with_w130_root do |root|
      part = w130_root_write(File.join(root, "all_1_1_0"))
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
      sentinel = ArgumentError.new("w130-root-callback-sentinel")
      caught = expect_raises(ArgumentError, "w130-root-callback-sentinel") do
        table.scan_typed { |_batch| raise sentinel }
      end
      caught.same?(sentinel).should be_true
    end
  end

  it "rejects Object selections through scalar-only scan APIs before any callback" do
    with_w130_root do |root|
      part = w130_root_write(File.join(root, "all_1_1_0"))
      [["payload"], ["pk", "payload"]].each do |columns|
        table = CrystalClick::WidePartTable.open_selected_typed([part], columns)
        callbacks = 0
        expect_raises(CrystalClick::UnsupportedFormatError) { table.scan { |_batch| callbacks += 1; nil } }
        expect_raises(CrystalClick::UnsupportedFormatError) { table.scan_numeric { |_batch| callbacks += 1; nil } }
        expect_raises(CrystalClick::UnsupportedFormatError) { table.scan_candidate_marks([[0]]) { |_batch| callbacks += 1; nil } }
        callbacks.should eq(0)
      end
    end
  end

  it "binds canonical whole-Object catalog schemas without changing candidate semantics" do
    with_w130_root do |root|
      declaration = "JSON(t UInt64, max_dynamic_paths=1, max_dynamic_types=1)"
      path = w130_root_catalog(root, declaration)
      w130_root_write(File.join(path, "all_1_1_0"))
      later = w130_root_write(File.join(path, "all_2_2_0"), Slice[10_u64, 12_u64, 18_u64])
      columns = File.join(later, "columns.txt")
      File.write(columns, File.read(columns).gsub(w130_root_schema.declaration, declaration))
      table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      rows = [] of Tuple(UInt64, UInt64)
      table.scan_typed_window(["pk", "payload"], 2_u64, 2) do |batch|
        batch.column_names.should eq(["pk", "payload"])
        batch.column_type_for("payload").should eq(w130_root_schema.declaration)
        keys = batch.values_for("pk")
        docs = batch.object_documents_for("payload")
        keys.size.times { |index| rows << {keys[index], docs[index].value_for("t").as_uint64} }
        nil
      end
      rows.should eq([{8_u64, 6_u64}, {10_u64, 4_u64}])
      candidate_keys = [] of UInt64
      exact_keys = [] of UInt64
      table.scan_uint64_pk_candidates(["pk", "payload"], lower_bound: 8_u64, upper_bound: 10_u64) do |batch|
        keys = batch.values_for("pk")
        batch.object_documents_for("payload").size.should eq(keys.size)
        candidate_keys.concat(keys)
        keys.each { |key| exact_keys << key if key >= 8_u64 && key <= 10_u64 }
        nil
      end
      candidate_keys.should eq([0_u64, 2_u64, 8_u64, 10_u64, 12_u64])
      exact_keys.should eq([8_u64, 10_u64])
    end
  end
end
