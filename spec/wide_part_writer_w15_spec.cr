require "./spec_helper"

private def w15_stream_bytes(path : String, logical_stream : String) : Array(UInt8)
  data_path = File.join(path, "#{CrystalClick::StreamName.hash(logical_stream)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(data_path).to_slice).to_a
end

private def w15_le_bytes(values : Array(Int32)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    bits = value.unsafe_as(UInt32)
    4.times { |index| bytes << ((bits >> (index * 8)) & 0xff_u32).to_u8 }
  end
  bytes
end

private def w15_le_bytes(values : Array(Int16)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    bits = value.unsafe_as(UInt16)
    2.times { |index| bytes << ((bits >> (index * 8)) & 0xff_u16).to_u8 }
  end
  bytes
end

private def w15_le_bytes(values : Array(Int64)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    bits = value.unsafe_as(UInt64)
    8.times { |index| bytes << ((bits >> (index * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

describe CrystalClick::WidePartWriter do
  it "writes Bool with exact semantic metadata and 0/1 bytes across marks" do
    parent = File.tempname("crystal-click-w15-bool")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    values = [false, true, false, true, true]

    begin
      CrystalClick::WidePartWriter.write_uint64_bool_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "flag",
        values.to_unsafe.to_slice(values.size), rows_per_mark: 2
      ).should eq(destination)
      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`flag` Bool\n"
      )
      File.read(File.join(destination, "serialization.json")).should eq(
        %({"columns":[],"propagate_types_serialization_versions_to_nested_types":true,"types_serialization_versions":{"string":1},"version":1})
      )
      w15_stream_bytes(destination, "flag").should eq([0_u8, 1_u8, 0_u8, 1_u8, 1_u8])
      CrystalClick::WidePart.open_typed(destination, "flag").column_type.should eq("Bool")
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes Nullable(Bool) with separate NULL and false values" do
    parent = File.tempname("crystal-click-w15-nullable-bool")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    values = [nil, false.as(Bool?), true.as(Bool?), nil, false.as(Bool?)]

    begin
      CrystalClick::WidePartWriter.write_uint64_nullable_bool_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "flag",
        values.to_unsafe.to_slice(values.size), rows_per_mark: 2
      ).should eq(destination)
      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`flag` Nullable(Bool)\n"
      )
      w15_stream_bytes(destination, "flag.null").should eq([1_u8, 0_u8, 0_u8, 1_u8, 0_u8])
      w15_stream_bytes(destination, "flag").should eq([0_u8, 0_u8, 1_u8, 0_u8, 0_u8])
      CrystalClick::WidePart.open_typed(destination, "flag").column_type.should eq("Nullable(Bool)")
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps generic Bool inference semantic without converting it to UInt8" do
    parent = File.tempname("crystal-click-w15-bool-inference")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64]
    bare = [false, true]
    nullable = [nil, false.as(Bool?)]

    begin
      bare_destination = File.join(parent, "bare")
      CrystalClick::WidePartWriter.write_uint64_typed_pair(
        bare_destination, "pk", keys.to_unsafe.to_slice(keys.size), "flag",
        bare.to_unsafe.to_slice(bare.size), 1
      )
      File.read(File.join(bare_destination, "columns.txt")).should contain("`flag` Bool\n")

      nullable_destination = File.join(parent, "nullable")
      CrystalClick::WidePartWriter.write_uint64_typed_pair(
        nullable_destination, "pk", keys.to_unsafe.to_slice(keys.size), "flag",
        nullable.to_unsafe.to_slice(nullable.size), 1
      )
      File.read(File.join(nullable_destination, "columns.txt")).should contain("`flag` Nullable(Bool)\n")
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes Decimal32 and Decimal64 as stock-normalized Decimal(9/18, scale) raw integers" do
    parent = File.tempname("crystal-click-w15-decimal")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    small = [-12_345_i32, -1_i32, 0_i32, 1_i32, 12_345_i32]
    large = [-123_456_789_i64, -1_i64, 0_i64, 1_i64, 123_456_789_i64]

    begin
      small_destination = File.join(parent, "decimal32")
      CrystalClick::WidePartWriter.write_uint64_decimal32_pair(
        small_destination, "pk", keys.to_unsafe.to_slice(keys.size), "amount",
        small.to_unsafe.to_slice(small.size), 2, 2
      ).should eq(small_destination)
      File.read(File.join(small_destination, "columns.txt")).should contain("`amount` Decimal(9, 2)\n")
      File.exists?(File.join(small_destination, "serialization.json")).should be_true
      w15_stream_bytes(small_destination, "amount").should eq(w15_le_bytes(small))

      large_destination = File.join(parent, "decimal64")
      CrystalClick::WidePartWriter.write_uint64_decimal64_pair(
        large_destination, "pk", keys.to_unsafe.to_slice(keys.size), "amount",
        large.to_unsafe.to_slice(large.size), 4, 2
      ).should eq(large_destination)
      File.read(File.join(large_destination, "columns.txt")).should contain("`amount` Decimal(18, 4)\n")
      w15_stream_bytes(large_destination, "amount").should eq(w15_le_bytes(large))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes nullable decimal raw slots with NULL distinct from zero" do
    parent = File.tempname("crystal-click-w15-nullable-decimal")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    small = [nil, -123_i32.as(Int32?), 0_i32.as(Int32?), nil, 456_i32.as(Int32?)]
    large = [nil, -12_345_i64.as(Int64?), 0_i64.as(Int64?), nil, 67_890_i64.as(Int64?)]

    begin
      small_destination = File.join(parent, "decimal32")
      CrystalClick::WidePartWriter.write_uint64_nullable_decimal32_pair(
        small_destination, "pk", keys.to_unsafe.to_slice(keys.size), "amount",
        small.to_unsafe.to_slice(small.size), 2, 2
      ).should eq(small_destination)
      File.read(File.join(small_destination, "columns.txt")).should contain("`amount` Nullable(Decimal(9, 2))\n")
      w15_stream_bytes(small_destination, "amount.null").should eq([1_u8, 0_u8, 0_u8, 1_u8, 0_u8])
      w15_stream_bytes(small_destination, "amount").should eq(w15_le_bytes([0_i32, -123_i32, 0_i32, 0_i32, 456_i32]))

      large_destination = File.join(parent, "decimal64")
      CrystalClick::WidePartWriter.write_uint64_nullable_decimal64_pair(
        large_destination, "pk", keys.to_unsafe.to_slice(keys.size), "amount",
        large.to_unsafe.to_slice(large.size), 4, 2
      ).should eq(large_destination)
      File.read(File.join(large_destination, "columns.txt")).should contain("`amount` Nullable(Decimal(18, 4))\n")
      w15_stream_bytes(large_destination, "amount.null").should eq([1_u8, 0_u8, 0_u8, 1_u8, 0_u8])
      w15_stream_bytes(large_destination, "amount").should eq(w15_le_bytes([0_i64, -12_345_i64, 0_i64, 0_i64, 67_890_i64]))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes Enum8 and Enum16 signed codes with their exact label mappings" do
    parent = File.tempname("crystal-click-w15-enum")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    small = [-7_i8, 0_i8, 7_i8, -7_i8, 7_i8]
    large = [-257_i16, 0_i16, 257_i16, -257_i16, 257_i16]
    small_type = "Enum8('neg' = -7, 'zero' = 0, 'pos' = 7)"
    large_type = "Enum16('neg' = -257, 'zero' = 0, 'pos' = 257)"

    begin
      small_destination = File.join(parent, "enum8")
      CrystalClick::WidePartWriter.write_uint64_enum8_pair(
        small_destination, "pk", keys.to_unsafe.to_slice(keys.size), "state",
        small.to_unsafe.to_slice(small.size), small_type, 2
      ).should eq(small_destination)
      File.read(File.join(small_destination, "columns.txt")).should contain("`state` #{small_type}\n")
      File.exists?(File.join(small_destination, "serialization.json")).should be_true
      w15_stream_bytes(small_destination, "state").should eq(small.map(&.unsafe_as(UInt8)))

      large_destination = File.join(parent, "enum16")
      CrystalClick::WidePartWriter.write_uint64_enum16_pair(
        large_destination, "pk", keys.to_unsafe.to_slice(keys.size), "state",
        large.to_unsafe.to_slice(large.size), large_type, 2
      ).should eq(large_destination)
      File.read(File.join(large_destination, "columns.txt")).should contain("`state` #{large_type}\n")
      w15_stream_bytes(large_destination, "state").should eq(w15_le_bytes(large))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes nullable enums without requiring zero in a NULL placeholder's mapping" do
    parent = File.tempname("crystal-click-w15-nullable-enum")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    small = [nil, -7_i8.as(Int8?), 7_i8.as(Int8?), nil, -7_i8.as(Int8?)]
    large = [nil, -257_i16.as(Int16?), 257_i16.as(Int16?), nil, -257_i16.as(Int16?)]

    begin
      small_destination = File.join(parent, "enum8")
      CrystalClick::WidePartWriter.write_uint64_nullable_enum8_pair(
        small_destination, "pk", keys.to_unsafe.to_slice(keys.size), "state",
        small.to_unsafe.to_slice(small.size), "Enum8('neg' = -7, 'pos' = 7)", 2
      ).should eq(small_destination)
      w15_stream_bytes(small_destination, "state.null").should eq([1_u8, 0_u8, 0_u8, 1_u8, 0_u8])
      w15_stream_bytes(small_destination, "state").should eq([0_u8, 249_u8, 7_u8, 0_u8, 249_u8])

      large_destination = File.join(parent, "enum16")
      CrystalClick::WidePartWriter.write_uint64_nullable_enum16_pair(
        large_destination, "pk", keys.to_unsafe.to_slice(keys.size), "state",
        large.to_unsafe.to_slice(large.size), "Enum16('neg' = -257, 'pos' = 257)", 2
      ).should eq(large_destination)
      w15_stream_bytes(large_destination, "state.null").should eq([1_u8, 0_u8, 0_u8, 1_u8, 0_u8])
      w15_stream_bytes(large_destination, "state").should eq(w15_le_bytes([0_i16, -257_i16, 257_i16, 0_i16, -257_i16]))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes Enum8 and Enum16 signed backing endpoints exactly" do
    parent = File.tempname("crystal-click-w15-enum-endpoints")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    small = [Int8::MIN, Int8::MAX, Int8::MIN, Int8::MAX, Int8::MIN]
    large = [Int16::MIN, Int16::MAX, Int16::MIN, Int16::MAX, Int16::MIN]
    small_type = "Enum8('min' = -128, 'max' = 127)"
    large_type = "Enum16('min' = -32768, 'max' = 32767)"
    nullable_small = [nil, Int8::MIN.as(Int8?), Int8::MAX.as(Int8?), nil, Int8::MIN.as(Int8?)]
    nullable_large = [nil, Int16::MIN.as(Int16?), Int16::MAX.as(Int16?), nil, Int16::MIN.as(Int16?)]

    begin
      small_destination = File.join(parent, "enum8")
      CrystalClick::WidePartWriter.write_uint64_enum8_pair(
        small_destination, "pk", keys.to_unsafe.to_slice(keys.size), "state",
        small.to_unsafe.to_slice(small.size), small_type, 2
      )
      File.read(File.join(small_destination, "columns.txt")).should contain("`state` #{small_type}\n")
      w15_stream_bytes(small_destination, "state").should eq(small.map(&.unsafe_as(UInt8)))

      large_destination = File.join(parent, "enum16")
      CrystalClick::WidePartWriter.write_uint64_enum16_pair(
        large_destination, "pk", keys.to_unsafe.to_slice(keys.size), "state",
        large.to_unsafe.to_slice(large.size), large_type, 2
      )
      File.read(File.join(large_destination, "columns.txt")).should contain("`state` #{large_type}\n")
      w15_stream_bytes(large_destination, "state").should eq(w15_le_bytes(large))

      nullable_small_destination = File.join(parent, "nullable-enum8")
      CrystalClick::WidePartWriter.write_uint64_nullable_enum8_pair(
        nullable_small_destination, "pk", keys.to_unsafe.to_slice(keys.size), "state",
        nullable_small.to_unsafe.to_slice(nullable_small.size), small_type, 2
      )
      w15_stream_bytes(nullable_small_destination, "state.null").should eq([1_u8, 0_u8, 0_u8, 1_u8, 0_u8])
      w15_stream_bytes(nullable_small_destination, "state").should eq([0_u8, 128_u8, 127_u8, 0_u8, 128_u8])

      nullable_large_destination = File.join(parent, "nullable-enum16")
      CrystalClick::WidePartWriter.write_uint64_nullable_enum16_pair(
        nullable_large_destination, "pk", keys.to_unsafe.to_slice(keys.size), "state",
        nullable_large.to_unsafe.to_slice(nullable_large.size), large_type, 2
      )
      w15_stream_bytes(nullable_large_destination, "state.null").should eq([1_u8, 0_u8, 0_u8, 1_u8, 0_u8])
      w15_stream_bytes(nullable_large_destination, "state").should eq(w15_le_bytes([0_i16, Int16::MIN, Int16::MAX, 0_i16, Int16::MIN]))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects undeclared enum codes, malformed enum metadata, and invalid scale before staging" do
    parent = File.tempname("crystal-click-w15-invalid")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64]
    enum_values = [1_i8, 2_i8]
    decimal_values = [0_i32, 1_i32]

    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_enum8_pair(
          File.join(parent, "bad-enum"), "pk", keys.to_unsafe.to_slice(keys.size), "state",
          enum_values.to_unsafe.to_slice(enum_values.size), "Enum8('one' = 1)", 1
        )
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_enum8_pair(
          File.join(parent, "bad-enum-type"), "pk", keys.to_unsafe.to_slice(keys.size), "state",
          enum_values.to_unsafe.to_slice(enum_values.size), "Enum8('one' = 1)\n3 columns:", 1
        )
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_enum8_pair(
          File.join(parent, "bad-enum-spacing"), "pk", keys.to_unsafe.to_slice(keys.size), "state",
          enum_values.to_unsafe.to_slice(enum_values.size), "Enum8('one'=1, 'two'=2)", 1
        )
      end
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_decimal32_pair(
          File.join(parent, "bad-decimal"), "pk", keys.to_unsafe.to_slice(keys.size), "amount",
          decimal_values.to_unsafe.to_slice(decimal_values.size), 10, 1
        )
      end
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
