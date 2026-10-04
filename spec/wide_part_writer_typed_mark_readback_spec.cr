require "./spec_helper"

# Opt-in trace around the existing private facade selectors. The public writer
# validates staged output through these methods before publishing a part.
module CrystalClick::WidePartWriter
  class_property typed_mark_readback_probe_enabled = false
  class_property typed_mark_readback_probe_calls = [] of Tuple(String, Int32, Bool)

  def self.begin_typed_mark_readback_probe : Nil
    self.typed_mark_readback_probe_calls = [] of Tuple(String, Int32, Bool)
    self.typed_mark_readback_probe_enabled = true
  end

  def self.end_typed_mark_readback_probe : Array(Tuple(String, Int32, Bool))
    self.typed_mark_readback_probe_enabled = false
    self.typed_mark_readback_probe_calls.dup
  end

  private def self.read_typed_numeric_mark(
    part : WidePart,
    column : String,
    mark_index : Int,
    values : Slice(T),
    type_name : String,
  ) : Array(T) forall T
    if typed_mark_readback_probe_enabled
      typed_mark_readback_probe_calls << {type_name, mark_index.to_i32, false}
    end
    previous_def
  end

  private def self.read_typed_nullable_numeric_mark(
    part : WidePart,
    column : String,
    mark_index : Int,
    values : Slice(T),
    type_name : String,
  ) : Array(T) forall T
    if typed_mark_readback_probe_enabled
      typed_mark_readback_probe_calls << {type_name, mark_index.to_i32, true}
    end
    previous_def
  end

  # A deliberately test-only bridge for the exact metadata refusal. Production
  # callers use the same private facade method from staged validation.
  def self.typed_mark_readback_test_read_numeric_mark(
    part : WidePart,
    column : String,
    mark_index : Int,
    values : Slice(T),
    type_name : String,
  ) : Array(T) forall T
    read_typed_numeric_mark(part, column, mark_index, values, type_name)
  end
end

# The module selectors are not inherited methods, but the WidePart argument is
# virtual: an extracted owner must keep calling the accessor on the passed
# reader object rather than pinning dispatch to WidePart.
class TypedMarkReadbackProbePart < CrystalClick::WidePart
  class_property date_code_read_calls = [] of Tuple(String, Int32, Int32)

  def read_date_codes_mark_range(column : String, first_mark : Int, mark_count : Int) : Array(UInt16)
    TypedMarkReadbackProbePart.date_code_read_calls << {column, first_mark.to_i32, mark_count.to_i32}
    super
  end
end

private def typed_mark_readback_capture_calls(&)
  CrystalClick::WidePartWriter.begin_typed_mark_readback_probe
  begin
    yield
    CrystalClick::WidePartWriter.end_typed_mark_readback_probe
  ensure
    CrystalClick::WidePartWriter.typed_mark_readback_probe_enabled = false
  end
end

private def with_typed_mark_readback_parent(label : String, &)
  parent = File.tempname("crystal-click-typed-mark-readback-#{label}-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def typed_mark_readback_decoded_stream(part : String, logical_name : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice).to_a
end

private def typed_mark_readback_trace(type_name : String, nullable : Bool = false) : Array(Tuple(String, Int32, Bool))
  [
    {type_name, 0, nullable},
    {type_name, 1, nullable},
    {type_name, 2, nullable},
  ]
end

private def write_typed_mark_readback_numeric_case(
  label : String,
  type_name : String,
  values : Array(T),
  expected_bytes : Bytes,
) : Nil forall T
  with_typed_mark_readback_parent(label) do |parent|
    keys = [1_u64, 2_u64, 2_u64, 4_u64, 9_u64]
    destination = File.join(parent, "part")
    trace = typed_mark_readback_capture_calls do
      CrystalClick::WidePartWriter.write_uint64_typed_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "value",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 2
      )
    end

    trace.should eq(typed_mark_readback_trace(type_name))
    part = CrystalClick::WidePart.open_typed(destination, "value")
    part.column_type.should eq(type_name)
    part.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
    observed = part.read_numeric_mark_range("value", 0, 3, T)
    middle = part.read_numeric_mark_range("value", 1, 1, T)
    {% if T == Float32 %}
      observed.map { |value| value.unsafe_as(UInt32) }.should eq(values.map { |value| value.unsafe_as(UInt32) })
      middle.map { |value| value.unsafe_as(UInt32) }.should eq(values[2, 2].map { |value| value.unsafe_as(UInt32) })
    {% elsif T == Float64 %}
      observed.map { |value| value.unsafe_as(UInt64) }.should eq(values.map { |value| value.unsafe_as(UInt64) })
      middle.map { |value| value.unsafe_as(UInt64) }.should eq(values[2, 2].map { |value| value.unsafe_as(UInt64) })
    {% else %}
      observed.should eq(values)
      middle.should eq(values[2, 2])
    {% end %}
    typed_mark_readback_decoded_stream(destination, "value").should eq(expected_bytes.to_a)
  end
