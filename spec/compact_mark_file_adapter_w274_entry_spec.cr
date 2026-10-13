require "./spec_helper"
require "./support/compact_mark_file_adapter_w274_fixture"

describe "W274 compressed Compact mark public entry" do
  it "opens a genuine compressed MRK3 sidecar through the public context and windows" do
    CompactMarkFileAdapterW274Fixture.with_isolated_part(CrystalClick::CompactMarkFormat::Mrk3) do |part|
      context = CrystalClick::CompactPartPhysicalContext.open(part)
      context.mode.should eq(CrystalClick::CompactMarkFormat::Mrk3)
      context.row_count.should eq(8_u64)
      context.granule_count.should eq(4_i32)

      first = context.read_window("alpha", 0, 1)
      first.first_mark.should eq(0_i32)
      first.row_offset.should eq(0_u64)
      first.granules.first.row_count.should eq(2_u64)
      first.granules.first.shards.map(&.bytes).should eq(["A0".to_slice])

      eof = context.read_window("gamma", 4, 0)
      eof.first_mark.should eq(4_i32)
      eof.row_offset.should eq(8_u64)
      eof.granules.should be_empty
    end
  end

  it "opens a genuine compressed MRK4 sidecar through the public context and windows" do
    CompactMarkFileAdapterW274Fixture.with_isolated_part(CrystalClick::CompactMarkFormat::Mrk4) do |part|
      context = CrystalClick::CompactPartPhysicalContext.open(part)
      context.mode.should eq(CrystalClick::CompactMarkFormat::Mrk4)
      context.row_count.should eq(8_u64)
      context.granule_count.should eq(4_i32)

      first = context.read_window("alpha", 0, 1)
      first.granules.first.shards.map(&.bytes).should eq(["a0".to_slice, Bytes.empty])
      first.granules.first.shards.map(&.slot_index).should eq([0_i32, 1_i32])

      eof = context.read_window("gamma", 4, 0)
      eof.first_mark.should eq(4_i32)
      eof.row_offset.should eq(8_u64)
      eof.granules.should be_empty
    end
  end
end
