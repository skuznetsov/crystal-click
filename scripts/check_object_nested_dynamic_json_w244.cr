require "../src/crystal_click"
require "digest/sha256"
require "json"

module CheckObjectNestedDynamicJSONW244
  extend self

  FORMAT_INPUT         = "object_nested_dynamic_json_w244_input_v1"
  FORMAT_OUTPUT        = "object_nested_dynamic_json_w244_helper_v1"
  ROW_COUNT            = 4
  MARK_ROWS            = [2_u64, 2_u64]
  MAX_PART_FILE_BYTES  = 16_i64 * 1024 * 1024
  MAX_PART_TOTAL_BYTES = 64_i64 * 1024 * 1024

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W244 helper: #{message}") unless condition
  end

  private def json(value : String) : JSON::Any
    JSON::Any.new(value)
  end

  private def json(value : Int64) : JSON::Any
    JSON::Any.new(value)
  end

  private def json_strings(values : Array(String)) : JSON::Any
    JSON::Any.new(values.map { |value| json(value) })
  end

  private def uint8_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt8")
  end

  private def int64_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("Int64")
  end

  private def string_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("String")
  end

  private def outer_json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 1,
      max_dynamic_types: 2,
      typed_paths: {"v" => uint8_type} of String => CrystalClick::BinaryDataType,
    )
  end

  private def inner_json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {"v" => int64_type} of String => CrystalClick::BinaryDataType,
    )
  end

  private def nested_actual_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.tuple([inner_json_type, uint8_type] of CrystalClick::BinaryDataType)
  end

  private def nested_dynamic_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.dynamic(max_types: 1)
  end

  private def outer_actual_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.tuple([
      outer_json_type,
      CrystalClick::BinaryDataType.array(nested_dynamic_type),
    ] of CrystalClick::BinaryDataType)
  end

  private def json_value(type : CrystalClick::BinaryDataType, value : CrystalClick::BinaryValue) : CrystalClick::BinaryValue
    row = CrystalClick::BinaryJsonRow.new(
      type,
      [{"v", value}] of Tuple(String, CrystalClick::BinaryValue),
    )
    CrystalClick::BinaryValue.json(type, row)
  end

  private def nested_value : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.tuple(
      nested_actual_type,
      [
        json_value(inner_json_type, CrystalClick::BinaryValue.int64(7_i64)),
        CrystalClick::BinaryValue.fixed(uint8_type, Bytes[9_u8]),
      ] of CrystalClick::BinaryValue,
    )
  end

  private def dynamic_value(value : CrystalClick::BinaryValue? = nil) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.dynamic(nested_dynamic_type, value)
  end

  private def outer_value(items : Array(CrystalClick::BinaryValue)) : CrystalClick::BinaryValue
    actual = outer_actual_type
    CrystalClick::BinaryValue.tuple(
      actual,
      [
        json_value(outer_json_type, CrystalClick::BinaryValue.fixed(uint8_type, Bytes[7_u8])),
        CrystalClick::BinaryValue.array(actual.child_at(1), items),
      ] of CrystalClick::BinaryValue,
    )
  end

  private def fixture_documents : Array(CrystalClick::ObjectDocument)
    spill = CrystalClick::BinaryValue.string("spill")
    ordinary = CrystalClick::BinaryValue.string("ordinary")
    [
      CrystalClick::ObjectDocument.new({
        "payload" => outer_value([
          dynamic_value(nested_value),
          dynamic_value(spill),
          dynamic_value,
        ] of CrystalClick::BinaryValue),
      } of String => CrystalClick::BinaryValue),
      CrystalClick::ObjectDocument.new({
        "payload" => outer_value([] of CrystalClick::BinaryValue),
      } of String => CrystalClick::BinaryValue),
      CrystalClick::ObjectDocument.new({
        "payload" => outer_value([
          dynamic_value(ordinary),
          dynamic_value,
        ] of CrystalClick::BinaryValue),
      } of String => CrystalClick::BinaryValue),
      CrystalClick::ObjectDocument.new({
        "payload" => outer_value([] of CrystalClick::BinaryValue),
      } of String => CrystalClick::BinaryValue),
    ] of CrystalClick::ObjectDocument
  end

  private def child_plan(json_type : CrystalClick::BinaryDataType) : CrystalClick::ObjectDocumentPlan
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new([] of String, shared_data_version: 2_u64, bucket_count: 1_u64),
      {} of String => CrystalClick::DynamicStructure,
    )
    CrystalClick::ObjectDocumentPlan.new(
      structures,
      json_type.json_type.not_nil!.typed_paths,
    )
  end

  private def write_plan : Tuple(CrystalClick::ObjectDocumentPlan, CrystalClick::ObjectSharedAdvancedJsonWritePolicy)
    outer_actual = outer_actual_type
    nested_actual = nested_actual_type
    outer_prepared = CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
      outer_actual,
      [{[0_i32] of Int32, child_plan(outer_json_type)}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
    )
    nested_prepared = CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
      nested_actual,
      [{[0_i32] of Int32, child_plan(inner_json_type)}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
    )
    policy = CrystalClick::ObjectSharedAdvancedJsonWritePolicy.new(
      [outer_prepared, nested_prepared] of CrystalClick::ObjectSharedAdvancedJsonActualPlan,
      16,
    )
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(
        [] of String,
        shared_data_version: 2_u64,
        bucket_count: 1_u64,
      ),
      {} of String => CrystalClick::DynamicStructure,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(structures, {} of String => CrystalClick::BinaryDataType)
    {plan, policy}
  end

  private def render_value(value : CrystalClick::BinaryValue, depth : Int32 = 0) : JSON::Any
    require!(depth <= 16, "fixture render exceeds its depth bound")
    return JSON::Any.new(nil) if value.is_null?
    case value.type.tag
    when CrystalClick::BinaryDataType::TAG_STRING
      json(value.as_string)
    when CrystalClick::BinaryDataType::TAG_UINT8
      json(value.byte_at(0).to_i64)
    when CrystalClick::BinaryDataType::TAG_INT64
      json(value.as_int64)
    when CrystalClick::BinaryDataType::TAG_ARRAY,
         CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE,
         CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
      JSON::Any.new(Array(JSON::Any).new(value.child_count) { |index| render_value(value.child_at(index), depth + 1) })
    when CrystalClick::BinaryDataType::TAG_JSON
      row = value.json_row
      fields = {} of String => JSON::Any
      row.path_count.times do |index|
        path = row.path_at(index)
        fields[path] = render_value(row.value_for(path).not_nil!, depth + 1)
      end
      JSON::Any.new(fields)
    when CrystalClick::BinaryDataType::TAG_DYNAMIC
      require!(value.child_count <= 1, "fixture Dynamic has multiple children")
      value.child_count == 0 ? JSON::Any.new(nil) : render_value(value.child_at(0), depth + 1)
    else
      raise CrystalClick::CorruptPartError.new("W244 helper: unrostered fixture type #{value.type.name}")
    end
  end

  private def render_documents(marks : Array(Array(CrystalClick::ObjectDocument)), first_mark : Int32 = 0) : Array(JSON::Any)
    output = [] of JSON::Any
    marks.each_with_index do |mark, mark_index|
      mark.each_with_index do |document, row_index|
        fields = {} of String => JSON::Any
        document.paths.each { |path| fields[path] = render_value(document.value_for(path)) }
        output << JSON::Any.new({
          "pk"  => json((first_mark * 2 + mark_index * 2 + row_index + 1).to_i64),
          "doc" => JSON::Any.new(fields),
        } of String => JSON::Any)
      end
    end
    output
  end

  private def nested_witnesses(marks : Array(Array(CrystalClick::ObjectDocument))) : Array(JSON::Any)
    output = [] of JSON::Any
    marks.each_with_index do |mark, mark_index|
      mark.each_with_index do |document, row_index|
        pk = mark_index * 2 + row_index + 1
        payload = document.value_for("payload")
        require!(payload.type == outer_actual_type && payload.child_count == 2, "outer Tuple differs at row #{pk}")
        parent_json = payload.child_at(0)
        parent_row = parent_json.json_row
        parent_value = parent_row.value_for("v").not_nil!
        require!(parent_value.type == uint8_type && parent_value.byte_at(0) == 7_u8, "outer JSON v differs at row #{pk}")
        array = payload.child_at(1)
        require!(array.type == outer_actual_type.child_at(1), "inner array descriptor differs at row #{pk}")
        items = [] of JSON::Any
        array.child_count.times do |index|
          dynamic = array.child_at(index)
          require!(dynamic.type == nested_dynamic_type && dynamic.child_count <= 1, "nested Dynamic shape differs at row #{pk}")
          if dynamic.child_count == 0
            items << JSON::Any.new({
              "index" => json(index.to_i64), "type" => json("NULL"), "is_null" => JSON::Any.new(true),
            } of String => JSON::Any)
          else
            actual = dynamic.child_at(0)
            if actual.type == nested_actual_type
              actual_json = actual.child_at(0)
              actual_row = actual_json.json_row
              actual_v = actual_row.value_for("v").not_nil!
              scalar = actual.child_at(1)
              require!(actual_v.type == int64_type && actual_v.as_int64 == 7_i64 &&
                       scalar.type == uint8_type && scalar.byte_at(0) == 9_u8,
                "nested Tuple(JSON, UInt8) value differs at row #{pk}")
              items << JSON::Any.new({
                "index"                 => json(index.to_i64),
                "type"                  => json(actual.type.name),
                "is_null"               => JSON::Any.new(false),
                "json_type"             => json(actual_json.type.name),
                "json_paths_with_types" => JSON::Any.new({"v" => json(actual_v.type.name)} of String => JSON::Any),
                "v_type"                => json(actual_v.type.name),
                "v"                     => json(actual_v.as_int64),
                "scalar_type"           => json(scalar.type.name),
                "scalar"                => json(scalar.byte_at(0).to_i64),
              } of String => JSON::Any)
            else
              require!(actual.type == string_type, "nested non-JSON sibling is not String at row #{pk}")
              items << JSON::Any.new({
                "index"   => json(index.to_i64),
                "type"    => json(actual.type.name),
                "is_null" => JSON::Any.new(false),
                "value"   => json(actual.as_string),
              } of String => JSON::Any)
            end
          end
        end
        output << JSON::Any.new({
          "pk"                          => json(pk.to_i64),
          "outer_actual_type"           => json(payload.type.name),
          "outer_json_type"             => json(parent_json.type.name),
          "outer_json_paths_with_types" => JSON::Any.new({"v" => json(parent_value.type.name)} of String => JSON::Any),
          "outer_v"                     => json(parent_value.byte_at(0).to_i64),
          "inner_array_type"            => json(array.type.name),
          "inner_items"                 => JSON::Any.new(items),
        } of String => JSON::Any)
      end
    end
    output
  end

  private def physical_inventory(path : String) : JSON::Any
    require!(Dir.exists?(path) && !File.symlink?(path), "part directory is missing or symlinked")
    names = Dir.children(path).sort
    require!(names.includes?("checksums.txt"), "part checksums are missing")
    checksums = CrystalClick::PartChecksums.open(path)
    physical_names = names.reject { |name| ["checksums.txt", "columns.txt", "columns_substreams.txt", "default_compression_codec.txt", "metadata_version.txt", "txn_version.txt"].includes?(name) }
    require!(physical_names.sort == checksums.entries.keys.sort, "physical checksum roster differs")
    total = 0_i64
    JSON::Any.new(names.map do |name|
      require!(/\A[a-zA-Z0-9_.-]+\z/.matches?(name), "unsafe part file name")
      file = File.join(path, name)
      require!(File.file?(file) && !File.symlink?(file), "part entry is not a regular file")
      size = File.size(file)
      require!(size <= MAX_PART_FILE_BYTES, "part file exceeds size bound")
      bytes = File.read(file)
      require!(bytes.bytesize.to_i64 == size, "part file changed while reading")
      total += size
      require!(total <= MAX_PART_TOTAL_BYTES, "part exceeds total size bound")
      JSON::Any.new({"name" => json(name), "size" => json(size), "sha256" => json(Digest::SHA256.hexdigest(bytes))} of String => JSON::Any)
    end)
  end

  private def read_part(path : String) : JSON::Any
    schema = CrystalClick::ObjectDocumentSchema.new({} of String => CrystalClick::BinaryDataType, max_dynamic_paths: 0)
    reader = CrystalClick::ObjectColumnReader.open(path, "doc", schema)
    require!(reader.row_count == ROW_COUNT.to_u64 && reader.mark_row_counts == MARK_ROWS, "Object row/mark grid differs")
    descriptor = CrystalClick::ObjectDocumentFileReader.inspect(
      path,
      "doc",
      schema.typed_paths,
      reader.ordinary_profile,
      CrystalClick::BinaryBulkProfile.single_stream,
      true,
    )
    require!(descriptor.plan.structures.object.shared_data_version == 2_u64, "shared serialization version is not 2")
    require!(descriptor.plan.structures.object.bucket_count == 1_u64, "advanced_s0 bucket count is not 1")
    full_marks = CrystalClick::ObjectColumnReader.open(path, "doc", schema).read_marks(0, MARK_ROWS.size)
    path_marks = CrystalClick::ObjectColumnReader.open(path, "doc", schema).read_shared_path_marks("payload", 0, MARK_ROWS.size)
    full_rows = render_documents(full_marks)
    require!(full_rows.size == ROW_COUNT, "full Object row count differs")
    direct_rows = [] of JSON::Any
    path_marks.each_with_index do |mark, mark_index|
      mark.each_with_index do |value, row_index|
        pk = mark_index * 2 + row_index + 1
        require!(value.type.tag == CrystalClick::BinaryDataType::TAG_DYNAMIC, "selected payload wrapper is not Dynamic")
        require!(value.child_count == 1 && value.child_at(0).type == outer_actual_type, "selected outer actual differs")
        direct_rows << JSON::Any.new({"pk" => json(pk.to_i64), "type" => json(value.child_at(0).type.name), "value" => render_value(value.child_at(0))} of String => JSON::Any)
      end
    end
    require!(direct_rows.size == ROW_COUNT, "selected payload row count differs")

    windows = [] of JSON::Any
    [{"first", 0, 1}, {"last", 1, 1}, {"zero_count_end", 2, 0}].each do |window, first_mark, count|
      whole = CrystalClick::ObjectColumnReader.open(path, "doc", schema).read_marks(first_mark, count)
      selected = CrystalClick::ObjectColumnReader.open(path, "doc", schema).read_shared_path_marks("payload", first_mark, count)
      expected_counts = Array(UInt64).new(count) { |offset| MARK_ROWS[first_mark + offset] }
      actual_counts = whole.map { |rows| rows.size.to_u64 }
      path_counts = selected.map { |rows| rows.size.to_u64 }
      require!(actual_counts == expected_counts && path_counts == expected_counts, "#{window} bounded mark rows differ")
      first_pk = first_mark * 2 + 1
      windows << JSON::Any.new({
        "window"           => json(window),
        "first_mark"       => json(first_mark.to_i64),
        "mark_count"       => json(count.to_i64),
        "mark_row_counts"  => JSON::Any.new(actual_counts.map { |n| json(n.to_i64) }),
        "full_rows"        => JSON::Any.new(render_documents(whole, first_mark)),
        "payload_first_pk" => count == 0 ? JSON::Any.new(nil) : json(first_pk.to_i64),
        "payload_rows"     => json(path_counts.sum.to_i64),
      } of String => JSON::Any)
    end

    JSON::Any.new({
      "path"                    => json(File.realpath(path)),
      "schema_declaration"      => json(reader.source_declaration),
      "columns_text"            => json(File.read(File.join(path, "columns.txt"))),
      "count_text"              => json(File.read(File.join(path, "count.txt")).strip),
      "count"                   => json(reader.row_count.to_i64),
      "shared_version"          => json(descriptor.plan.structures.object.shared_data_version.to_i64),
      "bucket_count"            => json(descriptor.plan.structures.object.bucket_count.to_i64),
      "mark_row_counts"         => JSON::Any.new(reader.mark_row_counts.map { |n| json(n.to_i64) }),
      "physical_file_inventory" => physical_inventory(path),
      "full_rows"               => JSON::Any.new(full_rows),
      "payload_rows"            => JSON::Any.new(direct_rows),
      "nested_type_witnesses"   => JSON::Any.new(nested_witnesses(full_marks)),
      "bounded_windows"         => JSON::Any.new(windows),
      "outer_actual_type"       => json(outer_actual_type.name),
      "nested_actual_type"      => json(nested_actual_type.name),
      "nested_dynamic_type"     => json(nested_dynamic_type.name),
      "nested_site"             => json("root.arm.1.field.1.elements"),
      "nested_json_type"        => json(inner_json_type.name),
    } of String => JSON::Any)
  end

  private def validate_input!(input : JSON::Any) : Int32
    hash = input.as_h
    require!(hash.keys.sort == ["format", "frame_bytes"], "input key set differs")
    require!(hash["format"].as_s == FORMAT_INPUT, "input format differs")
    frame_bytes = hash["frame_bytes"].as_i
    require!(frame_bytes == 32, "only the bounded frame_bytes=32 fixture is admitted")
    frame_bytes.to_i32
  end

  private def canonical_directory(path : String, label : String) : String
    expanded = File.expand_path(path)
    require!(Dir.exists?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded,
      "#{label} must be an existing canonical non-symlink directory")
    expanded
  end

  def run(args : Array(String)) : Nil
    unless args.size == 2
      raise ArgumentError.new("usage: check_object_nested_dynamic_json_w244.cr INPUT_JSON OUTPUT_ROOT")
    end
    input_path = File.expand_path(args[0])
    output_root = canonical_directory(args[1], "output root")
    require!(File.file?(input_path) && !File.symlink?(input_path), "input must be a regular non-symlink file")
    input_bytes = File.read(input_path)
    require!(input_bytes.bytesize <= 1_048_576, "input exceeds size bound")
    frame_bytes = validate_input!(JSON.parse(input_bytes))
    require!(Dir.children(output_root).empty?, "output root must be empty")

    part_path = File.join(output_root, "advanced_s0")
    plan, policy = write_plan
    documents = fixture_documents
    granules = documents.each_slice(2).map(&.to_a).to_a
    CrystalClick::WidePartWriter.write_uint64_object_pair(
      part_path,
      "pk",
      Slice(UInt64).new(ROW_COUNT) { |index| (index + 1).to_u64 },
      "doc",
      CrystalClick::ObjectDocumentSchema.new({} of String => CrystalClick::BinaryDataType, max_dynamic_paths: 0),
      plan,
      granules,
      rows_per_mark: 2,
      profile: CrystalClick::BinaryBulkProfile.single_stream,
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      frame_bytes: frame_bytes,
      shared_json_policy: policy,
      shared_target_chunk_rows: 1,
    )
    part = read_part(part_path)
    output = JSON::Any.new({
      "format"          => json(FORMAT_OUTPUT),
      "input_sha256"    => json(Digest::SHA256.hexdigest(input_bytes)),
      "output_root"     => json(output_root),
      "frame_bytes"     => json(frame_bytes.to_i64),
      "profile_id"      => json("advanced_s0"),
      "row_count"       => json(ROW_COUNT.to_i64),
      "mark_row_counts" => JSON::Any.new(MARK_ROWS.map { |n| json(n.to_i64) }),
      "part"            => part,
    } of String => JSON::Any)
    puts output.to_json
  end
end

CheckObjectNestedDynamicJSONW244.run(ARGV)
