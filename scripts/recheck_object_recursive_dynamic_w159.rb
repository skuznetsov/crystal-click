#!/usr/bin/env ruby
# Independent literal stock-side oracle for recursive declared JSON Dynamic.
# Expected values and metadata rosters are literals, not Crystal round-trips.
require "digest"
require "fileutils"
require "json"
require "open3"

VERSION = "26.10.1.1201"
BUILD_HASH = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
SOURCE_ROOT = "/Users/sergey/SrcArchives/clickhouse-2026-10-04-depth1-895d13ea"
SOURCE_REVISION = "895d13ea4ce8abb811b3b1b3d51b23a466a342a9"
ROOT_PREFIX = "/private/tmp/crystal-click-object-recursive-dynamic-w159."
TYPE_DECLARATION = "JSON(arr Array(Dynamic(max_types=1)), declared String, direct Dynamic(max_types=1), lookup Map(String, Dynamic(max_types=1)), pair Tuple(left Dynamic(max_types=1), right Dynamic(max_types=1)))"

# Separately authored literal rows are the value oracle for both writer paths.
ROWS = [
  {"pk" => 1, "arr" => [10], "declared" => "declared-alpha", "direct" => 42, "lookup" => {"key-one" => 200}, "pair" => [100, "right-alpha"], "legacy" => "legacy-alpha"},
  {"pk" => 2, "arr" => [11, 12], "declared" => "declared-beta", "direct" => 43, "lookup" => {"key-two" => "map-spill"}, "pair" => [101, "right-beta"], "legacy" => "legacy-beta"},
  {"pk" => 3, "arr" => [], "declared" => "declared-gamma", "direct" => nil, "lookup" => {}, "pair" => [nil, "right-gamma"], "legacy" => "legacy-gamma"},
  {"pk" => 4, "arr" => ["array-spill"], "declared" => "declared-delta", "direct" => 44, "lookup" => {"key-four" => 204}, "pair" => [103, true], "legacy" => "legacy-delta"},
  {"pk" => 5, "arr" => [15, 16, 17], "declared" => "declared-epsilon", "direct" => 45, "lookup" => {"key-five" => 205}, "pair" => [104, "right-epsilon"], "legacy" => "legacy-epsilon"},
  {"pk" => 6, "arr" => [nil], "declared" => "declared-zeta", "direct" => 46, "lookup" => {"key-six" => nil}, "pair" => [nil, nil], "legacy" => "legacy-zeta"},
].freeze

class LiteralOracleMismatch < StandardError
end

def fail!(message)
  raise "W159 independent stock/literal oracle failed: #{message}"
end

def require_true(condition, message)
  fail!(message) unless condition
end

def input_json_rows
  ROWS.map do |row|
    json = {
      "pk" => row.fetch("pk"),
      "j" => {
        "arr" => row.fetch("arr"),
        "declared" => row.fetch("declared"),
        "direct" => row.fetch("direct"),
        "lookup" => row.fetch("lookup"),
        "pair" => row.fetch("pair"),
        "legacy" => row.fetch("legacy"),
      },
    }
    JSON.generate(json) + "\n"
  end.join.b
end

def expected_projection(rows, mutant: false)
  rows.each_with_index.map do |row, index|
    direct = mutant && index.zero? ? 43 : row.fetch("direct")
    {
      "pk" => row.fetch("pk"),
      "arr" => row.fetch("arr"),
      "declared" => row.fetch("declared"),
      "pair_left" => row.fetch("pair").fetch(0),
      "pair_right" => row.fetch("pair").fetch(1),
      "lookup" => row.fetch("lookup"),
      "direct" => direct,
      "legacy" => row.fetch("legacy"),
    }
  end
end

def parsed_json_each_row(output)
  output.lines.map do |line|
    JSON.parse(line).tap do |row|
      raise LiteralOracleMismatch, "JSONEachRow result is not an object" unless row.is_a?(Hash)
    end
  end
end

