#!/usr/bin/env ruby
# Independent stock ClickHouse Wide-part/serialization oracle for W221.
# Leaf witnesses and raw values are declared here rather than imported from
# Crystal production eligibility or support tables. The construction result is
# discovery data: this runner does not assume every candidate is admissible.
require "digest"
require "fileutils"
require "find"
require "json"
require "open3"

STDOUT.sync = true

VERSION = "26.10.1.1201".freeze
BUILD_HASH = "d9bcb5ab007f0f6299f7f973f2642245bab3d028".freeze
EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2".freeze
SOURCE_ROOT = "/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1".freeze
SOURCE_REVISION = "0ca8150d9b1d0886edb2e3b4ab65eebb768d0357".freeze
ROOT_PREFIX = "/private/tmp/crystal-click-w221-physical.".freeze
PROCESS_TIMEOUT_SECONDS = 20
TERM_GRACE_SECONDS = 2
MEMORY_LIMIT_BYTES = 1_073_741_824

TARGET_FUNCTIONS = %w[any_respect_nulls anyLast_respect_nulls].freeze
SHAPES = %w[scalar inner_nullable outer_nullable].freeze
STRING_SERIALIZATION_MODES = %w[single_stream with_size_stream].freeze
KEYS = [11, 22, 33, 44, 55].freeze
NULL_ROW_INDEX = 1

Leaf = Struct.new(:key, :sql, :family, :bits, :signed, :precision, :scale, keyword_init: true)
Profile = Struct.new(:id, :kind, :function, :leaf, :shape, :string_mode, keyword_init: true) do
  def child_type
    shape == "inner_nullable" ? "Nullable(#{leaf.sql})" : leaf.sql
  end

  def aggregate_type
    "SimpleAggregateFunction(#{function}, #{child_type})"
  end

  def declared_type
    shape == "outer_nullable" ? "Nullable(#{aggregate_type})" : aggregate_type
  end

  def nullable_wire?
    shape != "scalar"
  end
end

LEAVES = begin
  leaves = []
  %w[UInt8 UInt16 UInt32 UInt64 UInt128 UInt256].each do |name|
    leaves << Leaf.new(key: name.downcase, sql: name, family: :integer,
      bits: name.delete_prefix("UInt").to_i, signed: false)
  end
  %w[Int8 Int16 Int32 Int64 Int128 Int256].each do |name|
    leaves << Leaf.new(key: name.downcase, sql: name, family: :integer,
      bits: name.delete_prefix("Int").to_i, signed: true)
  end
  leaves.concat([
    Leaf.new(key: "float32", sql: "Float32", family: :float32, bits: 32),
    Leaf.new(key: "float64", sql: "Float64", family: :float64, bits: 64),
    Leaf.new(key: "bfloat16", sql: "BFloat16", family: :bfloat16, bits: 16),
    Leaf.new(key: "string", sql: "String", family: :string),
    Leaf.new(key: "fixedstring3", sql: "FixedString(3)", family: :fixed_string),
  ])
  [[9, 2], [18, 3], [38, 5], [76, 7]].each do |precision, scale|
    bits = precision <= 9 ? 32 : (precision <= 18 ? 64 : (precision <= 38 ? 128 : 256))
    leaves << Leaf.new(key: "decimal_p#{precision}_s#{scale}",
      sql: "Decimal(#{precision}, #{scale})", family: :decimal,
      bits: bits, signed: true, precision: precision, scale: scale)
  end
  leaves.concat([
    Leaf.new(key: "date", sql: "Date", family: :temporal, bits: 16, signed: false),
    Leaf.new(key: "date32", sql: "Date32", family: :temporal, bits: 32, signed: true),
    Leaf.new(key: "time", sql: "Time", family: :temporal, bits: 32, signed: true),
    Leaf.new(key: "time64_s3", sql: "Time64(3)", family: :temporal, bits: 64, signed: true),
    Leaf.new(key: "datetime_utc", sql: "DateTime('UTC')", family: :temporal, bits: 32, signed: false),
    Leaf.new(key: "datetime64_s3_utc", sql: "DateTime64(3, 'UTC')", family: :temporal, bits: 64, signed: true),
    Leaf.new(key: "datetime_long_zone", sql: "DateTime('America/Argentina/ComodRivadavia')",
      family: :temporal, bits: 32, signed: false),
    Leaf.new(key: "datetime64_s3_long_zone",
      sql: "DateTime64(3, 'America/Argentina/ComodRivadavia')",
      family: :temporal, bits: 64, signed: true),
  ])
  raise "W221 physical leaf roster changed: expected 29, got #{leaves.length}" unless leaves.length == 29
  leaves.freeze
end

def require_true(condition, message)
  raise ArgumentError, message unless condition
end

def safe_label(value)
  value.gsub(/[^A-Za-z0-9_.-]/, "_")
end

def write_new(path, bytes)
  File.open(path, "wbx", 0o600) { |file| file.write(bytes) }
