require "./spec_helper"

W63_TABLE_KEYS       = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
W63_TABLE_MAP_VALUES = [
  [] of Tuple(String, Array(UInt64)),
  [{"dup", [0_u64, UInt64::MAX]}, {"dup", [] of UInt64}] of Tuple(String, Array(UInt64)),
  [{"雪", [42_u64]}, {"", [7_u64, 7_u64]}] of Tuple(String, Array(UInt64)),
  [] of Tuple(String, Array(UInt64)),
  [] of Tuple(String, Array(UInt64)),
  [] of Tuple(String, Array(UInt64)),
  [{"tail", [8_u64, 9_u64]}, {"dup", [42_u64]}] of Tuple(String, Array(UInt64)),
] of Array(Tuple(String, Array(UInt64)))

private def with_w63_table_part(&)
  parent = File.tempname("crystal-click-w63-table")
  Dir.mkdir(parent)
  path = File.join(parent, "all_1_1_0")
  CrystalClick::WidePartWriter.write_uint64_map_string_array_uint64_pair(
    path,
    "pk",
    W63_TABLE_KEYS.to_unsafe.to_slice(W63_TABLE_KEYS.size),
    "map_arrays",
    W63_TABLE_MAP_VALUES.to_unsafe.to_slice(W63_TABLE_MAP_VALUES.size),
    rows_per_mark: 2
  )
  begin
    yield path
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w63_table_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w63_table_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

describe "W63 typed table batches" do
  it "returns aligned ordered Map entries with nested UInt64 Arrays" do
    with_w63_table_part do |path|
      table = CrystalClick::WidePartTable.open_selected_typed([path], ["pk", "map_arrays"])
      observed_keys = [] of UInt64
      observed_maps = [] of Array(Tuple(String, Array(UInt64)))
      observed_offsets = [] of {Int32, UInt64, UInt64}

      table.scan_typed(batch_rows: 1) do |batch|
        keys = batch.values_for("pk", UInt64)
        maps = batch.map_string_array_uint64s_for("map_arrays")
        keys.each_with_index do |key, index|
          observed_keys << key
          observed_maps << maps[index]
          observed_offsets << {batch.mark_index, batch.mark_row_offset + index.to_u64, batch.part_row_offset + index.to_u64}
        end
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.map_string_array_uint64s_for("pk") }
      end

      observed_keys.should eq(W63_TABLE_KEYS)
      observed_maps.should eq(W63_TABLE_MAP_VALUES)
      observed_offsets.should eq([
        {0, 0_u64, 0_u64}, {0, 1_u64, 1_u64},
        {1, 0_u64, 2_u64}, {1, 1_u64, 3_u64},
        {2, 0_u64, 4_u64}, {2, 1_u64, 5_u64},
        {3, 0_u64, 6_u64},
      ])
    end
  end

  it "rejects corrupt selected key and nested-value boundaries before callbacks" do
    ["map_arrays%2Ekeys", "map_arrays%2Evalues.size1"].each do |stream|
      with_w63_table_part do |path|
        marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
        marks = File.read(marks_path).to_slice.dup
        mark_size = CrystalClick::WidePart::MARK_SIZE
        raise "W63 marks are missing the first record for #{stream}" if marks.size < mark_size

        row_count = w63_table_read_u64(marks, 16)
        w63_table_write_u64(marks, 16, row_count + 1_u64)
        File.write(marks_path, marks)

        callback_count = 0
        expect_raises(CrystalClick::CorruptPartError) do
          table = CrystalClick::WidePartTable.open_selected_typed([path], ["pk", "map_arrays"])
          table.scan_typed(batch_rows: 1) { callback_count += 1 }
        end
        callback_count.should eq(0)
      end
    end
  end
end
