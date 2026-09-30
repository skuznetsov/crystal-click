require "./spec_helper"

private def w64_shift_mark_decompressed_offset(path : String, stream : String, mark_index : Int) : Nil
  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE + 8
  value = 0_u64
  8.times { |index| value |= marks[offset + index].to_u64 << (index * 8) }
  8.times { |index| marks[offset + index] = (((value + 1_u64) >> (index * 8)) & 0xff_u64).to_u8 }
  File.write(marks_path, marks)
end

private def w64_write_plain(
  part : String,
  keys : Array(UInt64),
  rows : Array(Array(Array(T))),
  scale : Int32,
) : Nil forall T
  {% if T == Int32 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_decimal32_pair(part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), scale, rows_per_mark: 2)
  {% elsif T == Int64 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_decimal64_pair(part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), scale, rows_per_mark: 2)
  {% elsif T == Int128 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_decimal128_pair(part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), scale, rows_per_mark: 2)
  {% elsif T == CrystalClick::Decimal256Value %}
    CrystalClick::WidePartWriter.write_uint64_array_array_decimal256_pair(part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), scale, rows_per_mark: 2)
  {% else %}
    {% raise "unsupported W64 test type" %}
  {% end %}
  nil
end

private def w64_read_plain(reader : CrystalClick::WidePart, type : T.class) : Array(Array(Array(T))) forall T
  {% if T == Int32 %}
    reader.read_array_array_decimal32_mark_range("payload", 0, reader.mark_count)
  {% elsif T == Int64 %}
    reader.read_array_array_decimal64_mark_range("payload", 0, reader.mark_count)
  {% elsif T == Int128 %}
    reader.read_array_array_decimal128_mark_range("payload", 0, reader.mark_count)
  {% elsif T == CrystalClick::Decimal256Value %}
    reader.read_array_array_decimal256_mark_range("payload", 0, reader.mark_count)
  {% else %}
    {% raise "unsupported W64 test type" %}
  {% end %}
end

private def w64_write_nullable(
  part : String,
  keys : Array(UInt64),
  rows : Array(Array(Array(T?))),
  scale : Int32,
) : Nil forall T
  {% if T == Int32 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_decimal32_pair(part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), scale, rows_per_mark: 2)
  {% elsif T == Int64 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_decimal64_pair(part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), scale, rows_per_mark: 2)
  {% elsif T == Int128 %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_decimal128_pair(part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), scale, rows_per_mark: 2)
  {% elsif T == CrystalClick::Decimal256Value %}
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_decimal256_pair(part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), scale, rows_per_mark: 2)
  {% else %}
    {% raise "unsupported W64 test type" %}
  {% end %}
  nil
end

private def w64_read_nullable(reader : CrystalClick::WidePart, type : T.class) : Array(Array(Array(T?))) forall T
  {% if T == Int32 %}
    reader.read_array_array_nullable_decimal32_mark_range("payload", 0, reader.mark_count)
  {% elsif T == Int64 %}
    reader.read_array_array_nullable_decimal64_mark_range("payload", 0, reader.mark_count)
  {% elsif T == Int128 %}
    reader.read_array_array_nullable_decimal128_mark_range("payload", 0, reader.mark_count)
  {% elsif T == CrystalClick::Decimal256Value %}
    reader.read_array_array_nullable_decimal256_mark_range("payload", 0, reader.mark_count)
  {% else %}
    {% raise "unsupported W64 test type" %}
  {% end %}
end

