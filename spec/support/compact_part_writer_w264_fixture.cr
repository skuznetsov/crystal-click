require "../../src/crystal_click"

module CompactPartWriterW264Fixture
  extend self

  FORMAT        = "compact_part_writer_w264_fixture_v1"
  KEY_NAME      = "pk"
  ROW_COUNT     =  8
  ROWS_PER_MARK =  2
  FRAME_BYTES   = 32
  KEYS          = [101_u64, 102_u64, 103_u64, 104_u64, 105_u64, 106_u64, 107_u64, 108_u64]
  COLUMN_NAMES  = ["u", "text", "maybe", "gap", "arr", "pair", "lookup"]

  def types : Hash(String, CrystalClick::BinaryDataType)
    u64 = CrystalClick::BinaryDataType.primitive("UInt64")
    string = CrystalClick::BinaryDataType.primitive("String")
    nullable_u64 = CrystalClick::BinaryDataType.nullable(u64)
    {
      "u"     => u64,
      "text"  => string,
      "maybe" => nullable_u64,
      "gap"   => CrystalClick::BinaryDataType.array(nullable_u64),
      "arr"   => CrystalClick::BinaryDataType.array(nullable_u64),
      "pair"  => CrystalClick::BinaryDataType.tuple(
        [string, nullable_u64] of CrystalClick::BinaryDataType,
      ),
      "lookup" => CrystalClick::BinaryDataType.map(string, u64),
    } of String => CrystalClick::BinaryDataType
  end

  def values_for(name : String) : Array(CrystalClick::BinaryValue)
    type = types[name]?
    raise ArgumentError.new("unknown W264 column: #{name}") unless type

    case name
    when "u"
      [
        0_u64,
        1_u64,
        UInt64::MAX,
        42_u64,
        9_007_199_254_740_993_u64,
        7_u64,
        123_456_789_u64,
        108_u64,
      ].map { |value| CrystalClick::BinaryValue.uint64(value) }
    when "text"
      binary = String.new(Bytes[0_u8, 255_u8, 128_u8, 65_u8])
      [
        "",
        "alpha",
        "utf8-λ",
        "contains\0nul",
        binary,
        "crystal-" * 1024,
        "tail",
        "last",
      ].map { |value| CrystalClick::BinaryValue.string(value) }
    when "maybe"
      [nil, 0_u64, 1_u64, nil, 50_u64, 42_u64, nil, 7_u64].map do |value|
        nullable_u64(type, value)
      end
    when "arr"
      element_type = type.child_at(0)
      [
        [] of UInt64?,
        [nil] of UInt64?,
        [0_u64, nil, 5_u64] of UInt64?,
        [] of UInt64?,
        [50_u64] of UInt64?,
        [nil, 0_u64] of UInt64?,
        [42_u64, 42_u64, 42_u64] of UInt64?,
        [1_u64] of UInt64?,
      ].map do |items|
        children = items.map { |value| nullable_u64(element_type, value) }
        CrystalClick::BinaryValue.array(type, children)
      end
    when "gap"
      element_type = type.child_at(0)
      [
        [] of UInt64?,
        [] of UInt64?,
        [0_u64, 7_u64] of UInt64?,
        [] of UInt64?,
        [nil, 9_u64] of UInt64?,
        [] of UInt64?,
        [42_u64] of UInt64?,
        [] of UInt64?,
      ].map do |items|
        children = items.map { |value| nullable_u64(element_type, value) }
        CrystalClick::BinaryValue.array(type, children)
      end
    when "pair"
      tuple_rows = [
        {"a", 0_u64},
        {"b", nil},
        {"c", 3_u64},
        {"", nil},
        {"tuple-tail", 9_u64},
        {"λ", 1_u64},
        {"NUL\0key", 42_u64},
        {"last", 0_u64},
      ] of Tuple(String, UInt64?)
      tuple_rows.map do |label, value|
        CrystalClick::BinaryValue.tuple(
          type,
          [
            CrystalClick::BinaryValue.string(label),
            nullable_u64(type.child_at(1), value),
          ] of CrystalClick::BinaryValue,
        )
      end
    when "lookup"
      [
        [] of Tuple(String, UInt64),
        [{"alpha", 1_u64}] of Tuple(String, UInt64),
        [] of Tuple(String, UInt64),
        [{"zero", 0_u64}, {"max", 99_u64}] of Tuple(String, UInt64),
        [{"one", 7_u64}] of Tuple(String, UInt64),
        [] of Tuple(String, UInt64),
        [{"left", 4_u64}, {"right", 9_u64}] of Tuple(String, UInt64),
        [{"last", 108_u64}] of Tuple(String, UInt64),
      ].map do |entries|
        flat_values = [] of CrystalClick::BinaryValue
        entries.each do |key, value|
          flat_values << CrystalClick::BinaryValue.string(key)
          flat_values << CrystalClick::BinaryValue.uint64(value)
        end
        CrystalClick::BinaryValue.map(type, flat_values)
      end
    else
      raise ArgumentError.new("unknown W264 column: #{name}")
    end
  end

  def keys : Slice(UInt64)
    Slice(UInt64).new(KEYS.size) { |index| KEYS[index] }
  end

  def granules_for(name : String, rows_per_mark : Int32 = ROWS_PER_MARK) : Array(Array(CrystalClick::BinaryValue))
    raise ArgumentError.new("rows_per_mark must be positive") unless rows_per_mark > 0
    result = [] of Array(CrystalClick::BinaryValue)
    values_for(name).each_slice(rows_per_mark) { |slice| result << slice.to_a }
    result
  end

  def columns : Array(CrystalClick::CompactPartColumn)
    schema = types
    COLUMN_NAMES.map do |name|
      CrystalClick::CompactPartColumn.binary_bulk(name, schema[name], granules_for(name))
    end
  end

  # A stable, exact carrier signature used for local reader/write round trips.
  # The independent Ruby/native literal oracle is maintained separately in
  # probe_compact_part_writer_w264.rb.
  def row_signature(value : CrystalClick::BinaryValue) : String
    type = value.type.name
    bytes = if value.is_null? || value.child_count > 0 || value.byte_size == 0
              ""
            else
              value.bytes.hexstring
            end
    children = value.elements.map { |child| row_signature(child) }
    String.build do |io|
      io << type.bytesize << ':' << type << ':'
      io << (value.is_null? ? 'N' : 'V') << ':'
      io << bytes.bytesize << ':' << bytes << ':'
      io << children.size << '['
      children.each do |child|
        io << child.bytesize << ':' << child << ';'
      end
      io << ']'
    end
  end

  def signatures_for(name : String) : Array(String)
    values_for(name).map { |value| row_signature(value) }
  end

  # Normalize each public batch through the carrier that already owns that
  # declaration. Legacy typed carriers deliberately do not imply admission to
  # the generic BinaryBulk getter.
  def batch_signatures(batch : CrystalClick::WidePartTableBatch, name : String) : Array(String)
    type = types[name]
    values = case name
             when "u"
               batch.values_for(name).map { |value| CrystalClick::BinaryValue.uint64(value) }
             when "text"
               batch.strings_for(name).map { |value| CrystalClick::BinaryValue.string(value) }
             when "maybe"
               batch.nullable_values_for(name, UInt64).map { |value| nullable_u64(type, value) }
             when "gap", "arr"
               element_type = type.child_at(0)
               batch.array_nullable_uint64s_for(name).map do |items|
                 children = items.map { |value| nullable_u64(element_type, value) }
                 CrystalClick::BinaryValue.array(type, children)
               end
             when "pair"
               # This positional Tuple is generic-static, unlike the existing
               # named Tuple carrier, which has a legacy-only typed view.
               batch.binary_bulk_values_for(name).to_a
             when "lookup"
               batch.map_string_uint64s_for(name).map do |entries|
                 flat_values = [] of CrystalClick::BinaryValue
                 entries.each do |key, value|
                   flat_values << CrystalClick::BinaryValue.string(key)
                   flat_values << CrystalClick::BinaryValue.uint64(value)
                 end
                 CrystalClick::BinaryValue.map(type, flat_values)
               end
             else
               raise ArgumentError.new("unknown W264 column: #{name}")
             end
    values.map { |value| row_signature(value) }.to_a
  end

  private def nullable_u64(type : CrystalClick::BinaryDataType, value : UInt64?) : CrystalClick::BinaryValue
    if scalar = value
      CrystalClick::BinaryValue.nullable(type, CrystalClick::BinaryValue.uint64(scalar))
    else
      CrystalClick::BinaryValue.nullable(type)
    end
  end
