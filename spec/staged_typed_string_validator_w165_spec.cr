require "./spec_helper"
require "file_utils"

# These hooks are inert unless one of the W165 examples explicitly enables
# them. String validation currently dispatches directly through WidePart's
# virtual readers, so the probe sits on those exact public methods.
class CrystalClick::WidePart
  class_property w165_string_probe_enabled = false
  class_property w165_string_probe_calls = [] of Tuple(String, Int32, Int32, Array(String))
  class_property w165_string_probe_mismatch_mark = -1
  class_property w165_nullable_string_probe_calls = [] of Tuple(String, Int32, Int32, Array(String?))
  class_property w165_nullable_string_probe_mismatch_mark = -1

  def self.w165_begin_string_probe(mismatch_mark : Int32 = -1) : Nil
    self.w165_string_probe_calls = [] of Tuple(String, Int32, Int32, Array(String))
    self.w165_nullable_string_probe_calls = [] of Tuple(String, Int32, Int32, Array(String?))
    self.w165_string_probe_mismatch_mark = mismatch_mark
    self.w165_nullable_string_probe_mismatch_mark = -1
    self.w165_string_probe_enabled = true
  end

  def self.w165_begin_nullable_string_probe(mismatch_mark : Int32 = -1) : Nil
    self.w165_string_probe_calls = [] of Tuple(String, Int32, Int32, Array(String))
    self.w165_nullable_string_probe_calls = [] of Tuple(String, Int32, Int32, Array(String?))
    self.w165_string_probe_mismatch_mark = -1
    self.w165_nullable_string_probe_mismatch_mark = mismatch_mark
    self.w165_string_probe_enabled = true
  end

  def self.w165_end_string_probe : Nil
    self.w165_string_probe_enabled = false
    self.w165_string_probe_mismatch_mark = -1
    self.w165_nullable_string_probe_mismatch_mark = -1
  end

  def read_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(String)
    observed = previous_def
    if CrystalClick::WidePart.w165_string_probe_enabled
      if first_mark == CrystalClick::WidePart.w165_string_probe_mismatch_mark
        raise CorruptPartError.new("W165 mismatch injection requires a nonempty String mark") if observed.empty?
        observed[0] = observed[0] + "!"
      end
      CrystalClick::WidePart.w165_string_probe_calls << {
        column,
        first_mark.to_i32,
        mark_count.to_i32,
        observed.dup,
      }
    end
    observed
  end

  def read_nullable_string_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(String?)
    observed = previous_def
    if CrystalClick::WidePart.w165_string_probe_enabled
      if first_mark == CrystalClick::WidePart.w165_nullable_string_probe_mismatch_mark
        raise CorruptPartError.new("W165 mismatch injection requires a nonempty Nullable(String) mark") if observed.empty?
        value = observed[0]
        observed[0] = value.not_nil! + "!" unless value.nil?
      end
      CrystalClick::WidePart.w165_nullable_string_probe_calls << {
        column,
        first_mark.to_i32,
        mark_count.to_i32,
        observed.dup,
      }
    end
    observed
  end
end

# Test-only bridges keep the existing private staged validators directly
# characterizable, including exact-type checks against valid opposite profiles.
module CrystalClick::WidePartWriter
  def self.w165_test_validate_staged_string(
    stage : String,
    keys : Slice(UInt64),
    values : Slice(String),
    rows_per_mark : Int32,
  ) : Nil
    validate_staged_string_part(stage, "pk", "value", keys, values, rows_per_mark)
  end

  def self.w165_test_validate_staged_nullable_string(
    stage : String,
    keys : Slice(UInt64),
    values : Slice(String?),
    rows_per_mark : Int32,
  ) : Nil
    validate_staged_nullable_string_part(stage, "pk", "value", keys, values, rows_per_mark)
  end
end

