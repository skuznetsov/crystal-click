require "./spec_helper"

private def w187_array_table_json_schema : CrystalClick::ObjectDocumentSchema
  CrystalClick::ObjectDocumentSchema.parse_declaration("JSON(t UInt8)")
end

private def w187_array_table_schema : CrystalClick::StorageColumnSchema
  json = w187_array_table_json_schema
  CrystalClick::StorageColumnSchema.parse(
    "Tuple(items Array(Array(Tuple(doc #{json.declaration}, label LowCardinality(String), n UInt64))))"
  )
end

private def w187_array_table_plan(schema : CrystalClick::ObjectDocumentSchema) : CrystalClick::ObjectDocumentPlan
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String),
      {} of String => CrystalClick::DynamicStructure,
    ),
    schema.typed_paths,
  )
end

private def w187_array_table_item(
  typed : UInt8,
  label : String,
  sequence : UInt64,
) : CrystalClick::StorageColumnValue
  json = CrystalClick::ObjectDocument.new({
    "t" => CrystalClick::BinaryValue.fixed(
      CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[typed]
    ),
  })
  label_type = CrystalClick::BinaryDataType.low_cardinality(
    CrystalClick::BinaryDataType.primitive("String")
  )
  CrystalClick::StorageColumnValue.tuple([
    CrystalClick::StorageColumnValue.object_document(json),
    CrystalClick::StorageColumnValue.bulk(
      CrystalClick::BinaryValue.low_cardinality(label_type, CrystalClick::BinaryValue.string(label))
    ),
    CrystalClick::StorageColumnValue.bulk(CrystalClick::BinaryValue.uint64(sequence)),
  ] of CrystalClick::StorageColumnValue)
end

private def w187_array_table_row(groups : Array(Array(CrystalClick::StorageColumnValue))) : CrystalClick::StorageColumnValue
  nested = groups.map do |items|
    CrystalClick::StorageColumnValue.array(items)
  end
  CrystalClick::StorageColumnValue.tuple([
    CrystalClick::StorageColumnValue.array(nested),
  ] of CrystalClick::StorageColumnValue)
end

private def w187_array_table_granules : Array(Array(CrystalClick::StorageColumnValue))
  [
    [
      w187_array_table_row([
        [w187_array_table_item(7_u8, "oak", 70_u64)] of CrystalClick::StorageColumnValue,
        [] of CrystalClick::StorageColumnValue,
      ] of Array(CrystalClick::StorageColumnValue)),
      w187_array_table_row([] of Array(CrystalClick::StorageColumnValue)),
    ] of CrystalClick::StorageColumnValue,
    [
      w187_array_table_row([] of Array(CrystalClick::StorageColumnValue)),
      w187_array_table_row([] of Array(CrystalClick::StorageColumnValue)),
    ] of CrystalClick::StorageColumnValue,
    [
      w187_array_table_row([
        [w187_array_table_item(17_u8, "oak", 170_u64)] of CrystalClick::StorageColumnValue,
        [w187_array_table_item(19_u8, "cedar", 190_u64)] of CrystalClick::StorageColumnValue,
      ] of Array(CrystalClick::StorageColumnValue)),
      w187_array_table_row([] of Array(CrystalClick::StorageColumnValue)),
    ] of CrystalClick::StorageColumnValue,
    [
      w187_array_table_row([] of Array(CrystalClick::StorageColumnValue)),
      w187_array_table_row([] of Array(CrystalClick::StorageColumnValue)),
    ] of CrystalClick::StorageColumnValue,
  ] of Array(CrystalClick::StorageColumnValue)
end

private def w187_array_table_empty_granules : Array(Array(CrystalClick::StorageColumnValue))
  Array(Array(CrystalClick::StorageColumnValue)).new(4) do
    [
      w187_array_table_row([] of Array(CrystalClick::StorageColumnValue)),
      w187_array_table_row([] of Array(CrystalClick::StorageColumnValue)),
    ] of CrystalClick::StorageColumnValue
  end
end

private def w187_array_table_row_signature(value : CrystalClick::StorageColumnValue) : Array(Array(String))
  value.tuple?.should be_true
  outer = value.child_at(0)
  outer.array?.should be_true
  outer.array_values.map do |inner|
    inner.array?.should be_true
    inner.array_values.map do |item|
      item.tuple?.should be_true
      document = item.child_at(0).object_document
      label = item.child_at(1).bulk_value.child_at(0).as_string
      sequence = item.child_at(2).bulk_value.as_uint64
      "#{document.value_for("t").bytes[0]}:#{label}:#{sequence}"
    end
  end
