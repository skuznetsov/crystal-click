require "../src/crystal_click"
require "digest/sha256"
require "json"

module CheckObjectDescendantJSONW243
  extend self

  FORMAT_INPUT         = "object_descendant_json_w243_input_v1"
  FORMAT_OUTPUT        = "object_descendant_json_w243_helper_v1"
  ROW_COUNT            = 8
  MARK_ROWS            = [2_u64, 2_u64, 2_u64, 2_u64]
  MAX_PART_FILE_BYTES  = 16_i64 * 1024 * 1024
  MAX_PART_TOTAL_BYTES = 64_i64 * 1024 * 1024
  MAX_PART_FILES       = 4096
  PLAIN_METADATA_FILES = [
    "columns.txt",
    "columns_substreams.txt",
    "default_compression_codec.txt",
    "metadata_version.txt",
    "txn_version.txt",
  ] of String
  REQUIRED_PLAIN_METADATA_FILES = [
    "columns.txt",
    "columns_substreams.txt",
    "default_compression_codec.txt",
    "metadata_version.txt",
  ] of String
  PROFILE_SPECS = [
    {"map_s0", 0, "s0"},
    {"map_s1", 0, "s1"},
    {"map_with_buckets_s0", 1, "s0"},
    {"map_with_buckets_s1", 1, "s1"},
    {"advanced_s0", 2, "s0"},
    {"advanced_s1", 2, "s1"},
    {"advanced_chunked_s0", 3, "s0"},
    {"advanced_chunked_s1", 3, "s1"},
  ]
  BOUNDED_WINDOWS = [
    {"middle", 1, 2},
    {"last", 3, 1},
    {"empty_interior", 2, 0},
    {"zero_count_end", 4, 0},
  ]
  EXPECTED_ITEMS_BY_PK = {
    1 => {"populated", [7_i64, 8_i64]},
    2 => {"empty", [] of Int64},
    3 => {"absent", [] of Int64},
    4 => {"missing_payload", [] of Int64},
    5 => {"populated", [7_i64]},
    6 => {"missing_payload", [] of Int64},
    7 => {"empty", [] of Int64},
    8 => {"populated", [77_i64]},
  }

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W243 helper: #{message}") unless condition
  end

  private def json(value : String) : JSON::Any
    JSON::Any.new(value)
  end

  private def json(value : Int64) : JSON::Any
    JSON::Any.new(value)
  end

  private def json(value : Bool) : JSON::Any
    JSON::Any.new(value)
  end

  private def json_strings(values : Array(String)) : JSON::Any
    JSON::Any.new(values.map { |value| json(value) })
  end

  private def string_profile(name : String) : CrystalClick::BinaryBulkProfile
    case name
    when "s0" then CrystalClick::BinaryBulkProfile.single_stream
    when "s1" then CrystalClick::BinaryBulkProfile.with_size_stream
    else           raise CrystalClick::CorruptPartError.new("W243 helper: unknown String profile")
    end
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

  private def leaf_json_type(role : String) : CrystalClick::BinaryDataType
    leaf_type = role == "normal" ? uint8_type : (role == "type_only" ? int64_type : raise ArgumentError.new("unknown role"))
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {"v" => leaf_type} of String => CrystalClick::BinaryDataType,
    )
  end

  private def outer_actual_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.tuple([
      outer_json_type,
      CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.dynamic(max_types: 1)),
    ] of CrystalClick::BinaryDataType)
  end

  private def leaf_value(type : CrystalClick::BinaryDataType, role : String, number : Int64) : CrystalClick::BinaryValue
    leaf_json = leaf_json_type(role)
    value_type = role == "normal" ? uint8_type : int64_type
    value = if value_type.tag == CrystalClick::BinaryDataType::TAG_UINT8
              CrystalClick::BinaryValue.fixed(value_type, Bytes[number.to_u8])
            else
              CrystalClick::BinaryValue.int64(number)
            end
    row = CrystalClick::BinaryJsonRow.new(
      type,
      [{"v", value}] of Tuple(String, CrystalClick::BinaryValue),
    )
    CrystalClick::BinaryValue.json(leaf_json, row)
  end

  private def item_array_type(role : String) : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.array(leaf_json_type(role))
  end

  private def outer_value(role : String, pk : Int32) : CrystalClick::BinaryValue
    actual = outer_actual_type
    parent_json = outer_json_type
    items_type = item_array_type(role)
    item_values = case pk
                  when 1    then [leaf_value(leaf_json_type(role), role, 7_i64), leaf_value(leaf_json_type(role), role, 8_i64)] of CrystalClick::BinaryValue
                  when 2, 7 then [] of CrystalClick::BinaryValue
                  when 5    then [leaf_value(leaf_json_type(role), role, 7_i64)] of CrystalClick::BinaryValue
                  when 8    then [leaf_value(leaf_json_type(role), role, 77_i64)] of CrystalClick::BinaryValue
                  else           [] of CrystalClick::BinaryValue
                  end
    fields = [{"v", CrystalClick::BinaryValue.fixed(uint8_type, Bytes[42_u8])}] of Tuple(String, CrystalClick::BinaryValue)
    unless pk == 3
      fields << {"items", CrystalClick::BinaryValue.array(items_type, item_values)}
    end
    parent_row = CrystalClick::BinaryJsonRow.new(parent_json, fields)
    CrystalClick::BinaryValue.tuple(
      actual,
      [
        CrystalClick::BinaryValue.json(parent_json, parent_row),
        CrystalClick::BinaryValue.array(actual.child_at(1), [] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue,
    )
  end

  private def fixture_documents(role : String) : Array(CrystalClick::ObjectDocument)
    documents = [] of CrystalClick::ObjectDocument
    1.upto(ROW_COUNT) do |pk|
      fields = case pk
               when 4
                 {} of String => CrystalClick::BinaryValue
               when 6
                 {"payload" => CrystalClick::BinaryValue.null} of String => CrystalClick::BinaryValue
               else
                 {"payload" => outer_value(role, pk)} of String => CrystalClick::BinaryValue
               end
      documents << CrystalClick::ObjectDocument.new(fields)
    end
    documents
  end

  private def child_plan(role : String, version : Int32, buckets : UInt64) : CrystalClick::ObjectDocumentPlan
    outer_json = outer_json_type
    leaf_json = leaf_json_type(role)
    array_actual = CrystalClick::BinaryDataType.array(leaf_json)
    array_structure = CrystalClick::DynamicStructure.new(
      [array_actual, string_type] of CrystalClick::BinaryDataType,
    )
    grandchild_structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(
        [] of String,
        shared_data_version: version.to_u64,
        bucket_count: buckets,
      ),
      {} of String => CrystalClick::DynamicStructure,
    )
    grandchild_plan = CrystalClick::ObjectDocumentPlan.new(
      grandchild_structures,
      leaf_json.json_type.not_nil!.typed_paths,
    )
    array_key = CrystalClick::BinaryDynamicJsonLeafKey.new(
      "root",
      array_structure.canonical_index_for(array_actual),
      [0_i32] of Int32,
    )
    child_structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(
        ["items"] of String,
        shared_data_version: version.to_u64,
        bucket_count: buckets,
      ),
      {"items" => array_structure} of String => CrystalClick::DynamicStructure,
    )
    child_leaf_plans = {
      "items" => [{array_key, grandchild_plan}] of Tuple(
        CrystalClick::BinaryDynamicJsonLeafKey,
        CrystalClick::ObjectDocumentPlan,
      ),
    } of String => Array(Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan))
    CrystalClick::ObjectDocumentPlan.new(
      child_structures,
      outer_json.json_type.not_nil!.typed_paths,
      root_dynamic_json_object_leaf_plans: child_leaf_plans,
    )
  end

  private def write_plan(
    role : String,
    version : Int32,
    buckets : UInt64,
  ) : Tuple(CrystalClick::ObjectDocumentPlan, CrystalClick::ObjectSharedAdvancedJsonWritePolicy)
    actual = outer_actual_type
    child = child_plan(role, version, buckets)
    prepared = CrystalClick::ObjectSharedAdvancedJsonActualPlan.new(
      actual,
      [{[0_i32] of Int32, child}] of Tuple(Array(Int32), CrystalClick::ObjectDocumentPlan),
    )
    policy = CrystalClick::ObjectSharedAdvancedJsonWritePolicy.new(
      [prepared] of CrystalClick::ObjectSharedAdvancedJsonActualPlan,
      max_ordinary_types: 16,
    )
    object = CrystalClick::ObjectStructure.new(
      [] of String,
      shared_data_version: version.to_u64,
      bucket_count: buckets,
    )
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      object,
      {} of String => CrystalClick::DynamicStructure,
    )
    plan = CrystalClick::ObjectDocumentPlan.new(
      structures,
      {} of String => CrystalClick::BinaryDataType,
    )
    {plan, policy}
  end

  private def render_value(value : CrystalClick::BinaryValue, depth : Int32 = 0) : JSON::Any
    require!(depth <= 24, "fixture value exceeds its rendering depth bound")
    return JSON::Any.new(nil) if value.is_null?
    type = value.type
    case type.tag
    when CrystalClick::BinaryDataType::TAG_STRING
      json(value.as_string)
    when CrystalClick::BinaryDataType::TAG_INT64
      json(value.as_int64)
    when CrystalClick::BinaryDataType::TAG_UINT8
      json(value.byte_at(0).to_i64)
    when CrystalClick::BinaryDataType::TAG_ARRAY,
         CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE,
         CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
      JSON::Any.new(Array(JSON::Any).new(value.child_count) do |index|
        render_value(value.child_at(index), depth + 1)
      end)
    when CrystalClick::BinaryDataType::TAG_JSON
      row = value.json_row
      fields = {} of String => JSON::Any
      row.path_count.times do |index|
        path = row.path_at(index)
        fields[path] = render_value(row.value_for(path).not_nil!, depth + 1)
      end
      JSON::Any.new(fields)
    when CrystalClick::BinaryDataType::TAG_DYNAMIC
      if value.child_count == 0
        JSON::Any.new(nil)
      else
        require!(value.child_count == 1, "fixture Dynamic has multiple children")
        render_value(value.child_at(0), depth + 1)
      end
    else
      raise CrystalClick::CorruptPartError.new("W243 helper: unrostered value type #{type.name}")
    end
  end

  private def render_documents(
    marks : Array(Array(CrystalClick::ObjectDocument)),
    first_mark : Int32 = 0,
  ) : Array(JSON::Any)
    rows = [] of JSON::Any
    marks.each_with_index do |mark, mark_index|
      mark.each_with_index do |document, row_index|
        fields = {} of String => JSON::Any
        document.paths.each { |path| fields[path] = render_value(document.value_for(path)) }
        rows << JSON::Any.new({
          "pk"  => json((first_mark * 2 + mark_index * 2 + row_index + 1).to_i64),
          "doc" => JSON::Any.new(fields),
        } of String => JSON::Any)
      end
    end
    rows
  end

  private def transport_actual(value : CrystalClick::BinaryValue) : Tuple(String, CrystalClick::BinaryValue?)
    expected_wrapper = CrystalClick::BinaryDataType.dynamic(
      max_types: CrystalClick::ObjectSharedAdvancedChunkCodec::JSON_DYNAMIC_MAX_TYPES,
    )
    require!(value.type == expected_wrapper, "selected payload carrier descriptor differs")
    if value.is_null?
      require!(value.child_count == 0, "NULL selected payload carrier has a selected child")
      return {"NULL", nil}
    end
    require!(value.child_count == 1, "selected payload carrier selected-child count differs")
    child = value.child_at(0)
    require!(child.type == outer_actual_type && !child.is_null? && child.child_count == 2,
      "selected payload actual Tuple descriptor or shape differs")
    {child.type.name, child}
  end

  private def render_shared_path(marks : Array(Array(CrystalClick::BinaryValue)), first_mark : Int32 = 0) : Array(JSON::Any)
    rows = [] of JSON::Any
    marks.each_with_index do |mark, mark_index|
      mark.each_with_index do |value, row_index|
        actual_type, actual = transport_actual(value)
        rows << JSON::Any.new({
          "pk"           => json((first_mark * 2 + mark_index * 2 + row_index + 1).to_i64),
          "type"         => json(actual_type),
          "wrapper_type" => json(value.type.name),
          "value"        => actual ? render_value(actual) : JSON::Any.new(nil),
        } of String => JSON::Any)
      end
    end
    rows
  end

  private def item_witnesses(parent_json : CrystalClick::BinaryValue, role : String) : Tuple(String, Array(JSON::Any))
    row = parent_json.json_row
    raw_items = row.value_for("items")
    return {"absent", [] of JSON::Any} unless raw_items
    actual_type = item_array_type(role)
    items = raw_items.not_nil!
    require!(items.type == actual_type, "descendant items Array(JSON) descriptor differs")
    output = [] of JSON::Any
    items.child_count.times do |index|
      item = items.child_at(index)
      require!(item.type == leaf_json_type(role), "grandchild JSON descriptor differs")
      item_row = item.json_row
      require!(item_row.path_count == 1 && item_row.path_at(0) == "v", "grandchild JSON path roster differs")
      v = item_row.value_for("v").not_nil!
      expected_v_type = role == "normal" ? uint8_type : int64_type
      require!(v.type == expected_v_type, "grandchild typed v descriptor differs")
      output << JSON::Any.new({
        "index"       => json(index.to_i64),
        "actual_type" => json(item.type.name),
        "paths_types" => JSON::Any.new({"v" => json(v.type.name)} of String => JSON::Any),
        "v_type"      => json(v.type.name),
        "v_value"     => render_value(v),
      } of String => JSON::Any)
    end
    {items.child_count == 0 ? "empty" : "populated", output}
  end

  private def nested_type_witnesses(
    marks : Array(Array(CrystalClick::ObjectDocument)),
    role : String,
  ) : Array(JSON::Any)
    actual_type = outer_actual_type
    parent_descriptor = outer_json_type
    leaf_descriptor = leaf_json_type(role)
    items_descriptor = item_array_type(role)
    output = [] of JSON::Any
    marks.each_with_index do |mark, mark_index|
      mark.each_with_index do |document, row_index|
        pk = mark_index * 2 + row_index + 1
        state = "missing"
        payload_actual = "MISSING"
        parent_v = JSON::Any.new(nil)
        items_state = "missing_payload"
        items_actual = "MISSING"
        nested = [] of JSON::Any
        if document.paths.includes?("payload")
          payload = document.value_for("payload")
          if payload.type.tag == CrystalClick::BinaryDataType::TAG_NOTHING
            require!(payload.type == CrystalClick::BinaryDataType.primitive("Nothing") &&
                     payload.is_null? && payload.child_count == 0,
              "missing payload sentinel differs at pk #{pk}")
            # ObjectDocument materialization normalizes an input Nothing path
            # to absence; retain that exact read observation.
          else
            require!(payload.type == actual_type && !payload.is_null? && payload.child_count == 2,
              "outer tuple actual descriptor or shape differs at pk #{pk}")
            state = "value"
            payload_actual = payload.type.name
            parent_json = payload.child_at(0)
            require!(parent_json.type == parent_descriptor, "parent JSON descriptor differs at pk #{pk}")
            parent_row = parent_json.json_row
            parent_value = parent_row.value_for("v").not_nil!
            require!(parent_value.type == uint8_type, "parent typed v descriptor differs at pk #{pk}")
            parent_v = render_value(parent_value)
            items_state, nested = item_witnesses(parent_json, role)
            items_actual = {"absent", "missing_payload"}.includes?(items_state) ? "MISSING" : items_descriptor.name
          end
        end
        # Check every row, including absent/NULL parent payloads. Keeping this
        # oracle outside the present-payload branch prevents missing rows from
        # escaping the finite fixture contract.
        expected_items = EXPECTED_ITEMS_BY_PK[pk]
        require!(items_state == expected_items[0], "descendant items state differs at pk #{pk}")
        nested_values = nested.map { |item| item["v_value"].as_i64 }
        require!(nested_values == expected_items[1], "descendant JSON values differ at pk #{pk}")
        output << JSON::Any.new({
          "pk"                  => json(pk.to_i64),
          "payload_state"       => json(state),
          "payload_actual_type" => json(payload_actual),
          "parent_json_type"    => json(parent_descriptor.name),
          "parent_v_type"       => json("UInt8"),
          "parent_v"            => parent_v,
          "items_state"         => json(items_state),
          "items_actual_type"   => json(items_actual),
          "leaf_json_type"      => json(leaf_descriptor.name),
          "nested_path"         => json("payload.1.items[]"),
          "nested_items"        => JSON::Any.new(nested),
        } of String => JSON::Any)
      end
    end
    late = output.last? || raise CrystalClick::CorruptPartError.new("W243 helper: late witness row is absent")
    require!(late["pk"].as_i64 == ROW_COUNT && late["items_state"].as_s == "populated" &&
             late["nested_items"].as_a.size == 1 && late["nested_items"].as_a[0]["v_value"].as_i64 == 77,
      "late descendant value is not confined to the final real mark")
    output
  end

  private def bounded_windows(
    path : String,
    schema : CrystalClick::ObjectDocumentSchema,
    full_marks : Array(Array(CrystalClick::ObjectDocument)),
    path_marks : Array(Array(CrystalClick::BinaryValue)),
  ) : Array(JSON::Any)
    output = [] of JSON::Any
    BOUNDED_WINDOWS.each do |window, first_mark, mark_count|
      expected_counts = Array(UInt64).new(mark_count) { |offset| MARK_ROWS[first_mark + offset] }
      expected_docs = Array(Array(CrystalClick::ObjectDocument)).new(mark_count) { |offset| full_marks[first_mark + offset] }
      expected_doc_rows = render_documents(expected_docs, first_mark)
      actual_docs = CrystalClick::ObjectColumnReader.open(path, "doc", schema).read_marks(first_mark, mark_count)
      actual_doc_rows = render_documents(actual_docs, first_mark)
      actual_doc_counts = actual_docs.map { |mark| mark.size.to_u64 }
      require!(actual_doc_counts == expected_counts && actual_doc_rows == expected_doc_rows,
        "bounded whole-Object #{window} differs from the full read")
      output << JSON::Any.new({
        "consumer"                 => json("whole_object"),
        "path"                     => JSON::Any.new(nil),
        "window"                   => json(window),
        "first_mark"               => json(first_mark.to_i64),
        "mark_count"               => json(mark_count.to_i64),
        "expected_mark_row_counts" => JSON::Any.new(expected_counts.map { |n| json(n.to_i64) }),
        "actual_mark_row_counts"   => JSON::Any.new(actual_doc_counts.map { |n| json(n.to_i64) }),
        "expected_rows"            => JSON::Any.new(expected_doc_rows),
        "actual_rows"              => JSON::Any.new(actual_doc_rows),
        "matches_full_slice"       => json(true),
      } of String => JSON::Any)

      expected_path_marks = Array(Array(CrystalClick::BinaryValue)).new(mark_count) { |offset| path_marks[first_mark + offset] }
      expected_path_rows = render_shared_path(expected_path_marks, first_mark)
      actual_path_marks = CrystalClick::ObjectColumnReader.open(path, "doc", schema).read_shared_path_marks("payload", first_mark, mark_count)
      actual_path_rows = render_shared_path(actual_path_marks, first_mark)
      actual_path_counts = actual_path_marks.map { |mark| mark.size.to_u64 }
      require!(actual_path_counts == expected_counts && actual_path_rows == expected_path_rows,
        "bounded selected path #{window} differs from its full read")
      output << JSON::Any.new({
        "consumer"                 => json("selected_path"),
        "path"                     => json("payload"),
        "window"                   => json(window),
        "first_mark"               => json(first_mark.to_i64),
        "mark_count"               => json(mark_count.to_i64),
        "expected_mark_row_counts" => JSON::Any.new(expected_counts.map { |n| json(n.to_i64) }),
        "actual_mark_row_counts"   => JSON::Any.new(actual_path_counts.map { |n| json(n.to_i64) }),
        "expected_rows"            => JSON::Any.new(expected_path_rows),
        "actual_rows"              => JSON::Any.new(actual_path_rows),
        "matches_full_slice"       => json(true),
      } of String => JSON::Any)
    end
    output
  end

  private def file_inventory(path : String) : JSON::Any
    require!(Dir.exists?(path) && !File.symlink?(path), "part directory is missing or symlinked")
    names = Dir.children(path).sort
    require!(names.size <= MAX_PART_FILES, "part has too many files")
    require!(names.includes?("checksums.txt"), "checksums.txt is absent")
    require!(REQUIRED_PLAIN_METADATA_FILES.all? { |name| names.includes?(name) }, "required plain metadata is absent")

    checksums = CrystalClick::PartChecksums.open(path)
    expected_names = checksums.entries.keys.sort
    actual_names = names.reject do |name|
      name == "checksums.txt" || PLAIN_METADATA_FILES.includes?(name)
    end
    require!(actual_names == expected_names, "checksums roster differs from physical files")

    files = [] of JSON::Any
    total = 0_i64
    names.each do |name|
      require!(!name.includes?(File::SEPARATOR) && name != "." && name != "..", "unsafe part file name")
      require!(/\A[a-zA-Z0-9_.-]+\z/.matches?(name), "unsafe part file name")
      file_path = File.join(path, name)
      require!(File.file?(file_path) && !File.symlink?(file_path), "part entry is not a regular file")
      size = File.size(file_path)
      require!(size <= MAX_PART_FILE_BYTES, "part file exceeds size bound")
      bytes = File.read(file_path)
      require!(bytes.bytesize.to_i64 == size, "part file changed while hashing")
      total += size
      require!(total <= MAX_PART_TOTAL_BYTES, "part exceeds total size bound")

      unless name == "checksums.txt" || PLAIN_METADATA_FILES.includes?(name)
        entry = checksums.entry(name) || raise CrystalClick::CorruptPartError.new("W243 helper: checksum entry disappeared")
        require!(size.to_u64 == entry.physical_size, "physical checksum size differs for #{name}")
        require!(CrystalClick::CityHashV1.file_hash(bytes.to_slice) == entry.file_hash, "physical checksum hash differs for #{name}")
        if entry.compressed
          raw = if bytes.empty?
                  Bytes.empty
                else
                  CrystalClick::CompressedBlock.decode_all(
                    bytes.to_slice,
                    MAX_PART_TOTAL_BYTES,
                    MAX_PART_TOTAL_BYTES,
                    MAX_PART_TOTAL_BYTES,
                  )
                end
          require!(raw.size.to_u64 == entry.uncompressed_size, "uncompressed checksum size differs for #{name}")
        end
      end

      files << JSON::Any.new({
        "name"   => json(name),
        "size"   => json(size),
        "sha256" => json(Digest::SHA256.hexdigest(bytes)),
      } of String => JSON::Any)
    end
    JSON::Any.new(files)
  end

  private def read_part(path : String, role : String, version : Int32, string_id : String) : JSON::Any
    schema = CrystalClick::ObjectDocumentSchema.new(
      {} of String => CrystalClick::BinaryDataType,
      max_dynamic_paths: 0,
    )
    files = file_inventory(path)
    reader = CrystalClick::ObjectColumnReader.open(path, "doc", schema)
    require!(reader.row_count == ROW_COUNT.to_u64, "#{role} row count differs")
    require!(reader.mark_row_counts == MARK_ROWS, "#{role} real mark grid differs")
    expected_profile = string_profile(string_id)
    require!(reader.ordinary_profile == expected_profile, "#{role} ordinary String profile differs")
    descriptor = CrystalClick::ObjectDocumentFileReader.inspect(
      path,
      "doc",
      schema.typed_paths,
      reader.ordinary_profile,
      CrystalClick::BinaryBulkProfile.single_stream,
      true,
    )
    object = descriptor.plan.structures.object
    buckets = version == 0 || version == 2 ? 1_u64 : 2_u64
    require!(object.shared_data_version == version.to_u64 && object.bucket_count == buckets,
      "#{role} Object shared layout differs")
    full_marks = CrystalClick::ObjectColumnReader.open(path, "doc", schema).read_marks(0, MARK_ROWS.size)
    path_marks = CrystalClick::ObjectColumnReader.open(path, "doc", schema).read_shared_path_marks("payload", 0, MARK_ROWS.size)
    full_rows = render_documents(full_marks)
    direct_rows = render_shared_path(path_marks)
    witnesses = nested_type_witnesses(full_marks, role)
    require!(witnesses.size == ROW_COUNT, "#{role} nested type witness count differs")
    windows = bounded_windows(path, schema, full_marks, path_marks)
    require!(windows.size == 8, "#{role} bounded-window roster differs")
    columns_text = File.read(File.join(path, "columns.txt"))
    count_text = File.read(File.join(path, "count.txt")).strip
    source_declaration = reader.source_declaration
    require!(source_declaration == "JSON(max_dynamic_paths=0)", "#{role} outer Object declaration differs")
    JSON::Any.new({
      "role"                    => json(role),
      "path"                    => json(File.realpath(path)),
      "schema_declaration"      => json(source_declaration),
      "columns_text"            => json(columns_text),
      "count_text"              => json(count_text),
      "count"                   => json(reader.row_count.to_i64),
      "shared_version"          => json(version.to_i64),
      "bucket_count"            => json(buckets.to_i64),
      "string_profile"          => json(string_id),
      "ordinary_string_profile" => json(string_id == "s0" ? 0_i64 : 1_i64),
      "mark_row_counts"         => JSON::Any.new(reader.mark_row_counts.map { |n| json(n.to_i64) }),
      "physical_stream_names"   => json_strings(reader.physical_stream_names),
      "physical_file_inventory" => files,
      "full_rows"               => JSON::Any.new(full_rows),
      "direct_payload_rows"     => JSON::Any.new(direct_rows),
      "nested_type_witnesses"   => JSON::Any.new(witnesses),
      "bounded_windows"         => JSON::Any.new(windows),
      "outer_actual_type"       => json(outer_actual_type.name),
      "parent_json_type"        => json(outer_json_type.name),
      "item_array_type"         => json(item_array_type(role).name),
      "leaf_json_type"          => json(leaf_json_type(role).name),
      "nested_path"             => json("payload.1.items[]"),
    } of String => JSON::Any)
  end

  private def write_part(
    path : String,
    role : String,
    version : Int32,
    string_id : String,
    frame_bytes : Int32,
  ) : Nil
    buckets = version == 0 || version == 2 ? 1_u64 : 2_u64
    plan, policy = write_plan(role, version, buckets)
    documents = fixture_documents(role)
    granules = documents.each_slice(2).map(&.to_a).to_a
    target_rows = version == 3 ? 2 : 1
    CrystalClick::WidePartWriter.write_uint64_object_pair(
      path,
      "pk",
      Slice(UInt64).new(ROW_COUNT) { |index| (index + 1).to_u64 },
      "doc",
      CrystalClick::ObjectDocumentSchema.new(
        {} of String => CrystalClick::BinaryDataType,
        max_dynamic_paths: 0,
      ),
      plan,
      granules,
      rows_per_mark: 2,
      profile: string_profile(string_id),
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      frame_bytes: frame_bytes,
      shared_json_policy: policy,
      shared_target_chunk_rows: target_rows,
    )
    nil
  end

  private def validate_input!(input : JSON::Any) : Tuple(Int32, Array(Tuple(String, Int32, String)))
    hash = input.as_h
    require!(hash.keys.sort == ["format", "frame_bytes", "profiles"], "input key set differs")
    require!(hash["format"].as_s == FORMAT_INPUT, "input format differs")
    frame_bytes = hash["frame_bytes"].as_i
    require!(frame_bytes == 32 || frame_bytes == 64, "frame_bytes is outside the 32/64 allowlist")
    profiles = hash["profiles"].as_a
    require!(profiles.size == PROFILE_SPECS.size, "profile count differs")
    normalized = [] of Tuple(String, Int32, String)
    profiles.each_with_index do |entry, index|
      require!(entry.as_h.keys.sort == ["id", "shared_version", "string_profile"], "profile key set differs")
      expected = PROFILE_SPECS[index]
      actual_id = entry["id"].as_s
      actual_version = entry["shared_version"].as_i
      actual_string = entry["string_profile"].as_s
      require!(actual_id == expected[0] && actual_version == expected[1].to_i64 && actual_string == expected[2],
        "profile id/order/settings differ from the fixed roster")
      normalized << expected
    end
    {frame_bytes.to_i32, normalized}
  end

  private def canonical_directory(path : String, label : String) : String
    expanded = File.expand_path(path)
    require!(Dir.exists?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded,
      "#{label} must be an existing canonical non-symlink directory")
    expanded
  end

  def run(args : Array(String)) : Nil
    unless args.size == 2
      raise ArgumentError.new("usage: check_object_descendant_json_w243.cr INPUT_JSON OUTPUT_ROOT")
    end
    input_path = File.expand_path(args[0])
    output_root = canonical_directory(args[1], "output root")
    require!(File.file?(input_path) && !File.symlink?(input_path), "input must be a regular non-symlink file")
    input_size = File.size(input_path)
    require!(input_size <= 1_048_576, "input exceeds size bound")
    input_bytes = File.read(input_path)
    require!(input_bytes.bytesize.to_i64 == input_size && input_bytes.bytesize <= 1_048_576,
      "input changed or exceeds size bound while reading")
    frame_bytes, profiles = validate_input!(JSON.parse(input_bytes))
    require!(Dir.children(output_root).empty?, "output root must be empty before generation")

    results = [] of JSON::Any
    profiles.each do |id, version, string_id|
      buckets = version == 0 || version == 2 ? 1_u64 : 2_u64
      normal_path = File.join(output_root, "#{id}_normal")
      type_only_path = File.join(output_root, "#{id}_type_only")
      write_part(normal_path, "normal", version, string_id, frame_bytes)
      write_part(type_only_path, "type_only", version, string_id, frame_bytes)
      normal = read_part(normal_path, "normal", version, string_id)
      type_only = read_part(type_only_path, "type_only", version, string_id)
      normal_witnesses = normal["nested_type_witnesses"].as_a
      type_only_witnesses = type_only["nested_type_witnesses"].as_a
      require!(normal["full_rows"] == type_only["full_rows"], "type-only pair changed full logical values")
      require!(normal["direct_payload_rows"] == type_only["direct_payload_rows"], "type-only pair changed selected payload values")
      normal_nested = nested_value_projection(normal_witnesses)
      type_only_nested = nested_value_projection(type_only_witnesses)
      require!(normal_nested == type_only_nested, "type-only pair changed descendant JSON values")
      normal_types = nested_types(normal_witnesses)
      type_only_types = nested_types(type_only_witnesses)
      require!(normal_types.keys == type_only_types.keys && normal_types.values.all? { |types| types.all? { |t| t == "UInt8" } } &&
               type_only_types.values.all? { |types| types.all? { |t| t == "Int64" } },
        "type-only pair did not change only the grandchild v descriptor")
      require!(normal["physical_stream_names"] == type_only["physical_stream_names"],
        "type-only pair changed physical stream-name roster")
      results << JSON::Any.new({
        "id"                        => json(id),
        "shared_version"            => json(version.to_i64),
        "string_profile"            => json(string_id),
        "bucket_count"              => json(buckets.to_i64),
        "outer_actual_type"         => json(outer_actual_type.name),
        "parent_json_type"          => json(outer_json_type.name),
        "normal_item_array_type"    => json(item_array_type("normal").name),
        "type_only_item_array_type" => json(item_array_type("type_only").name),
        "normal_part"               => normal,
        "type_only_part"            => type_only,
        "pair_comparison"           => JSON::Any.new({
          "full_rows_equal"           => json(true),
          "direct_payload_rows_equal" => json(true),
          "nested_json_values_equal"  => json(true),
          "normal_nested_values"      => normal_nested,
          "type_only_nested_values"   => type_only_nested,
          "normal_nested_types"       => nested_type_projection(normal_types),
          "type_only_nested_types"    => nested_type_projection(type_only_types),
        } of String => JSON::Any),
      } of String => JSON::Any)
    end

    output = JSON::Any.new({
      "format"                => json(FORMAT_OUTPUT),
      "input_sha256"          => json(Digest::SHA256.hexdigest(input_bytes)),
      "output_root"           => json(output_root),
      "requested_frame_bytes" => json(frame_bytes.to_i64),
      "profile_ids"           => json_strings(PROFILE_SPECS.map(&.[0])),
      "profiles"              => JSON::Any.new(results),
    } of String => JSON::Any)
    puts output.to_json
  end

  private def nested_value_projection(witnesses : Array(JSON::Any)) : JSON::Any
    JSON::Any.new(witnesses.map do |row|
      JSON::Any.new({
        "pk"    => row["pk"],
        "state" => row["items_state"],
        "items" => JSON::Any.new(row["nested_items"].as_a.map do |item|
          JSON::Any.new({"index" => item["index"], "v_value" => item["v_value"]} of String => JSON::Any)
        end),
      } of String => JSON::Any)
    end)
  end

  private def nested_type_projection(types : Hash(Int64, Array(String))) : JSON::Any
    JSON::Any.new(types.keys.sort.map do |pk|
      JSON::Any.new({"pk" => json(pk), "v_types" => json_strings(types[pk])} of String => JSON::Any)
    end)
  end

  private def nested_types(witnesses : Array(JSON::Any)) : Hash(Int64, Array(String))
    output = {} of Int64 => Array(String)
    witnesses.each do |row|
      output[row["pk"].as_i64] = row["nested_items"].as_a.map { |item| item["v_type"].as_s }
    end
    output
  end
end

CheckObjectDescendantJSONW243.run(ARGV)
