#!/usr/bin/env ruby
# Independent read-only audit of fixed W217 stock cases; expects six library successes as supplementary self-report.
# Usage: ruby audit_projection_specialized_w217.rb DEBUG_ROOT [RELEASE_ROOT]
# This intentionally does not execute Crystal, ClickHouse, or the oracle.

require "digest"
require "json"

REPO_ROOT = "/Users/sergey/Projects/Crystal/crystal-click"
ORACLE_PATH = File.join(REPO_ROOT, "scripts/check_projection_specialized_w217_oracle.cr")
TMP_ROOT = "/private/tmp"
CLICKHOUSE_BIN = "/private/tmp/crystal-click-w216-runtime-recovery.DmL9Kw/clickhouse-stripped"
CLICKHOUSE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
CLICKHOUSE_VERSION = "26.10.1.1201"
CLICKHOUSE_BUILD = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
DATABASE = "w217_specialized_projection"
PARENTS = ["all_1_1_0", "all_2_2_0"].freeze
MAX_ENTRIES = 4_096
MAX_BYTES = 64 * 1024 * 1024
MAX_DEPTH = 32
TIMEOUT_SECONDS = 10
GRACE_SECONDS = 2
MAX_MEMORY = 536_870_912
MASK64 = 0xffff_ffff_ffff_ffff

JSON_U64 = "JSON(max_dynamic_types=0, max_dynamic_paths=0, t UInt64)"
JSON_U8 = "JSON(max_dynamic_types=0, max_dynamic_paths=0, t UInt8)"
ARRAY_JSON_U8 = "Array(#{JSON_U8})"
DYNAMIC_U64 = "Dynamic(max_types=1)"
ARRAY_DYNAMIC_U64 = "Array(#{DYNAMIC_U64})"
RECURSIVE_JSON_U8 = "Tuple(doc #{JSON_U8}, n UInt64)"

def assert!(condition, message)
  raise "AUDIT FAIL: #{message}" unless condition
end

def sha256_bytes(bytes)
  Digest::SHA256.hexdigest(bytes)
end

def sha256_file(path)
  digest = Digest::SHA256.new
  File.open(path, "rb") do |file|
    buffer = +""
    while file.read(64 * 1024, buffer)
      digest.update(buffer)
    end
  end
  digest.hexdigest
end

def plain_file!(path, label)
  assert!(!File.symlink?(path), "#{label} is a symlink: #{path}")
  assert!(File.file?(path), "#{label} is not a regular file: #{path}")
  assert!(File.realpath(path) == File.expand_path(path), "#{label} is not canonical: #{path}")
  path
end

def plain_dir!(path, label)
  assert!(!File.symlink?(path), "#{label} is a symlink: #{path}")
  assert!(File.directory?(path), "#{label} is not a directory: #{path}")
  assert!(File.realpath(path) == File.expand_path(path), "#{label} is not canonical: #{path}")
  path
end

def read_json(path, label)
  plain_file!(path, label)
  JSON.parse(File.binread(path))
rescue JSON::ParserError => error
  raise "AUDIT FAIL: malformed #{label}: #{error.message}"
end

def children_exact!(path, expected, label)
  actual = Dir.children(path).sort
  assert!(actual == expected.sort, "#{label} roster differs: got #{actual.inspect}, expected #{expected.sort.inspect}")
end

def expected_rows
  {
    "whole_json" => {
      "all_1_1_0" => [["101", "7"], ["102", "0"], ["103", "8"], ["104", "9"], ["105", "10"], ["106", "11"]],
      "all_2_2_0" => [["201", "21"], ["202", "22"], ["203", "23"], ["204", "24"], ["205", "25"], ["206", "26"]],
    },
    "array_json" => {
      "all_1_1_0" => [["101", "1", "7"], ["102", "0", "-"], ["103", "2", "8,9"], ["104", "2", "0,1"], ["105", "3", "10,11,12"], ["106", "1", "13"]],
      "all_2_2_0" => [["201", "0", "-"], ["202", "1", "21"], ["203", "2", "22,23"], ["204", "1", "24"], ["205", "0", "-"], ["206", "2", "26,27"]],
    },
    "recursive_json" => {
      "all_1_1_0" => [["101", "1", "10"], ["102", "2", "20"], ["103", "3", "30"], ["104", "4", "40"], ["105", "5", "50"], ["106", "6", "60"]],
      "all_2_2_0" => [["201", "21", "210"], ["202", "22", "220"], ["203", "23", "230"], ["204", "24", "240"], ["205", "25", "250"], ["206", "26", "260"]],
    },
    "dynamic_root" => {
      "all_1_1_0" => [["101", "UInt64", "7"], ["102", "UInt64", "0"], ["103", "UInt64", "8"], ["104", "UInt64", "9"], ["105", "UInt64", "10"], ["106", "UInt64", "11"]],
      "all_2_2_0" => [["201", "UInt64", "21"], ["202", "UInt64", "22"], ["203", "UInt64", "23"], ["204", "UInt64", "24"], ["205", "UInt64", "25"], ["206", "UInt64", "26"]],
    },
    "dynamic_array" => {
      "all_1_1_0" => [["101", "1", "UInt64", "7"], ["102", "0", "-", "-"], ["103", "2", "UInt64,UInt64", "8,9"], ["104", "2", "UInt64,UInt64", "0,1"], ["105", "3", "UInt64,UInt64,UInt64", "10,11,12"], ["106", "1", "UInt64", "13"]],
      "all_2_2_0" => [["201", "0", "-", "-"], ["202", "1", "UInt64", "21"], ["203", "2", "UInt64,UInt64", "22,23"], ["204", "1", "UInt64", "24"], ["205", "0", "-", "-"], ["206", "2", "UInt64,UInt64", "26,27"]],
    },
    "count" => {
      "all_1_1_0" => [["50", "2"], ["51", "2"], ["52", "2"]],
      "all_2_2_0" => [["100", "2"], ["101", "2"], ["102", "2"]],
    },
  }
