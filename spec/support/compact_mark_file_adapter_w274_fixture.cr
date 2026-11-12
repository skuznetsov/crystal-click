require "../../scripts/support/compact_physical_context_w259_fixture"

module CompactMarkFileAdapterW274Fixture
  extend self

  def mark_name(mode : CrystalClick::CompactMarkFormat) : String
    case mode
    when .mrk3? then "data.mrk3"
    when .mrk4? then "data.mrk4"
    else             raise ArgumentError.new("unsupported W274 fixture mark mode")
    end
  end

  def compressed_mark_name(mode : CrystalClick::CompactMarkFormat) : String
    case mode
    when .mrk3? then "data.cmrk3"
    when .mrk4? then "data.cmrk4"
    else             raise ArgumentError.new("unsupported W274 fixture mark mode")
    end
  end

  # The W259 source is built afresh for every invocation, then copied before
  # the caller receives it. Adversarial mutations therefore cannot leak back
  # into the literal source fixture or a sibling case.
  def with_isolated_part(mode : CrystalClick::CompactMarkFormat, compressed : Bool = true, &) : Nil
    root = File.tempname("crystal-click-w274-mark-adapter")
    source = File.join(root, "source")
    part = File.join(root, "part")
    Dir.mkdir_p(root)
    begin
      CompactPhysicalContextW259Fixture.build(source, mode)
      compress_marks!(source, mode) if compressed
      FileUtils.cp_r(source, part)
      yield part
    ensure
      FileUtils.rm_rf(root)
    end
    nil
  end

  def raw_marks_from_plain_part(part_path : String, mode : CrystalClick::CompactMarkFormat) : Bytes
    File.read(File.join(part_path, mark_name(mode))).to_slice.dup
  end

  def compress_marks!(part_path : String, mode : CrystalClick::CompactMarkFormat) : Bytes
    raw = raw_marks_from_plain_part(part_path, mode)
    write_compressed_marks!(part_path, mode, raw)
    raw
  end

  def write_compressed_marks!(
    part_path : String,
    mode : CrystalClick::CompactMarkFormat,
    raw_marks : Bytes,
  ) : Nil
    plain_path = File.join(part_path, mark_name(mode))
    File.delete(plain_path) if File.exists?(plain_path)
    compressed_name = compressed_mark_name(mode)
    write_compressed_sidecar!(part_path, compressed_name, compressed_frame(raw_marks), raw_marks)
    nil
  end

  def write_compressed_sidecar!(
    part_path : String,
    sidecar_name : String,
    physical_bytes : Bytes,
    raw_marks : Bytes,
    raw_size_override : UInt64? = nil,
    raw_hash_override : Tuple(UInt64, UInt64)? = nil,
    physical_hash_override : Tuple(UInt64, UInt64)? = nil,
  ) : Nil
    File.write(File.join(part_path, sidecar_name), physical_bytes)
    refresh_checksums(
      part_path,
      sidecar_name,
      raw_marks,
      true,
      raw_size_override,
      raw_hash_override,
      physical_hash_override
    )
    nil
  end

  def write_plain_sidecar!(part_path : String, sidecar_name : String, raw_marks : Bytes) : Nil
    File.write(File.join(part_path, sidecar_name), raw_marks)
    refresh_checksums(part_path)
    nil
  end

  def refresh_checksums(
    part_path : String,
    compressed_name : String? = nil,
    raw_marks : Bytes? = nil,
    compressed_flag_override : Bool? = nil,
    raw_size_override : UInt64? = nil,
    raw_hash_override : Tuple(UInt64, UInt64)? = nil,
    physical_hash_override : Tuple(UInt64, UInt64)? = nil,
  ) : Nil
    names = Dir.children(part_path).reject { |name| name == "checksums.txt" }.sort
    payload = IO::Memory.new
    write_varuint(payload, names.size.to_u64)
    names.each do |name|
      physical = File.read(File.join(part_path, name)).to_slice
      write_varuint(payload, name.bytesize.to_u64)
      payload.write(name.to_slice)
      write_varuint(payload, physical.size.to_u64)
      physical_hash = CrystalClick::CityHashV1.file_hash(physical)
      if name == compressed_name
        if override = physical_hash_override
          physical_hash = override
        end
      end
      write_hash(payload, physical_hash)

      is_compressed_entry = name == compressed_name
      is_compressed_entry = compressed_flag_override unless compressed_flag_override.nil? || name != compressed_name
      payload.write_byte(is_compressed_entry ? 1_u8 : 0_u8)
      if is_compressed_entry
        raw = raw_marks || raise ArgumentError.new("compressed W274 entry needs independent raw marks")
        write_varuint(payload, raw_size_override || raw.size.to_u64)
        write_hash(payload, raw_hash_override || CrystalClick::CityHashV1.file_hash(raw))
      end
    end

    encoded = CrystalClick::CompressedMarkWriter.encode(
      payload.to_slice,
      [0_u64, payload.size.to_u64],
      [1_u64],
      frame_bytes: 4096
    )
    manifest = IO::Memory.new
    manifest << CrystalClick::PartChecksums::CHECKSUMS_HEADER
    manifest.write(encoded.data)
    File.write(File.join(part_path, "checksums.txt"), manifest.to_slice)
    nil
  end

  def compressed_frame(raw : Bytes) : Bytes
    CrystalClick::CompressedMarkWriter.encode(
      raw,
      [0_u64, raw.size.to_u64],
      [1_u64],
      frame_bytes: 4096
    ).data
  end

  def compressed_frames(raw : Bytes, frame_bytes : Int) : Bytes
    CrystalClick::CompressedMarkWriter.encode(
      raw,
      [0_u64, raw.size.to_u64],
      [1_u64],
      frame_bytes: frame_bytes
    ).data
  end

  # Returns physical frame starts after checking each advertised extent stays
  # within the selected bytes. It deliberately does not authenticate frames.
  def compressed_frame_offsets(physical : Bytes) : Array(Int32)
    offsets = [] of Int32
    offset = 0
    while offset < physical.size
      raise ArgumentError.new("truncated W274 compressed frame header") if offset > physical.size - CrystalClick::CompressedBlock::FRAME_HEADER_SIZE
      compressed_size = read_u32(physical, offset + CrystalClick::CompressedBlock::CHECKSUM_SIZE + 1).to_i
      frame_end = offset + CrystalClick::CompressedBlock::CHECKSUM_SIZE + compressed_size
      raise ArgumentError.new("invalid W274 compressed frame extent") if compressed_size < CrystalClick::CompressedBlock::HEADER_SIZE || frame_end > physical.size
      offsets << offset.to_i32
      offset = frame_end
    end
    offsets
  end

  # Uncompressed byte coordinates of every interior frame boundary. A value
  # not divisible by eight proves a UInt64 mark field is split across frames.
  def internal_frame_uncompressed_boundaries(physical : Bytes) : Array(Int32)
    boundaries = [] of Int32
    frame_offsets = compressed_frame_offsets(physical)
    decoded_offset = 0
    frame_offsets.each_with_index do |frame_offset, index|
      decoded_offset += read_u32(
        physical,
        frame_offset + CrystalClick::CompressedBlock::CHECKSUM_SIZE + 5
      ).to_i
      boundaries << decoded_offset.to_i32 if index < frame_offsets.size - 1
    end
    boundaries
  end

  def mark_width(mode : CrystalClick::CompactMarkFormat) : Int32
    (CompactPhysicalContextW259Fixture.slots(mode).size * 16 + 8).to_i32
  end

  def read_u64(bytes : Bytes, offset : Int) : UInt64
    raise ArgumentError.new("W274 fixture UInt64 read is out of range") if offset < 0 || offset > bytes.size - 8
    value = 0_u64
    8.times { |index| value |= bytes[offset + index].to_u64 << (8 * index) }
    value
  end

  def read_u32(bytes : Bytes, offset : Int) : UInt32
    raise ArgumentError.new("W274 fixture UInt32 read is out of range") if offset < 0 || offset > bytes.size - 4
    value = 0_u32
    4.times { |index| value |= bytes[offset + index].to_u32 << (8 * index) }
    value
  end

  def write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
    raise ArgumentError.new("W274 fixture UInt64 write is out of range") if offset < 0 || offset > bytes.size - 8
    8.times { |index| bytes[offset + index] = ((value >> (8 * index)) & 0xff_u64).to_u8 }
    nil
  end

  private def write_varuint(io : IO, original : UInt64) : Nil
    value = original
    while value >= 0x80_u64
      io.write_byte(((value & 0x7f_u64) | 0x80_u64).to_u8)
      value >>= 7
    end
    io.write_byte(value.to_u8)
  end

  private def write_hash(io : IO, hash : Tuple(UInt64, UInt64)) : Nil
    8.times { |index| io.write_byte(((hash[0] >> (index * 8)) & 0xff_u64).to_u8) }
    8.times { |index| io.write_byte(((hash[1] >> (index * 8)) & 0xff_u64).to_u8) }
  end
end