def assert_original_literal_values(actual, label)
  expected = expected_projection(ROWS)
  return if actual == expected

  raise LiteralOracleMismatch,
    "#{label}: public JSONEachRow values differ from independent source literals: #{actual.inspect}"
end

def expected_runtime_types
  ROWS.each_with_index.map do |row, index|
    arr_types = row.fetch("arr").map { |value| value.nil? ? "None" : (value.is_a?(String) ? "String" : "Int64") }
    arr_shared = row.fetch("arr").map { |value| value.is_a?(String) ? 1 : 0 }
    left = row.fetch("pair").fetch(0)
    right = row.fetch("pair").fetch(1)
    map_values = row.fetch("lookup").values
    map_types = map_values.map { |value| value.nil? ? "None" : (value.is_a?(String) ? "String" : "Int64") }
    map_shared = map_values.map { |value| value.is_a?(String) ? 1 : 0 }
    direct = row.fetch("direct")
    {
      "pk" => row.fetch("pk"),
      "arr_types" => arr_types,
      "arr_shared" => arr_shared,
      "pair_left_type" => left.nil? ? "None" : "Int64",
      "pair_left_shared" => 0,
      "pair_right_type" => if right.nil? then "None" elsif right == true || right == false then "Bool" else "String" end,
      "pair_right_shared" => right == true || right == false ? 1 : 0,
      "map_types" => map_types,
      "map_shared" => map_shared,
      "direct_type" => direct.nil? ? "None" : "Int64",
      "direct_shared" => 0,
      "legacy_type" => "String",
      "declared_type" => "String",
    }
  end
end

class StockQueries
  def initialize(binary, root)
    @binary = binary
    @root = root
    @query_dir = File.join(root, "results", "ruby-oracle")
    require_true(!File.exist?(@query_dir) && !File.symlink?(@query_dir),
      "Ruby evidence directory already exists")
    FileUtils.mkdir_p(@query_dir, mode: 0o700)
    @sequence = 0
  end

  def call(label, store, sql)
    @sequence += 1
    base = File.join(@query_dir,
      format("%03d-%s", @sequence, label.gsub(/[^A-Za-z0-9_.-]/, "_")))
    path = base + ".sql"
    require_true(!File.exist?(path) && !File.symlink?(path),
      "refusing evidence overwrite at #{path}")
    File.binwrite(path, sql + ";\n")
    args = [
      @binary, "local", "--path", store, "--session_timezone=UTC", "--enable_json_type=1",
      "--allow_experimental_dynamic_type=1", "--print_pretty_type_names=0",
      "--output_format_json_quote_64bit_integers=0", "--max_threads=1",
      "--max_memory_usage=536870912", "--query", sql,
    ]
    stdout, stderr, status = Open3.capture3({"TZ" => "UTC"}, *args)
    File.binwrite(base + ".stdout", stdout.b)
    File.binwrite(base + ".stderr", stderr.b)
    [path, base + ".stdout", base + ".stderr"].each do |evidence_path|
      require_true(File.size(evidence_path) <= 8 * 1024 * 1024,
        "evidence artifact exceeds 8 MiB: #{evidence_path}")
    end
    fail!("stock query failed at #{label}: #{stderr}\nSQL=#{sql}") unless status.success?
    stdout.b
  end
end

