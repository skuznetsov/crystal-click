require "./spec_helper"

private def w108_scalar_type_names : Array(String)
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

private def w108_bare_leaf(name : String, type_name : String) : CrystalClick::WideTupleLeafColumn
  leaf_type = CrystalClick::WideTupleLeafType.parse(type_name) || raise "unadmitted W108 fixture leaf #{type_name}"

  if parameterized_type = leaf_type.parameterized_type
    case parameterized_type
    when CrystalClick::WideTupleFixedStringType
      values = [
        CrystalClick::FixedStringValue.new(parameterized_type.width, "a"),
        CrystalClick::FixedStringValue.new(parameterized_type.width, ""),
        CrystalClick::FixedStringValue.new(parameterized_type.width, "z"),
      ] of CrystalClick::FixedStringValue
      return CrystalClick::WideTupleLeafColumn.new(name, leaf_type, values, nil)
    when CrystalClick::WideTupleEnumType
      code = parameterized_type.definition.entries.first[1]
      if parameterized_type.definition.kind == :enum8
        value = CrystalClick::Enum8Value.new(parameterized_type.definition, code.to_i8)
        return CrystalClick::WideTupleLeafColumn.new(name, leaf_type, [value, value, value] of CrystalClick::Enum8Value, nil)
      else
        value = CrystalClick::Enum16Value.new(parameterized_type.definition, code)
        return CrystalClick::WideTupleLeafColumn.new(name, leaf_type, [value, value, value] of CrystalClick::Enum16Value, nil)
      end
    when CrystalClick::WideTupleDecimalType
      precision = parameterized_type.precision
      scale = parameterized_type.scale
      case parameterized_type.storage_width
      when 4
        values = [Int32::MIN, 0_i32, Int32::MAX].map { |raw| CrystalClick::Decimal32Value.new(raw, precision, scale) }
        return CrystalClick::WideTupleLeafColumn.new(name, leaf_type, values, nil)
      when 8
        values = [Int64::MIN, 0_i64, Int64::MAX].map { |raw| CrystalClick::Decimal64Value.new(raw, precision, scale) }
        return CrystalClick::WideTupleLeafColumn.new(name, leaf_type, values, nil)
      when 16
        values = [Int128::MIN, 0_i128, Int128::MAX].map { |raw| CrystalClick::Decimal128Value.new(raw, precision, scale) }
        return CrystalClick::WideTupleLeafColumn.new(name, leaf_type, values, nil)
      else
        low = CrystalClick::Decimal256Value.new(0_u128, 1_u128 << 127)
        zero = CrystalClick::Decimal256Value.new(0_u128, 0_u128)
        high = CrystalClick::Decimal256Value.new(UInt128::MAX, (1_u128 << 127) - 1_u128)
        values = [low, zero, high].map { |raw| CrystalClick::Decimal256TupleValue.new(raw, precision, scale) }
        return CrystalClick::WideTupleLeafColumn.new(name, leaf_type, values, nil)
      end
    end
  end

  if datetime_type = leaf_type.datetime_type
    case datetime_type.family
    when CrystalClick::DateTimeColumnType::Family::DateTime
      return CrystalClick::WideTupleLeafColumn.new(
        name, leaf_type,
        [CrystalClick::DateTimeValue.new(1_u32), CrystalClick::DateTimeValue.new(0_u32), CrystalClick::DateTimeValue.new(UInt32::MAX)] of CrystalClick::DateTimeValue,
        nil
      )
    when CrystalClick::DateTimeColumnType::Family::DateTime64
      precision = datetime_type.precision?.not_nil!.to_i
      values = [
        CrystalClick::DateTime64Value.new(0x0102_0304_0506_0708_i64, precision),
        CrystalClick::DateTime64Value.new(0_i64, precision),
        CrystalClick::DateTime64Value.new(Int64::MIN, precision),
      ] of CrystalClick::DateTime64Value
      return CrystalClick::WideTupleLeafColumn.new(name, leaf_type, values, nil)
    end
  end

  if type_name.starts_with?("Time64(")
    precision = CrystalClick::WideTupleTemporalType.precision(type_name).not_nil!.to_i
    values = [
      CrystalClick::Time64Value.new(Int64::MIN, precision),
      CrystalClick::Time64Value.new(0_i64, precision),
      CrystalClick::Time64Value.new(Int64::MAX, precision),
    ] of CrystalClick::Time64Value
    return CrystalClick::WideTupleLeafColumn.new(name, leaf_type, values, nil)
  end

  if type_name == "Date"
    return CrystalClick::WideTupleLeafColumn.new(name, leaf_type,
      [CrystalClick::DateValue.new(UInt16::MAX), CrystalClick::DateValue.new(0_u16), CrystalClick::DateValue.new(123_u16)] of CrystalClick::DateValue, nil)
  elsif type_name == "Date32"
    return CrystalClick::WideTupleLeafColumn.new(name, leaf_type,
      [CrystalClick::Date32Value.new(Int32::MIN), CrystalClick::Date32Value.new(0_i32), CrystalClick::Date32Value.new(Int32::MAX)] of CrystalClick::Date32Value, nil)
  elsif type_name == "Time"
    return CrystalClick::WideTupleLeafColumn.new(name, leaf_type,
      [CrystalClick::TimeValue.new(Int32::MIN), CrystalClick::TimeValue.new(0_i32), CrystalClick::TimeValue.new(Int32::MAX)] of CrystalClick::TimeValue, nil)
  elsif type_name == "String"
    return CrystalClick::WideTupleLeafColumn.new(name, leaf_type, ["same", "", "\0binary"] of String, nil)
  elsif type_name == "Bool"
    return CrystalClick::WideTupleLeafColumn.new(name, leaf_type, [true, false, true] of Bool, nil)
  elsif type_name == "UUID"
    return CrystalClick::WideTupleLeafColumn.new(name, leaf_type,
      [CrystalClick::UUIDValue.new(1_u64, 2_u64), CrystalClick::UUIDValue.new(0_u64, 0_u64), CrystalClick::UUIDValue.new(UInt64::MAX, 9_u64)] of CrystalClick::UUIDValue, nil)
  elsif type_name == "IPv4"
    return CrystalClick::WideTupleLeafColumn.new(name, leaf_type,
      [CrystalClick::IPv4Value.new(0x0102_0304_u32), CrystalClick::IPv4Value.new(0_u32), CrystalClick::IPv4Value.new(0xaabb_ccdd_u32)] of CrystalClick::IPv4Value, nil)
  elsif type_name == "IPv6"
    return CrystalClick::WideTupleLeafColumn.new(name, leaf_type,
      [CrystalClick::IPv6Value.new(0x2001_0db8_85a3_0000_u64, 0x0000_8a2e_0370_7334_u64), CrystalClick::IPv6Value.new(0_u64, 0_u64), CrystalClick::IPv6Value.new(UInt64::MAX, 2_u64)] of CrystalClick::IPv6Value, nil)
  end

  numeric_values : CrystalClick::WideTupleLeafColumn::Buffer = case type_name
  when "Int8"    then [Int8::MIN, 0_i8, Int8::MAX] of Int8
  when "UInt8"   then [0_u8, 1_u8, UInt8::MAX] of UInt8
  when "Int16"   then [Int16::MIN, 0_i16, Int16::MAX] of Int16
  when "UInt16"  then [0_u16, 1_u16, UInt16::MAX] of UInt16
  when "Int32"   then [Int32::MIN, 0_i32, Int32::MAX] of Int32
  when "UInt32"  then [0_u32, 1_u32, UInt32::MAX] of UInt32
  when "Int64"   then [Int64::MIN, 0_i64, Int64::MAX] of Int64
  when "UInt64"  then [0_u64, 1_u64, UInt64::MAX] of UInt64
  when "Int128"  then [Int128::MIN, 0_i128, Int128::MAX] of Int128
  when "UInt128" then [0_u128, 1_u128, UInt128::MAX] of UInt128
  when "Int256"
    [CrystalClick::Int256Value.new(0_u128, 1_u128 << 127), CrystalClick::Int256Value.new(0_u128, 0_u128), CrystalClick::Int256Value.new(UInt128::MAX, (1_u128 << 127) - 1_u128)] of CrystalClick::Int256Value
  when "UInt256"
    [CrystalClick::UInt256Value.new(UInt128::MAX, UInt128::MAX), CrystalClick::UInt256Value.new(0_u128, 0_u128), CrystalClick::UInt256Value.new(UInt128::MAX - 1_u128, UInt128::MAX)] of CrystalClick::UInt256Value
  when "Float32"
    [0x7fc0_1234_u32.unsafe_as(Float32), 0x8000_0000_u32.unsafe_as(Float32), 1.5_f32] of Float32
  when "Float64"
    [0x7ff8_0000_0001_2345_u64.unsafe_as(Float64), 0x8000_0000_0000_0000_u64.unsafe_as(Float64), 1.5_f64] of Float64
  when "BFloat16"
    [CrystalClick::BFloat16Value.new(0x7fc1_u16), CrystalClick::BFloat16Value.new(0x8000_u16), CrystalClick::BFloat16Value.new(0x3fc0_u16)] of CrystalClick::BFloat16Value
  else
    raise "W108 fixture lacks scalar carrier for #{type_name}"
  end
  CrystalClick::WideTupleLeafColumn.new(name, leaf_type, numeric_values, nil)
