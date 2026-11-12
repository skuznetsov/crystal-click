require "../src/crystal_click"

# Read-only witness for the pinned W288 native projection pair store.
# The fixture contains one all_1_1_0 part per table, each with the same six
# parent rows and a by_score child ordered on the projection key. ClickHouse
# authored the DDL and physical files; this script only opens them through the
# public OfflineCatalog entry point.

W288_DATABASE    = "native_stock"
W288_PROJECTION  = "by_score"
W288_TABLES      = ["compact_parent_wide_child", "wide_parent_compact_child"]
W288_COLUMNS     = ["id", "score", "label"]
W288_PARENT_ROWS = [
  {1_u64, 50_u64, "a\0b"},
  {2_u64, 10_u64, ""},
  {3_u64, 40_u64, "café"},
  {4_u64, 20_u64, "z\0"},
  {5_u64, 60_u64, "é"},
  {6_u64, 30_u64, "hi"},
]
W288_PROJECTION_ROWS = [
  {2_u64, 10_u64, ""},
  {4_u64, 20_u64, "z\0"},
  {6_u64, 30_u64, "hi"},
  {3_u64, 40_u64, "café"},
  {1_u64, 50_u64, "a\0b"},
  {5_u64, 60_u64, "é"},
]

alias W288Row = Tuple(UInt64, UInt64, String)
alias W288Batch = NamedTuple(
  part_index: Int32,
  part_name: String,
  part_path: String,
  mark_index: Int32,
  mark_row_offset: UInt64,
  part_row_offset: UInt64,
  source_row_offset: UInt64,
  rows: Array(W288Row),
)

def w288_assert(condition : Bool, message : String) : Nil
  raise "W288 projection pair witness: #{message}" unless condition
end

def w288_capture_batch(batches : Array(W288Batch), batch : CrystalClick::WidePartTableBatch) : Nil
  ids = batch.values_for("id", UInt64)
  scores = batch.values_for("score", UInt64)
  labels = batch.strings_for("label")
  unless ids.size == scores.size && scores.size == labels.size
    raise "batch columns are not row aligned for #{batch.part_name} mark #{batch.mark_index}"
  end

  rows = [] of W288Row
  ids.each_index do |index|
    rows << {ids[index], scores[index], labels[index].dup}
  end
  batches << {
    part_index:        batch.part_index,
    part_name:         batch.part_name.dup,
    part_path:         batch.part_path.dup,
    mark_index:        batch.mark_index,
    mark_row_offset:   batch.mark_row_offset,
    part_row_offset:   batch.part_row_offset,
    source_row_offset: batch.source_row_offset,
    rows:              rows,
  }
end

def w288_scan_full(
  table : CrystalClick::OfflineTable,
  projection : Bool,
) : Array(W288Batch)
  batches = [] of W288Batch
  callback = ->(batch : CrystalClick::WidePartTableBatch) { w288_capture_batch(batches, batch) }
  if projection
    table.scan_projection_typed(W288_PROJECTION, W288_COLUMNS, batch_rows: 1024, &callback)
  else
    table.scan_typed(W288_COLUMNS, batch_rows: 1024, &callback)
  end
  batches
end

def w288_scan_window(
  table : CrystalClick::OfflineTable,
  projection : Bool,
) : Array(W288Batch)
  batches = [] of W288Batch
  callback = ->(batch : CrystalClick::WidePartTableBatch) { w288_capture_batch(batches, batch) }
  if projection
    table.scan_projection_typed_window(W288_PROJECTION, W288_COLUMNS, 2_u64, 2, &callback)
  else
    table.scan_typed_window(W288_COLUMNS, 2_u64, 2, &callback)
  end
  batches
end

def w288_rows(batches : Array(W288Batch)) : Array(W288Row)
  batches.flat_map(&.[:rows])
end

def w288_assert_batches(
  label : String,
  batches : Array(W288Batch),
  part : CrystalClick::OfflinePartCandidate,
  expected_marks : Array({Int32, UInt64, UInt64, UInt64, Int32}),
) : Nil
  actual = batches.map do |batch|
    {
      batch[:mark_index],
      batch[:mark_row_offset],
      batch[:part_row_offset],
      batch[:source_row_offset],
      batch[:rows].size.to_i32,
    }
  end
  w288_assert(actual == expected_marks, "#{label} mark schedule differs: #{actual.inspect}")
  batches.each do |batch|
    w288_assert(batch[:part_index] == 0, "#{label} part index was #{batch[:part_index]}, expected 0")
    w288_assert(batch[:part_name] == part.name, "#{label} part name differs from the parent candidate")
    w288_assert(batch[:part_path] == part.path, "#{label} callback path differs from its parent candidate")
  end
end

