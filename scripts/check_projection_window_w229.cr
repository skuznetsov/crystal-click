#!/usr/bin/env crystal
# Read-only library consumer probe for stock-authored projection children.
# The Ruby runner owns all native ClickHouse calls and evidence capture.

require "json"
require "../src/crystal_click"

W229_DATABASE     = "w217_specialized_projection"
W229_PARENT_PARTS = ["all_1_1_0", "all_2_2_0"]

struct W229Window
  getter profile : String
  getter consumer : String
  getter name : String
  getter start_row : UInt64
  getter max_rows : Int32
  getter exception : String?
  getter callback_count : Int32
  getter rows : Array(W229Row)

  def initialize(
    @profile : String,
    @consumer : String,
    @name : String,
    @start_row : UInt64,
    @max_rows : Int32,
    @exception : String?,
    @callback_count : Int32,
    @rows : Array(W229Row),
  )
  end
end

struct W229Row
  getter parent_part : String
  getter child_mark_index : Int32
  getter child_mark_row_offset : UInt64
  getter child_part_row_offset : UInt64
  getter source_row_offset : UInt64
  getter values : Array(String)

  def initialize(
    @parent_part : String,
    @child_mark_index : Int32,
    @child_mark_row_offset : UInt64,
    @child_part_row_offset : UInt64,
    @source_row_offset : UInt64,
    @values : Array(String),
  )
  end
end

struct W229Profile
  getter id : String
  getter table_name : String
  getter columns : Array(String)
  getter kind : String

  def initialize(@id : String, @table_name : String, @columns : Array(String), @kind : String)
  end
end

private def w229_assert(condition : Bool, message : String) : Nil
  raise "W229 projection-window helper: #{message}" unless condition
end

private def w229_profiles : Array(W229Profile)
  [
    W229Profile.new("whole_json", "whole_json", ["pk", "payload"], "object"),
    W229Profile.new("array_json", "array_json", ["pk", "a"], "array_object"),
    W229Profile.new("recursive_json", "recursive_json", ["pk", "payload"], "recursive"),
    W229Profile.new("dynamic_root", "dynamic_root", ["pk", "payload"], "dynamic"),
    W229Profile.new("dynamic_array", "dynamic_array", ["pk", "wrapped"], "dynamic_array"),
    W229Profile.new("count", "count_parent", ["intDiv(pk, 2)", "count()"], "count"),
  ]
end

private def w229_dynamic_signature(value : CrystalClick::BinaryValue) : Tuple(String, String)
  w229_assert(value.type.tag == CrystalClick::BinaryDataType::TAG_DYNAMIC,
    "Dynamic value lost its wrapper: #{value.type.name}")
  w229_assert(value.element_count == 1, "Dynamic child count differs: #{value.element_count}")
  child = value.element_at(0)
  {child.type.name, child.as_uint64.to_s}
end

