require "./spec_helper"
require "file_utils"

private def w225a_u64_bytes(value : UInt64) : Bytes
  Bytes.new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w225a_sum_type : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.aggregate_function(
    "sum",
    CrystalClick::BinaryDataType.primitive("UInt8")
  )
end

private def w225a_state(type : CrystalClick::BinaryDataType, value : UInt64) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.aggregate_function_state(type, w225a_u64_bytes(value))
end

private def w225a_variant(
  type : CrystalClick::BinaryDataType,
  alternative : CrystalClick::BinaryDataType,
  value : CrystalClick::BinaryValue,
) : CrystalClick::BinaryValue
  index = type.children.index { |child| child.name == alternative.name } ||
          raise ArgumentError.new("W225 adversary alternative is not in the canonical roster")
  CrystalClick::BinaryValue.variant(type, index.to_u8, value)
end

private def w225a_type : CrystalClick::BinaryDataType
  sum = w225a_sum_type
  string = CrystalClick::BinaryDataType.primitive("String")
  CrystalClick::BinaryDataType.variant([
    CrystalClick::BinaryDataType.array(sum), string,
  ] of CrystalClick::BinaryDataType)
end

private def w225a_rows(type : CrystalClick::BinaryDataType) : Array(CrystalClick::BinaryValue)
  sum = w225a_sum_type
  array = type.child_at(type.children.index { |child| child.tag == CrystalClick::BinaryDataType::TAG_ARRAY }.not_nil!)
  string = CrystalClick::BinaryDataType.primitive("String")
  [
    w225a_variant(type, array, CrystalClick::BinaryValue.array(array, [w225a_state(sum, 1_u64), w225a_state(sum, 7_u64)])),
    w225a_variant(type, string, CrystalClick::BinaryValue.string("xy")),
    w225a_variant(type, array, CrystalClick::BinaryValue.array(array, [] of CrystalClick::BinaryValue)),
    CrystalClick::BinaryValue.variant_null(type),
    w225a_variant(type, string, CrystalClick::BinaryValue.string("z")),
  ] of CrystalClick::BinaryValue
end

private def w225a_root_unused_sum_type : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.variant([
    CrystalClick::BinaryDataType.aggregate_count,
    w225a_sum_type,
    CrystalClick::BinaryDataType.primitive("String"),
  ] of CrystalClick::BinaryDataType)
end

private def w225a_root_unused_sum_rows(type : CrystalClick::BinaryDataType) : Array(CrystalClick::BinaryValue)
  count = CrystalClick::BinaryDataType.aggregate_count
  string = CrystalClick::BinaryDataType.primitive("String")
  [
    w225a_variant(type, count, CrystalClick::BinaryValue.aggregate_count_state(count, 1_u64)),
    w225a_variant(type, string, CrystalClick::BinaryValue.string("left")),
    CrystalClick::BinaryValue.variant_null(type),
    CrystalClick::BinaryValue.variant_null(type),
    w225a_variant(type, string, CrystalClick::BinaryValue.string("right")),
  ] of CrystalClick::BinaryValue
end

private def w225a_marks(rows : Array(CrystalClick::BinaryValue)) : Array(Array(CrystalClick::BinaryValue))
  marks = [] of Array(CrystalClick::BinaryValue)
  offset = 0
  [2, 2, 1].each do |size|
    mark = Array(CrystalClick::BinaryValue).new(size)
    size.times { |index| mark << rows[offset + index] }
    marks << mark
    offset += size
  end
  marks
end

private def w225a_signature(value : CrystalClick::BinaryValue) : String
  type = value.type
  return "#{type.name}=NULL" if value.is_null?

  if type.aggregate_count_type
    return "#{type.name}:count=#{value.count_state}"
  elsif type.tag == CrystalClick::BinaryDataType::TAG_AGGREGATE_FUNCTION
    return "#{type.name}:#{value.aggregate_function_state_bytes.to_a.join(",")}"
  elsif type.tag == CrystalClick::BinaryDataType::TAG_VARIANT
    index = value.variant_index? || raise ArgumentError.new("Variant value has no selected arm")
    child = value.variant_child? || raise ArgumentError.new("Variant value has no child")
    return "#{type.name}<#{type.child_at(index).name}=#{w225a_signature(child)}>"
  elsif type.tag == CrystalClick::BinaryDataType::TAG_STRING
    return "#{type.name}:#{value.as_string}"
  end

  "#{type.name}[#{value.elements.map { |child| w225a_signature(child) }.join(";")}]"
end

private def w225a_write_part(
  destination : String,
  type : CrystalClick::BinaryDataType,
  rows : Array(CrystalClick::BinaryValue),
) : String
  CrystalClick::WidePartWriter.write_uint64_and_aggregate_function_part(
    destination,
    "pk",
    Slice[11_u64, 22_u64, 33_u64, 44_u64, 55_u64],
    "v",
    type,
    w225a_marks(rows),
    rows_per_mark: 2
  )
