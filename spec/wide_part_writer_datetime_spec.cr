require "./spec_helper"

private def writer_datetime_mark_rows(path : String, logical_stream : String) : Array(UInt64)
  mark_path = File.join(path, "#{CrystalClick::StreamName.hash(logical_stream)}.mrk2")
  bytes = File.read(mark_path).to_slice
  raise "invalid DateTime writer mark fixture" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE + 16
    value = 0_u64
    8.times { |byte| value |= bytes[offset + byte].to_u64 << (byte * 8) }
    value
  end
end

private def writer_datetime_seconds_bytes(values : Array(UInt32)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    4.times { |index| bytes << ((value >> (index * 8)) & 0xff_u32).to_u8 }
  end
  bytes
end

private def writer_datetime64_tick_bytes(values : Array(Int64)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    bits = value.unsafe_as(UInt64)
    8.times { |index| bytes << ((bits >> (index * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

private def writer_datetime_decoded_stream(path : String, logical_stream : String) : Array(UInt8)
  data_path = File.join(path, "#{CrystalClick::StreamName.hash(logical_stream)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(data_path).to_slice).to_a
end

private def assert_writer_datetime_shape(
  path : String,
  key_name : String,
  value_name : String,
  type_name : String,
  expected_bytes : Array(UInt8),
) : Nil
  File.read(File.join(path, "columns.txt")).should eq(
    "columns format version: 1\n2 columns:\n`#{key_name}` UInt64\n`#{value_name}` #{type_name}\n"
  )
  File.read(File.join(path, "columns_substreams.txt")).should eq(
    "columns substreams version: 1\n2 columns:\n1 substreams for column `#{key_name}`:\n\t#{key_name}\n1 substreams for column `#{value_name}`:\n\t#{value_name}\n"
  )
  File.read(File.join(path, "default_compression_codec.txt")).should eq("CODEC(LZ4)")
  File.exists?(File.join(path, "serialization.json")).should be_false
  Dir.glob(File.join(path, "*.bin")).size.should eq(2)
  Dir.glob(File.join(path, "*.mrk2")).size.should eq(2)
  Dir.glob(File.join(path, "*.cmrk2")).should be_empty
  writer_datetime_decoded_stream(path, value_name).should eq(expected_bytes)
  writer_datetime_mark_rows(path, key_name).should eq([2_u64, 2_u64, 1_u64, 0_u64])
  writer_datetime_mark_rows(path, value_name).should eq([2_u64, 2_u64, 1_u64, 0_u64])
end

describe CrystalClick::WidePartWriter do
  it "writes DateTime raw UInt32 epoch seconds with exact metadata, bytes, and marks" do
    parent = File.tempname("crystal-click-wide-writer-datetime")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    seconds = [0_u32, 1_u32, 1_700_000_000_u32, 2_000_000_000_u32, UInt32::MAX]

    begin
      CrystalClick::WidePartWriter.write_uint64_datetime_pair(
        destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "event_time",
        seconds.to_unsafe.to_slice(seconds.size),
        rows_per_mark: 2
      )

      assert_writer_datetime_shape(destination, "pk", "event_time", "DateTime", writer_datetime_seconds_bytes(seconds))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes DateTime64 raw signed ticks at precision 0, 3, and 9" do
    parent = File.tempname("crystal-click-wide-writer-datetime64")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    ticks = [Int64::MIN, -1_i64, 0_i64, 1_i64, Int64::MAX]

    begin
      {0, 3, 9}.each do |scale|
        destination = File.join(parent, "scale-#{scale}")
        value_name = "event_time64_#{scale}"
        CrystalClick::WidePartWriter.write_uint64_datetime64_pair(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          value_name,
          ticks.to_unsafe.to_slice(ticks.size),
          scale,
          2
        )

        assert_writer_datetime_shape(destination, "pk", value_name, "DateTime64(#{scale})", writer_datetime64_tick_bytes(ticks))
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps inferred UInt32 and Int64 values numeric" do
    parent = File.tempname("crystal-click-wide-writer-datetime-numeric")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64]
    seconds = [0_u32, UInt32::MAX]
    ticks = [Int64::MIN, Int64::MAX]

    begin
      uint32_destination = File.join(parent, "uint32")
      CrystalClick::WidePartWriter.write_uint64_typed_pair(
        uint32_destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "value",
        seconds.to_unsafe.to_slice(seconds.size),
        rows_per_mark: 1
      )
      File.read(File.join(uint32_destination, "columns.txt")).should contain("`value` UInt32")

      int64_destination = File.join(parent, "int64")
      CrystalClick::WidePartWriter.write_uint64_typed_pair(
        int64_destination,
        "pk",
        keys.to_unsafe.to_slice(keys.size),
        "value",
        ticks.to_unsafe.to_slice(ticks.size),
        rows_per_mark: 1
      )
      File.read(File.join(int64_destination, "columns.txt")).should contain("`value` Int64")
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects invalid DateTime64 precision and malformed input before publishing" do
    parent = File.tempname("crystal-click-wide-writer-datetime64-invalid")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64]
    ticks = [Int64::MIN, Int64::MAX]

    begin
      {-1, 10}.each do |scale|
        destination = File.join(parent, "bad-scale-#{scale}")
        expect_raises(ArgumentError) do
          CrystalClick::WidePartWriter.write_uint64_datetime64_pair(
            destination,
            "pk",
            keys.to_unsafe.to_slice(keys.size),
            "value",
            ticks.to_unsafe.to_slice(ticks.size),
            scale,
            1
          )
        end
        Dir.exists?(destination).should be_false
        Dir.children(parent).should be_empty
      end

      mismatched_destination = File.join(parent, "mismatched")
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_datetime_pair(
          mismatched_destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "value",
          [0_u32].to_unsafe.to_slice(1),
          rows_per_mark: 1
        )
      end
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "cleans staged DateTime and DateTime64 parts after exclusive publication fails" do
    parent = File.tempname("crystal-click-wide-writer-datetime-publish-failure")
    Dir.mkdir(parent)
    destination = File.join(parent, "x" * 256)
    keys = [1_u64]
    seconds = [UInt32::MAX]
    ticks = [Int64::MIN]

    begin
      expect_raises(IO::Error) do
        CrystalClick::WidePartWriter.write_uint64_datetime_pair(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "event_time",
          seconds.to_unsafe.to_slice(seconds.size),
          rows_per_mark: 1
        )
      end
      Dir.children(parent).should be_empty

      expect_raises(IO::Error) do
        CrystalClick::WidePartWriter.write_uint64_datetime64_pair(
          destination,
          "pk",
          keys.to_unsafe.to_slice(keys.size),
          "event_time64",
          ticks.to_unsafe.to_slice(ticks.size),
          3,
          1
        )
      end
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
