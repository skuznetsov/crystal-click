require "./spec_helper"

W75_WRITER_KEYS   = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
W75_WRITER_VALUES = [
  "alpha",
  0_u64,
  nil,
  "",
  "a\0b",
  nil,
  UInt64::MAX,
] of CrystalClick::VariantStringUInt64Value
W75_WRITER_UINT64_FIRST_VALUES = [
  42_u64,
  "s",
  nil,
  UInt64::MAX,
  "",
  nil,
  "tail",
] of CrystalClick::VariantStringUInt64Value

W75_WRITER_STRUCTURE = Bytes[
  0x04_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
  0x02_u8, 0x15_u8, 0x04_u8, 0x01_u8, 0x00_u8, 0x03_u8, 0x02_u8, 0x00_u8,
]
W75_WRITER_STRING_FIRST_DISCRIMINATOR = Bytes[
  0x01_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
  0x03_u8, 0x00_u8, 0x01_u8, 0x02_u8, 0xff_u8,
  0x03_u8, 0x00_u8, 0x01_u8, 0x01_u8, 0xff_u8,
  0x01_u8, 0x01_u8, 0x02_u8,
]
W75_WRITER_UINT64_FIRST_DISCRIMINATOR = Bytes[
  0x01_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8,
  0x03_u8, 0x00_u8, 0x02_u8, 0x01_u8, 0xff_u8,
  0x03_u8, 0x00_u8, 0x02_u8, 0x01_u8, 0xff_u8,
  0x01_u8, 0x01_u8, 0x01_u8,
]

