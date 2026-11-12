require "./spec_helper"
require "./support/compact_part_writer_w272_fixture"

describe "W272 typed-Dynamic Array(JSON) common-codec fixture control" do
  it "round trips the exact leaf binding, selected arrays, JSON elements, and mark grids" do
    CompactPartWriterW272Fixture.common_codec_roundtrip!
  end
end