rescue Errno::EEXIST
  raise "refusing to overwrite W221 physical evidence: #{path}"
end

def make_dir(path)
  Dir.mkdir(path, 0o700)
rescue Errno::EEXIST
  raise "refusing to reuse W221 physical evidence directory: #{path}"
end

def prepare_root!(argument)
  require_true(argument && argument.match?(/\A#{Regexp.escape(ROOT_PREFIX)}[A-Za-z0-9_-]+\z/),
    "usage: CLICKHOUSE_BIN=/path/to/clickhouse ruby scripts/probe_simple_aggregate_physical_w221.rb #{ROOT_PREFIX}<fresh-leaf>")
  require_true(File.directory?(argument) && !File.symlink?(argument),
    "W221 physical root must be a ROOT-created, real directory: #{argument}")
  root = File.realpath(argument)
  require_true(root == argument && root.start_with?(ROOT_PREFIX),
    "W221 physical root is not the expected direct /private/tmp child")
  require_true(Dir.empty?(root), "refusing to reuse nonempty W221 physical evidence root: #{root}")
  %w[evidence stores parts].each { |name| make_dir(File.join(root, name)) }
  make_dir(File.join(root, "evidence", "processes"))
  make_dir(File.join(root, "evidence", "cases"))
  root
end

def little_integer(value, bits)
  width = bits / 8
  unsigned = value & ((1 << bits) - 1)
  Array.new(width) { |index| (unsigned >> (index * 8)) & 0xff }.pack("C*").b
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

def values_for(leaf)
  case leaf.family
  when :integer, :decimal
    if leaf.family == :decimal
      maximum = (10**leaf.precision) - 1
      [maximum, 1, 0, -maximum, maximum - 17]
    else
      maximum = leaf.signed ? (1 << (leaf.bits - 1)) - 1 : (1 << leaf.bits) - 1
      boundary = leaf.signed ? -(1 << (leaf.bits - 1)) : maximum / 2
      [maximum, 1, 0, boundary, maximum - 17]
    end
  when :temporal
    # Keep raw carriers near the meaningful type boundaries instead of using
    # the much wider backing integer limits (notably Date32/Time64/DateTime64).
    case leaf.key
    when "date"
      [65_535, 1, 0, 32_767, 65_518]
    when "date32"
      # DateLUT interior-edge days: 1901-01-02 through 2298-12-30.
      [-25_201, 1, 0, 120_163, 120_146]
    when "time"
      # Time accepts signed local times through 999:59:59.
      [3_599_999, 1, 0, -3_599_999, 3_599_982]
    when "time64_s3"
      # Same local-time boundary, represented in millisecond ticks.
      [3_599_999_000, 1, 0, -3_599_999_000, 3_599_998_983]
    when "datetime_utc", "datetime_long_zone"
      # DateTime's UInt32 timestamp range, with a UTC/zone-independent low edge.
      [4_294_967_295, 1, 0, 86_400, 4_294_967_278]
    when "datetime64_s3_utc", "datetime64_s3_long_zone"
      # DateTime64(3) values inset one day from the DateLUT's 1900..2299 bounds.
      [10_413_705_599_999, 1, 0, -2_208_902_400_000, 10_413_705_599_982]
    else
      raise "unlisted W221 temporal leaf #{leaf.key.inspect}"
    end
  when :float32
    [3.4028233e38, 1.25, 0.0, -3.4028233e38, 0.5]
  when :float64
    [Float::MAX, 1.25, 0.0, -Float::MAX, 0.5]
  when :bfloat16
    # Exact little-endian BFloat16 bit patterns: max finite, +1, +0, -max, min subnormal.
    [0x7f7f, 0x3f80, 0x0000, 0xff7f, 0x0001]
  when :string
    ["edge\x00\xff".b, "nonnull\x00".b, "".b, "\x00\x7f\x00".b, "tail\x00".b]
  when :fixed_string
    ["\x00\xffA".b, "B\x00C".b, "\x00\x00\x00".b, "abc".b, "\xff\x00Z".b]
  else
    raise "unlisted W221 physical leaf family #{leaf.family.inspect}"
  end
end

def scalar_rowbinary(leaf, value)
  case leaf.family
  when :integer, :decimal, :temporal
    little_integer(value, leaf.bits)
  when :float32
    [value].pack("e").b
  when :float64
    [value].pack("E").b
  when :bfloat16
    [value].pack("S<").b
  when :string
    binary_string(value)
  when :fixed_string
    require_true(value.bytesize == 3, "FixedString(3) fixture value is not three bytes")
    value.b
  else
    raise "unlisted W221 RowBinary family #{leaf.family.inspect}"
  end
end

def rowbinary_value(profile, row_index)
  return "\x01".b if profile.nullable_wire? && row_index == NULL_ROW_INDEX
  value = values_for(profile.leaf).fetch(row_index)
  (profile.nullable_wire? ? "\x00".b : "".b) + scalar_rowbinary(profile.leaf, value)
end

def rowbinary_input(profile)
  output = +"".b
  KEYS.each_index do |row_index|
    output << little_integer(KEYS.fetch(row_index), 64)
    output << rowbinary_value(profile, row_index)
  end
  output
end

def expected_rowbinary(profile, row_indices)
  output = +"".b
  row_indices.each do |row_index|
    output << little_integer(KEYS.fetch(row_index), 64)
    output << rowbinary_value(profile, row_index)
  end
  output
end

def declared_profiles
  profiles = TARGET_FUNCTIONS.flat_map do |function|
    LEAVES.flat_map do |leaf|
      shapes = SHAPES.flat_map do |shape|
        if leaf.family == :string
          STRING_SERIALIZATION_MODES.map do |mode|
            Profile.new(id: "#{function}_#{leaf.key}_#{shape}_#{mode}", kind: "matrix",
              function: function, leaf: leaf, shape: shape, string_mode: mode)
          end
        else
          [Profile.new(id: "#{function}_#{leaf.key}_#{shape}", kind: "matrix",
            function: function, leaf: leaf, shape: shape, string_mode: nil)]
        end
      end
      shapes
    end
  end
  controls = [
    ["min", "uint64"],
    ["sum", "uint64"],
    ["sumWithOverflow", "decimal_p38_s5"],
    ["groupBitAnd", "int32"],
    ["groupBitOr", "int32"],
    ["groupBitXor", "int32"],
  ].map do |function, leaf_key|
    leaf = LEAVES.find { |candidate| candidate.key == leaf_key }
    Profile.new(id: "control_#{function}_#{leaf.key}_inner_nullable", kind: "control",
      function: function, leaf: leaf, shape: "inner_nullable", string_mode: nil)
  end
  profiles + controls
end

STOCK_SETTINGS = [
  "index_granularity=2",
  "index_granularity_bytes=10485760",
  "enable_mixed_granularity_parts=1",
  "min_rows_for_wide_part=0",
  "min_bytes_for_wide_part=0",
  "min_level_for_wide_part=0",
  "compress_marks=0",
  "compress_primary_key=0",
  "min_compress_block_size=0",
  "max_compress_block_size=4096",
  "ratio_of_defaults_for_sparse_serialization=1.0",
  "default_compression_codec='LZ4'",
  "nullable_serialization_version='basic'",
  "serialization_info_version='with_types'",
  "propagate_types_serialization_versions_to_nested_types=1",
].freeze

def table_ddl(profile, table)
  settings = STOCK_SETTINGS.dup
  settings << "string_serialization_version='#{profile.string_mode}'" if profile.string_mode
  "CREATE TABLE default.#{table} (k UInt64, v #{profile.declared_type}) " \
    "ENGINE=MergeTree ORDER BY k SETTINGS #{settings.join(', ')};"
end

def process_status_hash(status, timed_out:, spawn_error: nil, duration_ms:)
  record = {
    "success" => status&.success? || false,
    "exitstatus" => status&.exitstatus,
    "signaled" => status&.signaled? || false,
    "termsig" => status&.termsig,
    "timed_out" => timed_out,
    "duration_ms" => duration_ms,
    "reported_clickhouse_codes" => [],
  }
  record["spawn_error"] = spawn_error if spawn_error
  record
end

def terminate_child!(waiter)
  return unless waiter && waiter.alive?

  begin
    Process.kill("TERM", waiter.pid)
  rescue Errno::ESRCH
    nil
  end
  unless waiter.join(TERM_GRACE_SECONDS)
    begin
      Process.kill("KILL", waiter.pid)
    rescue Errno::ESRCH
      nil
    end
    waiter.join
  end
end

def run_bounded(argv, input: nil)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  stdout_bytes = "".b
  stderr_bytes = "".b
  status = nil
  timed_out = false
  spawn_error = nil
  waiter = nil
  readers = []
  stdin = stdout = stderr = nil

  begin
    # Deliberately inherit the caller's process group; never detach ClickHouse
    # from run_safe. The local timeout signals this child PID, not a new group.
    stdin, stdout, stderr, waiter = Open3.popen3({"TZ" => "UTC"}, *argv)
    stdin.binmode
    stdout.binmode
    stderr.binmode
    readers = [Thread.new { stdout.read }, Thread.new { stderr.read }]
    stdin.write(input.b) if input
    stdin.close

    unless waiter.join(PROCESS_TIMEOUT_SECONDS)
      timed_out = true
      terminate_child!(waiter)
    end
    status = waiter.value
    stdout_bytes = readers[0].value
    stderr_bytes = readers[1].value
  rescue StandardError => error
    spawn_error = "#{error.class}: #{error.message}"
  ensure
    # Reap the direct child on every error path, while leaving group cleanup to
    # the outer guard. Close pipes and drain readers even after an exception.
    terminate_child!(waiter) if waiter && waiter.alive?
    waiter.join if waiter
    [stdin, stdout, stderr].compact.each do |pipe|
      pipe.close unless pipe.closed?
    rescue IOError
      nil
    end
    readers.each(&:join)
  end

  codes = (stdout_bytes + stderr_bytes).scan(
    /(?:^|[^A-Za-z0-9_])Code:[\x09-\x0d\x20]*([0-9]+)(?![A-Za-z0-9_])/n,
  ).flatten.map(&:to_i).uniq
  record = process_status_hash(status, timed_out: timed_out, spawn_error: spawn_error,
    duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
  record["reported_clickhouse_codes"] = codes
  {stdout: stdout_bytes, stderr: stderr_bytes, status: record}
end

def query_argv(binary, store, sql, multiquery: false)
  argv = [binary, "local", "--path", store, "--session_timezone=UTC",
    "--enable_time_time64_type=1", "--max_threads=1", "--max_insert_threads=1",
    "--max_execution_time=15", "--max_memory_usage=#{MEMORY_LIMIT_BYTES}"]
  argv << "--multiquery" if multiquery
  argv.concat(["--query", sql])
end

class Recorder
  attr_reader :root

  def initialize(root, binary)
    @root = root
    @binary = binary
    @sequence = 0
  end

  def run(label, store, sql, input: nil, multiquery: false)
    @sequence += 1
    stem = format("%05d-%s", @sequence, safe_label(label))
    prefix = File.join(@root, "evidence", "processes", stem)
    argv = query_argv(@binary, store, sql, multiquery: multiquery)
    sql_bytes = sql.end_with?("\n") ? sql.b : (sql + "\n").b
    write_new(prefix + ".sql", sql_bytes)
    write_new(prefix + ".argv.json", JSON.pretty_generate({
      "argv" => argv,
      "environment" => {"TZ" => "UTC"},
      "timeout_seconds" => PROCESS_TIMEOUT_SECONDS,
      "stdin_bytes" => input&.bytesize,
      "stdin_sha256" => input && Digest::SHA256.hexdigest(input.b),
    }) + "\n")
    write_new(prefix + ".stdin.bin", input.b) if input

    run = run_bounded(argv, input: input)
    write_new(prefix + ".stdout", run.fetch(:stdout))
    write_new(prefix + ".stderr", run.fetch(:stderr))
    write_new(prefix + ".status.json", JSON.pretty_generate(run.fetch(:status)) + "\n")
    run.merge(prefix: prefix, argv: argv)
  end
end

def type_law_refusal?(status, output)
  codes = status.fetch("reported_clickhouse_codes")
  text = output.force_encoding(Encoding::UTF_8).scrub
  (codes.include?(36) && text.match?(/(?:Incompatible data types between aggregate function|Unsupported aggregate function)/i)) ||
    (codes.include?(43) && text.match?(/(?:Illegal type .* of argument for aggregate function|cannot be used in bitwise operations|Nested type .* cannot be inside Nullable type)/i))
end

def output_excerpt(output)
  output.force_encoding(Encoding::UTF_8).scrub.lines.map(&:strip).reject(&:empty?).first(4).join(" | ")
end

def profile_manifest(profile)
  row_fixtures = KEYS.each_index.map do |row_index|
    is_null = profile.nullable_wire? && row_index == NULL_ROW_INDEX
    value_bytes = rowbinary_value(profile, row_index)
    leaf_bytes = is_null ? nil : scalar_rowbinary(profile.leaf, values_for(profile.leaf).fetch(row_index))
    {
      "key" => KEYS.fetch(row_index),
      "is_null" => is_null,
      "value_rowbinary_hex" => value_bytes.unpack1("H*"),
      "leaf_value_rowbinary_hex" => leaf_bytes&.unpack1("H*"),
    }
  end
  {
    "id" => profile.id,
    "kind" => profile.kind,
    "function" => profile.function,
    "leaf_key" => profile.leaf.key,
    "leaf_type" => profile.leaf.sql,
    "shape" => profile.shape,
    "string_serialization_mode" => profile.string_mode,
    "declared_type" => profile.declared_type,
    "construction_expectation" => "expected_admitted_by_pinned_stock_construction_matrix",
    "row_keys" => KEYS,
    "nullable_row_index" => profile.nullable_wire? ? NULL_ROW_INDEX : nil,
    "rowbinary_values" => row_fixtures,
  }
end

def checked_part_path(path, store, label)
  root = File.realpath(store)
  expanded = File.expand_path(path, store)
  real = File.realpath(expanded)
  require_true(real.start_with?(root + File::SEPARATOR) && real != root,
    "#{label} resolves outside this profile's store: #{real}")
  real
rescue Errno::ENOENT, Errno::EACCES => error
  raise "cannot resolve #{label} safely: #{error.message}"
end

def part_inventory(part)
  files = []
  Find.find(part) do |path|
    next if path == part
    require_true(!File.symlink?(path), "symbolic link in immutable part: #{path}")
    next if File.directory?(path)
    require_true(File.file?(path), "unexpected non-file entry in part: #{path}")
    relative = path.delete_prefix(part + File::SEPARATOR)
    files << {
      "path" => relative,
      "size" => File.size(path),
      "sha256" => Digest::SHA256.file(path).hexdigest,
    }
  end
  files.sort_by { |entry| entry.fetch("path") }
end

def safe_text(path)
  File.binread(path).force_encoding(Encoding::UTF_8).scrub
end

def case_sql(profile, table, case_dir)
  full = File.join(case_dir, "rowbinary-full.bin")
  middle = File.join(case_dir, "rowbinary-middle.bin")
  empty = File.join(case_dir, "rowbinary-empty.bin")
  [full, middle, empty].each do |path|
    require_true(!File.exist?(path) && !File.symlink?(path), "refusing to overwrite RowBinary output #{path}")
  end
  escape = ->(path) { path.gsub("'", "\\'") }
  [
    "SELECT '__W221_SCHEMA__', name, type, toString(position) FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;",
    "SELECT '__W221_RUNTIME_TYPE__', toTypeName(k), toTypeName(v) FROM default.#{table} LIMIT 1 FORMAT TSVRaw;",
    "SELECT '__W221_DATA_PATH__', data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw;",
    "SELECT '__W221_PART__', name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;",
    "CHECK TABLE default.#{table} FORMAT TabSeparated;",
    "SELECT k, v FROM default.#{table} ORDER BY k INTO OUTFILE '#{escape.call(full)}' FORMAT RowBinary;",
    "SELECT k, v FROM default.#{table} WHERE k BETWEEN 22 AND 44 ORDER BY k INTO OUTFILE '#{escape.call(middle)}' FORMAT RowBinary;",
    "SELECT k, v FROM default.#{table} WHERE k=0 ORDER BY k INTO OUTFILE '#{escape.call(empty)}' FORMAT RowBinary;",
  ].join("\n") + "\n"
end

def tagged_rows(stdout, tag)
  stdout.force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp).map do |line|
    fields = line.split("\t", -1)
    fields if fields.first == tag
  end.compact
end

def compare_binary(actual, expected, label)
  return nil if actual.b == expected.b
  shared = [actual.bytesize, expected.bytesize].min
  mismatch = (0...shared).find { |index| actual.getbyte(index) != expected.getbyte(index) } || shared
  wanted = mismatch < expected.bytesize ? expected.getbyte(mismatch).to_s(16).rjust(2, "0") : "<eof>"
  observed = mismatch < actual.bytesize ? actual.getbyte(mismatch).to_s(16).rjust(2, "0") : "<eof>"
  "#{label} differs: expected #{expected.bytesize} bytes, observed #{actual.bytesize}; byte #{mismatch}: expected #{wanted}, got #{observed}"
end

def inspect_physical!(profile, root, store, record, case_dir)
  stdout = record.fetch(:stdout)
  schema_rows = tagged_rows(stdout, "__W221_SCHEMA__")
  expected_schema = [
    ["__W221_SCHEMA__", "k", "UInt64", "1"],
    ["__W221_SCHEMA__", "v", profile.declared_type, "2"],
  ]
  require_true(schema_rows == expected_schema,
    "system.columns exact native type differs: #{schema_rows.inspect}")

  type_rows = tagged_rows(stdout, "__W221_RUNTIME_TYPE__")
  require_true(type_rows == [["__W221_RUNTIME_TYPE__", "UInt64", profile.declared_type]],
    "toTypeName runtime type differs: #{type_rows.inspect}")
  data_rows = tagged_rows(stdout, "__W221_DATA_PATH__")
  part_rows = tagged_rows(stdout, "__W221_PART__")
  require_true(data_rows.length == 1 && data_rows.first.length == 2 && !data_rows.first[1].empty?,
    "system.tables data path is missing or ambiguous: #{data_rows.inspect}")
  require_true(part_rows.length == 1 && part_rows.first.length == 6,
    "expected one active source part, got #{part_rows.inspect}")
  part_name, rows_text, marks_text, part_type, part_path_text = part_rows.first.drop(1)
  require_true(part_name == "all_1_1_0", "unexpected immutable part name #{part_name.inspect}")
  require_true(rows_text == "5", "source part row count differs: #{rows_text.inspect}")
  require_true(marks_text == "4", "index_granularity=2 mark count differs: #{marks_text.inspect}")
  require_true(part_type == "Wide", "source part is not Wide: #{part_type.inspect}")
  check_rows = stdout.force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp).select do |line|
    line.start_with?("all_1_1_0\t")
  end
  require_true(check_rows == ["all_1_1_0\t1\t"], "CHECK TABLE did not report a clean part: #{check_rows.inspect}")

  data_path = checked_part_path(data_rows.first[1], store, "table data path")
  part_path = checked_part_path(part_path_text, store, "active part path")
  require_true(part_path.start_with?(data_path + File::SEPARATOR),
    "active part is outside the discovered table data path: #{part_path}")
  require_true(File.basename(part_path) == "all_1_1_0", "part path basename differs: #{part_path}")

  files = part_inventory(part_path)
  names = files.map { |entry| entry.fetch("path") }
  required_metadata = %w[columns.txt columns_substreams.txt count.txt checksums.txt serialization.json default_compression_codec.txt metadata_version.txt primary.idx]
  missing = required_metadata - names
  require_true(missing.empty?, "Wide part metadata roster is missing #{missing.inspect}")
  require_true(names.any? { |name| name.end_with?(".mrk2") }, "Wide part contains no plain .mrk2 mark stream")
  require_true(names.grep(/\.mrk(?:\.|\z)/).empty?, "Wide part contains non-mrk2 mark stream files")

  columns_text = safe_text(File.join(part_path, "columns.txt"))
  expected_columns_text = "columns format version: 1\n2 columns:\n`k` UInt64\n`v` #{profile.declared_type}\n"
  require_true(columns_text == expected_columns_text,
    "columns.txt differs from the exact native declarations: #{columns_text.inspect}")
  substreams_text = safe_text(File.join(part_path, "columns_substreams.txt"))
  serialization_text = safe_text(File.join(part_path, "serialization.json"))
  serialization = JSON.parse(serialization_text)
  codec_text = safe_text(File.join(part_path, "default_compression_codec.txt")).strip
  metadata_version = safe_text(File.join(part_path, "metadata_version.txt")).strip
  count_text = safe_text(File.join(part_path, "count.txt")).strip
  checksums_text = safe_text(File.join(part_path, "checksums.txt"))
  require_true(codec_text == "CODEC(LZ4)", "default part compression codec differs: #{codec_text.inspect}")
  require_true(count_text == "5", "count.txt differs from the five-row fixture: #{count_text.inspect}")

  copied_parent = File.join(root, "parts", profile.id)
  make_dir(copied_parent)
  copied_part = File.join(copied_parent, "all_1_1_0")
  require_true(!File.exist?(copied_part) && !File.symlink?(copied_part), "refusing to overwrite copied part")
  FileUtils.cp_r(part_path, copied_part)
  require_true(part_inventory(copied_part) == files, "copied immutable part differs from source snapshot")

  outputs = {
    "full" => [(0...KEYS.size).to_a, "rowbinary-full.bin"],
    "middle" => [[1, 2, 3], "rowbinary-middle.bin"],
    "empty" => [[], "rowbinary-empty.bin"],
  }
  rowbinary_records = {}
  mismatches = []
  outputs.each do |window, (indices, filename)|
    path = File.join(case_dir, filename)
    require_true(File.file?(path) && !File.symlink?(path), "ClickHouse did not create #{filename}")
    observed = File.binread(path)
    expected = expected_rowbinary(profile, indices)
    mismatch = compare_binary(observed, expected, "#{window} RowBinary")
    mismatches << mismatch if mismatch
    rowbinary_records[window] = {
      "path" => path.delete_prefix(root + File::SEPARATOR),
      "bytes" => observed.bytesize,
      "sha256" => Digest::SHA256.hexdigest(observed),
      "expected_bytes" => expected.bytesize,
      "expected_sha256" => Digest::SHA256.hexdigest(expected),
      "matches_independent_literal" => mismatch.nil?,
    }
  end
  require_true(mismatches.empty?, mismatches.join("; "))

  {
    "part_name" => part_name,
    "rows" => rows_text.to_i,
    "marks" => marks_text.to_i,
    "part_type" => part_type,
    "data_path" => data_path,
    "part_path" => part_path,
    "copied_part_path" => copied_part,
    "part_file_inventory" => files,
    "columns_txt" => columns_text,
    "columns_substreams_txt" => substreams_text,
    "serialization_json_text" => serialization_text,
    "serialization_json" => serialization,
    "checksums_txt" => checksums_text,
    "checksums_sha256" => Digest::SHA256.hexdigest(checksums_text.b),
    "default_compression_codec_txt" => codec_text,
    "metadata_version_txt" => metadata_version,
    "count_txt" => count_text,
    "rowbinary" => rowbinary_records,
  }
