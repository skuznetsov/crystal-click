require "../src/crystal_click"
require "file_utils"
require "json"

alias W174ProbeElement = Tuple(UInt64, String, Int32?)
alias W174ProbeRow = Tuple(UInt64, Array(W174ProbeElement))

private def w174_probe_copy_nested_row(row : CrystalClick::WideArrayTupleRow) : Array(W174ProbeElement)
  copied = [] of W174ProbeElement
  row.each do |element|
    copied << {
      element.value_as("a", UInt64),
      element.value_as("b", String),
      element["c"].as(Int32?),
    }
  end
  copied
end

private def w174_probe_append_batch(rows : Array(W174ProbeRow), batch : CrystalClick::WidePartTableBatch) : Nil
  keys = batch.values_for("pk")
  nested_rows = batch.nested_rows_for("nested")
  raise CrystalClick::CorruptPartError.new("probe batch key and Nested row counts differ") unless keys.size == nested_rows.size
  keys.each_with_index do |key, index|
    rows << {key, w174_probe_copy_nested_row(nested_rows[index])}
  end
end

private def w174_probe_append_offline_rows(
  rows : Array(W174ProbeRow),
  keys : Array(UInt64),
  nested_rows : Array(CrystalClick::WideArrayTupleRow),
) : Nil
  raise CrystalClick::CorruptPartError.new("probe offline key and Nested row counts differ") unless keys.size == nested_rows.size
  keys.each_with_index do |key, index|
    rows << {key, w174_probe_copy_nested_row(nested_rows[index])}
  end
end

private def w174_probe_write_rows(json : JSON::Builder, rows : Array(W174ProbeRow)) : Nil
  json.array do
    rows.each do |row|
      json.object do
        json.field "pk", row[0]
        json.field "nested" do
          json.array do
            row[1].each do |element|
              json.object do
                json.field "a", element[0]
                json.field "b", element[1]
                json.field "c", element[2]
              end
            end
          end
        end
      end
    end
  end
end

private def w174_probe_write_types(json : JSON::Builder, types : Array({String, String})) : Nil
  json.array do
    types.each do |column, type|
      json.object do
        json.field "column", column
        json.field "type", type
      end
    end
  end
end

private def w174_probe_write_sources(json : JSON::Builder, sources : Array({String, String, String})) : Nil
  json.array do
    sources.each do |column, source_name, source_type|
      json.object do
        json.field "column", column
        json.field "source_name", source_name
        json.field "source_type", source_type
      end
    end
  end
end

