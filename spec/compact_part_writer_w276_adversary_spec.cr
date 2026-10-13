require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w276_fixture"

private def w276_adv_assert_no_side_effect(parent : String, target : String) : Nil
  File.exists?(target).should be_false
  Dir.children(parent).sort.should eq(["keep.txt"])
  File.read(File.join(parent, "keep.txt")).should eq("unrelated")
  nil
end

private def w276_adv_write_fixture(
  target : String,
  profile : CrystalClick::BinaryBulkProfile,
  transport_limits : CrystalClick::CompressedStreamLimits = CrystalClick::CompressedStreamLimits.new,
) : String
  CrystalClick::CompactPartWriter.write_uint64_columns(
    target,
    CompactPartWriterW276Fixture::KEY_NAME,
    CompactPartWriterW276Fixture.keys,
    CompactPartWriterW276Fixture.columns,
    rows_per_mark: CompactPartWriterW276Fixture::ROWS_PER_MARK,
    frame_bytes: CompactPartWriterW276Fixture::FRAME_BYTES,
    mark_format: CrystalClick::CompactMarkFormat::Mrk4,
    profile: profile,
    transport_limits: transport_limits,
  )
end

private def w276_adv_lc_snapshot(part_path : String) : Tuple(Array(String), Array(Array(Tuple(String, Array(UInt8)))))
  physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
  roster = physical.physical_roster
    .select { |slot| slot.column_name == "lc_text" }
    .map { |slot| slot.stream_name || "" }
  granules = physical.read_window("lc_text", 0, 4).granules.map do |granule|
    granule.shards.map do |shard|
      {shard.stream_name || "", shard.bytes.to_a}
    end
  end
  {roster, granules}
end

private def w276_adv_static_input(
  name : String,
  type : CrystalClick::BinaryDataType,
  profile : CrystalClick::BinaryBulkProfile,
) : CrystalClick::CompactStaticColumnInput
  value = if type.tag == CrystalClick::BinaryDataType::TAG_UINT64
            CrystalClick::BinaryValue.uint64(1_u64)
          else
            CrystalClick::BinaryValue.string("x")
          end
  granules = [[value] of CrystalClick::BinaryValue] of Array(CrystalClick::BinaryValue)
  CrystalClick::CompactStaticColumnInput.new(name, type, granules, profile)
end

private def w276_adv_construct_metadata(
  selected_profile : CrystalClick::BinaryBulkProfile,
  key_plan_profile : CrystalClick::BinaryBulkProfile,
  metadata_value_profiles : Array(CrystalClick::BinaryBulkProfile),
  plan_value_profiles : Array(CrystalClick::BinaryBulkProfile),
) : CrystalClick::CompactPartMetadata
  unless metadata_value_profiles.size == plan_value_profiles.size
    raise ArgumentError.new("W276 metadata fixture profile grids differ")
  end

  string_type = CrystalClick::BinaryDataType.primitive("String")
  key_type = CrystalClick::BinaryDataType.primitive("UInt64")
  metadata_values = Array(CrystalClick::CompactStaticColumnInput).new(metadata_value_profiles.size)
  plan_inputs = [
    w276_adv_static_input("pk", key_type, key_plan_profile),
  ] of CrystalClick::CompactStaticColumnInput
  metadata_value_profiles.each_with_index do |profile, index|
    name = "text#{index}"
    metadata_values << w276_adv_static_input(name, string_type, profile)
    plan_inputs << w276_adv_static_input(name, string_type, plan_value_profiles[index])
  end

  limits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS
  write_plan = CrystalClick::CompactStaticWritePlan.new(
    plan_inputs,
    limits,
    CrystalClick::CompactMarkFormat::Mrk4,
  )
  CrystalClick::CompactPartMetadata.new(
    "pk",
    metadata_values,
    1_u64,
    limits,
    CrystalClick::BinaryCodecBudget.new(limits, true),
    CrystalClick::CompressedStreamBudget.new(CrystalClick::CompressedStreamLimits.new, true),
    write_plan,
    false,
    selected_profile,
  )
end

