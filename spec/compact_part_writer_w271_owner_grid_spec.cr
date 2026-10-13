require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w271_fixture"

private alias W271OGLeafPlan = Tuple(
  CrystalClick::BinaryDynamicJsonLeafKey,
  CrystalClick::ObjectDocumentPlan,
)

private module CompactPartWriterW271OwnerGridFixture
  extend self

  COLUMN_NAME = "typed_dynamic_json_siblings"
  LEFT_PATH   = "left"
  RIGHT_PATH  = "right"

  def declared_json_type : CrystalClick::BinaryDataType
    dynamic = CompactPartWriterW271Fixture.dynamic_type
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 1,
      typed_paths: {
        LEFT_PATH  => dynamic,
        RIGHT_PATH => dynamic,
      } of String => CrystalClick::BinaryDataType,
    )
  end

  def schema : CrystalClick::StorageColumnSchema
    CrystalClick::CompactJsonColumnAdapter.schema_for_json_declaration(declared_json_type.name) ||
      raise CrystalClick::UnsupportedFormatError.new("W271 sibling fixture JSON declaration is not admitted")
  end

  def actuals : CrystalClick::DynamicStructure
    CrystalClick::DynamicStructure.new(
      [CompactPartWriterW271Fixture.json_type] of CrystalClick::BinaryDataType,
      CrystalClick::StructureStatistics.new(
        [4_u64, 0_u64] of UInt64,
        [] of CrystalClick::StructureStatistic,
      ),
      version: CrystalClick::DynamicStructure::VERSION_V3,
    )
  end

  private def child_plan : CrystalClick::ObjectDocumentPlan
    CompactPartWriterW271Fixture.json_bindings[CompactPartWriterW271Fixture::PAYLOAD_PATH][0][1]
  end

  private def leaf_binding(
    structure : CrystalClick::DynamicStructure,
    child_plan : CrystalClick::ObjectDocumentPlan,
  ) : W271OGLeafPlan
    json = CompactPartWriterW271Fixture.json_type
    key = CrystalClick::BinaryDynamicJsonLeafKey.new(
      CompactPartWriterW271Fixture::SITE_PATH,
      structure.canonical_index_for(json),
      [] of Int32,
    )
    {key, child_plan}
  end

  def leaf_bindings : Hash(String, Array(W271OGLeafPlan))
    shared_child_plan = child_plan
    left_actuals = actuals
    right_actuals = actuals
    {
      LEFT_PATH  => ([leaf_binding(left_actuals, shared_child_plan)] of W271OGLeafPlan),
      RIGHT_PATH => ([leaf_binding(right_actuals, shared_child_plan)] of W271OGLeafPlan),
    } of String => Array(W271OGLeafPlan)
  end

  def object_plan : CrystalClick::ObjectDocumentPlan
    CrystalClick::ObjectDocumentPlan.new(
      CompactPartWriterW271Fixture.object_plan.structures,
      schema.object_schema.typed_paths,
      {
        LEFT_PATH  => actuals,
        RIGHT_PATH => actuals,
      } of String => CrystalClick::DynamicStructure,
      typed_dynamic_json_object_leaf_plans: leaf_bindings,
    )
  end

  def context : CrystalClick::CompactJsonWriteContext
    CrystalClick::CompactJsonWriteContext.new(
      {CompactPartWriterW271Fixture::SITE_PATH => object_plan} of String => CrystalClick::ObjectDocumentPlan,
    )
  end

  private def json_value(value : UInt8) : CrystalClick::BinaryValue
    fixture = CompactPartWriterW271Fixture
    CrystalClick::BinaryValue.json(
      fixture.json_type,
      CrystalClick::BinaryJsonRow.new(
        fixture.json_type,
        [{
          CompactPartWriterW271Fixture::VALUE_PATH,
          CrystalClick::BinaryValue.fixed(fixture.uint8_type, Bytes[value]),
        }] of Tuple(String, CrystalClick::BinaryValue),
      ),
    )
  end

  private def dynamic_value(value : UInt8?) : CrystalClick::BinaryValue
    child = if selected = value
              json_value(selected)
            else
              nil
            end
    CrystalClick::BinaryValue.dynamic(CompactPartWriterW271Fixture.dynamic_type, child)
  end

  def expected_left : Array(UInt8?)
    [11_u8, nil, nil, nil, 51_u8, 61_u8, nil, 81_u8] of UInt8?
  end

  def expected_right : Array(UInt8?)
    [nil, 22_u8, 31_u8, 41_u8, nil, nil, 71_u8, nil] of UInt8?
  end

  def expected_left_mark_counts : Array(Int32)
    [1, 0, 2, 1]
  end

  def expected_right_mark_counts : Array(Int32)
    [1, 2, 0, 1]
  end

  def rows : Array(CrystalClick::StorageColumnValue)
    left = expected_left
    right = expected_right
    output = Array(CrystalClick::StorageColumnValue).new(CompactPartWriterW271Fixture::ROW_COUNT)
    CompactPartWriterW271Fixture::ROW_COUNT.times do |index|
      document = CrystalClick::ObjectDocument.new({
        LEFT_PATH  => dynamic_value(left[index]),
        RIGHT_PATH => dynamic_value(right[index]),
      } of String => CrystalClick::BinaryValue)
      output << CrystalClick::StorageColumnValue.object_document(document)
    end
    output
  end

  def granules(values : Array(CrystalClick::StorageColumnValue) = rows) : Array(Array(CrystalClick::StorageColumnValue))
    output = Array(Array(CrystalClick::StorageColumnValue)).new(CompactPartWriterW271Fixture::MARK_COUNT)
    CompactPartWriterW271Fixture::MARK_COUNT.times do |mark|
      output << values[mark * CompactPartWriterW271Fixture::ROWS_PER_MARK, CompactPartWriterW271Fixture::ROWS_PER_MARK]
    end
    output
  end

  def column : CrystalClick::CompactPartColumn
    CrystalClick::CompactPartColumn.json(
      COLUMN_NAME,
      schema,
      granules,
      context,
    )
  end

  def common_codec_roundtrip : Array(Array(CrystalClick::ObjectDocument))
    document_granules = granules.map do |mark_rows|
      mark_rows.map(&.object_document)
    end
    streams = CrystalClick::ObjectDocumentCodec.encode(object_plan, document_granules)
    CrystalClick::ObjectDocumentCodec.decode(
      schema.object_schema.typed_paths,
      streams,
      typed_dynamic_json_object_leaf_plans: leaf_bindings,
    )
  end
