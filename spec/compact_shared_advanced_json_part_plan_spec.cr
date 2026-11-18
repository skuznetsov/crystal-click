require "./spec_helper"
require "file_utils"
require "../scripts/support/compact_physical_context_w259_fixture"
require "./support/compact_part_writer_w278_fixture"

private def cjpp_write_part(
  part_path : String,
  first_key : UInt64 = 1_u64,
  replacement_documents : Bool = false,
) : Nil
  fixture = CompactPartWriterW278Fixture
  keys = Slice(UInt64).new(CompactPartWriterW278Fixture::ROW_COUNT) { |index| first_key + index.to_u64 }
  column = if replacement_documents
             cjpp_replacement_json_column
           else
             fixture.column(CompactPartWriterW278Fixture::ROOT_COLUMN, 2_u64)
           end
  CrystalClick::CompactPartWriter.write_uint64_columns(
    part_path,
    CompactPartWriterW278Fixture::KEY_NAME,
    keys,
    [column] of CrystalClick::CompactPartColumn,
    rows_per_mark: CompactPartWriterW278Fixture::ROWS_PER_MARK,
    frame_bytes: CompactPartWriterW278Fixture::FRAME_BYTES,
    mark_format: CrystalClick::CompactMarkFormat::Mrk4,
  ).should eq(part_path)
  nil
end

private def cjpp_replacement_json_column : CrystalClick::CompactPartColumn
  fixture = CompactPartWriterW278Fixture
  rows = Array(CrystalClick::StorageColumnValue).new(CompactPartWriterW278Fixture::ROW_COUNT)
  fixture.root_rows.each_with_index do |row, row_index|
    rows << CrystalClick::StorageColumnValue.object_document(
      cjpp_replacement_document(row.object_document, row_index),
    )
  end

  object = CrystalClick::ObjectStructure.new(
    ["payload"] of String,
    version: 4_u64,
    shared_data_version: 2_u64,
    bucket_count: 2_u64,
    statistics: CrystalClick::StructureStatistics.new([2_u64] of UInt64, [] of CrystalClick::StructureStatistic),
  )
  dynamic = CrystalClick::DynamicStructure.new(
    [fixture.string_type] of CrystalClick::BinaryDataType,
    CrystalClick::StructureStatistics.new([0_u64, 1_u64] of UInt64, [] of CrystalClick::StructureStatistic),
    version: CrystalClick::DynamicStructure::VERSION_V3,
  )
  structures = CrystalClick::ObjectDynamicStructureSet.new(
    object,
    {"payload" => dynamic} of String => CrystalClick::DynamicStructure,
  )
  plan = CrystalClick::ObjectDocumentPlan.new(structures, fixture.json_schema.object_schema.typed_paths)
  context = CrystalClick::CompactJsonWriteContext.new(
    {CompactPartWriterW278Fixture::ROOT_SITE => plan} of String => CrystalClick::ObjectDocumentPlan,
  )
  granules = rows.each_slice(CompactPartWriterW278Fixture::ROWS_PER_MARK).map(&.to_a).to_a
  CrystalClick::CompactPartColumn.json(CompactPartWriterW278Fixture::ROOT_COLUMN, fixture.json_schema, granules, context)
end

private def cjpp_replacement_document(
  base : CrystalClick::ObjectDocument,
  row_index : Int32,
) : CrystalClick::ObjectDocument
  fields = Hash(String, CrystalClick::BinaryValue).new
  fields["id"] = CrystalClick::BinaryValue.uint64(10_000_u64 + row_index.to_u64)
  fields["label"] = CrystalClick::BinaryValue.string(
    cjpp_replacement_text(base.value_for("label").as_string, row_index + 1),
  )
  {"alpha", "aa", "beta"}.each_with_index do |path, path_index|
    fields[path] = CrystalClick::BinaryValue.string(
      cjpp_replacement_text(base.value_for(path).as_string, row_index + path_index + 2),
    )
  end
  # Preserve each string byte length and the Dynamic presence/type grid while
  # changing the authenticated source values under the same schema and marks.
  fields["payload"] = base.value_for("payload") if base.has_path?("payload")
  CrystalClick::ObjectDocument.new(fields)
