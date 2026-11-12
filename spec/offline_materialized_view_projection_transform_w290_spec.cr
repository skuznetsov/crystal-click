require "./spec_helper"
require "file_utils"
require "./support/offline_materialized_view_compact_transform_w286_fixture"

private alias W290Projection = CrystalClick::WidePartProjection | CrystalClick::CompactPartProjection
private alias W290ProjectionReader = CrystalClick::WidePartTable | CrystalClick::CompactPartTable

private def w290_projection_ddl : Array(String)
  [
    "PROJECTION `z_label` (SELECT id, label ORDER BY id)",
    "PROJECTION `a_score` (SELECT score, value, label ORDER BY score)",
  ]
end

private def w290_catalog(
  root : String,
  projections : Array(String) = w290_projection_ddl,
  target_value_declaration : String = "String",
  compact_source : Bool = false,
) : Tuple(CrystalClick::OfflineCatalog, String, String)
  _catalog, database_path, target_path = CompactMaterializedViewTransformW286Fixture.catalog(
    root,
    target_value_declaration: target_value_declaration,
    compact_source: compact_source,
  )

  target_metadata = File.join(database_path, "target.sql")
  target_ddl = File.read(target_metadata)
  target_ddl = target_ddl.sub(
    "`id` UInt64, `value` #{target_value_declaration}",
    "`id` UInt64, `score` UInt64, `value` #{target_value_declaration}",
  )
  unless projections.empty?
    target_ddl = target_ddl.sub(
      "`label` String\n)",
      "`label` String,\n  #{projections.join(",\n  ")}\n)",
    )
  end
  File.write(target_metadata, target_ddl)

  view_metadata = File.join(database_path, "view.sql")
  view_ddl = File.read(view_metadata)
  view_ddl = view_ddl.sub(
    "`id` UInt64,\n        `value` #{target_value_declaration}",
    "`id` UInt64,\n        `score` UInt64,\n        `value` #{target_value_declaration}",
  )
  view_ddl = view_ddl.sub(
    "AS SELECT k, v, v FROM lab.source",
    "AS SELECT k, k, v, v FROM lab.source",
  )
  File.write(view_metadata, view_ddl)
  {CrystalClick::OfflineCatalog.open(root), database_path, target_path}
end

private def w290_binary_values(values : Array(String)) : Array(CrystalClick::BinaryValue)
  values.map { |value| CrystalClick::BinaryValue.string(value) }
end

private def w290_binary_values(values : Array(UInt64)) : Array(CrystalClick::BinaryValue)
  values.map { |value| CrystalClick::BinaryValue.uint64(value) }
end

private def w290_granules(
  values : Array(CrystalClick::BinaryValue),
  rows_per_mark : Int32,
) : Array(Array(CrystalClick::BinaryValue))
  granules = [] of Array(CrystalClick::BinaryValue)
  values.each_slice(rows_per_mark) { |slice| granules << slice.to_a }
  granules
end

private def w290_wide_column(
  name : String,
  type_name : String,
  values : Array(CrystalClick::BinaryValue),
  rows_per_mark : Int32,
) : CrystalClick::WidePartColumn
  CrystalClick::WidePartColumn.binary_bulk(
    name,
    CrystalClick::BinaryDataType.primitive(type_name),
    w290_granules(values, rows_per_mark),
  )
end

private def w290_compact_column(
  name : String,
  type_name : String,
  values : Array(CrystalClick::BinaryValue),
  rows_per_mark : Int32,
) : CrystalClick::CompactPartColumn
  CrystalClick::CompactPartColumn.binary_bulk(
    name,
    CrystalClick::BinaryDataType.primitive(type_name),
    w290_granules(values, rows_per_mark),
  )
end

private def w290_wide_projection(
  name : String,
  key_name : String,
  keys : Array(UInt64),
  columns : Array(CrystalClick::WidePartColumn),
  rows_per_mark : Int32 = 2,
) : CrystalClick::WidePartProjection
  CrystalClick::WidePartProjection.precomputed(
    name, key_name, keys.to_unsafe.to_slice(keys.size), columns,
    rows_per_mark: rows_per_mark,
  )
