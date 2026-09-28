require "./wide_part_reader_w73_helpers"

describe "W73 typed table batches" do
  it "exposes ordered Map tuples for all three exact non-null cells" do
    with_w73_reader_u64_u64_part do |part|
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      keys = [] of UInt64
      observed = [] of Array(Tuple(UInt64, Array(UInt64)))
      table.scan_typed(batch_rows: 1) do |batch|
        batch_keys = batch.values_for("pk", UInt64)
        maps = batch.map_uint64_array_uint64s_for("payload")
        maps.size.should eq(batch_keys.size)
        keys.concat(batch_keys.to_a)
        observed.concat(maps.to_a)
      end
      keys.should eq(W73_READER_KEYS)
      observed.should eq(W73_READER_U64_U64_VALUES)
    end

    with_w73_reader_string_string_part do |part|
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      observed = [] of Array(Tuple(String, Array(String)))
      table.scan_typed(batch_rows: 2) do |batch|
        observed.concat(batch.map_string_array_strings_for("payload").to_a)
      end
      observed.should eq(W73_READER_STRING_STRING_VALUES)
    end

    with_w73_reader_u64_string_part do |part|
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      observed = [] of Array(Tuple(UInt64, Array(String)))
      table.scan_typed(batch_rows: 3) do |batch|
        observed.concat(batch.map_uint64_array_strings_for("payload").to_a)
      end
      observed.should eq(W73_READER_U64_STRING_VALUES)
    end
  end

  it "rejects a malformed later W73 leaf-size mark before exposing its row" do
    with_w73_reader_u64_string_part do |part|
      w71_rewrite_mark_frame(part, "payload%2Evalues.size1", 2) do |raw, offset|
        w71_write_u64(raw, offset, 3_u64)
      end
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      delivered = [] of UInt64
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed(batch_rows: 1) do |batch|
          delivered.concat(batch.values_for("pk", UInt64).to_a)
          batch.map_uint64_array_strings_for("payload")
        end
      end
      delivered.should eq(W73_READER_KEYS[0, 4])
    end
  end
end
