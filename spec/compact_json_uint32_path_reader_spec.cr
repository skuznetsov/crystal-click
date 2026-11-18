require "./spec_helper"
require "../scripts/support/compact_physical_context_w259_fixture"

module CompactJsonUInt32PathReaderSpecFixture
  extend self

  COLUMN_NAME = "doc"
  FIELD_NAME  = "tenant_id"
  SITE_PATH   = "root"
  ROWS        = 4

  def uint32_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt32")
  end

  def uint64_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt64")
  end

  def schema(field_type : CrystalClick::BinaryDataType) : CrystalClick::StorageColumnSchema
    json_type = CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {FIELD_NAME => field_type} of String => CrystalClick::BinaryDataType,
    )
    CrystalClick::CompactJsonColumnAdapter.schema_for_json_declaration(json_type.name) ||
      raise CrystalClick::UnsupportedFormatError.new("test JSON schema was not admitted")
  end

  def context(field_type : CrystalClick::BinaryDataType) : CrystalClick::CompactJsonWriteContext
    object = CrystalClick::ObjectStructure.new(
      [] of String,
      version: 4_u64,
      shared_data_version: 0_u64,
      bucket_count: 1_u64,
      statistics: CrystalClick::StructureStatistics.new(
        [] of UInt64,
        [] of CrystalClick::StructureStatistic,
      ),
    )
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      object,
      Hash(String, CrystalClick::DynamicStructure).new,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(
      structures,
      {FIELD_NAME => field_type} of String => CrystalClick::BinaryDataType,
    )
    CrystalClick::CompactJsonWriteContext.new(
      {SITE_PATH => plan} of String => CrystalClick::ObjectDocumentPlan,
    )
  end

  def fixed_value(type : CrystalClick::BinaryDataType, value : UInt64) : CrystalClick::BinaryValue
    width = type.fixed_width || raise ArgumentError.new("fixture field type is not fixed width")
    bytes = Bytes.new(width) do |index|
      ((value >> (index * 8)) & 0xff_u64).to_u8
    end
    CrystalClick::BinaryValue.fixed(type, bytes)
  end

  def write_part(
    part_path : String,
    field_type : CrystalClick::BinaryDataType = uint32_type,
    mark_format : CrystalClick::CompactMarkFormat = CrystalClick::CompactMarkFormat::Mrk4,
  ) : String
    schema = schema(field_type)
    rows = Array(CrystalClick::StorageColumnValue).new(ROWS)
    ROWS.times do |index|
      document = CrystalClick::ObjectDocument.new(
        {FIELD_NAME => fixed_value(field_type, (index + 11).to_u64)} of String => CrystalClick::BinaryValue,
      )
      rows << CrystalClick::StorageColumnValue.object_document(document)
    end
    granules = [rows[0, 2], rows[2, 2]] of Array(CrystalClick::StorageColumnValue)
    column = CrystalClick::CompactPartColumn.json(
      COLUMN_NAME,
      schema,
      granules,
      context(field_type),
    )
    keys = Slice.new(ROWS) { |index| index.to_u64 + 1_u64 }
    CrystalClick::CompactPartWriter.write_uint64_columns(
      part_path,
      "id",
      keys,
      [column] of CrystalClick::CompactPartColumn,
      rows_per_mark: 2,
      frame_bytes: 64,
      mark_format: mark_format,
    )
  end

  # The selected stream uses two packed UInt32 values in each mark. Native
  # JSON layout and serialization are checked separately against ClickHouse.
  def write_path_fixture(part_path : String) : Nil
    Dir.mkdir(part_path)
    File.write(File.join(part_path, "columns.txt"), "columns format version: 1\n2 columns:\n`id` UInt64\n`doc` #{schema(uint32_type).declaration}\n")
    substreams = CompactPhysicalContextW259Fixture.substreams_text([{"id", ["id"]}, {"doc", ["doc.tenant_id"]}])
    File.write(File.join(part_path, "columns_substreams.txt"), substreams)
    File.write(File.join(part_path, "count.txt"), "4\n")
    File.write(File.join(part_path, "default_compression_codec.txt"), "CODEC(LZ4)")
    File.write(File.join(part_path, "serialization.json"), %({"version":1,"columns":[],"types_serialization_versions":{},"propagate_types_serialization_versions_to_nested_types":true}))

    raw = IO::Memory.new
    2.times do |mark|
      start = (mark * 2 + 1).to_u64
      2.times { |index| raw.write_bytes(start + index.to_u64, IO::ByteFormat::LittleEndian) }
      2.times { |index| raw.write_bytes((start + index.to_u64 + 10).to_u32, IO::ByteFormat::LittleEndian) }
    end
    offsets = [0_u64, 16_u64, 24_u64, 40_u64, 48_u64]
    encoded = CrystalClick::CompressedMarkWriter.encode_with_positions(raw.to_slice, [0_u64, 48_u64], [4_u64], offsets, frame_bytes: 24)
    marks = IO::Memory.new
    [2_u64, 2_u64, 0_u64].each_with_index do |rows, index|
      2.times do |slot|
        position = encoded.position_at(rows.zero? ? offsets.size - 1 : index * 2 + slot)
        marks.write_bytes(position[0], IO::ByteFormat::LittleEndian)
        marks.write_bytes(position[1], IO::ByteFormat::LittleEndian)
      end
      marks.write_bytes(rows, IO::ByteFormat::LittleEndian)
    end
    File.write(File.join(part_path, "data.bin"), encoded.files.data)
    File.write(File.join(part_path, "data.mrk4"), marks.to_slice)
    CompactPhysicalContextW259Fixture.refresh_checksums(part_path)
  end
