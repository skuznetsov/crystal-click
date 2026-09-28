require "./spec_helper"

private def w59c_values : Array(Array(Array(String)))
  binary = String.new(Bytes[0x61_u8, 0_u8, 0x62_u8])
  [
    [["first", "", binary], [] of String],
    [["second", "entry"]],
    [] of Array(String),
    [] of Array(String),
    [["middle-a"], ["middle-b"]],
    [["middle-c", ""]],
    [["later", binary, ""]],
  ] of Array(Array(String))
end

private def w59c_with_writer_part(& : String ->)
  parent = File.tempname("crystal-click-w59-array-array-string-corruption")
  Dir.mkdir(parent)
  part = File.join(parent, "all_1_1_0")
  keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
  values = w59c_values

  begin
    CrystalClick::WidePartWriter.write_uint64_array_array_string_pair(
      part,
      "pk",
      keys.to_unsafe.to_slice(keys.size),
      "payload",
      values.to_unsafe.to_slice(values.size),
      rows_per_mark: 2
    )
    yield part
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w59c_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w59c_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w59c_corrupt_decompressed_offset(part : String, stream : String, mark_index : Int, increment : UInt64) : Nil
  marks_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE + 8
  decompressed_offset = w59c_read_u64(marks, offset)
  w59c_write_u64(marks, offset, decompressed_offset + increment)
  File.write(marks_path, marks)
end

describe "W59 Array(Array(String)) corruption" do
  it "rejects independently shifted substream marks before exposing corrupt rows and still reads a later mark" do
    values = w59c_values
    cases = [
      {"payload.size0", 8_u64},
      {"payload.size1", 8_u64},
      {"payload.size", 8_u64},
      {"payload", 1_u64},
    ]

    cases.each do |test_case|
      stream = test_case[0]
      increment = test_case[1]
      w59c_with_writer_part do |part|
        valid_reader = CrystalClick::WidePart.open_typed(part, "payload")
        valid_reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
        valid_reader.read_array_array_string_mark_range("payload", 0, valid_reader.mark_count).should eq(values)

        # Mark 1 has no nested children. Mark 2 is nonempty, so shifting its
        # decompressed offset remains parseable while invalidating that mark's
        # exact child-byte range; mark 3 remains independently addressable.
        w59c_corrupt_decompressed_offset(part, stream, 2, increment)

        reader = CrystalClick::WidePart.open_typed(part, "payload")
        reader.read_array_array_string_mark_range("payload", 3, 1).should eq(values[6, 1])
        expect_raises(CrystalClick::CorruptPartError) do
          reader.read_array_array_string_mark_range("payload", 2, 1)
        end

        table = CrystalClick::WidePartTable.open_selected_typed([part], ["payload"])
        observed = [] of Array(Array(String))
        expect_raises(CrystalClick::CorruptPartError) do
          table.scan_typed(batch_rows: 2) do |batch|
            observed.concat(batch.array_array_strings_for("payload"))
          end
        end
        observed.should eq(values[0, observed.size])
        observed.size.should be <= 4
        (observed.size % 2).should eq(0)
      end
    end
  end
end
