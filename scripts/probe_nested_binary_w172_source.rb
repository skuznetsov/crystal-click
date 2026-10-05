#!/usr/bin/env ruby
# Bounded stock-only binary-law probe for Nested and its Array(Tuple) carrier.
# This observes the pinned ClickHouse runtime; it does not certify library support.
require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "tmpdir"
require "time"

EXPECTED_SOURCE_REVISION = "e9b645ed83ad3c07b64f09fbd014e8f770d8691b"
EXPECTED_VERSION = "ClickHouse local version 26.10.1.1201 (official build)."
EXPECTED_BINARY_SHA256 = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
NESTED_TYPE = "Nested(a UInt64, b String, c Nullable(Int32))"
ARRAY_TUPLE_TYPE = "Array(Tuple(a UInt64, b String, c Nullable(Int32)))"

FIXTURE = [
  { key: 7, values: [[11, "north-0", nil], [103, "south", -17]] },
  { key: 13, values: [] },
  { key: 22, values: [[211, "tail", 31]] }
].freeze

def exclusive_write(path, bytes)
  File.open(path, "wbx", 0o600) { |file| file.write(bytes) }
end

def parse_options
  options = {
    clickhouse: ENV.fetch("CLICKHOUSE_BIN", "/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped"),
    source_root: ENV["W172_SOURCE_ROOT"],
    source_revision: ENV["W172_SOURCE_REVISION"],
    workdir: ENV["W172_WORKDIR"]
  }
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby scripts/probe_nested_binary_w172_source.rb --workdir DIR --source-root DIR --source-revision REV [options]"
    opts.on("--clickhouse PATH", "Pinned ClickHouse local executable") { |value| options[:clickhouse] = value }
    opts.on("--source-root DIR", "ClickHouse source checkout recorded with the source pin") { |value| options[:source_root] = value }
    opts.on("--source-revision REV", "Expected ClickHouse source revision") { |value| options[:source_revision] = value }
    opts.on("--workdir DIR", "Existing scratch parent; a fresh retained child is created") { |value| options[:workdir] = value }
  end
  parser.parse!
  raise "unexpected arguments: #{ARGV.inspect}" unless ARGV.empty?
  raise "--workdir is required" if options[:workdir].nil? || options[:workdir].empty?
  raise "--source-root is required" if options[:source_root].nil? || options[:source_root].empty?
  raise "--source-revision is required" if options[:source_revision].nil? || options[:source_revision].empty?
  options[:workdir] = File.realpath(options[:workdir])
  options[:source_root] = File.realpath(options[:source_root])
  options
end

def varuint(value)
  raise "varuint must be nonnegative" if value.negative?
  bytes = +"".b
  loop do
    byte = value & 0x7f
    value >>= 7
    bytes << (value.zero? ? byte : byte | 0x80)
    break if value.zero?
  end
  bytes
end

def binary_string(value)
  bytes = value.b
  varuint(bytes.bytesize) + bytes
end

def uint64_le(value)
  [value].pack("Q<")
end

def int32_le(value)
  [value].pack("l<")
end

def nullable_int32(value)
  value.nil? ? "\x01".b : "\x00".b + int32_le(value)
end

def nested_values_payload
  FIXTURE.each_with_object(+"".b) do |row, bytes|
    bytes << uint64_le(row.fetch(:key))
    bytes << varuint(row.fetch(:values).length)
    row.fetch(:values).each do |a, b, c|
      bytes << uint64_le(a) << binary_string(b) << nullable_int32(c)
    end
  end
end

def rowbinary_header(nested_type_descriptor)
  # RowBinaryWithNamesAndTypes: column count, names, then self-delimiting types.
  varuint(2) + binary_string("pk") + binary_string("nested") + "\x04".b + nested_type_descriptor
end

NESTED_DESCRIPTOR = ["2f0301610401621501632309"].pack("H*")
ARRAY_TUPLE_DESCRIPTOR = ["1e200301610401621501632309"].pack("H*")
EXPECTED_VALUES = nested_values_payload
EXPECTED_NESTED_OUTPUT = rowbinary_header(NESTED_DESCRIPTOR) + EXPECTED_VALUES
EXPECTED_ARRAY_TUPLE_OUTPUT = rowbinary_header(ARRAY_TUPLE_DESCRIPTOR) + EXPECTED_VALUES

