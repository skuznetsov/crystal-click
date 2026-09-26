require "./spec_helper"

private def w20_writer_decimal256_from_bytes_1_to_32 : CrystalClick::Decimal256Value
  CrystalClick::Decimal256Value.from_words(
    0x0807060504030201_u64,
    0x100f0e0d0c0b0a09_u64,
    0x1817161514131211_u64,
    0x201f1e1d1c1b1a19_u64
  )
end

describe CrystalClick::WidePartWriter do
  it "writes raw Decimal256 as exact 32-byte signed little-endian values" do
    parent = File.tempname("crystal-click-w20-decimal256")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    minimum = CrystalClick::Decimal256Value.from_words(0_u64, 0_u64, 0_u64, 0x8000000000000000_u64)
    negative_one = CrystalClick::Decimal256Value.from_words(UInt64::MAX, UInt64::MAX, UInt64::MAX, UInt64::MAX)
    zero = CrystalClick::Decimal256Value.new(0_u128, 0_u128)
    maximum = CrystalClick::Decimal256Value.from_words(UInt64::MAX, UInt64::MAX, UInt64::MAX, 0x7fffffffffffffff_u64)
    values = [minimum, w20_writer_decimal256_from_bytes_1_to_32, negative_one, zero, maximum]

    begin
      CrystalClick::WidePartWriter.write_uint64_decimal256_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "amount",
        values.to_unsafe.to_slice(values.size), 0, 2
      ).should eq(destination)
      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`amount` Decimal(76, 0)\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should contain(
        "1 substreams for column `amount`:\n\tamount\n"
      )
      File.read(File.join(destination, "serialization.json")).should eq(
        %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
      )

      expected = Array(UInt8).new(32 * values.size, 0_u8)
      expected[31] = 0x80_u8
      32.times { |index| expected[32 + index] = (index + 1).to_u8 }
      32.times { |index| expected[64 + index] = 0xff_u8 }
      31.times { |index| expected[128 + index] = 0xff_u8 }
      expected[159] = 0x7f_u8
      observed = CrystalClick::CompressedBlock.decode_all(
        File.read(File.join(destination, "#{CrystalClick::StreamName.hash("amount")}.bin")).to_slice
      ).to_a
      observed.should eq(expected)
      part = CrystalClick::WidePart.open_typed(destination, "amount")
      part.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      part.read_decimal256_raw_mark_range("amount", 0, 3).should eq(values)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes Nullable Decimal256 with a separate null map and zero-filled NULL slot" do
    parent = File.tempname("crystal-click-w20-nullable-decimal256")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 3_u64, 4_u64]
    zero = CrystalClick::Decimal256Value.new(0_u128, 0_u128)
    pattern = w20_writer_decimal256_from_bytes_1_to_32
    negative_one = CrystalClick::Decimal256Value.from_words(UInt64::MAX, UInt64::MAX, UInt64::MAX, UInt64::MAX)
    values = [nil.as(CrystalClick::Decimal256Value?), zero.as(CrystalClick::Decimal256Value?), pattern.as(CrystalClick::Decimal256Value?), negative_one.as(CrystalClick::Decimal256Value?)]

    begin
      CrystalClick::WidePartWriter.write_uint64_nullable_decimal256_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "amount",
        values.to_unsafe.to_slice(values.size), 76, 2
      ).should eq(destination)
      File.read(File.join(destination, "columns.txt")).should contain(
        "`amount` Nullable(Decimal(76, 76))\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should contain(
        "2 substreams for column `amount`:\n\tamount.null\n\tamount\n"
      )

      expected_payload = Array(UInt8).new(32 * values.size, 0_u8)
      32.times { |index| expected_payload[64 + index] = (index + 1).to_u8 }
      32.times { |index| expected_payload[96 + index] = 0xff_u8 }
      observed_payload = CrystalClick::CompressedBlock.decode_all(
        File.read(File.join(destination, "#{CrystalClick::StreamName.hash("amount")}.bin")).to_slice
      ).to_a
      observed_payload.should eq(expected_payload)
      observed_nulls = CrystalClick::CompressedBlock.decode_all(
        File.read(File.join(destination, "#{CrystalClick::StreamName.hash("amount.null")}.bin")).to_slice
      ).to_a
      observed_nulls.should eq([1_u8, 0_u8, 0_u8, 0_u8])
      part = CrystalClick::WidePart.open_typed(destination, "amount")
      part.read_nullable_decimal256_raw_mark_range("amount", 0, 2).should eq(values)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects Decimal256 scales outside zero through 76 before staging" do
    parent = File.tempname("crystal-click-w20-decimal256-invalid-scale")
    Dir.mkdir(parent)
    keys = [1_u64]
    values = [CrystalClick::Decimal256Value.new(1_u128, 0_u128)]
    nullable_values = [values[0].as(CrystalClick::Decimal256Value?)]
    destination = File.join(parent, "part")

    begin
      {-1, 77}.each do |scale|
        expect_raises(ArgumentError, "Decimal256 scale must be between 0 and 76") do
          CrystalClick::WidePartWriter.write_uint64_decimal256_pair(
            destination, "pk", keys.to_unsafe.to_slice(keys.size), "amount",
            values.to_unsafe.to_slice(values.size), scale, 1
          )
        end
        expect_raises(ArgumentError, "Decimal256 scale must be between 0 and 76") do
          CrystalClick::WidePartWriter.write_uint64_nullable_decimal256_pair(
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

  it "does not infer Decimal256 from its raw value type" do
    parent = File.tempname("crystal-click-w20-decimal256-inference")
    Dir.mkdir(parent)
    keys = [1_u64]
    values = [CrystalClick::Decimal256Value.new(1_u128, 0_u128)]
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
