require "./spec_helper"

private def w96_tuple_append_le(bytes : Array(UInt8), value : UInt128, width : Int32) : Nil
  width.times do |index|
    bytes << ((value >> (index * 8)) & 0xff_u128).to_u8
  end
end

private def w96_tuple_numeric_bytes(values : Array(T)) : Array(UInt8) forall T
  bytes = [] of UInt8
  values.each do |value|
    {% if T == UInt8 %}
      bytes << value
    {% elsif T == Int8 %}
      bytes << value.unsafe_as(UInt8)
    {% elsif T == UInt16 %}
      w96_tuple_append_le(bytes, value.to_u128, 2)
    {% elsif T == Int16 %}
      w96_tuple_append_le(bytes, value.unsafe_as(UInt16).to_u128, 2)
    {% elsif T == UInt32 %}
      w96_tuple_append_le(bytes, value.to_u128, 4)
    {% elsif T == Int32 %}
      w96_tuple_append_le(bytes, value.unsafe_as(UInt32).to_u128, 4)
    {% elsif T == UInt64 %}
      w96_tuple_append_le(bytes, value.to_u128, 8)
    {% elsif T == Int64 %}
      w96_tuple_append_le(bytes, value.unsafe_as(UInt64).to_u128, 8)
    {% elsif T == UInt128 %}
      w96_tuple_append_le(bytes, value, 16)
    {% elsif T == Int128 %}
      w96_tuple_append_le(bytes, value.unsafe_as(UInt128), 16)
    {% elsif T == CrystalClick::Int256Value || T == CrystalClick::UInt256Value %}
      w96_tuple_append_le(bytes, value.low, 16)
      w96_tuple_append_le(bytes, value.high, 16)
    {% elsif T == Float32 %}
      w96_tuple_append_le(bytes, value.unsafe_as(UInt32).to_u128, 4)
    {% elsif T == Float64 %}
      w96_tuple_append_le(bytes, value.unsafe_as(UInt64).to_u128, 8)
    {% elsif T == CrystalClick::BFloat16Value %}
      w96_tuple_append_le(bytes, value.bits.to_u128, 2)
    {% else %}
      {% raise "unsupported W96 fixture type" %}
    {% end %}
  end
  bytes
end

private def w96_tuple_u64_bytes(values : Array(UInt64)) : Array(UInt8)
  w96_tuple_numeric_bytes(values)
end

private def w96_tuple_read_u64(bytes : Bytes, offset : Int) : UInt64
  value = 0_u64
  8.times { |index| value |= bytes[offset + index].to_u64 << (index * 8) }
  value
end

