require "../../src/crystal_click"

module CompactPartWriterW265Fixture
  extend self

  SLOT_COUNT   = 17
  RECORD_WIDTH = SLOT_COUNT * 16 + 8

  def write(
    destination : String,
    mark_format : CrystalClick::CompactMarkFormat = CrystalClick::CompactMarkFormat::Mrk4,
    transport_limits : CrystalClick::CompressedStreamLimits = CrystalClick::CompressedStreamLimits.new,
    reader_limits : CrystalClick::CompressedStreamLimits = CrystalClick::CompressedStreamLimits.new,
  ) : String
    CrystalClick::CompactPartWriter.write_uint64_columns(
      destination,
      CompactPartWriterW264Fixture::KEY_NAME,
      CompactPartWriterW264Fixture.keys,
      CompactPartWriterW264Fixture.columns,
      rows_per_mark: CompactPartWriterW264Fixture::ROWS_PER_MARK,
      frame_bytes: CompactPartWriterW264Fixture::FRAME_BYTES,
      transport_limits: transport_limits,
      reader_limits: reader_limits,
      mark_format: mark_format,
    )
  end

  # Copy only the flat, operation-owned part files. The source is never opened
  # for writing and the destination must be a fresh directory.
  def copy_part(source : String, destination : String) : Nil
    Dir.mkdir(destination)
    Dir.children(source).each do |name|
      FileUtils.cp(File.join(source, name), File.join(destination, name))
    end
  end

  # In mark 2, `gap.null` is a nonempty child lane followed by the `gap` value
  # lane. Moving only the latter's start to the former's start keeps a valid,
  # monotone outer mark grid while changing the selected callback association.
  def mutate_gap_child_start!(part_path : String) : Nil
    mark_path = File.join(part_path, "data.mrk4")
    original = File.read(mark_path).to_slice.dup
    mark_index = 2
    null_slot = 6
    value_slot = 7
    value_pair = mark_index * RECORD_WIDTH + value_slot * 16
    null_pair = mark_index * RECORD_WIDTH + null_slot * 16
    physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
    granule = physical.read_window("gap", mark_index, 1).granules.first
    null_shard = granule.shards.find { |shard| shard.slot_index == null_slot } ||
                 raise "gap.null shard is missing from the authenticated window"
    value_shard = granule.shards.find { |shard| shard.slot_index == value_slot } ||
                  raise "gap value shard is missing from the authenticated window"
    raise "fixture's selected child intervals are not distinct" if null_shard.logical_start == value_shard.logical_start

    old_pair = {read_u64_le(original, value_pair), read_u64_le(original, value_pair + 8)}
    replacement_pair = {read_u64_le(original, null_pair), read_u64_le(original, null_pair + 8)}
    raise "saved gap.null pair does not resolve to its authenticated interval" unless physical.logical_position(replacement_pair) == null_shard.logical_start
    raise "saved gap value pair does not resolve to its authenticated interval" unless physical.logical_position(old_pair) == value_shard.logical_start
    raise "fixture's selected child intervals are empty" unless replacement_pair != old_pair

    write_u64_le(original, value_pair, replacement_pair[0])
    write_u64_le(original, value_pair + 8, replacement_pair[1])
    File.open(mark_path, "wb") { |file| file.write(original) }
    reseal_checksums!(part_path)

    checksums = CrystalClick::PartChecksums.open(part_path)
    entry = checksums.entry("data.mrk4") || raise "MRK4 checksum entry disappeared"
    raise "mutated MRK4 checksum was not resealed" unless entry.file_hash == CrystalClick::CityHashV1.file_hash(original)
    nil
  end

  # Swap two existing callback names in the `gap` block without changing its
  # shape, sidecar size, or any data/mark bytes. The MRK4 sidecar is not listed
  # in checksums.txt, so leave that file byte-for-byte unchanged; the reader
  # must reject the semantically wrong physical roster from its metadata.
  def mutate_gap_roster!(part_path : String) : Nil
    path = File.join(part_path, "columns_substreams.txt")
    before = File.read(path)
    checksums_path = File.join(part_path, "checksums.txt")
    checksums_before = File.read(checksums_path)
    checksums = CrystalClick::PartChecksums.open(part_path)
    raise "MRK4 sidecar unexpectedly has a checksum entry" if checksums.entry("columns_substreams.txt")
    columns = CrystalClick::WidePart.parse_columns_metadata(File.read(File.join(part_path, "columns.txt")))
    blocks = CrystalClick::WidePart.parse_columns_substreams_metadata(before, columns)
    gap_index = blocks.index { |block| block[0] == "gap" } || raise "gap block missing"
    gap = blocks[gap_index]
    raise "gap callback roster changed" unless gap[1] == ["gap.size0", "gap.null", "gap"]
    gap[1][1], gap[1][2] = gap[1][2], gap[1][1]
    blocks[gap_index] = {gap[0], gap[1]}
    after = String.build do |io|
      io << "columns substreams version: 1\n"
      io << blocks.size << " columns:\n"
      blocks.each do |column_name, streams|
        io << streams.size << " substreams for column `" << column_name << "`:\n"
        streams.each { |stream_name| io << '\t' << stream_name << '\n' }
      end
    end
    raise "roster mutation unexpectedly changed the sidecar size" unless before.bytesize == after.bytesize
    File.write(path, after)
    raise "roster mutation changed checksums.txt" unless File.read(checksums_path) == checksums_before
    nil
  end

  private def reseal_checksums!(part_path : String) : Nil
    checksum_path = File.join(part_path, "checksums.txt")
    text = File.read(checksum_path).to_slice
    header = CrystalClick::PartChecksums::CHECKSUMS_HEADER.to_slice
    raise "unexpected checksum envelope" unless text.size >= header.size && text[0, header.size] == header
    payload = CrystalClick::CompressedBlock.decode_all(
      text[header.size, text.size - header.size],
      CrystalClick::PartChecksums::MAX_FRAME_COMPRESSED_BYTES,
      CrystalClick::PartChecksums::MAX_FRAME_DECOMPRESSED_BYTES,
      CrystalClick::PartChecksums::MAX_PAYLOAD_BYTES,
    )
    raw_entries = parse_raw_entries(payload)
    records = Array(CrystalClick::PartWriterInfrastructure::ChecksumRecord).new(raw_entries.size)
    raw_entries.each do |entry|
      name, _old_file_hash, compressed, raw_size, raw_hash = entry
      file_bytes = File.read(File.join(part_path, name)).to_slice
      current_hash = CrystalClick::CityHashV1.file_hash(file_bytes)
      if compressed
        records << CrystalClick::PartWriterInfrastructure::ChecksumRecord.new(
          name,
          file_bytes.size.to_u64,
          current_hash,
          true,
          raw_size,
          raw_hash,
        )
      else
        records << CrystalClick::PartWriterInfrastructure::ChecksumRecord.new(
          name,
          file_bytes.size.to_u64,
          current_hash,
          false,
        )
      end
    end
    CrystalClick::PartWriterInfrastructure::PartChecksumsWriter.write(part_path, records)
  end

  private def parse_raw_entries(payload : Bytes) : Array(Tuple(String, {UInt64, UInt64}, Bool, UInt64?, {UInt64, UInt64}?))
    cursor = 0
    count, cursor = read_var_uint(payload, cursor)
    entries = Array(Tuple(String, {UInt64, UInt64}, Bool, UInt64?, {UInt64, UInt64}?)).new(count.to_i)
    count.to_i.times do
      name_size, cursor = read_var_uint(payload, cursor)
      name = String.new(payload[cursor, name_size.to_i])
      cursor += name_size.to_i
      physical_size, cursor = read_var_uint(payload, cursor)
      file_hash = {read_u64_le(payload, cursor), read_u64_le(payload, cursor + 8)}
      cursor += 16
      flag = payload[cursor]? || raise "truncated checksum flag"
      cursor += 1
      compressed = flag == 1_u8
      raw_size = nil.as(UInt64?)
      raw_hash = nil.as({UInt64, UInt64}?)
      if compressed
        size, cursor = read_var_uint(payload, cursor)
        raw_size = size
        raw_hash = {read_u64_le(payload, cursor), read_u64_le(payload, cursor + 8)}
        cursor += 16
      elsif flag != 0_u8
        raise "unsupported checksum compression flag"
      end
      entries << {name, file_hash, compressed, raw_size, raw_hash}
    end
    raise "trailing checksum payload" unless cursor == payload.size
    entries
  end

  private def read_var_uint(bytes : Bytes, cursor : Int32) : Tuple(UInt64, Int32)
    value = 0_u64
    shift = 0
    loop do
      byte = bytes[cursor]? || raise "truncated checksum varUInt"
      cursor += 1
      value |= (byte & 0x7f).to_u64 << shift
      return {value, cursor} if (byte & 0x80) == 0
      shift += 7
      raise "oversized checksum varUInt" if shift > 63
    end
  end

  private def read_u64_le(bytes : Bytes, offset : Int) : UInt64
    value = 0_u64
    8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
    value
  end

  private def write_u64_le(bytes : Bytes, offset : Int, value : UInt64) : Nil
    8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff).to_u8 }
  end
end
