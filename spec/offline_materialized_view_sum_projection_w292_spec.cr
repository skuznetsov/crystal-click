require "./spec_helper"
require "file_utils"
require "./support/offline_materialized_view_compact_transform_w286_fixture"

private def w292_catalog(root : String, projection : String)
  _, database_path, target_path = CompactMaterializedViewTransformW286Fixture.catalog(
    root, target_value_declaration: "UInt64"
  )
  metadata = File.join(database_path, "target.sql")
  ddl = File.read(metadata).sub(
    "`id` UInt64, `value`",
    "`id` UInt64, `group_key` UInt64, `value`"
  ).sub(
    "`label` String\n)",
    "`label` String,\n  PROJECTION `by_group` (#{projection})\n)"
  )
  File.write(metadata, ddl)
  view_metadata = File.join(database_path, "view.sql")
  view = File.read(view_metadata).sub(
    "`id` UInt64,\n",
    "`id` UInt64,\n        `group_key` UInt64,\n"
  ).sub("AS SELECT k, v, v FROM lab.source", "AS SELECT k, k, k, v FROM lab.source")
  File.write(view_metadata, view)
  {CrystalClick::OfflineCatalog.open(root), target_path}
end

private alias W292Aggregate = CrystalClick::WidePartProjectionAggregate

private def w292_aggregates
  [
    W292Aggregate.sum_uint64("value", Slice[0x0102030405060708_u64, UInt64::MAX, 0_u64]),
    W292Aggregate.count(Slice[1_u64, 1_u64, 2_u64]),
  ]
end

private def w292_projection(aggregates : Array(W292Aggregate))
  CrystalClick::WidePartProjection.precomputed_aggregate(
    "by_group", "group_key", Slice[10_u64, 20_u64, 30_u64], aggregates, rows_per_mark: 2)
end

private def w292_parent(input : CrystalClick::OfflinePartTransformInput)
  keys = [] of UInt64
  groups = [] of CrystalClick::BinaryValue
  values = [] of CrystalClick::BinaryValue
  labels = [] of CrystalClick::BinaryValue
  input.each_batch do |batch|
    batch.values_for("k").each_with_index do |key, index|
      group, value = case key
                     when 1_u64 then {30_u64, UInt64::MAX}
                     when 2_u64 then {10_u64, 0x0102030405060708_u64}
                     when 3_u64 then {30_u64, 1_u64}
                     when 4_u64 then {20_u64, UInt64::MAX}
                     else            raise "unexpected source key"
                     end
      keys << key * 10_u64
      groups << CrystalClick::BinaryValue.uint64(group)
      values << CrystalClick::BinaryValue.uint64(value)
      labels << CrystalClick::BinaryValue.string(batch.strings_for("v")[index])
    end
  end
  uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
  string = CrystalClick::BinaryDataType.primitive("String")
  columns = [{"group_key", uint64, groups}, {"value", uint64, values}, {"label", string, labels}]
  granules = columns.map do |name, type, column|
    marks = [] of Array(CrystalClick::BinaryValue)
    column.each_slice(2) { |mark| marks << mark }
    {name, type, marks}
  end
  {keys, granules}
end

private def w292_transform(catalog : CrystalClick::OfflineCatalog, projection : CrystalClick::WidePartProjection, compact : Bool = false)
  if compact
    catalog.transform_materialized_view_part(
      "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0",
      rows_per_mark: 2, batch_rows: 2, mark_format: CrystalClick::CompactMarkFormat::Mrk4,
    ) do |input|
      keys, columns = w292_parent(input)
      prepared = columns.map do |name, type, granules|
        CrystalClick::CompactPartColumn.binary_bulk(name, type, granules)
      end
      CrystalClick::CompactPartTransformOutput.new(keys.to_unsafe.to_slice(keys.size), prepared, projections: [projection])
    end
  else
    catalog.transform_materialized_view_part(
      "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0",
      rows_per_mark: 2, batch_rows: 2,
    ) do |input|
      keys, columns = w292_parent(input)
      prepared = columns.map do |name, type, granules|
        CrystalClick::WidePartColumn.binary_bulk(name, type, granules)
      end
      CrystalClick::WidePartTransformOutput.new(keys.to_unsafe.to_slice(keys.size), prepared, projections: [projection])
    end
  end
