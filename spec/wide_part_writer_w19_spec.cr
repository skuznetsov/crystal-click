require "./spec_helper"

private def w19_ipv6(hextets : Tuple(UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16, UInt16)) : CrystalClick::IPv6Value
  CrystalClick::IPv6Value.from_hextets(
    hextets[0], hextets[1], hextets[2], hextets[3],
    hextets[4], hextets[5], hextets[6], hextets[7]
  )
end

private def w19_ipv6_stream(path : String, logical_stream : String) : Array(UInt8)
  data_path = File.join(path, "#{CrystalClick::StreamName.hash(logical_stream)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(data_path).to_slice).to_a
end

private def w19_ipv6_mark_rows(path : String, stream : String) : Array(UInt64)
  marks_path = File.join(path, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  bytes = File.read(marks_path).to_slice
  raise "invalid W19 IPv6 mark fixture" unless bytes.size % CrystalClick::WidePart::MARK_SIZE == 0
  Array(UInt64).new(bytes.size // CrystalClick::WidePart::MARK_SIZE) do |index|
    offset = index * CrystalClick::WidePart::MARK_SIZE + 16
    row_count = 0_u64
    8.times { |byte| row_count |= bytes[offset + byte].to_u64 << (byte * 8) }
    row_count
  end
end

private def w19_assert_ipv6_serialization(path : String) : Nil
  JSON.parse(File.read(File.join(path, "serialization.json"))).as_h.should eq({
    "columns"                                                => JSON::Any.new([] of JSON::Any),
    "propagate_types_serialization_versions_to_nested_types" => JSON::Any.new(true),
    "types_serialization_versions"                           => JSON::Any.new({"string" => JSON::Any.new(1_i64)} of String => JSON::Any),
    "version"                                                => JSON::Any.new(1_i64),
  })
  CrystalClick::PartChecksums.open(path).entries.has_key?("serialization.json").should be_true
end

describe CrystalClick::WidePartWriter do
  it "writes exact IPv6 metadata and 16-byte network-order payloads across marks" do
    parent = File.tempname("crystal-click-w19-ipv6")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    values = [
      w19_ipv6({0x2001_u16, 0x0db8_u16, 0x85a3_u16, 0_u16, 0_u16, 0x8a2e_u16, 0x0370_u16, 0x7334_u16}),
      w19_ipv6({0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16}),
      w19_ipv6({0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 1_u16}),
      w19_ipv6({0x2001_u16, 0x0db8_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 1_u16}),
      w19_ipv6({1_u16, 2_u16, 3_u16, 4_u16, 5_u16, 6_u16, 7_u16, 8_u16}),
    ]
    expected_payload = [
      0x20_u8, 0x01_u8, 0x0d_u8, 0xb8_u8, 0x85_u8, 0xa3_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8, 0x8a_u8, 0x2e_u8, 0x03_u8, 0x70_u8, 0x73_u8, 0x34_u8,
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x01_u8,
      0x20_u8, 0x01_u8, 0x0d_u8, 0xb8_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x01_u8,
      0x00_u8, 0x01_u8, 0x00_u8, 0x02_u8, 0x00_u8, 0x03_u8, 0x00_u8, 0x04_u8,
      0x00_u8, 0x05_u8, 0x00_u8, 0x06_u8, 0x00_u8, 0x07_u8, 0x00_u8, 0x08_u8,
    ]

    begin
      CrystalClick::WidePartWriter.write_uint64_ipv6_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        values.to_unsafe.to_slice(values.size), 2
      ).should eq(destination)

      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` IPv6\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n1 substreams for column `payload`:\n\tpayload\n"
      )
      w19_assert_ipv6_serialization(destination)
      w19_ipv6_stream(destination, "payload").should eq(expected_payload)
      w19_ipv6_mark_rows(destination, "pk").should eq([2_u64, 2_u64, 1_u64, 0_u64])
      w19_ipv6_mark_rows(destination, "payload").should eq([2_u64, 2_u64, 1_u64, 0_u64])
      Dir.glob(File.join(destination, "*.cmrk2")).should be_empty
      CrystalClick::WidePart.open_typed(destination, "payload").read_ipv6s_mark_range("payload", 0, 3)
        .should eq(values)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "writes BASIC Nullable(IPv6) with NULL distinct from :: and zero-filled nested slots" do
    parent = File.tempname("crystal-click-w19-nullable-ipv6")
    Dir.mkdir(parent)
    destination = File.join(parent, "part")
    keys = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
    zero = w19_ipv6({0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16})
    loopback = w19_ipv6({0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 1_u16})
    asymmetric = w19_ipv6({0x2001_u16, 0x0db8_u16, 0x85a3_u16, 0_u16, 0_u16, 0x8a2e_u16, 0x0370_u16, 0x7334_u16})
    values = [
      nil.as(CrystalClick::IPv6Value?),
      zero.as(CrystalClick::IPv6Value?),
      loopback.as(CrystalClick::IPv6Value?),
      nil.as(CrystalClick::IPv6Value?),
      asymmetric.as(CrystalClick::IPv6Value?),
    ]
    expected_payload = [
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x01_u8,
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8, 0x00_u8,
      0x20_u8, 0x01_u8, 0x0d_u8, 0xb8_u8, 0x85_u8, 0xa3_u8, 0x00_u8, 0x00_u8,
      0x00_u8, 0x00_u8, 0x8a_u8, 0x2e_u8, 0x03_u8, 0x70_u8, 0x73_u8, 0x34_u8,
    ]

    begin
      CrystalClick::WidePartWriter.write_uint64_nullable_ipv6_pair(
        destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
        values.to_unsafe.to_slice(values.size), 2
      ).should eq(destination)

      File.read(File.join(destination, "columns.txt")).should eq(
        "columns format version: 1\n2 columns:\n`pk` UInt64\n`payload` Nullable(IPv6)\n"
      )
      File.read(File.join(destination, "columns_substreams.txt")).should eq(
        "columns substreams version: 1\n2 columns:\n1 substreams for column `pk`:\n\tpk\n2 substreams for column `payload`:\n\tpayload.null\n\tpayload\n"
      )
      w19_assert_ipv6_serialization(destination)
      w19_ipv6_stream(destination, "payload.null").should eq([1_u8, 0_u8, 0_u8, 1_u8, 0_u8])
      w19_ipv6_stream(destination, "payload").should eq(expected_payload)
      w19_ipv6_mark_rows(destination, "pk").should eq([2_u64, 2_u64, 1_u64, 0_u64])
      w19_ipv6_mark_rows(destination, "payload.null").should eq([2_u64, 2_u64, 1_u64, 0_u64])
      w19_ipv6_mark_rows(destination, "payload").should eq([2_u64, 2_u64, 1_u64, 0_u64])
      Dir.glob(File.join(destination, "*.cmrk2")).should be_empty
      CrystalClick::WidePart.open_typed(destination, "payload").read_nullable_ipv6s_mark_range("payload", 0, 3)
        .should eq(values)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects UUID and UInt128 inference and invalid rows before staging" do
    parent = File.tempname("crystal-click-w19-ipv6-reject")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64]
    ipv6_values = [w19_ipv6({0x2001_u16, 0x0db8_u16, 0x85a3_u16, 0_u16, 0_u16, 0x8a2e_u16, 0x0370_u16, 0x7334_u16})]
    nullable_ipv6_values = [nil.as(CrystalClick::IPv6Value?)]
    uuid_values = [CrystalClick::UUIDValue.new(0x20010db885a30000_u64, 0x00008a2e03707334_u64)]
    nullable_uuid_values = [nil.as(CrystalClick::UUIDValue?)]
    uint128_values = [0_u128, UInt128::MAX]

    begin
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_typed_pair(
          File.join(parent, "bare-uuid"), "pk", [1_u64].to_unsafe.to_slice(1), "payload",
          uuid_values.to_unsafe.to_slice(uuid_values.size), 1
        )
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_typed_pair(
          File.join(parent, "nullable-uuid"), "pk", [1_u64].to_unsafe.to_slice(1), "payload",
          nullable_uuid_values.to_unsafe.to_slice(nullable_uuid_values.size), 1
        )
      end
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_typed_pair(
          File.join(parent, "uint128"), "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          uint128_values.to_unsafe.to_slice(uint128_values.size), 1
        )
      end
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_ipv6_pair(
          File.join(parent, "bare-mismatch"), "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          ipv6_values.to_unsafe.to_slice(ipv6_values.size), 1
        )
      end
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_nullable_ipv6_pair(
          File.join(parent, "nullable-mismatch"), "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          nullable_ipv6_values.to_unsafe.to_slice(nullable_ipv6_values.size), 1
        )
      end
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
