require "./w71_helpers"

describe CrystalClick::OfflineCatalog do
  it "returns independently owned ordered W71 Map rows and enforces retained String limits" do
    with_w71_part do |part|
      catalog = w71_catalog_table(File.join(File.dirname(part), "catalog"), part)
      first = catalog["payload"].values.map do |value|
        value.as(Array(Tuple(UInt64, Array(String?))))
      end
      first.should eq(W71_VALUES)

      first[0][0][1][2] = "changed"
      catalog["payload"].values.map do |value|
        value.as(Array(Tuple(UInt64, Array(String?))))
      end.should eq(W71_VALUES)

      expect_raises(CrystalClick::BoundsError) do
        catalog["payload"].values(max_string_bytes: 1_u64)
      end
      expect_raises(CrystalClick::BoundsError) do
        catalog["payload"].values(max_rows: 6_u64)
      end
    end
  end
end
