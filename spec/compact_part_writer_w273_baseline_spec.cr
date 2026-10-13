require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w273_fixture"

private def w273_write_depth_two(
  part_path : String,
  mark_format : CrystalClick::CompactMarkFormat,
  discriminator_mode : CrystalClick::CompactVariantDiscriminatorMode,
) : String
  fixture = CompactPartWriterW273Fixture
  CrystalClick::CompactPartWriter.write_uint64_columns(
    part_path,
    CompactPartWriterW273Fixture::KEY_NAME,
    CompactPartWriterW273Fixture::KEYS,
    [fixture.column(2)] of CrystalClick::CompactPartColumn,
    rows_per_mark: CompactPartWriterW273Fixture::ROWS_PER_MARK,
    frame_bytes: CompactPartWriterW273Fixture::FRAME_BYTES,
    mark_format: mark_format,
    variant_discriminator_mode: discriminator_mode,
  )
end

private def w273_assert_literals(
  actual : Array(CrystalClick::StorageColumnValue),
  expected : Array(String?),
) : Nil
  actual.size.should eq(expected.size)
  fixture = CompactPartWriterW273Fixture
  actual.each_with_index do |value, index|
    expected_literal = expected[index]
    fixture.literal_for(value, 2).should eq(expected_literal)

    payload = value.object_document.value_for(CompactPartWriterW273Fixture::PAYLOAD_PATH)
    payload.type.should eq(fixture.dynamic_type)
    if expected_literal
      payload.is_null?.should be_false
      payload.child_count.should eq(1)
      payload.child_at(0).type.should eq(fixture.array_chain_type(2))
    else
      payload.is_null?.should be_true
    end
  end
  nil
end

private def w273_assert_marks(
  actual : Array(Array(CrystalClick::StorageColumnValue)),
  first_mark : Int,
  mark_count : Int,
) : Nil
  fixture = CompactPartWriterW273Fixture
  actual.size.should eq(mark_count)
  actual.each { |mark_rows| mark_rows.size.should eq(CompactPartWriterW273Fixture::ROWS_PER_MARK) }

  expected_row_start = first_mark * CompactPartWriterW273Fixture::ROWS_PER_MARK
  expected_row_count = mark_count * CompactPartWriterW273Fixture::ROWS_PER_MARK
  w273_assert_literals(
    actual.flatten,
    fixture.expected_literals(2)[expected_row_start, expected_row_count],
  )

  expected_size_vectors = fixture.expected_mark_array_size_vectors(2)[first_mark, mark_count]
  actual.each_with_index do |mark_rows, offset|
    fixture.array_size_vectors_for_mark(mark_rows, 2).should eq(expected_size_vectors[offset])
  end

  actual.map do |mark_rows|
    mark_rows.count { |row| !fixture.literal_for(row, 2).nil? }
  end.should eq(fixture.expected_mark_actual_counts(2)[first_mark, mark_count])

  observed_array_element_counts = Array(Array(Int32)).new(2) { [] of Int32 }
  observed_json_element_counts = [] of Int32
  actual.each do |mark_rows|
    vectors = fixture.array_size_vectors_for_mark(mark_rows, 2)
    2.times { |level| observed_array_element_counts[level] << vectors[level].sum }
    observed_json_element_counts << vectors[1].sum
  end
  expected_array_element_counts = fixture.expected_mark_array_element_counts(2).map do |per_mark|
    per_mark[first_mark, mark_count]
  end
  observed_array_element_counts.should eq(expected_array_element_counts)
  observed_json_element_counts.should eq(fixture.expected_mark_json_element_counts(2)[first_mark, mark_count])
  nil
end

describe CrystalClick::CompactPartWriter do
  it "round trips a depth-two typed-Dynamic nested Array(JSON) actual through public readers" do
    fixture = CompactPartWriterW273Fixture
    # The common-codec control must pass first, so a public-path failure is
    # attributable to Compact admission or physical readback, not a bad fixture.
    fixture.common_codec_roundtrip!(2)

    parent = File.tempname("crystal-click-w273-public-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      w273_write_depth_two(
        part_path,
        CrystalClick::CompactMarkFormat::Mrk3,
        CrystalClick::CompactVariantDiscriminatorMode::Basic,
      ).should eq(part_path)
      File.exists?(part_path).should be_true

      windows = [
        {0, CompactPartWriterW273Fixture::MARK_COUNT},
        {1, 2},
        {1, 1},
        {2, 1},
        {3, 1},
        {CompactPartWriterW273Fixture::MARK_COUNT, 0},
      ]

      recursive = CrystalClick::CompactRecursiveJsonColumnReader.open(
        part_path,
        CompactPartWriterW273Fixture::COLUMN_NAME,
        fixture.schema,
      )
      recursive.schema_declaration.should eq(fixture.schema.declaration)
      recursive.mark_count.should eq(CompactPartWriterW273Fixture::MARK_COUNT)
      recursive.row_count.should eq(CompactPartWriterW273Fixture::ROW_COUNT.to_u64)
      recursive.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
      windows.each do |first_mark, mark_count|
        w273_assert_marks(recursive.read_marks(first_mark, mark_count), first_mark, mark_count)
      end
      recursive.read_marks(CompactPartWriterW273Fixture::MARK_COUNT, 0).should eq([] of Array(CrystalClick::StorageColumnValue))
      empty_mark = recursive.read_marks(2, 1)[0]
      fixture.literal_for(empty_mark[0], 2).should eq("[]")
      fixture.literal_for(empty_mark[1], 2).should eq("[[]]")

      static_root = CrystalClick::CompactStaticJsonBulkColumnReader.open(
        part_path,
        CompactPartWriterW273Fixture::COLUMN_NAME,
        fixture.declared_json_type,
      )
      static_root.schema_declaration.should eq(fixture.declared_json_type.name)
      static_root.mark_count.should eq(CompactPartWriterW273Fixture::MARK_COUNT)
      static_root.row_count.should eq(CompactPartWriterW273Fixture::ROW_COUNT.to_u64)
      static_root.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
      windows.each do |first_mark, mark_count|
        documents = static_root.read_marks(first_mark, mark_count)
        values = documents.map do |mark|
          mark.map { |document| CrystalClick::StorageColumnValue.object_document(document) }
        end
        w273_assert_marks(values, first_mark, mark_count)
      end
      static_root.read_marks(CompactPartWriterW273Fixture::MARK_COUNT, 0).should eq([] of Array(CrystalClick::ObjectDocument))
      static_empty_mark = static_root.read_marks(2, 1)[0]
      fixture.literal_for(CrystalClick::StorageColumnValue.object_document(static_empty_mark[0]), 2).should eq("[]")
      fixture.literal_for(CrystalClick::StorageColumnValue.object_document(static_empty_mark[1]), 2).should eq("[[]]")
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