private def w174_probe_offline_root(parent : String, part_path : String, type_name : String) : String
  root = File.join(parent, "catalog")
  database_uuid = "17410000-0000-4000-8000-000000000001"
  table_uuid = "17410000-0000-4000-8000-000000000002"
  metadata = File.join(root, "metadata")
  database = File.join(root, "store", database_uuid[0, 3], database_uuid)
  table = File.join(root, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(metadata)
  FileUtils.mkdir_p(database)
  FileUtils.mkdir_p(table)
  File.write(File.join(metadata, "lab.sql"), "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")
  File.write(
    File.join(database, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `nested` #{type_name}\n)\nENGINE = MergeTree\nORDER BY pk\n"
  )
  File.write(File.join(table, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table, "detached"))
  FileUtils.cp_r(part_path, File.join(table, File.basename(part_path)))
  root
end

private def w174_probe_consumer(part_path : String, output_path : String) : Nil
  if File.exists?(output_path) || File.symlink?(output_path)
    raise CrystalClick::InvalidPartError.new("probe output path already exists")
  end
  unless Dir.exists?(File.dirname(output_path))
    raise CrystalClick::InvalidPartError.new("probe output directory does not exist")
  end

  type_name = "Nested(a UInt64, b String, c Nullable(Int32))"
  reader = CrystalClick::WidePartTable.open_selected_flattened_nested_typed(
    [part_path], ["pk", "nested"], "pk", "nested", type_name
  )
  full_rows = [] of W174ProbeRow
  reader.scan_typed(batch_rows: 2) { |batch| w174_probe_append_batch(full_rows, batch) }

  window_rows = [] of W174ProbeRow
  reader.scan_typed_window(1_u64, 3) { |batch| w174_probe_append_batch(window_rows, batch) }

  empty_row_window = [] of W174ProbeRow
  reader.scan_typed_window(1_u64, 1) { |batch| w174_probe_append_batch(empty_row_window, batch) }

  end_window = [] of W174ProbeRow
  reader.scan_typed_window(5_u64, 2) { |batch| w174_probe_append_batch(end_window, batch) }

  candidate_mark_1 = [] of W174ProbeRow
  reader.scan_typed_candidate_marks([[1]]) { |batch| w174_probe_append_batch(candidate_mark_1, batch) }

  key_reader = CrystalClick::WidePartTable.open_selected_flattened_nested_typed(
    [part_path], ["pk"], "pk", "nested", type_name
  )
  key_only = [] of UInt64
  key_reader.scan_typed do |batch|
    key_only.concat(batch.values_for("pk").to_a)
    nil
  end

  temporary_root = File.tempname("crystal-click-w174-consumer-probe-")
  Dir.mkdir(temporary_root)
  begin
    offline_root = w174_probe_offline_root(temporary_root, part_path, type_name)
    offline = CrystalClick::OfflineCatalog.open(offline_root)["lab"]["events"].with_flattened_nested("nested")
    offline_keys = offline["pk"].values.map(&.as(UInt64))
    offline_values = offline["nested"].values.map(&.as(CrystalClick::WideArrayTupleRow))
    offline_rows = [] of W174ProbeRow
    w174_probe_append_offline_rows(offline_rows, offline_keys, offline_values)

    offline_window = [] of W174ProbeRow
    offline.scan_typed_window(["pk", "nested"], 1_u64, 3) do |batch|
      w174_probe_append_batch(offline_window, batch)
    end

    offline_candidates = [] of W174ProbeRow
    offline.scan_uint64_pk_candidates(["pk", "nested"], 23_u64, 31_u64) do |batch|
      w174_probe_append_batch(offline_candidates, batch)
    end

    File.write(output_path, JSON.build do |json|
      json.object do
        json.field "type_name", type_name
        json.field "part_basename", File.basename(part_path)
        json.field "table" do
          json.object do
            json.field "header" do
              json.object do
                json.field "columns", reader.columns
                json.field "types" { w174_probe_write_types(json, reader.column_types) }
                json.field "sources" { w174_probe_write_sources(json, reader.column_sources) }
              end
            end
            json.field "full" { w174_probe_write_rows(json, full_rows) }
            json.field "window_1_3" { w174_probe_write_rows(json, window_rows) }
            json.field "empty_row_window_1_1" { w174_probe_write_rows(json, empty_row_window) }
            json.field "end_window_5_2" { w174_probe_write_rows(json, end_window) }
            json.field "candidate_mark_1" { w174_probe_write_rows(json, candidate_mark_1) }
            json.field "key_only" do
              json.object do
                json.field "columns", key_reader.columns
                json.field "types" { w174_probe_write_types(json, key_reader.column_types) }
                json.field "sources" { w174_probe_write_sources(json, key_reader.column_sources) }
                json.field "values", key_only
              end
            end
          end
        end
        json.field "offline" do
          json.object do
            json.field "primary_key_column", offline.primary_key_column
            json.field "metadata_ddl", offline.metadata_ddl
            json.field "columns" do
              json.array do
                offline.columns.each do |column|
                  json.object do
                    json.field "name", column.name
                    json.field "type", column.type
                    json.field "alias", column.alias_column
                    json.field "key_candidate", column.key_candidate_column
                  end
                end
              end
            end
            json.field "values" { w174_probe_write_rows(json, offline_rows) }
            json.field "window_1_3" { w174_probe_write_rows(json, offline_window) }
            json.field "pk_candidates_23_31" { w174_probe_write_rows(json, offline_candidates) }
          end
        end
      end
    end)
  ensure
    FileUtils.rm_rf(temporary_root)
  end
end

if ARGV.size == 3 && ARGV[0] == "--consumer"
  begin
    w174_probe_consumer(ARGV[1], ARGV[2])
  rescue ex
    STDERR.puts "CONSUMER_PROBE_FAILURE #{ex.class}: #{ex.message}"
    exit 2
  end
  exit 0
end

unless ARGV.size == 2 && ARGV[0] == "--baseline"
  STDERR.puts "usage: crystal scripts/check_flattened_nested_consumers_w174_probe.cr --baseline PART_PATH | --consumer PART_PATH OUTPUT_JSON"
  exit 64
end

part_path = ARGV[1]

begin
  CrystalClick::WidePartTable.open_selected_typed([part_path], ["pk", "nested"])
rescue ex : CrystalClick::UnsupportedFormatError
  STDERR.puts "BASELINE_REFUSAL #{ex.class}: #{ex.message}"
  exit 0
rescue ex
  STDERR.puts "BASELINE_UNEXPECTED_EXCEPTION #{ex.class}: #{ex.message}"
  exit 2
end

STDERR.puts "BASELINE_UNEXPECTED_ACCEPTANCE ordinary typed table route accepted flattened Nested"
exit 1
