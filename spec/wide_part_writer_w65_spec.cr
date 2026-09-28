require "./spec_helper"

private def writer_w65_values(type : T.class) : Array(Array(Array(T))) forall T
  rows = [] of Array(Array(T))
  {% if T == UInt16 %}
    rows << [] of Array(T)
    rows << [[] of T]
    rows << [[0_u16, UInt16::MAX] of T]
    rows << [[] of T]
    rows << [[1_u16] of T, [] of T]
    rows << [] of Array(T)
    rows << [[UInt16::MAX] of T]
  {% elsif T == Int32 %}
    rows << [] of Array(T)
    rows << [[] of T]
    rows << [[Int32::MIN, Int32::MAX] of T]
    rows << [[] of T]
    rows << [[-1_i32] of T, [] of T]
    rows << [] of Array(T)
    rows << [[Int32::MAX] of T]
  {% elsif T == UInt32 %}
    rows << [] of Array(T)
    rows << [[] of T]
    rows << [[0_u32, UInt32::MAX] of T]
    rows << [[] of T]
    rows << [[1_u32] of T, [] of T]
    rows << [] of Array(T)
    rows << [[UInt32::MAX] of T]
  {% elsif T == Int64 %}
    rows << [] of Array(T)
    rows << [[] of T]
    rows << [[Int64::MIN, Int64::MAX] of T]
    rows << [[] of T]
    rows << [[-1_i64] of T, [] of T]
    rows << [] of Array(T)
    rows << [[Int64::MAX] of T]
  {% else %}
    {% raise "unsupported W65 test type" %}
  {% end %}
  rows
end

private def writer_w65_nullable_values(type : T.class) : Array(Array(Array(T?))) forall T
  rows = [] of Array(Array(T?))
  {% if T == UInt16 %}
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, nil] of T?]
    rows << [[nil] of T?, [nil, nil] of T?]
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[UInt16::MAX, 0_u16, nil] of T?]
  {% elsif T == Int32 %}
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, nil] of T?]
    rows << [[nil] of T?, [nil, nil] of T?]
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[Int32::MAX, 0_i32, nil] of T?]
  {% elsif T == UInt32 %}
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, nil] of T?]
    rows << [[nil] of T?, [nil, nil] of T?]
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[UInt32::MAX, 0_u32, nil] of T?]
  {% elsif T == Int64 %}
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[nil, nil] of T?]
    rows << [[nil] of T?, [nil, nil] of T?]
    rows << [] of Array(T?)
    rows << [[] of T?]
    rows << [[Int64::MAX, 0_i64, nil] of T?]
  {% else %}
    {% raise "unsupported W65 nullable test type" %}
  {% end %}
  rows
end

private def writer_w65_append_u64(io : IO, value : UInt64) : Nil
  8.times { |byte| io.write_byte(((value >> (byte * 8)) & 0xff_u64).to_u8) }
end

private def writer_w65_append_leaf(io : IO, value : T) : Nil forall T
  bits = 0_u64
  width = 0
  {% if T == UInt16 %}
    bits = value.to_u64
    width = 2
  {% elsif T == Int32 %}
    bits = value.unsafe_as(UInt32).to_u64
    width = 4
  {% elsif T == UInt32 %}
    bits = value.to_u64
    width = 4
  {% elsif T == Int64 %}
    bits = value.unsafe_as(UInt64)
    width = 8
  {% else %}
    {% raise "unsupported W65 scalar encoding" %}
  {% end %}
  width.times { |byte| io.write_byte(((bits >> (byte * 8)) & 0xff_u64).to_u8) }
end

private def writer_w65_expected_streams(values : Array(Array(Array(T)))) : {Array(UInt8), Array(UInt8), Array(UInt8)} forall T
  size0 = IO::Memory.new
  size1 = IO::Memory.new
  leaf = IO::Memory.new
  values.each do |row|
    writer_w65_append_u64(size0, row.size.to_u64)
    row.each do |inner|
      writer_w65_append_u64(size1, inner.size.to_u64)
      inner.each { |value| writer_w65_append_leaf(leaf, value) }
    end
  end
  {size0.to_slice.to_a, size1.to_slice.to_a, leaf.to_slice.to_a}