end

def specs
  {
    "whole_json" => {
      "table" => "whole_json", "kind" => "object", "selected" => ["pk", "payload"],
      "source" => [["pk", "UInt64"], ["payload", JSON_U64]],
      "child" => [["pk", "UInt64"], ["payload", JSON_U64]], "key" => "pk",
    },
    "array_json" => {
      "table" => "array_json", "kind" => "array_object", "selected" => ["pk", "a"],
      "source" => [["pk", "UInt64"], ["a", ARRAY_JSON_U8]],
      "child" => [["pk", "UInt64"], ["a", ARRAY_JSON_U8]], "key" => "pk",
    },
    "recursive_json" => {
      "table" => "recursive_json", "kind" => "recursive", "selected" => ["pk", "payload"],
      "source" => [["pk", "UInt64"], ["payload", RECURSIVE_JSON_U8]],
      "child" => [["pk", "UInt64"], ["payload", RECURSIVE_JSON_U8]], "key" => "pk",
    },
    "dynamic_root" => {
      "table" => "dynamic_root", "kind" => "dynamic", "selected" => ["pk", "payload"],
      "source" => [["pk", "UInt64"], ["payload", DYNAMIC_U64]],
      "child" => [["pk", "UInt64"], ["payload", DYNAMIC_U64]], "key" => "pk",
    },
    "dynamic_array" => {
      "table" => "dynamic_array", "kind" => "dynamic_array", "selected" => ["pk", "wrapped"],
      "source" => [["pk", "UInt64"], ["wrapped", ARRAY_DYNAMIC_U64]],
      "child" => [["pk", "UInt64"], ["wrapped", ARRAY_DYNAMIC_U64]], "key" => "pk",
    },
    "count" => {
      "table" => "count_parent", "kind" => "count", "selected" => ["intDiv(pk, 2)", "count()"],
      "source" => [["pk", "UInt64"]],
      "child" => [["intDiv(pk, 2)", "UInt64"], ["count()", "AggregateFunction(count)"]],
      "key" => "intDiv(pk, 2)",
    },
  }
end

def tab_rows(text, label)
  text.lines.map do |line|
    fields = line.chomp.sub(/\r\z/, "").split("\t", -1)
    fields if fields[0] == label
  end.compact
end

def grouped_rows(text)
  grouped = Hash.new { |hash, key| hash[key] = [] }
  tab_rows(text, "__W217_ROWS__").each do |fields|
    assert!(fields.length >= 3, "malformed __W217_ROWS__ line: #{fields.inspect}")
    grouped[fields[1]] << fields.drop(2)
  end
  grouped
end

def check_section(text, case_id)
  lines = text.lines
  begin_indices = []
  end_indices = []
  lines.each_with_index do |line, index|
    fields = line.chomp.sub(/\r\z/, "").split("\t", -1)
    begin_indices << index if fields[0] == "__W217_CHECK_BEGIN__" && fields[1] == case_id
    end_indices << index if fields[0] == "__W217_CHECK_END__" && fields[1] == case_id
  end
  assert!(begin_indices.length == 1 && end_indices.length == 1 && begin_indices[0] < end_indices[0],
          "#{case_id} lacks one well-formed CHECK TABLE bracket")
  lines[(begin_indices[0] + 1)...end_indices[0]].map do |line|
    next if line.strip.empty?
    line.chomp.sub(/\r\z/, "").split("\t", -1)
  end.compact
end

def rotl64(value, bits)
  ((value << bits) | (value >> (64 - bits))) & MASK64
