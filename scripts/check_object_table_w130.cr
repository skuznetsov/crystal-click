# W130 pinned native/library Object table oracle.
#
# The native route has two UInt64-keyed Object roots across two three-row
# physical parts. It checks whole candidate granules separately from the
# exact SQL residual. The library route attaches one normalized Object part;
# W128 intentionally has no multi-Object-column writer.
require "file_utils"
require "json"
require "../src/crystal_click"
require "./w115_json_semantic_vectors"
require "./w122_bulk_vectors"

W130_VERSION           = "26.10.1.1201"
W130_BUILD_HASH        = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
W130_EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
W130_FRAME_BYTES       = 16
W130_PAYLOAD_DECL      = "JSON(max_dynamic_types=1, max_dynamic_paths=1, a UInt64, t String)"
W130_META_DECL         = "JSON(max_dynamic_types=1, max_dynamic_paths=1, flag UInt64, label String)"
# The admitted W129 profile requires Default serializers. In particular, an
# all-zero partition lane must not silently select Sparse in the native case.
W130_SETTINGS_BASE    = "index_granularity=2, index_granularity_bytes=10485760, enable_mixed_granularity_parts=1, min_rows_for_wide_part=0, min_bytes_for_wide_part=0, compress_marks=0, compress_primary_key=0, min_compress_block_size=0, max_compress_block_size=4096, ratio_of_defaults_for_sparse_serialization=1, default_compression_codec='LZ4', object_serialization_version='v3', object_shared_data_serialization_version_for_zero_level_parts='map', propagate_types_serialization_versions_to_nested_types=true"
W130_NATIVE_JSON_ROWS = [
  %({"pk":1,"payload":{"a":101,"t":"","d":11,"spill":"one"},"meta":{"flag":1001,"label":"north"},"bucket":0}),
  %({"pk":2,"payload":{"a":202,"t":"a\\u0000b","d":22},"meta":{"flag":1002,"label":"a\\u0000b"},"bucket":0}),
  %({"pk":3,"payload":{"a":303,"t":"λ雪","d":33,"spill":303},"meta":{"flag":1003,"label":"雪"},"bucket":0}),
  %({"pk":4,"payload":{"a":404,"t":"é","d":44},"meta":{"flag":1004,"label":"é"},"bucket":1}),
  %({"pk":5,"payload":{"a":505,"t":"x","d":55,"spill":true},"meta":{"flag":1005,"label":"x"},"bucket":1}),
  %({"pk":6,"payload":{"a":606,"t":"終","d":66},"meta":{"flag":1006,"label":"終"},"bucket":1}),
]
W130_KEYS           = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
W130_EXPECTED_GRIDS = [[2_u64, 1_u64], [2_u64, 1_u64]]
W130_PROFILES       = ["single_stream", "with_size_stream"]
W130_MODES          = [
  {"basic", CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE},
  {"compact", CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE},
]

class W130Mismatch < Exception
end

alias W130Part = NamedTuple(
  name: String,
  path: String,
  part_type: String,
  rows: UInt64,
  partition: String,
)

alias W130CapturedBatch = NamedTuple(
  part_index: Int32,
  part_name: String,
  part_path: String,
  mark_index: Int32,
  mark_row_offset: UInt64,
  part_row_offset: UInt64,
  source_row_offset: UInt64,
  keys: Array(UInt64),
  payload: Array(CrystalClick::ObjectDocument),
  meta: Array(CrystalClick::ObjectDocument),
)

def w130_fail(message : String) : NoReturn
  raise W130Mismatch.new(message)
end

def w130_require(condition : Bool, message : String) : Nil
  w130_fail(message) unless condition
end

def w130_expect_mismatch(label : String, &)
  begin
    yield
  rescue error : W130Mismatch
    puts "PASS W130 comparator rejected seeded mismatch: #{label}"
    return
  end
  w130_fail("#{label}: seeded mismatch passed the oracle comparator")
end

def w130_run(binary : String, store : String, query : String, input : IO? = nil) : String
  output = IO::Memory.new
  error = IO::Memory.new
  arguments = ["local", "--path", store, "--query", query]
  status = if input
             Process.run(binary, arguments, input: input, output: output, error: error)
           else
             Process.run(binary, arguments, output: output, error: error)
           end
  raise "ClickHouse local query failed: #{error}\n#{query}" unless status.success?
  output.to_s
end

def w130_run_status(binary : String, arguments : Array(String)) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(binary, arguments, output: output, error: error)
  raise "ClickHouse command failed: #{error}" unless status.success?
  output.to_s
end

def w130_verify_runtime(binary : String, store : String) : Nil
  version = w130_run_status(binary, ["local", "--version"]).strip
  w130_require(version == "ClickHouse local version #{W130_VERSION} (official build).",
    "unexpected ClickHouse version: #{version.inspect}")
  digest = w130_run_status("shasum", ["-a", "256", binary]).split(' ').first? || ""
  w130_require(digest == W130_EXECUTABLE_SHA256, "unexpected ClickHouse executable SHA-256")
  build = w130_run(binary, store,
    "SELECT name || '=' || value FROM system.build_options WHERE name IN ('GIT_HASH', 'VERSION_GITHASH') ORDER BY name FORMAT TSVRaw").lines.map(&.strip)
  w130_require(build == ["GIT_HASH=#{W130_BUILD_HASH}", "VERSION_GITHASH=#{W130_BUILD_HASH}"],
    "unexpected ClickHouse build identity")
end

