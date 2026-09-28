require "./spec_helper"

private def writer_w60_width(type : T.class) : Int32 forall T
  {% if T == UInt8 || T == Int8 %}
    1
  {% elsif T == UInt16 || T == Int16 %}
    2
  {% elsif T == UInt32 || T == Int32 || T == Float32 %}
    4
  {% elsif T == UInt64 || T == Int64 || T == Float64 %}
    8
  {% else %}
    raise "unexpected W60 test type"
  {% end %}
end

private def writer_w60_append_value(bytes : Array(UInt8), value : T) : Nil forall T
  {% if T == UInt8 %}
    bytes << value
  {% elsif T == UInt16 %}
    2.times { |byte| bytes << ((value >> (byte * 8)) & 0xff_u16).to_u8 }
  {% elsif T == UInt32 %}
    4.times { |byte| bytes << ((value >> (byte * 8)) & 0xff_u32).to_u8 }
  {% elsif T == UInt64 %}
    8.times { |byte| bytes << ((value >> (byte * 8)) & 0xff_u64).to_u8 }
  {% elsif T == Int8 %}
    bytes << value.unsafe_as(UInt8)
  {% elsif T == Int16 %}
    bits = value.unsafe_as(UInt16)
    2.times { |byte| bytes << ((bits >> (byte * 8)) & 0xff_u16).to_u8 }
  {% elsif T == Int32 %}
    bits = value.unsafe_as(UInt32)
    4.times { |byte| bytes << ((bits >> (byte * 8)) & 0xff_u32).to_u8 }
  {% elsif T == Int64 %}
    bits = value.unsafe_as(UInt64)
    8.times { |byte| bytes << ((bits >> (byte * 8)) & 0xff_u64).to_u8 }
  {% elsif T == Float32 %}
    bits = value.unsafe_as(UInt32)
    4.times { |byte| bytes << ((bits >> (byte * 8)) & 0xff_u32).to_u8 }
  {% elsif T == Float64 %}
    bits = value.unsafe_as(UInt64)
    8.times { |byte| bytes << ((bits >> (byte * 8)) & 0xff_u64).to_u8 }
  {% else %}
    raise "unexpected W60 test type"
  {% end %}
end

private def writer_w60_expected_streams(values : Array(Array(Array(T?)))) : {Array(UInt8), Array(UInt8)} forall T
  nulls = [] of UInt8
  data = [] of UInt8
  width = writer_w60_width(T)
  values.each do |row|
    row.each do |inner|
      inner.each do |value|
        if value.nil?
          nulls << 1_u8
          width.times { data << 0_u8 }
        else
          nulls << 0_u8
          writer_w60_append_value(data, value.not_nil!)
        end
      end
    end
  end
  {nulls, data}
end

private def writer_w60_value_equal?(expected : T?, actual : T?) : Bool forall T
  return expected.nil? && actual.nil? if expected.nil? || actual.nil?
  {% if T == Float32 %}
    expected.not_nil!.unsafe_as(UInt32) == actual.not_nil!.unsafe_as(UInt32)
  {% elsif T == Float64 %}
    expected.not_nil!.unsafe_as(UInt64) == actual.not_nil!.unsafe_as(UInt64)
  {% else %}
    expected == actual
  {% end %}
end

private def writer_w60_values_equal?(expected : Array(Array(Array(T?))), actual : Array(Array(Array(T?)))) : Bool forall T
  return false unless expected.size == actual.size
  expected.each_with_index do |row, row_index|
    observed_row = actual[row_index]
    return false unless row.size == observed_row.size
    row.each_with_index do |inner, inner_index|
      observed_inner = observed_row[inner_index]
      return false unless inner.size == observed_inner.size
      inner.each_with_index do |value, value_index|
        return false unless writer_w60_value_equal?(value, observed_inner[value_index])
      end
    end
  end
  true
end

private def writer_w60_mark_rows(path : String, logical_stream : String) : Array(UInt64)
  mark_path = File.join(path, "#{CrystalClick::StreamName.hash(logical_stream)}.mrk2")
  bytes = File.read(mark_path).to_slice
  raise "invalid W60 writer mark file" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE + 16
    value = 0_u64
    8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
    value
  end
end

private def writer_w60_mark_offsets(path : String, logical_stream : String) : Array(UInt64)
  mark_path = File.join(path, "#{CrystalClick::StreamName.hash(logical_stream)}.mrk2")
  bytes = File.read(mark_path).to_slice
  raise "invalid W60 writer mark file" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE
    value = 0_u64
    8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
    value
  end
