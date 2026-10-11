require "../../src/crystal_click"

module StaticRecursiveSelectedMetadataW258Fixture
  extend self

  FORMAT                 = "static_recursive_selected_metadata_w258_fixture_v1"
  KEY_NAME               = "pk"
  U_COLUMN               = "u"
  SIDE_COLUMN            = "side"
  ARRAY_COLUMN           = "arr"
  TUPLE_COLUMN           = "tup"
  LOW_CARDINALITY_COLUMN = "lc"
  VARIANT_COLUMN         = "v"
  ROWS_PER_MARK          = 2
  MARK_ROW_COUNTS        = [2_u64, 2_u64, 2_u64, 2_u64]
  KEYS                   = [1001_u64, 1002_u64, 1003_u64, 1004_u64, 1005_u64, 1006_u64, 1007_u64, 1008_u64]
  U_VALUES               = [2001_u64, 2002_u64, 2003_u64, 2004_u64, 2005_u64, 2006_u64, 2007_u64, 2008_u64]
  SIDE_VALUES            = ["side-0", "side-1", "side-2", "side-3", "side-4", "side-5", "side-6", "side-7"]
  LOW_CARDINALITY_VALUES = ["dup", "red", "dup", "", "blue", "dup", "blue", "tail"]

  def array_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.array(
      CrystalClick::BinaryDataType.nullable(
        CrystalClick::BinaryDataType.primitive("UInt64")
      )
    )
  end

  def tuple_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.tuple(
      [
        CrystalClick::BinaryDataType.primitive("UInt64"),
        CrystalClick::BinaryDataType.primitive("String"),
      ] of CrystalClick::BinaryDataType,
      ["n", "s"] of String,
    )
  end

  def low_cardinality_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.low_cardinality(
      CrystalClick::BinaryDataType.primitive("String")
    )
  end

  def variant_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.variant(
      [
        CrystalClick::BinaryDataType.primitive("String"),
        CrystalClick::BinaryDataType.primitive("UInt64"),
      ] of CrystalClick::BinaryDataType
    )
  end

  def types : Hash(String, CrystalClick::BinaryDataType)
    {
      U_COLUMN               => CrystalClick::BinaryDataType.primitive("UInt64"),
      SIDE_COLUMN            => CrystalClick::BinaryDataType.primitive("String"),
      ARRAY_COLUMN           => array_type,
      TUPLE_COLUMN           => tuple_type,
      LOW_CARDINALITY_COLUMN => low_cardinality_type,
      VARIANT_COLUMN         => variant_type,
    } of String => CrystalClick::BinaryDataType
  end

  def type_for(name : String) : CrystalClick::BinaryDataType
    types[name]? || raise ArgumentError.new("unknown W258 fixture column: #{name}")
  end

  def uint64_rows : Array(CrystalClick::BinaryValue)
    U_VALUES.map { |value| CrystalClick::BinaryValue.uint64(value) }
  end

  def side_rows : Array(CrystalClick::BinaryValue)
    SIDE_VALUES.map { |value| CrystalClick::BinaryValue.string(value) }
  end

  def array_rows : Array(CrystalClick::BinaryValue)
    type = array_type
    nullable_type = type.child_at(0)
    [
      CrystalClick::BinaryValue.array(type, [] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(type, [] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(type, [
        CrystalClick::BinaryValue.nullable(nullable_type),
        CrystalClick::BinaryValue.nullable(nullable_type, CrystalClick::BinaryValue.uint64(17_u64)),
      ] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(type, [
        CrystalClick::BinaryValue.nullable(nullable_type, CrystalClick::BinaryValue.uint64(23_u64)),
      ] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(type, [
        CrystalClick::BinaryValue.nullable(nullable_type, CrystalClick::BinaryValue.uint64(0_u64)),
        CrystalClick::BinaryValue.nullable(nullable_type),
      ] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(type, [] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(type, [
        CrystalClick::BinaryValue.nullable(nullable_type, CrystalClick::BinaryValue.uint64(7_u64)),
        CrystalClick::BinaryValue.nullable(nullable_type, CrystalClick::BinaryValue.uint64(8_u64)),
        CrystalClick::BinaryValue.nullable(nullable_type),
      ] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(type, [
        CrystalClick::BinaryValue.nullable(nullable_type),
        CrystalClick::BinaryValue.nullable(nullable_type, CrystalClick::BinaryValue.uint64(9_u64)),
      ] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue
  end

  def tuple_rows : Array(CrystalClick::BinaryValue)
    type = tuple_type
    (0...8).map do |index|
      CrystalClick::BinaryValue.tuple(type, [
        CrystalClick::BinaryValue.uint64(3001_u64 + index.to_u64),
        CrystalClick::BinaryValue.string("tuple-#{index}"),
      ] of CrystalClick::BinaryValue)
    end
  end

  def low_cardinality_rows : Array(CrystalClick::BinaryValue)
    type = low_cardinality_type
    LOW_CARDINALITY_VALUES.map do |value|
      CrystalClick::BinaryValue.low_cardinality(type, CrystalClick::BinaryValue.string(value))
    end
  end

  def variant_rows : Array(CrystalClick::BinaryValue)
    type = variant_type
    [
      variant(type, CrystalClick::BinaryValue.string("variant-0")),
      variant(type, CrystalClick::BinaryValue.uint64(4002_u64)),
      CrystalClick::BinaryValue.variant_null(type),
      variant(type, CrystalClick::BinaryValue.string("variant-3")),
      variant(type, CrystalClick::BinaryValue.uint64(4005_u64)),
      variant(type, CrystalClick::BinaryValue.string("variant-5")),
      variant(type, CrystalClick::BinaryValue.uint64(4007_u64)),
      CrystalClick::BinaryValue.variant_null(type),
    ] of CrystalClick::BinaryValue
  end

  def marks(rows : Array(CrystalClick::BinaryValue)) : Array(Array(CrystalClick::BinaryValue))
    result = Array(Array(CrystalClick::BinaryValue)).new
    rows.each_slice(ROWS_PER_MARK) { |slice| result << slice.to_a }
    result
  end

  def columns : Array(CrystalClick::WidePartColumn)
    types = types()
    [
      CrystalClick::WidePartColumn.binary_bulk(U_COLUMN, types[U_COLUMN], marks(uint64_rows)),
      CrystalClick::WidePartColumn.binary_bulk(SIDE_COLUMN, types[SIDE_COLUMN], marks(side_rows)),
      CrystalClick::WidePartColumn.binary_bulk(ARRAY_COLUMN, types[ARRAY_COLUMN], marks(array_rows)),
      CrystalClick::WidePartColumn.binary_bulk(TUPLE_COLUMN, types[TUPLE_COLUMN], marks(tuple_rows)),
      CrystalClick::WidePartColumn.binary_bulk(LOW_CARDINALITY_COLUMN, types[LOW_CARDINALITY_COLUMN], marks(low_cardinality_rows)),
      CrystalClick::WidePartColumn.binary_bulk(VARIANT_COLUMN, types[VARIANT_COLUMN], marks(variant_rows)),
    ] of CrystalClick::WidePartColumn
  end

  def write_part(destination : String) : String
    CrystalClick::WidePartWriter.write_uint64_columns(
      destination,
      KEY_NAME,
      KEYS.to_unsafe.to_slice(KEYS.size),
      columns,
      rows_per_mark: ROWS_PER_MARK,
      profile: CrystalClick::BinaryBulkProfile.with_size_stream,
      shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
      mode: CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE,
      frame_bytes: 32,
    )
  end

  private def variant(
    type : CrystalClick::BinaryDataType,
    child : CrystalClick::BinaryValue,
  ) : CrystalClick::BinaryValue
    type.child_count.times do |index|
      return CrystalClick::BinaryValue.variant(type, index, child) if type.child_at(index) == child.type
    end
    raise ArgumentError.new("W258 Variant child is absent from its canonical arm roster")
  end
end