def verify_pins(binary, queries, root, source_root)
  require_true(File.file?(binary) && File.executable?(binary) && !File.symlink?(binary),
    "pinned ClickHouse executable is missing, non-executable, or a symlink")
  digest = Digest::SHA256.file(binary).hexdigest
  require_true(digest == EXECUTABLE_SHA256, "runtime SHA-256 differs: #{digest}")
  source = Open3.capture3("git", "-C", source_root, "rev-parse", "HEAD")
  require_true(source[2].success? && source[0].strip == SOURCE_REVISION,
    "pinned ClickHouse source checkout differs: #{source[0].strip.inspect}")

  identity_store = File.join(root, "stores", "identity")
  version = queries.call("version", identity_store, "SELECT version() FORMAT TSVRaw").strip
  require_true(version == VERSION, "runtime version differs: #{version.inspect}")
  build = queries.call("build-identity", identity_store,
    "SELECT concat(name, '=', value) FROM system.build_options " \
    "WHERE name IN ('GIT_HASH','VERSION_GITHASH') ORDER BY name FORMAT TSVRaw")
  expected_build = "GIT_HASH=#{BUILD_HASH}\nVERSION_GITHASH=#{BUILD_HASH}\n"
  require_true(build == expected_build, "runtime build identity differs: #{build.inspect}")
  File.write(File.join(root, "results", "ruby-oracle", "pins.txt"), [
    "runtime_version=#{version}", "runtime_sha256=#{digest}",
    "runtime_build_hash=#{BUILD_HASH}", "source_reference=#{source_root}@#{source[0].strip}",
    "source_is_not_asserted_to_build_runtime=true",
  ].join("\n") + "\n")
end

def check_part(store, label, queries)
  parts = queries.call("#{label}-part", store,
    "SELECT name, toString(rows), toString(marks), part_type FROM system.parts " \
    "WHERE database='default' AND table='p' AND active ORDER BY name FORMAT TSVRaw")
  require_true(parts == "all_1_1_0\t6\t4\tWide\n",
    "#{label}: expected one six-row Wide part with 3 real marks + terminal mark; got #{parts.inspect}")
  check = queries.call("#{label}-check", store, "CHECK TABLE default.p FORMAT TabSeparated")
  require_true(check == "all_1_1_0\t1\t\n", "#{label}: stock CHECK TABLE differs: #{check.inspect}")

  columns = queries.call("#{label}-system-columns", store,
    "SELECT name, type, position FROM system.columns WHERE database='default' AND table='p' " \
    "ORDER BY position FORMAT TSVRaw")
  expected_columns = "pk\tUInt64\t1\nj\t#{TYPE_DECLARATION}\t2\n"
  require_true(columns == expected_columns, "#{label}: declared JSON schema differs: #{columns.inspect}")

  nominal_types = queries.call("#{label}-nominal-types", store,
    "SELECT toTypeName(j.arr), toTypeName(j.declared), toTypeName(j.direct), toTypeName(j.lookup), toTypeName(j.pair) " \
    "FROM default.p ORDER BY pk LIMIT 1 FORMAT TSVRaw")
  expected_nominal = [
    "Array(Dynamic(max_types=1))", "String", "Dynamic(max_types=1)",
    "Map(String, Dynamic(max_types=1))",
    "Tuple(left Dynamic(max_types=1), right Dynamic(max_types=1))",
  ].join("\t") + "\n"
  require_true(nominal_types == expected_nominal,
    "#{label}: exact nominal recursive declared types differ: #{nominal_types.inspect}")

  runtime_types = queries.call("#{label}-runtime-types", store,
    "SELECT pk, arrayMap(x -> dynamicType(x), j.arr) AS arr_types, " \
    "arrayMap(x -> toUInt8(isDynamicElementInSharedData(x)), j.arr) AS arr_shared, " \
    "dynamicType(tupleElement(j.pair, 1)) AS pair_left_type, " \
    "toUInt8(isDynamicElementInSharedData(tupleElement(j.pair, 1))) AS pair_left_shared, " \
    "dynamicType(tupleElement(j.pair, 2)) AS pair_right_type, " \
    "toUInt8(isDynamicElementInSharedData(tupleElement(j.pair, 2))) AS pair_right_shared, " \
    "arrayMap(x -> dynamicType(x), mapValues(j.lookup)) AS map_types, " \
    "arrayMap(x -> toUInt8(isDynamicElementInSharedData(x)), mapValues(j.lookup)) AS map_shared, " \
    "dynamicType(j.direct) AS direct_type, toUInt8(isDynamicElementInSharedData(j.direct)) AS direct_shared, " \
    "dynamicType(j.legacy) AS legacy_type, toTypeName(j.declared) AS declared_type " \
    "FROM default.p ORDER BY pk FORMAT JSONEachRow")
  actual_types = parsed_json_each_row(runtime_types)
  expected_types = expected_runtime_types
  require_true(actual_types == expected_types,
    "#{label}: exact native Dynamic type/spill observations differ: #{actual_types.inspect}")

  value_sql = "SELECT pk, j.arr AS arr, j.declared AS declared, tupleElement(j.pair, 1) AS pair_left, " \
    "tupleElement(j.pair, 2) AS pair_right, j.lookup AS lookup, j.direct AS direct, j.legacy AS legacy "
  values = parsed_json_each_row(queries.call("#{label}-literal-values", store,
    value_sql + "FROM default.p ORDER BY pk FORMAT JSONEachRow"))
  if label == "library-mutant"
    begin
      assert_original_literal_values(values, label)
    rescue LiteralOracleMismatch => error
      require_true(error.message.include?("source literals"),
        "mutant failed for a reason other than the original literal oracle")
    else
      fail!("valid wrong-value part unexpectedly passed the original literal oracle")
    end
    require_true(values == expected_projection(ROWS, mutant: true),
      "wrong-value control differs from its intended single 42-to-43 mutation")
    puts "PASS W159 stock-CHECK-valid mutant rejected by unchanged original literal oracle"
  else
    assert_original_literal_values(values, label)
  end

  middle = parsed_json_each_row(queries.call("#{label}-middle-literal-values", store,
    value_sql + "FROM default.p WHERE pk IN (3,4) ORDER BY pk FORMAT JSONEachRow"))
  expected_middle = expected_projection(ROWS)[2, 2]
  require_true(middle == expected_middle,
    "#{label}: independent rows 3-4 middle-window values differ: #{middle.inspect}")
  puts "PASS W159 stock CHECK/types/full+middle independent literals: #{label}"
