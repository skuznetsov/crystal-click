#!/usr/bin/env ruby
# Independent ClickHouse stock/library oracle for W170 temporal
# SimpleAggregateFunction construction and exact raw Wide-part values.
# Temporal profiles, RowBinary literals, SQL descriptors, and expectations are
# authored here independently from the Crystal test-support roster.
require "digest"
require "fileutils"
require "find"
require "json"
require "open3"

STDOUT.sync = true

VERSION = "26.10.1.1201".freeze
BUILD_HASH = "d9bcb5ab007f0f6299f7f973f2642245bab3d028".freeze
EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2".freeze
SOURCE_ROOT = "/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1".freeze
SOURCE_REVISION = "e9b645ed83ad3c07b64f09fbd014e8f770d8691b".freeze
REPO_ROOT = "/Users/sergey/Projects/Crystal/crystal-click".freeze
DEFAULT_BINARY = "/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped".freeze
ROOT_PREFIX = "/private/tmp/crystal-click-w170-native.".freeze

IDENTITY_FUNCTIONS = [
  ["any", "any"], ["anyLast", "any_last"], ["min", "min"], ["max", "max"],
].freeze
REFUSED_FUNCTIONS = %w[sum sumWithOverflow groupBitAnd groupBitOr groupBitXor].freeze
ZONE_WITNESSES = ["UTC", "Europe/Berlin", "America/Argentina/ComodRivadavia"].freeze
LONGEST_ZONE = "America/Argentina/ComodRivadavia".freeze
KEYS = [11, 22, 33, 44, 55].freeze
NULL_ROW = 2

TemporalLeaf = Struct.new(:key, :family, :sql, :carrier, :scale, :zone, keyword_init: true) do
  def width
    {"UInt16" => 2, "Int32" => 4, "UInt32" => 4, "Int64" => 8}.fetch(carrier)
  end

  def bits
    width * 8
  end
end

Profile = Struct.new(:function, :function_suffix, :leaf, :nullable, :ordinal, keyword_init: true) do
  def aggregate_type(function_name: function, temporal_sql: leaf.sql)
    "SimpleAggregateFunction(#{function_name}, #{temporal_sql})"
  end

  def type(function_name: function, temporal_sql: leaf.sql)
    inner = aggregate_type(function_name: function_name, temporal_sql: temporal_sql)
    nullable ? "Nullable(#{inner})" : inner
  end

  def column_name
    "c#{ordinal.to_s.rjust(4, '0')}"
  end

  def id
    "#{function_suffix}_#{leaf.key}_#{nullable ? 'nullable' : 'scalar'}"
  end

  def part_label
    id
  end

  def part_path(root)
    File.join(root, part_label, "all_1_1_0")
  end

  def library_table
    "w170_lib_#{column_name}"
  end
end

class W170Failure < StandardError; end

def fail!(message)
  raise W170Failure, "W170 independent temporal stock/literal oracle: #{message}"
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
rescue Errno::EEXIST
  fail!("refusing to reuse scratch directory #{path}")
end

def safe_label(value)
  value.gsub(/[^A-Za-z0-9_.-]/, "_")
end

def safe_child_path!(path, root, label)
  require_true(File.directory?(path) && !File.symlink?(path), "#{label} is absent or a symlink: #{path}")
  real_root = File.realpath(root)
  real_path = File.realpath(path)
  require_true(real_path.start_with?(real_root + File::SEPARATOR) && real_path != real_root,
    "#{label} resolves outside its owned root: #{real_path}")
  real_path
rescue Errno::ENOENT, Errno::EACCES => error
  fail!("cannot resolve #{label} safely: #{error.message}")
end

def ensure_empty_detached_dir!(data_path, label)
  detached = File.join(data_path, "detached")
  if File.exist?(detached) || File.symlink?(detached)
    safe_child_path!(detached, data_path, label)
    require_true(Dir.empty?(detached), "refusing to reuse nonempty detached directory #{detached}")
  else
    Dir.mkdir(detached, 0o700)
  end
  detached
end

def temporal_leaves
  leaves = [
    TemporalLeaf.new(key: "date", family: "Date", sql: "Date", carrier: "UInt16"),
    TemporalLeaf.new(key: "date32", family: "Date32", sql: "Date32", carrier: "Int32"),
    TemporalLeaf.new(key: "datetime_bare", family: "DateTime", sql: "DateTime", carrier: "UInt32"),
  ]
  ZONE_WITNESSES.each do |zone|
    key = case zone
          when "UTC" then "utc"
          when "Europe/Berlin" then "europe_berlin"
          when LONGEST_ZONE then "america_argentina_comodrivadavia"
          else fail!("unlisted timezone witness")
          end
    leaves << TemporalLeaf.new(key: "datetime_#{key}", family: "DateTime",
      sql: "DateTime('#{zone}')", carrier: "UInt32", zone: zone)
  end
  (0..9).each do |scale|
    leaves << TemporalLeaf.new(key: "datetime64_s#{scale}", family: "DateTime64",
      sql: "DateTime64(#{scale})", carrier: "Int64", scale: scale)
  end
  [0, 3, 9].each do |scale|
    ZONE_WITNESSES.each do |zone|
      key = case zone
            when "UTC" then "utc"
            when "Europe/Berlin" then "europe_berlin"
            when LONGEST_ZONE then "america_argentina_comodrivadavia"
            else fail!("unlisted timezone witness")
            end
      leaves << TemporalLeaf.new(key: "datetime64_s#{scale}_#{key}", family: "DateTime64",
        sql: "DateTime64(#{scale}, '#{zone}')", carrier: "Int64", scale: scale, zone: zone)
    end
  end
  leaves << TemporalLeaf.new(key: "time", family: "Time", sql: "Time", carrier: "Int32")
  (0..9).each do |scale|
    leaves << TemporalLeaf.new(key: "time64_s#{scale}", family: "Time64",
      sql: "Time64(#{scale})", carrier: "Int64", scale: scale)
  end
  leaves
