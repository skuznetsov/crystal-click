require "../../src/crystal_click"

module CompactPartWriterW266Fixture
  extend self

  KEY_NAME      = "pk"
  ROW_COUNT     =  8
  ROWS_PER_MARK =  2
  FRAME_BYTES   = 32
  KEYS          = [101_u64, 102_u64, 103_u64, 104_u64, 105_u64, 106_u64, 107_u64, 108_u64]
  COLUMN_NAMES  = ["root", "maybe", "items"]

  ROOT_SIGNATURES = [
    "S:726564", "S:626c7565", "S:6379616e", "S:676f6c64",
    "S:726564", "S:626c7565", "S:ff8041", "S:",
  ]
  MAYBE_SIGNATURES = [
    "S:726564", "N", "N", "S:",
    "S:626c7565", "S:726564", "S:", "S:ff8041",
  ]
  ITEMS_SIGNATURES = [
    "[S:726564]", "[N,S:]", "[]", "[]",
    "[S:ff8041]", "[S:726564,N]", "[S:677265656e]", "[S:,S:00,N]",
  ]

  def types : Hash(String, CrystalClick::BinaryDataType)
    string_type = CrystalClick::BinaryDataType.primitive("String")
    nullable_string_type = CrystalClick::BinaryDataType.nullable(string_type)
    low_string_type = CrystalClick::BinaryDataType.low_cardinality(string_type)
    low_nullable_string_type = CrystalClick::BinaryDataType.low_cardinality(nullable_string_type)
    {
      "root"  => low_string_type,
      "maybe" => low_nullable_string_type,
      "items" => CrystalClick::BinaryDataType.array(low_nullable_string_type),
    } of String => CrystalClick::BinaryDataType
  end

  def values_for(name : String) : Array(CrystalClick::BinaryValue)
    schema = types
    type = schema[name]?
    raise ArgumentError.new("unknown W266 column: #{name}") unless type

    case name
    when "root"
      root_strings.map do |value|
        CrystalClick::BinaryValue.low_cardinality(type, CrystalClick::BinaryValue.string(value))
      end
    when "maybe"
      nullable_strings.map { |value| low_nullable_string(type, value) }
    when "items"
      nested_string_rows.map do |row|
        children = [] of CrystalClick::BinaryValue
        row.each { |value| children << low_nullable_string(type.child_at(0), value) }
        CrystalClick::BinaryValue.array(type, children)
      end
    else
      raise ArgumentError.new("unknown W266 column: #{name}")
    end
  end

  def granules_for(name : String) : Array(Array(CrystalClick::BinaryValue))
    values_for(name).each_slice(ROWS_PER_MARK).map(&.to_a).to_a
  end

  def columns : Array(CrystalClick::CompactPartColumn)
    schema = types
    COLUMN_NAMES.map do |name|
      CrystalClick::CompactPartColumn.binary_bulk(name, schema[name], granules_for(name))
    end
  end

  def keys : Slice(UInt64)
    Slice(UInt64).new(KEYS.size) { |index| KEYS[index] }
  end

  def signatures(name : String) : Array(String)
    expected_signatures(name)
  end

  def expected_signatures(name : String) : Array(String)
    case name
    when "root"  then ROOT_SIGNATURES
    when "maybe" then MAYBE_SIGNATURES
    when "items" then ITEMS_SIGNATURES
    else              raise ArgumentError.new("unknown W266 column: #{name}")
    end
  end

  def read_signatures(name : String, values : Array(Array(CrystalClick::BinaryValue))) : Array(String)
    values.flatten.map { |value| row_signature(name, value) }
  end

  def row_signature(name : String, value : CrystalClick::BinaryValue) : String
    case name
    when "root"
      "S:#{value.child_at(0).as_string.to_slice.hexstring}"
    when "maybe"
      nullable_signature(value.child_at(0))
    when "items"
      "[#{value.elements.map { |item| nullable_signature(item.child_at(0)) }.join(",")}]"
    else
      raise ArgumentError.new("unknown W266 column: #{name}")
    end
  end

  def root_strings : Array(String)
    [
      "red", "blue", "cyan", "gold", "red", "blue",
      String.new(Bytes[0xff_u8, 0x80_u8, 0x41_u8]), "",
    ]
  end

  private def nullable_signature(value : CrystalClick::BinaryValue) : String
    return "N" if value.is_null?
    "S:#{value.child_at(0).as_string.to_slice.hexstring}"
  end

  private def nullable_strings : Array(String?)
    ["red", nil, nil, "", "blue", "red", "", String.new(Bytes[0xff_u8, 0x80_u8, 0x41_u8])] of String?
  end

  private def nested_string_rows : Array(Array(String?))
    [
      ["red"] of String?,
      [nil, ""] of String?,
      [] of String?,
      [] of String?,
      [String.new(Bytes[0xff_u8, 0x80_u8, 0x41_u8])] of String?,
      ["red", nil] of String?,
      ["green"] of String?,
      ["", String.new(Bytes[0x00_u8]), nil] of String?,
    ]
  end

  private def low_nullable_string(
    low_type : CrystalClick::BinaryDataType,
    value : String?,
  ) : CrystalClick::BinaryValue
    nullable_type = low_type.child_at(0)
    nullable = if string = value
                 CrystalClick::BinaryValue.nullable(nullable_type, CrystalClick::BinaryValue.string(string))
               else
                 CrystalClick::BinaryValue.nullable(nullable_type)
               end
    CrystalClick::BinaryValue.low_cardinality(low_type, nullable)
  end
end
