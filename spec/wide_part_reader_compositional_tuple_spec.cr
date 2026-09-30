require "./spec_helper"

private def w94_reader_tuple_type(columns : Array(CrystalClick::WideTupleLeafColumn)) : String
  "Tuple(#{columns.map { |column| "#{column.name} #{column.type_name}" }.join(", ")})"
end

private def w94_reader_write_part(
  parent : String,
  name : String,
  columns : Array(CrystalClick::WideTupleLeafColumn),
  rows_per_mark : Int32 = 2,
) : String
  row_count = columns.first?.try(&.size) || 0
  keys = Array(UInt64).new(row_count) { |index| index.to_u64 }
  part_container = File.join(parent, name)
  Dir.mkdir(part_container)
  destination = File.join(part_container, "all_1_1_0")
  type_name = w94_reader_tuple_type(columns)
  CrystalClick::WidePartWriter.write_uint64_tuple_pair(
    destination,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "payload",
    type_name,
    columns,
    rows_per_mark: rows_per_mark
  )
  destination
end

private def w94_reader_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def w94_reader_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w94_reader_repartition_first_two_marks(part : String, stream : String) : Nil
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(path).to_slice.dup
  w94_reader_write_u64(marks, 16, 1_u64)
  w94_reader_write_u64(marks, CrystalClick::WidePart::MARK_SIZE + 16, 3_u64)
  File.write(path, marks)
end

private def w94_reader_corrupt_mark_frame_header(part : String, stream : String, mark_index : Int) : Nil
  marks = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE
  compressed_offset = w94_reader_read_u64(marks, offset).to_i
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  bytes = File.read(path).to_slice.dup
  decompressed_size_offset = compressed_offset + CrystalClick::CompressedBlock::CHECKSUM_SIZE + 5
  if compressed_offset < 0 || decompressed_size_offset > bytes.size - 4
    raise "W94 frame-header corruption target is outside the stream"
  end
  4.times { |index| bytes[decompressed_size_offset + index] = 0_u8 }
  File.write(path, bytes)
end

private def w94_reader_point_mark_inside_first_frame(part : String, stream : String) : Nil
  mark_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(mark_path).to_slice.dup
  first_offset = w94_reader_read_u64(marks, 0)
  data_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  data = File.read(data_path).to_slice
  first_frame = CrystalClick::CompressedBlock.decode_frame(data, first_offset.to_i64)
  malformed_end = first_offset + 1_u64
  if malformed_end >= first_frame.end_offset.to_u64
    raise "W94 malformed end mark must point inside the first compressed frame"
  end
  w94_reader_write_u64(marks, CrystalClick::WidePart::MARK_SIZE, malformed_end)
  File.write(mark_path, marks)
end

private def w94_reader_assert_result(
  data : CrystalClick::WideTupleColumnData,
  expected_columns : Array(CrystalClick::WideTupleLeafColumn),
  first_row : Int32,
  row_count : Int32,
) : Nil
  data.row_count.should eq(row_count)
  data.fields.map { |field| {field.name, field.type_name} }.should eq(
    expected_columns.map { |column| {column.name, column.type_name} }
  )

  actual_columns = data.columns
  actual_columns.size.should eq(expected_columns.size)
  expected_columns.each_with_index do |expected, index|
    actual = actual_columns[index]
    actual.name.should eq(expected.name)
    actual.type_name.should eq(expected.type_name)
    if expected.type_name == "UInt64"
      actual.uint64_values.should eq(expected.uint64_values[first_row, row_count])
    else
      actual.string_values.should eq(expected.string_values[first_row, row_count])
    end
  end
  nil
end

