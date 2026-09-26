require "./spec_helper"

private def writer_date_mark_rows(path : String, logical_stream : String) : Array(UInt64)
  mark_path = File.join(path, "#{CrystalClick::StreamName.hash(logical_stream)}.mrk2")
  bytes = File.read(mark_path).to_slice
  raise "invalid date-writer mark fixture" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE + 16
    value = 0_u64
    8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
    value
  end
end

private def writer_date_code_bytes(values : Array(UInt16)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    2.times { |index| bytes << ((value >> (index * 8)) & 0xff_u16).to_u8 }
  end
  bytes
end

private def writer_date32_code_bytes(values : Array(Int32)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    bits = value.unsafe_as(UInt32)
    4.times { |index| bytes << ((bits >> (index * 8)) & 0xff_u32).to_u8 }
  end
  bytes
end

private def writer_date_decoded_stream(path : String, logical_stream : String) : Array(UInt8)
  data_path = File.join(path, "#{CrystalClick::StreamName.hash(logical_stream)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(data_path).to_slice).to_a
end

describe CrystalClick::WidePartWriter do
  it "writes Date raw UInt16 day codes with exact metadata and mark boundaries" do
    parent = File.tempname("crystal-click-wide-writer-date")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    codes = [0_u16, 1_u16, 32_768_u16, 65_534_u16, UInt16::MAX]

    begin
      CrystalClick::WidePartWriter.write_uint64_date_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "event_date",
        codes.to_unsafe.to_slice(codes.size),
        rows_per_mark: 2
      )

      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`event_date` Date\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n1 substreams for column `event_date`:\n\tevent_date\n"
      )
      File.exists?(File.join(destination, "serialization.json")).should be_false
      writer_date_decoded_stream(destination, "event_date").should eq(writer_date_code_bytes(codes))
      writer_date_mark_rows(destination, "pk").should eq([2_u64, 2_u64, 1_u64, 0_u64])
      writer_date_mark_rows(destination, "event_date").should eq([2_u64, 2_u64, 1_u64, 0_u64])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes Date32 raw signed Int32 day codes including both extrema across marks" do
    parent = File.tempname("crystal-click-wide-writer-date32")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    codes = [Int32::MIN, -1_i32, 0_i32, 1_i32, Int32::MAX]

    begin
      CrystalClick::WidePartWriter.write_uint64_date32_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "event_date32",
        codes.to_unsafe.to_slice(codes.size),
        rows_per_mark: 2
      )

      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`event_date32` Date32\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n1 substreams for column `event_date32`:\n\tevent_date32\n"
      )
      writer_date_decoded_stream(destination, "event_date32").should eq(writer_date32_code_bytes(codes))
      writer_date_mark_rows(destination, "pk").should eq([2_u64, 2_u64, 1_u64, 0_u64])
      writer_date_mark_rows(destination, "event_date32").should eq([2_u64, 2_u64, 1_u64, 0_u64])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps inferred UInt16 and Int32 values numeric instead of treating them as dates" do
    parent = File.tempname("crystal-click-wide-writer-date-numeric")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64]
    uint16_values = [0_u16, UInt16::MAX]
    int32_values = [Int32::MIN, Int32::MAX]

    begin
      uint16_destination = File.join(parent, "uint16")
      CrystalClick::WidePartWriter.write_uint64_typed_pair(
        uint16_destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "value",
        uint16_values.to_unsafe.to_slice(uint16_values.size),
        rows_per_mark: 1
      )
      File.read(File.join(uint16_destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`value` UInt16\n"
      )

      int32_destination = File.join(parent, "int32")
      CrystalClick::WidePartWriter.write_uint64_typed_pair(
        int32_destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "value",
        int32_values.to_unsafe.to_slice(int32_values.size),
        rows_per_mark: 1
      )
      File.read(File.join(int32_destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`value` Int32\n"
      )
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects invalid Date and Date32 inputs before publishing a part" do
    parent = File.tempname("crystal-click-wide-writer-date-invalid")
    Dir.mkdir(parent)

    begin
      date_destination = File.join(parent, "date")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_date_pair(
          date_destination,
          "pk",
          [1_u64, 2_u64].to_unsafe.to_slice(2),
          "value",
          [0_u16].to_unsafe.to_slice(1),
          rows_per_mark: 1
        )
      end
      Dir.exists?(date_destination).should be_false

      date32_destination = File.join(parent, "date32")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_date32_pair(
          date32_destination,
          "pk",
          [1_u64, 2_u64].to_unsafe.to_slice(2),
          "value",
          [Int32::MIN].to_unsafe.to_slice(1),
          rows_per_mark: 1
        )
      end
      Dir.children(parent).should eq([] of String)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "removes staged Date and Date32 parts when exclusive publication fails" do
    parent = File.tempname("crystal-click-wide-writer-date-publish-failure")
    Dir.mkdir(parent)
    destination = File.join(parent, "x" * 256)
    keys = [1_u64]
    date_codes = [0_u16]
    date32_codes = [Int32::MIN]

    begin
      expect_raises(IO::Error) do
        CrystalClick::WidePartWriter.write_uint64_date_pair(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "value",
          date_codes.to_unsafe.to_slice(date_codes.size),
          rows_per_mark: 1
        )
      end
      Dir.children(parent).should eq([] of String)

      expect_raises(IO::Error) do
        CrystalClick::WidePartWriter.write_uint64_date32_pair(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "value",
          date32_codes.to_unsafe.to_slice(date32_codes.size),
          rows_per_mark: 1
        )
      end
      Dir.children(parent).should eq([] of String)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