end

private def w292_sum_row_states(batch)
  batch.binary_bulk_values_for("sum(value)").map do |state|
    state.type.name.should eq("AggregateFunction(sum, UInt64)")
    state.aggregate_function_state_bytes.hexstring
  end
end

describe "W292 caller-run Sum aggregate projections" do
  it "admits the UInt64 Sum and Count declaration before invoking the callback" do
    root = File.tempname("crystal-click-w292-sum-admission-")
    begin
      catalog, target = w292_catalog(root, "SELECT sum(value), count(), group_key GROUP BY group_key")
      expect_raises(ArgumentError, "transform callback reached") do
        catalog.transform_materialized_view_part(
          "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0",
          rows_per_mark: 2, batch_rows: 1,
        ) do |_input|
          raise ArgumentError.new("transform callback reached")
        end
      end
      Dir.children(File.join(target, "detached")).should be_empty
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "publishes Sum alone and both aggregate orders and reads the child on its own marks" do
    [
      {false, "SELECT sum(value) AS total, group_key, count() AS n GROUP BY group_key", :sum_first},
      {true, "SELECT count(), sum(`value`) GROUP BY `group_key`", :count_first},
      {false, "SELECT sum(value) GROUP BY group_key", :sum_only},
    ].each do |compact, ddl, order|
      root = File.tempname("crystal-click-w292-sum-layout-")
      begin
        catalog, target = w292_catalog(root, ddl)
        aggregates = w292_aggregates
        has_count = order != :sum_only
        case order
        when :count_first then aggregates.reverse!
        when :sum_only    then aggregates.pop
        end
        projection = w292_projection(aggregates)
        aggregates.clear
        published = w292_transform(catalog, projection, compact)
        attached = File.join(target, "all_9_9_0")
        File.rename(published, attached)

        sum_declaration = "`sum(value)` AggregateFunction(sum, UInt64)"
        count_declaration = "`count()` AggregateFunction(count)"
        expected_declarations = case order
                                when :count_first then [count_declaration, sum_declaration]
                                when :sum_first   then [sum_declaration, count_declaration]
                                else                   [sum_declaration]
                                end
        File.read_lines(File.join(attached, "by_group.proj", "columns.txt"))[2..].should eq(
          ["`group_key` UInt64"] + expected_declarations
        )
        if has_count
          expect_raises(CrystalClick::UnsupportedFormatError, "AggregateFunction(count) requires one UInt64 key and one state column") do
            CrystalClick::WidePart.open_typed(File.join(attached, "by_group.proj"), "count()")
          end
        end

        columns = ["group_key", "sum(value)"]
        columns << "count()" if has_count
        table = CrystalClick::OfflineCatalog.open(root)["lab"]["target"]
        group_keys = [] of UInt64
        sums = [] of String
        counts = [] of UInt64
        table.scan_projection_typed("by_group", columns, batch_rows: 2) do |batch|
          batch.part_name.should eq("all_9_9_0")
          group_keys.concat(batch.values_for("group_key"))
          sums.concat(w292_sum_row_states(batch))
          if has_count
            states = batch.aggregate_count_states_for("count()", CrystalClick::BinaryDataType.aggregate_count)
            counts.concat(states.map(&.count_state))
          end
        end
        group_keys.should eq([10_u64, 20_u64, 30_u64])
        sums.should eq(["0807060504030201", "ffffffffffffffff", "0000000000000000"])
        counts.should eq(has_count ? [1_u64, 1_u64, 2_u64] : [] of UInt64)

        window = [] of String
        window_counts = [] of UInt64
        table.scan_projection_typed_window("by_group", columns, 1_u64, 2) do |batch|
          window.concat(w292_sum_row_states(batch))
          if has_count
            states = batch.aggregate_count_states_for("count()", CrystalClick::BinaryDataType.aggregate_count)
            window_counts.concat(states.map(&.count_state))
          end
        end
        window.should eq(["ffffffffffffffff", "0000000000000000"])
        window_counts.should eq(has_count ? [1_u64, 2_u64] : [] of UInt64)
        if has_count
          selected_counts = [] of UInt64
          table.scan_projection_typed("by_group", ["count()"]) do |batch|
            selected_counts.concat(batch.aggregate_count_states_for("count()", CrystalClick::BinaryDataType.aggregate_count).map(&.count_state))
          end
          selected_counts.should eq([1_u64, 1_u64, 2_u64])
        end
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "rejects mismatched aggregate columns and a wrong Count total without publishing a part" do
    root = File.tempname("crystal-click-w292-sum-mismatch-")
    begin
      catalog, target = w292_catalog(root, "SELECT sum(value), count() GROUP BY group_key")
      sum, count = w292_aggregates
      wrong_argument = W292Aggregate.sum_uint64("id", Slice[1_u64, 2_u64, 3_u64])
      wrong_count = W292Aggregate.count(Slice[1_u64, 1_u64, 1_u64])
      [[count, sum], [sum], [wrong_argument, count], [sum, wrong_count]].each do |aggregates|
        expect_raises(CrystalClick::UnsupportedFormatError) do
          w292_transform(catalog, w292_projection(aggregates))
        end
        Dir.children(File.join(target, "detached")).should be_empty
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "refuses other aggregate calls and ambiguous aggregate lists before the callback" do
    [
      "SELECT sum(value + 1) GROUP BY group_key",
      "SELECT sum(label) GROUP BY group_key",
      "SELECT sum(value), sum(id) GROUP BY group_key",
      "SELECT sum(value), count(value) GROUP BY group_key",
      "SELECT sum(value) AS n, count() AS n GROUP BY group_key",
      "SELECT sum(value) GROUP BY group_key, id",
    ].each do |ddl|
      root = File.tempname("crystal-click-w292-unsupported-sum-")
      begin
        catalog, target = w292_catalog(root, ddl)
        expect_raises(CrystalClick::UnsupportedFormatError) do
          catalog.transform_materialized_view_part(
            "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0",
            rows_per_mark: 2, batch_rows: 1,
          ) do |_input|
            raise ArgumentError.new("unexpected callback")
          end
        end
        Dir.children(File.join(target, "detached")).should be_empty
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "validates typed aggregate inputs and detaches their state slices" do
    values = Slice[0_u64, UInt64::MAX, 0x0102030405060708_u64]
    sum = W292Aggregate.sum_uint64("value", values)
    values.fill(0_u64)
    expect_raises(ArgumentError) { W292Aggregate.sum_uint64("value + 1", values) }
    expect_raises(ArgumentError) do
      w292_projection([W292Aggregate.sum_uint64("value", Slice[1_u64])])
    end
    expect_raises(ArgumentError) do
      w292_projection([sum, W292Aggregate.sum_uint64("id", values)])
    end
    root = File.tempname("crystal-click-w292-sum-detached-")
    begin
      catalog, target = w292_catalog(root, "SELECT sum(value) GROUP BY group_key")
      too_many_groups = CrystalClick::WidePartProjection.precomputed_aggregate(
        "by_group", "group_key", Slice[10_u64, 20_u64, 30_u64, 40_u64, 50_u64],
        [W292Aggregate.sum_uint64("value", Slice[0_u64, 0_u64, 0_u64, 0_u64, 0_u64])],
        rows_per_mark: 2,
      )
      expect_raises(CrystalClick::UnsupportedFormatError) { w292_transform(catalog, too_many_groups) }
      Dir.children(File.join(target, "detached")).should be_empty
      parent = w292_transform(catalog, w292_projection([sum]))
      reader = CrystalClick::WidePartTable.open_selected_projection_typed([parent], "by_group", ["sum(value)"])
      states = [] of String
      reader.scan_typed { |batch| states.concat(w292_sum_row_states(batch)) }
      states.should eq(["0000000000000000", "ffffffffffffffff", "0807060504030201"])
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
