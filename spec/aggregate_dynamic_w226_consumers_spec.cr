require "./spec_helper"
require "file_utils"
require "../scripts/support/dynamic_owned_values_w220"

private alias W226DynamicFixture = NamedTuple(
  type: CrystalClick::BinaryDataType,
  structures: Hash(String, CrystalClick::DynamicStructure),
  marks: Array(Array(CrystalClick::BinaryValue)),
)

private def w226_sum_type : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.aggregate_function(
    "sum",
    CrystalClick::BinaryDataType.primitive("UInt8"),
  )
end

private def w226_u64_bytes(value : UInt64) : Bytes
  Bytes.new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
end

private def w226_count_value(type : CrystalClick::BinaryDataType, value : UInt64) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.aggregate_count_state(type, value)
end

private def w226_sum_value(type : CrystalClick::BinaryDataType, value : UInt64) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.aggregate_function_state(type, w226_u64_bytes(value))
end

private def w226_marks(rows : Array(CrystalClick::BinaryValue)) : Array(Array(CrystalClick::BinaryValue))
  [rows[0, 2], rows[2, 2], rows[4, 1]]
end

private def w226_dynamic_fixture(case_id : String) : W226DynamicFixture
  dynamic = CrystalClick::BinaryDataType.dynamic(max_types: case_id == "all_shared" ? 0 : 1)
  count = CrystalClick::BinaryDataType.aggregate_count
  sum = w226_sum_type
  array_sum = CrystalClick::BinaryDataType.array(sum)
  dynamic_value = ->(child : CrystalClick::BinaryValue?) {
    CrystalClick::BinaryValue.dynamic(dynamic, child)
  }
  dynamic_count = ->(value : UInt64) { dynamic_value.call(w226_count_value(count, value)) }
  dynamic_sum = ->(value : UInt64) { dynamic_value.call(w226_sum_value(sum, value)) }
  empty_dynamic = -> { dynamic_value.call(nil) }
  array_sum_value = ->(values : Array(CrystalClick::BinaryValue)) {
    dynamic_value.call(CrystalClick::BinaryValue.array(array_sum, values))
  }

  case case_id
  when "known_count_shared_sum"
    rows = [
      dynamic_count.call(1_u64),
      dynamic_sum.call(256_u64),
      empty_dynamic.call,
      dynamic_count.call(UInt64::MAX),
      dynamic_count.call(0_u64),
    ] of CrystalClick::BinaryValue
    {
      type:       dynamic,
      structures: {"root" => CrystalClick::DynamicStructure.new([count] of CrystalClick::BinaryDataType)},
      marks:      w226_marks(rows),
    }
  when "all_shared"
    rows = [
      dynamic_count.call(1_u64),
      dynamic_sum.call(256_u64),
      empty_dynamic.call,
      dynamic_count.call(UInt64::MAX),
      dynamic_count.call(0_u64),
    ] of CrystalClick::BinaryValue
    {
      type:       dynamic,
      structures: {"root" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)},
      marks:      w226_marks(rows),
    }
  when "actual_array_sum"
    rows = [
      array_sum_value.call([] of CrystalClick::BinaryValue),
      dynamic_count.call(256_u64),
      empty_dynamic.call,
      array_sum_value.call([w226_sum_value(sum, 7_u64), w226_sum_value(sum, 17_u64)] of CrystalClick::BinaryValue),
      array_sum_value.call([w226_sum_value(sum, 0_u64)] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue
    {
      type:       dynamic,
      structures: {"root" => CrystalClick::DynamicStructure.new([array_sum] of CrystalClick::BinaryDataType)},
      marks:      w226_marks(rows),
    }
  when "outer_array_dynamic"
    outer_type = CrystalClick::BinaryDataType.array(dynamic)
    outer_row = ->(values : Array(CrystalClick::BinaryValue)) {
      CrystalClick::BinaryValue.array(outer_type, values)
    }
    rows = [
      outer_row.call([] of CrystalClick::BinaryValue),
      outer_row.call([] of CrystalClick::BinaryValue),
      outer_row.call([
        dynamic_count.call(1_u64),
        dynamic_sum.call(256_u64),
        empty_dynamic.call,
      ] of CrystalClick::BinaryValue),
      outer_row.call([dynamic_count.call(256_u64)] of CrystalClick::BinaryValue),
      outer_row.call([dynamic_sum.call(0_u64), dynamic_count.call(UInt64::MAX)] of CrystalClick::BinaryValue),
    ] of CrystalClick::BinaryValue
    {
      type:       outer_type,
      structures: {
        "root.elements" => CrystalClick::DynamicStructure.new([count] of CrystalClick::BinaryDataType),
      },
      marks: w226_marks(rows),
    }
  else
    raise ArgumentError.new("W226 fixture is outside its exact four-case roster")
  end
end

private def w226_profiles : Array(CrystalClick::BinaryBulkProfile)
  [
    CrystalClick::BinaryBulkProfile.single_stream,
    CrystalClick::BinaryBulkProfile.with_size_stream,
  ] of CrystalClick::BinaryBulkProfile
end

private def w226_expect_marks!(
  actual : Array(Array(CrystalClick::BinaryValue)),
  expected : Array(Array(CrystalClick::BinaryValue)),
) : Nil
  actual.size.should eq(expected.size)
  actual.each_with_index do |mark, mark_index|
    mark.size.should eq(expected[mark_index].size)
    mark.each_with_index do |value, row_index|
      value.type.should eq(expected[mark_index][row_index].type)
      CrystalClick::BinaryValueCodec.encode(value).should eq(
        CrystalClick::BinaryValueCodec.encode(expected[mark_index][row_index])
      )
    end
  end
end

describe "W226 generic Dynamic AggregateFunction consumers" do
  it "round-trips the finite known, shared, Array(Sum), and outer Array(Dynamic) profiles" do
    case_ids = [
      "known_count_shared_sum",
      "all_shared",
      "actual_array_sum",
      "outer_array_dynamic",
    ]

    case_ids.each do |case_id|
      fixture = w226_dynamic_fixture(case_id)
      w226_profiles.each do |profile|
        parent = File.tempname("crystal-click-w226-dynamic-consumer-")
        Dir.mkdir(parent)
        begin
          part = File.join(parent, "all_1_1_0")
          CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
            part,
            "pk",
            Slice[11_u64, 22_u64, 33_u64, 44_u64, 55_u64],
            "payload",
            fixture[:type],
            fixture[:structures],
            fixture[:marks],
            rows_per_mark: 2,
            profile: profile,
          ).should eq(part)

          reader = CrystalClick::DynamicBulkColumnReader.open(part, "payload", fixture[:type])
          reader.ordinary_profile.should eq(profile)
          reader.row_count.should eq(5_u64)
          reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
          w226_expect_marks!(reader.read_marks(0, 3), fixture[:marks])
          w226_expect_marks!(reader.read_marks(1, 1), [fixture[:marks][1]])
          reader.read_marks(3, 0).should eq([] of Array(CrystalClick::BinaryValue))

          table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "payload"])
          observed = Array(Array(CrystalClick::BinaryValue)).new(fixture[:marks].size) do
            [] of CrystalClick::BinaryValue
          end
          callbacks = 0
          table.scan_typed do |batch|
            callbacks += 1
            rows = batch.dynamic_bulk_values_for("payload").to_a
            w226_expect_marks!([rows], [fixture[:marks][batch.mark_index]])
            w226_expect_marks!([batch.binary_bulk_values_for("payload").to_a], [rows])
            observed[batch.mark_index] = rows
          end
          callbacks.should eq(3)
          w226_expect_marks!(observed, fixture[:marks])

          middle = [] of CrystalClick::BinaryValue
          table.scan_typed_window(2_u64, max_rows: 2) do |batch|
            middle.concat(batch.dynamic_bulk_values_for("payload"))
          end
          w226_expect_marks!([middle], [fixture[:marks][1]])

          offline = CrystalClick::DynamicOwnedValuesW220.materialize(
            part,
            "payload",
            fixture[:type],
            5_u64,
            [2_u64, 2_u64, 1_u64],
            fixture[:marks],
            reader.read_marks(0, reader.mark_count),
          )
          offline.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
          w226_expect_marks!(offline.values_by_mark, fixture[:marks])
        ensure
          FileUtils.rm_rf(parent)
        end
      end
    end
  end

  it "does not publish a part when the Dynamic structure site roster is incomplete" do
    dynamic = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    string = CrystalClick::BinaryValue.string("value")
    value = CrystalClick::BinaryValue.dynamic(dynamic, string)
    rows = [value, value, value, value, value] of CrystalClick::BinaryValue
    marks = w226_marks(rows)

    parent = File.tempname("crystal-click-w226-dynamic-invalid-write-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      expect_raises(ArgumentError, "Dynamic structure is missing") do
        CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
          part,
          "pk",
          Slice[11_u64, 22_u64, 33_u64, 44_u64, 55_u64],
          "payload",
          dynamic,
          {"root.unexpected" => CrystalClick::DynamicStructure.new([] of CrystalClick::BinaryDataType)},
          marks,
          rows_per_mark: 2,
        )
      end
      Dir.exists?(part).should be_false
      File.symlink?(part).should be_false
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
