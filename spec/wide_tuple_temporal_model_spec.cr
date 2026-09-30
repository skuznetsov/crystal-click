require "./spec_helper"

describe CrystalClick::WideTupleTemporalType do
  it "maps only the six exact temporal identities to their physical widths" do
    {
      {"Date", 2},
      {"Date32", 4},
      {"DateTime", 4},
      {"DateTime64(0)", 8},
      {"DateTime64(9)", 8},
      {"Time", 4},
      {"Time64(0)", 8},
      {"Time64(9)", 8},
    }.each do |type_name, width|
      CrystalClick::WideTupleTemporalType.width(type_name).should eq(width)
    end

    ["Date()", "DateTime64", "DateTime64(10)", "DateTime64(03)", "DateTime64(3, 'UTC')", "Time64(10)"].each do |type_name|
      CrystalClick::WideTupleTemporalType.width(type_name).should be_nil
    end
    CrystalClick::WideTupleTemporalType.precision("DateTime64(10)").should be_nil
    CrystalClick::WideTupleTemporalType.precision("Time64(03)").should be_nil
    CrystalClick::WideTupleTemporalType.owned_width("DateTime64(10)").should be_nil
  end

  it "canonicalizes only bare temporal names and one-digit scaled AST nodes" do
    {"Date", "Date32", "DateTime", "Time"}.each do |type_name|
      node = CrystalClick::WideTypeExpression.parse(type_name).not_nil!
      CrystalClick::WideTupleTemporalType.canonical_type(node).should eq(type_name)
    end

    (0..9).each do |precision|
      {"DateTime64", "Time64"}.each do |name|
        type_name = "#{name}(#{precision})"
        node = CrystalClick::WideTypeExpression.parse(type_name).not_nil!
        CrystalClick::WideTupleTemporalType.canonical_type(node).should eq(type_name)
        CrystalClick::WideTupleTemporalType.precision(type_name).should eq(precision.to_u8)
      end
    end

    ["DateTime64(10)", "DateTime64(03)", "DateTime64(3, UTC)", "Time64(10)"].each do |type_name|
      node = CrystalClick::WideTypeExpression.parse(type_name).not_nil!
      CrystalClick::WideTupleTemporalType.canonical_type(node).should be_nil
    end
    CrystalClick::WideTupleTemporalType.canonical_type(CrystalClick::WideTypeExpression.parse("DateTime64").not_nil!).should be_nil
    CrystalClick::WideTupleTemporalType.canonical_type(CrystalClick::WideTypeExpression.parse("Time64(10)").not_nil!).should be_nil
  end

  it "keeps scaled precision in immutable raw wrappers and rejects invalid constructor input" do
    (0..9).each do |precision|
      CrystalClick::DateTime64Value.new(-17_i64, precision).precision.should eq(precision.to_u8)
      CrystalClick::Time64Value.new(21_i64, precision).precision.should eq(precision.to_u8)
    end

    CrystalClick::DateTime64Value.new(-17_i64, 3).raw.should eq(-17_i64)
    CrystalClick::Time64Value.new(21_i64, 9).raw.should eq(21_i64)
    CrystalClick::DateTime64Value.new(2_i64, 3_u8).precision.should eq(3_u8)
    CrystalClick::Time64Value.new(2_i64, 9_u8).precision.should eq(9_u8)
    expect_raises(ArgumentError) { CrystalClick::DateTime64Value.new(0_i64, -1) }
    expect_raises(ArgumentError) { CrystalClick::DateTime64Value.new(0_i64, 10) }
    expect_raises(ArgumentError) { CrystalClick::Time64Value.new(0_i64, -1) }
    expect_raises(ArgumentError) { CrystalClick::Time64Value.new(0_i64, 10) }
  end

  it "compares exact nominal bits and precision without crossing wrapper identities" do
    same_dt64 = CrystalClick::DateTime64Value.new(7_i64, 3)
    same_time64 = CrystalClick::Time64Value.new(7_i64, 3)
    CrystalClick::WideTupleTemporalType.same_bits?(same_dt64, CrystalClick::DateTime64Value.new(7_i64, 3)).should be_true
    CrystalClick::WideTupleTemporalType.same_bits?(same_dt64, CrystalClick::DateTime64Value.new(7_i64, 4)).should be_false
    CrystalClick::WideTupleTemporalType.same_bits?(same_dt64, same_time64).should be_false
    CrystalClick::WideTupleTemporalType.same_bits?(CrystalClick::DateTimeValue.new(7_u32), CrystalClick::DateTime64Value.new(7_i64, 0)).should be_false
    CrystalClick::WideTupleTemporalType.same_bits?(CrystalClick::Date32Value.new(7_i32), CrystalClick::TimeValue.new(7_i32)).should be_false
    same_dt64.hash.should eq(CrystalClick::DateTime64Value.new(7_i64, 3).hash)
  end

  it "uses raw zero for Tuple defaults rather than the Date32 SQL default" do
    CrystalClick::WideTupleTemporalType.is_default?(CrystalClick::Date32Value.new(0_i32)).should be_true
    CrystalClick::WideTupleTemporalType.is_default?(CrystalClick::Date32Value.new(-25_567_i32)).should be_false
    CrystalClick::WideTupleTemporalType.is_default?(CrystalClick::DateValue.new(0_u16)).should be_true
    CrystalClick::WideTupleTemporalType.is_default?(CrystalClick::DateTimeValue.new(0_u32)).should be_true
    CrystalClick::WideTupleTemporalType.is_default?(CrystalClick::DateTime64Value.new(0_i64, 9)).should be_true
    CrystalClick::WideTupleTemporalType.is_default?(CrystalClick::TimeValue.new(1_i32)).should be_false
    CrystalClick::WideTupleTemporalType.is_default?(CrystalClick::Time64Value.new(0_i64, 0)).should be_true
  end

  it "validates nominal buffer type and scaled precision even for empty arrays" do
    dt64 = [] of CrystalClick::DateTime64Value
    time64 = [] of CrystalClick::Time64Value
    CrystalClick::WideTupleTemporalType.validate_buffer!("DateTime64(3)", dt64)
    CrystalClick::WideTupleTemporalType.validate_buffer!("Time64(9)", time64)
    expect_raises(ArgumentError) { CrystalClick::WideTupleTemporalType.validate_buffer!("Time64(9)", dt64) }
    expect_raises(ArgumentError) { CrystalClick::WideTupleTemporalType.validate_buffer!("DateTime64(3)", time64) }
    expect_raises(ArgumentError) { CrystalClick::WideTupleTemporalType.validate_buffer!("Date", [] of CrystalClick::Date32Value) }
    expect_raises(ArgumentError) { CrystalClick::WideTupleTemporalType.validate_buffer!("Date32", [] of CrystalClick::DateTimeValue) }
    expect_raises(ArgumentError) { CrystalClick::WideTupleTemporalType.validate_buffer!("DateTime", [] of CrystalClick::TimeValue) }
    expect_raises(ArgumentError) { CrystalClick::WideTupleTemporalType.validate_buffer!("Time", [] of CrystalClick::DateValue) }
    expect_raises(ArgumentError) do
      CrystalClick::WideTupleTemporalType.validate_buffer!("DateTime64(3)", [CrystalClick::DateTime64Value.new(1_i64, 4)] of CrystalClick::DateTime64Value)
    end
    expect_raises(ArgumentError) { CrystalClick::WideTupleTemporalType.validate_buffer!("DateTime64(10)", dt64) }
  end
