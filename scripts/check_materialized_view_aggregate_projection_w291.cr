require "../src/crystal_click"
require "json"

# W291 helper fixture. The caller chooses both the transform and the aggregate
# projection values; this code does not evaluate the projection SQL.
module MaterializedViewAggregateProjectionW291
  extend self

  FORMAT                = "materialized_view_aggregate_projection_w291_helper_v1"
  DATABASE              = "lab"
  PROJECTION            = "by_group"
  SOURCE_PART           = "all_1_1_0"
  COMPACT_PART          = "all_9_9_0"
  WIDE_PART             = "all_10_10_0"
  SOURCE_COLUMNS        = ["source_id", "source_group", "payload"]
  PARENT_COLUMNS        = ["parent_id", "group_key", "payload"]
  PROJECTION_COLUMNS    = ["group_key", "count()"]
  COMPACT_TARGET_UUID   = "f2910000-7b7f-4e2f-9e44-dc13a87b8805"
  WIDE_TARGET_UUID      = "f2910000-7b7f-4e2f-9e44-dc13a87b8806"
  WIDE_OUTPUT_ROW_COUNT = 131
  WIDE_ROWS_PER_MARK    =   4
  CHILD_ROWS_PER_MARK   =   2

  alias SourceRow = Tuple(UInt64, UInt64, String)
  alias ParentRow = Tuple(UInt64, UInt64, String)
  alias CountRow = Tuple(UInt64, UInt64)

  private def expected_parent_rows(row_count : Int32) : Array(ParentRow)
    Array(ParentRow).new(row_count) do |index|
      source_id = (index + 1).to_u64
      source_group = if source_id <= 3_u64
                       7_u64
                     elsif source_id <= 5_u64
                       11_u64
                     elsif source_id == 6_u64
                       29_u64
                     else
                       7_u64
                     end
      {source_id + 1_000_u64, source_group * 10_u64 + 7_u64, "r#{source_id}!"}
    end
  end

  SOURCE_ROWS = (1_u64..133_u64).map do |id|
    source_group = case id
                   when 1_u64..3_u64   then 7_u64
                   when 4_u64..5_u64   then 11_u64
                   when 6_u64          then 29_u64
                   when 7_u64..131_u64 then 7_u64
                   when 132_u64        then 41_u64
                   else                     43_u64
                   end
    {id, source_group, "r#{id}"}
  end

  EXPECTED_COMPACT_ROWS   = expected_parent_rows(6)
  EXPECTED_WIDE_ROWS      = expected_parent_rows(WIDE_OUTPUT_ROW_COUNT)
  EXPECTED_COMPACT_COUNTS = [{77_u64, 3_u64}, {117_u64, 2_u64}, {297_u64, 1_u64}]
  EXPECTED_WIDE_COUNTS    = [{77_u64, 128_u64}, {117_u64, 2_u64}, {297_u64, 1_u64}]

  def run(catalog_root : String, action : String, compact_part : String = COMPACT_PART, wide_part : String = WIDE_PART) : JSON::Any
    case action
    when "publish"
      publish(catalog_root)
    when "reopen"
      reopen(catalog_root, compact_part, wide_part)
    else
      raise ArgumentError.new("W291 action must be publish or reopen")
    end
  end

  private def publish(catalog_root : String) : JSON::Any
    catalog = CrystalClick::OfflineCatalog.open(catalog_root)
    source = catalog.table(DATABASE, "source")
    source_candidate = source.part_candidates.find { |part| part.name == SOURCE_PART } ||
                       raise CrystalClick::InvalidPartError.new("W291 stock source part is absent")
    source_columns = source.columns.map { |column| {column.name, column.type} }
    unless source_candidate.row_count == SOURCE_ROWS.size.to_u64 && source_columns == [
             {"source_id", "UInt64"}, {"source_group", "UInt64"}, {"payload", "String"},
           ]
      raise CrystalClick::CorruptPartError.new("W291 source candidate or exact schema differs")
    end

    compact_destination = catalog.transform_materialized_view_part(
      DATABASE, "view_compact", SOURCE_PART, SOURCE_COLUMNS, COMPACT_PART,
      mark_format: CrystalClick::CompactMarkFormat::Mrk4,
      rows_per_mark: 3,
      batch_rows: 3,
      profile: CrystalClick::BinaryBulkProfile.with_size_stream,
    ) do |input|
      rows = transform_rows(input, 6)
      compact_parent_output(rows)
    end

    wide_destination = catalog.transform_materialized_view_part(
      DATABASE, "view_wide", SOURCE_PART, SOURCE_COLUMNS, WIDE_PART,
      rows_per_mark: WIDE_ROWS_PER_MARK,
      batch_rows: 3,
      profile: CrystalClick::BinaryBulkProfile.with_size_stream,
    ) do |input|
      rows = transform_rows(input, WIDE_OUTPUT_ROW_COUNT)
      wide_parent_output(rows)
    end

    expected_compact = target_path(catalog_root, COMPACT_TARGET_UUID, "detached", COMPACT_PART)
    expected_wide = target_path(catalog_root, WIDE_TARGET_UUID, "detached", WIDE_PART)
    unless compact_destination == expected_compact && wide_destination == expected_wide
      raise CrystalClick::InvalidPartError.new("W291 transform destination differs from its resolved target")
    end

    JSON::Any.new({
      "format"                    => JSON::Any.new(FORMAT),
      "action"                    => JSON::Any.new("publish"),
      "status"                    => JSON::Any.new("ok"),
      "source_part_name"          => JSON::Any.new(SOURCE_PART),
      "source_row_count"          => JSON::Any.new(SOURCE_ROWS.size),
      "compact_parent_row_count"  => JSON::Any.new(EXPECTED_COMPACT_ROWS.size),
      "wide_parent_row_count"     => JSON::Any.new(EXPECTED_WIDE_ROWS.size),
      "compact_parent_rows"       => parent_rows_json(EXPECTED_COMPACT_ROWS),
      "wide_parent_rows"          => parent_rows_json(EXPECTED_WIDE_ROWS),
      "compact_child_rows"        => count_rows_json(EXPECTED_COMPACT_COUNTS),
      "wide_child_rows"           => count_rows_json(EXPECTED_WIDE_COUNTS),
      "compact_parent_mark_rows"  => int_array_json([3, 3]),
      "wide_parent_mark_rows"     => int_array_json(mark_rows(EXPECTED_WIDE_ROWS.size, WIDE_ROWS_PER_MARK)),
      "child_mark_rows"           => int_array_json([2, 1]),
      "projection_name"           => JSON::Any.new(PROJECTION),
      "projection_columns"        => string_array_json(PROJECTION_COLUMNS),
      "parent_columns"            => string_array_json(PARENT_COLUMNS),
      "compact_parent_path"       => JSON::Any.new(compact_destination),
      "wide_parent_path"          => JSON::Any.new(wide_destination),
      "wide_count_128_state_hex"  => JSON::Any.new("8001"),
      "projection_physical_state" => JSON::Any.new("count() AggregateFunction(count)"),
      "alias_target_state_name"   => JSON::Any.new("count()"),
    } of String => JSON::Any)
  end

  private def reopen(catalog_root : String, compact_part_name : String, wide_part_name : String) : JSON::Any
    {compact_part_name, wide_part_name}.each do |name|
      unless /\A[a-zA-Z0-9_-]+\z/.matches?(name) && name.includes?('_')
        raise CrystalClick::InvalidPartError.new("W291 attached part identity is malformed")
      end
    end

    catalog = CrystalClick::OfflineCatalog.open(catalog_root)
    pairs = [
      {"target_compact", compact_part_name, "Compact", COMPACT_TARGET_UUID, EXPECTED_COMPACT_ROWS, EXPECTED_COMPACT_COUNTS, 3},
      {"target_wide", wide_part_name, "Wide", WIDE_TARGET_UUID, EXPECTED_WIDE_ROWS, EXPECTED_WIDE_COUNTS, WIDE_ROWS_PER_MARK},
    ]
    pair_json = pairs.map do |table_name, part_name, parent_format, target_uuid, expected_parent, expected_counts, parent_rows_per_mark|
      table = catalog.table(DATABASE, table_name)
      metadata = table.metadata_ddl || raise CrystalClick::CorruptPartError.new("W291 #{table_name} metadata is absent")
      normalized_metadata = metadata.gsub(/\s+/, " ")
      normalized_projections = table.projections.map do |projection|
        {projection.name, projection.definition.gsub(/\s+/, " ").strip}
      end
      expected_definition = if table_name == "target_compact"
                              "SELECT group_key, count() GROUP BY group_key"
                            else
                              "SELECT count() AS n GROUP BY group_key"
                            end
      unless table.columns.map { |column| {column.name, column.type} } == [
               {"parent_id", "UInt64"}, {"group_key", "UInt64"}, {"payload", "String"},
             ] && normalized_projections == [{PROJECTION, expected_definition}]
        raise CrystalClick::CorruptPartError.new("W291 #{table_name} persisted schema/projection DDL differs")
      end
      unless normalized_metadata.includes?("PROJECTION by_group") && normalized_metadata.includes?(expected_definition)
        raise CrystalClick::CorruptPartError.new("W291 #{table_name} metadata lost the native aggregate projection definition")
      end

      candidates = table.part_candidates
      unless candidates.size == 1 && candidates.first.name == part_name && candidates.first.row_count == expected_parent.size.to_u64
        raise CrystalClick::CorruptPartError.new("W291 #{table_name} candidate identity/count differs")
      end
      part = candidates.first
      unless part.path == target_path(catalog_root, target_uuid, part_name)
        raise CrystalClick::InvalidPartError.new("W291 #{table_name} candidate escaped its catalog table directory")
      end

      child_path = File.join(part.path, "#{PROJECTION}.proj")
      assert_format!(part.path, parent_format, "#{table_name} parent")
      assert_format!(child_path, "Wide", "#{table_name} aggregate child")

      parent, parent_grid = scan_parent(table, part, nil, parent_rows_per_mark)
      counts, child_grid = scan_counts(table, part, nil)
      parent_window, parent_window_grid = scan_parent(table, part, 1_u64, parent_rows_per_mark)
      count_window, count_window_grid = scan_counts(table, part, 1_u64)
      expected_parent_window = expected_parent[1, 2]
      expected_count_window = expected_counts[1, 2]
      unless parent == expected_parent && counts == expected_counts &&
             parent_grid == mark_rows(expected_parent.size, parent_rows_per_mark) && child_grid == [2, 1] &&
             parent_window == expected_parent_window && parent_window_grid == [2] &&
             count_window == expected_count_window && count_window_grid == [1, 1]
        raise CrystalClick::CorruptPartError.new("W291 #{table_name} OfflineCatalog full/window values or mark grids differ")
      end

      JSON::Any.new({
        "table"                   => JSON::Any.new(table_name),
        "part_name"               => JSON::Any.new(part.name),
        "parent_format"           => JSON::Any.new(parent_format),
        "child_format"            => JSON::Any.new("Wide"),
        "parent_row_count"        => JSON::Any.new(part.row_count.to_i64),
        "parent_rows"             => parent_rows_json(parent),
        "child_rows"              => count_rows_json(counts),
        "parent_mark_rows"        => int_array_json(parent_grid),
        "child_mark_rows"         => int_array_json(child_grid),
        "parent_window_rows_1_3"  => parent_rows_json(parent_window),
        "child_window_rows_1_3"   => count_rows_json(count_window),
        "parent_window_mark_rows" => int_array_json(parent_window_grid),
        "child_window_mark_rows"  => int_array_json(count_window_grid),
        "parent_path"             => JSON::Any.new(part.path),
        "child_path"              => JSON::Any.new(child_path),
        "reopen_source"           => JSON::Any.new("byte_identical_copy_of_native_attached_part"),
      } of String => JSON::Any)
    end

    JSON::Any.new({
      "format"       => JSON::Any.new(FORMAT),
      "action"       => JSON::Any.new("reopen"),
      "status"       => JSON::Any.new("ok"),
      "catalog_root" => JSON::Any.new(catalog.root),
      "pairs"        => JSON::Any.new(pair_json),
    } of String => JSON::Any)
  end

  private def transform_rows(input : CrystalClick::OfflinePartTransformInput, output_count : Int32) : Array(ParentRow)
    unless input.row_count == SOURCE_ROWS.size.to_u64 && input.column_names == SOURCE_COLUMNS &&
           input.column_types == [{"source_id", "UInt64"}, {"source_group", "UInt64"}, {"payload", "String"}]
      raise CrystalClick::CorruptPartError.new("W291 callback source identity/schema differs")
    end

    expected = SOURCE_ROWS
    observed = [] of SourceRow
    output = [] of ParentRow
    input.each_batch do |batch|
      ids = batch.values_for("source_id", UInt64)
      groups = batch.values_for("source_group", UInt64)
      payloads = batch.strings_for("payload")
      unless ids.size == groups.size && groups.size == payloads.size
        raise CrystalClick::CorruptPartError.new("W291 callback source columns are not row-aligned")
      end
      ids.each_index do |index|
        source_row = {ids[index], groups[index], payloads[index].dup}
        expected_row = expected[observed.size]?
        unless expected_row && source_row == expected_row
          raise CrystalClick::CorruptPartError.new("W291 callback source literal differs at row #{observed.size}")
        end
        observed << source_row
        next if ids[index] > output_count.to_u64
        output << {ids[index] + 1_000_u64, groups[index] * 10_u64 + 7_u64, payloads[index] + "!"}
      end
    end

    unless observed == SOURCE_ROWS && output == expected_parent_rows(output_count)
      raise CrystalClick::CorruptPartError.new("W291 callback did not complete the exact filter/map/rekey oracle")
    end
    output
  end

  private def compact_parent_output(rows : Array(ParentRow)) : CrystalClick::CompactPartTransformOutput
    parent_ids = rows.map(&.[0])
    group_keys = rows.map(&.[1])
    payloads = rows.map(&.[2])
    keys, counts = count_pairs(rows)
    unless keys.zip(counts) == EXPECTED_COMPACT_COUNTS
      raise CrystalClick::CorruptPartError.new("W291 Compact parent count groups differ")
    end
    child = CrystalClick::WidePartProjection.precomputed_count(
      PROJECTION,
      "group_key",
      keys.to_unsafe.to_slice(keys.size),
      counts.to_unsafe.to_slice(counts.size),
      rows_per_mark: CHILD_ROWS_PER_MARK,
    )
    projections = [child] of (CrystalClick::WidePartProjection | CrystalClick::CompactPartProjection)
    CrystalClick::CompactPartTransformOutput.new(
      parent_ids.to_unsafe.to_slice(parent_ids.size),
      [compact_u64("group_key", group_keys, 3), compact_string("payload", payloads, 3)] of CrystalClick::CompactPartColumn,
      projections: projections,
    )
  end

  private def wide_parent_output(rows : Array(ParentRow)) : CrystalClick::WidePartTransformOutput
    parent_ids = rows.map(&.[0])
    group_keys = rows.map(&.[1])
    payloads = rows.map(&.[2])
    keys, counts = count_pairs(rows)
    unless keys.zip(counts) == EXPECTED_WIDE_COUNTS
      raise CrystalClick::CorruptPartError.new("W291 Wide parent count groups differ")
    end
    child = CrystalClick::WidePartProjection.precomputed_count(
      PROJECTION,
      "group_key",
      keys.to_unsafe.to_slice(keys.size),
      counts.to_unsafe.to_slice(counts.size),
      rows_per_mark: CHILD_ROWS_PER_MARK,
    )
    projections = [child] of (CrystalClick::WidePartProjection | CrystalClick::CompactPartProjection)
    CrystalClick::WidePartTransformOutput.new(
      parent_ids.to_unsafe.to_slice(parent_ids.size),
      [wide_u64("group_key", group_keys, WIDE_ROWS_PER_MARK), wide_string("payload", payloads, WIDE_ROWS_PER_MARK)] of CrystalClick::WidePartColumn,
      projections: projections,
    )
  end

  private def count_pairs(rows : Array(ParentRow)) : {Array(UInt64), Array(UInt64)}
    grouped = Hash(UInt64, UInt64).new(0_u64)
    rows.each { |row| grouped[row[1]] += 1_u64 }
    pairs = grouped.to_a.sort_by(&.[0])
    {pairs.map(&.[0]), pairs.map(&.[1])}
  end

  private def scan_parent(
    table : CrystalClick::OfflineTable,
    expected_candidate : CrystalClick::OfflinePartCandidate,
    start_row : UInt64?,
    batch_rows : Int32,
  ) : {Array(ParentRow), Array(Int32)}
    rows = [] of ParentRow
    grid = [] of Int32
    callback = ->(batch : CrystalClick::WidePartTableBatch) do
      validate_batch!(table, expected_candidate, batch)
      ids = batch.values_for("parent_id", UInt64)
      keys = batch.values_for("group_key", UInt64)
      payloads = batch.strings_for("payload")
      unless ids.size == keys.size && keys.size == payloads.size
        raise CrystalClick::CorruptPartError.new("W291 parent batch columns are not row-aligned")
      end
      ids.each_index { |index| rows << {ids[index], keys[index], payloads[index].dup} }
      grid << ids.size.to_i32
      nil
    end

    if start = start_row
      table.scan_typed_window(PARENT_COLUMNS, start, 2, &callback)
    else
      table.scan_typed(PARENT_COLUMNS, batch_rows: batch_rows, &callback)
    end
    {rows, grid}
  end

  private def scan_counts(
    table : CrystalClick::OfflineTable,
    expected_candidate : CrystalClick::OfflinePartCandidate,
    start_row : UInt64?,
  ) : {Array(CountRow), Array(Int32)}
    rows = [] of CountRow
    grid = [] of Int32
    callback = ->(batch : CrystalClick::WidePartTableBatch) do
      validate_batch!(table, expected_candidate, batch)
      keys = batch.values_for("group_key", UInt64)
      states = batch.aggregate_count_states_for("count()", CrystalClick::BinaryDataType.aggregate_count)
      unless keys.size == states.size
        raise CrystalClick::CorruptPartError.new("W291 key/count state columns are not row-aligned")
      end
      keys.each_index { |index| rows << {keys[index], states[index].count_state} }
      grid << keys.size.to_i32
      nil
    end

    if start = start_row
      table.scan_projection_typed_window(PROJECTION, PROJECTION_COLUMNS, start, 2, &callback)
    else
      table.scan_projection_typed(PROJECTION, PROJECTION_COLUMNS, batch_rows: CHILD_ROWS_PER_MARK, &callback)
    end
    {rows, grid}
  end

  private def validate_batch!(
    table : CrystalClick::OfflineTable,
    expected_candidate : CrystalClick::OfflinePartCandidate,
    batch : CrystalClick::WidePartTableBatch,
  ) : Nil
    expected_index = table.part_candidates.index do |candidate|
      candidate.name == expected_candidate.name && candidate.path == expected_candidate.path
    end || raise CrystalClick::InvalidPartError.new("W291 reopen candidate identity disappeared")
    unless batch.part_name == expected_candidate.name && batch.part_path == expected_candidate.path &&
           batch.part_index == expected_index
      raise CrystalClick::CorruptPartError.new("W291 catalog batch candidate name/path/index differs")
    end
  end

  private def wide_u64(name : String, values : Array(UInt64), rows_per_mark : Int32) : CrystalClick::WidePartColumn
    CrystalClick::WidePartColumn.binary_bulk(name, CrystalClick::BinaryDataType.primitive("UInt64"), grouped_u64(values, rows_per_mark))
  end

  private def wide_string(name : String, values : Array(String), rows_per_mark : Int32) : CrystalClick::WidePartColumn
    CrystalClick::WidePartColumn.binary_bulk(name, CrystalClick::BinaryDataType.primitive("String"), grouped_strings(values, rows_per_mark))
  end

  private def compact_u64(name : String, values : Array(UInt64), rows_per_mark : Int32) : CrystalClick::CompactPartColumn
    CrystalClick::CompactPartColumn.binary_bulk(name, CrystalClick::BinaryDataType.primitive("UInt64"), grouped_u64(values, rows_per_mark))
  end

  private def compact_string(name : String, values : Array(String), rows_per_mark : Int32) : CrystalClick::CompactPartColumn
    CrystalClick::CompactPartColumn.binary_bulk(name, CrystalClick::BinaryDataType.primitive("String"), grouped_strings(values, rows_per_mark))
  end

  private def grouped_u64(values : Array(UInt64), rows_per_mark : Int32) : Array(Array(CrystalClick::BinaryValue))
    grouped(values.map { |value| CrystalClick::BinaryValue.uint64(value) }, rows_per_mark)
  end

  private def grouped_strings(values : Array(String), rows_per_mark : Int32) : Array(Array(CrystalClick::BinaryValue))
    grouped(values.map { |value| CrystalClick::BinaryValue.string(value) }, rows_per_mark)
  end

  private def grouped(values : Array(CrystalClick::BinaryValue), rows_per_mark : Int32) : Array(Array(CrystalClick::BinaryValue))
    values.each_slice(rows_per_mark).map(&.to_a).to_a
  end

  private def mark_rows(row_count : Int32, rows_per_mark : Int32) : Array(Int32)
    mark_count = (row_count + rows_per_mark - 1) // rows_per_mark
    Array(Int32).new(mark_count) do |index|
      remaining = row_count - index * rows_per_mark
      {remaining, rows_per_mark}.min
    end
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
      raise CrystalClick::CorruptPartError.new("W291 #{label} marker family was #{actual}, expected #{format}")
    end
  end

  private def target_path(root : String, uuid : String, *parts : String) : String
    File.join(root, "store", uuid[0, 3], uuid, *parts)
  end

  private def parent_rows_json(rows : Array(ParentRow)) : JSON::Any
    JSON::Any.new(rows.map do |row|
      JSON::Any.new([JSON::Any.new(row[0].to_i64), JSON::Any.new(row[1].to_i64), JSON::Any.new(row[2])])
    end)
  end

  private def count_rows_json(rows : Array(CountRow)) : JSON::Any
    JSON::Any.new(rows.map do |row|
      JSON::Any.new([JSON::Any.new(row[0].to_i64), JSON::Any.new(row[1].to_i64)])
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
  STDERR.puts "usage: materialized-view-aggregate-projection-w291-helper CATALOG_ROOT publish|reopen [COMPACT_PART WIDE_PART]"
  exit 2
end

begin
  compact_part = ARGV[2]? || MaterializedViewAggregateProjectionW291::COMPACT_PART
  wide_part = ARGV[3]? || MaterializedViewAggregateProjectionW291::WIDE_PART
  puts MaterializedViewAggregateProjectionW291.run(ARGV[0], ARGV[1], compact_part, wide_part).to_json
rescue error
  STDERR.puts "W291 helper failed: #{error.class}: #{error.message}"
  exit 1
end