end

private def w271og_literal(document : CrystalClick::ObjectDocument, path : String) : UInt8?
  fixture = CompactPartWriterW271Fixture
  value = document.value_for(path)
  value.type.should eq(fixture.dynamic_type)
  if value.is_null?
    value.child_count.should eq(0)
    return nil
  end

  value.child_count.should eq(1)
  json = value.child_at(0)
  json.type.should eq(fixture.json_type)
  cell = json.json_row.value_for(CompactPartWriterW271Fixture::VALUE_PATH).not_nil!
  cell.type.should eq(fixture.uint8_type)
  cell.byte_at(0)
end

private def w271og_assert_window(
  actual_marks : Array(Array(CrystalClick::ObjectDocument)),
  first_mark : Int32,
  mark_count : Int32,
) : Nil
  fixture = CompactPartWriterW271OwnerGridFixture
  actual_marks.size.should eq(mark_count)
  expected_row_start = first_mark * CompactPartWriterW271Fixture::ROWS_PER_MARK
  expected_row_count = mark_count * CompactPartWriterW271Fixture::ROWS_PER_MARK
  expected_left = fixture.expected_left[expected_row_start, expected_row_count]
  expected_right = fixture.expected_right[expected_row_start, expected_row_count]
  actual_documents = actual_marks.flatten
  actual_left = actual_documents.map do |document|
    w271og_literal(document, CompactPartWriterW271OwnerGridFixture::LEFT_PATH)
  end
  actual_right = actual_documents.map do |document|
    w271og_literal(document, CompactPartWriterW271OwnerGridFixture::RIGHT_PATH)
  end
  actual_left.should eq(expected_left)
  actual_right.should eq(expected_right)
  actual_marks.map do |mark|
    mark.count { |document| !w271og_literal(document, CompactPartWriterW271OwnerGridFixture::LEFT_PATH).nil? }
  end.should eq(fixture.expected_left_mark_counts[first_mark, mark_count])
  actual_marks.map do |mark|
    mark.count { |document| !w271og_literal(document, CompactPartWriterW271OwnerGridFixture::RIGHT_PATH).nil? }
  end.should eq(fixture.expected_right_mark_counts[first_mark, mark_count])
  nil
