require "./spec_helper"
require "file_utils"

# Opt-in hooks around the existing private readback facade selectors. The
# public writer runs the staged validators before publishing, so a test-only
# failure here also checks that the staged directory is cleaned up.
module CrystalClick::WidePartWriter
  class_property w162_selector_probe_enabled = false
  class_property w162_selector_probe_calls = [] of Tuple(String, Int32, Bool, Int32)
  class_property w162_selector_probe_fail_mark = -1
  class_property w162_selector_probe_fail_nullable = false

  def self.w162_begin_selector_probe : Nil
    self.w162_selector_probe_calls = [] of Tuple(String, Int32, Bool, Int32)
    self.w162_selector_probe_fail_mark = -1
    self.w162_selector_probe_fail_nullable = false
    self.w162_selector_probe_enabled = true
  end

  def self.w162_end_selector_probe : Array(Tuple(String, Int32, Bool, Int32))
    self.w162_selector_probe_enabled = false
    self.w162_selector_probe_fail_mark = -1
    self.w162_selector_probe_calls.dup
  end

  def self.w162_stop_selector_probe : Nil
    self.w162_selector_probe_enabled = false
    self.w162_selector_probe_fail_mark = -1
  end

  private def self.read_typed_numeric_mark(
    part : WidePart,
    column : String,
    mark_index : Int,
    values : Slice(T),
    type_name : String,
  ) : Array(T) forall T
    observed = previous_def
    if w162_selector_probe_enabled
      w162_check_selector_result(part, mark_index, values, observed)
      w162_selector_probe_calls << {type_name, mark_index.to_i32, false, observed.size.to_i32}
      if !w162_selector_probe_fail_nullable && mark_index == w162_selector_probe_fail_mark
        raise CorruptPartError.new("W162 injected staged numeric validation failure")
      end
    end
    observed
  end

  private def self.read_typed_nullable_numeric_mark(
    part : WidePart,
    column : String,
    mark_index : Int,
    values : Slice(T),
    type_name : String,
  ) : Array(T) forall T
    observed = previous_def
    if w162_selector_probe_enabled
      w162_check_selector_result(part, mark_index, values, observed)
      w162_selector_probe_calls << {type_name, mark_index.to_i32, true, observed.size.to_i32}
      if w162_selector_probe_fail_nullable && mark_index == w162_selector_probe_fail_mark
        raise CorruptPartError.new("W162 injected staged numeric validation failure")
      end
    end
    observed
  end

  private def self.w162_check_selector_result(
    part : WidePart,
    mark_index : Int,
    values : Slice(T),
    observed : Array(T),
  ) : Nil forall T
    mark_rows = part.mark_row_counts
    start = 0
    mark_index.times { |index| start += mark_rows[index].to_i }
    expected = values[start, mark_rows[mark_index].to_i]
    observed.size.should eq(expected.size)
    {% if T == Float64 %}
      observed.map { |value| value.unsafe_as(UInt64) }.should eq(expected.map { |value| value.unsafe_as(UInt64) }.to_a)
    {% elsif T == Float64? %}
      observed_bits = observed.map do |value|
        value.nil? ? nil.as(UInt64?) : value.not_nil!.unsafe_as(UInt64).as(UInt64?)
      end
      expected_bits = expected.map do |value|
        value.nil? ? nil.as(UInt64?) : value.not_nil!.unsafe_as(UInt64).as(UInt64?)
      end
      observed_bits.should eq(expected_bits.to_a)
    {% else %}
      observed.should eq(expected.to_a)
    {% end %}
  end

  # Test-only bridge to the existing dispatcher; production callers continue
  # to use the same private facade.
  def self.w162_test_validate_staged_numeric(
    stage : String,
    keys : Slice(UInt64),
    values : Slice(T),
    type_name : String,
    rows_per_mark : Int32,
  ) : Nil forall T
    validate_staged_typed_part(stage, "pk", "value", keys, values, type_name, rows_per_mark)
  end
end