end

module CompactPartWriterW264GuardFixture
  extend self

  def keys(values : Array(UInt64)) : Slice(UInt64)
    Slice(UInt64).new(values.size) { |index| values[index] }
  end

  def uint64_column(name : String, values : Array(UInt64), rows_per_mark : Int32 = 2) : CrystalClick::CompactPartColumn
    type = CrystalClick::BinaryDataType.primitive("UInt64")
    granules = [] of Array(CrystalClick::BinaryValue)
    values.each_slice(rows_per_mark) do |slice|
      granules << slice.map { |value| CrystalClick::BinaryValue.uint64(value) }
    end
    CrystalClick::CompactPartColumn.binary_bulk(name, type, granules)
  end

  def write(
    destination : String,
    key_name : String,
    key_values : Array(UInt64),
    columns : Array(CrystalClick::CompactPartColumn),
    rows_per_mark : Int32 = 2,
    frame_bytes : Int = 32,
    limits : CrystalClick::BinaryCodecLimits = CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
    transport_limits : CrystalClick::CompressedStreamLimits = CrystalClick::CompressedStreamLimits.new,
    reader_limits : CrystalClick::CompressedStreamLimits = CrystalClick::CompressedStreamLimits.new,
  ) : String
    CrystalClick::CompactPartWriter.write_uint64_columns(
      destination,
      key_name,
      keys(key_values),
      columns,
      rows_per_mark: rows_per_mark,
      frame_bytes: frame_bytes,
      limits: limits,
      transport_limits: transport_limits,
      reader_limits: reader_limits,
    )
  end
end
