require "./spec_helper"

private def w134_expect_counters(
  rows : CrystalClick::WidePartArrayMapNumericRowsBase,
  row_count : UInt64,
  map_count : UInt64,
  entry_count : UInt64,
  payload_bytes : UInt64,
) : Nil
  rows.row_count.should eq(row_count)
  rows.map_count.should eq(map_count)
  rows.entry_count.should eq(entry_count)
  rows.payload_bytes.should eq(payload_bytes)
end

private def w134_u64_numeric_slice_after_owner_scope
  values = [
    [
      [{1_u64, -12_i16}, {2_u64, 300_i16}] of Tuple(UInt64, Int16),
      [] of Tuple(UInt64, Int16),
    ],
    [
      [] of Tuple(UInt64, Int16),
      [{3_u64, -7_i16}] of Tuple(UInt64, Int16),
    ],
  ] of Array(Array(Tuple(UInt64, Int16)))
  rows : CrystalClick::WidePartArrayMapNumericRowsBase = CrystalClick::WidePartArrayMapNumericRows(UInt64, Int16).new(values)

  # Three entries own 24 key bytes and six Int16 bytes.
  w134_expect_counters(rows, 2_u64, 4_u64, 3_u64, 30_u64)
  slice = rows.slice_rows(1, 1).as(CrystalClick::WidePartArrayMapNumericSlice(UInt64, Int16))
  {slice, values.object_id}
end