private def w229_values(batch : CrystalClick::WidePartTableBatch, profile : W229Profile) : Array(Array(String))
  case profile.kind
  when "object"
    keys = batch.values_for("pk", UInt64)
    object_documents = batch.object_documents_for("payload")
    w229_assert(keys.size == object_documents.size, "JSON row alignment differs")
    Array(Array(String)).new(keys.size) do |index|
      [keys[index].to_s, object_documents[index].value_for("t").as_uint64.to_s]
    end
  when "array_object"
    keys = batch.values_for("pk", UInt64)
    array_documents = batch.array_object_documents_for("a")
    w229_assert(keys.size == array_documents.size, "Array(JSON) row alignment differs")
    Array(Array(String)).new(keys.size) do |index|
      array_texts = array_documents[index].map { |document| document.value_for("t").bytes[0].to_s }
      [keys[index].to_s, array_texts.size.to_s, array_texts.empty? ? "-" : array_texts.join(",")]
    end
  when "recursive"
    keys = batch.values_for("pk", UInt64)
    recursive_values = batch.recursive_values_for("payload")
    w229_assert(keys.size == recursive_values.size, "recursive JSON row alignment differs")
    Array(Array(String)).new(keys.size) do |index|
      recursive_row = recursive_values[index]
      document = recursive_row.child_at(0).object_document
      [keys[index].to_s, document.value_for("t").bytes[0].to_s, recursive_row.child_at(1).bulk_value.as_uint64.to_s]
    end
  when "dynamic"
    keys = batch.values_for("pk", UInt64)
    dynamic_values = batch.dynamic_bulk_values_for("payload")
    w229_assert(keys.size == dynamic_values.size, "Dynamic row alignment differs")
    Array(Array(String)).new(keys.size) do |index|
      child_type, child_value = w229_dynamic_signature(dynamic_values[index])
      [keys[index].to_s, child_type, child_value]
    end
  when "dynamic_array"
    keys = batch.values_for("pk", UInt64)
    dynamic_array_values = batch.dynamic_bulk_values_for("wrapped")
    w229_assert(keys.size == dynamic_array_values.size, "Array(Dynamic) row alignment differs")
    Array(Array(String)).new(keys.size) do |index|
      dynamic_array = dynamic_array_values[index]
      w229_assert(dynamic_array.type.name == "Array(Dynamic(max_types=1))",
        "Array(Dynamic) nominal type differs: #{dynamic_array.type.name}")
      signatures = dynamic_array.elements.map { |item| w229_dynamic_signature(item) }
      [keys[index].to_s, signatures.size.to_s,
       signatures.empty? ? "-" : signatures.map(&.[0]).join(","),
       signatures.empty? ? "-" : signatures.map(&.[1]).join(",")]
    end
  when "count"
    keys = batch.values_for("intDiv(pk, 2)", UInt64)
    states = batch.aggregate_count_states_for("count()", CrystalClick::BinaryDataType.aggregate_count)
    w229_assert(keys.size == states.size, "Count key/state row alignment differs")
    Array(Array(String)).new(keys.size) do |index|
      [keys[index].to_s, states[index].count_state.to_s]
    end
  else
    raise "unhandled W229 profile kind: #{profile.kind}"
  end
end

private def w229_collect_window(
  profile : W229Profile,
  consumer : String,
  name : String,
  start_row : UInt64,
  max_rows : Int32,
  scan : Proc(Proc(CrystalClick::WidePartTableBatch, Nil), Nil),
) : W229Window
  rows = [] of W229Row
  callbacks = 0
  exception = nil.as(String?)
  collector = ->(batch : CrystalClick::WidePartTableBatch) do
    callbacks += 1
    values = w229_values(batch, profile)
    values.each_with_index do |value_row, index|
      row_index = index.to_u64
      rows << W229Row.new(
        batch.part_name,
        batch.mark_index,
        batch.mark_row_offset &+ row_index,
        batch.part_row_offset &+ row_index,
        batch.source_row_offset &+ row_index,
        value_row,
      )
    end
    nil
  end
  begin
    scan.call(collector)
  rescue error : CrystalClick::BoundsError
    exception = error.class.name
  end
  W229Window.new(profile.id, consumer, name, start_row, max_rows, exception, callbacks, rows)
end

private def w229_window_matrix(profile : W229Profile) : Array(Tuple(String, UInt64, Int32))
  child_rows = profile.kind == "count" ? 3_u64 : 6_u64
  total_rows = child_rows * W229_PARENT_PARTS.size.to_u64
  middle_start = profile.kind == "count" ? 1_u64 : 2_u64
  middle_rows = profile.kind == "count" ? 3 : 4
  [
    {"full", 0_u64, total_rows.to_i32},
    {"middle", middle_start, middle_rows},
    {"cross_child", child_rows - 1_u64, 3},
    {"eof", total_rows, 2},
    {"past_eof", total_rows + 1_u64, 1},
  ]
end