end

private def cjpp_replacement_text(original : String, seed : Int32) : String
  String.new(Bytes.new(original.bytesize) do |index|
    ('A'.ord + (seed + index) % 26).to_u8
  end)
end

private def cjpp_document_signature(document : CrystalClick::ObjectDocument) : String
  String.build do |io|
    document.paths.each do |path|
      value = document.value_for(path)
      io << path.bytesize << ':' << path << '=' << value.type.name << ':'
      case value.type.tag
      when CrystalClick::BinaryDataType::TAG_STRING
        text = value.as_string
        io << text.bytesize << ':' << text
      when CrystalClick::BinaryDataType::TAG_UINT64
        io << value.as_uint64
      when CrystalClick::BinaryDataType::TAG_DYNAMIC
        if value.is_null?
          io << "null"
        else
          raise "W278 Dynamic fixture value has an unexpected child count" unless value.element_count == 1
          child = value.element_at(0)
          io << child.type.name << ':'
          if child.type.tag == CrystalClick::BinaryDataType::TAG_STRING
            text = child.as_string
            io << text.bytesize << ':' << text
          else
            io << child.bytes.hexstring
          end
        end
      else
        io << value.bytes.hexstring
      end
      io << ';'
    end
  end
end

private def cjpp_expected_rows(first_key : UInt64, replacement_documents : Bool = false) : Array(Tuple(UInt64, String))
  documents = if replacement_documents
                # Reuse the exact column builder's logical input to keep the
                # oracle independent of the storage read path.
                cjpp_replacement_documents
              else
                CompactPartWriterW278Fixture.root_rows.map(&.object_document)
              end
  documents.each_with_index.map do |document, index|
    {first_key + index.to_u64, cjpp_document_signature(document)}
  end.to_a
end

private def cjpp_replacement_documents : Array(CrystalClick::ObjectDocument)
  fixture = CompactPartWriterW278Fixture
  fixture.root_rows.each_with_index.map do |row, row_index|
    cjpp_replacement_document(row.object_document, row_index)
  end.to_a
end

private def cjpp_scan(
  table : CrystalClick::TypedPartTable,
  workers : Int,
  batch_rows : Int = 1,
) : Tuple(Array(Tuple(UInt64, String)), Array(Tuple(Int32, UInt64, UInt64)))
  rows = [] of Tuple(UInt64, String)
  locations = [] of Tuple(Int32, UInt64, UInt64)
  table.scan_typed_parallel(workers, batch_rows: batch_rows) do |batch|
    keys = batch.values_for(CompactPartWriterW278Fixture::KEY_NAME)
    documents = batch.object_documents_for(CompactPartWriterW278Fixture::ROOT_COLUMN)
    keys.size.should eq(documents.size)
    documents.each_with_index do |document, index|
      rows << {keys[index], cjpp_document_signature(document)}
      locations << {batch.mark_index, batch.mark_row_offset, batch.part_row_offset}
    end
  end
  {rows, locations}
end

private def cjpp_frame_for(part_path : String, column : String, mark_index : Int32) : Int32
  physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
  granule = physical.read_window(column, mark_index, 1).granules.first
  granule.shards.each do |shard|
    first, limit = physical.frame_index.touched_frame_bounds(shard.logical_start, shard.logical_end)
    return first if first < limit
  end
  raise "W278 fixture has no compressed frame for #{column} mark #{mark_index}"
end

