require "./spec_helper"

private def retained_numeric_map_slice
  values = [
    [{1_u64, -3_i16}, {1_u64, 7_i16}] of Tuple(UInt64, Int16),
    [] of Tuple(UInt64, Int16),
  ] of Array(Tuple(UInt64, Int16))
  rows : CrystalClick::WidePartNumericMapRowsBase = CrystalClick::WidePartNumericMapRows(UInt64, Int16).new(values)
  rows.row_count.should eq(2_u64)
  rows.entry_count.should eq(2_u64)
  rows.payload_bytes.should eq(20_u64)
  {rows.slice_rows(0, 1).as(CrystalClick::WidePartNumericMapSlice(UInt64, Int16)), values.object_id}
end

private def retained_nullable_numeric_map_slice
  values = [
    [{"a", nil}, {"a", -3_i16}] of Tuple(String, Int16?),
    [] of Tuple(String, Int16?),
  ] of Array(Tuple(String, Int16?))
  rows : CrystalClick::WidePartNumericMapRowsBase = CrystalClick::WidePartNullableNumericMapRows(String, Int16).new(values)
  rows.row_count.should eq(2_u64)
  rows.entry_count.should eq(2_u64)
  rows.payload_bytes.should eq(8_u64)
  {rows.slice_rows(0, 1).as(CrystalClick::WidePartNumericMapSlice(String, Int16?)), values.object_id}
end

private def retained_numeric_map_array_slice
  values = [
    [{1_u64, [-3_i16, 7_i16]}, {1_u64, [] of Int16}] of Tuple(UInt64, Array(Int16)),
    [] of Tuple(UInt64, Array(Int16)),
  ] of Array(Tuple(UInt64, Array(Int16)))
  rows : CrystalClick::WidePartNumericMapRowsBase = CrystalClick::WidePartNumericMapArrayRows(UInt64, Int16).new(values)
  rows.row_count.should eq(2_u64)
  rows.entry_count.should eq(2_u64)
  rows.payload_bytes.should eq(20_u64)
  {rows.slice_rows(0, 1).as(CrystalClick::WidePartNumericMapSlice(UInt64, Array(Int16))), values.object_id}
end

private def retained_nullable_numeric_map_array_slice
  values = [
    [{"a", [nil, -3_i16] of Int16?}, {"a", [] of Int16?}] of Tuple(String, Array(Int16?)),
    [] of Tuple(String, Array(Int16?)),
  ] of Array(Tuple(String, Array(Int16?)))
  rows : CrystalClick::WidePartNumericMapRowsBase = CrystalClick::WidePartNullableNumericMapArrayRows(String, Int16).new(values)
  rows.row_count.should eq(2_u64)
  rows.entry_count.should eq(2_u64)
  rows.payload_bytes.should eq(8_u64)
  {rows.slice_rows(0, 1).as(CrystalClick::WidePartNumericMapSlice(String, Array(Int16?))), values.object_id}
end

describe "Numeric Map row-owner boundaries" do
  it "retains flat numeric rows and duplicate keys after the row-owner scope and GC" do
    slice, owner_id = retained_numeric_map_slice
    GC.collect
    slice.owner.object_id.should eq(owner_id)
    slice.values.to_a.should eq([[{1_u64, -3_i16}, {1_u64, 7_i16}]])
  end

  it "retains nullable rows and charges physical value slots plus null bytes" do
    slice, owner_id = retained_nullable_numeric_map_slice
    GC.collect
    slice.owner.object_id.should eq(owner_id)
    slice.values.to_a.should eq([[{"a", nil}, {"a", -3_i16}]])
  end

  it "retains nested numeric arrays including empty duplicate-key entries" do
    slice, owner_id = retained_numeric_map_array_slice
    GC.collect
    slice.owner.object_id.should eq(owner_id)
    slice.values.to_a.should eq([[{1_u64, [-3_i16, 7_i16]}, {1_u64, [] of Int16}]])
  end

  it "retains nested nullable arrays without losing nil or empty values" do
    slice, owner_id = retained_nullable_numeric_map_array_slice
    GC.collect
    slice.owner.object_id.should eq(owner_id)
    slice.values.to_a.should eq([[{"a", [nil, -3_i16] of Int16?}, {"a", [] of Int16?}]])
  end

  it "counts empty rows as rows but not entries or payload" do
    plain = CrystalClick::WidePartNumericMapRows(UInt64, Int16).new([[] of Tuple(UInt64, Int16)])
    nullable = CrystalClick::WidePartNullableNumericMapRows(String, Int16).new([[] of Tuple(String, Int16?)])
    arrays = CrystalClick::WidePartNumericMapArrayRows(UInt64, Int16).new([[] of Tuple(UInt64, Array(Int16))])
    nullable_arrays = CrystalClick::WidePartNullableNumericMapArrayRows(String, Int16).new([[] of Tuple(String, Array(Int16?))])
    [plain, nullable, arrays, nullable_arrays].each do |rows|
      rows.row_count.should eq(1_u64)
      rows.entry_count.should eq(0_u64)
      rows.payload_bytes.should eq(0_u64)
    end
  end

  it "preserves checked slice bounds and a valid empty end slice" do
    values = [[{1_u64, -3_i16}] of Tuple(UInt64, Int16)]
    rows = CrystalClick::WidePartNumericMapRows(UInt64, Int16).new(values)
    expect_raises(IndexError) { rows.slice_rows(1, 1) }
    expect_raises(IndexError) { rows.slice_rows(0, 2) }
    empty = rows.slice_rows(1, 0).as(CrystalClick::WidePartNumericMapSlice(UInt64, Int16))
    empty.values.should be_empty
    empty.owner.object_id.should eq(values.object_id)
  end
end
