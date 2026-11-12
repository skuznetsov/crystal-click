require "../src/crystal_click"
require "json"

# W290 transform fixture: the source and output literals are independently
# stated here and in the Ruby driver. The callback filters two source rows,
# then maps and rekeys the remaining six before constructing projection
# children with their own three-row granule schedule.
module MaterializedViewProjectionTransformW290
  extend self

  FORMAT              = "materialized_view_projection_transform_w290_helper_v1"
  DATABASE            = "lab"
  PROJECTION          = "by_score"
  SOURCE_PART         = "all_1_1_0"
  COMPACT_PART        = "all_9_9_0"
  WIDE_PART           = "all_10_10_0"
  SOURCE_COLUMNS      = ["id", "score", "label"]
  PARENT_COLUMNS      = ["id", "score", "label"]
  PROJECTION_COLUMNS  = ["score", "id", "label"]
  COMPACT_TARGET_UUID = "f2900000-7b7f-4e2f-9e44-dc13a87b8803"
  WIDE_TARGET_UUID    = "f2900000-7b7f-4e2f-9e44-dc13a87b8804"

  SOURCE_ROWS = [
    {1_u64, 50_u64, "a\0b"},
    {2_u64, 10_u64, ""},
    {3_u64, 40_u64, "café"},
    {4_u64, 20_u64, "z\0"},
    {5_u64, 60_u64, "é"},
    {6_u64, 30_u64, "hi"},
    {7_u64, 70_u64, "drop-seven"},
    {8_u64, 80_u64, "drop-eight"},
  ]

  OUTPUT_ROWS = [
    {101_u64, 1_050_u64, "a\0b!"},
    {102_u64, 1_010_u64, "!"},
    {103_u64, 1_040_u64, "café!"},
    {104_u64, 1_020_u64, "z\0!"},
    {105_u64, 1_060_u64, "é!"},
    {106_u64, 1_030_u64, "hi!"},
  ]

  alias Row = Tuple(UInt64, UInt64, String)
  alias TypeRow = Tuple(String, String)

  def run(catalog_root : String, action : String, compact_part : String = COMPACT_PART, wide_part : String = WIDE_PART) : JSON::Any
    case action
    when "publish"
      publish(catalog_root)
    when "reopen"
      reopen(catalog_root, compact_part, wide_part)
    else
      raise ArgumentError.new("W290 action must be publish or reopen")
    end
  end

  private def publish(catalog_root : String) : JSON::Any
    catalog = CrystalClick::OfflineCatalog.open(catalog_root)
    source = catalog.table(DATABASE, "source")
    source_candidate = source.part_candidates.find { |part| part.name == SOURCE_PART } ||
                       raise CrystalClick::InvalidPartError.new("W290 stock source part is absent")
    source_columns = source.columns.map { |column| {column.name, column.type} }
    unless source_candidate.row_count == SOURCE_ROWS.size.to_u64 && source_columns == [
             {"id", "UInt64"}, {"score", "UInt64"}, {"label", "String"},
           ]
      raise CrystalClick::CorruptPartError.new("W290 source candidate or exact schema differs")
    end

    compact_destination = catalog.transform_materialized_view_part(
      DATABASE, "view_compact", SOURCE_PART, SOURCE_COLUMNS, COMPACT_PART,
      mark_format: CrystalClick::CompactMarkFormat::Mrk4,
      rows_per_mark: 2,
      batch_rows: 2,
      profile: CrystalClick::BinaryBulkProfile.with_size_stream,
    ) do |input|
      rows = transform_rows(input)
      unless rows == OUTPUT_ROWS
        raise CrystalClick::CorruptPartError.new("W290 Compact callback literals differ")
      end
      compact_parent_output(rows)
    end

    wide_destination = catalog.transform_materialized_view_part(
      DATABASE, "view_wide", SOURCE_PART, SOURCE_COLUMNS, WIDE_PART,
      rows_per_mark: 2,
      batch_rows: 2,
      profile: CrystalClick::BinaryBulkProfile.with_size_stream,
    ) do |input|
      rows = transform_rows(input)
      unless rows == OUTPUT_ROWS
        raise CrystalClick::CorruptPartError.new("W290 Wide callback literals differ")
      end
      wide_parent_output(rows)
    end

    expected_compact = target_path(catalog_root, COMPACT_TARGET_UUID, "detached", COMPACT_PART)
    expected_wide = target_path(catalog_root, WIDE_TARGET_UUID, "detached", WIDE_PART)
    unless compact_destination == expected_compact && wide_destination == expected_wide
      raise CrystalClick::InvalidPartError.new("W290 transform destination differs from the resolved target")
    end

    JSON::Any.new({
      "format"                  => JSON::Any.new(FORMAT),
      "action"                  => JSON::Any.new("publish"),
      "status"                  => JSON::Any.new("ok"),
      "source_part_name"        => JSON::Any.new(SOURCE_PART),
      "source_row_count"        => JSON::Any.new(SOURCE_ROWS.size),
      "filtered_source_row_ids" => JSON::Any.new([7, 8].map { |id| JSON::Any.new(id) }),
      "output_row_count"        => JSON::Any.new(OUTPUT_ROWS.size),
      "output_rows"             => rows_json(OUTPUT_ROWS),
      "parent_mark_rows"        => JSON::Any.new([2, 2, 2].map { |rows| JSON::Any.new(rows) }),
      "child_mark_rows"         => JSON::Any.new([3, 3].map { |rows| JSON::Any.new(rows) }),
      "compact_parent_path"     => JSON::Any.new(compact_destination),
      "wide_parent_path"        => JSON::Any.new(wide_destination),
      "projection_name"         => JSON::Any.new(PROJECTION),
      "projection_columns"      => string_array_json(PROJECTION_COLUMNS),
      "parent_columns"          => string_array_json(PARENT_COLUMNS),
    } of String => JSON::Any)
  end

  private def reopen(catalog_root : String, compact_part_name : String, wide_part_name : String) : JSON::Any
    {compact_part_name, wide_part_name}.each do |name|
      unless /\A[a-zA-Z0-9_-]+\z/.matches?(name) && name.includes?('_')
        raise CrystalClick::InvalidPartError.new("W290 attached part identity is malformed")
      end
    end
    catalog = CrystalClick::OfflineCatalog.open(catalog_root)
    pairs = [
      {"target_compact", compact_part_name, "Compact", "Wide", COMPACT_TARGET_UUID},
      {"target_wide", wide_part_name, "Wide", "Compact", WIDE_TARGET_UUID},
    ]
    pair_json = pairs.map do |table_name, part_name, parent_format, child_format, target_uuid|
      table = catalog.table(DATABASE, table_name)
      metadata = table.metadata_ddl || raise CrystalClick::CorruptPartError.new("W290 #{table_name} metadata is absent")
      normalized_metadata = metadata.gsub(/\s+/, " ")
      normalized_projection = table.projections.map do |projection|
        {projection.name, projection.definition.gsub(/\s+/, " ").strip}
      end
      unless table.columns.map { |column| {column.name, column.type} } == [
               {"id", "UInt64"}, {"score", "UInt64"}, {"label", "String"},
             ] && normalized_projection == [
               {PROJECTION, "SELECT score, id, label ORDER BY score"},
             ] && normalized_metadata.includes?("WITH SETTINGS (index_granularity = 3)")
        raise CrystalClick::CorruptPartError.new("W290 #{table_name} persisted schema/projection DDL differs")
      end

      candidates = table.part_candidates
      unless candidates.size == 1 && candidates.first.name == part_name && candidates.first.row_count == OUTPUT_ROWS.size.to_u64
        raise CrystalClick::CorruptPartError.new("W290 #{table_name} candidate identity/count differs")
      end
      part = candidates.first
      unless part.path == target_path(catalog_root, target_uuid, part_name)
        raise CrystalClick::InvalidPartError.new("W290 #{table_name} candidate escaped its catalog table directory")
      end

      child_path = File.join(part.path, "#{PROJECTION}.proj")
      assert_format!(part.path, parent_format, "#{table_name} parent")
      assert_format!(child_path, child_format, "#{table_name} child")

      parent, parent_grid = scan_rows(table, part, false, nil, 2)
      projection, projection_grid = scan_rows(table, part, true, nil, 3)
      expected_projection = OUTPUT_ROWS.sort_by(&.[1])
      unless parent == OUTPUT_ROWS && projection == expected_projection &&
             parent_grid == [2, 2, 2] && projection_grid == [3, 3]
        raise CrystalClick::CorruptPartError.new("W290 #{table_name} full parent/projection scan differs")
      end

      parent_window, parent_window_grid = scan_rows(table, part, false, 2_u64, 2)
      projection_window, projection_window_grid = scan_rows(table, part, true, 2_u64, 2)
      unless parent_window == OUTPUT_ROWS[2, 2] && projection_window == expected_projection[2, 2] &&
             parent_window_grid == [2] && projection_window_grid == [1, 1]
        raise CrystalClick::CorruptPartError.new("W290 #{table_name} [2,4) catalog window differs")
      end

      JSON::Any.new({
        "table"                   => JSON::Any.new(table_name),
        "part_name"               => JSON::Any.new(part.name),
        "row_count"               => JSON::Any.new(part.row_count.to_i64),
        "parent_format"           => JSON::Any.new(parent_format),
        "child_format"            => JSON::Any.new(child_format),
        "parent_rows"             => rows_json(parent),
        "projection_rows"         => rows_json(projection),
        "parent_mark_rows"        => int_array_json(parent_grid),
        "child_mark_rows"         => int_array_json(projection_grid),
        "parent_window_rows_2_4"  => rows_json(parent_window),
        "child_window_rows_2_4"   => rows_json(projection_window),
        "parent_window_mark_rows" => int_array_json(parent_window_grid),
        "child_window_mark_rows"  => int_array_json(projection_window_grid),
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

  private def transform_rows(input : CrystalClick::OfflinePartTransformInput) : Array(Row)
    unless input.row_count == SOURCE_ROWS.size.to_u64 && input.column_names == SOURCE_COLUMNS &&
           input.column_types == [{"id", "UInt64"}, {"score", "UInt64"}, {"label", "String"}]
      raise CrystalClick::CorruptPartError.new("W290 callback source identity/schema differs")
    end

    observed = [] of Row
    output = [] of Row
    input.each_batch do |batch|
      ids = batch.values_for("id", UInt64)
      scores = batch.values_for("score", UInt64)
      labels = batch.strings_for("label")
      unless ids.size == scores.size && scores.size == labels.size
        raise CrystalClick::CorruptPartError.new("W290 callback source columns are not row-aligned")
      end
      ids.each_index do |index|
        source_row = {ids[index], scores[index], labels[index].dup}
        expected = SOURCE_ROWS[observed.size]?
        unless expected && source_row == expected
          raise CrystalClick::CorruptPartError.new("W290 callback source literal differs at row #{observed.size}")
        end
        observed << source_row
        next if ids[index] > 6_u64
        output << {ids[index] + 100_u64, scores[index] + 1_000_u64, labels[index] + "!"}
      end
    end

    unless observed == SOURCE_ROWS && output == OUTPUT_ROWS
      raise CrystalClick::CorruptPartError.new("W290 callback did not complete the filter/map/rekey oracle")
    end
    output
  end

  private def compact_parent_output(rows : Array(Row)) : CrystalClick::CompactPartTransformOutput
    ids = rows.map(&.[0])
    scores = rows.map(&.[1])
    labels = rows.map(&.[2])
    sorted = rows.sort_by(&.[1])
    child_scores = sorted.map(&.[1])
    child_ids = sorted.map(&.[0])
    child_labels = sorted.map(&.[2])

    child = CrystalClick::WidePartProjection.precomputed(
      PROJECTION,
      "score",
      child_scores.to_unsafe.to_slice(child_scores.size),
      [wide_u64("id", child_ids, 3), wide_string("label", child_labels, 3)] of CrystalClick::WidePartColumn,
      rows_per_mark: 3,
    )
    projections = [child] of (CrystalClick::WidePartProjection | CrystalClick::CompactPartProjection)
    CrystalClick::CompactPartTransformOutput.new(
      ids.to_unsafe.to_slice(ids.size),
      [compact_u64("score", scores, 2), compact_string("label", labels, 2)] of CrystalClick::CompactPartColumn,
      projections: projections,
    )
  end

  private def wide_parent_output(rows : Array(Row)) : CrystalClick::WidePartTransformOutput
    ids = rows.map(&.[0])
    scores = rows.map(&.[1])
    labels = rows.map(&.[2])
    sorted = rows.sort_by(&.[1])
    child_scores = sorted.map(&.[1])
    child_ids = sorted.map(&.[0])
    child_labels = sorted.map(&.[2])

    child = CrystalClick::CompactPartProjection.precomputed(
      PROJECTION,
      "score",
      child_scores.to_unsafe.to_slice(child_scores.size),
      [compact_u64("id", child_ids, 3), compact_string("label", child_labels, 3)] of CrystalClick::CompactPartColumn,
      rows_per_mark: 3,
      mark_format: CrystalClick::CompactMarkFormat::Mrk4,
      compress_marks: false,
      profile: CrystalClick::BinaryBulkProfile.single_stream,
    )
    projections = [child] of (CrystalClick::WidePartProjection | CrystalClick::CompactPartProjection)
    CrystalClick::WidePartTransformOutput.new(
      ids.to_unsafe.to_slice(ids.size),
      [wide_u64("score", scores, 2), wide_string("label", labels, 2)] of CrystalClick::WidePartColumn,
      projections: projections,
    )
  end

  private def grouped(values : Array(CrystalClick::BinaryValue), rows_per_mark : Int32) : Array(Array(CrystalClick::BinaryValue))
    values.each_slice(rows_per_mark).map do |slice|
      slice.to_a
    end.to_a
  end

  private def u64_values(values : Array(UInt64)) : Array(CrystalClick::BinaryValue)
    values.map { |value| CrystalClick::BinaryValue.uint64(value) }
  end

  private def string_values(values : Array(String)) : Array(CrystalClick::BinaryValue)
    values.map { |value| CrystalClick::BinaryValue.string(value) }
  end

  private def wide_u64(name : String, values : Array(UInt64), rows_per_mark : Int32) : CrystalClick::WidePartColumn
    CrystalClick::WidePartColumn.binary_bulk(
      name, CrystalClick::BinaryDataType.primitive("UInt64"), grouped(u64_values(values), rows_per_mark),
    )
  end

  private def wide_string(name : String, values : Array(String), rows_per_mark : Int32) : CrystalClick::WidePartColumn
    CrystalClick::WidePartColumn.binary_bulk(
      name, CrystalClick::BinaryDataType.primitive("String"), grouped(string_values(values), rows_per_mark),
    )
  end

  private def compact_u64(name : String, values : Array(UInt64), rows_per_mark : Int32) : CrystalClick::CompactPartColumn
    CrystalClick::CompactPartColumn.binary_bulk(
      name, CrystalClick::BinaryDataType.primitive("UInt64"), grouped(u64_values(values), rows_per_mark),
    )
  end

  private def compact_string(name : String, values : Array(String), rows_per_mark : Int32) : CrystalClick::CompactPartColumn
    CrystalClick::CompactPartColumn.binary_bulk(
      name, CrystalClick::BinaryDataType.primitive("String"), grouped(string_values(values), rows_per_mark),
    )
  end

  private def scan_rows(
    table : CrystalClick::OfflineTable,
    expected_candidate : CrystalClick::OfflinePartCandidate,
    projection : Bool,
    start_row : UInt64?,
    batch_rows : Int32,
  ) : {Array(Row), Array(Int32)}
    rows = [] of Row
    grid = [] of Int32
    callback = ->(batch : CrystalClick::WidePartTableBatch) do
      expected_index = table.part_candidates.index do |candidate|
        candidate.name == expected_candidate.name && candidate.path == expected_candidate.path
      end ||
                       raise CrystalClick::InvalidPartError.new("W290 reopen candidate identity disappeared")
      unless batch.part_name == expected_candidate.name && batch.part_path == expected_candidate.path &&
             batch.part_index == expected_index
        raise CrystalClick::CorruptPartError.new("W290 catalog batch candidate name/path/index differs")
      end
      ids = batch.values_for("id", UInt64)
      scores = batch.values_for("score", UInt64)
      labels = batch.strings_for("label")
      unless ids.size == scores.size && scores.size == labels.size
        raise CrystalClick::CorruptPartError.new("W290 catalog batch columns are not row-aligned")
      end
      ids.each_index { |index| rows << {ids[index], scores[index], labels[index].dup} }
      grid << ids.size.to_i32
      nil
    end

    if projection
      if start = start_row
        table.scan_projection_typed_window(PROJECTION, PROJECTION_COLUMNS, start, batch_rows, &callback)
      else
        table.scan_projection_typed(PROJECTION, PROJECTION_COLUMNS, batch_rows: batch_rows, &callback)
      end
    elsif start = start_row
      table.scan_typed_window(PARENT_COLUMNS, start, batch_rows, &callback)
    else
      table.scan_typed(PARENT_COLUMNS, batch_rows: batch_rows, &callback)
    end
    {rows, grid}
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
      raise CrystalClick::CorruptPartError.new("W290 #{label} marker family was #{actual}, expected #{format}")
    end
  end

  private def target_path(root : String, uuid : String, *parts : String) : String
    File.join(root, "store", uuid[0, 3], uuid, *parts)
  end

  private def rows_json(rows : Array(Row)) : JSON::Any
    JSON::Any.new(rows.map do |row|
      JSON::Any.new([JSON::Any.new(row[0].to_i64), JSON::Any.new(row[1].to_i64), JSON::Any.new(row[2])])
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
  STDERR.puts "usage: materialized-view-projection-transform-w290-helper CATALOG_ROOT publish|reopen [COMPACT_PART WIDE_PART]"
  exit 2
end

begin
  compact_part = ARGV[2]? || MaterializedViewProjectionTransformW290::COMPACT_PART
  wide_part = ARGV[3]? || MaterializedViewProjectionTransformW290::WIDE_PART
  puts MaterializedViewProjectionTransformW290.run(ARGV[0], ARGV[1], compact_part, wide_part).to_json
rescue error
  STDERR.puts "W290 helper failed: #{error.class}: #{error.message}"
  exit 1
end
