require "./spec_helper"
require "file_utils"
require "./support/offline_materialized_view_compact_transform_w286_fixture"

private alias W291Projection = CrystalClick::WidePartProjection | CrystalClick::CompactPartProjection

private def w291_catalog(root : String, definitions : Array(String), compact_source : Bool = false) : Tuple(
  CrystalClick::OfflineCatalog, String, String,
)
  _catalog, database_path, target_path = CompactMaterializedViewTransformW286Fixture.catalog(
    root, compact_source: compact_source
  )

  target_metadata = File.join(database_path, "target.sql")
  target_ddl = File.read(target_metadata)
  target_ddl = target_ddl.sub(
    "`id` UInt64, `value` String",
    "`id` UInt64, `score` UInt64, `value` String",
  )
  target_ddl = target_ddl.sub(
    "`label` String\n)",
    "`label` String,\n  #{definitions.join(",\n  ")}\n)",
  )
  File.write(target_metadata, target_ddl)

  view_metadata = File.join(database_path, "view.sql")
  view_ddl = File.read(view_metadata)
  view_ddl = view_ddl.sub(
    "`id` UInt64,\n        `value` String",
    "`id` UInt64,\n        `score` UInt64,\n        `value` String",
  )
  view_ddl = view_ddl.sub(
    "AS SELECT k, v, v FROM lab.source",
    "AS SELECT k, k, v, v FROM lab.source",
  )
  File.write(view_metadata, view_ddl)
  {CrystalClick::OfflineCatalog.open(root), database_path, target_path}
end

private def w291_values(values : Array(String)) : Array(CrystalClick::BinaryValue)
  values.map { |value| CrystalClick::BinaryValue.string(value) }
end

private def w291_granules(
  values : Array(CrystalClick::BinaryValue), rows_per_mark : Int32,
) : Array(Array(CrystalClick::BinaryValue))
  granules = [] of Array(CrystalClick::BinaryValue)
  values.each_slice(rows_per_mark) { |slice| granules << slice.to_a }
  granules
end

private def w291_wide_column(
  name : String, type_name : String, values : Array(CrystalClick::BinaryValue), rows_per_mark : Int32,
) : CrystalClick::WidePartColumn
  CrystalClick::WidePartColumn.binary_bulk(
    name,
    CrystalClick::BinaryDataType.primitive(type_name),
    w291_granules(values, rows_per_mark),
  )
end

private def w291_compact_column(
  name : String, type_name : String, values : Array(CrystalClick::BinaryValue), rows_per_mark : Int32,
) : CrystalClick::CompactPartColumn
  CrystalClick::CompactPartColumn.binary_bulk(
    name,
    CrystalClick::BinaryDataType.primitive(type_name),
    w291_granules(values, rows_per_mark),
  )
end

private def w291_count_projection(
  name : String, keys : Array(UInt64), counts : Array(UInt64), rows_per_mark : Int32 = 1,
) : CrystalClick::WidePartProjection
  CrystalClick::WidePartProjection.precomputed_count(
    name,
    "score",
    keys.to_unsafe.to_slice(keys.size),
    counts.to_unsafe.to_slice(counts.size),
    rows_per_mark: rows_per_mark,
  )
end

private def w291_rows(input : CrystalClick::OfflinePartTransformInput) : Tuple(
  Array(Tuple(UInt64, String)), Array(UInt64), Array(UInt64), Array(String), Array(String),
)
  input.column_names.should eq(["k", "v"])
  input.column_types.should eq([{"k", "UInt64"}, {"v", "String"}])
  input.row_count.should eq(4_u64)
  source = [] of Tuple(UInt64, String)
  ids = [] of UInt64
  scores = [] of UInt64
  values = [] of String
  labels = [] of String
  input.each_batch do |batch|
    keys = batch.values_for("k")
    strings = batch.strings_for("v")
    keys.each_with_index do |key, index|
      value = String.new(strings[index].to_slice)
      source << {key, value}
      next unless key > 1_u64

      ids << key * 10_u64
      scores << case key
      when 2_u64 then 30_u64
      when 3_u64 then 10_u64
      when 4_u64 then 30_u64
      else            raise "unexpected source key"
      end
      values << "mapped-#{value}"
      labels << "label-#{value}"
    end
  end
  {source, ids, scores, values, labels}