end

def accepted_profiles
  ordinal = 0
  IDENTITY_FUNCTIONS.flat_map do |function, suffix|
    temporal_leaves.flat_map do |leaf|
      [false, true].map do |nullable|
        ordinal += 1
        Profile.new(function: function, function_suffix: suffix, leaf: leaf,
          nullable: nullable, ordinal: ordinal)
      end
    end
  end
end

def native_values(leaf)
  case leaf.carrier
  when "UInt16" then [0, 1, 0xffff, 0x1234, 0xabcd]
  when "Int32" then [0, -1, -(1 << 31), (1 << 31) - 1, 0x01234567]
  when "UInt32" then [0, 1, 0xffffffff, 0x12345678, 0x89abcdef]
  when "Int64" then [0, -1, -(1 << 63), (1 << 63) - 1, 0x0123456789abcdef]
  else fail!("unknown raw temporal carrier #{leaf.carrier}")
  end
end

def library_values(leaf)
  case leaf.carrier
  when "UInt16" then [0, 0xffff, 1, 0xabcd, 0x1234]
  when "Int32" then [0, -1, (1 << 31) - 1, -(1 << 31), -0x01234567]
  when "UInt32" then [0, 1, 0x89abcdef, 0xffffffff, 0x12345678]
  when "Int64" then [0, -1, (1 << 63) - 1, -(1 << 63), 0x0fedcba987654321]
  else fail!("unknown raw temporal carrier #{leaf.carrier}")
  end
end

def raw_bytes(leaf, value)
  unsigned = value & ((1 << leaf.bits) - 1)
  Array.new(leaf.width) { |index| (unsigned >> (index * 8)) & 0xff }.pack("C*").b
end

def rowbinary_value(profile, value)
  return "\x01".b if profile.nullable && value.nil?
  (profile.nullable ? "\x00".b : "".b) + raw_bytes(profile.leaf, value)
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

def temporal_type_descriptor(leaf)
  case leaf.family
  when "Date"
    "\x0f".b
  when "Date32"
    "\x10".b
  when "DateTime"
    leaf.zone ? "\x12".b + binary_string(leaf.zone) : "\x11".b
  when "DateTime64"
    scale = [leaf.scale].pack("C").b
    leaf.zone ? "\x14".b + scale + binary_string(leaf.zone) : "\x13".b + scale
  when "Time"
    "\x32".b
  when "Time64"
    "\x34".b + [leaf.scale].pack("C").b
  else
    fail!("unknown temporal family for binary type descriptor #{leaf.family.inspect}")
  end
end

def aggregate_type_descriptor(profile)
  descriptor = "\x2e".b + binary_string(profile.function) + "\x00\x01".b
  descriptor << temporal_type_descriptor(profile.leaf)
  profile.nullable ? "\x23".b + descriptor : descriptor
end

def native_columns
  ["pk UInt64"] + accepted_profiles.map { |profile| "#{profile.column_name} #{profile.type}" }
end

def expected_native_columns
  rows = [["pk", "UInt64", 1]]
  accepted_profiles.each_with_index do |profile, index|
    rows << [profile.column_name, profile.type, index + 2]
  end
  rows.map { |name, type, position| "#{name}\t#{type}\t#{position}" }.join("\n") + "\n"
end

def expected_native_binary_type_header
  profiles = accepted_profiles
  names = ["pk"] + profiles.map(&:column_name)
  descriptors = ["\x04".b] + profiles.map { |profile| aggregate_type_descriptor(profile) }
  varuint(names.size) + names.map { |name| binary_string(name) }.join.b + descriptors.join.b
end

def native_rowbinary_input
  output = +"".b
  KEYS.each_with_index do |key, row|
    output << [key].pack("Q<")
    accepted_profiles.each do |profile|
      value = profile.nullable && row == NULL_ROW ? nil : native_values(profile.leaf).fetch(row)
      output << rowbinary_value(profile, value)
    end
  end
  output
end

def expected_native_rowbinary(rows)
  output = +"".b
  rows.each do |row|
    output << [KEYS.fetch(row)].pack("Q<")
    accepted_profiles.each do |profile|
      value = profile.nullable && row == NULL_ROW ? nil : native_values(profile.leaf).fetch(row)
      output << rowbinary_value(profile, value)
    end
  end
  output
end

def expected_library_rowbinary(profile, rows, values: library_values(profile.leaf), declared_type: profile.type)
  output = +"".b
  rows.each do |row|
    output << [KEYS.fetch(row)].pack("Q<")
    value = profile.nullable && row == NULL_ROW ? nil : values.fetch(row)
    output << rowbinary_value(profile, value)
  end
  output
end

def assert_binary(actual, expected, label)
  return if actual.b == expected.b
  shared = [actual.bytesize, expected.bytesize].min
  mismatch = (0...shared).find { |index| actual.getbyte(index) != expected.getbyte(index) } || shared
  wanted = mismatch < expected.bytesize ? expected.getbyte(mismatch).to_s(16).rjust(2, "0") : "<eof>"
  observed = mismatch < actual.bytesize ? actual.getbyte(mismatch).to_s(16).rjust(2, "0") : "<eof>"
  fail!("#{label} differs: expected #{expected.bytesize} bytes, observed #{actual.bytesize}; byte #{mismatch}: expected #{wanted}, got #{observed}")
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

