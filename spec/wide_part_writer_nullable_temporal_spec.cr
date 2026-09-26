require "./spec_helper"

private def nullable_temporal_writer_mark_rows(path : String, stream : String) : Array(UInt64)
  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  bytes = File.read(marks_path).to_slice
  raise "invalid nullable temporal writer mark fixture" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE + 16
    row_count = 0_u64
    8.times { |byte| row_count |= bytes[offset + byte].to_u64 << (byte * 8) }
    row_count
  end
end

private def nullable_temporal_writer_stream(path : String, logical_stream : String) : Array(UInt8)
  data_path = File.join(path, "#{CrystalClick::StreamName.hash(logical_stream)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(data_path).to_slice).to_a
end

private def nullable_temporal_writer_null_bytes(values : Array(T)) : Array(UInt8) forall T
  values.map { |value| value.nil? ? 1_u8 : 0_u8 }
end

private def nullable_temporal_writer_nested_bytes(values : Array(UInt16?)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    bits = value || 0_u16
    2.times { |index| bytes << ((bits >> (index * 8)) & 0xff_u16).to_u8 }
  end
  bytes
end

private def nullable_temporal_writer_nested_bytes(values : Array(Int32?)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    bits = (value || 0_i32).unsafe_as(UInt32)
    4.times { |index| bytes << ((bits >> (index * 8)) & 0xff_u32).to_u8 }
  end
  bytes
end

private def nullable_temporal_writer_nested_bytes(values : Array(UInt32?)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    bits = value || 0_u32
    4.times { |index| bytes << ((bits >> (index * 8)) & 0xff_u32).to_u8 }
  end
  bytes
end

private def nullable_temporal_writer_nested_bytes(values : Array(Int64?)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    bits = (value || 0_i64).unsafe_as(UInt64)
    8.times { |index| bytes << ((bits >> (index * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

private def assert_nullable_temporal_writer_shape(
  path : String,
  value_name : String,
  type_name : String,
  values : Array(T),
) : Nil forall T
  key_name = "pk"
  part = CrystalClick::WidePart.open_typed(path, value_name)
  part.column_type.should eq("Nullable(#{type_name})")
  part.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
  File.read(File.join(path, "columns.txt")).should eq(
    "columns format version: 1\n2 columns:\n`#{key_name}` UInt64\n`#{value_name}` Nullable(#{type_name})\n"
  )
  File.read(File.join(path, "columns_substreams.txt")).should eq(
    "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n2 substreams for column `#{value_name}`:\n\t#{value_name}.null\n\t#{value_name}\n"
  )
  File.read(File.join(path, "default_compression_codec.txt")).should eq("CODEC(LZ4)")
  serialization = JSON.parse(File.read(File.join(path, "serialization.json"))).as_h
  serialization["columns"].as_a.should be_empty
  serialization["propagate_types_serialization_versions_to_nested_types"].as_bool.should be_true
  serialization["types_serialization_versions"].as_h.should eq({"string" => JSON::Any.new(1_i64)})
  serialization["version"].as_i.should eq(1)
  CrystalClick::PartChecksums.open(path).entries.has_key?("serialization.json").should be_true
  Dir.glob(File.join(path, "*.bin")).size.should eq(3)
  Dir.glob(File.join(path, "*.mrk2")).size.should eq(3)
  Dir.glob(File.join(path, "*.cmrk2")).should be_empty
  nullable_temporal_writer_mark_rows(path, key_name).should eq([2_u64, 2_u64, 2_u64, 1_u64, 0_u64])
  nullable_temporal_writer_mark_rows(path, "#{value_name}.null").should eq([2_u64, 2_u64, 2_u64, 1_u64, 0_u64])
  nullable_temporal_writer_mark_rows(path, value_name).should eq([2_u64, 2_u64, 2_u64, 1_u64, 0_u64])
  nullable_temporal_writer_stream(path, "#{value_name}.null").should eq(nullable_temporal_writer_null_bytes(values))
  nullable_temporal_writer_stream(path, value_name).should eq(nullable_temporal_writer_nested_bytes(values))
end

describe CrystalClick::WidePartWriter do
  it "writes Nullable(Date) raw UInt16 codes with distinct NULL and zero values across marks" do
    parent = File.tempname("crystal-click-wide-writer-nullable-date")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
    values = [nil, 0_u16.as(UInt16?), 1_u16.as(UInt16?), nil, 32_768_u16.as(UInt16?), UInt16::MAX.as(UInt16?), nil]

    begin
      CrystalClick::WidePartWriter.write_uint64_nullable_date_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "event_date",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 2
      ).should eq(destination)

      assert_nullable_temporal_writer_shape(destination, "event_date", "Date", values)
      part = CrystalClick::WidePart.open_typed(destination, "event_date")
      part.read_nullable_date_codes_mark_range("event_date", 0, part.mark_count).should eq(values)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes Nullable(Date32) signed raw Int32 codes including both extrema" do
    parent = File.tempname("crystal-click-wide-writer-nullable-date32")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
    values = [nil, Int32::MIN.as(Int32?), -1_i32.as(Int32?), nil, 0_i32.as(Int32?), Int32::MAX.as(Int32?), nil]

    begin
      CrystalClick::WidePartWriter.write_uint64_nullable_date32_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "event_date32",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 2
      ).should eq(destination)

      assert_nullable_temporal_writer_shape(destination, "event_date32", "Date32", values)
      part = CrystalClick::WidePart.open_typed(destination, "event_date32")
      part.read_nullable_date32_codes_mark_range("event_date32", 0, part.mark_count).should eq(values)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes Nullable(DateTime) raw UInt32 epoch seconds with NULL distinct from zero" do
    parent = File.tempname("crystal-click-wide-writer-nullable-datetime")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
    values = [nil, 0_u32.as(UInt32?), 1_u32.as(UInt32?), nil, 1_700_000_000_u32.as(UInt32?), UInt32::MAX.as(UInt32?), nil]

    begin
      CrystalClick::WidePartWriter.write_uint64_nullable_datetime_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "event_time",
        values.to_unsafe.to_slice(values.size),
        rows_per_mark: 2
      ).should eq(destination)

      assert_nullable_temporal_writer_shape(destination, "event_time", "DateTime", values)
      part = CrystalClick::WidePart.open_typed(destination, "event_time")
      part.read_nullable_datetime_seconds_mark_range("event_time", 0, part.mark_count).should eq(values)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes Nullable(DateTime64(p)) raw Int64 ticks at canonical precisions" do
    parent = File.tempname("crystal-click-wide-writer-nullable-datetime64")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
    values = [nil, Int64::MIN.as(Int64?), -1_i64.as(Int64?), nil, 0_i64.as(Int64?), Int64::MAX.as(Int64?), nil]

    begin
      (0..9).each do |precision|
        destination = File.join(parent, "precision-#{precision}")
        value_name = "event_time64_#{precision}"
        CrystalClick::WidePartWriter.write_uint64_nullable_datetime64_pair(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          value_name,
          values.to_unsafe.to_slice(values.size),
          precision,
          2
        ).should eq(destination)

        assert_nullable_temporal_writer_shape(destination, value_name, "DateTime64(#{precision})", values)
        part = CrystalClick::WidePart.open_typed(destination, value_name)
        part.read_nullable_datetime64_ticks_mark_range(value_name, 0, part.mark_count).should eq(values)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects invalid DateTime64 precision and mismatched rows before staging" do
    parent = File.tempname("crystal-click-wide-writer-nullable-temporal-invalid")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64]
    ticks = [Int64::MIN.as(Int64?), Int64::MAX.as(Int64?)]

    begin
      {-1, 10}.each do |precision|
        destination = File.join(parent, "bad-precision-#{precision}")
        expect_raises(ArgumentError) do
          CrystalClick::WidePartWriter.write_uint64_nullable_datetime64_pair(
            destination,
            "pk",
            keys.to_unsafe.to_slice(keys.size),
            "event_time",
            ticks.to_unsafe.to_slice(ticks.size),
            precision,
            1
          )
        end
        Dir.exists?(destination).should be_false
        Dir.children(parent).should be_empty
      end

      mismatch_destination = File.join(parent, "mismatched")
      mismatch_values = [nil] of UInt16?
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_nullable_date_pair(
          mismatch_destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "event_date",
          mismatch_values.to_unsafe.to_slice(mismatch_values.size),
          rows_per_mark: 1
        )
      end
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "cleans its staging directory when exclusive publication fails" do
    parent = File.tempname("crystal-click-wide-writer-nullable-temporal-publish-failure")
    Dir.mkdir(parent)
    destination = File.join(parent, "x" * 256)
    values = [nil] of Int64?

    begin
      expect_raises(IO::Error) do
        CrystalClick::WidePartWriter.write_uint64_nullable_datetime64_pair(
          destination,
          "pk",
          [1_u64].to_unsafe.to_slice(1),
          "event_time",
          values.to_unsafe.to_slice(values.size),
          3,
          1
        )
      end
      Dir.children(parent).should eq([] of String)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps inferred nullable integer slices numeric" do
    parent = File.tempname("crystal-click-wide-writer-nullable-temporal-numeric")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64]

    begin
      uint16_values = [nil, UInt16::MAX.as(UInt16?)]
      CrystalClick::WidePartWriter.write_uint64_typed_pair(
        File.join(parent, "u16"),
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "value",
        uint16_values.to_unsafe.to_slice(uint16_values.size),
        rows_per_mark: 1
      )
      File.read(File.join(parent, "u16", "columns.txt")).should contain("`value` Nullable(UInt16)")

      int32_values = [nil, Int32::MIN.as(Int32?)]
      CrystalClick::WidePartWriter.write_uint64_typed_pair(
        File.join(parent, "i32"),
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "value",
        int32_values.to_unsafe.to_slice(int32_values.size),
        rows_per_mark: 1
      )
      File.read(File.join(parent, "i32", "columns.txt")).should contain("`value` Nullable(Int32)")

      uint32_values = [nil, UInt32::MAX.as(UInt32?)]
      CrystalClick::WidePartWriter.write_uint64_typed_pair(
        File.join(parent, "u32"),
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "value",
        uint32_values.to_unsafe.to_slice(uint32_values.size),
        rows_per_mark: 1
      )
      File.read(File.join(parent, "u32", "columns.txt")).should contain("`value` Nullable(UInt32)")

      int64_values = [nil, Int64::MAX.as(Int64?)]
      CrystalClick::WidePartWriter.write_uint64_typed_pair(
        File.join(parent, "i64"),
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "value",
        int64_values.to_unsafe.to_slice(int64_values.size),
        rows_per_mark: 1
      )
      File.read(File.join(parent, "i64", "columns.txt")).should contain("`value` Nullable(Int64)")
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
