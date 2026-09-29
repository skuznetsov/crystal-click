require "./wide_part_w80_helpers"

describe "W80 offline catalog Array(Map) materialization" do
  it "returns owned nested Maps and binary String keys" do
    with_w80_part do |parent, part|
      table = w80_catalog_table_for_part(File.join(parent, "catalog"), part)
      actual = table["payload"].values.map do |row|
        row.as?(Array(Array(Tuple(String, UInt64)))) || raise("catalog returned the wrong W80 value type")
      end
      actual.should eq(W80_ROWS)

      actual[0][0].clear
      actual[2][0][0] = {"changed", 0_u64}
      fresh = table["payload"].values.map do |row|
        row.as?(Array(Array(Tuple(String, UInt64)))) || raise("catalog returned the wrong W80 value type")
      end
      fresh.should eq(W80_ROWS)
    end
  end
end
