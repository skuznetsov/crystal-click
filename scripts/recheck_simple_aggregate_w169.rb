#!/usr/bin/env ruby
# Independent ClickHouse stock/library oracle for the bounded W169 Decimal
# construction and Wide-part slice. Roster, coefficient literals, descriptors,
# RowBinary inputs and expected outputs are authored independently from Crystal.
require "digest"
require "fileutils"
require "find"
require "json"
require "open3"

STDOUT.sync = true

VERSION = "26.10.1.1201"
BUILD_HASH = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
SOURCE_ROOT = "/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1"
SOURCE_REVISION = "e9b645ed83ad3c07b64f09fbd014e8f770d8691b"
ROOT_PREFIX = "/private/tmp/crystal-click-w169."
DEFAULT_BINARY = "/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped"

# Exact pinned source spellings; aliases are intentionally not normalized.
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

PRECISIONS = [1, 9, 10, 18, 19, 38, 39, 76].freeze
KEYS = [11, 22, 33, 44, 55, 66].freeze
NULL_ROW = 3

Profile = Struct.new(:function, :function_suffix, :precision, :scale, :nullable, keyword_init: true) do
  def width_bits
    case precision
    when 1..9 then 32
    when 10..18 then 64
    when 19..38 then 128
    when 39..76 then 256
    else
      raise "W169 precision outside Decimal32/64/128/256"
    end
  end

  def decimal_type
    "Decimal(#{precision}, #{scale})"
  end

  def type(function: self.function, precision: self.precision, scale: self.scale)
    inner = "SimpleAggregateFunction(#{function}, Decimal(#{precision}, #{scale}))"
    nullable ? "Nullable(#{inner})" : inner
  end

  def id
    "#{function_suffix}_decimal#{width_bits}_p#{precision}_s#{scale}"
  end

  def column_name
    "#{nullable ? "n" : "s"}_#{id}"
  end

  def part_label
    "#{nullable ? "nullable" : "scalar"}_#{id}"
  end

  def part_path(root)
    File.join(root, part_label, "all_1_1_0")
  end
end

PRECISION_SCALES = PRECISIONS.flat_map do |precision|
  [0, [3, precision].min, precision].uniq.map { |scale| [precision, scale] }
end.freeze

BASE_PROFILES = FUNCTIONS.flat_map do |function, function_suffix|
  PRECISION_SCALES.map do |precision, scale|
    Profile.new(function: function, function_suffix: function_suffix,
      precision: precision, scale: scale, nullable: false)
  end
end.freeze

CASES = BASE_PROFILES.flat_map do |profile|
  [profile, Profile.new(function: profile.function, function_suffix: profile.function_suffix,
    precision: profile.precision, scale: profile.scale, nullable: true)]
end.freeze

def source_eligible?(profile)
  case profile.function
  when "any", "anyLast", "min", "max", "sumWithOverflow"
    true
  when "sum"
    profile.precision >= 19
  when "groupBitAnd", "groupBitOr", "groupBitXor"
    false
  else
    raise "unlisted W169 canonical function #{profile.function.inspect}"
  end
end

ACCEPTED = CASES.select { |profile| source_eligible?(profile) }.freeze
REJECTED = CASES.reject { |profile| source_eligible?(profile) }.freeze

class W169Failure < StandardError; end

def fail!(message)
  raise W169Failure, "W169 independent stock/literal oracle: #{message}"
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
  bytes = value.b
  varuint(bytes.bytesize) + bytes
end

def decimal_tag(width_bits)
  case width_bits
  when 32 then 0x19
  when 64 then 0x1a
  when 128 then 0x1b
  when 256 then 0x1c
  else
    fail!("unrecognized Decimal wire width #{width_bits}")
  end
end

def aggregate_descriptor(profile)
  descriptor = "\x2e".b + binary_string(profile.function) + "\x00\x01".b
  descriptor << [decimal_tag(profile.width_bits), profile.precision, profile.scale].pack("C3")
  profile.nullable ? "\x23".b + descriptor : descriptor
end

def selected_profiles
  ACCEPTED
end

def selected_columns
  ["pk"] + selected_profiles.map(&:column_name)
