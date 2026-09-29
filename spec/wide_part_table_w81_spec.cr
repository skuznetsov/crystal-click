require "./spec_helper"
require "./w69_helpers"
require "file_utils"

private def with_w81_table_uint64_int8_part(& : String ->)
  parent = File.tempname("crystal-click-w81-table")
  Dir.mkdir(parent)
  part = File.join(parent, "all_1_1_0")
  values = [
    [] of Array(Tuple(UInt64, Int8)),
    [[{7_u64, 10_i8}, {7_u64, 11_i8}] of Tuple(UInt64, Int8)],
    [] of Array(Tuple(UInt64, Int8)),
    [[{UInt64::MAX, -1_i8}] of Tuple(UInt64, Int8)],
  ] of Array(Array(Tuple(UInt64, Int8)))
  keys = [0_u64, 1_u64, 2_u64, 3_u64]
  begin
    CrystalClick::WidePartWriter.write_uint64_array_map_uint64_numeric_pair(
      part,
      "pk",
      keys.to_unsafe.to_slice(keys.size),
      "payload",
      values.to_unsafe.to_slice(values.size),
      rows_per_mark: 2
    )
    yield part, values
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe "W81 typed table Array(Map) batches" do
  it "materializes numeric Array(Map) values and selects nonzero source marks" do
    with_w81_table_uint64_int8_part do |part, expected|
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      actual = [] of Array(Array(Tuple(UInt64, Int8)))
      table.scan_typed(batch_rows: 1) do |batch|
        actual.concat(batch.array_map_uint64_numeric_values_for("payload", Int8).to_a)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.array_map_uint64_numeric_values_for("payload", UInt8)
        end
      end
      actual.should eq(expected)

      selected = [] of Array(Array(Tuple(UInt64, Int8)))
      table.scan_typed_window(2_u64, 2) do |batch|
        selected.concat(batch.array_map_uint64_numeric_values_for("payload", Int8).to_a)
      end
      selected.should eq(expected[2, 2])
    end
  end

  it "rejects a malformed selected later mark before yielding any row" do
    with_w81_table_uint64_int8_part do |part, _expected|
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

  it "rejects a malformed selected String-key nullable-map offset before yielding rows" do
    parent = File.tempname("crystal-click-w81-null-offset-table")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_1_0")
    values = [
      [[{"before", 1_i16}] of Tuple(String, Int16?)],
      [[{"after", nil}] of Tuple(String, Int16?)],
    ] of Array(Array(Tuple(String, Int16?)))
    keys = [0_u64, 1_u64]
    begin
      CrystalClick::WidePartWriter.write_uint64_array_map_string_nullable_numeric_pair(
        part,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 1
      )
      w69_shift_mark(part, "payload%2Evalues.null", 1)
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed_window(1_u64, 1) do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "preserves binary String keys and nullable values in typed table batches" do
    parent = File.tempname("crystal-click-w81-string-nullable-table")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_1_0")
    binary_key = String.new(Bytes[0_u8, 0xff_u8, 0x80_u8])
    expected = [
      [
        [{binary_key, nil}, {"zero", 0_i16}] of Tuple(String, Int16?),
        [] of Tuple(String, Int16?),
      ] of Array(Tuple(String, Int16?)),
      [] of Array(Tuple(String, Int16?)),
    ] of Array(Array(Tuple(String, Int16?)))
    keys = [0_u64, 1_u64]
    begin
      CrystalClick::WidePartWriter.write_uint64_array_map_string_nullable_numeric_pair(
        part,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        expected.to_unsafe.to_slice(expected.size),
        rows_per_mark: 1
      )
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      actual = [] of Array(Array(Tuple(String, Int16?)))
      table.scan_typed(batch_rows: 1) do |batch|
        actual.concat(batch.array_map_string_nullable_numeric_values_for("payload", Int16).to_a)
      end
      actual.should eq(expected)
      actual[0][0][0][0].to_slice.should eq(binary_key.to_slice)
      actual[0][0][0][1].should be_nil
      actual[0][0][1].should eq({"zero", 0_i16})
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
