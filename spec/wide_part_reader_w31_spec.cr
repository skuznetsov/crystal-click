require "./spec_helper"

W31_ARRAY_NULLABLE_NUMERIC_FIXTURE = File.expand_path("../test/fixtures/public/wide_array_nullable_numeric/part", __DIR__)
W31_ARRAY_NULLABLE_NUMERIC_COLUMNS = {
  {"arr_u8", "UInt8"},
  {"arr_u16", "UInt16"},
  {"arr_u32", "UInt32"},
  {"arr_u64", "UInt64"},
  {"arr_i8", "Int8"},
  {"arr_i16", "Int16"},
  {"arr_i32", "Int32"},
  {"arr_i64", "Int64"},
  {"arr_f32", "Float32"},
  {"arr_f64", "Float64"},
}

private def w31_expected_values(type : T.class) : Array(Array(T?)) forall T
  {% if T == UInt8 %}
    [
      [] of UInt8?, [] of UInt8?, [nil, 0_u8, UInt8::MAX] of UInt8?, [] of UInt8?,
      [nil] of UInt8?, [nil, nil] of UInt8?, [] of UInt8?, [] of UInt8?,
      [1_u8, nil, UInt8::MAX] of UInt8?, [UInt8::MAX, 0_u8] of UInt8?, [] of UInt8?,
    ] of Array(UInt8?)
  {% elsif T == UInt16 %}
    [
      [] of UInt16?, [] of UInt16?, [nil, 0_u16, UInt16::MAX] of UInt16?, [] of UInt16?,
      [nil] of UInt16?, [nil, nil] of UInt16?, [] of UInt16?, [] of UInt16?,
      [1_u16, nil, UInt16::MAX] of UInt16?, [UInt16::MAX, 0_u16] of UInt16?, [] of UInt16?,
    ] of Array(UInt16?)
  {% elsif T == UInt32 %}
    [
      [] of UInt32?, [] of UInt32?, [nil, 0_u32, UInt32::MAX] of UInt32?, [] of UInt32?,
      [nil] of UInt32?, [nil, nil] of UInt32?, [] of UInt32?, [] of UInt32?,
      [1_u32, nil, UInt32::MAX] of UInt32?, [UInt32::MAX, 0_u32] of UInt32?, [] of UInt32?,
    ] of Array(UInt32?)
  {% elsif T == UInt64 %}
    [
      [] of UInt64?, [] of UInt64?, [nil, 0_u64, UInt64::MAX] of UInt64?, [] of UInt64?,
      [nil] of UInt64?, [nil, nil] of UInt64?, [] of UInt64?, [] of UInt64?,
      [1_u64, nil, UInt64::MAX] of UInt64?, [UInt64::MAX, 0_u64] of UInt64?, [] of UInt64?,
    ] of Array(UInt64?)
  {% elsif T == Int8 %}
    [
      [] of Int8?, [] of Int8?, [nil, 0_i8, Int8::MAX] of Int8?, [] of Int8?,
      [nil] of Int8?, [nil, nil] of Int8?, [] of Int8?, [] of Int8?,
      [Int8::MIN, nil, -1_i8] of Int8?, [Int8::MAX, 0_i8] of Int8?, [] of Int8?,
    ] of Array(Int8?)
  {% elsif T == Int16 %}
    [
      [] of Int16?, [] of Int16?, [nil, 0_i16, Int16::MAX] of Int16?, [] of Int16?,
      [nil] of Int16?, [nil, nil] of Int16?, [] of Int16?, [] of Int16?,
      [Int16::MIN, nil, -1_i16] of Int16?, [Int16::MAX, 0_i16] of Int16?, [] of Int16?,
    ] of Array(Int16?)
  {% elsif T == Int32 %}
    [
      [] of Int32?, [] of Int32?, [nil, 0_i32, Int32::MAX] of Int32?, [] of Int32?,
      [nil] of Int32?, [nil, nil] of Int32?, [] of Int32?, [] of Int32?,
      [Int32::MIN, nil, -1_i32] of Int32?, [Int32::MAX, 0_i32] of Int32?, [] of Int32?,
    ] of Array(Int32?)
  {% elsif T == Int64 %}
    [
      [] of Int64?, [] of Int64?, [nil, 0_i64, Int64::MAX] of Int64?, [] of Int64?,
      [nil] of Int64?, [nil, nil] of Int64?, [] of Int64?, [] of Int64?,
      [Int64::MIN, nil, -1_i64] of Int64?, [Int64::MAX, 0_i64] of Int64?, [] of Int64?,
    ] of Array(Int64?)
  {% elsif T == Float32 %}
    [
      [] of Float32?, [] of Float32?,
      [nil, 0x8000_0000_u32.unsafe_as(Float32), 0x0000_0000_u32.unsafe_as(Float32), 0x7fc1_2345_u32.unsafe_as(Float32), 0x7f7f_ffff_u32.unsafe_as(Float32), 0x7f80_0000_u32.unsafe_as(Float32)] of Float32?,
      [] of Float32?, [nil] of Float32?, [nil, nil] of Float32?, [] of Float32?, [] of Float32?,
      [0x3fc0_0000_u32.unsafe_as(Float32), nil, 0xff80_0000_u32.unsafe_as(Float32), 0x0000_0001_u32.unsafe_as(Float32)] of Float32?,
      [0xff7f_ffff_u32.unsafe_as(Float32), 0xc010_0000_u32.unsafe_as(Float32), 0x8000_0001_u32.unsafe_as(Float32)] of Float32?,
      [] of Float32?,
    ] of Array(Float32?)
  {% elsif T == Float64 %}
    [
      [] of Float64?, [] of Float64?,
      [nil, 0x8000_0000_0000_0000_u64.unsafe_as(Float64), 0x0000_0000_0000_0000_u64.unsafe_as(Float64), 0x7ff8_0000_0000_1234_u64.unsafe_as(Float64), 0x7fef_ffff_ffff_ffff_u64.unsafe_as(Float64), 0x7ff0_0000_0000_0000_u64.unsafe_as(Float64)] of Float64?,
      [] of Float64?, [nil] of Float64?, [nil, nil] of Float64?, [] of Float64?, [] of Float64?,
      [0x3ff8_0000_0000_0000_u64.unsafe_as(Float64), nil, 0xfff0_0000_0000_0000_u64.unsafe_as(Float64), 0x0000_0000_0000_0001_u64.unsafe_as(Float64)] of Float64?,
      [0xffef_ffff_ffff_ffff_u64.unsafe_as(Float64), 0xc002_0000_0000_0000_u64.unsafe_as(Float64), 0x8000_0000_0000_0001_u64.unsafe_as(Float64)] of Float64?,
      [] of Float64?,
    ] of Array(Float64?)
  {% else %}
    raise "unsupported W31 test type"
  {% end %}
