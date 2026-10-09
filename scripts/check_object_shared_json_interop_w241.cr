require "../src/crystal_click"
require "digest/sha256"
require "json"

module CheckObjectSharedJSONInteropW241
  extend self

  FORMAT_INPUT         = "object_shared_json_interop_w241_input_v2"
  FORMAT_OUTPUT        = "object_shared_json_interop_w241_helper_v2"
  ROW_COUNT            = 8
  MARK_ROWS            = [2_u64, 2_u64, 2_u64, 2_u64]
  PHYSICAL_MARK_ROWS   = [2_u64, 2_u64, 2_u64, 2_u64, 0_u64]
  MAX_PART_FILE_BYTES  = 16_i64 * 1024 * 1024
  MAX_PART_TOTAL_BYTES = 64_i64 * 1024 * 1024
  MAX_RAW_STREAM_BYTES = 1_i64 * 1024 * 1024
  PROFILE_IDS          = [
    "map_s0", "map_s1", "map_with_buckets_s0", "map_with_buckets_s1",
    "advanced_s0", "advanced_s1", "advanced_chunked_s0", "advanced_chunked_s1",
  ]

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W241 helper: #{message}") unless condition
  end

  private def validate_real_mark_rows!(rows : Array(UInt64)) : Nil
    require!(rows == MARK_ROWS, "real mark row domain differs")
  end

  private def self_test_mark_domain_guard! : Nil
    forged_rows_rejected = false
    begin
      validate_real_mark_rows!(PHYSICAL_MARK_ROWS)
    rescue ex : CrystalClick::CorruptPartError
      forged_rows_rejected = ex.message == "W241 helper: real mark row domain differs"
    end
    require!(forged_rows_rejected, "five-entry physical mark schedule passed the real-reader mark guard")
  end

  # This comparator intentionally covers only the selected-path fixture
  # grammar: Dynamic, Array(JSON), JSON rows, and the observed String/UInt8/
  # UInt64/Int64 leaves. It avoids BinaryValue#== identity semantics for
  # ordinary recursive values and fails closed if the fixture grows.
  private def fixture_value_equal?(
    left : CrystalClick::BinaryValue,
    right : CrystalClick::BinaryValue,
    depth : Int32 = 0,
  ) : Bool
    require!(depth <= 16, "fixture structural comparison exceeds its depth bound")
    return false unless left.type == right.type
    return false unless left.is_null? == right.is_null?

    type = left.type
    if left.is_null?
      unless type.tag == CrystalClick::BinaryDataType::TAG_DYNAMIC
        raise CrystalClick::CorruptPartError.new(
          "W241 helper: fixture structural oracle encountered an unrostered NULL type #{type.name}"
        )
      end
      require!(left.child_count == 0 && right.child_count == 0,
        "fixture NULL Dynamic has a selected child")
      return true
    end

    case type.tag
    when CrystalClick::BinaryDataType::TAG_DYNAMIC
      require!(left.child_count <= 1 && right.child_count <= 1,
        "fixture Dynamic has more than one selected child")
      return false unless left.child_count == right.child_count
      require!(left.child_count == 1, "non-NULL fixture Dynamic has no selected child")
      fixture_value_equal?(left.child_at(0), right.child_at(0), depth + 1)
    when CrystalClick::BinaryDataType::TAG_ARRAY
      return false unless left.child_count == right.child_count
      left.child_count.times do |index|
        return false unless fixture_value_equal?(left.child_at(index), right.child_at(index), depth + 1)
      end
      true
    when CrystalClick::BinaryDataType::TAG_JSON
      left_row = left.json_row
      right_row = right.json_row
      return false unless left_row.type == right_row.type && left_row.path_count == right_row.path_count
      left_row.path_count.times do |index|
        return false unless left_row.path_at(index) == right_row.path_at(index)
        return false unless fixture_value_equal?(left_row.value_at(index), right_row.value_at(index), depth + 1)
      end
      true
    when CrystalClick::BinaryDataType::TAG_STRING,
         CrystalClick::BinaryDataType::TAG_UINT8,
         CrystalClick::BinaryDataType::TAG_UINT64,
         CrystalClick::BinaryDataType::TAG_INT64
      require!(left.child_count == 0 && right.child_count == 0,
        "fixture primitive leaf unexpectedly has children")
      return false unless left.byte_size == right.byte_size
      left.byte_size.times do |index|
        return false unless left.byte_at(index) == right.byte_at(index)
      end
      true
    else
      raise CrystalClick::CorruptPartError.new(
        "W241 helper: fixture structural oracle does not admit #{type.name}"
      )
    end
  end

  private def fixture_value_grid_equal?(
    left : Array(Array(CrystalClick::BinaryValue)),
    right : Array(Array(CrystalClick::BinaryValue)),
    expected_mark_rows : Array(UInt64),
  ) : Bool
    return false unless left.size == expected_mark_rows.size && right.size == expected_mark_rows.size
    left.size.times do |mark_index|
      expected_rows = expected_mark_rows[mark_index].to_i
      left_mark = left[mark_index]
      right_mark = right[mark_index]
      return false unless left_mark.size == expected_rows && right_mark.size == expected_rows
      left_mark.size.times do |row_index|
        return false unless fixture_value_equal?(left_mark[row_index], right_mark[row_index])
      end
    end
    true
  end

  private def self_test_fixture_value_comparison! : Nil
    rows = [{42_u8, "alpha", "s"}] of Tuple(UInt8, String, String)
    left = json_array(arr_json_type, rows, "s")
    equal_but_distinct = json_array(arr_json_type, rows, "s")
    require!(!left.same?(equal_but_distinct), "fixture comparison self-test reused the same Array(JSON) object")
    left_grid = [[left]] of Array(CrystalClick::BinaryValue)
    equal_grid = [[equal_but_distinct]] of Array(CrystalClick::BinaryValue)
    require!(fixture_value_grid_equal?(left_grid, equal_grid, [1_u64]),
      "fixture structural comparison rejected distinct equal Array(JSON) values")
    require!(!fixture_value_grid_equal?(left_grid, equal_grid, [2_u64]),
      "fixture structural comparison accepted a forged mark row count")

    changed = json_array(
      arr_json_type,
      [{42_u8, "blpha", "s"}] of Tuple(UInt8, String, String),
      "s",
    )
    left_row = left.child_at(0).json_row
    changed_row = changed.child_at(0).json_row
    require!(left.type == changed.type && left.child_count == changed.child_count &&
             left_row.type == changed_row.type && left_row.path_count == changed_row.path_count,
      "fixture nested-String self-test changed its Array/JSON descriptors or counts")
    left_row.path_count.times do |index|
      left_field = left_row.value_at(index)
      changed_field = changed_row.value_at(index)
      require!(left_row.path_at(index) == changed_row.path_at(index) &&
               left_field.type == changed_field.type &&
               left_field.is_null? == changed_field.is_null? &&
               left_field.child_count == changed_field.child_count,
        "fixture nested-String self-test changed its JSON path roster or field descriptor")
    end
    left_string = left_row.value_for("s").not_nil!
    changed_string = changed_row.value_for("s").not_nil!
    require!(left_string.type.tag == CrystalClick::BinaryDataType::TAG_STRING &&
             left_string.byte_size == changed_string.byte_size &&
             left_string.byte_at(0) != changed_string.byte_at(0),
      "fixture nested-String self-test did not make a same-length String payload change")
    changed_grid = [[changed]] of Array(CrystalClick::BinaryValue)
    require!(!fixture_value_grid_equal?(left_grid, changed_grid, [1_u64]),
      "fixture structural comparison accepted a same-length nested String change")

    carrier_type = selected_path_carrier_type
    selected_array = CrystalClick::BinaryValue.dynamic(carrier_type, left)
    require!(fixture_value_equal?(selected_path_outer_projection(selected_array), left),
      "selected-path projection rejected an Array(JSON) child")
    scalar = CrystalClick::BinaryValue.dynamic(carrier_type, CrystalClick::BinaryValue.string("scalar"))
    require!(fixture_value_equal?(selected_path_outer_projection(scalar), scalar.child_at(0)),
      "selected-path projection rejected a scalar child")

    null_carrier = CrystalClick::BinaryValue.dynamic(carrier_type)
    projected_null = selected_path_outer_projection(null_carrier)
    require!(
      projected_null.same?(null_carrier) && projected_null.is_null? && projected_null.child_count == 0,
      "selected-path projection rejected the valid NULL carrier shape")
    nothing_sentinel_carrier = CrystalClick::BinaryValue.dynamic(
      carrier_type,
      CrystalClick::BinaryValue.null,
    )
    require!(
      selected_path_outer_projection(nothing_sentinel_carrier).is_null? &&
      nothing_sentinel_carrier.child_count == 0,
      "Dynamic Nothing NULL sentinel did not normalize to the valid NULL carrier shape")

    wrong_cap = CrystalClick::BinaryValue.dynamic(
      CrystalClick::BinaryDataType.dynamic(max_types: 32),
      CrystalClick::BinaryValue.string("scalar"),
    )
    require_selected_path_projection_rejected!(wrong_cap, "wrong outer Dynamic cap")

    nested_dynamic = CrystalClick::BinaryValue.dynamic(
      carrier_type,
      CrystalClick::BinaryValue.dynamic(
        CrystalClick::BinaryDataType.dynamic(max_types: 32),
        CrystalClick::BinaryValue.string("nested"),
      ),
    )
    require!(
      nested_dynamic.child_count == 1 &&
      nested_dynamic.child_at(0).type.tag == CrystalClick::BinaryDataType::TAG_DYNAMIC,
      "nested-Dynamic self-test did not construct its immediate child shape")
    require_selected_path_projection_rejected!(nested_dynamic, "immediate nested Dynamic child")
  end

  private def selected_path_carrier_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.dynamic(
      max_types: CrystalClick::ObjectSharedAdvancedChunkCodec::JSON_DYNAMIC_MAX_TYPES,
    )
  end

  # This is a fixture-specific bridge from the selected-path transport carrier
  # to the logical path value. Do not recursively unwrap: nested Dynamic is
  # outside the closed W241 actual-type roster.
  private def selected_path_outer_projection(value : CrystalClick::BinaryValue) : CrystalClick::BinaryValue
    require!(value.type == selected_path_carrier_type,
      "selected-path outer carrier has an unexpected descriptor")
    if value.is_null?
      require!(value.child_count == 0, "NULL selected-path carrier has a child")
      return value
    end

    require!(value.child_count == 1, "non-NULL selected-path carrier must have exactly one child")
    selected = value.child_at(0)
    require!(selected.type.tag != CrystalClick::BinaryDataType::TAG_DYNAMIC,
      "selected-path carrier has an immediate nested Dynamic child")
    selected
  end

  private def require_selected_path_projection_rejected!(
    value : CrystalClick::BinaryValue,
    case_name : String,
  ) : Nil
    rejected = false
    begin
      selected_path_outer_projection(value)
    rescue ex : CrystalClick::CorruptPartError
      rejected = true
    end
    require!(rejected, "selected-path projection accepted #{case_name}")
  end

  private def required_json_field(fields : Hash(String, JSON::Any), name : String) : JSON::Any
    fields[name]? || raise CrystalClick::CorruptPartError.new("W241 helper: required JSON field is absent: #{name}")
  end

  private def profile(name : String) : CrystalClick::BinaryBulkProfile
    case name
    when "s0" then CrystalClick::BinaryBulkProfile.single_stream
    when "s1" then CrystalClick::BinaryBulkProfile.with_size_stream
    else           raise ArgumentError.new("W241 String profile is outside the fixed roster")
    end
  end

  private def u8 : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt8")
  end

  private def stock_schema : CrystalClick::ObjectDocumentSchema
    CrystalClick::ObjectDocumentSchema.new(
      {} of String => CrystalClick::BinaryDataType,
      max_dynamic_paths: 0,
    )
  end

  private def arr_json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.json(
        max_dynamic_paths: 1,
        max_dynamic_types: 1,
        typed_paths: {"v" => u8} of String => CrystalClick::BinaryDataType,
      ),
    )
  end

  private def late_json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.json(
        max_dynamic_paths: 2,
        max_dynamic_types: 1,
        typed_paths: {"v" => u8} of String => CrystalClick::BinaryDataType,
      ),
    )
  end

  private def nullable_string_array_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("String")),
    )
  end

  private def json_value(type : CrystalClick::BinaryDataType, number : UInt8, name : String, dynamic_path : String) : CrystalClick::BinaryValue
    row = CrystalClick::BinaryJsonRow.new(
      type.child_at(0),
      [
        {"v", CrystalClick::BinaryValue.fixed(u8, Bytes[number])},
        {dynamic_path, CrystalClick::BinaryValue.string(name)},
      ] of Tuple(String, CrystalClick::BinaryValue),
    )
    CrystalClick::BinaryValue.json(type.child_at(0), row)
  end

  private def child_plan(
    version : Int32,
    bucket_count : UInt64,
    path : String,
  ) : CrystalClick::ObjectDocumentPlan
    object = CrystalClick::ObjectStructure.new(
      [path] of String,
      shared_data_version: version.to_u64,
      bucket_count: bucket_count,
    )
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      object,
      {path => CrystalClick::DynamicStructure.new(
        [CrystalClick::BinaryDataType.primitive("String")] of CrystalClick::BinaryDataType,
      )},
    )
    CrystalClick::ObjectDocumentPlan.new(
      structures,
      {"v" => u8} of String => CrystalClick::BinaryDataType,
    )
  end

  private def actual_plan(
    actual_type : CrystalClick::BinaryDataType,
    child : CrystalClick::ObjectDocumentPlan,
  ) : CrystalClick::ObjectSharedAdvancedJsonActualPlan
    CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
      actual_type,
      [{[0_i32] of Int32, child}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
    )
  end

  private def json_array(
    type : CrystalClick::BinaryDataType,
    rows : Array(Tuple(UInt8, String, String)),
    path : String,
  ) : CrystalClick::BinaryValue
    elements = rows.map { |row| json_value(type, row[0], row[1], path) }
    CrystalClick::BinaryValue.array(type, elements)
  end

  private def fixture(version : Int32) : Array(CrystalClick::ObjectDocument)
    arr_type = arr_json_type
    late_type = late_json_type
    empty_type = nullable_string_array_type
    docs = [] of CrystalClick::ObjectDocument
    docs << CrystalClick::ObjectDocument.new({
      "arr"   => json_array(arr_type, [{1_u8, "one", "s"}, {2_u8, "two", "s"}] of Tuple(UInt8, String, String), "s"),
      "mixed" => CrystalClick::BinaryValue.int64(1_i64),
      "label" => CrystalClick::BinaryValue.string("one"),
    } of String => CrystalClick::BinaryValue)
    docs << CrystalClick::ObjectDocument.new({
      "arr"   => json_array(arr_type, [{3_u8, "three", "s"}] of Tuple(UInt8, String, String), "s"),
      "mixed" => CrystalClick::BinaryValue.string("two"),
      "label" => CrystalClick::BinaryValue.int64(2_i64),
    } of String => CrystalClick::BinaryValue)
    docs << CrystalClick::ObjectDocument.new({
      "arr"   => CrystalClick::BinaryValue.array(empty_type, [] of CrystalClick::BinaryValue),
      "mixed" => CrystalClick::BinaryValue.bool(true),
      "label" => CrystalClick::BinaryValue.string("three"),
    } of String => CrystalClick::BinaryValue)
    docs << CrystalClick::ObjectDocument.new({} of String => CrystalClick::BinaryValue)
    docs << CrystalClick::ObjectDocument.new({
      "arr"   => json_array(arr_type, [{5_u8, "five", "s"}] of Tuple(UInt8, String, String), "s"),
      "mixed" => CrystalClick::BinaryValue.int64(2_i64),
      "label" => CrystalClick::BinaryValue.int64(5_i64),
    } of String => CrystalClick::BinaryValue)
    docs << CrystalClick::ObjectDocument.new({
      "arr"   => CrystalClick::BinaryValue.array(empty_type, [] of CrystalClick::BinaryValue),
      "mixed" => CrystalClick::BinaryValue.string("six"),
      "label" => CrystalClick::BinaryValue.string("six"),
    } of String => CrystalClick::BinaryValue)
    docs << CrystalClick::ObjectDocument.new({
      "arr"   => json_array(arr_type, [{7_u8, "seven", "s"}] of Tuple(UInt8, String, String), "s"),
      "mixed" => CrystalClick::BinaryValue.bool(false),
      "label" => CrystalClick::BinaryValue.int64(7_i64),
    } of String => CrystalClick::BinaryValue)
    docs << CrystalClick::ObjectDocument.new({
      "arr"   => json_array(arr_type, [{8_u8, "eight", "s"}] of Tuple(UInt8, String, String), "s"),
      "mixed" => CrystalClick::BinaryValue.int64(3_i64),
      "label" => CrystalClick::BinaryValue.string("last"),
      "late"  => json_array(late_type, [{80_u8, "last-chunk-only", "late_only_child"}] of Tuple(UInt8, String, String), "late_only_child"),
    } of String => CrystalClick::BinaryValue)
    docs
  end

  private def render_value(value : CrystalClick::BinaryValue) : JSON::Any
    return JSON::Any.new(nil) if value.is_null?
    type = value.type
    case type.tag
    when CrystalClick::BinaryDataType::TAG_STRING
      JSON::Any.new(value.as_string)
    when CrystalClick::BinaryDataType::TAG_BOOL
      JSON::Any.new(value.as_bool)
    when CrystalClick::BinaryDataType::TAG_INT64
      JSON::Any.new(value.as_int64)
    when CrystalClick::BinaryDataType::TAG_UINT8
      JSON::Any.new(value.byte_at(0).to_i64)
    when CrystalClick::BinaryDataType::TAG_UINT64
      number = value.as_uint64
      raise CrystalClick::CorruptPartError.new("W241 helper: UInt64 witness exceeds JSON integer range") if number > Int64::MAX.to_u64
      JSON::Any.new(number.to_i64)
    when CrystalClick::BinaryDataType::TAG_ARRAY
      JSON::Any.new(value.elements.map { |item| render_value(item) })
    when CrystalClick::BinaryDataType::TAG_JSON
      row = value.json_row
      fields = {} of String => JSON::Any
      row.path_count.times do |index|
        path = row.path_at(index)
        fields[path] = render_value(row.value_for(path).not_nil!)
      end
      JSON::Any.new(fields)
    when CrystalClick::BinaryDataType::TAG_DYNAMIC
      value.child_count == 0 ? JSON::Any.new(nil) : render_value(value.child_at(0))
    else
      raise CrystalClick::CorruptPartError.new("W241 helper: unrostered decoded value type #{type.name}")
    end
  end

  private def render_documents(marks : Array(Array(CrystalClick::ObjectDocument)), first_row : Int32) : Array(JSON::Any)
    rows = [] of JSON::Any
    marks.each_with_index do |mark, mark_index|
      mark.each_with_index do |document, row_index|
        fields = {} of String => JSON::Any
        document.paths.each { |path| fields[path] = render_value(document.value_for(path)) }
        rows << JSON::Any.new({
          "pk"  => JSON::Any.new((first_row + mark_index * 2 + row_index + 1).to_i64),
          "doc" => JSON::Any.new(fields),
        } of String => JSON::Any)
      end
    end
    rows
  end

  private def render_shared_path(marks : Array(Array(CrystalClick::BinaryValue)), first_row : Int32) : Array(JSON::Any)
    rows = [] of JSON::Any
    marks.each_with_index do |mark, mark_index|
      mark.each_with_index do |value, row_index|
        concrete = selected_path_outer_projection(value)
        rows << JSON::Any.new({
          "pk"           => JSON::Any.new((first_row + mark_index * 2 + row_index + 1).to_i64),
          "type"         => JSON::Any.new(concrete.is_null? ? "NULL" : concrete.type.name),
          "wrapper_type" => JSON::Any.new(value.type.name),
          "value"        => render_value(value),
        } of String => JSON::Any)
      end
    end
    rows
  end

  private def concrete_value(value : CrystalClick::BinaryValue) : CrystalClick::BinaryValue
    current = value
    while current.type.tag == CrystalClick::BinaryDataType::TAG_DYNAMIC && current.child_count > 0
      current = current.child_at(0)
    end
    current
  end

  # Preserve the actual nested type evidence separately from the normalized
  # logical JSON values. Stock inference and the generated explicit child
  # plan are expected to differ here (for example, stock UInt64 vs UInt8).
  private def nested_type_witnesses(marks : Array(Array(CrystalClick::ObjectDocument)), first_row : Int32) : Array(JSON::Any)
    rows = [] of JSON::Any
    marks.each_with_index do |mark, mark_index|
      mark.each_with_index do |document, row_index|
        fields = {} of String => JSON::Any
        {"arr", "late"}.each do |path|
          next unless document.paths.includes?(path)
          value = document.value_for(path)
          concrete = concrete_value(value)
          witness = {
            "wrapper_type" => JSON::Any.new(value.type.name),
            "outer_type"   => JSON::Any.new(concrete.type.name),
          } of String => JSON::Any
          if concrete.type.tag == CrystalClick::BinaryDataType::TAG_ARRAY && !concrete.elements.empty?
            element = concrete.elements[0]
            witness["element_type"] = JSON::Any.new(element.type.name)
            if element.type.tag == CrystalClick::BinaryDataType::TAG_JSON
              child_types = {} of String => JSON::Any
              json = element.json_row
              json.path_count.times do |index|
                child_path = json.path_at(index)
                child = json.value_for(child_path).not_nil!
                child_types[child_path] = JSON::Any.new(concrete_value(child).type.name)
              end
              witness["first_element_child_types"] = JSON::Any.new(child_types)
            end
          end
          fields[path] = JSON::Any.new(witness)
        end
        rows << JSON::Any.new({
          "pk"    => JSON::Any.new((first_row + mark_index * 2 + row_index + 1).to_i64),
          "paths" => JSON::Any.new(fields),
        } of String => JSON::Any)
      end
    end
    rows
  end

  private def file_bytes(path : String, label : String) : Bytes
    require!(File.file?(path) && !File.symlink?(path), "#{label} is absent, non-regular, or symlinked")
    size = File.size(path)
    require!(size <= MAX_PART_FILE_BYTES, "#{label} exceeds the file-size bound")
    text = File.read(path)
    require!(text.bytesize.to_i64 == size, "#{label} changed while reading")
    Bytes.new(text.bytesize) { |index| text.to_slice[index] }
  end

  private def physical_inventory(path : String) : JSON::Any
    names = Dir.children(path).sort
    total = 0_i64
    files = [] of JSON::Any
    names.each do |name|
      require!(!name.includes?(File::SEPARATOR) && name != "." && name != "..", "part file name is unsafe")
      file_path = File.join(path, name)
      require!(File.file?(file_path) && !File.symlink?(file_path), "part contains a non-regular file: #{name}")
      bytes = file_bytes(file_path, "part file #{name}")
      total += bytes.size.to_i64
      require!(total <= MAX_PART_TOTAL_BYTES, "part exceeds total-size bound")
      files << JSON::Any.new({
        "name"   => JSON::Any.new(name),
        "size"   => JSON::Any.new(bytes.size.to_i64),
        "sha256" => JSON::Any.new(Digest::SHA256.hexdigest(bytes)),
      } of String => JSON::Any)
    end
    JSON::Any.new(files)
  end

  private def raw_stream_inventory(path : String, logical_names : Array(String)) : JSON::Any
    raw_streams = {} of String => JSON::Any
    logical_names.sort.each do |logical_name|
      next unless logical_name == "doc.object_structure" || logical_name.starts_with?("doc.object_shared_data")
      stem = CrystalClick::StreamName.hash(logical_name)
      stream_path = File.join(path, "#{stem}.bin")
      physical = file_bytes(stream_path, "stream #{logical_name}")
      raw = if physical.empty?
              Bytes.empty
            else
              CrystalClick::CompressedBlock.decode_all(
                physical,
                MAX_PART_FILE_BYTES,
                MAX_RAW_STREAM_BYTES,
                MAX_RAW_STREAM_BYTES,
              )
            end
      require!(raw.size.to_i64 <= MAX_RAW_STREAM_BYTES, "decoded stream #{logical_name} exceeds bound")
      raw_streams[logical_name] = JSON::Any.new({
        "physical_file"   => JSON::Any.new("#{stem}.bin"),
        "physical_sha256" => JSON::Any.new(Digest::SHA256.hexdigest(physical)),
        "decoded_bytes"   => JSON::Any.new(raw.size.to_i64),
        "decoded_sha256"  => JSON::Any.new(Digest::SHA256.hexdigest(raw)),
        "decoded_hex"     => JSON::Any.new(raw.map { |byte| byte.to_s(16).rjust(2, '0') }.join),
      } of String => JSON::Any)
    end
    JSON::Any.new(raw_streams)
  end

  private def assert_checksummed_part!(path : String) : Nil
    CrystalClick::WidePartWriter.w241_validate_and_inventory_part(path)
  end

  private def read_part(path : String, expected_version : Int32, expected_profile : String, role : String) : JSON::Any
    schema = stock_schema
    assert_checksummed_part!(path)
    reader = CrystalClick::ObjectColumnReader.open(path, "doc", schema)
    require!(reader.row_count == ROW_COUNT.to_u64, "#{role} row count differs")
    validate_real_mark_rows!(reader.mark_row_counts)
    string_version = expected_profile == "s0" ? 0 : 1
    require!(reader.ordinary_profile == profile(expected_profile), "#{role} ordinary String binding differs")
    descriptor = CrystalClick::ObjectDocumentFileReader.inspect(
      path,
      "doc",
      schema.typed_paths,
      reader.ordinary_profile,
      CrystalClick::BinaryBulkProfile.single_stream,
      true,
    )
    object = descriptor.plan.structures.object
    require!(object.shared_data_version == expected_version.to_u64, "#{role} actual shared-data version differs")
    # Whole-Object reconstruction uses its own reader. The path stage below
    # opens fresh readers and never calls read_marks/read_document.
    full_reader = CrystalClick::ObjectColumnReader.open(path, "doc", schema)
    full = full_reader.read_marks(0, MARK_ROWS.size)
    direct = {} of String => JSON::Any
    direct_values = {} of String => Array(Array(CrystalClick::BinaryValue))
    {"arr", "mixed", "late"}.each do |path_name|
      path_reader = CrystalClick::ObjectColumnReader.open(path, "doc", schema)
      values = path_reader.read_shared_path_marks(path_name, 0, MARK_ROWS.size)
      direct_values[path_name] = values
      direct[path_name] = JSON::Any.new(render_shared_path(values, 0))
    end
    selected_witnesses = if expected_version >= 2
                           selected_path_structure_witnesses(
                             path, schema, reader, descriptor, expected_version, direct_values,
                           )
                         else
                           [] of JSON::Any
                         end
    inventory = physical_inventory(path)
    bounded_windows = bounded_window_witnesses(path, schema, full, direct_values)
    raw_streams = raw_stream_inventory(path, reader.physical_stream_names)
    mark_triples = {} of String => JSON::Any
    reader.physical_stream_names.each do |logical_name|
      mark_path = File.join(path, "#{CrystalClick::StreamName.hash(logical_name)}.mrk2")
      mark_bytes = file_bytes(mark_path, "mark file #{logical_name}")
      require!(mark_bytes.size % 24 == 0, "mark file #{logical_name} is not plain triples")
      values = [] of JSON::Any
      words = [] of UInt64
      (mark_bytes.size // 8).times do |index|
        value = 0_u64
        8.times { |offset| value |= mark_bytes[index * 8 + offset].to_u64 << (offset * 8) }
        words << value
      end
      words.each_slice(3) do |triple|
        values << JSON::Any.new(triple.map { |value| JSON::Any.new(value.to_i64) })
      end
      physical_rows = words.each_slice(3).map { |triple| triple[2] }.to_a
      require!(physical_rows == PHYSICAL_MARK_ROWS,
        "#{role} physical mark file does not contain four real records and one terminal sentinel")
      mark_triples[logical_name] = JSON::Any.new(values)
    end
    substreams_bytes = file_bytes(File.join(path, "columns_substreams.txt"), "columns_substreams.txt")
    columns_bytes = file_bytes(File.join(path, "columns.txt"), "columns.txt")
    count_bytes = file_bytes(File.join(path, "count.txt"), "count.txt")
    serialization_bytes = file_bytes(File.join(path, "serialization.json"), "serialization.json")
    serialization = JSON.parse(String.new(serialization_bytes))
    checksums_bytes = file_bytes(File.join(path, "checksums.txt"), "checksums.txt")
    expected_string_version = string_version.to_i64
    require!(serialization["version"].as_i == 1 &&
             serialization["propagate_types_serialization_versions_to_nested_types"].as_bool &&
             serialization["types_serialization_versions"]["string"].as_i == expected_string_version,
      "#{role} serialized ordinary String version differs")
    result = {
      "role"                              => JSON::Any.new(role),
      "part_path"                         => JSON::Any.new(path),
      "source_declaration"                => JSON::Any.new(reader.source_declaration),
      "row_count"                         => JSON::Any.new(reader.row_count.to_i64),
      "mark_row_counts"                   => JSON::Any.new(reader.mark_row_counts.map { |n| JSON::Any.new(n.to_i64) }),
      "actual_shared_data_version"        => JSON::Any.new(object.shared_data_version.to_i64),
      "actual_bucket_count"               => JSON::Any.new(object.bucket_count.to_i64),
      "ordinary_string_profile"           => JSON::Any.new(string_version),
      "physical_stream_names"             => JSON::Any.new(reader.physical_stream_names.map { |name| JSON::Any.new(name) }),
      "mark_triples"                      => JSON::Any.new(mark_triples),
      "physical_file_inventory"           => inventory,
      "columns_substreams_text"           => JSON::Any.new(String.new(substreams_bytes)),
      "columns_text"                      => JSON::Any.new(String.new(columns_bytes)),
      "count_text"                        => JSON::Any.new(String.new(count_bytes).strip),
      "serialization_json"                => JSON::Any.new(serialization.as_h),
      "serialization_json_sha256"         => JSON::Any.new(Digest::SHA256.hexdigest(serialization_bytes)),
      "checksums_sha256"                  => JSON::Any.new(Digest::SHA256.hexdigest(checksums_bytes)),
      "raw_shared_streams"                => raw_streams,
      "full_rows"                         => JSON::Any.new(render_documents(full, 0)),
      "nested_type_witnesses"             => JSON::Any.new(nested_type_witnesses(full, 0)),
      "direct_shared_path_rows"           => JSON::Any.new(direct),
      "selected_path_structure_witnesses" => JSON::Any.new(selected_witnesses),
      "bounded_windows"                   => JSON::Any.new(bounded_windows),
      "direct_shared_path_semantics"      => JSON::Any.new(expected_version < 2 ? "bounded selected shared MAP lane; not physically selective" : "selected shared Data path; whole-Object read was performed by a separate reader"),
    } of String => JSON::Any
    JSON::Any.new(result)
  end

  private def bounded_window_witnesses(
    part : String,
    schema : CrystalClick::ObjectDocumentSchema,
    full_reference : Array(Array(CrystalClick::ObjectDocument)),
    path_references : Hash(String, Array(Array(CrystalClick::BinaryValue))),
  ) : Array(JSON::Any)
    windows = [
      {"middle", 1, 2},
      {"last", 3, 1},
      {"empty_interior", 2, 0},
      {"zero_count_end", MARK_ROWS.size, 0},
    ] of Tuple(String, Int32, Int32)
    witnesses = [] of JSON::Any

    windows.each do |window, first_mark, mark_count|
      expected_mark_counts = Array(UInt64).new(mark_count) { |offset| MARK_ROWS[first_mark + offset] }
      expected_documents = Array(Array(CrystalClick::ObjectDocument)).new(mark_count) do |offset|
        full_reference[first_mark + offset]
      end
      expected_doc_rows = render_documents(expected_documents, first_mark * 2)
      actual_documents = CrystalClick::ObjectColumnReader.open(part, "doc", schema).read_marks(first_mark, mark_count)
      actual_doc_rows = render_documents(actual_documents, first_mark * 2)
      actual_doc_counts = actual_documents.map { |mark| mark.size.to_u64 }
      require!(actual_doc_counts == expected_mark_counts && actual_doc_rows == expected_doc_rows,
        "W241 bounded whole-Object #{window} differs from its full-read slice")
      witnesses << JSON::Any.new({
        "consumer"                 => JSON::Any.new("whole_object"),
        "path"                     => JSON::Any.new(nil),
        "window"                   => JSON::Any.new(window),
        "first_mark"               => JSON::Any.new(first_mark),
        "mark_count"               => JSON::Any.new(mark_count),
        "expected_mark_row_counts" => JSON::Any.new(expected_mark_counts.map { |rows| JSON::Any.new(rows.to_i64) }),
        "actual_mark_row_counts"   => JSON::Any.new(actual_doc_counts.map { |rows| JSON::Any.new(rows.to_i64) }),
        "expected_rows"            => JSON::Any.new(expected_doc_rows),
        "actual_rows"              => JSON::Any.new(actual_doc_rows),
        "matches_full_slice"       => JSON::Any.new(true),
      } of String => JSON::Any)

      {"arr", "mixed", "late"}.each do |path_name|
        reference = path_references[path_name]? || raise CrystalClick::CorruptPartError.new(
          "W241 helper: full-read reference path is absent: #{path_name}"
        )
        expected_marks = Array(Array(CrystalClick::BinaryValue)).new(mark_count) do |offset|
          reference[first_mark + offset]
        end
        expected_rows = render_shared_path(expected_marks, first_mark * 2)
        path_window_reader = CrystalClick::ObjectColumnReader.open(part, "doc", schema)
        actual_marks = path_window_reader.read_shared_path_marks(path_name, first_mark, mark_count)
        actual_rows = render_shared_path(actual_marks, first_mark * 2)
        actual_mark_counts = actual_marks.map { |mark| mark.size.to_u64 }
        require!(actual_mark_counts == expected_mark_counts && actual_rows == expected_rows,
          "W241 bounded selected path #{path_name} #{window} differs from its full-read slice")
        witnesses << JSON::Any.new({
          "consumer"                 => JSON::Any.new("selected_path"),
          "path"                     => JSON::Any.new(path_name),
          "window"                   => JSON::Any.new(window),
          "first_mark"               => JSON::Any.new(first_mark),
          "mark_count"               => JSON::Any.new(mark_count),
          "expected_mark_row_counts" => JSON::Any.new(expected_mark_counts.map { |rows| JSON::Any.new(rows.to_i64) }),
          "actual_mark_row_counts"   => JSON::Any.new(actual_mark_counts.map { |rows| JSON::Any.new(rows.to_i64) }),
          "expected_rows"            => JSON::Any.new(expected_rows),
          "actual_rows"              => JSON::Any.new(actual_rows),
          "matches_full_slice"       => JSON::Any.new(true),
        } of String => JSON::Any)
      end
    end
    witnesses
  end

  # Fresh, bounded second pass over the six physical ADVANCED lanes. It keeps
  # the exact path Data slice, callback tape, and decoded Dynamic structures
  # together so the Ruby auditor can bind the type roster to physical marks.
  private def selected_path_structure_witnesses(
    part : String,
    schema : CrystalClick::ObjectDocumentSchema,
    reader : CrystalClick::ObjectColumnReader,
    descriptor : CrystalClick::ObjectDocumentFileDescriptor,
    version : Int32,
    expected_path_values : Hash(String, Array(Array(CrystalClick::BinaryValue))),
  ) : Array(JSON::Any)
    rows_per_parent = reader.mark_row_counts
    require!(!rows_per_parent.empty? && rows_per_parent.all? { |rows| rows > 0_u64 },
      "ADVANCED witness must use positive real parent marks and exclude the EOF coordinate")
    object = descriptor.plan.structures.object
    physical = CrystalClick::ObjectDocumentPhysicalPlan.new(
      "doc", descriptor.plan, reader.ordinary_profile, CrystalClick::BinaryBulkProfile.single_stream,
      schema.limits,
    )
    require!(physical.shared_bucket_count == object.bucket_count.to_i32,
      "ADVANCED witness physical plan bucket count differs from the on-part descriptor")
    source = CrystalClick::PartStreamSource.new(part)
    inputs = Array(CrystalClick::ObjectSharedPhysicalBucketLaneInputs).new(physical.shared_bucket_count)
    physical.shared_bucket_count.times do |bucket|
      lanes = Hash(String, CrystalClick::ObjectSharedPhysicalLaneInput).new
      CrystalClick::ObjectSharedPhysicalBucketLaneInputs::LANE_NAMES.each do |lane|
        logical_name = physical.advanced_bucket_stream_name(bucket, lane)
        stem = CrystalClick::StreamName.hash(logical_name)
        lanes[lane] = source.physical_lane_input("#{stem}.bin", "#{stem}.mrk2")
      end
      inputs << CrystalClick::ObjectSharedPhysicalBucketLaneInputs.new(lanes)
    end

    witnesses = [] of JSON::Any
    {"arr", "late"}.each do |path_name|
      selected_bucket = CrystalClick::ObjectSharedBucketLayout.bucket_for(path_name, physical.shared_bucket_count)
      # The document-level reader owns the complete bucket grid: it validates
      # the opposite bucket with no retained path Data and captures only this
      # path in its hash-selected bucket. Keep that cross-bucket schedule check
      # separate from the bucket-level decoder below, which accepts one owner.
      selected_values = CrystalClick::ObjectSharedAdvancedDocumentCodec.decode_path_only(
        inputs,
        rows_per_parent,
        rows_per_parent,
        version,
        physical.shared_bucket_count,
        selected_bucket,
        path_name,
        0,
        rows_per_parent.size,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::ObjectDocumentCodec::DEFAULT_LIMITS),
        CrystalClick::CompressedStreamBudget.read_default,
        reader.ordinary_profile,
      )
      expected_values = expected_path_values[path_name]? || raise CrystalClick::CorruptPartError.new(
        "W241 helper: independent path reference is absent: #{path_name}"
      )
      require!(expected_values.size == MARK_ROWS.size,
        "ADVANCED direct path reference differs from the real parent mark domain")
      require!(fixture_value_grid_equal?(
        selected_values,
        expected_values[0...rows_per_parent.size],
        MARK_ROWS[0...rows_per_parent.size],
      ),
        "ADVANCED document-level path decode differs from the independent ObjectColumnReader result")

      codec_budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::ObjectDocumentCodec::DEFAULT_LIMITS)
      transport_budget = CrystalClick::CompressedStreamBudget.read_default
      parents = CrystalClick::ObjectSharedPhysicalBucketDecoder.decode_selected_path(
        version, inputs[selected_bucket], rows_per_parent, path_name, 0, rows_per_parent.size,
        codec_budget, transport_budget,
      )
      nested_context = CrystalClick::ObjectSharedNestedSerializationContext.for_read(
        version.to_u64, reader.ordinary_profile,
      )
      dynamic_type = CrystalClick::BinaryDataType.dynamic(
        max_types: CrystalClick::ObjectSharedAdvancedChunkCodec::JSON_DYNAMIC_MAX_TYPES,
      )
      parents.each_with_index do |parent, parent_mark|
        require!(parent.physical_rows == rows_per_parent[parent_mark], "ADVANCED witness parent rows differ")
        parent.chunks.each_with_index do |chunk, chunk_index|
          chunk.path_count.times do |path_index|
            physical_path = chunk.path_at(path_index)
            next unless physical_path.name == path_name
            streams = physical_path.streams
            decoded = CrystalClick::ObjectSharedPathCodec.decode_with_json_children_with_budget(
              streams.data,
              streams.events,
              chunk.row_count.to_i,
              dynamic_type,
              codec_budget,
              nested_context,
              reader.ordinary_profile,
              streams.coordinate_context,
            )
            require!(decoded.rows.size == chunk.row_count.to_i,
              "ADVANCED witness decoded path row count differs from its physical chunk")
            structure_witnesses = decoded.structures.to_a.sort_by { |entry| entry[0] }.map do |structure_path, structure|
              types = Array(JSON::Any).new(structure.type_count) do |index|
                JSON::Any.new(structure.type_at(index).name)
              end
              JSON::Any.new({
                "path"       => JSON::Any.new(structure_path),
                "type_count" => JSON::Any.new(structure.type_count),
                "types"      => JSON::Any.new(types),
              } of String => JSON::Any)
            end
            event_witnesses = streams.events.map do |event|
              JSON::Any.new({
                "name"            => JSON::Any.new(event.name),
                "relative_offset" => JSON::Any.new(event.relative_offset.to_i64),
              } of String => JSON::Any)
            end
            raw_data = streams.data
            witnesses << JSON::Any.new({
              "path"      => JSON::Any.new(path_name),
              "bucket_id" => JSON::Any.new(selected_bucket),
              # The selected child bytes are stored inside this containing
              # root Object Data lane. Nested Compact marks must be resolved
              # against its frames, never against a detached child buffer.
              "containing_data_stream" => JSON::Any.new("doc.object_shared_data.#{selected_bucket}.data"),
              "parent_mark"            => JSON::Any.new(parent_mark),
              "chunk_index"            => JSON::Any.new(chunk_index),
              "row_count"              => JSON::Any.new(chunk.row_count.to_i64),
              "data_hex"               => JSON::Any.new(raw_data.map { |byte| byte.to_s(16).rjust(2, '0') }.join),
              "data_sha256"            => JSON::Any.new(Digest::SHA256.hexdigest(raw_data)),
              "events"                 => JSON::Any.new(event_witnesses),
              "structures"             => JSON::Any.new(structure_witnesses),
            } of String => JSON::Any)
          end
        end
        chunk_rows = 0_u64
        parent.chunks.each { |chunk| chunk_rows += chunk.row_count.to_u64 }
        require!(chunk_rows == parent.physical_rows.to_u64,
          "ADVANCED witness chunks do not cover the physical parent mark")
      end
      real_rows = 0_u64
      parents.each { |parent| real_rows += parent.physical_rows.to_u64 }
      require!(real_rows == reader.row_count.to_u64,
        "ADVANCED witness real parent marks do not cover the part row count")
    end
    witnesses
  end

  private def write_part(path : String, version : Int32, profile_id : String, frame_bytes : Int32) : JSON::Any
    ordinary_profile = profile(profile_id)
    # String serialization-version propagation covers ordinary and nested
    # Dynamic String fields. The normalized shared-MAP carrier keeps its
    # separately admitted stock single-stream encoding for both versions.
    shared_profile = CrystalClick::BinaryBulkProfile.single_stream
    bucket_count = version == 0 ? 1_u64 : 2_u64
    object = CrystalClick::ObjectStructure.new(
      [] of String,
      shared_data_version: version.to_u64,
      bucket_count: bucket_count,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(
      CrystalClick::ObjectDynamicStructureSet.new(object, {} of String => CrystalClick::DynamicStructure),
      {} of String => CrystalClick::BinaryDataType,
    )
    actuals = [
      actual_plan(arr_json_type, child_plan(version, bucket_count, "s")),
      actual_plan(late_json_type, child_plan(version, bucket_count, "late_only_child")),
    ] of CrystalClick::ObjectSharedAdvancedJsonActualPlan
    policy = if version >= 2
               CrystalClick::ObjectSharedAdvancedJsonWritePolicy.new(actuals, max_ordinary_types: 16)
             else
               nil
             end
    granules = fixture(version).each_slice(2).map(&.to_a).to_a
    target_rows = version == 3 ? 2 : 1
    CrystalClick::WidePartWriter.write_uint64_object_pair(
      path,
      "pk",
      Slice(UInt64).new(ROW_COUNT) { |index| (index + 1).to_u64 },
      "doc",
      stock_schema,
      plan,
      granules,
      rows_per_mark: 2,
      profile: ordinary_profile,
      shared_profile: shared_profile,
      shared_json_policy: policy,
      shared_target_chunk_rows: target_rows,
      frame_bytes: frame_bytes,
    )
    JSON::Any.new({
      "path"                        => JSON::Any.new(path),
      "requested_target_chunk_rows" => JSON::Any.new(target_rows),
      "requested_frame_bytes"       => JSON::Any.new(frame_bytes),
      "policy_enabled"              => JSON::Any.new(!policy.nil?),
      "prepared_actuals"            => JSON::Any.new([
        JSON::Any.new({"type" => JSON::Any.new(arr_json_type.name), "typed_child" => JSON::Any.new("v UInt8"), "dynamic_child" => JSON::Any.new("s String")} of String => JSON::Any),
        JSON::Any.new({"type" => JSON::Any.new(late_json_type.name), "typed_child" => JSON::Any.new("v UInt8"), "dynamic_child" => JSON::Any.new("late_only_child String")} of String => JSON::Any),
      ]),
    } of String => JSON::Any)
  end

  private def canonical_directory(path : String, label : String) : String
    expanded = File.expand_path(path)
    require!(Dir.exists?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded, "#{label} is not canonical")
    expanded
  end

  private def run(args : Array(String)) : Nil
    unless args.size == 2
      raise ArgumentError.new("usage: check_object_shared_json_interop_w241.cr INPUT_JSON OUTPUT_ROOT")
    end
    input_path = File.expand_path(args[0])
    output_root = canonical_directory(args[1], "output root")
    self_test_mark_domain_guard!
    self_test_fixture_value_comparison!
    require!(File.file?(input_path) && !File.symlink?(input_path) && input_path.starts_with?(output_root + File::SEPARATOR), "input must be a plain file below output root")
    input_bytes = File.read(input_path)
    input = JSON.parse(input_bytes)
    require!(input.as_h.keys.sort == ["capture_root", "format", "frame_bytes", "profiles"] && input["format"].as_s == FORMAT_INPUT, "input envelope differs")
    frame_bytes_value = input["frame_bytes"].as_i
    require!(frame_bytes_value == 32 || frame_bytes_value == 64, "requested frame_bytes is outside the fixed 32/64 allowlist")
    frame_bytes = frame_bytes_value.to_i32
    capture_root = canonical_directory(input["capture_root"].as_s, "capture root")
    profiles = input["profiles"].as_a
    observed_ids = profiles.map { |item| item["id"].as_s }
    require!(observed_ids == PROFILE_IDS, "profile IDs/order differ from the fixed eight-profile matrix")
    results = [] of JSON::Any
    profiles.each do |item|
      require!(item.as_h.keys.sort == ["id", "shared_version", "source_part", "string_profile"], "profile input keys differ")
      id = item["id"].as_s
      version = item["shared_version"].as_i
      string_id = item["string_profile"].as_s
      require!(0 <= version && version <= 3 && id.ends_with?(string_id), "profile settings disagree with profile ID")
      source_path = File.expand_path(item["source_part"].as_s)
      require!(Dir.exists?(source_path) && !File.symlink?(source_path) && File.realpath(source_path) == source_path && source_path.starts_with?(capture_root + File::SEPARATOR), "#{id} source part is outside authenticated capture root")
      profile_root = File.join(output_root, id)
      require!(!File.exists?(profile_root) && !File.symlink?(profile_root), "#{id} output directory already exists")
      Dir.mkdir(profile_root, 0o700)
      generated_path = File.join(profile_root, "all_1_1_0")
      source = read_part(source_path, version, string_id, "stock_source")
      writer = write_part(generated_path, version, string_id, frame_bytes)
      generated = read_part(generated_path, version, string_id, "crystal_generated")
      results << JSON::Any.new({
        "id"             => JSON::Any.new(id),
        "shared_version" => JSON::Any.new(version),
        "string_profile" => JSON::Any.new(string_id),
        "source_read"    => source,
        "writer"         => writer,
        "generated_read" => generated,
      } of String => JSON::Any)
    end
    negative_controls = write_negative_controls(
      File.join(output_root, "advanced_chunked_s0", "all_1_1_0"),
      output_root,
    )
    puts JSON::Any.new({
      "format"                => JSON::Any.new(FORMAT_OUTPUT),
      "requested_frame_bytes" => JSON::Any.new(frame_bytes),
      "input_sha256"          => JSON::Any.new(Digest::SHA256.hexdigest(input_bytes)),
      "capture_root"          => JSON::Any.new(capture_root),
      "output_root"           => JSON::Any.new(output_root),
      "profile_ids"           => JSON::Any.new(observed_ids.map { |id| JSON::Any.new(id) }),
      "profiles"              => JSON::Any.new(results),
      "negative_controls"     => negative_controls,
    } of String => JSON::Any).to_json
  rescue ex : Exception
    STDERR.puts "W241 Crystal helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  private def write_negative_controls(source_part : String, output_root : String) : JSON::Any
    controls_root = File.join(output_root, "negative_controls")
    require!(!File.exists?(controls_root) && !File.symlink?(controls_root), "negative-control destination exists")
    Dir.mkdir(controls_root, 0o700)
    data_path = File.join(controls_root, "advanced_chunked_s0_data_corrupt", "all_1_1_0")
    copy_path = File.join(controls_root, "advanced_chunked_s0_copy_truncated", "all_1_1_0")
    data_dir = File.dirname(data_path)
    copy_dir = File.dirname(copy_path)
    Dir.mkdir(data_dir, 0o700)
    Dir.mkdir(copy_dir, 0o700)
    CrystalClick::WidePartWriter.w241_copy_and_mutate_shared_stream(
      source_part,
      data_path,
      "data",
      "last-chunk-only",
      "last-chunk-onlz",
      0,
    )
    # Do not use read_part here: it intentionally starts with a full Object
    # read, whose Copy-vs-Data consistency check rejects this Data-only mutant
    # before reaching its selected-path stage.
    schema = stock_schema
    source_path_reader = CrystalClick::ObjectColumnReader.open(source_part, "doc", schema)
    source_late_rows = render_shared_path(
      source_path_reader.read_shared_path_marks("late", 0, MARK_ROWS.size), 0,
    )
    data_path_reader = CrystalClick::ObjectColumnReader.open(data_path, "doc", schema)
    mutated_late_rows = render_shared_path(
      data_path_reader.read_shared_path_marks("late", 0, MARK_ROWS.size), 0,
    )
    expected_late = JSON.parse("[{\"v\":80,\"late_only_child\":\"last-chunk-onlz\"}]")
    require!(source_late_rows.size == mutated_late_rows.size,
      "W241 Data-negative selected-path row count differs from the source")
    late_pk8_seen = false
    source_late_rows.each_with_index do |source_row, index|
      mutated_row = mutated_late_rows[index]
      source_fields = source_row.as_h
      mutated_fields = mutated_row.as_h
      source_pk = required_json_field(source_fields, "pk").as_i
      require!(required_json_field(mutated_fields, "pk").as_i == source_pk,
        "W241 Data-negative selected-path row ordering differs from the source")
      if source_pk == 8_i64
        late_pk8_seen = true
        require!(required_json_field(mutated_fields, "value") == expected_late,
          "W241 Data-negative direct path did not expose the intended late payload value")
        require!(required_json_field(mutated_fields, "type") == required_json_field(source_fields, "type") &&
                 required_json_field(mutated_fields, "wrapper_type") == required_json_field(source_fields, "wrapper_type"),
          "W241 Data-negative changed the late path's type witness")
      else
        require!(mutated_row == source_row,
          "W241 Data-negative selected-path read changed a row outside pk8")
      end
    end
    require!(late_pk8_seen, "W241 Data-negative selected-path read omitted pk8")

    # Full reconstruction must reject the deliberate Data/Copy disagreement;
    # it must not be misreported as a successful changed Object value.
    full_read_rejected = false
    begin
      CrystalClick::ObjectColumnReader.open(data_path, "doc", schema).read_marks(0, MARK_ROWS.size)
    rescue ex : CrystalClick::CorruptPartError
      require!(ex.message == "Object shared Copy value disagrees with its per-path Dynamic row",
        "W241 Data-negative full read failed for an unexpected reason: #{ex.message}")
      full_read_rejected = true
    end
    require!(full_read_rejected,
      "W241 Data-negative full read unexpectedly accepted the Copy/JSON Data disagreement")
    CrystalClick::WidePartWriter.w241_copy_and_mutate_shared_stream(
      source_part,
      copy_path,
      "copy.values",
      "",
      "",
      1,
    )
    data_inventory = negative_part_inventory(data_path)
    copy_inventory = negative_part_inventory(copy_path)
    JSON::Any.new({
      "data_corrupt_part"        => JSON::Any.new(data_path),
      "data_corrupt_kind"        => JSON::Any.new("same-length late-only payload substitution in ADVANCED Data; Copy bytes preserved"),
      "data_corrupt_inventory"   => data_inventory,
      "copy_truncated_part"      => JSON::Any.new(copy_path),
      "copy_truncated_kind"      => JSON::Any.new("late tail removed from ADVANCED Copy values raw stream; Data bytes preserved"),
      "copy_truncated_inventory" => copy_inventory,
    } of String => JSON::Any)
  end

  private def negative_part_inventory(path : String) : JSON::Any
    assert_checksummed_part!(path)
    substreams = file_bytes(File.join(path, "columns_substreams.txt"), "negative columns_substreams.txt")
    logical = String.new(substreams).lines.map do |line|
      line.strip.sub(/\A\*\s*/, "") if line.starts_with?("\t")
    end.compact
    JSON::Any.new({
      "physical_file_inventory" => physical_inventory(path),
      "columns_substreams_text" => JSON::Any.new(String.new(substreams)),
      "physical_stream_names"   => JSON::Any.new(logical.map { |name| JSON::Any.new(name) }),
      "raw_shared_streams"      => raw_stream_inventory(path, logical),
    } of String => JSON::Any)
  end

  def main(args : Array(String)) : Nil
    run(args)
  end
end

module CrystalClick
  module WidePartWriter
    # W241-only checksum bridge: validates every checksummed file and creates
    # fresh checksum-valid negative parts without widening production APIs.
    # Mirrors ClickHouse IMergeTreeDataPart::getFileNamesWithoutChecksums:
    # columns.txt is always exempt; these are the optional plain metadata
    # sidecars that may also be present outside checksums.txt.
    W241_PLAIN_METADATA_FILES = [
      "columns.txt",
      "columns_substreams.txt",
      "default_compression_codec.txt",
      "metadata_version.txt",
      "txn_version.txt",
    ] of String
    W241_REQUIRED_PLAIN_METADATA_FILES = [
      "columns.txt",
      "columns_substreams.txt",
      "default_compression_codec.txt",
      "metadata_version.txt",
    ] of String

    def self.w241_validate_and_inventory_part(part : String) : Nil
      w241_read_bounded(File.join(part, "checksums.txt"))
      checksums = PartChecksums.open(part)
      names = Dir.children(part).sort
      raise CorruptPartError.new("W241 part has too many files") if names.size > 4096
      raise CorruptPartError.new("W241 checksums file is absent") unless names.includes?("checksums.txt")
      plain_metadata_names = names.select { |name| W241_PLAIN_METADATA_FILES.includes?(name) }
      unless W241_REQUIRED_PLAIN_METADATA_FILES.all? { |name| plain_metadata_names.includes?(name) }
        raise CorruptPartError.new("W241 required plain metadata is absent")
      end
      expected_names = checksums.entries.keys.sort
      actual_names = names.reject do |name|
        name == "checksums.txt" || W241_PLAIN_METADATA_FILES.includes?(name)
      end
      raise CorruptPartError.new("W241 checksums roster differs from physical files") unless actual_names == expected_names
      total_size = 0_i64
      names.each do |name|
        next if name == "checksums.txt"
        raise CorruptPartError.new("W241 unsafe part filename") unless /\A[a-zA-Z0-9_.-]+\z/.matches?(name)
        file_path = File.join(part, name)
        raise CorruptPartError.new("W241 checksum input is absent or symlinked") if File.symlink?(file_path) || !File.file?(file_path)
        physical = w241_read_bounded(file_path)
        total_size += physical.size.to_i64
        raise CorruptPartError.new("W241 part exceeds total-size bound") if total_size > 64_i64 * 1024 * 1024
        next if W241_PLAIN_METADATA_FILES.includes?(name)

        entry = checksums.entry(name) || raise CorruptPartError.new("W241 checksum entry disappeared")
        raise CorruptPartError.new("W241 physical size differs for #{name}") unless physical.size.to_u64 == entry.physical_size
        raise CorruptPartError.new("W241 physical hash differs for #{name}") unless CityHashV1.file_hash(physical) == entry.file_hash
        if entry.compressed
          raw = if physical.empty?
                  Bytes.empty
                else
                  CompressedBlock.decode_all(physical, 64_i64 * 1024 * 1024, 64_i64 * 1024 * 1024, 64_i64 * 1024 * 1024)
                end
          raise CorruptPartError.new("W241 uncompressed size differs for #{name}") unless raw.size.to_u64 == entry.uncompressed_size
          # PartChecksums currently exposes physical file hashes and decoded
          # extents; compressed-frame integrity is independently checked by
          # decode_all. Native CHECK remains the independent storage validator.
        end
      end
      nil
    end

    def self.w241_copy_and_mutate_shared_stream(
      source : String,
      destination : String,
      stream_suffix : String,
      needle : String,
      replacement : String,
      truncate_tail_bytes : Int32,
    ) : Nil
      raise CorruptPartError.new("W241 source part is missing or symlinked") if !Dir.exists?(source) || File.symlink?(source)
      raise CorruptPartError.new("W241 negative destination already exists") if File.exists?(destination) || File.symlink?(destination)
      raise ArgumentError.new("W241 negative stream mutation mode is invalid") if truncate_tail_bytes < 0
      if truncate_tail_bytes == 0
        raise ArgumentError.new("W241 same-length payload mutation is reserved for shared Data") unless stream_suffix == "data"
      else
        raise ArgumentError.new("W241 tail truncation is reserved for Copy values") unless stream_suffix == "copy.values"
      end
      Dir.mkdir(destination, 0o700)
      copied_size = 0_i64
      source_file_sha256 = {} of String => String
      raise CorruptPartError.new("W241 source part has too many files") if Dir.children(source).size > 4096
      Dir.children(source).sort.each do |name|
        source_path = File.join(source, name)
        raise CorruptPartError.new("W241 source file is non-regular") if File.symlink?(source_path) || !File.file?(source_path)
        bytes = w241_read_bounded(source_path)
        copied_size += bytes.size.to_i64
        raise CorruptPartError.new("W241 source part exceeds total-size bound") if copied_size > 64_i64 * 1024 * 1024
        source_file_sha256[name] = Digest::SHA256.hexdigest(bytes)
        File.open(File.join(destination, name), "wb") do |file|
          file.write(bytes)
        end
      end

      logical_names = String.new(w241_read_bounded(File.join(destination, "columns_substreams.txt"))).lines.map do |line|
        line.strip.sub(/\A\*\s*/, "") if line.starts_with?("\t")
      end.compact
      candidates = logical_names.select do |name|
        if stream_suffix == "data"
          /\Adoc\.object_shared_data\.\d+\.data\z/.matches?(name)
        else
          name == "doc.object_shared_data.copy.values"
        end
      end
      raise CorruptPartError.new("W241 negative target stream is absent or ambiguous") unless candidates.size == 1 || (stream_suffix == "data" && !candidates.empty?)
      target = if stream_suffix == "data"
                 candidates.find do |name|
                   physical = read_stream_raw(destination, name)
                   contains_bytes?(physical, needle.to_slice)
                 end || raise CorruptPartError.new("W241 late payload is absent from shared Data")
               else
                 candidates.first
               end
      original_raw = read_stream_raw(destination, target)
      replacement_offset = nil.as(Int32?)
      transformed = if truncate_tail_bytes > 0
                      raise CorruptPartError.new("W241 Copy lane is too short to truncate") if original_raw.size <= truncate_tail_bytes
                      Bytes.new(original_raw.size - truncate_tail_bytes) { |index| original_raw[index] }
                    else
                      raise CorruptPartError.new("W241 Data payload mutation must change equal-length nonempty text") if needle.empty? || needle.bytesize != replacement.bytesize || needle == replacement
                      rewritten = copy_bytes(original_raw)
                      replacement_offset = replace_once!(rewritten, needle.to_slice, replacement.to_slice)
                      raise CorruptPartError.new("W241 Data payload substitution did not match exactly once") unless replacement_offset
                      verify_exact_payload_replacement!(original_raw, rewritten, replacement_offset.not_nil!,
                        needle.to_slice, replacement.to_slice)
                      rewritten
                    end
      stream_stem = StreamName.hash(target)
      data_path = File.join(destination, "#{stream_stem}.bin")
      original_physical = w241_read_bounded(data_path)
      mark_path = File.join(destination, "#{stream_stem}.mrk2")
      original_marks = w241_read_bounded(mark_path)
      if truncate_tail_bytes > 0
        # Copy truncation intentionally retains its existing invalid-tail
        # control: collapse to one frame and repair the Copy marks to that
        # representation. This is separate from the equal-length Data control.
        frame = StreamEncoding.encode_lz4_frame(transformed)
        encoded = CompressedBlock.decode_frame(frame, 0_i64, 16_i64 * 1024 * 1024, 16_i64 * 1024 * 1024)
        raise CorruptPartError.new("W241 reencoded Copy target is not exactly one valid frame") unless encoded.end_offset == frame.size.to_i64 && encoded.output.size == transformed.size
        File.open(data_path, "wb") { |file| file.write(frame) }
        repair_marks_for_reencoded_stream(destination, stream_stem, original_physical, original_marks,
          frame.size.to_i64, original_raw.size, transformed.size)
      else
        raise CorruptPartError.new("W241 Data payload mutation changed the logical stream length") unless transformed.size == original_raw.size
        frame_preserving = reencode_literal_frames_preserving_geometry(original_physical, original_raw, transformed)
        File.open(data_path, "wb") { |file| file.write(frame_preserving) }
        raise CorruptPartError.new("W241 Data mutation unexpectedly changed the shared mark file") unless w241_read_bounded(mark_path) == original_marks
      end
      w241_rebuild_checksums(destination)
      w241_validate_and_inventory_part(destination)
      changed_names = if truncate_tail_bytes > 0
                        ["#{stream_stem}.bin", "#{stream_stem}.mrk2", "checksums.txt"]
                      else
                        ["#{stream_stem}.bin", "checksums.txt"]
                      end
      w241_assert_changed_file_roster!(destination, source_file_sha256, changed_names)
      nil
    end

    private def self.copy_bytes(source : Bytes) : Bytes
      Bytes.new(source.size) { |index| source[index] }
    end

    private def self.verify_exact_payload_replacement!(original : Bytes, transformed : Bytes, offset : Int32,
                                                       needle : Bytes, replacement : Bytes) : Nil
      if original.size != transformed.size || needle.empty? || needle.size != replacement.size || offset < 0 ||
         offset > original.size - needle.size
        raise CorruptPartError.new("W241 Data payload replacement extent is invalid")
      end
      needle.size.times do |index|
        if original[offset + index] != needle[index]
          raise CorruptPartError.new("W241 Data payload replacement source differs")
        end
      end
      original.size.times do |index|
        expected = if index >= offset && index < offset + needle.size
                     replacement[index - offset]
                   else
                     original[index]
                   end
        if transformed[index] != expected
          raise CorruptPartError.new("W241 Data mutation changed bytes outside the intended late payload")
        end
      end
      nil
    end

    private def self.reencode_literal_frames_preserving_geometry(
      original_physical : Bytes,
      original_raw : Bytes,
      transformed_raw : Bytes,
    ) : Bytes
      limits = w241_stream_limits
      unless original_raw.size == transformed_raw.size
        raise CorruptPartError.new("W241 Data frame-preserving mutation changed logical size")
      end
      original_index = CompressedFrameIndex.new(
        original_physical,
        limits,
        CompressedStreamBudget.new(limits),
      )
      unless original_index.logical_size == original_raw.size.to_i64 && !original_index.frames.empty?
        raise CorruptPartError.new("W241 Data source frame index differs from its decoded lane")
      end

      io = IO::Memory.new
      original_index.frames.each do |descriptor|
        unless descriptor.method == CompressedBlock::METHOD_LZ4
          raise CorruptPartError.new("W241 Data source frame is not literal-compatible LZ4")
        end
        frame_size = descriptor.end_offset - descriptor.compressed_offset
        frame_raw_size = descriptor.decompressed_size
        source_frame = CompressedBlock.decode_frame(
          original_physical,
          descriptor.compressed_offset,
          limits.max_frame_compressed_bytes,
          limits.max_frame_decompressed_bytes,
        )
        unless source_frame.end_offset == descriptor.end_offset && source_frame.output.size.to_i64 == frame_raw_size
          raise CorruptPartError.new("W241 Data source frame extent differs from its index")
        end
        source_raw_slice = w241_slice!(original_raw, descriptor.logical_start, frame_raw_size, "source frame raw")
        unless bytes_equal?(source_frame.output, source_raw_slice)
          raise CorruptPartError.new("W241 Data source frame differs from decoded lane bytes")
        end
        canonical_source_frame = StreamEncoding.encode_lz4_frame(source_frame.output)
        source_physical_slice = w241_slice!(original_physical, descriptor.compressed_offset, frame_size,
          "source frame physical")
        unless canonical_source_frame.size.to_i64 == frame_size && bytes_equal?(canonical_source_frame, source_physical_slice)
          raise CorruptPartError.new("W241 Data source is not exact literal-LZ4 output; refusing coordinate rebase")
        end

        transformed_slice = w241_slice!(transformed_raw, descriptor.logical_start, frame_raw_size,
          "transformed frame raw")
        encoded_frame = StreamEncoding.encode_lz4_frame(transformed_slice)
        unless encoded_frame.size.to_i64 == frame_size
          raise CorruptPartError.new("W241 Data transformed literal frame changed a physical frame extent")
        end
        decoded_frame = CompressedBlock.decode_frame(
          encoded_frame,
          0_i64,
          limits.max_frame_compressed_bytes,
          limits.max_frame_decompressed_bytes,
        )
        unless decoded_frame.end_offset == frame_size && bytes_equal?(decoded_frame.output, transformed_slice)
          raise CorruptPartError.new("W241 Data transformed frame failed its exact decoded-content guard")
        end
        io.write(encoded_frame)
      end

      memory = io.to_slice
      physical = Bytes.new(memory.size) { |index| memory[index] }
      unless physical.size.to_i64 == original_physical.size.to_i64
        raise CorruptPartError.new("W241 Data frame-preserving mutation changed physical lane size")
      end
      transformed_index = CompressedFrameIndex.new(
        physical,
        limits,
        CompressedStreamBudget.new(limits),
      )
      unless transformed_index.frames.size == original_index.frames.size &&
             transformed_index.logical_size == original_index.logical_size
        raise CorruptPartError.new("W241 Data transformed frame roster differs from source")
      end
      original_index.frames.each_with_index do |before, index|
        after = transformed_index.frames[index]
        unless after.compressed_offset == before.compressed_offset && after.end_offset == before.end_offset &&
               after.logical_start == before.logical_start && after.logical_end == before.logical_end &&
               after.method == before.method
          raise CorruptPartError.new("W241 Data transformed frame coordinates differ from source")
        end
      end
      decoded = CompressedBlock.decode_all(
        physical,
        limits.max_frame_compressed_bytes,
        limits.max_frame_decompressed_bytes,
        limits.max_decoded_bytes,
      )
      unless bytes_equal?(decoded, transformed_raw)
        raise CorruptPartError.new("W241 Data transformed frame roster decodes to different lane bytes")
      end
      physical
    end

    private def self.w241_stream_limits : CompressedStreamLimits
      CompressedStreamLimits.new(
        max_file_bytes: 16 * 1024 * 1024,
        max_mark_bytes: 16 * 1024 * 1024,
        max_frame_compressed_bytes: 16 * 1024 * 1024,
        max_frame_decompressed_bytes: 16 * 1024 * 1024,
        max_records: 4096,
        max_decoded_bytes: 16 * 1024 * 1024,
        max_result_bytes: 16 * 1024 * 1024,
      )
    end

    private def self.w241_slice!(source : Bytes, offset : Int64, size : Int64, label : String) : Bytes
      if offset < 0 || size < 0 || offset > source.size.to_i64 - size || size > Int32::MAX
        raise CorruptPartError.new("W241 #{label} slice is outside its bounded source")
      end
      Bytes.new(size.to_i) { |index| source[offset.to_i + index] }
    end

    private def self.bytes_equal?(left : Bytes, right : Bytes) : Bool
      return false unless left.size == right.size
      left.size.times do |index|
        return false if left[index] != right[index]
      end
      true
    end

    private def self.w241_assert_changed_file_roster!(part : String, source_sha256 : Hash(String, String),
                                                      expected_changed : Array(String)) : Nil
      actual_names = Dir.children(part).sort
      unless actual_names == source_sha256.keys.sort
        raise CorruptPartError.new("W241 negative mutation changed the physical file roster")
      end
      changed = [] of String
      actual_names.each do |name|
        physical = w241_read_bounded(File.join(part, name))
        source_digest = source_sha256[name]? || raise CorruptPartError.new("W241 source digest is absent for #{name}")
        changed << name if Digest::SHA256.hexdigest(physical) != source_digest
      end
      unless changed.sort == expected_changed.sort
        raise CorruptPartError.new("W241 negative mutation changed files outside its exact target roster")
      end
      nil
    end

    private def self.read_stream_raw(part : String, logical_name : String) : Bytes
      physical_path = File.join(part, "#{StreamName.hash(logical_name)}.bin")
      raise CorruptPartError.new("W241 stream is absent or symlinked") if File.symlink?(physical_path) || !File.file?(physical_path)
      physical = w241_read_bounded(physical_path)
      raise CorruptPartError.new("W241 compressed stream is empty") if physical.empty?
      CompressedBlock.decode_all(physical, 64_i64 * 1024 * 1024, 64_i64 * 1024 * 1024, 64_i64 * 1024 * 1024)
    end

    private def self.w241_read_bounded(path : String) : Bytes
      raise CorruptPartError.new("W241 read target is absent, non-regular, or symlinked") if File.symlink?(path) || !File.file?(path)
      size = File.size(path)
      raise CorruptPartError.new("W241 file exceeds 16 MiB pre-read bound: #{path}") if size > 16_i64 * 1024 * 1024
      text = File.read(path)
      raise CorruptPartError.new("W241 file changed while reading: #{path}") if text.bytesize.to_i64 != size
      Bytes.new(text.bytesize) { |index| text.to_slice[index] }
    end

    private def self.contains_bytes?(haystack : Bytes, needle : Bytes) : Bool
      return false if needle.empty? || needle.size > haystack.size
      0.upto(haystack.size - needle.size) do |start|
        matched = true
        needle.size.times do |offset|
          matched = false if haystack[start + offset] != needle[offset]
        end
        return true if matched
      end
      false
    end

    private def self.replace_once!(haystack : Bytes, needle : Bytes, replacement : Bytes) : Int32?
      return nil if needle.empty? || needle.size != replacement.size || needle.size > haystack.size
      matches = [] of Int32
      0.upto(haystack.size - needle.size) do |start|
        matched = true
        needle.size.times do |offset|
          matched = false if haystack[start + offset] != needle[offset]
        end
        matches << start if matched
      end
      return nil unless matches.size == 1
      needle.size.times { |offset| haystack[matches.first + offset] = replacement[offset] }
      matches.first
    end

    private def self.repair_marks_for_reencoded_stream(
      part : String,
      stream_stem : String,
      original_physical : Bytes,
      original_marks : Bytes,
      replacement_physical_size : Int64,
      original_raw_size : Int32,
      raw_size : Int32,
    ) : Nil
      mark_path = File.join(part, "#{stream_stem}.mrk2")
      raise CorruptPartError.new("W241 mark file is not plain triples") unless original_marks.size % 24 == 0
      words = original_marks.to_a.each_slice(8).map do |octets|
        octets.each_with_index.reduce(0_u64) { |value, (byte, index)| value | (byte.to_u64 << (index * 8)) }
      end.to_a
      raise CorruptPartError.new("W241 target mark count differs from fixture") unless words.size == 15
      limits = w241_stream_limits
      index = CompressedFrameIndex.new(original_physical, limits, CompressedStreamBudget.new(limits))
      raise CorruptPartError.new("W241 mark source decoded length differs") unless index.logical_size == original_raw_size.to_i64
      io = IO::Memory.new
      words.each_slice(3) do |triple|
        compressed_offset, decompressed_offset, rows = triple
        terminal = compressed_offset == original_physical.size.to_u64 && decompressed_offset == 0_u64
        logical_offset = index.logical_position(compressed_offset, decompressed_offset, terminal)
        raise CorruptPartError.new("W241 logical mark exceeds original stream") if logical_offset > original_raw_size
        new_compressed_offset = terminal ? replacement_physical_size.to_u64 : 0_u64
        new_decompressed_offset = terminal ? 0_u64 : Math.min(logical_offset, raw_size.to_i64).to_u64
        StreamEncoding.write_uint64_le(io, new_compressed_offset)
        StreamEncoding.write_uint64_le(io, new_decompressed_offset)
        StreamEncoding.write_uint64_le(io, rows)
      end
      File.open(mark_path, "wb") { |file| file.write(io.to_slice) }
      nil
    end

    private def self.w241_rebuild_checksums(part : String) : Nil
      w241_read_bounded(File.join(part, "checksums.txt"))
      original = PartChecksums.open(part)
      records = [] of ChecksumRecord
      total_size = 0_i64
      raise CorruptPartError.new("W241 checksum part has too many files") if original.entries.size > 4096
      original.entries.keys.sort.each do |name|
        path = File.join(part, name)
        raise CorruptPartError.new("W241 checksum repair input is missing or symlinked") if File.symlink?(path) || !File.file?(path)
        physical = w241_read_bounded(path)
        total_size += physical.size.to_i64
        raise CorruptPartError.new("W241 checksum part exceeds total-size bound") if total_size > 64_i64 * 1024 * 1024
        prior = original.entry(name) || raise CorruptPartError.new("W241 checksum repair entry disappeared")
        if prior.compressed
          raw = if physical.empty?
                  Bytes.empty
                else
                  CompressedBlock.decode_all(physical, 64_i64 * 1024 * 1024, 64_i64 * 1024 * 1024, 64_i64 * 1024 * 1024)
                end
          records << ChecksumRecord.new(name, physical.size.to_u64, CityHashV1.file_hash(physical), true,
            raw.size.to_u64, CityHashV1.file_hash(raw))
        else
          records << ChecksumRecord.new(name, physical.size.to_u64, CityHashV1.file_hash(physical), false)
        end
      end
      PartChecksumsWriter.write(part, records)
      w241_read_bounded(File.join(part, "checksums.txt"))
      repaired = PartChecksums.open(part)
      raise CorruptPartError.new("W241 checksum repair changed the file roster") unless repaired.entries.keys.sort == original.entries.keys.sort
      nil
    end
  end
end

CheckObjectSharedJSONInteropW241.main(ARGV)