end

def expected_binary_type_header
  descriptors = ["\x04".b] + selected_profiles.map { |profile| aggregate_descriptor(profile) }
  varuint(selected_columns.size) + selected_columns.map { |name| binary_string(name) }.join.b + descriptors.join.b
end

def signed_256(words)
  unsigned = words.each_with_index.reduce(0) do |value, (word, index)|
    value | (word << (64 * index))
  end
  unsigned >= (1 << 255) ? unsigned - (1 << 256) : unsigned
end

# Independently authored Ruby literals match the Crystal writer and stock
# RowBinary fixture contracts exactly; the two paths intentionally reorder
# extrema and asymmetric patterns so neither is derived from the other.
NATIVE_VALUES = {
  32 => [0, -1, 0x7fffffff, -0x80000000, 0x12345671, -0x1234567f].freeze,
  64 => [0, -1, 0x7fffffffffffffff, -0x8000000000000000,
    0x123456789abcdef1, -0x123456789abcdeff].freeze,
  128 => [0, -1, 0x7fffffffffffffffffffffffffffffff,
    -0x80000000000000000000000000000000,
    0x0123456789abcdef0123456789abcdef,
    -0x0123456789abcdef0123456789abcdf1].freeze,
  256 => [
    signed_256([0, 0, 0, 0]),
    signed_256([0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff]),
    signed_256([0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x7fffffffffffffff]),
    signed_256([0, 0, 0, 0x8000000000000000]),
    signed_256([0xfedcba9876543211, 0x0123456789abcdef, 0x13579bdf2468ace0, 0x0123456789abcdef]),
    signed_256([0x1020304050607081, 0x23456789abcdef01, 0x3579bdf02468ace1, 0xfedcba9876543210]),
  ].freeze,
}.freeze

LIBRARY_VALUES = {
  32 => [0, -1, -0x80000000, 0x7fffffff, -0x1234567f, 0x12345671].freeze,
  64 => [0, -1, -0x8000000000000000, 0x7fffffffffffffff,
    -0x123456789abcdeff, 0x123456789abcdef1].freeze,
  128 => [0, -1, -0x80000000000000000000000000000000,
    0x7fffffffffffffffffffffffffffffff,
    -0x0123456789abcdef0123456789abcdf1,
    0x0123456789abcdef0123456789abcdef].freeze,
  256 => [
    signed_256([0, 0, 0, 0]),
    signed_256([0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff]),
    signed_256([0, 0, 0, 0x8000000000000000]),
    signed_256([0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0x7fffffffffffffff]),
    signed_256([0x1020304050607081, 0x23456789abcdef01, 0x3579bdf02468ace1, 0xfedcba9876543210]),
    signed_256([0xfedcba9876543211, 0x0123456789abcdef, 0x13579bdf2468ace0, 0x0123456789abcdef]),
  ].freeze,
}.freeze

def values_for(profile, native:)
  (native ? NATIVE_VALUES : LIBRARY_VALUES).fetch(profile.width_bits).dup
end

def coefficient_bytes(value, width_bits)
  width = width_bits / 8
  unsigned = value & ((1 << width_bits) - 1)
  Array.new(width) { |index| (unsigned >> (8 * index)) & 0xff }.pack("C*").b
end

def scalar_rowbinary(profile, value)
  coefficient_bytes(value, profile.width_bits)
end

def nullable_rowbinary(profile, value)
  value.nil? ? "\x01".b : "\x00".b + scalar_rowbinary(profile, value)
end

def native_columns
  ["pk UInt64"] + selected_profiles.map { |profile| "#{profile.column_name} #{profile.type}" }
end

def expected_native_columns
  rows = [["pk", "UInt64", 1]]
  selected_profiles.each_with_index do |profile, index|
    rows << [profile.column_name, profile.type, index + 2]
  end
  rows.map { |name, type, position| "#{name}\t#{type}\t#{position}" }.join("\n") + "\n"
end

