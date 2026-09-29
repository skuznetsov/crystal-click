require "./wide_part_w80_helpers"
require "./w69_helpers"

private def w80_table_set_mark_frame_method(path : String, stream : String, mark_index : Int, method : UInt8) : Nil
  stream_hash = CrystalClick::StreamName.hash(stream)
  marks = File.read(File.join(path, "#{stream_hash}.mrk2")).to_slice
  mark_offset = mark_index * CrystalClick::WidePart::MARK_SIZE
  compressed_offset = 0_u64
  8.times { |byte| compressed_offset |= marks[mark_offset + byte].to_u64 << (byte * 8) }

  data_path = File.join(path, "#{stream_hash}.bin")
  data = File.read(data_path).to_slice.dup
  frame_offset = compressed_offset.to_i
  data[frame_offset + CrystalClick::CompressedBlock::CHECKSUM_SIZE] = method

  size_offset = frame_offset + CrystalClick::CompressedBlock::CHECKSUM_SIZE + 1
  compressed_size = 0_u32
  4.times { |byte| compressed_size |= data[size_offset + byte].to_u32 << (byte * 8) }
  checksum = CrystalClick::CityHashV1.hash128(
    data[frame_offset + CrystalClick::CompressedBlock::CHECKSUM_SIZE, compressed_size.to_i]
  )
  8.times do |byte|
    data[frame_offset + byte] = ((checksum[0] >> (byte * 8)) & 0xff_u64).to_u8
    data[frame_offset + 8 + byte] = ((checksum[1] >> (byte * 8)) & 0xff_u64).to_u8
  end
  File.write(data_path, data)
end

describe "W80 typed table Array(Map) batches" do
  it "materializes ordered nested Maps across marks and typed batch slices" do
    with_w80_part do |_parent, part|
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      actual = [] of Array(Array(Tuple(String, UInt64)))
      table.scan_typed(batch_rows: 1) do |batch|
        actual.concat(batch.array_map_string_uint64s_for("payload").to_a)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.map_string_array_uint64s_for("payload")
        end
      end
      actual.should eq(W80_ROWS)
      actual[0][0][0].should eq({"dup", 0_u64})
      actual[0][0][1].should eq({"dup", UInt64::MAX})
      actual[2][0][0][0].should eq(W80_BINARY_KEY)

      selected = [] of Array(Array(Tuple(String, UInt64)))
      table.scan_typed_window(2_u64, 2) do |batch|
        selected.concat(batch.array_map_string_uint64s_for("payload").to_a)
      end
      selected.should eq(W80_ROWS[2, 2])
    end
  end

  it "rejects a shifted later inner-offset mark before yielding that mark" do
    with_w80_part do |_parent, part|
      w69_shift_mark(part, "payload.size1", 1)
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed_window(2_u64, 2) do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)
    end
  end

  it "classifies a checksummed non-LZ4 frame as unsupported" do
    with_w80_part do |_parent, part|
      w80_table_set_mark_frame_method(
        part,
        "payload.size1",
        1,
        CrystalClick::CompressedBlock::METHOD_ZSTD
      )
      reader = CrystalClick::WidePart.open_typed(part, "payload")

      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_array_map_string_uint64_mark_range("payload", 1, 1)
      end
    end
  end
end
