#!/usr/bin/env ruby
# Root-run stock/library ATTACH qualification for JSON(p Dynamic(max_types=0)).
# Native process execution is delegated to the bounded W180 executor; this
# runner never builds ClickHouse or compiles the Crystal helper.

require 'digest'
require 'find'
require 'json'
require 'optparse'
require_relative 'probe_nested_bulk_part_w202'

module ProbeObjectTypedDynamicSharedJSONW214
  W202 = ProbeNestedBulkPartW202
  W180 = W202::W180
  BINARY = W202::BINARY
  BINARY_SHA256 = W202::BINARY_SHA256
  VERSION = W202::VERSION
  BUILD = W202::BUILD
  TYPE = 'JSON(p Dynamic(max_types=0))'.freeze
  FORMAT_INPUT = 'object_typed_dynamic_shared_json_w214_input_v1'.freeze
  FORMAT_OUTPUT = 'object_typed_dynamic_shared_json_w214_helper_v1'.freeze
  PROFILES = %w[single_stream with_size_stream].freeze
  MODES = %w[basic compact].freeze
  CELLS = PROFILES.flat_map { |profile| MODES.map { |mode| [profile, mode] } }.freeze
  ROWS = [
    {id: 1, kind: :json, values: ['one']},
    {id: 2, kind: :json, values: ['two']},
    {id: 3, kind: :empty_inferred_array, values: []},
    {id: 4, kind: :array, values: ['four']},
    {id: 5, kind: :array, values: %w[five six]},
    {id: 6, kind: :null, values: []},
    {id: 7, kind: :missing, values: []},
    {id: 8, kind: :json, values: ['eight']},
  ].freeze
  # The empty JSON array is an inferred Array(Nullable(String)) actual in both
  # the stock source and the independently constructed library witness.
  NATIVE_ROWS = ROWS
  WINDOWS = {
    'FULL' => (0...8),
    'FIRST_EMPTY' => (0...2),
    'LATER' => (2...6),
    'FINAL' => (6...8),
    'ZERO' => (8...8),
  }.freeze
  HELPER_NATIVE_WINDOWS = {
    'full' => 'FULL', 'first' => 'FIRST_EMPTY', 'middle' => 'LATER',
    'final' => 'FINAL', 'eof' => 'ZERO',
  }.freeze
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

  class Probe < W202::Probe
    def initialize(binary, crystal_helper, evidence_root)
      super
      @token = Digest::SHA256.hexdigest(@root)[0, 8]
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
      send(:write_new, input_path, JSON.pretty_generate(build_helper_input) + "\n")
      helper = run_helper(input_path)
      assert_helper_output!(helper[:data])
      attach_library_parts!

      attached = send(:run_clickhouse, 'attach_and_check', attached_sql)
      send(:assert_native_invocation!, attached)
      attached_native = send(:parse_native, attached[:stdout])
      send(:assert_pin!, attached_native)
      assert_attached_native!(attached_native)

      @source_parts.each do |table_name, path|
        fail!("stock source part changed: #{table_name}") unless mode_snapshot(path) == @source_snapshots.fetch(table_name)
      end
      @library_parts.each do |cell, path|
        fail!("generated library part changed: #{cell}") unless mode_snapshot(path) == @library_snapshots.fetch(cell)
      end
      @binary_sha_after = send(:binary_sha)
      @helper_sha_after = send(:helper_sha)
      fail!('pinned ClickHouse executable SHA changed during probe') unless @binary_sha_after == BINARY_SHA256
      fail!('prebuilt Crystal helper SHA changed during probe') unless @helper_sha_after == @helper_sha_before

      write_evidence(
        status: 'paired_typed_dynamic_json_observed',
        native_source: native,
        helper: helper[:data], helper_invocation: helper[:record],
        native_attached: attached_native,
        source_part_snapshots: @source_snapshots,
        library_part_snapshots: @library_snapshots,
        boundary: 'Only declared JSON(p Dynamic(max_types=0)); root/inferred Dynamic and Object shared paths are excluded. Native empty [] is inferred as Array(Nullable(String)), not Array(JSON).',
      )
      puts "W214 typed Object Dynamic JSON paired probe cells=#{CELLS.size}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @binary_sha_after = send(:binary_sha) rescue nil
      @helper_sha_after = send(:helper_sha) rescue nil
      write_evidence(status: 'runner_failure_or_observations_differ', fatal_error: @fatal_error) rescue nil
      warn "W214 probe failure (process failure is not format evidence): #{@fatal_error}"
      false
    end

    private

    def fail!(message)
      raise RuntimeError, "W214 typed Dynamic JSON oracle: #{message}"
    end

    def run_clickhouse(label, sql)
      invocation = super
      annotate_invocation!(label, invocation[:record])
      invocation
    end

    def cell_id(profile, mode)
      "#{profile}_#{mode}"
    end

    def table(profile, mode, origin)
      short_profile = profile == 'single_stream' ? 'single' : 'withsize'
      "w214_#{@token}_#{short_profile}_#{mode}_#{origin}"
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
        inserts = NATIVE_ROWS.map do |row|
          raw = case row[:kind]
                when :json then JSON.generate({'p' => {'s' => row[:values].fetch(0)}})
                when :array then JSON.generate({'p' => row[:values].map { |text| {'s' => text} }})
                when :empty_inferred_array then JSON.generate({'p' => []})
                when :null then '{"p":null}'
                when :missing then '{}'
                else fail!("unknown literal row kind #{row[:kind].inspect}")
                end
          "(#{row[:id]}, CAST('#{raw}', '#{TYPE}'))"
        end
        statements << "INSERT INTO default.#{name} VALUES\n#{inserts.join(",\n")};"
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
        profile, mode, = @table_identity.fetch(name)
        statements.concat(value_queries(name, profile, mode))
      end
      statements.join("\n") + "\n"
    end

    def value_queries(table_name, profile, mode)
      windows = {
        'FULL' => '',
        'FIRST_EMPTY' => ' WHERE pk BETWEEN 1 AND 2',
        'LATER' => ' WHERE pk BETWEEN 3 AND 6',
        'FINAL' => ' WHERE pk BETWEEN 7 AND 8',
        'ZERO' => ' WHERE pk > 8',
      }
      windows.flat_map do |window, predicate|
        tag = "__W202_VALUES_#{window}__"
        query = "SELECT '#{tag}', '#{table_name}', toString(pk), dynamicType(payload.p), " \
                "if(isDynamicElementInSharedData(payload.p), 'true', 'false'), " \
                "hex(toJSONString(payload.p)), hex(toJSONString(JSONDynamicPaths(payload))), " \
                "hex(toJSONString(JSONSharedDataPaths(payload))) FROM default.#{table_name}#{predicate} " \
                "ORDER BY pk FORMAT TSVRaw;"
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
      annotate_invocation!('crystal_helper', invocation[:record])
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

    def annotate_invocation!(label, record)
      # The inherited W202 value is compiler-sized, not this runner's outer guard.
      # The runner records a declaration; measured root-guard evidence is separate.
      record.delete(:required_outer_run_safe_memory_limit_bytes)
      record[:outer_guard] = {
        memory_limit_mib: 1024, timeout_seconds: 120, status: 'declared_not_measured',
        note: 'Runner declaration only; actual outer-guard evidence is separate',
      }
      path = File.join(@root, 'invocations', "#{label}.json")
      stat = File.lstat(path)
      fail!("refusing to rewrite non-regular invocation evidence: #{label}") unless stat.file? && !stat.symlink?
      File.open(path, 'wb') { |file| file.write(JSON.pretty_generate(record) + "\n") }
    end

    def build_helper_input
      capture_root = File.realpath(File.join(@root, 'stores', 'native'))
      cells = CELLS.map do |profile, mode|
        cell = cell_id(profile, mode)
        source = table(profile, mode, 'source')
        library_part = File.join(@root, 'generated', cell, 'all_1_1_0')
        {
          'cell_id' => cell,
          'capture_root' => capture_root,
          'profile_id' => profile,
          'mode_id' => mode,
          'source_part' => @source_parts.fetch(source),
          'library_part' => library_part,
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
      expected_schema = all_tables.sort.flat_map { |name| [[name, 'pk', 'UInt64'], [name, 'payload', TYPE]] }
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
        assert_value_windows!(native, name)
      end
    end

    def assert_attached_native!(native)
      expected_checks = all_tables.to_h do |name|
        profile, = @table_identity.fetch(name)
        [[name, profile], ["all_1_1_0\t1\t"]]
      end
      fail!("source/library CHECK differs: #{native[:checks].inspect}") unless native[:checks] == expected_checks
      expected_schema = all_tables.sort.flat_map { |name| [[name, 'pk', 'UInt64'], [name, 'payload', TYPE]] }
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
        assert_value_windows!(native, name)
      end
    end

    def expected_signatures(rows = ROWS)
      rows.map do |row|
        case row[:kind]
        when :json then "JSON(#{row[:values].fetch(0)})"
        when :array then "Array(JSON):[#{row[:values].map { |value| "JSON(#{value})" }.join(',')}]"
        when :empty_inferred_array then 'Array(Nullable(String)):[]'
        when :null, :missing then 'NULL'
        end
      end
    end

    def expected_window_signatures(window, origin)
      native_window = HELPER_NATIVE_WINDOWS.fetch(window)
      indexes = WINDOWS.fetch(native_window)
      rows = origin == 'source' ? NATIVE_ROWS : ROWS
      selected = expected_signatures(rows)[indexes]
      return [] if native_window == 'ZERO'
      selected.each_slice(2).map(&:to_a)
    end

    def expected_native_rows(window)
      indexes = WINDOWS.fetch(window)
      NATIVE_ROWS[indexes].map do |row|
        type = case row[:kind]
               when :json then 'JSON'
               when :array then 'Array(JSON)'
               when :empty_inferred_array then 'Array(Nullable(String))'
               when :null, :missing then 'None'
               end
        shared = %i[json array empty_inferred_array].include?(row[:kind]) ? 'true' : 'false'
        value = case row[:kind]
                when :json then JSON.generate({'s' => row[:values].fetch(0)})
                when :array then JSON.generate(row[:values].map { |text| {'s' => text} })
                when :empty_inferred_array then JSON.generate([])
                when :null, :missing then nil
                end
        json_hex = value ? value.unpack1('H*').upcase : '\N'
        empty_paths_hex = '5B5D'
        [row[:id].to_s, type, shared, json_hex, empty_paths_hex, empty_paths_hex]
      end
    end

    def assert_value_windows!(native, table_name)
      WINDOWS.each_key do |window|
        actual = native[:value_rows].fetch([table_name, window], [])
        expected = expected_native_rows(window)
        fail!("#{table_name}/#{window} native values/types/shared/path projections differ: #{actual.inspect}") unless actual == expected
      end
    end

    def assert_helper_output!(data)
      expected_keys = %w[cells declaration format ordinary_roster_empty windows]
      fail!('helper output keys differ') unless data.keys.sort == expected_keys
      fail!('helper declaration or empty-roster contract differs') unless
        data['declaration'] == TYPE && data['ordinary_roster_empty'] == true
      expected_cells = CELLS.map { |profile, mode| "#{profile}/#{mode}" }
      observed_cells = data.fetch('cells').map { |cell| "#{cell.fetch('profile_id')}/#{cell.fetch('mode_id')}" }
      fail!('helper profile/mode cell roster differs') unless observed_cells == expected_cells
      expected_windows = [
        {'window' => 'full', 'first_mark' => 0, 'mark_count' => 4},
        {'window' => 'first', 'first_mark' => 0, 'mark_count' => 1},
        {'window' => 'middle', 'first_mark' => 1, 'mark_count' => 2},
        {'window' => 'final', 'first_mark' => 3, 'mark_count' => 1},
        {'window' => 'eof', 'first_mark' => 4, 'mark_count' => 0},
      ]
      fail!('helper selected-window schedule differs') unless data['windows'] == expected_windows

      data.fetch('cells').each_with_index do |cell, index|
        profile, mode = CELLS.fetch(index)
        expected_cell_id = cell_id(profile, mode)
        fail!("helper cell #{expected_cell_id} identity differs") unless cell['cell_id'] == expected_cell_id
        expected_library = File.join(@root, 'generated', expected_cell_id, 'all_1_1_0')
        fail!("helper cell #{expected_cell_id} library path differs") unless File.expand_path(cell['library_part_path']) == expected_library
        %w[source library].each do |origin|
          side = cell.fetch(origin)
          fail!("#{expected_cell_id}/#{origin} descriptor differs") unless
            side['schema_declaration'] == TYPE && side['row_count'] == 8 && side['mark_count'] == 4 &&
            side['mark_row_counts'] == [2, 2, 2, 2] && side['ordinary_dynamic_types'] == []
          %w[physical_stream_names selected_checksum_names].each do |key|
            names = side.fetch(key)
            fail!("#{expected_cell_id}/#{origin} #{key} is empty/duplicated") unless names.is_a?(Array) && !names.empty? && names.uniq == names
          end
          expected_windows.each_with_index do |window, window_index|
            observed = side.fetch('windows').fetch(window_index)
            fail!("#{expected_cell_id}/#{origin}/#{window['window']} window metadata differs") unless
              observed['window'] == window['window'] && observed['first_mark'] == window['first_mark'] && observed['mark_count'] == window['mark_count']
            fail!("#{expected_cell_id}/#{origin}/#{window['window']} literal values differ") unless
              observed['rows_by_mark'] == expected_window_signatures(window['window'], origin)
          end
        end
        fail!("#{expected_cell_id} source/library helper observations differ") unless cell['source'] == cell['library']
        @library_parts[expected_cell_id] = expected_library
        @library_snapshots[expected_cell_id] = mode_snapshot(expected_library)
      end
    end

    def attach_library_parts!
      CELLS.each do |profile, mode|
        cell = cell_id(profile, mode)
        path = send(:validate_generated_part!, @library_parts.fetch(cell), cell)
        target = table(profile, mode, 'library')
        @executor.send(:attach_part!, path, send(:validate_store_path!, @data_paths.fetch(target)))
      end
    end

    def mode_snapshot(path)
      send(:validate_plain_tree!, path)
      Find.find(path).sort.each_with_object({}) do |entry, output|
        next if entry == path
        relative = entry.delete_prefix(path + File::SEPARATOR)
        stat = File.lstat(entry)
        output[relative] = if stat.directory?
                             {type: 'directory', mode: stat.mode & 0o777}
                           else
                             {type: 'file', size: stat.size, sha256: Digest::SHA256.file(entry).hexdigest,
                              mode: stat.mode & 0o777}
                           end
      end
    end

    def write_evidence(data)
      summary = {
        probe: 'W214 declared typed Dynamic JSON paired stock/library qualification',
        status: data[:status], fatal_error: data[:fatal_error],
        runtime: {path: @binary, expected_sha256: BINARY_SHA256,
                  sha256_before: @binary_sha_before, sha256_after: @binary_sha_after,
                  expected_version: VERSION, expected_build: BUILD},
        helper: {path: @helper, sha256_before: @helper_sha_before, sha256_after: @helper_sha_after},
        limits: {max_threads: 1, local_max_memory_usage_bytes: W202::MEMORY,
                 timeout_seconds: W202::TIMEOUT, termination_grace_seconds: W202::GRACE,
                 executor: 'JsonBinaryKernelW180Probe#execute'},
        outer_guard: {
          memory_limit_mib: 1024, timeout_seconds: 120, status: 'declared_not_measured',
          note: 'Runner declaration only; actual outer-guard evidence is separate',
        },
        declaration: TYPE, profiles: PROFILES, modes: MODES, cells: CELLS,
        rows: {stock_source: NATIVE_ROWS, library_witness: ROWS},
        empty_array_distinction: {
          stock_source: {
            construction: 'JSON text inference', kind: 'empty_inferred_array',
            dynamic_type: 'Array(Nullable(String))', signature: 'Array(Nullable(String)):[]',
          },
          library_witness: {
            construction: 'explicit Binary Dynamic actual', kind: 'empty_inferred_array',
            dynamic_type: 'Array(Nullable(String))', signature: 'Array(Nullable(String)):[]',
          },
        },
        windows: WINDOWS.transform_values { |range| range.to_a },
        evidence_root: @root, invocations: @invocations,
      }.merge(data.reject { |key, _| %i[status fatal_error].include?(key) })
      send(:write_new, File.join(@root, 'qualifier.json'), JSON.pretty_generate(summary) + "\n")
    end
  end

  def self.run_cli
    options = {binary: BINARY, helper: nil, root: nil}
    OptionParser.new do |parser|
      parser.banner = 'usage: ruby scripts/probe_object_typed_dynamic_shared_json_w214.rb --crystal-helper PREBUILT --evidence-root EMPTY_DIRECT_CHILD_OF_PRIVATE_TMP [--clickhouse PINNED]'
      parser.on('--clickhouse PATH', 'Pinned ClickHouse 26.10.1.1201 executable') { |value| options[:binary] = value }
      parser.on('--crystal-helper PATH', 'Prebuilt Crystal helper; this runner never compiles it') { |value| options[:helper] = value }
      parser.on('--evidence-root PATH', 'Existing empty direct child of /private/tmp') { |value| options[:root] = value }
    end.parse!
    abort 'W214: --crystal-helper and --evidence-root are required' unless options[:helper] && options[:root]
    Probe.new(options[:binary], options[:helper], options[:root]).run ? 0 : 1
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit ProbeObjectTypedDynamicSharedJSONW214.run_cli
  rescue StandardError => error
    warn "W214 runner error: #{error.class}: #{error.message}"
    exit 1
  end
end
