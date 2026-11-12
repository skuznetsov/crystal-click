require "../src/crystal_click"
require "../spec/support/compact_part_writer_w277_fixture"
require "digest/sha256"
require "json"

module CompactContextStringWriterW277Helper
  extend self

  FORMAT         = "compact_context_string_writer_w277_helper_v1"
  MAX_FILES      = 192
  MAX_PART_BYTES = 64_i64 * 1024_i64 * 1024_i64

  def run(args : Array(String)) : String
    action = args[0]? || raise ArgumentError.new("expected write, read, or audit")
    report = case action
             when "write"
               unless args.size == 6
                 raise ArgumentError.new("usage: helper write DEST mrk3|mrk4 plain|compressed basic|compact map|map_with_buckets")
               end
               write_part(args[1], args[2], args[3], args[4], args[5])
             when "read"
               unless args.size == 6
                 raise ArgumentError.new("usage: helper read PART map|map_with_buckets COLUMN|all FIRST_MARK MARK_COUNT")
               end
               column_name = args[3] == "all" ? nil : args[3]
               selected_report(validate_part(args[1]), args[2], "read", column_name, args[4].to_i32, args[5].to_i32)
             when "audit"
               unless args.size == 3
                 raise ArgumentError.new("usage: helper audit PART map|map_with_buckets")
               end
               selected_report(validate_part(args[1]), args[2], "audit", nil, 0, CompactPartWriterW277Fixture::MARK_COUNT)
             else
               raise ArgumentError.new("unknown W277 helper action: #{action}")
             end
    report.to_json
  end

  private def write_part(
    destination : String,
    mark_name : String,
    compression_name : String,
    mode_name : String,
    shared_layout_name : String,
  ) : JSON::Any
    mark = case mark_name
           when "mrk3" then CrystalClick::CompactMarkFormat::Mrk3
           when "mrk4" then CrystalClick::CompactMarkFormat::Mrk4
           else             raise ArgumentError.new("W277 mark format must be mrk3 or mrk4")
           end
    compressed = case compression_name
                 when "plain"      then false
                 when "compressed" then true
                 else                   raise ArgumentError.new("W277 compression must be plain or compressed")
                 end
    mode = case mode_name
           when "basic"   then CrystalClick::CompactVariantDiscriminatorMode::Basic
           when "compact" then CrystalClick::CompactVariantDiscriminatorMode::Compact
           else                raise ArgumentError.new("W277 Variant discriminator mode must be basic or compact")
           end
    shared_layout = shared_layout(shared_layout_name)
    part = validate_new_destination(destination)
    fixture = CompactPartWriterW277Fixture
    CrystalClick::CompactPartWriter.write_uint64_columns(
      part,
      CompactPartWriterW277Fixture::KEY_NAME,
      fixture.keys,
      fixture.columns(shared_layout: shared_layout),
      CompactPartWriterW277Fixture::ROWS_PER_MARK,
      CompactPartWriterW277Fixture::FRAME_BYTES,
      mark_format: mark,
      compress_marks: compressed,
      variant_discriminator_mode: mode,
      profile: CrystalClick::BinaryBulkProfile.with_size_stream,
    )
    selected_report(
      part,
      shared_layout_name,
      "write",
      nil,
      0,
      CompactPartWriterW277Fixture::MARK_COUNT,
      requested_mark_format: mark_name,
      requested_compression: compression_name,
      requested_mode: mode_name,
    )
  end

  private def selected_report(
    part : String,
    shared_layout_name : String,
    action : String,
    column_name : String?,
    first_mark : Int32,
    mark_count : Int32,
    requested_mark_format : String? = nil,
    requested_compression : String? = nil,
    requested_mode : String? = nil,
  ) : JSON::Any
    fixture = CompactPartWriterW277Fixture
    layout = shared_layout(shared_layout_name)
    mark_total = CompactPartWriterW277Fixture::MARK_COUNT
    unless first_mark >= 0 && mark_count >= 0 && first_mark <= mark_total && mark_count <= mark_total - first_mark
      raise ArgumentError.new("W277 selected mark window is outside the four data marks")
    end
    names_for_layout = fixture.column_names_for(layout)
    schemas_for_layout = fixture.schemas(layout)
    unless names_for_layout.includes?(column_name || names_for_layout.first)
      raise ArgumentError.new("W277 selected column is outside the fixed fixture")
    end
    physical = CrystalClick::CompactPartPhysicalContext.open(part)
    mark_format = physical.mode.mrk3? ? "mrk3" : (physical.mode.mrk4? ? "mrk4" : "unsupported")
    unless mark_format == "mrk3" || mark_format == "mrk4"
      raise CrystalClick::UnsupportedFormatError.new("W277 part has an unsupported Compact mark format")
    end
    if requested_mark_format && requested_mark_format != mark_format
      raise CrystalClick::CorruptPartError.new("W277 written mark format differs from request")
    end
    unless physical.row_count == CompactPartWriterW277Fixture::ROW_COUNT.to_u64 &&
           physical.mark_row_counts == Array(UInt64).new(mark_total, CompactPartWriterW277Fixture::ROWS_PER_MARK.to_u64)
      raise CrystalClick::CorruptPartError.new("W277 physical part rows or data-mark grid differs from fixture")
    end

    names = column_name ? [column_name] : names_for_layout
    columns = Array(JSON::Any).new
    names.each do |name|
      type = fixture.types[name]?
      raise CrystalClick::UnsupportedFormatError.new("W277 fixture omits declared type for #{name}") unless type
      json_schema = schemas_for_layout[name]?
      if schema = json_schema
        reader = CrystalClick::CompactRecursiveJsonColumnReader.open(part, name, schema)
        unless reader.ordinary_profile.with_size_stream?
          raise CrystalClick::UnsupportedFormatError.new("W277 JSON reader lost the propagated String1 profile for #{name}")
        end
        marks = reader.read_marks(first_mark, mark_count)
        signatures = fixture.signatures_from(name, marks)
        expected = fixture.expected_signatures(name)[first_mark * CompactPartWriterW277Fixture::ROWS_PER_MARK, mark_count * CompactPartWriterW277Fixture::ROWS_PER_MARK]
        unless signatures == expected
          raise CrystalClick::CorruptPartError.new("W277 recursive JSON reader signatures differ for #{name}")
        end
        columns << column_report(name, reader.schema_declaration, reader.ordinary_profile, reader.mark_row_counts,
          signatures, reader.physical_stream_names, reader.selected_checksum_names)
      else
        reader = CrystalClick::CompactDynamicBulkColumnReader.open(part, name, type)
        unless reader.ordinary_profile.with_size_stream?
          raise CrystalClick::UnsupportedFormatError.new("W277 Dynamic reader lost the propagated String1 profile for #{name}")
        end
        marks = reader.read_marks(first_mark, mark_count)
        signatures = fixture.signatures_from(name, marks)
        expected = fixture.expected_signatures(name)[first_mark * CompactPartWriterW277Fixture::ROWS_PER_MARK, mark_count * CompactPartWriterW277Fixture::ROWS_PER_MARK]
        unless signatures == expected
          raise CrystalClick::CorruptPartError.new("W277 Dynamic reader signatures differ for #{name}")
        end
        columns << column_report(name, reader.schema_declaration, reader.ordinary_profile, reader.mark_row_counts,
          signatures, reader.physical_stream_names, reader.selected_checksum_names)
      end
    end

    key_reader = CrystalClick::CompactBinaryBulkColumnReader.open(
      part,
      CompactPartWriterW277Fixture::KEY_NAME,
      CrystalClick::BinaryDataType.primitive("UInt64"),
    )
    keys = key_reader.read_marks(first_mark, mark_count).flatten.map(&.as_uint64)
    expected_keys = fixture.keys[first_mark * CompactPartWriterW277Fixture::ROWS_PER_MARK, mark_count * CompactPartWriterW277Fixture::ROWS_PER_MARK].to_a
    unless keys == expected_keys
      raise CrystalClick::CorruptPartError.new("W277 key reader differs from fixed fixture")
    end

    metadata_text = read_bounded_file(part, "serialization.json", 4_i64 * 1024_i64 * 1024_i64)
    metadata = JSON.parse(metadata_text).as_h
    info_version = metadata["version"]?.try(&.as_i) || raise CrystalClick::CorruptPartError.new("W277 serialization metadata version is absent")
    propagated = metadata["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) || false
    versions = metadata["types_serialization_versions"]?.try(&.as_h) || raise CrystalClick::CorruptPartError.new("W277 serialization version roster is absent")
    string_version = versions["string"]?.try(&.as_i) || raise CrystalClick::CorruptPartError.new("W277 String version is absent")
    unless info_version == 1 && string_version == 1 && propagated
      raise CrystalClick::UnsupportedFormatError.new("W277 part is not propagated String1/with_size_stream")
    end

    checksums = CrystalClick::PartChecksums.open(part)
    mark_file = physical.marks_name
    if compression = requested_compression
      entry = checksums.entry(mark_file)
      expected_compressed = compression == "compressed"
      unless entry && entry.not_nil!.compressed == expected_compressed
        raise CrystalClick::CorruptPartError.new("W277 mark compression differs from request")
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
      "shared_layout"          => shared_layout_name,
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
      "serialization_metadata" => {
        "version"                                                => info_version,
        "string_version"                                         => string_version,
        "propagate_types_serialization_versions_to_nested_types" => propagated,
        "raw"                                                    => metadata_text,
      },
      "marks_file" => mark_file,
      "files"      => files,
      "checksums"  => checksum_entries,
    })
  end

  private def column_report(
    name : String,
    type : String,
    profile : CrystalClick::BinaryBulkProfile,
    mark_rows : Array(UInt64),
    signatures : Array(String),
    streams : Array(String),
    checksums : Array(String),
  ) : JSON::Any
    json({
      "name"                    => name,
      "type"                    => type,
      "profile"                 => profile.with_size_stream? ? "with_size_stream" : "single_stream",
      "mark_row_counts"         => mark_rows,
      "signatures"              => signatures,
      "physical_stream_names"   => streams,
      "selected_checksum_names" => checksums,
    })
  end

  private def shared_layout(name : String) : Symbol
    case name
    when "map"              then :map
    when "map_with_buckets" then :map_with_buckets
    else                         raise ArgumentError.new("W277 shared layout must be map or map_with_buckets")
    end
  end

  private def json(value : T) : JSON::Any forall T
    JSON.parse(value.to_json)
  end

  private def validate_new_destination(path : String) : String
    expanded = File.expand_path(path)
    if File.exists?(expanded) || File.symlink?(expanded)
      raise ArgumentError.new("W277 destination already exists or is symlinked")
    end
    parent = File.dirname(expanded)
    unless Dir.exists?(parent) && !File.symlink?(parent) && File.realpath(parent) == parent
      raise ArgumentError.new("W277 destination parent must be canonical and non-symlinked")
    end
    expanded
  end

  private def validate_part(path : String) : String
    expanded = File.expand_path(path)
    unless Dir.exists?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded
      raise ArgumentError.new("W277 source part must be a canonical non-symlink directory")
    end
    expanded
  end

  private def read_bounded_file(part : String, name : String, maximum : Int64) : String
    path = File.join(part, name)
    unless File.file?(path) && !File.symlink?(path) && File.size(path) <= maximum
      raise CrystalClick::CorruptPartError.new("W277 metadata file is missing, symlinked, or oversized: #{name}")
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
        raise CrystalClick::CorruptPartError.new("W277 part contains a non-regular top-level entry")
      end
      total += stat.size
      if entries.size >= MAX_FILES || total > MAX_PART_BYTES
        raise CrystalClick::UnsupportedFormatError.new("W277 part inventory exceeds its fixed bound")
      end
      entries << {path: name, size: stat.size, sha256: Digest::SHA256.new.file(path).hexfinal}
    end
    entries.sort_by(&.[:path])
  end
end

puts CompactContextStringWriterW277Helper.run(ARGV)
