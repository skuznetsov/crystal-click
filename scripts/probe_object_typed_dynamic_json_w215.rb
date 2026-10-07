#!/usr/bin/env ruby
# Bounded asymmetric stock/library qualification for JSON actuals in declared
# Object Dynamic fields. The stock source uses the already-qualified cast
# construction, which intentionally yields plain JSON actual descriptors;
# the library witness independently writes parameterized JSON(v UInt8).

require 'digest'
require 'json'
require 'optparse'
require_relative 'probe_object_typed_dynamic_shared_json_w214'

module ProbeObjectTypedDynamicJSONW215
  W214 = ProbeObjectTypedDynamicSharedJSONW214
  W202 = W214::W202
  BINARY = W202::BINARY
  BINARY_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  VERSION = '26.10.1.1201'.freeze
  BUILD = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  TYPE = 'JSON(max_dynamic_paths=0,max_dynamic_types=0,p Dynamic(max_types=2))'.freeze
  DECLARATION = 'JSON(max_dynamic_types=0, max_dynamic_paths=0, p Dynamic(max_types=2))'.freeze
  TYPED_JSON = 'JSON(max_dynamic_types=0, max_dynamic_paths=0, v UInt8)'.freeze
  TYPED_ARRAY_JSON = "Array(#{TYPED_JSON})".freeze
  FORMAT_INPUT = 'object_typed_dynamic_json_w215_input_v1'.freeze
  FORMAT_OUTPUT = 'object_typed_dynamic_json_w215_helper_v1'.freeze
  PROFILES = %w[single_stream with_size_stream].freeze
  MODES = %w[basic compact].freeze
  CELLS = PROFILES.flat_map { |profile| MODES.map { |mode| [profile, mode] } }.freeze
  WINDOWS = {
    'FULL' => (0...8),
    'FIRST_EMPTY' => (0...2),
    'LATER' => (2...6),
    'FINAL' => (6...8),
    'ZERO' => (8...8),
  }.freeze
  EXPECTED_ROWS_BY_MARK = [
    ['JSON(7)', 'JSON(8)'],
    ['ARRAY[JSON(17)]', 'ARRAY[JSON(18),JSON(19)]'],
    ['NULL', 'JSON(20)'],
    ['ARRAY[JSON(21),JSON(22)]', 'JSON(23)'],
  ].freeze
  ROWS = [
    {pk: 1, kind: :json, values: [7]},
    {pk: 2, kind: :json, values: [8]},
    {pk: 3, kind: :array, values: [17]},
    {pk: 4, kind: :array, values: [18, 19]},
    {pk: 5, kind: :null, values: []},
    {pk: 6, kind: :json, values: [20]},
    {pk: 7, kind: :array, values: [21, 22]},
    {pk: 8, kind: :json, values: [23]},
  ].freeze
  SETTINGS_BASE = [
    'index_granularity=2', 'index_granularity_bytes=10485760',
    'enable_mixed_granularity_parts=1', 'min_rows_for_wide_part=0',
    'min_bytes_for_wide_part=0', 'compress_marks=0', 'compress_primary_key=0',
    'min_compress_block_size=0', 'max_compress_block_size=4096',
    "default_compression_codec='LZ4'", "serialization_info_version='with_types'",
    'propagate_types_serialization_versions_to_nested_types=true',
    "dynamic_serialization_version='v3'", "object_serialization_version='v3'",
    "object_shared_data_serialization_version_for_zero_level_parts='map'",
  ].join(', ').freeze

  class Probe < W214::Probe
    def initialize(binary, crystal_helper, evidence_root)
      super
      @table_identity = {}
      CELLS.each do |profile, mode|
        %w[source library].each do |origin|
          @table_identity[table(profile, mode, origin)] = [profile, mode, origin]
        end
      end
      @source_parts = {}
      @source_snapshots = {}
      @library_parts = {}
      @library_snapshots = {}
      @data_paths = {}
      @invocations = []
    end

    def run
      send(:prepare_layout!)
      CELLS.each { |profile, mode| Dir.mkdir(File.join(@root, 'generated', cell_id(profile, mode)), 0o700) }
      @binary_sha_before = send(:binary_sha)
      fail!('pinned ClickHouse executable SHA-256 mismatch before probe') unless @binary_sha_before == BINARY_SHA256
      @helper_sha_before = send(:helper_sha)

      initial = send(:run_clickhouse, 'native_sources', initial_sql)
      send(:assert_native_invocation!, initial)
      native = send(:parse_native, initial[:stdout])
      send(:assert_pin!, native)
      assert_initial_native!(native)

      input_path = File.join(@root, 'inputs', 'helper-input.json')
      input = JSON.pretty_generate(build_helper_input) + "\n"
      send(:write_new, input_path, input)
      @helper_input = {
        path: input_path,
        bytes: input.bytesize,
        sha256: Digest::SHA256.hexdigest(input),
      }
      helper = run_helper(input_path)
      assert_helper_output!(helper[:data])
      send(:attach_library_parts!)

      attached = send(:run_clickhouse, 'attach_and_check', attached_sql)
      send(:assert_native_invocation!, attached)
      attached_native = send(:parse_native, attached[:stdout])
      send(:assert_pin!, attached_native)
      assert_attached_native!(attached_native)

      @source_parts.each do |name, path|
        fail!("stock source part changed during ATTACH/SELECT: #{name}") unless mode_snapshot(path) == @source_snapshots.fetch(name)
      end
      @library_parts.each do |cell, path|
        fail!("library part changed during ATTACH/SELECT: #{cell}") unless mode_snapshot(path) == @library_snapshots.fetch(cell)
      end
      @binary_sha_after = send(:binary_sha)
      @helper_sha_after = send(:helper_sha)
      fail!('pinned ClickHouse executable SHA changed during probe') unless @binary_sha_after == BINARY_SHA256
      fail!('prebuilt Crystal helper SHA changed during probe') unless @helper_sha_after == @helper_sha_before

      write_evidence(
        status: 'asymmetric_stock_plain_and_library_typed_json_actuals_observed',
        source: native, helper: helper[:data], helper_invocation: helper[:record],
        initial_invocation: initial[:record], attached: attached_native,
        attached_invocation: attached[:record], source_part_snapshots: @source_snapshots,
        library_part_snapshots: @library_snapshots,
      )
      puts "W215 asymmetric typed Object Dynamic JSON probe cells=#{CELLS.size}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @binary_sha_after = send(:binary_sha) rescue nil
      @helper_sha_after = send(:helper_sha) rescue nil
      write_evidence(status: 'runner_failure_or_observations_differ', fatal_error: @fatal_error) rescue nil
      warn "W215 probe failure (process failure is not format evidence): #{@fatal_error}"
      false
    end

    private

    def fail!(message)
      raise RuntimeError, "W215 typed Object Dynamic JSON oracle: #{message}"
    end

    def cell_id(profile, mode)
      "#{profile}_#{mode}"
    end

    def table(profile, mode, origin)
      short_profile = profile == 'single_stream' ? 'single' : 'withsize'
      "w215_#{@token}_#{short_profile}_#{mode}_#{origin}"
    end

    def all_tables
      CELLS.flat_map { |profile, mode| %w[source library].map { |origin| table(profile, mode, origin) } }
    end

    def source_tables
      CELLS.map { |profile, mode| table(profile, mode, 'source') }
    end

    def settings(profile, mode)
      compact = mode == 'compact' ? 1 : 0
      "#{SETTINGS_BASE}, use_compact_variant_discriminators_serialization=#{compact}, string_serialization_version='#{profile}'"
    end

    def source_actual(row)
      case row[:kind]
      when :json
        json = JSON.generate({'v' => row[:values].fetch(0)})
        inner = "CAST(CAST('#{json}', 'JSON(max_dynamic_paths=0,max_dynamic_types=0,v UInt8)'), 'Dynamic(max_types=2)')"
      when :array
        items = row[:values].map do |value|
          json = JSON.generate({'v' => value})
          "CAST('#{json}', 'JSON(max_dynamic_paths=0,max_dynamic_types=0,v UInt8)')"
        end
        inner = "CAST([#{items.join(', ')}], 'Dynamic(max_types=2)')"
      when :null
        return "CAST('{\"p\":null}', '#{TYPE}')"
      else
        fail!("unrostered native row kind #{row[:kind].inspect}")
      end
      tuple = "CAST(tuple(#{inner}), 'Tuple(p Dynamic(max_types=2))')"
      "CAST(#{tuple}, '#{TYPE}')"
    end

    def initial_sql
      statements = [
        'SET flatten_nested=0;',
        'SET output_format_json_named_tuples_as_objects=1;',
        'SET print_pretty_type_names=0;',
        "SELECT '__W202_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
      ]
      CELLS.each do |profile, mode|
        %w[source library].each do |origin|
          name = table(profile, mode, origin)
          statements << "CREATE TABLE default.#{name} (pk UInt64, payload #{TYPE}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings(profile, mode)};"
        end
      end
      CELLS.each do |profile, mode|
        name = table(profile, mode, 'source')
        rows = ROWS.map { |row| "SELECT #{row[:pk]} AS pk, #{source_actual(row)} AS payload" }
        statements << "INSERT INTO default.#{name}\n#{rows.join("\nUNION ALL\n")};"
        statements << send(:check_sql, name, profile)
      end
      names = all_tables.map { |name| "'#{name}'" }.join(',')
      statements << "SELECT '__W202_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{names}) ORDER BY table, position FORMAT TSVRaw;"
      statements << "SELECT '__W202_DATA_PATH__', name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name IN (#{names}) ORDER BY name FORMAT TSVRaw;"
      statements << send(:parts_sql, source_tables)
      source_tables.each do |name|
        profile, mode, = @table_identity.fetch(name)
        statements.concat(value_queries(name, profile, mode))
      end
      statements.join("\n") + "\n"
    end

    def attached_sql
      statements = [
        'SET flatten_nested=0;',
        'SET output_format_json_named_tuples_as_objects=1;',
        'SET print_pretty_type_names=0;',
        "SELECT '__W202_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
      ]
      CELLS.each do |profile, mode|
        statements << "ALTER TABLE default.#{table(profile, mode, 'library')} ATTACH PART 'all_1_1_0';"
      end
      all_tables.each do |name|
        profile, = @table_identity.fetch(name)
        statements << send(:check_sql, name, profile)
      end
      names = all_tables.map { |name| "'#{name}'" }.join(',')
      statements << "SELECT '__W202_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{names}) ORDER BY table, position FORMAT TSVRaw;"
      statements << send(:parts_sql, all_tables)
      all_tables.each do |name|
        profile, mode, origin = @table_identity.fetch(name)
        statements.concat(value_queries(name, profile, mode, origin))
      end
      statements.join("\n") + "\n"
    end

    def value_queries(table_name, profile, mode, origin = 'source')
      predicates = {
        'FULL' => '',
        'FIRST_EMPTY' => ' WHERE pk BETWEEN 1 AND 2',
        'LATER' => ' WHERE pk BETWEEN 3 AND 6',
        'FINAL' => ' WHERE pk BETWEEN 7 AND 8',
        'ZERO' => ' WHERE pk > 8',
      }
      predicates.flat_map do |window, predicate|
        tag = "__W202_VALUES_#{window}__"
        query = "SELECT '#{tag}', '#{table_name}', toString(pk), " \
                "if(isNull(payload.p), 'None', dynamicType(payload.p)), " \
                "if(isNull(payload.p), 'false', if(isDynamicElementInSharedData(payload.p), 'true', 'false')), " \
                "if(isNull(payload.p), '6E756C6C', hex(toJSONString(payload.p))), " \
                "hex(toJSONString(JSONDynamicPaths(payload))), hex(toJSONString(JSONSharedDataPaths(payload))) " \
                "FROM default.#{table_name}#{predicate} ORDER BY pk FORMAT TSVRaw;"
        if window == 'ZERO'
          ["SELECT '__W202_ZERO_BEGIN__', '#{table_name}', '#{profile}', 'values' FORMAT TSVRaw;",
           query,
           "SELECT '__W202_ZERO_END__', '#{table_name}', '#{profile}', 'values' FORMAT TSVRaw;"]
        else
          [query]
        end
      end
    end

    def run_helper(input_path)
      before = send(:helper_sha)
      fail!('prebuilt Crystal helper changed before invocation') unless before == @helper_sha_before
      argv = [@helper, input_path, @root]
      invocation = @executor.send(:execute_record, 'crystal_helper', argv, ''.b,
                                  'prebuilt Crystal helper', before, @helper)
      send(:annotate_invocation!, 'crystal_helper', invocation[:record])
      fail!('prebuilt Crystal helper process failed') unless send(:successful?, invocation)
      fail!('prebuilt Crystal helper emitted stderr') unless invocation[:stderr].empty?
      fail!('prebuilt Crystal helper changed during invocation') unless send(:helper_sha) == before
      lines = invocation[:stdout].lines.map(&:chomp).reject(&:empty?)
      fail!('helper must emit exactly one JSON record') unless lines.size == 1
      data = JSON.parse(lines.fetch(0))
      fail!('helper output format differs') unless data['format'] == FORMAT_OUTPUT
      @invocations << invocation[:record]
      {data: data, record: invocation[:record]}
    end

    def build_helper_input
      capture_root = File.realpath(File.join(@root, 'stores', 'native'))
      cells = CELLS.map do |profile, mode|
        cell = cell_id(profile, mode)
        source = table(profile, mode, 'source')
        {
          'cell_id' => cell,
          'capture_root' => capture_root,
          'profile_id' => profile,
          'mode_id' => mode,
          'source_part' => @source_parts.fetch(source),
          'library_part' => File.join(@root, 'generated', cell, 'all_1_1_0'),
        }
      end
      {'format' => FORMAT_INPUT, 'capture_root' => capture_root, 'cells' => cells}
    end

    def assert_initial_native!(native)
      expected_checks = source_tables.to_h do |name|
        profile, = @table_identity.fetch(name)
        [[name, profile], ["all_1_1_0\t1\t"]]
      end
      fail!("stock source CHECK differs: #{native[:checks].inspect}") unless native[:checks] == expected_checks
      expected_schema = all_tables.sort.flat_map { |name| [[name, 'pk', 'UInt64'], [name, 'payload', DECLARATION]] }
      fail!('stock source/empty-library schema roster differs') unless native[:schemas] == expected_schema
      fail!('stock table data paths do not cover exact table roster') unless native[:data_paths].keys.sort == all_tables.sort
      native[:data_paths].each_value { |path| send(:validate_store_path!, path) }
      @data_paths = native[:data_paths].dup
      expected_zero = source_tables.flat_map do |name|
        profile, = @table_identity.fetch(name)
        [["__W202_ZERO_BEGIN__", name, profile, 'values'], ["__W202_ZERO_END__", name, profile, 'values']]
      end
      fail!('stock EOF-window boundary roster differs') unless native[:zero_events] == expected_zero
      fail!('stock source active-part roster differs') unless native[:parts].keys.sort == source_tables.sort
      expected_rows = source_tables.product(%w[FULL FIRST_EMPTY LATER FINAL]).sort
      fail!('stock source value-window roster differs') unless native[:value_rows].keys.sort == expected_rows
      source_tables.each do |name|
        part = native[:parts].fetch(name)
        fail!("#{name} is not one eight-row Wide part/four marks") unless
          part[:name] == 'all_1_1_0' && part[:type] == 'Wide' && part[:rows] == '8' && part[:marks] == '5'
        path = send(:validate_source_part!, part[:path])
        @source_parts[name] = path
        @source_snapshots[name] = mode_snapshot(path)
        assert_value_windows!(native, name, 'source')
      end
    end

    def assert_attached_native!(native)
      expected_checks = all_tables.to_h do |name|
        profile, = @table_identity.fetch(name)
        [[name, profile], ["all_1_1_0\t1\t"]]
      end
      fail!("source/library CHECK differs: #{native[:checks].inspect}") unless native[:checks] == expected_checks
      expected_schema = all_tables.sort.flat_map { |name| [[name, 'pk', 'UInt64'], [name, 'payload', DECLARATION]] }
      fail!('attached schema roster differs') unless native[:schemas] == expected_schema
      fail!('attached active-part roster differs') unless native[:parts].keys.sort == all_tables.sort
      expected_rows = all_tables.product(%w[FULL FIRST_EMPTY LATER FINAL]).sort
      fail!('attached value-window roster differs') unless native[:value_rows].keys.sort == expected_rows
      expected_zero = all_tables.flat_map do |name|
        profile, = @table_identity.fetch(name)
        [["__W202_ZERO_BEGIN__", name, profile, 'values'], ["__W202_ZERO_END__", name, profile, 'values']]
      end
      fail!('attached EOF-window boundary roster differs') unless native[:zero_events] == expected_zero
      all_tables.each do |name|
        part = native[:parts].fetch(name)
        fail!("#{name} part identity/grid differs") unless
          part[:name] == 'all_1_1_0' && part[:type] == 'Wide' && part[:rows] == '8' && part[:marks] == '5'
        _profile, _mode, origin = @table_identity.fetch(name)
        assert_value_windows!(native, name, origin)
      end
    end

    def expected_dynamic_type(row, origin)
      return 'None' if row[:kind] == :null
      if origin == 'source'
        row[:kind] == :json ? 'JSON' : 'Array(JSON)'
      else
        row[:kind] == :json ? TYPED_JSON : TYPED_ARRAY_JSON
      end
    end

    def expected_native_rows(window, origin)
      indexes = WINDOWS.fetch(window)
      ROWS[indexes].map do |row|
        value = case row[:kind]
                when :json then JSON.generate({'v' => row[:values].fetch(0)})
                when :array then JSON.generate(row[:values].map { |item| {'v' => item} })
                when :null then nil
                end
        [row[:pk].to_s, expected_dynamic_type(row, origin), 'false',
         value ? value.unpack1('H*').upcase : '6E756C6C', '5B5D', '5B5D']
      end
    end

    def assert_value_windows!(native, table_name, origin)
      WINDOWS.each do |window, _range|
        actual = native[:value_rows].fetch([table_name, window], [])
        expected = expected_native_rows(window, origin)
        fail!("#{table_name}/#{window} native type/shared/literal/path observations differ: #{actual.inspect}") unless actual == expected
      end
    end

    def assert_helper_output!(data)
      expected_keys = %w[cells declaration format library_actual_types literal_scalar_values ordinary_dynamic_cap windows]
      fail!('helper output keys differ') unless data.keys.sort == expected_keys
      fail!('helper output format differs') unless data['format'] == FORMAT_OUTPUT
      fail!('helper declaration/ordinary cap differs') unless data['declaration'] == DECLARATION && data['ordinary_dynamic_cap'] == 2
      fail!('library typed JSON descriptor roster differs') unless data['library_actual_types'].sort == [TYPED_ARRAY_JSON, TYPED_JSON].sort
      fail!('literal child scalar roster differs') unless data['literal_scalar_values'] == [7, 8, 17, 18, 19, 20, 21, 22, 23]
      expected_windows = [
        {'window' => 'full', 'first_mark' => 0, 'mark_count' => 4},
        {'window' => 'first', 'first_mark' => 0, 'mark_count' => 1},
        {'window' => 'middle', 'first_mark' => 1, 'mark_count' => 2},
        {'window' => 'final', 'first_mark' => 3, 'mark_count' => 1},
        {'window' => 'eof', 'first_mark' => 4, 'mark_count' => 0},
      ]
      fail!('helper selected-window schedule differs') unless data['windows'] == expected_windows
      expected_cells = CELLS.map { |profile, mode| "#{profile}/#{mode}" }
      observed_cells = data.fetch('cells').map { |cell| "#{cell.fetch('profile_id')}/#{cell.fetch('mode_id')}" }
      fail!('helper profile/mode cell roster differs') unless observed_cells == expected_cells

      data.fetch('cells').each_with_index do |cell, index|
        profile, mode = CELLS.fetch(index)
        expected_cell = cell_id(profile, mode)
        fail!("#{expected_cell} helper identity differs") unless cell['cell_id'] == expected_cell
        expected_library = File.join(@root, 'generated', expected_cell, 'all_1_1_0')
        fail!("#{expected_cell} generated path differs") unless File.expand_path(cell['library_part_path']) == expected_library
        sides = {}
        %w[source library].each do |origin|
          side = cell.fetch(origin)
          expected_actuals = origin == 'source' ? ['Array(JSON)', 'JSON'] : [TYPED_ARRAY_JSON, TYPED_JSON].sort
          expected_scalar = origin == 'source' ? 'Int64' : 'UInt8'
          fail!("#{expected_cell}/#{origin} declared schema differs") unless side['schema_declaration'] == DECLARATION
          fail!("#{expected_cell}/#{origin} mark/value descriptor differs") unless
            side['row_count'] == 8 && side['mark_count'] == 4 && side['mark_row_counts'] == [2, 2, 2, 2]
          fail!("#{expected_cell}/#{origin} actual JSON descriptors differ") unless side['dynamic_actual_types'] == expected_actuals
          fail!("#{expected_cell}/#{origin} JSON v scalar type differs") unless side['json_v_scalar_type'] == expected_scalar
          %w[physical_stream_names selected_checksum_names].each do |key|
            names = side.fetch(key)
            fail!("#{expected_cell}/#{origin} #{key} is empty/duplicated") unless names.is_a?(Array) && !names.empty? && names.uniq == names
          end
          windows = side.fetch('windows')
          fail!("#{expected_cell}/#{origin} window roster differs") unless windows.size == expected_windows.size
          windows.each_with_index do |window, window_index|
            expected_window = expected_windows.fetch(window_index)
            fail!("#{expected_cell}/#{origin}/#{expected_window['window']} window bounds differ") unless
              window['window'] == expected_window['window'] && window['first_mark'] == expected_window['first_mark'] && window['mark_count'] == expected_window['mark_count']
            expected_rows = EXPECTED_ROWS_BY_MARK[
              expected_window['first_mark'], expected_window['mark_count']
            ] || []
            fail!("#{expected_cell}/#{origin}/#{expected_window['window']} literal rows differ") unless window['rows_by_mark'] == expected_rows
          end
          sides[origin] = side
        end
        fail!("#{expected_cell} source/library actual descriptors were not kept asymmetric") if
          sides['source']['dynamic_actual_types'] == sides['library']['dynamic_actual_types']
        fail!("#{expected_cell} source/library physical stream rosters unexpectedly match") if
          sides['source']['physical_stream_names'] == sides['library']['physical_stream_names']
        fail!("#{expected_cell} source/library scalar signatures differ") unless
          sides['source']['windows'].map { |window| window['rows_by_mark'] } == sides['library']['windows'].map { |window| window['rows_by_mark'] }

        @library_parts[expected_cell] = expected_library
        @library_snapshots[expected_cell] = mode_snapshot(expected_library)
      end
    end

    def write_evidence(data)
      summary = {
        probe: 'W215 asymmetric declared Object Dynamic plain-source/typed-library JSON witness',
        status: data[:status], fatal_error: data[:fatal_error],
        runtime: {path: @binary, expected_sha256: BINARY_SHA256,
                  sha256_before: @binary_sha_before, sha256_after: @binary_sha_after,
                  expected_version: VERSION, expected_build: BUILD},
        helper_pin: {path: @helper, sha256_before: @helper_sha_before, sha256_after: @helper_sha_after},
        limits: {max_threads: 1, local_max_memory_usage_bytes: W202::MEMORY,
                 timeout_seconds: W202::TIMEOUT, termination_grace_seconds: W202::GRACE,
                 executor: 'JsonBinaryKernelW180Probe#execute'},
        outer_guard: {
          memory_limit_mib: 1024, timeout_seconds: 120, status: 'declared_not_measured',
          note: 'Runner declaration only; actual outer-guard evidence is separate',
        },
        declaration: DECLARATION, source_sql_type: TYPE, profiles: PROFILES, modes: MODES, cells: CELLS,
        source_construction: 'Qualified Tuple(p Dynamic(max_types=2)) cast to outer JSON; inner typed JSON parameters are erased by ClickHouse and source actuals are plain JSON/Array(JSON).',
        descriptor_boundary: 'Stock source and library descriptors are intentionally asymmetric. Stock JSON v is discovered Int64; library JSON v is declared UInt8. No equivalent-descriptor claim.',
        literal_rows: ROWS, windows: WINDOWS.transform_values { |range| range.to_a },
        helper_input: @helper_input,
        evidence_root: @root, invocations: @invocations,
      }.merge(data.reject { |key, _| %i[status fatal_error].include?(key) })
      send(:write_new, File.join(@root, 'qualifier.json'), JSON.pretty_generate(summary) + "\n")
    end
  end

  def self.run_cli
    options = {binary: BINARY, helper: nil, root: nil}
    OptionParser.new do |parser|
      parser.banner = 'usage: ruby scripts/probe_object_typed_dynamic_json_w215.rb --crystal-helper PREBUILT --evidence-root EMPTY_DIRECT_CHILD_OF_PRIVATE_TMP [--clickhouse PINNED]'
      parser.on('--clickhouse PATH', 'Pinned ClickHouse 26.10.1.1201 executable') { |value| options[:binary] = value }
      parser.on('--crystal-helper PATH', 'Prebuilt Crystal helper; this runner never compiles it') { |value| options[:helper] = value }
      parser.on('--evidence-root PATH', 'Existing empty direct child of /private/tmp') { |value| options[:root] = value }
    end.parse!
    abort 'W215: --crystal-helper and --evidence-root are required' unless options[:helper] && options[:root]
    Probe.new(options[:binary], options[:helper], options[:root]).run ? 0 : 1
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit ProbeObjectTypedDynamicJSONW215.run_cli
  rescue StandardError => error
    warn "W215 runner error: #{error.class}: #{error.message}"
    exit 1
  end
end
