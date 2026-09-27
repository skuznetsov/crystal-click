require "./spec_helper"

private def w21_reader_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w21_reader_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w21_reader_encode_lz4_frame(raw : Bytes) : Bytes
  raise "W21 mutation fixture cannot encode an empty frame" if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w21_reader_write_u32(frame, header + 1, compressed_size.to_u32)
  w21_reader_write_u32(frame, header + 5, raw.size.to_u32)

  cursor = CrystalClick::CompressedBlock::FRAME_HEADER_SIZE
  if raw.size < 15
    frame[cursor] = (raw.size << 4).to_u8
    cursor += 1
  else
    frame[cursor] = 0xf0_u8
    cursor += 1
    remaining = raw.size - 15
    while remaining >= 255
      frame[cursor] = 255_u8
      cursor += 1
      remaining -= 255
    end
    frame[cursor] = remaining.to_u8
    cursor += 1
  end
  raw.copy_to(frame[cursor, raw.size])
  hash = CrystalClick::CityHashV1.hash128(frame[header, compressed_size])
  8.times do |byte|
    frame[byte] = ((hash[0] >> (byte * 8)) & 0xff_u64).to_u8
    frame[8 + byte] = ((hash[1] >> (byte * 8)) & 0xff_u64).to_u8
  end
  frame
end

private def w21_reader_corrupt_u64_frame(path : String, stream : String, frame_index : Int, value : UInt64) : Nil
  raise "W21 mutation frame index must be non-negative" if frame_index < 0
  file = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")
  encoded = File.read(file).to_slice
  frame_offset = 0_i64
  frame_index.times do
    frame_offset = CrystalClick::CompressedBlock.decode_frame(encoded, frame_offset).end_offset
  end
  frame = CrystalClick::CompressedBlock.decode_frame(encoded, frame_offset)
  raw = frame.output.dup
  w21_reader_write_u64(raw, 0, value)
  rewritten = w21_reader_encode_lz4_frame(raw)
  frame_bytes = frame.end_offset - frame_offset
  raise "W21 mutation changed the frame's physical size" unless rewritten.size == frame_bytes
  result = encoded.dup
  rewritten.copy_to(result.to_unsafe + frame_offset, rewritten.size)
  File.write(file, result)
end