def native_rowbinary_input
  output = +"".b
  KEYS.each_with_index do |key, row|
    output << [key].pack("Q<")
    selected_profiles.each do |profile|
      value = values_for(profile, native: true).fetch(row)
      output << (profile.nullable && row == NULL_ROW ? nullable_rowbinary(profile, nil) :
        (profile.nullable ? nullable_rowbinary(profile, value) : scalar_rowbinary(profile, value)))
    end
  end
  output
end

def expected_native_rowbinary(selected_rows)
  output = +"".b
  selected_rows.each do |row|
    output << [KEYS.fetch(row)].pack("Q<")
    selected_profiles.each do |profile|
      value = values_for(profile, native: true).fetch(row)
      output << (profile.nullable && row == NULL_ROW ? nullable_rowbinary(profile, nil) :
        (profile.nullable ? nullable_rowbinary(profile, value) : scalar_rowbinary(profile, value)))
    end
  end
  output
end

def expected_profile_rowbinary(profile, selected_rows, values: values_for(profile, native: false), null_row: NULL_ROW)
  output = +"".b
  selected_rows.each do |row|
    output << [KEYS.fetch(row)].pack("Q<")
    value = profile.nullable && row == null_row ? nil : values.fetch(row)
    output << (profile.nullable ? nullable_rowbinary(profile, value) : scalar_rowbinary(profile, value))
  end
  output
end

def verify_immutable_original_oracle(profile, attached)
  expected_type = "pk\tUInt64\nv\t#{profile.type}\n"
  require_true(attached.fetch(:observed_type) == expected_type,
    "original exact canonical type oracle rejected #{profile.type}: #{attached.fetch(:observed_type).inspect}")
  expected = expected_profile_rowbinary(profile, (0...KEYS.size).to_a,
    values: values_for(profile, native: false))
  assert_binary(attached.fetch(:full), expected,
    "original literal raw coefficient RowBinary oracle for #{profile.type}")
  true
end

def require_immutable_original_rejection(profile, attached, label)
  begin
    verify_immutable_original_oracle(profile, attached)
  rescue W169Failure => error
    return error.message
  end
  fail!("unchanged immutable original type/literal oracle accepted CHECK-valid mutant #{label}")
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

class W169StockQueries
  attr_reader :evidence

  def initialize(binary, root)
    @binary = binary
    @evidence = File.join(root, "results", "ruby-oracle")
    make_dir(@evidence)
    @sequence = 0
  end

  def record_process(label, args, input: nil, chdir: ENV.fetch("W169_REPO_ROOT"))
    @sequence += 1
    safe_label = label.gsub(/[^A-Za-z0-9_.-]/, "_")
    base = File.join(@evidence, format("%05d-%s", @sequence, safe_label))
    write_new(base + ".argv.json", JSON.pretty_generate({"argv" => args, "stdin_bytes" => input && input.bytesize,
      "stdin_sha256" => input && Digest::SHA256.hexdigest(input)}) + "\n")
    write_new(base + ".stdin.bin", input.b) if input
    stdout, stderr, status = Open3.capture3({"TZ" => "UTC"}, *args, stdin_data: input, chdir: chdir)
    write_new(base + ".stdout", stdout.b)
    write_new(base + ".stderr", stderr.b)
    write_new(base + ".status.json", JSON.pretty_generate({
      "success" => status.success?, "exitstatus" => status.exitstatus,
      "signaled" => status.signaled?, "termsig" => status.termsig,
    }) + "\n")
    [base, stdout.b, stderr.b, status]
  end

  def call(label, store, sql, input: nil, settings: {})
    write_sql_base = @sequence + 1
    safe_label = label.gsub(/[^A-Za-z0-9_.-]/, "_")
    sql_path = File.join(@evidence, format("%05d-%s.sql", write_sql_base, safe_label))
    write_new(sql_path, sql + "\n")
    args = [
      @binary, "local", "--path", store, "--session_timezone=UTC",
      "--print_pretty_type_names=0", "--output_format_json_quote_64bit_integers=0",
      "--max_threads=1", "--max_insert_threads=1", "--max_memory_usage=536870912",
      "--query", sql,
    ]
    settings.each { |name, value| args << "--#{name}=#{value}" }
    _base, stdout, stderr, status = record_process(label, args, input: input)
    fail!("stock query failed at #{label}: #{stderr}\nSQL=#{sql}") unless status.success?
    stdout
  end
