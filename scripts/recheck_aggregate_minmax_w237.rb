#!/usr/bin/env ruby
# Stock ClickHouse evidence for min/max AggregateFunction state bytes, plus an
# optional library round-trip driven by the separately built W237 helper.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'optparse'
require 'timeout'
require_relative 'recheck_aggregate_recursive_w224'

module RecheckAggregateMinmaxW237
  extend self

  R = RecheckAggregateRecursiveW224
  VERSION = R::VERSION.freeze
  BUILD_HASH = R::BUILD_HASH.freeze
  RUNTIME_SHA256 = R::RUNTIME_SHA256.freeze
  SOURCE_ROOT = R::SOURCE_ROOT.freeze
  SOURCE_REVISION = R::SOURCE_REVISION.freeze
  STOCK_PREFIX = '/private/tmp/crystal-click-w237-stock.'.freeze
  EVIDENCE_PREFIX = '/private/tmp/crystal-click-w237-evidence.'.freeze
  GENERATED_PREFIX = '/private/tmp/crystal-click-w237-generated.'.freeze
  STOCK_FORMAT = 'aggregate_minmax_w237_stock_v1'.freeze
  SUMMARY_FORMAT = 'aggregate_minmax_w237_summary_v1'.freeze
  HELPER_FORMAT = 'aggregate_minmax_w237_helper_v1'.freeze
  HELPER_LABEL = 'w237-library-roundtrip'.freeze
  ROW_KEYS = [11, 22, 33, 44, 55].freeze
  MARK_ROWS = [2, 2, 1].freeze
  CHECK_OUTPUT = "all_1_1_0\t1\t\n".freeze
  INVALIDATED_FILE = 'invalidated_system_columns.txt'.freeze
  INVALIDATED_NAMES = %w[_block_number _block_offset].freeze
  HELPER_TIMEOUT_SECONDS = 600
  TERM_GRACE_SECONDS = 2

  SOURCE_SHA256 = {
    'src/AggregateFunctions/AggregateFunctionsMinMax.cpp' => 'bfb2cf8b8daa4dbe7f595e66354593177f6116970f2128ba13ba13cb03d6fef2',
    'src/AggregateFunctions/SingleValueData.h' => 'c0fe1ec8d360e7dfcaef816b48dd52ed2e62472e6fb0abc77e5591772240c9c6',
    'src/AggregateFunctions/SingleValueData.cpp' => '208232bfc01f340b090a1c5839a09ed3be0ac179b5768c34f8be6f768abc19f0',
    'src/AggregateFunctions/Combinators/AggregateFunctionNull.h' => '94eee4ce82872fb54d40b440519278282eae46871fe94d7d4f8c64f6caeb9501',
  }.freeze

  # Finite source-valid representatives. The literal fixture describes the
  # native serialized state independently of minState/maxState; computed
  # controls below separately ask the pinned binary for empty and populated
  # states. Named Nested is retained as a request and its observed schema is
  # recorded verbatim because ClickHouse may canonicalize it to Array(Tuple).
  TYPE_SPECS = [
    { 'id' => 'uint8', 'argument_type' => 'UInt8', 'wire' => 'fixed', 'scalar' => 'UInt8', 'width' => 1,
      'values' => [nil, 0, 1, 255, 42], 'controls' => ['toUInt8(17)', 'toUInt8(3)'], 'min_value' => 3, 'max_value' => 17 },
    { 'id' => 'uint256', 'argument_type' => 'UInt256', 'wire' => 'fixed', 'scalar' => 'UInt256', 'width' => 32,
      'values' => [nil, 0, 1, 255, 42], 'controls' => ['toUInt256(4352)', 'toUInt256(17)'], 'min_value' => 17, 'max_value' => 4352 },
    { 'id' => 'int256', 'argument_type' => 'Int256', 'wire' => 'fixed', 'scalar' => 'Int256', 'width' => 32,
      'values' => [nil, -1, 255, -256, 42], 'controls' => ['toInt256(-17)', 'toInt256(4352)'], 'min_value' => -17, 'max_value' => 4352 },
    { 'id' => 'float32', 'argument_type' => 'Float32', 'wire' => 'fixed', 'scalar' => 'Float32', 'width' => 4,
      'values' => [nil, -0.0, 1.5, -2.25, 0.125], 'controls' => ['toFloat32(2.25)', 'toFloat32(-1.5)'], 'min_value' => -1.5, 'max_value' => 2.25 },
    { 'id' => 'bool', 'argument_type' => 'Bool', 'wire' => 'fixed', 'scalar' => 'Bool', 'width' => 1,
      'values' => [nil, false, true, false, true], 'controls' => ['CAST(1 AS Bool)', 'CAST(0 AS Bool)'], 'min_value' => false, 'max_value' => true },
    { 'id' => 'decimal32', 'argument_type' => 'Decimal(9, 2)', 'wire' => 'fixed', 'scalar' => 'Decimal32', 'width' => 4,
      'values' => [nil, -250, 0, 125, 999], 'controls' => ['toDecimal32(1.25, 2)', 'toDecimal32(-2.5, 2)'], 'min_value' => -250, 'max_value' => 125 },
    { 'id' => 'date', 'argument_type' => 'Date', 'wire' => 'fixed', 'scalar' => 'UInt16', 'width' => 2,
      'values' => [nil, 0, 1, 42, 2], 'controls' => ["toDate('1970-01-04')", "toDate('1970-01-02')"], 'min_value' => 1, 'max_value' => 3 },
    { 'id' => 'date32', 'argument_type' => 'Date32', 'wire' => 'fixed', 'scalar' => 'Int32', 'width' => 4,
      'values' => [nil, -1, 0, 42, -3], 'controls' => ["toDate32('1970-01-04')", "toDate32('1970-01-02')"], 'min_value' => 1, 'max_value' => 3 },
    { 'id' => 'datetime_utc', 'argument_type' => "DateTime('UTC')", 'wire' => 'fixed', 'scalar' => 'UInt32', 'width' => 4,
      'values' => [nil, 0, 1, 42, 2], 'controls' => ["toDateTime(17, 'UTC')", "toDateTime(3, 'UTC')"], 'min_value' => 3, 'max_value' => 17 },
    { 'id' => 'datetime64_utc', 'argument_type' => "DateTime64(3, 'UTC')", 'wire' => 'fixed', 'scalar' => 'Int64', 'width' => 8,
      'values' => [nil, -1000, 0, 1000, 2], 'controls' => ["toDateTime64('1970-01-01 00:00:00.017', 3, 'UTC')", "toDateTime64('1970-01-01 00:00:00.003', 3, 'UTC')"], 'min_value' => 3, 'max_value' => 17 },
    { 'id' => 'time', 'argument_type' => 'Time', 'wire' => 'fixed', 'scalar' => 'Int32', 'width' => 4,
      'values' => [nil, 0, 1, 42, 2], 'controls' => ["toTime(toDateTime(17, 'UTC'))", "toTime(toDateTime(3, 'UTC'))"], 'min_value' => 3, 'max_value' => 17 },
    { 'id' => 'time64', 'argument_type' => 'Time64(3)', 'wire' => 'fixed', 'scalar' => 'Int64', 'width' => 8,
      'values' => [nil, -1000, 0, 1000, 2], 'controls' => ["toTime64('00:00:00.017', 3)", "toTime64('00:00:00.003', 3)"], 'min_value' => 3, 'max_value' => 17 },
    { 'id' => 'interval_day', 'argument_type' => 'IntervalDay', 'wire' => 'fixed', 'scalar' => 'Int64', 'width' => 8,
      'values' => [nil, -1, 0, 42, 2], 'controls' => ['toIntervalDay(17)', 'toIntervalDay(3)'], 'min_value' => 3, 'max_value' => 17 },
    { 'id' => 'string', 'argument_type' => 'String', 'wire' => 'string',
      'values' => [nil, '', 'a', "a\0b", 'z'], 'controls' => ["CAST('', 'String')", "CAST('a', 'String')"], 'min_value' => '', 'max_value' => 'a' },
    { 'id' => 'fixed_string', 'argument_type' => 'FixedString(3)', 'wire' => 'fixed_string', 'width' => 3,
      'values' => [nil, 'abc', 'x', 'xyz', '12'], 'controls' => ["toFixedString('a', 3)", "toFixedString('b', 3)"], 'min_value' => "a\0\0", 'max_value' => "b\0\0" },
    { 'id' => 'tuple', 'argument_type' => 'Tuple(n UInt8, label String)', 'wire' => 'tuple',
      'values' => [nil, [0, ''], [1, 'a'], [2, 'b'], [255, 'z']],
      'controls' => ["CAST(tuple(toUInt8(1), 'a'), 'Tuple(n UInt8, label String)')", "CAST(tuple(toUInt8(2), 'b'), 'Tuple(n UInt8, label String)')"],
      'min_value' => [1, 'a'], 'max_value' => [2, 'b'] },
    { 'id' => 'array_tuple', 'argument_type' => 'Array(Tuple(n UInt8, label String))', 'wire' => 'array_tuple',
      'values' => [nil, [], [[1, '']], [[1, 'a'], [2, 'b']], [[255, 'z']]],
      'controls' => ["CAST([(toUInt8(1), 'a')], 'Array(Tuple(n UInt8, label String))')", "CAST([(toUInt8(2), 'b')], 'Array(Tuple(n UInt8, label String))')"],
      'min_value' => [[1, 'a']], 'max_value' => [[2, 'b']] },
    { 'id' => 'map', 'argument_type' => 'Map(String, UInt8)', 'wire' => 'map',
      'values' => [nil, [], [['a', 1]], [['a', 1], ['b', 2]], [['z', 255]]],
      'controls' => ["map('a', toUInt8(1))", "map('b', toUInt8(2))"],
      'min_value' => [['a', 1]], 'max_value' => [['b', 2]] },
    { 'id' => 'nested', 'argument_type' => 'Nested(n UInt8, label String)', 'wire' => 'array_tuple',
      'values' => [nil, [], [[1, '']], [[1, 'a'], [2, 'b']], [[255, 'z']]],
      'controls' => ["CAST([(toUInt8(1), 'a')], 'Array(Tuple(n UInt8, label String))')", "CAST([(toUInt8(2), 'b')], 'Array(Tuple(n UInt8, label String))')"],
      'min_value' => [[1, 'a']], 'max_value' => [[2, 'b']] },
    { 'id' => 'nullable_uint8', 'argument_type' => 'Nullable(UInt8)', 'wrapper' => 'nullable', 'wire' => 'fixed', 'scalar' => 'UInt8', 'width' => 1,
      'values' => [nil, 0, 1, 255, 42], 'controls' => ['CAST(3 AS Nullable(UInt8))', 'CAST(7 AS Nullable(UInt8))'], 'min_value' => 3, 'max_value' => 7 },
    { 'id' => 'nullable_string', 'argument_type' => 'Nullable(String)', 'wrapper' => 'nullable', 'wire' => 'string',
      'values' => [nil, '', 'a', 'b', 'z'], 'controls' => ["CAST('', 'Nullable(String)')", "CAST('a', 'Nullable(String)')"], 'min_value' => '', 'max_value' => 'a' },
    { 'id' => 'low_cardinality_uint16', 'argument_type' => 'LowCardinality(UInt16)', 'wrapper' => 'low_cardinality', 'wire' => 'fixed', 'scalar' => 'UInt16', 'width' => 2,
      'values' => [nil, 0, 1, 257, 42], 'controls' => ['toLowCardinality(toUInt16(17))', 'toLowCardinality(toUInt16(3))'], 'min_value' => 3, 'max_value' => 17 },
    { 'id' => 'low_cardinality_nullable_uint8', 'argument_type' => 'LowCardinality(Nullable(UInt8))', 'wrapper' => 'low_cardinality_nullable', 'inner_type' => 'UInt8', 'wire' => 'fixed', 'scalar' => 'UInt8', 'width' => 1,
      'values' => [nil, 0, 1, 255, 42], 'controls' => ['toLowCardinality(CAST(3 AS Nullable(UInt8)))', 'toLowCardinality(CAST(7 AS Nullable(UInt8)))'], 'min_value' => 3, 'max_value' => 7 },
  ].freeze

  # These LC String cases extend the constructor census only; persisted state
  # coverage deliberately stays at the numeric/nullable dispatch profiles.
  CONSTRUCTOR_ONLY_TYPES = [
    { 'id' => 'lc_string_min', 'operation' => 'min', 'type' => 'AggregateFunction(min, LowCardinality(String))' },
    { 'id' => 'lc_string_max', 'operation' => 'max', 'type' => 'AggregateFunction(max, LowCardinality(String))' },
    { 'id' => 'lc_nullable_string_min', 'operation' => 'min', 'type' => 'AggregateFunction(min, LowCardinality(Nullable(String)))' },
    { 'id' => 'lc_nullable_string_max', 'operation' => 'max', 'type' => 'AggregateFunction(max, LowCardinality(Nullable(String)))' },
  ].freeze

  STRING_LEGACY_CASES = [
    { 'id' => 'negative_length_minus_two', 'input_hex' => 'feffffff', 'expected_hex' => 'ffffffff',
      'law' => 'any negative signed Int32 length decodes as absent and canonicalizes to -1' },
    { 'id' => 'zero_length_old_empty', 'input_hex' => '00000000', 'expected_hex' => '0100000000',
      'law' => 'legacy zero length decodes as present-empty and canonicalizes to length 1 plus NUL' },
    { 'id' => 'missing_terminal_nul', 'input_hex' => '03000000616263', 'expected_hex' => '0400000061626300',
      'law' => 'nonzero final byte is retained as content and canonical serialization appends NUL' },
  ].freeze

  def fail!(message)
    raise ArgumentError, message
  end

  def require_true(condition, message)
    fail!(message) unless condition
  end

  def write_new(path, bytes)
    R.write_new(path, bytes)
  end

  def write_json(path, object)
    R.write_json(path, object)
  end

  def make_dir(path)
    R.make_dir(path)
  end

  def clean_record(record)
    record.reject { |key, _| %w[stdout stderr path].include?(key) }
  end

  def checked_success!(record, label)
    require_true(record.fetch('classification') == 'process_success' && record.fetch('exitstatus') == 0 &&
      !record.fetch('signaled') && !record.fetch('timed_out') && !record.fetch('spawn_error'),
      "#{label} did not complete as a successful process; see its raw status sidecar")
    record
  end

  def source_pin!
    inherited = R.pin_source!
    rows = SOURCE_SHA256.map do |relative, expected|
      path = File.join(SOURCE_ROOT, relative)
      require_true(File.file?(path) && !File.symlink?(path), "min/max source anchor absent or symlinked: #{relative}")
      actual = Digest::SHA256.file(path).hexdigest
      { 'path' => relative, 'expected_sha256' => expected, 'actual_sha256' => actual, 'matches' => expected == actual }
    end
    require_true(rows.all? { |row| row.fetch('matches') }, 'a min/max source file differs from its pinned revision')
    inherited.merge('minmax_source_hashes' => rows, 'minmax_source_laws' => [
      { 'path' => 'src/AggregateFunctions/AggregateFunctionsMinMax.cpp', 'lines' => '25-45,145-174',
        'law' => 'min/max are unary parameterless states, require comparable arguments, reject Dynamic and Variant anywhere in the argument tree, and delegate state bytes to SingleValueData.' },
      { 'path' => 'src/AggregateFunctions/SingleValueData.h', 'lines' => '84-110,429-454',
        'law' => 'fixed numeric values store a presence byte plus little-endian carrier; Date/DateTime have fixed carriers, String has a specialized owner, and other types use generic Field or column storage.' },
      { 'path' => 'src/AggregateFunctions/SingleValueData.cpp', 'lines' => '1297-1357,1460-1478,1571-1593',
        'law' => 'String uses signed Int32 length including its terminating NUL, with -1 for absence; generic owners prepend presence and delegate the body to child binary serialization.' },
      { 'path' => 'src/AggregateFunctions/Combinators/AggregateFunctionNull.h', 'lines' => '221-255',
        'law' => 'Nullable aggregate state has its own serialized outer presence flag and serializes the nested state only when active.' },
    ])
  end

  def profiles
    rows = []
    TYPE_SPECS.each do |spec|
      %w[min max].each do |operation|
        rows << spec.merge('operation' => operation,
          'id' => "#{operation}_#{spec.fetch('id')}",
          'requested_type' => "AggregateFunction(#{operation}, #{spec.fetch('argument_type')})")
      end
    end
    rows.each_with_index { |profile, index| profile['ordinal'] = index }
    rows
  end

  def coverage_manifest
    {
      'method' => 'finite source-valid representative roster; min and max each tested for every persisted declared type',
      'declared_type_count' => TYPE_SPECS.length,
      'operation_count' => 2,
      'persisted_profile_count' => TYPE_SPECS.length * 2,
      'declared_type_families' => [
        'numeric widths and domains: UInt8, UInt256, Int256, Float32, Bool',
        'Decimal: Decimal32',
        'temporal: Date, Date32, DateTime with UTC timezone, DateTime64(3) with UTC timezone, Time, Time64(3)',
        'Interval: IntervalDay',
        'text: String and FixedString(3)',
        'generic: Tuple, Array(Tuple), Map, and Nested',
        'dispatch wrappers: Nullable(UInt8), Nullable(String), LowCardinality(UInt16), LowCardinality(Nullable(UInt8))',
      ],
      'constructor_only_profiles' => CONSTRUCTOR_ONLY_TYPES.map { |spec| spec.fetch('type') },
      'cartesian_expansion' => false,
      'limits' => 'Representative fixtures are source-valid, not exhaustive aliases, precisions, integer widths, compound shapes, or Cartesian products.',
    }
  end

  def little_unsigned(value, width)
    number = Integer(value)
    max = 1 << (width * 8)
    require_true(number >= 0 && number < max, "unsigned literal outside #{width}-byte carrier: #{value.inspect}")
    Array.new(width) { |index| (number >> (index * 8)) & 0xff }.pack('C*').b
  end

  def little_signed(value, width)
    number = Integer(value)
    mod = 1 << (width * 8)
    require_true(number >= -(mod >> 1) && number < (mod >> 1), "signed literal outside #{width}-byte carrier: #{value.inspect}")
    little_unsigned(number % mod, width)
  end

  def varuint(value)
    number = Integer(value)
    require_true(number >= 0 && number <= 18_446_744_073_709_551_615, 'literal VarUInt outside UInt64 range')
    bytes = []
    while number >= 0x80
      bytes << ((number & 0x7f) | 0x80)
      number >>= 7
    end
    (bytes << number).pack('C*').b
  end

  def signed_i32(value)
    little_signed(value, 4)
  end

  def string_binary(value)
    bytes = value.encode(Encoding::UTF_8).b
    varuint(bytes.bytesize) + bytes
  end

  def scalar_bytes(type, value, width)
    case type
    when 'Float32' then [Float(value)].pack('e').b
    when 'Float64' then [Float(value)].pack('E').b
    when 'Bool' then [value ? 1 : 0].pack('C').b
    when 'Int8', 'Int16', 'Int32', 'Int64', 'Int128', 'Int256', 'Date32',
         'Decimal32', 'Decimal64', 'Decimal128', 'Decimal256'
      little_signed(value, width)
    else
      little_unsigned(value, width)
    end
  end

  def generic_body(profile, value)
    case profile.fetch('wire')
    when 'tuple'
      number, label = value
      scalar_bytes('UInt8', number, 1) + string_binary(label)
    when 'array_tuple'
      items = value
      varuint(items.length) + items.map { |tuple| generic_body(profile.merge('wire' => 'tuple'), tuple) }.join.b
    when 'map'
      pairs = value
      varuint(pairs.length) + pairs.map { |key, item| string_binary(key) + scalar_bytes('UInt8', item, 1) }.join.b
    else
      fail!("unlisted generic min/max wire kind: #{profile.fetch('wire')}")
    end
  end

  def base_state(profile, value)
    wire = profile.fetch('wire')
    if wire == 'string'
      return signed_i32(-1) if value.nil?
      bytes = value.encode(Encoding::UTF_8).b
      signed_i32(bytes.bytesize + 1) + bytes + "\x00".b
    elsif wire == 'fixed_string'
      return "\x00".b if value.nil?
      raw = value.encode(Encoding::UTF_8).b
      width = profile.fetch('width')
      require_true(raw.bytesize <= width, 'FixedString fixture exceeds declared width')
      "\x01".b + raw.ljust(width, "\x00".b)
    elsif wire == 'fixed'
      return "\x00".b if value.nil?
      "\x01".b + scalar_bytes(profile.fetch('scalar'), value, profile.fetch('width'))
    else
      return "\x00".b if value.nil?
      "\x01".b + generic_body(profile, value)
    end
  end

  def state_bytes(profile, value)
    wrapper = profile['wrapper']
    if wrapper == 'nullable'
      return "\x00".b if value.nil?
      "\x01".b + base_state(profile, value)
    elsif wrapper == 'low_cardinality_nullable'
      return "\x00".b if value.nil?
      "\x01".b + base_state(profile, value)
    elsif wrapper == 'low_cardinality'
      base_state(profile, value)
    else
      base_state(profile, value)
    end
  end

  def state_hex(profile)
    profile.fetch('values').map { |value| state_bytes(profile, value).unpack1('H*') }
  end

  def rowbinary_rows(profile)
    profile.fetch('values').each_with_index.map do |value, index|
      little_unsigned(ROW_KEYS.fetch(index), 8) + state_bytes(profile, value)
    end
  end

  def rowbinary_window(profile, window)
    indices = case window
              when 'full' then [0, 1, 2, 3, 4]
              when 'middle' then [1, 2, 3]
              when 'zero' then []
              else fail!("unlisted RowBinary window #{window}")
              end
    rows = rowbinary_rows(profile)
    indices.map { |index| rows.fetch(index) }.join.b
  end

  def validate_literal_roster!
    expected_count = TYPE_SPECS.length * 2
    all_profiles = profiles
    require_true(all_profiles.length == expected_count, 'literal fixture roster differs from min/max coverage manifest')
    all_profiles.each do |profile|
      fixture_states = state_hex(profile)
      require_true(fixture_states.length == profile.fetch('values').length,
        "state literal count differs for #{profile.fetch('id')}")
      %w[full middle zero].each do |window|
        rowbinary_window(profile, window)
      end
      [false, true].each do |populated|
        expected_control_state(profile, populated: populated)
      end
    end
    true
  end

  def table_name(profile, side = 'stock')
    "w237_#{side}_p#{format('%03d', profile.fetch('ordinal'))}"
  end

  def source_store(root)
    File.join(root, 'stores', 'stock')
  end

  def source_control_paths(root, profile)
    base = File.join(root, 'cases', 'source-controls', profile.fetch('id'))
    paths = { 'empty' => base + '-empty.rowbinary', 'populated' => base + '-populated.rowbinary' }
    if %w[nullable low_cardinality_nullable].include?(profile['wrapper'])
      paths['all_null'] = base + '-all-null.rowbinary'
    end
    paths
  end

  def profile_part_path(root, profile)
    File.join(root, 'stock-parts', profile.fetch('id'), 'all_1_1_0')
  end

  def quote_sql(path)
    path.gsub("'", "\\'")
  end

  def source_values_query(profile)
    values = profile.fetch('controls')
    values.map { |expr| "SELECT #{expr} AS x" }.join("\nUNION ALL\n")
  end

  def source_empty_query(profile)
    type = profile.fetch('argument_type')
    if profile['wrapper'] == 'nullable'
      "SELECT CAST(NULL AS #{type}) AS x WHERE 0"
    elsif profile['wrapper'] == 'low_cardinality_nullable'
      "SELECT toLowCardinality(CAST(NULL AS Nullable(#{profile.fetch('inner_type')}))) AS x WHERE 0"
    else
      # Keep an exactly typed expression in the source query. CAST(0 AS T) is
      # not defined for generic containers even when WHERE 0 makes it empty.
      "SELECT #{profile.fetch('controls').first} AS x WHERE 0"
    end
  end

  def source_all_null_query(profile)
    if profile['wrapper'] == 'nullable'
      "SELECT CAST(NULL AS #{profile.fetch('argument_type')}) AS x"
    elsif profile['wrapper'] == 'low_cardinality_nullable'
      "SELECT toLowCardinality(CAST(NULL AS Nullable(#{profile.fetch('inner_type')}))) AS x"
    end
  end

  def source_control_sql(profile, root)
    op = profile.fetch('operation')
    paths = source_control_paths(root, profile)
    input = source_values_query(profile)
    empty = source_empty_query(profile)
    statements = [
      "SELECT #{op}State(x) FROM (#{empty}) INTO OUTFILE '#{quote_sql(paths.fetch('empty'))}' FORMAT RowBinary",
      "SELECT 'W237_SOURCE_TYPE_BEGIN_#{profile.fetch('id')}' FORMAT TSVRaw",
      "SELECT toTypeName(#{op}State(x)) FROM (#{input}) LIMIT 1 FORMAT TSVRaw",
      "SELECT 'W237_SOURCE_TYPE_END_#{profile.fetch('id')}' FORMAT TSVRaw",
      "SELECT #{op}State(x) FROM (#{input}) INTO OUTFILE '#{quote_sql(paths.fetch('populated'))}' FORMAT RowBinary",
    ]
    if paths.key?('all_null')
      statements.insert(1, "SELECT #{op}State(x) FROM (#{source_all_null_query(profile)}) INTO OUTFILE '#{quote_sql(paths.fetch('all_null'))}' FORMAT RowBinary")
    end
    statements.join(";\n")
  end

  def expected_control_state(profile, populated:)
    unless populated
      return "\x00".b if profile['wrapper'] == 'nullable' || profile['wrapper'] == 'low_cardinality_nullable'
      return signed_i32(-1) if profile.fetch('wire') == 'string'
      return "\x00".b
    end
    value = profile.fetch(profile.fetch('operation') == 'min' ? 'min_value' : 'max_value')
    state_bytes(profile, value)
  end

  def create_sql(profile, table)
    settings = R::STOCK_SETTINGS + ["string_serialization_version='single_stream'"]
    "CREATE TABLE default.#{table} (pk UInt64, v #{profile.fetch('declared_type')}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings.join(', ')}"
  end

  def inventory(part)
    full = File.expand_path(part)
    require_true(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "part is absent, symlinked, or noncanonical: #{full}")
    rows = []
    Find.find(full) do |path|
      next if path == full
      require_true(!File.symlink?(path), "part contains symlink: #{path}")
      next if File.directory?(path)
      require_true(File.file?(path), "part contains non-file entry: #{path}")
      rows << { 'path' => path[(full.length + 1)..-1], 'size' => File.size(path),
        'sha256' => Digest::SHA256.file(path).hexdigest }
    end
    rows.sort_by { |row| row.fetch('path') }
  end

  def clean_helper_process(record)
    record.reject { |key, _| %w[stdout stderr].include?(key) }
  end

  def run_helper(executable, matrix_path, output_root, evidence_root)
    argv = [executable, '--stock-matrix', matrix_path, '--output-root', output_root]
    write_new(File.join(evidence_root, 'helper.argv.json'), JSON.pretty_generate({
      'label' => HELPER_LABEL, 'argv' => argv, 'timeout_seconds' => HELPER_TIMEOUT_SECONDS,
      'environment' => { 'TZ' => 'UTC' },
    }) + "\n")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stdout_data = ''.b
    stderr_data = ''.b
    status = nil
    spawn_error = nil
    timed_out = false
    stdin = stdout = stderr = waiter = nil
    readers = []
    begin
      stdin, stdout, stderr, waiter = Open3.popen3({ 'TZ' => 'UTC' }, *argv)
      [stdin, stdout, stderr].each(&:binmode)
      readers = [Thread.new { stdout.read }, Thread.new { stderr.read }]
      stdin.close
      unless waiter.join(HELPER_TIMEOUT_SECONDS)
        timed_out = true
        R.terminate_child(waiter)
      end
      status = waiter.value
      stdout_data = readers[0].value
      stderr_data = readers[1].value
    rescue StandardError => error
      spawn_error = "#{error.class}: #{error.message}"
    ensure
      R.terminate_child(waiter) if waiter && waiter.alive?
      [stdin, stdout, stderr].compact.each { |pipe| pipe.close unless pipe.closed? rescue nil }
      readers.each(&:join)
    end
    record = {
      'label' => HELPER_LABEL,
      'classification' => if spawn_error then 'spawn_failure' elsif timed_out then 'process_timeout' elsif status && status.success? then 'process_success' else 'process_nonzero_or_signaled_exit' end,
      'exitstatus' => status && status.exitstatus, 'signaled' => status && status.signaled? || false,
      'termsig' => status && status.termsig, 'timed_out' => timed_out,
      'duration_ms' => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
      'spawn_error' => spawn_error, 'stdout_bytes' => stdout_data.bytesize, 'stderr_bytes' => stderr_data.bytesize,
    }
    write_new(File.join(evidence_root, 'helper.stdout'), stdout_data)
    write_new(File.join(evidence_root, 'helper.stderr'), stderr_data)
    write_new(File.join(evidence_root, 'helper.status.json'), JSON.pretty_generate(record) + "\n")
    record.merge('stdout' => stdout_data, 'stderr' => stderr_data, 'argv' => argv)
  end

  class Probe
    include RecheckAggregateMinmaxW237

    def initialize(options)
      @binary = R.validate_binary!(options.fetch(:clickhouse))
      @stock_only = options.fetch(:stock_only)
      @profiles = RecheckAggregateMinmaxW237.profiles
      @records = []
      @construction = []
      @source_controls = []
      @stock_profiles = []
      @native_profiles = []
      @fatal = nil
      @source_root = nil
      @evidence_root = nil
      @generated_root = nil
      @matrix_path = nil
      @matrix_sha256 = nil
      @helper = nil
      @helper_sha256 = nil
      @recorder = nil
      if @stock_only
        @source_root = R.validate_root(options.fetch(:output_root), STOCK_PREFIX, 'W237 stock root')
        @evidence_root = @source_root
      else
        @source_root = validate_stock_matrix_root(options.fetch(:stock_matrix))
        @matrix_path = File.join(@source_root, 'stock-matrix.json')
        @evidence_root = R.validate_root(options.fetch(:output_root), EVIDENCE_PREFIX, 'W237 evidence root')
        @generated_root = R.validate_root(options.fetch(:generated_root), GENERATED_PREFIX, 'W237 generated root')
        @helper = R.validate_program!(options.fetch(:helper), 'prebuilt W237 helper')
        @helper_sha256 = Digest::SHA256.file(@helper).hexdigest
        expected = R.validate_sha256_pin!(options.fetch(:helper_sha256), 'expected W237 helper SHA-256')
        require_true(@helper_sha256 == expected, 'prebuilt W237 helper differs from external SHA-256 pin')
      end
      @recorder = R::Recorder.new(@evidence_root, @binary)
    end

    def run
      validate_literal_roster!
      prepare_layout
      @source_pin = RecheckAggregateMinmaxW237.source_pin!
      pin_runtime
      if @stock_only
        capture_constructor_census
        capture_invalid_constructors
        capture_lc_constructor_only
        capture_source_controls
        capture_string_legacy
        create_stock_tables
        insert_stock_fixtures
        capture_stock_profiles
        write_stock_matrix
        verify_clickhouse_roster!
        write_summary('stock_minmax_profiles_observed')
        puts "W237 stock min/max matrix profiles=#{@stock_profiles.length}; matrix=#{@matrix_path}"
      else
        load_stock_matrix
        invoke_helper
        capture_native_profiles
        verify_clickhouse_roster!
        write_summary('paired_minmax_profiles_observed')
        puts "W237 paired min/max profiles=#{@native_profiles.length}; evidence=#{@evidence_root}"
      end
      true
    rescue StandardError => error
      @fatal ||= "#{error.class}: #{error.message}"
      write_summary('runner_failure_or_observations_differ') rescue nil
      warn "W237 min/max probe stopped: #{@fatal}"
      false
    end

    private

    def validate_stock_matrix_root(path)
      full = File.expand_path(path)
      require_true(File.file?(full) && !File.symlink?(full) && File.realpath(full) == full,
        'stock matrix path is absent, symlinked, or noncanonical')
      root = File.dirname(full)
      require_true(File.directory?(root) && !File.symlink?(root) && File.realpath(root) == root &&
        File.dirname(root) == File.realpath('/private/tmp') && root.start_with?(STOCK_PREFIX) &&
        File.basename(full) == 'stock-matrix.json', 'stock matrix must be the W237 root-level stock-matrix.json')
      root
    end

    def prepare_layout
      if @stock_only
        %w[invocations cases stores stock-parts].each { |name| Dir.mkdir(File.join(@source_root, name), 0o700) }
        %w[pins construction stock].each { |name| Dir.mkdir(File.join(@source_root, 'stores', name), 0o700) }
        %w[source-controls stock-rowbinary string-legacy].each { |name| Dir.mkdir(File.join(@source_root, 'cases', name), 0o700) }
        Dir.mkdir(File.join(@source_root, 'stores', 'string-legacy'), 0o700)
      else
        %w[invocations cases stores].each { |name| Dir.mkdir(File.join(@evidence_root, name), 0o700) }
        %w[native pins].each { |name| Dir.mkdir(File.join(@evidence_root, 'stores', name), 0o700) }
        %w[native-rowbinary].each { |name| Dir.mkdir(File.join(@evidence_root, 'cases', name), 0o700) }
      end
    end

    def process(label, store, sql, input: nil, timeout: R::PROCESS_TIMEOUT_SECONDS)
      record = @recorder.run(label, store, sql, input: input, timeout: timeout)
      @records << record
      record
    end

    def pin_runtime
      pin_store = File.join(@evidence_root, 'stores', 'pins')
      version = checked_success!(process('runtime-version-pin', pin_store,
        'SELECT version() FORMAT TSVRaw'), 'runtime version pin')
      require_true(version.fetch('stdout').strip == VERSION, 'native version differs from exact W237 pin')
      build = checked_success!(process('runtime-build-pin', pin_store,
        "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw"), 'runtime build pin')
      require_true(build.fetch('stdout').strip == "VERSION_GITHASH=#{BUILD_HASH}", 'native build hash differs from exact W237 pin')
      @runtime_pin = { 'version' => VERSION, 'build_hash' => BUILD_HASH,
        'sha256' => Digest::SHA256.file(@binary).hexdigest, 'runtime_source_correlation' => 'not_asserted' }
      write_json(File.join(@evidence_root, 'runtime_pin.json'), @runtime_pin)
    end

    def capture_constructor_census
      columns = @profiles.each_with_index.map { |profile, index| "p#{format('%03d', index)} #{profile.fetch('requested_type')}" }
      sql = "CREATE TABLE default.w237_constructor (pk UInt8, #{columns.join(', ')}) ENGINE=Memory;\n" \
        "SELECT name, type FROM system.columns WHERE database='default' AND table='w237_constructor' ORDER BY position FORMAT TSVRaw"
      record = process('constructor-positive-census', File.join(@source_root, 'stores', 'construction'), sql)
      unless record.fetch('classification') == 'process_success' && record.fetch('exitstatus') == 0 &&
          !record.fetch('signaled') && !record.fetch('timed_out') && !record.fetch('spawn_error')
        @construction << { 'classification' => 'constructor_or_schema_failure', 'requested_profile_count' => @profiles.length,
          'process' => clean_record(record), 'stdout' => record.fetch('stdout'), 'stderr' => record.fetch('stderr') }
        fail!('positive min/max constructor census failed; raw process status is preserved')
      end
      schema = record.fetch('stdout').force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      require_true(schema.length == @profiles.length + 1 && schema.first == "pk\tUInt8",
        'positive constructor census returned an incomplete system.columns result')
      @profiles.each_with_index do |profile, index|
        name, type = schema.fetch(index + 1).split("\t", 2)
        require_true(name == "p#{format('%03d', index)}" && type && type.start_with?("AggregateFunction(#{profile.fetch('operation')}, "),
          "source constructor/schema differs for #{profile.fetch('id')}: #{schema.fetch(index + 1).inspect}")
        profile['declared_type'] = type
      end
      @construction << { 'classification' => 'source_constructor_acceptance_observed',
        'profile_count' => @profiles.length, 'requested_types' => @profiles.map { |profile| profile.fetch('requested_type') },
        'declared_types' => @profiles.map { |profile| profile.fetch('declared_type') },
        'stdout' => record.fetch('stdout'), 'process' => clean_record(record) }
    end

    def capture_invalid_constructors
      cases = [
        ['dynamic', 'AggregateFunction(min, Dynamic)', 'AggregateFunction(max, Dynamic)'],
        ['variant', 'AggregateFunction(min, Variant(UInt8, String))', 'AggregateFunction(max, Variant(UInt8, String))'],
      ]
      cases.each do |id, *types|
        types.each_with_index do |type, index|
          operation = index.zero? ? 'min' : 'max'
          label = "constructor-invalid-#{id}-#{operation}"
          table = "w237_refused_#{id}_#{operation}"
          store = File.join(@source_root, 'stores', 'construction', "#{id}-#{operation}")
          Dir.mkdir(store, 0o700)
          record = process(label, store,
            "CREATE TABLE default.#{table} (v #{type}) ENGINE=Memory")
          diagnostic = (record.fetch('stdout') + record.fetch('stderr')).force_encoding(Encoding::UTF_8).scrub
          semantic = record.fetch('classification') == 'process_nonzero_or_signaled_exit' &&
            record.fetch('exitstatus') && record.fetch('exitstatus').positive? && !record.fetch('signaled') &&
            !record.fetch('timed_out') && !record.fetch('spawn_error') &&
            diagnostic.match?(/Illegal type .* of argument of aggregate function #{operation}/i)
          @construction << { 'id' => "#{id}_#{operation}",
            'classification' => semantic ? 'expected_semantic_refusal' : 'unexpected_constructor_process_outcome',
            'requested_type' => type, 'source_anchor' => 'src/AggregateFunctions/AggregateFunctionsMinMax.cpp',
            'process' => clean_record(record), 'stdout' => record.fetch('stdout'), 'stderr' => record.fetch('stderr'),
            'observed_diagnostic' => diagnostic.lines.grep(/DB::Exception/).map(&:strip) }
          require_true(semantic, "#{label} was not an isolated expected source-level constructor refusal")
        end
      end
    end

    def capture_lc_constructor_only
      @lc_constructor_only = CONSTRUCTOR_ONLY_TYPES.map do |spec|
        store = File.join(@source_root, 'stores', 'construction', spec.fetch('id'))
        Dir.mkdir(store, 0o700)
        table = "w237_#{spec.fetch('id')}"
        sql = "CREATE TABLE default.#{table} (v #{spec.fetch('type')}) ENGINE=Memory;\n" \
          "SELECT 'W237_LC_CENSUS_BEGIN_#{spec.fetch('id')}' FORMAT TSVRaw;\n" \
          "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;\n" \
          "SELECT 'W237_LC_CENSUS_END_#{spec.fetch('id')}' FORMAT TSVRaw"
        record = process("constructor-lc-only-#{spec.fetch('id')}", store, sql)
        status = record.fetch('classification')
        require_true(!record.fetch('timed_out') && !record.fetch('spawn_error') && !record.fetch('signaled'),
          "LC constructor-only probe did not produce a normal process outcome: #{spec.fetch('id')}")
        if status == 'process_success' && record.fetch('exitstatus') == 0
          observed = marker_section(record.fetch('stdout'),
            "W237_LC_CENSUS_BEGIN_#{spec.fetch('id')}", "W237_LC_CENSUS_END_#{spec.fetch('id')}", spec.fetch('id'))
          schema = observed.lines.map(&:chomp)
          classification = if schema.length == 1 && schema.first.start_with?("v\tAggregateFunction(#{spec.fetch('operation')}, ")
                              'source_constructor_acceptance_observed'
                            else
                              'constructor_schema_observation_differed'
                            end
          { 'id' => spec.fetch('id'), 'requested_type' => spec.fetch('type'),
            'classification' => classification, 'schema' => schema,
            'process' => clean_record(record), 'stdout' => record.fetch('stdout'), 'stderr' => record.fetch('stderr') }
        else
          diagnostic = (record.fetch('stdout') + record.fetch('stderr')).force_encoding(Encoding::UTF_8).scrub
          { 'id' => spec.fetch('id'), 'requested_type' => spec.fetch('type'),
            'classification' => 'constructor_process_refusal_observed',
            'observed_diagnostic' => diagnostic.lines.grep(/DB::Exception/).map(&:strip),
            'process' => clean_record(record), 'stdout' => record.fetch('stdout'), 'stderr' => record.fetch('stderr') }
        end
      end
    end

    def capture_source_controls
      @profiles.each do |profile|
        paths = source_control_paths(@source_root, profile)
        paths.each_value { |path| require_true(!File.exist?(path) && !File.symlink?(path), "refusing to overwrite native control #{path}") }
        record = checked_success!(process("source-controls-#{profile.fetch('id')}", File.join(@source_root, 'stores', 'construction'),
          source_control_sql(profile, @source_root)), "native source controls #{profile.fetch('id')}")
        type_name = marker_section(record.fetch('stdout'),
          "W237_SOURCE_TYPE_BEGIN_#{profile.fetch('id')}", "W237_SOURCE_TYPE_END_#{profile.fetch('id')}", "source type #{profile.fetch('id')}")
        expected_type_line = "AggregateFunction(#{profile.fetch('operation')}, #{profile.fetch('argument_type')})\n"
        observed_type = type_name
        control_values = {}
        { 'empty' => false, 'all_null' => false, 'populated' => true }.each do |kind, populated|
          next unless paths.key?(kind)
          bytes = File.binread(paths.fetch(kind))
          expected = expected_control_state(profile, populated: populated)
          require_true(bytes == expected,
            "native source-computed #{kind} state differs from independent literal for #{profile.fetch('id')}: #{bytes.unpack1('H*')}")
          control_values[kind] = control_record(paths.fetch(kind), bytes, expected)
        end
        # Type spelling is evidence, not a prior assumption: preserve it even
        # when the stock parser canonicalizes Nested or a dispatch shell.
        control_observation = { 'id' => profile.fetch('id'), 'operation' => profile.fetch('operation'),
          'requested_type' => profile.fetch('requested_type'), 'declared_type' => profile.fetch('declared_type'),
          'source_state_type_name' => observed_type, 'expected_type_name' => expected_type_line,
          'type_name_matches_nominal_request' => observed_type == expected_type_line,
          'empty' => control_values.fetch('empty'),
          'populated' => control_values.fetch('populated'),
          'process' => clean_record(record) }
        control_observation['all_null'] = control_values.fetch('all_null') if paths.key?('all_null')
        @source_controls << control_observation
      end
    end

    def capture_string_legacy
      @string_legacy = []
      %w[min max].each do |operation|
        STRING_LEGACY_CASES.each do |spec|
          id = "#{operation}_#{spec.fetch('id')}"
          store = File.join(@source_root, 'stores', 'string-legacy', id)
          Dir.mkdir(store, 0o700)
          table = "w237_string_legacy_#{operation}_#{spec.fetch('id')}"
          type = "AggregateFunction(#{operation}, String)"
          settings = R::STOCK_SETTINGS + ["string_serialization_version='single_stream'"]
          create_sql = "CREATE TABLE default.#{table} (pk UInt64, v #{type}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings.join(', ')}"
          create = process("string-legacy-create-#{id}", store, create_sql)
          input = little_unsigned(ROW_KEYS.first, 8) + [spec.fetch('input_hex')].pack('H*').b
          insert = process("string-legacy-insert-#{id}", store,
            "INSERT INTO default.#{table} FORMAT RowBinary", input: input)
          output_path = File.join(@source_root, 'cases', 'string-legacy', "#{id}.rowbinary")
          require_true(!File.exist?(output_path) && !File.symlink?(output_path),
            "refusing to overwrite legacy String output #{output_path}")
          readback = process("string-legacy-readback-#{id}", store,
            "SELECT v FROM default.#{table} ORDER BY pk INTO OUTFILE '#{quote_sql(output_path)}' FORMAT RowBinary")
          [create, insert, readback].each do |record|
            require_true(!record.fetch('timed_out') && !record.fetch('spawn_error') && !record.fetch('signaled'),
              "legacy String reader probe had a timeout, spawn failure, or signal: #{record.fetch('label')}")
          end
          expected = [spec.fetch('expected_hex')].pack('H*').b
          actual = nil
          classification = if create.fetch('exitstatus') != 0 || insert.fetch('exitstatus') != 0 || readback.fetch('exitstatus') != 0
                             'normal_process_refusal_observed'
                           else
                             require_true(File.file?(output_path) && !File.symlink?(output_path),
                               "legacy String readback succeeded without creating output: #{id}")
                             actual = File.binread(output_path)
                             require_true(actual == expected,
                               "legacy String canonical readback differs for #{id}: #{actual.unpack1('H*')}")
                             'source_compatibility_observed'
                           end
          @string_legacy << { 'id' => id, 'operation' => operation,
            'raw_input_state_hex' => spec.fetch('input_hex'), 'expected_canonical_state_hex' => spec.fetch('expected_hex'),
            'source_law' => spec.fetch('law'), 'classification' => classification,
            'output_path' => output_path, 'observed_output_state_hex' => actual && actual.unpack1('H*'),
            'processes' => [create, insert, readback].map { |record| clean_record(record) } }
        end
      end
    end

    def control_record(path, bytes, expected)
      { 'path' => path, 'bytes' => bytes.bytesize, 'sha256' => Digest::SHA256.hexdigest(bytes),
        'literal_hex' => expected.unpack1('H*'), 'observed_hex' => bytes.unpack1('H*'), 'matches' => bytes == expected }
    end

    def create_stock_tables
      sql = @profiles.map { |profile| create_sql(profile, table_name(profile)) }.join(";\n")
      record = checked_success!(process('stock-create-all', source_store(@source_root), sql), 'stock table creation')
      @stock_create_process = clean_record(record)
    end

    def insert_stock_fixtures
      @profiles.each do |profile|
        input = rowbinary_rows(profile).join.b
        record = checked_success!(process("stock-insert-#{profile.fetch('id')}", source_store(@source_root),
          "INSERT INTO default.#{table_name(profile)} FORMAT RowBinary", input: input), "stock fixture insert #{profile.fetch('id')}")
        @records[-1]['input_bytes'] = input.bytesize
        @records[-1]['input_sha256'] = Digest::SHA256.hexdigest(input)
      end
    end

    def stock_capture_sql
      statements = []
      @profiles.each do |profile|
        id = profile.fetch('id')
        table = table_name(profile)
        statements << "SELECT 'W237_CHECK_BEGIN_#{id}' FORMAT TSVRaw"
        statements << "CHECK TABLE default.#{table} FORMAT TSVRaw"
        statements << "SELECT 'W237_CHECK_END_#{id}' FORMAT TSVRaw"
        statements << "SELECT 'W237_SCHEMA_BEGIN_#{id}' FORMAT TSVRaw"
        statements << "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw"
        statements << "SELECT 'W237_SCHEMA_END_#{id}' FORMAT TSVRaw"
        statements << "SELECT 'W237_PART_BEGIN_#{id}' FORMAT TSVRaw"
        statements << "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw"
        statements << "SELECT 'W237_PART_END_#{id}' FORMAT TSVRaw"
        %w[full middle zero].each do |window|
          predicate = { 'full' => '', 'middle' => ' WHERE pk BETWEEN 22 AND 44', 'zero' => ' WHERE pk=0' }.fetch(window)
          path = File.join(@source_root, 'cases', 'stock-rowbinary', "#{id}-#{window}.rowbinary")
          statements << "SELECT pk, v FROM default.#{table}#{predicate} ORDER BY pk INTO OUTFILE '#{quote_sql(path)}' FORMAT RowBinary"
        end
      end
      statements.join(";\n")
    end

    def capture_stock_profiles
      @profiles.each do |profile|
        %w[full middle zero].each do |window|
          path = File.join(@source_root, 'cases', 'stock-rowbinary', "#{profile.fetch('id')}-#{window}.rowbinary")
          require_true(!File.exist?(path) && !File.symlink?(path), "refusing to overwrite stock RowBinary #{path}")
        end
      end
      record = checked_success!(process('stock-capture-all', source_store(@source_root), stock_capture_sql), 'stock physical capture')
      @stock_capture_process = clean_record(record)
      @profiles.each do |profile|
        id = profile.fetch('id')
        check = marker_section(record.fetch('stdout'), "W237_CHECK_BEGIN_#{id}", "W237_CHECK_END_#{id}", "CHECK #{id}")
        require_true(check == CHECK_OUTPUT, "stock CHECK output differs for #{id}: #{check.inspect}")
        schema = marker_section(record.fetch('stdout'), "W237_SCHEMA_BEGIN_#{id}", "W237_SCHEMA_END_#{id}", "schema #{id}")
        rows = schema.lines.map(&:chomp)
        require_true(rows.length == 2 && rows.first == "pk\tUInt64" && rows.last.start_with?("v\tAggregateFunction(#{profile.fetch('operation')}, "),
          "stock system.columns shape differs for #{id}: #{rows.inspect}")
        observed_declared = rows.last.split("\t", 2).fetch(1)
        require_true(observed_declared == profile.fetch('declared_type'),
          "stock table schema differs from constructor census for #{id}")
        part_output = marker_section(record.fetch('stdout'), "W237_PART_BEGIN_#{id}", "W237_PART_END_#{id}", "part census #{id}")
        part_rows = part_output.lines.map(&:chomp)
        require_true(part_rows.length == 1, "expected one active stock part for #{id}: #{part_rows.inspect}")
        fields = part_rows.first.split("\t", -1)
        require_true(fields.length == 5 && fields[0] == 'all_1_1_0' && fields[1] == '5' && fields[2] == '4' && fields[3] == 'Wide',
          "stock part identity/grid differs for #{id}: #{fields.inspect}")
        original = File.expand_path(fields[4])
        require_true(File.directory?(original) && !File.symlink?(original) && File.realpath(original) == original,
          "stock part path invalid for #{id}")
        target = profile_part_path(@source_root, profile)
        target_parent = File.dirname(target)
        Dir.mkdir(target_parent, 0o700)
        FileUtils.cp_r(original, target)
        files = {}
        %w[full middle zero].each do |window|
          path = File.join(@source_root, 'cases', 'stock-rowbinary', "#{id}-#{window}.rowbinary")
          actual = File.binread(path)
          expected = rowbinary_window(profile, window)
          require_true(actual == expected, "stock #{window} RowBinary differs from literal rows for #{id}")
          files[window] = { 'path' => path, 'bytes' => actual.bytesize,
            'sha256' => Digest::SHA256.hexdigest(actual), 'literal_hex' => expected.unpack1('H*'),
            'matches_independent_literal' => true }
        end
        physical = part_metadata(target)
        @stock_profiles << {
          'id' => id, 'requested_type' => profile.fetch('requested_type'), 'declared_type' => observed_declared,
          'states_hex' => state_hex(profile), 'stock_part_path' => target,
          'check_output' => check, 'schema' => rows, 'part_census' => fields,
          'physical' => physical, 'rowbinary_windows' => files,
          'source_controls' => @source_controls.find { |item| item.fetch('id') == id },
        }
      end
    end

    def part_metadata(part)
      files = inventory(part)
      metadata = {}
      {
        'serialization_json' => 'serialization.json',
        'metadata_version' => 'metadata_version.txt',
        'compression_codec' => 'default_compression_codec.txt',
      }.each do |key, filename|
        path = File.join(part, filename)
        require_true(File.file?(path) && !File.symlink?(path), "part metadata missing #{filename}")
        bytes = File.binread(path)
        metadata[key] = { 'path' => filename, 'sha256' => Digest::SHA256.hexdigest(bytes), 'bytes' => bytes.bytesize }
        metadata[key]['parsed'] = JSON.parse(bytes) if key == 'serialization_json'
        metadata[key]['text'] = bytes.force_encoding(Encoding::UTF_8).scrub.strip if key != 'serialization_json'
      end
      { 'inventory' => files, 'metadata' => metadata }
    rescue JSON::ParserError => error
      fail!("stock part serialization.json is invalid: #{error.message}")
    end

    def write_stock_matrix
      @matrix_path = File.join(@source_root, 'stock-matrix.json')
      matrix = { 'format' => STOCK_FORMAT, 'row_keys' => ROW_KEYS, 'mark_rows' => MARK_ROWS,
        'profile_count' => @stock_profiles.length,
        'coverage' => coverage_manifest,
        'profiles' => @stock_profiles.map { |profile| profile.slice('id', 'declared_type', 'states_hex', 'stock_part_path') },
        'profile_evidence' => @stock_profiles,
        'source_root' => @source_root, 'runtime_pin' => @runtime_pin, 'source_pin' => @source_pin,
        'constructor_observations' => @construction, 'lc_constructor_only_observations' => @lc_constructor_only,
        'source_computed_controls' => @source_controls, 'string_legacy_observations' => @string_legacy,
        'stock_settings' => R::STOCK_SETTINGS + ["string_serialization_version='single_stream'"] }
      write_json(@matrix_path, matrix)
      @matrix_sha256 = Digest::SHA256.file(@matrix_path).hexdigest
    end

    def load_stock_matrix
      @matrix_path = File.join(@source_root, 'stock-matrix.json')
      bytes = File.binread(@matrix_path)
      matrix = JSON.parse(bytes.force_encoding(Encoding::UTF_8))
      require_true(matrix.fetch('format') == STOCK_FORMAT && matrix.fetch('row_keys') == ROW_KEYS &&
        matrix.fetch('mark_rows') == MARK_ROWS && matrix.fetch('profile_count') == @profiles.length,
        'stock matrix format or finite profile count differs')
      @matrix_sha256 = Digest::SHA256.hexdigest(bytes)
      actual = matrix.fetch('profiles')
      require_true(actual.length == @profiles.length, 'stock matrix profile count differs from finite W237 roster')
      evidence = matrix.fetch('profile_evidence')
      require_true(evidence.length == @profiles.length, 'stock matrix detailed evidence roster differs')
      @profiles.each_with_index do |expected, index|
        observed = actual.fetch(index)
        detail = evidence.fetch(index)
        require_true(observed.fetch('id') == expected.fetch('id') && observed.fetch('states_hex') == state_hex(expected),
          "stock matrix identity or literal state fixture differs at #{expected.fetch('id')}")
        require_true(observed.keys.sort == %w[declared_type id states_hex stock_part_path].sort &&
          detail.fetch('id') == observed.fetch('id') && detail.fetch('declared_type') == observed.fetch('declared_type') &&
          detail.fetch('states_hex') == observed.fetch('states_hex') && detail.fetch('stock_part_path') == observed.fetch('stock_part_path'),
          "stock matrix core profile contract or detail cross-reference differs at #{expected.fetch('id')}")
        expected['declared_type'] = observed.fetch('declared_type')
        expected['stock_part_path'] = observed.fetch('stock_part_path')
        expected['stock_profile'] = detail
        require_true(detail.fetch('schema').last == "v\t#{expected.fetch('declared_type')}",
          "stock matrix observed schema differs for #{expected.fetch('id')}")
        path = observed.fetch('stock_part_path')
        require_true(path == profile_part_path(@source_root, expected), "stock part path differs from canonical W237 path for #{expected.fetch('id')}")
        inventory(path)
      end
      @stock_matrix = matrix
    rescue JSON::ParserError, KeyError => error
      fail!("stock matrix is invalid: #{error.message}")
    end

    def invoke_helper
      require_true(Digest::SHA256.file(@helper).hexdigest == @helper_sha256, 'helper SHA changed before invocation')
      process_record = run_helper(@helper, @matrix_path, @generated_root, @evidence_root)
      @helper_process = clean_helper_process(process_record)
      checked_success!(process_record, 'W237 physical helper')
      require_true(Digest::SHA256.file(@helper).hexdigest == @helper_sha256, 'helper SHA changed during invocation')
      output = JSON.parse(process_record.fetch('stdout').force_encoding(Encoding::UTF_8))
      require_true(output.fetch('format') == HELPER_FORMAT && output.fetch('profile_count') == @profiles.length,
        'physical helper JSON format/profile count differs')
      actual = output.fetch('profiles')
      require_true(actual.length == @profiles.length, 'physical helper returned incomplete profile roster')
      @profiles.each_with_index do |profile, index|
        observed = actual.fetch(index)
        stock = profile.fetch('stock_profile')
        require_true(observed.fetch('id') == profile.fetch('id') &&
          observed.fetch('declared_type') == profile.fetch('declared_type') &&
          File.realpath(observed.fetch('stock_part_path')) == stock.fetch('stock_part_path'),
          "helper output profile identity/type/stock path differs: #{profile.fetch('id')}")
        helper_path = File.expand_path(observed.fetch('library_part_path'))
        require_true(helper_path == File.join(@generated_root, 'generated', profile.fetch('id'), 'all_1_1_0'),
          "helper library part path differs from canonical output layout: #{profile.fetch('id')}")
        profile['library_part_path'] = helper_path
        profile['helper_profile'] = observed
        profile['library_inventory_before_attach'] = inventory(helper_path)
      end
      @helper_output = output
      @helper_stdout_sha256 = Digest::SHA256.hexdigest(process_record.fetch('stdout'))
    rescue JSON::ParserError, KeyError => error
      fail!("physical helper stdout is not the declared W237 JSON contract: #{error.message}")
    end

    def native_create_sql
      statements = []
      @profiles.each do |profile|
        table = table_name(profile, 'native')
        statements << create_sql(profile, table)
        statements << "SELECT 'W237_NATIVE_DATA_PATH_BEGIN_#{profile.fetch('id')}' FORMAT TSVRaw"
        statements << "SELECT arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw"
        statements << "SELECT 'W237_NATIVE_DATA_PATH_END_#{profile.fetch('id')}' FORMAT TSVRaw"
      end
      statements.join(";\n")
    end

    def attach_sql
      @profiles.map do |profile|
        "ALTER TABLE default.#{table_name(profile, 'native')} ATTACH PART 'all_1_1_0'"
      end.join(";\n")
    end

    def prepare_detached_parts(create_stdout)
      native_store = File.join(@evidence_root, 'stores', 'native')
      @profiles.each do |profile|
        id = profile.fetch('id')
        body = marker_section(create_stdout, "W237_NATIVE_DATA_PATH_BEGIN_#{id}",
          "W237_NATIVE_DATA_PATH_END_#{id}", "native data path #{id}")
        lines = body.lines.map(&:chomp)
        require_true(lines.length == 1 && !lines.first.empty? && !lines.first.include?("\t"),
          "native system.tables.data_paths observation is malformed for #{id}")
        data_path = File.expand_path(lines.first)
        require_true(data_path.start_with?(native_store + File::SEPARATOR) && File.directory?(data_path) &&
          !File.symlink?(data_path) && File.realpath(data_path) == data_path,
          "native system.tables.data_paths escaped isolated store for #{id}")
        detached_dir = File.join(data_path, 'detached')
        require_true(File.directory?(detached_dir) && !File.symlink?(detached_dir) &&
          File.realpath(detached_dir) == detached_dir,
          "native detached directory is absent/noncanonical for #{id}")
        detached_part = File.join(detached_dir, 'all_1_1_0')
        require_true(!File.exist?(detached_part) && !File.symlink?(detached_part),
          "native detached destination is not fresh for #{id}")

        library_path = profile.fetch('library_part_path')
        library_before = inventory(library_path)
        require_true(library_before == profile.fetch('library_inventory_before_attach'),
          "generated source part changed after helper preflight for #{id}")
        FileUtils.cp_r(library_path, detached_part)
        detached_inventory = inventory(detached_part)
        require_true(detached_inventory == library_before,
          "fresh detached copy differs from generated source part for #{id}")
        profile['native_data_path'] = data_path
        profile['detached_part_path'] = detached_part
        profile['detached_inventory_before_attach'] = detached_inventory
      end
    end

    def native_capture_sql
      statements = []
      @profiles.each do |profile|
        id = profile.fetch('id')
        table = table_name(profile, 'native')
        statements << "SELECT 'W237_NATIVE_CHECK_BEGIN_#{id}' FORMAT TSVRaw"
        statements << "CHECK TABLE default.#{table} FORMAT TSVRaw"
        statements << "SELECT 'W237_NATIVE_CHECK_END_#{id}' FORMAT TSVRaw"
        statements << "SELECT 'W237_NATIVE_SCHEMA_BEGIN_#{id}' FORMAT TSVRaw"
        statements << "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw"
        statements << "SELECT 'W237_NATIVE_SCHEMA_END_#{id}' FORMAT TSVRaw"
        statements << "SELECT 'W237_NATIVE_PART_BEGIN_#{id}' FORMAT TSVRaw"
        statements << "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw"
        statements << "SELECT 'W237_NATIVE_PART_END_#{id}' FORMAT TSVRaw"
        %w[full middle zero].each do |window|
          predicate = { 'full' => '', 'middle' => ' WHERE pk BETWEEN 22 AND 44', 'zero' => ' WHERE pk=0' }.fetch(window)
          path = File.join(@evidence_root, 'cases', 'native-rowbinary', "#{id}-#{window}.rowbinary")
          statements << "SELECT pk, v FROM default.#{table}#{predicate} ORDER BY pk INTO OUTFILE '#{quote_sql(path)}' FORMAT RowBinary"
        end
      end
      statements.join(";\n")
    end

    def capture_native_profiles
      require_true(@profiles.all? { |profile| File.directory?(profile.fetch('library_part_path')) }, 'helper did not create every library part')
      create = checked_success!(process('native-create-all', File.join(@evidence_root, 'stores', 'native'), native_create_sql), 'native table creation')
      @native_create_process = clean_record(create)
      prepare_detached_parts(create.fetch('stdout'))
      attach = checked_success!(process('native-attach-all', File.join(@evidence_root, 'stores', 'native'), attach_sql), 'native part attachment')
      @native_attach_process = clean_record(attach)
      capture = checked_success!(process('native-capture-all', File.join(@evidence_root, 'stores', 'native'), native_capture_sql), 'native part verification')
      @native_capture_process = clean_record(capture)
      @profiles.each do |profile|
        id = profile.fetch('id')
        check = marker_section(capture.fetch('stdout'), "W237_NATIVE_CHECK_BEGIN_#{id}", "W237_NATIVE_CHECK_END_#{id}", "native CHECK #{id}")
        require_true(check == CHECK_OUTPUT, "native CHECK output differs for #{id}: #{check.inspect}")
        schema = marker_section(capture.fetch('stdout'), "W237_NATIVE_SCHEMA_BEGIN_#{id}", "W237_NATIVE_SCHEMA_END_#{id}", "native schema #{id}")
        rows = schema.lines.map(&:chomp)
        require_true(rows == ["pk\tUInt64", "v\t#{profile.fetch('declared_type')}"], "native schema differs for #{id}: #{rows.inspect}")
        part_output = marker_section(capture.fetch('stdout'), "W237_NATIVE_PART_BEGIN_#{id}", "W237_NATIVE_PART_END_#{id}", "native part #{id}")
        part_rows = part_output.lines.map(&:chomp)
        require_true(part_rows.length == 1, "expected one attached native part for #{id}")
        fields = part_rows.first.split("\t", -1)
        require_true(fields.length == 5 && fields[0] == 'all_1_1_0' && fields[1] == '5' && fields[2] == '4' && fields[3] == 'Wide',
          "native attached part identity/grid differs for #{id}: #{fields.inspect}")
        attached_part_path = File.join(profile.fetch('native_data_path'), 'all_1_1_0')
        observed_part_path = File.expand_path(fields.fetch(4))
        require_true(observed_part_path == attached_part_path && File.directory?(attached_part_path) &&
          !File.symlink?(attached_part_path) && File.realpath(attached_part_path) == attached_part_path,
          "native attached part path does not descend from observed system.tables.data_paths for #{id}")
        require_true(!File.exist?(profile.fetch('detached_part_path')) && !File.symlink?(profile.fetch('detached_part_path')),
          "native detached source remains after successful ATTACH for #{id}")
        attached_inventory = inventory(attached_part_path)
        library_inventory = profile.fetch('library_inventory_before_attach')
        library_by_path = library_inventory.to_h { |entry| [entry.fetch('path'), entry] }
        attached_by_path = attached_inventory.to_h { |entry| [entry.fetch('path'), entry] }
        removed = (library_by_path.keys - attached_by_path.keys).sort
        changed = library_by_path.keys.select do |path|
          attached_by_path.key?(path) && library_by_path.fetch(path) != attached_by_path.fetch(path)
        end.sort
        added = (attached_by_path.keys - library_by_path.keys).sort
        require_true(removed.empty? && changed.empty? && [[], [INVALIDATED_FILE]].include?(added),
          "native ATTACH inventory delta differs from generated part for #{id}")
        if added == [INVALIDATED_FILE]
          invalidated = File.binread(File.join(attached_part_path, INVALIDATED_FILE))
          require_true(["_block_number\n_block_offset\n", "_block_offset\n_block_number\n"].include?(invalidated),
            "native invalidated-system-columns contents differ for #{id}")
        end
        library_inventory_after = inventory(profile.fetch('library_part_path'))
        require_true(library_inventory_after == library_inventory,
          "native ATTACH changed generated source files for #{id}")
        windows = {}
        %w[full middle zero].each do |window|
          path = File.join(@evidence_root, 'cases', 'native-rowbinary', "#{id}-#{window}.rowbinary")
          actual = File.binread(path)
          expected = rowbinary_window(profile, window)
          require_true(actual == expected, "native #{window} RowBinary differs from independent literals for #{id}")
          windows[window] = { 'path' => path, 'bytes' => actual.bytesize,
            'sha256' => Digest::SHA256.hexdigest(actual), 'literal_hex' => expected.unpack1('H*'),
            'matches_independent_literal' => true }
        end
        @native_profiles << { 'id' => id, 'declared_type' => profile.fetch('declared_type'),
          'stock_part_path' => profile.fetch('stock_part_path'), 'library_part_path' => profile.fetch('library_part_path'),
          'native_data_path' => profile.fetch('native_data_path'),
          'detached_part_path' => profile.fetch('detached_part_path'),
          'detached_inventory_before_attach' => profile.fetch('detached_inventory_before_attach'),
          'library_inventory_before_attach' => profile.fetch('library_inventory_before_attach'),
          'library_inventory_after_attach' => library_inventory_after,
          'attached_part_path' => attached_part_path,
          'attached_inventory' => attached_inventory,
          'attached_inventory_delta' => { 'removed' => removed, 'changed' => changed, 'added' => added },
          'check_output' => check, 'schema' => rows, 'part_census' => fields, 'rowbinary_windows' => windows }
      end
      write_json(File.join(@evidence_root, 'cases', 'native-matrix.json'), {
        'format' => 'aggregate_minmax_w237_native_v1', 'profile_count' => @native_profiles.length,
        'profiles' => @native_profiles, 'processes' => {
          'create' => @native_create_process, 'attach' => @native_attach_process, 'capture' => @native_capture_process,
        },
      })
    end

    def verify_clickhouse_roster!
      labels = @recorder.records.map { |record| record.fetch('label') }
      require_true(labels.uniq.length == labels.length, 'duplicate raw ClickHouse invocation labels')
      expected = %w[runtime-version-pin runtime-build-pin constructor-positive-census
        constructor-invalid-dynamic-min constructor-invalid-dynamic-max constructor-invalid-variant-min constructor-invalid-variant-max]
      if @stock_only
        expected.concat(CONSTRUCTOR_ONLY_TYPES.map { |spec| "constructor-lc-only-#{spec.fetch('id')}" })
        expected.concat(@profiles.map { |profile| "source-controls-#{profile.fetch('id')}" })
        expected.concat(['stock-create-all', 'stock-capture-all'])
        expected.concat(@profiles.map { |profile| "stock-insert-#{profile.fetch('id')}" })
        expected.concat(%w[min max].flat_map do |operation|
          STRING_LEGACY_CASES.flat_map do |spec|
            id = "#{operation}_#{spec.fetch('id')}"
            %W[string-legacy-create-#{id} string-legacy-insert-#{id} string-legacy-readback-#{id}]
          end
        end)
      else
        expected = %w[runtime-version-pin runtime-build-pin]
        expected.concat(%w[native-create-all native-attach-all native-capture-all])
      end
      require_true(labels.sort == expected.sort, 'raw ClickHouse invocation roster differs from exact W237 phase')
      @recorder.records.each do |record|
        label = record.fetch('label')
        normal = !record.fetch('signaled') && !record.fetch('timed_out') && !record.fetch('spawn_error')
        if label.start_with?('constructor-invalid-')
          require_true(normal && record.fetch('classification') == 'process_nonzero_or_signaled_exit' &&
            record.fetch('exitstatus') && record.fetch('exitstatus').positive?,
            "expected source-level constructor refusal has wrong process outcome: #{label}")
        elsif label.start_with?('constructor-lc-only-') || label.start_with?('string-legacy-')
          require_true(normal, "bounded compatibility/census process did not finish normally: #{label}")
        else
          require_true(record.fetch('classification') == 'process_success' && record.fetch('exitstatus') == 0 && normal,
            "unexpected ClickHouse process failure: #{label}")
        end
      end
    end

    def marker_section(stdout, start_marker, end_marker, label)
      lines = stdout.force_encoding(Encoding::UTF_8).scrub.lines
      start = lines.index { |line| line.chomp == start_marker }
      finish = lines.index { |line| line.chomp == end_marker }
      require_true(start && finish && finish > start, "raw stdout markers missing for #{label}")
      body = lines[(start + 1)...finish]
      body.join
    end

    def write_summary(classification)
      return unless @evidence_root && File.directory?(@evidence_root) && !File.exist?(File.join(@evidence_root, 'summary.json'))
      path = File.join(@evidence_root, 'stock-matrix.json')
      @matrix_sha256 ||= Digest::SHA256.file(path).hexdigest if File.file?(path)
      records = @recorder ? @recorder.records.map { |record| clean_record(record) } : []
      summary = { 'format' => SUMMARY_FORMAT, 'classification' => classification,
        'success' => %w[stock_minmax_profiles_observed paired_minmax_profiles_observed].include?(classification),
        'error' => @fatal, 'stock_only' => @stock_only, 'stock_root' => @source_root,
        'evidence_root' => @evidence_root, 'generated_root' => @generated_root,
        'matrix_path' => File.file?(path) ? path : @matrix_path, 'stock_matrix_sha256' => @matrix_sha256,
        'source_pin' => @source_pin, 'runtime_pin' => @runtime_pin,
        'helper_path' => @helper, 'helper_sha256' => @helper_sha256, 'helper_process' => @helper_process,
        'helper_stdout_sha256' => @helper_stdout_sha256,
        'profile_count_expected' => @profiles.length, 'stock_profile_count' => @stock_profiles.length,
        'coverage' => coverage_manifest,
        'native_profile_count' => @native_profiles.length, 'constructor_observations' => @construction,
        'lc_constructor_only_observations' => @lc_constructor_only, 'string_legacy_observations' => @string_legacy,
        'source_control_count' => @source_controls.length, 'processes' => records }
      write_json(File.join(@evidence_root, 'summary.json'), summary)
    end
  end

  def marker_section(stdout, start_marker, end_marker, label)
    lines = stdout.force_encoding(Encoding::UTF_8).scrub.lines
    start = lines.index { |line| line.chomp == start_marker }
    finish = lines.index { |line| line.chomp == end_marker }
    require_true(start && finish && finish > start, "raw stdout markers missing for #{label}")
    lines[(start + 1)...finish].join
  end

  def main(argv)
    options = { stock_only: false }
    parser = OptionParser.new do |opts|
      opts.banner = <<~USAGE
        Usage:
          ruby scripts/recheck_aggregate_minmax_w237.rb --clickhouse BIN --stock-only --output-root EMPTY_STOCK_ROOT
          ruby scripts/recheck_aggregate_minmax_w237.rb --clickhouse BIN --stock-matrix PATH --output-root EMPTY_EVIDENCE_ROOT --generated-root EMPTY_GENERATED_ROOT --helper BIN --helper-sha256 HEX
      USAGE
      opts.on('--clickhouse PATH') { |value| options[:clickhouse] = value }
      opts.on('--stock-only') { options[:stock_only] = true }
      opts.on('--stock-matrix PATH') { |value| options[:stock_matrix] = value }
      opts.on('--output-root PATH') { |value| options[:output_root] = value }
      opts.on('--generated-root PATH') { |value| options[:generated_root] = value }
      opts.on('--helper PATH') { |value| options[:helper] = value }
      opts.on('--helper-sha256 HEX') { |value| options[:helper_sha256] = value }
    end
    parser.parse!(argv)
    require_true(argv.empty? && options[:clickhouse] && options[:output_root], parser.to_s)
    if options[:stock_only]
      require_true(!options[:stock_matrix] && !options[:generated_root] && !options[:helper] && !options[:helper_sha256], parser.to_s)
    else
      require_true(options[:stock_matrix] && options[:generated_root] && options[:helper] && options[:helper_sha256], parser.to_s)
    end
    Probe.new(options).run
  rescue StandardError => error
    warn "W237 min/max runner setup failure: #{error.class}: #{error.message}"
    false
  end
end

exit(RecheckAggregateMinmaxW237.main(ARGV) ? 0 : 1) if $PROGRAM_NAME == __FILE__