end

describe "Compact JSON declared UInt32 path reader" do
  it "emits an exact typed slice beside an ordinary selected column" do
    parent = File.tempname("crystal-click-json-u32-path-")
    Dir.mkdir(parent)
    begin
      part_path = File.join(parent, "0_1_1_0")
      CompactJsonUInt32PathReaderSpecFixture.write_path_fixture(part_path)
      table = CrystalClick::TypedPartTable.open_selected_typed([part_path], ["id", "doc.tenant_id"])
      table.column_types.should eq([{"id", "UInt64"}, {"doc.tenant_id", "UInt32"}])

      ids = [] of UInt64
      tenants = [] of UInt32
      table.scan_typed(batch_rows: 1) do |batch|
        ids.concat(batch.values_for("id", UInt64))
        tenants.concat(batch.values_for("doc.tenant_id", UInt32))
      end
      ids.should eq([1_u64, 2_u64, 3_u64, 4_u64])
      tenants.should eq([11_u32, 12_u32, 13_u32, 14_u32])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a same-size data replacement with changed frame geometry before decoding" do
    parent = File.tempname("crystal-click-json-u32-frame-grid-")
    Dir.mkdir(parent)
    part_path = File.join(parent, "0_1_1_0")
    begin
      uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
      value = CompactJsonUInt32PathReaderSpecFixture.fixed_value(uint64, 23_u64)
      column = CrystalClick::CompactPartColumn.binary_bulk(
        "doc",
        uint64,
        [[value]] of Array(CrystalClick::BinaryValue),
      )
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part_path,
        "id",
        Slice[1_u64],
        [column] of CrystalClick::CompactPartColumn,
        rows_per_mark: 1,
        frame_bytes: 4,
        mark_format: CrystalClick::CompactMarkFormat::Mrk4,
      )

      budget = CrystalClick::CompressedStreamBudget.read_default
      context = CrystalClick::CompactPartPhysicalContext.open(part_path, budget)
      slot = context.physical_roster.find { |item| item.column_name == "doc" } ||
             raise "fixture omitted the selected UInt64 slot"
      stream_name = slot.stream_name || raise "fixture UInt64 slot has no MRK4 stream name"
      slot_index = context.validate_fixed_width_stream_spans!("doc", stream_name, 8_u64, "test UInt64")
      context.fixed_width_stream_workspace_bytes("doc", slot_index, 0, stream_name, 8_u64, "test UInt64")

      data_path = File.join(part_path, "data.bin")
      original_size = context.data_size
      raw = CrystalClick::CompressedMarkReader.read_all(data_path, original_size, budget)
      replacement = nil.as(Bytes?)
      1.upto(raw.size) do |frame_bytes|
        next if frame_bytes == 4
        candidate = CrystalClick::CompressedMarkWriter.encode(
          raw,
          [0_u64, raw.size.to_u64],
          [1_u64],
          frame_bytes: frame_bytes,
        ).data
        next unless candidate.size.to_i64 == original_size
        candidate_index = CrystalClick::CompressedFrameIndex.new(
          candidate,
          budget.limits,
          CrystalClick::CompressedStreamBudget.read_default,
        )
        next if candidate_index.logical_size == context.frame_index.logical_size &&
                candidate_index.frames.size == context.frame_index.frames.size &&
                candidate_index.frames.each_with_index.all? do |frame, index|
                  expected = context.frame_index.frames[index]
                  frame.compressed_offset == expected.compressed_offset &&
                  frame.end_offset == expected.end_offset &&
                  frame.logical_start == expected.logical_start &&
                  frame.logical_end == expected.logical_end &&
                  frame.method == expected.method
                end
        replacement = candidate
        break
      end
      replacement_bytes = replacement || raise "could not produce a same-size alternate frame grid"
      File.write(data_path, replacement_bytes)
      File.size(data_path).should eq(original_size)

      destination = Bytes.new(8, 0xff_u8)
      decoded_before = budget.decoded_byte_count
      results_before = budget.result_byte_count
      error = expect_raises(CrystalClick::CorruptPartError) do
        context.read_fixed_width_stream_mark_into(
          "doc",
          slot_index,
          0,
          stream_name,
          8_u64,
          "test UInt64",
          destination,
          CrystalClick::CompressedBlock::DecodeWorkspace.new,
        )
      end
      error.message.not_nil!.should contain("frame geometry changed")
      destination.should eq(Bytes.new(8, 0xff_u8))
      budget.decoded_byte_count.should eq(decoded_before)
      budget.result_byte_count.should eq(results_before)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects absent or non-UInt32 declarations and refuses MRK3" do
    parent = File.tempname("crystal-click-json-u32-path-guards-")
    begin
      Dir.mkdir(parent)
      uint32_part = File.join(parent, "uint64_1_1_0")
      CompactJsonUInt32PathReaderSpecFixture.write_part(
        uint32_part,
        CompactJsonUInt32PathReaderSpecFixture.uint64_type,
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::TypedPartTable.open_selected_typed([uint32_part], ["doc.absent"])
      end

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::TypedPartTable.open_selected_typed([uint32_part], ["doc.tenant_id"])
      end

      mrk3_part = File.join(parent, "mrk3_1_1_0")
      CompactJsonUInt32PathReaderSpecFixture.write_part(
        mrk3_part,
        CompactJsonUInt32PathReaderSpecFixture.uint64_type,
        CrystalClick::CompactMarkFormat::Mrk3,
      )
      columns_path = File.join(mrk3_part, "columns.txt")
      columns = File.read(columns_path)
      old_declaration = CompactJsonUInt32PathReaderSpecFixture.schema(
        CompactJsonUInt32PathReaderSpecFixture.uint64_type,
      ).declaration
      new_declaration = CompactJsonUInt32PathReaderSpecFixture.schema(
        CompactJsonUInt32PathReaderSpecFixture.uint32_type,
      ).declaration
      columns.includes?(old_declaration).should be_true
      columns = columns.sub(old_declaration, new_declaration)
      File.write(columns_path, columns)
      expect_raises(CrystalClick::UnsupportedFormatError, /MRK4/) do
        CrystalClick::TypedPartTable.open_selected_typed([mrk3_part], ["doc.tenant_id"])
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
