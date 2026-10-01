require "./spec_helper"

private def w107lm_nullable_types : Array(String)
  types = [
    "Int8", "UInt8", "Int16", "UInt16", "Int32", "UInt32", "Int64", "UInt64",
    "Int128", "UInt128", "Int256", "UInt256", "Float32", "Float64", "BFloat16", "Bool",
    "String", "UUID", "IPv4", "IPv6", "Date", "Date32", "DateTime", "Time",
  ]
  10.times { |precision| types << "DateTime64(#{precision})" }
  10.times { |precision| types << "Time64(#{precision})" }
  types.concat([
    "DateTime('UTC')", "DateTime64(9, 'America/New_York')", "FixedString(5)",
    "Enum8('negative' = -7, 'positive' = 4)", "Enum16('negative' = -300, 'positive' = 400)",
    "Decimal(9, 2)", "Decimal(18, 3)", "Decimal(38, 4)", "Decimal(76, 5)",
  ])
  types.size.should eq(53)
  types
end

private def w107lm_raw_values(type_name : String) : CrystalClick::WideTupleLeafColumn::Buffer
  case type_name
  when "Int8"    then return [-101_i8, 0_i8, 119_i8] of Int8
  when "UInt8"   then return [201_u8, 0_u8, 255_u8] of UInt8
  when "Int16"   then return [-30_001_i16, 0_i16, 30_001_i16] of Int16
  when "UInt16"  then return [65_000_u16, 0_u16, 64_000_u16] of UInt16
  when "Int32"   then return [Int32::MIN, 0_i32, Int32::MAX] of Int32
  when "UInt32"  then return [UInt32::MAX, 0_u32, 4_000_000_000_u32] of UInt32
  when "Int64"   then return [Int64::MIN, 0_i64, Int64::MAX] of Int64
  when "UInt64"  then return [UInt64::MAX, 0_u64, UInt64::MAX - 1_u64] of UInt64
  when "Int128"  then return [Int128::MIN, 0_i128, Int128::MAX] of Int128
  when "UInt128" then return [UInt128::MAX, 0_u128, UInt128::MAX - 1_u128] of UInt128
  when "Int256"
    return [
      CrystalClick::Int256Value.new(0_u128, 1_u128 << 127),
      CrystalClick::Int256Value.new(0_u128, 0_u128),
      CrystalClick::Int256Value.new(UInt128::MAX, (1_u128 << 127) - 1_u128),
    ] of CrystalClick::Int256Value
  when "UInt256"
    return [
      CrystalClick::UInt256Value.new(UInt128::MAX, UInt128::MAX),
      CrystalClick::UInt256Value.new(0_u128, 0_u128),
      CrystalClick::UInt256Value.new(UInt128::MAX - 1_u128, UInt128::MAX),
    ] of CrystalClick::UInt256Value
  when "Float32"
    return [
      0x7fc0_1234_u32.unsafe_as(Float32),
      0x8000_0000_u32.unsafe_as(Float32),
      0xffc0_5678_u32.unsafe_as(Float32),
    ] of Float32
  when "Float64"
    return [
      0x7ff8_0000_0001_2345_u64.unsafe_as(Float64),
      0x8000_0000_0000_0000_u64.unsafe_as(Float64),
      0xfff8_ffff_1234_5678_u64.unsafe_as(Float64),
    ] of Float64
  when "BFloat16"
    return [
      CrystalClick::BFloat16Value.new(0x7fc1_u16),
      CrystalClick::BFloat16Value.new(0x8000_u16),
      CrystalClick::BFloat16Value.new(0xffa2_u16),
    ] of CrystalClick::BFloat16Value
  when "Bool"
    return [0xa5_u8, 0_u8, 0xff_u8] of UInt8
  when "String"
    return ["\0hidden", "", "tail\0payload"] of String
  when "UUID"
    return [
      CrystalClick::UUIDValue.new(0x0102_u64, 0x0304_u64),
      CrystalClick::UUIDValue.new(0_u64, 0_u64),
      CrystalClick::UUIDValue.new(UInt64::MAX, 9_u64),
    ] of CrystalClick::UUIDValue
  when "IPv4"
    return [
      CrystalClick::IPv4Value.new(0x0102_0304_u32),
      CrystalClick::IPv4Value.new(0_u32),
      CrystalClick::IPv4Value.new(0xaabb_ccdd_u32),
    ] of CrystalClick::IPv4Value
  when "IPv6"
    return [
      CrystalClick::IPv6Value.new(0x2001_0db8_85a3_0000_u64, 0x0000_8a2e_0370_7334_u64),
      CrystalClick::IPv6Value.new(0_u64, 0_u64),
      CrystalClick::IPv6Value.new(UInt64::MAX, 2_u64),
    ] of CrystalClick::IPv6Value
  when "Date"
    return [CrystalClick::DateValue.new(UInt16::MAX), CrystalClick::DateValue.new(0_u16), CrystalClick::DateValue.new(123_u16)] of CrystalClick::DateValue
  when "Date32"
    return [CrystalClick::Date32Value.new(Int32::MIN), CrystalClick::Date32Value.new(0_i32), CrystalClick::Date32Value.new(Int32::MAX)] of CrystalClick::Date32Value
  when "Time"
    return [CrystalClick::TimeValue.new(Int32::MIN), CrystalClick::TimeValue.new(0_i32), CrystalClick::TimeValue.new(Int32::MAX)] of CrystalClick::TimeValue
  when "FixedString(5)"
    return [
      CrystalClick::FixedStringValue.from_raw(5, Bytes[0x00_u8, 0xff_u8, 0x41_u8, 0x00_u8, 0x7f_u8]),
      CrystalClick::FixedStringValue.new(5, "mid"),
      CrystalClick::FixedStringValue.from_raw(5, Bytes[0x80_u8, 0x00_u8, 0xfe_u8, 0x42_u8, 0x00_u8]),
    ] of CrystalClick::FixedStringValue
  when "Enum8('negative' = -7, 'positive' = 4)"
    return [-128_i8, -7_i8, 127_i8] of Int8
  when "Enum16('negative' = -300, 'positive' = 400)"
    return [Int16::MIN, -300_i16, Int16::MAX] of Int16
  when "Decimal(9, 2)"
    return [Int32::MIN, 0_i32, Int32::MAX] of Int32
  when "Decimal(18, 3)"
    return [Int64::MIN, 0_i64, Int64::MAX] of Int64
  when "Decimal(38, 4)"
    return [Int128::MIN, 0_i128, Int128::MAX] of Int128
  when "Decimal(76, 5)"
    return [
      CrystalClick::Int256Value.new(0_u128, 1_u128 << 127),
      CrystalClick::Int256Value.new(0_u128, 0_u128),
      CrystalClick::Int256Value.new(UInt128::MAX, (1_u128 << 127) - 1_u128),
    ] of CrystalClick::Int256Value
  end

  if datetime_type = CrystalClick::DateTimeColumnType.parse_leaf(type_name)
    case datetime_type.family
    when CrystalClick::DateTimeColumnType::Family::DateTime
      return [
        CrystalClick::DateTimeValue.new(0x0102_0304_u32),
        CrystalClick::DateTimeValue.new(0_u32),
        CrystalClick::DateTimeValue.new(UInt32::MAX),
      ] of CrystalClick::DateTimeValue
    when CrystalClick::DateTimeColumnType::Family::DateTime64
      precision = datetime_type.precision?.not_nil!.to_i
      return [
        CrystalClick::DateTime64Value.new(0x0102_0304_0506_0708_i64, precision),
        CrystalClick::DateTime64Value.new(0_i64, precision),
        CrystalClick::DateTime64Value.new(Int64::MIN, precision),
      ] of CrystalClick::DateTime64Value
    end
  end

  if type_name.starts_with?("Time64(")
    precision = CrystalClick::WideTupleTemporalType.precision(type_name).not_nil!.to_i
    return [
      CrystalClick::Time64Value.new(Int64::MIN, precision),
      CrystalClick::Time64Value.new(0_i64, precision),
      CrystalClick::Time64Value.new(Int64::MAX, precision),
    ] of CrystalClick::Time64Value
  end

  raise "W107 leaf matrix lacks raw fixture for #{type_name}"