describe "W134 public Array(Map) row-owner interfaces" do
  it "retains a numeric row owner and values after its lexical scope and GC" do
    slice, owner_id = w134_u64_numeric_slice_after_owner_scope
    GC.collect

    slice.owner.object_id.should eq(owner_id)
    slice.owner.size.should eq(2)
    slice.owner[1][1][0].should eq({3_u64, -7_i16})
    slice.values.size.should eq(1)
    slice.values[0][1][0].should eq({3_u64, -7_i16})
  end

  it "counts numeric entries with String keys and a signed non-default-width value" do
    values = [
      [[{"a", -1_i16}, {"bc", 20_i16}] of Tuple(String, Int16)],
      [] of Array(Tuple(String, Int16)),
    ] of Array(Array(Tuple(String, Int16)))
    rows = CrystalClick::WidePartArrayMapNumericRows(String, Int16).new(values)

    # String keys use three bytes; two Int16 values use four more.
    w134_expect_counters(rows, 2_u64, 1_u64, 2_u64, 7_u64)
    slice = rows.slice_rows(0, 1).as(CrystalClick::WidePartArrayMapNumericSlice(String, Int16))
    slice.owner.object_id.should eq(values.object_id)
    slice.values[0][0][1].should eq({"bc", 20_i16})
  end

  it "counts nullable numeric slots including nil values and their null-map bytes" do
    values = [
      [[{"n", nil}, {"", -3_i16}] of Tuple(String, Int16?)],
      [
        [] of Tuple(String, Int16?),
        [{"z", 7_i16}] of Tuple(String, Int16?),
      ],
    ] of Array(Array(Tuple(String, Int16?)))
    rows : CrystalClick::WidePartArrayMapNumericRowsBase = CrystalClick::WidePartArrayMapNullableNumericRows(String, Int16).new(values)

    # Two key bytes plus three entries at (Int16 + null-map) width.
    w134_expect_counters(rows, 2_u64, 3_u64, 3_u64, 11_u64)
    slice = rows.slice_rows(0, 2).as(CrystalClick::WidePartArrayMapNumericSlice(String, Int16?))
    slice.owner.object_id.should eq(values.object_id)
    slice.values[0][0][0][1].should be_nil
    slice.values[1][1][0].should eq({"z", 7_i16})
  end

  it "counts String and Nullable String leaves with binary, Unicode, empty, and nil values" do
    binary_unicode = "\0雪"
    string_values = [
      [[{"x", binary_unicode}, {"", ""}] of Tuple(String, String)],
    ] of Array(Array(Tuple(String, String)))
    string_rows = CrystalClick::WidePartArrayMapStringLeafRows(String, String).new(string_values)

    # The key contributes one byte; NUL plus the three-byte snow character contribute four.
    w134_expect_counters(string_rows, 1_u64, 1_u64, 2_u64, 5_u64)
    string_slice = string_rows.slice_rows(0, 1).as(CrystalClick::WidePartArrayMapNumericSlice(String, String))
    string_slice.owner.object_id.should eq(string_values.object_id)
    string_slice.values[0][0][0][1].should eq(binary_unicode)
    string_slice.values[0][0][1][1].should eq("")

    nullable_values = [
      [[{1_u64, "é"}, {2_u64, nil}, {3_u64, ""}] of Tuple(UInt64, String?)],
    ] of Array(Array(Tuple(UInt64, String?)))
    nullable_rows = CrystalClick::WidePartArrayMapStringLeafRows(UInt64, String?).new(nullable_values)

    # Three UInt64 keys, two UTF-8 value bytes, and one null-map byte per entry.
    w134_expect_counters(nullable_rows, 1_u64, 1_u64, 3_u64, 29_u64)
    nullable_slice = nullable_rows.slice_rows(0, 1).as(CrystalClick::WidePartArrayMapNumericSlice(UInt64, String?))
    nullable_slice.owner.object_id.should eq(nullable_values.object_id)
    nullable_slice.values[0][0][0][1].should eq("é")
    nullable_slice.values[0][0][1][1].should be_nil
    nullable_slice.values[0][0][2][1].should eq("")
  end

  it "counts Bool and nullable Bool as distinct fixed-width payloads" do
    bool_values = [
      [[{"a", true}, {"bc", false}] of Tuple(String, Bool)],
    ] of Array(Array(Tuple(String, Bool)))
    bool_rows = CrystalClick::WidePartArrayMapBoolLeafRows(String, Bool).new(bool_values)

    # Three String-key bytes plus one Bool byte per entry.
    w134_expect_counters(bool_rows, 1_u64, 1_u64, 2_u64, 5_u64)
    bool_slice = bool_rows.slice_rows(0, 1).as(CrystalClick::WidePartArrayMapNumericSlice(String, Bool))
    bool_slice.owner.object_id.should eq(bool_values.object_id)
    bool_slice.values[0][0][0].should eq({"a", true})
    bool_slice.values[0][0][1].should eq({"bc", false})

    nullable_values = [
      [[{1_u64, false}, {2_u64, nil}] of Tuple(UInt64, Bool?)],
    ] of Array(Array(Tuple(UInt64, Bool?)))
    nullable_rows = CrystalClick::WidePartArrayMapBoolLeafRows(UInt64, Bool?).new(nullable_values)

    # Two UInt64 keys plus two (Bool + null-map) payload bytes.
    w134_expect_counters(nullable_rows, 1_u64, 1_u64, 2_u64, 20_u64)
    nullable_slice = nullable_rows.slice_rows(0, 1).as(CrystalClick::WidePartArrayMapNumericSlice(UInt64, Bool?))
    nullable_slice.owner.object_id.should eq(nullable_values.object_id)
    nullable_slice.values[0][0][0][1].should eq(false)
    nullable_slice.values[0][0][1][1].should be_nil
  end

  it "counts nested numeric and String elements independently of map entries, including empty arrays" do
    numeric_values = [
      [
        [{1_u64, [2_i16, -3_i16]}, {2_u64, [] of Int16}] of Tuple(UInt64, Array(Int16)),
        [] of Tuple(UInt64, Array(Int16)),
      ],
      [[{3_u64, [4_i16]}] of Tuple(UInt64, Array(Int16))],
    ] of Array(Array(Tuple(UInt64, Array(Int16))))
    numeric_rows : CrystalClick::WidePartArrayMapArrayLeafRowsBase = CrystalClick::WidePartArrayMapArrayLeafRows(UInt64, Int16).new(numeric_values)

    # Three map entries carry three nested Int16 elements; the empty nested Array contributes none.
    w134_expect_counters(numeric_rows, 2_u64, 3_u64, 3_u64, 30_u64)
    numeric_rows.value_count.should eq(3_u64)
    numeric_slice = numeric_rows.slice_rows(0, 2).as(CrystalClick::WidePartArrayMapNumericSlice(UInt64, Array(Int16)))
    numeric_slice.owner.object_id.should eq(numeric_values.object_id)
    numeric_slice.values[0][0][1][1].should be_empty
    numeric_slice.values[1][0][0][1].should eq([4_i16])

    string_values = [
      [
        [{"a", ["é", ""]}, {"", [] of String}] of Tuple(String, Array(String)),
        [{"bc", ["\0"]}] of Tuple(String, Array(String)),
      ],
    ] of Array(Array(Tuple(String, Array(String))))
    string_rows = CrystalClick::WidePartArrayMapArrayLeafRows(String, String).new(string_values)

    # UTF-8/NUL values and String keys each contribute raw bytes; empty leaves contribute zero.
    w134_expect_counters(string_rows, 1_u64, 2_u64, 3_u64, 6_u64)
    string_rows.value_count.should eq(3_u64)
    string_slice = string_rows.slice_rows(0, 1).as(CrystalClick::WidePartArrayMapNumericSlice(String, Array(String)))
    string_slice.owner.object_id.should eq(string_values.object_id)
    string_slice.values[0][0][1][1].should be_empty
    string_slice.values[0][0][0][1][1].should eq("")
    string_slice.values[0][1][0][1].should eq(["\0"])
  end
end