private def w75_writer_raw_stream(part : String, stream : String) : Array(UInt8)
  encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  return [] of UInt8 if encoded.empty?
  CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w75_writer_raw_u64_stream(part : String, stream : String) : Array(UInt64)
  bytes = w75_writer_raw_stream(part, stream)
  raise "W75 writer UInt64 stream is not aligned: #{stream}" unless bytes.size % 8 == 0
  Array(UInt64).new(bytes.size // 8) do |index|
    offset = index * 8
    value = 0_u64
    8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
    value
  end
end

private def w75_writer_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w75_writer_literal_frame_size(raw_size : Int64) : UInt64
  extension_size = raw_size < 15 ? 0_i64 : ((raw_size - 15) // 255) + 1
  (CrystalClick::CompressedBlock::HEADER_SIZE.to_i64 + CrystalClick::CompressedBlock::CHECKSUM_SIZE.to_i64 +
    1_i64 + extension_size + raw_size).to_u64
end

private def w75_writer_expected_frames(
  raw_sizes : Array(Int64),
  row_counts : Array(UInt64),
  first_decompressed_offset : UInt64 = 0_u64,
) : Array(Tuple(UInt64, UInt64, UInt64))
  raise "W75 expected mark fixture is inconsistent" unless raw_sizes.size == row_counts.size
  marks = [] of Tuple(UInt64, UInt64, UInt64)
  compressed_offset = 0_u64
  raw_sizes.each_with_index do |raw_size, index|
    marks << {compressed_offset, index == 0 ? first_decompressed_offset : 0_u64, row_counts[index]}
    compressed_offset += w75_writer_literal_frame_size(raw_size) if raw_size > 0
  end
  marks << {compressed_offset, 0_u64, 0_u64}
  marks
end

private def w75_writer_expected_empty(row_counts : Array(UInt64)) : Array(Tuple(UInt64, UInt64, UInt64))
  row_counts.map { |rows| {0_u64, 0_u64, rows} }.concat([{0_u64, 0_u64, 0_u64}])
end

private def w75_writer_marks(part : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  bytes = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "W75 writer mark file is malformed: #{stream}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {
      w75_writer_read_u64(bytes, offset),
      w75_writer_read_u64(bytes, offset + 8),
      w75_writer_read_u64(bytes, offset + 16),
    }
  end
end

private def w75_writer_assert_part(
  values : Array(CrystalClick::VariantStringUInt64Value),
  discriminator : Bytes,
  string_sizes : Array(UInt64),
  string_bytes : Array(UInt8),
  uint64_values : Array(UInt64),
  string_size_marks : Array(Tuple(UInt64, UInt64, UInt64)),
  string_marks : Array(Tuple(UInt64, UInt64, UInt64)),
  uint64_marks : Array(Tuple(UInt64, UInt64, UInt64)),
  discriminator_marks : Array(Tuple(UInt64, UInt64, UInt64)),
) : Nil
  parent = File.tempname("crystal-click-w75-dynamic-writer")
  Dir.mkdir(parent)
  destination = File.join(parent, "part")
  streams = [
    "payload.dynamic_structure",
    "payload.variant_discr",
    "payload.SharedVariant.size",
    "payload.SharedVariant",
    "payload.String.size",
    "payload.String",
    "payload.UInt64",
  ]
  begin
    CrystalClick::WidePartWriter.write_uint64_dynamic_string_uint64_pair(
      destination,
      "pk",
      W75_WRITER_KEYS.to_unsafe.to_slice(W75_WRITER_KEYS.size),
      "payload",
      values.to_unsafe.to_slice(values.size),
      rows_per_mark: 3
    )

    File.read(File.join(destination, "columns.txt")).should eq(
      "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Dynamic\n"
    )
    File.read(File.join(destination, "columns_substreams.txt")).should eq(
      "columns substreams version: 1\n2 columns:\n" +
      "1 substreams for column `pk`:\n\tpk\n" +
      "7 substreams for column `payload`:\n" +
      "\tpayload.dynamic_structure\n\tpayload.variant_discr\n" +
      "\tpayload.SharedVariant.size\n\tpayload.SharedVariant\n" +
      "\tpayload.String.size\n\tpayload.String\n\tpayload.UInt64\n"
    )
    File.read(File.join(destination, "serialization.json")).should eq(
      "{\"columns\":[{\"kind\":\"Default\",\"name\":\"pk\",\"num_defaults\":0,\"num_rows\":7}]," +
      "\"propagate_types_serialization_versions_to_nested_types\":true," +
      "\"types_serialization_versions\":{\"string\":1},\"version\":1}"
    )

    w75_writer_raw_stream(destination, "payload.dynamic_structure").should eq(W75_WRITER_STRUCTURE.to_a)
    w75_writer_raw_stream(destination, "payload.variant_discr").should eq(discriminator.to_a)
    w75_writer_raw_u64_stream(destination, "payload.String.size").should eq(string_sizes)
    w75_writer_raw_stream(destination, "payload.String").should eq(string_bytes)
    w75_writer_raw_u64_stream(destination, "payload.UInt64").should eq(uint64_values)
    {"payload.SharedVariant.size", "payload.SharedVariant"}.each do |stream|
      data_path = File.join(destination, "#{CrystalClick::StreamName.hash(stream)}.bin")
      File.exists?(data_path).should be_true
      File.size(data_path).should eq(0)
    end

    w75_writer_marks(destination, "pk").should eq(
      w75_writer_expected_frames([24_i64, 24_i64, 8_i64], [3_u64, 3_u64, 1_u64])
    )
    w75_writer_marks(destination, "payload.dynamic_structure").should eq(
      [{0_u64, 11_u64, 3_u64}, {0_u64, 11_u64, 3_u64}, {0_u64, 11_u64, 1_u64}, {0_u64, 16_u64, 0_u64}]
    )
    w75_writer_marks(destination, "payload.variant_discr").should eq(discriminator_marks)
    w75_writer_marks(destination, "payload.SharedVariant.size").should eq(w75_writer_expected_empty([3_u64, 3_u64, 1_u64]))
    w75_writer_marks(destination, "payload.SharedVariant").should eq(w75_writer_expected_empty([3_u64, 3_u64, 1_u64]))
    w75_writer_marks(destination, "payload.String.size").should eq(string_size_marks)
    w75_writer_marks(destination, "payload.String").should eq(string_marks)
    w75_writer_marks(destination, "payload.UInt64").should eq(uint64_marks)

    expected_checksums = ["count.txt", "primary.idx", "serialization.json"]
    (["pk"] + streams).each do |stream|
      base = CrystalClick::StreamName.hash(stream)
      expected_checksums << "#{base}.bin"
      expected_checksums << "#{base}.mrk2"
    end
    checksums = CrystalClick::PartChecksums.open(destination)
    checksums.entries.keys.sort.should eq(expected_checksums.sort)
    checksums.entries.each_key { |name| checksums.validate_selected_entries(destination, name) }
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w75_writer_reject_input(
  parent : String,
  name : String,
  key_name : String,
  keys : Array(UInt64),
  values : Array(CrystalClick::VariantStringUInt64Value),
  rows_per_mark : Int32 = 3,
) : Nil
  destination = File.join(parent, name)
  expect_raises(ArgumentError) do
    CrystalClick::WidePartWriter.write_uint64_dynamic_string_uint64_pair(
      destination,
      key_name,
      keys.to_unsafe.to_slice(keys.size),
      "payload",
      values.to_unsafe.to_slice(values.size),
      rows_per_mark: rows_per_mark
    )
  end
  File.exists?(destination).should be_false
end

describe CrystalClick::WidePartWriter do
  it "writes the canonical Dynamic two-arm profile for String-first mixed rows" do
    w75_writer_assert_part(
      W75_WRITER_VALUES,
      W75_WRITER_STRING_FIRST_DISCRIMINATOR,
      [5_u64, 0_u64, 3_u64],
      [0x61_u8, 0x6c_u8, 0x70_u8, 0x68_u8, 0x61_u8, 0x61_u8, 0_u8, 0x62_u8],
      [0_u64, UInt64::MAX],
      w75_writer_expected_frames([8_i64, 16_i64, 0_i64], [3_u64, 3_u64, 1_u64]),
      w75_writer_expected_frames([5_i64, 3_i64, 0_i64], [3_u64, 3_u64, 1_u64]),
      w75_writer_expected_frames([8_i64, 0_i64, 8_i64], [3_u64, 3_u64, 1_u64]),
      w75_writer_expected_frames([13_i64, 5_i64, 3_i64], [3_u64, 3_u64, 1_u64], 8_u64)
    )
  end

  it "keeps the canonical tags and metadata when UInt64 is the first row" do
    w75_writer_assert_part(
      W75_WRITER_UINT64_FIRST_VALUES,
      W75_WRITER_UINT64_FIRST_DISCRIMINATOR,
      [1_u64, 0_u64, 4_u64],
      [0x73_u8, 0x74_u8, 0x61_u8, 0x69_u8, 0x6c_u8],
      [42_u64, UInt64::MAX],
      w75_writer_expected_frames([8_i64, 8_i64, 8_i64], [3_u64, 3_u64, 1_u64]),
      w75_writer_expected_frames([1_i64, 0_i64, 4_i64], [3_u64, 3_u64, 1_u64]),
      w75_writer_expected_frames([8_i64, 8_i64, 0_i64], [3_u64, 3_u64, 1_u64]),
      w75_writer_expected_frames([13_i64, 5_i64, 3_i64], [3_u64, 3_u64, 1_u64], 8_u64)
    )
  end

  it "rejects partial Dynamic arms and malformed inputs before publication" do
    parent = File.tempname("crystal-click-w75-dynamic-reject")
    Dir.mkdir(parent)
    begin
      w75_writer_reject_input(parent, "mismatched-rows", "pk", [1_u64, 2_u64], ["x"] of CrystalClick::VariantStringUInt64Value)
      w75_writer_reject_input(parent, "unsorted-keys", "pk", [2_u64, 1_u64], ["x", 2_u64] of CrystalClick::VariantStringUInt64Value)
      w75_writer_reject_input(parent, "invalid-key-name", "bad.name", [1_u64, 2_u64], ["x", 2_u64] of CrystalClick::VariantStringUInt64Value)
      w75_writer_reject_input(parent, "zero-mark-size", "pk", [1_u64, 2_u64], ["x", 2_u64] of CrystalClick::VariantStringUInt64Value, 0)
      w75_writer_reject_input(parent, "oversize-mark-size", "pk", [1_u64, 2_u64], ["x", 2_u64] of CrystalClick::VariantStringUInt64Value, 65_537)
      w75_writer_reject_input(parent, "all-null", "pk", [1_u64, 2_u64], [nil, nil] of CrystalClick::VariantStringUInt64Value)
      w75_writer_reject_input(parent, "uint64-only", "pk", [1_u64, 2_u64], [1_u64, 2_u64] of CrystalClick::VariantStringUInt64Value)
      w75_writer_reject_input(parent, "string-only", "pk", [1_u64, 2_u64], ["x", "y"] of CrystalClick::VariantStringUInt64Value)

      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_dynamic_string_uint64_pair(
          File.join(parent, "missing", "part"),
          "pk",
          W75_WRITER_KEYS.to_unsafe.to_slice(W75_WRITER_KEYS.size),
          "payload",
          W75_WRITER_VALUES.to_unsafe.to_slice(W75_WRITER_VALUES.size),
          rows_per_mark: 3
        )
      end

      collision = File.join(parent, "existing")
      File.write(collision, "preserve this user data")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_dynamic_string_uint64_pair(
          collision,
          "pk",
          W75_WRITER_KEYS.to_unsafe.to_slice(W75_WRITER_KEYS.size),
          "payload",
          W75_WRITER_VALUES.to_unsafe.to_slice(W75_WRITER_VALUES.size),
          rows_per_mark: 3
        )
      end
      File.read(collision).should eq("preserve this user data")
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