class W172Capture
  attr_reader :root, :records

  def initialize(root)
    @root = root
    @commands = File.join(root, "commands")
    FileUtils.mkdir_p(@commands, mode: 0o700)
    @records = []
  end

  def run(label, argv, sql: nil, stdin_data: "".b)
    index = records.length + 1
    base = format("%02d-%s", index, label.gsub(/[^A-Za-z0-9_.-]/, "_"))
    argv_bytes = JSON.generate(argv)
    argv_path = File.join(@commands, "#{base}.argv.json")
    stdin_path = File.join(@commands, "#{base}.stdin")
    sql_path = sql.nil? ? nil : File.join(@commands, "#{base}.sql")
    stdout_path = File.join(@commands, "#{base}.stdout")
    stderr_path = File.join(@commands, "#{base}.stderr")
    exclusive_write(argv_path, argv_bytes)
    exclusive_write(stdin_path, stdin_data)
    exclusive_write(sql_path, sql) unless sql.nil?

    stdout = "".b
    stderr = "".b
    begin
      stdout, stderr, status = Open3.capture3({ "TZ" => "UTC" }, *argv, stdin_data: stdin_data, binmode: true)
      status_record = {
        "exitstatus" => status.exitstatus,
        "termsig" => status.termsig,
        "success" => status.success?
      }
    rescue StandardError => error
      status_record = {
        "success" => false,
        "spawn_error_class" => error.class.name,
        "spawn_error" => error.message
      }
    end

    exclusive_write(stdout_path, stdout)
    exclusive_write(stderr_path, stderr)
    record = {
      "label" => label,
      "argv" => argv,
      "sql" => sql,
      "status" => status_record,
      "files" => {
        "argv" => argv_path,
        "sql" => sql_path,
        "stdin" => stdin_path,
        "stdout" => stdout_path,
        "stderr" => stderr_path
      },
      "sha256" => {
        "argv_json" => Digest::SHA256.hexdigest(argv_bytes),
        "sql" => sql.nil? ? nil : Digest::SHA256.hexdigest(sql),
        "stdin" => Digest::SHA256.hexdigest(stdin_data),
        "stdout" => Digest::SHA256.hexdigest(stdout),
        "stderr" => Digest::SHA256.hexdigest(stderr)
      }
    }
    records << record
    [record, stdout, stderr]
  end
end

options = parse_options
raise "source revision differs from the pinned revision" unless options[:source_revision] == EXPECTED_SOURCE_REVISION
binary = File.expand_path(options[:clickhouse])
raise "refusing symlinked ClickHouse binary" if File.symlink?(binary)
raise "pinned ClickHouse binary missing or not executable" unless File.file?(binary) && File.executable?(binary)
binary_before = Digest::SHA256.file(binary).hexdigest
raise "ClickHouse binary SHA-256 differs before probe: #{binary_before}" unless binary_before == EXPECTED_BINARY_SHA256

run_root = Dir.mktmpdir("nested-binary-w172-", options[:workdir])
store = File.join(run_root, "clickhouse-store")
FileUtils.mkdir_p(store, mode: 0o700)
capture = W172Capture.new(run_root)
records = capture.records

version_record, version_stdout, = capture.run("runtime-version", [binary, "local", "--version"])

ddl_settings = "index_granularity = 2, index_granularity_bytes = 10485760, " \
  "enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, " \
  "min_bytes_for_wide_part = 0, default_compression_codec = 'LZ4'"