private def cjpp_flip_compressed_checksum_byte(part_path : String, frame_index : Int32) : Nil
  path = File.join(part_path, "data.bin")
  data = writable_file_bytes(path)
  offset = 0
  frame = 0
  while frame < frame_index
    size_offset = offset + CrystalClick::CompressedBlock::CHECKSUM_SIZE + 1
    compressed_size = 0_u32
    4.times do |index|
      compressed_size |= data[size_offset + index].to_u32 << (index * 8)
    end
    offset += CrystalClick::CompressedBlock::CHECKSUM_SIZE + compressed_size.to_i
    frame += 1
  end
  raise "W278 frame index is outside data.bin" if offset >= data.size
  data[offset] ^= 0x01_u8
  File.write(path, data)
  nil
end

private def cjpp_flip_compressed_payload_byte(part_path : String, frame_index : Int32, rehash : Bool) : Nil
  path = File.join(part_path, "data.bin")
  data = writable_file_bytes(path)
  offset = 0
  frame = 0
  while frame < frame_index
    size_offset = offset + CrystalClick::CompressedBlock::CHECKSUM_SIZE + 1
    compressed_size = 0_u32
    4.times do |index|
      compressed_size |= data[size_offset + index].to_u32 << (index * 8)
    end
    offset += CrystalClick::CompressedBlock::CHECKSUM_SIZE + compressed_size.to_i
    frame += 1
  end
  raise "W278 frame index is outside data.bin" if offset >= data.size
  payload_offset = offset + CrystalClick::CompressedBlock::FRAME_HEADER_SIZE
  raise "W278 frame has no compressed payload" if payload_offset >= data.size
  data[payload_offset] ^= 0x01_u8

  if rehash
    header_offset = offset + CrystalClick::CompressedBlock::CHECKSUM_SIZE
    compressed_size = 0_u32
    4.times do |index|
      compressed_size |= data[header_offset + 1 + index].to_u32 << (index * 8)
    end
    digest = CrystalClick::CityHashV1.hash128(data[header_offset, compressed_size.to_i])
    CompactPhysicalContextW259Fixture.write_u64(data, offset, digest[0])
    CompactPhysicalContextW259Fixture.write_u64(data, offset + 8, digest[1])
  end
  # Leave checksums.txt untouched so post-callback guards must authenticate
  # the captured compressed frame itself, not merely notice changed metadata.
  File.write(path, data)
  nil
end

private def cjpp_replace_file(source : String, destination : String) : Nil
  staged = "#{destination}.replacement"
  FileUtils.cp(source, staged)
  File.rename(staged, destination)
end

private def cjpp_replace_part_files(source_part : String, destination_part : String) : Nil
  names = Dir.children(source_part).reject { |name| name == "checksums.txt" }.sort
  names.each do |name|
    cjpp_replace_file(File.join(source_part, name), File.join(destination_part, name))
  end
  # Publish the matching manifest last so the callback boundary observes one
  # complete, internally checksummed replacement.
  cjpp_replace_file(
    File.join(source_part, "checksums.txt"),
    File.join(destination_part, "checksums.txt"),
  )
end

