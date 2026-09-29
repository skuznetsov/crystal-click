require "./wide_part_w79_helpers"

describe "W79 nullable numeric Map Array reader" do
  it "decodes both exact Map key shapes and charges every leaf plus null code" do
    with_w79_parts do |_parent, u64_path, string_path|
      u64_reader = CrystalClick::WidePart.open_typed(u64_path, "payload")
      u64_reader.column_type.should eq("Map(UInt64, Array(Nullable(Int8)))")
      u64_reader.read_map_uint64_array_nullable_numeric_mark_range("payload", 0, u64_reader.mark_count, Int8)
        .should eq(W79_U64_ROWS)
      u64_reader.map_uint64_array_nullable_numeric_mark_range_raw_bytes("payload", 0, u64_reader.mark_count)
        .should eq(40_u64)
      u64_reader.map_uint64_array_nullable_numeric_mark_range_materialization_preflight("payload", 0, u64_reader.mark_count, Int8)
        .should eq({40_u64, 232_u64})

      string_reader = CrystalClick::WidePart.open_typed(string_path, "payload")
      string_reader.column_type.should eq("Map(String, Array(Nullable(Float64)))")
      actual = string_reader.read_map_string_array_nullable_numeric_mark_range("payload", 0, string_reader.mark_count, Float64)
      actual.size.should eq(W79_STRING_ROWS.size)
      actual[1][0][0].should eq(W79_STRING_KEY)
      actual[1][0][1][0].should be_nil
      actual[1][0][1][1].not_nil!.unsafe_as(UInt64).should eq(0x8000_0000_0000_0000_u64)
      actual[1][1].should eq({"", [] of Float64?})
      actual[2][0][1][0].not_nil!.unsafe_as(UInt64).should eq(W79_NAN_BITS)
      actual[2][0][1][1].should be_nil
      actual[3].should eq(W79_STRING_ROWS[3])
      string_reader.map_string_array_nullable_numeric_mark_range_raw_bytes("payload", 0, string_reader.mark_count)
        .should eq(45_u64)
      string_reader.map_string_array_nullable_numeric_mark_range_materialization_preflight("payload", 0, string_reader.mark_count, Float64)
        .should eq({45_u64, 237_u64})

      expect_raises(CrystalClick::UnsupportedFormatError) do
        string_reader.read_map_string_array_nullable_numeric_mark_range("payload", 0, string_reader.mark_count, Int8)
      end
    end
  end

  it "rejects a checksum-valid null code outside the 0/1 domain" do
    with_w79_parts do |_parent, u64_path, _string_path|
      w69_rewrite_mark_frame(u64_path, "payload%2Evalues.null", 0) do |raw, offset|
        raw[offset] = 2_u8
      end
      reader = CrystalClick::WidePart.open_typed(u64_path, "payload")
      expect_raises(CrystalClick::CorruptPartError) do
        reader.map_uint64_array_nullable_numeric_mark_range_materialization_preflight("payload", 0, 1, Int8)
      end
    end
  end
end
