require "../../src/crystal_click"

module CompactPhysicalContextW259Fixture
  extend self

  COLUMNS = [
    {"alpha", "String"},
    {"beta", "String"},
    {"gamma", "String"},
  ] of {String, String}

  MRK4_SUBSTREAMS = [
    {"alpha", ["shared", "payload"]},
    {"beta", ["shared"]},
    {"gamma", ["offsets"]},
  ] of {String, Array(String)}

  MRK3_SHARDS = [
    ["A0".to_slice, "B0".to_slice, Bytes.empty],
    [Bytes.empty, "B1".to_slice, "G1".to_slice],
    ["A2".to_slice, Bytes.empty, "G2".to_slice],
    ["A3".to_slice, "B3".to_slice, Bytes.empty],
  ] of Array(Bytes)

  # The repeated `shared` name belongs to two different column blocks and is
  # intentional. Empty shards are also intentional: equal positions are
  # distinct ordered slots, not duplicate mark records.
  MRK4_SHARDS = [
    ["a0".to_slice, Bytes.empty, "b0".to_slice, Bytes.empty],
    [Bytes.empty, "a1".to_slice, "b1".to_slice, "g1".to_slice],
    ["a2".to_slice, Bytes.empty, Bytes.empty, "g2".to_slice],
    ["a3".to_slice, "a3p".to_slice, "b3".to_slice, Bytes.empty],
  ] of Array(Bytes)

  ROW_COUNTS = [2_u64, 2_u64, 2_u64, 2_u64]
  COUNT_TEXT = "8\n"

  def mark_name(mode : CrystalClick::CompactMarkFormat) : String
    case mode
    when .mrk3? then "data.mrk3"
    when .mrk4? then "data.mrk4"
    else             raise ArgumentError.new("unsupported W259 fixture mark mode")
    end
  end

  def slots(mode : CrystalClick::CompactMarkFormat) : Array({String, String?})
    case mode
    when .mrk3?
      COLUMNS.map { |name, _type| {name, nil.as(String?)} }
    when .mrk4?
      MRK4_SUBSTREAMS.flat_map do |column, names|
        names.map { |name| {column, name.as(String?)} }
      end
    else
      raise ArgumentError.new("unsupported W259 fixture mark mode")
    end
  end

  def shards(mode : CrystalClick::CompactMarkFormat) : Array(Array(Bytes))
    source = mode.mrk3? ? MRK3_SHARDS : MRK4_SHARDS
    source.map { |mark| mark.map(&.dup) }
  end

  def build(part_path : String, mode : CrystalClick::CompactMarkFormat) : Nil
    Dir.mkdir_p(part_path)
    File.write(File.join(part_path, "columns.txt"), columns_text)
    File.write(File.join(part_path, "count.txt"), COUNT_TEXT)
    File.write(File.join(part_path, "#{mark_name(mode)}"), mark_bytes(mode))
    if mode.mrk4?
      File.write(File.join(part_path, "columns_substreams.txt"), substreams_text)
    end

    raw = raw_bytes(mode)
    queries = cumulative_offsets(mode)
    positioned = CrystalClick::CompressedMarkWriter.encode_with_positions(
      raw,
      [0_u64, raw.size.to_u64],
      [ROW_COUNTS.sum],
      queries,
      frame_bytes: 7
    )
    File.write(File.join(part_path, "data.bin"), positioned.files.data)
    File.write(File.join(part_path, mark_name(mode)), mark_bytes(mode, positioned.positions))
    refresh_checksums(part_path)
    nil
  end

  def columns_text : String
    String.build do |io|
      io << "columns format version: 1\n"
      io << COLUMNS.size << " columns:\n"
      COLUMNS.each do |name, type|
        io << '`' << name << "` " << type << '\n'
      end
    end
  end

  def substreams_text(substreams : Array({String, Array(String)}) = MRK4_SUBSTREAMS) : String
    String.build do |io|
      io << "columns substreams version: 1\n"
      io << substreams.size << " columns:\n"
      substreams.each do |name, stream_names|
        io << stream_names.size << " substreams for column `" << name << "`:\n"
        stream_names.each { |stream| io << '\t' << stream << '\n' }
      end
    end
  end

  def raw_bytes(mode : CrystalClick::CompactMarkFormat) : Bytes
    raw = IO::Memory.new
    shards(mode).each do |mark|
      mark.each { |shard| raw.write(shard) }
    end
    raw.to_slice
  end

  # One query coordinate is emitted at the start of each physical slot, plus
  # an exact logical EOF query for the terminal record.
  def cumulative_offsets(mode : CrystalClick::CompactMarkFormat) : Array(UInt64)
    offsets = [0_u64]
    cursor = 0_u64
    shards(mode).each do |mark|
      mark.each do |shard|
        cursor += shard.size.to_u64
        offsets << cursor
      end
    end
    offsets
  end

  def mark_bytes(
    mode : CrystalClick::CompactMarkFormat,
    positions : Array(Tuple(UInt64, UInt64))? = nil,
  ) : Bytes
    mode_slots = slots(mode).size
    mark_count = ROW_COUNTS.size
    width = mode_slots * 16 + 8
    output = Bytes.new((mark_count + 1) * width, 0_u8)
    if coordinates = positions
      raise "W259 fixture has an incorrect position count" unless coordinates.size == (mark_count * mode_slots) + 1
      mark_count.times do |mark|
        mode_slots.times do |slot|
          write_position(output, mark * width + slot * 16, coordinates[mark * mode_slots + slot])
        end
        write_u64(output, mark * width + mode_slots * 16, ROW_COUNTS[mark])
      end
      eof = coordinates.last
      mode_slots.times do |slot|
        write_position(output, mark_count * width + slot * 16, eof)
      end
      write_u64(output, mark_count * width + mode_slots * 16, 0_u64)
    end
    output
  end

  def rewrite_marks(part_path : String, mode : CrystalClick::CompactMarkFormat, bytes : Bytes) : Nil
    File.write(File.join(part_path, mark_name(mode)), bytes)
    refresh_checksums(part_path)
  end

  def copy_position(
    marks : Bytes,
    mode : CrystalClick::CompactMarkFormat,
    source_mark : Int,
    source_slot : Int,
    target_mark : Int,
    target_slot : Int,
  ) : Nil
    width = slots(mode).size * 16 + 8
    source = source_mark * width + source_slot * 16
    target = target_mark * width + target_slot * 16
    marks[source, 16].copy_to(marks[target, 16])
  end

  def set_position(
    marks : Bytes,
    mode : CrystalClick::CompactMarkFormat,
    mark : Int,
    slot : Int,
    compressed_offset : UInt64,
    decompressed_offset : UInt64,
  ) : Nil
    width = slots(mode).size * 16 + 8
    offset = mark * width + slot * 16
    write_u64(marks, offset, compressed_offset)
    write_u64(marks, offset + 8, decompressed_offset)
  end

  def last_frame_end_position(data : Bytes) : Tuple(UInt64, UInt64)
    offset = 0
    last_offset = 0_u64
    last_decompressed_size = 0_u64
    while offset < data.size
      last_offset = offset.to_u64
      compressed_size = read_u32(data, offset + CrystalClick::CompressedBlock::CHECKSUM_SIZE + 1)
      last_decompressed_size = read_u32(data, offset + CrystalClick::CompressedBlock::CHECKSUM_SIZE + 5).to_u64
      offset += CrystalClick::CompressedBlock::CHECKSUM_SIZE + compressed_size.to_i
    end
    raise "W259 fixture has no compressed frames" if offset != data.size || offset == 0
    {last_offset, last_decompressed_size}
  end

  def corrupt_frame_payload(part_path : String, frame_index : Int) : Nil
    data_path = File.join(part_path, "data.bin")
    data = File.read(data_path).to_slice.dup
    offset = 0
    frame = 0
    while frame < frame_index
      compressed_size = read_u32(data, offset + CrystalClick::CompressedBlock::CHECKSUM_SIZE + 1)
      offset += CrystalClick::CompressedBlock::CHECKSUM_SIZE + compressed_size.to_i
      frame += 1
    end
    raise "W259 fixture frame index is outside data.bin" if offset >= data.size
    payload = offset + CrystalClick::CompressedBlock::FRAME_HEADER_SIZE
    raise "W259 fixture frame has no payload" if payload >= data.size
    data[payload] = data[payload] ^ 1_u8
    File.write(data_path, data)
    refresh_checksums(part_path)
    nil
  end

  def refresh_checksums(part_path : String) : Nil
    names = Dir.children(part_path).reject { |name| name == "checksums.txt" }.sort
    payload = IO::Memory.new
    write_varuint(payload, names.size.to_u64)
    names.each do |name|
      physical = File.read(File.join(part_path, name)).to_slice
      write_varuint(payload, name.bytesize.to_u64)
      payload.write(name.to_slice)
      write_varuint(payload, physical.size.to_u64)
      write_hash(payload, CrystalClick::CityHashV1.file_hash(physical))
      payload.write_byte(0_u8)
    end
    manifest = IO::Memory.new
    manifest << CrystalClick::PartChecksums::CHECKSUMS_HEADER
    manifest.write(literal_lz4_frame(payload.to_slice))
    File.write(File.join(part_path, "checksums.txt"), manifest.to_slice)
    nil
  end

  private def write_position(output : Bytes, offset : Int, position : Tuple(UInt64, UInt64)) : Nil
    write_u64(output, offset, position[0])
    write_u64(output, offset + 8, position[1])
  end

  def write_u64(output : Bytes, offset : Int, value : UInt64) : Nil
    8.times { |index| output[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
  end

  private def write_varuint(io : IO, original : UInt64) : Nil
    value = original
    while value >= 0x80_u64
      io.write_byte(((value & 0x7f_u64) | 0x80_u64).to_u8)
      value >>= 7
    end
    io.write_byte(value.to_u8)
  end

  private def write_hash(io : IO, hash : {UInt64, UInt64}) : Nil
    8.times { |index| io.write_byte(((hash[0] >> (index * 8)) & 0xff_u64).to_u8) }
    8.times { |index| io.write_byte(((hash[1] >> (index * 8)) & 0xff_u64).to_u8) }
  end

  private def literal_lz4_frame(raw : Bytes) : Bytes
    raise "W259 checksum envelope cannot be empty" if raw.empty?
    extension_size = raw.size < 15 ? 0 : ((raw.size - 15) // 255) + 1
    payload_size = 1 + extension_size + raw.size
    compressed_size = CrystalClick::CompressedBlock::HEADER_SIZE + payload_size
    frame = Bytes.new(CrystalClick::CompressedBlock::FRAME_HEADER_SIZE + payload_size, 0_u8)
    header = CrystalClick::CompressedBlock::CHECKSUM_SIZE
    frame[header] = CrystalClick::CompressedBlock::METHOD_LZ4
    write_u32(frame, header + 1, compressed_size.to_u32)
    write_u32(frame, header + 5, raw.size.to_u32)
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
    write_u64(frame, 0, hash[0])
    write_u64(frame, 8, hash[1])
    frame
  end

  private def write_u32(output : Bytes, offset : Int, value : UInt32) : Nil
    4.times { |index| output[offset + index] = ((value >> (index * 8)) & 0xff_u32).to_u8 }
  end

  private def read_u32(bytes : Bytes, offset : Int) : UInt32
    bytes[offset].to_u32 |
      (bytes[offset + 1].to_u32 << 8) |
      (bytes[offset + 2].to_u32 << 16) |
      (bytes[offset + 3].to_u32 << 24)
  end
end
