require "./spec_helper"

describe CrystalClick::ClickHouseSipHash do
  it "matches pinned ClickHouse zero-key sipHash64 vectors across tail boundaries" do
    expected = {
        0 => 2_202_906_307_356_721_367_u64,
        1 => 10_863_254_463_029_944_905_u64,
        2 => 566_436_307_820_060_636_u64,
        7 => 2_909_365_655_995_158_743_u64,
        8 => 13652807937714663539_u64,
        9 => 11793426910964076454_u64,
        255 => 14894995872665425153_u64,
        256 => 12_018_341_290_192_864_882_u64,
        257 => 18_069_836_101_139_270_801_u64,
    }

    expected.each do |length, hash|
      bytes = Bytes.new(length, 'a'.ord.to_u8)
      CrystalClick::ClickHouseSipHash.hash64(bytes).should eq(hash)
    end
  end

  it "matches native vectors for nonuniform bytes across word and block boundaries" do
    expected = {
        1 => 10_041_351_145_189_524_877_u64,
        2 => 7_116_620_274_505_051_173_u64,
        7 => 12_958_684_268_628_887_563_u64,
        8 => 14_351_595_582_721_587_512_u64,
        9 => 6_993_662_196_368_935_714_u64,
        16 => 14_484_248_404_429_867_391_u64,
        128 => 13_494_878_767_035_684_471_u64,
        255 => 9_888_990_691_444_837_432_u64,
        256 => 11_329_680_248_228_324_305_u64,
    }

    expected.each do |length, hash|
      bytes = Bytes.new(length) { |index| index.to_u8 }
      CrystalClick::ClickHouseSipHash.hash64(bytes).should eq(hash)
    end
  end

  it "is invariant to incremental update boundaries, including empty updates" do
    bytes = Bytes.new(257, 'a'.ord.to_u8)
    hasher = CrystalClick::ClickHouseSipHash.new

    hasher.update(Bytes.new(0))
    offset = 0
    [1, 6, 1, 8, 17, 63, 128, 33].each do |size|
      chunk_size = {size, bytes.size - offset}.min
      break if chunk_size <= 0
      hasher.update(bytes[offset, chunk_size])
      offset += chunk_size
      hasher.update(Bytes.new(0))
    end
    hasher.update(bytes[offset, bytes.size - offset]) if offset < bytes.size

    hasher.finish64.should eq(18_069_836_101_139_270_801_u64)
  end

  it "preserves nonuniform byte order across incremental word and block boundaries" do
    bytes = Bytes.new(256) { |index| index.to_u8 }
    hasher = CrystalClick::ClickHouseSipHash.new

    offset = 0
    [1, 7, 8, 9, 31, 64, 127, 9].each do |size|
      hasher.update(Bytes.new(0))
      hasher.update(bytes[offset, size])
      offset += size
    end
    offset.should eq(bytes.size)

    hasher.finish64.should eq(11_329_680_248_228_324_305_u64)
  end

  it "keeps finish deterministic and rejects updates after finalization" do
    hasher = CrystalClick::ClickHouseSipHash.new
    hasher.update("a".to_slice)

    first = hasher.finish64
    hasher.finish64.should eq(first)
    expect_raises(ArgumentError) { hasher.update("b".to_slice) }
  end
end
