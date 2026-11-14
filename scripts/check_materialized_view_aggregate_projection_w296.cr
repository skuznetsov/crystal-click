require "../src/crystal_click"
require "json"

# Offline half of the W296 stock-native -> caller transform -> Compact
# AggregateFunction projection witness.
module MaterializedViewAggregateProjectionW296
  extend self

  FORMAT                     = "materialized_view_aggregate_projection_w296_helper_v1"
  DATABASE                   = "lab"
  SOURCE_PART                = "all_1_1_0"
  WIDE_PART                  = "all_9_9_0"
  COMPACT_PART               = "all_10_10_0"
  PROJECTION                 = "by_group"
  SOURCE_COLUMNS             = ["source_id", "source_group", "value"]
  PARENT_COLUMNS             = ["parent_id", "group_key", "value"]
  COMPACT_AGGREGATES         = ["max(value)", "sum(value)", "min(value)"]
  WIDE_AGGREGATES            = ["min(value)", "count()", "sum(value)", "max(value)"]
  COMPACT_PROJECTION_COLUMNS = ["group_key"] + COMPACT_AGGREGATES
  WIDE_PROJECTION_COLUMNS    = ["group_key"] + WIDE_AGGREGATES
  WIDE_TARGET_UUID           = "f2960000-7b7f-4e2f-9e44-dc13a87b8804"
  COMPACT_TARGET_UUID        = "f2960000-7b7f-4e2f-9e44-dc13a87b8803"
  CHILD_ROWS_PER_MARK        =                      2
  PARENT_ROWS_PER_MARK       =                      2
  WINDOW_START               =                  1_u64
  WINDOW_COUNT               =                  4_u64
  PARENT_WINDOW_COUNT        =                  5_u64
  ASYMMETRIC                 = 0x0102030405060708_u64
  UINT64_MAX_VALUE           = UInt64::MAX
  GROUP_KEYS                 = [
    7_u64,
    42_u64,
    ASYMMETRIC,
    0x8000000000000001_u64,
    UINT64_MAX_VALUE,
  ]
  GROUP_COUNTS     = [1_u64, 130_u64, 2_u64, 7_u64, 3_u64]
  SOURCE_ROW_COUNT = 143_u64

  alias SourceRow = Tuple(UInt64, UInt64, UInt64)
  alias ParentRow = Tuple(UInt64, UInt64, UInt64)

  def run(catalog_root : String, action : String, wide_part : String = WIDE_PART, compact_part : String = COMPACT_PART) : JSON::Any
    case action
    when "publish"
      publish(catalog_root)
    when "reopen"
      reopen(catalog_root, wide_part, compact_part)
    else
      raise ArgumentError.new("W296 action must be publish or reopen")
    end
  end

  private def publish(catalog_root : String) : JSON::Any
    catalog = CrystalClick::OfflineCatalog.open(catalog_root)
    source = catalog.table(DATABASE, "source")
    candidate = source.part_candidates.find { |part| part.name == SOURCE_PART } ||
                raise CrystalClick::InvalidPartError.new("W296 stock source part is absent")
    unless candidate.row_count == SOURCE_ROW_COUNT && source.columns.map { |column| {column.name, column.type} } == [
             {"source_id", "UInt64"}, {"source_group", "UInt64"}, {"value", "UInt64"},
           ]
      raise CrystalClick::CorruptPartError.new("W296 source candidate or schema differs")
    end

    compact_path = catalog.transform_materialized_view_part(
      DATABASE, "view_compact", SOURCE_PART, SOURCE_COLUMNS, COMPACT_PART,
      mark_format: CrystalClick::CompactMarkFormat::Mrk4,
      compress_marks: true,
      rows_per_mark: PARENT_ROWS_PER_MARK,
      batch_rows: 2,
      profile: CrystalClick::BinaryBulkProfile.with_size_stream,
    ) do |input|
      compact_output(transform_rows(input))
    end
    wide_path = catalog.transform_materialized_view_part(
      DATABASE, "view_wide", SOURCE_PART, SOURCE_COLUMNS, WIDE_PART,
      rows_per_mark: PARENT_ROWS_PER_MARK,
      batch_rows: 2,
      profile: CrystalClick::BinaryBulkProfile.with_size_stream,
    ) do |input|
      wide_output(transform_rows(input))
    end

    expected_compact = target_path(catalog_root, COMPACT_TARGET_UUID, "detached", COMPACT_PART)
    expected_wide = target_path(catalog_root, WIDE_TARGET_UUID, "detached", WIDE_PART)
    unless compact_path == expected_compact && wide_path == expected_wide
      raise CrystalClick::InvalidPartError.new("W296 transform destination differs from resolved targets")
    end

    summaries = expected_group_summaries
    JSON::Any.new({
      "format"                     => JSON::Any.new(FORMAT),
      "action"                     => JSON::Any.new("publish"),
      "status"                     => JSON::Any.new("ok"),
      "source_part_name"           => JSON::Any.new(SOURCE_PART),
      "source_row_count"           => JSON::Any.new(SOURCE_ROW_COUNT),
      "parent_rows"                => parent_rows_json(expected_parent_rows),
      "group_keys"                 => u64_array_json(summaries.map(&.key)),
      "group_counts"               => u64_array_json(summaries.map(&.count)),
      "group_sums"                 => u64_array_json(summaries.map(&.sum)),
      "group_mins"                 => u64_array_json(summaries.map(&.minimum)),
      "group_maxs"                 => u64_array_json(summaries.map(&.maximum)),
      "compact_parent_path"        => JSON::Any.new(compact_path),
      "wide_parent_path"           => JSON::Any.new(wide_path),
      "parent_mark_count"          => JSON::Any.new(mark_count(SOURCE_ROW_COUNT, PARENT_ROWS_PER_MARK)),
      "parent_tail_rows"           => JSON::Any.new((SOURCE_ROW_COUNT % PARENT_ROWS_PER_MARK).to_i),
      "child_mark_rows"            => int_array_json(child_mark_rows),
      "compact_projection_columns" => string_array_json(COMPACT_PROJECTION_COLUMNS),
      "wide_projection_columns"    => string_array_json(WIDE_PROJECTION_COLUMNS),
      "compact_aggregate_order"    => string_array_json(COMPACT_AGGREGATES),
      "wide_aggregate_order"       => string_array_json(WIDE_AGGREGATES),
      "min_state_hex"              => string_array_json(summaries.map { |summary| minmax_state(summary.minimum).hexstring }),
      "max_state_hex"              => string_array_json(summaries.map { |summary| minmax_state(summary.maximum).hexstring }),
      "sum_state_hex"              => string_array_json(summaries.map { |summary| uint64_le(summary.sum).hexstring }),
      "count_state_varuint_hex"    => string_array_json(summaries.map { |summary| varuint(summary.count).hexstring }),
      "compact_child_format"       => JSON::Any.new("Compact MRK4"),
      "wide_child_format"          => JSON::Any.new("Compact MRK4"),
    } of String => JSON::Any)
  end

  private def reopen(catalog_root : String, wide_part_name : String, compact_part_name : String) : JSON::Any
    [wide_part_name, compact_part_name].each do |name|
      unless /\A[a-zA-Z0-9_-]+\z/.matches?(name) && name.includes?('_')
        raise CrystalClick::InvalidPartError.new("W296 attached part identity is malformed")
      end
    end
    catalog = CrystalClick::OfflineCatalog.open(catalog_root)
    compact = reopen_pair(catalog, catalog_root, "target_compact", compact_part_name, "Compact", COMPACT_TARGET_UUID,
      COMPACT_PROJECTION_COLUMNS, COMPACT_AGGREGATES)
    wide = reopen_pair(catalog, catalog_root, "target_wide", wide_part_name, "Wide", WIDE_TARGET_UUID,
      WIDE_PROJECTION_COLUMNS, WIDE_AGGREGATES)
    JSON::Any.new({
      "format"       => JSON::Any.new(FORMAT),
      "action"       => JSON::Any.new("reopen"),
      "status"       => JSON::Any.new("ok"),
      "catalog_root" => JSON::Any.new(catalog.root),
      "pairs"        => JSON::Any.new([compact, wide]),
    } of String => JSON::Any)
  end

  private def reopen_pair(
    catalog : CrystalClick::OfflineCatalog,
    catalog_root : String,
    table_name : String,
    part_name : String,
    parent_format : String,
    uuid : String,
    projection_columns : Array(String),
    aggregate_columns : Array(String),
  ) : JSON::Any
    table = catalog.table(DATABASE, table_name)
    projection = table.projections.find { |entry| entry.name == PROJECTION } ||
                 raise CrystalClick::CorruptPartError.new("W296 #{table_name} projection metadata is absent")
    expected_definition = if table_name == "target_compact"
                            "SELECT max(value) AS maximum, sum(value) AS total, min(value) AS minimum GROUP BY group_key"
                          else
                            "SELECT group_key, min(value) AS minimum, count() AS n, sum(value) AS total, max(value) AS maximum GROUP BY group_key"
                          end
    unless projection.definition.gsub(/\s+/, " ").strip == expected_definition &&
           table.columns.map { |column| {column.name, column.type} } == [
             {"parent_id", "UInt64"}, {"group_key", "UInt64"}, {"value", "UInt64"},
           ]
      raise CrystalClick::CorruptPartError.new("W296 #{table_name} persisted schema or projection DDL differs")
    end

    candidates = table.part_candidates
    unless candidates.size == 1 && candidates.first.name == part_name && candidates.first.row_count == SOURCE_ROW_COUNT
      raise CrystalClick::CorruptPartError.new("W296 #{table_name} attached candidate identity/count differs")
    end
    part = candidates.first
    expected_path = target_path(catalog_root, uuid, part_name)
    unless part.path == expected_path
      raise CrystalClick::InvalidPartError.new("W296 #{table_name} candidate escaped its target directory")
    end
    child_path = File.join(part.path, "#{PROJECTION}.proj")
    assert_format!(part.path, parent_format, "#{table_name} parent", table_name == "target_compact")
    assert_format!(child_path, "Compact", "#{table_name} aggregate child", table_name == "target_compact")

    parent, parent_grid, parent_identity = scan_parent(table, part, nil)
    parent_window, parent_window_grid, parent_window_identity = scan_parent(table, part, {WINDOW_START, PARENT_WINDOW_COUNT})
    child, child_grid, child_identity, child_states = scan_child(table, part, projection_columns, aggregate_columns, nil)
    child_window, child_window_grid, child_window_identity, child_window_states =
      scan_child(table, part, projection_columns, aggregate_columns, {WINDOW_START, WINDOW_COUNT})
    keys, key_grid, key_identity = scan_keys(table, part, nil)
    key_window, key_window_grid, key_window_identity = scan_keys(table, part, {WINDOW_START, WINDOW_COUNT})
    state_only, state_only_grid, state_only_identity, state_only_hex = scan_state_only(table, part, aggregate_columns, nil)
    state_window, state_window_grid, state_window_identity, state_window_hex =
      scan_state_only(table, part, aggregate_columns, {WINDOW_START, WINDOW_COUNT})

    summaries = expected_group_summaries
    expected_children = summaries.map { |summary| [summary.key] + aggregate_columns.map { |name| aggregate_value(summary, name) } }
    expected_window = expected_children[WINDOW_START.to_i, WINDOW_COUNT.to_i]
    expected_parent_window = expected_parent_rows[WINDOW_START.to_i, PARENT_WINDOW_COUNT.to_i]
    expected_identity = {"part_name" => part.name, "part_path" => part.path}
    expected_state_hex = Hash(String, Array(String)).new
    expected_state_window_hex = Hash(String, Array(String)).new
    expected_state_values = Hash(String, Array(UInt64)).new
    expected_state_window_values = Hash(String, Array(UInt64)).new
    window_summaries = summaries[WINDOW_START.to_i, WINDOW_COUNT.to_i]
    aggregate_columns.each do |name|
      expected_state_hex[name] = summaries.map { |summary| aggregate_state(name, summary).hexstring }
      expected_state_window_hex[name] = window_summaries.map { |summary| aggregate_state(name, summary).hexstring }
      expected_state_values[name] = summaries.map { |summary| aggregate_value(summary, name) }
      expected_state_window_values[name] = window_summaries.map { |summary| aggregate_value(summary, name) }
    end
    unless parent == expected_parent_rows && parent_grid == expected_parent_mark_rows && parent_window == expected_parent_window &&
           parent_window_grid == [1, 2, 2] && child == expected_children && child_grid == child_mark_rows &&
           child_window == expected_window && child_window_grid == [1, 2, 1] &&
           keys == GROUP_KEYS.to_a && key_grid == child_mark_rows && key_window == expected_window.map(&.first) && key_window_grid == [1, 2, 1] &&
           state_only == expected_state_values && state_only_grid == child_mark_rows && state_window == expected_state_window_values &&
           state_window_grid == [1, 2, 1] && child_states == expected_state_hex && child_window_states == expected_state_window_hex &&
           state_only_hex == expected_state_hex && state_window_hex == expected_state_window_hex &&
           [parent_identity, parent_window_identity, child_identity, child_window_identity, key_identity, key_window_identity,
            state_only_identity, state_window_identity].all? { |identity| identity == expected_identity }
      raise CrystalClick::CorruptPartError.new("W296 #{table_name} full/window parent or aggregate rows differ")
    end

    callback_identity = Hash(String, JSON::Any).new
    expected_identity.each { |key, value| callback_identity[key] = JSON::Any.new(value) }
    JSON::Any.new({
      "table"                             => JSON::Any.new(table_name),
      "part_name"                         => JSON::Any.new(part.name),
      "parent_format"                     => JSON::Any.new(parent_format),
      "child_format"                      => JSON::Any.new("Compact"),
      "parent_rows"                       => parent_rows_json(parent),
      "parent_mark_rows"                  => int_array_json(parent_grid),
      "parent_window_start_1_count_5"     => parent_rows_json(parent_window),
      "parent_window_mark_rows"           => int_array_json(parent_window_grid),
      "child_rows"                        => nested_u64_json(child),
      "child_mark_rows"                   => int_array_json(child_grid),
      "child_window_start_1_count_4"      => nested_u64_json(child_window),
      "child_window_mark_rows"            => int_array_json(child_window_grid),
      "child_keys_only"                   => u64_array_json(keys),
      "child_keys_window_start_1_count_4" => u64_array_json(key_window),
      "state_only_rows"                   => state_rows_json(state_only),
      "state_only_window_rows"            => state_rows_json(state_window),
      "state_only_mark_rows"              => int_array_json(state_only_grid),
      "state_only_window_mark_rows"       => int_array_json(state_window_grid),
      "state_hex"                         => state_hex_json(child_states),
      "state_window_hex"                  => state_hex_json(child_window_states),
      "state_only_hex"                    => state_hex_json(state_only_hex),
      "state_only_window_hex"             => state_hex_json(state_window_hex),
      "parent_path"                       => JSON::Any.new(part.path),
      "child_path"                        => JSON::Any.new(child_path),
      "callback_parent_identity"          => JSON::Any.new(callback_identity),
      "projection_columns"                => string_array_json(projection_columns),
      "aggregate_columns_only"            => string_array_json(aggregate_columns),
      "reopen_source"                     => JSON::Any.new("byte_identical_native_part_copy"),
    } of String => JSON::Any)
  end

  private def transform_rows(input : CrystalClick::OfflinePartTransformInput) : Array(ParentRow)
    unless input.row_count == SOURCE_ROW_COUNT && input.column_names == SOURCE_COLUMNS && input.column_types == [
             {"source_id", "UInt64"}, {"source_group", "UInt64"}, {"value", "UInt64"},
           ]
      raise CrystalClick::CorruptPartError.new("W296 callback source identity or schema differs")
    end
    observed = [] of SourceRow
    output = [] of ParentRow
    input.each_batch do |batch|
      ids = batch.values_for("source_id", UInt64)
      groups = batch.values_for("source_group", UInt64)
      values = batch.values_for("value", UInt64)
      unless ids.size == groups.size && groups.size == values.size
        raise CrystalClick::CorruptPartError.new("W296 source columns are not aligned")
      end
      ids.each_index do |index|
        row = {ids[index], groups[index], values[index]}
        expected = source_rows[observed.size]?
        unless expected && expected == row
          raise CrystalClick::CorruptPartError.new("W296 literal source differs at row #{observed.size}")
        end
        observed << row
        output << {ids[index] + 100_u64, groups[index], values[index]}
      end
    end
    unless observed == source_rows && output == expected_parent_rows
      raise CrystalClick::CorruptPartError.new("W296 transform callback did not complete the exact source map")
    end
    output
  end

  private def compact_output(rows : Array(ParentRow)) : CrystalClick::CompactPartTransformOutput
    ids = rows.map(&.[0])
    groups = rows.map(&.[1])
    values = rows.map(&.[2])
    keys, summaries = aggregate_values(rows)
    maxima = summaries.map(&.maximum)
    sums = summaries.map(&.sum)
    minima = summaries.map(&.minimum)
    aggregates = [
      CrystalClick::WidePartProjectionAggregate.max_uint64("value", maxima.to_unsafe.to_slice(maxima.size)),
      CrystalClick::WidePartProjectionAggregate.sum_uint64("value", sums.to_unsafe.to_slice(sums.size)),
      CrystalClick::WidePartProjectionAggregate.min_uint64("value", minima.to_unsafe.to_slice(minima.size)),
    ] of CrystalClick::WidePartProjectionAggregate
    projection = CrystalClick::CompactPartProjection.precomputed_aggregate(
      PROJECTION, "group_key", keys.to_unsafe.to_slice(keys.size), aggregates,
      rows_per_mark: CHILD_ROWS_PER_MARK,
      frame_bytes: 4096,
      compress_marks: true,
    )
    CrystalClick::CompactPartTransformOutput.new(
      ids.to_unsafe.to_slice(ids.size),
      [compact_u64("group_key", groups), compact_u64("value", values)] of CrystalClick::CompactPartColumn,
      projections: [projection] of (CrystalClick::WidePartProjection | CrystalClick::CompactPartProjection),
    )
  end

  private def wide_output(rows : Array(ParentRow)) : CrystalClick::WidePartTransformOutput
    ids = rows.map(&.[0])
    groups = rows.map(&.[1])
    values = rows.map(&.[2])
    keys, summaries = aggregate_values(rows)
    counts = summaries.map(&.count)
    minima = summaries.map(&.minimum)
    sums = summaries.map(&.sum)
    maxima = summaries.map(&.maximum)
    aggregates = [
      CrystalClick::WidePartProjectionAggregate.min_uint64("value", minima.to_unsafe.to_slice(minima.size)),
      CrystalClick::WidePartProjectionAggregate.count(counts.to_unsafe.to_slice(counts.size)),
      CrystalClick::WidePartProjectionAggregate.sum_uint64("value", sums.to_unsafe.to_slice(sums.size)),
      CrystalClick::WidePartProjectionAggregate.max_uint64("value", maxima.to_unsafe.to_slice(maxima.size)),
    ] of CrystalClick::WidePartProjectionAggregate
    projection = CrystalClick::CompactPartProjection.precomputed_aggregate(
      PROJECTION, "group_key", keys.to_unsafe.to_slice(keys.size), aggregates,
      rows_per_mark: CHILD_ROWS_PER_MARK,
      frame_bytes: 4096,
      compress_marks: false,
    )
    CrystalClick::WidePartTransformOutput.new(
      ids.to_unsafe.to_slice(ids.size),
      [wide_u64("group_key", groups), wide_u64("value", values)] of CrystalClick::WidePartColumn,
      projections: [projection] of (CrystalClick::WidePartProjection | CrystalClick::CompactPartProjection),
    )
  end

  private def aggregate_values(rows : Array(ParentRow)) : {Array(UInt64), Array(GroupSummary)}
    counts = Hash(UInt64, UInt64).new(0_u64)
    sums = Hash(UInt64, UInt64).new(0_u64)
    mins = Hash(UInt64, UInt64).new
    maxs = Hash(UInt64, UInt64).new
    rows.each do |row|
      key = row[1]
      value = row[2]
      counts[key] += 1_u64
      sums[key] = ((sums[key].to_u128 + value.to_u128) & UInt64::MAX.to_u128).to_u64
      if minimum = mins[key]?
        mins[key] = value if value < minimum
      else
        mins[key] = value
      end
      if maximum = maxs[key]?
        maxs[key] = value if value > maximum
      else
        maxs[key] = value
      end
    end
    keys = counts.keys.sort
    summaries = keys.map { |key| GroupSummary.new(key, counts[key], sums[key], mins[key], maxs[key]) }
    unless summaries.map { |item| {item.key, item.count, item.sum, item.minimum, item.maximum} } ==
             expected_group_summaries.map { |item| {item.key, item.count, item.sum, item.minimum, item.maximum} }
      raise CrystalClick::CorruptPartError.new("W296 caller aggregate oracle differs")
    end
    {keys, summaries}
  end

  private def scan_parent(
    table : CrystalClick::OfflineTable,
    part : CrystalClick::OfflinePartCandidate,
    window : Tuple(UInt64, UInt64)?,
  ) : {Array(ParentRow), Array(Int32), Hash(String, String)}
    rows = [] of ParentRow
    grid = [] of Int32
    identity = identity_for(part)
    callback = ->(batch : CrystalClick::WidePartTableBatch) do
      observe_identity!(identity, batch)
      ids = batch.values_for("parent_id", UInt64)
      groups = batch.values_for("group_key", UInt64)
      values = batch.values_for("value", UInt64)
      ids.each_index { |index| rows << {ids[index], groups[index], values[index]} }
      grid << ids.size.to_i32
      nil
    end
    if range = window
      table.scan_typed_window(PARENT_COLUMNS, range[0], range[1], &callback)
    else
      table.scan_typed(PARENT_COLUMNS, batch_rows: PARENT_ROWS_PER_MARK, &callback)
    end
    {rows, grid, identity}
  end

  private def scan_child(
    table : CrystalClick::OfflineTable,
    part : CrystalClick::OfflinePartCandidate,
    columns : Array(String),
    aggregate_columns : Array(String),
    window : Tuple(UInt64, UInt64)?,
  ) : {Array(Array(UInt64)), Array(Int32), Hash(String, String), Hash(String, Array(String))}
    rows = [] of Array(UInt64)
    grid = [] of Int32
    state_hex = Hash(String, Array(String)).new
    aggregate_columns.each { |name| state_hex[name] = [] of String }
    identity = identity_for(part)
    callback = ->(batch : CrystalClick::WidePartTableBatch) do
      observe_identity!(identity, batch)
      keys = batch.values_for("group_key", UInt64)
      values_by_column = Hash(String, Array(UInt64)).new
      aggregate_columns.each do |name|
        values, encoded = read_state_column(batch, name)
        unless values.size == keys.size
          raise CrystalClick::CorruptPartError.new("W296 child key and #{name} state rows are not aligned")
        end
        values_by_column[name] = values
        state_hex[name].concat(encoded)
      end
      keys.each_index do |index|
        row = [keys[index]] of UInt64
        aggregate_columns.each { |name| row << values_by_column[name][index] }
        rows << row
      end
      grid << keys.size.to_i32
      nil
    end
    if range = window
      table.scan_projection_typed_window(PROJECTION, columns, range[0], range[1], &callback)
    else
      table.scan_projection_typed(PROJECTION, columns, batch_rows: CHILD_ROWS_PER_MARK, &callback)
    end
    {rows, grid, identity, state_hex}
  end

  private def scan_keys(
    table : CrystalClick::OfflineTable,
    part : CrystalClick::OfflinePartCandidate,
    window : Tuple(UInt64, UInt64)?,
  ) : {Array(UInt64), Array(Int32), Hash(String, String)}
    rows = [] of UInt64
    grid = [] of Int32
    identity = identity_for(part)
    callback = ->(batch : CrystalClick::WidePartTableBatch) do
      observe_identity!(identity, batch)
      keys = batch.values_for("group_key", UInt64)
      rows.concat(keys.to_a)
      grid << keys.size.to_i32
      nil
    end
    if range = window
      table.scan_projection_typed_window(PROJECTION, ["group_key"], range[0], range[1], &callback)
    else
      table.scan_projection_typed(PROJECTION, ["group_key"], batch_rows: CHILD_ROWS_PER_MARK, &callback)
    end
    {rows, grid, identity}
  end

  private def scan_state_only(
    table : CrystalClick::OfflineTable,
    part : CrystalClick::OfflinePartCandidate,
    aggregate_columns : Array(String),
    window : Tuple(UInt64, UInt64)?,
  ) : {Hash(String, Array(UInt64)), Array(Int32), Hash(String, String), Hash(String, Array(String))}
    rows = Hash(String, Array(UInt64)).new
    state_hex = Hash(String, Array(String)).new
    aggregate_columns.each do |name|
      rows[name] = [] of UInt64
      state_hex[name] = [] of String
    end
    grid = [] of Int32
    identity = identity_for(part)
    callback = ->(batch : CrystalClick::WidePartTableBatch) do
      observe_identity!(identity, batch)
      batch_rows = nil.as(Int32?)
      aggregate_columns.each do |name|
        values, encoded = read_state_column(batch, name)
        if batch_rows
          unless values.size == batch_rows
            raise CrystalClick::CorruptPartError.new("W296 aggregate-only state columns are not aligned")
          end
        else
          batch_rows = values.size.to_i32
        end
        rows[name].concat(values)
        state_hex[name].concat(encoded)
      end
      grid << batch_rows.not_nil!
      nil
    end
    if range = window
      table.scan_projection_typed_window(PROJECTION, aggregate_columns, range[0], range[1], &callback)
    else
      table.scan_projection_typed(PROJECTION, aggregate_columns, batch_rows: CHILD_ROWS_PER_MARK, &callback)
    end
    {rows, grid, identity, state_hex}
  end

  private def read_state_column(batch : CrystalClick::WidePartTableBatch, name : String) : {Array(UInt64), Array(String)}
    if name == "count()"
      states = batch.aggregate_count_states_for(name, CrystalClick::BinaryDataType.aggregate_count)
      return {states.map(&.count_state).to_a, states.map { |state| varuint(state.count_state).hexstring }.to_a}
    end

    expected_type = case name
                    when "min(value)" then "AggregateFunction(min, UInt64)"
                    when "max(value)" then "AggregateFunction(max, UInt64)"
                    when "sum(value)" then "AggregateFunction(sum, UInt64)"
                    else                   raise CrystalClick::UnsupportedFormatError.new("W296 unknown state column #{name}")
                    end
    values = [] of UInt64
    encoded = [] of String
    batch.binary_bulk_values_for(name).each do |state|
      bytes = state.aggregate_function_state_bytes
      if name == "sum(value)"
        unless state.type.name == expected_type && bytes.size == 8
          raise CrystalClick::CorruptPartError.new("W296 sum state nominal type or payload length differs")
        end
        values << IO::Memory.new(bytes).read_bytes(UInt64, IO::ByteFormat::LittleEndian)
      else
        unless state.type.name == expected_type && bytes.size == 9 && bytes[0] == 1_u8
          raise CrystalClick::CorruptPartError.new("W296 #{name} state nominal type, presence byte, or payload length differs")
        end
        values << IO::Memory.new(bytes[1, 8]).read_bytes(UInt64, IO::ByteFormat::LittleEndian)
      end
      encoded << bytes.hexstring
    end
    {values, encoded}
  end

  private def observe_identity!(identity : Hash(String, String), batch : CrystalClick::WidePartTableBatch) : Nil
    actual = {"part_name" => batch.part_name, "part_path" => batch.part_path}
    unless actual == identity
      raise CrystalClick::CorruptPartError.new("W296 scan callback does not identify its selected parent part")
    end
    nil
  end

  private def identity_for(part : CrystalClick::OfflinePartCandidate) : Hash(String, String)
    {"part_name" => part.name, "part_path" => part.path}
  end

  private def expected_group_summaries : Array(GroupSummary)
    aggregates = Hash(UInt64, Tuple(UInt64, UInt64, UInt64, UInt64)).new
    source_rows.each do |row|
      key = row[1]
      value = row[2]
      if current = aggregates[key]?
        count, sum, minimum, maximum = current
        aggregates[key] = {count + 1_u64, ((sum.to_u128 + value.to_u128) & UInt64::MAX.to_u128).to_u64,
                           {minimum, value}.min, {maximum, value}.max}
      else
        aggregates[key] = {1_u64, value, value, value}
      end
    end
    aggregates.keys.sort.map do |key|
      count, sum, minimum, maximum = aggregates[key]
      GroupSummary.new(key, count, sum, minimum, maximum)
    end
  end

  private def source_rows : Array(SourceRow)
    rows = [] of SourceRow
    id = 1_u64
    GROUP_KEYS.each_with_index do |group, group_index|
      remaining = GROUP_COUNTS[group_index]
      while remaining > 0_u64
        value = ((id * 37_u64) ^ ASYMMETRIC)
        value = case id
                when   1_u64 then 0_u64
                when   2_u64 then 1_u64
                when   3_u64 then UInt64::MAX
                when 132_u64 then ASYMMETRIC
                when 133_u64 then 42_u64
                when 141_u64 then ASYMMETRIC
                when 142_u64 then UInt64::MAX
                when 143_u64 then 17_u64
                else              value
                end
        rows << {id, group, value}
        id += 1_u64
        remaining -= 1_u64
      end
    end
    rows
  end

  private def expected_parent_rows : Array(ParentRow)
    source_rows.map { |row| {row[0] + 100_u64, row[1], row[2]} }
  end

  private def aggregate_value(summary : GroupSummary, name : String) : UInt64
    case name
    when "count()"    then summary.count
    when "min(value)" then summary.minimum
    when "max(value)" then summary.maximum
    when "sum(value)" then summary.sum
    else                   raise CrystalClick::UnsupportedFormatError.new("W296 unknown aggregate #{name}")
    end
  end

  private def aggregate_state(name : String, summary : GroupSummary) : Bytes
    case name
    when "count()"    then varuint(summary.count)
    when "min(value)" then minmax_state(summary.minimum)
    when "max(value)" then minmax_state(summary.maximum)
    when "sum(value)" then uint64_le(summary.sum)
    else                   raise CrystalClick::UnsupportedFormatError.new("W296 unknown aggregate #{name}")
    end
  end

  private def minmax_state(value : UInt64) : Bytes
    bytes = Bytes.new(9)
    bytes[0] = 1_u8
    encoded = uint64_le(value)
    8.times { |index| bytes[index + 1] = encoded[index] }
    bytes
  end

  private def uint64_le(value : UInt64) : Bytes
    Bytes.new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
  end

  private def varuint(value : UInt64) : Bytes
    bytes = [] of UInt8
    remaining = value
    loop do
      byte = (remaining & 0x7f_u64).to_u8
      remaining >>= 7
      bytes << (remaining.zero? ? byte : (byte | 0x80_u8))
      break if remaining.zero?
    end
    Bytes.new(bytes.size) { |index| bytes[index] }
  end

  private def target_path(catalog_root : String, uuid : String, *parts : String) : String
    File.join(catalog_root, "store", uuid[0, 3], uuid, *parts)
  end

  private def mark_count(rows : UInt64, rows_per_mark : Int32) : Int32
    ((rows - 1_u64) // rows_per_mark.to_u64 + 1_u64).to_i32
  end

  private def child_mark_rows : Array(Int32)
    Array.new((GROUP_KEYS.size - 1) // CHILD_ROWS_PER_MARK, CHILD_ROWS_PER_MARK) +
      [((GROUP_KEYS.size - 1) % CHILD_ROWS_PER_MARK + 1).to_i32]
  end

  private def expected_parent_mark_rows : Array(Int32)
    full_marks = (SOURCE_ROW_COUNT / PARENT_ROWS_PER_MARK).to_i
    tail = (SOURCE_ROW_COUNT % PARENT_ROWS_PER_MARK).to_i
    Array(Int32).new(full_marks, PARENT_ROWS_PER_MARK).tap { |rows| rows << tail if tail > 0 }
  end

  private def assert_format!(path : String, format : String, label : String, compressed : Bool) : Nil
    names = Dir.children(path)
    compact_marks = names.select { |name| name.ends_with?(".mrk4") || name.ends_with?(".cmrk4") }
    wide_marks = names.select { |name| name.ends_with?(".mrk2") || name.ends_with?(".cmrk2") }
    actual = if !compact_marks.empty? && wide_marks.empty?
               "Compact"
             elsif !wide_marks.empty? && compact_marks.empty?
               "Wide"
             else
               "ambiguous"
             end
    unless actual == format
      raise CrystalClick::CorruptPartError.new("W296 #{label} marker family was #{actual}, expected #{format}")
    end
    mark_files = format == "Compact" ? compact_marks : wide_marks
    actual_compressed = !mark_files.empty? && mark_files.all? { |name| name.includes?(".cmrk") }
    unless actual_compressed == compressed
      raise CrystalClick::CorruptPartError.new("W296 #{label} mark compression differs from the table setting")
    end
  end

  private def wide_u64(name : String, values : Array(UInt64)) : CrystalClick::WidePartColumn
    CrystalClick::WidePartColumn.binary_bulk(name, CrystalClick::BinaryDataType.primitive("UInt64"), grouped(values))
  end

  private def compact_u64(name : String, values : Array(UInt64)) : CrystalClick::CompactPartColumn
    CrystalClick::CompactPartColumn.binary_bulk(name, CrystalClick::BinaryDataType.primitive("UInt64"), grouped(values))
  end

  private def grouped(values : Array(UInt64)) : Array(Array(CrystalClick::BinaryValue))
    values.map { |value| CrystalClick::BinaryValue.uint64(value) }.each_slice(PARENT_ROWS_PER_MARK).map(&.to_a).to_a
  end

  private def parent_rows_json(rows : Array(ParentRow)) : JSON::Any
    JSON::Any.new(rows.map do |row|
      JSON::Any.new([JSON::Any.new(row[0].to_s), JSON::Any.new(row[1].to_s), JSON::Any.new(row[2].to_s)])
    end)
  end

  private def nested_u64_json(rows : Array(Array(UInt64))) : JSON::Any
    JSON::Any.new(rows.map { |row| JSON::Any.new(row.map { |value| JSON::Any.new(value.to_s) }) })
  end

  private def u64_array_json(values : Array(UInt64)) : JSON::Any
    JSON::Any.new(values.map { |value| JSON::Any.new(value.to_s) })
  end

  private def state_rows_json(rows : Hash(String, Array(UInt64))) : JSON::Any
    result = Hash(String, JSON::Any).new
    rows.each { |name, values| result[name] = JSON::Any.new(values.map { |value| JSON::Any.new(value.to_s) }) }
    JSON::Any.new(result)
  end

  private def state_hex_json(states : Hash(String, Array(String))) : JSON::Any
    result = Hash(String, JSON::Any).new
    states.each { |name, values| result[name] = JSON::Any.new(values.map { |value| JSON::Any.new(value) }) }
    JSON::Any.new(result)
  end

  private def int_array_json(values : Array(Int32)) : JSON::Any
    JSON::Any.new(values.map { |value| JSON::Any.new(value) })
  end

  private def string_array_json(values : Array(String)) : JSON::Any
    JSON::Any.new(values.map { |value| JSON::Any.new(value) })
  end

  private struct GroupSummary
    getter key : UInt64
    getter count : UInt64
    getter sum : UInt64
    getter minimum : UInt64
    getter maximum : UInt64

    def initialize(@key, @count, @sum, @minimum, @maximum)
    end
  end
end

if ARGV.size < 2 || ARGV.size > 4 || (ARGV[1] == "publish" && ARGV.size != 2) || (ARGV[1] == "reopen" && ARGV.size != 4)
  STDERR.puts "usage: materialized-view-aggregate-projection-w296-helper CATALOG_ROOT publish|reopen [WIDE_PART COMPACT_PART]"
  exit 2
end

begin
  wide_part = ARGV[2]? || MaterializedViewAggregateProjectionW296::WIDE_PART
  compact_part = ARGV[3]? || MaterializedViewAggregateProjectionW296::COMPACT_PART
  puts MaterializedViewAggregateProjectionW296.run(ARGV[0], ARGV[1], wide_part, compact_part).to_json
rescue error
  STDERR.puts "W296 helper failed: #{error.class}: #{error.message}"
  exit 1
end
