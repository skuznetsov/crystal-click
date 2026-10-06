require "./spec_helper"

module CrystalClick::WidePartWriter
  # Rebuild the temporary corruption fixture's checksums so the negative stays
  # focused on the shifted Array(JSON) schedule rather than stale file hashes.
  def self.w185_refresh_checksums(part : String) : Nil
    current = PartChecksums.open(part)
    records = [] of ChecksumRecord
    current.entries.each do |name, entry|
      bytes = File.read(File.join(part, name)).to_slice
      file_hash = CityHashV1.file_hash(bytes)
      if entry.compressed
        raw = CompressedBlock.decode_all(bytes)
        records << ChecksumRecord.new(
          name, bytes.size.to_u64, file_hash, true, raw.size.to_u64, CityHashV1.file_hash(raw)
        )
      else
        records << ChecksumRecord.new(name, bytes.size.to_u64, file_hash, false)
      end
    end
    write_checksums(part, records)
  end
end

private def w185_array_object_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w185_array_object_redistribute_size0(part : String) : Nil
  data_path = File.join(part, "#{CrystalClick::StreamName.hash("a.size0")}.bin")
  marks_path = File.join(part, "#{CrystalClick::StreamName.hash("a.size0")}.mrk2")
  raw = CrystalClick::CompressedBlock.decode_all(File.read(data_path).to_slice).dup
  raw.size.should eq(8 * 8)
  # Keep the global child count at three, but move one child from mark 2 to
  # mark 3. The earlier marks remain valid; typed/shared child lanes still
  # encode [1, 0, 2, 0].
  w185_array_object_write_u64(raw, 32, 1_u64)
  w185_array_object_write_u64(raw, 48, 1_u64)
  rewritten = CrystalClick::CompressedMarkWriter.encode(
    raw,
    [0_u64, 16_u64, 32_u64, 48_u64, 64_u64],
    [2_u64, 2_u64, 2_u64, 2_u64],
  )
  File.write(data_path, rewritten.data)
  File.write(marks_path, rewritten.marks)
  CrystalClick::WidePartWriter.w185_refresh_checksums(part)
end

private def w185_array_object_schema : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.new(
    {"t" => CrystalClick::BinaryDataType.primitive("UInt8")},
    max_dynamic_paths: 0,
    max_dynamic_types: 0,
  )
end

private def w185_array_object_plan : CrystalClick::ObjectDocumentPlan
  schema = w185_array_object_schema
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    CrystalClick::ObjectStructure.new([] of String),
    {} of String => CrystalClick::DynamicStructure,
  )
  CrystalClick::ObjectDocumentPlan.new(structures, schema.typed_paths)
end

private def w185_array_object_doc(t : UInt8, shared : String) : CrystalClick::ObjectDocument
  CrystalClick::ObjectDocument.new({
    "t" => CrystalClick::BinaryValue.fixed(
      CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[t]),
    "shared" => CrystalClick::BinaryValue.string(shared),
  })
end

private def w185_array_object_granules : Array(Array(Array(CrystalClick::ObjectDocument)))
  [
    [
      [] of CrystalClick::ObjectDocument,
      [w185_array_object_doc(7_u8, "red")] of CrystalClick::ObjectDocument,
    ],
    [
      [] of CrystalClick::ObjectDocument,
      [] of CrystalClick::ObjectDocument,
    ],
    [
      [w185_array_object_doc(11_u8, "blue"), w185_array_object_doc(13_u8, "green")] of CrystalClick::ObjectDocument,
      [] of CrystalClick::ObjectDocument,
    ],
    [
      [] of CrystalClick::ObjectDocument,
      [] of CrystalClick::ObjectDocument,
    ],
  ] of Array(Array(CrystalClick::ObjectDocument))
end

private def w185_array_object_empty_granules : Array(Array(Array(CrystalClick::ObjectDocument)))
  Array(Array(Array(CrystalClick::ObjectDocument))).new(4) do
    [
      [] of CrystalClick::ObjectDocument,
      [] of CrystalClick::ObjectDocument,
    ] of Array(CrystalClick::ObjectDocument)
  end
end

