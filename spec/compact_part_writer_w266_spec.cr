require "./spec_helper"
require "./support/compact_part_writer_w266_fixture"

private def w266_read_u64_le(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times do |index|
    value |= bytes[offset + index].to_u64 << (index * 8)
  end
  value
end

private def w266_expect_additional_update_index(bytes : Bytes, offset : Int = 0) : Nil
  flags = w266_read_u64_le(bytes, offset)
  (flags & CrystalClick::BinaryLowCardinalityStorageStreams::ADDITIONAL_BIT)
    .should eq(CrystalClick::BinaryLowCardinalityStorageStreams::ADDITIONAL_BIT)
  (flags & CrystalClick::BinaryLowCardinalityStorageStreams::UPDATE_BIT)
    .should eq(CrystalClick::BinaryLowCardinalityStorageStreams::UPDATE_BIT)
  (flags & CrystalClick::BinaryLowCardinalityStorageStreams::GLOBAL_BIT).should eq(0_u64)
end

describe CrystalClick::CompactPartWriter do
  it "round trips per-mark LC state and stateless row windows in MRK3 and MRK4" do
    fixture = CompactPartWriterW266Fixture
    [CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::CompactMarkFormat::Mrk4].each do |mark_format|
      suffix = mark_format.mrk3? ? "mrk3" : "mrk4"
      parent = File.tempname("crystal-click-w266-#{suffix}-")
      part_path = File.join(parent, "all_1_1_0")
      begin
        Dir.mkdir(parent)
        CrystalClick::CompactPartWriter.write_uint64_columns(
          part_path,
          CompactPartWriterW266Fixture::KEY_NAME,
          fixture.keys,
          fixture.columns,
          rows_per_mark: CompactPartWriterW266Fixture::ROWS_PER_MARK,
          frame_bytes: CompactPartWriterW266Fixture::FRAME_BYTES,
          mark_format: mark_format,
        )

        physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
        physical.mode.should eq(mark_format)
        physical.row_count.should eq(CompactPartWriterW266Fixture::ROW_COUNT.to_u64)
        physical.granule_count.should eq(4_i32)

        CompactPartWriterW266Fixture::COLUMN_NAMES.each do |name|
          reader = CrystalClick::CompactBinaryBulkColumnReader.open(part_path, name, fixture.types[name])
          reader.mark_count.should eq(4)
          reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
          expected = fixture.expected_signatures(name)
          fixture.read_signatures(name, reader.read_marks(0, 4)).should eq(expected)
          fixture.read_signatures(name, reader.read_marks(1, 2)).should eq(expected[2, 4])
          fixture.read_signatures(name, reader.read_marks(3, 1)).should eq(expected[6, 2])
          fixture.read_signatures(name, reader.read_marks(4, 0)).should be_empty
        end

        if mark_format.mrk3?
          ["root", "maybe"].each do |column_name|
            marks = physical.read_window(column_name, 0, 4).granules
            marks.each do |mark|
              bytes = mark.shards.first.bytes
              w266_read_u64_le(bytes, 0).should eq(CrystalClick::BinaryLowCardinalityStorageStreams::VERSION)
              w266_expect_additional_update_index(bytes, 8)
            end
          end
        end
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "persists the exact MRK4 callback roster and additional-only reset at each granule" do
    fixture = CompactPartWriterW266Fixture
    parent = File.tempname("crystal-click-w266-roster-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part_path,
        CompactPartWriterW266Fixture::KEY_NAME,
        fixture.keys,
        fixture.columns,
        rows_per_mark: CompactPartWriterW266Fixture::ROWS_PER_MARK,
        frame_bytes: CompactPartWriterW266Fixture::FRAME_BYTES,
        mark_format: CrystalClick::CompactMarkFormat::Mrk4,
      )

      physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
      roster = physical.physical_roster.map do |slot|
        {slot.index, slot.column_name, slot.stream_name}
      end
      expected_roster = [
        {0_i32, "pk", "pk"},
        {1_i32, "root", "root.dict_prefix"},
        {2_i32, "root", "root.dict"},
        {3_i32, "root", "root"},
        {4_i32, "maybe", "maybe.dict_prefix"},
        {5_i32, "maybe", "maybe.dict"},
        {6_i32, "maybe", "maybe"},
        {7_i32, "items", "items.dict_prefix"},
        {8_i32, "items", "items.size0"},
        {9_i32, "items", "items.dict"},
        {10_i32, "items", "items"},
      ] of Tuple(Int32, String, String?)
      roster.should eq(expected_roster)

      {"root", "maybe"}.each do |column_name|
        marks = physical.read_window(column_name, 0, 4).granules
        marks.size.should eq(4)
        marks.each do |mark|
          prefix = mark.shards.find { |shard| shard.stream_name == "#{column_name}.dict_prefix" } ||
                   raise "missing #{column_name} dictionary state-prefix callback"
          dictionary = mark.shards.find { |shard| shard.stream_name == "#{column_name}.dict" } ||
                       raise "missing #{column_name} dictionary callback"
          indexes = mark.shards.find { |shard| shard.stream_name == column_name } ||
                    raise "missing #{column_name} index callback"
          prefix.bytes.size.should eq(8)
          w266_read_u64_le(prefix.bytes, 0).should eq(CrystalClick::BinaryLowCardinalityStorageStreams::VERSION)
          dictionary.bytes.should be_empty
          w266_expect_additional_update_index(indexes.bytes)
        end
      end

      item_marks = physical.read_window("items", 0, 4).granules
      item_marks.size.should eq(4)
      item_marks.each_with_index do |mark, index|
        prefix = mark.shards.find { |shard| shard.stream_name == "items.dict_prefix" } ||
                 raise "missing items dictionary state-prefix callback"
        dictionary = mark.shards.find { |shard| shard.stream_name == "items.dict" } ||
                     raise "missing items dictionary callback"
        indexes = mark.shards.find { |shard| shard.stream_name == "items" } ||
                  raise "missing items index callback"
        prefix.bytes.size.should eq(8)
        w266_read_u64_le(prefix.bytes, 0).should eq(CrystalClick::BinaryLowCardinalityStorageStreams::VERSION)
        dictionary.bytes.should be_empty
        if index == 1
          indexes.bytes.should be_empty
        else
          w266_expect_additional_update_index(indexes.bytes)
        end
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "exposes exact root slices and an empty EOF window through the Compact table" do
    fixture = CompactPartWriterW266Fixture
    parent = File.tempname("crystal-click-w266-table-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part_path,
        CompactPartWriterW266Fixture::KEY_NAME,
        fixture.keys,
        fixture.columns,
        rows_per_mark: CompactPartWriterW266Fixture::ROWS_PER_MARK,
        frame_bytes: CompactPartWriterW266Fixture::FRAME_BYTES,
        mark_format: CrystalClick::CompactMarkFormat::Mrk4,
      )

      table = CrystalClick::CompactPartTable.open_selected_typed(
        [part_path],
        [CompactPartWriterW266Fixture::KEY_NAME, "root"],
      )
      table.total_row_count.should eq(CompactPartWriterW266Fixture::ROW_COUNT.to_u64)
      table.part_mark_row_counts.should eq([[2_u64, 2_u64, 2_u64, 2_u64]])

      scan = ->(start_row : UInt64, max_rows : Int32) do
        keys = [] of UInt64
        values = [] of String
        callbacks = 0
        table.scan_typed_window(start_row, max_rows) do |batch|
          callbacks += 1
          keys.concat(batch.values_for(CompactPartWriterW266Fixture::KEY_NAME))
          values.concat(batch.low_cardinality_strings_for("root").map { |value| value.to_slice.hexstring })
        end
        {callbacks, keys, values}
      end

      full = scan.call(0_u64, CompactPartWriterW266Fixture::ROW_COUNT)
      full[0].should eq(4)
      full[1].should eq(CompactPartWriterW266Fixture::KEYS)
      full[2].should eq(fixture.root_strings.map { |value| value.to_slice.hexstring })

      middle = scan.call(2_u64, 4)
      middle[0].should eq(2)
      middle[1].should eq(CompactPartWriterW266Fixture::KEYS[2, 4])
      middle[2].should eq(fixture.root_strings[2, 4].map { |value| value.to_slice.hexstring })

      last = scan.call(6_u64, 2)
      last[0].should eq(1)
      last[1].should eq(CompactPartWriterW266Fixture::KEYS[6, 2])
      last[2].should eq(fixture.root_strings[6, 2].map { |value| value.to_slice.hexstring })

      empty = scan.call(CompactPartWriterW266Fixture::ROW_COUNT.to_u64, 1)
      empty[0].should eq(0)
      empty[1].should be_empty
      empty[2].should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
