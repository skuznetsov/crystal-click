#!/usr/bin/env ruby
# Bounded reciprocal stock/library qualification for generic bitwise
# AggregateFunction states. Reuses W202's pinned process owner; builds nothing.

require 'digest'
require 'json'
require 'optparse'
require_relative 'probe_nested_bulk_part_w202'

module VerifyAggregateBitwiseW255
  W202 = ProbeNestedBulkPartW202
  W185 = W202::W185

  FORMAT = 'aggregate_bitwise_w255_native_capture_v1'.freeze
  BINARY = W202::BINARY
  BINARY_SHA256 = W202::BINARY_SHA256
  VERSION = W202::VERSION
  BUILD = W202::BUILD
  MEMORY = W202::MEMORY
  TIMEOUT = W202::TIMEOUT
  GRACE = W202::GRACE
  OUTER_RUN_SAFE_LIMIT = W202::OUTER_RUN_SAFE_LIMIT

  KEY = 'id'.freeze
  TABLES = %w[source_bitwise library_bitwise].freeze
  FUNCTIONS = [
    {name: 'groupBitOr', code: 'or'},
    {name: 'groupBitAnd', code: 'and'},
    {name: 'groupBitXor', code: 'xor'},
  ].map(&:freeze).freeze
  INTEGER_TYPES = [
    {name: 'UInt8', width: 1, signed: false},
    {name: 'UInt16', width: 2, signed: false},
    {name: 'UInt32', width: 4, signed: false},
    {name: 'UInt64', width: 8, signed: false},
    {name: 'UInt128', width: 16, signed: false},
    {name: 'UInt256', width: 32, signed: false},
    {name: 'Int8', width: 1, signed: true},
    {name: 'Int16', width: 2, signed: true},
    {name: 'Int32', width: 4, signed: true},
    {name: 'Int64', width: 8, signed: true},
    {name: 'Int128', width: 16, signed: true},
    {name: 'Int256', width: 32, signed: true},
  ].map(&:freeze).freeze
  PATTERNS = [
    '0123456789abcdeffedcba987654321000112233445566778899aabbccddeeff',
    '80ff7f0181fe7e0293ec6d1485fa2b7c92eb6c1584fb2a7d0f1e2d3c4b5a69f8',
    'f0e1d2c3b4a5968700112233445566778899aabbccddeefffedcba9876543210',
    '102030405060708090a0b0c0d0e0f001112233445566778899aabbccddeeff7f',
    'ff00aa5501807f031029384756abcdeffedcba9876543210deadbeef01234567',
  ].freeze
  ROW_KEYS = (1..6).to_a.freeze
  PARENT_MARK_ROWS = [2, 2, 2].freeze
  CHILD_ROWS = [0, 3, 1, 0, 2, 0].freeze
  CHILD_LANES = [
    {name: 'or_u16', function: 0, type: 1},
    {name: 'and_i128', function: 1, type: 10},
    {name: 'xor_u256', function: 2, type: 5},
  ].map(&:freeze).freeze
  SOURCE_FILES = %w[
    scripts/verify_aggregate_bitwise_w255.rb
    scripts/check_aggregate_bitwise_w255.cr
    scripts/probe_nested_bulk_part_w202.rb
    scripts/check_array_json_parts_w185.rb
    scripts/check_array_json_parts_w185.cr
    scripts/check_json_binary_kernel_w180.rb
    scripts/check_json_binary_kernel_w180.cr
    scripts/probe_json_array_storage_w183.rb
  ].freeze

  class RowBinaryCursor
    attr_reader :offset

    def initialize(bytes)
      @bytes = bytes.b
      @offset = 0
    end

    def take(length)
      raise 'truncated RowBinary aggregate state' if length.negative? || @offset + length > @bytes.bytesize
      result = @bytes.byteslice(@offset, length)
      @offset += length
      result
    end

    def uint_varint
      value = 0
      shift = 0
      10.times do
        byte = take(1).getbyte(0)
        raise 'RowBinary array length overflows UInt64' if shift == 63 && (byte & 0x7e) != 0
        value |= (byte & 0x7f) << shift
        return value if (byte & 0x80).zero?
        shift += 7
      end
      raise 'RowBinary array length exceeds ten bytes'
    end
  end

  class Probe < W202::Probe
    def initialize(binary, crystal_helper, evidence_root, helper_mode)
      super(binary, crystal_helper, evidence_root)
      fail_w255!('helper mode must be debug or release') unless %w[debug release].include?(helper_mode)
      @helper_mode = helper_mode
      @helper_sha_before = nil
      @source_native = nil
      @attached_native = nil
      @helper_data = nil
      @source_part = nil
      @library_part = nil
      @attached_library_part = nil
      @source_snapshot = nil
      @library_snapshot = nil
      @attached_library_snapshot = nil
      @source_pins_before = nil
      @source_pins_after = nil
    end

    def run
      send(:prepare_layout!)
      Dir.mkdir(File.join(@root, 'generated', 'bitwise'), 0o700)
      @source_pins_before = source_pins
      @binary_sha_before = send(:binary_sha)
      fail_w255!('pinned ClickHouse executable SHA mismatch before probe') unless @binary_sha_before == BINARY_SHA256
      @helper_sha_before = send(:helper_sha)

      initial = send(:run_clickhouse, 'native_sources', initial_sql)
      send(:assert_native_invocation!, initial)
      @source_native = send(:parse_native, initial[:stdout])
      send(:assert_pin!, @source_native)
      assert_initial_native!(@source_native)

      @library_part = File.join(@root, 'generated', 'bitwise', 'all_1_1_0')
      helper = run_helper([@helper, @source_part, @library_part])
      @helper_data = helper.fetch(:data)
      assert_helper!(@helper_data)
      @library_snapshot = send(:snapshot_part, @library_part)

      @executor.send(:attach_part!, @library_part,
                     send(:validate_store_path!, @source_native[:data_paths].fetch('library_bitwise')))
      attached = send(:run_clickhouse, 'attach_and_check', attached_sql)
      send(:assert_native_invocation!, attached)
      @attached_native = send(:parse_native, attached[:stdout])
      send(:assert_pin!, @attached_native)
      assert_attached_native!(@attached_native)

      @attached_library_part = send(:validate_source_part!,
                                    @attached_native[:parts].fetch('library_bitwise').fetch(:path))
      @attached_library_snapshot = send(:snapshot_part, @attached_library_part)
      fail_w255!('stock source part changed during ATTACH/readback') unless
        send(:snapshot_part, @source_part) == @source_snapshot
      fail_w255!('library original changed during ATTACH/readback') unless
        send(:snapshot_part, @library_part) == @library_snapshot

      raw_source = raw_state_read('source_raw_states', 'source_bitwise')
      raw_library = raw_state_read('library_raw_states', 'library_bitwise')
      @binary_sha_after = send(:binary_sha)
      @helper_sha_after = send(:helper_sha)
      @source_pins_after = source_pins
      fail_w255!('pinned ClickHouse executable SHA changed during probe') unless @binary_sha_after == BINARY_SHA256
      fail_w255!('prebuilt Crystal helper SHA changed during probe') unless @helper_sha_after == @helper_sha_before
      fail_w255!('W255/W202 harness source changed during probe') unless @source_pins_after == @source_pins_before
      fail_w255!('attached library part changed during readback') unless
        send(:snapshot_part, @attached_library_part) == @attached_library_snapshot

      write_summary('paired_aggregate_bitwise_observed', raw_source: raw_source, raw_library: raw_library)
      puts "W255 AggregateFunction bitwise reciprocal; helper_mode=#{@helper_mode}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @binary_sha_after = send(:binary_sha) rescue nil
      @helper_sha_after = send(:helper_sha) rescue nil
      @source_pins_after = source_pins rescue nil
      write_summary('runner_failure_or_observations_differ') rescue nil
      warn "W255 probe failure (process failure is not format evidence): #{@fatal_error}"
      false
    end

    private

    def fail_w255!(message)
      raise "W255 bitwise oracle: #{message}"
    end

    def source_pins
      SOURCE_FILES.map do |relative|
        path = File.expand_path(relative, File.expand_path('..', __dir__))
        fail_w255!("pinned harness source is missing or symlinked: #{relative}") unless
          File.file?(path) && !File.symlink?(path)
        {path: path, sha256: Digest::SHA256.file(path).hexdigest}
      end
    end

    def helper_sha
      Digest::SHA256.file(@helper).hexdigest
    end

    def settings
      [
        'index_granularity=2', 'index_granularity_bytes=10485760',
        'enable_mixed_granularity_parts=1', 'min_rows_for_wide_part=0',
        'min_bytes_for_wide_part=0', 'compress_marks=0', 'compress_primary_key=0',
        'min_compress_block_size=0', 'max_compress_block_size=4096',
        "default_compression_codec='LZ4'", "serialization_info_version='with_types'",
        'propagate_types_serialization_versions_to_nested_types=1',
      ].join(', ').freeze
    end

    def root_columns
      INTEGER_TYPES.flat_map do |type|
        FUNCTIONS.map do |function|
          {
            name: "state_#{function[:code]}_#{type[:name].downcase}",
            sql_type: "AggregateFunction(#{function[:name]}, #{type[:name]})",
            width: type[:width], type: type, function: function,
          }.freeze
        end
      end.freeze
    end

    def child_type_sql
      fields = CHILD_LANES.map do |lane|
        type = INTEGER_TYPES.fetch(lane[:type])
        function = FUNCTIONS.fetch(lane[:function])
        "#{lane[:name]} AggregateFunction(#{function[:name]}, #{type[:name]})"
      end
      "Array(Tuple(#{fields.join(', ')}))"
    end

    def schema
      [['id', 'UInt64']] + root_columns.map { |column| [column[:name], column[:sql_type]] } +
        [['states', child_type_sql]]
    end

    def initial_sql
      source, library = TABLES
      statements = [
        "SELECT '__W202_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
        "CREATE TABLE default.#{source} (#{schema.map { |name, type| "`#{name}` #{type}" }.join(', ')}) ENGINE=MergeTree ORDER BY id SETTINGS #{settings};",
        "CREATE TABLE default.#{library} (#{schema.map { |name, type| "`#{name}` #{type}" }.join(', ')}) ENGINE=MergeTree ORDER BY id SETTINGS #{settings};",
        insert_sql(source),
        check_sql(source),
        schema_sql,
        data_paths_sql,
        parts_sql([source]),
      ]
      statements.join("\n") + "\n"
    end

    def insert_sql(table_name)
      columns = schema.map { |name, _type| "`#{name}`" }.join(', ')
      selects = ROW_KEYS.first(5).each_with_index.map { |key, row| populated_select(key, row) }
      selects << empty_select(ROW_KEYS.last)
      "INSERT INTO default.#{table_name} (#{columns})\n" + selects.join("\nUNION ALL\n") + ";"
    end

    def populated_select(key, row)
      expressions = [key.to_s]
      root_columns.each_with_index do |column, index|
        type = column[:type]
        function = column[:function]
        type_index = INTEGER_TYPES.index(type)
        function_index = FUNCTIONS.index(function)
        pattern = operand((row + type_index + function_index) % PATTERNS.size, type[:width])
        value = sql_integer(pattern, type)
        expressions << "initializeAggregation('#{function[:name]}State', CAST('#{value}' AS #{type[:name]}))"
      end
      expressions << child_array_sql(row)
      "SELECT #{expressions.join(', ')}"
    end

    def empty_select(key)
      expressions = [key.to_s]
      root_columns.each do |column|
        function = column[:function]
        type = column[:type]
        expressions << "#{function[:name]}State(CAST(0 AS #{type[:name]}))"
      end
      expressions << "CAST([], '#{child_type_sql}')"
      "SELECT #{expressions.join(', ')} FROM numbers(0)"
    end

    def child_array_sql(parent)
      children = CHILD_ROWS.fetch(parent)
      return "CAST([], '#{child_type_sql}')" if children.zero?

      tuples = children.times.map do |child|
        fields = CHILD_LANES.each_with_index.map do |lane, lane_index|
          type = INTEGER_TYPES.fetch(lane[:type])
          function = FUNCTIONS.fetch(lane[:function])
          pattern = operand((parent + child + lane_index * 2) % PATTERNS.size, type[:width])
          value = sql_integer(pattern, type)
          "initializeAggregation('#{function[:name]}State', CAST('#{value}' AS #{type[:name]}))"
        end
        "tuple(#{fields.join(', ')})"
      end
      "CAST([#{tuples.join(', ')}], '#{child_type_sql}')"
    end

    def sql_integer(bytes, type)
      value = bytes.bytes.reverse_each.reduce(0) { |number, byte| (number << 8) | byte }
      bits = type[:width] * 8
      value -= (1 << bits) if type[:signed] && (value & (1 << (bits - 1))) != 0
      value.to_s
    end

    def operand(index, width)
      [PATTERNS.fetch(index)].pack('H*').byteslice(0, width)
    end

    def check_sql(name)
      [
        "SELECT '__W202_CHECK_BEGIN__', '#{name}', 'bitwise' FORMAT TSVRaw;",
        "CHECK TABLE default.#{name} FORMAT TSV;",
        "SELECT '__W202_CHECK_END__', '#{name}', 'bitwise' FORMAT TSVRaw;",
      ].join("\n")
    end

    def schema_sql
      names = TABLES.map { |name| "'#{name}'" }.join(',')
      "SELECT '__W202_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{names}) ORDER BY table, position FORMAT TSVRaw;"
    end

    def data_paths_sql
      names = TABLES.map { |name| "'#{name}'" }.join(',')
      "SELECT '__W202_DATA_PATH__', name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name IN (#{names}) ORDER BY name FORMAT TSVRaw;"
    end

    def parts_sql(tables)
      names = tables.map { |name| "'#{name}'" }.join(',')
      "SELECT '__W202_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table IN (#{names}) AND active ORDER BY table,name FORMAT TSVRaw;"
    end

    def attached_sql
      [
        "SELECT '__W202_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
        "ALTER TABLE default.library_bitwise ATTACH PART 'all_1_1_0';",
        check_sql('source_bitwise'),
        check_sql('library_bitwise'),
        schema_sql,
        data_paths_sql,
        parts_sql(TABLES),
      ].join("\n") + "\n"
    end

    def assert_initial_native!(native)
      expected_checks = {['source_bitwise', 'bitwise'] => ["all_1_1_0\t1\t"]}
      fail_w255!("stock CHECK did not return one success: #{native[:checks].inspect}") unless native[:checks] == expected_checks
      expected_schemas = TABLES.sort.flat_map { |table| schema.map { |name, type| [table, name, type] } }
      fail_w255!('native source and empty target schema differ') unless native[:schemas] == expected_schemas
      fail_w255!('native table data paths differ from exact table roster') unless native[:data_paths].keys.sort == TABLES.sort
      native[:data_paths].each_value { |path| send(:validate_store_path!, path) }
      source = native[:parts].fetch('source_bitwise')
      fail_w255!('stock source part is not one six-row Wide part with three marks plus EOF') unless
        source[:name] == 'all_1_1_0' && source[:type] == 'Wide' && source[:rows] == '6' && source[:marks] == '4'
      @source_part = send(:validate_source_part!, source[:path])
      @source_snapshot = send(:snapshot_part, @source_part)
    end

    def assert_attached_native!(native)
      expected_checks = TABLES.to_h { |table| [[table, 'bitwise'], ["all_1_1_0\t1\t"]] }
      fail_w255!("stock CHECK rejected a source or library part: #{native[:checks].inspect}") unless native[:checks] == expected_checks
      expected_schemas = TABLES.sort.flat_map { |table| schema.map { |name, type| [table, name, type] } }
      fail_w255!('attached native schema differs') unless native[:schemas] == expected_schemas
      fail_w255!('attached native data-path roster differs') unless native[:data_paths].keys.sort == TABLES.sort
      fail_w255!('attached native active-part roster differs') unless native[:parts].keys.sort == TABLES.sort
      native[:parts].each do |table, part|
        fail_w255!("#{table} part identity or mark grid differs") unless
          part[:name] == 'all_1_1_0' && part[:type] == 'Wide' && part[:rows] == '6' && part[:marks] == '4'
      end
    end

    def run_helper(argv)
      before = helper_sha
      fail_w255!('prebuilt Crystal helper changed before invocation') unless before == @helper_sha_before
      invocation = @executor.send(:execute_record, 'crystal_helper', argv, ''.b,
                                  'prebuilt Crystal helper', before, @helper)
      fail_w255!('Crystal helper process failed; this is not native format evidence') unless send(:successful?, invocation)
      fail_w255!('Crystal helper emitted stderr') unless invocation[:stderr].empty?
      fail_w255!('prebuilt Crystal helper changed during invocation') unless helper_sha == before
      lines = invocation[:stdout].lines.map(&:chomp).reject(&:empty?)
      fail_w255!('Crystal helper must emit exactly one JSON report') unless lines.size == 1
      data = JSON.parse(lines.fetch(0))
      fail_w255!('Crystal helper report format differs') unless data['format'] == 'aggregate_bitwise_w255_helper_v1'
      @invocations << invocation[:record]
      {data: data, record: invocation[:record]}
    end

    def assert_helper!(data)
      fail_w255!('helper parent keys, P grid, or ragged Q differ') unless
        data['row_keys'] == ROW_KEYS && data['mark_rows'] == PARENT_MARK_ROWS && data['child_row_counts'] == CHILD_ROWS
      fail_w255!('helper did not report the exact 36+3 state roster') unless
        data['root_state_count'] == 36 && data['child_state_lanes'] == 3
      fail_w255!('helper physical stream profile differs') unless data['bulk_profile'] == 'with_size_stream'
      expected_columns = root_columns.map { |column| [column[:name], column[:sql_type]] } + [['states', child_type_sql]]
      actual_columns = data['column_roster'].map { |entry| entry }
      fail_w255!('helper nominal column roster differs from independent literals') unless actual_columns == expected_columns
      expected = expected_state_hex
      fail_w255!('helper independent state literals differ') unless data['independent_state_hex'] == expected
      %w[source library].each do |origin|
        side = data.fetch(origin == 'source' ? 'source' : 'library')
        fail_w255!("helper #{origin} path differs") unless File.expand_path(side.fetch('path')) ==
          (origin == 'source' ? @source_part : @library_part)
        report = side
        columns = report.fetch('root_columns')
        fail_w255!("helper #{origin} root-column roster differs") unless columns.size == 36
        columns.each_with_index do |entry, index|
          expected_column = root_columns.fetch(index)
          fail_w255!("helper #{origin}/#{expected_column[:name]} raw reads differ") unless
            entry.fetch('type') == expected_column[:sql_type] && entry.fetch('row_count') == 6 &&
            entry.fetch('mark_row_counts') == PARENT_MARK_ROWS && entry.fetch('state_hex_by_row') == expected.fetch(index).fetch('rows')
        end
        states = report.fetch('states')
        fail_w255!("helper #{origin}/states recursive reads differ") unless
          states.fetch('type') == child_type_sql && states.fetch('row_count') == 6 &&
          states.fetch('mark_row_counts') == PARENT_MARK_ROWS && states.fetch('state_hex_by_row') == expected.last.fetch('rows')
      end
      expected_public = expected_columns.each_slice(15).map do |group|
        {'columns' => group.map(&:first), 'batch_marks' => [0, 1, 2], 'row_count' => 6}
      end
      fail_w255!('helper public table scans did not report exact columns and batches') unless
        data['public_stock'] == expected_public && data['public_library'] == expected_public &&
        data['offline_stock'] == {'column_count' => 37, 'row_count' => 6, 'exact_nominal_states' => true} &&
        data['offline_library'] == {'column_count' => 37, 'row_count' => 6, 'exact_nominal_states' => true}
    end

    def expected_state_hex
      roots = root_columns.each_with_index.map do |column, index|
        type_index = index / FUNCTIONS.size
        function_index = index % FUNCTIONS.size
        values = ROW_KEYS.map do |key|
          if key == 6
            column[:function][:code] == 'and' ? 'ff' * column[:width] : '00' * column[:width]
          else
            operand((key - 1 + type_index + function_index) % PATTERNS.size, column[:width]).unpack1('H*')
          end
        end
        [column[:name], values]
      end
      child_rows = CHILD_ROWS.each_with_index.map do |count, parent|
        count.times.map do |child|
          CHILD_LANES.map do |lane|
            type = INTEGER_TYPES.fetch(lane[:type])
            operand((parent + child + CHILD_LANES.index(lane) * 2) % PATTERNS.size, type[:width]).unpack1('H*')
          end
        end
      end
      root_entries = roots.map do |name, rows|
        {'name' => name, 'type' => root_columns.find { |column| column[:name] == name }[:sql_type],
         'rows' => rows}
      end
      state_entry = {'name' => 'states', 'type' => child_type_sql,
                     'rows' => child_rows.map { |row| JSON.generate(row) }}
      root_entries + [state_entry]
    end

    def raw_state_read(label, table)
      selected = schema.map { |name, _type| "`#{name}`" }.join(', ')
      invocation = send(:run_clickhouse, label,
                        "SELECT #{selected} FROM default.#{table} ORDER BY id FORMAT RowBinary;\n")
      send(:assert_native_invocation!, invocation)
      rows = decode_rows(invocation[:stdout])
      {label: label, table: table, stdout_file: invocation[:record][:stdout_file],
       stdout_bytes: invocation[:record][:stdout_bytes], stdout_sha256: invocation[:record][:stdout_sha256],
       rows: rows}
    end

    def decode_rows(bytes)
      cursor = RowBinaryCursor.new(bytes)
      rows = ROW_KEYS.map do |key|
        actual_key = little_unsigned(cursor.take(8))
        fail_w255!("RowBinary key differs at row #{key}") unless actual_key == key
        root_states = root_columns.map do |column|
          hex = cursor.take(column[:width]).unpack1('H*')
          [column[:name], hex]
        end
        child_count = cursor.uint_varint
        fail_w255!("RowBinary states array length differs at parent #{key}") unless child_count == CHILD_ROWS.fetch(key - 1)
        child_states = child_count.times.map do
          CHILD_LANES.map do |lane|
            width = INTEGER_TYPES.fetch(lane[:type])[:width]
            cursor.take(width).unpack1('H*')
          end
        end
        {'id' => key, 'root_state_hex' => root_states, 'child_state_hex' => child_states}
      end
      fail_w255!('RowBinary aggregate state output has trailing bytes') unless cursor.offset == bytes.bytesize
      compare_raw_rows!(rows)
      rows
    end

    def compare_raw_rows!(rows)
      expected = expected_raw_rows
      fail_w255!('native RowBinary aggregate state bytes differ from independent literals') unless rows == expected
    end

    def expected_raw_rows
      ROW_KEYS.map do |key|
        root_states = root_columns.each_with_index.map do |column, index|
          type_index = index / FUNCTIONS.size
          function_index = index % FUNCTIONS.size
          hex = if key == 6
                  column[:function][:code] == 'and' ? 'ff' * column[:width] : '00' * column[:width]
                else
                  operand((key - 1 + type_index + function_index) % PATTERNS.size, column[:width]).unpack1('H*')
                end
          [column[:name], hex]
        end
        child_states = CHILD_ROWS.fetch(key - 1).times.map do |child|
          CHILD_LANES.map do |lane|
            type = INTEGER_TYPES.fetch(lane[:type])
            operand((key - 1 + child + CHILD_LANES.index(lane) * 2) % PATTERNS.size, type[:width]).unpack1('H*')
          end
        end
        {'id' => key, 'root_state_hex' => root_states, 'child_state_hex' => child_states}
      end
    end

    def little_unsigned(bytes)
      bytes.bytes.reverse_each.reduce(0) { |number, byte| (number << 8) | byte }
    end

    def check_rows(native)
      native[:checks].map do |(table, profile), rows|
        {'table' => table, 'profile' => profile, 'rows' => rows}
      end
    end

    def native_summary(native)
      {
        'pin' => native[:pin],
        'checks' => check_rows(native),
        'schemas' => native[:schemas],
        'data_paths' => native[:data_paths],
        'parts' => native[:parts].transform_values do |part|
          {'name' => part[:name], 'path' => part[:path], 'type' => part[:type],
           'rows' => part[:rows], 'marks' => part[:marks]}
        end,
      }
    end

    def write_summary(status, raw_source: nil, raw_library: nil)
      source_pins_now = @source_pins_after || source_pins rescue nil
      invocation_summaries = @invocations.map do |record|
        stdout_file = record.fetch(:stdout_file)
        label = File.basename(stdout_file, '.stdout')
        fail_w255!('invocation stdout filename is not a direct label sidecar') unless
          !label.empty? && stdout_file == "#{label}.stdout"
        record.merge(label: label)
      end
      summary = {
        format: FORMAT, status: status, fatal_error: @fatal_error,
        case: {table_names: TABLES, helper_mode: @helper_mode, profile: 'with_size_stream', row_keys: ROW_KEYS,
               parent_mark_rows: PARENT_MARK_ROWS, child_row_counts: CHILD_ROWS,
               root_state_count: 36, child_state_lanes: 3},
        runtime: {path: @binary, expected_sha256: BINARY_SHA256,
                  sha256_before: @binary_sha_before, sha256_after: @binary_sha_after,
                  expected_version: VERSION, expected_build: BUILD},
        helper: {path: @helper, mode: @helper_mode,
                 sha256_before: @helper_sha_before, sha256_after: @helper_sha_after},
        harness_source_pins: {before: @source_pins_before, after: source_pins_now},
        limits: {max_threads: 1, local_max_memory_usage_bytes: MEMORY,
                 required_outer_run_safe_memory_limit_bytes: OUTER_RUN_SAFE_LIMIT,
                 timeout_seconds: TIMEOUT, termination_grace_seconds: GRACE,
                 executor: 'JsonBinaryKernelW180Probe#execute'},
        settings: settings, evidence_root: @root, invocations: invocation_summaries,
        parts: {source: @source_part, library_generated: @library_part,
                library_attached: @attached_library_part,
                source_snapshot: @source_snapshot, library_snapshot: @library_snapshot,
                attached_library_snapshot: @attached_library_snapshot},
        native: {initial: @source_native && native_summary(@source_native),
                 attached: @attached_native && native_summary(@attached_native)},
        helper_report: @helper_data, raw_state_reads: [raw_source, raw_library].compact,
      }
      send(:write_new, File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      send(:write_new, File.join(@root, 'summary.md'), [
        '# W255 AggregateFunction bitwise reciprocal capture', '',
        "Status: `#{status}`", '',
        "Runtime: #{VERSION} / #{BUILD} / SHA256 `#{@binary_sha_before}`", '',
        "Helper mode: `#{@helper_mode}`", '',
        'Scope: the 36 unary bare-integer groupBitOr/And/Xor root states and the three named Array(Tuple) child lanes in this one Wide profile. Raw RowBinary state bytes, exact schema, CHECK=1, row/mark windows and helper consumer reports are retained. This does not claim aggregate execution or other layouts.', '',
        "Evidence root: `#{@root}`", '',
      ].join("\n"))
    end
  end

  EXPECTED_LABELS = %w[native_sources crystal_helper attach_and_check source_raw_states library_raw_states].freeze

  def self.audit_summary(path)
    summary_path = File.expand_path(path)
    summary = JSON.parse(File.binread(summary_path))
    raise 'W255 audit format differs' unless summary['format'] == FORMAT
    raise 'W255 audit status is not green' unless summary['status'] == 'paired_aggregate_bitwise_observed'
    root = summary.fetch('evidence_root')
    raise 'W255 evidence root is not canonical' unless File.directory?(root) && !File.symlink?(root) && File.realpath(root) == root
    invocations = summary.fetch('invocations')
    raise 'W255 invocation roster differs' unless invocations.map { |item| item.fetch('label') } == EXPECTED_LABELS

    invocations.each do |record|
      label = record.fetch('label')
      raise "W255 #{label} process did not succeed" unless
        record['process_classification'] == 'success' && record['exit'] == 0 &&
        record['signal'].nil? && record['timed_out'] == false
      raise "W255 #{label} process error is present" if
        %w[spawn_error stdin_write_error stdout_read_error stderr_read_error].any? { |key| record[key] }
      argv = record.fetch('argv')
      expected_argv_hash = Digest::SHA256.hexdigest(JSON.pretty_generate(argv) + "\n")
      raise "W255 #{label} argv digest differs" unless record['argv_sha256'] == expected_argv_hash
      %w[stdout stderr].each do |stream|
        filename = record.fetch("#{stream}_file")
        raise "W255 #{label} #{stream} filename escaped invocation directory" unless filename == "#{label}.#{stream}"
        bytes = File.binread(File.join(root, 'invocations', filename))
        raise "W255 #{label} #{stream} size/hash differs" unless
          bytes.bytesize == record["#{stream}_bytes"] && Digest::SHA256.hexdigest(bytes) == record["#{stream}_sha256"]
      end
      if record['stdin_file']
        filename = record.fetch('stdin_file')
        raise "W255 #{label} stdin filename escaped invocation directory" unless filename == "#{label}.stdin.sql"
        bytes = File.binread(File.join(root, 'invocations', filename))
        raise "W255 #{label} stdin size/hash differs" unless
          bytes.bytesize == record['stdin_bytes'] && Digest::SHA256.hexdigest(bytes) == record['stdin_sha256']
      end
    end

    native = summary.fetch('native')
    initial = parse_native_file(root, invocations, 'native_sources')
    attached = parse_native_file(root, invocations, 'attach_and_check')
    expected_initial = [{'table' => 'source_bitwise', 'profile' => 'bitwise', 'rows' => ["all_1_1_0\t1\t"]}]
    expected_attached = %w[source_bitwise library_bitwise].map do |table|
      {'table' => table, 'profile' => 'bitwise', 'rows' => ["all_1_1_0\t1\t"]}
    end
    raise 'W255 initial raw CHECK result differs' unless initial[:checks] == expected_initial
    raise 'W255 attached raw CHECK result differs' unless attached[:checks] == expected_attached
    raise 'W255 summary initial CHECK projection differs from raw process output' unless native.fetch('initial').fetch('checks') == expected_initial
    raise 'W255 summary attached CHECK projection differs from raw process output' unless native.fetch('attached').fetch('checks') == expected_attached

    raw_reads = summary.fetch('raw_state_reads')
    raise 'W255 raw state read roster differs' unless raw_reads.map { |item| item.fetch('label') } == %w[source_raw_states library_raw_states]
    raw_reads.each do |item|
      record = invocations.find { |entry| entry['label'] == item.fetch('label') }
      raise 'W255 raw RowBinary sidecar binding differs' unless record && item['stdout_file'] == record['stdout_file'] &&
        item['stdout_bytes'] == record['stdout_bytes'] && item['stdout_sha256'] == record['stdout_sha256']
      actual_bytes = File.binread(File.join(root, 'invocations', record.fetch('stdout_file')))
      decoded = Probe.allocate.send(:decode_rows, actual_bytes)
      raise 'W255 raw RowBinary parsed values differ from the independently recomputed literal census' unless item['rows'] == decoded
    end
    true
  end

  def self.parse_native_file(root, invocations, label)
    record = invocations.find { |entry| entry['label'] == label } || raise("W255 missing #{label} invocation")
    stdout = File.binread(File.join(root, 'invocations', record.fetch('stdout_file')))
    parsed = W202::Probe.allocate.send(:parse_native, stdout)
    checks = parsed[:checks].map do |(table, profile), rows|
      {'table' => table, 'profile' => profile, 'rows' => rows}
    end
    {checks: checks}
  end
end

def main
  options = {binary: VerifyAggregateBitwiseW255::BINARY}
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/verify_aggregate_bitwise_w255.rb --evidence-root EMPTY_CHILD_OF_PRIVATE_TMP --crystal-helper PREBUILT_HELPER --helper-mode debug|release [--clickhouse PINNED_BINARY]\n       ruby scripts/verify_aggregate_bitwise_w255.rb --audit SUMMARY_JSON'
    parser.on('--clickhouse PATH') { |value| options[:binary] = value }
    parser.on('--crystal-helper PATH') { |value| options[:crystal_helper] = value }
    parser.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
    parser.on('--helper-mode MODE') { |value| options[:helper_mode] = value }
    parser.on('--audit SUMMARY_JSON') { |value| options[:audit] = value }
  end.parse!

  if options[:audit]
    raise 'audit mode does not accept probe options' if options[:crystal_helper] || options[:evidence_root] || options[:helper_mode]
    VerifyAggregateBitwiseW255.audit_summary(options[:audit])
    puts 'W255 summary audit passed'
    return
  end
  raise 'prebuilt Crystal helper is required via --crystal-helper' unless options[:crystal_helper]
  raise 'empty evidence root is required via --evidence-root' unless options[:evidence_root]
  raise 'helper mode is required via --helper-mode debug|release' unless options[:helper_mode]
  exit(VerifyAggregateBitwiseW255::Probe.new(options[:binary], options[:crystal_helper],
                                             options[:evidence_root], options[:helper_mode]).run ? 0 : 1)
rescue StandardError => error
  warn "W255 verifier error: #{error.class}: #{error.message}"
  exit 1
end

main if $PROGRAM_NAME == __FILE__
