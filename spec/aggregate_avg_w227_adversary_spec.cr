require "./spec_helper"
require "file_utils"

private def w227a_type(argument : String) : CrystalClick::BinaryDataType
  parsed = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(argument).not_nil!
  CrystalClick::BinaryDataType.aggregate_function("avg", parsed)
end

private def w227a_join(prefix : Bytes, suffix : Bytes) : Bytes
  Bytes.new(prefix.size + suffix.size) do |index|
    index < prefix.size ? prefix[index] : suffix[index - prefix.size]
  end
end

describe "W227 Avg independent state-boundary adversaries" do
  it "never exposes a fixed stride for Avg and keeps each width's default exact" do
    {"UInt8" => 8, "Int128" => 16, "Decimal(76, 2)" => 32}.each do |argument, width|
      type = w227a_type(argument)
      plan = CrystalClick::BinaryAggregateFunctionStatePlan.for_type(type)
      plan.minimum_state_bytes.should eq(width + 1)
      plan.default_state_bytes.should eq(Bytes.new(width + 1, 0_u8))
      expect_raises(ArgumentError, "variable") { plan.state_width }
      CrystalClick::BinaryValueCodec.decode_value(type, plan.default_state_bytes)
        .aggregate_function_state_bytes.should eq(plan.default_state_bytes)
    end

    sum = CrystalClick::BinaryDataType.aggregate_function("sum", CrystalClick::BinaryDataType.primitive("UInt8"))
    CrystalClick::BinaryAggregateFunctionStatePlan.for_type(sum).state_width.should eq(8)
  end

  it "delimits every seven-bit count transition without consuming a following scalar" do
    {"UInt8" => 8, "Int128" => 16, "Decimal(76, 2)" => 32}.each do |argument, width|
      type = w227a_type(argument)
      numerator = Bytes.new(width, 0xa5_u8)
      1.upto(9) do |digits|
        # Explicit wire expectations immediately below and at 2^(7*digits).
        before = Bytes.new(digits, 0xff_u8)
        before[digits - 1] = 0x7f_u8
        at = Bytes.new(digits + 1, 0x80_u8)
        at[digits] = 0x01_u8
        {before, at}.each do |denominator|
          raw = w227a_join(numerator, denominator)
          input = w227a_join(raw, Bytes[0x5a_u8])
          context = CrystalClick::BinaryCodecContext.new(CrystalClick::BinaryCodecLimits.default, input)
          restored = CrystalClick::BinaryAggregateFunctionStateCodec.read(type, context)
          restored.should eq(raw)
          context.input_offset.should eq(raw.size)
          context.read_byte.should eq(0x5a_u8)
          context.ensure_consumed
          # Read state ownership is independent from the borrowed input cursor.
          input.fill(0_u8)
          restored.should eq(raw)
        end
      end
    end
  end

  it "rejects hostile denominator endings for all three numerator widths" do
    {"UInt8" => 8, "Int128" => 16, "Decimal(76, 2)" => 32}.each do |argument, width|
      type = w227a_type(argument)
      numerator = Bytes.new(width, 0xff_u8)
      malformed = [
        Bytes[0x80_u8],
        Bytes[0x80_u8, 0_u8],
        Bytes.new(9, 0x80_u8),
        Bytes.new(10, 0x80_u8),
        Bytes.new(10, 0xff_u8),
        Bytes.new(11, 0x80_u8),
      ] of Bytes
      malformed.each do |denominator|
        raw = w227a_join(numerator, denominator)
        expect_raises(ArgumentError) { CrystalClick::BinaryValue.aggregate_function_state(type, raw) }
        expect_raises(CrystalClick::CorruptPartError) { CrystalClick::BinaryValueCodec.decode_value(type, raw) }
      end
    end
  end

  it "delimits nullable present counts and absent states without consuming an adjacent state" do
    {"UInt8" => 8, "Int128" => 16, "Decimal(76, 2)" => 32}.each do |argument, width|
      type = w227a_type("Nullable(#{argument})")
      numerator = Bytes.new(width, 0xa5_u8)
      {Bytes[0x80_u8, 0x01_u8], Bytes[0x80_u8, 0x80_u8, 0x01_u8]}.each do |count|
        present = w227a_join(Bytes[1_u8], w227a_join(numerator, count))
        input = w227a_join(present, Bytes[0_u8, 0x5a_u8])
        context = CrystalClick::BinaryCodecContext.new(CrystalClick::BinaryCodecLimits.default, input)
        restored = CrystalClick::BinaryAggregateFunctionStateCodec.read(type, context)
        restored.should eq(present)
        context.input_offset.should eq(present.size)
        CrystalClick::BinaryAggregateFunctionStateCodec.read(type, context).should eq(Bytes[0_u8])
        context.read_byte.should eq(0x5a_u8)
        context.ensure_consumed
        CrystalClick::BinaryValueCodec.encode_value(
          CrystalClick::BinaryValue.aggregate_function_state(type, present)).should eq(present)
        input.fill(0_u8)
        restored.should eq(present)
      end

      {Bytes[0x80_u8], Bytes[0x80_u8, 0_u8], Bytes.new(10, 0xff_u8)}.each do |count|
        raw = w227a_join(Bytes[1_u8], w227a_join(numerator, count))
        expect_raises(ArgumentError) { CrystalClick::BinaryValue.aggregate_function_state(type, raw) }
        expect_raises(CrystalClick::CorruptPartError) { CrystalClick::BinaryValueCodec.decode_value(type, raw) }
      end
    end
  end

  it "does not open temporal inputs in Sum and preserves its existing Interval route" do
    ["Date", "Date32", "DateTime", "DateTime64(9)", "Time", "Time64(0)"].each do |argument|
      parsed = CrystalClick::BinaryRecursiveDataTypeNameReader.parse_canonical(argument).not_nil!
      CrystalClick::BinaryDataType.aggregate_function("avg", parsed).name.should eq("AggregateFunction(avg, #{parsed.name})")
      expect_raises(ArgumentError) { CrystalClick::BinaryDataType.aggregate_function("sum", parsed) }
    end
    interval = CrystalClick::BinaryDataType.interval(CrystalClick::BinaryIntervalType::Kind::Year)
    sum = CrystalClick::BinaryDataType.aggregate_function("sum", interval)
    CrystalClick::BinaryAggregateFunctionStatePlan.for_type(sum).state_width.should eq(8)
  end

  it "rejects a damaged Avg transport frame before a public typed callback" do
    type = w227a_type("UInt8")
    value = CrystalClick::BinaryValue.aggregate_function_state(type, Bytes.new(9, 0_u8))
    parent = File.tempname("crystal-click-w227-avg-corrupt-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_and_aggregate_function_part(
        part, "pk", Slice[11_u64, 22_u64], "v", type,
        [[value, value] of CrystalClick::BinaryValue], rows_per_mark: 2, frame_bytes: 64)
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "v"])
      physical = CrystalClick::BinaryBulkPhysicalPlan.new(type, "v")
      path = File.join(part, physical.data_file_for("root.data", true))
      frame = File.read(path).to_slice.dup
      frame.empty?.should be_false
      frame[0] ^= 0x01_u8
      File.write(path, frame)
      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table.scan_typed(batch_rows: 2) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