end

def verify_pins(binary, queries, root)
  require_true(File.file?(binary) && File.executable?(binary) && !File.symlink?(binary),
    "pinned ClickHouse executable is absent, non-executable, or a symlink")
  digest = Digest::SHA256.file(binary).hexdigest
  require_true(digest == EXECUTABLE_SHA256, "ClickHouse executable SHA-256 differs: #{digest}")

  source_args = ["git", "-C", SOURCE_ROOT, "rev-parse", "HEAD"]
  _base, source_stdout, source_stderr, source_status = queries.record_process("source-revision-pin", source_args)
  require_true(source_status.success? && source_stdout.strip == SOURCE_REVISION,
    "pinned source revision differs: #{source_stdout.strip.inspect} #{source_stderr.inspect}")

  identity_store = File.join(root, "stores", "identity")
  make_dir(identity_store)
  version = queries.call("runtime-version", identity_store, "SELECT version() FORMAT TSVRaw").strip
  require_true(version == VERSION, "ClickHouse version differs: #{version.inspect}")
  build = queries.call("runtime-build", identity_store,
    "SELECT concat(name, '=', value) FROM system.build_options " \
    "WHERE name = 'VERSION_GITHASH' FORMAT TSVRaw")
  require_true(build == "VERSION_GITHASH=#{BUILD_HASH}\n",
    "ClickHouse build hash differs: #{build.inspect}")

  write_new(File.join(queries.evidence, "pins.txt"), [
    "runtime_version=#{VERSION}", "runtime_sha256=#{digest}",
    "runtime_build_hash=#{BUILD_HASH}", "source_reference=#{SOURCE_ROOT}@#{SOURCE_REVISION}",
    "source_is_not_asserted_to_build_runtime=true",
  ].join("\n") + "\n")
end

def write_literal_roster_manifest(path)
  header = [
    "function", "precision", "scale", "width_bits", "nullable", "eligible",
    "exact_type", "part_label", "native_signed_coefficients", "library_signed_coefficients",
    "primary_key_literals", "outer_null_row",
  ]
  lines = [header.join("\t")]
  CASES.each do |profile|
    lines << [
      profile.function, profile.precision, profile.scale, profile.width_bits,
      profile.nullable, source_eligible?(profile), profile.type, profile.part_label,
      values_for(profile, native: true).join(","), values_for(profile, native: false).join(","),
      KEYS.join(","),
      profile.nullable ? NULL_ROW : "none",
    ].join("\t")
  end
  write_new(path, lines.join("\n") + "\n")
end

def create_native_source(queries, root)
  store = File.join(root, "stores", "native-stock")
  make_dir(store)
  table = "w169_simple_aggregate_decimal_stock"
  queries.call("create-native-stock", store, native_table_ddl(table, native_columns))
  queries.call("insert-native-stock-rowbinary", store,
    "INSERT INTO default.#{table} FORMAT RowBinary", input: native_rowbinary_input)

  columns = queries.call("native-stock-columns", store,
    "SELECT name, type, toString(position) FROM system.columns " \
    "WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  require_true(columns == expected_native_columns,
    "native stock exact canonical function/P/S/carrier/shape declarations differ")
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
    ["middle", " WHERE pk >= 33 AND pk <= 44", [2, 3]],
    ["empty", " WHERE pk = 0", []],
  ].each do |label, where, selected|
    actual = queries.call("native-stock-rowbinary-#{label}", store,
      "SELECT #{projection} FROM default.#{table}#{where} ORDER BY pk FORMAT RowBinary")
    assert_binary(actual, expected_native_rowbinary(selected), "native stock #{label} RowBinary")
  end
  typed_header = queries.call("native-all-profiles-binary-type-header", store,
    "SELECT #{projection} FROM default.#{table} LIMIT 0 FORMAT RowBinaryWithNamesAndTypes",
    settings: {"output_format_binary_encode_types_in_binary_format" => "1"})
  assert_binary(typed_header, expected_binary_type_header, "native 255-column literal binary type header")

  local_parent = File.join(root, "native-stock-part")
  make_dir(local_parent)
  local_part = File.join(local_parent, "all_1_1_0")
  require_true(!File.exist?(local_part) && !File.symlink?(local_part), "refusing to overwrite copied native source part")
  FileUtils.cp_r(source_part, local_part)
  puts "PASS W169 native source: #{selected_profiles.size} scalar/outer-Nullable profiles; exact binary descriptors; Wide/LZ4; literal full/middle/empty RowBinary"
  {store: store, table: table, part: local_part, columns: columns}
