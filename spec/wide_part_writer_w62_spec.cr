require "./spec_helper"

private def writer_w62_width(type : T.class) : Int32 forall T
  {% if T == Int128 || T == UInt128 %}
    16
  {% elsif T == CrystalClick::Int256Value || T == CrystalClick::UInt256Value %}
    32
  {% elsif T == CrystalClick::BFloat16Value %}
    2
  {% else %}
    raise "unexpected W62 writer type"
  {% end %}
end

private def writer_w62_append_value(bytes : Array(UInt8), value : T) : Nil forall T
  {% if T == Int128 %}
    bits = value.unsafe_as(UInt128)
    16.times { |byte| bytes << ((bits >> (byte * 8)) & 0xff_u128).to_u8 }
  {% elsif T == UInt128 %}
    16.times { |byte| bytes << ((value >> (byte * 8)) & 0xff_u128).to_u8 }
  {% elsif T == CrystalClick::Int256Value || T == CrystalClick::UInt256Value %}
    16.times { |byte| bytes << ((value.low >> (byte * 8)) & 0xff_u128).to_u8 }
    16.times { |byte| bytes << ((value.high >> (byte * 8)) & 0xff_u128).to_u8 }
  {% elsif T == CrystalClick::BFloat16Value %}
    2.times { |byte| bytes << ((value.bits >> (byte * 8)) & 0xff_u16).to_u8 }
  {% else %}
    raise "unexpected W62 writer value"
  {% end %}
end

private def writer_w62_value_identical?(expected : T, actual : T) : Bool forall T
  {% if T == CrystalClick::BFloat16Value %}
    expected.bits == actual.bits
  {% elsif T == CrystalClick::Int256Value || T == CrystalClick::UInt256Value %}
    expected.low == actual.low && expected.high == actual.high
  {% else %}
    expected == actual
  {% end %}
end

private def writer_w62_values_identical?(expected : Array(Array(Array(T))), actual : Array(Array(Array(T)))) : Bool forall T
  return false unless expected.size == actual.size
  expected.each_with_index do |row, row_index|
    observed_row = actual[row_index]
    return false unless row.size == observed_row.size
    row.each_with_index do |inner, inner_index|
      observed_inner = observed_row[inner_index]
      return false unless inner.size == observed_inner.size
      inner.each_with_index do |value, value_index|
        return false unless writer_w62_value_identical?(value, observed_inner[value_index])
      end
    end
  end
  true
end

private def writer_w62_nullable_values_identical?(expected : Array(Array(Array(T?))), actual : Array(Array(Array(T?)))) : Bool forall T
  return false unless expected.size == actual.size
  expected.each_with_index do |row, row_index|
    observed_row = actual[row_index]
    return false unless row.size == observed_row.size
    row.each_with_index do |inner, inner_index|
      observed_inner = observed_row[inner_index]
      return false unless inner.size == observed_inner.size
      inner.each_with_index do |value, value_index|
        observed = observed_inner[value_index]
        return false if value.nil? != observed.nil?
        if value && observed
          return false unless writer_w62_value_identical?(value.not_nil!, observed.not_nil!)
        end
      end
    end
  end
  true
end

private def writer_w62_nested_sizes(values : Array(Array(Array(T)))) : {Array(UInt8), Array(UInt8)} forall T
  size0 = [] of UInt8
  size1 = [] of UInt8
  values.each do |row|
    8.times { |byte| size0 << ((row.size.to_u64 >> (byte * 8)) & 0xff_u64).to_u8 }
    row.each do |inner|
      8.times { |byte| size1 << ((inner.size.to_u64 >> (byte * 8)) & 0xff_u64).to_u8 }
    end
  end
  {size0, size1}
end

private def writer_w62_check_common_metadata(part : String, type_name : String, nullable : Bool) : Nil
  expected_type = nullable ? "Array(Array(Nullable(#{type_name})))" : "Array(Array(#{type_name}))"
  File.read(File.join(part, "columns.txt")).should eq("columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` #{expected_type}\n")
  expected_payload_streams = nullable ? "4 substreams for column `payload`:\n\tpayload.size0\n\tpayload.size1\n\tpayload.null\n\tpayload\n" : "3 substreams for column `payload`:\n\tpayload.size0\n\tpayload.size1\n\tpayload\n"
  expected_substreams = "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n#{expected_payload_streams}"
  File.read(File.join(part, "columns_substreams.txt")).should eq(expected_substreams)
  File.read(File.join(part, "default_compression_codec.txt")).should eq("CODEC(LZ4)")
  File.read(File.join(part, "serialization.json")).should eq(
    "{\"columns\":[]," +
    "\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{\"string\":1},\"version\":1}"
  )
