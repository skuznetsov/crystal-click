require "./spec_helper"
require "file_utils"

# Opt-in probes stay on the public WidePart readback methods used by the
# staged Array numeric validators. Mismatch modes alter a returned row so the
# real validator comparison and public writer cleanup path are exercised.
class CrystalClick::WidePart
  class_property r1_array_numeric_probe_enabled = false
  class_property r1_array_numeric_probe_mismatch_mark = -1
  class_property r1_array_numeric_probe_calls = [] of Tuple(String, Int32, Int32, Array(Array(UInt64)))

  class_property r1_array_nullable_numeric_probe_enabled = false
  class_property r1_array_nullable_numeric_probe_mismatch_mark = -1
  class_property r1_array_nullable_numeric_probe_calls = [] of Tuple(String, Int32, Int32, Array(Array(UInt64?)))

  def self.r1_begin_array_numeric_probe(mismatch_mark : Int32 = -1) : Nil
    self.r1_array_numeric_probe_calls = [] of Tuple(String, Int32, Int32, Array(Array(UInt64)))
    self.r1_array_numeric_probe_mismatch_mark = mismatch_mark
    self.r1_array_numeric_probe_enabled = true
  end

  def self.r1_begin_array_nullable_numeric_probe(mismatch_mark : Int32 = -1) : Nil
    self.r1_array_nullable_numeric_probe_calls = [] of Tuple(String, Int32, Int32, Array(Array(UInt64?)))
    self.r1_array_nullable_numeric_probe_mismatch_mark = mismatch_mark
    self.r1_array_nullable_numeric_probe_enabled = true
  end

  def self.r1_end_array_numeric_probes : Nil
    self.r1_array_numeric_probe_enabled = false
    self.r1_array_numeric_probe_mismatch_mark = -1
    self.r1_array_nullable_numeric_probe_enabled = false
    self.r1_array_nullable_numeric_probe_mismatch_mark = -1
  end

  def read_array_numeric_mark_range(column : String, first_mark : Int, mark_count : Int, type : T.class) : Array(Array(T)) forall T
    observed = previous_def
    if CrystalClick::WidePart.r1_array_numeric_probe_enabled
      {% if T == Float64 %}
        if first_mark == CrystalClick::WidePart.r1_array_numeric_probe_mismatch_mark
          raise "R1 scalar mismatch probe requires a nonempty mark" if observed.empty? || observed[0].empty?
          observed[0][0] = 3.5_f64
        end
        CrystalClick::WidePart.r1_array_numeric_probe_calls << {
          column,
          first_mark.to_i32,
          mark_count.to_i32,
          observed.map { |row| row.map { |value| value.unsafe_as(UInt64) } },
        }
      {% end %}
    end
    observed
  end

  def read_array_nullable_numeric_mark_range(column : String, first_mark : Int, mark_count : Int, type : T.class) : Array(Array(T?)) forall T
    observed = previous_def
    if CrystalClick::WidePart.r1_array_nullable_numeric_probe_enabled
      {% if T == Float64 %}
        if first_mark == CrystalClick::WidePart.r1_array_nullable_numeric_probe_mismatch_mark
          raise "R1 nullable mismatch probe requires a nonempty mark" if observed.empty? || observed[0].empty?
          observed[0][0] = 3.5_f64.as(Float64?)
        end
        CrystalClick::WidePart.r1_array_nullable_numeric_probe_calls << {
          column,
          first_mark.to_i32,
          mark_count.to_i32,
          observed.map do |row|
            row.map do |value|
              if value.nil?
                nil.as(UInt64?)
              else
                value.not_nil!.unsafe_as(UInt64).as(UInt64?)
              end
            end
          end,
        }
      {% end %}
    end
    observed
  end
end

private def r1_float64(bits : UInt64) : Float64
  bits.unsafe_as(Float64)
end

private def r1_array_numeric_values : Array(Array(Float64))
  [
    [] of Float64,
    [r1_float64(0x8000000000000000_u64), r1_float64(0x7ff8000000000042_u64)],
    [r1_float64(0x7ff8000000000123_u64)],
    [] of Float64,
    [r1_float64(0x0000000000000001_u64)],
  ]
