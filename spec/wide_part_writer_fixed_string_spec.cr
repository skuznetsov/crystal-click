require "./spec_helper"

private def expected_fixed_string_bytes(value : String, width : Int32) : String
  bytes = Bytes.new(width, 0_u8)
  value.to_slice.copy_to(bytes) unless value.empty?
  String.new(bytes)
end

describe CrystalClick::WidePartWriter do
  it "writes one zero-padded FixedString stream across marks and reads back exact bytes" do
    parent = File.tempname("crystal-click-wide-writer-fixed-string")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 2_u64, 4_u64, 9_u64, 11_u64, 13_u64]
    values = ["", "a", "a\0b\0", "éx", "uvwx", String.new(Bytes[0xff_u8, 0_u8]), "z"]
    expected = values.map { |value| expected_fixed_string_bytes(value, 4) }

    begin
      CrystalClick::WidePartWriter.write_uint64_fixed_string_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "value",
        values.to_unsafe.to_slice(values.size),
        width: 4,
        rows_per_mark: 2
      )

      key_part = CrystalClick::WidePart.open(destination, "pk")
      key_part.row_count.should eq(7_u64)
      key_part.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
      key_part.read_uint64.should eq(keys)

      value_part = CrystalClick::WidePart.open_typed(destination, "value")
      value_part.column_type.should eq("FixedString(4)")
      value_part.row_count.should eq(7_u64)
      value_part.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
      value_part.read_fixed_string_mark_range("value", 0, value_part.mark_count).should eq(expected)
      value_part.read_fixed_string_mark_range("value", 1, 1).should eq(expected[2, 2])

      data_path = File.join(destination, "#{CrystalClick::StreamName.hash("value")}.bin")
      CrystalClick::CompressedBlock.decode_all(File.read(data_path).to_slice).to_a.should eq(expected.join.to_slice.to_a)
      File.exists?(File.join(destination, "#{CrystalClick::StreamName.hash("value.size")}.bin")).should be_false
      File.exists?(File.join(destination, "#{CrystalClick::StreamName.hash("value.size")}.mrk2")).should be_false
      serialization = JSON.parse(File.read(File.join(destination, "serialization.json")))
      serialization["types_serialization_versions"].as_h["string"].as_i.should eq(1)

      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`value` FixedString(4)\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n1 substreams for column `value`:\n\tvalue\n"
      )
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects invalid widths and values wider than N without publishing a part" do
    parent = File.tempname("crystal-click-wide-writer-fixed-string-invalid")
    Dir.mkdir(parent)
    keys = [1_u64]

    begin
      zero_width_destination = File.join(parent, "zero-width")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_fixed_string_pair(
          zero_width_destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "value",
          [""].to_unsafe.to_slice(1),
          width: 0,
          rows_per_mark: 1
        )
      end
      File.exists?(zero_width_destination).should be_false

      oversized_value_destination = File.join(parent, "oversized-value")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_fixed_string_pair(
          oversized_value_destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "value",
          ["abcde"].to_unsafe.to_slice(1),
          width: 4,
          rows_per_mark: 1
        )
      end
      File.exists?(oversized_value_destination).should be_false

      oversized_width_destination = File.join(parent, "oversized-width")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_fixed_string_pair(
          oversized_width_destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "value",
          [""].to_unsafe.to_slice(1),
          width: CrystalClick::WidePart::MAX_FIXED_STRING_WIDTH.to_i32 + 1,
          rows_per_mark: 1
        )
      end
      File.exists?(oversized_width_destination).should be_false

      oversized_mark_destination = File.join(parent, "oversized-mark")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_fixed_string_pair(
          oversized_mark_destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "value",
          ["a"].to_unsafe.to_slice(1),
          width: 1,
          rows_per_mark: (CrystalClick::WidePart::MAX_FIXED_STRING_RANGE_ROWS + 1_u64).to_i32
        )
      end
      File.exists?(oversized_mark_destination).should be_false

      oversized_frame_destination = File.join(parent, "oversized-frame")
      frame_rows = CrystalClick::WidePart::MAX_FRAME_DECOMPRESSED_BYTES // CrystalClick::WidePart::MAX_FIXED_STRING_WIDTH + 1
      frame_keys = Array(UInt64).new(frame_rows) { |index| index.to_u64 }
      frame_values = Array(String).new(frame_rows, "")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_fixed_string_pair(
          oversized_frame_destination,
          "pk",
          frame_keys.to_unsafe.to_slice(frame_keys.size),
          "value",
          frame_values.to_unsafe.to_slice(frame_values.size),
          width: CrystalClick::WidePart::MAX_FIXED_STRING_WIDTH.to_i32,
          rows_per_mark: frame_rows.to_i32
        )
      end
      File.exists?(oversized_frame_destination).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