end

private def w225a_offline_table(
  source : String,
  part : String,
) : CrystalClick::OfflineTable
  info = CrystalClick::MergeTreePartInfo.parse("all_1_1_0").not_nil!
  candidate = CrystalClick::OfflinePartCandidate.new("all_1_1_0", part, info, 5_u64)
  CrystalClick::OfflineTable.new(
    "w225_events",
    "w225-variant-adversary-fixture",
    "MergeTree",
    [
      CrystalClick::OfflineColumn.new("pk", "UInt64"),
      CrystalClick::OfflineColumn.new("v", source),
    ] of CrystalClick::OfflineColumn,
    [candidate] of CrystalClick::OfflinePartCandidate
  )
end

private def w225a_parent(&)
  parent = File.tempname("crystal-click-w225-variant-adversary-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe "W225 AggregateFunction Variant adversarial controls" do
  it "retains the all-NULL mark and globally unused AggregateFunction arm on the full schedule" do
    type = w225a_root_unused_sum_type
    rows = w225a_root_unused_sum_rows(type)
    streams = CrystalClick::BinaryBulkCodec.encode(type, w225a_marks(rows))

    count_type = CrystalClick::BinaryDataType.aggregate_count
    sum_type = w225a_sum_type
    string_type = CrystalClick::BinaryDataType.primitive("String")
    count_index = type.children.index { |child| child.name == count_type.name }.not_nil!
    sum_index = type.children.index { |child| child.name == sum_type.name }.not_nil!
    string_index = type.children.index { |child| child.name == string_type.name }.not_nil!

    discriminators = streams.stream("root.discriminators")
    discriminators.offsets.should eq([0_u64, 2_u64, 4_u64, 5_u64])
    discriminators.bytes.should eq(Bytes[
      count_index.to_u8,
      string_index.to_u8,
      0xff_u8,
      0xff_u8,
      string_index.to_u8,
    ])

    unused_sum = streams.stream("root.arm.#{sum_index}.data")
    unused_sum.bytes.should be_empty
    unused_sum.offsets.should eq([0_u64, 0_u64, 0_u64, 0_u64])
    streams.roles.should contain("root.arm.#{count_index}.data")
    streams.roles.should contain("root.arm.#{sum_index}.data")
    streams.roles.should contain("root.arm.#{string_index}.data")
  end

  it "preserves an empty selected-arm child domain without erasing parent mark coordinates" do
    element_type = w225a_root_unused_sum_type
    array_type = CrystalClick::BinaryDataType.array(element_type)
    rows = [
      CrystalClick::BinaryValue.array(array_type, [
        w225a_variant(element_type, CrystalClick::BinaryDataType.aggregate_count,
          CrystalClick::BinaryValue.aggregate_count_state(CrystalClick::BinaryDataType.aggregate_count, 127_u64)),
        w225a_variant(element_type, w225a_sum_type, w225a_state(w225a_sum_type, 256_u64)),
      ]),
      CrystalClick::BinaryValue.array(array_type, [
        w225a_variant(element_type, w225a_sum_type, w225a_state(w225a_sum_type, 7_u64)),
      ]),
      CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(array_type, [] of CrystalClick::BinaryValue),
      CrystalClick::BinaryValue.array(array_type, [CrystalClick::BinaryValue.variant_null(element_type)]),
    ] of CrystalClick::BinaryValue

    streams = CrystalClick::BinaryBulkCodec.encode(array_type, w225a_marks(rows))
    streams.stream("root.sizes").offsets.should eq([0_u64, 16_u64, 32_u64, 40_u64])
    streams.stream("root.elements.discriminators").offsets.should eq([0_u64, 3_u64, 3_u64, 4_u64])
    streams.stream("root.elements.discriminators").bytes.size.should eq(4)

    selected = CrystalClick::BinaryBulkCodec.decode(array_type, streams, [2_u64, 2_u64, 1_u64])
    selected.map(&.size).should eq([2, 2, 1])
    selected[1].map(&.element_count).should eq([0, 0])
    selected[2][0].element_at(0).is_null?.should be_true
  end

  it "charges sparse selected AggregateFunction arms against exact and one-short owned-value budgets" do
    type = w225a_type
    rows = w225a_rows(type)
    expected = rows.map { |value| w225a_signature(value) }

    w225a_parent do |parent|
      part = File.join(parent, "all_1_1_0")
      w225a_write_part(part, type, rows)
      table = w225a_offline_table(type.name, part)

      exact = table["v"].values(max_rows: 5_u64, max_string_bytes: 3_u64, max_tuple_cells: 6_u64)
      exact.map { |value| w225a_signature(value.as(CrystalClick::BinaryValue)) }.should eq(expected)
      expect_raises(CrystalClick::BoundsError) do
        table["v"].values(max_rows: 5_u64, max_string_bytes: 3_u64, max_tuple_cells: 5_u64)
      end
      expect_raises(CrystalClick::BoundsError) do
        table["v"].values(max_rows: 5_u64, max_string_bytes: 2_u64, max_tuple_cells: 6_u64)
      end

      selected_array = exact[0].as(CrystalClick::BinaryValue).variant_child? ||
                       raise ArgumentError.new("W225 selected array arm disappeared")
      selected_array.element_count.should eq(2)
      selected_array.element_at(0).aggregate_function_state_bytes.should eq(w225a_u64_bytes(1_u64))
      selected_array.element_at(1).aggregate_function_state_bytes.should eq(w225a_u64_bytes(7_u64))

      detached = selected_array.element_at(0).aggregate_function_state_bytes
      detached.fill(0xff_u8)
      w225a_signature(exact[0].as(CrystalClick::BinaryValue)).should eq(expected[0])

      plan = CrystalClick::BinaryBulkPhysicalPlan.new(type, "v")
      state_role = type.children.index { |child| child.tag == CrystalClick::BinaryDataType::TAG_ARRAY }.not_nil!
      data_path = File.join(part, plan.data_file_for("root.arm.#{state_role}.elements.data", true))
      File.write(data_path, Bytes[0_u8].to_slice)
      exact.map { |value| w225a_signature(value.as(CrystalClick::BinaryValue)) }.should eq(expected)
    end
  end

  it "rejects wrong nominal and malformed lanes before any typed callback" do
    sum = w225a_sum_type
    overflow = CrystalClick::BinaryDataType.aggregate_function(
      "sumWithOverflow",
      CrystalClick::BinaryDataType.primitive("UInt8")
    )
    rows = [1_u64, 7_u64, 255_u64, 256_u64, 17_u64].map { |value| w225a_state(sum, value) }

    w225a_parent do |parent|
      part = File.join(parent, "all_1_1_0")
      w225a_write_part(part, sum, rows)

      wrong_nominal = w225a_offline_table(overflow.name, part)
      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        wrong_nominal.scan_typed(["v"]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)

      valid_reader = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "v"])
      plan = CrystalClick::BinaryBulkPhysicalPlan.new(sum, "v")
      path = File.join(part, plan.data_file_for("root.data", true))
      bytes = File.read(path).to_slice.dup
      bytes.empty?.should be_false
      bytes[0] = bytes[0] ^ 0xff_u8
      File.write(path, bytes)

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        valid_reader.scan_typed(batch_rows: 2) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    end
  end

  it "rejects a Variant nominal mismatch and corrupt selected state arm before callbacks" do
    type = w225a_root_unused_sum_type
    count = CrystalClick::BinaryDataType.aggregate_count
    sum = w225a_sum_type
    string = CrystalClick::BinaryDataType.primitive("String")
    rows = [
      w225a_variant(type, count, CrystalClick::BinaryValue.aggregate_count_state(count, 1_u64)),
      w225a_variant(type, sum, w225a_state(sum, 256_u64)),
      w225a_variant(type, string, CrystalClick::BinaryValue.string("middle")),
      CrystalClick::BinaryValue.variant_null(type),
      w225a_variant(type, count, CrystalClick::BinaryValue.aggregate_count_state(count, UInt64::MAX)),
    ] of CrystalClick::BinaryValue
    wrong_sum = CrystalClick::BinaryDataType.aggregate_function(
      "sumWithOverflow",
      CrystalClick::BinaryDataType.primitive("UInt8")
    )
    wrong_type = CrystalClick::BinaryDataType.variant([
      count, wrong_sum, string,
    ] of CrystalClick::BinaryDataType)

    w225a_parent do |parent|
      part = File.join(parent, "all_1_1_0")
      w225a_write_part(part, type, rows)

      wrong_nominal = w225a_offline_table(wrong_type.name, part)
      callbacks = 0
      expect_raises(CrystalClick::UnsupportedFormatError) do
        wrong_nominal.scan_typed(["v"]) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)

      valid_reader = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "v"])
      physical = CrystalClick::BinaryBulkPhysicalPlan.new(type, "v")
      sum_index = type.children.index { |child| child.name == sum.name }.not_nil!
      path = File.join(part, physical.data_file_for("root.arm.#{sum_index}.data", true))
      bytes = File.read(path).to_slice.dup
      bytes.empty?.should be_false
      bytes[0] = bytes[0] ^ 0xff_u8
      File.write(path, bytes)

      callbacks = 0
      expect_raises(CrystalClick::CorruptPartError) do
        valid_reader.scan_typed(batch_rows: 2) { |_batch| callbacks += 1 }
      end
      callbacks.should eq(0)
    end
  end
end
