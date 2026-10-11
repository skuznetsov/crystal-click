require "../src/crystal_click"
require "json"
require "file_utils"
require "./support/wide_ragged_selected_metadata_w261_fixture"

module CheckWideRaggedSelectedMetadataW261
  FORMAT = "wide_ragged_selected_metadata_w261_checker_v1"
  alias Attempt = NamedTuple(name: String, status: String, rows: Int32?, detail: String?)
  alias Scan = NamedTuple(columns: Hash(String, Array(String)), offsets: Array(Tuple(UInt64, UInt64)))

  def self.hex(value : String) : String
    String.build do |io|
      value.to_slice.each { |byte| io << byte.to_s(16).rjust(2, '0') }
    end
  end

  def self.string_signature(value : String) : String
    "string:#{hex(value)}"
  end

  def self.nullable_string_signature(value : CrystalClick::WideTupleLeafColumn::Value) : String
    case value
    when String
      string_signature(value)
    when Nil
      "null"
    else
      raise CrystalClick::CorruptPartError.new("W261 nullable String leaf has an unexpected carrier")
    end
  end

  def self.nullable_float64_signature(value : Float64?) : String
    value ? "float64:#{value}" : "null"
  end

  def self.tuple_signature(row : CrystalClick::WideTupleRow) : String
    id = row.value_as("id", UInt64)
    details = row.tuple("details")
    note = nullable_string_signature(details["note"])
    score = details.value_as("score", UInt32)
    "tuple[id=uint64:#{id},details=tuple[note=#{note},score=uint32:#{score}]]"
  end

  def self.array_tuple_signature(row : CrystalClick::WideArrayTupleRow) : String
    values = [] of String
    row.each { |tuple| values << tuple_signature(tuple) }
    "array[#{values.join(',')}]"
  end

  def self.map_tuple_signature(row : CrystalClick::WideMapTupleRow) : String
    entries = [] of String
    row.each do |key_value, value_row|
      key = key_value.as(String)
      meta = value_row.tuple("meta")
      note = nullable_string_signature(meta["note"])
      id = meta.value_as("id", UInt64)
      score = nullable_float64_signature(value_row["score"].as(Float64?))
      entries << "#{hex(key)}:tuple[meta=tuple[note=#{note},id=uint64:#{id}],score=#{score}]"
    end
    "map[#{entries.join(',')}]"
  end

  def self.simple_map_signature(values : Array(Tuple(UInt64, UInt64?))) : String
    entries = values.map do |key, value|
      "uint64:#{key}:#{value ? "uint64:#{value}" : "null"}"
    end
    "map[#{entries.join(',')}]"
  end

  def self.lookup_map_signature(values : Array(Tuple(String, Array(UInt64?)))) : String
    entries = values.map do |key, children|
      rendered = children.map { |value| value ? "uint64:#{value}" : "null" }
      "#{hex(key)}:[#{rendered.join(',')}]"
    end
    "map[#{entries.join(',')}]"
  end

  def self.tuple_string_signature(row : CrystalClick::WideTupleRow) : String
    "tuple[n=uint64:#{row.value_as("n", UInt64)},s=#{string_signature(row.value_as("s", String))}]"
  end

  def self.variant_signature(value : CrystalClick::VariantStringUInt64Value) : String
    case value
    when String
      "variant<String>(#{string_signature(value)})"
    when UInt64
      "variant<UInt64>(uint64:#{value})"
    else
      "variant<NULL>(null)"
    end
  end

  def self.direct_signatures(part : String, column : String, first_mark : Int = 0, mark_count : Int? = nil) : Array(String)
    reader = CrystalClick::WidePart.open_typed(part, column)
    expected_type = WideRaggedSelectedMetadataW261Fixture.schema_hash[column]?
    raise CrystalClick::CorruptPartError.new("W261 direct reader type is absent from fixture") unless expected_type
    raise CrystalClick::CorruptPartError.new("W261 direct reader type differs for #{column}") unless reader.column_type == expected_type
    count = mark_count || reader.mark_count
    raise CrystalClick::CorruptPartError.new("W261 direct mark schedule differs for #{column}") unless reader.mark_row_counts == WideRaggedSelectedMetadataW261Fixture::MARK_ROW_COUNTS

    case column
    when "pk", "u"
      source = reader.read_numeric_mark_range(column, first_mark, count, UInt64)
      source.map { |value| "uint64:#{value}" }
    when "side", "lc"
      source = if column == "lc"
                 reader.read_low_cardinality_string_mark_range(column, first_mark.to_i32, count.to_i32)
               else
                 reader.read_string_mark_range(column, first_mark, count)
               end
      source.map { |value| string_signature(value) }
    when "seq"
      data = reader.read_array_tuple_mark_range(column, first_mark, count)
      expected_sizes = WideRaggedSelectedMetadataW261Fixture::ARRAY_COUNTS[
        first_mark.to_i32 * 2, count.to_i32 * 2,
      ].map(&.to_u64)
      raise CrystalClick::CorruptPartError.new("W261 Array(Tuple) row schedule differs") unless data.row_sizes == expected_sizes
      Array.new(data.row_count) { |index| array_tuple_signature(data.row(index)) }
    when "mapped"
      data = reader.read_map_tuple_mark_range(column, first_mark, count)
      expected_sizes = WideRaggedSelectedMetadataW261Fixture::MAP_TUPLE_COUNTS[
        first_mark.to_i32 * 2, count.to_i32 * 2,
      ].map(&.to_u64)
      raise CrystalClick::CorruptPartError.new("W261 Map(Tuple) row schedule differs") unless data.row_sizes == expected_sizes
      Array.new(data.row_count) { |index| map_tuple_signature(data.row(index)) }
    when "simple"
      reader.read_map_uint64_nullable_uint64_mark_range(column, first_mark, count).map do |row|
        simple_map_signature(row)
      end
    when "lookup"
      reader.read_map_string_array_nullable_uint64_mark_range(column, first_mark, count).map do |row|
        lookup_map_signature(row)
      end
    when "tup"
      data = reader.read_tuple_mark_range(column, first_mark, count)
      Array.new(data.row_count) { |index| tuple_string_signature(data.row(index)) }
    when "v"
      reader.read_variant_string_uint64_mark_range(column, first_mark, count).map do |value|
        variant_signature(value)
      end
    else
      raise CrystalClick::UnsupportedFormatError.new("W261 direct reader has no assertion for #{column}")
    end
  end

  def self.table_signatures_for_batch(batch : CrystalClick::WidePartTableBatch) : Hash(String, Array(String))
    result = Hash(String, Array(String)).new
    result["u"] = batch.values_for("u", UInt64).map { |value| "uint64:#{value}" }.to_a
    result["side"] = batch.strings_for("side").map { |value| string_signature(value) }.to_a
    result["seq"] = batch.array_tuple_rows_for("seq").map { |row| array_tuple_signature(row) }.to_a
    result["mapped"] = batch.map_tuple_rows_for("mapped").map { |row| map_tuple_signature(row) }.to_a
    result["simple"] = batch.map_uint64_nullable_uint64s_for("simple").map { |row| simple_map_signature(row) }.to_a
    result["lookup"] = batch.map_string_array_nullable_uint64s_for("lookup").map { |row| lookup_map_signature(row) }.to_a
    result["tup"] = batch.tuple_rows_for("tup").map { |row| tuple_string_signature(row) }.to_a
    result["lc"] = batch.low_cardinality_strings_for("lc").map { |value| string_signature(value) }.to_a
    result["v"] = batch.variant_string_uint64_for("v").map { |value| variant_signature(value) }.to_a
    result
  end

  def self.collect_scan(
    table : CrystalClick::WidePartTable | CrystalClick::TypedPartTable,
    start_row : UInt64? = nil,
    max_rows : Int = 8,
  ) : Scan
    columns = Hash(String, Array(String)).new do |hash, name|
      hash[name] = [] of String
    end
    offsets = [] of Tuple(UInt64, UInt64)
    requested_start = start_row || 0_u64
    expected_offset = requested_start
    callback = ->(batch : CrystalClick::WidePartTableBatch) {
      rows = batch.row_count || raise CrystalClick::CorruptPartError.new("W261 typed batch omitted its row count")
      raise CrystalClick::CorruptPartError.new("W261 selected table callback row offset differs") unless batch.source_row_offset == expected_offset
      values = table_signatures_for_batch(batch)
      values.each do |column, signatures|
        raise CrystalClick::CorruptPartError.new("W261 typed batch #{column} row count differs") unless signatures.size.to_u64 == rows
        columns[column].concat(signatures)
      end
      offsets << {batch.source_row_offset, rows}
      expected_offset += rows
      nil
    }
    if start_row
      table.scan_typed_window(start_row, max_rows) { |batch| callback.call(batch) }
    else
      table.scan_typed(batch_rows: max_rows) { |batch| callback.call(batch) }
    end
    {columns: columns, offsets: offsets}
  end

  def self.selected_types : Array({String, String})
    selected = WideRaggedSelectedMetadataW261Fixture::SELECTED_COLUMNS
    schema = WideRaggedSelectedMetadataW261Fixture.schema_hash
    selected.map { |name| {name, schema[name]} }
  end

  def self.assert_scan(scan : Scan, expected : Hash(String, Array(String)), label : String) : Nil
    raise CrystalClick::CorruptPartError.new("W261 #{label} selected column set differs") unless scan[:columns].keys.sort == WideRaggedSelectedMetadataW261Fixture::SELECTED_COLUMNS.sort
    raise CrystalClick::CorruptPartError.new("W261 #{label} values differ from independent fixture literals") unless scan[:columns] == expected
    nil
  end

  def self.signatures_for_rows(expected : Hash(String, Array(String)), first_row : Int, row_count : Int) : Hash(String, Array(String))
    result = Hash(String, Array(String)).new
    WideRaggedSelectedMetadataW261Fixture::SELECTED_COLUMNS.each do |column|
      result[column] = expected[column][first_row, row_count]
    end
    result
  end

  def self.assert_offsets(scan : Scan, first_row : UInt64, row_count : UInt64, label : String) : Nil
    next_offset = first_row
    scan[:offsets].each do |offset, count|
      raise CrystalClick::CorruptPartError.new("W261 #{label} emitted an empty batch") if count == 0_u64
      raise CrystalClick::CorruptPartError.new("W261 #{label} source row offset differs") unless offset == next_offset
      next_offset += count
    end
    raise CrystalClick::CorruptPartError.new("W261 #{label} row cardinality differs") unless next_offset == first_row + row_count
    nil
  end

  def self.assert_table_metadata(table : CrystalClick::WidePartTable | CrystalClick::TypedPartTable, label : String) : Nil
    raise CrystalClick::CorruptPartError.new("W261 #{label} part count differs") unless table.part_count == 1
    raise CrystalClick::CorruptPartError.new("W261 #{label} total row count differs") unless table.total_row_count == WideRaggedSelectedMetadataW261Fixture::ROW_COUNT
    raise CrystalClick::CorruptPartError.new("W261 #{label} selected column order differs") unless table.columns == WideRaggedSelectedMetadataW261Fixture::SELECTED_COLUMNS
    raise CrystalClick::CorruptPartError.new("W261 #{label} selected exact types differ") unless table.column_types == selected_types
    raise CrystalClick::CorruptPartError.new("W261 #{label} selected mark schedule differs") unless table.part_mark_row_counts == [WideRaggedSelectedMetadataW261Fixture::MARK_ROW_COUNTS]
    nil
  end

  def self.assert_table_reads(table : CrystalClick::WidePartTable | CrystalClick::TypedPartTable, label : String) : NamedTuple(full: Scan, window: Scan)
    expected = WideRaggedSelectedMetadataW261Fixture.expected_signatures
    assert_table_metadata(table, label)

    full = collect_scan(table, max_rows: 2)
    assert_scan(full, expected, "#{label} full scan")
    assert_offsets(full, 0_u64, WideRaggedSelectedMetadataW261Fixture::ROW_COUNT, "#{label} full scan")

    window = collect_scan(table, 2_u64, 4)
    assert_scan(window, signatures_for_rows(expected, 2, 4), "#{label} window")
    assert_offsets(window, 2_u64, 4_u64, "#{label} window")

    eof = collect_scan(table, WideRaggedSelectedMetadataW261Fixture::ROW_COUNT, 2)
    raise CrystalClick::CorruptPartError.new("W261 #{label} EOF emitted a callback") unless eof[:offsets].empty? && eof[:columns].empty?
    {full: full, window: window}
  end

  def self.offline_value_signature(column : String, value : CrystalClick::OfflineColumnValue) : String
    case column
    when "u"
      "uint64:#{value.as(UInt64)}"
    when "side", "lc"
      string_signature(value.as(String))
    when "seq"
      array_tuple_signature(value.as(CrystalClick::WideArrayTupleRow))
    when "mapped"
      map_tuple_signature(value.as(CrystalClick::WideMapTupleRow))
    when "simple"
      simple_map_signature(value.as(Array(Tuple(UInt64, UInt64?))))
    when "lookup"
      lookup_map_signature(value.as(Array(Tuple(String, Array(UInt64?)))))
    when "tup"
      tuple_string_signature(value.as(CrystalClick::WideTupleRow))
    when "v"
      variant_signature(value.as(CrystalClick::VariantStringUInt64Value))
    else
      raise CrystalClick::UnsupportedFormatError.new("W261 offline assertion has no carrier for #{column}")
    end
  end

  def self.offline_signatures(table : CrystalClick::OfflineTable) : Hash(String, Array(String))
    result = Hash(String, Array(String)).new
    WideRaggedSelectedMetadataW261Fixture::SELECTED_COLUMNS.each do |column|
      budget = WideRaggedSelectedMetadataW261Fixture::VALUE_BUDGETS[column]
      values = table[column].values(
        max_rows: WideRaggedSelectedMetadataW261Fixture::ROW_COUNT,
        max_string_bytes: budget[:string_bytes],
        max_tuple_cells: budget[:tuple_cells],
      )
      raise CrystalClick::CorruptPartError.new("W261 offline #{column} row cardinality differs") unless values.size.to_u64 == WideRaggedSelectedMetadataW261Fixture::ROW_COUNT
      result[column] = values.map { |value| offline_value_signature(column, value) }
    end
    result
  end

  def self.assert_offline_budget_boundaries(table : CrystalClick::OfflineTable) : Nil
    WideRaggedSelectedMetadataW261Fixture::SELECTED_COLUMNS.each do |column|
      budget = WideRaggedSelectedMetadataW261Fixture::VALUE_BUDGETS[column]
      selected = table[column]
      if budget[:string_bytes] > 0_u64
        begin
          selected.values(
            max_rows: WideRaggedSelectedMetadataW261Fixture::ROW_COUNT,
            max_string_bytes: budget[:string_bytes] - 1_u64,
            max_tuple_cells: budget[:tuple_cells],
          )
          raise CrystalClick::CorruptPartError.new("W261 offline #{column} accepted one-less String budget")
        rescue ex : CrystalClick::BoundsError
          unless (ex.message || "").includes?("String")
            raise CrystalClick::CorruptPartError.new("W261 offline #{column} failed outside the String budget guard")
          end
        end
      end
      if budget[:tuple_cells] > 0_u64
        begin
          selected.values(
            max_rows: WideRaggedSelectedMetadataW261Fixture::ROW_COUNT,
            max_string_bytes: budget[:string_bytes],
            max_tuple_cells: budget[:tuple_cells] - 1_u64,
          )
          raise CrystalClick::CorruptPartError.new("W261 offline #{column} accepted one-less Tuple budget")
        rescue ex : CrystalClick::BoundsError
          unless (ex.message || "").includes?("Tuple")
            raise CrystalClick::CorruptPartError.new("W261 offline #{column} failed outside the Tuple budget guard")
          end
        end
      end
    end

    begin
      table["u"].values(max_rows: WideRaggedSelectedMetadataW261Fixture::ROW_COUNT - 1_u64, max_string_bytes: 0_u64, max_tuple_cells: 0_u64)
      raise CrystalClick::CorruptPartError.new("W261 offline UInt64 accepted one-less row budget")
    rescue ex : CrystalClick::BoundsError
      unless (ex.message || "").includes?("row limit")
        raise CrystalClick::CorruptPartError.new("W261 offline UInt64 failed outside the row budget guard")
      end
    end
    nil
  end

  def self.assert_direct_reads(part : String) : Array({String, Int32})
    expected = WideRaggedSelectedMetadataW261Fixture.expected_signatures
    outcomes = [] of {String, Int32}
    WideRaggedSelectedMetadataW261Fixture::SELECTED_COLUMNS.each do |column|
      full = direct_signatures(part, column)
      raise CrystalClick::CorruptPartError.new("W261 direct #{column} full values differ") unless full == expected[column]
      window = direct_signatures(part, column, 1, 2)
      raise CrystalClick::CorruptPartError.new("W261 direct #{column} mark window differs") unless window == expected[column][2, 4]
      outcomes << {column, full.size.to_i32}
    end
    outcomes
  end

  def self.green(part : String, work_root : String) : Int32
    direct = assert_direct_reads(part)

    wide = CrystalClick::WidePartTable.open_selected_typed([part], WideRaggedSelectedMetadataW261Fixture::SELECTED_COLUMNS)
    wide_result = assert_table_reads(wide, "WidePartTable")
    typed = CrystalClick::TypedPartTable.open_selected_typed([part], WideRaggedSelectedMetadataW261Fixture::SELECTED_COLUMNS)
    typed_result = assert_table_reads(typed, "TypedPartTable")

    catalog_fixture = WideRaggedSelectedMetadataW261Fixture.prepare_offline_catalog(part, work_root)
    catalog = CrystalClick::OfflineCatalog.open(catalog_fixture[:root])
    offline = catalog.table("lab", "events")
    offline_types = offline.columns.map { |column| {column.name, column.type} }
    raise CrystalClick::CorruptPartError.new("W261 offline full schema types differ") unless offline_types == WideRaggedSelectedMetadataW261Fixture::SCHEMA
    candidates = offline.resolved_scan_parts
    raise CrystalClick::CorruptPartError.new("W261 offline catalog did not resolve the copied stock part") unless candidates.size == 1 && File.realpath(candidates[0].path) == File.realpath(catalog_fixture[:part])
    offline_values = offline_signatures(offline)
    raise CrystalClick::CorruptPartError.new("W261 offline .values differ from independent fixture literals") unless offline_values == WideRaggedSelectedMetadataW261Fixture.expected_signatures
    assert_offline_budget_boundaries(offline)

    JSON.build(STDOUT) do |json|
      json.object do
        json.field "format", FORMAT
        json.field "status", "green_all_assertions"
        json.field "assertions" do
          json.array do
            %w[direct full window eof selected_table offline_values exact_types exact_budgets].each { |name| json.string name }
          end
        end
        json.field "ordinary_controls", "green"
        json.field "selected_columns_without_pk", WideRaggedSelectedMetadataW261Fixture::SELECTED_COLUMNS
        json.field "row_count", WideRaggedSelectedMetadataW261Fixture::ROW_COUNT
        json.field "mark_row_counts", WideRaggedSelectedMetadataW261Fixture::MARK_ROW_COUNTS
        json.field "direct_rows_by_column" do
          json.array do
            direct.each do |column, rows|
              json.object do
                json.field "column", column
                json.field "rows", rows
                json.field "full_and_window_literals", "green"
              end
            end
          end
        end
        json.field "selected_table_attempts" do
          json.array do
            [{"WidePartTable", wide_result}, {"TypedPartTable", typed_result}].each do |name, result|
              json.object do
                json.field "name", name
                json.field "status", "green"
                json.field "rows", result[:full][:columns]["u"].size
                json.field "window_rows", result[:window][:columns]["u"].size
                json.field "eof_callbacks", 0
              end
            end
          end
        end
        json.field "offline_values" do
          json.object do
            WideRaggedSelectedMetadataW261Fixture::SELECTED_COLUMNS.each do |column|
              json.field column, offline_values[column].size
            end
          end
        end
        json.field "offline_budgets" do
          json.object do
            WideRaggedSelectedMetadataW261Fixture::SELECTED_COLUMNS.each do |column|
              budget = WideRaggedSelectedMetadataW261Fixture::VALUE_BUDGETS[column]
              json.field column do
                json.object do
                  json.field "string_bytes", budget[:string_bytes]
                  json.field "tuple_cells", budget[:tuple_cells]
                  json.field "one_less_string_rejected", budget[:string_bytes] > 0_u64
                  json.field "one_less_tuple_rejected", budget[:tuple_cells] > 0_u64
                end
              end
            end
          end
        end
      end
    end
    STDOUT << '\n'
    0
  end

  def self.capture_table_attempt(part : String, typed_part_table : Bool) : Attempt
    name = typed_part_table ? "TypedPartTable" : "WidePartTable"
    begin
      table = if typed_part_table
                CrystalClick::TypedPartTable.open_selected_typed([part], WideRaggedSelectedMetadataW261Fixture::SELECTED_COLUMNS)
              else
                CrystalClick::WidePartTable.open_selected_typed([part], WideRaggedSelectedMetadataW261Fixture::SELECTED_COLUMNS)
              end
      unless table.columns == WideRaggedSelectedMetadataW261Fixture::SELECTED_COLUMNS && table.column_types == selected_types
        return {name: name, status: "metadata_mismatch", rows: nil, detail: "selected columns or exact type declarations differ"}
      end
      full = collect_scan(table)
      unless full[:columns] == WideRaggedSelectedMetadataW261Fixture.expected_signatures
        return {name: name, status: "value_mismatch", rows: full[:columns]["u"]?.try(&.size), detail: "full typed scan differs from independent literals"}
      end
      {name: name, status: "green", rows: full[:columns]["u"].size, detail: nil}
    rescue ex : Exception
      {name: name, status: "rejected", rows: nil, detail: "#{ex.class}: #{ex.message || "no message"}"}
    end
  end

  def self.write_attempt(json : JSON::Builder, attempt : Attempt) : Nil
    json.object do
      json.field "name", attempt[:name]
      json.field "status", attempt[:status]
      json.field "rows" do
        if rows = attempt[:rows]
          json.number rows
        else
          json.null
        end
      end
      json.field "detail" do
        if detail = attempt[:detail]
          json.string detail
        else
          json.null
        end
      end
    end
  end

  def self.write_attempts(json : JSON::Builder, attempts : Array(Attempt)) : Nil
    json.array do
      attempts.each { |attempt| write_attempt(json, attempt) }
    end
  end

  def self.baseline(part : String) : Int32
    expected = WideRaggedSelectedMetadataW261Fixture.expected_signatures
    controls = Hash(String, Array(String)).new
    controls["pk"] = expected_keys.map { |value| "uint64:#{value}" }
    controls["u"] = expected["u"]
    controls["side"] = expected["side"]
    controls.each do |column, wanted|
      actual = direct_signatures(part, column)
      raise CrystalClick::CorruptPartError.new("W261 ordinary control #{column} differs") unless actual == wanted
    end

    direct = [] of Attempt
    WideRaggedSelectedMetadataW261Fixture::SELECTED_COLUMNS.each do |column|
      attempt : Attempt
      begin
        values = direct_signatures(part, column)
        status = values == expected[column] ? "green" : "value_mismatch"
        attempt = {name: column, status: status, rows: values.size, detail: nil}
      rescue ex : Exception
        attempt = {name: column, status: "rejected", rows: nil, detail: "#{ex.class}: #{ex.message || "no message"}"}
      end
      direct << attempt
    end
    tables = [capture_table_attempt(part, false), capture_table_attempt(part, true)] of Attempt
    red = direct.any? { |attempt| attempt[:status] != "green" } || tables.any? { |attempt| attempt[:status] != "green" }
    JSON.build(STDOUT) do |json|
      json.object do
        json.field "format", FORMAT
        json.field "status", red ? "baseline_red_captured" : "baseline_typed_green"
        json.field "ordinary_controls", "green"
        json.field "direct_selected_attempts" do
          write_attempts(json, direct)
        end
        json.field "selected_table_attempts" do
          write_attempts(json, tables)
        end
        json.field "assertion_boundary", "baseline records admission and value outcomes independently; typed rejection is evidence, not a harness failure"
      end
    end
    STDOUT << '\n'
    0
  end

  def self.expected_keys : Array(UInt64)
    WideRaggedSelectedMetadataW261Fixture::KEY_VALUES
  end

  def self.run : Nil
    unless ARGV.size == 3 && {"baseline", "green"}.includes?(ARGV[0])
      STDERR.puts "usage: check_wide_ragged_selected_metadata_w261.cr baseline|green STOCK_PART WORK_ROOT"
      exit(2)
    end
    mode, raw_part, raw_work_root = ARGV
    part = File.expand_path(raw_part)
    raise CrystalClick::InvalidPartError.new("W261 stock part must be an existing non-symlink directory") unless Dir.exists?(part) && !File.symlink?(part) && File.realpath(part) == part
    work_root = File.expand_path(raw_work_root)
    raise CrystalClick::InvalidPartError.new("W261 work root must be a fresh child of an existing directory") if File.exists?(work_root) || File.symlink?(work_root)
    raise CrystalClick::InvalidPartError.new("W261 work root parent is absent or symlinked") unless Dir.exists?(File.dirname(work_root)) && !File.symlink?(File.dirname(work_root)) && File.realpath(File.dirname(work_root)) == File.dirname(work_root)

    exit(baseline(part)) if mode == "baseline"
    exit(green(part, work_root))
  end
end

CheckWideRaggedSelectedMetadataW261.run
