#!/usr/bin/env ruby
# Paired stock-ClickHouse and Crystal Dynamic AggregateFunction qualification.
# RowBinary inputs and expectations below are literal, independent of the
# Crystal helper and production codec.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require_relative 'recheck_aggregate_recursive_w224'

module RecheckAggregateDynamicW226
  extend self

  R = RecheckAggregateRecursiveW224
  VERSION = R::VERSION.freeze
  BUILD_HASH = R::BUILD_HASH.freeze
  RUNTIME_SHA256 = R::RUNTIME_SHA256.freeze
  SOURCE_ROOT = R::SOURCE_ROOT.freeze
  SOURCE_REVISION = R::SOURCE_REVISION.freeze
  SOURCE_PREFIX = '/private/tmp/crystal-click-w226-native.'.freeze
  EVIDENCE_PREFIX = '/private/tmp/crystal-click-w226-evidence.'.freeze
  FORMAT_INPUT = 'aggregate_dynamic_w226_input_v1'.freeze
  FORMAT_HELPER = 'aggregate_dynamic_w226_helper_v1'.freeze
  FORMAT_SUMMARY = 'aggregate_dynamic_w226_summary_v1'.freeze
  FORMAT_MATRIX = 'aggregate_dynamic_w226_stock_matrix_v1'.freeze
  DYNAMIC_BASIC_SETTING = 'use_compact_variant_discriminators_serialization=0'.freeze
  INVALIDATED_FILE = 'invalidated_system_columns.txt'.freeze
  INVALIDATED_NAMES = %w[_block_number _block_offset].freeze
  CHECKS = %w[source_full source_middle source_zero library_full library_middle library_zero
    typed_scan_callbacks generic_scan_values window_middle window_eof owned_values
    rowbinary_full rowbinary_middle rowbinary_zero pqr_schedule source_roster_placement_expectation].freeze
  PROFILE_IDS = %w[
    known_count_shared_sum_single_stream
    known_count_shared_sum_with_size_stream
    all_shared_single_stream
    all_shared_with_size_stream
    actual_array_sum_single_stream
    actual_array_sum_with_size_stream
    outer_array_dynamic_single_stream
    outer_array_dynamic_with_size_stream
  ].freeze
  COUNT_DESCRIPTOR = ['250005636f756e740000'].pack('H*').b.freeze
  SUM_U8_DESCRIPTOR = ['25000373756d000101'].pack('H*').b.freeze
  ARRAY_SUM_U8_DESCRIPTOR = ("\x1e".b + SUM_U8_DESCRIPTOR).freeze
  NOTHING_DESCRIPTOR = "\x00".b.freeze
  MAX_U64 = 18_446_744_073_709_551_615
  STRING_VERSIONS = { 'single_stream' => 0, 'with_size_stream' => 1 }.freeze
  SOURCE_HASHES = {
    'src/Columns/ColumnDynamic.cpp' => 'aa358c9ac40b8d20d7cc15e7292cdc7eb6aa218ced66d023b80628cac904c04a',
    'src/Columns/ColumnDynamic.h' => '5375cf777d0982c26ce59baafb4db65dea90b76091ed1e2e794508fa5387de5c',
    'src/DataTypes/Serializations/SerializationDynamic.cpp' => 'ae052b671cf6b00ea87ac41aa80983bd48439235dcd035726fc9063a7ab81491',
    'src/DataTypes/DataTypesBinaryEncoding.h' => '92c3362477dc283302fc84713413f45fd6c92c7273309c6efb41425d22c5485f',
    'src/DataTypes/DataTypesBinaryEncoding.cpp' => '78ba394f20ccd2a00f5be6b8c4d470fafb1c91a6f87bb27c301c2d3203f28f87',
    'src/DataTypes/DataTypeVariant.cpp' => '10cf25b1ad0c1fd00eec3637bca21756207122d45ef09f97518c5748d6ae300d',
    'src/DataTypes/Serializations/SerializationVariant.cpp' => '9e91cc5a2aa9498841aa7524193247d55a30c77682c65a0991c77a2968b9e022',
  }.freeze

  def fail!(message)
    raise ArgumentError, message
  end

  def require_true(condition, message)
    fail!(message) unless condition
  end

  def write_new(path, bytes)
    File.open(path, 'wbx', 0o600) { |file| file.write(bytes) }
  rescue Errno::EEXIST
    fail!("refusing to overwrite W226 evidence: #{path}")
  end

  def write_json(path, object)
    write_new(path, JSON.pretty_generate(object) + "\n")
  end

  def validate_root(path, prefix, label)
    full = File.expand_path(path)
    require_true(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full && Dir.children(full).empty?,
      "#{label} must be a fresh, empty, canonical directory")
    require_true(File.dirname(full) == File.realpath('/private/tmp') && full.start_with?(prefix),
      "#{label} must be a fresh direct /private/tmp child with prefix #{prefix}")
    full
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

  def count(value)
    { 'kind' => 'count', 'value' => value.to_s }
  end

  def sum(value)
    { 'kind' => 'sum', 'value' => Integer(value) }
  end

  def null_value
    { 'kind' => 'null' }
  end

  def array_sum(*values)
    { 'kind' => 'array_sum', 'items' => values.map { |value| Integer(value) } }
  end

  def outer(*values)
    { 'kind' => 'outer', 'items' => values }
  end

  def cases
    values = [count(1), sum(256), null_value, count(MAX_U64), count(0)]
    [
      { 'case_id' => 'known_count_shared_sum', 'declared_type' => 'Dynamic(max_types=1)', 'site' => 'root',
        'source_types' => ['AggregateFunction(count)'],
        'source_shared' => [[false], [true], [nil], [false], [false]], 'rows' => values },
      { 'case_id' => 'all_shared', 'declared_type' => 'Dynamic(max_types=0)', 'site' => 'root',
        'source_types' => [], 'source_shared' => [[true], [true], [nil], [true], [true]], 'rows' => values },
      { 'case_id' => 'actual_array_sum', 'declared_type' => 'Dynamic(max_types=1)', 'site' => 'root',
        'source_types' => ['Array(AggregateFunction(sum, UInt8))'],
        'source_shared' => [[false], [true], [nil], [false], [false]],
        'rows' => [array_sum, count(256), null_value, array_sum(7, 17), array_sum(0)] },
      { 'case_id' => 'outer_array_dynamic', 'declared_type' => 'Array(Dynamic(max_types=1))', 'site' => 'root.elements',
        'source_types' => ['AggregateFunction(count)'],
        'source_shared' => [[], [], [false, true, nil], [false], [true, false]],
        'rows' => [outer, outer, outer(count(1), sum(256), null_value), outer(count(256)), outer(sum(0), count(MAX_U64))] },
    ]
  end

  def profiles
    cases.flat_map do |item|
      %w[single_stream with_size_stream].map do |profile|
        id = "#{item.fetch('case_id')}_#{profile}"
        item.merge('id' => id, 'profile' => profile,
          'source_types' => { item.fetch('site') => item.fetch('source_types') },
          'source_shared' => { item.fetch('site') => item.fetch('source_shared') },
          'mark_rows' => R::MARK_ROWS.map(&:to_i), 'row_keys' => R::ROW_KEYS.map(&:to_i))
      end
    end
  end

  def dynamic_type(value)
    case value.fetch('kind')
    when 'count' then 'AggregateFunction(count)'
    when 'sum' then 'AggregateFunction(sum, UInt8)'
    when 'array_sum' then 'Array(AggregateFunction(sum, UInt8))'
    when 'null' then 'Nothing'
    else fail!("unlisted W226 actual type: #{value.fetch('kind')}")
    end
  end

  def aggregate_descriptor(value)
    case value.fetch('kind')
    when 'count' then COUNT_DESCRIPTOR
    when 'sum' then SUM_U8_DESCRIPTOR
    when 'array_sum' then ARRAY_SUM_U8_DESCRIPTOR
    when 'null' then NOTHING_DESCRIPTOR
    else fail!("unlisted W226 descriptor kind: #{value.fetch('kind')}")
    end
  end

  def state_body(value)
    case value.fetch('kind')
    when 'count' then varuint(Integer(value.fetch('value'), 10))
    when 'sum' then u64(value.fetch('value'))
    when 'array_sum'
      items = value.fetch('items')
      varuint(items.length) + items.map { |item| u64(item) }.join.b
    when 'null' then ''.b
    else fail!("unlisted W226 state kind: #{value.fetch('kind')}")
    end
  end

  def dynamic_wire(value)
    aggregate_descriptor(value) + state_body(value)
  end

  def row_value_wire(profile, row)
    value = profile.fetch('rows').fetch(row)
    if profile.fetch('case_id') == 'outer_array_dynamic'
      items = value.fetch('items')
      varuint(items.length) + items.map { |item| dynamic_wire(item) }.join.b
    else
      dynamic_wire(value)
    end
  end

  def expected_rows(profile)
    profile.fetch('rows').each_index.map do |index|
      u64(profile.fetch('row_keys').fetch(index)) + row_value_wire(profile, index)
    end
  end

  def expected_windows(profile)
    rows = profile.fetch('rows').each_index.map { |index| row_value_wire(profile, index) }
    { 'full' => rows.join.b, 'middle' => rows[2, 2].join.b, 'zero' => ''.b }
  end

  def expected_signatures(profile)
    declared_descriptor = if profile.fetch('case_id') == 'outer_array_dynamic'
                            "\x1e\x2b\x01".b
                          else
                            max_types = profile.fetch('case_id') == 'all_shared' ? 0 : 1
                            "\x2b".b + [max_types].pack('C').b
                          end
    profile.fetch('rows').each_index.map do |index|
      bytes = declared_descriptor + row_value_wire(profile, index)
      "#{profile.fetch('declared_type')}|#{bytes.unpack1('H*')}"
    end
  end

  def expected_pqr(profile)
    outer = profile.fetch('case_id') == 'outer_array_dynamic'
    q = outer ? [0, 0, 3, 1, 2] : [1, 1, 1, 1, 1]
    r = outer ? [0, 0, 2, 1, 2] : [1, 1, 0, 1, 1]
    q_by_mark = [q[0, 2].sum, q[2, 2].sum, q[4, 1].sum]
    r_by_mark = [r[0, 2].sum, r[2, 2].sum, r[4, 1].sum]
    { 'parent_mark_rows' => [2, 2, 1],
      'dynamic_values_by_parent_row' => q,
      'selected_non_null_actuals_by_parent_row' => r,
      'dynamic_values_by_mark' => q_by_mark,
      'selected_non_null_actuals_by_mark' => r_by_mark }
  end

  def source_law!(profile, observed_types, observed_shared)
    expected = profile.fetch('source_types')
    expected_flags = profile.fetch('source_shared')
    require_true(observed_types == expected, "native Dynamic ordinary roster differs from finite W226 law for #{profile.fetch('id')}: #{observed_types.inspect}")
    require_true(observed_shared == expected_flags, "native Dynamic shared-occurrence grid differs from finite W226 law for #{profile.fetch('id')}: #{observed_shared.inspect}")
  end

  def checked_success!(record, label)
    require_true(record.fetch('classification') == 'process_success' && record.fetch('exitstatus') == 0 &&
      !record.fetch('signaled') && !record.fetch('timed_out') && !record.fetch('spawn_error'),
      "#{label} failed as a process; a process failure is not a semantic refusal")
    record
  end

  def clean_record(record)
    record.reject { |key, _| %w[stdout stderr path].include?(key) }
  end

  def pin_source!
    require_true(File.directory?(SOURCE_ROOT) && File.realpath(SOURCE_ROOT) == SOURCE_ROOT,
      'pinned ClickHouse source root is absent or noncanonical')
    base = R.pin_source!
    supplemental = SOURCE_HASHES.map do |relative, expected|
      path = File.join(SOURCE_ROOT, relative)
      require_true(File.file?(path) && !File.symlink?(path), "source anchor absent or symlinked: #{relative}")
      actual = Digest::SHA256.file(path).hexdigest
      { 'path' => relative, 'expected_sha256' => expected, 'actual_sha256' => actual, 'matches' => actual == expected }
    end
    require_true(supplemental.all? { |row| row.fetch('matches') }, 'a supplemental Dynamic/Variant source hash differs')
    base.merge('dynamic_source_hashes' => supplemental,
      'dynamic_source_laws' => [
        { 'path' => 'src/DataTypes/Serializations/SerializationDynamic.cpp', 'law' => 'Dynamic serializer owns type descriptors, known/shared routing, and its selected actual serializers; the finite probe checks only Count/Sum(UInt8)/Array(Sum(UInt8)).' },
        { 'path' => 'src/Columns/ColumnDynamic.h', 'law' => 'Dynamic column tracks known alternatives and shared payload separately; the probe records per-occurrence shared flags rather than inferring from roster alone.' },
        { 'path' => 'src/DataTypes/DataTypesBinaryEncoding.h', 'law' => 'RowBinary descriptors distinguish Nothing, Array, and AggregateFunction; fixture descriptors are fixed literal bytes.' },
        { 'path' => 'src/DataTypes/Serializations/SerializationAggregateFunction.cpp', 'law' => 'AggregateFunction RowBinary delegates to the aggregate state serializer; the probe supplies state bytes independently.' },
      ])
  end

  class Probe
    def initialize(options)
      @binary = R.validate_binary!(options.fetch(:clickhouse))
      @expected_helper_sha = R.validate_sha256_pin!(options.fetch(:helper_sha256), 'external helper SHA-256')
      @helper = R.validate_program!(options.fetch(:helper), 'prebuilt W226 Crystal helper')
      @helper_sha_start = Digest::SHA256.file(@helper).hexdigest
      RecheckAggregateDynamicW226.require_true(@helper_sha_start == @expected_helper_sha,
        "prebuilt W226 helper differs from external SHA-256 pin: #{@helper_sha_start}")
      @source_root = RecheckAggregateDynamicW226.validate_root(options.fetch(:source_root), SOURCE_PREFIX, 'stock source root')
      @root = RecheckAggregateDynamicW226.validate_root(options.fetch(:evidence_root), EVIDENCE_PREFIX, 'evidence root')
      @profiles = RecheckAggregateDynamicW226.profiles
      RecheckAggregateDynamicW226.require_true(@profiles.map { |row| row.fetch('id') } == PROFILE_IDS,
        'W226 profile roster/order differs from four-case by two-profile fixture')
      @recorder = R::Recorder.new(@root, @binary)
      @source_pin = nil
      @runtime_pin = nil
      @source_profiles = []
      @helper_profiles = []
      @library_inventories = {}
      @native_records = []
      @targets = {}
      @fatal = nil
    end

    def run
      prepare_layout
      @source_pin = RecheckAggregateDynamicW226.pin_source!
      pin_runtime
      @profiles.each_with_index { |profile, index| capture_stock_profile(profile, index) }
      write_source_matrix
      invoke_helper
      create_native_targets
      @profiles.each_with_index { |profile, index| attach_library_part(profile, @helper_profiles.fetch(index), index) }
      verify_invocations
      write_summary('paired_dynamic_aggregate_profiles_observed')
      puts "W226 paired Dynamic AggregateFunction profiles=#{@profiles.length}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal ||= "#{error.class}: #{error.message}"
      write_summary('runner_failure_or_observations_differ') rescue nil
      warn "W226 paired probe failure (process failure is not semantic refusal): #{@fatal}"
      false
    end

    private

    # Keep the runner's reusable fixture/process helpers owned by the module;
    # these narrow delegates avoid including the module entrypoint in Probe.
    def checked_success!(record, label)
      RecheckAggregateDynamicW226.checked_success!(record, label)
    end

    def clean_record(record)
      RecheckAggregateDynamicW226.clean_record(record)
    end

    def expected_rows(profile)
      RecheckAggregateDynamicW226.expected_rows(profile)
    end

    def expected_windows(profile)
      RecheckAggregateDynamicW226.expected_windows(profile)
    end

    def expected_signatures(profile)
      RecheckAggregateDynamicW226.expected_signatures(profile)
    end

    def expected_pqr(profile)
      RecheckAggregateDynamicW226.expected_pqr(profile)
    end

    def source_law!(profile, observed_types, observed_shared)
      RecheckAggregateDynamicW226.source_law!(profile, observed_types, observed_shared)
    end

    def write_json(path, object)
      RecheckAggregateDynamicW226.write_json(path, object)
    end

    def prepare_layout
      %w[invocations generated cases stores].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'generated', 'parts'), 0o700)
      %w[stores parts cases].each { |name| Dir.mkdir(File.join(@source_root, name), 0o700) }
      Dir.mkdir(File.join(@source_root, 'stores', 'profiles'), 0o700)
      Dir.mkdir(File.join(@source_root, 'stores', 'pins'), 0o700)
      Dir.mkdir(File.join(@source_root, 'stores', 'native'), 0o700)
      Dir.mkdir(File.join(@source_root, 'parts', 'profiles'), 0o700)
      Dir.mkdir(File.join(@source_root, 'cases', 'profiles'), 0o700)
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
    end

    def process(label, store, sql = nil, input: nil, timeout: R::PROCESS_TIMEOUT_SECONDS, argv: nil)
      @recorder.run(label, store, sql, input: input, timeout: timeout, argv: argv)
    end

    def pin_runtime
      store = File.join(@source_root, 'stores', 'pins')
      version = checked_success!(process('runtime-version-pin', store, 'SELECT version() FORMAT TSVRaw'), 'runtime version')
      RecheckAggregateDynamicW226.require_true(version.fetch('stdout').strip == VERSION, 'native version differs from exact pin')
      build = checked_success!(process('runtime-build-pin', store,
        "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw"), 'runtime build hash')
      RecheckAggregateDynamicW226.require_true(build.fetch('stdout').strip == "VERSION_GITHASH=#{BUILD_HASH}", 'native build hash differs from exact pin')
      @runtime_pin = { 'version' => VERSION, 'build_hash' => BUILD_HASH,
        'sha256' => Digest::SHA256.file(@binary).hexdigest, 'runtime_source_correlation' => 'not_asserted' }
    end

    def table_name(profile, native: false)
      "w226_#{native ? 'native_' : ''}#{profile.fetch('id')}"
    end

    def create_sql(profile, table)
      settings = R::STOCK_SETTINGS + ["string_serialization_version='#{profile.fetch('profile')}'",
        "dynamic_serialization_version='v3'", DYNAMIC_BASIC_SETTING]
      "CREATE TABLE default.#{table} (pk UInt64, v #{profile.fetch('declared_type')}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings.join(', ')}"
    end

    def inventory(part)
      path = File.expand_path(part)
      RecheckAggregateDynamicW226.require_true(File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path,
        "part is absent, symlinked, or noncanonical: #{path}")
      entries = []
      Find.find(path) do |entry|
        next if entry == path
        RecheckAggregateDynamicW226.require_true(!File.symlink?(entry), "part contains symlink: #{entry}")
        next if File.directory?(entry)
        RecheckAggregateDynamicW226.require_true(File.file?(entry), "part contains non-file entry: #{entry}")
        entries << { 'path' => entry[(path.length + 1)..-1], 'size' => File.size(entry), 'sha256' => Digest::SHA256.file(entry).hexdigest }
      end
      entries.sort_by { |entry| entry.fetch('path') }
    end

    def strict_part_path!(raw, expected, label)
      accepted = raw == expected || raw == expected + File::SEPARATOR
      RecheckAggregateDynamicW226.require_true(accepted, "#{label} path differs from exact canonical path: #{raw.inspect}")
      RecheckAggregateDynamicW226.require_true(File.directory?(expected) && !File.symlink?(expected) && File.realpath(expected) == expected,
        "#{label} path missing, symlinked, or redirected")
      expected
    end

    def schema_output(profile)
      "pk\tUInt64\nv\t#{profile.fetch('declared_type')}\n"
    end

    def expected_check
      "all_1_1_0\t1\t\n"
    end

    def part_path(profile)
      File.join(@source_root, 'parts', 'profiles', profile.fetch('id'), 'all_1_1_0')
    end

  def rowbinary_indices(window)
      { 'full' => [0, 1, 2, 3, 4], 'middle' => [2, 3], 'zero' => [] }.fetch(window)
    end

    def output_path(side, profile, window)
      File.join(@root, 'cases', "#{side}-#{profile.fetch('id')}-#{window}.rowbinary")
    end

    def run_rowbinary(side, profile, table, store)
      windows = {}
      %w[full middle zero].each do |window|
        output = output_path(side, profile, window)
        RecheckAggregateDynamicW226.require_true(!File.exist?(output) && !File.symlink?(output), "refusing to overwrite #{output}")
        predicate = case window
                    when 'full' then ''
                    when 'middle' then ' WHERE pk BETWEEN 33 AND 44'
                    when 'zero' then ' WHERE pk=0'
                    end
        sql = "SELECT pk, v FROM default.#{table}#{predicate} ORDER BY pk INTO OUTFILE '#{output.gsub("'", "\\'")}' FORMAT RowBinary"
        record = checked_success!(process("#{side}-rowbinary-#{profile.fetch('id')}-#{window}", store, sql), "#{side} #{window} RowBinary")
        actual = File.binread(output)
        expected_rows = expected_rows(profile)
        expected = rowbinary_indices(window).map { |row| expected_rows.fetch(row) }.join.b
        RecheckAggregateDynamicW226.require_true(actual == expected,
          "#{side} #{window} RowBinary differs from literal fixture for #{profile.fetch('id')}")
        windows[window] = { 'path' => output, 'bytes' => actual.bytesize, 'sha256' => Digest::SHA256.hexdigest(actual),
          'literal_hex' => actual.unpack1('H*'), 'matches_independent_literal' => true,
          'process' => clean_record(record) }
      end
      windows
    end

    def parse_flag(value)
      return nil if value.nil?
      return value if value == true || value == false
      return false if value == 0 || value == '0' || value == 'false'
      return true if value == 1 || value == '1' || value == 'true'
      RecheckAggregateDynamicW226.fail!("unrecognized isDynamicElementInSharedData value: #{value.inspect}")
    end

    def parse_type(value)
      return 'Nothing' if value == 'None'
      RecheckAggregateDynamicW226.require_true(value.is_a?(String) && !value.empty?, "invalid dynamicType result: #{value.inspect}")
      value
    end

    def normalized_shared_flag(type, raw_flag, label)
      flag = parse_flag(raw_flag)
      if type == 'Nothing'
        RecheckAggregateDynamicW226.require_true(flag == false,
          "#{label} NULL must retain the raw false isDynamicElementInSharedData result")
        nil
      else
        RecheckAggregateDynamicW226.require_true(flag == true || flag == false,
          "#{label} non-NULL actual lacks a raw shared Bool")
        flag
      end
    end

    def capture_dynamic_observation(profile, store, table, label_prefix)
      outer_array = profile.fetch('case_id') == 'outer_array_dynamic'
      if outer_array
        sql = "SELECT toString(pk) AS pk, arrayMap(x -> dynamicType(x), v) AS types, arrayMap(x -> isDynamicElementInSharedData(x), v) AS shared FROM default.#{table} ORDER BY pk FORMAT JSONEachRow"
      else
        sql = "SELECT toString(pk) AS pk, dynamicType(v) AS types, isDynamicElementInSharedData(v) AS shared FROM default.#{table} ORDER BY pk FORMAT JSONEachRow"
      end
      record = checked_success!(process("#{label_prefix}-placement-#{profile.fetch('id')}", store, sql), "#{label_prefix} placement query")
      rows = record.fetch('stdout').lines.map { |line| JSON.parse(line) }
      RecheckAggregateDynamicW226.require_true(rows.length == 5, "#{label_prefix} placement row count differs")
      types_grid = []
      shared_grid = []
      raw_types_grid = []
      raw_shared_grid = []
      rows.each_with_index do |row, index|
        RecheckAggregateDynamicW226.require_true(Integer(row.fetch('pk'), 10) == profile.fetch('row_keys').fetch(index),
          "#{label_prefix} placement order/key differs")
        if outer_array
          types = row.fetch('types')
          flags = row.fetch('shared')
          RecheckAggregateDynamicW226.require_true(types.is_a?(Array) && flags.is_a?(Array) && types.length == flags.length,
            "#{label_prefix} outer Dynamic placement grid shape differs")
          parsed_types = types.map { |type| parse_type(type) }
          types_grid << parsed_types
          shared_grid << flags.each_with_index.map do |flag, item_index|
            normalized_shared_flag(parsed_types.fetch(item_index), flag, "#{label_prefix} #{profile.fetch('id')} row #{index}")
          end
          raw_types_grid << types
          raw_shared_grid << flags
        else
          parsed_type = parse_type(row.fetch('types'))
          types_grid << [parsed_type]
          shared_grid << [normalized_shared_flag(parsed_type, row.fetch('shared'), "#{label_prefix} #{profile.fetch('id')} row #{index}")]
          # Keep the native JSONEachRow scalar observations flat; normalized
          # logical grids above remain one-element arrays per parent row.
          raw_types_grid << row.fetch('types')
          raw_shared_grid << row.fetch('shared')
        end
      end
      site = profile.fetch('site')
      roster = []
      types_grid.each_with_index do |types, row_index|
        types.each_with_index do |type, item_index|
          next if type == 'Nothing' || shared_grid.fetch(row_index).fetch(item_index)
          roster << type unless roster.include?(type)
        end
      end
      observed_types = { site => roster }
      observed_shared = { site => shared_grid }
      source_law!(profile, observed_types, observed_shared)
      { 'types_grid' => types_grid, 'raw_types_grid' => raw_types_grid, 'raw_shared_grid' => raw_shared_grid,
        'source_types' => observed_types, 'source_shared' => observed_shared,
        'placement_rows_json' => record.fetch('stdout'), 'process' => clean_record(record) }
    rescue JSON::ParserError => error
      RecheckAggregateDynamicW226.fail!("#{label_prefix} placement JSONEachRow invalid: #{error.message}")
    end

    def capture_stock_profile(profile, index)
      id = profile.fetch('id')
      table = table_name(profile)
      store = File.join(@source_root, 'stores', 'profiles', id)
      Dir.mkdir(store, 0o700)
      create = checked_success!(process("stock-create-#{id}", store, create_sql(profile, table)), "stock CREATE #{id}")
      literals = expected_rows(profile).join.b
      insert = checked_success!(process("stock-insert-#{id}", store,
        "INSERT INTO default.#{table} FORMAT RowBinary", input: literals), "stock RowBinary INSERT #{id}")
      check = checked_success!(process("stock-check-#{id}", store,
        "CHECK TABLE default.#{table} FORMAT TSVRaw"), "stock CHECK #{id}")
      RecheckAggregateDynamicW226.require_true(check.fetch('stdout') == expected_check, "stock CHECK differs for #{id}")
      windows = run_rowbinary('stock', profile, table, store)
      metadata = checked_success!(process("stock-metadata-#{id}", store,
        "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw"), "stock metadata #{id}")
      RecheckAggregateDynamicW226.require_true(metadata.fetch('stdout') == schema_output(profile), "stock exact schema differs for #{id}")
      type_name = checked_success!(process("stock-type-name-#{id}", store,
        "SELECT toTypeName(v) FROM default.#{table} LIMIT 1 FORMAT TSVRaw"), "stock toTypeName #{id}")
      RecheckAggregateDynamicW226.require_true(type_name.fetch('stdout') == "#{profile.fetch('declared_type')}\n",
        "stock toTypeName differs for #{id}")
      placement = capture_dynamic_observation(profile, store, table, 'stock')
      census = checked_success!(process("stock-part-#{id}", store,
        "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw"), "stock part census #{id}")
      census_rows = census.fetch('stdout').split("\n", -1)
      RecheckAggregateDynamicW226.require_true(census_rows.length == 2 && census_rows.last.empty?, "stock part census row shape differs for #{id}")
      fields = census_rows.first.split("\t", -1)
      original_part = File.expand_path(fields.fetch(4))
      RecheckAggregateDynamicW226.require_true(fields.length == 5 && fields.first(4) == ['all_1_1_0', '5', '4', 'Wide'],
        "stock part identity/grid differs for #{id}: #{fields.inspect}")
      strict_part_path!(fields.fetch(4), original_part, "stock original #{id}")
      source_part = part_path(profile)
      Dir.mkdir(File.dirname(source_part), 0o700)
      FileUtils.cp_r(original_part, source_part)
      source_inventory = inventory(source_part)
      source_serialization = JSON.parse(File.binread(File.join(source_part, 'serialization.json')))
      assert_serialization_profile!(source_serialization, profile, 'stock')
      RecheckAggregateDynamicW226.require_true(File.binread(File.join(source_part, 'metadata_version.txt')).strip == '0' &&
        File.binread(File.join(source_part, 'default_compression_codec.txt')).strip == 'CODEC(LZ4)',
        "stock part metadata version/codec differs for #{id}")
      profile['source_part_path'] = source_part
      profile['source_inventory'] = source_inventory
      profile['source_serialization'] = source_serialization
      profile['stock_windows'] = windows
      profile['stock_placement'] = placement
      profile['stock_processes'] = [create, insert, check, metadata, type_name, census, placement.fetch('process')].map { |row| clean_record(row) } +
        windows.values.map { |row| row.fetch('process') }
      profile['destination_path'] = File.join(@root, 'generated', 'parts', format('%02d-%s', index, id), 'all_1_1_0')
      Dir.mkdir(File.dirname(profile.fetch('destination_path')), 0o700)
      profile['expected_rowbinary_hex'] = expected_windows(profile).transform_values { |bytes| bytes.unpack1('H*') }
      profile['expected_source_rows_hex'] = expected_rows(profile).map { |bytes| bytes.unpack1('H*') }
      RecheckAggregateDynamicW226.write_json(File.join(@source_root, 'cases', 'profiles', "#{id}.json"), {
        'id' => id, 'case_id' => profile.fetch('case_id'), 'profile' => profile.fetch('profile'),
        'classification' => 'stock_physical_observed', 'declared_type' => profile.fetch('declared_type'),
        'source_part_path' => source_part, 'source_types' => placement.fetch('source_types'),
        'source_shared' => placement.fetch('source_shared'), 'types_grid' => placement.fetch('types_grid'),
        'mark_rows' => profile.fetch('mark_rows'), 'source_inventory' => source_inventory,
        'serialization_json' => source_serialization, 'rowbinary_windows' => windows,
        'check_output' => check.fetch('stdout'), 'processes' => profile.fetch('stock_processes') })
      @source_profiles << profile
    rescue JSON::ParserError => error
      RecheckAggregateDynamicW226.fail!("stock serialization metadata invalid for #{id}: #{error.message}")
    end

    def assert_serialization_profile!(serialization, profile, side)
      RecheckAggregateDynamicW226.require_true(serialization.is_a?(Hash) && serialization.fetch('version') == 1 &&
        serialization.fetch('propagate_types_serialization_versions_to_nested_types') == true &&
        serialization.fetch('types_serialization_versions').fetch('string') == STRING_VERSIONS.fetch(profile.fetch('profile')),
        "#{side} serialization metadata lacks exact type/version profile for #{profile.fetch('id')}")
      RecheckAggregateDynamicW226.require_true(File.binread(File.join(part_path(profile), 'count.txt')).strip == '5',
        "#{side} part count differs for #{profile.fetch('id')}") if side == 'stock'
    end

    def write_source_matrix
      matrix = { 'format' => FORMAT_MATRIX, 'profile_count' => @source_profiles.length,
        'source_pin' => @source_pin, 'runtime_pin' => @runtime_pin,
        'row_keys' => R::ROW_KEYS.map(&:to_i), 'mark_rows' => R::MARK_ROWS.map(&:to_i),
        'string_versions' => STRING_VERSIONS, 'dynamic_serialization_version' => 'v3',
        'variant_discriminator_mode' => 'BASIC', 'profiles' => @source_profiles.map do |profile|
          profile.reject { |key, _| key == 'rows' }
        end }
      matrix_path = File.join(@source_root, 'matrix.json')
      RecheckAggregateDynamicW226.write_json(matrix_path, matrix)
      @source_matrix_sha = Digest::SHA256.file(matrix_path).hexdigest
    end

    def invoke_helper
      input = { 'format' => FORMAT_INPUT, 'profiles' => @source_profiles.map do |profile|
        { 'id' => profile.fetch('id'), 'case_id' => profile.fetch('case_id'), 'profile' => profile.fetch('profile'),
          'declared_type' => profile.fetch('declared_type'), 'source_part_path' => profile.fetch('source_part_path'),
          'destination_path' => profile.fetch('destination_path'),
          'expected_rowbinary_hex' => profile.fetch('expected_rowbinary_hex'),
          'source_types' => profile.fetch('stock_placement').fetch('source_types'),
          'source_shared' => profile.fetch('stock_placement').fetch('source_shared') }
      end }
      input_path = File.join(@root, 'generated', 'helper-input.json')
      write_json(input_path, input)
      @helper_input_sha = Digest::SHA256.file(input_path).hexdigest
      sha_before = Digest::SHA256.file(@helper).hexdigest
      RecheckAggregateDynamicW226.require_true(sha_before == @expected_helper_sha && sha_before == @helper_sha_start,
        'prebuilt helper changed before launch or no longer matches external pin')
      argv = [@helper, input_path, File.join(@root, 'generated'), @source_root]
      record = process('generic-stock-read-library-write-read', @root, nil, timeout: R::HELPER_TIMEOUT_SECONDS, argv: argv)
      @helper_sha_after = Digest::SHA256.file(@helper).hexdigest
      RecheckAggregateDynamicW226.require_true(@helper_sha_after == @expected_helper_sha && @helper_sha_after == sha_before,
        'prebuilt helper changed during execution')
      checked_success!(record, 'prebuilt Crystal helper')
      output = JSON.parse(record.fetch('stdout'))
      RecheckAggregateDynamicW226.require_true(output.fetch('format') == FORMAT_HELPER &&
        output.fetch('profiles').length == @source_profiles.length &&
        output.fetch('profiles').map { |row| row.fetch('id') } == PROFILE_IDS,
        'W226 helper output format/count/profile roster differs')
      write_json(File.join(@root, 'generated', 'helper-output.json'), output)
      write_json(File.join(@root, 'generated', 'helper-process.json'), clean_record(record))
      @helper_process = clean_record(record)
      @helper_profiles = output.fetch('profiles')
      @helper_profiles.each_with_index { |item, index| validate_helper_profile(item, @source_profiles.fetch(index)) }
    rescue JSON::ParserError => error
      RecheckAggregateDynamicW226.fail!("W226 helper stdout is not one JSON value: #{error.message}")
    end

    def validate_helper_profile(item, profile)
      id = profile.fetch('id')
      destination = profile.fetch('destination_path')
      RecheckAggregateDynamicW226.require_true(item.fetch('id') == id && item.fetch('case_id') == profile.fetch('case_id') &&
        item.fetch('profile') == profile.fetch('profile') && item.fetch('type') == profile.fetch('declared_type'),
        "W226 helper profile identity/type differs for #{id}")
      RecheckAggregateDynamicW226.require_true(item.fetch('checks') == CHECKS,
        "W226 helper did not report the exact ordered check roster for #{id}")
      %w[stock_part library_part].each do |key|
        part = item.fetch(key)
        expected_path = key == 'stock_part' ? profile.fetch('source_part_path') : destination
        prefix = key == 'stock_part' ? 'source' : 'library'
        RecheckAggregateDynamicW226.require_true(part.fetch('path') == expected_path &&
          part.fetch('full_rowbinary_hex') == profile.fetch('expected_rowbinary_hex').fetch('full') &&
          part.fetch('middle_rowbinary_hex') == profile.fetch('expected_rowbinary_hex').fetch('middle') &&
          part.fetch('zero_rowbinary_hex') == profile.fetch('expected_rowbinary_hex').fetch('zero'),
          "helper #{prefix} value-body windows/path differ for #{id}")
      end
      expected_roles = { profile.fetch('site') => profile.fetch('source_types').fetch(profile.fetch('site')) }
      expected_roles = { 'root' => ['AggregateFunction(count)'] } if profile.fetch('case_id') == 'known_count_shared_sum'
      expected_roles = { 'root' => [] } if profile.fetch('case_id') == 'all_shared'
      expected_roles = { 'root' => ['Array(AggregateFunction(sum, UInt8))'] } if profile.fetch('case_id') == 'actual_array_sum'
      expected_roles = { 'root.elements' => ['AggregateFunction(count)'] } if profile.fetch('case_id') == 'outer_array_dynamic'
      roles = item.fetch('logicalroles')
      roles_match = roles.is_a?(Hash) && %w[stock library].all? { |side|
        roles.fetch(side).is_a?(Hash) && roles.fetch(side).fetch('ordinary') == expected_roles
      }
      RecheckAggregateDynamicW226.require_true(roles_match,
        "helper stock/library ordinary roles differ from finite source roster for #{id}")
      RecheckAggregateDynamicW226.require_true(item.fetch('mark_rows') == R::MARK_ROWS.map(&:to_i),
        "helper mark-row schedule differs from finite W226 fixture for #{id}")
      RecheckAggregateDynamicW226.require_true(item.fetch('pqr') == expected_pqr(profile),
        "helper P/Q/R occurrence schedule differs from finite W226 fixture for #{id}")
      streams = item.fetch('physicalstreams')
      streams_match = streams.is_a?(Hash) && %w[stock library].all? { |side|
        names = streams.fetch(side)
        names.is_a?(Array) && names == names.sort && names.all? { |name| name.is_a?(String) && !name.empty? } && names.uniq.length == names.length
      }
      RecheckAggregateDynamicW226.require_true(streams_match, "helper physical stream roster has an invalid shape for #{id}")
      RecheckAggregateDynamicW226.require_true(streams.fetch('stock') == streams.fetch('library'),
        "helper stock/library physical streams differ for #{id}")
      signatures = item.fetch('owned_signatures')
      RecheckAggregateDynamicW226.require_true(signatures == expected_signatures(profile),
        "helper owned values differ from independent signature literals for #{id}")
      library_path = item.fetch('library_part').fetch('path')
      RecheckAggregateDynamicW226.require_true(library_path == destination && File.directory?(destination) &&
        !File.symlink?(destination) && File.realpath(destination) == destination,
        "helper library part is absent or escaped destination for #{id}")
      library_inventory = inventory(destination)
      @library_inventories[id] = library_inventory
      RecheckAggregateDynamicW226.require_true(inventory(profile.fetch('source_part_path')) == profile.fetch('source_inventory'),
        "helper altered or changed stock part inventory for #{id}")
      RecheckAggregateDynamicW226.write_json(File.join(@root, 'cases', "#{id}-helper.json"), {
        'id' => id, 'case_id' => profile.fetch('case_id'), 'profile' => profile.fetch('profile'),
        'declared_type' => profile.fetch('declared_type'), 'stock_part_path' => profile.fetch('source_part_path'),
        'library_part_path' => destination, 'stock_inventory' => profile.fetch('source_inventory'),
        'library_inventory' => library_inventory, 'helper_profile' => item })
    end

    def create_native_targets
      @profiles.each do |profile|
        id = profile.fetch('id')
        store = File.join(@root, 'stores', 'native', id)
        Dir.mkdir(store, 0o700)
        table = table_name(profile, native: true)
        checked_success!(process("native-create-#{id}", store, create_sql(profile, table)), "native CREATE #{id}")
        data = checked_success!(process("native-data-path-#{id}", store,
          "SELECT arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw"), "native data path #{id}")
        data_path = File.expand_path(data.fetch('stdout').strip)
        RecheckAggregateDynamicW226.require_true(data_path.start_with?(store + File::SEPARATOR) &&
          File.directory?(data_path) && !File.symlink?(data_path) && File.realpath(data_path) == data_path,
          "native target data path escaped isolated store for #{id}")
        detached = File.join(data_path, 'detached')
        RecheckAggregateDynamicW226.require_true(File.directory?(detached) && !File.symlink?(detached) && File.realpath(detached) == detached,
          "native detached directory is invalid for #{id}")
        @targets[id] = { 'store' => store, 'table' => table, 'data_path' => data_path,
          'detached_path' => File.join(detached, 'all_1_1_0'), 'data_path_process' => clean_record(data) }
      end
    end

    def compare_file_delta!(generated, attached, id)
      before = Hash[inventory(generated).map { |entry| [entry.fetch('path'), entry] }]
      after_entries = inventory(attached)
      after = Hash[after_entries.map { |entry| [entry.fetch('path'), entry] }]
      removed = before.keys - after.keys
      changed = before.keys.select { |path| after.key?(path) && before.fetch(path) != after.fetch(path) }
      added = after.keys - before.keys
      RecheckAggregateDynamicW226.require_true(removed.empty? && changed.empty? && added == [INVALIDATED_FILE],
        "ATTACH modified unexpected generated part files for #{id}: removed=#{removed.inspect}, changed=#{changed.inspect}, added=#{added.inspect}")
      aux = File.binread(File.join(attached, INVALIDATED_FILE)).split("\n", -1)
      RecheckAggregateDynamicW226.require_true(aux.pop == '' && aux.sort == INVALIDATED_NAMES.sort,
        "ATTACH auxiliary invalidated columns differ for #{id}")
      { 'removed' => removed, 'changed' => changed, 'added' => added, 'attached_inventory' => after_entries }
    end

    def attach_library_part(profile, helper_profile, index)
      id = profile.fetch('id')
      target = @targets.fetch(id)
      generated = profile.fetch('destination_path')
      RecheckAggregateDynamicW226.require_true(@library_inventories.fetch(id) == inventory(generated),
        "helper generated inventory changed before ATTACH for #{id}")
      FileUtils.cp_r(generated, target.fetch('detached_path'))
      RecheckAggregateDynamicW226.require_true(inventory(target.fetch('detached_path')) == inventory(generated),
        "detached library part copy differs for #{id}")
      attach = checked_success!(process("native-attach-#{id}", target.fetch('store'),
        "ALTER TABLE default.#{target.fetch('table')} ATTACH PART 'all_1_1_0'"), "native ATTACH #{id}")
      check = checked_success!(process("native-check-#{id}", target.fetch('store'),
        "CHECK TABLE default.#{target.fetch('table')} FORMAT TSVRaw"), "native CHECK #{id}")
      RecheckAggregateDynamicW226.require_true(check.fetch('stdout') == expected_check, "attached CHECK differs for #{id}")
      metadata = checked_success!(process("native-metadata-#{id}", target.fetch('store'),
        "SELECT name, type FROM system.columns WHERE database='default' AND table='#{target.fetch('table')}' ORDER BY position FORMAT TSVRaw"), "native metadata #{id}")
      RecheckAggregateDynamicW226.require_true(metadata.fetch('stdout') == schema_output(profile), "attached schema differs for #{id}")
      type_name = checked_success!(process("native-type-name-#{id}", target.fetch('store'),
        "SELECT toTypeName(v) FROM default.#{target.fetch('table')} LIMIT 1 FORMAT TSVRaw"), "native toTypeName #{id}")
      RecheckAggregateDynamicW226.require_true(type_name.fetch('stdout') == "#{profile.fetch('declared_type')}\n",
        "attached toTypeName differs for #{id}")
      placement = capture_dynamic_observation(profile, target.fetch('store'), target.fetch('table'), 'native')
      census = checked_success!(process("native-part-#{id}", target.fetch('store'),
        "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{target.fetch('table')}' AND active ORDER BY name FORMAT TSVRaw"), "native part census #{id}")
      rows = census.fetch('stdout').split("\n", -1)
      RecheckAggregateDynamicW226.require_true(rows.length == 2 && rows.last.empty?, "attached part census shape differs for #{id}")
      fields = rows.first.split("\t", -1)
      attached_path = File.join(target.fetch('data_path'), 'all_1_1_0')
      RecheckAggregateDynamicW226.require_true(fields.length == 5 && fields.first(4) == ['all_1_1_0', '5', '4', 'Wide'],
        "attached part identity/grid differs for #{id}")
      strict_part_path!(fields.fetch(4), attached_path, "attached part #{id}")
      delta = compare_file_delta!(generated, attached_path, id)
      columns = File.binread(File.join(attached_path, 'columns.txt')).force_encoding(Encoding::UTF_8).scrub
      expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`v` #{profile.fetch('declared_type')}\n"
      RecheckAggregateDynamicW226.require_true(columns == expected_columns, "attached columns.txt declaration differs for #{id}")
      serialization = JSON.parse(File.binread(File.join(attached_path, 'serialization.json')))
      assert_serialization_profile!(serialization, profile, 'library')
      RecheckAggregateDynamicW226.require_true(serialization == JSON.parse(File.binread(File.join(generated, 'serialization.json'))),
        "ATTACH changed library serialization metadata for #{id}")
      RecheckAggregateDynamicW226.require_true(File.binread(File.join(attached_path, 'metadata_version.txt')).strip == '0' &&
        File.binread(File.join(attached_path, 'default_compression_codec.txt')).strip == 'CODEC(LZ4)' &&
        File.binread(File.join(attached_path, 'count.txt')).strip == '5', "attached codec/count/metadata differs for #{id}")
      windows = run_rowbinary('native', profile, target.fetch('table'), target.fetch('store'))
      RecheckAggregateDynamicW226.require_true(placement.fetch('source_types') == profile.fetch('source_types') &&
        placement.fetch('source_shared') == profile.fetch('source_shared'), "attached placement law differs for #{id}")
      record = { 'id' => id, 'case_id' => profile.fetch('case_id'), 'profile' => profile.fetch('profile'),
        'classification' => 'native_attached_check_and_rowbinary_observed', 'declared_type' => profile.fetch('declared_type'),
        'native_schema' => metadata.fetch('stdout'), 'type_name' => type_name.fetch('stdout'),
        'placement' => placement, 'source_types' => profile.fetch('source_types'), 'source_shared' => profile.fetch('source_shared'),
        'mark_rows' => R::MARK_ROWS, 'check_output' => check.fetch('stdout'), 'serialization_json' => serialization,
        'columns_txt' => columns, 'rowbinary_windows' => windows, 'generated_inventory' => inventory(generated),
        'attached_inventory' => delta.fetch('attached_inventory'), 'file_delta' => delta,
        'processes' => [target.fetch('data_path_process'), clean_record(attach), clean_record(check), clean_record(metadata),
          clean_record(type_name), clean_record(census), clean_record(placement.fetch('process'))] + windows.values.map { |item| item.fetch('process') } }
      @native_records << record
      write_json(File.join(@root, 'cases', "#{id}-attached.json"), record)
    rescue JSON::ParserError => error
      RecheckAggregateDynamicW226.fail!("attached serialization metadata invalid for #{id}: #{error.message}")
    end

    def expected_labels
      labels = %w[runtime-version-pin runtime-build-pin generic-stock-read-library-write-read]
      @profiles.each do |profile|
        id = profile.fetch('id')
        labels.concat(%W[stock-create-#{id} stock-insert-#{id} stock-check-#{id} stock-metadata-#{id}
          stock-type-name-#{id} stock-placement-#{id} stock-part-#{id} stock-rowbinary-#{id}-full
          stock-rowbinary-#{id}-middle stock-rowbinary-#{id}-zero])
        labels.concat(%W[native-create-#{id} native-data-path-#{id} native-attach-#{id} native-check-#{id}
          native-metadata-#{id} native-type-name-#{id} native-placement-#{id} native-part-#{id}
          native-rowbinary-#{id}-full native-rowbinary-#{id}-middle native-rowbinary-#{id}-zero])
      end
      labels
    end

    def verify_invocations
      labels = @recorder.records.map { |record| record.fetch('label') }
      RecheckAggregateDynamicW226.require_true(labels.uniq.length == labels.length && labels.sort == expected_labels.sort,
        'exact W226 process invocation roster differs')
      @recorder.records.each do |record|
        RecheckAggregateDynamicW226.require_true(record.fetch('classification') == 'process_success' &&
          record.fetch('exitstatus') == 0 && !record.fetch('signaled') && !record.fetch('timed_out') && !record.fetch('spawn_error'),
          "W226 process failed: #{record.fetch('label')}")
      end
    end

    def write_summary(classification)
      return unless @root && File.directory?(@root) && !File.exist?(File.join(@root, 'summary.json'))
      records = @recorder ? @recorder.records : []
      summary = { 'format' => FORMAT_SUMMARY, 'classification' => classification,
        'success' => classification == 'paired_dynamic_aggregate_profiles_observed', 'error' => @fatal,
        'source_root' => @source_root, 'evidence_root' => @root, 'source_pin' => @source_pin,
        'runtime_pin' => @runtime_pin, 'helper_sha256_expected' => @expected_helper_sha,
        'helper_sha256_at_start' => @helper_sha_start, 'helper_sha256_after_execute' => @helper_sha_after,
        'helper_input_sha256' => @helper_input_sha, 'source_matrix_sha256' => @source_matrix_sha,
        'counts' => { 'profiles_expected' => PROFILE_IDS.length, 'stock_profiles' => @source_profiles.length,
          'helper_profiles' => @helper_profiles.length, 'native_profiles' => @native_records.length,
          'processes' => records.length },
        'process_status_counts' => { 'success_exit0' => records.count { |item| item.fetch('classification') == 'process_success' },
          'nonzero_or_signaled' => records.count { |item| item.fetch('classification') == 'process_nonzero_or_signaled_exit' },
          'timeout' => records.count { |item| item.fetch('classification') == 'process_timeout' },
          'spawn_failure' => records.count { |item| item.fetch('classification') == 'spawn_failure' } } }
      write_json(File.join(@root, 'summary.json'), summary)
      write_json(File.join(@source_root, 'source_pin.json'), @source_pin) if @source_pin
      write_json(File.join(@source_root, 'runtime_pin.json'), @runtime_pin) if @runtime_pin
    end
  end

  def main(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/recheck_aggregate_dynamic_w226.rb --clickhouse BIN --helper HELPER --helper-sha256 HEX --source-root EMPTY_DIR --evidence-root EMPTY_DIR'
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
    warn "W226 runner setup failure: #{error.class}: #{error.message}"
    false
  end
end

exit(RecheckAggregateDynamicW226.main(ARGV) ? 0 : 1) if $PROGRAM_NAME == __FILE__
