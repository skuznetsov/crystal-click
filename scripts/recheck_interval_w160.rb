#!/usr/bin/env ruby
# Independent stock-side Interval Wide oracle. Expected types, keys, and raw
# Int64 values below are literals, independent of Crystal reader output.
require "digest"
require "fileutils"
require "find"
require "open3"

# Stream bounded stage results through the wrapper instead of buffering them
# until the full serial native qualification finishes.
STDOUT.sync = true

VERSION = "26.10.1.1201"
BUILD_HASH = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
SOURCE_ROOT = "/Users/sergey/SrcArchives/clickhouse-2026-10-04-depth1-41b7bd50"
SOURCE_REVISION = "41b7bd50051cc2017fe5ca5505fb35c9dc620000"
ROOT_PREFIX = "/private/tmp/crystal-click-interval-w160."
DEFAULT_BINARY = "/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped"
TYPES = [
  ["IntervalNanosecond", "nanosecond", 0],
  ["IntervalMicrosecond", "microsecond", 1],
  ["IntervalMillisecond", "millisecond", 2],
  ["IntervalSecond", "second", 3],
  ["IntervalMinute", "minute", 4],
  ["IntervalHour", "hour", 5],
  ["IntervalDay", "day", 6],
  ["IntervalWeek", "week", 7],
  ["IntervalMonth", "month", 8],
  ["IntervalQuarter", "quarter", 9],
  ["IntervalYear", "year", 10],
].freeze
KEYS = [1, 2, 4, 6, 9, 11].freeze
STOCK_COUNTS = [7, -3, 0, 42, -1, 11].freeze
STOCK_NULLABLE_COUNTS = [7, -3, 0, nil, -1, 11].freeze
LIBRARY_COUNTS = [-(2**63), -3, 0, 42, -1, (2**63) - 1].freeze
LIBRARY_NULLABLE_COUNTS = [-(2**63), -3, 0, nil, -1, (2**63) - 1].freeze
VALUE_MUTANT_COUNTS = [-(2**63) + 1, -3, 0, 42, -1, (2**63) - 1].freeze
STOCK_SETTINGS = <<~SQL.freeze
  index_granularity = 2,
  index_granularity_bytes = 10485760,
  enable_mixed_granularity_parts = 1,
  min_rows_for_wide_part = 0,
  min_bytes_for_wide_part = 0,
  min_level_for_wide_part = 0,
  compress_marks = 0,
  compress_primary_key = 0,
  min_compress_block_size = 0,
  max_compress_block_size = 4096,
  ratio_of_defaults_for_sparse_serialization = 1.0,
  default_compression_codec = 'LZ4'
SQL

class W160Failure < StandardError; end

def fail!(message)
  raise W160Failure, "W160 independent stock/literal oracle: #{message}"
end

def require_true(condition, message)
  fail!(message) unless condition
end

def write_new(path, bytes)
  require_true(!File.exist?(path) && !File.symlink?(path), "refusing to overwrite evidence #{path}")
  File.open(path, "wbx", 0o600) { |file| file.write(bytes) }
rescue Errno::EEXIST
  fail!("refusing to overwrite evidence #{path}")
end

def make_dir(path)
  require_true(!File.exist?(path) && !File.symlink?(path), "refusing to reuse scratch directory #{path}")
  Dir.mkdir(path, 0o700)
end

def i64_le(value)
  [value].pack("q<")
end

def u64_le(value)
  [value].pack("Q<")
end

def interval_columns
  ["pk UInt64"] + TYPES.flat_map do |type_name, suffix, _kind|
    ["s_#{suffix} #{type_name}", "n_#{suffix} Nullable(#{type_name})"]
  end
end

def select_columns
  ["pk"] + TYPES.flat_map { |_type_name, suffix, _kind| ["s_#{suffix}", "n_#{suffix}"] }
end

def stock_rowbinary_input
  output = +"".b
  KEYS.each_with_index do |key, row|
    output << u64_le(key)
    TYPES.each do |_type_name, _suffix, _kind|
      output << i64_le(STOCK_COUNTS.fetch(row))
      nullable = STOCK_NULLABLE_COUNTS.fetch(row)
      if nullable.nil?
        output << "\x01".b
      else
        output << "\x00".b << i64_le(nullable)
      end
    end
  end
  output
end

