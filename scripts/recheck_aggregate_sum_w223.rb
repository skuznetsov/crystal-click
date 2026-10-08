#!/usr/bin/env ruby
# Bounded stock-Wide and Crystal generic bulk qualification for W223.
# This runner consumes a separately prebuilt Crystal helper; it does not build
# ClickHouse or compile Crystal.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'optparse'

module RecheckAggregateSumW223
  extend self

  VERSION = '26.10.1.1201'.freeze
  BUILD_HASH = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  CLICKHOUSE_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  SOURCE_ROOT = '/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1'.freeze
  SOURCE_REVISION = '0ca8150d9b1d0886edb2e3b4ab65eebb768d0357'.freeze
  SOURCE_PREFIX = '/private/tmp/crystal-click-w223-physical.'.freeze
  EVIDENCE_PREFIX = '/private/tmp/crystal-click-w223-bulk.'.freeze
  FORMAT_SOURCE = 'aggregate_sum_physical_w223_matrix_v1'.freeze
  FORMAT_INPUT = 'aggregate_sum_w223_input_v1'.freeze
  FORMAT_HELPER = 'aggregate_sum_w223_helper_v1'.freeze
  PROCESS_TIMEOUT_SECONDS = 90
  HELPER_TIMEOUT_SECONDS = 600
  TERM_GRACE_SECONDS = 2
  MEMORY_LIMIT_BYTES = 1_073_741_824
  ROW_KEYS = [11, 22, 33, 44, 55].freeze
  MARK_ROWS = [2, 2, 1].freeze
  INVALIDATED_FILE = 'invalidated_system_columns.txt'.freeze
  INVALIDATED_NAMES = %w[_block_number _block_offset].freeze
  ATTACHMENT_SOURCE_BASIS = 'pinned-runtime ATTACH inventory observation; source implementation is not asserted as proof'.freeze
  ATTACHMENT_SOURCE_PATH_SCOPE = "#{SOURCE_ROOT}@#{SOURCE_REVISION}:src/Storages/MergeTree/MergeTreeData.cpp#loadPartAndFixMetadataImpl (context only; not hash-pinned)".freeze

  SOURCE_HASHES = {
    'src/AggregateFunctions/AggregateFunctionSum.cpp' => 'db1bb5a1501bf31bad3f6b48b0942762062733241cd2ba33abb9a43e76d272a6',
    'src/AggregateFunctions/AggregateFunctionSum.h' => '1ced4e3ee877780fd5b5c3547bd6bdd4f4e8c09559702e91838b15871bb9a94d',
    'src/AggregateFunctions/Helpers.h' => '1ef65dadd04fcf968998f35db36f300877550d7732c88d25b8e0fe8109857892',
    'src/DataTypes/DataTypeDomainBool.cpp' => '3de0e1b9e943e381270216d676c46ab8a5cf19bd70f7c41b52831ef0fa9a8d68',
    'src/DataTypes/DataTypeNumberBase.h' => '277d1f9233b3ec0c58a02f8865b28f75320dc09587fe303a0425be47297d54e0',
    'src/DataTypes/DataTypeInterval.h' => '5ad4cc9f20ea828d13f531f25a6d4cfacc8669ea54e26bc1f4fd06d866d6d8a7',
  }.freeze

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

  NUMERIC_TYPES = %w[
    UInt8 UInt16 UInt32 UInt64 UInt128 UInt256
    Int8 Int16 Int32 Int64 Int128 Int256
    Float32 Float64 BFloat16
  ].freeze
  INTERVAL_TYPES = %w[
    IntervalNanosecond IntervalMicrosecond IntervalMillisecond
    IntervalSecond IntervalMinute IntervalHour IntervalDay IntervalWeek
    IntervalMonth IntervalQuarter IntervalYear
  ].freeze
  BASE_TYPES = (
    NUMERIC_TYPES + ['Bool', "Enum8('zero' = 0, 'one' = 1)", "Enum16('zero' = 0, 'one' = 1)"] +
    ['Decimal(9, 2)', 'Decimal(18, 4)', 'Decimal(38, 8)', 'Decimal(76, 12)'] + INTERVAL_TYPES
  ).freeze

  def profile(id, function, argument, kind: nil, canonical: nil, storage_width: nil)
    actual_kind = kind || (function == 'count' ? 'count' : 'sum')
    actual_canonical = canonical || (function == 'sumKahan' && argument.match?(/\A(?:Decimal|Interval)/) ? 'sum' : function)
    actual_argument = actual_kind == 'count' ? nil : argument
    actual_type = actual_kind == 'count' ? 'AggregateFunction(count)' :
      "AggregateFunction(#{actual_canonical}, #{argument})"
    {
      'id' => id, 'kind' => actual_kind, 'source_function' => function,
      'canonical_function' => actual_canonical, 'argument_type' => actual_argument,
      'declared_type' => actual_type,
      'source_type' => actual_type,
    }
  end

  def fail!(message)
    raise ArgumentError, message
  end

  def safe_label(value)
    value.gsub(/[^A-Za-z0-9_.-]/, '_').downcase
  end

  def stock_process_labels(id)
    %W[stock-create-#{id} stock-rowbinary-insert-#{id} stock-schema-#{id} stock-type-name-#{id}
      stock-state-hex-#{id} stock-table-path-#{id} stock-part-census-#{id}
      stock-rowbinary-#{id}-full stock-rowbinary-#{id}-middle stock-rowbinary-#{id}-empty]
  end

  def expected_profiles
    rows = []
    [
      ['sum_uint8', 'sum', 'UInt8'], ['sum_uint64', 'sum', 'UInt64'],
      ['sum_int16', 'sum', 'Int16'], ['sum_int128', 'sum', 'Int128'],
      ['sum_uint256', 'sum', 'UInt256'], ['sum_float32', 'sum', 'Float32'],
      ['sum_float64', 'sum', 'Float64'], ['sum_bfloat16', 'sum', 'BFloat16'],
      ['sum_bool', 'sum', 'Bool'],
      ['sum_enum8', 'sum', "Enum8('zero' = 0, 'one' = 1)"],
      ['sum_enum16', 'sum', "Enum16('zero' = 0, 'one' = 1)"],
      ['sum_decimal32', 'sum', 'Decimal(9, 2)'],
      ['sum_decimal64', 'sum', 'Decimal(18, 4)'],
      ['sum_decimal128', 'sum', 'Decimal(38, 8)'],
      ['sum_decimal256', 'sum', 'Decimal(76, 12)'],
      ['sum_interval_nanosecond', 'sum', 'IntervalNanosecond'],
      ['sum_interval_day', 'sum', 'IntervalDay'], ['sum_interval_year', 'sum', 'IntervalYear'],
      ['overflow_uint8', 'sumWithOverflow', 'UInt8'],
      ['overflow_uint128', 'sumWithOverflow', 'UInt128'],
      ['overflow_uint256', 'sumWithOverflow', 'UInt256'],
      ['overflow_bool', 'sumWithOverflow', 'Bool'],
      ['overflow_enum8', 'sumWithOverflow', "Enum8('zero' = 0, 'one' = 1)"],
      ['overflow_decimal32', 'sumWithOverflow', 'Decimal(9, 2)'],
      ['overflow_interval_day', 'sumWithOverflow', 'IntervalDay'],
      ['kahan_float32', 'sumKahan', 'Float32'], ['kahan_float64', 'sumKahan', 'Float64'],
      ['kahan_bfloat16', 'sumKahan', 'BFloat16'], ['kahan_bool', 'sumKahan', 'Bool'],
      ['kahan_enum8', 'sumKahan', "Enum8('zero' = 0, 'one' = 1)"],
      ['kahan_decimal64', 'sumKahan', 'Decimal(18, 4)', 'sum'],
      ['kahan_interval_day', 'sumKahan', 'IntervalDay', 'sum'],
      ['sum_nullable_uint64', 'sum', 'Nullable(UInt64)'],
      ['sum_nullable_decimal64', 'sum', 'Nullable(Decimal(18, 4))'],
      ['sum_nullable_enum8', 'sum', "Nullable(Enum8('zero' = 0, 'one' = 1))"],
      ['sum_lc_uint8', 'sum', 'LowCardinality(UInt8)'],
      ['sum_lc_nullable_uint8', 'sum', 'LowCardinality(Nullable(UInt8))'],
      ['sum_lc_interval_day', 'sum', 'LowCardinality(IntervalDay)'],
      ['sum_lc_nullable_interval_day', 'sum', 'LowCardinality(Nullable(IntervalDay))'],
      ['overflow_nullable_bool', 'sumWithOverflow', 'Nullable(Bool)'],
      ['kahan_nullable_float64', 'sumKahan', 'Nullable(Float64)'],
      ['kahan_lc_nullable_float32', 'sumKahan', 'LowCardinality(Nullable(Float32))'],
    ].each do |id, function, argument, canonical|
      rows << profile(id, function, argument, canonical: canonical)
    end
    rows << profile('count_compatibility', 'count', nil, kind: 'count', canonical: 'count')
    fail!('W223 physical profile roster must be exact and bounded') unless rows.length == 43 && rows.map { |row| row.fetch('id') }.uniq.length == rows.length
    rows.freeze
  end

  def expected_construction_profiles
    rows = []
    BASE_TYPES.each do |argument|
      label = safe_label(argument)
      rows << profile("construct_sum_#{label}", 'sum', argument)
      rows << profile("construct_overflow_#{label}", 'sumWithOverflow', argument)
    end
    [
      ['construct_kahan_float32', 'Float32'], ['construct_kahan_float64', 'Float64'],
      ['construct_kahan_bfloat16', 'BFloat16'], ['construct_kahan_uint8', 'UInt8'],
      ['construct_kahan_uint256', 'UInt256'], ['construct_kahan_bool', 'Bool'],
      ['construct_kahan_enum8', "Enum8('zero' = 0, 'one' = 1)"],
      ['construct_kahan_decimal32', 'Decimal(9, 2)'],
      ['construct_kahan_decimal256', 'Decimal(76, 12)'],
      ['construct_kahan_interval_nano', 'IntervalNanosecond'],
      ['construct_kahan_interval_year', 'IntervalYear'],
      ['construct_kahan_nullable_float64', 'Nullable(Float64)'],
    ].each do |id, argument|
      rows << profile(id, 'sumKahan', argument)
    end
    rows.each do |row|
      argument = row.fetch('argument_type')
      row['input_type'] = "AggregateFunction(#{row.fetch('source_function')}, #{argument})"
      row['construction_expectation'] = 'strict_stock_positive; refusal is a probe mismatch'
    end
    fail!('W223 construction census roster must be exact and bounded') unless
      rows.length == 78 && rows.map { |row| row.fetch('id') }.uniq.length == rows.length && BASE_TYPES.length == 33
    rows.freeze
  end

  class Probe
    def initialize(options)
      @binary = validate_executable(options.fetch(:clickhouse), 'ClickHouse')
      @helper = validate_executable(options.fetch(:crystal_helper), 'prebuilt Crystal helper')
      @source_root = validate_fresh_root(options.fetch(:source_root), SOURCE_PREFIX, 'source')
      @root = validate_fresh_root(options.fetch(:evidence_root), EVIDENCE_PREFIX, 'evidence')
      @profiles = RecheckAggregateSumW223.expected_profiles.map { |row| row.dup }
      @invocations = []
      @records = []
      @helper_records = []
      @helper_profiles = []
      @construction_profiles = RecheckAggregateSumW223.expected_construction_profiles.map { |row| row.dup }
      @construction_records = []
      @fatal = nil
      @sequence = 0
      @clickhouse_pin = nil
      @helper_sha = nil
      @source_hashes = {}
      @recorder = Recorder.new(self)
    end

    attr_reader :root, :source_root, :binary, :helper, :profiles, :recorder

    def run
      prepare_layout!
      pin_source!
      pin_executables!
      capture_construction_census!
      capture_stock_profiles!
      write_source_matrix!
      write_manifest!
      invoke_helper!
      create_native_targets!
      attach_and_verify_all!
      verify_pins!
      write_summary('paired_sum_family_bulk_observed')
      puts "W223 Sum-family paired bulk matrix profiles=#{@profiles.length}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal ||= "#{error.class}: #{error.message}"
      write_summary('runner_failure_or_observations_differ') rescue nil
      warn "W223 paired probe failure (not a type-law refusal): #{@fatal}"
      false
    end

    def write_new(path, bytes)
      File.open(path, 'wbx', 0o600) { |file| file.write(bytes) }
    rescue Errno::EEXIST
      fail!("refusing to overwrite W223 evidence: #{path}")
    end

    def write_json(path, object)
      write_new(path, JSON.pretty_generate(object) + "\n")
    end

    def fail!(message)
      raise ArgumentError, message
    end

    def safe_label(value)
      value.gsub(/[^A-Za-z0-9_.-]/, '_')
    end

    private

    def validate_executable(path, label)
      fail!("#{label} path is required") unless path && !path.empty?
      full = File.expand_path(path)
      fail!("#{label} is absent, non-executable, or symlinked: #{full}") unless
        File.file?(full) && File.executable?(full) && !File.symlink?(full) && File.realpath(full) == full
      full
    end

    def validate_fresh_root(path, prefix, label)
      full = File.expand_path(path)
      fail!("#{label} root must be direct child of /private/tmp") unless File.dirname(full) == File.realpath('/private/tmp')
      fail!("#{label} root must be existing, canonical, empty, and nonsymlinked") unless
        File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full && Dir.children(full).empty?
      fail!("#{label} root does not use exact fixed prefix") unless full.start_with?(prefix)
      full
    rescue Errno::ENOENT
      fail!("#{label} root is absent")
    end

    def prepare_layout!
      %w[invocations stores parts cases generated construction].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      %w[invocations stores parts cases evidence construction].each { |name| Dir.mkdir(File.join(@source_root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'generated', 'parts'), 0o700)
      Dir.mkdir(File.join(@root, 'cases', 'profiles'), 0o700)
      Dir.mkdir(File.join(@root, 'cases', 'construction'), 0o700)
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
      Dir.mkdir(File.join(@source_root, 'cases', 'profiles'), 0o700)
      Dir.mkdir(File.join(@source_root, 'construction', 'stores'), 0o700)
      Dir.mkdir(File.join(@source_root, 'construction', 'cases'), 0o700)
    end

    def pin_source!
      fail!('pinned source root is absent or noncanonical') unless File.directory?(SOURCE_ROOT) && File.realpath(SOURCE_ROOT) == SOURCE_ROOT
      SOURCE_HASHES.each do |relative, expected|
        path = File.join(SOURCE_ROOT, relative)
        actual = Digest::SHA256.file(path).hexdigest
        fail!("pinned CH source anchor differs: #{relative}") unless actual == expected
        @source_hashes[relative] = {'sha256' => actual, 'expected_sha256' => expected}
      end
    end

    def pin_executables!
      sha = Digest::SHA256.file(@binary).hexdigest
      fail!('ClickHouse executable SHA differs from the independently pinned runtime') unless sha == CLICKHOUSE_SHA256
      version = @recorder.run_clickhouse('runtime-version', File.join(@root, 'stores', 'native'), 'SELECT version() FORMAT TSVRaw')
      assert_success!(version, 'runtime version')
      fail!('ClickHouse version differs from the fixed runtime pin') unless version.fetch(:stdout).strip == VERSION
      build = @recorder.run_clickhouse('runtime-build', File.join(@root, 'stores', 'native'),
        "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw")
      assert_success!(build, 'runtime build')
      fail!('ClickHouse build hash differs from fixed runtime pin') unless build.fetch(:stdout).strip == "VERSION_GITHASH=#{BUILD_HASH}"
      @clickhouse_pin = {'path' => @binary, 'version' => VERSION, 'build_hash' => BUILD_HASH, 'sha256' => sha}
      @helper_sha = Digest::SHA256.file(@helper).hexdigest
      write_json(File.join(@root, 'runtime_pin.json'), {
        'runtime' => @clickhouse_pin,
        'prebuilt_helper' => {'path' => @helper, 'sha256' => @helper_sha, 'compiled_by_this_runner' => false},
        'source_comparison_pin' => "#{SOURCE_ROOT}@#{SOURCE_REVISION}",
        'runtime_source_correlation' => 'not_asserted',
        'source_hashes' => @source_hashes,
      })
    end

    def verify_pins!
      fail!('ClickHouse executable changed during qualification') unless Digest::SHA256.file(@binary).hexdigest == CLICKHOUSE_SHA256
      fail!('prebuilt helper changed during qualification') unless Digest::SHA256.file(@helper).hexdigest == @helper_sha
      pin_source!
    end

    def assert_success!(result, label)
      status = result.fetch(:status)
      fail!("#{label} failed (probe failure, not a law refusal): #{status.inspect}") unless
        status.fetch('success') && status.fetch('exitstatus') == 0 && !status.fetch('timed_out') &&
        !status.fetch('signaled') && status['spawn_error'].nil? && status.fetch('reported_clickhouse_codes', []).empty?
    end

    def write_source_new(path, bytes)
      File.open(path, 'wbx', 0o600) { |file| file.write(bytes) }
    rescue Errno::EEXIST
      fail!("refusing to overwrite W223 stock evidence: #{path}")
    end

    def write_source_json(path, object)
      write_source_new(path, JSON.pretty_generate(object) + "\n")
    end

    def unwrap_argument(argument)
      current = argument
      loop do
        match = /\A(?:LowCardinality|Nullable)\((.*)\)\z/.match(current)
        break unless match
        current = match[1]
      end
      current
    end

    def little_endian(value, width)
      remaining = value
      Array.new(width) do
        byte = remaining & 0xff
        remaining >>= 8
        byte
      end.pack('C*').b
    end

    def varuint(value)
      output = +''.b
      remaining = value
      while remaining >= 0x80
        output << ((remaining & 0x7f) | 0x80)
        remaining >>= 7
      end
      output << remaining
    end

    def decimal_storage_width(type)
      precision = decimal_precision(type)
      return 4 if precision <= 9
      return 8 if precision <= 18
      return 16 if precision <= 38
      32
    end

    def decimal_precision(type)
      match = /\ADecimal\((\d+),/.match(type)
      fail!("invalid Decimal type in independent oracle: #{type}") unless match
      Integer(match[1], 10)
    end

    def state_width(profile)
      return nil if profile.fetch('kind') == 'count'
      function = profile.fetch('source_function')
      argument = unwrap_argument(profile.fetch('argument_type'))
      return 16 if function == 'sumKahan' && profile.fetch('canonical_function') == 'sumKahan'
      if function == 'sumWithOverflow'
        return 1 if argument == 'Bool' || argument.start_with?('Enum8(')
        return 2 if argument.start_with?('Enum16(') || argument == 'BFloat16'
        return 4 if argument == 'Float32'
        return 8 if argument == 'Float64'
        return decimal_storage_width(argument) if argument.start_with?('Decimal(')
        if (overflow_match = /\A(?:U?Int)(8|16|32|64|128|256)\z/.match(argument))
          return overflow_match[1].to_i / 8
        end
      end
      return 8 if argument.start_with?('Interval')
      if argument.start_with?('Decimal(')
        precision = decimal_precision(argument)
        return precision > 38 ? 32 : 16
      end
      return 8 if argument == 'Bool' || argument.start_with?('Enum8(', 'Enum16(', 'Float', 'BFloat16')
      if (match = /\A(?:U?Int)(8|16|32|64|128|256)\z/.match(argument))
        bits = match[1].to_i
        return bits <= 64 ? 8 : bits / 8
      end
      return 8 if argument.start_with?('Interval')
      fail!("no independent W223 state-width law for #{profile.fetch('id')}/#{argument}")
    end

    def state_bytes(profile, index)
      return varuint([0, 127, 128, 16_384, 18_446_744_073_709_551_615][index]) if profile.fetch('kind') == 'count'
      argument = profile.fetch('argument_type')
      base = unwrap_argument(argument)
      if argument.include?('Nullable(') && index == 2
        return "\x00".b
      end
      if profile.fetch('source_function') == 'sumKahan' && profile.fetch('canonical_function') == 'sumKahan'
        sums = [1.5, 2.5, 3.25, 4.5, 5.75]
        compensations = [0.25, -0.125, 0.5, -0.25, 0.125]
        state = [sums[index]].pack('E') + [compensations[index]].pack('E')
        return argument.include?('Nullable(') ? "\x01".b + state : state
      end
      width = state_width(profile)
      value = index + 1
      if profile.fetch('source_function') == 'sumWithOverflow' && base == 'Float32'
        state = [value.to_f].pack('e')
      elsif profile.fetch('source_function') == 'sumWithOverflow' && base == 'Float64'
        state = [value.to_f].pack('E')
      elsif profile.fetch('source_function') == 'sumWithOverflow' && base == 'BFloat16'
        state = [value.to_f].pack('e').byteslice(2, 2)
      elsif base.start_with?('Float', 'BFloat16')
        state = [value.to_f].pack('E')
      else
        multiplier = base.start_with?('Decimal(') ? 100 : 1
        state = little_endian(value * multiplier, width)
      end
      argument.include?('Nullable(') ? "\x01".b + state : state
    end

    def state_hexes(profile)
      (0...5).map { |index| state_bytes(profile, index).unpack1('H*') }
    end

    def rowbinary(profile, indices)
      indices.map { |index| [ROW_KEYS.fetch(index)].pack('Q<') + state_bytes(profile, index) }.join.b
    end

    def table_name(profile)
      "w223_#{safe_label(profile.fetch('id'))}"
    end

    def create_sql(profile, table)
      settings = STOCK_SETTINGS.dup
      settings << 'allow_suspicious_low_cardinality_types=1'
      "CREATE TABLE default.#{table} (pk UInt64, v #{profile.fetch('declared_type')}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings.join(', ')}"
    end

    def source_case_dir(profile)
      path = File.join(@source_root, 'cases', 'profiles', safe_label(profile.fetch('id')))
      Dir.mkdir(path, 0o700)
      path
    end

    def capture_stock_profile!(profile, index)
      id = profile.fetch('id')
      table = table_name(profile)
      case_dir = source_case_dir(profile)
      store = File.join(@source_root, 'stores', safe_label(id))
      Dir.mkdir(store, 0o700)
      create = @recorder.run_clickhouse("stock-create-#{id}", store, create_sql(profile, table), multiquery: false)
      assert_success!(create, "stock CREATE #{id}")

      bytes = ROW_KEYS.each_with_index.map { |key, row| [key].pack('Q<') + state_bytes(profile, row) }.join.b
      insert = @recorder.run_clickhouse("stock-rowbinary-insert-#{id}", store,
        "INSERT INTO default.#{table} FORMAT RowBinary", input: bytes)
      assert_success!(insert, "stock RowBinary INSERT #{id}")

      schema = @recorder.run_clickhouse("stock-schema-#{id}", store,
        "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
      assert_success!(schema, "stock schema census #{id}")
      schema_rows = schema.fetch(:stdout).force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp)
      expected_schema = ["pk\tUInt64", "v\t#{profile.fetch('declared_type')}"]
      fail!("stock exact nominal schema differs for #{id}: #{schema_rows.inspect}") unless schema_rows == expected_schema

      typed = @recorder.run_clickhouse("stock-type-name-#{id}", store,
        "SELECT toTypeName(v) FROM default.#{table} LIMIT 1 FORMAT TSVRaw")
      assert_success!(typed, "stock type name #{id}")
      fail!("stock toTypeName differs for #{id}") unless typed.fetch(:stdout).strip == profile.fetch('declared_type')

      hex = @recorder.run_clickhouse("stock-state-hex-#{id}", store,
        "SELECT hex(v) FROM default.#{table} ORDER BY pk FORMAT TSVRaw")
      assert_success!(hex, "stock raw state hex #{id}")
      observed_hexes = hex.fetch(:stdout).force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp).map(&:downcase)
      expected_hexes = state_hexes(profile)
      fail!("stock raw aggregate state bytes differ from independent literal for #{id}") unless observed_hexes == expected_hexes

      table_path_result = @recorder.run_clickhouse("stock-table-path-#{id}", store,
        "SELECT arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw")
      assert_success!(table_path_result, "stock data path #{id}")
      data_path = table_path_result.fetch(:stdout).strip
      fail!("stock table path is empty for #{id}") if data_path.empty?
      data_path = File.expand_path(data_path)
      fail!("stock table data path is outside its exact store for #{id}") unless data_path.start_with?(store + File::SEPARATOR)

      part_result = @recorder.run_clickhouse("stock-part-census-#{id}", store,
        "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw")
      assert_success!(part_result, "stock part census #{id}")
      part_rows = part_result.fetch(:stdout).force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp)
      fail!("stock part census must have one native row for #{id}: #{part_rows.inspect}") unless part_rows.length == 1
      fields = part_rows.first.split("\t", -1)
      fail!("stock part identity/grid differs for #{id}: #{fields.inspect}") unless
        fields.length == 5 && fields[0] == 'all_1_1_0' && fields[1] == '5' && fields[2] == '4' && fields[3] == 'Wide'
      original_part = File.expand_path(fields[4])
      fail!("stock part path is not exact data-path child for #{id}") unless original_part == File.join(data_path, 'all_1_1_0')
      fail!("stock native part is missing, symlinked, or noncanonical for #{id}") unless
        File.directory?(original_part) && !File.symlink?(original_part) && File.realpath(original_part) == original_part

      copied_part = File.join(@source_root, 'parts', safe_label(id), 'all_1_1_0')
      FileUtils.mkdir_p(File.dirname(copied_part), mode: 0o700)
      fail!("stock copy destination already exists for #{id}") if File.exist?(copied_part) || File.symlink?(copied_part)
      FileUtils.cp_r(original_part, copied_part)
      original_inventory = inventory(original_part, "stock original #{id}")
      copied_inventory = inventory(copied_part, "stock copy #{id}")
      fail!("copied stock part differs from original inventory for #{id}") unless copied_inventory == original_inventory

      rowbinary_windows = {}
      {'full' => "(SELECT 1)", 'middle' => 'pk BETWEEN 22 AND 44', 'empty' => 'pk = 0'}.each do |window, predicate|
        where = window == 'full' ? '' : " WHERE #{predicate}"
        query = @recorder.run_clickhouse("stock-rowbinary-#{id}-#{window}", store,
          "SELECT pk, v FROM default.#{table}#{where} ORDER BY pk FORMAT RowBinary")
        assert_success!(query, "stock #{window} RowBinary #{id}")
        indices = window == 'full' ? [0, 1, 2, 3, 4] : (window == 'middle' ? [1, 2, 3] : [])
        expected = rowbinary(profile, indices)
        fail!("stock #{window} RowBinary differs from independent bytes for #{id}") unless query.fetch(:stdout).b == expected
        relative = "cases/profiles/#{safe_label(id)}/#{window}.rowbinary"
        evidence_path = File.join(@source_root, relative)
        write_source_new(evidence_path, query.fetch(:stdout).b)
        rowbinary_windows[window] = {'path' => relative, 'absolute_path' => evidence_path,
          'bytes' => expected.bytesize, 'sha256' => Digest::SHA256.hexdigest(expected),
          'matches_independent_literal' => true}
      end

      serialization_text = File.binread(File.join(copied_part, 'serialization.json'))
      serialization = JSON.parse(serialization_text)
      fail!("stock serialization metadata law differs for #{id}") unless
        serialization == {
          'columns' => [], 'propagate_types_serialization_versions_to_nested_types' => true,
          'types_serialization_versions' => {'string' => 1}, 'version' => 1,
        }
      metadata_version = File.binread(File.join(copied_part, 'metadata_version.txt')).strip
      fail!("stock metadata version is not zero for #{id}") unless metadata_version == '0'
      fail!("stock compression codec is not LZ4 for #{id}") unless
        File.binread(File.join(copied_part, 'default_compression_codec.txt')).strip == 'CODEC(LZ4)'

      profile.merge!({
        'row_keys' => ROW_KEYS, 'mark_rows' => MARK_ROWS, 'classification' => 'stock_physical_observed',
        'construction_expectation' => 'strict_stock_positive; refusal is a probe mismatch',
        'literal_state_hex' => expected_hexes,
        'physical' => {
          'source_part_path' => copied_part, 'original_part_path' => original_part,
          'part_file_inventory' => copied_inventory, 'original_part_file_inventory' => original_inventory,
          'rowbinary' => rowbinary_windows, 'serialization_json' => serialization,
          'metadata_version_txt' => metadata_version, 'rows' => 5, 'marks_with_terminal' => 4,
          'real_mark_rows' => MARK_ROWS, 'part_type' => fields[3], 'native_part_name' => fields[0],
          'to_type_name' => typed.fetch(:stdout).strip, 'observed_state_hex' => observed_hexes,
        },
      })
      @records << {'id' => id, 'classification' => 'stock_physical_observed',
        'declared_type' => profile.fetch('declared_type'), 'source_function' => profile.fetch('source_function'),
        'canonical_function' => profile.fetch('canonical_function'), 'physical' => profile.fetch('physical')}
      stock_labels = RecheckAggregateSumW223.stock_process_labels(id)
      stock_processes = @invocations.select { |item| stock_labels.include?(item.fetch('label')) }
      fail!("stock profile process roster differs for #{id}") unless
        stock_processes.map { |item| item.fetch('label') }.sort == stock_labels.sort
      write_json(File.join(@root, 'cases', 'profiles', "#{safe_label(id)}-stock.json"), {
        'id' => id, 'schema' => schema_rows, 'state_hex' => observed_hexes, 'rowbinary' => rowbinary_windows,
        'source_part_path' => copied_part, 'original_part_path' => original_part,
        'source_inventory' => copied_inventory,
        'processes' => stock_processes,
      })
    rescue JSON::ParserError => error
      fail!("invalid stock metadata JSON for #{profile.fetch('id')}: #{error.message}")
    end

    def capture_stock_profiles!
      @profiles.each_with_index { |profile, index| capture_stock_profile!(profile, index) }
    end

    def capture_construction_profile!(profile)
      id = profile.fetch('id')
      table = "w223_construct_#{safe_label(id)}"
      store = File.join(@source_root, 'construction', 'stores', safe_label(id))
      Dir.mkdir(store, 0o700)
      create_sql = "CREATE TABLE default.#{table} (v #{profile.fetch('input_type')}) ENGINE=Memory; " \
        "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw"
      schema = @recorder.run_clickhouse("construction-create-and-schema-#{id}", store, create_sql, multiquery: true)
      assert_success!(schema, "strict stock AggregateFunction construction/schema #{id}")
      observed = schema.fetch(:stdout).force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp)
      expected = ["v\t#{profile.fetch('declared_type')}"]
      fail!("stock construction canonical descriptor differs for #{id}: #{observed.inspect}") unless observed == expected
      invocation_label = "construction-create-and-schema-#{id}"
      construction_processes = @invocations.select { |item| item.fetch('label') == invocation_label }
      fail!("strict stock construction process roster differs for #{id}") unless construction_processes.length == 1
      record = {
        'id' => id, 'function_family' => profile.fetch('source_function'),
        'source_function' => profile.fetch('source_function'),
        'canonical_function' => profile.fetch('canonical_function'),
        'argument_type' => profile.fetch('argument_type'), 'input_type' => profile.fetch('input_type'),
        'expected_storage_type' => profile.fetch('declared_type'), 'observed_schema' => observed,
        'classification' => 'strict_stock_construction_observed',
        'processes' => construction_processes,
      }
      @construction_records << record
      write_json(File.join(@root, 'cases', 'construction', "#{safe_label(id)}.json"), record)
      write_source_json(File.join(@source_root, 'construction', 'cases', "#{safe_label(id)}.json"), record)
    end

    def capture_construction_census!
      @construction_profiles.each { |profile| capture_construction_profile!(profile) }
      fail!('W223 construction census count differs from its independent expected roster') unless
        @construction_records.length == 78 && @construction_records.all? { |item| item.fetch('classification') == 'strict_stock_construction_observed' }
    end

    def inventory(part, label)
      fail!("#{label} part is absent or noncanonical: #{part}") unless
        File.directory?(part) && !File.symlink?(part) && File.realpath(part) == part
      files = []
      Find.find(part) do |path|
        next if path == part
        fail!("symlink in #{label}: #{path}") if File.symlink?(path)
        next if File.directory?(path)
        fail!("non-file part entry in #{label}: #{path}") unless File.file?(path)
        files << {'path' => path[(part.length + 1)..-1], 'size' => File.size(path),
          'sha256' => Digest::SHA256.file(path).hexdigest}
      end
      files.sort_by { |entry| entry.fetch('path') }
    end

    def write_source_matrix!
      matrix = {
        'format' => FORMAT_SOURCE, 'case_count' => @profiles.length,
        'stock_physical_observed' => @profiles.length, 'physical_mismatches' => 0,
        'probe_failures' => 0, 'construction_mismatches' => 0,
        'source_pin' => {'source_reference' => "#{SOURCE_ROOT}@#{SOURCE_REVISION}",
          'runtime_built_from_this_snapshot_not_asserted' => true,
          'file_hashes' => @source_hashes.map { |path, record| {'path' => path,
            'expected_sha256' => record.fetch('expected_sha256'), 'actual_sha256' => record.fetch('sha256'), 'matches' => true} }},
        'runtime_pin' => {'runtime_version' => VERSION, 'runtime_build_hash' => BUILD_HASH,
          'runtime_sha256' => CLICKHOUSE_SHA256},
        'case_basis' => '43 branch-oriented state-width, nullable/LC, canonicalization, and Count compatibility witnesses; not a Cartesian closure.',
        'construction_census' => {
          'expected_count' => @construction_profiles.length, 'observed_count' => @construction_records.length,
          'base_type_count' => BASE_TYPES.length, 'sum_arguments' => BASE_TYPES,
          'sum_with_overflow_arguments' => BASE_TYPES,
          'targeted_sum_kahan_arguments' => @construction_profiles.select { |item| item.fetch('source_function') == 'sumKahan' }.map { |item| item.fetch('argument_type') },
          'law' => 'each source spelling is CREATEd independently; observed system.columns type must equal the independently expected canonical storage descriptor',
          'cases' => @construction_records,
        },
        'matrix' => @profiles,
      }
      write_source_json(File.join(@source_root, 'matrix.json'), matrix)
      @source_matrix_path = File.join(@source_root, 'matrix.json')
      @source_matrix_sha = Digest::SHA256.file(@source_matrix_path).hexdigest
    end

    def helper_input_profile(profile, index)
      part_parent = File.join(@root, 'generated', 'parts', format('%03d-%s', index, safe_label(profile.fetch('id'))))
      Dir.mkdir(part_parent, 0o700)
      base = {
        'id' => profile.fetch('id'), 'kind' => profile.fetch('kind'),
        'declared_type' => profile.fetch('declared_type'),
        'source_type' => profile.fetch('source_type'),
        'source_part' => profile.fetch('physical').fetch('source_part_path'),
        'library_part' => File.join(part_parent, 'all_1_1_0'),
        'row_keys' => ROW_KEYS, 'mark_rows' => MARK_ROWS,
        'state_hex' => profile.fetch('literal_state_hex'),
      }
      if profile.fetch('kind') == 'count'
        base['counts'] = [0, 127, 128, 16_384, 18_446_744_073_709_551_615].map(&:to_s)
      else
        base['argument_type'] = profile.fetch('argument_type')
        base['canonical_function'] = profile.fetch('canonical_function')
        base['source_function'] = profile.fetch('source_function')
      end
      base
    end

    def write_helper_input!
      input = {'format' => FORMAT_INPUT, 'capture_root' => @source_root,
        'profiles' => @profiles.each_with_index.map { |profile, index| helper_input_profile(profile, index) }}
      path = File.join(@root, 'generated', 'helper-input.json')
      write_json(path, input)
      @helper_input_sha = Digest::SHA256.file(path).hexdigest
      @helper_input_path = path
    end

    def write_manifest!
      write_json(File.join(@root, 'manifest.json'), {
        'suite' => 'W223 paired stock and library AggregateFunction Sum-family physical evidence',
        'runtime_expected' => {'version' => VERSION, 'build_hash' => BUILD_HASH, 'sha256' => CLICKHOUSE_SHA256},
        'comparison_source' => "#{SOURCE_ROOT}@#{SOURCE_REVISION}",
        'runtime_source_correlation' => 'not_asserted',
        'source_root' => @source_root,
        'source_matrix' => {'path' => @source_matrix_path, 'sha256' => @source_matrix_sha, 'profiles' => @profiles.length},
        'profiles' => @profiles.map do |item|
          item.slice('id', 'kind', 'source_function', 'canonical_function', 'argument_type', 'declared_type')
        end,
        'construction_law_scope' => {'ordinary_sum_and_overflow_arguments' => BASE_TYPES,
          'sum_argument_count' => BASE_TYPES.length, 'sum_with_overflow_argument_count' => BASE_TYPES.length,
          'targeted_sum_kahan_argument_count' => @construction_profiles.count { |item| item.fetch('source_function') == 'sumKahan' },
          'observed_construction_count' => @construction_records.length, 'physical_profile_count' => @profiles.length,
          'claim' => 'construction admission is an exact finite census for 33 base leaves plus targeted Kahan cases; physical proof is branch-oriented, not Cartesian recursive closure'},
        'rows' => {'keys' => ROW_KEYS, 'row_count' => 5, 'real_mark_rows' => MARK_ROWS,
          'RowBinary_windows' => ['full', 'middle keys 22..44', 'empty where pk=0']},
        'literal_oracle' => 'Independent Ruby fixed-width little-endian accumulator, Nullable presence, two-word Kahan and Count VarUInt bytes; no production codec reused',
        'metadata_policy' => {'stock_source' => 'columns empty; types_serialization_versions.string=1; serialization.json version=1; metadata_version.txt=0; propagate=true',
          'sum_library_writer' => 'Sum-family generic writer: Default pk record; types_serialization_versions.string=0; serialization.json version=1; metadata_version.txt=0; propagate=true',
          'count_compatibility_writer' => 'Count legacy writer uses PartSchemaMetadata.serialization_metadata (src/crystal_click/wide_part_writer/staged_aggregate_count_part_validator.cr:34): columns empty; types_serialization_versions.string=1; serialization.json version=1; metadata_version.txt=0; propagate=true',
          'difference' => 'stock/Count omitted-default string setting is 1; Sum generic writer single_stream is 0; the two writer paths are intentionally distinct'},
        'attachment_inventory_policy' => {
          'scope' => 'native ATTACH preserves every original generated file path, size, and SHA-256; only the exact observed auxiliary file may be added',
          'allowed_added_file' => INVALIDATED_FILE, 'exact_line_set' => INVALIDATED_NAMES,
          'source_basis' => ATTACHMENT_SOURCE_BASIS, 'source_path_scope' => ATTACHMENT_SOURCE_PATH_SCOPE,
        },
        'process_policy' => {'timeout_seconds' => PROCESS_TIMEOUT_SECONDS,
          'helper_timeout_seconds' => HELPER_TIMEOUT_SECONDS,
          'children' => 'inherit outer process group; bounded termination targets positive child PID',
          'unexpected refusal/nonzero/timeout/spawn error' => 'probe failure, never positive law evidence'},
      })
    end

    def invoke_helper!
      write_helper_input!
      result = @recorder.run_helper('generic-stock-read-library-write-read', @helper_input_path,
        File.join(@root, 'generated'), @source_root)
      assert_success!(result, 'prebuilt Crystal stock/library reader-writer helper')
      parsed = JSON.parse(result.fetch(:stdout))
      fail!('Crystal helper output format differs') unless parsed.fetch('format') == FORMAT_HELPER
      fail!('Crystal helper roster/count differs') unless parsed.fetch('profile_count') == @profiles.length &&
        parsed.fetch('profiles').length == @profiles.length && parsed.fetch('mismatch_count') == 0
      fail!('Crystal helper profile order differs') unless
        parsed.fetch('profiles').map { |item| item.fetch('id') } == @profiles.map { |item| item.fetch('id') }
      @helper_profiles = parsed.fetch('profiles')
      @helper_profiles.each_with_index do |item, index|
        profile = @profiles.fetch(index)
        fail!("helper did not physically observe #{profile.fetch('id')}") unless
          item.fetch('classification') == 'physical_observed' && item.fetch('declared_type') == profile.fetch('declared_type')
        generated = File.expand_path(item.fetch('library_part_path'))
        allowed = File.join(@root, 'generated', 'parts') + File::SEPARATOR
        fail!("generated library part escaped exact output root for #{profile.fetch('id')}") unless generated.start_with?(allowed)
        fail!("generated library part is absent or noncanonical for #{profile.fetch('id')}") unless
          File.directory?(generated) && !File.symlink?(generated) && File.realpath(generated) == generated
        item['library_part_inventory'] = inventory(generated, "library #{profile.fetch('id')}")
        fail!("generated library part inventory is empty for #{profile.fetch('id')}") if item['library_part_inventory'].empty?
        fail!("helper literal state evidence differs for #{profile.fetch('id')}") unless
          item.fetch('literal_state_hex') == profile.fetch('literal_state_hex')
        %w[source library].each do |side|
          reader = item.fetch(side)
          fail!("#{side} reader row/mark grid differs for #{profile.fetch('id')}") unless
            reader.fetch('row_count') == 5 && reader.fetch('mark_row_counts') == MARK_ROWS
        end
        if profile.fetch('kind') == 'sum'
          expected_schedule = [[0, 0, 2], [1, 2, 2], [2, 4, 1]]
          %w[source_public_scan library_public_scan].each do |side|
            fail!("#{side} public typed schedule differs for #{profile.fetch('id')}") unless
              item.fetch(side).fetch('batch_schedule') == expected_schedule
          end
        else
          fail!("Count compatibility reader path missing for #{profile.fetch('id')}") unless item.fetch('kind') == 'count'
        end
        @records << {'id' => profile.fetch('id'), 'classification' => 'library_helper_observed',
          'declared_type' => profile.fetch('declared_type'), 'library_part_path' => generated,
          'library_inventory' => item.fetch('library_part_inventory')}
      end
      @helper_process = result.fetch(:record)
      write_json(File.join(@root, 'generated', 'helper-output.json'), parsed)
      write_json(File.join(@root, 'generated', 'helper-process.json'), @helper_process)
    rescue JSON::ParserError => error
      fail!("Crystal helper stdout was not one JSON value: #{error.message}")
    end

    def create_native_targets!
      @target_by_id = {}
      @profiles.each do |profile|
        id = profile.fetch('id')
        store = File.join(@root, 'stores', 'native', safe_label(id))
        Dir.mkdir(store, 0o700)
        table = table_name(profile)
        created = @recorder.run_clickhouse("native-create-#{id}", store, create_sql(profile, table))
        assert_success!(created, "native target CREATE #{id}")
        path_result = @recorder.run_clickhouse("native-data-path-#{id}", store,
          "SELECT arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw")
        assert_success!(path_result, "native target data path #{id}")
        data_path = File.expand_path(path_result.fetch(:stdout).strip)
        fail!("native target path escaped case store for #{id}") unless data_path.start_with?(store + File::SEPARATOR)
        detached = File.join(data_path, 'detached')
        fail!("native detached directory absent, symlinked, or noncanonical for #{id}") unless
          File.directory?(detached) && !File.symlink?(detached) && File.realpath(detached) == detached
        detached_part = File.join(detached, 'all_1_1_0')
        fail!("native detached destination already exists for #{id}") if File.exist?(detached_part) || File.symlink?(detached_part)
        @target_by_id[id] = {'store' => store, 'table' => table, 'data_path' => data_path,
          'detached_path' => detached_part}
      end
    end

    def parse_substreams(text, id)
      fail!("columns_substreams not newline terminated for #{id}") unless text.end_with?("\n")
      fail!("columns_substreams contains CR for #{id}") if text.include?("\r")
      lines = text.lines.map(&:chomp)
      fail!("columns_substreams header differs for #{id}") unless lines.shift == 'columns substreams version: 1' && lines.shift == '2 columns:'
      delimiter = 96.chr
      roster = {}
      %w[pk v].each do |expected_column|
        header = lines.shift.to_s
        prefix = /\A([1-9][0-9]*) substreams for column /.match(header)
        fail!("columns_substreams header malformed for #{id}/#{expected_column}") unless prefix && header.end_with?(':')
        column = header[prefix[0].length...-1]
        fail!("columns_substreams column order/name differs for #{id}") unless column == "#{delimiter}#{expected_column}#{delimiter}"
        count = Integer(prefix[1], 10)
        maximum = expected_column == 'pk' ? 1 : 16
        fail!("columns_substreams count exceeds finite bound for #{id}") unless count <= maximum
        names = []
        count.times do
          line = lines.shift.to_s
          fail!("columns_substreams item malformed for #{id}") unless line.start_with?("\t") && line.count("\t") == 1
          names << line[1..-1]
        end
        fail!("duplicate columns_substreams item for #{id}") unless names.uniq.length == names.length
        roster[expected_column] = names.sort
      end
      fail!("trailing columns_substreams fields for #{id}") unless lines.empty?
      roster
    rescue ArgumentError => error
      fail!("columns_substreams count invalid for #{id}: #{error.message}")
    end

    def check_attachment_delta!(before, after, part, id)
      before_map = before.each_with_object({}) { |item, map| map[item.fetch('path')] = item }
      after_map = after.each_with_object({}) { |item, map| map[item.fetch('path')] = item }
      removed = before_map.keys - after_map.keys
      changed = before_map.keys.select { |path| after_map.key?(path) && before_map.fetch(path) != after_map.fetch(path) }
      added = after_map.keys - before_map.keys
      fail!("ATTACH removed/changed original files for #{id}") unless removed.empty? && changed.empty?
      fail!("ATTACH added unexpected files for #{id}: #{added.inspect}") unless added == [INVALIDATED_FILE]
      bytes = File.binread(File.join(part, INVALIDATED_FILE))
      lines = bytes.split("\n", -1)
      fail!("ATTACH auxiliary is not two newline-terminated lines for #{id}") unless lines.pop == '' && lines.length == 2
      fail!("ATTACH auxiliary names differ for #{id}") unless lines.uniq.sort == INVALIDATED_NAMES.sort
      auxiliary = after_map.fetch(INVALIDATED_FILE)
      fail!("ATTACH auxiliary inventory differs for #{id}") unless
        auxiliary.fetch('size') == bytes.bytesize && auxiliary.fetch('sha256') == Digest::SHA256.hexdigest(bytes)
      {'removed_paths' => removed, 'changed_original_paths' => changed, 'added_paths' => added,
        'auxiliary_path' => INVALIDATED_FILE, 'auxiliary_names_unordered' => lines.sort,
        'auxiliary_sha256' => Digest::SHA256.hexdigest(bytes), 'original_files_preserved_exactly' => true,
        'only_source_backed_auxiliary_added' => true}
    end

    def rowbinary_expected(profile, indices)
      indices.map do |index|
        [ROW_KEYS.fetch(index)].pack('Q<') + [profile.fetch('literal_state_hex').fetch(index)].pack('H*')
      end.join.b
    end

    def validate_native_window!(profile, target, window, indices)
      predicate = case window
                  when 'full' then ''
                  when 'middle' then ' WHERE pk BETWEEN 22 AND 44'
                  when 'empty' then ' WHERE pk = 0'
                  else fail!("unlisted native RowBinary window #{window}")
                  end
      result = @recorder.run_clickhouse("native-rowbinary-#{profile.fetch('id')}-#{window}", target.fetch('store'),
        "SELECT pk, v FROM default.#{target.fetch('table')}#{predicate} ORDER BY pk FORMAT RowBinary")
      assert_success!(result, "native #{window} RowBinary #{profile.fetch('id')}")
      expected = rowbinary_expected(profile, indices)
      fail!("attached native #{window} RowBinary differs from independent bytes for #{profile.fetch('id')}") unless
        result.fetch(:stdout).b == expected
      {'bytes' => expected.bytesize, 'sha256' => Digest::SHA256.hexdigest(expected),
        'matches_independent_literal' => true, 'invocation' => result.fetch(:record)}
    end

    def attach_and_verify_one!(profile, helper_profile)
      id = profile.fetch('id')
      target = @target_by_id.fetch(id)
      generated = File.expand_path(helper_profile.fetch('library_part_path'))
      generated_inventory = inventory(generated, "pre-attach library #{id}")
      FileUtils.cp_r(generated, target.fetch('detached_path'))
      detached_inventory = inventory(target.fetch('detached_path'), "detached library #{id}")
      fail!("detached copy differs from generated library part for #{id}") unless detached_inventory == generated_inventory

      attach = @recorder.run_clickhouse("native-attach-#{id}", target.fetch('store'),
        "ALTER TABLE default.#{target.fetch('table')} ATTACH PART 'all_1_1_0'")
      assert_success!(attach, "native ATTACH #{id}")
      check = @recorder.run_clickhouse("native-check-#{id}", target.fetch('store'),
        "CHECK TABLE default.#{target.fetch('table')} FORMAT TSVRaw")
      assert_success!(check, "native CHECK TABLE #{id}")
      fail!("native CHECK TABLE output differs for #{id}") unless check.fetch(:stdout) == "all_1_1_0\t1\t\n"

      part_result = @recorder.run_clickhouse("native-active-part-#{id}", target.fetch('store'),
        "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{target.fetch('table')}' AND active ORDER BY name FORMAT TSVRaw")
      assert_success!(part_result, "native active part census #{id}")
      rows = part_result.fetch(:stdout).force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp)
      fail!("native attached part census differs for #{id}") unless rows.length == 1
      fields = rows.first.split("\t", -1)
      attached = File.join(target.fetch('data_path'), 'all_1_1_0')
      fail!("native attached part identity/grid differs for #{id}") unless
        fields.length == 5 && fields[0] == 'all_1_1_0' && fields[1] == '5' && fields[2] == '4' &&
        fields[3] == 'Wide' && File.expand_path(fields[4]) == attached
      after_inventory = inventory(attached, "attached library #{id}")
      delta = check_attachment_delta!(generated_inventory, after_inventory, attached, id)

      tick = 96.chr
      columns = File.binread(File.join(attached, 'columns.txt')).force_encoding(Encoding::UTF_8).scrub
      expected_columns = "columns format version: 1\n2 columns:\n#{tick}pk#{tick} UInt64\n#{tick}v#{tick} #{profile.fetch('declared_type')}\n"
      fail!("native columns.txt exact declaration differs for #{id}") unless columns == expected_columns
      substreams_text = File.binread(File.join(attached, 'columns_substreams.txt')).force_encoding(Encoding::UTF_8).scrub
      substreams = parse_substreams(substreams_text, id)
      value_streams = helper_profile.fetch('library').fetch('physical_stream_names').sort
      fail!("native substream membership differs for #{id}") unless substreams == {'pk' => ['pk'], 'v' => value_streams}
      serialization = JSON.parse(File.binread(File.join(attached, 'serialization.json')))
      expected_serialization = if profile.fetch('kind') == 'count'
        {'columns' => [], 'propagate_types_serialization_versions_to_nested_types' => true,
          'types_serialization_versions' => {'string' => 1}, 'version' => 1}
      else
        {'columns' => [{'exact_num_defaults' => true, 'kind' => 'Default', 'name' => 'pk', 'num_defaults' => 0, 'num_rows' => 5}],
          'propagate_types_serialization_versions_to_nested_types' => true,
          'types_serialization_versions' => {'string' => 0}, 'version' => 1}
      end
      fail!("library serialization metadata differs for #{id}") unless serialization == expected_serialization
      stock_serialization = profile.fetch('physical').fetch('serialization_json')
      fail!("stock source serialization policy differs for #{id}") unless stock_serialization == {
        'columns' => [], 'propagate_types_serialization_versions_to_nested_types' => true,
        'types_serialization_versions' => {'string' => 1}, 'version' => 1,
      }
      metadata_version = File.binread(File.join(attached, 'metadata_version.txt')).strip
      codec = File.binread(File.join(attached, 'default_compression_codec.txt')).strip
      count = File.binread(File.join(attached, 'count.txt')).strip
      fail!("native metadata version/codec/count differs for #{id}") unless metadata_version == '0' && codec == 'CODEC(LZ4)' && count == '5'

      schema_result = @recorder.run_clickhouse("native-schema-#{id}", target.fetch('store'),
        "SELECT name, type FROM system.columns WHERE database='default' AND table='#{target.fetch('table')}' ORDER BY position FORMAT TSVRaw")
      assert_success!(schema_result, "native schema #{id}")
      schema = schema_result.fetch(:stdout).force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp)
      fail!("native exact schema differs for #{id}") unless schema == ["pk\tUInt64", "v\t#{profile.fetch('declared_type')}"]
      type_result = @recorder.run_clickhouse("native-type-name-#{id}", target.fetch('store'),
        "SELECT toTypeName(v) FROM default.#{target.fetch('table')} LIMIT 1 FORMAT TSVRaw")
      assert_success!(type_result, "native toTypeName #{id}")
      fail!("native toTypeName differs for #{id}") unless type_result.fetch(:stdout).strip == profile.fetch('declared_type')
      hex_result = @recorder.run_clickhouse("native-state-hex-#{id}", target.fetch('store'),
        "SELECT hex(v) FROM default.#{target.fetch('table')} ORDER BY pk FORMAT TSVRaw")
      assert_success!(hex_result, "native state hex #{id}")
      observed_hex = hex_result.fetch(:stdout).force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp).map(&:downcase)
      fail!("native state bytes differ for #{id}") unless observed_hex == profile.fetch('literal_state_hex')
      rowbinary = {
        'full' => validate_native_window!(profile, target, 'full', [0, 1, 2, 3, 4]),
        'middle' => validate_native_window!(profile, target, 'middle', [1, 2, 3]),
        'empty' => validate_native_window!(profile, target, 'empty', []),
      }
      record = {
        'id' => id, 'kind' => profile.fetch('kind'), 'source_function' => profile.fetch('source_function'),
        'canonical_function' => profile.fetch('canonical_function'), 'argument_type' => profile['argument_type'],
        'declared_type' => profile.fetch('declared_type'), 'classification' => 'native_attached_observed',
        'generated_part_path' => generated, 'generated_inventory_before_attach' => generated_inventory,
        'detached_inventory_before_attach' => detached_inventory, 'attached_part_path' => attached,
        'attached_inventory_after_attach' => after_inventory, 'attachment_inventory_delta' => delta,
        'columns_txt' => columns, 'columns_substreams_txt' => substreams_text,
        'columns_substreams_expected' => {'pk' => ['pk'], 'v' => value_streams},
        'source_stock_serialization_json' => stock_serialization,
        'attached_library_serialization_json' => serialization,
        'source_library_serialization_difference' => {
          'source_columns' => stock_serialization.fetch('columns'), 'library_columns' => serialization.fetch('columns'),
          'source_string_version' => stock_serialization.fetch('types_serialization_versions').fetch('string'),
          'library_string_version' => serialization.fetch('types_serialization_versions').fetch('string'),
        },
        'metadata_version_txt' => metadata_version, 'codec' => codec, 'count_txt' => count,
        'native_schema' => schema, 'native_type_name' => type_result.fetch(:stdout).strip,
        'native_state_hex' => observed_hex, 'literal_state_hex' => profile.fetch('literal_state_hex'),
        'check_table_invocation' => check.fetch(:record), 'rowbinary' => rowbinary,
      }
      @records << record
      write_json(File.join(@root, 'cases', 'profiles', "#{safe_label(id)}-native.json"), record)
      record
    rescue JSON::ParserError => error
      fail!("native serialization metadata JSON invalid for #{id}: #{error.message}")
    end

    def attach_and_verify_all!
      @profiles.each_with_index { |profile, index| attach_and_verify_one!(profile, @helper_profiles.fetch(index)) }
    end

    def write_summary(classification)
      return unless @root && File.directory?(@root) && !File.exist?(File.join(@root, 'summary.json'))
      write_json(File.join(@root, 'summary.json'), {
        'format' => 'aggregate_sum_w223_summary_v1', 'classification' => classification,
        'success' => classification == 'paired_sum_family_bulk_observed', 'error' => @fatal,
        'evidence_root' => @root, 'source_root' => @source_root,
        'source_matrix_path' => @source_matrix_path, 'source_matrix_sha256' => @source_matrix_sha,
        'runtime_pin' => @clickhouse_pin, 'helper' => {'path' => @helper, 'sha256' => @helper_sha},
        'counts' => {'expected_profiles' => @profiles.length,
          'expected_construction_cases' => @construction_profiles.length,
          'construction_observed' => @construction_records.length,
          'stock_observed' => @profiles.count { |item| item['classification'] == 'stock_physical_observed' },
          'generic_helper_observed' => @helper_profiles.length,
          'native_attached_observed' => @records.count { |item| item['classification'] == 'native_attached_observed' },
          'invocations' => @invocations.length},
        'process_status_counts' => {
          'success_exit0' => @invocations.count { |item| item.dig('status', 'success') == true && item.dig('status', 'exitstatus') == 0 },
          'failed_timed_out_or_spawn_error' => @invocations.count do |item|
            item.dig('status', 'success') != true || item.dig('status', 'exitstatus') != 0 ||
              item.dig('status', 'timed_out') == true || !item.dig('status', 'spawn_error').nil?
          end,
        },
      })
    end

  end

  class Recorder
    def initialize(probe)
      @probe = probe
      @root = probe.root
      @sequence = 0
    end

    def run_clickhouse(label, store, sql, input: nil, multiquery: false, extra_args: [])
      argv = [@probe.binary, 'local', '--path', store, '--session_timezone=UTC',
        '--enable_time_time64_type=1', '--max_threads=1', '--max_insert_threads=1',
        '--max_execution_time=30', "--max_memory_usage=#{MEMORY_LIMIT_BYTES}"]
      argv << '--multiquery' if multiquery
      argv.concat(extra_args)
      argv.concat(['--query', sql])
      run(label, argv, input, PROCESS_TIMEOUT_SECONDS, {'TZ' => 'UTC'}, 'clickhouse', sql_record: sql)
    end

    def run_helper(label, input_path, output_root, capture_root)
      argv = [@probe.helper, input_path, output_root, capture_root]
      run(label, argv, nil, HELPER_TIMEOUT_SECONDS, {'TZ' => 'UTC'}, 'crystal_helper')
    end

    private

    def run(label, argv, input, timeout, environment, role, sql_record: nil)
      @sequence += 1
      stem = format('%05d-%s', @sequence, label.gsub(/[^A-Za-z0-9_.-]/, '_'))
      prefix = File.join(@root, 'invocations', stem)
      @probe.write_new(prefix + '.sql', sql_record || input || "#{role}: #{argv.join(' ')}\n") if role == 'clickhouse'
      @probe.write_new(prefix + '.argv.json', JSON.pretty_generate({
        'label' => label, 'argv' => argv, 'environment' => environment,
        'timeout_seconds' => timeout, 'process_group' => 'inherited', 'role' => role,
        'stdin_bytes' => input && input.bytesize,
        'stdin_sha256' => input && Digest::SHA256.hexdigest(input),
      }) + "\n")

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stdout_bytes = ''.b
      stderr_bytes = ''.b
      status = nil
      timed_out = false
      spawn_error = nil
      waiter = nil
      readers = []
      stdin = stdout = stderr = nil
      begin
        # Children stay in the outer run_safe group; timeout targets only this
        # positive PID and never creates a detached child process group.
        stdin, stdout, stderr, waiter = Open3.popen3(environment, *argv)
        [stdin, stdout, stderr].each(&:binmode)
        readers = [Thread.new { stdout.read }, Thread.new { stderr.read }]
        stdin.write(input.b) if input
        stdin.close
        unless waiter.join(timeout)
          timed_out = true
          terminate_child(waiter)
        end
        status = waiter.value
        stdout_bytes = readers[0].value
        stderr_bytes = readers[1].value
      rescue StandardError => error
        spawn_error = "#{error.class}: #{error.message}"
      ensure
        terminate_child(waiter) if waiter && waiter.alive?
        waiter.join if waiter
        [stdin, stdout, stderr].compact.each do |pipe|
          pipe.close unless pipe.closed?
        rescue IOError
          nil
        end
        readers.each(&:join)
      end

      codes = (stdout_bytes + stderr_bytes).scan(/(?:^|[^A-Za-z0-9_])Code:[\x09-\x0d\x20]*([0-9]+)(?![A-Za-z0-9_])/n).flatten.map(&:to_i).uniq
      process_status = {
        'success' => status && status.success? || false,
        'exitstatus' => status && status.exitstatus,
        'signaled' => status && status.signaled? || false,
        'termsig' => status && status.termsig,
        'timed_out' => timed_out,
        'duration_ms' => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
        'reported_clickhouse_codes' => codes,
      }
      process_status['spawn_error'] = spawn_error if spawn_error
      @probe.write_new(prefix + '.stdout', stdout_bytes)
      @probe.write_new(prefix + '.stderr', stderr_bytes)
      @probe.write_json(prefix + '.status.json', process_status)
      record = {
        'label' => label, 'stem' => prefix.delete_prefix(@root + File::SEPARATOR), 'role' => role,
        'status' => process_status,
        'argv_sha256' => Digest::SHA256.file(prefix + '.argv.json').hexdigest,
        'stdout_sha256' => Digest::SHA256.hexdigest(stdout_bytes),
        'stderr_sha256' => Digest::SHA256.hexdigest(stderr_bytes),
      }
      @probe.instance_variable_get(:@invocations) << record
      {stdout: stdout_bytes, stderr: stderr_bytes, status: process_status, record: record, prefix: prefix}
    end

    def terminate_child(waiter)
      return unless waiter && waiter.alive?
      begin
        Process.kill('TERM', waiter.pid)
      rescue Errno::ESRCH
        nil
      end
      unless waiter.join(TERM_GRACE_SECONDS)
        begin
          Process.kill('KILL', waiter.pid)
        rescue Errno::ESRCH
          nil
        end
        waiter.join
      end
    end
  end

  def main(argv)
    options = {}
    parser = OptionParser.new do |items|
      items.banner = 'Usage: recheck_aggregate_sum_w223.rb --clickhouse PATH --crystal-helper PATH --source-root EMPTY_ROOT --evidence-root EMPTY_ROOT'
      items.on('--clickhouse PATH', 'Pinned ClickHouse executable') { |value| options[:clickhouse] = value }
      items.on('--crystal-helper PATH', 'Prebuilt Crystal helper executable') { |value| options[:crystal_helper] = value }
      items.on('--source-root PATH', 'Fresh empty source capture root under /private/tmp') { |value| options[:source_root] = value }
      items.on('--evidence-root PATH', 'Fresh empty evidence root under /private/tmp') { |value| options[:evidence_root] = value }
    end
    parser.parse!(argv)
    raise OptionParser::MissingArgument, 'one or more required options' unless
      %i[clickhouse crystal_helper source_root evidence_root].all? { |key| options[key] }
    raise OptionParser::InvalidArgument, "unexpected positional arguments: #{argv.inspect}" unless argv.empty?
    exit(Probe.new(options).run ? 0 : 1)
  rescue StandardError => error
    warn "W223 runner setup/error (not a type-law refusal): #{error.class}: #{error.message}"
    warn parser.to_s if parser
    exit 2
  end
end

RecheckAggregateSumW223.main(ARGV)