end

private def writer_w65_expected_nullable_streams(values : Array(Array(Array(T?)))) : {Array(UInt8), Array(UInt8), Array(UInt8), Array(UInt8)} forall T
  size0 = IO::Memory.new
  size1 = IO::Memory.new
  nulls = IO::Memory.new
  leaf = IO::Memory.new
  values.each do |row|
    writer_w65_append_u64(size0, row.size.to_u64)
    row.each do |inner|
      writer_w65_append_u64(size1, inner.size.to_u64)
      inner.each do |value|
        if value.nil?
          nulls.write_byte(1_u8)
          writer_w65_append_leaf(leaf, T.zero)
        else
          nulls.write_byte(0_u8)
          writer_w65_append_leaf(leaf, value.not_nil!)
        end
      end
    end
  end
  {size0.to_slice.to_a, size1.to_slice.to_a, nulls.to_slice.to_a, leaf.to_slice.to_a}
end

private def writer_w65_stream(part : String, logical_stream : String) : Array(UInt8)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_stream)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(path).to_slice).to_a
end

private def writer_w65_mark_field(part : String, logical_stream : String, field_offset : Int32) : Array(UInt64)
  path = File.join(part, "#{CrystalClick::StreamName.hash(logical_stream)}.mrk2")
  bytes = File.read(path).to_slice
  raise "invalid W65 mark file for #{logical_stream}" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE + field_offset
    value = 0_u64
    8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
    value
  end
end

