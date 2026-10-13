require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w271_fixture"

private module CompactPartWriterW271RecursiveOwnerFixture
  extend self

  COLUMN_NAME = "typed_dynamic_json_array"
  ARRAY_SITE  = "root/array[0]"

  # The eight frozen W271 Object inputs are deliberately redistributed across
  # the parent Array(JSON) rows. Mark 1 has no child Objects; mark 3 has four,
  # which makes parent rows, Object occurrences, and Dynamic JSON arms distinct
  # grids.
  def object_indexes_by_parent_row : Array(Array(Int32))
    [
      [0, 1],
      [] of Int32,
      [] of Int32,
      [] of Int32,
      [4],
      [5],
      [6],
      [7, 2, 3],
    ] of Array(Int32)
  end

  def schema : CrystalClick::StorageColumnSchema
    CrystalClick::StorageColumnSchema.parse(
      CrystalClick::BinaryDataType.array(CompactPartWriterW271Fixture.declared_json_type).name,
    )
  end

  def context : CrystalClick::CompactJsonWriteContext
    CrystalClick::CompactJsonWriteContext.new(
      {ARRAY_SITE => CompactPartWriterW271Fixture.object_plan} of String => CrystalClick::ObjectDocumentPlan,
    )
  end

  def rows : Array(CrystalClick::StorageColumnValue)
    object_rows = CompactPartWriterW271Fixture.rows
    object_indexes_by_parent_row.map do |indexes|
      children = indexes.map do |index|
        source = object_rows[index]
        source.object?.should be_true
        CrystalClick::StorageColumnValue.object_document(source.object_document)
      end
      CrystalClick::StorageColumnValue.array(children)
    end
  end

  def column : CrystalClick::CompactPartColumn
    CrystalClick::CompactPartColumn.json(
      COLUMN_NAME,
      schema,
      CompactPartWriterW271Fixture.granules(rows),
      context,
    )
  end
end

private def w271_recursive_owner_write(
  part_path : String,
  mark_format : CrystalClick::CompactMarkFormat,
  discriminator_mode : CrystalClick::CompactVariantDiscriminatorMode,
) : String
  CrystalClick::CompactPartWriter.write_uint64_columns(
    part_path,
    CompactPartWriterW271Fixture::KEY_NAME,
    CompactPartWriterW271Fixture::KEYS,
    [CompactPartWriterW271RecursiveOwnerFixture.column] of CrystalClick::CompactPartColumn,
    rows_per_mark: CompactPartWriterW271Fixture::ROWS_PER_MARK,
    frame_bytes: CompactPartWriterW271Fixture::FRAME_BYTES,
    mark_format: mark_format,
    variant_discriminator_mode: discriminator_mode,
  )
end

private def w271_recursive_owner_assert_window(
  actual_marks : Array(Array(CrystalClick::StorageColumnValue)),
  first_mark : Int32,
  mark_count : Int32,
) : Nil
  fixture = CompactPartWriterW271Fixture
  expected_groups = CompactPartWriterW271RecursiveOwnerFixture.object_indexes_by_parent_row
  expected_literals = fixture.expected_literals
  actual_marks.size.should eq(mark_count)

  mark_count.times do |mark_offset|
    mark_index = first_mark + mark_offset
    actual_rows = actual_marks[mark_offset]
    actual_rows.size.should eq(CompactPartWriterW271Fixture::ROWS_PER_MARK)
    expected_start = mark_index * CompactPartWriterW271Fixture::ROWS_PER_MARK

    CompactPartWriterW271Fixture::ROWS_PER_MARK.times do |row_offset|
      row_index = expected_start + row_offset
      actual_array = actual_rows[row_offset]
      actual_array.array?.should be_true
      expected_indexes = expected_groups[row_index]
      children = actual_array.array_values
      children.size.should eq(expected_indexes.size)

      expected_indexes.each_with_index do |object_index, child_index|
        actual_object = children[child_index]
        actual_object.object?.should be_true
        document = actual_object.object_document
        payload = document.value_for(CompactPartWriterW271Fixture::PAYLOAD_PATH)
        payload.type.should eq(fixture.dynamic_type)
        expected_literal = expected_literals[object_index]

        if literal = expected_literal
          payload.is_null?.should be_false
          payload.child_count.should eq(1)
          json = payload.child_at(0)
          json.type.should eq(fixture.json_type)
          cell = json.json_row.value_for(CompactPartWriterW271Fixture::VALUE_PATH).not_nil!
          cell.type.should eq(fixture.uint8_type)
          cell.byte_at(0).should eq(literal)
        else
          payload.is_null?.should be_true
          payload.child_count.should eq(0)
        end
      end
    end
  end

  nil
