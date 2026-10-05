#!/usr/bin/env ruby
# Independent W163 stock/library oracle. Type rosters and expected RowBinary
# bytes are literal Ruby fixtures and are never sourced from Crystal output.
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
ROOT_PREFIX = "/private/tmp/crystal-click-simple-aggregate-w163."
DEFAULT_BINARY = "/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped"

FUNCTIONS = [
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

# Literal ClickHouse eligibility matrix for the ten-carrier W163 slice.
FUNCTIONS_BY_CARRIER = {
  "UInt8" => %w[any anyLast min max sumWithOverflow groupBitAnd groupBitOr groupBitXor],
  "UInt16" => %w[any anyLast min max sumWithOverflow groupBitAnd groupBitOr groupBitXor],
  "UInt32" => %w[any anyLast min max sumWithOverflow groupBitAnd groupBitOr groupBitXor],
  "UInt64" => %w[any anyLast min max sum sumWithOverflow groupBitAnd groupBitOr groupBitXor],
  "Int8" => %w[any anyLast min max sumWithOverflow groupBitAnd groupBitOr groupBitXor],
  "Int16" => %w[any anyLast min max sumWithOverflow groupBitAnd groupBitOr groupBitXor],
  "Int32" => %w[any anyLast min max sumWithOverflow groupBitAnd groupBitOr groupBitXor],
  "Int64" => %w[any anyLast min max sum sumWithOverflow groupBitAnd groupBitOr groupBitXor],
  "Float32" => %w[any anyLast min max sumWithOverflow],
  "Float64" => %w[any anyLast min max sum sumWithOverflow],
}.freeze

FUNCTION_SUFFIX = FUNCTIONS.to_h.freeze
CARRIERS = [
  ["UInt8", "u8", "C"],
  ["UInt16", "u16", "S<"],
  ["UInt32", "u32", "L<"],
  ["UInt64", "u64", "Q<"],
  ["Int8", "i8", "c"],
  ["Int16", "i16", "s<"],
  ["Int32", "i32", "l<"],
  ["Int64", "i64", "q<"],
  ["Float32", "f32", "L<"],
  ["Float64", "f64", "Q<"],
].freeze
CARRIER_BINARY_TAGS = {
  "UInt8" => 0x01,
  "UInt16" => 0x02,
  "UInt32" => 0x03,
  "UInt64" => 0x04,
  "Int8" => 0x07,
  "Int16" => 0x08,
  "Int32" => 0x09,
  "Int64" => 0x0a,
  "Float32" => 0x0d,
  "Float64" => 0x0e,
}.freeze

# Floating values are represented here by finite IEEE bit patterns, not Ruby
# decimal floats. This preserves negative zero and avoids text/NaN normalization.
STOCK_VALUES = {
  "UInt8" => [0, 1, 0x7f, 0x80, 0xfe, 0xff],
  "UInt16" => [0, 1, 0x7fff, 0x8000, 0xfffe, 0xffff],
  "UInt32" => [0, 1, 0x7fff_ffff, 0x8000_0000, 0xffff_fffe, 0xffff_ffff],
  "UInt64" => [0, 1, (2**63) - 1, 2**63, (2**64) - 2, (2**64) - 1],
  "Int8" => [-128, -1, 0, 1, 126, 127],
  "Int16" => [-32_768, -1, 0, 1, 32_766, 32_767],
  "Int32" => [-(2**31), -1, 0, 1, (2**31) - 2, (2**31) - 1],
  "Int64" => [-(2**63), -1, 0, 1, (2**63) - 2, (2**63) - 1],
  "Float32" => [0x8000_0000, 0x3fc0_0000, 0xc010_0000, 0x7f7f_ffff, 0xff7f_ffff, 0x0000_0001],
  "Float64" => [0x8000_0000_0000_0000, 0x3ff8_0000_0000_0000, 0xc002_0000_0000_0000,
                0x7fef_ffff_ffff_ffff, 0xffef_ffff_ffff_ffff, 0x0000_0000_0000_0001],
}.freeze

LIBRARY_VALUES = {
  "UInt8" => [0x11, 0x23, 0x45, 0x67, 0x89, 0xab],
  "UInt16" => [0x0102, 0x1234, 0x2345, 0x789a, 0xabcd, 0xfedc],
  "UInt32" => [0x0102_0304, 0x1234_5678, 0x2345_6789, 0x789a_bcde, 0xabcd_ef01, 0xfedc_ba98],
  "UInt64" => [0x0123_4567_89ab_cdef, 0x1020_3040_5060_7080, 0x2345_6789_abcdef01,
               0x9876_5432_10fe_dcba, 0xaaaaaaaa_55555555, 0xfedc_ba98_7654_3210],
  "Int8" => [-127, -42, -7, 3, 58, 126],
  "Int16" => [-32_767, -12_345, -257, 42, 12_345, 32_766],
  "Int32" => [-(2**31) + 1, -123_456_789, -257, 42, 123_456_789, (2**31) - 2],
  "Int64" => [-(2**63) + 1, -1_234_567_890_123_456_789, -257, 42,
              1_234_567_890_123_456_789, (2**63) - 2],
  "Float32" => [0x8000_0000, 0x3fc0_0000, 0xc010_0000, 0x7f7f_fffe, 0xff7f_fffe, 0x0000_0002],
  "Float64" => [0x8000_0000_0000_0000, 0x3ff8_0000_0000_0000, 0xc002_0000_0000_0000,
                0x7fef_ffff_ffff_fffe, 0xffef_ffff_ffff_fffe, 0x0000_0000_0000_0002],
}.freeze

KEYS = [1, 2, 3, 4, 5, 6].freeze
EXPECTED_PROFILE_COUNT = 77

Profile = Struct.new(:function, :function_suffix, :carrier, :carrier_suffix, :name, keyword_init: true) do
  def type(nullable: false, function: self.function)
    inner = "SimpleAggregateFunction(#{function}, #{carrier})"
    nullable ? "Nullable(#{inner})" : inner
  end

  def table_label(nullable: false)
    "#{nullable ? "nullable" : "scalar"}_#{name}"
  end

  def part_path(root, nullable: false)
    File.join(root, table_label(nullable: nullable), "all_1_1_0")
  end
end

PROFILES = CARRIERS.flat_map do |carrier, carrier_suffix, _pack|
  eligible_functions = FUNCTION_SUFFIX.select do |function, _suffix|
    FUNCTIONS_BY_CARRIER.fetch(carrier).include?(function)
  end
  eligible_functions.map do |function, function_suffix|
    Profile.new(function: function, function_suffix: function_suffix, carrier: carrier,
      carrier_suffix: carrier_suffix, name: "#{function_suffix}_#{carrier_suffix}")
  end
end.freeze

class W163Failure < StandardError; end

def fail!(message)
  raise W163Failure, "W163 independent stock/literal oracle: #{message}"
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

def simple_aggregate_binary_descriptor(profile, nullable:)
  child_tag = CARRIER_BINARY_TAGS.fetch(profile.carrier)
  descriptor = "\x2e".b + binary_string(profile.function) + "\x00\x01".b + [child_tag].pack("C")
  nullable ? "\x23".b + descriptor : descriptor
end

def expected_native_binary_type_header
  names = selected_columns
  descriptors = ["\x04".b] + PROFILES.flat_map do |profile|
    [
      simple_aggregate_binary_descriptor(profile, nullable: false),
      simple_aggregate_binary_descriptor(profile, nullable: true),
    ]
  end
  varuint(names.size) + names.map { |name| binary_string(name) }.join.b + descriptors.join.b
end

def pack_format(carrier)
  CARRIERS.find { |name, _suffix, _format| name == carrier }.fetch(2)
end

def carrier_bytes(carrier, value)
  [value].pack(pack_format(carrier))
end

def nullable_rowbinary(profile, value)
  value.nil? ? "\x01".b : "\x00".b + carrier_bytes(profile.carrier, value)
end

def declared_type(profile, nullable:, function: profile.function)
  profile.type(nullable: nullable, function: function)
end

def profile_columns(profile)
  [
    "s_#{profile.name} #{declared_type(profile, nullable: false)}",
    "n_#{profile.name} #{declared_type(profile, nullable: true)}",
  ]
end

def native_columns
  ["pk UInt64"] + PROFILES.flat_map { |profile| profile_columns(profile) }
end

def selected_columns
  ["pk"] + PROFILES.flat_map { |profile| ["s_#{profile.name}", "n_#{profile.name}"] }
end

def native_rowbinary_input
  output = +"".b
  KEYS.each_with_index do |key, row|
    output << [key].pack("Q<")
    PROFILES.each do |profile|
      values = STOCK_VALUES.fetch(profile.carrier)
      output << carrier_bytes(profile.carrier, values.fetch(row))
      output << nullable_rowbinary(profile, row == 3 ? nil : values.fetch(row))
    end
  end
  output
end

def expected_native_rowbinary(selected_rows)
  output = +"".b
  selected_rows.each do |row|
    output << [KEYS.fetch(row)].pack("Q<")
    PROFILES.each do |profile|
      values = STOCK_VALUES.fetch(profile.carrier)
      output << carrier_bytes(profile.carrier, values.fetch(row))
      output << nullable_rowbinary(profile, row == 3 ? nil : values.fetch(row))
    end
  end
  output
end

def expected_profile_rowbinary(profile, selected_rows, nullable:, values:, function: profile.function)
  output = +"".b
  selected_rows.each do |row|
    output << [KEYS.fetch(row)].pack("Q<")
    value = nullable && row == 3 ? nil : values.fetch(row)
    output << (nullable ? nullable_rowbinary(profile, value) : carrier_bytes(profile.carrier, value))
  end
  output
end

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

class W163StockQueries
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
    write_new(base + ".sql", sql + "\n")
    args = [
      @binary, "local", "--path", store, "--session_timezone=UTC",
      "--print_pretty_type_names=0", "--output_format_json_quote_64bit_integers=0",
      "--max_threads=1", "--max_insert_threads=1", "--max_memory_usage=536870912",
      "--query", sql,
    ]
    settings.each { |name, value| args << "--#{name}=#{value}" }
    stdout, stderr, status = Open3.capture3({"TZ" => "UTC"}, *args,
      stdin_data: input, chdir: ENV.fetch("W163_REPO_ROOT"))
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
    "git", "-C", SOURCE_ROOT, "rev-parse", "HEAD", chdir: ENV.fetch("W163_REPO_ROOT")
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
  columns = [["pk", "UInt64", 1]]
  position = 2
  PROFILES.each do |profile|
    columns << ["s_#{profile.name}", declared_type(profile, nullable: false), position]
    position += 1
    columns << ["n_#{profile.name}", declared_type(profile, nullable: true), position]
    position += 1
  end
  columns.map { |name, type, index| "#{name}\t#{type}\t#{index}" }.join("\n") + "\n"
end

def create_native_source(queries, root)
  store = File.join(root, "stores", "native-stock")
  make_dir(store)
  table = "w163_simple_aggregate_stock"
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

  typed_header = queries.call("native-all-profiles-binary-type-header", store,
    "SELECT #{selected_columns.join(", ")} FROM default.#{table} LIMIT 0 FORMAT RowBinaryWithNamesAndTypes",
    settings: {"output_format_binary_encode_types_in_binary_format" => "1"})
  assert_rowbinary(typed_header, expected_native_binary_type_header, "native 155-column literal binary type header")

  local_parent = File.join(root, "native-stock-part")
  make_dir(local_parent)
  local_part = File.join(local_parent, "all_1_1_0")
  require_true(!File.exist?(local_part) && !File.symlink?(local_part), "refusing to overwrite copied native source part")
  FileUtils.cp_r(source_part, local_part)
  puts "PASS W163 stock source: #{PROFILES.size} exact profiles × scalar/outer Nullable; Wide/LZ4; literal full/middle/empty RowBinary"
  {store: store, table: table, part: local_part}
end

def run_crystal_spec(crystal, root, stock_part)
  evidence = File.join(root, "results", "crystal")
  base = File.join(evidence, "stock-reader-and-library-writer-spec")
  env = {
    "CRYSTAL_CACHE_DIR" => ENV.fetch("CRYSTAL_CACHE_DIR"),
    "TZ" => "UTC",
    "W163_SIMPLE_AGGREGATE_STOCK_WIDE_PART" => stock_part,
    "W163_PART_ROOT" => File.join(root, "library-parts"),
  }
  stdout, stderr, status = Open3.capture3(env, crystal, "spec", "--single-module", "--threads", "1",
    "--error-trace", "--link-flags=-fuse-ld=ld", "spec/simple_aggregate_w163_stock_reader_spec.cr",
    chdir: ENV.fetch("W163_REPO_ROOT"))
  write_new(base + ".stdout", stdout.b)
  write_new(base + ".stderr", stderr.b)
  fail!("Crystal W163 stock-reader/writer spec failed: #{stderr}") unless status.success?
  summaries = stdout.lines.map(&:strip).select { |line| line.match?(/\A\d+ examples?,/) }
  expected_summary = "2 examples, 0 failures, 0 errors, 0 pending"
  require_true(summaries == [expected_summary],
    "opt-in Crystal spec did not execute exactly two passing examples: #{summaries.inspect}")
  puts stdout unless stdout.empty?
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

def attach_part(queries, root, source_part, profile, nullable:, label:, values:, declared_function: profile.function)
  source_part = real_directory_beneath!(source_part, root, "library-authored complete part #{label}")
  files = part_files(source_part)
  require_true(files.include?("columns.txt") && files.include?("count.txt"), "library part metadata roster is incomplete for #{label}")
  store = File.join(root, "stores", "writers")
  Dir.mkdir(store) unless Dir.exist?(store)
  table = "w163_#{label.gsub(/[^a-z0-9_]/, "_")}"
  type = declared_type(profile, nullable: nullable, function: declared_function)
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
  expected_type = "pk\tUInt64\nv\t#{type}\n"
  require_true(observed_type == expected_type, "attached exact function/carrier/shape differs for #{label}: #{observed_type.inspect}")
  part_info = queries.call("part-info-#{label}", store,
    "SELECT name, toString(rows), toString(marks), part_type FROM system.parts " \
    "WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw")
  require_true(part_info == "all_1_1_0\t6\t4\tWide\n", "attached part metadata differs for #{label}: #{part_info.inspect}")

  actual_full = nil
  [
    ["full", "", (0...KEYS.size).to_a],
    ["middle", " WHERE pk >= 3 AND pk <= 4", [2, 3]],
    ["empty", " WHERE pk = 0", []],
  ].each do |window, where, selected|
    actual = queries.call("rowbinary-#{label}-#{window}", store,
      "SELECT pk, v FROM default.#{table}#{where} ORDER BY pk FORMAT RowBinary")
    expected = expected_profile_rowbinary(profile, selected, nullable: nullable, values: values,
      function: declared_function)
    assert_rowbinary(actual, expected, "library part #{label} #{window}")
    actual_full = actual if window == "full"
  end
  puts "PASS W163 library→stock #{label}: ATTACH/CHECK, exact type/rows/marks/Wide, literal full/middle/empty RowBinary"
  {table: table, store: store, type: type, full: actual_full}
end

def verify_type_mutant(queries, root, part_root)
  profile = PROFILES.find { |item| item.function == "min" && item.carrier == "UInt64" }
  source_part = profile.part_path(part_root, nullable: false)
  mutant_parent = File.join(root, "mutants")
  make_dir(mutant_parent)
  mutant = File.join(mutant_parent, "min-u64-declared-max")
  FileUtils.cp_r(source_part, mutant)
  columns_path = File.join(mutant, "columns.txt")
  before = File.binread(columns_path)
  require_true(before.scan("SimpleAggregateFunction(min, UInt64)").length == 1,
    "minimum UInt64 fixture does not contain exactly one canonical declaration")
  after = before.sub("SimpleAggregateFunction(min, UInt64)", "SimpleAggregateFunction(max, UInt64)")
  File.binwrite(columns_path, after)
  require_true(before.bytesize == after.bytesize, "min→max nominal mutant changed metadata size")
  require_true(part_files(source_part) == part_files(mutant), "min→max nominal mutant changed the complete-part file roster")
  changed = part_files(source_part).select do |relative|
    File.binread(File.join(source_part, relative)) != File.binread(File.join(mutant, relative))
  end
  require_true(changed == ["columns.txt"], "nominal mutant changed more than columns.txt: #{changed.inspect}")

  attached = attach_part(queries, root, mutant, profile, nullable: false,
    label: "min_u64_declared_max", values: LIBRARY_VALUES.fetch("UInt64"), declared_function: "max")
  original_type = declared_type(profile, nullable: false)
  original_values = expected_profile_rowbinary(profile, (0...KEYS.size).to_a,
    nullable: false, values: LIBRARY_VALUES.fetch("UInt64"))
  require_true(!literal_oracle_matches?(attached.fetch(:type),
    original_type, attached.fetch(:full), original_values),
    "unchanged min/UInt64 exact identity+value oracle unexpectedly accepted max declaration")
  write_new(File.join(queries.evidence, "wrong-function-oracle-rejection.txt"), [
    "expected_type=#{original_type}", "mutant_type=#{attached.fetch(:type)}",
    "stock_attach_and_check=passed", "all_non_columns_part_files_unchanged=true",
    "raw_value_stream_unchanged=true", "rejection_gate=unchanged literal exact-type plus raw RowBinary oracle",
  ].join("\n") + "\n")
  puts "PASS W163 nominal mutant: stock max ATTACH/CHECK succeeds; unchanged min oracle rejects same-width identity drift"
end

def verify_value_mutant(queries, root, part_root)
  profile = PROFILES.find { |item| item.function == "min" && item.carrier == "UInt64" }
  mutant = File.join(part_root, "scalar_min_u64_value_mutant", "all_1_1_0")
  require_true(File.directory?(mutant) && File.basename(mutant) == "all_1_1_0",
    "library spec omitted canonical min/UInt64 value-mutant part")
  mutant_values = [0x0123_4567_89ab_cdee, *LIBRARY_VALUES.fetch("UInt64").drop(1)].freeze
  attached = attach_part(queries, root, mutant, profile, nullable: false,
    label: "min_u64_value_mutant", values: mutant_values)
  actual = attached.fetch(:full)
  original = expected_profile_rowbinary(profile, (0...KEYS.size).to_a,
    nullable: false, values: LIBRARY_VALUES.fetch("UInt64"))
  mutant_expected = expected_profile_rowbinary(profile, (0...KEYS.size).to_a,
    nullable: false, values: mutant_values)
  assert_rowbinary(actual, mutant_expected, "min/UInt64 value mutant intended result")
  require_true(!literal_oracle_matches?(attached.fetch(:type),
    declared_type(profile, nullable: false), actual, original),
    "unchanged min/UInt64 exact identity+value oracle unexpectedly accepted changed payload")
  write_new(File.join(queries.evidence, "wrong-value-oracle-rejection.txt"), [
    "expected_type=#{declared_type(profile, nullable: false)}",
    "expected_values=#{LIBRARY_VALUES.fetch("UInt64").join(",")}",
    "mutant_values=#{mutant_values.join(",")}",
    "stock_attach_and_check=passed", "rejection_gate=unchanged literal exact-type plus raw RowBinary oracle",
  ].join("\n") + "\n")
  puts "PASS W163 value mutant: stock CHECK succeeds and unchanged exact raw-value oracle rejects one UInt64 change"
end

def main
  require_true(ENV["W163_EXECUTE_AS_ROOT"] == "YES", "set W163_EXECUTE_AS_ROOT=YES only under root-owned resource guard")
  require_true(PROFILES.size == EXPECTED_PROFILE_COUNT, "literal W163 scalar profile count differs: #{PROFILES.size}")
  root = ENV.fetch("W163_PAIR_ROOT")
  require_true(root.start_with?(ROOT_PREFIX) && File.realpath(root) == root && !File.symlink?(root),
    "W163 output root is absent, unsafe, or noncanonical")
  children = Dir.children(root).sort
  require_true((children - ["recheck.log"]) == ["crystal-cache"],
    "W163 root must be fresh with only its isolated cache and optional wrapper log")
  log = File.join(root, "recheck.log")
  require_true(!File.symlink?(log) && (!File.exist?(log) || File.file?(log)), "W163 wrapper log is not a regular owned output")

  ENV["W163_REPO_ROOT"] = File.realpath(File.expand_path("..", __dir__))
  %w[results stores].each { |name| make_dir(File.join(root, name)) }
  make_dir(File.join(root, "results", "crystal"))
  binary = ENV.fetch("CLICKHOUSE_BIN", DEFAULT_BINARY)
  queries = W163StockQueries.new(binary, root)
  verify_pins(binary, queries, root)
  native = create_native_source(queries, root)
  part_root = File.join(root, "library-parts")
  make_dir(part_root)
  run_crystal_spec(ENV.fetch("CRYSTAL_BIN"), root, native.fetch(:part))

  PROFILES.each do |profile|
    [
      [false, LIBRARY_VALUES.fetch(profile.carrier)],
      [true, LIBRARY_VALUES.fetch(profile.carrier)],
    ].each do |nullable, values|
      source_part = profile.part_path(part_root, nullable: nullable)
      require_true(File.directory?(source_part), "missing canonical complete library part #{source_part}")
      attach_part(queries, root, source_part, profile, nullable: nullable,
        label: profile.table_label(nullable: nullable), values: values)
    end
  end

  verify_type_mutant(queries, root, part_root)
  verify_value_mutant(queries, root, part_root)
  write_new(File.join(queries.evidence, "summary.txt"), <<~TEXT)
    PASS literal source matrix: #{PROFILES.size} accepted scalar profiles and #{PROFILES.size} outer Nullable profiles
    PASS stock-authored Wide/LZ4 part with exact schema and independent full/middle/empty RowBinary
    PASS opt-in Crystal spec executed stock numeric typed readers and public full-part writers
    PASS #{PROFILES.size * 2} independently library-authored complete parts ATTACHed and CHECK TABLE-validated by stock
    PASS exact canonical function/carrier/outer shape, six rows, four marks and Wide layout per attached part
    PASS literal full/middle/empty RowBinary comparisons for every scalar and outer Nullable profile
    PASS min→max metadata-only nominal mutant remains stock-CHECK-valid and is rejected by unchanged exact identity oracle
    PASS value mutant remains stock-CHECK-valid and is rejected by unchanged literal value oracle
    runtime=#{VERSION} build=#{BUILD_HASH} sha256=#{EXECUTABLE_SHA256}
    source_reference=#{SOURCE_ROOT}@#{SOURCE_REVISION}
    source_is_not_asserted_to_build_runtime=true
  TEXT
  puts "PASS W163 independent stock/library numeric SimpleAggregateFunction oracle"
end

main