describe CrystalClick::WidePart do
  it "admits only the exact supported Array declarations" do
    ["Array(UInt64)", "Array(String)", "Array(Nullable(UInt64))", "Array(Array(UInt64))"].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_true
    end

    [
      "Array(UInt8)",
      "Array(Int64)",
      "Array(FixedString(8))",
      "Array(Array(Nullable(UInt64)))",
      "Array(Array(UInt64) trailing)",
      "Array( UInt64)",
      "Array(UInt64, String)",
      "Array()",
      "Array(UInt64) trailing",
    ].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "reads Array(UInt64) rows by outer mark and exposes only the exact array accessor" do
    parent = File.tempname("crystal-click-w21-reader-array-u64")
    Dir.mkdir(parent)
    part_path = File.join(parent, "all_1_1_0")
    keys = [1_u64, 2_u64, 2_u64, 4_u64, 9_u64, 11_u64, 13_u64]
    values = [
      [100_u64, 101_u64],
      [] of UInt64,
      [0_u64, UInt64::MAX],
      [42_u64],
      [7_u64, 8_u64, 9_u64],
      [] of UInt64,
      [5_u64],
    ] of Array(UInt64)

    begin
      CrystalClick::WidePartWriter.write_uint64_array_uint64_pair(
        part_path,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 2
      )

      reader = CrystalClick::WidePart.open_typed(part_path, "payload")
      reader.column_type.should eq("Array(UInt64)")
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
      reader.mark_count.should eq(4)
      reader.read_array_uint64_mark_range("payload", 0, reader.mark_count).should eq(values)
      reader.read_array_uint64_mark_range("payload", 1, 2).should eq(values[2, 4])
      serialization_path = File.join(part_path, "serialization.json")
      original_serialization = File.read(serialization_path)
      File.write(
        serialization_path,
        %({"columns":[{"kind":"Default","name":"pk","num_defaults":0,"num_rows":7}],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
      )
      stock_metadata_reader = CrystalClick::WidePart.open_typed(part_path, "payload")
      stock_metadata_reader.read_array_uint64_mark_range("payload", 0, 1).should eq(values[0, 2])
      File.write(
        serialization_path,
        %({"columns":[{"kind":"Other","name":"pk","num_defaults":0,"num_rows":7}],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
      )
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(part_path, "payload")
      end
      File.write(serialization_path, original_serialization)
      expect_raises(CrystalClick::BoundsError) do
        reader.read_array_uint64_mark_range("payload", 0, 0)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_uint64
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_numeric_mark_range("payload", 0, 1, UInt64)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_array_string_mark_range("payload", 0, 1)
      end

      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["payload"])
      observed = [] of Array(UInt64)
      offsets = [] of {Int32, UInt64, Int32}
      table.scan_typed(batch_rows: 3) do |batch|
        batch_values = batch.array_uint64s_for("payload")
        observed.concat(batch_values)
        offsets << {batch.mark_index, batch.part_row_offset, batch_values.size.to_i32}
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.values_for("payload") }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.strings_for("payload") }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_strings_for("payload") }
      end
      observed.should eq(values)
      offsets.should eq([
        {0_i32, 0_u64, 2_i32},
        {1_i32, 2_u64, 2_i32},
        {2_i32, 4_u64, 2_i32},
        {3_i32, 6_u64, 1_i32},
      ])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "reads binary-safe Array(String) elements, including empty strings, across marks" do
    parent = File.tempname("crystal-click-w21-reader-array-string")
    Dir.mkdir(parent)
    part_path = File.join(parent, "all_1_1_0")
    keys = [1_u64, 2_u64, 2_u64, 4_u64, 9_u64, 11_u64, 13_u64]
    binary = String.new(Bytes[0x61_u8, 0_u8, 0x62_u8])
    invalid_utf8 = String.new(Bytes[0xff_u8, 0_u8])
    values = [
      ["", "alpha"],
      [] of String,
      [binary, ""],
      ["é"],
      ["last", invalid_utf8],
      [] of String,
      ["z"],
    ] of Array(String)

    begin
      CrystalClick::WidePartWriter.write_uint64_array_string_pair(
        part_path,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 2
      )

      reader = CrystalClick::WidePart.open_typed(part_path, "payload")
      reader.column_type.should eq("Array(String)")
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
      reader.read_array_string_mark_range("payload", 0, reader.mark_count).should eq(values)
      reader.read_array_string_mark_range("payload", 1, 2).should eq(values[2, 4])
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_uint64
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_string_mark_range("payload", 0, 1)
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_array_uint64_mark_range("payload", 0, 1)
      end

      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["payload"])
      observed = [] of Array(String)
      table.scan_typed(batch_rows: 3) do |batch|
        batch_values = batch.array_strings_for("payload")
        observed.concat(batch_values)
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.values_for("payload", UInt64) }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.strings_for("payload") }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_uint64s_for("payload") }
      end
      observed.should eq(values)
      observed[0][0].should eq("")
      observed[2][0].to_slice.to_a.should eq([0x61_u8, 0_u8, 0x62_u8])
      observed[2][1].should eq("")
      observed[4][1].to_slice.to_a.should eq([0xff_u8, 0_u8])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "admits zero-byte flattened streams only for valid empty Array payloads" do
    parent = File.tempname("crystal-click-w21-reader-empty-arrays")
    Dir.mkdir(parent)
    u64_path = File.join(parent, "u64")
    string_empty_arrays_path = File.join(parent, "string-empty-arrays")
    string_empty_values_path = File.join(parent, "string-empty-values")
    keys = [1_u64, 2_u64, 3_u64, 4_u64]
    all_empty_u64 = Array(Array(UInt64)).new(keys.size) { [] of UInt64 }
    all_empty_string_arrays = [
      [] of String,
      [] of String,
      [] of String,
      [] of String,
    ] of Array(String)
    all_empty_string_values = [
      [] of String,
      [""],
      ["", ""],
      [] of String,
    ] of Array(String)

    begin
      CrystalClick::WidePartWriter.write_uint64_array_uint64_pair(
        u64_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        all_empty_u64.to_unsafe.to_slice(all_empty_u64.size), rows_per_mark: 2
      )
      CrystalClick::WidePart.open_typed(u64_path, "payload")
        .read_array_uint64_mark_range("payload", 0, 2).should eq(all_empty_u64)
      u64_raw = File.join(u64_path, "#{CrystalClick::StreamName.hash("payload")}.bin")
      File.file?(u64_raw).should be_true
      File.size(u64_raw).should eq(0)

      CrystalClick::WidePartWriter.write_uint64_array_string_pair(
        string_empty_arrays_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        all_empty_string_arrays.to_unsafe.to_slice(all_empty_string_arrays.size), rows_per_mark: 2
      )
      CrystalClick::WidePart.open_typed(string_empty_arrays_path, "payload")
        .read_array_string_mark_range("payload", 0, 2).should eq(all_empty_string_arrays)
      nested_sizes = File.join(string_empty_arrays_path, "#{CrystalClick::StreamName.hash("payload.size")}.bin")
      File.size(nested_sizes).should eq(0)

      CrystalClick::WidePartWriter.write_uint64_array_string_pair(
        string_empty_values_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        all_empty_string_values.to_unsafe.to_slice(all_empty_string_values.size), rows_per_mark: 2
      )
      CrystalClick::WidePart.open_typed(string_empty_values_path, "payload")
        .read_array_string_mark_range("payload", 0, 2).should eq(all_empty_string_values)
      string_raw = File.join(string_empty_values_path, "#{CrystalClick::StreamName.hash("payload")}.bin")
      File.file?(string_raw).should be_true
      File.size(string_raw).should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects malformed array metadata, mark offsets, and same-size nested lengths" do
    parent = File.tempname("crystal-click-w21-reader-array-corrupt")
    Dir.mkdir(parent)
    part_path = File.join(parent, "part")
    keys = [1_u64, 2_u64]
    values = [[11_u64, 12_u64], [] of UInt64] of Array(UInt64)

    begin
      CrystalClick::WidePartWriter.write_uint64_array_uint64_pair(
        part_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        values.to_unsafe.to_slice(values.size), rows_per_mark: 2
      )

      columns_path = File.join(part_path, "columns.txt")
      columns = File.read(columns_path)
      File.write(columns_path, columns.sub("Array(UInt64)", "Array(UInt8)"))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(part_path, "payload")
      end
      File.write(columns_path, columns)

      substreams_path = File.join(part_path, "columns_substreams.txt")
      substreams = File.read(substreams_path)
      File.write(substreams_path, substreams.sub("payload.size0", "payload.size1"))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(part_path, "payload")
      end
      File.write(substreams_path, substreams)

      marks_path = File.join(part_path, "#{CrystalClick::StreamName.hash("payload.size0")}.mrk2")
      marks = File.read(marks_path).to_slice.dup
      # A nonzero local offset for the first frame violates the zero-based mark contract.
      w21_reader_write_u64(marks, 8, 8_u64)
      File.write(marks_path, marks)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(part_path, "payload")
      end
      original_marks = File.read(marks_path).to_slice.dup
      w21_reader_write_u64(original_marks, 8, 0_u64)
      File.write(marks_path, original_marks)

      w21_reader_corrupt_u64_frame(part_path, "payload.size0", 0, UInt64::MAX)
      reader = CrystalClick::WidePart.open_typed(part_path, "payload")
      expect_raises(CrystalClick::CorruptPartError) do
        reader.read_array_uint64_mark_range("payload", 0, 1)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects unsupported Array(String) serializer versions and oversized nested lengths before allocation" do
    parent = File.tempname("crystal-click-w21-reader-array-string-corrupt")
    Dir.mkdir(parent)
    part_path = File.join(parent, "part")
    keys = [1_u64, 2_u64]
    values = [["a", "b"], [] of String] of Array(String)

    begin
      CrystalClick::WidePartWriter.write_uint64_array_string_pair(
        part_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        values.to_unsafe.to_slice(values.size), rows_per_mark: 2
      )

      serialization_path = File.join(part_path, "serialization.json")
      serialization = File.read(serialization_path)
      File.write(serialization_path, serialization.sub(%("string":1), %("string":2)))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(part_path, "payload")
      end
      File.write(serialization_path, serialization)

      w21_reader_corrupt_u64_frame(part_path, "payload.size", 0, UInt64::MAX)
      reader = CrystalClick::WidePart.open_typed(part_path, "payload")
      expect_raises(CrystalClick::CorruptPartError) do
        reader.read_array_string_mark_range("payload", 0, 1)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects same-size nested-count and String-byte corruption compensated across marks" do
    parent = File.tempname("crystal-click-w21-reader-array-compensating-corruption")
    Dir.mkdir(parent)
    u64_path = File.join(parent, "u64")
    string_count_path = File.join(parent, "string-count")
    string_bytes_path = File.join(parent, "string-bytes")
    keys = [1_u64, 2_u64]
    u64_values = [[11_u64], [12_u64]] of Array(UInt64)
    string_values = [["a"], ["b"]] of Array(String)

    begin
      CrystalClick::WidePartWriter.write_uint64_array_uint64_pair(
        u64_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        u64_values.to_unsafe.to_slice(u64_values.size), rows_per_mark: 1
      )
      # Preserve stream and mark file sizes while moving one nested element
      # from mark 1 to mark 0; aggregate flattened counts still equal two.
      w21_reader_corrupt_u64_frame(u64_path, "payload.size0", 0, 2_u64)
      w21_reader_corrupt_u64_frame(u64_path, "payload.size0", 1, 0_u64)
      u64_reader = CrystalClick::WidePart.open_typed(u64_path, "payload")
      expect_raises(CrystalClick::CorruptPartError) do
        u64_reader.read_array_uint64_mark_range("payload", 0, 2)
      end

      CrystalClick::WidePartWriter.write_uint64_array_string_pair(
        string_count_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        string_values.to_unsafe.to_slice(string_values.size), rows_per_mark: 1
      )
      # Shift one nested String-size slot across marks without changing total
      # slot count; size0 and payload counts must agree independently per mark.
      w21_reader_corrupt_u64_frame(string_count_path, "payload.size0", 0, 2_u64)
      w21_reader_corrupt_u64_frame(string_count_path, "payload.size0", 1, 0_u64)
      string_count_reader = CrystalClick::WidePart.open_typed(string_count_path, "payload")
      expect_raises(CrystalClick::CorruptPartError) do
        string_count_reader.read_array_string_mark_range("payload", 0, 2)
      end

      CrystalClick::WidePartWriter.write_uint64_array_string_pair(
        string_bytes_path, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        string_values.to_unsafe.to_slice(string_values.size), rows_per_mark: 1
      )
      # Preserve the total nested raw-byte sum while moving a byte between
      # String-size marks. The raw data marks must match each size mark.
      w21_reader_corrupt_u64_frame(string_bytes_path, "payload.size", 0, 0_u64)
      w21_reader_corrupt_u64_frame(string_bytes_path, "payload.size", 1, 2_u64)
      string_bytes_reader = CrystalClick::WidePart.open_typed(string_bytes_path, "payload")
      expect_raises(CrystalClick::CorruptPartError) do
        string_bytes_reader.read_array_string_mark_range("payload", 0, 2)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "bounds outer rows and flattened elements before array result allocation" do
    parent = File.tempname("crystal-click-w21-reader-array-bounds")
    Dir.mkdir(parent)
    rows_path = File.join(parent, "rows")
    elements_path = File.join(parent, "elements")
    oversized_rows = Array(Array(UInt64)).new(CrystalClick::WidePart::MAX_ARRAY_MARK_ROWS.to_i + 1) { [] of UInt64 }
    row_keys = Array(UInt64).new(oversized_rows.size) { |index| index.to_u64 }
    first_mark_elements = Array(UInt64).new(CrystalClick::WidePart::MAX_ARRAY_MARK_ELEMENTS.to_i) { |index| index.to_u64 }
    oversized_elements = [first_mark_elements, [99_u64]] of Array(UInt64)
    element_keys = [1_u64, 2_u64]

    begin
      CrystalClick::WidePartWriter.write_uint64_array_uint64_pair(
        rows_path, "pk", row_keys.to_unsafe.to_slice(row_keys.size), "payload",
        oversized_rows.to_unsafe.to_slice(oversized_rows.size), rows_per_mark: CrystalClick::WidePart::MAX_ARRAY_MARK_ROWS.to_i
      )
      rows_reader = CrystalClick::WidePart.open_typed(rows_path, "payload")
      expect_raises(CrystalClick::CorruptPartError) do
        rows_reader.read_array_uint64_mark_range("payload", 0, rows_reader.mark_count)
      end

      CrystalClick::WidePartWriter.write_uint64_array_uint64_pair(
        elements_path, "pk", element_keys.to_unsafe.to_slice(element_keys.size), "payload",
        oversized_elements.to_unsafe.to_slice(oversized_elements.size), rows_per_mark: 1
      )
      elements_reader = CrystalClick::WidePart.open_typed(elements_path, "payload")
      expect_raises(CrystalClick::CorruptPartError) do
        elements_reader.read_array_uint64_mark_range("payload", 0, elements_reader.mark_count)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
