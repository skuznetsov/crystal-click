require "../src/crystal_click"
require "json"

# Offline half of the W294 two-key stock-native projection witness.
module MaterializedViewAggregateProjectionW294
  extend self

  FORMAT               = "materialized_view_aggregate_projection_w294_helper_v1"
  DATABASE             = "lab"
  PROJECTION           = "by_group"
  SOURCE_PART          = "all_1_1_0"
  COMPACT_PART         = "all_9_9_0"
  WIDE_PART            = "all_10_10_0"
  SOURCE_COLUMNS       = ["source_id", "key_a", "key_b", "value"]
  PARENT_COLUMNS       = ["parent_id", "key_a", "key_b", "value"]
  COMPACT_COLUMNS      = ["key_a", "key_b", "count()", "sum(value)", "min(value)", "max(value)"]
  WIDE_COLUMNS         = ["key_b", "key_a", "count()"]
  COMPACT_TARGET_UUID  = "f2940000-7b7f-4e2f-9e44-dc13a87b8805"
  WIDE_TARGET_UUID     = "f2940000-7b7f-4e2f-9e44-dc13a87b8806"
  CHILD_ROWS_PER_MARK  =                      2
  PARENT_ROWS_PER_MARK =                      2
  ASYMMETRIC           = 0x0102030405060708_u64

  alias Row = Tuple(UInt64, UInt64, UInt64, UInt64)
  alias Group = Tuple(UInt64, UInt64, UInt64, UInt64, UInt64, UInt64)
  alias CompactChildRow = Tuple(UInt64, UInt64, UInt64, UInt64, UInt64, UInt64)
  alias WideChildRow = Tuple(UInt64, UInt64, UInt64)

  SOURCE_ROWS = [
    {1_u64, 6_u64, 10_u64, 0_u64},
    {2_u64, 6_u64, 10_u64, ASYMMETRIC},
    {3_u64, 6_u64, 10_u64, UInt64::MAX},
    {4_u64, 6_u64, 12_u64, 17_u64},
    {5_u64, 6_u64, 15_u64, 42_u64},
    {6_u64, 6_u64, 15_u64, 23_u64},
    {7_u64, 7_u64, 1_u64, 99_u64},
    {8_u64, 7_u64, 1_u64, 1_u64},
    {9_u64, 7_u64, 1_u64, 2_u64},
    {10_u64, 7_u64, 1_u64, 3_u64},
    {11_u64, 7_u64, 4_u64, ASYMMETRIC},
    {12_u64, 7_u64, 4_u64, 7_u64},
    {13_u64, 8_u64, 1_u64, 0_u64},
    {14_u64, 8_u64, 1_u64, UInt64::MAX},
    {15_u64, 8_u64, 1_u64, 8_u64},
    {16_u64, UInt64::MAX, 0_u64, ASYMMETRIC},
    {17_u64, UInt64::MAX, 0_u64, UInt64::MAX},
    {18_u64, UInt64::MAX, ASYMMETRIC, ASYMMETRIC},
  ] of Row

  EXPECTED_PARENT_ROWS = SOURCE_ROWS.map { |row| {row[0] + 100_u64, row[1], row[2], row[3]} }
  EXPECTED_GROUPS      = [
    {6_u64, 10_u64, 3_u64, ASYMMETRIC - 1_u64, 0_u64, UInt64::MAX},
    {6_u64, 12_u64, 1_u64, 17_u64, 17_u64, 17_u64},
    {6_u64, 15_u64, 2_u64, 65_u64, 23_u64, 42_u64},
    {7_u64, 1_u64, 4_u64, 105_u64, 1_u64, 99_u64},
    {7_u64, 4_u64, 2_u64, ASYMMETRIC + 7_u64, 7_u64, ASYMMETRIC},
    {8_u64, 1_u64, 3_u64, 7_u64, 0_u64, UInt64::MAX},
    {UInt64::MAX, 0_u64, 2_u64, ASYMMETRIC - 1_u64, ASYMMETRIC, UInt64::MAX},
    {UInt64::MAX, ASYMMETRIC, 1_u64, ASYMMETRIC, ASYMMETRIC, ASYMMETRIC},
  ] of Group

  def run(catalog_root : String, action : String, compact_part : String = COMPACT_PART, wide_part : String = WIDE_PART) : JSON::Any
    case action
    when "publish"
      publish(catalog_root)
    when "reopen"
      reopen(catalog_root, compact_part, wide_part)
    else
      raise ArgumentError.new("W294 action must be publish or reopen")
    end
  end

  private def publish(catalog_root : String) : JSON::Any
    catalog = CrystalClick::OfflineCatalog.open(catalog_root)
    source = catalog.table(DATABASE, "source")
    candidate = source.part_candidates.find { |part| part.name == SOURCE_PART } ||
                raise CrystalClick::InvalidPartError.new("W294 stock source part is absent")
    unless candidate.row_count == SOURCE_ROWS.size.to_u64 && source.columns.map { |column| {column.name, column.type} } == [
             {"source_id", "UInt64"}, {"key_a", "UInt64"}, {"key_b", "UInt64"}, {"value", "UInt64"},
           ]
      raise CrystalClick::CorruptPartError.new("W294 source candidate or schema differs")
    end

    compact_path = catalog.transform_materialized_view_part(
      DATABASE, "view_compact", SOURCE_PART, SOURCE_COLUMNS, COMPACT_PART,
      mark_format: CrystalClick::CompactMarkFormat::Mrk4,
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
      raise CrystalClick::InvalidPartError.new("W294 transform destination differs from resolved targets")
    end
    expected_compact_index = primary_index_bytes(EXPECTED_GROUPS.map { |row| {row[0], row[1]} })
    reverse_groups = EXPECTED_GROUPS.sort_by { |row| {row[1], row[0]} }
    expected_wide_index = primary_index_bytes(reverse_groups.map { |row| {row[1], row[0]} })
    compact_index = File.read(File.join(compact_path, "#{PROJECTION}.proj", "primary.idx"))
    wide_index = File.read(File.join(wide_path, "#{PROJECTION}.proj", "primary.idx"))
    unless compact_index.to_slice == expected_compact_index && wide_index.to_slice == expected_wide_index
      raise CrystalClick::CorruptPartError.new("W294 generated compound primary index differs from literal key tuples")
    end

    JSON::Any.new({
      "format"                     => JSON::Any.new(FORMAT),
      "action"                     => JSON::Any.new("publish"),
      "status"                     => JSON::Any.new("ok"),
      "source_part_name"           => JSON::Any.new(SOURCE_PART),
      "source_row_count"           => JSON::Any.new(SOURCE_ROWS.size),
      "parent_rows"                => rows_json(EXPECTED_PARENT_ROWS),
      "compact_child_rows"         => compact_child_rows_json(compact_child_rows(EXPECTED_GROUPS)),
      "wide_child_rows"            => wide_child_rows_json(wide_child_rows(reverse_groups)),
      "parent_columns"             => string_array_json(PARENT_COLUMNS),
      "compact_projection_columns" => string_array_json(COMPACT_COLUMNS),
      "wide_projection_columns"    => string_array_json(WIDE_COLUMNS),
      "parent_mark_rows"           => int_array_json([2, 2, 2, 2, 2, 2, 2, 2, 2]),
      "child_mark_rows"            => int_array_json([2, 2, 2, 2]),
      "compact_parent_path"        => JSON::Any.new(compact_path),
      "wide_parent_path"           => JSON::Any.new(wide_path),
      "compact_primary_index_hex"  => JSON::Any.new(compact_index.to_slice.hexstring),
      "wide_primary_index_hex"     => JSON::Any.new(wide_index.to_slice.hexstring),
      "compact_aggregate_order"    => string_array_json(["count()", "sum(value)", "min(value)", "max(value)"]),
      "wide_aggregate_order"       => string_array_json(["count()"]),
    } of String => JSON::Any)
  end

  private def reopen(catalog_root : String, compact_part_name : String, wide_part_name : String) : JSON::Any
    [compact_part_name, wide_part_name].each do |name|
      unless /\A[a-zA-Z0-9_-]+\z/.matches?(name) && name.includes?('_')
        raise CrystalClick::InvalidPartError.new("W294 attached part identity is malformed")
      end
    end
    catalog = CrystalClick::OfflineCatalog.open(catalog_root)
    compact = reopen_pair(catalog, catalog_root, "target_compact", compact_part_name, "Compact", COMPACT_TARGET_UUID, COMPACT_COLUMNS, false)
    wide = reopen_pair(catalog, catalog_root, "target_wide", wide_part_name, "Wide", WIDE_TARGET_UUID, WIDE_COLUMNS, true)
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
    reverse_keys : Bool,
  ) : JSON::Any
    table = catalog.table(DATABASE, table_name)
    projection = table.projections.find { |entry| entry.name == PROJECTION } ||
                 raise CrystalClick::CorruptPartError.new("W294 #{table_name} projection metadata is absent")
    definition = projection.definition.gsub(/\s+/, " ").strip
    expected_definition = if reverse_keys
                            "SELECT key_b, count() GROUP BY key_b, key_a"
                          else
                            "SELECT key_b, count() AS n, sum(value) AS total, min(value) AS minimum, key_a, max(value) AS maximum GROUP BY key_a, key_b"
                          end
    unless definition == expected_definition && table.columns.map { |column| {column.name, column.type} } == [
             {"parent_id", "UInt64"}, {"key_a", "UInt64"}, {"key_b", "UInt64"}, {"value", "UInt64"},
           ]
      raise CrystalClick::CorruptPartError.new("W294 #{table_name} persisted schema or aggregate DDL differs")
    end

    candidates = table.part_candidates
    unless candidates.size == 1 && candidates.first.name == part_name && candidates.first.row_count == EXPECTED_PARENT_ROWS.size.to_u64
      raise CrystalClick::CorruptPartError.new("W294 #{table_name} attached candidate identity/count differs")
    end
    part = candidates.first
    expected_path = target_path(catalog_root, uuid, part_name)
    unless part.path == expected_path
      raise CrystalClick::InvalidPartError.new("W294 #{table_name} candidate escaped its target directory")
    end
    child_path = File.join(part.path, "#{PROJECTION}.proj")
    assert_format!(part.path, parent_format, "#{table_name} parent")
    assert_format!(child_path, "Wide", "#{table_name} aggregate child")

    parent, parent_grid = scan_parent(table, nil)
    parent_window, parent_window_grid = scan_parent(table, {1_u64, 5_u64})
    expected_parent = EXPECTED_PARENT_ROWS
    if reverse_keys
      wide_expected = wide_child_rows(EXPECTED_GROUPS.sort_by { |row| {row[1], row[0]} })
      child, child_grid = scan_wide_child(table, projection_columns, nil)
      child_window, child_window_grid = scan_wide_child(table, projection_columns, {1_u64, 5_u64})
      expected_counts = wide_expected.map(&.[2])
      unless child == wide_expected && child_window == wide_expected[1, 5] &&
             child_grid == [2, 2, 2, 2] && child_window_grid == [1, 2, 2]
        raise CrystalClick::CorruptPartError.new("W294 #{table_name} full/window child values differ")
      end
      child_json = wide_child_rows_json(child)
      child_window_json = wide_child_rows_json(child_window)
    else
      compact_expected = compact_child_rows(EXPECTED_GROUPS)
      child, child_grid = scan_compact_child(table, projection_columns, nil)
      child_window, child_window_grid = scan_compact_child(table, projection_columns, {1_u64, 5_u64})
      expected_counts = compact_expected.map(&.[2])
      unless child == compact_expected && child_window == compact_expected[1, 5] &&
             child_grid == [2, 2, 2, 2] && child_window_grid == [1, 2, 2]
        raise CrystalClick::CorruptPartError.new("W294 #{table_name} full/window child values differ")
      end
      child_json = compact_child_rows_json(child)
      child_window_json = compact_child_rows_json(child_window)
    end
    count_rows, count_grid = scan_count_only(table, nil)
    count_window, count_window_grid = scan_count_only(table, {1_u64, 5_u64})
    unless count_rows == expected_counts && count_window == expected_counts[1, 5] &&
           count_grid == [2, 2, 2, 2] && count_window_grid == [1, 2, 2]
      raise CrystalClick::CorruptPartError.new("W294 #{table_name} full/window Count-only child values differ")
    end
    count_json = u64_array_json(count_rows)
    count_window_json = u64_array_json(count_window)
    unless parent == expected_parent && parent_grid == [2, 2, 2, 2, 2, 2, 2, 2, 2] &&
           parent_window == expected_parent[1, 5] && parent_window_grid == [1, 2, 2]
      raise CrystalClick::CorruptPartError.new("W294 #{table_name} full/window parent values differ")
    end

    JSON::Any.new({
      "table"                         => JSON::Any.new(table_name),
      "part_name"                     => JSON::Any.new(part.name),
      "parent_format"                 => JSON::Any.new(parent_format),
      "child_format"                  => JSON::Any.new("Wide"),
      "parent_rows"                   => rows_json(parent),
      "child_rows"                    => child_json,
      "child_count_only_rows"         => count_json,
      "parent_mark_rows"              => int_array_json(parent_grid),
      "child_mark_rows"               => int_array_json(child_grid),
      "parent_window_start_1_count_5" => rows_json(parent_window),
      "child_window_start_1_count_5"  => child_window_json,
      "child_count_only_window"       => count_window_json,
      "parent_window_mark_rows"       => int_array_json(parent_window_grid),
      "child_window_mark_rows"        => int_array_json(child_window_grid),
      "count_only_mark_rows"          => int_array_json(count_grid),
      "count_only_window_mark_rows"   => int_array_json(count_window_grid),
      "parent_path"                   => JSON::Any.new(part.path),
      "child_path"                    => JSON::Any.new(child_path),
      "projection_columns"            => string_array_json(projection_columns),
      "reopen_source"                 => JSON::Any.new("byte_identical_copy_of_native_attached_part"),
    } of String => JSON::Any)
  end

  private def transform_rows(input : CrystalClick::OfflinePartTransformInput) : Array(Row)
    unless input.row_count == SOURCE_ROWS.size.to_u64 && input.column_names == SOURCE_COLUMNS && input.column_types == [
             {"source_id", "UInt64"}, {"key_a", "UInt64"}, {"key_b", "UInt64"}, {"value", "UInt64"},
           ]
      raise CrystalClick::CorruptPartError.new("W294 callback source identity or schema differs")
    end
    observed = [] of Row
    output = [] of Row
    input.each_batch do |batch|
      ids = batch.values_for("source_id", UInt64)
      first = batch.values_for("key_a", UInt64)
      second = batch.values_for("key_b", UInt64)
      values = batch.values_for("value", UInt64)
      unless ids.size == first.size && first.size == second.size && second.size == values.size
        raise CrystalClick::CorruptPartError.new("W294 callback source columns are not aligned")
      end
      ids.each_index do |index|
        source_row = {ids[index], first[index], second[index], values[index]}
        expected = SOURCE_ROWS[observed.size]?
        unless expected && source_row == expected
          raise CrystalClick::CorruptPartError.new("W294 source literal differs at row #{observed.size}")
        end
        observed << source_row
        output << {ids[index] + 100_u64, first[index], second[index], values[index]}
      end
    end
    unless observed == SOURCE_ROWS && output == EXPECTED_PARENT_ROWS
      raise CrystalClick::CorruptPartError.new("W294 callback did not complete its exact map/rekey oracle")
    end
    output
  end

  private def compact_output(rows : Array(Row)) : CrystalClick::CompactPartTransformOutput
    ids = rows.map(&.[0])
    first = rows.map(&.[1])
    second = rows.map(&.[2])
    values = rows.map(&.[3])
    stats = grouped_stats(rows)
    ordered = stats.keys.sort_by { |key| {key[0], key[1]} }
    assert_stats!(ordered, stats, false)
    keys_a = ordered.map(&.[0])
    keys_b = ordered.map(&.[1])
    counts = ordered.map { |key| stats[key].count }
    sums = ordered.map { |key| stats[key].sum }
    mins = ordered.map { |key| stats[key].minimum }
    maxs = ordered.map { |key| stats[key].maximum }
    aggregate_columns = [
      CrystalClick::WidePartProjectionAggregate.count(counts.to_unsafe.to_slice(counts.size)),
      CrystalClick::WidePartProjectionAggregate.sum_uint64("value", sums.to_unsafe.to_slice(sums.size)),
      CrystalClick::WidePartProjectionAggregate.min_uint64("value", mins.to_unsafe.to_slice(mins.size)),
      CrystalClick::WidePartProjectionAggregate.max_uint64("value", maxs.to_unsafe.to_slice(maxs.size)),
    ]
    projection = CrystalClick::WidePartProjection.precomputed_aggregate(
      PROJECTION, {"key_a", "key_b"},
      {keys_a.to_unsafe.to_slice(keys_a.size), keys_b.to_unsafe.to_slice(keys_b.size)},
      aggregate_columns, rows_per_mark: CHILD_ROWS_PER_MARK)
    projections = [projection] of (CrystalClick::WidePartProjection | CrystalClick::CompactPartProjection)
    CrystalClick::CompactPartTransformOutput.new(
      ids.to_unsafe.to_slice(ids.size),
      [compact_u64("key_a", first), compact_u64("key_b", second), compact_u64("value", values)] of CrystalClick::CompactPartColumn,
      projections: projections,
    )
  end

  private def wide_output(rows : Array(Row)) : CrystalClick::WidePartTransformOutput
    ids = rows.map(&.[0])
    first = rows.map(&.[1])
    second = rows.map(&.[2])
    values = rows.map(&.[3])
    stats = grouped_stats(rows)
    ordered = stats.keys.sort_by { |key| {key[1], key[0]} }
    assert_stats!(ordered, stats, true)
    keys_b = ordered.map(&.[1])
    keys_a = ordered.map(&.[0])
    counts = ordered.map { |key| stats[key].count }
    aggregate_columns = [CrystalClick::WidePartProjectionAggregate.count(counts.to_unsafe.to_slice(counts.size))]
    projection = CrystalClick::WidePartProjection.precomputed_aggregate(
      PROJECTION, {"key_b", "key_a"},
      {keys_b.to_unsafe.to_slice(keys_b.size), keys_a.to_unsafe.to_slice(keys_a.size)},
      aggregate_columns, rows_per_mark: CHILD_ROWS_PER_MARK)
    projections = [projection] of (CrystalClick::WidePartProjection | CrystalClick::CompactPartProjection)
    CrystalClick::WidePartTransformOutput.new(
      ids.to_unsafe.to_slice(ids.size),
      [wide_u64("key_a", first), wide_u64("key_b", second), wide_u64("value", values)] of CrystalClick::WidePartColumn,
      projections: projections,
    )
  end

  private class AggregateStats
    getter count : UInt64
    getter sum : UInt64
    getter minimum : UInt64
    getter maximum : UInt64

    def initialize(value : UInt64)
      @count = 1_u64
      @sum = value
      @minimum = value
      @maximum = value
    end

    def add(value : UInt64) : Nil
      @count += 1_u64
      @sum = ((@sum.to_u128 + value.to_u128) & UInt64::MAX.to_u128).to_u64
      @minimum = value if value < @minimum
      @maximum = value if value > @maximum
    end
  end

  private def grouped_stats(rows : Array(Row)) : Hash(Tuple(UInt64, UInt64), AggregateStats)
    stats = Hash(Tuple(UInt64, UInt64), AggregateStats).new
    rows.each do |row|
      key = {row[1], row[2]}
      if current = stats[key]?
        current.add(row[3])
      else
        stats[key] = AggregateStats.new(row[3])
      end
    end
    stats
  end

  private def assert_stats!(ordered : Array(Tuple(UInt64, UInt64)), stats : Hash(Tuple(UInt64, UInt64), AggregateStats), reverse : Bool) : Nil
    expected = reverse ? EXPECTED_GROUPS.sort_by { |row| {row[1], row[0]} } : EXPECTED_GROUPS
    actual = ordered.map do |key|
      state = stats[key]
      {key[0], key[1], state.count, state.sum, state.minimum, state.maximum}
    end
    unless actual == expected
      raise CrystalClick::CorruptPartError.new("W294 caller aggregate oracle differs")
    end
  end

  private def compact_child_rows(groups : Array(Group)) : Array(CompactChildRow)
    groups.map { |row| {row[0], row[1], row[2], row[3], row[4], row[5]} }
  end

  private def wide_child_rows(groups : Array(Group)) : Array(WideChildRow)
    groups.map { |row| {row[1], row[0], row[2]} }
  end

  private def scan_parent(table : CrystalClick::OfflineTable, window : Tuple(UInt64, UInt64)?) : {Array(Row), Array(Int32)}
    rows = [] of Row
    grid = [] of Int32
    callback = ->(batch : CrystalClick::WidePartTableBatch) do
      ids = batch.values_for("parent_id", UInt64)
      first = batch.values_for("key_a", UInt64)
      second = batch.values_for("key_b", UInt64)
      values = batch.values_for("value", UInt64)
      ids.each_index { |index| rows << {ids[index], first[index], second[index], values[index]} }
      grid << ids.size.to_i32
      nil
    end
    if range = window
      table.scan_typed_window(PARENT_COLUMNS, range[0], range[1], &callback)
    else
      table.scan_typed(PARENT_COLUMNS, batch_rows: PARENT_ROWS_PER_MARK, &callback)
    end
    {rows, grid}
  end

  private def scan_compact_child(
    table : CrystalClick::OfflineTable,
    columns : Array(String),
    window : Tuple(UInt64, UInt64)?,
  ) : {Array(CompactChildRow), Array(Int32)}
    rows = [] of CompactChildRow
    grid = [] of Int32
    callback = ->(batch : CrystalClick::WidePartTableBatch) do
      first = batch.values_for("key_a", UInt64)
      second = batch.values_for("key_b", UInt64)
      counts = batch.aggregate_count_states_for("count()", CrystalClick::BinaryDataType.aggregate_count)
      sums = decode_u64_column(batch, "sum(value)", "AggregateFunction(sum, UInt64)")
      mins = decode_extremum_column(batch, "min(value)", "AggregateFunction(min, UInt64)")
      maxs = decode_extremum_column(batch, "max(value)", "AggregateFunction(max, UInt64)")
      unless first.size == second.size && second.size == counts.size && counts.size == sums.size && sums.size == mins.size && mins.size == maxs.size
        raise CrystalClick::CorruptPartError.new("W294 Compact aggregate child columns are not aligned")
      end
      first.each_index { |index| rows << {first[index], second[index], counts[index].count_state, sums[index], mins[index], maxs[index]} }
      grid << first.size.to_i32
      nil
    end
    if range = window
      table.scan_projection_typed_window(PROJECTION, columns, range[0], range[1], &callback)
    else
      table.scan_projection_typed(PROJECTION, columns, batch_rows: CHILD_ROWS_PER_MARK, &callback)
    end
    {rows, grid}
  end

  private def scan_wide_child(
    table : CrystalClick::OfflineTable,
    columns : Array(String),
    window : Tuple(UInt64, UInt64)?,
  ) : {Array(WideChildRow), Array(Int32)}
    rows = [] of WideChildRow
    grid = [] of Int32
    callback = ->(batch : CrystalClick::WidePartTableBatch) do
      first = batch.values_for("key_b", UInt64)
      second = batch.values_for("key_a", UInt64)
      counts = batch.aggregate_count_states_for("count()", CrystalClick::BinaryDataType.aggregate_count)
      unless first.size == second.size && second.size == counts.size
        raise CrystalClick::CorruptPartError.new("W294 Wide aggregate child columns are not aligned")
      end
      first.each_index { |index| rows << {first[index], second[index], counts[index].count_state} }
      grid << first.size.to_i32
      nil
    end
    if range = window
      table.scan_projection_typed_window(PROJECTION, columns, range[0], range[1], &callback)
    else
      table.scan_projection_typed(PROJECTION, columns, batch_rows: CHILD_ROWS_PER_MARK, &callback)
    end
    {rows, grid}
  end

  private def scan_count_only(table : CrystalClick::OfflineTable, window : Tuple(UInt64, UInt64)?) : {Array(UInt64), Array(Int32)}
    counts = [] of UInt64
    grid = [] of Int32
    callback = ->(batch : CrystalClick::WidePartTableBatch) do
      states = batch.aggregate_count_states_for("count()", CrystalClick::BinaryDataType.aggregate_count)
      states.each { |state| counts << state.count_state }
      grid << states.size.to_i32
      nil
    end
    if range = window
      table.scan_projection_typed_window(PROJECTION, ["count()"], range[0], range[1], &callback)
    else
      table.scan_projection_typed(PROJECTION, ["count()"], batch_rows: CHILD_ROWS_PER_MARK, &callback)
    end
    {counts, grid}
  end

  private def decode_u64_column(batch : CrystalClick::WidePartTableBatch, name : String, expected_type : String) : Array(UInt64)
    batch.binary_bulk_values_for(name).map do |state|
      bytes = state.aggregate_function_state_bytes
      unless state.type.name == expected_type && bytes.size == 8
        raise CrystalClick::CorruptPartError.new("W294 #{name} state nominal type or payload length differs")
      end
      IO::Memory.new(bytes).read_bytes(UInt64, IO::ByteFormat::LittleEndian)
    end.to_a
  end

  private def decode_extremum_column(batch : CrystalClick::WidePartTableBatch, name : String, expected_type : String) : Array(UInt64)
    batch.binary_bulk_values_for(name).map do |state|
      bytes = state.aggregate_function_state_bytes
      unless state.type.name == expected_type && bytes.size == 9 && bytes[0] == 1_u8
        raise CrystalClick::CorruptPartError.new("W294 #{name} state nominal type, presence byte, or payload length differs")
      end
      IO::Memory.new(bytes[1, 8]).read_bytes(UInt64, IO::ByteFormat::LittleEndian)
    end.to_a
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

  private def assert_format!(path : String, format : String, label : String) : Nil
    children = Dir.children(path)
    compact = File.file?(File.join(path, "data.mrk4"))
    wide = children.any?(&.ends_with?(".mrk2"))
    actual = if compact && !wide
               "Compact"
             elsif wide && !compact
               "Wide"
             else
               "ambiguous"
             end
    unless actual == format
      raise CrystalClick::CorruptPartError.new("W294 #{label} marker family was #{actual}, expected #{format}")
    end
  end

  private def target_path(root : String, uuid : String, *parts : String) : String
    File.join(root, "store", uuid[0, 3], uuid, *parts)
  end

  private def rows_json(rows : Array(Row)) : JSON::Any
    JSON::Any.new(rows.map do |row|
      JSON::Any.new(row.to_a.map { |value| JSON::Any.new(value.to_s) })
    end)
  end

  private def compact_child_rows_json(rows : Array(CompactChildRow)) : JSON::Any
    JSON::Any.new(rows.map { |row| JSON::Any.new(row.to_a.map { |value| JSON::Any.new(value.to_s) }) })
  end

  private def wide_child_rows_json(rows : Array(WideChildRow)) : JSON::Any
    JSON::Any.new(rows.map { |row| JSON::Any.new(row.to_a.map { |value| JSON::Any.new(value.to_s) }) })
  end

  private def u64_array_json(values : Array(UInt64)) : JSON::Any
    JSON::Any.new(values.map { |value| JSON::Any.new(value.to_s) })
  end

  private def int_array_json(values : Array(Int32)) : JSON::Any
    JSON::Any.new(values.map { |value| JSON::Any.new(value) })
  end

  private def string_array_json(values : Array(String)) : JSON::Any
    JSON::Any.new(values.map { |value| JSON::Any.new(value) })
  end

  private def primary_index_bytes(keys : Array(Tuple(UInt64, UInt64))) : Bytes
    bytes = IO::Memory.new
    row = 0
    while row < keys.size
      bytes.write_bytes(keys[row][0], IO::ByteFormat::LittleEndian)
      bytes.write_bytes(keys[row][1], IO::ByteFormat::LittleEndian)
      row += CHILD_ROWS_PER_MARK
    end
    last = keys.last
    bytes.write_bytes(last[0], IO::ByteFormat::LittleEndian)
    bytes.write_bytes(last[1], IO::ByteFormat::LittleEndian)
    bytes.to_slice
  end
end

if ARGV.size < 2 || ARGV.size > 4 || (ARGV[1] == "publish" && ARGV.size != 2) || (ARGV[1] == "reopen" && ARGV.size != 4)
  STDERR.puts "usage: materialized-view-aggregate-projection-w294-helper CATALOG_ROOT publish|reopen [COMPACT_PART WIDE_PART]"
  exit 2
end

begin
  compact_part = ARGV[2]? || MaterializedViewAggregateProjectionW294::COMPACT_PART
  wide_part = ARGV[3]? || MaterializedViewAggregateProjectionW294::WIDE_PART
  puts MaterializedViewAggregateProjectionW294.run(ARGV[0], ARGV[1], compact_part, wide_part).to_json
rescue error
  STDERR.puts "W294 helper failed: #{error.class}: #{error.message}"
  exit 1
end