describe "Compact shared Advanced root JSON part plan" do
  it "replays one complete plan receipt into independent bounded request budgets" do
    parent = File.tempname("crystal-click-compact-shared-plan-receipt-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      cjpp_write_part(part_path)
      reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
        part_path,
        CompactPartWriterW278Fixture::ROOT_COLUMN,
        CompactPartWriterW278Fixture.json_type,
      )

      workspace_peak = 0_u64
      workspace_limit = CrystalClick::WidePartTable::MAX_MARK_MATERIALIZED_BYTES.to_u64
      observe_workspace = ->(bytes : UInt64) do
        workspace_peak = bytes if bytes > workspace_peak
        raise CrystalClick::CorruptPartError.new("Compact shared plan test exceeded its workspace bound") if bytes > workspace_limit
        nil
      end
      plan = reader.prepare_advanced_part_plan(
        observe_workspace,
        [CompactPartWriterW278Fixture::KEY_NAME],
      ).not_nil!

      plan.mark_count.should eq(reader.mark_count)
      plan.prepared_mark_count.should eq(reader.mark_count)
      plan.retained_workspace_bytes.should be > 0_u64
      workspace_peak.should be <= workspace_limit
      reader.prepared_advanced_context.should be_nil
      reader.mark_row_counts.each_with_index do |rows, mark_index|
        plan.mark_row_count_at(mark_index).should eq(rows)
        plan.uint64_mark_bytes(CompactPartWriterW278Fixture::KEY_NAME, mark_index).size.to_u64
          .should eq(rows * sizeof(UInt64).to_u64)
      end

      limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
      missing_receipt = CrystalClick::BinaryCodecBudget.new(limits)
      expect_raises(ArgumentError) do
        plan.decode_mark_with_budget(0, missing_receipt)
      end
      {missing_receipt.node_count, missing_receipt.element_count, missing_receipt.wire_byte_count}
        .should eq({0_i64, 0_i64, 0_i64})

      first_budget = CrystalClick::BinaryCodecBudget.new(limits)
      second_budget = CrystalClick::BinaryCodecBudget.new(limits)
      plan.replay_preparation_budget!(first_budget)
      first_receipt_counts = {first_budget.node_count, first_budget.element_count, first_budget.wire_byte_count}
      first_receipt_counts[0].should be > 0_i64
      plan.replay_preparation_budget!(first_budget)
      {first_budget.node_count, first_budget.element_count, first_budget.wire_byte_count}
        .should eq(first_receipt_counts)

      plan.replay_preparation_budget!(second_budget)
      second_receipt_counts = {second_budget.node_count, second_budget.element_count, second_budget.wire_byte_count}
      second_receipt_counts.should eq(first_receipt_counts)
      first_bytes = plan.uint64_mark_bytes(CompactPartWriterW278Fixture::KEY_NAME, 0)
      first_bytes[0] ^= 0x01_u8
      plan.uint64_mark_bytes(CompactPartWriterW278Fixture::KEY_NAME, 0).should_not eq(first_bytes)

      expected = cjpp_expected_rows(1_u64).first(CompactPartWriterW278Fixture::ROWS_PER_MARK).map { |row| row[1] }
      first_documents = plan.decode_mark_with_budget(0, first_budget)
      first_documents.map { |document| cjpp_document_signature(document) }.should eq(expected)
      {second_budget.node_count, second_budget.element_count, second_budget.wire_byte_count}
        .should eq(second_receipt_counts)

      near_limit = CrystalClick::BinaryCodecBudget.new(limits)
      near_limit.charge_elements(limits.max_elements.to_u64)
      before_failed_replay = {near_limit.node_count, near_limit.element_count, near_limit.wire_byte_count}
      expect_raises(CrystalClick::CorruptPartError) do
        plan.replay_preparation_budget!(near_limit)
      end
      {near_limit.node_count, near_limit.element_count, near_limit.wire_byte_count}
        .should eq(before_failed_replay)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "reads every root JSON row identically through serial, W1 and W4 split batches" do
    parent = File.tempname("crystal-click-compact-shared-plan-read-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      cjpp_write_part(part_path)
      table = CrystalClick::TypedPartTable.open_selected_typed(
        [part_path],
        [CompactPartWriterW278Fixture::KEY_NAME, CompactPartWriterW278Fixture::ROOT_COLUMN],
      )
      expected = cjpp_expected_rows(1_u64)

      serial = [] of Tuple(UInt64, String)
      table.scan_typed(batch_rows: 1) do |batch|
        keys = batch.values_for(CompactPartWriterW278Fixture::KEY_NAME)
        documents = batch.object_documents_for(CompactPartWriterW278Fixture::ROOT_COLUMN)
        keys.size.should eq(documents.size)
        documents.each_with_index do |document, index|
          serial << {keys[index], cjpp_document_signature(document)}
        end
      end
      serial.should eq(expected)

      [1, 4].each do |workers|
        actual, locations = cjpp_scan(table, workers)
        actual.should eq(expected)
        locations.should eq((0...CompactPartWriterW278Fixture::ROW_COUNT).map do |row|
          {(row // CompactPartWriterW278Fixture::ROWS_PER_MARK).to_i32,
           (row % CompactPartWriterW278Fixture::ROWS_PER_MARK).to_u64,
           row.to_u64}
        end)
      end

      empty_callbacks = 0
      table.scan_typed_candidate_marks([[] of Int32]) { |_batch| empty_callbacks += 1 }
      empty_callbacks.should eq(0)
      retry_rows, _retry_locations = cjpp_scan(table, 1)
      retry_rows.should eq(expected)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a damaged late root JSON mark before the first worker callback" do
    parent = File.tempname("crystal-click-compact-shared-plan-late-mark-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      cjpp_write_part(part_path)
      table = CrystalClick::TypedPartTable.open_selected_typed(
        [part_path],
        [CompactPartWriterW278Fixture::KEY_NAME, CompactPartWriterW278Fixture::ROOT_COLUMN],
      )
      frame = cjpp_frame_for(part_path, CompactPartWriterW278Fixture::ROOT_COLUMN, 3_i32)
      CompactPhysicalContextW259Fixture.corrupt_frame_payload(part_path, frame)

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed_parallel(4, batch_rows: 1) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a damaged later part before any multipart callback" do
    parent = File.tempname("crystal-click-compact-shared-plan-late-part-")
    first_part = File.join(parent, "all_1_1_0")
    second_part = File.join(parent, "all_2_2_0")
    begin
      Dir.mkdir(parent)
      cjpp_write_part(first_part, 1_u64)
      cjpp_write_part(second_part, 101_u64)
      table = CrystalClick::TypedPartTable.open_selected_typed(
        [first_part, second_part],
        [CompactPartWriterW278Fixture::KEY_NAME, CompactPartWriterW278Fixture::ROOT_COLUMN],
      )
      frame = cjpp_frame_for(second_part, CompactPartWriterW278Fixture::ROOT_COLUMN, 3_i32)
      CompactPhysicalContextW259Fixture.corrupt_frame_payload(second_part, frame)

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed_parallel(4, batch_rows: 1) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "revalidates damaged and validly rehashed frame changes within one mark" do
    [1, 4].each do |workers|
      [:checksum, :payload, :rehash_payload].each do |mutation|
        parent = File.tempname("crystal-click-compact-shared-plan-between-batches-")
        part_path = File.join(parent, "all_1_1_0")
        begin
          Dir.mkdir(parent)
          cjpp_write_part(part_path)
          table = CrystalClick::TypedPartTable.open_selected_typed(
            [part_path],
            [CompactPartWriterW278Fixture::KEY_NAME, CompactPartWriterW278Fixture::ROOT_COLUMN],
          )
          frame = cjpp_frame_for(part_path, CompactPartWriterW278Fixture::ROOT_COLUMN, 0_i32)

          callbacks = 0
          message = mutation == :rehash_payload ? /checksum/ : /checksum mismatch/
          expect_raises(CrystalClick::CorruptPartError, message) do
            table.scan_typed_parallel(workers, batch_rows: 1) do |_batch|
              callbacks += 1
              if callbacks == 1
                case mutation
                when :checksum
                  cjpp_flip_compressed_checksum_byte(part_path, frame)
                when :payload
                  cjpp_flip_compressed_payload_byte(part_path, frame, false)
                when :rehash_payload
                  cjpp_flip_compressed_payload_byte(part_path, frame, true)
                end
              end
            end
          end
          callbacks.should eq(1)
        ensure
          FileUtils.rm_rf(parent)
        end
      end
    end
  end

  it "revalidates a selected UInt64 frame after a callback" do
    [1, 4].each do |workers|
      parent = File.tempname("crystal-click-compact-shared-plan-uint64-frame-")
      part_path = File.join(parent, "all_1_1_0")
      begin
        Dir.mkdir(parent)
        cjpp_write_part(part_path)
        table = CrystalClick::TypedPartTable.open_selected_typed(
          [part_path],
          [CompactPartWriterW278Fixture::KEY_NAME, CompactPartWriterW278Fixture::ROOT_COLUMN],
        )
        frame = cjpp_frame_for(part_path, CompactPartWriterW278Fixture::KEY_NAME, 0_i32)

        callbacks = 0
        expect_raises(CrystalClick::CorruptPartError) do
          table.scan_typed_parallel(workers, batch_rows: 1) do |_batch|
            callbacks += 1
            CompactPhysicalContextW259Fixture.corrupt_frame_payload(part_path, frame) if callbacks == 1
          end
        end
        callbacks.should eq(1)
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "stops before stale batches on a valid same-path replacement and reopens new values" do
    parent = File.tempname("crystal-click-compact-shared-plan-replacement-")
    part_path = File.join(parent, "all_1_1_0")
    replacement_path = File.join(parent, "replacement_1_1_0")
    begin
      Dir.mkdir(parent)
      cjpp_write_part(part_path)
      cjpp_write_part(replacement_path, 1_001_u64, true)
      table = CrystalClick::TypedPartTable.open_selected_typed(
        [part_path],
        [CompactPartWriterW278Fixture::KEY_NAME, CompactPartWriterW278Fixture::ROOT_COLUMN],
      )

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        # One full-mark callback makes the next scheduled delivery belong to
        # another worker, whose prefetched result still reflects the old file.
        table.scan_typed_parallel(4, batch_rows: CompactPartWriterW278Fixture::ROWS_PER_MARK) do |_batch|
          callbacks += 1
          if callbacks == 1
            cjpp_replace_part_files(replacement_path, part_path)
          end
        end
      end
      callbacks.should eq(1)

      reopened = CrystalClick::TypedPartTable.open_selected_typed(
        [part_path],
        [CompactPartWriterW278Fixture::KEY_NAME, CompactPartWriterW278Fixture::ROOT_COLUMN],
      )
      fresh_rows, _fresh_locations = cjpp_scan(reopened, 1)
      fresh_rows.should eq(cjpp_expected_rows(1_001_u64, true))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "allows a nested empty-candidate read and a clean retry after the outer scan" do
    parent = File.tempname("crystal-click-compact-shared-plan-nested-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      cjpp_write_part(part_path)
      table = CrystalClick::TypedPartTable.open_selected_typed(
        [part_path],
        [CompactPartWriterW278Fixture::KEY_NAME, CompactPartWriterW278Fixture::ROOT_COLUMN],
      )
      expected = cjpp_expected_rows(1_u64)
      callbacks = 0
      nested_callbacks = 0
      outer_rows = [] of Tuple(UInt64, String)
      table.scan_typed_parallel(4, batch_rows: 1) do |batch|
        callbacks += 1
        keys = batch.values_for(CompactPartWriterW278Fixture::KEY_NAME)
        documents = batch.object_documents_for(CompactPartWriterW278Fixture::ROOT_COLUMN)
        documents.each_with_index do |document, index|
          outer_rows << {keys[index], cjpp_document_signature(document)}
        end
        if callbacks == 1
          table.scan_typed_candidate_marks([[] of Int32]) { |_nested_batch| nested_callbacks += 1 }
        end
      end
      callbacks.should eq(CompactPartWriterW278Fixture::ROW_COUNT)
      nested_callbacks.should eq(0)
      outer_rows.should eq(expected)

      retry_rows, _retry_locations = cjpp_scan(table, 1)
      retry_rows.should eq(expected)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
