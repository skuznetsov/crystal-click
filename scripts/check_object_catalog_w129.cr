# W129 stock/Object-column/catalog interoperability oracle.
#
# Four fresh native INSERT parts exercise both global String profiles and both
# Dynamic discriminator layouts. Four fresh library-written parts take the
# reverse route through stock ATTACH/CHECK/full SQL. Every quiescent part is
# then read by ObjectColumnReader and copied into a synthetic Atomic catalog
# whose DDL is built from the observed stock column declaration.
require "file_utils"
require "json"
require "../src/crystal_click"
require "./w115_json_semantic_vectors"
require "./w122_bulk_vectors"

W129_VERSION           = "26.10.1.1201"
W129_BUILD_HASH        = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
W129_EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
W129_FRAME_BYTES       = 16
W129_DECLARATION       = "JSON(max_dynamic_types=1, max_dynamic_paths=1, a UInt64, t String)"
W129_SETTINGS_BASE     = "index_granularity=2, index_granularity_bytes=10485760, enable_mixed_granularity_parts=1, min_rows_for_wide_part=0, min_bytes_for_wide_part=0, compress_marks=0, compress_primary_key=0, min_compress_block_size=0, max_compress_block_size=4096, default_compression_codec='LZ4', object_serialization_version='v3', object_shared_data_serialization_version_for_zero_level_parts='map', propagate_types_serialization_versions_to_nested_types=true"
W129_JSON_ROWS         = [
  %({"pk":1,"payload":{"a":101,"t":"","d":11,"spill":"one"}}),
  %({"pk":2,"payload":{"a":0,"t":"a\\u0000b","d":22}}),
  %({"pk":3,"payload":{"a":303,"t":"λ雪","d":33,"spill":303}}),
  %({"pk":4,"payload":{"a":404,"t":"é","d":44}}),
  %({"pk":5,"payload":{"a":505,"t":"x","d":55,"spill":true}}),
  %({"pk":6,"payload":{"a":606,"t":"nul","d":66}}),
  %({"pk":7,"payload":{"a":707,"t":"終","d":77,"spill":"\\u0000"}}),
]
W129_KEYS          = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64]
W129_ROWS_PER_MARK = [2_u64, 2_u64, 2_u64, 1_u64]
W129_PROFILES      = [
  {"single_stream", CrystalClick::BinaryBulkProfile.single_stream},
  {"with_size_stream", CrystalClick::BinaryBulkProfile.with_size_stream},
]
W129_MODES = [
  {"basic", CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE},
  {"compact", CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE},
]

class W129Mismatch < Exception
end

def w129_fail(message : String) : NoReturn
  raise W129Mismatch.new(message)
end

def w129_require(condition : Bool, message : String) : Nil
  w129_fail(message) unless condition
end

def w129_run(binary : String, store : String, query : String, input : IO? = nil) : String
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

def w129_run_status(binary : String, arguments : Array(String)) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(binary, arguments, output: output, error: error)
  raise "ClickHouse command failed: #{error}" unless status.success?
  output.to_s
end

def w129_verify_runtime(binary : String, store : String) : Nil
  version = w129_run_status(binary, ["local", "--version"]).strip
  w129_require(version == "ClickHouse local version #{W129_VERSION} (official build).",
    "unexpected ClickHouse version: #{version.inspect}")
  digest = w129_run_status("shasum", ["-a", "256", binary]).split(' ').first? || ""
  w129_require(digest == W129_EXECUTABLE_SHA256, "unexpected ClickHouse executable SHA-256")
  build = w129_run(binary, store,
    "SELECT name || '=' || value FROM system.build_options WHERE name IN ('GIT_HASH', 'VERSION_GITHASH') ORDER BY name FORMAT TSVRaw").lines.map(&.strip)
  w129_require(build == ["GIT_HASH=#{W129_BUILD_HASH}", "VERSION_GITHASH=#{W129_BUILD_HASH}"],
    "unexpected ClickHouse build identity")
end

def w129_store_child(path : String, store : String, label : String) : String
  real_store = File.realpath(store)
  real_path = File.realpath(path)
  unless real_path.starts_with?(real_store + "/") && !File.symlink?(path)
    w129_fail("#{label}: path escapes isolated store or is a symlink")
  end
  relative = real_path[(real_store.size + 1)..]
  cursor = real_store
  relative.split('/').each do |component|
    cursor = File.join(cursor, component)
    w129_fail("#{label}: symlink in store path") if File.symlink?(cursor)
  end
  real_path
