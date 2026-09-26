require "./spec_helper"

private def w17_uuid_payload_bytes(values : Array(CrystalClick::UUIDValue)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    8.times { |index| bytes << ((value.high >> (index * 8)) & 0xff_u64).to_u8 }
    8.times { |index| bytes << ((value.low >> (index * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

private def w17_nullable_uuid_payload_bytes(values : Array(CrystalClick::UUIDValue?)) : Array(UInt8)
  bytes = [] of UInt8
  values.each do |value|
    uuid = value || CrystalClick::UUIDValue.new(0_u64, 0_u64)
    8.times { |index| bytes << ((uuid.high >> (index * 8)) & 0xff_u64).to_u8 }
    8.times { |index| bytes << ((uuid.low >> (index * 8)) & 0xff_u64).to_u8 }
  end
  bytes
end

private def w17_nullable_uuid_null_bytes(values : Array(CrystalClick::UUIDValue?)) : Array(UInt8)
  values.map { |value| value.nil? ? 1_u8 : 0_u8 }
end

private def w17_uuid_stream(path : String, logical_stream : String) : Array(UInt8)
  data_path = File.join(path, "#{CrystalClick::StreamName.hash(logical_stream)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(data_path).to_slice).to_a
end

private def w17_uuid_mark_rows(path : String, stream : String) : Array(UInt64)
  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  bytes = File.read(marks_path).to_slice
  raise "invalid W17 UUID mark fixture" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE + 16
    row_count = 0_u64
    8.times { |byte| row_count |= bytes[offset + byte].to_u64 << (byte * 8) }
    row_count
  end
end

private def w17_uuid_hexes(values : Array(CrystalClick::UUIDValue)) : Array(String)
  values.map(&.to_s)
end

private def w17_nullable_uuid_hexes(values : Array(CrystalClick::UUIDValue?)) : Array(String?)
  values.map { |value| value.try(&.to_s) }
end

private def w17_assert_uuid_serialization(path : String) : Nil
  JSON.parse(File.read(File.join(path, "serialization.json"))).as_h.should eq({
    "columns"                                                => JSON::Any.new([] of JSON::Any),
    "propagate_types_serialization_versions_to_nested_types" => JSON::Any.new(true),
    "types_serialization_versions"                           => JSON::Any.new({"string" => JSON::Any.new(1_i64)} of String => JSON::Any),
    "version"                                                => JSON::Any.new(1_i64),
  })
  CrystalClick::PartChecksums.open(path).entries.has_key?("serialization.json").should be_true
end

describe CrystalClick::WidePartWriter do
  it "writes bare UUID halves in the pinned ClickHouse physical byte order" do
    parent = File.tempname("crystal-click-w17-uuid")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    values = [
      CrystalClick::UUIDValue.new(0x0011223344556677_u64, 0x8899aabbccddeeff_u64),
      CrystalClick::UUIDValue.new(0_u64, 0_u64),
      CrystalClick::UUIDValue.new(UInt64::MAX, UInt64::MAX),
      CrystalClick::UUIDValue.new(0x0123456789abcdef_u64, 0xfedcba9876543210_u64),
      CrystalClick::UUIDValue.new(0x1020304050607080_u64, 0x90a0b0c0d0e0f001_u64),
    ]

    begin
      CrystalClick::WidePartWriter.write_uint64_uuid_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        values.to_unsafe.to_slice(values.size), 2
      ).should eq(destination)

      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` UUID\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n1 substreams for column `payload`:\n\tpayload\n"
      )
      File.read(File.join(destination, "default_compression_codec.txt")).should eq("CODEC(LZ4)")
      File.read(File.join(destination, "metadata_version.txt")).should eq("0")
      File.read(File.join(destination, "count.txt")).should eq("5")
      w17_assert_uuid_serialization(destination)
      w17_uuid_stream(destination, "payload").should eq(w17_uuid_payload_bytes(values))
      w17_uuid_stream(destination, "payload")[0, 16].should eq(
        [0x77_u8, 0x66_u8, 0x55_u8, 0x44_u8, 0x33_u8, 0x22_u8, 0x11_u8, 0x00_u8,
         0xff_u8, 0xee_u8, 0xdd_u8, 0xcc_u8, 0xbb_u8, 0xaa_u8, 0x99_u8, 0x88_u8]
      )
      w17_uuid_mark_rows(destination, "pk").should eq([2_u64, 2_u64, 1_u64, 0_u64])
      w17_uuid_mark_rows(destination, "payload").should eq([2_u64, 2_u64, 1_u64, 0_u64])
      Dir.glob(File.join(destination, "*.cmrk2")).should be_empty
      CrystalClick::WidePart.open_typed(destination, "payload").read_uuids_mark_range("payload", 0, 3)
        .map(&.to_s).should eq(w17_uuid_hexes(values))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes BASIC Nullable(UUID) with NULL distinct from zero and a zero-filled nested slot" do
    parent = File.tempname("crystal-click-w17-nullable-uuid")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    zero = CrystalClick::UUIDValue.new(0_u64, 0_u64)
    values = [
      nil.as(CrystalClick::UUIDValue?),
      zero.as(CrystalClick::UUIDValue?),
      CrystalClick::UUIDValue.new(0x0011223344556677_u64, 0x8899aabbccddeeff_u64).as(CrystalClick::UUIDValue?),
      nil.as(CrystalClick::UUIDValue?),
      CrystalClick::UUIDValue.new(UInt64::MAX, UInt64::MAX).as(CrystalClick::UUIDValue?),
    ]

    begin
      CrystalClick::WidePartWriter.write_uint64_nullable_uuid_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        values.to_unsafe.to_slice(values.size), 2
      ).should eq(destination)

      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Nullable(UUID)\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n2 substreams for column `payload`:\n\tpayload.null\n\tpayload\n"
      )
      File.read(File.join(destination, "default_compression_codec.txt")).should eq("CODEC(LZ4)")
      File.read(File.join(destination, "metadata_version.txt")).should eq("0")
      File.read(File.join(destination, "count.txt")).should eq("5")
      w17_assert_uuid_serialization(destination)
      w17_uuid_stream(destination, "payload.null").should eq(w17_nullable_uuid_null_bytes(values))
      w17_uuid_stream(destination, "payload").should eq(w17_nullable_uuid_payload_bytes(values))
      w17_uuid_mark_rows(destination, "pk").should eq([2_u64, 2_u64, 1_u64, 0_u64])
      w17_uuid_mark_rows(destination, "payload.null").should eq([2_u64, 2_u64, 1_u64, 0_u64])
      w17_uuid_mark_rows(destination, "payload").should eq([2_u64, 2_u64, 1_u64, 0_u64])
      Dir.glob(File.join(destination, "*.cmrk2")).should be_empty
      part = CrystalClick::WidePart.open_typed(destination, "payload")
      part.read_nullable_uuids_mark_range("payload", 0, 3).map { |value| value.try(&.to_s) }
        .should eq(w17_nullable_uuid_hexes(values))
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects generic UUID inference and mismatched rows before publication" do
    parent = File.tempname("crystal-click-w17-uuid-reject")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64]
    values = [CrystalClick::UUIDValue.new(0x0011223344556677_u64, 0x8899aabbccddeeff_u64)]
    nullable = [nil.as(CrystalClick::UUIDValue?)]
    uint128_values = [0_u128, UInt128::MAX]
    uuid_text = ["00112233-4455-6677-8899-aabbccddeeff", "00000000-0000-0000-0000-000000000000"]

    begin
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_typed_pair(
          File.join(parent, "inferred"), "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          values.to_unsafe.to_slice(values.size), 1
        )
      end
      Dir.children(parent).should be_empty

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_typed_pair(
          File.join(parent, "nullable-inferred"), "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          nullable.to_unsafe.to_slice(nullable.size), 1
        )
      end
      Dir.children(parent).should be_empty

      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_typed_pair(
          File.join(parent, "uint128-inferred"), "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          uint128_values.to_unsafe.to_slice(uint128_values.size), 1
        )
      end
      Dir.children(parent).should be_empty

      string_destination = File.join(parent, "string-stays-string")
      CrystalClick::WidePartWriter.write_uint64_typed_pair(
        string_destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        uuid_text.to_unsafe.to_slice(uuid_text.size), 1
      )
      File.read(File.join(string_destination, "columns.txt")).should contain("`payload` String\n")

      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_uuid_pair(
          File.join(parent, "mismatched"), "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          values.to_unsafe.to_slice(values.size), 1
        )
      end
      Dir.children(parent).should eq(["string-stays-string"])

      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_nullable_uuid_pair(
          File.join(parent, "nullable-mismatched"), "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          nullable.to_unsafe.to_slice(nullable.size), 1
        )
      end
      Dir.children(parent).should eq(["string-stays-string"])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "cleans staging after exclusive publication fails" do
    parent = File.tempname("crystal-click-w17-uuid-publish-failure")
    Dir.mkdir(parent)
    destination = File.join(parent, "x" * 256)
    values = [CrystalClick::UUIDValue.new(0_u64, 0_u64)]

    begin
      expect_raises(IO::Error) do
        CrystalClick::WidePartWriter.write_uint64_uuid_pair(
          destination, "pk", [1_u64].to_unsafe.to_slice(1), "payload",
          values.to_unsafe.to_slice(values.size), 1
        )
      end
      Dir.children(parent).should eq([] of String)
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
