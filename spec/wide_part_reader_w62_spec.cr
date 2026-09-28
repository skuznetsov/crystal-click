require "./spec_helper"

private def w62_write_u64(bytes : Bytes, offset : Int, value : UInt64) : Nil
  8.times { |byte| bytes[offset + byte] = ((value >> (byte * 8)) & 0xff_u64).to_u8 }
end

private def w62_shift_mark_decompressed_offset(path : String, stream : String, mark_index : Int) : Nil
  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  marks = File.read(marks_path).to_slice.dup
  offset = mark_index * CrystalClick::WidePart::MARK_SIZE + 8
  value = 0_u64
  8.times { |byte| value |= marks[offset + byte].to_u64 << (byte * 8) }
  w62_write_u64(marks, offset, value + 1_u64)
  File.write(marks_path, marks)
end

private def w62_check_numeric_reader(type : T.class, type_name : String, samples : Array(T), label : String) : Nil forall T
  rows = [] of Array(Array(T))
  rows << [[samples[0], samples[1]] of T, [] of T]
  rows << ([] of Array(T))
  rows << [[] of T]
  rows << ([] of Array(T))
  rows << [[samples[2]], [] of T]
  rows << ([] of Array(T))
  rows << [[samples[3], samples[4]]]
  keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
  parent = File.tempname("crystal-click-w62-reader-#{label}")
  Dir.mkdir(parent)
  part = File.join(parent, "part")

  begin
    CrystalClick::WidePartWriter.write_uint64_array_array_numeric_pair(
      part,
      "pk",
      keys.to_unsafe.to_slice(keys.size),
      "payload",
      rows.to_unsafe.to_slice(rows.size),
      rows_per_mark: 2
    )

    reader = CrystalClick::WidePart.open_typed(part, "payload")
    reader.column_type.should eq("Array(Array(#{type_name}))")
    reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    reader.read_array_array_numeric_mark_range("payload", 0, reader.mark_count, type).should eq(rows)
    reader.read_array_array_numeric_mark_range("payload", 1, 1, type).should eq(rows[2, 2])
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w62_check_nullable_numeric_reader(type : T.class, type_name : String, samples : Array(T), label : String) : Nil forall T
  rows = [] of Array(Array(T?))
  rows << [[samples[0], nil, samples[1]] of T?, [] of T?]
  rows << ([] of Array(T?))
  rows << [[nil, nil] of T?]
  rows << ([] of Array(T?))
  rows << [[samples[2], nil] of T?, [] of T?]
  rows << ([] of Array(T?))
  rows << [[samples[3], nil, samples[4]] of T?]
  keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
  parent = File.tempname("crystal-click-w62-reader-nullable-#{label}")
  Dir.mkdir(parent)
  part = File.join(parent, "part")

  begin
    CrystalClick::WidePartWriter.write_uint64_array_array_nullable_numeric_pair(
      part,
      "pk",
      keys.to_unsafe.to_slice(keys.size),
      "payload",
      rows.to_unsafe.to_slice(rows.size),
      rows_per_mark: 2
    )

    reader = CrystalClick::WidePart.open_typed(part, "payload")
    reader.column_type.should eq("Array(Array(Nullable(#{type_name})))")
    reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    reader.read_array_array_nullable_numeric_mark_range("payload", 0, reader.mark_count, type).should eq(rows)
    reader.read_array_array_nullable_numeric_mark_range("payload", 1, 1, type).should eq(rows[2, 2])
  ensure
    FileUtils.rm_rf(parent)
  end
end

