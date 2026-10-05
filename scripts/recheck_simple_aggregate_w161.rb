#!/usr/bin/env ruby
# Independent stock-side SimpleAggregateFunction Wide oracle. Expected type
# names and UInt64 payloads are literal and never derived from Crystal output.
require "digest"
require "fileutils"
require "find"
require "open3"

STDOUT.sync = true

VERSION = "26.10.1.1201"
BUILD_HASH = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
SOURCE_ROOT = "/Users/sergey/SrcArchives/clickhouse-2026-10-04-depth1-41b7bd50"
SOURCE_REVISION = "41b7bd50051cc2017fe5ca5505fb35c9dc620000"
ROOT_PREFIX = "/private/tmp/crystal-click-simple-aggregate-w161."
DEFAULT_BINARY = "/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped"

TYPES = [
  ["any", "any"],
  ["anyLast", "any_last"],
  ["min", "min"],
  ["max", "max"],
  ["sum", "sum"],
  ["sumWithOverflow", "sum_with_overflow"],
  ["groupBitAnd", "group_bit_and"],
  ["groupBitOr", "group_bit_or"],
  ["groupBitXor", "group_bit_xor"],
].freeze
KEYS = [1, 2, 3, 4, 5, 6].freeze
STOCK_VALUES = [0, 1, (2**63) - 1, 2**63, (2**64) - 2, (2**64) - 1].freeze
STOCK_NULLABLE_VALUES = [0, 1, (2**63) - 1, nil, (2**64) - 2, (2**64) - 1].freeze
LIBRARY_VALUES = [0, 1, 0x0123456789abcdef, 2**63, (2**64) - 2, (2**64) - 1].freeze
LIBRARY_NULLABLE_VALUES = [0, 1, 0x0123456789abcdef, nil, (2**64) - 2, (2**64) - 1].freeze
# The paired Crystal driver changes only the first library value from 0 to 1.
VALUE_MUTANT_VALUES = [1, 1, 0x0123456789abcdef, 2**63, (2**64) - 2, (2**64) - 1].freeze

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

class W161Failure < StandardError; end

def fail!(message)
  raise W161Failure, "W161 independent stock/literal oracle: #{message}"
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

def u64_le(value)
  [value].pack("Q<")
end

def varuint(value)
  output = +"".b
  remaining = value
  while remaining >= 0x80
    output << ((remaining & 0x7f) | 0x80)
    remaining >>= 7
  end
  output << remaining
end

def binary_string(value)
  varuint(value.bytesize) + value.b
end

def simple_aggregate_descriptor(function_name)
  [0x2e].pack("C") + binary_string(function_name) + "\x00\x01\x04".b
end

def nullable_simple_aggregate_descriptor(function_name)
  "\x23".b + simple_aggregate_descriptor(function_name)
end

def expected_min_binary_type_header
  names = ["pk", "s_min", "n_min"]
  descriptors = ["\x04".b, simple_aggregate_descriptor("min"), nullable_simple_aggregate_descriptor("min")]
  varuint(names.size) + names.map { |name| binary_string(name) }.join.b + descriptors.join.b
end

def nullable_rowbinary(value)
  value.nil? ? "\x01".b : "\x00".b + u64_le(value)
end

def declared_type(function_name, nullable:)
  type = "SimpleAggregateFunction(#{function_name}, UInt64)"
  nullable ? "Nullable(#{type})" : type
end

def native_columns
  ["pk UInt64"] + TYPES.flat_map do |function_name, suffix|
    ["s_#{suffix} #{declared_type(function_name, nullable: false)}",
     "n_#{suffix} #{declared_type(function_name, nullable: true)}"]
  end
end

def selected_columns
  ["pk"] + TYPES.flat_map { |_function_name, suffix| ["s_#{suffix}", "n_#{suffix}"] }
end

