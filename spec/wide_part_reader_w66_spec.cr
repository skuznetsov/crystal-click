require "./spec_helper"

private def w66r_values(type : T.class, scale : Int32) : Array(Array(Array(T))) forall T
  rows = [] of Array(Array(T))
  {% if T == Int32 %}
    rows << [] of Array(T)
    rows << [[] of T]
    rows << [[-3_599_999_i32, -1_i32, 0_i32, 1_i32, 3_599_999_i32] of T]
    rows << [[-3_600_000_i32] of T, [] of T]
    rows << [] of Array(T)
    rows << [[] of T]
    rows << [[999_i32] of T]
  {% elsif T == Int64 %}
    scale_factor = 1_i64
    scale.times { scale_factor *= 10_i64 }
    limit = 3_599_999_i64 * scale_factor
    rows << [] of Array(T)
    rows << [[] of T]
    rows << [[-limit, -1_234_i64, 0_i64, 1_i64, limit] of T]
    rows << [[-limit + 1_i64] of T, [] of T]
    rows << [] of Array(T)
    rows << [[] of T]
    rows << [[999_i64 * scale_factor] of T]
  {% else %}
    {% raise "unsupported W66 reader test type" %}
  {% end %}
  rows
end

private def w66r_nullable_values(type : T.class, scale : Int32) : Array(Array(Array(T?))) forall T
  rows = [] of Array(Array(T?))
  {% if T == Int32 %}
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, nil] of T?, [] of T?]
    rows << [[nil] of T?, [nil, nil] of T?]
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, -1_i32, 0_i32, 1_i32] of T?]
  {% elsif T == Int64 %}
    scale_factor = 1_i64
    scale.times { scale_factor *= 10_i64 }
    limit = 3_599_999_i64 * scale_factor
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, nil] of T?, [] of T?]
    rows << [[nil] of T?, [nil, nil] of T?]
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, -1_234_i64, 0_i64, 1_i64, limit] of T?]
  {% else %}
    {% raise "unsupported W66 nullable reader test type" %}
  {% end %}
  rows
end

