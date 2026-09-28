require "./w70_helpers"

describe "W70 typed table batches" do
  it "keeps duplicate keys, empty Arrays, and nullable Strings aligned across marks" do
    with_w70_part do |part|
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["id", "m"])
      observed_keys = [] of UInt64
      observed_maps = [] of Array(Tuple(String, Array(String?)))
      observed_marks = [] of Int32

      table.scan_typed(batch_rows: 1) do |batch|
        keys = batch.values_for("id", UInt64)
        maps = batch.map_string_array_nullable_strings_for("m")
        maps.size.should eq(keys.size)
        keys.each_with_index do |key, index|
          observed_keys << key
          observed_maps << maps[index]
          observed_marks << batch.mark_index
        end
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.map_string_array_nullable_strings_for("id")
        end
      end

      observed_keys.should eq(W70_KEYS)
      observed_maps.should eq(W70_VALUES)
      observed_marks.should eq([0, 0, 1, 1, 2, 2, 3])
    end
  end

  it "charges physical hidden NULL bytes before callback without requiring visible-byte equality" do
    with_w70_part do |part|
      w70_rewrite_mark_frame(part, "m%2Evalues.size", 0) do |raw, offset|
        w70_write_u64(raw, offset, 1_u64)
        w70_write_u64(raw, offset + 16, 2_u64)
      end
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["id", "m"])
      observed = [] of Array(Tuple(String, Array(String?)))
      table.scan_typed(batch_rows: 2) do |batch|
        observed.concat(batch.map_string_array_nullable_strings_for("m").to_a)
      end
      observed[0][0][1].should eq([nil, "", "\0b", "café"] of String?)
      observed[0, 2].size.should eq(2)
    end
  end

  it "rejects malformed later-mark NULL bytes before exposing that mark" do
    with_w70_part do |part|
      w70_rewrite_mark_frame(part, "m%2Evalues.null", 2) do |raw, offset|
        raw[offset] = 2_u8
      end
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["id", "m"])
      delivered = [] of UInt64
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed(batch_rows: 1) do |batch|
          delivered.concat(batch.values_for("id", UInt64).to_a)
          batch.map_string_array_nullable_strings_for("m")
        end
      end
      delivered.should eq([0_u64, 1_u64, 2_u64, 3_u64])
    end
  end
end
