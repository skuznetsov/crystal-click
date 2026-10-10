module ProjectionPublicationW256Fixture
  extend self

  alias BinaryBulkProfile = CrystalClick::BinaryBulkProfile
  alias BinaryDataType = CrystalClick::BinaryDataType
  alias BinaryValue = CrystalClick::BinaryValue
  alias WidePartColumn = CrystalClick::WidePartColumn
  alias WidePartProjection = CrystalClick::WidePartProjection

  KEY_NAME          = "id"
  SCORE_NAME        = "score"
  LABEL_NAME        = "label"
  ITEMS_NAME        = "items"
  PROJECTION_NAME   = "by_score"
  BUCKET_PROJECTION = "by_bucket"

  IDS    = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
  SCORES = [50_u64, 10_u64, 40_u64, 20_u64, 60_u64, 30_u64]
  LABELS = ["a\0b", "", "café", "z\0", "é", "hi"]
  ITEMS  = [
    [1_u16, 2_u16],
    [] of UInt16,
    [3_u16],
    [2_u16, 4_u16],
    [] of UInt16,
    [6_u16, 7_u16],
  ]

  BY_SCORE_KEYS   = [10_u64, 20_u64, 30_u64, 40_u64, 50_u64, 60_u64]
  BY_SCORE_IDS    = [2_u64, 4_u64, 6_u64, 3_u64, 1_u64, 5_u64]
  BY_SCORE_LABELS = ["", "z\0", "hi", "café", "a\0b", "é"]
  BY_SCORE_ITEMS  = [
    [] of UInt16,
    [2_u16, 4_u16],
    [6_u16, 7_u16],
    [3_u16],
    [1_u16, 2_u16],
    [] of UInt16,
  ]

  BUCKET_KEYS    = [0_u64, 1_u64, 2_u64]
  BUCKET_MEMBERS = [[3_u16, 6_u16], [1_u16, 4_u16], [2_u16, 5_u16]]

  PARENT_MARK_ROWS = [2_u64, 2_u64, 2_u64]
  SCORE_MARK_ROWS  = [3_u64, 3_u64]
  BUCKET_MARK_ROWS = [2_u64, 1_u64]

  def profile(name : String) : BinaryBulkProfile
    case name
    when "single"
      BinaryBulkProfile.single_stream
    when "sized"
      BinaryBulkProfile.with_size_stream
    else
      raise ArgumentError.new("unknown W256 profile")
    end
  end

  def uint16_type : BinaryDataType
    BinaryDataType.primitive("UInt16")
  end

  def uint64_type : BinaryDataType
    BinaryDataType.primitive("UInt64")
  end

  def string_type : BinaryDataType
    BinaryDataType.primitive("String")
  end

  def items_type : BinaryDataType
    BinaryDataType.array(uint16_type)
  end

  def uint16_value(value : UInt16) : BinaryValue
    BinaryValue.fixed(
      uint16_type,
      Bytes[(value & 0xff_u16).to_u8, (value >> 8).to_u8],
    )
  end

  def items_value(values : Array(UInt16)) : BinaryValue
    BinaryValue.array(items_type, values.map { |value| uint16_value(value) })
  end

  def grouped(values : Array(BinaryValue), rows_per_mark : Int32) : Array(Array(BinaryValue))
    result = [] of Array(BinaryValue)
    values.each_slice(rows_per_mark) { |mark| result << mark.to_a }
    result
  end

  def binary_column(
    name : String,
    type : BinaryDataType,
    values : Array(BinaryValue),
    rows_per_mark : Int32,
  ) : WidePartColumn
    WidePartColumn.binary_bulk(name, type, grouped(values, rows_per_mark))
  end

  def parent_columns(rows_per_mark : Int32 = 2) : Array(WidePartColumn)
    [
      binary_column(SCORE_NAME, uint64_type, SCORES.map { |value| BinaryValue.uint64(value) }, rows_per_mark),
      binary_column(LABEL_NAME, string_type, LABELS.map { |value| BinaryValue.string(value) }, rows_per_mark),
      binary_column(ITEMS_NAME, items_type, ITEMS.map { |value| items_value(value) }, rows_per_mark),
    ] of WidePartColumn
  end

  def write_parent(
    destination : String,
    profile_name : String = "single",
    projections : Array(WidePartProjection) = [] of WidePartProjection,
    transport_limits : CrystalClick::CompressedStreamLimits = CrystalClick::CompressedStreamLimits.new,
  ) : String
    keys = IDS.dup
    CrystalClick::WidePartWriter.write_uint64_columns(
      destination,
      KEY_NAME,
      keys.to_unsafe.to_slice(keys.size),
      parent_columns,
      rows_per_mark: 2,
      profile: profile(profile_name),
      transport_limits: transport_limits,
      projections: projections,
    )
  end

  def by_score_columns(rows_per_mark : Int32 = 3) : Array(WidePartColumn)
    [
      binary_column("id", uint64_type, BY_SCORE_IDS.map { |value| BinaryValue.uint64(value) }, rows_per_mark),
      binary_column("label", string_type, BY_SCORE_LABELS.map { |value| BinaryValue.string(value) }, rows_per_mark),
      binary_column("items", items_type, BY_SCORE_ITEMS.map { |value| items_value(value) }, rows_per_mark),
    ] of WidePartColumn
  end

  def by_score_projection(rows_per_mark : Int32 = 3) : WidePartProjection
    keys = BY_SCORE_KEYS.dup
    WidePartProjection.precomputed(
      PROJECTION_NAME,
      SCORE_NAME,
      keys.to_unsafe.to_slice(keys.size),
      by_score_columns(rows_per_mark),
      rows_per_mark: rows_per_mark,
    )
  end

  def by_bucket_projection(rows_per_mark : Int32 = 2) : WidePartProjection
    keys = BUCKET_KEYS.dup
    values = BUCKET_MEMBERS.map { |members| items_value(members) }
    columns = [binary_column("members", items_type, values, rows_per_mark)] of WidePartColumn
    WidePartProjection.precomputed(
      BUCKET_PROJECTION,
      "bucket",
      keys.to_unsafe.to_slice(keys.size),
      columns,
      rows_per_mark: rows_per_mark,
    )
  end

  # Three child rows are deliberately grouped independently of the parent's
  # two-row marks. The values are literal caller-owned materialization; no
  # projection expression is evaluated here.
  def by_score_rows : NamedTuple(keys: Array(UInt64), ids: Array(BinaryValue), labels: Array(BinaryValue), items: Array(BinaryValue))
    {
      keys:   BY_SCORE_KEYS.dup,
      ids:    BY_SCORE_IDS.map { |value| BinaryValue.uint64(value) },
      labels: BY_SCORE_LABELS.map { |value| BinaryValue.string(value) },
      items:  BY_SCORE_ITEMS.map { |value| items_value(value) },
    }
  end

  def parent_rows : NamedTuple(ids: Array(UInt64), scores: Array(BinaryValue), labels: Array(BinaryValue), items: Array(BinaryValue))
    {
      ids:    IDS.dup,
      scores: SCORES.map { |value| BinaryValue.uint64(value) },
      labels: LABELS.map { |value| BinaryValue.string(value) },
      items:  ITEMS.map { |value| items_value(value) },
    }
  end

  def signature(value : BinaryValue) : String
    case value.type.tag
    when BinaryDataType::TAG_STRING
      "String:#{value.bytes.hexstring}"
    when BinaryDataType::TAG_UINT64
      "UInt64:#{value.as_uint64}"
    when BinaryDataType::TAG_ARRAY
      children = (0...value.element_count).map { |index| signature(value.element_at(index)) }
      "#{value.type.name}[#{children.join(",")}]"
    else
      "#{value.type.name}:#{value.bytes.hexstring}"
    end
  end
end