create_sql = <<~SQL
  SET flatten_nested = 0;
  CREATE TABLE default.w172_nested_source (pk UInt64, nested #{NESTED_TYPE})
    ENGINE = MergeTree ORDER BY pk SETTINGS #{ddl_settings};
  CREATE TABLE default.w172_array_tuple_source (pk UInt64, nested #{ARRAY_TUPLE_TYPE})
    ENGINE = MergeTree ORDER BY pk SETTINGS #{ddl_settings};
  CREATE TABLE default.w172_nested_reverse (pk UInt64, nested #{NESTED_TYPE})
    ENGINE = MergeTree ORDER BY pk SETTINGS #{ddl_settings};
SQL

def query_argv(binary, store, sql)
  [binary, "local", "--path", store, "--multiquery", "--max_threads=1", "--query", sql]
end

capture.run("create-tables", query_argv(binary, store, create_sql), sql: create_sql)

rows = [
  "(7, [(11, 'north-0', NULL), (103, 'south', -17)])",
  "(13, [])",
  "(22, [(211, 'tail', 31)])"
].join(",\n")
insert_sql = <<~SQL
  SET flatten_nested = 0;
  INSERT INTO default.w172_nested_source (pk, nested) VALUES #{rows};
  INSERT INTO default.w172_array_tuple_source (pk, nested) VALUES #{rows};
SQL
capture.run("insert-stock-fixture", query_argv(binary, store, insert_sql), sql: insert_sql)

def capture_select(capture, binary, store, label, table, format_name, binary_types: false)
  setting = binary_types ? "SET output_format_binary_encode_types_in_binary_format = 1;\n" : ""
  sql = "SET flatten_nested = 0;\n#{setting}SELECT pk, nested FROM default.#{table} ORDER BY pk FORMAT #{format_name};\n"
  capture.run(label, query_argv(binary, store, sql), sql: sql)
end

nested_header_record, nested_header_stdout, = capture_select(capture, binary, store,
  "nested-rowbinary-with-types", "w172_nested_source", "RowBinaryWithNamesAndTypes", binary_types: true)
nested_values_record, nested_values_stdout, = capture_select(capture, binary, store,
  "nested-rowbinary-values", "w172_nested_source", "RowBinary")
array_header_record, array_header_stdout, = capture_select(capture, binary, store,
  "array-tuple-rowbinary-with-types", "w172_array_tuple_source", "RowBinaryWithNamesAndTypes", binary_types: true)
array_values_record, array_values_stdout, = capture_select(capture, binary, store,
  "array-tuple-rowbinary-values", "w172_array_tuple_source", "RowBinary")

reverse_input = EXPECTED_NESTED_OUTPUT
reverse_sql = <<~SQL
  SET flatten_nested = 0;
  SET input_format_binary_decode_types_in_binary_format = 1;
  INSERT INTO default.w172_nested_reverse (pk, nested) FORMAT RowBinaryWithNamesAndTypes
SQL
reverse_insert_record, = capture.run("insert-independent-binary", query_argv(binary, store, reverse_sql),
  sql: reverse_sql, stdin_data: reverse_input)
reverse_output_record, reverse_output_stdout, = capture_select(capture, binary, store,
  "reverse-rowbinary-with-types", "w172_nested_reverse", "RowBinaryWithNamesAndTypes", binary_types: true)

binary_after = Digest::SHA256.file(binary).hexdigest
checks = {
  "runtime_version" => version_stdout.strip == EXPECTED_VERSION,
  "all_native_commands_succeeded" => records.all? { |record| record.dig("status", "success") == true },
  "nested_descriptor_and_values_match_independent_literal" => nested_header_stdout == EXPECTED_NESTED_OUTPUT,
  "nested_values_match_independent_literal" => nested_values_stdout == EXPECTED_VALUES,
  "array_tuple_descriptor_and_values_match_independent_literal" => array_header_stdout == EXPECTED_ARRAY_TUPLE_OUTPUT,
  "array_tuple_values_match_independent_literal" => array_values_stdout == EXPECTED_VALUES,
  "nested_and_array_tuple_row_values_are_identical" => nested_values_stdout == array_values_stdout,
  "reverse_binary_input_readback_matches_independent_literal" => reverse_output_stdout == EXPECTED_NESTED_OUTPUT,
  "reverse_input_was_the_independent_literal" => Digest::SHA256.hexdigest(reverse_input) == Digest::SHA256.hexdigest(EXPECTED_NESTED_OUTPUT),
  "runtime_binary_sha256_unchanged" => binary_after == EXPECTED_BINARY_SHA256
}

manifest = {
  "probe" => "W172 stock Nested binary descriptor and RowBinary law",
  "interpretation" => "pinned stock observations checked against independently encoded literals; no library support asserted",
  "created_at_utc" => Time.now.utc.iso8601(6),
  "source_pin" => {
    "root" => options[:source_root],
    "revision_supplied" => options[:source_revision],
    "expected_revision" => EXPECTED_SOURCE_REVISION,
    "revision_verification" => "recorded caller assertion; checkout was not inspected by this runner"
  },
  "runtime" => {
    "path" => binary,
    "expected_version" => EXPECTED_VERSION,
    "observed_version_stdout" => version_stdout.dup.force_encoding(Encoding::UTF_8),
    "sha256_before" => binary_before,
    "sha256_after" => binary_after,
    "version_command" => version_record
  },
  "fixture" => {
    "nested_type" => NESTED_TYPE,
    "array_tuple_type" => ARRAY_TUPLE_TYPE,
    "rows" => FIXTURE.map { |row| { "pk" => row[:key], "nested" => row[:values] } },
    "nested_binary_type_descriptor_hex" => NESTED_DESCRIPTOR.unpack1("H*"),
    "array_tuple_binary_type_descriptor_hex" => ARRAY_TUPLE_DESCRIPTOR.unpack1("H*"),
    "nested_rowbinary_with_names_and_types_hex" => EXPECTED_NESTED_OUTPUT.unpack1("H*"),
    "array_tuple_rowbinary_with_names_and_types_hex" => EXPECTED_ARRAY_TUPLE_OUTPUT.unpack1("H*"),
    "shared_rowbinary_values_hex" => EXPECTED_VALUES.unpack1("H*"),
    "nullable_null_encoding" => "marker 01; no Int32 placeholder bytes",
    "commands" => records
  },
  "checks" => checks,
  "check_failures" => checks.reject { |_, passed| passed }.keys,
  "native_call_count" => records.length
}
manifest_path = File.join(run_root, "manifest.json")
exclusive_write(manifest_path, JSON.pretty_generate(manifest) + "\n")
puts JSON.pretty_generate({ "manifest" => manifest_path, "checks" => checks, "native_call_count" => records.length })
abort "W172 binary-law probe checks failed; see retained manifest" unless checks.values.all?
abort "unexpected native command count" unless records.length <= 20