end

def run_case(profile, root, recorder)
  case_dir = File.join(root, "evidence", "cases", safe_label(profile.id))
  make_dir(case_dir)
  store = File.join(root, "stores", safe_label(profile.id))
  make_dir(store)
  table = "saf_w221_#{safe_label(profile.id)}"
  result = profile_manifest(profile).merge("classification" => "pending", "processes" => {})

  create = recorder.run("#{profile.id}-create", store, table_ddl(profile, table))
  result["processes"]["create"] = create.fetch(:prefix).delete_prefix(root + File::SEPARATOR)
  status = create.fetch(:status)
  unless status.fetch("success") && !status.fetch("timed_out") && !status["spawn_error"] && !status.fetch("signaled")
    output = create.fetch(:stdout) + create.fetch(:stderr)
    if !status.fetch("timed_out") && !status["spawn_error"] && !status.fetch("signaled") &&
        type_law_refusal?(status, output)
      result["classification"] = "observed_type_refusal"
      result["refusal_codes"] = status.fetch("reported_clickhouse_codes")
      result["diagnostic_excerpt"] = output_excerpt(output)
    else
      result["classification"] = "probe_failure"
      result["failure"] = status["spawn_error"] || (status.fetch("timed_out") ? "bounded create timeout" :
        "nonzero/signaled CREATE without a specific type-law diagnostic")
      result["failure_excerpt"] = output_excerpt(output)
    end
    write_new(File.join(case_dir, "case.json"), JSON.pretty_generate(result) + "\n")
    return result
  end

  input = rowbinary_input(profile)
  insert_sql = "INSERT INTO default.#{table} FORMAT RowBinary"
  insert = recorder.run("#{profile.id}-insert-rowbinary", store, insert_sql, input: input)
  result["processes"]["insert"] = insert.fetch(:prefix).delete_prefix(root + File::SEPARATOR)
  write_new(File.join(case_dir, "rowbinary-input.bin"), input)
  input_metadata = {
    "path" => File.join("evidence", "cases", safe_label(profile.id), "rowbinary-input.bin"),
    "bytes" => input.bytesize,
    "sha256" => Digest::SHA256.hexdigest(input),
  }
  result["rowbinary_input"] = input_metadata
  unless insert.fetch(:status).fetch("success") && !insert.fetch(:status).fetch("timed_out") &&
      !insert.fetch(:status)["spawn_error"] && !insert.fetch(:status).fetch("signaled")
    result["classification"] = "probe_failure"
    result["failure"] = "RowBinary INSERT failed; this is not classified as a construction refusal"
    result["failure_excerpt"] = output_excerpt(insert.fetch(:stdout) + insert.fetch(:stderr))
    write_new(File.join(case_dir, "case.json"), JSON.pretty_generate(result) + "\n")
    return result
  end

  inspection_sql = case_sql(profile, table, case_dir)
  inspect = recorder.run("#{profile.id}-inspect", store, inspection_sql, multiquery: true)
  result["processes"]["inspect"] = inspect.fetch(:prefix).delete_prefix(root + File::SEPARATOR)
  unless inspect.fetch(:status).fetch("success") && !inspect.fetch(:status).fetch("timed_out") &&
      !inspect.fetch(:status)["spawn_error"] && !inspect.fetch(:status).fetch("signaled")
    result["classification"] = "probe_failure"
    result["failure"] = "metadata/RowBinary inspection process failed"
    result["failure_excerpt"] = output_excerpt(inspect.fetch(:stdout) + inspect.fetch(:stderr))
    write_new(File.join(case_dir, "case.json"), JSON.pretty_generate(result) + "\n")
    return result
  end

  begin
    result["physical"] = inspect_physical!(profile, root, store, inspect, case_dir)
    result["classification"] = "physical_observed"
  rescue StandardError => error
    result["classification"] = "physical_mismatch"
    result["failure"] = "#{error.class}: #{error.message}"
  end
  write_new(File.join(case_dir, "case.json"), JSON.pretty_generate(result) + "\n")
  result
