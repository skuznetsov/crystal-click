require "./wide_part_reader_w73_helpers"

W78_READER_NUMERIC_LEAVES = [
  {"UInt8", 1},
  {"UInt16", 2},
  {"UInt32", 4},
  {"UInt64", 8},
  {"Int8", 1},
  {"Int16", 2},
  {"Int32", 4},
  {"Int64", 8},
  {"Float32", 4},
  {"Float64", 8},
]

private def w78_reader_numeric_frame(raw : Bytes) : Bytes
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w71_write_u32(frame, header + 1, compressed_size.to_u32)
  w71_write_u32(frame, header + 5, raw.size.to_u32)

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
  raw.copy_to(frame.to_unsafe + cursor, raw.size)
  hash = CrystalClick::CityHashV1.hash128(frame[header, compressed_size])
  w71_write_u64(frame, 0, hash[0])
  w71_write_u64(frame, 8, hash[1])
  frame
end

# Build a physically width-correct numeric leaf stream from an existing
# Map(K, Array(UInt64)) writer fixture. The fixture key/size streams remain
# byte-for-byte stock-shaped; only leaf bytes and the leaf stream's marks are
# re-encoded, independently of the production W78 reader.
private def w78_reader_rewrite_numeric_leaf(
  path : String,
  key_type : String,
  leaf_type : String,
  width : Int32,
  mark_leaf_counts : Array(Int32),
) : Nil
  columns_path = File.join(path, "columns.txt")
  columns = File.read(columns_path)
  source_type = "Map(#{key_type}, Array(UInt64))"
  target_type = "Map(#{key_type}, Array(#{leaf_type}))"
  raise "W78 fixture source metadata differs" unless columns.includes?(source_type)
  File.write(columns_path, columns.gsub(source_type, target_type))

  stream = "payload%2Evalues"
  data_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")
  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  mark_bytes = File.read(marks_path).to_slice.dup
  mark_size = CrystalClick::WidePart::MARK_SIZE
  raise "W78 fixture has partial leaf marks" unless mark_bytes.size % mark_size == 0
  mark_records = mark_bytes.size // mark_size
  raise "W78 fixture lacks terminal leaf mark" if mark_records < 2

  original_values = w71_raw_stream(path, stream)
  original_raw = original_values.to_unsafe.to_slice(original_values.size)
  rewritten = IO::Memory.new
  expected_numeric_raw = IO::Memory.new
  compressed_offset = 0_u64
  source_offset = 0

  raise "W78 fixture leaf mark count differs" unless mark_leaf_counts.size == mark_records - 1
  mark_leaf_counts.each_with_index do |leaf_count, mark_index|
    mark_offset = mark_index * mark_size
    raise "W78 fixture UInt64 payload exceeds source stream" if leaf_count < 0 || leaf_count > (original_raw.size - source_offset) // 8
    narrow = Bytes.new(leaf_count * width)
    leaf_count.times do |element_index|
      (narrow.to_unsafe + element_index * width).copy_from(original_raw.to_unsafe + source_offset + element_index * 8, width)
    end
    expected_numeric_raw.write(narrow)

    w71_write_u64(mark_bytes, mark_offset, compressed_offset)
    # Wide marks use a local decompressed offset within each compressed frame.
    w71_write_u64(mark_bytes, mark_offset + 8, 0_u64)
    unless narrow.empty?
      frame = w78_reader_numeric_frame(narrow)
      rewritten.write(frame)
      compressed_offset += frame.size.to_u64
    end
    source_offset += leaf_count * 8
  end
  raise "W78 fixture UInt64 payload has trailing bytes" unless source_offset == original_raw.size

  terminal_offset = (mark_records - 1) * mark_size
  w71_write_u64(mark_bytes, terminal_offset, compressed_offset)
  w71_write_u64(mark_bytes, terminal_offset + 8, 0_u64)
  File.write(data_path, rewritten.to_slice)
  File.write(marks_path, mark_bytes)
  decoded_numeric_raw = CrystalClick::CompressedBlock.decode_all(File.read(data_path).to_slice)
  raise "W78 fixture numeric frames differ from intended leaf bytes" unless decoded_numeric_raw == expected_numeric_raw.to_slice
end

