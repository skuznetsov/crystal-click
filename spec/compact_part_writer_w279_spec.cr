require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w279_fixture"

alias W279DynamicSiteMap = Hash(String, CrystalClick::DynamicStructure)
alias W279NestedDynamicSiteMap = Hash(String, W279DynamicSiteMap)

private def w279_expected_selected?(depth : Int, row : Int) : Bool
  case depth
  when 0 then [true, false, false, false, true, false, false, true][row]
  when 2 then [true, false, false, false, true, true, false, true][row]
  when 3 then [true, false, false, false, true, true, true, true][row]
  else        raise ArgumentError.new("unsupported W279 depth")
  end
end

private def w279_expected_shape(depth : Int, row : Int) : String
  case depth
  when 0
    case row
    when 0 then "11"
    when 4 then "82"
    when 7 then "83"
    else        ""
    end
  when 2
    ["[[11,12],[13]]", "", "", "", "[]", "[[]]", "", "[[81],[82,83],[]]"][row]
  when 3
    ["[[[11,12],[]],[[13,14]]]", "", "", "", "[]", "[[]]", "[[[]]]", "[[[81]],[[82,83],[]],[]]"][row]
  else
    raise ArgumentError.new("unsupported W279 depth")
  end
end

private def w279_shape(value : CrystalClick::BinaryValue, depth : Int) : String
  if depth == 0
    value.json_row.value_for("id").not_nil!.as_uint64.to_s
  else
    "[#{value.elements.map { |child| w279_shape(child, depth - 1) }.join(",")}]"
  end
end

private def w279_collect_leaf_rows(
  value : CrystalClick::BinaryValue,
  depth : Int,
  output : Array(CrystalClick::BinaryJsonRow),
) : Nil
  if depth == 0
    output << value.json_row
  else
    value.elements.each { |child| w279_collect_leaf_rows(child, depth - 1, output) }
  end
  nil
end

private def w279_shared_index(id : UInt64) : Int32
  case id
  when 11_u64 then 0
  when 12_u64 then 1
  when 13_u64 then 5
  when 14_u64 then 2
  when 81_u64 then 4
  when 82_u64 then 3
  when 83_u64 then 6
  else             raise ArgumentError.new("unknown W279 JSON row")
  end
end

private def w279_expected_shared_value(path : String, id : UInt64) : String
  row = w279_shared_index(id)
  return "" if path == "alpha" && row == 0
  return CompactPartWriterW279Fixture::LONG_STRING if path == "alpha" && row == 3
  return String.new(Bytes[0x00_u8, 0xff_u8, 0x80_u8, 0x41_u8]) if path == "aa" && row == 1
  return "shared\0nul" if path == "beta" && row == 5

  "#{path}-shared-#{row}"
end

private def w279_assert_documents(
  documents : Array(CrystalClick::ObjectDocument),
  depth : Int,
  first_row : Int,
) : Nil
  expected_window_rows = first_row == 0 ? CompactPartWriterW279Fixture::ROW_COUNT : 4
  documents.size.should eq(expected_window_rows)
  documents.each_with_index do |document, offset|
    row_index = first_row + offset
    actual = document.value_for(CompactPartWriterW279Fixture::PAYLOAD_PATH)
    actual.type.should eq(CompactPartWriterW279Fixture.dynamic_type)
    selected = w279_expected_selected?(depth, row_index)
    actual.is_null?.should eq(!selected)
    if selected
      actual.child_count.should eq(1)
      value = actual.child_at(0)
      w279_shape(value, depth).should eq(w279_expected_shape(depth, row_index))
      leaves = [] of CrystalClick::BinaryJsonRow
      w279_collect_leaf_rows(value, depth, leaves)
      expected_ids = CompactPartWriterW279Fixture.expected_leaf_ids(depth)[row_index]
      leaves.map { |leaf| leaf.value_for("id").not_nil!.as_uint64 }.should eq(expected_ids)
      leaves.each do |leaf|
        id = leaf.value_for("id").not_nil!.as_uint64
        leaf.value_for("label").not_nil!.as_string.should eq("child-#{id}")
        CompactPartWriterW279Fixture::SHARED_PATHS.each do |path|
          shared = leaf.value_for(path).not_nil!
          shared.type.should eq(CompactPartWriterW279Fixture.string_type)
          shared.as_string.should eq(w279_expected_shared_value(path, id))
        end
      end
    else
      actual.child_count.should eq(0)
    end
  end
  nil
end

