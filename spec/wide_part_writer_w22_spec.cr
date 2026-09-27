require "./spec_helper"

private def w22_writer_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w22_writer_append_u64(bytes : Array(UInt8), value : UInt64) : Nil
  8.times { |byte| bytes << ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w22_writer_append_var_uint(bytes : Array(UInt8), value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    bytes << ((remaining & 0x7f_u64) | 0x80_u64).to_u8
    remaining >>= 7
  end
  bytes << remaining.to_u8
end

private def w22_writer_decoded_bytes(path : String, stream : String) : Array(UInt8)
  CrystalClick::CompressedBlock.decode_all(
    File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  ).to_a
end

private def w22_writer_marks(path : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  bytes = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "W22 test mark file is malformed" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0

  Array(Tuple(UInt64, UInt64, UInt64)).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {
      w22_writer_u64(bytes, offset),
      w22_writer_u64(bytes, offset + 8),
      w22_writer_u64(bytes, offset + 16),
    }
  end
end

describe CrystalClick::WidePartWriter do
  it "writes the shared LowCardinality(String) dictionary and UInt8 ID marks" do
    parent = File.tempname("crystal-click-wide-writer-w22-lowcard")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 2_u64, 4_u64, 9_u64, 11_u64, 13_u64]
    binary = String.new(Bytes[0x61_u8, 0_u8, 0x62_u8])
    invalid_utf8 = String.new(Bytes[0xff_u8, 0_u8])
    values = ["", binary, invalid_utf8, "alpha", "repeat", "alpha", "last"]

    begin
      CrystalClick::WidePartWriter.write_uint64_low_cardinality_string_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 2
      ).should eq(destination)

      key_part = CrystalClick::WidePart.open(destination, "pk")
      payload_part = CrystalClick::WidePart.open_typed(destination, "payload")
      key_part.read_uint64.should eq(keys)
      payload_part.column_type.should eq("LowCardinality(String)")
      payload_part.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
      payload_part.read_low_cardinality_string_mark_range("payload", 0, payload_part.mark_count).should eq(values)
      payload_part.read_low_cardinality_string_mark_range("payload", 1, 2).should eq(values[2, 4])

      dictionary = [] of String
      values.each { |value| dictionary << value unless dictionary.includes?(value) }
      expected_dictionary = [] of UInt8
      w22_writer_append_u64(expected_dictionary, 1_u64)
      w22_writer_append_u64(expected_dictionary, dictionary.size.to_u64)
      dictionary.each do |value|
        w22_writer_append_var_uint(expected_dictionary, value.bytesize.to_u64)
        expected_dictionary.concat(value.to_slice.to_a)
      end
      w22_writer_decoded_bytes(destination, "payload.dict").should eq(expected_dictionary)

      expected_indexes = [] of UInt8
      row = 0
      mark_index = 0
      while row < values.size
        rows = {2, values.size - row}.min
        w22_writer_append_u64(expected_indexes, mark_index == 0 ? 0x500_u64 : 0x100_u64)
        w22_writer_append_u64(expected_indexes, rows.to_u64)
        rows.times do |offset|
          expected_indexes << dictionary.index(values[row + offset]).not_nil!.to_u8
        end
        row += rows
        mark_index += 1
      end
      w22_writer_decoded_bytes(destination, "payload").should eq(expected_indexes)

      dictionary_compressed_size = File.size(File.join(destination, "#{CrystalClick::StreamName.hash("payload.dict")}.bin")).to_u64
      w22_writer_marks(destination, "payload.dict").should eq([
        {0_u64, 8_u64, 2_u64},
        {0_u64, 8_u64, 2_u64},
        {0_u64, 8_u64, 2_u64},
        {0_u64, 8_u64, 1_u64},
        {dictionary_compressed_size, 0_u64, 0_u64},
      ])

      index_marks = w22_writer_marks(destination, "payload")
      index_marks.size.should eq(payload_part.mark_count + 1)
      index_marks.last.should eq({File.size(File.join(destination, "#{CrystalClick::StreamName.hash("payload")}.bin")).to_u64, 0_u64, 0_u64})
      index_marks.map(&.[2]).should eq([2_u64, 2_u64, 2_u64, 1_u64, 0_u64])

      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` LowCardinality(String)\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n2 substreams for column `payload`:\n\tpayload.dict\n\tpayload\n"
      )
      File.read(File.join(destination, "serialization.json")).should eq(
        %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
      )
      File.read(File.join(destination, "default_compression_codec.txt")).should eq("CODEC(LZ4)")

      expected_checksum_names = ["count.txt", "primary.idx", "serialization.json"]
      {"pk", "payload.dict", "payload"}.each do |stream|
        base = CrystalClick::StreamName.hash(stream)
        expected_checksum_names << "#{base}.bin"
        expected_checksum_names << "#{base}.mrk2"
      end
      CrystalClick::PartChecksums.open(destination).entries.keys.sort.should eq(expected_checksum_names.sort)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "accepts repeated and empty keys in a one-value shared dictionary" do
    parent = File.tempname("crystal-click-wide-writer-w22-lowcard-repeated")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    values = ["", "", "", "", ""]

    begin
      CrystalClick::WidePartWriter.write_uint64_low_cardinality_string_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        values.to_unsafe.to_slice(values.size), rows_per_mark: 2
      )

      payload_part = CrystalClick::WidePart.open_typed(destination, "payload")
      payload_part.read_low_cardinality_string_mark_range("payload", 0, payload_part.mark_count).should eq(values)
      w22_writer_decoded_bytes(destination, "payload.dict").should eq(
        [1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8]
      )
      w22_writer_marks(destination, "payload.dict").map { |mark| {mark[0], mark[1]} }.should eq([
        {0_u64, 8_u64}, {0_u64, 8_u64}, {0_u64, 8_u64},
        {File.size(File.join(destination, "#{CrystalClick::StreamName.hash("payload.dict")}.bin")).to_u64, 0_u64},
      ])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "reserves the empty default at ID zero when all input strings are nonempty" do
    parent = File.tempname("crystal-click-wide-writer-w22-lowcard-default-key")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 3_u64]
    values = ["alpha", "beta", "alpha"]

    begin
      CrystalClick::WidePartWriter.write_uint64_low_cardinality_string_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        values.to_unsafe.to_slice(values.size), rows_per_mark: 2
      )

      expected_dictionary = [] of UInt8
      w22_writer_append_u64(expected_dictionary, 1_u64)
      w22_writer_append_u64(expected_dictionary, 3_u64)
      w22_writer_append_var_uint(expected_dictionary, 0_u64)
      w22_writer_append_var_uint(expected_dictionary, 5_u64)
      expected_dictionary.concat("alpha".to_slice.to_a)
      w22_writer_append_var_uint(expected_dictionary, 4_u64)
      expected_dictionary.concat("beta".to_slice.to_a)
      w22_writer_decoded_bytes(destination, "payload.dict").should eq(expected_dictionary)

      expected_indexes = [] of UInt8
      w22_writer_append_u64(expected_indexes, 0x500_u64)
      w22_writer_append_u64(expected_indexes, 2_u64)
      expected_indexes.concat([1_u8, 2_u8])
      w22_writer_append_u64(expected_indexes, 0x100_u64)
      w22_writer_append_u64(expected_indexes, 1_u64)
      expected_indexes << 1_u8
      w22_writer_decoded_bytes(destination, "payload").should eq(expected_indexes)
      CrystalClick::WidePart.open_typed(destination, "payload").read_low_cardinality_string_mark_range("payload", 0, 2).should eq(values)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "allows 256 dictionary entries including the reserved empty default" do
    parent = File.tempname("crystal-click-wide-writer-w22-lowcard-max-dictionary")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = Array(UInt64).new(255) { |index| index.to_u64 }
    values = Array(String).new(255) { |index| "value-#{index}" }

    begin
      CrystalClick::WidePartWriter.write_uint64_low_cardinality_string_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 255
      )
      dictionary = w22_writer_decoded_bytes(destination, "payload.dict")
      w22_writer_u64(dictionary.to_unsafe.to_slice(dictionary.size), 8).should eq(256_u64)
      w22_writer_decoded_bytes(destination, "payload").last.should eq(255_u8)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects invalid inputs, dictionary overflows, and oversized marks before staging" do
    invalid_cases = [
      {keys: [2_u64, 1_u64], values: ["a", "b"], rows_per_mark: 1_i32, key_name: "pk"},
      {keys: [1_u64, 2_u64], values: ["a"], rows_per_mark: 1_i32, key_name: "pk"},
      {keys: [1_u64], values: ["a"], rows_per_mark: 0_i32, key_name: "pk"},
      {keys: [1_u64], values: ["a"], rows_per_mark: 65_537_i32, key_name: "pk"},
      {keys: [1_u64], values: ["a"], rows_per_mark: 1_i32, key_name: "../pk"},
    ]

    invalid_cases.each do |input|
      parent = File.tempname("crystal-click-wide-writer-w22-lowcard-invalid")
      Dir.mkdir(parent)
      destination = File.join(parent, "part")
      begin
        expect_raises(ArgumentError) do
          CrystalClick::WidePartWriter.write_uint64_low_cardinality_string_pair(
            destination,
            input[:key_name],
            input[:keys].to_unsafe.to_slice(input[:keys].size),
            "payload",
            input[:values].to_unsafe.to_slice(input[:values].size),
            rows_per_mark: input[:rows_per_mark]
          )
        end
        Dir.children(parent).should eq([] of String)
      ensure
        FileUtils.rm_rf(parent)
      end
    end

    parent = File.tempname("crystal-click-wide-writer-w22-lowcard-unique-limit")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = Array(UInt64).new(256) { |index| index.to_u64 }
    values = Array(String).new(256) { |index| "value-#{index}" }
    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_low_cardinality_string_pair(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          values.to_unsafe.to_slice(values.size), rows_per_mark: 1
        )
      end
      Dir.children(parent).should eq([] of String)
    ensure
      FileUtils.rm_rf(parent)
    end

    parent = File.tempname("crystal-click-wide-writer-w22-lowcard-mark-bytes")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    oversized_mark_value = String.new(Bytes.new(CrystalClick::WidePart::MAX_STRING_RANGE_BYTES + 1, 0_u8))
    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_low_cardinality_string_pair(
          destination, "pk", [1_u64].to_unsafe.to_slice(1), "payload",
          [oversized_mark_value].to_unsafe.to_slice(1), rows_per_mark: 1
        )
      end
      Dir.children(parent).should eq([] of String)
    ensure
      FileUtils.rm_rf(parent)
    end

    parent = File.tempname("crystal-click-wide-writer-w22-lowcard-dictionary-bytes")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = Array(UInt64).new(255) { |index| (index + 1).to_u64 }
    values = Array(String).new(255) { |index| String.new(Bytes.new(263_200, index.to_u8)) }
    begin
      error = expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_low_cardinality_string_pair(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          values.to_unsafe.to_slice(values.size), rows_per_mark: 1
        )
      end
      error.message.to_s.should contain("dictionary exceeds decoded-size limit")
      Dir.children(parent).should eq([] of String)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects LowCardinality mark counts beyond the reader limit before staging" do
    parent = File.tempname("crystal-click-wide-writer-w22-lowcard-mark-limit")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    row_count = CrystalClick::WidePart::MAX_LOW_CARDINALITY_MARKS + 1
    keys = Array(UInt64).new(row_count) { |index| index.to_u64 }
    values = Array(String).new(row_count) { "same" }

    begin
      error = expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_low_cardinality_string_pair(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          values.to_unsafe.to_slice(values.size), rows_per_mark: 1
        )
      end
      error.message.to_s.should contain("mark count exceeds")
      Dir.children(parent).should eq([] of String)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "leaves an existing destination and its contents unchanged" do
    parent = File.tempname("crystal-click-wide-writer-w22-lowcard-existing")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    Dir.mkdir(destination)
    sentinel = File.join(destination, "keep.txt")
    File.write(sentinel, "preserve")

    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_low_cardinality_string_pair(
          destination, "pk", [1_u64].to_unsafe.to_slice(1), "payload",
          ["value"].to_unsafe.to_slice(1), rows_per_mark: 1
        )
      end
      File.read(sentinel).should eq("preserve")
      Dir.children(parent).should eq(["part"])
      Dir.children(destination).should eq(["keep.txt"])
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
