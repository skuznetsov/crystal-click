#!/usr/bin/env ruby
# Finite stock-produced Wide Dynamic V3 structure/site qualifier for W154.
# The stock part is only a metadata fixture; this does not qualify library
# Dynamic bulk values, part writing, or physical reader admission.
require "digest"
require "open3"
require "optparse"

VERSION = "26.10.1.1201"
BUILD_HASH = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
SOURCE_ROOT = "/Users/sergey/SrcArchives/clickhouse-2026-10-04-depth1-b94acbe3"
SOURCE_REVISION = "b94acbe318f8459ac88b35647f4e2293d8e225db"
SCRATCH_ROOT_PREFIX = "/private/tmp/crystal-click-w154-"
DEFAULT_BINARY = "/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped"
TABLE = "dynamic_bulk_structure_w154"

class W154Failure < StandardError; end

def w154_fail!(message)
  raise W154Failure, "W154 stock probe: #{message}"
end

def w154_require(condition, message)
  w154_fail!(message) unless condition
end

def w154_write_new_file(path, bytes)
  File.open(path, "wbx", 0o600) { |file| file.write(bytes) }
rescue Errno::EEXIST
  w154_fail!("refusing to overwrite #{path}")
end

def w154_validate_scratch(path)
  w154_require(Dir.exist?(path) && !File.symlink?(path), "caller scratch directory is absent or a symlink")
  scratch = File.realpath(path)
  w154_require(File.expand_path(path) == scratch, "scratch path is not canonical")
  parent = File.dirname(scratch)
  w154_require(File.realpath(parent) == parent, "scratch parent is not canonical")
  w154_require(File.dirname(parent) == "/private/tmp" && File.basename(parent).start_with?(SCRATCH_ROOT_PREFIX.delete_prefix("/private/tmp/")),
    "scratch must be a direct child of a /private/tmp/crystal-click-w154-* root")
  w154_require(File.dirname(scratch) == parent, "scratch must be a direct child of its W154 root")
  w154_require(Dir.children(scratch).empty?, "caller scratch directory must be empty")
  scratch
end

class W154StockQueries
  attr_reader :sequence

  def initialize(binary, root)
    @binary = binary
    @root = root
    @query_dir = File.join(root, "results", "stock")
    @store = File.join(root, "stores", "w154")
    Dir.mkdir(@query_dir, 0o700)
    Dir.mkdir(File.dirname(@store), 0o700)
    Dir.mkdir(@store, 0o700)
    @sequence = 0
  end

  def call(label, sql)
    @sequence += 1
    safe_label = label.gsub(/[^A-Za-z0-9_.-]/, "_")
    base = File.join(@query_dir, format("%03d-%s", @sequence, safe_label))
    w154_write_new_file(base + ".sql", sql + ";\n")
    args = [
      @binary, "local", "--path", @store, "--session_timezone=UTC",
      "--print_pretty_type_names=0", "--max_threads=1",
      "--max_memory_usage=536870912", "--query", sql,
    ]
    stdout, stderr, status = Open3.capture3({"TZ" => "UTC"}, *args)
    w154_write_new_file(base + ".stdout", stdout.b)
    w154_write_new_file(base + ".stderr", stderr.b)
    [base + ".sql", base + ".stdout", base + ".stderr"].each do |path|
      w154_require(File.size(path) <= 16 * 1024 * 1024, "evidence file exceeds 16 MiB: #{path}")
    end
    {success: status.success?, exitstatus: status.exitstatus, stdout: stdout.b, stderr: stderr.b}
  end

  def require_success(result, label)
    w154_require(result[:success], "#{label} failed: #{result[:stderr].inspect}")
  end

  def call_success(label, sql)
    result = call(label, sql)
    require_success(result, label)
    result[:stdout]
  end
end

def w154_validate_driver(path)
  w154_require(File.file?(path) && File.executable?(path) && !File.symlink?(path),
    "compiled Crystal driver is absent, non-executable, or a symlink")
  [File.expand_path(path), Digest::SHA256.file(path).hexdigest]
end

