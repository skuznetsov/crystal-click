#!/usr/bin/env ruby
# Independent ClickHouse stock/library oracle for the bounded W168 text slice.
# This Ruby roster, binary descriptors, payloads, and RowBinary expectations are
# deliberately authored independently from the Crystal implementation/spec.
require "digest"
require "fileutils"
require "find"
require "open3"

STDOUT.sync = true

VERSION = "26.10.1.1201"
BUILD_HASH = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
SOURCE_ROOT = "/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1"
SOURCE_REVISION = "e9b645ed83ad3c07b64f09fbd014e8f770d8691b"
ROOT_PREFIX = "/private/tmp/crystal-click-w168."
DEFAULT_BINARY = "/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped"

FUNCTIONS = [
  ["any", "any"],
  ["anyLast", "any_last"],
  ["min", "min"],
  ["max", "max"],
].freeze

CARRIERS = [
  ["String", "string", nil, 0x15],
  ["FixedString(1)", "fixed1", 1, 0x16],
  ["FixedString(3)", "fixed3", 3, 0x16],
  ["FixedString(130)", "fixed130", 130, 0x16],
].freeze
CARRIER_WIDTH = CARRIERS.to_h { |name, _suffix, width, _tag| [name, width] }.freeze
CARRIER_TAG = CARRIERS.to_h { |name, _suffix, _width, tag| [name, tag] }.freeze
FIXED_WIDTHS = CARRIERS.each_with_object({}) do |(name, _suffix, width, _tag), widths|
  widths[name] = width if width
end.freeze

STOCK_STRING_VALUES = [
  "".b,
  "A".b,
  "\xc3\xa9".b,
  "\x00\xff\x41".b,
  "click".b,
  "\xff".b,
].freeze

LIBRARY_STRING_VALUES = [
  "L".b,
  "".b,
  "\x00\xff\x01".b,
  "\xc3\xa9".b,
  "the-end".b,
  "\xfe".b,
].freeze

KEYS = [1, 2, 3, 4, 5, 6].freeze
EXPECTED_SCALAR_PROFILE_COUNT = 16
EXPECTED_PART_COUNT = 32
EXPECTED_SELECTED_COLUMN_COUNT = 33

Profile = Struct.new(:function, :function_suffix, :carrier, :carrier_suffix, :width, keyword_init: true) do
  def name
    "#{function_suffix}_#{carrier_suffix}"
  end

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

PROFILES = CARRIERS.flat_map do |carrier, carrier_suffix, width, _tag|
  FUNCTIONS.map do |function, function_suffix|
    Profile.new(function: function, function_suffix: function_suffix, carrier: carrier,
      carrier_suffix: carrier_suffix, width: width)
  end
end.freeze

class W168Failure < StandardError; end

def fail!(message)
  raise W168Failure, "W168 independent stock/literal oracle: #{message}"
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

def storage_descriptor(profile)
  tag = CARRIER_TAG.fetch(profile.carrier)
  return [tag].pack("C") unless profile.width

  [tag].pack("C") + varuint(profile.width)
end

def aggregate_binary_descriptor(profile, nullable:)
  descriptor = "\x2e".b + binary_string(profile.function) + "\x00\x01".b + storage_descriptor(profile)
  nullable ? "\x23".b + descriptor : descriptor
end

def selected_columns
  ["pk"] + PROFILES.flat_map { |profile| ["s_#{profile.name}", "n_#{profile.name}"] }
end

def expected_binary_type_header
  descriptors = ["\x04".b] + PROFILES.flat_map do |profile|
    [aggregate_binary_descriptor(profile, nullable: false), aggregate_binary_descriptor(profile, nullable: true)]
  end
  varuint(selected_columns.size) + selected_columns.map { |name| binary_string(name) }.join.b + descriptors.join.b
end

def fixed_stock_values(width)
  seeds = case width
          when 1
            ["\x00".b, "A".b, "\xff".b, "\xc3".b, "z".b, "\xfe".b]
          when 3
            ["".b, "a".b, "\xc3\xa9".b, "a\x00b".b, "\xff".b, "XYZ".b]
          when 130
            ["".b, "\x00".b, "a\x00b".b, byte_pattern(129, 11), byte_pattern(130, 23), byte_pattern(17, 47)]
          else
            fail!("unsupported literal FixedString stock width #{width}")
          end
  seeds.map { |seed| seed.ljust(width, "\x00".b) }
end

