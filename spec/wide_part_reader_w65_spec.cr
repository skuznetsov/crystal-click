require "./spec_helper"

private def w65r_values(type : T.class) : Array(Array(Array(T))) forall T
  rows = [] of Array(Array(T))
  {% if T == UInt16 %}
    rows << [] of Array(T)
    rows << [[] of T]
    rows << [[0_u16, UInt16::MAX] of T]
    rows << [[] of T]
    rows << [[1_u16] of T, [] of T]
    rows << [] of Array(T)
    rows << [[UInt16::MAX] of T]
  {% elsif T == Int32 %}
    rows << [] of Array(T)
    rows << [[] of T]
    rows << [[Int32::MIN, Int32::MAX] of T]
    rows << [[] of T]
    rows << [[-1_i32] of T, [] of T]
    rows << [] of Array(T)
    rows << [[Int32::MAX] of T]
  {% elsif T == UInt32 %}
    rows << [] of Array(T)
    rows << [[] of T]
    rows << [[0_u32, UInt32::MAX] of T]
    rows << [[] of T]
    rows << [[1_u32] of T, [] of T]
    rows << [] of Array(T)
    rows << [[UInt32::MAX] of T]
  {% elsif T == Int64 %}
    rows << [] of Array(T)
    rows << [[] of T]
    rows << [[Int64::MIN, Int64::MAX] of T]
    rows << [[] of T]
    rows << [[-1_i64] of T, [] of T]
    rows << [] of Array(T)
    rows << [[Int64::MAX] of T]
  {% else %}
    {% raise "unsupported W65 reader test type" %}
  {% end %}
  rows
end

private def w65r_nullable_values(type : T.class) : Array(Array(Array(T?))) forall T
  rows = [] of Array(Array(T?))
  {% if T == UInt16 %}
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, nil] of T?]
    rows << [[nil] of T?, [nil, nil] of T?]
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[UInt16::MAX, 0_u16, nil] of T?]
  {% elsif T == Int32 %}
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, nil] of T?]
    rows << [[nil] of T?, [nil, nil] of T?]
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[Int32::MAX, 0_i32, nil] of T?]
  {% elsif T == UInt32 %}
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, nil] of T?]
    rows << [[nil] of T?, [nil, nil] of T?]
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[UInt32::MAX, 0_u32, nil] of T?]
  {% elsif T == Int64 %}
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, nil] of T?]
    rows << [[nil] of T?, [nil, nil] of T?]
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[Int64::MAX, 0_i64, nil] of T?]
  {% else %}
    {% raise "unsupported W65 nullable reader test type" %}
  {% end %}
  rows
end