def w154_call_driver(driver, root, label, *arguments)
  directory = File.join(root, "results", "driver")
  safe_label = label.gsub(/[^A-Za-z0-9_.-]/, "_")
  base = File.join(directory, safe_label)
  stdout, stderr, status = Open3.capture3({}, driver, *arguments)
  w154_write_new_file(base + ".stdout", stdout.b)
  w154_write_new_file(base + ".stderr", stderr.b)
  [base + ".stdout", base + ".stderr"].each do |path|
    w154_require(File.size(path) <= 16 * 1024 * 1024, "driver evidence exceeds 16 MiB: #{path}")
  end
  {success: status.success?, exitstatus: status.exitstatus, stdout: stdout.b, stderr: stderr.b}
end

def w154_check_source_identity
  source, source_error, source_status = Open3.capture3("git", "-C", SOURCE_ROOT, "rev-parse", "HEAD")
  w154_require(source_status.success? && source.strip == SOURCE_REVISION,
    "pinned shallow source revision differs: #{source.strip.inspect} #{source_error}")
  changes, changes_error, changes_status = Open3.capture3(
    "git", "-C", SOURCE_ROOT, "status", "--porcelain", "--untracked-files=normal"
  )
  w154_require(changes_status.success? && changes.empty?,
    "pinned source tree is not clean: #{changes.inspect} #{changes_error}")
  source.strip
end

def w154_create_sql
  <<~SQL.strip
    CREATE TABLE default.#{TABLE}
    (
      id UInt64,
      root_dynamic Dynamic(max_types=4),
      array_dynamic Array(Dynamic),
      pair Tuple(left Dynamic, right Dynamic),
      unused_variant Variant(Array(Dynamic(max_types=0)), UInt8),
      empty_nested Array(Dynamic(max_types=0))
    )
    ENGINE = MergeTree
    ORDER BY id
    SETTINGS
      index_granularity=8192,
      index_granularity_bytes=10485760,
      enable_mixed_granularity_parts=1,
      min_rows_for_wide_part=0,
      min_bytes_for_wide_part=0,
      compress_marks=0,
      min_compress_block_size=0,
      max_compress_block_size=4096,
      default_compression_codec='LZ4'
  SQL
end

def w154_row(id, root_value, array_value, left_value, right_value)
  unused = "CAST(toUInt8(#{40 + id}), 'Variant(Array(Dynamic(max_types=0)), UInt8)')"
  empty = "CAST([], 'Array(Dynamic(max_types=0))')"
  "SELECT #{id}, #{root_value}, #{array_value}, tuple(#{left_value}, #{right_value}), #{unused}, #{empty}"
end

def w154_insert_sql
  dynamic = ->(value) { "CAST(#{value}, 'Dynamic')" }
  root_dynamic = ->(value) { "CAST(#{value}, 'Dynamic(max_types=4)')" }
  array_dynamic = ->(values) { "[#{values.map { |value| dynamic.call(value) }.join(', ')}]" }
  array_dynamic_empty = "CAST([], 'Array(Dynamic)')"

  rows = [
    w154_row(1,
      root_dynamic.call("[#{dynamic.call("'nested-root'")}, #{dynamic.call('toUInt8(7)')} ]"),
      array_dynamic.call(["'array-string'", "toUInt16(21)"]),
      dynamic.call("'tuple-left'"), dynamic.call("toUInt16(31)")),
    w154_row(2,
      root_dynamic.call("'root-string'"),
      array_dynamic.call(["toUInt16(22)"]),
      dynamic.call("toUInt8(32)"), dynamic.call("toUInt64(41)")),
    w154_row(3,
      root_dynamic.call("toUInt8(8)"),
      array_dynamic_empty,
      dynamic.call("toUInt8(33)"), dynamic.call("toUInt64(42)")),
    w154_row(4,
      root_dynamic.call("toUInt64(43)"),
      array_dynamic_empty,
      dynamic.call("'tuple-left-again'"), dynamic.call("toUInt16(34)")),
  ]
  "INSERT INTO default.#{TABLE}\n" + rows.join("\nUNION ALL\n")
end