private def w279_assert_reader_windows(
  part_path : String,
  depth : Int,
  profile : CrystalClick::BinaryBulkProfile,
) : Nil
  fixture = CompactPartWriterW279Fixture
  recursive = CrystalClick::CompactRecursiveJsonColumnReader.open(
    part_path,
    CompactPartWriterW279Fixture::COLUMN_NAME,
    fixture.schema,
  )
  recursive.mark_count.should eq(CompactPartWriterW279Fixture::MARK_COUNT)
  recursive.row_count.should eq(CompactPartWriterW279Fixture::ROW_COUNT.to_u64)
  recursive.ordinary_profile.should eq(profile)
  w279_assert_documents(recursive.read_marks(0, recursive.mark_count).flatten.map(&.object_document), depth, 0)
  w279_assert_documents(recursive.read_marks(1, 2).flatten.map(&.object_document), depth, 2)
  recursive.read_marks(recursive.mark_count, 0).should be_empty

  static = CrystalClick::CompactStaticJsonBulkColumnReader.open(
    part_path,
    CompactPartWriterW279Fixture::COLUMN_NAME,
    fixture.declared_json_type,
  )
  static.mark_count.should eq(CompactPartWriterW279Fixture::MARK_COUNT)
  static.row_count.should eq(CompactPartWriterW279Fixture::ROW_COUNT.to_u64)
  static.ordinary_profile.should eq(profile)
  w279_assert_documents(static.read_marks(0, static.mark_count).flatten, depth, 0)
  w279_assert_documents(static.read_marks(1, 2).flatten, depth, 2)
  static.read_marks(static.mark_count, 0).should be_empty
  nil
end

private def w279_matrix_cell(
  depth : Int,
  shared_data_version : UInt64,
  profile : CrystalClick::BinaryBulkProfile,
  mark_format : CrystalClick::CompactMarkFormat,
  compress_marks : Bool,
  discriminator_mode : CrystalClick::CompactVariantDiscriminatorMode,
) : Nil
  fixture = CompactPartWriterW279Fixture
  parent = File.tempname("crystal-click-w279-focused-")
  part_path = File.join(parent, "all_1_1_0")
  begin
    Dir.mkdir(parent)
    CrystalClick::CompactPartWriter.write_uint64_columns(
      part_path,
      CompactPartWriterW279Fixture::KEY_NAME,
      fixture.keys,
      [fixture.column(depth, shared_data_version)] of CrystalClick::CompactPartColumn,
      rows_per_mark: CompactPartWriterW279Fixture::ROWS_PER_MARK,
      frame_bytes: 64,
      mark_format: mark_format,
      variant_discriminator_mode: discriminator_mode,
      compress_marks: compress_marks,
      profile: profile,
    ).should eq(part_path)

    physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
    physical.mode.should eq(mark_format)
    physical.row_count.should eq(CompactPartWriterW279Fixture::ROW_COUNT.to_u64)
    physical.granule_count.should eq(CompactPartWriterW279Fixture::MARK_COUNT)
    physical.mark_row_counts.should eq(Array(UInt64).new(CompactPartWriterW279Fixture::MARK_COUNT, 2_u64))
    mark_entry = CrystalClick::PartChecksums.open(part_path).entry(physical.marks_name).not_nil!
    mark_entry.compressed.should eq(compress_marks)
    w279_assert_reader_windows(part_path, depth, profile)
  ensure
    FileUtils.rm_rf(parent)
  end
  nil
end

