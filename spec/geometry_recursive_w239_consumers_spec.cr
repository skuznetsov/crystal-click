require "./spec_helper"
require "./support/geometry_recursive_w239_fixture"

private def w239c_offline_table(
  part : String,
  type : String,
  row_count : UInt64,
) : CrystalClick::OfflineTable
  info = CrystalClick::MergeTreePartInfo.parse("all_1_1_0").not_nil!
  candidate = CrystalClick::OfflinePartCandidate.new("all_1_1_0", part, info, row_count)
  CrystalClick::OfflineTable.new(
    "w239_events",
    "w239-geometry-fixture",
    "MergeTree",
    [
      CrystalClick::OfflineColumn.new("pk", "UInt64"),
      CrystalClick::OfflineColumn.new("v", type),
    ] of CrystalClick::OfflineColumn,
    [candidate] of CrystalClick::OfflinePartCandidate,
    "pk",
  )
end

describe "W239 Geometry recursive public consumers" do
  it "routes lawful wrapper products through typed scans, selected windows, and offline values" do
    fixture = W239GeometryFixture.new
    begin
      part = fixture.write_composed
      fixture.composed_type.name.should contain("Geometry")
      CrystalClick::WidePart.supports_typed_type?(fixture.composed_type.name).should be_true
      CrystalClick::WidePart.supports_custom_geo_bulk_type?(fixture.composed_type.name).should be_true

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "v"])
      table.column_types.should eq([{"pk", "UInt64"}, {"v", fixture.composed_type.name}])
      observed = [] of CrystalClick::BinaryValue
      schedule = [] of Tuple(Int32, Int64, Int32)
      table.scan_typed(batch_rows: 3) do |batch|
        values = batch.binary_bulk_values_for("v")
        values.size.should eq(batch.values_for("pk").size)
        observed.concat(values.to_a)
        schedule << {batch.mark_index, batch.part_row_offset.to_i64, values.size}
      end
      expected = fixture.composed_marks.flatten
      observed.size.should eq(expected.size)
      observed.each_with_index { |value, index| w239g_assert_value(value, expected[index]) }
      schedule.should eq([
        {0, 0_i64, 3},
        {0, 3_i64, 1},
        {1, 4_i64, 3},
        {1, 7_i64, 1},
        {2, 8_i64, 3},
      ])

      window = [] of CrystalClick::BinaryValue
      table.scan_typed_window(3_u64, 5) do |batch|
        window.concat(batch.binary_bulk_values_for("v").to_a)
      end
      window.size.should eq(5)
      window.each_with_index { |value, index| w239g_assert_value(value, expected[index + 3]) }
      eof_callbacks = 0
      table.scan_typed_window(11_u64, 1) { |_batch| eof_callbacks += 1 }
      eof_callbacks.should eq(0)

      offline = w239c_offline_table(part, fixture.composed_type.name, 11_u64)
      offline_values = offline["v"].values(max_rows: 11_u64).map do |value|
        value.as(CrystalClick::BinaryValue)
      end
      offline_values.size.should eq(expected.size)
      offline_values.each_with_index { |value, index| w239g_assert_value(value, expected[index]) }
    ensure
      fixture.close
    end
  end

  it "preserves bare Geometry legacy GeometryRow and OfflineColumn value contracts" do
    fixture = W239GeometryFixture.new
    begin
      part = fixture.write_bare
      CrystalClick::WidePart.supports_typed_type?("Geometry").should be_true
      CrystalClick::WidePart.supports_custom_geo_bulk_type?("Geometry").should be_false

      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "v"])
      rows = [] of CrystalClick::WideGeometryRow
      table.scan_typed(batch_rows: 3) do |batch|
        batch.column_type_for("v").should eq("Geometry")
        error = expect_raises(CrystalClick::UnsupportedFormatError) do
          batch.binary_bulk_values_for("v")
        end
        error.message.should eq("Binary bulk accessor requires an admitted static or Dynamic declaration")
        rows.concat(batch.geometry_rows_for("v").to_a)
      end
      expected = fixture.geometry_marks.flatten
      rows.size.should eq(expected.size)
      rows.each_with_index { |row, index| w239g_assert_legacy_row(row, expected[index]) }

      offline = w239c_offline_table(part, "Geometry", 11_u64)
      legacy_values = offline["v"].values(max_rows: 11_u64).map do |value|
        value.as(CrystalClick::WideGeometryRow)
      end
      legacy_values.size.should eq(expected.size)
      legacy_values.each_with_index { |row, index| w239g_assert_legacy_row(row, expected[index]) }
    ensure
      fixture.close
    end
  end
end
