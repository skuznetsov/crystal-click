require "./spec_helper"

private def w18_ipv4(octets : Tuple(UInt8, UInt8, UInt8, UInt8)) : CrystalClick::IPv4Value
  CrystalClick::IPv4Value.from_octets(octets[0], octets[1], octets[2], octets[3])
end

private def w18_ipv4_stream(path : String, logical_stream : String) : Array(UInt8)
  data_path = File.join(path, "#{CrystalClick::StreamName.hash(logical_stream)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(data_path).to_slice).to_a
end

private def w18_ipv4_mark_rows(path : String, stream : String) : Array(UInt64)
  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  bytes = File.read(marks_path).to_slice
  raise "invalid W18 IPv4 mark fixture" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE + 16
    row_count = 0_u64
    8.times { |byte| row_count |= bytes[offset + byte].to_u64 << (byte * 8) }
    row_count
  end
end

private def w18_ipv4_bytes(values : Array(CrystalClick::IPv4Value)) : Array(UInt8)
  values.flat_map do |value|
    address = value.network_order
    4.times.map { |index| ((address >> (index * 8)) & 0xff_u32).to_u8 }
  end
end

private def w18_nullable_ipv4_bytes(values : Array(CrystalClick::IPv4Value?)) : Array(UInt8)
  nested = values.map { |value| value || w18_ipv4({0_u8, 0_u8, 0_u8, 0_u8}) }
  w18_ipv4_bytes(nested)
end

describe CrystalClick::WidePartWriter do
  it "writes exact IPv4 metadata and little-endian network-order payload bytes" do
    parent = File.tempname("crystal-click-w18-ipv4")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    values = [
      w18_ipv4({1_u8, 2_u8, 3_u8, 4_u8}),
      w18_ipv4({4_u8, 3_u8, 2_u8, 1_u8}),
      w18_ipv4({0_u8, 0_u8, 0_u8, 0_u8}),
      w18_ipv4({203_u8, 0_u8, 113_u8, 9_u8}),
      w18_ipv4({255_u8, 255_u8, 255_u8, 255_u8}),
    ]

    begin
      CrystalClick::WidePartWriter.write_uint64_ipv4_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        values.to_unsafe.to_slice(values.size), 2
      ).should eq(destination)

      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` IPv4\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n1 substreams for column `payload`:\n\tpayload\n"
      )
      JSON.parse(File.read(File.join(destination, "serialization.json"))).as_h.should eq({
        "columns"                                                => JSON::Any.new([] of JSON::Any),
        "propagate_types_serialization_versions_to_nested_types" => JSON::Any.new(true),
        "types_serialization_versions"                           => JSON::Any.new({"string" => JSON::Any.new(1_i64)} of String => JSON::Any),
        "version"                                                => JSON::Any.new(1_i64),
      })
      CrystalClick::PartChecksums.open(destination).entries.has_key?("serialization.json").should be_true
      w18_ipv4_stream(destination, "payload").should eq(w18_ipv4_bytes(values))
      w18_ipv4_stream(destination, "payload")[0, 4].should eq([0x04_u8, 0x03_u8, 0x02_u8, 0x01_u8])
      w18_ipv4_stream(destination, "payload")[4, 4].should eq([0x01_u8, 0x02_u8, 0x03_u8, 0x04_u8])
      w18_ipv4_mark_rows(destination, "pk").should eq([2_u64, 2_u64, 1_u64, 0_u64])
      w18_ipv4_mark_rows(destination, "payload").should eq([2_u64, 2_u64, 1_u64, 0_u64])
      Dir.glob(File.join(destination, "*.cmrk2")).should be_empty
      CrystalClick::WidePart.open_typed(destination, "payload").read_ipv4s_mark_range("payload", 0, 3)
        .map(&.to_s).should eq(["1.2.3.4", "4.3.2.1", "0.0.0.0", "203.0.113.9", "255.255.255.255"])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes BASIC Nullable(IPv4) with NULL distinct from zero and a zero nested slot" do
    parent = File.tempname("crystal-click-w18-nullable-ipv4")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    values = [
      nil.as(CrystalClick::IPv4Value?),
      w18_ipv4({0_u8, 0_u8, 0_u8, 0_u8}).as(CrystalClick::IPv4Value?),
      w18_ipv4({1_u8, 2_u8, 3_u8, 4_u8}).as(CrystalClick::IPv4Value?),
      nil.as(CrystalClick::IPv4Value?),
      w18_ipv4({4_u8, 3_u8, 2_u8, 1_u8}).as(CrystalClick::IPv4Value?),
    ]

    begin
      CrystalClick::WidePartWriter.write_uint64_nullable_ipv4_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        values.to_unsafe.to_slice(values.size), 2
      ).should eq(destination)

      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Nullable(IPv4)\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n2 substreams for column `payload`:\n\tpayload.null\n\tpayload\n"
      )
      JSON.parse(File.read(File.join(destination, "serialization.json"))).as_h.should eq({
        "columns"                                                => JSON::Any.new([] of JSON::Any),
        "propagate_types_serialization_versions_to_nested_types" => JSON::Any.new(true),
        "types_serialization_versions"                           => JSON::Any.new({"string" => JSON::Any.new(1_i64)} of String => JSON::Any),
        "version"                                                => JSON::Any.new(1_i64),
      })
      CrystalClick::PartChecksums.open(destination).entries.has_key?("serialization.json").should be_true
      w18_ipv4_stream(destination, "payload.null").should eq([1_u8, 0_u8, 0_u8, 1_u8, 0_u8])
      w18_nullable_ipv4_bytes(values).should eq(w18_ipv4_stream(destination, "payload"))
      w18_ipv4_mark_rows(destination, "pk").should eq([2_u64, 2_u64, 1_u64, 0_u64])
      w18_ipv4_mark_rows(destination, "payload.null").should eq([2_u64, 2_u64, 1_u64, 0_u64])
      w18_ipv4_mark_rows(destination, "payload").should eq([2_u64, 2_u64, 1_u64, 0_u64])
      Dir.glob(File.join(destination, "*.cmrk2")).should be_empty
      CrystalClick::WidePart.open_typed(destination, "payload").read_nullable_ipv4s_mark_range("payload", 0, 3)
        .map { |value| value.try(&.to_s) }.should eq([nil, "0.0.0.0", "1.2.3.4", nil, "4.3.2.1"])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps UInt32 inference numeric and rejects invalid rows before staging" do
    parent = File.tempname("crystal-click-w18-ipv4-reject")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64]
    ipv4_values = [w18_ipv4({1_u8, 2_u8, 3_u8, 4_u8})]
    nullable_values = [nil.as(CrystalClick::IPv4Value?)]
    uint32_values = [0x01020304_u32, 0_u32]

    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_ipv4_pair(
          File.join(parent, "bare-mismatch"), "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          ipv4_values.to_unsafe.to_slice(ipv4_values.size), 1
        )
      end
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_nullable_ipv4_pair(
          File.join(parent, "nullable-mismatch"), "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          nullable_values.to_unsafe.to_slice(nullable_values.size), 1
        )
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_typed_pair(
          File.join(parent, "inferred-ipv4"), "pk", [1_u64].to_unsafe.to_slice(1), "payload",
          ipv4_values.to_unsafe.to_slice(ipv4_values.size), 1
        )
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_typed_pair(
          File.join(parent, "inferred-nullable-ipv4"), "pk", [1_u64].to_unsafe.to_slice(1), "payload",
          nullable_values.to_unsafe.to_slice(nullable_values.size), 1
        )
      end
      Dir.children(parent).should be_empty

      inferred = File.join(parent, "still-uint32")
      CrystalClick::WidePartWriter.write_uint64_typed_pair(
        inferred, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        uint32_values.to_unsafe.to_slice(uint32_values.size), 1
      )
      File.read(File.join(inferred, "columns.txt")).should contain("`payload` UInt32\n")
      Dir.children(parent).should eq(["still-uint32"])
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "cleans staging after exclusive publication fails" do
    parent = File.tempname("crystal-click-w18-ipv4-publish-failure")
    Dir.mkdir(parent)
    destination = File.join(parent, "x" * 256)
    values = [w18_ipv4({1_u8, 2_u8, 3_u8, 4_u8})]

    begin
      expect_raises(IO::Error) do
        CrystalClick::WidePartWriter.write_uint64_ipv4_pair(
          destination, "pk", [1_u64].to_unsafe.to_slice(1), "payload",
          values.to_unsafe.to_slice(values.size), 1
        )
      end
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