end

describe CrystalClick::WideTupleLeafColumn do
  it "requires exact metadata for temporal arrays and preserves it across owned copies" do
    values = [CrystalClick::DateTime64Value.new(-4_i64, 3)]
    name = String.new("ticks".to_slice)
    type_name = String.new("DateTime64(3)".to_slice)
    column = CrystalClick::WideTupleLeafColumn.new(name, type_name, values)
    name.to_unsafe[0] = 'X'.ord.to_u8
    type_name.to_unsafe[0] = 'X'.ord.to_u8
    values[0] = CrystalClick::DateTime64Value.new(99_i64, 3)

    column.name.should eq("ticks")
    column.type_name.should eq("DateTime64(3)")
    column.values_as(CrystalClick::DateTime64Value).should eq([CrystalClick::DateTime64Value.new(-4_i64, 3)])
    copy = column.owned_copy
    copy.type_name.should eq("DateTime64(3)")
    copy.value_at(0, CrystalClick::DateTime64Value).should eq(CrystalClick::DateTime64Value.new(-4_i64, 3))

    empty = CrystalClick::WideTupleLeafColumn.new("empty", "Time64(9)", [] of CrystalClick::Time64Value)
    empty.owned_copy.type_name.should eq("Time64(9)")
    empty.size.should eq(0)
    empty_dt64 = CrystalClick::WideTupleLeafColumn.new("empty", "DateTime64(3)", [] of CrystalClick::DateTime64Value)
    empty_dt64.owned_copy.type_name.should eq("DateTime64(3)")
    expect_raises(ArgumentError) { CrystalClick::WideTupleLeafColumn.new("empty", "DateTime64(3)", [] of CrystalClick::Time64Value) }
    expect_raises(ArgumentError) { CrystalClick::WideTupleLeafColumn.new("empty", "Date", [] of CrystalClick::Date32Value) }
    expect_raises(ArgumentError) { CrystalClick::WideTupleLeafColumn.new("empty", "Date32", [] of CrystalClick::DateTimeValue) }
    expect_raises(ArgumentError) { CrystalClick::WideTupleLeafColumn.new("empty", "DateTime", [] of CrystalClick::TimeValue) }
    expect_raises(ArgumentError) { CrystalClick::WideTupleLeafColumn.new("empty", "Time", [] of CrystalClick::DateValue) }
    expect_raises(ArgumentError) { CrystalClick::WideTupleLeafColumn.new("empty", [] of CrystalClick::DateValue) }

    widened : CrystalClick::WideTupleLeafColumn::Buffer = [] of CrystalClick::Date32Value
    expect_raises(ArgumentError) { CrystalClick::WideTupleLeafColumn.new("empty", widened) }
  end

  it "retains per-row scaled metadata and rejects a mismatched precision" do
    values = [CrystalClick::DateTime64Value.new(1_i64, 3), CrystalClick::DateTime64Value.new(-2_i64, 3)]
    column = CrystalClick::WideTupleLeafColumn.new("ticks", "DateTime64(3)", values)
    column.values_as(CrystalClick::DateTime64Value).map(&.precision).should eq([3_u8, 3_u8])
    expect_raises(ArgumentError) do
      CrystalClick::WideTupleLeafColumn.new("ticks", "DateTime64(3)", [CrystalClick::DateTime64Value.new(1_i64, 4)])
    end
    times = CrystalClick::WideTupleLeafColumn.new("times", "Time64(9)", [CrystalClick::Time64Value.new(-8_i64, 9)])
    times.owned_copy.type_name.should eq("Time64(9)")
    times.owned_copy.value_at(0, CrystalClick::Time64Value).should eq(CrystalClick::Time64Value.new(-8_i64, 9))
  end

  it "stores all unscaled temporal wrappers only with exact declaration metadata" do
    date = CrystalClick::WideTupleLeafColumn.new("d", "Date", [CrystalClick::DateValue.new(2_u16)])
    date32 = CrystalClick::WideTupleLeafColumn.new("d32", "Date32", [CrystalClick::Date32Value.new(-1_i32)])
    datetime = CrystalClick::WideTupleLeafColumn.new("dt", "DateTime", [CrystalClick::DateTimeValue.new(3_u32)])
    time = CrystalClick::WideTupleLeafColumn.new("t", "Time", [CrystalClick::TimeValue.new(-4_i32)])
    date.value_at(0, CrystalClick::DateValue).raw.should eq(2_u16)
    date32.value_at(0, CrystalClick::Date32Value).raw.should eq(-1_i32)
    datetime.value_at(0, CrystalClick::DateTimeValue).raw.should eq(3_u32)
    time.value_at(0, CrystalClick::TimeValue).raw.should eq(-4_i32)
    [date, date32, datetime, time].each { |column| column.owned_copy.type_name.should eq(column.type_name) }

    expect_raises(ArgumentError) { CrystalClick::WideTupleLeafColumn.new("d", "Date", [CrystalClick::Date32Value.new(2_i32)]) }
    expect_raises(ArgumentError) { CrystalClick::WideTupleLeafColumn.new("d32", "Date32", [CrystalClick::DateValue.new(2_u16)]) }
    expect_raises(ArgumentError) { CrystalClick::WideTupleLeafColumn.new("dt", "DateTime", [CrystalClick::TimeValue.new(2_i32)]) }
    expect_raises(ArgumentError) { CrystalClick::WideTupleLeafColumn.new("t", "Time", [CrystalClick::DateTimeValue.new(2_u32)]) }
  end
