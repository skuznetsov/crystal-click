require "./spec_helper"

private def w16_writer_decimal128_le_bytes(values : Array(Int128)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    bits = value.unsafe_as(UInt128)
    16.times { |index| bytes << ((bits >> (index * 8)) & 0xff_u128).to_u8 }
  end
  bytes
end

describe CrystalClick::WidePartWriter do
  it "writes Decimal128 at precision 38 with 16-byte signed raw values" do
    parent = File.tempname("crystal-click-w16-decimal128")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    endpoint = ("9" * 38).to_i128
    values = [-endpoint, -9_223_372_036_854_775_809_i128, -1_i128, 0_i128, endpoint]

    begin
      CrystalClick::WidePartWriter.write_uint64_decimal128_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "amount",
        values.to_unsafe.to_slice(values.size), 0, 2
      ).should eq(destination)
      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`amount` Decimal(38, 0)\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should contain("1 substreams for column `amount`:\n\tamount\n")
      File.read(File.join(destination, "serialization.json")).should eq(
        %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
      )
      w16_writer_decimal128_le_bytes(values).should eq(
        CrystalClick::CompressedBlock.decode_all(File.read(File.join(destination, "#{CrystalClick::StreamName.hash("amount")}.bin")).to_slice).to_a
      )
      CrystalClick::WidePart.open_typed(destination, "amount").read_decimal128_raw_mark_range("amount", 0, 3).should eq(values)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes Nullable Decimal128 scale 38 with separate null map and zero slot" do
    parent = File.tempname("crystal-click-w16-nullable-decimal128")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 3_u64, 4_u64]
    endpoint = ("9" * 38).to_i128
    values = [nil, (-endpoint).as(Int128?), 0_i128.as(Int128?), endpoint.as(Int128?)]
    nested = [0_i128, -endpoint, 0_i128, endpoint]

    begin
      CrystalClick::WidePartWriter.write_uint64_nullable_decimal128_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "amount",
        values.to_unsafe.to_slice(values.size), 38, 2
      ).should eq(destination)
      File.read(File.join(destination, "columns.txt")).should contain("`amount` Nullable(Decimal(38, 38))\n")
      File.read(File.join(destination, "columns_substreams.txt")).should contain(
        "2 substreams for column `amount`:\n\tamount.null\n\tamount\n"
      )
      w16_writer_decimal128_le_bytes(nested).should eq(
        CrystalClick::CompressedBlock.decode_all(File.read(File.join(destination, "#{CrystalClick::StreamName.hash("amount")}.bin")).to_slice).to_a
      )
      CrystalClick::CompressedBlock.decode_all(File.read(File.join(destination, "#{CrystalClick::StreamName.hash("amount.null")}.bin")).to_slice).to_a.should eq([1_u8, 0_u8, 0_u8, 0_u8])
      CrystalClick::WidePart.open_typed(destination, "amount").read_nullable_decimal128_raw_mark_range("amount", 0, 2).should eq(values)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects Decimal128 scales outside zero through 38 before staging" do
    parent = File.tempname("crystal-click-w16-decimal128-invalid-scale")
    Dir.mkdir(parent)
    keys = [1_u64]
    values = [1_i128]
    nullable_values = [1_i128.as(Int128?)]
    destination = File.join(parent, "part")

    begin
      {-1, 39}.each do |scale|
        expect_raises(ArgumentError, "Decimal128 scale must be between 0 and 38") do
          CrystalClick::WidePartWriter.write_uint64_decimal128_pair(
            destination, "pk", keys.to_unsafe.to_slice(keys.size), "amount",
            values.to_unsafe.to_slice(values.size), scale, 1
          )
        end
        expect_raises(ArgumentError, "Decimal128 scale must be between 0 and 38") do
          CrystalClick::WidePartWriter.write_uint64_nullable_decimal128_pair(
            destination, "pk", keys.to_unsafe.to_slice(keys.size), "amount",
            nullable_values.to_unsafe.to_slice(nullable_values.size), scale, 1
          )
        end
      end
      Dir.exists?(destination).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "requires explicit scale instead of inferring Decimal128 from Int128" do
    parent = File.tempname("crystal-click-w16-decimal128-inference")
    Dir.mkdir(parent)
    keys = [1_u64]
    values = [1_i128]
    destination = File.join(parent, "part")

    begin
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_typed_pair(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "amount",
          values.to_unsafe.to_slice(values.size), 1
        )
      end
      Dir.exists?(destination).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