private def w229_add_consumer_windows(
  output : Array(W229Window),
  store : String,
  profile : W229Profile,
  paths : Array(String),
) : Nil
  w229_window_matrix(profile).each do |name, start_row, max_rows|
    {"low_level", "offline"}.each do |consumer|
      if consumer == "offline"
        catalog = CrystalClick::OfflineCatalog.open(store)
        table = catalog.table(W229_DATABASE, profile.table_name)
        scan = ->(callback : Proc(CrystalClick::WidePartTableBatch, Nil)) do
          table.scan_projection_typed_window("p", profile.columns, start_row, max_rows, &callback)
        end
        output << w229_collect_window(profile, consumer, name, start_row, max_rows, scan)
      else
        reader = CrystalClick::WidePartTable.open_selected_projection_typed(paths, "p", profile.columns)
        w229_assert(reader.total_row_count == (profile.kind == "count" ? 6_u64 : 12_u64),
          "low-level selected child row count differs for #{profile.id}")
        scan = ->(callback : Proc(CrystalClick::WidePartTableBatch, Nil)) do
          reader.scan_typed_window(start_row, max_rows, &callback)
        end
        output << w229_collect_window(profile, consumer, name, start_row, max_rows, scan)
      end
    end
  end
  nil
end

private def w229_emit(root : String) : Nil
  windows = [] of W229Window
  w229_profiles.each do |profile|
    store = File.join(root, "stores", profile.id)
    w229_assert(File.directory?(store) && !File.symlink?(store), "missing plain W217 store for #{profile.id}")
    catalog = CrystalClick::OfflineCatalog.open(store)
    table = catalog.table(W229_DATABASE, profile.table_name)
    candidates = table.part_candidates
    w229_assert(candidates.map(&.name) == W229_PARENT_PARTS,
      "parent part order differs for #{profile.id}: #{candidates.map(&.name).inspect}")
    paths = candidates.map(&.path)
    w229_assert(candidates.map(&.row_count).sum == 12_u64,
      "parent row total differs for #{profile.id}")
    w229_add_consumer_windows(windows, store, profile, paths)
  end

  json_output = JSON.build do |json|
    json.object do
      json.field "format", "projection_window_w229_helper_v1"
      json.field "fixture_root", root
      json.field "windows" do
        json.array do
          windows.each do |window|
            json.object do
              json.field "profile", window.profile
              json.field "consumer", window.consumer
              json.field "window", window.name
              json.field "start_row", window.start_row
              json.field "max_rows", window.max_rows
              json.field "exception", window.exception
              json.field "callback_count", window.callback_count
              json.field "rows" do
                json.array do
                  window.rows.each do |row|
                    json.object do
                      json.field "parent_part", row.parent_part
                      json.field "child_mark_index", row.child_mark_index
                      json.field "child_mark_row_offset", row.child_mark_row_offset
                      json.field "child_part_row_offset", row.child_part_row_offset
                      json.field "source_row_offset", row.source_row_offset
                      json.field "values" do
                        json.array do
                          row.values.each { |value| json.string(value) }
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
    end
  end
  puts json_output
end

if ARGV.size != 2 || ARGV[0] != "--fixture-root"
  raise "usage: check_projection_window_w229.cr --fixture-root /private/tmp/crystal-click-w229-fixtures-..."
end
fixture_root_arg = ARGV[1]
w229_assert(File.expand_path(fixture_root_arg) == fixture_root_arg && !File.symlink?(fixture_root_arg),
  "fixture root must be a canonical non-symlink path")
fixture_root = File.real_path(fixture_root_arg)
w229_assert(File.dirname(fixture_root) == "/private/tmp" && File.basename(fixture_root).starts_with?("crystal-click-w229-fixtures-"),
  "fixture root must be a direct W229 fixture child of /private/tmp")
w229_stores_root = File.join(fixture_root, "stores")
w229_assert(Dir.exists?(w229_stores_root) && !File.symlink?(w229_stores_root), "missing plain W217 stores directory")
w229_expected_store_names = w229_profiles.map(&.id).sort
w229_actual_store_names = Dir.children(w229_stores_root).sort
w229_assert(w229_actual_store_names == w229_expected_store_names,
  "W217 stores roster differs: #{w229_actual_store_names.inspect}")
w229_emit(fixture_root)