private def w165_parent(label : String, &)
  parent = File.tempname("crystal-click-w165-#{label}-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    CrystalClick::WidePart.w165_end_string_probe
    FileUtils.rm_rf(parent)
  end
end

private def w165_string_values : Array(String)
  [
    "",
    String.new(Bytes[0x61_u8, 0x00_u8, 0xff_u8]),
    "é",
    String.new(Bytes.new(130, 0x78_u8)),
    "tail",
  ]
end

private def w165_nullable_string_values : Array(String?)
  [
    nil.as(String?),
    "".as(String?),
    String.new(Bytes[0x61_u8, 0x00_u8, 0xff_u8]).as(String?),
    "λ".as(String?),
    String.new(Bytes.new(130, 0x78_u8)).as(String?),
  ]
end

private def w165_keys : Array(UInt64)
  [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
end

private def w165_string_mark_trace(values : Array(String)) : Array(Tuple(String, Int32, Int32, Array(String)))
  [
    {"value", 0_i32, 1_i32, values[0, 2]},
    {"value", 1_i32, 1_i32, values[2, 2]},
    {"value", 2_i32, 1_i32, values[4, 1]},
  ]
end

private def w165_nullable_string_mark_trace(values : Array(String?)) : Array(Tuple(String, Int32, Int32, Array(String?)))
  [
    {"value", 0_i32, 1_i32, values[0, 2]},
    {"value", 1_i32, 1_i32, values[2, 2]},
    {"value", 2_i32, 1_i32, values[4, 1]},
  ]
end

private def w165_string_mark_trace_with_mismatch(values : Array(String)) : Array(Tuple(String, Int32, Int32, Array(String)))
  expected = w165_string_mark_trace(values)
  expected[1][3][0] = expected[1][3][0] + "!"
  expected[0, 2]
end

private def w165_nullable_string_mark_trace_with_mismatch(values : Array(String?)) : Array(Tuple(String, Int32, Int32, Array(String?)))
  expected = w165_nullable_string_mark_trace(values)
  expected[1][3][0] = expected[1][3][0].not_nil! + "!"
  expected[0, 2]
end

private def w165_decoded_stream(part : String, logical_name : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice).to_a
end

describe "W165 staged String validator characterization" do
  it "reads exact String values by one mark and rejects a returned-value mismatch before publication" do
    w165_parent("scalar") do |parent|
      keys = w165_keys
      values = w165_string_values
      destination = File.join(parent, "scalar-part")

      CrystalClick::WidePart.w165_begin_string_probe
      begin
        CrystalClick::WidePartWriter.write_uint64_string_pair(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "value",
          values.to_unsafe.to_slice(values.size),
          rows_per_mark: 2
        ).should eq(destination)
      ensure
        CrystalClick::WidePart.w165_string_probe_calls.should eq(w165_string_mark_trace(values))
        CrystalClick::WidePart.w165_end_string_probe
      end

      part = CrystalClick::WidePart.open_typed(destination, "value")
      part.column_type.should eq("String")
      part.row_count.should eq(5_u64)
      part.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      part.read_string_mark_range("value", 0, 3).map(&.to_slice.to_a).should eq([
        [] of UInt8,
        [0x61_u8, 0x00_u8, 0xff_u8],
        [0xc3_u8, 0xa9_u8],
        Array(UInt8).new(130, 0x78_u8),
        [0x74_u8, 0x61_u8, 0x69_u8, 0x6c_u8],
      ])
      w165_decoded_stream(destination, "value").should eq(
        [0x61_u8, 0x00_u8, 0xff_u8, 0xc3_u8, 0xa9_u8] + Array(UInt8).new(130, 0x78_u8) +
        [0x74_u8, 0x61_u8, 0x69_u8, 0x6c_u8]
      )
      w165_decoded_stream(destination, "value.size").should eq(Bytes[
        0, 0, 0, 0, 0, 0, 0, 0,
        3, 0, 0, 0, 0, 0, 0, 0,
        2, 0, 0, 0, 0, 0, 0, 0,
        130, 0, 0, 0, 0, 0, 0, 0,
        4, 0, 0, 0, 0, 0, 0, 0,
      ].to_a)

      bad_table = File.join(parent, "scalar-failed-table")
      Dir.mkdir(bad_table)
      bad_destination = File.join(bad_table, "all_1_1_0")
      CrystalClick::WidePart.w165_begin_string_probe(mismatch_mark: 1)
      begin
        error = expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::WidePartWriter.write_uint64_string_pair(
            bad_destination,
            "pk",
            keys.to_unsafe.to_slice(keys.size),
            "value",
            values.to_unsafe.to_slice(values.size),
            rows_per_mark: 2
          )
        end
        error.message.should eq("staged String stream readback differs from input")
      ensure
        CrystalClick::WidePart.w165_string_probe_calls.should eq(w165_string_mark_trace_with_mismatch(values))
        CrystalClick::WidePart.w165_end_string_probe
      end
      File.exists?(bad_destination).should be_false
      Dir.children(bad_table).should be_empty

      nullable_profile = File.join(parent, "scalar-guard-nullable-profile")
      nullable_values = w165_nullable_string_values
      CrystalClick::WidePartWriter.write_uint64_typed_pair(
        nullable_profile,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "value",
        nullable_values.to_unsafe.to_slice(nullable_values.size),
        rows_per_mark: 2
      )
      type_error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.w165_test_validate_staged_string(
          nullable_profile,
          keys.to_unsafe.to_slice(keys.size),
          values.to_unsafe.to_slice(values.size),
          2
        )
      end
      type_error.message.should eq("staged String column type does not match")
    end
  end

  it "reads Nullable(String) values by one mark and rejects a returned-value mismatch before publication" do
    w165_parent("nullable") do |parent|
      keys = w165_keys
      values = w165_nullable_string_values
      destination = File.join(parent, "nullable-part")

      CrystalClick::WidePart.w165_begin_nullable_string_probe
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
        CrystalClick::WidePart.w165_nullable_string_probe_calls.should eq(w165_nullable_string_mark_trace(values))
        CrystalClick::WidePart.w165_end_string_probe
      end

      part = CrystalClick::WidePart.open_typed(destination, "value")
      part.column_type.should eq("Nullable(String)")
      part.row_count.should eq(5_u64)
      part.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      part.read_nullable_string_mark_range("value", 0, 3).map do |value|
        value.nil? ? nil.as(Array(UInt8)?) : value.not_nil!.to_slice.to_a.as(Array(UInt8)?)
      end.should eq([
        nil.as(Array(UInt8)?),
        [] of UInt8,
        [0x61_u8, 0x00_u8, 0xff_u8].as(Array(UInt8)?),
        [0xce_u8, 0xbb_u8].as(Array(UInt8)?),
        Array(UInt8).new(130, 0x78_u8).as(Array(UInt8)?),
      ])
      w165_decoded_stream(destination, "value.null").should eq([1_u8, 0_u8, 0_u8, 0_u8, 0_u8])
      w165_decoded_stream(destination, "value").should eq(
        [0x61_u8, 0x00_u8, 0xff_u8, 0xce_u8, 0xbb_u8] + Array(UInt8).new(130, 0x78_u8)
      )
      w165_decoded_stream(destination, "value.size").should eq(Bytes[
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        3, 0, 0, 0, 0, 0, 0, 0,
        2, 0, 0, 0, 0, 0, 0, 0,
        130, 0, 0, 0, 0, 0, 0, 0,
      ].to_a)

      bad_table = File.join(parent, "nullable-failed-table")
      Dir.mkdir(bad_table)
      bad_destination = File.join(bad_table, "all_1_1_0")
      CrystalClick::WidePart.w165_begin_nullable_string_probe(mismatch_mark: 1)
      begin
        error = expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::WidePartWriter.write_uint64_typed_pair(
            bad_destination,
            "pk",
            keys.to_unsafe.to_slice(keys.size),
            "value",
            values.to_unsafe.to_slice(values.size),
            rows_per_mark: 2
          )
        end
        error.message.should eq("staged Nullable(String) stream readback differs from input")
      ensure
        CrystalClick::WidePart.w165_nullable_string_probe_calls.should eq(w165_nullable_string_mark_trace_with_mismatch(values))
        CrystalClick::WidePart.w165_end_string_probe
      end
      File.exists?(bad_destination).should be_false
      Dir.children(bad_table).should be_empty

      scalar_profile = File.join(parent, "nullable-guard-scalar-profile")
      scalar_values = w165_string_values
      CrystalClick::WidePartWriter.write_uint64_string_pair(
        scalar_profile,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "value",
        scalar_values.to_unsafe.to_slice(scalar_values.size),
        rows_per_mark: 2
      )
      type_error = expect_raises(CrystalClick::CorruptPartError) do
        CrystalClick::WidePartWriter.w165_test_validate_staged_nullable_string(
          scalar_profile,
          keys.to_unsafe.to_slice(keys.size),
          values.to_unsafe.to_slice(values.size),
          2
        )
      end
      type_error.message.should eq("staged Nullable(String) type does not match")
    end
  end
end