def fixed_library_values(width)
  case width
  when 1
    ["".b, "x".b, "\x80".b, "y".b, "\xff".b, "z".b]
  when 3
    ["x".b, "".b, "\x00\xfe".b, "\xc3\xa9".b, "abc".b, "\xff".b]
  when 130
    ["".b, "q".b, "\x00\xff".b, byte_pattern(128, 5), byte_pattern(130, 91), byte_pattern(1, 173)]
  else
    fail!("unsupported literal FixedString library width #{width}")
  end
end

def byte_pattern(length, seed)
  Array.new(length) { |index| (index * 37 + seed) & 0xff }.pack("C*").b
end

def values_for(profile, native:)
  return native ? STOCK_STRING_VALUES : LIBRARY_STRING_VALUES if profile.carrier == "String"

  native ? fixed_stock_values(profile.width) : fixed_library_values(profile.width)
end

def nullable_values(values, null_index: 3)
  values.each_with_index.map { |value, index| index == null_index ? nil : value }
end

def scalar_value_rowbinary(profile, value)
  if profile.width
    require_true(value.bytesize <= profile.width, "literal FixedString value exceeds width #{profile.width}")
    value.b.ljust(profile.width, "\x00".b)
  else
    binary_string(value)
  end
end

def nullable_value_rowbinary(profile, value)
  value.nil? ? "\x01".b : "\x00".b + scalar_value_rowbinary(profile, value)
end

def native_columns
  ["pk UInt64"] + PROFILES.flat_map do |profile|
    ["s_#{profile.name} #{profile.type}", "n_#{profile.name} #{profile.type(nullable: true)}"]
  end
end

def expected_native_columns
  columns = [["pk", "UInt64", 1]]
  position = 2
  PROFILES.each do |profile|
    columns << ["s_#{profile.name}", profile.type, position]
    position += 1
    columns << ["n_#{profile.name}", profile.type(nullable: true), position]
    position += 1
  end
  columns.map { |name, type, index| "#{name}\t#{type}\t#{index}" }.join("\n") + "\n"
end

def native_rowbinary_input
  output = +"".b
  KEYS.each_with_index do |key, row|
    output << [key].pack("Q<")
    PROFILES.each do |profile|
      value = values_for(profile, native: true).fetch(row)
      output << scalar_value_rowbinary(profile, value)
      output << nullable_value_rowbinary(profile, row == 3 ? nil : value)
    end
  end
  output
end

def expected_native_rowbinary(selected_rows)
  output = +"".b
  selected_rows.each do |row|
    output << [KEYS.fetch(row)].pack("Q<")
    PROFILES.each do |profile|
      value = values_for(profile, native: true).fetch(row)
      output << scalar_value_rowbinary(profile, value)
      output << nullable_value_rowbinary(profile, row == 3 ? nil : value)
    end
  end
  output
end

def expected_profile_rowbinary(profile, selected_rows, nullable:, values: values_for(profile, native: false), null_index: 3)
  output = +"".b
  selected_rows.each do |row|
    output << [KEYS.fetch(row)].pack("Q<")
    value = nullable && row == null_index ? nil : values.fetch(row)
    output << (nullable ? nullable_value_rowbinary(profile, value) : scalar_value_rowbinary(profile, value))
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
  default_compression_codec = 'LZ4',
  string_serialization_version = 'with_size_stream',
  nullable_serialization_version = 'basic',
  serialization_info_version = 'with_types',
  propagate_types_serialization_versions_to_nested_types = 1
SQL

def native_table_ddl(table, columns)
  "CREATE TABLE default.#{table}\n(\n    #{columns.join(",\n    ")}\n)\nENGINE = MergeTree\nORDER BY pk\nSETTINGS\n#{STOCK_SETTINGS};"
end

def assert_binary(actual, expected, label)
  return if actual.b == expected.b

  shared = [actual.bytesize, expected.bytesize].min
  mismatch = (0...shared).find { |index| actual.getbyte(index) != expected.getbyte(index) } || shared
  wanted = mismatch < expected.bytesize ? expected.getbyte(mismatch).to_s(16).rjust(2, "0") : "<eof>"
  observed = mismatch < actual.bytesize ? actual.getbyte(mismatch).to_s(16).rjust(2, "0") : "<eof>"
  fail!("#{label} differs: expected #{expected.bytesize} bytes, observed #{actual.bytesize}; byte #{mismatch}: expected #{wanted}, got #{observed}")
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

class W168StockQueries
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
      stdin_data: input, chdir: ENV.fetch("W168_REPO_ROOT"))
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
    "git", "-C", SOURCE_ROOT, "rev-parse", "HEAD", chdir: ENV.fetch("W168_REPO_ROOT")
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

