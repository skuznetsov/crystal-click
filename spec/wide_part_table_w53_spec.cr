require "./spec_helper"

W53_TABLE_FIXTURE           = File.expand_path("../test/fixtures/public/wide_map_nullable_w53/part", __DIR__)
W53_TABLE_BINARY_KEY        = String.new(Bytes[0x41_u8, 0_u8, 0x42_u8, 0xff_u8])
W53_TABLE_MAP_UINT64_VALUES = [
  [] of Tuple(UInt64, UInt64?),
  [{7_u64, nil}, {7_u64, 0_u64}] of Tuple(UInt64, UInt64?),
  [{UInt64::MAX, 42_u64}, {0_u64, nil}] of Tuple(UInt64, UInt64?),
  [{1_u64, 0_u64}] of Tuple(UInt64, UInt64?),
  [] of Tuple(UInt64, UInt64?),
  [{5_u64, nil}, {5_u64, UInt64::MAX}] of Tuple(UInt64, UInt64?),
  [{9_u64, 0_u64}] of Tuple(UInt64, UInt64?),
] of Array(Tuple(UInt64, UInt64?))
W53_TABLE_MAP_STRING_VALUES = [
  [] of Tuple(String, UInt64?),
  [{"dup", nil}, {"dup", 0_u64}] of Tuple(String, UInt64?),
  [{W53_TABLE_BINARY_KEY, UInt64::MAX}, {"雪", nil}] of Tuple(String, UInt64?),
  [{"empty", 0_u64}, {"empty", nil}] of Tuple(String, UInt64?),
  [] of Tuple(String, UInt64?),
  [{"tail", nil}, {"", 0_u64}] of Tuple(String, UInt64?),
  [{"end", 0_u64}] of Tuple(String, UInt64?),
] of Array(Tuple(String, UInt64?))

describe "W53 Nullable-value Map typed table" do
  it "scans nullable values and ordered duplicates across multiple table batches" do
    root = File.tempname("crystal-click-w53-map-table")
    Dir.mkdir(root)
    part_path = File.join(root, "all_1_1_0")
    FileUtils.cp_r(W53_TABLE_FIXTURE, part_path)
    begin
      table = CrystalClick::WidePartTable.open_selected_typed(
        [part_path], ["pk", "map_u64", "map_string"]
      )
      observed_keys = [] of UInt64
      observed_u64 = [] of Array(Tuple(UInt64, UInt64?))
      observed_string = [] of Array(Tuple(String, UInt64?))
      table.scan_typed(batch_rows: 3) do |batch|
        keys = batch.values_for("pk", UInt64)
        u64_maps = batch.map_uint64_nullable_uint64s_for("map_u64")
        string_maps = batch.map_string_nullable_uint64s_for("map_string")
        keys.each_with_index do |key, index|
          observed_keys << key
          observed_u64 << u64_maps[index]
          observed_string << string_maps[index]
        end
      end

      observed_keys.should eq([1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64])
      observed_u64.should eq(W53_TABLE_MAP_UINT64_VALUES)
      observed_string.should eq(W53_TABLE_MAP_STRING_VALUES)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