end

def sip_round(state)
  v0, v1, v2, v3 = state
  a = (v0 + v1) & MASK64
  b = rotl64(v1, 13) ^ a
  a = rotl64(a, 32)
  c = (v2 + v3) & MASK64
  d = rotl64(v3, 16) ^ c
  a = (a + d) & MASK64
  d = rotl64(d, 21) ^ a
  c = (c + b) & MASK64
  b = rotl64(b, 17) ^ c
  c = rotl64(c, 32)
  [a, b, c, d]
end

def stream_name_hash(name)
  v0 = 0x736f6d6570736575
  v1 = 0x646f72616e646f6d
  v2 = 0x6c7967656e657261
  v3 = 0x7465646279746573
  bytes = name.b
  index = 0
  while index + 8 <= bytes.bytesize
    word = bytes.byteslice(index, 8).unpack1("Q<")
    v3 ^= word
    2.times { v0, v1, v2, v3 = sip_round([v0, v1, v2, v3]) }
    v0 ^= word
    index += 8
  end
  word = (bytes.bytesize << 56) & MASK64
  remaining = bytes.bytesize - index
  remaining.times do |offset|
    word |= bytes.getbyte(index + offset) << (offset * 8)
  end
  v3 ^= word
  2.times { v0, v1, v2, v3 = sip_round([v0, v1, v2, v3]) }
  v0 ^= word
  v2 ^= 0xff
  4.times { v0, v1, v2, v3 = sip_round([v0, v1, v2, v3]) }
  format("%016x%016x", (v2 ^ v3) & MASK64, (v0 ^ v1) & MASK64)
end

def marks_grid!(part_path, stream_name, expected, label)
  mark_path = File.join(part_path, "#{stream_name_hash(stream_name)}.mrk2")
  plain_file!(mark_path, "#{label} primary-key mark file")
  bytes = File.binread(mark_path)
  assert!(bytes.bytesize.positive? && (bytes.bytesize % 24).zero?,
          "#{label} mark file size is not a whole number of plain 24-byte .mrk2 records")
  records = bytes.bytesize / 24
  assert!(records == expected.length + 1, "#{label} .mrk2 record count is #{records}, expected data marks plus EOF")
  counts = records.times.map { |index| bytes.byteslice(index * 24 + 16, 8).unpack1("Q<") }
  assert!(counts[0...-1] == expected && counts[-1] == 0,
          "#{label} .mrk2 row grid #{counts.inspect} differs from #{expected.inspect} plus EOF")
end

def count_child_stream_name!(child_path, label)
  substreams_path = File.join(child_path, "columns_substreams.txt")
  plain_file!(substreams_path, "#{label} columns_substreams.txt")
  actual = File.binread(substreams_path)
  expected = "columns substreams version: 1\n" \
             "2 columns:\n" \
             "1 substreams for column `intDiv(pk, 2)`:\n" \
             "\tintDiv%28pk%2C%202%29\n" \
             "1 substreams for column `count()`:\n" \
             "\tcount%28%29\n"
  assert!(actual == expected,
          "#{label} columns_substreams.txt differs from the exact Count child stream profile")
  stream_name = actual.lines[3].chomp.sub(/\A\t/, "")
  assert!(stream_name == "intDiv%28pk%2C%202%29",
          "#{label} Count primary-key substream is not the pinned escaped physical identity")
  stream_name
end

def columns_text(columns)
  body = +"columns format version: 1\n#{columns.length} columns:\n"
  columns.each { |name, type| body << "\x60#{name}\x60 #{type}\n" }
  body
end

def count_file!(path, expected, label)
  plain_file!(path, "#{label} count.txt")
  contents = File.binread(path)
  assert!(contents.match?(/\A[0-9]+\n?\z/) && contents.to_i == expected,
          "#{label} count.txt does not contain exactly row count #{expected}: #{contents.inspect}")
end

def expected_source_paths
  paths = []
  entrypoint = File.join(REPO_ROOT, "src/crystal_click.cr")
  paths << entrypoint if File.file?(entrypoint)
  paths.concat(Dir.glob(File.join(REPO_ROOT, "src/crystal_click/**/*.cr")))
  paths << ORACLE_PATH
  paths.uniq.sort
end

def source_manifest_expected
  paths = expected_source_paths.map do |path|
    plain_file!(path, "source file")
    canonical = File.realpath(path)
    assert!(canonical.start_with?(REPO_ROOT + "/"), "source file escaped repository: #{canonical}")
    {
      "path" => canonical[(REPO_ROOT.length + 1)..],
      "size_bytes" => File.size(canonical),
      "sha256" => sha256_file(canonical),
    }
  end
  {
    "format" => "w217_specialized_projection_source_manifest_v1",
    "repository_root" => REPO_ROOT,
    "files" => paths,
  }
