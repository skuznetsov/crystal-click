require "./wide_part_reader_w73_helpers"

describe CrystalClick::OfflineCatalog do
  it "materializes independently owned ordered rows for all three W73 Map Array cells" do
    with_w73_reader_u64_u64_part do |part|
      table = w73_reader_catalog_table(
        File.join(File.dirname(part), "catalog_u64_u64"),
        part,
        "Map(UInt64, Array(UInt64))"
      )
      values = table["payload"].values.map do |value|
        value.as(Array(Tuple(UInt64, Array(UInt64))))
      end
      values.should eq(W73_READER_U64_U64_VALUES)
      values[1][1][1][0] = 99_u64
      table["payload"].values.map do |value|
        value.as(Array(Tuple(UInt64, Array(UInt64))))
      end.should eq(W73_READER_U64_U64_VALUES)
      expect_raises(CrystalClick::BoundsError) do
        table["payload"].values(max_rows: 4_u64)
      end
    end

    with_w73_reader_string_string_part do |part|
      table = w73_reader_catalog_table(
        File.join(File.dirname(part), "catalog_string_string"),
        part,
        "Map(String, Array(String))"
      )
      values = table["payload"].values.map do |value|
        value.as(Array(Tuple(String, Array(String))))
      end
      values.should eq(W73_READER_STRING_STRING_VALUES)
      values[1][1][1][1] = "mutated"
      table["payload"].values.map do |value|
        value.as(Array(Tuple(String, Array(String))))
      end.should eq(W73_READER_STRING_STRING_VALUES)
      expect_raises(CrystalClick::BoundsError) do
        table["payload"].values(max_string_bytes: 1_u64)
      end
      expect_raises(CrystalClick::BoundsError) do
        table["payload"].values(max_rows: 4_u64)
      end
    end

    with_w73_reader_u64_string_part do |part|
      table = w73_reader_catalog_table(
        File.join(File.dirname(part), "catalog_u64_string"),
        part,
        "Map(UInt64, Array(String))"
      )
      values = table["payload"].values.map do |value|
        value.as(Array(Tuple(UInt64, Array(String))))
      end
      values.should eq(W73_READER_U64_STRING_VALUES)
      values[1][1][1][1] = "mutated"
      table["payload"].values.map do |value|
        value.as(Array(Tuple(UInt64, Array(String))))
      end.should eq(W73_READER_U64_STRING_VALUES)
      expect_raises(CrystalClick::BoundsError) do
        table["payload"].values(max_string_bytes: 1_u64)
      end
      expect_raises(CrystalClick::BoundsError) do
        table["payload"].values(max_rows: 4_u64)
      end
    end
  end
end
