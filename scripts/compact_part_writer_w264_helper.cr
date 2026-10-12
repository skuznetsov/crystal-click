require "../src/crystal_click"
require "../spec/support/compact_part_writer_w264_fixture"
require "digest/sha256"
require "file_utils"
require "json"

module CrystalClick
  module WidePartWriter
    alias W264ChecksumEntry = NamedTuple(
      physical_size: UInt64,
      file_hash: Tuple(UInt64, UInt64),
      compressed: Bool,
      uncompressed_size: UInt64?,
      uncompressed_hash: Tuple(UInt64, UInt64)?,
    )

    # W264-local rewriter. It preserves every physical file and checksum field
    # except the selected data.bin uncompressed fold, then proves the decoded
    # checksum payload changed in exactly that field.
    def self.w264_mutate_uncompressed_fold!(part : String) : Nil
      before = w264_checksum_entries(part)
      target = before["data.bin"]?
      unless target && target[:compressed] && target[:uncompressed_hash]
        raise CorruptPartError.new("W264 data.bin checksum is not a compressed entry")
      end
      target_entry = target.not_nil!
      target_hash = target_entry[:uncompressed_hash].not_nil!

      records = w264_rebuild_records(part, "data.bin") do |name, entry, folded_hash|
        if name == "data.bin"
          saved = entry[:uncompressed_hash] || raise CorruptPartError.new("W264 data.bin checksum has no saved uncompressed hash")
          {saved[0] ^ 1_u64, saved[1]}
        else
          entry[:uncompressed_hash] || folded_hash
        end
      end
      PartChecksumsWriter.write(part, records)

      after = w264_checksum_entries(part)
      raise CorruptPartError.new("W264 folded-hash mutation changed checksum roster") unless before.keys.sort == after.keys.sort
      before.each do |name, entry|
        observed = after[name]
        if name == "data.bin"
          unless observed[:physical_size] == entry[:physical_size] && observed[:file_hash] == entry[:file_hash] &&
                 observed[:compressed] == entry[:compressed] && observed[:uncompressed_size] == entry[:uncompressed_size] &&
                 observed[:uncompressed_hash] == {target_hash[0] ^ 1_u64, target_hash[1]}
            raise CorruptPartError.new("W264 folded-hash mutation changed an unintended data.bin field")
          end
        elsif observed != entry
          raise CorruptPartError.new("W264 folded-hash mutation changed another checksum entry")
        end
      end
      nil
    end

    # W264-local structurally malformed MRK3 copy. The first nonterminal
    # compressed coordinate is changed to EOF; data.bin and every logical byte
    # remain untouched. The checksums envelope is rebuilt for the modified
    # mark file so the stock rejection cannot be attributed to a stale hash.
    def self.w264_mutate_first_mark_to_eof!(part : String) : Nil
      path = File.join(part, "data.mrk3")
      marks = w264_read_bytes(path)
      columns = WidePart.parse_columns_metadata(File.read(File.join(part, "columns.txt")))
      width = columns.size.to_i64 * 16_i64 + 8_i64
      expected_columns = CompactPartWriterW264Fixture::COLUMN_NAMES.size + 1
      unless columns.size == expected_columns && marks.size.to_i64 == width * 5_i64
        raise CorruptPartError.new("W264 mark control did not locate the expected literal five-record grid")
      end
      raise CorruptPartError.new("W264 first MRK3 slot no longer starts at compressed offset zero") unless w264_read_u64(marks, 0) == 0_u64
      data_size = File.size(File.join(part, "data.bin")).to_u64
      w264_write_u64(marks, 0, data_size)
      File.open(path, "wb") { |file| file.write(marks) }

      before = w264_checksum_entries(part)
      records = w264_rebuild_records(part, nil) { |_name, entry, folded_hash| entry[:uncompressed_hash] || folded_hash }
      PartChecksumsWriter.write(part, records)
      after = w264_checksum_entries(part)
      raise CorruptPartError.new("W264 mark reseal changed checksum roster") unless before.keys.sort == after.keys.sort
      before.each do |name, entry|
        observed = after[name]
        if name == "data.mrk3"
          unless observed[:physical_size] == entry[:physical_size] && observed[:compressed] == false &&
                 observed[:uncompressed_size].nil? && observed[:file_hash] != entry[:file_hash]
            raise CorruptPartError.new("W264 malformed-mark reseal did not update only the mark file hash")
          end
        elsif observed != entry
          raise CorruptPartError.new("W264 malformed-mark reseal changed another checksum entry")
        end
      end
      nil
    end

    def self.w264_checksum_audit(part : String) : Hash(String, W264ChecksumEntry)
      w264_checksum_entries(part)
    end

    private def self.w264_rebuild_records(
      part : String,
      changed_uncompressed_name : String?,
      &block : String, W264ChecksumEntry, Tuple(UInt64, UInt64) -> Tuple(UInt64, UInt64)
    ) : Array(ChecksumRecord)
      original = w264_checksum_entries(part)
      records = [] of ChecksumRecord
      original.keys.sort.each do |name|
        physical = w264_read_bytes(File.join(part, name))
        entry = original[name]
        if entry[:compressed]
          raw = CompressedBlock.decode_all(physical, max_output_size: 64_i64 * 1024 * 1024)
          folded_hash = w264_folded_uncompressed_hash(raw)
          updated_hash = if name == changed_uncompressed_name
                           yield name, entry, folded_hash
                         else
                           entry[:uncompressed_hash] || folded_hash
                         end
          records << ChecksumRecord.new(
            name,
            physical.size.to_u64,
            CityHashV1.file_hash(physical),
            true,
            raw.size.to_u64,
            updated_hash,
          )
        else
          records << ChecksumRecord.new(name, physical.size.to_u64, CityHashV1.file_hash(physical), false)
        end
      end
      records
    end

    # Compact persists the fold of the 16-byte little-endian CityHash file
    # digest, not the digest tuple itself. Keep this audit/reseal calculation
    # aligned with CompactStaticMRK3Writer and ClickHouse's WriterCompact.
    def self.w264_folded_uncompressed_hash(raw : Bytes) : Tuple(UInt64, UInt64)
      digest = CityHashV1.file_hash(raw)
      digest_bytes = Bytes.new(16)
      w264_write_u64(digest_bytes, 0, digest[0])
      w264_write_u64(digest_bytes, 8, digest[1])
      CityHashV1.hash128_with_seed(digest_bytes, 0_u64, 0_u64)
    end

    private def self.w264_checksum_entries(part : String) : Hash(String, W264ChecksumEntry)
      bytes = w264_read_bytes(File.join(part, "checksums.txt"))
      header = PartChecksums::CHECKSUMS_HEADER.to_slice
      unless bytes.size >= header.size && bytes[0, header.size] == header
        raise CorruptPartError.new("W264 checksums header differs")
      end
      payload = CompressedBlock.decode_all(bytes[header.size, bytes.size - header.size])
      cursor = 0
      count, cursor = w264_read_var_uint(payload, cursor)
      if count == 0_u64 || count > PartChecksums::MAX_ENTRIES.to_u64
        raise CorruptPartError.new("W264 checksum entry count is outside its bound")
      end
      entries = Hash(String, W264ChecksumEntry).new
      count.to_i.times do
        name_size, cursor = w264_read_var_uint(payload, cursor)
        if name_size == 0_u64 || name_size > PartChecksums::MAX_NAME_BYTES.to_u64 ||
           cursor < 0 || cursor > payload.size - name_size.to_i
          raise CorruptPartError.new("W264 checksum entry name is truncated")
        end
        name = String.new(payload[cursor, name_size.to_i])
        cursor += name_size.to_i
        physical_size, cursor = w264_read_var_uint(payload, cursor)
        file_hash = {w264_read_u64(payload, cursor), w264_read_u64(payload, cursor + 8)}
        cursor += 16
        flag = payload[cursor]? || raise CorruptPartError.new("W264 checksum flag is truncated")
        cursor += 1
        compressed = flag == 1_u8
        unless flag == 0_u8 || flag == 1_u8
          raise CorruptPartError.new("W264 checksum compression flag is invalid")
        end
        uncompressed_size = nil.as(UInt64?)
        uncompressed_hash = nil.as(Tuple(UInt64, UInt64)?)
        if compressed
          size, cursor = w264_read_var_uint(payload, cursor)
          uncompressed_size = size
          uncompressed_hash = {w264_read_u64(payload, cursor), w264_read_u64(payload, cursor + 8)}
          cursor += 16
        end
        if entries.has_key?(name)
          raise CorruptPartError.new("W264 checksum roster has duplicate names")
        end
        entries[name] = {
          physical_size:     physical_size,
          file_hash:         file_hash,
          compressed:        compressed,
          uncompressed_size: uncompressed_size,
          uncompressed_hash: uncompressed_hash,
        }
      end
      unless cursor == payload.size
        raise CorruptPartError.new("W264 checksums payload has trailing bytes")
      end
      entries
    end

    private def self.w264_read_var_uint(bytes : Bytes, initial_cursor : Int32) : Tuple(UInt64, Int32)
      value = 0_u64
      cursor = initial_cursor
      shift = 0
      loop do
        byte = bytes[cursor]? || raise CorruptPartError.new("W264 checksums varUInt is truncated")
        cursor += 1
        payload = (byte & 0x7f).to_u64
        if shift == 63 && payload > 1_u64
          raise CorruptPartError.new("W264 checksums varUInt overflows")
        end
        value |= payload << shift
        return {value, cursor} if (byte & 0x80) == 0
        shift += 7
        if shift > 63
          raise CorruptPartError.new("W264 checksums varUInt is too long")
        end
      end
    end

    private def self.w264_read_u64(bytes : Bytes, offset : Int) : UInt64
      if offset < 0 || offset > bytes.size - 8
        raise CorruptPartError.new("W264 checksum UInt64 is truncated")
      end
      value = 0_u64
      8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
      value
    end

    private def self.w264_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
      if offset < 0 || offset > bytes.size - 8
        raise CorruptPartError.new("W264 MRK3 UInt64 is truncated")
      end
      8.times { |index| bytes[offset + index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
    end

    private def self.w264_read_bytes(path : String) : Bytes
      raise CorruptPartError.new("W264 mutation input must be a regular non-symlink file") if File.symlink?(path) || !File.file?(path)
      text = File.read(path)
      Bytes.new(text.bytesize) { |index| text.to_slice[index] }
    end
  end
end

module CompactPartWriterW264Helper
  extend self

  FORMAT = "compact_part_writer_w264_helper_v1"

  def run(args : Array(String)) : String
    action = args[0]? || raise ArgumentError.new("expected write, inspect, inspect-outcome, audit, stale-copy, fold-copy or mark-copy")
    case action
    when "write"
      raise ArgumentError.new("usage: helper write PART") unless args.size == 2
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
    when "inspect"
      raise ArgumentError.new("usage: helper inspect PART") unless args.size == 2
      report(validate_part(args[1]), action)
    when "inspect-outcome"
      raise ArgumentError.new("usage: helper inspect-outcome PART") unless args.size == 2
      part = validate_part(args[1])
      begin
        report(part, "inspect")
      rescue error : CrystalClick::CorruptPartError
        JSON.build do |json|
          json.object do
            json.field "format", FORMAT
            json.field "action", action
            json.field "status", "rejected"
            json.field "error_class", error.class.name
            json.field "error_message", error.message
          end
        end
      end
    when "audit"
      raise ArgumentError.new("usage: helper audit PART") unless args.size == 2
      audit_report(validate_part(args[1]))
    when "stale-copy", "fold-copy", "mark-copy"
      raise ArgumentError.new("usage: helper CONTROL-COPY SOURCE DESTINATION") unless args.size == 3
      source = validate_part(args[1])
      destination = validate_new_destination(args[2])
      FileUtils.cp_r(source, destination)
      case action
      when "stale-copy"
        stale_data_copy!(destination)
      when "fold-copy"
        CrystalClick::WidePartWriter.w264_mutate_uncompressed_fold!(destination)
      when "mark-copy"
        CrystalClick::WidePartWriter.w264_mutate_first_mark_to_eof!(destination)
      end
      JSON.build do |json|
        json.object do
          json.field "format", FORMAT
          json.field "action", action
          json.field "status", "ok"
          json.field "source", source
          json.field "destination", destination
          json.field "files", file_inventory(destination)
          json.field "data_bin_sha256", sha(File.join(destination, "data.bin"))
          json.field "data_mrk3_sha256", sha(File.join(destination, "data.mrk3"))
          json.field "checksums_sha256", sha(File.join(destination, "checksums.txt"))
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

  private def stale_data_copy!(part : String) : Nil
    path = File.join(part, "data.bin")
    bytes = w264_read_bytes(path)
    raise ArgumentError.new("Compact data.bin is empty") if bytes.empty?
    bytes[0] ^= 1_u8
    File.open(path, "wb") { |file| file.write(bytes) }
    nil
  end

  private def w264_read_bytes(path : String) : Bytes
    raise ArgumentError.new("mutation target is missing or symlinked") if File.symlink?(path) || !File.file?(path)
    text = File.read(path)
    Bytes.new(text.bytesize) { |index| text.to_slice[index] }
  end

  private def report(part : String, action : String) : String
    physical = CrystalClick::CompactPartPhysicalContext.open(part)
    schema = CompactPartWriterW264Fixture.types
    columns = Hash(String, NamedTuple(type: String, signatures: Array(String), marks: Array(UInt64))).new
    CompactPartWriterW264Fixture::COLUMN_NAMES.each do |name|
      reader = CrystalClick::CompactBinaryBulkColumnReader.open(part, name, schema[name])
      rows = reader.read_marks(0, reader.mark_count).flatten
      columns[name] = {
        type:       reader.schema_declaration,
        signatures: rows.map { |value| CompactPartWriterW264Fixture.row_signature(value) },
        marks:      reader.mark_row_counts,
      }
    end
    key_reader = CrystalClick::CompactBinaryBulkColumnReader.open(
      part,
      CompactPartWriterW264Fixture::KEY_NAME,
      CrystalClick::BinaryDataType.primitive("UInt64"),
    )
    keys = key_reader.read_marks(0, key_reader.mark_count).flatten.map(&.as_uint64)
    checksums = CrystalClick::PartChecksums.open(part)
    JSON.build do |json|
      json.object do
        json.field "format", FORMAT
        json.field "action", action
        json.field "status", "ok"
        json.field "part_path", part
        json.field "mode", physical.mode.mrk3? ? "mrk3" : "mrk4"
        json.field "row_count", physical.row_count
        json.field "real_marks", physical.granule_count
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
        json.field "files", file_inventory(part)
        json.field "checksums" do
          json.array do
            checksums.entries.keys.sort.each do |name|
              entry = checksums.entry(name).not_nil!
              json.object do
                json.field "name", name
                json.field "physical_size", entry.physical_size
                json.field "compressed", entry.compressed
                json.field "uncompressed_size", entry.uncompressed_size
              end
            end
          end
        end
        json.field "data_bin_bytes", File.size(File.join(part, "data.bin"))
        json.field "data_mrk3_bytes", File.size(File.join(part, "data.mrk3"))
      end
    end
  end

  # Raw physical audit for the independently generated native reference and
  # disposable checksum/mark mutants. Unlike `inspect`, this deliberately
  # does not open the public Compact reader, so it can report the exact saved
  # checksum fields even when a copy is semantically or physically invalid.
  private def audit_report(part : String) : String
    checksums = CrystalClick::WidePartWriter.w264_checksum_audit(part)
    data_path = File.join(part, "data.bin")
    data_bytes = w264_read_bytes(data_path)
    decode_error = nil.as(String?)
    raw = begin
      CrystalClick::CompressedBlock.decode_all(data_bytes, max_output_size: 64_i64 * 1024 * 1024)
    rescue error : CrystalClick::CorruptPartError
      decode_error = "#{error.class}: #{error.message}"
      nil
    end
    data_entry = checksums["data.bin"]?
    JSON.build do |json|
      json.object do
        json.field "format", FORMAT
        json.field "action", "audit"
        json.field "status", "ok"
        json.field "part_path", part
        json.field "files", file_inventory(part)
        json.field "checksum_entries" do
          json.array do
            checksums.keys.sort.each do |name|
              entry = checksums[name]
              json.object do
                json.field "name", name
                json.field "physical_size", entry[:physical_size]
                json.field "file_hash_words" do
                  json.array do
                    json.string entry[:file_hash][0].to_s
                    json.string entry[:file_hash][1].to_s
                  end
                end
                json.field "compressed", entry[:compressed]
                json.field "uncompressed_size", entry[:uncompressed_size]
                json.field "uncompressed_hash_words" do
                  if hash = entry[:uncompressed_hash]
                    json.array do
                      json.string hash[0].to_s
                      json.string hash[1].to_s
                    end
                  else
                    json.null
                  end
                end
              end
            end
          end
        end
        json.field "data_bin_physical_size", data_bytes.size
        json.field "data_bin_raw_decode_error", decode_error
        json.field "data_bin_raw_size", raw.try(&.size)
        json.field "data_bin_raw_sha256", raw ? Digest::SHA256.hexdigest(raw) : nil
        json.field "data_bin_raw_file_hash_words" do
          if raw
            hash = CrystalClick::CityHashV1.file_hash(raw)
            json.array do
              json.string hash[0].to_s
              json.string hash[1].to_s
            end
          else
            json.null
          end
        end
        json.field "data_bin_computed_uncompressed_hash_words" do
          if raw
            hash = CrystalClick::WidePartWriter.w264_folded_uncompressed_hash(raw)
            json.array do
              json.string hash[0].to_s
              json.string hash[1].to_s
            end
          else
            json.null
          end
        end
        json.field "data_bin_saved_uncompressed_hash_words" do
          if entry = data_entry
            if hash = entry[:uncompressed_hash]
              json.array do
                json.string hash[0].to_s
                json.string hash[1].to_s
              end
            else
              json.null
            end
          else
            json.null
          end
        end
      end
    end
  end

  private def file_inventory(part : String) : Array(NamedTuple(path: String, size: Int64, sha256: String))
    Dir.glob(File.join(part, "**", "*"))
      .select { |path| File.file?(path) }
      .sort!
      .map do |path|
        {
          path:   path[part.bytesize + 1, path.bytesize - part.bytesize - 1],
          size:   File.size(path),
          sha256: sha(path),
        }
      end
  end

  private def sha(path : String) : String
    Digest::SHA256.hexdigest(w264_read_bytes(path))
  end
end

puts CompactPartWriterW264Helper.run(ARGV)
