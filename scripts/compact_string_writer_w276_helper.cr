require "../src/crystal_click"
require "../spec/support/compact_part_writer_w276_fixture"
require "digest/sha256"
require "json"

module CompactPartWriterW276Helper
  extend self

  FORMAT         = "compact_string_writer_w276_helper_v1"
  MAX_FILES      = 160
  MAX_PART_BYTES = 64_i64 * 1024_i64 * 1024_i64

  def run(args : Array(String)) : String
    action = args[0]? || raise ArgumentError.new("expected write, read, or audit")
    report = case action
             when "write"
               unless args.size == 5
                 raise ArgumentError.new("usage: helper write DEST mrk3|mrk4 compressed0|1 profile0|1")
               end
               write_part(args[1], args[2], args[3], args[4])
             when "read"
               unless args.size == 4
                 raise ArgumentError.new("usage: helper read PART FIRST_MARK MARK_COUNT")
               end
               selected_report(validate_part(args[1]), "read", args[2].to_i32, args[3].to_i32)
             when "audit"
               unless args.size == 2
                 raise ArgumentError.new("usage: helper audit PART")
               end
               selected_report(validate_part(args[1]), "audit", 0, CompactPartWriterW276Fixture::ROW_COUNT // CompactPartWriterW276Fixture::ROWS_PER_MARK)
             else
               raise ArgumentError.new("unknown W276 helper action: #{action}")
             end
    report.to_json
  end

  private def write_part(destination : String, mark_name : String, compressed_name : String, profile_name : String) : JSON::Any
    mark = case mark_name
           when "mrk3" then CrystalClick::CompactMarkFormat::Mrk3
           when "mrk4" then CrystalClick::CompactMarkFormat::Mrk4
           else             raise ArgumentError.new("W276 mark format must be mrk3 or mrk4")
           end
    compressed = case compressed_name
                 when "compressed0" then false
                 when "compressed1" then true
                 else                    raise ArgumentError.new("W276 compression option must be compressed0 or compressed1")
                 end
    profile = case profile_name
              when "profile0" then CrystalClick::BinaryBulkProfile.single_stream
              when "profile1" then CrystalClick::BinaryBulkProfile.with_size_stream
              else                 raise ArgumentError.new("W276 profile option must be profile0 or profile1")
              end
    part = validate_new_destination(destination)
    CrystalClick::CompactPartWriter.write_uint64_columns(
      part,
      CompactPartWriterW276Fixture::KEY_NAME,
      CompactPartWriterW276Fixture.keys,
      CompactPartWriterW276Fixture.columns,
      rows_per_mark: CompactPartWriterW276Fixture::ROWS_PER_MARK,
      frame_bytes: CompactPartWriterW276Fixture::FRAME_BYTES,
      mark_format: mark,
      compress_marks: compressed,
      profile: profile,
    )
    selected_report(part, "write", 0, CompactPartWriterW276Fixture::ROW_COUNT // CompactPartWriterW276Fixture::ROWS_PER_MARK,
      requested_mark_format: mark_name, requested_compress_marks: compressed, requested_profile: profile_name)
  end

  private def selected_report(
    part : String,
    action : String,
    first_mark : Int32,
    mark_count : Int32,
    requested_mark_format : String? = nil,
    requested_compress_marks : Bool? = nil,
    requested_profile : String? = nil,
  ) : JSON::Any
    mark_total = CompactPartWriterW276Fixture::ROW_COUNT // CompactPartWriterW276Fixture::ROWS_PER_MARK
    unless first_mark >= 0 && mark_count >= 0 && first_mark <= mark_total && mark_count <= mark_total - first_mark
      raise ArgumentError.new("W276 selected mark window is outside the four data marks")
    end

    physical = CrystalClick::CompactPartPhysicalContext.open(part)
    mode = physical.mode.mrk3? ? "mrk3" : (physical.mode.mrk4? ? "mrk4" : "unsupported")
    unless mode == "mrk3" || mode == "mrk4"
      raise CrystalClick::UnsupportedFormatError.new("W276 part has an unsupported Compact mark format")
    end
    if requested_mark_format && requested_mark_format != mode
      raise CrystalClick::CorruptPartError.new("W276 written mark format differs from request")
    end
    unless physical.row_count == CompactPartWriterW276Fixture::ROW_COUNT.to_u64 &&
           physical.mark_row_counts == Array(UInt64).new(mark_total, CompactPartWriterW276Fixture::ROWS_PER_MARK.to_u64)
      raise CrystalClick::CorruptPartError.new("W276 physical part rows or data-mark grid differs from fixture")
    end
    schema = CompactPartWriterW276Fixture.types
    columns = Array(NamedTuple(name: String, type: String, profile: String, marks: Array(UInt64),
      signatures: Array(String), physical_stream_names: Array(String), selected_checksum_names: Array(String))).new
    CompactPartWriterW276Fixture::COLUMN_NAMES.each do |name|
      type = schema[name]
      reader = CrystalClick::CompactBinaryBulkColumnReader.open(part, name, type)
      marks = reader.read_marks(first_mark, mark_count)
      signatures = marks.flatten.map { |value| CompactPartWriterW264Fixture.row_signature(value) }
      columns << {
        name:                    name,
        type:                    reader.schema_declaration,
        profile:                 reader.ordinary_profile.with_size_stream? ? "with_size_stream" : "single_stream",
        marks:                   reader.mark_row_counts,
        signatures:              signatures,
        physical_stream_names:   reader.physical_stream_names,
        selected_checksum_names: reader.selected_checksum_names,
      }
    end
    key_reader = CrystalClick::CompactBinaryBulkColumnReader.open(
      part,
      CompactPartWriterW276Fixture::KEY_NAME,
      CrystalClick::BinaryDataType.primitive("UInt64"),
    )
    key_marks = key_reader.read_marks(first_mark, mark_count)
    keys = key_marks.flatten.map(&.as_uint64)

    serialization_text = read_bounded_file(part, "serialization.json", 4_i64 * 1024_i64 * 1024_i64)
    metadata = JSON.parse(serialization_text).as_h
    version = metadata["version"]?.try(&.as_i) || raise CrystalClick::CorruptPartError.new("W276 serialization version is absent")
    propagated = metadata["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) || false
    versions = metadata["types_serialization_versions"]?.try(&.as_h) || raise CrystalClick::CorruptPartError.new("W276 serialization versions are absent")
    string_version = versions["string"]?.try(&.as_i) || raise CrystalClick::CorruptPartError.new("W276 String serialization version is absent")
    expected_string_version = case requested_profile
                              when "profile0" then 0
                              when "profile1" then 1
                              else                 nil
                              end
    unless version == 1 && (string_version == 0 || string_version == 1) &&
           (expected_string_version.nil? || string_version == expected_string_version) && propagated
      raise CrystalClick::UnsupportedFormatError.new("W276 part is not the requested propagated String profile")
    end

    files = inventory(part)
    checksums = CrystalClick::PartChecksums.open(part)
    checksum_entries = checksums.entries.keys.sort.map do |name|
      entry = checksums.entry(name).not_nil!
      {
        "name"              => name,
        "physical_size"     => entry.physical_size,
        "compressed"        => entry.compressed,
        "uncompressed_size" => entry.uncompressed_size,
      }
    end
    roster = physical.physical_roster.map do |slot|
      {"index" => slot.index, "column" => slot.column_name, "stream" => slot.stream_name}
    end
    if mode == "mrk4" && string_version == 1
      expected_mrk4_string1_callbacks = {
        "pair"         => ["pair%2E1.size", "pair%2E1", "pair%2E2.null", "pair%2E2"],
        "string_array" => ["string_array%2Eitems.size0", "string_array%2Eitems.null",
                           "string_array%2Eitems.size", "string_array%2Eitems"],
      }
      expected_mrk4_string1_callbacks.each do |column_name, expected_streams|
        observed_streams = roster.select { |slot| slot["column"] == column_name }.map { |slot| slot["stream"] }
        unless observed_streams == expected_streams
          raise CrystalClick::CorruptPartError.new("W276 #{column_name} MRK4 String1 callbacks differ")
        end
      end
    end
    mark_name = physical.marks_name
    unless requested_compress_marks.nil?
      mark_checksum = checksums.entry(mark_name)
      unless mark_checksum && mark_checksum.not_nil!.compressed == requested_compress_marks
        raise CrystalClick::CorruptPartError.new("W276 mark compression differs from request")
      end
    end
    json({
      "format"                   => FORMAT,
      "action"                   => action,
      "status"                   => "ok",
      "part_path"                => part,
      "mark_format"              => mode,
      "requested_mark_format"    => requested_mark_format,
      "requested_compress_marks" => requested_compress_marks,
      "requested_profile"        => requested_profile,
      "first_mark"               => first_mark,
      "selected_mark_count"      => mark_count,
      "row_count"                => physical.row_count,
      "data_mark_count"          => physical.granule_count,
      "mark_row_counts"          => physical.mark_row_counts,
      "keys"                     => keys,
      "columns"                  => columns,
      "physical_roster"          => roster,
      "serialization_metadata"   => {
        "version"                                                => version,
        "string_version"                                         => string_version,
        "propagate_types_serialization_versions_to_nested_types" => propagated,
        "raw"                                                    => serialization_text,
      },
      "marks_file" => mark_name,
      "files"      => files,
      "checksums"  => checksum_entries,
    })
  end

  private def json(value : T) : JSON::Any forall T
    JSON.parse(value.to_json)
  end

  private def validate_new_destination(path : String) : String
    expanded = File.expand_path(path)
    if File.exists?(expanded) || File.symlink?(expanded)
      raise ArgumentError.new("W276 destination already exists or is symlinked")
    end
    parent = File.dirname(expanded)
    unless Dir.exists?(parent) && !File.symlink?(parent) && File.realpath(parent) == parent
      raise ArgumentError.new("W276 destination parent must be canonical and non-symlinked")
    end
    expanded
  end

  private def validate_part(path : String) : String
    expanded = File.expand_path(path)
    unless Dir.exists?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded
      raise ArgumentError.new("W276 source part must be a canonical non-symlink directory")
    end
    expanded
  end

  private def read_bounded_file(part : String, name : String, maximum : Int64) : String
    path = File.join(part, name)
    unless File.file?(path) && !File.symlink?(path) && File.size(path) <= maximum
      raise CrystalClick::CorruptPartError.new("W276 metadata file is missing, symlinked, or oversized: #{name}")
    end
    File.read(path)
  end

  private def inventory(part : String) : Array(NamedTuple(path: String, size: Int64, sha256: String))
    entries = [] of NamedTuple(path: String, size: Int64, sha256: String)
    total = 0_i64
    Dir.each_child(part) do |name|
      path = File.join(part, name)
      stat = File.info(path, follow_symlinks: false)
      unless stat.file? && !stat.symlink?
        raise CrystalClick::CorruptPartError.new("W276 part contains a non-regular top-level entry")
      end
      total += stat.size
      if entries.size >= MAX_FILES || total > MAX_PART_BYTES
        raise CrystalClick::UnsupportedFormatError.new("W276 part inventory exceeds its fixed bound")
      end
      entries << {path: name, size: stat.size, sha256: Digest::SHA256.new.file(path).hexfinal}
    end
    entries.sort_by(&.[:path])
  end
end

puts CompactPartWriterW276Helper.run(ARGV)
