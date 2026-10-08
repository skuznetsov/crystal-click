#!/usr/bin/env ruby
# Independent stock ClickHouse witness for AggregateFunction state composition
# through Array, plus a scalar Count control and one source-predicted refusal.
# This script only authors/captures stock parts; expected RowBinary bytes below
# are explicit literals and do not call the Crystal codec.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'open3'

VERSION = '26.10.1.1201'.freeze
BUILD_HASH = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
RUNTIME_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
SOURCE_ROOT = '/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1'.freeze
SOURCE_REVISION = '0ca8150d9b1d0886edb2e3b4ab65eebb768d0357'.freeze
ROOT_PREFIX = '/private/tmp/crystal-click-w224-probe.'.freeze
PROCESS_TIMEOUT_SECONDS = 35
TERM_GRACE_SECONDS = 2
MEMORY_LIMIT_BYTES = 1_073_741_824

SOURCE_SHA256 = {
  'src/AggregateFunctions/AggregateFunctionCount.h' => 'e30c050dcfb8805e1fd5d9525079cc0c7ca660d03b50ecf9c9cf38a303eb2f0a',
  'src/AggregateFunctions/AggregateFunctionSum.cpp' => 'db1bb5a1501bf31bad3f6b48b0942762062733241cd2ba33abb9a43e76d272a6',
  'src/AggregateFunctions/AggregateFunctionSum.h' => '1ced4e3ee877780fd5b5c3547bd6bdd4f4e8c09559702e91838b15871bb9a94d',
  'src/Core/Field.h' => '42fd21be18892643bcfae9962485b0605441fa39e8d56df2a6e13da5554ea0c4',
  'src/DataTypes/DataTypeAggregateFunction.cpp' => '81a26eab248379dd3f055fb716a4e7cb3a5f08a90239116f6df3af5b8c83b4ec',
  'src/DataTypes/DataTypeAggregateFunction.h' => 'f9969a90bcb0653b51643e50d853f1301c30d346311a6c93199a6207ec291334',
  'src/DataTypes/DataTypeArray.cpp' => 'a830a6d44d7bc6424be8053ae6505f3121b4c668a497aa5b1309fadc6bdb3a51',
  'src/DataTypes/DataTypeArray.h' => '660e6f37210922c200a7cbba5f25a0f01d579f79a51611768de72d1a3002be37',
  'src/DataTypes/DataTypeDynamic.h' => '25136ab2047032e8e86b382f3864f92144ee600b150d4e95cb8827a8dbfff2fd',
  'src/DataTypes/DataTypeLowCardinality.cpp' => 'e75ef3196f929ed61313394fe8ba13c0a377446f73fac12f2b2425128d625c5c',
  'src/DataTypes/DataTypeMap.cpp' => 'dfc839fd14ad6f0b726d65cdc266622cc62912cc48adfb60e61bdb0b49752c73',
  'src/DataTypes/DataTypeNested.cpp' => 'bb0cd02e0c94e0bd8520f6c8a83f64c7089fc47e5dc09f9d72e15f81367f16e4',
  'src/DataTypes/DataTypeNullable.cpp' => '68c4e432a0f555712906d796a4db1d950b32abac2d6c2eba4c1117ad39793e64',
  'src/DataTypes/DataTypeObject.cpp' => '17aa66e87730ef2710d501ae08ed78b0e9ffa914f7a9d33541bb63983d3741b7',
  'src/DataTypes/DataTypeTuple.cpp' => '350d50a6d0c5cefbf8b31bad1106f7e2200cc69ada1bac50704723d66edde2a0',
  'src/DataTypes/DataTypeTuple.h' => '9ebb2d555efa56456e4d57d873dcdbf231e48c96fcf87fa41d067f8073e9953b',
  'src/DataTypes/DataTypeVariant.cpp' => '10cf25b1ad0c1fd00eec3637bca21756207122d45ef09f97518c5748d6ae300d',
  'src/DataTypes/IDataType.h' => '6e9befee2cf642d989912710a4857c5a122fb7ba337eafc6b923c10f8eb33d5c',
  'src/DataTypes/Serializations/SerializationAggregateFunction.cpp' => '1fa59453165a7cdb33811e8cf8eb55d7f7b18abd4d28281397470dd217dd4950',
  'src/DataTypes/Serializations/SerializationArray.cpp' => '825295e177ae7f406c1a1c155e0c9e17b4cc39f4747cb1f3fb327b54db043791',
  'src/DataTypes/Serializations/SerializationMap.cpp' => '191c35c896507f303b06b2527277148d748ba5b8c62ffbefbdab739b1a6a8056',
  'src/DataTypes/Serializations/SerializationNullable.cpp' => '7f8f0f97725f21d196beabae47fefcc3bcb32e250f4a1f9a87b37f73eae7c43f',
  'src/DataTypes/Serializations/SerializationTuple.cpp' => '12e38b357204e005fc4780bac7e2e358b0a14357e0e246137414166062a1a884',
}.freeze

