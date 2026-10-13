require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w272_fixture"

private def w272p_write(
  part_path : String,
  column : CrystalClick::CompactPartColumn,
  mark_format : CrystalClick::CompactMarkFormat,
  discriminator_mode : CrystalClick::CompactVariantDiscriminatorMode,
) : String
  CrystalClick::CompactPartWriter.write_uint64_columns(
    part_path,
    CompactPartWriterW272Fixture::KEY_NAME,
    CompactPartWriterW272Fixture::KEYS,
    [column] of CrystalClick::CompactPartColumn,
    rows_per_mark: CompactPartWriterW272Fixture::ROWS_PER_MARK,
    frame_bytes: CompactPartWriterW272Fixture::FRAME_BYTES,
    mark_format: mark_format,
    variant_discriminator_mode: discriminator_mode,
  )
end

private def w272p_column(
  rows : Array(CrystalClick::StorageColumnValue),
) : CrystalClick::CompactPartColumn
  fixture = CompactPartWriterW272Fixture
  CrystalClick::CompactPartColumn.json(
    CompactPartWriterW272Fixture::COLUMN_NAME,
    fixture.schema,
    fixture.granules(rows),
    fixture.context,
  )
end

private def w272p_assert_rows(
  actual : Array(CrystalClick::StorageColumnValue),
  expected : Array(Array(UInt8)?),
) : Nil
  fixture = CompactPartWriterW272Fixture
  actual.size.should eq(expected.size)
  actual.each_with_index do |value, index|
    expected_elements = expected[index]
    fixture.literal_for(value).should eq(expected_elements)
    payload = value.object_document.value_for(CompactPartWriterW272Fixture::PAYLOAD_PATH)
    payload.type.should eq(fixture.dynamic_type)
    if elements = expected_elements
      payload.is_null?.should be_false
      payload.child_count.should eq(1)
      selected = payload.child_at(0)
      selected.type.should eq(fixture.array_json_type)
      selected.elements.size.should eq(elements.size)
      selected.elements.each_with_index do |json, element_index|
        json.type.should eq(fixture.json_type)
        json.json_row.type.should eq(fixture.json_type)
        cell = json.json_row.value_for(CompactPartWriterW272Fixture::VALUE_PATH).not_nil!
        cell.type.should eq(fixture.uint8_type)
        cell.byte_at(0).should eq(elements[element_index])
      end
    else
      payload.is_null?.should be_true
    end
  end
  nil
end

private def w272p_assert_window(
  marks : Array(Array(CrystalClick::StorageColumnValue)),
  first_mark : Int,
  mark_count : Int,
) : Nil
  fixture = CompactPartWriterW272Fixture
  marks.size.should eq(mark_count)
  row_start = first_mark * CompactPartWriterW272Fixture::ROWS_PER_MARK
  row_count = mark_count * CompactPartWriterW272Fixture::ROWS_PER_MARK
  expected = fixture.expected_literals[row_start, row_count]
  marks.each do |mark|
    mark.size.should eq(CompactPartWriterW272Fixture::ROWS_PER_MARK)
  end
  w272p_assert_rows(marks.flatten, expected)

  marks.map do |mark|
    mark.count { |row| !fixture.literal_for(row).nil? }
  end.should eq(fixture.expected_mark_actual_counts[first_mark, mark_count])
  marks.map do |mark|
    mark.sum { |row| fixture.literal_for(row).try(&.size) || 0 }
  end.should eq(fixture.expected_mark_json_element_counts[first_mark, mark_count])
  nil
end

private def w272p_assert_mrk4_first_prefix_statistics(part_path : String) : Nil
  physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
  physical.mode.should eq(CrystalClick::CompactMarkFormat::Mrk4)
  shards = physical.read_window(CompactPartWriterW272Fixture::COLUMN_NAME, 0, 1).granules[0].shards
  prefixes = shards.select do |shard|
    shard.stream_name.try(&.ends_with?(".payload.dynamic_structure")) == true
  end.map { |shard| CrystalClick::DynamicStructureCodec.decode(shard.bytes) }
  prefixes.size.should eq(1)
  prefix = prefixes[0]
  prefix.version.should eq(CrystalClick::DynamicStructure::VERSION_V3)
  prefix.statistics.not_nil!.counts.should eq([4_u64, 0_u64])
  prefix.statistics.not_nil!.shared.should be_empty
  nil
