#!/usr/bin/env ruby
# Stock-only persistence discriminator for Nested inside typed JSON paths.
# It records native ClickHouse behavior and independent RowBinary literals;
# it does not change or admit any Crystal library type.

require 'digest'
require 'json'
require 'optparse'
require_relative 'recheck_object_declared_qbit_stock_w235'

module RecheckObjectDeclaredNestedStockW236
  extend self

  Q = RecheckObjectDeclaredQBitStockW235
  R = Q::R
  SOURCE_ROOT = Q::SOURCE_ROOT.freeze
  SOURCE_REVISION = Q::SOURCE_REVISION.freeze
  CLICKHOUSE_BIN = Q::CLICKHOUSE_BIN
  CLICKHOUSE_SHA256 = Q::CLICKHOUSE_SHA256
  CLICKHOUSE_VERSION = Q::CLICKHOUSE_VERSION.freeze
  CLICKHOUSE_BUILD = Q::CLICKHOUSE_BUILD.freeze

  ROOT_PREFIX = 'crystal-click-w236-stock.'.freeze
  PROCESS_TIMEOUT_SECONDS = 90
  MAX_EXECUTION_SECONDS = 30
  MEMORY_LIMIT_BYTES = 1_073_741_824
  MAX_PROCESS_COUNT = 64
  ROW_KEYS = [1, 2, 3, 4, 5, 6].freeze
  MARK_ROWS = [2, 2, 2].freeze
  PART_MARKS = 4
  STOCK_SETTINGS = Q::STOCK_SETTINGS

  NESTED_TYPE = 'Nested(n UInt8, s String)'.freeze
  ARRAY_TUPLE_TYPE = 'Array(Tuple(n UInt8, s String))'.freeze
  DIRECT_TYPE = NESTED_TYPE
  ARRAY_TYPE = "Array(#{NESTED_TYPE})".freeze
  TUPLE_TYPE = "Tuple(items #{NESTED_TYPE}, tag UInt8)".freeze
  MAP_TYPE = "Map(String, #{NESTED_TYPE})".freeze
  VARIANT_TYPE = "Variant(#{NESTED_TYPE}, String)".freeze

  # Input values are six independent source literals per profile. nil means
  # that the JSON object has no q path; [] is an explicitly present empty value.
  PROFILES = [
    {
      'id' => 'direct_nested', 'table' => 'w236_json_nested_direct',
      'type' => DIRECT_TYPE, 'kind' => 'nested',
      'canonical_type' => ARRAY_TUPLE_TYPE,
      'row_values' => [
        [[1, 'a'], [2, 'long']], [], nil, [[255, 'x']],
        [[0, 'left'], [17, 'r'], [42, 'longer-right']], nil,
      ],
      'expected_body_hex' => [
        '0201016102046c6f6e67', '00', '00', '01ff0178',
        '0300046c6566741101722a0c6c6f6e6765722d7269676874', '00',
      ],
    },
    {
      'id' => 'array_nested', 'table' => 'w236_json_nested_array',
      'type' => ARRAY_TYPE, 'kind' => 'array_nested',
      'canonical_type' => "Array(#{ARRAY_TUPLE_TYPE})",
      'row_values' => [
        [[[1, 'a'], [2, 'long']], [[3, 'm']]], [], nil, [[]],
        [[[0, 'left'], [17, 'r']]], [[[4, 'tail'], [8, 'x']], [[9, 'long']]],
      ],
      'expected_body_hex' => [
        '020201016102046c6f6e670103016d', '00', '00', '0100',
        '010200046c656674110172', '020204047461696c0801780109046c6f6e67',
      ],
    },
    {
      'id' => 'tuple_nested', 'table' => 'w236_json_nested_tuple',
      'type' => TUPLE_TYPE, 'kind' => 'tuple_nested',
      'canonical_type' => "Tuple(items #{ARRAY_TUPLE_TYPE}, tag UInt8)",
      'row_values' => [
        { 'items' => [[1, 't'], [2, 'side']], 'tag' => 7 },
        { 'items' => [], 'tag' => 9 }, nil,
        { 'items' => [[255, 'x']], 'tag' => 255 },
        { 'items' => [[0, 'left'], [17, 'r'], [42, 'longer-right']], 'tag' => 5 },
        { 'items' => [], 'tag' => 0 },
      ],
      'expected_body_hex' => [
        '0201017402047369646507', '0009', '0000', '01ff0178ff',
        '0300046c6566741101722a0c6c6f6e6765722d726967687405', '0000',
      ],
    },
    {
      'id' => 'map_nested', 'table' => 'w236_json_nested_map',
      'type' => MAP_TYPE, 'kind' => 'map_nested',
      'canonical_type' => "Map(String, #{ARRAY_TUPLE_TYPE})",
      'row_values' => [
        [['a', [[1, 'a'], [2, 'long']]], ['long-key', [[3, 'm']]]],
        [], nil, [['x', []]],
        [['left', [[0, 'left'], [17, 'r'], [42, 'longer-right']]]],
        [['tail', [[9, 'z']]]],
      ],
      'expected_body_hex' => [
        '0201610201016102046c6f6e67086c6f6e672d6b65790103016d',
        '00', '00', '01017800',
        '01046c6566740300046c6566741101722a0c6c6f6e6765722d7269676874',
        '01047461696c0109017a',
      ],
    },
    {
      'id' => 'variant_nested', 'table' => 'w236_json_nested_variant',
      'type' => VARIANT_TYPE, 'kind' => 'variant_nested',
      'canonical_type' => "Variant(#{ARRAY_TUPLE_TYPE}, String)",
      'row_values' => [
        { 'variant' => 'nested', 'value' => [[1, 'a'], [2, 'long']] },
        { 'variant' => 'string', 'value' => 'v' }, nil,
        { 'variant' => 'nested', 'value' => [[255, 'x']] },
        { 'variant' => 'string', 'value' => 'much-longer' },
        { 'variant' => 'nested', 'value' => [[0, 'left'], [17, 'r'], [42, 'longer-right']] },
      ],
      'expected_body_hex' => [
        '000201016102046c6f6e67', '010176', 'ff', '0001ff0178',
        '010b6d7563682d6c6f6e676572',
        '000300046c6566741101722a0c6c6f6e6765722d7269676874',
      ],
    },
  ].map { |profile| profile.freeze }.freeze

  CONTROL_ID = 'ordinary_json_control'.freeze
  CONTROL_TABLE = 'w236_json_positive_control'.freeze
  CONTROL_ROWS = [
    { 'q' => 7, 'xs' => [1, 2] },
    { 'xs' => [] },
    { 'q' => 255, 'xs' => [8] },
    { 'q' => 0, 'xs' => [3, 4, 5] },
    {},
    { 'q' => 42, 'xs' => [9, 0] },
  ].freeze
  CONTROL_EXPECTED_ROW_HEX = [
    '010000000000000007020102',
    '02000000000000000000',
    '0300000000000000ff0108',
    '04000000000000000003030405',
    '05000000000000000000',
    '06000000000000002a020900',
  ].freeze

  def fail!(message)
    raise ArgumentError, message
  end

  def require_true(condition, message)
    fail!(message) unless condition
  end

  def validate_root(path)
    full = File.expand_path(path)
    require_true(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full && Dir.children(full).empty?,
      'capture root must be a fresh, empty, canonical directory')
    require_true(File.dirname(full) == File.realpath('/private/tmp') && File.basename(full).start_with?(ROOT_PREFIX),
      "capture root must be a direct /private/tmp child named #{ROOT_PREFIX}*")
    full
  end

  def validate_binary(path)
    full = Q.validate_binary(path)
    require_true(full == CLICKHOUSE_BIN && Digest::SHA256.file(full).hexdigest == CLICKHOUSE_SHA256,
      'runtime differs from the W236 fixed path/SHA pin')
    full
  end

  def varuint(value)
    require_true(value.is_a?(Integer) && value >= 0 && value <= 18_446_744_073_709_551_615,
      "invalid VarUInt literal: #{value.inspect}")
    bytes = []
    while value >= 0x80
      bytes << ((value & 0x7f) | 0x80)
      value >>= 7
    end
    (bytes << value).pack('C*').b
  end

  def uint64(value)
    require_true(value.is_a?(Integer) && value >= 0 && value <= 18_446_744_073_709_551_615,
      "invalid UInt64 literal: #{value.inspect}")
    Array.new(8) { |index| (value >> (index * 8)) & 0xff }.pack('C*').b
  end

  def string_bytes(value)
    bytes = value.encode(Encoding::UTF_8).b
    varuint(bytes.bytesize) + bytes
  end

  def nested_body(rows)
    require_true(rows.is_a?(Array), 'Nested literal must be an array of tuples')
    serialized = rows.map do |tuple|
      require_true(tuple.is_a?(Array) && tuple.length == 2, 'Nested tuple literal must have exactly n and s')
      number, string = tuple
      require_true(number.is_a?(Integer) && number.between?(0, 255), 'Nested n literal is not UInt8')
      require_true(string.is_a?(String), 'Nested s literal is not String')
      [number].pack('C').b + string_bytes(string)
    end.join.b
    varuint(rows.length) + serialized
  end

  def serialize_value(profile, value)
    case profile.fetch('kind')
    when 'nested'
      nested_body(value)
    when 'array_nested'
      require_true(value.is_a?(Array), 'Array(Nested) literal must be an array')
      varuint(value.length) + value.map { |nested| nested_body(nested) }.join.b
    when 'tuple_nested'
      require_true(value.is_a?(Hash), 'Tuple literal must contain items and tag')
      tag = value.fetch('tag')
      require_true(tag.is_a?(Integer) && tag.between?(0, 255), 'Tuple tag literal is not UInt8')
      nested_body(value.fetch('items')) + [tag].pack('C').b
    when 'map_nested'
      require_true(value.is_a?(Array), 'Map literal must be an array of key/value pairs')
      serialized = value.map do |pair|
        require_true(pair.is_a?(Array) && pair.length == 2 && pair.fetch(0).is_a?(String),
          'Map literal pair must contain a String key and Nested value')
        string_bytes(pair.fetch(0)) + nested_body(pair.fetch(1))
      end.join.b
      varuint(value.length) + serialized
    when 'variant_nested'
      require_true(value.is_a?(Hash), 'Variant literal must identify its arm and value')
      case value.fetch('variant')
      when 'nested'
        [0].pack('C').b + nested_body(value.fetch('value'))
      when 'string'
        [1].pack('C').b + string_bytes(value.fetch('value'))
      else
        fail!("unlisted Variant arm: #{value.fetch('variant').inspect}")
      end
    else
      fail!("unlisted Nested profile kind: #{profile.fetch('kind').inspect}")
    end
  end

  def object_rowbinary_input(profile)
    profile.fetch('row_values').each_with_index.map do |value, index|
      object = if value.nil?
                 varuint(0)
               else
                 varuint(1) + string_bytes('q') + serialize_value(profile, value)
               end
      uint64(ROW_KEYS.fetch(index)) + object
    end.join.b
  end

  def expected_rows(profile)
    profile.fetch('expected_body_hex').each_with_index.map do |hex, index|
      require_true(hex.match?(/\A(?:[0-9a-f]{2})*\z/), 'expected output body is not literal hex')
      uint64(ROW_KEYS.fetch(index)) + [hex].pack('H*').b
    end
  end

  def control_input
    CONTROL_ROWS.each_with_index.map do |row, index|
      entries = row.sort_by { |path, _value| path }
      object = varuint(entries.length)
      entries.each do |path, value|
        object << string_bytes(path)
        case path
        when 'q'
          require_true(value.is_a?(Integer) && value.between?(0, 255), 'control q literal is not UInt8')
          object << [value].pack('C').b
        when 'xs'
          require_true(value.is_a?(Array) && value.all? { |item| item.is_a?(Integer) && item.between?(0, 255) },
            'control xs literal is not Array(UInt8)')
          object << varuint(value.length) << value.pack('C*').b
        else
          fail!("unlisted control path: #{path.inspect}")
        end
      end
      uint64(ROW_KEYS.fetch(index)) + object
    end.join.b
  end

  def create_sql(profile)
    "CREATE TABLE default.#{profile.fetch('table')} (id UInt64, j JSON(q #{profile.fetch('type')})) " \
      "ENGINE=MergeTree ORDER BY id SETTINGS #{STOCK_SETTINGS.join(', ')}"
  end

  def control_create_sql
    "CREATE TABLE default.#{CONTROL_TABLE} (id UInt64, j JSON(q UInt8, xs Array(UInt8))) " \
      "ENGINE=MergeTree ORDER BY id SETTINGS #{STOCK_SETTINGS.join(', ')}"
  end

  def schema_sql(table)
    "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw"
  end

  def check_sql(table)
    "CHECK TABLE default.#{table} FORMAT TSVRaw"
  end

  def part_sql(table)
    "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts " \
      "WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw"
  end

  def window_sql(table, window, control: false)
    predicate = { 'full' => '', 'middle' => ' WHERE id BETWEEN 3 AND 4', 'empty' => ' WHERE id=0' }.fetch(window)
    columns = control ? 'id, j.q, j.xs' : 'id, j.q'
    "SELECT #{columns} FROM default.#{table}#{predicate} ORDER BY id " \
      'SETTINGS output_format_binary_write_json_as_string=0 FORMAT RowBinary'
  end

  def expected_schema_spellings(profile)
    nominal = "id\tUInt64\nj\tJSON(q #{profile.fetch('type')})\n"
    canonical = "id\tUInt64\nj\tJSON(q #{profile.fetch('canonical_type')})\n"
    [nominal, canonical].uniq
  end

  class Probe
    def initialize(options)
      @binary = RecheckObjectDeclaredNestedStockW236.validate_binary(options.fetch(:clickhouse))
      @root = RecheckObjectDeclaredNestedStockW236.validate_root(options.fetch(:capture_root))
      @recorder = R::Recorder.new(@root, @binary)
      @stores = {}
      @part_records = []
      @profile_records = []
      @fatal_error = nil
    end

    def run
      prepare_layout
      pin_runtime
      PROFILES.each { |profile| run_profile(profile) }
      run_control
      save_evidence
      expected_ids = PROFILES.map { |profile| profile.fetch('id') } + [CONTROL_ID]
      success = @profile_records.map { |item| item.fetch('id') } == expected_ids &&
        @part_records.map { |item| item.fetch('id') } == expected_ids &&
        @profile_records.all? { |item| item.fetch('status') == 'persisted_and_literal_rowbinary_matched' }
      puts JSON.generate(
        'status' => success ? 'all_profiles_persisted_and_literal_windows_matched' : 'stock_discriminator_inconclusive',
        'runtime_version' => CLICKHOUSE_VERSION, 'runtime_build' => CLICKHOUSE_BUILD,
        'invocations' => @recorder.records.length, 'capture_root' => @root,
        'profiles' => @profile_records.map { |item|
          { 'id' => item.fetch('id'), 'status' => item.fetch('status'),
            'nested_type_spelling_class' => item.fetch('nested_type_spelling_class') }
        },
      )
      success
    rescue StandardError => error
      @fatal_error = "#{error.class}: #{error.message}"
      warn "W236 stock discriminator stopped with raw captures preserved: #{@fatal_error}"
      begin
        save_evidence
      rescue StandardError => evidence_error
        warn "W236 partial evidence index could not be completed: #{evidence_error.class}: #{evidence_error.message}"
      end
      false
    end

    private

    def prepare_layout
      R.make_dir(File.join(@root, 'invocations'))
      R.make_dir(File.join(@root, 'literal_rowbinary'))
      R.make_dir(File.join(@root, 'stores'))
      profiles = PROFILES.map { |profile| [profile.fetch('id'), profile.fetch('table')] } + [[CONTROL_ID, CONTROL_TABLE]]
      profiles.each do |id, _table|
        store = File.join(@root, 'stores', id)
        R.make_dir(store)
        @stores[id] = store
      end
    end

    def process_success?(record)
      record.fetch('classification') == 'process_success' && record.fetch('exitstatus') == 0 &&
        record.fetch('signaled') == false && record.fetch('timed_out') == false &&
        record.fetch('termsig').nil? && record.fetch('spawn_error').nil?
    end

    def failure_kind(record)
      return 'timeout' if record.fetch('timed_out')
      return 'spawn_or_plumbing_failure' if record.fetch('spawn_error')
      return 'signal' if record.fetch('signaled') || record.fetch('termsig')
      return 'native_nonzero_exit_unclassified' if record.fetch('exitstatus') && record.fetch('exitstatus') != 0

      'unexpected_process_outcome'
    end

    def capture_ref(record)
      "invocations/#{File.basename(record.fetch('path'))}"
    end

    def process_summary(record)
      {
        'classification' => record.fetch('classification'),
        'exitstatus' => record.fetch('exitstatus'), 'signaled' => record.fetch('signaled'),
        'termsig' => record.fetch('termsig'), 'timed_out' => record.fetch('timed_out'),
        'spawn_error' => record.fetch('spawn_error'), 'duration_ms' => record.fetch('duration_ms'),
        'stdout_bytes' => record.fetch('stdout_bytes'), 'stderr_bytes' => record.fetch('stderr_bytes'),
        'stdout_sha256' => Digest::SHA256.hexdigest(record.fetch('stdout')),
        'stderr_sha256' => Digest::SHA256.hexdigest(record.fetch('stderr')),
        'failure_kind' => process_success?(record) ? nil : failure_kind(record),
        'capture_prefix' => capture_ref(record),
      }
    end

    def invoke(label, store_id, sql, input: nil)
      RecheckObjectDeclaredNestedStockW236.require_true(@recorder.records.length < MAX_PROCESS_COUNT,
        'fixed W236 child-process cap exceeded')
      store = @stores.fetch(store_id)
      argv = RecheckRecursiveQBitDynamicW233.clickhouse_argv(@binary, store, sql)
      RecheckObjectDeclaredNestedStockW236.require_true(
        argv.include?("--max_execution_time=#{MAX_EXECUTION_SECONDS}") &&
          argv.include?("--max_memory_usage=#{MEMORY_LIMIT_BYTES}"),
        'reused W235 argv builder no longer supplies the W236 execution and memory bounds')
      @recorder.run(label, store, sql, input: input, timeout: PROCESS_TIMEOUT_SECONDS,
        argv: argv)
    end

    def pin_runtime
      store_id = PROFILES.first.fetch('id')
      version = invoke('runtime-version', store_id, 'SELECT version() FORMAT TSVRaw')
      RecheckObjectDeclaredNestedStockW236.require_true(
        process_success?(version) && version.fetch('stdout') == "#{CLICKHOUSE_VERSION}\n",
        'runtime version differs from the W236 pin')
      build = invoke('runtime-build', store_id,
        "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw")
      RecheckObjectDeclaredNestedStockW236.require_true(
        process_success?(build) && build.fetch('stdout') == "VERSION_GITHASH=#{CLICKHOUSE_BUILD}\n",
        'runtime build hash differs from the W236 pin')
      @runtime_pin = {
        'path' => @binary, 'sha256' => CLICKHOUSE_SHA256, 'version' => CLICKHOUSE_VERSION,
        'build_hash' => CLICKHOUSE_BUILD,
        'source_revision_is_separately_pinned_not_asserted_as_runtime_lineage' => true,
        'version_capture' => capture_ref(version), 'build_capture' => capture_ref(build),
      }
    end

    def new_profile_record(profile, control: false)
      {
        'id' => profile.fetch('id'), 'table' => profile.fetch('table'),
        'declared_type' => control ? 'JSON(q UInt8, xs Array(UInt8))' : "JSON(q #{profile.fetch('type')})",
        'nested_type_spelling_class' => control ? 'not_applicable' : nil,
        'expected_schema_spellings' => control ? ["id\tUInt64\nj\tJSON(q UInt8, xs Array(UInt8))\n"] :
          RecheckObjectDeclaredNestedStockW236.expected_schema_spellings(profile),
        'row_keys' => ROW_KEYS, 'rows_per_mark' => MARK_ROWS, 'part_type_expected' => 'Wide',
        'part_marks_expected' => PART_MARKS,
        'row_values' => if control
                          ROW_KEYS.each_with_index.map do |id, index|
                            { 'id' => id, 'q_present' => CONTROL_ROWS.fetch(index).key?('q'),
                              'xs_present' => CONTROL_ROWS.fetch(index).key?('xs'), 'value' => CONTROL_ROWS.fetch(index) }
                          end
                        else
                          ROW_KEYS.each_with_index.map do |id, index|
                            value = profile.fetch('row_values').fetch(index)
                            { 'id' => id, 'q_present' => !value.nil?, 'value' => value }
                          end
                        end,
        'steps' => {}, 'rowbinary_windows' => {}, 'failures' => [],
        'status' => 'in_progress',
      }
    end

    def add_failure(record, step, reason, detail = nil)
      failure = { 'step' => step, 'reason' => reason }
      failure['detail'] = detail if detail
      record.fetch('failures') << failure
    end

    def run_profile(profile)
      record = new_profile_record(profile)
      @profile_records << record
      begin
        input = RecheckObjectDeclaredNestedStockW236.object_rowbinary_input(profile)
        input_name = "#{profile.fetch('id')}-input.rowbin"
        R.write_new(File.join(@root, 'literal_rowbinary', input_name), input)
        record['input_literal'] = "literal_rowbinary/#{input_name}"

        create = invoke("#{profile.fetch('id')}-create", profile.fetch('id'),
          RecheckObjectDeclaredNestedStockW236.create_sql(profile))
        record.fetch('steps')['create'] = process_summary(create)
        unless process_success?(create)
          add_failure(record, 'create', failure_kind(create))
          record['status'] = 'native_or_plumbing_create_failure'
          return
        end

        schema = invoke("#{profile.fetch('id')}-schema", profile.fetch('id'),
          RecheckObjectDeclaredNestedStockW236.schema_sql(profile.fetch('table')))
        record.fetch('steps')['schema'] = process_summary(schema)
        unless process_success?(schema)
          add_failure(record, 'schema', failure_kind(schema))
          record['status'] = 'schema_query_failure'
          return
        end
        schema_text = schema.fetch('stdout').dup.force_encoding(Encoding::UTF_8).scrub
        record['schema_stdout'] = schema_text
        accepted_schemas = RecheckObjectDeclaredNestedStockW236.expected_schema_spellings(profile)
        if schema.fetch('stdout') == accepted_schemas.first
          record['nested_type_spelling_class'] = 'nominal_custom_nested_name_preserved'
        elsif schema.fetch('stdout') == accepted_schemas.last
          record['nested_type_spelling_class'] = 'canonicalized_to_array_tuple_spelling'
        else
          record['nested_type_spelling_class'] = 'unexpected_exact_schema'
          add_failure(record, 'schema', 'unexpected_exact_schema')
        end

        insert = invoke("#{profile.fetch('id')}-insert", profile.fetch('id'),
          "INSERT INTO default.#{profile.fetch('table')} SETTINGS input_format_binary_read_json_as_string=0 FORMAT RowBinary",
          input: input)
        record.fetch('steps')['insert'] = process_summary(insert)
        unless process_success?(insert)
          add_failure(record, 'insert', failure_kind(insert))
          record['status'] = 'native_or_plumbing_insert_failure'
          return
        end

        check = invoke("#{profile.fetch('id')}-check", profile.fetch('id'),
          RecheckObjectDeclaredNestedStockW236.check_sql(profile.fetch('table')))
        record.fetch('steps')['check'] = process_summary(check)
        if process_success?(check)
          record['check_stdout'] = check.fetch('stdout').dup.force_encoding(Encoding::UTF_8).scrub
          record['check_matches_expected'] = check.fetch('stdout') == "all_1_1_0\t1\t\n"
          add_failure(record, 'check', 'unexpected_check_stdout') unless record.fetch('check_matches_expected')
        else
          add_failure(record, 'check', failure_kind(check))
        end

        part = invoke("#{profile.fetch('id')}-part", profile.fetch('id'),
          RecheckObjectDeclaredNestedStockW236.part_sql(profile.fetch('table')))
        record.fetch('steps')['part'] = process_summary(part)
        if process_success?(part)
          record['part_stdout'] = part.fetch('stdout').dup.force_encoding(Encoding::UTF_8).scrub
          record['part_capture'] = capture_ref(part)
          record_part(profile.fetch('id'), profile.fetch('table'), part, record)
        else
          add_failure(record, 'part', failure_kind(part))
        end

        compare_rowbinary_windows(profile.fetch('table'), profile.fetch('id'), profile,
          RecheckObjectDeclaredNestedStockW236.expected_rows(profile), record)
        record['status'] = record.fetch('failures').empty? ?
          'persisted_and_literal_rowbinary_matched' : 'stock_result_failed_closed'
      rescue StandardError => error
        add_failure(record, 'script', 'script_inconclusive', "#{error.class}: #{error.message}")
        record['status'] = 'script_inconclusive'
      end
    end

    def record_part(id, table, part, profile_record)
      unless process_success?(part)
        add_failure(profile_record, 'part', failure_kind(part))
        return
      end
      fields = part.fetch('stdout').force_encoding(Encoding::UTF_8).scrub.lines.map do |line|
        line.chomp.split("\t", -1)
      end
      unless fields.length == 1 && fields.first.length == 5 &&
          fields.first[0, 4] == ['all_1_1_0', '6', PART_MARKS.to_s, 'Wide']
        add_failure(profile_record, 'part', 'unexpected_part_shape')
        return
      end
      part_path = File.expand_path(fields.first.fetch(4))
      store = @stores.fetch(id)
      unless part_path.start_with?(store + File::SEPARATOR) && File.directory?(part_path) &&
          !File.symlink?(part_path) && File.realpath(part_path) == part_path
        add_failure(profile_record, 'part', 'part_path_outside_isolated_store_or_noncanonical')
        return
      end

      inventory = Q.inventory_tree(part_path)
      relative = part_path.delete_prefix(@root + File::SEPARATOR)
      profile_record['part_path'] = part_path
      profile_record['part_path_relative'] = relative
      profile_record['part_inventory_file_count'] = inventory.fetch('files').length
      @part_records << {
        'id' => id, 'table' => table, 'part_path' => part_path,
        'part_path_relative' => relative, 'files' => inventory.fetch('files'),
      }
    end

    def compare_rowbinary_windows(table, id, profile, rows, record, control: false)
      windows = {
        'full' => rows.join.b,
        'middle' => rows[2, 2].join.b,
        'empty' => ''.b,
      }
      windows.each do |window, expected|
        expected_name = "#{id}-#{window}-expected.rowbin"
        expected_path = File.join(@root, 'literal_rowbinary', expected_name)
        R.write_new(expected_path, expected)
        output = invoke("#{id}-rowbinary-#{window}", id,
          RecheckObjectDeclaredNestedStockW236.window_sql(table, window, control: control))
        window_record = {
          'expected_literal' => "literal_rowbinary/#{expected_name}",
          'expected_bytes' => expected.bytesize,
          'expected_sha256' => Digest::SHA256.hexdigest(expected),
          'capture_prefix' => capture_ref(output),
          'process' => process_summary(output),
          'matches_independent_literal' => process_success?(output) && output.fetch('stdout') == expected,
        }
        record.fetch('rowbinary_windows')[window] = window_record
        add_failure(record, "rowbinary_#{window}",
          process_success?(output) ? 'rowbinary_mismatch' : failure_kind(output)) unless
          window_record.fetch('matches_independent_literal')
      end
    end

    def run_control
      profile = { 'id' => CONTROL_ID, 'table' => CONTROL_TABLE }
      record = new_profile_record(profile, control: true)
      @profile_records << record
      begin
        input = RecheckObjectDeclaredNestedStockW236.control_input
        input_name = "#{CONTROL_ID}-input.rowbin"
        R.write_new(File.join(@root, 'literal_rowbinary', input_name), input)
        record['input_literal'] = "literal_rowbinary/#{input_name}"

        create = invoke('positive-control-create', CONTROL_ID,
          RecheckObjectDeclaredNestedStockW236.control_create_sql)
        record.fetch('steps')['create'] = process_summary(create)
        unless process_success?(create)
          add_failure(record, 'create', failure_kind(create))
          record['status'] = 'native_or_plumbing_create_failure'
          return
        end
        schema = invoke('positive-control-schema', CONTROL_ID,
          RecheckObjectDeclaredNestedStockW236.schema_sql(CONTROL_TABLE))
        record.fetch('steps')['schema'] = process_summary(schema)
        unless process_success?(schema)
          add_failure(record, 'schema', failure_kind(schema))
          record['status'] = 'schema_query_failure'
          return
        end
        record['schema_stdout'] = schema.fetch('stdout').dup.force_encoding(Encoding::UTF_8).scrub
        expected_schema = "id\tUInt64\nj\tJSON(q UInt8, xs Array(UInt8))\n"
        unless schema.fetch('stdout') == expected_schema
          add_failure(record, 'schema', 'unexpected_exact_schema')
        end

        insert = invoke('positive-control-insert', CONTROL_ID,
          "INSERT INTO default.#{CONTROL_TABLE} SETTINGS input_format_binary_read_json_as_string=0 FORMAT RowBinary",
          input: input)
        record.fetch('steps')['insert'] = process_summary(insert)
        unless process_success?(insert)
          add_failure(record, 'insert', failure_kind(insert))
          record['status'] = 'native_or_plumbing_insert_failure'
          return
        end

        check = invoke('positive-control-check', CONTROL_ID,
          RecheckObjectDeclaredNestedStockW236.check_sql(CONTROL_TABLE))
        record.fetch('steps')['check'] = process_summary(check)
        if process_success?(check)
          record['check_stdout'] = check.fetch('stdout').dup.force_encoding(Encoding::UTF_8).scrub
          record['check_matches_expected'] = check.fetch('stdout') == "all_1_1_0\t1\t\n"
          add_failure(record, 'check', 'unexpected_check_stdout') unless record.fetch('check_matches_expected')
        else
          add_failure(record, 'check', failure_kind(check))
        end

        part = invoke('positive-control-part', CONTROL_ID,
          RecheckObjectDeclaredNestedStockW236.part_sql(CONTROL_TABLE))
        record.fetch('steps')['part'] = process_summary(part)
        if process_success?(part)
          record['part_stdout'] = part.fetch('stdout').dup.force_encoding(Encoding::UTF_8).scrub
          record['part_capture'] = capture_ref(part)
          record_part(CONTROL_ID, CONTROL_TABLE, part, record)
        else
          add_failure(record, 'part', failure_kind(part))
        end

        expected_rows = CONTROL_EXPECTED_ROW_HEX.map { |hex| [hex].pack('H*').b }
        compare_rowbinary_windows(CONTROL_TABLE, CONTROL_ID, nil, expected_rows, record, control: true)
        record['status'] = record.fetch('failures').empty? ?
          'persisted_and_literal_rowbinary_matched' : 'stock_result_failed_closed'
      rescue StandardError => error
        add_failure(record, 'script', 'script_inconclusive', "#{error.class}: #{error.message}")
        record['status'] = 'script_inconclusive'
      end
    end

    def save_evidence
      return unless File.directory?(File.join(@root, 'invocations')) && File.directory?(File.join(@root, 'stores'))
      R.write_new(File.join(@root, 'part_inventories.json'),
        JSON.pretty_generate({ 'parts' => @part_records }) + "\n") unless File.exist?(File.join(@root, 'part_inventories.json'))
      witness = {
        'format' => 'object_declared_nested_stock_w236_v1',
        'source_reference' => "#{SOURCE_ROOT}@#{SOURCE_REVISION}",
        'runtime' => @runtime_pin,
        'settings' => STOCK_SETTINGS,
        'profiles' => @profile_records,
        'process_count' => @recorder.records.length,
        'process_cap' => MAX_PROCESS_COUNT,
        'process_timeout_seconds' => PROCESS_TIMEOUT_SECONDS,
        'max_execution_time_seconds' => MAX_EXECUTION_SECONDS,
        'max_memory_usage_bytes' => MEMORY_LIMIT_BYTES,
        'fatal_error' => @fatal_error,
        'scope' => 'five isolated typed JSON paths using Nested(n UInt8, s String), recursive Array/Tuple/Map/Variant wrappers, and one ordinary JSON positive control; each successful path is persisted to a local Wide part and compared against independent full, middle, and empty RowBinary output literals',
        'source_conclusions' => [
          'The pinned Nested constructor represents Nested as Array(Tuple(...)) while retaining a custom Nested name on the rebuilt type.',
          'The pinned JSON reader builder recursively handles Array, Tuple, string-keyed Map, and Variant nodes.',
          'These source facts are hypotheses about behavior until the pinned native persistence and exact-schema captures below succeed.',
        ],
        'limitations' => [
          'This probe measures only the pinned stock ClickHouse runtime and does not invoke Crystal library code.',
          'A native constructor or insert failure is not treated as a positive compatibility result; timeout, signal, spawn failure, and nonzero exit remain separately classified.',
          'Exact system.columns output is retained verbatim; an Array(Tuple(...)) canonical spelling is recorded as such and never relabeled as nominal Nested.',
          'A six-row index_granularity=2 part is expected to expose rows_per_mark [2,2,2] and marks_count 4 under the W235 stock convention.',
          'No runtime-owner type admission or library read/write claim follows from this stock-only probe.',
        ],
      }
      R.write_new(File.join(@root, 'witnesses.json'), JSON.pretty_generate(witness) + "\n") unless File.exist?(File.join(@root, 'witnesses.json'))
      profiles = PROFILES.map { |item| [item.fetch('id'), item.fetch('table')] } + [[CONTROL_ID, CONTROL_TABLE]]
      allowed_stores = @stores.each_with_object({}) do |(id, path), result|
        table = profiles.find { |profile_id, _table| profile_id == id }&.fetch(1)
        result[File.realpath(path)] = table if table
      end
      inventory = Q.inventory_tree(@root, allowed_stores: allowed_stores)
      R.write_new(File.join(@root, 'capture_inventory.json'), JSON.pretty_generate(inventory) + "\n") unless File.exist?(File.join(@root, 'capture_inventory.json'))
    end
  end

  def main(argv)
    options = { clickhouse: CLICKHOUSE_BIN }
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/recheck_object_declared_nested_stock_w236.rb --capture-root EMPTY_DIR [--clickhouse PINNED_BIN]'
      opts.on('--capture-root PATH') { |value| options[:capture_root] = value }
      opts.on('--clickhouse PATH') { |value| options[:clickhouse] = value }
    end
    parser.parse!(argv)
    require_true(argv.empty? && options.key?(:capture_root), parser.to_s)
    Probe.new(options).run
  rescue StandardError => error
    warn "W236 stock probe setup failed: #{error.class}: #{error.message}"
    false
  end
end

exit(RecheckObjectDeclaredNestedStockW236.main(ARGV) ? 0 : 1) if $PROGRAM_NAME == __FILE__