end

def verify_source_manifest!(root)
  pre_path = File.join(root, "source_manifest.pre.json")
  post_path = File.join(root, "source_manifest.post.json")
  plain_file!(pre_path, "source manifest pre")
  plain_file!(post_path, "source manifest post")
  pre_raw = File.binread(pre_path)
  post_raw = File.binread(post_path)
  assert!(pre_raw == post_raw, "source manifest pre/post bytes differ")
  pre = JSON.parse(pre_raw)
  post = JSON.parse(post_raw)
  assert!(pre == post, "parsed source manifests differ")
  expected = source_manifest_expected
  assert!(pre["format"] == expected["format"] && pre["repository_root"] == REPO_ROOT,
          "source manifest identity/root is wrong")
  assert!(pre["files"] == expected["files"],
          "source manifest exact file roster or live source hashes/sizes differ")
  [pre_raw, sha256_bytes(pre_raw), pre]
end

def walk_parent(parent_path, store_path, parent_name)
  files = []
  entry_count = 0
  total_bytes = 0
  walk = lambda do |directory, depth|
    assert!(depth <= MAX_DEPTH, "physical input tree exceeds depth budget at #{directory}")
    Dir.children(directory).sort.each do |name|
      entry_count += 1
      assert!(entry_count <= MAX_ENTRIES, "physical input tree exceeds entry budget")
      path = File.join(directory, name)
      assert!(!File.symlink?(path), "physical input contains symlink: #{path}")
      canonical = File.realpath(path)
      assert!(canonical == File.expand_path(path), "physical path is not canonical: #{path}")
      assert!(canonical.start_with?(parent_path + "/") && canonical.start_with?(store_path + "/"),
              "physical input escaped parent/store: #{canonical}")
      if File.directory?(path)
        walk.call(canonical, depth + 1)
      elsif File.file?(path)
        size = File.size(path)
        total_bytes += size
        assert!(total_bytes <= MAX_BYTES, "physical input exceeds byte budget")
        relative = canonical[(parent_path.length + 1)..]
        files << {
          "parent" => parent_name,
          "relative_path" => relative,
          "canonical_path" => canonical,
          "size_bytes" => size,
          "sha256" => sha256_file(canonical),
        }
      else
        raise "AUDIT FAIL: physical input is not a plain file/directory: #{path}"
      end
    end
  end
  walk.call(parent_path, 0)
  [entry_count, total_bytes, files]
end

def physical_snapshot(case_id, stdout_text, store_path)
  parent_rows = tab_rows(stdout_text, "__W217_PARENT__")
  expected_paths = {}
  parent_rows.each do |fields|
    next unless fields.length == 7
    expected_paths[fields[2]] = File.expand_path(fields[3])
  end
  assert!(expected_paths.keys.sort == PARENTS.sort, "#{case_id} parent path rows are incomplete")
  parent_parts = []
  files = []
  entries_total = 0
  bytes_total = 0
  expected_paths.sort.each do |name, path|
    plain_dir!(path, "#{case_id} parent #{name}")
    assert!(File.basename(path) == name && path.start_with?(store_path + "/"),
            "#{case_id} parent path identity/store containment differs: #{path}")
    entries, bytes, part_files = walk_parent(path, store_path, name)
    entries_total += entries
    bytes_total += bytes
    assert!(entries_total <= MAX_ENTRIES && bytes_total <= MAX_BYTES,
            "#{case_id} aggregate physical input exceeds budget")
    parent_parts << { "name" => name, "canonical_path" => path }
    files.concat(part_files)
  end
  files.sort_by! { |file| [file["parent"], file["relative_path"]] }
  {
    "format" => "w217_stock_projection_physical_inputs_v1",
    "case" => case_id,
    "complete" => true,
    "store" => store_path,
    "max_entries" => MAX_ENTRIES,
    "max_total_bytes" => MAX_BYTES,
    "max_depth" => MAX_DEPTH,
    "entry_count" => entries_total,
    "file_count" => files.length,
    "total_bytes" => bytes_total,
    "parent_parts" => parent_parts,
    "files" => files,
  }
end