end

describe CrystalClick::WideTupleTypePlan do
  it "admits the complete canonical temporal family and rejects lexical parameter aliases" do
    ["Date", "Date32", "DateTime", "Time"].each do |type_name|
      CrystalClick::WideTupleTypePlan.for_type("Tuple(value #{type_name})").should_not be_nil
    end
    (0..9).each do |precision|
      ["DateTime64", "Time64"].each do |name|
        CrystalClick::WideTupleTypePlan.for_type("Tuple(value #{name}(#{precision}))").should_not be_nil
      end
    end

    [
      "Tuple(value Date())",
      "Tuple(value DateTime64( 3 ))",
      "Tuple(value DateTime64 (3))",
      "Tuple(value DateTime64(03))",
      "Tuple(value DateTime64(10))",
      "Tuple(value DateTime64(3, 'UTC'))",
      "Tuple(value Time64( 9 ))",
      "Tuple(value Time64(9 ))",
      "Tuple(value Time64(10))",
      "Tuple(value DateTime('UTC'))",
    ].each do |type_name|
      CrystalClick::WideTupleTypePlan.for_type(type_name).should be_nil
    end
    long_parameter = "x" * 4_100
    CrystalClick::WideTupleTypePlan.for_type("Tuple(value DateTime64(#{long_parameter}))").should be_nil
  end

  it "charges scaled rows by the actual owned wrapper size, not the eight-byte stream width" do
    sizeof(CrystalClick::DateTime64Value).should eq(16)
    sizeof(CrystalClick::Time64Value).should eq(16)
    plan = CrystalClick::WideTupleTypePlan.for_type("Tuple(value DateTime64(3))").not_nil!
    plan.stream_width("payload", "payload%2Evalue").should eq(8)
    plan.materialization_charge(1_u64, 0_u64).should eq(
      CrystalClick::WideTupleTypePlan::RESULT_CONTAINER_ACCOUNTING_BYTES +
      CrystalClick::WideTupleTypePlan::FIELD_CONTAINER_ACCOUNTING_BYTES +
      CrystalClick::WideTupleTypePlan::RESULT_ROW_ACCOUNTING_BYTES +
      sizeof(CrystalClick::DateTime64Value).to_u64
    )
    plan.materialization_charge(UInt64::MAX, 0_u64).should be_nil
    plan.materialization_charge(0_u64, UInt64::MAX).should be_nil
  end
end
