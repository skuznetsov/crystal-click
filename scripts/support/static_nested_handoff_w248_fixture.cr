require "../../src/crystal_click"
require "digest/sha256"

module StaticNestedHandoffW248Fixture
  extend self

  FORMAT              = "static_nested_handoff_w248_fixture_v1"
  KEY_NAME            = "pk"
  ROOT_COLUMN         = "root_nested"
  ARRAY_PARENT_COLUMN = "array_parent"
  RECURSIVE_COLUMN    = "recursive_nested"
  STRING0_COLUMN      = "string0"
  STRING1_COLUMN      = "string1"
  FRAME_BYTES         = 32
  ROWS_PER_MARK       =  2
  KEYS                = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
  MARK_ROW_COUNTS     = [2_u64, 2_u64, 1_u64]
  TARGET_COLUMNS      = [ROOT_COLUMN, ARRAY_PARENT_COLUMN, RECURSIVE_COLUMN]
  STRING_COLUMNS      = [STRING0_COLUMN, STRING1_COLUMN]

  def profile(name : String) : CrystalClick::BinaryBulkProfile
    case name
    when "single", "s0"
      CrystalClick::BinaryBulkProfile.single_stream
    when "sized", "s1"
      CrystalClick::BinaryBulkProfile.with_size_stream
    else
      raise ArgumentError.new("W248 String profile must be single or sized")
    end
  end

  def root_nested_type : CrystalClick::BinaryDataType
    string = CrystalClick::BinaryDataType.primitive("String")
    nullable_string = CrystalClick::BinaryDataType.nullable(string)
    label = CrystalClick::BinaryDataType.low_cardinality(nullable_string)
    choice = CrystalClick::BinaryDataType.variant(
      [string, CrystalClick::BinaryDataType.primitive("UInt64")] of CrystalClick::BinaryDataType
    )
    CrystalClick::BinaryDataType.nested(
      [label, choice, string] of CrystalClick::BinaryDataType,
      ["label", "choice", "note"] of String,
    )
  end

  def array_parent_type : CrystalClick::BinaryDataType
    nested = root_nested_type
    CrystalClick::BinaryDataType.tuple(
      [
        CrystalClick::BinaryDataType.primitive("UInt64"),
        CrystalClick::BinaryDataType.array(nested),
      ] of CrystalClick::BinaryDataType,
      ["id", "batches"] of String,
    )
  end

  def recursive_nested_type : CrystalClick::BinaryDataType
    string = CrystalClick::BinaryDataType.primitive("String")
    nullable_string = CrystalClick::BinaryDataType.nullable(string)
    label = CrystalClick::BinaryDataType.low_cardinality(nullable_string)
    choice = CrystalClick::BinaryDataType.variant(
      [string, CrystalClick::BinaryDataType.primitive("UInt64")] of CrystalClick::BinaryDataType
    )
    child_nested = CrystalClick::BinaryDataType.nested(
      [string, CrystalClick::BinaryDataType.array(string)] of CrystalClick::BinaryDataType,
      ["note", "tags"] of String,
    )
    CrystalClick::BinaryDataType.nested(
      [label, choice, string, child_nested] of CrystalClick::BinaryDataType,
      ["label", "choice", "note", "child"] of String,
    )
  end

  # Same physical Array(named Tuple(...)) shape as root Nested, but with a
  # distinct nominal declaration. It is used only to prove that persisted
  # Nested identity is not erased by a shape-compatible reader request.
  def array_tuple_substitution_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.array(root_nested_type.child_at(0))
  end

  def types : Hash(String, CrystalClick::BinaryDataType)
    {
      ROOT_COLUMN         => root_nested_type,
      ARRAY_PARENT_COLUMN => array_parent_type,
      RECURSIVE_COLUMN    => recursive_nested_type,
      STRING0_COLUMN      => CrystalClick::BinaryDataType.primitive("String"),
      STRING1_COLUMN      => CrystalClick::BinaryDataType.primitive("String"),
    } of String => CrystalClick::BinaryDataType
  end

  def columns : Array(CrystalClick::WidePartColumn)
    declared_types = types
    result = Array(CrystalClick::WidePartColumn).new(declared_types.size)
    TARGET_COLUMNS.each do |name|
      result << CrystalClick::WidePartColumn.binary_bulk(
        name,
        declared_types[name],
        marks(rows_for(name)),
      )
    end
    STRING_COLUMNS.each do |name|
      result << CrystalClick::WidePartColumn.binary_bulk(
        name,
        declared_types[name],
        marks(rows_for(name)),
      )
    end
    result
  end

  def rows_for(name : String) : Array(CrystalClick::BinaryValue)
    case name
    when ROOT_COLUMN
      type = root_nested_type
      record_type = type.child_at(0)
      [
        nested_value(type, [] of CrystalClick::BinaryValue),
        nested_value(type, [
          rich_record(record_type, "red", CrystalClick::BinaryValue.string("arm-red"), "first"),
          rich_record(record_type, nil, CrystalClick::BinaryValue.uint64(42_u64), "second"),
          rich_record(record_type, "", nil, "default-null-variant"),
        ] of CrystalClick::BinaryValue),
        nested_value(type, [] of CrystalClick::BinaryValue),
        nested_value(type, [
          rich_record(record_type, "blue", CrystalClick::BinaryValue.uint64(0_u64), "later"),
        ] of CrystalClick::BinaryValue),
        nested_value(type, [
          rich_record(record_type, "red", CrystalClick::BinaryValue.string("arm-tail"), "tail"),
          rich_record(record_type, nil, CrystalClick::BinaryValue.uint64(UInt64::MAX), "final"),
        ] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue
    when ARRAY_PARENT_COLUMN
      type = array_parent_type
      batches_type = type.child_at(1)
      root_rows = rows_for(ROOT_COLUMN)
      [
        tuple_value(type, CrystalClick::BinaryValue.uint64(1_u64), array_value(batches_type, [] of CrystalClick::BinaryValue)),
        tuple_value(type, CrystalClick::BinaryValue.uint64(2_u64), array_value(batches_type, [root_rows[1], root_rows[0]] of CrystalClick::BinaryValue)),
        tuple_value(type, CrystalClick::BinaryValue.uint64(3_u64), array_value(batches_type, [] of CrystalClick::BinaryValue)),
        tuple_value(type, CrystalClick::BinaryValue.uint64(4_u64), array_value(batches_type, [root_rows[3]] of CrystalClick::BinaryValue)),
        tuple_value(type, CrystalClick::BinaryValue.uint64(5_u64), array_value(batches_type, [root_rows[4], root_rows[2]] of CrystalClick::BinaryValue)),
      ] of CrystalClick::BinaryValue
    when RECURSIVE_COLUMN
      type = recursive_nested_type
      record_type = type.child_at(0)
      child_type = record_type.child_at(3)
      child_record_type = child_type.child_at(0)
      tags_type = child_record_type.child_at(1)
      [
        nested_value(type, [] of CrystalClick::BinaryValue),
        nested_value(type, [] of CrystalClick::BinaryValue),
        nested_value(type, [
          recursive_record(
            record_type, child_type, child_record_type, tags_type,
            "red", CrystalClick::BinaryValue.string("outer-arm"), "outer-first",
            [
              child_record(child_record_type, tags_type, "child-empty-tags", [] of CrystalClick::BinaryValue),
              child_record(child_record_type, tags_type, "child-ragged", [
                CrystalClick::BinaryValue.string("r"), CrystalClick::BinaryValue.string("s"),
              ] of CrystalClick::BinaryValue),
            ] of CrystalClick::BinaryValue,
          ),
          recursive_record(
            record_type, child_type, child_record_type, tags_type,
            nil, CrystalClick::BinaryValue.uint64(77_u64), "outer-second",
            [] of CrystalClick::BinaryValue,
          ),
        ] of CrystalClick::BinaryValue),
        nested_value(type, [
          recursive_record(
            record_type, child_type, child_record_type, tags_type,
            "", nil, "outer-later",
            [child_record(child_record_type, tags_type, "child-later", [
              CrystalClick::BinaryValue.string("x"),
            ] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
          ),
        ] of CrystalClick::BinaryValue),
        nested_value(type, [
          recursive_record(
            record_type, child_type, child_record_type, tags_type,
            "red", CrystalClick::BinaryValue.uint64(0_u64), "outer-tail",
            [] of CrystalClick::BinaryValue,
          ),
          recursive_record(
            record_type, child_type, child_record_type, tags_type,
            nil, CrystalClick::BinaryValue.string("outer-final-arm"), "outer-final",
            [child_record(child_record_type, tags_type, "child-final", [] of CrystalClick::BinaryValue)] of CrystalClick::BinaryValue,
          ),
        ] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue
    when STRING0_COLUMN
      ["plain-first", "plain-second", "plain-middle", "nul\0byte", "plain-final"].map do |value|
        CrystalClick::BinaryValue.string(value)
      end
    when STRING1_COLUMN
      ["", "repeat", "repeat", "tail\0byte", "last"].map do |value|
        CrystalClick::BinaryValue.string(value)
      end
    else
      raise ArgumentError.new("unknown W248 column: #{name}")
    end
  end

  def array_tuple_substitution_rows : Array(CrystalClick::BinaryValue)
    array_type = array_tuple_substitution_type
    rows_for(ROOT_COLUMN).map do |nested|
      records = Array(CrystalClick::BinaryValue).new(nested.child_count)
      nested.child_count.times { |index| records << nested.child_at(index) }
      CrystalClick::BinaryValue.array(array_type, records)
    end
  end

  def marks(rows : Array(CrystalClick::BinaryValue)) : Array(Array(CrystalClick::BinaryValue))
    result = Array(Array(CrystalClick::BinaryValue)).new
    rows.each_slice(ROWS_PER_MARK) { |slice| result << slice.to_a }
    result
  end

  def write_part(
    destination : String,
    profile_name : String,
    frame_bytes : Int = FRAME_BYTES,
  ) : String
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

  # Independent direct nominal-Nested control over the existing pair writer.
  # It intentionally shares the literal value corpus, but not the N-column
  # input-admission path under test.
  def write_direct_control(
    destination : String,
    profile_name : String,
    frame_bytes : Int = FRAME_BYTES,
  ) : String
    type = root_nested_type
    CrystalClick::WidePartWriter.write_uint64_nested_bulk_part(
      destination,
      KEY_NAME,
      KEYS.to_unsafe.to_slice(KEYS.size),
      ROOT_COLUMN,
      type,
      marks(rows_for(ROOT_COLUMN)),
      rows_per_mark: ROWS_PER_MARK,
      profile: profile(profile_name),
      frame_bytes: frame_bytes,
    )
  end

  # A projection child carries its own complete grid and exactly one selected
  # generic Nested value column; it is not copied from the parent table lane.
  def write_projection_part(destination : String, profile_name : String) : String
    type = recursive_nested_type
    column = CrystalClick::WidePartColumn.binary_bulk(
      "projected", type, marks(rows_for(RECURSIVE_COLUMN))
    )
    CrystalClick::WidePartWriter.write_uint64_columns(
      destination,
      KEY_NAME,
      KEYS.to_unsafe.to_slice(KEYS.size),
      [column] of CrystalClick::WidePartColumn,
      rows_per_mark: ROWS_PER_MARK,
      profile: profile(profile_name),
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
      frame_bytes: FRAME_BYTES,
    )
  end

  def write_array_tuple_substitution_part(
    destination : String,
    profile_name : String,
  ) : String
    type = array_tuple_substitution_type
    column = CrystalClick::WidePartColumn.binary_bulk(
      "shape_substitute", type, marks(array_tuple_substitution_rows)
    )
    CrystalClick::WidePartWriter.write_uint64_columns(
      destination,
      KEY_NAME,
      KEYS.to_unsafe.to_slice(KEYS.size),
      [column] of CrystalClick::WidePartColumn,
      rows_per_mark: ROWS_PER_MARK,
      profile: profile(profile_name),
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
      frame_bytes: FRAME_BYTES,
    )
  end

  # Structural signature includes the nominal descriptor, NULL state,
  # Variant discriminator, scalar bytes, and recursively ordered child values.
  def row_signature(value : CrystalClick::BinaryValue) : String
    String.build do |io|
      io << value.type.name << '\0'
      io << (value.is_null? ? '1' : '0') << '\0'
      if value.type.tag == CrystalClick::BinaryDataType::TAG_VARIANT
        if variant_index = value.variant_index?
          io << variant_index << '\0'
        end
      end
      if value.byte_size > 0
        value.bytes.each { |byte| io << byte.to_s(16).rjust(2, '0') }
      end
      io << '['
      value.child_count.times do |index|
        io << row_signature(value.child_at(index)) << ';'
      end
      io << ']'
    end
  end

  def row_hash(value : CrystalClick::BinaryValue) : String
    Digest::SHA256.hexdigest(row_signature(value))
  end

  private def rich_record(
    type : CrystalClick::BinaryDataType,
    label : String?,
    variant_child : CrystalClick::BinaryValue?,
    note : String,
  ) : CrystalClick::BinaryValue
    label_type = type.child_at(0)
    nullable_string_type = label_type.child_at(0)
    label_value = CrystalClick::BinaryValue.low_cardinality(
      label_type,
      CrystalClick::BinaryValue.nullable(
        nullable_string_type,
        label.try { |value| CrystalClick::BinaryValue.string(value) },
      ),
    )
    choice_type = type.child_at(1)
    choice = if child = variant_child
               index = choice_type.children.index(child.type).not_nil!.to_i
               CrystalClick::BinaryValue.variant(choice_type, index, child)
             else
               CrystalClick::BinaryValue.variant_null(choice_type)
             end
    tuple_value(type, label_value, choice, CrystalClick::BinaryValue.string(note))
  end

  private def recursive_record(
    type : CrystalClick::BinaryDataType,
    child_type : CrystalClick::BinaryDataType,
    child_record_type : CrystalClick::BinaryDataType,
    tags_type : CrystalClick::BinaryDataType,
    label : String?,
    variant_child : CrystalClick::BinaryValue?,
    note : String,
    child_records : Array(CrystalClick::BinaryValue),
  ) : CrystalClick::BinaryValue
    label_type = type.child_at(0)
    nullable_string_type = label_type.child_at(0)
    label_value = CrystalClick::BinaryValue.low_cardinality(
      label_type,
      CrystalClick::BinaryValue.nullable(
        nullable_string_type,
        label.try { |value| CrystalClick::BinaryValue.string(value) },
      ),
    )
    choice_type = type.child_at(1)
    choice = if child = variant_child
               index = choice_type.children.index(child.type).not_nil!.to_i
               CrystalClick::BinaryValue.variant(choice_type, index, child)
             else
               CrystalClick::BinaryValue.variant_null(choice_type)
             end
    child_value = nested_value(child_type, child_records)
    tuple_value(
      type,
      label_value,
      choice,
      CrystalClick::BinaryValue.string(note),
      child_value,
    )
  end

  private def child_record(
    type : CrystalClick::BinaryDataType,
    tags_type : CrystalClick::BinaryDataType,
    note : String,
    tags : Array(CrystalClick::BinaryValue),
  ) : CrystalClick::BinaryValue
    tuple_value(type, CrystalClick::BinaryValue.string(note), array_value(tags_type, tags))
  end

  private def nested_value(
    type : CrystalClick::BinaryDataType,
    records : Array(CrystalClick::BinaryValue),
  ) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.nested(type, records)
  end

  private def array_value(
    type : CrystalClick::BinaryDataType,
    children : Array(CrystalClick::BinaryValue),
  ) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.array(type, children)
  end

  private def tuple_value(
    type : CrystalClick::BinaryDataType,
    first : CrystalClick::BinaryValue,
    second : CrystalClick::BinaryValue,
  ) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.tuple(type, [first, second] of CrystalClick::BinaryValue)
  end

  private def tuple_value(
    type : CrystalClick::BinaryDataType,
    first : CrystalClick::BinaryValue,
    second : CrystalClick::BinaryValue,
    third : CrystalClick::BinaryValue,
  ) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.tuple(type, [first, second, third] of CrystalClick::BinaryValue)
  end

  private def tuple_value(
    type : CrystalClick::BinaryDataType,
    first : CrystalClick::BinaryValue,
    second : CrystalClick::BinaryValue,
    third : CrystalClick::BinaryValue,
    fourth : CrystalClick::BinaryValue,
  ) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.tuple(type, [first, second, third, fourth] of CrystalClick::BinaryValue)
  end
end
