require "./spec_helper"

describe CrystalClick::ClickHouseSipHash do
  it "matches independent ClickHouse ordinary-0xff 128-bit source-law vectors" do
    # Each oracle string is formatted as 16 hex digits of high followed by
    # 16 hex digits of low; finish128 exposes the pair in {low, high} order.
    vectors = [] of Tuple(Bytes, Tuple(UInt64, UInt64))
    vectors << {Bytes.new(0), {0xe983a656dbc1b532_u64, 0xf711edcba8b6b5e5_u64}}
    vectors << {"by_score.proj".to_slice, {0x417df556f7e94afe_u64, 0xd8c7c32708619f57_u64}}
    vectors << {Bytes[0x61_u8, 0x00_u8, 0x62_u8], {0x8f4e2cfe39775346_u64, 0x7ad54c0d2263a4fc_u64}}
    vectors << {Bytes.new(256) { |index| index.to_u8 }, {0xe0ab0fd591637102_u64, 0x7d9013fd070bd2d3_u64}}

    vectors.each do |bytes, expected|
      CrystalClick::ClickHouseSipHash.hash128(bytes).should eq(expected)
    end
  end

  it "keeps the 64-bit and 128-bit finalizers idempotent in either order" do
    bytes = Bytes.new(37) { |index| ((index * 29) & 0xff).to_u8 }

    hash128_first = CrystalClick::ClickHouseSipHash.new
    hash128_first.update(bytes)
    pair = hash128_first.finish128
    hash128_first.finish128.should eq(pair)
    hash128_first.finish64.should eq(pair[0] ^ pair[1])
    hash128_first.finish64.should eq(pair[0] ^ pair[1])

    hash64_first = CrystalClick::ClickHouseSipHash.new
    hash64_first.update(bytes)
    hash64 = hash64_first.finish64
    hash64_first.finish64.should eq(hash64)
    pair_after = hash64_first.finish128
    pair_after.should eq(CrystalClick::ClickHouseSipHash.hash128(bytes))
    hash64.should eq(pair_after[0] ^ pair_after[1])
    hash64_first.finish128.should eq(pair_after)
  end

  it "preserves 128-bit output across incremental word and tail splits" do
    bytes = Bytes.new(256) { |index| index.to_u8 }
    expected = CrystalClick::ClickHouseSipHash.hash128(bytes)
    hasher = CrystalClick::ClickHouseSipHash.new

    hasher.update(Bytes.new(0))
    offset = 0
    [1, 7, 8, 9, 31, 64, 127, 9].each do |size|
      hasher.update(bytes[offset, size])
      offset += size
      hasher.update(Bytes.new(0))
    end
    offset.should eq(bytes.size)
    hasher.finish128.should eq(expected)
  end

  it "rejects updates after either finalizer while allowing the other cached result" do
    after64 = CrystalClick::ClickHouseSipHash.new
    after64.update("first".to_slice)
    hash64 = after64.finish64
    pair = after64.finish128
    hash64.should eq(pair[0] ^ pair[1])
    expect_raises(ArgumentError) { after64.update("late".to_slice) }

    after128 = CrystalClick::ClickHouseSipHash.new
    after128.update("second".to_slice)
    pair = after128.finish128
    hash64 = after128.finish64
    hash64.should eq(pair[0] ^ pair[1])
    expect_raises(ArgumentError) { after128.update("late".to_slice) }
  end
end
