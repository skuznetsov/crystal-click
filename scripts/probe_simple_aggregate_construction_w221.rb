#!/usr/bin/env ruby
# Independent pinned-ClickHouse construction oracle for W221.
# Expected type laws and scalar leaves are authored here from the pinned
# ClickHouse implementation, not imported from Crystal eligibility/support data.
require "digest"
require "fileutils"
require "json"
require "open3"

STDOUT.sync = true

VERSION = "26.10.1.1201".freeze
BUILD_HASH = "d9bcb5ab007f0f6299f7f973f2642245bab3d028".freeze
EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2".freeze
SOURCE_ROOT = "/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1".freeze
SOURCE_REVISION = "0ca8150d9b1d0886edb2e3b4ab65eebb768d0357".freeze
ROOT_PREFIX = "/private/tmp/crystal-click-w221.".freeze
PROCESS_TIMEOUT_SECONDS = 15
TERM_GRACE_SECONDS = 2

# The nine previously covered canonical functions plus the two null-respecting
# variants admitted by DataTypeCustomSimpleAggregateFunction in the pinned CH.
FUNCTIONS = %w[
  any anyLast min max sum sumWithOverflow groupBitAnd groupBitOr groupBitXor
  any_respect_nulls anyLast_respect_nulls
].freeze

NUMERIC_TYPES = %w[
  UInt8 UInt16 UInt32 UInt64 UInt128 UInt256
  Int8 Int16 Int32 Int64 Int128 Int256
  Float32 Float64 BFloat16
].freeze
INTEGER_TYPES = %w[
  UInt8 UInt16 UInt32 UInt64 UInt128 UInt256
  Int8 Int16 Int32 Int64 Int128 Int256
].freeze

Leaf = Struct.new(:key, :sql, :family, keyword_init: true)

LEAVES = begin
  leaves = NUMERIC_TYPES.map { |name| Leaf.new(key: name.downcase, sql: name, family: :numeric) }
  leaves.concat([
    Leaf.new(key: "string", sql: "String", family: :identity_only),
    Leaf.new(key: "fixedstring3", sql: "FixedString(3)", family: :identity_only),
  ])
  [[9, 2], [18, 3], [38, 5], [76, 7]].each do |precision, scale|
    leaves << Leaf.new(key: "decimal_p#{precision}_s#{scale}",
      sql: "Decimal(#{precision}, #{scale})", family: :decimal)
  end
  [
    ["date", "Date"],
    ["date32", "Date32"],
    ["time", "Time"],
    ["time64_s3", "Time64(3)"],
    ["datetime_utc", "DateTime('UTC')"],
    ["datetime64_s3_utc", "DateTime64(3, 'UTC')"],
    ["datetime_long_zone", "DateTime('America/Argentina/ComodRivadavia')"],
    ["datetime64_s3_long_zone", "DateTime64(3, 'America/Argentina/ComodRivadavia')"],
  ].each do |key, sql|
    leaves << Leaf.new(key: key, sql: sql, family: :temporal)
  end
  raise "W221 scalar roster changed: expected 29, got #{leaves.length}" unless leaves.length == 29
  leaves.freeze
end

SHAPES = %w[scalar inner_nullable outer_nullable double_nullable].freeze

# `sum` uses NearestFieldType for numeric leaves and widens Decimal32/64 to
# Decimal128; Decimal128/256 keep their physical width and scale. The other
# functions below either return the input type exactly or are unsupported for
# the independently listed leaf family.
SUM_NUMERIC_RESULT = {
  "UInt8" => "UInt64", "UInt16" => "UInt64", "UInt32" => "UInt64",
  "UInt64" => "UInt64", "UInt128" => "UInt128", "UInt256" => "UInt256",
  "Int8" => "Int64", "Int16" => "Int64", "Int32" => "Int64",
  "Int64" => "Int64", "Int128" => "Int128", "Int256" => "Int256",
  "Float32" => "Float64", "Float64" => "Float64", "BFloat16" => "Float64",
}.freeze