private def w185_array_object_signatures(
  marks : Array(Array(Array(CrystalClick::ObjectDocument))),
) : Array(Array(Array(String)))
  marks.map do |rows|
    rows.map do |documents|
      documents.map do |document|
        "#{document.value_for("t").bytes[0]}:#{document.value_for("shared").as_string}"
      end
    end
  end
end

private def w185_array_object_table_rows(
  table : CrystalClick::WidePartTable,
  column : String,
) : Array(Array(CrystalClick::ObjectDocument))
  rows = [] of Array(CrystalClick::ObjectDocument)
  table.scan_typed(batch_rows: 2) do |batch|
    batch.array_object_documents_for(column).each { |row| rows << row }
    nil
  end
  rows
end

private def with_w185_array_object_directory(&)
  parent = File.tempname("crystal-click-w185-array-object-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe "W185 persisted Array(JSON) MAP site" do
  it "writes, reopens, and scans parent rows without confusing them with JSON child occurrences" do
    with_w185_array_object_directory do |parent|
      part = File.join(parent, "all_1_1_0")
      schema = w185_array_object_schema
      plan = w185_array_object_plan
      granules = w185_array_object_granules
      keys = Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64]

      CrystalClick::WidePartWriter.write_uint64_array_object_pair(
        part, "pk", keys, "a", schema, plan, granules,
        rows_per_mark: 2, mode: 0_u64, frame_bytes: 64,
      ).should eq(part)

      File.read(File.join(part, "count.txt")).should eq("8")
      File.read(File.join(part, "metadata_version.txt")).should eq("0")
      File.exists?(File.join(part, "checksums.txt")).should be_true
      File.read(File.join(part, "columns.txt")).should contain(
        "`a` Array(JSON(max_dynamic_types=0, max_dynamic_paths=0, t UInt8))"
      )
      substreams = File.read(File.join(part, "columns_substreams.txt"))
      substreams.should contain("a.size0")
      substreams.should contain("a.t")
      substreams.should contain("a.object_shared_data.size1")

      reader = CrystalClick::ArrayObjectColumnReader.open(part, "a", schema)
      reader.schema_declaration.should eq("Array(#{schema.declaration})")
      reader.row_count.should eq(8_u64)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
      reader.physical_stream_names.should contain("a.size0")
      reader.physical_stream_names.should contain("a.t")
      reader.physical_stream_names.should contain("a.object_shared_data.size1")

      expected = [
        [[] of String, ["7:red"]],
        [[] of String, [] of String],
        [["11:blue", "13:green"], [] of String],
        [[] of String, [] of String],
      ]
      w185_array_object_signatures(reader.read_marks(0, reader.mark_count)).should eq(expected)
      # Mark 1 is a real zero-child middle mark. This selected read starts after
      # the earlier child in mark 0 and retains one shared-MAP value in mark 2.
      w185_array_object_signatures(reader.read_marks(1, 2)).should eq([
        [[] of String, [] of String],
        [["11:blue", "13:green"], [] of String],
      ])

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "a"])
      table.total_row_count.should eq(8_u64)
      table.column_types.should eq([{"pk", "UInt64"}, {"a", "Array(JSON(max_dynamic_types=0, max_dynamic_paths=0, t UInt8))"}])
      rows = w185_array_object_table_rows(table, "a")
      rows.size.should eq(8)
      rows.map(&.size).should eq([0, 1, 0, 0, 2, 0, 0, 0])
      rows.map do |documents|
        documents.map { |document| "#{document.value_for("t").bytes[0]}:#{document.value_for("shared").as_string}" }
      end.should eq([[] of String, ["7:red"], [] of String, [] of String, ["11:blue", "13:green"], [] of String, [] of String, [] of String])

      window_rows = [] of Array(CrystalClick::ObjectDocument)
      table.scan_typed_window(4_u64, 4) do |batch|
        batch.array_object_documents_for("a").each { |row| window_rows << row }
        nil
      end
      window_rows.map(&.size).should eq([2, 0, 0, 0])
      window_rows[0].map { |document| document.value_for("shared").as_string }.should eq(["blue", "green"])

      original_checksums = File.read(File.join(part, "checksums.txt"))
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_object_pair(
          part, "pk", keys, "a", schema, plan, granules,
          rows_per_mark: 2, mode: 0_u64, frame_bytes: 64,
        )
      end
      File.read(File.join(part, "checksums.txt")).should eq(original_checksums)
      File.read(File.join(part, "count.txt")).should eq("8")
      Dir.children(parent).should eq(["all_1_1_0"])

      wrong_caps = CrystalClick::ObjectDocumentSchema.new(
        {"t" => CrystalClick::BinaryDataType.primitive("UInt8")},
        max_dynamic_paths: 1,
        max_dynamic_types: 0,
      )
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::ArrayObjectColumnReader.open(part, "a", wrong_caps)
      end
    end
  end

  it "keeps all-empty parent rows distinct from an empty mark selection" do
    with_w185_array_object_directory do |parent|
      part = File.join(parent, "all_2_2_0")
      compact_part = File.join(parent, "all_3_3_0")
      schema = w185_array_object_schema
      granules = w185_array_object_empty_granules
      keys = Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64]

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_array_object_pair(
          compact_part, "pk", keys, "a", schema, w185_array_object_plan, granules,
          rows_per_mark: 2, mode: 1_u64, frame_bytes: 64,
        )
      end
      File.exists?(compact_part).should be_false

      CrystalClick::WidePartWriter.write_uint64_array_object_pair(
        part, "pk", keys, "a", schema, w185_array_object_plan, granules,
        rows_per_mark: 2, frame_bytes: 64,
      )

      reader = CrystalClick::ArrayObjectColumnReader.open(part, "a", schema)
      full = reader.read_marks(0, reader.mark_count)
      full.size.should eq(4)
      full.map(&.size).should eq([2, 2, 2, 2])
      full.flat_map { |mark| mark.map(&.size) }.should eq([0, 0, 0, 0, 0, 0, 0, 0])
      reader.read_marks(reader.mark_count, 0).should be_empty

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "a"])
      rows = w185_array_object_table_rows(table, "a")
      rows.size.should eq(8)
      rows.map(&.size).should eq([0, 0, 0, 0, 0, 0, 0, 0])
    end
  end

  it "rejects shifted Array(JSON) outer marks before invoking a batch callback" do
    with_w185_array_object_directory do |parent|
      part = File.join(parent, "all_1_1_0")
      corrupt = File.join(parent, "all_2_2_0")
      schema = w185_array_object_schema
      keys = Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64]
      CrystalClick::WidePartWriter.write_uint64_array_object_pair(
        part, "pk", keys, "a", schema, w185_array_object_plan, w185_array_object_granules,
        rows_per_mark: 2, mode: 0_u64, frame_bytes: 64,
      )

      FileUtils.cp_r(part, corrupt)
      marks_path = File.join(corrupt, "#{CrystalClick::StreamName.hash("a.size0")}.mrk2")
      marks = File.read(marks_path).to_slice.dup
      marks.size.should eq(5 * CrystalClick::WidePart::MARK_SIZE)
      # The second mark claims three outer rows while the key and nested typed
      # lanes still claim two. Refresh checksums to isolate schedule validation.
      w185_array_object_write_u64(marks, CrystalClick::WidePart::MARK_SIZE + 16, 3_u64)
      File.write(marks_path, marks)
      CrystalClick::WidePartWriter.w185_refresh_checksums(corrupt)

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([corrupt], ["pk", "a"])
        table.scan_typed(batch_rows: 2) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    end
  end

  it "rejects a late same-total child redistribution before its selected mark callback" do
    with_w185_array_object_directory do |parent|
      source = File.join(parent, "all_1_1_0")
      corrupt = File.join(parent, "all_2_2_0")
      schema = w185_array_object_schema
      keys = Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64]
      CrystalClick::WidePartWriter.write_uint64_array_object_pair(
        source, "pk", keys, "a", schema, w185_array_object_plan, w185_array_object_granules,
        rows_per_mark: 2, mode: 0_u64, frame_bytes: 64,
      )
      FileUtils.cp_r(source, corrupt)
      w185_array_object_redistribute_size0(corrupt)

      # The selected late mark catches a same-total C redistribution without
      # relying on an earlier mark or a stale checksum to trigger rejection.
      table = CrystalClick::WidePartTable.open_selected_typed([corrupt], ["pk", "a"])
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed_candidate_marks([[3]]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    end
  end
end
