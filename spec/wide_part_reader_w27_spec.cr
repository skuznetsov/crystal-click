require "./spec_helper"

W27_ARRAY_NULLABLE_UINT64_FIXTURE = File.expand_path("../test/fixtures/public/wide_array_nullable_uint64/part", __DIR__)

private def w27_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w27_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w27_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w27_decode_u64_stream(path : String, stream : String) : Array(UInt64)
  raw = CrystalClick::CompressedBlock.decode_all(
    File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  )
  raise "W27 stream is not UInt64-aligned" unless raw.size % 8 == 0
  Array(UInt64).new(raw.size // 8) { |index| w27_u64(raw, index * 8) }
end

private def w27_decode_bytes_stream(path : String, stream : String) : Array(UInt8)
  CrystalClick::CompressedBlock.decode_all(
    File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")).to_slice
  ).to_a
end

private def w27_mark_triples(path : String, stream : String) : Array({UInt64, UInt64, UInt64})
  marks = File.read(File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "W27 mark file is malformed" unless marks.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array({UInt64, UInt64, UInt64}).new(marks.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    base = index * CrystalClick::WidePart::MARK_SIZE
    {w27_u64(marks, base), w27_u64(marks, base + 8), w27_u64(marks, base + 16)}
  end
end

private def w27_rewrite_first_frame_value(path : String, stream : String, raw_offset : Int, raw_width : Int, value : UInt64) : Nil
  data_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.bin")
  encoded = File.read(data_path).to_slice
  frame = CrystalClick::CompressedBlock.decode_frame(encoded, 0_i64)
  raw = frame.output.dup
  if raw_width == 1
    raw[raw_offset] = value.to_u8
  elsif raw_width == 8
    w27_write_u64(raw, raw_offset, value)
  else
    raise "unsupported W27 mutation width"
  end

  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  rewritten = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  rewritten[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w27_write_u32(rewritten, header + 1, compressed_size.to_u32)
  w27_write_u32(rewritten, header + 5, raw.size.to_u32)
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
  w27_write_u64(rewritten, 0, hash[0])
  w27_write_u64(rewritten, 8, hash[1])
  old_frame_end = frame.end_offset.to_i
  delta = rewritten.size - old_frame_end
  result = Bytes.new(encoded.size + delta)
  rewritten.copy_to(result.to_unsafe, rewritten.size)
  encoded[old_frame_end, encoded.size - old_frame_end].copy_to(result.to_unsafe + rewritten.size, encoded.size - old_frame_end)
  File.write(data_path, result)

  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  raise "W27 mark file is malformed" unless marks.size % CrystalClick::WidePart::MARK_SIZE == 0
  (0...marks.size).step(CrystalClick::WidePart::MARK_SIZE) do |offset|
    compressed_offset = w27_u64(marks, offset)
    if compressed_offset >= old_frame_end.to_u64
      w27_write_u64(marks, offset, (compressed_offset.to_i64 + delta).to_u64)
    end
  end
  File.write(marks_path, marks)
end

describe CrystalClick::WidePart do
  it "keeps Array(Nullable(UInt64)) and other supported Array admissions exact" do
    ["Array(UInt64)", "Array(String)", "Array(Nullable(UInt64))", "Array(Array(UInt64))", "Array(Array(Nullable(UInt64)))"].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_true
    end
    [
      "Array(Nullable(UInt8))",
      "Array(Nullable(UInt64) trailing)",
      "Nullable(Array(UInt64))",
      "Array(Array(Nullable(UInt8)))",
      "Array(Array(UInt64) trailing)",
      "Array(Nullable(Nullable(UInt64)))",
    ].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "reads stock Array(Nullable(UInt64)) child streams by outer-row marks and batches typed values" do
    arrays = [
      [] of UInt64?,
      [nil, 0_u64, UInt64::MAX] of UInt64?,
      [42_u64, nil] of UInt64?,
      [] of UInt64?,
      [nil] of UInt64?,
      [1_u64, 2_u64] of UInt64?,
      [] of UInt64?,
    ] of Array(UInt64?)
    reader = CrystalClick::WidePart.open_typed(W27_ARRAY_NULLABLE_UINT64_FIXTURE, "payload")
    reader.column_type.should eq("Array(Nullable(UInt64))")
    reader.row_count.should eq(7_u64)
    reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    reader.read_array_nullable_uint64_mark_range("payload", 0, reader.mark_count).should eq(arrays)
    reader.read_array_nullable_uint64_mark_range("payload", 1, 2).should eq(arrays[2, 4])
    reader.array_nullable_uint64_mark_range_raw_bytes("payload", 0, reader.mark_count).should eq(72_u64)

    w27_decode_u64_stream(W27_ARRAY_NULLABLE_UINT64_FIXTURE, "payload.size0").should eq([0_u64, 3_u64, 2_u64, 0_u64, 1_u64, 2_u64, 0_u64])
    w27_decode_bytes_stream(W27_ARRAY_NULLABLE_UINT64_FIXTURE, "payload.null").should eq([1_u8, 0_u8, 0_u8, 0_u8, 1_u8, 1_u8, 0_u8, 0_u8])
    w27_decode_u64_stream(W27_ARRAY_NULLABLE_UINT64_FIXTURE, "payload").should eq([0_u64, 0_u64, UInt64::MAX, 42_u64, 0_u64, 0_u64, 1_u64, 2_u64])
    w27_mark_triples(W27_ARRAY_NULLABLE_UINT64_FIXTURE, "payload.size0").should eq([
      {0_u64, 0_u64, 2_u64}, {0_u64, 16_u64, 2_u64}, {0_u64, 32_u64, 2_u64},
      {0_u64, 48_u64, 1_u64}, {0_u64, 56_u64, 0_u64},
    ])
    w27_mark_triples(W27_ARRAY_NULLABLE_UINT64_FIXTURE, "payload.null").should eq([
      {0_u64, 0_u64, 2_u64}, {0_u64, 3_u64, 2_u64}, {0_u64, 5_u64, 2_u64},
      {0_u64, 8_u64, 1_u64}, {0_u64, 8_u64, 0_u64},
    ])
    w27_mark_triples(W27_ARRAY_NULLABLE_UINT64_FIXTURE, "payload").should eq([
      {0_u64, 0_u64, 2_u64}, {0_u64, 24_u64, 2_u64}, {0_u64, 40_u64, 2_u64},
      {0_u64, 64_u64, 1_u64}, {0_u64, 64_u64, 0_u64},
    ])

    table_root = File.tempname("crystal-click-w27-reader-table")
    Dir.mkdir(table_root)
    table_part = File.join(table_root, "all_1_1_0")
    FileUtils.cp_r(W27_ARRAY_NULLABLE_UINT64_FIXTURE, table_part)
    begin
      table = CrystalClick::WidePartTable.open_selected_typed([table_part], ["pk", "payload"])
      observed = [] of Array(UInt64?)
      offsets = [] of {Int32, UInt64, Int32}
      table.scan_typed(batch_rows: 3) do |batch|
        observed.concat(batch.array_nullable_uint64s_for("payload").map(&.dup))
        offsets << {batch.mark_index, batch.part_row_offset, batch.array_nullable_uint64s_for("payload").size.to_i32}
        expect_raises(CrystalClick::UnsupportedFormatError) { batch.array_uint64s_for("payload") }
      end
      observed.should eq(arrays)
      offsets.should eq([
        {0_i32, 0_u64, 2_i32}, {1_i32, 2_u64, 2_i32},
        {2_i32, 4_u64, 2_i32}, {3_i32, 6_u64, 1_i32},
      ])
    ensure
      FileUtils.rm_rf(table_root)
    end
  end

  it "accepts stock Default key statistics but rejects out-of-range counts and wrong child marks" do
    parent = File.tempname("crystal-click-w27-reader-corrupt")
    Dir.mkdir(parent)
    begin
      valid = File.join(parent, "valid")
      FileUtils.cp_r(W27_ARRAY_NULLABLE_UINT64_FIXTURE, valid)
      CrystalClick::WidePart.open_typed(valid, "payload").read_array_nullable_uint64_mark_range("payload", 0, 1).should eq([
        [] of UInt64?, [nil, 0_u64, UInt64::MAX] of UInt64?,
      ])

      bad_stats = File.join(parent, "bad-stats")
      FileUtils.cp_r(W27_ARRAY_NULLABLE_UINT64_FIXTURE, bad_stats)
      serialization = File.join(bad_stats, "serialization.json")
      File.write(serialization, File.read(serialization).sub("num_defaults\":1", "num_defaults\":8"))
      expect_raises(CrystalClick::CorruptPartError) { CrystalClick::WidePart.open_typed(bad_stats, "payload") }

      bad_kind = File.join(parent, "bad-kind")
      FileUtils.cp_r(W27_ARRAY_NULLABLE_UINT64_FIXTURE, bad_kind)
      serialization = File.join(bad_kind, "serialization.json")
      File.write(serialization, File.read(serialization).sub("kind\":\"Default\"", "kind\":\"Sparse\""))
      expect_raises(CrystalClick::UnsupportedFormatError) { CrystalClick::WidePart.open_typed(bad_kind, "payload") }

      bad_rows = File.join(parent, "bad-child-rows")
      FileUtils.cp_r(W27_ARRAY_NULLABLE_UINT64_FIXTURE, bad_rows)
      null_marks_path = File.join(bad_rows, "#{CrystalClick::StreamName.hash("payload.null")}.mrk2")
      null_marks = File.read(null_marks_path).to_slice.dup
      w27_write_u64(null_marks, CrystalClick::WidePart::MARK_SIZE + 16, 1_u64)
      File.write(null_marks_path, null_marks)
      expect_raises(CrystalClick::CorruptPartError) { CrystalClick::WidePart.open_typed(bad_rows, "payload") }

      bad_offset = File.join(parent, "bad-child-offset")
      FileUtils.cp_r(W27_ARRAY_NULLABLE_UINT64_FIXTURE, bad_offset)
      null_marks_path = File.join(bad_offset, "#{CrystalClick::StreamName.hash("payload.null")}.mrk2")
      null_marks = File.read(null_marks_path).to_slice.dup
      w27_write_u64(null_marks, 2 * CrystalClick::WidePart::MARK_SIZE + 8, 6_u64)
      File.write(null_marks_path, null_marks)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(bad_offset, "payload").read_array_nullable_uint64_mark_range("payload", 1, 1)
      end
      callbacks = 0
      table_bad_offset = File.join(parent, "all_1_1_0")
      FileUtils.cp_r(bad_offset, table_bad_offset)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartTable.open_selected_typed([table_bad_offset], ["payload"]).scan_typed_candidate_marks([[2]]) do |_batch|
          callbacks += 1
        end
      end
      callbacks.should eq(0)

      bad_null = File.join(parent, "bad-null-map")
      FileUtils.cp_r(W27_ARRAY_NULLABLE_UINT64_FIXTURE, bad_null)
      w27_rewrite_first_frame_value(bad_null, "payload.null", 0, 1, 2_u64)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(bad_null, "payload").read_array_nullable_uint64_mark_range("payload", 0, 2)
      end

      oversized = File.join(parent, "oversized-size0")
      FileUtils.cp_r(W27_ARRAY_NULLABLE_UINT64_FIXTURE, oversized)
      w27_rewrite_first_frame_value(oversized, "payload.size0", 0, 8, UInt64::MAX)
      expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(oversized, "payload").read_array_nullable_uint64_mark_range("payload", 0, 1)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe CrystalClick::WidePartWriter do
  it "writes Array(Nullable(UInt64)) with separate child streams and outer-row marks" do
    parent = File.tempname("crystal-click-w27-writer-array-null-u64")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [0_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
    values = [
      [] of UInt64?,
      [nil, 0_u64, UInt64::MAX] of UInt64?,
      [42_u64, nil] of UInt64?,
      [] of UInt64?,
      [nil] of UInt64?,
      [1_u64, 2_u64] of UInt64?,
      [] of UInt64?,
    ] of Array(UInt64?)

    begin
      CrystalClick::WidePartWriter.write_uint64_array_nullable_uint64_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        values.to_unsafe.to_slice(values.size), rows_per_mark: 2
      ).should eq(destination)
      part = CrystalClick::WidePart.open_typed(destination, "payload")
      part.read_array_nullable_uint64_mark_range("payload", 0, part.mark_count).should eq(values)
      part.read_array_nullable_uint64_mark_range("payload", 1, 2).should eq(values[2, 4])
      part.array_nullable_uint64_mark_range_raw_bytes("payload", 0, part.mark_count).should eq(72_u64)
      ["pk", "payload.size0", "payload.null", "payload"].each do |stream|
        w27_mark_triples(destination, stream).map(&.[2]).should eq([2_u64, 2_u64, 2_u64, 1_u64, 0_u64])
      end
      w27_decode_u64_stream(destination, "payload.size0").should eq([0_u64, 3_u64, 2_u64, 0_u64, 1_u64, 2_u64, 0_u64])
      w27_decode_bytes_stream(destination, "payload.null").should eq([1_u8, 0_u8, 0_u8, 0_u8, 1_u8, 1_u8, 0_u8, 0_u8])
      w27_decode_u64_stream(destination, "payload").should eq([0_u64, 0_u64, UInt64::MAX, 42_u64, 0_u64, 0_u64, 1_u64, 2_u64])
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n3 substreams for column `payload`:\n\tpayload.size0\n\tpayload.null\n\tpayload\n"
      )

      middle_path = File.join(parent, "empty-middle")
      middle_keys = [1_u64, 2_u64, 3_u64]
      middle_values = [[0_u64] of UInt64?, [] of UInt64?, [nil, UInt64::MAX] of UInt64?] of Array(UInt64?)
      CrystalClick::WidePartWriter.write_uint64_array_nullable_uint64_pair(
        middle_path, "pk", middle_keys.to_unsafe.to_slice(middle_keys.size), "payload",
        middle_values.to_unsafe.to_slice(middle_values.size), rows_per_mark: 1
      )
      middle = CrystalClick::WidePart.open_typed(middle_path, "payload")
      middle.read_array_nullable_uint64_mark_range("payload", 0, middle.mark_count).should eq(middle_values)
      null_data = File.join(middle_path, "#{CrystalClick::StreamName.hash("payload.null")}.bin")
      null_encoded = File.read(null_data).to_slice
      first_null_frame = CrystalClick::CompressedBlock.decode_frame(null_encoded, 0_i64)
      last_null_frame = CrystalClick::CompressedBlock.decode_frame(null_encoded, first_null_frame.end_offset)
      last_null_frame.end_offset.should eq(null_encoded.size.to_i64)
      w27_mark_triples(middle_path, "payload.null").map(&.[0]).should eq([
        0_u64, first_null_frame.end_offset.to_u64, first_null_frame.end_offset.to_u64, null_encoded.size.to_u64,
      ])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects excessive flattened nullable elements before publishing a part" do
    parent = File.tempname("crystal-click-w27-writer-array-null-limit")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64]
    values = [Array(UInt64?).new((CrystalClick::WidePart::MAX_ARRAY_MARK_ELEMENTS + 1).to_i, nil)]
    begin
      error = expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_nullable_uint64_pair(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          values.to_unsafe.to_slice(values.size), rows_per_mark: 1
        )
      end
      error.message.to_s.should contain("Array(Nullable(UInt64)) nested element count exceeds per-mark limit")
      Dir.children(parent).should eq([] of String)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