IDENTITY_FUNCTIONS = %w[any anyLast min max any_respect_nulls anyLast_respect_nulls].freeze
BITWISE_FUNCTIONS = %w[groupBitAnd groupBitOr groupBitXor].freeze

def require_true(condition, message)
  raise ArgumentError, message unless condition
end

def safe_label(value)
  value.gsub(/[^A-Za-z0-9_.-]/, "_")
end

def write_new(path, bytes)
  File.open(path, "wbx", 0o600) { |file| file.write(bytes) }
rescue Errno::EEXIST
  raise "refusing to overwrite W221 evidence: #{path}"
end

def make_dir(path)
  Dir.mkdir(path, 0o700)
rescue Errno::EEXIST
  raise "refusing to reuse W221 evidence directory: #{path}"
end

def prepare_root!(argument)
  require_true(argument && argument.match?(/\A#{Regexp.escape(ROOT_PREFIX)}[A-Za-z0-9_-]+\z/),
    "usage: CLICKHOUSE_BIN=/path/to/clickhouse ruby scripts/probe_simple_aggregate_construction_w221.rb #{ROOT_PREFIX}<fresh-leaf>")
  require_true(File.directory?(argument) && !File.symlink?(argument),
    "W221 root must be a ROOT-created, real directory: #{argument}")
  root = File.realpath(argument)
  require_true(root == argument && root.start_with?(ROOT_PREFIX), "W221 root is not the expected direct /private/tmp child")
  require_true(Dir.empty?(root), "refusing to reuse nonempty W221 evidence root: #{root}")
  %w[evidence stores].each { |name| make_dir(File.join(root, name)) }
  root
end

def process_status_hash(status, timed_out:, spawn_error: nil, duration_ms:)
  out = {
    "success" => status&.success? || false,
    "exitstatus" => status&.exitstatus,
    "signaled" => status&.signaled? || false,
    "termsig" => status&.termsig,
    "timed_out" => timed_out,
    "duration_ms" => duration_ms,
    "reported_clickhouse_codes" => [],
  }
  out["spawn_error"] = spawn_error if spawn_error
  out
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

def run_bounded(argv, timeout_seconds: PROCESS_TIMEOUT_SECONDS)
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
    # Inherit the caller's process group so the outer run_safe guard can stop
    # this Ruby process and every ClickHouse child together.
    Open3.popen3({"TZ" => "UTC"}, *argv) do |child_stdin, child_stdout, child_stderr, child_waiter|
      stdin = child_stdin
      stdout = child_stdout
      stderr = child_stderr
      waiter = child_waiter
      stdin.close
      readers = [
        Thread.new { stdout.binmode; stdout.read },
        Thread.new { stderr.binmode; stderr.read },
      ]
      deadline = started + timeout_seconds
      loop do
        break if waiter.join(0)
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break if remaining.positive? && waiter.join([0.1, remaining].min)
        next if remaining.positive?

        timed_out = true
        terminate_child!(waiter)
        break
      end
      status = waiter.value
      stdout_bytes = readers[0].value
      stderr_bytes = readers[1].value
    end
  rescue StandardError => error
    spawn_error = "#{error.class}: #{error.message}"
  ensure
    # If anything fails after spawn (including a reader error), stop and reap
    # the one child before returning its failure as probe evidence. Do not kill
    # a process group here: the outer guard owns that boundary.
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
    "--enable_time_time64_type=1", "--max_threads=1", "--max_execution_time=10",
    "--max_memory_usage=536870912"]
  argv << "--multiquery" if multiquery
  argv.concat(["--query", sql])
end

