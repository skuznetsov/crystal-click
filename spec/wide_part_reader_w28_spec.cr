require "./spec_helper"

W28_ARRAY_ARRAY_UINT64_FIXTURE = File.expand_path("../test/fixtures/public/wide_array_array_uint64/part", __DIR__)

private def w28_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w28_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w28_rewrite_u64_frame(path : String, stream : String, value : UInt64) : Nil
  data_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")
  encoded = File.read(data_path).to_slice
  frame = CrystalClick::CompressedBlock.decode_frame(encoded, 0_i64)
  raw = frame.output.dup
  w28_write_u64(raw, 0, value)

  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  rewritten = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  rewritten[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w28_write_u32(rewritten, header + 1, compressed_size.to_u32)
  w28_write_u32(rewritten, header + 5, raw.size.to_u32)
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
  w28_write_u64(rewritten, 0, hash[0])
  w28_write_u64(rewritten, 8, hash[1])
  raise "W28 mutation changed the frame's physical size" unless rewritten.size == frame.end_offset
  rewritten.copy_to(encoded.to_unsafe, rewritten.size)
  File.write(data_path, encoded)
end

describe CrystalClick::WidePart do
  it "admits the exact nested Array(UInt64) recursive type" do
    CrystalClick::WidePart.supports_typed_type?("Array(Array(UInt64))").should be_true
    [
      "Array( Array(UInt64))",
      "Array(Array(UInt64, UInt64))",
      "Array(Array(Nullable(UInt8)))",
      "Array(Array(UInt64)) trailing",
    ].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "reads the stock three-stream nested UInt64 array by outer-row marks" do
    expected = [
      [] of Array(UInt64),
      [[] of UInt64, [0_u64, UInt64::MAX], [] of UInt64],
      [[42_u64], [] of UInt64],
      [] of Array(UInt64),
      [[] of UInt64, [] of UInt64],
      [[1_u64, 2_u64, 3_u64]],
      [] of Array(UInt64),
    ] of Array(Array(UInt64))

    reader = CrystalClick::WidePart.open_typed(W28_ARRAY_ARRAY_UINT64_FIXTURE, "payload")
    reader.column_type.should eq("Array(Array(UInt64))")
    reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    reader.read_array_array_uint64_mark_range("payload", 0, reader.mark_count).should eq(expected)
    reader.read_array_array_uint64_mark_range("payload", 1, 2).should eq(expected[2, 4])
    expect_raises(CrystalClick::BoundsError) do
      reader.read_array_array_uint64_mark_range("payload", 0, 0)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      reader.read_array_uint64_mark_range("payload", 0, 1)
    end

    parent = File.tempname("crystal-click-w28-array-array-u64-table")
    Dir.mkdir(parent)
    part_path = File.join(parent, "all_1_1_0")
    FileUtils.cp_r(W28_ARRAY_ARRAY_UINT64_FIXTURE, part_path)
    begin
      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["payload"])
      observed = [] of Array(Array(UInt64))
      offsets = [] of {Int32, UInt64, Int32}
      table.scan_typed(batch_rows: 3) do |batch|
        values = batch.array_array_uint64s_for("payload")
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

  it "writes nested UInt64 offsets including a zero-leaf middle mark" do
    parent = File.tempname("crystal-click-w28-array-array-u64-writer")
    Dir.mkdir(parent)
    part_path = File.join(parent, "all_1_1_0")
    keys = [1_u64, 2_u64, 3_u64]
    values = [
      [[5_u64]],
      [[] of UInt64, [] of UInt64],
      [[0_u64, UInt64::MAX]],
    ] of Array(Array(UInt64))

    begin
      CrystalClick::WidePartWriter.write_uint64_array_array_uint64_pair(
        part_path,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 1
      )

      reader = CrystalClick::WidePart.open_typed(part_path, "payload")
      reader.column_type.should eq("Array(Array(UInt64))")
      reader.mark_row_counts.should eq([1_u64, 1_u64, 1_u64])
      reader.read_array_array_uint64_mark_range("payload", 0, 3).should eq(values)
      reader.read_array_array_uint64_mark_range("payload", 1, 1).should eq(values[1, 1])

      empty_outer_path = File.join(parent, "all_2_2_0")
      empty_outer = [
        [] of Array(UInt64),
        [] of Array(UInt64),
        [] of Array(UInt64),
      ] of Array(Array(UInt64))
      empty_keys = [4_u64, 5_u64, 6_u64]
      CrystalClick::WidePartWriter.write_uint64_array_array_uint64_pair(
        empty_outer_path,
        "pk",
        empty_keys.to_unsafe.to_slice(empty_keys.size),
        "payload",
        empty_outer.to_unsafe.to_slice(empty_outer.size),
        rows_per_mark: 2
      )
      empty_outer_reader = CrystalClick::WidePart.open_typed(empty_outer_path, "payload")
      empty_outer_reader.read_array_array_uint64_mark_range("payload", 0, empty_outer_reader.mark_count).should eq(empty_outer)

      empty_inner_path = File.join(parent, "all_3_3_0")
      empty_inner = [
        [[] of UInt64],
        [[] of UInt64],
      ] of Array(Array(UInt64))
      empty_inner_keys = [7_u64, 8_u64]
      CrystalClick::WidePartWriter.write_uint64_array_array_uint64_pair(
        empty_inner_path,
        "pk",
        empty_inner_keys.to_unsafe.to_slice(empty_inner_keys.size),
        "payload",
        empty_inner.to_unsafe.to_slice(empty_inner.size),
        rows_per_mark: 1
      )
      empty_inner_reader = CrystalClick::WidePart.open_typed(empty_inner_path, "payload")
      empty_inner_reader.read_array_array_uint64_mark_range("payload", 0, empty_inner_reader.mark_count).should eq(empty_inner)
      empty_inner_reader.array_array_uint64_mark_range_raw_bytes("payload", 0, 2).should eq(32_u64)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects shifted size1 marks before exposing a batch callback" do
    parent = File.tempname("crystal-click-w28-array-array-u64-shifted-mark")
    Dir.mkdir(parent)
    part_path = File.join(parent, "all_1_1_0")
    keys = [1_u64, 2_u64]
    values = [[[1_u64]], [[] of UInt64]] of Array(Array(UInt64))

    begin
      CrystalClick::WidePartWriter.write_uint64_array_array_uint64_pair(
        part_path,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 1
      )
      marks_path = File.join(part_path, "#{CrystalClick::StreamName.hash("payload.size1")}.mrk2")
      marks = File.read(marks_path).to_slice.dup
      w28_write_u64(marks, CrystalClick::WidePart::MARK_SIZE + 8, 16_u64)
      File.write(marks_path, marks)

      table = CrystalClick::WidePartTable.open_selected_typed([part_path], ["payload"])
      callbacks = 0
      error = expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed(batch_rows: 2) { |_batch| callbacks += 1 }
      end
      error.message.to_s.should contain("mark offset exceeds frame output")
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects an oversized leaf count before reading leaf values and does not publish over-limit writer input" do
    parent = File.tempname("crystal-click-w28-array-array-u64-bounds")
    Dir.mkdir(parent)
    part_path = File.join(parent, "all_1_1_0")
    keys = [1_u64]
    values = [[[1_u64]]] of Array(Array(UInt64))

    begin
      CrystalClick::WidePartWriter.write_uint64_array_array_uint64_pair(
        part_path,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 1
      )
      w28_rewrite_u64_frame(part_path, "payload.size1", CrystalClick::WidePart::MAX_ARRAY_MARK_ELEMENTS + 1_u64)
      reader = CrystalClick::WidePart.open_typed(part_path, "payload")
      error = expect_raises(CrystalClick::CorruptPartError) do
        reader.read_array_array_uint64_mark_range("payload", 0, 1)
      end
      error.message.to_s.should contain("leaf element count exceeds per-range limit")

      oversized_inner = Array(UInt64).new((CrystalClick::WidePart::MAX_ARRAY_MARK_ELEMENTS + 1_u64).to_i) { 0_u64 }
      oversized_values = [[oversized_inner]] of Array(Array(UInt64))
      unpublished_path = File.join(parent, "all_2_2_0")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_array_uint64_pair(
          unpublished_path,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "payload",
          oversized_values.to_unsafe.to_slice(oversized_values.size),
          rows_per_mark: 1
        )
      end
      File.exists?(unpublished_path).should be_false
      Dir.children(parent).sort.should eq(["all_1_1_0"])
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
