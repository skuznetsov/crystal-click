require "../src/crystal_click"
require "../spec/support/compact_part_writer_w278_fixture"
require "digest/sha256"
require "json"

module CompactAdvancedJsonWriterW278Helper
  extend self

  FORMAT         = "compact_advanced_json_writer_w278_helper_v1"
  MAX_FILES      = 192
  MAX_PART_BYTES = 64_i64 * 1024_i64 * 1024_i64

  def run(args : Array(String)) : String
    action = args[0]? || raise ArgumentError.new("expected write, read, or audit")
    report = case action
             when "write"
               unless args.size == 7
                 raise ArgumentError.new("usage: helper write DEST advanced|advanced_chunked mrk3|mrk4 plain|compressed basic|compact s0|s1")
               end
               write_part(args[1], args[2], args[3], args[4], args[5], args[6])
             when "read"
               unless args.size == 7
                 raise ArgumentError.new("usage: helper read PART advanced|advanced_chunked s0|s1 COLUMN|all FIRST_MARK MARK_COUNT")
               end
               column_name = args[4] == "all" ? nil : args[4]
               selected_report(validate_part(args[1]), args[2], args[3], "read", column_name, args[5].to_i32, args[6].to_i32)
             when "audit"
               unless args.size == 4
                 raise ArgumentError.new("usage: helper audit PART advanced|advanced_chunked s0|s1")
               end
               selected_report(validate_part(args[1]), args[2], args[3], "audit", nil, 0, CompactPartWriterW278Fixture::MARK_COUNT)
             else
               raise ArgumentError.new("unknown W278 helper action: #{action}")
             end
    report.to_json
  end

  private def write_part(
    destination : String,
    shared_version_name : String,
    mark_name : String,
    compression_name : String,
    mode_name : String,
    profile_name : String,
  ) : JSON::Any
    version_info = shared_version(shared_version_name)
    shared_version_value = version_info[0]
    profile = profile(profile_name)
    mark = case mark_name
           when "mrk3" then CrystalClick::CompactMarkFormat::Mrk3
           when "mrk4" then CrystalClick::CompactMarkFormat::Mrk4
           else             raise ArgumentError.new("W278 mark format must be mrk3 or mrk4")
           end
    compressed = case compression_name
                 when "plain"      then false
                 when "compressed" then true
                 else                   raise ArgumentError.new("W278 mark compression must be plain or compressed")
                 end
    mode = case mode_name
           when "basic"   then CrystalClick::CompactVariantDiscriminatorMode::Basic
           when "compact" then CrystalClick::CompactVariantDiscriminatorMode::Compact
           else                raise ArgumentError.new("W278 discriminator mode must be basic or compact")
           end
    part = validate_new_destination(destination)
    fixture = CompactPartWriterW278Fixture
    CrystalClick::CompactPartWriter.write_uint64_columns(
      part,
      CompactPartWriterW278Fixture::KEY_NAME,
      fixture.keys,
      fixture.columns(shared_version_value),
      rows_per_mark: CompactPartWriterW278Fixture::ROWS_PER_MARK,
      # Small frames make later-granule and frame-boundary relocations visible.
      frame_bytes: 64,
      mark_format: mark,
      variant_discriminator_mode: mode,
      compress_marks: compressed,
      profile: profile,
    )
    selected_report(
      part,
      shared_version_name,
      profile_name,
      "write",
      nil,
      0,
      CompactPartWriterW278Fixture::MARK_COUNT,
      requested_mark_format: mark_name,
      requested_compression: compression_name,
      requested_mode: mode_name,
    )
  end

  private def selected_report(
    part : String,
    shared_version_name : String,
    profile_name : String,
    action : String,
    column_name : String?,
    first_mark : Int32,
    mark_count : Int32,
    requested_mark_format : String? = nil,
    requested_compression : String? = nil,
    requested_mode : String? = nil,
  ) : JSON::Any
    version_info = shared_version(shared_version_name)
    shared_version_value = version_info[0]
    shared_version_label = version_info[1]
    expected_profile = profile(profile_name)
    mark_total = CompactPartWriterW278Fixture::MARK_COUNT
    unless first_mark >= 0 && mark_count >= 0 && first_mark <= mark_total && mark_count <= mark_total - first_mark
      raise ArgumentError.new("W278 selected mark window is outside the four data marks")
    end
    fixture = CompactPartWriterW278Fixture
    names = CompactPartWriterW278Fixture::COLUMN_NAMES
    if selected = column_name
      raise ArgumentError.new("W278 selected column is outside the fixed fixture") unless names.includes?(selected)
      names = [selected]
    end

    physical = CrystalClick::CompactPartPhysicalContext.open(part)
    mark_format = physical.mode.mrk3? ? "mrk3" : (physical.mode.mrk4? ? "mrk4" : "unsupported")
    unless mark_format == "mrk3" || mark_format == "mrk4"
      raise CrystalClick::UnsupportedFormatError.new("W278 part has an unsupported Compact mark format")
    end
    if requested_mark_format && requested_mark_format != mark_format
      raise CrystalClick::CorruptPartError.new("W278 written mark format differs from request")
    end
    unless physical.row_count == CompactPartWriterW278Fixture::ROW_COUNT.to_u64 &&
           physical.mark_row_counts == Array(UInt64).new(mark_total, CompactPartWriterW278Fixture::ROWS_PER_MARK.to_u64)
      raise CrystalClick::CorruptPartError.new("W278 physical part rows or data-mark grid differs from fixture")
    end

    columns = Array(JSON::Any).new
    names.each do |name|
      schema = fixture.schemas[name]? || raise CrystalClick::UnsupportedFormatError.new("W278 fixture omits schema for #{name}")
      reader = CrystalClick::CompactRecursiveJsonColumnReader.open(part, name, schema)
      unless reader.ordinary_profile == expected_profile
        raise CrystalClick::UnsupportedFormatError.new("W278 JSON reader lost the requested String profile for #{name}")
      end
      marks = reader.read_marks(first_mark, mark_count)
      signatures = marks.flatten.map { |value| storage_signature(value) }
      expected = fixture.rows_for(name)[first_mark * CompactPartWriterW278Fixture::ROWS_PER_MARK, mark_count * CompactPartWriterW278Fixture::ROWS_PER_MARK]
      unless signatures == expected.map { |value| storage_signature(value) }
        raise CrystalClick::CorruptPartError.new("W278 recursive JSON reader signatures differ for #{name}")
      end
      columns << json({
        "name"                    => name,
        "type"                    => reader.schema_declaration,
        "profile"                 => reader.ordinary_profile.with_size_stream? ? "with_size_stream" : "single_stream",
        "mark_row_counts"         => reader.mark_row_counts,
        "signatures"              => signatures,
        "physical_stream_names"   => reader.physical_stream_names,
        "selected_checksum_names" => reader.selected_checksum_names,
      })
    end

    key_reader = CrystalClick::CompactBinaryBulkColumnReader.open(
      part,
      CompactPartWriterW278Fixture::KEY_NAME,
      CrystalClick::BinaryDataType.primitive("UInt64"),
    )
    keys = key_reader.read_marks(first_mark, mark_count).flatten.map(&.as_uint64)
    expected_keys = fixture.keys[first_mark * CompactPartWriterW278Fixture::ROWS_PER_MARK,
      mark_count * CompactPartWriterW278Fixture::ROWS_PER_MARK].to_a
    unless keys == expected_keys
      raise CrystalClick::CorruptPartError.new("W278 key reader differs from fixed fixture")
    end

    metadata_text = read_bounded_file(part, "serialization.json", 4_i64 * 1024_i64 * 1024_i64)
    metadata = JSON.parse(metadata_text).as_h
    info_version = metadata["version"]?.try(&.as_i) || raise CrystalClick::CorruptPartError.new("W278 serialization metadata version is absent")
    propagated = metadata["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) || false
    versions = metadata["types_serialization_versions"]?.try(&.as_h) || raise CrystalClick::CorruptPartError.new("W278 serialization version roster is absent")
    string_version = versions["string"]?.try(&.as_i) || raise CrystalClick::CorruptPartError.new("W278 String version is absent")
    expected_string_version = expected_profile.with_size_stream? ? 1 : 0
    unless info_version == 1 && string_version == expected_string_version && propagated
      raise CrystalClick::UnsupportedFormatError.new("W278 metadata does not match the requested propagated String profile")
    end
    metadata_report = {
      "version"                                                => info_version,
      "string_version"                                         => string_version,
      "propagate_types_serialization_versions_to_nested_types" => propagated,
      "raw"                                                    => metadata_text,
    }

    checksums = CrystalClick::PartChecksums.open(part)
    mark_file = physical.marks_name
    if compression = requested_compression
      entry = checksums.entry(mark_file)
      unless entry && entry.not_nil!.compressed == (compression == "compressed")
        raise CrystalClick::CorruptPartError.new("W278 mark compression differs from request")
      end
    end
    files = inventory(part)
    roster = physical.physical_roster.map do |slot|
      {"index" => slot.index, "column" => slot.column_name, "stream" => slot.stream_name}
    end
    checksum_entries = checksums.entries.keys.sort.map do |name|
      entry = checksums.entry(name).not_nil!
      {"name" => name, "physical_size" => entry.physical_size, "compressed" => entry.compressed,
       "uncompressed_size" => entry.uncompressed_size}
    end
    json({
      "format"                 => FORMAT,
      "action"                 => action,
      "status"                 => "ok",
      "part_path"              => part,
      "shared_version"         => shared_version_label,
      "shared_version_value"   => shared_version_value,
      "profile"                => profile_name,
      "mark_format"            => mark_format,
      "requested_mark_format"  => requested_mark_format,
      "requested_compression"  => requested_compression,
      "requested_mode"         => requested_mode,
      "first_mark"             => first_mark,
      "selected_mark_count"    => mark_count,
      "row_count"              => physical.row_count,
      "data_mark_count"        => physical.granule_count,
      "mark_row_counts"        => physical.mark_row_counts,
      "keys"                   => keys,
      "columns"                => columns,
      "physical_roster"        => roster,
      "serialization_metadata" => metadata_report,
      "marks_file"             => mark_file,
      "files"                  => files,
      "checksums"              => checksum_entries,
    })
  end

  private def storage_signature(value : CrystalClick::StorageColumnValue) : String
    if value.object?
      fields = value.object_document.paths.map do |path|
        "#{path.bytesize}:#{path.to_slice.hexstring}=#{binary_signature(value.object_document.value_for(path))}"
      end
      "JSON{#{fields.join(";")}}"
    elsif value.array?
      "Array[#{value.array_values.map { |child| storage_signature(child) }.join(";")}]"
    elsif value.tuple?
      "Tuple(#{value.tuple_values.map { |child| storage_signature(child) }.join(";")})"
    elsif value.bulk?
      binary_signature(value.bulk_value)
    else
      raise CrystalClick::UnsupportedFormatError.new("W278 reader returned an unknown storage value node")
    end
  end

  private def binary_signature(value : CrystalClick::BinaryValue) : String
    return "NULL(#{value.type.name})" if value.is_null?
    case value.type.tag
    when CrystalClick::BinaryDataType::TAG_STRING
      bytes = value.as_string.to_slice
      "S#{bytes.size}:#{bytes.hexstring}"
    when CrystalClick::BinaryDataType::TAG_UINT8
      "U8:#{value.bytes[0]}"
    when CrystalClick::BinaryDataType::TAG_UINT64
      "U64:#{value.as_uint64}"
    else
      raise CrystalClick::UnsupportedFormatError.new("W278 signature has an unsupported leaf type: #{value.type.name}")
    end
  end

  private def shared_version(name : String) : Tuple(UInt64, String)
    case name
    when "advanced"         then {2_u64, "advanced"}
    when "advanced_chunked" then {3_u64, "advanced_chunked"}
    else                         raise ArgumentError.new("W278 shared version must be advanced or advanced_chunked")
    end
  end

  private def profile(name : String) : CrystalClick::BinaryBulkProfile
    case name
    when "s0" then CrystalClick::BinaryBulkProfile.single_stream
    when "s1" then CrystalClick::BinaryBulkProfile.with_size_stream
    else           raise ArgumentError.new("W278 profile must be s0 or s1")
    end
  end

  private def json(value : T) : JSON::Any forall T
    JSON.parse(value.to_json)
  end

  private def validate_new_destination(path : String) : String
    expanded = File.expand_path(path)
    if File.exists?(expanded) || File.symlink?(expanded)
      raise ArgumentError.new("W278 destination already exists or is symlinked")
    end
    parent = File.dirname(expanded)
    unless Dir.exists?(parent) && !File.symlink?(parent) && File.realpath(parent) == parent
      raise ArgumentError.new("W278 destination parent must be canonical and non-symlinked")
    end
    expanded
  end

  private def validate_part(path : String) : String
    expanded = File.expand_path(path)
    unless Dir.exists?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded
      raise ArgumentError.new("W278 source part must be a canonical non-symlink directory")
    end
    expanded
  end

  private def read_bounded_file(part : String, name : String, maximum : Int64) : String
    path = File.join(part, name)
    unless File.file?(path) && !File.symlink?(path) && File.size(path) <= maximum
      raise CrystalClick::CorruptPartError.new("W278 metadata file is missing, symlinked, or oversized: #{name}")
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
        raise CrystalClick::CorruptPartError.new("W278 part contains a non-regular top-level entry")
      end
      total += stat.size
      if entries.size >= MAX_FILES || total > MAX_PART_BYTES
        raise CrystalClick::UnsupportedFormatError.new("W278 part inventory exceeds its fixed bound")
      end
      entries << {path: name, size: stat.size, sha256: Digest::SHA256.new.file(path).hexfinal}
    end
    entries.sort_by(&.[:path])
  end
end

puts CompactAdvancedJsonWriterW278Helper.run(ARGV)
