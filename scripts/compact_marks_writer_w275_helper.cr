require "../src/crystal_click"
require "../spec/support/compact_part_writer_w264_fixture"
require "./support/compact_part_writer_w273_native_fixture"
require "digest/sha256"
require "json"

module CompactMarksWriterW275Helper
  extend self

  FORMAT        = "compact_marks_writer_w275_helper_v1"
  MAX_RAW_BYTES = 64_i64 * 1024 * 1024

  def run(args : Array(String)) : String
    action = args[0]? || raise ArgumentError.new("expected write-static, write-json, marks, or read-json")
    report = case action
             when "write-static"
               unless args.size == 4
                 raise ArgumentError.new("usage: helper write-static DEST mrk3|mrk4 compressed=0|1")
               end
               write_static(args[1], args[2], parse_bool(args[3]))
             when "write-json"
               unless args.size == 6
                 raise ArgumentError.new("usage: helper write-json DEST DEPTH mrk3|mrk4 basic|compact compressed=0|1")
               end
               write_json(args[1], args[2].to_i, args[3], args[4], parse_bool(args[5]))
             when "marks"
               unless args.size == 2
                 raise ArgumentError.new("usage: helper marks PART")
               end
               read_marks(args[1])
             when "read-json"
               unless args.size == 5
                 raise ArgumentError.new("usage: helper read-json PART DEPTH FIRST_MARK MARK_COUNT")
               end
               read_json(args[1], args[2].to_i, args[3].to_i, args[4].to_i)
             else
               raise ArgumentError.new("unknown W275 helper action: #{action}")
             end
    report.to_json
  end

  private def parse_bool(value : String) : Bool
    case value
    when "0" then false
    when "1" then true
    else          raise ArgumentError.new("compressed must be exactly 0 or 1")
    end
  end

  private def format(name : String) : CrystalClick::CompactMarkFormat
    case name
    when "mrk3" then CrystalClick::CompactMarkFormat::Mrk3
    when "mrk4" then CrystalClick::CompactMarkFormat::Mrk4
    else             raise ArgumentError.new("mark format must be mrk3 or mrk4")
    end
  end

  private def mode(name : String) : CrystalClick::CompactVariantDiscriminatorMode
    case name
    when "basic"   then CrystalClick::CompactVariantDiscriminatorMode::Basic
    when "compact" then CrystalClick::CompactVariantDiscriminatorMode::Compact
    else                raise ArgumentError.new("discriminator mode must be basic or compact")
    end
  end

  private def validate_new_part(path : String) : String
    expanded = File.expand_path(path)
    if File.exists?(expanded) || File.symlink?(expanded)
      raise ArgumentError.new("W275 destination already exists or is symlinked")
    end
    parent = File.dirname(expanded)
    unless Dir.exists?(parent) && !File.symlink?(parent) && File.realpath(parent) == parent
      raise ArgumentError.new("W275 destination parent must already be canonical and non-symlinked")
    end
    expanded
  end

  private def validate_part(path : String) : String
    expanded = File.expand_path(path)
    unless Dir.exists?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded
      raise CrystalClick::InvalidPartError.new("W275 part must be a canonical non-symlink directory")
    end
    expanded
  end

  private def write_static(destination : String, mark_name : String, compressed : Bool) : JSON::Any
    mark = format(mark_name)
    part = validate_new_part(destination)
    CrystalClick::CompactPartWriter.write_uint64_columns(
      part,
      CompactPartWriterW264Fixture::KEY_NAME,
      CompactPartWriterW264Fixture.keys,
      CompactPartWriterW264Fixture.columns,
      rows_per_mark: CompactPartWriterW264Fixture::ROWS_PER_MARK,
      frame_bytes: CompactPartWriterW264Fixture::FRAME_BYTES,
      mark_format: mark,
      compress_marks: compressed,
    )
    json({
      "format"           => FORMAT,
      "action"           => "write-static",
      "status"           => "ok",
      "part_path"        => part,
      "layout"           => mark_name,
      "compressed_marks" => compressed,
      "key_count"        => CompactPartWriterW264Fixture::ROW_COUNT,
      "rows_per_mark"    => CompactPartWriterW264Fixture::ROWS_PER_MARK,
      "schema"           => CompactPartWriterW264Fixture::COLUMN_NAMES.map do |name|
        {"name" => name, "type" => CompactPartWriterW264Fixture.types[name].name}
      end,
      "fixture_role" => "W264 bounded static scalar, Nullable, Array, Tuple, and Map witness",
    })
  end

  private def write_json(
    destination : String,
    depth : Int32,
    mark_name : String,
    mode_name : String,
    compressed : Bool,
  ) : JSON::Any
    unless depth == 2
      raise ArgumentError.new("W275 generated JSON witness is exactly Array^2(JSON)")
    end
    mark = format(mark_name)
    discriminator = mode(mode_name)
    part = validate_new_part(destination)
    CompactPartWriterW273NativeFixture.common_codec_roundtrip!(depth)
    CrystalClick::CompactPartWriter.write_uint64_columns(
      part,
      CompactPartWriterW273NativeFixture::KEY_NAME,
      CompactPartWriterW273NativeFixture::KEYS,
      ([CompactPartWriterW273NativeFixture.column(depth)] of CrystalClick::CompactPartColumn),
      CompactPartWriterW273NativeFixture::ROWS_PER_MARK,
      CompactPartWriterW273NativeFixture::FRAME_BYTES,
      mark_format: mark,
      variant_discriminator_mode: discriminator,
      compress_marks: compressed,
    )
    json({
      "format"                                   => FORMAT,
      "action"                                   => "write-json",
      "status"                                   => "ok",
      "part_path"                                => part,
      "depth"                                    => depth,
      "layout"                                   => mark_name,
      "discriminator_mode"                       => mode_name,
      "compressed_marks"                         => compressed,
      "dynamic_actual_type"                      => CompactPartWriterW273NativeFixture.array_chain_type(depth).name,
      "declared_schema"                          => CompactPartWriterW273NativeFixture.declared_json_type.name,
      "child_json_path_types"                    => {"value" => "Int64"},
      "expected_mark_rows"                       => [2, 2, 2, 2, 0],
      "expected_fixture_mark_actual_counts"      => CompactPartWriterW273NativeFixture.expected_mark_actual_counts(depth),
      "expected_fixture_mark_array_size_vectors" => CompactPartWriterW273NativeFixture.expected_mark_array_size_vectors(depth),
      "literals"                                 => CompactPartWriterW273NativeFixture.expected_literals(depth),
      "fixture_role"                             => "native-shaped inferred Int64 leaves for typed Dynamic Array^2(JSON), including NULL, [], and [[]]",
    })
  end

  private def budget : CrystalClick::CompressedStreamBudget
    limits = CrystalClick::CompressedStreamLimits.new(
      max_file_bytes: MAX_RAW_BYTES.to_i,
      max_mark_bytes: MAX_RAW_BYTES.to_i,
      max_frame_compressed_bytes: MAX_RAW_BYTES.to_i,
      max_frame_decompressed_bytes: MAX_RAW_BYTES.to_i,
      max_records: 100_000,
      max_decoded_bytes: MAX_RAW_BYTES.to_i,
      max_result_bytes: MAX_RAW_BYTES.to_i,
    )
    CrystalClick::CompressedStreamBudget.new(limits)
  end

  private def read_marks(part_path : String) : JSON::Any
    part = validate_part(part_path)
    checksums = CrystalClick::PartChecksums.open(part)
    context = CrystalClick::CompactPartPhysicalContext.open(part, budget)
    name = context.marks_name
    entry = checksums.entry(name) || raise CrystalClick::CorruptPartError.new("W275 mark checksum entry is absent")
    path = File.join(part, name)
    unless File.file?(path) && !File.symlink?(path) && File.size(path).to_u64 == entry.physical_size
      raise CrystalClick::CorruptPartError.new("W275 physical mark file differs from its checksum size")
    end
    canonical = if entry.compressed
                  raw_size = entry.uncompressed_size || raise CrystalClick::CorruptPartError.new("W275 compressed marks lack raw size")
                  raw_hash = entry.uncompressed_hash || raise CrystalClick::CorruptPartError.new("W275 compressed marks lack raw hash")
                  decoded = CrystalClick::CompressedMarkReader.read_all(
                    path,
                    entry.physical_size.to_i64,
                    budget,
                    raw_size.to_i64,
                    entry.file_hash,
                  )
                  unless decoded.size.to_u64 == raw_size && CrystalClick::CityHashV1.file_hash(decoded) == raw_hash
                    raise CrystalClick::CorruptPartError.new("W275 decoded marks differ from saved checksum metadata")
                  end
                  decoded
                else
                  if entry.uncompressed_size || entry.uncompressed_hash
                    raise CrystalClick::CorruptPartError.new("W275 plain marks declare compressed checksum metadata")
                  end
                  bytes = File.read(path).to_slice.dup
                  unless CrystalClick::CityHashV1.file_hash(bytes) == entry.file_hash
                    raise CrystalClick::CorruptPartError.new("W275 plain marks differ from saved checksum metadata")
                  end
                  bytes
                end
    rows = context.mark_row_counts
    rows << 0_u64
    json({
      "format"                      => FORMAT,
      "action"                      => "marks",
      "status"                      => "ok",
      "marks_file"                  => name,
      "layout"                      => name.ends_with?("mrk3") ? "mrk3" : "mrk4",
      "compressed"                  => entry.compressed,
      "physical_size"               => entry.physical_size,
      "physical_sha256"             => Digest::SHA256.hexdigest(File.read(path)),
      "physical_cityhash_words"     => [entry.file_hash[0].to_s, entry.file_hash[1].to_s],
      "uncompressed_size"           => entry.uncompressed_size,
      "uncompressed_cityhash_words" => entry.uncompressed_hash.try { |hash| [hash[0].to_s, hash[1].to_s] },
      "canonical_size"              => canonical.size,
      "canonical_sha256"            => Digest::SHA256.hexdigest(canonical),
      "canonical_marks_hex"         => canonical.hexstring.downcase,
      "mark_rows_with_terminal"     => rows,
      "integrity"                   => "compressed frames and physical/uncompressed ClickHouse CityHash metadata verified; schema-neutral Compact grid opened",
    })
  end

  private def read_json(part_path : String, depth : Int32, first_mark : Int32, mark_count : Int32) : JSON::Any
    unless depth == 2 && first_mark >= 0 && mark_count >= 0 && first_mark <= 4 && mark_count <= 4 - first_mark
      raise ArgumentError.new("W275 JSON window is outside the four-mark depth-two witness")
    end
    part = validate_part(part_path)
    recursive = CrystalClick::CompactRecursiveJsonColumnReader.open(
      part,
      CompactPartWriterW273NativeFixture::COLUMN_NAME,
      CompactPartWriterW273NativeFixture.schema,
    )
    recursive_marks = recursive.read_marks(first_mark, mark_count)
    recursive_values = recursive_marks.map do |rows|
      rows.map { |value| CompactPartWriterW273NativeFixture.literal_for(value, depth) }
    end
    static = CrystalClick::CompactStaticJsonBulkColumnReader.open(
      part,
      CompactPartWriterW273NativeFixture::COLUMN_NAME,
      CompactPartWriterW273NativeFixture.declared_json_type,
    )
    static_marks = static.read_marks(first_mark, mark_count)
    static_values = static_marks.map do |rows|
      rows.map do |document|
        CompactPartWriterW273NativeFixture.literal_for(
          CrystalClick::StorageColumnValue.object_document(document),
          depth,
        )
      end
    end
    expected = CompactPartWriterW273NativeFixture.expected_literals(depth)[
      first_mark * CompactPartWriterW273NativeFixture::ROWS_PER_MARK,
      mark_count * CompactPartWriterW273NativeFixture::ROWS_PER_MARK,
    ]
    unless recursive_values == static_values && recursive_values.flatten == expected
      raise CrystalClick::CorruptPartError.new("W275 recursive/static JSON window differs from independent fixture literals")
    end
    json({
      "format"                     => FORMAT,
      "action"                     => "read-json",
      "status"                     => "accepted",
      "depth"                      => depth,
      "first_mark"                 => first_mark,
      "mark_count"                 => mark_count,
      "row_count"                  => expected.size,
      "recursive_literals_by_mark" => recursive_values,
      "static_literals_by_mark"    => static_values,
      "literals"                   => expected,
      "reader_agreement"           => true,
    })
  end

  private def json(value : T) : JSON::Any forall T
    JSON.parse(value.to_json)
  end
end

puts CompactMarksWriterW275Helper.run(ARGV)