def w288_assert_format!(path : String, format : String, label : String) : Nil
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
  w288_assert(actual == format, "#{label} physical marker family was #{actual}, expected #{format}: #{path}")
end

if ARGV.size < 1 || ARGV.size > 2
  STDERR.puts "usage: crystal run scripts/check_projection_pairs.cr -- <clickhouse-local-store> [database]"
  exit 2
end

store_root = File.realpath(ARGV[0])
database_name = ARGV[1]? || W288_DATABASE
catalog = CrystalClick::OfflineCatalog.open(store_root)
w288_assert(catalog.root == store_root, "catalog root is not the canonical input store")

W288_TABLES.each do |table_name|
  table = catalog.table(database_name, table_name)
  metadata = table.metadata_ddl || raise "#{table_name}: catalog omitted persisted table DDL"
  w288_assert(metadata.includes?("WITH SETTINGS"), "#{table_name}: persisted projection settings were not retained")
  w288_assert(table.projections.any? { |projection| projection.name == W288_PROJECTION },
    "#{table_name}: catalog omitted persisted #{W288_PROJECTION} projection")

  columns = table.columns
  {"id" => "UInt64", "score" => "UInt64", "label" => "String"}.each do |name, type|
    column = columns.find { |entry| entry.name == name } || raise "#{table_name}: missing DDL column #{name}"
    w288_assert(column.type == type, "#{table_name}.#{name} DDL type was #{column.type}, expected #{type}")
  end

  candidates = table.part_candidates
  w288_assert(candidates.size == 1, "#{table_name} has #{candidates.size} parent candidates, expected one")
  part = candidates.first
  w288_assert(part.name == "all_1_1_0", "#{table_name} parent part name was #{part.name}")
  w288_assert(part.row_count == 6_u64, "#{table_name} parent row count was #{part.row_count}, expected six")
  w288_assert(File.realpath(part.path) == part.path, "#{table_name} parent candidate path is not canonical")

  child_path = File.join(part.path, "#{W288_PROJECTION}.proj")
  w288_assert(Dir.exists?(child_path), "#{table_name} is missing its projection child directory")

  expected_parent_format, expected_child_format = if table_name == "compact_parent_wide_child"
                                                    {"Compact", "Wide"}
                                                  else
                                                    {"Wide", "Compact"}
                                                  end
  w288_assert_format!(part.path, expected_parent_format, "#{table_name} parent")
  w288_assert_format!(child_path, expected_child_format, "#{table_name} projection child")

  parent_batches = w288_scan_full(table, false)
  projection_batches = w288_scan_full(table, true)
  w288_assert(w288_rows(parent_batches) == W288_PARENT_ROWS, "#{table_name} parent rows differ from stock literals")
  w288_assert(w288_rows(projection_batches) == W288_PROJECTION_ROWS,
    "#{table_name} projection rows differ from stock sorted literals")
  w288_assert_batches("#{table_name} parent", parent_batches, part, [
    {0_i32, 0_u64, 0_u64, 0_u64, 2_i32},
    {1_i32, 0_u64, 2_u64, 2_u64, 2_i32},
    {2_i32, 0_u64, 4_u64, 4_u64, 2_i32},
  ])
  w288_assert_batches("#{table_name} projection", projection_batches, part, [
    {0_i32, 0_u64, 0_u64, 0_u64, 3_i32},
    {1_i32, 0_u64, 3_u64, 3_u64, 3_i32},
  ])

  parent_window = w288_scan_window(table, false)
  projection_window = w288_scan_window(table, true)
  w288_assert(w288_rows(parent_window) == [W288_PARENT_ROWS[2], W288_PARENT_ROWS[3]],
    "#{table_name} parent [2,4) literal window differs")
  w288_assert(w288_rows(projection_window) == [W288_PROJECTION_ROWS[2], W288_PROJECTION_ROWS[3]],
    "#{table_name} projection [2,4) literal window differs")
  w288_assert_batches("#{table_name} parent window", parent_window, part, [
    {1_i32, 0_u64, 2_u64, 2_u64, 2_i32},
  ])
  w288_assert_batches("#{table_name} projection window", projection_window, part, [
    {0_i32, 2_u64, 2_u64, 2_u64, 1_i32},
    {1_i32, 0_u64, 3_u64, 3_u64, 1_i32},
  ])

  puts "PASS #{table_name}: #{expected_parent_format} parent / #{expected_child_format} child"
  puts "  parent marks: #{parent_batches.map(&.[:rows].size).inspect}; child marks: #{projection_batches.map(&.[:rows].size).inspect}"
  puts "  full rows and [2,4) windows matched; projection batches retained parent identity #{part.name}"
  puts "  parent: #{part.path}"
  puts "  child:  #{child_path}"
end

puts "PASS W288 catalog-native projection pair witness through persisted metadata"
