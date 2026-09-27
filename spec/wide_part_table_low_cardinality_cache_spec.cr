require "./spec_helper"

private class WidePartTableLowCardinalityCacheStop < Exception
end

private def low_cardinality_cache_fixture(parent : String) : {String, Array(String)}
  part_path = File.join(parent, "all_1_1_0")
  values = ["alpha", "beta", "alpha", "gamma"]
  keys = [1_u64, 2_u64, 3_u64, 4_u64]
  CrystalClick::WidePartWriter.write_uint64_low_cardinality_string_pair(
    part_path,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "payload",
    values.to_unsafe.to_slice(values.size),
    rows_per_mark: 2
  )
  {part_path, values}
end

private def low_cardinality_cache_corrupt_index_frame(part_path : String) : Nil
  data_path = File.join(part_path, "#{CrystalClick::StreamName.hash("payload")}.bin")
  bytes = File.read(data_path).to_slice.dup
  bytes[CrystalClick::CompressedBlock::CHECKSUM_SIZE] = 0_u8
  File.write(data_path, bytes)
end

describe CrystalClick::WidePartTable do
  it "releases LowCardinality validation state after a successful typed scan" do
    parent = File.tempname("crystal-click-lc-cache-success")
    Dir.mkdir(parent)
    part_path, values = low_cardinality_cache_fixture(parent)

    begin
      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["payload"])
      observed = [] of String
      table.scan_typed(batch_rows: 1) do |batch|
        observed << batch.low_cardinality_strings_for("payload")[0]
      end
      observed.should eq(values)

      low_cardinality_cache_corrupt_index_frame(part_path)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_typed { |_batch| }
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "releases LowCardinality validation state when a typed-scan callback raises" do
    parent = File.tempname("crystal-click-lc-cache-exception")
    Dir.mkdir(parent)
    part_path, _values = low_cardinality_cache_fixture(parent)

    begin
      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["payload"])
      expect_raises(WidePartTableLowCardinalityCacheStop) do
        table.scan_typed(batch_rows: 1) do |_batch|
          raise WidePartTableLowCardinalityCacheStop.new("stop after cache initialization")
        end
      end

      low_cardinality_cache_corrupt_index_frame(part_path)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        table.scan_typed { |_batch| }
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
