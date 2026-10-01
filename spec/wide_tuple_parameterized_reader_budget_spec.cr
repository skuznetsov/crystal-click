require "./spec_helper"

class CrystalClick::WidePart
  # Build the private range reader with observable payload/decode callbacks.
  # This is a spec-only reopen; production exposes no test instrumentation.
  def self.w101_reader_budget_test_reader(
    plan : WideTupleTypePlan,
    rows : UInt64,
    payloads : Hash(String, Bytes),
    range_row_calls : Array(String),
    mark_row_calls : Array(String),
    read_calls : Array(String),
    validate_calls : Array(String),
    parameterized_decode_calls : Array(String),
  ) : TupleReader
    TupleReader.new(
      plan,
      "payload",
      ->(stream_name : String, _first_mark : Int32, _mark_count : Int32) {
        range_row_calls << stream_name
        rows
      },
      ->(stream_name : String, _mark_index : Int32) {
        mark_row_calls << stream_name
        rows
      },
      ->(stream_name : String, _first_mark : Int32, _mark_count : Int32, expected_bytes : Int32, _element_width : Int32, _expected_rows : UInt64) {
        read_calls << stream_name
        bytes = payloads[stream_name]? || raise "unexpected payload read for #{stream_name}"
        raise "test payload length mismatch for #{stream_name}" unless bytes.size == expected_bytes
        bytes
      },
      ->(stream_name : String, _first_mark : Int32, _mark_count : Int32, _expected_bytes : Int32, _element_width : Int32, _expected_rows : UInt64) {
        validate_calls << stream_name
        nil
      },
      ->(_bytes : Bytes, _offset : Int32) { 0_u64 },
      TupleLeafDecoder.new(
        ->(name : String, _type_name : String, _bytes : Bytes, _rows : UInt64, _width : Int32) {
          WideTupleLeafColumn.new(name, [] of UInt64)
        },
        ->(name : String, _bytes : Bytes, _rows : UInt64, _width : Int32) {
          WideTupleLeafColumn.new(name, [] of Bool)
        },
        ->(name : String, _type_name : String, _bytes : Bytes, _rows : UInt64, _width : Int32) {
          WideTupleLeafColumn.new(name, [] of UInt64)
        },
        ->(name : String, _type_name : String, _bytes : Bytes, _rows : UInt64, _width : Int32) {
          WideTupleLeafColumn.new(name, [] of UInt64)
        },
        ->(name : String, _exact_type : DateTimeColumnType, _bytes : Bytes, _rows : UInt64, _width : Int32) {
          raise "unexpected DateTime leaf decode for #{name} in FixedString budget test"
        },
        ->(name : String, exact_type : WideTupleParameterizedType, bytes : Bytes, encoded_rows : UInt64, width : Int32) {
          parameterized_decode_calls << name
          fixed_type = exact_type.as?(WideTupleFixedStringType) ||
                       raise "unexpected non-FixedString parameterized decode"
          unless width == fixed_type.width && bytes.size.to_u64 == encoded_rows * width.to_u64
            raise CorruptPartError.new("test FixedString decode dimensions do not match")
          end

          values = Array(FixedStringValue).new(encoded_rows.to_i) do |row_index|
            offset = row_index * width
            row_bytes = Bytes.new(width)
            width.times { |byte_index| row_bytes[byte_index] = bytes[offset + byte_index] }
            FixedStringValue.from_raw(width, row_bytes)
          end
          WideTupleLeafColumn.new(name, fixed_type, values)
        },
        ->(_name : String, _leaf_type : WideTupleLeafType, _bytes : Bytes, _null_map : ScalarNullMap, _encoded_rows : UInt64, _width : Int32) {
          raise "unexpected Nullable leaf decode in FixedString budget test"
        })
    )
  end
end

private def w101rb_test_reader(
  type_name : String,
  rows : UInt64,
  payloads : Hash(String, Bytes),
  range_row_calls : Array(String),
  mark_row_calls : Array(String),
  read_calls : Array(String),
  validate_calls : Array(String),
  parameterized_decode_calls : Array(String),
)
  plan = CrystalClick::WideTupleTypePlan.for_type(type_name).not_nil!
  CrystalClick::WidePart.w101_reader_budget_test_reader(
    plan,
    rows,
    payloads,
    range_row_calls,
    mark_row_calls,
    read_calls,
    validate_calls,
    parameterized_decode_calls
  )
end