def native_rowbinary_input
  output = +"".b
  KEYS.each_with_index do |key, row|
    output << u64_le(key)
    TYPES.each do |_function_name, _suffix|
      output << u64_le(STOCK_VALUES.fetch(row))
      output << nullable_rowbinary(STOCK_NULLABLE_VALUES.fetch(row))
    end
  end
  output
end

def expected_native_rowbinary(selected_rows)
  output = +"".b
  selected_rows.each do |row|
    output << u64_le(KEYS.fetch(row))
    TYPES.each do |_function_name, _suffix|
      output << u64_le(STOCK_VALUES.fetch(row))
      output << nullable_rowbinary(STOCK_NULLABLE_VALUES.fetch(row))
    end
  end
  output
end

def expected_part_rowbinary(selected_rows, nullable:, values: LIBRARY_VALUES)
  output = +"".b
  selected_rows.each do |row|
    output << u64_le(KEYS.fetch(row))
    value = nullable ? LIBRARY_NULLABLE_VALUES.fetch(row) : values.fetch(row)
    output << (nullable ? nullable_rowbinary(value) : u64_le(value))
  end
  output
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

def literal_oracle_matches?(actual_type, expected_type, actual_rowbinary, expected_rowbinary)
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

class W161StockQueries
  attr_reader :evidence

  def initialize(binary, root)
    @binary = binary
    @evidence = File.join(root, "results", "ruby-oracle")
    make_dir(@evidence)
    @sequence = 0
  end

  def call(label, store, sql, input: nil, settings: {})
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
    settings.each { |name, value| args << "--#{name}=#{value}" }
    stdout, stderr, status = Open3.capture3({"TZ" => "UTC"}, *args,
      stdin_data: input, chdir: ENV.fetch("W161_REPO_ROOT"))
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
    "git", "-C", SOURCE_ROOT, "rev-parse", "HEAD", chdir: ENV.fetch("W161_REPO_ROOT")
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

def expected_native_columns
  (["pk\tUInt64\t1"] + TYPES.each_with_index.flat_map do |(function_name, suffix), index|
    start = index * 2 + 2
    ["s_#{suffix}\t#{declared_type(function_name, nullable: false)}\t#{start}",
     "n_#{suffix}\t#{declared_type(function_name, nullable: true)}\t#{start + 1}"]
  end).join("\n") + "\n"
end