SOURCE_LAWS = [
  { 'path' => 'src/DataTypes/DataTypeAggregateFunction.cpp', 'lines' => '349-359',
    'law' => 'AggregateFunction arguments resolve through DataTypeFactory and the aggregate-function factory.' },
  { 'path' => 'src/DataTypes/DataTypeAggregateFunction.h', 'lines' => '51,84-89',
    'law' => 'AggregateFunction cannot be directly inside Nullable, has no type subtypes, and disables sparse serialization.' },
  { 'path' => 'src/DataTypes/DataTypeAggregateFunction.cpp', 'lines' => '262-265',
    'law' => 'AggregateFunction default type serialization is SerializationAggregateFunction for its function and state version.' },
  { 'path' => 'src/DataTypes/DataTypeArray.cpp', 'lines' => '32-35,59-64',
    'law' => 'Array accepts its nested type and recursively obtains nested serialization.' },
  { 'path' => 'src/DataTypes/DataTypeArray.h', 'lines' => '39-42',
    'law' => 'Array itself cannot be directly inside Nullable.' },
  { 'path' => 'src/DataTypes/DataTypeTuple.h', 'lines' => '38',
    'law' => 'Tuple can be directly inside Nullable.' },
  { 'path' => 'src/DataTypes/DataTypeNullable.cpp', 'lines' => '29-34',
    'law' => 'Nullable constructor refuses a nested type whose canBeInsideNullable is false.' },
  { 'path' => 'src/DataTypes/DataTypeMap.cpp', 'lines' => '120-140,152-155',
    'law' => 'Map composes key/value serialization and rejects Nullable or LowCardinality(Nullable) keys.' },
  { 'path' => 'src/DataTypes/DataTypeNested.cpp', 'lines' => '51-75',
    'law' => 'Nested named fields are parsed individually and represented as Array(Tuple(fields...)).' },
  { 'path' => 'src/DataTypes/DataTypeLowCardinality.cpp', 'lines' => '30-40',
    'law' => 'LowCardinality requires the inner type to opt in; AggregateFunction and Array use IDataType default false.' },
  { 'path' => 'src/DataTypes/IDataType.h', 'lines' => '373-374',
    'law' => 'Types are not eligible inside LowCardinality unless they override the default-false opt-in.' },
  { 'path' => 'src/DataTypes/DataTypeVariant.cpp', 'lines' => '26-35,46-64',
    'law' => 'Variant rejects Nullable/LowCardinality(Nullable), Dynamic, and nested Variant alternatives; AggregateFunction is not rejected by this constructor path.' },
  { 'path' => 'src/DataTypes/DataTypeDynamic.h', 'lines' => '23-25,41-45',
    'law' => 'Dynamic is parameterized, cannot be directly inside Nullable, and exposes no static type subtypes; this is not evidence of an AggregateFunction child wrapper.' },
  { 'path' => 'src/DataTypes/DataTypeObject.cpp', 'lines' => '180-206',
    'law' => 'JSON typed paths request serializers from declared child types; this generic path does not establish AggregateFunction JSON compatibility.' },
  { 'path' => 'src/DataTypes/Serializations/SerializationArray.cpp', 'lines' => '57-65',
    'law' => 'RowBinary array value is VarUInt element count followed by recursively serialized elements.' },
  { 'path' => 'src/DataTypes/Serializations/SerializationNullable.cpp', 'lines' => '184-204',
    'law' => 'Nullable binary values emit one null byte and serialize the nested value only when non-null.' },
  { 'path' => 'src/DataTypes/Serializations/SerializationTuple.cpp', 'lines' => '56-64',
    'law' => 'Tuple binary values serialize siblings in declaration order without an outer tuple prefix.' },
  { 'path' => 'src/DataTypes/Serializations/SerializationMap.cpp', 'lines' => '70-80',
    'law' => 'Map binary values use VarUInt pair count followed by key then value serialization per entry.' },
  { 'path' => 'src/DataTypes/Serializations/SerializationAggregateFunction.cpp', 'lines' => '58-83',
    'law' => 'AggregateFunction single-value state bytes delegate to the function serializer.' },
  { 'path' => 'src/AggregateFunctions/AggregateFunctionSum.cpp', 'lines' => '21-28',
    'law' => 'sum(UInt8) accumulator/result state uses NearestFieldType<UInt8>.' },
  { 'path' => 'src/Core/Field.h', 'lines' => '199-206',
    'law' => 'NearestFieldType maps UInt8 to UInt64.' },
  { 'path' => 'src/AggregateFunctions/AggregateFunctionSum.h', 'lines' => '273-281',
    'law' => 'sum state accumulator is serialized as its fixed-width little-endian value.' },
  { 'path' => 'src/AggregateFunctions/AggregateFunctionCount.h', 'lines' => '114-132',
    'law' => 'Count state serializes/deserializes its UInt64 value as VarUInt.' },
].freeze

