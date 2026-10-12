require "json"
require "digest/sha256"
require "../src/crystal_click"
require "./support/compact_json_w263_fixture"

alias W263RootMatrixOperation = NamedTuple(
  name: String,
  status: String,
  phase: String,
  error_class: String?,
  error: String?,
)

alias W263RootMatrixCell = NamedTuple(
  label: String,
  table: String,
  source_mark_format: String,
  layout_status: String,
  operations: Array(W263RootMatrixOperation),
)

private def w263_root_matrix_require!(condition : Bool, message : String) : Nil
  raise CrystalClick::CorruptPartError.new(message) unless condition
end

private def w263_root_matrix_labels : Array(String)
  layouts = [
    "obj_v1_dyn_v1_map",
    "obj_v2_dyn_v2_map",
    "obj_v3_dyn_v3_map",
    "obj_v3_dyn_v3_map_with_buckets",
    "obj_v3_dyn_v3_advanced",
    "obj_v3_dyn_v3_advanced_chunked",
  ]
  labels = [] of String
  layouts.each do |layout|
    {"mrk3", "mrk4"}.each do |mark_format|
      {"s0", "s1"}.each do |string_version|
        {"variant_basic", "variant_compact"}.each do |variant|
          labels << "#{layout}_#{mark_format}_#{string_version}_#{variant}"
        end
      end
    end
  end
  labels
end

private def w263_root_matrix_schema_records : Array(Tuple(String, String, String))
  records = [] of Tuple(String, String, String)
  w263_root_matrix_labels.each do |label|
    table = "w263_#{label}"
    CompactJsonW263Fixture::SCHEMA.each do |name, type|
      records << {table, name, type}
    end
  end
  records
end

