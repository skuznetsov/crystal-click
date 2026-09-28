require "./spec_helper"

private def w61_reader_values(long_value : String) : Array(Array(Array(String?)))
  values = [] of Array(Array(String?))
  values << [["alpha", nil, ""] of String?]
  values << [] of Array(String?)
  values << [[nil] of String?, [] of String?, [nil, nil] of String?]
  values << [[nil] of String?]
  values << [[] of String?, [] of String?]
  values << [] of Array(String?)
  values << [["a\0b", "é😃", long_value] of String?, [] of String?]
  values << [["", "β"] of String?]
  values << [["tail", nil] of String?]
  values
end

private def w61_reader_append_u64(bytes : Array(UInt8), value : UInt64) : Nil
  8.times { |byte| bytes << ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w61_reader_expected_streams(values : Array(Array(Array(String?)))) : {Array(UInt8), Array(UInt8), Array(UInt8), Array(UInt8), Array(UInt8)}
  size0 = [] of UInt8
  size1 = [] of UInt8
  nulls = [] of UInt8
  sizes = [] of UInt8
  raw = [] of UInt8
  values.each do |row|
    w61_reader_append_u64(size0, row.size.to_u64)
    row.each do |inner|
      w61_reader_append_u64(size1, inner.size.to_u64)
      inner.each do |value|
        if value.nil?
          nulls << 1_u8
          w61_reader_append_u64(sizes, 0_u64)
        else
          string = value.not_nil!
          nulls << 0_u8
          w61_reader_append_u64(sizes, string.bytesize.to_u64)
          string.to_slice.each { |byte| raw << byte }
        end
      end
    end
  end
  {size0, size1, nulls, sizes, raw}
end

private def w61_reader_raw_stream(part : String, stream : String) : Bytes
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice)
end

private def w61_reader_bytes(values : Array(UInt8)) : Bytes
  bytes = Bytes.new(values.size)
  values.each_with_index { |value, index| bytes[index] = value }
  bytes
end

private def w61_reader_stream_mark_chunks(values : Array(Array(Array(String?))), stream : String) : Array(Bytes)
  chunks = [] of Bytes
  first_row = 0
  while first_row < values.size
    row_count = Math.min(2, values.size - first_row)
    rows = values[first_row, row_count]
    raw = [] of UInt8
    rows.each do |row|
      case stream
      when "payload.size0"
        w61_reader_append_u64(raw, row.size.to_u64)
      when "payload.size1"
        row.each { |inner| w61_reader_append_u64(raw, inner.size.to_u64) }
      when "payload.null"
        row.each do |inner|
          inner.each { |value| raw << (value.nil? ? 1_u8 : 0_u8) }
        end
      when "payload.size"
        row.each do |inner|
          inner.each { |value| w61_reader_append_u64(raw, value.nil? ? 0_u64 : value.not_nil!.bytesize.to_u64) }
        end
      when "payload"
        row.each do |inner|
          inner.each do |value|
            value.not_nil!.to_slice.each { |byte| raw << byte } unless value.nil?
          end
        end
      else
        raise "unsupported W61 test stream"
      end
    end
    chunks << w61_reader_bytes(raw)
    first_row += row_count
  end
  chunks
end

private def w61_reader_write_u32(bytes : Bytes, offset : Int, value : UInt32) : Nil
  4.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u32).to_u8 }
end

private def w61_reader_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w61_reader_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w61_reader_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w61_reader_write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
  8.times { |byte| io.write_byte(((hash[0] >> (byte * 8)) & 0xff_u64).to_u8) }
  8.times { |byte| io.write_byte(((hash[1] >> (byte * 8)) & 0xff_u64).to_u8) }
end

private def w61_reader_encode_lz4_frame(raw : Bytes) : Bytes
  raise "W61 test cannot encode an empty LZ4 block" if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  w61_reader_write_u32(frame, header + 1, compressed_size.to_u32)
  w61_reader_write_u32(frame, header + 5, raw.size.to_u32)
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
  checksum = CrystalClick::CityHashV1.hash128(frame[header, compressed_size])
  w61_reader_write_u64(frame, 0, checksum[0])
  w61_reader_write_u64(frame, 8, checksum[1])
  frame
end