end

private def w108_nullable_leaf(name : String, base_type_name : String) : CrystalClick::WideTupleLeafColumn
  base = w108_bare_leaf(name, base_type_name)
  mask = CrystalClick::ScalarNullMap.new(Bytes[1_u8, 0_u8, 1_u8], 3_u64)
  base.as_nullable(mask)
end

private def w108_nullable_raw_leaf(
  name : String,
  type_name : String,
  values : CrystalClick::WideTupleLeafColumn::Buffer,
  null_bytes : Bytes = Bytes[1_u8, 0_u8, 1_u8],
) : CrystalClick::WideTupleLeafColumn
  leaf_type = CrystalClick::WideTupleLeafType.parse("Nullable(#{type_name})") ||
              raise "unadmitted W108 nullable fixture leaf #{type_name}"
  map = CrystalClick::ScalarNullMap.new(null_bytes, values.size.to_u64)
  CrystalClick::WideTupleLeafColumn.new(name, leaf_type, values, map)
end

private def w108_assert_same_physical(
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
    expected_values.map { |value| {value.low, value.high} }.should eq(actual_values.map { |value| {value.low, value.high} })
  elsif expected_values = expected.as?(Array(CrystalClick::UInt256Value))
    actual_values = actual.as(Array(CrystalClick::UInt256Value))
    expected_values.map { |value| {value.low, value.high} }.should eq(actual_values.map { |value| {value.low, value.high} })
  else
    actual.should eq(expected)
  end
  nil
end

private def w108_assert_same_logical_value(
  expected : CrystalClick::WideTupleLeafColumn::Value,
  actual : CrystalClick::WideTupleLeafColumn::Value,
) : Nil
  if expected.nil?
    actual.should be_nil
  elsif expected_float32 = expected.as?(Float32)
    actual.as(Float32).unsafe_as(UInt32).should eq(expected_float32.unsafe_as(UInt32))
  elsif expected_float64 = expected.as?(Float64)
    actual.as(Float64).unsafe_as(UInt64).should eq(expected_float64.unsafe_as(UInt64))
  else
    actual.should eq(expected)
  end
  nil
end

private def w108_mark_rows(part_path : String, stream_name : String) : Array(UInt64)
  path = File.join(part_path, "#{CrystalClick::StreamName.hash(stream_name)}.mrk2")
  bytes = File.read(path).to_slice
  (bytes.size % CrystalClick::WidePart::MARK_SIZE).should eq(0)
  Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE + 16
    count = 0_u64
    8.times { |byte| count |= bytes[offset + byte].to_u64 << (byte * 8) }
    count
  end
end

private def w108_stage_factory(calls : Array(Int32)) : Proc(String, String)
  ->(parent : String) do
    calls << 1
    stage = File.tempname(".w108-map-tuple-stage-", nil, dir: parent)
    Dir.mkdir(stage)
    stage
  end
end

private def w108_string_copy(calls : Array(Int32)) : Proc(CrystalClick::WideTupleLeafColumn, Array(String))
  ->(column : CrystalClick::WideTupleLeafColumn) do
    calls << 1
    if column.leaf_type.nullable?
      column.physical_values.as(Array(String))
    else
      column.string_values
    end
  end
end

module CrystalClick
  module WidePartWriter
    class MapTuplePartWriter
      def self.w108_test_preflight(
        destination : String,
        key_name : String,
        keys : Slice(UInt64),
        value_name : String,
        type_name : String,
        row_sizes : Slice(UInt64),
        map_keys : WideTupleLeafColumn,
        value_columns : Array(WideTupleLeafColumn),
        rows_per_mark : Int32,
        infrastructure : TuplePartInfrastructure,
      ) : MapTuplePartWriteInput
        preflight(destination, key_name, keys, value_name, type_name, row_sizes,
          map_keys, value_columns, rows_per_mark, infrastructure)
      end

      def self.w108_test_validate_staged_part(
        stage : String,
        input : MapTuplePartWriteInput,
        infrastructure : TuplePartInfrastructure,
      ) : Nil
        validate_staged_part(stage, input, infrastructure)
      end

      def self.w108_test_mark_materialization_charge(
        type_plan : WideMapTupleTypePlan,
        key_type : WideTupleLeafType,
        map_keys : WideTupleLeafColumn,
        value_columns : Array(WideTupleLeafColumn),
        fields : Array(WideTupleField),
        row_sizes : Slice(UInt64),
        rows_per_mark : Int32,
      ) : {UInt64, UInt64}
        schedule = TupleLeafMarkSchedule.from_row_sizes(
          row_sizes, rows_per_mark, WidePart::MAX_ARRAY_MARK_ROWS,
          WidePart::MAX_ARRAY_MARK_ELEMENTS.to_i32, MAX_MARKS,
          WideTupleTypePlan::MAX_MATERIALIZED_BYTES
        )
        mark = schedule.mark(0)
        schedule_charge = TupleLeafMarkSchedule.ragged_logical_charge(1).not_nil!
        charge = mark_materialization_charge(
          type_plan, key_type, mark, map_keys, value_columns, fields
        ).not_nil!
        {charge, schedule_charge}
      end
    end

    def self.w108_test_mark_materialization_charge(
      type_plan : WideMapTupleTypePlan,
      key_type : WideTupleLeafType,
      map_keys : WideTupleLeafColumn,
      value_columns : Array(WideTupleLeafColumn),
      fields : Array(WideTupleField),
      row_sizes : Slice(UInt64),
      rows_per_mark : Int32,
    ) : {UInt64, UInt64}
      MapTuplePartWriter.w108_test_mark_materialization_charge(
        type_plan, key_type, map_keys, value_columns, fields, row_sizes, rows_per_mark
      )
    end

    def self.w108_test_validate_staged_against(
      stage : String,
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      type_name : String,
      row_sizes : Slice(UInt64),
      map_keys : WideTupleLeafColumn,
      value_columns : Array(WideTupleLeafColumn),
      rows_per_mark : Int32,
      infrastructure : TuplePartInfrastructure,
    ) : Nil
      input = MapTuplePartWriter.w108_test_preflight(
        destination, key_name, keys, value_name, type_name, row_sizes,
        map_keys, value_columns, rows_per_mark, infrastructure
      )
      MapTuplePartWriter.w108_test_validate_staged_part(stage, input, infrastructure)
    end

    def self.w108_test_infrastructure(
      stage_factory : Proc(String, String),
      copy_string_values : Proc(WideTupleLeafColumn, Array(String)),
    ) : TuplePartInfrastructure
      build_tuple_part_infrastructure(stage_factory, copy_string_values)
    end

    def self.w108_test_write_with_hooks(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      type_name : String,
      row_sizes : Slice(UInt64),
      map_keys : WideTupleLeafColumn,
      value_columns : Array(WideTupleLeafColumn),
      rows_per_mark : Int32,
      stage_factory : Proc(String, String),
      copy_string_values : Proc(WideTupleLeafColumn, Array(String)),
    ) : String
      MapTuplePartWriter.write(destination, key_name, keys, value_name, type_name,
        row_sizes, map_keys, value_columns, rows_per_mark,
        build_tuple_part_infrastructure(stage_factory, copy_string_values))
    end
  end
end

describe "W108 Map(K, named Tuple) writer" do
  it "writes and reads every admitted W105 scalar key descriptor" do
    parent = File.tempname("crystal-click-map-tuple-w108-key-matrix")
    Dir.mkdir(parent)
    keys = [10_u64, 20_u64, 30_u64, 40_u64, 50_u64]
    row_sizes = [0_u64, 2_u64, 0_u64, 1_u64, 0_u64]
    value = CrystalClick::WideTupleLeafColumn.new("value", [31_u8, 32_u8, 33_u8] of UInt8)

    begin
      w108_scalar_type_names.each_with_index do |key_type, index|
        declaration = "Map(#{key_type}, Tuple(value UInt8))"
        map_keys = w108_bare_leaf("keys", key_type)
        destination = File.join(parent, "part-#{index}")

        CrystalClick::WidePartWriter.write_uint64_map_tuple_part(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", declaration,
          row_sizes.to_unsafe.to_slice(row_sizes.size), map_keys, [value], 2
        ).should eq(destination)

        part = CrystalClick::WidePart.open_typed(destination, "payload")
        decoded = part.read_map_tuple_mark_range("payload", 0, part.mark_count)
        decoded.type_name.should eq(declaration)
        decoded.row_sizes.should eq(row_sizes)
        decoded.entry_count.should eq(3)
        decoded.key_column.leaf_type.should eq(map_keys.leaf_type)
        w108_assert_same_physical(map_keys.physical_values, decoded.key_column.physical_values)
        decoded.tuple_data["value"].physical_values.should eq([31_u8, 32_u8, 33_u8])
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "retains zero-valued external primary keys and their Map row association" do
    parent = File.tempname("crystal-click-map-tuple-w108-zero-primary-key")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    primary_keys = [0_u64, 0_u64, 11_u64]
    row_sizes = [1_u64, 0_u64, 1_u64]
    map_keys = CrystalClick::WideTupleLeafColumn.new("keys", ["first", "third"] of String)
    values = CrystalClick::WideTupleLeafColumn.new("value", [101_u8, 203_u8] of UInt8)
    declaration = "Map(String, Tuple(value UInt8))"

    begin
      CrystalClick::WidePartWriter.write_uint64_map_tuple_part(
        destination, "pk", primary_keys.to_unsafe.to_slice(primary_keys.size), "payload", declaration,
        row_sizes.to_unsafe.to_slice(row_sizes.size), map_keys, [values], 1
      ).should eq(destination)

      serialization = JSON.parse(File.read(File.join(destination, "serialization.json"))).as_h
      external_key_stats = serialization["columns"].as_a.first.as_h
      external_key_stats["kind"].as_s.should eq("Default")
      external_key_stats["name"].as_s.should eq("pk")
      external_key_stats["num_defaults"].as_i.should eq(2)
      external_key_stats["num_rows"].as_i.should eq(3)

      key_part = CrystalClick::WidePart.open_typed(destination, "pk")
      key_part.read_uint64_mark_range("pk", 0, key_part.mark_count).should eq(primary_keys)

      map_part = CrystalClick::WidePart.open_typed(destination, "payload")
      decoded = map_part.read_map_tuple_mark_range("payload", 0, map_part.mark_count)
      decoded.row_sizes.should eq(row_sizes)
      decoded.row(0).key_as(0, String).should eq("first")
      decoded.row(0).value_at(0).value_as("value", UInt8).should eq(101_u8)
      decoded.row(1).size.should eq(0)
      decoded.row(2).key_as(0, String).should eq("third")
      decoded.row(2).value_at(0).value_as("value", UInt8).should eq(203_u8)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "preserves all bare and Nullable W105 value leaves over ragged rows and empty marks" do
    parent = File.tempname("crystal-click-map-tuple-w108-leaf-matrix")
    Dir.mkdir(parent)
    keys = [10_u64, 20_u64, 30_u64, 40_u64, 50_u64]
    row_sizes = [0_u64, 2_u64, 0_u64, 1_u64, 0_u64]
    map_key_values = ["dup", "dup", "\0binary"] of String
    map_keys = CrystalClick::WideTupleLeafColumn.new("keys", map_key_values)
    types = w108_scalar_type_names

    begin
      [{"bare", false}, {"nullable", true}].each do |profile, nullable|
        columns = [] of CrystalClick::WideTupleLeafColumn
        types.each_with_index do |base_type, index|
          name = "leaf_#{index.to_s.rjust(2, '0')}"
          columns << (nullable ? w108_nullable_leaf(name, base_type) : w108_bare_leaf(name, base_type))
        end
        if nullable
          columns << w108_nullable_raw_leaf("hidden_enum", "Enum8('small' = 3)",
            [Int8::MIN, 3_i8, Int8::MAX] of Int8)
          columns << w108_nullable_raw_leaf("hidden_bool", "Bool", [0xa5_u8, 0_u8, 0xff_u8] of UInt8)
          columns << w108_nullable_raw_leaf("hidden_float", "Float32",
            [0x7fc0_1234_u32.unsafe_as(Float32), 0x8000_0000_u32.unsafe_as(Float32), 0xffc0_5678_u32.unsafe_as(Float32)] of Float32)
          columns << w108_nullable_raw_leaf("hidden_decimal", "Decimal(76, 5)",
            [CrystalClick::Int256Value.new(0_u128, 1_u128 << 127), CrystalClick::Int256Value.new(0_u128, 0_u128),
             CrystalClick::Int256Value.new(UInt128::MAX, (1_u128 << 127) - 1_u128)] of CrystalClick::Int256Value)
          columns << CrystalClick::WideTupleLeafColumn.new("bare_probe", [0_u64, 9_u64, 0_u64] of UInt64)
        end

        tuple_type = "Tuple(#{columns.map { |column| "#{column.name} #{column.type_name}" }.join(", ")})"
        declaration = "Map(String, #{tuple_type})"
        destination = File.join(parent, "part-#{profile}")
        CrystalClick::WidePartWriter.write_uint64_map_tuple_part(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", declaration,
          row_sizes.to_unsafe.to_slice(row_sizes.size), map_keys, columns, 1
        ).should eq(destination)

        part = CrystalClick::WidePart.open_typed(destination, "payload")
        decoded = part.read_map_tuple_mark_range("payload", 0, part.mark_count)
        decoded.plan.type_name.should eq(declaration)
        decoded.row_count.should eq(5)
        decoded.entry_count.should eq(3)
        decoded.row_sizes.should eq(row_sizes)
        decoded.offsets.should eq([0_u64, 0_u64, 2_u64, 2_u64, 3_u64, 3_u64])
        decoded.row(0).size.should eq(0)
        decoded.row(1).size.should eq(2)
        decoded.row(2).size.should eq(0)
        decoded.row(3).size.should eq(1)
        decoded.row(4).size.should eq(0)
        decoded.row(1).key_at(0).should eq("dup")
        decoded.row(1).key_at(1).should eq("dup")
        decoded.row(3).key_at(0).should eq("\0binary")
        w108_mark_rows(destination, "payload.size0").should eq([1_u64, 1_u64, 1_u64, 1_u64, 1_u64, 0_u64])
        w108_mark_rows(destination, "payload%2Ekeys.size").should eq([1_u64, 1_u64, 1_u64, 1_u64, 1_u64, 0_u64])

        actual_columns = decoded.tuple_data.columns
        actual_columns.size.should eq(columns.size)
        actual_columns.each_with_index do |actual, index|
          expected = columns[index]
          actual.name.should eq(expected.name)
          actual.leaf_type.should eq(expected.leaf_type)
          actual.type_name.should eq(expected.type_name)
          w108_assert_same_physical(expected.physical_values, actual.physical_values)
          if expected.leaf_type.nullable?
            actual.null_map.not_nil!.bytes.should eq(expected.null_map.not_nil!.bytes)
          else
            actual.null_map.should be_nil
          end
          3.times do |entry|
            w108_assert_same_logical_value(expected.value_at(entry), actual.value_at(entry))
          end
        end
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "retains nested Map Tuple paths and exact qualified leaf descriptors" do
    parent = File.tempname("crystal-click-map-tuple-w108-nested")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [10_u64, 20_u64, 30_u64, 40_u64, 50_u64]
    row_sizes = [0_u64, 2_u64, 0_u64, 1_u64, 0_u64]
    key_type = CrystalClick::WideTupleLeafType.parse("String").not_nil!
    map_keys = CrystalClick::WideTupleLeafColumn.new("keys", ["dup", "dup", "\0key"] of String)
    code_type = CrystalClick::WideTupleLeafType.parse("Nullable(Enum8('negative' = -7, 'positive' = 4))").not_nil!
    code_mask = CrystalClick::ScalarNullMap.new(Bytes[1_u8, 0_u8, 1_u8], 3_u64)
    code = CrystalClick::WideTupleLeafColumn.new(
      "meta.code", code_type, [Int8::MIN, -7_i8, Int8::MAX] of Int8, code_mask
    )
    note_type = CrystalClick::WideTupleLeafType.parse("String").not_nil!
    note = CrystalClick::WideTupleLeafColumn.new(
      "meta.note", note_type, ["hidden\0bytes", "visible", ""] of String, nil
    )
    zone_type = CrystalClick::WideTupleLeafType.parse("DateTime64(3, 'UTC')").not_nil!
    zone = CrystalClick::WideTupleLeafColumn.new(
      "zone", zone_type,
      [CrystalClick::DateTime64Value.new(0x0102_0304_0506_0708_i64, 3),
       CrystalClick::DateTime64Value.new(0_i64, 3),
       CrystalClick::DateTime64Value.new(Int64::MIN, 3)] of CrystalClick::DateTime64Value,
      nil
    )
    tuple_type = "Tuple(meta Tuple(code #{code_type.type_name}, note String), zone #{zone_type.type_name})"
    declaration = "Map(String, #{tuple_type})"
    columns = [code, note, zone]

    begin
      CrystalClick::WidePartWriter.write_uint64_map_tuple_part(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", declaration,
        row_sizes.to_unsafe.to_slice(row_sizes.size), map_keys, columns, 2
      )

      plan = CrystalClick::WideMapTupleTypePlan.for_type(declaration).not_nil!
      plan.key_type.should eq(key_type)
      plan.tuple_plan.type_name.should eq(tuple_type)
      plan.physical_streams("payload").should eq([
        "payload.size0",
        "payload%2Ekeys.size",
        "payload%2Ekeys",
        "payload%2Evalues%2Emeta%2Ecode.null",
        "payload%2Evalues%2Emeta%2Ecode",
        "payload%2Evalues%2Emeta%2Enote.size",
        "payload%2Evalues%2Emeta%2Enote",
        "payload%2Evalues%2Ezone",
      ])
      File.exists?(File.join(destination, "#{CrystalClick::StreamName.hash("payload%2Evalues%2Emeta%2Ecode")}.bin")).should be_true

      part = CrystalClick::WidePart.open_typed(destination, "payload")
      decoded = part.read_map_tuple_mark_range("payload", 0, part.mark_count)
      decoded.type_name.should eq(declaration)
      decoded.row_sizes.should eq(row_sizes)
      decoded.key_column.leaf_type.should eq(key_type)
      decoded.tuple_data.type_name_at(["meta"]).should eq("Tuple(code #{code_type.type_name}, note String)")
      decoded.tuple_data["meta.code"].leaf_type.should eq(code_type)
      w108_assert_same_physical(code.physical_values, decoded.tuple_data["meta.code"].physical_values)
      decoded.tuple_data["meta.code"].null_map.not_nil!.bytes.should eq(code_mask.bytes)
      decoded.tuple_data.value_at_scoped(["meta"], "code", 0).should be_nil
      decoded.tuple_data.value_at_scoped(["meta"], "code", 1).should eq(CrystalClick::Enum8Value.new(
        code_type.parameterized_type.not_nil!.as(CrystalClick::WideTupleEnumType).definition, -7_i8
      ))
      decoded.tuple_data["meta.note"].physical_values.should eq(["hidden\0bytes", "visible", ""])
      decoded.tuple_data["zone"].leaf_type.should eq(zone_type)
      decoded.tuple_data["zone"].physical_values.should eq(zone.physical_values)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps an all-empty Map's outer rows and String size/data streams" do
    parent = File.tempname("crystal-click-map-tuple-w108-all-empty")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 3_u64]
    row_sizes = [0_u64, 0_u64, 0_u64]
    map_key_type = CrystalClick::WideTupleLeafType.parse("String").not_nil!
    map_keys = CrystalClick::WideTupleLeafColumn.new("keys", map_key_type, [] of String, nil)
    empty_mask = CrystalClick::ScalarNullMap.new(Bytes.empty, 0_u64)
    empty_value_type = CrystalClick::WideTupleLeafType.parse("Nullable(String)").not_nil!
    value = CrystalClick::WideTupleLeafColumn.new("text", empty_value_type, [] of String, empty_mask)
    declaration = "Map(String, Tuple(text Nullable(String)))"

    begin
      CrystalClick::WidePartWriter.write_uint64_map_tuple_part(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", declaration,
        row_sizes.to_unsafe.to_slice(row_sizes.size), map_keys, [value], 1
      )
      decoded = CrystalClick::WidePart.open_typed(destination, "payload").read_map_tuple_mark_range(
        "payload", 0, CrystalClick::WidePart.open_typed(destination, "payload").mark_count
      )
      decoded.row_sizes.should eq(row_sizes)
      decoded.entry_count.should eq(0)
      decoded.key_column.physical_values.should eq([] of String)
      decoded.tuple_data["text"].physical_values.should eq([] of String)
      decoded.tuple_data["text"].null_map.not_nil!.bytes.should be_empty
      w108_mark_rows(destination, "payload.size0").should eq([1_u64, 1_u64, 1_u64, 0_u64])
      w108_mark_rows(destination, "payload%2Ekeys.size").should eq([1_u64, 1_u64, 1_u64, 0_u64])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "accounts per-mark key Strings, value Strings, and retained schedule separately" do
    declaration = "Map(String, Tuple(note String, hidden Nullable(String)))"
    plan = CrystalClick::WideMapTupleTypePlan.for_type(declaration).not_nil!
    key_type = plan.key_type
    keys = CrystalClick::WideTupleLeafColumn.new("keys", key_type, ["key", "other", "last"] of String, nil)
    hidden_type = plan.tuple_plan.fields[1].leaf_type
    hidden_mask = CrystalClick::ScalarNullMap.new(Bytes[1_u8, 0_u8, 1_u8], 3_u64)
    values = [
      CrystalClick::WideTupleLeafColumn.new("note", plan.tuple_plan.fields[0].leaf_type,
        ["value-entry", "more", ""] of String, nil),
      CrystalClick::WideTupleLeafColumn.new("hidden", hidden_type,
        ["nullpayload", "visible", "hidden-end"] of String, hidden_mask),
    ] of CrystalClick::WideTupleLeafColumn
    row_sizes = [1_u64, 2_u64]
    key_bytes = "key".bytesize.to_u64
    value_bytes = "value-entry".bytesize.to_u64 + "nullpayload".bytesize.to_u64

    actual, schedule_bytes = CrystalClick::WidePartWriter.w108_test_mark_materialization_charge(
      plan, key_type, keys, values, plan.tuple_plan.fields, row_sizes.to_unsafe.to_slice(2), 1
    )
    expected = plan.materialization_charge(1_u64, 1_u64, key_bytes, value_bytes, schedule_bytes).not_nil!

    key_bytes.should_not eq(value_bytes)
    schedule_bytes.should be > 0
    actual.should eq(expected)
  end

  it "rejects wrong exact key identity and Nullable keys before copy, stage, or residue" do
    parent = File.tempname("crystal-click-map-tuple-w108-preflight")
    Dir.mkdir(parent)
    File.write(File.join(parent, "keep"), "unchanged")
    before = Dir.children(parent).sort
    stage_calls = [] of Int32
    copy_calls = [] of Int32
    destination = File.join(parent, "part")
    keys = [1_u64]
    sizes = [1_u64]
    wrong_same_width = CrystalClick::WideTupleLeafColumn.new("keys", [7_u32] of UInt32)
    value = CrystalClick::WideTupleLeafColumn.new("value", ["payload"] of String)
    factory = w108_stage_factory(stage_calls)
    copy = w108_string_copy(copy_calls)

    begin
      expect_raises(ArgumentError, "Map key storage does not match its exact nonnullable schema") do
        CrystalClick::WidePartWriter.w108_test_write_with_hooks(
          destination, "pk", keys.to_unsafe.to_slice(1), "payload", "Map(Int32, Tuple(value String))",
          sizes.to_unsafe.to_slice(1), wrong_same_width, [value], 1, factory, copy
        )
      end

      nullable_type = CrystalClick::WideTupleLeafType.parse("Nullable(String)").not_nil!
      nullable_map = CrystalClick::ScalarNullMap.new(Bytes[0_u8], 1_u64)
      nullable_key = CrystalClick::WideTupleLeafColumn.new("keys", nullable_type, ["k"] of String, nullable_map)
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.w108_test_write_with_hooks(
          destination, "pk", keys.to_unsafe.to_slice(1), "payload", "Map(Nullable(String), Tuple(value String))",
          sizes.to_unsafe.to_slice(1), nullable_key, [value], 1, factory, copy
        )
      end

      stage_calls.should be_empty
      copy_calls.should be_empty
      File.exists?(destination).should be_false
      Dir.children(parent).sort.should eq(before)
      File.read(File.join(parent, "keep")).should eq("unchanged")
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "charges hidden Nullable(String) entry bytes before callbacks or staging" do
    parent = File.tempname("crystal-click-map-tuple-w108-string-budget")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    stage_calls = [] of Int32
    copy_calls = [] of Int32
    bytes_per_value = (CrystalClick::WideTupleTypePlan::MAX_MATERIALIZED_BYTES // 2_u64).to_i32 + 1_024
    hidden = String.new(Bytes.new(bytes_per_value, 0x61_u8))
    map_key = CrystalClick::WideTupleLeafColumn.new("keys", [1_u64, 2_u64] of UInt64)
    mask = CrystalClick::ScalarNullMap.new(Bytes[1_u8, 1_u8], 2_u64)
    text_type = CrystalClick::WideTupleLeafType.parse("Nullable(String)").not_nil!
    text = CrystalClick::WideTupleLeafColumn.new("text", text_type, [hidden, hidden] of String, mask)
    keys = [1_u64, 2_u64]
    sizes = [1_u64, 1_u64]

    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.w108_test_write_with_hooks(
          destination, "pk", keys.to_unsafe.to_slice(2), "payload",
          "Map(UInt64, Tuple(text Nullable(String)))", sizes.to_unsafe.to_slice(2),
          map_key, [text], 1, w108_stage_factory(stage_calls), w108_string_copy(copy_calls)
        )
      end
      stage_calls.should be_empty
      copy_calls.should be_empty
      File.exists?(destination).should be_false
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a staged equal-total but shifted Map row-size vector" do
    parent = File.tempname("crystal-click-map-tuple-w108-row-boundary-attack")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [10_u64, 20_u64]
    actual_sizes = [1_u64, 2_u64]
    expected_wrong_sizes = [2_u64, 1_u64]
    map_keys = CrystalClick::WideTupleLeafColumn.new("keys", [5_u64, 5_u64, 7_u64] of UInt64)
    values = [CrystalClick::WideTupleLeafColumn.new("value", [11_u8, 12_u8, 13_u8] of UInt8)] of CrystalClick::WideTupleLeafColumn
    declaration = "Map(UInt64, Tuple(value UInt8))"

    begin
      CrystalClick::WidePartWriter.write_uint64_map_tuple_part(
        destination, "pk", keys.to_unsafe.to_slice(2), "payload", declaration,
        actual_sizes.to_unsafe.to_slice(2), map_keys, values, 1
      )
      infrastructure = CrystalClick::WidePartWriter.w108_test_infrastructure(
        ->(parent : String) { File.tempname("unused-w108-stage-", nil, dir: parent) },
        ->(column : CrystalClick::WideTupleLeafColumn) { column.physical_values.as(Array(String)) }
      )
      staged_part = CrystalClick::WidePart.open_typed(destination, "payload")
      expect_raises(CrystalClick::CorruptPartError, "staged Map row boundaries or cardinality differ") do
        CrystalClick::WidePartWriter.w108_test_validate_staged_against(
          destination, File.join(parent, "not-published"), "pk", keys.to_unsafe.to_slice(2),
          "payload", declaration, expected_wrong_sizes.to_unsafe.to_slice(2),
          map_keys, values, 1, infrastructure
        )
      end
      staged_part.row_count.should eq(2)
      staged_part.read_map_tuple_mark_range("payload", 0, staged_part.mark_count).row_sizes.should eq(actual_sizes)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