end

private def w187_array_table_mark_signature(
  rows : Array(CrystalClick::StorageColumnValue),
) : Array(Array(Array(String)))
  rows.map { |row| w187_array_table_row_signature(row) }
end

private def with_w187_array_table_directory(& : String ->)
  root = File.tempname("crystal-click-w187-recursive-array-table-")
  Dir.mkdir(root)
  yield root
ensure
  FileUtils.rm_rf(root) if root && Dir.exists?(root)
end

private def w187_array_table_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

module CrystalClick::WidePartWriter
  # Rebuild temporary fixture checksums after changing a schedule lane so that
  # the corruption check tests occurrence validation, not stale hashes.
  def self.w187_refresh_checksums(part : String) : Nil
    current = PartChecksums.open(part)
    records = [] of ChecksumRecord
    current.entries.each do |name, entry|
      bytes = File.read(File.join(part, name)).to_slice
      file_hash = CityHashV1.file_hash(bytes)
      if entry.compressed
        raw = bytes.empty? ? Bytes.empty : CompressedBlock.decode_all(bytes)
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

private def w187_array_table_corrupt_outer_q(part : String) : Nil
  logical_name = "payload%2Eitems.size0"
  data_path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  marks_path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.mrk2")
  raw = CrystalClick::CompressedBlock.decode_all(File.read(data_path).to_slice).dup
  raw.size.should eq(8 * 8)
  # Mark 2's first parent now claims three outer Array children. The following
  # size1 lane still contains only two entries for that mark, so its inherited
  # Q domain is inconsistent even though the root P grid remains unchanged.
  w187_array_table_write_u64(raw, 4 * 8, 3_u64)
  rewritten = CrystalClick::CompressedMarkWriter.encode(
    raw,
    [0_u64, 16_u64, 32_u64, 48_u64, 64_u64],
    [2_u64, 2_u64, 2_u64, 2_u64],
  )
  File.write(data_path, rewritten.data)
  File.write(marks_path, rewritten.marks)
  CrystalClick::WidePartWriter.w187_refresh_checksums(part)
end

private def with_w187_recursive_catalog(& : CrystalClick::OfflineTable ->)
  root = File.tempname("crystal-click-w187-recursive-pk-candidate-")
  Dir.mkdir(root)
  database_uuid = "b1777707-5b3b-4bfc-9900-000000000001"
  table_uuid = "b1777707-5b3b-4bfc-9900-000000000002"
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(database_path)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(File.join(database_path, "events.sql"), <<-DDL)
    ATTACH TABLE _ UUID '#{table_uuid}'
    (
        `pk` UInt64,
        `payload` #{w187_array_table_schema.declaration}
    )
    ENGINE = MergeTree
    ORDER BY pk
    DDL
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  yield CrystalClick::OfflineCatalog.open(root).table("lab", "events")
ensure
  FileUtils.rm_rf(root) if root && Dir.exists?(root)
end