end

private def w291_wide_output(
  ids : Array(UInt64), scores : Array(UInt64), values : Array(String), labels : Array(String),
  projections : Indexable(W291Projection),
) : CrystalClick::WidePartTransformOutput
  columns = [
    w291_wide_column("score", "UInt64", scores.map { |value| CrystalClick::BinaryValue.uint64(value) }, 2),
    w291_wide_column("value", "String", w291_values(values), 2),
    w291_wide_column("label", "String", w291_values(labels), 2),
  ] of CrystalClick::WidePartColumn
  CrystalClick::WidePartTransformOutput.new(
    ids.to_unsafe.to_slice(ids.size), columns, projections: projections
  )
end

private def w291_compact_output(
  ids : Array(UInt64), scores : Array(UInt64), values : Array(String), labels : Array(String),
  projections : Indexable(W291Projection),
) : CrystalClick::CompactPartTransformOutput
  columns = [
    w291_compact_column("score", "UInt64", scores.map { |value| CrystalClick::BinaryValue.uint64(value) }, 2),
    w291_compact_column("value", "String", w291_values(values), 2),
    w291_compact_column("label", "String", w291_values(labels), 2),
  ] of CrystalClick::CompactPartColumn
  CrystalClick::CompactPartTransformOutput.new(
    ids.to_unsafe.to_slice(ids.size), columns, projections: projections
  )
end

private def w291_assert_count_child(parent : String, projection_name : String) : Nil
  type = CrystalClick::BinaryDataType.aggregate_count
  reader = CrystalClick::WidePartTable.open_selected_projection_typed(
    [parent], projection_name, ["score", "count()"]
  )
  reader.column_types.should eq([{"score", "UInt64"}, {"count()", type.name}])
  reader.total_row_count.should eq(2_u64)
  reader.part_mark_row_counts.should eq([[1_u64, 1_u64]])

  rows = [] of Tuple(UInt64, UInt64)
  reader.scan_typed(batch_rows: 1) do |batch|
    keys = batch.values_for("score")
    states = batch.aggregate_count_states_for("count()", type)
    keys.each_with_index { |key, index| rows << {key, states[index].count_state} }
  end
  rows.should eq([{10_u64, 1_u64}, {30_u64, 2_u64}])

  window = [] of Tuple(UInt64, UInt64)
  reader.scan_typed_window(1_u64, 1) do |batch|
    keys = batch.values_for("score")
    states = batch.aggregate_count_states_for("count()", type)
    keys.each_with_index { |key, index| window << {key, states[index].count_state} }
  end
  window.should eq([{30_u64, 2_u64}])
end

private def w291_no_publication(target_path : String) : Nil
  Dir.children(File.join(target_path, "detached")).should be_empty
end