STOCK_SETTINGS = [
  'index_granularity=2',
  'index_granularity_bytes=10485760',
  'enable_mixed_granularity_parts=1',
  'min_rows_for_wide_part=0',
  'min_bytes_for_wide_part=0',
  'min_level_for_wide_part=0',
  'compress_marks=0',
  'compress_primary_key=0',
  'min_compress_block_size=0',
  'max_compress_block_size=4096',
  'ratio_of_defaults_for_sparse_serialization=1.0',
  "default_compression_codec='LZ4'",
  "nullable_serialization_version='basic'",
  "serialization_info_version='with_types'",
  'propagate_types_serialization_versions_to_nested_types=1',
].freeze

# Whole-row literals are pinned directly: key LE UInt64, Array VarUInt length
# and LE UInt64 sum states, then Count VarUInt. The sum state domain deliberately
# includes nonempty, empty, uneven, zero, and a value larger than UInt8.
ROWS = [
  { 'pk' => 11, 'sum_states' => [1, 7], 'count_state' => 0,
    'rowbinary_hex' => '0b00000000000000020100000000000000070000000000000000' },
  { 'pk' => 22, 'sum_states' => [], 'count_state' => 127,
    'rowbinary_hex' => '1600000000000000007f' },
  { 'pk' => 33, 'sum_states' => [255], 'count_state' => 128,
    'rowbinary_hex' => '210000000000000001ff000000000000008001' },
  { 'pk' => 44, 'sum_states' => [0, 256, 17], 'count_state' => 16_384,
    'rowbinary_hex' => '2c0000000000000003000000000000000000010000000000001100000000000000808001' },
  { 'pk' => 55, 'sum_states' => [], 'count_state' => 18_446_744_073_709_551_615,
    'rowbinary_hex' => '370000000000000000ffffffffffffffffff01' },
].freeze

TABLE = 'recursive_array_w224'.freeze
SUM_TYPE = 'Array(AggregateFunction(sum, UInt8))'.freeze
COUNT_TYPE = 'AggregateFunction(count)'.freeze

def require_true(condition, message)
  raise ArgumentError, message unless condition
end

def encode_fixture_var_uint(value)
  require_true(value.is_a?(Integer) && value >= 0 && value <= 18_446_744_073_709_551_615,
    "fixture VarUInt is outside UInt64: #{value.inspect}")
  bytes = []
  while value >= 0x80
    bytes << ((value & 0x7f) | 0x80)
    value >>= 7
  end
  bytes << value
  bytes.pack('C*').b
end

def encode_fixture_uint64_le(value)
  require_true(value.is_a?(Integer) && value >= 0 && value <= 18_446_744_073_709_551_615,
    "fixture UInt64 is outside range: #{value.inspect}")
  Array.new(8) { |index| (value >> (index * 8)) & 0xff }.pack('C*').b
end

def encode_fixture_row_from_metadata(row)
  states = row.fetch('sum_states')
  require_true(states.is_a?(Array), 'fixture sum_states must be an Array')
  encode_fixture_uint64_le(row.fetch('pk')) +
    encode_fixture_var_uint(states.length) +
    states.map { |state| encode_fixture_uint64_le(state) }.join.b +
    encode_fixture_var_uint(row.fetch('count_state'))
end