end

def run_crystal_spec(crystal, root, stock_part, part_root)
  evidence = File.join(root, "results", "crystal")
  base = File.join(evidence, "wide-part-simple-aggregate-decimal-native-spec")
  args = [crystal, "spec", "--single-module", "--threads", "1", "--error-trace",
    "--link-flags=-fuse-ld=ld", "spec/wide_part_simple_aggregate_decimal_w169_native_spec.cr"]
  env = {
    "CRYSTAL_CACHE_DIR" => ENV.fetch("CRYSTAL_CACHE_DIR"),
    "TZ" => "UTC",
    "W169_SIMPLE_AGGREGATE_STOCK_WIDE_PART" => stock_part,
    "W169_PART_ROOT" => part_root,
  }
  write_new(base + ".argv.json", JSON.pretty_generate({"argv" => args, "environment" => env}) + "\n")
  stdout, stderr, status = Open3.capture3(env, *args, chdir: ENV.fetch("W169_REPO_ROOT"))
  write_new(base + ".stdout", stdout.b)
  write_new(base + ".stderr", stderr.b)
  write_new(base + ".status.json", JSON.pretty_generate({
    "success" => status.success?, "exitstatus" => status.exitstatus,
    "signaled" => status.signaled?, "termsig" => status.termsig,
  }) + "\n")
  fail!("Crystal W169 qualification spec failed: #{stderr}") unless status.success?
  summaries = stdout.lines.map(&:strip).select { |line| line.match?(/\A\d+ examples?,/) }
  require_true(summaries == ["2 examples, 0 failures, 0 errors, 0 pending"],
    "W169 Crystal spec did not execute exactly two passing examples: #{summaries.inspect}")
  require_true(stdout.include?("W169 construction matrix: cases=414 accepted=254 rejected=160 native_columns=255"),
    "Crystal W169 case roster/count line is missing")
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

