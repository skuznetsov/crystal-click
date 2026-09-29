require "./spec_helper"

private alias W84MapUInt64ArrayUInt64 = Array(Tuple(UInt64, Array(UInt64)))
private alias W84MapUInt64ArrayString = Array(Tuple(UInt64, Array(String)))
private alias W84MapStringArrayUInt64 = Array(Tuple(String, Array(UInt64)))
private alias W84MapStringArrayString = Array(Tuple(String, Array(String)))

private def w84_temp_part(name : String) : Tuple(String, String)
  parent = File.tempname(name)
  Dir.mkdir(parent)
  {parent, File.join(parent, "part")}
end

private def w84_assert_serialization_metadata(part : String)
  File.read(File.join(part, "serialization.json")).strip.should eq(
    %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
  )
end

describe "W84 Array(Map(K, Array(V))) writer" do
  it "writes UInt64 keys and UInt64 arrays, preserving duplicate keys and empty levels" do
    parent, destination = w84_temp_part("crystal-click-w84-uu")
    keys = [1_u64, 2_u64]
    rows = [
      [] of W84MapUInt64ArrayUInt64,
      [
        [] of Tuple(UInt64, Array(UInt64)),
        [{7_u64, [] of UInt64}, {7_u64, [11_u64, 12_u64]}] of Tuple(UInt64, Array(UInt64)),
      ] of W84MapUInt64ArrayUInt64,
    ] of Array(W84MapUInt64ArrayUInt64)

    begin
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_array_uint64_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 1
      )
      w84_assert_serialization_metadata(destination)
      part = CrystalClick::WidePart.open_typed(destination, "payload")
      part.read_array_map_uint64_array_uint64_mark_range("payload", 0, 2).should eq(rows)
      part.read_array_map_uint64_array_uint64_mark_range("payload", 1, 1).should eq([rows[1]])
      part.mark_row_counts.should eq([1_u64, 1_u64])
      File.read(File.join(destination, "columns_substreams.txt")).should contain("payload%2Evalues.size2")
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes UInt64 keys and String arrays, including empty and binary String values" do
    parent, destination = w84_temp_part("crystal-click-w84-us")
    keys = [1_u64, 2_u64]
    binary = String.new(Bytes[0x00_u8, 0xff_u8, 0x80_u8])
    rows = [
      [] of W84MapUInt64ArrayString,
      [
        [] of Tuple(UInt64, Array(String)),
        [{7_u64, [] of String}, {7_u64, ["", binary]}] of Tuple(UInt64, Array(String)),
      ] of W84MapUInt64ArrayString,
    ] of Array(W84MapUInt64ArrayString)

    begin
      CrystalClick::WidePartWriter.write_uint64_array_map_uint64_array_string_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 1
      )
      w84_assert_serialization_metadata(destination)
      part = CrystalClick::WidePart.open_typed(destination, "payload")
      part.read_array_map_uint64_array_string_mark_range("payload", 0, 2).should eq(rows)
      part.mark_row_counts.should eq([1_u64, 1_u64])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes String keys and UInt64 arrays, including empty and binary keys" do
    parent, destination = w84_temp_part("crystal-click-w84-su")
    keys = [1_u64, 2_u64]
    binary = String.new(Bytes[0x41_u8, 0x00_u8, 0xff_u8])
    rows = [
      [] of W84MapStringArrayUInt64,
      [
        [] of Tuple(String, Array(UInt64)),
        [{"dup", [] of UInt64}, {"dup", [13_u64]}, {binary, [14_u64]}] of Tuple(String, Array(UInt64)),
      ] of W84MapStringArrayUInt64,
    ] of Array(W84MapStringArrayUInt64)

    begin
      CrystalClick::WidePartWriter.write_uint64_array_map_string_array_uint64_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 1
      )
      w84_assert_serialization_metadata(destination)
      part = CrystalClick::WidePart.open_typed(destination, "payload")
      part.read_array_map_string_array_uint64_mark_range("payload", 0, 2).should eq(rows)
      part.mark_row_counts.should eq([1_u64, 1_u64])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes String keys and String arrays, including duplicate, empty, and binary Strings" do
    parent, destination = w84_temp_part("crystal-click-w84-ss")
    keys = [1_u64, 2_u64]
    binary_key = String.new(Bytes[0x41_u8, 0x00_u8, 0xff_u8])
    binary_value = String.new(Bytes[0x00_u8, 0xff_u8, 0x80_u8])
    rows = [
      [] of W84MapStringArrayString,
      [
        [] of Tuple(String, Array(String)),
        [{"dup", [] of String}, {"dup", ["", binary_value]}, {binary_key, ["tail"]}] of Tuple(String, Array(String)),
      ] of W84MapStringArrayString,
    ] of Array(W84MapStringArrayString)

    begin
      CrystalClick::WidePartWriter.write_uint64_array_map_string_array_string_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 1
      )
      w84_assert_serialization_metadata(destination)
      part = CrystalClick::WidePart.open_typed(destination, "payload")
      part.read_array_map_string_array_string_mark_range("payload", 0, 2).should eq(rows)
      part.mark_row_counts.should eq([1_u64, 1_u64])
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