describe CrystalClick::WidePart do
  it "admits the five wider fixed-width numeric leaves in two Array levels" do
    {"Int128", "UInt128", "Int256", "UInt256", "BFloat16"}.each do |leaf|
      CrystalClick::WidePart.supports_typed_type?("Array(Array(#{leaf}))").should be_true
      CrystalClick::WidePart.supports_typed_type?("Array(Array(Nullable(#{leaf})))").should be_true
    end
  end

  it "does not treat arbitrary nested semantic or recursive shapes as admitted" do
    {
      "Array(Array(Bool))",
      "Array(Array(Decimal256))",
      "Array(Array(Nullable(Decimal256)))",
      "Array(Array(Nullable(UUID)))",
      "Array(Array(Array(Int128)))",
      "Array(Array(Nullable(BFloat16))) trailing",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end

  it "reads and preflights each exact nested wide numeric leaf" do
    w62_check_numeric_reader(Int128, "Int128", [Int128::MIN, Int128::MAX, -1_i128, 0_i128, 42_i128], "int128")
    w62_check_numeric_reader(UInt128, "UInt128", [0_u128, UInt128::MAX, 42_u128, 1_u128, 2_u128], "uint128")
    w62_check_numeric_reader(
      CrystalClick::Int256Value,
      "Int256",
      [
        CrystalClick::Int256Value.from_words(0_u64, 0_u64, 0_u64, 0x8000000000000000_u64),
        CrystalClick::Int256Value.from_words(UInt64::MAX, UInt64::MAX, UInt64::MAX, 0x7fffffffffffffff_u64),
        CrystalClick::Int256Value.from_words(UInt64::MAX, UInt64::MAX, UInt64::MAX, UInt64::MAX),
        CrystalClick::Int256Value.from_words(0_u64, 0_u64, 0_u64, 0_u64),
        CrystalClick::Int256Value.from_words(42_u64, 0_u64, 0_u64, 0_u64),
      ],
      "int256"
    )
    w62_check_numeric_reader(
      CrystalClick::UInt256Value,
      "UInt256",
      [
        CrystalClick::UInt256Value.new(0_u128, 0_u128),
        CrystalClick::UInt256Value.new(UInt128::MAX, UInt128::MAX),
        CrystalClick::UInt256Value.new(42_u128, 0_u128),
        CrystalClick::UInt256Value.new(1_u128, 0_u128),
        CrystalClick::UInt256Value.new(2_u128, 0_u128),
      ],
      "uint256"
    )
    w62_check_numeric_reader(
      CrystalClick::BFloat16Value,
      "BFloat16",
      [CrystalClick::BFloat16Value.new(0x0000_u16), CrystalClick::BFloat16Value.new(0x8000_u16), CrystalClick::BFloat16Value.new(0x7fc1_u16), CrystalClick::BFloat16Value.new(0x0001_u16), CrystalClick::BFloat16Value.new(0xffff_u16)],
      "bfloat16"
    )
  end

  it "reads nullable nested wide leaves with NULL and an all-NULL middle mark" do
    w62_check_nullable_numeric_reader(Int128, "Int128", [Int128::MIN, Int128::MAX, -1_i128, 0_i128, 42_i128], "int128")
    w62_check_nullable_numeric_reader(UInt128, "UInt128", [0_u128, UInt128::MAX, 42_u128, 1_u128, 2_u128], "uint128")
    w62_check_nullable_numeric_reader(
      CrystalClick::Int256Value,
      "Int256",
      [
        CrystalClick::Int256Value.from_words(0_u64, 0_u64, 0_u64, 0x8000000000000000_u64),
        CrystalClick::Int256Value.from_words(UInt64::MAX, UInt64::MAX, UInt64::MAX, 0x7fffffffffffffff_u64),
        CrystalClick::Int256Value.from_words(UInt64::MAX, UInt64::MAX, UInt64::MAX, UInt64::MAX),
        CrystalClick::Int256Value.from_words(0_u64, 0_u64, 0_u64, 0_u64),
        CrystalClick::Int256Value.from_words(42_u64, 0_u64, 0_u64, 0_u64),
      ],
      "int256"
    )
    w62_check_nullable_numeric_reader(
      CrystalClick::UInt256Value,
      "UInt256",
      [
        CrystalClick::UInt256Value.new(0_u128, 0_u128),
        CrystalClick::UInt256Value.new(UInt128::MAX, UInt128::MAX),
        CrystalClick::UInt256Value.new(42_u128, 0_u128),
        CrystalClick::UInt256Value.new(1_u128, 0_u128),
        CrystalClick::UInt256Value.new(2_u128, 0_u128),
      ],
      "uint256"
    )
    w62_check_nullable_numeric_reader(
      CrystalClick::BFloat16Value,
      "BFloat16",
      [CrystalClick::BFloat16Value.new(0x0000_u16), CrystalClick::BFloat16Value.new(0x8000_u16), CrystalClick::BFloat16Value.new(0x7fc1_u16), CrystalClick::BFloat16Value.new(0x0001_u16), CrystalClick::BFloat16Value.new(0xffff_u16)],
      "bfloat16"
    )
  end

  it "rejects shifted selected-mark boundaries in every nested numeric stream" do
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
    plain_rows = [
      [[CrystalClick::Int256Value.from_words(1_u64, 0_u64, 0_u64, 0_u64)] of CrystalClick::Int256Value],
      [] of Array(CrystalClick::Int256Value),
      [[] of CrystalClick::Int256Value],
      [] of Array(CrystalClick::Int256Value),
      [[CrystalClick::Int256Value.from_words(2_u64, 0_u64, 0_u64, 0_u64)]],
      [] of Array(CrystalClick::Int256Value),
      [[CrystalClick::Int256Value.from_words(3_u64, 0_u64, 0_u64, 0_u64)]],
    ] of Array(Array(CrystalClick::Int256Value))
    nullable_rows = [
      [[CrystalClick::Int256Value.from_words(1_u64, 0_u64, 0_u64, 0_u64), nil] of CrystalClick::Int256Value?],
      [] of Array(CrystalClick::Int256Value?),
      [[nil, nil] of CrystalClick::Int256Value?],
      [] of Array(CrystalClick::Int256Value?),
      [[CrystalClick::Int256Value.from_words(2_u64, 0_u64, 0_u64, 0_u64), nil] of CrystalClick::Int256Value?],
      [] of Array(CrystalClick::Int256Value?),
      [[CrystalClick::Int256Value.from_words(3_u64, 0_u64, 0_u64, 0_u64)] of CrystalClick::Int256Value?],
    ] of Array(Array(CrystalClick::Int256Value?))
    parent = File.tempname("crystal-click-w62-reader-mark-corruption")
    Dir.mkdir(parent)
    plain_part = File.join(parent, "plain")
    nullable_part = File.join(parent, "nullable")

    begin
      CrystalClick::WidePartWriter.write_uint64_array_array_numeric_pair(
        plain_part,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        plain_rows.to_unsafe.to_slice(plain_rows.size),
        rows_per_mark: 2
      )
      CrystalClick::WidePartWriter.write_uint64_array_array_nullable_numeric_pair(
        nullable_part,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "payload",
        nullable_rows.to_unsafe.to_slice(nullable_rows.size),
        rows_per_mark: 2
      )

      {
        {plain_part, ["payload.size0", "payload.size1", "payload"]},
        {nullable_part, ["payload.size0", "payload.size1", "payload.null", "payload"]},
      }.each do |source, streams|
        streams.each do |stream|
          corrupt_parent = File.tempname("crystal-click-w62-reader-mark-corruption-case")
          Dir.mkdir(corrupt_parent)
          corrupt_part = File.join(corrupt_parent, "part")
          begin
            FileUtils.cp_r(source, corrupt_part)
            w62_shift_mark_decompressed_offset(corrupt_part, stream, 2)
            expect_raises(CrystalClick::CorruptPartError) do
              reader = CrystalClick::WidePart.open_typed(corrupt_part, "payload")
              if stream == "payload.null"
                reader.read_array_array_nullable_numeric_mark_range("payload", 2, 1, CrystalClick::Int256Value)
              elsif source == nullable_part
                reader.read_array_array_nullable_numeric_mark_range("payload", 2, 1, CrystalClick::Int256Value)
              else
                reader.read_array_array_numeric_mark_range("payload", 2, 1, CrystalClick::Int256Value)
              end
            end
          ensure
            FileUtils.rm_rf(corrupt_parent)
          end
        end
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