def validate_literal_rows!
  ROWS.each_with_index.map do |row, index|
    hex = row.fetch('rowbinary_hex')
    require_true(hex.match?(/\A(?:[0-9a-f]{2})+\z/), "fixture row #{index + 1} literal is not even-length lowercase hex")
    literal = [hex].pack('H*').b
    from_metadata = encode_fixture_row_from_metadata(row)
    require_true(literal == from_metadata,
      "fixture row #{index + 1} literal does not match its independent metadata encoding: literal=#{hex}, metadata=#{from_metadata.unpack1('H*')}")
    {
      'row_number' => index + 1,
      'pk' => row.fetch('pk'),
      'array_length' => row.fetch('sum_states').length,
      'count_state' => row.fetch('count_state'),
      'literal_hex' => hex,
      'metadata_hex' => from_metadata.unpack1('H*'),
      'matches' => true,
    }
  end
end

def safe_label(value)
  value.gsub(/[^A-Za-z0-9_.-]/, '_')
end

def write_new(path, bytes)
  File.open(path, 'wbx', 0o600) { |file| file.write(bytes) }
rescue Errno::EEXIST
  raise "refusing to overwrite W224 probe evidence: #{path}"
end

def make_dir(path)
  Dir.mkdir(path, 0o700)
rescue Errno::EEXIST
  raise "refusing to reuse W224 probe directory: #{path}"
end