def record_process(root, binary, label, sql, multiquery: false)
  stem = safe_label(label)
  evidence = File.join(root, "evidence", stem)
  store = File.join(root, "stores", stem)
  make_dir(store)
  argv = query_argv(binary, store, sql, multiquery: multiquery)
  write_new(evidence + ".sql", (sql.end_with?("\n") ? sql : sql + "\n").b)
  write_new(evidence + ".argv.json", JSON.pretty_generate({
    "argv" => argv,
    "environment" => {"TZ" => "UTC"},
    "timeout_seconds" => PROCESS_TIMEOUT_SECONDS,
  }) + "\n")
  run = run_bounded(argv)
  write_new(evidence + ".stdout", run.fetch(:stdout))
  write_new(evidence + ".stderr", run.fetch(:stderr))
  write_new(evidence + ".status.json", JSON.pretty_generate(run.fetch(:status)) + "\n")
  run.merge(evidence: evidence, argv: argv)
end

def pin_runtime!(root, binary)
  require_true(File.file?(binary) && File.executable?(binary) && !File.symlink?(binary),
    "CLICKHOUSE_BIN is absent, non-executable, or a symlink: #{binary}")
  sha256 = Digest::SHA256.file(binary).hexdigest
  require_true(sha256 == EXECUTABLE_SHA256, "ClickHouse executable SHA-256 mismatch: #{sha256}")

  version_record = record_process(root, binary, "pin_version", "SELECT version() FORMAT TSVRaw")
  require_true(version_record.dig(:status, "success") && !version_record.dig(:status, "timed_out"),
    "pinned ClickHouse version query failed; see #{version_record[:evidence]}")
  version = version_record.fetch(:stdout).strip
  require_true(version == VERSION, "ClickHouse version mismatch: #{version.inspect}")

  build_record = record_process(root, binary, "pin_build", "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw")
  require_true(build_record.dig(:status, "success") && !build_record.dig(:status, "timed_out"),
    "pinned ClickHouse build query failed; see #{build_record[:evidence]}")
  build = build_record.fetch(:stdout).strip
  require_true(build == "VERSION_GITHASH=#{BUILD_HASH}", "ClickHouse build hash mismatch: #{build.inspect}")

  pin = {
    "runtime_version" => version,
    "runtime_sha256" => sha256,
    "runtime_build_hash" => BUILD_HASH,
    "source_reference" => "#{SOURCE_ROOT}@#{SOURCE_REVISION}",
    "source_is_not_asserted_to_build_runtime" => true,
  }
  write_new(File.join(root, "runtime_pin.json"), JSON.pretty_generate(pin) + "\n")
  pin
end

def source_law(function, leaf)
  if IDENTITY_FUNCTIONS.include?(function)
    return {accepted: true, reason: "function result is the input type"}
  end

  if function == "sum"
    result = if leaf.family == :numeric
               SUM_NUMERIC_RESULT.fetch(leaf.sql)
             elsif leaf.family == :decimal
               precision, scale = leaf.sql.scan(/\d+/).map(&:to_i)
               result_precision = precision <= 18 ? 38 : precision
               "Decimal(#{result_precision}, #{scale})"
             end
    return {accepted: false, refusal: :illegal_type,
      reason: "sum has no supported numeric/decimal overload for #{leaf.sql}"} unless result
    return {accepted: true, reason: "sum result equals storage type"} if result == leaf.sql
    return {accepted: false, refusal: :result_mismatch,
      reason: "sum result #{result} differs from storage type #{leaf.sql}"}
  end

  if function == "sumWithOverflow"
    return {accepted: true, reason: "same-type numeric/decimal sum result"} if %i[numeric decimal].include?(leaf.family)
    return {accepted: false, refusal: :illegal_type,
      reason: "sumWithOverflow has no numeric/decimal overload for #{leaf.sql}"}
  end

  if BITWISE_FUNCTIONS.include?(function)
    return {accepted: true, reason: "integer overload returns the input type"} if INTEGER_TYPES.include?(leaf.sql)
    return {accepted: false, refusal: :illegal_type,
      reason: "bitwise aggregates are implemented for integer types only"}
  end

  raise "unlisted W221 canonical function #{function.inspect}"
end