rescue StandardError => error
  result ||= profile_manifest(profile).merge("processes" => {})
  result["classification"] = "probe_failure"
  result["failure"] = "#{error.class}: #{error.message}"
  case_dir ||= File.join(root, "evidence", "cases", safe_label(profile.id))
  write_new(File.join(case_dir, "case.json"), JSON.pretty_generate(result) + "\n") if
    File.directory?(case_dir) && !File.exist?(File.join(case_dir, "case.json"))
  result
end

def pin_runtime!(root, recorder, binary)
  require_true(File.file?(binary) && File.executable?(binary) && !File.symlink?(binary),
    "CLICKHOUSE_BIN is absent, non-executable, or a symlink: #{binary}")
  sha256 = Digest::SHA256.file(binary).hexdigest
  require_true(sha256 == EXECUTABLE_SHA256, "ClickHouse executable SHA-256 mismatch: #{sha256}")
  pin_store = File.join(root, "stores", "pins")
  make_dir(pin_store)
  version_record = recorder.run("pin-version", pin_store, "SELECT version() FORMAT TSVRaw")
  require_true(version_record.dig(:status, "success") && !version_record.dig(:status, "timed_out"),
    "pinned ClickHouse version query failed")
  version = version_record.fetch(:stdout).strip
  require_true(version == VERSION, "ClickHouse version mismatch: #{version.inspect}")
  build_record = recorder.run("pin-build", pin_store,
    "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw")
  require_true(build_record.dig(:status, "success") && !build_record.dig(:status, "timed_out"),
    "pinned ClickHouse build query failed")
  build = build_record.fetch(:stdout).strip
  require_true(build == "VERSION_GITHASH=#{BUILD_HASH}", "ClickHouse build hash mismatch: #{build.inspect}")
  pin = {
    "runtime_version" => version,
    "runtime_sha256" => sha256,
    "runtime_build_hash" => BUILD_HASH,
    "source_snapshot" => "#{SOURCE_ROOT}@#{SOURCE_REVISION}",
    "source_snapshot_is_separate_from_runtime_build_identity" => true,
    "runtime_built_from_source_snapshot_is_not_asserted" => true,
  }
  write_new(File.join(root, "runtime_pin.json"), JSON.pretty_generate(pin) + "\n")
  pin