end

describe CrystalClick::CompactPartWriter do
  it "keeps nested typed-Dynamic JSON owners aligned with Array(JSON) occurrences" do
    fixture = CompactPartWriterW271RecursiveOwnerFixture
    combinations = [
      {CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::CompactVariantDiscriminatorMode::Basic},
      {CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::CompactVariantDiscriminatorMode::Compact},
      {CrystalClick::CompactMarkFormat::Mrk4, CrystalClick::CompactVariantDiscriminatorMode::Basic},
      {CrystalClick::CompactMarkFormat::Mrk4, CrystalClick::CompactVariantDiscriminatorMode::Compact},
    ]
    windows = [
      {0, CompactPartWriterW271Fixture::MARK_COUNT},
      {1, 2},
      {CompactPartWriterW271Fixture::MARK_COUNT - 1, 1},
      {1, 1},
      {CompactPartWriterW271Fixture::MARK_COUNT, 0},
    ]

    fixture.schema.declaration.should eq(
      CrystalClick::BinaryDataType.array(CompactPartWriterW271Fixture.declared_json_type).name,
    )
    fixture.schema.array?.should be_true
    child_schema = fixture.schema.child_at(0)
    child_schema.object?.should be_true
    child_schema.object_schema.typed_paths[CompactPartWriterW271Fixture::PAYLOAD_PATH].should eq(
      CompactPartWriterW271Fixture.dynamic_type,
    )
    fixture.object_indexes_by_parent_row.map(&.size).should eq([2, 0, 0, 0, 1, 1, 1, 3])
    fixture.object_indexes_by_parent_row.each_slice(CompactPartWriterW271Fixture::ROWS_PER_MARK).map do |rows|
      rows.sum { |indexes| indexes.count { |index| !CompactPartWriterW271Fixture.expected_literals[index].nil? } }
    end.to_a.should eq([1, 0, 2, 1])

    combinations.each do |mark_format, discriminator_mode|
      mark_suffix = mark_format.mrk3? ? "mrk3" : "mrk4"
      mode_suffix = discriminator_mode == CrystalClick::CompactVariantDiscriminatorMode::Basic ? "basic" : "compact"
      parent = File.tempname("crystal-click-w271-recursive-owner-#{mark_suffix}-#{mode_suffix}-")
      part_path = File.join(parent, "all_1_1_0")
      begin
        Dir.mkdir(parent)
        w271_recursive_owner_write(part_path, mark_format, discriminator_mode).should eq(part_path)
        File.exists?(part_path).should be_true

        reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
          part_path,
          CompactPartWriterW271RecursiveOwnerFixture::COLUMN_NAME,
          fixture.schema,
        )
        reader.schema_declaration.should eq(fixture.schema.declaration)
        reader.mark_count.should eq(CompactPartWriterW271Fixture::MARK_COUNT)
        reader.row_count.should eq(CompactPartWriterW271Fixture::ROW_COUNT.to_u64)
        reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])

        # The recursive typed-JSON site is non-Advanced MAP0, so each present
        # child Object is validated against its captured parent-source slices
        # before materialization. Distinct literals make owner rebinds visible.
        windows.each do |first_mark, mark_count|
          w271_recursive_owner_assert_window(reader.read_marks(first_mark, mark_count), first_mark, mark_count)
        end

        full = reader.read_marks(0, reader.mark_count)
        full.map { |mark| mark.sum { |row| row.array_values.size } }.should eq([2, 0, 2, 4])
        full.map do |mark|
          mark.sum do |row|
            row.array_values.count do |object|
              !object.object_document.value_for(CompactPartWriterW271Fixture::PAYLOAD_PATH).is_null?
            end
          end
        end.should eq([1, 0, 2, 1])
        zero_child_mark = reader.read_marks(1, 1)
        zero_child_mark[0].map { |row| row.array_values.size }.should eq([0, 0])
        reader.read_marks(reader.mark_count, 0).should be_empty
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end
end
