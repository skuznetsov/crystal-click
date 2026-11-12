require "../src/crystal_click"
require "json"

# W292 offline half of the pinned stock-native aggregate projection witness.
# The helper accepts only literal UInt64 sums/counts computed by this fixture;
# it never evaluates the persisted materialized-view or projection SQL.
module MaterializedViewAggregateProjectionW292
  extend self

  FORMAT               = "materialized_view_aggregate_projection_w292_helper_v1"
  DATABASE             = "lab"
  PROJECTION           = "by_group"
  SOURCE_PART          = "all_1_1_0"
  COMPACT_PART         = "all_9_9_0"
  WIDE_PART            = "all_10_10_0"
  SOURCE_COLUMNS       = ["source_id", "source_group", "value"]
  PARENT_COLUMNS       = ["parent_id", "group_key", "value"]
  COMPACT_COLUMNS      = ["group_key", "sum(value)", "count()"]
  WIDE_COLUMNS         = ["group_key", "count()", "sum(value)"]
  COMPACT_TARGET_UUID  = "f2920000-7b7f-4e2f-9e44-dc13a87b8805"
  WIDE_TARGET_UUID     = "f2920000-7b7f-4e2f-9e44-dc13a87b8806"
  CHILD_ROWS_PER_MARK  = 2
  PARENT_ROWS_PER_MARK = 2

  alias Row = Tuple(UInt64, UInt64, UInt64)

  SOURCE_ROWS = [
    {1_u64, 10_u64, UInt64::MAX},
    {2_u64, 10_u64, 1_u64},
    {3_u64, 10_u64, 0_u64},
    {4_u64, 20_u64, 0_u64},
    {5_u64, 30_u64, 42_u64},
  ] of Row
  EXPECTED_PARENT_ROWS = SOURCE_ROWS.map { |row| {row[0] + 100_u64, row[1], row[2]} }
  EXPECTED_CHILD_ROWS  = [
    {10_u64, 3_u64, 0_u64},
    {20_u64, 1_u64, 0_u64},
    {30_u64, 1_u64, 42_u64},
  ]

  def run(catalog_root : String, action : String, compact_part : String = COMPACT_PART, wide_part : String = WIDE_PART) : JSON::Any
    case action
    when "publish"
      publish(catalog_root)
    when "reopen"
      reopen(catalog_root, compact_part, wide_part)
    else
      raise ArgumentError.new("W292 action must be publish or reopen")
    end
  end

  private def publish(catalog_root : String) : JSON::Any
    catalog = CrystalClick::OfflineCatalog.open(catalog_root)
    source = catalog.table(DATABASE, "source")
    candidate = source.part_candidates.find { |part| part.name == SOURCE_PART } ||
                raise CrystalClick::InvalidPartError.new("W292 stock source part is absent")
    unless candidate.row_count == SOURCE_ROWS.size.to_u64 && source.columns.map { |column| {column.name, column.type} } == [
             {"source_id", "UInt64"}, {"source_group", "UInt64"}, {"value", "UInt64"},
           ]
      raise CrystalClick::CorruptPartError.new("W292 source candidate or schema differs")
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
      raise CrystalClick::InvalidPartError.new("W292 transform destination differs from the resolved targets")
    end

    JSON::Any.new({
      "format"                     => JSON::Any.new(FORMAT),
      "action"                     => JSON::Any.new("publish"),
      "status"                     => JSON::Any.new("ok"),
      "source_part_name"           => JSON::Any.new(SOURCE_PART),
      "source_row_count"           => JSON::Any.new(SOURCE_ROWS.size),
      "parent_rows"                => rows_json(EXPECTED_PARENT_ROWS),
      "child_rows"                 => child_rows_json(EXPECTED_CHILD_ROWS),
      "parent_columns"             => string_array_json(PARENT_COLUMNS),
      "compact_projection_columns" => string_array_json(COMPACT_COLUMNS),
      "wide_projection_columns"    => string_array_json(WIDE_COLUMNS),
      "parent_mark_rows"           => int_array_json([2, 2, 1]),
      "child_mark_rows"            => int_array_json([2, 1]),
      "compact_parent_path"        => JSON::Any.new(compact_path),
      "wide_parent_path"           => JSON::Any.new(wide_path),
      "sum_state_hex"              => string_array_json(["0000000000000000", "0000000000000000", "2a00000000000000"]),
      "count_state_varuint_hex"    => string_array_json(["03", "01", "01"]),
      "compact_aggregate_order"    => string_array_json(["sum(value)", "count()"]),
      "wide_aggregate_order"       => string_array_json(["count()", "sum(value)"]),
    } of String => JSON::Any)
  end

  private def reopen(catalog_root : String, compact_part_name : String, wide_part_name : String) : JSON::Any
    [compact_part_name, wide_part_name].each do |name|
      unless /\A[a-zA-Z0-9_-]+\z/.matches?(name) && name.includes?('_')
        raise CrystalClick::InvalidPartError.new("W292 attached part identity is malformed")
      end
    end

    catalog = CrystalClick::OfflineCatalog.open(catalog_root)
    pairs = [
      {"target_compact", compact_part_name, "Compact", COMPACT_TARGET_UUID, COMPACT_COLUMNS},
      {"target_wide", wide_part_name, "Wide", WIDE_TARGET_UUID, WIDE_COLUMNS},
    ].map do |table_name, part_name, parent_format, uuid, projection_columns|
      table = catalog.table(DATABASE, table_name)
      projection = table.projections.find { |entry| entry.name == PROJECTION } ||
                   raise CrystalClick::CorruptPartError.new("W292 #{table_name} projection metadata is absent")
      definition = projection.definition.gsub(/\s+/, " ").strip
      expected_definition = if table_name == "target_compact"
                              "SELECT sum(value) AS total, count() AS n GROUP BY group_key"
                            else
                              "SELECT group_key, count() AS n, sum(value) AS total GROUP BY group_key"
                            end
      unless definition == expected_definition && table.columns.map { |column| {column.name, column.type} } == [
               {"parent_id", "UInt64"}, {"group_key", "UInt64"}, {"value", "UInt64"},
             ]
        raise CrystalClick::CorruptPartError.new("W292 #{table_name} persisted schema or aggregate DDL differs")
      end

      candidates = table.part_candidates
      unless candidates.size == 1 && candidates.first.name == part_name && candidates.first.row_count == EXPECTED_PARENT_ROWS.size.to_u64
        raise CrystalClick::CorruptPartError.new("W292 #{table_name} attached candidate identity/count differs")
      end
      part = candidates.first
      expected_path = target_path(catalog_root, uuid, part_name)
      unless part.path == expected_path
        raise CrystalClick::InvalidPartError.new("W292 #{table_name} candidate escaped its target directory")
      end
      child_path = File.join(part.path, "#{PROJECTION}.proj")
      assert_format!(part.path, parent_format, "#{table_name} parent")
      assert_format!(child_path, "Wide", "#{table_name} aggregate child")

      parent, parent_grid = scan_parent(table, PARENT_COLUMNS, nil)
      child, child_grid = scan_child(table, projection_columns, nil)
      parent_window, parent_window_grid = scan_parent(table, PARENT_COLUMNS, 1_u64)
      child_window, child_window_grid = scan_child(table, projection_columns, 1_u64)
      unless parent == EXPECTED_PARENT_ROWS && child == EXPECTED_CHILD_ROWS &&
             parent_grid == [2, 2, 1] && child_grid == [2, 1] &&
             parent_window == EXPECTED_PARENT_ROWS[1, 3] && parent_window_grid == [1, 2] &&
             child_window == EXPECTED_CHILD_ROWS[1, 2] &&
             child_window_grid == [1, 1]
        raise CrystalClick::CorruptPartError.new("W292 #{table_name} full/window parent or child values differ")
      end

      JSON::Any.new({
        "table"                         => JSON::Any.new(table_name),
        "part_name"                     => JSON::Any.new(part.name),
        "parent_format"                 => JSON::Any.new(parent_format),
        "child_format"                  => JSON::Any.new("Wide"),
        "parent_rows"                   => rows_json(parent),
        "child_rows"                    => child_rows_json(EXPECTED_CHILD_ROWS),
        "parent_mark_rows"              => int_array_json(parent_grid),
        "child_mark_rows"               => int_array_json(child_grid),
        "parent_window_start_1_count_3" => rows_json(parent_window),
        "child_window_start_1_count_2"  => child_rows_json(EXPECTED_CHILD_ROWS[1, 2]),
        "parent_window_mark_rows"       => int_array_json(parent_window_grid),
        "child_window_mark_rows"        => int_array_json(child_window_grid),
        "parent_path"                   => JSON::Any.new(part.path),
        "child_path"                    => JSON::Any.new(child_path),
        "projection_columns"            => string_array_json(projection_columns),
        "reopen_source"                 => JSON::Any.new("byte_identical_copy_of_native_attached_part"),
      } of String => JSON::Any)
    end

    JSON::Any.new({
      "format"       => JSON::Any.new(FORMAT),
      "action"       => JSON::Any.new("reopen"),
      "status"       => JSON::Any.new("ok"),
      "catalog_root" => JSON::Any.new(catalog.root),
      "pairs"        => JSON::Any.new(pairs),
    } of String => JSON::Any)
  end

  private def transform_rows(input : CrystalClick::OfflinePartTransformInput) : Array(Row)
    unless input.row_count == SOURCE_ROWS.size.to_u64 && input.column_names == SOURCE_COLUMNS &&
           input.column_types == [{"source_id", "UInt64"}, {"source_group", "UInt64"}, {"value", "UInt64"}]
      raise CrystalClick::CorruptPartError.new("W292 callback source identity or schema differs")
    end
    observed = [] of Row
    output = [] of Row
    input.each_batch do |batch|
      ids = batch.values_for("source_id", UInt64)
      groups = batch.values_for("source_group", UInt64)
      values = batch.values_for("value", UInt64)
      unless ids.size == groups.size && groups.size == values.size
        raise CrystalClick::CorruptPartError.new("W292 callback source columns are not aligned")
      end
      ids.each_index do |index|
        source_row = {ids[index], groups[index], values[index]}
        expected = SOURCE_ROWS[observed.size]?
        unless expected && source_row == expected
          raise CrystalClick::CorruptPartError.new("W292 source literal differs at row #{observed.size}")
        end
        observed << source_row
        output << {ids[index] + 100_u64, groups[index], values[index]}
      end
    end
    unless observed == SOURCE_ROWS && output == EXPECTED_PARENT_ROWS
      raise CrystalClick::CorruptPartError.new("W292 callback did not complete its exact map/rekey oracle")
    end
    output
  end

  private def compact_output(rows : Array(Row)) : CrystalClick::CompactPartTransformOutput
    keys = rows.map(&.[0])
    values = rows.map(&.[2])
    groups = rows.map(&.[1])
    aggregate_keys, aggregate_columns = projection_aggregates(rows, sum_first: true)
    projection = CrystalClick::WidePartProjection.precomputed_aggregate(
      PROJECTION, "group_key", aggregate_keys.to_unsafe.to_slice(aggregate_keys.size), aggregate_columns,
      rows_per_mark: CHILD_ROWS_PER_MARK,
    )
    projections = [projection] of (CrystalClick::WidePartProjection | CrystalClick::CompactPartProjection)
    CrystalClick::CompactPartTransformOutput.new(
      keys.to_unsafe.to_slice(keys.size),
      [compact_u64("group_key", groups), compact_u64("value", values)] of CrystalClick::CompactPartColumn,
      projections: projections,
    )
  end

  private def wide_output(rows : Array(Row)) : CrystalClick::WidePartTransformOutput
    keys = rows.map(&.[0])
    values = rows.map(&.[2])
    groups = rows.map(&.[1])
    aggregate_keys, aggregate_columns = projection_aggregates(rows, sum_first: false)
    projection = CrystalClick::WidePartProjection.precomputed_aggregate(
      PROJECTION, "group_key", aggregate_keys.to_unsafe.to_slice(aggregate_keys.size), aggregate_columns,
      rows_per_mark: CHILD_ROWS_PER_MARK,
    )
    projections = [projection] of (CrystalClick::WidePartProjection | CrystalClick::CompactPartProjection)
    CrystalClick::WidePartTransformOutput.new(
      keys.to_unsafe.to_slice(keys.size),
      [wide_u64("group_key", groups), wide_u64("value", values)] of CrystalClick::WidePartColumn,
      projections: projections,
    )
  end

  private def projection_aggregates(rows : Array(Row), sum_first : Bool) : {Array(UInt64), Array(CrystalClick::WidePartProjectionAggregate)}
    counts = Hash(UInt64, UInt64).new(0_u64)
    sums = Hash(UInt64, UInt64).new(0_u64)
    rows.each do |row|
      group = row[1]
      counts[group] += 1_u64
      sums[group] = ((sums[group].to_u128 + row[2].to_u128) & UInt64::MAX.to_u128).to_u64
    end
    keys = counts.keys.sort
    count_values = keys.map { |key| counts[key] }
    sum_values = keys.map { |key| sums[key] }
    unless keys == [10_u64, 20_u64, 30_u64] && count_values == [3_u64, 1_u64, 1_u64] && sum_values == [0_u64, 0_u64, 42_u64]
      raise CrystalClick::CorruptPartError.new("W292 caller aggregate oracle differs")
    end
    count = CrystalClick::WidePartProjectionAggregate.count(count_values.to_unsafe.to_slice(count_values.size))
    sum = CrystalClick::WidePartProjectionAggregate.sum_uint64("value", sum_values.to_unsafe.to_slice(sum_values.size))
    aggregates = sum_first ? [sum, count] : [count, sum]
    {keys, aggregates}
  end

  private def scan_parent(
    table : CrystalClick::OfflineTable,
    columns : Array(String),
    start_row : UInt64?,
  ) : {Array(Row), Array(Int32)}
    rows = [] of Row
    grid = [] of Int32
    callback = ->(batch : CrystalClick::WidePartTableBatch) do
      ids = batch.values_for("parent_id", UInt64)
      groups = batch.values_for("group_key", UInt64)
      values = batch.values_for("value", UInt64)
      ids.each_index { |index| rows << {ids[index], groups[index], values[index]} }
      grid << ids.size.to_i32
      nil
    end
    if first = start_row
      table.scan_typed_window(columns, first, 3, &callback)
    else
      table.scan_typed(columns, batch_rows: 2, &callback)
    end
    {rows, grid}
  end

  private def scan_child(
    table : CrystalClick::OfflineTable,
    columns : Array(String),
    start_row : UInt64?,
  ) : {Array(Tuple(UInt64, UInt64, UInt64)), Array(Int32)}
    rows = [] of Tuple(UInt64, UInt64, UInt64)
    grid = [] of Int32
    callback = ->(batch : CrystalClick::WidePartTableBatch) do
      keys = batch.values_for("group_key", UInt64)
      counts = batch.aggregate_count_states_for("count()", CrystalClick::BinaryDataType.aggregate_count)
      sums = batch.binary_bulk_values_for("sum(value)")
      unless keys.size == counts.size && keys.size == sums.size
        raise CrystalClick::CorruptPartError.new("W292 aggregate child columns are not aligned")
      end
      keys.each_index do |index|
        state = sums[index]
        unless state.type.name == "AggregateFunction(sum, UInt64)" && state.aggregate_function_state_bytes.size == 8
          raise CrystalClick::CorruptPartError.new("W292 Sum state nominal type or fixed payload length differs")
        end
        value = IO::Memory.new(state.aggregate_function_state_bytes).read_bytes(UInt64, IO::ByteFormat::LittleEndian)
        rows << {keys[index], counts[index].count_state, value}
      end
      grid << keys.size.to_i32
      nil
    end
    projection_columns = ["group_key", "count()", "sum(value)"]
    if first = start_row
      table.scan_projection_typed_window(PROJECTION, projection_columns, first, 2, &callback)
    else
      table.scan_projection_typed(PROJECTION, projection_columns, batch_rows: 2, &callback)
    end
    {rows, grid}
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
      raise CrystalClick::CorruptPartError.new("W292 #{label} marker family was #{actual}, expected #{format}")
    end
  end

  private def target_path(root : String, uuid : String, *parts : String) : String
    File.join(root, "store", uuid[0, 3], uuid, *parts)
  end

  private def rows_json(rows : Array(Row)) : JSON::Any
    JSON::Any.new(rows.map do |row|
      # Encode the UInt64 payload as decimal text so UInt64::MAX stays exact
      # across JSON implementations that expose only signed integer values.
      JSON::Any.new([JSON::Any.new(row[0].to_i64), JSON::Any.new(row[1].to_i64), JSON::Any.new(row[2].to_s)])
    end)
  end

  private def child_rows_json(rows : Array(Tuple(UInt64, UInt64, UInt64))) : JSON::Any
    JSON::Any.new(rows.map do |key, count, sum|
      JSON::Any.new([JSON::Any.new(key.to_i64), JSON::Any.new(count.to_i64), JSON::Any.new(sum.to_i64)])
    end)
  end

  private def int_array_json(values : Array(Int32)) : JSON::Any
    JSON::Any.new(values.map { |value| JSON::Any.new(value) })
  end

  private def string_array_json(values : Array(String)) : JSON::Any
    JSON::Any.new(values.map { |value| JSON::Any.new(value) })
  end
end

if ARGV.size < 2 || ARGV.size > 4 || (ARGV[1] == "publish" && ARGV.size != 2) || (ARGV[1] == "reopen" && ARGV.size != 4)
  STDERR.puts "usage: materialized-view-aggregate-projection-w292-helper CATALOG_ROOT publish|reopen [COMPACT_PART WIDE_PART]"
  exit 2
end

begin
  compact_part = ARGV[2]? || MaterializedViewAggregateProjectionW292::COMPACT_PART
  wide_part = ARGV[3]? || MaterializedViewAggregateProjectionW292::WIDE_PART
  puts MaterializedViewAggregateProjectionW292.run(ARGV[0], ARGV[1], compact_part, wide_part).to_json
rescue error
  STDERR.puts "W292 helper failed: #{error.class}: #{error.message}"
  exit 1
end
