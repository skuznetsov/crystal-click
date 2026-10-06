require "../src/crystal_click"
require "json"

module CheckObjectSharedNestedPartsW198
  extend self

  PROFILE_IDS = [
    "nested_v2_s0", "nested_v2_s1", "nested_v3_s0", "nested_v3_s1",
    "array_tuple_v2_s0", "array_tuple_v2_s1", "array_tuple_v3_s0", "array_tuple_v3_s1",
  ]
  EXPECTED_MARK_ROWS = [2_u64, 2_u64, 2_u64, 2_u64]
  PATH_NAME          = "n"

  alias Document = CrystalClick::ObjectDocument

  private def schema : CrystalClick::ObjectDocumentSchema
    CrystalClick::ObjectDocumentSchema.new(
      {} of String => CrystalClick::BinaryDataType,
      max_dynamic_types: 1,
      max_dynamic_paths: 0,
    )
  end

  private def actual_type(kind : String) : CrystalClick::BinaryDataType
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")
    string = CrystalClick::BinaryDataType.primitive("String")
    fields = [uint8, string] of CrystalClick::BinaryDataType
    names = ["n", "s"] of String
    case kind
    when "nested"
      CrystalClick::BinaryDataType.nested(fields, names)
    when "array_tuple"
      tuple = CrystalClick::BinaryDataType.tuple(fields, names)
      CrystalClick::BinaryDataType.array(tuple)
    else
      raise ArgumentError.new("W198 kind is outside the Nested/Array(Tuple) matrix")
    end
  end

  private def plan(inner : CrystalClick::ObjectDocumentSchema, version : Int) : CrystalClick::ObjectDocumentPlan
    object = CrystalClick::ObjectStructure.new(
      [] of String,
      shared_data_version: version.to_u64,
      bucket_count: 2_u64,
    )
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      object,
      {} of String => CrystalClick::DynamicStructure,
    )
    CrystalClick::ObjectDocumentPlan.new(structures, inner.typed_paths)
  end

  private def tuple_value(kind : String, number : UInt8, text : String) : CrystalClick::BinaryValue
    type = actual_type(kind)
    tuple_type = type.child_at(0)
    fields = [
      CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[number]),
      CrystalClick::BinaryValue.string(text),
    ] of CrystalClick::BinaryValue
    CrystalClick::BinaryValue.tuple(tuple_type, fields)
  end

  private def present_document(kind : String, entries : Array(Tuple(UInt8, String))) : Document
    type = actual_type(kind)
    records = entries.map { |entry| tuple_value(kind, entry[0], entry[1]) }
    value = if kind == "nested"
              CrystalClick::BinaryValue.nested(type, records)
            else
              CrystalClick::BinaryValue.array(type, records)
            end
    Document.new({PATH_NAME => value})
  end

  private def documents(kind : String) : Array(Document)
    [
      present_document(kind, [{7_u8, "one"}] of Tuple(UInt8, String)),
      Document.new({} of String => CrystalClick::BinaryValue),
      present_document(kind, [] of Tuple(UInt8, String)),
      present_document(kind, [{9_u8, "four"}] of Tuple(UInt8, String)),
      present_document(kind, [{11_u8, "a"}, {12_u8, "bb"}] of Tuple(UInt8, String)),
      Document.new({} of String => CrystalClick::BinaryValue),
      present_document(kind, [] of Tuple(UInt8, String)),
      present_document(kind, [{0_u8, ""}] of Tuple(UInt8, String)),
    ] of Document
  end

  private def mark_granules(rows : Array(Document)) : Array(Array(Document))
    Array(Array(Document)).new(4) do |mark|
      [rows[mark * 2], rows[mark * 2 + 1]] of Document
    end
  end

  private def keys : Slice(UInt64)
    Slice(UInt64).new(8) { |index| (index + 1).to_u64 }
  end

  private def profile(string_profile : Int) : CrystalClick::BinaryBulkProfile
    case string_profile
    when 0 then CrystalClick::BinaryBulkProfile.single_stream
    when 1 then CrystalClick::BinaryBulkProfile.with_size_stream
    else        raise ArgumentError.new("W198 String profile must be 0 or 1")
    end
  end

  private def render_rows(marks : Array(Array(Document)), first_row : Int) : Array(JSON::Any)
    rows = [] of JSON::Any
    marks.each_with_index do |mark, mark_index|
      mark.each_with_index do |document, row_index|
        present = document.has_path?(PATH_NAME)
        type_name = ""
        value_hex = ""
        if present
          value = document.value_for(PATH_NAME)
          type_name = value.type.name
          value_hex = CrystalClick::BinaryValueCodec.encode(value).hexstring
        end
        rows << JSON::Any.new({
          "pk"           => JSON::Any.new((first_row + mark_index * 2 + row_index + 1).to_i64),
          "path_present" => JSON::Any.new(present),
          "type_name"    => JSON::Any.new(type_name),
          "value_hex"    => JSON::Any.new(value_hex),
        } of String => JSON::Any)
      end
    end
    rows
  end

  private def reader_record(part : String, kind : String, shared_version : Int, string_profile : Int, inner : CrystalClick::ObjectDocumentSchema) : JSON::Any
    reader = CrystalClick::ObjectColumnReader.open(part, "j", inner)
    marks = reader.mark_row_counts
    unless reader.row_count == 8_u64 && marks == EXPECTED_MARK_ROWS
      raise CrystalClick::CorruptPartError.new("W198 part does not have the fixed eight-row four-mark grid")
    end
    unless reader.ordinary_profile == profile(string_profile)
      raise CrystalClick::CorruptPartError.new("W198 ordinary String profile differs from its profile ID")
    end

    descriptor = CrystalClick::ObjectDocumentFileReader.inspect(
      part,
      "j",
      inner.typed_paths,
      reader.ordinary_profile,
      CrystalClick::BinaryBulkProfile.single_stream,
      true,
    )
    actual_shared_version = descriptor.plan.structures.object.shared_data_version
    unless actual_shared_version == shared_version.to_u64
      raise CrystalClick::CorruptPartError.new("W198 Object shared-data version differs from its profile ID")
    end

    full = reader.read_marks(0, marks.size)
    middle = reader.read_marks(1, 2)
    zero = reader.read_marks(marks.size, 0)
    JSON::Any.new({
      "source_declaration"      => JSON::Any.new(reader.source_declaration),
      "schema_declaration"      => JSON::Any.new(reader.schema_declaration),
      "row_count"               => JSON::Any.new(reader.row_count.to_i64),
      "mark_row_counts"         => JSON::Any.new(marks.map { |count| JSON::Any.new(count.to_i64) }),
      "physical_stream_names"   => JSON::Any.new(reader.physical_stream_names.map { |name| JSON::Any.new(name) }),
      "shared_data_version"     => JSON::Any.new(actual_shared_version.to_i64),
      "ordinary_string_profile" => JSON::Any.new(string_profile),
      "full_rows"               => JSON::Any.new(render_rows(full, 0)),
      "middle_rows"             => JSON::Any.new(render_rows(middle, 2)),
      "zero_rows"               => JSON::Any.new(render_rows(zero, 8)),
    } of String => JSON::Any)
  end

  private def write_library_part!(part : String, kind : String, version : Int, string_profile : Int, inner : CrystalClick::ObjectDocumentSchema) : Nil
    CrystalClick::WidePartWriter.write_uint64_object_pair(
      part,
      "pk",
      keys,
      "j",
      inner,
      plan(inner, version),
      mark_granules(documents(kind)),
      rows_per_mark: 2,
      profile: profile(string_profile),
    )
    nil
  end

  private def validate_part_path!(part : String, output_root : String, capture_root : String, generated : Bool) : Nil
    path = File.expand_path(part)
    if generated
      root = File.realpath(output_root)
      unless path.starts_with?(root + File::SEPARATOR) && !File.exists?(path) && !File.symlink?(path)
        raise ArgumentError.new("W198 library part destination is not a fresh descendant of output root")
      end
      ensure_generated_parent!(path, root)
      parent = File.realpath(File.dirname(path))
      unless parent == root || parent.starts_with?(root + File::SEPARATOR)
        raise ArgumentError.new("W198 library part parent escapes output root")
      end
    else
      root = File.realpath(capture_root)
      unless Dir.exists?(path) && !File.symlink?(path) && File.realpath(path) == path && path.starts_with?(root + File::SEPARATOR)
        raise ArgumentError.new("W198 stock part is absent, noncanonical, symlinked, or outside capture root")
      end
    end
  end

  private def ensure_generated_parent!(path : String, root : String) : Nil
    relative = path.byte_slice(root.bytesize + 1, path.bytesize - root.bytesize - 1)
    parent_relative = File.dirname(relative)
    return if parent_relative == "."

    current = root
    parent_relative.split(File::SEPARATOR).each do |component|
      next if component.empty? || component == "."
      if component == ".."
        raise ArgumentError.new("W198 library part parent contains traversal")
      end
      candidate = File.join(current, component)
      if File.symlink?(candidate)
        raise ArgumentError.new("W198 library part parent contains a symlink")
      elsif Dir.exists?(candidate)
        current = File.realpath(candidate)
      elsif File.exists?(candidate)
        raise ArgumentError.new("W198 library part parent component is not a directory")
      else
        Dir.mkdir(candidate)
        current = File.realpath(candidate)
      end
      unless current.starts_with?(root + File::SEPARATOR)
        raise ArgumentError.new("W198 library part parent escapes output root")
      end
    end
  end

  private def expected_kind(id : String) : String
    id.starts_with?("nested_") ? "nested" : "array_tuple"
  end

  private def expected_version(id : String) : Int
    id.includes?("_v2_") ? 2 : 3
  end

  private def expected_string_profile(id : String) : Int
    id.ends_with?("_s0") ? 0 : 1
  end

  private def process_profile(profile_input : JSON::Any, output_root : String, capture_root : String) : JSON::Any
    id = profile_input["profile_id"].as_s
    kind = profile_input["kind"].as_s
    version = profile_input["shared_version"].as_i
    string_profile = profile_input["string_profile"].as_i
    source_part = profile_input["source_part"].as_s
    library_part = profile_input["library_part"].as_s
    profile_capture_root = profile_input["capture_root"].as_s

    unless kind == expected_kind(id) && version == expected_version(id) && string_profile == expected_string_profile(id)
      raise ArgumentError.new("W198 profile metadata differs from its fixed profile ID")
    end
    unless profile_capture_root == capture_root
      raise ArgumentError.new("W198 profile capture root differs from the authenticated top-level root")
    end
    validate_part_path!(source_part, output_root, capture_root, false)
    validate_part_path!(library_part, output_root, capture_root, true)

    inner = schema
    write_library_part!(library_part, kind, version, string_profile, inner)
    source = reader_record(source_part, kind, version, string_profile, inner)
    library = reader_record(library_part, kind, version, string_profile, inner)
    JSON::Any.new({
      "profile_id"        => JSON::Any.new(id),
      "kind"              => JSON::Any.new(kind),
      "shared_version"    => JSON::Any.new(version),
      "string_profile"    => JSON::Any.new(string_profile),
      "library_part_path" => JSON::Any.new(File.expand_path(library_part)),
      "source"            => source,
      "library"           => library,
    } of String => JSON::Any)
  end

  private def run(args : Array(String)) : Nil
    unless args.size == 2
      raise ArgumentError.new("usage: check_object_shared_nested_parts_w198.cr INPUT.json OUTPUT_ROOT")
    end
    input_path = File.expand_path(args[0])
    output_root = File.expand_path(args[1])
    unless Dir.exists?(output_root) && !File.symlink?(output_root) && File.realpath(output_root) == output_root
      raise ArgumentError.new("W198 output root must be a canonical existing directory")
    end
    unless File.file?(input_path) && !File.symlink?(input_path) && input_path.starts_with?(output_root + File::SEPARATOR)
      raise ArgumentError.new("W198 helper input must be a plain file below output root")
    end

    input = JSON.parse(File.read(input_path))
    unless input.as_h.keys.sort == ["capture_root", "format", "profiles"] &&
           input["format"].as_s == "object_shared_nested_parts_w198_input_v1"
      raise ArgumentError.new("W198 input format mismatch")
    end
    capture_root = input["capture_root"].as_s
    unless Dir.exists?(capture_root) && !File.symlink?(capture_root) && File.realpath(capture_root) == capture_root
      raise ArgumentError.new("W198 capture root must be canonical and non-symlinked")
    end
    profiles = input["profiles"].as_a
    ids = profiles.map { |item| item["profile_id"].as_s }
    unless ids == PROFILE_IDS
      raise ArgumentError.new("W198 profile roster differs from the exact eight-profile matrix")
    end
    profiles.each do |item|
      unless item.as_h.keys.sort == ["capture_root", "kind", "library_part", "profile_id", "shared_version", "source_part", "string_profile"]
        raise ArgumentError.new("W198 profile input keys differ")
      end
    end

    output_profiles = profiles.map { |item| process_profile(item, output_root, capture_root) }
    puts JSON::Any.new({
      "format"      => JSON::Any.new("object_shared_nested_parts_w198_helper_v1"),
      "profile_ids" => JSON::Any.new(PROFILE_IDS.map { |id| JSON::Any.new(id) }),
      "profiles"    => JSON::Any.new(output_profiles),
    }).to_json
  rescue ex : Exception
    STDERR.puts "W198 Crystal helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  def main(args : Array(String)) : Nil
    run(args)
  end
end

CheckObjectSharedNestedPartsW198.main(ARGV)
