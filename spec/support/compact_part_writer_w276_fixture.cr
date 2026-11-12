require "../../src/crystal_click"
require "./compact_part_writer_w264_fixture"

module CompactPartWriterW276Fixture
  extend self

  FORMAT        = "compact_part_writer_w276_fixture_v1"
  KEY_NAME      = CompactPartWriterW264Fixture::KEY_NAME
  ROW_COUNT     = CompactPartWriterW264Fixture::ROW_COUNT
  ROWS_PER_MARK = CompactPartWriterW264Fixture::ROWS_PER_MARK
  FRAME_BYTES   = CompactPartWriterW264Fixture::FRAME_BYTES
  COLUMN_NAMES  = [
    "u", "text", "maybe", "gap", "arr", "pair", "lookup",
    "string_array", "lc_text", "variant_text",
  ]

  def types : Hash(String, CrystalClick::BinaryDataType)
    schema = CompactPartWriterW264Fixture.types
    string_type = CrystalClick::BinaryDataType.primitive("String")
    uint64_type = CrystalClick::BinaryDataType.primitive("UInt64")
    nullable_string_type = CrystalClick::BinaryDataType.nullable(string_type)
    array_nullable_string_type = CrystalClick::BinaryDataType.array(nullable_string_type)
    # The public Compact typed carrier does not admit a root
    # Array(Nullable(String)). Keep that root rejection intact and exercise the
    # same recursive child layout through an admitted generic-static Tuple.
    schema["string_array"] = CrystalClick::BinaryDataType.tuple(
      [array_nullable_string_type] of CrystalClick::BinaryDataType,
      ["items"] of String,
    )
    schema["lc_text"] = CrystalClick::BinaryDataType.low_cardinality(string_type)
    schema["variant_text"] = CrystalClick::BinaryDataType.variant(
      [string_type, uint64_type] of CrystalClick::BinaryDataType,
    )
    schema
  end

  def values_for(name : String) : Array(CrystalClick::BinaryValue)
    return CompactPartWriterW264Fixture.values_for(name) if CompactPartWriterW264Fixture::COLUMN_NAMES.includes?(name)

    schema = types
    type = schema[name]?
    raise ArgumentError.new("unknown W276 column: #{name}") unless type

    case name
    when "string_array"
      array_type = type.child_at(0)
      element_type = array_type.child_at(0)
      rows = [
        [] of String?,
        [""] of String?,
        [nil, "nullable\0tail"] of String?,
        [] of String?,
        [] of String?,
        [] of String?,
        ["long:" + ("x" * 256)] of String?,
        [raw_string(Bytes[0x00_u8, 0xff_u8, 0x80_u8, 0x41_u8])] of String?,
      ] of Array(String?)
      rows.map do |items|
        children = items.map { |value| nullable_string(element_type, value) }
        array_value = CrystalClick::BinaryValue.array(array_type, children)
        CrystalClick::BinaryValue.tuple(type, [array_value] of CrystalClick::BinaryValue)
      end
    when "lc_text"
      [
        "",
        "",
        raw_string(Bytes[0x00_u8, 0xff_u8, 0x80_u8, 0x41_u8]),
        "lc\0nul",
        "repeat",
        "repeat",
        "",
        "tail",
      ].map do |value|
        CrystalClick::BinaryValue.low_cardinality(type, CrystalClick::BinaryValue.string(value))
      end
    when "variant_text"
      [
        CrystalClick::BinaryValue.variant(type, 0, CrystalClick::BinaryValue.string("")),
        CrystalClick::BinaryValue.variant(type, 1, CrystalClick::BinaryValue.uint64(0_u64)),
        CrystalClick::BinaryValue.variant(
          type,
          0,
          CrystalClick::BinaryValue.string(raw_string(Bytes[0x00_u8, 0xff_u8, 0x80_u8, 0x41_u8])),
        ),
        CrystalClick::BinaryValue.variant_null(type),
        CrystalClick::BinaryValue.variant(type, 1, CrystalClick::BinaryValue.uint64(42_u64)),
        CrystalClick::BinaryValue.variant(
          type,
          0,
          CrystalClick::BinaryValue.string("long:" + ("x" * 256)),
        ),
        CrystalClick::BinaryValue.variant_null(type),
        CrystalClick::BinaryValue.variant(
          type,
          0,
          CrystalClick::BinaryValue.string("variant\0tail"),
        ),
      ] of CrystalClick::BinaryValue
    else
      raise ArgumentError.new("unknown W276 column: #{name}")
    end
  end

  def granules_for(name : String) : Array(Array(CrystalClick::BinaryValue))
    values_for(name).each_slice(ROWS_PER_MARK).map(&.to_a).to_a
  end

  def columns : Array(CrystalClick::CompactPartColumn)
    result = CompactPartWriterW264Fixture.columns
    schema = types
    ["string_array", "lc_text", "variant_text"].each do |name|
      result << CrystalClick::CompactPartColumn.binary_bulk(name, schema[name], granules_for(name))
    end
    result
  end

  def keys : Slice(UInt64)
    CompactPartWriterW264Fixture.keys
  end

  def expected_signatures(name : String) : Array(String)
    values_for(name).map { |value| CompactPartWriterW264Fixture.row_signature(value) }
  end

  def signatures_from(marks : Array(Array(CrystalClick::BinaryValue))) : Array(String)
    marks.flatten.map { |value| CompactPartWriterW264Fixture.row_signature(value) }
  end

  private def nullable_string(
    type : CrystalClick::BinaryDataType,
    value : String?,
  ) : CrystalClick::BinaryValue
    if scalar = value
      CrystalClick::BinaryValue.nullable(type, CrystalClick::BinaryValue.string(scalar))
    else
      CrystalClick::BinaryValue.nullable(type)
    end
  end

  private def raw_string(bytes : Bytes) : String
    String.new(bytes)
  end
end