private def w66r_write_plain(part : String, values : Array(Array(Array(T))), scale : Int32) : Nil forall T
  keys = (1_u64..values.size.to_u64).to_a
  {% if T == Int32 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_time_pair(part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", values.to_unsafe.to_slice(values.size), 2)
  {% elsif T == Int64 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_time64_pair(part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", values.to_unsafe.to_slice(values.size), scale, 2)
  {% else %}
    {% raise "unsupported W66 writer test type" %}
  {% end %}
end

private def w66r_write_nullable(part : String, values : Array(Array(Array(T?))), scale : Int32) : Nil forall T
  keys = (1_u64..values.size.to_u64).to_a
  {% if T == Int32 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_time_pair(part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", values.to_unsafe.to_slice(values.size), 2)
  {% elsif T == Int64 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_time64_pair(part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", values.to_unsafe.to_slice(values.size), scale, 2)
  {% else %}
    {% raise "unsupported W66 nullable writer test type" %}
  {% end %}
end

private def w66r_read_plain(reader : CrystalClick::WidePart, type : T.class) : Array(Array(Array(T))) forall T
  {% if T == Int32 %}
    reader.read_array_array_time_seconds_mark_range("payload", 0, reader.mark_count)
  {% elsif T == Int64 %}
    reader.read_array_array_time64_ticks_mark_range("payload", 0, reader.mark_count)
  {% else %}
    {% raise "unsupported W66 reader test type" %}
  {% end %}
end

private def w66r_read_nullable(reader : CrystalClick::WidePart, type : T.class) : Array(Array(Array(T?))) forall T
  {% if T == Int32 %}
    reader.read_array_array_nullable_time_seconds_mark_range("payload", 0, reader.mark_count)
  {% elsif T == Int64 %}
    reader.read_array_array_nullable_time64_ticks_mark_range("payload", 0, reader.mark_count)
  {% else %}
    {% raise "unsupported W66 nullable reader test type" %}
  {% end %}
end

private def w66r_batch_plain(batch : CrystalClick::WidePartTableBatch, type : T.class) : Slice(Array(Array(T))) forall T
  {% if T == Int32 %}
    batch.array_array_time_seconds_for("payload")
  {% elsif T == Int64 %}
    batch.array_array_time64_ticks_for("payload")
  {% else %}
    {% raise "unsupported W66 table test type" %}
  {% end %}
end

private def w66r_batch_nullable(batch : CrystalClick::WidePartTableBatch, type : T.class) : Slice(Array(Array(T?))) forall T
  {% if T == Int32 %}
    batch.array_array_nullable_time_seconds_for("payload")
  {% elsif T == Int64 %}
    batch.array_array_nullable_time64_ticks_for("payload")
  {% else %}
    {% raise "unsupported W66 nullable table test type" %}
  {% end %}
end

private def w66r_catalog_table(root : String, part : String, type : String) : CrystalClick::OfflineTable
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

private def w66r_check_pair(type : T.class, scale : Int32 = 0) : Nil forall T
  parent = File.tempname("crystal-click-reader-w66")
  Dir.mkdir(parent)
  plain_part = File.join(parent, "plain", "all_1_7_0")
  nullable_part = File.join(parent, "nullable", "all_1_7_0")
  Dir.mkdir(File.dirname(plain_part))
  Dir.mkdir(File.dirname(nullable_part))
  plain_values = w66r_values(T, scale)
  nullable_values = w66r_nullable_values(T, scale)
  leaf = {% if T == Int32 %} "Time" {% else %} "Time64(#{scale})" {% end %}
  plain_type = "Array(Array(#{leaf}))"
  nullable_type = "Array(Array(Nullable(#{leaf})))"

  begin
    w66r_write_plain(plain_part, plain_values, scale)
    w66r_write_nullable(nullable_part, nullable_values, scale)
    plain = CrystalClick::WidePart.open_typed(plain_part, "payload")
    nullable = CrystalClick::WidePart.open_typed(nullable_part, "payload")
    plain.column_type.should eq(plain_type)
    nullable.column_type.should eq(nullable_type)
    plain.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    nullable.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    w66r_read_plain(plain, T).should eq(plain_values)
    w66r_read_nullable(nullable, T).should eq(nullable_values)
    expect_raises(CrystalClick::UnsupportedFormatError) { plain.read_array_array_numeric_mark_range("payload", 0, 1, T) }
    expect_raises(CrystalClick::UnsupportedFormatError) { plain.read_array_array_numeric_mark_range("payload", 1, 1, T) }
    expect_raises(CrystalClick::UnsupportedFormatError) { nullable.read_array_array_nullable_numeric_mark_range("payload", 1, 1, T) }
    {% if T == Int32 %}
      expect_raises(CrystalClick::UnsupportedFormatError) { plain.read_array_array_date32_codes_mark_range("payload", 0, 1) }
      expect_raises(CrystalClick::UnsupportedFormatError) { plain.read_array_array_datetime_seconds_mark_range("payload", 0, 1) }
      expect_raises(CrystalClick::UnsupportedFormatError) { nullable.read_array_array_nullable_date32_codes_mark_range("payload", 0, 1) }
      expect_raises(CrystalClick::UnsupportedFormatError) { nullable.read_array_array_nullable_datetime_seconds_mark_range("payload", 0, 1) }
    {% elsif T == Int64 %}
      expect_raises(CrystalClick::UnsupportedFormatError) { plain.read_array_array_datetime64_ticks_mark_range("payload", 0, 1) }
      expect_raises(CrystalClick::UnsupportedFormatError) { nullable.read_array_array_nullable_datetime64_ticks_mark_range("payload", 0, 1) }
    {% end %}

    selected_plain = CrystalClick::WidePartTable.open_selected_typed([plain_part], ["payload"])
    plain_batches = [] of Array(Array(T))
    selected_plain.scan_typed(batch_rows: 1) do |batch|
      plain_batches.concat(w66r_batch_plain(batch, T))
      expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_array_numeric_values("payload", T) }
      {% if T == Int32 %}
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_array_date32_codes_for("payload") }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_array_datetime_seconds_for("payload") }
      {% elsif T == Int64 %}
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_array_datetime64_ticks_for("payload") }
      {% end %}
    end
    plain_batches.should eq(plain_values)

    selected_nullable = CrystalClick::WidePartTable.open_selected_typed([nullable_part], ["payload"])
    nullable_batches = [] of Array(Array(T?))
    selected_nullable.scan_typed(batch_rows: 1) do |batch|
      nullable_batches.concat(w66r_batch_nullable(batch, T))
      expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_array_nullable_numeric_values("payload", T) }
      {% if T == Int32 %}
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_array_nullable_date32_codes_for("payload") }
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_array_nullable_datetime_seconds_for("payload") }
      {% elsif T == Int64 %}
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_array_nullable_datetime64_ticks_for("payload") }
      {% end %}
    end
    nullable_batches.should eq(nullable_values)

    plain_catalog = w66r_catalog_table(File.join(parent, "catalog-plain"), plain_part, plain_type)
    nullable_catalog = w66r_catalog_table(File.join(parent, "catalog-nullable"), nullable_part, nullable_type)
    plain_catalog["payload"].values.map { |value| value.as(Array(Array(T))) }.should eq(plain_values)
    nullable_catalog["payload"].values.map { |value| value.as(Array(Array(T?))) }.should eq(nullable_values)
  ensure
    FileUtils.rm_rf(parent.not_nil!)
  end
end

private def w66r_shift_mark_offset(part : String, stream : String, mark_index : Int, delta : UInt64) : Nil
  marks_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE + 8
  value = 0_u64
  8.times { |index| value |= marks[offset + index].to_u64 << (index * 8) }
  8.times { |index| marks[offset + index] = (((value + delta) >> (index * 8)) & 0xff_u64).to_u8 }
  File.write(marks_path, marks)
end