describe "W276 propagated String1 Compact writer adversaries" do
  it "rejects metadata inputs and callback plans that disagree with the selected profile" do
    single = CrystalClick::BinaryBulkProfile.single_stream
    sized = CrystalClick::BinaryBulkProfile.with_size_stream

    # The callback plan's key can disagree independently of all value inputs
    # and callbacks. Metadata must not publish String1 JSON over a String0 key
    # callback.
    expect_raises(CrystalClick::UnsupportedFormatError) do
      w276_adv_construct_metadata(sized, single, [sized] of CrystalClick::BinaryBulkProfile,
        [sized] of CrystalClick::BinaryBulkProfile)
    end

    # Static metadata inputs all claim String1, but one value callback still
    # belongs to String0. This also checks a mixed callback plan.
    expect_raises(CrystalClick::UnsupportedFormatError) do
      w276_adv_construct_metadata(sized, sized,
        [sized, sized] of CrystalClick::BinaryBulkProfile,
        [sized, single] of CrystalClick::BinaryBulkProfile)
    end

    # Every metadata input must match the selected profile, independently of
    # whether its detached callback plan matches.
    expect_raises(CrystalClick::UnsupportedFormatError) do
      w276_adv_construct_metadata(sized, sized,
        [sized, single] of CrystalClick::BinaryBulkProfile,
        [sized, sized] of CrystalClick::BinaryBulkProfile)
    end
  end

  it "keeps LowCardinality(String) byte-identical to String0 while sizing ordinary String" do
    parent = File.tempname("crystal-click-w276-low-cardinality-")
    single_path = File.join(parent, "single")
    sized_path = File.join(parent, "sized")
    begin
      Dir.mkdir(parent)
      w276_adv_write_fixture(single_path, CrystalClick::BinaryBulkProfile.single_stream).should eq(single_path)
      w276_adv_write_fixture(sized_path, CrystalClick::BinaryBulkProfile.with_size_stream).should eq(sized_path)

      single_lc = w276_adv_lc_snapshot(single_path)
      sized_lc = w276_adv_lc_snapshot(sized_path)
      single_lc.should eq(sized_lc)
      sized_lc[0].should eq(["lc_text.dict_prefix", "lc_text.dict", "lc_text"])

      physical = CrystalClick::CompactPartPhysicalContext.open(sized_path)
      physical.physical_roster.select { |slot| slot.column_name == "text" }
        .map { |slot| slot.stream_name || "" }.should eq(["text.size", "text"])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "retains the first empty String size value and zero-occurrence callbacks" do
    parent = File.tempname("crystal-click-w276-empty-string-callback-")
    part_path = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      w276_adv_write_fixture(part_path, CrystalClick::BinaryBulkProfile.with_size_stream).should eq(part_path)
      physical = CrystalClick::CompactPartPhysicalContext.open(part_path)

      # Mark zero contains one empty non-NULL String child: its size callback
      # is present and encodes the logical length zero, while data is empty.
      first_empty = physical.read_window("string_array", 0, 1).granules.first.shards
      first_empty.map { |shard| shard.stream_name || "" }.should eq(
        [
          "string_array%2Eitems.size0",
          "string_array%2Eitems.null",
          "string_array%2Eitems.size",
          "string_array%2Eitems",
        ],
      )
      first_empty[2].bytes.should eq(Bytes.new(8, 0_u8))
      first_empty[3].bytes.should be_empty

      # Mark two has no String occurrences at all; MRK4 still carries the
      # callbacks with zero extent instead of dropping the physical slots.
      no_occurrences = physical.read_window("string_array", 2, 1).granules.first.shards
      no_occurrences.map { |shard| shard.stream_name || "" }.should eq(
        [
          "string_array%2Eitems.size0",
          "string_array%2Eitems.null",
          "string_array%2Eitems.size",
          "string_array%2Eitems",
        ],
      )
      no_occurrences[2].bytes.should be_empty
      no_occurrences[3].bytes.should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps root Array(Nullable(String)) outside the typed carrier for both String profiles" do
    string_type = CrystalClick::BinaryDataType.primitive("String")
    nullable_string_type = CrystalClick::BinaryDataType.nullable(string_type)
    array_type = CrystalClick::BinaryDataType.array(nullable_string_type)
    rows = Array(CrystalClick::BinaryValue).new(CompactPartWriterW276Fixture::ROW_COUNT)
    CompactPartWriterW276Fixture::ROW_COUNT.times do |index|
      elements = if index.even?
                   [] of CrystalClick::BinaryValue
                 else
                   [
                     CrystalClick::BinaryValue.nullable(
                       nullable_string_type,
                       CrystalClick::BinaryValue.string("root-array"),
                     ),
                   ] of CrystalClick::BinaryValue
                 end
      rows << CrystalClick::BinaryValue.array(array_type, elements)
    end
    granules = rows.each_slice(CompactPartWriterW276Fixture::ROWS_PER_MARK).map(&.to_a).to_a
    column = CrystalClick::CompactPartColumn.binary_bulk("root_array", array_type, granules)

    [
      CrystalClick::BinaryBulkProfile.single_stream,
      CrystalClick::BinaryBulkProfile.with_size_stream,
    ].each_with_index do |profile, profile_index|
      parent = File.tempname("crystal-click-w276-root-array-#{profile_index}-")
      target = File.join(parent, "all_1_1_0")
      begin
        Dir.mkdir(parent)
        File.write(File.join(parent, "keep.txt"), "unrelated")
        error = expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::CompactPartWriter.write_uint64_columns(
            target,
            CompactPartWriterW276Fixture::KEY_NAME,
            CompactPartWriterW276Fixture.keys,
            [column] of CrystalClick::CompactPartColumn,
            rows_per_mark: CompactPartWriterW276Fixture::ROWS_PER_MARK,
            frame_bytes: CompactPartWriterW276Fixture::FRAME_BYTES,
            mark_format: CrystalClick::CompactMarkFormat::Mrk4,
            profile: profile,
          )
        end
        error.message.should eq("Compact selected type has no established typed batch carrier")
        w276_adv_assert_no_side_effect(parent, target)
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "fails a tiny transport-result budget without leaving stage artifacts" do
    parent = File.tempname("crystal-click-w276-result-budget-")
    target = File.join(parent, "all_1_1_0")
    begin
      Dir.mkdir(parent)
      File.write(File.join(parent, "keep.txt"), "unrelated")
      expect_raises(CrystalClick::UnsupportedFormatError) do
        w276_adv_write_fixture(
          target,
          CrystalClick::BinaryBulkProfile.with_size_stream,
          CrystalClick::CompressedStreamLimits.new(max_result_bytes: 1),
        )
      end
      w276_adv_assert_no_side_effect(parent, target)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
