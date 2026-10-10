require "./spec_helper"
require "file_utils"
require "../scripts/support/dynamic_recursive_handoff_w249_fixture"

private def w249_assert_values!(actual : Array(CrystalClick::BinaryValue), expected : Array(CrystalClick::BinaryValue)) : Nil
  actual.size.should eq(expected.size)
  actual.each_with_index do |value, index|
    value.type.should eq(expected[index].type)
    value.type.name.should eq(expected[index].type.name)
    DynamicRecursiveHandoffW249Fixture.row_signature(value).should eq(
      DynamicRecursiveHandoffW249Fixture.row_signature(expected[index])
    )
  end
end

private def w249_candidate(path : String) : CrystalClick::OfflinePartCandidate
  info = CrystalClick::MergeTreePartInfo.parse("all_1_1_0").not_nil!
  CrystalClick::OfflinePartCandidate.new("all_1_1_0", path, info, 5_u64)
end

private def w249_offline_table(path : String) : CrystalClick::OfflineTable
  columns = [CrystalClick::OfflineColumn.new("pk", "UInt64")] of CrystalClick::OfflineColumn
  DynamicRecursiveHandoffW249Fixture.column_types.each do |name, type|
    columns << CrystalClick::OfflineColumn.new(name, type.name)
  end
  CrystalClick::OfflineTable.new(
    "events", "w249-dynamic-recursive", "MergeTree", columns,
    [w249_candidate(path)] of CrystalClick::OfflinePartCandidate,
  )
end