private def w61_reader_refresh_checksums(part : String) : Nil
  parsed = CrystalClick::PartChecksums.open(part)
  payload = IO::Memory.new
  names = parsed.entries.keys.sort
  w61_reader_write_varuint(payload, names.size.to_u64)
  names.each do |name|
    file_bytes = File.read(File.join(part, name)).to_slice
    entry = parsed.entries[name]
    w61_reader_write_varuint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w61_reader_write_varuint(payload, file_bytes.size.to_u64)
    w61_reader_write_hash(payload, CrystalClick::CityHashV1.file_hash(file_bytes))
    if entry.compressed
      raw = CrystalClick::CompressedBlock.decode_all(file_bytes)
      payload.write_byte(1_u8)
      w61_reader_write_varuint(payload, raw.size.to_u64)
      w61_reader_write_hash(payload, CrystalClick::CityHashV1.file_hash(raw))
    else
      payload.write_byte(0_u8)
    end
  end
  frame = w61_reader_encode_lz4_frame(payload.to_slice)
  File.open(File.join(part, "checksums.txt"), "wb") do |io|
    io << CrystalClick::PartChecksums::CHECKSUMS_HEADER
    io.write(frame)
  end
end

private def w61_reader_reencode_mark_chunks(part : String, stream : String, chunks : Array(Bytes)) : Nil
  data_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  marks_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  mark_records = marks.size // CrystalClick::WidePart::MARK_SIZE
  raise "W61 test mark/chunk count mismatch" unless mark_records == chunks.size + 1

  output = IO::Memory.new
  compressed_offset = 0_u64
  chunks.each_with_index do |chunk, index|
    mark_offset = index * CrystalClick::WidePart::MARK_SIZE
    w61_reader_write_u64(marks, mark_offset, compressed_offset)
    w61_reader_write_u64(marks, mark_offset + 8, 0_u64)
    unless chunk.empty?
      frame = w61_reader_encode_lz4_frame(chunk)
      output.write(frame)
      compressed_offset += frame.size.to_u64
    end
  end
  sentinel_offset = chunks.size * CrystalClick::WidePart::MARK_SIZE
  w61_reader_write_u64(marks, sentinel_offset, compressed_offset)
  w61_reader_write_u64(marks, sentinel_offset + 8, 0_u64)

  File.write(data_path, output.to_slice)
  File.write(marks_path, marks)

  w61_reader_refresh_checksums(part)
end

private def w61_reader_shift_mark(part : String, stream : String, mark_index : Int, delta : UInt64) : Nil
  marks_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE + 8
  w61_reader_write_u64(marks, offset, w61_reader_read_u64(marks, offset) + delta)
  File.write(marks_path, marks)
  w61_reader_refresh_checksums(part)
end

private def w61_reader_write_part(part : String, values : Array(Array(Array(String?)))) : Nil
  keys = (1_u64..values.size.to_u64).to_a
  CrystalClick::WidePartWriter.write_uint64_array_array_nullable_string_pair(
    part,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "payload",
    values.to_unsafe.to_slice(values.size),
    rows_per_mark: 2
  )
end