end

private def w107lm_assert_same_physical(
  expected : CrystalClick::WideTupleLeafColumn::Buffer,
  actual : CrystalClick::WideTupleLeafColumn::Buffer,
) : Nil
  if expected_values = expected.as?(Array(Float32))
    actual_values = actual.as(Array(Float32))
    expected_values.map(&.unsafe_as(UInt32)).should eq(actual_values.map(&.unsafe_as(UInt32)))
  elsif expected_values = expected.as?(Array(Float64))
    actual_values = actual.as(Array(Float64))
    expected_values.map(&.unsafe_as(UInt64)).should eq(actual_values.map(&.unsafe_as(UInt64)))
  elsif expected_values = expected.as?(Array(CrystalClick::Int256Value))
    actual_values = actual.as(Array(CrystalClick::Int256Value))
    expected_values.map { |value| {value.low, value.high} }.should eq(
      actual_values.map { |value| {value.low, value.high} }
    )
  elsif expected_values = expected.as?(Array(CrystalClick::UInt256Value))
    actual_values = actual.as(Array(CrystalClick::UInt256Value))
    expected_values.map { |value| {value.low, value.high} }.should eq(
      actual_values.map { |value| {value.low, value.high} }
    )
  else
    actual.should eq(expected)
  end
  nil