end

private def writer_w62_mark_rows(part : String, logical_stream : String) : Array(UInt64)
  mark_path = File.join(part, "#{CrystalClick::StreamName.hash(logical_stream)}.mrk2")
  bytes = File.read(mark_path).to_slice
  raise "invalid W62 writer mark file" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE + 16
    value = 0_u64
    8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
    value
  end
end

private def writer_w62_plain_case(values : Array(Array(Array(T))), type : T.class, label : String) : Nil forall T
  type_name = CrystalClick::WidePart.array_numeric_type_name(type)
  parent = File.tempname("crystal-click-wide-writer-w62-#{label}")
  Dir.mkdir(parent)
  part = File.join(parent, "all_1_1_0")
  keys = [1_u64, 2_u64, 4_u64, 7_u64, 10_u64]

  begin
    CrystalClick::WidePartWriter.write_uint64_array_array_numeric_pair(
      part,
      "pk",
      keys.to_unsafe.to_slice(keys.size),
      "payload",
      values.to_unsafe.to_slice(values.size),
      rows_per_mark: 2
    )

    reader = CrystalClick::WidePart.open_typed(part, "payload")
    reader.column_type.should eq("Array(Array(#{type_name}))")
    reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
    actual = reader.read_array_array_numeric_mark_range("payload", 0, reader.mark_count, type)
    writer_w62_values_identical?(values, actual).should be_true
    selected = reader.read_array_array_numeric_mark_range("payload", 1, 1, type)
    writer_w62_values_identical?(values[2, 2], selected).should be_true

    expected_size0, expected_size1 = writer_w62_nested_sizes(values)
    size0 = File.join(part, "#{CrystalClick::StreamName.hash("payload.size0")}.bin")
    size1 = File.join(part, "#{CrystalClick::StreamName.hash("payload.size1")}.bin")
    CrystalClick::CompressedBlock.decode_all(File.read(size0).to_slice).to_a.should eq(expected_size0)
    CrystalClick::CompressedBlock.decode_all(File.read(size1).to_slice).to_a.should eq(expected_size1)
    writer_w62_mark_rows(part, "payload.size0").should eq([2_u64, 2_u64, 1_u64, 0_u64])
    writer_w62_mark_rows(part, "payload.size1").should eq([2_u64, 2_u64, 1_u64, 0_u64])
    writer_w62_check_common_metadata(part, type_name, false)
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def writer_w62_nullable_case(values : Array(Array(Array(T?))), type : T.class, label : String) : Nil forall T
  type_name = CrystalClick::WidePart.array_numeric_type_name(type)
  width = writer_w62_width(type)
  parent = File.tempname("crystal-click-wide-writer-w62-nullable-#{label}")
  Dir.mkdir(parent)
  part = File.join(parent, "all_1_1_0")
  keys = [1_u64, 2_u64, 4_u64, 7_u64, 10_u64]

  begin
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_numeric_pair(
      part,
      "pk",
      keys.to_unsafe.to_slice(keys.size),
      "payload",
      values.to_unsafe.to_slice(values.size),
      rows_per_mark: 2
    )

    reader = CrystalClick::WidePart.open_typed(part, "payload")
    reader.column_type.should eq("Array(Array(Nullable(#{type_name})))")
    reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
    actual = reader.read_array_array_nullable_numeric_mark_range("payload", 0, reader.mark_count, type)
    writer_w62_nullable_values_identical?(values, actual).should be_true
    selected = reader.read_array_array_nullable_numeric_mark_range("payload", 1, 1, type)
    writer_w62_nullable_values_identical?(values[2, 2], selected).should be_true

    expected_size0, expected_size1 = writer_w62_nested_sizes(values)
    flat = [] of T?
    values.each { |row| row.each { |inner| flat.concat(inner) } }
    expected_nulls = flat.map { |value| value.nil? ? 1_u8 : 0_u8 }
    expected_values = [] of UInt8
    flat.each do |value|
      if value.nil?
        width.times { expected_values << 0_u8 }
      else
        writer_w62_append_value(expected_values, value.not_nil!)
      end
    end

    {
      {"payload.size0", expected_size0},
      {"payload.size1", expected_size1},
      {"payload.null", expected_nulls},
      {"payload", expected_values},
    }.each do |logical_stream, expected_raw|
      data_path = File.join(part, "#{CrystalClick::StreamName.hash(logical_stream)}.bin")
      CrystalClick::CompressedBlock.decode_all(File.read(data_path).to_slice).to_a.should eq(expected_raw)
      writer_w62_mark_rows(part, logical_stream).should eq([2_u64, 2_u64, 1_u64, 0_u64])
    end
    writer_w62_check_common_metadata(part, type_name, true)
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def writer_w62_plain_values(type : T.class) : Array(Array(Array(T))) forall T
  {% if T == Int128 %}
    [
      [] of Array(Int128),
      [[] of Int128, [Int128::MIN, Int128::MAX, -1_i128] of Int128],
      [] of Array(Int128),
      [[] of Int128],
      [[Int128::MIN + 1_i128, 0_i128]],
    ] of Array(Array(Int128))
  {% elsif T == UInt128 %}
    [
      [] of Array(UInt128),
      [[] of UInt128, [UInt128::MAX, (1_u128 << 64), 0_u128] of UInt128],
      [] of Array(UInt128),
      [[] of UInt128],
      [[UInt128::MAX - 1_u128, 42_u128]],
    ] of Array(Array(UInt128))
  {% elsif T == CrystalClick::Int256Value %}
    [
      [] of Array(CrystalClick::Int256Value),
      [[] of CrystalClick::Int256Value, [
        CrystalClick::Int256Value.from_words(0_u64, 0_u64, 0_u64, 0x8000000000000000_u64),
        CrystalClick::Int256Value.from_words(UInt64::MAX, UInt64::MAX, UInt64::MAX, UInt64::MAX),
      ] of CrystalClick::Int256Value],
      [] of Array(CrystalClick::Int256Value),
      [[] of CrystalClick::Int256Value],
      [[CrystalClick::Int256Value.from_words(1_u64, 0_u64, 0_u64, 0_u64)]],
    ] of Array(Array(CrystalClick::Int256Value))
  {% elsif T == CrystalClick::UInt256Value %}
    [
      [] of Array(CrystalClick::UInt256Value),
      [[] of CrystalClick::UInt256Value, [
        CrystalClick::UInt256Value.from_words(UInt64::MAX, UInt64::MAX, UInt64::MAX, UInt64::MAX),
        CrystalClick::UInt256Value.from_words(0_u64, 0_u64, 0_u64, 0x8000000000000000_u64),
      ] of CrystalClick::UInt256Value],
      [] of Array(CrystalClick::UInt256Value),
      [[] of CrystalClick::UInt256Value],
      [[CrystalClick::UInt256Value.from_words(42_u64, 0_u64, 0_u64, 0_u64)]],
    ] of Array(Array(CrystalClick::UInt256Value))
  {% elsif T == CrystalClick::BFloat16Value %}
    [
      [] of Array(CrystalClick::BFloat16Value),
      [[] of CrystalClick::BFloat16Value, [
        CrystalClick::BFloat16Value.new(0x8000_u16),
        CrystalClick::BFloat16Value.new(0x7fc1_u16),
        CrystalClick::BFloat16Value.new(0x0001_u16),
      ] of CrystalClick::BFloat16Value],
      [] of Array(CrystalClick::BFloat16Value),
      [[] of CrystalClick::BFloat16Value],
      [[CrystalClick::BFloat16Value.new(0x3f80_u16), CrystalClick::BFloat16Value.new(0xbf80_u16)]],
    ] of Array(Array(CrystalClick::BFloat16Value))
  {% else %}
    raise "unexpected W62 writer type"
  {% end %}