end

private def write_w60_writer_case(samples : Array(T?), type_name : String, label : String) : Nil forall T
  raise "W60 writer cases require two sample values" unless samples.size == 2
  parent = File.tempname("crystal-click-wide-writer-w60-#{label}")
  Dir.mkdir(parent)
  destination = File.join(parent, "part")
  keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
  values = Array(Array(Array(T?))).new(7) { [] of Array(T?) }
  values[0] = [[samples[0], nil] of T?, [] of T?]
  values[2] = [[nil, nil] of T?]
  values[3] = [[nil] of T?]
  values[6] = [[samples[1], nil] of T?]

  begin
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_numeric_pair(
      destination,
      "pk",
      keys.to_unsafe.to_slice(keys.size),
      "payload",
      values.to_unsafe.to_slice(values.size),
      rows_per_mark: 2
    )

    reader = CrystalClick::WidePart.open_typed(destination, "payload")
    reader.column_type.should eq("Array(Array(Nullable(#{type_name})))")
    reader.row_count.should eq(7_u64)
    reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    observed = reader.read_array_array_nullable_numeric_mark_range("payload", 0, reader.mark_count, T)
    writer_w60_values_equal?(values, observed).should be_true

    expected_nulls, expected_data = writer_w60_expected_streams(values)
    null_path = File.join(destination, "#{CrystalClick::StreamName.hash("payload.null")}.bin")
    CrystalClick::CompressedBlock.decode_all(File.read(null_path).to_slice).to_a.should eq(expected_nulls)
    value_path = File.join(destination, "#{CrystalClick::StreamName.hash("payload")}.bin")
    CrystalClick::CompressedBlock.decode_all(File.read(value_path).to_slice).to_a.should eq(expected_data)

    expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n4 substreams for column `payload`:\n\tpayload.size0\n\tpayload.size1\n\tpayload.null\n\tpayload\n"
    File.read(File.join(destination, "columns_substreams.txt")).should eq(expected_substreams)
    File.read(File.join(destination, "columns.txt")).should eq("columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Array(Array(Nullable(#{type_name})))\n")

    {"payload.size0", "payload.size1", "payload.null", "payload"}.each do |stream|
      writer_w60_mark_rows(destination, stream).should eq([2_u64, 2_u64, 2_u64, 1_u64, 0_u64])
    end
    {"payload.size1", "payload.null", "payload"}.each do |stream|
      offsets = writer_w60_mark_offsets(destination, stream)
      offsets[2].should eq(offsets[3])
    end
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe CrystalClick::WidePartWriter do
  it "writes the exact W60 nullable primitive numeric Array family" do
    write_w60_writer_case([0_u8, UInt8::MAX] of UInt8?, "UInt8", "uint8")
    write_w60_writer_case([0_u16, UInt16::MAX] of UInt16?, "UInt16", "uint16")
    write_w60_writer_case([0_u32, UInt32::MAX] of UInt32?, "UInt32", "uint32")
    write_w60_writer_case([0_u64, UInt64::MAX] of UInt64?, "UInt64", "uint64")
    write_w60_writer_case([Int8::MIN, -1_i8] of Int8?, "Int8", "int8")
    write_w60_writer_case([Int16::MIN, -1_i16] of Int16?, "Int16", "int16")
    write_w60_writer_case([Int32::MIN, -1_i32] of Int32?, "Int32", "int32")
    write_w60_writer_case([Int64::MIN, -1_i64] of Int64?, "Int64", "int64")
    write_w60_writer_case([0x8000_0000_u32.unsafe_as(Float32), 0x7fc1_2345_u32.unsafe_as(Float32)] of Float32?, "Float32", "float32")
    write_w60_writer_case([0x8000_0000_0000_0000_u64.unsafe_as(Float64), 0x7ff8_0000_0000_1234_u64.unsafe_as(Float64)] of Float64?, "Float64", "float64")
  end

  it "rejects nullable numeric leaves outside the W60 primitive profile before staging" do
    parent = File.tempname("crystal-click-wide-writer-w60-reject")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64]
    values = [[[1_i128] of Int128?] of Array(Int128?)] of Array(Array(Int128?))

    begin
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_array_array_nullable_numeric_pair(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "payload",
          values.to_unsafe.to_slice(values.size),
          rows_per_mark: 1
        )
      end
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