def create_native_source(queries, root)
  store = File.join(root, "stores", "native-stock")
  make_dir(store)
  table = "w161_simple_aggregate_stock"
  queries.call("create-native-stock", store, native_table_ddl(table, native_columns))
  queries.call("insert-native-stock-rowbinary", store,
    "INSERT INTO default.#{table} FORMAT RowBinary", input: native_rowbinary_input)

  columns = queries.call("native-stock-columns", store,
    "SELECT name, type, toString(position) FROM system.columns " \
    "WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  require_true(columns == expected_native_columns, "native stock source exact function/type declarations differ")
  check = queries.call("check-native-stock", store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  require_true(check == "all_1_1_0\t1", "native stock source CHECK TABLE differs: #{check.inspect}")
  part_info = queries.call("native-stock-part", store,
    "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts " \
    "WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw")
  fields = part_info.strip.split("\t", -1)
  require_true(fields.size == 5 && fields[0, 4] == ["all_1_1_0", "6", "4", "Wide"],
    "native source is not one six-row Wide part with three real plus terminal marks: #{part_info.inspect}")
  source_part = real_directory_beneath!(fields[4], store, "native source part path")

  projection = selected_columns.join(", ")
  [
    ["full", "", (0...KEYS.size).to_a],
    ["middle", " WHERE pk >= 3 AND pk <= 4", [2, 3]],
    ["empty", " WHERE pk = 0", []],
  ].each do |label, where, selected|
    actual = queries.call("native-stock-rowbinary-#{label}", store,
      "SELECT #{projection} FROM default.#{table}#{where} ORDER BY pk FORMAT RowBinary")
    assert_rowbinary(actual, expected_native_rowbinary(selected), "native stock #{label}")
  end

  typed_header = queries.call("native-min-binary-type-header", store,
    "SELECT pk, s_min, n_min FROM default.#{table} LIMIT 0 FORMAT RowBinaryWithNamesAndTypes",
    settings: {"output_format_binary_encode_types_in_binary_format" => "1"})
  assert_rowbinary(typed_header, expected_min_binary_type_header, "native min binary type header")

  local_parent = File.join(root, "native-stock-part")
  make_dir(local_parent)
  local_part = File.join(local_parent, "all_1_1_0")
  require_true(!File.exist?(local_part) && !File.symlink?(local_part), "refusing to overwrite copied native source part")
  FileUtils.cp_r(source_part, local_part)
  puts "PASS native source: all 19 exact declarations, literal binary type header, Wide/LZ4 producer CHECK, raw RowBinary full/middle/empty"
  {store: store, table: table, part: local_part}
end

def run_crystal(crystal, root, label, *arguments, extra_env: {})
  evidence = File.join(root, "results", "crystal")
  base = File.join(evidence, label)
  env = {"CRYSTAL_CACHE_DIR" => ENV.fetch("CRYSTAL_CACHE_DIR"), "TZ" => "UTC"}.merge(extra_env)
  stdout, stderr, status = Open3.capture3(env, crystal, *arguments, chdir: ENV.fetch("W161_REPO_ROOT"))
  write_new(base + ".stdout", stdout.b)
  write_new(base + ".stderr", stderr.b)
  fail!("Crystal command #{label} failed: #{stderr}") unless status.success?
  puts stdout unless stdout.empty?
end

def run_stock_reader_admission(crystal, root, part)
  run_crystal(crystal, root, "stock-reader-admission", "spec", "--single-module", "--threads", "1",
    "--error-trace", "--link-flags=-fuse-ld=ld", "spec/simple_aggregate_w161_stock_reader_red_spec.cr",
    extra_env: {"W161_SIMPLE_AGGREGATE_STOCK_WIDE_PART" => part})
  puts "PASS opt-in existing-public-API stock Wide reader spec executed on native part"
end

def run_library_driver(crystal, root, native_part)
  parts = File.join(root, "library-parts")
  make_dir(parts)
  run_crystal(crystal, root, "library-driver", "run", "--single-module", "--threads", "1",
    "--error-trace", "--link-flags=-fuse-ld=ld", "scripts/check_simple_aggregate_w161.cr",
    extra_env: {"W161_PART_ROOT" => parts, "W161_SIMPLE_AGGREGATE_STOCK_WIDE_PART" => native_part})
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

def attach_part(queries, root, source_part, function_name, nullable, label, values: LIBRARY_VALUES)
  source_part = real_directory_beneath!(source_part, root, "library-authored complete part #{label}")
  store = File.join(root, "stores", "writers")
  Dir.mkdir(store) unless Dir.exist?(store)
  table = "w161_#{label.gsub(/[^a-z0-9_]/, "_")}"
  type = declared_type(function_name, nullable: nullable)
  queries.call("create-#{label}", store, native_table_ddl(table, ["pk UInt64", "v #{type}"]))
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
  require_true(observed_type == "pk\tUInt64\nv\t#{type}\n", "attached exact function/type differs for #{label}: #{observed_type.inspect}")

  expected_values = nullable ? LIBRARY_NULLABLE_VALUES : values
  [
    ["full", "", (0...KEYS.size).to_a],
    ["middle", " WHERE pk >= 3 AND pk <= 4", [2, 3]],
    ["empty", " WHERE pk = 0", []],
  ].each do |window, where, selected|
    actual = queries.call("rowbinary-#{label}-#{window}", store,
      "SELECT pk, v FROM default.#{table}#{where} ORDER BY pk FORMAT RowBinary")
    expected = expected_part_rowbinary(selected, nullable: nullable, values: expected_values)
    assert_rowbinary(actual, expected, "library part #{label} #{window}")
  end
  puts "PASS library→stock #{label}: ATTACH/CHECK, exact #{type}, full/middle/empty raw RowBinary"
  {table: table, store: store}
end

def verify_type_mutant(queries, root, part_root)
  source_part = File.join(part_root, "scalar_min", "all_1_1_0")
  mutant_parent = File.join(root, "mutants")
  make_dir(mutant_parent)
  mutant = File.join(mutant_parent, "min-declared-max")
  FileUtils.cp_r(source_part, mutant)
  columns_path = File.join(mutant, "columns.txt")
  before = File.binread(columns_path)
  require_true(before.scan("SimpleAggregateFunction(min, UInt64)").length == 1,
    "minimum fixture does not contain exactly one canonical declaration")
  after = before.sub("SimpleAggregateFunction(min, UInt64)", "SimpleAggregateFunction(max, UInt64)")
  File.binwrite(columns_path, after)
  require_true(before.bytesize == after.bytesize, "min→max type mutant changed metadata size")
  require_true(part_files(source_part) == part_files(mutant),
    "min→max type mutant changed the complete-part file roster")
  changed = part_files(source_part).select do |relative|
    File.binread(File.join(source_part, relative)) != File.binread(File.join(mutant, relative))
  end
  require_true(changed == ["columns.txt"], "type mutant changed more than its declaration: #{changed.inspect}")

  observed = attach_part(queries, root, mutant, "max", false, "minimum_part_declared_max")
  store = observed.fetch(:store)
  actual = queries.call("rowbinary-min-mutant-original-oracle", store,
    "SELECT pk, v FROM default.#{observed.fetch(:table)} ORDER BY pk FORMAT RowBinary")
  original = expected_part_rowbinary((0...KEYS.size).to_a, nullable: false)
  require_true(actual.b == original.b, "same-width min→max mutation changed stored values")
  require_true(!literal_oracle_matches?("SimpleAggregateFunction(max, UInt64)",
    "SimpleAggregateFunction(min, UInt64)", actual, original),
    "unchanged minimum exact-type/value oracle unexpectedly accepted max declaration")
  write_new(File.join(queries.evidence, "wrong-function-oracle-rejection.txt"), [
    "expected_type=SimpleAggregateFunction(min, UInt64)",
    "mutant_declared_type=SimpleAggregateFunction(max, UInt64)",
    "stock_attach_and_check=passed", "all_non_columns_part_files_unchanged=true",
    "raw_value_stream_unchanged=true", "rejection_gate=unchanged literal exact-type plus raw RowBinary oracle",
  ].join("\n") + "\n")
  puts "PASS function mutant: stock max ATTACH/CHECK succeeds; unchanged min oracle rejects same-width identity drift"
end

def verify_value_mutant(queries, root, part_root)
  mutant = File.join(part_root, "scalar_min_value_mutant", "all_1_1_0")
  require_true(File.directory?(mutant) && File.basename(mutant) == "all_1_1_0",
    "library driver omitted canonical scalar value-mutant part")
  observed = attach_part(queries, root, mutant, "min", false, "minimum_value_mutant", values: VALUE_MUTANT_VALUES)
  actual = queries.call("rowbinary-value-mutant-original-oracle", observed.fetch(:store),
    "SELECT pk, v FROM default.#{observed.fetch(:table)} ORDER BY pk FORMAT RowBinary")
  original = expected_part_rowbinary((0...KEYS.size).to_a, nullable: false)
  mutant_expected = expected_part_rowbinary((0...KEYS.size).to_a, nullable: false, values: VALUE_MUTANT_VALUES)
  assert_rowbinary(actual, mutant_expected, "one-value mutation intended result")
  require_true(!literal_oracle_matches?("SimpleAggregateFunction(min, UInt64)",
    "SimpleAggregateFunction(min, UInt64)", actual, original),
    "unchanged minimum exact-type/value oracle unexpectedly accepted the UInt64 value mutant")
  write_new(File.join(queries.evidence, "wrong-value-oracle-rejection.txt"), [
    "expected_type=SimpleAggregateFunction(min, UInt64)",
    "expected_values=#{LIBRARY_VALUES.join(",")}", "mutant_values=#{VALUE_MUTANT_VALUES.join(",")}",
    "stock_attach_and_check=passed", "rejection_gate=unchanged literal exact-type plus raw RowBinary oracle",
  ].join("\n") + "\n")
  puts "PASS value mutant: stock CHECK succeeds and unchanged exact raw-value oracle rejects one UInt64 change"
end

def main
  require_true(ENV["W161_EXECUTE_AS_ROOT"] == "YES", "set W161_EXECUTE_AS_ROOT=YES only under root-owned resource guard")
  root = ENV.fetch("W161_PAIR_ROOT")
  require_true(root.start_with?(ROOT_PREFIX) && File.realpath(root) == root && !File.symlink?(root),
    "W161 output root is absent, unsafe, or noncanonical")
  children = Dir.children(root).sort
  require_true((children - ["recheck.log"]) == ["crystal-cache"],
    "W161 root must be fresh with only its isolated cache and optional wrapper log")
  log = File.join(root, "recheck.log")
  require_true(!File.symlink?(log) && (!File.exist?(log) || File.file?(log)),
    "W161 wrapper log is not a regular owned output")

  ENV["W161_REPO_ROOT"] = File.realpath(File.expand_path("..", __dir__))
  %w[results stores].each { |name| make_dir(File.join(root, name)) }
  make_dir(File.join(root, "results", "crystal"))
  binary = ENV.fetch("CLICKHOUSE_BIN", DEFAULT_BINARY)
  queries = W161StockQueries.new(binary, root)
  verify_pins(binary, queries, root)
  native = create_native_source(queries, root)
  crystal = ENV.fetch("CRYSTAL_BIN")
  run_stock_reader_admission(crystal, root, native.fetch(:part))
  part_root = run_library_driver(crystal, root, native.fetch(:part))

  TYPES.each do |function_name, suffix|
    [
      [false, File.join(part_root, "scalar_#{suffix}", "all_1_1_0")],
      [true, File.join(part_root, "nullable_#{suffix}", "all_1_1_0")],
    ].each do |nullable, part|
      require_true(File.directory?(part), "missing canonical complete library part #{part}")
      attach_part(queries, root, part, function_name, nullable,
        "#{nullable ? "nullable" : "scalar"}_#{suffix}")
    end
  end

  verify_type_mutant(queries, root, part_root)
  verify_value_mutant(queries, root, part_root)
  write_new(File.join(queries.evidence, "summary.txt"), <<~TEXT)
    PASS native-authored Wide/LZ4 source with nine scalar and nine Nullable SimpleAggregateFunction declarations
    PASS exact native schema and literal stock RowBinary full/middle/empty comparisons
    PASS opt-in stock-authored public Wide reader spec with all nine scalar and Nullable functions
    PASS 18 independently library-authored complete parts ATTACHed and CHECK TABLE-validated by stock
    PASS exact type and literal full/middle/empty RowBinary comparisons for all 18 library parts
    PASS same-width min→max mutant remains stock-CHECK-valid and is rejected by unchanged exact identity oracle
    PASS value mutant remains stock-CHECK-valid and is rejected by unchanged literal value oracle
    runtime=#{VERSION} build=#{BUILD_HASH} sha256=#{EXECUTABLE_SHA256}
    source_reference=#{SOURCE_ROOT}@#{SOURCE_REVISION}
    source_is_not_asserted_to_build_runtime=true
  TEXT
  puts "PASS W161 independent stock/library bidirectional SimpleAggregateFunction oracle"
end

main