end

private def w272p_empty_mark_rows : Array(CrystalClick::StorageColumnValue)
  rows = CompactPartWriterW272Fixture.rows
  [rows[0], rows[1], rows[2], rows[3], rows[4], rows[6], rows[5], rows[7]] of CrystalClick::StorageColumnValue
end

private def w272p_empty_mark_literals : Array(Array(UInt8)?)
  [
    ([11_u8, 12_u8] of UInt8),
    nil,
    nil,
    nil,
    ([] of UInt8),
    nil,
    ([61_u8] of UInt8),
    ([81_u8, 82_u8, 83_u8] of UInt8),
  ] of Array(UInt8)?
end

private def w272p_common_codec_empty_mark_control!(
  rows : Array(CrystalClick::StorageColumnValue),
) : Nil
  fixture = CompactPartWriterW272Fixture
  actuals = fixture.actuals
  bindings = fixture.json_bindings
  leaves = bindings[CompactPartWriterW272Fixture::PAYLOAD_PATH]
  leaves.size.should eq(1)
  key, child_plan = leaves[0]
  key.dynamic_site.should eq(CompactPartWriterW272Fixture::SITE_PATH)
  key.canonical_arm_index.should eq(actuals.canonical_index_for(fixture.array_json_type))
  key.descriptor_child_path.should eq([0_i32] of Int32)
  child_plan.typed_paths.should eq(fixture.json_type.json_type.not_nil!.typed_paths)
  actuals.statistics.not_nil!.counts.should eq([4_u64, 0_u64])

  documents = fixture.granules(rows).map do |mark_rows|
    mark_rows.map(&.object_document)
  end
  streams = CrystalClick::ObjectDocumentCodec.encode(fixture.object_plan, documents)
  decoded = CrystalClick::ObjectDocumentCodec.decode(
    fixture.schema.object_schema.typed_paths,
    streams,
    typed_dynamic_json_object_leaf_plans: bindings,
  )
  decoded.size.should eq(CompactPartWriterW272Fixture::MARK_COUNT)
  decoded.each do |mark_rows|
    mark_rows.size.should eq(CompactPartWriterW272Fixture::ROWS_PER_MARK)
  end

  decoded_literals = decoded.flat_map do |mark_rows|
    mark_rows.map do |document|
      fixture.literal_for(CrystalClick::StorageColumnValue.object_document(document))
    end
  end
  decoded_literals.should eq(w272p_empty_mark_literals)
  decoded.map do |mark_rows|
    mark_rows.count do |document|
      !fixture.literal_for(CrystalClick::StorageColumnValue.object_document(document)).nil?
    end
  end.should eq([1, 0, 1, 2])
  decoded.map do |mark_rows|
    mark_rows.sum do |document|
      fixture.literal_for(CrystalClick::StorageColumnValue.object_document(document)).try(&.size) || 0
    end
  end.should eq([2, 0, 0, 4])
  nil
end

