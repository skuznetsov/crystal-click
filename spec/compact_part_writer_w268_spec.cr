require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w268_fixture"

private def w268_write_fixture(
  part_path : String,
  fixture_columns : Array(CrystalClick::CompactPartColumn),
  mark_format : CrystalClick::CompactMarkFormat,
  discriminator_mode : CrystalClick::CompactVariantDiscriminatorMode,
  limits : CrystalClick::BinaryCodecLimits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
) : String
  CrystalClick::CompactPartWriter.write_uint64_columns(
    part_path,
    CompactPartWriterW268Fixture::KEY_NAME,
    CompactPartWriterW268Fixture.keys,
    fixture_columns,
    rows_per_mark: CompactPartWriterW268Fixture::ROWS_PER_MARK,
    frame_bytes: CompactPartWriterW268Fixture::FRAME_BYTES,
    limits: limits,
    mark_format: mark_format,
    variant_discriminator_mode: discriminator_mode,
  )
end

private def w268_read_structure_prefix(
  window : CrystalClick::CompactPartPhysicalWindow,
  mark_index : Int,
) : CrystalClick::DynamicStructure
  mark = window.granules[mark_index]
  shards = mark.shards.select do |shard|
    shard.stream_name.try(&.ends_with?(".dynamic_structure")) == true
  end
  shards.size.should eq(1)
  CrystalClick::DynamicStructureCodec.decode(shards[0].bytes)
end

