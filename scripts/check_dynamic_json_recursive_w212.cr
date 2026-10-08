require "../src/crystal_click"
require "json"
require "./support/dynamic_owned_values_w220"

module CheckDynamicJSONRecursiveW212
  extend self

  COLUMN   = "payload"
  KEY_NAME = "pk"
  CASE_IDS = [
    "root_array_json",
    "root_named_tuple_json",
    "root_deep_nullable_json",
    "root_map_json",
    "root_array_variant_json",
    "array_dynamic_array_json",
  ]
  PROFILE_IDS   = ["single_stream", "with_size_stream"]
  FORMAT_INPUT  = "dynamic_json_recursive_w212_input_v1"
  FORMAT_OUTPUT = "dynamic_json_recursive_w212_helper_v1"
  PARENT_ROWS   = [2_u64, 2_u64, 2_u64]
  OBJECT_ROWS   = [2_u64, 2_u64, 2_u64, 0_u64]

  alias LeafPlan = Tuple(CrystalClick::BinaryDynamicJsonLeafKey, CrystalClick::ObjectDocumentPlan)
  alias Fixture = NamedTuple(
    case_id: String,
    type: CrystalClick::BinaryDataType,
    structures: Hash(String, CrystalClick::DynamicStructure),
    granules: Array(Array(CrystalClick::BinaryValue)),
    leaf_plans: Array(LeafPlan),
    sites: Array(String),
    json_used: CrystalClick::BinaryDataType,
    json_unused: CrystalClick::BinaryDataType,
    expected_rows: Array(Array(String)),
  )

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W212 helper: #{message}") unless condition
  end

  private def with_phase(case_id : String, profile_name : String, phase : String, &block : -> T) : T forall T
    yield
  rescue ex : Exception
    raise "W212 helper case=#{case_id} profile=#{profile_name} phase=#{phase}: #{ex.class}: #{ex.message}"
  end

  private def profile(name : String) : CrystalClick::BinaryBulkProfile
    case name
    when "single_stream"
      CrystalClick::BinaryBulkProfile.single_stream
    when "with_size_stream"
      CrystalClick::BinaryBulkProfile.with_size_stream
    else
      raise ArgumentError.new("W212 profile is outside the fixed roster")
    end
  end

  private def u8_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt8")
  end

  private def i64_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("Int64")
  end

  private def string_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("String")
  end

  private def json_type(max_dynamic_types : Int32) : CrystalClick::BinaryDataType
    uint8 = u8_type
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 1,
      max_dynamic_types: max_dynamic_types,
      typed_paths: {
        "id"    => uint8,
        "maybe" => CrystalClick::BinaryDataType.nullable(uint8),
      } of String => CrystalClick::BinaryDataType,
    )
  end

  private def json_plan(type : CrystalClick::BinaryDataType) : CrystalClick::ObjectDocumentPlan
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["counter"] of String),
      {"counter" => CrystalClick::DynamicStructure.new([i64_type] of CrystalClick::BinaryDataType)},
    )
    CrystalClick::ObjectDocumentPlan.new(structures, type.json_type.not_nil!.typed_paths)
  end

  private def json_value(type : CrystalClick::BinaryDataType, id : UInt8, counter : Int64) : CrystalClick::BinaryValue
    uint8 = u8_type
    nullable_uint8 = CrystalClick::BinaryDataType.nullable(uint8)
    row = CrystalClick::BinaryJsonRow.new(
      type,
      [
        {"id", CrystalClick::BinaryValue.fixed(uint8, Bytes[id])},
        {"maybe", CrystalClick::BinaryValue.null(nullable_uint8)},
        {"counter", CrystalClick::BinaryValue.int64(counter)},
      ] of Tuple(String, CrystalClick::BinaryValue),
    )
    CrystalClick::BinaryValue.json(type, row)
  end

  private def u8(value : UInt8) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.fixed(u8_type, Bytes[value])
  end

  private def string(value : String) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.string(value)
  end

  private def dynamic_value(type : CrystalClick::BinaryDataType, child : CrystalClick::BinaryValue) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.dynamic(type, child)
  end

  private def fixture(case_id : String) : Fixture
    uint8 = u8_type
    string = string_type
    dynamic = CrystalClick::BinaryDataType.dynamic(4)
    used = json_type(1)
    unused = json_type(2)
    array_json = CrystalClick::BinaryDataType.array(used)
    unused_plan = json_plan(unused)

    site = case case_id
           when "array_dynamic_array_json" then "root.elements"
           when "root_array_json", "root_named_tuple_json", "root_deep_nullable_json", "root_map_json", "root_array_variant_json"
             "root"
           else
             raise ArgumentError.new("W212 case is outside the fixed roster")
           end

    actual = case case_id
             when "root_array_json", "array_dynamic_array_json"
               array_json
             when "root_named_tuple_json"
               CrystalClick::BinaryDataType.tuple(
                 [used, used] of CrystalClick::BinaryDataType,
                 ["left", "right"] of String,
               )
             when "root_deep_nullable_json"
               nullable = CrystalClick::BinaryDataType.nullable(used)
               pair = CrystalClick::BinaryDataType.tuple(
                 [string, nullable] of CrystalClick::BinaryDataType,
               )
               CrystalClick::BinaryDataType.array(pair)
             when "root_map_json"
               CrystalClick::BinaryDataType.map(string, used)
             when "root_array_variant_json"
               variant = CrystalClick::BinaryDataType.variant([used, uint8] of CrystalClick::BinaryDataType)
               CrystalClick::BinaryDataType.array(variant)
             else
               raise ArgumentError.new("W212 case is outside the fixed roster")
             end

    structure = CrystalClick::DynamicStructure.new([actual, unused, uint8] of CrystalClick::BinaryDataType)
    actual_index = structure.canonical_index_for(actual)
    unused_index = structure.canonical_index_for(unused)
    plans = [] of LeafPlan
    leaf_paths = case case_id
                 when "root_array_json", "array_dynamic_array_json" then [[0] of Int32] of Array(Int32)
                 when "root_named_tuple_json"                       then [[0] of Int32, [1] of Int32] of Array(Int32)
                 when "root_deep_nullable_json"                     then [[0, 1, 0] of Int32] of Array(Int32)
                 when "root_map_json"                               then [[1] of Int32] of Array(Int32)
                 when "root_array_variant_json"
                   json_arm = actual.child_at(0).children.index(used).not_nil!.to_i32
                   [[0, json_arm] of Int32]
                 else raise ArgumentError.new("W212 leaf path roster is incomplete")
                 end
    leaf_paths.each do |path|
      plans << {CrystalClick::BinaryDynamicJsonLeafKey.new(site, actual_index, path), json_plan(used)}
    end
    plans << {CrystalClick::BinaryDynamicJsonLeafKey.new(site, unused_index, [] of Int32), unused_plan}

    dyn = ->(child : CrystalClick::BinaryValue) { dynamic_value(dynamic, child) }
    used_json = ->(id : UInt8) { json_value(used, id, id.to_i64 * 10_i64 + 1_i64) }
    expected = [] of Array(String)
    granules = [] of Array(CrystalClick::BinaryValue)

    case case_id
    when "root_array_json"
      rows = [
        dyn.call(u8(11_u8)), dyn.call(u8(12_u8)),
        dyn.call(CrystalClick::BinaryValue.array(array_json, [] of CrystalClick::BinaryValue)),
        dyn.call(CrystalClick::BinaryValue.array(array_json, [used_json.call(31_u8), used_json.call(32_u8)] of CrystalClick::BinaryValue)),
        dyn.call(CrystalClick::BinaryValue.array(array_json, [used_json.call(33_u8), used_json.call(34_u8), used_json.call(35_u8)] of CrystalClick::BinaryValue)),
        dyn.call(CrystalClick::BinaryValue.array(array_json, [] of CrystalClick::BinaryValue)),
      ] of CrystalClick::BinaryValue
      expected = [
        ["D[U8:11]", "D[U8:12]"] of String,
        ["D[[]]", "D[[J(31,311),J(32,321)]]"] of String,
        ["D[[J(33,331),J(34,341),J(35,351)]]", "D[[]]"] of String,
      ] of Array(String)
      granules = rows.each_slice(2).map(&.to_a).to_a
    when "root_named_tuple_json"
      tuple = actual
      tuple_value = ->(left : UInt8, right : UInt8) {
        CrystalClick::BinaryValue.tuple(tuple, [used_json.call(left), used_json.call(right)] of CrystalClick::BinaryValue)
      }
      rows = [
        dyn.call(u8(13_u8)), dyn.call(u8(14_u8)),
        dyn.call(tuple_value.call(41_u8, 42_u8)), dyn.call(tuple_value.call(43_u8, 44_u8)),
        dyn.call(tuple_value.call(0_u8, 45_u8)), dyn.call(tuple_value.call(46_u8, 47_u8)),
      ] of CrystalClick::BinaryValue
      expected = [
        ["D[U8:13]", "D[U8:14]"] of String,
        ["D[(left=J(41,411),right=J(42,421))]", "D[(left=J(43,431),right=J(44,441))]"] of String,
        ["D[(left=J(0,1),right=J(45,451))]", "D[(left=J(46,461),right=J(47,471))]"] of String,
      ] of Array(String)
      granules = rows.each_slice(2).map(&.to_a).to_a
    when "root_deep_nullable_json"
      nullable = actual.child_at(0).child_at(1)
      tuple = actual.child_at(0)
      array = actual
      pair = ->(label : String, doc : CrystalClick::BinaryValue) {
        CrystalClick::BinaryValue.tuple(tuple, [string(label), doc] of CrystalClick::BinaryValue)
      }
      nullable_json = ->(id : UInt8) {
        CrystalClick::BinaryValue.nullable(nullable, used_json.call(id))
      }
      null_json = -> { CrystalClick::BinaryValue.nullable(nullable) }
      array_value = ->(items : Array(CrystalClick::BinaryValue)) { CrystalClick::BinaryValue.array(array, items) }
      rows = [
        dyn.call(u8(15_u8)), dyn.call(u8(16_u8)),
        dyn.call(array_value.call([] of CrystalClick::BinaryValue)),
        dyn.call(array_value.call([pair.call("nil", null_json.call), pair.call("present", nullable_json.call(61_u8))] of CrystalClick::BinaryValue)),
        dyn.call(array_value.call([pair.call("default", nullable_json.call(62_u8)), pair.call("null-default", null_json.call)] of CrystalClick::BinaryValue)),
        dyn.call(array_value.call([] of CrystalClick::BinaryValue)),
      ] of CrystalClick::BinaryValue
      expected = [
        ["D[U8:15]", "D[U8:16]"] of String,
        ["D[[]]", "D[[(nil,null),(present,J(61,611))]]"] of String,
        ["D[[(default,J(62,621)),(null-default,null)]]", "D[[]]"] of String,
      ] of Array(String)
      granules = rows.each_slice(2).map(&.to_a).to_a
    when "root_map_json"
      map_type = actual
      map_value = ->(entries : Array(Tuple(String, UInt8))) {
        flat = [] of CrystalClick::BinaryValue
        entries.each do |key, id|
          flat << string(key)
          flat << used_json.call(id)
        end
        CrystalClick::BinaryValue.map(map_type, flat)
      }
      rows = [
        dyn.call(u8(17_u8)), dyn.call(u8(18_u8)),
        dyn.call(map_value.call([] of Tuple(String, UInt8))),
        dyn.call(map_value.call([{"alpha", 71_u8}, {"beta", 72_u8}] of Tuple(String, UInt8))),
        dyn.call(map_value.call([{"omega", 73_u8}] of Tuple(String, UInt8))),
        dyn.call(map_value.call([] of Tuple(String, UInt8))),
      ] of CrystalClick::BinaryValue
      expected = [
        ["D[U8:17]", "D[U8:18]"] of String,
        ["D[{}]", "D[{alpha=J(71,711),beta=J(72,721)}]"] of String,
        ["D[{omega=J(73,731)}]", "D[{}]"] of String,
      ] of Array(String)
      granules = rows.each_slice(2).map(&.to_a).to_a
    when "root_array_variant_json"
      variant = actual.child_at(0)
      array = actual
      json_arm = variant.children.index(used).not_nil!
      u8_arm = variant.children.index(uint8).not_nil!
      json_choice = ->(id : UInt8) { CrystalClick::BinaryValue.variant(variant, json_arm, used_json.call(id)) }
      u8_choice = ->(value : UInt8) { CrystalClick::BinaryValue.variant(variant, u8_arm, u8(value)) }
      null_choice = -> { CrystalClick::BinaryValue.variant_null(variant) }
      array_value = ->(items : Array(CrystalClick::BinaryValue)) { CrystalClick::BinaryValue.array(array, items) }
      rows = [
        dyn.call(u8(19_u8)), dyn.call(u8(20_u8)),
        dyn.call(array_value.call([] of CrystalClick::BinaryValue)),
        dyn.call(array_value.call([json_choice.call(81_u8), u8_choice.call(82_u8), null_choice.call] of CrystalClick::BinaryValue)),
        dyn.call(array_value.call([json_choice.call(83_u8), json_choice.call(84_u8)] of CrystalClick::BinaryValue)),
        dyn.call(array_value.call([] of CrystalClick::BinaryValue)),
      ] of CrystalClick::BinaryValue
      expected = [
        ["D[U8:19]", "D[U8:20]"] of String,
        ["D[[]]", "D[[V#{json_arm}=J(81,811),V#{u8_arm}=U8:82,Vnull]]"] of String,
        ["D[[V#{json_arm}=J(83,831),V#{json_arm}=J(84,841)]]", "D[[]]"] of String,
      ] of Array(String)
      granules = rows.each_slice(2).map(&.to_a).to_a
    when "array_dynamic_array_json"
      array_json_dynamic = actual
      array_dynamic = CrystalClick::BinaryDataType.array(dynamic)
      child_json_array = ->(items : Array(CrystalClick::BinaryValue)) {
        dynamic_value(dynamic, CrystalClick::BinaryValue.array(array_json_dynamic, items))
      }
      child_u8 = ->(value : UInt8) { dynamic_value(dynamic, u8(value)) }
      outer = ->(items : Array(CrystalClick::BinaryValue)) { CrystalClick::BinaryValue.array(array_dynamic, items) }
      rows = [
        outer.call([] of CrystalClick::BinaryValue), outer.call([] of CrystalClick::BinaryValue),
        outer.call([child_json_array.call([] of CrystalClick::BinaryValue), child_u8.call(91_u8), child_json_array.call([used_json.call(101_u8)] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue),
        outer.call([] of CrystalClick::BinaryValue),
        outer.call([
          child_json_array.call([used_json.call(111_u8), used_json.call(112_u8)] of CrystalClick::BinaryValue),
          child_u8.call(92_u8),
          child_json_array.call([used_json.call(113_u8)] of CrystalClick::BinaryValue),
          child_json_array.call([used_json.call(114_u8)] of CrystalClick::BinaryValue),
          child_u8.call(93_u8),
        ] of CrystalClick::BinaryValue),
        outer.call([] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue
      expected = [
        ["[]", "[]"] of String,
        ["[D[[]],D[U8:91],D[[J(101,1011)]]]", "[]"] of String,
        ["[D[[J(111,1111),J(112,1121)]],D[U8:92],D[[J(113,1131)]],D[[J(114,1141)]],D[U8:93]]", "[]"] of String,
      ] of Array(String)
      granules = rows.each_slice(2).map(&.to_a).to_a
    else
      raise ArgumentError.new("W212 case is outside the fixed roster")
    end

    structures = {site => structure}
    {case_id: case_id, type: case_id == "array_dynamic_array_json" ? CrystalClick::BinaryDataType.array(dynamic) : dynamic,
     structures: structures, granules: granules, leaf_plans: plans, sites: [site] of String,
     json_used: used, json_unused: unused, expected_rows: expected}
  end

  private def signature(value : CrystalClick::BinaryValue) : String
    if value.type.tag == CrystalClick::BinaryDataType::TAG_VARIANT && value.is_null?
      return "Vnull"
    end
    if value.is_null?
      return "null"
    end
    case value.type.tag
    when CrystalClick::BinaryDataType::TAG_DYNAMIC
      "D[#{signature(value.child_at(0))}]"
    when CrystalClick::BinaryDataType::TAG_JSON
      row = value.json_row
      id = row.value_for("id").not_nil!.byte_at(0)
      counter = row.value_for("counter").not_nil!.as_int64
      "J(#{id},#{counter})"
    when CrystalClick::BinaryDataType::TAG_ARRAY
      "[#{value.elements.map { |item| signature(item) }.join(",")}]"
    when CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
      fields = value.elements.each_with_index.map do |item, index|
        "#{value.type.field_name_at(index)}=#{signature(item)}"
      end
      "(#{fields.join(",")})"
    when CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE
      "(#{value.elements.map { |item| signature(item) }.join(",")})"
    when CrystalClick::BinaryDataType::TAG_NULLABLE
      signature(value.child_at(0))
    when CrystalClick::BinaryDataType::TAG_MAP
      entries = value.elements.each_slice(2).map do |pair|
        "#{pair[0].as_string}=#{signature(pair[1])}"
      end
      "{#{entries.join(",")}}"
    when CrystalClick::BinaryDataType::TAG_VARIANT
      index = value.variant_index?
      if index
        "V#{index}=#{signature(value.variant_child?.not_nil!)}"
      else
        "Vnull"
      end
    when CrystalClick::BinaryDataType::TAG_UINT8
      "U8:#{value.byte_at(0)}"
    when CrystalClick::BinaryDataType::TAG_STRING
      value.as_string
    else
      raise CrystalClick::CorruptPartError.new("W212 helper encountered an unrostered fixture value type")
    end
  end

  private def validate_path!(path : String, root : String, generated : Bool) : Nil
    full = File.expand_path(path)
    require!(full.starts_with?(root + File::SEPARATOR), "part path escaped its authenticated root")
    if generated
      require!(!File.exists?(full) && !File.symlink?(full), "generated destination already exists")
      parent = File.dirname(full)
      require!(Dir.exists?(parent) && !File.symlink?(parent) && File.realpath(parent) == parent,
        "generated parent is absent, symlinked or noncanonical")
    else
      require!(Dir.exists?(full) && !File.symlink?(full) && File.realpath(full) == full,
        "stock source part is absent, symlinked or noncanonical")
    end
  end

  private def check_mark_file!(part : String, stream_name : String) : Nil
    path = File.join(part, "#{CrystalClick::StreamName.hash(stream_name)}.mrk2")
    bytes = File.read(path).to_slice
    unless bytes.size % CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE == 0
      raise CrystalClick::CorruptPartError.new("W212 Object child marks contain an incomplete record")
    end
    count = bytes.size // CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE
    rows = Array(UInt64).new(count) do |record|
      offset = record * CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE + 16
      value = 0_u64
      8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
      value
    end
    require!(rows == OBJECT_ROWS, "Object child .mrk2 third words do not preserve physical parent rows P")
  end

  private def row_signature(value : CrystalClick::BinaryValue, case_id : String) : String
    signature(value)
  end

  private def reader_record(part : String, fixed : Fixture, profile_name : String, origin : String, validate_child_grid : Bool) : JSON::Any
    reader = CrystalClick::DynamicBulkColumnReader.open(
      part, COLUMN, fixed[:type], CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
      CrystalClick::CompressedStreamLimits.new,
    )
    require!(reader.schema_declaration == fixed[:type].name, "#{origin} nominal schema differs")
    require!(reader.row_count == 6_u64 && reader.mark_count == 3, "#{origin} parent row/mark census differs")
    require!(reader.mark_row_counts == PARENT_ROWS, "#{origin} parent mark grid P differs")
    require!(reader.ordinary_profile == profile(profile_name), "#{origin} String profile differs")
    low_level_by_mark = reader.read_marks(0, reader.mark_count)
    marks = low_level_by_mark.map do |mark|
      mark.map { |value| row_signature(value, fixed[:case_id]) }
    end
    require!(marks == fixed[:expected_rows], "#{origin} rows differ from independent helper literals")
    require!(reader.read_marks(0, 1).map { |mark| mark.map { |value| row_signature(value, fixed[:case_id]) } } == marks[0, 1],
      "#{origin} first-window selection differs")
    require!(reader.read_marks(1, 1).map { |mark| mark.map { |value| row_signature(value, fixed[:case_id]) } } == marks[1, 1],
      "#{origin} middle-window selection differs")
    require!(reader.read_marks(2, 1).map { |mark| mark.map { |value| row_signature(value, fixed[:case_id]) } } == marks[2, 1],
      "#{origin} final-window selection differs")
    require!(reader.read_marks(reader.mark_count, 0).empty?, "#{origin} EOF zero-mark selection is not empty")

    table = CrystalClick::WidePartTable.open_selected_typed([part], [KEY_NAME, COLUMN])
    table_values = Array(Array(CrystalClick::BinaryValue)).new(fixed[:granules].size) { [] of CrystalClick::BinaryValue }
    candidate_marks = Array(Int32).new(fixed[:granules].size) { |mark| mark.to_i32 }
    table.scan_typed_candidate_marks([candidate_marks]) do |batch|
      mark = batch.mark_index
      require!(batch.part_index == 0 && mark >= 0 && mark < fixed[:granules].size,
        "#{origin} batch identity is outside the fixed part/mark grid")
      expected_offset = (mark * PARENT_ROWS.first).to_u64
      require!(batch.mark_row_offset == 0_u64 && batch.part_row_offset == expected_offset && batch.source_row_offset == expected_offset,
        "#{origin} typed-batch offsets differ from physical P")
      require!(batch.values_for(KEY_NAME, UInt64).size == fixed[:granules][mark].size,
        "#{origin} key and Dynamic candidate row counts differ")
      table_values[mark] = batch.dynamic_bulk_values_for(COLUMN).to_a
    end
    table_values.each_with_index do |values, mark|
      wanted = fixed[:granules][mark]
      require!(values.size == wanted.size, "#{origin} table candidate count differs at mark #{mark}")
      values.each_with_index do |value, row|
        require!(CrystalClick::BinaryValueCodec.encode(value) == CrystalClick::BinaryValueCodec.encode(wanted[row]),
          "#{origin} generic Dynamic table value differs at #{mark}/#{row}")
      end
    end
    middle_values = [] of CrystalClick::BinaryValue
    table.scan_typed_window(1_u64, 3) do |batch|
      mark_start = (batch.mark_index * PARENT_ROWS.first).to_u64
      expected_mark_offset = batch.mark_index == 0 ? 1_u64 : 0_u64
      expected_row_offset = mark_start + expected_mark_offset
      require!(batch.mark_row_offset == expected_mark_offset && batch.part_row_offset == expected_row_offset &&
               batch.source_row_offset == expected_row_offset, "#{origin} middle-window offsets differ")
      middle_values.concat(batch.dynamic_bulk_values_for(COLUMN).to_a)
    end
    expected_window = fixed[:granules].flatten[1, 3]
    require!(middle_values.size == expected_window.size, "#{origin} middle-window row count differs")
    middle_values.each_with_index do |value, index|
      require!(CrystalClick::BinaryValueCodec.encode(value) == CrystalClick::BinaryValueCodec.encode(expected_window[index]),
        "#{origin} middle-window generic table value differs at row #{index}")
    end
    eof_callbacks = 0
    table.scan_typed_window(table.total_row_count, 1) { |_batch| eof_callbacks += 1 }
    require!(eof_callbacks == 0, "#{origin} table EOF window exposed a callback")

    physical_names = reader.physical_stream_names.sort!
    require!(physical_names.uniq == physical_names && !physical_names.empty?, "#{origin} physical stream roster is empty or duplicated")
    checksum_names = reader.selected_checksum_names.sort!
    require!(checksum_names.uniq == checksum_names, "#{origin} selected checksum roster contains duplicates")
    checksums = CrystalClick::PartChecksums.open(part)
    checksum_names.each { |name| require!(checksums.entries.has_key?(name), "#{origin} checksum is missing #{name}") }

    child_names = physical_names.select do |name|
      name.includes?(".object_structure") || name.includes?(".object_shared_data") ||
        name.includes?(".counter.") || name.ends_with?(".id") || name.ends_with?(".maybe") || name.ends_with?(".maybe.null")
    end
    require!(!child_names.empty?, "#{origin} JSON Object child stream roster is empty")
    child_names.each { |name| check_mark_file!(part, name) } if validate_child_grid

    bound_keys = [] of String
    bound_types = [] of String
    if origin == "library"
      budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true)
      plan = CrystalClick::BinaryDynamicBulkPlan.new_with_budget(
        fixed[:type], fixed[:structures], budget, profile(profile_name),
        json_object_leaf_plans: fixed[:leaf_plans],
      )
      physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(plan, COLUMN, CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS)
      require!(reader.physical_stream_names.sort == physical.stream_names.values.sort,
        "library physical stream roster differs from the complete bound-leaf plan")
      physical.json_object_sites.each do |site|
        key = site.leaf_key
        bound_keys << "#{key.dynamic_site}/#{key.canonical_arm_index}/#{key.descriptor_child_path.join(",")}"
        bound_types << site.binding.json_type.name
        site.physical_plan.stream_names.each do |name|
          child_names << name
          check_mark_file!(part, name) if validate_child_grid
          base = CrystalClick::StreamName.hash(name)
          {"#{base}.bin", "#{base}.mrk2"}.each do |file_name|
            require!(checksum_names.includes?(file_name), "library Object child file is absent from checksum roster")
          end
        end
      end
      expected_keys = fixed[:leaf_plans].map do |key, _plan|
        "#{key.dynamic_site}/#{key.canonical_arm_index}/#{key.descriptor_child_path.join(",")}"
      end.sort
      require!(bound_keys.sort == expected_keys, "library exact JSON leaf binding roster differs")
    else
      child_names.each { |name| check_mark_file!(part, name) } if validate_child_grid
    end

    record = {
      "case_id"                   => JSON::Any.new(fixed[:case_id]),
      "profile_id"                => JSON::Any.new(profile_name),
      "schema_declaration"        => JSON::Any.new(reader.schema_declaration),
      "row_count"                 => JSON::Any.new(reader.row_count.to_i64),
      "mark_count"                => JSON::Any.new(reader.mark_count),
      "mark_row_counts"           => JSON::Any.new(reader.mark_row_counts.map { |count| JSON::Any.new(count.to_i64) }),
      "rows_by_mark"              => JSON::Any.new(marks.map { |mark| JSON::Any.new(mark.map { |row| JSON::Any.new(row) }) }),
      "physical_stream_names"     => JSON::Any.new(physical_names.map { |name| JSON::Any.new(name) }),
      "selected_checksum_names"   => JSON::Any.new(checksum_names.map { |name| JSON::Any.new(name) }),
      "object_child_stream_names" => JSON::Any.new(child_names.uniq.sort!.map { |name| JSON::Any.new(name) }),
      "bound_json_leaf_keys"      => JSON::Any.new(bound_keys.sort!.map { |key| JSON::Any.new(key) }),
      "bound_json_type_names"     => JSON::Any.new(bound_types.sort!.map { |name| JSON::Any.new(name) }),
      "windows"                   => JSON::Any.new(["full", "first", "middle", "final", "eof_zero"].map { |name| JSON::Any.new(name) }),
    } of String => JSON::Any
    if origin == "source"
      observation = CrystalClick::DynamicOwnedValuesW220.materialize(
        part,
        COLUMN,
        fixed[:type],
        reader.row_count,
        reader.mark_row_counts,
        fixed[:granules],
        low_level_by_mark,
      )
      record["owned_values"] = CrystalClick::DynamicOwnedValuesW220.to_json(observation) do |value|
        row_signature(value, fixed[:case_id])
      end
    end
    JSON::Any.new(record)
  end

  private def write_library_part!(path : String, fixed : Fixture, profile_name : String) : Nil
    keys = Slice[1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
    result = CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
      path,
      KEY_NAME,
      keys,
      COLUMN,
      fixed[:type],
      fixed[:structures],
      fixed[:granules],
      rows_per_mark: 2,
      profile: profile(profile_name),
      frame_bytes: 4096,
      metadata_version: 0_i64,
      limits: CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
      transport_limits: CrystalClick::CompressedStreamLimits.new,
      json_object_leaf_plans: fixed[:leaf_plans],
    )
    require!(result == path, "writer returned a different part path")
  end

  private def process_case(item : JSON::Any, capture_root : String, output_root : String) : JSON::Any
    case_id = item["case_id"].as_s
    profile_name = item["profile_id"].as_s
    require!(CASE_IDS.includes?(case_id) && PROFILE_IDS.includes?(profile_name), "case/profile is outside the exact roster")
    require!(item["capture_root"].as_s == capture_root, "case capture root differs")
    source_part = item["source_part"].as_s
    library_part = item["library_part"].as_s
    validate_path!(source_part, capture_root, false)
    validate_path!(library_part, output_root, true)
    fixed = fixture(case_id)
    with_phase(case_id, profile_name, "write") { write_library_part!(library_part, fixed, profile_name) }
    source = with_phase(case_id, profile_name, "source-read") { reader_record(source_part, fixed, profile_name, "source", true) }
    library = with_phase(case_id, profile_name, "library-read") { reader_record(library_part, fixed, profile_name, "library", true) }
    JSON::Any.new({
      "case_id"           => JSON::Any.new(case_id),
      "profile_id"        => JSON::Any.new(profile_name),
      "library_part_path" => JSON::Any.new(File.expand_path(library_part)),
      "source"            => source,
      "library"           => library,
    } of String => JSON::Any)
  end

  private def run(args : Array(String)) : Nil
    unless args.size == 2
      raise ArgumentError.new("usage: check_dynamic_json_recursive_w212.cr INPUT.json OUTPUT_ROOT")
    end
    input_path = File.expand_path(args[0])
    output_root = File.expand_path(args[1])
    unless Dir.exists?(output_root) && !File.symlink?(output_root) && File.realpath(output_root) == output_root
      raise ArgumentError.new("W212 output root must be canonical and non-symlinked")
    end
    unless File.file?(input_path) && !File.symlink?(input_path) && input_path.starts_with?(output_root + File::SEPARATOR)
      raise ArgumentError.new("W212 helper input must be a plain file below output root")
    end
    input = JSON.parse(File.read(input_path))
    require!(input.as_h.keys.sort == ["capture_root", "cases", "format"] && input["format"].as_s == FORMAT_INPUT,
      "helper input format differs")
    capture_root = input["capture_root"].as_s
    require!(Dir.exists?(capture_root) && !File.symlink?(capture_root) && File.realpath(capture_root) == capture_root,
      "capture root is not canonical")
    cases = input["cases"].as_a
    expected = CASE_IDS.flat_map { |case_id| PROFILE_IDS.map { |profile_name| "#{case_id}/#{profile_name}" } }
    observed = cases.map { |item| "#{item["case_id"].as_s}/#{item["profile_id"].as_s}" }
    require!(observed == expected, "case/profile order differs from fixed roster")
    cases.each do |item|
      require!(item.as_h.keys.sort == ["capture_root", "case_id", "library_part", "profile_id", "source_part"],
        "case input keys differ")
    end
    results = cases.map { |item| process_case(item, capture_root, output_root) }
    puts JSON::Any.new({
      "format"                 => JSON::Any.new(FORMAT_OUTPUT),
      "case_ids"               => JSON::Any.new(CASE_IDS.map { |name| JSON::Any.new(name) }),
      "profile_ids"            => JSON::Any.new(PROFILE_IDS.map { |name| JSON::Any.new(name) }),
      "parent_mark_rows"       => JSON::Any.new(PARENT_ROWS.map { |rows| JSON::Any.new(rows.to_i64) }),
      "object_child_mark_rows" => JSON::Any.new(OBJECT_ROWS.map { |rows| JSON::Any.new(rows.to_i64) }),
      "cases"                  => JSON::Any.new(results),
    }).to_json
  rescue ex : Exception
    STDERR.puts "W212 Crystal helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  def main(args : Array(String)) : Nil
    run(args)
  end
end

CheckDynamicJSONRecursiveW212.main(ARGV)
