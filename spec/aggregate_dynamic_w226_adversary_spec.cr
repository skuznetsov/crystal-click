require "./spec_helper"
require "file_utils"

private def w226a_sum_type : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.aggregate_function(
    "sum",
    CrystalClick::BinaryDataType.primitive("UInt8"),
  )
end

private def w226a_u64_bytes(value : UInt64) : Bytes
  Bytes.new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w226a_dynamic_value(
  dynamic : CrystalClick::BinaryDataType,
  actual : CrystalClick::BinaryValue,
) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.dynamic(dynamic, actual)
end

private def w226a_join(parts : Array(Bytes)) : Bytes
  size = parts.sum(&.size)
  result = Bytes.new(size)
  offset = 0
  parts.each do |part|
    part.size.times do |index|
      result[offset + index] = part[index]
    end
    offset += part.size
  end
  result
end

describe "W226 generic Dynamic AggregateFunction adversarial controls" do
  it "preserves nominal Count versus Sum through generic Dynamic value envelopes" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    count = CrystalClick::BinaryDataType.aggregate_count
    sum = w226a_sum_type
    count_value = w226a_dynamic_value(
      dynamic,
      CrystalClick::BinaryValue.aggregate_count_state(count, UInt64::MAX),
    )
    sum_value = w226a_dynamic_value(
      dynamic,
      CrystalClick::BinaryValue.aggregate_function_state(sum, w226a_u64_bytes(256_u64)),
    )

    {count_value, sum_value}.each do |value|
      wire = CrystalClick::BinaryValueCodec.encode(value)
      restored = CrystalClick::BinaryValueCodec.decode(wire)
      restored.type.should eq(dynamic)
      restored.child_count.should eq(1)
      restored.child_at(0).type.should eq(value.child_at(0).type)
      CrystalClick::BinaryValueCodec.encode(restored).should eq(wire)
    end

    restored_count = CrystalClick::BinaryValueCodec.decode(CrystalClick::BinaryValueCodec.encode(count_value))
      .child_at(0)
    restored_count.count_state.should eq(UInt64::MAX)
    expect_raises(ArgumentError) { restored_count.aggregate_function_state_bytes }

    restored_sum = CrystalClick::BinaryValueCodec.decode(CrystalClick::BinaryValueCodec.encode(sum_value))
      .child_at(0)
    restored_sum.type.should eq(sum)
    restored_sum.aggregate_function_state_bytes.should eq(w226a_u64_bytes(256_u64))
    expect_raises(ArgumentError) { restored_sum.count_state }
  end

  it "keeps the shared-child default closed, including a nested runtime Dynamic actual" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    count = CrystalClick::BinaryDataType.aggregate_count
    actual = CrystalClick::BinaryValue.aggregate_count_state(count, 1_u64)
    direct = w226a_dynamic_value(dynamic, actual)

    direct_budget = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
      true,
    )
    expect_raises(CrystalClick::UnsupportedFormatError, "AggregateFunction") do
      CrystalClick::BinaryValueCodec.encode_dynamic_bulk_child(direct, direct_budget, 1)
    end

    tuple = CrystalClick::BinaryDataType.tuple(
      [dynamic, CrystalClick::BinaryDataType.primitive("UInt8")] of CrystalClick::BinaryDataType,
    )
    hidden = CrystalClick::BinaryValue.tuple(
      tuple,
      [direct, CrystalClick::BinaryValue.fixed(CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[7_u8])] of CrystalClick::BinaryValue,
    )
    hidden_budget = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
      true,
    )
    expect_raises(CrystalClick::UnsupportedFormatError, "AggregateFunction") do
      CrystalClick::BinaryValueCodec.encode_dynamic_bulk_child(hidden, hidden_budget, 1)
    end

    borrowed_budget = CrystalClick::BinaryCodecBudget.new(
      CrystalClick::BinaryCodecLimits.default,
      true,
    )
    expect_raises(CrystalClick::UnsupportedFormatError, "Dynamic") do
      CrystalClick::BinaryValueCodec.encode_borrowed(direct, borrowed_budget)
    end
  end

  it "rejects trailing scalar bytes and preserves cumulative Dynamic value budgets" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    sum = w226a_sum_type
    value = w226a_dynamic_value(
      dynamic,
      CrystalClick::BinaryValue.aggregate_function_state(sum, w226a_u64_bytes(7_u64)),
    )
    wire = CrystalClick::BinaryValueCodec.encode(value)
    trailing = w226a_join([wire, Bytes[0xff_u8]] of Bytes)
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(trailing)
    end

    limits = CrystalClick::BinaryCodecLimits.new(
      max_depth: 16,
      max_nodes: 1,
      max_elements: 16,
      max_bytes: 1024,
    )
    expect_raises(CrystalClick::UnsupportedFormatError, "node limit") do
      CrystalClick::BinaryValueCodec.encode(value, limits)
    end
    expect_raises(CrystalClick::CorruptPartError, "node limit") do
      CrystalClick::BinaryValueCodec.decode(wire, limits)
    end
  end

  it "admits an exact retained Dynamic AggregateFunction owner budget atomically" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    count = CrystalClick::BinaryDataType.aggregate_count
    value = w226a_dynamic_value(
      dynamic,
      CrystalClick::BinaryValue.aggregate_count_state(count, UInt64::MAX),
    )
    values = [value] of CrystalClick::BinaryValue

    probe = CrystalClick::ObjectValuesMaterializationBudget.new(logical_limit: UInt64::MAX)
    probe.reserve_binary_values_base(1_u64)
    probe.charge_binary_values(values)
    exact_bytes = probe.retained_logical_bytes
    exact_bytes.should be > 0_u64

    exact = CrystalClick::ObjectValuesMaterializationBudget.new(logical_limit: exact_bytes)
    exact.reserve_binary_values_base(1_u64)
    exact.charge_binary_values(values)
    exact.retained_logical_bytes.should eq(exact_bytes)

    one_short = CrystalClick::ObjectValuesMaterializationBudget.new(logical_limit: exact_bytes - 1_u64)
    one_short.reserve_binary_values_base(1_u64)
    before = {
      one_short.retained_logical_bytes,
      one_short.string_payload_bytes,
      one_short.tuple_cells,
      one_short.node_count,
      one_short.element_count,
    }
    expect_raises(CrystalClick::BoundsError) { one_short.charge_binary_values(values) }
    {
      one_short.retained_logical_bytes,
      one_short.string_payload_bytes,
      one_short.tuple_cells,
      one_short.node_count,
      one_short.element_count,
    }.should eq(before)
  end

  it "does not retain a JSON runtime Array(Dynamic) selecting AggregateFunction" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    array_dynamic = CrystalClick::BinaryDataType.array(dynamic)
    count = CrystalClick::BinaryDataType.aggregate_count
    selected = w226a_dynamic_value(
      dynamic,
      CrystalClick::BinaryValue.aggregate_count_state(count, 1_u64),
    )
    array = CrystalClick::BinaryValue.array(
      array_dynamic,
      [selected] of CrystalClick::BinaryValue,
    )
    json = CrystalClick::BinaryDataType.json

    expect_raises(ArgumentError, "JSON Dynamic actual type is outside the admitted runtime profile") do
      CrystalClick::BinaryJsonRow.new(
        json,
        [{"values", array}] of Tuple(String, CrystalClick::BinaryValue),
      )
    end
    selected.type.should eq(dynamic)
    selected.child_at(0).type.should eq(count)
    selected.child_at(0).count_state.should eq(1_u64)
  end

  it "rejects a corrupt compressed Dynamic data stream before publishing a typed callback" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    count = CrystalClick::BinaryDataType.aggregate_count
    count_value = ->(value : UInt64) {
      w226a_dynamic_value(dynamic, CrystalClick::BinaryValue.aggregate_count_state(count, value))
    }
    rows = [
      count_value.call(1_u64),
      count_value.call(2_u64),
      count_value.call(3_u64),
      count_value.call(4_u64),
      count_value.call(5_u64),
    ] of CrystalClick::BinaryValue
    marks = [rows[0, 2], rows[2, 2], rows[4, 1]]

    parent = File.tempname("crystal-click-w226-dynamic-corrupt-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
        part,
        "pk",
        Slice[11_u64, 22_u64, 33_u64, 44_u64, 55_u64],
        "payload",
        dynamic,
        {"root" => CrystalClick::DynamicStructure.new([count] of CrystalClick::BinaryDataType)},
        marks,
        rows_per_mark: 2,
      ).should eq(part)

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
      prepared = CrystalClick::BinaryDynamicBulkPlan.new(
        dynamic,
        {"root" => CrystalClick::DynamicStructure.new([count] of CrystalClick::BinaryDataType)},
      )
      physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(prepared, "payload")
      data_path = File.join(part, physical.data_file_for("root.arm.0.data", true))
      data = File.read(data_path).to_slice.dup
      data.empty?.should be_false
      # The on-disk lane is a compressed block; this corrupts its first frame
      # byte and exercises transport validation before a selected batch can
      # be published. It is not a raw Count-state mutation.
      data[0] = 0x80_u8
      File.write(data_path, data)

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
