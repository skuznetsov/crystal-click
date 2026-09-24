require "./spec_helper"

def city_hash_spec_pattern(length : Int) : Bytes
  bytes = Bytes.new(length)
  length.times do |index|
    bytes[index] = ((index * 31 + 7) & 0xff).to_u8
  end
  bytes
end

def city_hash_spec_var_uint(bytes : Bytes, cursor : Int32) : {UInt64, Int32}
  value = 0_u64
  shift = 0
  offset = cursor
  loop do
    byte = bytes[offset]
    offset += 1
    value |= (byte & 0x7f).to_u64 << shift
    return {value, offset} if (byte & 0x80) == 0
    shift += 7
  end
end

def city_hash_spec_uint64_le(bytes : Bytes, offset : Int32) : UInt64
  value = 0_u64
  8.times do |index|
    value |= bytes[offset + index].to_u64 << (index * 8)
  end
  value
end

describe CrystalClick::CityHashV1 do
  it "matches ClickHouse CityHash v1.0.2 vectors across short and long inputs" do
    CrystalClick::CityHashV1.hash128("".to_slice).should eq(
      {0x3df09dfc64c09a2b_u64, 0x3cb540c392e51e29_u64}
    )
    CrystalClick::CityHashV1.hash128("a".to_slice).should eq(
      {0xd27139a1afe01ad0_u64, 0xfd7e8ee2e4c86cf6_u64}
    )
    CrystalClick::CityHashV1.hash128("0123456789abcdef".to_slice).should eq(
      {0xc52ea1adb29e4800_u64, 0x7369a2fab076de4c_u64}
    )
    CrystalClick::CityHashV1.hash128(Bytes.new(128, 'x'.ord.to_u8)).should eq(
      {0xe9ab8fd6b63767a7_u64, 0x0b51af1f8c372075_u64}
    )
    CrystalClick::CityHashV1.hash128(Bytes.new(257, 'y'.ord.to_u8)).should eq(
      {0x88862b5a0a3b3ea5_u64, 0x83e46c1a2ba6b49b_u64}
    )
  end

  it "matches seeded vectors used by ClickHouse block hashing" do
    CrystalClick::CityHashV1.hash128_with_seed(
      Bytes.new(257, 'q'.ord.to_u8),
      0x123456789abcdef0_u64,
      0xfedcba9876543210_u64
    ).should eq({0x3051060483794ca3_u64, 0x68d85232bb728730_u64})
  end

  it "matches source-backed seeded short-tail and exact-block vectors" do
    CrystalClick::CityHashV1.hash128_with_seed(
      city_hash_spec_pattern(9),
      0x123456789abcdef0_u64,
      0xfedcba9876543210_u64
    ).should eq({0x05f097b9769ebb60_u64, 0x0450a4a3aaed39b2_u64})

    sixteen_bytes = city_hash_spec_pattern(16)
    CrystalClick::CityHashV1.hash128_with_seed(
      sixteen_bytes,
      0x123456789abcdef0_u64,
      0xfedcba9876543210_u64
    ).should eq({0xd71dcdd16d3324be_u64, 0x6e003856ca3f54c1_u64})
    CrystalClick::CityHashV1.file_hash(sixteen_bytes).should eq(
      {0x26c1206b9ea553ab_u64, 0xb9c34e21ef8571be_u64}
    )
  end

  it "matches source vectors at the short-input and 128-byte path boundaries" do
    expected = {
        7 => {0xd7ba2459ab7c2913_u64, 0x53dd430b513ca460_u64},
        8 => {0xf5a4ca47208136a0_u64, 0x3dd4575b3d46e5ab_u64},
       15 => {0xd956065c63d9ab15_u64, 0x9623caadd0037b73_u64},
       16 => {0x3f3a3275564b7f48_u64, 0xb48a2a7a16bac60b_u64},
       17 => {0xaee34bf68bb2e0a2_u64, 0xe0d6910555f00b87_u64},
      127 => {0xc244dc8a06ce8c41_u64, 0xf30e2cf6b33629a6_u64},
      128 => {0xba863c0c70f32346_u64, 0x24b156fc6f3c170a_u64},
      129 => {0x238598064c8ee2f1_u64, 0x6c89b9263ef7410b_u64},
    }
    expected.each do |length, hash|
      CrystalClick::CityHashV1.hash128(city_hash_spec_pattern(length)).should eq(hash)
    end

    seeded_expected = {
      127 => {0xa7f1b5842958f05a_u64, 0x04c392b0fcb624c7_u64},
      128 => {0x4addd0571f611141_u64, 0xbe4d9378349640c8_u64},
      129 => {0x0f528dd6ca8f0d4e_u64, 0x7442c703c14f9dad_u64},
    }
    seeded_expected.each do |length, hash|
      CrystalClick::CityHashV1.hash128_with_seed(
        city_hash_spec_pattern(length),
        0x123456789abcdef0_u64,
        0xfedcba9876543210_u64
      ).should eq(hash)
    end
  end

  it "matches a ClickHouse-produced compressed-frame checksum" do
    path = File.expand_path("../test/fixtures/public/wide_u64_pk_raw/part/caa7f9c8e43d2fa739d1e26d71e99843.bin", __DIR__)
    bin_contents = File.read(path)
    bytes = bin_contents.to_slice
    frame_size = bytes[17].to_u32 |
                 (bytes[18].to_u32 << 8) |
                 (bytes[19].to_u32 << 16) |
                 (bytes[20].to_u32 << 24)

    frame_size.should be >= 9_u32
    (16 + frame_size).should be <= bytes.size.to_u32
    CrystalClick::CityHashV1.hash128(bytes[16, frame_size.to_i]).should eq(
      {0x7d6af50aa8efd3b3_u64, 0xde34fca699c46a51_u64}
    )
  end

  it "matches ClickHouse's 2048-byte chained file hash" do
    bytes = Bytes.new(5000)
    bytes.size.times do |index|
      bytes[index] = ((index * 31 + 7) & 0xff).to_u8
    end

    CrystalClick::CityHashV1.file_hash(bytes).should eq(
      {0x72d2c4b9e4dcfa65_u64, 0xa9c9e9ea68eac0d4_u64}
    )
  end

  it "matches a physical file hash recorded by the public ClickHouse fixture" do
    part_path = File.expand_path("../test/fixtures/public/wide_u64_pk_raw/part", __DIR__)
    checksum_contents = File.read(File.join(part_path, "checksums.txt"))
    checksum_file = checksum_contents.to_slice
    header_size = CrystalClick::PartChecksums::CHECKSUMS_HEADER.bytesize
    payload = CrystalClick::CompressedBlock.decode_all(checksum_file[header_size, checksum_file.size - header_size])
    count, cursor = city_hash_spec_var_uint(payload, 0)
    recorded_count_hash = nil.as({UInt64, UInt64}?)

    count.to_i.times do
      name_size, cursor = city_hash_spec_var_uint(payload, cursor)
      name = String.new(payload[cursor, name_size.to_i])
      cursor += name_size.to_i
      _, cursor = city_hash_spec_var_uint(payload, cursor) # physical size
      file_hash = {city_hash_spec_uint64_le(payload, cursor), city_hash_spec_uint64_le(payload, cursor + 8)}
      cursor += 16
      compressed = payload[cursor] == 1_u8
      cursor += 1
      if name == "count.txt"
        recorded_count_hash = file_hash
        break
      end
      if compressed
        _, cursor = city_hash_spec_var_uint(payload, cursor)
        cursor += 16
      end
    end

    expected = recorded_count_hash || raise "public checksums.txt has no count.txt hash"
    count_contents = File.read(File.join(part_path, "count.txt"))
    count_bytes = count_contents.to_slice
    CrystalClick::CityHashV1.file_hash(count_bytes).should eq(expected)
  end
end