def validate_root!(path)
  require_true(path && path.match?(/\A#{Regexp.escape(ROOT_PREFIX)}[A-Za-z0-9_-]+\z/),
    "usage: ruby scripts/probe_aggregate_recursive_w224.rb /path/to/clickhouse #{ROOT_PREFIX}<fresh-leaf>")
  require_true(File.directory?(path) && !File.symlink?(path), 'evidence root must be a real, pre-created directory')
  real = File.realpath(path)
  require_true(real == path && File.dirname(real) == File.realpath('/private/tmp'),
    'evidence root must be a canonical direct child of /private/tmp')
  require_true(Dir.empty?(real), "refusing to reuse nonempty evidence root: #{real}")
  %w[evidence stores parts].each { |name| make_dir(File.join(real, name)) }
  make_dir(File.join(real, 'evidence', 'processes'))
  make_dir(File.join(real, 'evidence', 'cases'))
  real
end

def validate_binary!(path)
  full = File.expand_path(path)
  require_true(File.file?(full) && File.executable?(full) && !File.symlink?(full) && File.realpath(full) == full,
    "ClickHouse executable must be a canonical, executable regular file: #{full}")
  sha = Digest::SHA256.file(full).hexdigest
  require_true(sha == RUNTIME_SHA256, "pinned ClickHouse executable SHA-256 differs: #{sha}")
  full
end

def pin_source!(root)
  require_true(File.directory?(SOURCE_ROOT), "pinned ClickHouse source root is absent: #{SOURCE_ROOT}")
  records = SOURCE_SHA256.map do |relative, expected|
    path = File.join(SOURCE_ROOT, relative)
    require_true(File.file?(path) && !File.symlink?(path), "source anchor absent or symlinked: #{relative}")
    actual = Digest::SHA256.file(path).hexdigest
    { 'path' => relative, 'expected_sha256' => expected, 'actual_sha256' => actual, 'matches' => actual == expected }
  end
  pin = {
    'source_reference' => "#{SOURCE_ROOT}@#{SOURCE_REVISION}",
    'source_revision_given_by_task_context_not_git_revalidated' => SOURCE_REVISION,
    'runtime_built_from_this_source_snapshot_not_asserted' => true,
    'source_file_hashes' => records,
    'source_laws' => SOURCE_LAWS,
  }
  write_new(File.join(root, 'source_pin.json'), JSON.pretty_generate(pin) + "\n")
  require_true(records.all? { |record| record.fetch('matches') }, 'pinned source anchor hash mismatch')
  pin
end

def terminate_child!(waiter)
  return unless waiter && waiter.alive?

  Process.kill('TERM', waiter.pid)
  waiter.join(TERM_GRACE_SECONDS) || Process.kill('KILL', waiter.pid)
rescue Errno::ESRCH
  nil
ensure
  waiter.join if waiter
end

def clickhouse_argv(binary, store, sql)
  [binary, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1', '--max_insert_threads=1',
   '--max_execution_time=20', "--max_memory_usage=#{MEMORY_LIMIT_BYTES}", '--multiquery', '--query', sql]
end

class Recorder
  def initialize(root, binary)
    @root = root
    @binary = binary
    @sequence = 0
  end

  def run(operation_id, store, sql, input: nil, expected_exit: 'zero')
    @sequence += 1
    stem = format('%04d-%s', @sequence, safe_label(operation_id))
    prefix = File.join(@root, 'evidence', 'processes', stem)
    argv = clickhouse_argv(@binary, store, sql)
    write_new(prefix + '.sql', (sql.end_with?("\n") ? sql : sql + "\n").b)
    write_new(prefix + '.argv.json', JSON.pretty_generate({
      'operation_id' => operation_id,
      'argv' => argv,
      'environment' => { 'TZ' => 'UTC' },
      'timeout_seconds' => PROCESS_TIMEOUT_SECONDS,
      'expected_process_outcome' => expected_exit,
      'stdin_bytes' => input&.bytesize,
      'stdin_sha256' => input && Digest::SHA256.hexdigest(input.b),
    }) + "\n")
    write_new(prefix + '.stdin.bin', input.b) if input

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stdout_bytes = ''.b
    stderr_bytes = ''.b
    waiter = nil
    streams = []
    stdin = stdout = stderr = nil
    timed_out = false
    spawn_error = nil
    status = nil
    begin
      stdin, stdout, stderr, waiter = Open3.popen3({ 'TZ' => 'UTC' }, *argv)
      [stdin, stdout, stderr].each(&:binmode)
      streams = [Thread.new { stdout.read }, Thread.new { stderr.read }]
      stdin.write(input.b) if input
      stdin.close
      unless waiter.join(PROCESS_TIMEOUT_SECONDS)
        timed_out = true
        terminate_child!(waiter)
      end
      status = waiter.value
      stdout_bytes = streams[0].value
      stderr_bytes = streams[1].value
    rescue StandardError => error
      spawn_error = "#{error.class}: #{error.message}"
    ensure
      terminate_child!(waiter) if waiter && waiter.alive?
      [stdin, stdout, stderr].compact.each do |pipe|
        pipe.close unless pipe.closed?
      rescue IOError
        nil
      end
      streams.each(&:join)
    end

    process_classification = if spawn_error
                               'spawn_failure'
                             elsif timed_out
                               'process_timeout'
                             elsif status && status.success?
                               'process_success'
                             else
                               'process_nonzero_or_signaled_exit'
                             end
    result = {
      'operation_id' => operation_id,
      'classification' => process_classification,
      'exitstatus' => status && status.exitstatus,
      'signaled' => status && status.signaled? || false,
      'termsig' => status && status.termsig,
      'timed_out' => timed_out,
      'duration_ms' => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
      'spawn_error' => spawn_error,
      'stdout_bytes' => stdout_bytes.bytesize,
      'stderr_bytes' => stderr_bytes.bytesize,
    }
    write_new(prefix + '.stdout', stdout_bytes)
    write_new(prefix + '.stderr', stderr_bytes)
    write_new(prefix + '.status.json', JSON.pretty_generate(result) + "\n")
    result.merge('stdout' => stdout_bytes, 'stderr' => stderr_bytes, 'prefix' => prefix)
  end
end

def checked_success!(record)
  require_true(record.fetch('classification') == 'process_success',
    "#{record.fetch('operation_id')} process failed; this is not a semantic type refusal")
  record
end

def check_expected_refusal!(record, expected_diagnostic)
  # A semantic refusal is recognized from the explicit test expectation plus
  # nonzero child status and the exact source-backed diagnostic, never from a
  # process-label substring. All other failures remain process/test failures.
  body = (record.fetch('stdout') + record.fetch('stderr')).lines.each_with_object([]) do |line, messages|
    match = /\ACode: [0-9]+\. DB::Exception: (.*?)(?:\r?\n)?\z/.match(line)
    next unless match

    message = match[1].sub(/\s+\([A-Z_]+\)(?:\s+\(version [^)]+\))?\z/, '')
    messages << message.sub(/\.\z/, '')
  end
  if record.fetch('classification') == 'process_success'
    record['classification'] = 'unexpected_success_for_expected_refusal'
  elsif record.fetch('classification') == 'process_nonzero_or_signaled_exit' &&
        record.fetch('exitstatus') && record.fetch('exitstatus').positive? && !record.fetch('signaled') &&
        !record.fetch('timed_out') && !record.fetch('spawn_error') && body == [expected_diagnostic]
    record['classification'] = 'expected_semantic_refusal'
  else
    record['classification'] = 'refusal_diagnostic_or_process_mismatch'
  end
  require_true(record.fetch('classification') == 'expected_semantic_refusal',
    "#{record.fetch('operation_id')} did not produce the exact expected semantic refusal")
  record
end

