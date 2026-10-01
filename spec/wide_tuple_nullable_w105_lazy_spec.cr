require "./spec_helper"

private def w106_nullable_tree_and_path_charge(name : String) : UInt64
  node_bytes = instance_sizeof(CrystalClick::WideTupleSchemaNode).to_u64 +
               instance_sizeof(Array(CrystalClick::WideTupleSchemaNode)).to_u64
  string_bytes = instance_sizeof(String).to_u64 + name.bytesize.to_u64 + 1_u64
  node_bytes + sizeof(Pointer(CrystalClick::WideTupleSchemaNode)).to_u64 +
    node_bytes + string_bytes +
    instance_sizeof(Array(String)).to_u64 + sizeof(Pointer(String)).to_u64 + string_bytes
end

class CrystalClick::WidePart
  # A spec-only TupleReader factory with observable stream and decoder
  # callbacks. It lets the tests corrupt a mask without also corrupting its
  # compressed frame checksum.
  def self.w105_nullable_lazy_test_reader(
    plan : WideTupleTypePlan,
    mark_rows : Hash(String, Array(UInt64)),
    payloads : Hash(String, Array(Bytes)),
    read_calls : Array(String),
    validate_calls : Array(String),
    decode_calls : Array(String),
  ) : TupleReader
    TupleReader.new(
      plan,
      "payload",
      ->(stream_name : String, first_mark : Int32, mark_count : Int32) {
        counts = mark_rows[stream_name]
        rows = 0_u64
        mark_count.times { |offset| rows += counts[first_mark + offset] }
        rows
      },
      ->(stream_name : String, mark_index : Int32) {
        mark_rows[stream_name][mark_index]
      },
      ->(stream_name : String, first_mark : Int32, mark_count : Int32, expected_bytes : Int32, _width : Int32, _expected_rows : UInt64) {
        read_calls << stream_name
        source_marks = payloads[stream_name]
        output = Bytes.new(expected_bytes)
        cursor = 0
        mark_count.times do |offset|
          source_marks[first_mark + offset].each do |byte|
            raise CorruptPartError.new("test payload exceeds requested bytes") if cursor >= output.size
            output[cursor] = byte
            cursor += 1
          end
        end
        raise CorruptPartError.new("test payload length differs from request") unless cursor == expected_bytes
        output
      },
      ->(stream_name : String, _first_mark : Int32, _mark_count : Int32, _expected_bytes : Int32, _width : Int32, _expected_rows : UInt64) {
        validate_calls << stream_name
        nil
      },
      ->(bytes : Bytes, offset : Int32) {
        value = 0_u64
        8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
        value
      },
      ->(_name : String, _type_name : String, _bytes : Bytes, _rows : UInt64, _width : Int32) {
        raise "unexpected numeric Tuple decoder"
      },
      ->(_name : String, _bytes : Bytes, _rows : UInt64, _width : Int32) {
        raise "unexpected Bool Tuple decoder"
      },
      ->(_name : String, _type_name : String, _bytes : Bytes, _rows : UInt64, _width : Int32) {
        raise "unexpected identifier Tuple decoder"
      },
      ->(_name : String, _type_name : String, _bytes : Bytes, _rows : UInt64, _width : Int32) {
        raise "unexpected temporal Tuple decoder"
      },
      ->(_name : String, _exact_type : DateTimeColumnType, _bytes : Bytes, _rows : UInt64, _width : Int32) {
        raise "unexpected DateTime Tuple decoder"
      },
      ->(_name : String, _exact_type : WideTupleParameterizedType, _bytes : Bytes, _rows : UInt64, _width : Int32) {
        raise "unexpected parameterized Tuple decoder"
      },
      ->(name : String, leaf_type : WideTupleLeafType, bytes : Bytes, null_map : ScalarNullMap, rows : UInt64, _width : Int32) {
        decode_calls << name
        raise "test nullable decoder expects UInt8" unless leaf_type.base_type_name == "UInt8"
        values = Array(UInt8).new(rows.to_i) { |index| bytes[index] }
        WideTupleLeafColumn.new(name, leaf_type, values, null_map)
      }
    )
  end
end