def attach_part(queries, root, part_root, source_part, profile, label:, declared_type: profile.type,
  values: values_for(profile, native: false), verify_windows: true)
  source_part = real_directory_beneath!(source_part, part_root, "library-authored complete part #{label}")
  files = part_files(source_part)
  require_true(files.include?("columns.txt") && files.include?("count.txt"), "library part metadata roster incomplete for #{label}")
  store = File.join(root, "stores", "writers")
  table = "w169_#{label.gsub(/[^a-z0-9_]/, "_")}"
  queries.call("create-#{label}", store, native_table_ddl(table, ["pk UInt64", "v #{declared_type}"]))
  data_path = queries.call("data-path-#{label}", store,
    "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  require_true(!data_path.empty?, "no native table path for #{table}")
  data_path = real_directory_beneath!(data_path, store, "native table path for #{table}")
  detached = File.join(data_path, "detached")
  if File.exist?(detached) || File.symlink?(detached)
    detached = real_directory_beneath!(detached, data_path, "native detached directory for #{table}")
    require_true(Dir.empty?(detached), "refusing to reuse nonempty detached directory #{detached}")
  else
    Dir.mkdir(detached, 0o700)
  end
  detached_part = File.join(detached, "all_1_1_0")
  require_true(!File.exist?(detached_part) && !File.symlink?(detached_part), "refusing to overwrite detached part #{detached_part}")
  FileUtils.cp_r(source_part, detached_part)
  queries.call("attach-#{label}", store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  check = queries.call("check-#{label}", store, "CHECK TABLE default.#{table} FORMAT TabSeparated")
  require_true(check == "all_1_1_0\t1\t\n", "stock CHECK TABLE raw fields differ for #{label}: #{check.inspect}")
  observed_type = queries.call("type-#{label}", store,
    "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  expected_type = "pk\tUInt64\nv\t#{declared_type}\n"
  require_true(observed_type == expected_type, "attached exact canonical type differs for #{label}: #{observed_type.inspect}")
  part_info = queries.call("part-info-#{label}", store,
    "SELECT name, toString(rows), toString(marks), part_type FROM system.parts " \
    "WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw")
  require_true(part_info == "all_1_1_0\t6\t4\tWide\n", "attached part metadata differs for #{label}: #{part_info.inspect}")

  full = nil
  windows = verify_windows ? [
    ["full", "", (0...KEYS.size).to_a],
    ["middle", " WHERE pk >= 33 AND pk <= 44", [2, 3]],
    ["empty", " WHERE pk = 0", []],
  ] : [["full", "", (0...KEYS.size).to_a]]
  windows.each do |window, where, selected|
    actual = queries.call("rowbinary-#{label}-#{window}", store,
      "SELECT pk, v FROM default.#{table}#{where} ORDER BY pk FORMAT RowBinary")
    expected = expected_profile_rowbinary(profile, selected, values: values)
    assert_binary(actual, expected, "library part #{label} #{window}")
    full = actual if window == "full"
  end
  {table: table, store: store, type: declared_type, full: full, observed_type: observed_type}
end

def verify_metadata_mutant(queries, root, part_root, profile, label:, new_precision: profile.precision, new_scale: profile.scale)
  source_part = profile.part_path(part_root)
  mutant_root = File.join(root, "mutants", label)
  FileUtils.mkdir_p(File.dirname(mutant_root))
  require_true(!File.exist?(mutant_root) && !File.symlink?(mutant_root), "refusing to overwrite mutant #{mutant_root}")
  FileUtils.cp_r(source_part, mutant_root)
  columns_path = File.join(mutant_root, "columns.txt")
  before = File.binread(columns_path)
  original_type = profile.type
  mutant_type = profile.type(precision: new_precision, scale: new_scale)
  require_true(before.scan(original_type).length == 1, "#{label} source lacks its one exact original declaration")
  after = before.sub(original_type, mutant_type)
  File.binwrite(columns_path, after)
  require_true(before.bytesize == after.bytesize, "#{label} same-width metadata mutant changed declaration length")
  require_true(part_files(source_part) == part_files(mutant_root), "#{label} changed complete-part file roster")
  changed = part_files(source_part).select do |relative|
    File.binread(File.join(source_part, relative)) != File.binread(File.join(mutant_root, relative))
  end
  require_true(changed == ["columns.txt"], "#{label} changed files other than columns.txt: #{changed.inspect}")

  attached = attach_part(queries, root, root, mutant_root, profile, label: label,
    declared_type: mutant_type, verify_windows: false)
  require_true(attached.fetch(:observed_type) == "pk\tUInt64\nv\t#{mutant_type}\n",
    "stock did not retain #{label} exact declared type")
  require_true(mutant_type != original_type, "#{label} mutant was not distinguishable by exact original type oracle")
  original_rejection = require_immutable_original_rejection(profile, attached, label)
  require_true(original_rejection.include?("original exact canonical type oracle"),
    "#{label} was not rejected by the original exact type comparison: #{original_rejection}")
  write_new(File.join(queries.evidence, "#{label}-oracle-rejection.txt"), [
    "original_type=#{original_type}", "mutant_type=#{mutant_type}",
    "stock_attach_and_check=passed", "all_non_columns_part_files_unchanged=true",
    "raw_rowbinary_matches_original_literals=true", "rejection_gate=unchanged exact type oracle",
    "original_oracle_failure=#{original_rejection.lines.first.strip}",
  ].join("\n") + "\n")
  puts "PASS W169 #{label}: stock CHECK accepts same-width metadata mutant; original exact type oracle rejects"
end

def verify_coefficient_mutant(queries, root, part_root)
  profile = ACCEPTED.find do |candidate|
    candidate.function == "any" && candidate.precision == 19 && candidate.scale == 0 && !candidate.nullable
  end
  require_true(profile, "source law omitted the Decimal(19, 0) coefficient discriminator")
  mutant = File.join(part_root, "mutants", "coefficient_lsb", "all_1_1_0")
  values = values_for(profile, native: false).dup
  require_true(values[0] == 0, "coefficient mutant fixture must begin at literal raw zero")
  values[0] = 1
  attached = attach_part(queries, root, part_root, mutant, profile,
    label: "coefficient_lsb_zero_to_one", values: values, verify_windows: false)
  changed_expected = expected_profile_rowbinary(profile, (0...KEYS.size).to_a, values: values)
  original_expected = expected_profile_rowbinary(profile, (0...KEYS.size).to_a)
  assert_binary(attached.fetch(:full), changed_expected, "coefficient LSB 0→1 intended literal RowBinary")
  require_true(attached.fetch(:full) != original_expected,
    "unchanged literal coefficient oracle accepted raw coefficient 0→1")
  original_rejection = require_immutable_original_rejection(profile, attached, "coefficient_lsb_zero_to_one")
  require_true(original_rejection.include?("original literal raw coefficient RowBinary oracle"),
    "coefficient mutant was not rejected by the original literal comparison: #{original_rejection}")
  write_new(File.join(queries.evidence, "coefficient-lsb-oracle-rejection.txt"), [
    "expected_first_coefficient=0", "mutant_first_coefficient=1",
    "stock_attach_and_check=passed", "exact_type_unchanged=true",
    "rejection_gate=unchanged literal raw coefficient RowBinary oracle",
    "original_oracle_failure=#{original_rejection.lines.first.strip}",
  ].join("\n") + "\n")
  puts "PASS W169 coefficient mutant: stock CHECK accepts the same-type part; original raw-literal oracle rejects coefficient 0→1"
end

def verify_constructed_roster(root, part_root)
  part_count = ACCEPTED.count do |profile|
    path = profile.part_path(part_root)
    File.directory?(path) && !File.symlink?(path)
  end
  rejected_root = File.join(part_root, "rejected")
  rejected_count = Dir.children(rejected_root).count do |name|
    path = File.join(rejected_root, name)
    File.directory?(path) && !File.symlink?(path) && Dir.empty?(path)
  end
  mutant = File.join(part_root, "mutants", "coefficient_lsb", "all_1_1_0")
  require_true(part_count == ACCEPTED.size, "Crystal authored #{part_count} canonical parts, expected #{ACCEPTED.size}")
  require_true(rejected_count == REJECTED.size, "Crystal rejected #{rejected_count} construction cases, expected #{REJECTED.size}")
  require_true(File.directory?(mutant) && !File.symlink?(mutant), "Crystal omitted coefficient LSB mutant complete part")
  [part_count, rejected_count]
end

def main
  require_true(ENV["W169_EXECUTE_AS_ROOT"] == "YES",
    "set W169_EXECUTE_AS_ROOT=YES only under root-owned serial resource guard")
  require_true(CASES.size == 414 && ACCEPTED.size == 254 && REJECTED.size == 160,
    "derived W169 function/P/S/shape roster count differs: cases=#{CASES.size}, accepted=#{ACCEPTED.size}, rejected=#{REJECTED.size}")
  require_true(selected_columns.size == 255, "derived native W169 table does not contain PK + 254 exact value columns")

  root = ENV.fetch("W169_PAIR_ROOT")
  require_true(root.start_with?(ROOT_PREFIX) && File.realpath(root) == root && !File.symlink?(root),
    "W169 output root is absent, unsafe, or noncanonical")
  children = Dir.children(root).sort
  require_true((children - ["recheck.log"]) == ["crystal-cache"],
    "W169 root must be fresh with only its isolated cache and optional wrapper log")
  log = File.join(root, "recheck.log")
  require_true(!File.symlink?(log) && (!File.exist?(log) || File.file?(log)), "W169 wrapper log is not a regular owned output")

  ENV["W169_REPO_ROOT"] = File.realpath(File.expand_path("..", __dir__))
  %w[results stores].each { |name| make_dir(File.join(root, name)) }
  make_dir(File.join(root, "results", "crystal"))
  part_root = File.join(root, "library-parts")
  make_dir(part_root)

  binary = ENV.fetch("CLICKHOUSE_BIN", DEFAULT_BINARY)
  queries = W169StockQueries.new(binary, root)
  write_literal_roster_manifest(File.join(queries.evidence, "literal-roster-manifest.tsv"))
  verify_pins(binary, queries, root)
  native = create_native_source(queries, root)
  run_crystal_spec(ENV.fetch("CRYSTAL_BIN"), root, native.fetch(:part), part_root)
  constructed_parts, rejected_cases = verify_constructed_roster(root, part_root)

  writers_store = File.join(root, "stores", "writers")
  make_dir(writers_store)
  attached = 0
  ACCEPTED.each_with_index do |profile, index|
    source_part = profile.part_path(part_root)
    values = values_for(profile, native: false)
    attached_part = attach_part(queries, root, part_root, source_part, profile,
      label: format("library_%03d_%s", index + 1, profile.part_label), values: values)
    verify_immutable_original_oracle(profile, attached_part)
    attached += 1
  end
  require_true(attached == constructed_parts && attached == ACCEPTED.size,
    "stock ATTACH/CHECK accepted #{attached} parts; construction roster has #{constructed_parts}")

  # A useful source-law discriminator: Decimal128 storage does not normalize
  # Decimal(19, 0) to the maximum family precision Decimal(38, 0).
  sum19 = ACCEPTED.find do |profile|
    profile.function == "sum" && profile.precision == 19 && profile.scale == 0 && !profile.nullable
  end
  require_true(sum19 && sum19.type == "SimpleAggregateFunction(sum, Decimal(19, 0))",
    "sum Decimal(19, 0) exact requested P/S metadata was silently normalized")
  require_true(native.fetch(:columns).include?("#{sum19.column_name}\t#{sum19.type}\t"),
    "native stock metadata omitted sum's exact Decimal(19, 0) discriminator")

  verify_metadata_mutant(queries, root, part_root,
    ACCEPTED.find { |profile| profile.function == "any" && profile.precision == 19 && profile.scale == 0 && !profile.nullable },
    label: "precision_p19_to_p20", new_precision: 20)
  verify_metadata_mutant(queries, root, part_root,
    ACCEPTED.find { |profile| profile.function == "any" && profile.precision == 19 && profile.scale == 3 && !profile.nullable },
    label: "scale_s3_to_s4", new_scale: 4)
  verify_coefficient_mutant(queries, root, part_root)

  write_new(File.join(queries.evidence, "summary.txt"), <<~TEXT)
    W169 bounded canonical Decimal SimpleAggregateFunction qualification
    runtime_version=#{VERSION}
    runtime_build_hash=#{BUILD_HASH}
    runtime_sha256=#{EXECUTABLE_SHA256}
    source_reference=#{SOURCE_ROOT}@#{SOURCE_REVISION}
    source_is_not_asserted_to_build_runtime=true
    canonical_functions=#{FUNCTIONS.map(&:first).join(",")}
    canonical_precisions=#{PRECISIONS.join(",")}
    unique_precision_scale_pairs=#{PRECISION_SCALES.length}
    candidate_construction_cases=#{CASES.length}
    source_eligible_cases=#{ACCEPTED.length}
    source_refused_cases=#{REJECTED.length}
    native_columns_including_pk=#{selected_columns.length}
    library_parts_authored=#{constructed_parts}
    library_parts_stock_attached_and_checked=#{attached}
    stock_native_source=6_rows_4_marks_Wide_LZ4
    stock_windows=full,middle,empty
    exact_rowbinary_binary_type_descriptors=passed
    sum_decimal19_metadata_retained=true
    stock_check_valid_mutants=precision_p19_to_p20,scale_s3_to_s4,coefficient_lsb_0_to_1
    all_mutants_rejected_by_original_exact_type_or_literal_oracle=true
  TEXT
  puts "PASS W169 bounded construction/stock oracle: #{CASES.length} derived cases (#{ACCEPTED.length} accepted, #{REJECTED.length} refused); #{attached} library parts stock ATTACH/CHECK and exact full/middle/empty literal RowBinary; 3 CHECK-valid mutants rejected"
end

begin
  main
rescue W169Failure => error
  warn error.message
  exit 1
end
