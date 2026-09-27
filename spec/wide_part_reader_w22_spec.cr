require "./spec_helper"

private def w22_reader_write_u64(io : IO, value : UInt64) : Nil
  8.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u64).to_u8) }
end

private def w22_reader_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
  value
end

private def w22_reader_set_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w22_reader_write_var_uint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w22_reader_encode_lz4_frame(raw : Bytes) : Bytes
  raise "W22 reader fixture cannot encode an empty frame" if raw.empty?
  extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
  payload_size = 1 + extension_size + raw.size
  compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
  frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
  header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
  frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
  4.times do |index|
    frame[header + 1 + index] = ((compressed_size >> (index * 8)) & 0xff).to_u8
    frame[header + 5 + index] = ((raw.size >> (index * 8)) & 0xff).to_u8
  end

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
  w22_reader_set_u64(frame, 0, hash[0])
  w22_reader_set_u64(frame, 8, hash[1])
  frame
end

private def w22_reader_rewrite_checksums(part_path : String) : Nil
  entries = CrystalClick::PartChecksums.open(part_path).entries
  payload = IO::Memory.new
  w22_reader_write_var_uint(payload, entries.size.to_u64)
  entries.each do |name, entry|
    bytes = File.read(File.join(part_path, name)).to_slice
    raw = entry.compressed ? CrystalClick::CompressedBlock.decode_all(bytes) : Bytes.new(0)
    w22_reader_write_var_uint(payload, name.bytesize.to_u64)
    payload.write(name.to_slice)
    w22_reader_write_var_uint(payload, bytes.size.to_u64)
    compressed_hash = CrystalClick::CityHashV1.file_hash(bytes)
    w22_reader_write_u64(payload, compressed_hash[0])
    w22_reader_write_u64(payload, compressed_hash[1])
    if entry.compressed
      payload.write_byte(1_u8)
      w22_reader_write_var_uint(payload, raw.size.to_u64)
      raw_hash = CrystalClick::CityHashV1.file_hash(raw)
      w22_reader_write_u64(payload, raw_hash[0])
      w22_reader_write_u64(payload, raw_hash[1])
    else
      payload.write_byte(0_u8)
    end
  end

  output = IO::Memory.new
  output << CrystalClick::PartChecksums::CHECKSUMS_HEADER
  output.write(w22_reader_encode_lz4_frame(payload.to_slice))
  File.write(File.join(part_path, "checksums.txt"), output.to_slice)
end

private def w22_reader_fixture(part_path : String, values : Array(String), rows_per_mark : Int32 = 2) : Nil
  keys = Array(UInt64).new(values.size) { |index| index.to_u64 + 1_u64 }
  CrystalClick::WidePartWriter.write_uint64_low_cardinality_string_pair(
    part_path,
    "pk",
    keys.to_unsafe.to_slice(keys.size),
    "payload",
    values.to_unsafe.to_slice(values.size),
    rows_per_mark: rows_per_mark
  )
end

private def w22_reader_stream_path(part_path : String, stream : String, extension : String = "bin") : String
  File.join(part_path, "#{CrystalClick::StreamName.hash(stream)}.#{extension}")
end

private def w22_reader_read_frame(part_path : String, stream : String, frame_index : Int) : Bytes
  encoded = File.read(w22_reader_stream_path(part_path, stream)).to_slice
  offset = 0_i64
  frame_index.times do
    offset = CrystalClick::CompressedBlock.decode_frame(encoded, offset).end_offset
  end
  CrystalClick::CompressedBlock.decode_frame(encoded, offset).output.dup
end

private def w22_reader_replace_frame(part_path : String, stream : String, frame_index : Int, raw : Bytes) : Nil
  path = w22_reader_stream_path(part_path, stream)
  encoded = File.read(path).to_slice.dup
  offset = 0_i64
  frame_index.times do
    offset = CrystalClick::CompressedBlock.decode_frame(encoded, offset).end_offset
  end
  old_frame = CrystalClick::CompressedBlock.decode_frame(encoded, offset)
  replacement = w22_reader_encode_lz4_frame(raw)
  raise "W22 reader mutation changed compressed frame size" unless replacement.size == old_frame.end_offset - offset
  replacement.copy_to(encoded.to_unsafe + offset, replacement.size)
  File.write(path, encoded)
  w22_reader_rewrite_checksums(part_path)
end

private def w22_reader_write_marks(part_path : String, stream : String, records : Array(Tuple(UInt64, UInt64, UInt64))) : Nil
  bytes = IO::Memory.new
  records.each do |record|
    record.each { |value| w22_reader_write_u64(bytes, value) }
  end
  File.write(w22_reader_stream_path(part_path, stream, "mrk2"), bytes.to_slice)
end

