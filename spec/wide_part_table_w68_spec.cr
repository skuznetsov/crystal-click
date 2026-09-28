require "./spec_helper"

W68_TABLE_KEYS = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
W68_TABLE_ROWS = [
  [{"dup", [nil, 0_u64] of UInt64?}, {"dup", [] of UInt64?}] of Tuple(String, Array(UInt64?)),
  [] of Tuple(String, Array(UInt64?)),
  [{"empty", [] of UInt64?}] of Tuple(String, Array(UInt64?)),
  [{"null", [nil] of UInt64?}, {"zero", [0_u64] of UInt64?}] of Tuple(String, Array(UInt64?)),
  [{"all-null", [nil, nil] of UInt64?}] of Tuple(String, Array(UInt64?)),
  [{"also-null", [nil] of UInt64?}] of Tuple(String, Array(UInt64?)),
  [{"tail", [UInt64::MAX] of UInt64?}] of Tuple(String, Array(UInt64?)),
] of Array(Tuple(String, Array(UInt64?)))

private def with_w68_table_part(& : String ->)
  parent = File.tempname("crystal-click-w68-table")
  Dir.mkdir(parent)
  begin
    part = File.join(parent, "all_1_1_0")
    CrystalClick::WidePartWriter.write_uint64_map_string_array_nullable_uint64_pair(
      part,
      "pk",
      W68_TABLE_KEYS.to_unsafe.to_slice(W68_TABLE_KEYS.size),
      "payload",
      W68_TABLE_ROWS.to_unsafe.to_slice(W68_TABLE_ROWS.size),
      rows_per_mark: 2
    )
    yield part
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w68_table_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w68_table_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w68_table_corrupt_later_null_frame(part : String, mark_index : Int) : Nil
  stream = "payload%2Evalues.null"
  base = CrystalClick::StreamName.hash(stream)
  marks = File.read(File.join(part, "#{base}.mrk2")).to_slice
  mark_offset = mark_index * CrystalClick::WidePart::MARK_SIZE
  compressed_offset = 0_u64
  8.times { |byte| compressed_offset |= marks[mark_offset + byte].to_u64 << (byte * 8) }

  data_path = File.join(part, "#{base}.bin")
  encoded = File.read(data_path).to_slice.dup
  frame = CrystalClick::CompressedBlock.decode_frame(encoded, compressed_offset.to_i64)
  raw = frame.output.dup
  raise "selected W68 null frame is empty" if raw.empty?
  raw[0] = 2_u8

  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  rewritten = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  rewritten[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w68_table_write_u32(rewritten, header + 1, compressed_size.to_u32)
  w68_table_write_u32(rewritten, header + 5, raw.size.to_u32)
  cursor = CrystalClick::CompressedBlock::FRAME_HEADER_SIZE
  if raw.size < 15
    rewritten[cursor] = (raw.size << 4).to_u8
    cursor += 1
  else
    rewritten[cursor] = 0xf0_u8
    cursor += 1
    remaining = raw.size - 15
    while remaining >= 255
      rewritten[cursor] = 255_u8
      cursor += 1
      remaining -= 255
    end
    rewritten[cursor] = remaining.to_u8
    cursor += 1
  end
  raw.copy_to(rewritten.to_unsafe + cursor, raw.size)
  hash = CrystalClick::CityHashV1.hash128(rewritten[header, compressed_size])
  w68_table_write_u64(rewritten, 0, hash[0])
  w68_table_write_u64(rewritten, 8, hash[1])
  raise "W68 null mutation changed frame size" unless compressed_offset.to_i64 + rewritten.size == frame.end_offset
  rewritten.copy_to(encoded.to_unsafe + compressed_offset.to_i, rewritten.size)
  File.write(data_path, encoded)
end

describe "W68 typed table batches" do
  it "aligns ordered nullable Map Arrays across an all-NULL mark and later tail" do
    with_w68_table_part do |part|
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      observed_keys = [] of UInt64
      observed_maps = [] of Array(Tuple(String, Array(UInt64?)))
      observed_marks = [] of Int32

      table.scan_typed(batch_rows: 1) do |batch|
        keys = batch.values_for("pk", UInt64)
        maps = batch.map_string_array_nullable_uint64s_for("payload")
        maps.size.should eq(keys.size)
        keys.each_with_index do |key, index|
          observed_keys << key
          observed_maps << maps[index]
          observed_marks << batch.mark_index
        end
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.map_string_array_nullable_uint64s_for("pk")
        end
      end

      observed_keys.should eq(W68_TABLE_KEYS)
      observed_maps.should eq(W68_TABLE_ROWS)
      observed_marks.should eq([0, 0, 1, 1, 2, 2, 3])
    end
  end

  it "rejects a shifted null-map mark row-count field before a callback" do
    with_w68_table_part do |part|
      stream = "payload%2Evalues.null"
      marks_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
      marks = File.read(marks_path).to_slice.dup
      mark = 0
      row_count = 0_u64
      8.times { |byte| row_count |= marks[mark + 16 + byte].to_u64 << (byte * 8) }
      shifted = row_count + 1_u64
      8.times { |byte| marks[mark + 16 + byte] = ((shifted >> (byte * 8)) & 0xff_u64).to_u8 }
      File.write(marks_path, marks)

      callback_count = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
        table.scan_typed(batch_rows: 1) { callback_count += 1 }
      end
      callback_count.should eq(0)
    end
  end

  it "rejects malformed later-mark null data before that mark's callback" do
    with_w68_table_part do |part|
      w68_table_corrupt_later_null_frame(part, 2)
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      delivered = [] of UInt64
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed(batch_rows: 1) do |batch|
          delivered.concat(batch.values_for("pk", UInt64).to_a)
        end
      end
      delivered.should eq([1_u64, 2_u64, 3_u64, 4_u64])
    end
  end
end