end

def main
  root = ENV.fetch("W159_PAIR_ROOT")
  require_true(root.start_with?(ROOT_PREFIX) && root.bytesize > ROOT_PREFIX.bytesize,
    "W159_PAIR_ROOT must be a direct safe /private/tmp child")
  require_true(Dir.exist?(root) && !File.symlink?(root) && File.realpath(root) == root,
    "W159 evidence root is absent, noncanonical, or a symlink")
  %w[stores results].each do |child|
    path = File.join(root, child)
    require_true(Dir.exist?(path) && !File.symlink?(path), "missing or unsafe #{child} directory")
  end

  binary = ENV.fetch("CLICKHOUSE_BIN")
  queries = StockQueries.new(binary, root)
  source_root = ENV.fetch("W159_SOURCE_ROOT", SOURCE_ROOT)
  verify_pins(binary, queries, root, source_root)
  %w[native library library-mutant].each do |cell|
    store = File.join(root, "stores", cell)
    require_true(Dir.exist?(store) && !File.symlink?(store), "missing or unsafe stock store for #{cell}")
    check_part(store, cell, queries)
  end

  File.write(File.join(root, "results", "ruby-oracle", "summary.txt"), <<~TEXT)
    PASS independent Ruby literal oracle queried three isolated stock stores
    PASS exact declared plain String neighbor, Array(Dynamic), Tuple(two sites), Map(String, Dynamic), and direct Dynamic nominal types
    PASS exact per-row dynamicType and isDynamicElementInSharedData observations, including Tuple-right Bool spill
    PASS stock CHECK TABLE, six full rows, and rows 3-4 middle-window JSONEachRow values
    PASS library-mutant direct Int64 42->43 remains stock-CHECK-valid and fails the unchanged original literal oracle
    source_reference=#{source_root}@#{SOURCE_REVISION}
    runtime=#{VERSION} build=#{BUILD_HASH} sha256=#{EXECUTABLE_SHA256}
    source_is_not_asserted_to_build_runtime=true
  TEXT
  puts "PASS W159 independent Ruby stock/literal recheck"
end

main