private def w22_reader_write_over_limit_marks(part_path : String, stream : String) : Int32
  data_mark_count = CrystalClick::WidePart::MAX_LOW_CARDINALITY_MARKS + 1
  record_count = data_mark_count + 1 # Include the EOF sentinel.
  mark_size = CrystalClick::WidePart::MARK_SIZE
  bytes = IO::Memory.new(record_count * mark_size)
  data_size = File.size(w22_reader_stream_path(part_path, stream)).to_u64
  dictionary_stream = stream.ends_with?(".dict")

  record_count.times do |record_index|
    sentinel = record_index == data_mark_count
    compressed_offset = sentinel ? data_size : 0_u64
    decompressed_offset = if sentinel
                            0_u64
                          elsif dictionary_stream
                            8_u64
                          else
                            0_u64
                          end
    rows = sentinel ? 0_u64 : 1_u64
    w22_reader_write_u64(bytes, compressed_offset)
    w22_reader_write_u64(bytes, decompressed_offset)
    w22_reader_write_u64(bytes, rows)
  end

  File.write(w22_reader_stream_path(part_path, stream, "mrk2"), bytes.to_slice)
  record_count
end

private def w22_reader_write_local_dictionary_streams(part_path : String, values : Array(String), rows_per_mark : Int32) : Nil
  dictionary = IO::Memory.new
  w22_reader_write_u64(dictionary, 1_u64)
  dictionary_marks = [] of Tuple(UInt64, UInt64, UInt64)
  index_data = IO::Memory.new
  index_marks = [] of Tuple(UInt64, UInt64, UInt64)
  row_start = 0

  while row_start < values.size
    rows = {rows_per_mark, values.size - row_start}.min
    dictionary_offset = dictionary.size.to_u64
    w22_reader_write_u64(dictionary, 1_u64)
    w22_reader_write_var_uint(dictionary, 0_u64)
    dictionary_marks << {0_u64, dictionary_offset, rows.to_u64}

    local_keys = [""]
    local_ids = Hash(String, UInt8).new
    local_ids[""] = 0_u8
    rows.times do |offset|
      value = values[row_start + offset]
      unless local_ids.has_key?(value)
        local_ids[value] = local_keys.size.to_u8
        local_keys << value
      end
    end

    index = IO::Memory.new
    w22_reader_write_u64(index, 0x600_u64)
    w22_reader_write_u64(index, local_keys.size.to_u64)
    local_keys.each do |value|
      w22_reader_write_var_uint(index, value.bytesize.to_u64)
      index.write(value.to_slice)
    end
    w22_reader_write_u64(index, rows.to_u64)
    rows.times do |offset|
      index.write_byte(local_ids[values[row_start + offset]])
    end
    frame = w22_reader_encode_lz4_frame(index.to_slice)
    index_marks << {index_data.size.to_u64, 0_u64, rows.to_u64}
    index_data.write(frame)
    row_start += rows
  end

  dictionary_frame = w22_reader_encode_lz4_frame(dictionary.to_slice)
  File.write(w22_reader_stream_path(part_path, "payload.dict"), dictionary_frame)
  dictionary_marks << {dictionary_frame.size.to_u64, 0_u64, 0_u64}
  w22_reader_write_marks(part_path, "payload.dict", dictionary_marks)

  File.write(w22_reader_stream_path(part_path, "payload"), index_data.to_slice)
  index_marks << {index_data.size.to_u64, 0_u64, 0_u64}
  w22_reader_write_marks(part_path, "payload", index_marks)
  w22_reader_rewrite_checksums(part_path)
end