end

def main
  root = prepare_root!(ARGV.fetch(0, nil))
  binary = ENV.fetch("CLICKHOUSE_BIN")
  profiles = declared_profiles
  manifest = {
    "suite" => "W221 independent SimpleAggregateFunction physical metadata/RowBinary probe",
    "source_snapshot" => "#{SOURCE_ROOT}@#{SOURCE_REVISION}",
    "runtime_pin_expected" => {"version" => VERSION, "build_hash" => BUILD_HASH, "sha256" => EXECUTABLE_SHA256},
    "source_snapshot_is_not_asserted_to_build_runtime" => true,
    "target_functions" => TARGET_FUNCTIONS,
    "leaf_count" => LEAVES.length,
    "leaf_witnesses" => LEAVES.map { |leaf| {"key" => leaf.key, "sql" => leaf.sql, "family" => leaf.family.to_s} },
    "shapes" => SHAPES,
    "string_serialization_modes" => STRING_SERIALIZATION_MODES,
    "control_types" => [
      "SimpleAggregateFunction(min, Nullable(UInt64))",
      "SimpleAggregateFunction(sum, Nullable(UInt64))",
      "SimpleAggregateFunction(sumWithOverflow, Nullable(Decimal(38, 5)))",
      "SimpleAggregateFunction(groupBitAnd, Nullable(Int32))",
      "SimpleAggregateFunction(groupBitOr, Nullable(Int32))",
      "SimpleAggregateFunction(groupBitXor, Nullable(Int32))",
    ],
    "case_count" => profiles.length,
    "stock_construction_law" => {
      "total_cases" => 1283,
      "accepted" => 717,
      "refused" => 566,
      "result_mismatches" => 0,
      "probe_failures" => 0,
      "selected_physical_products_expected_admitted" => profiles.length,
    },
    "construction_expectations" => "all selected physical products are expected to construct; specific ClickHouse type-law refusals remain classified separately and count as admission mismatches",
    "rows" => {"keys" => KEYS, "row_count" => KEYS.size, "nullable_row_index" => NULL_ROW_INDEX,
      "index_granularity" => 2, "expected_wide_part_rows" => 5, "expected_marks_from_w170_profile" => 4},
    "table_settings" => STOCK_SETTINGS,
    "process_timeout_seconds" => PROCESS_TIMEOUT_SECONDS,
    "child_process_group" => "inherited from caller; per-child TERM/KILL targets positive pid",
  }
  write_new(File.join(root, "manifest.json"), JSON.pretty_generate(manifest) + "\n")
  recorder = Recorder.new(root, binary)
  begin
    pin = pin_runtime!(root, recorder, binary)
  rescue StandardError => error
    write_new(File.join(root, "fatal.json"), JSON.pretty_generate({
      "phase" => "runtime_pin", "error" => "#{error.class}: #{error.message}", "cases_started" => 0,
    }) + "\n")
    warn "W221 physical probe refused to interpret stock outcomes: #{error.message}"
    return 2
  end

  results = []
  profiles.each_with_index do |profile, index|
    puts "W221 physical case #{index + 1}/#{profiles.length}: #{profile.id}"
    results << run_case(profile, root, recorder)
  end
  failures = results.select do |result|
    %w[probe_failure physical_mismatch observed_type_refusal].include?(result.fetch("classification"))
  end
  summary = {
    "suite" => manifest.fetch("suite"),
    "runtime_pin" => pin,
    "case_count" => results.length,
    "physical_observed" => results.count { |result| result.fetch("classification") == "physical_observed" },
    "observed_type_refusals" => results.count { |result| result.fetch("classification") == "observed_type_refusal" },
    "admission_mismatches" => results.count { |result| result.fetch("classification") == "observed_type_refusal" },
    "probe_failures" => results.count { |result| result.fetch("classification") == "probe_failure" },
    "physical_mismatches" => results.count { |result| result.fetch("classification") == "physical_mismatch" },
    "matrix" => results,
  }
  write_new(File.join(root, "matrix.json"), JSON.pretty_generate(summary) + "\n")
  puts "W221 physical matrix=#{File.join(root, 'matrix.json')} cases=#{results.length} " \
    "physical=#{summary.fetch('physical_observed')} type_refusals=#{summary.fetch('observed_type_refusals')} " \
    "failures=#{failures.length}"
  failures.empty? ? 0 : 1
end

exit(main)