private def w64_check_pair(type : T.class, precision : Int32, scale : Int32, samples : Array(T), label : String) : Nil forall T
  keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
  plain_rows = [] of Array(Array(T))
  plain_rows << [[samples[0], samples[1]] of T, [] of T]
  plain_rows << ([] of Array(T))
  plain_rows << [[] of T]
  plain_rows << ([] of Array(T))
  plain_rows << [[samples[2]], [] of T]
  plain_rows << ([] of Array(T))
  plain_rows << [[samples[3], samples[4]]]
  nullable_rows = [] of Array(Array(T?))
  nullable_rows << [[samples[0], nil, samples[1]] of T?, [] of T?]
  nullable_rows << ([] of Array(T?))
  nullable_rows << [[nil, nil] of T?]
  nullable_rows << ([] of Array(T?))
  nullable_rows << [[samples[2], nil] of T?, [] of T?]
  nullable_rows << ([] of Array(T?))
  nullable_rows << [[samples[3], nil, samples[4]] of T?]
  parent = File.tempname("crystal-click-w64-#{label}")
  Dir.mkdir(parent)
  plain_part = File.join(parent, "plain")
  nullable_part = File.join(parent, "nullable")

  begin
    w64_write_plain(plain_part, keys, plain_rows, scale)
    w64_write_nullable(nullable_part, keys, nullable_rows, scale)
    plain = CrystalClick::WidePart.open_typed(plain_part, "payload")
    nullable = CrystalClick::WidePart.open_typed(nullable_part, "payload")
    plain.column_type.should eq("Array(Array(Decimal(#{precision}, #{scale})))")
    nullable.column_type.should eq("Array(Array(Nullable(Decimal(#{precision}, #{scale}))))")
    plain.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    nullable.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    w64_read_plain(plain, type).should eq(plain_rows)
    w64_read_nullable(nullable, type).should eq(nullable_rows)
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe CrystalClick::WidePart do
  it "admits exact two-level Decimal Array declarations with optional nullable leaves" do
    {9, 18, 38, 76}.each do |precision|
      {0, 2, precision}.each do |scale|
        leaf = "Decimal(#{precision}, #{scale})"
        CrystalClick::WidePart.supports_typed_type?("Array(Array(#{leaf}))").should be_true
        CrystalClick::WidePart.supports_typed_type?("Array(Array(Nullable(#{leaf})))").should be_true
      end
    end
  end

  it "rejects invalid nested Decimal scales and unsupported composition" do
    {
      "Array(Array(Decimal(9, 10)))",
      "Array(Array(Nullable(Decimal(38, -1))))",
      "Array(Array(Decimal(77, 2)))",
      "Array(Array(Decimal(09, 2)))",
      "Array(Array(Decimal(9,2)))",
      "Array(Array(Nullable(Decimal256(2))))",
      "Array(Array(Array(Decimal(9, 2))))",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "writes and reads every two-level Decimal width with nullable leaves and empty middle marks" do
    w64_check_pair(Int32, 9, 2, [-999_999_999_i32, 999_999_999_i32, -1_i32, 0_i32, 42_i32], "decimal32")
    w64_check_pair(Int64, 18, 2, [-999_999_999_999_999_999_i64, 999_999_999_999_999_999_i64, -1_i64, 0_i64, 42_i64], "decimal64")
    decimal128_max = 10_i128**38 - 1_i128
    w64_check_pair(Int128, 38, 2, [-decimal128_max, decimal128_max, -1_i128, 0_i128, 42_i128], "decimal128")
    w64_check_pair(
      CrystalClick::Decimal256Value,
      76,
      2,
      [
        CrystalClick::Decimal256Value.from_words(UInt64::MAX - 41_u64, UInt64::MAX, UInt64::MAX, UInt64::MAX),
        CrystalClick::Decimal256Value.from_words(999_999_999_u64, 0_u64, 0_u64, 0_u64),
        CrystalClick::Decimal256Value.from_words(UInt64::MAX, UInt64::MAX, UInt64::MAX, UInt64::MAX),
        CrystalClick::Decimal256Value.from_words(0_u64, 0_u64, 0_u64, 0_u64),
        CrystalClick::Decimal256Value.from_words(42_u64, 0_u64, 0_u64, 0_u64),
      ],
      "decimal256"
    )
  end

  it "preserves zero and maximum legal scales for every nested Decimal width" do
    {0, 9}.each do |scale|
      w64_check_pair(Int32, 9, scale, [-123_i32, 123_i32, -1_i32, 0_i32, 42_i32], "decimal32-scale-#{scale}")
    end
    {0, 18}.each do |scale|
      w64_check_pair(Int64, 18, scale, [-123_i64, 123_i64, -1_i64, 0_i64, 42_i64], "decimal64-scale-#{scale}")
    end
    {0, 38}.each do |scale|
      w64_check_pair(Int128, 38, scale, [-123_i128, 123_i128, -1_i128, 0_i128, 42_i128], "decimal128-scale-#{scale}")
    end
    {0, 76}.each do |scale|
      samples = [-123_i128, 123_i128, -1_i128, 0_i128, 42_i128].map { |value| CrystalClick::Decimal256Value.from_int128(value) }
      w64_check_pair(CrystalClick::Decimal256Value, 76, scale, samples, "decimal256-scale-#{scale}")
    end
  end

  it "rejects shifted selected-mark boundaries in each nullable Decimal stream" do
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
    rows = [
      [[1_i32, nil] of Int32?],
      [] of Array(Int32?),
      [[nil, nil] of Int32?],
      [] of Array(Int32?),
      [[2_i32] of Int32?],
      [] of Array(Int32?),
      [[3_i32] of Int32?],
    ] of Array(Array(Int32?))
    parent = File.tempname("crystal-click-w64-mark-boundary")
    Dir.mkdir(parent)
    source = File.join(parent, "source")
    begin
      w64_write_nullable(source, keys, rows, 2)
      ["payload.size0", "payload.size1", "payload.null", "payload"].each_with_index do |stream, index|
        copy = File.join(parent, "corrupt-#{index}")
        FileUtils.cp_r(source, copy)
        w64_shift_mark_decompressed_offset(copy, stream, 2)
        expect_raises(CrystalClick::CorruptPartError) do
          CrystalClick::WidePart.open_typed(copy, "payload").read_array_array_nullable_decimal32_mark_range("payload", 2, 1)
        end
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