def expected_stock_rowbinary(selected_rows)
  output = +"".b
  selected_rows.each do |row|
    output << u64_le(KEYS.fetch(row))
    TYPES.each do |_type_name, _suffix, _kind|
      output << i64_le(STOCK_COUNTS.fetch(row))
      nullable = STOCK_NULLABLE_COUNTS.fetch(row)
      if nullable.nil?
        output << "\x01".b
      else
        output << "\x00".b << i64_le(nullable)
      end
    end
  end
  output
end

def expected_library_rowbinary(selected_rows, nullable:, counts: LIBRARY_COUNTS)
  output = +"".b
  selected_rows.each do |row|
    output << u64_le(KEYS.fetch(row))
    value = nullable ? LIBRARY_NULLABLE_COUNTS.fetch(row) : counts.fetch(row)
    if nullable
      if value.nil?
        output << "\x01".b
      else
        output << "\x00".b << i64_le(value)
      end
    else
      output << i64_le(value)
    end
  end
  output
end

class W160StockQueries
  attr_reader :evidence

  def initialize(binary, root)
    @binary = binary
    @evidence = File.join(root, "results", "ruby-oracle")
    make_dir(@evidence)
    @sequence = 0
  end

  def call(label, store, sql, input: nil)
    @sequence += 1
    safe_label = label.gsub(/[^A-Za-z0-9_.-]/, "_")
    base = File.join(@evidence, format("%04d-%s", @sequence, safe_label))
    write_new(base + ".sql", sql + ";\n")
    args = [
      @binary, "local", "--path", store, "--session_timezone=UTC",
      "--print_pretty_type_names=0", "--output_format_json_quote_64bit_integers=0",
      "--max_threads=1", "--max_insert_threads=1", "--max_memory_usage=536870912",
      "--query", sql,
    ]
    env = {"TZ" => "UTC"}
    if input
      stdout, stderr, status = Open3.capture3(env, *args, stdin_data: input, chdir: ENV.fetch("W160_REPO_ROOT"))
    else
      stdout, stderr, status = Open3.capture3(env, *args, chdir: ENV.fetch("W160_REPO_ROOT"))
    end
    write_new(base + ".stdout", stdout.b)
    write_new(base + ".stderr", stderr.b)
    [base + ".sql", base + ".stdout", base + ".stderr"].each do |path|
      require_true(File.size(path) <= 8 * 1024 * 1024, "evidence file exceeds 8 MiB: #{path}")
    end
    fail!("stock query failed at #{label}: #{stderr}\nSQL=#{sql}") unless status.success?
    stdout.b
  end
end

def verify_pins(binary, queries, root)
  require_true(File.file?(binary) && File.executable?(binary) && !File.symlink?(binary),
    "pinned ClickHouse executable is absent, non-executable, or a symlink")
  digest = Digest::SHA256.file(binary).hexdigest
  require_true(digest == EXECUTABLE_SHA256, "ClickHouse executable SHA-256 differs: #{digest}")
  source_stdout, source_stderr, source_status = Open3.capture3(
    "git", "-C", SOURCE_ROOT, "rev-parse", "HEAD", chdir: ENV.fetch("W160_REPO_ROOT")
  )
  require_true(source_status.success? && source_stdout.strip == SOURCE_REVISION,
    "pinned source revision differs: #{source_stdout.strip.inspect} #{source_stderr.inspect}")

  identity_store = File.join(root, "stores", "identity")
  make_dir(identity_store)
  version = queries.call("runtime-version", identity_store, "SELECT version() FORMAT TSVRaw").strip
  require_true(version == VERSION, "ClickHouse version differs: #{version.inspect}")
  build = queries.call("runtime-build", identity_store,
    "SELECT concat(name, '=', value) FROM system.build_options " \
    "WHERE name IN ('GIT_HASH','VERSION_GITHASH') ORDER BY name FORMAT TSVRaw")
  expected_build = "GIT_HASH=#{BUILD_HASH}\nVERSION_GITHASH=#{BUILD_HASH}\n"
  require_true(build == expected_build, "ClickHouse build hash differs: #{build.inspect}")
  write_new(File.join(queries.evidence, "pins.txt"), [
    "runtime_version=#{VERSION}", "runtime_sha256=#{digest}",
    "runtime_build_hash=#{BUILD_HASH}", "source_reference=#{SOURCE_ROOT}@#{SOURCE_REVISION}",
    "source_is_not_asserted_to_build_runtime=true",
  ].join("\n") + "\n")
end

