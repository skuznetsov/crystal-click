require "../src/crystal_click"
require "json"
require "set"

module CheckObjectSharedQBitPartsW200
  extend self

  FORMAT                 = "object_shared_qbit_parts_w200_input_v1"
  OUTPUT_FORMAT          = "object_shared_qbit_parts_w200_helper_v1"
  EXPECTED_PROFILE_COUNT =    48
  ROW_COUNT              = 4_u64
  EXPECTED_MARK_ROWS     = [2_u64, 2_u64]
  COLUMN                 = "j"
  PATH                   = "q"
  COLUMN_TYPE            = "JSON(max_dynamic_types=1, max_dynamic_paths=0)"
  CARRIERS               = ["Int8", "BFloat16", "Float32", "Float64"]
  SHAPES                 = [{"dim3", 3_i64, 3_i64, false}, {"dim9", 9_i64, 9_i64, false}, {"stride16_8", 16_i64, 8_i64, true}]

  private struct Profile
    getter id : String
    getter carrier : String
    getter dimension : Int64
    getter stride : Int64
    getter explicit_stride : Bool
    getter shared_version : Int64
    getter string_profile : Int64
    getter type : CrystalClick::QBitType

    def initialize(
      @id : String,
      @carrier : String,
      @dimension : Int64,
      @stride : Int64,
      @explicit_stride : Bool,
      @shared_version : Int64,
      @string_profile : Int64,
      @type : CrystalClick::QBitType,
    )
    end
  end

  def run(args : Array(String)) : Nil
    unless args.size == 2
      STDERR.puts "usage: check_object_shared_qbit_parts_w200 INPUT.json GENERATED_ROOT"
      exit 64
    end

    input_path = File.expand_path(args[0])
    raise ArgumentError.new("W200 input manifest must be a regular non-symlink file") unless File.file?(input_path) && !File.symlink?(input_path)
    output_root = canonical_output_root(args[1])
    input = JSON.parse(File.read(input_path))
    raise ArgumentError.new("W200 input manifest has an unexpected top-level shape") unless input.as_h.keys.sort == ["capture_root", "format", "profiles"]
    raise ArgumentError.new("W200 input manifest format mismatch") unless input["format"].as_s == FORMAT

    capture_root = canonical_capture_root(input["capture_root"].as_s)
    profiles = input["profiles"].as_a
    raise ArgumentError.new("W200 manifest must contain exactly 48 profiles") unless profiles.size == EXPECTED_PROFILE_COUNT
    ids = Set(String).new
    records = profiles.map_with_index do |profile, index|
      process_profile(profile, index, output_root, capture_root, ids)
    end
    raise ArgumentError.new("W200 profile identifiers are duplicated") unless ids.size == EXPECTED_PROFILE_COUNT

    puts json_object({
      "format"         => json_string(OUTPUT_FORMAT),
      "profile_ids"    => JSON::Any.new(records.map { |record| record["id"].as_s }.map { |id| json_string(id) }),
      "profile_count"  => JSON::Any.new(records.size.to_i64),
      "profiles"       => JSON::Any.new(records),
      "capture_root"   => json_string(capture_root),
      "generated_root" => json_string(output_root),
    }).to_json
  rescue ex : Exception
    STDERR.puts "W200 complete-part QBit inspection failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  private def process_profile(
    input : JSON::Any,
    index : Int32,
    output_root : String,
    capture_root : String,
    ids : Set(String),
  ) : JSON::Any
    expected_keys = ["bucket_count", "carrier", "dimension", "explicit_stride", "id", "part", "shared_version", "stride", "string_profile", "type_name"]
    fields = input.as_h
    raise ArgumentError.new("W200 profile fields differ from the fixed schema") unless fields.keys.sort == expected_keys

    expected = expected_profile(index)
    id = fields["id"].as_s
    raise ArgumentError.new("W200 profile roster/order differs from the fixed 48-profile matrix") unless id == expected.id
    raise ArgumentError.new("W200 profile identifier is duplicated") unless ids.add?(id)

    carrier = fields["carrier"].as_s
    dimension = positive_int(fields["dimension"].as_i64, "dimension")
    stride = positive_int(fields["stride"].as_i64, "stride")
    explicit_stride = fields["explicit_stride"].as_bool
    shared_version = fields["shared_version"].as_i64
    string_profile = fields["string_profile"].as_i64
    bucket_count = fields["bucket_count"].as_i64
    unless carrier == expected.carrier && dimension == expected.dimension && stride == expected.stride &&
           explicit_stride == expected.explicit_stride && shared_version == expected.shared_version &&
           string_profile == expected.string_profile && bucket_count == 2
      raise ArgumentError.new("W200 profile fields do not match the fixed 48-profile matrix")
    end
    unless fields["type_name"].as_s == expected.type.type_name
      raise ArgumentError.new("W200 nominal QBit descriptor differs from the fixed profile")
    end

    source_part = canonical_source_part(fields["part"].as_s, capture_root)
    library_part = File.join(output_root, id, "all_1_1_0")
    prepare_library_destination!(library_part, output_root)

    schema = object_schema
    source_reader = CrystalClick::ObjectColumnReader.open(source_part, COLUMN, schema)
    source_marks = read_full(source_reader, id, "stock")
    validate_document_types(source_marks, expected, id, "stock")

    CrystalClick::WidePartWriter.write_uint64_object_pair(
      library_part,
      "pk",
      Slice[1_u64, 2_u64, 3_u64, 4_u64],
      COLUMN,
      schema,
      plan(schema, expected.shared_version),
      source_marks,
      rows_per_mark: 2,
      profile: bulk_profile(expected.string_profile),
    )

    library_reader = CrystalClick::ObjectColumnReader.open(library_part, COLUMN, schema)
    library_marks = read_full(library_reader, id, "library")
    validate_document_types(library_marks, expected, id, "library")

    source_windows = reader_windows(source_reader, source_part, source_marks, expected, id, "stock")
    library_windows = reader_windows(library_reader, library_part, library_marks, expected, id, "library")
    unless source_windows == library_windows
      raise CrystalClick::CorruptPartError.new("W200 #{id} public reader source/library windows differ")
    end

    json_object({
      "id"               => json_string(id),
      "part"             => json_string(source_part),
      "library_part"     => json_string(library_part),
      "type_name"        => json_string(expected.type.type_name),
      "effective_stride" => JSON::Any.new(expected.type.stride.to_i64),
      "source"           => source_windows,
      "library"          => library_windows,
    })
  end

  private def expected_profile(index : Int32) : Profile
    raise ArgumentError.new("W200 profile index is outside fixed matrix") unless index >= 0 && index < EXPECTED_PROFILE_COUNT
    carrier = CARRIERS[index // 12]
    shape_name, dimension, stride, explicit_stride = SHAPES[(index // 4) % 3]
    shared_version = 2_i64 + ((index // 2) % 2)
    string_profile = (index % 2).to_i64
    type = if explicit_stride
             CrystalClick::QBitType.new(carrier, dimension.to_u64, stride.to_u64)
           else
             CrystalClick::QBitType.new(carrier, dimension.to_u64)
           end
    Profile.new(
      "#{carrier.downcase}_#{shape_name}_v#{shared_version}_s#{string_profile}",
      carrier,
      dimension,
      stride,
      explicit_stride,
      shared_version,
      string_profile,
      type,
    )
  end

  private def object_schema : CrystalClick::ObjectDocumentSchema
    CrystalClick::ObjectDocumentSchema.new(
      {} of String => CrystalClick::BinaryDataType,
      max_dynamic_types: 1,
      max_dynamic_paths: 0,
    )
  end

  private def plan(schema : CrystalClick::ObjectDocumentSchema, shared_version : Int64) : CrystalClick::ObjectDocumentPlan
    object = CrystalClick::ObjectStructure.new(
      [] of String,
      shared_data_version: shared_version.to_u64,
      bucket_count: 2_u64,
    )
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      object,
      {} of String => CrystalClick::DynamicStructure,
    )
    CrystalClick::ObjectDocumentPlan.new(structures, schema.typed_paths)
  end

  private def read_full(
    reader : CrystalClick::ObjectColumnReader,
    id : String,
    side : String,
  ) : Array(Array(CrystalClick::ObjectDocument))
    unless reader.row_count == ROW_COUNT && reader.mark_row_counts == EXPECTED_MARK_ROWS
      raise CrystalClick::CorruptPartError.new("W200 #{id} #{side} source does not have the fixed four-row/two-mark grid")
    end
    full = reader.read_marks(0, 2)
    unless full.size == 2 && full.all?(&.size.==(2))
      raise CrystalClick::CorruptPartError.new("W200 #{id} #{side} full read differs from the fixed mark grid")
    end
    full
  end

  private def validate_document_types(
    marks : Array(Array(CrystalClick::ObjectDocument)),
    profile : Profile,
    id : String,
    side : String,
  ) : Nil
    expected_rows = [true, false, true, true]
    marks.each_with_index do |mark, mark_index|
      mark.each_with_index do |document, row_index|
        row = mark_index * 2 + row_index
        present = document.has_path?(PATH)
        unless present == expected_rows[row]
          raise CrystalClick::CorruptPartError.new("W200 #{id} #{side} row #{row + 1} presence differs from the fixed fixture")
        end
        next unless present

        value = document.value_for(PATH)
        expected_type = CrystalClick::BinaryDataType.qbit(profile.type)
        unless value.type == expected_type && value.qbit_value.type == profile.type &&
               value.qbit_value.raw_bytesize == profile.type.raw_row_bytes
          raise CrystalClick::CorruptPartError.new("W200 #{id} #{side} row #{row + 1} has a different nominal/effective QBit type")
        end
      end
    end
  end

  private def reader_windows(
    reader : CrystalClick::ObjectColumnReader,
    part : String,
    full : Array(Array(CrystalClick::ObjectDocument)),
    profile : Profile,
    id : String,
    side : String,
  ) : JSON::Any
    unless reader.source_declaration == COLUMN_TYPE && reader.schema_declaration == COLUMN_TYPE &&
           reader.ordinary_profile == bulk_profile(profile.string_profile)
      raise CrystalClick::CorruptPartError.new("W200 #{id} #{side} source declaration or ordinary String profile differs")
    end
    file_descriptor = descriptor(reader, part)
    plan = file_descriptor.plan
    structure_set = plan.structures
    persisted = structure_set.object
    object_dynamic_paths = persisted.dynamic_paths.sort
    dynamic_roster = structure_set.dynamics.keys.sort
    typed_paths = plan.typed_paths.keys.sort
    unless persisted.shared_data_version == profile.shared_version.to_u64 && persisted.bucket_count == 2_u64
      raise CrystalClick::CorruptPartError.new("W200 #{id} #{side} persisted shared-data profile differs")
    end
    unless object_dynamic_paths.empty? && structure_set.dynamic_count == 0 && dynamic_roster.empty? && typed_paths.empty?
      raise CrystalClick::CorruptPartError.new("W200 #{id} #{side} is not an Object-shared-only structure")
    end
    middle = reader.read_marks(1, 1)
    zero = reader.read_marks(2, 0)
    unless middle.size == 1 && middle[0].size == 2 && zero.empty?
      raise CrystalClick::CorruptPartError.new("W200 #{id} #{side} middle/zero windows differ from the fixed mark selection")
    end
    json_object({
      "source_declaration"      => json_string(reader.source_declaration),
      "schema_declaration"      => json_string(reader.schema_declaration),
      "row_count"               => JSON::Any.new(reader.row_count.to_i64),
      "mark_row_counts"         => JSON::Any.new(reader.mark_row_counts.map { |count| JSON::Any.new(count.to_i64) }),
      "ordinary_string_profile" => JSON::Any.new(string_profile_id(reader.ordinary_profile)),
      "shared_version"          => JSON::Any.new(persisted.shared_data_version.to_i64),
      "bucket_count"            => JSON::Any.new(persisted.bucket_count.to_i64),
      "object_dynamic_paths"    => JSON::Any.new(object_dynamic_paths.map { |path| json_string(path) }),
      "dynamic_roster"          => JSON::Any.new(dynamic_roster.map { |path| json_string(path) }),
      "typed_paths"             => JSON::Any.new(typed_paths.map { |path| json_string(path) }),
      "type_name"               => json_string(profile.type.type_name),
      "effective_stride"        => JSON::Any.new(profile.type.stride.to_i64),
      "full_rows"               => JSON::Any.new(render_rows(full, 0)),
      "middle_rows"             => JSON::Any.new(render_rows(middle, 2)),
      "zero_rows"               => JSON::Any.new(render_rows(zero, 4)),
      "middle_window"           => JSON::Any.new({"first_mark" => JSON::Any.new(1_i64), "mark_count" => JSON::Any.new(1_i64)} of String => JSON::Any),
      "zero_window"             => JSON::Any.new({"first_mark" => JSON::Any.new(2_i64), "mark_count" => JSON::Any.new(0_i64)} of String => JSON::Any),
    })
  end

  private def render_rows(marks : Array(Array(CrystalClick::ObjectDocument)), first_row : Int32) : Array(JSON::Any)
    rows = [] of JSON::Any
    marks.each_with_index do |mark, mark_index|
      mark.each_with_index do |document, row_index|
        present = document.has_path?(PATH)
        if present
          value = document.value_for(PATH)
          qbit = value.qbit_value
          rows << json_object({
            "pk"               => JSON::Any.new((first_row + mark_index * 2 + row_index + 1).to_i64),
            "path_present"     => JSON::Any.new(true),
            "type_name"        => json_string(qbit.type.type_name),
            "effective_stride" => JSON::Any.new(qbit.type.stride.to_i64),
            "raw_hex"          => json_string(qbit.raw_bytes.hexstring.downcase),
          })
        else
          rows << json_object({
            "pk"               => JSON::Any.new((first_row + mark_index * 2 + row_index + 1).to_i64),
            "path_present"     => JSON::Any.new(false),
            "type_name"        => JSON::Any.new(nil),
            "effective_stride" => JSON::Any.new(nil),
            "raw_hex"          => JSON::Any.new(nil),
          })
        end
      end
    end
    rows
  end

  private def descriptor(reader : CrystalClick::ObjectColumnReader, part : String) : CrystalClick::ObjectDocumentFileDescriptor
    CrystalClick::ObjectDocumentFileReader.inspect(
      part,
      COLUMN,
      {} of String => CrystalClick::BinaryDataType,
      reader.ordinary_profile,
      CrystalClick::BinaryBulkProfile.single_stream,
      true,
    )
  end

  private def bulk_profile(version : Int64) : CrystalClick::BinaryBulkProfile
    case version
    when 0 then CrystalClick::BinaryBulkProfile.single_stream
    when 1 then CrystalClick::BinaryBulkProfile.with_size_stream
    else        raise ArgumentError.new("W200 String profile must be 0 or 1")
    end
  end

  private def string_profile_id(profile : CrystalClick::BinaryBulkProfile) : Int64
    return 0_i64 if profile == CrystalClick::BinaryBulkProfile.single_stream
    return 1_i64 if profile == CrystalClick::BinaryBulkProfile.with_size_stream
    -1_i64
  end

  private def canonical_capture_root(path : String) : String
    expanded = File.expand_path(path)
    unless Dir.exists?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded && expanded.starts_with?("/private/tmp/")
      raise ArgumentError.new("W200 capture root must be a canonical /private/tmp directory")
    end
    expanded
  end

  private def canonical_output_root(path : String) : String
    expanded = File.expand_path(path)
    unless Dir.exists?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded && expanded.starts_with?("/private/tmp/")
      raise ArgumentError.new("W200 generated root must be a canonical /private/tmp directory")
    end
    expanded
  end

  private def canonical_source_part(path : String, root : String) : String
    expanded = File.expand_path(path)
    unless Dir.exists?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded && expanded.starts_with?(root + File::SEPARATOR)
      raise ArgumentError.new("W200 stock source part must be canonical, plain, and below the capture root")
    end
    expanded
  end

  private def prepare_library_destination!(path : String, root : String) : Nil
    expanded = File.expand_path(path)
    unless expanded.starts_with?(root + File::SEPARATOR) && !File.exists?(expanded) && !File.symlink?(expanded)
      raise ArgumentError.new("W200 library destination is not a fresh descendant of generated root")
    end
    relative = expanded.byte_slice(root.bytesize + 1, expanded.bytesize - root.bytesize - 1)
    parent_relative = File.dirname(relative)
    current = root
    unless parent_relative == "."
      parent_relative.split(File::SEPARATOR).each do |component|
        next if component.empty? || component == "."
        raise ArgumentError.new("W200 library path contains traversal") if component == ".."
        candidate = File.join(current, component)
        if File.symlink?(candidate)
          raise ArgumentError.new("W200 library parent contains a symlink")
        elsif Dir.exists?(candidate)
          current = File.realpath(candidate)
        elsif File.exists?(candidate)
          raise ArgumentError.new("W200 library parent component is not a directory")
        else
          Dir.mkdir(candidate, 0o700)
          current = File.realpath(candidate)
        end
        unless current.starts_with?(root + File::SEPARATOR)
          raise ArgumentError.new("W200 library parent escapes generated root")
        end
      end
    end
  end

  private def positive_int(value : Int64, label : String) : Int64
    raise ArgumentError.new("W200 #{label} must be a positive Int32") unless value > 0 && value <= Int32::MAX
    value
  end

  private def json_string(value : String) : JSON::Any
    JSON::Any.new(value)
  end

  private def json_object(value : Hash(String, JSON::Any)) : JSON::Any
    JSON::Any.new(value)
  end
end

CheckObjectSharedQBitPartsW200.run(ARGV)