end

private def writer_w62_nullable_values(type : T.class) : Array(Array(Array(T?))) forall T
  {% if T == Int128 %}
    [
      [] of Array(Int128?),
      [[] of Int128?, [nil, Int128::MIN, Int128::MAX] of Int128?],
      [] of Array(Int128?),
      [[nil, nil] of Int128?],
      [[-1_i128, nil, 0_i128] of Int128?],
    ] of Array(Array(Int128?))
  {% elsif T == UInt128 %}
    [
      [] of Array(UInt128?),
      [[] of UInt128?, [nil, UInt128::MAX, 1_u128] of UInt128?],
      [] of Array(UInt128?),
      [[nil, nil] of UInt128?],
      [[UInt128::MAX - 1_u128, nil] of UInt128?],
    ] of Array(Array(UInt128?))
  {% elsif T == CrystalClick::Int256Value %}
    [
      [] of Array(CrystalClick::Int256Value?),
      [[] of CrystalClick::Int256Value?, [nil,
                                          CrystalClick::Int256Value.from_words(0_u64, 0_u64, 0_u64, 0x8000000000000000_u64),
                                          CrystalClick::Int256Value.from_words(UInt64::MAX, UInt64::MAX, UInt64::MAX, UInt64::MAX),
      ] of CrystalClick::Int256Value?],
      [] of Array(CrystalClick::Int256Value?),
      [[nil, nil] of CrystalClick::Int256Value?],
      [[CrystalClick::Int256Value.from_words(1_u64, 0_u64, 0_u64, 0_u64), nil] of CrystalClick::Int256Value?],
    ] of Array(Array(CrystalClick::Int256Value?))
  {% elsif T == CrystalClick::UInt256Value %}
    [
      [] of Array(CrystalClick::UInt256Value?),
      [[] of CrystalClick::UInt256Value?, [nil,
                                           CrystalClick::UInt256Value.from_words(UInt64::MAX, UInt64::MAX, UInt64::MAX, UInt64::MAX),
                                           CrystalClick::UInt256Value.from_words(0_u64, 0_u64, 0_u64, 0x8000000000000000_u64),
      ] of CrystalClick::UInt256Value?],
      [] of Array(CrystalClick::UInt256Value?),
      [[nil, nil] of CrystalClick::UInt256Value?],
      [[CrystalClick::UInt256Value.from_words(42_u64, 0_u64, 0_u64, 0_u64), nil] of CrystalClick::UInt256Value?],
    ] of Array(Array(CrystalClick::UInt256Value?))
  {% elsif T == CrystalClick::BFloat16Value %}
    [
      [] of Array(CrystalClick::BFloat16Value?),
      [[] of CrystalClick::BFloat16Value?, [nil,
                                            CrystalClick::BFloat16Value.new(0x8000_u16),
                                            CrystalClick::BFloat16Value.new(0x7fc1_u16),
      ] of CrystalClick::BFloat16Value?],
      [] of Array(CrystalClick::BFloat16Value?),
      [[nil, nil] of CrystalClick::BFloat16Value?],
      [[CrystalClick::BFloat16Value.new(0x0001_u16), nil] of CrystalClick::BFloat16Value?],
    ] of Array(Array(CrystalClick::BFloat16Value?))
  {% else %}
    raise "unexpected W62 writer type"
  {% end %}