def create_native_source(queries, root)
  store = File.join(root, "stores", "native-stock")
  make_dir(store)
  table = "w168_simple_aggregate_stock"
  queries.call("create-native-stock", store, native_table_ddl(table, native_columns))
  queries.call("insert-native-stock-rowbinary", store,
    "INSERT INTO default.#{table} FORMAT RowBinary", input: native_rowbinary_input)

  columns = queries.call("native-stock-columns", store,
    "SELECT name, type, toString(position) FROM system.columns " \
    "WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  require_true(columns == expected_native_columns, "native stock exact function/carrier/shape declarations differ")
  check = queries.call("check-native-stock", store,
    "CHECK TABLE default.#{table} FORMAT TabSeparated")
  require_true(check == "all_1_1_0\t1\t\n", "native stock CHECK TABLE raw fields differ: #{check.inspect}")
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
    assert_binary(actual, expected_native_rowbinary(selected), "native stock #{label} RowBinary")
  end

  typed_header = queries.call("native-all-profiles-binary-type-header", store,
    "SELECT #{projection} FROM default.#{table} LIMIT 0 FORMAT RowBinaryWithNamesAndTypes",
    settings: {"output_format_binary_encode_types_in_binary_format" => "1"})
  assert_binary(typed_header, expected_binary_type_header, "native 33-column literal binary type header")

  local_parent = File.join(root, "native-stock-part")
  make_dir(local_parent)
  local_part = File.join(local_parent, "all_1_1_0")
  require_true(!File.exist?(local_part) && !File.symlink?(local_part), "refusing to overwrite copied native source part")
  FileUtils.cp_r(source_part, local_part)
  puts "PASS W168 stock source: #{PROFILES.size} exact profiles × scalar/outer Nullable; explicit String-size/BASIC Nullable/with_types; Wide/LZ4; literal full/middle/empty RowBinary"
  {store: store, table: table, part: local_part}
end

def run_crystal_spec(crystal, root, stock_part)
  evidence = File.join(root, "results", "crystal")
  base = File.join(evidence, "stock-reader-and-library-writer-spec")
  env = {
    "CRYSTAL_CACHE_DIR" => ENV.fetch("CRYSTAL_CACHE_DIR"),
    "TZ" => "UTC",
    "W168_SIMPLE_AGGREGATE_STOCK_WIDE_PART" => stock_part,
    "W168_PART_ROOT" => File.join(root, "library-parts"),
  }
  stdout, stderr, status = Open3.capture3(env, crystal, "spec", "--single-module", "--threads", "1",
    "--error-trace", "--link-flags=-fuse-ld=ld", "spec/simple_aggregate_w168_stock_reader_spec.cr",
    chdir: ENV.fetch("W168_REPO_ROOT"))
  write_new(base + ".stdout", stdout.b)
  write_new(base + ".stderr", stderr.b)
  fail!("Crystal W168 stock-reader/writer spec failed: #{stderr}") unless status.success?
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

def attach_part(queries, root, source_part, profile, nullable:, label:, values:, null_index: 3, declared_function: profile.function)
  source_part = real_directory_beneath!(source_part, root, "library-authored complete part #{label}")
  files = part_files(source_part)
  require_true(files.include?("columns.txt") && files.include?("count.txt"), "library part metadata roster is incomplete for #{label}")
  store = File.join(root, "stores", "writers")
  Dir.mkdir(store) unless Dir.exist?(store)
  table = "w168_#{label.gsub(/[^a-z0-9_]/, "_")}"
  type = profile.type(nullable: nullable, function: declared_function)
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
  check = queries.call("check-#{label}", store, "CHECK TABLE default.#{table} FORMAT TabSeparated")
  require_true(check == "all_1_1_0\t1\t\n", "stock CHECK TABLE raw fields differ for #{label}: #{check.inspect}")
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
    expected = expected_profile_rowbinary(profile, selected, nullable: nullable, values: values, null_index: null_index)
    assert_binary(actual, expected, "library part #{label} #{window}")
    actual_full = actual if window == "full"
  end
  puts "PASS W168 library→stock #{label}: ATTACH/CHECK, exact type/rows/marks/Wide, literal full/middle/empty RowBinary"
  {table: table, store: store, type: type, full: actual_full, observed_type: observed_type}
end

def verify_type_mutant(queries, root, part_root)
  profile = PROFILES.find { |item| item.function == "min" && item.carrier == "String" }
  source_part = profile.part_path(part_root, nullable: false)
  mutant_parent = File.join(root, "mutants")
  make_dir(mutant_parent)
  mutant = File.join(mutant_parent, "min-string-declared-max")
  FileUtils.cp_r(source_part, mutant)
  columns_path = File.join(mutant, "columns.txt")
  before = File.binread(columns_path)
  original_type = "SimpleAggregateFunction(min, String)"
  mutant_type = "SimpleAggregateFunction(max, String)"
  require_true(before.scan(original_type).length == 1, "minimum String fixture does not contain exactly one canonical declaration")
  after = before.sub(original_type, mutant_type)
  File.binwrite(columns_path, after)
  require_true(before.bytesize == after.bytesize, "min→max nominal mutant changed metadata size")
  require_true(part_files(source_part) == part_files(mutant), "min→max nominal mutant changed the complete-part file roster")
  changed = part_files(source_part).select do |relative|
    File.binread(File.join(source_part, relative)) != File.binread(File.join(mutant, relative))
  end
  require_true(changed == ["columns.txt"], "nominal mutant changed more than columns.txt: #{changed.inspect}")

  attached = attach_part(queries, root, mutant, profile, nullable: false,
    label: "min_string_declared_max", values: LIBRARY_STRING_VALUES, declared_function: "max")
  original_bytes = expected_profile_rowbinary(profile, (0...KEYS.size).to_a,
    nullable: false, values: LIBRARY_STRING_VALUES)
  assert_binary(attached.fetch(:full), original_bytes, "min→max nominal mutant raw-value preservation")
  require_true(attached.fetch(:observed_type) == "pk\tUInt64\nv\t#{mutant_type}\n",
    "stock reported type did not retain max declaration")
  write_new(File.join(queries.evidence, "wrong-function-oracle-rejection.txt"), [
    "expected_type=#{original_type}", "mutant_type=#{mutant_type}",
    "stock_attach_and_check=passed", "all_non_columns_part_files_unchanged=true",
    "raw_rowbinary_unchanged=true", "rejection_gate=unchanged literal exact-type oracle",
  ].join("\n") + "\n")
  puts "PASS W168 nominal mutant: stock max ATTACH/CHECK succeeds; unchanged min exact-type oracle rejects same-storage identity drift"
end

def verify_value_mutant(queries, root, part_root)
  profile = PROFILES.find { |item| item.function == "min" && item.carrier == "String" }
  mutant = File.join(part_root, "scalar_min_string_value_mutant", "all_1_1_0")
  require_true(File.directory?(mutant) && File.basename(mutant) == "all_1_1_0",
    "library spec omitted canonical min/String value-mutant part")
  mutant_values = LIBRARY_STRING_VALUES.dup
  mutant_values[0] = "M".b
  attached = attach_part(queries, root, mutant, profile, nullable: false,
    label: "min_string_value_mutant", values: mutant_values)
  actual = attached.fetch(:full)
  original = expected_profile_rowbinary(profile, (0...KEYS.size).to_a,
    nullable: false, values: LIBRARY_STRING_VALUES)
  mutant_expected = expected_profile_rowbinary(profile, (0...KEYS.size).to_a,
    nullable: false, values: mutant_values)
  assert_binary(actual, mutant_expected, "min/String value mutant intended result")
  require_true(actual != original, "unchanged min/String exact-value oracle unexpectedly accepted changed payload")
  write_new(File.join(queries.evidence, "wrong-value-oracle-rejection.txt"), [
    "expected_first_value_hex=#{LIBRARY_STRING_VALUES.fetch(0).unpack1("H*")}",
    "mutant_first_value_hex=#{mutant_values.fetch(0).unpack1("H*")}",
    "stock_attach_and_check=passed", "rejection_gate=unchanged literal exact raw RowBinary oracle",
  ].join("\n") + "\n")
  puts "PASS W168 value mutant: stock CHECK succeeds and unchanged exact raw-value oracle rejects one String payload"
end

def verify_nullable_map_mutant(queries, root, part_root)
  profile = PROFILES.find { |item| item.function == "min" && item.carrier == "FixedString(3)" }
  mutant = File.join(part_root, "nullable_min_fixed3_nullmap_mutant", "all_1_1_0")
  require_true(File.directory?(mutant) && File.basename(mutant) == "all_1_1_0",
    "library spec omitted canonical Nullable(FixedString(3)) null-map mutant part")
  original_values = fixed_library_values(3)
  mutant_values = original_values.dup
  attached = attach_part(queries, root, mutant, profile, nullable: true,
    label: "nullable_min_fixed3_nullmap_mutant", values: mutant_values, null_index: 1)
  original = expected_profile_rowbinary(profile, (0...KEYS.size).to_a,
    nullable: true, values: original_values, null_index: 3)
  mutant_expected = expected_profile_rowbinary(profile, (0...KEYS.size).to_a,
    nullable: true, values: mutant_values, null_index: 1)
  assert_binary(attached.fetch(:full), mutant_expected, "Nullable(FixedString(3)) null-map mutant intended result")
  require_true(attached.fetch(:full) != original, "unchanged nullable oracle unexpectedly accepted moved NULL row")
  write_new(File.join(queries.evidence, "wrong-nullmap-oracle-rejection.txt"), [
    "expected_null_row=3", "mutant_null_row=1", "stock_attach_and_check=passed",
    "rejection_gate=unchanged literal null positions plus exact RowBinary",
  ].join("\n") + "\n")
  puts "PASS W168 nullable mutant: stock CHECK succeeds and unchanged null-position oracle rejects moved NULL"
end

def main
  require_true(ENV["W168_EXECUTE_AS_ROOT"] == "YES",
    "set W168_EXECUTE_AS_ROOT=YES only under root-owned resource guard")
  require_true(PROFILES.size == EXPECTED_SCALAR_PROFILE_COUNT,
    "literal W168 scalar profile count differs: #{PROFILES.size}")
  require_true(PROFILES.size * 2 == EXPECTED_PART_COUNT,
    "literal W168 scalar plus nullable part count differs")
  require_true(selected_columns.size == EXPECTED_SELECTED_COLUMN_COUNT,
    "literal W168 selected column count differs: #{selected_columns.size}")
  root = ENV.fetch("W168_PAIR_ROOT")
  require_true(root.start_with?(ROOT_PREFIX) && File.realpath(root) == root && !File.symlink?(root),
    "W168 output root is absent, unsafe, or noncanonical")
  children = Dir.children(root).sort
  require_true((children - ["recheck.log"]) == ["crystal-cache"],
    "W168 root must be fresh with only its isolated cache and optional wrapper log")
  log = File.join(root, "recheck.log")
  require_true(!File.symlink?(log) && (!File.exist?(log) || File.file?(log)),
    "W168 wrapper log is not a regular owned output")

  ENV["W168_REPO_ROOT"] = File.realpath(File.expand_path("..", __dir__))
  %w[results stores].each { |name| make_dir(File.join(root, name)) }
  make_dir(File.join(root, "results", "crystal"))
  binary = ENV.fetch("CLICKHOUSE_BIN", DEFAULT_BINARY)
  queries = W168StockQueries.new(binary, root)
  verify_pins(binary, queries, root)
  native = create_native_source(queries, root)
  part_root = File.join(root, "library-parts")
  make_dir(part_root)
  run_crystal_spec(ENV.fetch("CRYSTAL_BIN"), root, native.fetch(:part))

  PROFILES.each do |profile|
    values = values_for(profile, native: false)
    [[false, values], [true, values]].each do |nullable, profile_values|
      source_part = profile.part_path(part_root, nullable: nullable)
      require_true(File.directory?(source_part), "missing canonical complete library part #{source_part}")
      attach_part(queries, root, source_part, profile, nullable: nullable,
        label: profile.table_label(nullable: nullable), values: profile_values)
    end
  end

  verify_type_mutant(queries, root, part_root)
  verify_value_mutant(queries, root, part_root)
  verify_nullable_map_mutant(queries, root, part_root)
  write_new(File.join(queries.evidence, "summary.txt"), <<~TEXT)
    PASS literal source matrix: #{PROFILES.size} accepted scalar profiles and #{PROFILES.size} outer Nullable profiles
    PASS explicit String WITH_SIZE_STREAM, Nullable BASIC, serialization_info_version with_types, and nested propagation
    PASS stock-authored Wide/LZ4 part with exact 33-column schema and independent full/middle/empty RowBinary
    PASS opt-in Crystal spec executed stock text typed readers and public full-part writers
    PASS #{EXPECTED_PART_COUNT} independently library-authored complete parts ATTACHed and CHECK TABLE-validated by stock
    PASS exact canonical function/carrier/outer shape, six rows, four marks and Wide layout per attached part
    PASS literal full/middle/empty RowBinary comparisons for every scalar and outer Nullable profile
    PASS min→max metadata-only nominal mutant remains stock-CHECK-valid and is rejected by unchanged exact-type oracle
    PASS value mutant remains stock-CHECK-valid and is rejected by unchanged literal value oracle
    PASS nullable null-map mutant remains stock-CHECK-valid and is rejected by unchanged literal NULL-position oracle
    runtime=#{VERSION} build=#{BUILD_HASH} sha256=#{EXECUTABLE_SHA256}
    source_reference=#{SOURCE_ROOT}@#{SOURCE_REVISION}
    source_is_not_asserted_to_build_runtime=true
  TEXT
  puts "PASS W168 independent stock/library text SimpleAggregateFunction oracle"
end

main
