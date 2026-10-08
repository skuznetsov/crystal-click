#!/usr/bin/env ruby
# Independent stock ClickHouse physical witnesses for recursive SAF storage.
# The manifest owns literal recursive values; no Crystal eligibility table is
# imported. This runner only creates/captures stock Wide parts and their oracle.
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
ROOT_PREFIX = "/private/tmp/crystal-click-w222-physical.".freeze
PROCESS_TIMEOUT_SECONDS = 25
TERM_GRACE_SECONDS = 2
MEMORY_LIMIT_BYTES = 1_073_741_824
ROW_KEYS = [11, 22, 33, 44, 55].freeze
MARK_ROWS = [2, 2, 1].freeze

# These anchors pin the source snapshot as a comparison source. The executable
# pin above is a separately identified runtime; this probe does not claim the
# runtime was built from this source tree.
SOURCE_FILE_SHA256 = {
  "src/DataTypes/DataTypeCustomSimpleAggregateFunction.cpp" => "6c4502cdd659d59cc83b953a03399fa37d491f097ca38f445bfa74b1654e877d",
  "src/DataTypes/DataTypesBinaryEncoding.h" => "92c3362477dc283302fc84713413f45fd6c92c7273309c6efb41425d22c5485f",
  "src/DataTypes/DataTypesBinaryEncoding.cpp" => "78ba394f20ccd2a00f5be6b8c4d470fafb1c91a6f87bb27c301c2d3203f28f87",
}.freeze

def require_true(condition, message)
  raise ArgumentError, message unless condition
end

def safe_label(value)
  value.gsub(/[^A-Za-z0-9_.-]/, "_")
end

def write_new(path, bytes)
  File.open(path, "wbx", 0o600) { |file| file.write(bytes) }
rescue Errno::EEXIST
  raise "refusing to overwrite W222 physical evidence: #{path}"
end

def make_dir(path)
  Dir.mkdir(path, 0o700)
rescue Errno::EEXIST
  raise "refusing to reuse W222 physical evidence directory: #{path}"
end

