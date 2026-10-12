require "../../src/crystal_click"

module CompactPartWriterW268Fixture
  extend self

  KEY_NAME      = "pk"
  ROOT_COLUMN   = "root"
  CTX_COLUMN    = "ctx"
  ROOT_SITE     = "root"
  NESTED_SITE   = "root.field.1.elements"
  ROWS_PER_MARK =    2
  ROW_COUNT     =   12
  MARK_COUNT    =    6
  FRAME_BYTES   = 4096
  KEYS          = (1_u64..12_u64).to_a

  ROOT_SIGNATURES = [
    "UInt8:11",
    "UInt8:12",
    "String:r3",
    "UInt64:9001",
    "UInt8:13",
    "String:r6",
    "NULL",
    "NULL",
    "String:r9",
    "UInt64:9002",
    "UInt8:14",
    "UInt8:15",
  ] of String

  CTX_SIGNATURES = [
    "r01[UInt16:101]",
    "r02[UInt16:102]",
    "r03[UInt16:103,String:n4]",
    "r04[UInt64:19001]",
    "r05[String:n5]",
    "r06[UInt16:104,UInt16:105]",
    "r07[]",
    "r08[]",
    "r09[UInt64:19002]",
    "r10[String:n10,UInt16:106]",
    "r11[UInt16:107,String:tail]",
    "r12[NULL]",
  ] of String

  def uint8_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt8")
  end

  def uint16_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt16")
  end

  def uint64_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt64")
  end

  def string_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("String")
  end

  def root_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.dynamic(max_types: 1)
  end

  def nested_dynamic_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.dynamic(max_types: 1)
  end

  def items_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.array(nested_dynamic_type)
  end

  def ctx_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.tuple(
      [string_type, items_type] of CrystalClick::BinaryDataType,
      ["label", "items"] of String,
    )
  end

  def root_rows : Array(CrystalClick::BinaryValue)
    dynamic = root_type
    uint8 = uint8_type

    [
      dynamic_value(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[11_u8])),
      dynamic_value(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[12_u8])),
      dynamic_value(dynamic, CrystalClick::BinaryValue.string("r3")),
      dynamic_value(dynamic, CrystalClick::BinaryValue.uint64(9001_u64)),
      dynamic_value(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[13_u8])),
      dynamic_value(dynamic, CrystalClick::BinaryValue.string("r6")),
      dynamic_value(dynamic, nil),
      dynamic_value(dynamic, nil),
      dynamic_value(dynamic, CrystalClick::BinaryValue.string("r9")),
      dynamic_value(dynamic, CrystalClick::BinaryValue.uint64(9002_u64)),
      dynamic_value(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[14_u8])),
      dynamic_value(dynamic, CrystalClick::BinaryValue.fixed(uint8, Bytes[15_u8])),
    ] of CrystalClick::BinaryValue
  end

  def ctx_rows : Array(CrystalClick::BinaryValue)
    tuple = ctx_type
    items = items_type
    dynamic = nested_dynamic_type
    uint16 = uint16_type

    nested = [
      [dynamic_value(dynamic, uint16_value(uint16, 101_u16))] of CrystalClick::BinaryValue,
      [dynamic_value(dynamic, uint16_value(uint16, 102_u16))] of CrystalClick::BinaryValue,
      [
        dynamic_value(dynamic, uint16_value(uint16, 103_u16)),
        dynamic_value(dynamic, CrystalClick::BinaryValue.string("n4")),
      ] of CrystalClick::BinaryValue,
      [dynamic_value(dynamic, CrystalClick::BinaryValue.uint64(19001_u64))] of CrystalClick::BinaryValue,
      [dynamic_value(dynamic, CrystalClick::BinaryValue.string("n5"))] of CrystalClick::BinaryValue,
      [
        dynamic_value(dynamic, uint16_value(uint16, 104_u16)),
        dynamic_value(dynamic, uint16_value(uint16, 105_u16)),
      ] of CrystalClick::BinaryValue,
      [] of CrystalClick::BinaryValue,
      [] of CrystalClick::BinaryValue,
      [dynamic_value(dynamic, CrystalClick::BinaryValue.uint64(19002_u64))] of CrystalClick::BinaryValue,
      [
        dynamic_value(dynamic, CrystalClick::BinaryValue.string("n10")),
        dynamic_value(dynamic, uint16_value(uint16, 106_u16)),
      ] of CrystalClick::BinaryValue,
      [
        dynamic_value(dynamic, uint16_value(uint16, 107_u16)),
        dynamic_value(dynamic, CrystalClick::BinaryValue.string("tail")),
      ] of CrystalClick::BinaryValue,
      [dynamic_value(dynamic, nil)] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)

    rows = Array(CrystalClick::BinaryValue).new(ROW_COUNT)
    nested.each_with_index do |values, index|
      label = "r#{(index + 1).to_s.rjust(2, '0')}"
      rows << CrystalClick::BinaryValue.tuple(
        tuple,
        [
          CrystalClick::BinaryValue.string(label),
          CrystalClick::BinaryValue.array(items, values),
        ] of CrystalClick::BinaryValue,
      )
    end
    rows
  end

  def root_granules : Array(Array(CrystalClick::BinaryValue))
    split_marks(root_rows)
  end

  def ctx_granules : Array(Array(CrystalClick::BinaryValue))
    split_marks(ctx_rows)
  end

  def structure(
    ordinary_type : CrystalClick::BinaryDataType,
    version : UInt64 = CrystalClick::DynamicStructure::VERSION_V3,
    sample_ordinary_count : UInt64 = 2_u64,
  ) : CrystalClick::DynamicStructure
    statistics = CrystalClick::StructureStatistics.new(
      [0_u64, sample_ordinary_count] of UInt64,
      [] of CrystalClick::StructureStatistic,
    )
    CrystalClick::DynamicStructure.new([ordinary_type] of CrystalClick::BinaryDataType, statistics, version: version)
  end

  def root_context(
    version : UInt64 = CrystalClick::DynamicStructure::VERSION_V3,
    sample_ordinary_count : UInt64 = 2_u64,
  ) : CrystalClick::CompactDynamicWriteContext
    sites = {
      ROOT_SITE => structure(uint8_type, version, sample_ordinary_count),
    } of String => CrystalClick::DynamicStructure
    CrystalClick::CompactDynamicWriteContext.new(sites)
  end

  def ctx_context(
    version : UInt64 = CrystalClick::DynamicStructure::VERSION_V3,
    sample_ordinary_count : UInt64 = 2_u64,
  ) : CrystalClick::CompactDynamicWriteContext
    sites = {
      NESTED_SITE => structure(uint16_type, version, sample_ordinary_count),
    } of String => CrystalClick::DynamicStructure
    CrystalClick::CompactDynamicWriteContext.new(sites)
  end

  def columns(
    root_version : UInt64 = CrystalClick::DynamicStructure::VERSION_V3,
    nested_version : UInt64 = CrystalClick::DynamicStructure::VERSION_V3,
    root_sample_count : UInt64 = 2_u64,
    nested_sample_count : UInt64 = 2_u64,
  ) : Array(CrystalClick::CompactPartColumn)
    [
      CrystalClick::CompactPartColumn.dynamic_bulk(
        ROOT_COLUMN,
        root_type,
        root_granules,
        root_context(root_version, root_sample_count),
      ),
      CrystalClick::CompactPartColumn.dynamic_bulk(
        CTX_COLUMN,
        ctx_type,
        ctx_granules,
        ctx_context(nested_version, nested_sample_count),
      ),
    ] of CrystalClick::CompactPartColumn
  end

  def keys : Slice(UInt64)
    Slice(UInt64).new(KEYS.size) { |index| KEYS[index] }
  end

  def signature(column_name : String, rows : Array(CrystalClick::BinaryValue)) : Array(String)
    case column_name
    when ROOT_COLUMN
      rows.map { |value| dynamic_signature(value) }
    when CTX_COLUMN
      rows.map { |value| context_signature(value) }
    else
      raise ArgumentError.new("unknown W268 fixture column")
    end
  end

  def dynamic_signature(value : CrystalClick::BinaryValue) : String
    return "NULL" if value.is_null?

    scalar_signature(value.child_at(0))
  end

  def context_signature(value : CrystalClick::BinaryValue) : String
    label = String.new(value.child_at(0).bytes)
    nested = value.child_at(1)
    entries = nested.elements.map { |dynamic| dynamic_signature(dynamic) }
    "#{label}[#{entries.join(',')}]"
  end

  private def dynamic_value(
    type : CrystalClick::BinaryDataType,
    child : CrystalClick::BinaryValue?,
  ) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.dynamic(type, child)
  end

  private def uint16_value(type : CrystalClick::BinaryDataType, value : UInt16) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.fixed(
      type,
      Bytes[(value & 0x00ff_u16).to_u8, (value >> 8).to_u8],
    )
  end

  private def scalar_signature(value : CrystalClick::BinaryValue) : String
    case value.type.tag
    when CrystalClick::BinaryDataType::TAG_STRING
      "String:#{String.new(value.bytes)}"
    when CrystalClick::BinaryDataType::TAG_UINT8
      "UInt8:#{value.byte_at(0)}"
    when CrystalClick::BinaryDataType::TAG_UINT16
      decoded = value.byte_at(0).to_u16 | (value.byte_at(1).to_u16 << 8)
      "UInt16:#{decoded}"
    when CrystalClick::BinaryDataType::TAG_UINT64
      decoded = 0_u64
      8.times do |index|
        decoded |= value.byte_at(index).to_u64 << (index * 8)
      end
      "UInt64:#{decoded}"
    else
      raise ArgumentError.new("unexpected W268 fixture scalar")
    end
  end

  private def split_marks(rows : Array(CrystalClick::BinaryValue)) : Array(Array(CrystalClick::BinaryValue))
    rows.each_slice(ROWS_PER_MARK).map(&.to_a).to_a
  end
end