end

private def r1_array_nullable_numeric_values : Array(Array(Float64?))
  [
    [] of Float64?,
    [r1_float64(0x8000000000000000_u64).as(Float64?), nil.as(Float64?), r1_float64(0x7ff8000000000042_u64).as(Float64?)],
    [nil.as(Float64?), r1_float64(0x7ff8000000000123_u64).as(Float64?)],
    [] of Float64?,
    [nil.as(Float64?), r1_float64(0x0000000000000000_u64).as(Float64?)],
  ]
end

private def r1_array_numeric_trace(
  values : Array(Array(Float64)),
  mismatch_mark : Int32 = -1,
) : Array(Tuple(String, Int32, Int32, Array(Array(UInt64))))
  trace = [] of Tuple(String, Int32, Int32, Array(Array(UInt64)))
  start = 0
  mark_index = 0
  while start < values.size
    rows = {2, values.size - start}.min
    observed = values[start, rows].map { |row| row.map { |value| value.unsafe_as(UInt64) } }
    if mark_index == mismatch_mark
      raise "R1 scalar trace mismatch requires a nonempty row" if observed.empty? || observed[0].empty?
      observed[0][0] = 0x400c000000000000_u64
    end
    trace << {"value", mark_index, 1, observed}
    break if mark_index == mismatch_mark
    start += rows
    mark_index += 1
  end
  trace
end

private def r1_array_nullable_numeric_trace(
  values : Array(Array(Float64?)),
  mismatch_mark : Int32 = -1,
) : Array(Tuple(String, Int32, Int32, Array(Array(UInt64?))))
  trace = [] of Tuple(String, Int32, Int32, Array(Array(UInt64?)))
  start = 0
  mark_index = 0
  while start < values.size
    rows = {2, values.size - start}.min
    observed = values[start, rows].map do |row|
      row.map do |value|
        if value.nil?
          nil.as(UInt64?)
        else
          value.not_nil!.unsafe_as(UInt64).as(UInt64?)
        end
      end
    end
    if mark_index == mismatch_mark
      raise "R1 nullable trace mismatch requires a nonempty row" if observed.empty? || observed[0].empty?
      observed[0][0] = 0x400c000000000000_u64.as(UInt64?)
    end
    trace << {"value", mark_index, 1, observed}
    break if mark_index == mismatch_mark
    start += rows
    mark_index += 1
  end
  trace
end

private def r1_array_numeric_bits(values : Array(Array(Float64))) : Array(Array(UInt64))
  values.map { |row| row.map { |value| value.unsafe_as(UInt64) } }
end

private def r1_array_nullable_numeric_bits(values : Array(Array(Float64?))) : Array(Array(UInt64?))
  values.map do |row|
    row.map do |value|
      if value.nil?
        nil.as(UInt64?)
      else
        value.not_nil!.unsafe_as(UInt64).as(UInt64?)
      end
    end
  end
end

