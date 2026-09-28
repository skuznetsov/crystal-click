require "./w69_helpers"

describe CrystalClick::OfflineCatalog do
  it "returns independent ordered W69 Map rows while preserving NULL and zero" do
    with_w69_part do |part|
      root = File.join(File.dirname(part), "catalog")
      catalog = w69_catalog_table(root, part)
      first = catalog["payload"].values.map do |value|
        value.as(Array(Tuple(UInt64, Array(UInt64?))))
      end
      first.should eq(W69_VALUES)

      first[1][0][1][0] = 99_u64
      first[1] << {8_u64, [8_u64] of UInt64?}
      catalog["payload"].values.map do |value|
        value.as(Array(Tuple(UInt64, Array(UInt64?))))
      end.should eq(W69_VALUES)

      expect_raises(CrystalClick::BoundsError) do
        catalog["payload"].values(max_rows: 6_u64)
      end
    end
  end
end
