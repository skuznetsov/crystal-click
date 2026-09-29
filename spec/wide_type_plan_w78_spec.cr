require "./spec_helper"

W78_NUMERIC_LEAVES = [
  {"UInt8", 1},
  {"UInt16", 2},
  {"UInt32", 4},
  {"UInt64", 8},
  {"Int8", 1},
  {"Int16", 2},
  {"Int32", 4},
  {"Int64", 8},
  {"Float32", 4},
  {"Float64", 8},
]

W78_KEY_SHAPES = [
  {"UInt64", false},
  {"String", true},
]

describe CrystalClick::WideTypePlan::WidePhysicalPlanShadow do
  it "shadows the exact W78 Map Array streams, widths, and independent axes" do
    issues = [] of String

    W78_NUMERIC_LEAVES.each do |leaf_type, leaf_width|
      W78_KEY_SHAPES.each do |key_type, string_key|
        type = "Map(#{key_type}, Array(#{leaf_type}))"
        plan = CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(type)
        unless plan
          issues << "#{type}: missing physical shadow"
          next
        end

        expected_names = if string_key
                           [
                             "payload.size0",
                             "payload%2Ekeys.size",
                             "payload%2Ekeys",
                             "payload%2Evalues.size1",
                             "payload%2Evalues",
                           ]
                         else
                           [
                             "payload.size0",
                             "payload%2Ekeys",
                             "payload%2Evalues.size1",
                             "payload%2Evalues",
                           ]
                         end
        expected_widths = if string_key
                            [8, 8, 1, 8, leaf_width]
                          else
                            [8, 8, 8, leaf_width]
                          end
        expected_axes = if string_key
                          [
                            {"table_rows", "TableRows"},
                            {"payload:root:map_entries", "MapEntries"},
                            {"payload:keys:string_bytes", "StringBytes"},
                            {"payload:values:array1_elements", "ArrayElements"},
                          ]
                        else
                          [
                            {"table_rows", "TableRows"},
                            {"payload:root:map_entries", "MapEntries"},
                            {"payload:values:array1_elements", "ArrayElements"},
                          ]
                        end

        streams = plan.streams
        names = streams.map(&.name)
        issues << "#{type}: streams #{names.inspect}, expected #{expected_names.inspect}" unless names == expected_names
        widths = streams.map(&.element_width)
        issues << "#{type}: widths #{widths.inspect}, expected #{expected_widths.inspect}" unless widths == expected_widths
        axes = plan.axes.map { |axis| {axis.id, axis.kind.to_s} }
        issues << "#{type}: axes #{axes.inspect}, expected #{expected_axes.inspect}" unless axes == expected_axes

        streams.each do |stream|
          issues << "#{type}: #{stream.name} mark-row axis is #{stream.mark_row_axis.id}" unless stream.mark_row_axis.id == "table_rows"
        end

        map_sizes = streams.find(&.name.==("payload.size0"))
        if map_sizes
          issues << "#{type}: Map size is not stored on table_rows" unless map_sizes.storage_axis.id == "table_rows"
          issues << "#{type}: Map-size parent axis is not table_rows" unless map_sizes.cardinality_parent_axis.try(&.id) == "table_rows"
          issues << "#{type}: Map-size child axis is not map_entries" unless map_sizes.cardinality_child_axis.try(&.id) == "payload:root:map_entries"
        end

        key_stream = streams.find(&.name.==("payload%2Ekeys"))
        key_size = streams.find(&.name.==("payload%2Ekeys.size"))
        if string_key
          if key_size
            issues << "#{type}: String key sizes are not stored on map_entries" unless key_size.storage_axis.id == "payload:root:map_entries"
            issues << "#{type}: String-key size parent axis is not map_entries" unless key_size.cardinality_parent_axis.try(&.id) == "payload:root:map_entries"
            issues << "#{type}: String-key size child axis is not string_bytes" unless key_size.cardinality_child_axis.try(&.id) == "payload:keys:string_bytes"
          else
            issues << "#{type}: missing String key-size stream"
          end
          issues << "#{type}: String key bytes are not stored on string_bytes" unless key_stream.try(&.storage_axis.id) == "payload:keys:string_bytes"
        else
          issues << "#{type}: numeric keys are not stored on map_entries" unless key_stream.try(&.storage_axis.id) == "payload:root:map_entries"
        end

        value_sizes = streams.find(&.name.==("payload%2Evalues.size1"))
        value_stream = streams.find(&.name.==("payload%2Evalues"))
        if value_sizes
          issues << "#{type}: Array sizes are not stored on map_entries" unless value_sizes.storage_axis.id == "payload:root:map_entries"
          issues << "#{type}: Array-size parent axis is not map_entries" unless value_sizes.cardinality_parent_axis.try(&.id) == "payload:root:map_entries"
          issues << "#{type}: Array-size child axis is not array elements" unless value_sizes.cardinality_child_axis.try(&.id) == "payload:values:array1_elements"
        else
          issues << "#{type}: missing Array size1 stream"
        end
        issues << "#{type}: numeric leaves are not stored on array elements" unless value_stream.try(&.storage_axis.id) == "payload:values:array1_elements"
        issues << "#{type}: numeric leaf semantic type is not #{leaf_type}" unless value_stream.try(&.semantic_type) == leaf_type
      end
    end

    issues.should be_empty
  end

  it "admits exactly the ten numeric leaves for both W78 Map key shapes" do
    issues = [] of String

    W78_NUMERIC_LEAVES.each do |leaf_type, _leaf_width|
      W78_KEY_SHAPES.each do |key_type, _string_key|
        type = "Map(#{key_type}, Array(#{leaf_type}))"
        unless CrystalClick::WidePart.supports_typed_type?(type)
          issues << "#{type}: exact typed admission is missing"
        end
      end
    end

    issues.should be_empty
  end

  it "keeps nearby non-W78 declarations out of the exact shadow and admission" do
    w79_type = "Map(UInt64, Array(Nullable(Int8)))"
    CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(w79_type).should_not be_nil
    CrystalClick::WidePart.supports_typed_type?(w79_type).should be_true

    {
      "Map(Int64, Array(UInt64))",
      "Map(UInt32, Array(Int8))",
      "Map(UInt64, Array(Array(Int8)))",
      "Map(UInt64, Nullable(Array(Int8)))",
      "Map(UInt64, Array(BFloat16))",
      "Map(UInt64, Array(Int128))",
      "Map(UInt64, Array(Int8)) trailing",
      "Map(UInt64, Array(Nullable(Int128)))",
    }.each do |type|
      CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(type).should be_nil
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end
  end
end
