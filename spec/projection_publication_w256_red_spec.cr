require "./spec_helper"
require "file_utils"

describe "W256 projection publication baseline regression" do
  it "requires a composed child to be registered in the parent checksum envelope" do
    parent = File.tempname("crystal-click-w256-red-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      keys = [1_u64, 2_u64]
      type = CrystalClick::BinaryDataType.primitive("UInt64")
      values = [[CrystalClick::BinaryValue.uint64(20_u64), CrystalClick::BinaryValue.uint64(10_u64)]]
      child_keys = [10_u64, 20_u64]
      child_values = [[CrystalClick::BinaryValue.uint64(2_u64)], [CrystalClick::BinaryValue.uint64(1_u64)]]
      projection = CrystalClick::WidePartProjection.precomputed(
        "by_score", "score", child_keys.to_unsafe.to_slice(child_keys.size),
        [CrystalClick::WidePartColumn.binary_bulk("id", type, child_values)],
        rows_per_mark: 1,
      )
      # The baseline constructed the child after publishing the flat parent;
      # it failed the final assertion because no parent summary was registered.
      # The admitted API stages both owners inside one publication envelope.
      CrystalClick::WidePartWriter.write_uint64_columns(
        part, "id", keys.to_unsafe.to_slice(keys.size),
        [CrystalClick::WidePartColumn.binary_bulk("score", type, values)],
        rows_per_mark: 2,
        projections: [projection],
      )
      CrystalClick::PartChecksums.open(part).entry("by_score.proj").should_not be_nil
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