def w130_store_child(path : String, store : String, label : String) : String
  real_store = File.realpath(store)
  real_path = File.realpath(path)
  unless real_path.starts_with?(real_store + "/") && !File.symlink?(path)
    w130_fail("#{label}: path escapes isolated store or is a symlink")
  end
  relative = real_path[(real_store.size + 1)..]
  cursor = real_store
  relative.split('/').each do |component|
    cursor = File.join(cursor, component)
    w130_fail("#{label}: symlink in store path") if File.symlink?(cursor)
  end
  real_path
end

def w130_assert_tree(path : String, label : String) : Nil
  w130_require(Dir.exists?(path) && !File.symlink?(path), "#{label}: unsafe/missing directory")
  Dir.children(path).each do |name|
    child = File.join(path, name)
    w130_require(!File.symlink?(child), "#{label}: symlink child #{name.inspect}")
    if Dir.exists?(child)
      w130_assert_tree(child, "#{label}/#{name}")
    else
      w130_require(File.file?(child), "#{label}: non-file child #{name.inspect}")
    end
  end
end

def w130_table_name(label : String) : String
  "w130_#{label.gsub('-', "_")}"
end

def w130_typed_schema : Hash(String, CrystalClick::BinaryDataType)
  {
    "a" => CrystalClick::BinaryDataType.primitive("UInt64"),
    "t" => CrystalClick::BinaryDataType.primitive("String"),
  }
end

def w130_meta_schema : Hash(String, CrystalClick::BinaryDataType)
  {
    "flag"  => CrystalClick::BinaryDataType.primitive("UInt64"),
    "label" => CrystalClick::BinaryDataType.primitive("String"),
  }
end

def w130_payload_document(
  a : UInt64,
  text : String,
  d : Int64,
  spill : CrystalClick::BinaryValue? = nil,
) : CrystalClick::ObjectDocument
  fields = {} of String => CrystalClick::BinaryValue
  fields["a"] = CrystalClick::BinaryValue.uint64(a)
  fields["t"] = CrystalClick::BinaryValue.string(text)
  fields["d"] = CrystalClick::BinaryValue.int64(d)
  fields["spill"] = spill if spill
  CrystalClick::ObjectDocument.new(fields)
end

def w130_expected_payloads : Array(CrystalClick::ObjectDocument)
  [
    w130_payload_document(101_u64, "", 11_i64, CrystalClick::BinaryValue.string("one")),
    w130_payload_document(202_u64, "a\0b", 22_i64),
    w130_payload_document(303_u64, "λ雪", 33_i64, CrystalClick::BinaryValue.int64(303_i64)),
    w130_payload_document(404_u64, "é", 44_i64),
    w130_payload_document(505_u64, "x", 55_i64, CrystalClick::BinaryValue.bool(true)),
    w130_payload_document(606_u64, "終", 66_i64),
  ]
end

def w130_expected_meta : Array(CrystalClick::ObjectDocument)
  values = [
    {1001_u64, "north"},
    {1002_u64, "a\0b"},
    {1003_u64, "雪"},
    {1004_u64, "é"},
    {1005_u64, "x"},
    {1006_u64, "終"},
  ]
  values.map do |flag, label|
    CrystalClick::ObjectDocument.new({
      "flag"  => CrystalClick::BinaryValue.uint64(flag),
      "label" => CrystalClick::BinaryValue.string(label),
    })
  end
end

def w130_assert_document(expected : CrystalClick::ObjectDocument, actual : CrystalClick::ObjectDocument, label : String) : Nil
  w130_require(expected.paths == actual.paths, "#{label}: Object path roster differs")
  expected.paths.each do |path|
    w130_require(W122BulkVectors.value_equal?(expected.value_for(path), actual.value_for(path)),
      "#{label}: Object value differs at path #{path.inspect}")
  end
end

def w130_assert_documents(expected : Array(CrystalClick::ObjectDocument), actual : Array(CrystalClick::ObjectDocument), label : String) : Nil
  w130_require(expected.size == actual.size, "#{label}: document count differs")
  expected.each_with_index do |document, index|
    w130_assert_document(document, actual[index], "#{label} row #{index}")
  end
end

def w130_assert_grid(actual : Array(Array(UInt64)), expected : Array(Array(UInt64)), label : String) : Nil
  w130_require(actual == expected, "#{label}: physical mark grid differs: #{actual.inspect}")
end

def w130_assert_check(actual : String, part_names : Array(String), label : String) : Nil
  expected = part_names.map { |name| "#{name}\t1\t" }.sort
  lines = actual.lines.map(&.chomp).sort
  w130_require(lines == expected, "#{label}: CHECK TABLE rows differ: #{actual.inspect}")
end

def w130_assert_comparator_sensitivity(actual_check : String, part_names : Array(String)) : Nil
  expected_payloads = w130_expected_payloads
  wrong_payloads = expected_payloads.dup
  wrong_payloads[0] = w130_payload_document(999_u64, "", 11_i64, CrystalClick::BinaryValue.string("one"))
  w130_expect_mismatch("wrong Object document") do
    w130_assert_documents(expected_payloads, wrong_payloads, "seeded wrong document")
  end

  w130_expect_mismatch("wrong physical grid") do
    w130_assert_grid([[2_u64, 1_u64], [2_u64, 2_u64]], W130_EXPECTED_GRIDS, "seeded wrong grid")
  end

  wrong_check = actual_check.gsub("\t1\t", "\t0\t")
  w130_require(wrong_check != actual_check, "CHECK TABLE comparator control did not mutate its positive result")
  w130_expect_mismatch("wrong CHECK TABLE result") do
    w130_assert_check(wrong_check, part_names, "seeded wrong CHECK TABLE")
  end