describe "W94 compositional named Tuple reader" do
  it "preserves the exact pair API while exposing the same part as owned columns" do
    part = File.expand_path("../test/fixtures/public/wide_tuple_uint64_string/part", __DIR__)
    reader = CrystalClick::WidePart.open_typed(part, "payload")
    expected = [
      {0_u64, ""},
      {UInt64::MAX, "short"},
      {2_u64, String.new(Bytes[0x41_u8, 0x00_u8, 0x42_u8, 0xff_u8])},
      {3_u64, "a much longer payload crossing offsets"},
      {4_u64, ""},
    ] of Tuple(UInt64, String)

    reader.read_tuple_uint64_string_mark_range("payload", 0, 3).should eq(expected)
    generic = reader.read_tuple_mark_range("payload", 0, 3)
    generic["a"].uint64_values.should eq(expected.map(&.[0]))
    generic["b"].string_values.should eq(expected.map(&.[1]))
    w94_reader_assert_result(
      reader.read_tuple_mark_range("payload", 1, 1),
      [
        CrystalClick::WideTupleLeafColumn.new("a", expected.map(&.[0])),
        CrystalClick::WideTupleLeafColumn.new("b", expected.map(&.[1])),
      ] of CrystalClick::WideTupleLeafColumn,
      2,
      2
    )
  end

  it "rejects negative and oversized public mark bounds before narrowing to Int32" do
    part = File.expand_path("../test/fixtures/public/wide_tuple_uint64_string/part", __DIR__)
    reader = CrystalClick::WidePart.open_typed(part, "payload")

    expect_raises(CrystalClick::BoundsError) do
      reader.read_tuple_mark_range("payload", -1_i64, 1_i64)
    end
    expect_raises(CrystalClick::BoundsError) do
      reader.read_tuple_mark_range("payload", Int64::MAX, 1_i64)
    end

    callbacks = 0
    expect_raises(CrystalClick::BoundsError) do
      reader.each_tuple_mark_range("payload", 0_i64, Int64::MAX) do |_mark, _mark_index|
        callbacks += 1
        nil
      end
    end
    callbacks.should eq(0)
  end

  it "reads 1-, 2-, 3-, and 9-leaf profiles in declared order across a short final mark" do
    profiles = [] of Tuple(String, Array(CrystalClick::WideTupleLeafColumn))
    profiles << {"one", [
      CrystalClick::WideTupleLeafColumn.new("only", [1_u64, 3_u64, UInt64::MAX, 7_u64, 9_u64]),
    ] of CrystalClick::WideTupleLeafColumn}
    profiles << {"two", [
      CrystalClick::WideTupleLeafColumn.new("text", ["", "é", String.new(Bytes[0xff_u8, 0_u8]), "", "last"] of String),
      CrystalClick::WideTupleLeafColumn.new("number", [8_u64, 9_u64, 10_u64, 11_u64, 12_u64]),
    ] of CrystalClick::WideTupleLeafColumn}
    profiles << {"three", [
      CrystalClick::WideTupleLeafColumn.new("first", ["", "", "", "", ""] of String),
      CrystalClick::WideTupleLeafColumn.new("middle", ["a", "", "b\0c", "", ""] of String),
      CrystalClick::WideTupleLeafColumn.new("last", ["", "", "", "", ""] of String),
    ] of CrystalClick::WideTupleLeafColumn}
    profiles << {"nine", [
      CrystalClick::WideTupleLeafColumn.new("a", [0_u64, 1_u64, 2_u64, 3_u64, 4_u64]),
      CrystalClick::WideTupleLeafColumn.new("b", ["", "b", "", "d", ""] of String),
      CrystalClick::WideTupleLeafColumn.new("c", ["c", "", "", "", "e"] of String),
      CrystalClick::WideTupleLeafColumn.new("d", [5_u64, 6_u64, 7_u64, 8_u64, 9_u64]),
      CrystalClick::WideTupleLeafColumn.new("e", ["", "", "i", "", ""] of String),
      CrystalClick::WideTupleLeafColumn.new("f", [10_u64, 11_u64, 12_u64, 13_u64, 14_u64]),
      CrystalClick::WideTupleLeafColumn.new("g", ["g", "", "", "h", ""] of String),
      CrystalClick::WideTupleLeafColumn.new("h", [15_u64, 16_u64, 17_u64, 18_u64, 19_u64]),
      CrystalClick::WideTupleLeafColumn.new("i", ["", "", "", "", ""] of String),
    ] of CrystalClick::WideTupleLeafColumn}

    parent = File.tempname("crystal-click-w94-reader-composition")
    Dir.mkdir(parent)
    begin
      profiles.each do |name, columns|
        part = w94_reader_write_part(parent, name, columns)
        reader = CrystalClick::WidePart.open_typed(part, "payload")
        result = reader.read_tuple_mark_range("payload", 0, reader.mark_count)
        w94_reader_assert_result(result, columns, 0, 5)
        w94_reader_assert_result(reader.read_tuple_mark_range("payload", 1, 2), columns, 2, 3)

        marks = [] of Tuple(Int32, CrystalClick::WideTupleColumnData)
        reader.each_tuple_mark_range("payload", 0, reader.mark_count) do |mark, mark_index|
          marks << {mark_index, mark}
          nil
        end
        marks.map(&.[0]).should eq([0, 1, 2])
        marks.map { |(_, mark)| mark.row_count }.should eq([2, 2, 1])
        row_offset = 0
        marks.each do |(_, mark)|
          w94_reader_assert_result(mark, columns, row_offset, mark.row_count)
          row_offset += mark.row_count
        end
        row_offset.should eq(5)

        visited = [] of Int32
        expect_raises(Exception) do
          reader.each_tuple_mark_range("payload", 0, reader.mark_count) do |_mark, mark_index|
            visited << mark_index
            raise "stop at first consumer callback"
          end
        end
        visited.should eq([0])

        key_reader = CrystalClick::WidePart.open_typed(part, "pk")
        expect_raises(CrystalClick::UnsupportedFormatError) do
          key_reader.read_tuple_mark_range("pk", 0, 1)
        end
        expect_raises(CrystalClick::UnsupportedFormatError) do
          reader.read_numeric_mark_range("payload", 0, 1, UInt64)
        end

        if name == "three"
          expect_raises(CrystalClick::UnsupportedFormatError) do
            reader.read_tuple_uint64_string_mark_range("payload", 0, 1)
          end
          callbacks = 0
          table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
          expect_raises(CrystalClick::UnsupportedFormatError) do
            table.scan_typed do |_batch|
              callbacks += 1
              nil
            end
          end
          callbacks.should eq(0)
        end
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a checksum-independent mismatched leaf mark schedule before a reader can expose rows" do
    columns = [
      CrystalClick::WideTupleLeafColumn.new("text", ["a", "b", "c", "d", "e"] of String),
      CrystalClick::WideTupleLeafColumn.new("number", [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]),
    ] of CrystalClick::WideTupleLeafColumn
    parent = File.tempname("crystal-click-w94-reader-mark-schedule")
    Dir.mkdir(parent)
    begin
      valid_part = w94_reader_write_part(parent, "valid", columns)
      malformed_container = File.join(parent, "misaligned")
      Dir.mkdir(malformed_container)
      malformed_part = File.join(malformed_container, "all_2_2_0")
      FileUtils.cp_r(valid_part, malformed_part)
      w94_reader_repartition_first_two_marks(malformed_part, "payload%2Etext.size")

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError, "selected substreams have different mark row counts") do
        table = CrystalClick::WidePartTable.open_selected_typed([malformed_part], ["payload"])
        table.scan_typed do |_batch|
          callbacks += 1
          nil
        end
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "charges empty String slots together and refuses before invoking an iterator callback" do
    columns = Array(CrystalClick::WideTupleLeafColumn).new(9) do |index|
      name = ["a", "b", "c", "d", "e", "f", "g", "h", "i"][index]
      CrystalClick::WideTupleLeafColumn.new(name, [""] of String)
    end
    parent = File.tempname("crystal-click-w94-reader-budget")
    Dir.mkdir(parent)
    begin
      part = w94_reader_write_part(parent, "empty-nine", columns, 1)
      reader = CrystalClick::WidePart.open_typed(part, "payload")
      expect_raises(CrystalClick::CorruptPartError, "Tuple materialization charge exceeds per-range limit") do
        reader.read_tuple_mark_range("payload", 0, 1, max_materialized_bytes: 431_u64)
      end

      callbacks = [] of Int32
      expect_raises(CrystalClick::CorruptPartError, "Tuple materialization charge exceeds per-range limit") do
        reader.each_tuple_mark_range("payload", 0, 1, max_materialized_bytes: 431_u64) do |_mark, mark_index|
          callbacks << mark_index
          nil
        end
      end
      callbacks.should be_empty

      result = reader.read_tuple_mark_range("payload", 0, 1, max_materialized_bytes: 432_u64)
      result.row_count.should eq(1)
      result.columns.each { |column| column.string_values.should eq([""]) }
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps later frame-header corruption lazy for ranges and reports it only after earlier mark callbacks" do
    columns = [
      CrystalClick::WideTupleLeafColumn.new("text", ["first", "second", "third"] of String),
      CrystalClick::WideTupleLeafColumn.new("number", [1_u64, 2_u64, 3_u64]),
    ] of CrystalClick::WideTupleLeafColumn
    parent = File.tempname("crystal-click-w94-reader-lazy")
    Dir.mkdir(parent)
    begin
      part = w94_reader_write_part(parent, "lazy", columns, 1)
      reader = CrystalClick::WidePart.open_typed(part, "payload")
      w94_reader_corrupt_mark_frame_header(part, "payload%2Etext", 1)

      first = reader.read_tuple_mark_range("payload", 0, 1)
      first["text"].string_values.should eq(["first"])

      callbacks = [] of Int32
      expect_raises(CrystalClick::CorruptPartError) do
        reader.each_tuple_mark_range("payload", 0, 3) do |_mark, mark_index|
          callbacks << mark_index
          nil
        end
      end
      callbacks.should eq([0])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a non-sentinel end mark that points inside the selected frame" do
    columns = [
      CrystalClick::WideTupleLeafColumn.new("text", ["first", "second"] of String),
      CrystalClick::WideTupleLeafColumn.new("number", [1_u64, 2_u64]),
    ] of CrystalClick::WideTupleLeafColumn
    parent = File.tempname("crystal-click-w94-reader-malformed-endmark")
    Dir.mkdir(parent)
    begin
      part = w94_reader_write_part(parent, "malformed-endmark", columns, 1)
      w94_reader_point_mark_inside_first_frame(part, "payload%2Etext")
      reader = CrystalClick::WidePart.open_typed(part, "payload")

      expect_raises(CrystalClick::CorruptPartError) do
        reader.read_tuple_mark_range("payload", 0, 1)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
