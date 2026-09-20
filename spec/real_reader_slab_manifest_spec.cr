require "./spec_helper"
require "../benchmarks/real_reader_slab_manifest"

def real_reader_manifest_json(
  version : Int = 2,
  fixture : String = "/private/tmp/runtime-only-fixture",
  rows : UInt64 = 8_388_608_u64,
  columns : Array(String) = ["value"],
  expected_checksums : Array(String) = ["0"],
  multiplier : String = "0x94d049bb133111eb",
) : String
  columns_json = columns.each_with_index.map do |name, index|
    checksum = expected_checksums[index]? || "0"
    %({"name":"#{name}","expected_checksum":"#{checksum}"})
  end.join(",")
  %({"version":#{version},"fixture":"#{fixture}","expected_rows":#{rows},"columns":[#{columns_json}],"checksum":{"algorithm":"u64_mul_xor","initial":0,"multiplier":"#{multiplier}","order":"physical_part_order"}})
end

describe CrystalClickRealReaderSlabManifest do
  it "accepts a valid v2 workload at the controlled threshold" do
    workload = CrystalClickRealReaderSlabManifest.parse_json(real_reader_manifest_json)

    workload.expected_rows.should eq(8_388_608_u64)
    workload.columns.size.should eq(1)
    workload.decoded_bytes.should eq(64_u64 * 1024_u64 * 1024_u64)
    workload.threshold_met?.should be_true
    workload.validate_controlled!.should be_nil
  end

  it "retains UInt64 checksums beyond the signed JSON integer range" do
    workload = CrystalClickRealReaderSlabManifest.parse_json(real_reader_manifest_json(expected_checksums: ["15108874301622009856"]))

    workload.columns[0].expected_checksum.should eq(15_108_874_301_622_009_856_u64)
  end

  it "preserves physical column order and each expected checksum" do
    workload = CrystalClickRealReaderSlabManifest.parse_json(
      real_reader_manifest_json(
        columns: ["first", "second"],
        expected_checksums: ["7", "15108874301622009856"],
      )
    )

    workload.columns.map(&.name).should eq(["first", "second"])
    workload.columns.map(&.expected_checksum).should eq([7_u64, 15_108_874_301_622_009_856_u64])
    workload.decoded_bytes.should eq(128_u64 * 1024_u64 * 1024_u64)
    workload.validate_controlled!.should be_nil
  end

  it "rejects duplicate column names" do
    expect_raises(ArgumentError, /unique/) do
      CrystalClickRealReaderSlabManifest.parse_json(real_reader_manifest_json(columns: ["value", "value"], expected_checksums: ["0", "1"]))
    end
  end

  it "rejects bad versions, rows, and checksum metadata" do
    expect_raises(ArgumentError, /version/) { CrystalClickRealReaderSlabManifest.parse_json(real_reader_manifest_json(version: 1)) }
    expect_raises(ArgumentError, /expected_rows/) { CrystalClickRealReaderSlabManifest.parse_json(real_reader_manifest_json(rows: 0_u64)) }
    expect_raises(ArgumentError, /controlled limit/) { CrystalClickRealReaderSlabManifest.parse_json(real_reader_manifest_json(rows: 1_000_000_001_u64)) }
    expect_raises(ArgumentError, /checksum metadata/) { CrystalClickRealReaderSlabManifest.parse_json(real_reader_manifest_json(multiplier: "0x1")) }
  end

  it "requires an absolute non-root fixture" do
    expect_raises(ArgumentError, /absolute/) do
      CrystalClickRealReaderSlabManifest.parse_json(real_reader_manifest_json(fixture: "relative-fixture"))
    end
    expect_raises(ArgumentError, /absolute/) do
      CrystalClickRealReaderSlabManifest.parse_json(real_reader_manifest_json(fixture: "/"))
    end
  end

  it "bounds manifest size, columns, and column names" do
    expect_raises(ArgumentError, /too large/) do
      CrystalClickRealReaderSlabManifest.parse_json(real_reader_manifest_json + (" " * 66_000))
    end
    expect_raises(ArgumentError, /controlled limit/) do
      CrystalClickRealReaderSlabManifest.parse_json(real_reader_manifest_json(rows: 8_388_608_u64, columns: Array.new(1_025, "x"), expected_checksums: Array.new(1_025, "0")))
    end
    expect_raises(ArgumentError, /controlled limit/) do
      CrystalClickRealReaderSlabManifest.parse_json(real_reader_manifest_json(columns: ["x" * 257]))
    end
  end

  it "bounds JSON nesting depth" do
    nested = "0"
    18.times { nested = "[#{nested}]" }

    expect_raises(ArgumentError, /too deeply nested/) do
      CrystalClickRealReaderSlabManifest.parse_json(nested)
    end
  end

  it "rejects duplicate and unknown object keys" do
    duplicate_root = %({"version":2,"version":2,"fixture":"/private/tmp/runtime-only-fixture","expected_rows":8388608,"columns":[{"name":"value","expected_checksum":"0"}],"checksum":{"algorithm":"u64_mul_xor","initial":0,"multiplier":"0x94d049bb133111eb","order":"physical_part_order"}})
    unknown_root = %({"version":2,"fixture":"/private/tmp/runtime-only-fixture","expected_rows":8388608,"columns":[{"name":"value","expected_checksum":"0"}],"checksum":{"algorithm":"u64_mul_xor","initial":0,"multiplier":"0x94d049bb133111eb","order":"physical_part_order"},"private":"raw"})
    expect_raises(ArgumentError, /duplicate/) { CrystalClickRealReaderSlabManifest.parse_json(duplicate_root) }
    expect_raises(ArgumentError, /unknown/) { CrystalClickRealReaderSlabManifest.parse_json(unknown_root) }
  end

  it "rejects an under-threshold workload only in controlled mode" do
    workload = CrystalClickRealReaderSlabManifest.parse_json(real_reader_manifest_json(rows: 200_000_u64))

    workload.threshold_met?.should be_false
    expect_raises(ArgumentError, /64 MiB/) { workload.validate_controlled! }
  end

  it "requires unique non-empty names and an expected checksum per column" do
    expect_raises(ArgumentError, /non-empty/) do
      CrystalClickRealReaderSlabManifest.parse_json(real_reader_manifest_json(columns: [""], expected_checksums: ["0"]))
    end
    expect_raises(ArgumentError, /expected_checksum/) do
      CrystalClickRealReaderSlabManifest.parse_json(%({"version":2,"fixture":"/private/tmp/fixture","expected_rows":8388608,"columns":[{"name":"value"}],"checksum":{"algorithm":"u64_mul_xor","initial":0,"multiplier":"0x94d049bb133111eb","order":"physical_part_order"}}))
    end
  end
end
