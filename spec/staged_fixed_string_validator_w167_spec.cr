require "./spec_helper"
require "file_utils"

# Inert-by-default probes characterize the exact virtual FixedString readers
# used by the staged validators. W167 enables them only around public writes.
class CrystalClick::WidePart
  class_property w167_fixed_string_probe_enabled = false
  class_property w167_fixed_string_probe_calls = [] of Tuple(String, Int32, Int32, Array(String))
  class_property w167_fixed_string_probe_mismatch_mark = -1
  class_property w167_nullable_fixed_string_probe_calls = [] of Tuple(String, Int32, Int32, Array(String?))
  class_property w167_nullable_fixed_string_probe_mismatch_mark = -1

  def self.w167_begin_fixed_string_probe(
    fixed_mismatch_mark : Int32 = -1,
    nullable_mismatch_mark : Int32 = -1,
  ) : Nil
    self.w167_fixed_string_probe_calls = [] of Tuple(String, Int32, Int32, Array(String))
    self.w167_nullable_fixed_string_probe_calls = [] of Tuple(String, Int32, Int32, Array(String?))
    self.w167_fixed_string_probe_mismatch_mark = fixed_mismatch_mark
    self.w167_nullable_fixed_string_probe_mismatch_mark = nullable_mismatch_mark
    self.w167_fixed_string_probe_enabled = true
  end

  def self.w167_end_fixed_string_probe : Nil
    self.w167_fixed_string_probe_enabled = false
    self.w167_fixed_string_probe_mismatch_mark = -1
    self.w167_nullable_fixed_string_probe_mismatch_mark = -1
  end

  def read_fixed_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(String)
    observed = previous_def
    if CrystalClick::WidePart.w167_fixed_string_probe_enabled
      if first_mark == CrystalClick::WidePart.w167_fixed_string_probe_mismatch_mark
        raise CorruptPartError.new("W167 mismatch injection requires a nonempty FixedString value") if observed.empty? || observed[0].empty?
        bytes = observed[0].to_slice.dup
        bytes[0] = bytes[0] ^ 0x01_u8
        observed[0] = String.new(bytes)
      end
      CrystalClick::WidePart.w167_fixed_string_probe_calls << {
        column,
        first_mark.to_i32,
        mark_count.to_i32,
        observed.dup,
      }
    end
    observed
  end

  def read_nullable_fixed_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(String?)
    observed = previous_def
    if CrystalClick::WidePart.w167_fixed_string_probe_enabled
      if first_mark == CrystalClick::WidePart.w167_nullable_fixed_string_probe_mismatch_mark
        raise CorruptPartError.new("W167 mismatch injection requires a nonempty Nullable(FixedString) mark") if observed.empty?
        observed[0] = nil
      end
      CrystalClick::WidePart.w167_nullable_fixed_string_probe_calls << {
        column,
        first_mark.to_i32,
        mark_count.to_i32,
        observed.dup,
      }
    end
    observed
  end
end

# Test-only bridges characterize the private validators against valid public
# writer output, including exact nominal shape and FixedString width checks.
module CrystalClick::WidePartWriter
  def self.w167_test_validate_staged_fixed_string(
    stage : String,
    keys : Slice(UInt64),
    values : Slice(String),
    width : Int32,
    rows_per_mark : Int32,
  ) : Nil
    validate_staged_fixed_string_part(stage, "pk", "value", keys, values, width, rows_per_mark)
  end

  def self.w167_test_validate_staged_nullable_fixed_string(
    stage : String,
    keys : Slice(UInt64),
    values : Slice(String?),
    width : Int32,
    rows_per_mark : Int32,
  ) : Nil
    validate_staged_nullable_fixed_string_part(stage, "pk", "value", keys, values, width, rows_per_mark)
  end
end

