require "../src/crystal_click"
require "json"
require "./support/dynamic_recursive_handoff_w249_fixture"

module CheckDynamicRecursiveHandoffW249
  extend self

  FORMAT    = "dynamic_recursive_handoff_w249_helper_v1"
  CONSUMERS = ["direct_reader", "table_full_scan", "table_window", "table_candidate_marks", "offline_values"]

  private def fail!(message : String) : NoReturn
    raise CrystalClick::CorruptPartError.new("W249 helper: #{message}")
  end

  private def require!(condition : Bool, message : String) : Nil
    fail!(message) unless condition
  end

  private def json_array(values : Array(String)) : JSON::Any
    JSON::Any.new(values.map { |value| JSON::Any.new(value) })
  end

  private def json_rows(rows : Array(JSON::Any)?) : JSON::Any
    rows ? JSON::Any.new(rows) : JSON::Any.new(nil)
  end

  private def read_direct(part : String) : NamedTuple(
    profile: String,
    keys: Array(UInt64),
    mark_row_counts: Array(UInt64),
    values: Hash(String, Array(CrystalClick::BinaryValue)),
    rows: Array(JSON::Any),
  )
    keys = CrystalClick::WidePart.open_typed(part, DynamicRecursiveHandoffW249Fixture::KEY_NAME).read_uint64
    require!(keys == DynamicRecursiveHandoffW249Fixture::KEYS, "direct key values differ from the frozen five-row fixture")
    values = Hash(String, Array(CrystalClick::BinaryValue)).new
    profiles = [] of String
    marks = [] of UInt64
    DynamicRecursiveHandoffW249Fixture::TARGET_COLUMNS.each do |name|
      type = DynamicRecursiveHandoffW249Fixture.column_types[name]
      reader = CrystalClick::DynamicBulkColumnReader.open(part, name, type)
      require!(reader.schema_declaration == type.name && reader.source_declaration == type.name,
        "direct nominal declaration differs for #{name}")
      row_marks = reader.mark_row_counts
      require!(row_marks == DynamicRecursiveHandoffW249Fixture::MARK_ROW_COUNTS, "direct mark grid differs for #{name}")
      if marks.empty?
        marks = row_marks
      else
        require!(marks == row_marks, "target columns have different mark grids")
      end
      profiles << DynamicRecursiveHandoffW249Fixture.profile_name(reader.ordinary_profile)
      values[name] = reader.read_marks(0, reader.mark_count).flat_map { |mark| mark }
      require!(values[name].size == keys.size, "direct row count differs for #{name}")
    end
    require!(profiles.uniq.size == 1, "target columns have different String profiles")
    rows = rows_from_values(keys, values)
    require!(DynamicRecursiveHandoffW249Fixture.rows_equal?(rows, DynamicRecursiveHandoffW249Fixture.expected_rows), "direct BinaryBulk rows differ from literal fixture")
    {profile: profiles.first, keys: keys, mark_row_counts: marks, values: values, rows: rows}
  end

  private def rows_from_values(
    keys : Array(UInt64),
    columns : Hash(String, Array(CrystalClick::BinaryValue)),
  ) : Array(JSON::Any)
    require!(DynamicRecursiveHandoffW249Fixture::TARGET_COLUMNS.all? { |name| columns.has_key?(name) }, "row builder lacks a target column")
    rows = Array(JSON::Any).new(keys.size)
    keys.each_with_index do |key, index|
      values = Hash(String, CrystalClick::BinaryValue).new
      DynamicRecursiveHandoffW249Fixture::TARGET_COLUMNS.each do |name|
        column = columns[name]
        require!(index < column.size, "row builder column is short: #{name}")
        values[name] = column[index]
      end
      rows << DynamicRecursiveHandoffW249Fixture.row_record(key, values)
    end
    rows
  end

  private def table_rows(
    table : CrystalClick::WidePartTable,
    mode : String,
  ) : Array(JSON::Any)
    rows = [] of JSON::Any
    append = ->(batch : CrystalClick::WidePartTableBatch) do
      keys = batch.values_for(DynamicRecursiveHandoffW249Fixture::KEY_NAME)
      columns = Hash(String, Slice(CrystalClick::BinaryValue)).new
      DynamicRecursiveHandoffW249Fixture::TARGET_COLUMNS.each do |name|
        columns[name] = batch.dynamic_bulk_values_for(name)
      end
      keys.size.times do |index|
        values = Hash(String, CrystalClick::BinaryValue).new
        DynamicRecursiveHandoffW249Fixture::TARGET_COLUMNS.each { |name| values[name] = columns[name][index] }
        rows << DynamicRecursiveHandoffW249Fixture.row_record(keys[index], values)
      end
      nil
    end
    case mode
    when "full"
      table.scan_typed(batch_rows: 2, &append)
    when "window"
      table.scan_typed_window(2_u64, 2, &append)
    when "candidate"
      table.scan_typed_candidate_marks([[0_i32, 2_i32]], &append)
    else
      raise ArgumentError.new("unknown W249 table read mode")
    end
    rows
  end

  private def offline_rows(root : String) : Array(JSON::Any)
    table = CrystalClick::OfflineCatalog.open(root).table("lab", "events")
    keys = table[DynamicRecursiveHandoffW249Fixture::KEY_NAME].values(max_rows: DynamicRecursiveHandoffW249Fixture::KEYS.size.to_u64).map(&.as(UInt64))
    columns = Hash(String, Array(CrystalClick::BinaryValue)).new
    DynamicRecursiveHandoffW249Fixture::TARGET_COLUMNS.each do |name|
      columns[name] = table[name].values(max_rows: DynamicRecursiveHandoffW249Fixture::KEYS.size.to_u64).map(&.as(CrystalClick::BinaryValue))
    end
    require!(keys == DynamicRecursiveHandoffW249Fixture::KEYS, "offline UInt64 primary keys differ from literal fixture")
    rows = rows_from_values(keys, columns)
    require!(DynamicRecursiveHandoffW249Fixture.rows_equal?(rows, DynamicRecursiveHandoffW249Fixture.expected_rows), "offline .values differ from literal fixture")
    rows
  end

  private def report_columns(action : String, values : Hash(String, Array(CrystalClick::BinaryValue))) : JSON::Any
    rows = [] of JSON::Any
    DynamicRecursiveHandoffW249Fixture::TARGET_COLUMNS.each do |name|
      sites = [] of JSON::Any
      observed = DynamicRecursiveHandoffW249Fixture.observed_types_by_site(name, values[name])
      DynamicRecursiveHandoffW249Fixture.dynamic_sites[name].each do |site|
        entry = Hash(String, JSON::Any).new
        entry["path"] = JSON::Any.new(site[:path])
        entry["registered_actual_types"] = action == "write" ? json_array(site[:registered_actual_types]) : JSON::Any.new(nil)
        entry["observed_actual_types"] = json_array(observed[site[:path]])
        sites << JSON::Any.new(entry)
      end
      column = Hash(String, JSON::Any).new
      column["name"] = JSON::Any.new(name)
      column["type"] = JSON::Any.new(DynamicRecursiveHandoffW249Fixture.column_types[name].name)
      column["dynamic_sites"] = JSON::Any.new(sites)
      rows << JSON::Any.new(column)
    end
    JSON::Any.new(rows)
  end

  private def make_report(
    action : String,
    part : String,
    profile : String,
    frame_bytes : Int?,
    direct : Array(JSON::Any),
    observed_values : Hash(String, Array(CrystalClick::BinaryValue)),
    table_full : Array(JSON::Any)? = nil,
    table_window : Array(JSON::Any)? = nil,
    table_candidates : Array(JSON::Any)? = nil,
    offline : Array(JSON::Any)? = nil,
  ) : JSON::Any
    columns = report_columns(action, observed_values)
    observed = Hash(String, JSON::Any).new
    observed["direct_reader"] = JSON::Any.new(direct)
    observed["table_full_scan"] = json_rows(table_full)
    observed["table_window"] = json_rows(table_window)
    observed["table_candidate_marks"] = json_rows(table_candidates)
    observed["offline_values"] = json_rows(offline)

    report = Hash(String, JSON::Any).new
    report["format"] = JSON::Any.new(FORMAT)
    report["action"] = JSON::Any.new(action)
    report["part_path"] = JSON::Any.new(File.expand_path(part))
    report["profile"] = JSON::Any.new(profile)
    report["frame_bytes"] = frame_bytes ? JSON::Any.new(frame_bytes.to_i64) : JSON::Any.new(nil)
    report["rows_per_mark"] = JSON::Any.new(DynamicRecursiveHandoffW249Fixture::ROWS_PER_MARK.to_i64)
    report["key_column"] = JSON::Any.new(DynamicRecursiveHandoffW249Fixture::KEY_NAME)
    report["columns"] = columns
    report["keys"] = JSON::Any.new(DynamicRecursiveHandoffW249Fixture::KEYS.map { |key| JSON::Any.new(key.to_i64) })
    report["mark_row_counts"] = JSON::Any.new(DynamicRecursiveHandoffW249Fixture::MARK_ROW_COUNTS.map { |count| JSON::Any.new(count.to_i64) })
    report["expected_rows"] = JSON::Any.new(DynamicRecursiveHandoffW249Fixture.expected_rows)
    report["observed"] = JSON::Any.new(observed)
    JSON::Any.new(report)
  end

  private def write_report(part : String, profile_name : String) : JSON::Any
    DynamicRecursiveHandoffW249Fixture.write_part(part, profile_name, DynamicRecursiveHandoffW249Fixture::FRAME_BYTES)
    direct = read_direct(part)
    require!(direct[:profile] == DynamicRecursiveHandoffW249Fixture.profile_name(DynamicRecursiveHandoffW249Fixture.profile(profile_name)), "writer profile differs from request")
    make_report("write", part, direct[:profile], DynamicRecursiveHandoffW249Fixture::FRAME_BYTES, direct[:rows], direct[:values])
  end

  private def read_report(part : String, offline_root : String) : JSON::Any
    direct = read_direct(part)
    table = CrystalClick::WidePartTable.open_selected_typed(
      [part], [DynamicRecursiveHandoffW249Fixture::KEY_NAME] + DynamicRecursiveHandoffW249Fixture::TARGET_COLUMNS,
    )
    require!(table.total_row_count == DynamicRecursiveHandoffW249Fixture::KEYS.size.to_u64, "typed table row count differs")
    full = table_rows(table, "full")
    window = table_rows(table, "window")
    candidates = table_rows(table, "candidate")
    expected = DynamicRecursiveHandoffW249Fixture.expected_rows
    expected_window = expected[2, 2]
    expected_candidates = [expected[0], expected[1], expected[4]]
    require!(DynamicRecursiveHandoffW249Fixture.rows_equal?(full, expected), "typed table full scan differs from fixture")
    require!(DynamicRecursiveHandoffW249Fixture.rows_equal?(window, expected_window), "typed table window differs from fixture")
    require!(DynamicRecursiveHandoffW249Fixture.rows_equal?(candidates, expected_candidates), "typed candidate marks differ from fixture")
    offline = if offline_root == "none"
                nil
              else
                offline_rows(offline_root)
              end
    make_report("read", part, direct[:profile], nil, direct[:rows], direct[:values], full, window,
      candidates, offline)
  end

  def main(args : Array(String)) : Nil
    unless args.size == 3
      raise ArgumentError.new("usage: helper write PART single|sized | read PART OFFLINE_ROOT_OR_NONE")
    end
    report = case args[0]
             when "write" then write_report(args[1], args[2])
             when "read"  then read_report(args[1], args[2])
             else              raise ArgumentError.new("usage: helper write PART single|sized | read PART OFFLINE_ROOT_OR_NONE")
             end
    puts report.to_json
  end
end

CheckDynamicRecursiveHandoffW249.main(ARGV)
