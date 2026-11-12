require "./spec_helper"
require "./support/compact_part_writer_w273_fixture"

describe "W273 nested typed-Dynamic Array-chain common-codec fixture control" do
  it "round trips the exact depth-two leaf binding, literals, size vectors, and mark grids" do
    CompactPartWriterW273Fixture.common_codec_roundtrip!(2)
  end

  it "round trips the exact depth-three leaf binding, literals, size vectors, and mark grids" do
    CompactPartWriterW273Fixture.common_codec_roundtrip!(3)
  end
end
