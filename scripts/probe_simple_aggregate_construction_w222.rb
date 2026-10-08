#!/usr/bin/env ruby
# Independent pinned-ClickHouse construction and descriptor oracle for W222.
# Laws are authored from pinned ClickHouse sources, not Crystal eligibility data.
require "digest"
require "json"
require "open3"

STDOUT.sync = true

VERSION = "26.10.1.1201".freeze
BUILD_HASH = "d9bcb5ab007f0f6299f7f973f2642245bab3d028".freeze
EXECUTABLE_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2".freeze
SOURCE_ROOT = "/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1".freeze
SOURCE_REVISION = "0ca8150d9b1d0886edb2e3b4ab65eebb768d0357".freeze
ROOT_PREFIX = "/private/tmp/crystal-click-w222.".freeze
PROCESS_TIMEOUT_SECONDS = 15
TERM_GRACE_SECONDS = 2

# Hashes pin the source files that define this probe's finite laws. The source
# archive is a comparison snapshot, not asserted to have built the runtime.
SOURCE_FILE_SHA256 = {
  "src/DataTypes/DataTypeCustomSimpleAggregateFunction.cpp" => "6c4502cdd659d59cc83b953a03399fa37d491f097ca38f445bfa74b1654e877d",
  "src/DataTypes/DataTypesBinaryEncoding.h" => "92c3362477dc283302fc84713413f45fd6c92c7273309c6efb41425d22c5485f",
  "src/DataTypes/DataTypeArray.h" => "660e6f37210922c200a7cbba5f25a0f01d579f79a51611768de72d1a3002be37",
  "src/DataTypes/DataTypeNullable.cpp" => "68c4e432a0f555712906d796a4db1d950b32abac2d6c2eba4c1117ad39793e64",
  "src/DataTypes/DataTypeNothing.h" => "7b38d3466d96965e30583f7662f5bf98eb0c17feef570d0adc4548ccb7c68370",
  "src/DataTypes/IDataTypeDummy.h" => "646b0c068b53141a41ed9f1ece68071745b1def29fa3bbdbee3c1e0d6755e113",
  "src/Storages/StorageFactory.cpp" => "6f21906a9ddad1a3fdf4867ca424727694791df9c1ede0d7b8d73449b4f30199",
  "src/Common/ErrorCodes.cpp" => "172e9409cf6713b727d46bd452929bcba7144c299d2681b91513f935d186ab76",
  "src/AggregateFunctions/Combinators/AggregateFunctionMap.cpp" => "0c3dc7b7ee3d1f7df65f7b12f5fd6ba88ca8da74356c4fc4a5ad2cac87924b9f",
  "src/AggregateFunctions/AggregateFunctionSumMap.cpp" => "fa67e6f23e3e0b0446a1a498e311423250f8e19650cad8738fa51305bfbca778",
  "src/AggregateFunctions/Combinators/AggregateFunctionArray.cpp" => "01621f65198b00bdefaf07b2e18c755331c3ad027932d1f25377611f32fe020c",
  "src/AggregateFunctions/AggregateFunctionGroupArray.cpp" => "6b4a434d9a77deb6122018f61ccab342587698d8b15c905877b16ec4c743aec1",
  "src/AggregateFunctions/AggregateFunctionGroupUniqArray.cpp" => "93ebf903f75a6aeaba56fc9b6340d7d9dd887f4113fc0a8b08be2060a7ffeb81",
  "src/AggregateFunctions/TimeSeries/AggregateFunctionTimeSeriesGroupArray.cpp" => "41d6db3d0f0f572ecd5d9e297461a6a3d2ea737d5dbdfbef6501b73fac9728f6",
  "src/AggregateFunctions/AggregateFunctionFactory.cpp" => "19edf542a3fc0364ffece33db8051d788613fd2125354679f501b9ddd038330a",
  "src/Core/Settings.cpp" => "1feab11c05a33d9df8c6e4886ad00a81efa358ba320803d720db32eef4f9db9a",
  "src/DataTypes/DataTypesBinaryEncoding.cpp" => "78ba394f20ccd2a00f5be6b8c4d470fafb1c91a6f87bb27c301c2d3203f28f87",
  "src/Common/FieldBinaryEncoding.cpp" => "123c388a21d766e07bdb6ca2b94efc8e9d071ce86306b16368b686b6138b7766",
  "src/Processors/Formats/Impl/BinaryRowOutputFormat.cpp" => "080028415c76eec928cab410e998ec9da4b59f2d1ad02d8a9fc499be0ceb8dbc",
}.freeze

SEMANTIC_ERROR_CODES = [36, 42, 43, 50, 53, 63, 69, 133].freeze

def require_true(condition, message)
  raise ArgumentError, message unless condition
end

def safe_label(value)
  value.gsub(/[^A-Za-z0-9_.-]/, "_")
end

def write_new(path, bytes)
  File.open(path, "wbx", 0o600) { |file| file.write(bytes) }
rescue Errno::EEXIST
  raise "refusing to overwrite W222 evidence: #{path}"
end

def make_dir(path)
  Dir.mkdir(path, 0o700)
rescue Errno::EEXIST
  raise "refusing to reuse W222 evidence directory: #{path}"
end