end

def w129_assert_tree(path : String, label : String) : Nil
  w129_require(Dir.exists?(path) && !File.symlink?(path), "#{label}: unsafe/missing directory")
  Dir.children(path).each do |name|
    child = File.join(path, name)
    w129_require(!File.symlink?(child), "#{label}: symlink child #{name.inspect}")
    if Dir.exists?(child)
      w129_assert_tree(child, "#{label}/#{name}")
    else
      w129_require(File.file?(child), "#{label}: non-file child #{name.inspect}")
    end
  end
end

def w129_table_name(label : String) : String
  "w129_#{label.gsub('-', "_")}"
end

def w129_table_schema(binary : String, store : String, table : String, label : String) : String
  actual = w129_run(binary, store,
    "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  expected = "pk UInt64\npayload #{W129_DECLARATION}\n"
  w129_require(actual == expected, "#{label}: stock columns differ from the canonical typed Object declaration: #{actual.inspect}")
  payload_line = actual.lines.map(&.chomp).find(&.starts_with?("payload ")) ||
                 w129_fail("#{label}: payload declaration was absent from system.columns")
  actual_declaration = payload_line["payload ".bytesize..]
  parsed = CrystalClick::ObjectDocumentSchema.parse_declaration(actual_declaration)
  w129_require(parsed.declaration == W129_DECLARATION,
    "#{label}: live declaration does not parse to the canonical schema")
  actual_declaration
end

def w129_create_table(binary : String, store : String, table : String, profile_name : String, mode : UInt64, label : String) : String
  compact = mode == CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE ? 1 : 0
  settings = "#{W129_SETTINGS_BASE}, use_compact_variant_discriminators_serialization=#{compact}, string_serialization_version='#{profile_name}'"
  w129_run(binary, store,
    "CREATE TABLE default.#{table} (pk UInt64, payload #{W129_DECLARATION}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings}")
  w129_table_schema(binary, store, table, label)
end

def w129_table_data_path(binary : String, store : String, table : String, label : String) : String
  path = w129_run(binary, store,
    "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  w129_store_child(path, store, "#{label} data path")
end

def w129_part(binary : String, store : String, table : String, label : String) : Tuple(String, String)
  rows = w129_run(binary, store,
    "SELECT name, path, part_type, toString(rows) FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines
  w129_require(rows.size == 1, "#{label}: expected exactly one active part, got #{rows.size}")
  fields = rows.first.split('\t')
  w129_require(fields.size == 4 && fields[2] == "Wide" && fields[3] == "7",
    "#{label}: expected one seven-row Wide part, got #{rows.first.inspect}")
  part_path = w129_store_child(fields[1], store, "#{label} part")
  w129_assert_tree(part_path, "#{label} part")
  w129_require(File.file?(File.join(part_path, "checksums.txt")), "#{label}: part lacks checksums.txt")
  {fields[0], part_path}
end

def w129_expected_documents : Array(CrystalClick::ObjectDocument)
  rows = [] of CrystalClick::ObjectDocument
  rows << w129_document(101_u64, "", 11_i64, CrystalClick::BinaryValue.string("one"))
  rows << w129_document(0_u64, "a\0b", 22_i64)
  rows << w129_document(303_u64, "λ雪", 33_i64, CrystalClick::BinaryValue.int64(303_i64))
  rows << w129_document(404_u64, "é", 44_i64)
  rows << w129_document(505_u64, "x", 55_i64, CrystalClick::BinaryValue.bool(true))
  rows << w129_document(606_u64, "nul", 66_i64)
  rows << w129_document(707_u64, "終", 77_i64, CrystalClick::BinaryValue.string("\0"))
  rows
end

def w129_document(
  a : UInt64,
  t : String,
  d : Int64,
  spill : CrystalClick::BinaryValue? = nil,
) : CrystalClick::ObjectDocument
  # Keep the typed/dynamic fields and the shared-only spill path explicit.
  # `d` occurs in every row and has one nominal type; `spill` occurs in only
  # four rows, so max_dynamic_paths=1 keeps `d` dynamic and routes spill to MAP.
  fields = {} of String => CrystalClick::BinaryValue
  fields["a"] = CrystalClick::BinaryValue.uint64(a)
  fields["t"] = CrystalClick::BinaryValue.string(t)
  fields["d"] = CrystalClick::BinaryValue.int64(d)
  fields["spill"] = spill if spill
  CrystalClick::ObjectDocument.new(fields)
end

def w129_granules(documents : Array(CrystalClick::ObjectDocument)) : Array(Array(CrystalClick::ObjectDocument))
  [documents[0, 2], documents[2, 2], documents[4, 2], documents[6, 1]]
end

def w129_typed_schema : Hash(String, CrystalClick::BinaryDataType)
  {
    "a" => CrystalClick::BinaryDataType.primitive("UInt64"),
    "t" => CrystalClick::BinaryDataType.primitive("String"),
  }
end

def w129_plan : CrystalClick::ObjectDocumentPlan
  int64 = CrystalClick::BinaryDataType.primitive("Int64")
  object = CrystalClick::ObjectStructure.new(["d"] of String)
  dynamics = {"d" => CrystalClick::DynamicStructure.new([int64])} of String => CrystalClick::DynamicStructure
  CrystalClick::ObjectDocumentPlan.new(
    CrystalClick::ObjectDynamicStructureSet.new(object, dynamics),
    w129_typed_schema
  )
end

def w129_assert_documents(
  expected : Array(CrystalClick::ObjectDocument),
  actual : Array(CrystalClick::ObjectDocument),
  label : String,
) : Nil
  w129_require(expected.size == actual.size, "#{label}: document count differs")
  expected.each_with_index do |document, row_index|
    found = actual[row_index]
    paths = document.paths
    w129_require(paths == found.paths, "#{label}: path roster differs at row #{row_index}")
    paths.each do |path|
      w129_require(W122BulkVectors.value_equal?(document.value_for(path), found.value_for(path)),
        "#{label}: nominal value differs at row #{row_index}, path #{path.inspect}")
    end
  end
end

def w129_assert_granules(
  expected : Array(Array(CrystalClick::ObjectDocument)),
  actual : Array(Array(CrystalClick::ObjectDocument)),
  label : String,
) : Nil
  w129_require(expected.size == actual.size, "#{label}: mark count differs")
  expected.each_with_index do |rows, mark_index|
    w129_assert_documents(rows, actual[mark_index], "#{label} mark #{mark_index}")
  end
end

def w129_assert_mark_grid(actual : Array(UInt64), expected : Array(UInt64), label : String) : Nil
  w129_require(actual == expected, "#{label}: mark row-count grid differs: #{actual.inspect}")
end

def w129_assert_check(actual : String, part_name : String, label : String) : Nil
  expected = "#{part_name}\t1\t\n"
  w129_require(actual == expected, "#{label}: CHECK TABLE output mismatch: #{actual.inspect}")
end

def w129_assert_stock_rows(actual : String, first_index : Int32, count : Int32, expected_payloads : Array(String), label : String) : Nil
  lines = actual.lines
  w129_require(lines.size == count, "#{label}: SQL row count differs")
  count.times do |offset|
    expected_index = first_index + offset
    outer = JSON.parse(lines[offset]).as_h
    key = outer["pk"].as_i64.to_u64
    w129_require(key == W129_KEYS[expected_index], "#{label}: primary-key order differs at output row #{offset}")
    expected_payload = JSON.parse(expected_payloads[expected_index])
    actual_payload = JSON.parse(outer["payload"].as_s)
    w129_require(w115_semantic_json_equal?(expected_payload, actual_payload),
      "#{label}: stock payload differs for pk=#{key}: #{actual_payload}")
  end
end

def w129_assert_stock_sql(binary : String, store : String, table : String, part_name : String, label : String) : Nil
  check = w129_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated")
  w129_assert_check(check, part_name, "#{label} CHECK TABLE")

  typed = w129_run(binary, store,
    "SELECT pk, payload.a, concat('x', hex(payload.t)), dynamicType(payload.d) FROM default.#{table} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw")
  typed_lines = typed.lines
  documents = w129_expected_documents
  w129_require(typed_lines.size == documents.size, "#{label}: typed SQL row count differs")
  documents.each_with_index do |document, index|
    fields = typed_lines[index].split('\t')
    w129_require(fields.size == 4, "#{label}: malformed typed SQL row #{typed_lines[index].inspect}")
    w129_require(fields[0].to_u64 == W129_KEYS[index], "#{label}: typed SQL primary-key order differs")
    w129_require(fields[1].to_u64 == document.value_for("a").as_uint64,
      "#{label}: typed UInt64 SQL projection differs at row #{index}")
    expected_hex = document.value_for("t").as_string.to_slice.hexstring.upcase
    w129_require(fields[2] == "x#{expected_hex}", "#{label}: typed String SQL projection differs at row #{index}")
    w129_require(fields[3] == "Int64", "#{label}: stock dynamicType(payload.d) did not qualify the expected Int64 arm at row #{index}: #{fields[3].inspect}")
  end

  full = w129_run(binary, store,
    "SELECT pk, toJSONString(payload) AS payload FROM default.#{table} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT JSONEachRow")
  w129_assert_stock_rows(full, 0, documents.size, W129_JSON_ROWS.map { |row| JSON.parse(row).as_h["payload"].to_json }, "#{label} full SQL")
  selected = w129_run(binary, store,
    "SELECT pk, toJSONString(payload) AS payload FROM default.#{table} WHERE pk >= 3 AND pk <= 6 ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT JSONEachRow")
  w129_assert_stock_rows(selected, 2, 4, W129_JSON_ROWS.map { |row| JSON.parse(row).as_h["payload"].to_json }, "#{label} pk3..6 SQL")
end

def w129_assert_object_reader(part : String, schema : CrystalClick::ObjectDocumentSchema, label : String) : Nil
  reader = CrystalClick::ObjectColumnReader.open(part, "payload", schema)
  expected = w129_granules(w129_expected_documents)
  grid = reader.mark_row_counts.map(&.to_u64)
  w129_require(reader.row_count.to_u64 == 7_u64, "#{label}: ObjectColumnReader row_count differs")
  w129_assert_mark_grid(grid, W129_ROWS_PER_MARK, "#{label} ObjectColumnReader")
  w129_assert_granules(expected, reader.read_marks(0, grid.size), "#{label} ObjectColumnReader full")
  w129_assert_granules(expected[1, 2], reader.read_marks(1, 2), "#{label} ObjectColumnReader middle marks")
  w129_assert_granules([] of Array(CrystalClick::ObjectDocument), reader.read_marks(grid.size, 0),
    "#{label} ObjectColumnReader terminal zero marks")
end

def w129_catalog_root(root : String, label : String, table_number : Int32, part : String, actual_declaration : String, ddl_declaration : String? = nil) : String
  catalog = File.join(root, "catalog", label)
  w129_require(!File.exists?(catalog) && !File.symlink?(File.dirname(catalog)), "#{label}: catalog fixture path is occupied or unsafe")
  metadata = File.join(catalog, "metadata")
  FileUtils.mkdir_p(metadata)
  FileUtils.mkdir_p(File.join(catalog, "store"))

  database_uuid = "12900000-0000-4000-8000-000000000001"
  table_uuid = "12910000-0000-4000-8000-00000000000#{table_number}"
  File.write(File.join(metadata, "lab.sql"),
    "ATTACH DATABASE _ UUID '#{database_uuid}'\nENGINE = Atomic\n")

  database_dir = File.join(catalog, "store", database_uuid[0, 3], database_uuid)
  FileUtils.mkdir_p(database_dir)
  ddl = ddl_declaration || actual_declaration
  File.write(File.join(database_dir, "events.sql"),
    "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `payload` #{ddl}\n)\nENGINE = MergeTree\nORDER BY pk\n")

  table_dir = File.join(catalog, "store", table_uuid[0, 3], table_uuid)
  FileUtils.mkdir_p(table_dir)
  File.write(File.join(table_dir, "format_version.txt"), "1\n")
  Dir.mkdir(File.join(table_dir, "detached"))
  FileUtils.cp_r(part, File.join(table_dir, "all_1_1_0"))
  w129_assert_tree(File.join(table_dir, "all_1_1_0"), "#{label} copied catalog part")
  w129_require(CrystalClick::ObjectDocumentSchema.parse_declaration(actual_declaration).declaration == W129_DECLARATION,
    "#{label}: catalog fixture source declaration differs from observed stock DDL")
  catalog
end

def w129_catalog_values(catalog_root : String, label : String) : Tuple(CrystalClick::OfflineColumnSelection, Array(CrystalClick::ObjectDocument))
  selection = CrystalClick::OfflineCatalog.open(catalog_root)["lab"]["events"]["payload"]
  union_values = selection.values
  documents = union_values.map(&.as(CrystalClick::ObjectDocument))
  w129_assert_documents(w129_expected_documents, documents, "#{label} OfflineCatalog.values")
  {selection, documents}
end

def w129_assert_owned_catalog_values(selection : CrystalClick::OfflineColumnSelection, values : Array(CrystalClick::ObjectDocument), label : String) : Nil
  # Mutating the caller-owned result and one returned byte snapshot must not
  # alter the retained document or a subsequent materialization.
  owned_bytes = values[1].value_for("t").bytes
  owned_bytes[0] = 'X'.ord.to_u8
  w129_require(values[1].value_for("t").as_string == "a\0b",
    "#{label}: mutating a detached byte snapshot changed the returned ObjectDocument")
  values.clear
  again = selection.values.map(&.as(CrystalClick::ObjectDocument))
  w129_assert_documents(w129_expected_documents, again, "#{label} owned re-materialization")
end

def w129_expect_corrupt_part(label : String, &)
  begin
    yield
  rescue error : CrystalClick::CorruptPartError
    puts "PASS W129 seeded mismatch rejected as CorruptPartError: #{label}"
    return
  end
  w129_fail("#{label}: seeded mismatch did not raise CrystalClick::CorruptPartError")
end

def w129_flip_serialized_string_profile(path : String, expected_profile : CrystalClick::BinaryBulkProfile) : Nil
  source = File.read(path)
  bytes = Bytes.new(source.bytesize) { |index| source.to_slice[index] }
  key = "\"string\""
  key_offset = source.index(key) || w129_fail("serialization.json has no global String profile key")
  cursor = key_offset + key.bytesize
  while cursor < bytes.size && (bytes[cursor] == 9_u8 || bytes[cursor] == 10_u8 || bytes[cursor] == 13_u8 || bytes[cursor] == 32_u8)
    cursor += 1
  end
  w129_require(cursor < bytes.size && bytes[cursor] == ':'.ord.to_u8,
    "serialization.json global String profile key has no value")
  cursor += 1
  while cursor < bytes.size && (bytes[cursor] == 9_u8 || bytes[cursor] == 10_u8 || bytes[cursor] == 13_u8 || bytes[cursor] == 32_u8)
    cursor += 1
  end
  expected_digit = expected_profile == CrystalClick::BinaryBulkProfile.single_stream ? '0'.ord.to_u8 : '1'.ord.to_u8
  wrong_digit = expected_digit == '0'.ord.to_u8 ? '1'.ord.to_u8 : '0'.ord.to_u8
  w129_require(cursor < bytes.size && bytes[cursor] == expected_digit,
    "serialization.json global String profile does not match the selected part profile")
  bytes[cursor] = wrong_digit
  File.write(path, bytes)
  w129_require(File.size(path) == source.bytesize, "profile mutation changed serialization.json size")
end

def w129_seed_mark_grid_mismatch(root : String, label : String, part : String) : String
  parent = File.join(root, "negative", "grid")
  FileUtils.mkdir_p(parent)
  corrupted = File.join(parent, label)
  FileUtils.cp_r(part, corrupted)

  mark_name = CrystalClick::StreamName.hash("payload.t") + ".mrk2"
  mark_path = File.join(corrupted, mark_name)
  bytes = Bytes.new(File.size(mark_path).to_i)
  File.open(mark_path, "rb") { |io| io.read_fully(bytes) }
  record_count = 5 # four real marks plus terminal sentinel
  w129_require(bytes.size == record_count * CrystalClick::CompressedMarkReader::MARK_RECORD_SIZE,
    "#{label}: typed String mark file does not contain the expected five records")
  # Adaptive records are three little-endian UInt64s; the third is rows.
  # Alter a copied real-mark row count without touching the source part.
  row_count_offset = CrystalClick::CompressedMarkReader::MARK_RECORD_SIZE + 16
  bytes[row_count_offset] = bytes[row_count_offset] + 1_u8
  File.open(mark_path, "wb") { |io| io.write(bytes) }
  corrupted
end

def w129_assert_negative_controls(
  root : String,
  label : String,
  part : String,
  actual_declaration : String,
  expected_profile : CrystalClick::BinaryBulkProfile,
  profile_name : String,
  table_number : Int32,
) : Nil
  schema = CrystalClick::ObjectDocumentSchema.parse_declaration(actual_declaration)

  bad_count_parent = File.join(root, "negative", "count")
  FileUtils.mkdir_p(bad_count_parent)
  bad_count_part = File.join(bad_count_parent, label)
  FileUtils.cp_r(part, bad_count_part)
  count_path = File.join(bad_count_part, "count.txt")
  count_text = File.read(count_path)
  count_bytes = Bytes.new(count_text.bytesize) { |index| count_text.to_slice[index] }
  w129_require(count_bytes.size > 0 && count_bytes[0] == '7'.ord.to_u8,
    "#{label}: expected seven-row count metadata for same-size count mismatch")
  count_bytes[0] = '8'.ord.to_u8
  File.write(count_path, count_bytes)
  w129_expect_corrupt_part("part metadata count") do
    reader = CrystalClick::ObjectColumnReader.open(bad_count_part, "payload", schema)
    reader.row_count
  end

  wrong_caps = CrystalClick::ObjectDocumentSchema.parse_declaration(
    "JSON(max_dynamic_types=1, max_dynamic_paths=0, a UInt64, t String)"
  )
  w129_expect_corrupt_part("schema capacity mismatch") do
    CrystalClick::ObjectColumnReader.open(part, "payload", wrong_caps).mark_row_counts
  end

  profile_copy_parent = File.join(root, "negative", "profile")
  FileUtils.mkdir_p(profile_copy_parent)
  profile_copy = File.join(profile_copy_parent, label)
  FileUtils.cp_r(part, profile_copy)
  serialization_path = File.join(profile_copy, "serialization.json")
  w129_flip_serialized_string_profile(serialization_path, expected_profile)
  w129_expect_corrupt_part("global String profile mismatch") do
    CrystalClick::ObjectColumnReader.open(profile_copy, "payload", schema).mark_row_counts
  end

  bad_grid_part = w129_seed_mark_grid_mismatch(root, label, part)
  w129_expect_corrupt_part("physical/outer mark grid mismatch") do
    CrystalClick::ObjectColumnReader.open(bad_grid_part, "payload", schema).mark_row_counts
  end

  wrong_ddl = "JSON(max_dynamic_types=1, max_dynamic_paths=0, a UInt64, t String)"
  bad_catalog = w129_catalog_root(root, "#{label}_bad_ddl", table_number, part, actual_declaration, wrong_ddl)
  w129_expect_corrupt_part("OfflineCatalog DDL capacity mismatch") do
    CrystalClick::OfflineCatalog.open(bad_catalog)["lab"]["events"]["payload"].values
  end
  puts "PASS W129 mismatch controls: count, schema caps, serialized String profile, mutated physical row grid, and catalog DDL"
end

def w129_stock_case(binary : String, root : String, profile_name : String, profile : CrystalClick::BinaryBulkProfile, mode_name : String, mode : UInt64, case_number : Int32, run_negative_controls : Bool) : Nil
  label = "stock_#{profile_name}_#{mode_name}"
  store = File.join(root, "stores", label)
  FileUtils.mkdir_p(store)
  table = w129_table_name(label)
  actual_declaration = w129_create_table(binary, store, table, profile_name, mode, label)
  input = IO::Memory.new(W129_JSON_ROWS.join("\n") + "\n")
  w129_run(binary, store, "INSERT INTO default.#{table} FORMAT JSONEachRow", input)
  part_name, part = w129_part(binary, store, table, label)
  w129_assert_stock_sql(binary, store, table, part_name, label)

  schema = CrystalClick::ObjectDocumentSchema.parse_declaration(actual_declaration)
  w129_assert_object_reader(part, schema, label)
  catalog = w129_catalog_root(root, label, case_number, part, actual_declaration)
  selection, values = w129_catalog_values(catalog, label)
  w129_assert_owned_catalog_values(selection, values, label)
  if run_negative_controls
    w129_assert_negative_controls(root, label, part, actual_declaration, profile, profile_name, case_number + 8)
  end
  puts "PASS W129 native INSERT -> ObjectColumnReader full/middle/zero + OfflineCatalog owned values + stock CHECK/full/PK window: #{label} part=#{part_name}"
end

def w129_library_case(binary : String, root : String, profile_name : String, profile : CrystalClick::BinaryBulkProfile, mode_name : String, mode : UInt64, case_number : Int32) : Nil
  label = "library_#{profile_name}_#{mode_name}"
  store = File.join(root, "stores", label)
  FileUtils.mkdir_p(store)
  table = w129_table_name(label)
  actual_declaration = w129_create_table(binary, store, table, profile_name, mode, label)
  data_path = w129_table_data_path(binary, store, table, label)
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  detached = w129_store_child(detached, store, "#{label} detached directory")
  part_name = "all_1_1_0"
  part = File.join(detached, part_name)
  w129_require(!File.exists?(part) && !File.symlink?(part), "#{label}: detached part path is occupied")

  CrystalClick::WidePartWriter.write_uint64_object_pair(
    part,
    "pk",
    Slice(UInt64).new(W129_KEYS.size) { |index| W129_KEYS[index] },
    "payload",
    CrystalClick::ObjectDocumentSchema.parse_declaration(actual_declaration),
    w129_plan,
    w129_granules(w129_expected_documents),
    rows_per_mark: 2,
    mode: mode,
    profile: profile,
    shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
    frame_bytes: W129_FRAME_BYTES
  )
  part = w129_store_child(part, store, "#{label} library-written part")
  w129_run(binary, store, "ALTER TABLE default.#{table} ATTACH PART '#{part_name}'")
  attached_name, attached_part = w129_part(binary, store, table, label)
  w129_require(attached_name == part_name, "#{label}: ATTACH changed the part identity")
  w129_assert_stock_sql(binary, store, table, attached_name, label)

  schema = CrystalClick::ObjectDocumentSchema.parse_declaration(actual_declaration)
  w129_assert_object_reader(attached_part, schema, label)
  catalog = w129_catalog_root(root, label, case_number + 4, attached_part, actual_declaration)
  selection, values = w129_catalog_values(catalog, label)
  w129_assert_owned_catalog_values(selection, values, label)
  puts "PASS W129 library part -> stock ATTACH/CHECK/full/PK SQL -> ObjectColumnReader + OfflineCatalog: #{label} part=#{attached_name}"
end

def w129_check : Nil
  binary = ENV["CLICKHOUSE_BIN"]? || raise "CLICKHOUSE_BIN is required"
  root = ENV["W129_TMP_ROOT"]? || raise "W129_TMP_ROOT is required"
  w129_require(!File.symlink?(root) && Dir.exists?(root), "W129 temporary root must be an existing non-symlink directory")
  root = File.realpath(root)
  w129_require(root.starts_with?("/private/tmp/crystal-click-object-catalog-w129."), "unsafe W129 temporary root")
  w129_require(W129_JSON_ROWS.size == 7 && W129_KEYS.size == 7, "W129 independent row inventory changed")
  schema = CrystalClick::ObjectDocumentSchema.parse_declaration(W129_DECLARATION)
  w129_require(schema.typed_paths == w129_typed_schema, "W129 canonical schema differs from the typed-path oracle")
  w129_require(schema.declaration == W129_DECLARATION, "W129 schema parser did not return the exact canonical declaration")

  bootstrap_store = File.join(root, "bootstrap")
  FileUtils.mkdir_p(bootstrap_store)
  w129_run(binary, bootstrap_store, "SELECT 1")
  w129_verify_runtime(binary, bootstrap_store)

  case_number = 1
  W129_PROFILES.each do |profile_name, profile|
    W129_MODES.each do |mode_name, mode|
      w129_stock_case(binary, root, profile_name, profile, mode_name, mode, case_number,
        run_negative_controls: case_number == 1)
      case_number += 1
    end
  end

  case_number = 1
  W129_PROFILES.each do |profile_name, profile|
    W129_MODES.each do |mode_name, mode|
      w129_library_case(binary, root, profile_name, profile, mode_name, mode, case_number)
      case_number += 1
    end
  end
  puts "PASS W129 scope: fresh native/library bidirectional normalized Object V3/MAP one-bucket Wide parts, typed UInt64/String, Dynamic and shared spill values, both String profiles and discriminator layouts; no mixed table typed scan or perf claim"
end

w129_check
