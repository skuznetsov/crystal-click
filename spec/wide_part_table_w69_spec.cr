require "./w69_helpers"

describe "W69 typed table batches" do
  it "keeps ordered duplicate UInt64 keys and nullable nested Arrays aligned by mark" do
    with_w69_part do |part|
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      observed_keys = [] of UInt64
      observed_maps = [] of Array(Tuple(UInt64, Array(UInt64?)))
      observed_marks = [] of Int32

      table.scan_typed(batch_rows: 1) do |batch|
        keys = batch.values_for("pk", UInt64)
        maps = batch.map_uint64_array_nullable_uint64s_for("payload")
        maps.size.should eq(keys.size)
        keys.each_with_index do |key, index|
          observed_keys << key
          observed_maps << maps[index]
          observed_marks << batch.mark_index
        end
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.map_uint64_array_nullable_uint64s_for("pk")
        end
      end

      observed_keys.should eq(W69_KEYS)
      observed_maps.should eq(W69_VALUES)
      observed_marks.should eq([0, 0, 1, 1, 2, 2, 3])
    end
  end

  it "rejects malformed later-mark NULL bytes before exposing that mark" do
    with_w69_part do |part|
      w69_rewrite_mark_frame(part, "payload%2Evalues.null", 2) do |raw, decompressed_offset|
        raw[decompressed_offset] = 2_u8
      end
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      delivered = [] of UInt64
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed(batch_rows: 1) do |batch|
          delivered.concat(batch.values_for("pk", UInt64).to_a)
          batch.map_uint64_array_nullable_uint64s_for("payload")
        end
      end
      delivered.should eq([1_u64, 2_u64, 3_u64, 4_u64])
    end
  end
end