describe "W249 recursive Dynamic declaration handoff" do
  # This positive control stays before the declared schema test. It separates
  # the existing recursive Dynamic codec from the missing declaration/public
  # handoff and proves the empty first mark does not require an occurrence.
  it "writes and reads direct nominal Nested Dynamic in both String profiles" do
    type = DynamicRecursiveHandoffW249Fixture.root_nested_type
    rows = DynamicRecursiveHandoffW249Fixture.rows_for(DynamicRecursiveHandoffW249Fixture::ROOT_NESTED)
    DynamicRecursiveHandoffW249Fixture.dynamic_sites[DynamicRecursiveHandoffW249Fixture::ROOT_NESTED].first[:path].should eq("root.elements.field.0")
    DynamicRecursiveHandoffW249Fixture.observed_types_by_site(DynamicRecursiveHandoffW249Fixture::ROOT_NESTED, rows).values.first.should eq(["Int64", "String"])

    ["single", "sized"].each do |profile_name|
      parent = File.tempname("crystal-click-w249-direct-")
      Dir.mkdir(parent)
      begin
        part = File.join(parent, "all_1_1_0")
        CrystalClick::WidePartWriter.write_uint64_dynamic_bulk_part(
          part,
          DynamicRecursiveHandoffW249Fixture::KEY_NAME,
          DynamicRecursiveHandoffW249Fixture::KEYS.to_unsafe.to_slice(DynamicRecursiveHandoffW249Fixture::KEYS.size),
          DynamicRecursiveHandoffW249Fixture::ROOT_NESTED,
          type,
          DynamicRecursiveHandoffW249Fixture.structures_for(DynamicRecursiveHandoffW249Fixture::ROOT_NESTED),
          DynamicRecursiveHandoffW249Fixture.marks(rows),
          DynamicRecursiveHandoffW249Fixture::ROWS_PER_MARK,
          DynamicRecursiveHandoffW249Fixture.profile(profile_name),
          DynamicRecursiveHandoffW249Fixture::FRAME_BYTES,
        ).should eq(part)

        reader = CrystalClick::DynamicBulkColumnReader.open(part, DynamicRecursiveHandoffW249Fixture::ROOT_NESTED, type)
        reader.schema_declaration.should eq(type.name)
        reader.source_declaration.should eq(type.name)
        reader.row_count.should eq(5_u64)
        reader.mark_row_counts.should eq(DynamicRecursiveHandoffW249Fixture::MARK_ROW_COUNTS)
        reader.ordinary_profile.should eq(DynamicRecursiveHandoffW249Fixture.profile(profile_name))
        values = reader.read_marks(0, reader.mark_count).flat_map { |mark| mark }
        w249_assert_values!(values, rows)
        reader.read_marks(3, 0).should eq([] of Array(CrystalClick::BinaryValue))
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end

  it "admits recursive nominal declarations without rewriting Nested or restricting Map keys" do
    types = DynamicRecursiveHandoffW249Fixture.column_types
    DynamicRecursiveHandoffW249Fixture::TARGET_COLUMNS.each do |name|
      parsed = CrystalClick::DynamicBulkColumnDeclaration.parse(types[name].name)
      parsed.should eq(types[name])
      parsed.not_nil!.tag.should eq(types[name].tag)
      parsed.not_nil!.name.should eq(types[name].name)
    end

    # These are core constructor guards, not parser-only spellings.
    dynamic = DynamicRecursiveHandoffW249Fixture.dynamic_type
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.nullable(dynamic) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.low_cardinality(dynamic) }
    expect_raises(ArgumentError) do
      CrystalClick::BinaryDataType.variant([dynamic, CrystalClick::BinaryDataType.primitive("String")] of CrystalClick::BinaryDataType)
    end
    CrystalClick::DynamicBulkColumnDeclaration.parse("Dynamic").should be_nil
    CrystalClick::DynamicBulkColumnDeclaration.parse("Dynamic(max_types=1)").should eq(dynamic)
    CrystalClick::ObjectRecursiveDeclaration.preflight_slice(
      "Map(UInt64, Nested(d Dynamic(max_types=1), label String))".to_slice,
      0,
      "Map(UInt64, Nested(d Dynamic(max_types=1), label String))".bytesize,
      CrystalClick::ObjectRecursiveDeclaration::DEFAULT_LIMITS,
      1,
    ).should be_nil
  end

  it "keeps DynamicBulk declaration admission opt-in while preserving the ObjectJson default" do
    source = "Nested(d Dynamic(max_types=1), label String)"
    bytes = source.to_slice
    limits = CrystalClick::ObjectRecursiveDeclaration::DEFAULT_LIMITS
    dynamic_bulk = CrystalClick::ObjectRecursiveDeclaration::AdmissionProfile::DynamicBulk
    object_json = CrystalClick::ObjectRecursiveDeclaration::AdmissionProfile::ObjectJson

    CrystalClick::ObjectRecursiveDeclaration.preflight_slice(bytes, 0, bytes.size).should be_nil
    CrystalClick::ObjectRecursiveDeclaration.preflight_slice(
      bytes, 0, bytes.size, limits, 1, object_json,
    ).should be_nil

    expected = CrystalClick::BinaryDataType.nested(
      [
        CrystalClick::BinaryDataType.dynamic(max_types: 1),
        CrystalClick::BinaryDataType.primitive("String"),
      ] of CrystalClick::BinaryDataType,
      ["d", "label"] of String,
    )
    preflight = CrystalClick::ObjectRecursiveDeclaration.preflight_slice(
      bytes, 0, bytes.size, limits, 1, dynamic_bulk,
    ).not_nil!
    preflight.profile.should eq(dynamic_bulk)
    preflight.materialize.should eq(expected)

    budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    budget.visit_node(1)
    preflight.account(budget)
    budget.node_count.should be > 0
    budget.element_count.should be > 0
    budget.wire_byte_count.should be > 0
    CrystalClick::DynamicBulkColumnDeclaration.parse(source).should eq(expected)
  end

  it "revalidates a metrics-correct public Preflight under its selected profile before charging" do
    source = "Nested(d Dynamic(max_types=1), label String)"
    bytes = source.to_slice
    limits = CrystalClick::ObjectRecursiveDeclaration::DEFAULT_LIMITS
    dynamic_bulk = CrystalClick::ObjectRecursiveDeclaration::AdmissionProfile::DynamicBulk
    object_json = CrystalClick::ObjectRecursiveDeclaration::AdmissionProfile::ObjectJson
    actual = CrystalClick::ObjectRecursiveDeclaration.preflight_slice(
      bytes, 0, bytes.size, limits, 1, dynamic_bulk,
    ).not_nil!

    # Copy every public metric and coordinate exactly; only the admission
    # profile differs from the valid DynamicBulk preflight.
    forged = CrystalClick::ObjectRecursiveDeclaration::Preflight.new(
      actual.byte_size,
      actual.descriptor_node_count,
      actual.child_edge_count,
      actual.metadata_edge_count,
      actual.enum_entry_count,
      actual.decoded_label_bytes,
      actual.explicit_zone_bytes,
      actual.tuple_name_count,
      actual.tuple_name_bytes,
      actual.max_depth,
      actual.root_depth,
      actual.source,
      actual.first,
      actual.after,
      actual.limits,
      object_json,
    )
    forged.profile.should eq(object_json)

    budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    expect_raises(ArgumentError) { forged.materialize }
    {budget.node_count, budget.element_count, budget.wire_byte_count}.should eq({0_i64, 0_i64, 0_i64})

    expect_raises(ArgumentError) { forged.account(budget) }
    {budget.node_count, budget.element_count, budget.wire_byte_count}.should eq({0_i64, 0_i64, 0_i64})
  end

  it "revalidates borrowed DynamicBulk source bytes while admitting same-size edits and rejecting malformed edits before charge" do
    limits = CrystalClick::ObjectRecursiveDeclaration::DEFAULT_LIMITS
    dynamic_bulk = CrystalClick::ObjectRecursiveDeclaration::AdmissionProfile::DynamicBulk
    bytes = "Nested(d Dynamic(max_types=1), label String)".to_slice.dup
    preflight = CrystalClick::ObjectRecursiveDeclaration.preflight_slice(
      bytes, 0, bytes.size, limits, 1, dynamic_bulk,
    ).not_nil!
    max_types_offset = "Nested(d Dynamic(max_types=".bytesize

    # The one-byte edit remains canonical and preserves all preflight metrics,
    # so the retained DynamicBulk selector must materialize the current tree.
    bytes[max_types_offset] = '2'.ord.to_u8
    expected = CrystalClick::BinaryDataType.nested(
      [
        CrystalClick::BinaryDataType.dynamic(max_types: 2),
        CrystalClick::BinaryDataType.primitive("String"),
      ] of CrystalClick::BinaryDataType,
      ["d", "label"] of String,
    )
    preflight.profile.should eq(dynamic_bulk)
    preflight.materialize.should eq(expected)

    accepted_budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    accepted_budget.visit_node(1)
    preflight.account(accepted_budget)
    accepted_budget.node_count.should be > 0
    accepted_budget.element_count.should be > 0
    accepted_budget.wire_byte_count.should be > 0

    bytes[max_types_offset] = 'x'.ord.to_u8
    expect_raises(ArgumentError) { preflight.materialize }

    malformed_budget = CrystalClick::BinaryCodecBudget.new(limits, true)
    expect_raises(ArgumentError) { preflight.account(malformed_budget) }
    {malformed_budget.node_count, malformed_budget.element_count, malformed_budget.wire_byte_count}.should eq({0_i64, 0_i64, 0_i64})
  end

  it "preserves inherited descriptor and rendered-name budget boundaries" do
    source = "Nested(a Dynamic(max_types=1))"
    exact_descriptor = CrystalClick::BinaryCodecLimits.new(
      max_depth: 3, max_nodes: 4, max_elements: 3, max_bytes: 1_000_000,
    )
    parsed = CrystalClick::DynamicBulkColumnDeclaration.parse(source, limits: exact_descriptor).not_nil!
    [
      CrystalClick::BinaryCodecLimits.new(2, 4, 3, 1_000_000_u64),
      CrystalClick::BinaryCodecLimits.new(3, 3, 3, 1_000_000_u64),
      CrystalClick::BinaryCodecLimits.new(3, 4, 2, 1_000_000_u64),
    ].each do |small|
      expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::DynamicBulkColumnDeclaration.parse(source, limits: small)
      end
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicBulkColumnDeclaration.parse(source, root_depth: 2, limits: exact_descriptor)
    end

    bounds = CrystalClick::BinaryTypeNameBudget.measure(
      parsed,
      CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
    )
    bounds.should eq({33_u64, 175_u64})
    exact_name = CrystalClick::BinaryCodecLimits.new(3, 4, 3, bounds[1].to_i)
    CrystalClick::DynamicBulkColumnDeclaration.parse(source, limits: exact_name).should eq(parsed)
    short_name = CrystalClick::BinaryCodecLimits.new(3, 4, 3, (bounds[1] - 1_u64).to_i)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicBulkColumnDeclaration.parse(source, limits: short_name)
    end
  end

  it "keeps direct, full table, window, candidate-mark and offline values on the same nominal rows" do
    parent = File.tempname("crystal-click-w249-consumers-")
    Dir.mkdir(parent)
    begin
      part = File.join(parent, "all_1_1_0")
      DynamicRecursiveHandoffW249Fixture.write_part(part, "single")
      expected = DynamicRecursiveHandoffW249Fixture.expected_rows

      direct_by_column = Hash(String, Array(CrystalClick::BinaryValue)).new
      DynamicRecursiveHandoffW249Fixture::TARGET_COLUMNS.each do |name|
        reader = CrystalClick::DynamicBulkColumnReader.open(part, name, DynamicRecursiveHandoffW249Fixture.column_types[name])
        reader.mark_row_counts.should eq(DynamicRecursiveHandoffW249Fixture::MARK_ROW_COUNTS)
        direct_by_column[name] = reader.read_marks(0, reader.mark_count).flat_map { |mark| mark }
        w249_assert_values!(direct_by_column[name], DynamicRecursiveHandoffW249Fixture.rows_for(name))
      end

      selected = [DynamicRecursiveHandoffW249Fixture::KEY_NAME] + DynamicRecursiveHandoffW249Fixture::TARGET_COLUMNS
      table = CrystalClick::WidePartTable.open_selected_typed([part], selected)
      table.total_row_count.should eq(5_u64)
      table.part_mark_row_counts.should eq([DynamicRecursiveHandoffW249Fixture::MARK_ROW_COUNTS])
      table_rows = [] of JSON::Any
      table.scan_typed do |batch|
        keys = batch.values_for(DynamicRecursiveHandoffW249Fixture::KEY_NAME)
        values = Hash(String, Slice(CrystalClick::BinaryValue)).new
        DynamicRecursiveHandoffW249Fixture::TARGET_COLUMNS.each { |name| values[name] = batch.dynamic_bulk_values_for(name) }
        keys.size.times do |index|
          row = Hash(String, CrystalClick::BinaryValue).new
          DynamicRecursiveHandoffW249Fixture::TARGET_COLUMNS.each { |name| row[name] = values[name][index] }
          table_rows << DynamicRecursiveHandoffW249Fixture.row_record(keys[index], row)
        end
      end
      DynamicRecursiveHandoffW249Fixture.rows_equal?(table_rows, expected).should be_true

      window_rows = [] of JSON::Any
      window_keys = [] of UInt64
      table.scan_typed_window(2_u64, 2) do |batch|
        keys = batch.values_for(DynamicRecursiveHandoffW249Fixture::KEY_NAME)
        values = Hash(String, Slice(CrystalClick::BinaryValue)).new
        DynamicRecursiveHandoffW249Fixture::TARGET_COLUMNS.each { |name| values[name] = batch.dynamic_bulk_values_for(name) }
        keys.size.times do |index|
          row = Hash(String, CrystalClick::BinaryValue).new
          DynamicRecursiveHandoffW249Fixture::TARGET_COLUMNS.each { |name| row[name] = values[name][index] }
          window_keys << keys[index]
          window_rows << DynamicRecursiveHandoffW249Fixture.row_record(keys[index], row)
        end
      end
      window_keys.should eq([3_u64, 4_u64])
      DynamicRecursiveHandoffW249Fixture.rows_equal?(window_rows, expected[2, 2]).should be_true

      candidate_rows = [] of JSON::Any
      candidate_keys = [] of UInt64
      table.scan_typed_candidate_marks([[0_i32, 2_i32]]) do |batch|
        keys = batch.values_for(DynamicRecursiveHandoffW249Fixture::KEY_NAME)
        values = Hash(String, Slice(CrystalClick::BinaryValue)).new
        DynamicRecursiveHandoffW249Fixture::TARGET_COLUMNS.each { |name| values[name] = batch.dynamic_bulk_values_for(name) }
        keys.size.times do |index|
          row = Hash(String, CrystalClick::BinaryValue).new
          DynamicRecursiveHandoffW249Fixture::TARGET_COLUMNS.each { |name| row[name] = values[name][index] }
          candidate_keys << keys[index]
          candidate_rows << DynamicRecursiveHandoffW249Fixture.row_record(keys[index], row)
        end
      end
      candidate_keys.should eq([1_u64, 2_u64, 5_u64])
      DynamicRecursiveHandoffW249Fixture.rows_equal?(candidate_rows, [expected[0], expected[1], expected[4]]).should be_true

      offline = w249_offline_table(part)
      DynamicRecursiveHandoffW249Fixture::TARGET_COLUMNS.each do |name|
        values = offline[name].values(max_rows: 5_u64).map(&.as(CrystalClick::BinaryValue))
        w249_assert_values!(values, DynamicRecursiveHandoffW249Fixture.rows_for(name))
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end