def expected_system_columns
  (["pk\tUInt64\t1"] + TYPES.each_with_index.flat_map do |(type_name, suffix, _kind), index|
    start = index * 2 + 2
    ["s_#{suffix}\t#{type_name}\t#{start}", "n_#{suffix}\tNullable(#{type_name})\t#{start + 1}"]
  end).join("\n") + "\n"
end

def native_table_ddl(table, columns)
  "CREATE TABLE default.#{table}\n(\n    #{columns.join(",\n    ")}\n)\nENGINE = MergeTree\nORDER BY pk\nSETTINGS\n#{STOCK_SETTINGS};"
end

def assert_rowbinary(actual, expected, label)
  return if actual.b == expected.b

  shared = [actual.bytesize, expected.bytesize].min
  mismatch = (0...shared).find { |index| actual.getbyte(index) != expected.getbyte(index) } || shared
  wanted = mismatch < expected.bytesize ? expected.getbyte(mismatch).to_s(16).rjust(2, "0") : "<eof>"
  observed = mismatch < actual.bytesize ? actual.getbyte(mismatch).to_s(16).rjust(2, "0") : "<eof>"
  fail!("#{label} RowBinary differs: expected #{expected.bytesize} bytes, observed #{actual.bytesize}; byte #{mismatch}: expected #{wanted}, got #{observed}")
end

def literal_interval_oracle_matches?(actual_type, expected_type, actual_rowbinary, expected_rowbinary)
  actual_type == expected_type && actual_rowbinary.b == expected_rowbinary.b
end

def real_directory_beneath!(path, owned_root, label)
  normalized = path.sub(%r{/+\z}, "")
  require_true(File.directory?(normalized) && !File.symlink?(normalized), "#{label} is absent or a symlink: #{path}")
  root_real = File.realpath(owned_root)
  path_real = File.realpath(normalized)
  require_true(path_real.start_with?(root_real + File::SEPARATOR) && path_real != root_real,
    "#{label} resolved outside its owned root: #{path_real}")
  path_real
rescue Errno::ENOENT, Errno::EACCES => error
  fail!("cannot resolve #{label} safely: #{error.message}")
end

def run_crystal(crystal, root, label, *arguments, extra_env: {})
  evidence = File.join(root, "results", "crystal")
  Dir.mkdir(evidence) unless Dir.exist?(evidence)
  base = File.join(evidence, label)
  env = {"CRYSTAL_CACHE_DIR" => ENV.fetch("CRYSTAL_CACHE_DIR"), "TZ" => "UTC"}.merge(extra_env)
  stdout, stderr, status = Open3.capture3(env, crystal, *arguments, chdir: ENV.fetch("W160_REPO_ROOT"))
  write_new(base + ".stdout", stdout.b)
  write_new(base + ".stderr", stderr.b)
  fail!("Crystal command #{label} failed: #{stderr}") unless status.success?
  puts stdout unless stdout.empty?
  nil
end

