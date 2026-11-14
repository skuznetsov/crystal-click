require "../src/crystal_click"
require "json"

module MaterializedViewAggregateProjectionW298
  extend self

  FORMAT               = "materialized_view_aggregate_projection_w298_helper_v1"
  W299_FORMAT          = "materialized_view_aggregate_projection_w299_helper_v1"
  DATABASE             = "lab"
  PROJECTION           = "by_group"
  SOURCE_PART          = "all_1_1_0"
  SOURCE_COLUMNS       = ["source_id", "key_a", "key_b", "key_c", "key_d", "value"]
  PARENT_COLUMNS       = ["parent_id", "key_a", "key_b", "key_c", "key_d", "value"]
  AGGREGATES           = ["count()", "sum(value)", "min(value)", "max(value)"]
  PARENT_ROWS_PER_MARK =                      2
  CHILD_ROWS_PER_MARK  =                      2
  WINDOW_START         =                  1_u64
  WINDOW_COUNT         =                  5_u64
  ASYMMETRIC           = 0x0102030405060708_u64

  alias Row = Array(UInt64)
  alias Group = NamedTuple(keys: Array(UInt64), count: UInt64, sum: UInt64, minimum: UInt64, maximum: UInt64)
  alias Target = NamedTuple(name: String, uuid: String, view: String, control: String, control_uuid: String,
    part: String, parent_format: String, child_format: String, order: Array(String))

  KEY_NAMES = ["key_a", "key_b", "key_c", "key_d"]
  TARGETS   = [
    {name: "target_ww", uuid: "f2980000-7b7f-4e2f-9e44-dc13a8788010", view: "view_ww", control: "control_ww",
     control_uuid: "f2980000-7b7f-4e2f-9e44-dc13a8788020", part: SOURCE_PART, parent_format: "Wide",
     child_format: "Wide", order: ["key_a", "key_b", "key_c", "key_d"]},
    {name: "target_wc", uuid: "f2980000-7b7f-4e2f-9e44-dc13a8788011", view: "view_wc", control: "control_wc",
     control_uuid: "f2980000-7b7f-4e2f-9e44-dc13a8788021", part: SOURCE_PART, parent_format: "Wide",
     child_format: "Compact", order: ["key_d", "key_c", "key_b", "key_a"]},
    {name: "target_cw", uuid: "f2980000-7b7f-4e2f-9e44-dc13a8788012", view: "view_cw", control: "control_cw",
     control_uuid: "f2980000-7b7f-4e2f-9e44-dc13a8788022", part: SOURCE_PART, parent_format: "Compact",
     child_format: "Wide", order: ["key_b", "key_d", "key_a", "key_c"]},
    {name: "target_cc", uuid: "f2980000-7b7f-4e2f-9e44-dc13a8788013", view: "view_cc", control: "control_cc",
     control_uuid: "f2980000-7b7f-4e2f-9e44-dc13a8788023", part: SOURCE_PART, parent_format: "Compact",
     child_format: "Compact", order: ["key_c", "key_a", "key_d", "key_b"]},
  ] of Target
  W299_TARGETS = TARGETS.select { |target| target[:child_format] == "Wide" }

  SOURCE_ROWS = [
    [1_u64, 6_u64, 10_u64, 5_u64, 100_u64, 0_u64],
    [2_u64, 6_u64, 10_u64, 5_u64, 100_u64, ASYMMETRIC],
    [3_u64, 6_u64, 10_u64, 5_u64, 200_u64, UInt64::MAX],
    [4_u64, 6_u64, 10_u64, 7_u64, 1_u64, 17_u64],
    [5_u64, 5_u64, 0_u64, 0_u64, 0_u64, 42_u64],
    [6_u64, 6_u64, 11_u64, 0_u64, 0_u64, 23_u64],
    [7_u64, 6_u64, 11_u64, 0_u64, 0_u64, 99_u64],
    [8_u64, 7_u64, 0_u64, 3_u64, 4_u64, 1_u64],
    [9_u64, 7_u64, 0_u64, 3_u64, 4_u64, 2_u64],
    [10_u64, 7_u64, 1_u64, 2_u64, 0_u64, 3_u64],
    [11_u64, 8_u64, 1_u64, 0_u64, 5_u64, 4_u64],
    [12_u64, UInt64::MAX, 0_u64, ASYMMETRIC, 0_u64, ASYMMETRIC],
    [13_u64, UInt64::MAX, 0_u64, ASYMMETRIC, 1_u64, UInt64::MAX],
    [14_u64, UInt64::MAX, 0_u64, UInt64::MAX, 0_u64, 0_u64],
    [15_u64, UInt64::MAX, ASYMMETRIC, 0_u64, 0_u64, 17_u64],
    [16_u64, UInt64::MAX, UInt64::MAX, UInt64::MAX, UInt64::MAX, 42_u64],
  ] of Row
  PARENT_ROWS = SOURCE_ROWS.map { |row| row.map_with_index { |value, index| index == 0 ? value + 100_u64 : value } }

  def run(catalog_root : String, action : String, profile : String = "w298") : JSON::Any
    unless profile == "w298" || profile == "w299"
      raise ArgumentError.new("W298 helper profile must be w298 or w299")
    end
    case action
    when "publish" then publish(catalog_root, profile)
    when "reopen"  then reopen(catalog_root, profile)
    else                raise ArgumentError.new("W298 helper action must be publish or reopen")
    end
  end

  private def publish(catalog_root : String, profile : String) : JSON::Any
    catalog = CrystalClick::OfflineCatalog.open(catalog_root)
    source = catalog.table(DATABASE, "source")
    candidate = source.part_candidates.find { |part| part.name == SOURCE_PART } ||
                raise CrystalClick::InvalidPartError.new("W298 stock source part is absent")
    unless candidate.row_count == SOURCE_ROWS.size.to_u64 && source.columns.map { |column| {column.name, column.type} } == [
             {"source_id", "UInt64"}, {"key_a", "UInt64"}, {"key_b", "UInt64"},
             {"key_c", "UInt64"}, {"key_d", "UInt64"}, {"value", "UInt64"},
           ]
      raise CrystalClick::CorruptPartError.new("W298 source candidate or schema differs")
    end

    targets = profile == "w299" ? W299_TARGETS : TARGETS
    results = targets.map do |target|
      path = if target[:parent_format] == "Wide"
               catalog.transform_materialized_view_part(
                 DATABASE, target[:view], SOURCE_PART, SOURCE_COLUMNS, target[:part],
                 rows_per_mark: PARENT_ROWS_PER_MARK, batch_rows: PARENT_ROWS_PER_MARK,
                 profile: CrystalClick::BinaryBulkProfile.with_size_stream,
               ) do |input|
                 rows = transform_rows(input)
                 wide_output(target, rows, profile == "w299")
               end
             else
               catalog.transform_materialized_view_part(
                 DATABASE, target[:view], SOURCE_PART, SOURCE_COLUMNS, target[:part],
                 mark_format: CrystalClick::CompactMarkFormat::Mrk4,
                 rows_per_mark: PARENT_ROWS_PER_MARK, batch_rows: PARENT_ROWS_PER_MARK,
                 profile: CrystalClick::BinaryBulkProfile.with_size_stream, compress_marks: true,
               ) do |input|
                 rows = transform_rows(input)
                 compact_output(target, rows, profile == "w299")
               end
             end
      expected_path = target_path(catalog_root, target[:uuid], "detached", target[:part])
      unless path == expected_path
        raise CrystalClick::InvalidPartError.new("W298 #{target[:name]} transform destination differs")
      end
      groups = ordered_groups(target[:order])
      {
        "table"            => JSON::Any.new(target[:name]),
        "part"             => JSON::Any.new(target[:part]),
        "parent_format"    => JSON::Any.new(target[:parent_format]),
        "child_format"     => JSON::Any.new(target[:child_format]),
        "keys"             => JSON::Any.new(target[:order].map { |name| JSON::Any.new(name) }),
        "rows"             => nested_u64_json(child_rows(groups)),
        "parent_rows"      => nested_u64_json(PARENT_ROWS),
        "parent_mark_rows" => int_array_json(parent_mark_rows),
        "child_mark_rows"  => int_array_json(child_mark_rows(groups.size.to_i32)),
        "path"             => JSON::Any.new(path),
      } of String => JSON::Any
    end
    JSON::Any.new({
      "format"           => JSON::Any.new(helper_format(profile)),
      "action"           => JSON::Any.new("publish"),
      "status"           => JSON::Any.new("ok"),
      "source_row_count" => JSON::Any.new(SOURCE_ROWS.size),
      "targets"          => JSON::Any.new(results.map { |entry| JSON::Any.new(entry) }),
    } of String => JSON::Any)
  end

  private def reopen(catalog_root : String, profile : String) : JSON::Any
    catalog = CrystalClick::OfflineCatalog.open(catalog_root)
    targets = profile == "w299" ? W299_TARGETS : TARGETS
    results = targets.flat_map do |target|
      [target[:control], target[:name]].map do |table_name|
        expected_part = table_name == target[:control] ? SOURCE_PART : target[:part]
        reopen_pair(catalog, catalog_root, table_name, expected_part, target, profile)
      end
    end
    JSON::Any.new({
      "format" => JSON::Any.new(helper_format(profile)),
      "action" => JSON::Any.new("reopen"),
      "status" => JSON::Any.new("ok"),
      "pairs"  => JSON::Any.new(results),
    } of String => JSON::Any)
  end

  private def reopen_pair(
    catalog : CrystalClick::OfflineCatalog,
    catalog_root : String,
    table_name : String,
    part_name : String,
    target : Target,
    profile : String,
  ) : JSON::Any
    table = catalog.table(DATABASE, table_name)
    candidates = table.part_candidates
    unless candidates.size == 1 && candidates.first.name == part_name && candidates.first.row_count == PARENT_ROWS.size.to_u64
      raise CrystalClick::CorruptPartError.new("W298 #{table_name} offline part identity/count differs")
    end
    part = candidates.first
    expected_path = if table_name == target[:control]
                      target_path(catalog_root, target[:control_uuid], part_name)
                    else
                      target_path(catalog_root, target[:uuid], part_name)
                    end
    unless part.path == expected_path
      raise CrystalClick::InvalidPartError.new("W298 #{table_name} offline part escaped its catalog path")
    end

    groups = ordered_groups(target[:order])
    expected_rows = child_rows(groups)
    full_parent, parent_grid, parent_identity = scan_parent(table, part, nil)
    parent_window, parent_window_grid, _ = scan_parent(table, part, {WINDOW_START, WINDOW_COUNT})
    full_child, child_grid, child_identity, child_states = scan_child(table, part, target, nil)
    child_window, child_window_grid, _, window_states = scan_child(table, part, target, {WINDOW_START, WINDOW_COUNT})
    expected_state_hex = state_hex(groups)
    expected_window_hex = expected_state_hex.transform_values { |values| values[1, WINDOW_COUNT.to_i] }
    expected_parent_window = PARENT_ROWS[1, WINDOW_COUNT.to_i]
    expected_child_marks = child_mark_rows(groups.size.to_i32)
    expected_window_grid = [1, 2, 2]

    unless full_parent == PARENT_ROWS && parent_grid == parent_mark_rows && parent_window == expected_parent_window &&
           parent_window_grid == expected_window_grid && full_child == expected_rows && child_grid == expected_child_marks &&
           child_window == expected_rows[1, WINDOW_COUNT.to_i] && child_window_grid == expected_window_grid &&
           child_states == expected_state_hex && window_states == expected_window_hex &&
           parent_identity == identity_for(part) && child_identity == identity_for(part)
      raise CrystalClick::CorruptPartError.new("W298 #{table_name} offline parent, child, window, or state bytes differ")
    end
    result = {
      "table"                   => JSON::Any.new(table_name),
      "parent_format"           => JSON::Any.new(target[:parent_format]),
      "child_format"            => JSON::Any.new(target[:child_format]),
      "child_rows"              => nested_u64_json(full_child),
      "child_state_hex"         => state_hex_json(child_states),
      "child_window_rows"       => nested_u64_json(child_window),
      "child_window_state_hex"  => state_hex_json(window_states),
      "parent_mark_rows"        => int_array_json(parent_grid),
      "child_mark_rows"         => int_array_json(child_grid),
      "window_parent_mark_rows" => int_array_json(parent_window_grid),
      "window_child_mark_rows"  => int_array_json(child_window_grid),
      "path"                    => JSON::Any.new(part.path),
    } of String => JSON::Any
    if profile == "w299"
      method = table_name == target[:control] ? CrystalClick::CompressedBlock::METHOD_ZSTD : CrystalClick::CompressedBlock::METHOD_LZ4
      result["mark_witness"] = compressed_wide_mark_witness(File.join(part.path, "#{PROJECTION}.proj"), method)
    end
    JSON::Any.new(result)
  end

  private def compressed_wide_mark_witness(child_path : String, expected_method : UInt8) : JSON::Any
    names = Dir.children(child_path).sort!
    marks = names.select(&.ends_with?(".cmrk2"))
    if marks.size != 8 || marks.any? { |name| !/\A[0-9a-f]{32}\.cmrk2\z/.matches?(name) } ||
       names.any?(&.ends_with?(".mrk2"))
      raise CrystalClick::CorruptPartError.new("W299 compressed Wide child has a mixed or incomplete mark roster")
    end

    checksums = CrystalClick::PartChecksums.open(child_path)
    lanes = marks.map do |name|
      physical = File.read(File.join(child_path, name)).to_slice
      canonical = CrystalClick::CompressedBlock.decode_all(physical)
      entry = checksums.entry(name).not_nil!
      method = physical[CrystalClick::CompressedBlock::CHECKSUM_SIZE]
      unless method == expected_method && entry.compressed && entry.physical_size == physical.size.to_u64 &&
             entry.file_hash == CrystalClick::CityHashV1.file_hash(physical) &&
             entry.uncompressed_size == canonical.size.to_u64 &&
             entry.uncompressed_hash == CrystalClick::CityHashV1.file_hash(canonical) &&
             canonical.size == 8 * CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE
        raise CrystalClick::CorruptPartError.new("W299 compressed Wide child mark codec, checksum or 192-byte lane differs")
      end
      JSON::Any.new({
        "name"            => JSON::Any.new(name),
        "physical_size"   => JSON::Any.new(physical.size),
        "method"          => JSON::Any.new(method.to_i),
        "canonical_bytes" => JSON::Any.new(canonical.size),
        "records"         => JSON::Any.new(canonical.size // CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE),
      } of String => JSON::Any)
    end
    JSON::Any.new({
      "mark_files"               => JSON::Any.new(marks.map { |name| JSON::Any.new(name) }),
      "lane_count"               => JSON::Any.new(lanes.size),
      "canonical_bytes_per_lane" => JSON::Any.new(8 * CrystalClick::CompressedMarkWriter::MARK_RECORD_SIZE),
      "method"                   => JSON::Any.new(expected_method.to_i),
      "lanes"                    => JSON::Any.new(lanes),
    } of String => JSON::Any)
  end

  private def transform_rows(input : CrystalClick::OfflinePartTransformInput) : Array(Row)
    unless input.row_count == SOURCE_ROWS.size.to_u64 && input.column_names == SOURCE_COLUMNS
      raise CrystalClick::CorruptPartError.new("W298 source callback identity/schema differs")
    end
    observed = [] of Row
    output = [] of Row
    input.each_batch do |batch|
      columns = SOURCE_COLUMNS.map { |name| batch.values_for(name, UInt64) }
      unless columns.all? { |column| column.size == columns.first.size }
        raise CrystalClick::CorruptPartError.new("W298 source callback columns are not aligned")
      end
      columns.first.each_index do |index|
        row = columns.map { |column| column[index] }
        unless SOURCE_ROWS[observed.size]? == row
          raise CrystalClick::CorruptPartError.new("W298 source literal differs at row #{observed.size}")
        end
        observed << row
        output << row.map_with_index { |value, position| position == 0 ? value + 100_u64 : value }
      end
    end
    unless observed == SOURCE_ROWS && output == PARENT_ROWS
      raise CrystalClick::CorruptPartError.new("W298 callback did not complete the exact row transform")
    end
    output
  end

  private def wide_output(target : Target, rows : Array(Row), compress_wide_marks : Bool) : CrystalClick::WidePartTransformOutput
    groups = ordered_groups(target[:order], rows)
    projection = projection_output(target, groups, compress_wide_marks)
    ids = rows.map(&.[0])
    columns = Array(CrystalClick::WidePartColumn).new
    PARENT_COLUMNS.each_with_index do |name, index|
      next if index == 0
      columns << wide_u64(name, rows.map { |row| row[index] })
    end
    CrystalClick::WidePartTransformOutput.new(
      ids.to_unsafe.to_slice(ids.size), columns,
      projections: [projection] of (CrystalClick::WidePartProjection | CrystalClick::CompactPartProjection),
    )
  end

  private def compact_output(target : Target, rows : Array(Row), compress_wide_marks : Bool) : CrystalClick::CompactPartTransformOutput
    groups = ordered_groups(target[:order], rows)
    projection = projection_output(target, groups, compress_wide_marks)
    ids = rows.map(&.[0])
    columns = Array(CrystalClick::CompactPartColumn).new
    PARENT_COLUMNS.each_with_index do |name, index|
      next if index == 0
      columns << compact_u64(name, rows.map { |row| row[index] })
    end
    CrystalClick::CompactPartTransformOutput.new(
      ids.to_unsafe.to_slice(ids.size), columns,
      projections: [projection] of (CrystalClick::WidePartProjection | CrystalClick::CompactPartProjection),
    )
  end

  private def projection_output(
    target : Target,
    groups : Array(Group),
    compress_wide_marks : Bool,
  ) : CrystalClick::WidePartProjection | CrystalClick::CompactPartProjection
    if target[:child_format] == "Wide"
      CrystalClick::WidePartProjection.precomputed_aggregate(
        PROJECTION, target[:order], key_slices(groups, target[:order]), aggregate_columns(groups),
        rows_per_mark: CHILD_ROWS_PER_MARK, compress_marks: compress_wide_marks,
      )
    else
      CrystalClick::CompactPartProjection.precomputed_aggregate(
        PROJECTION, target[:order], key_slices(groups, target[:order]), aggregate_columns(groups),
        rows_per_mark: CHILD_ROWS_PER_MARK, frame_bytes: 4096, compress_marks: target[:parent_format] == "Compact",
      )
    end
  end

  private def helper_format(profile : String) : String
    profile == "w299" ? W299_FORMAT : FORMAT
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

  private def ordered_groups(order : Array(String), rows : Array(Row) = PARENT_ROWS) : Array(Group)
    stats = Hash(Array(UInt64), AggregateStats).new
    rows.each do |row|
      keys = KEY_NAMES.map { |name| row[1 + KEY_NAMES.index(name).not_nil!] }
      if current = stats[keys]?
        current.add(row[5])
      else
        stats[keys] = AggregateStats.new(row[5])
      end
    end
    ordered = stats.map do |source_keys, value|
      keys = order.map { |name| source_keys[KEY_NAMES.index(name).not_nil!] }
      {keys: keys, count: value.count, sum: value.sum, minimum: value.minimum, maximum: value.maximum}
    end
    ordered.sort! { |left, right| compare_keys(left[:keys], right[:keys]) }
    ordered
  end

  private def compare_keys(left : Array(UInt64), right : Array(UInt64)) : Int32
    left.each_index do |index|
      order = left[index] <=> right[index]
      return order unless order.zero?
    end
    0
  end

  private def key_slices(groups : Array(Group), order : Array(String)) : Array(Slice(UInt64))
    columns = Array(Slice(UInt64)).new(order.size)
    order.each_index do |index|
      values = groups.map { |group| group[:keys][index] }
      columns << values.to_unsafe.to_slice(values.size)
    end
    columns
  end

  private def aggregate_columns(groups : Array(Group)) : Array(CrystalClick::WidePartProjectionAggregate)
    AGGREGATES.map do |name|
      values = groups.map do |group|
        case name
        when "count()"    then group[:count]
        when "sum(value)" then group[:sum]
        when "min(value)" then group[:minimum]
        when "max(value)" then group[:maximum]
        else                   raise CrystalClick::UnsupportedFormatError.new("W298 aggregate is unsupported")
        end
      end
      slice = values.to_unsafe.to_slice(values.size)
      case name
      when "count()"    then CrystalClick::WidePartProjectionAggregate.count(slice)
      when "sum(value)" then CrystalClick::WidePartProjectionAggregate.sum_uint64("value", slice)
      when "min(value)" then CrystalClick::WidePartProjectionAggregate.min_uint64("value", slice)
      when "max(value)" then CrystalClick::WidePartProjectionAggregate.max_uint64("value", slice)
      else                   raise CrystalClick::UnsupportedFormatError.new("W298 aggregate is unsupported")
      end
    end
  end

  private def child_rows(groups : Array(Group)) : Array(Array(UInt64))
    groups.map do |group|
      group[:keys] + [group[:count], group[:sum], group[:minimum], group[:maximum]]
    end
  end

  private def scan_parent(
    table : CrystalClick::OfflineTable,
    part : CrystalClick::OfflinePartCandidate,
    window : Tuple(UInt64, UInt64)?,
  ) : {Array(Row), Array(Int32), Hash(String, String)}
    rows = [] of Row
    grid = [] of Int32
    identity = identity_for(part)
    callback = ->(batch : CrystalClick::WidePartTableBatch) do
      observe_identity!(identity, batch)
      columns = PARENT_COLUMNS.map { |name| batch.values_for(name, UInt64) }
      unless columns.all? { |column| column.size == columns.first.size }
        raise CrystalClick::CorruptPartError.new("W298 parent callback columns are not aligned")
      end
      columns.first.each_index { |index| rows << columns.map { |column| column[index] } }
      grid << columns.first.size.to_i32
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
    target : Target,
    window : Tuple(UInt64, UInt64)?,
  ) : {Array(Array(UInt64)), Array(Int32), Hash(String, String), Hash(String, Array(String))}
    rows = [] of Array(UInt64)
    grid = [] of Int32
    encoded = Hash(String, Array(String)).new
    AGGREGATES.each { |name| encoded[name] = [] of String }
    identity = identity_for(part)
    columns = target[:order] + AGGREGATES
    callback = ->(batch : CrystalClick::WidePartTableBatch) do
      observe_identity!(identity, batch)
      key_columns = target[:order].map { |name| batch.values_for(name, UInt64) }
      state_columns = Hash(String, Array(UInt64)).new
      AGGREGATES.each do |name|
        values, bytes = read_state_column(batch, name)
        unless values.size == key_columns.first.size
          raise CrystalClick::CorruptPartError.new("W298 key and aggregate state rows are not aligned")
        end
        state_columns[name] = values
        encoded[name].concat(bytes)
      end
      key_columns.first.each_index do |index|
        row = key_columns.map { |column| column[index] }
        AGGREGATES.each { |name| row << state_columns[name][index] }
        rows << row
      end
      grid << key_columns.first.size.to_i32
      nil
    end
    if range = window
      table.scan_projection_typed_window(PROJECTION, columns, range[0], range[1], &callback)
    else
      table.scan_projection_typed(PROJECTION, columns, batch_rows: CHILD_ROWS_PER_MARK, &callback)
    end
    {rows, grid, identity, encoded}
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
                    else                   raise CrystalClick::UnsupportedFormatError.new("W298 aggregate state is unsupported")
                    end
    values = [] of UInt64
    bytes_by_row = [] of String
    batch.binary_bulk_values_for(name).each do |state|
      bytes = state.aggregate_function_state_bytes
      if name == "sum(value)"
        unless state.type.name == expected_type && bytes.size == 8
          raise CrystalClick::CorruptPartError.new("W298 sum state type or byte length differs")
        end
        values << IO::Memory.new(bytes).read_bytes(UInt64, IO::ByteFormat::LittleEndian)
      else
        unless state.type.name == expected_type && bytes.size == 9 && bytes[0] == 1_u8
          raise CrystalClick::CorruptPartError.new("W298 extremum state type or byte length differs")
        end
        values << IO::Memory.new(bytes[1, 8]).read_bytes(UInt64, IO::ByteFormat::LittleEndian)
      end
      bytes_by_row << bytes.hexstring
    end
    {values, bytes_by_row}
  end

  private def state_hex(groups : Array(Group)) : Hash(String, Array(String))
    {
      "count()"    => groups.map { |group| varuint(group[:count]).hexstring },
      "sum(value)" => groups.map { |group| u64_le(group[:sum]).hexstring },
      "min(value)" => groups.map { |group| extremum_bytes(group[:minimum]).hexstring },
      "max(value)" => groups.map { |group| extremum_bytes(group[:maximum]).hexstring },
    }
  end

  private def varuint(value : UInt64) : Bytes
    io = IO::Memory.new
    remaining = value
    loop do
      byte = (remaining & 0x7f_u64).to_u8
      remaining >>= 7
      io.write_byte(remaining.zero? ? byte : (byte | 0x80_u8))
      break if remaining.zero?
    end
    io.to_slice
  end

  private def u64_le(value : UInt64) : Bytes
    io = IO::Memory.new
    io.write_bytes(value, IO::ByteFormat::LittleEndian)
    io.to_slice
  end

  private def extremum_bytes(value : UInt64) : Bytes
    io = IO::Memory.new
    io.write_byte(1_u8)
    io.write_bytes(value, IO::ByteFormat::LittleEndian)
    io.to_slice
  end

  private def child_mark_rows(count : Int32) : Array(Int32)
    Array.new((count + CHILD_ROWS_PER_MARK - 1) // CHILD_ROWS_PER_MARK) { |index|
      Math.min(count - index * CHILD_ROWS_PER_MARK, CHILD_ROWS_PER_MARK).to_i32
    }
  end

  private def parent_mark_rows : Array(Int32)
    Array.new((PARENT_ROWS.size + PARENT_ROWS_PER_MARK - 1) // PARENT_ROWS_PER_MARK) { |index|
      Math.min(PARENT_ROWS.size - index * PARENT_ROWS_PER_MARK, PARENT_ROWS_PER_MARK).to_i32
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

  private def observe_identity!(identity : Hash(String, String), batch : CrystalClick::WidePartTableBatch) : Nil
    unless identity == {"part_name" => batch.part_name, "part_path" => batch.part_path}
      raise CrystalClick::CorruptPartError.new("W298 callback identity differs from selected part")
    end
  end

  private def identity_for(part : CrystalClick::OfflinePartCandidate) : Hash(String, String)
    {"part_name" => part.name, "part_path" => part.path}
  end

  private def target_path(root : String, uuid : String, *parts : String) : String
    File.join(root, "store", uuid[0, 3], uuid, *parts)
  end

  private def nested_u64_json(rows : Array(Array(UInt64))) : JSON::Any
    JSON::Any.new(rows.map { |row| JSON::Any.new(row.map { |value| JSON::Any.new(value.to_s) }) })
  end

  private def int_array_json(values : Array(Int32)) : JSON::Any
    JSON::Any.new(values.map { |value| JSON::Any.new(value) })
  end

  private def state_hex_json(values : Hash(String, Array(String))) : JSON::Any
    JSON::Any.new(values.to_h { |name, entries| {name, JSON::Any.new(entries.map { |value| JSON::Any.new(value) })} })
  end
end

if !(2..3).includes?(ARGV.size) || !["publish", "reopen"].includes?(ARGV[1]) ||
   (ARGV.size == 3 && !["w298", "w299"].includes?(ARGV[2]))
  STDERR.puts "usage: w298-helper CATALOG_ROOT publish|reopen [w298|w299]"
  exit 2
end

begin
  profile = ARGV[2]? || "w298"
  puts MaterializedViewAggregateProjectionW298.run(ARGV[0], ARGV[1], profile).to_json
rescue error
  STDERR.puts "W298/W299 helper failed: #{error.class}: #{error.message}"
  exit 1
end