private def w105l_reader(
  type_name : String,
  mark_rows : Hash(String, Array(UInt64)),
  payloads : Hash(String, Array(Bytes)),
  read_calls : Array(String),
  validate_calls : Array(String),
  decode_calls : Array(String),
)
  plan = CrystalClick::WideTupleTypePlan.for_type(type_name).not_nil!
  CrystalClick::WidePart.w105_nullable_lazy_test_reader(
    plan, mark_rows, payloads, read_calls, validate_calls, decode_calls
  )
end

private def w105l_u64_bytes(value : UInt64) : Bytes
  Bytes.new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w105l_null_map(bytes : Array(UInt8)) : CrystalClick::ScalarNullMap
  CrystalClick::ScalarNullMap.new(bytes.to_unsafe.to_slice(bytes.size), bytes.size.to_u64)
end

describe "W105 nullable Tuple reader adversarial boundaries" do
  it "rejects a malformed first mask before any mark or payload decoder callback" do
    type_name = "Tuple(value Nullable(UInt8))"
    mask_stream = "payload%2Evalue.null"
    value_stream = "payload%2Evalue"
    mark_rows = {
      mask_stream  => [1_u64],
      value_stream => [1_u64],
    } of String => Array(UInt64)
    payloads = {
      mask_stream  => [Bytes[2_u8]],
      value_stream => [Bytes[7_u8]],
    } of String => Array(Bytes)
    read_calls = [] of String
    validate_calls = [] of String
    decode_calls = [] of String
    reader = w105l_reader(type_name, mark_rows, payloads, read_calls, validate_calls, decode_calls)
    yielded = [] of Int32

    expect_raises(CrystalClick::CorruptPartError, "Tuple Nullable null map is invalid") do
      reader.each(0, 1, CrystalClick::WideTupleTypePlan::MAX_MATERIALIZED_BYTES) do |_mark, mark_index|
        yielded << mark_index
        nil
      end
    end
    yielded.should be_empty
    decode_calls.should be_empty
    read_calls.should_not be_empty
  end

  it "allows earlier valid marks before a later malformed mask but never yields the bad mark" do
    type_name = "Tuple(value Nullable(UInt8))"
    mask_stream = "payload%2Evalue.null"
    value_stream = "payload%2Evalue"
    mark_rows = {
      mask_stream  => [1_u64, 1_u64],
      value_stream => [1_u64, 1_u64],
    } of String => Array(UInt64)
    payloads = {
      mask_stream  => [Bytes[0_u8], Bytes[2_u8]],
      value_stream => [Bytes[7_u8], Bytes[8_u8]],
    } of String => Array(Bytes)
    read_calls = [] of String
    validate_calls = [] of String
    decode_calls = [] of String
    reader = w105l_reader(type_name, mark_rows, payloads, read_calls, validate_calls, decode_calls)
    yielded = [] of Int32
    yielded_values = [] of UInt8

    expect_raises(CrystalClick::CorruptPartError, "Tuple Nullable null map is invalid") do
      reader.each(0, 2, CrystalClick::WideTupleTypePlan::MAX_MATERIALIZED_BYTES) do |mark, mark_index|
        yielded << mark_index
        yielded_values << mark.row(0).value_as("value", UInt8)
        nil
      end
    end
    yielded.should eq([0])
    yielded_values.should eq([7_u8])
    decode_calls.should eq(["value"])
  end

  it "rejects a selected mask mark-row-axis mismatch before reading or yielding any mark" do
    type_name = "Tuple(value Nullable(UInt8))"
    mask_stream = "payload%2Evalue.null"
    value_stream = "payload%2Evalue"
    # Both streams contain two rows overall, but row boundaries disagree at
    # the first selected mark. Range-total equality must not hide this.
    mark_rows = {
      mask_stream  => [0_u64, 2_u64],
      value_stream => [1_u64, 1_u64],
    } of String => Array(UInt64)
    payloads = {
      mask_stream  => [Bytes.empty, Bytes[0_u8, 0_u8]],
      value_stream => [Bytes[7_u8], Bytes[8_u8]],
    } of String => Array(Bytes)
    read_calls = [] of String
    validate_calls = [] of String
    decode_calls = [] of String
    reader = w105l_reader(type_name, mark_rows, payloads, read_calls, validate_calls, decode_calls)
    yielded = [] of Int32

    expect_raises(CrystalClick::CorruptPartError, "Tuple substream mark rows differ") do
      reader.each(0, 2, CrystalClick::WideTupleTypePlan::MAX_MATERIALIZED_BYTES) do |_mark, mark_index|
        yielded << mark_index
        nil
      end
    end
    yielded.should be_empty
    read_calls.should be_empty
    validate_calls.should be_empty
    decode_calls.should be_empty
  end

  it "charges hidden Nullable(String) bytes at the exact materialization boundary" do
    type_name = "Tuple(text Nullable(String))"
    mask_stream = "payload%2Etext.null"
    size_stream = "payload%2Etext.size"
    value_stream = "payload%2Etext"
    mark_rows = {
      mask_stream  => [1_u64],
      size_stream  => [1_u64],
      value_stream => [1_u64],
    } of String => Array(UInt64)
    payloads = {
      mask_stream  => [Bytes[1_u8]],
      size_stream  => [w105l_u64_bytes(6_u64)],
      value_stream => ["hidden".to_slice],
    } of String => Array(Bytes)
    read_calls = [] of String
    validate_calls = [] of String
    decode_calls = [] of String
    plan = CrystalClick::WideTupleTypePlan.for_type(type_name).not_nil!
    reader = CrystalClick::WidePart.w105_nullable_lazy_test_reader(
      plan, mark_rows, payloads, read_calls, validate_calls, decode_calls
    )
    leaf_name_bytes = "String".bytesize.to_u64
    leaf_type_charge = instance_sizeof(CrystalClick::WideTupleLeafType).to_u64 +
                       instance_sizeof(String).to_u64 + leaf_name_bytes + 1_u64
    exact_charge = CrystalClick::WideTupleTypePlan::RESULT_CONTAINER_ACCOUNTING_BYTES +
                   sizeof(CrystalClick::WideTupleField).to_u64 +
                   w106_nullable_tree_and_path_charge("text") +
                   leaf_type_charge +
                   instance_sizeof(CrystalClick::ScalarNullMap).to_u64 +
                   CrystalClick::WideTupleTypePlan::RESULT_ROW_ACCOUNTING_BYTES +
                   CrystalClick::WideTupleTypePlan::STRING_SLOT_ACCOUNTING_BYTES +
                   sizeof(UInt8).to_u64 + 6_u64
    yielded = [] of Int32

    expect_raises(CrystalClick::CorruptPartError, "Tuple materialization charge exceeds per-range limit") do
      reader.each(0, 1, exact_charge - 1_u64) do |_mark, mark_index|
        yielded << mark_index
        nil
      end
    end
    yielded.should be_empty
    validate_calls.should be_empty
    read_calls.should eq([size_stream])

    data = reader.read(0, 1, exact_charge)
    data.row(0)["text"].should be_nil
    data["text"].physical_values.as(Array(String)).should eq(["hidden"])
    data["text"].string_bytesize_at(0).should eq(6_u64)
    data.row(0).string_bytesize.should eq(6_u64)
  end

  it "preserves Nullable raw buffers and masks through each descriptor-copy overload" do
    fixed_type = CrystalClick::WideTupleLeafType.parse("Nullable(FixedString(3))").not_nil!
    fixed_values = [
      CrystalClick::FixedStringValue.from_raw(3, Bytes[0xff_u8, 0_u8, 0_u8]),
      CrystalClick::FixedStringValue.new(3, "x"),
    ] of CrystalClick::FixedStringValue
    fixed = CrystalClick::WideTupleLeafColumn.new("fixed", fixed_type, fixed_values, w105l_null_map([1_u8, 0_u8]))
    fixed_copy = fixed.owned_copy_for(fixed_type.parameterized_type.not_nil!)
    fixed_copy.leaf_type.should eq(fixed_type)
    fixed_copy.null_map.not_nil!.bytes.should eq([1_u8, 0_u8])
    fixed_copy.physical_values.as(Array(CrystalClick::FixedStringValue)).should eq(fixed_values)

    enum_type = CrystalClick::WideTupleLeafType.parse(
      "Nullable(Enum8('minus' = -7, 'plus' = 4))"
    ).not_nil!
    enum_values = [0_i8, -7_i8] of Int8
    enum_column = CrystalClick::WideTupleLeafColumn.new("state", enum_type, enum_values, w105l_null_map([1_u8, 0_u8]))
    enum_copy = enum_column.owned_copy_for(enum_type.parameterized_type.not_nil!)
    enum_copy.leaf_type.should eq(enum_type)
    enum_copy.null_map.not_nil!.bytes.should eq([1_u8, 0_u8])
    enum_copy.physical_values.as(Array(Int8)).should eq(enum_values)
    enum_values[0] = 99_i8
    enum_copy.physical_values.as(Array(Int8)).should eq([0_i8, -7_i8])

    decimal_type = CrystalClick::WideTupleLeafType.parse("Nullable(Decimal(9, 2))").not_nil!
    decimal_values = [Int32::MIN, 17_i32] of Int32
    decimal = CrystalClick::WideTupleLeafColumn.new("amount", decimal_type, decimal_values, w105l_null_map([1_u8, 0_u8]))
    decimal_copy = decimal.owned_copy_for(decimal_type.parameterized_type.not_nil!)
    decimal_copy.leaf_type.should eq(decimal_type)
    decimal_copy.null_map.not_nil!.bytes.should eq([1_u8, 0_u8])
    decimal_copy.physical_values.as(Array(Int32)).should eq(decimal_values)
    decimal_values[0] = 0_i32
    decimal_copy.physical_values.as(Array(Int32)).should eq([Int32::MIN, 17_i32])

    datetime_type = CrystalClick::WideTupleLeafType.parse(
      "Nullable(DateTime64(3, 'US/Eastern'))"
    ).not_nil!
    datetime_values = [
      CrystalClick::DateTime64Value.new(Int64::MIN, 3),
      CrystalClick::DateTime64Value.new(42_i64, 3),
    ] of CrystalClick::DateTime64Value
    datetime = CrystalClick::WideTupleLeafColumn.new("tick", datetime_type, datetime_values, w105l_null_map([1_u8, 0_u8]))
    datetime_copy = datetime.owned_copy_for(datetime_type.datetime_type.not_nil!)
    datetime_copy.leaf_type.should eq(datetime_type)
    datetime_copy.null_map.not_nil!.bytes.should eq([1_u8, 0_u8])
    datetime_copy.datetime_type.not_nil!.time_zone?.not_nil!.name.should eq("US/Eastern")
    datetime_copy.physical_values.as(Array(CrystalClick::DateTime64Value)).should eq(datetime_values)
    datetime_values[0] = CrystalClick::DateTime64Value.new(0_i64, 3)
    datetime_copy.physical_values.as(Array(CrystalClick::DateTime64Value)).should eq([
      CrystalClick::DateTime64Value.new(Int64::MIN, 3),
      CrystalClick::DateTime64Value.new(42_i64, 3),
    ])
  end

  it "rejects nullable descriptors paired with the wrong physical carrier" do
    mask = w105l_null_map([0_u8])
    wrong_carriers = [
      {"Nullable(UInt64)", [1_i64] of Int64},
      {"Nullable(Bool)", [true] of Bool},
      {"Nullable(Enum8('minus' = -7, 'plus' = 4))", [CrystalClick::Enum8Value.new(
        CrystalClick::WideTupleLeafType.parse("Enum8('minus' = -7, 'plus' = 4)").not_nil!.parameterized_type.as(CrystalClick::WideTupleEnumType).definition,
        -7_i8
      )] of CrystalClick::Enum8Value},
      {"Nullable(Decimal(9, 2))", [CrystalClick::Decimal32Value.new(17_i32, 9, 2)] of CrystalClick::Decimal32Value},
      {"Nullable(DateTime64(3, 'US/Eastern'))", [CrystalClick::DateTimeValue.new(1_u32)] of CrystalClick::DateTimeValue},
      {"Nullable(FixedString(3))", ["x"] of String},
    ]

    wrong_carriers.each_with_index do |(type_name, values), index|
      leaf_type = CrystalClick::WideTupleLeafType.parse(type_name).not_nil!
      expect_raises(ArgumentError) do
        CrystalClick::WideTupleLeafColumn.new("wrong#{index}", leaf_type, values, mask)
      end
    end
  end
end
