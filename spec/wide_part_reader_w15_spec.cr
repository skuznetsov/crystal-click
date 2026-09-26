require "./spec_helper"

private def w15_reader_keys(size : Int) : Array(UInt64)
  Array(UInt64).new(size) { |index| index.to_u64 + 1_u64 }
end

private def w15_reader_replace_first_stream_byte(part_path : String, stream : String, value : UInt8) : Nil
  data_path = File.join(part_path, "#{CrystalClick::StreamName.hash(stream)}.bin")
  data = File.read(data_path).to_slice.dup
  # Small W15 streams use one LZ4 literal frame; the first raw byte starts at
  # byte 26 after the 16-byte checksum, 9-byte frame header, and token.
  data[26] = value
  File.write(data_path, data)
end

describe CrystalClick::WidePart do
  it "admits the sealed Bool, Enum, and stock-normalized Decimal type forms" do
    [
      "Bool",
      "Nullable(Bool)",
      "Enum8('negative' = -128, 'positive' = 127)",
      "Nullable(Enum8('negative' = -128, 'positive' = 127))",
      "Enum8('quo\\'te' = -7, 'back\\\\slash' = 7)",
      "Enum16('negative' = -32768, 'positive' = 32767)",
      "Nullable(Enum16('negative' = -32768, 'positive' = 32767))",
      "Decimal(9, 0)",
      "Decimal(9, 9)",
      "Nullable(Decimal(9, 2))",
      "Decimal(18, 0)",
      "Decimal(18, 18)",
      "Nullable(Decimal(18, 4))",
    ].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_true
    end

    [
      "Nullable(Nullable(Bool))",
      "Bool(1)",
      "Enum8('overflow' = 128)",
      "Enum8('duplicate' = 1, 'duplicate' = 2)",
      "Enum8('one' = 1, 'two' = 1)",
      "Enum8('unprobed'=1)",
      "Enum8( 'unprobed' = 1)",
      "Enum8('unprobed' = 1,  'also' = 2)",
      "Enum16('overflow' = 32768)",
      "Decimal(8, 2)",
      "Decimal(9, 10)",
      "Decimal(18, 19)",
      "Decimal(19, 2)",
      "Nullable(Decimal(9, 10))",
      "Enum8('unprobed\\nlabel' = 1)",
    ].each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end

    raw_control_type = String.build do |io|
      io << "Enum8('raw"
      io << '\n'
      io << "line' = 1)"
    end
    CrystalClick::WidePart.supports_typed_type?(raw_control_type).should be_false
    CrystalClick::WidePart.supports_w15_semantic_type?("Nullable(Enum8('one' = 1))").should be_false
    CrystalClick::WidePart.supports_nullable_w15_semantic_type?("Nullable(Enum8('one' = 1))").should be_true
    CrystalClick::WidePart.enum8_codes("Enum8('quo\\'te' = -7, 'back\\\\slash' = 7)").should eq(Set(Int8).new([-7_i8, 7_i8]))
    CrystalClick::WidePart.decimal32_scale("Decimal(9, 0)").should eq(0)
    CrystalClick::WidePart.decimal64_scale("Decimal(18, 18)").should eq(18)
    CrystalClick::WidePart.nullable_decimal32_scale("Nullable(Decimal(9, 2))").should eq(2)
    CrystalClick::WidePart.catalog_type("Decimal32(2)").should eq("Decimal(9, 2)")
    CrystalClick::WidePart.catalog_type("Nullable(Decimal64(18))").should eq("Nullable(Decimal(18, 18))")
  end

  it "reads bare and nullable Bool while validating only non-NULL semantic bytes" do
    parent = File.tempname("crystal-click-w15-reader-bool")
    Dir.mkdir(parent)
    keys = w15_reader_keys(3)
    bare = [false, true, false]
    nullable = [nil, true.as(Bool?), false.as(Bool?)]

    begin
      bare_part = File.join(parent, "bool")
      CrystalClick::WidePartWriter.write_uint64_bool_pair(
        bare_part, "pk", keys.to_unsafe.to_slice(keys.size), "flag",
        bare.to_unsafe.to_slice(bare.size), 2
      )
      reader = CrystalClick::WidePart.open_typed(bare_part, "flag")
      reader.column_type.should eq("Bool")
      reader.read_bool_mark_range("flag", 0, reader.mark_count).should eq(bare)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        reader.read_numeric_mark_range("flag", 0, 1, UInt8)
      end

      nullable_part = File.join(parent, "nullable-bool")
      CrystalClick::WidePartWriter.write_uint64_nullable_bool_pair(
        nullable_part, "pk", keys.to_unsafe.to_slice(keys.size), "flag",
        nullable.to_unsafe.to_slice(nullable.size), 2
      )
      nullable_reader = CrystalClick::WidePart.open_typed(nullable_part, "flag")
      nullable_reader.read_nullable_bool_mark_range("flag", 0, nullable_reader.mark_count).should eq(nullable)

      w15_reader_replace_first_stream_byte(bare_part, "flag", 2_u8)
      expect_raises(CrystalClick::CorruptPartError, "Bool byte is not 0 or 1") do
        CrystalClick::WidePart.open_typed(bare_part, "flag").read_bool_mark_range("flag", 0, 1)
      end

      # The nested slot beneath NULL is consumed but not domain-validated.
      w15_reader_replace_first_stream_byte(nullable_part, "flag", 2_u8)
      CrystalClick::WidePart.open_typed(nullable_part, "flag").read_nullable_bool_mark_range("flag", 0, 1).should eq([nil, true])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "reads Enum8/16 raw signed codes, rejects undeclared values, and skips NULL placeholders" do
    parent = File.tempname("crystal-click-w15-reader-enum")
    Dir.mkdir(parent)
    keys = w15_reader_keys(3)
    enum8 = [-7_i8, 0_i8, 7_i8]
    enum16 = [-32_768_i16, 0_i16, 32_767_i16]
    nullable = [nil, -7_i8.as(Int8?), 7_i8.as(Int8?)]
    enum8_type = "Enum8('quo\\'te' = -7, 'back\\\\slash' = 7, 'zero' = 0)"

    begin
      small_part = File.join(parent, "enum8")
      CrystalClick::WidePartWriter.write_uint64_enum8_pair(
        small_part, "pk", keys.to_unsafe.to_slice(keys.size), "state",
        enum8.to_unsafe.to_slice(enum8.size), enum8_type, 2
      )
      small_reader = CrystalClick::WidePart.open_typed(small_part, "state")
      small_reader.column_type.should eq(enum8_type)
      small_reader.read_enum8_codes_mark_range("state", 0, small_reader.mark_count).should eq(enum8)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        small_reader.read_numeric_mark_range("state", 0, 1, Int8)
      end

      large_part = File.join(parent, "enum16")
      CrystalClick::WidePartWriter.write_uint64_enum16_pair(
        large_part, "pk", keys.to_unsafe.to_slice(keys.size), "state",
        enum16.to_unsafe.to_slice(enum16.size), "Enum16('min' = -32768, 'zero' = 0, 'max' = 32767)", 2
      )
      large_reader = CrystalClick::WidePart.open_typed(large_part, "state")
      large_reader.read_enum16_codes_mark_range("state", 0, large_reader.mark_count).should eq(enum16)

      nullable_part = File.join(parent, "nullable-enum8")
      CrystalClick::WidePartWriter.write_uint64_nullable_enum8_pair(
        nullable_part, "pk", keys.to_unsafe.to_slice(keys.size), "state",
        nullable.to_unsafe.to_slice(nullable.size), "Enum8('neg' = -7, 'pos' = 7)", 2
      )
      nullable_reader = CrystalClick::WidePart.open_typed(nullable_part, "state")
      nullable_reader.read_nullable_enum8_codes_mark_range("state", 0, nullable_reader.mark_count).should eq(nullable)

      nullable16_part = File.join(parent, "nullable-enum16")
      nullable16 = [nil, -32_768_i16.as(Int16?), 32_767_i16.as(Int16?)]
      CrystalClick::WidePartWriter.write_uint64_nullable_enum16_pair(
        nullable16_part, "pk", keys.to_unsafe.to_slice(keys.size), "state",
        nullable16.to_unsafe.to_slice(nullable16.size), "Enum16('min' = -32768, 'max' = 32767)", 2
      )
      CrystalClick::WidePart.open_typed(nullable16_part, "state").read_nullable_enum16_codes_mark_range("state", 0, 2).should eq(nullable16)

      w15_reader_replace_first_stream_byte(small_part, "state", 42_u8)
      expect_raises(CrystalClick::CorruptPartError, "Enum8 code is not declared") do
        CrystalClick::WidePart.open_typed(small_part, "state").read_enum8_codes_mark_range("state", 0, 1)
      end
      w15_reader_replace_first_stream_byte(nullable_part, "state", 42_u8)
      CrystalClick::WidePart.open_typed(nullable_part, "state").read_nullable_enum8_codes_mark_range("state", 0, 1).should eq([nil, -7_i8])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "requires the pinned String serialization metadata shape for W15 semantic types" do
    parent = File.tempname("crystal-click-w15-reader-serialization")
    Dir.mkdir(parent)
    keys = w15_reader_keys(1)
    values = [true]

    begin
      bare_part = File.join(parent, "bool")
      CrystalClick::WidePartWriter.write_uint64_bool_pair(
        bare_part, "pk", keys.to_unsafe.to_slice(keys.size), "flag",
        values.to_unsafe.to_slice(values.size), 1
      )
      metadata_path = File.join(bare_part, "serialization.json")
      metadata = File.read(metadata_path)
      metadata.should contain(%("string":1))

      File.delete(metadata_path)
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(bare_part, "flag")
      end

      File.write(metadata_path, metadata.sub(%("string":1), %("string":0)))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(bare_part, "flag")
      end

      File.write(metadata_path, metadata.sub(%("columns":[]), %("columns":[{"name":"flag"}])))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(bare_part, "flag")
      end

      File.write(metadata_path, metadata.sub(%("columns":[]), %("columns":[],"missing_columns":[])))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(bare_part, "flag")
      end

      nullable_part = File.join(parent, "nullable-bool")
      nullable_values = [nil.as(Bool?)]
      CrystalClick::WidePartWriter.write_uint64_nullable_bool_pair(
        nullable_part, "pk", keys.to_unsafe.to_slice(keys.size), "flag",
        nullable_values.to_unsafe.to_slice(nullable_values.size), 1
      )
      nullable_metadata_path = File.join(nullable_part, "serialization.json")
      nullable_metadata = File.read(nullable_metadata_path)
      File.write(nullable_metadata_path, nullable_metadata.sub(%("string":1), %("nullable":0,"string":1)))
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePart.open_typed(nullable_part, "flag")
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "preserves raw Decimal32/64 scaled integers, including backing-width extrema and NULL" do
    parent = File.tempname("crystal-click-w15-reader-decimal")
    Dir.mkdir(parent)
    keys = w15_reader_keys(3)
    values32 = [Int32::MIN, 0_i32, Int32::MAX]
    values64 = [Int64::MIN, 0_i64, Int64::MAX]
    nullable32 = [nil, Int32::MIN.as(Int32?), Int32::MAX.as(Int32?)]
    nullable64 = [nil, Int64::MIN.as(Int64?), Int64::MAX.as(Int64?)]

    begin
      part32 = File.join(parent, "decimal32")
      CrystalClick::WidePartWriter.write_uint64_decimal32_pair(
        part32, "pk", keys.to_unsafe.to_slice(keys.size), "amount",
        values32.to_unsafe.to_slice(values32.size), 2, 2
      )
      reader32 = CrystalClick::WidePart.open_typed(part32, "amount")
      reader32.column_type.should eq("Decimal(9, 2)")
      CrystalClick::WidePart.decimal32_scale(reader32.column_type).should eq(2)
      reader32.read_decimal32_raw_mark_range("amount", 0, reader32.mark_count).should eq(values32)

      part64 = File.join(parent, "decimal64")
      CrystalClick::WidePartWriter.write_uint64_decimal64_pair(
        part64, "pk", keys.to_unsafe.to_slice(keys.size), "amount",
        values64.to_unsafe.to_slice(values64.size), 18, 2
      )
      reader64 = CrystalClick::WidePart.open_typed(part64, "amount")
      CrystalClick::WidePart.decimal64_scale(reader64.column_type).should eq(18)
      reader64.read_decimal64_raw_mark_range("amount", 0, reader64.mark_count).should eq(values64)

      nullable_part32 = File.join(parent, "nullable-decimal32")
      CrystalClick::WidePartWriter.write_uint64_nullable_decimal32_pair(
        nullable_part32, "pk", keys.to_unsafe.to_slice(keys.size), "amount",
        nullable32.to_unsafe.to_slice(nullable32.size), 2, 2
      )
      CrystalClick::WidePart.open_typed(nullable_part32, "amount").read_nullable_decimal32_raw_mark_range("amount", 0, 2).should eq(nullable32)

      nullable_part64 = File.join(parent, "nullable-decimal64")
      CrystalClick::WidePartWriter.write_uint64_nullable_decimal64_pair(
        nullable_part64, "pk", keys.to_unsafe.to_slice(keys.size), "amount",
        nullable64.to_unsafe.to_slice(nullable64.size), 18, 2
      )
      CrystalClick::WidePart.open_typed(nullable_part64, "amount").read_nullable_decimal64_raw_mark_range("amount", 0, 2).should eq(nullable64)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
