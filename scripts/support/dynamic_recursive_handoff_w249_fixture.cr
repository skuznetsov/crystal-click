require "../../src/crystal_click"
require "json"

module DynamicRecursiveHandoffW249Fixture
  extend self

  FORMAT           = "dynamic_recursive_handoff_w249_fixture_v1"
  KEY_NAME         = "pk"
  ROOT_NESTED      = "root_nested"
  ARRAY_NESTED     = "array_nested"
  TUPLE_PARENT     = "tuple_parent"
  RECURSIVE_NESTED = "recursive_nested"
  MAP_PARENT       = "map_parent"
  FRAME_BYTES      = 32
  ROWS_PER_MARK    =  2
  KEYS             = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
  MARK_ROW_COUNTS  = [2_u64, 2_u64, 1_u64]
  TARGET_COLUMNS   = [ROOT_NESTED, ARRAY_NESTED, TUPLE_PARENT, RECURSIVE_NESTED, MAP_PARENT]

  EXPECTED_ROWS_JSON = <<-JSON
    [
      {"pk":1,"root_nested":[],"array_nested":[],"tuple_parent":[1,[]],"recursive_nested":[],"map_parent":[]},
      {"pk":2,"root_nested":[],"array_nested":[],"tuple_parent":[2,[]],"recursive_nested":[],"map_parent":[]},
      {
        "pk":3,
        "root_nested":[[["Int64",7],"root-a"],[["NULL",null],null],[["String","root-shared"],"root-b"]],
        "array_nested":[[[["Int64",9],"array-a"],[["String","array-shared"],"array-b"]]],
        "tuple_parent":[3,[[[["Int64",11],"tuple-a"],[["NULL",null],"tuple-null"]]]],
        "recursive_nested":[[["Int64",13],[[["NULL",null],["x"]],[["String","child-shared"],[]]]]],
        "map_parent":[[17,[[["Int64",19],"map-a"],[["String","map-shared"],"map-b"]]]]
      },
      {"pk":4,"root_nested":[],"array_nested":[[]],"tuple_parent":[4,[]],"recursive_nested":[],"map_parent":[]},
      {
        "pk":5,
        "root_nested":[[["String","root-tail"],"tail"],[["Int64",23],null]],
        "array_nested":[[[["NULL",null],"array-null"]],[],[[["Int64",29],"array-tail"]]],
        "tuple_parent":[5,[[[["Int64",31],"tuple-tail"],[["String","tuple-shared-tail"],"tuple-spill"]]]],
        "recursive_nested":[[["NULL",null],[]],[["String","parent-shared"],[[["Int64",37],[]],[["NULL",null],["tail","tags"]]]]],
        "map_parent":[[41,[[["NULL",null],"map-null"]]],[43,[]]]
      }
    ]
    JSON

  def profile(name : String) : CrystalClick::BinaryBulkProfile
    case name
    when "single", "s0"
      CrystalClick::BinaryBulkProfile.single_stream
    when "sized", "s1"
      CrystalClick::BinaryBulkProfile.with_size_stream
    else
      raise ArgumentError.new("W249 String profile must be single or sized")
    end
  end

  def profile_name(profile : CrystalClick::BinaryBulkProfile) : String
    profile.with_size_stream? ? "sized" : "single"
  end

  def dynamic_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.dynamic(max_types: 1)
  end

  def nested_record_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.nested(
      [dynamic_type, CrystalClick::BinaryDataType.primitive("String")] of CrystalClick::BinaryDataType,
      ["d", "label"] of String,
    )
  end

  def root_nested_type : CrystalClick::BinaryDataType
    low_cardinality_label = CrystalClick::BinaryDataType.low_cardinality(
      CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("String"))
    )
    CrystalClick::BinaryDataType.nested(
      [dynamic_type, low_cardinality_label] of CrystalClick::BinaryDataType,
      ["d", "label"] of String,
    )
  end

  def array_nested_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.array(nested_record_type)
  end

  def tuple_parent_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.tuple(
      [
        CrystalClick::BinaryDataType.primitive("UInt64"),
        CrystalClick::BinaryDataType.array(nested_record_type),
      ] of CrystalClick::BinaryDataType,
      ["id", "records"] of String,
    )
  end

  def recursive_nested_type : CrystalClick::BinaryDataType
    child = CrystalClick::BinaryDataType.nested(
      [dynamic_type, CrystalClick::BinaryDataType.array(CrystalClick::BinaryDataType.primitive("String"))] of CrystalClick::BinaryDataType,
      ["d", "tags"] of String,
    )
    CrystalClick::BinaryDataType.nested(
      [dynamic_type, child] of CrystalClick::BinaryDataType,
      ["d", "child"] of String,
    )
  end

  def map_parent_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.map(
      CrystalClick::BinaryDataType.primitive("UInt64"), nested_record_type
    )
  end

  def column_types : Hash(String, CrystalClick::BinaryDataType)
    {
      ROOT_NESTED      => root_nested_type,
      ARRAY_NESTED     => array_nested_type,
      TUPLE_PARENT     => tuple_parent_type,
      RECURSIVE_NESTED => recursive_nested_type,
      MAP_PARENT       => map_parent_type,
    } of String => CrystalClick::BinaryDataType
  end

  def dynamic_sites : Hash(String, Array(NamedTuple(path: String, registered_actual_types: Array(String))))
    {
      ROOT_NESTED      => [{path: "root.elements.field.0", registered_actual_types: ["Int64"] of String}],
      ARRAY_NESTED     => [{path: "root.elements.elements.field.0", registered_actual_types: ["Int64"] of String}],
      TUPLE_PARENT     => [{path: "root.field.1.elements.elements.field.0", registered_actual_types: ["Int64"] of String}],
      RECURSIVE_NESTED => [
        {path: "root.elements.field.0", registered_actual_types: ["Int64"] of String},
        {path: "root.elements.field.1.elements.field.0", registered_actual_types: ["Int64"] of String},
      ],
      MAP_PARENT => [{path: "root.elements.field.1.elements.field.0", registered_actual_types: ["Int64"] of String}],
    } of String => Array(NamedTuple(path: String, registered_actual_types: Array(String)))
  end

  def observed_types_by_site(
    name : String,
    values : Array(CrystalClick::BinaryValue),
  ) : Hash(String, Array(String))
    result = Hash(String, Array(String)).new
    dynamic_sites[name].each { |site| result[site[:path]] = [] of String }
    type = column_types[name]
    values.each { |value| collect_observed_types(type, value, "root", result) }
    result.each_value(&.sort!)
    result
  end

  def structures_for(name : String) : Hash(String, CrystalClick::DynamicStructure)
    structures = Hash(String, CrystalClick::DynamicStructure).new
    sites = dynamic_sites[name]? || raise ArgumentError.new("unknown W249 column: #{name}")
    actual_types = [CrystalClick::BinaryDataType.primitive("Int64")] of CrystalClick::BinaryDataType
    sites.each do |site|
      structures[site[:path]] = CrystalClick::DynamicStructure.new(actual_types)
    end
    structures
  end

  def columns : Array(CrystalClick::WidePartColumn)
    types = column_types
    TARGET_COLUMNS.map do |name|
      CrystalClick::WidePartColumn.dynamic_bulk(name, types[name], structures_for(name), marks(rows_for(name)))
    end
  end

  def rows_for(name : String) : Array(CrystalClick::BinaryValue)
    case name
    when ROOT_NESTED
      type = root_nested_type
      record_type = type.child_at(0)
      [
        nested(type, [] of CrystalClick::BinaryValue),
        nested(type, [] of CrystalClick::BinaryValue),
        nested(type, [
          root_record(record_type, int64(7), "root-a"),
          root_record(record_type, nil, nil),
          root_record(record_type, string("root-shared"), "root-b"),
        ] of CrystalClick::BinaryValue),
        nested(type, [] of CrystalClick::BinaryValue),
        nested(type, [
          root_record(record_type, string("root-tail"), "tail"),
          root_record(record_type, int64(23), nil),
        ] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue
    when ARRAY_NESTED
      type = array_nested_type
      nested_type = type.child_at(0)
      record_type = nested_type.child_at(0)
      [
        array(type, [] of CrystalClick::BinaryValue),
        array(type, [] of CrystalClick::BinaryValue),
        array(type, [nested(nested_type, [
          nested_record(record_type, int64(9), string("array-a")),
          nested_record(record_type, string("array-shared"), string("array-b")),
        ] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue),
        array(type, [nested(nested_type, [] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue),
        array(type, [
          nested(nested_type, [nested_record(record_type, nil, string("array-null"))] of CrystalClick::BinaryValue),
          nested(nested_type, [] of CrystalClick::BinaryValue),
          nested(nested_type, [nested_record(record_type, int64(29), string("array-tail"))] of CrystalClick::BinaryValue),
        ] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue
    when TUPLE_PARENT
      type = tuple_parent_type
      records_type = type.child_at(1)
      nested_type = records_type.child_at(0)
      record_type = nested_type.child_at(0)
      [
        parent_tuple(type, 1_u64, [] of CrystalClick::BinaryValue),
        parent_tuple(type, 2_u64, [] of CrystalClick::BinaryValue),
        parent_tuple(type, 3_u64, [nested(nested_type, [
          nested_record(record_type, int64(11), string("tuple-a")),
          nested_record(record_type, nil, string("tuple-null")),
        ] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue),
        parent_tuple(type, 4_u64, [] of CrystalClick::BinaryValue),
        parent_tuple(type, 5_u64, [nested(nested_type, [
          nested_record(record_type, int64(31), string("tuple-tail")),
          nested_record(record_type, string("tuple-shared-tail"), string("tuple-spill")),
        ] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue
    when RECURSIVE_NESTED
      type = recursive_nested_type
      outer_tuple = type.child_at(0)
      child_type = outer_tuple.child_at(1)
      child_tuple = child_type.child_at(0)
      tags_type = child_tuple.child_at(1)
      [
        nested(type, [] of CrystalClick::BinaryValue),
        nested(type, [] of CrystalClick::BinaryValue),
        nested(type, [
          recursive_record(outer_tuple, int64(13), child_type, [
            recursive_child(child_tuple, tags_type, nil, [string("x")]),
            recursive_child(child_tuple, tags_type, string("child-shared"), [] of CrystalClick::BinaryValue),
          ] of CrystalClick::BinaryValue),
        ] of CrystalClick::BinaryValue),
        nested(type, [] of CrystalClick::BinaryValue),
        nested(type, [
          recursive_record(outer_tuple, nil, child_type, [] of CrystalClick::BinaryValue),
          recursive_record(outer_tuple, string("parent-shared"), child_type, [
            recursive_child(child_tuple, tags_type, int64(37), [] of CrystalClick::BinaryValue),
            recursive_child(child_tuple, tags_type, nil, [string("tail"), string("tags")]),
          ] of CrystalClick::BinaryValue),
        ] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue
    when MAP_PARENT
      type = map_parent_type
      nested_type = type.child_at(1)
      record_type = nested_type.child_at(0)
      [
        map(type, [] of CrystalClick::BinaryValue),
        map(type, [] of CrystalClick::BinaryValue),
        map(type, [
          u64(17), nested(nested_type, [
            nested_record(record_type, int64(19), string("map-a")),
            nested_record(record_type, string("map-shared"), string("map-b")),
          ] of CrystalClick::BinaryValue),
        ] of CrystalClick::BinaryValue),
        map(type, [] of CrystalClick::BinaryValue),
        map(type, [
          u64(41), nested(nested_type, [nested_record(record_type, nil, string("map-null"))] of CrystalClick::BinaryValue),
          u64(43), nested(nested_type, [] of CrystalClick::BinaryValue),
        ] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue
    else
      raise ArgumentError.new("unknown W249 column: #{name}")
    end
  end

  def marks(rows : Array(CrystalClick::BinaryValue)) : Array(Array(CrystalClick::BinaryValue))
    result = Array(Array(CrystalClick::BinaryValue)).new
    rows.each_slice(ROWS_PER_MARK) { |slice| result << slice.to_a }
    result
  end

  def write_part(destination : String, profile_name : String, frame_bytes : Int = FRAME_BYTES) : String
    CrystalClick::WidePartWriter.write_uint64_columns(
      destination,
      KEY_NAME,
      KEYS.to_unsafe.to_slice(KEYS.size),
      columns,
      rows_per_mark: ROWS_PER_MARK,
      profile: profile(profile_name),
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
      frame_bytes: frame_bytes,
    )
  end

  def expected_rows : Array(JSON::Any)
    JSON.parse(EXPECTED_ROWS_JSON).as_a
  end

  def expected_rows_json : String
    JSON.parse(EXPECTED_ROWS_JSON).to_json
  end

  def row_signature(value : CrystalClick::BinaryValue) : JSON::Any
    case value.type.tag
    when CrystalClick::BinaryDataType::TAG_DYNAMIC
      if value.child_count == 0
        JSON::Any.new([JSON::Any.new("NULL"), JSON::Any.new(nil)])
      else
        child = value.child_at(0)
        JSON::Any.new([JSON::Any.new(child.type.name), scalar_signature(child)])
      end
    when CrystalClick::BinaryDataType::TAG_NESTED
      JSON::Any.new(value.elements.map { |record| row_signature(record) })
    when CrystalClick::BinaryDataType::TAG_ARRAY
      JSON::Any.new(value.elements.map { |element| row_signature(element) })
    when CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE, CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
      JSON::Any.new(value.elements.map { |field| row_signature(field) })
    when CrystalClick::BinaryDataType::TAG_MAP
      entries = [] of JSON::Any
      index = 0
      while index < value.child_count
        entries << JSON::Any.new([row_signature(value.child_at(index)), row_signature(value.child_at(index + 1))])
        index += 2
      end
      JSON::Any.new(entries)
    when CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY
      row_signature(value.child_at(0))
    when CrystalClick::BinaryDataType::TAG_NULLABLE
      value.is_null? ? JSON::Any.new(nil) : row_signature(value.child_at(0))
    when CrystalClick::BinaryDataType::TAG_NOTHING
      JSON::Any.new(nil)
    else
      scalar_signature(value)
    end
  end

  def row_record(key : UInt64, values : Hash(String, CrystalClick::BinaryValue)) : JSON::Any
    object = Hash(String, JSON::Any).new
    object[KEY_NAME] = JSON::Any.new(key.to_i64)
    TARGET_COLUMNS.each { |name| object[name] = row_signature(values[name]) }
    JSON::Any.new(object)
  end

  def rows_equal?(left : Array(JSON::Any), right : Array(JSON::Any)) : Bool
    left.size == right.size && left.each_with_index.all? { |row, index| row.to_json == right[index].to_json }
  end

  private def scalar_signature(value : CrystalClick::BinaryValue) : JSON::Any
    case value.type.tag
    when CrystalClick::BinaryDataType::TAG_STRING
      JSON::Any.new(String.new(value.bytes))
    when CrystalClick::BinaryDataType::TAG_INT64
      bits = read_u64_le(value.bytes)
      JSON::Any.new(bits.unsafe_as(Int64))
    when CrystalClick::BinaryDataType::TAG_UINT64
      JSON::Any.new(read_u64_le(value.bytes).to_i64)
    else
      raise CrystalClick::UnsupportedFormatError.new("W249 semantic witness does not support #{value.type.name}")
    end
  end

  private def read_u64_le(bytes : Bytes) : UInt64
    raise CrystalClick::CorruptPartError.new("W249 Int64 witness has the wrong width") unless bytes.size == 8
    value = 0_u64
    8.times { |index| value |= bytes[index].to_u64 << (index * 8) }
    value
  end

  private def collect_observed_types(
    type : CrystalClick::BinaryDataType,
    value : CrystalClick::BinaryValue,
    path : String,
    result : Hash(String, Array(String)),
  ) : Nil
    case type.tag
    when CrystalClick::BinaryDataType::TAG_DYNAMIC
      if value.child_count > 0
        actual_type = value.child_at(0).type.name
        types = result[path]? || raise CrystalClick::CorruptPartError.new("unexpected W249 Dynamic site: #{path}")
        types << actual_type unless types.includes?(actual_type)
      end
    when CrystalClick::BinaryDataType::TAG_ARRAY
      value.elements.each do |element|
        collect_observed_types(type.child_at(0), element, "#{path}.elements", result)
      end
    when CrystalClick::BinaryDataType::TAG_NESTED
      tuple_type = type.child_at(0)
      value.elements.each do |record|
        tuple_type.child_count.times do |index|
          collect_observed_types(
            tuple_type.child_at(index),
            record.child_at(index),
            "#{path}.elements.field.#{index}",
            result,
          )
        end
      end
    when CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE, CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
      type.child_count.times do |index|
        collect_observed_types(type.child_at(index), value.child_at(index), "#{path}.field.#{index}", result)
      end
    when CrystalClick::BinaryDataType::TAG_MAP
      elements = value.elements
      (0...elements.size).step(2) do |index|
        collect_observed_types(type.child_at(0), elements[index], "#{path}.elements.field.0", result)
        collect_observed_types(type.child_at(1), elements[index + 1], "#{path}.elements.field.1", result)
      end
    when CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY
      collect_observed_types(type.child_at(0), value.child_at(0), path, result)
    when CrystalClick::BinaryDataType::TAG_NULLABLE
      unless value.is_null?
        collect_observed_types(type.child_at(0), value.child_at(0), "#{path}.nested", result)
      end
    end
    nil
  end

  private def dynamic(child : CrystalClick::BinaryValue?) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.dynamic(dynamic_type, child)
  end

  private def int64(value : Int64) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.int64(value)
  end

  private def string(value : String) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.string(value)
  end

  private def u64(value : UInt64) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.uint64(value)
  end

  private def nested(type : CrystalClick::BinaryDataType, rows : Array(CrystalClick::BinaryValue)) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.nested(type, rows)
  end

  private def array(type : CrystalClick::BinaryDataType, values : Array(CrystalClick::BinaryValue)) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.array(type, values)
  end

  private def map(type : CrystalClick::BinaryDataType, values : Array(CrystalClick::BinaryValue)) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.map(type, values)
  end

  private def nested_record(
    tuple_type : CrystalClick::BinaryDataType,
    actual : CrystalClick::BinaryValue?,
    label : CrystalClick::BinaryValue,
  ) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.tuple(tuple_type, [dynamic(actual), label] of CrystalClick::BinaryValue)
  end

  private def root_record(
    tuple_type : CrystalClick::BinaryDataType,
    actual : CrystalClick::BinaryValue?,
    label : String?,
  ) : CrystalClick::BinaryValue
    low_cardinality = tuple_type.child_at(1)
    nullable = low_cardinality.child_at(0)
    nullable_value = if label
                       CrystalClick::BinaryValue.nullable(nullable, string(label))
                     else
                       CrystalClick::BinaryValue.nullable(nullable)
                     end
    low_value = CrystalClick::BinaryValue.low_cardinality(low_cardinality, nullable_value)
    nested_record(tuple_type, actual, low_value)
  end

  private def recursive_record(
    tuple_type : CrystalClick::BinaryDataType,
    actual : CrystalClick::BinaryValue?,
    child_type : CrystalClick::BinaryDataType,
    children : Array(CrystalClick::BinaryValue),
  ) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.tuple(tuple_type, [dynamic(actual), nested(child_type, children)] of CrystalClick::BinaryValue)
  end

  private def recursive_child(
    tuple_type : CrystalClick::BinaryDataType,
    tags_type : CrystalClick::BinaryDataType,
    actual : CrystalClick::BinaryValue?,
    tags : Array(CrystalClick::BinaryValue),
  ) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.tuple(tuple_type, [dynamic(actual), array(tags_type, tags)] of CrystalClick::BinaryValue)
  end

  private def parent_tuple(
    tuple_type : CrystalClick::BinaryDataType,
    key : UInt64,
    records : Array(CrystalClick::BinaryValue),
  ) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.tuple(tuple_type, [u64(key), array(tuple_type.child_at(1), records)] of CrystalClick::BinaryValue)
  end
end