def prepare_root!(argument)
  require_true(argument && argument.match?(/\A#{Regexp.escape(ROOT_PREFIX)}[A-Za-z0-9_-]+\z/),
    "usage: CLICKHOUSE_BIN=/path/to/clickhouse ruby scripts/probe_simple_aggregate_construction_w222.rb #{ROOT_PREFIX}<fresh-leaf>")
  require_true(File.directory?(argument) && !File.symlink?(argument),
    "W222 root must be a ROOT-created, real directory: #{argument}")
  root = File.realpath(argument)
  require_true(root == argument && root.start_with?(ROOT_PREFIX), "W222 root is not the expected direct /private/tmp child")
  require_true(Dir.empty?(root), "refusing to reuse nonempty W222 evidence root: #{root}")
  %w[evidence stores].each { |name| make_dir(File.join(root, name)) }
  root
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
    # Ruby and every ClickHouse child together.
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
    # Per-child timeout/exception cleanup only. Never detach or kill a group;
    # the outer guard owns the process-group boundary.
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
  record = {
    "success" => status && status.success? || false,
    "exitstatus" => status && status.exitstatus,
    "signaled" => status && status.signaled? || false,
    "termsig" => status && status.termsig,
    "timed_out" => timed_out,
    "duration_ms" => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
    "reported_clickhouse_codes" => codes,
  }
  record["spawn_error"] = spawn_error if spawn_error
  {stdout: stdout_bytes, stderr: stderr_bytes, status: record}
end

def query_argv(binary, store, sql, multiquery: false, extra_args: [])
  argv = [binary, "local", "--path", store, "--session_timezone=UTC",
    "--max_threads=1", "--max_execution_time=10", "--max_memory_usage=536870912"]
  argv << "--multiquery" if multiquery
  argv.concat(extra_args)
  argv.concat(["--query", sql])
end

def record_process(root, binary, label, sql, multiquery: false, extra_args: [])
  stem = safe_label(label)
  evidence = File.join(root, "evidence", stem)
  store = File.join(root, "stores", stem)
  make_dir(store)
  argv = query_argv(binary, store, sql, multiquery: multiquery, extra_args: extra_args)
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

def pin_source!(root)
  require_true(File.directory?(SOURCE_ROOT), "pinned ClickHouse source root is absent: #{SOURCE_ROOT}")
  files = SOURCE_FILE_SHA256.map do |relative, expected|
    path = File.join(SOURCE_ROOT, relative)
    require_true(File.file?(path) && !File.symlink?(path), "pinned source anchor is absent or symlinked: #{path}")
    actual = Digest::SHA256.file(path).hexdigest
    {"path" => relative, "expected_sha256" => expected, "actual_sha256" => actual,
      "matches" => actual == expected}
  end
  record = {
    "source_reference" => "#{SOURCE_ROOT}@#{SOURCE_REVISION}",
    "source_root_realpath" => File.realpath(SOURCE_ROOT),
    "source_revision_provided_by_task_context" => SOURCE_REVISION,
    "full_source_revision_not_revalidated_with_git" => true,
    "file_hashes" => files,
  }
  write_new(File.join(root, "source_pin.json"), JSON.pretty_generate(record) + "\n")
  mismatches = files.reject { |file| file.fetch("matches") }
  require_true(mismatches.empty?, "pinned ClickHouse source anchor hash mismatch: #{mismatches.map { |x| x.fetch("path") }.join(", ")}")
  record
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

  build_record = record_process(root, binary, "pin_build",
    "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw")
  require_true(build_record.dig(:status, "success") && !build_record.dig(:status, "timed_out"),
    "pinned ClickHouse build query failed; see #{build_record[:evidence]}")
  build = build_record.fetch(:stdout).strip
  require_true(build == "VERSION_GITHASH=#{BUILD_HASH}", "ClickHouse build hash mismatch: #{build.inspect}")

  pin = {
    "runtime_version" => version,
    "runtime_sha256" => sha256,
    "runtime_build_hash" => BUILD_HASH,
    "source_reference" => "#{SOURCE_ROOT}@#{SOURCE_REVISION}",
    "runtime_source_correlation" => "not_asserted",
  }
  write_new(File.join(root, "runtime_pin.json"), JSON.pretty_generate(pin) + "\n")
  pin
end

def saf_type(function_expression, *argument_types)
  "SimpleAggregateFunction(#{function_expression}, #{argument_types.join(", ")})"
end

def accepted_case(id, function_expression, argument_types, canonical_expression, canonical_arguments,
  group, reason, settings: [])
  {
    "id" => id,
    "kind" => "construction",
    "cohort" => "strict",
    "group" => group,
    "declared_type" => saf_type(function_expression, *argument_types),
    "expected" => "accepted",
    "expected_type" => saf_type(canonical_expression, *canonical_arguments),
    "law_reason" => reason,
    "settings" => settings,
  }
end

def refused_case(id, function_expression, argument_types, group, reason, code, pattern, settings: [], declared_type: nil)
  {
    "id" => id,
    "kind" => "construction",
    "cohort" => "strict",
    "group" => group,
    "declared_type" => declared_type || saf_type(function_expression, *argument_types),
    "expected" => "refused",
    "law_reason" => reason,
    "refusal" => {"code" => code, "pattern" => pattern},
    "settings" => settings,
  }
end

def exploratory_case(id, function_expression, argument_types, reason, settings: [])
  {
    "id" => id,
    "kind" => "construction",
    "cohort" => "exploratory",
    "group" => "special_type_boundary",
    "declared_type" => saf_type(function_expression, *argument_types),
    "expected" => "unresolved",
    "law_reason" => reason,
    "settings" => settings,
  }
end

def strict_cases
  cases = []
  add_accept = lambda do |*args, **options|
    cases << accepted_case(*args, **options)
  end
  add_refuse = lambda do |*args, **options|
    cases << refused_case(*args, **options)
  end

  # Map combinator and its historical mapped-array input form. The Map path
  # preserves the declared Map type only when nested aggregate results do.
  add_accept.call("map_sum_uint8_uint64", "sumMap", ["Map(UInt8, UInt64)"],
    "sumMap", ["Map(UInt8, UInt64)"], "map", "sumMap over UInt64 values preserves the Map type")
  add_accept.call("map_min_string_uint64", "minMap", ["Map(String, UInt64)"],
    "minMap", ["Map(String, UInt64)"], "map", "minMap accepts the String key path and preserves Map values")
  add_accept.call("map_max_uuid_array", "maxMap", ["Map(UUID, Array(UInt64))"],
    "maxMap", ["Map(UUID, Array(UInt64))"], "map", "Map key UUID is in the combinator switch; Array is comparable")
  add_accept.call("map_sum_ipv4_key", "sumMap", ["Map(IPv4, UInt64)"],
    "sumMap", ["Map(IPv4, UInt64)"], "map", "IPv4 key is explicitly dispatched by the Map combinator")
  add_accept.call("map_max_enum8_key", "maxMap", ["Map(Enum8('a' = 1, 'b' = 2), UInt64)"],
    "maxMap", ["Map(Enum8('a' = 1, 'b' = 2), UInt64)"], "map", "Enum8 key is explicitly dispatched by the Map combinator")

  mapped = "Tuple(Array(UInt8), Array(UInt64))"
  %w[sum min max].each do |base|
    old_name = "#{base}MappedArrays"
    canonical = "#{base}Map"
    add_accept.call("#{old_name}_tuple_canonicalizes", old_name, [mapped], canonical, [mapped],
      "map_mapped_arrays", "legacy mapped-array function name returns its canonical *Map identity")
  end
  add_accept.call("sumMap_tuple_arrays", "sumMap", [mapped], "sumMap", [mapped],
    "map_mapped_arrays", "Map combinator redirects a tuple of key/value arrays to the mapped-array implementation")
  mapped_three = "Tuple(Array(UInt8), Array(UInt64), Array(UInt64))"
  add_accept.call("sumMappedArrays_three_arrays", "sumMappedArrays", [mapped_three], "sumMap", [mapped_three],
    "map_mapped_arrays", "sumMap supports multiple value arrays and its tuple result is a fixed point")
  add_refuse.call("sumMap_map_value_widens", "sumMap", ["Map(UInt8, UInt8)"], "map",
    "sumMap(UInt8) promotes values to UInt64, so result Map differs from storage", 36,
    "Incompatible data types between aggregate function")
  add_refuse.call("map_float_key_unsupported", "sumMap", ["Map(Float64, UInt64)"], "map",
    "Map combinator's finite key switch excludes Float64", 43,
    "Map key type .* is not is not supported by combinator")
  add_refuse.call("mapped_arrays_tuple_too_short", "sumMappedArrays", ["Tuple(Array(UInt8))"], "map_mapped_arrays",
    "mapped-array input requires at least a key and one value array", 42,
    "requires at least two arguments of Array type")
  add_refuse.call("sumMap_parameter_forbidden", "sumMap(1)", ["Map(UInt8, UInt64)"], "map_parameters",
    "sumMap has no aggregate parameters", 133, "Aggregate function .* cannot have parameters")
  add_refuse.call("minMappedArrays_parameter_forbidden", "minMappedArrays(1)", [mapped], "map_parameters",
    "minMappedArrays has no aggregate parameters", 133, "Aggregate function .* cannot have parameters")
  add_refuse.call("sumMap_multiple_args_result_mismatch", "sumMap",
    ["Array(UInt8)", "Array(UInt64)"], "map_mapped_arrays",
    "the two-array form returns a tuple, not the first array storage argument", 36,
    "Incompatible data types between aggregate function")

  # Array suffix families: one Array layer is stripped before invoking the
  # base aggregate, and a fixed point is required for SAF admission.
  add_accept.call("groupArrayArray_plain", "groupArrayArray", ["Array(UInt64)"],
    "groupArrayArray", ["Array(UInt64)"], "array_families", "groupArray over Array values returns the same Array type")
  add_accept.call("groupArrayArray_with_limit", "groupArrayArray(3)", ["Array(String)"],
    "groupArrayArray(3)", ["Array(String)"], "array_families", "groupArrayArray allows one positive integer limit")
  add_accept.call("array_concat_agg_alias", "array_concat_agg", ["Array(UInt64)"],
    "groupArrayArray", ["Array(UInt64)"], "canonical_aliases", "array_concat_agg resolves to groupArrayArray")
  add_accept.call("groupArrayLastArray_with_limit", "groupArrayLastArray(5)", ["Array(UInt64)"],
    "groupArrayLastArray(5)", ["Array(UInt64)"], "array_families", "groupArrayLast requires a positive max_elems parameter")
  add_refuse.call("groupArrayLastArray_without_limit", "groupArrayLastArray", ["Array(UInt64)"], "array_parameters",
    "groupArrayLast is invalid without its required cap", 36,
    "groupArrayLast make sense only with max_elems")
  add_refuse.call("groupArrayLastArray_zero_limit", "groupArrayLastArray(0)", ["Array(UInt64)"], "array_parameters",
    "array aggregate cap must be positive", 36, "Parameter for aggregate function .* should be positive number")
  add_refuse.call("groupArrayArray_wrong_field_kind", "groupArrayArray('x')", ["Array(UInt64)"], "array_parameters",
    "the optional array cap accepts only a positive integer Field", 36,
    "Parameter for aggregate function .* should be positive number")
  add_refuse.call("groupArrayArray_too_many_parameters", "groupArrayArray(1, 2)", ["Array(UInt64)"], "array_parameters",
    "groupArray accepts zero or one cap", 42, "Incorrect number of parameters for aggregate function")
  add_accept.call("groupUniqArrayArray_plain", "groupUniqArrayArray", ["Array(UInt64)"],
    "groupUniqArrayArray", ["Array(UInt64)"], "array_families", "groupUniqArray over Array values returns the same Array type")
  add_accept.call("groupUniqArrayArray_with_limit", "groupUniqArrayArray(7)", ["Array(String)"],
    "groupUniqArrayArray(7)", ["Array(String)"], "array_families", "groupUniqArray allows one positive integer limit")
  add_accept.call("groupUniqArrayArrayMap_plain", "groupUniqArrayArrayMap", ["Map(String, Array(UInt64))"],
    "groupUniqArrayArrayMap", ["Map(String, Array(UInt64))"], "array_map_family",
    "Map wraps Array(groupUniqArray) and preserves Map(String, Array(UInt64))")
  add_accept.call("groupUniqArrayArrayMap_with_limit", "groupUniqArrayArrayMap(4)", ["Map(String, Array(UInt8))"],
    "groupUniqArrayArrayMap(4)", ["Map(String, Array(UInt8))"], "array_map_family",
    "Map+Array combinators preserve the fixed-point storage type and forward the cap")
  add_refuse.call("groupUniqArrayArray_zero_limit", "groupUniqArrayArray(0)", ["Array(UInt64)"], "array_parameters",
    "array aggregate cap must be positive", 36, "Parameter for aggregate function .* should be positive number")
  add_refuse.call("groupUniqArrayArray_too_many_parameters", "groupUniqArrayArray(1, 2)", ["Array(UInt64)"], "array_parameters",
    "groupUniqArray accepts zero or one cap", 42, "Incorrect number of parameters for aggregate function")
  add_refuse.call("groupUniqArrayArrayMap_too_many_parameters", "groupUniqArrayArrayMap(1, 2)",
    ["Map(String, Array(UInt64))"], "array_parameters", "groupUniqArrayMap accepts zero or one cap", 42,
    "Incorrect number of parameters for aggregate function")
  add_refuse.call("groupArrayArray_nullable_element_result_mismatch", "groupArrayArray",
    ["Array(Nullable(UInt64))"], "array_nullable_transform",
    "Null combinator result is Nullable(Array(UInt64)), not Array(Nullable(UInt64))", 36,
    "Incompatible data types between aggregate function")
  add_refuse.call("groupArrayLastArray_nullable_element_result_mismatch", "groupArrayLastArray(3)",
    ["Array(Nullable(UInt64))"], "array_nullable_transform",
    "Null combinator result is not the original Array(Nullable(T)) storage type", 36,
    "Incompatible data types between aggregate function")
  add_refuse.call("groupArrayArray_nested_lc_result_mismatch", "groupArrayArray",
    ["Array(LowCardinality(String))"], "array_low_cardinality_transform",
    "factory recursively removes child LowCardinality but SAF storage equality removes only a top-level wrapper", 36,
    "Incompatible data types between aggregate function")

  # timeSeriesGroupArray is private-preview and has one SAF-compatible form:
  # an identity result Array(Tuple(timestamp, Float32|Float64)).
  ts_setting = ["--enable_time_series_aggregate_functions=1"]
  ts_u32_f64 = "Array(Tuple(UInt32, Float64))"
  ts_dt64_f32 = "Array(Tuple(DateTime64(3, 'UTC'), Float32))"
  ts_dt_f64 = "Array(Tuple(DateTime('UTC'), Float64))"
  [ts_u32_f64, ts_dt64_f32, ts_dt_f64].each_with_index do |type, index|
    add_accept.call("timeSeriesGroupArray_valid_#{index + 1}", "timeSeriesGroupArray", [type],
      "timeSeriesGroupArray", [type], "time_series", "single Array(Tuple(timestamp, value)) result is the storage type",
      settings: ts_setting)
  end
  add_accept.call("timeSeriesGroupArray_old_setting_alias", "timeSeriesGroupArray", [ts_u32_f64],
    "timeSeriesGroupArray", [ts_u32_f64], "time_series_setting_alias",
    "legacy setting name is an alias of enable_time_series_aggregate_functions",
    settings: ["--allow_experimental_time_series_aggregate_functions=1"])
  add_refuse.call("timeSeriesGroupArray_default_disabled", "timeSeriesGroupArray", [ts_u32_f64], "time_series_gate",
    "private-preview aggregate is disabled by default", 63,
    "private preview and disabled by default")
  add_refuse.call("timeSeriesGroupArray_bad_timestamp", "timeSeriesGroupArray", ["Array(Tuple(Date, Float64))"],
    "time_series_types", "single-argument form accepts DateTime64, DateTime or UInt32 timestamp", 43,
    'Illegal type .* of 1st argument \\(timestamp\\)', settings: ts_setting)
  add_refuse.call("timeSeriesGroupArray_bad_value", "timeSeriesGroupArray", ["Array(Tuple(UInt32, UInt64))"],
    "time_series_types", "single-argument form accepts Float32 or Float64 values", 43,
    'Illegal type .* of 2nd argument \\(value\\)', settings: ts_setting)
  add_refuse.call("timeSeriesGroupArray_wrong_tuple_arity", "timeSeriesGroupArray",
    ["Array(Tuple(UInt32, Float64, String))"], "time_series_types",
    "single-argument tuple form requires exactly two fields", 43,
    'expected Array\\(Tuple\\(timestamp, value\\)\\)', settings: ts_setting)
  add_refuse.call("timeSeriesGroupArray_not_array_tuple", "timeSeriesGroupArray", ["Tuple(UInt32, Float64)"],
    "time_series_types", "single-argument SAF form must be Array(Tuple(timestamp, value))", 43,
    'expected Array\\(Tuple\\(timestamp, value\\)\\)', settings: ts_setting)
  add_refuse.call("timeSeriesGroupArray_two_args_result_mismatch", "timeSeriesGroupArray",
    ["Array(UInt32)", "Array(Float64)"], "time_series_result_mismatch",
    "two-array aggregate result is Array(Tuple(UInt32, Float64)), not the first array storage", 36,
    "Incompatible data types between aggregate function", settings: ts_setting)
  add_refuse.call("timeSeriesGroupArray_parameter_forbidden", "timeSeriesGroupArray(1)", [ts_u32_f64],
    "time_series_parameters", "timeSeriesGroupArray accepts no parameters", 133,
    "Aggregate function .* cannot have parameters", settings: ts_setting)

  # Recursive controls for the previously admitted eleven functions. These
  # separate type equality, comparability and aggregate overload legality.
  add_accept.call("any_map_identity", "any", ["Map(String, UInt64)"], "any", ["Map(String, UInt64)"],
    "existing_identity", "any preserves a Map input")
  add_accept.call("anyLast_array_identity", "anyLast", ["Array(UInt64)"], "anyLast", ["Array(UInt64)"],
    "existing_identity", "anyLast preserves an Array input")
  add_accept.call("any_respect_nullable_identity", "any_respect_nulls", ["Nullable(UInt64)"],
    "any_respect_nulls", ["Nullable(UInt64)"], "existing_identity", "respect-nulls name directly handles Nullable input")
  add_accept.call("anyLast_respect_tuple_identity", "anyLast_respect_nulls", ["Tuple(UInt64, String)"],
    "anyLast_respect_nulls", ["Tuple(UInt64, String)"], "existing_identity", "respect-nulls result preserves Tuple input")
  add_accept.call("min_array_comparable", "min", ["Array(UInt64)"], "min", ["Array(UInt64)"],
    "existing_comparable", "Array is comparable and min returns its exact input type")
  add_accept.call("max_tuple_comparable", "max", ["Tuple(UInt64, String)"], "max", ["Tuple(UInt64, String)"],
    "existing_comparable", "Tuple is comparable and max returns its exact input type")
  add_accept.call("min_map_comparable", "min", ["Map(String, UInt64)"], "min", ["Map(String, UInt64)"],
    "existing_comparable", "Map is comparable and min returns its exact input type")
  add_accept.call("max_map_comparable", "max", ["Map(String, Array(UInt64))"], "max",
    ["Map(String, Array(UInt64))"], "existing_comparable", "nested Map/Array comparability preserves the full input type")
  add_refuse.call("min_dynamic_rejected", "min", ["Dynamic"], "existing_comparable_rejection",
    "min explicitly rejects Dynamic trees because values may have different runtime types", 43,
    "can contain values with different data types")
  add_refuse.call("max_variant_rejected", "max", ["Variant(UInt64, String)"], "existing_comparable_rejection",
    "max explicitly rejects Variant trees because values may have different runtime types", 43,
    "can contain values with different data types")
  add_accept.call("sum_uint64_identity_result", "sum", ["UInt64"], "sum", ["UInt64"],
    "existing_numeric", "sum(UInt64) returns UInt64")
  add_accept.call("sum_decimal128_identity_result", "sum", ["Decimal(38, 5)"], "sum", ["Decimal(38, 5)"],
    "existing_numeric", "Decimal(38,5) sum preserves Decimal128 precision and scale")
  add_refuse.call("sum_array_unsupported", "sum", ["Array(UInt64)"], "existing_numeric_rejection",
    "sum has no Array overload", 43, "Illegal type .* of argument for aggregate function")
  add_accept.call("sumWithOverflow_int64", "sumWithOverflow", ["Int64"], "sumWithOverflow", ["Int64"],
    "existing_numeric", "sumWithOverflow returns the exact integer input type")
  add_refuse.call("sumWithOverflow_map_unsupported", "sumWithOverflow", ["Map(String, UInt64)"],
    "existing_numeric_rejection", "sumWithOverflow has numeric, not Map, overloads", 43,
    "Illegal type .* of argument for aggregate function")
  add_accept.call("groupBitAnd_uint64", "groupBitAnd", ["UInt64"], "groupBitAnd", ["UInt64"],
    "existing_bitwise", "groupBitAnd preserves integer input type")
  add_accept.call("groupBitOr_int32", "groupBitOr", ["Int32"], "groupBitOr", ["Int32"],
    "existing_bitwise", "groupBitOr preserves integer input type")
  add_accept.call("groupBitXor_uint32", "groupBitXor", ["UInt32"], "groupBitXor", ["UInt32"],
    "existing_bitwise", "groupBitXor preserves integer input type")
  add_refuse.call("groupBitAnd_map_unsupported", "groupBitAnd", ["Map(String, UInt64)"],
    "existing_bitwise_rejection", "bitwise aggregates accept integer types only", 43,
    "cannot be used in bitwise operations")
  add_refuse.call("groupArray_not_in_saf_allowlist", "groupArray", ["Array(UInt64)"], "existing_function_allowlist",
    "groupArray is outside the finite SimpleAggregateFunction name allowlist; this refusal precedes result equality", 36,
    Regexp.escape("Unsupported aggregate function groupArray"))
  add_refuse.call("groupUniqArray_not_in_saf_allowlist", "groupUniqArray", ["Array(UInt64)"],
    "existing_function_allowlist",
    "groupUniqArray is outside the finite SimpleAggregateFunction name allowlist; this refusal precedes result equality", 36,
    Regexp.escape("Unsupported aggregate function groupUniqArray"))
  add_accept.call("any_low_cardinality_string", "any", ["LowCardinality(String)"], "any",
    ["LowCardinality(String)"], "existing_low_cardinality", "top-level LowCardinality is removed for result equality")
  add_refuse.call("any_nested_low_cardinality_array_mismatch", "any", ["Array(LowCardinality(String))"],
    "existing_low_cardinality", "recursive factory normalization changes Array child but SAF equality removes only outer LowCardinality", 36,
    "Incompatible data types between aggregate function")
  add_refuse.call("outer_nullable_saf_forbidden", "Nullable(SimpleAggregateFunction(groupArrayArray, Array(UInt64)))",
    [], "nullable_boundary", "Array-backed storage cannot be wrapped in Nullable because Array is not valid inside Nullable", 43,
    Regexp.escape("Nested type SimpleAggregateFunction(groupArrayArray, Array(UInt64)) cannot be inside Nullable type"),
    declared_type: "Nullable(SimpleAggregateFunction(groupArrayArray, Array(UInt64)))")

  cases
end

def exploratory_cases
  [
    ["special_bool_any", "any", ["Bool"], "Bool aggregate-result and type-domain admission are kept exploratory"],
    ["special_uuid_any", "any", ["UUID"], "UUID is a storage-domain control beyond the scalar W221 roster"],
    ["special_ipv4_any", "any", ["IPv4"], "IPv4 is a storage-domain control beyond the scalar W221 roster"],
    ["special_ipv6_any", "any", ["IPv6"], "IPv6 is a storage-domain control beyond the scalar W221 roster"],
    ["special_enum_any", "any", ["Enum8('zero' = 0, 'one' = 1)"], "Enum support is type/factory dependent"],
    ["special_interval_any", "any", ["IntervalDay"], "Interval support is type/factory dependent"],
    ["special_nothing_any", "any", ["Nothing"], "Nothing is an expression-only dummy type that cannot be stored in a table; this is not an aggregate-result law"],
    ["special_qbit_any", "any", ["QBit(Float32, 4)"], "QBit is a custom type and its admission is not inferred from scalar codecs"],
    ["special_nested_any", "any", ["Nested(x UInt64, y String)"], "Nested can expand to multiple storage columns"],
    ["special_variant_any", "any", ["Variant(UInt64, String)"], "Variant result identity does not certify discriminator/child storage support"],
    ["special_dynamic_any", "any", ["Dynamic(max_types=4)"], "Dynamic result identity does not certify roster/shared-data storage support"],
    ["special_json_any", "any", ["JSON"], "JSON/Object result identity does not certify typed/dynamic/shared paths"],
    ["special_nested_saf_any", "any", ["Array(SimpleAggregateFunction(any, UInt64))"], "nested SAF ownership is not inferred from child acceptance"],
    ["special_map_nested_nullable", "sumMap", ["Map(String, Nullable(UInt64))"], "nullable Map-value result compatibility is source-sensitive"],
    ["special_array_map_nullable", "groupUniqArrayArrayMap", ["Map(String, Array(Nullable(UInt64)))"], "nested Null/Array/Map result composition is exploratory"],
  ].map do |id, function, args, reason|
    exploratory_case(id, function, args, reason,
      settings: function == "timeSeriesGroupArray" ? ["--enable_time_series_aggregate_functions=1"] :
        (id == "special_nested_any" ? ["--flatten_nested=0"] : []))
  end
end

def varuint(value)
  require_true(value >= 0, "VarUInt cannot encode a negative value")
  bytes = []
  remaining = value
  while remaining >= 0x80
    bytes << ((remaining & 0x7f) | 0x80)
    remaining >>= 7
  end
  bytes << remaining
  bytes
end

def binary_string(value)
  contents = value.b.bytes
  varuint(contents.length) + contents
end

def field_uint64(value)
  [0x01] + varuint(value)
end

def data_type_uint8
  [0x01]
end

def data_type_uint64
  [0x04]
end

def data_type_string
  [0x15]
end

def data_type_array(nested)
  [0x1e] + nested
end

def data_type_tuple(elements)
  [0x1f] + varuint(elements.length) + elements.flatten(1)
end

def data_type_map(key, value)
  [0x27] + key + value
end

def data_type_simple_aggregate(function, parameters, arguments)
  [0x2e] + binary_string(function) + varuint(parameters.length) +
    parameters.flat_map { |parameter| field_uint64(parameter) } +
    varuint(arguments.length) + arguments.flatten(1)
end

def descriptor_cases
  array_u8 = data_type_array(data_type_uint8)
  array_u64 = data_type_array(data_type_uint64)
  array_string = data_type_array(data_type_string)
  map_string_array_u8 = data_type_map(data_type_string, array_u8)
  tuple_key_values = data_type_tuple([array_u8, array_u64])

  specs = [
    ["descriptor_groupArrayArray_optional_cap", "groupArrayArray(3)", ["Array(UInt8)"],
      "groupArrayArray", [3], [array_u8]],
    ["descriptor_groupArrayLastArray_required_cap", "groupArrayLastArray(5)", ["Array(UInt64)"],
      "groupArrayLastArray", [5], [array_u64]],
    ["descriptor_groupUniqArrayArray_no_cap", "groupUniqArrayArray", ["Array(String)"],
      "groupUniqArrayArray", [], [array_string]],
    ["descriptor_groupUniqArrayArrayMap_optional_cap", "groupUniqArrayArrayMap(4)",
      ["Map(String, Array(UInt8))"], "groupUniqArrayArrayMap", [4], [map_string_array_u8]],
    ["descriptor_sumMappedArrays_canonical_name", "sumMappedArrays", ["Tuple(Array(UInt8), Array(UInt64))"],
      "sumMap", [], [tuple_key_values]],
  ]

  specs.map do |id, function_expression, argument_types, canonical_function, parameters, encoded_arguments|
    expected_bytes = data_type_simple_aggregate(canonical_function, parameters, encoded_arguments)
    {
      "id" => id,
      "kind" => "descriptor",
      "cohort" => "strict",
      "group" => "binary_type_descriptor",
      "declared_type" => saf_type(function_expression, *argument_types),
      "expected" => "accepted",
      "expected_type" => saf_type(
        canonical_function + (parameters.empty? ? "" : "(#{parameters.join(", ")})"), *argument_types),
      "law_reason" => "RowBinaryWithNamesAndTypes binary type header must encode the canonical SAF function, Field UInt64 parameter(s), and recursive argument descriptor",
      "descriptor_law" => {
        "canonical_function" => canonical_function,
        "uint64_field_parameters" => parameters,
        "expected_type_hex" => expected_bytes.pack("C*").unpack1("H*"),
        "binary_type_index_simple_aggregate_function" => "0x2e",
        "field_uint64_type_index" => "0x01",
        "query_format" => "RowBinaryWithNamesAndTypes",
      },
    }
  end
end

def all_cases
  strict_cases + exploratory_cases + descriptor_cases
end

def create_describe_sql(type)
  "CREATE TABLE x (v #{type}) ENGINE=Memory;\nDESCRIBE TABLE x FORMAT TSVRaw"
end

def create_descriptor_sql(type)
  "CREATE TABLE x (v #{type}) ENGINE=Memory;\nSELECT v FROM x LIMIT 0 FORMAT RowBinaryWithNamesAndTypes"
end

def described_type(stdout)
  rows = stdout.force_encoding(Encoding::UTF_8).scrub.split(/\r?\n/).reject(&:empty?)
  row = rows.find { |line| line.start_with?("v\t") }
  return nil unless row
  row.split("\t", -1)[1]
end

def semantic_code?(codes)
  codes.any? { |code| SEMANTIC_ERROR_CODES.include?(code) }
end

def classify_construction(test_case, run)
  status = run.fetch(:status)
  output = run.fetch(:stdout) + run.fetch(:stderr)
  codes = status.fetch("reported_clickhouse_codes")
  text = output.force_encoding(Encoding::UTF_8).scrub
  return ["probe_failure", "bounded timeout", nil] if status.fetch("timed_out")
  return ["probe_failure", status.fetch("spawn_error"), nil] if status["spawn_error"]
  return ["probe_failure", "process was signaled", nil] if status.fetch("signaled")

  if status.fetch("success")
    observed = described_type(run.fetch(:stdout))
    if test_case.fetch("cohort") == "exploratory"
      return ["exploratory_constructed", observed ? "DESCRIBE returned a nominal v row" : "CREATE succeeded; DESCRIBE had no v row", observed]
    end
    unless observed
      return ["probe_failure", "successful process did not produce a DESCRIBE row", nil]
    end
    if test_case.fetch("expected") == "accepted" && observed == test_case.fetch("expected_type")
      return ["accepted", observed, observed]
    end
    if test_case.fetch("expected") == "refused"
      return ["law_mismatch", "stock accepted a declaration predicted to be refused (#{observed})", observed]
    end
    return ["law_mismatch", "DESCRIBE type #{observed.inspect} != #{test_case.fetch("expected_type").inspect}", observed]
  end

  if test_case.fetch("cohort") == "exploratory"
    if test_case.fetch("id") == "special_nothing_any" && codes == [370] &&
        status.fetch("exitstatus") == (370 & 0xff) &&
        text.match?(Regexp.new(Regexp.escape("Data type SimpleAggregateFunction(any, Nothing) of column 'v' cannot be used in tables"), Regexp::IGNORECASE))
      return ["exploratory_storage_refused", "Code 370 is the table-storage prohibition for the Nothing dummy type, not an aggregate construction refusal", nil]
    end
    return ["exploratory_refused", "ClickHouse refusal codes=#{codes.inspect}", nil] if semantic_code?(codes)
    return ["probe_failure", "nonzero exit without a recognized type/parser code (codes=#{codes.inspect})", nil]
  end

  refusal = test_case["refusal"]
  if test_case.fetch("expected") == "refused" && refusal && codes == [refusal.fetch("code")] &&
      status.fetch("exitstatus") == (refusal.fetch("code") & 0xff) &&
      text.match?(Regexp.new(refusal.fetch("pattern"), Regexp::IGNORECASE))
    return ["expected_refusal", "Code #{refusal.fetch("code")} matches the specific source-law refusal", nil]
  end
  if semantic_code?(codes)
    return ["law_mismatch", "unexpected ClickHouse type-law refusal (codes=#{codes.inspect})", nil]
  end
  ["probe_failure", "nonzero exit without an expected semantic refusal (codes=#{codes.inspect})", nil]
end

def read_varuint(bytes, offset)
  value = 0
  shift = 0
  10.times do
    byte = bytes.getbyte(offset)
    raise ArgumentError, "truncated VarUInt" unless byte
    offset += 1
    value |= (byte & 0x7f) << shift
    return [value, offset] if (byte & 0x80).zero?
    shift += 7
  end
  raise ArgumentError, "VarUInt exceeds ten bytes"
end

def read_binary_string(bytes, offset)
  size, offset = read_varuint(bytes, offset)
  value = bytes.byteslice(offset, size)
  raise ArgumentError, "truncated length-prefixed string" unless value && value.bytesize == size
  [value, offset + size]
end

def parse_binary_header(stdout)
  count, offset = read_varuint(stdout, 0)
  raise ArgumentError, "expected one RowBinary header column, got #{count}" unless count == 1
  name, offset = read_binary_string(stdout, offset)
  {"column_count" => count, "column_name" => name.force_encoding(Encoding::UTF_8).scrub,
    "type_bytes" => stdout.byteslice(offset, stdout.bytesize - offset) || "".b}
end

def classify_descriptor(test_case, run)
  status = run.fetch(:status)
  output = run.fetch(:stdout) + run.fetch(:stderr)
  codes = status.fetch("reported_clickhouse_codes")
  return ["probe_failure", "bounded timeout", nil] if status.fetch("timed_out")
  return ["probe_failure", status.fetch("spawn_error"), nil] if status["spawn_error"]
  return ["probe_failure", "process was signaled", nil] if status.fetch("signaled")
  unless status.fetch("success")
    return ["law_mismatch", "descriptor construction refused with semantic code #{codes.inspect}", nil] if semantic_code?(codes)
    return ["probe_failure", "descriptor query failed without a semantic type code #{codes.inspect}", nil]
  end

  begin
    header = parse_binary_header(run.fetch(:stdout))
  rescue StandardError => error
    return ["probe_failure", "could not parse binary header: #{error.class}: #{error.message}", nil]
  end
  observed = header.fetch("type_bytes")
  expected = [test_case.fetch("descriptor_law").fetch("expected_type_hex")].pack("H*")
  if header.fetch("column_name") != "v"
    return ["law_mismatch", "binary header column name was #{header.fetch("column_name").inspect}", header]
  end
  if observed == expected
    return ["descriptor_exact", "binary header type bytes match independently constructed encoding", header]
  end
  ["law_mismatch", "binary type bytes differ: observed=#{observed.unpack1("H*")}", header]
end

def run_case(root, binary, test_case)
  label = test_case.fetch("id")
  if test_case.fetch("kind") == "descriptor"
    sql = create_descriptor_sql(test_case.fetch("declared_type"))
    extra_args = ["--output_format_binary_encode_types_in_binary_format=1"]
  else
    sql = create_describe_sql(test_case.fetch("declared_type"))
    extra_args = []
  end
  extra_args.concat(test_case.fetch("settings", []))
  run = record_process(root, binary, label, sql, multiquery: true, extra_args: extra_args)
  if test_case.fetch("kind") == "descriptor"
    classification, detail, observed = classify_descriptor(test_case, run)
  else
    classification, detail, observed = classify_construction(test_case, run)
  end
  test_case.merge(
    "classification" => classification,
    "detail" => detail,
    "observed_type" => observed.is_a?(String) ? observed : nil,
    "observed_descriptor_hex" => observed.is_a?(Hash) ? observed.fetch("type_bytes").unpack1("H*") : nil,
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

  cases = all_cases
  manifest = {
    "suite" => "W222 independent SimpleAggregateFunction recursive construction and descriptor probe",
    "source_reference" => "#{SOURCE_ROOT}@#{SOURCE_REVISION}",
    "runtime_pin" => {"version" => VERSION, "build_hash" => BUILD_HASH, "sha256" => EXECUTABLE_SHA256},
    "source_is_not_asserted_to_build_runtime" => true,
    "source_file_sha256" => SOURCE_FILE_SHA256,
    "source_law_anchors" => [
      {"file" => "src/DataTypes/DataTypeCustomSimpleAggregateFunction.cpp", "lines" => "31-65,151-169", "law" => "resolved canonical function name must be in the finite 22-name allowlist; aggregate result must equal top-level removeLowCardinality(storage)"},
      {"file" => "src/DataTypes/DataTypesBinaryEncoding.h", "lines" => "9-58", "law" => "BinaryTypeIndex assigns UInt64=0x04 and SimpleAggregateFunction=0x2e; descriptor expectations are sourced from this enum"},
      {"file" => "src/DataTypes/DataTypeArray.h", "lines" => "39-43", "law" => "Array is not itself valid inside Nullable; for SAF(Array(...)), outer Nullable validates array storage, not the custom SAF spelling"},
      {"file" => "src/DataTypes/DataTypeNullable.cpp", "lines" => "25-35", "law" => "Nullable construction rejects a nested storage type whose canBeInsideNullable is false"},
      {"file" => "src/DataTypes/DataTypeNothing.h", "lines" => "12-18", "law" => "Nothing is backed by the expression-only IDataTypeDummy type"},
      {"file" => "src/DataTypes/IDataTypeDummy.h", "lines" => "21-46", "law" => "IDataTypeDummy cannot be stored in tables, independently of aggregate result compatibility"},
      {"file" => "src/Storages/StorageFactory.cpp", "lines" => "40-45", "law" => "table creation rejects types whose cannotBeStoredInTables predicate is true with DATA_TYPE_CANNOT_BE_USED_IN_TABLES"},
      {"file" => "src/Common/ErrorCodes.cpp", "lines" => "304-308", "law" => "error code 370 is DATA_TYPE_CANNOT_BE_USED_IN_TABLES"},
      {"file" => "src/AggregateFunctions/Combinators/AggregateFunctionMap.cpp", "lines" => "487-591", "law" => "Map input dispatches a finite key-type set; tuple/array inputs redirect sum/min/max to mapped-array functions"},
      {"file" => "src/AggregateFunctions/AggregateFunctionSumMap.cpp", "lines" => "parseArguments and registrations 747-981", "law" => "mapped forms require a tuple or at least two arrays; aliases report canonical Map function names"},
      {"file" => "src/AggregateFunctions/Combinators/AggregateFunctionArray.cpp", "lines" => "19-43", "law" => "Array combinator strips exactly one Array layer and forwards parameters"},
      {"file" => "src/AggregateFunctions/AggregateFunctionGroupArray.cpp", "lines" => "792-829,913-916,1040-1044", "law" => "groupArray accepts zero or one positive cap; groupArrayLast requires a cap; array_concat_agg aliases groupArrayArray"},
      {"file" => "src/AggregateFunctions/AggregateFunctionGroupUniqArray.cpp", "lines" => "449-480", "law" => "groupUniqArray accepts zero or one positive cap"},
      {"file" => "src/AggregateFunctions/TimeSeries/AggregateFunctionTimeSeriesGroupArray.cpp", "lines" => "26-96,108-118,170", "law" => "SAF form is identity Array(Tuple(timestamp,value)), requires timestamp DateTime64/DateTime/UInt32 and Float32/Float64, no parameters, gated by setting"},
      {"file" => "src/Core/Settings.cpp", "lines" => "10674-10678", "law" => "enable_time_series_aggregate_functions defaults false and aliases allow_experimental_time_series_aggregate_functions"},
      {"file" => "src/DataTypes/DataTypesBinaryEncoding.cpp", "lines" => "272-307,489-493", "law" => "SAF binary header encodes canonical name, Field parameters, argument count and argument descriptors"},
      {"file" => "src/Common/FieldBinaryEncoding.cpp", "lines" => "21-47,89-99", "law" => "positive UInt64 Field parameter starts with field type byte 0x01 followed by VarUInt"},
      {"file" => "src/Processors/Formats/Impl/BinaryRowOutputFormat.cpp", "lines" => "25-53", "law" => "RowBinaryWithNamesAndTypes binary mode writes VarUInt column count, length-prefixed names, then encoded types"},
    ],
    "scope" => {
      "qualification_boundary" => "Finite discriminating witnesses only; strict outcomes certify only the exact declarations below, not the Cartesian product of families, Map key types, recursive shapes, parameters, or storage leaves. Exploratory cases do not enter the pass certificate.",
      "strict_construction_cases" => cases.count { |item| item.fetch("cohort") == "strict" && item.fetch("kind") == "construction" },
      "exploratory_construction_cases" => cases.count { |item| item.fetch("cohort") == "exploratory" },
      "strict_descriptor_cases" => cases.count { |item| item.fetch("kind") == "descriptor" },
      "aggregate_families" => %w[sumMap minMap maxMap groupArrayArray groupArrayLastArray groupUniqArrayArray groupUniqArrayArrayMap sumMappedArrays minMappedArrays maxMappedArrays timeSeriesGroupArray],
      "existing_recursive_controls" => %w[any anyLast any_respect_nulls anyLast_respect_nulls min max sum sumWithOverflow groupBitAnd groupBitOr groupBitXor],
      "special_exploratory_types" => %w[Bool UUID IPv4 IPv6 Enum8 IntervalDay Nothing QBit Nested Variant Dynamic JSON nested-SimpleAggregateFunction],
      "construction_uses_runtime_values" => false,
    },
    "process_timeout_seconds" => PROCESS_TIMEOUT_SECONDS,
    "cases" => cases,
  }
  write_new(File.join(root, "manifest.json"), JSON.pretty_generate(manifest) + "\n")

  begin
    source_pin = pin_source!(root)
    runtime_pin = pin_runtime!(root, binary)
  rescue StandardError => error
    write_new(File.join(root, "fatal.json"), JSON.pretty_generate({
      "phase" => "source_or_runtime_pin",
      "error" => "#{error.class}: #{error.message}",
      "cases_interpreted" => 0,
    }) + "\n")
    warn "W222 refused to interpret construction results: #{error.message}"
    return 2
  end

  results = []
  cases.each_with_index do |test_case, index|
    puts "W222 construction case #{index + 1}/#{cases.length}: #{test_case.fetch("id")}"
    begin
      results << run_case(root, binary, test_case)
    rescue StandardError => error
      results << test_case.merge(
        "classification" => "probe_failure",
        "detail" => "#{error.class}: #{error.message}",
      )
    end
  end

  strict = results.select { |result| result.fetch("cohort") == "strict" }
  exploratory = results.select { |result| result.fetch("cohort") == "exploratory" }
  mismatches = strict.count { |result| result.fetch("classification") == "law_mismatch" }
  failures = results.count { |result| result.fetch("classification") == "probe_failure" }
  summary = {
    "suite" => "W222 independent SimpleAggregateFunction recursive construction and descriptor probe",
    "source_pin" => source_pin,
    "runtime_pin" => runtime_pin,
    "case_count" => results.length,
    "strict_case_count" => strict.length,
    "strict_expected_accepted" => strict.count { |result| result.fetch("expected") == "accepted" },
    "strict_expected_refused" => strict.count { |result| result.fetch("expected") == "refused" },
    "strict_observed_accepted" => strict.count { |result| %w[accepted descriptor_exact].include?(result.fetch("classification")) },
    "strict_observed_expected_refusal" => strict.count { |result| result.fetch("classification") == "expected_refusal" },
    "exploratory_constructed" => exploratory.count { |result| result.fetch("classification") == "exploratory_constructed" },
    "exploratory_refused" => exploratory.count { |result| result.fetch("classification") == "exploratory_refused" },
    "exploratory_storage_refused" => exploratory.count { |result| result.fetch("classification") == "exploratory_storage_refused" },
    "law_mismatches" => mismatches,
    "probe_failures" => failures,
    "matrix" => results,
  }
  write_new(File.join(root, "matrix.json"), JSON.pretty_generate(summary) + "\n")
  puts "W222 matrix=#{File.join(root, "matrix.json")} cases=#{results.length} law_mismatches=#{mismatches} probe_failures=#{failures}"
  mismatches.zero? && failures.zero? ? 0 : 1
end

exit(main)
