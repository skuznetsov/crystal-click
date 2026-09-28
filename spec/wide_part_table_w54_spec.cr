require "./spec_helper"

W54_TABLE_FIXTURE           = File.expand_path("../test/fixtures/public/wide_map_nullable_string_w54/part", __DIR__)
W54_TABLE_BINARY_KEY        = String.new(Bytes[0x41_u8, 0_u8, 0x42_u8, 0xff_u8])
W54_TABLE_MAP_UINT64_VALUES = [
  [] of Tuple(UInt64, String?),
  [{7_u64, nil}, {7_u64, ""}] of Tuple(UInt64, String?),
  [{UInt64::MAX, ""}, {0_u64, nil}] of Tuple(UInt64, String?),
  [{1_u64, "x\0y"}] of Tuple(UInt64, String?),
  [] of Tuple(UInt64, String?),
  [{5_u64, nil}, {5_u64, "雪"}] of Tuple(UInt64, String?),
  [{9_u64, "end"}] of Tuple(UInt64, String?),
] of Array(Tuple(UInt64, String?))
W54_TABLE_MAP_STRING_VALUES = [
  [] of Tuple(String, String?),
  [{"dup", nil}, {"dup", ""}] of Tuple(String, String?),
  [{W54_TABLE_BINARY_KEY, ""}, {"雪", nil}] of Tuple(String, String?),
  [{"empty", ""}] of Tuple(String, String?),
  [] of Tuple(String, String?),
  [{"tail", nil}, {"", "🐈"}] of Tuple(String, String?),
  [{"end", "last"}] of Tuple(String, String?),
] of Array(Tuple(String, String?))

describe "W54 Nullable(String)-value Map typed table" do
  it "scans both exact Map types across batches without collapsing duplicate keys" do
    root = File.tempname("crystal-click-w54-map-table")
    Dir.mkdir(root)
    part_path = File.join(root, "all_1_1_0")
    FileUtils.cp_r(W54_TABLE_FIXTURE, part_path)
    begin
      table = CrystalClick::WidePartTable.open_selected_typed(
        [part_path], ["pk", "map_u64", "map_string"]
      )
      observed_keys = [] of UInt64
      observed_u64 = [] of Array(Tuple(UInt64, String?))
      observed_string = [] of Array(Tuple(String, String?))
      table.scan_typed(batch_rows: 3) do |batch|
        keys = batch.values_for("pk", UInt64)
        u64_maps = batch.map_uint64_nullable_strings_for("map_u64")
        string_maps = batch.map_string_nullable_strings_for("map_string")
        keys.each_with_index do |key, index|
          observed_keys << key
          observed_u64 << u64_maps[index]
          observed_string << string_maps[index]
        end
      end

      observed_keys.should eq([1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64])
      observed_u64.should eq(W54_TABLE_MAP_UINT64_VALUES)
      observed_string.should eq(W54_TABLE_MAP_STRING_VALUES)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