def aggregate_type(function, leaf_sql)
  "SimpleAggregateFunction(#{function}, #{leaf_sql})"
end

def declared_type(function, leaf, shape)
  inner_leaf = shape == "inner_nullable" || shape == "double_nullable" ? "Nullable(#{leaf.sql})" : leaf.sql
  inner = aggregate_type(function, inner_leaf)
  shape == "outer_nullable" || shape == "double_nullable" ? "Nullable(#{inner})" : inner
end

def shape_law(function, leaf, shape)
  inner_law = source_law(function, leaf)
  return inner_law unless inner_law[:accepted]
  return inner_law unless %w[outer_nullable double_nullable].include?(shape)

  if shape == "outer_nullable"
    {accepted: true, reason: "scalar SAF storage type can be wrapped in Nullable"}
  else
    {accepted: false, refusal: :double_nullable,
      reason: "Nullable cannot wrap an already-Nullable SAF storage type"}
  end
end

def refusal_expectation(law, function, leaf, shape)
  case law.fetch(:refusal)
  when :result_mismatch
    {"code" => 36, "pattern" => "Incompatible data types between aggregate function"}
  when :illegal_type
    {"code" => 43, "pattern" => "(?:Illegal type .* of argument for aggregate function|cannot be used in bitwise operations)"}
  when :double_nullable
    {"code" => 43, "pattern" => "Nested type SimpleAggregateFunction.*cannot be inside Nullable type"}
  else
    raise "unmapped refusal for #{function} #{leaf.sql} #{shape}: #{law.inspect}"
  end
end

def matrix_cases
  FUNCTIONS.flat_map do |function|
    LEAVES.flat_map do |leaf|
      SHAPES.map do |shape|
        law = shape_law(function, leaf, shape)
        expected_type = law[:accepted] ? declared_type(function, leaf, shape) : nil
        {
          "id" => safe_label("#{function}_#{leaf.key}_#{shape}"),
          "kind" => "matrix",
          "function" => function,
          "leaf" => leaf.sql,
          "leaf_key" => leaf.key,
          "shape" => shape,
          "declared_type" => declared_type(function, leaf, shape),
          "expected" => law[:accepted] ? "accepted" : "refused",
          "expected_type" => expected_type,
          "law_reason" => law.fetch(:reason),
          "refusal" => law[:accepted] ? nil : refusal_expectation(law, function, leaf, shape),
        }
      end
    end
  end
end

def control_cases
  [
    {
      "id" => "control_result_widening_sum_uint8", "kind" => "control",
      "declared_type" => "SimpleAggregateFunction(sum, UInt8)", "expected" => "refused",
      "law_reason" => "sum(UInt8) returns UInt64, not UInt8",
      "refusal" => {"code" => 36, "pattern" => "Incompatible data types between aggregate function"},
    },
    {
      "id" => "control_result_widening_sum_decimal18", "kind" => "control",
      "declared_type" => "SimpleAggregateFunction(sum, Decimal(18, 3))", "expected" => "refused",
      "law_reason" => "sum(Decimal(18, 3)) returns Decimal(38, 3), not Decimal(18, 3)",
      "refusal" => {"code" => 36, "pattern" => "Incompatible data types between aggregate function"},
    },
    {
      "id" => "control_disallowed_function_avg", "kind" => "control",
      "declared_type" => "SimpleAggregateFunction(avg, UInt8)", "expected" => "refused",
      "law_reason" => "avg is not in the SimpleAggregateFunction supported-function allowlist",
      "refusal" => {"code" => 36, "pattern" => "Unsupported aggregate function avg"},
    },
    {
      "id" => "control_function_parameters", "kind" => "control",
      "declared_type" => "SimpleAggregateFunction(any(1), UInt8)", "expected" => "refused",
      "law_reason" => "any rejects parameters before SAF result-type qualification",
      "refusal" => {"code" => 133, "pattern" => "Aggregate function any cannot have parameters"},
    },
    {
      "id" => "control_alias_any_value", "kind" => "control",
      "declared_type" => "SimpleAggregateFunction(any_value, UInt8)", "expected" => "accepted",
      "expected_type" => "SimpleAggregateFunction(any, UInt8)",
      "law_reason" => "any_value resolves to canonical any",
    },
    {
      "id" => "control_alias_first_value_respect_nulls", "kind" => "control",
      "declared_type" => "SimpleAggregateFunction(firstValueRespectNulls, Nullable(UInt8))", "expected" => "accepted",
      "expected_type" => "SimpleAggregateFunction(any_respect_nulls, Nullable(UInt8))",
      "law_reason" => "firstValueRespectNulls resolves to canonical any_respect_nulls",
    },
    {
      "id" => "control_alias_bit_or", "kind" => "control",
      "declared_type" => "SimpleAggregateFunction(BIT_OR, UInt8)", "expected" => "accepted",
      "expected_type" => "SimpleAggregateFunction(groupBitOr, UInt8)",
      "law_reason" => "BIT_OR resolves to canonical groupBitOr",
    },
  ].freeze
