require "./spec_helper"
require "./support/compact_part_writer_w271_fixture"

describe "W271 typed-Dynamic JSON fixture control" do
  it "round-trips the exact bound child JSON arm through the common Object codec" do
    fixture = CompactPartWriterW271Fixture

    fixture.common_codec_roundtrip!
    fixture.column.name.should eq(CompactPartWriterW271Fixture::COLUMN_NAME)
    fixture.rows.size.should eq(CompactPartWriterW271Fixture::ROW_COUNT)
    fixture.granules.map(&.size).should eq([2, 2, 2, 2])
    fixture.expected_mark_arm_counts.should eq([1, 0, 2, 1])
  end
end