describe "W101 parameterized Tuple reader materialization budget" do
  it "charges one FixedString payload before reading or decoding the selected range" do
    type_name = "Tuple(code FixedString(4))"
    plan = CrystalClick::WideTupleTypePlan.for_type(type_name).not_nil!
    rows = 2_u64
    payload_bytes = 8_u64
    old_charge_without_fixed_payload = plan.materialization_charge(rows, 0_u64).not_nil!
    correct_charge = plan.materialization_charge(rows, payload_bytes).not_nil!
    budget = old_charge_without_fixed_payload + 4_u64
    (old_charge_without_fixed_payload < budget).should be_true
    (budget < correct_charge).should be_true

    payloads = {
      "payload%2Ecode" => Bytes[0x41_u8, 0_u8, 0_u8, 0_u8, 0x42_u8, 0x43_u8, 0_u8, 0_u8],
    } of String => Bytes
    range_row_calls = [] of String
    mark_row_calls = [] of String
    read_calls = [] of String
    validate_calls = [] of String
    decode_calls = [] of String
    reader = w101rb_test_reader(
      type_name, rows, payloads, range_row_calls, mark_row_calls, read_calls, validate_calls, decode_calls
    )

    expect_raises(CrystalClick::CorruptPartError, "Tuple materialization charge exceeds per-range limit") do
      reader.read(0, 1, budget)
    end
    read_calls.should be_empty
    validate_calls.should be_empty
    decode_calls.should be_empty

    yielded_marks = [] of Int32
    expect_raises(CrystalClick::CorruptPartError, "Tuple materialization charge exceeds per-range limit") do
      reader.each(0, 1, budget) do |_data, mark_index|
        yielded_marks << mark_index
        nil
      end
    end
    yielded_marks.should be_empty
    read_calls.should be_empty
    validate_calls.should be_empty
    decode_calls.should be_empty
  end

  it "aggregates FixedString payload from every fixed field before materialization" do
    type_name = "Tuple(left FixedString(2), right FixedString(3))"
    plan = CrystalClick::WideTupleTypePlan.for_type(type_name).not_nil!
    rows = 2_u64
    aggregate_payload_bytes = rows * (2_u64 + 3_u64)
    old_charge_without_fixed_payload = plan.materialization_charge(rows, 0_u64).not_nil!
    correct_charge = plan.materialization_charge(rows, aggregate_payload_bytes).not_nil!
    budget = old_charge_without_fixed_payload + 8_u64
    (old_charge_without_fixed_payload + 6_u64 < budget).should be_true
    (budget < correct_charge).should be_true

    payloads = {
      "payload%2Eleft"  => Bytes[0x41_u8, 0_u8, 0x42_u8, 0_u8],
      "payload%2Eright" => Bytes[0x78_u8, 0x79_u8, 0_u8, 0x7a_u8, 0_u8, 0_u8],
    } of String => Bytes
    range_row_calls = [] of String
    mark_row_calls = [] of String
    read_calls = [] of String
    validate_calls = [] of String
    decode_calls = [] of String
    reader = w101rb_test_reader(
      type_name, rows, payloads, range_row_calls, mark_row_calls, read_calls, validate_calls, decode_calls
    )

    expect_raises(CrystalClick::CorruptPartError, "Tuple materialization charge exceeds per-range limit") do
      reader.read(0, 1, budget)
    end
    read_calls.should be_empty
    validate_calls.should be_empty
    decode_calls.should be_empty

    yielded_marks = [] of Int32
    expect_raises(CrystalClick::CorruptPartError, "Tuple materialization charge exceeds per-range limit") do
      reader.each(0, 1, budget) do |_data, mark_index|
        yielded_marks << mark_index
        nil
      end
    end
    yielded_marks.should be_empty
    read_calls.should be_empty
    validate_calls.should be_empty
    decode_calls.should be_empty
  end

  it "accepts the exact aggregate charge and returns both FixedString columns" do
    type_name = "Tuple(left FixedString(2), right FixedString(3))"
    plan = CrystalClick::WideTupleTypePlan.for_type(type_name).not_nil!
    rows = 2_u64
    payload_bytes = rows * (2_u64 + 3_u64)
    exact_charge = plan.materialization_charge(rows, payload_bytes).not_nil!
    payloads = {
      "payload%2Eleft"  => Bytes[0x41_u8, 0_u8, 0x42_u8, 0_u8],
      "payload%2Eright" => Bytes[0x78_u8, 0x79_u8, 0_u8, 0x7a_u8, 0_u8, 0_u8],
    } of String => Bytes
    range_row_calls = [] of String
    mark_row_calls = [] of String
    read_calls = [] of String
    validate_calls = [] of String
    decode_calls = [] of String
    reader = w101rb_test_reader(
      type_name, rows, payloads, range_row_calls, mark_row_calls, read_calls, validate_calls, decode_calls
    )

    reader.materialization_charge(0, 1, exact_charge).should eq(exact_charge)
    read_calls.should be_empty
    validate_calls.should eq(["payload%2Eleft", "payload%2Eright"])
    decode_calls.should be_empty

    result = reader.read(0, 1, exact_charge)
    result.row_count.should eq(2)
    result.fields.map { |field| {field.name, field.type_name} }.should eq([
      {"left", "FixedString(2)"}, {"right", "FixedString(3)"},
    ])
    result.columns[0].values_as(CrystalClick::FixedStringValue).should eq([
      CrystalClick::FixedStringValue.from_raw(2_i32, Bytes[0x41_u8, 0_u8]),
      CrystalClick::FixedStringValue.from_raw(2_i32, Bytes[0x42_u8, 0_u8]),
    ])
    result.columns[1].values_as(CrystalClick::FixedStringValue).should eq([
      CrystalClick::FixedStringValue.from_raw(3_i32, Bytes[0x78_u8, 0x79_u8, 0_u8]),
      CrystalClick::FixedStringValue.from_raw(3_i32, Bytes[0x7a_u8, 0_u8, 0_u8]),
    ])
    result.string_bytesize_at(0).should eq(5_u64)
    result.string_bytesize_at(1).should eq(5_u64)
    read_calls.should eq(["payload%2Eleft", "payload%2Eright"])
    validate_calls.should eq([
      "payload%2Eleft", "payload%2Eright", "payload%2Eleft", "payload%2Eright",
    ])
    decode_calls.should eq(["left", "right"])
  end
end
