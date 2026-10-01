require "./spec_helper"

private def w100_temporal_writer_cases : Array(Tuple(String, CrystalClick::WideTupleTemporalType::Buffer, Array(UInt8), Int32))
  cases = [] of Tuple(String, CrystalClick::WideTupleTemporalType::Buffer, Array(UInt8), Int32)
  cases << {"Date", [CrystalClick::DateValue.new(0x1234_u16), CrystalClick::DateValue.new(0_u16)] of CrystalClick::DateValue, [0x34_u8, 0x12_u8, 0_u8, 0_u8], 1}
  cases << {"Date32", [CrystalClick::Date32Value.new(-25567_i32), CrystalClick::Date32Value.new(5_i32)] of CrystalClick::Date32Value, [0x21_u8, 0x9c_u8, 0xff_u8, 0xff_u8, 0x05_u8, 0_u8, 0_u8, 0_u8], 0}
  cases << {"DateTime", [CrystalClick::DateTimeValue.new(0x01020304_u32), CrystalClick::DateTimeValue.new(0_u32)] of CrystalClick::DateTimeValue, [0x04_u8, 0x03_u8, 0x02_u8, 0x01_u8, 0_u8, 0_u8, 0_u8, 0_u8], 1}
  cases << {"Time", [CrystalClick::TimeValue.new(-2_i32), CrystalClick::TimeValue.new(0_i32)] of CrystalClick::TimeValue, [0xfe_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0_u8, 0_u8, 0_u8, 0_u8], 1}
  (0..9).each do |precision|
    cases << {
      "DateTime64(#{precision})",
      [CrystalClick::DateTime64Value.new(-2_i64, precision), CrystalClick::DateTime64Value.new(0_i64, precision)] of CrystalClick::DateTime64Value,
      [0xfe_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8],
      1,
    }
    cases << {
      "Time64(#{precision})",
      [CrystalClick::Time64Value.new(0x0102030405060708_i64, precision), CrystalClick::Time64Value.new(0_i64, precision)] of CrystalClick::Time64Value,
      [0x08_u8, 0x07_u8, 0x06_u8, 0x05_u8, 0x04_u8, 0x03_u8, 0x02_u8, 0x01_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8, 0_u8],
      1,
    }
  end
  cases
end

private def w100_temporal_writer_stage_factory(calls : Array(Int32)) : Proc(String, String)
  ->(parent : String) do
    calls << 1
    stage = File.tempname(".w100-temporal-stage-", nil, dir: parent)
    Dir.mkdir(stage)
    stage
  end
end

private def w100_temporal_writer_string_copy(calls : Array(Int32)) : Proc(CrystalClick::WideTupleLeafColumn, Array(String))
  ->(column : CrystalClick::WideTupleLeafColumn) do
    calls << 1
    column.string_values
  end
end

private def w100_temporal_writer_stream_bytes(part : String, stream : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice).to_a
end