def create_native_source(binary, queries, root)
  store = File.join(root, "stores", "native-stock")
  make_dir(store)
  table = "w160_interval_stock"
  queries.call("create-native-stock", store, native_table_ddl(table, interval_columns))
  queries.call("insert-native-stock-rowbinary", store,
    "INSERT INTO default.#{table} FORMAT RowBinary", input: stock_rowbinary_input)

  columns = queries.call("native-stock-columns", store,
    "SELECT name, type, toString(position) FROM system.columns " \
    "WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  require_true(columns == expected_system_columns, "native stock source exact kind/type declarations differ")
  check = queries.call("check-native-stock", store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  require_true(check == "all_1_1_0\t1", "native stock source CHECK TABLE differs: #{check.inspect}")
  part_info = queries.call("native-stock-part", store,
    "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts " \
    "WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw")
  fields = part_info.strip.split("\t", -1)
  require_true(fields.size == 5 && fields[0, 4] == ["all_1_1_0", "6", "4", "Wide"],
    "native source is not one six-row Wide part with three real plus terminal marks: #{part_info.inspect}")
  source_part = fields[4]
  source_part = real_directory_beneath!(source_part, store, "native source part path")

  projection = select_columns.join(", ")
  [
    ["full", "", (0...KEYS.size).to_a],
    ["middle", " WHERE pk >= 4 AND pk < 9", [2, 3]],
    ["empty", " WHERE pk = 0", []],
  ].each do |label, where, selected|
    actual = queries.call("native-stock-rowbinary-#{label}", store,
      "SELECT #{projection} FROM default.#{table}#{where} ORDER BY pk FORMAT RowBinary")
    assert_rowbinary(actual, expected_stock_rowbinary(selected), "native stock #{label}")
  end

  local_part = File.join(root, "native-stock-part")
  require_true(!File.exist?(local_part) && !File.symlink?(local_part), "refusing to overwrite copied native source part")
  FileUtils.cp_r(source_part, local_part)
  puts "PASS native stock source: all 11 exact types, Wide/LZ4 producer CHECK, raw RowBinary full/middle/empty"
  {store: store, table: table, part: local_part}
end

def run_stock_reader_admission(crystal, root, part)
  run_crystal(
    crystal,
    root,
    "stock-reader-admission",
    "spec",
    "--single-module",
    "--threads",
    "1",
    "--error-trace",
    "--link-flags=-fuse-ld=ld",
    "spec/interval_w160_stock_reader_red_spec.cr",
    extra_env: {
      "W160_INTERVAL_STOCK_WIDE_PART" => part,
      "W160_INTERVAL_STOCK_VALUE_COLUMN" => "s_second",
    }
  )
  puts "PASS opt-in existing-public-API stock Wide reader spec executed on native part"
end

def run_library_driver(crystal, root, native_part)
  parts = File.join(root, "library-parts")
  make_dir(parts)
  run_crystal(
    crystal,
    root,
    "library-driver",
    "run",
    "--single-module",
    "--threads",
    "1",
    "--error-trace",
    "--link-flags=-fuse-ld=ld",
    "scripts/check_interval_w160.cr",
    extra_env: {"W160_PART_ROOT" => parts, "W160_INTERVAL_STOCK_WIDE_PART" => native_part}
  )
  parts
end

def part_files(part)
  paths = []
  Find.find(part) do |path|
    next if path == part
    require_true(!File.symlink?(path), "symbolic link in complete part #{path}")
    next if File.directory?(path)
    require_true(File.file?(path), "unexpected non-file part entry #{path}")
    paths << path.delete_prefix(part + "/")
  end
  paths.sort
end

def attach_part(binary, queries, root, source_part, declaration, nullable, label, counts: LIBRARY_COUNTS)
  source_part = real_directory_beneath!(source_part, root, "library-authored complete part #{label}")
  store = File.join(root, "stores", "writers")
  Dir.mkdir(store) unless Dir.exist?(store)
  table = "w160_#{label.gsub(/[^a-z0-9_]/, "_")}"
  type = nullable ? "Nullable(#{declaration})" : declaration
  columns = ["pk UInt64", "v #{type}"]
  queries.call("create-#{label}", store, native_table_ddl(table, columns))
  data_path = queries.call("data-path-#{label}", store,
    "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  require_true(!data_path.empty?, "no native table path for #{table}")
  data_path = real_directory_beneath!(data_path, store, "native table path for #{table}")
  detached = File.join(data_path, "detached")
  if File.exist?(detached) || File.symlink?(detached)
    detached = real_directory_beneath!(detached, data_path, "native detached directory for #{table}")
    require_true(Dir.empty?(detached), "refusing to reuse nonempty detached directory #{detached}")
  else
    Dir.mkdir(detached)
  end
  detached_part = File.join(detached, "all_1_1_0")
  require_true(!File.exist?(detached_part) && !File.symlink?(detached_part), "refusing to overwrite detached part #{detached_part}")
  FileUtils.cp_r(source_part, detached_part)
  queries.call("attach-#{label}", store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  check = queries.call("check-#{label}", store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  require_true(check == "all_1_1_0\t1", "stock CHECK TABLE rejected complete library part #{label}: #{check.inspect}")
  observed_type = queries.call("type-#{label}", store,
    "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  require_true(observed_type == "pk\tUInt64\nv\t#{type}\n", "attached exact Interval kind/type differs for #{label}: #{observed_type.inspect}")

  expected_counts = nullable ? LIBRARY_NULLABLE_COUNTS : counts
  [
    ["full", "", (0...KEYS.size).to_a],
    ["middle", " WHERE pk >= 4 AND pk < 9", [2, 3]],
    ["empty", " WHERE pk = 0", []],
  ].each do |window, where, selected|
    actual = queries.call("rowbinary-#{label}-#{window}", store,
      "SELECT pk, v FROM default.#{table}#{where} ORDER BY pk FORMAT RowBinary")
    expected = expected_library_rowbinary(selected, nullable: nullable, counts: expected_counts)
    assert_rowbinary(actual, expected, "library part #{label} #{window}")
  end
  puts "PASS library→stock #{label}: ATTACH/CHECK, exact #{type}, full/middle/empty raw RowBinary"
  table
end

def verify_type_mutant(binary, queries, root, second_part)
  mutant_root = File.join(root, "mutants")
  make_dir(mutant_root)
  mutant = File.join(mutant_root, "second-declared-month")
  FileUtils.cp_r(second_part, mutant)
  columns_path = File.join(mutant, "columns.txt")
  before = File.binread(columns_path)
  require_true(before.scan("IntervalSecond").length == 1, "Second fixture does not contain one exact declaration")
  after = before.sub("IntervalSecond", "IntervalMonth")
  File.binwrite(columns_path, after)

  original_files = part_files(second_part)
  mutant_files = part_files(mutant)
  require_true(original_files == mutant_files, "type mutant changed the complete-part file roster")
  changed = original_files.select do |relative|
    File.binread(File.join(second_part, relative)) != File.binread(File.join(mutant, relative))
  end
  require_true(changed == ["columns.txt"], "type mutant changed more than its Interval declaration: #{changed.inspect}")
  original_expected_type = "IntervalSecond"
  mutant_declared_type = after.lines.find { |line| line.start_with?("`v` ") }&.split(" ", 2)&.last&.strip
  require_true(mutant_declared_type == "IntervalMonth", "wrong-kind mutation did not change only Second→Month")
  table = attach_part(binary, queries, root, mutant, "IntervalMonth", false,
    "wrong_kind_second_declared_month", counts: LIBRARY_COUNTS)
  store = File.join(root, "stores", "writers")
  actual_type = queries.call("wrong-kind-mutant-type", store,
    "SELECT type FROM system.columns WHERE database='default' AND table='#{table}' AND name='v' FORMAT TSVRaw").strip
  actual_rowbinary = queries.call("wrong-kind-mutant-original-second-oracle", store,
    "SELECT pk, v FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  expected_rowbinary = expected_library_rowbinary((0...KEYS.size).to_a, nullable: false, counts: LIBRARY_COUNTS)
  require_true(actual_type == mutant_declared_type, "attached Month mutant did not retain its declared Month kind")
  require_true(actual_rowbinary.b == expected_rowbinary.b, "wrong-kind mutant changed raw counts instead of only kind")
  require_true(!literal_interval_oracle_matches?(actual_type, original_expected_type, actual_rowbinary, expected_rowbinary),
    "unchanged Second exact-type/raw-count oracle unexpectedly accepted same-width Month")
  write_new(File.join(queries.evidence, "wrong-kind-oracle-rejection.txt"), [
    "expected_type=#{original_expected_type}", "mutant_declared_type=#{mutant_declared_type}",
    "rejection_gate=unchanged literal exact-type plus raw-count RowBinary comparator after successful Month ATTACH/CHECK",
    "all_non_columns_part_files_unchanged=true", "raw_value_stream_unchanged=true",
  ].join("\n") + "\n")
  puts "PASS wrong-kind mutant: stock Month ATTACH/CHECK succeeds; unchanged Second exact-type oracle rejects while counts match"
end

def verify_value_mutant(queries, root, part_root)
  mutant = File.join(part_root, "scalar-second-value-mutant", "all_1_1_0")
  require_true(File.directory?(mutant) && File.basename(mutant) == "all_1_1_0", "library driver omitted canonical value-mutant part")
  target = attach_part(ENV.fetch("CLICKHOUSE_BIN"), queries, root, mutant,
    "IntervalSecond", false, "value_mutant_second", counts: VALUE_MUTANT_COUNTS)
  store = File.join(root, "stores", "writers")
  actual = queries.call("rowbinary-value-mutant-original-oracle", store,
    "SELECT pk, v FROM default.#{target} ORDER BY pk FORMAT RowBinary")
  original_expected = expected_library_rowbinary((0...KEYS.size).to_a, nullable: false)
  mutant_expected = expected_library_rowbinary((0...KEYS.size).to_a, nullable: false, counts: VALUE_MUTANT_COUNTS)
  assert_rowbinary(actual, mutant_expected, "one-count value mutant intended output")
  require_true(!literal_interval_oracle_matches?("IntervalSecond", "IntervalSecond", actual, original_expected),
    "unchanged original exact-type/raw-count oracle unexpectedly accepted the one-count mutant")
  write_new(File.join(queries.evidence, "wrong-value-oracle-rejection.txt"), [
    "expected_type=IntervalSecond", "expected_raw_counts=#{LIBRARY_COUNTS.join(",")}",
    "mutant_raw_counts=#{VALUE_MUTANT_COUNTS.join(",")}",
    "rejection_gate=unchanged literal key and raw-count RowBinary comparator",
    "stock_attach_and_check=passed",
  ].join("\n") + "\n")
  puts "PASS wrong-value mutant: stock CHECK succeeds, unchanged original raw-count oracle rejects exactly one changed count"
end

def main
  require_true(ENV["W160_EXECUTE_AS_ROOT"] == "YES", "set W160_EXECUTE_AS_ROOT=YES only under root-owned resource guard")
  root = ENV.fetch("W160_PAIR_ROOT")
  require_true(root.start_with?(ROOT_PREFIX) && File.realpath(root) == root && !File.symlink?(root),
    "W160 output root is absent, unsafe, or noncanonical")
  # The shell wrapper's tee may create this regular log before or after Ruby
  # starts. Admit only that owned output, never an arbitrary reused root.
  children = Dir.children(root).sort
  require_true((children - ["recheck.log"]) == ["crystal-cache"],
    "W160 root must be fresh with only its isolated cache and optional wrapper log")
  log = File.join(root, "recheck.log")
  require_true(!File.symlink?(log) && (!File.exist?(log) || File.file?(log)),
    "W160 wrapper log is not a regular owned output")

  repo_root = File.realpath(File.expand_path("..", __dir__))
  ENV["W160_REPO_ROOT"] = repo_root
  %w[results stores].each { |name| make_dir(File.join(root, name)) }
  make_dir(File.join(root, "results", "crystal"))
  queries = W160StockQueries.new(ENV.fetch("CLICKHOUSE_BIN", DEFAULT_BINARY), root)
  verify_pins(ENV.fetch("CLICKHOUSE_BIN", DEFAULT_BINARY), queries, root)
  native = create_native_source(ENV.fetch("CLICKHOUSE_BIN", DEFAULT_BINARY), queries, root)
  crystal = ENV.fetch("CRYSTAL_BIN")
  run_stock_reader_admission(crystal, root, native.fetch(:part))
  part_root = run_library_driver(crystal, root, native.fetch(:part))

  TYPES.each do |type_name, suffix, kind|
    [
      [false, File.join(part_root, "scalar_#{suffix}", "all_1_1_0")],
      [true, File.join(part_root, "nullable_#{suffix}", "all_1_1_0")],
    ].each do |nullable, part|
      require_true(kind >= 0 && File.directory?(part), "missing canonical complete library part #{part}")
      attach_part(
        ENV.fetch("CLICKHOUSE_BIN", DEFAULT_BINARY), queries, root, part,
        type_name, nullable, "#{nullable ? "nullable" : "scalar"}_#{suffix}"
      )
    end
  end

  second_part = File.join(part_root, "scalar_second", "all_1_1_0")
  verify_type_mutant(ENV.fetch("CLICKHOUSE_BIN", DEFAULT_BINARY), queries, root, second_part)
  verify_value_mutant(queries, root, part_root)

  write_new(File.join(queries.evidence, "summary.txt"), <<~TEXT)
    PASS native-authored Wide/LZ4 table with all 11 scalar and Nullable Interval declarations
    PASS exact stock schema and raw RowBinary full/middle/empty value comparisons
    PASS opt-in existing-public-API stock IntervalSecond reader RED spec executed with literal full/middle reads
    PASS 22 independently library-authored complete parts, each ATTACHed and CHECK TABLE-validated against stock
    PASS all 22 stock readers returned exact literal type plus full/middle/empty raw RowBinary
    PASS library writer/reader exact raw Int64 LE payloads, LZ4 metadata and .mrk2 grids checked by the Crystal driver
    PASS WidePartTable batch/window and OfflineCatalog column.values consumers covered for all 11 scalar/Nullable kinds
    PASS wrong-kind Month declaration mutant rejected by unchanged exact Second type oracle with count stream unchanged
    PASS wrong-value IntervalSecond mutant remains stock-CHECK-valid and is rejected by unchanged exact raw-count oracle
    runtime=#{VERSION} build=#{BUILD_HASH} sha256=#{EXECUTABLE_SHA256}
    source_reference=#{SOURCE_ROOT}@#{SOURCE_REVISION}
    source_is_not_asserted_to_build_runtime=true
  TEXT
  puts "PASS W160 independent stock/library bidirectional Interval oracle"
end

main
