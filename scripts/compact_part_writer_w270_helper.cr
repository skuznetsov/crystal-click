require "../src/crystal_click"
require "./support/compact_part_writer_w270_fixture"
require "file_utils"
require "json"

module CompactPartWriterW270Helper
  extend self

  FORMAT          = "compact_part_writer_w270_helper_v1"
  MAX_RAW_BYTES   = 64_i64 * 1024 * 1024
  MAX_FILE_BYTES  = MAX_RAW_BYTES + 1024_i64 * 1024
  MAX_FRAME_COUNT = 100_000

  def run(args : Array(String)) : String
    action = args[0]? || raise ArgumentError.new("expected write-main, write-uint8-witness, read-main, or copy-mutant")
    report = case action
             when "write-main"
               raise ArgumentError.new("usage: helper write-main DEST mrk3|mrk4 map|map_with_buckets basic|compact") unless args.size == 5
               write_main(args[1], args[2], args[3], args[4])
             when "write-uint8-witness"
               raise ArgumentError.new("usage: helper write-uint8-witness DEST mrk3|mrk4 basic|compact") unless args.size == 4
               write_uint8_witness(args[1], args[2], args[3])
             when "read-main"
               raise ArgumentError.new("usage: helper read-main PART COLUMN FIRST_MARK MARK_COUNT") unless args.size == 5
               read_main(args[1], args[2], args[3].to_i, args[4].to_i)
             when "read-uint8-witness"
               raise ArgumentError.new("usage: helper read-uint8-witness PART FIRST_MARK MARK_COUNT") unless args.size == 4
               read_uint8_witness(args[1], args[2].to_i, args[3].to_i)
             when "copy-mutant"
               raise ArgumentError.new("usage: helper copy-mutant resealed SOURCE DEST COLUMN MARK TYPE") unless args.size == 7 && args[1] == "resealed"
               copy_dynamic_version_mutant(args[2], args[3], args[4], args[5].to_i, args[6])
             when "copy-array-size-mutant"
               raise ArgumentError.new("usage: helper copy-array-size-mutant resealed SOURCE DEST") unless args.size == 4 && args[1] == "resealed"
               copy_array_size_mutant(args[2], args[3])
             else
               raise ArgumentError.new("unknown W270 helper action: #{action}")
             end
    report.to_json
  end

  private def json(value : T) : JSON::Any forall T
    JSON.parse(value.to_json)
  end

  private def validate_new_destination(path : String) : String
    expanded = File.expand_path(path)
    if File.exists?(expanded) || File.symlink?(expanded)
      raise ArgumentError.new("W270 destination already exists or is symlinked")
    end
    parent = File.dirname(expanded)
    unless Dir.exists?(parent) && !File.symlink?(parent) && File.realpath(parent) == parent
      raise ArgumentError.new("W270 destination parent must already be canonical and non-symlinked")
    end
    expanded
  end

  private def validate_part(path : String) : String
    expanded = File.expand_path(path)
    unless Dir.exists?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded
      raise CrystalClick::InvalidPartError.new("W270 source part must be a canonical non-symlink directory")
    end
    expanded
  end

  private def mark_format(name : String) : CrystalClick::CompactMarkFormat
    case name
    when "mrk3" then CrystalClick::CompactMarkFormat::Mrk3
    when "mrk4" then CrystalClick::CompactMarkFormat::Mrk4
    else             raise ArgumentError.new("W270 mark format must be mrk3 or mrk4")
    end
  end

  private def discriminator_mode(name : String) : CrystalClick::CompactVariantDiscriminatorMode
    case name
    when "basic"   then CrystalClick::CompactVariantDiscriminatorMode::Basic
    when "compact" then CrystalClick::CompactVariantDiscriminatorMode::Compact
    else                raise ArgumentError.new("W270 Variant mode must be basic or compact")
    end
  end

  private def validate_layout(name : String) : Nil
    unless name == "map" || name == "map_with_buckets"
      raise ArgumentError.new("W270 shared layout must be map or map_with_buckets")
    end
  end

  private def write_main(destination : String, mark_name : String, layout : String, mode_name : String) : JSON::Any
    part = validate_new_destination(destination)
    validate_layout(layout)
    CrystalClick::CompactPartWriter.write_uint64_columns(
      part,
      CompactPartWriterW270NativeFixture::KEY_NAME,
      CompactPartWriterW270NativeFixture::KEYS,
      CompactPartWriterW270NativeFixture.columns(layout),
      CompactPartWriterW270NativeFixture::ROWS_PER_MARK,
      CompactPartWriterW270NativeFixture::FRAME_BYTES,
      mark_format: mark_format(mark_name),
      variant_discriminator_mode: discriminator_mode(mode_name),
    )
    json({
      "format"                     => FORMAT,
      "action"                     => "write-main",
      "status"                     => "ok",
      "part_path"                  => part,
      "row_count"                  => CompactPartWriterW270NativeFixture::ROW_COUNT,
      "mark_count"                 => CompactPartWriterW270NativeFixture::MARK_COUNT,
      "mark_format"                => mark_name,
      "shared_layout"              => layout,
      "variant_discriminator_mode" => mode_name == "compact" ? 1 : 0,
      "fixture"                    => "six literal rows / three two-row marks; full INSERT-block Object and Dynamic statistics",
    })
  end

  private def write_uint8_witness(destination : String, mark_name : String, mode_name : String) : JSON::Any
    part = validate_new_destination(destination)
    CrystalClick::CompactPartWriter.write_uint64_columns(
      part,
      CompactPartWriterW270UInt8NativeFixture::KEY_NAME,
      CompactPartWriterW270UInt8NativeFixture::KEYS,
      ([CompactPartWriterW270UInt8NativeFixture.column] of CrystalClick::CompactPartColumn),
      CompactPartWriterW270UInt8NativeFixture::ROWS_PER_MARK,
      CompactPartWriterW270UInt8NativeFixture::FRAME_BYTES,
      mark_format: mark_format(mark_name),
      variant_discriminator_mode: discriminator_mode(mode_name),
    )
    json({
      "format"                            => FORMAT,
      "action"                            => "write-uint8-witness",
      "status"                            => "ok",
      "part_path"                         => part,
      "row_count"                         => CompactPartWriterW270UInt8NativeFixture::ROW_COUNT,
      "mark_count"                        => CompactPartWriterW270UInt8NativeFixture::MARK_COUNT,
      "mark_format"                       => mark_name,
      "shared_layout"                     => "map",
      "variant_discriminator_mode"        => mode_name == "compact" ? 1 : 0,
      "typed_dynamic_type"                => "Array(UInt8)",
      "fixture_source"                    => "scripts/support/compact_part_writer_w270_fixture.cr",
      "dynamic_prefix_full_insert_counts" => [3_u64, 0_u64],
      "key_count"                         => CompactPartWriterW270UInt8NativeFixture::KEYS.size,
      "rows_per_mark"                     => CompactPartWriterW270UInt8NativeFixture::ROWS_PER_MARK,
    })
  end

  private def read_main(part_path : String, column : String, first_mark : Int32, mark_count : Int32) : JSON::Any
    part = validate_part(part_path)
    fixture = CompactPartWriterW270NativeFixture
    unless first_mark >= 0 && mark_count >= 0 && first_mark <= CompactPartWriterW270NativeFixture::MARK_COUNT &&
           mark_count <= CompactPartWriterW270NativeFixture::MARK_COUNT - first_mark
      raise ArgumentError.new("W270 selected mark window is outside the three-mark witness")
    end
    schema = fixture.schemas[column]? || raise ArgumentError.new("W270 JSON column is outside the four-site witness")
    reader = CrystalClick::CompactRecursiveJsonColumnReader.open(part, column, schema)
    values = reader.read_marks(first_mark, mark_count).flatten
    json({
      "format"     => FORMAT,
      "action"     => "read-main",
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
      "action"        => "read-main",
      "status"        => "rejected",
      "column"        => column,
      "first_mark"    => first_mark,
      "mark_count"    => mark_count,
      "error_class"   => error.class.name,
      "error_message" => error.message || "",
    })
  end

  private def read_uint8_witness(part_path : String, first_mark : Int32, mark_count : Int32) : JSON::Any
    part = validate_part(part_path)
    unless first_mark >= 0 && mark_count >= 0 &&
           first_mark <= CompactPartWriterW270UInt8NativeFixture::MARK_COUNT &&
           mark_count <= CompactPartWriterW270UInt8NativeFixture::MARK_COUNT - first_mark
      raise ArgumentError.new("W270 UInt8 witness mark window is outside its four-mark grid")
    end
    reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
      part,
      CompactPartWriterW270UInt8NativeFixture::COLUMN_NAME,
      CompactPartWriterW270UInt8NativeFixture.schema,
    )
    values = reader.read_marks(first_mark, mark_count).flatten
    json({
      "format"     => FORMAT,
      "action"     => "read-uint8-witness",
      "status"     => "accepted",
      "column"     => CompactPartWriterW270UInt8NativeFixture::COLUMN_NAME,
      "first_mark" => first_mark,
      "mark_count" => mark_count,
      "row_count"  => values.size,
      "signatures" => values.map { |value| CompactPartWriterW270NativeFixture.signatures(value) },
    })
  rescue error : CrystalClick::Error
    json({
      "format"        => FORMAT,
      "action"        => "read-uint8-witness",
      "status"        => "rejected",
      "column"        => CompactPartWriterW270UInt8NativeFixture::COLUMN_NAME,
      "first_mark"    => first_mark,
      "mark_count"    => mark_count,
      "error_class"   => error.class.name,
      "error_message" => error.message || "",
    })
  end

  private def read_bytes(path : String) : Bytes
    unless File.file?(path) && !File.symlink?(path)
      raise CrystalClick::CorruptPartError.new("W270 expected a regular non-symlink file")
    end
    size = File.size(path)
    if size < 0 || size > MAX_FILE_BYTES
      raise CrystalClick::CorruptPartError.new("W270 file exceeds its bounded read size")
    end
    File.read(path).to_slice.dup
  end

  private def read_u64_le(bytes : Bytes, offset : Int) : UInt64
    if offset < 0 || offset > bytes.size - 8
      raise CrystalClick::CorruptPartError.new("W270 truncated UInt64 field")
    end
    value = 0_u64
    8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
    value
  end

  private def copy_dynamic_version_mutant(
    source_path : String,
    destination_path : String,
    column : String,
    mark : Int32,
    ordinary_type : String,
  ) : JSON::Any
    source = validate_part(source_path)
    destination = validate_new_destination(destination_path)
    if destination == source || destination.starts_with?(source + File::SEPARATOR)
      raise ArgumentError.new("W270 mutant destination must be outside its source part")
    end
    unless column == CompactPartWriterW270NativeFixture::ARRAY_COLUMN && mark == 1
      raise ArgumentError.new("W270 middle typed-Dynamic mutation is fixed to array_json mark 1")
    end

    FileUtils.cp_r(source, destination)
    physical = CrystalClick::CompactPartPhysicalContext.open(destination)
    raise CrystalClick::UnsupportedFormatError.new("W270 typed-Dynamic prefix mutation requires MRK4") unless physical.mode.mrk4?
    window = physical.read_window(column, mark, 1)
    candidates = window.granules.first.shards.select do |shard|
      next false unless shard.stream_name.try(&.ends_with?(".dynamic_structure"))
      structure = CrystalClick::DynamicStructureCodec.decode(shard.bytes)
      structure.version == CrystalClick::DynamicStructure::VERSION_V3 && structure.types.any? { |type| type.name == ordinary_type }
    end
    unless candidates.size == 1
      raise CrystalClick::CorruptPartError.new("W270 middle mark does not identify one typed-Dynamic #{ordinary_type} prefix")
    end
    prefix = candidates.first
    before = CrystalClick::DynamicStructureCodec.decode(prefix.bytes)
    data_path = File.join(destination, "data.bin")
    compressed = read_bytes(data_path)
    raw = CrystalClick::CompressedBlock.decode_all(compressed, max_output_size: MAX_RAW_BYTES)
    offset = prefix.logical_start.to_i
    if offset < 0 || offset > raw.size - 8
      raise CrystalClick::CorruptPartError.new("W270 Dynamic structure callback offset is outside data.bin")
    end
    original = Bytes.new(raw.size) { |index| raw[index] }
    raw[offset] = 3_u8
    unless read_u64_le(raw, offset) == 3_u64
      raise CrystalClick::CorruptPartError.new("W270 Dynamic version mutation did not set flattened wire value 3")
    end
    rebuilt, frame_count = rebuild_equal_sized_frames(compressed, raw)
    replacement = CrystalClick::CompressedBlock.decode_all(rebuilt, max_output_size: MAX_RAW_BYTES)
    changed = [] of Int32
    original.each_with_index { |byte, index| changed << index.to_i32 if replacement[index] != byte }
    unless changed == [offset.to_i32] && rebuilt.size == compressed.size
      raise CrystalClick::CorruptPartError.new("W270 mutation changed bytes outside the one version byte or moved frame coordinates")
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
      "ordinary_type"          => ordinary_type,
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

  private def copy_array_size_mutant(source_path : String, destination_path : String) : JSON::Any
    source = validate_part(source_path)
    destination = validate_new_destination(destination_path)
    if destination == source || destination.starts_with?(source + File::SEPARATOR)
      raise ArgumentError.new("W270 mutant destination must be outside its source part")
    end

    FileUtils.cp_r(source, destination)
    physical = CrystalClick::CompactPartPhysicalContext.open(destination)
    raise CrystalClick::UnsupportedFormatError.new("W270 Array size mutation requires MRK4") unless physical.mode.mrk4?

    column = CompactPartWriterW270NativeFixture::ROOT_COLUMN
    mark = 1
    window = physical.read_window(column, mark, 1)
    payload_prefix = CrystalClick::PhysicalStreamName.append_escaped_component(column, "payload")
    actual_type_prefix = CrystalClick::PhysicalStreamName.append_escaped_component(
      payload_prefix,
      CompactPartWriterW270NativeFixture.payload_array_type.name,
    )
    expected_stream = CrystalClick::PhysicalStreamName.append_literal(actual_type_prefix, ".size0")
    candidates = window.granules.first.shards.select { |shard| shard.stream_name == expected_stream }
    unless candidates.size == 1
      raise CrystalClick::CorruptPartError.new("W270 root_json middle callback does not contain its exact typed Array size0 stream")
    end
    shard = candidates.first
    unless shard.bytes.size == 8 && read_u64_le(shard.bytes, 0) == 0_u64
      raise CrystalClick::CorruptPartError.new("W270 root_json middle typed Array size0 is not the literal empty-array UInt64 zero")
    end

    data_path = File.join(destination, "data.bin")
    compressed = read_bytes(data_path)
    raw = CrystalClick::CompressedBlock.decode_all(compressed, max_output_size: MAX_RAW_BYTES)
    offset = shard.logical_start.to_i
    if offset < 0 || offset > raw.size - 8
      raise CrystalClick::CorruptPartError.new("W270 Array size callback offset is outside data.bin")
    end
    unless raw[offset, 8] == Bytes.new(8, 0_u8)
      raise CrystalClick::CorruptPartError.new("W270 physical size lane differs from authenticated shard bytes")
    end

    original = Bytes.new(raw.size) { |index| raw[index] }
    raw[offset] = 1_u8
    unless read_u64_le(raw, offset) == 1_u64
      raise CrystalClick::CorruptPartError.new("W270 Array size mutation did not set flattened UInt64 value one")
    end
    rebuilt, frame_count = rebuild_equal_sized_frames(compressed, raw)
    replacement = CrystalClick::CompressedBlock.decode_all(rebuilt, max_output_size: MAX_RAW_BYTES)
    changed = [] of Int32
    original.each_with_index { |byte, index| changed << index.to_i32 if replacement[index] != byte }
    unless changed == [offset.to_i32] && rebuilt.size == compressed.size
      raise CrystalClick::CorruptPartError.new("W270 mutation changed bytes outside the one size byte or moved frame coordinates")
    end

    File.write(data_path, rebuilt)
    reseal_checksums!(destination)
    json({
      "format"                 => FORMAT,
      "action"                 => "copy-array-size-mutant",
      "status"                 => "ok",
      "mode"                   => "resealed",
      "source_path"            => source,
      "mutant_path"            => destination,
      "column"                 => column,
      "stream"                 => expected_stream,
      "mark"                   => mark,
      "semantic_type"          => CompactPartWriterW270NativeFixture.payload_array_type.name,
      "value_before"           => 0_u64,
      "value_after"            => 1_u64,
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
        raise CrystalClick::CorruptPartError.new("W270 LZ4 frame count exceeds its audit bound")
      end
      frame = CrystalClick::CompressedBlock.decode_frame(compressed, compressed_offset)
      frame_bytes = CrystalClick::PartWriterInfrastructure::StreamEncoding.encode_lz4_frame(
        raw[logical_start.to_i, frame.output.size],
      )
      unless frame_bytes.size.to_i64 == frame.end_offset - compressed_offset
        raise CrystalClick::CorruptPartError.new("W270 resealed LZ4 frame size differs and would move mark coordinates")
      end
      rebuilt.write(frame_bytes)
      logical_start += frame.output.size
      compressed_offset = frame.end_offset
      frame_count += 1
    end
    unless logical_start == raw.size && rebuilt.size == compressed.size
      raise CrystalClick::CorruptPartError.new("W270 resealed frames do not cover the whole data stream")
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
          raise CrystalClick::CorruptPartError.new("W270 resealed compressed-stream raw size differs")
        end
        records << CrystalClick::PartWriterInfrastructure::ChecksumRecord.new(
          name, bytes.size.to_u64, hash, true, raw.size.to_u64, folded_hash(raw),
        )
      else
        records << CrystalClick::PartWriterInfrastructure::ChecksumRecord.new(name, bytes.size.to_u64, hash, false)
      end
    end
    CrystalClick::PartWriterInfrastructure::PartChecksumsWriter.write(part, records)
  end
end

begin
  puts CompactPartWriterW270Helper.run(ARGV)
rescue error
  STDERR.puts "W270 helper failed: #{error.class}: #{error.message}"
  exit 1
end