end

describe "WidePartWriter typed mark readback facade" do
  it "keeps unsigned, signed, and floating payload dispatch on exact marks and bytes" do
    write_typed_mark_readback_numeric_case(
      "uint16",
      "UInt16",
      [0x1234_u16, 0x80ff_u16, 0x0001_u16, 0xffff_u16, 0x8000_u16],
      Bytes[
        0x34, 0x12, 0xff, 0x80, 0x01, 0x00, 0xff, 0xff, 0x00, 0x80,
      ]
    )
    write_typed_mark_readback_numeric_case(
      "int32",
      "Int32",
      [-2_i32, 0x01020304_i32, Int32::MIN, 0_i32, Int32::MAX],
      Bytes[
        0xfe, 0xff, 0xff, 0xff,
        0x04, 0x03, 0x02, 0x01,
        0x00, 0x00, 0x00, 0x80,
        0x00, 0x00, 0x00, 0x00,
        0xff, 0xff, 0xff, 0x7f,
      ]
    )
    write_typed_mark_readback_numeric_case(
      "float64",
      "Float64",
      [1.5_f64, -2.0_f64, 0.0_f64, 3.25_f64, -0.0_f64],
      Bytes[
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0x3f,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xc0,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0a, 0x40,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80,
      ]
    )
  end

  it "keeps Bool and raw DateTime branches on each staged mark" do
    with_typed_mark_readback_parent("bool-datetime") do |parent|
      keys = [1_u64, 2_u64, 2_u64, 4_u64, 9_u64]

      bool_values = [false, true, true, false, true]
      bool_part = File.join(parent, "bool")
      bool_trace = typed_mark_readback_capture_calls do
        CrystalClick::WidePartWriter.write_uint64_typed_pair(
          bool_part,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "value",
          bool_values.to_unsafe.to_slice(bool_values.size),
          rows_per_mark: 2
        )
      end
      bool_trace.should eq(typed_mark_readback_trace("Bool"))
      bool_reader = CrystalClick::WidePart.open_typed(bool_part, "value")
      bool_reader.read_bool_mark_range("value", 0, 3).should eq(bool_values)
      bool_reader.read_bool_mark_range("value", 1, 1).should eq(bool_values[2, 2])
      typed_mark_readback_decoded_stream(bool_part, "value").should eq([0_u8, 1_u8, 1_u8, 0_u8, 1_u8])

      seconds = [0x01020304_u32, 0_u32, 0x80000000_u32, UInt32::MAX, 42_u32]
      datetime_part = File.join(parent, "datetime")
      datetime_trace = typed_mark_readback_capture_calls do
        CrystalClick::WidePartWriter.write_uint64_datetime_pair(
          datetime_part,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "value",
          seconds.to_unsafe.to_slice(seconds.size),
          rows_per_mark: 2
        )
      end
      datetime_trace.should eq(typed_mark_readback_trace("DateTime"))
      datetime_reader = CrystalClick::WidePart.open_typed(datetime_part, "value")
      datetime_reader.read_datetime_seconds_mark_range("value", 0, 3).should eq(seconds)
      datetime_reader.read_datetime_seconds_mark_range("value", 1, 1).should eq(seconds[2, 2])
      typed_mark_readback_decoded_stream(datetime_part, "value").should eq(Bytes[
        0x04, 0x03, 0x02, 0x01,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x80,
        0xff, 0xff, 0xff, 0xff,
        0x2a, 0x00, 0x00, 0x00,
      ].to_a)
    end
  end

  it "preserves nullable Bool and DateTime64 null maps, placeholders, and middle-mark reads" do
    with_typed_mark_readback_parent("nullable") do |parent|
      keys = [1_u64, 2_u64, 2_u64, 4_u64, 9_u64]

      bool_values = [nil, false.as(Bool?), true.as(Bool?), nil, true.as(Bool?)]
      bool_part = File.join(parent, "nullable-bool")
      bool_trace = typed_mark_readback_capture_calls do
        CrystalClick::WidePartWriter.write_uint64_typed_pair(
          bool_part,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "value",
          bool_values.to_unsafe.to_slice(bool_values.size),
          rows_per_mark: 2
        )
      end
      bool_trace.should eq(typed_mark_readback_trace("Nullable(Bool)", true))
      bool_reader = CrystalClick::WidePart.open_typed(bool_part, "value")
      bool_reader.read_nullable_bool_mark_range("value", 0, 3).should eq(bool_values)
      bool_reader.read_nullable_bool_mark_range("value", 1, 1).should eq(bool_values[2, 2])
      typed_mark_readback_decoded_stream(bool_part, "value.null").should eq([1_u8, 0_u8, 0_u8, 1_u8, 0_u8])
      typed_mark_readback_decoded_stream(bool_part, "value").should eq([0_u8, 0_u8, 1_u8, 0_u8, 1_u8])

      ticks = [nil, -2_i64.as(Int64?), 0_i64.as(Int64?), Int64::MIN.as(Int64?), nil]
      datetime_part = File.join(parent, "nullable-datetime64")
      datetime_trace = typed_mark_readback_capture_calls do
        CrystalClick::WidePartWriter.write_uint64_nullable_datetime64_pair(
          datetime_part,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "value",
          ticks.to_unsafe.to_slice(ticks.size),
          3,
          2
        )
      end
      datetime_trace.should eq(typed_mark_readback_trace("Nullable(DateTime64(3))", true))
      datetime_reader = CrystalClick::WidePart.open_typed(datetime_part, "value")
      datetime_reader.read_nullable_datetime64_ticks_mark_range("value", 0, 3).should eq(ticks)
      datetime_reader.read_nullable_datetime64_ticks_mark_range("value", 1, 1).should eq(ticks[2, 2])
      typed_mark_readback_decoded_stream(datetime_part, "value.null").should eq([1_u8, 0_u8, 0_u8, 0_u8, 1_u8])
      typed_mark_readback_decoded_stream(datetime_part, "value").should eq(Bytes[
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xfe, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      ].to_a)
    end
  end

  it "keeps exact selector refusals read-only and rejects bad public input before staging" do
    with_typed_mark_readback_parent("refusal") do |parent|
      keys = [1_u64, 2_u64]
      values = [0x1234_u16, 0x5678_u16]
      source = File.join(parent, "source")
      CrystalClick::WidePartWriter.write_uint64_typed_pair(
        source,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "value",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 1
      )
      source_children = Dir.children(source).sort
      source_payload = File.read(File.join(source, "#{CrystalClick::StreamName.hash("value")}.bin"))
      part = CrystalClick::WidePart.open_typed(source, "value")

      expect_raises(CrystalClick::UnsupportedFormatError, "typed writer requires an exact UInt16 or Date payload") do
        CrystalClick::WidePartWriter.typed_mark_readback_test_read_numeric_mark(
          part,
          "value",
          0,
          values.to_unsafe.to_slice(values.size),
          "UInt8"
        )
      end
      Dir.children(source).sort.should eq(source_children)
      File.read(File.join(source, "#{CrystalClick::StreamName.hash("value")}.bin")).should eq(source_payload)

      rejected_target = File.join(parent, "rejected")
      expect_raises(ArgumentError, "columns must contain the same nonzero row count") do
        CrystalClick::WidePartWriter.write_uint64_typed_pair(
          rejected_target,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "value",
          [1_u16].to_unsafe.to_slice(1),
          rows_per_mark: 1
        )
      end
      Dir.exists?(rejected_target).should be_false

      existing_target = File.join(parent, "existing")
      Dir.mkdir(existing_target)
      File.write(File.join(existing_target, "keep.txt"), "do not replace")
      expect_raises(ArgumentError, "destination must not already exist") do
        CrystalClick::WidePartWriter.write_uint64_typed_pair(
          existing_target,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "value",
          values.to_unsafe.to_slice(values.size),
          rows_per_mark: 1
        )
      end
      File.read(File.join(existing_target, "keep.txt")).should eq("do not replace")
      Dir.children(parent).sort.should eq(["existing", "source"])
    end
  end

  it "preserves virtual dispatch through the supplied WidePart reader" do
    with_typed_mark_readback_parent("reader-dispatch") do |parent|
      keys = [1_u64, 2_u64]
      values = [0x0102_u16, 0x3040_u16]
      destination = File.join(parent, "date")
      CrystalClick::WidePartWriter.write_uint64_date_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "value",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 1
      )

      TypedMarkReadbackProbePart.date_code_read_calls = [] of Tuple(String, Int32, Int32)
      part = TypedMarkReadbackProbePart.open_typed(destination, "value")
      part.class.should eq(TypedMarkReadbackProbePart)
      CrystalClick::WidePartWriter.typed_mark_readback_test_read_numeric_mark(
        part,
        "value",
        1,
        values.to_unsafe.to_slice(values.size),
        "Date"
      ).should eq([values[1]])
      TypedMarkReadbackProbePart.date_code_read_calls.should eq([{"value", 1, 1}])
    end
  end
end