private def w96_tuple_stream_bytes(part : String, stream : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  encoded = File.read(path).to_slice
  return [] of UInt8 if encoded.empty?
  CrystalClick::CompressedBlock.decode_all(encoded).to_a
end

private def w96_tuple_marks(part : String, stream : String) : Array(Tuple(UInt64, UInt64, UInt64))
  bytes = File.read(File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")).to_slice
  raise "malformed W96 mark file for #{stream}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(Tuple(UInt64, UInt64, UInt64)).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    {
      w96_tuple_read_u64(bytes, offset),
      w96_tuple_read_u64(bytes, offset + 8),
      w96_tuple_read_u64(bytes, offset + 16),
    }
  end
end

private def w96_tuple_type(columns : Array(CrystalClick::WideTupleLeafColumn)) : String
  "Tuple(#{columns.map { |column| "#{column.name} #{column.type_name}" }.join(", ")})"
end

private def w96_tuple_streams(columns : Array(CrystalClick::WideTupleLeafColumn)) : Array(String)
  streams = [] of String
  columns.each do |column|
    leaf_stream = "payload%2E#{column.name}"
    streams << "#{leaf_stream}.size" if column.type_name == "String"
    streams << leaf_stream
  end
  streams
end

private def w96_tuple_counting_factory(calls : Array(Int32)) : Proc(String, String)
  ->(parent : String) do
    calls << 1
    stage = File.tempname(".w96-numeric-tuple-stage-", nil, dir: parent)
    Dir.mkdir(stage)
    stage
  end
end

private def w96_tuple_counting_string_copy(
  calls : Array(Int32),
) : Proc(CrystalClick::WideTupleLeafColumn, Array(String))
  ->(column : CrystalClick::WideTupleLeafColumn) do
    calls << 1
    column.string_values
  end
end

module CrystalClick
  module WidePartWriter
    def self.w96_test_write_uint64_tuple_pair_with_stage_factory(
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
        destination, key_name, keys, value_name, type_name, columns, rows_per_mark,
        stage_factory, copy_string_values
      )
    end
  end
end

describe CrystalClick::WidePartWriter do
  it "writes every admitted numeric Tuple leaf with exact bytes, widths, marks and raw-bit readback" do
    columns = [] of CrystalClick::WideTupleLeafColumn
    expected_raw = {} of String => Tuple(Array(UInt8), Int32, UInt64)

    add_numeric = ->(column : CrystalClick::WideTupleLeafColumn, raw : Array(UInt8), width : Int32) do
      columns << column
      expected_raw["payload%2E#{column.name}"] = {raw, width, raw.size.to_u64}
    end

    add_numeric.call(CrystalClick::WideTupleLeafColumn.new("i8", [0_i8, Int8::MIN, Int8::MAX]), w96_tuple_numeric_bytes([0_i8, Int8::MIN, Int8::MAX]), 1)
    add_numeric.call(CrystalClick::WideTupleLeafColumn.new("u8", [0_u8, 0x80_u8, UInt8::MAX]), w96_tuple_numeric_bytes([0_u8, 0x80_u8, UInt8::MAX]), 1)
    add_numeric.call(CrystalClick::WideTupleLeafColumn.new("i16", [0_i16, Int16::MIN, Int16::MAX]), w96_tuple_numeric_bytes([0_i16, Int16::MIN, Int16::MAX]), 2)
    add_numeric.call(CrystalClick::WideTupleLeafColumn.new("u16", [0_u16, 0x8000_u16, UInt16::MAX]), w96_tuple_numeric_bytes([0_u16, 0x8000_u16, UInt16::MAX]), 2)
    add_numeric.call(CrystalClick::WideTupleLeafColumn.new("i32", [0_i32, Int32::MIN, Int32::MAX]), w96_tuple_numeric_bytes([0_i32, Int32::MIN, Int32::MAX]), 4)
    add_numeric.call(CrystalClick::WideTupleLeafColumn.new("u32", [0_u32, 0x8000_0000_u32, UInt32::MAX]), w96_tuple_numeric_bytes([0_u32, 0x8000_0000_u32, UInt32::MAX]), 4)
    add_numeric.call(CrystalClick::WideTupleLeafColumn.new("i64", [0_i64, Int64::MIN, Int64::MAX]), w96_tuple_numeric_bytes([0_i64, Int64::MIN, Int64::MAX]), 8)
    add_numeric.call(CrystalClick::WideTupleLeafColumn.new("u64", [0_u64, 1_u64 << 63, UInt64::MAX]), w96_tuple_numeric_bytes([0_u64, 1_u64 << 63, UInt64::MAX]), 8)
    add_numeric.call(CrystalClick::WideTupleLeafColumn.new("i128", [0_i128, Int128::MIN, Int128::MAX]), w96_tuple_numeric_bytes([0_i128, Int128::MIN, Int128::MAX]), 16)
    add_numeric.call(CrystalClick::WideTupleLeafColumn.new("u128", [0_u128, 1_u128 << 127, UInt128::MAX]), w96_tuple_numeric_bytes([0_u128, 1_u128 << 127, UInt128::MAX]), 16)
    add_numeric.call(CrystalClick::WideTupleLeafColumn.new("i256", [CrystalClick::Int256Value.new(0_u128, 0_u128), CrystalClick::Int256Value.new(0_u128, 1_u128 << 127), CrystalClick::Int256Value.new(UInt128::MAX, UInt128::MAX)] of CrystalClick::Int256Value), w96_tuple_numeric_bytes([CrystalClick::Int256Value.new(0_u128, 0_u128), CrystalClick::Int256Value.new(0_u128, 1_u128 << 127), CrystalClick::Int256Value.new(UInt128::MAX, UInt128::MAX)] of CrystalClick::Int256Value), 32)
    add_numeric.call(CrystalClick::WideTupleLeafColumn.new("u256", [CrystalClick::UInt256Value.new(0_u128, 0_u128), CrystalClick::UInt256Value.new(0_u128, 1_u128 << 127), CrystalClick::UInt256Value.new(UInt128::MAX, UInt128::MAX)] of CrystalClick::UInt256Value), w96_tuple_numeric_bytes([CrystalClick::UInt256Value.new(0_u128, 0_u128), CrystalClick::UInt256Value.new(0_u128, 1_u128 << 127), CrystalClick::UInt256Value.new(UInt128::MAX, UInt128::MAX)] of CrystalClick::UInt256Value), 32)
    float32_values = [0.0_f32, 0x8000_0000_u32.unsafe_as(Float32), 0x7fc0_1234_u32.unsafe_as(Float32)]
    add_numeric.call(CrystalClick::WideTupleLeafColumn.new("f32", float32_values), w96_tuple_numeric_bytes(float32_values), 4)
    float64_values = [0.0_f64, 0x8000_0000_0000_0000_u64.unsafe_as(Float64), 0x7ff8_0000_0000_1234_u64.unsafe_as(Float64)]
    add_numeric.call(CrystalClick::WideTupleLeafColumn.new("f64", float64_values), w96_tuple_numeric_bytes(float64_values), 8)
    bfloat_values = [CrystalClick::BFloat16Value.new(0_u16), CrystalClick::BFloat16Value.new(0x8000_u16), CrystalClick::BFloat16Value.new(0x7fc1_u16)]
    add_numeric.call(CrystalClick::WideTupleLeafColumn.new("bf16", bfloat_values), w96_tuple_numeric_bytes(bfloat_values), 2)

    text_values = ["", "a\0b", String.new(Bytes[0xff_u8, 0_u8])]
    columns << CrystalClick::WideTupleLeafColumn.new("text", text_values)
    size_bytes = w96_tuple_u64_bytes([0_u64, 3_u64, 2_u64])
    text_bytes = text_values.map { |value| value.to_slice.to_a }.flatten
    expected_raw["payload%2Etext.size"] = {size_bytes, 8, size_bytes.size.to_u64}
    expected_raw["payload%2Etext"] = {text_bytes, 1, text_bytes.size.to_u64}

    keys = [0_u64, 3_u64, 9_u64]
    type_name = w96_tuple_type(columns)
    parent = File.tempname("crystal-click-wide-writer-numeric-tuple-w96")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")

    begin
      CrystalClick::WidePartWriter.write_uint64_tuple_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", type_name, columns,
        rows_per_mark: 2
      ).should eq(destination)

      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{type_name}\n"
      )
      streams = w96_tuple_streams(columns)
      expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n#{streams.size} substreams for column `payload`:\n"
      streams.each { |stream| expected_substreams += "\t#{stream}\n" }
      File.read(File.join(destination, "columns_substreams.txt")).should eq(expected_substreams)

      w96_tuple_stream_bytes(destination, "pk").should eq(w96_tuple_u64_bytes(keys))
      w96_tuple_marks(destination, "pk").map(&.[2]).should eq([2_u64, 1_u64, 0_u64])
      streams.each do |stream|
        raw, width, expected_uncompressed_size = expected_raw[stream]
        w96_tuple_stream_bytes(destination, stream).should eq(raw)
        w96_tuple_marks(destination, stream).map(&.[2]).should eq([2_u64, 1_u64, 0_u64])
        entry = CrystalClick::PartChecksums.open(destination).entries["#{CrystalClick::StreamName.hash(stream)}.bin"]
        entry.uncompressed_size.not_nil!.should eq(expected_uncompressed_size)
        is_raw_string = columns.any? do |column|
          column.type_name == "String" && stream == "payload%2E#{column.name}"
        end
        raw.size.should eq(keys.size * width) unless is_raw_string
      end
      CrystalClick::PartChecksums.open(destination).entries["#{CrystalClick::StreamName.hash("pk")}.bin"].uncompressed_size.not_nil!.should eq(24_u64)

      serialization = JSON.parse(File.read(File.join(destination, "serialization.json"))).as_h
      payload_record = serialization["columns"].as_a.find do |record|
        record.as_h["name"]?.try(&.as_s) == "payload"
      end.not_nil!.as_h
      payload_record["num_defaults"].as_i.should eq(1)
      payload_record["subcolumns"].as_a.map { |record| record.as_h["num_defaults"].as_i }.should eq(Array.new(columns.size, 1_i64))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects numeric nominal and row mismatches before creating a stage or copying String leaves" do
    parent = File.tempname("crystal-click-wide-writer-numeric-tuple-invalid")
    Dir.mkdir(parent)
    factory_calls = [] of Int32
    string_snapshot_calls = [] of Int32
    factory = w96_tuple_counting_factory(factory_calls)
    copy_strings = w96_tuple_counting_string_copy(string_snapshot_calls)
    keys = [1_u64, 2_u64]

    begin
      wrong_nominal = [CrystalClick::WideTupleLeafColumn.new("n", [1_i8, 2_i8])] of CrystalClick::WideTupleLeafColumn
      expect_raises(ArgumentError, "Tuple leaf buffers do not match schema order") do
        CrystalClick::WidePartWriter.w96_test_write_uint64_tuple_pair_with_stage_factory(
          File.join(parent, "nominal"), "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          "Tuple(n UInt8)", wrong_nominal, 1, factory, copy_strings
        )
      end

      wrong_rows = [
        CrystalClick::WideTupleLeafColumn.new("n", [1_i16, 2_i16]),
        CrystalClick::WideTupleLeafColumn.new("text", ["only one"] of String),
      ] of CrystalClick::WideTupleLeafColumn
      expect_raises(ArgumentError, "Tuple leaf buffers must match key row count") do
        CrystalClick::WidePartWriter.w96_test_write_uint64_tuple_pair_with_stage_factory(
          File.join(parent, "rows"), "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          w96_tuple_type(wrong_rows), wrong_rows, 1, factory, copy_strings
        )
      end

      factory_calls.should be_empty
      string_snapshot_calls.should be_empty
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "charges 256-bit leaf width against the combined result and key budget before staging" do
    parent = File.tempname("crystal-click-wide-writer-numeric-tuple-budget")
    Dir.mkdir(parent)
    factory_calls = [] of Int32
    string_snapshot_calls = [] of Int32
    factory = w96_tuple_counting_factory(factory_calls)
    copy_strings = w96_tuple_counting_string_copy(string_snapshot_calls)
    row_count = 1_400_000
    keys = Array(UInt64).new(row_count) { |index| index.to_u64 }
    values = Array(CrystalClick::Int256Value).new(row_count) { CrystalClick::Int256Value.new(0_u128, 0_u128) }
    columns = [CrystalClick::WideTupleLeafColumn.new("wide", values)] of CrystalClick::WideTupleLeafColumn
    destination = File.join(parent, "over-budget")

    begin
      expect_raises(ArgumentError, "Tuple materialization charge exceeds limit") do
        CrystalClick::WidePartWriter.w96_test_write_uint64_tuple_pair_with_stage_factory(
          destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload", w96_tuple_type(columns),
          columns, 8192, factory, copy_strings
        )
      end
      factory_calls.should be_empty
      string_snapshot_calls.should be_empty
      File.exists?(destination).should be_false
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