def verify_physical_manifests!(root, case_id, stdout_text, store_path)
  result_dir = File.join(root, "results", case_id)
  pre_path = File.join(result_dir, "physical_inputs.pre.json")
  post_path = File.join(result_dir, "physical_inputs.post.json")
  plain_file!(pre_path, "#{case_id} physical pre-manifest")
  plain_file!(post_path, "#{case_id} physical post-manifest")
  pre_raw = File.binread(pre_path)
  post_raw = File.binread(post_path)
  assert!(pre_raw == post_raw, "#{case_id} physical pre/post manifest bytes differ")
  pre = JSON.parse(pre_raw)
  post = JSON.parse(post_raw)
  assert!(pre == post && pre["complete"] == true &&
          pre["format"] == "w217_stock_projection_physical_inputs_v1",
          "#{case_id} physical pre/post manifests are not identical complete snapshots")
  live = physical_snapshot(case_id, stdout_text, store_path)
  assert!(pre == live, "#{case_id} on-disk parent-file roster, paths, sizes, or SHA-256 differ from captured manifests")
  [sha256_bytes(pre_raw), live]
end

def verify_native_sql!(sql, input, process, case_id, store_path, sql_path)
  assert!(sql.end_with?("\n"), "#{case_id} stock SQL lacks final newline")
  assert!(sha256_bytes(sql) == input["sql_sha256"], "#{case_id} stock.sql hash differs from input manifest")
  assert!(sql == input["sql"], "#{case_id} stock.sql bytes differ from the recorded input SQL")
  assert!(sql.scan("SETTINGS optimize_use_projections=0 FORMAT TSVRaw;").length == 2,
          "#{case_id} does not have optimizer-off row and EOF SQL statements")
  assert!(sql.lines.any? { |line| line.include?("'__W217_ROWS__'") && line.include?("optimize_use_projections=0") },
          "#{case_id} actual semantic SQL is not optimizer-off")
  assert!(sql.lines.any? { |line| line.include?("'__W217_EOF__'") && line.include?("optimize_use_projections=0") },
          "#{case_id} actual EOF/count SQL is not optimizer-off")
  assert!(sql.scan(/CHECK TABLE [^\n]+ FORMAT TSV;/).length == 1,
          "#{case_id} SQL lacks exactly one stock CHECK TABLE")
  assert!(sql.include?("SYSTEM STOP MERGES #{DATABASE}.#{input["table"]};"),
          "#{case_id} SQL does not stop merges")
  insert_lines = sql.lines.select { |line| line.start_with?("INSERT INTO ") }
  assert!(insert_lines.length == 2, "#{case_id} does not issue two separate inserts")
  insert_keys = insert_lines.map do |line|
    pattern = case_id == "count" ? /\((\d+)\)/ : /\((\d+),/
    line.scan(pattern).flatten.map(&:to_i)
  end
  expected_insert_keys = case_id == "count" ? [(100..105).to_a, (200..205).to_a] : [(101..106).to_a, (201..206).to_a]
  assert!(insert_keys == expected_insert_keys, "#{case_id} SQL insert rows differ: #{insert_keys.inspect}")
  assert!(process["sql_file"] == sql_path, "#{case_id} process record names a different SQL path")
  expected_argv = [
    CLICKHOUSE_BIN, "local", "--path", store_path, "--multiquery",
    "--max_threads=1", "--max_insert_threads=1",
    "--max_memory_usage=#{MAX_MEMORY}", "--max_query_size=1048576",
    "--query", sql,
  ]
  assert!(process["argv"] == expected_argv, "#{case_id} raw argv differs from pinned command/SQL")
end

def verify_metadata_and_grids!(case_id, spec, stdout_text, store_path)
  schema = tab_rows(stdout_text, "__W217_SCHEMA__").map do |fields|
    assert!(fields.length == 3, "#{case_id} has malformed source schema row")
    [fields[1], fields[2]]
  end
  assert!(schema == spec["source"], "#{case_id} direct-parent source schema differs: #{schema.inspect}")

  parents = tab_rows(stdout_text, "__W217_PARENT__")
  assert!(parents.length == 2, "#{case_id} does not report exactly two parent parts")
  expected_child_grid = case_id == "count" ? [2, 1] : [2, 2, 2]
  parents.each do |fields|
    assert!(fields.length == 7, "#{case_id} malformed system.parts row: #{fields.inspect}")
    _marker, table, name, raw_path, rows, marks, part_type = fields
    assert!(table == spec["table"] && PARENTS.include?(name), "#{case_id} unexpected parent table/name")
    assert!(rows == "6" && marks == "4" && part_type == "Wide",
            "#{case_id}/#{name} direct parent is not 6 rows, 3 data marks + EOF, Wide")
    parent_path = File.expand_path(raw_path)
    assert!(parent_path.start_with?(store_path + "/") && File.basename(parent_path) == name,
            "#{case_id}/#{name} parent path does not point inside isolated store")
    plain_dir!(parent_path, "#{case_id}/#{name} parent part")
    count_file!(File.join(parent_path, "count.txt"), 6, "#{case_id}/#{name} parent")
    parent_columns = File.join(parent_path, "columns.txt")
    plain_file!(parent_columns, "#{case_id}/#{name} parent columns.txt")
    assert!(File.binread(parent_columns) == columns_text(spec["source"]),
            "#{case_id}/#{name} direct-parent columns.txt differs from source schema")
    marks_grid!(parent_path, "pk", [2, 2, 2], "#{case_id}/#{name} direct parent")

    child_path = File.join(parent_path, "p.proj")
    plain_dir!(child_path, "#{case_id}/#{name} p.proj")
    child_columns = File.join(child_path, "columns.txt")
    plain_file!(child_columns, "#{case_id}/#{name} p.proj columns.txt")
    assert!(File.binread(child_columns) == columns_text(spec["child"]),
            "#{case_id}/#{name} p.proj child columns.txt differs from hard-coded child profile")
    child_rows = case_id == "count" ? 3 : 6
    count_file!(File.join(child_path, "count.txt"), child_rows, "#{case_id}/#{name} p.proj child")
    child_stream_name = case_id == "count" ? count_child_stream_name!(child_path, "#{case_id}/#{name} p.proj child") : spec["key"]
    marks_grid!(child_path, child_stream_name, expected_child_grid, "#{case_id}/#{name} p.proj child")
  end
end

def verify_stdout!(case_id, stdout_text)
  pins = tab_rows(stdout_text, "__W217_PIN__")
  assert!(pins == [["__W217_PIN__", CLICKHOUSE_VERSION, CLICKHOUSE_BUILD]],
          "#{case_id} raw native runtime pin differs: #{pins.inspect}")
  checks = check_section(stdout_text, case_id)
  assert!(checks.length == 2 && checks.all? { |row| row.length >= 2 && row[1] == "1" } &&
          checks.map(&:first).sort == PARENTS.sort,
          "#{case_id} CHECK TABLE did not return exactly two parent rows with result=1: #{checks.inspect}")
  actual_rows = grouped_rows(stdout_text)
  assert!(actual_rows == expected_rows.fetch(case_id),
          "#{case_id} raw stock semantic rows differ from independent literal expectations")
  eof = tab_rows(stdout_text, "__W217_EOF__")
  assert!(eof == [["__W217_EOF__", case_id, "12"]],
          "#{case_id} optimizer-off EOF query did not report exactly 12 source rows: #{eof.inspect}")
end

def audit_case!(root, case_id, source_sha)
  case_dir = File.join(root, "cases", case_id)
  result_dir = File.join(root, "results", case_id)
  store_path = File.join(root, "stores", case_id)
  plain_dir!(case_dir, "#{case_id} case directory")
  plain_dir!(result_dir, "#{case_id} result directory")
  plain_dir!(store_path, "#{case_id} isolated store")
  children_exact!(case_dir, ["input_manifest.json", "stock.sql"], "#{case_id} case files")
  children_exact!(result_dir, [
    "#{case_id}.stdout", "#{case_id}.stderr", "#{case_id}.process.json",
    "physical_inputs.pre.json", "physical_inputs.post.json",
  ], "#{case_id} result files")

  input_path = File.join(case_dir, "input_manifest.json")
  sql_path = File.join(case_dir, "stock.sql")
  process_path = File.join(result_dir, "#{case_id}.process.json")
  stdout_path = File.join(result_dir, "#{case_id}.stdout")
  stderr_path = File.join(result_dir, "#{case_id}.stderr")
  input = read_json(input_path, "#{case_id} input manifest")
  process = read_json(process_path, "#{case_id} process record")
  spec = specs.fetch(case_id)

  assert!(input["format"] == "w217_specialized_projection_input_v1" &&
          input["case"] == case_id && input["kind"] == spec["kind"] &&
          input["database"] == DATABASE && input["table"] == spec["table"] &&
          input["projection"] == "p" && input["store"] == store_path,
          "#{case_id} raw input manifest identity/paths differ")
  assert!(input["selected_projection_columns"] == spec["selected"],
          "#{case_id} selected child columns differ from literal expectation")
  assert!(input["source_types"].map { |col| [col["name"], col["type"]] } == spec["source"] &&
          input["expected_child_types"].map { |col| [col["name"], col["type"]] } == spec["child"],
          "#{case_id} input schema metadata differs from literal source/child profiles")
  assert!(input["source_manifest_sha256"] == source_sha &&
          input["oracle_script"] == ORACLE_PATH &&
          input["oracle_script_sha256"] == sha256_file(ORACLE_PATH),
          "#{case_id} input source/oracle hashes differ from captured/live bytes")
  assert!(input["parent_parts"] == PARENTS && input["timeout_seconds"] == TIMEOUT_SECONDS &&
          input["termination_grace_seconds"] == GRACE_SECONDS &&
          input["max_threads"] == 1 && input["max_insert_threads"] == 1 &&
          input["max_memory_usage_bytes"] == MAX_MEMORY &&
          input["stop_merges"] == true && input["separate_six_row_inserts"] == true,
          "#{case_id} input runtime/shape pins differ")
  assert!(input["clickhouse_binary"] == CLICKHOUSE_BIN &&
          input["clickhouse_binary_sha256"] == CLICKHOUSE_SHA256 &&
          input["expected_clickhouse_version"] == CLICKHOUSE_VERSION &&
          input["expected_clickhouse_build"] == CLICKHOUSE_BUILD,
          "#{case_id} input binary/version/build pins differ")

  sql = File.binread(plain_file!(sql_path, "#{case_id} raw stock SQL"))
  verify_native_sql!(sql, input, process, case_id, store_path, sql_path)

  argv_files = {
    "stdout" => [stdout_path, process["stdout_file"], process["stdout_sha256"]],
    "stderr" => [stderr_path, process["stderr_file"], process["stderr_sha256"]],
  }
  argv_files.each do |label, (path, recorded_path, recorded_sha)|
    plain_file!(path, "#{case_id} raw #{label}")
    assert!(recorded_path == path, "#{case_id} process record #{label} path differs")
    assert!(File.size(path) <= 16 * 1024 * 1024, "#{case_id} #{label} exceeds oracle output bound")
    assert!(recorded_sha == sha256_file(path), "#{case_id} process-record #{label} hash differs from raw file")
  end
  assert!(process["case"] == case_id && process["timed_out"] == false &&
          process["process_error"].nil? && process["success"] == true &&
          process["exit_code"] == 0 && process["exit_signal"].nil? &&
          process["timeout_seconds"] == TIMEOUT_SECONDS &&
          process["termination_grace_seconds"] == GRACE_SECONDS,
          "#{case_id} raw native process status is not a clean bounded exit")
  stdout_bytes = File.binread(stdout_path)
  stdout_text = stdout_bytes.dup.force_encoding("UTF-8")
  assert!(stdout_text.valid_encoding?, "#{case_id} raw stdout is not valid UTF-8")
  verify_stdout!(case_id, stdout_text)
  verify_metadata_and_grids!(case_id, spec, stdout_text, store_path)
  physical_sha, = verify_physical_manifests!(root, case_id, stdout_text, store_path)
  child_rows = case_id == "count" ? 3 : 6
  child_grid = case_id == "count" ? [2, 1] : [2, 2, 2]
  {
    "sql_sha256" => sha256_bytes(sql),
    "stdout_sha256" => sha256_bytes(stdout_bytes),
    "stderr_sha256" => sha256_file(stderr_path),
    "process_sha256" => sha256_file(process_path),
    "physical_manifest_sha256" => physical_sha,
    "process_exit_code" => process["exit_code"],
    "timed_out" => process["timed_out"],
    "parent_rows_per_part" => 6,
    "parent_mark_grid" => [2, 2, 2],
    "child_rows_per_part" => child_rows,
    "child_mark_grid" => child_grid,
  }
end

def audit_root!(root_argument, mode, other_source_sha = nil)
  root = File.expand_path(root_argument)
  plain_dir!(root, "#{mode} evidence root")
  assert!(File.dirname(root) == TMP_ROOT, "#{mode} evidence root is not a direct /private/tmp child")
  children_exact!(root, [
    "cases", "results", "stores",
    "source_manifest.pre.json", "source_manifest.post.json", "result.json",
  ], "#{mode} root")
  cases_root = File.join(root, "cases")
  results_root = File.join(root, "results")
  stores_root = File.join(root, "stores")
  plain_dir!(cases_root, "#{mode} cases")
  plain_dir!(results_root, "#{mode} results")
  plain_dir!(stores_root, "#{mode} stores")
  case_ids = specs.keys
  children_exact!(cases_root, case_ids, "#{mode} cases")
  children_exact!(results_root, case_ids, "#{mode} results")
  children_exact!(stores_root, case_ids, "#{mode} stores")

  source_raw, source_sha, source = verify_source_manifest!(root)
  assert!(source_sha == other_source_sha, "#{mode} source manifest differs from other mode") if other_source_sha
  statuses = {}
  case_ids.each { |case_id| statuses[case_id] = audit_case!(root, case_id, source_sha) }

  # result.json is a self-report only; its success booleans never substitute
  # for the independently checked stock SQL/process/store evidence above.
  result = read_json(File.join(root, "result.json"), "#{mode} supplementary result.json")
  assert!(result["format"] == "w217_specialized_projection_result_v1" &&
          result["cases"].is_a?(Array) &&
          result["cases"].map { |entry| entry["case"] } == case_ids,
          "#{mode} supplementary result.json case roster/format differs")
  assert!(result["clickhouse_binary_sha256"] == CLICKHOUSE_SHA256 &&
          result["expected_clickhouse_version"] == CLICKHOUSE_VERSION &&
          result["expected_clickhouse_build"] == CLICKHOUSE_BUILD &&
          result["source_manifest_pre_sha256"] == source_sha &&
          result["source_manifest_post_sha256"] == source_sha &&
          result["source_manifest_unchanged"] == true &&
          result["oracle_script_sha256"] == sha256_file(ORACLE_PATH),
          "#{mode} supplementary result.json pins or source hashes differ")
  library_results = result["cases"].to_h { |entry| [entry["case"], entry] }
  expected_reported_successes = case_ids
  reported_successes = library_results.select { |_id, entry| entry["success"] == true }.keys
  assert!(library_results.keys.sort == case_ids.sort &&
          reported_successes.sort == expected_reported_successes.sort,
          "#{mode} library self-report is not the expected six-success result")
  case_ids.each do |case_id|
    detail = library_results.fetch(case_id)["detail"]
    child_rows = case_id == "count" ? 3 : 6
    assert!(detail.is_a?(String) &&
            detail.start_with?("stock literal SELECT, low-level child reader, and OfflineTable scan agree;") &&
            detail.include?("child rows/parent=#{child_rows}") &&
            detail.include?("child marks=") &&
            detail.include?("schema="),
            "#{mode} #{case_id} self-reported success lacks child-row/grid/schema details")
  end
  {
    "root" => root,
    "source_sha256" => source_sha,
    "source_revision" => source["source_revision"],
    "statuses" => statuses,
    "library_reported_successes" => reported_successes.sort,
    "library_reported_refusals" => {},
  }
end

begin
  unless (1..2).cover?(ARGV.length)
    raise "usage: ruby audit_projection_specialized_w217.rb DEBUG_EVIDENCE_ROOT [RELEASE_EVIDENCE_ROOT]"
  end
  assert!(File.file?(ORACLE_PATH) && !File.symlink?(ORACLE_PATH), "frozen oracle script is missing or symlinked")
  oracle_sha = sha256_file(ORACLE_PATH)
  assert!(File.file?(CLICKHOUSE_BIN) && !File.symlink?(CLICKHOUSE_BIN) && File.executable?(CLICKHOUSE_BIN),
          "pinned ClickHouse executable is absent, symlinked, or not executable")
  binary_sha = sha256_file(CLICKHOUSE_BIN)
  assert!(binary_sha == CLICKHOUSE_SHA256, "pinned ClickHouse executable hash differs: #{binary_sha}")
  labels = ARGV.length == 1 ? ["DEBUG"] : ["DEBUG", "RELEASE"]
  summaries = []
  ARGV.each_with_index do |path, index|
    other_sha = index.zero? ? nil : summaries.first["source_sha256"]
    summaries << audit_root!(path, labels[index], other_sha)
  end
  if summaries.length == 2
    assert!(summaries[0]["source_sha256"] == summaries[1]["source_sha256"],
            "DEBUG/RELEASE source manifests differ")
    assert!(summaries[0]["source_revision"] == summaries[1]["source_revision"],
            "DEBUG/RELEASE source_revision labels differ")
  end
  summaries.each do |summary|
    puts "#{summary["root"]}: raw native six-case evidence PASS; source_manifest=#{summary["source_sha256"]}"
    puts "  stock axes: parent=6 rows/[2,2,2] per part; " \
         "child=6 rows/[2,2,2] except Count=3 rows/[2,1] per part"
    puts "  library self-report (supplementary): #{summary["library_reported_successes"].length}/6 reported success; refusals=none"
    summary["statuses"].each do |case_id, files|
      puts "  #{case_id}: parent=#{files["parent_rows_per_part"]}/#{files["parent_mark_grid"].inspect}, " \
           "child=#{files["child_rows_per_part"]}/#{files["child_mark_grid"].inspect}; " \
           "exit=#{files["process_exit_code"]} timeout=#{files["timed_out"]} " \
           "sql=#{files["sql_sha256"]} stdout=#{files["stdout_sha256"]} stderr=#{files["stderr_sha256"]} " \
           "process=#{files["process_sha256"]} physical=#{files["physical_manifest_sha256"]}"
    end
  end
  puts "Library self-report is 6/6 success (supplementary only); this audit does not independently establish " \
       "library admission. Synthetic axis-divergence tests remain a separate scope."
  puts "Native runtime pin: #{CLICKHOUSE_VERSION} (#{CLICKHOUSE_BUILD}), SHA-256=#{binary_sha}"
  puts "Oracle SHA-256=#{oracle_sha}; result.json statuses were checked as supplementary diagnostics, not used as raw proof."
rescue StandardError => error
  warn error.message
  exit 1
end