private def with_w162_parent(label : String, &)
  parent = File.tempname("crystal-click-w162-#{label}-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w162_destination(parent : String, name : String) : String
  table = File.join(parent, name)
  Dir.mkdir(table)
  File.join(table, "all_1_1_0")
end

private def w162_decoded_stream(part : String, logical_name : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice).to_a
end

private def w162_three_mark_trace(type_name : String, nullable : Bool) : Array(Tuple(String, Int32, Bool, Int32))
  [
    {type_name, 0_i32, nullable, 2_i32},
    {type_name, 1_i32, nullable, 2_i32},
    {type_name, 2_i32, nullable, 1_i32},
  ]
end

private def w162_replace_staged_column_type(stage : String, from : String, to : String) : Nil
  path = File.join(stage, "columns.txt")
  original = File.read(path)
  from_line = "`value` #{from}\n"
  to_line = "`value` #{to}\n"
  original.should contain(from_line)
  updated = original.sub(from_line, to_line)
  raise "W162 fixture did not contain the expected staged type" if updated == original
  File.write(path, updated)
end

describe "W162 staged typed numeric validator characterization" do
  it "preserves scalar Float64 selector marks, exact return bits, and raw negative-zero/NaN bytes" do
    with_w162_parent("scalar") do |parent|
      keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
      expected_bits = [
        0x8000000000000000_u64,
        0x7ff8000000000042_u64,
        0x3ff0000000000000_u64,
        0x0000000000000000_u64,
        0xfff8000000000001_u64,
      ]
      values = expected_bits.map(&.unsafe_as(Float64))
      destination = w162_destination(parent, "scalar-table")

      CrystalClick::WidePartWriter.w162_begin_selector_probe
      begin
        CrystalClick::WidePartWriter.write_uint64_typed_pair(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "value",
          values.to_unsafe.to_slice(values.size),
          rows_per_mark: 2
        ).should eq(destination)
      ensure
        calls = CrystalClick::WidePartWriter.w162_end_selector_probe
      end

      calls.should eq(w162_three_mark_trace("Float64", false))
      reader = CrystalClick::WidePart.open_typed(destination, "value")
      reader.column_type.should eq("Float64")
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      reader.read_numeric_mark_range("value", 0, 3, Float64).map(&.unsafe_as(UInt64)).should eq(expected_bits)
      w162_decoded_stream(destination, "value").should eq(Bytes[
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80,
        0x42, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0x7f,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf0, 0x3f,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0xff,
      ].to_a)
    end
  end

  it "preserves Nullable(Float64) selector marks, null placeholders, and exact payload bits" do
    with_w162_parent("nullable") do |parent|
      keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
      negative_zero = 0x8000000000000000_u64.unsafe_as(Float64)
      nan = 0x7ff8000000000042_u64.unsafe_as(Float64)
      values = [
        negative_zero.as(Float64?),
        nil.as(Float64?),
        nan.as(Float64?),
        0.0_f64.as(Float64?),
        nil.as(Float64?),
      ]
      destination = w162_destination(parent, "nullable-table")

      CrystalClick::WidePartWriter.w162_begin_selector_probe
      begin
        CrystalClick::WidePartWriter.write_uint64_typed_pair(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "value",
          values.to_unsafe.to_slice(values.size),
          rows_per_mark: 2
        ).should eq(destination)
      ensure
        calls = CrystalClick::WidePartWriter.w162_end_selector_probe
      end

      calls.should eq(w162_three_mark_trace("Nullable(Float64)", true))
      reader = CrystalClick::WidePart.open_typed(destination, "value")
      reader.column_type.should eq("Nullable(Float64)")
      reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      observed = reader.read_nullable_numeric_mark_range("value", 0, 3, Float64)
      observed_bits = observed.map do |value|
        value.nil? ? nil.as(UInt64?) : value.not_nil!.unsafe_as(UInt64).as(UInt64?)
      end
      observed_bits.should eq([
        0x8000000000000000_u64.as(UInt64?), nil.as(UInt64?),
        0x7ff8000000000042_u64.as(UInt64?), 0_u64.as(UInt64?), nil.as(UInt64?),
      ])
      w162_decoded_stream(destination, "value.null").should eq([0_u8, 1_u8, 0_u8, 0_u8, 1_u8])
      w162_decoded_stream(destination, "value").should eq(Bytes[
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x42, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0x7f,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      ].to_a)
    end
  end

  it "refuses scalar and Nullable temporal metadata mismatches at the staged validator" do
    with_w162_parent("metadata") do |parent|
      keys = [1_u64, 2_u64, 3_u64]
      scalar_values = [0x01020304_u32, 0_u32, UInt32::MAX]
      scalar_destination = w162_destination(parent, "scalar-source")
      CrystalClick::WidePartWriter.write_uint64_datetime_pair(
        scalar_destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "value",
        scalar_values.to_unsafe.to_slice(scalar_values.size),
        rows_per_mark: 2
      )
      scalar_stage = File.join(parent, "scalar-stage")
      FileUtils.cp_r(scalar_destination, scalar_stage)
      w162_replace_staged_column_type(scalar_stage, "DateTime", "DateTime64(0)")
      scalar_error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.w162_test_validate_staged_numeric(
          scalar_stage,
          keys.to_unsafe.to_slice(keys.size),
          scalar_values.to_unsafe.to_slice(scalar_values.size),
          "DateTime",
          2
        )
      end
      scalar_error.message.should eq("staged typed temporal column metadata differs")

      nullable_values = [0x01020304_u32.as(UInt32?), nil.as(UInt32?), UInt32::MAX.as(UInt32?)]
      nullable_destination = w162_destination(parent, "nullable-source")
      CrystalClick::WidePartWriter.write_uint64_nullable_datetime_pair(
        nullable_destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "value",
        nullable_values.to_unsafe.to_slice(nullable_values.size),
        rows_per_mark: 2
      )
      nullable_stage = File.join(parent, "nullable-stage")
      FileUtils.cp_r(nullable_destination, nullable_stage)
      w162_replace_staged_column_type(nullable_stage, "Nullable(DateTime)", "Nullable(DateTime64(0))")
      nullable_error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.w162_test_validate_staged_numeric(
          nullable_stage,
          keys.to_unsafe.to_slice(keys.size),
          nullable_values.to_unsafe.to_slice(nullable_values.size),
          "Nullable(DateTime)",
          2
        )
      end
      nullable_error.message.should eq("staged Nullable temporal column metadata differs")
    end
  end

  it "cleans the public writer's staged directory after scalar or Nullable readback failure" do
    with_w162_parent("cleanup") do |parent|
      keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
      scalar_values = [1.0_f64, -0.0_f64, 0x7ff8000000000042_u64.unsafe_as(Float64), 4.0_f64, 5.0_f64]
      nullable_values = [
        1.0_f64.as(Float64?),
        nil.as(Float64?),
        -0.0_f64.as(Float64?),
        4.0_f64.as(Float64?),
        nil.as(Float64?),
      ]

      scalar_table = File.join(parent, "scalar-failed")
      Dir.mkdir(scalar_table)
      scalar_destination = File.join(scalar_table, "all_1_1_0")
      CrystalClick::WidePartWriter.w162_begin_selector_probe
      CrystalClick::WidePartWriter.w162_selector_probe_fail_mark = 1
      begin
        error = expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::WidePartWriter.write_uint64_typed_pair(
            scalar_destination,
            "pk",
            keys.to_unsafe.to_slice(keys.size),
            "value",
            scalar_values.to_unsafe.to_slice(scalar_values.size),
            rows_per_mark: 2
          )
        end
        error.message.should eq("W162 injected staged numeric validation failure")
      ensure
        scalar_calls = CrystalClick::WidePartWriter.w162_end_selector_probe
      end
      scalar_calls.should eq([
        {"Float64", 0_i32, false, 2_i32},
        {"Float64", 1_i32, false, 2_i32},
      ])
      File.exists?(scalar_destination).should be_false
      Dir.children(scalar_table).should be_empty

      nullable_table = File.join(parent, "nullable-failed")
      Dir.mkdir(nullable_table)
      nullable_destination = File.join(nullable_table, "all_1_1_0")
      CrystalClick::WidePartWriter.w162_begin_selector_probe
      CrystalClick::WidePartWriter.w162_selector_probe_fail_mark = 1
      CrystalClick::WidePartWriter.w162_selector_probe_fail_nullable = true
      begin
        error = expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::WidePartWriter.write_uint64_typed_pair(
            nullable_destination,
            "pk",
            keys.to_unsafe.to_slice(keys.size),
            "value",
            nullable_values.to_unsafe.to_slice(nullable_values.size),
            rows_per_mark: 2
          )
        end
        error.message.should eq("W162 injected staged numeric validation failure")
      ensure
        nullable_calls = CrystalClick::WidePartWriter.w162_end_selector_probe
      end
      nullable_calls.should eq([
        {"Nullable(Float64)", 0_i32, true, 2_i32},
        {"Nullable(Float64)", 1_i32, true, 2_i32},
      ])
      File.exists?(nullable_destination).should be_false
      Dir.children(nullable_table).should be_empty
    end
  end
end