describe CrystalClick::WidePart do
  it "admits only the exact two-level nullable String Array shape in W61" do
    CrystalClick::WidePart.supports_typed_type?("Array(Array(Nullable(String)))").should be_true

    {
      "Array(Array(Nullable(FixedString(4))))",
      "Array(Array(Array(Nullable(String))))",
      "Array(Array(Nullable(String))) trailing",
      "Array(Array( Nullable(String)))",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "plans the exact five W61 streams in serializer order" do
    type = "Array(Array(Nullable(String)))"
    plan = CrystalClick::WideTypePlan.admitted(type).not_nil!
    plan.shape.should eq(CrystalClick::WideTypePlan::Shape::ArrayArrayNullableString)
    plan.physical_substreams("payload").should eq([
      "payload.size0",
      "payload.size1",
      "payload.null",
      "payload.size",
      "payload",
    ])

    {
      "Array(Array(Nullable(FixedString(4))))",
      "Array(Array(Array(Nullable(String))))",
      "Array(Array(Nullable(String))) trailing",
      "Array(Array( Nullable(String)))",
    }.each do |unadmitted|
      CrystalClick::WideTypePlan.admitted(unadmitted).should be_nil
    end
  end

  it "reads NULL, empty, binary, and nested values by marks with exact five-stream byte accounting" do
    parent = File.tempname("crystal-click-w61-reader")
    Dir.mkdir(parent)
    part = File.join(parent, "part")
    values = w61_reader_values("z" * 5000)

    begin
      w61_reader_write_part(part, values)
      reader = CrystalClick::WidePart.open_typed(part, "payload")
      reader.column_type.should eq("Array(Array(Nullable(String)))")
      reader.row_count.should eq(values.size.to_u64)
      reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 2_u64, 1_u64])
      reader.read_array_array_nullable_string_mark_range("payload", 0, reader.mark_count).should eq(values)
      reader.read_array_array_nullable_string_mark_range("payload", 3, 2).should eq(values[6, 3])

      expected_streams = w61_reader_expected_streams(values).to_a
      {"payload.size0", "payload.size1", "payload.null", "payload.size", "payload"}.zip(expected_streams).each do |stream, expected|
        w61_reader_raw_stream(part, stream).to_a.should eq(expected)
      end

      flat_inner_arrays = 0_u64
      flat_strings = 0_u64
      raw_bytes = 0_u64
      values.each do |row|
        flat_inner_arrays += row.size.to_u64
        row.each do |inner|
          flat_strings += inner.size.to_u64
          inner.each { |value| raw_bytes += value.not_nil!.bytesize.to_u64 unless value.nil? }
        end
      end
      expected_raw_bytes = values.size.to_u64 * 8_u64 + flat_inner_arrays * 8_u64 + flat_strings + flat_strings * 8_u64 + raw_bytes
      reader.array_array_nullable_string_mark_range_raw_bytes("payload", 0, reader.mark_count).should eq(expected_raw_bytes)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects shifted mark boundaries independently in each of the five physical streams" do
    parent = File.tempname("crystal-click-w61-reader-shifted-mark")
    Dir.mkdir(parent)
    base = File.join(parent, "base")
    values = w61_reader_values("z" * 128)

    begin
      w61_reader_write_part(base, values)
      {"payload.size0", "payload.size1", "payload.null", "payload.size", "payload"}.each_with_index do |stream, index|
        part = File.join(parent, "shifted-#{index}")
        FileUtils.cp_r(base, part)
        w61_reader_shift_mark(part, stream, 3, 1_u64)
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::WidePart.open_typed(part, "payload").read_array_array_nullable_string_mark_range("payload", 3, 1)
        end
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects non-boolean null-map bytes during direct raw-byte preflight" do
    parent = File.tempname("crystal-click-w61-reader-invalid-null")
    Dir.mkdir(parent)
    part = File.join(parent, "part")
    values = w61_reader_values("unused")

    begin
      w61_reader_write_part(part, values)
      chunks = w61_reader_stream_mark_chunks(values, "payload.null")
      chunks[0][0] = 2_u8
      w61_reader_reencode_mark_chunks(part, "payload.null", chunks)

      error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePart.open_typed(part, "payload").array_array_nullable_string_mark_range_raw_bytes("payload", 0, 1)
      end
      (error.message || "").should contain("null-map")
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "consumes physical String bytes hidden beneath NULL without exposing them" do
    parent = File.tempname("crystal-click-w61-reader-null-payload")
    Dir.mkdir(parent)
    part = File.join(parent, "part")
    values = w61_reader_values("unused")

    begin
      w61_reader_write_part(part, values)
      base_reader = CrystalClick::WidePart.open_typed(part, "payload")
      original_charge = base_reader.array_array_nullable_string_mark_range_raw_bytes("payload", 0, base_reader.mark_count)
      size_chunks = w61_reader_stream_mark_chunks(values, "payload.size")
      w61_reader_write_u64(size_chunks[0], 8, 1_u64)
      w61_reader_reencode_mark_chunks(part, "payload.size", size_chunks)

      raw_chunks = w61_reader_stream_mark_chunks(values, "payload")
      expanded_first_mark = Bytes.new(raw_chunks[0].size + 1)
      raw_chunks[0][0, 5].copy_to(expanded_first_mark)
      expanded_first_mark[5] = 0x5a_u8
      raw_chunks[0][5, raw_chunks[0].size - 5].copy_to(expanded_first_mark[6, raw_chunks[0].size - 5])
      raw_chunks[0] = expanded_first_mark
      w61_reader_reencode_mark_chunks(part, "payload", raw_chunks)

      reader = CrystalClick::WidePart.open_typed(part, "payload")
      reader.read_array_array_nullable_string_mark_range("payload", 0, reader.mark_count).should eq(values)
      reader.array_array_nullable_string_mark_range_raw_bytes("payload", 0, reader.mark_count).should eq(original_charge + 1_u64)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