describe "W291 caller-run count aggregate projections" do
  it "writes aliased, reversed-key and omitted-key count children beside a plain child for both parent layouts" do
    definitions = [
      "PROJECTION `by_score_alias` (SELECT count() AS n, score GROUP BY score)",
      "PROJECTION `by_score_omitted` (SELECT count() GROUP BY score)",
      "PROJECTION `by_id` (SELECT id, label ORDER BY id)",
    ]

    [{:wide, false}, {:compact, true}].each_with_index do |(layout, compact_source), index|
      root = File.tempname("crystal-click-w291-count-layout-#{index}-")
      begin
        catalog, _database_path, target_path = w291_catalog(root, definitions, compact_source)
        callbacks = 0
        result = if layout == :wide
                   catalog.transform_materialized_view_part(
                     "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0",
                     rows_per_mark: 2, batch_rows: 1,
                   ) do |input|
                     callbacks += 1
                     _source, ids, scores, values, labels = w291_rows(input)
                     counts = [
                       w291_count_projection("by_score_alias", [10_u64, 30_u64], [1_u64, 2_u64]),
                       w291_count_projection("by_score_omitted", [10_u64, 30_u64], [1_u64, 2_u64]),
                       CrystalClick::WidePartProjection.precomputed(
                         "by_id", "id", ids.to_unsafe.to_slice(ids.size),
                         [w291_wide_column("label", "String", w291_values(labels), 1)] of CrystalClick::WidePartColumn,
                         rows_per_mark: 1,
                       ),
                     ] of W291Projection
                     w291_wide_output(ids, scores, values, labels, counts)
                   end
                 else
                   catalog.transform_materialized_view_part(
                     "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0",
                     mark_format: CrystalClick::CompactMarkFormat::Mrk3,
                     rows_per_mark: 2, batch_rows: 1,
                   ) do |input|
                     callbacks += 1
                     _source, ids, scores, values, labels = w291_rows(input)
                     counts = [
                       w291_count_projection("by_score_alias", [10_u64, 30_u64], [1_u64, 2_u64]),
                       w291_count_projection("by_score_omitted", [10_u64, 30_u64], [1_u64, 2_u64]),
                       CrystalClick::WidePartProjection.precomputed(
                         "by_id", "id", ids.to_unsafe.to_slice(ids.size),
                         [w291_wide_column("label", "String", w291_values(labels), 1)] of CrystalClick::WidePartColumn,
                         rows_per_mark: 1,
                       ),
                     ] of W291Projection
                     w291_compact_output(ids, scores, values, labels, counts)
                   end
                 end

        callbacks.should eq(1)
        result.should eq(File.join(target_path, "detached", "all_9_9_0"))
        parent = CrystalClick::TypedPartTable.open_selected_typed(
          [result], ["id", "score", "value", "label"]
        )
        parent.total_row_count.should eq(3_u64)
        w291_assert_count_child(result, "by_score_alias")
        w291_assert_count_child(result, "by_score_omitted")
        plain = CrystalClick::WidePartTable.open_selected_projection_typed([result], "by_id", ["id", "label"])
        plain.total_row_count.should eq(3_u64)
        plain.part_mark_row_counts.should eq([[1_u64, 1_u64, 1_u64]])
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "rejects invalid count groups and keeps the UInt128 count total exact" do
    expect_raises(ArgumentError) do
      CrystalClick::WidePartProjection.precomputed_count(
        "by_score", "score", Slice[10_u64, 10_u64], Slice[1_u64, 1_u64]
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::WidePartProjection.precomputed_count(
        "by_score", "score", Slice[30_u64, 10_u64], Slice[1_u64, 1_u64]
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::WidePartProjection.precomputed_count(
        "by_score", "score", Slice[10_u64], Slice[0_u64]
      )
    end
    expect_raises(ArgumentError) do
      CrystalClick::WidePartProjection.precomputed_count(
        "by_score", "score", Slice[10_u64, 30_u64], Slice[1_u64]
      )
    end

    overflow_safe = CrystalClick::WidePartProjection.precomputed_count(
      "by_score", "score", Slice[10_u64, 30_u64], Slice[UInt64::MAX, 1_u64]
    )
    overflow_safe.count_total.should eq(UInt64::MAX.to_u128 + 1_u128)
  end

  it "rejects mismatched totals, raw Compact count owners and post-scan DDL drift without publication" do
    [
      {"simple", [1_u64, 1_u64]},
      {"uint64-overflow", [UInt64::MAX, 1_u64]},
    ].each do |case_name, counts|
      root = File.tempname("crystal-click-w291-count-total-#{case_name}-")
      begin
        catalog, _database_path, target_path = w291_catalog(
          root, ["PROJECTION `by_score` (SELECT count() GROUP BY score)"]
        )
        callbacks = 0
        scanned = 0
        projection = w291_count_projection("by_score", [10_u64, 30_u64], counts)
        error = expect_raises(CrystalClick::UnsupportedFormatError) do
          catalog.transform_materialized_view_part(
            "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0",
            rows_per_mark: 2, batch_rows: 1,
          ) do |input|
            callbacks += 1
            source, ids, scores, values, labels = w291_rows(input)
            scanned = source.size
            w291_wide_output(ids, scores, values, labels, [projection] of W291Projection)
          end
        end
        (error.message || "").should contain("count projection counts must sum to the parent row count")
        callbacks.should eq(1)
        scanned.should eq(4)
        w291_no_publication(target_path)
      ensure
        FileUtils.rm_rf(root)
      end
    end

    root = File.tempname("crystal-click-w291-count-owner-")
    begin
      catalog, _database_path, target_path = w291_catalog(
        root, ["PROJECTION `by_score` (SELECT count() GROUP BY score)"]
      )
      compact_owner = CrystalClick::CompactPartProjection.precomputed(
        "by_score", "score", Slice[10_u64, 30_u64],
        [w291_compact_column("label", "String", w291_values(["one", "two"]), 1)] of CrystalClick::CompactPartColumn,
        rows_per_mark: 1,
      )
      callbacks = 0
      error = expect_raises(CrystalClick::UnsupportedFormatError) do
        catalog.transform_materialized_view_part(
          "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0",
          rows_per_mark: 2, batch_rows: 1,
        ) do |input|
          callbacks += 1
          _source, ids, scores, values, labels = w291_rows(input)
          w291_wide_output(ids, scores, values, labels, [compact_owner] of W291Projection)
        end
      end
      (error.message || "").should contain("transform count projection requires a Wide count child")
      callbacks.should eq(1)
      w291_no_publication(target_path)
    ensure
      FileUtils.rm_rf(root)
    end

    root = File.tempname("crystal-click-w291-count-ddl-drift-")
    begin
      catalog, database_path, target_path = w291_catalog(
        root, ["PROJECTION `by_score` (SELECT count() AS n, score GROUP BY score)"]
      )
      target_metadata = File.join(database_path, "target.sql")
      original = File.read(target_metadata)
      callbacks = 0
      scanned = 0
      error = expect_raises(CrystalClick::InvalidPartError) do
        catalog.transform_materialized_view_part(
          "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0",
          rows_per_mark: 2, batch_rows: 1,
        ) do |input|
          callbacks += 1
          source, ids, scores, values, labels = w291_rows(input)
          scanned = source.size
          File.write(
            target_metadata,
            original.gsub(
              "SELECT count() AS n, score GROUP BY score",
              "SELECT count() AS total, score GROUP BY score",
            ),
          )
          projection = w291_count_projection("by_score", [10_u64, 30_u64], [1_u64, 2_u64])
          w291_wide_output(ids, scores, values, labels, [projection] of W291Projection)
        end
      end
      (error.message || "").should eq("MATERIALIZED VIEW target identity changed during transform callback")
      callbacks.should eq(1)
      scanned.should eq(4)
      w291_no_publication(target_path)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "enforces count conservation through direct Wide writer preparation" do
    root = File.tempname("crystal-click-w291-direct-count-total-")
    begin
      Dir.mkdir(root)
      destination = File.join(root, "parent")
      projection = w291_count_projection("by_score", [10_u64, 30_u64], [1_u64, 1_u64])
      columns = [
        w291_wide_column("value", "String", w291_values(["one", "two", "three"]), 2),
      ] of CrystalClick::WidePartColumn
      error = expect_raises(CrystalClick::UnsupportedFormatError) do
        CrystalClick::WidePartWriter.write_uint64_columns(
          destination, "id", Slice[20_u64, 30_u64, 40_u64], columns,
          rows_per_mark: 2, projections: [projection],
        )
      end
      (error.message || "").should contain("count projection counts must sum to the parent row count")
      File.exists?(destination).should be_false
      Dir.children(root).should be_empty
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
