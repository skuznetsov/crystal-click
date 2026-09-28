require "./w70_helpers"

private def w70_raw_stream(path : String, stream : String) : Array(UInt8)
  encoded = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  return [] of UInt8 if encoded.empty?
  CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w70_raw_u64_stream(path : String, stream : String) : Array(UInt64)
  bytes = w70_raw_stream(path, stream)
  raise "W70 UInt64 stream is not aligned: #{stream}" unless bytes.size % 8 == 0
  Array(UInt64).new(bytes.size // 8) do |index|
    w70_read_u64(bytes.to_unsafe.to_slice(bytes.size), index * 8)
  end
end

private def w70_assert_marks(
  path : String,
  stream : String,
  raw_mark_sizes : Array(Int32),
  expected_rows : Array(UInt64),
) : Nil
  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice
  marks.size.should eq((raw_mark_sizes.size + 1) * CrystalClick::WidePart::MARK_SIZE)
  w70_mark_rows(path, stream).should eq(expected_rows + [0_u64])

  encoded = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  compressed_offset = 0_i64
  raw_mark_sizes.each_with_index do |raw_size, index|
    w70_read_u64(marks, index * CrystalClick::WidePart::MARK_SIZE).should eq(compressed_offset.to_u64)
    w70_read_u64(marks, index * CrystalClick::WidePart::MARK_SIZE + 8).should eq(0_u64)
    next if raw_size == 0
    frame = CrystalClick::CompressedBlock.decode_frame(
      encoded,
      compressed_offset,
      CrystalClick::WidePartWriter::MAX_FRAME_COMPRESSED.to_i64,
      CrystalClick::WidePartWriter::MAX_FRAME_RAW_BYTES.to_i64
    )
    frame.output.size.should eq(raw_size)
    compressed_offset = frame.end_offset
  end
  terminal = raw_mark_sizes.size * CrystalClick::WidePart::MARK_SIZE
  w70_read_u64(marks, terminal).should eq(compressed_offset.to_u64)
  w70_read_u64(marks, terminal + 8).should eq(0_u64)
  w70_read_u64(marks, terminal + 16).should eq(0_u64)
  compressed_offset.should eq(encoded.size.to_i64)
  nil
end

describe CrystalClick::WidePartWriter do
  it "writes exact Map(String, Array(Nullable(String))) streams with independent nested axes" do
    with_w70_part do |part|
      File.read(File.join(part, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`id` UInt64\n`m` Map(String, Array(Nullable(String)))\n"
      )
      File.read(File.join(part, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `id`:\n\tid\n" +
        "7 substreams for column `m`:\n" + W70_STREAMS.map { |stream| "\t#{stream}\n" }.join
      )
      File.read(File.join(part, "serialization.json")).should eq(
        %({"columns":[{"kind":"Default","name":"id","num_defaults":1,"num_rows":7}],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
      )
      File.read(File.join(part, "default_compression_codec.txt")).should eq("CODEC(LZ4)")
      File.read(File.join(part, "metadata_version.txt")).should eq("0")
      File.read(File.join(part, "count.txt")).should eq("7")

      W70_VALUES.map(&.size).should eq([3, 0, 1, 2, 2, 1, 2])
      w70_raw_u64_stream(part, "m.size0").should eq([3_u64, 0_u64, 1_u64, 2_u64, 2_u64, 1_u64, 2_u64])
      w70_raw_u64_stream(part, "m%2Ekeys.size").should eq([3_u64, 3_u64, 3_u64, 11_u64, 1_u64, 2_u64, 5_u64, 6_u64, 5_u64, 4_u64, 5_u64])
      w70_raw_stream(part, "m%2Ekeys").should eq("dupdupdupempty_arrayxx2laterlater2latertailtail2".to_slice.to_a)
      w70_raw_u64_stream(part, "m%2Evalues.size1").should eq([4_u64, 1_u64, 1_u64, 0_u64, 1_u64, 2_u64, 2_u64, 1_u64, 1_u64, 2_u64, 1_u64])
      w70_raw_stream(part, "m%2Evalues.null").should eq([1_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 1_u8, 1_u8, 1_u8, 1_u8, 0_u8, 0_u8, 0_u8])
      w70_raw_u64_stream(part, "m%2Evalues.size").should eq([0_u64, 0_u64, 3_u64, 5_u64, 4_u64, 9_u64, 2_u64, 2_u64, 3_u64, 0_u64, 0_u64, 0_u64, 0_u64, 10_u64, 0_u64, 5_u64])
      w70_raw_stream(part, "m%2Evalues").should eq("a\0bcafétaildup-thirdx3x2x2bafter-nulltail2".to_slice.to_a)

      mark_rows = [2_u64, 2_u64, 2_u64, 1_u64]
      {
        {"id", [16, 16, 16, 8]},
        {"m.size0", [16, 16, 16, 8]},
        {"m%2Ekeys.size", [24, 24, 24, 16]},
        {"m%2Ekeys", [9, 14, 16, 9]},
        {"m%2Evalues.size1", [24, 24, 24, 16]},
        {"m%2Evalues.null", [6, 3, 4, 3]},
        {"m%2Evalues.size", [48, 24, 32, 24]},
        {"m%2Evalues", [21, 7, 0, 15]},
      }.each do |stream, raw_sizes|
        w70_assert_marks(part, stream, raw_sizes, mark_rows)
      end

      w70_mark_decompressed_offsets(part, "m%2Ekeys.size").should eq([0_u64, 0_u64, 0_u64, 0_u64, 0_u64])
      w70_mark_decompressed_offsets(part, "m%2Ekeys").should eq([0_u64, 0_u64, 0_u64, 0_u64, 0_u64])
      w70_mark_decompressed_offsets(part, "m%2Evalues.null").should eq([0_u64, 0_u64, 0_u64, 0_u64, 0_u64])
      w70_mark_decompressed_offsets(part, "m%2Evalues.size").should eq([0_u64, 0_u64, 0_u64, 0_u64, 0_u64])
      w70_mark_decompressed_offsets(part, "m%2Evalues").should eq([0_u64, 0_u64, 0_u64, 0_u64, 0_u64])

      expected_files = ["count.txt", "primary.idx", "serialization.json"]
      (W70_STREAMS + ["id"]).each do |stream|
        base = CrystalClick::StreamName.hash(stream)
        expected_files << "#{base}.bin"
        expected_files << "#{base}.mrk2"
      end
      checksums = CrystalClick::PartChecksums.open(part)
      checksums.entries.keys.sort.should eq(expected_files.sort)
      checksums.entries.each_key { |name| checksums.validate_selected_entries(part, name) }

      original_checksums = File.read(File.join(part, "checksums.txt"))
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_map_string_array_nullable_string_pair(
          part,
          "id",
          W70_KEYS.to_unsafe.to_slice(W70_KEYS.size),
          "m",
          W70_VALUES.to_unsafe.to_slice(W70_VALUES.size),
          rows_per_mark: 2
        )
      end
      File.read(File.join(part, "checksums.txt")).should eq(original_checksums)
    end
  end

  it "keeps NULL canonical as size zero and emits no hidden raw String bytes" do
    with_w70_part do |part|
      nulls = w70_raw_stream(part, "m%2Evalues.null")
      sizes = w70_raw_u64_stream(part, "m%2Evalues.size")
      raw_values = w70_raw_stream(part, "m%2Evalues")
      nulls.each_with_index do |is_null, index|
        next unless is_null == 1_u8
        sizes[index].should eq(0_u64)
      end
      raw_values.should eq("a\0bcafétaildup-thirdx3x2x2bafter-nulltail2".to_slice.to_a)
      raw_values.size.should eq(43)
    end
  end

  it "preserves positive-row all-empty Map marks and empty String keys and values" do
    parent = File.tempname("crystal-click-wide-writer-w70-empty-axes")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [0_u64, 1_u64, 2_u64, 3_u64]
    values = [
      [] of Tuple(String, Array(String?)),
      [] of Tuple(String, Array(String?)),
      [{"", [""] of String?}] of Tuple(String, Array(String?)),
      [] of Tuple(String, Array(String?)),
    ] of Array(Tuple(String, Array(String?)))
    begin
      CrystalClick::WidePartWriter.write_uint64_map_string_array_nullable_string_pair(
        destination,
        "id",
        keys.to_unsafe.to_slice(keys.size),
        "m",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 2
      )

      w70_raw_u64_stream(destination, "m.size0").should eq([0_u64, 0_u64, 1_u64, 0_u64])
      w70_raw_u64_stream(destination, "m%2Ekeys.size").should eq([0_u64])
      w70_raw_stream(destination, "m%2Ekeys").should eq([] of UInt8)
      w70_raw_u64_stream(destination, "m%2Evalues.size1").should eq([1_u64])
      w70_raw_stream(destination, "m%2Evalues.null").should eq([0_u8])
      w70_raw_u64_stream(destination, "m%2Evalues.size").should eq([0_u64])
      w70_raw_stream(destination, "m%2Evalues").should eq([] of UInt8)
      w70_mark_rows(destination, "m%2Ekeys").should eq([2_u64, 2_u64, 0_u64])
      w70_mark_rows(destination, "m%2Evalues").should eq([2_u64, 2_u64, 0_u64])
      reader = CrystalClick::WidePart.open_typed(destination, "m")
      reader.read_map_string_array_nullable_string_mark_range("m", 0, reader.mark_count).should eq(values)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects Map-entry overflow before creating a staged or published part" do
    parent = File.tempname("crystal-click-wide-writer-w70-entry-overflow")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    too_many_entries = Array(Tuple(String, Array(String?))).new(
      (CrystalClick::WidePart::MAX_ARRAY_MARK_ELEMENTS + 1_u64).to_i
    ) { {"k", [] of String?} }
    values = [too_many_entries] of Array(Tuple(String, Array(String?)))
    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_map_string_array_nullable_string_pair(
          destination,
          "id",
          [1_u64].to_unsafe.to_slice(1),
          "m",
          values.to_unsafe.to_slice(values.size),
          rows_per_mark: 1
        )
      end
      Dir.children(parent).should eq([] of String)
      File.exists?(destination).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects flattened nullable String leaf overflow before staging" do
    parent = File.tempname("crystal-click-wide-writer-w70-leaf-overflow")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    too_many_values = Array(String?).new((CrystalClick::WidePart::MAX_ARRAY_MARK_ELEMENTS + 1_u64).to_i, nil)
    values = [[{"one", too_many_values}] of Tuple(String, Array(String?))] of Array(Tuple(String, Array(String?)))
    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_map_string_array_nullable_string_pair(
          destination,
          "id",
          [1_u64].to_unsafe.to_slice(1),
          "m",
          values.to_unsafe.to_slice(values.size),
          rows_per_mark: 1
        )
      end
      Dir.children(parent).should eq([] of String)
      File.exists?(destination).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