end

private def w271og_documents_from_values(
  value_marks : Array(Array(CrystalClick::StorageColumnValue)),
) : Array(Array(CrystalClick::ObjectDocument))
  value_marks.map do |mark|
    mark.map do |value|
      value.object?.should be_true
      value.object_document
    end
  end
end

describe CrystalClick::CompactPartWriter do
  it "keeps sibling typed-Dynamic JSON child grids under their own field roots" do
    fixture = CompactPartWriterW271OwnerGridFixture

    fixture.schema.object_schema.typed_paths.keys.to_a.sort.should eq([
      CompactPartWriterW271OwnerGridFixture::LEFT_PATH,
      CompactPartWriterW271OwnerGridFixture::RIGHT_PATH,
    ])
    typed_paths = fixture.schema.object_schema.typed_paths
    typed_paths[CompactPartWriterW271OwnerGridFixture::LEFT_PATH].should eq(CompactPartWriterW271Fixture.dynamic_type)
    typed_paths[CompactPartWriterW271OwnerGridFixture::RIGHT_PATH].should eq(CompactPartWriterW271Fixture.dynamic_type)
    object_plan = fixture.object_plan
    [
      CompactPartWriterW271OwnerGridFixture::LEFT_PATH,
      CompactPartWriterW271OwnerGridFixture::RIGHT_PATH,
    ].each do |path|
      object_plan.typed_dynamic_site_count_for(path).should eq(1)
      object_plan.typed_dynamic_site_path_at(path, 0).should eq(CompactPartWriterW271Fixture::SITE_PATH)
      actuals = object_plan.typed_dynamic_site_structure_for(path, CompactPartWriterW271Fixture::SITE_PATH)
      actuals.types.map(&.name).should eq([CompactPartWriterW271Fixture.json_type.name])
      actuals.statistics.not_nil!.counts.should eq([4_u64, 0_u64])
      actuals.statistics.not_nil!.shared.should be_empty
    end
    bindings = fixture.leaf_bindings
    bindings.keys.to_a.sort.should eq([
      CompactPartWriterW271OwnerGridFixture::LEFT_PATH,
      CompactPartWriterW271OwnerGridFixture::RIGHT_PATH,
    ])
    bindings[CompactPartWriterW271OwnerGridFixture::LEFT_PATH][0][0].should eq(
      bindings[CompactPartWriterW271OwnerGridFixture::RIGHT_PATH][0][0],
    )
    shared_child_plan = bindings[CompactPartWriterW271OwnerGridFixture::LEFT_PATH][0][1]
    bindings[CompactPartWriterW271OwnerGridFixture::LEFT_PATH][0][1].same?(shared_child_plan).should be_true
    bindings[CompactPartWriterW271OwnerGridFixture::RIGHT_PATH][0][1].same?(shared_child_plan).should be_true
    bindings[CompactPartWriterW271OwnerGridFixture::LEFT_PATH][0][0].dynamic_site.should eq(
      CompactPartWriterW271Fixture::SITE_PATH,
    )
    bindings[CompactPartWriterW271OwnerGridFixture::LEFT_PATH][0][0].descriptor_child_path.should be_empty

    # This control runs before any Compact writer attempt so a bad binding or
    # literal constructor cannot masquerade as a physical-writer refusal.
    common = fixture.common_codec_roundtrip
    common.size.should eq(CompactPartWriterW271Fixture::MARK_COUNT)
    common.each do |mark|
      mark.size.should eq(CompactPartWriterW271Fixture::ROWS_PER_MARK)
    end
    w271og_assert_window(common, 0, CompactPartWriterW271Fixture::MARK_COUNT)

    combinations = [
      {CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::CompactVariantDiscriminatorMode::Basic},
      {CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::CompactVariantDiscriminatorMode::Compact},
      {CrystalClick::CompactMarkFormat::Mrk4, CrystalClick::CompactVariantDiscriminatorMode::Basic},
      {CrystalClick::CompactMarkFormat::Mrk4, CrystalClick::CompactVariantDiscriminatorMode::Compact},
    ]
    windows = [
      {0, CompactPartWriterW271Fixture::MARK_COUNT},
      {1, 2},
      {0, 1},
      {3, 1},
      {1, 1},
      {2, 1},
      {CompactPartWriterW271Fixture::MARK_COUNT, 0},
    ]

    combinations.each do |mark_format, discriminator_mode|
      mark_suffix = mark_format.mrk3? ? "mrk3" : "mrk4"
      mode_suffix = discriminator_mode == CrystalClick::CompactVariantDiscriminatorMode::Basic ? "basic" : "compact"
      parent = File.tempname("crystal-click-w271-owner-grid-#{mark_suffix}-#{mode_suffix}-")
      part_path = File.join(parent, "all_1_1_0")
      begin
        Dir.mkdir(parent)
        CrystalClick::CompactPartWriter.write_uint64_columns(
          part_path,
          CompactPartWriterW271Fixture::KEY_NAME,
          CompactPartWriterW271Fixture::KEYS,
          [fixture.column] of CrystalClick::CompactPartColumn,
          rows_per_mark: CompactPartWriterW271Fixture::ROWS_PER_MARK,
          frame_bytes: CompactPartWriterW271Fixture::FRAME_BYTES,
          mark_format: mark_format,
          variant_discriminator_mode: discriminator_mode,
        ).should eq(part_path)

        recursive = CrystalClick::CompactRecursiveJsonColumnReader.open(
          part_path,
          CompactPartWriterW271OwnerGridFixture::COLUMN_NAME,
          fixture.schema,
        )
        recursive.schema_declaration.should eq(fixture.schema.declaration)
        recursive.mark_count.should eq(CompactPartWriterW271Fixture::MARK_COUNT)
        recursive.row_count.should eq(CompactPartWriterW271Fixture::ROW_COUNT.to_u64)
        recursive.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
        windows.each do |first_mark, mark_count|
          w271og_assert_window(
            w271og_documents_from_values(recursive.read_marks(first_mark, mark_count)),
            first_mark,
            mark_count,
          )
        end
        left_zero = recursive.read_marks(1, 1)
        left_zero.size.should eq(1)
        left_zero[0].size.should eq(CompactPartWriterW271Fixture::ROWS_PER_MARK)
        right_zero = recursive.read_marks(2, 1)
        right_zero.size.should eq(1)
        right_zero[0].size.should eq(CompactPartWriterW271Fixture::ROWS_PER_MARK)
        recursive.read_marks(recursive.mark_count, 0).should be_empty

        static_root = CrystalClick::CompactStaticJsonBulkColumnReader.open(
          part_path,
          CompactPartWriterW271OwnerGridFixture::COLUMN_NAME,
          fixture.declared_json_type,
        )
        static_root.schema_declaration.should eq(fixture.declared_json_type.name)
        static_root.mark_count.should eq(CompactPartWriterW271Fixture::MARK_COUNT)
        static_root.row_count.should eq(CompactPartWriterW271Fixture::ROW_COUNT.to_u64)
        static_root.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
        windows.each do |first_mark, mark_count|
          w271og_assert_window(static_root.read_marks(first_mark, mark_count), first_mark, mark_count)
        end
        static_root.read_marks(static_root.mark_count, 0).should be_empty
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end
end