describe CrystalClick::WidePart do
  it "admits only the exact LowCardinality(String) typed declaration" do
    CrystalClick::WidePart.supports_typed_type?("LowCardinality(String)").should be_true

    [
      "LowCardinality(String )",
      "LowCardinality( String)",
      "LowCardinality(FixedString(8))",
      "Nullable(LowCardinality(String))",
      "LowCardinality(String) trailing",
    ].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "reads shared-global dictionary values from full and later-start ranges" do
    parent = File.tempname("crystal-click-w22-reader-global")
    Dir.mkdir(parent)
    part_path = File.join(parent, "part")
    binary = String.new(Bytes[0x61_u8, 0_u8, 0xff_u8])
    values = ["", "alpha", binary, "alpha", "β", "\0"]

    begin
      w22_reader_fixture(part_path, values, 2)
      part = CrystalClick::WidePart.open_typed(part_path, "payload")
      part.read_low_cardinality_string_mark_range("payload", 0, part.mark_count).should eq(values)
      part.read_low_cardinality_string_mark_range("payload", 2, 1).should eq(values[4, 2])
      part.read_low_cardinality_string_mark_range("payload", 1, 2).should eq(values[2, 4])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "reads per-granule additional-key dictionaries from full and later-start ranges" do
    parent = File.tempname("crystal-click-w22-reader-local")
    Dir.mkdir(parent)
    part_path = File.join(parent, "part")
    binary = String.new(Bytes[0x80_u8, 0_u8, 0xff_u8])
    values = ["alpha", "", "beta", binary, binary, "gamma"]

    begin
      w22_reader_fixture(part_path, values, 2)
      w22_reader_write_local_dictionary_streams(part_path, values, 2)
      part = CrystalClick::WidePart.open_typed(part_path, "payload")
      part.read_low_cardinality_string_mark_range("payload", 0, part.mark_count).should eq(values)
      part.read_low_cardinality_string_mark_range("payload", 2, 1).should eq(values[4, 2])
      part.read_low_cardinality_string_mark_range("payload", 1, 2).should eq(values[2, 4])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects semantically malformed shared dictionaries, index flags, IDs, and marks" do
    cases = ["version", "flags", "id", "trailing", "marks"]
    cases.each do |probe|
      parent = File.tempname("crystal-click-w22-reader-corrupt-#{probe}")
      Dir.mkdir(parent)
      part_path = File.join(parent, "part")
      values = ["alpha", "beta"]

      begin
        w22_reader_fixture(part_path, values, 2)
        case probe
        when "version"
          raw = w22_reader_read_frame(part_path, "payload.dict", 0)
          w22_reader_set_u64(raw, 0, 2_u64)
          w22_reader_replace_frame(part_path, "payload.dict", 0, raw)
        when "flags"
          raw = w22_reader_read_frame(part_path, "payload", 0)
          w22_reader_set_u64(raw, 0, 0x400_u64)
          w22_reader_replace_frame(part_path, "payload", 0, raw)
        when "id"
          raw = w22_reader_read_frame(part_path, "payload", 0)
          raw[16] = 255_u8
          w22_reader_replace_frame(part_path, "payload", 0, raw)
        when "trailing"
          raw = w22_reader_read_frame(part_path, "payload.dict", 0)
          w22_reader_set_u64(raw, 8, 2_u64)
          w22_reader_replace_frame(part_path, "payload.dict", 0, raw)
        when "marks"
          marks_path = w22_reader_stream_path(part_path, "payload.dict", "mrk2")
          marks = File.read(marks_path).to_slice.dup
          w22_reader_set_u64(marks, 8, 9_u64)
          File.write(marks_path, marks)
          w22_reader_rewrite_checksums(part_path)
        end

        case probe
        when "version", "flags"
          expect_raises(CrystalClick::UnsupportedFormatError) do
            part = CrystalClick::WidePart.open_typed(part_path, "payload")
            part.read_low_cardinality_string_mark_range("payload", 0, 1)
          end
        when "id", "trailing", "marks"
          expect_raises(CrystalClick::CorruptPartError) do
            part = CrystalClick::WidePart.open_typed(part_path, "payload")
            part.read_low_cardinality_string_mark_range("payload", 0, 1)
          end
        end
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "rejects an out-of-range ID in an unselected later mark before returning mark zero" do
    parent = File.tempname("crystal-click-w22-reader-unselected-corruption")
    Dir.mkdir(parent)
    part_path = File.join(parent, "part")
    values = ["alpha", "beta", "gamma", "delta"]

    begin
      w22_reader_fixture(part_path, values, 2)
      later_mark = w22_reader_read_frame(part_path, "payload", 1)
      later_mark[16] = 255_u8
      w22_reader_replace_frame(part_path, "payload", 1, later_mark)

      part = CrystalClick::WidePart.open_typed(part_path, "payload")
      expect_raises(CrystalClick::CorruptPartError) do
        part.read_low_cardinality_string_mark_range("payload", 0, 1)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects oversized dictionary and index mark files before allocating mark arrays" do
    ["payload.dict", "payload"].each do |stream|
      parent = File.tempname("crystal-click-w22-reader-mark-limit")
      Dir.mkdir(parent)
      part_path = File.join(parent, "part")

      begin
        w22_reader_fixture(part_path, ["alpha", "beta"], 2)
        record_count = w22_reader_write_over_limit_marks(part_path, stream)
        mark_path = w22_reader_stream_path(part_path, stream, "mrk2")
        File.size(mark_path).should eq(record_count * CrystalClick::WidePart::MARK_SIZE)
        w22_reader_rewrite_checksums(part_path)

        error = expect_raises(CrystalClick::UnsupportedFormatError) do
          CrystalClick::WidePart.open_typed(part_path, "payload")
        end
        error.message.to_s.should contain("per-reader mark limit")
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "returns independent String objects for repeated shared dictionary IDs" do
    parent = File.tempname("crystal-click-w22-reader-string-ownership")
    Dir.mkdir(parent)
    part_path = File.join(parent, "part")
    values = ["repeat", "repeat"]

    begin
      w22_reader_fixture(part_path, values, 2)
      decoded = CrystalClick::WidePart.open_typed(part_path, "payload").read_low_cardinality_string_mark_range("payload", 0, 1)

      decoded.should eq(values)
      decoded[0].to_unsafe.should_not eq(decoded[1].to_unsafe)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