end

private def w107lm_mark_rows(part_path : String, stream_name : String) : Array(UInt64)
  path = File.join(part_path, "#{CrystalClick::StreamName.hash(stream_name)}.mrk2")
  bytes = File.read(path).to_slice
  (bytes.size % CrystalClick::WidePart::MARK_SIZE).should eq(0)
  Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE + 16
    row_count = 0_u64
    8.times { |byte| row_count |= bytes[offset + byte].to_u64 << (byte * 8) }
    row_count
  end
end

describe "W107 Array(Tuple) terminal leaf matrix" do
  it "round-trips every W105 nullable scalar declaration through ragged outer rows" do
    parent = File.tempname("crystal-click-array-tuple-w107-leaf-matrix")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")

    nullable_types = w107lm_nullable_types
    columns = [
      CrystalClick::WideTupleLeafColumn.new("bare_u64", [99_u64, 0_u64, 7_u64] of UInt64),
      CrystalClick::WideTupleLeafColumn.new("bare_string", ["outer", "", "hidden"] of String),
    ] of CrystalClick::WideTupleLeafColumn
    nullable_types.each_with_index do |base_type, index|
      leaf_type = CrystalClick::WideTupleLeafType.parse("Nullable(#{base_type})") ||
                  raise "W107 matrix type was not admitted: #{base_type}"
      null_map = CrystalClick::ScalarNullMap.new(Bytes[1_u8, 0_u8, 1_u8], 3_u64)
      columns << CrystalClick::WideTupleLeafColumn.new(
        "nullable_#{index.to_s.rjust(2, '0')}", leaf_type, w107lm_raw_values(base_type), null_map
      )
    end
    columns.size.should eq(55)

    tuple_type = "Tuple(#{columns.map { |column| "#{column.name} #{column.type_name}" }.join(", ")})"
    array_type = "Array(#{tuple_type})"
    keys = [10_u64, 20_u64, 30_u64, 40_u64, 50_u64]
    row_sizes = [0_u64, 2_u64, 0_u64, 1_u64, 0_u64]

    begin
      CrystalClick::WidePartWriter.write_uint64_array_tuple_part(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", array_type,
        row_sizes.to_unsafe.to_slice(row_sizes.size), columns, 1
      ).should eq(destination)

      part = CrystalClick::WidePart.open_typed(destination, "payload")
      part.column_type.should eq(array_type)
      part.mark_count.should eq(5)
      decoded = part.read_array_tuple_mark_range("payload", 0, part.mark_count)
      decoded.type_name.should eq(array_type)
      decoded.tuple_data.type_name.should eq(tuple_type)
      decoded.row_count.should eq(5)
      decoded.element_count.should eq(3)
      decoded.row_sizes.should eq(row_sizes)
      decoded.offsets.should eq([0_u64, 0_u64, 2_u64, 2_u64, 3_u64, 3_u64])
      [0, 2, 4].each { |index| decoded.row(index).size.should eq(0) }
      decoded.row(1).size.should eq(2)
      decoded.row(3).size.should eq(1)

      # All mark row counts remain in outer-row units. Flattened leaf and mask
      # cardinalities instead follow row_sizes, including zero-element marks.
      w107lm_mark_rows(destination, "payload.size0").should eq([1_u64, 1_u64, 1_u64, 1_u64, 1_u64, 0_u64])
      w107lm_mark_rows(destination, "payload%2Enullable_00.null").should eq([1_u64, 1_u64, 1_u64, 1_u64, 1_u64, 0_u64])
      w107lm_mark_rows(destination, "payload%2Enullable_00").should eq([1_u64, 1_u64, 1_u64, 1_u64, 1_u64, 0_u64])

      actual_columns = decoded.tuple_data.columns
      actual_columns.size.should eq(columns.size)
      actual_columns.each_with_index do |actual, index|
        expected = columns[index]
        actual.name.should eq(expected.name)
        actual.leaf_type.should eq(expected.leaf_type)
        actual.type_name.should eq(expected.type_name)
        w107lm_assert_same_physical(expected.physical_values, actual.physical_values)

        if expected.leaf_type.nullable?
          actual.null_map.not_nil!.bytes.should eq([1_u8, 0_u8, 1_u8])
          [0, 2].each { |row| actual.value_at(row).should be_nil }
          actual.value_at(1).should eq(expected.value_at(1))
          decoded.row(1)[0][expected.name].should be_nil
          decoded.row(1)[1][expected.name].should eq(expected.value_at(1))
          decoded.row(3)[0][expected.name].should be_nil
        else
          actual.null_map.should be_nil
          [0, 1, 2].each do |row|
            actual.value_at(row).should eq(expected.value_at(row))
          end
        end
      end

      # These pairs deliberately carry identical raw values but distinct
      # declared identities: bare versus UTC DateTime, and unqualified versus
      # America/New_York DateTime64 at the same precision.
      bare_datetime = actual_columns.find { |column| column.leaf_type.base_type_name == "DateTime" }.not_nil!
      utc_datetime = actual_columns.find { |column| column.leaf_type.base_type_name == "DateTime('UTC')" }.not_nil!
      bare_datetime.physical_values.should eq(utc_datetime.physical_values)
      (bare_datetime.leaf_type == utc_datetime.leaf_type).should be_false

      local_dt64 = actual_columns.find { |column| column.leaf_type.base_type_name == "DateTime64(9)" }.not_nil!
      ny_dt64 = actual_columns.find { |column| column.leaf_type.base_type_name == "DateTime64(9, 'America/New_York')" }.not_nil!
      local_dt64.physical_values.should eq(ny_dt64.physical_values)
      (local_dt64.leaf_type == ny_dt64.leaf_type).should be_false

      actual_columns.each do |column|
        base = column.leaf_type.base_type_name
        if base.starts_with?("DateTime64(")
          precision = CrystalClick::DateTimeColumnType.parse_leaf(base).not_nil!.precision?.not_nil!
          column.physical_values.as(Array(CrystalClick::DateTime64Value)).each do |value|
            value.precision.should eq(precision)
          end
        elsif base.starts_with?("Time64(")
          precision = CrystalClick::WideTupleTemporalType.precision(base).not_nil!
          column.physical_values.as(Array(CrystalClick::Time64Value)).each do |value|
            value.precision.should eq(precision)
          end
        end
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