end

private def w31_numeric_bits(value : T) : UInt64 forall T
  {% if T == UInt8 || T == Int8 %}
    value.unsafe_as(UInt8).to_u64
  {% elsif T == UInt16 || T == Int16 %}
    value.unsafe_as(UInt16).to_u64
  {% elsif T == UInt32 || T == Int32 || T == Float32 %}
    value.unsafe_as(UInt32).to_u64
  {% else %}
    value.unsafe_as(UInt64)
  {% end %}
end

private def w31_numeric_width(type : T.class) : Int32 forall T
  {% if T == UInt8 || T == Int8 %}
    1
  {% elsif T == UInt16 || T == Int16 %}
    2
  {% elsif T == UInt32 || T == Int32 || T == Float32 %}
    4
  {% else %}
    8
  {% end %}
end

private def w31_nullable_bits(values : Array(Array(T?))) : Array(Array(UInt64?)) forall T
  values.map do |row|
    row.map do |value|
      value.nil? ? nil : w31_numeric_bits(value.not_nil!)
    end
  end
end

private def w31_assert_nested_equal(actual : Array(Array(T?)), expected : Array(Array(T?))) : Nil forall T
  w31_nullable_bits(actual).should eq(w31_nullable_bits(expected))
end

private def w31_append_little_endian(bytes : Array(UInt8), value : UInt64, width : Int32) : Nil
  width.times { |index| bytes << ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w31_size_bytes(values : Array(Array(T?))) : Array(UInt8) forall T
  bytes = [] of UInt8
  values.each { |row| w31_append_little_endian(bytes, row.size.to_u64, 8) }
  bytes
end

private def w31_null_bytes(values : Array(Array(T?))) : Array(UInt8) forall T
  values.flat_map { |row| row.map { |value| value.nil? ? 1_u8 : 0_u8 } }
end

private def w31_payload_bytes(values : Array(Array(T?)), type : T.class) : Array(UInt8) forall T
  bytes = [] of UInt8
  width = w31_numeric_width(type)
  values.each do |row|
    row.each do |value|
      w31_append_little_endian(bytes, value.nil? ? 0_u64 : w31_numeric_bits(value.not_nil!), width)
    end
  end
  bytes
end

private def w31_decode_stream(part_path : String, stream : String) : Array(UInt8)
  data_path = File.join(part_path, "#{CrystalClick::StreamName.hash(stream)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(data_path).to_slice).to_a
end

private def w31_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w31_mark_triples(part_path : String, stream : String) : Array({UInt64, UInt64, UInt64})
  raw = File.read(File.join(part_path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "W31 mark file is malformed" unless raw.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array({UInt64, UInt64, UInt64}).new(raw.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    base = index * CrystalClick::WidePart::MARK_SIZE
    {w31_u64(raw, base), w31_u64(raw, base + 8), w31_u64(raw, base + 16)}
  end
end

private def w31_copy_fixture_part(parent : String, name : String) : String
  root = File.join(parent, name)
  Dir.mkdir(root)
  part = File.join(root, "all_1_1_0")
  FileUtils.cp_r(W31_ARRAY_NULLABLE_NUMERIC_FIXTURE, part)
  part
end

private def w31_child_counts(type : T.class) : Array(UInt64) forall T
  {% if T == Float32 || T == Float64 %}
    [0_u64, 6_u64, 3_u64, 0_u64, 7_u64, 0_u64]
  {% else %}
    [0_u64, 3_u64, 3_u64, 0_u64, 5_u64, 0_u64]
  {% end %}
end

private def w31_prefix_offsets(counts : Array(UInt64), multiplier : UInt64 = 1_u64) : Array(UInt64)
  offsets = [0_u64]
  counts.each { |count| offsets << offsets.last + count * multiplier }
  offsets
end

private def w31_check_physical_streams(part_path : String, column : String, values : Array(Array(T?)), type : T.class, assert_stock_offsets : Bool = true) : Nil forall T
  width = w31_numeric_width(type)
  child_counts = w31_child_counts(type)
  w31_decode_stream(part_path, "#{column}.size0").should eq(w31_size_bytes(values))
  w31_decode_stream(part_path, "#{column}.null").should eq(w31_null_bytes(values))
  w31_decode_stream(part_path, column).should eq(w31_payload_bytes(values, type))

  expected_rows = [2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 1_u64, 0_u64]
  expected_size_offsets = [0_u64, 16_u64, 32_u64, 48_u64, 64_u64, 80_u64, 88_u64]
  size_marks = w31_mark_triples(part_path, "#{column}.size0")
  null_marks = w31_mark_triples(part_path, "#{column}.null")
  value_marks = w31_mark_triples(part_path, column)
  size_marks.map(&.[2]).should eq(expected_rows)
  null_marks.map(&.[2]).should eq(expected_rows)
  value_marks.map(&.[2]).should eq(expected_rows)
  if assert_stock_offsets
    size_marks.map(&.[1]).should eq(expected_size_offsets)
    null_marks.map(&.[1]).should eq(w31_prefix_offsets(child_counts))
    value_marks.map(&.[1]).should eq(w31_prefix_offsets(child_counts, width.to_u64))
  end
end

private def w31_check_reader_and_table(type : T.class, column : String) : Nil forall T
  expected = w31_expected_values(type)
  reader = CrystalClick::WidePart.open_typed(W31_ARRAY_NULLABLE_NUMERIC_FIXTURE, column)
  reader.column_type.should eq("Array(Nullable(#{CrystalClick::WidePart.numeric_type_name(type)}))")
  reader.row_count.should eq(11_u64)
  reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 1_u64])
  w31_assert_nested_equal(reader.read_array_nullable_numeric_mark_range(column, 0, reader.mark_count, type), expected)
  w31_assert_nested_equal(reader.read_array_nullable_numeric_mark_range(column, 2, 2, type), expected[4, 4])
  leaf_count = expected.sum(&.size).to_u64
  reader.array_nullable_numeric_mark_range_raw_bytes(column, 0, reader.mark_count).should eq(leaf_count * (w31_numeric_width(type) + 1).to_u64)
  w31_check_physical_streams(W31_ARRAY_NULLABLE_NUMERIC_FIXTURE, column, expected, type)

  table_root = File.tempname("crystal-click-w31-table-#{column}")
  Dir.mkdir(table_root)
  part_path = File.join(table_root, "all_1_1_0")
  begin
    FileUtils.cp_r(W31_ARRAY_NULLABLE_NUMERIC_FIXTURE, part_path)
    table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["pk", column])
    observed = [] of Array(T?)
    batches = [] of {Int32, UInt64, Int32}
    table.scan_typed(batch_rows: 4) do |batch|
      values = batch.array_nullable_numeric_values(column, type)
      observed.concat(values.map(&.dup))
      batches << {batch.mark_index, batch.part_row_offset, values.size.to_i32}
    end
    w31_assert_nested_equal(observed, expected)
    batches.should eq([
      {0_i32, 0_u64, 2_i32}, {1_i32, 2_u64, 2_i32}, {2_i32, 4_u64, 2_i32},
      {3_i32, 6_u64, 2_i32}, {4_i32, 8_u64, 2_i32}, {5_i32, 10_u64, 1_i32},
    ])
  ensure
    FileUtils.rm_rf(table_root)
  end
end

private def w31_check_writer(type : T.class, column : String) : Nil forall T
  values = w31_expected_values(type)
  keys = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64, 17_u64, 19_u64, 21_u64, 25_u64]
  parent = File.tempname("crystal-click-w31-writer-#{column}")
  Dir.mkdir(parent)
  part_path = File.join(parent, "part")
  begin
    CrystalClick::WidePartWriter.write_uint64_array_nullable_numeric_pair(
      part_path,
      "pk",
      keys.to_unsafe.to_slice(keys.size),
      "payload",
      values.to_unsafe.to_slice(values.size),
      rows_per_mark: 2
    )
    reader = CrystalClick::WidePart.open_typed(part_path, "payload")
    reader.column_type.should eq("Array(Nullable(#{CrystalClick::WidePart.numeric_type_name(type)}))")
    reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 1_u64])
    w31_assert_nested_equal(reader.read_array_nullable_numeric_mark_range("payload", 0, reader.mark_count, type), values)
    w31_assert_nested_equal(reader.read_array_nullable_numeric_mark_range("payload", 2, 2, type), values[4, 4])
    w31_check_physical_streams(part_path, "payload", values, type, false)
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def with_w31_catalog_root(&)
  root = File.tempname("crystal-click-w31-offline-catalog")
  Dir.mkdir(root)
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

