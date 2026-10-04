#!/usr/bin/env ruby
# Independent stock-side literal oracle for W158 declared JSON Dynamic paths.
# The expected rows below are source literals, not Crystal output or a
# writer/reader round-trip. Stock SQL supplies the semantic type/spill witness.
require "digest"
require "fileutils"
require "json"
require "open3"

VERSION = "26.10.1.1201"
BUILD_HASH = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
SOURCE_ROOT = "/Users/sergey/SrcArchives/clickhouse-2026-10-04-depth1-895d13ea"
SOURCE_REVISION = "895d13ea4ce8abb811b3b1b3d51b23a466a342a9"
ROOT_PREFIX = "/private/tmp/crystal-click-object-dynamic-w158."
TYPE_DECLARATION = "Dynamic(max_types=1)"
VALUES = [42, [1, 2, 3], 44, 45, [4, 5], 47].freeze
MUTANT_VALUES = [43, [1, 2, 3], 44, 45, [4, 5], 47].freeze
SHARED_FLAGS = [false, true, false, false, true, false].freeze
EXPECTED_DYNAMIC_TYPES = [
  "Int64",
  "Array(Nullable(Int64))",
  "Int64",
  "Int64",
  "Array(Nullable(Int64))",
  "Int64",
].freeze

class LiteralOracleMismatch < StandardError
end

def fail!(message)
  raise "W158 independent stock/literal oracle failed: #{message}"
end

def require_true(condition, message)
  fail!(message) unless condition
end

def json_rows(values)
  values.each_with_index.map do |value, index|
    JSON.generate({"pk" => index + 1, "a" => value}) + "\n"
  end.join.b
end

def expected_types
  VALUES.each_with_index.map do |_value, index|
    type = EXPECTED_DYNAMIC_TYPES.fetch(index)
    flag = SHARED_FLAGS.fetch(index) ? "1" : "0"
    "#{index + 1}\t#{type}\t#{flag}\n"
  end.join
end

def assert_original_literal_values(actual, label)
  expected = json_rows(VALUES)
  return if actual == expected

  raise LiteralOracleMismatch,
    "#{label}: public JSONEachRow values differ from independent source literals: #{actual.inspect}"
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
      @binary, "local", "--path", store, "--session_timezone=UTC",
      "--print_pretty_type_names=0", "--output_format_json_quote_64bit_integers=0",
      "--allow_suspicious_variant_types=1", "--allow_suspicious_low_cardinality_types=1",
      "--max_threads=1", "--max_memory_usage=536870912", "--query", sql,
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
  require_true(check == "all_1_1_0\t1\t\n",
    "#{label}: stock CHECK TABLE differs: #{check.inspect}")

  actual_types = queries.call("#{label}-runtime-types", store,
    "SELECT pk, dynamicType(j.a), toUInt8(isDynamicElementInSharedData(j.a)) " \
    "FROM default.p ORDER BY pk FORMAT TSVRaw")
  require_true(actual_types == expected_types,
    "#{label}: exact stock-observed Dynamic type/spill roster differs: #{actual_types.inspect}")

  nominal = queries.call("#{label}-nominal-type", store,
    "SELECT toTypeName(j.a) FROM default.p ORDER BY pk LIMIT 1 FORMAT TSVRaw")
  require_true(nominal == "#{TYPE_DECLARATION}\n",
    "#{label}: nominal declared typed-path type differs: #{nominal.inspect}")

  values = queries.call("#{label}-literal-values", store,
    "SELECT pk, j.a AS a FROM default.p ORDER BY pk FORMAT JSONEachRow")
  if label == "library-mutant"
    begin
      assert_original_literal_values(values, label)
    rescue LiteralOracleMismatch => error
      require_true(error.message.include?("source literals"),
        "mutant failed for a reason other than the original literal oracle")
    else
      fail!("valid wrong-value part unexpectedly passed the original 42 literal oracle")
    end
    require_true(values == json_rows(MUTANT_VALUES),
      "wrong-value control differs from its intended 42-to-43 single-literal mutation")
    puts "PASS W158 stock-CHECK-valid mutant rejected by the original literal oracle"
  else
    assert_original_literal_values(values, label)
  end

  middle = queries.call("#{label}-middle-literal-values", store,
    "SELECT pk, j.a AS a FROM default.p WHERE pk IN (3,4) ORDER BY pk FORMAT JSONEachRow")
  expected_middle = [2, 3].map do |index|
    JSON.generate({"pk" => index + 1, "a" => VALUES.fetch(index)}) + "\n"
  end.join.b
  require_true(middle == expected_middle,
    "#{label}: independent middle-window literal values differ: #{middle.inspect}")
  puts "PASS W158 stock CHECK/types/full+middle independent literals: #{label}"
end

def main
  root = ENV.fetch("W158_PAIR_ROOT")
  require_true(root.start_with?(ROOT_PREFIX) && root.bytesize > ROOT_PREFIX.bytesize,
    "W158_PAIR_ROOT must be a direct safe /private/tmp child")
  require_true(Dir.exist?(root) && !File.symlink?(root) && File.realpath(root) == root,
    "W158 evidence root is absent, noncanonical, or a symlink")
  %w[stores results].each do |child|
    path = File.join(root, child)
    require_true(Dir.exist?(path) && !File.symlink?(path), "missing or unsafe #{child} directory")
  end

  binary = ENV.fetch("CLICKHOUSE_BIN")
  queries = StockQueries.new(binary, root)
  source_root = ENV.fetch("W158_SOURCE_ROOT", SOURCE_ROOT)
  verify_pins(binary, queries, root, source_root)
  %w[native library library-mutant].each do |cell|
    store = File.join(root, "stores", cell)
    require_true(Dir.exist?(store) && !File.symlink?(store), "missing or unsafe stock store for #{cell}")
    check_part(store, cell, queries)
  end

  File.write(File.join(root, "results", "ruby-oracle", "summary.txt"), <<~TEXT)
    PASS independent Ruby literal oracle queried three isolated stock stores
    PASS exact nominal Dynamic(max_types=1), literal Int64/Array(Nullable(Int64)) dynamicType rows, and shared-arm marker checks
    PASS stock CHECK TABLE, six full rows, and keys 3-4 middle-window JSONEachRow values
    PASS library-mutant Int64 42->43 remains stock-CHECK-valid and is rejected by the original literal oracle
    source_reference=#{source_root}@#{SOURCE_REVISION}
    runtime=#{VERSION} build=#{BUILD_HASH} sha256=#{EXECUTABLE_SHA256}
    source_is_not_asserted_to_build_runtime=true
  TEXT
  puts "PASS W158 independent Ruby stock/literal recheck"
end

main
