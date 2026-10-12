require "../src/crystal_click"
require "./support/compact_part_writer_w269_fixture"
require "file_utils"
require "json"

module CompactPartWriterW269Helper
  extend self

  FORMAT          = "compact_part_writer_w269_helper_v1"
  MAX_RAW_BYTES   = 64_i64 * 1024 * 1024
  MAX_FILE_BYTES  = MAX_RAW_BYTES + 1024_i64 * 1024
  MAX_FRAME_COUNT = 100_000
  WINDOWS         = {
    "full"      => {0, CompactPartWriterW269Fixture::MARK_COUNT},
    "middle"    => {1, 1},
    "last_mark" => {CompactPartWriterW269Fixture::MARK_COUNT - 1, 1},
    "empty"     => {CompactPartWriterW269Fixture::MARK_COUNT, 0},
  }

  def run(args : Array(String)) : String
    action = args[0]? || raise ArgumentError.new("expected write-generated, audit, read, copy-mutant, or verify-checksum")
    report = case action
             when "write-generated"
               raise ArgumentError.new("usage: helper write-generated DEST mrk3|mrk4 map|map_with_buckets basic|compact") unless args.size == 5
               write_generated(args[1], args[2], args[3], args[4])
             when "audit"
               raise ArgumentError.new("usage: helper audit PART map|map_with_buckets basic|compact") unless args.size == 4
               audit(validate_part(args[1]), args[2], args[3])
             when "read"
               raise ArgumentError.new("usage: helper read PART COLUMN FIRST_MARK MARK_COUNT") unless args.size == 5
               read_selected(validate_part(args[1]), args[2], args[3].to_i, args[4].to_i)
             when "copy-mutant"
               raise ArgumentError.new("usage: helper copy-mutant resealed SOURCE DEST COLUMN MARK") unless args.size == 6 && args[1] == "resealed"
               copy_mutant(args[2], args[3], args[4], args[5].to_i)
             when "verify-checksum"
               raise ArgumentError.new("usage: helper verify-checksum PART FILE") unless args.size == 3
               verify_checksum(validate_part(args[1]), args[2])
             else
               raise ArgumentError.new("unknown helper action: #{action}")
             end
    report.to_json
  end

  private def json(value : T) : JSON::Any forall T
    JSON.parse(value.to_json)
  end

  private def validate_part(path : String) : String
    expanded = File.expand_path(path)
    unless Dir.exists?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded
      raise CrystalClick::InvalidPartError.new("W269 part must be a canonical non-symlink directory")
    end
    expanded
  end

  private def validate_new_destination(path : String) : String
    expanded = File.expand_path(path)
    raise ArgumentError.new("W269 destination already exists or is symlinked") if File.exists?(expanded) || File.symlink?(expanded)
    parent = File.dirname(expanded)
    unless Dir.exists?(parent) && !File.symlink?(parent) && File.realpath(parent) == parent
      raise ArgumentError.new("W269 destination parent must already be canonical and non-symlinked")
    end
    expanded
  end

  private def read_bytes(path : String) : Bytes
    unless File.file?(path) && !File.symlink?(path)
      raise CrystalClick::CorruptPartError.new("W269 expected a regular non-symlink file")
    end
    size = File.size(path)
    if size < 0 || size > MAX_FILE_BYTES
      raise CrystalClick::CorruptPartError.new("W269 file exceeds its bounded read size")
    end
    File.read(path).to_slice.dup
  end

  private def read_u64_le(bytes : Bytes, offset : Int) : UInt64
    if offset < 0 || offset > bytes.size - 8
      raise CrystalClick::CorruptPartError.new("W269 truncated UInt64 field")
    end
    value = 0_u64
    8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
    value
  end

  private def write_generated(destination : String, format_name : String, shared_layout : String, variant_mode : String) : JSON::Any
    part = validate_new_destination(destination)
    mark_format = case format_name
                  when "mrk3" then CrystalClick::CompactMarkFormat::Mrk3
                  when "mrk4" then CrystalClick::CompactMarkFormat::Mrk4
                  else             raise ArgumentError.new("mark format must be mrk3 or mrk4")
                  end
    mode = case variant_mode
           when "basic"   then CrystalClick::CompactVariantDiscriminatorMode::Basic
           when "compact" then CrystalClick::CompactVariantDiscriminatorMode::Compact
           else                raise ArgumentError.new("Variant mode must be basic or compact")
           end
    validate_layout!(shared_layout)
    CrystalClick::CompactPartWriter.write_uint64_columns(
      part,
      CompactPartWriterW269Fixture::KEY_NAME,
      CompactPartWriterW269Fixture::KEYS,
      CompactPartWriterW269Fixture.columns(shared_layout),
      CompactPartWriterW269Fixture::ROWS_PER_MARK,
      CompactPartWriterW269Fixture::FRAME_BYTES,
      mark_format: mark_format,
      variant_discriminator_mode: mode,
    )
    json({
      "format"                     => FORMAT,
      "action"                     => "write-generated",
      "status"                     => "ok",
      "part_path"                  => part,
      "row_count"                  => CompactPartWriterW269Fixture::ROW_COUNT,
      "mark_format"                => format_name,
      "shared_layout"              => shared_layout,
      "variant_discriminator_mode" => mode.value,
      "site_keys"                  => [
        CompactPartWriterW269Fixture::ROOT_SITE,
        CompactPartWriterW269Fixture::ARRAY_SITE,
        CompactPartWriterW269Fixture::TAGGED_SITE,
        CompactPartWriterW269Fixture::LEFT_SITE,
        CompactPartWriterW269Fixture::RIGHT_SITE,
      ],
      "statistics_source" => "literal six-row INSERT-block census in the fixture; first-mark and final-part counts are not recomputed",
    })
  end

  private def validate_layout!(layout : String) : Nil
    unless layout == "map" || layout == "map_with_buckets"
      raise ArgumentError.new("W269 shared layout must be map or map_with_buckets")
    end
  end

  private def audit(part : String, shared_layout : String, variant_mode : String) : JSON::Any
    validate_layout!(shared_layout)
    unless variant_mode == "basic" || variant_mode == "compact"
      raise ArgumentError.new("W269 Variant mode must be basic or compact")
    end
    physical = CrystalClick::CompactPartPhysicalContext.open(part)
    fixture = CompactPartWriterW269Fixture
    expected_rows = Array(UInt64).new(CompactPartWriterW269Fixture::MARK_COUNT) { CompactPartWriterW269Fixture::ROWS_PER_MARK.to_u64 }
    unless physical.row_count == CompactPartWriterW269Fixture::ROW_COUNT && physical.granule_count == CompactPartWriterW269Fixture::MARK_COUNT && physical.mark_row_counts == expected_rows
      raise CrystalClick::CorruptPartError.new("W269 part dimensions differ from the six-row, three-mark witness")
    end

    data = read_bytes(File.join(part, "data.bin"))
    raw = CrystalClick::CompressedBlock.decode_all(data, max_output_size: MAX_RAW_BYTES)
    checksums = CrystalClick::PartChecksums.open(part)
    mark_name = physical.mode.mrk4? ? "data.mrk4" : "data.mrk3"
    checksums.validate_selected_entries(part, "data.bin", mark_name)
    mark_bytes = read_bytes(File.join(part, mark_name))
    mark_tape = audit_mark_tape(physical, mark_bytes, data.size.to_u64, raw.size.to_u64)
    callback_shards = read_callback_shards(physical)
    prefix_observation = decode_prefixes(callback_shards, shared_layout, variant_mode, physical.mode.mrk4?)
    windows = read_windows(part)
    json({
      "format"                  => FORMAT,
      "action"                  => "audit",
      "status"                  => "ok",
      "mark_format"             => physical.mode.mrk4? ? "mrk4" : "mrk3",
      "row_count"               => physical.row_count,
      "granule_count"           => physical.granule_count,
      "mark_rows"               => physical.mark_row_counts,
      "physical_roster"         => physical.physical_roster.map { |slot| {"column" => slot.column_name, "stream" => slot.stream_name || ""} },
      "physical_mark_tape"      => mark_tape,
      "data_bin_bytes"          => data.size,
      "raw_data_hex"            => raw.hexstring,
      "callback_shards"         => callback_shards,
      "prefix_observation"      => prefix_observation,
      "windows"                 => windows,
      "metadata"                => metadata_observation(part),
      "callback_audit_boundary" => physical.mode.mrk4? ? "named physical callbacks and raw prefix bytes are exposed" : "MRK3 exposes whole-column slots only; recursive reader semantics and complete whole-column mark decoding are exposed, not callback-name coordinates",
      "claim_boundary"          => "whole-mark grid and EOF coordinates are audited; no granule-only IO claim is made",
    })
  end

  private def audit_mark_tape(
    physical : CrystalClick::CompactPartPhysicalContext,
    bytes : Bytes,
    compressed_size : UInt64,
    raw_size : UInt64,
  ) : JSON::Any
    slot_count = physical.physical_roster.size
    width = slot_count * 16 + 8
    record_count = CompactPartWriterW269Fixture::MARK_COUNT + 1
    unless slot_count > 0 && bytes.size == width * record_count
      raise CrystalClick::CorruptPartError.new("W269 mark tape dimensions differ from its physical roster")
    end
    records = Array(JSON::Any).new(record_count)
    (0...record_count).each do |mark|
      start = mark * width
      pairs = Array(JSON::Any).new(slot_count)
      slot_count.times do |slot|
        offset = start + slot * 16
        compressed_offset = read_u64_le(bytes, offset)
        decompressed_offset = read_u64_le(bytes, offset + 8)
        logical = physical.logical_position({compressed_offset, decompressed_offset})
        unless logical >= 0 && logical.to_u64 <= raw_size && compressed_offset <= compressed_size
          raise CrystalClick::CorruptPartError.new("W269 mark coordinate escaped data.bin")
        end
        pairs << JSON::Any.new({
          "slot"                => JSON::Any.new(slot.to_i64),
          "compressed_offset"   => JSON::Any.new(compressed_offset.to_i64),
          "decompressed_offset" => JSON::Any.new(decompressed_offset.to_i64),
          "logical_position"    => JSON::Any.new(logical),
        })
      end
      rows = read_u64_le(bytes, start + slot_count * 16)
      expected = mark < CompactPartWriterW269Fixture::MARK_COUNT ? CompactPartWriterW269Fixture::ROWS_PER_MARK.to_u64 : 0_u64
      unless rows == expected
        raise CrystalClick::CorruptPartError.new("W269 mark row trailer differs at mark #{mark}")
      end
      records << JSON::Any.new({
        "mark"      => JSON::Any.new(mark.to_i64),
        "row_count" => JSON::Any.new(rows.to_i64),
        "pairs"     => JSON::Any.new(pairs),
      } of String => JSON::Any)
    end
    eof = records.last.as_h["pairs"].as_a
    unless eof.all? do |pair|
             fields = pair.as_h
             fields["compressed_offset"].as_i64.to_u64 == compressed_size &&
             fields["decompressed_offset"].as_i64.zero? && fields["logical_position"].as_i64.to_u64 == raw_size
           end
      raise CrystalClick::CorruptPartError.new("W269 terminal MRK record is not all-slot EOF")
    end
    json({
      "file"            => physical.mode.mrk4? ? "data.mrk4" : "data.mrk3",
      "slot_count"      => slot_count,
      "record_width"    => width,
      "byte_size"       => bytes.size,
      "compressed_size" => compressed_size,
      "raw_size"        => raw_size,
      "records"         => records,
    })
  end

  private def read_callback_shards(physical : CrystalClick::CompactPartPhysicalContext) : Array(JSON::Any)
    names = [
      CompactPartWriterW269Fixture::KEY_NAME,
      CompactPartWriterW269Fixture::ROOT_COLUMN,
      CompactPartWriterW269Fixture::ARRAY_COLUMN,
      CompactPartWriterW269Fixture::TAGGED_COLUMN,
      CompactPartWriterW269Fixture::PAIR_COLUMN,
    ]
    windows = Hash(String, CrystalClick::CompactPartPhysicalWindow).new
    names.each { |name| windows[name] = physical.read_window(name, 0, physical.granule_count) }
    result = [] of JSON::Any
    physical.granule_count.times do |mark|
      names.each do |column|
        windows[column].granules[mark].shards.each do |shard|
          result << JSON::Any.new({
            "column"        => JSON::Any.new(column),
            "mark"          => JSON::Any.new(mark.to_i64),
            "slot"          => JSON::Any.new(shard.slot_index.to_i64),
            "stream"        => JSON::Any.new(shard.stream_name || ""),
            "logical_start" => JSON::Any.new(shard.logical_start),
            "logical_end"   => JSON::Any.new(shard.logical_end),
            "byte_count"    => JSON::Any.new(shard.bytes.size.to_i64),
            "bytes_hex"     => JSON::Any.new(shard.bytes.hexstring),
          })
        end
      end
    end
    result
  end

  private def decode_prefixes(
    shards : Array(JSON::Any),
    shared_layout : String,
    variant_mode : String,
    named_callbacks : Bool,
  ) : JSON::Any
    return JSON::Any.new({"state" => JSON::Any.new("mrk3_named_callbacks_not_persisted")} of String => JSON::Any) unless named_callbacks
    expected_shared = shared_layout == "map" ? 0_u64 : 1_u64
    expected_buckets = shared_layout == "map" ? 1_u64 : 2_u64
    structures = [] of JSON::Any
    dynamics = [] of JSON::Any
    variants = [] of JSON::Any
    shards.each do |shard|
      fields = shard.as_h
      stream = fields["stream"].as_s
      bytes = decode_hex(fields["bytes_hex"].as_s)
      if stream.ends_with?(".object_structure")
        object = CrystalClick::ObjectStructureCodec.decode(bytes)
        unless object.version == 4_u64 && object.shared_data_version == expected_shared && object.bucket_count == expected_buckets
          raise CrystalClick::CorruptPartError.new("W269 Object prefix version/shared layout differs at #{stream}")
        end
        statistics = object.statistics
        structures << JSON::Any.new({
          "column"              => fields["column"],
          "mark"                => fields["mark"],
          "stream"              => fields["stream"],
          "version"             => JSON::Any.new(object.version.to_i64),
          "dynamic_paths"       => JSON::Any.new(object.dynamic_paths.map { |path| JSON::Any.new(path) }),
          "shared_data_version" => JSON::Any.new(object.shared_data_version.to_i64),
          "bucket_count"        => JSON::Any.new(object.bucket_count.to_i64),
          "statistics_flag"     => JSON::Any.new(statistics.nil? ? 0_i64 : 1_i64),
          "statistics"          => statistics_json(statistics),
        } of String => JSON::Any)
      elsif stream.ends_with?(".dynamic_structure")
        dynamic = CrystalClick::DynamicStructureCodec.decode(bytes)
        dynamics << JSON::Any.new({
          "column"          => fields["column"],
          "mark"            => fields["mark"],
          "stream"          => fields["stream"],
          "version"         => JSON::Any.new(dynamic.version.to_i64),
          "ordinary_types"  => JSON::Any.new(dynamic.types.map { |type| JSON::Any.new(type.name) }),
          "statistics_flag" => JSON::Any.new(dynamic.statistics.nil? ? 0_i64 : 1_i64),
          "statistics"      => statistics_json(dynamic.statistics),
        } of String => JSON::Any)
      elsif stream.ends_with?(".variant_discr_prefix")
        unless bytes.size == 8
          raise CrystalClick::CorruptPartError.new("W269 Variant discriminator prefix is not an LE UInt64")
        end
        mode = read_u64_le(bytes, 0)
        expected_mode = variant_mode == "compact" ? 1_u64 : 0_u64
        unless mode == expected_mode
          raise CrystalClick::CorruptPartError.new("W269 Variant discriminator mode differs at #{stream}")
        end
        variants << JSON::Any.new({
          "column"     => fields["column"],
          "mark"       => fields["mark"],
          "stream"     => fields["stream"],
          "prefix_hex" => fields["bytes_hex"],
          "mode"       => JSON::Any.new(mode.to_i64),
        })
      end
    end
    unless structures.any? && dynamics.any?
      raise CrystalClick::CorruptPartError.new("W269 named callback audit did not find Object and Dynamic structure prefixes")
    end
    json({"state" => "decoded_named_prefixes", "object_structures" => structures, "dynamic_structures" => dynamics, "variant_prefixes" => variants})
  end

  private def statistics_json(statistics : CrystalClick::StructureStatistics?) : JSON::Any
    if value = statistics
      json({
        "counts" => value.counts.map(&.to_i64),
        "shared" => value.shared.map { |entry| {"name_hex" => entry.name.to_slice.hexstring, "count" => entry.count.to_i64} },
      })
    else
      JSON::Any.new(nil)
    end
  end

  private def metadata_observation(part : String) : JSON::Any
    path = File.join(part, "serialization.json")
    return JSON::Any.new(nil) unless File.file?(path) && !File.symlink?(path)
    text = read_bytes(path)
    JSON.parse(String.new(text))
  rescue ex : JSON::ParseException
    raise CrystalClick::CorruptPartError.new("W269 serialization.json is invalid JSON: #{ex.message}")
  end

  private def read_windows(part : String) : JSON::Any
    fixture = CompactPartWriterW269Fixture
    readers = {
      CompactPartWriterW269Fixture::ROOT_COLUMN   => nil.as(CrystalClick::CompactRecursiveJsonColumnReader?),
      CompactPartWriterW269Fixture::ARRAY_COLUMN  => nil.as(CrystalClick::CompactRecursiveJsonColumnReader?),
      CompactPartWriterW269Fixture::TAGGED_COLUMN => nil.as(CrystalClick::CompactRecursiveJsonColumnReader?),
      CompactPartWriterW269Fixture::PAIR_COLUMN   => nil.as(CrystalClick::CompactRecursiveJsonColumnReader?),
    }
    fixture.schemas.each do |name, schema|
      readers[name] = CrystalClick::CompactRecursiveJsonColumnReader.open(part, name, schema)
    end
    output = Hash(String, JSON::Any).new
    WINDOWS.each do |window_name, span|
      columns = Hash(String, JSON::Any).new
      readers.each do |column, reader|
        selected = reader || raise CrystalClick::CorruptPartError.new("W269 recursive JSON reader was not opened")
        values = selected.read_marks(span[0], span[1]).flatten
        columns[column] = JSON::Any.new(values.map { |value| CompactPartWriterW269Fixture.signatures(value) })
      end
      output[window_name] = JSON::Any.new(columns)
    end
    JSON::Any.new(output)
  end

  private def read_selected(part : String, column : String, first_mark : Int32, mark_count : Int32) : JSON::Any
    fixture = CompactPartWriterW269Fixture
    unless first_mark >= 0 && mark_count >= 0 && first_mark <= CompactPartWriterW269Fixture::MARK_COUNT && mark_count <= CompactPartWriterW269Fixture::MARK_COUNT - first_mark
      raise ArgumentError.new("W269 mark selection is outside the witness grid")
    end
    schema = fixture.schemas[column]? || raise ArgumentError.new("W269 column is outside the four JSON sites")
    reader = CrystalClick::CompactRecursiveJsonColumnReader.open(part, column, schema)
    values = reader.read_marks(first_mark, mark_count).flatten
    json({
      "format"     => FORMAT,
      "action"     => "read",
      "status"     => "accepted",
      "column"     => column,
      "first_mark" => first_mark,
      "mark_count" => mark_count,
      "row_count"  => values.size,
      "signatures" => values.map { |value| fixture.signatures(value) },
    })
  rescue error : CrystalClick::Error
    json({
      "format"        => FORMAT,
      "action"        => "read",
      "status"        => "rejected",
      "column"        => column,
      "first_mark"    => first_mark,
      "mark_count"    => mark_count,
      "error_class"   => error.class.name,
      "error_message" => error.message || "",
    })
  end

  private def copy_mutant(source_path : String, destination_path : String, column : String, mark : Int32) : JSON::Any
    source = validate_part(source_path)
    destination = validate_new_destination(destination_path)
    if destination == source || destination.starts_with?(source + File::SEPARATOR)
      raise ArgumentError.new("W269 mutant destination must be outside its source part")
    end
    unless column == CompactPartWriterW269Fixture::TAGGED_COLUMN && mark == 1
      raise ArgumentError.new("W269 resealed Object-version mutant is fixed to tagged_json mark 1")
    end
    FileUtils.cp_r(source, destination)
    physical = CrystalClick::CompactPartPhysicalContext.open(destination)
    raise CrystalClick::UnsupportedFormatError.new("W269 prefix mutation requires MRK4") unless physical.mode.mrk4?
    window = physical.read_window(column, mark, 1)
    prefix = window.granules.first.shards.find { |shard| shard.stream_name.try(&.ends_with?(".object_structure")) } ||
             raise CrystalClick::CorruptPartError.new("W269 tagged Object structure callback is absent")
    before = CrystalClick::ObjectStructureCodec.decode(prefix.bytes)
    unless before.version == 4_u64
      raise CrystalClick::CorruptPartError.new("W269 mutation source Object structure version is not 4")
    end
    data_path = File.join(destination, "data.bin")
    compressed = read_bytes(data_path)
    raw = CrystalClick::CompressedBlock.decode_all(compressed, max_output_size: MAX_RAW_BYTES)
    offset = prefix.logical_start.to_i
    if offset < 0 || offset >= raw.size
      raise CrystalClick::CorruptPartError.new("W269 Object callback offset is outside data.bin")
    end
    original_raw = Bytes.new(raw.size) { |index| raw[index] }
    raw[offset] = 3_u8
    unless read_u64_le(raw, offset) == 3_u64
      raise CrystalClick::CorruptPartError.new("W269 Object structure mutation did not set flattened wire value 3")
    end
    rebuilt, frame_count = rebuild_equal_sized_frames(compressed, raw)
    replacement_raw = CrystalClick::CompressedBlock.decode_all(rebuilt, max_output_size: MAX_RAW_BYTES)
    changed = [] of Int32
    original_raw.each_with_index { |byte, index| changed << index.to_i32 if replacement_raw[index] != byte }
    unless changed == [offset.to_i32] && rebuilt.size == compressed.size
      raise CrystalClick::CorruptPartError.new("W269 Object mutation changed bytes outside the one version byte or moved frame coordinates")
    end
    File.write(data_path, rebuilt)
    reseal_checksums!(destination)
    json({
      "format"                 => FORMAT,
      "action"                 => "copy-mutant",
      "status"                 => "ok",
      "mode"                   => "resealed",
      "source_path"            => source,
      "mutant_path"            => destination,
      "column"                 => column,
      "stream"                 => prefix.stream_name || "",
      "mark"                   => mark,
      "version_before"         => before.version,
      "version_after"          => 3_u64,
      "logical_offset"         => offset,
      "raw_changed_offsets"    => changed,
      "compressed_size_before" => compressed.size,
      "compressed_size_after"  => rebuilt.size,
      "raw_size"               => raw.size,
      "frame_count"            => frame_count,
      "checksums_resealed"     => true,
    })
  end

  private def rebuild_equal_sized_frames(compressed : Bytes, raw : Bytes) : Tuple(Bytes, Int32)
    rebuilt = IO::Memory.new(compressed.size)
    compressed_offset = 0_i64
    logical_start = 0_i64
    frame_count = 0_i32
    while compressed_offset < compressed.size.to_i64
      if frame_count >= MAX_FRAME_COUNT
        raise CrystalClick::CorruptPartError.new("W269 LZ4 frame count exceeds its audit bound")
      end
      frame = CrystalClick::CompressedBlock.decode_frame(compressed, compressed_offset)
      frame_bytes = CrystalClick::PartWriterInfrastructure::StreamEncoding.encode_lz4_frame(
        raw[logical_start.to_i, frame.output.size],
      )
      unless frame_bytes.size.to_i64 == frame.end_offset - compressed_offset
        raise CrystalClick::CorruptPartError.new("W269 resealed LZ4 frame size differs and would move mark coordinates")
      end
      rebuilt.write(frame_bytes)
      logical_start += frame.output.size
      compressed_offset = frame.end_offset
      frame_count += 1
    end
    unless logical_start == raw.size && rebuilt.size == compressed.size
      raise CrystalClick::CorruptPartError.new("W269 resealed frames do not cover the whole data stream")
    end
    {rebuilt.to_slice, frame_count}
  end

  private def folded_hash(raw : Bytes) : {UInt64, UInt64}
    digest = CrystalClick::CityHashV1.file_hash(raw)
    bytes = Bytes.new(16, 0_u8)
    8.times do |index|
      bytes[index] = ((digest[0] >> (index * 8)) & 0xff).to_u8
      bytes[8 + index] = ((digest[1] >> (index * 8)) & 0xff).to_u8
    end
    CrystalClick::CityHashV1.hash128_with_seed(bytes, 0_u64, 0_u64)
  end

  private def reseal_checksums!(part : String) : Nil
    existing = CrystalClick::PartChecksums.open(part)
    records = [] of CrystalClick::PartWriterInfrastructure::ChecksumRecord
    existing.entries.each do |name, entry|
      bytes = read_bytes(File.join(part, name))
      hash = CrystalClick::CityHashV1.file_hash(bytes)
      if entry.compressed
        raw = CrystalClick::CompressedBlock.decode_all(bytes, max_output_size: MAX_RAW_BYTES)
        unless raw.size.to_u64 == entry.uncompressed_size
          raise CrystalClick::CorruptPartError.new("W269 resealed compressed stream raw size differs")
        end
        records << CrystalClick::PartWriterInfrastructure::ChecksumRecord.new(name, bytes.size.to_u64, hash, true, raw.size.to_u64, folded_hash(raw))
      else
        records << CrystalClick::PartWriterInfrastructure::ChecksumRecord.new(name, bytes.size.to_u64, hash, false)
      end
    end
    CrystalClick::PartWriterInfrastructure::PartChecksumsWriter.write(part, records)
  end

  private def verify_checksum(part : String, name : String) : JSON::Any
    checksums = CrystalClick::PartChecksums.open(part)
    entry = checksums.entry(name) || raise CrystalClick::CorruptPartError.new("W269 checksum entry is absent")
    bytes = read_bytes(File.join(part, name))
    actual_hash = CrystalClick::CityHashV1.file_hash(bytes)
    json({
      "format"                 => FORMAT,
      "action"                 => "verify-checksum",
      "status"                 => actual_hash == entry.file_hash ? "accepted" : "rejected",
      "file"                   => name,
      "physical_size"          => bytes.size,
      "declared_physical_size" => entry.physical_size.to_i64,
      "file_hash_matches"      => actual_hash == entry.file_hash,
      "expected_file_hash"     => "#{entry.file_hash[0].to_s(16)}:#{entry.file_hash[1].to_s(16)}",
      "actual_file_hash"       => "#{actual_hash[0].to_s(16)}:#{actual_hash[1].to_s(16)}",
    })
  end

  private def decode_hex(value : String) : Bytes
    unless value.bytesize.even? && value.bytesize <= MAX_RAW_BYTES * 2
      raise CrystalClick::CorruptPartError.new("W269 hex payload exceeds its bound")
    end
    bytes = Bytes.new(value.bytesize // 2)
    source = value.to_slice
    bytes.size.times do |index|
      bytes[index] = ((hex_nibble(source[index * 2]) << 4) | hex_nibble(source[index * 2 + 1])).to_u8
    end
    bytes
  end

  private def hex_nibble(byte : UInt8) : UInt8
    case byte
    when 48_u8..57_u8  then byte - 48_u8
    when 97_u8..102_u8 then byte - 87_u8
    else
      raise CrystalClick::CorruptPartError.new("W269 hex data is not canonical lowercase")
    end
  end
end

begin
  puts CompactPartWriterW269Helper.run(ARGV)
rescue error
  STDERR.puts "W269 helper failed: #{error.class}: #{error.message}"
  exit 1
end