end

def w130_actual_declarations(binary : String, store : String, table : String, expected_lines : Array(String), label : String) : Hash(String, String)
  actual = w130_run(binary, store,
    "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  w130_require(actual.lines.map(&.chomp) == expected_lines,
    "#{label}: stock columns differ from declarations: #{actual.inspect}")
  declarations = {} of String => String
  actual.lines.each do |line|
    name, type = line.chomp.split(' ', 2)
    declarations[name] = type
  end
  declarations
end

def w130_create_native_table(binary : String, store : String, table : String, profile_name : String, mode : UInt64, label : String) : Hash(String, String)
  compact = mode == CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE ? 1 : 0
  settings = "#{W130_SETTINGS_BASE}, use_compact_variant_discriminators_serialization=#{compact}, string_serialization_version='#{profile_name}'"
  w130_run(binary, store,
    "CREATE TABLE default.#{table} (pk UInt64, payload #{W130_PAYLOAD_DECL}, meta #{W130_META_DECL}, bucket UInt8) ENGINE=MergeTree PARTITION BY bucket ORDER BY pk SETTINGS #{settings}")
  w130_actual_declarations(binary, store, table,
    ["pk UInt64", "payload #{W130_PAYLOAD_DECL}", "meta #{W130_META_DECL}", "bucket UInt8"], label)
end

def w130_create_library_table(binary : String, store : String, table : String, profile_name : String, mode : UInt64, label : String) : Hash(String, String)
  compact = mode == CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE ? 1 : 0
  settings = "#{W130_SETTINGS_BASE}, use_compact_variant_discriminators_serialization=#{compact}, string_serialization_version='#{profile_name}'"
  w130_run(binary, store,
    "CREATE TABLE default.#{table} (pk UInt64, payload #{W130_PAYLOAD_DECL}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings}")
  w130_actual_declarations(binary, store, table,
    ["pk UInt64", "payload #{W130_PAYLOAD_DECL}"], label)
end

