require "../src/crystal_click"
require "json"
require "./support/compact_dynamic_w262_fixture"

module CheckCompactDynamicW262
  FORMAT        = "compact_dynamic_w262_baseline_helper_v1"
  GREEN_FORMAT  = "compact_dynamic_w262_green_helper_v1"
  GREEN_COLUMNS = {
    "root"    => "Dynamic(max_types=1)",
    "nested"  => "Array(Tuple(choice Variant(String, UInt64), payload Dynamic(max_types=1)))",
    "by_name" => "Map(String, Dynamic(max_types=1))",
  }
  STATIC_REFUSAL  = "selected Compact declaration is outside static BinaryBulk admission"
  DYNAMIC_COLUMNS = {
    {"root", "Dynamic(max_types=1)"},
    {"nested", "Array(Tuple(choice Variant(String, UInt64), payload Dynamic(max_types=1)))"},
    {"by_name", "Map(String, Dynamic(max_types=1))"},
  }

  alias ValueScan = NamedTuple(keys: Array(UInt64), columns: Hash(String, Array(String)))
  alias PublicReport = NamedTuple(
    mark_rows: Array(Array(UInt64)),
    full: ValueScan,
    first: ValueScan,
    middle: ValueScan,
    last: ValueScan,
    eof: ValueScan,
  )
  alias DirectReport = NamedTuple(
    mark_rows: Array(UInt64),
    full: Array(Array(String)),
    first: Array(Array(String)),
    middle: Array(Array(String)),
    last: Array(Array(String)),
    eof: Array(Array(String)),
  )

  private def self.read_compact_pk(part : String) : Array(UInt64)
    values = [] of UInt64
    table = CrystalClick::CompactPartTable.open_selected_typed([part], ["pk"])
    table.scan_typed do |batch|
      values.concat(batch.values_for("pk", UInt64).to_a)
    end
    values
  end

  private def self.read_typed_pk(part : String) : Array(UInt64)
    values = [] of UInt64
    table = CrystalClick::TypedPartTable.open_selected_typed([part], ["pk"])
    table.scan_typed do |batch|
      values.concat(batch.values_for("pk", UInt64).to_a)
    end
    values
  end

  private def self.expect_refusal(api : String, part : String, column : String) : String
    begin
      case api
      when "compact"
        CrystalClick::CompactPartTable.open_selected_typed([part], [column])
      when "typed"
        CrystalClick::TypedPartTable.open_selected_typed([part], [column])
      else
        raise "unknown W262 API #{api.inspect}"
      end
    rescue ex : CrystalClick::UnsupportedFormatError
      error = ex.message || ""
      unless error == STATIC_REFUSAL
        raise "W262 #{api}/#{column} refusal differs: #{error.inspect}"
      end
      return error
    end
    raise "W262 #{api}/#{column} unexpectedly accepted Dynamic without its context"
  end

  private def self.signatures(values : Array(CrystalClick::BinaryValue)) : Array(String)
    values.map { |value| CompactDynamicW262Fixture.value_signature(value) }.to_a
  end

  private def self.value_scan(
    table : CrystalClick::CompactPartTable | CrystalClick::TypedPartTable,
    columns : Array(String),
    start_row : UInt64,
    max_rows : Int,
  ) : ValueScan
    keys = [] of UInt64
    column_signatures = Hash(String, Array(String)).new
    columns.each { |column| column_signatures[column] = [] of String }
    table.scan_typed_window(start_row, max_rows) do |batch|
      keys.concat(batch.values_for("pk", UInt64).to_a)
      columns.each do |column|
        column_signatures[column].concat(signatures(batch.dynamic_bulk_values_for(column).to_a))
      end
    end
    {keys: keys, columns: column_signatures}
  end

  private def self.public_report(
    table : CrystalClick::CompactPartTable | CrystalClick::TypedPartTable,
    columns : Array(String),
  ) : PublicReport
    expected_grid = [[2_u64, 2_u64, 2_u64, 2_u64]]
    mark_rows = table.part_mark_row_counts
    raise "W262 public Dynamic mark grid differs: #{mark_rows.inspect}" unless mark_rows == expected_grid
    raise "W262 public Dynamic row count differs" unless table.total_row_count == 8_u64
    # A zero-mark EOF selection still prepares/validates the complete part
    # schedule before any full-window scan is allowed to mask a late prefix.
    eof = value_scan(table, columns, 8_u64, 1)
    {
      mark_rows: mark_rows,
      full:      value_scan(table, columns, 0_u64, 8),
      first:     value_scan(table, columns, 0_u64, 2),
      middle:    value_scan(table, columns, 2_u64, 4),
      last:      value_scan(table, columns, 6_u64, 2),
      eof:       eof,
    }
  end

  private def self.direct_report(part : String, column : String, source_type : String) : DirectReport
    type = CrystalClick::DynamicBulkColumnDeclaration.parse(source_type) ||
           raise CrystalClick::UnsupportedFormatError.new("W262 direct reader type is not Dynamic-bearing")
    reader = CrystalClick::CompactDynamicBulkColumnReader.open(part, column, type)
    expected_marks = [2_u64, 2_u64, 2_u64, 2_u64]
    raise "W262 direct reader mark grid differs for #{column}" unless reader.mark_row_counts == expected_marks

    # The EOF zero-mark read comes first: it must still validate the complete
    # Dynamic prefix schedule, including prefixes belonging to later marks.
    eof = reader.read_marks(reader.mark_count, 0)
    raise "W262 direct reader EOF selection was not empty for #{column}" unless eof.empty?
    full = reader.read_marks(0, reader.mark_count)
    first = reader.read_marks(0, 1)
    middle = reader.read_marks(1, 2)
    last = reader.read_marks(3, 1)
    reader.validate_complete_schedule
    {
      mark_rows: reader.mark_row_counts,
      full:      full.map { |mark| signatures(mark) },
      first:     first.map { |mark| signatures(mark) },
      middle:    middle.map { |mark| signatures(mark) },
      last:      last.map { |mark| signatures(mark) },
      eof:       eof.map { |mark| signatures(mark) },
    }
  end

  private def self.offline_signatures(store_root : String, table_name : String, column : String) : Array(String)
    values = CrystalClick::OfflineCatalog.open(store_root)["default"][table_name][column].values
    values.map do |value|
      binary = value.as?(CrystalClick::BinaryValue) ||
               raise CrystalClick::CorruptPartError.new("W262 offline Dynamic value is not BinaryValue")
      CompactDynamicW262Fixture.value_signature(binary)
    end
  end

  def self.run_green(manifest_path : String) : Nil
    manifest = JSON.parse(File.read(manifest_path)).as_h
    unless manifest["format"].as_s == "compact_dynamic_w262_native_manifest_v1"
      raise "wrong W262 native manifest format"
    end
    store_root = File.expand_path(manifest["store_root"].as_s)
    parts = manifest["parts"].as_a
    expected_labels = %w[
      mrk3_s0_vbasic mrk3_s0_vcompact mrk3_s1_vbasic mrk3_s1_vcompact
      mrk4_s0_vbasic mrk4_s0_vcompact mrk4_s1_vbasic mrk4_s1_vcompact
    ]
    labels = parts.map { |entry| entry["label"].as_s }
    unless labels.sort == expected_labels.sort && labels.uniq.size == labels.size
      raise "W262 manifest labels differ from the sealed eight-cell matrix"
    end

    cells = [] of NamedTuple(
      label: String,
      compact_pk: Array(UInt64),
      typed_pk: Array(UInt64),
      direct: Hash(String, DirectReport),
      compact: PublicReport,
      typed: PublicReport,
      offline: Hash(String, Array(String)),
    )
    dynamic_columns = GREEN_COLUMNS.keys
    parts.each do |entry|
      label = entry["label"].as_s
      part = File.expand_path(entry["path"].as_s)
      raise "W262 #{label} part path is absent or linked" unless File.directory?(part) && !File.symlink?(part)

      compact_pk = read_compact_pk(part)
      typed_pk = read_typed_pk(part)
      expected_pk = (1_u64..8_u64).to_a
      unless compact_pk == expected_pk && typed_pk == expected_pk
        raise "W262 #{label} UInt64 positive read differs: compact=#{compact_pk.inspect}, typed=#{typed_pk.inspect}"
      end

      direct = Hash(String, DirectReport).new
      dynamic_columns.each do |column|
        source_type = GREEN_COLUMNS.fetch(column) { raise "W262 Dynamic type missing for #{column}" }
        direct[column] = direct_report(part, column, source_type)
        actual = direct[column][:full].flatten
        expected = case column
                   when "root"    then CompactDynamicW262Fixture.root_values
                   when "nested"  then CompactDynamicW262Fixture.nested_values
                   when "by_name" then CompactDynamicW262Fixture.map_values
                   else                raise "W262 Dynamic literal roster is incomplete"
                   end.map { |value| CompactDynamicW262Fixture.value_signature(value) }
        raise "W262 #{label}/#{column} direct literal values differ" unless actual == expected
      end

      compact_table = CrystalClick::CompactPartTable.open_selected_typed(
        [part], ["pk"] + dynamic_columns,
      )
      typed_table = CrystalClick::TypedPartTable.open_selected_typed(
        [part], ["pk"] + dynamic_columns,
      )
      compact = public_report(compact_table, dynamic_columns)
      typed = public_report(typed_table, dynamic_columns)
      offline = Hash(String, Array(String)).new
      dynamic_columns.each do |column|
        offline[column] = offline_signatures(store_root, entry["table"].as_s, column)
      end
      cells << {
        label: label, compact_pk: compact_pk, typed_pk: typed_pk,
        direct: direct, compact: compact, typed: typed, offline: offline,
      }
    end

    JSON.build(STDOUT) do |json|
      json.object do
        json.field "format", GREEN_FORMAT
        json.field "status", "green_candidate"
        json.field "cells" do
          json.array do
            cells.each do |cell|
              json.object do
                json.field "label", cell[:label]
                json.field "compact_pk", cell[:compact_pk]
                json.field "typed_pk", cell[:typed_pk]
                json.field "direct" do
                  json.object do
                    cell[:direct].each do |column, report|
                      json.field column do
                        json.object do
                          json.field "mark_rows", report[:mark_rows]
                          json.field "full", report[:full]
                          json.field "first", report[:first]
                          json.field "middle", report[:middle]
                          json.field "last", report[:last]
                          json.field "eof", report[:eof]
                        end
                      end
                    end
                  end
                end
                {"compact" => cell[:compact], "typed" => cell[:typed]}.each do |name, report|
                  json.field name do
                    json.object do
                      json.field "mark_rows", report[:mark_rows]
                      {"full" => report[:full], "first" => report[:first], "middle" => report[:middle],
                       "last" => report[:last], "eof" => report[:eof]}.each do |window, scan|
                        json.field window do
                          json.object do
                            json.field "keys", scan[:keys]
                            json.field "columns", scan[:columns]
                          end
                        end
                      end
                    end
                  end
                end
                json.field "offline" do
                  json.object do
                    cell[:offline].each do |column, values|
                      json.field column, values
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
    STDOUT << '\n'
  end

  def self.run(manifest_path : String) : Nil
    manifest = JSON.parse(File.read(manifest_path)).as_h
    unless manifest["format"].as_s == "compact_dynamic_w262_native_manifest_v1"
      raise "wrong W262 native manifest format"
    end
    parts = manifest["parts"].as_a
    expected_labels = %w[
      mrk3_s0_vbasic mrk3_s0_vcompact mrk3_s1_vbasic mrk3_s1_vcompact
      mrk4_s0_vbasic mrk4_s0_vcompact mrk4_s1_vbasic mrk4_s1_vcompact
    ]
    labels = parts.map { |entry| entry["label"].as_s }
    unless labels.sort == expected_labels.sort && labels.uniq.size == labels.size
      raise "W262 manifest labels differ from the sealed eight-cell matrix"
    end

    cells = [] of NamedTuple(
      label: String,
      compact_pk: Array(UInt64),
      typed_pk: Array(UInt64),
      refusals: Array(NamedTuple(api: String, column: String, type: String, error: String)),
    )
    parts.each do |entry|
      label = entry["label"].as_s
      part = File.expand_path(entry["path"].as_s)
      unless File.directory?(part) && !File.symlink?(part)
        raise "W262 #{label} part path is absent or linked"
      end

      compact_pk = read_compact_pk(part)
      typed_pk = read_typed_pk(part)
      expected_pk = (1_u64..8_u64).to_a
      unless compact_pk == expected_pk && typed_pk == expected_pk
        raise "W262 #{label} UInt64 positive read differs: compact=#{compact_pk.inspect}, typed=#{typed_pk.inspect}"
      end

      refusals = [] of NamedTuple(api: String, column: String, type: String, error: String)
      DYNAMIC_COLUMNS.each do |column, source_type|
        parsed = CrystalClick::DynamicBulkColumnDeclaration.parse(source_type)
        raise "W262 Dynamic declaration is not admitted by the context-owned parser: #{source_type}" unless parsed
        raise "W262 Dynamic declaration leaked into static admission: #{source_type}" if CrystalClick::StaticBinaryBulkColumnDeclaration.parse(source_type)
        {"compact", "typed"}.each do |api|
          error = expect_refusal(api, part, column)
          refusals << {api: api, column: column, type: source_type, error: error}
        end
      end
      cells << {label: label, compact_pk: compact_pk, typed_pk: typed_pk, refusals: refusals}
    end

    JSON.build(STDOUT) do |json|
      json.object do
        json.field "format", FORMAT
        json.field "status", "expected_unsupported"
        json.field "cells" do
          json.array do
            cells.each do |cell|
              json.object do
                json.field "label", cell[:label]
                json.field "compact_pk", cell[:compact_pk]
                json.field "typed_pk", cell[:typed_pk]
                json.field "refusals" do
                  json.array do
                    cell[:refusals].each do |refusal|
                      json.object do
                        json.field "api", refusal[:api]
                        json.field "column", refusal[:column]
                        json.field "type", refusal[:type]
                        json.field "error_class", "UnsupportedFormatError"
                        json.field "error", refusal[:error]
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
    STDOUT << '\n'
  end
end

unless ARGV.size == 2 && (ARGV[0] == "baseline" || ARGV[0] == "green")
  abort "usage: check_compact_dynamic_w262 baseline|green MANIFEST.json"
end

case ARGV[0]
when "baseline"
  CheckCompactDynamicW262.run(ARGV[1])
when "green"
  CheckCompactDynamicW262.run_green(ARGV[1])
else
  abort "usage: check_compact_dynamic_w262 baseline|green MANIFEST.json"
end
