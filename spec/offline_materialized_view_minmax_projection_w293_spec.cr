require "./spec_helper"
require "file_utils"
require "./support/offline_materialized_view_compact_transform_w286_fixture"

private def w293_catalog(root : String, projection : String)
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

private alias W293Aggregate = CrystalClick::WidePartProjectionAggregate

private def w293_minimum : W293Aggregate
  W293Aggregate.min_uint64(
    "value", Slice[0x0102030405060708_u64, 42_u64, 0_u64]
  )
end

private def w293_maximum : W293Aggregate
  W293Aggregate.max_uint64(
    "value", Slice[0x0102030405060708_u64, 42_u64, UInt64::MAX]
  )
end

private def w293_maximum_id : W293Aggregate
  W293Aggregate.max_uint64("id", Slice[20_u64, 40_u64, 30_u64])
end

private def w293_sum : W293Aggregate
  W293Aggregate.sum_uint64(
    "value", Slice[0x0102030405060708_u64, 42_u64, UInt64::MAX]
  )
end

private def w293_count : W293Aggregate
  W293Aggregate.count(Slice[1_u64, 1_u64, 2_u64])
end

private def w293_aggregates(order : Symbol) : Array(W293Aggregate)
  minimum = w293_minimum
  maximum = w293_maximum
  sum = w293_sum
  count = w293_count
  case order
  when :min_only       then [minimum]
  when :max_only       then [maximum]
  when :mixed_alias    then [minimum, w293_maximum_id, count, sum]
  when :mixed_reversed then [sum, maximum, count, minimum]
  else                      raise "unexpected W293 aggregate order"
  end
end

private def w293_projection(aggregates : Array(W293Aggregate)) : CrystalClick::WidePartProjection
  CrystalClick::WidePartProjection.precomputed_aggregate(
    "by_group", "group_key", Slice[10_u64, 20_u64, 30_u64], aggregates,
    rows_per_mark: 2,
  )
end

private def w293_parent(input : CrystalClick::OfflinePartTransformInput) : Tuple(
  Array(UInt64), Array(Tuple(String, CrystalClick::BinaryDataType, Array(Array(CrystalClick::BinaryValue)))),
)
  keys = [] of UInt64
  groups = [] of CrystalClick::BinaryValue
  values = [] of CrystalClick::BinaryValue
  labels = [] of CrystalClick::BinaryValue
  input.each_batch do |batch|
    batch.values_for("k").each_with_index do |key, index|
      group, value = case key
                     when 1_u64 then {30_u64, UInt64::MAX}
                     when 2_u64 then {10_u64, 0x0102030405060708_u64}
                     when 3_u64 then {30_u64, 0_u64}
                     when 4_u64 then {20_u64, 42_u64}
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

private def w293_transform(
  catalog : CrystalClick::OfflineCatalog,
  projection : CrystalClick::WidePartProjection,
  compact : Bool = false,
) : String
  if compact
    catalog.transform_materialized_view_part(
      "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0",
      rows_per_mark: 2, batch_rows: 2, mark_format: CrystalClick::CompactMarkFormat::Mrk4,
    ) do |input|
      keys, columns = w293_parent(input)
      prepared = columns.map do |name, type, granules|
        CrystalClick::CompactPartColumn.binary_bulk(name, type, granules)
      end
      CrystalClick::CompactPartTransformOutput.new(
        keys.to_unsafe.to_slice(keys.size), prepared, projections: [projection]
      )
    end
  else
    catalog.transform_materialized_view_part(
      "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0",
      rows_per_mark: 2, batch_rows: 2,
    ) do |input|
      keys, columns = w293_parent(input)
      prepared = columns.map do |name, type, granules|
        CrystalClick::WidePartColumn.binary_bulk(name, type, granules)
      end
      CrystalClick::WidePartTransformOutput.new(
        keys.to_unsafe.to_slice(keys.size), prepared, projections: [projection]
      )
    end
  end
end

private def w293_state_hex(batch, column : String, function : String) : Array(String)
  batch.binary_bulk_values_for(column).map do |state|
    state.type.name.should eq("AggregateFunction(#{function}, UInt64)")
    state.aggregate_function_state_bytes.hexstring
  end.to_a
end

private def w293_declaration(column : String, function : String) : String
  if function == "count"
    "`#{column}` AggregateFunction(count)"
  else
    "`#{column}` AggregateFunction(#{function}, UInt64)"
  end
end

private def w293_expected_declarations(order : Symbol) : Array(String)
  aggregate_columns = case order
                      when :min_only then [{"min(value)", "min"}]
                      when :max_only then [{"max(value)", "max"}]
                      when :mixed_alias
                        [
                          {"min(value)", "min"}, {"max(id)", "max"},
                          {"count()", "count"}, {"sum(value)", "sum"},
                        ]
                      when :mixed_reversed
                        [
                          {"sum(value)", "sum"}, {"max(value)", "max"},
                          {"count()", "count"}, {"min(value)", "min"},
                        ]
                      else raise "unexpected W293 aggregate order"
                      end
  ["`group_key` UInt64"] + aggregate_columns.map { |column, function| w293_declaration(column, function) }
