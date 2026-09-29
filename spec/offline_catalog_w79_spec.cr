require "./wide_part_w79_helpers"

describe "W79 offline catalog typed materialization" do
  it "returns owned nested nullable arrays and String keys" do
    with_w79_parts do |parent, _u64_path, string_path|
      table = w79_catalog_table_for_part(
        File.join(parent, "catalog"),
        string_path,
        "Map(String, Array(Nullable(Float64)))"
      )
      actual = table["payload"].values.map do |row|
        row.as?(Array(Tuple(String, Array(Float64?)))) || raise("catalog returned the wrong W79 value type")
      end
      actual.size.should eq(W79_STRING_ROWS.size)
      actual[1][0][0].should eq(W79_STRING_KEY)
      actual[1][0][1][0].should be_nil
      actual[1][0][1][1].not_nil!.unsafe_as(UInt64).should eq(0x8000_0000_0000_0000_u64)
      actual[2][0][1][0].not_nil!.unsafe_as(UInt64).should eq(W79_NAN_BITS)
      actual[2][0][1][1].should be_nil

      actual[1][0][1].clear
      actual[2][0] = {"changed", actual[2][0][1]}
      fresh = table["payload"].values.map do |row|
        row.as?(Array(Tuple(String, Array(Float64?)))) || raise("catalog returned the wrong W79 value type")
      end
      fresh[1][0][0].should eq(W79_STRING_KEY)
      fresh[1][0][1].should eq([nil, 0x8000_0000_0000_0000_u64.unsafe_as(Float64)] of Float64?)
      fresh[2][0][0].should eq("dup")
      fresh[2][0][1][0].not_nil!.unsafe_as(UInt64).should eq(W79_NAN_BITS)
      fresh[2][0][1][1].should be_nil
    end
  end
end
