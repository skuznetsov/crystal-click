require "../src/crystal_click"
require "json"

# Offline half of the W295 native Count projection witness.
module MaterializedViewAggregateProjectionW295
  extend self

  FORMAT               = "materialized_view_aggregate_projection_w295_helper_v1"
  DATABASE             = "lab"
  SOURCE_PART          = "all_1_1_0"
  WIDE_PART            = "all_9_9_0"
  COMPACT_PART         = "all_10_10_0"
  PROJECTION           = "by_group"
  SOURCE_COLUMNS       = ["source_id", "source_group", "value"]
  PARENT_COLUMNS       = ["parent_id", "group_key", "value"]
  PROJECTION_COLUMNS   = ["group_key", "count()"]
  WIDE_TARGET_UUID     = "f2950000-7b7f-4e2f-9e44-dc13a87b8804"
  COMPACT_TARGET_UUID  = "f2950000-7b7f-4e2f-9e44-dc13a87b8803"
  CHILD_ROWS_PER_MARK  =                      2
  PARENT_ROWS_PER_MARK =                      2
  WINDOW_START         =                  1_u64
  WINDOW_COUNT         =                  4_u64
  PARENT_WINDOW_COUNT  =                  5_u64
  ASYMMETRIC           = 0x0102030405060708_u64
  GROUP_KEYS           = [
    7_u64,
    42_u64,
    ASYMMETRIC,
    0x8000000000000001_u64,
    UInt64::MAX,
  ]
  GROUP_COUNTS     = [1_u64, 130_u64, 2_u64, 7_u64, 3_u64]
  SOURCE_ROW_COUNT = 143_u64

  alias SourceRow = Tuple(UInt64, UInt64, UInt64)
  alias ParentRow = Tuple(UInt64, UInt64, UInt64)
  alias GroupRow = Tuple(UInt64, UInt64)

  def run(catalog_root : String, action : String, wide_part : String = WIDE_PART, compact_part : String = COMPACT_PART) : JSON::Any
    case action
    when "publish"
      publish(catalog_root)
    when "reopen"
      reopen(catalog_root, wide_part, compact_part)
    else
      raise ArgumentError.new("W295 action must be publish or reopen")
    end
  end

  private def publish(catalog_root : String) : JSON::Any
    catalog = CrystalClick::OfflineCatalog.open(catalog_root)
    source = catalog.table(DATABASE, "source")
    candidate = source.part_candidates.find { |part| part.name == SOURCE_PART } ||
                raise CrystalClick::InvalidPartError.new("W295 stock source part is absent")
    unless candidate.row_count == SOURCE_ROW_COUNT && source.columns.map { |column| {column.name, column.type} } == [
             {"source_id", "UInt64"}, {"source_group", "UInt64"}, {"value", "UInt64"},
           ]
      raise CrystalClick::CorruptPartError.new("W295 source candidate or schema differs")
    end

    wide_path = catalog.transform_materialized_view_part(
      DATABASE, "view_wide", SOURCE_PART, SOURCE_COLUMNS, WIDE_PART,
      rows_per_mark: PARENT_ROWS_PER_MARK,
      batch_rows: 2,
      profile: CrystalClick::BinaryBulkProfile.with_size_stream,
    ) do |input|
      wide_output(transform_rows(input))
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

    expected_wide = target_path(catalog_root, WIDE_TARGET_UUID, "detached", WIDE_PART)
    expected_compact = target_path(catalog_root, COMPACT_TARGET_UUID, "detached", COMPACT_PART)
    unless wide_path == expected_wide && compact_path == expected_compact
      raise CrystalClick::InvalidPartError.new("W295 transform destination differs from resolved targets")
    end

    JSON::Any.new({
      "format"                  => JSON::Any.new(FORMAT),
      "action"                  => JSON::Any.new("publish"),
      "status"                  => JSON::Any.new("ok"),
      "source_part_name"        => JSON::Any.new(SOURCE_PART),
      "source_row_count"        => JSON::Any.new(SOURCE_ROW_COUNT),
      "parent_rows"             => parent_rows_json(expected_parent_rows),
      "group_rows"              => group_rows_json(expected_group_rows),
      "group_keys"              => u64_array_json(GROUP_KEYS.to_a),
      "group_counts"            => u64_array_json(GROUP_COUNTS.to_a),
      "wide_parent_path"        => JSON::Any.new(wide_path),
      "compact_parent_path"     => JSON::Any.new(compact_path),
      "parent_mark_count"       => JSON::Any.new(mark_count(SOURCE_ROW_COUNT, PARENT_ROWS_PER_MARK)),
      "parent_tail_rows"        => JSON::Any.new(1),
      "child_mark_rows"         => int_array_json([2, 2, 1]),
      "count_state_varuint_hex" => string_array_json(GROUP_COUNTS.map { |count| varuint_hex(count) }),
      "projection_columns"      => string_array_json(PROJECTION_COLUMNS),
      "child_format"            => JSON::Any.new("Compact MRK4"),
    } of String => JSON::Any)
  end

  private def reopen(catalog_root : String, wide_part_name : String, compact_part_name : String) : JSON::Any
    [wide_part_name, compact_part_name].each do |name|
      unless /\A[a-zA-Z0-9_-]+\z/.matches?(name) && name.includes?('_')
        raise CrystalClick::InvalidPartError.new("W295 attached part identity is malformed")
      end
    end
    catalog = CrystalClick::OfflineCatalog.open(catalog_root)
    wide = reopen_pair(catalog, catalog_root, "target_wide", wide_part_name, "Wide", WIDE_TARGET_UUID)
    compact = reopen_pair(catalog, catalog_root, "target_compact", compact_part_name, "Compact", COMPACT_TARGET_UUID)
    JSON::Any.new({
      "format"       => JSON::Any.new(FORMAT),
      "action"       => JSON::Any.new("reopen"),
      "status"       => JSON::Any.new("ok"),
      "catalog_root" => JSON::Any.new(catalog.root),
      "pairs"        => JSON::Any.new([wide, compact]),
    } of String => JSON::Any)
  end

  private def reopen_pair(
    catalog : CrystalClick::OfflineCatalog,
    catalog_root : String,
    table_name : String,
    part_name : String,
    parent_format : String,
    uuid : String,
  ) : JSON::Any
    table = catalog.table(DATABASE, table_name)
    projection = table.projections.find { |entry| entry.name == PROJECTION } ||
                 raise CrystalClick::CorruptPartError.new("W295 #{table_name} projection metadata is absent")
    unless projection.definition.gsub(/\s+/, " ").strip == "SELECT group_key, count() GROUP BY group_key" &&
           table.columns.map { |column| {column.name, column.type} } == [
             {"parent_id", "UInt64"}, {"group_key", "UInt64"}, {"value", "UInt64"},
           ]
      raise CrystalClick::CorruptPartError.new("W295 #{table_name} persisted schema or projection DDL differs")
    end

    candidates = table.part_candidates
    unless candidates.size == 1 && candidates.first.name == part_name && candidates.first.row_count == SOURCE_ROW_COUNT
      raise CrystalClick::CorruptPartError.new("W295 #{table_name} attached candidate identity/count differs")
    end
    part = candidates.first
    expected_path = target_path(catalog_root, uuid, part_name)
    unless part.path == expected_path
      raise CrystalClick::InvalidPartError.new("W295 #{table_name} candidate escaped its target directory")
    end
    child_path = File.join(part.path, "#{PROJECTION}.proj")
    compressed_marks = table_name == "target_compact"
    assert_format!(part.path, parent_format, "#{table_name} parent", compressed_marks)
    assert_format!(child_path, "Compact", "#{table_name} Count child", compressed_marks)

    parent, parent_grid, parent_identity = scan_parent(table, part)
    parent_window, parent_window_grid, parent_window_identity = scan_parent(table, part, {WINDOW_START, PARENT_WINDOW_COUNT})
    child, child_grid, child_identity = scan_child(table, part, nil)
    child_window, child_window_grid, child_window_identity = scan_child(table, part, {WINDOW_START, WINDOW_COUNT})
    keys, key_grid, key_identity = scan_keys(table, part, nil)
    key_window, key_window_grid, key_window_identity = scan_keys(table, part, {WINDOW_START, WINDOW_COUNT})
    counts, count_grid, count_identity = scan_counts(table, part, nil)
    count_window, count_window_grid, count_window_identity = scan_counts(table, part, {WINDOW_START, WINDOW_COUNT})

    expected_parents = expected_parent_rows
    expected_groups = expected_group_rows
    expected_window = expected_groups[WINDOW_START.to_i, WINDOW_COUNT.to_i]
    expected_parent_window = expected_parents[WINDOW_START.to_i, PARENT_WINDOW_COUNT.to_i]
    expected_identity = {"part_name" => part.name, "part_path" => part.path}
    unless parent == expected_parents && parent_grid == expected_parent_mark_rows && parent_window == expected_parent_window &&
           parent_window_grid == [1, 2, 2] && child == expected_groups && child_grid == [2, 2, 1] &&
           child_window == expected_window && child_window_grid == [1, 2, 1] &&
           keys == GROUP_KEYS.to_a && key_grid == [2, 2, 1] && key_window == expected_window.map(&.[0]) && key_window_grid == [1, 2, 1] &&
           counts == GROUP_COUNTS.to_a && count_grid == [2, 2, 1] && count_window == expected_window.map(&.[1]) && count_window_grid == [1, 2, 1]
      raise CrystalClick::CorruptPartError.new("W295 #{table_name} full/window parent or Count rows differ")
    end
    identities = [parent_identity, parent_window_identity, child_identity, child_window_identity,
                  key_identity, key_window_identity, count_identity, count_window_identity]
    unless identities.all? { |identity| identity == expected_identity }
      raise CrystalClick::CorruptPartError.new("W295 #{table_name} scan callback lost parent-part identity")
    end

    JSON::Any.new({
      "table"                              => JSON::Any.new(table_name),
      "part_name"                          => JSON::Any.new(part.name),
      "parent_format"                      => JSON::Any.new(parent_format),
      "child_format"                       => JSON::Any.new("Compact"),
      "parent_rows"                        => parent_rows_json(parent),
      "parent_mark_rows"                   => int_array_json(parent_grid),
      "parent_window_start_1_count_5"      => parent_rows_json(parent_window),
      "parent_window_mark_rows"            => int_array_json(parent_window_grid),
      "child_rows"                         => group_rows_json(child),
      "child_mark_rows"                    => int_array_json(child_grid),
      "child_window_start_1_count_4"       => group_rows_json(child_window),
      "child_window_mark_rows"             => int_array_json(child_window_grid),
      "child_keys_only"                    => u64_array_json(keys),
      "child_keys_window_start_1_count_4"  => u64_array_json(key_window),
      "child_count_only"                   => u64_array_json(counts),
      "child_count_window_start_1_count_4" => u64_array_json(count_window),
      "count_only_mark_rows"               => int_array_json(count_grid),
      "count_only_window_mark_rows"        => int_array_json(count_window_grid),
      "parent_path"                        => JSON::Any.new(part.path),
      "child_path"                         => JSON::Any.new(child_path),
      "callback_parent_identity"           => JSON::Any.new({
        "part_name" => JSON::Any.new(part.name),
        "part_path" => JSON::Any.new(part.path),
      } of String => JSON::Any),
      "projection_columns" => string_array_json(PROJECTION_COLUMNS),
      "reopen_source"      => JSON::Any.new("byte_identical_copy_of_native_attached_part"),
    } of String => JSON::Any)
  end

  private def transform_rows(input : CrystalClick::OfflinePartTransformInput) : Array(ParentRow)
    unless input.row_count == SOURCE_ROW_COUNT && input.column_names == SOURCE_COLUMNS && input.column_types == [
             {"source_id", "UInt64"}, {"source_group", "UInt64"}, {"value", "UInt64"},
           ]
      raise CrystalClick::CorruptPartError.new("W295 callback source identity or schema differs")
    end
    observed = [] of SourceRow
    output = [] of ParentRow
    input.each_batch do |batch|
      ids = batch.values_for("source_id", UInt64)
      groups = batch.values_for("source_group", UInt64)
      values = batch.values_for("value", UInt64)
      unless ids.size == groups.size && groups.size == values.size
        raise CrystalClick::CorruptPartError.new("W295 source columns are not aligned")
      end
      ids.each_index do |index|
        row = {ids[index], groups[index], values[index]}
        expected = source_rows[observed.size]?
        unless expected && expected == row
          raise CrystalClick::CorruptPartError.new("W295 literal source differs at row #{observed.size}")
        end
        observed << row
        output << {ids[index] + 100_u64, groups[index], values[index]}
      end
    end
    unless observed == source_rows && output == expected_parent_rows
      raise CrystalClick::CorruptPartError.new("W295 transform callback did not complete the exact source map")
    end
    output
  end

  private def wide_output(rows : Array(ParentRow)) : CrystalClick::WidePartTransformOutput
    ids = rows.map(&.[0])
    groups = rows.map(&.[1])
    values = rows.map(&.[2])
    projection = count_projection(false)
    CrystalClick::WidePartTransformOutput.new(
      ids.to_unsafe.to_slice(ids.size),
      [wide_u64("group_key", groups), wide_u64("value", values)] of CrystalClick::WidePartColumn,
      projections: [projection] of (CrystalClick::WidePartProjection | CrystalClick::CompactPartProjection),
    )
  end

  private def compact_output(rows : Array(ParentRow)) : CrystalClick::CompactPartTransformOutput
    ids = rows.map(&.[0])
    groups = rows.map(&.[1])
    values = rows.map(&.[2])
    projection = count_projection(true)
    CrystalClick::CompactPartTransformOutput.new(
      ids.to_unsafe.to_slice(ids.size),
      [compact_u64("group_key", groups), compact_u64("value", values)] of CrystalClick::CompactPartColumn,
      projections: [projection] of (CrystalClick::WidePartProjection | CrystalClick::CompactPartProjection),
    )
  end

  private def count_projection(compress_marks : Bool) : CrystalClick::CompactPartProjection
    keys = GROUP_KEYS.to_a
    counts = GROUP_COUNTS.to_a
    CrystalClick::CompactPartProjection.precomputed_count(
      PROJECTION, "group_key",
      keys.to_unsafe.to_slice(keys.size),
      counts.to_unsafe.to_slice(counts.size),
      rows_per_mark: CHILD_ROWS_PER_MARK,
      compress_marks: compress_marks,
    )
  end

  private def scan_parent(
    table : CrystalClick::OfflineTable,
    part : CrystalClick::OfflinePartCandidate,
    window : Tuple(UInt64, UInt64)? = nil,
  ) : {Array(ParentRow), Array(Int32), Hash(String, String)}
    rows = [] of ParentRow
    grid = [] of Int32
    identity = nil.as(Hash(String, String)?)
    callback = ->(batch : CrystalClick::WidePartTableBatch) do
      observe_identity!(identity, batch, part)
      ids = batch.values_for("parent_id", UInt64)
      groups = batch.values_for("group_key", UInt64)
      values = batch.values_for("value", UInt64)
      unless ids.size == groups.size && groups.size == values.size
        raise CrystalClick::CorruptPartError.new("W295 selected parent columns are not aligned")
      end
      ids.each_index { |index| rows << {ids[index], groups[index], values[index]} }
      grid << ids.size.to_i32
      nil
    end
    if range = window
      table.scan_typed_window(PARENT_COLUMNS, range[0], range[1], &callback)
    else
      table.scan_typed(PARENT_COLUMNS, batch_rows: PARENT_ROWS_PER_MARK, &callback)
    end
    {rows, grid, identity || identity_for(part)}
  end

  private def scan_child(
    table : CrystalClick::OfflineTable,
    part : CrystalClick::OfflinePartCandidate,
    window : Tuple(UInt64, UInt64)?,
  ) : {Array(GroupRow), Array(Int32), Hash(String, String)}
    rows = [] of GroupRow
    grid = [] of Int32
    identity = nil.as(Hash(String, String)?)
    callback = ->(batch : CrystalClick::WidePartTableBatch) do
      observe_identity!(identity, batch, part)
      keys = batch.values_for("group_key", UInt64)
      counts = batch.aggregate_count_states_for("count()", CrystalClick::BinaryDataType.aggregate_count)
      unless keys.size == counts.size
        raise CrystalClick::CorruptPartError.new("W295 child keys and Count states are not aligned")
      end
      keys.each_index { |index| rows << {keys[index], counts[index].count_state} }
      grid << keys.size.to_i32
      nil
    end
    if range = window
      table.scan_projection_typed_window(PROJECTION, PROJECTION_COLUMNS, range[0], range[1], &callback)
    else
      table.scan_projection_typed(PROJECTION, PROJECTION_COLUMNS, batch_rows: CHILD_ROWS_PER_MARK, &callback)
    end
    {rows, grid, identity || identity_for(part)}
  end

  private def scan_keys(
    table : CrystalClick::OfflineTable,
    part : CrystalClick::OfflinePartCandidate,
    window : Tuple(UInt64, UInt64)?,
  ) : {Array(UInt64), Array(Int32), Hash(String, String)}
    rows = [] of UInt64
    grid = [] of Int32
    identity = nil.as(Hash(String, String)?)
    callback = ->(batch : CrystalClick::WidePartTableBatch) do
      observe_identity!(identity, batch, part)
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
    {rows, grid, identity || identity_for(part)}
  end

  private def scan_counts(
    table : CrystalClick::OfflineTable,
    part : CrystalClick::OfflinePartCandidate,
    window : Tuple(UInt64, UInt64)?,
  ) : {Array(UInt64), Array(Int32), Hash(String, String)}
    rows = [] of UInt64
    grid = [] of Int32
    identity = nil.as(Hash(String, String)?)
    callback = ->(batch : CrystalClick::WidePartTableBatch) do
      observe_identity!(identity, batch, part)
      states = batch.aggregate_count_states_for("count()", CrystalClick::BinaryDataType.aggregate_count)
      states.each { |state| rows << state.count_state }
      grid << states.size.to_i32
      nil
    end
    if range = window
      table.scan_projection_typed_window(PROJECTION, ["count()"], range[0], range[1], &callback)
    else
      table.scan_projection_typed(PROJECTION, ["count()"], batch_rows: CHILD_ROWS_PER_MARK, &callback)
    end
    {rows, grid, identity || identity_for(part)}
  end

  private def observe_identity!(identity : Hash(String, String)?, batch : CrystalClick::WidePartTableBatch, part : CrystalClick::OfflinePartCandidate) : Nil
    actual = {"part_name" => batch.part_name, "part_path" => batch.part_path}
    expected = identity_for(part)
    unless actual == expected
      raise CrystalClick::CorruptPartError.new("W295 scan callback does not identify its selected parent part")
    end
    nil
  end

  private def identity_for(part : CrystalClick::OfflinePartCandidate) : Hash(String, String)
    {"part_name" => part.name, "part_path" => part.path}
  end

  private def source_rows : Array(SourceRow)
    rows = [] of SourceRow
    id = 1_u64
    GROUP_KEYS.each_with_index do |group, group_index|
      remaining = GROUP_COUNTS[group_index]
      while remaining > 0_u64
        rows << {id, group, (id * 37_u64) ^ ASYMMETRIC}
        id += 1_u64
        remaining -= 1_u64
      end
    end
    rows
  end

  private def expected_parent_rows : Array(ParentRow)
    source_rows.map { |row| {row[0] + 100_u64, row[1], row[2]} }
  end

  private def expected_group_rows : Array(GroupRow)
    GROUP_KEYS.each_with_index.map { |key, index| {key, GROUP_COUNTS[index]} }.to_a
  end

  private def expected_parent_mark_rows : Array(Int32)
    full_marks = (SOURCE_ROW_COUNT / PARENT_ROWS_PER_MARK).to_i32
    tail = (SOURCE_ROW_COUNT % PARENT_ROWS_PER_MARK).to_i32
    Array(Int32).new(full_marks, PARENT_ROWS_PER_MARK).tap { |rows| rows << tail if tail > 0 }
  end

  private def mark_count(rows : UInt64, rows_per_mark : Int32) : Int32
    ((rows + rows_per_mark.to_u64 - 1_u64) / rows_per_mark.to_u64).to_i32
  end

  private def assert_format!(path : String, expected : String, label : String, compressed_marks : Bool) : Nil
    children = Dir.children(path)
    compact = children.any? { |name| name.ends_with?(".mrk4") || name.ends_with?(".cmrk4") }
    wide = children.any? { |name| name.ends_with?(".mrk2") || name.ends_with?(".cmrk2") }
    mark_files = children.select { |name| /\.c?mrk[24]\z/.matches?(name) }
    actual = if compact && !wide
               "Compact"
             elsif wide && !compact
               "Wide"
             else
               "ambiguous"
             end
    unless actual == expected
      raise CrystalClick::CorruptPartError.new("W295 #{label} marker family is #{actual}, expected #{expected}")
    end
    actual_compressed = !mark_files.empty? && mark_files.all? { |name| name.includes?(".cmrk") }
    unless actual_compressed == compressed_marks
      raise CrystalClick::CorruptPartError.new("W295 #{label} mark compression differs from its persisted table settings")
    end
  end

  private def target_path(root : String, uuid : String, *parts : String) : String
    File.join(root, "store", uuid.byte_slice(0, 3), uuid, *parts)
  end

  private def wide_u64(name : String, values : Array(UInt64)) : CrystalClick::WidePartColumn
    CrystalClick::WidePartColumn.binary_bulk(name, CrystalClick::BinaryDataType.primitive("UInt64"), grouped(values))
  end

  private def compact_u64(name : String, values : Array(UInt64)) : CrystalClick::CompactPartColumn
    CrystalClick::CompactPartColumn.binary_bulk(name, CrystalClick::BinaryDataType.primitive("UInt64"), grouped(values))
  end

  private def grouped(values : Array(UInt64)) : Array(Array(CrystalClick::BinaryValue))
    values.map { |value| CrystalClick::BinaryValue.uint64(value) }.each.each_slice(PARENT_ROWS_PER_MARK).map(&.to_a).to_a
  end

  private def varuint_hex(value : UInt64) : String
    bytes = [] of UInt8
    remaining = value
    loop do
      byte = (remaining & 0x7f_u64).to_u8
      remaining >>= 7
      bytes << (remaining == 0 ? byte : byte | 0x80_u8)
      break if remaining == 0
    end
    bytes.to_unsafe.to_slice(bytes.size).hexstring
  end

  private def parent_rows_json(rows : Array(ParentRow)) : JSON::Any
    JSON::Any.new(rows.map { |row| JSON::Any.new(row.to_a.map { |value| JSON::Any.new(value.to_s) }) })
  end

  private def group_rows_json(rows : Array(GroupRow)) : JSON::Any
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
end

if ARGV.size < 2 || ARGV.size > 4 || (ARGV[1] == "publish" && ARGV.size != 2) || (ARGV[1] == "reopen" && ARGV.size != 4)
  STDERR.puts "usage: materialized-view-aggregate-projection-w295-helper CATALOG_ROOT publish|reopen [WIDE_PART COMPACT_PART]"
  exit 2
end

begin
  puts MaterializedViewAggregateProjectionW295.run(
    ARGV[0], ARGV[1], ARGV[2]? || MaterializedViewAggregateProjectionW295::WIDE_PART,
    ARGV[3]? || MaterializedViewAggregateProjectionW295::COMPACT_PART,
  ).to_json
rescue ex
  STDERR.puts "W295 helper failure: #{ex.class}: #{ex.message}"
  exit 1
end