private def w66r_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w66r_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w66r_reseal_frame_bytes(part : String, stream : String, raw_offset : Int, poison : Array(UInt8)) : Nil
  data_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  encoded = File.read(data_path).to_slice
  frame = CrystalClick::CompressedBlock.decode_frame(encoded, 0_i64)
  raw = frame.output.dup
  raise "poison range exceeds first frame" if raw_offset < 0 || raw_offset + poison.size > raw.size
  poison.each_with_index { |byte, index| raw[raw_offset + index] = byte }

  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  rewritten = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  rewritten[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w66r_write_u32(rewritten, header + 1, compressed_size.to_u32)
  w66r_write_u32(rewritten, header + 5, raw.size.to_u32)
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
  w66r_write_u64(rewritten, 0, hash[0])
  w66r_write_u64(rewritten, 8, hash[1])

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
      w66r_write_u64(marks, offset, (mark_offset.to_i64 + delta).to_u64)
    end
  end
  File.write(marks_path, marks)
end

describe CrystalClick::WidePart do
  it "admits only canonical two-level Time and Time64 leaves" do
    {
      "Array(Array(Time))",
      "Array(Array(Nullable(Time)))",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_true
    end
    (0..9).each do |scale|
      CrystalClick::WidePart.supports_typed_type?("Array(Array(Time64(#{scale})))").should be_true
      CrystalClick::WidePart.supports_typed_type?("Array(Array(Nullable(Time64(#{scale}))))").should be_true
    end
    {
      "Array(Array(Time64))",
      "Array(Array(Time64(03)))",
      "Array(Array(Time64(10)))",
      "Array(Array(Time64(3, 'UTC')))",
      "Array(Array(Nullable(Nullable(Time))))",
      "Array(Array(Time64(Nullable(Int64))))",
      "Nullable(Array(Array(Time)))",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "reads plain and nullable Time raw seconds and Time64 ticks through batches and catalog projection" do
    w66r_check_pair(Int32)
    {0, 3, 9}.each { |scale| w66r_check_pair(Int64, scale) }
  end

  it "rejects shifted selected later-mark offsets before callback and ignores hidden nullable child bytes" do
    parent = File.tempname("crystal-click-reader-w66-corrupt")
    Dir.mkdir(parent)
    source = File.join(parent, "source")
    values = w66r_nullable_values(Int64, 3)
    begin
      w66r_write_nullable(source, values, 3)
      {"payload.size0" => 8_u64, "payload.size1" => 8_u64, "payload.null" => 1_u64, "payload" => 8_u64}.each do |stream, delta|
        copy_root = File.join(parent, "corrupt-#{stream.tr(".", "-")}")
        FileUtils.mkdir_p(copy_root)
        copy = File.join(copy_root, "all_1_7_0")
        FileUtils.cp_r(source, copy)
        w66r_shift_mark_offset(copy, stream, 1, delta)
        selected = CrystalClick::WidePartTable.open_selected_typed([copy], ["payload"])
        callbacks = 0
        expect_raises(CrystalClick::CorruptPartError) do
          selected.scan_typed_candidate_marks([[1]]) { |_batch| callbacks += 1 }
        end
        callbacks.should eq(0)
      end

      hidden = File.join(parent, "hidden")
      w66r_write_nullable(hidden, values, 3)
      # Row 2 (the first row of mark 1) has two NULL leaf slots; poison its
      # two Int64 child values. The null map, not those bytes, defines values.
      w66r_reseal_frame_bytes(hidden, "payload", 0, [0x42_u8, 0x24_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
                                                     0x99_u8, 0x88_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8])
      reader = CrystalClick::WidePart.open_typed(hidden, "payload")
      reader.read_array_array_nullable_time64_ticks_mark_range("payload", 0, reader.mark_count).should eq(values)
    ensure
      FileUtils.rm_rf(parent.not_nil!)
    end
  end

  it "rejects invalid writer precision and unsorted keys before publishing a part" do
    parent = File.tempname("crystal-click-w66-writer-reject")
    Dir.mkdir(parent)
    target = File.join(parent, "not-published")
    values = [[[0_i64]]] of Array(Array(Int64))
    keys = [1_u64]
    expect_raises(ArgumentError) do
      CrystalClick::WidePartWriter.write_uint64_array_array_time64_pair(target, "pk", keys.to_unsafe.to_slice(1), "payload", values.to_unsafe.to_slice(1), 10)
    end
    File.exists?(target).should be_false

    unsorted_target = File.join(parent, "unsorted")
    unsorted_keys = [2_u64, 1_u64]
    unsorted_values = [[[0_i32]], [[1_i32]]] of Array(Array(Int32))
    expect_raises(ArgumentError) do
      CrystalClick::WidePartWriter.write_uint64_array_array_time_pair(unsorted_target, "pk", unsorted_keys.to_unsafe.to_slice(2), "payload", unsorted_values.to_unsafe.to_slice(2), 1)
    end
    File.exists?(unsorted_target).should be_false
  ensure
    FileUtils.rm_rf(parent.not_nil!)
  end
end
