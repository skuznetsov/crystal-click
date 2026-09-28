require "./spec_helper"

private def writer_w66_plain_values(type : T.class, scale : Int32) : Array(Array(Array(T))) forall T
  rows = [] of Array(Array(T))
  {% if T == Int32 %}
    rows << [] of Array(T)
    rows << [[] of T]
    rows << [[0_i32, -1_i32] of T]
    rows << [[3_599_999_i32] of T, [] of T]
    rows << [[] of T]
    rows << [] of Array(T)
    rows << [[Int32::MIN, Int32::MAX] of T]
  {% elsif T == Int64 %}
    factor = 1_i64
    scale.times { factor *= 10_i64 }
    limit = 3_599_999_i64 * factor
    rows << [] of Array(T)
    rows << [[] of T]
    rows << [[0_i64, -factor] of T]
    rows << [[limit] of T, [] of T]
    rows << [[] of T]
    rows << [] of Array(T)
    rows << [[Int64::MIN, Int64::MAX] of T]
  {% else %}
    {% raise "unsupported W66 writer scalar" %}
  {% end %}
  rows
end

private def writer_w66_nullable_values(type : T.class, scale : Int32) : Array(Array(Array(T?))) forall T
  rows = [] of Array(Array(T?))
  {% if T == Int32 %}
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, nil] of T?, [] of T?]
    rows << [[nil] of T?, [nil, nil] of T?]
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, Int32::MIN, 0_i32, Int32::MAX] of T?]
  {% elsif T == Int64 %}
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, nil] of T?, [] of T?]
    rows << [[nil] of T?, [nil, nil] of T?]
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, Int64::MIN, 0_i64, Int64::MAX] of T?]
  {% else %}
    {% raise "unsupported W66 nullable writer scalar" %}
  {% end %}
  rows
end

private def writer_w66_append_u64(io : IO, value : UInt64) : Nil
  8.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u64).to_u8) }
end

private def writer_w66_append_scalar(io : IO, value : T) : Nil forall T
  {% if T == Int32 %}
    bits = value.unsafe_as(UInt32).to_u64
    4.times { |byte| io.write_byte(((bits >> (byte * 8)) & 0xff_u64).to_u8) }
  {% elsif T == Int64 %}
    bits = value.unsafe_as(UInt64)
    8.times { |byte| io.write_byte(((bits >> (byte * 8)) & 0xff_u64).to_u8) }
  {% else %}
    {% raise "unsupported W66 writer scalar" %}
  {% end %}
end

private def writer_w66_expected_plain(values : Array(Array(Array(T)))) : {Array(UInt8), Array(UInt8), Array(UInt8)} forall T
  size0 = IO::Memory.new
  size1 = IO::Memory.new
  data = IO::Memory.new
  values.each do |row|
    writer_w66_append_u64(size0, row.size.to_u64)
    row.each do |inner|
      writer_w66_append_u64(size1, inner.size.to_u64)
      inner.each { |value| writer_w66_append_scalar(data, value) }
    end
  end
  {size0.to_slice.to_a, size1.to_slice.to_a, data.to_slice.to_a}
end

private def writer_w66_expected_nullable(values : Array(Array(Array(T?)))) : {Array(UInt8), Array(UInt8), Array(UInt8), Array(UInt8)} forall T
  size0 = IO::Memory.new
  size1 = IO::Memory.new
  nulls = IO::Memory.new
  data = IO::Memory.new
  values.each do |row|
    writer_w66_append_u64(size0, row.size.to_u64)
    row.each do |inner|
      writer_w66_append_u64(size1, inner.size.to_u64)
      inner.each do |value|
        if value.nil?
          nulls.write_byte(1_u8)
          writer_w66_append_scalar(data, T.zero)
        else
          nulls.write_byte(0_u8)
          writer_w66_append_scalar(data, value.not_nil!)
        end
      end
    end
  end
  {size0.to_slice.to_a, size1.to_slice.to_a, nulls.to_slice.to_a, data.to_slice.to_a}
end