end

def create_describe_sql(type)
  "CREATE TABLE x (v #{type}) ENGINE=Memory;\nDESCRIBE TABLE x FORMAT TSVRaw"
end

def described_type(stdout)
  rows = stdout.force_encoding(Encoding::UTF_8).scrub.split(/\r?\n/).reject(&:empty?)
  row = rows.find { |line| line.start_with?("v\t") }
  return nil unless row
  fields = row.split("\t", -1)
  fields[1]
end

def known_type_refusal?(codes, output)
  text = output.force_encoding(Encoding::UTF_8).scrub
  (codes.include?(36) && text.match?(/(?:Incompatible data types between aggregate function|Unsupported aggregate function)/)) ||
    (codes.include?(43) && text.match?(/(?:Illegal type .* of argument for aggregate function|cannot be used in bitwise operations|Nested type .* cannot be inside Nullable type)/i)) ||
    (codes.include?(133) && text.match?(/Aggregate function .* cannot have parameters/))
end

def classify(test_case, run)
  status = run.fetch(:status)
  output = run.fetch(:stdout) + run.fetch(:stderr)
  return ["probe_failure", "bounded timeout"] if status.fetch("timed_out")
  return ["probe_failure", status.fetch("spawn_error")] if status["spawn_error"]
  return ["probe_failure", "process was signaled"] if status.fetch("signaled")

  if status.fetch("success")
    observed_type = described_type(run.fetch(:stdout))
    return ["probe_failure", "successful process did not produce a DESCRIBE row"] unless observed_type
    if test_case["expected"] == "accepted" && observed_type == test_case["expected_type"]
      return ["accepted", observed_type]
    end
    if known_type_refusal?(status.fetch("reported_clickhouse_codes"), output)
      return ["law_mismatch", "ClickHouse emitted a type refusal despite success classification"]
    end
    return ["law_mismatch", "DESCRIBE type #{observed_type.inspect} != #{test_case["expected_type"].inspect}"]
  end

  refusal = test_case["refusal"]
  codes = status.fetch("reported_clickhouse_codes")
  text = output.force_encoding(Encoding::UTF_8).scrub
  if test_case["expected"] == "refused" && refusal && codes.include?(refusal.fetch("code")) && text.match?(Regexp.new(refusal.fetch("pattern")))
    return ["expected_refusal", "Code #{refusal.fetch("code")} matches declared semantic refusal"]
  end
  return ["law_mismatch", "unexpected ClickHouse type-law refusal (codes=#{codes.inspect})"] if known_type_refusal?(codes, output)
  ["probe_failure", "nonzero exit without the expected specific type-law diagnostic (codes=#{codes.inspect})"]
end