end

private def w290_compact_projection(
  name : String,
  key_name : String,
  keys : Array(UInt64),
  columns : Array(CrystalClick::CompactPartColumn),
  rows_per_mark : Int32 = 2,
  mark_format : CrystalClick::CompactMarkFormat = CrystalClick::CompactMarkFormat::Mrk3,
  frame_bytes : Int = 256,
) : CrystalClick::CompactPartProjection
  CrystalClick::CompactPartProjection.precomputed(
    name, key_name, keys.to_unsafe.to_slice(keys.size), columns,
    rows_per_mark: rows_per_mark,
    frame_bytes: frame_bytes,
    mark_format: mark_format,
  )
end

private def w290_scan(input : CrystalClick::OfflinePartTransformInput) : Tuple(
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
      when 4_u64 then 20_u64
      else            raise "unexpected source key"
      end
      values << "mapped-#{value}"
      labels << "label-#{value}"
    end
  end
  {source, ids, scores, values, labels}
end

private def w290_score_rows(
  scores : Array(UInt64), values : Array(String), labels : Array(String),
) : Array(Tuple(UInt64, String, String))
  rows = [] of Tuple(UInt64, String, String)
  scores.each_with_index { |score, i| rows << {score, values[i], labels[i]} }
  rows.sort_by!(&.[0])
end

private def w290_roster(
  score_layout : Symbol,
  label_layout : Symbol,
  ids : Array(UInt64),
  scores : Array(UInt64),
  values : Array(String),
  labels : Array(String),
) : Array(W290Projection)
  score_rows = w290_score_rows(scores, values, labels)
  score_keys = score_rows.map(&.[0])
  score_values = w290_binary_values(score_rows.map(&.[1]))
  score_labels = w290_binary_values(score_rows.map(&.[2]))

  score : W290Projection = if score_layout == :wide
    w290_wide_projection(
      "a_score", "score", score_keys,
      [
        w290_wide_column("value", "String", score_values, 2),
        w290_wide_column("label", "String", score_labels, 2),
      ] of CrystalClick::WidePartColumn,
      2,
    )
  else
    w290_compact_projection(
      "a_score", "score", score_keys,
      [
        w290_compact_column("value", "String", score_values, 2),
        w290_compact_column("label", "String", score_labels, 2),
      ] of CrystalClick::CompactPartColumn,
      2,
      CrystalClick::CompactMarkFormat::Mrk4,
    )
  end

  label_values = w290_binary_values(labels)
  label : W290Projection = if label_layout == :wide
    w290_wide_projection(
      "z_label", "id", ids,
      [w290_wide_column("label", "String", label_values, 1)] of CrystalClick::WidePartColumn,
      1,
    )
  else
    w290_compact_projection(
      "z_label", "id", ids,
      [w290_compact_column("label", "String", label_values, 1)] of CrystalClick::CompactPartColumn,
      1,
      CrystalClick::CompactMarkFormat::Mrk4,
    )
  end

  # DDL declares z_label before a_score; the callback's reverse order survives.
  [score, label]
end

private def w290_wide_output(
  ids : Array(UInt64), scores : Array(UInt64), values : Array(String), labels : Array(String),
  projections : Indexable(W290Projection) = [] of CrystalClick::WidePartProjection,
) : CrystalClick::WidePartTransformOutput
  columns = [
    w290_wide_column("score", "UInt64", w290_binary_values(scores), 2),
    w290_wide_column("value", "String", w290_binary_values(values), 2),
    w290_wide_column("label", "String", w290_binary_values(labels), 2),
  ] of CrystalClick::WidePartColumn
  CrystalClick::WidePartTransformOutput.new(
    ids.to_unsafe.to_slice(ids.size), columns, projections: projections)
end

private def w290_compact_output(
  ids : Array(UInt64), scores : Array(UInt64), values : Array(String), labels : Array(String),
  projections : Indexable(W290Projection) = [] of CrystalClick::WidePartProjection,
) : CrystalClick::CompactPartTransformOutput
  columns = [
    w290_compact_column("score", "UInt64", w290_binary_values(scores), 2),
    w290_compact_column("value", "String", w290_binary_values(values), 2),
    w290_compact_column("label", "String", w290_binary_values(labels), 2),
  ] of CrystalClick::CompactPartColumn
  CrystalClick::CompactPartTransformOutput.new(
    ids.to_unsafe.to_slice(ids.size), columns, projections: projections)
end

private def w290_check_detachment(
  supplied : Array(W290Projection),
  output : CrystalClick::WidePartTransformOutput | CrystalClick::CompactPartTransformOutput,
) : Nil
  supplied.clear
  output.projections.map(&.name).should eq(["a_score", "z_label"])
  output.projections.clear
  output.projections.map(&.name).should eq(["a_score", "z_label"])
end

private def w290_wide_callback(
  input : CrystalClick::OfflinePartTransformInput,
  score_layout : Symbol,
  label_layout : Symbol,
) : CrystalClick::WidePartTransformOutput
  source, ids, scores, values, labels = w290_scan(input)
  source.should eq([{1_u64, "one"}, {2_u64, "two"}, {3_u64, "three"}, {4_u64, "four"}])
  ids.should eq([20_u64, 30_u64, 40_u64])
  scores.should eq([30_u64, 10_u64, 20_u64])
  values.should eq(["mapped-two", "mapped-three", "mapped-four"])
  labels.should eq(["label-two", "label-three", "label-four"])
  roster = w290_roster(score_layout, label_layout, ids, scores, values, labels)
  output = w290_wide_output(ids, scores, values, labels, roster)
  w290_check_detachment(roster, output)
  output
end

private def w290_compact_callback(
  input : CrystalClick::OfflinePartTransformInput,
  score_layout : Symbol,
  label_layout : Symbol,
) : CrystalClick::CompactPartTransformOutput
  source, ids, scores, values, labels = w290_scan(input)
  source.should eq([{1_u64, "one"}, {2_u64, "two"}, {3_u64, "three"}, {4_u64, "four"}])
  ids.should eq([20_u64, 30_u64, 40_u64])
  scores.should eq([30_u64, 10_u64, 20_u64])
  values.should eq(["mapped-two", "mapped-three", "mapped-four"])
  labels.should eq(["label-two", "label-three", "label-four"])
  roster = w290_roster(score_layout, label_layout, ids, scores, values, labels)
  output = w290_compact_output(ids, scores, values, labels, roster)
  w290_check_detachment(roster, output)
  output
end

private def w290_reader(
  parent_path : String,
  layout : Symbol,
  name : String,
  columns : Array(String),
) : W290ProjectionReader
  if layout == :wide
    CrystalClick::WidePartTable.open_selected_projection_typed([parent_path], name, columns)
  else
    CrystalClick::CompactPartTable.open_selected_projection_child_typed(parent_path, name, columns)
  end
end

private def w290_two_string_rows(
  reader : W290ProjectionReader,
  key_name : String,
  first_name : String,
  second_name : String,
) : Array(Tuple(UInt64, String, String))
  rows = [] of Tuple(UInt64, String, String)
  reader.scan_typed do |batch|
    keys = batch.values_for(key_name)
    first = batch.strings_for(first_name)
    second = batch.strings_for(second_name)
    keys.each_with_index do |key, i|
      rows << {key, String.new(first[i].to_slice), String.new(second[i].to_slice)}
    end
  end
  rows
end

private def w290_one_string_rows(
  reader : W290ProjectionReader,
  key_name : String,
  value_name : String,
) : Array(Tuple(UInt64, String))
  rows = [] of Tuple(UInt64, String)
  reader.scan_typed do |batch|
    keys = batch.values_for(key_name)
    values = batch.strings_for(value_name)
    keys.each_with_index { |key, i| rows << {key, String.new(values[i].to_slice)} }
  end
  rows
end

private def w290_assert_parent(path : String) : Nil
  reader = CrystalClick::TypedPartTable.open_selected_typed(
    [path], ["id", "score", "value", "label"]
  )
  reader.total_row_count.should eq(3_u64)
  reader.part_mark_row_counts.should eq([[2_u64, 1_u64]])
  rows = [] of Tuple(UInt64, UInt64, String, String)
  reader.scan_typed do |batch|
    ids = batch.values_for("id")
    scores = batch.values_for("score")
    values = batch.strings_for("value")
    labels = batch.strings_for("label")
    ids.each_with_index do |id, i|
      rows << {id, scores[i], String.new(values[i].to_slice), String.new(labels[i].to_slice)}
    end
  end
  rows.should eq([
    {20_u64, 30_u64, "mapped-two", "label-two"},
    {30_u64, 10_u64, "mapped-three", "label-three"},
    {40_u64, 20_u64, "mapped-four", "label-four"},
  ])
end

private def w290_assert_children(
  path : String,
  score_layout : Symbol,
  label_layout : Symbol,
) : Nil
  score_reader = w290_reader(path, score_layout, "a_score", ["score", "value", "label"])
  score_reader.part_mark_row_counts.should eq([[2_u64, 1_u64]])
  w290_two_string_rows(score_reader, "score", "value", "label").should eq([
    {10_u64, "mapped-three", "label-three"},
    {20_u64, "mapped-four", "label-four"},
    {30_u64, "mapped-two", "label-two"},
  ])

  label_reader = w290_reader(path, label_layout, "z_label", ["id", "label"])
  label_reader.part_mark_row_counts.should eq([[1_u64, 1_u64, 1_u64]])
  w290_one_string_rows(label_reader, "id", "label").should eq([
    {20_u64, "label-two"},
    {30_u64, "label-three"},
    {40_u64, "label-four"},
  ])
end

private def w290_bad_roster(
  case_name : Symbol,
) : Tuple(Array(W290Projection), Regex)
  ids = [20_u64, 30_u64, 40_u64]
  scores = [10_u64, 20_u64, 30_u64]
  values = ["mapped-three", "mapped-four", "mapped-two"]
  labels = ["label-three", "label-four", "label-two"]
  parent_labels = ["label-two", "label-three", "label-four"]
  score_key = case_name == :wrong_key_name ? "id" : "score"

  score_columns = [
    w290_wide_column("value", "String", w290_binary_values(values), 2),
    w290_wide_column("label", "String", w290_binary_values(labels), 2),
  ] of CrystalClick::WidePartColumn
  if case_name == :wrong_column_order
    score_columns = [
      w290_wide_column("label", "String", w290_binary_values(labels), 2),
      w290_wide_column("value", "String", w290_binary_values(values), 2),
    ] of CrystalClick::WidePartColumn
  elsif case_name == :wrong_type
    score_columns = [
      w290_wide_column("value", "UInt64", w290_binary_values([1_u64, 2_u64, 3_u64]), 2),
      w290_wide_column("label", "String", w290_binary_values(labels), 2),
    ] of CrystalClick::WidePartColumn
  elsif case_name == :wrong_count
    scores = [10_u64, 30_u64]
    values = ["mapped-three", "mapped-two"]
    labels = ["label-three", "label-two"]
    score_columns = [
      w290_wide_column("value", "String", w290_binary_values(values), 2),
      w290_wide_column("label", "String", w290_binary_values(labels), 2),
    ] of CrystalClick::WidePartColumn
  end

  score = w290_wide_projection("a_score", score_key, scores, score_columns)
  label_name = case_name == :wrong_name ? "wrong_label" : "z_label"
  label = w290_compact_projection(
    label_name, "id", ids,
    [w290_compact_column("label", "String", w290_binary_values(parent_labels), 1)] of CrystalClick::CompactPartColumn,
    1,
  )
  roster = [] of W290Projection
  case case_name
  when :missing
    roster << score
  when :extra
    extra = w290_wide_projection(
      "extra", "score", [10_u64, 20_u64, 30_u64],
      [
        w290_wide_column("value", "String", w290_binary_values(["v1", "v2", "v3"]), 2),
        w290_wide_column("label", "String", w290_binary_values(labels), 2),
      ] of CrystalClick::WidePartColumn,
    )
    roster << score << label << extra
  when :duplicate
    duplicate = w290_compact_projection(
      "z_label", "id", ids,
      [w290_compact_column("label", "String", w290_binary_values(parent_labels), 1)] of CrystalClick::CompactPartColumn,
      1,
    )
    roster << label << duplicate
  else
    roster << score << label
  end

  message = case case_name
            when :missing, :extra, :wrong_name
              /\Atransform projection output roster does not match target DDL\z/
            when :duplicate
              /\Atransform projection output names must be unique\z/
            when :wrong_key_name
              /\Atransform projection output key does not match target schema\z/
            when :wrong_count
              /\Atransform projection output row count does not match parent row count\z/
            else
              /\Aprepared Wide columns do not match the bound target schema\z/
            end
  {roster, message}
end

private def w290_budget_labels : Array(String)
  [
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
    "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
  ]
end

private def w290_budget_rows(
  input : CrystalClick::OfflinePartTransformInput,
) : Tuple(Array(UInt64), Array(UInt64), Array(UInt64), Array(String), Int32)
  input.row_count.should eq(4_u64)
  ids = [] of UInt64
  scores = [] of UInt64
  values = [] of UInt64
  labels = [] of String
  source_keys = [] of UInt64
  source_row_count = 0
  input.each_batch do |batch|
    keys = batch.values_for("k")
    keys.each do |key|
      source_keys << key
      source_row_count += 1
      next unless key > 1_u64
      ids << key * 10_u64
      scores << case key
      when 2_u64 then 30_u64
      when 3_u64 then 10_u64
      when 4_u64 then 20_u64
      else            raise "unexpected source key"
      end
      values << key * 100_u64
      labels << case key
      when 2_u64 then w290_budget_labels[0]
      when 3_u64 then w290_budget_labels[1]
      when 4_u64 then w290_budget_labels[2]
      else            raise "unexpected source key"
      end
    end
  end
  source_keys.should eq([1_u64, 2_u64, 3_u64, 4_u64])
  {ids, scores, values, labels, source_row_count}
end

private def w290_budget_child(
  name : String,
  layout : Symbol,
  keys : Array(UInt64),
  labels : Array(String),
) : W290Projection
  values = w290_binary_values(labels)
  if layout == :wide
    w290_wide_projection(
      name, "score", keys,
      [w290_wide_column("label", "String", values, 2)] of CrystalClick::WidePartColumn,
      2,
    )
  else
    w290_compact_projection(
      name, "score", keys,
      [w290_compact_column("label", "String", values, 2)] of CrystalClick::CompactPartColumn,
      2,
      frame_bytes: 8,
    )
  end
end

private def w290_budget_roster(children : Array(Tuple(String, Symbol))) : Array(W290Projection)
  score_rows = [] of Tuple(UInt64, String)
  [30_u64, 10_u64, 20_u64].each_with_index do |score, i|
    score_rows << {score, w290_budget_labels[i]}
  end
  score_rows.sort_by!(&.[0])
  keys = score_rows.map(&.[0])
  children.map { |name, layout| w290_budget_child(name, layout, keys, score_rows.map(&.[1])) }
end

private def w290_budget_output(
  input : CrystalClick::OfflinePartTransformInput,
  projections : Array(W290Projection),
) : CrystalClick::CompactPartTransformOutput
  ids, scores, values, labels, _source_row_count = w290_budget_rows(input)
  w290_budget_output_rows(ids, scores, values, labels, projections)
end

private def w290_budget_output_rows(
  ids : Array(UInt64),
  scores : Array(UInt64),
  values : Array(UInt64),
  labels : Array(String),
  projections : Array(W290Projection),
) : CrystalClick::CompactPartTransformOutput
  columns = [
    w290_compact_column("score", "UInt64", w290_binary_values(scores), 2),
    w290_compact_column("value", "UInt64", w290_binary_values(values), 2),
    w290_compact_column("label", "String", w290_binary_values(labels), 2),
  ] of CrystalClick::CompactPartColumn
  CrystalClick::CompactPartTransformOutput.new(
    ids.to_unsafe.to_slice(ids.size), columns, projections: projections)
end

private def w290_assert_no_publication(target_path : String) : Nil
  Dir.children(File.join(target_path, "detached")).should be_empty
end

private def w290_assert_error(error : Exception, message : Regex) : Nil
  (error.message || "").should match(message)
end

describe "W290 transform projection publication" do
  it "publishes both mixed pairs with a detached reversed roster and independent key grids" do
    [
      {:wide, :compact, :wide, false},
      {:compact, :wide, :compact, true},
    ].each_with_index do |(parent_layout, score_layout, label_layout, compact_source), index|
      root = File.tempname("crystal-click-w290-mixed-#{index}-")
      begin
        catalog, _database_path, target_path = w290_catalog(root, compact_source: compact_source)
        callback_count = 0
        result = if parent_layout == :wide
                   catalog.transform_materialized_view_part(
                     "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0",
                     rows_per_mark: 2, batch_rows: 2,
                   ) do |input|
                     callback_count += 1
                     w290_wide_callback(input, score_layout, label_layout)
                   end
                 else
                   catalog.transform_materialized_view_part(
                     "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0",
                     mark_format: CrystalClick::CompactMarkFormat::Mrk3,
                     rows_per_mark: 2, batch_rows: 2,
                   ) do |input|
                     callback_count += 1
                     w290_compact_callback(input, score_layout, label_layout)
                   end
                 end
        callback_count.should eq(1)
        result.should eq(File.join(target_path, "detached", "all_9_9_0"))
        w290_assert_parent(result)
        w290_assert_children(result, score_layout, label_layout)
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "rejects missing, extra, duplicate, or mismatched callback children after a complete scan" do
    [
      :missing, :extra, :duplicate, :wrong_name, :wrong_key_name,
      :wrong_column_order, :wrong_type, :wrong_count,
    ].each do |case_name|
      root = File.tempname("crystal-click-w290-invalid-#{case_name}-")
      begin
        catalog, _database_path, target_path = w290_catalog(root)
        roster, expected_message = w290_bad_roster(case_name)
        callback_count = 0
        source_row_count = 0
        error = expect_raises(CrystalClick::UnsupportedFormatError) do
          catalog.transform_materialized_view_part(
            "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0",
            rows_per_mark: 2, batch_rows: 2,
          ) do |input|
            callback_count += 1
            source, ids, scores, values, labels = w290_scan(input)
            source_row_count = source.size
            w290_wide_output(ids, scores, values, labels, roster)
          end
        end
        w290_assert_error(error, expected_message)
        callback_count.should eq(1)
        source_row_count.should eq(4)
        w290_assert_no_publication(target_path)
      ensure
        FileUtils.rm_rf(root)
      end
    end
  end

  it "refuses unsupported aggregate projection DDL before callback and catches DDL drift after scanning" do
    [
      {"PROJECTION `by_count` (SELECT score, sum(value) GROUP BY score)",
       /\Atransform sum projection requires one plain UInt64 target column\z/},
      {"PROJECTION `by_count` (SELECT score, count(score) GROUP BY score)",
       /\Atransform count projection SELECT must contain count\(\) and optionally its group key\z/},
    ].each_with_index do |(definition, expected_message), index|
      root = File.tempname("crystal-click-w290-unsupported-ddl-#{index}-")
      begin
        catalog, _database_path, target_path = w290_catalog(root, [definition])
        callbacks = 0
        error = expect_raises(CrystalClick::UnsupportedFormatError) do
          catalog.transform_materialized_view_part(
            "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0",
            rows_per_mark: 2, batch_rows: 2,
          ) do |_input|
            callbacks += 1
            w290_wide_output([20_u64], [30_u64], ["mapped"], ["label"])
          end
        end
        w290_assert_error(error, expected_message)
        callbacks.should eq(0)
        w290_assert_no_publication(target_path)
      ensure
        FileUtils.rm_rf(root)
      end
    end

    root = File.tempname("crystal-click-w290-ddl-drift-")
    begin
      catalog, database_path, target_path = w290_catalog(root)
      target_metadata = File.join(database_path, "target.sql")
      original = File.read(target_metadata)
      callbacks = 0
      scanned = 0
      error = expect_raises(CrystalClick::InvalidPartError) do
        catalog.transform_materialized_view_part(
          "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0",
          rows_per_mark: 2, batch_rows: 2,
        ) do |input|
          callbacks += 1
          rows = w290_scan(input)
          scanned = rows[0].size
          File.write(
            target_metadata,
            original.gsub(
              "SELECT score, value, label ORDER BY score",
              "SELECT id, value, label ORDER BY id",
            ),
          )
          roster = w290_roster(:wide, :compact, rows[1], rows[2], rows[3], rows[4])
          w290_wide_output(rows[1], rows[2], rows[3], rows[4], roster)
        end
      end
      w290_assert_error(error, /\AMATERIALIZED VIEW target identity changed during transform callback\z/)
      callbacks.should eq(1)
      scanned.should eq(4)
      w290_assert_no_publication(target_path)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "rolls back when a third child exhausts the shared readback budget" do
    # One child plus the parent fits. Three full-width children exceed the cap
    # while the third child is being read back, before parent readback begins.
    limits = CrystalClick::CompressedStreamLimits.new(max_decoded_bytes: 450)
    controls = [
      {
        ["PROJECTION `z_first` (SELECT score, label ORDER BY score)"],
        [{"z_first", :wide}],
      },
      {
        ["PROJECTION `a_third` (SELECT score, label ORDER BY score)"],
        [{"a_third", :compact}],
      },
    ]
    controls.each_with_index do |(definitions, child_specs), index|
      root = File.tempname("crystal-click-w290-budget-control-#{index}-")
      begin
        catalog, _database_path, target_path = w290_catalog(
          root, definitions, target_value_declaration: "UInt64"
        )
        roster = w290_budget_roster(child_specs)
        result = catalog.transform_materialized_view_part(
          "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0",
          mark_format: CrystalClick::CompactMarkFormat::Mrk3,
          frame_bytes: 8,
          rows_per_mark: 2, batch_rows: 2, reader_limits: limits,
        ) { |input| w290_budget_output(input, roster) }
        File.directory?(result).should be_true
        Dir.children(File.join(target_path, "detached")).should eq(["all_9_9_0"])
      ensure
        FileUtils.rm_rf(root)
      end
    end

    root = File.tempname("crystal-click-w290-budget-late-")
    begin
      definitions = [
        "PROJECTION `z_first` (SELECT score, label ORDER BY score)",
        "PROJECTION `y_second` (SELECT score, label ORDER BY score)",
        "PROJECTION `a_third` (SELECT score, label ORDER BY score)",
      ]
      catalog, _database_path, target_path = w290_catalog(
        root, definitions, target_value_declaration: "UInt64"
      )
      roster = w290_budget_roster([
        {"z_first", :wide}, {"y_second", :wide}, {"a_third", :compact},
      ])
      callbacks = 0
      scanned = 0
      error = expect_raises(CrystalClick::CorruptPartError) do
        catalog.transform_materialized_view_part(
          "lab", "view", "all_1_1_0", ["k", "v"], "all_9_9_0",
          mark_format: CrystalClick::CompactMarkFormat::Mrk3,
          frame_bytes: 8,
          rows_per_mark: 2, batch_rows: 2, reader_limits: limits,
        ) do |input|
          callbacks += 1
          ids, scores, values, labels, scanned = w290_budget_rows(input)
          w290_budget_output_rows(ids, scores, values, labels, roster)
        end
      end
      w290_assert_error(error, /compressed stream decoded-byte limit exceeded/)
      callbacks.should eq(1)
      scanned.should eq(4)
      w290_assert_no_publication(target_path)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
