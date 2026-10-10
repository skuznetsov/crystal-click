require "../../src/crystal_click"
require "digest/sha256"

module StaticBinaryBulkTableW247Fixture
  extend self

  FORMAT               = "static_binary_bulk_table_w247_fixture_v1"
  KEY_NAME             = "pk"
  VARIANT_COLUMN       = "root_variant"
  ARRAY_VARIANT_COLUMN = "array_variant"
  TUPLE_COLUMN         = "named_recursive"
  STRING0_COLUMN       = "string0"
  STRING1_COLUMN       = "string1"
  FRAME_BYTES          = 32
  ROWS_PER_MARK        =  2
  KEYS                 = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
  MARK_ROW_COUNTS      = [2_u64, 2_u64, 1_u64]
  TARGET_COLUMNS       = [VARIANT_COLUMN, ARRAY_VARIANT_COLUMN, TUPLE_COLUMN]
  STRING_COLUMNS       = [STRING0_COLUMN, STRING1_COLUMN]

  def profile(name : String) : CrystalClick::BinaryBulkProfile
    case name
    when "single"
      CrystalClick::BinaryBulkProfile.single_stream
    when "sized"
      CrystalClick::BinaryBulkProfile.with_size_stream
    else
      raise ArgumentError.new("W247 String profile must be single or sized")
    end
  end

  def variant_type : CrystalClick::BinaryDataType
    u16_array = CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.primitive("UInt16")
    )
    CrystalClick::BinaryDataType.variant(
      [u16_array, CrystalClick::BinaryDataType.primitive("String")] of CrystalClick::BinaryDataType
    )
  end

  def array_variant_type : CrystalClick::BinaryDataType
    low_cardinality_string = CrystalClick::BinaryDataType.low_cardinality(
      CrystalClick::BinaryDataType.primitive("String")
    )
    variant = CrystalClick::BinaryDataType.variant(
      [low_cardinality_string, CrystalClick::BinaryDataType.primitive("UInt64")] of CrystalClick::BinaryDataType
    )
    CrystalClick::BinaryDataType.array(variant)
  end

  def tuple_type : CrystalClick::BinaryDataType
    nullable_int32 = CrystalClick::BinaryDataType.nullable(
      CrystalClick::BinaryDataType.primitive("Int32")
    )
    array_nullable_int32 = CrystalClick::BinaryDataType.array(nullable_int32)
    low_cardinality_nullable_string = CrystalClick::BinaryDataType.low_cardinality(
      CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("String"))
    )
    CrystalClick::BinaryDataType.tuple(
      [array_nullable_int32, low_cardinality_nullable_string, variant_type] of CrystalClick::BinaryDataType,
      ["arr", "labels", "choice"] of String,
    )
  end

  def types : Hash(String, CrystalClick::BinaryDataType)
    {
      VARIANT_COLUMN       => variant_type,
      ARRAY_VARIANT_COLUMN => array_variant_type,
      TUPLE_COLUMN         => tuple_type,
      STRING0_COLUMN       => CrystalClick::BinaryDataType.primitive("String"),
      STRING1_COLUMN       => CrystalClick::BinaryDataType.primitive("String"),
    } of String => CrystalClick::BinaryDataType
  end

  def columns : Array(CrystalClick::WidePartColumn)
    types = types()
    result = Array(CrystalClick::WidePartColumn).new(types.size)
    TARGET_COLUMNS.each do |name|
      result << CrystalClick::WidePartColumn.binary_bulk(name, types[name], marks(rows_for(name)))
    end
    result << CrystalClick::WidePartColumn.binary_bulk(
      STRING0_COLUMN, types[STRING0_COLUMN], marks(rows_for(STRING0_COLUMN))
    )
    result << CrystalClick::WidePartColumn.binary_bulk(
      STRING1_COLUMN, types[STRING1_COLUMN], marks(rows_for(STRING1_COLUMN))
    )
    result
  end

  def rows_for(name : String) : Array(CrystalClick::BinaryValue)
    case name
    when VARIANT_COLUMN
      type = variant_type
      array_arm = type.child_at(0)
      u16 = array_arm.child_at(0)
      [
        variant(type, array_value(array_arm, [fixed_unsigned(u16, 7_u64), fixed_unsigned(u16, 65_535_u64)] of CrystalClick::BinaryValue)),
        variant(type, CrystalClick::BinaryValue.string("root-string")),
        variant(type, array_value(array_arm, [] of CrystalClick::BinaryValue)),
        CrystalClick::BinaryValue.variant_null(type),
        variant(type, CrystalClick::BinaryValue.string("root-tail")),
      ] of CrystalClick::BinaryValue
    when ARRAY_VARIANT_COLUMN
      type = array_variant_type
      variant_type = type.child_at(0)
      low_cardinality = variant_type.child_at(0)
      [
        array_value(type, [
          variant(variant_type, CrystalClick::BinaryValue.low_cardinality(low_cardinality, CrystalClick::BinaryValue.string("red"))),
          variant(variant_type, CrystalClick::BinaryValue.uint64(9_u64)),
        ] of CrystalClick::BinaryValue),
        array_value(type, [] of CrystalClick::BinaryValue),
        array_value(type, [
          variant(variant_type, CrystalClick::BinaryValue.low_cardinality(low_cardinality, CrystalClick::BinaryValue.string("red"))),
          variant(variant_type, CrystalClick::BinaryValue.low_cardinality(low_cardinality, CrystalClick::BinaryValue.string("blue"))),
        ] of CrystalClick::BinaryValue),
        array_value(type, [variant(variant_type, CrystalClick::BinaryValue.uint64(0_u64))] of CrystalClick::BinaryValue),
        array_value(type, [
          variant(variant_type, CrystalClick::BinaryValue.low_cardinality(low_cardinality, CrystalClick::BinaryValue.string("tail"))),
          variant(variant_type, CrystalClick::BinaryValue.uint64(UInt64::MAX)),
        ] of CrystalClick::BinaryValue),
      ] of CrystalClick::BinaryValue
    when TUPLE_COLUMN
      type = tuple_type
      array_type = type.child_at(0)
      nullable_int32 = array_type.child_at(0)
      labels_type = type.child_at(1)
      nullable_string = labels_type.child_at(0)
      choice_type = type.child_at(2)
      [
        tuple_value(type,
          array_value(array_type, [nullable(nullable_int32, fixed_signed(nullable_int32.child_at(0), 1_i32)), nullable(nullable_int32), nullable(nullable_int32, fixed_signed(nullable_int32.child_at(0), -3_i32))] of CrystalClick::BinaryValue),
          low_cardinality(labels_type, nullable(nullable_string, CrystalClick::BinaryValue.string("alpha"))),
          variant(choice_type, array_value(choice_type.child_at(0), [fixed_unsigned(choice_type.child_at(0).child_at(0), 0_u64), fixed_unsigned(choice_type.child_at(0).child_at(0), 65_535_u64)] of CrystalClick::BinaryValue))),
        tuple_value(type,
          array_value(array_type, [] of CrystalClick::BinaryValue),
          low_cardinality(labels_type, nullable(nullable_string)),
          variant(choice_type, CrystalClick::BinaryValue.string("tuple-string"))),
        tuple_value(type,
          array_value(array_type, [nullable(nullable_int32)] of CrystalClick::BinaryValue),
          low_cardinality(labels_type, nullable(nullable_string, CrystalClick::BinaryValue.string("alpha"))),
          CrystalClick::BinaryValue.variant_null(choice_type)),
        tuple_value(type,
          array_value(array_type, [nullable(nullable_int32, fixed_signed(nullable_int32.child_at(0), 99_i32))] of CrystalClick::BinaryValue),
          low_cardinality(labels_type, nullable(nullable_string, CrystalClick::BinaryValue.string("β"))),
          variant(choice_type, array_value(choice_type.child_at(0), [] of CrystalClick::BinaryValue))),
        tuple_value(type,
          array_value(array_type, [nullable(nullable_int32, fixed_signed(nullable_int32.child_at(0), 0_i32)), nullable(nullable_int32, fixed_signed(nullable_int32.child_at(0), Int32::MIN))] of CrystalClick::BinaryValue),
          low_cardinality(labels_type, nullable(nullable_string)),
          variant(choice_type, CrystalClick::BinaryValue.string("tuple-tail"))),
      ] of CrystalClick::BinaryValue
    when STRING0_COLUMN
      ["plain-1", "plain-2", "plain-3", "plain-4", "plain-5"].map do |value|
        CrystalClick::BinaryValue.string(value)
      end
    when STRING1_COLUMN
      ["", "repeat", "repeat", "nul\0byte", "last"].map do |value|
        CrystalClick::BinaryValue.string(value)
      end
    else
      raise ArgumentError.new("unknown W247 column: #{name}")
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

  # A projection child has its own physical schema and row grid. Keep the
  # selected name distinct from the parent so OfflineTable routing cannot
  # accidentally succeed by reading a same-named parent column.
  def write_projection_part(destination : String, profile_name : String) : String
    projection_column = CrystalClick::WidePartColumn.binary_bulk(
      "projected",
      variant_type,
      marks(rows_for(VARIANT_COLUMN)),
    )
    CrystalClick::WidePartWriter.write_uint64_columns(
      destination,
      KEY_NAME,
      KEYS.to_unsafe.to_slice(KEYS.size),
      [projection_column] of CrystalClick::WidePartColumn,
      rows_per_mark: ROWS_PER_MARK,
      profile: profile(profile_name),
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
      frame_bytes: FRAME_BYTES,
    )
  end

  # Structural, typed signature for a bounded fixture row. This deliberately
  # records nominal SQL descriptors, NULL state, Variant discriminator,
  # scalar bytes and recursive child order without relying on value identity.
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

  private def variant(
    type : CrystalClick::BinaryDataType,
    child : CrystalClick::BinaryValue,
  ) : CrystalClick::BinaryValue
    type.child_count.times do |index|
      return CrystalClick::BinaryValue.variant(type, index, child) if type.child_at(index) == child.type
    end
    raise ArgumentError.new("W247 Variant child is absent from its canonical arm roster")
  end

  private def array_value(
    type : CrystalClick::BinaryDataType,
    children : Array(CrystalClick::BinaryValue),
  ) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.array(type, children)
  end

  private def nullable(
    type : CrystalClick::BinaryDataType,
    child : CrystalClick::BinaryValue? = nil,
  ) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.nullable(type, child)
  end

  private def low_cardinality(
    type : CrystalClick::BinaryDataType,
    child : CrystalClick::BinaryValue,
  ) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.low_cardinality(type, child)
  end

  private def tuple_value(
    type : CrystalClick::BinaryDataType,
    first : CrystalClick::BinaryValue,
    second : CrystalClick::BinaryValue,
    third : CrystalClick::BinaryValue,
  ) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.tuple(type, [first, second, third] of CrystalClick::BinaryValue)
  end

  private def fixed_unsigned(
    type : CrystalClick::BinaryDataType,
    value : UInt64,
  ) : CrystalClick::BinaryValue
    width = type.fixed_width || raise ArgumentError.new("W247 unsigned fixture type is not fixed-width")
    bytes = Bytes.new(width) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
    CrystalClick::BinaryValue.fixed(type, bytes)
  end

  private def fixed_signed(
    type : CrystalClick::BinaryDataType,
    value : Int32,
  ) : CrystalClick::BinaryValue
    width = type.fixed_width || raise ArgumentError.new("W247 signed fixture type is not fixed-width")
    bits = value.unsafe_as(UInt32)
    bytes = Bytes.new(width) { |index| ((bits >> (index * 8)) & 0xff_u32).to_u8 }
    CrystalClick::BinaryValue.fixed(type, bytes)
  end
end
