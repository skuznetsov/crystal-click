require "./spec_helper"
require "file_utils"
require "./support/compact_part_writer_w280_fixture"

private def w280_assert_planned_order(
  case_name : Symbol,
  column : CrystalClick::CompactPartColumn,
) : Nil
  fixture = CompactPartWriterW280Fixture
  input = column.json_input
  plan = CrystalClick::CompactJsonCallbackPlan.new(
    input,
    CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS,
    CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
  )

  plan.json_sites.map(&.key).should eq(fixture.json_site_keys(case_name))
  plan.array_sites.map(&.key).should eq(fixture.array_site_keys(case_name))
  plan.uint8_sites.map(&.key).should eq(fixture.uint8_site_keys(case_name))
  plan.schema_plan.bulk_sites.map(&.key).should eq(fixture.bulk_site_keys(case_name))

  expected = [] of String
  fixture.json_site_keys(case_name).each do |site_key|
    plan.site_binding(site_key).prefix_pairs.each { |pair| expected << pair[1] }
  end
  fixture.body_dfs(case_name).each do |kind, site_key|
    case kind
    when :json
      plan.site_binding(site_key).body_pairs.each { |pair| expected << pair[1] }
    when :array
      expected << plan.schema_plan.array_site(site_key).callback_name
    when :uint8
      expected << plan.schema_plan.uint8_site(site_key).callback_name
    when :bulk_size
      expected << plan.schema_plan.bulk_site(site_key).physical_plan.stream_name_for("root.sizes")
    when :bulk_data
      expected << plan.schema_plan.bulk_site(site_key).physical_plan.stream_name_for("root.elements.data")
    else
      raise ArgumentError.new("unknown W280 body-order token")
    end
  end
  plan.callback_names.should eq(expected)
  nil
end

private def w280_write_case(case_name : Symbol, mark_format : CrystalClick::CompactMarkFormat) : String
  fixture = CompactPartWriterW280Fixture
  parent = File.tempname("crystal-click-w280-#{case_name}-")
  part_path = File.join(parent, "all_1_1_0")
  Dir.mkdir(parent)
  begin
    column = fixture.column(case_name)
    w280_assert_planned_order(case_name, column)
    CrystalClick::CompactPartWriter.write_uint64_columns(
      part_path,
      CompactPartWriterW280Fixture::KEY_NAME,
      fixture.keys,
      [column] of CrystalClick::CompactPartColumn,
      rows_per_mark: CompactPartWriterW280Fixture::ROWS_PER_MARK,
      frame_bytes: CompactPartWriterW280Fixture::FRAME_BYTES,
      mark_format: mark_format,
    ).should eq(part_path)
    part_path
  rescue ex
    FileUtils.rm_rf(parent)
    raise ex
  end
end

private def w280_assert_windows(
  part_path : String,
  case_name : Symbol,
) : Nil
  fixture = CompactPartWriterW280Fixture
  reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
    part_path,
    CompactPartWriterW280Fixture::COLUMN_NAME,
    fixture.schema(case_name),
  )
  expected = fixture.expected_signatures(case_name)
  reader.mark_count.should eq(CompactPartWriterW280Fixture::MARK_COUNT)
  reader.row_count.should eq(CompactPartWriterW280Fixture::ROW_COUNT.to_u64)

  reader.read_marks(0, reader.mark_count).flatten.map { |value| fixture.signature(value) }.should eq(expected)
  reader.read_marks(1, 2).flatten.map { |value| fixture.signature(value) }.should eq(expected[2, 4])
  reader.read_marks(3, 1).flatten.map { |value| fixture.signature(value) }.should eq(expected[6, 2])
  reader.read_marks(reader.mark_count, 0).should be_empty
  nil
end

private def w280_write_and_read_case(case_name : Symbol) : Nil
  [
    CrystalClick::CompactMarkFormat::Mrk3,
    CrystalClick::CompactMarkFormat::Mrk4,
  ].each do |mark_format|
    part_path = w280_write_case(case_name, mark_format)
    begin
      w280_assert_windows(part_path, case_name)
    ensure
      FileUtils.rm_rf(File.dirname(part_path))
    end
  end
  nil
end

private def w280_assert_positional_array_uint8_bulk_ownership : Nil
  fixture = CompactPartWriterW280Fixture
  array_schema = fixture.schema(:positional_uint8).child_at(2)
  array_schema.bulk?.should be_true
  array_schema.bulk_type.should eq(fixture.array_uint8_type)

  rows = fixture.rows(:positional_uint8)
  rows.each do |row|
    carrier = row.child_at(2)
    carrier.bulk?.should be_true
    carrier.bulk_value.type.should eq(fixture.array_uint8_type)
    carrier.bulk_value.elements.each do |element|
      element.type.should eq(fixture.uint8_type)
    end
  end
  nil
end

describe "W280 generic recursive Compact JSON writer entry" do
  it "keeps the previously admitted Array(JSON) writer control round-trippable" do
    w280_write_and_read_case(:array_json)
  end

  it "round-trips distinct sibling Array(JSON) branches and their inherited row domains" do
    w280_write_and_read_case(:sibling_arrays)
  end

  it "round-trips four sibling Object sites in literal Tuple DFS order" do
    w280_write_and_read_case(:four_sibling_objects)
  end

  it "round-trips more than four nested Array/Tuple sites with repeated JSON and UInt8 leaves" do
    w280_write_and_read_case(:nested_five_sites)
  end

  it "round-trips unnamed Tuple UInt8 leaves before, between, and after JSON sites" do
    w280_assert_positional_array_uint8_bulk_ownership
    w280_write_and_read_case(:positional_uint8)
  end
end