private def w272p_check_empty_selected_arm_mark(
  mark_format : CrystalClick::CompactMarkFormat,
  discriminator_mode : CrystalClick::CompactVariantDiscriminatorMode,
) : Nil
  fixture = CompactPartWriterW272Fixture
  rows = w272p_empty_mark_rows
  expected = w272p_empty_mark_literals
  w272p_common_codec_empty_mark_control!(rows)

  parent = File.tempname("crystal-click-w272-empty-arm-mark-")
  part_path = File.join(parent, "all_1_1_0")
  begin
    Dir.mkdir(parent)
    w272p_write(part_path, w272p_column(rows), mark_format, discriminator_mode).should eq(part_path)
    File.exists?(part_path).should be_true
    w272p_assert_mrk4_first_prefix_statistics(part_path) if mark_format == CrystalClick::CompactMarkFormat::Mrk4

    recursive = CrystalClick::CompactRecursiveJsonColumnReader.open(
      part_path,
      CompactPartWriterW272Fixture::COLUMN_NAME,
      fixture.schema,
    )
    recursive.mark_count.should eq(CompactPartWriterW272Fixture::MARK_COUNT)
    recursive.row_count.should eq(CompactPartWriterW272Fixture::ROW_COUNT.to_u64)
    recursive.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
    recursive_marks = recursive.read_marks(0, CompactPartWriterW272Fixture::MARK_COUNT)
    w272p_assert_rows(recursive_marks.flatten, expected)
    recursive_marks.map do |mark|
      mark.count { |row| !fixture.literal_for(row).nil? }
    end.should eq([1, 0, 1, 2])
    recursive_marks.map do |mark|
      mark.sum { |row| fixture.literal_for(row).try(&.size) || 0 }
    end.should eq([2, 0, 0, 4])
    empty_only_mark = recursive.read_marks(2, 1)[0]
    empty_only_mark.size.should eq(CompactPartWriterW272Fixture::ROWS_PER_MARK)
    w272p_assert_rows(empty_only_mark, [([] of UInt8), nil] of Array(UInt8)?)
    empty_only_mark.count { |row| !fixture.literal_for(row).nil? }.should eq(1)
    empty_only_mark.sum { |row| fixture.literal_for(row).try(&.size) || 0 }.should eq(0)

    static_root = CrystalClick::CompactStaticJsonBulkColumnReader.open(
      part_path,
      CompactPartWriterW272Fixture::COLUMN_NAME,
      fixture.declared_json_type,
    )
    static_root.mark_count.should eq(CompactPartWriterW272Fixture::MARK_COUNT)
    static_root.row_count.should eq(CompactPartWriterW272Fixture::ROW_COUNT.to_u64)
    static_root.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
    static_marks = static_root.read_marks(0, CompactPartWriterW272Fixture::MARK_COUNT).map do |mark|
      mark.map { |document| CrystalClick::StorageColumnValue.object_document(document) }
    end
    w272p_assert_rows(static_marks.flatten, expected)
    static_marks.map do |mark|
      mark.count { |row| !fixture.literal_for(row).nil? }
    end.should eq([1, 0, 1, 2])
    static_marks.map do |mark|
      mark.sum { |row| fixture.literal_for(row).try(&.size) || 0 }
    end.should eq([2, 0, 0, 4])
    static_empty_only_mark = static_root.read_marks(2, 1)[0].map do |document|
      CrystalClick::StorageColumnValue.object_document(document)
    end
    w272p_assert_rows(static_empty_only_mark, [([] of UInt8), nil] of Array(UInt8)?)
    static_empty_only_mark.count { |row| !fixture.literal_for(row).nil? }.should eq(1)
    static_empty_only_mark.sum { |row| fixture.literal_for(row).try(&.size) || 0 }.should eq(0)
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