def w130_table_data_path(binary : String, store : String, table : String, label : String) : String
  path = w130_run(binary, store,
    "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  w130_store_child(path, store, "#{label} data path")
end

def w130_collect_parts(binary : String, store : String, table : String, expected_count : Int32, expected_rows : UInt64, label : String) : Array(W130Part)
  rows = w130_run(binary, store,
    "SELECT name, path, part_type, toString(rows), toString(partition) FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY partition, name FORMAT TSVRaw").lines
  w130_require(rows.size == expected_count, "#{label}: expected #{expected_count} active parts, got #{rows.size}")
  parts = Array(W130Part).new(rows.size)
  rows.each do |row|
    fields = row.chomp.split('\t')
    w130_require(fields.size == 5 && fields[2] == "Wide" && fields[3].to_u64 == expected_rows,
      "#{label}: expected #{expected_rows}-row Wide part, got #{row.inspect}")
    path = w130_store_child(fields[1], store, "#{label} part")
    w130_assert_tree(path, "#{label} part #{fields[0]}")
    w130_require(File.file?(File.join(path, "checksums.txt")), "#{label}: part lacks checksums.txt")
    parts << {name: fields[0], path: path, part_type: fields[2], rows: fields[3].to_u64, partition: fields[4]}
  end
  parts
end

def w130_create_catalog_root(
  root : String,
  label : String,
  table_number : Int32,
  parts : Array(W130Part),
  declarations : Hash(String, String),
  partitioned : Bool,
) : String
  catalog = File.join(root, "catalog", label)
  w130_require(!File.exists?(catalog) && !File.symlink?(File.dirname(catalog)), "#{label}: catalog path is occupied or unsafe")
  metadata = File.join(catalog, "metadata")
  FileUtils.mkdir_p(metadata)
  FileUtils.mkdir_p(File.join(catalog, "store"))

  database_uuid = "13000000-0000-4000-8000-000000000001"
  table_uuid = "13010000-0000-4000-8000-00000000000#{table_number}"
  File.write(File.join(metadata, "lab.sql"),
    "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")

  database_dir = File.join(catalog, "store", database_uuid[0, 3], database_uuid)
  FileUtils.mkdir_p(database_dir)
  column_lines = declarations.map do |name, type|
    "    `#{name}` #{type}"
  end
  tail = partitioned ? "PARTITION BY bucket\n" : ""
  File.write(File.join(database_dir, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n#{column_lines.join(",\n")}\n)\nENGINE = MergeTree\n#{tail}ORDER BY pk\n")

  table_dir = File.join(catalog, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(table_dir)
  File.write(File.join(table_dir, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_dir, "detached"))
  parts.each do |part|
    destination = File.join(table_dir, part[:name])
    w130_require(!File.exists?(destination) && !File.symlink?(destination), "#{label}: catalog part path is occupied")
    FileUtils.cp_r(part[:path], destination)
    w130_assert_tree(destination, "#{label} copied catalog part")
  end
  catalog
end

def w130_schema(declarations : Hash(String, String), column : String, expected : String, label : String) : CrystalClick::ObjectDocumentSchema
  declaration = declarations[column]? || w130_fail("#{label}: missing stock declaration for #{column}")
  schema = CrystalClick::ObjectDocumentSchema.parse_declaration(declaration)
  w130_require(schema.declaration == expected, "#{label}: canonical Object declaration differs for #{column}")
  schema
end

def w130_verify_indexes(parts : Array(W130Part), payload_schema : CrystalClick::ObjectDocumentSchema, meta_schema : CrystalClick::ObjectDocumentSchema, label : String) : {Array(Array(UInt64)), Array(Array(Int32)), Array(Array(Int32))}
  grids = Array(Array(UInt64)).new(parts.size)
  range_schedule = Array(Array(Int32)).new(parts.size)
  point_schedule = Array(Array(Int32)).new(parts.size)
  expected_primary_keys = [[1_u64, 3_u64, 3_u64], [4_u64, 6_u64, 6_u64]]

  parts.each_with_index do |part, index|
    serializers = JSON.parse(File.read(File.join(part[:path], "serialization.json")))["columns"].as_a
    w130_require(serializers.all? { |entry| entry["kind"].as_s == "Default" },
      "#{label}: stock selected a non-Default serializer outside the admitted Object profile")
    payload = CrystalClick::ObjectColumnReader.open(part[:path], "payload", payload_schema)
    meta = CrystalClick::ObjectColumnReader.open(part[:path], "meta", meta_schema)
    grid = payload.mark_row_counts.map(&.to_u64)
    w130_require(payload.row_count == 3_u64 && meta.row_count == 3_u64, "#{label}: Object root row count differs")
    w130_assert_grid([grid], [W130_EXPECTED_GRIDS[index]], "#{label} part #{index}")
    w130_assert_grid([grid], [meta.mark_row_counts.map(&.to_u64)], "#{label} selected Object roots")
    grids << grid

    checksums = CrystalClick::PartChecksums.open(part[:path])
    primary = CrystalClick::PrimaryKeyIndex.open(part[:path], grid.size, checksums, verify_recorded_hash: true)
    w130_require(primary.keys == expected_primary_keys[index], "#{label}: stock primary.idx keys/sentinel differ for part #{index}: #{primary.keys.inspect}")
    range = primary.candidate_marks(3_u64, 4_u64)
    point = primary.candidate_marks(3_u64, 3_u64)
    expected_range = index == 0 ? [0_i32, 1_i32] : [0_i32]
    expected_point = index == 0 ? [0_i32, 1_i32] : [] of Int32
    w130_require(range == expected_range, "#{label}: actual PK [3,4] index schedule differs for part #{index}: #{range.inspect}")
    w130_require(point == expected_point, "#{label}: actual PK [3,3] index schedule differs for part #{index}: #{point.inspect}")
    range_schedule << range
    point_schedule << point
  end
  {grids, range_schedule, point_schedule}
end

def w130_capture(batch : CrystalClick::WidePartTableBatch, with_meta : Bool) : W130CapturedBatch
  payload = batch.object_documents_for("payload").to_a
  meta = with_meta ? batch.object_documents_for("meta").to_a : [] of CrystalClick::ObjectDocument
  {
    part_index:        batch.part_index,
    part_name:         batch.part_name,
    part_path:         batch.part_path,
    mark_index:        batch.mark_index,
    mark_row_offset:   batch.mark_row_offset,
    part_row_offset:   batch.part_row_offset,
    source_row_offset: batch.source_row_offset,
    keys:              batch.values_for("pk").to_a,
    payload:           payload,
    meta:              meta,
  }
end

def w130_assert_batches(
  actual : Array(W130CapturedBatch),
  part_names : Array(String),
  part_paths : Array(String),
  part_indices : Array(Int32),
  mark_indices : Array(Int32),
  mark_offsets : Array(UInt64),
  part_offsets : Array(UInt64),
  source_offsets : Array(UInt64),
  expected_keys : Array(Array(UInt64)),
  with_meta : Bool,
  label : String,
) : Nil
  count = expected_keys.size
  w130_require(actual.size == count && part_indices.size == count && mark_indices.size == count &&
               mark_offsets.size == count && part_offsets.size == count && source_offsets.size == count,
    "#{label}: callback count differs")
  expected_payloads = w130_expected_payloads
  expected_meta = w130_expected_meta
  count.times do |index|
    batch = actual[index]
    w130_require(batch[:part_index] == part_indices[index], "#{label}: part index differs at callback #{index}")
    w130_require(batch[:part_name] == part_names[part_indices[index]], "#{label}: part name/order differs at callback #{index}")
    w130_require(batch[:part_path] == part_paths[part_indices[index]], "#{label}: part path/provenance differs at callback #{index}")
    w130_require(batch[:mark_index] == mark_indices[index], "#{label}: mark index differs at callback #{index}")
    w130_require(batch[:mark_row_offset] == mark_offsets[index], "#{label}: mark row offset differs at callback #{index}")
    w130_require(batch[:part_row_offset] == part_offsets[index], "#{label}: part row offset differs at callback #{index}")
    w130_require(batch[:source_row_offset] == source_offsets[index], "#{label}: source row offset differs at callback #{index}")
    w130_require(batch[:keys] == expected_keys[index], "#{label}: whole-mark/window key rows differ at callback #{index}: #{batch[:keys].inspect}")
    w130_require(batch[:payload].size == expected_keys[index].size, "#{label}: payload row alignment differs at callback #{index}")
    if with_meta
      w130_require(batch[:meta].size == expected_keys[index].size, "#{label}: meta row alignment differs at callback #{index}")
    else
      w130_require(batch[:meta].empty?, "#{label}: unselected meta column was returned")
    end

    expected_keys[index].each_with_index do |key, row|
      expected_index = key.to_i - 1
      w130_assert_document(expected_payloads[expected_index], batch[:payload][row], "#{label} payload pk=#{key}")
      if with_meta
        w130_assert_document(expected_meta[expected_index], batch[:meta][row], "#{label} meta pk=#{key}")
      end
    end
  end
end

def w130_collect_stock_parts(binary : String, store : String, table : String, count : Int32, rows_per_part : UInt64, label : String) : Array(W130Part)
  w130_collect_parts(binary, store, table, count, rows_per_part, label)
end

def w130_check_output(binary : String, store : String, table : String, parts : Array(W130Part), label : String) : String
  check = w130_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated")
  w130_assert_check(check, parts.map(&.[:name]), "#{label} CHECK TABLE")
  check
end

def w130_assert_sql_rows(actual : String, expected_indices : Array(Int32), with_meta : Bool, label : String) : Nil
  lines = actual.lines
  w130_require(lines.size == expected_indices.size, "#{label}: stock SQL result count differs")
  expected_payloads = w130_expected_payloads
  expected_meta = w130_expected_meta
  expected_indices.each_with_index do |expected_index, output_index|
    outer = JSON.parse(lines[output_index]).as_h
    key = outer["pk"].as_i64.to_u64
    w130_require(key == W130_KEYS[expected_index], "#{label}: stock SQL key/order differs at row #{output_index}")
    payload = JSON.parse(outer["payload"].as_s)
    expected_payload = JSON.parse(W130_NATIVE_JSON_ROWS[expected_index]).as_h["payload"]
    w130_require(w115_semantic_json_equal?(expected_payload, payload), "#{label}: stock payload differs for pk=#{key}")
    if with_meta
      meta = JSON.parse(outer["meta"].as_s)
      expected_meta_json = JSON.parse(W130_NATIVE_JSON_ROWS[expected_index]).as_h["meta"]
      w130_require(w115_semantic_json_equal?(expected_meta_json, meta), "#{label}: stock meta differs for pk=#{key}")
    end
    # Cross-check typed Object values independently from JSON text semantics.
    w130_require(expected_payloads[expected_index].paths.size == 3 + (expected_payloads[expected_index].has_path?("spill") ? 1 : 0),
      "#{label}: independent payload fixture unexpectedly changed")
    if with_meta
      w130_require(expected_meta[expected_index].value_for("flag").as_uint64 == W130_KEYS[expected_index] + 1000_u64,
        "#{label}: independent meta key/value fixture unexpectedly changed")
    end
  end
end

def w130_assert_typed_sql(binary : String, store : String, table : String, with_meta : Bool, row_count : Int32, label : String) : Nil
  select_list = with_meta ? "pk, payload.a, hex(payload.t), dynamicType(payload.d), meta.flag, hex(meta.label)" : "pk, payload.a, hex(payload.t), dynamicType(payload.d)"
  output = w130_run(binary, store,
    "SELECT #{select_list} FROM default.#{table} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw")
  lines = output.lines.map(&.chomp)
  w130_require(lines.size == row_count, "#{label}: typed stock SQL row count differs")
  payloads = w130_expected_payloads
  meta = w130_expected_meta
  payload_strings = ["", "a\0b", "λ雪", "é", "x", "終"]
  meta_strings = ["north", "a\0b", "雪", "é", "x", "終"]
  lines.each_with_index do |line, index|
    fields = line.split('\t')
    expected_fields = with_meta ? 6 : 4
    w130_require(fields.size == expected_fields, "#{label}: malformed typed SQL row #{line.inspect}")
    w130_require(fields[0].to_u64 == W130_KEYS[index], "#{label}: typed SQL PK order differs")
    w130_require(fields[1].to_u64 == payloads[index].value_for("a").as_uint64, "#{label}: payload UInt64 SQL projection differs")
    w130_require(fields[2] == payload_strings[index].to_slice.hexstring.upcase, "#{label}: payload String SQL projection differs")
    w130_require(fields[3] == "Int64", "#{label}: stock Dynamic type arm differs")
    if with_meta
      w130_require(fields[4].to_u64 == meta[index].value_for("flag").as_uint64, "#{label}: meta UInt64 SQL projection differs")
      w130_require(fields[5] == meta_strings[index].to_slice.hexstring.upcase, "#{label}: meta String SQL projection differs")
    end
  end
end

def w130_assert_stock_sql(binary : String, store : String, table : String, parts : Array(W130Part), with_meta : Bool, upper_bound : UInt64, expected_filtered_indices : Array(Int32), row_count : Int32, label : String) : String
  check = w130_check_output(binary, store, table, parts, label)
  json_select = with_meta ? "pk, toJSONString(payload) AS payload, toJSONString(meta) AS meta" : "pk, toJSONString(payload) AS payload"
  full = w130_run(binary, store,
    "SELECT #{json_select} FROM default.#{table} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT JSONEachRow")
  full_indices = Array(Int32).new(row_count) { |index| index }
  w130_assert_sql_rows(full, full_indices, with_meta, "#{label} full stock SQL")
  filtered = w130_run(binary, store,
    "SELECT #{json_select} FROM default.#{table} WHERE pk >= 3 AND pk <= #{upper_bound} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT JSONEachRow")
  w130_assert_sql_rows(filtered, expected_filtered_indices, with_meta, "#{label} inclusive PK 3..#{upper_bound} stock SQL")
  w130_assert_typed_sql(binary, store, table, with_meta, row_count, label)
  check
end

def w130_assert_native_catalog_scans(
  catalog_root : String,
  parts : Array(W130Part),
  native_schedules : {Array(Array(UInt64)), Array(Array(Int32)), Array(Array(Int32))},
  label : String,
) : Nil
  table = CrystalClick::OfflineCatalog.open(catalog_root).table("lab", "events")
  resolved_parts = table.resolved_scan_parts
  resolved_names = resolved_parts.map(&.name)
  resolved_paths = resolved_parts.map(&.path)
  expected_names = parts.map(&.[:name])
  w130_require(resolved_names == expected_names, "#{label}: OfflineTable part order differs from the pinned inventory")
  part_names = resolved_names
  columns = ["pk", "payload", "meta"]

  full = [] of W130CapturedBatch
  table.scan_typed(columns, batch_rows: 2) { |batch| full << w130_capture(batch, true) }
  w130_assert_batches(full, part_names, resolved_paths,
    [0_i32, 0_i32, 1_i32, 1_i32], [0_i32, 1_i32, 0_i32, 1_i32],
    [0_u64, 0_u64, 0_u64, 0_u64], [0_u64, 2_u64, 0_u64, 2_u64],
    [0_u64, 2_u64, 3_u64, 5_u64],
    [[1_u64, 2_u64], [3_u64], [4_u64, 5_u64], [6_u64]], true,
    "#{label} full typed table scan")

  window = [] of W130CapturedBatch
  table.scan_typed_window(columns, 1_u64, max_rows: 3) { |batch| window << w130_capture(batch, true) }
  w130_assert_batches(window, part_names, resolved_paths,
    [0_i32, 0_i32, 1_i32], [0_i32, 1_i32, 0_i32],
    [1_u64, 0_u64, 0_u64], [1_u64, 2_u64, 0_u64], [1_u64, 2_u64, 3_u64],
    [[2_u64], [3_u64], [4_u64]], true,
    "#{label} physical window crossing parts")

  candidate = [] of W130CapturedBatch
  table.scan_uint64_pk_candidates(columns, lower_bound: 3_u64, upper_bound: 4_u64) do |batch|
    candidate << w130_capture(batch, true)
  end
  actual_schedule = Array(Array(Int32)).new(parts.size) { [] of Int32 }
  candidate.each { |batch| actual_schedule[batch[:part_index]] << batch[:mark_index] }
  w130_require(actual_schedule == native_schedules[1], "#{label}: table candidate callback schedule differs from inspected primary indexes")
  w130_assert_batches(candidate, part_names, resolved_paths,
    [0_i32, 0_i32, 1_i32], [0_i32, 1_i32, 0_i32],
    [0_u64, 0_u64, 0_u64], [0_u64, 2_u64, 0_u64], [0_u64, 2_u64, 3_u64],
    [[1_u64, 2_u64], [3_u64], [4_u64, 5_u64]], true,
    "#{label} whole PK candidate granules 3..4")
  candidate_rows = candidate.sum(&.[:keys].size)
  w130_require(candidate_rows == 5, "#{label}: expected five whole candidate rows, got #{candidate_rows}")

  residual_keys = [] of UInt64
  residual_payload = [] of CrystalClick::ObjectDocument
  residual_meta = [] of CrystalClick::ObjectDocument
  candidate.each do |batch|
    batch[:keys].each_with_index do |key, row|
      next if key < 3_u64 || key > 4_u64
      residual_keys << key
      residual_payload << batch[:payload][row]
      residual_meta << batch[:meta][row]
    end
  end
  w130_require(residual_keys == [3_u64, 4_u64], "#{label}: inclusive residual did not reduce candidate rows to pk3,pk4")
  w130_assert_documents([w130_expected_payloads[2], w130_expected_payloads[3]], residual_payload,
    "#{label} exact residual payload")
  w130_assert_documents([w130_expected_meta[2], w130_expected_meta[3]], residual_meta,
    "#{label} exact residual meta")

  point = [] of W130CapturedBatch
  table.scan_uint64_pk_candidates(columns, lower_bound: 3_u64, upper_bound: 3_u64) do |batch|
    point << w130_capture(batch, true)
  end
  point_schedule = Array(Array(Int32)).new(parts.size) { [] of Int32 }
  point.each { |batch| point_schedule[batch[:part_index]] << batch[:mark_index] }
  w130_require(point_schedule == native_schedules[2], "#{label}: point candidate schedule differs from inspected primary indexes")
  point_rows = point.sum(&.[:keys].size)
  w130_require(point_rows == 3, "#{label}: pk=3 should retain its predecessor and terminal short granules")
  point_residual = [] of UInt64
  point.each do |batch|
    batch[:keys].each do |key|
      point_residual << key if key == 3_u64
    end
  end
  w130_require(point_residual == [3_u64], "#{label}: pk=3 residual did not reduce false-positive rows")
end

def w130_assert_reversed_native_direct(parts : Array(W130Part), label : String) : Nil
  reversed_paths = parts.reverse.map(&.[:path])
  reversed_names = parts.reverse.map(&.[:name])
  columns = ["meta", "payload", "pk"]
  table = CrystalClick::WidePartTable.open_selected_typed(reversed_paths, columns)
  w130_require(table.columns == columns, "#{label}: direct table changed caller-selected column order")

  actual = [] of W130CapturedBatch
  table.scan_typed(batch_rows: 2) do |batch|
    w130_require(batch.column_names == columns, "#{label}: callback changed caller-selected column order")
    actual << w130_capture(batch, true)
  end
  w130_assert_batches(actual, reversed_names, reversed_paths,
    [0_i32, 0_i32, 1_i32, 1_i32], [0_i32, 1_i32, 0_i32, 1_i32],
    [0_u64, 0_u64, 0_u64, 0_u64], [0_u64, 2_u64, 0_u64, 2_u64],
    [0_u64, 2_u64, 3_u64, 5_u64],
    [[4_u64, 5_u64], [6_u64], [1_u64, 2_u64], [3_u64]], true,
    "#{label} reversed-path direct typed scan")
end

# Independent selection-scope attack on disposable catalog copies, not on the
# stock source parts. Restore metadata before retaining the example catalog.
def w130_assert_unselected_object_schema(catalog_root : String, label : String) : Nil
  parts = CrystalClick::OfflineCatalog.open(catalog_root).table("lab", "events").resolved_scan_parts
  originals = {} of String => String
  begin
    parts.each do |part|
      path = File.join(part.path, "columns.txt")
      original = File.read(path)
      mutated = original.gsub("flag UInt64", "flag BFloat16")
      w130_require(mutated != original, "#{label}: unrelated-schema control did not mutate metadata")
      originals[path] = original
      File.write(path, mutated)
    end
    reader = CrystalClick::WidePartTable.open_selected_typed(parts.map(&.path), ["payload", "pk"])
    keys = [] of UInt64
    documents = [] of CrystalClick::ObjectDocument
    reader.scan_typed do |batch|
      keys.concat(batch.values_for("pk"))
      documents.concat(batch.object_documents_for("payload"))
      nil
    end
    w130_require(keys == W130_KEYS, "#{label}: unselected Object schema affected selected keys")
    w130_assert_documents(w130_expected_payloads, documents, "#{label} selected Object with unsupported sibling")
    rejected = false
    begin
      CrystalClick::WidePartTable.open_selected_typed(parts.map(&.path), ["meta"])
    rescue error : CrystalClick::UnsupportedFormatError
      rejected = true
    end
    w130_require(rejected, "#{label}: selecting the unsupported sibling Object schema was admitted")
  ensure
    originals.each { |path, original| File.write(path, original) }
  end
end

def w130_native_case(binary : String, root : String, profile_name : String, mode_name : String, mode : UInt64, case_number : Int32, check_comparator_controls : Bool) : Nil
  label = "native_#{profile_name}_#{mode_name}"
  store = File.join(root, "stores", label)
  FileUtils.mkdir_p(store)
  table_name = w130_table_name(label)
  declarations = w130_create_native_table(binary, store, table_name, profile_name, mode, label)
  input = IO::Memory.new(W130_NATIVE_JSON_ROWS.join("\n") + "\n")
  w130_run(binary, store, "INSERT INTO default.#{table_name} FORMAT JSONEachRow", input)
  parts = w130_collect_stock_parts(binary, store, table_name, 2, 3_u64, label)
  w130_require(parts.map(&.[:partition]) == ["0", "1"], "#{label}: expected partition-ordered stock parts 0 then 1")
  w130_require(parts.map(&.[:rows]) == [3_u64, 3_u64], "#{label}: native part row inventory differs")

  payload_schema = w130_schema(declarations, "payload", W130_PAYLOAD_DECL, label)
  meta_schema = w130_schema(declarations, "meta", W130_META_DECL, label)
  inventory = w130_verify_indexes(parts, payload_schema, meta_schema, label)
  w130_assert_reversed_native_direct(parts, label)
  actual_check = w130_assert_stock_sql(binary, store, table_name, parts, true, 4_u64, [2_i32, 3_i32], 6, label)
  w130_assert_comparator_sensitivity(actual_check, parts.map(&.[:name])) if check_comparator_controls

  catalog_root = w130_create_catalog_root(root, label, case_number, parts, declarations, true)
  w130_assert_native_catalog_scans(catalog_root, parts, inventory, label)
  w130_assert_unselected_object_schema(catalog_root, label)
  puts "PASS W130 pinned native two-Object/table scan/window/candidate/residual: #{label} parts=#{parts.map(&.[:name]).join(",")}"
end

def w130_library_plan : CrystalClick::ObjectDocumentPlan
  int64 = CrystalClick::BinaryDataType.primitive("Int64")
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["d"] of String),
      {"d" => CrystalClick::DynamicStructure.new([int64])} of String => CrystalClick::DynamicStructure,
    ),
    w130_typed_schema,
  )
end

def w130_library_case(binary : String, root : String) : Nil
  label = "library_with_size_compact"
  store = File.join(root, "stores", label)
  FileUtils.mkdir_p(store)
  table_name = w130_table_name(label)
  declarations = w130_create_library_table(binary, store, table_name, "with_size_stream",
    CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE, label)
  data_path = w130_table_data_path(binary, store, table_name, label)
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  detached = w130_store_child(detached, store, "#{label} detached directory")
  part_name = "all_1_1_0"
  part_path = File.join(detached, part_name)
  w130_require(!File.exists?(part_path) && !File.symlink?(part_path), "#{label}: detached part path is occupied")
  payloads = w130_expected_payloads[0, 3]
  granules = [payloads[0, 2], payloads[2, 1]]
  CrystalClick::WidePartWriter.write_uint64_object_pair(
    part_path, "pk", Slice[1_u64, 2_u64, 3_u64], "payload",
    CrystalClick::ObjectDocumentSchema.parse_declaration(declarations["payload"]),
    w130_library_plan, granules,
    rows_per_mark: 2, mode: CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE,
    profile: CrystalClick::BinaryBulkProfile.with_size_stream,
    shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
    frame_bytes: W130_FRAME_BYTES,
  )
  part_path = w130_store_child(part_path, store, "#{label} library part")
  w130_run(binary, store, "ALTER TABLE default.#{table_name} ATTACH PART '#{part_name}'")
  parts = w130_collect_stock_parts(binary, store, table_name, 1, 3_u64, label)
  w130_require(parts[0][:name] == part_name, "#{label}: ATTACH changed the library part identity")
  check = w130_assert_stock_sql(binary, store, table_name, parts, false, 3_u64, [2_i32], 3, label)
  w130_assert_comparator_sensitivity(check, parts.map(&.[:name]))

  # Independently pin the attached part's physical grid and primary-index
  # schedule before comparing the catalog candidate callbacks against them.
  payload_schema = w130_schema(declarations, "payload", W130_PAYLOAD_DECL, label)
  grid = CrystalClick::ObjectColumnReader.open(parts[0][:path], "payload", payload_schema).mark_row_counts.map(&.to_u64)
  w130_assert_grid([grid], [[2_u64, 1_u64]], "#{label} library physical grid")
  checksums = CrystalClick::PartChecksums.open(parts[0][:path])
  primary = CrystalClick::PrimaryKeyIndex.open(parts[0][:path], grid.size, checksums, verify_recorded_hash: true)
  w130_require(primary.keys == [1_u64, 3_u64, 3_u64] && primary.candidate_marks(3_u64, 3_u64) == [0_i32, 1_i32],
    "#{label}: library primary index/sentinel schedule differs")

  catalog_root = w130_create_catalog_root(root, label, 9, parts, declarations, false)
  table = CrystalClick::OfflineCatalog.open(catalog_root).table("lab", "events")
  library_parts = table.resolved_scan_parts
  w130_require(library_parts.map(&.name) == [part_name], "#{label}: library catalog part order differs")
  library_paths = library_parts.map(&.path)

  full = [] of W130CapturedBatch
  table.scan_typed(["pk", "payload"], batch_rows: 2) { |batch| full << w130_capture(batch, false) }
  w130_assert_batches(full, [part_name], library_paths, [0_i32, 0_i32], [0_i32, 1_i32],
    [0_u64, 0_u64], [0_u64, 2_u64], [0_u64, 2_u64],
    [[1_u64, 2_u64], [3_u64]], false, "#{label} full typed table scan")

  window = [] of W130CapturedBatch
  table.scan_typed_window(["pk", "payload"], 1_u64, max_rows: 2) do |batch|
    window << w130_capture(batch, false)
  end
  w130_assert_batches(window, [part_name], library_paths, [0_i32, 0_i32], [0_i32, 1_i32],
    [1_u64, 0_u64], [1_u64, 2_u64], [1_u64, 2_u64],
    [[2_u64], [3_u64]], false, "#{label} physical window")

  candidate = [] of W130CapturedBatch
  table.scan_uint64_pk_candidates(["pk", "payload"], lower_bound: 3_u64, upper_bound: 3_u64) do |batch|
    candidate << w130_capture(batch, false)
  end
  candidate_schedule = [] of Int32
  candidate.each { |batch| candidate_schedule << batch[:mark_index] }
  w130_require(candidate_schedule == [0_i32, 1_i32], "#{label}: library primary-key schedule differs")
  candidate_rows = candidate.sum(&.[:keys].size)
  w130_require(candidate_rows == 3, "#{label}: library candidate callbacks were not whole granules")
  residual_keys = [] of UInt64
  residual_payload = [] of CrystalClick::ObjectDocument
  candidate.each do |batch|
    batch[:keys].each_with_index do |key, row|
      next unless key == 3_u64
      residual_keys << key
      residual_payload << batch[:payload][row]
    end
  end
  w130_require(residual_keys == [3_u64], "#{label}: library exact residual differs from stock SQL")
  w130_assert_documents([w130_expected_payloads[2]], residual_payload, "#{label} library PK residual")
  puts "PASS W130 library-written single-Object part -> stock ATTACH/CHECK/SQL/table scan/window/candidates: #{label}"
end

def w130_check : Nil
  binary = ENV["CLICKHOUSE_BIN"]? || raise "CLICKHOUSE_BIN is required"
  root = ENV["W130_TMP_ROOT"]? || raise "W130_TMP_ROOT is required"
  w130_require(!File.symlink?(root) && Dir.exists?(root), "W130 temporary root must be an existing non-symlink directory")
  root = File.realpath(root)
  w130_require(root.starts_with?("/private/tmp/crystal-click-object-table-w130."), "unsafe W130 temporary root")
  w130_require(W130_NATIVE_JSON_ROWS.size == 6 && W130_KEYS.size == 6, "W130 independent row inventory changed")

  payload_schema = CrystalClick::ObjectDocumentSchema.parse_declaration(W130_PAYLOAD_DECL)
  meta_schema = CrystalClick::ObjectDocumentSchema.parse_declaration(W130_META_DECL)
  w130_require(payload_schema.typed_paths == w130_typed_schema, "W130 payload schema differs from the admitted UInt64/String typed paths")
  w130_require(meta_schema.typed_paths == w130_meta_schema, "W130 meta schema differs from the admitted UInt64/String typed paths")
  w130_require(payload_schema.declaration == W130_PAYLOAD_DECL && meta_schema.declaration == W130_META_DECL,
    "W130 canonical Object declarations changed")

  bootstrap_store = File.join(root, "bootstrap")
  FileUtils.mkdir_p(bootstrap_store)
  w130_run(binary, bootstrap_store, "SELECT 1")
  w130_verify_runtime(binary, bootstrap_store)

  case_number = 1
  W130_PROFILES.each do |profile_name|
    W130_MODES.each do |mode_name, mode|
      w130_native_case(binary, root, profile_name, mode_name, mode, case_number,
        check_comparator_controls: case_number == 1)
      case_number += 1
    end
  end

  w130_library_case(binary, root)
  puts "PASS W130 scope: pinned native two-Object parts and one library-written Object part through typed table batches/windows/UInt64-PK candidates with exact residuals; no projection, MV, general writer, or performance claim"
end

w130_check