describe CrystalClick::CompactPartWriter do
  it "round trips independent Dynamic sites over full, middle, last, and empty windows" do
    fixture = CompactPartWriterW268Fixture
    [
      {CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::CompactVariantDiscriminatorMode::Basic},
      {CrystalClick::CompactMarkFormat::Mrk3, CrystalClick::CompactVariantDiscriminatorMode::Compact},
      {CrystalClick::CompactMarkFormat::Mrk4, CrystalClick::CompactVariantDiscriminatorMode::Basic},
      {CrystalClick::CompactMarkFormat::Mrk4, CrystalClick::CompactVariantDiscriminatorMode::Compact},
    ].each do |mark_format, discriminator_mode|
      suffix = mark_format == CrystalClick::CompactMarkFormat::Mrk3 ? "mrk3" : "mrk4"
      mode_suffix = discriminator_mode == CrystalClick::CompactVariantDiscriminatorMode::Basic ? "basic" : "compact"
      parent = File.tempname("crystal-click-w268-#{suffix}-#{mode_suffix}-")
      part_path = File.join(parent, "all_1_1_0")
      begin
        Dir.mkdir(parent)
        w268_write_fixture(
          part_path,
          fixture.columns,
          mark_format,
          discriminator_mode,
        ).should eq(part_path)

        {
          CompactPartWriterW268Fixture::ROOT_COLUMN => CompactPartWriterW268Fixture::ROOT_SIGNATURES,
          CompactPartWriterW268Fixture::CTX_COLUMN  => CompactPartWriterW268Fixture::CTX_SIGNATURES,
        }.each do |column_name, expected|
          type = column_name == CompactPartWriterW268Fixture::ROOT_COLUMN ? fixture.root_type : fixture.ctx_type
          reader = CrystalClick::CompactDynamicBulkColumnReader.open(part_path, column_name, type)
          reader.mark_count.should eq(CompactPartWriterW268Fixture::MARK_COUNT)

          [
            {0, CompactPartWriterW268Fixture::MARK_COUNT},
            {2, 2},
            {CompactPartWriterW268Fixture::MARK_COUNT - 1, 1},
            {CompactPartWriterW268Fixture::MARK_COUNT, 0},
          ].each do |first_mark, mark_count|
            actual = fixture.signature(column_name, reader.read_marks(first_mark, mark_count).flatten)
            expected_rows = if first_mark == CompactPartWriterW268Fixture::MARK_COUNT
                              [] of String
                            else
                              expected[first_mark * CompactPartWriterW268Fixture::ROWS_PER_MARK, mark_count * CompactPartWriterW268Fixture::ROWS_PER_MARK]
                            end
            actual.should eq(expected_rows)
          end
        end

        physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
        physical.mode.should eq(mark_format)
        physical.row_count.should eq(CompactPartWriterW268Fixture::ROW_COUNT.to_u64)
        physical.granule_count.should eq(CompactPartWriterW268Fixture::MARK_COUNT)

        if mark_format == CrystalClick::CompactMarkFormat::Mrk4
          # The callback roster includes the key plus every recursive Dynamic
          # callback; the two independent sites yield thirteen physical slots.
          physical.physical_roster.size.should eq(13)
          {CompactPartWriterW268Fixture::ROOT_COLUMN, CompactPartWriterW268Fixture::CTX_COLUMN}.each do |column_name|
            window = physical.read_window(column_name, 0, CompactPartWriterW268Fixture::MARK_COUNT)
            window.granules.size.should eq(CompactPartWriterW268Fixture::MARK_COUNT)
            window.granules.each do |mark|
              mark.shards.count do |shard|
                shard.stream_name.try(&.ends_with?(".dynamic_structure")) == true
              end.should eq(1)
            end
          end
        end
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "preserves each supplied V1, V2, or V3 first-prefix sample and version-specific later statistics" do
    fixture = CompactPartWriterW268Fixture
    version_pairs = [
      {CrystalClick::DynamicStructure::VERSION_V1, CrystalClick::DynamicStructure::VERSION_V2},
      {CrystalClick::DynamicStructure::VERSION_V2, CrystalClick::DynamicStructure::VERSION_V3},
      {CrystalClick::DynamicStructure::VERSION_V3, CrystalClick::DynamicStructure::VERSION_V1},
    ] of Tuple(UInt64, UInt64)

    version_pairs.each do |root_version, nested_version|
      parent = File.tempname("crystal-click-w268-version-#{root_version}-#{nested_version}-")
      part_path = File.join(parent, "all_1_1_0")
      begin
        Dir.mkdir(parent)
        columns = fixture.columns(root_version, nested_version)
        w268_write_fixture(
          part_path,
          columns,
          CrystalClick::CompactMarkFormat::Mrk4,
          CrystalClick::CompactVariantDiscriminatorMode::Compact,
        )

        physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
        {
          {CompactPartWriterW268Fixture::ROOT_COLUMN, "UInt8"},
          {CompactPartWriterW268Fixture::CTX_COLUMN, "UInt16"},
        }.each do |column_name, ordinary_name|
          version = column_name == CompactPartWriterW268Fixture::ROOT_COLUMN ? root_version : nested_version
          window = physical.read_window(column_name, 0, CompactPartWriterW268Fixture::MARK_COUNT)
          first = w268_read_structure_prefix(window, 0)
          first.version.should eq(version)
          first.type_count.should eq(1)
          first.type_at(0).name.should eq(ordinary_name)
          first.statistics.not_nil!.counts.should eq([0_u64, 2_u64])
          first.statistics.not_nil!.shared.should be_empty

          # These supplied first-block counts are intentionally not a
          # final-part census: root has five UInt8 values and nested items
          # have seven UInt16 values across the complete twelve rows.
          final_ordinary_count = column_name == CompactPartWriterW268Fixture::ROOT_COLUMN ? 5_u64 : 7_u64
          first.statistics.not_nil!.count_at(1).should_not eq(final_ordinary_count)

          (1...CompactPartWriterW268Fixture::MARK_COUNT).each do |mark_index|
            later = w268_read_structure_prefix(window, mark_index)
            later.version.should eq(version)
            later.type_at(0).name.should eq(ordinary_name)
            if version == CrystalClick::DynamicStructure::VERSION_V3
              later.statistics.should be_nil
            else
              statistics = later.statistics.not_nil!
              statistics.counts.should eq([0_u64, 0_u64])
              statistics.shared.should be_empty
            end
          end
        end
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end
end
