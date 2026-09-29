require "./wide_part_w79_helpers"

describe "W79 typed table Map Array batches" do
  it "materializes nullable leaves for both Map key axes with matching charge" do
    with_w79_parts do |_parent, u64_path, string_path|
      u64_table = CrystalClick::WidePartTable.open_selected_typed([u64_path], ["pk", "payload"])
      string_table = CrystalClick::WidePartTable.open_selected_typed([string_path], ["pk", "payload"])
      actual_u64 = [] of Array(Tuple(UInt64, Array(Int8?)))
      actual_string = [] of Array(Tuple(String, Array(Float64?)))
      u64_table.scan_typed(batch_rows: 1) do |batch|
        actual_u64.concat(batch.map_uint64_array_nullable_numeric_values_for("payload", Int8).to_a)
      end
      string_table.scan_typed(batch_rows: 1) do |batch|
        actual_string.concat(batch.map_string_array_nullable_numeric_values_for("payload", Float64).to_a)
      end
      actual_u64.should eq(W79_U64_ROWS)
      actual_string.size.should eq(W79_STRING_ROWS.size)
      actual_string[1][0][0].should eq(W79_STRING_KEY)
      actual_string[1][0][1][0].should be_nil
      actual_string[1][0][1][1].not_nil!.unsafe_as(UInt64).should eq(0x8000_0000_0000_0000_u64)
      actual_string[2][0][1][0].not_nil!.unsafe_as(UInt64).should eq(W79_NAN_BITS)
      actual_string[2][0][1][1].should be_nil

      u64_table.scan_typed(batch_rows: 1) do |batch|
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.map_uint64_array_nullable_numeric_values_for("payload", UInt8)
        end
        break
      end
    end
  end

  it "preflights a shifted later values.null mark before yielding that selected mark" do
    with_w79_parts do |_parent, u64_path, _string_path|
      w69_shift_mark(u64_path, "payload%2Evalues.null", 1)
      table = CrystalClick::WidePartTable.open_selected_typed([u64_path], ["pk", "payload"])
      callback_count = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed_window(2_u64, 2) do |_batch|
          callback_count += 1
        end
      end
      callback_count.should eq(0)
    end
  end
end