private def writer_w66_write_plain(part : String, keys : Array(UInt64), values : Array(Array(Array(T))), scale : Int32) : Nil forall T
  key_slice = keys.to_unsafe.to_slice(keys.size)
  value_slice = values.to_unsafe.to_slice(values.size)
  {% if T == Int32 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_time_pair(part, "pk", key_slice, "payload", value_slice, rows_per_mark: 2)
  {% elsif T == Int64 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_time64_pair(part, "pk", key_slice, "payload", value_slice, scale, rows_per_mark: 2)
  {% else %}
    {% raise "unsupported W66 writer scalar" %}
  {% end %}
end

private def writer_w66_write_nullable(part : String, keys : Array(UInt64), values : Array(Array(Array(T?))), scale : Int32) : Nil forall T
  key_slice = keys.to_unsafe.to_slice(keys.size)
  value_slice = values.to_unsafe.to_slice(values.size)
  {% if T == Int32 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_time_pair(part, "pk", key_slice, "payload", value_slice, rows_per_mark: 2)
  {% elsif T == Int64 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_time64_pair(part, "pk", key_slice, "payload", value_slice, scale, rows_per_mark: 2)
  {% else %}
    {% raise "unsupported W66 nullable writer scalar" %}
  {% end %}
end

private def writer_w66_stream(part : String, stream : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice).to_a
end

private def writer_w66_check_marks(part : String, streams : Array(String)) : Nil
  streams.each do |stream|
    path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
    File.size(path).should eq(5 * CrystalClick::WidePart::MARK_SIZE)
    bytes = File.read(path).to_slice
    rows = Array(UInt64).new(5) do |mark|
      offset = mark * CrystalClick::WidePart::MARK_SIZE + 16
      8.times.reduce(0_u64) { |value, byte| value | (bytes[offset + byte].to_u64 << (byte * 8)) }
    end
    rows.should eq([2_u64, 2_u64, 2_u64, 1_u64, 0_u64])
  end
end

private def writer_w66_case(type : T.class, scale : Int32 = 0) : Nil forall T
  parent = File.tempname("crystal-click-wide-writer-w66")
  Dir.mkdir(parent)
  keys = (1_u64..7_u64).to_a
  plain_values = writer_w66_plain_values(T, scale)
  nullable_values = writer_w66_nullable_values(T, scale)
  plain_part = File.join(parent, "plain")
  nullable_part = File.join(parent, "nullable")
  leaf = {% if T == Int32 %} "Time" {% else %} "Time64(#{scale})" {% end %}
  plain_streams = writer_w66_expected_plain(plain_values)
  nullable_streams = writer_w66_expected_nullable(nullable_values)

  begin
    writer_w66_write_plain(plain_part, keys, plain_values, scale)
    writer_w66_write_nullable(nullable_part, keys, nullable_values, scale)
    File.read(File.join(plain_part, "columns.txt")).should eq("columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Array(Array(#{leaf}))\n")
    File.read(File.join(nullable_part, "columns.txt")).should eq("columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Array(Array(Nullable(#{leaf})))\n")
    {"payload.size0", "payload.size1", "payload"}.zip(plain_streams.to_a).each do |stream, expected|
      writer_w66_stream(plain_part, stream).should eq(expected)
    end
    {"payload.size0", "payload.size1", "payload.null", "payload"}.zip(nullable_streams.to_a).each do |stream, expected|
      writer_w66_stream(nullable_part, stream).should eq(expected)
    end
    writer_w66_check_marks(plain_part, ["pk", "payload.size0", "payload.size1", "payload"])
    writer_w66_check_marks(nullable_part, ["pk", "payload.size0", "payload.size1", "payload.null", "payload"])
  ensure
    FileUtils.rm_rf(parent.not_nil!)
  end
end

describe CrystalClick::WidePartWriter do
  it "emits exact two-level Time and Time64 streams, BASIC null children, and paired marks" do
    writer_w66_case(Int32)
    {0, 3, 9}.each { |scale| writer_w66_case(Int64, scale) }
  end

  it "rejects invalid Time64 scale and unsorted keys without publishing a part" do
    parent = File.tempname("crystal-click-wide-writer-w66-reject")
    Dir.mkdir(parent)
    target = File.join(parent, "invalid-scale")
    keys = [1_u64]
    values = [[[0_i64]]] of Array(Array(Int64))
    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_array_time64_pair(
          target, "pk", keys.to_unsafe.to_slice(1), "payload", values.to_unsafe.to_slice(1), 10, rows_per_mark: 1
        )
      end
      File.exists?(target).should be_false

      unsorted = File.join(parent, "unsorted")
      bad_keys = [2_u64, 1_u64]
      bad_values = [[[0_i32]], [[1_i32]]] of Array(Array(Int32))
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_array_time_pair(
          unsorted, "pk", bad_keys.to_unsafe.to_slice(2), "payload", bad_values.to_unsafe.to_slice(2), rows_per_mark: 1
        )
      end
      File.exists?(unsorted).should be_false
    ensure
      FileUtils.rm_rf(parent.not_nil!)
    end
  end
end