private def w65r_write_plain(part : String, values : Array(Array(Array(T))), scale : Int32) : Nil forall T
  keys = (1_u64..values.size.to_u64).to_a
  {% if T == UInt16 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_date_pair(part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", values.to_unsafe.to_slice(values.size), rows_per_mark: 2)
  {% elsif T == Int32 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_date32_pair(part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", values.to_unsafe.to_slice(values.size), rows_per_mark: 2)
  {% elsif T == UInt32 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_datetime_pair(part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", values.to_unsafe.to_slice(values.size), rows_per_mark: 2)
  {% elsif T == Int64 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_datetime64_pair(part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", values.to_unsafe.to_slice(values.size), scale, rows_per_mark: 2)
  {% else %}
    {% raise "unsupported W65 writer test type" %}
  {% end %}
  nil
end

private def w65r_write_nullable(part : String, values : Array(Array(Array(T?))), scale : Int32) : Nil forall T
  keys = (1_u64..values.size.to_u64).to_a
  {% if T == UInt16 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_date_pair(part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", values.to_unsafe.to_slice(values.size), rows_per_mark: 2)
  {% elsif T == Int32 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_date32_pair(part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", values.to_unsafe.to_slice(values.size), rows_per_mark: 2)
  {% elsif T == UInt32 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_datetime_pair(part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", values.to_unsafe.to_slice(values.size), rows_per_mark: 2)
  {% elsif T == Int64 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_datetime64_pair(part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", values.to_unsafe.to_slice(values.size), scale, rows_per_mark: 2)
  {% else %}
    {% raise "unsupported W65 nullable writer test type" %}
  {% end %}
  nil
end

private def w65r_read_plain(reader : CrystalClick::WidePart, type : T.class) : Array(Array(Array(T))) forall T
  {% if T == UInt16 %}
    reader.read_array_array_date_codes_mark_range("payload", 0, reader.mark_count)
  {% elsif T == Int32 %}
    reader.read_array_array_date32_codes_mark_range("payload", 0, reader.mark_count)
  {% elsif T == UInt32 %}
    reader.read_array_array_datetime_seconds_mark_range("payload", 0, reader.mark_count)
  {% elsif T == Int64 %}
    reader.read_array_array_datetime64_ticks_mark_range("payload", 0, reader.mark_count)
  {% else %}
    {% raise "unsupported W65 reader type" %}
  {% end %}
end

private def w65r_read_nullable(reader : CrystalClick::WidePart, type : T.class) : Array(Array(Array(T?))) forall T
  {% if T == UInt16 %}
    reader.read_array_array_nullable_date_codes_mark_range("payload", 0, reader.mark_count)
  {% elsif T == Int32 %}
    reader.read_array_array_nullable_date32_codes_mark_range("payload", 0, reader.mark_count)
  {% elsif T == UInt32 %}
    reader.read_array_array_nullable_datetime_seconds_mark_range("payload", 0, reader.mark_count)
  {% elsif T == Int64 %}
    reader.read_array_array_nullable_datetime64_ticks_mark_range("payload", 0, reader.mark_count)
  {% else %}
    {% raise "unsupported W65 nullable reader type" %}
  {% end %}
end

private def w65r_read_batch_plain(batch : CrystalClick::WidePartTableBatch, type : T.class) : Slice(Array(Array(T))) forall T
  {% if T == UInt16 %}
    batch.array_array_date_codes_for("payload")
  {% elsif T == Int32 %}
    batch.array_array_date32_codes_for("payload")
  {% elsif T == UInt32 %}
    batch.array_array_datetime_seconds_for("payload")
  {% elsif T == Int64 %}
    batch.array_array_datetime64_ticks_for("payload")
  {% else %}
    {% raise "unsupported W65 table type" %}
  {% end %}
end

private def w65r_read_batch_nullable(batch : CrystalClick::WidePartTableBatch, type : T.class) : Slice(Array(Array(T?))) forall T
  {% if T == UInt16 %}
    batch.array_array_nullable_date_codes_for("payload")
  {% elsif T == Int32 %}
    batch.array_array_nullable_date32_codes_for("payload")
  {% elsif T == UInt32 %}
    batch.array_array_nullable_datetime_seconds_for("payload")
  {% elsif T == Int64 %}
    batch.array_array_nullable_datetime64_ticks_for("payload")
  {% else %}
    {% raise "unsupported W65 nullable table type" %}
  {% end %}
end

private def w65r_catalog_table(root : String, part : String, type : String) : CrystalClick::OfflineTable
  database_uuid = "39fb5af3-33d7-4270-97c6-7a05027c9aa8"
  table_uuid = "acf5fcb3-6448-49b0-91c6-c647bce9ce05"
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  File.write(File.join(root, "metadata", "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  database_path = File.join(root, "store", database_uuid[0, 3], database_uuid)
  FileUtils.mkdir_p(database_path)
  File.write(File.join(database_path, "events.sql"), "ATTACH TABLE _ UUID '#{table_uuid}'\n(`pk` UInt64, `payload` #{type})\nENGINE = MergeTree\nORDER BY pk\n")
  table_path = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(table_path)
  File.write(File.join(table_path, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_path, "detached"))
  FileUtils.cp_r(part, File.join(table_path, File.basename(part)))
  CrystalClick::OfflineCatalog.open(root).table("lab", "events")
end

private def w65r_catalog_plain(table : CrystalClick::OfflineTable, type : T.class) : Array(Array(Array(T))) forall T
  table["payload"].values.map { |value| value.as(Array(Array(T))) }
end

private def w65r_catalog_nullable(table : CrystalClick::OfflineTable, type : T.class) : Array(Array(Array(T?))) forall T
  table["payload"].values.map { |value| value.as(Array(Array(T?))) }
end

private def w65r_check_pair(type : T.class, leaf_name : String, scale : Int32 = 3) : Nil forall T
  parent = File.tempname("crystal-click-reader-w65")
  Dir.mkdir(parent)
  plain_part = File.join(parent, "all_1_7_0")
  nullable_dir = File.join(parent, "nullable")
  Dir.mkdir(nullable_dir)
  nullable_part = File.join(nullable_dir, "all_1_7_0")
  plain_values = w65r_values(T)
  nullable_values = w65r_nullable_values(T)
  leaf = leaf_name == "DateTime64" ? "DateTime64(#{scale})" : leaf_name
  plain_type = "Array(Array(#{leaf}))"
  nullable_type = "Array(Array(Nullable(#{leaf})))"

  begin
    w65r_write_plain(plain_part, plain_values, scale)
    w65r_write_nullable(nullable_part, nullable_values, scale)
    plain = CrystalClick::WidePart.open_typed(plain_part, "payload")
    nullable = CrystalClick::WidePart.open_typed(nullable_part, "payload")
    plain.column_type.should eq(plain_type)
    nullable.column_type.should eq(nullable_type)
    plain.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    nullable.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    w65r_read_plain(plain, T).should eq(plain_values)
    w65r_read_nullable(nullable, T).should eq(nullable_values)

    selected_plain = CrystalClick::WidePartTable.open_selected_typed([plain_part], ["payload"])
    plain_batches = [] of Array(Array(T))
    selected_plain.scan_typed(batch_rows: 1) do |batch|
      plain_batches.concat(w65r_read_batch_plain(batch, T))
      expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_array_numeric_values("payload", T) }
    end
    plain_batches.should eq(plain_values)

    selected_nullable = CrystalClick::WidePartTable.open_selected_typed([nullable_part], ["payload"])
    nullable_batches = [] of Array(Array(T?))
    selected_nullable.scan_typed(batch_rows: 1) do |batch|
      nullable_batches.concat(w65r_read_batch_nullable(batch, T))
      expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_array_nullable_numeric_values("payload", T) }
    end
    nullable_batches.should eq(nullable_values)

    plain_table = w65r_catalog_table(File.join(parent, "catalog-plain"), plain_part, plain_type)
    nullable_table = w65r_catalog_table(File.join(parent, "catalog-nullable"), nullable_part, nullable_type)
    w65r_catalog_plain(plain_table, T).should eq(plain_values)
    w65r_catalog_nullable(nullable_table, T).should eq(nullable_values)
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w65r_shift_mark_decompressed_offset(part : String, stream : String, mark_index : Int, delta : UInt64) : Nil
  marks_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE + 8
  value = 0_u64
  8.times { |index| value |= marks[offset + index].to_u64 << (index * 8) }
  8.times { |index| marks[offset + index] = (((value + delta) >> (index * 8)) & 0xff_u64).to_u8 }
  File.write(marks_path, marks)
end

private def w65r_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w65r_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

# Rebuild the first literal-LZ4 frame after changing a leaf slot hidden by a
# NULL bit; this proves the nullable decoder consumes the bytes but ignores
# their scalar meaning.
private def w65r_reseal_first_frame_bytes(part : String, stream : String, raw_offset : Int, poison : Array(UInt8)) : Nil
  data_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  encoded = File.read(data_path).to_slice
  frame = CrystalClick::CompressedBlock.decode_frame(encoded, 0_i64)
  raw = frame.output.dup
  raise "poison range exceeds first #{stream} frame" if raw_offset < 0 || raw_offset + poison.size > raw.size
  poison.each_with_index { |byte, index| raw[raw_offset + index] = byte }

  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  rewritten = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  rewritten[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w65r_write_u32(rewritten, header + 1, compressed_size.to_u32)
  w65r_write_u32(rewritten, header + 5, raw.size.to_u32)
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
  w65r_write_u64(rewritten, 0, hash[0])
  w65r_write_u64(rewritten, 8, hash[1])

  old_frame_end = frame.end_offset.to_i
  delta = rewritten.size - old_frame_end
  result = Bytes.new(encoded.size + delta)
  rewritten.copy_to(result.to_unsafe, rewritten.size)
  encoded[old_frame_end, encoded.size - old_frame_end].copy_to(result.to_unsafe + rewritten.size, encoded.size - old_frame_end)
  File.write(data_path, result)

  marks_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  (0...marks.size).step(CrystalClick::WidePart::MARK_SIZE) do |offset|
    mark_offset = 0_u64
    8.times { |byte| mark_offset |= marks[offset + byte].to_u64 << (byte * 8) }
    if mark_offset >= old_frame_end.to_u64
      w65r_write_u64(marks, offset, (mark_offset.to_i64 + delta).to_u64)
    end
  end
  File.write(marks_path, marks)
end

describe CrystalClick::WidePart do
  it "admits only exact two-level temporal declarations and canonical DateTime64 scales" do
    {"Date", "Date32", "DateTime"}.each do |leaf|
      CrystalClick::WidePart.supports_typed_type?("Array(Array(#{leaf}))").should be_true
      CrystalClick::WidePart.supports_typed_type?("Array(Array(Nullable(#{leaf})))").should be_true
    end
    {0, 3, 9}.each do |scale|
      CrystalClick::WidePart.supports_typed_type?("Array(Array(DateTime64(#{scale})))").should be_true
      CrystalClick::WidePart.supports_typed_type?("Array(Array(Nullable(DateTime64(#{scale}))))").should be_true
    end
    {
      "Array(Array(DateTime64(01)))",
      "Array(Array(DateTime64(10)))",
      "Array(Array(DateTime('UTC')))",
      "Array(Array(DateTime64(3, 'UTC')))",
      "Array(Array(Array(Date)))",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "reads plain and nullable temporal leaves across raw widths, empty arrays, NULLs, and DateTime64 scales" do
    w65r_check_pair(UInt16, "Date")
    w65r_check_pair(Int32, "Date32")
    w65r_check_pair(UInt32, "DateTime")
    {0, 3, 9}.each { |scale| w65r_check_pair(Int64, "DateTime64", scale) }
  end

  it "rejects shifted selected later-mark boundaries before any callback" do
    values = w65r_nullable_values(UInt32)
    parent = File.tempname("crystal-click-reader-w65-boundary")
    Dir.mkdir(parent)
    source = File.join(parent, "source")
    begin
      w65r_write_nullable(source, values, 3)
      {"payload.size0", "payload.size1", "payload.null", "payload"}.each_with_index do |stream, index|
        copy_root = File.join(parent, "corrupt-#{index}")
        FileUtils.mkdir_p(copy_root)
        copy = File.join(copy_root, "all_1_7_0")
        FileUtils.cp_r(source, copy)
        delta = stream == "payload.null" ? 1_u64 : (stream == "payload" ? 4_u64 : 8_u64)
        # Mark 1 is the all-NULL middle mark, with enough later-stream bytes
        # that an aligned shift survives metadata parsing and reaches preflight.
        w65r_shift_mark_decompressed_offset(copy, stream, 1, delta)
        selected = CrystalClick::WidePartTable.open_selected_typed([copy], ["payload"])
        callbacks = 0
        expect_raises(CrystalClick::CorruptPartError) do
          selected.scan_typed_candidate_marks([[1]]) { |_batch| callbacks += 1 }
        end
        callbacks.should eq(0)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "consumes but ignores nonzero temporal child bytes underneath NULL" do
    parent = File.tempname("crystal-click-reader-w65-null-hidden")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_4_0")
    rows = [
      [[nil] of UInt16?],
      [[0_u16] of UInt16?],
      [] of Array(UInt16?),
      [[] of UInt16?],
    ] of Array(Array(UInt16?))
    begin
      w65r_write_nullable(part, rows, 3)
      w65r_reseal_first_frame_bytes(part, "payload", 0, [0x42_u8, 0xff_u8])
      reader = CrystalClick::WidePart.open_typed(part, "payload")
      reader.read_array_array_nullable_date_codes_mark_range("payload", 0, reader.mark_count).should eq(rows)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