end

private def w293_projection_columns(order : Symbol) : Array(String)
  case order
  when :min_only       then ["group_key", "min(value)"]
  when :max_only       then ["group_key", "max(value)"]
  when :mixed_alias    then ["group_key", "min(value)", "max(id)", "count()", "sum(value)"]
  when :mixed_reversed then ["group_key", "sum(value)", "max(value)", "count()", "min(value)"]
  else                      raise "unexpected W293 aggregate order"
  end
end

describe "W293 caller-run UInt64 min/max aggregate projections" do
  it "admits min and max before invoking the transform callback" do
    root = File.tempname("crystal-click-w293-minmax-admission-")
    begin
      catalog, target = w293_catalog(
        root, "SELECT min(value), max(value), group_key GROUP BY group_key"
      )
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

  it "publishes min and max alone and mixed states in SELECT order for Wide and Compact parents" do
    [
      {false, "SELECT min(value) GROUP BY group_key", :min_only},
      {true, "SELECT max(value) GROUP BY group_key", :max_only},
      {false, "SELECT min(value) AS lowest, max(id) AS highest_id, count() AS rows, sum(value) AS total GROUP BY group_key", :mixed_alias},
      {true, "SELECT sum(value), max(value), count(), min(value) GROUP BY group_key", :mixed_reversed},
    ].each do |compact, ddl, order|
      root = File.tempname("crystal-click-w293-minmax-layout-")
      begin
        catalog, target = w293_catalog(root, ddl)
        projection = w293_projection(w293_aggregates(order))
        published = w293_transform(catalog, projection, compact)
        attached = File.join(target, "all_9_9_0")
        File.rename(published, attached)

        File.read_lines(File.join(attached, "by_group.proj", "columns.txt"))[2..].should eq(
          w293_expected_declarations(order)
        )
        projection_columns = w293_projection_columns(order)
        child_table = CrystalClick::WidePartTable.open_selected_projection_typed(
          [attached], "by_group", projection_columns
        )
        child_table.part_mark_row_counts.should eq([[2_u64, 1_u64]])

        table = CrystalClick::OfflineCatalog.open(root)["lab"]["target"]
        groups = [] of UInt64
        minimum_states = [] of String
        maximum_states = [] of String
        sum_states = [] of String
        counts = [] of UInt64
        table.scan_projection_typed("by_group", projection_columns, batch_rows: 2) do |batch|
          batch.part_name.should eq("all_9_9_0")
          groups.concat(batch.values_for("group_key"))
          if order == :min_only || order == :mixed_alias || order == :mixed_reversed
            minimum_states.concat(w293_state_hex(batch, "min(value)", "min"))
          end
          if order == :max_only || order == :mixed_alias || order == :mixed_reversed
            column = order == :mixed_alias ? "max(id)" : "max(value)"
            maximum_states.concat(w293_state_hex(batch, column, "max"))
          end
          if order == :mixed_alias || order == :mixed_reversed
            sum_states.concat(w293_state_hex(batch, "sum(value)", "sum"))
            counts.concat(
              batch.aggregate_count_states_for("count()", CrystalClick::BinaryDataType.aggregate_count).map(&.count_state)
            )
          end
        end
        groups.should eq([10_u64, 20_u64, 30_u64])
        expected_minimum = case order
                           when :min_only, :mixed_alias, :mixed_reversed
                             ["010807060504030201", "012a00000000000000", "010000000000000000"]
                           else
                             [] of String
                           end
        minimum_states.should eq(expected_minimum)
        expected_maximum = case order
                           when :mixed_alias
                             ["011400000000000000", "012800000000000000", "011e00000000000000"]
                           when :max_only, :mixed_reversed
                             ["010807060504030201", "012a00000000000000", "01ffffffffffffffff"]
                           else
                             [] of String
                           end
        maximum_states.should eq(expected_maximum)
        expected_sum = case order
                       when :mixed_alias, :mixed_reversed
                         ["0807060504030201", "2a00000000000000", "ffffffffffffffff"]
                       else
                         [] of String
                       end
        sum_states.should eq(expected_sum)
        counts.should eq(order == :mixed_alias || order == :mixed_reversed ? [1_u64, 1_u64, 2_u64] : [] of UInt64)

        window_groups = [] of UInt64
        window_minimum = [] of String
        window_maximum = [] of String
        table.scan_projection_typed_window("by_group", projection_columns, 1_u64, 2) do |batch|
          window_groups.concat(batch.values_for("group_key"))
          if order == :min_only || order == :mixed_alias || order == :mixed_reversed
            window_minimum.concat(w293_state_hex(batch, "min(value)", "min"))
          end
          if order == :max_only || order == :mixed_alias || order == :mixed_reversed
            column = order == :mixed_alias ? "max(id)" : "max(value)"
            window_maximum.concat(w293_state_hex(batch, column, "max"))
          end
        end
        window_groups.should eq([20_u64, 30_u64])
        expected_window_minimum = case order
                                  when :min_only, :mixed_alias, :mixed_reversed
                                    ["012a00000000000000", "010000000000000000"]
                                  else
                                    [] of String
                                  end
        window_minimum.should eq(expected_window_minimum)
        expected_window_maximum = case order
                                  when :mixed_alias
                                    ["012800000000000000", "011e00000000000000"]
                                  when :max_only, :mixed_reversed
                                    ["012a00000000000000", "01ffffffffffffffff"]
                                  else
                                    [] of String
                                  end
        window_maximum.should eq(expected_window_maximum)

        if order == :mixed_alias || order == :mixed_reversed
          selected_counts = [] of UInt64
          table.scan_projection_typed("by_group", ["count()"]) do |batch|
            selected_counts.concat(
              batch.aggregate_count_states_for("count()", CrystalClick::BinaryDataType.aggregate_count).map(&.count_state)
            )
          end
          selected_counts.should eq([1_u64, 1_u64, 2_u64])
          expect_raises(CrystalClick::UnsupportedFormatError) do
            CrystalClick::WidePart.open_typed(File.join(attached, "by_group.proj"), "count()")
          end
        end
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "rejects strict aggregate mismatches before publishing a child" do
    root = File.tempname("crystal-click-w293-minmax-mismatch-")
    begin
      catalog, target = w293_catalog(
        root, "SELECT min(value), max(id), count(), sum(value) GROUP BY group_key"
      )
      correct = w293_aggregates(:mixed_alias)
      mismatched = [
        [W293Aggregate.min_uint64("id", Slice[1_u64, 2_u64, 3_u64]), correct[1], correct[2], correct[3]],
        [correct[0], W293Aggregate.max_uint64("value", Slice[1_u64, 2_u64, 3_u64]), correct[2], correct[3]],
        [
          W293Aggregate.max_uint64("value", Slice[1_u64, 2_u64, 3_u64]),
          W293Aggregate.min_uint64("id", Slice[1_u64, 2_u64, 3_u64]),
          correct[2], correct[3],
        ],
        [correct[0], correct[1], correct[2]],
        [correct[0], correct[1], W293Aggregate.count(Slice[1_u64, 1_u64, 1_u64]), correct[3]],
      ] of Array(W293Aggregate)
      mismatched.each do |aggregates|
        expect_raises(CrystalClick::UnsupportedFormatError) do
          w293_transform(catalog, w293_projection(aggregates))
        end
        Dir.children(File.join(target, "detached")).should be_empty
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "refuses duplicate min/max calls, unsafe expressions, and ambiguous aliases before the callback" do
    [
      "SELECT min(value + 1) GROUP BY group_key",
      "SELECT max(abs(id)) GROUP BY group_key",
      "SELECT min(label) GROUP BY group_key",
      "SELECT max(label) GROUP BY group_key",
      "SELECT min(value), min(id) GROUP BY group_key",
      "SELECT max(id), max(value) GROUP BY group_key",
      "SELECT min(value) AS repeated, max(id) AS repeated GROUP BY group_key",
      "SELECT min(value) AS id, max(id) GROUP BY group_key",
      "SELECT min(value) AS group_key, group_key GROUP BY group_key",
      "SELECT min(value), count(value) GROUP BY group_key",
      "SELECT min(value) GROUP BY group_key, id",
    ].each do |ddl|
      root = File.tempname("crystal-click-w293-unsupported-minmax-")
      begin
        catalog, target = w293_catalog(root, ddl)
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

  it "validates and detaches min/max value snapshots and the aggregate roster" do
    input = Slice[0_u64, UInt64::MAX, 0x0102030405060708_u64]
    minimum = W293Aggregate.min_uint64("value", input)
    maximum = W293Aggregate.max_uint64("id", input)
    input.fill(0_u64)
    minimum.values.should eq([0_u64, UInt64::MAX, 0x0102030405060708_u64])
    maximum.values.should eq([0_u64, UInt64::MAX, 0x0102030405060708_u64])
    returned = minimum.values
    returned.fill(1_u64)
    minimum.values.should eq([0_u64, UInt64::MAX, 0x0102030405060708_u64])
    expect_raises(ArgumentError) { W293Aggregate.min_uint64("value + 1", input) }
    expect_raises(ArgumentError) { W293Aggregate.max_uint64("", input) }
    expect_raises(ArgumentError) { W293Aggregate.min_uint64("value", Slice(UInt64).new(0)) }

    aggregates = [w293_minimum, w293_maximum_id]
    projection = w293_projection(aggregates)
    aggregates.clear
    projection.aggregate_columns.map { |aggregate| aggregate.argument_name.not_nil! }.should eq(["value", "id"])
    snapshot = projection.aggregate_columns.first.values
    snapshot.fill(0_u64)
    projection.aggregate_columns.first.values.should eq([0x0102030405060708_u64, 42_u64, 0_u64])
    expect_raises(ArgumentError) do
      w293_projection([w293_minimum, W293Aggregate.min_uint64("id", Slice[1_u64, 2_u64])])
    end
    expect_raises(ArgumentError) do
      w293_projection([w293_minimum, W293Aggregate.min_uint64("id", Slice[1_u64, 2_u64, 3_u64])])
    end
  end
end
