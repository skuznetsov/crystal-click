require "../src/crystal_click"
require "json"

# Offline half of the W293 stock-native min/max projection witness.
# Every aggregate below is computed from the literal callback rows; this
# helper never evaluates persisted materialized-view or projection SQL.
module MaterializedViewAggregateProjectionW293
  extend self

  FORMAT               = "materialized_view_aggregate_projection_w293_helper_v1"
  DATABASE             = "lab"
  PROJECTION           = "by_group"
  SOURCE_PART          = "all_1_1_0"
  COMPACT_PART         = "all_9_9_0"
  WIDE_PART            = "all_10_10_0"
  SOURCE_COLUMNS       = ["source_id", "source_group", "value"]
  PARENT_COLUMNS       = ["parent_id", "group_key", "value"]
  COMPACT_COLUMNS      = ["group_key", "min(value)", "max(value)"]
  WIDE_COLUMNS         = ["group_key", "max(value)", "count()", "min(value)", "sum(value)"]
  COMPACT_TARGET_UUID  = "f2930000-7b7f-4e2f-9e44-dc13a87b8805"
  WIDE_TARGET_UUID     = "f2930000-7b7f-4e2f-9e44-dc13a87b8806"
  CHILD_ROWS_PER_MARK  =                      2
  PARENT_ROWS_PER_MARK =                      2
  ASYMMETRIC           = 0x0102030405060708_u64

  alias Row = Tuple(UInt64, UInt64, UInt64)
  alias ChildRow = Tuple(UInt64, UInt64, UInt64, UInt64, UInt64)

  SOURCE_ROWS = [
    {1_u64, 10_u64, 0_u64},
    {2_u64, 10_u64, 1_u64},
    {3_u64, 10_u64, UInt64::MAX},
    {4_u64, 20_u64, ASYMMETRIC},
    {5_u64, 20_u64, 17_u64},
    {6_u64, 20_u64, 23_u64},
    {7_u64, 30_u64, 42_u64},
    {8_u64, 20_u64, 99_u64},
    {9_u64, 30_u64, ASYMMETRIC},
  ] of Row
  EXPECTED_PARENT_ROWS  = SOURCE_ROWS.map { |row| {row[0] + 100_u64, row[1], row[2]} }
  EXPECTED_KEYS         = [10_u64, 20_u64, 30_u64]
  EXPECTED_MINS         = [0_u64, 17_u64, 42_u64]
  EXPECTED_MAXS         = [UInt64::MAX, ASYMMETRIC, ASYMMETRIC]
  EXPECTED_COUNTS       = [3_u64, 4_u64, 2_u64]
  EXPECTED_SUMS         = [0_u64, ASYMMETRIC + 139_u64, ASYMMETRIC + 42_u64]
  EXPECTED_COMPACT_ROWS = EXPECTED_KEYS.each_index.map do |index|
    {EXPECTED_KEYS[index], EXPECTED_MINS[index], EXPECTED_MAXS[index], 0_u64, 0_u64}
  end.to_a
  EXPECTED_WIDE_ROWS = EXPECTED_KEYS.each_index.map do |index|
    {EXPECTED_KEYS[index], EXPECTED_MINS[index], EXPECTED_MAXS[index], EXPECTED_COUNTS[index], EXPECTED_SUMS[index]}
  end.to_a

  def run(catalog_root : String, action : String, compact_part : String = COMPACT_PART, wide_part : String = WIDE_PART) : JSON::Any
    case action
    when "publish"
      publish(catalog_root)
    when "reopen"
      reopen(catalog_root, compact_part, wide_part)
    else
      raise ArgumentError.new("W293 action must be publish or reopen")
    end
  end

  private def publish(catalog_root : String) : JSON::Any
    catalog = CrystalClick::OfflineCatalog.open(catalog_root)
    source = catalog.table(DATABASE, "source")
    candidate = source.part_candidates.find { |part| part.name == SOURCE_PART } ||
                raise CrystalClick::InvalidPartError.new("W293 stock source part is absent")
    unless candidate.row_count == SOURCE_ROWS.size.to_u64 && source.columns.map { |column| {column.name, column.type} } == [
             {"source_id", "UInt64"}, {"source_group", "UInt64"}, {"value", "UInt64"},
           ]
      raise CrystalClick::CorruptPartError.new("W293 source candidate or schema differs")
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
      raise CrystalClick::InvalidPartError.new("W293 transform destination differs from the resolved targets")
    end

    JSON::Any.new({
      "format"                     => JSON::Any.new(FORMAT),
      "action"                     => JSON::Any.new("publish"),
      "status"                     => JSON::Any.new("ok"),
      "source_part_name"           => JSON::Any.new(SOURCE_PART),
      "source_row_count"           => JSON::Any.new(SOURCE_ROWS.size),
      "parent_rows"                => rows_json(EXPECTED_PARENT_ROWS),
      "compact_child_rows"         => compact_rows_json(EXPECTED_COMPACT_ROWS),
      "wide_child_rows"            => wide_rows_json(EXPECTED_WIDE_ROWS),
      "parent_columns"             => string_array_json(PARENT_COLUMNS),
      "compact_projection_columns" => string_array_json(COMPACT_COLUMNS),
      "wide_projection_columns"    => string_array_json(WIDE_COLUMNS),
      "parent_mark_rows"           => int_array_json([2, 2, 2, 2, 1]),
      "child_mark_rows"            => int_array_json([2, 1]),
      "compact_parent_path"        => JSON::Any.new(compact_path),
      "wide_parent_path"           => JSON::Any.new(wide_path),
      "min_state_hex"              => string_array_json(EXPECTED_MINS.map { |value| minmax_state(value).hexstring }),
      "max_state_hex"              => string_array_json(EXPECTED_MAXS.map { |value| minmax_state(value).hexstring }),
      "sum_state_hex"              => string_array_json(EXPECTED_SUMS.map { |value| uint64_le(value).hexstring }),
      "count_state_varuint_hex"    => string_array_json(EXPECTED_COUNTS.map { |value| varuint(value).hexstring }),
      "compact_aggregate_order"    => string_array_json(["min(value)", "max(value)"]),
      "wide_aggregate_order"       => string_array_json(["max(value)", "count()", "min(value)", "sum(value)"]),
    } of String => JSON::Any)
  end

  private def reopen(catalog_root : String, compact_part_name : String, wide_part_name : String) : JSON::Any
    [compact_part_name, wide_part_name].each do |name|
      unless /\A[a-zA-Z0-9_-]+\z/.matches?(name) && name.includes?('_')
        raise CrystalClick::InvalidPartError.new("W293 attached part identity is malformed")
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
    wide_aggregates : Bool,
  ) : JSON::Any
    table = catalog.table(DATABASE, table_name)
    projection = table.projections.find { |entry| entry.name == PROJECTION } ||
                 raise CrystalClick::CorruptPartError.new("W293 #{table_name} projection metadata is absent")
    definition = projection.definition.gsub(/\s+/, " ").strip
    expected_definition = if wide_aggregates
                            "SELECT group_key, max(value) AS maximum, count() AS n, min(value) AS minimum, sum(value) AS total GROUP BY group_key"
                          else
                            "SELECT min(value) AS minimum, max(value) AS maximum GROUP BY group_key"
                          end
    unless definition == expected_definition && table.columns.map { |column| {column.name, column.type} } == [
             {"parent_id", "UInt64"}, {"group_key", "UInt64"}, {"value", "UInt64"},
           ]
      raise CrystalClick::CorruptPartError.new("W293 #{table_name} persisted schema or aggregate DDL differs")
    end

    candidates = table.part_candidates
    unless candidates.size == 1 && candidates.first.name == part_name && candidates.first.row_count == EXPECTED_PARENT_ROWS.size.to_u64
      raise CrystalClick::CorruptPartError.new("W293 #{table_name} attached candidate identity/count differs")
    end
    part = candidates.first
    expected_path = target_path(catalog_root, uuid, part_name)
    unless part.path == expected_path
      raise CrystalClick::InvalidPartError.new("W293 #{table_name} candidate escaped its target directory")
    end
    child_path = File.join(part.path, "#{PROJECTION}.proj")
    assert_format!(part.path, parent_format, "#{table_name} parent")
    assert_format!(child_path, "Wide", "#{table_name} aggregate child")

    expected_children = wide_aggregates ? EXPECTED_WIDE_ROWS : EXPECTED_COMPACT_ROWS
    parent, parent_grid = scan_parent(table, PARENT_COLUMNS, nil)
    child, child_grid = scan_child(table, projection_columns, nil, wide_aggregates)
    parent_window, parent_window_grid = scan_parent(table, PARENT_COLUMNS, 1_u64)
    child_window, child_window_grid = scan_child(table, projection_columns, 1_u64, wide_aggregates)
    unless parent == EXPECTED_PARENT_ROWS && child == expected_children &&
           parent_grid == [2, 2, 2, 2, 1] && child_grid == [2, 1] &&
           parent_window == EXPECTED_PARENT_ROWS[1, 5] && parent_window_grid == [1, 2, 2] &&
           child_window == expected_children[1, 2] && child_window_grid == [1, 1]
      raise CrystalClick::CorruptPartError.new("W293 #{table_name} full/window parent or child values differ")
    end

    JSON::Any.new({
      "table"                         => JSON::Any.new(table_name),
      "part_name"                     => JSON::Any.new(part.name),
      "parent_format"                 => JSON::Any.new(parent_format),
      "child_format"                  => JSON::Any.new("Wide"),
      "parent_rows"                   => rows_json(parent),
      "child_rows"                    => wide_aggregates ? wide_rows_json(child) : compact_rows_json(child),
      "parent_mark_rows"              => int_array_json(parent_grid),
      "child_mark_rows"               => int_array_json(child_grid),
      "parent_window_start_1_count_5" => rows_json(parent_window),
      "child_window_start_1_count_2"  => wide_aggregates ? wide_rows_json(child_window) : compact_rows_json(child_window),
      "parent_window_mark_rows"       => int_array_json(parent_window_grid),
      "child_window_mark_rows"        => int_array_json(child_window_grid),
      "parent_path"                   => JSON::Any.new(part.path),
      "child_path"                    => JSON::Any.new(child_path),
      "projection_columns"            => string_array_json(projection_columns),
      "reopen_source"                 => JSON::Any.new("byte_identical_copy_of_native_attached_part"),
    } of String => JSON::Any)
  end

  private def transform_rows(input : CrystalClick::OfflinePartTransformInput) : Array(Row)
    unless input.row_count == SOURCE_ROWS.size.to_u64 && input.column_names == SOURCE_COLUMNS &&
           input.column_types == [{"source_id", "UInt64"}, {"source_group", "UInt64"}, {"value", "UInt64"}]
      raise CrystalClick::CorruptPartError.new("W293 callback source identity or schema differs")
    end
    observed = [] of Row
    output = [] of Row
    input.each_batch do |batch|
      ids = batch.values_for("source_id", UInt64)
      groups = batch.values_for("source_group", UInt64)
      values = batch.values_for("value", UInt64)
      unless ids.size == groups.size && groups.size == values.size
        raise CrystalClick::CorruptPartError.new("W293 callback source columns are not aligned")
      end
      ids.each_index do |index|
        source_row = {ids[index], groups[index], values[index]}
        expected = SOURCE_ROWS[observed.size]?
        unless expected && source_row == expected
          raise CrystalClick::CorruptPartError.new("W293 source literal differs at row #{observed.size}")
        end
        observed << source_row
        output << {ids[index] + 100_u64, groups[index], values[index]}
      end
    end
    unless observed == SOURCE_ROWS && output == EXPECTED_PARENT_ROWS
      raise CrystalClick::CorruptPartError.new("W293 callback did not complete its exact map/rekey oracle")
    end
    output
  end

  private def compact_output(rows : Array(Row)) : CrystalClick::CompactPartTransformOutput
    keys = rows.map(&.[0])
    values = rows.map(&.[2])
    groups = rows.map(&.[1])
    aggregate_keys, aggregate_columns = projection_aggregates(rows)
    projection = CrystalClick::WidePartProjection.precomputed_aggregate(
      PROJECTION, "group_key", aggregate_keys.to_unsafe.to_slice(aggregate_keys.size), [aggregate_columns[0], aggregate_columns[1]],
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
    aggregate_keys, aggregate_columns = projection_aggregates(rows)
    ordered_columns = [aggregate_columns[1], aggregate_columns[2], aggregate_columns[0], aggregate_columns[3]]
    projection = CrystalClick::WidePartProjection.precomputed_aggregate(
      PROJECTION, "group_key", aggregate_keys.to_unsafe.to_slice(aggregate_keys.size), ordered_columns,
      rows_per_mark: CHILD_ROWS_PER_MARK,
    )
    projections = [projection] of (CrystalClick::WidePartProjection | CrystalClick::CompactPartProjection)
    CrystalClick::WidePartTransformOutput.new(
      keys.to_unsafe.to_slice(keys.size),
      [wide_u64("group_key", groups), wide_u64("value", values)] of CrystalClick::WidePartColumn,
      projections: projections,
    )
  end

  private def projection_aggregates(rows : Array(Row)) : {Array(UInt64), Array(CrystalClick::WidePartProjectionAggregate)}
    counts = Hash(UInt64, UInt64).new(0_u64)
    sums = Hash(UInt64, UInt64).new(0_u64)
    mins = Hash(UInt64, UInt64).new
    maxs = Hash(UInt64, UInt64).new
    rows.each do |row|
      group = row[1]
      value = row[2]
      counts[group] += 1_u64
      sums[group] = ((sums[group].to_u128 + value.to_u128) & UInt64::MAX.to_u128).to_u64
      if minimum = mins[group]?
        mins[group] = value if value < minimum
      else
        mins[group] = value
      end
      if maximum = maxs[group]?
        maxs[group] = value if value > maximum
      else
        maxs[group] = value
      end
    end
    keys = counts.keys.sort
    count_values = keys.map { |key| counts[key] }
    sum_values = keys.map { |key| sums[key] }
    min_values = keys.map { |key| mins[key] }
    max_values = keys.map { |key| maxs[key] }
    unless keys == EXPECTED_KEYS && count_values == EXPECTED_COUNTS && sum_values == EXPECTED_SUMS &&
           min_values == EXPECTED_MINS && max_values == EXPECTED_MAXS
      raise CrystalClick::CorruptPartError.new("W293 caller aggregate oracle differs")
    end

    count = CrystalClick::WidePartProjectionAggregate.count(count_values.to_unsafe.to_slice(count_values.size))
    sum = CrystalClick::WidePartProjectionAggregate.sum_uint64("value", sum_values.to_unsafe.to_slice(sum_values.size))
    minimum = CrystalClick::WidePartProjectionAggregate.min_uint64("value", min_values.to_unsafe.to_slice(min_values.size))
    maximum = CrystalClick::WidePartProjectionAggregate.max_uint64("value", max_values.to_unsafe.to_slice(max_values.size))
    # Return canonical aggregates; each parent supplies its own declared order.
    {keys, [minimum, maximum, count, sum]}
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
      table.scan_typed_window(columns, first, 5, &callback)
    else
      table.scan_typed(columns, batch_rows: PARENT_ROWS_PER_MARK, &callback)
    end
    {rows, grid}
  end

  private def scan_child(
    table : CrystalClick::OfflineTable,
    columns : Array(String),
    start_row : UInt64?,
    wide_aggregates : Bool,
  ) : {Array(ChildRow), Array(Int32)}
    rows = [] of ChildRow
    grid = [] of Int32
    callback = ->(batch : CrystalClick::WidePartTableBatch) do
      keys = batch.values_for("group_key", UInt64)
      mins = decode_minmax_column(batch, "min(value)", "AggregateFunction(min, UInt64)")
      maxs = decode_minmax_column(batch, "max(value)", "AggregateFunction(max, UInt64)")
      if wide_aggregates
        counts = batch.aggregate_count_states_for("count()", CrystalClick::BinaryDataType.aggregate_count)
        sums = decode_sum_column(batch)
        unless keys.size == mins.size && mins.size == maxs.size && maxs.size == counts.size && counts.size == sums.size
          raise CrystalClick::CorruptPartError.new("W293 Wide aggregate child columns are not aligned")
        end
        keys.each_index do |index|
          rows << {keys[index], mins[index], maxs[index], counts[index].count_state, sums[index]}
        end
      else
        unless keys.size == mins.size && mins.size == maxs.size
          raise CrystalClick::CorruptPartError.new("W293 Compact aggregate child columns are not aligned")
        end
        keys.each_index do |index|
          rows << {keys[index], mins[index], maxs[index], 0_u64, 0_u64}
        end
      end
      grid << keys.size.to_i32
      nil
    end
    if first = start_row
      table.scan_projection_typed_window(PROJECTION, columns, first, 2, &callback)
    else
      table.scan_projection_typed(PROJECTION, columns, batch_rows: CHILD_ROWS_PER_MARK, &callback)
    end
    {rows, grid}
  end

  private def decode_minmax_column(batch : CrystalClick::WidePartTableBatch, name : String, expected_type : String) : Array(UInt64)
    batch.binary_bulk_values_for(name).map do |state|
      bytes = state.aggregate_function_state_bytes
      unless state.type.name == expected_type && bytes.size == 9 && bytes[0] == 1_u8
        raise CrystalClick::CorruptPartError.new("W293 #{name} state nominal type, presence byte, or payload length differs")
      end
      IO::Memory.new(bytes[1, 8]).read_bytes(UInt64, IO::ByteFormat::LittleEndian)
    end.to_a
  end

  private def decode_sum_column(batch : CrystalClick::WidePartTableBatch) : Array(UInt64)
    batch.binary_bulk_values_for("sum(value)").map do |state|
      bytes = state.aggregate_function_state_bytes
      unless state.type.name == "AggregateFunction(sum, UInt64)" && bytes.size == 8
        raise CrystalClick::CorruptPartError.new("W293 sum state nominal type or fixed payload length differs")
      end
      IO::Memory.new(bytes).read_bytes(UInt64, IO::ByteFormat::LittleEndian)
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
      raise CrystalClick::CorruptPartError.new("W293 #{label} marker family was #{actual}, expected #{format}")
    end
  end

  private def target_path(root : String, uuid : String, *parts : String) : String
    File.join(root, "store", uuid[0, 3], uuid, *parts)
  end

  private def rows_json(rows : Array(Row)) : JSON::Any
    JSON::Any.new(rows.map do |row|
      # Decimal text keeps UInt64::MAX exact across signed JSON integer APIs.
      JSON::Any.new([JSON::Any.new(row[0].to_i64), JSON::Any.new(row[1].to_i64), JSON::Any.new(row[2].to_s)])
    end)
  end

  private def compact_rows_json(rows : Array(ChildRow)) : JSON::Any
    JSON::Any.new(rows.map do |row|
      JSON::Any.new([JSON::Any.new(row[0].to_i64), JSON::Any.new(row[1].to_s), JSON::Any.new(row[2].to_s)])
    end)
  end

  private def wide_rows_json(rows : Array(ChildRow)) : JSON::Any
    JSON::Any.new(rows.map do |row|
      JSON::Any.new([
        JSON::Any.new(row[0].to_i64), JSON::Any.new(row[2].to_s), JSON::Any.new(row[3].to_i64),
        JSON::Any.new(row[1].to_s), JSON::Any.new(row[4].to_s),
      ])
    end)
  end

  private def int_array_json(values : Array(Int32)) : JSON::Any
    JSON::Any.new(values.map { |value| JSON::Any.new(value) })
  end

  private def string_array_json(values : Array(String)) : JSON::Any
    JSON::Any.new(values.map { |value| JSON::Any.new(value) })
  end

  private def uint64_le(value : UInt64) : Bytes
    Bytes.new(8) do |index|
      ((value >> (index * 8)) & 0xff_u64).to_u8
    end
  end

  private def minmax_state(value : UInt64) : Bytes
    bytes = Bytes.new(9)
    bytes[0] = 1_u8
    encoded = uint64_le(value)
    8.times { |index| bytes[index + 1] = encoded[index] }
    bytes
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
end

if ARGV.size < 2 || ARGV.size > 4 || (ARGV[1] == "publish" && ARGV.size != 2) || (ARGV[1] == "reopen" && ARGV.size != 4)
  STDERR.puts "usage: materialized-view-aggregate-projection-w293-helper CATALOG_ROOT publish|reopen [COMPACT_PART WIDE_PART]"
  exit 2
end

begin
  compact_part = ARGV[2]? || MaterializedViewAggregateProjectionW293::COMPACT_PART
  wide_part = ARGV[3]? || MaterializedViewAggregateProjectionW293::WIDE_PART
  puts MaterializedViewAggregateProjectionW293.run(ARGV[0], ARGV[1], compact_part, wide_part).to_json
rescue error
  STDERR.puts "W293 helper failed: #{error.class}: #{error.message}"
  exit 1
end