def prepare_root!(argument)
  require_true(argument && argument.match?(/\A#{Regexp.escape(ROOT_PREFIX)}[A-Za-z0-9_-]+\z/),
    "usage: CLICKHOUSE_BIN=/path/to/clickhouse ruby scripts/probe_simple_aggregate_physical_w222.rb #{ROOT_PREFIX}<fresh-leaf>")
  require_true(File.directory?(argument) && !File.symlink?(argument),
    "W222 physical root must be a ROOT-created, real directory: #{argument}")
  root = File.realpath(argument)
  require_true(root == argument && root.start_with?(ROOT_PREFIX) && File.dirname(root) == "/private/tmp",
    "W222 physical root must be a canonical direct /private/tmp child")
  require_true(Dir.empty?(root), "refusing to reuse nonempty W222 physical root: #{root}")
  %w[evidence stores parts].each { |name| make_dir(File.join(root, name)) }
  make_dir(File.join(root, "evidence", "processes"))
  make_dir(File.join(root, "evidence", "cases"))
  root
end

def hex_bytes(hex)
  require_true(hex.is_a?(String) && hex.bytesize.even? && hex.match?(/\A(?:[0-9a-f]{2})*\z/),
    "literal value bytes must be even lowercase hexadecimal")
  [hex].pack("H*").b
end

def little_integer(value, bits)
  width = bits / 8
  unsigned = value & ((1 << bits) - 1)
  Array.new(width) { |index| (unsigned >> (index * 8)) & 0xff }.pack("C*").b
end

def raw_hex(value, bits)
  {"raw_hex" => little_integer(value, bits).unpack1("H*")}
end

def raw_float32(hex)
  {"raw_hex" => hex}
end

def raw_float64(hex)
  {"raw_hex" => hex}
end

def raw_string(bytes)
  {"raw_hex" => bytes.b.unpack1("H*")}
end

def varuint(value)
  require_true(value >= 0, "RowBinary VarUInt cannot be negative")
  result = +"".b
  remaining = value
  while remaining >= 0x80
    result << ((remaining & 0x7f) | 0x80)
    remaining >>= 7
  end
  result << remaining
end

def fixed_type(name, width)
  {"kind" => "fixed", "name" => name, "width" => width}
end

def string_type
  {"kind" => "string", "name" => "String"}
end

def array_type(child)
  {"kind" => "array", "name" => "Array(#{child.fetch("name")})", "child" => child}
end

def tuple_type(children, names = nil)
  require_true(names.nil? || names.length == children.length, "named Tuple fixture field count differs")
  fields = children.each_with_index.map do |child, index|
    names ? "#{names.fetch(index)} #{child.fetch("name")}" : child.fetch("name")
  end
  name = "Tuple(#{fields.join(", ")})"
  {"kind" => "tuple", "name" => name, "children" => children, "field_names" => names || []}
end

def map_type(key, value)
  {"kind" => "map", "name" => "Map(#{key.fetch("name")}, #{value.fetch("name")})",
    "key" => key, "value" => value}
end

def nullable_type(child)
  {"kind" => "nullable", "name" => "Nullable(#{child.fetch("name")})", "child" => child}
end

def encode_value(type, value)
  case type.fetch("kind")
  when "fixed"
    bytes = hex_bytes(value.fetch("raw_hex"))
    require_true(bytes.bytesize == type.fetch("width"), "#{type.fetch("name")} literal width differs")
    bytes
  when "string"
    bytes = hex_bytes(value.fetch("raw_hex"))
    varuint(bytes.bytesize) + bytes
  when "array"
    require_true(value.is_a?(Array), "#{type.fetch("name")} literal is not an Array")
    varuint(value.length) + value.map { |child| encode_value(type.fetch("child"), child) }.join.b
  when "tuple"
    require_true(value.is_a?(Array) && value.length == type.fetch("children").length,
      "#{type.fetch("name")} literal has the wrong Tuple arity")
    type.fetch("children").each_with_index.map do |child, index|
      encode_value(child, value.fetch(index))
    end.join.b
  when "map"
    require_true(value.is_a?(Array), "#{type.fetch("name")} literal is not a Map entry list")
    pairs = value.map do |pair|
      require_true(pair.is_a?(Array) && pair.length == 2, "Map literal entry is not a key/value pair")
      encode_value(type.fetch("key"), pair.fetch(0)) + encode_value(type.fetch("value"), pair.fetch(1))
    end
    varuint(pairs.length) + pairs.join.b
  when "nullable"
    value.nil? ? "\x01".b : ("\x00".b + encode_value(type.fetch("child"), value))
  else
    raise ArgumentError, "unlisted W222 RowBinary value kind #{type.fetch("kind").inspect}"
  end
end

def profile(id, source_function, canonical_function, storage, rows, category, settings: [], string_mode: nil)
  storage_name = storage.fetch("name")
  source_type = "SimpleAggregateFunction(#{source_function}, #{storage_name})"
  canonical_type = "SimpleAggregateFunction(#{canonical_function}, #{storage_name})"
  string_type_present = storage_name.match?(/(?:^|\W)String(?:\W|$)/)
  modes = if string_type_present
            %w[single_stream with_size_stream]
          else
            [nil]
          end
  if string_mode
    modes = [string_mode]
  end
  modes.map do |mode|
    label = mode ? "#{id}_#{mode}" : id
    row_records = rows.each_with_index.map do |value, index|
      raw = encode_value(storage, value)
      {"key" => ROW_KEYS.fetch(index), "value" => value, "value_rowbinary_hex" => raw.unpack1("H*")}
    end
    {
      "id" => label,
      "category" => category,
      "source_function" => source_function,
      "canonical_function" => canonical_function,
      "source_type" => source_type,
      "declared_type" => canonical_type,
      "storage_type" => storage_name,
      "storage_spec" => storage,
      "string_serialization_mode" => mode || "omitted_default",
      "source_string_serialization_mode" => mode || "with_size_stream",
      "settings" => settings,
      "row_keys" => ROW_KEYS,
      "mark_rows" => MARK_ROWS,
      "rowbinary_values" => row_records,
      "construction_expectation" => "strict_stock_construction_positive; failure is not skipped",
    }
  end
end

def declared_profiles
  i32 = fixed_type("Int32", 4)
  i64 = fixed_type("Int64", 8)
  u32 = fixed_type("UInt32", 4)
  u64 = fixed_type("UInt64", 8)
  u8 = fixed_type("UInt8", 1)
  i16 = fixed_type("Int16", 2)
  f32 = fixed_type("Float32", 4)
  f64 = fixed_type("Float64", 8)
  string = string_type

  map_i32_i64 = map_type(i32, i64)
  tuple_arrays = tuple_type([array_type(i32), array_type(i64)])
  tuple_three_arrays = tuple_type([array_type(i32), array_type(i64), array_type(i64)])
  array_u64 = array_type(u64)
  array_string = array_type(string)
  nested_array_u64 = array_type(array_u64)
  map_i32_array_i64 = map_type(i32, array_type(i64))
  map_string_u64 = map_type(string, u64)
  map_string_array_u8 = map_type(string, array_type(u8))
  named_key_value = tuple_type([u64, string], ["key", "value"])
  array_named_key_value = array_type(named_key_value)
  nullable_u64 = nullable_type(u64)
  nullable_i64 = nullable_type(i64)
  nullable_string = nullable_type(string)
  ts_u32_f64 = array_type(tuple_type([u32, f64]))
  ts_datetime64_f32 = array_type(tuple_type([fixed_type("DateTime64(3, 'UTC')", 8), f32]))
  ts_datetime_f64 = array_type(tuple_type([fixed_type("DateTime('UTC')", 4), f64]))

  u = lambda { |value| raw_hex(value, 64) }
  i = lambda { |value, bits = 64| raw_hex(value, bits) }
  s = lambda { |value| raw_string(value) }
  f32v = lambda { |hex| raw_float32(hex) }
  f64v = lambda { |hex| raw_float64(hex) }
  rows_map = [
    [],
    [[i.call(-7, 32), i.call(100)], [i.call(13, 32), i.call(-200)]],
    [[i.call(0, 32), i.call(0)]],
    [[i.call((1 << 31) - 1, 32), i.call(-(1 << 63))]],
    [[i.call(-(1 << 31), 32), i.call((1 << 63) - 1)]],
  ]
  rows_tuple_arrays = [
    [[], []],
    [[i.call(-7, 32), i.call(13, 32)], [i.call(100), i.call(-200)]],
    [[i.call(0, 32)], [i.call(0)]],
    [[i.call((1 << 31) - 1, 32)], [i.call(-(1 << 63))]],
    [[i.call(-(1 << 31), 32), i.call((1 << 31) - 1, 32)], [i.call((1 << 63) - 1), i.call(-(1 << 63))]],
  ]
  rows_tuple_three = [
    [[], [], []],
    [[i.call(1, 32), i.call(2, 32)], [i.call(3), i.call(4)], [i.call(5), i.call(6)]],
    [[i.call(0, 32)], [i.call(0)], [i.call(0)]],
    [[i.call((1 << 31) - 1, 32)], [i.call(-(1 << 63))], [i.call(17)]],
    [[i.call(-(1 << 31), 32)], [i.call((1 << 63) - 1)], [i.call(-(1 << 63))]],
  ]
  rows_u64 = [[], [u.call(1), u.call(2)], [u.call(0)], [u.call((1 << 64) - 1)], [u.call(5), u.call(6), u.call(7)]]
  rows_strings = [[], [s.call("a\x00"), s.call("")], [s.call("b")], [s.call("\x00x")], [s.call("tail")]]
  rows_nested_array = [[], [[u.call(1), u.call(2)]], [[], [u.call(3)]], [[u.call((1 << 64) - 1)], []], [[u.call(5), u.call(6)]]]
  rows_map_array = [
    [],
    [[i.call(-7, 32), [i.call(100), i.call(-200)]], [i.call(13, 32), []]],
    [[i.call(0, 32), [i.call(0)]]],
    [[i.call((1 << 31) - 1, 32), [i.call(-(1 << 63))]]],
    [[i.call(-(1 << 31), 32), [i.call((1 << 63) - 1), i.call(-(1 << 63))]]],
  ]
  rows_ts_u32_f64 = [
    [],
    [[raw_hex(1_000, 32), f64v.call("000000000000f83f")], [raw_hex(1_001, 32), f64v.call("00000000000002c0")]],
    [[raw_hex(0, 32), f64v.call("0000000000000000")]],
    [[raw_hex((1 << 32) - 1, 32), f64v.call("000000000000e03f")]],
    [[raw_hex(42, 32), f64v.call("0000000000000440")], [raw_hex(43, 32), f64v.call("0000000000000c40")]],
  ]
  rows_ts_datetime64_f32 = [
    [],
    [[raw_hex(1_000_000, 64), f32v.call("0000c03f")], [raw_hex(1_001_000, 64), f32v.call("000010c0")]],
    [[raw_hex(0, 64), f32v.call("00000000")]],
    [[raw_hex(4_294_967_000, 64), f32v.call("0000803f")]],
    [[raw_hex(-2_208_902_400_000, 64), f32v.call("00004040")]],
  ]
  rows_ts_datetime_f64 = [
    [],
    [[raw_hex(1_000, 32), f64v.call("000000000000f83f")]],
    [[raw_hex(0, 32), f64v.call("0000000000000000")]],
    [[raw_hex(4_294_967_000, 32), f64v.call("000000000000e03f")]],
    [[raw_hex(42, 32), f64v.call("0000000000000440")]],
  ]
  rows_map_string = [
    [],
    [[s.call("k\x00a"), u.call(100)], [s.call(""), u.call(200)]],
    [[s.call("zero"), u.call(0)]],
    [[s.call("max"), u.call((1 << 64) - 1)]],
    [[s.call("last"), u.call(5)]],
  ]
  rows_map_string_array_u8 = [
    [],
    [[s.call("k\x00"), [raw_hex(1, 8), raw_hex(2, 8)]], [s.call(""), [raw_hex(3, 8)]]],
    [[s.call("zero"), []]],
    [[s.call("max"), [raw_hex(255, 8)]]],
    [[s.call("tail"), [raw_hex(5, 8), raw_hex(6, 8)]]],
  ]
  rows_named_tuple = [
    [u.call(1), s.call("one\x00")],
    [u.call(2), s.call("two")],
    [u.call(0), s.call("")],
    [u.call((1 << 64) - 1), s.call("max")],
    [u.call(5), s.call("tail\x00")],
  ]
  rows_nullable_u64 = [u.call(100), nil, u.call(0), u.call((1 << 64) - 1), u.call(42)]
  rows_nullable_i64 = [i.call(100), nil, i.call(0), i.call(-(1 << 63)), i.call((1 << 63) - 1)]
  rows_nullable_string = [s.call("a"), nil, s.call("\x00"), s.call("middle"), s.call("z")]
  rows_array_named_tuple = [[], [rows_named_tuple[0], rows_named_tuple[1]], [rows_named_tuple[2]], [rows_named_tuple[3]], [rows_named_tuple[4]]]
  rows_array_of_array = rows_nested_array

  cases = []
  cases.concat(profile("sumMap_map_i32_i64", "sumMap", "sumMap", map_i32_i64, rows_map, "map"))
  cases.concat(profile("minMap_map_i32_i64", "minMap", "minMap", map_i32_i64, rows_map, "map"))
  cases.concat(profile("maxMap_map_i32_i64", "maxMap", "maxMap", map_i32_i64, rows_map, "map"))
  cases.concat(profile("sumMappedArrays_tuple_canonicalizes", "sumMappedArrays", "sumMap", tuple_arrays,
    rows_tuple_arrays, "mapped_arrays"))
  cases.concat(profile("minMappedArrays_tuple_canonicalizes", "minMappedArrays", "minMap", tuple_arrays,
    rows_tuple_arrays, "mapped_arrays"))
  cases.concat(profile("maxMappedArrays_tuple_canonicalizes", "maxMappedArrays", "maxMap", tuple_arrays,
    rows_tuple_arrays, "mapped_arrays"))
  cases.concat(profile("sumMap_tuple_arrays", "sumMap", "sumMap", tuple_arrays, rows_tuple_arrays, "mapped_arrays"))
  cases.concat(profile("sumMappedArrays_three_arrays", "sumMappedArrays", "sumMap", tuple_three_arrays,
    rows_tuple_three, "mapped_arrays"))

  cases.concat(profile("groupArrayArray_uint64", "groupArrayArray", "groupArrayArray", array_u64,
    rows_u64, "array"))
  cases.concat(profile("groupArrayArray_uint64_capped", "groupArrayArray(3)", "groupArrayArray(3)",
    array_u64, rows_u64, "array_parameter"))
  cases.concat(profile("groupArrayArray_capped_string", "groupArrayArray(3)", "groupArrayArray(3)",
    array_string, rows_strings, "array_parameter"))
  cases.concat(profile("array_concat_agg_alias", "array_concat_agg", "groupArrayArray", array_u64,
    rows_u64, "canonical_alias"))
  cases.concat(profile("groupArrayArray_nested_array", "groupArrayArray", "groupArrayArray", nested_array_u64,
    rows_nested_array, "recursive_array"))
  cases.concat(profile("groupArrayLastArray_cap5", "groupArrayLastArray(5)", "groupArrayLastArray(5)",
    array_u64, rows_u64, "array_required_parameter"))
  cases.concat(profile("groupUniqArrayArray_uint64", "groupUniqArrayArray", "groupUniqArrayArray", array_u64,
    rows_u64, "array"))
  cases.concat(profile("groupUniqArrayArray_capped_string", "groupUniqArrayArray(7)", "groupUniqArrayArray(7)",
    array_string, rows_strings, "array_parameter"))
  cases.concat(profile("groupUniqArrayArrayMap_map_i32_array_i64", "groupUniqArrayArrayMap",
    "groupUniqArrayArrayMap", map_i32_array_i64, rows_map_array, "map_array"))
  cases.concat(profile("groupUniqArrayArrayMap_capped_map_string_array_u8", "groupUniqArrayArrayMap(4)",
    "groupUniqArrayArrayMap(4)", map_string_array_u8, rows_map_string_array_u8, "map_array_parameter"))

  ts_setting = ["--enable_time_series_aggregate_functions=1"]
  cases.concat(profile("timeSeriesGroupArray_u32_f64", "timeSeriesGroupArray", "timeSeriesGroupArray",
    ts_u32_f64, rows_ts_u32_f64, "time_series", settings: ts_setting))
  cases.concat(profile("timeSeriesGroupArray_datetime64_f32", "timeSeriesGroupArray", "timeSeriesGroupArray",
    ts_datetime64_f32, rows_ts_datetime64_f32, "time_series", settings: ts_setting))
  cases.concat(profile("timeSeriesGroupArray_datetime_f64", "timeSeriesGroupArray", "timeSeriesGroupArray",
    ts_datetime_f64, rows_ts_datetime_f64, "time_series", settings: ts_setting))

  cases.concat(profile("any_map_string_u64", "any", "any", map_string_u64, rows_map_string, "existing_any"))
  cases.concat(profile("anyLast_array_u64", "anyLast", "anyLast", array_u64, rows_u64, "existing_anyLast"))
  cases.concat(profile("anyLast_named_tuple", "anyLast", "anyLast", named_key_value, rows_named_tuple,
    "existing_named_tuple"))
  cases.concat(profile("any_respect_nullable_u64", "any_respect_nulls", "any_respect_nulls", nullable_u64,
    rows_nullable_u64, "existing_inner_nullable"))
  cases.concat(profile("anyLast_respect_nullable_u64", "anyLast_respect_nulls", "anyLast_respect_nulls",
    nullable_u64, rows_nullable_u64, "existing_inner_nullable"))
  cases.concat(profile("min_array_nested", "min", "min", nested_array_u64, rows_array_of_array,
    "existing_min_recursive"))
  cases.concat(profile("min_map_i32_i64", "min", "min", map_i32_i64, rows_map, "existing_min_recursive"))
  cases.concat(profile("max_map_i32_array_i64", "max", "max", map_i32_array_i64, rows_map_array,
    "existing_max_recursive"))
  cases.concat(profile("min_array_named_tuple", "min", "min", array_named_key_value,
    rows_array_named_tuple, "existing_nested_array_tuple"))
  cases.concat(profile("min_nullable_i64", "min", "min", nullable_i64, rows_nullable_i64,
    "existing_inner_nullable"))
  cases.concat(profile("max_nullable_string", "max", "max", nullable_string, rows_nullable_string,
    "existing_inner_nullable"))

  require_true(cases.length == 39, "W222 exact physical profile roster changed: expected 39, got #{cases.length}")
  ids = cases.map { |item| item.fetch("id") }
  require_true(ids.uniq == ids, "W222 physical roster contains duplicate ids")
  cases.each do |item|
    require_true(item.fetch("declared_type") == "SimpleAggregateFunction(#{item.fetch("canonical_function")}, #{item.fetch("storage_type")})",
      "canonical declared type differs from the independently composed storage type")
    require_true(item.fetch("rowbinary_values").length == 5, "fixture row count differs from fixed key roster")
  end
  cases
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
    # Inherit run_safe's process group. Timeout signals only this positive PID.
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
    "--enable_time_time64_type=1", "--max_threads=1", "--max_insert_threads=1",
    "--max_execution_time=20", "--max_memory_usage=#{MEMORY_LIMIT_BYTES}"]
  argv << "--multiquery" if multiquery
  argv.concat(extra_args)
  argv.concat(["--query", sql])