private def with_w78_reader_uint64_key_int8_part(& : String, Array(Array(Tuple(UInt64, Array(Int8)))) ->) : Nil
  parent = File.tempname("crystal-click-w78-reader-u64-int8")
  Dir.mkdir(parent)
  part = File.join(parent, "all_1_1_0")
  keys = Array(UInt64).new(8) { |index| index.to_u64 }
  rows = [
    [] of Tuple(UInt64, Array(UInt64)),
    [{5_u64, [] of UInt64}, {5_u64, [] of UInt64}] of Tuple(UInt64, Array(UInt64)),
    [{9_u64, [0x80_u64, 0xff_u64, 0_u64, 0x7f_u64] of UInt64}] of Tuple(UInt64, Array(UInt64)),
    [{9_u64, [] of UInt64}] of Tuple(UInt64, Array(UInt64)),
    [{42_u64, [] of UInt64}, {42_u64, [17_u64, 0xfb_u64] of UInt64}] of Tuple(UInt64, Array(UInt64)),
    [] of Tuple(UInt64, Array(UInt64)),
    [] of Tuple(UInt64, Array(UInt64)),
    [{UInt64::MAX, [] of UInt64}] of Tuple(UInt64, Array(UInt64)),
  ] of Array(Tuple(UInt64, Array(UInt64)))
  expected = [
    [] of Tuple(UInt64, Array(Int8)),
    [{5_u64, [] of Int8}, {5_u64, [] of Int8}] of Tuple(UInt64, Array(Int8)),
    [{9_u64, [Int8::MIN, -1_i8, 0_i8, Int8::MAX] of Int8}] of Tuple(UInt64, Array(Int8)),
    [{9_u64, [] of Int8}] of Tuple(UInt64, Array(Int8)),
    [{42_u64, [] of Int8}, {42_u64, [17_i8, -5_i8] of Int8}] of Tuple(UInt64, Array(Int8)),
    [] of Tuple(UInt64, Array(Int8)),
    [] of Tuple(UInt64, Array(Int8)),
    [{UInt64::MAX, [] of Int8}] of Tuple(UInt64, Array(Int8)),
  ] of Array(Tuple(UInt64, Array(Int8)))

  begin
    CrystalClick::WidePartWriter.write_uint64_map_uint64_array_uint64_pair(
      part, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
      rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2
    )
    w78_reader_rewrite_numeric_leaf(part, "UInt64", "Int8", 1, [0, 4, 2, 0])
    yield part, expected
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def with_w78_reader_string_key_float64_part(& : String, Array(Array(Tuple(String, Array(Float64)))) ->) : Nil
  parent = File.tempname("crystal-click-w78-reader-string-f64")
  Dir.mkdir(parent)
  part = File.join(parent, "all_1_1_0")
  keys = Array(UInt64).new(8) { |index| index.to_u64 }
  nan_bits = 0x7ff8_0000_0000_0042_u64
  negative_zero_bits = 0x8000_0000_0000_0000_u64
  rows = [
    [] of Tuple(String, Array(UInt64)),
    [{"dup", [] of UInt64}, {"dup", [] of UInt64}] of Tuple(String, Array(UInt64)),
    [{String.new(Bytes[0x6b_u8, 0_u8, 0xff_u8]), [negative_zero_bits, nan_bits] of UInt64}] of Tuple(String, Array(UInt64)),
    [{"雪", [1.5_f64.unsafe_as(UInt64), (-2.25_f64).unsafe_as(UInt64)] of UInt64}] of Tuple(String, Array(UInt64)),
    [{"dup", [negative_zero_bits, nan_bits] of UInt64}] of Tuple(String, Array(UInt64)),
    [] of Tuple(String, Array(UInt64)),
    [] of Tuple(String, Array(UInt64)),
    [{"", [] of UInt64}] of Tuple(String, Array(UInt64)),
  ] of Array(Tuple(String, Array(UInt64)))
  expected = [
    [] of Tuple(String, Array(Float64)),
    [{"dup", [] of Float64}, {"dup", [] of Float64}] of Tuple(String, Array(Float64)),
    [{String.new(Bytes[0x6b_u8, 0_u8, 0xff_u8]), [negative_zero_bits.unsafe_as(Float64), nan_bits.unsafe_as(Float64)] of Float64}] of Tuple(String, Array(Float64)),
    [{"雪", [1.5_f64, -2.25_f64] of Float64}] of Tuple(String, Array(Float64)),
    [{"dup", [negative_zero_bits.unsafe_as(Float64), nan_bits.unsafe_as(Float64)] of Float64}] of Tuple(String, Array(Float64)),
    [] of Tuple(String, Array(Float64)),
    [] of Tuple(String, Array(Float64)),
    [{"", [] of Float64}] of Tuple(String, Array(Float64)),
  ] of Array(Tuple(String, Array(Float64)))

  begin
    CrystalClick::WidePartWriter.write_uint64_map_string_array_uint64_pair(
      part, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
      rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2
    )
    w78_reader_rewrite_numeric_leaf(part, "String", "Float64", 8, [0, 4, 2, 0])
    yield part, expected
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe "W78 exact numeric Map Array reader admission" do
  it "admits the ten W76 numeric leaves under both exact W78 Map keys" do
    W78_READER_NUMERIC_LEAVES.each do |leaf_type, _width|
      CrystalClick::WidePart.map_uint64_array_numeric_value_type("Map(UInt64, Array(#{leaf_type}))").should eq(leaf_type)
      CrystalClick::WidePart.map_string_array_numeric_value_type("Map(String, Array(#{leaf_type}))").should eq(leaf_type)
      CrystalClick::WidePart.supports_typed_type?("Map(UInt64, Array(#{leaf_type}))").should be_true
      CrystalClick::WidePart.supports_typed_type?("Map(String, Array(#{leaf_type}))").should be_true
    end
  end

  it "rejects near-miss declarations outside the W78 exact grammar" do
    {
      "Map(Int64, Array(UInt64))",
      "Map(UInt32, Array(Int8))",
      "Map(UInt64, Array(Nullable(Int8)))",
      "Map(UInt64, Array(Array(Int8)))",
      "Map(UInt64, Nullable(Array(Int8)))",
      "Map(UInt64, Array(BFloat16))",
      "Map(UInt64, Array(Int128))",
      "Map(UInt64,Array(Int8))",
      "Map(UInt64, Array(Int8)) trailing",
    }.each do |type|
      CrystalClick::WidePart.map_uint64_array_numeric_value_type(type).should be_nil
      CrystalClick::WidePart.map_string_array_numeric_value_type(type).should be_nil
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end
end

