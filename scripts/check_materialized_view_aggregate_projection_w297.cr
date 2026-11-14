require "../src/crystal_click"
require "json"

# Offline half of the W297 native Compact two-key aggregate projection witness.
module MaterializedViewAggregateProjectionW297
  extend self

  FORMAT               = "materialized_view_aggregate_projection_w297_helper_v1"
  DATABASE             = "lab"
  PROJECTION           = "by_group"
  SOURCE_PART          = "all_1_1_0"
  COMPACT_PART         = "all_9_9_0"
  WIDE_PART            = "all_10_10_0"
  SOURCE_COLUMNS       = ["source_id", "key_a", "key_b", "value"]
  PARENT_COLUMNS       = ["parent_id", "key_a", "key_b", "value"]
  COMPACT_KEYS         = ["key_a", "key_b"]
  WIDE_KEYS            = ["key_b", "key_a"]
  COMPACT_AGGREGATES   = ["count()", "sum(value)", "min(value)", "max(value)"]
  WIDE_AGGREGATES      = ["sum(value)", "min(value)", "max(value)"]
  COMPACT_COLUMNS      = COMPACT_KEYS + COMPACT_AGGREGATES
  WIDE_COLUMNS         = WIDE_KEYS + WIDE_AGGREGATES
  COMPACT_TARGET_UUID  = "f2970000-7b7f-4e2f-9e44-dc13a87b8803"
  WIDE_TARGET_UUID     = "f2970000-7b7f-4e2f-9e44-dc13a87b8804"
  CHILD_ROWS_PER_MARK  =                      2
  PARENT_ROWS_PER_MARK =                      2
  WINDOW_START         =                  1_u64
  WINDOW_COUNT         =                  5_u64
  ASYMMETRIC           = 0x0102030405060708_u64

  alias Row = Tuple(UInt64, UInt64, UInt64, UInt64)
  alias ParentRow = Tuple(UInt64, UInt64, UInt64, UInt64)

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
    {19_u64, UInt64::MAX, UInt64::MAX, 0_u64},
  ] of Row

  PARENT_ROWS = SOURCE_ROWS.map { |row| {row[0] + 100_u64, row[1], row[2], row[3]} }

  def run(catalog_root : String, action : String, compact_part : String = COMPACT_PART, wide_part : String = WIDE_PART) : JSON::Any
    case action
    when "publish"
      publish(catalog_root)
    when "reopen"
      reopen(catalog_root, compact_part, wide_part)
    else
      raise ArgumentError.new("W297 action must be publish or reopen")
    end
  end

  private def publish(catalog_root : String) : JSON::Any
    catalog = CrystalClick::OfflineCatalog.open(catalog_root)
    source = catalog.table(DATABASE, "source")
    candidate = source.part_candidates.find { |part| part.name == SOURCE_PART } ||
                raise CrystalClick::InvalidPartError.new("W297 stock source part is absent")
    unless candidate.row_count == SOURCE_ROWS.size.to_u64 && source.columns.map { |column| {column.name, column.type} } == [
             {"source_id", "UInt64"}, {"key_a", "UInt64"}, {"key_b", "UInt64"}, {"value", "UInt64"},
           ]
      raise CrystalClick::CorruptPartError.new("W297 source candidate or schema differs")
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
      raise CrystalClick::InvalidPartError.new("W297 transform destination differs from resolved targets")
    end

    compact_groups = ordered_groups(:ab)
    wide_groups = ordered_groups(:ba)
    compact_index = primary_index_bytes(compact_groups.map { |item| {item[0], item[1]} })
    wide_index = primary_index_bytes(wide_groups.map { |item| {item[1], item[0]} })
    compact_actual = File.read(File.join(compact_path, "#{PROJECTION}.proj", "primary.idx"))
    wide_actual = File.read(File.join(wide_path, "#{PROJECTION}.proj", "primary.idx"))
    unless compact_actual.to_slice == compact_index && wide_actual.to_slice == wide_index
      raise CrystalClick::CorruptPartError.new("W297 generated compound primary index differs from literal key pairs")
    end

    JSON::Any.new({
      "format"                     => JSON::Any.new(FORMAT),
      "action"                     => JSON::Any.new("publish"),
      "status"                     => JSON::Any.new("ok"),
      "source_part_name"           => JSON::Any.new(SOURCE_PART),
      "source_row_count"           => JSON::Any.new(SOURCE_ROWS.size),
      "parent_rows"                => rows_json(PARENT_ROWS),
      "parent_mark_rows"           => int_array_json(parent_mark_rows),
      "child_mark_rows"            => int_array_json(child_mark_rows(compact_groups.size)),
      "compact_parent_path"        => JSON::Any.new(compact_path),
      "wide_parent_path"           => JSON::Any.new(wide_path),
      "compact_child_rows"         => nested_u64_json(compact_child_rows(compact_groups, COMPACT_AGGREGATES)),
      "wide_child_rows"            => nested_u64_json(wide_child_rows(wide_groups)),
      "compact_projection_columns" => string_array_json(COMPACT_COLUMNS),
      "wide_projection_columns"    => string_array_json(WIDE_COLUMNS),
      "compact_aggregate_order"    => string_array_json(COMPACT_AGGREGATES),
      "wide_aggregate_order"       => string_array_json(WIDE_AGGREGATES),
      "compact_primary_index_hex"  => JSON::Any.new(compact_actual.to_slice.hexstring),
      "wide_primary_index_hex"     => JSON::Any.new(wide_actual.to_slice.hexstring),
      "compact_state_hex"          => state_hex_json(compact_groups, COMPACT_AGGREGATES),
      "wide_state_hex"             => state_hex_json(wide_groups, WIDE_AGGREGATES),
      "compact_child_format"       => JSON::Any.new("Compact MRK4 compressed"),
      "wide_child_format"          => JSON::Any.new("Compact MRK4 plain"),
    } of String => JSON::Any)
  end

  private def reopen(catalog_root : String, compact_part_name : String, wide_part_name : String) : JSON::Any
    [compact_part_name, wide_part_name].each do |name|
      unless /\A[a-zA-Z0-9_-]+\z/.matches?(name) && name.includes?('_')
        raise CrystalClick::InvalidPartError.new("W297 attached part identity is malformed")
      end
    end
    catalog = CrystalClick::OfflineCatalog.open(catalog_root)
    compact = reopen_pair(catalog, catalog_root, "target_compact", compact_part_name, "Compact", COMPACT_TARGET_UUID,
      COMPACT_KEYS, COMPACT_AGGREGATES, :ab)
    wide = reopen_pair(catalog, catalog_root, "target_wide", wide_part_name, "Wide", WIDE_TARGET_UUID,
      WIDE_KEYS, WIDE_AGGREGATES, :ba)
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
    key_names : Array(String),
    aggregate_names : Array(String),
    order : Symbol,
  ) : JSON::Any
    table = catalog.table(DATABASE, table_name)
    projection = table.projections.find { |entry| entry.name == PROJECTION } ||
                 raise CrystalClick::CorruptPartError.new("W297 #{table_name} projection metadata is absent")
    expected_definition = if table_name == "target_compact"
                            "SELECT key_b, count() AS n, sum(value) AS total, min(value) AS minimum, key_a, max(value) AS maximum GROUP BY key_a, key_b"
                          else
                            "SELECT key_a, sum(value) AS total, min(value) AS minimum, key_b, max(value) AS maximum GROUP BY key_b, key_a"
                          end
    expected_parent_schema = [
      {"parent_id", "UInt64"}, {"key_a", "UInt64"}, {"key_b", "UInt64"}, {"value", "UInt64"},
    ]
    unless projection.definition.gsub(/\s+/, " ").strip == expected_definition &&
           table.columns.map { |column| {column.name, column.type} } == expected_parent_schema
      raise CrystalClick::CorruptPartError.new("W297 #{table_name} persisted schema or projection DDL differs")
    end
    candidates = table.part_candidates
    unless candidates.size == 1 && candidates.first.name == part_name && candidates.first.row_count == PARENT_ROWS.size.to_u64
      raise CrystalClick::CorruptPartError.new("W297 #{table_name} attached candidate identity/count differs")
    end
    part = candidates.first
    expected_path = target_path(catalog_root, uuid, part_name)
    unless part.path == expected_path
      raise CrystalClick::InvalidPartError.new("W297 #{table_name} candidate escaped its target directory")
    end
    child_path = File.join(part.path, "#{PROJECTION}.proj")

    parents, parent_grid, parent_identity = scan_parent(table, part, nil)
    parent_window, parent_window_grid, parent_window_identity = scan_parent(table, part, {1_u64, 5_u64})
    expected_groups = ordered_groups(order)
    expected_child = child_rows_for(expected_groups, key_names, aggregate_names)
    child, child_grid, child_identity, child_states = scan_child(table, part, key_names, aggregate_names, nil)
    child_window, child_window_grid, child_window_identity, child_window_states =
      scan_child(table, part, key_names, aggregate_names, {WINDOW_START, WINDOW_COUNT})
    key_rows, key_grid, key_identity = scan_keys(table, part, key_names, nil)
    key_window, key_window_grid, key_window_identity = scan_keys(table, part, key_names, {WINDOW_START, WINDOW_COUNT})
    state_rows, state_grid, state_identity, state_hex = scan_state_only(table, part, aggregate_names, nil)
    state_window, state_window_grid, state_window_identity, state_window_hex =
      scan_state_only(table, part, aggregate_names, {WINDOW_START, WINDOW_COUNT})

    expected_window = expected_child[1, 5]
    expected_parent_window = PARENT_ROWS[1, 5]
    expected_states = expected_state_values(expected_groups, aggregate_names)
    expected_state_window = Hash(String, Array(UInt64)).new
    expected_state_window_hex = Hash(String, Array(String)).new
    aggregate_names.each do |name|
      expected_state_window[name] = expected_states[name][1, 5]
      expected_state_window_hex[name] = state_bytes_for(expected_groups[1, 5], name)
    end
    expected_keys = expected_groups.map do |item|
      order == :ab ? [item[0], item[1]] : [item[1], item[0]]
    end
    expected_key_window = expected_keys[1, 5]
    expected_child_grid = child_mark_rows(expected_groups.size)
    unless parents == PARENT_ROWS && parent_grid == parent_mark_rows && parent_window == expected_parent_window &&
           parent_window_grid == [1, 2, 2] && child == expected_child && child_grid == expected_child_grid &&
           child_window == expected_window && child_window_grid == [1, 2, 2] &&
           key_rows == expected_keys && key_grid == expected_child_grid &&
           key_window == expected_key_window && key_window_grid == [1, 2, 2] &&
           state_rows == expected_states && state_grid == expected_child_grid && state_window == expected_state_window &&
           state_window_grid == [1, 2, 2] && child_states == state_bytes_hash(expected_groups, aggregate_names) &&
           child_window_states == expected_state_window_hex && state_hex == child_states && state_window_hex == child_window_states
      raise CrystalClick::CorruptPartError.new("W297 #{table_name} full/window parent or aggregate rows differ")
    end
    identity = {"part_name" => part.name, "part_path" => part.path}
    unless [parent_identity, parent_window_identity, child_identity, child_window_identity, key_identity,
            key_window_identity, state_identity, state_window_identity].all? { |observed| observed == identity }
      raise CrystalClick::CorruptPartError.new("W297 #{table_name} scan callback identity differs")
    end

    count_only = nil.as(Array(UInt64)?)
    count_only_window = nil.as(Array(UInt64)?)
    count_only_grid = nil.as(Array(Int32)?)
    count_only_window_grid = nil.as(Array(Int32)?)
    if aggregate_names.includes?("count()")
      count_only, count_only_grid = scan_count_only(table, part, nil)
      count_only_window, count_only_window_grid = scan_count_only(table, part, {WINDOW_START, WINDOW_COUNT})
      unless count_only == expected_states["count()"] && count_only_window == expected_state_window["count()"] &&
             count_only_grid == expected_child_grid && count_only_window_grid == [1, 2, 2]
        raise CrystalClick::CorruptPartError.new("W297 Count-only child values differ")
      end
    end

    JSON::Any.new({
      "table"                         => JSON::Any.new(table_name),
      "part_name"                     => JSON::Any.new(part.name),
      "parent_format"                 => JSON::Any.new(parent_format),
      "child_format"                  => JSON::Any.new("Compact MRK4"),
      "parent_rows"                   => rows_json(parents),
      "child_rows"                    => nested_u64_json(child),
      "child_key_rows"                => nested_u64_json(key_rows),
      "child_state_only"              => state_values_json(state_rows),
      "child_state_hex"               => state_hex_json(state_hex),
      "parent_mark_rows"              => int_array_json(parent_grid),
      "child_mark_rows"               => int_array_json(child_grid),
      "parent_window_start_1_count_5" => rows_json(parent_window),
      "child_window_start_1_count_5"  => nested_u64_json(child_window),
      "child_key_window"              => nested_u64_json(key_window),
      "child_state_window"            => state_values_json(state_window),
      "child_state_window_hex"        => state_hex_json(child_window_states),
      "parent_window_mark_rows"       => int_array_json(parent_window_grid),
      "child_window_mark_rows"        => int_array_json(child_window_grid),
      "key_only_mark_rows"            => int_array_json(key_grid),
      "key_only_window_mark_rows"     => int_array_json(key_window_grid),
      "state_only_mark_rows"          => int_array_json(state_grid),
      "state_only_window_mark_rows"   => int_array_json(state_window_grid),
      "count_only_rows"               => count_only ? u64_array_json(count_only.not_nil!) : JSON::Any.new([] of JSON::Any),
      "count_only_window"             => count_only_window ? u64_array_json(count_only_window.not_nil!) : JSON::Any.new([] of JSON::Any),
      "count_only_mark_rows"          => count_only_grid ? int_array_json(count_only_grid.not_nil!) : JSON::Any.new([] of JSON::Any),
      "count_only_window_mark_rows"   => count_only_window_grid ? int_array_json(count_only_window_grid.not_nil!) : JSON::Any.new([] of JSON::Any),
      "parent_path"                   => JSON::Any.new(part.path),
      "child_path"                    => JSON::Any.new(child_path),
      "projection_columns"            => string_array_json(key_names + aggregate_names),
      "reopen_source"                 => JSON::Any.new("byte_identical_copy_of_native_attached_part"),
    } of String => JSON::Any)
  end

  private def transform_rows(input : CrystalClick::OfflinePartTransformInput) : Array(ParentRow)
    unless input.row_count == SOURCE_ROWS.size.to_u64 && input.column_names == SOURCE_COLUMNS && input.column_types == [
             {"source_id", "UInt64"}, {"key_a", "UInt64"}, {"key_b", "UInt64"}, {"value", "UInt64"},
           ]
      raise CrystalClick::CorruptPartError.new("W297 callback source identity or schema differs")
    end
    observed = [] of Row
    output = [] of ParentRow
    input.each_batch do |batch|
      ids = batch.values_for("source_id", UInt64)
      first = batch.values_for("key_a", UInt64)
      second = batch.values_for("key_b", UInt64)
      values = batch.values_for("value", UInt64)
      unless ids.size == first.size && first.size == second.size && second.size == values.size
        raise CrystalClick::CorruptPartError.new("W297 callback source columns are not aligned")
      end
      ids.each_index do |index|
        source_row = {ids[index], first[index], second[index], values[index]}
        expected = SOURCE_ROWS[observed.size]?
        unless expected && source_row == expected
          raise CrystalClick::CorruptPartError.new("W297 source literal differs at row #{observed.size}")
        end
        observed << source_row
        output << {ids[index] + 100_u64, first[index], second[index], values[index]}
      end
    end
    unless observed == SOURCE_ROWS && output == PARENT_ROWS
      raise CrystalClick::CorruptPartError.new("W297 callback did not complete its exact parent-row transform")
    end
    output
  end

  private def compact_output(rows : Array(ParentRow)) : CrystalClick::CompactPartTransformOutput
    ids = rows.map(&.[0])
    key_a = rows.map(&.[1])
    key_b = rows.map(&.[2])
    values = rows.map(&.[3])
    groups = ordered_groups(:ab, rows)
    aggregates = aggregate_columns(groups, COMPACT_AGGREGATES)
    key_a_values = groups.map(&.[0])
    key_b_values = groups.map(&.[1])
    projection = CrystalClick::CompactPartProjection.precomputed_aggregate(
      PROJECTION, {"key_a", "key_b"},
      {key_a_values.to_unsafe.to_slice(key_a_values.size), key_b_values.to_unsafe.to_slice(key_b_values.size)},
      aggregates,
      rows_per_mark: CHILD_ROWS_PER_MARK,
      frame_bytes: 4096,
      compress_marks: true,
    )
    CrystalClick::CompactPartTransformOutput.new(
      ids.to_unsafe.to_slice(ids.size),
      [compact_u64("key_a", key_a), compact_u64("key_b", key_b), compact_u64("value", values)] of CrystalClick::CompactPartColumn,
      projections: [projection] of (CrystalClick::WidePartProjection | CrystalClick::CompactPartProjection),
    )
  end

  private def wide_output(rows : Array(ParentRow)) : CrystalClick::WidePartTransformOutput
    ids = rows.map(&.[0])
    key_a = rows.map(&.[1])
    key_b = rows.map(&.[2])
    values = rows.map(&.[3])
    groups = ordered_groups(:ba, rows)
    aggregates = aggregate_columns(groups, WIDE_AGGREGATES)
    key_b_values = groups.map(&.[1])
    key_a_values = groups.map(&.[0])
    projection = CrystalClick::CompactPartProjection.precomputed_aggregate(
      PROJECTION, {"key_b", "key_a"},
      {key_b_values.to_unsafe.to_slice(key_b_values.size), key_a_values.to_unsafe.to_slice(key_a_values.size)},
      aggregates,
      rows_per_mark: CHILD_ROWS_PER_MARK,
      frame_bytes: 4096,
      compress_marks: false,
    )
    CrystalClick::WidePartTransformOutput.new(
      ids.to_unsafe.to_slice(ids.size),
      [wide_u64("key_a", key_a), wide_u64("key_b", key_b), wide_u64("value", values)] of CrystalClick::WidePartColumn,
      projections: [projection] of (CrystalClick::WidePartProjection | CrystalClick::CompactPartProjection),
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

  private def grouped_stats(rows : Array(ParentRow)) : Hash(Tuple(UInt64, UInt64), AggregateStats)
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

  private def ordered_groups(
    order : Symbol,
    rows : Array(ParentRow) = PARENT_ROWS,
  ) : Array(Tuple(UInt64, UInt64, UInt64, UInt64, UInt64, UInt64))
    stats = grouped_stats(rows)
    keys = stats.keys
    keys = order == :ab ? keys.sort_by { |key| {key[0], key[1]} } : keys.sort_by { |key| {key[1], key[0]} }
    keys.map do |key|
      current = stats[key]
      {key[0], key[1], current.count, current.sum, current.minimum, current.maximum}
    end
  end

  private def aggregate_columns(
    groups : Array(Tuple(UInt64, UInt64, UInt64, UInt64, UInt64, UInt64)),
    names : Array(String),
  ) : Array(CrystalClick::WidePartProjectionAggregate)
    names.map do |name|
      case name
      when "count()"
        values = groups.map(&.[2])
        CrystalClick::WidePartProjectionAggregate.count(values.to_unsafe.to_slice(values.size))
      when "sum(value)"
        values = groups.map(&.[3])
        CrystalClick::WidePartProjectionAggregate.sum_uint64("value", values.to_unsafe.to_slice(values.size))
      when "min(value)"
        values = groups.map(&.[4])
        CrystalClick::WidePartProjectionAggregate.min_uint64("value", values.to_unsafe.to_slice(values.size))
      when "max(value)"
        values = groups.map(&.[5])
        CrystalClick::WidePartProjectionAggregate.max_uint64("value", values.to_unsafe.to_slice(values.size))
      else
        raise CrystalClick::UnsupportedFormatError.new("W297 unknown aggregate #{name}")
      end
    end
  end

  private def child_rows_for(
    groups : Array(Tuple(UInt64, UInt64, UInt64, UInt64, UInt64, UInt64)),
    key_names : Array(String),
    aggregate_names : Array(String),
  ) : Array(Array(UInt64))
    groups.map do |group|
      keys = if key_names == COMPACT_KEYS
               [group[0], group[1]]
             else
               [group[1], group[0]]
             end
      keys + aggregate_names.map { |name| aggregate_value(group, name) }
    end
  end

  private def compact_child_rows(
    groups : Array(Tuple(UInt64, UInt64, UInt64, UInt64, UInt64, UInt64)),
    aggregate_names : Array(String),
  ) : Array(Array(UInt64))
    child_rows_for(groups, COMPACT_KEYS, aggregate_names)
  end

  private def wide_child_rows(
    groups : Array(Tuple(UInt64, UInt64, UInt64, UInt64, UInt64, UInt64)),
  ) : Array(Array(UInt64))
    child_rows_for(groups, WIDE_KEYS, WIDE_AGGREGATES)
  end

  private def aggregate_value(group : Tuple(UInt64, UInt64, UInt64, UInt64, UInt64, UInt64), name : String) : UInt64
    case name
    when "count()"    then group[2]
    when "sum(value)" then group[3]
    when "min(value)" then group[4]
    when "max(value)" then group[5]
    else                   raise CrystalClick::UnsupportedFormatError.new("W297 unknown aggregate #{name}")
    end
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
      first = batch.values_for("key_a", UInt64)
      second = batch.values_for("key_b", UInt64)
      values = batch.values_for("value", UInt64)
      unless ids.size == first.size && first.size == second.size && second.size == values.size
        raise CrystalClick::CorruptPartError.new("W297 parent columns are not aligned")
      end
      ids.each_index { |index| rows << {ids[index], first[index], second[index], values[index]} }
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
    key_names : Array(String),
    aggregate_names : Array(String),
    window : Tuple(UInt64, UInt64)?,
  ) : {Array(Array(UInt64)), Array(Int32), Hash(String, String), Hash(String, Array(String))}
    rows = [] of Array(UInt64)
    grid = [] of Int32
    state_hex = Hash(String, Array(String)).new
    aggregate_names.each { |name| state_hex[name] = [] of String }
    identity = identity_for(part)
    callback = ->(batch : CrystalClick::WidePartTableBatch) do
      observe_identity!(identity, batch)
      keys = key_names.map { |name| batch.values_for(name, UInt64) }
      values_by_column = Hash(String, Array(UInt64)).new
      aggregate_names.each do |name|
        values, encoded = read_state_column(batch, name)
        unless values.size == keys.first.size
          raise CrystalClick::CorruptPartError.new("W297 key and #{name} state rows are not aligned")
        end
        values_by_column[name] = values
        state_hex[name].concat(encoded)
      end
      keys.first.each_index do |index|
        row = [] of UInt64
        keys.each { |column| row << column[index] }
        aggregate_names.each { |name| row << values_by_column[name][index] }
        rows << row
      end
      grid << keys.first.size.to_i32
      nil
    end
    columns = key_names + aggregate_names
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
    key_names : Array(String),
    window : Tuple(UInt64, UInt64)?,
  ) : {Array(Array(UInt64)), Array(Int32), Hash(String, String)}
    rows = [] of Array(UInt64)
    grid = [] of Int32
    identity = identity_for(part)
    callback = ->(batch : CrystalClick::WidePartTableBatch) do
      observe_identity!(identity, batch)
      keys = key_names.map { |name| batch.values_for(name, UInt64) }
      keys.first.each_index { |index| rows << keys.map { |column| column[index] } }
      grid << keys.first.size.to_i32
      nil
    end
    if range = window
      table.scan_projection_typed_window(PROJECTION, key_names, range[0], range[1], &callback)
    else
      table.scan_projection_typed(PROJECTION, key_names, batch_rows: CHILD_ROWS_PER_MARK, &callback)
    end
    {rows, grid, identity}
  end

  private def scan_state_only(
    table : CrystalClick::OfflineTable,
    part : CrystalClick::OfflinePartCandidate,
    aggregate_names : Array(String),
    window : Tuple(UInt64, UInt64)?,
  ) : {Hash(String, Array(UInt64)), Array(Int32), Hash(String, String), Hash(String, Array(String))}
    rows = Hash(String, Array(UInt64)).new
    state_hex = Hash(String, Array(String)).new
    aggregate_names.each do |name|
      rows[name] = [] of UInt64
      state_hex[name] = [] of String
    end
    grid = [] of Int32
    identity = identity_for(part)
    callback = ->(batch : CrystalClick::WidePartTableBatch) do
      observe_identity!(identity, batch)
      batch_rows = nil.as(Int32?)
      aggregate_names.each do |name|
        values, encoded = read_state_column(batch, name)
        if count = batch_rows
          unless values.size == count
            raise CrystalClick::CorruptPartError.new("W297 aggregate-only states are not aligned")
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
      table.scan_projection_typed_window(PROJECTION, aggregate_names, range[0], range[1], &callback)
    else
      table.scan_projection_typed(PROJECTION, aggregate_names, batch_rows: CHILD_ROWS_PER_MARK, &callback)
    end
    {rows, grid, identity, state_hex}
  end

  private def scan_count_only(
    table : CrystalClick::OfflineTable,
    part : CrystalClick::OfflinePartCandidate,
    window : Tuple(UInt64, UInt64)?,
  ) : {Array(UInt64), Array(Int32)}
    counts = [] of UInt64
    grid = [] of Int32
    identity = identity_for(part)
    callback = ->(batch : CrystalClick::WidePartTableBatch) do
      observe_identity!(identity, batch)
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

  private def read_state_column(batch : CrystalClick::WidePartTableBatch, name : String) : {Array(UInt64), Array(String)}
    if name == "count()"
      states = batch.aggregate_count_states_for(name, CrystalClick::BinaryDataType.aggregate_count)
      return {states.map(&.count_state).to_a, states.map { |state| varuint(state.count_state).hexstring }.to_a}
    end
    expected_type = case name
                    when "sum(value)" then "AggregateFunction(sum, UInt64)"
                    when "min(value)" then "AggregateFunction(min, UInt64)"
                    when "max(value)" then "AggregateFunction(max, UInt64)"
                    else                   raise CrystalClick::UnsupportedFormatError.new("W297 unknown state #{name}")
                    end
    values = [] of UInt64
    encoded = [] of String
    batch.binary_bulk_values_for(name).each do |state|
      bytes = state.aggregate_function_state_bytes
      if name == "sum(value)"
        unless state.type.name == expected_type && bytes.size == 8
          raise CrystalClick::CorruptPartError.new("W297 sum state nominal type or payload length differs")
        end
        values << IO::Memory.new(bytes).read_bytes(UInt64, IO::ByteFormat::LittleEndian)
      else
        unless state.type.name == expected_type && bytes.size == 9 && bytes[0] == 1_u8
          raise CrystalClick::CorruptPartError.new("W297 extremum state nominal type, presence byte, or length differs")
        end
        values << IO::Memory.new(bytes[1, 8]).read_bytes(UInt64, IO::ByteFormat::LittleEndian)
      end
      encoded << bytes.hexstring
    end
    {values, encoded}
  end

  private def observe_identity!(identity : Hash(String, String), batch : CrystalClick::WidePartTableBatch) : Nil
    unless {"part_name" => batch.part_name, "part_path" => batch.part_path} == identity
      raise CrystalClick::CorruptPartError.new("W297 callback does not identify its selected parent part")
    end
  end

  private def identity_for(part : CrystalClick::OfflinePartCandidate) : Hash(String, String)
    {"part_name" => part.name, "part_path" => part.path}
  end

  private def expected_state_values(
    groups : Array(Tuple(UInt64, UInt64, UInt64, UInt64, UInt64, UInt64)),
    names : Array(String),
  ) : Hash(String, Array(UInt64))
    names.to_h do |name|
      {name, groups.map { |group| aggregate_value(group, name) }}
    end
  end

  private def state_bytes_for(
    groups : Array(Tuple(UInt64, UInt64, UInt64, UInt64, UInt64, UInt64)),
    name : String,
  ) : Array(String)
    groups.map do |group|
      value = aggregate_value(group, name)
      case name
      when "count()"    then varuint(value).hexstring
      when "sum(value)" then u64_le(value).hexstring
      else
        io = IO::Memory.new
        io.write_byte(1_u8)
        io.write_bytes(value, IO::ByteFormat::LittleEndian)
        io.to_slice.hexstring
      end
    end
  end

  private def state_bytes_hash(
    groups : Array(Tuple(UInt64, UInt64, UInt64, UInt64, UInt64, UInt64)),
    names : Array(String),
  ) : Hash(String, Array(String))
    names.to_h { |name| {name, state_bytes_for(groups, name)} }
  end

  private def varuint(value : UInt64) : Bytes
    bytes = IO::Memory.new
    remaining = value
    loop do
      byte = (remaining & 0x7f_u64).to_u8
      remaining >>= 7
      bytes.write_byte(remaining.zero? ? byte : (byte | 0x80_u8))
      break if remaining.zero?
    end
    bytes.to_slice
  end

  private def u64_le(value : UInt64) : Bytes
    io = IO::Memory.new
    io.write_bytes(value, IO::ByteFormat::LittleEndian)
    io.to_slice
  end

  private def primary_index_bytes(keys : Array(Tuple(UInt64, UInt64))) : Bytes
    io = IO::Memory.new
    row = 0
    while row < keys.size
      io.write_bytes(keys[row][0], IO::ByteFormat::LittleEndian)
      io.write_bytes(keys[row][1], IO::ByteFormat::LittleEndian)
      row += CHILD_ROWS_PER_MARK
    end
    io.write_bytes(keys.last[0], IO::ByteFormat::LittleEndian)
    io.write_bytes(keys.last[1], IO::ByteFormat::LittleEndian)
    io.to_slice
  end

  private def child_mark_rows(group_count : Int32) : Array(Int32)
    Array.new((group_count + CHILD_ROWS_PER_MARK - 1) // CHILD_ROWS_PER_MARK) { |index|
      remaining = group_count - index * CHILD_ROWS_PER_MARK
      Math.min(remaining, CHILD_ROWS_PER_MARK).to_i32
    }
  end

  private def parent_mark_rows : Array(Int32)
    Array.new((PARENT_ROWS.size + PARENT_ROWS_PER_MARK - 1) // PARENT_ROWS_PER_MARK) { |index|
      remaining = PARENT_ROWS.size - index * PARENT_ROWS_PER_MARK
      Math.min(remaining, PARENT_ROWS_PER_MARK).to_i32
    }
  end

  private def compact_u64(name : String, values : Array(UInt64)) : CrystalClick::CompactPartColumn
    CrystalClick::CompactPartColumn.binary_bulk(name, CrystalClick::BinaryDataType.primitive("UInt64"), grouped(values))
  end

  private def wide_u64(name : String, values : Array(UInt64)) : CrystalClick::WidePartColumn
    CrystalClick::WidePartColumn.binary_bulk(name, CrystalClick::BinaryDataType.primitive("UInt64"), grouped(values))
  end

  private def grouped(values : Array(UInt64)) : Array(Array(CrystalClick::BinaryValue))
    values.map { |value| CrystalClick::BinaryValue.uint64(value) }.each_slice(PARENT_ROWS_PER_MARK).map(&.to_a).to_a
  end

  private def target_path(root : String, uuid : String, *parts : String) : String
    File.join(root, "store", uuid[0, 3], uuid, *parts)
  end

  private def rows_json(rows : Array(ParentRow)) : JSON::Any
    JSON::Any.new(rows.map { |row| JSON::Any.new(row.to_a.map { |value| JSON::Any.new(value.to_s) }) })
  end

  private def nested_u64_json(rows : Array(Array(UInt64))) : JSON::Any
    JSON::Any.new(rows.map { |row| JSON::Any.new(row.map { |value| JSON::Any.new(value.to_s) }) })
  end

  private def u64_array_json(values : Array(UInt64)) : JSON::Any
    JSON::Any.new(values.map { |value| JSON::Any.new(value.to_s) })
  end

  private def state_values_json(values : Hash(String, Array(UInt64))) : JSON::Any
    JSON::Any.new(values.to_h { |name, rows| {name, JSON::Any.new(rows.map { |value| JSON::Any.new(value.to_s) })} })
  end

  private def state_hex_json(values : Hash(String, Array(String))) : JSON::Any
    JSON::Any.new(values.to_h { |name, rows| {name, JSON::Any.new(rows.map { |value| JSON::Any.new(value) })} })
  end

  private def state_hex_json(
    groups : Array(Tuple(UInt64, UInt64, UInt64, UInt64, UInt64, UInt64)),
    names : Array(String),
  ) : JSON::Any
    state_hex_json(state_bytes_hash(groups, names))
  end

  private def int_array_json(values : Array(Int32)) : JSON::Any
    JSON::Any.new(values.map { |value| JSON::Any.new(value) })
  end

  private def string_array_json(values : Array(String)) : JSON::Any
    JSON::Any.new(values.map { |value| JSON::Any.new(value) })
  end
end

if ARGV.size < 2 || ARGV.size > 4 || (ARGV[1] == "publish" && ARGV.size != 2) || (ARGV[1] == "reopen" && ARGV.size != 4)
  STDERR.puts "usage: materialized-view-aggregate-projection-w297-helper CATALOG_ROOT publish|reopen [COMPACT_PART WIDE_PART]"
  exit 2
end

begin
  compact_part = ARGV[2]? || MaterializedViewAggregateProjectionW297::COMPACT_PART
  wide_part = ARGV[3]? || MaterializedViewAggregateProjectionW297::WIDE_PART
  puts MaterializedViewAggregateProjectionW297.run(ARGV[0], ARGV[1], compact_part, wide_part).to_json
rescue error
  STDERR.puts "W297 helper failed: #{error.class}: #{error.message}"
  exit 1
end
