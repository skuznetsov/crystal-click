require "../src/crystal_click"
require "../spec/support/compact_part_writer_w266_fixture"
require "file_utils"
require "json"

module CompactPartWriterW266Helper
  extend self

  FORMAT          = "compact_part_writer_w266_helper_v1"
  MAX_RAW_BYTES   = 64_i64 * 1024 * 1024
  MAX_FRAME_COUNT = 100_000
  alias LcMarkAudit = NamedTuple(mark: Int32, prefix_version: UInt64, prefix_bytes: Int32, dictionary_bytes: Int32, dictionary_hex: String, index_bytes: Int32, index_hex: String, flags: UInt64?)
  alias LcSiteAudit = NamedTuple(column: String, prefix_stream: String, dictionary_stream: String, index_stream: String, marks: Array(LcMarkAudit))
  alias MarkPairAudit = NamedTuple(slot: Int32, compressed_offset: UInt64, decompressed_offset: UInt64, logical_position: Int64)
  alias MarkRecordAudit = NamedTuple(mark: Int32, row_count: UInt64, pairs: Array(MarkPairAudit))
  alias MarkTapeAudit = NamedTuple(file: String, slot_count: Int32, record_width: Int32, byte_size: Int32, compressed_size: UInt64, raw_size: UInt64, real_mark_rows: Array(UInt64), records: Array(MarkRecordAudit))
  WINDOWS = {
    "full"   => {0, 4},
    "middle" => {1, 2},
    "last"   => {3, 1},
    "empty"  => {4, 0},
  }
  LOW_CARDINALITY_SITES = [
    {column: "root", prefix: "root.dict_prefix", dictionary: "root.dict", index: "root"},
    {column: "maybe", prefix: "maybe.dict_prefix", dictionary: "maybe.dict", index: "maybe"},
    {column: "items", prefix: "items.dict_prefix", dictionary: "items.dict", index: "items"},
  ]

  def run(args : Array(String)) : String
    action = args[0]? || raise ArgumentError.new("expected audit or write")
    case action
    when "audit"
      raise ArgumentError.new("usage: helper audit PART") unless args.size == 2
      report(validate_part(args[1]), action)
    when "write"
      raise ArgumentError.new("usage: helper write PART mrk3|mrk4") unless args.size == 3
      part = validate_new_destination(args[1])
      format = case args[2]?
               when "mrk3" then CrystalClick::CompactMarkFormat::Mrk3
               when "mrk4" then CrystalClick::CompactMarkFormat::Mrk4
               else             raise ArgumentError.new("mark format must be mrk3 or mrk4")
               end
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part,
        CompactPartWriterW266Fixture::KEY_NAME,
        CompactPartWriterW266Fixture.keys,
        CompactPartWriterW266Fixture.columns,
        rows_per_mark: CompactPartWriterW266Fixture::ROWS_PER_MARK,
        frame_bytes: CompactPartWriterW266Fixture::FRAME_BYTES,
        mark_format: format,
      )
      report(part, action)
    when "write-only"
      raise ArgumentError.new("usage: helper write-only PART mrk3|mrk4") unless args.size == 3
      part = validate_new_destination(args[1])
      format = case args[2]?
               when "mrk3" then CrystalClick::CompactMarkFormat::Mrk3
               when "mrk4" then CrystalClick::CompactMarkFormat::Mrk4
               else             raise ArgumentError.new("mark format must be mrk3 or mrk4")
               end
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part,
        CompactPartWriterW266Fixture::KEY_NAME,
        CompactPartWriterW266Fixture.keys,
        CompactPartWriterW266Fixture.columns,
        rows_per_mark: CompactPartWriterW266Fixture::ROWS_PER_MARK,
        frame_bytes: CompactPartWriterW266Fixture::FRAME_BYTES,
        mark_format: format,
      )
      JSON.build do |json|
        json.object do
          json.field "format", FORMAT
          json.field "action", action
          json.field "status", "ok"
          json.field "path", part
          json.field "mark_format", args[2]
        end
      end
    when "copy-mutant"
      raise ArgumentError.new("usage: helper copy-mutant prefix SOURCE DESTINATION") unless args.size == 4
      raise ArgumentError.new("only the prefix mutant is supported") unless args[1] == "prefix"
      source = validate_part(args[2])
      destination = validate_new_destination(args[3])
      FileUtils.cp_r(source, destination)
      poison = poison_middle_prefix!(destination)
      JSON.build do |json|
        json.object do
          json.field "format", FORMAT
          json.field "action", action
          json.field "status", "ok"
          json.field "kind", "prefix"
          json.field "source_path", source
          json.field "mutant_path", destination
          json.field "changed_files", ["checksums.txt", "data.bin"]
          json.field "poisoned_mark", 1
          json.field "poisoned_column", "root"
          json.field "prefix_version", 2
          json.field "prefix_logical_offset", poison[:logical_offset]
          json.field "prefix_byte_before", poison[:prefix_byte_before]
          json.field "prefix_byte_after", poison[:prefix_byte_after]
          json.field "raw_changed_offsets" do
            json.array { poison[:raw_changed_offsets].each { |offset| json.number offset } }
          end
          json.field "compressed_size", poison[:compressed_size]
          json.field "raw_size", poison[:raw_size]
          json.field "frame_count", poison[:frame_count]
        end
      end
    when "inspect-outcome"
      raise ArgumentError.new("usage: helper inspect-outcome PART COLUMN [FIRST_MARK MARK_COUNT]") unless args.size == 3 || args.size == 5
      part = validate_part(args[1])
      column = args[2]
      first_mark = args[3]?.try(&.to_i) || 0
      mark_count = args[4]?.try(&.to_i)
      begin
        type = if column == CompactPartWriterW266Fixture::KEY_NAME
                 CrystalClick::BinaryDataType.primitive("UInt64")
               else
                 CompactPartWriterW266Fixture.types[column]? || raise ArgumentError.new("unknown fixture column")
               end
        reader = CrystalClick::CompactBinaryBulkColumnReader.open(part, column, type)
        count = mark_count || reader.mark_count
        values = reader.read_marks(first_mark, count)
        JSON.build do |json|
          json.object do
            json.field "format", FORMAT
            json.field "action", action
            json.field "status", "accepted"
            json.field "column", column
            json.field "first_mark", first_mark
            json.field "mark_count", count
            json.field "row_count", values.sum(&.size)
            if column == CompactPartWriterW266Fixture::KEY_NAME
              json.field "key_values", values.flatten.map(&.as_uint64).map(&.to_s)
            end
          end
        end
      rescue error : CrystalClick::Error
        JSON.build do |json|
          json.object do
            json.field "format", FORMAT
            json.field "action", action
            json.field "status", "rejected"
            json.field "column", column
            json.field "first_mark", first_mark
            json.field "mark_count", mark_count
            json.field "error_class", error.class.name
            json.field "error_message", error.message
          end
        end
      end
    else
      raise ArgumentError.new("unknown helper action: #{action}")
    end
  end

  private def validate_new_destination(path : String) : String
    expanded = File.expand_path(path)
    raise ArgumentError.new("part destination already exists or is symlinked") if File.exists?(expanded) || File.symlink?(expanded)
    parent = File.dirname(expanded)
    raise ArgumentError.new("part parent must already exist and be a directory") unless Dir.exists?(parent) && !File.symlink?(parent)
    expanded
  end

  private def validate_part(path : String) : String
    expanded = File.expand_path(path)
    raise ArgumentError.new("part must be a regular non-symlink directory") unless Dir.exists?(expanded) && !File.symlink?(expanded)
    expanded
  end

  private def read_bytes(path : String) : Bytes
    expanded = File.expand_path(path)
    unless File.exists?(expanded) && File.file?(expanded) && !File.symlink?(expanded)
      raise CrystalClick::CorruptPartError.new("W266 expected a regular non-symlink file")
    end
    size = File.size(expanded)
    raise CrystalClick::CorruptPartError.new("W266 file exceeds bounded read size") if size > MAX_RAW_BYTES + 1024_i64 * 1024
    File.read(expanded).to_slice.dup
  end

  private def read_u64_le(bytes : Bytes, offset : Int) : UInt64
    raise CrystalClick::CorruptPartError.new("truncated W266 LowCardinality word") if offset < 0 || offset > bytes.size - 8
    value = 0_u64
    8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
    value
  end

  private def read_u32_le(bytes : Bytes, offset : Int) : UInt32
    raise CrystalClick::CorruptPartError.new("truncated W266 frame word") if offset < 0 || offset > bytes.size - 4
    bytes[offset].to_u32 |
      (bytes[offset + 1].to_u32 << 8) |
      (bytes[offset + 2].to_u32 << 16) |
      (bytes[offset + 3].to_u32 << 24)
  end

  private def independent_frame_census(data : Bytes) : Tuple(
    Array(NamedTuple(compressed_offset: UInt64, logical_start: UInt64, decoded_size: UInt64)),
    UInt64,
  )
    raise CrystalClick::CorruptPartError.new("W266 data.bin is empty or exceeds frame-census bounds") if data.empty? || data.size > MAX_RAW_BYTES
    frames = Array(NamedTuple(compressed_offset: UInt64, logical_start: UInt64, decoded_size: UInt64)).new
    compressed_offset = 0_i64
    logical_start = 0_u64
    while compressed_offset < data.size.to_i64
      if frames.size >= MAX_FRAME_COUNT || compressed_offset > data.size.to_i64 - CrystalClick::CompressedBlock::FRAME_HEADER_SIZE
        raise CrystalClick::CorruptPartError.new("W266 frame census is truncated or oversized")
      end
      header = compressed_offset.to_i + CrystalClick::CompressedBlock::CHECKSUM_SIZE
      compressed_size = read_u32_le(data, header + 1).to_i64
      decoded_size = read_u32_le(data, header + 5).to_u64
      unless data[header] == CrystalClick::CompressedBlock::METHOD_LZ4 &&
             compressed_size >= CrystalClick::CompressedBlock::HEADER_SIZE &&
             decoded_size > 0_u64 && decoded_size <= MAX_RAW_BYTES.to_u64
        raise CrystalClick::CorruptPartError.new("W266 frame is outside the bounded LZ4 profile")
      end
      frame_size = CrystalClick::CompressedBlock::CHECKSUM_SIZE.to_i64 + compressed_size
      if frame_size > data.size.to_i64 - compressed_offset || decoded_size > UInt64::MAX - logical_start
        raise CrystalClick::CorruptPartError.new("W266 frame extent overflows data.bin")
      end
      frames << {compressed_offset: compressed_offset.to_u64, logical_start: logical_start, decoded_size: decoded_size}
      compressed_offset += frame_size
      logical_start += decoded_size
    end
    raise CrystalClick::CorruptPartError.new("W266 frame census has trailing bytes") unless compressed_offset == data.size.to_i64
    {frames, logical_start}
  end

  private def independent_logical_position(
    compressed_offset : UInt64,
    decompressed_offset : UInt64,
    compressed_size : UInt64,
    logical_size : UInt64,
    frames : Array(NamedTuple(compressed_offset: UInt64, logical_start: UInt64, decoded_size: UInt64)),
  ) : Int64
    return logical_size.to_i64 if compressed_offset == compressed_size && decompressed_offset == 0_u64
    frame = frames.find { |candidate| candidate[:compressed_offset] == compressed_offset } ||
            raise CrystalClick::CorruptPartError.new("W266 mark pair does not name a compressed frame")
    if decompressed_offset > frame[:decoded_size] || frame[:logical_start] > Int64::MAX.to_u64 - decompressed_offset
      raise CrystalClick::CorruptPartError.new("W266 mark pair exceeds its decoded frame")
    end
    (frame[:logical_start] + decompressed_offset).to_i64
  end

  private def audit_physical_mark_tape(
    part : String,
    physical : CrystalClick::CompactPartPhysicalContext,
    compressed_data : Bytes,
    raw_data_size : UInt64,
  ) : MarkTapeAudit
    mark_file = physical.mode.mrk4? ? "data.mrk4" : "data.mrk3"
    other_mark_file = physical.mode.mrk4? ? "data.mrk3" : "data.mrk4"
    raise CrystalClick::CorruptPartError.new("both W266 Compact mark files are present") if File.exists?(File.join(part, other_mark_file))
    roster = physical.physical_roster
    slots = roster.size.to_i32
    width = (slots * 16 + 8).to_i32
    bytes = read_bytes(File.join(part, mark_file))
    count = physical.granule_count + 1
    expected_size = count.to_i64 * width.to_i64
    unless bytes.size.to_i64 == expected_size && bytes.size <= CrystalClick::CompressedStreamLimits.new.max_mark_bytes
      raise CrystalClick::CorruptPartError.new("W266 raw mark tape does not match the exact physical grid")
    end
    frames, census_size = independent_frame_census(compressed_data)
    raise CrystalClick::CorruptPartError.new("W266 frame census differs from raw data size") unless census_size == raw_data_size
    records = [] of MarkRecordAudit
    real_rows = [] of UInt64
    previous_position = -1_i64
    count.times do |mark|
      record_start = mark * width
      pairs = [] of MarkPairAudit
      slots.times do |slot|
        pair_offset = record_start + slot * 16
        compressed_offset = read_u64_le(bytes, pair_offset)
        decompressed_offset = read_u64_le(bytes, pair_offset + 8)
        position = independent_logical_position(compressed_offset, decompressed_offset, compressed_data.size.to_u64, raw_data_size, frames)
        unless physical.logical_position({compressed_offset, decompressed_offset}) == position
          raise CrystalClick::CorruptPartError.new("W266 independent mark coordinate disagrees with physical context")
        end
        raise CrystalClick::CorruptPartError.new("W266 mark coordinates are not monotone") if position < previous_position
        previous_position = position
        pairs << {slot: slot.to_i32, compressed_offset: compressed_offset, decompressed_offset: decompressed_offset, logical_position: position}
      end
      row_count = read_u64_le(bytes, record_start + slots * 16)
      if mark == physical.granule_count
        unless row_count == 0_u64 && pairs.all? { |pair| pair[:compressed_offset] == compressed_data.size.to_u64 && pair[:decompressed_offset] == 0_u64 && pair[:logical_position].to_u64 == raw_data_size }
          raise CrystalClick::CorruptPartError.new("W266 terminal mark is not all-slot raw EOF")
        end
      else
        raise CrystalClick::CorruptPartError.new("W266 real mark row count differs from the two-row grid") unless row_count == 2_u64
        real_rows << row_count
      end
      records << {mark: mark.to_i32, row_count: row_count, pairs: pairs}
    end
    unless real_rows.size == 4 && real_rows.sum == physical.row_count
      raise CrystalClick::CorruptPartError.new("W266 real mark rows do not sum to the fixture count")
    end
    {
      file:            mark_file,
      slot_count:      slots,
      record_width:    width,
      byte_size:       bytes.size.to_i32,
      compressed_size: compressed_data.size.to_u64,
      raw_size:        raw_data_size,
      real_mark_rows:  real_rows,
      records:         records,
    }
  end

  private def folded_hash(raw : Bytes) : {UInt64, UInt64}
    digest = CrystalClick::CityHashV1.file_hash(raw)
    digest_bytes = Bytes.new(16, 0_u8)
    8.times do |index|
      digest_bytes[index] = ((digest[0] >> (index * 8)) & 0xff).to_u8
      digest_bytes[8 + index] = ((digest[1] >> (index * 8)) & 0xff).to_u8
    end
    CrystalClick::CityHashV1.hash128_with_seed(digest_bytes, 0_u64, 0_u64)
  end

  private def reseal_checksums!(part : String) : Nil
    existing = CrystalClick::PartChecksums.open(part)
    records = [] of CrystalClick::PartWriterInfrastructure::ChecksumRecord
    existing.entries.each do |name, entry|
      bytes = read_bytes(File.join(part, name))
      file_hash = CrystalClick::CityHashV1.file_hash(bytes)
      if entry.compressed
        raw = CrystalClick::CompressedBlock.decode_all(bytes, max_output_size: MAX_RAW_BYTES)
        unless raw.size.to_u64 == entry.uncompressed_size
          raise CrystalClick::CorruptPartError.new("W266 resealed compressed stream raw size differs")
        end
        records << CrystalClick::PartWriterInfrastructure::ChecksumRecord.new(name, bytes.size.to_u64, file_hash, true, raw.size.to_u64, folded_hash(raw))
      else
        records << CrystalClick::PartWriterInfrastructure::ChecksumRecord.new(name, bytes.size.to_u64, file_hash, false)
      end
    end
    CrystalClick::PartWriterInfrastructure::PartChecksumsWriter.write(part, records)
    nil
  end

  private def poison_middle_prefix!(part : String) : NamedTuple(
    logical_offset: Int32,
    prefix_byte_before: UInt8,
    prefix_byte_after: UInt8,
    raw_changed_offsets: Array(Int32),
    compressed_size: Int32,
    raw_size: Int32,
    frame_count: Int32,
  )
    physical = CrystalClick::CompactPartPhysicalContext.open(part)
    raise ArgumentError.new("prefix poisoning requires MRK4") unless physical.mode.mrk4?
    window = physical.read_window("root", 1, 1)
    shard = window.granules.first.shards.find { |item| item.stream_name == "root.dict_prefix" } ||
            raise CrystalClick::CorruptPartError.new("W266 middle root prefix shard is absent")
    prefix = shard.bytes
    raise CrystalClick::CorruptPartError.new("W266 middle root prefix is not one LE UInt64") unless prefix.size == 8
    raise CrystalClick::CorruptPartError.new("W266 middle root prefix is not version one") unless read_u64_le(prefix, 0) == 1_u64
    raw = CrystalClick::CompressedBlock.decode_all(read_bytes(File.join(part, "data.bin")), max_output_size: MAX_RAW_BYTES)
    logical_offset = shard.logical_start.to_i
    raise CrystalClick::CorruptPartError.new("W266 prefix offset is outside data.bin") if logical_offset < 0 || logical_offset > raw.size - 8
    original_raw = Bytes.new(raw.size) { |index| raw[index] }
    prefix_byte_before = raw[logical_offset]
    raise CrystalClick::CorruptPartError.new("W266 located prefix byte is not version one") unless prefix_byte_before == 1_u8
    raw[logical_offset] = 2_u8

    source = read_bytes(File.join(part, "data.bin"))
    rebuilt = IO::Memory.new(source.size)
    compressed_offset = 0_i64
    logical_start = 0_i64
    frame_count = 0_i32
    while compressed_offset < source.size.to_i64
      frame = CrystalClick::CompressedBlock.decode_frame(source, compressed_offset)
      frame_raw = raw[logical_start.to_i, frame.output.size]
      frame_bytes = CrystalClick::PartWriterInfrastructure::StreamEncoding.encode_lz4_frame(frame_raw)
      unless frame_bytes.size.to_i64 == frame.end_offset - compressed_offset
        raise CrystalClick::CorruptPartError.new("W266 resealed LZ4 frame size changed and would invalidate mark pairs")
      end
      rebuilt.write(frame_bytes)
      logical_start += frame.output.size
      compressed_offset = frame.end_offset
      frame_count += 1
    end
    raise CrystalClick::CorruptPartError.new("W266 resealed raw bytes do not match frame census") unless logical_start == raw.size
    replacement = rebuilt.to_slice
    raise CrystalClick::CorruptPartError.new("W266 resealed data.bin changed physical size") unless replacement.size == source.size
    replacement_raw = CrystalClick::CompressedBlock.decode_all(replacement, max_output_size: MAX_RAW_BYTES)
    raise CrystalClick::CorruptPartError.new("W266 resealed raw stream size changed") unless replacement_raw.size == raw.size
    unless replacement_raw == raw
      raise CrystalClick::CorruptPartError.new("W266 resealed raw stream differs from the intended one-byte poison")
    end
    changed_offsets = [] of Int32
    original_raw.each_with_index do |byte, index|
      changed_offsets << index.to_i32 if replacement_raw[index] != byte
    end
    raise CrystalClick::CorruptPartError.new("W266 poison changed bytes outside its one-byte prefix mutation") unless changed_offsets == [logical_offset.to_i32]
    File.open(File.join(part, "data.bin"), "wb") { |file| file.write(replacement) }
    reseal_checksums!(part)
    checked = CrystalClick::PartChecksums.open(part)
    checked.validate_selected_entries(part, "data.bin")
    unless checked.entry("data.bin").try(&.file_hash) == CrystalClick::CityHashV1.file_hash(replacement)
      raise CrystalClick::CorruptPartError.new("W266 resealed data.bin file checksum differs")
    end
    {
      logical_offset:      logical_offset.to_i32,
      prefix_byte_before:  prefix_byte_before,
      prefix_byte_after:   raw[logical_offset],
      raw_changed_offsets: changed_offsets,
      compressed_size:     source.size.to_i32,
      raw_size:            raw.size.to_i32,
      frame_count:         frame_count,
    }
  end

  private def signature_rows(part : String, name : String, first_mark : Int, mark_count : Int) : Array(String)
    type = CompactPartWriterW266Fixture.types[name]? || raise ArgumentError.new("unknown W266 column: #{name}")
    reader = CrystalClick::CompactBinaryBulkColumnReader.open(part, name, type)
    values = reader.read_marks(first_mark, mark_count)
    CompactPartWriterW266Fixture.read_signatures(name, values)
  end

  private def audit_low_cardinality(physical : CrystalClick::CompactPartPhysicalContext) : Array(LcSiteAudit)
    result = [] of LcSiteAudit
    LOW_CARDINALITY_SITES.each do |site|
      window = physical.read_window(site[:column], 0, physical.granule_count)
      marks = [] of LcMarkAudit
      window.granules.each do |granule|
        streams = granule.shards.to_h do |shard|
          name = shard.stream_name || raise CrystalClick::CorruptPartError.new("W266 MRK4 shard has no callback name")
          {name, shard.bytes}
        end
        prefix = streams[site[:prefix]]? || raise CrystalClick::CorruptPartError.new("missing #{site[:prefix]} callback")
        dictionary = streams[site[:dictionary]]? || raise CrystalClick::CorruptPartError.new("missing #{site[:dictionary]} callback")
        index = streams[site[:index]]? || raise CrystalClick::CorruptPartError.new("missing #{site[:index]} callback")
        raise CrystalClick::CorruptPartError.new("W266 LowCardinality prefix is not one LE UInt64") unless prefix.size == 8
        flags = index.empty? ? nil : read_u64_le(index, 0)
        marks << {
          mark:             granule.mark,
          prefix_version:   read_u64_le(prefix, 0),
          prefix_bytes:     prefix.size.to_i32,
          dictionary_bytes: dictionary.size.to_i32,
          dictionary_hex:   dictionary.hexstring,
          index_bytes:      index.size.to_i32,
          index_hex:        index.hexstring,
          flags:            flags,
        }
      end
      result << {
        column:            site[:column],
        prefix_stream:     site[:prefix],
        dictionary_stream: site[:dictionary],
        index_stream:      site[:index],
        marks:             marks,
      }
    end
    result
  end

  private def report(part : String, action : String) : String
    physical = CrystalClick::CompactPartPhysicalContext.open(part)
    roster = physical.physical_roster
    expected_roster = [] of Tuple(String, String?)
    if physical.mode.mrk4?
      expected_roster << {"pk", "pk"}
      expected_roster << {"root", "root.dict_prefix"}
      expected_roster << {"root", "root.dict"}
      expected_roster << {"root", "root"}
      expected_roster << {"maybe", "maybe.dict_prefix"}
      expected_roster << {"maybe", "maybe.dict"}
      expected_roster << {"maybe", "maybe"}
      expected_roster << {"items", "items.dict_prefix"}
      expected_roster << {"items", "items.size0"}
      expected_roster << {"items", "items.dict"}
      expected_roster << {"items", "items"}
    else
      expected_roster << {"pk", nil}
      expected_roster << {"root", nil}
      expected_roster << {"maybe", nil}
      expected_roster << {"items", nil}
    end
    observed_roster = roster.map { |slot| {slot.column_name, slot.stream_name} }
    raise CrystalClick::CorruptPartError.new("W266 stock physical callback roster differs") unless observed_roster == expected_roster
    unless physical.row_count == 8_u64 && physical.granule_count == 4
      raise CrystalClick::CorruptPartError.new("W266 stock row/granule grid differs")
    end

    low_cardinality = [] of LcSiteAudit
    if physical.mode.mrk4?
      low_cardinality = audit_low_cardinality(physical)
      low_cardinality.each do |site|
        site[:marks].each do |mark|
          unless mark[:prefix_version] == 1_u64 && mark[:prefix_bytes] == 8
            raise CrystalClick::CorruptPartError.new("W266 #{site[:column]} prefix shard differs at mark #{mark[:mark]}")
          end
          if mark[:index_bytes] > 0
            flags = mark[:flags] || raise CrystalClick::CorruptPartError.new("W266 nonempty index shard has no flags")
            unless (flags & 0x100_u64) == 0_u64 && (flags & 0x600_u64) == 0x600_u64
              raise CrystalClick::CorruptPartError.new("W266 #{site[:column]} index flags differ at mark #{mark[:mark]}")
            end
          end
        end
      end
      items_middle = low_cardinality[2][:marks][1]
      unless items_middle[:index_bytes] == 0 && items_middle[:flags].nil?
        raise CrystalClick::CorruptPartError.new("W266 empty middle items granule has a nonempty LC index body")
      end
    end

    compressed_data = read_bytes(File.join(part, "data.bin"))
    raw_data = CrystalClick::CompressedBlock.decode_all(compressed_data, max_output_size: MAX_RAW_BYTES)
    mark_tape = audit_physical_mark_tape(part, physical, compressed_data, raw_data.size.to_u64)

    window_reads = Hash(String, Hash(String, Array(String))).new
    WINDOWS.each do |name, selection|
      columns = Hash(String, Array(String)).new
      CompactPartWriterW266Fixture::COLUMN_NAMES.each do |column|
        columns[column] = signature_rows(part, column, selection[0], selection[1])
      end
      key_reader = CrystalClick::CompactBinaryBulkColumnReader.open(
        part,
        CompactPartWriterW266Fixture::KEY_NAME,
        CrystalClick::BinaryDataType.primitive("UInt64"),
      )
      columns[CompactPartWriterW266Fixture::KEY_NAME] = key_reader.read_marks(selection[0], selection[1]).flatten.map(&.as_uint64).map(&.to_s)
      window_reads[name] = columns
    end

    JSON.build do |json|
      json.object do
        json.field "format", FORMAT
        json.field "action", action
        json.field "status", "ok"
        json.field "mode", physical.mode.mrk4? ? "mrk4" : "mrk3"
        json.field "row_count", physical.row_count
        json.field "granule_count", physical.granule_count
        json.field "physical_mark_tape" do
          json.object do
            json.field "file", mark_tape[:file]
            json.field "slot_count", mark_tape[:slot_count]
            json.field "record_width", mark_tape[:record_width]
            json.field "byte_size", mark_tape[:byte_size]
            json.field "compressed_size", mark_tape[:compressed_size]
            json.field "raw_size", mark_tape[:raw_size]
            json.field "real_mark_rows", mark_tape[:real_mark_rows]
            json.field "records" do
              json.array do
                mark_tape[:records].each do |record|
                  json.object do
                    json.field "mark", record[:mark]
                    json.field "row_count", record[:row_count]
                    json.field "pairs" do
                      json.array do
                        record[:pairs].each do |pair|
                          json.object do
                            json.field "slot", pair[:slot]
                            json.field "compressed_offset", pair[:compressed_offset]
                            json.field "decompressed_offset", pair[:decompressed_offset]
                            json.field "logical_position", pair[:logical_position]
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
        json.field "mark_rows" do
          json.array { physical.mark_row_counts.each { |rows| json.number rows } }
        end
        json.field "physical_roster" do
          json.array do
            roster.each do |slot|
              json.object do
                json.field "column", slot.column_name
                json.field "stream", slot.stream_name
              end
            end
          end
        end
        json.field "low_cardinality_sites" do
          json.array do
            low_cardinality.each do |site|
              json.object do
                json.field "column", site[:column]
                json.field "prefix_stream", site[:prefix_stream]
                json.field "dictionary_stream", site[:dictionary_stream]
                json.field "index_stream", site[:index_stream]
                json.field "marks" do
                  json.array do
                    site[:marks].each do |mark|
                      json.object do
                        json.field "mark", mark[:mark]
                        json.field "prefix_version", mark[:prefix_version]
                        json.field "prefix_bytes", mark[:prefix_bytes]
                        json.field "dictionary_bytes", mark[:dictionary_bytes]
                        json.field "dictionary_hex", mark[:dictionary_hex]
                        json.field "index_bytes", mark[:index_bytes]
                        json.field "index_hex", mark[:index_hex]
                        json.field "flags", mark[:flags]
                      end
                    end
                  end
                end
              end
            end
          end
        end
        json.field "windows" do
          json.object do
            window_reads.each do |name, columns|
              json.field name do
                json.object do
                  columns.each do |column, signatures|
                    json.field column do
                      json.array { signatures.each { |signature| json.string signature } }
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end

begin
  puts CompactPartWriterW266Helper.run(ARGV)
rescue error
  STDERR.puts "W266 helper failed: #{error.class}: #{error.message}"
  exit 1
end
