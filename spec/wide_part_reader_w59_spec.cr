require "./spec_helper"

private def w59_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w59_mark_position(part : String, stream : String, mark_index : Int) : {UInt64, UInt64}
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(path).to_slice
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE
  {w59_read_u64(marks, offset), w59_read_u64(marks, offset + 8)}
end

describe CrystalClick::WidePart do
  it "admits exactly two-level Arrays with String leaves" do
    CrystalClick::WidePart.supports_typed_type?("Array(Array(String))").should be_true

    {
      "Array(Array(Nullable(String)))",
      "Array(Array(Array(String)))",
      "Array(Array(String)) trailing",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "reads nested String bytes across marks and independently selects a later mark" do
    parent = File.tempname("crystal-click-w59-reader-array-array-string")
    Dir.mkdir(parent)
    part = File.join(parent, "gaps")
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    binary = String.new(Bytes[0x61_u8, 0_u8, 0x62_u8])
    values = [
      [] of Array(String),
      [[] of String, [] of String],
      [] of Array(String),
      [] of Array(String),
      [["later", binary, "é", "x" * 5000]],
    ] of Array(Array(String))

    begin
      CrystalClick::WidePartWriter.write_uint64_array_array_string_pair(
        part,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 2
      )

      reader = CrystalClick::WidePart.open_typed(part, "payload")
      reader.column_type.should eq("Array(Array(String))")
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      reader.read_array_array_string_mark_range("payload", 0, reader.mark_count).should eq(values)
      reader.read_array_array_string_mark_range("payload", 2, 1).should eq(values[4, 1])
      w59_mark_position(part, "payload.size1", 1).should eq(w59_mark_position(part, "payload.size1", 2))
      w59_mark_position(part, "payload.size", 1).should eq(w59_mark_position(part, "payload.size", 2))
      w59_mark_position(part, "payload", 1).should eq(w59_mark_position(part, "payload", 2))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "distinguishes empty String elements from all-empty outer arrays" do
    parent = File.tempname("crystal-click-w59-empty-string-children")
    Dir.mkdir(parent)
    empty_string_part = File.join(parent, "empty-string")
    all_empty_part = File.join(parent, "all-empty")
    keys = [1_u64, 2_u64, 3_u64, 4_u64]
    empty_string_values = [
      [] of Array(String),
      [] of Array(String),
      [[""]],
      [] of Array(String),
    ] of Array(Array(String))
    all_empty_values = Array(Array(Array(String))).new(keys.size) { [] of Array(String) }

    begin
      CrystalClick::WidePartWriter.write_uint64_array_array_string_pair(
        empty_string_part,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        empty_string_values.to_unsafe.to_slice(empty_string_values.size),
        rows_per_mark: 2
      )
      empty_reader = CrystalClick::WidePart.open_typed(empty_string_part, "payload")
      empty_reader.read_array_array_string_mark_range("payload", 0, 2).should eq(empty_string_values)
      w59_mark_position(empty_string_part, "payload.size", 1).should_not eq(w59_mark_position(empty_string_part, "payload.size", 2))
      w59_mark_position(empty_string_part, "payload", 1).should eq(w59_mark_position(empty_string_part, "payload", 2))
      string_sizes = File.join(empty_string_part, "#{CrystalClick::StreamName.hash("payload.size")}.bin")
      string_bytes = File.join(empty_string_part, "#{CrystalClick::StreamName.hash("payload")}.bin")
      File.size(string_sizes).should be > 0
      File.size(string_bytes).should eq(0)

      CrystalClick::WidePartWriter.write_uint64_array_array_string_pair(
        all_empty_part,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        all_empty_values.to_unsafe.to_slice(all_empty_values.size),
        rows_per_mark: 2
      )
      all_empty_reader = CrystalClick::WidePart.open_typed(all_empty_part, "payload")
      all_empty_reader.read_array_array_string_mark_range("payload", 0, 2).should eq(all_empty_values)

      offset_stream = File.join(all_empty_part, "#{CrystalClick::StreamName.hash("payload.size0")}.bin")
      File.size(offset_stream).should be > 0
      ["payload.size1", "payload.size", "payload"].each do |stream|
        child_stream = File.join(all_empty_part, "#{CrystalClick::StreamName.hash(stream)}.bin")
        File.file?(child_stream).should be_true
        File.size(child_stream).should eq(0)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