describe "W187 recursive Array typed table consumers" do
  it "regroups repeated Array occurrences and replays a LowCardinality sibling for selected middle windows" do
    with_w187_array_table_directory do |parent|
      part = File.join(parent, "all_1_1_0")
      schema = w187_array_table_schema
      object_schema = w187_array_table_json_schema
      plans = {"root/tuple[0]/array[0]/array[0]/tuple[0]" => w187_array_table_plan(object_schema)}
      keys = Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64]
      granules = w187_array_table_granules

      CrystalClick::WidePartWriter.write_uint64_recursive_pair(
        part, "pk", keys, "payload", schema, plans, granules,
        rows_per_mark: 2,
        mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
        frame_bytes: 64,
      ).should eq(part)

      reader = CrystalClick::RecursiveStorageColumnReader.open(part, "payload", schema)
      reader.schema_declaration.should eq(schema.declaration)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
      names = reader.physical_stream_names
      names.should contain("payload%2Eitems.size0")
      names.should contain("payload%2Eitems.size1")
      names.any?(&.starts_with?("payload%2Eitems%2Edoc")).should be_true
      names.any?(&.starts_with?("payload%2Eitems%2Elabel")).should be_true

      expected = [
        [
          [["7:oak:70"], [] of String] of Array(String),
          [] of Array(String),
        ] of Array(Array(String)),
        [
          [] of Array(String),
          [] of Array(String),
        ] of Array(Array(String)),
        [
          [["17:oak:170"], ["19:cedar:190"]] of Array(String),
          [] of Array(String),
        ] of Array(Array(String)),
        [
          [] of Array(String),
          [] of Array(String),
        ] of Array(Array(String)),
      ] of Array(Array(Array(String)))

      full = reader.read_marks(0, reader.mark_count)
      full.map { |mark| w187_array_table_mark_signature(mark) }.should eq(expected)
      reader.read_marks(2, 1).map { |mark| w187_array_table_mark_signature(mark) }.should eq([expected[2]])
      reader.read_marks(reader.mark_count, 0).should be_empty

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      candidate_signatures = [] of Array(Array(Array(String)))
      table.scan_typed_candidate_marks([[0, 1, 2, 3]]) do |batch|
        candidate_signatures << w187_array_table_mark_signature(batch.recursive_values_for("payload").to_a)
      end
      candidate_signatures.should eq(expected)

      middle_signatures = [] of Array(Array(Array(String)))
      table.scan_typed_candidate_marks([[2]]) do |batch|
        middle_signatures << w187_array_table_mark_signature(batch.recursive_values_for("payload").to_a)
      end
      middle_signatures.should eq([expected[2]])

      window_signatures = [] of Array(Array(Array(String)))
      table.scan_typed_window(4_u64, 2) do |batch|
        window_signatures << w187_array_table_mark_signature(batch.recursive_values_for("payload").to_a)
      end
      window_signatures.should eq([expected[2]])

      zero_callbacks = 0
      table.scan_typed_candidate_marks([[] of Int32]) { |_batch| zero_callbacks += 1 }
      zero_callbacks.should eq(0)
    end
  end

  it "preserves all-empty repeated Array children as eight empty parent values" do
    with_w187_array_table_directory do |parent|
      part = File.join(parent, "all_1_1_0")
      schema = w187_array_table_schema
      object_schema = w187_array_table_json_schema
      plans = {"root/tuple[0]/array[0]/array[0]/tuple[0]" => w187_array_table_plan(object_schema)}
      keys = Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64]
      CrystalClick::WidePartWriter.write_uint64_recursive_pair(
        part, "pk", keys, "payload", schema, plans, w187_array_table_empty_granules,
        rows_per_mark: 2,
        mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
        frame_bytes: 64,
      )

      reader = CrystalClick::RecursiveStorageColumnReader.open(part, "payload", schema)
      reader.read_marks(0, reader.mark_count).flatten.map do |row|
        w187_array_table_row_signature(row)
      end.should eq(Array(Array(Array(String))).new(8) { [] of Array(String) })
      reader.read_marks(reader.mark_count, 0).should be_empty
      reader.physical_stream_names.should contain("payload%2Eitems.size0")
      reader.physical_stream_names.should contain("payload%2Eitems.size1")

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      rows = [] of Array(Array(String))
      table.scan_typed_candidate_marks([[0, 1, 2, 3]]) do |batch|
        batch.recursive_values_for("payload").each do |row|
          rows << w187_array_table_row_signature(row)
        end
      end
      rows.should eq(Array(Array(Array(String))).new(8) { [] of Array(String) })
    end
  end

  it "rejects a nested inherited-Q mismatch before any selected batch callback" do
    with_w187_array_table_directory do |parent|
      source = File.join(parent, "all_1_1_0")
      corrupt = File.join(parent, "all_2_2_0")
      schema = w187_array_table_schema
      object_schema = w187_array_table_json_schema
      plans = {"root/tuple[0]/array[0]/array[0]/tuple[0]" => w187_array_table_plan(object_schema)}
      keys = Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64]
      CrystalClick::WidePartWriter.write_uint64_recursive_pair(
        source, "pk", keys, "payload", schema, plans, w187_array_table_granules,
        rows_per_mark: 2,
        mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
        frame_bytes: 64,
      )
      FileUtils.cp_r(source, corrupt)
      w187_array_table_corrupt_outer_q(corrupt)

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([corrupt], ["pk", "payload"])
        table.scan_typed_candidate_marks([[2]]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    end
  end

  it "keeps recursive Array(JSON) outside the narrower offline UInt64 PK-candidate API" do
    with_w187_recursive_catalog do |table|
      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_uint64_pk_candidates(["pk", "payload"], lower_bound: 1_u64) do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)
    end
  end
end
