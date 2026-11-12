require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w279_fixture"

private def w279_collect_leaf_ids(
  value : CrystalClick::BinaryValue,
  depth : Int,
  output : Array(UInt64),
) : Nil
  if depth == 0
    output << value.json_row.value_for("id").not_nil!.as_uint64
    return
  end
  value.elements.each { |child| w279_collect_leaf_ids(child, depth - 1, output) }
  nil
end

private def w279_assert_child_json_values(
  rows : Array(CrystalClick::StorageColumnValue),
  depth : Int,
  first_row : Int = 0,
) : Nil
  fixture = CompactPartWriterW279Fixture
  ids_by_row = fixture.expected_leaf_ids(depth)
  actual_selected = case depth
                    when 0 then [true, false, false, false, true, false, false, true]
                    when 2 then [true, false, false, false, true, true, false, true]
                    when 3 then [true, false, false, false, true, true, true, true]
                    else        raise ArgumentError.new("unsupported W279 fixture depth")
                    end

  rows.size.should be <= ids_by_row.size
  rows.each_with_index do |row, row_offset|
    absolute_row = first_row + row_offset
    payload = row.object_document.value_for(CompactPartWriterW279Fixture::PAYLOAD_PATH)
    payload.type.should eq(fixture.dynamic_type)
    payload.is_null?.should eq(!actual_selected[absolute_row])
    if actual_selected[absolute_row]
      payload.child_count.should eq(1)
      selected = payload.child_at(0)
      observed_ids = [] of UInt64
      w279_collect_leaf_ids(selected, depth, observed_ids)
      observed_ids.should eq(ids_by_row[absolute_row])

      next unless depth == 0 || !observed_ids.empty?
      leaves = [] of CrystalClick::BinaryJsonRow
      w279_collect_json_rows(selected, depth, leaves)
      leaves.map do |json_row|
        id = json_row.value_for("id").not_nil!.as_uint64
        json_row.value_for("label").not_nil!.as_string.should eq("child-#{id}")
        CompactPartWriterW279Fixture::SHARED_PATHS.each do |path|
          json_row.value_for(path).not_nil!.type.should eq(fixture.string_type)
        end
        id
      end.should eq(ids_by_row[absolute_row])

      leaves.each do |json_row|
        id = json_row.value_for("id").not_nil!.as_uint64
        case id
        when 11_u64
          json_row.value_for("alpha").not_nil!.as_string.should eq("")
        when 12_u64
          json_row.value_for("aa").not_nil!.as_string.should eq(String.new(Bytes[0x00_u8, 0xff_u8, 0x80_u8, 0x41_u8]))
        when 13_u64
          json_row.value_for("beta").not_nil!.as_string.should eq("shared\0nul")
        when 82_u64
          json_row.value_for("alpha").not_nil!.as_string.should eq(CompactPartWriterW279Fixture::LONG_STRING)
        end
      end
    else
      payload.child_count.should eq(0)
    end
  end
  nil
end

private def w279_collect_json_rows(
  value : CrystalClick::BinaryValue,
  depth : Int,
  output : Array(CrystalClick::BinaryJsonRow),
) : Nil
  if depth == 0
    output << value.json_row
    return
  end
  value.elements.each { |child| w279_collect_json_rows(child, depth - 1, output) }
  nil
end

private def w279_write_and_read_entry_case(shared_data_version : UInt64) : Nil
  fixture = CompactPartWriterW279Fixture
  parent = File.tempname("crystal-click-w279-entry-v#{shared_data_version}-")
  part_path = File.join(parent, "all_1_1_0")
  begin
    Dir.mkdir(parent)
    CrystalClick::CompactPartWriter.write_uint64_columns(
      part_path,
      CompactPartWriterW279Fixture::KEY_NAME,
      fixture.keys,
      [fixture.column(2, shared_data_version)] of CrystalClick::CompactPartColumn,
      rows_per_mark: CompactPartWriterW279Fixture::ROWS_PER_MARK,
      frame_bytes: CompactPartWriterW279Fixture::FRAME_BYTES,
      mark_format: CrystalClick::CompactMarkFormat::Mrk4,
      profile: CrystalClick::BinaryBulkProfile.single_stream,
    ).should eq(part_path)

    reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
      part_path,
      CompactPartWriterW279Fixture::COLUMN_NAME,
      fixture.schema,
    )
    reader.mark_count.should eq(CompactPartWriterW279Fixture::MARK_COUNT)
    reader.row_count.should eq(CompactPartWriterW279Fixture::ROW_COUNT.to_u64)
    w279_assert_child_json_values(reader.read_marks(0, reader.mark_count).flatten, 2)
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

describe "W279 typed-Dynamic JSON child shared-layout entry" do
  it "keeps the MAP0 parent and child control round-trippable under String0 and MRK4" do
    shared_buckets = CompactPartWriterW279Fixture::SHARED_PATHS.map do |path|
      CrystalClick::ObjectSharedBucketLayout.bucket_for(path, 2_u64)
    end.uniq.sort
    shared_buckets.should eq([0, 1])
    w279_write_and_read_entry_case(0_u64)
  end

  it "writes matching MAP_WITH_BUCKETS parent and child owners with two buckets" do
    w279_write_and_read_entry_case(1_u64)
  end

  it "writes matching ADVANCED parent and child owners with two buckets" do
    w279_write_and_read_entry_case(2_u64)
  end

  it "writes matching ADVANCED_CHUNKED parent and child owners with two buckets" do
    w279_write_and_read_entry_case(3_u64)
  end
end
