require "./spec_helper"

describe CrystalClick::WideTypePlan::WidePhysicalPlanShadow do
  it "describes the three exact W73 Map Array stream inventories and independent axes" do
    {
      {
        "Map(UInt64, Array(UInt64))",
        [
          "payload.size0",
          "payload%2Ekeys",
          "payload%2Evalues.size1",
          "payload%2Evalues",
        ],
        [8, 8, 8, 8],
      },
      {
        "Map(String, Array(String))",
        [
          "payload.size0",
          "payload%2Ekeys.size",
          "payload%2Ekeys",
          "payload%2Evalues.size1",
          "payload%2Evalues.size",
          "payload%2Evalues",
        ],
        [8, 8, 1, 8, 8, 1],
      },
      {
        "Map(UInt64, Array(String))",
        [
          "payload.size0",
          "payload%2Ekeys",
          "payload%2Evalues.size1",
          "payload%2Evalues.size",
          "payload%2Evalues",
        ],
        [8, 8, 8, 8, 1],
      },
    }.each do |type, expected_names, expected_widths|
      plan = CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(type).not_nil!
      plan.column_type.should eq(type)
      plan.streams.map(&.name).should eq(expected_names)
      plan.streams.map(&.element_width).should eq(expected_widths)
      plan.streams.each { |stream| stream.mark_row_axis.id.should eq("table_rows") }

      map_sizes = plan.streams.first
      map_entries_axis = map_sizes.cardinality_child_axis.not_nil!
      map_sizes.cardinality_parent_axis.not_nil!.id.should eq("table_rows")
      key_sizes = plan.streams.find(&.name.ends_with?("%2Ekeys.size"))
      if key_sizes
        key_sizes.storage_axis.id.should eq(map_entries_axis.id)
        key_bytes_axis = key_sizes.cardinality_child_axis.not_nil!
        key_sizes.cardinality_parent_axis.not_nil!.id.should eq(map_entries_axis.id)
        plan.streams.find { |stream| stream.name.ends_with?("%2Ekeys") }.not_nil!.storage_axis.id.should eq(key_bytes_axis.id)
      else
        plan.streams.find { |stream| stream.name.ends_with?("%2Ekeys") }.not_nil!.storage_axis.id.should eq(map_entries_axis.id)
      end
      nested_sizes = plan.streams.find(&.name.ends_with?("%2Evalues.size1")).not_nil!
      nested_elements_axis = nested_sizes.cardinality_child_axis.not_nil!
      nested_sizes.cardinality_parent_axis.not_nil!.id.should eq(map_entries_axis.id)
      nested_sizes.storage_axis.id.should eq(map_entries_axis.id)

      if type.includes?("String)")
        value_sizes = plan.streams.find { |stream| stream.name == "payload%2Evalues.size" }.not_nil!
        value_bytes_axis = value_sizes.cardinality_child_axis.not_nil!
        value_sizes.cardinality_parent_axis.not_nil!.id.should eq(nested_elements_axis.id)
        plan.streams.find { |stream| stream.name == "payload%2Evalues" }.not_nil!.storage_axis.id.should eq(value_bytes_axis.id)
      end
    end
  end

  it "keeps nearby W73 spellings out of the shadow plan" do
    {
      "Map(Int64, Array(UInt64))",
      "Map(UInt64, Array(Int64))",
      "Map(UInt64, Array(Nullable(Int64)))",
      "Map(UInt64, Array(Array(String)))",
      "Map(UInt64, Nullable(Array(String)))",
      "Map(UInt64, Array(String)) trailing",
    }.each do |type|
      CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(type).should be_nil
    end
  end
end
