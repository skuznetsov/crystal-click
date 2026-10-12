require "./spec_helper"
require "./support/compact_part_writer_w267_fixture"

private def w267_read_u64_le(bytes : Bytes) : UInt64
  unless bytes.size == 8
    raise "W267 Compact discriminator prefix must be exactly eight bytes"
  end
  value = 0_u64
  8.times do |index|
    value |= bytes[index].to_u64 << (index * 8)
  end
  value
end

describe CrystalClick::CompactPartWriter do
  it "round trips recursive Variant callbacks with per-mark Compact state" do
    fixture = CompactPartWriterW267Fixture
    [CrystalClick::CompactMarkFormat::Mrk4, CrystalClick::CompactMarkFormat::Mrk3].each do |mark_format|
      suffix = mark_format == CrystalClick::CompactMarkFormat::Mrk4 ? "mrk4" : "mrk3"
      parent = File.tempname("crystal-click-w267-#{suffix}-")
      part_path = File.join(parent, "all_1_1_0")
      begin
        Dir.mkdir(parent)
        CrystalClick::CompactPartWriter.write_uint64_columns(
          part_path,
          CompactPartWriterW267Fixture::KEY_NAME,
          fixture.keys,
          fixture.columns,
          rows_per_mark: CompactPartWriterW267Fixture::ROWS_PER_MARK,
          frame_bytes: CompactPartWriterW267Fixture::FRAME_BYTES,
          mark_format: mark_format,
        )

        physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
        physical.mode.should eq(mark_format)
        physical.row_count.should eq(CompactPartWriterW267Fixture::ROW_COUNT.to_u64)
        physical.granule_count.should eq(CompactPartWriterW267Fixture::MARK_COUNT)

        CompactPartWriterW267Fixture::COLUMN_NAMES.each do |column_name|
          type = fixture.types[column_name]
          reader = CrystalClick::CompactBinaryBulkColumnReader.open(part_path, column_name, type)
          reader.mark_count.should eq(CompactPartWriterW267Fixture::MARK_COUNT)
          expected = fixture.expected_signatures(column_name)
          fixture.read_signatures(column_name, reader.read_marks(0, CompactPartWriterW267Fixture::MARK_COUNT)).should eq(expected)
          fixture.read_signatures(column_name, reader.read_marks(1, 2)).should eq(expected[2, 4])
          fixture.read_signatures(column_name, reader.read_marks(3, 1)).should eq(expected[6, 2])
        end

        if mark_format == CrystalClick::CompactMarkFormat::Mrk4
          {"payload" => 1, "ctx" => 2}.each do |column_name, variant_site_count|
            window = physical.read_window(column_name, 0, CompactPartWriterW267Fixture::MARK_COUNT)
            window.granules.each_with_index do |mark, mark_index|
              variant_prefixes = mark.shards.select do |shard|
                shard.stream_name.try(&.ends_with?(".variant_discr_prefix")) == true
              end
              variant_prefixes.size.should eq(variant_site_count)
              variant_prefixes.each do |prefix|
                w267_read_u64_le(prefix.bytes).should eq(1_u64) # ClickHouse COMPACT mode.
              end

              dictionary_prefixes = mark.shards.select do |shard|
                shard.stream_name.try(&.ends_with?(".dict_prefix")) == true
              end
              dictionary_prefix_count = column_name == "payload" ? 2 : 1
              dictionary_prefixes.size.should eq(dictionary_prefix_count)
              dictionary_prefixes.each do |prefix|
                w267_read_u64_le(prefix.bytes).should eq(CrystalClick::BinaryLowCardinalityStorageStreams::VERSION)
              end

              if column_name == "ctx"
                variant_bodies = mark.shards.select do |shard|
                  shard.stream_name.try(&.ends_with?(".variant_discr")) == true
                end
                variant_bodies.size.should eq(2)
                if mark_index == 1
                  # This mark has rows at the parent level but no nested list
                  # elements, so one recursive Variant callback is empty.
                  variant_bodies.count { |body| body.bytes.empty? }.should eq(1)
                end
              end
            end
          end
        end
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "round trips explicit BASIC framing and writes every recursive site prefix" do
    fixture = CompactPartWriterW267Fixture
    [CrystalClick::CompactMarkFormat::Mrk4, CrystalClick::CompactMarkFormat::Mrk3].each do |mark_format|
      suffix = mark_format.mrk4? ? "mrk4" : "mrk3"
      parent = File.tempname("crystal-click-w267-basic-#{suffix}-")
      part_path = File.join(parent, "all_1_1_0")
      begin
        Dir.mkdir(parent)
        CrystalClick::CompactPartWriter.write_uint64_columns(
          part_path,
          CompactPartWriterW267Fixture::KEY_NAME,
          fixture.keys,
          fixture.columns,
          rows_per_mark: CompactPartWriterW267Fixture::ROWS_PER_MARK,
          frame_bytes: CompactPartWriterW267Fixture::FRAME_BYTES,
          mark_format: mark_format,
          variant_discriminator_mode: CrystalClick::CompactVariantDiscriminatorMode::Basic,
        )

        CompactPartWriterW267Fixture::COLUMN_NAMES.each do |column_name|
          reader = CrystalClick::CompactBinaryBulkColumnReader.open(part_path, column_name, fixture.types[column_name])
          expected = fixture.expected_signatures(column_name)
          fixture.read_signatures(column_name, reader.read_marks(0, CompactPartWriterW267Fixture::MARK_COUNT)).should eq(expected)
        end

        physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
        if mark_format.mrk4?
          total_variant_prefixes = 0
          {"payload" => 1, "ctx" => 2}.each do |column_name, site_count|
            marks = physical.read_window(column_name, 0, CompactPartWriterW267Fixture::MARK_COUNT).granules
            marks.each do |mark|
              prefixes = mark.shards.select do |shard|
                shard.stream_name.try(&.ends_with?(".variant_discr_prefix")) == true
              end
              prefixes.size.should eq(site_count)
              prefixes.each do |prefix|
                w267_read_u64_le(prefix.bytes).should eq(0_u64)
                total_variant_prefixes += 1
              end
            end
          end
          total_variant_prefixes.should eq(12)
        end
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end
end
