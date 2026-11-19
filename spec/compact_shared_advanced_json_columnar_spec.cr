require "./spec_helper"
require "file_utils"
require "../scripts/support/compact_physical_context_w259_fixture"

private module CompactJsonColumnarGuardFixture
  extend self

  COLUMN        = "root_json"
  KEY           = "pk"
  SITE          = "root"
  DYNAMIC_PATH  = "payload"
  ROW_COUNT     = 8
  ROWS_PER_MARK = 2
  SHARED_PATHS  = ["alpha", "aa", "beta"] +
                  (0...17).map { |index| "extra_#{index.to_s.rjust(2, '0')}" }.to_a

  def uint64 : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt64")
  end

  def string : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("String")
  end

  def nullable_uint64 : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.nullable(uint64)
  end

  def json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 64,
      max_dynamic_types: 2,
      typed_paths: {
        "id"   => uint64,
        "rank" => nullable_uint64,
      } of String => CrystalClick::BinaryDataType,
    )
  end

  def schema : CrystalClick::StorageColumnSchema
    CrystalClick::CompactJsonColumnAdapter.schema_for_json_declaration(json_type.name) ||
      raise CrystalClick::UnsupportedFormatError.new("columnar guard JSON schema was not admitted")
  end

  def context(shared_version : UInt64) : CrystalClick::CompactJsonWriteContext
    object = CrystalClick::ObjectStructure.new(
      [DYNAMIC_PATH] of String,
      version: 4_u64,
      shared_data_version: shared_version,
      bucket_count: 2_u64,
      statistics: CrystalClick::StructureStatistics.new([2_u64] of UInt64, [] of CrystalClick::StructureStatistic),
    )
    # Canonical Dynamic order is SharedVariant, String, UInt64. Both ordinary
    # arms occur in the first mark, so this is a real two-arm Dynamic witness.
    dynamic = CrystalClick::DynamicStructure.new(
      [string, uint64] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new([0_u64, 1_u64, 1_u64], [] of CrystalClick::StructureStatistic),
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      object,
      {DYNAMIC_PATH => dynamic} of String => CrystalClick::DynamicStructure,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(structures, schema.object_schema.typed_paths)
    CrystalClick::CompactJsonWriteContext.new({SITE => plan} of String => CrystalClick::ObjectDocumentPlan)
  end

  def document(row : Int32, base : UInt64 = 1_u64, replacement : Bool = false) : CrystalClick::ObjectDocument
    seed = replacement ? row + 23 : row
    fields = {
      "id"   => CrystalClick::BinaryValue.uint64(base + row.to_u64),
      "rank" => rank_value(row, replacement),
    } of String => CrystalClick::BinaryValue

    SHARED_PATHS.each_with_index do |path, path_index|
      fields[path] = CrystalClick::BinaryValue.string(shared_value(path, path_index, seed))
    end

    case row % 4
    when 0
      fields[DYNAMIC_PATH] = CrystalClick::BinaryValue.string("text-#{seed.to_s.rjust(2, '0')}")
    when 1
      fields[DYNAMIC_PATH] = CrystalClick::BinaryValue.uint64(70_000_u64 + seed.to_u64)
    when 2
      # The absent cell must remain distinct from the typed rank NULL.
    when 3
      fields[DYNAMIC_PATH] = CrystalClick::BinaryValue.string("tail\0#{seed}")
    end
    CrystalClick::ObjectDocument.new(fields)
  end

  def documents(base : UInt64 = 1_u64, replacement : Bool = false) : Array(CrystalClick::ObjectDocument)
    Array(CrystalClick::ObjectDocument).new(ROW_COUNT) do |row|
      document(row.to_i32, base, replacement)
    end
  end

  def write_part(
    path : String,
    base : UInt64 = 1_u64,
    replacement : Bool = false,
    shared_version : UInt64 = 2_u64,
  ) : String
    rows = documents(base, replacement).map do |document|
      CrystalClick::StorageColumnValue.object_document(document)
    end.to_a
    granules = rows.each_slice(ROWS_PER_MARK).map(&.to_a).to_a
    json_column = CrystalClick::CompactPartColumn.json(COLUMN, schema, granules, context(shared_version))
    keys = Slice(UInt64).new(ROW_COUNT) { |index| base + index.to_u64 }
    CrystalClick::CompactPartWriter.write_uint64_columns(
      path,
      KEY,
      keys,
      [json_column] of CrystalClick::CompactPartColumn,
      rows_per_mark: ROWS_PER_MARK,
      frame_bytes: 4096,
      mark_format: CrystalClick::CompactMarkFormat::Mrk4,
    )
  end

  def expected_rowbinary(
    document : CrystalClick::ObjectDocument,
  ) : Bytes
    entries = [] of Tuple(String, CrystalClick::BinaryValue)
    document.paths.each do |path|
      entries << {path, document.value_for(path)}
    end
    json_rowbinary(entries)
  end

  def rowbinary_from_batch(
    batch : CrystalClick::CompactJsonColumnarBatch,
    row : Int,
  ) : Bytes
    entries = [] of Tuple(String, CrystalClick::BinaryValue)
    batch.column_count.times do |index|
      column = batch.column_at(index)
      value = column.value_at(row)
      next unless value
      entries << {column.path, value}
    end
    json_rowbinary(entries)
  end

  def json_rowbinary(entries : Array(Tuple(String, CrystalClick::BinaryValue))) : Bytes
    output = IO::Memory.new
    json = IO::Memory.new
    json << '{'
    entries.each_with_index do |entry, index|
      json << ',' if index > 0
      JSON::Any.new(entry[0]).to_json(json)
      json << ':'
      write_json_value(json, entry[1])
    end
    json << '}'
    write_varuint(output, json.size.to_u64)
    output.write(json.to_slice)
    output.to_slice
  end

  def write_json_value(io : IO, value : CrystalClick::BinaryValue) : Nil
    return io << "null" if value.is_null?

    case value.type.tag
    when CrystalClick::BinaryDataType::TAG_UINT32
      io << uint32_value(value)
    when CrystalClick::BinaryDataType::TAG_UINT64
      io << value.as_uint64
    when CrystalClick::BinaryDataType::TAG_INT64
      io << value.as_int64
    when CrystalClick::BinaryDataType::TAG_STRING
      JSON::Any.new(value.as_string).to_json(io)
    when CrystalClick::BinaryDataType::TAG_BOOL
      io << (value.as_bool ? "true" : "false")
    when CrystalClick::BinaryDataType::TAG_NULLABLE, CrystalClick::BinaryDataType::TAG_DYNAMIC
      write_json_value(io, value.child_at(0))
    else
      raise CrystalClick::UnsupportedFormatError.new("columnar guard cannot serialize JSON leaf #{value.type.name}")
    end
    nil
  end

  def uint32_value(value : CrystalClick::BinaryValue) : UInt32
    unless value.type.tag == CrystalClick::BinaryDataType::TAG_UINT32 && value.byte_size == 4
      raise CrystalClick::UnsupportedFormatError.new("columnar guard expected UInt32 JSON leaf")
    end
    result = 0_u32
    4.times { |index| result |= value.byte_at(index).to_u32 << (index * 8) }
    result
  end

  def write_varuint(io : IO, value : UInt64) : Nil
    remaining = value
    while remaining >= 0x80_u64
      io.write_byte((remaining & 0x7f_u64).to_u8 | 0x80_u8)
      remaining >>= 7
    end
    io.write_byte(remaining.to_u8)
    nil
  end

  def rank_value(row : Int32, replacement : Bool) : CrystalClick::BinaryValue
    type = nullable_uint64
    return CrystalClick::BinaryValue.nullable(type) if row == 1
    scalar = CrystalClick::BinaryValue.uint64((row + (replacement ? 100 : 10)).to_u64)
    CrystalClick::BinaryValue.nullable(type, scalar)
  end

  private def shared_value(path : String, path_index : Int32, seed : Int32) : String
    return "" if path == "alpha" && seed == 0
    return "long:" + ("x" * 256) if path == "alpha" && seed == 3
    return "bytes\0with\0nuls" if path == "aa" && seed == 1
    return "shared\0nul" if path == "beta" && seed == 5
    "#{path}:#{path_index}:#{seed}"
  end
end

private def cjcv_copy_part_files(source : String, destination : String) : Nil
  Dir.children(source).reject { |name| name == "checksums.txt" }.sort.each do |name|
    target = File.join(destination, name)
    staged = "#{target}.replacement"
    FileUtils.cp(File.join(source, name), staged)
    File.rename(staged, target)
  end
  staged_checksums = File.join(destination, "checksums.txt.replacement")
  FileUtils.cp(File.join(source, "checksums.txt"), staged_checksums)
  File.rename(staged_checksums, File.join(destination, "checksums.txt"))
end

private def cjcv_late_root_frame(part_path : String, mark_index : Int32) : Int32
  physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
  window = physical.read_window(CompactJsonColumnarGuardFixture::COLUMN, mark_index, 1).granules.first
  window.shards.each do |shard|
    first, limit = physical.frame_index.touched_frame_bounds(shard.logical_start, shard.logical_end)
    return first if first < limit
  end
  raise "columnar fixture mark #{mark_index} has no root JSON frame"
end

private def cjcv_scan_rows(
  table : CrystalClick::TypedPartTable,
  workers : Int,
  batch_rows : Int,
  expected_documents : Array(CrystalClick::ObjectDocument),
) : Tuple(Array(UInt64), Array(Bytes), Array(Tuple(Int32, UInt64, UInt64)))
  keys = [] of UInt64
  rowbinary = [] of Bytes
  locations = [] of Tuple(Int32, UInt64, UInt64)
  table.scan_compact_json_columnar(workers: workers, batch_rows: batch_rows) do |batch|
    key_slice = batch.uint64_column(CompactJsonColumnarGuardFixture::KEY)
    key_slice.size.should eq(batch.row_count)
    expected_path_order = (CompactJsonColumnarGuardFixture::SHARED_PATHS + ["id", "payload", "rank"]).sort
    batch.columns.map(&.path).to_a.should eq(expected_path_order)
    batch.column_for("not-in-the-roster").should be_nil
    batch.part_index.should eq(0_i32)
    batch.part_path.empty?.should be_false
    File.basename(batch.part_path).should eq(batch.part_name)
    batch.column_for("id").not_nil!.fallback_type.should eq(CompactJsonColumnarGuardFixture.uint64)
    batch.column_for("rank").not_nil!.fallback_type.should eq(CompactJsonColumnarGuardFixture.nullable_uint64)
    batch.column_count.should be > CrystalClick::WidePartTable::MAX_COLUMNS

    batch.row_count.times do |row|
      key = key_slice[row]
      # The fixture uses one-based adjacent keys, and row order is global.
      first_document_key = expected_documents.first.value_for("id").not_nil!.as_uint64
      document_index = (key - first_document_key).to_i
      document = expected_documents[document_index]

      id_column = batch.column_for("id").not_nil!
      id_value = id_column.value_at(row).not_nil!
      id_column.row_count.should eq(batch.row_count)
      id_value.as_uint64.should eq(document.value_for("id").as_uint64)
      id_column.present_at?(row).should be_true

      rank_column = batch.column_for("rank").not_nil!
      rank_value = rank_column.value_at(row).not_nil!
      rank_column.present_at?(row).should be_true
      rank_column.type_at(row).should eq(CompactJsonColumnarGuardFixture.nullable_uint64)
      rank_column.nullable_at?(row).should be_true
      rank_value.is_null?.should eq(document.value_for("rank").is_null?)

      payload_column = batch.column_for("payload").not_nil!
      payload_column.fallback_type.should be_nil
      expected_payload = document.has_path?("payload") ? document.value_for("payload") : nil
      if expected_payload
        payload_column.present_at?(row).should be_true
        actual_payload = payload_column.value_at(row).not_nil!
        actual_payload.is_null?.should be_false
        payload_column.type_at(row).should eq(expected_payload.type)
        payload_column.nullable_at?(row).should be_false
        # The Dynamic arm is represented by its exact admitted actual value;
        # retaining a Dynamic wrapper here would change the root JSON type.
        actual_payload.type.name.should eq(expected_payload.type.name)
        case expected_payload.type.tag
        when CrystalClick::BinaryDataType::TAG_STRING
          actual_payload.as_string.should eq(expected_payload.as_string)
        when CrystalClick::BinaryDataType::TAG_UINT64
          actual_payload.as_uint64.should eq(expected_payload.as_uint64)
        else
          raise "unexpected Dynamic test value type: #{expected_payload.type.name}"
        end
      else
        payload_column.present_at?(row).should be_false
        payload_column.value_at(row).should be_nil
        payload_column.type_at(row).should be_nil
        payload_column.nullable_at?(row).should be_false
      end

      # The strongest sparse/null discriminator: row 1 has a present typed
      # Nullable NULL; row 2 has an absent Dynamic path.
      if document_index == 1
        rank_value.is_null?.should be_true
        payload_column.present_at?(row).should be_true
      elsif document_index == 2
        payload_column.present_at?(row).should be_false
      end

      rowbinary << CompactJsonColumnarGuardFixture.rowbinary_from_batch(batch, row)
      keys << key
      locations << {batch.mark_index, batch.mark_row_offset, batch.part_row_offset}
      expected_payload_for_row = CompactJsonColumnarGuardFixture.expected_rowbinary(document)
      rowbinary.last.should eq(expected_payload_for_row)
      batch.mark_index.should eq((document_index // CompactJsonColumnarGuardFixture::ROWS_PER_MARK).to_i32)
      (batch.mark_row_offset + row.to_u64).should eq((document_index % CompactJsonColumnarGuardFixture::ROWS_PER_MARK).to_u64)
      (batch.part_row_offset + row.to_u64).should eq(document_index.to_u64)
      (batch.source_row_offset + row.to_u64).should eq(document_index.to_u64)
    end
    expect_raises(IndexError) { batch.column_for("id").not_nil!.value_at(batch.row_count) }
  end
  {keys, rowbinary, locations}
end

describe "Compact shared Advanced root JSON columnar batches" do
  # The writer emits one chunk per row for SharedData v3; v2 uses one chunk per mark.
  [2_u64, 3_u64].each do |shared_version|
    it "emits exact RowBinary and split-relative locations with SharedData v#{shared_version}" do
      parent = File.tempname("compact-json-columnar-value-grid-")
      part = File.join(parent, "all_1_1_0")
      begin
        Dir.mkdir(parent)
        CompactJsonColumnarGuardFixture.write_part(part, shared_version: shared_version)
        table = CrystalClick::TypedPartTable.open_selected_typed(
          [part],
          [CompactJsonColumnarGuardFixture::KEY, CompactJsonColumnarGuardFixture::COLUMN],
        )
        expected_documents = CompactJsonColumnarGuardFixture.documents
        expected_keys = (1_u64..CompactJsonColumnarGuardFixture::ROW_COUNT.to_u64).to_a
        expected_locations = (0...CompactJsonColumnarGuardFixture::ROW_COUNT).map do |row|
          {(row // CompactJsonColumnarGuardFixture::ROWS_PER_MARK).to_i32,
           (row % CompactJsonColumnarGuardFixture::ROWS_PER_MARK).to_u64,
           row.to_u64}
        end

        serial_keys, serial_json, serial_locations = cjcv_scan_rows(table, 1, 1, expected_documents)
        serial_keys.should eq(expected_keys)
        serial_json.should eq(expected_documents.map { |document| CompactJsonColumnarGuardFixture.expected_rowbinary(document) })
        serial_locations.should eq(expected_locations)

        parallel_keys, parallel_json, parallel_locations = cjcv_scan_rows(table, 4, 1, expected_documents)
        parallel_keys.should eq(serial_keys)
        parallel_json.should eq(serial_json)
        parallel_locations.should eq(serial_locations)

        # Two rows per mark, so batch_rows larger than one proves one callback
        # window can contain the complete mark and preserve its row order.
        whole_mark_keys, whole_mark_json, whole_mark_locations = cjcv_scan_rows(table, 4, 2, expected_documents)
        whole_mark_keys.should eq(serial_keys)
        whole_mark_json.should eq(serial_json)
        whole_mark_locations.should eq((0...CompactJsonColumnarGuardFixture::ROW_COUNT).map do |row|
          {(row // CompactJsonColumnarGuardFixture::ROWS_PER_MARK).to_i32,
           0_u64,
           (row // CompactJsonColumnarGuardFixture::ROWS_PER_MARK).to_u64 * CompactJsonColumnarGuardFixture::ROWS_PER_MARK.to_u64}
        end)
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "reuses one borrowed batch and column wrapper while a snapshot survives later windows" do
    parent = File.tempname("compact-json-columnar-snapshot-")
    part = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      CompactJsonColumnarGuardFixture.write_part(part)
      table = CrystalClick::TypedPartTable.open_selected_typed(
        [part],
        [CompactJsonColumnarGuardFixture::KEY, CompactJsonColumnarGuardFixture::COLUMN],
      )
      borrowed = nil.as(CrystalClick::CompactJsonColumnarBatch?)
      borrowed_id_column = nil.as(CrystalClick::CompactJsonColumnarColumn?)
      owned = nil.as(CrystalClick::CompactJsonColumnarBatch?)
      borrowed_snapshots = [] of Bytes
      callbacks = 0
      table.scan_compact_json_columnar(workers: 1, batch_rows: 1) do |batch|
        callbacks += 1
        if callbacks == 1
          borrowed = batch
          borrowed_id_column = batch.column_for("id")
          owned = batch.snapshot
          borrowed_snapshots << CompactJsonColumnarGuardFixture.rowbinary_from_batch(owned.not_nil!, 0)
        else
          batch.same?(borrowed.not_nil!).should be_true
          batch.column_for("id").not_nil!.same?(borrowed_id_column.not_nil!).should be_true
        end
        batch.row_count.should eq(1)
        batch.part_row_offset.should eq((callbacks - 1).to_u64)
        batch.mark_row_offset.should eq(((callbacks - 1) % CompactJsonColumnarGuardFixture::ROWS_PER_MARK).to_u64)
        batch.uint64_column(CompactJsonColumnarGuardFixture::KEY).to_a.should eq([callbacks.to_u64])
      end
      callbacks.should eq(CompactJsonColumnarGuardFixture::ROW_COUNT)
      borrowed_snapshots.first.should eq(CompactJsonColumnarGuardFixture.expected_rowbinary(CompactJsonColumnarGuardFixture.document(0)))
      owned.not_nil!.part_row_offset.should eq(0_u64)
      owned.not_nil!.uint64_column(CompactJsonColumnarGuardFixture::KEY).should eq(Slice[1_u64])
      CompactJsonColumnarGuardFixture.rowbinary_from_batch(owned.not_nil!, 0).should eq(borrowed_snapshots.first)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "authenticates the whole selected grid before callbacks and retries cleanly" do
    parent = File.tempname("compact-json-columnar-grid-preflight-")
    part = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      CompactJsonColumnarGuardFixture.write_part(part)
      table = CrystalClick::TypedPartTable.open_selected_typed(
        [part],
        [CompactJsonColumnarGuardFixture::KEY, CompactJsonColumnarGuardFixture::COLUMN],
      )
      frame = cjcv_late_root_frame(part, 3_i32)
      CompactPhysicalContextW259Fixture.corrupt_frame_payload(part, frame)
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_compact_json_columnar(workers: 4, batch_rows: 1) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)

      FileUtils.rm_rf(part)
      CompactJsonColumnarGuardFixture.write_part(part)
      reopened = CrystalClick::TypedPartTable.open_selected_typed(
        [part],
        [CompactJsonColumnarGuardFixture::KEY, CompactJsonColumnarGuardFixture::COLUMN],
      )
      keys, actual, _locations = cjcv_scan_rows(
        reopened,
        1,
        1,
        CompactJsonColumnarGuardFixture.documents,
      )
      keys.should eq((1_u64..CompactJsonColumnarGuardFixture::ROW_COUNT.to_u64).to_a)
      actual.should eq(CompactJsonColumnarGuardFixture.documents.map do |document|
        CompactJsonColumnarGuardFixture.expected_rowbinary(document)
      end)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects an output workspace budget before the first callback" do
    parent = File.tempname("compact-json-columnar-workspace-preflight-")
    part = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      CompactJsonColumnarGuardFixture.write_part(part)
      table = CrystalClick::TypedPartTable.open_selected_typed(
        [part],
        [CompactJsonColumnarGuardFixture::KEY, CompactJsonColumnarGuardFixture::COLUMN],
      )
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_compact_json_columnar(
          workers: 4,
          batch_rows: 1,
          workspace_limit: 1_u64,
        ) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps sparse column high-water slots charged across a disjoint reset" do
    batch = CrystalClick::CompactJsonColumnarBatch.from_layout(
      ["path-a", "path-b"],
      ["pk"],
      {} of String => CrystalClick::BinaryDataType,
      4,
      8_u64,
    )
    empty_workspace = batch.retained_workspace_bytes

    batch.begin_mark!(0, "part", "/part", 0, 0_u64, 0_u64, 0_u64, 4_u64)
    4.times do |row|
      batch.append_value!("path-a", row, CrystalClick::BinaryValue.string("a#{row}"))
    end
    first_companion = Bytes.new(32) do |index|
      value = (index // 8 + 1).to_u64
      ((value >> ((index % 8) * 8)) & 0xff_u64).to_u8
    end
    batch.fill_uint64_column!("pk", first_companion, 4_u64)
    batch.uint64_column("pk").to_a.should eq([1_u64, 2_u64, 3_u64, 4_u64])
    batch.reset!
    after_reset = batch.retained_workspace_bytes
    slot_bytes = sizeof(Int32).to_u64 + sizeof(CrystalClick::CompactJsonColumnarCell).to_u64
    companion_slot_bytes = 4_u64 * sizeof(UInt64).to_u64
    (after_reset - empty_workspace).should eq(4_u64 * slot_bytes + companion_slot_bytes)

    batch.begin_mark!(0, "part", "/part", 1, 0_u64, 4_u64, 4_u64, 2_u64)
    2.times do |row|
      batch.append_value!("path-b", row, CrystalClick::BinaryValue.string("b#{row}"))
    end
    second_companion = Bytes.new(16) do |index|
      value = (index // 8 + 5).to_u64
      ((value >> ((index % 8) * 8)) & 0xff_u64).to_u8
    end
    batch.fill_uint64_column!("pk", second_companion, 2_u64)
    batch.uint64_column("pk").to_a.should eq([5_u64, 6_u64])
    batch.column_for("path-a").not_nil!.present_at?(0).should be_false
    batch.column_for("path-a").not_nil!.present_at?(1).should be_false
    batch.column_for("path-b").not_nil!.present_at?(0).should be_true
    batch.column_for("path-b").not_nil!.present_at?(1).should be_true
    batch.retained_workspace_bytes.should be > after_reset
  end

  it "rejects a valid same-path replacement between split callbacks and reopens its values" do
    parent = File.tempname("compact-json-columnar-replacement-")
    part = File.join(parent, "all_1_1_0")
    replacement = File.join(parent, "replacement_1_1_0")
    begin
      Dir.mkdir(parent)
      CompactJsonColumnarGuardFixture.write_part(part)
      CompactJsonColumnarGuardFixture.write_part(replacement, 10_001_u64, true)
      [1, 2].each do |batch_rows|
        FileUtils.rm_rf(part)
        CompactJsonColumnarGuardFixture.write_part(part)
        callbacks = 0
        expect_raises(CrystalClick::CorruptPartError) do
          table = CrystalClick::TypedPartTable.open_selected_typed(
            [part],
            [CompactJsonColumnarGuardFixture::KEY, CompactJsonColumnarGuardFixture::COLUMN],
          )
          table.scan_compact_json_columnar(workers: 4, batch_rows: batch_rows) do |_batch|
            callbacks += 1
            cjcv_copy_part_files(replacement, part) if callbacks == 1
          end
        end
        callbacks.should eq(1)
      end

      reopened = CrystalClick::TypedPartTable.open_selected_typed(
        [part],
        [CompactJsonColumnarGuardFixture::KEY, CompactJsonColumnarGuardFixture::COLUMN],
      )
      keys, actual, _locations = cjcv_scan_rows(
        reopened,
        4,
        1,
        CompactJsonColumnarGuardFixture.documents(10_001_u64, true),
      )
      keys.should eq((10_001_u64..(10_001_u64 + CompactJsonColumnarGuardFixture::ROW_COUNT.to_u64 - 1_u64)).to_a)
      actual.should eq(CompactJsonColumnarGuardFixture.documents(10_001_u64, true).map do |document|
        CompactJsonColumnarGuardFixture.expected_rowbinary(document)
      end)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "allows a nested scan and a later clean retry" do
    parent = File.tempname("compact-json-columnar-nested-")
    part = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      CompactJsonColumnarGuardFixture.write_part(part)
      table = CrystalClick::TypedPartTable.open_selected_typed(
        [part],
        [CompactJsonColumnarGuardFixture::KEY, CompactJsonColumnarGuardFixture::COLUMN],
      )
      outer_keys = [] of UInt64
      nested_keys = [] of UInt64
      table.scan_compact_json_columnar(workers: 1, batch_rows: 1) do |batch|
        batch.uint64_column(CompactJsonColumnarGuardFixture::KEY).each do |key|
          outer_keys << key
        end
        if outer_keys.size == 1
          table.scan_compact_json_columnar(workers: 1, batch_rows: 2) do |nested|
            nested_keys.concat(nested.uint64_column(CompactJsonColumnarGuardFixture::KEY).to_a)
          end
        end
      end
      expected = (1_u64..CompactJsonColumnarGuardFixture::ROW_COUNT.to_u64).to_a
      outer_keys.should eq(expected)
      nested_keys.should eq(expected)

      retry_keys = [] of UInt64
      table.scan_compact_json_columnar(workers: 4, batch_rows: 1) do |batch|
        retry_keys.concat(batch.uint64_column(CompactJsonColumnarGuardFixture::KEY).to_a)
      end
      retry_keys.should eq(expected)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "cleans up parallel workers after a callback raises and allows the same table to rescan" do
    parent = File.tempname("compact-json-columnar-callback-error-")
    part = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      CompactJsonColumnarGuardFixture.write_part(part)
      table = CrystalClick::TypedPartTable.open_selected_typed(
        [part],
        [CompactJsonColumnarGuardFixture::KEY, CompactJsonColumnarGuardFixture::COLUMN],
      )
      callbacks = 0
      expect_raises(ArgumentError) do
        table.scan_compact_json_columnar(workers: 4, batch_rows: 1) do |_batch|
          callbacks += 1
          raise ArgumentError.new("intentional callback failure")
        end
      end
      callbacks.should eq(1)

      keys = [] of UInt64
      table.scan_compact_json_columnar(workers: 4, batch_rows: 1) do |batch|
        keys.concat(batch.uint64_column(CompactJsonColumnarGuardFixture::KEY).to_a)
      end
      keys.should eq((1_u64..CompactJsonColumnarGuardFixture::ROW_COUNT.to_u64).to_a)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

private def cjcv_official_fixture_probe(part : String, oracle_path : String) : Nil
  table = CrystalClick::TypedPartTable.open_selected_typed([part], ["id", "doc"])
  table.column_types.any? { |name, type| name == "doc" && type.starts_with?("JSON(") }.should be_true
  expected_rowbinary = File.read(oracle_path)
  expected_bytes = expected_rowbinary.to_slice
  expected_rows = File.read(File.join(part, "count.txt")).strip.to_u64

  [1, 4].each do |workers|
    actual_bytes = IO::Memory.new
    observed_ids = [] of UInt64
    observed_documents = 0_u64
    table.scan_compact_json_columnar(workers: workers, batch_rows: 128) do |batch|
      ids = batch.uint64_column("id")
      ids.size.should eq(batch.row_count)
      batch.row_count.times do |row|
        id = ids[row]
        observed_ids << id
        observed_documents += 1_u64
        actual_bytes.write_bytes(id, IO::ByteFormat::LittleEndian)
        actual_bytes.write(CompactJsonColumnarGuardFixture.rowbinary_from_batch(batch, row))
      end
    end
    observed_documents.should eq(expected_rows)
    observed_ids.size.to_u64.should eq(expected_rows)
    observed_ids.each_with_index do |id, index|
      id.should eq(index.to_u64)
    end
    actual = actual_bytes.to_slice
    unless actual == expected_bytes
      mismatch = 0
      limit = Math.min(actual.size, expected_bytes.size)
      while mismatch < limit && actual[mismatch] == expected_bytes[mismatch]
        mismatch += 1
      end
      actual_byte = mismatch < actual.size ? actual[mismatch] : nil
      expected_byte = mismatch < expected_bytes.size ? expected_bytes[mismatch] : nil
      raise "official RowBinary mismatch at byte #{mismatch}: actual=#{actual_byte.inspect} expected=#{expected_byte.inspect}; actual_size=#{actual.size} expected_size=#{expected_bytes.size}"
    end
  end
  nil
end

if fixture_root = ENV["CRYSTAL_CLICK_COLUMNAR_JSON_FIXTURE_ROOT"]?
  describe "official Compact JSON columnar fixture parity" do
    {"fixture", "overflow-fixture"}.each do |directory|
      it "matches the pinned RowBinary oracle and id/doc order for #{directory}" do
        part = File.join(fixture_root, directory, "0_1_1_0")
        oracle = File.join(fixture_root, directory, "0_1_1_0.rowbinary")
        cjcv_official_fixture_probe(part, oracle)
      end
    end
  end
end