describe "W78 numeric Map Array reader" do
  it "decodes ordered UInt64-key entries and narrow signed leaves across empty marks" do
    with_w78_reader_uint64_key_int8_part do |path, expected|
      reader = CrystalClick::WidePart.open_typed(path, "payload")
      reader.column_type.should eq("Map(UInt64, Array(Int8))")
      reader.read_map_uint64_array_numeric_mark_range("payload", 0, reader.mark_count, Int8).should eq(expected)
      reader.read_map_uint64_array_numeric_mark_range("payload", 1, 2, Int8).should eq(expected[2, 4])
      reader.map_uint64_array_numeric_mark_range_raw_bytes("payload", 0, reader.mark_count).should eq(62_u64)
      reader.map_uint64_array_numeric_mark_range_materialization_preflight("payload", 0, reader.mark_count, Int8)
        .should eq({62_u64, 406_u64})
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
    end
  end

  it "decodes String keys and preserves floating leaf bits through the last empty mark" do
    with_w78_reader_string_key_float64_part do |path, expected|
      reader = CrystalClick::WidePart.open_typed(path, "payload")
      reader.column_type.should eq("Map(String, Array(Float64))")
      actual = reader.read_map_string_array_numeric_mark_range("payload", 0, reader.mark_count, Float64)
      actual.map { |row| row.map { |key, values| {key, values.map(&.unsafe_as(UInt64))} } }
        .should eq(expected.map { |row| row.map { |key, values| {key, values.map(&.unsafe_as(UInt64))} } })
      selected = reader.read_map_string_array_numeric_mark_range("payload", 1, 2, Float64)
      selected.map { |row| row.map { |key, values| {key, values.map(&.unsafe_as(UInt64))} } }
        .should eq(expected[2, 4].map { |row| row.map { |key, values| {key, values.map(&.unsafe_as(UInt64))} } })
      reader.map_string_array_numeric_mark_range_raw_bytes("payload", 0, reader.mark_count).should eq(63_u64)
      reader.map_string_array_numeric_mark_range_materialization_preflight("payload", 0, reader.mark_count, Float64)
        .should eq({63_u64, 367_u64})
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64])
    end
  end

  it "rejects a shifted selected numeric-leaf mark before exposing that range" do
    with_w78_reader_uint64_key_int8_part do |path, _expected|
      w71_shift_mark(path, "payload%2Evalues", 2)
      reader = CrystalClick::WidePart.open_typed(path, "payload")
      expect_raises(CrystalClick::CorruptPartError) do
        reader.read_map_uint64_array_numeric_mark_range("payload", 2, 1, Int8)
      end
    end
  end
end