def literal_input
  ROWS.map { |row| [row.fetch('rowbinary_hex')].pack('H*').b }.join.b
end

def expected_window(indices)
  indices.map { |index| [ROWS.fetch(index).fetch('rowbinary_hex')].pack('H*').b }.join.b
end

def tagged_rows(output, tag)
  output.force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp).each_with_object([]) do |line, rows|
    fields = line.split("\t", -1)
    rows << fields if fields.first == tag
  end
end

def inventory(part)
  entries = []
  Find.find(part) do |path|
    next if path == part
    require_true(!File.symlink?(path), "symlink in stock part: #{path}")
    next if File.directory?(path)
    require_true(File.file?(path), "unexpected stock part entry: #{path}")
    entries << {
      'path' => path.delete_prefix(part + File::SEPARATOR),
      'size' => File.size(path),
      'sha256' => Digest::SHA256.file(path).hexdigest,
    }
  end
  entries.sort_by { |item| item.fetch('path') }
end

def safe_text(path)
  File.binread(path).force_encoding(Encoding::UTF_8).scrub
end

def checked_child_path(path, store, label)
  store_real = File.realpath(store)
  expanded = File.expand_path(path, store)
  real = File.realpath(expanded)
  require_true(real.start_with?(store_real + File::SEPARATOR) && real != store_real, "#{label} escapes its process store")
  real
end

