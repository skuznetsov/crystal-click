require "./spec_helper"

W29_ARRAY_ARRAY_NULLABLE_UINT64_FIXTURE = File.expand_path("../test/fixtures/public/wide_array_array_nullable_uint64/part", __DIR__)

private def w29_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w29_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w29_rewrite_first_frame_value(path : String, stream : String, value : UInt64, width : Int32 = 8) : Nil
  data_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")
  encoded = File.read(data_path).to_slice
  frame = CrystalClick::CompressedBlock.decode_frame(encoded, 0_i64)
  raw = frame.output.dup
  case width
  when 1 then raw[0] = value.to_u8
  when 8 then w29_write_u64(raw, 0, value)
  else        raise "unsupported W29 mutation width"
  end

  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  rewritten = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  rewritten[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w29_write_u32(rewritten, header + 1, compressed_size.to_u32)
  w29_write_u32(rewritten, header + 5, raw.size.to_u32)
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
  w29_write_u64(rewritten, 0, hash[0])
  w29_write_u64(rewritten, 8, hash[1])
  raise "W29 mutation changed the frame's physical size" unless rewritten.size == frame.end_offset
  rewritten.copy_to(encoded.to_unsafe, rewritten.size)
  File.write(data_path, encoded)
end

private def w29_shift_mark_rows(path : String, stream : String) : Nil
  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  raise "W29 mutation requires at least two data marks and a sentinel" unless marks.size >= 3 * CrystalClick::WidePart::MARK_SIZE
  w29_write_u64(marks, 16, 1_u64)
  w29_write_u64(marks, CrystalClick::WidePart::MARK_SIZE + 16, 2_u64)
  File.write(marks_path, marks)
end

describe CrystalClick::WidePart do
  it "admits the exact W29 nested nullable UInt64 shape while rejecting malformed neighbors" do
    CrystalClick::WidePart.supports_typed_type?("Array(Array(Nullable(UInt64)))").should be_true
    [
      "Array(Array( Nullable(UInt64)))",
      "Array(Array(Nullable(UInt64), UInt64))",
      "Array(Array(Nullable(UInt64))) trailing",
      "Array(Array(Nullable(Bool)))",
      "Array(Array(Array(Nullable(UInt64))))",
    ].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "reads stock nested nullable UInt64 arrays and exposes exact per-mark batches" do
    expected = [
      [] of Array(UInt64?),
      [[] of UInt64?, [nil, 0_u64, UInt64::MAX] of UInt64?, [] of UInt64?],
      [[42_u64, nil] of UInt64?, [] of UInt64?],
      [] of Array(UInt64?),
      [[nil] of UInt64?, [] of UInt64?],
      [[1_u64, 2_u64, 3_u64] of UInt64?],
      [] of Array(UInt64?),
    ] of Array(Array(UInt64?))

    reader = CrystalClick::WidePart.open_typed(W29_ARRAY_ARRAY_NULLABLE_UINT64_FIXTURE, "payload")
    reader.column_type.should eq("Array(Array(Nullable(UInt64)))")
    reader.row_count.should eq(7_u64)
    reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    reader.read_array_array_nullable_uint64_mark_range("payload", 0, reader.mark_count).should eq(expected)
    reader.read_array_array_nullable_uint64_mark_range("payload", 1, 2).should eq(expected[2, 4])
    reader.array_array_nullable_uint64_mark_range_raw_bytes("payload", 0, reader.mark_count).should eq(201_u64)
    expect_raises(CrystalClick::BoundsError) do
      reader.read_array_array_nullable_uint64_mark_range("payload", 0, 0)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      reader.read_array_array_uint64_mark_range("payload", 0, 1)
    end

    parent = File.tempname("crystal-click-w29-array-array-null-u64-table")
    Dir.mkdir(parent)
    part_path = File.join(parent, "all_1_1_0")
    FileUtils.cp_r(W29_ARRAY_ARRAY_NULLABLE_UINT64_FIXTURE, part_path)
    begin
      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["payload"])
      observed = [] of Array(Array(UInt64?))
      offsets = [] of {Int32, UInt64, Int32}
      table.scan_typed(batch_rows: 3) do |batch|
        values = batch.array_array_nullable_uint64s_for("payload")
        observed.concat(values)
        offsets << {batch.mark_index, batch.part_row_offset, values.size.to_i32}
      end
      observed.should eq(expected)
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

  it "writes nested nullable UInt64 offsets and handles empty outer and inner marks" do
    parent = File.tempname("crystal-click-w29-array-array-null-u64-writer")
    Dir.mkdir(parent)
    part_path = File.join(parent, "all_1_1_0")
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    values = [
      [] of Array(UInt64?),
      [[] of UInt64?],
      [[] of UInt64?, [] of UInt64?],
      [[nil, 0_u64, UInt64::MAX] of UInt64?, [] of UInt64?, [42_u64, nil] of UInt64?],
      [[1_u64, 2_u64, 3_u64] of UInt64?],
    ] of Array(Array(UInt64?))

    begin
      CrystalClick::WidePartWriter.write_uint64_array_array_nullable_uint64_pair(
        part_path,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 1
      )

      reader = CrystalClick::WidePart.open_typed(part_path, "payload")
      reader.column_type.should eq("Array(Array(Nullable(UInt64)))")
      reader.mark_row_counts.should eq([1_u64, 1_u64, 1_u64, 1_u64, 1_u64])
      reader.read_array_array_nullable_uint64_mark_range("payload", 0, reader.mark_count).should eq(values)
      reader.read_array_array_nullable_uint64_mark_range("payload", 2, 1).should eq(values[2, 1])
      reader.array_array_nullable_uint64_mark_range_raw_bytes("payload", 0, reader.mark_count).should eq(168_u64)

      all_empty_path = File.join(parent, "all_2_2_0")
      all_empty_keys = [6_u64, 7_u64, 8_u64]
      all_empty = Array(Array(Array(UInt64?))).new(3) { [] of Array(UInt64?) }
      CrystalClick::WidePartWriter.write_uint64_array_array_nullable_uint64_pair(
        all_empty_path,
        "pk",
        all_empty_keys.to_unsafe.to_slice(all_empty_keys.size),
        "payload",
        all_empty.to_unsafe.to_slice(all_empty.size),
        rows_per_mark: 2
      )
      all_empty_reader = CrystalClick::WidePart.open_typed(all_empty_path, "payload")
      all_empty_reader.read_array_array_nullable_uint64_mark_range("payload", 0, all_empty_reader.mark_count).should eq(all_empty)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects shifted same-size child mark boundaries before exposing table batches" do
    parent = File.tempname("crystal-click-w29-array-array-null-u64-shifted-mark")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64, 3_u64]
    values = [[[1_u64] of UInt64?], [[2_u64] of UInt64?], [[3_u64] of UInt64?]] of Array(Array(UInt64?))

    begin
      ["payload.size1", "payload.null"].each_with_index do |stream, index|
        part_path = File.join(parent, "all_#{index + 1}_#{index + 1}_0")
        CrystalClick::WidePartWriter.write_uint64_array_array_nullable_uint64_pair(
          part_path,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "payload",
          values.to_unsafe.to_slice(values.size),
          rows_per_mark: 2
        )
        w29_shift_mark_rows(part_path, stream)

        callbacks = 0
        expect_raises(CrystalClick::CorruptPartError) do
          table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["payload"])
          table.scan_typed(batch_rows: 3) { |_batch| callbacks += 1 }
        end
        callbacks.should eq(0)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "enforces nested leaf caps before materialization and writer publication" do
    parent = File.tempname("crystal-click-w29-array-array-null-u64-bounds")
    Dir.mkdir(parent)
    part_path = File.join(parent, "all_1_1_0")
    keys = [1_u64]
    values = [[[1_u64] of UInt64?]] of Array(Array(UInt64?))

    begin
      CrystalClick::WidePartWriter.write_uint64_array_array_nullable_uint64_pair(
        part_path,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 1
      )
      w29_rewrite_first_frame_value(part_path, "payload.size1", CrystalClick::WidePart::MAX_ARRAY_MARK_ELEMENTS + 1_u64)

      reader = CrystalClick::WidePart.open_typed(part_path, "payload")
      error = expect_raises(CrystalClick::CorruptPartError) do
        reader.read_array_array_nullable_uint64_mark_range("payload", 0, 1)
      end
      error.message.to_s.should contain("leaf element count exceeds per-range limit")

      table_callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["payload"])
        table.scan_typed(batch_rows: 1) { |_batch| table_callbacks += 1 }
      end
      table_callbacks.should eq(0)

      oversized_inner = Array(UInt64?).new((CrystalClick::WidePart::MAX_ARRAY_MARK_ELEMENTS + 1_u64).to_i) { 0_u64 }
      oversized_values = [[oversized_inner]] of Array(Array(UInt64?))
      unpublished_path = File.join(parent, "all_2_2_0")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_array_nullable_uint64_pair(
          unpublished_path,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "payload",
          oversized_values.to_unsafe.to_slice(oversized_values.size),
          rows_per_mark: 1
        )
      end
      File.exists?(unpublished_path).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a malformed nested null-map byte" do
    parent = File.tempname("crystal-click-w29-array-array-null-u64-bad-null")
    Dir.mkdir(parent)
    part_path = File.join(parent, "all_1_1_0")
    FileUtils.cp_r(W29_ARRAY_ARRAY_NULLABLE_UINT64_FIXTURE, part_path)

    begin
      w29_rewrite_first_frame_value(part_path, "payload.null", 2_u64, 1)
      reader = CrystalClick::WidePart.open_typed(part_path, "payload")
      expect_raises(CrystalClick::CorruptPartError, /null map contains a value other than 0 or 1/) do
        reader.read_array_array_nullable_uint64_mark_range("payload", 0, reader.mark_count)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