end

describe CrystalClick::WidePartWriter do
  it "writes the exact W62 nested wide numeric Array family" do
    writer_w62_plain_case(writer_w62_plain_values(Int128), Int128, "int128")
    writer_w62_plain_case(writer_w62_plain_values(UInt128), UInt128, "uint128")
    writer_w62_plain_case(writer_w62_plain_values(CrystalClick::Int256Value), CrystalClick::Int256Value, "int256")
    writer_w62_plain_case(writer_w62_plain_values(CrystalClick::UInt256Value), CrystalClick::UInt256Value, "uint256")
    writer_w62_plain_case(writer_w62_plain_values(CrystalClick::BFloat16Value), CrystalClick::BFloat16Value, "bfloat16")
  end

  it "writes W62 nullable nested wide leaves with exact null maps and zero placeholders" do
    writer_w62_nullable_case(writer_w62_nullable_values(Int128), Int128, "int128")
    writer_w62_nullable_case(writer_w62_nullable_values(UInt128), UInt128, "uint128")
    writer_w62_nullable_case(writer_w62_nullable_values(CrystalClick::Int256Value), CrystalClick::Int256Value, "int256")
    writer_w62_nullable_case(writer_w62_nullable_values(CrystalClick::UInt256Value), CrystalClick::UInt256Value, "uint256")
    writer_w62_nullable_case(writer_w62_nullable_values(CrystalClick::BFloat16Value), CrystalClick::BFloat16Value, "bfloat16")
  end
end