private def w167_parent(label : String, &)
  parent = File.tempname("crystal-click-w167-#{label}-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    CrystalClick::WidePart.w167_end_fixed_string_probe
    FileUtils.rm_rf(parent)
  end
end

private def w167_keys : Array(UInt64)
  [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
end

private def w167_fixed_string_values : Array(String)
  ["", "é", String.new(Bytes[0x61_u8, 0x00_u8, 0xff_u8]), "WXYZ", "z"]
end

private def w167_nullable_fixed_string_values : Array(String?)
  [nil, "", "a", String.new(Bytes[0x00_u8, 0xff_u8]), "é"] of String?
end

private def w167_padded_fixed_string(value : String, width : Int32) : String
  bytes = Bytes.new(width, 0_u8)
  value.to_slice.copy_to(bytes) unless value.empty?
  String.new(bytes)
end

private def w167_padded_fixed_string_values(values : Array(String), width : Int32) : Array(String)
  values.map { |value| w167_padded_fixed_string(value, width) }
end

private def w167_padded_nullable_fixed_string_values(values : Array(String?), width : Int32) : Array(String?)
  padded = [] of String?
  values.each do |value|
    padded << (value.nil? ? nil : w167_padded_fixed_string(value.not_nil!, width))
  end
  padded
end

private def w167_fixed_string_mark_trace(values : Array(String)) : Array(Tuple(String, Int32, Int32, Array(String)))
  [
    {"value", 0_i32, 1_i32, values[0, 2]},
    {"value", 1_i32, 1_i32, values[2, 2]},
    {"value", 2_i32, 1_i32, values[4, 1]},
  ]
end

private def w167_nullable_fixed_string_mark_trace(values : Array(String?)) : Array(Tuple(String, Int32, Int32, Array(String?)))
  [
    {"value", 0_i32, 1_i32, values[0, 2]},
    {"value", 1_i32, 1_i32, values[2, 2]},
    {"value", 2_i32, 1_i32, values[4, 1]},
  ]
end

private def w167_fixed_string_mark_trace_with_mismatch(values : Array(String)) : Array(Tuple(String, Int32, Int32, Array(String)))
  expected = w167_fixed_string_mark_trace(values)
  bytes = expected[1][3][0].to_slice.dup
  bytes[0] = bytes[0] ^ 0x01_u8
  expected[1][3][0] = String.new(bytes)
  expected[0, 2]
end

private def w167_nullable_fixed_string_mark_trace_with_mismatch(values : Array(String?)) : Array(Tuple(String, Int32, Int32, Array(String?)))
  expected = w167_nullable_fixed_string_mark_trace(values)
  expected[1][3][0] = nil
  expected[0, 2]
end

describe "W167 staged FixedString validator characterization" do
  it "reads scalar FixedString bytes one mark at a time through the public writer" do
    w167_parent("scalar") do |parent|
      keys = w167_keys
      values = w167_fixed_string_values
      expected = w167_padded_fixed_string_values(values, 4)
      destination = File.join(parent, "scalar-part")

      CrystalClick::WidePart.w167_begin_fixed_string_probe
      begin
        CrystalClick::WidePartWriter.write_uint64_fixed_string_pair(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "value",
          values.to_unsafe.to_slice(values.size),
          width: 4,
          rows_per_mark: 2
        ).should eq(destination)
      ensure
        CrystalClick::WidePart.w167_fixed_string_probe_calls.should eq(w167_fixed_string_mark_trace(expected))
        CrystalClick::WidePart.w167_end_fixed_string_probe
      end

      part = CrystalClick::WidePart.open_typed(destination, "value")
      part.column_type.should eq("FixedString(4)")
      part.row_count.should eq(5_u64)
      part.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      part.read_fixed_string_mark_range("value", 0, 3).should eq(expected)
    end
  end

  it "rejects a scalar returned-byte mismatch at mark one before publish and removes staging" do
    w167_parent("scalar-mismatch") do |parent|
      keys = w167_keys
      values = w167_fixed_string_values
      expected = w167_padded_fixed_string_values(values, 4)
      publish_parent = File.join(parent, "publish")
      Dir.mkdir(publish_parent)
      destination = File.join(publish_parent, "all_1_1_0")

      CrystalClick::WidePart.w167_begin_fixed_string_probe(fixed_mismatch_mark: 1)
      begin
        error = expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::WidePartWriter.write_uint64_fixed_string_pair(
            destination,
            "pk",
            keys.to_unsafe.to_slice(keys.size),
            "value",
            values.to_unsafe.to_slice(values.size),
            width: 4,
            rows_per_mark: 2
          )
        end
        error.message.should eq("staged FixedString stream readback differs from input")
      ensure
        CrystalClick::WidePart.w167_fixed_string_probe_calls.should eq(w167_fixed_string_mark_trace_with_mismatch(expected))
        CrystalClick::WidePart.w167_end_fixed_string_probe
      end
      File.exists?(destination).should be_false
      Dir.children(publish_parent).should be_empty
    end
  end

  it "distinguishes Nullable(FixedString) NULL from empty and rejects a mark-one NULL mismatch" do
    w167_parent("nullable") do |parent|
      keys = w167_keys
      values = w167_nullable_fixed_string_values
      expected = w167_padded_nullable_fixed_string_values(values, 3)
      destination = File.join(parent, "nullable-part")

      CrystalClick::WidePart.w167_begin_fixed_string_probe
      begin
        CrystalClick::WidePartWriter.write_uint64_nullable_fixed_string_pair(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "value",
          values.to_unsafe.to_slice(values.size),
          width: 3,
          rows_per_mark: 2
        ).should eq(destination)
      ensure
        CrystalClick::WidePart.w167_nullable_fixed_string_probe_calls.should eq(w167_nullable_fixed_string_mark_trace(expected))
        CrystalClick::WidePart.w167_end_fixed_string_probe
      end

      part = CrystalClick::WidePart.open_typed(destination, "value")
      part.column_type.should eq("Nullable(FixedString(3))")
      part.row_count.should eq(5_u64)
      part.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      part.read_nullable_fixed_string_mark_range("value", 0, 3).should eq(expected)
      expected[0].should be_nil
      expected[1].should eq("\0\0\0")

      publish_parent = File.join(parent, "publish")
      Dir.mkdir(publish_parent)
      bad_destination = File.join(publish_parent, "all_1_1_0")
      CrystalClick::WidePart.w167_begin_fixed_string_probe(nullable_mismatch_mark: 1)
      begin
        error = expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::WidePartWriter.write_uint64_nullable_fixed_string_pair(
            bad_destination,
            "pk",
            keys.to_unsafe.to_slice(keys.size),
            "value",
            values.to_unsafe.to_slice(values.size),
            width: 3,
            rows_per_mark: 2
          )
        end
        error.message.should eq("staged Nullable(FixedString) null map differs from input")
      ensure
        CrystalClick::WidePart.w167_nullable_fixed_string_probe_calls.should eq(w167_nullable_fixed_string_mark_trace_with_mismatch(expected))
        CrystalClick::WidePart.w167_end_fixed_string_probe
      end
      File.exists?(bad_destination).should be_false
      Dir.children(publish_parent).should be_empty
    end
  end

  it "guards the opposite valid shape and exact width through private-validator bridges" do
    w167_parent("nominal-guards") do |parent|
      keys = w167_keys
      scalar_values = ["", "a", "xy", "z", "q"]
      nullable_values = [nil, "", "a", "xy", "z"] of String?
      scalar_part = File.join(parent, "scalar-profile")
      nullable_part = File.join(parent, "nullable-profile")

      CrystalClick::WidePartWriter.write_uint64_fixed_string_pair(
        scalar_part,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "value",
        scalar_values.to_unsafe.to_slice(scalar_values.size),
        width: 3,
        rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_nullable_fixed_string_pair(
        nullable_part,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "value",
        nullable_values.to_unsafe.to_slice(nullable_values.size),
        width: 3,
        rows_per_mark: 2
      )

      scalar_shape_error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.w167_test_validate_staged_fixed_string(
          nullable_part,
          keys.to_unsafe.to_slice(keys.size),
          scalar_values.to_unsafe.to_slice(scalar_values.size),
          3,
          2
        )
      end
      scalar_shape_error.message.should eq("staged FixedString column type does not match")

      nullable_shape_error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.w167_test_validate_staged_nullable_fixed_string(
          scalar_part,
          keys.to_unsafe.to_slice(keys.size),
          nullable_values.to_unsafe.to_slice(nullable_values.size),
          3,
          2
        )
      end
      nullable_shape_error.message.should eq("staged Nullable(FixedString) type does not match")

      scalar_width_error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.w167_test_validate_staged_fixed_string(
          scalar_part,
          keys.to_unsafe.to_slice(keys.size),
          scalar_values.to_unsafe.to_slice(scalar_values.size),
          4,
          2
        )
      end
      scalar_width_error.message.should eq("staged FixedString column type does not match")

      nullable_width_error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.w167_test_validate_staged_nullable_fixed_string(
          nullable_part,
          keys.to_unsafe.to_slice(keys.size),
          nullable_values.to_unsafe.to_slice(nullable_values.size),
          4,
          2
        )
      end
      nullable_width_error.message.should eq("staged Nullable(FixedString) type does not match")
    end
  end
end