describe "W279 typed-Dynamic JSON child readers and shared layouts" do
  it "keeps child-free legacy Object prefixes outside the nested JSON admission gate" do
    profile = CrystalClick::BinaryBulkProfile.single_stream
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    statistics = CrystalClick::StructureStatistics.new(
      [] of UInt64,
      [] of CrystalClick::StructureStatistic,
    )
    object = CrystalClick::ObjectStructure.new(
      [] of String,
      version: 2_u64,
      shared_data_version: 0_u64,
      bucket_count: 1_u64,
      statistics: statistics,
    )
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      object,
      Hash(String, CrystalClick::DynamicStructure).new,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(
      structures,
      Hash(String, CrystalClick::BinaryDataType).new,
    )
    physical = CrystalClick::ObjectDocumentPhysicalPlan.from_escaped_prefix(
      "root",
      plan,
      profile,
      profile,
      limits,
    )
    empty_prefix_map = Hash(
      String,
      CrystalClick::ObjectSharedPathJsonTapeCodec::PrefixMap,
    ).new
    prefix = CrystalClick::ObjectDocumentCallbackPrefix.new(
      CrystalClick::BinaryDataType.json(
        max_dynamic_paths: 0,
        max_dynamic_types: 0,
        typed_paths: Hash(String, CrystalClick::BinaryDataType).new,
      ),
      0_i32,
      0_i32,
      0_i32,
      "root",
      "root",
      0_u64,
      CrystalClick::ObjectSharedNestedSerializationContext.for_read(0_u64, profile),
      0_i32,
      CrystalClick::ObjectDocumentCallbackPrefix::StatisticsContext::PrefixOnly,
      Hash(String, Int32).new,
      plan,
      structures,
      [] of Tuple(String, Bytes),
      W279NestedDynamicSiteMap.new,
      W279NestedDynamicSiteMap.new,
      Hash(String, CrystalClick::BinaryDynamicBulkPlan).new,
      Hash(String, CrystalClick::BinaryDynamicBulkPlan).new,
      empty_prefix_map,
      Hash(String, CrystalClick::ObjectSharedPathJsonTapeCodec::PrefixMap).new,
    )
    prefix.bind_physical_plan!(physical)

    CrystalClick::ObjectDocumentTypedDynamicJsonReadContext.from_prefix(
      prefix,
      CrystalClick::BinaryCodecBudget.new(limits, false),
    ).should be_nil
  end

  it "preserves the child-free fast path for every sealed Object V3 shared layout" do
    profile = CrystalClick::BinaryBulkProfile.single_stream
    limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
    [0_u64, 1_u64, 2_u64, 3_u64].each do |shared_version|
      statistics = CrystalClick::StructureStatistics.new(
        [] of UInt64,
        [] of CrystalClick::StructureStatistic,
      )
      object = CrystalClick::ObjectStructure.new(
        [] of String,
        version: 4_u64,
        shared_data_version: shared_version,
        bucket_count: CompactPartWriterW279Fixture.bucket_count_for(shared_version),
        statistics: statistics,
      )
      structures = CrystalClick::ObjectDynamicStructureSet.new(
        object,
        Hash(String, CrystalClick::DynamicStructure).new,
      )
      plan = CrystalClick::ObjectDocumentPlan.new(
        structures,
        Hash(String, CrystalClick::BinaryDataType).new,
      )
      physical = CrystalClick::ObjectDocumentPhysicalPlan.from_escaped_prefix(
        "root",
        plan,
        profile,
        profile,
        limits,
      )
      empty_prefix_map = Hash(
        String,
        CrystalClick::ObjectSharedPathJsonTapeCodec::PrefixMap,
      ).new
      prefix = CrystalClick::ObjectDocumentCallbackPrefix.new(
        CrystalClick::BinaryDataType.json(
          max_dynamic_paths: 0,
          max_dynamic_types: 0,
          typed_paths: Hash(String, CrystalClick::BinaryDataType).new,
        ),
        0_i32,
        0_i32,
        0_i32,
        "root",
        "root",
        0_u64,
        CrystalClick::ObjectSharedNestedSerializationContext.for_read(shared_version, profile),
        0_i32,
        CrystalClick::ObjectDocumentCallbackPrefix::StatisticsContext::PrefixOnly,
        Hash(String, Int32).new,
        plan,
        structures,
        [] of Tuple(String, Bytes),
        W279NestedDynamicSiteMap.new,
        W279NestedDynamicSiteMap.new,
        Hash(String, CrystalClick::BinaryDynamicBulkPlan).new,
        Hash(String, CrystalClick::BinaryDynamicBulkPlan).new,
        empty_prefix_map,
        Hash(String, CrystalClick::ObjectSharedPathJsonTapeCodec::PrefixMap).new,
      )
      prefix.bind_physical_plan!(physical)

      CrystalClick::ObjectDocumentTypedDynamicJsonReadContext.from_prefix(
        prefix,
        CrystalClick::BinaryCodecBudget.new(limits, false),
      ).should be_nil
    end
  end

  it "round-trips direct JSON and Array-chain depths across both readers and physical variants" do
    depths = [0, 2, 3]
    shared_versions = [0_u64, 1_u64, 2_u64, 3_u64]
    profiles = [
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::BinaryBulkProfile.with_size_stream,
    ] of CrystalClick::BinaryBulkProfile
    mark_formats = [CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::CompactMarkFormat::Mrk4]
    discriminator_modes = [
      CrystalClick::CompactVariantDiscriminatorMode::Basic,
      CrystalClick::CompactVariantDiscriminatorMode::Compact,
    ]
    cases = 0

    depths.each do |depth|
      shared_versions.each do |shared_version|
        profiles.each do |profile|
          mark_formats.each do |mark_format|
            [false, true].each do |compress_marks|
              discriminator_modes.each do |discriminator_mode|
                w279_matrix_cell(depth, shared_version, profile, mark_format, compress_marks, discriminator_mode)
                cases += 1
              end
            end
          end
        end
      end
    end

    cases.should eq(192)
  end

  it "keeps the independent mark-local actual-arm count oracle distinct from JSON leaf counts" do
    fixture = CompactPartWriterW279Fixture
    fixture.expected_mark_actual_counts(0).should eq([1, 0, 1, 1])
    fixture.expected_mark_actual_counts(2).should eq([1, 0, 2, 1])
    fixture.expected_mark_actual_counts(3).should eq([1, 0, 2, 2])
    fixture.expected_leaf_ids(2).map(&.size).should eq([3, 0, 0, 0, 0, 0, 0, 3])
    fixture.expected_leaf_ids(3).map(&.size).should eq([4, 0, 0, 0, 0, 0, 0, 3])
  end
end