private def w263_root_matrix_decode_hex(hex : String) : Bytes
  source = hex.to_slice
  unless source.size.even?
    raise CrystalClick::CorruptPartError.new("W263 native root JSON hex has an odd byte count")
  end
  bytes = Bytes.new(source.size // 2)
  bytes.size.times do |index|
    high = w263_root_matrix_hex_nibble(source[index * 2])
    low = w263_root_matrix_hex_nibble(source[index * 2 + 1])
    bytes[index] = ((high << 4) | low).to_u8
  end
  bytes
end

private def w263_root_matrix_hex_nibble(byte : UInt8) : UInt8
  case byte
  when '0'.ord.to_u8..'9'.ord.to_u8
    (byte - '0'.ord.to_u8).to_u8
  when 'a'.ord.to_u8..'f'.ord.to_u8
    (byte - 'a'.ord.to_u8 + 10).to_u8
  when 'A'.ord.to_u8..'F'.ord.to_u8
    (byte - 'A'.ord.to_u8 + 10).to_u8
  else
    raise CrystalClick::CorruptPartError.new("W263 native root JSON hex contains a non-hex byte")
  end
end

private def w263_root_matrix_json_any(value : CrystalClick::BinaryValue) : JSON::Any
  case value.type.tag
  when CrystalClick::BinaryDataType::TAG_JSON
    fields = Hash(String, JSON::Any).new
    value.json_row.entries.each do |path, child|
      fields[path] = w263_root_matrix_json_any(child)
    end
    JSON::Any.new(fields)
  when CrystalClick::BinaryDataType::TAG_STRING
    JSON::Any.new(value.as_string)
  when CrystalClick::BinaryDataType::TAG_UINT8
    JSON::Any.new(value.byte_at(0).to_i64)
  when CrystalClick::BinaryDataType::TAG_UINT64
    JSON::Any.new(value.as_uint64.to_i64)
  when CrystalClick::BinaryDataType::TAG_INT64
    JSON::Any.new(value.as_int64)
  when CrystalClick::BinaryDataType::TAG_FLOAT64
    JSON::Any.new(value.as_float64_bits.unsafe_as(Float64))
  else
    raise CrystalClick::UnsupportedFormatError.new("W263 native root JSON oracle lacks #{value.type.name}")
  end
end

private def w263_root_matrix_document_signature(document : CrystalClick::ObjectDocument) : String
  entries = document.paths.sort.map do |path|
    "#{path}=#{CompactJsonW263Fixture.value_signature(document.value_for(path))}"
  end
  "#{CompactJsonW263Fixture.json_type.name}{#{entries.join(",")}}"
end

private def w263_root_matrix_assert_native_rows!(
  summary : JSON::Any,
  label : String,
  expected_values : Array(CrystalClick::BinaryValue),
) : Nil
  native_rows = summary["native_rows"].as_h
  table = "w263_#{label}"
  expected_values.each_with_index do |expected_value, index|
    key = "#{table}|#{index + 1}"
    row = native_rows[key]?.try(&.as_a) ||
          raise CrystalClick::CorruptPartError.new("W263 native root JSON oracle lacks #{key}")
    unless row.size > 7
      raise CrystalClick::CorruptPartError.new("W263 native root JSON oracle row is truncated for #{key}")
    end
    actual = JSON.parse(String.new(w263_root_matrix_decode_hex(row[7].as_s)))
    expected = w263_root_matrix_json_any(expected_value)
    unless actual.as_h == expected.as_h
      raise CrystalClick::CorruptPartError.new("W263 native root JSON differs from the independent literal for #{key}")
    end
  end
  nil
end

private def w263_root_matrix_summary_cell(summary : JSON::Any, label : String) : JSON::Any
  summary["helper"]["result"]["cells"].as_a.find { |cell| cell["label"].as_s == label } ||
    raise CrystalClick::CorruptPartError.new("W263 helper layout evidence lacks #{label}")
end

private def w263_root_matrix_assert_physical_layout!(part_path : String, label : String, summary : JSON::Any) : String
  evidence = w263_root_matrix_summary_cell(summary, label)["persisted_root_layout"]
  expected_format = evidence["mark_format"].as_s
  physical = CrystalClick::CompactPartPhysicalContext.open(part_path)
  actual_format = physical.mode.mrk3? ? "mrk3" : (physical.mode.mrk4? ? "mrk4" : "unsupported")
  w263_root_matrix_require!(actual_format == expected_format, "W263 source/helper mark formats differ for #{label}")
  expected_granules = evidence["granules"].as_a
  w263_root_matrix_require!(expected_granules.size == physical.granule_count, "W263 saved mark count differs for #{label}")
  window = physical.read_window("root", 0, physical.granule_count)
  actual_granules = window.granules
  w263_root_matrix_require!(actual_granules.size == expected_granules.size, "W263 root physical window differs for #{label}")
  expected_granules.each_with_index do |expected, index|
    actual = actual_granules[index]
    w263_root_matrix_require!(actual.mark == expected["mark"].as_i, "W263 root physical mark index differs for #{label}")
    w263_root_matrix_require!(actual.row_offset == expected["row_offset"].as_i64.to_u64, "W263 root physical row offset differs for #{label}")
    w263_root_matrix_require!(actual.row_count == expected["row_count"].as_i64.to_u64, "W263 root physical row count differs for #{label}")
    expected_shards = expected["shards"].as_a
    actual_shards = actual.shards
    w263_root_matrix_require!(actual_shards.size == expected_shards.size, "W263 root shard count differs for #{label} mark #{index}")
    expected_shards.each_with_index do |expected_shard, shard_index|
      shard = actual_shards[shard_index]
      expected_stream = expected_shard["stream"]?.try(&.as_s?)
      w263_root_matrix_require!(shard.slot_index == expected_shard["slot"].as_i, "W263 root shard slot differs for #{label} mark #{index}")
      w263_root_matrix_require!(shard.stream_name == expected_stream, "W263 root shard stream differs for #{label} mark #{index}")
      w263_root_matrix_require!(shard.bytes.size == expected_shard["bytes"].as_i, "W263 root shard length differs for #{label} mark #{index}")
      w263_root_matrix_require!(shard.logical_start == expected_shard["logical_start"].as_i64, "W263 root shard start differs for #{label} mark #{index}")
      w263_root_matrix_require!(shard.logical_end == expected_shard["logical_end"].as_i64, "W263 root shard end differs for #{label} mark #{index}")
    end
  end
  actual_format
end

private def w263_root_matrix_inventory(manifest_entry : JSON::Any) : Array(Tuple(String, Int64, String))
  manifest_entry["file_inventory"].as_a.map do |item|
    {item["path"].as_s, item["bytes"].as_i64, item["sha256"].as_s}
  end
end

private def w263_root_matrix_part_path(
  root : String,
  store_root : String,
  label : String,
  summary : JSON::Any,
  summary_record : JSON::Any,
  manifest_entry : JSON::Any,
) : String
  table = "w263_#{label}"
  mark_extension = label.includes?("_mrk3_") ? ".mrk3" : ".mrk4"
  w263_root_matrix_require!(summary_record["part_type"].as_s == "Compact", "W263 summary part is not Compact for #{label}")
  w263_root_matrix_require!(summary_record["rows"].as_s == CompactJsonW263Fixture::ROWS.to_s, "W263 summary row count differs for #{label}")
  w263_root_matrix_require!(summary_record["marks"].as_s.to_i == CompactJsonW263Fixture::MARK_ROWS.size + 1, "W263 summary physical mark count differs for #{label}")
  w263_root_matrix_require!(summary_record["mark_extension"].as_s == mark_extension, "W263 summary mark extension differs for #{label}")
  w263_root_matrix_require!(manifest_entry["table"].as_s == table, "W263 native manifest table differs for #{label}")
  w263_root_matrix_require!(manifest_entry["part_type"].as_s == "Compact", "W263 native manifest part is not Compact for #{label}")
  w263_root_matrix_require!(manifest_entry["rows"].as_s == CompactJsonW263Fixture::ROWS.to_s, "W263 native manifest row count differs for #{label}")
  w263_root_matrix_require!(manifest_entry["marks"].as_s.to_i == CompactJsonW263Fixture::MARK_ROWS.size + 1, "W263 native manifest physical mark count differs for #{label}")
  w263_root_matrix_require!(manifest_entry["mark_extension"].as_s == mark_extension, "W263 native manifest mark extension differs for #{label}")
  w263_root_matrix_require!(summary_record["path"].as_s == manifest_entry["path"].as_s, "W263 summary/native manifest path differs for #{label}")

  source_part = File.realpath(manifest_entry["path"].as_s)
  store_prefix = store_root.ends_with?(File::SEPARATOR) ? store_root : store_root + File::SEPARATOR
  w263_root_matrix_require!(source_part.starts_with?(store_prefix), "W263 source part escapes the authenticated native store for #{label}")
  w263_root_matrix_require!(File.basename(source_part) == CompactJsonW263Fixture::PART_NAME, "W263 source part identity differs for #{label}")
  CompactJsonW263Fixture.assert_native_inventory!(source_part, w263_root_matrix_inventory(manifest_entry))

  serialization_path = File.join(source_part, "serialization.json")
  serialization = JSON.parse(File.read(serialization_path))
  w263_root_matrix_require!(serialization == summary_record["serialization"], "W263 serialization metadata differs from summary for #{label}")
  expected_string_version = label.includes?("_s1_") ? 1 : 0
  actual_string_version = serialization["types_serialization_versions"]["string"].as_i
  w263_root_matrix_require!(actual_string_version == expected_string_version, "W263 string serialization version differs from label for #{label}")
  source_part
end

private def w263_root_matrix_authenticate!(root : String) : {JSON::Any, JSON::Any, String, Array(String)}
  summary_path = File.join(root, "summary.json")
  manifest_path = File.join(root, "parts", "native_manifest.json")
  {summary_path, manifest_path}.each do |path|
    unless File.file?(path) && !File.symlink?(path) && File.realpath(path) == path
      raise CrystalClick::CorruptPartError.new("W263 evidence metadata is absent, linked or noncanonical: #{path}")
    end
    if File.size(path) > 4 * 1024 * 1024
      raise CrystalClick::CorruptPartError.new("W263 evidence metadata exceeds its bound: #{path}")
    end
  end
  summary = JSON.parse(File.read(summary_path))
  manifest = JSON.parse(File.read(manifest_path))
  labels = w263_root_matrix_labels
  w263_root_matrix_require!(summary["format"].as_s == "compact_json_w263_probe_summary_v1", "W263 summary format differs")
  w263_root_matrix_require!(manifest["format"].as_s == CompactJsonW263Fixture::NATIVE_MANIFEST_FORMAT, "W263 native manifest format differs")
  w263_root_matrix_require!(summary["mode"].as_s == "baseline" && manifest["mode"].as_s == "baseline", "W263 evidence is not the pinned baseline capture")
  w263_root_matrix_require!(summary["row_count"].as_i == CompactJsonW263Fixture::ROWS, "W263 summary row count differs")
  w263_root_matrix_require!(summary["mark_rows"].as_a.map { |rows| rows.as_i64.to_u64 } == CompactJsonW263Fixture::MARK_ROWS, "W263 summary mark grid differs")
  w263_root_matrix_require!(summary["cells"].as_a.map(&.as_s).sort == labels.sort, "W263 summary label roster differs")
  w263_root_matrix_require!(summary["parts"].as_h.size == labels.size, "W263 summary part roster differs")
  w263_root_matrix_require!(manifest["parts"].as_a.size == labels.size, "W263 native manifest part roster differs")
  w263_root_matrix_require!(summary["helper"]["result"]["cells"].as_a.size == labels.size, "W263 helper layout roster differs")
  w263_root_matrix_require!(summary["native_rows"].as_h.size == labels.size * CompactJsonW263Fixture::ROWS, "W263 native row literal roster differs")
  w263_root_matrix_require!(summary["native_invocation"]["exit"].as_i == 0, "W263 native capture did not exit successfully")
  w263_root_matrix_require!(summary["native_invocation"]["process_classification"].as_s == "success", "W263 native capture was not classified as successful")
  w263_root_matrix_require!(summary["clickhouse"]["sha256"].as_s == CompactJsonW263Fixture::NATIVE_BINARY_SHA256, "W263 ClickHouse binary hash differs")
  w263_root_matrix_require!(summary["clickhouse"]["version"].as_s == CompactJsonW263Fixture::NATIVE_VERSION, "W263 ClickHouse version differs")
  w263_root_matrix_require!(summary["clickhouse"]["build"].as_s == CompactJsonW263Fixture::NATIVE_BUILD, "W263 ClickHouse build differs")
  w263_root_matrix_require!(summary["native_invocation"]["binary_sha_after"].as_s == CompactJsonW263Fixture::NATIVE_BINARY_SHA256, "W263 ClickHouse binary changed during capture")
  w263_root_matrix_require!(summary["source_snapshot"]["revision"].as_s == CompactJsonW263Fixture::NATIVE_SOURCE_REVISION, "W263 ClickHouse source revision differs")
  w263_root_matrix_require!(manifest["clickhouse"]["sha256"].as_s == CompactJsonW263Fixture::NATIVE_BINARY_SHA256, "W263 native manifest binary hash differs")
  w263_root_matrix_require!(manifest["clickhouse"]["version"].as_s == CompactJsonW263Fixture::NATIVE_VERSION, "W263 native manifest version differs")
  w263_root_matrix_require!(manifest["clickhouse"]["build"].as_s == CompactJsonW263Fixture::NATIVE_BUILD, "W263 native manifest build differs")
  w263_root_matrix_require!(manifest["source_snapshot"]["revision"].as_s == CompactJsonW263Fixture::NATIVE_SOURCE_REVISION, "W263 native manifest source revision differs")

  expected_schemas = w263_root_matrix_schema_records
  actual_schemas = summary["schemas"].as_a.map do |entry|
    fields = entry.as_a
    w263_root_matrix_require!(fields.size == 3, "W263 summary schema record is malformed")
    {fields[0].as_s, fields[1].as_s, fields[2].as_s}
  end
  w263_root_matrix_require!(actual_schemas.size == expected_schemas.size, "W263 summary schema roster size differs")
  expected_schemas.each do |expected|
    w263_root_matrix_require!(actual_schemas.includes?(expected), "W263 summary schema is missing #{expected[0]}.#{expected[1]}")
  end

  repo_root = File.expand_path("..", __DIR__)
  summary["source_hashes"].as_a.each do |source|
    path = source["path"].as_s
    prefix = repo_root.ends_with?(File::SEPARATOR) ? repo_root : repo_root + File::SEPARATOR
    unless path.starts_with?(prefix) && File.file?(path) && !File.symlink?(path) && File.realpath(path) == path
      raise CrystalClick::CorruptPartError.new("W263 source pin is outside this checkout or noncanonical: #{path}")
    end
    expected_sha = source["sha256"].as_s
    actual_sha = Digest::SHA256.hexdigest(File.read(path))
    w263_root_matrix_require!(actual_sha == expected_sha, "W263 pinned source changed: #{path}")
  end
  fixture_path = File.join(repo_root, "scripts", "support", "compact_json_w263_fixture.cr")
  w263_root_matrix_require!(summary["source_hashes"].as_a.any? { |entry| entry["path"].as_s == fixture_path }, "W263 summary does not pin the independent Crystal fixture")

  store_root = File.realpath(manifest["store_root"].as_s)
  expected_store_root = File.realpath(File.join(root, "stores", "native"))
  w263_root_matrix_require!(store_root == expected_store_root, "W263 native store path differs from the supplied evidence root")
  manifest_parts = manifest["parts"].as_a
  manifest_labels = manifest_parts.map(&.["label"].as_s)
  w263_root_matrix_require!(manifest_labels.sort == labels.sort, "W263 native manifest label roster differs")
  {summary, manifest, store_root, labels}
end

private def w263_root_matrix_run_operation(
  part_path : String,
  label : String,
  operation_name : String,
  first_mark : Int32,
  mark_count : Int32,
  expected_signatures : Array(String),
) : W263RootMatrixOperation
  phase = "open"
  begin
    reader = CrystalClick::CompactStaticJsonBulkColumnReader.open(
      part_path,
      "root",
      CompactJsonW263Fixture.json_type,
    )
    w263_root_matrix_require!(reader.row_count == CompactJsonW263Fixture::ROWS.to_u64, "W263 reader row count differs for #{label}")
    w263_root_matrix_require!(reader.mark_count == CompactJsonW263Fixture::MARK_ROWS.size, "W263 reader mark count differs for #{label}")
    w263_root_matrix_require!(reader.mark_row_counts == CompactJsonW263Fixture::MARK_ROWS, "W263 reader mark grid differs for #{label}")

    phase = "read_marks"
    actual_marks = reader.read_marks(first_mark, mark_count)
    phase = "prepared_context"
    w263_root_matrix_require!(reader.prepared_context.mark_count == reader.mark_count, "W263 reader did not publish complete EOF-first preparation for #{label}")
    actual_signatures = actual_marks.flat_map do |mark|
      mark.map { |document| w263_root_matrix_document_signature(document) }
    end
    w263_root_matrix_require!(actual_signatures == expected_signatures, "W263 #{operation_name} root values differ from independent literals for #{label}")
    {name: operation_name, status: "pass", phase: "complete", error_class: nil, error: nil}
  rescue ex
    {name: operation_name, status: "error", phase: phase, error_class: ex.class.name, error: ex.message || ""}
  end
end

private def w263_root_matrix_run_cell(
  root : String,
  store_root : String,
  summary : JSON::Any,
  manifest : JSON::Any,
  label : String,
) : W263RootMatrixCell
  table = "w263_#{label}"
  summary_record = summary["parts"][label]
  manifest_entry = manifest["parts"].as_a.find { |item| item["label"].as_s == label } ||
                   raise CrystalClick::CorruptPartError.new("W263 native manifest part disappeared for #{label}")
  source_mark_format = label.includes?("_mrk3_") ? "mrk3" : "mrk4"
  layout_status = "error"
  operations = [] of W263RootMatrixOperation

  part_path = w263_root_matrix_part_path(root, store_root, label, summary, summary_record, manifest_entry)
  begin
    w263_root_matrix_assert_native_rows!(summary, label, CompactJsonW263Fixture.root_values)
    actual_format = w263_root_matrix_assert_physical_layout!(part_path, label, summary)
    layout_status = "pass"
    w263_root_matrix_require!(actual_format == source_mark_format, "W263 reader source mark family differs from label for #{label}")
  rescue ex
    operations << {name: "authenticated_layout_and_native_oracles", status: "error", phase: "layout_and_native_oracles", error_class: ex.class.name, error: ex.message || ""}
    return {label: label, table: table, source_mark_format: source_mark_format, layout_status: layout_status, operations: operations}
  end

  expected = CompactJsonW263Fixture.expected_signatures["root"]
  selections = [
    {"eof_first", CompactJsonW263Fixture::MARK_ROWS.size.to_i32, 0_i32, [] of String},
    {"single_mark_0", 0_i32, 1_i32, expected[0, 2]},
    {"cross_marks_1_2", 1_i32, 2_i32, expected[2, 4]},
    {"full_column", 0_i32, CompactJsonW263Fixture::MARK_ROWS.size.to_i32, expected},
  ]
  selections.each do |name, first, count, expected_rows|
    operations << w263_root_matrix_run_operation(part_path, label, name, first, count, expected_rows)
  end
  {label: label, table: table, source_mark_format: source_mark_format, layout_status: layout_status, operations: operations}
end

private def w263_root_matrix_write_result(json : JSON::Builder, result : W263RootMatrixCell) : Nil
  json.object do
    json.field "label", result[:label]
    json.field "table", result[:table]
    json.field "source_mark_format", result[:source_mark_format]
    json.field "layout_status", result[:layout_status]
    json.field "operations" do
      json.array do
        result[:operations].each do |operation|
          json.object do
            json.field "name", operation[:name]
            json.field "status", operation[:status]
            json.field "phase", operation[:phase]
            json.field "error_class", operation[:error_class] if operation[:error_class]
            json.field "error", operation[:error] if operation[:error]
          end
        end
      end
    end
  end
  nil
end

begin
  unless ARGV.size == 1
    raise ArgumentError.new("usage: crystal scripts/check_compact_static_json_root_matrix_w263.cr <baseline-evidence-root>")
  end
  supplied_root = ARGV[0]
  root = File.realpath(supplied_root)
  unless Dir.exists?(root) && File.expand_path(supplied_root) == root
    raise ArgumentError.new("W263 evidence root is absent or noncanonical")
  end

  summary, manifest, store_root, labels = w263_root_matrix_authenticate!(root)
  results = labels.map do |label|
    w263_root_matrix_run_cell(root, store_root, summary, manifest, label)
  end
  failed_cells = results.count do |cell|
    cell[:layout_status] != "pass" || cell[:operations].any? { |operation| operation[:status] != "pass" }
  end

  report = JSON.build do |json|
    json.object do
      json.field "format", "compact_static_json_root_matrix_w263_diagnostic_v1"
      json.field "evidence_root", root
      json.field "capture_mode", manifest["mode"].as_s
      # This is capture provenance only. It does not set the expected reader result.
      json.field "capture_status_provenance", summary["status"].as_s
      json.field "native_runtime_provenance_claimed", manifest["source_snapshot"]["runtime_provenance_claimed"].as_bool
      json.field "cell_count", results.size
      json.field "failed_cell_count", failed_cells
      json.field "cells" do
        json.array { results.each { |cell| w263_root_matrix_write_result(json, cell) } }
      end
    end
  end
  puts report
  exit(failed_cells == 0 ? 0 : 1)
rescue ex
  report = JSON.build do |json|
    json.object do
      json.field "format", "compact_static_json_root_matrix_w263_diagnostic_v1"
      json.field "fatal_error_class", ex.class.name
      json.field "fatal_error", ex.message || ""
    end
  end
  puts report
  exit 2
end
