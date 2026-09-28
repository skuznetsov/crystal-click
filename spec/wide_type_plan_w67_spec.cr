require "./spec_helper"

private def w67_shadow_fingerprint(
  plan : CrystalClick::WideTypePlan::WidePhysicalPlanShadow,
) : Array(String)
  plan.streams.map do |stream|
    relation = if parent = stream.cardinality_parent_axis
                 "#{parent.id}->#{stream.cardinality_child_axis.not_nil!.id}"
               else
                 "-"
               end
    path = stream.semantic_path.empty? ? "root" : stream.semantic_path.join(".")
    "#{stream.name}|#{stream.element_width}|#{stream.semantic_type}|#{path}|#{stream.role}|#{stream.storage_mode}|#{stream.storage_axis.id}|#{relation}|mark=#{stream.mark_row_axis.id}"
  end
end

describe CrystalClick::WideTypePlan::WidePhysicalPlanShadow do
  it "preserves ordered stream identity, width, storage axis, and cardinality for sealed controls" do
    cases = {
      {
        "Array(Tuple(a UInt64, b String))",
        [
          "payload.size0|8|Array(Tuple(a UInt64, b String))|root|ArraySize0|Counts|table_rows|table_rows->payload:root:array0_elements|mark=table_rows",
          "payload%2Ea|8|UInt64|a|Value|FixedWidthValues|payload:root:array0_elements|-|mark=table_rows",
          "payload%2Eb.size|8|String|b|StringSize|Counts|payload:root:array0_elements|payload:root:array0_elements->payload:b:string_bytes|mark=table_rows",
          "payload%2Eb|1|String|b|Value|VariableBytes|payload:b:string_bytes|-|mark=table_rows",
        ],
      },
      {
        "Array(Tuple(a Nullable(UInt64), b String))",
        [
          "payload.size0|8|Array(Tuple(a Nullable(UInt64), b String))|root|ArraySize0|Counts|table_rows|table_rows->payload:root:array0_elements|mark=table_rows",
          "payload%2Ea.null|1|Nullable(UInt64)|a|NullMap|NullMapBytes|payload:root:array0_elements|-|mark=table_rows",
          "payload%2Ea|8|Nullable(UInt64)|a|Value|FixedWidthValues|payload:root:array0_elements|-|mark=table_rows",
          "payload%2Eb.size|8|String|b|StringSize|Counts|payload:root:array0_elements|payload:root:array0_elements->payload:b:string_bytes|mark=table_rows",
          "payload%2Eb|1|String|b|Value|VariableBytes|payload:b:string_bytes|-|mark=table_rows",
        ],
      },
      {
        "Array(Tuple(a UInt64, b UInt64))",
        [
          "payload.size0|8|Array(Tuple(a UInt64, b UInt64))|root|ArraySize0|Counts|table_rows|table_rows->payload:root:array0_elements|mark=table_rows",
          "payload%2Ea|8|UInt64|a|Value|FixedWidthValues|payload:root:array0_elements|-|mark=table_rows",
          "payload%2Eb|8|UInt64|b|Value|FixedWidthValues|payload:root:array0_elements|-|mark=table_rows",
        ],
      },
      {
        "Array(Array(String))",
        [
          "payload.size0|8|Array(Array(String))|root|ArraySize0|Counts|table_rows|table_rows->payload:root:array0_elements|mark=table_rows",
          "payload.size1|8|Array(String)|root|ArraySize1|Counts|payload:root:array0_elements|payload:root:array0_elements->payload:root:array1_elements|mark=table_rows",
          "payload.size|8|String|root|StringSize|Counts|payload:root:array1_elements|payload:root:array1_elements->payload:root:string_bytes|mark=table_rows",
          "payload|1|String|root|Value|VariableBytes|payload:root:string_bytes|-|mark=table_rows",
        ],
      },
      {
        "Array(Array(Nullable(String)))",
        [
          "payload.size0|8|Array(Array(Nullable(String)))|root|ArraySize0|Counts|table_rows|table_rows->payload:root:array0_elements|mark=table_rows",
          "payload.size1|8|Array(Nullable(String))|root|ArraySize1|Counts|payload:root:array0_elements|payload:root:array0_elements->payload:root:array1_elements|mark=table_rows",
          "payload.null|1|Nullable(String)|root|NullMap|NullMapBytes|payload:root:array1_elements|-|mark=table_rows",
          "payload.size|8|Nullable(String)|root|StringSize|Counts|payload:root:array1_elements|payload:root:array1_elements->payload:root:string_bytes|mark=table_rows",
          "payload|1|Nullable(String)|root|Value|VariableBytes|payload:root:string_bytes|-|mark=table_rows",
        ],
      },
      {
        "Map(String, Array(UInt64))",
        [
          "payload.size0|8|Map(String, Array(UInt64))|root|MapSize0|Counts|table_rows|table_rows->payload:root:map_entries|mark=table_rows",
          "payload%2Ekeys.size|8|String|keys|StringSize|Counts|payload:root:map_entries|payload:root:map_entries->payload:keys:string_bytes|mark=table_rows",
          "payload%2Ekeys|1|String|keys|Value|VariableBytes|payload:keys:string_bytes|-|mark=table_rows",
          "payload%2Evalues.size1|8|Array(UInt64)|values|ArraySize1|Counts|payload:root:map_entries|payload:root:map_entries->payload:values:array1_elements|mark=table_rows",
          "payload%2Evalues|8|UInt64|values|Value|FixedWidthValues|payload:values:array1_elements|-|mark=table_rows",
        ],
      },
      {
        "Map(String, Array(Nullable(UInt64)))",
        [
          "payload.size0|8|Map(String, Array(Nullable(UInt64)))|root|MapSize0|Counts|table_rows|table_rows->payload:root:map_entries|mark=table_rows",
          "payload%2Ekeys.size|8|String|keys|StringSize|Counts|payload:root:map_entries|payload:root:map_entries->payload:keys:string_bytes|mark=table_rows",
          "payload%2Ekeys|1|String|keys|Value|VariableBytes|payload:keys:string_bytes|-|mark=table_rows",
          "payload%2Evalues.size1|8|Array(Nullable(UInt64))|values|ArraySize1|Counts|payload:root:map_entries|payload:root:map_entries->payload:values:array1_elements|mark=table_rows",
          "payload%2Evalues.null|1|Nullable(UInt64)|values|NullMap|NullMapBytes|payload:values:array1_elements|-|mark=table_rows",
          "payload%2Evalues|8|Nullable(UInt64)|values|Value|FixedWidthValues|payload:values:array1_elements|-|mark=table_rows",
        ],
      },
    }

    cases.each do |type, expected|
      plan = CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(type).not_nil!
      w67_shadow_fingerprint(plan).should eq(expected)
      plan.mark_row_axis.id.should eq("table_rows")
      plan.streams.each { |stream| stream.mark_row_axis.id.should eq("table_rows") }
    end
  end

  it "keeps the candidate shadow-only and rejects malformed or unbounded Map shapes" do
    candidate = "Map(String, Array(Nullable(UInt64)))"
    CrystalClick::WideTypePlan.parse(candidate).should_not be_nil
    CrystalClick::WideTypePlan.admitted(candidate).should be_nil
    CrystalClick::WidePart.supports_typed_type?(candidate).should be_false
    CrystalClick::WidePart.supports_typed_type?("Map(String, Array(UInt64))").should be_true

    plan = CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(candidate).not_nil!
    map_size, key_size, _key_data, values_size, nulls, values = plan.streams
    entries_axis = map_size.cardinality_child_axis.not_nil!.id
    key_size.storage_axis.id.should eq(entries_axis)
    key_size.cardinality_parent_axis.not_nil!.id.should eq(entries_axis)
    values_size.storage_axis.id.should eq(entries_axis)
    nulls.storage_axis.id.should eq(values_size.cardinality_child_axis.not_nil!.id)
    values.storage_axis.id.should eq(nulls.storage_axis.id)
    values.element_width.should eq(8)

    # The pinned stock probe has table-row counts [2, 2, 1, 0], Map-entry
    # counts [2, 3, 1], and value-element counts [2, 2, 1]. Those counts are
    # producer-data evidence; this type-only descriptor checks that they cannot
    # be mistaken for the same axis. Every stream still carries table rows in
    # its mark-row coordinate.
    plan.mark_row_axis.kind.should eq(CrystalClick::WideTypePlan::WidePhysicalPlanShadow::AxisKind::TableRows)
    plan.axes.map(&.kind).should contain(CrystalClick::WideTypePlan::WidePhysicalPlanShadow::AxisKind::MapEntries)
    plan.axes.map(&.kind).should contain(CrystalClick::WideTypePlan::WidePhysicalPlanShadow::AxisKind::ArrayElements)

    {
      "Map(String)",
      "Map(String, Array(Nullable(UInt64)), UInt64)",
      "Map(String, Array(Nullable(UInt64))) trailing",
      "Map(String, Array(Array(Nullable(UInt64))))",
      "Map(UInt64, Array(Nullable(UInt64)))",
    }.each do |unbounded|
      CrystalClick::WideTypePlan::WidePhysicalPlanShadow.for_type(unbounded).should be_nil
    end
  end
end
