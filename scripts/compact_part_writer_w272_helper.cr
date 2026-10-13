require "../src/crystal_click"
require "./support/compact_part_writer_w272_native_fixture"
require "file_utils"
require "json"

module CompactPartWriterW272Helper
  extend self

  FORMAT = "compact_part_writer_w272_helper_v1"
  MAX_RAW_BYTES   = 64_i64 * 1024 * 1024
  MAX_FILE_BYTES  = MAX_RAW_BYTES + 1024_i64 * 1024
  MAX_FRAME_COUNT = 100_000

  def run(args : Array(String)) : String
    action = args[0]? || raise ArgumentError.new("expected write-native, read-native, or copy-child-dynamic-version-mutant")
    report = case action
             when "write-native"
               unless args.size == 4
                 raise ArgumentError.new("usage: helper write-native DEST mrk3|mrk4 basic|compact")
               end
               write_native(args[1], args[2], args[3])
             when "read-native"
               unless args.size == 4
                 raise ArgumentError.new("usage: helper read-native PART FIRST_MARK MARK_COUNT")
               end
               read_native(args[1], args[2].to_i, args[3].to_i)
             when "copy-child-dynamic-version-mutant"
               unless args.size == 5 && args[1] == "resealed"
                 raise ArgumentError.new("usage: helper copy-child-dynamic-version-mutant resealed SOURCE DEST MARK")
               end
               copy_child_dynamic_version_mutant(args[2], args[3], args[4].to_i)
             else
               raise ArgumentError.new("unknown W272 helper action: #{action}")
             end
    report.to_json
  end

  private def json(value : T) : JSON::Any forall T
    JSON.parse(value.to_json)
  end

  private def validate_new_destination(path : String) : String
    expanded = File.expand_path(path)
    if File.exists?(expanded) || File.symlink?(expanded)
      raise ArgumentError.new("W272 destination already exists or is symlinked")
    end
    parent = File.dirname(expanded)
    unless Dir.exists?(parent) && !File.symlink?(parent) && File.realpath(parent) == parent
      raise ArgumentError.new("W272 destination parent must already be canonical and non-symlinked")
    end
    expanded
  end

  private def validate_part(path : String) : String
    expanded = File.expand_path(path)
    unless Dir.exists?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded
      raise CrystalClick::InvalidPartError.new("W272 source part must be a canonical non-symlink directory")
    end
    expanded
  end

  private def mark_format(name : String) : CrystalClick::CompactMarkFormat
    case name
    when "mrk3" then CrystalClick::CompactMarkFormat::Mrk3
    when "mrk4" then CrystalClick::CompactMarkFormat::Mrk4
    else             raise ArgumentError.new("W272 mark format must be mrk3 or mrk4")
    end
  end

  private def discriminator_mode(name : String) : CrystalClick::CompactVariantDiscriminatorMode
    case name
    when "basic"   then CrystalClick::CompactVariantDiscriminatorMode::Basic
    when "compact" then CrystalClick::CompactVariantDiscriminatorMode::Compact
    else                raise ArgumentError.new("W272 discriminator mode must be basic or compact")
    end
  end

  private def write_native(destination : String, mark_name : String, mode_name : String) : JSON::Any
    part = validate_new_destination(destination)
    CompactPartWriterW272NativeFixture.common_codec_roundtrip!
    CrystalClick::CompactPartWriter.write_uint64_columns(
      part,
      CompactPartWriterW272NativeFixture::KEY_NAME,
      CompactPartWriterW272NativeFixture::KEYS,
      ([CompactPartWriterW272NativeFixture.column] of CrystalClick::CompactPartColumn),
      CompactPartWriterW272NativeFixture::ROWS_PER_MARK,
      CompactPartWriterW272NativeFixture::FRAME_BYTES,
      mark_format: mark_format(mark_name),
      variant_discriminator_mode: discriminator_mode(mode_name),
    )
    json({
      "format" => FORMAT,
      "action" => "write-native",
      "status" => "ok",
      "part_path" => part,
      "row_count" => CompactPartWriterW272NativeFixture::ROW_COUNT,
      "mark_count" => CompactPartWriterW272NativeFixture::MARK_COUNT,
      "rows_per_mark" => CompactPartWriterW272NativeFixture::ROWS_PER_MARK,
      "mark_format" => mark_name,
      "discriminator_mode" => mode_name,
      "discriminator_mode_id" => mode_name == "compact" ? 1 : 0,
      "column" => CompactPartWriterW272NativeFixture::COLUMN_NAME,
      "declared_schema" => CompactPartWriterW272NativeFixture.declared_json_type.name,
      "dynamic_actual_type" => CompactPartWriterW272NativeFixture.array_json_type.name,
      "expected_parent_dynamic_statistics" => [4_u64, 0_u64],
      "child_json_path_types" => {"value" => "Int64"},
      "expected_child_object_statistics" => [6_u64],
      "expected_child_dynamic_statistics" => [6_u64, 0_u64],
      "expected_fixture_mark_arm_counts" => CompactPartWriterW272NativeFixture.expected_mark_arm_counts,
      "expected_fixture_child_element_counts" => CompactPartWriterW272NativeFixture.expected_mark_json_element_counts,
      "literals" => CompactPartWriterW272NativeFixture.expected_literals,
      "fixture_role" => "native-shaped inferred Int64 JSON elements in an ordinary Array(JSON) Dynamic actual",
    })
  end

  private def read_bytes(path : String) : Bytes
    unless File.file?(path) && !File.symlink?(path)
      raise CrystalClick::CorruptPartError.new("W272 expected a regular non-symlink file")
    end
    size = File.size(path)
    if size < 0 || size > MAX_FILE_BYTES
      raise CrystalClick::CorruptPartError.new("W272 file exceeds its bounded read size")
    end
    File.read(path).to_slice.dup
  end

  private def read_u64_le(bytes : Bytes, offset : Int) : UInt64
    if offset < 0 || offset > bytes.size - 8
      raise CrystalClick::CorruptPartError.new("W272 truncated UInt64 field")
    end
    value = 0_u64
    8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
    value
  end

  private def copy_child_dynamic_version_mutant(
    source_path : String,
    destination_path : String,
    mark : Int32,
  ) : JSON::Any
    source = validate_part(source_path)
    destination = validate_new_destination(destination_path)
    if destination == source || destination.starts_with?(source + File::SEPARATOR)
      raise ArgumentError.new("W272 mutant destination must be outside its source part")
    end
    unless mark == 2
      raise ArgumentError.new("W272 child Dynamic version mutation is fixed to data mark 2")
    end

    FileUtils.cp_r(source, destination)
    physical = CrystalClick::CompactPartPhysicalContext.open(destination)
    unless physical.mode.mrk4?
      raise CrystalClick::UnsupportedFormatError.new("W272 child Dynamic mutation requires MRK4")
    end

    column = CompactPartWriterW272NativeFixture::COLUMN_NAME
    payload_prefix = CrystalClick::PhysicalStreamName.append_escaped_component(column, "payload")
    array_prefix = CrystalClick::PhysicalStreamName.append_escaped_component(payload_prefix, "Array(JSON)")
    value_prefix = CrystalClick::PhysicalStreamName.append_escaped_component(array_prefix, "value")
    expected_stream = CrystalClick::PhysicalStreamName.append_literal(value_prefix, ".dynamic_structure")
    window = physical.read_window(column, mark, 1)
    candidates = window.granules.first.shards.select { |shard| shard.stream_name == expected_stream }
    unless candidates.size == 1
      raise CrystalClick::CorruptPartError.new("W272 mark 2 lacks one exact Array(JSON) child value Dynamic structure stream")
    end
    shard = candidates.first
    prefix = CrystalClick::DynamicStructureCodec.decode(shard.bytes)
    unless prefix.version == 4_u64 && prefix.types.size == 1 && prefix.types.first.name == "Int64" && prefix.statistics.nil?
      raise CrystalClick::CorruptPartError.new("W272 mark 2 child Dynamic prefix is not v4 inferred Int64 with later-mark statistics absent")
    end

    data_path = File.join(destination, "data.bin")
    compressed = read_bytes(data_path)
    raw = CrystalClick::CompressedBlock.decode_all(compressed, max_output_size: MAX_RAW_BYTES)
    offset = shard.logical_start.to_i
    if offset < 0 || shard.bytes.size > raw.size || offset > raw.size - shard.bytes.size ||
       raw[offset, shard.bytes.size] != shard.bytes
      raise CrystalClick::CorruptPartError.new("W272 child Dynamic offset differs from authenticated mark shard")
    end
    original = Bytes.new(raw.size) { |index| raw[index] }
    raw[offset] = 5_u8
    unless read_u64_le(raw, offset) == 5_u64
      raise CrystalClick::CorruptPartError.new("W272 mutation did not set the child Dynamic version to UInt64 5")
    end
    rebuilt, frame_count = rebuild_equal_sized_frames(compressed, raw)
    replacement = CrystalClick::CompressedBlock.decode_all(rebuilt, max_output_size: MAX_RAW_BYTES)
    changed = [] of Int32
    original.each_with_index { |byte, index| changed << index.to_i32 if replacement[index] != byte }
    unless changed == [offset.to_i32] && rebuilt.size == compressed.size
      raise CrystalClick::CorruptPartError.new("W272 mutation changed bytes outside one version byte or moved frame coordinates")
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
      "column" => column,
      "stream" => expected_stream,
      "mark" => mark,
      "semantic_type" => "Dynamic(Int64)",
      "version_before" => 4_u64,
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
        raise CrystalClick::CorruptPartError.new("W272 LZ4 frame count exceeds its audit bound")
      end
      frame = CrystalClick::CompressedBlock.decode_frame(compressed, compressed_offset)
      frame_bytes = CrystalClick::PartWriterInfrastructure::StreamEncoding.encode_lz4_frame(
        raw[logical_start.to_i, frame.output.size],
      )
      unless frame_bytes.size.to_i64 == frame.end_offset - compressed_offset
        raise CrystalClick::CorruptPartError.new("W272 resealed LZ4 frame size differs and would move mark coordinates")
      end
      rebuilt.write(frame_bytes)
      logical_start += frame.output.size
      compressed_offset = frame.end_offset
      frame_count += 1
    end
    unless logical_start == raw.size && rebuilt.size == compressed.size
      raise CrystalClick::CorruptPartError.new("W272 resealed frames do not cover the complete data stream")
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
          raise CrystalClick::CorruptPartError.new("W272 resealed compressed-stream raw size differs")
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

  private def signature(value : CrystalClick::StorageColumnValue) : JSON::Any
    unless value.object?
      raise CrystalClick::CorruptPartError.new("W272 reader returned a non-Object row")
    end
    payload = CompactPartWriterW272NativeFixture.literal_for(value)
    encoded_payload = if values = payload
                        JSON::Any.new(values.map do |number|
                          JSON::Any.new({CompactPartWriterW272NativeFixture::VALUE_PATH => JSON::Any.new(number)})
                        end)
                      else
                        JSON::Any.new(nil)
                      end
    JSON::Any.new({CompactPartWriterW272NativeFixture::PAYLOAD_PATH => encoded_payload})
  end

  private def reader_summary(literals : Array(Array(Int64)?)) : JSON::Any
    signatures = literals.map do |values|
      encoded_payload = if array = values
                          JSON::Any.new(array.map do |number|
                            JSON::Any.new({CompactPartWriterW272NativeFixture::VALUE_PATH => JSON::Any.new(number)})
                          end)
                        else
                          JSON::Any.new(nil)
                        end
      JSON::Any.new({CompactPartWriterW272NativeFixture::PAYLOAD_PATH => encoded_payload})
    end
    json({
      "row_count" => literals.size,
      "literals" => literals,
      "signatures" => signatures,
    })
  end

  private def read_native(part_path : String, first_mark : Int32, mark_count : Int32) : JSON::Any
    part = validate_part(part_path)
    fixture = CompactPartWriterW272NativeFixture
    unless first_mark >= 0 && mark_count >= 0 && first_mark <= CompactPartWriterW272NativeFixture::MARK_COUNT &&
           mark_count <= CompactPartWriterW272NativeFixture::MARK_COUNT - first_mark
      raise ArgumentError.new("W272 selected mark window is outside the four-mark witness")
    end

    recursive = CrystalClick::CompactRecursiveJsonColumnReader.open(part, CompactPartWriterW272NativeFixture::COLUMN_NAME, fixture.schema)
    recursive_marks = recursive.read_marks(first_mark, mark_count)
    recursive_literals = recursive_marks.map do |mark_rows|
      mark_rows.map { |value| fixture.literal_for(value) }
    end

    static = CrystalClick::CompactStaticJsonBulkColumnReader.open(part, CompactPartWriterW272NativeFixture::COLUMN_NAME, fixture.declared_json_type)
    static_marks = static.read_marks(first_mark, mark_count)
    static_literals = static_marks.map do |mark_rows|
      mark_rows.map do |document|
        fixture.literal_for(CrystalClick::StorageColumnValue.object_document(document))
      end
    end

    if recursive_literals != static_literals
      raise CrystalClick::CorruptPartError.new("W272 recursive and static JSON read APIs disagree")
    end
    json({
      "format" => FORMAT,
      "action" => "read-native",
      "status" => "accepted",
      "column" => CompactPartWriterW272NativeFixture::COLUMN_NAME,
      "first_mark" => first_mark,
      "mark_count" => mark_count,
      "row_count" => recursive_literals.sum(&.size),
      "recursive" => reader_summary(recursive_literals.flat_map { |mark_rows| mark_rows }),
      "static" => reader_summary(static_literals.flat_map { |mark_rows| mark_rows }),
      "recursive_arm_counts_by_mark" => recursive_literals.map { |rows| rows.count { |value| !value.nil? } },
      "recursive_child_element_counts_by_mark" => recursive_literals.map { |rows| rows.sum { |value| value.try(&.size) || 0 } },
      "static_arm_counts_by_mark" => static_literals.map { |rows| rows.count { |value| !value.nil? } },
      "static_child_element_counts_by_mark" => static_literals.map { |rows| rows.sum { |value| value.try(&.size) || 0 } },
    })
  rescue error : CrystalClick::Error
    json({
      "format" => FORMAT,
      "action" => "read-native",
      "status" => "rejected",
      "column" => CompactPartWriterW272NativeFixture::COLUMN_NAME,
      "first_mark" => first_mark,
      "mark_count" => mark_count,
      "error_class" => error.class.name,
      "error_message" => error.message || "",
    })
  end
end

puts CompactPartWriterW272Helper.run(ARGV)