def run_case(root, binary, test_case)
  label = test_case.fetch("id")
  sql = create_describe_sql(test_case.fetch("declared_type"))
  run = record_process(root, binary, label, sql, multiquery: true)
  classification, detail = classify(test_case, run)
  test_case.merge(
    "classification" => classification,
    "detail" => detail,
    "status" => run.fetch(:status),
    "logs" => {
      "sql" => File.join("evidence", File.basename(run.fetch(:evidence)) + ".sql"),
      "argv" => File.join("evidence", File.basename(run.fetch(:evidence)) + ".argv.json"),
      "stdout" => File.join("evidence", File.basename(run.fetch(:evidence)) + ".stdout"),
      "stderr" => File.join("evidence", File.basename(run.fetch(:evidence)) + ".stderr"),
      "status" => File.join("evidence", File.basename(run.fetch(:evidence)) + ".status.json"),
    },
  )
end

def main
  root = prepare_root!(ARGV.fetch(0, nil))
  binary = ENV.fetch("CLICKHOUSE_BIN")
  require_true(File.file?(binary) && File.executable?(binary) && !File.symlink?(binary),
    "CLICKHOUSE_BIN is absent, non-executable, or a symlink: #{binary}")

  manifest = {
    "suite" => "W221 independent SimpleAggregateFunction construction matrix",
    "source_reference" => "#{SOURCE_ROOT}@#{SOURCE_REVISION}",
    "source_is_not_asserted_to_build_runtime" => true,
    "runtime_pin" => {"version" => VERSION, "build_hash" => BUILD_HASH, "sha256" => EXECUTABLE_SHA256},
    "functions" => FUNCTIONS,
    "numeric_types" => NUMERIC_TYPES,
    "leaf_count" => LEAVES.length,
    "shapes" => SHAPES,
    "process_timeout_seconds" => PROCESS_TIMEOUT_SECONDS,
    "expected_laws" => {
      "identity_result_functions" => IDENTITY_FUNCTIONS,
      "integer_only_functions" => BITWISE_FUNCTIONS,
      "sum_numeric_result_types" => SUM_NUMERIC_RESULT,
      "outer_nullable_requires_scalar_law" => true,
      "double_nullable_is_rejected_after_inner_saf_accepts" => true,
    },
  }
  write_new(File.join(root, "manifest.json"), JSON.pretty_generate(manifest) + "\n")

  begin
    pin = pin_runtime!(root, binary)
  rescue StandardError => error
    write_new(File.join(root, "fatal.json"), JSON.pretty_generate({
      "phase" => "runtime_pin",
      "error" => "#{error.class}: #{error.message}",
      "cases_interpreted" => 0,
    }) + "\n")
    warn "W221 refused to interpret construction results: #{error.message}"
    return 2
  end

  cases = matrix_cases + control_cases
  results = []
  cases.each_with_index do |test_case, index|
    puts "W221 construction case #{index + 1}/#{cases.length}: #{test_case.fetch("id")}"
    results << run_case(root, binary, test_case)
  end

  mismatches = results.count { |result| result.fetch("classification") == "law_mismatch" }
  failures = results.count { |result| result.fetch("classification") == "probe_failure" }
  summary = {
    "suite" => "W221 independent SimpleAggregateFunction construction matrix",
    "runtime_pin" => pin,
    "case_count" => results.length,
    "expected_accepted" => results.count { |result| result.fetch("expected") == "accepted" },
    "expected_refused" => results.count { |result| result.fetch("expected") == "refused" },
    "observed_accepted" => results.count { |result| result.fetch("classification") == "accepted" },
    "observed_expected_refusal" => results.count { |result| result.fetch("classification") == "expected_refusal" },
    "law_mismatches" => mismatches,
    "probe_failures" => failures,
    "matrix" => results,
  }
  write_new(File.join(root, "matrix.json"), JSON.pretty_generate(summary) + "\n")
  puts "W221 matrix=#{File.join(root, "matrix.json")} cases=#{results.length} law_mismatches=#{mismatches} probe_failures=#{failures}"
  mismatches.zero? && failures.zero? ? 0 : 1
end

exit(main)
