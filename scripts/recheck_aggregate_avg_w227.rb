#!/usr/bin/env ruby
# Paired stock-ClickHouse and Crystal avg AggregateFunction qualification.
# The RowBinary aggregate states are independent literal bytes; avgState SQL
# probes separately verify a small set of source-generated states.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require_relative 'recheck_aggregate_recursive_w224'

module RecheckAggregateAvgW227
  extend self

  R = RecheckAggregateRecursiveW224
  VERSION = R::VERSION.freeze
  BUILD_HASH = R::BUILD_HASH.freeze
  RUNTIME_SHA256 = R::RUNTIME_SHA256.freeze
  SOURCE_ROOT = R::SOURCE_ROOT.freeze
  SOURCE_REVISION = R::SOURCE_REVISION.freeze
  SOURCE_PREFIX = '/private/tmp/crystal-click-w227-native.'.freeze
  EVIDENCE_PREFIX = '/private/tmp/crystal-click-w227-evidence.'.freeze
  FORMAT_INPUT = 'aggregate_avg_w227_input_v1'.freeze
  FORMAT_HELPER = 'aggregate_avg_w227_helper_v1'.freeze
  FORMAT_SUMMARY = 'aggregate_avg_w227_summary_v1'.freeze
  FORMAT_MATRIX = 'aggregate_avg_w227_stock_matrix_v1'.freeze
  FORMAT_NATIVE = 'aggregate_avg_w227_native_matrix_v1'.freeze
  HELPER_LABEL = 'generic-stock-read-library-write-read'.freeze
  ROW_KEYS = R::ROW_KEYS.map(&:to_i).freeze
  MARK_ROWS = R::MARK_ROWS.map(&:to_i).freeze
  CHECK_OUTPUT = "all_1_1_0\t1\t\n".freeze
  MAX_U64 = 18_446_744_073_709_551_615
  COUNT_WIRES = [0, 127, 128, 16_384, MAX_U64].freeze
  BASE_PROFILE_COUNT = 136
  PROFILE_COUNT = 148
  NULL_ROW_INDEX = 2
  INVALIDATED_FILE = 'invalidated_system_columns.txt'.freeze
  INVALIDATED_NAMES = %w[_block_number _block_offset].freeze

  SOURCE_HASHES = {
    'src/AggregateFunctions/AggregateFunctionAvg.cpp' => 'fa4b350334ca402d4e17928823ca244cc4ca698ee1cb1fd465646ec770cfb48c',
    'src/AggregateFunctions/AggregateFunctionAvg.h' => 'f9760157c55129578105501dc771896cc6ac9995a3b1809552a00911f3406c6e',
    'src/AggregateFunctions/AggregateFunctionFactory.cpp' => '19edf542a3fc0364ffece33db8051d788613fd2125354679f501b9ddd038330a',
    'src/AggregateFunctions/Combinators/AggregateFunctionNull.cpp' => '829d45d95c8c17471a6093cc5a2ae3238c8728fd73cb57e0b908b412d4012efc',
    'src/AggregateFunctions/Combinators/AggregateFunctionNull.h' => '94eee4ce82872fb54d40b440519278282eae46871fe94d7d4f8c64f6caeb9501',
    'src/AggregateFunctions/IAggregateFunction.h' => '07b52aa8d08744674ee677f2b1ec55089c72870cf16e2aafaa0f815c34073b0d',
    'src/AggregateFunctions/FactoryHelpers.h' => 'abe6d4e6f20b93b1089c0c0bce90999dd58a421918d70b5dd1d186f5ed278b96',
    'src/AggregateFunctions/Helpers.h' => '1ef65dadd04fcf968998f35db36f300877550d7732c88d25b8e0fe8109857892',
    'src/Core/Field.h' => '42fd21be18892643bcfae9962485b0605441fa39e8d56df2a6e13da5554ea0c4',
    'base/base/Decimal_fwd.h' => '6f2bca44c9ded6aceabbbac2316a4100983655939a386c35aeffe11a4c1bf9da',
    'src/DataTypes/IDataType.h' => '6e9befee2cf642d989912710a4857c5a122fb7ba337eafc6b923c10f8eb33d5c',
    'src/DataTypes/DataTypeDomainBool.cpp' => '3de0e1b9e943e381270216d676c46ab8a5cf19bd70f7c41b52831ef0fa9a8d68',
    'src/DataTypes/DataTypeLowCardinality.cpp' => 'e75ef3196f929ed61313394fe8ba13c0a377446f73fac12f2b2425128d625c5c',
    'src/DataTypes/DataTypeLowCardinality.h' => '5f2e0e468177df1ce933240f7303d3558a2ba94a63e4dcdf4f92951f9520f0b2',
    'src/DataTypes/DataTypeNumberBase.h' => '277d1f9233b3ec0c58a02f8865b28f75320dc09587fe303a0425be47297d54e0',
    'src/DataTypes/DataTypeDecimalBase.h' => '9cc360ca7218629d9b697c46acdf0e2855604d78704d760e5d5fe620368f1955',
    'src/DataTypes/DataTypesDecimal.cpp' => 'c5aafee0387ea3bdd9b558759c654b8d48e492b4c6bc6b2b486b2283e2d17d6e',
    'src/DataTypes/DataTypeInterval.h' => '5ad4cc9f20ea828d13f531f25a6d4cfacc8669ea54e26bc1f4fd06d866d6d8a7',
    'src/DataTypes/DataTypeInterval.cpp' => 'feac362223d5a6445f810574c625f245acf6ebe183d4f97f506422b94daf347a',
    'src/Common/IntervalKind.h' => 'c4ad758a9d01d3c935bd2399c1c6aad7df668fab14ff881b731cc4d9bbf161ed',
    'src/DataTypes/DataTypeAggregateFunction.cpp' => '81a26eab248379dd3f055fb716a4e7cb3a5f08a90239116f6df3af5b8c83b4ec',
    'src/DataTypes/Serializations/SerializationAggregateFunction.cpp' => '1fa59453165a7cdb33811e8cf8eb55d7f7b18abd4d28281397470dd217dd4950',
    'src/DataTypes/DataTypeDateTime64.cpp' => 'e585bd8190c92fd52bbcb28165a272e41a8c507e823d246716c38e942e888adf',
    'src/DataTypes/DataTypeDateTime64.h' => '587ca9498e2321309578e0dde78937875e2bd241ad9e90edb15d9b4266c6e098',
    'src/DataTypes/DataTypeTime64.cpp' => '01d3e9ab70e1dcb71b02e0040383cbda2273a2ec50decf8a69af23292ccad8a9',
    'src/DataTypes/DataTypeTime64.h' => 'fd3b4eb7d7c730366ac45747a7793e1e1777c182b8b15145b63ccb73684df55f',
    'src/DataTypes/DataTypeDate.cpp' => 'a93159bbe79e556a896698250b5cd2b1fea46ab267f5fcef95b47a2b7e967ea8',
    'src/DataTypes/DataTypeDate32.cpp' => '54850ab01593a1edc9698b2e11149dbd148dec1c9c9d46e39b4599786a5ee665',
    'src/DataTypes/DataTypeDateTime.cpp' => 'f9d5fbfe0d896bd55e995e5f71bfb759ee02f6b4a6880e8c5abd25dac2be0f7c',
    'src/DataTypes/DataTypeTime.cpp' => '8c35c3bb4e01a35ffa82c273091d6a42d4e9459214b738130d355c3ed9e5a65b',
  }.freeze

  SOURCE_LAWS = [
    { 'path' => 'src/AggregateFunctions/AggregateFunctionAvg.cpp', 'lines' => '21-35,37-68,84-89',
      'law' => 'avg is unary and parameterless; it admits numeric, decimal, date/time, and interval TypeIndex families, dispatches temporal/decimal accumulator widths, and preserves interval units.' },
    { 'path' => 'src/AggregateFunctions/AggregateFunctionAvg.h', 'lines' => '237-273,465-487',
      'law' => 'avg state serializes little-endian numerator followed by VarUInt UInt64 count; merge adds both; numerator width depends on the dispatched accumulator.' },
    { 'path' => 'src/AggregateFunctions/Combinators/AggregateFunctionNull.h', 'lines' => '221-256,482-491',
      'law' => 'Nullable arguments are wrapped by the internal Null combinator; its state stores a presence byte and nested avg state only when present.' },
    { 'path' => 'src/AggregateFunctions/Combinators/AggregateFunctionNull.cpp', 'lines' => '100-115,129-141',
      'law' => 'Null combinator transforms nullable arguments and forwards non-null values to the nested aggregate.' },
    { 'path' => 'src/DataTypes/DataTypeDomainBool.cpp', 'lines' => '11-18',
      'law' => 'Bool exposes the UInt8 type index and is source-valid for avg despite being a distinct domain type.' },
    { 'path' => 'src/DataTypes/IDataType.h', 'lines' => '430-437,466-478,691-706',
      'law' => 'The numeric gate includes Bool backing UInt8 and BFloat16 while Enum8/16 remain distinct nonnumeric types.' },
    { 'path' => 'src/DataTypes/DataTypeLowCardinality.cpp', 'lines' => '30-40',
      'law' => 'LowCardinality validity depends on inner-type eligibility; nullable inner types are supported where their nested type can be inside LC.' },
    { 'path' => 'src/DataTypes/DataTypeNumberBase.h', 'lines' => '53',
      'law' => 'Numeric domain types opt into LowCardinality eligibility.' },
    { 'path' => 'src/DataTypes/DataTypeDecimalBase.h', 'lines' => '96-99',
      'law' => 'Decimal types do not opt into LowCardinality eligibility.' },
    { 'path' => 'src/DataTypes/DataTypesDecimal.cpp', 'lines' => '29-32,99-112',
      'law' => 'Decimal32/64/128/256 scale syntax constructs max-precision Decimal types whose canonical names are Decimal(P, S).' },
    { 'path' => 'src/DataTypes/DataTypeInterval.cpp', 'lines' => '24-60,185-207',
      'law' => 'The finite interval aliases are the 11 named Interval units; all share the Interval TypeIndex.' },
    { 'path' => 'src/DataTypes/DataTypeAggregateFunction.cpp', 'lines' => '349-359',
      'law' => 'AggregateFunction type metadata retains its declared argument descriptors after factory construction.' },
  ].freeze

  def fail!(message)
    raise ArgumentError, message
  end

  def require_true(condition, message)
    fail!(message) unless condition
  end

  def write_json(path, object)
    R.write_json(path, object)
  end

  def profile_slug(type)
    type.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
  end

  def wrap_argument(type, shell)
    case shell
    when 'bare' then type
    when 'nullable' then "Nullable(#{type})"
    when 'low_cardinality' then "LowCardinality(#{type})"
    when 'low_cardinality_nullable' then "LowCardinality(Nullable(#{type}))"
    else fail!("unlisted avg argument shell: #{shell}")
    end
  end

  def make_leaf(type, family, numerator_kind, numerator_width, low_cardinality: true)
    { 'type' => type, 'family' => family, 'numerator_kind' => numerator_kind,
      'numerator_width' => numerator_width, 'low_cardinality' => low_cardinality }
  end

  def numeric_leaves
    rows = []
    %w[UInt8 UInt16 UInt32 UInt64].each { |type| rows << make_leaf(type, 'unsigned', 'integer', 8) }
    rows << make_leaf('UInt128', 'unsigned', 'integer', 16)
    rows << make_leaf('UInt256', 'unsigned', 'integer', 32)
    %w[Int8 Int16 Int32 Int64].each { |type| rows << make_leaf(type, 'signed', 'integer', 8) }
    rows << make_leaf('Int128', 'signed', 'integer', 16)
    rows << make_leaf('Int256', 'signed', 'integer', 32)
    %w[BFloat16 Float32 Float64].each { |type| rows << make_leaf(type, 'float', 'float64', 8) }
    rows << make_leaf('Bool', 'bool', 'integer', 8)
    rows
  end

  def base_leaves
    leaves = numeric_leaves
    [['Decimal(9, 0)', 16], ['Decimal(18, 0)', 16], ['Decimal(38, 0)', 16], ['Decimal(76, 0)', 32]].each do |type, width|
      leaves << make_leaf(type, 'decimal', 'integer', width, low_cardinality: false)
    end
    %w[Date Date32 DateTime Time].each do |type|
      leaves << make_leaf(type, 'temporal', 'integer', 8)
    end
    leaves << make_leaf('DateTime64(3)', 'scaled_temporal', 'integer', 16, low_cardinality: false)
    leaves << make_leaf('Time64(3)', 'scaled_temporal', 'integer', 16, low_cardinality: false)
    %w[IntervalNanosecond IntervalMicrosecond IntervalMillisecond IntervalSecond IntervalMinute
       IntervalHour IntervalDay IntervalWeek IntervalMonth IntervalQuarter IntervalYear].each do |type|
      leaves << make_leaf(type, 'interval', 'integer', 8)
    end
    leaves
  end

  def witness_leaves
    [
      make_leaf("DateTime('UTC')", 'temporal_metadata_witness', 'integer', 8),
      make_leaf("DateTime64(0, 'UTC')", 'scaled_temporal_witness', 'integer', 16, low_cardinality: false),
      make_leaf("DateTime64(9, 'UTC')", 'scaled_temporal_witness', 'integer', 16, low_cardinality: false),
      make_leaf('Time64(0)', 'scaled_temporal_witness', 'integer', 16, low_cardinality: false),
      make_leaf('Time64(9)', 'scaled_temporal_witness', 'integer', 16, low_cardinality: false),
    ]
  end

  def profile_roster
    profiles = []
    (base_leaves + witness_leaves).each do |leaf|
      shells = leaf.fetch('low_cardinality') ? %w[bare nullable low_cardinality low_cardinality_nullable] : %w[bare nullable]
      shells.each do |shell|
        argument = wrap_argument(leaf.fetch('type'), shell)
        id = "avg_#{profile_slug(leaf.fetch('type'))}_#{shell}"
        profiles << leaf.merge('id' => id, 'argument_type' => argument,
          'declared_type' => "AggregateFunction(avg, #{argument})", 'shell' => shell,
          'nullable_state' => argument.include?('Nullable('))
      end
    end
    require_true(profiles.length == PROFILE_COUNT, 'W227 full finite roster count differs from 148')
    require_true(profiles.take(BASE_PROFILE_COUNT).length == BASE_PROFILE_COUNT,
      'W227 base compatibility roster count differs from 136')
    require_true(profiles.map { |row| row.fetch('id') }.uniq.length == profiles.length,
      'W227 profile IDs are not unique')
    profiles.each_with_index { |profile, index| profile['ordinal'] = index }
    profiles
  end

  def u64(value)
    number = Integer(value)
    require_true(number >= 0 && number <= MAX_U64, "UInt64 literal outside range: #{value.inspect}")
    Array.new(8) { |index| (number >> (index * 8)) & 0xff }.pack('C*').b
  end

  def varuint(value)
    number = Integer(value)
    require_true(number >= 0 && number <= MAX_U64, "VarUInt literal outside range: #{value.inspect}")
    bytes = []
    while number >= 0x80
      bytes << ((number & 0x7f) | 0x80)
      number >>= 7
    end
    (bytes << number).pack('C*').b
  end

  def little_unsigned(value, width)
    number = Integer(value)
    require_true(number >= 0 && number < (1 << (width * 8)), "numerator does not fit #{width} bytes")
    Array.new(width) { |index| (number >> (index * 8)) & 0xff }.pack('C*').b
  end

  def numerator_bytes(profile, count)
    value = count == MAX_U64 ? 0 : count
    value = 0 if count == 0
    raw = if profile.fetch('numerator_kind') == 'float64'
            [value.to_f].pack('E').b
          else
            little_unsigned(value, profile.fetch('numerator_width'))
          end
    require_true(raw.bytesize == profile.fetch('numerator_width'), "numerator width differs for #{profile.fetch('id')}")
    raw
  end

  def state_bytes(profile, index)
    if profile.fetch('nullable_state') && index == NULL_ROW_INDEX
      return "\x00".b
    end
    count = profile.fetch('nullable_state') ? [0, 127, nil, 16_384, MAX_U64].fetch(index) : COUNT_WIRES.fetch(index)
    body = numerator_bytes(profile, count) + varuint(count)
    profile.fetch('nullable_state') ? "\x01".b + body : body
  end

  def states(profile)
    ROW_KEYS.each_index.map { |index| state_bytes(profile, index) }
  end

  def rowbinary_rows(profile)
    states(profile).each_with_index.map { |state, index| u64(ROW_KEYS.fetch(index)) + state }
  end

  def expected_windows(profile)
    rows = rowbinary_rows(profile)
    { 'full' => rows.join.b, 'middle' => rows[1, 3].join.b, 'zero' => ''.b }
  end

  def computed_probes
    [
      { 'id' => 'empty_uint8', 'argument_type' => 'UInt8', 'numerator_kind' => 'integer', 'width' => 8, 'numerator' => 0, 'count' => 0,
        'query' => "SELECT avgState(toUInt8(number)) FROM numbers(0) INTO OUTFILE '%PATH%' FORMAT RowBinary" },
      { 'id' => 'uint8_count_127', 'argument_type' => 'UInt8', 'numerator_kind' => 'integer', 'width' => 8, 'numerator' => 8001, 'count' => 127,
        'query' => "SELECT avgState(toUInt8(number)) FROM numbers(127) INTO OUTFILE '%PATH%' FORMAT RowBinary" },
      { 'id' => 'uint8_count_128', 'argument_type' => 'UInt8', 'numerator_kind' => 'integer', 'width' => 8, 'numerator' => 8128, 'count' => 128,
        'query' => "SELECT avgState(toUInt8(number)) FROM numbers(128) INTO OUTFILE '%PATH%' FORMAT RowBinary" },
      { 'id' => 'signed_int8', 'argument_type' => 'Int8', 'numerator_kind' => 'integer', 'width' => 8, 'numerator' => 3, 'count' => 3,
        'query' => "SELECT avgState(toInt8(x)) FROM (SELECT arrayJoin([-2, 1, 4]) AS x) INTO OUTFILE '%PATH%' FORMAT RowBinary" },
      { 'id' => 'float32_accumulates_float64', 'argument_type' => 'Float32', 'numerator_kind' => 'float64', 'width' => 8, 'numerator' => 8.0, 'count' => 3,
        'query' => "SELECT avgState(toFloat32(x)) FROM (SELECT arrayJoin([1.5, 2.25, 4.25]) AS x) INTO OUTFILE '%PATH%' FORMAT RowBinary" },
      { 'id' => 'decimal32_scale2', 'argument_type' => 'Decimal(9, 2)', 'numerator_kind' => 'integer', 'width' => 16, 'numerator' => 200, 'count' => 3,
        'query' => "SELECT avgState(toDecimal32(x, 2)) FROM (SELECT arrayJoin([1, 2, -1]) AS x) INTO OUTFILE '%PATH%' FORMAT RowBinary" },
      { 'id' => 'date', 'argument_type' => 'Date', 'numerator_kind' => 'integer', 'width' => 8, 'numerator' => 2, 'count' => 2,
        'query' => "SELECT avgState(toDate(x)) FROM (SELECT arrayJoin(['1970-01-01', '1970-01-03']) AS x) INTO OUTFILE '%PATH%' FORMAT RowBinary" },
      { 'id' => 'date32', 'argument_type' => 'Date32', 'numerator_kind' => 'integer', 'width' => 8, 'numerator' => 2, 'count' => 2,
        'query' => "SELECT avgState(toDate32(x)) FROM (SELECT arrayJoin(['1970-01-01', '1970-01-03']) AS x) INTO OUTFILE '%PATH%' FORMAT RowBinary" },
      { 'id' => 'datetime_utc', 'argument_type' => "DateTime('UTC')", 'numerator_kind' => 'integer', 'width' => 8, 'numerator' => 3, 'count' => 2,
        'query' => "SELECT avgState(toDateTime(x, 'UTC')) FROM (SELECT arrayJoin([1, 2]) AS x) INTO OUTFILE '%PATH%' FORMAT RowBinary" },
      { 'id' => 'time', 'argument_type' => 'Time', 'numerator_kind' => 'integer', 'width' => 8, 'numerator' => 3, 'count' => 2,
        'query' => "SELECT avgState(toTime(toDateTime(x, 'UTC'))) FROM (SELECT arrayJoin([1, 2]) AS x) INTO OUTFILE '%PATH%' FORMAT RowBinary" },
      { 'id' => 'datetime64_scale9_utc', 'argument_type' => "DateTime64(9, 'UTC')", 'numerator_kind' => 'integer', 'width' => 16, 'numerator' => 3_000_000_000, 'count' => 2,
        'query' => "SELECT avgState(toDateTime64(x, 9, 'UTC')) FROM (SELECT arrayJoin([1, 2]) AS x) INTO OUTFILE '%PATH%' FORMAT RowBinary" },
      { 'id' => 'time64_scale9', 'argument_type' => 'Time64(9)', 'numerator_kind' => 'integer', 'width' => 16, 'numerator' => 3, 'count' => 2,
        'query' => "SELECT avgState(toTime64(x, 9)) FROM (SELECT arrayJoin(['00:00:00.000000001', '00:00:00.000000002']) AS x) INTO OUTFILE '%PATH%' FORMAT RowBinary" },
      { 'id' => 'interval_day', 'argument_type' => 'IntervalDay', 'numerator_kind' => 'integer', 'width' => 8, 'numerator' => 3, 'count' => 2,
        'query' => "SELECT avgState(toIntervalDay(x)) FROM (SELECT arrayJoin([1, 2]) AS x) INTO OUTFILE '%PATH%' FORMAT RowBinary" },
    ]
  end

  def computed_state(probe)
    numerator = if probe.fetch('numerator_kind') == 'float64'
                  [probe.fetch('numerator')].pack('E').b
                else
                  little_unsigned(probe.fetch('numerator'), probe.fetch('width'))
                end
    numerator + varuint(probe.fetch('count'))
  end

  def source_pin!
    base = R.pin_source!
    rows = SOURCE_HASHES.map do |relative, expected|
      path = File.join(SOURCE_ROOT, relative)
      require_true(File.file?(path) && !File.symlink?(path), "source anchor absent or symlinked: #{relative}")
      actual = Digest::SHA256.file(path).hexdigest
      { 'path' => relative, 'expected_sha256' => expected, 'actual_sha256' => actual, 'matches' => actual == expected }
    end
    require_true(rows.all? { |row| row.fetch('matches') }, 'a supplemental avg source hash differs')
    base.merge('aggregate_avg_source_hashes' => rows, 'aggregate_avg_source_laws' => SOURCE_LAWS)
  end

  def checked_success!(record, label)
    require_true(record.fetch('classification') == 'process_success' && record.fetch('exitstatus') == 0 &&
      !record.fetch('signaled') && !record.fetch('timed_out') && !record.fetch('spawn_error'),
      "#{label} failed as a process; process failure is not semantic refusal")
    record
  end

  def clean_record(record)
    record.reject { |key, _| %w[stdout stderr path].include?(key) }
  end

  def diagnostic_messages(record)
    (record.fetch('stdout') + record.fetch('stderr')).lines.map do |line|
      match = /\ACode: [0-9]+\. DB::Exception: (.*?)(?:\r?\n)?\z/.match(line)
      next unless match
      match[1].sub(/\s+\([A-Z_]+\)(?:\s+\(version [^)]+\))?\z/, '').sub(/\.\z/, '')
    end.compact
  end

  def index_token(index)
    format('%03d', index)
  end

  def stock_table(profile)
    "w227_stock_p#{index_token(profile.fetch('ordinal'))}"
  end

  def native_table(profile)
    "w227_native_p#{index_token(profile.fetch('ordinal'))}"
  end

  def schema_output(profile)
    "pk\tUInt64\nv\t#{profile.fetch('declared_type')}\n"
  end

  def create_sql(profile, table)
    settings = R::STOCK_SETTINGS
    "CREATE TABLE default.#{table} (pk UInt64, v #{profile.fetch('declared_type')}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings.join(', ')}"
  end

  def constructor_sql(profiles)
    columns = profiles.each_with_index.map { |profile, index| "p#{index_token(index)} #{profile.fetch('declared_type')}" }
    "CREATE TABLE default.w227_constructor (pk UInt8, #{columns.join(', ')}) ENGINE=Memory;\n" \
      "SELECT name, type FROM system.columns WHERE database='default' AND table='w227_constructor' ORDER BY position FORMAT TSVRaw"
  end

  def enum_sql(width)
    value_type = "Enum#{width}('a' = 1, 'b' = 2)"
    "CREATE TABLE default.w227_refused_enum#{width} (v AggregateFunction(avg, #{value_type})) ENGINE=Memory"
  end

  def stock_capture_sql(profiles, source_root)
    sql = []
    profiles.each do |profile|
      id = profile.fetch('id')
      table = stock_table(profile)
      sql << "SELECT 'W227_CHECK_BEGIN_#{id}' FORMAT TSVRaw"
      sql << "CHECK TABLE default.#{table} FORMAT TSVRaw"
      sql << "SELECT 'W227_CHECK_END_#{id}' FORMAT TSVRaw"
      %w[full middle zero].each do |window|
        predicate = { 'full' => '', 'middle' => ' WHERE pk BETWEEN 22 AND 44', 'zero' => ' WHERE pk=0' }.fetch(window)
        path = File.join(source_root, 'cases', 'rowbinary', "stock-#{id}-#{window}.rowbinary")
        sql << "SELECT pk, v FROM default.#{table}#{predicate} ORDER BY pk INTO OUTFILE '#{path}' FORMAT RowBinary"
      end
    end
    sql.join(";\n")
  end

  def inspect_sql(profiles, side, data_path_by_id = {})
    sql = []
    profiles.each do |profile|
      id = profile.fetch('id')
      table = side == 'stock' ? stock_table(profile) : native_table(profile)
      %w[schema type part].each do |kind|
        sql << "SELECT 'W227_#{side.upcase}_#{kind.upcase}_BEGIN_#{id}' FORMAT TSVRaw"
        query = case kind
                when 'schema'
                  "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw"
                when 'type'
                  "SELECT toTypeName(v) FROM default.#{table} LIMIT 1 FORMAT TSVRaw"
                when 'part'
                  "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw"
                end
        sql << query
        sql << "SELECT 'W227_#{side.upcase}_#{kind.upcase}_END_#{id}' FORMAT TSVRaw"
      end
    end
    sql.join(";\n")
  end

  def rowbinary_path(root, side, profile, window)
    File.join(root, 'cases', 'rowbinary', "#{side}-#{profile.fetch('id')}-#{window}.rowbinary")
  end

  def rowbinary_indices(window)
    { 'full' => [0, 1, 2, 3, 4], 'middle' => [1, 2, 3], 'zero' => [] }.fetch(window)
  end

  def invocations_expected(profiles)
    labels = %w[runtime-version-pin runtime-build-pin constructor-positive-census
      constructor-invalid-enum8 constructor-invalid-enum16 avgstate-computed-probes stock-create-all
      stock-capture-all stock-inspect-all generic-stock-read-library-write-read native-create-all
      native-data-paths native-attach-and-capture-all native-inspect-all]
    labels.concat(profiles.map { |profile| "stock-insert-#{profile.fetch('id')}" })
    labels
  end

  class Probe
    def initialize(options)
      @binary = R.validate_binary!(options.fetch(:clickhouse))
      @expected_helper_sha = R.validate_sha256_pin!(options.fetch(:helper_sha256), 'external helper SHA-256')
      @helper = R.validate_program!(options.fetch(:helper), 'prebuilt W227 Crystal helper')
      @helper_sha_start = Digest::SHA256.file(@helper).hexdigest
      RecheckAggregateAvgW227.require_true(@helper_sha_start == @expected_helper_sha,
        "prebuilt W227 helper differs from external SHA-256 pin: #{@helper_sha_start}")
      @source_root = R.validate_root(options.fetch(:source_root), SOURCE_PREFIX, 'stock source root')
      @root = R.validate_root(options.fetch(:evidence_root), EVIDENCE_PREFIX, 'evidence root')
      @profiles = RecheckAggregateAvgW227.profile_roster
      @recorder = R::Recorder.new(@root, @binary)
      @source_profiles = []
      @helper_profiles = []
      @native_profiles = []
      @construction_records = []
      @computed_records = []
      @source_pin = nil
      @runtime_pin = nil
      @helper_input_sha = nil
      @helper_sha_after = nil
      @source_matrix_sha = nil
      @native_matrix_sha = nil
      @fatal = nil
    end

    def run
      prepare_layout
      @source_pin = RecheckAggregateAvgW227.source_pin!
      pin_runtime
      capture_constructor_census
      capture_invalid_constructors
      capture_computed_probes
      capture_stock_profiles
      write_source_matrix
      invoke_helper
      capture_native_profiles
      verify_invocations
      write_summary('paired_aggregate_avg_profiles_observed')
      puts "W227 paired AggregateFunction(avg) profiles=#{@profiles.length}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal ||= "#{error.class}: #{error.message}"
      write_summary('runner_failure_or_observations_differ') rescue nil
      warn "W227 avg probe failure (process failure is not semantic refusal): #{@fatal}"
      false
    end

    private

    def prepare_layout
      %w[invocations generated cases stores].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'generated', 'parts'), 0o700)
      %w[stores parts cases].each { |name| Dir.mkdir(File.join(@source_root, name), 0o700) }
      Dir.mkdir(File.join(@source_root, 'stores', 'pins'), 0o700)
      Dir.mkdir(File.join(@source_root, 'stores', 'construction'), 0o700)
      Dir.mkdir(File.join(@source_root, 'stores', 'stock'), 0o700)
      Dir.mkdir(File.join(@source_root, 'parts', 'profiles'), 0o700)
      Dir.mkdir(File.join(@source_root, 'cases', 'rowbinary'), 0o700)
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
      Dir.mkdir(File.join(@root, 'cases', 'rowbinary'), 0o700)
    end

    def process(label, store, sql = nil, input: nil, timeout: R::PROCESS_TIMEOUT_SECONDS, argv: nil)
      @recorder.run(label, store, sql, input: input, timeout: timeout, argv: argv)
    end

    def pin_runtime
      store = File.join(@source_root, 'stores', 'pins')
      version = RecheckAggregateAvgW227.checked_success!(process('runtime-version-pin', store,
        'SELECT version() FORMAT TSVRaw'), 'runtime version')
      RecheckAggregateAvgW227.require_true(version.fetch('stdout').strip == VERSION, 'native version differs from exact pin')
      build = RecheckAggregateAvgW227.checked_success!(process('runtime-build-pin', store,
        "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw"), 'runtime build hash')
      RecheckAggregateAvgW227.require_true(build.fetch('stdout').strip == "VERSION_GITHASH=#{BUILD_HASH}", 'native build hash differs from exact pin')
      @runtime_pin = { 'version' => VERSION, 'build_hash' => BUILD_HASH,
        'sha256' => Digest::SHA256.file(@binary).hexdigest, 'runtime_source_correlation' => 'not_asserted' }
      RecheckAggregateAvgW227.write_json(File.join(@source_root, 'runtime_pin.json'), @runtime_pin)
    end

    def capture_constructor_census
      record = RecheckAggregateAvgW227.checked_success!(process('constructor-positive-census',
        File.join(@source_root, 'stores', 'construction'), RecheckAggregateAvgW227.constructor_sql(@profiles)),
        'positive avg constructor census')
      expected = ["pk\tUInt8\n"] + @profiles.each_with_index.map do |profile, index|
        "p#{RecheckAggregateAvgW227.index_token(index)}\t#{profile.fetch('declared_type')}\n"
      end
      RecheckAggregateAvgW227.require_true(record.fetch('stdout') == expected.join,
        'stock avg constructor census differs from all exact declared signatures')
      @construction_records << { 'classification' => 'source_constructor_acceptance_observed',
        'profile_count' => @profiles.length, 'base_source_valid_count' => BASE_PROFILE_COUNT,
        'metadata_witness_count' => PROFILE_COUNT - BASE_PROFILE_COUNT,
        'stdout' => record.fetch('stdout'), 'process' => RecheckAggregateAvgW227.clean_record(record) }
    end

    def capture_invalid_constructors
      [8, 16].each do |width|
        id = "enum#{width}"
        store = File.join(@source_root, 'stores', 'construction', id)
        Dir.mkdir(store, 0o700)
        record = process("constructor-invalid-#{id}", store, RecheckAggregateAvgW227.enum_sql(width))
        messages = RecheckAggregateAvgW227.diagnostic_messages(record)
        valid = record.fetch('classification') == 'process_nonzero_or_signaled_exit' &&
          record.fetch('exitstatus') && record.fetch('exitstatus').positive? && !record.fetch('signaled') &&
          !record.fetch('timed_out') && !record.fetch('spawn_error') && messages.length == 1 &&
          messages.first.start_with?("Illegal type Enum#{width}") &&
          messages.first.include?('of argument for aggregate function avg')
        RecheckAggregateAvgW227.require_true(valid, "Enum#{width} negative constructor control did not match avg source refusal")
        @construction_records << { 'id' => id, 'classification' => 'expected_semantic_refusal',
          'source_anchor' => 'src/AggregateFunctions/AggregateFunctionAvg.cpp:37-46',
          'expected_diagnostic_pattern' => "Illegal type Enum#{width} ... of argument for aggregate function avg",
          'observed_diagnostics' => messages, 'process' => RecheckAggregateAvgW227.clean_record(record) }
      end
    end

    def capture_computed_probes
      probes = RecheckAggregateAvgW227.computed_probes
      sql = probes.map do |probe|
        path = File.join(@root, 'cases', 'rowbinary', "computed-#{probe.fetch('id')}.rowbinary")
        RecheckAggregateAvgW227.require_true(!File.exist?(path) && !File.symlink?(path), "refusing to overwrite #{path}")
        probe.fetch('query').sub('%PATH%', path)
      end.join(";\n")
      record = RecheckAggregateAvgW227.checked_success!(process('avgstate-computed-probes',
        File.join(@source_root, 'stores', 'construction'), sql), 'source-generated avgState probes')
      probes.each do |probe|
        path = File.join(@root, 'cases', 'rowbinary', "computed-#{probe.fetch('id')}.rowbinary")
        actual = File.binread(path)
        expected = RecheckAggregateAvgW227.computed_state(probe)
        RecheckAggregateAvgW227.require_true(actual == expected,
          "source-generated avgState bytes differ for #{probe.fetch('id')}")
        @computed_records << { 'id' => probe.fetch('id'), 'argument_type' => probe.fetch('argument_type'),
          'expected_hex' => expected.unpack1('H*'), 'actual_hex' => actual.unpack1('H*'),
          'path' => path, 'bytes' => actual.bytesize, 'sha256' => Digest::SHA256.hexdigest(actual),
          'matches_independent_literal' => true }
      end
      @computed_process = RecheckAggregateAvgW227.clean_record(record)
    end

    def all_create_sql(profiles, side)
      profiles.map do |profile|
        table = side == 'stock' ? RecheckAggregateAvgW227.stock_table(profile) : RecheckAggregateAvgW227.native_table(profile)
        RecheckAggregateAvgW227.create_sql(profile, table)
      end.join(";\n")
    end

    def inventory(part)
      full = File.expand_path(part)
      RecheckAggregateAvgW227.require_true(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full,
        "part is absent, symlinked, or noncanonical: #{full}")
      entries = []
      Find.find(full) do |path|
        next if path == full
        RecheckAggregateAvgW227.require_true(!File.symlink?(path), "part contains symlink: #{path}")
        next if File.directory?(path)
        RecheckAggregateAvgW227.require_true(File.file?(path), "part contains non-file entry: #{path}")
        entries << { 'path' => path[(full.length + 1)..-1], 'size' => File.size(path), 'sha256' => Digest::SHA256.file(path).hexdigest }
      end
      entries.sort_by { |entry| entry.fetch('path') }
    end

    def section(stdout, start_marker, end_marker, label)
      lines = stdout.lines
      starts = lines.each_index.select { |index| lines[index].chomp == start_marker }
      ends = lines.each_index.select { |index| lines[index].chomp == end_marker }
      RecheckAggregateAvgW227.require_true(starts.length == 1 && ends.length == 1 && starts.first < ends.first,
        "#{label} section markers are missing, duplicated, or reversed")
      lines[(starts.first + 1)...ends.first].join
    end

    def stock_input(profile)
      RecheckAggregateAvgW227.rowbinary_rows(profile).join.b
    end

    def capture_stock_profiles
      store = File.join(@source_root, 'stores', 'stock')
      create = RecheckAggregateAvgW227.checked_success!(process('stock-create-all', store,
        all_create_sql(@profiles, 'stock')), 'stock CREATE all profiles')
      @profiles.each do |profile|
        id = profile.fetch('id')
        insert = RecheckAggregateAvgW227.checked_success!(process("stock-insert-#{id}", store,
          "INSERT INTO default.#{RecheckAggregateAvgW227.stock_table(profile)} FORMAT RowBinary", input: stock_input(profile)),
          "stock RowBinary INSERT #{id}")
        profile['stock_insert_process'] = RecheckAggregateAvgW227.clean_record(insert)
      end
      capture = RecheckAggregateAvgW227.checked_success!(process('stock-capture-all', store,
        RecheckAggregateAvgW227.stock_capture_sql(@profiles, @source_root)), 'stock CHECK and RowBinary captures')
      expected_check_stdout = @profiles.map do |profile|
        "W227_CHECK_BEGIN_#{profile.fetch('id')}\n#{CHECK_OUTPUT}W227_CHECK_END_#{profile.fetch('id')}\n"
      end.join
      RecheckAggregateAvgW227.require_true(capture.fetch('stdout') == expected_check_stdout,
        'stock raw CHECK result bits differ from one exact successful part per profile')
      @stock_capture_process = RecheckAggregateAvgW227.clean_record(capture)

      inspect = RecheckAggregateAvgW227.checked_success!(process('stock-inspect-all', store,
        RecheckAggregateAvgW227.inspect_sql(@profiles, 'stock')), 'stock metadata and part inspection')
      @profiles.each do |profile|
        id = profile.fetch('id')
        schema = section(inspect.fetch('stdout'), "W227_STOCK_SCHEMA_BEGIN_#{id}", "W227_STOCK_SCHEMA_END_#{id}", "stock schema #{id}")
        type_name = section(inspect.fetch('stdout'), "W227_STOCK_TYPE_BEGIN_#{id}", "W227_STOCK_TYPE_END_#{id}", "stock typeName #{id}")
        part_line = section(inspect.fetch('stdout'), "W227_STOCK_PART_BEGIN_#{id}", "W227_STOCK_PART_END_#{id}", "stock part #{id}")
        RecheckAggregateAvgW227.require_true(schema == RecheckAggregateAvgW227.schema_output(profile), "stock exact schema differs for #{id}")
        RecheckAggregateAvgW227.require_true(type_name == "#{profile.fetch('declared_type')}\n", "stock toTypeName differs for #{id}")
        fields = part_line.chomp.split("\t", -1)
        RecheckAggregateAvgW227.require_true(fields.length == 5 && fields.first(4) == ['all_1_1_0', '5', '4', 'Wide'],
          "stock part identity/grid differs for #{id}: #{fields.inspect}")
        original = File.expand_path(fields.fetch(4))
        RecheckAggregateAvgW227.require_true(File.directory?(original) && !File.symlink?(original) && File.realpath(original) == original,
          "stock part path is invalid for #{id}")
        source_part = File.join(@source_root, 'parts', 'profiles', id, 'all_1_1_0')
        Dir.mkdir(File.dirname(source_part), 0o700)
        FileUtils.cp_r(original, source_part)
        source_inventory = inventory(source_part)
        serialization = JSON.parse(File.binread(File.join(source_part, 'serialization.json')))
        RecheckAggregateAvgW227.require_true(File.binread(File.join(source_part, 'metadata_version.txt')).strip == '0' &&
          File.binread(File.join(source_part, 'default_compression_codec.txt')).strip == 'CODEC(LZ4)' &&
          File.binread(File.join(source_part, 'count.txt')).strip == '5', "stock part metadata differs for #{id}")

        windows = {}
        %w[full middle zero].each do |window|
          path = RecheckAggregateAvgW227.rowbinary_path(@source_root, 'stock', profile, window)
          actual = File.binread(path)
          expected = RecheckAggregateAvgW227.expected_windows(profile).fetch(window)
          RecheckAggregateAvgW227.require_true(actual == expected,
            "stock #{window} RowBinary differs from independent literal for #{id}")
          windows[window] = { 'path' => path, 'bytes' => actual.bytesize,
            'sha256' => Digest::SHA256.hexdigest(actual), 'literal_hex' => actual.unpack1('H*'),
            'matches_independent_literal' => true }
        end
        profile['source_part'] = source_part
        profile['source_inventory'] = source_inventory
        profile['source_serialization'] = serialization
        profile['stock_schema'] = schema
        profile['stock_type_name'] = type_name
        profile['stock_part_path'] = original
        profile['stock_check_output'] = CHECK_OUTPUT
        profile['stock_rowbinary_windows'] = windows
      end
      @stock_create_process = RecheckAggregateAvgW227.clean_record(create)
      @stock_inspect_process = RecheckAggregateAvgW227.clean_record(inspect)
      @source_profiles = @profiles
    end

    def helper_input_profile(profile)
      index = profile.fetch('ordinal')
      { 'id' => profile.fetch('id'), 'declared_type' => profile.fetch('declared_type'),
        'argument_type' => profile.fetch('argument_type'), 'source_part' => profile.fetch('source_part'),
        'library_part' => File.join(@root, 'generated', 'parts',
          "library-#{RecheckAggregateAvgW227.index_token(index)}-#{profile.fetch('id')}", 'all_1_1_0'),
        'row_keys' => ROW_KEYS, 'mark_rows' => MARK_ROWS,
        'state_hex' => RecheckAggregateAvgW227.states(profile).map { |bytes| bytes.unpack1('H*') },
        'literal_rowbinary_hex' => RecheckAggregateAvgW227.rowbinary_rows(profile).map { |bytes| bytes.unpack1('H*') } }
    end

    def write_source_matrix
      @helper_inputs = @profiles.map { |profile| helper_input_profile(profile) }
      matrix = { 'format' => FORMAT_MATRIX, 'profile_count' => @profiles.length,
        'base_source_valid_count' => BASE_PROFILE_COUNT, 'metadata_witness_count' => PROFILE_COUNT - BASE_PROFILE_COUNT,
        'construction_records' => @construction_records, 'computed_probes' => @computed_records,
        'source_pin' => @source_pin, 'runtime_pin' => @runtime_pin,
        'row_keys' => ROW_KEYS, 'mark_rows' => MARK_ROWS, 'count_wire_values' => COUNT_WIRES.map(&:to_s),
        'profiles' => @profiles.map do |profile|
          profile.merge('state_hex' => RecheckAggregateAvgW227.states(profile).map { |bytes| bytes.unpack1('H*') },
            'literal_rowbinary_hex' => RecheckAggregateAvgW227.rowbinary_rows(profile).map { |bytes| bytes.unpack1('H*') })
        end }
      matrix_path = File.join(@source_root, 'matrix.json')
      RecheckAggregateAvgW227.write_json(matrix_path, matrix)
      @source_matrix_sha = Digest::SHA256.file(matrix_path).hexdigest
      input = { 'format' => FORMAT_INPUT, 'capture_root' => @source_root, 'profiles' => @helper_inputs }
      input_path = File.join(@root, 'generated', 'helper-input.json')
      RecheckAggregateAvgW227.write_json(input_path, input)
      @helper_input_path = input_path
      @helper_input_sha = Digest::SHA256.file(input_path).hexdigest
    end

    def invoke_helper
      sha_before = Digest::SHA256.file(@helper).hexdigest
      RecheckAggregateAvgW227.require_true(sha_before == @expected_helper_sha && sha_before == @helper_sha_start,
        'prebuilt W227 helper changed before launch or differs from external pin')
      record = process(HELPER_LABEL, @root, nil, timeout: R::HELPER_TIMEOUT_SECONDS,
        argv: [@helper, @helper_input_path, File.join(@root, 'generated'), @source_root])
      @helper_sha_after = Digest::SHA256.file(@helper).hexdigest
      RecheckAggregateAvgW227.require_true(@helper_sha_after == @expected_helper_sha && @helper_sha_after == sha_before,
        'prebuilt W227 helper changed during execution')
      RecheckAggregateAvgW227.checked_success!(record, 'prebuilt Crystal avg helper')
      output = JSON.parse(record.fetch('stdout'))
      RecheckAggregateAvgW227.require_true(output.fetch('format') == FORMAT_HELPER &&
        output.fetch('profile_count') == @profiles.length &&
        output.fetch('profiles').map { |item| item.fetch('id') } == @profiles.map { |item| item.fetch('id') },
        'W227 helper output format/count/profile roster differs')
      RecheckAggregateAvgW227.write_json(File.join(@root, 'generated', 'helper-output.json'), output)
      RecheckAggregateAvgW227.write_json(File.join(@root, 'generated', 'helper-process.json'), RecheckAggregateAvgW227.clean_record(record))
      @helper_process = RecheckAggregateAvgW227.clean_record(record)
      @helper_profiles = output.fetch('profiles')
      @profiles.each_with_index { |profile, index| validate_helper_profile(profile, @helper_profiles.fetch(index), @helper_inputs.fetch(index)) }
      @helper_output = output
    rescue JSON::ParserError => error
      RecheckAggregateAvgW227.fail!("W227 helper stdout is not one JSON object: #{error.message}")
    end

    def validate_helper_side(side, observed, input, label)
      expected_states = input.fetch('state_hex')
      expected_keys = ROW_KEYS
      # The part persists column stream "v"; "root.data" below is its logical role.
      RecheckAggregateAvgW227.require_true(observed.fetch('grid') == {
        'row_count' => 5, 'mark_rows' => MARK_ROWS, 'mark_count' => 3, 'physical_stream_names' => ['v'] },
        "helper #{label} grid differs")
      states = expected_states.map { |hex| [hex].pack('H*').b }
      offsets = [0, states[0, 2].sum(&:bytesize), states[0, 4].sum(&:bytesize), states.sum(&:bytesize)]
      stream = observed.fetch('streams')
      expected_stream = [{ 'role' => 'root.data', 'byte_count' => states.sum(&:bytesize),
        'bytes_hex' => states.join.b.unpack1('H*'), 'mark_offsets' => offsets }]
      RecheckAggregateAvgW227.require_true(stream == expected_stream, "helper #{label} opaque stream bytes/marks differ")
      expected_windows = {
        'full' => { 'first_mark' => 0, 'mark_count' => 3, 'row_keys' => expected_keys, 'state_hex' => expected_states },
        'first_mark' => { 'first_mark' => 0, 'mark_count' => 1, 'row_keys' => expected_keys[0, 2], 'state_hex' => expected_states[0, 2] },
        'middle_mark' => { 'first_mark' => 1, 'mark_count' => 1, 'row_keys' => expected_keys[2, 2], 'state_hex' => expected_states[2, 2] },
        'final_short_mark' => { 'first_mark' => 2, 'mark_count' => 1, 'row_keys' => expected_keys[4, 1], 'state_hex' => expected_states[4, 1] },
        'eof_empty' => { 'first_mark' => 3, 'mark_count' => 0, 'row_keys' => [], 'state_hex' => [] },
      }
      RecheckAggregateAvgW227.require_true(observed.fetch('windows') == expected_windows, "helper #{label} mark windows differ")
    end

    def validate_helper_profile(profile, observed, input)
      expected_identity = { 'id' => input.fetch('id'), 'declared_type' => input.fetch('declared_type'),
        'argument_type' => input.fetch('argument_type'), 'library_part_path' => input.fetch('library_part'),
        'row_keys' => ROW_KEYS, 'mark_rows' => MARK_ROWS, 'exact_state_hex' => input.fetch('state_hex') }
      expected_identity.each do |key, value|
        RecheckAggregateAvgW227.require_true(observed.fetch(key) == value, "helper profile #{input.fetch('id')} #{key} differs")
      end
      %w[source library].each { |side| validate_helper_side(side, observed.fetch(side), input, "#{side}/#{input.fetch('id')}") }
      expected_values = ROW_KEYS.each_with_index.map do |key, index|
        { 'key' => key, 'type' => input.fetch('declared_type'), 'state_hex' => input.fetch('state_hex').fetch(index) }
      end
      RecheckAggregateAvgW227.require_true(observed.fetch('public_values') == { 'source' => expected_values, 'library' => expected_values },
        "helper public values differ for #{input.fetch('id')}")
      owned = input.fetch('state_hex').map { |state| { 'type' => input.fetch('declared_type'), 'state_hex' => state } }
      RecheckAggregateAvgW227.require_true(observed.fetch('owned_values') == { 'source' => owned, 'library' => owned },
        "helper owned values differ for #{input.fetch('id')}")
      library_path = input.fetch('library_part')
      RecheckAggregateAvgW227.require_true(File.directory?(library_path) && !File.symlink?(library_path) && File.realpath(library_path) == library_path,
        "helper library part is missing or redirected for #{input.fetch('id')}")
      RecheckAggregateAvgW227.require_true(inventory(input.fetch('source_part')) == @profiles.fetch(profile.fetch('ordinal')).fetch('source_inventory'),
        "helper modified stock source part for #{input.fetch('id')}")
      profile['library_part'] = library_path
      profile['library_inventory'] = inventory(library_path)
      RecheckAggregateAvgW227.write_json(File.join(@root, 'cases', "helper-#{input.fetch('id')}.json"),
        { 'id' => input.fetch('id'), 'input' => input, 'helper_profile' => observed,
          'source_inventory' => @profiles.fetch(profile.fetch('ordinal')).fetch('source_inventory'),
          'library_inventory' => profile.fetch('library_inventory') })
    end

    def native_create_all
      store = File.join(@root, 'stores', 'native')
      record = RecheckAggregateAvgW227.checked_success!(process('native-create-all', store,
        all_create_sql(@profiles, 'native')), 'native target CREATE all profiles')
      @native_create_process = RecheckAggregateAvgW227.clean_record(record)
    end

    def native_data_paths
      store = File.join(@root, 'stores', 'native')
      names = @profiles.map { |profile| "'#{RecheckAggregateAvgW227.native_table(profile)}'" }
      sql = "SELECT name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name IN (#{names.join(', ')}) ORDER BY name FORMAT TSVRaw"
      record = RecheckAggregateAvgW227.checked_success!(process('native-data-paths', store, sql), 'native data path census')
      rows = record.fetch('stdout').lines.map { |line| line.chomp.split("\t", -1) }
      RecheckAggregateAvgW227.require_true(rows.length == @profiles.length && rows.all? { |row| row.length == 2 },
        'native data path census row count/shape differs')
      mapping = rows.to_h
      @profiles.each do |profile|
        table = RecheckAggregateAvgW227.native_table(profile)
        path = File.expand_path(mapping.fetch(table))
        RecheckAggregateAvgW227.require_true(path.start_with?(store + File::SEPARATOR) && File.directory?(path) &&
          !File.symlink?(path) && File.realpath(path) == path,
          "native target path escaped its isolated store for #{profile.fetch('id')}")
        detached = File.join(path, 'detached')
        RecheckAggregateAvgW227.require_true(File.directory?(detached) && !File.symlink?(detached) && File.realpath(detached) == detached,
          "native detached directory is invalid for #{profile.fetch('id')}")
        profile['native_data_path'] = path
        profile['native_detached_path'] = File.join(detached, 'all_1_1_0')
        RecheckAggregateAvgW227.require_true(!File.exist?(profile.fetch('native_detached_path')),
          "native detached destination already exists for #{profile.fetch('id')}")
      end
      @native_paths_process = RecheckAggregateAvgW227.clean_record(record)
    end

    def copy_library_parts
      @profiles.each do |profile|
        source = profile.fetch('library_part')
        destination = profile.fetch('native_detached_path')
        FileUtils.cp_r(source, destination)
        RecheckAggregateAvgW227.require_true(inventory(source) == inventory(destination),
          "detached library part copy differs for #{profile.fetch('id')}")
      end
    end

    def native_capture_sql
      sql = []
      @profiles.each do |profile|
        id = profile.fetch('id')
        table = RecheckAggregateAvgW227.native_table(profile)
        sql << "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'"
        sql << "SELECT 'W227_CHECK_BEGIN_#{id}' FORMAT TSVRaw"
        sql << "CHECK TABLE default.#{table} FORMAT TSVRaw"
        sql << "SELECT 'W227_CHECK_END_#{id}' FORMAT TSVRaw"
        %w[full middle zero].each do |window|
          predicate = { 'full' => '', 'middle' => ' WHERE pk BETWEEN 22 AND 44', 'zero' => ' WHERE pk=0' }.fetch(window)
          path = RecheckAggregateAvgW227.rowbinary_path(@root, 'native', profile, window)
          sql << "SELECT pk, v FROM default.#{table}#{predicate} ORDER BY pk INTO OUTFILE '#{path}' FORMAT RowBinary"
        end
      end
      sql.join(";\n")
    end

    def compare_file_delta(generated, attached, id)
      before_entries = inventory(generated)
      after_entries = inventory(attached)
      before = before_entries.to_h { |entry| [entry.fetch('path'), entry] }
      after = after_entries.to_h { |entry| [entry.fetch('path'), entry] }
      removed = before.keys - after.keys
      changed = before.keys.select { |path| after.key?(path) && before.fetch(path) != after.fetch(path) }
      added = after.keys - before.keys
      RecheckAggregateAvgW227.require_true(removed.empty? && changed.empty? && added == [INVALIDATED_FILE],
        "ATTACH modified unexpected part files for #{id}: removed=#{removed.inspect}, changed=#{changed.inspect}, added=#{added.inspect}")
      aux = File.binread(File.join(attached, INVALIDATED_FILE)).split("\n", -1)
      RecheckAggregateAvgW227.require_true(aux.pop == '' && aux.sort == INVALIDATED_NAMES.sort,
        "ATTACH invalidated system-column sidecar differs for #{id}")
      { 'removed' => removed, 'changed' => changed, 'added' => added, 'attached_inventory' => after_entries }
    end

    def capture_native_profiles
      native_create_all
      native_data_paths
      copy_library_parts
      store = File.join(@root, 'stores', 'native')
      capture = RecheckAggregateAvgW227.checked_success!(process('native-attach-and-capture-all', store,
        native_capture_sql), 'native ATTACH/CHECK/RowBinary captures')
      expected_checks = @profiles.map do |profile|
        "W227_CHECK_BEGIN_#{profile.fetch('id')}\n#{CHECK_OUTPUT}W227_CHECK_END_#{profile.fetch('id')}\n"
      end.join
      RecheckAggregateAvgW227.require_true(capture.fetch('stdout') == expected_checks,
        'native raw CHECK result bits differ from one exact successful attached part per profile')
      @native_capture_process = RecheckAggregateAvgW227.clean_record(capture)
      inspect = RecheckAggregateAvgW227.checked_success!(process('native-inspect-all', store,
        RecheckAggregateAvgW227.inspect_sql(@profiles, 'native')), 'native attached metadata/part inspection')
      @native_inspect_process = RecheckAggregateAvgW227.clean_record(inspect)

      @profiles.each do |profile|
        id = profile.fetch('id')
        schema = section(inspect.fetch('stdout'), "W227_NATIVE_SCHEMA_BEGIN_#{id}", "W227_NATIVE_SCHEMA_END_#{id}", "native schema #{id}")
        type_name = section(inspect.fetch('stdout'), "W227_NATIVE_TYPE_BEGIN_#{id}", "W227_NATIVE_TYPE_END_#{id}", "native typeName #{id}")
        part_line = section(inspect.fetch('stdout'), "W227_NATIVE_PART_BEGIN_#{id}", "W227_NATIVE_PART_END_#{id}", "native part #{id}")
        RecheckAggregateAvgW227.require_true(schema == RecheckAggregateAvgW227.schema_output(profile), "native exact schema differs for #{id}")
        RecheckAggregateAvgW227.require_true(type_name == "#{profile.fetch('declared_type')}\n", "native toTypeName differs for #{id}")
        fields = part_line.chomp.split("\t", -1)
        RecheckAggregateAvgW227.require_true(fields.length == 5 && fields.first(4) == ['all_1_1_0', '5', '4', 'Wide'],
          "native attached part identity/grid differs for #{id}: #{fields.inspect}")
        attached = File.join(profile.fetch('native_data_path'), 'all_1_1_0')
        RecheckAggregateAvgW227.require_true(File.expand_path(fields.fetch(4)) == attached && File.directory?(attached) &&
          !File.symlink?(attached) && File.realpath(attached) == attached,
          "native attached part path differs for #{id}")
        delta = compare_file_delta(profile.fetch('library_part'), attached, id)
        expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`v` #{profile.fetch('declared_type')}\n"
        columns = File.binread(File.join(attached, 'columns.txt')).force_encoding(Encoding::UTF_8).scrub
        RecheckAggregateAvgW227.require_true(columns == expected_columns, "native columns.txt differs for #{id}")
        serialization = JSON.parse(File.binread(File.join(attached, 'serialization.json')))
        library_serialization = JSON.parse(File.binread(File.join(profile.fetch('library_part'), 'serialization.json')))
        RecheckAggregateAvgW227.require_true(serialization == library_serialization, "ATTACH changed serialization metadata for #{id}")
        RecheckAggregateAvgW227.require_true(File.binread(File.join(attached, 'metadata_version.txt')).strip == '0' &&
          File.binread(File.join(attached, 'default_compression_codec.txt')).strip == 'CODEC(LZ4)' &&
          File.binread(File.join(attached, 'count.txt')).strip == '5', "native attached metadata differs for #{id}")
        windows = {}
        %w[full middle zero].each do |window|
          path = RecheckAggregateAvgW227.rowbinary_path(@root, 'native', profile, window)
          actual = File.binread(path)
          expected = RecheckAggregateAvgW227.expected_windows(profile).fetch(window)
          RecheckAggregateAvgW227.require_true(actual == expected, "native #{window} RowBinary differs for #{id}")
          windows[window] = { 'path' => path, 'bytes' => actual.bytesize,
            'sha256' => Digest::SHA256.hexdigest(actual), 'literal_hex' => actual.unpack1('H*'),
            'matches_independent_literal' => true }
        end
        @native_profiles << { 'id' => id, 'declared_type' => profile.fetch('declared_type'),
          'native_schema' => schema, 'native_type_name' => type_name, 'check_output' => CHECK_OUTPUT,
          'native_data_path' => profile.fetch('native_data_path'), 'attached_part_path' => attached,
          'columns_txt' => columns, 'serialization_json' => serialization,
          'library_inventory' => inventory(profile.fetch('library_part')),
          'attached_inventory' => delta.fetch('attached_inventory'), 'file_delta' => delta,
          'rowbinary_windows' => windows }
      end
      native_matrix = { 'format' => FORMAT_NATIVE, 'profile_count' => @profiles.length,
        'profiles' => @native_profiles, 'processes' => {
          'create' => @native_create_process, 'data_paths' => @native_paths_process,
          'attach_capture' => @native_capture_process, 'inspect' => @native_inspect_process } }
      native_path = File.join(@root, 'cases', 'native-matrix.json')
      RecheckAggregateAvgW227.write_json(native_path, native_matrix)
      @native_matrix_sha = Digest::SHA256.file(native_path).hexdigest
    rescue JSON::ParserError => error
      RecheckAggregateAvgW227.fail!("native serialization metadata invalid: #{error.message}")
    end

    def verify_invocations
      labels = @recorder.records.map { |record| record.fetch('label') }
      expected = RecheckAggregateAvgW227.invocations_expected(@profiles)
      RecheckAggregateAvgW227.require_true(labels.uniq.length == labels.length && labels.sort == expected.sort,
        'exact W227 raw process invocation roster differs')
      expected_failures = %w[constructor-invalid-enum8 constructor-invalid-enum16]
      @recorder.records.each do |record|
        next if expected_failures.include?(record.fetch('label'))
        RecheckAggregateAvgW227.require_true(record.fetch('classification') == 'process_success' && record.fetch('exitstatus') == 0 &&
          !record.fetch('signaled') && !record.fetch('timed_out') && !record.fetch('spawn_error'),
          "W227 process failed: #{record.fetch('label')}")
      end
    end

    def write_summary(classification)
      path = File.join(@root || '', 'summary.json')
      return unless @root && File.directory?(@root) && !File.exist?(path)
      records = @recorder ? @recorder.records : []
      summary = { 'format' => FORMAT_SUMMARY, 'classification' => classification,
        'success' => classification == 'paired_aggregate_avg_profiles_observed', 'error' => @fatal,
        'source_root' => @source_root, 'evidence_root' => @root,
        'source_pin' => @source_pin, 'runtime_pin' => @runtime_pin,
        'profile_count_expected' => PROFILE_COUNT, 'base_source_valid_count' => BASE_PROFILE_COUNT,
        'metadata_witness_count' => PROFILE_COUNT - BASE_PROFILE_COUNT,
        'stock_profile_count' => @source_profiles.length, 'helper_profile_count' => @helper_profiles.length,
        'native_profile_count' => @native_profiles.length,
        'construction_count' => @construction_records.empty? ? 0 : @construction_records.first.fetch('profile_count', 0),
        'computed_probe_count' => @computed_records.length,
        'helper_sha256_expected' => @expected_helper_sha, 'helper_sha256_at_start' => @helper_sha_start,
        'helper_sha256_after_execute' => @helper_sha_after, 'helper_input_sha256' => @helper_input_sha,
        'source_matrix_sha256' => @source_matrix_sha, 'native_matrix_sha256' => @native_matrix_sha,
        'process_count' => records.length,
        'process_status_counts' => { 'success_exit0' => records.count { |item| item.fetch('classification') == 'process_success' },
          'nonzero_or_signaled' => records.count { |item| item.fetch('classification') == 'process_nonzero_or_signaled_exit' },
          'timeout' => records.count { |item| item.fetch('classification') == 'process_timeout' },
          'spawn_failure' => records.count { |item| item.fetch('classification') == 'spawn_failure' } } }
      RecheckAggregateAvgW227.write_json(path, summary)
      RecheckAggregateAvgW227.write_json(File.join(@source_root, 'source_pin.json'), @source_pin) if @source_pin && !File.exist?(File.join(@source_root, 'source_pin.json'))
      RecheckAggregateAvgW227.write_json(File.join(@source_root, 'runtime_pin.json'), @runtime_pin) if @runtime_pin && !File.exist?(File.join(@source_root, 'runtime_pin.json'))
    end
  end

  def main(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/recheck_aggregate_avg_w227.rb --clickhouse BIN --helper HELPER --helper-sha256 HEX --source-root EMPTY_DIR --evidence-root EMPTY_DIR'
      opts.on('--clickhouse PATH') { |value| options[:clickhouse] = value }
      opts.on('--helper PATH') { |value| options[:helper] = value }
      opts.on('--helper-sha256 HEX') { |value| options[:helper_sha256] = value }
      opts.on('--source-root PATH') { |value| options[:source_root] = value }
      opts.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
    end
    parser.parse!(argv)
    require_true(argv.empty? && %i[clickhouse helper helper_sha256 source_root evidence_root].all? { |key| options.key?(key) }, parser.to_s)
    Probe.new(options).run
  rescue StandardError => error
    warn "W227 runner setup failure: #{error.class}: #{error.message}"
    false
  end
end

exit(RecheckAggregateAvgW227.main(ARGV) ? 0 : 1) if $PROGRAM_NAME == __FILE__