end

class Recorder
  attr_reader :root

  def initialize(root, binary)
    @root = root
    @binary = binary
    @sequence = 0
  end

  def run(label, store, sql, input: nil, multiquery: false, extra_args: [])
    @sequence += 1
    stem = format("%05d-%s", @sequence, safe_label(label))
    prefix = File.join(@root, "evidence", "processes", stem)
    argv = query_argv(@binary, store, sql, multiquery: multiquery, extra_args: extra_args)
    write_new(prefix + ".sql", (sql.end_with?("\n") ? sql : sql + "\n").b)
    write_new(prefix + ".argv.json", JSON.pretty_generate({
      "argv" => argv,
      "environment" => {"TZ" => "UTC"},
      "timeout_seconds" => PROCESS_TIMEOUT_SECONDS,
      "stdin_bytes" => input && input.bytesize,
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

def checked_path(path, store, label)
  root = File.realpath(store)
  expanded = File.expand_path(path, store)
  real = File.realpath(expanded)
  require_true(real.start_with?(root + File::SEPARATOR) && real != root, "#{label} escapes its process store")
  real
rescue Errno::ENOENT, Errno::EACCES => error
  raise "cannot resolve #{label} safely: #{error.message}"
end

def part_inventory(part)
  files = []
  Find.find(part) do |path|
    next if path == part
    require_true(!File.symlink?(path), "symlink in immutable source part: #{path}")
    next if File.directory?(path)
    require_true(File.file?(path), "unexpected source part entry: #{path}")
    files << {"path" => path.delete_prefix(part + File::SEPARATOR), "size" => File.size(path),
      "sha256" => Digest::SHA256.file(path).hexdigest}
  end
  files.sort_by { |entry| entry.fetch("path") }
end

def safe_text(path)
  File.binread(path).force_encoding(Encoding::UTF_8).scrub
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
  "#{label}: expected #{expected.bytesize} bytes, observed #{actual.bytesize}; first mismatch byte #{mismatch} expected #{wanted}, got #{observed}"
end

def rowbinary_input(profile)
  output = +"".b
  profile.fetch("rowbinary_values").each do |row|
    output << little_integer(row.fetch("key"), 64)
    output << hex_bytes(row.fetch("value_rowbinary_hex"))
  end
  output
end

def expected_window(profile, indices)
  output = +"".b
  indices.each do |index|
    row = profile.fetch("rowbinary_values").fetch(index)
    output << little_integer(row.fetch("key"), 64)
    output << hex_bytes(row.fetch("value_rowbinary_hex"))
  end
  output
end

def profile_sql(profile, table, case_dir)
  files = {
    "full" => File.join(case_dir, "rowbinary-full.bin"),
    "middle" => File.join(case_dir, "rowbinary-middle.bin"),
    "empty" => File.join(case_dir, "rowbinary-empty.bin"),
  }
  files.each_value { |path| require_true(!File.exist?(path) && !File.symlink?(path), "refusing to overwrite #{path}") }
  escape = lambda { |path| path.gsub("'", "\\'") }
  table_name = "default.#{table}"
  [
    "SELECT '__W222_SCHEMA__', name, type, toString(position) FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;",
    "SELECT '__W222_RUNTIME_TYPE__', toTypeName(pk), toTypeName(v) FROM #{table_name} LIMIT 1 FORMAT TSVRaw;",
    "SELECT '__W222_DATA_PATH__', data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw;",
    "SELECT '__W222_PART__', name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;",
    "CHECK TABLE #{table_name} FORMAT TabSeparated;",
    "SELECT pk, v FROM #{table_name} ORDER BY pk INTO OUTFILE '#{escape.call(files.fetch("full"))}' FORMAT RowBinary;",
    "SELECT pk, v FROM #{table_name} WHERE pk BETWEEN 22 AND 44 ORDER BY pk INTO OUTFILE '#{escape.call(files.fetch("middle"))}' FORMAT RowBinary;",
    "SELECT pk, v FROM #{table_name} WHERE pk=0 INTO OUTFILE '#{escape.call(files.fetch("empty"))}' FORMAT RowBinary;",
  ].join("\n") + "\n"
end

def inspect_profile!(profile, root, store, record, case_dir)
  expected_type = profile.fetch("declared_type")
  schema_rows = tagged_rows(record.fetch(:stdout), "__W222_SCHEMA__")
  expected_schema = [["__W222_SCHEMA__", "pk", "UInt64", "1"], ["__W222_SCHEMA__", "v", expected_type, "2"]]
  require_true(schema_rows == expected_schema, "system.columns exact nominal declaration differs: #{schema_rows.inspect}")
  runtime_rows = tagged_rows(record.fetch(:stdout), "__W222_RUNTIME_TYPE__")
  require_true(runtime_rows == [["__W222_RUNTIME_TYPE__", "UInt64", expected_type]],
    "toTypeName does not equal the exact canonical nominal SAF declaration")
  data_rows = tagged_rows(record.fetch(:stdout), "__W222_DATA_PATH__")
  part_rows = tagged_rows(record.fetch(:stdout), "__W222_PART__")
  require_true(data_rows.length == 1 && data_rows.first.length == 2 && !data_rows.first[1].empty?,
    "source data path is missing or ambiguous")
  require_true(part_rows.length == 1 && part_rows.first.length == 6, "expected one active Wide source part")
  part_name, rows_text, marks_text, part_type, part_path_text = part_rows.first.drop(1)
  require_true(part_name == "all_1_1_0" && rows_text == "5" && marks_text == "4" && part_type == "Wide",
    "source part identity/grid differs: #{part_rows.inspect}")
  check_lines = record.fetch(:stdout).force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp).select do |line|
    line.start_with?("all_1_1_0\t")
  end
  require_true(check_lines == ["all_1_1_0\t1\t"], "CHECK TABLE did not validate the one source part: #{check_lines.inspect}")

  data_path = checked_path(data_rows.first[1], store, "table data path")
  part_path = checked_path(part_path_text, store, "active part path")
  require_true(part_path.start_with?(data_path + File::SEPARATOR) && File.basename(part_path) == "all_1_1_0",
    "discovered source part path is not below the table data path")
  inventory = part_inventory(part_path)
  names = inventory.map { |entry| entry.fetch("path") }
  required = %w[columns.txt columns_substreams.txt count.txt checksums.txt serialization.json default_compression_codec.txt metadata_version.txt primary.idx]
  require_true((required - names).empty?, "source Wide part lacks required metadata files")
  require_true(names.any? { |name| name.end_with?(".mrk2") } && names.grep(/\.mrk(?:\.|\z)/).empty?,
    "source part is missing plain mrk2 marks or contains non-mrk2 marks")

  columns = safe_text(File.join(part_path, "columns.txt"))
  expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`v` #{expected_type}\n"
  require_true(columns == expected_columns, "columns.txt exact declarations differ: #{columns.inspect}")
  substreams = safe_text(File.join(part_path, "columns_substreams.txt"))
  serialization_text = safe_text(File.join(part_path, "serialization.json"))
  serialization = JSON.parse(serialization_text)
  checksums_text = safe_text(File.join(part_path, "checksums.txt"))
  require_true(safe_text(File.join(part_path, "count.txt")).strip == "5", "count.txt row count differs")
  require_true(safe_text(File.join(part_path, "default_compression_codec.txt")).strip == "CODEC(LZ4)",
    "default compression codec differs")

  copy_parent = File.join(root, "parts", profile.fetch("id"))
  make_dir(copy_parent)
  copied_part = File.join(copy_parent, "all_1_1_0")
  require_true(!File.exist?(copied_part) && !File.symlink?(copied_part), "refusing to overwrite source part copy")
  FileUtils.cp_r(part_path, copied_part)
  require_true(part_inventory(copied_part) == inventory, "copied immutable source part changed")

  windows = {
    "full" => (0...5).to_a,
    "middle" => [1, 2, 3],
    "empty" => [],
  }
  rowbinary = {}
  mismatches = []
  windows.each do |name, indices|
    path = File.join(case_dir, "rowbinary-#{name}.bin")
    observed = File.binread(path)
    expected = expected_window(profile, indices)
    mismatch = compare_binary(observed, expected, "source #{name} RowBinary")
    mismatches << mismatch if mismatch
    rowbinary[name] = {"path" => path.delete_prefix(root + File::SEPARATOR),
      "bytes" => observed.bytesize, "sha256" => Digest::SHA256.hexdigest(observed),
      "expected_bytes" => expected.bytesize, "expected_sha256" => Digest::SHA256.hexdigest(expected),
      "matches_independent_literal" => mismatch.nil?}
  end
  require_true(mismatches.empty?, mismatches.join("; "))

  {
    "source_type" => profile.fetch("source_type"),
    "canonical_declared_type" => expected_type,
    "source_function" => profile.fetch("source_function"),
    "canonical_function" => profile.fetch("canonical_function"),
    "source_part_path" => part_path,
    "copied_part_path" => copied_part,
    "row_count" => 5,
    "native_mark_count_with_terminal" => 4,
    "real_mark_rows_expected" => MARK_ROWS,
    "part_file_inventory" => inventory,
    "columns_txt" => columns,
    "columns_substreams_txt" => substreams,
    "serialization_json_text" => serialization_text,
    "serialization_json" => serialization,
    "checksums_txt" => checksums_text,
    "checksums_sha256" => Digest::SHA256.hexdigest(checksums_text.b),
    "metadata_version_txt" => safe_text(File.join(part_path, "metadata_version.txt")).strip,
    "default_compression_codec_txt" => safe_text(File.join(part_path, "default_compression_codec.txt")).strip,
    "rowbinary" => rowbinary,
  }
end

def source_pin!(root)
  require_true(File.directory?(SOURCE_ROOT), "pinned source root is absent")
  files = SOURCE_FILE_SHA256.map do |relative, expected|
    path = File.join(SOURCE_ROOT, relative)
    require_true(File.file?(path) && !File.symlink?(path), "pinned source anchor is absent or symlinked: #{relative}")
    actual = Digest::SHA256.file(path).hexdigest
    {"path" => relative, "expected_sha256" => expected, "actual_sha256" => actual, "matches" => actual == expected}
  end
  pin = {"source_reference" => "#{SOURCE_ROOT}@#{SOURCE_REVISION}",
    "source_revision_from_task_context_not_git_revalidated" => SOURCE_REVISION,
    "runtime_built_from_this_snapshot_not_asserted" => true, "file_hashes" => files}
  write_new(File.join(root, "source_pin.json"), JSON.pretty_generate(pin) + "\n")
  require_true(files.all? { |entry| entry.fetch("matches") }, "pinned ClickHouse source file hash mismatch")
  pin
end

def pin_runtime!(root, recorder, binary)
  require_true(File.file?(binary) && File.executable?(binary) && !File.symlink?(binary),
    "CLICKHOUSE_BIN is absent, non-executable, or symlinked")
  sha = Digest::SHA256.file(binary).hexdigest
  require_true(sha == EXECUTABLE_SHA256, "ClickHouse runtime SHA-256 mismatch: #{sha}")
  store = File.join(root, "stores", "pins")
  make_dir(store)
  version_record = recorder.run("pin-version", store, "SELECT version() FORMAT TSVRaw")
  require_true(version_record.dig(:status, "success") && !version_record.dig(:status, "timed_out"),
    "version pin process failed")
  version = version_record.fetch(:stdout).strip
  require_true(version == VERSION, "ClickHouse version mismatch: #{version.inspect}")
  build_record = recorder.run("pin-build", store,
    "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw")
  require_true(build_record.dig(:status, "success") && !build_record.dig(:status, "timed_out"),
    "build pin process failed")
  build = build_record.fetch(:stdout).strip
  require_true(build == "VERSION_GITHASH=#{BUILD_HASH}", "ClickHouse build hash mismatch: #{build.inspect}")
  pin = {"runtime_version" => version, "runtime_build_hash" => BUILD_HASH, "runtime_sha256" => sha,
    "comparison_source" => "#{SOURCE_ROOT}@#{SOURCE_REVISION}", "runtime_source_correlation" => "not_asserted"}
  write_new(File.join(root, "runtime_pin.json"), JSON.pretty_generate(pin) + "\n")
  pin
end

def run_profile(profile, root, recorder)
  case_dir = File.join(root, "evidence", "cases", safe_label(profile.fetch("id")))
  make_dir(case_dir)
  store = File.join(root, "stores", safe_label(profile.fetch("id")))
  make_dir(store)
  table = "saf_w222_#{safe_label(profile.fetch("id"))}"
  result = profile.dup
  result["classification"] = "pending"
  result["processes"] = {}
  ddl_settings = STOCK_SETTINGS.dup
  if profile.fetch("string_serialization_mode") != "omitted_default"
    ddl_settings << "string_serialization_version='#{profile.fetch("string_serialization_mode")}'"
  end
  ddl = "CREATE TABLE default.#{table} (pk UInt64, v #{profile.fetch("source_type")}) ENGINE=MergeTree ORDER BY pk SETTINGS #{ddl_settings.join(", ")};"
  extra_args = profile.fetch("settings")
  create = recorder.run("#{profile.fetch("id")}-create", store, ddl, extra_args: extra_args)
  result["processes"]["create"] = create.fetch(:prefix).delete_prefix(root + File::SEPARATOR)
  status = create.fetch(:status)
  unless status.fetch("success") && !status.fetch("timed_out") && !status["spawn_error"] && !status.fetch("signaled")
    output = create.fetch(:stdout) + create.fetch(:stderr)
    result["classification"] = if !status.fetch("timed_out") && !status["spawn_error"] && !status.fetch("signaled") && !status.fetch("reported_clickhouse_codes").empty?
                                  "stock_construction_mismatch"
                                else
                                  "probe_failure"
                                end
    result["failure_status"] = status
    result["failure_excerpt"] = output.force_encoding(Encoding::UTF_8).scrub.lines.map(&:strip).reject(&:empty?).first(5).join(" | ")
    write_new(File.join(case_dir, "case.json"), JSON.pretty_generate(result) + "\n")
    return result
  end

  input = rowbinary_input(profile)
  insert = recorder.run("#{profile.fetch("id")}-insert-rowbinary", store,
    "INSERT INTO default.#{table} FORMAT RowBinary", input: input, extra_args: extra_args)
  result["processes"]["insert"] = insert.fetch(:prefix).delete_prefix(root + File::SEPARATOR)
  write_new(File.join(case_dir, "rowbinary-input.bin"), input)
  result["rowbinary_input"] = {"path" => File.join("evidence", "cases", profile.fetch("id"), "rowbinary-input.bin"),
    "bytes" => input.bytesize, "sha256" => Digest::SHA256.hexdigest(input)}
  unless insert.fetch(:status).fetch("success") && !insert.fetch(:status).fetch("timed_out") && !insert.fetch(:status)["spawn_error"] && !insert.fetch(:status).fetch("signaled")
    result["classification"] = "probe_failure"
    result["failure_status"] = insert.fetch(:status)
    result["failure_excerpt"] = (insert.fetch(:stdout) + insert.fetch(:stderr)).force_encoding(Encoding::UTF_8).scrub.lines.map(&:strip).reject(&:empty?).first(5).join(" | ")
    write_new(File.join(case_dir, "case.json"), JSON.pretty_generate(result) + "\n")
    return result
  end

  inspect_sql = profile_sql(profile, table, case_dir)
  inspection = recorder.run("#{profile.fetch("id")}-inspect", store, inspect_sql, multiquery: true, extra_args: extra_args)
  result["processes"]["inspect"] = inspection.fetch(:prefix).delete_prefix(root + File::SEPARATOR)
  unless inspection.fetch(:status).fetch("success") && !inspection.fetch(:status).fetch("timed_out") && !inspection.fetch(:status)["spawn_error"] && !inspection.fetch(:status).fetch("signaled")
    result["classification"] = "probe_failure"
    result["failure_status"] = inspection.fetch(:status)
    result["failure_excerpt"] = (inspection.fetch(:stdout) + inspection.fetch(:stderr)).force_encoding(Encoding::UTF_8).scrub.lines.map(&:strip).reject(&:empty?).first(5).join(" | ")
    write_new(File.join(case_dir, "case.json"), JSON.pretty_generate(result) + "\n")
    return result
  end

  begin
    result["physical"] = inspect_profile!(profile, root, store, inspection, case_dir)
    result["classification"] = "stock_physical_observed"
  rescue StandardError => error
    result["classification"] = "physical_mismatch"
    result["failure"] = "#{error.class}: #{error.message}"
  end
  write_new(File.join(case_dir, "case.json"), JSON.pretty_generate(result) + "\n")
  result
rescue StandardError => error
  result ||= profile.dup
  result["classification"] = "probe_failure"
  result["failure"] = "#{error.class}: #{error.message}"
  case_dir ||= File.join(root, "evidence", "cases", safe_label(profile.fetch("id")))
  write_new(File.join(case_dir, "case.json"), JSON.pretty_generate(result) + "\n") if File.directory?(case_dir) && !File.exist?(File.join(case_dir, "case.json"))
  result
end

def main
  root = prepare_root!(ARGV.fetch(0, nil))
  binary = ENV.fetch("CLICKHOUSE_BIN")
  cases = declared_profiles
  require_true(cases.length == 39, "physical case count changed after roster validation")
  source_pin = source_pin!(root)
  manifest = {
    "suite" => "W222 independent recursive SimpleAggregateFunction Wide-part/RowBinary probe",
    "source_pin" => source_pin,
    "runtime_pin_expected" => {"version" => VERSION, "build_hash" => BUILD_HASH, "sha256" => EXECUTABLE_SHA256},
    "runtime_built_from_comparison_source_not_asserted" => true,
    "case_count" => cases.length,
    "case_roster" => cases,
    "row_keys" => ROW_KEYS,
    "rows_per_real_mark" => MARK_ROWS,
    "native_mark_grid_includes_terminal" => [2, 2, 1, 0],
    "string_profiles" => %w[single_stream with_size_stream],
    "unsupported_scope" => "No LowCardinality, Variant, Dynamic, JSON/Object, QBit, Nested, or composite outer-Nullable positive profile is claimed.",
    "parameter_scope" => "Finite UInt64 Field parameters are represented only by source-qualified capped array-family witnesses; this is not all-Field parameter qualification.",
    "construction_failures" => "Every listed positive product is strict; a CREATE refusal is a recorded nonzero admission mismatch, never skipped.",
    "table_settings" => STOCK_SETTINGS,
    "process_timeout_seconds" => PROCESS_TIMEOUT_SECONDS,
    "child_process_group" => "inherited from outer guard; bounded child TERM/KILL targets the positive child PID",
  }
  write_new(File.join(root, "manifest.json"), JSON.pretty_generate(manifest) + "\n")
  recorder = Recorder.new(root, binary)
  begin
    runtime_pin = pin_runtime!(root, recorder, binary)
  rescue StandardError => error
    write_new(File.join(root, "fatal.json"), JSON.pretty_generate({"phase" => "runtime_pin", "error" => "#{error.class}: #{error.message}", "cases_started" => 0}) + "\n")
    warn "W222 physical probe refused to interpret stock outcomes: #{error.message}"
    return 2
  end

  results = []
  cases.each_with_index do |item, index|
    puts "W222 physical case #{index + 1}/#{cases.length}: #{item.fetch("id")}"
    results << run_profile(item, root, recorder)
  end
  mismatches = results.count { |item| item.fetch("classification") == "stock_construction_mismatch" }
  failures = results.count { |item| item.fetch("classification") == "probe_failure" }
  physical = results.count { |item| item.fetch("classification") == "stock_physical_observed" }
  physical_mismatches = results.count { |item| item.fetch("classification") == "physical_mismatch" }
  summary = {"suite" => manifest.fetch("suite"), "source_pin" => source_pin, "runtime_pin" => runtime_pin,
    "case_count" => results.length, "stock_physical_observed" => physical,
    "stock_construction_mismatches" => mismatches, "physical_mismatches" => physical_mismatches,
    "probe_failures" => failures, "matrix" => results}
  write_new(File.join(root, "matrix.json"), JSON.pretty_generate(summary) + "\n")
  puts "W222 physical matrix=#{File.join(root, "matrix.json")} cases=#{results.length} physical=#{physical} admission_mismatches=#{mismatches} failures=#{failures + physical_mismatches}"
  physical == results.length && mismatches.zero? && failures.zero? && physical_mismatches.zero? ? 0 : 1
end

exit(main)