module CrystalClick
  module WidePartWriter
    class TuplePartWriter
      def self.w100_test_validate_staged_part(
        stage : String,
        input : TuplePartWriteInput,
        infrastructure : TuplePartInfrastructure,
      ) : Nil
        validate_staged_part(stage, input, infrastructure)
      end
    end

    def self.w100_test_write_with_stage_factory(
      destination : String,
      key_name : String,
      keys : Slice(UInt64),
      value_name : String,
      type_name : String,
      columns : Array(WideTupleLeafColumn),
      rows_per_mark : Int32,
      stage_factory : Proc(String, String),
      copy_string_values : Proc(WideTupleLeafColumn, Array(String)),
    ) : String
      write_uint64_tuple_pair_with_stage_factory(
        destination, key_name, keys, value_name, type_name, columns, rows_per_mark, stage_factory,
        copy_string_values
      )
    end

    def self.w100_test_validate_tuple_stage(
      stage : String,
      key_name : String,
      keys : Array(UInt64),
      value_name : String,
      type_name : String,
      expected_leaf_buffers : Array(WideTupleLeafColumn::Buffer),
      rows_per_mark : Int32,
    ) : Nil
      type_plan = WideTupleTypePlan.for_type(type_name) || raise "invalid W100 Tuple test type"
      logical_streams = [key_name] + type_plan.physical_streams(value_name)
      mark_count = checked_mark_count(keys.size, rows_per_mark)
      input = TuplePartWriteInput.new(
        File.join(File.dirname(stage), "not-published"),
        File.dirname(stage),
        key_name,
        keys.dup,
        value_name,
        type_plan,
        expected_leaf_buffers,
        logical_streams,
        Array(Int64).new(logical_streams.size, 0_i64),
        Array(UInt64).new(logical_streams.size, 0_u64),
        mark_count,
        rows_per_mark,
        File.read(File.join(stage, "columns.txt")),
        File.read(File.join(stage, "columns_substreams.txt")),
        File.read(File.join(stage, "serialization.json")),
      )
      infrastructure = build_tuple_part_infrastructure(
        ->(parent : String) { create_stage(parent) },
        ->(column : WideTupleLeafColumn) { column.string_values }
      )
      TuplePartWriter.w100_test_validate_staged_part(stage, input, infrastructure)
    end
  end
end

private def w100_assert_temporal_writer_case(
  parent : String,
  leaf_type : String,
  values : CrystalClick::WideTupleTemporalType::Buffer,
  expected_bytes : Array(UInt8),
  expected_defaults : Int32,
) : Nil
  rows = values.size
  type_name = "Tuple(event #{leaf_type})"
  columns = [CrystalClick::WideTupleLeafColumn.new("event", leaf_type, values)] of CrystalClick::WideTupleLeafColumn
  keys = Array(UInt64).new(rows) { |index| index.to_u64 + 1_u64 }
  destination = File.join(parent, "part-#{leaf_type.gsub(/[^A-Za-z0-9]+/, "-")}")
  stage_calls = [] of Int32
  copy_calls = [] of Int32
  factory = w100_temporal_writer_stage_factory(stage_calls)

  CrystalClick::WidePartWriter.w100_test_write_with_stage_factory(
    destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns, 1, factory,
    w100_temporal_writer_string_copy(copy_calls)
  ).should eq(destination)

  stage_calls.should eq([1])
  copy_calls.should be_empty
  File.read(File.join(destination, "columns.txt")).should eq(
    "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{type_name}\n"
  )
  File.read(File.join(destination, "columns_substreams.txt")).should eq(
    "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n1 substreams for column `payload`:\n\tpayload%2Eevent\n"
  )
  w100_temporal_writer_stream_bytes(destination, "payload%2Eevent").should eq(expected_bytes)

  expected_serialization = "{\"columns\":[{\"kind\":\"Default\",\"name\":\"payload\",\"num_defaults\":#{expected_defaults},\"num_rows\":#{rows},\"subcolumns\":[{\"kind\":\"Default\",\"num_defaults\":#{expected_defaults},\"num_rows\":#{rows}}]},{\"kind\":\"Default\",\"name\":\"pk\",\"num_defaults\":0,\"num_rows\":#{rows}}],\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{\"string\":1},\"version\":1}"
  File.read(File.join(destination, "serialization.json")).should eq(expected_serialization)

  part = CrystalClick::WidePart.open_typed(destination, "payload")
  part.row_count.should eq(rows.to_u64)
  part.mark_row_counts.should eq(Array(UInt64).new(rows) { 1_u64 })
  decoded = part.read_tuple_mark_range("payload", 0, part.mark_count)
  decoded.fields.map(&.type_name).should eq([leaf_type])
  decoded.columns[0].type_name.should eq(leaf_type)
  decoded.columns[0].values.should eq(values)
  values.each_with_index do |value, index|
    decoded.columns[0].value_at(index).should eq(value)
  end
  nil