class W170Recorder
  attr_reader :evidence

  def initialize(binary, root)
    @binary = binary
    @evidence = File.join(root, "results", "ruby-oracle")
    make_dir(@evidence)
    make_dir(File.join(@evidence, "processes"))
    @sequence = 0
  end

  def run(label, store, sql, input: nil, multiquery: false, settings: {})
    @sequence += 1
    stem = format("%05d-%s", @sequence, safe_label(label))
    prefix = File.join(@evidence, "processes", stem)
    args = [@binary, "local", "--path", store, "--session_timezone=UTC",
      "--print_pretty_type_names=0", "--output_format_json_quote_64bit_integers=0",
      "--enable_time_time64_type=1", "--max_threads=1", "--max_insert_threads=1",
      "--max_memory_usage=1073741824"]
    args << "--multiquery" if multiquery
    args << "--query" << sql
    settings.each { |name, value| args << "--#{name}=#{value}" }
    write_new(prefix + ".sql", sql.b + (sql.end_with?("\n") ? "" : "\n").b)
    write_new(prefix + ".argv.json", JSON.pretty_generate({
      "argv" => args,
      "stdin_bytes" => input&.bytesize,
      "stdin_sha256" => input && Digest::SHA256.hexdigest(input),
      "environment" => {"TZ" => "UTC"},
    }) + "\n")
    write_new(prefix + ".stdin.bin", input.b) if input
    stdout, stderr, status = Open3.capture3({"TZ" => "UTC"}, *args,
      stdin_data: input, chdir: REPO_ROOT)
    write_new(prefix + ".stdout", stdout.b)
    write_new(prefix + ".stderr", stderr.b)
    status_record = {
      "success" => status.success?, "exitstatus" => status.exitstatus,
      "signaled" => status.signaled?, "termsig" => status.termsig,
      # RowBinaryWithNamesAndTypes can make stdout invalid UTF-8. Keep the
      # evidence untouched and scan a binary copy with an ASCII-only pattern.
      "reported_clickhouse_codes" => (stdout.b + stderr.b).scan(
        /(?:^|[^A-Za-z0-9_])Code:[\x09-\x0d\x20]*([0-9]+)(?![A-Za-z0-9_])/in,
      ).flatten.map(&:to_i).uniq,
    }
    write_new(prefix + ".status.json", JSON.pretty_generate(status_record) + "\n")
    write_new(prefix + ".hashes.json", JSON.pretty_generate({
      "sql_sha256" => Digest::SHA256.file(prefix + ".sql").hexdigest,
      "stdout_sha256" => Digest::SHA256.hexdigest(stdout.b),
      "stderr_sha256" => Digest::SHA256.hexdigest(stderr.b),
      "stdin_sha256" => input && Digest::SHA256.hexdigest(input.b),
    }) + "\n")
    {prefix: prefix, stdout: stdout.b, stderr: stderr.b, status: status_record, argv: args}
  end

  def require_success!(record, label)
    status = record.fetch(:status)
    return if status.fetch("success") && !status.fetch("signaled")
    fail!("#{label} failed (exit=#{status.fetch('exitstatus').inspect}, signal=#{status.fetch('termsig').inspect}): #{record.fetch(:stderr)}")
  end
end

def source_revision_pin!(recorder, label)
  git_stdout, git_stderr, git_status = Open3.capture3("git", "-C", SOURCE_ROOT, "rev-parse", "HEAD")
  require_true(git_status.success? && !git_status.signaled? && git_stdout.strip == SOURCE_REVISION,
    "source revision pin differs: #{git_stdout.strip.inspect} #{git_stderr.inspect}")
  git_artifact = File.join(recorder.evidence, "source-#{safe_label(label)}.json")
  write_new(git_artifact, JSON.pretty_generate({
    "argv" => ["git", "-C", SOURCE_ROOT, "rev-parse", "HEAD"],
    "stdout" => git_stdout, "stderr" => git_stderr,
    "status" => {"success" => git_status.success?, "exitstatus" => git_status.exitstatus,
      "signaled" => git_status.signaled?, "termsig" => git_status.termsig},
    "expected_source_revision" => SOURCE_REVISION,
  }) + "\n")
  git_stdout.strip
end

def verify_runtime_pin!(recorder, binary, root, suffix)
  require_true(File.file?(binary) && File.executable?(binary) && !File.symlink?(binary),
    "pinned ClickHouse executable is absent, non-executable, or a symlink")
  digest = Digest::SHA256.file(binary).hexdigest
  require_true(digest == EXECUTABLE_SHA256, "ClickHouse executable SHA-256 differs: #{digest}")
  identity_store = File.join(root, "stores", "pins")
  version_record = recorder.run("runtime-version-#{suffix}", identity_store,
    "SELECT version() FORMAT TSVRaw")
  recorder.require_success!(version_record, "runtime version query")
  version = version_record.fetch(:stdout).strip
  require_true(version == VERSION, "ClickHouse version differs: #{version.inspect}")
  build_record = recorder.run("runtime-build-#{suffix}", identity_store,
    "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw")
  recorder.require_success!(build_record, "runtime build query")
  build = build_record.fetch(:stdout)
  require_true(build == "VERSION_GITHASH=#{BUILD_HASH}\n", "ClickHouse build hash differs: #{build.inspect}")
  source = source_revision_pin!(recorder, "source-revision-#{suffix}")
  pin = {
    "runtime_version" => version,
    "runtime_sha256" => digest,
    "runtime_build_hash" => BUILD_HASH,
    "source_reference" => "#{SOURCE_ROOT}@#{source}",
    "source_is_not_asserted_to_build_runtime" => true,
  }
  write_new(File.join(recorder.evidence, "pins-#{suffix}.json"), JSON.pretty_generate(pin) + "\n")
  pin
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