def main
  require_true(ARGV.length == 2, 'expected exactly: CLICKHOUSE_BIN FRESH_EVIDENCE_ROOT')
  literal_validation = validate_literal_rows!
  root = validate_root!(File.expand_path(ARGV.fetch(1)))
  binary = validate_binary!(ARGV.fetch(0))
  source_pin = pin_source!(root)
  write_new(File.join(root, 'evidence', 'cases', 'literal_rows.json'), JSON.pretty_generate({
    'table' => TABLE,
    'columns' => { 'sums' => SUM_TYPE, 'count_state' => COUNT_TYPE },
    'rows' => ROWS,
    'rowbinary_hex_is_independent_literal' => true,
  }) + "\n")
  write_new(File.join(root, 'evidence', 'cases', 'literal_rows_validation.json'), JSON.pretty_generate({
    'validation' => 'pure Ruby UInt64-LE and VarUInt encoder derived only from fixture metadata',
    'before_any_clickhouse_process' => true,
    'all_rows_match' => true,
    'rows' => literal_validation,
  }) + "\n")

  recorder = Recorder.new(root, binary)
  pin_store = File.join(root, 'stores', 'pins')
  make_dir(pin_store)
  version = checked_success!(recorder.run('runtime-version-pin', pin_store, 'SELECT version() FORMAT TSVRaw'))
  require_true(version.fetch('stdout').strip == VERSION, 'runtime version differs from pinned version')
  build = checked_success!(recorder.run('runtime-build-pin', pin_store,
    "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw"))
  require_true(build.fetch('stdout').strip == "VERSION_GITHASH=#{BUILD_HASH}", 'runtime build hash differs from pin')
  runtime_pin = {
    'version' => version.fetch('stdout').strip,
    'build_hash' => BUILD_HASH,
    'sha256' => Digest::SHA256.file(binary).hexdigest,
    'runtime_source_correlation' => 'not_asserted',
  }
  write_new(File.join(root, 'runtime_pin.json'), JSON.pretty_generate(runtime_pin) + "\n")

  store = File.join(root, 'stores', 'array-sum')
  case_dir = File.join(root, 'evidence', 'cases', 'array-sum')
  make_dir(store)
  make_dir(case_dir)
  outputs = %w[full middle empty].each_with_object({}) do |name, paths|
    paths[name] = File.join(case_dir, "rowbinary-#{name}.bin")
  end
  outputs.each_value { |path| require_true(!File.exist?(path) && !File.symlink?(path), "refusing to overwrite #{path}") }
  escape = ->(path) { path.gsub("'", "\\'") }
  ddl = "CREATE TABLE default.#{TABLE} (pk UInt64, sums #{SUM_TYPE}, count_state #{COUNT_TYPE}) ENGINE=MergeTree ORDER BY pk SETTINGS #{STOCK_SETTINGS.join(', ')}"
  checked_success!(recorder.run('stock-create-array-sum-count-control', store, ddl))
  checked_success!(recorder.run('stock-rowbinary-insert-array-sum-count-control', store,
    "INSERT INTO default.#{TABLE} FORMAT RowBinary", input: literal_input))

  sql = [
    "SELECT '__W224_SCHEMA__', name, type, toString(position) FROM system.columns WHERE database='default' AND table='#{TABLE}' ORDER BY position FORMAT TSVRaw;",
    "SELECT '__W224_RUNTIME_TYPE__', toTypeName(sums), toTypeName(count_state) FROM default.#{TABLE} LIMIT 1 FORMAT TSVRaw;",
    "SELECT '__W224_DATA_PATH__', data_paths[1] FROM system.tables WHERE database='default' AND name='#{TABLE}' FORMAT TSVRaw;",
    "SELECT '__W224_PART__', name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{TABLE}' AND active ORDER BY name FORMAT TSVRaw;",
    "CHECK TABLE default.#{TABLE} FORMAT TabSeparated;",
    "SELECT pk, sums, count_state FROM default.#{TABLE} ORDER BY pk INTO OUTFILE '#{escape.call(outputs.fetch('full'))}' FORMAT RowBinary;",
    "SELECT pk, sums, count_state FROM default.#{TABLE} WHERE pk BETWEEN 22 AND 44 ORDER BY pk INTO OUTFILE '#{escape.call(outputs.fetch('middle'))}' FORMAT RowBinary;",
    "SELECT pk, sums, count_state FROM default.#{TABLE} WHERE pk=0 INTO OUTFILE '#{escape.call(outputs.fetch('empty'))}' FORMAT RowBinary;",
  ].join("\n") + "\n"
  observed = checked_success!(recorder.run('stock-schema-check-and-rowbinary-windows', store, sql))

  schema = tagged_rows(observed.fetch('stdout'), '__W224_SCHEMA__')
  expected_schema = [
    ['__W224_SCHEMA__', 'pk', 'UInt64', '1'],
    ['__W224_SCHEMA__', 'sums', SUM_TYPE, '2'],
    ['__W224_SCHEMA__', 'count_state', COUNT_TYPE, '3'],
  ]
  require_true(schema == expected_schema, "stock schema differs: #{schema.inspect}")
  runtime_types = tagged_rows(observed.fetch('stdout'), '__W224_RUNTIME_TYPE__')
  require_true(runtime_types == [['__W224_RUNTIME_TYPE__', SUM_TYPE, COUNT_TYPE]],
    "runtime type names differ: #{runtime_types.inspect}")
  data_rows = tagged_rows(observed.fetch('stdout'), '__W224_DATA_PATH__')
  part_rows = tagged_rows(observed.fetch('stdout'), '__W224_PART__')
  require_true(data_rows.length == 1 && data_rows.first.length == 2 && !data_rows.first[1].empty?,
    'stock table data path is missing or ambiguous')
  require_true(part_rows.length == 1 && part_rows.first.length == 6, "expected one active part, got #{part_rows.inspect}")
  part_name, rows_text, marks_text, part_type, part_path_text = part_rows.first.drop(1)
  require_true(part_name == 'all_1_1_0' && rows_text == '5' && marks_text == '4' && part_type == 'Wide',
    "stock Wide part identity/grid differs: #{part_rows.inspect}")
  check_lines = observed.fetch('stdout').force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp).select do |line|
    line.start_with?("#{part_name}\t")
  end
  require_true(check_lines == ["#{part_name}\t1\t"], "CHECK TABLE did not validate exactly one part: #{check_lines.inspect}")

  store_data = checked_child_path(data_rows.first[1], store, 'table data path')
  part_path = checked_child_path(part_path_text, store, 'active part path')
  require_true(part_path.start_with?(store_data + File::SEPARATOR) && File.basename(part_path) == part_name,
    'part path is not below the discovered table data path')
  files = inventory(part_path)
  file_names = files.map { |entry| entry.fetch('path') }
  required = %w[columns.txt columns_substreams.txt count.txt checksums.txt serialization.json default_compression_codec.txt metadata_version.txt primary.idx]
  require_true((required - file_names).empty?, "Wide part lacks metadata files: #{required - file_names}")
  require_true(file_names.any? { |name| name.end_with?('.mrk2') } && file_names.grep(/\.mrk(?:\.|\z)/).empty?,
    'stock part is not plain mrk2-only')
  columns = safe_text(File.join(part_path, 'columns.txt'))
  expected_columns = "columns format version: 1\n3 columns:\n`pk` UInt64\n`sums` #{SUM_TYPE}\n`count_state` #{COUNT_TYPE}\n"
  require_true(columns == expected_columns, "columns.txt declarations differ: #{columns.inspect}")
  require_true(safe_text(File.join(part_path, 'count.txt')).strip == '5', 'count.txt differs from five fixture rows')
  codec = safe_text(File.join(part_path, 'default_compression_codec.txt')).strip
  require_true(codec == 'CODEC(LZ4)', "default codec differs: #{codec.inspect}")
  serialization = JSON.parse(safe_text(File.join(part_path, 'serialization.json')))
  checksums_text = safe_text(File.join(part_path, 'checksums.txt'))

  copy_parent = File.join(root, 'parts', 'stock-array-sum')
  make_dir(copy_parent)
  copied_part = File.join(copy_parent, part_name)
  require_true(!File.exist?(copied_part) && !File.symlink?(copied_part), 'refusing to overwrite stock part copy')
  FileUtils.cp_r(part_path, copied_part)
  require_true(inventory(copied_part) == files, 'copied immutable stock part differs from source inventory')

  windows = { 'full' => [0, 1, 2, 3, 4], 'middle' => [1, 2, 3], 'empty' => [] }
  rowbinary = windows.each_with_object({}) do |(name, indices), windows_manifest|
    actual = File.binread(outputs.fetch(name))
    expected = expected_window(indices)
    require_true(actual == expected, "stock #{name} RowBinary differs from independent literal bytes")
    windows_manifest[name] = {
      'path' => outputs.fetch(name).delete_prefix(root + File::SEPARATOR),
      'bytes' => actual.bytesize,
      'sha256' => Digest::SHA256.hexdigest(actual),
      'expected_bytes' => expected.bytesize,
      'expected_sha256' => Digest::SHA256.hexdigest(expected),
      'matches_independent_literal_bytes' => true,
    }
  end

  # The expected failure is tied to a specific negative type test and an exact
  # source-derived constructor diagnostic, independent of process naming.
  refusal_store = File.join(root, 'stores', 'refused-nullable-aggregate')
  make_dir(refusal_store)
  refusal = recorder.run('expected-refusal-nullable-aggregate-function', refusal_store,
    'CREATE TABLE default.refused_nullable (v Nullable(AggregateFunction(sum, UInt8))) ENGINE=Memory',
    expected_exit: 'nonzero_for_exact_semantic_refusal')
  check_expected_refusal!(refusal,
    'Nested type AggregateFunction(sum, UInt8) cannot be inside Nullable type')
  refusal_record = refusal.reject { |key, _| %w[stdout stderr prefix].include?(key) }
  write_new(File.join(root, 'evidence', 'expected_refusal_nullable_aggregate.json'),
    JSON.pretty_generate(refusal_record.merge(
      'expected_diagnostic' => 'Nested type AggregateFunction(sum, UInt8) cannot be inside Nullable type',
      'source_anchor' => 'src/DataTypes/DataTypeNullable.cpp:29-34',
    )) + "\n")

  manifest = {
    'format' => 'aggregate_recursive_w224_stock_probe_v1',
    'classification' => 'stock_array_aggregate_state_discriminator_observed',
    'runtime_pin' => runtime_pin,
    'source_pin' => source_pin,
    'table' => TABLE,
    'columns' => schema.drop(1).map { |row| { 'name' => row[1], 'type' => row[2] } },
    'row_keys' => ROWS.map { |row| row.fetch('pk') },
    'mark_rows_expected' => [2, 2, 1],
    'native_mark_count_with_terminal' => 4,
    'part_type' => part_type,
    'source_part_path' => part_path,
    'copied_part_path' => copied_part,
    'part_file_inventory' => files,
    'columns_txt' => columns,
    'columns_substreams_txt' => safe_text(File.join(part_path, 'columns_substreams.txt')),
    'serialization_json' => serialization,
    'checksums_sha256' => Digest::SHA256.hexdigest(checksums_text.b),
    'default_compression_codec' => codec,
    'rowbinary_windows' => rowbinary,
    'expected_semantic_refusal' => refusal_record,
    'runtime_source_correlation' => 'not_asserted',
  }
  write_new(File.join(root, 'manifest.json'), JSON.pretty_generate(manifest) + "\n")
  puts "W224 stock Array(AggregateFunction(sum, UInt8)) plus Count control; 5 rows, real marks [2,2,1], evidence=#{root}"
  true
rescue StandardError => error
  warn "W224 stock probe failure (process failures are not semantic refusals): #{error.class}: #{error.message}"
  false
end

exit(main ? 0 : 1)