end

describe CrystalClick::WidePartWriter do
  w100_temporal_writer_cases.each do |leaf_type, values, expected_bytes, expected_defaults|
    it "writes exact #{leaf_type} Tuple values through the matching raw LE carrier" do
      parent = File.tempname("crystal-click-wide-writer-temporal-tuple")
      Dir.mkdir(parent)
      begin
        w100_assert_temporal_writer_case(parent, leaf_type, values, expected_bytes, expected_defaults)
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "counts Date32 raw zero as storage default, not the SQL type default" do
    parent = File.tempname("crystal-click-wide-writer-date32-default")
    Dir.mkdir(parent)
    begin
      w100_assert_temporal_writer_case(
        parent, "Date32",
        ([CrystalClick::Date32Value.new(-25567_i32), CrystalClick::Date32Value.new(-25567_i32), CrystalClick::Date32Value.new(0_i32)] of CrystalClick::Date32Value),
        [0x21_u8, 0x9c_u8, 0xff_u8, 0xff_u8, 0x21_u8, 0x9c_u8, 0xff_u8, 0xff_u8, 0_u8, 0_u8, 0_u8, 0_u8],
        1
      )
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "counts an all-zero scaled temporal leaf as fully default" do
    parent = File.tempname("crystal-click-wide-writer-temporal-all-zero")
    Dir.mkdir(parent)
    begin
      w100_assert_temporal_writer_case(
        parent, "DateTime64(3)",
        ([CrystalClick::DateTime64Value.new(0_i64, 3), CrystalClick::DateTime64Value.new(0_i64, 3)] of CrystalClick::DateTime64Value),
        Array(UInt8).new(16, 0_u8),
        2
      )
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects altered expected temporal source buffers for an unchanged canonical stage" do
    parent = File.tempname("crystal-click-wide-writer-temporal-expected-mismatch")
    Dir.mkdir(parent)
    canonical = File.join(parent, "canonical")
    type_name = "Tuple(day Date, day32 Date32, stamp DateTime, stamp64 DateTime64(3), clock Time, clock64 Time64(3))"
    keys = [1_u64, 2_u64]
    columns = [
      CrystalClick::WideTupleLeafColumn.new("day", "Date", [CrystalClick::DateValue.new(12_u16), CrystalClick::DateValue.new(0_u16)] of CrystalClick::DateValue),
      CrystalClick::WideTupleLeafColumn.new("day32", "Date32", [CrystalClick::Date32Value.new(-25567_i32), CrystalClick::Date32Value.new(0_i32)] of CrystalClick::Date32Value),
      CrystalClick::WideTupleLeafColumn.new("stamp", "DateTime", [CrystalClick::DateTimeValue.new(123_u32), CrystalClick::DateTimeValue.new(0_u32)] of CrystalClick::DateTimeValue),
      CrystalClick::WideTupleLeafColumn.new("stamp64", "DateTime64(3)", [CrystalClick::DateTime64Value.new(456_i64, 3), CrystalClick::DateTime64Value.new(0_i64, 3)] of CrystalClick::DateTime64Value),
      CrystalClick::WideTupleLeafColumn.new("clock", "Time", [CrystalClick::TimeValue.new(-7_i32), CrystalClick::TimeValue.new(0_i32)] of CrystalClick::TimeValue),
      CrystalClick::WideTupleLeafColumn.new("clock64", "Time64(3)", [CrystalClick::Time64Value.new(789_i64, 3), CrystalClick::Time64Value.new(0_i64, 3)] of CrystalClick::Time64Value),
    ] of CrystalClick::WideTupleLeafColumn
    stage_calls = [] of Int32
    copy_calls = [] of Int32

    begin
      CrystalClick::WidePartWriter.w100_test_write_with_stage_factory(
        canonical, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns, 2,
        w100_temporal_writer_stage_factory(stage_calls), w100_temporal_writer_string_copy(copy_calls)
      ).should eq(canonical)
      stage_calls.should eq([1])
      copy_calls.should be_empty

      # This canonical on-disk part stays byte-for-byte unchanged throughout:
      # the adversary alters the expected source buffers supplied to the
      # internal staged validator, not the stored stream and not public
      # mid-write cleanup behavior.
      part = CrystalClick::WidePart.open_typed(canonical, "payload")
      part.row_count.should eq(2_u64)
      decoded = part.read_tuple_mark_range("payload", 0, part.mark_count)
      decoded.fields.map(&.type_name).should eq([
        "Date", "Date32", "DateTime", "DateTime64(3)", "Time", "Time64(3)",
      ])
      original_buffers = [] of CrystalClick::WideTupleLeafColumn::Buffer
      columns.each_with_index do |column, index|
        decoded.columns[index].values.should eq(column.values)
        original_buffers << column.values
      end

      # First prove the unchanged canonical part passes with its actual source
      # buffers; only then run the mismatched-expected-input attacks.
      CrystalClick::WidePartWriter.w100_test_validate_tuple_stage(
        canonical, "pk", keys, "payload", type_name, original_buffers, 2
      )

      raw_mismatches = [] of CrystalClick::WideTupleLeafColumn::Buffer
      raw_mismatches << [CrystalClick::DateValue.new(13_u16), CrystalClick::DateValue.new(0_u16)] of CrystalClick::DateValue
      raw_mismatches << [CrystalClick::Date32Value.new(-25566_i32), CrystalClick::Date32Value.new(0_i32)] of CrystalClick::Date32Value
      raw_mismatches << [CrystalClick::DateTimeValue.new(124_u32), CrystalClick::DateTimeValue.new(0_u32)] of CrystalClick::DateTimeValue
      raw_mismatches << [CrystalClick::DateTime64Value.new(457_i64, 3), CrystalClick::DateTime64Value.new(0_i64, 3)] of CrystalClick::DateTime64Value
      raw_mismatches << [CrystalClick::TimeValue.new(-6_i32), CrystalClick::TimeValue.new(0_i32)] of CrystalClick::TimeValue
      raw_mismatches << [CrystalClick::Time64Value.new(790_i64, 3), CrystalClick::Time64Value.new(0_i64, 3)] of CrystalClick::Time64Value

      raw_mismatches.each_with_index do |mismatched_buffer, index|
        expected_buffers = original_buffers.dup
        expected_buffers[index] = mismatched_buffer
        expect_raises(CrystalClick::CorruptPartError, "staged Tuple temporal leaf readback differs") do
          CrystalClick::WidePartWriter.w100_test_validate_tuple_stage(
            canonical, "pk", keys, "payload", type_name, expected_buffers, 2
          )
        end
      end

      precision_mismatches = [] of Tuple(Int32, CrystalClick::WideTupleLeafColumn::Buffer)
      precision_mismatches << {3, [CrystalClick::DateTime64Value.new(456_i64, 4), CrystalClick::DateTime64Value.new(0_i64, 4)] of CrystalClick::DateTime64Value}
      precision_mismatches << {5, [CrystalClick::Time64Value.new(789_i64, 4), CrystalClick::Time64Value.new(0_i64, 4)] of CrystalClick::Time64Value}
      precision_mismatches.each do |index, mismatched_buffer|
        expected_buffers = original_buffers.dup
        expected_buffers[index] = mismatched_buffer
        expect_raises(CrystalClick::CorruptPartError, "staged Tuple temporal leaf readback differs") do
          CrystalClick::WidePartWriter.w100_test_validate_tuple_stage(
            canonical, "pk", keys, "payload", type_name, expected_buffers, 2
          )
        end
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "composes temporal leaves with existing primitive, Bool, String and identifier leaves" do
    parent = File.tempname("crystal-click-wide-writer-temporal-composition")
    Dir.mkdir(parent)
    factory_calls = [] of Int32
    copy_calls = [] of Int32
    destination = File.join(parent, "composed")
    keys = [1_u64, 2_u64]
    type_name = "Tuple(at DateTime64(3), day Date32, count UInt64, active Bool, id UUID, label String)"
    columns = [
      CrystalClick::WideTupleLeafColumn.new("at", "DateTime64(3)", [CrystalClick::DateTime64Value.new(-1_i64, 3), CrystalClick::DateTime64Value.new(0_i64, 3)] of CrystalClick::DateTime64Value),
      CrystalClick::WideTupleLeafColumn.new("day", "Date32", [CrystalClick::Date32Value.new(-25567_i32), CrystalClick::Date32Value.new(0_i32)] of CrystalClick::Date32Value),
      CrystalClick::WideTupleLeafColumn.new("count", [3_u64, 4_u64]),
      CrystalClick::WideTupleLeafColumn.new("active", [true, false]),
      CrystalClick::WideTupleLeafColumn.new("id", [CrystalClick::UUIDValue.new(1_u64, 2_u64), CrystalClick::UUIDValue.new(3_u64, 4_u64)]),
      CrystalClick::WideTupleLeafColumn.new("label", ["now", ""] of String),
    ] of CrystalClick::WideTupleLeafColumn
    begin
      CrystalClick::WidePartWriter.w100_test_write_with_stage_factory(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns, 1,
        w100_temporal_writer_stage_factory(factory_calls), w100_temporal_writer_string_copy(copy_calls)
      ).should eq(destination)

      factory_calls.should eq([1])
      copy_calls.should eq([1])
      part = CrystalClick::WidePart.open_typed(destination, "payload")
      row = part.read_tuple_mark_range("payload", 0, part.mark_count).row(0)
      row.value_as("at", CrystalClick::DateTime64Value).should eq(CrystalClick::DateTime64Value.new(-1_i64, 3))
      row.value_as("day", CrystalClick::Date32Value).should eq(CrystalClick::Date32Value.new(-25567_i32))
      row.value_as("count", UInt64).should eq(3_u64)
      row.value_as("active", Bool).should be_true
      row.value_as("id", CrystalClick::UUIDValue).should eq(CrystalClick::UUIDValue.new(1_u64, 2_u64))
      row.value_as("label", String).should eq("now")
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects mismatched exact temporal type, nominal carrier, or scale before staging" do
    parent = File.tempname("crystal-click-wide-writer-temporal-invalid")
    Dir.mkdir(parent)
    stage_calls = [] of Int32
    copy_calls = [] of Int32
    factory = w100_temporal_writer_stage_factory(stage_calls)
    keys = [1_u64, 2_u64]

    begin
      wrong_scale_metadata = [
        CrystalClick::WideTupleLeafColumn.new(
          "at", "DateTime64(9)",
          [CrystalClick::DateTime64Value.new(1_i64, 9), CrystalClick::DateTime64Value.new(2_i64, 9)] of CrystalClick::DateTime64Value
        ),
      ] of CrystalClick::WideTupleLeafColumn
      expect_raises(ArgumentError, "Tuple leaf buffers do not match schema order") do
        CrystalClick::WidePartWriter.w100_test_write_with_stage_factory(
          File.join(parent, "wrong-scale-type"), "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          "Tuple(at DateTime64(3))", wrong_scale_metadata, 1, factory, w100_temporal_writer_string_copy(copy_calls)
        )
      end

      expect_raises(ArgumentError) do
        wrong_nominal = [
          CrystalClick::WideTupleLeafColumn.new(
            "at", "DateTime64(3)",
            [CrystalClick::DateTimeValue.new(1_u32), CrystalClick::DateTimeValue.new(2_u32)] of CrystalClick::DateTimeValue
          ),
        ] of CrystalClick::WideTupleLeafColumn
        CrystalClick::WidePartWriter.w100_test_write_with_stage_factory(
          File.join(parent, "wrong-nominal-buffer"), "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          "Tuple(at DateTime64(3))", wrong_nominal, 1, factory, w100_temporal_writer_string_copy(copy_calls)
        )
      end

      expect_raises(ArgumentError) do
        mixed_scale_rows = [
          CrystalClick::WideTupleLeafColumn.new(
            "at", "DateTime64(3)",
            [CrystalClick::DateTime64Value.new(1_i64, 3), CrystalClick::DateTime64Value.new(2_i64, 9)] of CrystalClick::DateTime64Value
          ),
        ] of CrystalClick::WideTupleLeafColumn
        CrystalClick::WidePartWriter.w100_test_write_with_stage_factory(
          File.join(parent, "mixed-row-scale"), "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          "Tuple(at DateTime64(3))", mixed_scale_rows, 1, factory, w100_temporal_writer_string_copy(copy_calls)
        )
      end

      empty_scale_mismatch = [
        CrystalClick::WideTupleLeafColumn.new("at", "DateTime64(9)", [] of CrystalClick::DateTime64Value),
      ] of CrystalClick::WideTupleLeafColumn
      expect_raises(ArgumentError, "Tuple leaf buffers do not match schema order") do
        CrystalClick::WidePartWriter.w100_test_write_with_stage_factory(
          File.join(parent, "empty-wrong-scale"), "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          "Tuple(at DateTime64(3))", empty_scale_mismatch, 1, factory, w100_temporal_writer_string_copy(copy_calls)
        )
      end

      stage_calls.should be_empty
      copy_calls.should be_empty
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "charges temporal materialization by owned nominal representation before staging" do
    parent = File.tempname("crystal-click-wide-writer-temporal-budget")
    Dir.mkdir(parent)
    stage_calls = [] of Int32
    copy_calls = [] of Int32
    factory = w100_temporal_writer_stage_factory(stage_calls)
    type_name = "Tuple(at DateTime64(3))"
    plan = CrystalClick::WideTupleTypePlan.for_type(type_name).not_nil!
    owned_width = CrystalClick::WideTupleTemporalType.owned_width("DateTime64(3)").not_nil!
    per_row_charge = CrystalClick::WideTupleTypePlan::RESULT_ROW_ACCOUNTING_BYTES + owned_width.to_u64 + CrystalClick::WideTupleTypePlan::UINT64_SLOT_ACCOUNTING_BYTES
    datetime_descriptor_charge = plan.fields.first.datetime_type.not_nil!.logical_charge
    fixed_charge = CrystalClick::WideTupleTypePlan::RESULT_CONTAINER_ACCOUNTING_BYTES +
                   CrystalClick::WideTupleTypePlan::FIELD_CONTAINER_ACCOUNTING_BYTES + datetime_descriptor_charge
    rows = ((CrystalClick::WideTupleTypePlan::MAX_MATERIALIZED_BYTES - fixed_charge) // per_row_charge + 1_u64).to_i32
    keys = Array(UInt64).new(rows) { |index| index.to_u64 + 1_u64 }
    values = Array(CrystalClick::DateTime64Value).new(rows) { CrystalClick::DateTime64Value.new(0_i64, 3) }
    columns = [CrystalClick::WideTupleLeafColumn.new("at", "DateTime64(3)", values)] of CrystalClick::WideTupleLeafColumn
    destination = File.join(parent, "over-budget")

    begin
      expect_raises(ArgumentError, "Tuple materialization charge exceeds limit") do
        CrystalClick::WidePartWriter.w100_test_write_with_stage_factory(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns, 65_536,
          factory, w100_temporal_writer_string_copy(copy_calls)
        )
      end
      plan.materialization_charge(rows.to_u64, 0_u64).should_not be_nil
      stage_calls.should be_empty
      copy_calls.should be_empty
      File.exists?(destination).should be_false
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
