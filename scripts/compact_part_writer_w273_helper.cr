require "../src/crystal_click"
require "./support/compact_part_writer_w273_native_fixture"
require "file_utils"
require "json"

module CompactPartWriterW273Helper
  extend self

  FORMAT = "compact_part_writer_w273_helper_v1"
  MAX_RAW_BYTES   = 64_i64 * 1024 * 1024
  MAX_FILE_BYTES  = MAX_RAW_BYTES + 1024_i64 * 1024
  MAX_FRAME_COUNT = 100_000

  def run(args : Array(String)) : String
    action = args[0]? || raise ArgumentError.new("expected write-native, read-native, or copy-child-dynamic-version-mutant")
    report = case action
             when "write-native"
               unless args.size == 5
                 raise ArgumentError.new("usage: helper write-native DEST DEPTH mrk3|mrk4 basic|compact")
               end
               write_native(args[1], args[2].to_i, args[3], args[4])
             when "read-native"
               unless args.size == 5
                 raise ArgumentError.new("usage: helper read-native PART DEPTH FIRST_MARK MARK_COUNT")
               end
               read_native(args[1], args[2].to_i, args[3].to_i, args[4].to_i)
             when "copy-child-dynamic-version-mutant"
               unless args.size == 6 && args[1] == "resealed"
                 raise ArgumentError.new("usage: helper copy-child-dynamic-version-mutant resealed SOURCE DEST MARK DEPTH")
               end
               copy_child_dynamic_version_mutant(args[2], args[3], args[4].to_i, args[5].to_i)
             else
               raise ArgumentError.new("unknown W273 helper action: #{action}")
             end
    report.to_json
  end

  private def json(value : T) : JSON::Any forall T
    JSON.parse(value.to_json)
  end

  private def validate_depth(depth : Int) : Int
    unless depth == 2 || depth == 3
      raise ArgumentError.new("W273 native helper depth must be two or three")
    end
    depth
  end

  private def validate_new_destination(path : String) : String
    expanded = File.expand_path(path)
    if File.exists?(expanded) || File.symlink?(expanded)
      raise ArgumentError.new("W273 destination already exists or is symlinked")
    end
    parent = File.dirname(expanded)
    unless Dir.exists?(parent) && !File.symlink?(parent) && File.realpath(parent) == parent
      raise ArgumentError.new("W273 destination parent must already be canonical and non-symlinked")
    end
    expanded
  end

  private def validate_part(path : String) : String
    expanded = File.expand_path(path)
    unless Dir.exists?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded
      raise CrystalClick::InvalidPartError.new("W273 source part must be a canonical non-symlink directory")
    end
    expanded
  end

  private def mark_format(name : String) : CrystalClick::CompactMarkFormat
    case name
    when "mrk3" then CrystalClick::CompactMarkFormat::Mrk3
    when "mrk4" then CrystalClick::CompactMarkFormat::Mrk4
    else             raise ArgumentError.new("W273 mark format must be mrk3 or mrk4")
    end
  end

  private def discriminator_mode(name : String) : CrystalClick::CompactVariantDiscriminatorMode
    case name
    when "basic"   then CrystalClick::CompactVariantDiscriminatorMode::Basic
    when "compact" then CrystalClick::CompactVariantDiscriminatorMode::Compact
    else                raise ArgumentError.new("W273 discriminator mode must be basic or compact")
    end
  end

  private def write_native(
    destination : String,
    depth : Int,
    mark_name : String,
    mode_name : String,
  ) : JSON::Any
    validate_depth(depth)
    part = validate_new_destination(destination)
    fixture = CompactPartWriterW273NativeFixture
    fixture.common_codec_roundtrip!(depth)
    CrystalClick::CompactPartWriter.write_uint64_columns(
      part,
      CompactPartWriterW273NativeFixture::KEY_NAME,
      CompactPartWriterW273NativeFixture::KEYS,
      ([fixture.column(depth)] of CrystalClick::CompactPartColumn),
      CompactPartWriterW273NativeFixture::ROWS_PER_MARK,
      CompactPartWriterW273NativeFixture::FRAME_BYTES,
      mark_format: mark_format(mark_name),
      variant_discriminator_mode: discriminator_mode(mode_name),
    )
    literal_rows = fixture.expected_literals(depth)
    actual_counts = fixture.expected_mark_actual_counts(depth)
    leaf_counts = fixture.expected_mark_json_element_counts(depth)
    json({
      "format" => FORMAT,
      "action" => "write-native",
      "status" => "ok",
      "part_path" => part,
      "depth" => depth,
      "row_count" => CompactPartWriterW273NativeFixture::ROW_COUNT,
      "mark_count" => CompactPartWriterW273NativeFixture::MARK_COUNT,
      "rows_per_mark" => CompactPartWriterW273NativeFixture::ROWS_PER_MARK,
      "mark_format" => mark_name,
      "discriminator_mode" => mode_name,
      "discriminator_mode_id" => mode_name == "compact" ? 1 : 0,
      "column" => CompactPartWriterW273NativeFixture::COLUMN_NAME,
      "declared_schema" => fixture.declared_json_type.name,
      "dynamic_actual_type" => fixture.array_chain_type(depth).name,
      "expected_parent_dynamic_statistics" => [actual_counts.sum.to_u64, 0_u64],
      "child_json_path_types" => {"value" => "Int64"},
      "expected_child_object_statistics" => [leaf_counts.sum.to_u64],
      "expected_child_dynamic_statistics" => [leaf_counts.sum.to_u64, 0_u64],
      "expected_fixture_mark_actual_counts" => actual_counts,
      "expected_fixture_mark_array_size_vectors" => fixture.expected_mark_array_size_vectors(depth),
      "expected_fixture_mark_array_element_counts_by_level" => fixture.expected_mark_array_element_counts(depth),
      "expected_fixture_mark_json_element_counts" => leaf_counts,
      "literals" => literal_rows,
      "fixture_role" => "native-shaped inferred Int64 JSON leaves in a bounded Array-chain Dynamic actual; independent of the local UInt8 spec fixture",
    })
  end

  private def signature_payload(value : JSON::Any?, depth : Int) : JSON::Any
    return JSON::Any.new(nil) unless payload = value
    values = payload.as_a
    nested = values.map do |child|
      if depth == 1
        JSON::Any.new({CompactPartWriterW273NativeFixture::VALUE_PATH => child})
      else
        signature_payload(child, depth - 1)
      end
    end
    JSON::Any.new(nested)
  end

  private def signature(value : CrystalClick::StorageColumnValue, depth : Int) : JSON::Any
    payload = CompactPartWriterW273NativeFixture.literal_for(value, depth)
    JSON::Any.new({CompactPartWriterW273NativeFixture::PAYLOAD_PATH => signature_payload(payload, depth)})
  end

  private def reader_summary(literals : Array(JSON::Any?), depth : Int) : JSON::Any
    signatures = literals.map do |literal|
      JSON::Any.new({CompactPartWriterW273NativeFixture::PAYLOAD_PATH => signature_payload(literal, depth)})
    end
    json({"row_count" => literals.size, "literals" => literals, "signatures" => signatures})
  end

  private def mark_size_vectors(
    marks : Array(Array(CrystalClick::StorageColumnValue)),
    depth : Int,
  ) : Array(Array(Array(Int32)))
    marks.map { |rows| CompactPartWriterW273NativeFixture.array_size_vectors_for_mark(rows, depth) }
  end

  private def level_counts(vectors : Array(Array(Array(Int32))), depth : Int) : Array(Array(Int32))
    counts = Array(Array(Int32)).new(depth) { [] of Int32 }
    vectors.each do |mark_levels|
      depth.times { |level| counts[level] << mark_levels[level].sum }
    end
    counts
  end

  private def json_leaf_counts(vectors : Array(Array(Array(Int32))), depth : Int) : Array(Int32)
    vectors.map { |mark_levels| mark_levels[depth - 1].sum }
  end

  private def read_native(
    part_path : String,
    depth : Int32,
    first_mark : Int32,
    mark_count : Int32,
  ) : JSON::Any
    validate_depth(depth)
    part = validate_part(part_path)
    fixture = CompactPartWriterW273NativeFixture
    unless first_mark >= 0 && mark_count >= 0 && first_mark <= CompactPartWriterW273NativeFixture::MARK_COUNT &&
           mark_count <= CompactPartWriterW273NativeFixture::MARK_COUNT - first_mark
      raise ArgumentError.new("W273 selected mark window is outside the four-mark witness")
    end

    recursive = CrystalClick::CompactRecursiveJsonColumnReader.open(part, CompactPartWriterW273NativeFixture::COLUMN_NAME, fixture.schema)
    recursive_marks = recursive.read_marks(first_mark, mark_count)
    recursive_values = recursive_marks.map do |rows|
      rows.map { |value| fixture.literal_for(value, depth) }
    end
    static = CrystalClick::CompactStaticJsonBulkColumnReader.open(part, CompactPartWriterW273NativeFixture::COLUMN_NAME, fixture.declared_json_type)
    static_marks = static.read_marks(first_mark, mark_count)
    static_values = static_marks.map do |rows|
      rows.map do |document|
        fixture.literal_for(CrystalClick::StorageColumnValue.object_document(document), depth)
      end
    end
    unless recursive_values == static_values
      raise CrystalClick::CorruptPartError.new("W273 recursive and static Array-chain reader APIs disagree")
    end

    expected = fixture.expected_literals(depth)[first_mark * CompactPartWriterW273NativeFixture::ROWS_PER_MARK, mark_count * CompactPartWriterW273NativeFixture::ROWS_PER_MARK]
    flat = recursive_values.flatten
    unless flat == expected
      raise CrystalClick::CorruptPartError.new("W273 selected Array-chain literals differ from fixture")
    end
    recursive_vectors = mark_size_vectors(recursive_marks, depth)
    static_values_for_vectors = static_marks.map do |rows|
      rows.map { |document| CrystalClick::StorageColumnValue.object_document(document) }
    end
    static_vectors = mark_size_vectors(static_values_for_vectors, depth)
    unless recursive_vectors == static_vectors
      raise CrystalClick::CorruptPartError.new("W273 recursive and static per-parent size vectors disagree")
    end
    expected_vectors = fixture.expected_mark_array_size_vectors(depth)[first_mark, mark_count]
    unless recursive_vectors == expected_vectors
      raise CrystalClick::CorruptPartError.new("W273 selected per-parent size vectors differ from fixture")
    end
    expected_arms = fixture.expected_mark_actual_counts(depth)[first_mark, mark_count]
    unless recursive_values.map { |rows| rows.count { |value| !value.nil? } } == expected_arms &&
           static_values.map { |rows| rows.count { |value| !value.nil? } } == expected_arms
      raise CrystalClick::CorruptPartError.new("W273 selected Dynamic actual counts differ from fixture")
    end
    json_counts = json_leaf_counts(recursive_vectors, depth)
    unless level_counts(recursive_vectors, depth) == fixture.expected_mark_array_element_counts(depth).map { |counts| counts[first_mark, mark_count] } &&
           json_counts == fixture.expected_mark_json_element_counts(depth)[first_mark, mark_count]
      raise CrystalClick::CorruptPartError.new("W273 selected per-level Array counts differ from fixture")
    end
    json({
      "format" => FORMAT,
      "action" => "read-native",
      "status" => "accepted",
      "column" => CompactPartWriterW273NativeFixture::COLUMN_NAME,
      "depth" => depth,
      "first_mark" => first_mark,
      "mark_count" => mark_count,
      "row_count" => flat.size,
      "recursive" => reader_summary(flat, depth),
      "static" => reader_summary(static_values.flatten, depth),
      "recursive_arm_counts_by_mark" => recursive_values.map { |rows| rows.count { |value| !value.nil? } },
      "static_arm_counts_by_mark" => static_values.map { |rows| rows.count { |value| !value.nil? } },
      "recursive_array_size_vectors_by_mark" => recursive_vectors,
      "static_array_size_vectors_by_mark" => static_vectors,
      "recursive_array_element_counts_by_level_and_mark" => level_counts(recursive_vectors, depth),
      "static_array_element_counts_by_level_and_mark" => level_counts(static_vectors, depth),
      "recursive_json_leaf_counts_by_mark" => json_counts,
      "static_json_leaf_counts_by_mark" => json_leaf_counts(static_vectors, depth),
    })
  rescue error : CrystalClick::Error
    json({
      "format" => FORMAT,
      "action" => "read-native",
      "status" => "rejected",
      "column" => CompactPartWriterW273NativeFixture::COLUMN_NAME,
      "depth" => depth,
      "first_mark" => first_mark,
      "mark_count" => mark_count,
      "error_class" => error.class.name,
      "error_message" => error.message || "",
    })
  end

  private def read_bytes(path : String) : Bytes
    unless File.file?(path) && !File.symlink?(path)
      raise CrystalClick::CorruptPartError.new("W273 expected a regular non-symlink file")
    end
    size = File.size(path)
    if size < 0 || size > MAX_FILE_BYTES
      raise CrystalClick::CorruptPartError.new("W273 file exceeds its bounded read size")
    end
    File.read(path).to_slice.dup
  end

  private def read_u64_le(bytes : Bytes, offset : Int) : UInt64
    if offset < 0 || offset > bytes.size - 8
      raise CrystalClick::CorruptPartError.new("W273 truncated UInt64 field")
    end
    value = 0_u64
    8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
    value
  end

  private def copy_child_dynamic_version_mutant(
    source_path : String,
    destination_path : String,
    mark : Int32,
    depth : Int32,
  ) : JSON::Any
    validate_depth(depth)
    source = validate_part(source_path)
    destination = validate_new_destination(destination_path)
    if destination == source || destination.starts_with?(source + File::SEPARATOR)
      raise ArgumentError.new("W273 mutant destination must be outside its source part")
    end
    unless mark == 3
      raise ArgumentError.new("W273 child Dynamic prefix mutation is fixed to later data mark 3")
    end

    FileUtils.cp_r(source, destination)
    physical = CrystalClick::CompactPartPhysicalContext.open(destination)
    unless physical.mode.mrk4?
      raise CrystalClick::UnsupportedFormatError.new("W273 Dynamic version mutation requires MRK4")
    end
    fixture = CompactPartWriterW273NativeFixture
    payload_prefix = CrystalClick::PhysicalStreamName.append_escaped_component(
      CompactPartWriterW273NativeFixture::COLUMN_NAME,
      CompactPartWriterW273NativeFixture::PAYLOAD_PATH,
    )
    actual_prefix = CrystalClick::PhysicalStreamName.append_escaped_component(
      payload_prefix,
      fixture.array_chain_type(depth).name,
    )
    child_value_prefix = CrystalClick::PhysicalStreamName.append_escaped_component(
      actual_prefix,
      CompactPartWriterW273NativeFixture::VALUE_PATH,
    )
    expected_stream = CrystalClick::PhysicalStreamName.append_literal(child_value_prefix, ".dynamic_structure")
    window = physical.read_window(CompactPartWriterW273NativeFixture::COLUMN_NAME, mark, 1)
    candidates = window.granules.first.shards.select { |shard| shard.stream_name == expected_stream }
    unless candidates.size == 1
      raise CrystalClick::CorruptPartError.new("W273 later mark lacks one exact nested JSON child Dynamic structure stream")
    end
    shard = candidates.first
    prefix = CrystalClick::DynamicStructureCodec.decode(shard.bytes)
    unless prefix.version == CrystalClick::DynamicStructure::VERSION_V3 &&
           prefix.types.size == 1 && prefix.types.first == fixture.int64_type && prefix.statistics.nil?
      raise CrystalClick::CorruptPartError.new("W273 later child Dynamic prefix differs from the V3 Int64 roster without statistics")
    end

    data_path = File.join(destination, "data.bin")
    compressed = read_bytes(data_path)
    raw = CrystalClick::CompressedBlock.decode_all(compressed, max_output_size: MAX_RAW_BYTES)
    offset = shard.logical_start.to_i
    if offset < 0 || shard.bytes.size > raw.size || offset > raw.size - shard.bytes.size || raw[offset, shard.bytes.size] != shard.bytes
      raise CrystalClick::CorruptPartError.new("W273 Dynamic prefix offset differs from authenticated mark shard")
    end
    original = Bytes.new(raw.size) { |index| raw[index] }
    raw[offset] = 5_u8
    unless read_u64_le(raw, offset) == 5_u64
      raise CrystalClick::CorruptPartError.new("W273 mutation did not set the Dynamic version to UInt64 5")
    end
    rebuilt, frame_count = rebuild_equal_sized_frames(compressed, raw)
    replacement = CrystalClick::CompressedBlock.decode_all(rebuilt, max_output_size: MAX_RAW_BYTES)
    changed = [] of Int32
    original.each_with_index { |byte, index| changed << index.to_i32 if replacement[index] != byte }
    unless changed == [offset.to_i32] && rebuilt.size == compressed.size
      raise CrystalClick::CorruptPartError.new("W273 mutation changed bytes outside one version byte or moved frame coordinates")
    end
    File.write(data_path, rebuilt)
    reseal_checksums!(destination)
    json({
      "format" => FORMAT,
      "action" => "copy-child-dynamic-version-mutant",
      "status" => "ok",
      "mode" => "resealed",
      "source_path" => source,
      "mutant_path" => destination,
      "column" => CompactPartWriterW273NativeFixture::COLUMN_NAME,
      "stream" => expected_stream,
      "mark" => mark,
      "depth" => depth,
      "semantic_type" => "Dynamic(Int64)",
      "version_before" => CrystalClick::DynamicStructure::VERSION_V3,
      "version_after" => 5_u64,
      "logical_offset" => offset,
      "raw_changed_offsets" => changed,
      "compressed_size_before" => compressed.size,
      "compressed_size_after" => rebuilt.size,
      "raw_size" => raw.size,
      "frame_count" => frame_count,
      "checksums_resealed" => true,
    })
  end

  private def rebuild_equal_sized_frames(compressed : Bytes, raw : Bytes) : Tuple(Bytes, Int32)
    rebuilt = IO::Memory.new(compressed.size)
    compressed_offset = 0_i64
    logical_start = 0_i64
    frame_count = 0_i32
    while compressed_offset < compressed.size.to_i64
      if frame_count >= MAX_FRAME_COUNT
        raise CrystalClick::CorruptPartError.new("W273 LZ4 frame count exceeds its audit bound")
      end
      frame = CrystalClick::CompressedBlock.decode_frame(compressed, compressed_offset)
      frame_bytes = CrystalClick::PartWriterInfrastructure::StreamEncoding.encode_lz4_frame(
        raw[logical_start.to_i, frame.output.size],
      )
      unless frame_bytes.size.to_i64 == frame.end_offset - compressed_offset
        raise CrystalClick::CorruptPartError.new("W273 resealed LZ4 frame size differs and would move mark coordinates")
      end
      rebuilt.write(frame_bytes)
      logical_start += frame.output.size
      compressed_offset = frame.end_offset
      frame_count += 1
    end
    unless logical_start == raw.size && rebuilt.size == compressed.size
      raise CrystalClick::CorruptPartError.new("W273 resealed frames do not cover the complete data stream")
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
          raise CrystalClick::CorruptPartError.new("W273 resealed compressed-stream raw size differs")
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

puts CompactPartWriterW273Helper.run(ARGV)
