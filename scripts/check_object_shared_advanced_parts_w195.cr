require "../src/crystal_click"
require "json"

module CheckObjectSharedAdvancedPartsW195
  extend self

  ROOT_TYPE   = "JSON(max_dynamic_types=0, max_dynamic_paths=0, t UInt8)"
  ARRAY_TYPE  = "Array(#{ROOT_TYPE})"
  PROFILE_IDS = [
    "root_advanced_v2", "root_advanced_chunked_v3",
    "array_advanced_v2", "array_advanced_chunked_v3",
    "empty_root_advanced_v2", "empty_root_advanced_chunked_v3",
    "empty_array_advanced_v2", "empty_array_advanced_chunked_v3",
  ]

  alias Document = CrystalClick::ObjectDocument

  private def schema : CrystalClick::ObjectDocumentSchema
    CrystalClick::ObjectDocumentSchema.new(
      {"t" => CrystalClick::BinaryDataType.primitive("UInt8")},
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
    )
  end

  private def plan(inner : CrystalClick::ObjectDocumentSchema, version : UInt64, buckets : UInt64) : CrystalClick::ObjectDocumentPlan
    structure = CrystalClick::ObjectStructure.new(
      [] of String,
      shared_data_version: version,
      bucket_count: buckets,
    )
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      structure,
      {} of String => CrystalClick::DynamicStructure,
    )
    CrystalClick::ObjectDocumentPlan.new(structures, inner.typed_paths)
  end

  private def document(t : UInt8, shared : Hash(String, String)) : Document
    values = {"t" => CrystalClick::BinaryValue.fixed(
      CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[t]
    )} of String => CrystalClick::BinaryValue
    shared.each { |path, value| values[path] = CrystalClick::BinaryValue.string(value) }
    Document.new(values)
  end

  # These literals intentionally mirror the finite W191 stock corpus without
  # deriving library input from any reader result.
  private def root_rows(empty : Bool) : Array(Document)
    rows = [] of Document
    1_u8.upto(8_u8) do |pk|
      shared = {} of String => String
      unless empty
        case pk
        when 1_u8 then shared["alpha"] = "r-alpha-1"
        when 2_u8
          shared["aa"] = "r-aa-2"
          shared["beta"] = "r-beta-2"
        when 3_u8 then shared["beta"] = "r-beta-3"
        when 4_u8
          shared["alpha"] = "r-alpha-4"
          shared["aa"] = "r-aa-4"
        when 5_u8
          shared["aa"] = "r-aa-5"
          shared["beta"] = "r-beta-5"
        when 6_u8 then shared["alpha"] = "r-alpha-6"
        when 7_u8 then shared["beta"] = "r-beta-7"
        when 8_u8
          shared["alpha"] = "r-alpha-8"
          shared["aa"] = "r-aa-8"
          shared["beta"] = "r-beta-8"
        end
      end
      rows << document(pk, shared)
    end
    rows
  end

  private def array_rows(empty : Bool) : Array(Array(Document))
    rows = Array(Array(Document)).new(8) { [] of Document }
    return rows if empty

    rows[3] = [document(41_u8, {"alpha" => "a-alpha-41"} of String => String)]
    rows[4] = [
      document(51_u8, {"aa" => "a-aa-51"} of String => String),
      document(52_u8, {"beta" => "a-beta-52"} of String => String),
    ]
    rows[5] = [document(61_u8, {"alpha" => "a-alpha-61", "beta" => "a-beta-61"} of String => String)]
    rows
  end

  private def keys : Slice(UInt64)
    Slice(UInt64).new(8) { |index| (index + 1).to_u64 }
  end

  private def root_marks(rows : Array(Document)) : Array(Array(Document))
    Array(Array(Document)).new(4) do |mark|
      [rows[mark * 2], rows[mark * 2 + 1]] of Document
    end
  end

  private def array_marks(rows : Array(Array(Document))) : Array(Array(CrystalClick::StorageColumnValue))
    parents = rows.map do |documents|
      children = documents.map { |item| CrystalClick::StorageColumnValue.object_document(item) }
      CrystalClick::StorageColumnValue.array(children)
    end
    Array(Array(CrystalClick::StorageColumnValue)).new(4) do |mark|
      [parents[mark * 2], parents[mark * 2 + 1]] of CrystalClick::StorageColumnValue
    end
  end

  private def render_document(document : Document) : JSON::Any
    fields = {} of String => JSON::Any
    document.paths.each do |path|
      value = document.value_for(path)
      fields[path] = if value.is_null?
                       JSON::Any.new(nil)
                     elsif path == "t"
                       JSON::Any.new(value.bytes[0].to_i64)
                     else
                       JSON::Any.new(value.as_string)
                     end
    end
    JSON::Any.new(fields)
  end

  private def render_documents(documents : Array(Document)) : Array(JSON::Any)
    documents.map { |item| render_document(item) }
  end

  private def render_recursive(value : CrystalClick::StorageColumnValue) : JSON::Any
    if value.object?
      render_document(value.object_document)
    elsif value.array?
      JSON::Any.new(value.array_values.map { |child| render_recursive(child) })
    else
      raise CrystalClick::CorruptPartError.new("W195 recursive reader returned a non-JSON structural value")
    end
  end

  private def reader_record(part : String, column : String, kind : String, inner : CrystalClick::ObjectDocumentSchema) : Hash(String, JSON::Any)
    if kind == "root"
      reader = CrystalClick::ObjectColumnReader.open(part, column, inner)
      marks = reader.mark_row_counts
      full = reader.read_marks(0, marks.size)
      middle = reader.read_marks(1, 2)
      zero = reader.read_marks(marks.size, 0)
      {
        "source_declaration"      => JSON::Any.new(reader.source_declaration),
        "schema_declaration"      => JSON::Any.new(reader.schema_declaration),
        "row_count"               => JSON::Any.new(reader.row_count.to_i64),
        "mark_row_counts"         => JSON::Any.new(marks.map { |count| JSON::Any.new(count.to_i64) }),
        "physical_stream_names"   => JSON::Any.new(reader.physical_stream_names.map { |name| JSON::Any.new(name) }),
        "selected_checksum_names" => JSON::Any.new(reader.selected_checksum_names.map { |name| JSON::Any.new(name) }),
        "logical_read_bytes"      => JSON::Any.new(reader.logical_read_bytes.to_i64),
        "full_rows"               => JSON::Any.new(full.flat_map { |mark| render_documents(mark) }),
        "middle_rows"             => JSON::Any.new(middle.flat_map { |mark| render_documents(mark) }),
        "zero_rows"               => JSON::Any.new(zero.flat_map { |mark| render_documents(mark) }),
      } of String => JSON::Any
    else
      recursive_reader_record(part, column, inner)
    end
  end

  private def recursive_reader_record(part : String, column : String, inner : CrystalClick::ObjectDocumentSchema) : Hash(String, JSON::Any)
    schema = CrystalClick::StorageColumnSchema.parse("Array(#{inner.declaration})")
    reader = CrystalClick::RecursiveStorageColumnReader.open(part, column, schema)
    marks = reader.mark_row_counts
    full = reader.read_marks(0, marks.size)
    middle = reader.read_marks(1, 2)
    zero = reader.read_marks(marks.size, 0)
    full_rows = full.flat_map { |mark| mark.map { |row| render_recursive(row) } }
    middle_rows = middle.flat_map { |mark| mark.map { |row| render_recursive(row) } }
    zero_rows = zero.flat_map { |mark| mark.map { |row| render_recursive(row) } }
    {
      "source_declaration"      => JSON::Any.new(reader.source_declaration),
      "schema_declaration"      => JSON::Any.new(reader.schema_declaration),
      "row_count"               => JSON::Any.new(reader.row_count.to_i64),
      "mark_row_counts"         => JSON::Any.new(marks.map { |count| JSON::Any.new(count.to_i64) }),
      "physical_stream_names"   => JSON::Any.new(reader.physical_stream_names.map { |name| JSON::Any.new(name) }),
      "selected_checksum_names" => JSON::Any.new(reader.selected_checksum_names.map { |name| JSON::Any.new(name) }),
      "logical_read_bytes"      => JSON::Any.new(reader.logical_read_bytes.to_i64),
      "full_rows"               => JSON::Any.new(full_rows),
      "middle_rows"             => JSON::Any.new(middle_rows),
      "zero_rows"               => JSON::Any.new(zero_rows),
    } of String => JSON::Any
  end

  private def table_rows(part : String, column : String, kind : String, schema_declaration : String, start : UInt64?, max_rows : Int) : Array(JSON::Any)
    table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", column])
    rows = [] of JSON::Any
    consume = ->(batch : CrystalClick::WidePartTableBatch) {
      if kind == "root"
        batch.object_documents_for(column).each { |document| rows << render_document(document) }
      elsif kind == "array"
        batch.array_object_documents_for(column).each do |documents|
          rows << JSON::Any.new(render_documents(documents))
        end
      else
        batch.recursive_values_for(column).each { |value| rows << render_recursive(value) }
      end
      nil
    }
    if start
      table.scan_typed_window(start, max_rows: max_rows, &consume)
    elsif kind == "root"
      table.scan_typed(batch_rows: 2, &consume)
    else
      table.scan_typed(batch_rows: 2, &consume)
    end
    rows
  end

  private def table_record(part : String, column : String, kind : String, declaration : String) : Hash(String, JSON::Any)
    {
      "full_rows"   => JSON::Any.new(table_rows(part, column, kind, declaration, nil, 8)),
      "middle_rows" => JSON::Any.new(table_rows(part, column, kind, declaration, 2_u64, 4)),
      "zero_rows"   => JSON::Any.new(table_rows(part, column, kind, declaration, 8_u64, 2)),
    } of String => JSON::Any
  end

  private def write_library_part(part : String, column : String, kind : String, empty : Bool, version : UInt64, buckets : UInt64, inner : CrystalClick::ObjectDocumentSchema) : Nil
    object_plan = plan(inner, version, buckets)
    if kind == "root"
      rows = root_rows(empty)
      CrystalClick::WidePartWriter.write_uint64_object_pair(
        part, "pk", keys, column, inner, object_plan, root_marks(rows), rows_per_mark: 2)
    else
      rows = array_rows(empty)
      schema = CrystalClick::StorageColumnSchema.parse("Array(#{inner.declaration})")
      object_plans = {"root/array[0]" => object_plan}
      CrystalClick::WidePartWriter.write_uint64_recursive_pair(
        part,
        "pk",
        keys,
        column,
        schema,
        object_plans,
        array_marks(rows),
        rows_per_mark: 2,
      )
    end
    nil
  end

  private def validate_part_path!(part : String, output_root : String, capture_root : String, generated : Bool) : Nil
    path = File.expand_path(part)
    if generated
      root = File.realpath(output_root)
      unless path.starts_with?(root + File::SEPARATOR) && !File.exists?(path) && !File.symlink?(path)
        raise ArgumentError.new("W195 library part destination is not a fresh descendant of output root")
      end
      parent = File.realpath(File.dirname(path))
      unless parent.starts_with?(root + File::SEPARATOR)
        raise ArgumentError.new("W195 library part parent escapes output root")
      end
    else
      root = File.realpath(capture_root)
      unless Dir.exists?(path) && !File.symlink?(path) && File.realpath(path) == path && path.starts_with?(root + File::SEPARATOR)
        raise ArgumentError.new("W195 stock part is absent, noncanonical, symlinked, or outside capture root")
      end
    end
  end

  private def process_profile(profile : JSON::Any, output_root : String) : JSON::Any
    id = profile["profile_id"].as_s
    kind = profile["kind"].as_s
    version = profile["shared_version"].as_i.to_u64
    buckets = profile["bucket_count"].as_i.to_u64
    empty = profile["empty"].as_bool
    source_part = profile["source_part"].as_s
    library_part = profile["library_part"].as_s
    column = kind == "array" ? "a" : "j"
    capture_root = profile["capture_root"].as_s
    validate_part_path!(source_part, output_root, capture_root, false)
    validate_part_path!(library_part, output_root, capture_root, true)
    inner = schema
    write_library_part(library_part, column, kind, empty, version, buckets, inner)
    declaration = kind == "array" ? "Array(#{inner.declaration})" : inner.declaration
    source_direct = reader_record(source_part, column, kind, inner)
    library_direct = reader_record(library_part, column, kind, inner)
    source_table = table_record(source_part, column, kind, declaration)
    library_table = table_record(library_part, column, kind, declaration)
    JSON::Any.new({
      "profile_id"        => JSON::Any.new(id),
      "kind"              => JSON::Any.new(kind),
      "shared_version"    => JSON::Any.new(version.to_i64),
      "bucket_count"      => JSON::Any.new(buckets.to_i64),
      "declaration"       => JSON::Any.new(declaration),
      "library_part_path" => JSON::Any.new(File.expand_path(library_part)),
      "source_direct"     => JSON::Any.new(source_direct),
      "source_table"      => JSON::Any.new(source_table),
      "library_direct"    => JSON::Any.new(library_direct),
      "library_table"     => JSON::Any.new(library_table),
    })
  end

  private def run(args : Array(String)) : Nil
    raise ArgumentError.new("usage: check_object_shared_advanced_parts_w195.cr INPUT.json OUTPUT_ROOT") unless args.size == 2
    input_path = File.expand_path(args[0])
    output_root = File.expand_path(args[1])
    unless Dir.exists?(output_root) && !File.symlink?(output_root) && File.realpath(output_root) == output_root
      raise ArgumentError.new("W195 output root must be a canonical existing directory")
    end
    unless File.file?(input_path) && !File.symlink?(input_path) && input_path.starts_with?(output_root + File::SEPARATOR)
      raise ArgumentError.new("W195 helper input must be a plain file below output root")
    end
    input = JSON.parse(File.read(input_path))
    unless input.as_h.keys.sort == ["capture_root", "format", "profiles"] &&
           input["format"].as_s == "object_shared_advanced_parts_w195_input_v1"
      raise ArgumentError.new("W195 input format mismatch")
    end
    capture_root = input["capture_root"].as_s
    unless Dir.exists?(capture_root) && !File.symlink?(capture_root) && File.realpath(capture_root) == capture_root
      raise ArgumentError.new("W195 capture root must be canonical and non-symlinked")
    end
    profiles = input["profiles"].as_a
    ids = profiles.map { |profile| profile["profile_id"].as_s }
    unless ids == PROFILE_IDS
      raise ArgumentError.new("W195 input profile roster differs from the eight admitted W191 profiles")
    end
    profiles.each do |profile|
      unless profile.as_h.keys.sort == ["bucket_count", "capture_root", "empty", "kind", "library_part", "profile_id", "shared_version", "source_part"]
        raise ArgumentError.new("W195 profile input keys differ")
      end
      kind = profile["kind"].as_s
      shared_version = profile["shared_version"].as_i
      bucket_count = profile["bucket_count"].as_i
      unless profile["capture_root"].as_s == capture_root && (kind == "root" || kind == "array") &&
             (shared_version == 2 || shared_version == 3) && (bucket_count == 1 || bucket_count == 2)
        raise ArgumentError.new("W195 profile metadata is outside the bounded W191 fixture")
      end
      profile_id = profile["profile_id"].as_s
      expected_empty = profile_id.starts_with?("empty_")
      unless profile["empty"].as_bool == expected_empty
        raise ArgumentError.new("W195 empty-control identity does not match profile id")
      end
      expected_version = profile_id.ends_with?("_v2") ? 2 : 3
      expected_buckets = expected_empty ? 1 : 2
      unless profile["shared_version"].as_i == expected_version && profile["bucket_count"].as_i == expected_buckets
        raise ArgumentError.new("W195 profile version/bucket metadata differs from its fixed id")
      end
      validate_part_path!(profile["source_part"].as_s, output_root, capture_root, false)
      validate_part_path!(profile["library_part"].as_s, output_root, capture_root, true)
    end
    output_profiles = profiles.map { |profile| process_profile(profile, output_root) }
    puts JSON::Any.new({
      "format"      => JSON::Any.new("object_shared_advanced_parts_w195_helper_v1"),
      "profile_ids" => JSON::Any.new(PROFILE_IDS.map { |id| JSON::Any.new(id) }),
      "profiles"    => JSON::Any.new(output_profiles),
    }).to_json
  rescue ex : Exception
    STDERR.puts "W195 Crystal helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  def main(args : Array(String)) : Nil
    run(args)
  end
end

CheckObjectSharedAdvancedPartsW195.main(ARGV)
