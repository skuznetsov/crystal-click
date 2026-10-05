require "./spec_helper"

private def w176_reader_type(label : String) : CrystalClick::BinaryDataType
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  case label
  when "none"
    CrystalClick::BinaryDataType.aggregate_count
  when "uint64"
    CrystalClick::BinaryDataType.aggregate_count(uint64)
  when "nullable"
    CrystalClick::BinaryDataType.aggregate_count(CrystalClick::BinaryDataType.nullable(uint64))
  else
    raise ArgumentError.new("unknown W176 reader profile")
  end
end

private def w176_reader_counts : Array(UInt64)
  [0_u64, 127_u64, 128_u64, 16_384_u64, UInt64::MAX]
end

private def w176_reader_profile_names : Array(Tuple(String, String))
  [
    {"none", "AggregateFunction(count)"},
    {"uint64", "AggregateFunction(count, UInt64)"},
    {"nullable", "AggregateFunction(count, Nullable(UInt64))"},
  ]
end

private def w176_serializer_json(serializers : String, version : Int32 = 1, type_versions : String = "\"string\":1") : String
  %({"version":#{version},"columns":[#{serializers}],"types_serialization_versions":{#{type_versions}},"propagate_types_serialization_versions_to_nested_types":true})
end

private def w176_stock_key_serializer(name : String = "pk", rows : Int32 = 5) : String
  %({"kind":"Default","name":"#{name}","num_defaults":0,"num_rows":#{rows},"exact_num_defaults":true})
end

private def w176_read_u32(bytes : Bytes, offset : Int) : UInt32
  value = 0_u32
  4.times { |byte| value |= bytes[offset + byte].to_u32 << (byte * 8) }
  value
end

private def w176_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w176_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w176_write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
  8.times { |byte| io.write_byte(((hash[0] >> (byte * 8)) & 0xff_u64).to_u8) }
  8.times { |byte| io.write_byte(((hash[1] >> (byte * 8)) & 0xff_u64).to_u8) }
end

private def w176_lz4_literal_frame(bytes : Bytes) : Bytes
  compressed = IO::Memory.new
  if bytes.size < 15
    compressed.write_byte((bytes.size << 4).to_u8)
  else
    compressed.write_byte(0xf0_u8)
    remainder = bytes.size - 15
    while remainder >= 255
      compressed.write_byte(255_u8)
      remainder -= 255
    end
    compressed.write_byte(remainder.to_u8)
  end
  compressed.write(bytes)
  payload = compressed.to_slice

  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload.size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload.size
  4.times { |byte| frame[header + 1 + byte] = ((compressed_size >> (byte * 8)) & 0xff).to_u8 }
  4.times { |byte| frame[header + 5 + byte] = ((bytes.size >> (byte * 8)) & 0xff).to_u8 }
  payload.copy_to(frame[CrystalClick::CompressedBlock::FRAME_HEADER_SIZE, payload.size])
  checksum = CrystalClick::CityHashV1.hash128(frame[header, compressed_size])
  w176_write_u64(frame, 0, checksum[0])
  w176_write_u64(frame, 8, checksum[1])
  frame
end

private def w176_refresh_checksums(part : String, raw_overrides : Hash(String, Bytes) = Hash(String, Bytes).new) : Nil
  parsed = CrystalClick::PartChecksums.open(part)
  payload = IO::Memory.new
  names = parsed.entries.keys.sort
  w176_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    file_bytes = File.read(File.join(part, name)).to_slice
    entry = parsed.entries[name]
    w176_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w176_write_varuint(payload, file_bytes.size.to_u64)
    w176_write_hash(payload, CrystalClick::CityHashV1.file_hash(file_bytes))
    if entry.compressed
      raw = raw_overrides[name]? || CrystalClick::CompressedBlock.decode_all(file_bytes)
      payload.write_byte(1_u8)
      w176_write_varuint(payload, raw.size.to_u64)
      w176_write_hash(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end
  output = IO::Memory.new
  output << CrystalClick::PartChecksums::CHECKSUMS_HEADER
  output.write(w176_lz4_literal_frame(payload.to_slice))
  File.write(File.join(part, "checksums.txt"), output.to_slice)
end

private def w176_with_stock_copy(label : String, stock_root : String, destination_name : String, & : String ->)
  parent = File.tempname("crystal-click-w176-reader")
  Dir.mkdir(parent)
  path = File.join(parent, destination_name)
  FileUtils.cp_r(File.join(stock_root, "part-#{label}"), path)
  yield path
ensure
  FileUtils.rm_rf(parent) if parent && Dir.exists?(parent)
end

describe "W176 AggregateFunction(count) Wide-part reader" do
  it "owns exact nominal descriptors and one variable-width stream" do
    w176_reader_profile_names.each do |label, type_name|
      type = w176_reader_type(label)
      plan = CrystalClick::WideAggregateCountStoragePlan.require(type)
      plan.type_name.should eq(type_name)
      plan.physical_streams("c").should eq(["c"])
      plan.stream_width("c", "c").should eq(1)
      expect_raises(CrystalClick::UnsupportedFormatError) { plan.stream_width("c", "c.size") }
      CrystalClick::WideAggregateCountStoragePlan.for_type_name("Array(#{type_name})").should be_nil
    end

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::WideAggregateCountStoragePlan.require(CrystalClick::BinaryDataType.primitive("UInt64"))
    end

    plan = CrystalClick::WideAggregateCountStoragePlan.require(w176_reader_type("none"))
    plan.maximum_state_bytes(CrystalClick::WideAggregateCountStoragePlan::MAX_MARK_RANGE_ROWS).should eq(655_360)
    expect_raises(CrystalClick::CorruptPartError) do
      plan.maximum_state_bytes(CrystalClick::WideAggregateCountStoragePlan::MAX_MARK_RANGE_ROWS + 1_u64)
    end
  end

  it "decodes canonical VarUInt values into nominal owned Count states" do
    type = w176_reader_type("none")
    max_value = Bytes[0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0x01_u8]
    values = CrystalClick::WideAggregateCountStateReader.read(max_value, 1_u64, type)
    values.map(&.count_state).should eq([UInt64::MAX])
    values.each { |value| value.type.should eq(type) }
    values[0].bytes.should eq(Bytes[0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8])
    CrystalClick::WideAggregateCountStateReader.read(Bytes.empty, 0_u64, type).should be_empty

    same_count_other_type = CrystalClick::BinaryValue.aggregate_count_state(w176_reader_type("uint64"), 7_u64)
    count_value = CrystalClick::BinaryValue.aggregate_count_state(type, 7_u64)
    count_value.should_not eq(same_count_other_type)
  end

  it "admits only the two exact paired serialization metadata forms" do
    w176_reader_profile_names.each do |label, type_name|
      columns = [{"pk", "UInt64"}, {"c", type_name}]
      CrystalClick::WideAggregateCountSerializationProfile.validate!(
        w176_serializer_json(""), columns, "c", type_name, 5_u64
      )
      CrystalClick::WideAggregateCountSerializationProfile.validate!(
        w176_serializer_json(w176_stock_key_serializer), columns, "c", type_name, 5_u64
      )
    end
  end

  it "rejects sparse, Count-owned, partial, mismatched, and unknown serializer metadata" do
    type_name = "AggregateFunction(count)"
    columns = [{"pk", "UInt64"}, {"c", type_name}]
    sparse = %({"kind":"Sparse","name":"pk","num_defaults":0,"num_rows":5,"exact_num_defaults":true})
    count_serializer = w176_stock_key_serializer("c")
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::WideAggregateCountSerializationProfile.validate!(w176_serializer_json(sparse), columns, "c", type_name, 5_u64)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::WideAggregateCountSerializationProfile.validate!(w176_serializer_json(count_serializer), columns, "c", type_name, 5_u64)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::WideAggregateCountSerializationProfile.validate!(w176_serializer_json("#{w176_stock_key_serializer},#{count_serializer}"), columns, "c", type_name, 5_u64)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::WideAggregateCountSerializationProfile.validate!(w176_serializer_json(w176_stock_key_serializer("other")), columns, "c", type_name, 5_u64)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::WideAggregateCountSerializationProfile.validate!(
        w176_serializer_json(""), [{"pk", "UInt32"}, {"c", type_name}], "c", type_name, 5_u64
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::WideAggregateCountSerializationProfile.validate!(w176_serializer_json("", type_versions: "\"string\":1,\"nullable\":0"), columns, "c", type_name, 5_u64)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::WideAggregateCountSerializationProfile.validate!(w176_serializer_json("", type_versions: "\"string\":2"), columns, "c", type_name, 5_u64)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::WideAggregateCountSerializationProfile.validate!(
        w176_serializer_json("").sub("\"types_serialization_versions\":{\"string\":1},", ""),
        columns, "c", type_name, 5_u64
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::WideAggregateCountSerializationProfile.validate!(
        w176_serializer_json("").sub("\"propagate_types_serialization_versions_to_nested_types\":true", "\"propagate_types_serialization_versions_to_nested_types\":true,\"future\":1"),
        columns, "c", type_name, 5_u64
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::WideAggregateCountSerializationProfile.validate!(w176_serializer_json("", version: 2), columns, "c", type_name, 5_u64)
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::WideAggregateCountSerializationProfile.validate!(
        w176_serializer_json(w176_stock_key_serializer), columns, "c", type_name, 4_u64
      )
    end
  end

  it "rejects malformed, nonminimal, trailing, and over-budget state lanes" do
    type = w176_reader_type("none")
    malformed = [
      {Bytes[0x80_u8], 1_u64},
      {Bytes[0x80_u8, 0x00_u8], 1_u64},
      {Bytes[0x01_u8, 0x00_u8], 1_u64},
      {Bytes[0x80_u8, 0x80_u8, 0x80_u8, 0x80_u8, 0x80_u8, 0x80_u8, 0x80_u8, 0x80_u8, 0x80_u8, 0x02_u8], 1_u64},
      {Bytes[0x80_u8, 0x80_u8, 0x80_u8, 0x80_u8, 0x80_u8, 0x80_u8, 0x80_u8, 0x80_u8, 0x80_u8, 0x80_u8], 1_u64},
      {Bytes[0x00_u8], 2_u64},
      {Bytes.new(11, 0_u8), 1_u64},
    ]
    malformed.each do |bytes, rows|
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WideAggregateCountStateReader.read(bytes, rows, type)
      end
    end

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::WideAggregateCountStateReader.read(Bytes.empty, CrystalClick::WideAggregateCountStoragePlan::MAX_MARK_RANGE_ROWS + 1_u64, type)
    end
  end

  if stock_root = ENV["W176_STOCK_ROOT"]?
    counts = w176_reader_counts
    w176_reader_profile_names.each do |label, type_name|
      it "reads stock #{type_name} across whole, single-mark, and multi-mark windows" do
        type = w176_reader_type(label)
        part_path = File.join(stock_root, "part-#{label}")
        part = CrystalClick::WidePart.open_typed(part_path, "c")
        part.column_type.should eq(type_name)
        part.row_count.should eq(5_u64)
        part.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])

        whole = part.read_aggregate_count_mark_range("c", 0, part.mark_count, expected_type: type)
        whole.map(&.count_state).should eq(counts)
        whole.each { |value| value.type.should eq(type) }
        part.read_aggregate_count_mark_range("c", 1, 1, expected_type: type).map(&.count_state).should eq([128_u64, 16_384_u64])
        part.read_aggregate_count_mark_range("c", 1, 2, expected_type: type).map(&.count_state).should eq([128_u64, 16_384_u64, UInt64::MAX])

        wrong_type = label == "none" ? CrystalClick::BinaryDataType.aggregate_count(CrystalClick::BinaryDataType.primitive("UInt64")) : CrystalClick::BinaryDataType.aggregate_count
        expect_raises(CrystalClick::UnsupportedFormatError) do
          part.read_aggregate_count_mark_range("c", 0, 1, expected_type: wrong_type)
        end
        expect_raises(CrystalClick::UnsupportedFormatError) do
          part.read_uint64_mark_range("c", 0, 1)
        end
        expect_raises(CrystalClick::BoundsError) do
          part.read_aggregate_count_mark_range("c", 0, 0, expected_type: type)
        end
      end
    end

    it "keeps the typed table's unsupported Count route fail-closed before callbacks" do
      w176_with_stock_copy("none", stock_root, "all_1_1_0") do |path|
        table = CrystalClick::WidePartTable.open_selected_typed([path], ["c"])
        callbacks = 0
        expect_raises(CrystalClick::UnsupportedFormatError) do
          table.scan_typed do |_batch|
            callbacks += 1
          end
        end
        callbacks.should eq(0)
      end
    end

    it "requires serialization.json for the exact Count profile" do
      w176_with_stock_copy("none", stock_root, "part-none") do |path|
        File.delete(File.join(path, "serialization.json"))
        expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::WidePart.open_typed(path, "c")
        end
      end
    end

    it "rejects a Count mark range whose internal row boundary was redistributed, even with refreshed checksums" do
      w176_with_stock_copy("none", stock_root, "part-none") do |path|
        marks_path = File.join(path, "#{CrystalClick::StreamName.hash("c")}.mrk2")
        marks = File.read(marks_path).to_slice.dup
        # The fixture has three marks and a terminal record. Move the
        # boundary between the first two one-byte states from byte 2 to byte 1.
        mark_one_decompressed_offset = CrystalClick::WidePart::MARK_SIZE + 8
        w176_write_u64(marks, mark_one_decompressed_offset, 1_u64)
        File.write(marks_path, marks)
        w176_refresh_checksums(path)

        mark_file = "#{CrystalClick::StreamName.hash("c")}.mrk2"
        checksums = CrystalClick::PartChecksums.open(path)
        checksums.entry(mark_file).not_nil!.file_hash.should eq(CrystalClick::CityHashV1.file_hash(File.read(marks_path).to_slice))
        part = CrystalClick::WidePart.open_typed(path, "c")
        expect_raises(CrystalClick::CorruptPartError) do
          part.read_aggregate_count_mark_range("c", 0, 3, expected_type: w176_reader_type("none"))
        end
      end
    end

    it "refuses a non-LZ4 frame header after refreshed frame and part checksums" do
      w176_with_stock_copy("none", stock_root, "part-none") do |path|
        data_name = "#{CrystalClick::StreamName.hash("c")}.bin"
        data_path = File.join(path, data_name)
        frame = File.read(data_path).to_slice.dup
        raw = CrystalClick::CompressedBlock.decode_all(frame)
        header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
        frame[header] = CrystalClick::CompressedBlock::METHOD_ZSTD
        compressed_size = w176_read_u32(frame, header + 1).to_i
        compressed_size.should eq(frame.size - header)
        checksum = CrystalClick::CityHashV1.hash128(frame[CrystalClick::CompressedBlock::CHECKSUM_SIZE, compressed_size])
        w176_write_u64(frame, 0, checksum[0])
        w176_write_u64(frame, 8, checksum[1])
        File.write(data_path, frame)
        raw_overrides = Hash(String, Bytes).new
        raw_overrides[data_name] = raw
        w176_refresh_checksums(path, raw_overrides)
        checksums = CrystalClick::PartChecksums.open(path)
        checksums.entry(data_name).not_nil!.file_hash.should eq(CrystalClick::CityHashV1.file_hash(frame))

        part = CrystalClick::WidePart.open_typed(path, "c")
        # The frame checksum and part checksum agree with the mutated header;
        # the payload is intentionally not a ZSTD stream. Count must reject
        # the method before the decoder interprets that payload.
        expect_raises(CrystalClick::UnsupportedFormatError) do
          part.read_aggregate_count_mark_range("c", 0, 1, expected_type: w176_reader_type("none"))
        end
      end
    end

    it "rejects a mutated compressed-frame checksum when part checksums are refreshed" do
      w176_with_stock_copy("none", stock_root, "part-none") do |path|
        data_name = "#{CrystalClick::StreamName.hash("c")}.bin"
        data_path = File.join(path, data_name)
        frame = File.read(data_path).to_slice.dup
        raw = CrystalClick::CompressedBlock.decode_all(frame)
        original_size = frame.size
        frame[0] = frame[0] ^ 0x01_u8
        File.write(data_path, frame)
        raw_overrides = Hash(String, Bytes).new
        raw_overrides[data_name] = raw
        w176_refresh_checksums(path, raw_overrides)

        entry = CrystalClick::PartChecksums.open(path).entry(data_name).not_nil!
        entry.physical_size.should eq(original_size.to_u64)
        entry.file_hash.should eq(CrystalClick::CityHashV1.file_hash(frame))

        part = CrystalClick::WidePart.open_typed(path, "c")
        expect_raises(CrystalClick::CorruptPartError) do
          part.read_aggregate_count_mark_range("c", 0, 1, expected_type: w176_reader_type("none"))
        end
      end
    end
  end
end