def make_evidence_output_dirs(evidence)
  %w[rowbinary rowbinary/native rowbinary/library rowbinary/mutants].each do |relative|
    path = File.join(evidence, relative)
    FileUtils.mkdir_p(path, mode: 0o700)
    require_true(File.directory?(path) && !File.symlink?(path), "unsafe evidence output directory #{path}")
  end
end

def create_native_source(recorder, root)
  store = File.join(root, "stores", "native-stock")
  make_dir(store)
  table = "w170_simple_aggregate_temporal_stock"
  create = recorder.run("native-create", store, native_table_ddl(table, native_columns))
  recorder.require_success!(create, "native stock CREATE TABLE")
  insert = recorder.run("native-insert-rowbinary", store,
    "INSERT INTO default.#{table} FORMAT RowBinary", input: native_rowbinary_input)
  recorder.require_success!(insert, "native stock RowBinary INSERT")

  metadata = recorder.run("native-system-columns", store,
    "SELECT name, type, toString(position) FROM system.columns " \
    "WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  recorder.require_success!(metadata, "native exact type metadata")
  require_true(metadata.fetch(:stdout) == expected_native_columns,
    "native exact canonical temporal metadata (including scale/timezone) differs")
  type_header = recorder.run("native-binary-type-header", store,
    "SELECT #{(["pk"] + accepted_profiles.map(&:column_name)).join(", ")} " \
    "FROM default.#{table} LIMIT 0 FORMAT RowBinaryWithNamesAndTypes",
    settings: {"output_format_binary_encode_types_in_binary_format" => "1"})
  recorder.require_success!(type_header, "native RowBinaryWithNamesAndTypes type header")
  assert_binary(type_header.fetch(:stdout), expected_native_binary_type_header,
    "native 289-column literal binary temporal type header")
  write_new(File.join(recorder.evidence, "rowbinary", "native", "type-header.bin"),
    type_header.fetch(:stdout))
  check = recorder.run("native-check-table", store,
    "CHECK TABLE default.#{table} FORMAT TabSeparated")
  recorder.require_success!(check, "native CHECK TABLE")
  require_true(check.fetch(:stdout) == "all_1_1_0\t1\t\n",
    "native stock CHECK TABLE raw fields differ: #{check.fetch(:stdout).inspect}")
  part = recorder.run("native-part-info", store,
    "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts " \
    "WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw")
  recorder.require_success!(part, "native part metadata")
  fields = part.fetch(:stdout).strip.split("\t", -1)
  require_true(fields.size == 5 && fields[0, 4] == ["all_1_1_0", "5", "4", "Wide"],
    "native source is not one five-row Wide part with bounded marks: #{part.fetch(:stdout).inspect}")
  source_part = safe_child_path!(fields[4], store, "native source part")

  windows = [
    ["full", "", (0...KEYS.size).to_a],
    ["middle", " WHERE pk >= 22 AND pk <= 44", [1, 2, 3]],
    ["empty", " WHERE pk = 0", []],
  ]
  windows.each do |label, where, rows|
    record = recorder.run("native-rowbinary-#{label}", store,
      "SELECT #{(["pk"] + accepted_profiles.map(&:column_name)).join(", ")} " \
      "FROM default.#{table}#{where} ORDER BY pk FORMAT RowBinary")
    recorder.require_success!(record, "native #{label} RowBinary")
    assert_binary(record.fetch(:stdout), expected_native_rowbinary(rows), "native #{label} RowBinary")
    write_new(File.join(recorder.evidence, "rowbinary", "native", "#{label}.bin"), record.fetch(:stdout))
  end

  parent = File.join(root, "native-stock-part")
  make_dir(parent)
  local_part = File.join(parent, "all_1_1_0")
  require_true(!File.exist?(local_part) && !File.symlink?(local_part), "refusing to overwrite copied native source part")
  FileUtils.cp_r(source_part, local_part)
  puts "PASS W170 native stock source: 289 columns, 5 rows, exact temporal metadata, Wide/LZ4, full/middle/empty RowBinary"
  {store: store, table: table, part: local_part, metadata: metadata.fetch(:stdout)}
end

def run_crystal_spec(crystal, recorder, root, stock_part, part_root)
  base = File.join(root, "results", "crystal", "wide-part-simple-aggregate-temporal-native-spec")
  args = [crystal, "spec", "--single-module", "--threads", "1", "--error-trace",
    "--link-flags=-fuse-ld=ld", "spec/wide_part_simple_aggregate_temporal_w170_native_spec.cr"]
  env = {
    "CRYSTAL_CACHE_DIR" => ENV.fetch("CRYSTAL_CACHE_DIR"),
    "TZ" => "UTC",
    "W170_SIMPLE_AGGREGATE_STOCK_WIDE_PART" => stock_part,
    "W170_PART_ROOT" => part_root,
  }
  write_new(base + ".argv.json", JSON.pretty_generate({"argv" => args, "environment" => env}) + "\n")
  stdout, stderr, status = Open3.capture3(env, *args, chdir: REPO_ROOT)
  write_new(base + ".stdout", stdout.b)
  write_new(base + ".stderr", stderr.b)
  status_record = {"success" => status.success?, "exitstatus" => status.exitstatus,
    "signaled" => status.signaled?, "termsig" => status.termsig}
  write_new(base + ".status.json", JSON.pretty_generate(status_record) + "\n")
  write_new(base + ".hashes.json", JSON.pretty_generate({
    "stdout_sha256" => Digest::SHA256.hexdigest(stdout.b),
    "stderr_sha256" => Digest::SHA256.hexdigest(stderr.b),
  }) + "\n")
  fail!("Crystal W170 qualification spec failed (exit=#{status.exitstatus.inspect}, signal=#{status.termsig.inspect}): #{stderr}") unless status.success? && !status.signaled?
  summaries = stdout.lines.map(&:strip).select { |line| line.match?(/\A\d+ examples?,/) }
  require_true(summaries == ["2 examples, 0 failures, 0 errors, 0 pending"],
    "Crystal W170 spec did not execute exactly two actual passing examples: #{summaries.inspect}")
  require_true(stdout.include?("W170 construction matrix: leaves=36 accepted=288 rejected=0 native_columns=289 refusal_functions=5 refusal_cases=180 value_mutants=1"),
    "Crystal W170 exact construction roster/count line is missing")
  puts stdout unless stdout.empty?
end

def library_table_data_paths(recorder, store, profiles)
  paths = {}
  profiles.each_slice(24).with_index do |batch, batch_index|
    statements = batch.map do |profile|
      native_table_ddl(profile.library_table, ["pk UInt64", "v #{profile.type}"])
    end
    statements << "SELECT name, data_paths[1] FROM system.tables WHERE database='default' " \
      "AND name IN (#{batch.map { |profile| "'#{profile.library_table}'" }.join(",")}) " \
      "ORDER BY name FORMAT TSVRaw;"
    record = recorder.run(format("library-create-tables-%02d", batch_index + 1), store,
      statements.join("\n"), multiquery: true)
    recorder.require_success!(record, "library table creation batch #{batch_index + 1}")
    found = {}
    record.fetch(:stdout).lines.each do |line|
      name, path = line.chomp.split("\t", 2)
      require_true(name && path && !path.empty?, "malformed system.tables data path row: #{line.inspect}")
      require_true(!found.key?(name), "duplicate library table path row: #{name}")
      found[name] = path
    end
    expected_names = batch.map(&:library_table).sort
    require_true(found.keys.sort == expected_names,
      "library table path roster mismatch: expected=#{expected_names.inspect}, observed=#{found.keys.sort.inspect}")
    found.each do |name, path|
      paths[name] = safe_child_path!(path, store, "library table data path #{name}")
    end
  end
  require_true(paths.size == profiles.size, "library table data path count #{paths.size}, expected #{profiles.size}")
  paths
end

def prepare_library_parts(recorder, root, profiles, part_root, table_paths)
  profiles.each do |profile|
    source_part = safe_child_path!(profile.part_path(part_root), part_root,
      "Crystal-authored complete part #{profile.part_label}")
    files = part_files(source_part)
    require_true(files.include?("columns.txt") && files.include?("count.txt"),
      "library complete part metadata is incomplete for #{profile.part_label}")
    columns = File.binread(File.join(source_part, "columns.txt"))
    require_true(columns.include?(profile.type), "Crystal part lacks exact type metadata #{profile.type}")
    data_path = table_paths.fetch(profile.library_table)
    detached = ensure_empty_detached_dir!(data_path, "detached directory #{profile.library_table}")
    target = File.join(detached, "all_1_1_0")
    require_true(!File.exist?(target) && !File.symlink?(target), "refusing to overwrite detached library part #{target}")
    FileUtils.cp_r(source_part, target)
  end
end

def library_window_sql(table, label, where, outfile)
  "SELECT pk, v FROM default.#{table}#{where} ORDER BY pk INTO OUTFILE '#{outfile}' FORMAT RowBinary;"
end

def attach_and_check_library(recorder, root, profile, table, part_label)
  output_root = File.join(recorder.evidence, "rowbinary", "library")
  stem = safe_label(part_label)
  outputs = {
    "full" => File.join(output_root, "#{stem}-full.bin"),
    "middle" => File.join(output_root, "#{stem}-middle.bin"),
    "empty" => File.join(output_root, "#{stem}-empty.bin"),
    "schema" => File.join(output_root, "#{stem}-schema.tsv"),
    "partinfo" => File.join(output_root, "#{stem}-partinfo.tsv"),
  }
  sql = [
    "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0';",
    "CHECK TABLE default.#{table} FORMAT TabSeparated;",
    "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position INTO OUTFILE '#{outputs.fetch('schema')}' FORMAT TSVRaw;",
    "SELECT name, toString(rows), toString(marks), part_type FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name INTO OUTFILE '#{outputs.fetch('partinfo')}' FORMAT TSVRaw;",
    library_window_sql(table, "full", "", outputs.fetch("full")),
    library_window_sql(table, "middle", " WHERE pk >= 22 AND pk <= 44", outputs.fetch("middle")),
    library_window_sql(table, "empty", " WHERE pk = 0", outputs.fetch("empty")),
  ].join("\n")
  record = recorder.run("library-attach-check-#{part_label}",
    File.join(root, "stores", "library"), sql, multiquery: true)
  recorder.require_success!(record, "library ATTACH/CHECK/RowBinary #{part_label}")
  require_true(record.fetch(:stdout) == "all_1_1_0\t1\t\n",
    "library CHECK TABLE differs for #{part_label}: #{record.fetch(:stdout).inspect}")
  expected_schema = "pk\tUInt64\nv\t#{profile.type}\n"
  require_true(File.binread(outputs.fetch("schema")) == expected_schema,
    "attached stock exact type descriptor differs for #{part_label}")
  require_true(File.binread(outputs.fetch("partinfo")) == "all_1_1_0\t5\t4\tWide\n",
    "attached library part is not the exact five-row Wide source for #{part_label}")
  values = library_values(profile.leaf)
  {"full" => (0...KEYS.size).to_a, "middle" => [1, 2, 3], "empty" => []}.each do |window, rows|
    observed = File.binread(outputs.fetch(window))
    expected = expected_library_rowbinary(profile, rows, values: values)
    assert_binary(observed, expected, "stock-attached library #{part_label} #{window} RowBinary")
  end
  outputs.each_value { |path| require_true(File.file?(path) && !File.symlink?(path), "missing raw library evidence output #{path}") }
  record
end

def attach_mutant_table(recorder, root, store, label, profile, declared_type, source_part)
  table = "w170_mutant_#{safe_label(label)}"
  create = recorder.run("mutant-create-#{label}", store,
    native_table_ddl(table, ["pk UInt64", "v #{declared_type}"]))
  recorder.require_success!(create, "mutant table create #{label}")
  path_record = recorder.run("mutant-data-path-#{label}", store,
    "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw")
  recorder.require_success!(path_record, "mutant table data path #{label}")
  data_path = safe_child_path!(path_record.fetch(:stdout).strip, store, "mutant table path #{label}")
  detached = ensure_empty_detached_dir!(data_path, "mutant detached directory #{label}")
  target = File.join(detached, "all_1_1_0")
  require_true(!File.exist?(target) && !File.symlink?(target), "refusing to overwrite mutant detached part #{target}")
  FileUtils.cp_r(source_part, target)

  root_evidence = File.join(recorder.evidence, "rowbinary", "mutants")
  base = safe_label(label)
  schema_path = File.join(root_evidence, "#{base}-schema.tsv")
  partinfo_path = File.join(root_evidence, "#{base}-partinfo.tsv")
  full_path = File.join(root_evidence, "#{base}-full.bin")
  sql = [
    "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0';",
    "CHECK TABLE default.#{table} FORMAT TabSeparated;",
    "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position INTO OUTFILE '#{schema_path}' FORMAT TSVRaw;",
    "SELECT name, toString(rows), toString(marks), part_type FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name INTO OUTFILE '#{partinfo_path}' FORMAT TSVRaw;",
    "SELECT pk, v FROM default.#{table} ORDER BY pk INTO OUTFILE '#{full_path}' FORMAT RowBinary;",
  ].join("\n")
  record = recorder.run("mutant-attach-check-#{label}", store, sql, multiquery: true)
  recorder.require_success!(record, "mutant ATTACH/CHECK #{label}")
  require_true(record.fetch(:stdout) == "all_1_1_0\t1\t\n", "mutant CHECK failed for #{label}: #{record.fetch(:stdout).inspect}")
  require_true(File.binread(schema_path) == "pk\tUInt64\nv\t#{declared_type}\n", "mutant stock metadata differs for #{label}")
  require_true(File.binread(partinfo_path) == "all_1_1_0\t5\t4\tWide\n", "mutant part info differs for #{label}")
  observed = File.binread(full_path)
  original_schema = "pk\tUInt64\nv\t#{profile.type}\n"
  original_rowbinary = expected_library_rowbinary(profile, (0...KEYS.size).to_a)
  observed_schema = File.binread(schema_path)
  {record: record, observed: observed, schema: observed_schema,
   original_schema_match: observed_schema == original_schema,
   original_rowbinary_match: observed == original_rowbinary}
end

def write_mutated_metadata_part(root, profile, label, mutant_type)
  source = profile.part_path(ENV.fetch("W170_PART_ROOT"))
  target = File.join(root, "mutants", safe_label(label), "all_1_1_0")
  FileUtils.mkdir_p(File.dirname(target), mode: 0o700)
  require_true(!File.exist?(target) && !File.symlink?(target), "refusing to overwrite metadata mutant #{target}")
  source_files = part_files(source)
  FileUtils.cp_r(source, target)
  before = File.binread(File.join(target, "columns.txt"))
  original = profile.type
  require_true(before.scan(original).length == 1, "#{label} part lacks one exact original declaration")
  after = before.sub(original, mutant_type)
  require_true(after != before, "#{label} metadata mutation made no change")
  File.binwrite(File.join(target, "columns.txt"), after)
  require_true(source_files == part_files(target), "#{label} changed complete-part file roster")
  changed = source_files.select do |relative|
    File.binread(File.join(source, relative)) != File.binread(File.join(target, relative))
  end
  require_true(changed == ["columns.txt"], "#{label} modified part files beyond columns.txt: #{changed.inspect}")
  target
end

def verify_metadata_mutant(recorder, root, profile, label, mutant_storage_type)
  source = profile.part_path(ENV.fetch("W170_PART_ROOT"))
  mutant_type = profile.type(temporal_sql: mutant_storage_type)
  part = write_mutated_metadata_part(root, profile, label, mutant_type)
  record = attach_mutant_table(recorder, root, File.join(root, "stores", "library"), label,
    profile, mutant_type, part)
  # CHECK validates part consistency, not the caller's original nominal zone or scale.
  original_type_rejection = mutant_type == profile.type
  require_true(!original_type_rejection, "#{label} metadata mutant did not change exact type")
  original_raw = expected_library_rowbinary(profile, (0...KEYS.size).to_a)
  assert_binary(record.fetch(:observed), original_raw, "same-width metadata mutant #{label} raw values")
  require_true(!record.fetch(:original_schema_match),
    "unchanged exact type oracle accepted same-width metadata mutant #{label}")
  require_true(record.fetch(:original_rowbinary_match),
    "same-width metadata mutation unexpectedly changed raw payload #{label}")
  write_new(File.join(recorder.evidence, "#{safe_label(label)}-oracle-rejection.txt"),
    ["original_type=#{profile.type}", "mutant_type=#{mutant_type}",
     "same_carrier_width=true", "stock_attach_and_check=passed",
     "raw_rowbinary_matches_original_literals=true", "unchanged_exact_type_oracle=rejected"].join("\n") + "\n")
  puts "PASS W170 #{label}: stock CHECK accepts same-width type metadata; exact original descriptor oracle rejects"
end

def verify_value_mutant(recorder, root, profiles)
  profile = profiles.find do |candidate|
    candidate.function == "any" && candidate.leaf.sql == "DateTime64(3)" && !candidate.nullable
  end
  require_true(profile, "W170 roster omitted DateTime64(3) scalar any discriminator")
  source = File.join(ENV.fetch("W170_PART_ROOT"), "mutants", "value_lsb", "all_1_1_0")
  require_true(File.directory?(source) && !File.symlink?(source), "Crystal omitted writer-produced value mutant")
  original_values = library_values(profile.leaf)
  mutant_values = original_values.dup
  mutant_values[0] = 1
  table = "w170_mutant_value_lsb"
  store = File.join(root, "stores", "library")
  create = recorder.run("mutant-create-value-lsb", store,
    native_table_ddl(table, ["pk UInt64", "v #{profile.type}"]))
  recorder.require_success!(create, "value mutant table create")
  path_record = recorder.run("mutant-data-path-value-lsb", store,
    "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw")
  recorder.require_success!(path_record, "value mutant table path")
  data_path = safe_child_path!(path_record.fetch(:stdout).strip, store, "value mutant data path")
  detached = ensure_empty_detached_dir!(data_path, "value mutant detached directory")
  target = File.join(detached, "all_1_1_0")
  require_true(!File.exist?(target) && !File.symlink?(target), "refusing to overwrite value mutant part #{target}")
  FileUtils.cp_r(source, target)
  base = "value_lsb"
  outputs = {
    "schema" => File.join(recorder.evidence, "rowbinary", "mutants", "#{base}-schema.tsv"),
    "partinfo" => File.join(recorder.evidence, "rowbinary", "mutants", "#{base}-partinfo.tsv"),
    "full" => File.join(recorder.evidence, "rowbinary", "mutants", "#{base}-full.bin"),
  }
  sql = [
    "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0';",
    "CHECK TABLE default.#{table} FORMAT TabSeparated;",
    "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position INTO OUTFILE '#{outputs.fetch('schema')}' FORMAT TSVRaw;",
    "SELECT name, toString(rows), toString(marks), part_type FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name INTO OUTFILE '#{outputs.fetch('partinfo')}' FORMAT TSVRaw;",
    "SELECT pk, v FROM default.#{table} ORDER BY pk INTO OUTFILE '#{outputs.fetch('full')}' FORMAT RowBinary;",
  ].join("\n")
  record = recorder.run("mutant-attach-check-value-lsb", store, sql, multiquery: true)
  recorder.require_success!(record, "value mutant ATTACH/CHECK")
  require_true(record.fetch(:stdout) == "all_1_1_0\t1\t\n", "value mutant CHECK failed: #{record.fetch(:stdout).inspect}")
  require_true(File.binread(outputs.fetch("schema")) == "pk\tUInt64\nv\t#{profile.type}\n",
    "value mutant changed its exact declared type")
  require_true(File.binread(outputs.fetch("partinfo")) == "all_1_1_0\t5\t4\tWide\n",
    "value mutant part metadata differs")
  expected_original = expected_library_rowbinary(profile, (0...KEYS.size).to_a, values: original_values)
  expected_mutant = expected_library_rowbinary(profile, (0...KEYS.size).to_a, values: mutant_values)
  actual = File.binread(outputs.fetch("full"))
  assert_binary(actual, expected_mutant, "writer-produced value mutant intended RowBinary")
  require_true(actual != expected_original, "unchanged literal raw oracle accepted value mutation")
  write_new(File.join(recorder.evidence, "value-lsb-oracle-rejection.txt"),
    ["original_first_raw_value=0", "mutant_first_raw_value=1", "exact_type_unchanged=true",
     "stock_attach_and_check=passed", "rejection_gate=unchanged literal RowBinary oracle"].join("\n") + "\n")
  puts "PASS W170 value mutant: stock CHECK accepts same-type part; unchanged literal RowBinary oracle rejects raw 0→1"
end

def validate_root!(root)
  require_true(ENV["W170_EXECUTE_AS_ROOT"] == "YES",
    "set W170_EXECUTE_AS_ROOT=YES only under the root-owned serial resource guard")
  require_true(root.start_with?(ROOT_PREFIX) && File.realpath(root) == root && !File.symlink?(root),
    "W170 output root is absent, unsafe, or noncanonical")
  children = Dir.children(root).sort
  require_true((children - ["crystal-cache", "recheck.log"]).empty? && children.include?("crystal-cache"),
    "W170 root must be fresh with only isolated cache and optional wrapper log")
  %w[crystal-cache recheck.log].each do |name|
    path = File.join(root, name)
    next unless File.exist?(path) || File.symlink?(path)
    require_true(!File.symlink?(path) && (name == "crystal-cache" ? File.directory?(path) : File.file?(path)),
      "unsafe W170 root child #{name}")
  end
end

def main
  require_true(IDENTITY_FUNCTIONS.map(&:first) == %w[any anyLast min max], "W170 identity function roster drifted")
  leaves = temporal_leaves
  profiles = accepted_profiles
  require_true(leaves.size == 36 && profiles.size == 288,
    "W170 derived roster differs: leaves=#{leaves.size}, accepted=#{profiles.size}")
  require_true(profiles.map(&:column_name) == (1..288).map { |index| "c#{index.to_s.rjust(4, '0')}" },
    "W170 c0001..c0288 stock column sequence differs")
  require_true(native_columns.size == 289, "W170 native table must contain PK plus exactly 288 value columns")
  require_true(LONGEST_ZONE.bytesize == 32 && ZONE_WITNESSES.last == LONGEST_ZONE,
    "W170 longest timezone witness is not the independent 32-byte literal")

  root = ENV.fetch("W170_PAIR_ROOT")
  validate_root!(root)
  make_dir(File.join(root, "results"))
  make_dir(File.join(root, "stores"))
  make_dir(File.join(root, "stores", "pins"))
  make_dir(File.join(root, "results", "crystal"))
  part_root = File.join(root, "library-parts")
  make_dir(part_root)
  # The recorder owns this evidence subtree and all process artifacts beneath it.
  recorder = W170Recorder.new(ENV.fetch("CLICKHOUSE_BIN", DEFAULT_BINARY), root)
  make_evidence_output_dirs(recorder.evidence)
  part_store = File.join(root, "stores", "library")
  make_dir(part_store)

  before_pin = verify_runtime_pin!(recorder, ENV.fetch("CLICKHOUSE_BIN", DEFAULT_BINARY), root, "before")
  native = create_native_source(recorder, root)
  run_crystal_spec(ENV.fetch("CRYSTAL_BIN"), recorder, root, native.fetch(:part), part_root)
  source_profiles = profiles
  table_paths = library_table_data_paths(recorder, part_store, source_profiles)
  prepare_library_parts(recorder, root, source_profiles, part_root, table_paths)
  source_profiles.each do |profile|
    attach_and_check_library(recorder, root, profile, profile.library_table, profile.part_label)
  end

  zone_profile = source_profiles.find do |profile|
    profile.function == "any" && profile.leaf.sql == "DateTime('UTC')" && !profile.nullable
  end
  require_true(zone_profile, "W170 roster omitted DateTime('UTC') scalar any discriminator")
  verify_metadata_mutant(recorder, root, zone_profile, "zone_utc_to_berlin", "DateTime('Europe/Berlin')")
  scale_profile = source_profiles.find do |profile|
    profile.function == "any" && profile.leaf.sql == "DateTime64(3)" && !profile.nullable
  end
  require_true(scale_profile, "W170 roster omitted DateTime64(3) scalar any discriminator")
  verify_metadata_mutant(recorder, root, scale_profile, "scale_3_to_4", "DateTime64(4)")
  verify_value_mutant(recorder, root, source_profiles)

  after_pin = verify_runtime_pin!(recorder, ENV.fetch("CLICKHOUSE_BIN", DEFAULT_BINARY), root, "after")
  require_true(before_pin == after_pin, "runtime/source pins changed during W170 evidence capture")
  summary = [
    "W170 bounded temporal SimpleAggregateFunction qualification",
    "runtime_version=#{VERSION}", "runtime_build_hash=#{BUILD_HASH}",
    "runtime_sha256=#{EXECUTABLE_SHA256}",
    "source_reference=#{SOURCE_ROOT}@#{SOURCE_REVISION}",
    "source_is_not_asserted_to_build_runtime=true",
    "temporal_leaves=#{leaves.size}", "identity_functions=#{IDENTITY_FUNCTIONS.map(&:first).join(',')}",
    "accepted_construction_cases=#{profiles.size}", "native_columns_including_pk=#{native_columns.size}",
    "library_parts_authored=#{profiles.size}", "library_parts_stock_attached_checked=#{profiles.size}",
    "native_stock=5_rows_4_marks_Wide_LZ4", "nullable_null_row=#{NULL_ROW}",
    "stock_windows=full,middle,empty", "exact_temporal_type_names_scale_zone=true",
    "check_valid_mutants=zone_utc_to_berlin,scale_3_to_4,value_lsb_0_to_1",
    "all_mutants_rejected_by_unchanged_original_oracles=true",
    "before_after_runtime_and_source_pins=equal",
  ].join("\n") + "\n"
  write_new(File.join(recorder.evidence, "summary.txt"), summary)
  puts "PASS W170 bounded temporal construction/stock oracle: 36 leaves × 4 identity functions × scalar/Nullable = 288 library parts; stock ATTACH/CHECK and exact full/middle/empty RowBinary; 3 CHECK-valid mutants rejected"
end

begin
  main
rescue W170Failure => error
  warn error.message
  exit 1
end