def w154_main(options)
  w154_require(options[:scratch], "--scratch is required; runner never creates or reuses its scratch directory")
  w154_require(options[:driver], "--driver is required")
  root = w154_validate_scratch(options[:scratch])
  results = File.join(root, "results")
  Dir.mkdir(results, 0o700)
  driver_dir = File.join(results, "driver")
  Dir.mkdir(driver_dir, 0o700)

  driver, driver_digest = w154_validate_driver(options[:driver])
  binary = options[:binary]
  w154_require(File.file?(binary) && File.executable?(binary) && !File.symlink?(binary),
    "pinned ClickHouse executable is absent, non-executable, or a symlink")
  digest = Digest::SHA256.file(binary).hexdigest
  w154_require(digest == EXECUTABLE_SHA256, "runtime SHA-256 differs: #{digest}")
  source_revision = w154_check_source_identity

  manifest = [
    "qualification=stock-produced Dynamic V3 structure metadata and occurrence sites",
    "runtime_version=#{VERSION}",
    "runtime_sha256=#{digest}",
    "runtime_build_hash=#{BUILD_HASH}",
    "source_reference=#{SOURCE_ROOT}@#{source_revision}",
    "source_worktree=clean",
    "source_is_reference_only; it is not asserted to build the runtime",
    "driver=#{driver}",
    "driver_sha256=#{driver_digest}",
    "fixture=one four-row Wide MergeTree part with root Dynamic(max_types=4) containing Array(Dynamic), String, UInt8, and UInt64, declared Array(Dynamic), two tuple Dynamic fields, unused Variant(Array(Dynamic(max_types=0))) arm, and all-empty Array(Dynamic(max_types=0)) child",
    "controls=root cap admits all four observed ordinary types; the implicit SharedVariant canonical arm remains distinct from ordinary String but is not claimed to contain a selected root row; tuple site structure blobs are valid stock outputs and swapped only for the independent expected-site roster rejection",
    "empty_children=unused Variant child and declared empty Array child must each have a present decodable zero-type structure prefix",
    "scope=complete per-site structure decode/encode and site-to-roster identity only",
    "not_a_gate=does not qualify generic Dynamic bulk values, legacy DynamicValueCodec admission, full part readers/writers, Object, projections, or current-master compatibility",
  ].join("\n") + "\n"
  w154_write_new_file(File.join(results, "manifest.txt"), manifest)

  queries = W154StockQueries.new(binary, root)
  version = queries.call_success("version", "SELECT version() FORMAT TSVRaw")
  w154_require(version.strip == VERSION, "runtime version differs: #{version.inspect}")
  build = queries.call_success("build-identity",
    "SELECT concat(name, '=', value) FROM system.build_options WHERE name IN ('GIT_HASH','VERSION_GITHASH') ORDER BY name FORMAT TSVRaw")
  expected_build = "GIT_HASH=#{BUILD_HASH}\nVERSION_GITHASH=#{BUILD_HASH}\n"
  w154_require(build == expected_build, "runtime build identity differs: #{build.inspect}")

  create = queries.call("create-wide-fixture", w154_create_sql)
  queries.require_success(create, "CREATE W154 stock fixture")
  insert = queries.call("insert-wide-fixture", w154_insert_sql)
  queries.require_success(insert, "INSERT W154 stock fixture")

  columns = queries.call_success("column-types",
    "SELECT name, type FROM system.columns WHERE database='default' AND table='#{TABLE}' ORDER BY position FORMAT TSVRaw")
  expected_columns = [
    "id\tUInt64",
    "root_dynamic\tDynamic(max_types=4)",
    "array_dynamic\tArray(Dynamic)",
    "pair\tTuple(left Dynamic, right Dynamic)",
    "unused_variant\tVariant(Array(Dynamic(max_types=0)), UInt8)",
    "empty_nested\tArray(Dynamic(max_types=0))",
  ].join("\n") + "\n"
  w154_require(columns == expected_columns, "stock-normalized fixture column types differ: #{columns.inspect}")

  shared = queries.call_success("root-sharedvariant-control",
    "SELECT id, dynamicType(root_dynamic), toUInt8(isDynamicElementInSharedData(root_dynamic)) FROM default.#{TABLE} ORDER BY id SETTINGS print_pretty_type_names=0 FORMAT TSVRaw")
  expected_shared = "1\tArray(Dynamic)\t0\n2\tString\t0\n3\tUInt8\t0\n4\tUInt64\t0\n"
  w154_require(shared == expected_shared,
    "stock root Dynamic roster/implicit SharedVariant control differs: #{shared.inspect}")

  fixture_values = queries.call_success("fixture-values",
    "SELECT id, dynamicType(root_dynamic), toUInt8(isDynamicElementInSharedData(root_dynamic)), length(array_dynamic), dynamicType(tupleElement(pair, 1)), dynamicType(tupleElement(pair, 2)), length(empty_nested) FROM default.#{TABLE} ORDER BY id SETTINGS print_pretty_type_names=0 FORMAT TSVRaw")
  expected_fixture_values = [
    "1\tArray(Dynamic)\t0\t2\tString\tUInt16\t0",
    "2\tString\t0\t1\tUInt8\tUInt64\t0",
    "3\tUInt8\t0\t0\tUInt8\tUInt64\t0",
    "4\tUInt64\t0\t0\tString\tUInt16\t0",
  ].join("\n") + "\n"
  w154_require(fixture_values == expected_fixture_values,
    "stock row values differ from the exact finite fixture: #{fixture_values.inspect}")

  part_rows = queries.call_success("active-wide-part",
    "SELECT name, partition_id, min_block_number, max_block_number, level, rows, part_type, path FROM system.parts WHERE database='default' AND table='#{TABLE}' AND active=1 ORDER BY name FORMAT TSVRaw")
  entries = part_rows.lines.map { |line| line.chomp.split("\t", -1) }
  w154_require(entries.size == 1 && entries.first.size == 8, "expected one active part, got #{part_rows.inspect}")
  part_name, partition_id, min_block, max_block, level, rows, part_type, part = entries.first
  w154_require([min_block, max_block, level].all? { |value| value.match?(/\A\d+\z/) },
    "part block identity fields are not unsigned integers: #{part_rows.inspect}")
  w154_require(part_name == "#{partition_id}_#{min_block}_#{max_block}_#{level}" && min_block == max_block && level == "0",
    "stock fixture part identity is not the exact single-insert part: #{part_rows.inspect}")
  w154_require(rows == "4" && part_type == "Wide", "fixture is not one four-row Wide part: #{part_rows.inspect}")
  part = File.realpath(part)
  store = File.realpath(File.join(root, "stores", "w154"))
  w154_require(part.start_with?(store + File::SEPARATOR), "stock part escaped the isolated W154 store")
  w154_require(File.basename(part) == part_name, "resolved stock part directory does not match system.parts identity")

  qualified = w154_call_driver(driver, root, "stock-site-qualification", "--qualify", part)
  w154_require(qualified[:success], "Crystal stock metadata qualification failed: #{qualified[:stderr].inspect}")
  w154_require(qualified[:stdout].include?("NEGATIVE-CONTROL\tswapped-site-stock-valid\tdecode=accepted\tindependent-site-roster=REJECTED"),
    "Crystal driver omitted the stock-valid swapped-site semantic control: #{qualified[:stdout].inspect}")
  w154_require(qualified[:stdout].include?("sites=7 empty_child_sites=2 swapped_site_control=REJECTED"),
    "Crystal driver omitted the finite site/empty-child summary: #{qualified[:stdout].inspect}")

  summary = [
    "result\tstock-produced-Wide-DynamicStructure-site-qualification\tPASS",
    "part_path\t#{part}",
    "part_name\t#{part_name}",
    "partition_id\t#{partition_id}",
    "part_block_range\t#{min_block}-#{max_block}",
    "part_level\t#{level}",
    "rows\t#{rows}",
    "part_type\t#{part_type}",
    "fixture_values\t#{fixture_values.lines.map(&:chomp).join(';')}",
    "actual_root_values_and_shared_flag\t#{shared.lines.map(&:chomp).join(';')}",
    "driver_stdout\tresults/driver/stock-site-qualification.stdout",
    "driver_stderr\tresults/driver/stock-site-qualification.stderr",
  ].join("\n") + "\n"
  w154_write_new_file(File.join(results, "summary.tsv"), summary)
  puts "W154 stock DynamicStructure/site qualification captured under #{root}"
end

def main
  options = {binary: DEFAULT_BINARY, scratch: nil, driver: nil}
  OptionParser.new do |parser|
    parser.banner = "Usage: ruby scripts/check_dynamic_bulk_structure_w154.rb --driver PATH --scratch EMPTY_W154_SUBDIR [--binary PATH]"
    parser.on("--binary PATH", "Pinned ClickHouse executable") { |value| options[:binary] = value }
    parser.on("--driver PATH", "Built Crystal stock metadata/site qualifier") { |value| options[:driver] = value }
    parser.on("--scratch PATH", "Caller-created empty direct child of a /private/tmp/crystal-click-w154-* root") { |value| options[:scratch] = value }
  end.parse!
  w154_main(options)
rescue W154Failure => error
  warn error.message
  exit 1
end

main