private def w31_catalog_table_path(root : String) : String
  database_uuid = "5d2f15f0-2a1d-40e7-b859-6bb2517cb0aa"
  table_uuid = "68a6df12-431c-45dd-9b80-2348be96f833"
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(database_path)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  columns = String.build do |io|
    io << "    `pk` UInt64,\n"
    W31_ARRAY_NULLABLE_NUMERIC_COLUMNS.each_with_index do |(name, type), index|
      io << "    `" << name << "` Array(Nullable(" << type << "))"
      io << ",\n" unless index == W31_ARRAY_NULLABLE_NUMERIC_COLUMNS.size - 1
      io << "\n" if index == W31_ARRAY_NULLABLE_NUMERIC_COLUMNS.size - 1
    end
  end
  File.write(
    File.join(database_path, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n#{columns})\nENGINE = MergeTree\nORDER BY pk\n"
  )
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(W31_ARRAY_NULLABLE_NUMERIC_FIXTURE, File.join(table_path, "all_1_1_0"))
  table_path
end

private def w31_check_catalog(type : T.class, column : String) : Nil forall T
  expected = w31_expected_values(type)
  with_w31_catalog_root do |root|
    w31_catalog_table_path(root)
    table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
    values = table[column].values.map { |value| value.as(Array(T?)) }
    w31_assert_nested_equal(values, expected)
    values[2][1] = nil
    w31_assert_nested_equal(table[column].values.map { |value| value.as(Array(T?)) }, expected)
  end
end

private def w31_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w31_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w31_rewrite_first_frame_value(part_path : String, stream : String, raw_offset : Int, raw_width : Int, value : UInt64) : Nil
  data_path = File.join(part_path, "#{CrystalClick::StreamName.hash(stream)}.bin")
  encoded = File.read(data_path).to_slice
  frame = CrystalClick::CompressedBlock.decode_frame(encoded, 0_i64)
  raw = frame.output.dup
  case raw_width
  when 1
    raw[raw_offset] = value.to_u8
  when 8
    w31_write_u64(raw, raw_offset, value)
  else
    raise "unsupported W31 mutation width"
  end
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  rewritten = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  rewritten[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w31_write_u32(rewritten, header + 1, compressed_size.to_u32)
  w31_write_u32(rewritten, header + 5, raw.size.to_u32)
  cursor = CrystalClick::CompressedBlock::FRAME_HEADER_SIZE
  if raw.size < 15
    rewritten[cursor] = (raw.size << 4).to_u8
    cursor += 1
  else
    rewritten[cursor] = 0xf0_u8
    cursor += 1
    remaining = raw.size - 15
    while remaining >= 255
      rewritten[cursor] = 255_u8
      cursor += 1
      remaining -= 255
    end
    rewritten[cursor] = remaining.to_u8
    cursor += 1
  end
  raw.copy_to(rewritten.to_unsafe + cursor, raw.size)
  hash = CrystalClick::CityHashV1.hash128(rewritten[header, compressed_size])
  w31_write_u64(rewritten, 0, hash[0])
  w31_write_u64(rewritten, 8, hash[1])
  old_frame_end = frame.end_offset.to_i
  delta = rewritten.size - old_frame_end
  result = Bytes.new(encoded.size + delta)
  rewritten.copy_to(result.to_unsafe, rewritten.size)
  encoded[old_frame_end, encoded.size - old_frame_end].copy_to(result.to_unsafe + rewritten.size, encoded.size - old_frame_end)
  File.write(data_path, result)

  marks_path = File.join(part_path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  raise "W31 mark file is malformed" unless marks.size % CrystalClick::WidePart::MARK_SIZE == 0
  (0...marks.size).step(CrystalClick::WidePart::MARK_SIZE) do |offset|
    compressed_offset = w31_u64(marks, offset)
    if compressed_offset >= old_frame_end.to_u64
      w31_write_u64(marks, offset, (compressed_offset.to_i64 + delta).to_u64)
    end
  end
  File.write(marks_path, marks)
end

private def w31_write_mark_offset(part_path : String, stream : String, record_index : Int, value : UInt64) : Nil
  path = File.join(part_path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(path).to_slice.dup
  offset = record_index * CrystalClick::WidePart::MARK_SIZE + 8
  w31_write_u64(marks, offset, value)
  File.write(path, marks)
end

private def w31_expect_rejected_before_callback(type : T.class, part_path : String, column : String, mark_index : Int32) : Nil forall T
  callbacks = 0
  expect_raises(CrystalClick::CorruptPartError) do
    table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["pk", column])
    table.scan_typed_candidate_marks([[mark_index]]) do |batch|
      callbacks += 1
      batch.array_nullable_numeric_values(column, type)
    end
  end
  callbacks.should eq(0)
end

describe CrystalClick::WidePart do
  it "admits exactly one-level Array(Nullable(T)) for W30 numeric leaves" do
    [
      "Array(Nullable(UInt8))", "Array(Nullable(UInt16))", "Array(Nullable(UInt32))", "Array(Nullable(UInt64))",
      "Array(Nullable(Int8))", "Array(Nullable(Int16))", "Array(Nullable(Int32))", "Array(Nullable(Int64))",
      "Array(Nullable(Float32))", "Array(Nullable(Float64))", "Array(Array(Nullable(UInt64)))",
    ].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_true
    end

    [
      "Array(Nullable(Decimal(75, 0)))", "Array(Nullable(Decimal(38, 39)))",
      "Array(Nullable(Nullable(UInt64)))", "Array(Array(Nullable(Bool)))", "Nullable(Array(UInt64))",
      "Array(Nullable(UInt64) trailing)", "Array(Nullable(UInt64)) trailing",
    ].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "rejects empty array-serializer metadata outside the exact W31 eleven-column shape" do
    parent = File.tempname("crystal-click-w31-mixed-schema")
    Dir.mkdir(parent)
    begin
      mixed = w31_copy_fixture_part(parent, "mixed-schema")
      columns_path = File.join(mixed, "columns.txt")
      original = File.read(columns_path)
      mutated = original.sub("`arr_f64` Array(Nullable(Float64))", "`arr_f64` Array(Nullable(UInt16))")
      mutated.should_not eq(original)
      File.write(columns_path, mutated)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(mixed, "arr_u8")
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "reads stock nullable child streams by outer-row marks for all ten numeric widths" do
    w31_check_reader_and_table(UInt8, "arr_u8")
    w31_check_reader_and_table(UInt16, "arr_u16")
    w31_check_reader_and_table(UInt32, "arr_u32")
    w31_check_reader_and_table(UInt64, "arr_u64")
    w31_check_reader_and_table(Int8, "arr_i8")
    w31_check_reader_and_table(Int16, "arr_i16")
    w31_check_reader_and_table(Int32, "arr_i32")
    w31_check_reader_and_table(Int64, "arr_i64")
    w31_check_reader_and_table(Float32, "arr_f32")
    w31_check_reader_and_table(Float64, "arr_f64")
  end

  it "writes exact null, size, and payload streams for all ten nullable numeric widths" do
    w31_check_writer(UInt8, "arr_u8")
    w31_check_writer(UInt16, "arr_u16")
    w31_check_writer(UInt32, "arr_u32")
    w31_check_writer(UInt64, "arr_u64")
    w31_check_writer(Int8, "arr_i8")
    w31_check_writer(Int16, "arr_i16")
    w31_check_writer(Int32, "arr_i32")
    w31_check_writer(Int64, "arr_i64")
    w31_check_writer(Float32, "arr_f32")
    w31_check_writer(Float64, "arr_f64")
  end

  it "materializes nullable numeric arrays through OfflineCatalog without aliasing" do
    w31_check_catalog(UInt8, "arr_u8")
    w31_check_catalog(UInt16, "arr_u16")
    w31_check_catalog(UInt32, "arr_u32")
    w31_check_catalog(UInt64, "arr_u64")
    w31_check_catalog(Int8, "arr_i8")
    w31_check_catalog(Int16, "arr_i16")
    w31_check_catalog(Int32, "arr_i32")
    w31_check_catalog(Int64, "arr_i64")
    w31_check_catalog(Float32, "arr_f32")
    w31_check_catalog(Float64, "arr_f64")
  end

  it "rejects malformed null maps, shifted child marks, width mismatches, and oversized counts before callbacks" do
    parent = File.tempname("crystal-click-w31-corrupt")
    Dir.mkdir(parent)
    begin
      bad_null = w31_copy_fixture_part(parent, "bad-null-map")
      w31_rewrite_first_frame_value(bad_null, "arr_u8.null", 0, 1, 2_u64)
      bad_null_reader = CrystalClick::WidePart.open_typed(bad_null, "arr_u8")
      null_error = expect_raises(CrystalClick::CorruptPartError) do
        bad_null_reader.read_array_nullable_numeric_mark_range("arr_u8", 1, 1, UInt8)
      end
      (null_error.message || "").should contain("Array(Nullable(T)) null map contains a value other than 0 or 1")
      w31_expect_rejected_before_callback(UInt8, bad_null, "arr_u8", 1_i32)

      shifted = w31_copy_fixture_part(parent, "shifted-child-mark")
      child_marks = w31_mark_triples(shifted, "arr_u16.null")
      child_marks[2][1].should eq(3_u64)
      child_marks[3][1].should eq(6_u64)
      w31_write_mark_offset(shifted, "arr_u16.null", 2, 4_u64)
      w31_write_mark_offset(shifted, "arr_u16.null", 3, 5_u64)
      shifted_reader = CrystalClick::WidePart.open_typed(shifted, "arr_u16")
      shifted_error = expect_raises(CrystalClick::CorruptPartError) do
        shifted_reader.array_nullable_numeric_mark_range_raw_bytes("arr_u16", 2, 1)
      end
      (shifted_error.message || "").should contain("mark range byte count mismatch")
      w31_expect_rejected_before_callback(UInt16, shifted, "arr_u16", 2_i32)

      bad_width = w31_copy_fixture_part(parent, "bad-width")
      value_marks = w31_mark_triples(bad_width, "arr_u16")
      value_marks.last[1].should eq(22_u64)
      w31_write_mark_offset(bad_width, "arr_u16", 6, 23_u64)
      width_error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(bad_width, "arr_u16")
      end
      (width_error.message || "").should contain("mark decompressed offset is not column-type-aligned")
      w31_expect_rejected_before_callback(UInt16, bad_width, "arr_u16", 0_i32)

      oversized = w31_copy_fixture_part(parent, "oversized-count")
      w31_rewrite_first_frame_value(oversized, "arr_u8.size0", 0, 8, UInt64::MAX)
      oversized_reader = CrystalClick::WidePart.open_typed(oversized, "arr_u8")
      oversized_error = expect_raises(CrystalClick::CorruptPartError) do
        oversized_reader.array_nullable_numeric_mark_range_raw_bytes("arr_u8", 0, 1)
      end
      (oversized_error.message || "").should contain("Array nested element count exceeds per-range limit")
      w31_expect_rejected_before_callback(UInt8, oversized, "arr_u8", 0_i32)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