private def r1_array_numeric_parent(label : String, &) : Nil
  parent = File.tempname("crystal-click-r1-array-numeric-#{label}-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    CrystalClick::WidePart.r1_end_array_numeric_probes
    FileUtils.rm_rf(parent)
  end
end

describe CrystalClick::WidePartWriter do
  it "reads Array(Float64) back one mark at a time with exact ragged and floating-point bits" do
    r1_array_numeric_parent("scalar") do |parent|
      keys = [1_u64, 2_u64, 4_u64, 7_u64, 10_u64]
      values = r1_array_numeric_values
      destination = File.join(parent, "array-part")

      calls = [] of Tuple(String, Int32, Int32, Array(Array(UInt64)))
      CrystalClick::WidePart.r1_begin_array_numeric_probe
      begin
        CrystalClick::WidePartWriter.write_uint64_array_numeric_pair(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "value",
          values.to_unsafe.to_slice(values.size),
          rows_per_mark: 2
        ).should eq(destination)
      ensure
        calls = CrystalClick::WidePart.r1_array_numeric_probe_calls.dup
        CrystalClick::WidePart.r1_end_array_numeric_probes
      end

      calls.should eq(r1_array_numeric_trace(values))
      part = CrystalClick::WidePart.open_typed(destination, "value")
      part.column_type.should eq("Array(Float64)")
      part.row_count.should eq(5_u64)
      part.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      r1_array_numeric_bits(part.read_array_numeric_mark_range("value", 0, 3, Float64)).should eq(r1_array_numeric_bits(values))
    end
  end

  it "rejects an altered Array(Float64) mark-1 readback and removes the staged directory" do
    r1_array_numeric_parent("scalar-mismatch") do |parent|
      keys = [1_u64, 2_u64, 4_u64, 7_u64, 10_u64]
      values = r1_array_numeric_values
      table = File.join(parent, "failed-table")
      Dir.mkdir(table)
      destination = File.join(table, "all_1_1_0")

      CrystalClick::WidePart.r1_begin_array_numeric_probe(mismatch_mark: 1)
      begin
        error = expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::WidePartWriter.write_uint64_array_numeric_pair(
            destination,
            "pk",
            keys.to_unsafe.to_slice(keys.size),
            "value",
            values.to_unsafe.to_slice(values.size),
            rows_per_mark: 2
          )
        end
        error.message.should eq("staged Array numeric stream readback differs from input")
      ensure
        CrystalClick::WidePart.r1_end_array_numeric_probes
        CrystalClick::WidePart.r1_array_numeric_probe_calls.should eq(r1_array_numeric_trace(values, mismatch_mark: 1))
      end

      File.exists?(destination).should be_false
      Dir.children(table).should be_empty
    end
  end

  it "reads Array(Nullable(Float64)) back by mark with exact null and floating-point bits" do
    r1_array_numeric_parent("nullable") do |parent|
      keys = [1_u64, 2_u64, 4_u64, 7_u64, 10_u64]
      values = r1_array_nullable_numeric_values
      destination = File.join(parent, "array-part")

      calls = [] of Tuple(String, Int32, Int32, Array(Array(UInt64?)))
      CrystalClick::WidePart.r1_begin_array_nullable_numeric_probe
      begin
        CrystalClick::WidePartWriter.write_uint64_array_nullable_numeric_pair(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "value",
          values.to_unsafe.to_slice(values.size),
          rows_per_mark: 2
        ).should eq(destination)
      ensure
        calls = CrystalClick::WidePart.r1_array_nullable_numeric_probe_calls.dup
        CrystalClick::WidePart.r1_end_array_numeric_probes
      end

      calls.should eq(r1_array_nullable_numeric_trace(values))
      part = CrystalClick::WidePart.open_typed(destination, "value")
      part.column_type.should eq("Array(Nullable(Float64))")
      part.row_count.should eq(5_u64)
      part.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
      r1_array_nullable_numeric_bits(part.read_array_nullable_numeric_mark_range("value", 0, 3, Float64)).should eq(r1_array_nullable_numeric_bits(values))
    end
  end

  it "rejects an altered Array(Nullable(Float64)) mark-1 readback and removes the staged directory" do
    r1_array_numeric_parent("nullable-mismatch") do |parent|
      keys = [1_u64, 2_u64, 4_u64, 7_u64, 10_u64]
      values = r1_array_nullable_numeric_values
      table = File.join(parent, "failed-table")
      Dir.mkdir(table)
      destination = File.join(table, "all_1_1_0")

      CrystalClick::WidePart.r1_begin_array_nullable_numeric_probe(mismatch_mark: 1)
      begin
        error = expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::WidePartWriter.write_uint64_array_nullable_numeric_pair(
            destination,
            "pk",
            keys.to_unsafe.to_slice(keys.size),
            "value",
            values.to_unsafe.to_slice(values.size),
            rows_per_mark: 2
          )
        end
        error.message.should eq("staged Array(Nullable(T)) stream readback differs from input")
      ensure
        CrystalClick::WidePart.r1_end_array_numeric_probes
        CrystalClick::WidePart.r1_array_nullable_numeric_probe_calls.should eq(r1_array_nullable_numeric_trace(values, mismatch_mark: 1))
      end

      File.exists?(destination).should be_false
      Dir.children(table).should be_empty
    end
  end
end