private def writer_w65_write_plain(part : String, keys : Array(UInt64), values : Array(Array(Array(T))), scale : Int32) : Nil forall T
  key_slice = keys.to_unsafe.to_slice(keys.size)
  value_slice = values.to_unsafe.to_slice(values.size)
  {% if T == UInt16 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_date_pair(part, "pk", key_slice, "payload", value_slice, rows_per_mark: 2)
  {% elsif T == Int32 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_date32_pair(part, "pk", key_slice, "payload", value_slice, rows_per_mark: 2)
  {% elsif T == UInt32 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_datetime_pair(part, "pk", key_slice, "payload", value_slice, rows_per_mark: 2)
  {% elsif T == Int64 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_datetime64_pair(part, "pk", key_slice, "payload", value_slice, scale, rows_per_mark: 2)
  {% else %}
    {% raise "unsupported W65 writer type" %}
  {% end %}
  nil
end

private def writer_w65_write_nullable(part : String, keys : Array(UInt64), values : Array(Array(Array(T?))), scale : Int32) : Nil forall T
  key_slice = keys.to_unsafe.to_slice(keys.size)
  value_slice = values.to_unsafe.to_slice(values.size)
  {% if T == UInt16 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_date_pair(part, "pk", key_slice, "payload", value_slice, rows_per_mark: 2)
  {% elsif T == Int32 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_date32_pair(part, "pk", key_slice, "payload", value_slice, rows_per_mark: 2)
  {% elsif T == UInt32 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_datetime_pair(part, "pk", key_slice, "payload", value_slice, rows_per_mark: 2)
  {% elsif T == Int64 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_datetime64_pair(part, "pk", key_slice, "payload", value_slice, scale, rows_per_mark: 2)
  {% else %}
    {% raise "unsupported W65 nullable writer type" %}
  {% end %}
  nil
end

private def writer_w65_assert_marks(part : String, streams : Array(String), nullable : Bool) : Nil
  streams.each do |stream|
    mark_path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
    File.size(mark_path).should eq(5 * CrystalClick::WidePart::MARK_SIZE)
    writer_w65_mark_field(part, stream, 16).should eq([2_u64, 2_u64, 2_u64, 1_u64, 0_u64])
  end
  if nullable
    writer_w65_stream(part, "payload.null")[0, 5].should eq([1_u8, 1_u8, 1_u8, 1_u8, 1_u8])
  end
end

private def writer_w65_case(type : T.class, type_name : String, scale : Int32 = 3) : Nil forall T
  parent = File.tempname("crystal-click-wide-writer-w65")
  Dir.mkdir(parent)
  keys = (1_u64..7_u64).to_a
  plain = writer_w65_values(T)
  nullable = writer_w65_nullable_values(T)
  plain_part = File.join(parent, "plain")
  nullable_part = File.join(parent, "nullable")
  leaf_type = type_name == "DateTime64" ? "DateTime64(#{scale})" : type_name

  begin
    writer_w65_write_plain(plain_part, keys, plain, scale)
    writer_w65_write_nullable(nullable_part, keys, nullable, scale)

    plain_type = "Array(Array(#{leaf_type}))"
    nullable_type = "Array(Array(Nullable(#{leaf_type})))"
    File.read(File.join(plain_part, "columns.txt")).should eq(
      "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{plain_type}\n"
    )
    File.read(File.join(nullable_part, "columns.txt")).should eq(
      "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{nullable_type}\n"
    )
    plain_streams = writer_w65_expected_streams(plain)
    {"payload.size0", "payload.size1", "payload"}.zip(plain_streams.to_a).each do |stream, expected|
      writer_w65_stream(plain_part, stream).should eq(expected)
    end
    nullable_streams = writer_w65_expected_nullable_streams(nullable)
    {"payload.size0", "payload.size1", "payload.null", "payload"}.zip(nullable_streams.to_a).each do |stream, expected|
      writer_w65_stream(nullable_part, stream).should eq(expected)
    end
    expected_plain_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n3 substreams for column `payload`:\n\tpayload.size0\n\tpayload.size1\n\tpayload\n"
    expected_nullable_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n4 substreams for column `payload`:\n\tpayload.size0\n\tpayload.size1\n\tpayload.null\n\tpayload\n"
    File.read(File.join(plain_part, "columns_substreams.txt")).should eq(expected_plain_substreams)
    File.read(File.join(nullable_part, "columns_substreams.txt")).should eq(expected_nullable_substreams)
    writer_w65_assert_marks(plain_part, ["payload.size0", "payload.size1", "payload"], false)
    writer_w65_assert_marks(nullable_part, ["payload.size0", "payload.size1", "payload.null", "payload"], true)
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe CrystalClick::WidePartWriter do
  it "writes paired two-level temporal Arrays with exact raw streams, null maps, and plain mrk2 granules" do
    writer_w65_case(UInt16, "Date")
    writer_w65_case(Int32, "Date32")
    writer_w65_case(UInt32, "DateTime")
    {0, 3, 9}.each { |scale| writer_w65_case(Int64, "DateTime64", scale) }
  end

  it "rejects invalid DateTime64 precision and malformed input before creating a stage" do
    parent = File.tempname("crystal-click-wide-writer-w65-reject")
    Dir.mkdir(parent)
    keys = [1_u64]
    values = [[[Int64::MIN] of Int64]]

    begin
      {-1, 10}.each do |scale|
        expect_raises(ArgumentError) do
          CrystalClick::WidePartWriter.write_uint64_array_array_datetime64_pair(
            File.join(parent, "bad-#{scale}"), "pk", keys.to_unsafe.to_slice(1), "payload",
            values.to_unsafe.to_slice(1), scale, rows_per_mark: 1
          )
        end
      end
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_array_datetime64_pair(
          File.join(parent, "bad-rows"), "pk", keys.to_unsafe.to_slice(1), "payload",
          ([] of Array(Array(Int64))).to_unsafe.to_slice(0), 3, rows_per_mark: 1
        )
      end

      existing = File.join(parent, "existing")
      Dir.mkdir(existing)
      File.write(File.join(existing, "marker"), "preserve")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_array_datetime64_pair(
          existing, "pk", keys.to_unsafe.to_slice(1), "payload",
          values.to_unsafe.to_slice(1), 3, rows_per_mark: 1
        )
      end
      File.read(File.join(existing, "marker")).should eq("preserve")
      Dir.children(parent).should eq(["existing"])
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