private def w272p_check_public_matrix(
  mark_format : CrystalClick::CompactMarkFormat,
  discriminator_mode : CrystalClick::CompactVariantDiscriminatorMode,
) : Nil
  fixture = CompactPartWriterW272Fixture
  # The common paired-stream path validates this plan and literal roster
  # before the Compact writer is allowed to exercise physical admission.
  fixture.common_codec_roundtrip!

  parent = File.tempname("crystal-click-w272-matrix-")
  part_path = File.join(parent, "all_1_1_0")
  begin
    Dir.mkdir(parent)
    w272p_write(part_path, fixture.column, mark_format, discriminator_mode).should eq(part_path)
    File.exists?(part_path).should be_true
    w272p_assert_mrk4_first_prefix_statistics(part_path) if mark_format == CrystalClick::CompactMarkFormat::Mrk4

    windows = [
      {0, CompactPartWriterW272Fixture::MARK_COUNT}, # complete grid
      {1, 2},                                        # middle
      {1, 1},                                        # zero selected arms
      {2, 1},                                        # selected empty array and one-element array
      {3, 1},                                        # last mark
      {CompactPartWriterW272Fixture::MARK_COUNT, 0}, # EOF empty window
    ]

    recursive = CrystalClick::CompactRecursiveJsonColumnReader.open(
      part_path,
      CompactPartWriterW272Fixture::COLUMN_NAME,
      fixture.schema,
    )
    recursive.schema_declaration.should eq(fixture.schema.declaration)
    recursive.mark_count.should eq(CompactPartWriterW272Fixture::MARK_COUNT)
    recursive.row_count.should eq(CompactPartWriterW272Fixture::ROW_COUNT.to_u64)
    recursive.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
    windows.each do |first_mark, mark_count|
      w272p_assert_window(recursive.read_marks(first_mark, mark_count), first_mark, mark_count)
    end

    static_root = CrystalClick::CompactStaticJsonBulkColumnReader.open(
      part_path,
      CompactPartWriterW272Fixture::COLUMN_NAME,
      fixture.declared_json_type,
    )
    static_root.schema_declaration.should eq(fixture.declared_json_type.name)
    static_root.mark_count.should eq(CompactPartWriterW272Fixture::MARK_COUNT)
    static_root.row_count.should eq(CompactPartWriterW272Fixture::ROW_COUNT.to_u64)
    static_root.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
    windows.each do |first_mark, mark_count|
      documents = static_root.read_marks(first_mark, mark_count)
      values = documents.map do |mark|
        mark.map { |document| CrystalClick::StorageColumnValue.object_document(document) }
      end
      w272p_assert_window(values, first_mark, mark_count)
    end

    zero_arm = recursive.read_marks(1, 1)[0]
    zero_arm.size.should eq(CompactPartWriterW272Fixture::ROWS_PER_MARK)
    w272p_assert_rows(zero_arm, [nil, nil] of Array(UInt8)?)
    empty_actual = recursive.read_marks(2, 1)[0][0]
    fixture.literal_for(empty_actual).should eq([] of UInt8)
    empty_actual.object_document.value_for(CompactPartWriterW272Fixture::PAYLOAD_PATH).is_null?.should be_false
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

describe CrystalClick::CompactPartWriter do
  it "round trips the typed-Dynamic Array(JSON) owner on MRK3 BASIC" do
    w272p_check_public_matrix(
      CrystalClick::CompactMarkFormat::Mrk3,
      CrystalClick::CompactVariantDiscriminatorMode::Basic,
    )
  end

  it "round trips the typed-Dynamic Array(JSON) owner on MRK3 COMPACT" do
    w272p_check_public_matrix(
      CrystalClick::CompactMarkFormat::Mrk3,
      CrystalClick::CompactVariantDiscriminatorMode::Compact,
    )
  end

  it "round trips the typed-Dynamic Array(JSON) owner on MRK4 BASIC" do
    w272p_check_public_matrix(
      CrystalClick::CompactMarkFormat::Mrk4,
      CrystalClick::CompactVariantDiscriminatorMode::Basic,
    )
  end

  it "round trips the typed-Dynamic Array(JSON) owner on MRK4 COMPACT" do
    w272p_check_public_matrix(
      CrystalClick::CompactMarkFormat::Mrk4,
      CrystalClick::CompactVariantDiscriminatorMode::Compact,
    )
  end

  it "keeps a selected empty Array(JSON) in an A=1/E=0 mark on MRK3 BASIC" do
    w272p_check_empty_selected_arm_mark(
      CrystalClick::CompactMarkFormat::Mrk3,
      CrystalClick::CompactVariantDiscriminatorMode::Basic,
    )
  end

  it "keeps a selected empty Array(JSON) in an A=1/E=0 mark on MRK3 COMPACT" do
    w272p_check_empty_selected_arm_mark(
      CrystalClick::CompactMarkFormat::Mrk3,
      CrystalClick::CompactVariantDiscriminatorMode::Compact,
    )
  end

  it "keeps a selected empty Array(JSON) in an A=1/E=0 mark on MRK4 BASIC" do
    w272p_check_empty_selected_arm_mark(
      CrystalClick::CompactMarkFormat::Mrk4,
      CrystalClick::CompactVariantDiscriminatorMode::Basic,
    )
  end

  it "keeps a selected empty Array(JSON) in an A=1/E=0 mark on MRK4 COMPACT" do
    w272p_check_empty_selected_arm_mark(
      CrystalClick::CompactMarkFormat::Mrk4,
      CrystalClick::CompactVariantDiscriminatorMode::Compact,
    )
  end
end
