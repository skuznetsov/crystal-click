require "../src/crystal_click"
require "../spec/support/compact_part_writer_w264_fixture"
require "../spec/support/compact_part_writer_w265_fixture"
require "digest/sha256"
require "file_utils"
require "json"

module CompactPartWriterW265Helper
  extend self

  FORMAT          = "compact_part_writer_w265_helper_v1"
  MAX_RAW_BYTES   = 64_i64 * 1024 * 1024
  MAX_FRAME_COUNT = 100_000

  def run(args : Array(String)) : String
    action = args[0]? || raise ArgumentError.new("expected write-default, write, audit, copy-mutant or inspect-outcome")
    case action
    when "write-default"
      raise ArgumentError.new("usage: helper write-default PART") unless args.size == 2
      part = validate_new_destination(args[1])
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part,
        CompactPartWriterW264Fixture::KEY_NAME,
        CompactPartWriterW264Fixture.keys,
        CompactPartWriterW264Fixture.columns,
        rows_per_mark: CompactPartWriterW264Fixture::ROWS_PER_MARK,
        frame_bytes: CompactPartWriterW264Fixture::FRAME_BYTES,
      )
      report(part, action)
    when "write"
      raise ArgumentError.new("usage: helper write PART mrk3|mrk4") unless args.size == 3
      part = validate_new_destination(args[1])
      mark_format = case args[2]?
                    when "mrk4" then CrystalClick::CompactMarkFormat::Mrk4
                    when "mrk3" then CrystalClick::CompactMarkFormat::Mrk3
                    else             raise ArgumentError.new("mark format must be mrk3 or mrk4")
                    end
      CompactPartWriterW265Fixture.write(part, mark_format)
      report(part, action)
    when "audit"
      raise ArgumentError.new("usage: helper audit PART") unless args.size == 2
      report(validate_part(args[1]), action)
    when "copy-mutant"
      raise ArgumentError.new("usage: helper copy-mutant KIND SOURCE DESTINATION") unless args.size == 4
      kind = args[1]
      source = validate_part(args[2])
      destination = validate_new_destination(args[3])
      FileUtils.cp_r(source, destination)
      case kind
      when "stale"
        mutate_stale_data!(destination)
      when "fold"
        mutate_fold!(destination)
      when "child"
        CompactPartWriterW265Fixture.mutate_gap_child_start!(destination)
      when "roster"
        CompactPartWriterW265Fixture.mutate_gap_roster!(destination)
      else
        raise ArgumentError.new("unknown Compact MRK4 mutant: #{kind}")
      end
      JSON.build do |json|
        json.object do
          json.field "format", FORMAT
          json.field "action", action
          json.field "status", "ok"
          json.field "kind", kind
          json.field "source_files", file_inventory(source)
          json.field "mutant_files", file_inventory(destination)
          json.field "checksum_entries", checksum_audit(destination)
        end
      end
    when "inspect-outcome"
      raise ArgumentError.new("usage: helper inspect-outcome PART COLUMN") unless args.size == 3
      part = validate_part(args[1])
      column = args[2]
      begin
        type = if column == CompactPartWriterW264Fixture::KEY_NAME
                 CrystalClick::BinaryDataType.primitive("UInt64")
               else
                 CompactPartWriterW264Fixture.types[column]? || raise ArgumentError.new("unknown fixture column")
               end
        reader = CrystalClick::CompactBinaryBulkColumnReader.open(part, column, type)
        reader.read_marks(0, reader.mark_count)
        outcome(action, "accepted", nil, nil)
      rescue error : CrystalClick::CorruptPartError
        outcome(action, "rejected", error.class.name, error.message)
      end
    else
      raise ArgumentError.new("unknown helper action: #{action}")
    end
  end

  private def outcome(action : String, status : String, error_class : String?, message : String?) : String
    JSON.build do |json|
      json.object do
        json.field "format", FORMAT
        json.field "action", action
        json.field "status", status
        json.field "error_class", error_class
        json.field "error_message", message
      end
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

  private def report(part : String, action : String) : String
    physical = CrystalClick::CompactPartPhysicalContext.open(part)
    schema = CompactPartWriterW264Fixture.types
    columns = Hash(String, NamedTuple(type: String, marks: Array(UInt64), signatures: Array(String))).new
    CompactPartWriterW264Fixture::COLUMN_NAMES.each do |name|
      reader = CrystalClick::CompactBinaryBulkColumnReader.open(part, name, schema[name])
      values = reader.read_marks(0, reader.mark_count).flatten
      columns[name] = {
        type:       reader.schema_declaration,
        marks:      reader.mark_row_counts,
        signatures: values.map { |value| CompactPartWriterW264Fixture.row_signature(value) },
      }
    end
    key_reader = CrystalClick::CompactBinaryBulkColumnReader.open(
      part,
      CompactPartWriterW264Fixture::KEY_NAME,
      CrystalClick::BinaryDataType.primitive("UInt64"),
    )
    keys = key_reader.read_marks(0, key_reader.mark_count).flatten.map(&.as_uint64)
    checksums = checksum_audit(part)
    compressed_data = read_bytes(File.join(part, "data.bin"))
    raw = CrystalClick::CompressedBlock.decode_all(
      compressed_data,
      max_output_size: MAX_RAW_BYTES,
    )
    mark_tape = audit_mark_tape(part, physical, compressed_data, raw.size.to_u64)
    JSON.build do |json|
      json.object do
        json.field "format", FORMAT
        json.field "action", action
        json.field "status", "ok"
        json.field "mode", physical.mode.mrk4? ? "mrk4" : "mrk3"
        json.field "row_count", physical.row_count
        json.field "mark_rows", physical.mark_row_counts
        json.field "physical_roster" do
          json.array do
            physical.physical_roster.each do |slot|
              json.object do
                json.field "index", slot.index
                json.field "column", slot.column_name
                json.field "stream", slot.stream_name
              end
            end
          end
        end
        json.field "keys", keys
        json.field "columns" do
          json.array do
            CompactPartWriterW264Fixture::COLUMN_NAMES.each do |name|
              item = columns[name]
              json.object do
                json.field "name", name
                json.field "type", item[:type]
                json.field "mark_rows", item[:marks]
                json.field "signatures", item[:signatures]
              end
            end
          end
        end
        json.field "files", file_inventory(part)
        json.field "checksum_entries", checksums
        json.field "data_bin_raw_size", raw.size
        json.field "data_bin_raw_sha256", Digest::SHA256.hexdigest(raw)
        json.field "data_bin_saved_uncompressed_hash_words" do
          saved = checksums.find { |entry| entry[:name] == "data.bin" }.not_nil![:uncompressed_hash_words]
          json.array { saved.not_nil!.each { |word| json.string word.to_s } }
        end
        json.field "data_bin_computed_uncompressed_hash_words" do
          hash = folded_hash(raw)
          json.array do
            json.string hash[0].to_s
            json.string hash[1].to_s
          end
        end
        json.field "physical_mark_tape" do
          json.object do
            json.field "file", mark_tape[:file]
            json.field "slot_count", mark_tape[:slot_count]
            json.field "record_width", mark_tape[:record_width]
            json.field "byte_size", mark_tape[:byte_size]
            json.field "independent_frame_count", mark_tape[:independent_frame_count]
            json.field "header_bytes", 0
            json.field "records" do
              json.array do
                mark_tape[:records].each do |record|
                  json.object do
                    json.field "mark", record[:mark]
                    json.field "row_count", record[:row_count].to_s
                    json.field "pairs" do
                      json.array do
                        record[:pairs].each do |pair|
                          json.object do
                            json.field "slot", pair[:slot]
                            json.field "column", pair[:column]
                            json.field "stream", pair[:stream]
                            json.field "compressed_offset", pair[:compressed_offset].to_s
                            json.field "decompressed_offset", pair[:decompressed_offset].to_s
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
      end
    end
  end

  private def audit_mark_tape(
    part : String,
    physical : CrystalClick::CompactPartPhysicalContext,
    compressed_data : Bytes,
    raw_data_size : UInt64,
  ) : NamedTuple(
    file: String,
    slot_count: Int32,
    record_width: Int32,
    byte_size: Int32,
    independent_frame_count: Int32,
    records: Array(NamedTuple(
      mark: Int32,
      row_count: UInt64,
      pairs: Array(NamedTuple(
        slot: Int32,
        column: String,
        stream: String?,
        compressed_offset: UInt64,
        decompressed_offset: UInt64,
        logical_position: Int64,
      )),
    )),
  )
    mark_file = if physical.mode.mrk4?
                  "data.mrk4"
                else
                  "data.mrk3"
                end
    other_mark_file = physical.mode.mrk4? ? "data.mrk3" : "data.mrk4"
    raise CrystalClick::CorruptPartError.new("both Compact mark files are present") if File.exists?(File.join(part, other_mark_file))

    roster = physical.physical_roster
    expected_roster = if physical.mode.mrk4?
                        [
                          {"pk", "pk"}, {"u", "u"}, {"text", "text"}, {"maybe", "maybe.null"}, {"maybe", "maybe"},
                          {"gap", "gap.size0"}, {"gap", "gap.null"}, {"gap", "gap"},
                          {"arr", "arr.size0"}, {"arr", "arr.null"}, {"arr", "arr"},
                          {"pair", "pair%2E1"}, {"pair", "pair%2E2.null"}, {"pair", "pair%2E2"},
                          {"lookup", "lookup.size0"}, {"lookup", "lookup%2Ekeys"}, {"lookup", "lookup%2Evalues"},
                        ]
                      else
                        [
                          {"pk", nil}, {"u", nil}, {"text", nil}, {"maybe", nil},
                          {"gap", nil}, {"arr", nil}, {"pair", nil}, {"lookup", nil},
                        ]
                      end
    observed_roster = roster.map { |slot| {slot.column_name, slot.stream_name} }
    raise CrystalClick::CorruptPartError.new("physical callback roster differs from the fixed W265 schema") unless observed_roster == expected_roster
    raise CrystalClick::CorruptPartError.new("W265 fixture row/granule count differs") unless physical.row_count == CompactPartWriterW264Fixture::ROW_COUNT.to_u64 && physical.granule_count == 4

    frames, independently_decoded_size = independent_frame_census(compressed_data)
    raise CrystalClick::CorruptPartError.new("independent frame census differs from decoded tape size") unless independently_decoded_size == raw_data_size

    bytes = read_bytes(File.join(part, mark_file))
    slot_count = roster.size.to_i32
    record_width = (slot_count * 16 + 8).to_i32
    record_count = physical.granule_count + 1
    expected_size = record_count.to_i64 * record_width.to_i64
    raise CrystalClick::CorruptPartError.new("plain Compact mark tape size differs from exact grid") unless bytes.size.to_i64 == expected_size && bytes.size <= CrystalClick::CompressedStreamLimits.new.max_mark_bytes

    records = Array(NamedTuple(
      mark: Int32,
      row_count: UInt64,
      pairs: Array(NamedTuple(
        slot: Int32,
        column: String,
        stream: String?,
        compressed_offset: UInt64,
        decompressed_offset: UInt64,
        logical_position: Int64,
      )),
    )).new(record_count)
    previous_logical = -1_i64
    row_sum = 0_u64
    record_count.times do |mark|
      record_offset = mark * record_width
      pairs = Array(NamedTuple(
        slot: Int32,
        column: String,
        stream: String?,
        compressed_offset: UInt64,
        decompressed_offset: UInt64,
        logical_position: Int64,
      )).new(slot_count)
      roster.each do |slot|
        pair_offset = record_offset + slot.index * 16
        compressed_offset = read_u64_le(bytes, pair_offset)
        decompressed_offset = read_u64_le(bytes, pair_offset + 8)
        logical_position = independent_logical_position(
          compressed_offset,
          decompressed_offset,
          compressed_data.size.to_u64,
          raw_data_size,
          frames,
        )
        context_position = physical.logical_position({compressed_offset, decompressed_offset})
        raise CrystalClick::CorruptPartError.new("independent frame resolver differs from Compact context") unless logical_position == context_position
        raise CrystalClick::CorruptPartError.new("saved Compact callback coordinates are not monotone") if logical_position < previous_logical
        previous_logical = logical_position
        pairs << {
          slot:                slot.index,
          column:              slot.column_name,
          stream:              slot.stream_name,
          compressed_offset:   compressed_offset,
          decompressed_offset: decompressed_offset,
          logical_position:    logical_position,
        }
      end
      row_count = read_u64_le(bytes, record_offset + slot_count * 16)
      if mark == physical.granule_count
        raise CrystalClick::CorruptPartError.new("terminal row count is nonzero") unless row_count == 0_u64
        raise CrystalClick::CorruptPartError.new("terminal callbacks do not all resolve to raw EOF") unless pairs.all? { |pair| pair[:logical_position].to_u64 == raw_data_size }
      else
        raise CrystalClick::CorruptPartError.new("real mark row count differs from two-row fixture") unless row_count == 2_u64
        row_sum += row_count
      end
      records << {mark: mark.to_i32, row_count: row_count, pairs: pairs}
    end
    raise CrystalClick::CorruptPartError.new("mark rows do not sum to fixture count") unless row_sum == physical.row_count

    {
      file:                    mark_file,
      slot_count:              slot_count,
      record_width:            record_width,
      byte_size:               bytes.size,
      independent_frame_count: frames.size.to_i32,
      records:                 records,
    }
  end

  private def independent_frame_census(compressed_data : Bytes) : Tuple(
    Array(NamedTuple(compressed_offset: UInt64, logical_start: UInt64, decoded_size: UInt64)),
    UInt64,
  )
    if compressed_data.empty? || compressed_data.size > MAX_RAW_BYTES
      raise CrystalClick::CorruptPartError.new("compressed data.bin is outside the bounded frame census")
    end

    frames = Array(NamedTuple(compressed_offset: UInt64, logical_start: UInt64, decoded_size: UInt64)).new
    offset = 0_i64
    logical_start = 0_u64
    frame_header_size = CrystalClick::CompressedBlock::FRAME_HEADER_SIZE
    while offset < compressed_data.size.to_i64
      if frames.size >= MAX_FRAME_COUNT || offset > compressed_data.size.to_i64 - frame_header_size
        raise CrystalClick::CorruptPartError.new("compressed data.bin frame census is truncated or oversized")
      end
      header_offset = offset.to_i + CrystalClick::CompressedBlock::CHECKSUM_SIZE
      method = compressed_data[header_offset]
      compressed_size = read_u32_le(compressed_data, header_offset + 1).to_i64
      decoded_size = read_u32_le(compressed_data, header_offset + 5).to_u64
      unless method == CrystalClick::CompressedBlock::METHOD_LZ4 &&
             compressed_size >= CrystalClick::CompressedBlock::HEADER_SIZE &&
             compressed_size <= CrystalClick::CompressedBlock::DEFAULT_MAX_FRAME &&
             decoded_size > 0_u64 && decoded_size <= MAX_RAW_BYTES.to_u64
        raise CrystalClick::CorruptPartError.new("compressed data.bin frame header is outside the W265 LZ4 profile")
      end
      frame_bytes = CrystalClick::CompressedBlock::CHECKSUM_SIZE.to_i64 + compressed_size
      if frame_bytes > compressed_data.size.to_i64 - offset || decoded_size > UInt64::MAX - logical_start
        raise CrystalClick::CorruptPartError.new("compressed data.bin frame extent overflows its bounded source")
      end
      frames << {
        compressed_offset: offset.to_u64,
        logical_start:     logical_start,
        decoded_size:      decoded_size,
      }
      offset += frame_bytes
      logical_start += decoded_size
    end
    raise CrystalClick::CorruptPartError.new("compressed data.bin frame census has trailing bytes") unless offset == compressed_data.size.to_i64
    {frames, logical_start}
  end

  private def independent_logical_position(
    compressed_offset : UInt64,
    decompressed_offset : UInt64,
    compressed_size : UInt64,
    logical_size : UInt64,
    frames : Array(NamedTuple(compressed_offset: UInt64, logical_start: UInt64, decoded_size: UInt64)),
  ) : Int64
    if compressed_offset == compressed_size && decompressed_offset == 0_u64
      return logical_size.to_i64
    end
    frame = frames.find { |candidate| candidate[:compressed_offset] == compressed_offset } ||
            raise CrystalClick::CorruptPartError.new("saved pair does not name a raw compressed frame start")
    if decompressed_offset > frame[:decoded_size] || frame[:logical_start] > Int64::MAX.to_u64 - decompressed_offset
      raise CrystalClick::CorruptPartError.new("saved pair decompressed offset exceeds the independent frame census")
    end
    (frame[:logical_start] + decompressed_offset).to_i64
  end

  private def read_u32_le(bytes : Bytes, offset : Int) : UInt32
    if offset < 0 || offset > bytes.size - 4
      raise CrystalClick::CorruptPartError.new("truncated independent compressed frame header")
    end
    bytes[offset].to_u32 |
      (bytes[offset + 1].to_u32 << 8) |
      (bytes[offset + 2].to_u32 << 16) |
      (bytes[offset + 3].to_u32 << 24)
  end

  private def checksum_audit(part : String) : Array(NamedTuple(
    name: String,
    physical_size: UInt64,
    file_hash_words: Array(UInt64),
    compressed: Bool,
    uncompressed_size: UInt64?,
    uncompressed_hash_words: Array(UInt64)?,
  ))
    parse_checksums(read_bytes(File.join(part, "checksums.txt"))).map do |entry|
      {
        name:                    entry[:name],
        physical_size:           entry[:physical_size],
        file_hash_words:         [entry[:file_hash][0], entry[:file_hash][1]],
        compressed:              entry[:compressed],
        uncompressed_size:       entry[:uncompressed_size],
        uncompressed_hash_words: entry[:uncompressed_hash].try { |hash| [hash[0], hash[1]] },
      }
    end
  end

  private def parse_checksums(bytes : Bytes) : Array(NamedTuple(
    name: String,
    physical_size: UInt64,
    file_hash: {UInt64, UInt64},
    compressed: Bool,
    uncompressed_size: UInt64?,
    uncompressed_hash: {UInt64, UInt64}?,
  ))
    header = CrystalClick::PartChecksums::CHECKSUMS_HEADER.to_slice
    raise CrystalClick::CorruptPartError.new("checksums header differs") unless bytes.size >= header.size && bytes[0, header.size] == header
    payload = CrystalClick::CompressedBlock.decode_all(
      bytes[header.size, bytes.size - header.size],
      CrystalClick::PartChecksums::MAX_FRAME_COMPRESSED_BYTES,
      CrystalClick::PartChecksums::MAX_FRAME_DECOMPRESSED_BYTES,
      CrystalClick::PartChecksums::MAX_PAYLOAD_BYTES,
    )
    cursor = 0
    count, cursor = read_var_uint(payload, cursor)
    entries = [] of NamedTuple(
      name: String,
      physical_size: UInt64,
      file_hash: {UInt64, UInt64},
      compressed: Bool,
      uncompressed_size: UInt64?,
      uncompressed_hash: {UInt64, UInt64}?,
    )
    count.to_i.times do
      name_size, cursor = read_var_uint(payload, cursor)
      name = String.new(payload[cursor, name_size.to_i])
      cursor += name_size.to_i
      physical_size, cursor = read_var_uint(payload, cursor)
      file_hash = {read_u64_le(payload, cursor), read_u64_le(payload, cursor + 8)}
      cursor += 16
      flag = payload[cursor]? || raise CrystalClick::CorruptPartError.new("checksums flag is truncated")
      cursor += 1
      compressed = flag == 1_u8
      uncompressed_size = nil.as(UInt64?)
      uncompressed_hash = nil.as({UInt64, UInt64}?)
      if compressed
        uncompressed_size, cursor = read_var_uint(payload, cursor)
        uncompressed_hash = {read_u64_le(payload, cursor), read_u64_le(payload, cursor + 8)}
        cursor += 16
      elsif flag != 0_u8
        raise CrystalClick::CorruptPartError.new("checksums flag is invalid")
      end
      entries << {
        name:              name,
        physical_size:     physical_size,
        file_hash:         file_hash,
        compressed:        compressed,
        uncompressed_size: uncompressed_size,
        uncompressed_hash: uncompressed_hash,
      }
    end
    raise CrystalClick::CorruptPartError.new("checksums payload has trailing bytes") unless cursor == payload.size
    entries
  end

  private def reseal_checksums!(part : String, fold_flip : Bool = false) : Nil
    records = [] of CrystalClick::PartWriterInfrastructure::ChecksumRecord
    parse_checksums(read_bytes(File.join(part, "checksums.txt"))).each do |entry|
      physical = read_bytes(File.join(part, entry[:name]))
      file_hash = CrystalClick::CityHashV1.file_hash(physical)
      if entry[:compressed]
        raw = CrystalClick::CompressedBlock.decode_all(physical, max_output_size: MAX_RAW_BYTES)
        unless raw.size.to_u64 == entry[:uncompressed_size]
          raise CrystalClick::CorruptPartError.new("compressed checksum raw size changed unexpectedly")
        end
        uncompressed_hash = folded_hash(raw)
        if fold_flip && entry[:name] == "data.bin"
          uncompressed_hash = {uncompressed_hash[0] ^ 1_u64, uncompressed_hash[1]}
        end
        records << CrystalClick::PartWriterInfrastructure::ChecksumRecord.new(
          entry[:name], physical.size.to_u64, file_hash, true, raw.size.to_u64, uncompressed_hash,
        )
      else
        records << CrystalClick::PartWriterInfrastructure::ChecksumRecord.new(
          entry[:name], physical.size.to_u64, file_hash, false,
        )
      end
    end
    CrystalClick::PartWriterInfrastructure::PartChecksumsWriter.write(part, records)
    nil
  end

  private def mutate_stale_data!(part : String) : Nil
    path = File.join(part, "data.bin")
    bytes = read_bytes(path)
    raise ArgumentError.new("data.bin is empty") if bytes.empty?
    bytes[0] ^= 1_u8
    File.open(path, "wb") { |file| file.write(bytes) }
    nil
  end

  private def mutate_fold!(part : String) : Nil
    reseal_checksums!(part, fold_flip: true)
  end

  private def folded_hash(raw : Bytes) : {UInt64, UInt64}
    digest = CrystalClick::CityHashV1.file_hash(raw)
    digest_bytes = Bytes.new(16, 0_u8)
    write_u64_le(digest_bytes, 0, digest[0])
    write_u64_le(digest_bytes, 8, digest[1])
    CrystalClick::CityHashV1.hash128_with_seed(digest_bytes, 0_u64, 0_u64)
  end

  private def file_inventory(part : String) : Array(NamedTuple(path: String, size: Int64, sha256: String))
    Dir.glob(File.join(part, "**", "*"))
      .select { |path| File.file?(path) }
      .sort!
      .map do |path|
        {
          path:   path[part.bytesize + 1, path.bytesize - part.bytesize - 1],
          size:   File.size(path),
          sha256: Digest::SHA256.hexdigest(read_bytes(path)),
        }
      end
  end

  private def read_bytes(path : String) : Bytes
    raise ArgumentError.new("file is missing or symlinked") if File.symlink?(path) || !File.file?(path)
    text = File.read(path)
    Bytes.new(text.bytesize) { |index| text.to_slice[index] }
  end

  private def read_var_uint(bytes : Bytes, cursor : Int32) : Tuple(UInt64, Int32)
    value = 0_u64
    shift = 0
    loop do
      byte = bytes[cursor]? || raise CrystalClick::CorruptPartError.new("checksums varUInt is truncated")
      cursor += 1
      value |= (byte & 0x7f).to_u64 << shift
      return {value, cursor} if (byte & 0x80) == 0
      shift += 7
      raise CrystalClick::CorruptPartError.new("checksums varUInt is too long") if shift > 63
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

puts CompactPartWriterW265Helper.run(ARGV)
