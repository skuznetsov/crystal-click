#!/usr/bin/env ruby
# Bounded stock/library qualification for direct and Array(JSON) actuals in
# inferred Dynamic paths of a root Object column. Stock input is literal
# Object RowBinary; the library helper independently writes the same roster.

require 'digest'
require 'json'
require 'optparse'
require_relative 'probe_nested_bulk_part_w202'

module ProbeObjectInferredDynamicJSONW216
  W202 = ProbeNestedBulkPartW202
  BINARY = W202::BINARY
  BINARY_SHA256 = W202::BINARY_SHA256
  VERSION = W202::VERSION
  BUILD = W202::BUILD
  TYPE_SQL = 'JSON(max_dynamic_paths=16,max_dynamic_types=4)'.freeze
  DECLARATION = 'JSON(max_dynamic_types=4, max_dynamic_paths=16)'.freeze
  TYPED_JSON = 'JSON(max_dynamic_types=0, max_dynamic_paths=0, v UInt8)'.freeze
  TYPED_ARRAY_JSON = "Array(#{TYPED_JSON})".freeze
  FORMAT_INPUT = 'object_inferred_dynamic_json_w216_input_v1'.freeze
  FORMAT_OUTPUT = 'object_inferred_dynamic_json_w216_helper_v1'.freeze
  # Pinned ClickHouse 26.10.1.1201 adds this one metadata file when a
  # library-authored Wide part is attached. Source parts and the generated
  # pre-ATTACH snapshot remain exact and immutable.
  ATTACH_INVALIDATED_SYSTEM_COLUMNS_NAME = 'invalidated_system_columns.txt'.freeze
  ATTACH_INVALIDATED_SYSTEM_COLUMNS_CONTENT = "_block_offset\n_block_number\n".b.freeze
  ATTACH_INVALIDATED_SYSTEM_COLUMNS_MODE = 0o644
  PROFILES = %w[single_stream with_size_stream].freeze
  MODES = %w[basic compact].freeze
  CELLS = PROFILES.flat_map { |profile| MODES.map { |mode| [profile, mode] } }.freeze
  WINDOWS = {
    'FULL' => (0...8), 'FIRST_MARK' => (0...2), 'LATER' => (2...6),
    'FINAL' => (6...8), 'ZERO' => (8...8),
  }.freeze
  HELPER_WINDOWS = [
    {'window' => 'full', 'first_mark' => 0, 'mark_count' => 4},
    {'window' => 'first', 'first_mark' => 0, 'mark_count' => 1},
    {'window' => 'middle', 'first_mark' => 1, 'mark_count' => 2},
    {'window' => 'final', 'first_mark' => 3, 'mark_count' => 1},
    {'window' => 'eof', 'first_mark' => 4, 'mark_count' => 0},
  ].freeze
  ROWS = [
    {pk: 1, kind: :json, value: 7, label: 'ordinary-first'},
    {pk: 2, kind: :array, value: [8, 9], label: nil},
    {pk: 3, kind: :absent, value: nil, label: 'sparse'},
    {pk: 4, kind: :json, value: 0, label: nil},
    {pk: 5, kind: :array, value: [], label: nil},
    {pk: 6, kind: :absent, value: nil, label: 'tail'},
    {pk: 7, kind: :json, value: 20, label: nil},
    {pk: 8, kind: :array, value: [21], label: nil},
  ].freeze
  EXPECTED_BY_MARK = [
    [['JSON(7)', 'ordinary-first'], ['ARRAY[JSON(8),JSON(9)]', 'ABSENT']],
    [['ABSENT', 'sparse'], ['JSON(0)', 'ABSENT']],
    [['ARRAY[]', 'ABSENT'], ['ABSENT', 'tail']],
    [['JSON(20)', 'ABSENT'], ['ARRAY[JSON(21)]', 'ABSENT']],
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

  class Probe < W202::Probe
    def initialize(binary, crystal_helper, evidence_root)
      super
      @token = Digest::SHA256.hexdigest(@root)[0, 8]
      @table_identity = {}
      CELLS.each do |profile, mode|
        %w[source library].each { |origin| @table_identity[table(profile, mode, origin)] = [profile, mode, origin] }
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
      input_bytes = rowbinary
      input_path = File.join(@root, 'inputs', 'payload.rowbinary')
      send(:write_new, input_path, input_bytes)
      @rowbinary_input = {path: input_path, bytes: input_bytes.bytesize, sha256: Digest::SHA256.hexdigest(input_bytes)}

      initial = send(:run_clickhouse, 'native_sources', initial_sql(input_path))
      send(:assert_native_invocation!, initial)
      native = send(:parse_native, initial[:stdout])
      send(:assert_pin!, native)
      assert_initial_native!(native)

      input = build_helper_input
      helper_input_path = File.join(@root, 'inputs', 'helper-input.json')
      helper_input_bytes = JSON.pretty_generate(input) + "\n"
      send(:write_new, helper_input_path, helper_input_bytes)
      @helper_input = {path: helper_input_path, bytes: helper_input_bytes.bytesize,
                       sha256: Digest::SHA256.hexdigest(helper_input_bytes)}
      helper = run_helper(helper_input_path)
      assert_helper_output!(helper[:data])
      attach_library_parts!

      attached = send(:run_clickhouse, 'attach_and_check', attached_sql)
      send(:assert_native_invocation!, attached)
      attached_native = send(:parse_native, attached[:stdout])
      send(:assert_pin!, attached_native)
      assert_attached_native!(attached_native)

      @source_parts.each do |table_name, path|
        fail!("stock source part changed during ATTACH/SELECT: #{table_name}") unless send(:snapshot_part, path) == @source_snapshots.fetch(table_name)
      end
      @library_parts.each do |cell, path|
        fail!("generated library part changed during ATTACH/SELECT: #{cell}") unless send(:snapshot_part, path) == @library_snapshots.fetch(cell)
      end
      @binary_sha_after = send(:binary_sha)
      @helper_sha_after = send(:helper_sha)
      fail!('pinned ClickHouse executable SHA changed during probe') unless @binary_sha_after == BINARY_SHA256
      fail!('prebuilt Crystal helper SHA changed during probe') unless @helper_sha_after == @helper_sha_before

      write_evidence(status: 'paired_inferred_dynamic_json_observed', source: native,
                     helper: helper[:data], helper_invocation: helper[:record],
                     initial_invocation: initial[:record], attached: attached_native,
                     attached_invocation: attached[:record], source_part_snapshots: @source_snapshots,
                     library_part_snapshots: @library_snapshots)
      puts "W216 inferred Object Dynamic JSON probe cells=#{CELLS.size}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @binary_sha_after = send(:binary_sha) rescue nil
      @helper_sha_after = send(:helper_sha) rescue nil
      write_evidence(status: 'runner_failure_or_observations_differ', fatal_error: @fatal_error) rescue nil
      warn "W216 probe failure (process failure is not format evidence): #{@fatal_error}"
      false
    end

    private

    def fail!(message)
      raise RuntimeError, "W216 inferred Object Dynamic JSON oracle: #{message}"
    end

    def cell_id(profile, mode)
      "#{profile}_#{mode}"
    end

    def table(profile, mode, origin)
      short_profile = profile == 'single_stream' ? 'single' : 'withsize'
      "w216_#{@token}_#{short_profile}_#{mode}_#{origin}"
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

    def initial_sql(input_path)
      escaped_path = input_path.gsub("'", "\\'")
      statements = [
        'SET flatten_nested=0;',
        'SET input_format_binary_read_json_as_string=0;',
        'SET output_format_json_named_tuples_as_objects=1;',
        'SET print_pretty_type_names=0;',
        "SELECT '__W202_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
      ]
      CELLS.each do |profile, mode|
        %w[source library].each do |origin|
          name = table(profile, mode, origin)
          statements << "CREATE TABLE default.#{name} (pk UInt64, payload #{TYPE_SQL}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings(profile, mode)};"
        end
      end
      CELLS.each do |profile, mode|
        name = table(profile, mode, 'source')
        statements << "INSERT INTO default.#{name} SELECT * FROM file('#{escaped_path}', 'RowBinary', 'pk UInt64, payload #{TYPE_SQL}');"
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
      CELLS.each { |profile, mode| statements << "ALTER TABLE default.#{table(profile, mode, 'library')} ATTACH PART 'all_1_1_0';" }
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

    def value_queries(name, profile, mode)
      WINDOWS.flat_map do |window, range|
        # Reuse the inherited W202 parser's exact bounded tag vocabulary while
        # retaining W216's semantic name for its first populated mark window.
        native_window = window == 'FIRST_MARK' ? 'FIRST_EMPTY' : window
        tag = "__W202_VALUES_#{native_window}__"
        predicate = window == 'FULL' ? '' : " WHERE pk BETWEEN #{range.begin + 1} AND #{range.end}"
        if range.size.zero?
          predicate = ' WHERE pk > 8'
        end
        query = "SELECT '#{tag}', '#{name}', toString(pk), " \
                "if(isNull(payload.p), 'None', dynamicType(payload.p)), " \
                "if(isNull(payload.p), '6E756C6C', hex(toJSONString(payload.p))), " \
                "if(isNull(payload.label), 'None', dynamicType(payload.label)), " \
                "if(isNull(payload.label), '6E756C6C', hex(toJSONString(payload.label))), " \
                "toTypeName(payload) FROM default.#{name}#{predicate} ORDER BY pk FORMAT TSVRaw;"
        if window == 'ZERO'
          ["SELECT '__W202_ZERO_BEGIN__', '#{name}', '#{profile}', 'values' FORMAT TSVRaw;", query,
           "SELECT '__W202_ZERO_END__', '#{name}', '#{profile}', 'values' FORMAT TSVRaw;"]
        else
          [query]
        end
      end
    end

    def parse_native(stdout)
      native = super
      value_rows = {}
      native[:value_rows].each do |(table_name, window), rows|
        w216_window = window == 'FIRST_EMPTY' ? 'FIRST_MARK' : window
        key = [table_name, w216_window]
        fail!('native value-window aliases collide') if value_rows.has_key?(key)
        value_rows[key] = rows
      end
      native.merge(value_rows: value_rows)
    end

    def rowbinary
      json_descriptor = [0x30, 0, 0, 0, 1, 1, 0x76, 1, 0, 0].pack('C*').b
      json_row = ->(value) { [1, 1, 0x76, value].pack('C*').b }
      string = ->(value) { varuint(value.bytesize) + value.b }
      direct = ->(value) { json_descriptor + json_row.call(value) }
      array = ->(values) { [0x1e].pack('C') + json_descriptor + varuint(values.size) + values.map { |value| json_row.call(value) }.join.b }
      ROWS.map do |row|
        entries = []
        payload = case row[:kind]
                  when :json then direct.call(row[:value])
                  when :array then array.call(row[:value])
                  when :absent then nil
                  else fail!("unrostered row kind #{row[:kind].inspect}")
                  end
        entries << string.call('p') + payload if payload
        entries << string.call('label') + [0x15].pack('C') + string.call(row[:label]) if row[:label]
        [row[:pk]].pack('Q<') + varuint(entries.size) + entries.join.b
      end.join.b
    end

    def varuint(value)
      result = +''.b
      loop do
        byte = value & 0x7f
        value >>= 7
        byte |= 0x80 unless value.zero?
        result << byte
        break if value.zero?
      end
      result
    end

    def run_helper(input_path)
      before = send(:helper_sha)
      fail!('prebuilt Crystal helper changed before invocation') unless before == @helper_sha_before
      argv = [@helper, input_path, @root]
      invocation = @executor.send(:execute_record, 'crystal_helper', argv, ''.b,
                                  'prebuilt Crystal helper', before, @helper)
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
        {
          'cell_id' => cell, 'capture_root' => capture_root,
          'profile_id' => profile, 'mode_id' => mode,
          'source_part' => @source_parts.fetch(table(profile, mode, 'source')),
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
      fail!('stock CHECK roster/results differ') unless native[:checks] == expected_checks
      expected_schema = all_tables.sort.flat_map { |name| [[name, 'pk', 'UInt64'], [name, 'payload', DECLARATION]] }
      fail!('stock source/empty-library schema roster differs') unless native[:schemas] == expected_schema
      fail!('native data-path roster differs') unless native[:data_paths].keys.sort == all_tables.sort
      native[:data_paths].each_value { |path| send(:validate_store_path!, path) }
      fail!('native data paths are not unique per table') unless native[:data_paths].values.uniq.size == all_tables.size
      @data_paths = native[:data_paths].dup
      expected_zero = source_tables.flat_map do |name|
        profile, = @table_identity.fetch(name)
        [["__W202_ZERO_BEGIN__", name, profile, 'values'], ["__W202_ZERO_END__", name, profile, 'values']]
      end
      fail!('native EOF marker roster differs') unless native[:zero_events] == expected_zero
      fail!('stock source part roster differs') unless native[:parts].keys.sort == source_tables.sort
      expected_keys = source_tables.product(%w[FULL FIRST_MARK LATER FINAL]).sort
      fail!('stock value window roster differs') unless native[:value_rows].keys.sort == expected_keys
      source_tables.each do |name|
        part = native[:parts].fetch(name)
        fail!("#{name} part identity/grid differs") unless part[:name] == 'all_1_1_0' && part[:type] == 'Wide' && part[:rows] == '8' && part[:marks] == '5'
        path = send(:validate_source_part!, part[:path])
        expected_path = File.join(send(:validate_store_path!, @data_paths.fetch(name)), 'all_1_1_0')
        fail!("#{name} source part path does not match its table data path") unless path == expected_path
        @source_parts[name] = path
        @source_snapshots[name] = send(:snapshot_part, path)
        assert_value_windows!(native, name)
      end
    end

    def assert_attached_native!(native)
      expected_checks = all_tables.to_h do |name|
        profile, = @table_identity.fetch(name)
        [[name, profile], ["all_1_1_0\t1\t"]]
      end
      fail!('stock/library CHECK roster/results differ') unless native[:checks] == expected_checks
      expected_schema = all_tables.sort.flat_map { |name| [[name, 'pk', 'UInt64'], [name, 'payload', DECLARATION]] }
      fail!('attached schema roster differs') unless native[:schemas] == expected_schema
      fail!('attached part roster differs') unless native[:parts].keys.sort == all_tables.sort
      expected_keys = all_tables.product(%w[FULL FIRST_MARK LATER FINAL]).sort
      fail!('attached value window roster differs') unless native[:value_rows].keys.sort == expected_keys
      expected_zero = all_tables.flat_map do |name|
        profile, = @table_identity.fetch(name)
        [["__W202_ZERO_BEGIN__", name, profile, 'values'], ["__W202_ZERO_END__", name, profile, 'values']]
      end
      fail!('attached EOF marker roster differs') unless native[:zero_events] == expected_zero
      all_tables.each do |name|
        part = native[:parts].fetch(name)
        fail!("#{name} attached part identity/grid differs") unless part[:name] == 'all_1_1_0' && part[:type] == 'Wide' && part[:rows] == '8' && part[:marks] == '5'
        path = send(:validate_source_part!, part[:path])
        expected_path = File.join(send(:validate_store_path!, @data_paths.fetch(name)), 'all_1_1_0')
        fail!("#{name} attached part path does not match its table data path") unless path == expected_path
        profile, mode, origin = @table_identity.fetch(name)
        expected_snapshot = if origin == 'source'
                              @source_snapshots.fetch(name)
                            else
                              @library_snapshots.fetch(cell_id(profile, mode))
                            end
        attached_snapshot = send(:snapshot_part, path)
        if origin == 'library'
          if expected_snapshot.has_key?(ATTACH_INVALIDATED_SYSTEM_COLUMNS_NAME)
            fail!("#{name} generated library manifest unexpectedly contains the ATTACH-only metadata file")
          end
          allowed_metadata = {
            type: 'file',
            size: ATTACH_INVALIDATED_SYSTEM_COLUMNS_CONTENT.bytesize,
            sha256: Digest::SHA256.hexdigest(ATTACH_INVALIDATED_SYSTEM_COLUMNS_CONTENT),
          }
          expected_attached_snapshot = expected_snapshot.merge(
            ATTACH_INVALIDATED_SYSTEM_COLUMNS_NAME => allowed_metadata,
          )
          fail!("#{name} attached stored files differ from the immutable generated manifest plus the exact ATTACH metadata file") unless attached_snapshot == expected_attached_snapshot

          metadata_path = File.join(path, ATTACH_INVALIDATED_SYSTEM_COLUMNS_NAME)
          metadata_stat = File.lstat(metadata_path)
          unless metadata_stat.file? && !metadata_stat.symlink? &&
                 (metadata_stat.mode & 0o7777) == ATTACH_INVALIDATED_SYSTEM_COLUMNS_MODE &&
                 File.binread(metadata_path) == ATTACH_INVALIDATED_SYSTEM_COLUMNS_CONTENT
            fail!("#{name} ATTACH metadata file differs from the pinned content/mode")
          end
        else
          fail!("#{name} attached source files differ from the immutable source manifest") unless attached_snapshot == expected_snapshot
        end
        assert_value_windows!(native, name)
      end
    end

    def expected_native_rows(window)
      indexes = WINDOWS.fetch(window)
      ROWS[indexes].map do |row|
        p_type, p_value = case row[:kind]
                          when :json then [TYPED_JSON, {'v' => row[:value]}]
                          when :array then [TYPED_ARRAY_JSON, row[:value].map { |value| {'v' => value} }]
                          when :absent then ['None', nil]
                          end
        [row[:pk].to_s, p_type, p_value,
         row[:label].nil? ? 'None' : 'String', row[:label], DECLARATION]
      end
    end

    def parse_hex_json(hex)
      fail!('native value hex is malformed') unless hex.match?(/\A(?:[0-9A-Fa-f]{2})*\z/)
      JSON.parse([hex].pack('H*'))
    rescue JSON::ParserError => error
      fail!("native value hex is invalid JSON: #{error.message}")
    end

    def assert_value_windows!(native, table_name)
      WINDOWS.each_key do |window|
        actual = native[:value_rows].fetch([table_name, window], []).map do |fields|
          [fields[0], fields[1], parse_hex_json(fields[2]), fields[3], parse_hex_json(fields[4]), fields[5]]
        end
        expected = expected_native_rows(window)
        fail!("#{table_name}/#{window} actual type/literal rows differ: #{actual.inspect}") unless actual == expected
      end
    end

    def assert_helper_output!(data)
      fail!('helper output keys/format differ') unless data.keys.sort == %w[actual_types cells declaration format literal_values windows] && data['format'] == FORMAT_OUTPUT
      fail!('helper schema declaration differs') unless data['declaration'] == DECLARATION
      fail!('helper actual descriptor roster differs') unless data['actual_types'] == [TYPED_ARRAY_JSON, TYPED_JSON].sort
      fail!('helper independent scalar literals differ') unless data['literal_values'] == [7, 8, 9, 0, 20, 21]
      fail!('helper windows differ') unless data['windows'] == HELPER_WINDOWS
      observed_cells = data.fetch('cells').map { |cell| "#{cell.fetch('profile_id')}/#{cell.fetch('mode_id')}" }
      fail!('helper cell roster/order differs') unless observed_cells == CELLS.map { |profile, mode| "#{profile}/#{mode}" }
      data.fetch('cells').each_with_index do |cell, index|
        profile, mode = CELLS.fetch(index)
        id = cell_id(profile, mode)
        fail!("#{id} helper identity differs") unless cell['cell_id'] == id
        expected_library = File.join(@root, 'generated', id, 'all_1_1_0')
        fail!("#{id} helper destination differs") unless File.expand_path(cell['library_part_path']) == expected_library
        %w[source library].each do |origin|
          side = cell.fetch(origin)
          fail!("#{id}/#{origin} helper origin identity differs") unless side['origin'] == origin
          fail!("#{id}/#{origin} descriptor/mark metadata differs") unless
            side['schema_declaration'] == DECLARATION && side['row_count'] == 8 && side['mark_count'] == 4 &&
            side['mark_row_counts'] == [2, 2, 2, 2] && side['dynamic_actual_types'] == [TYPED_ARRAY_JSON, TYPED_JSON].sort
          %w[physical_stream_names selected_checksum_names].each do |key|
            names = side.fetch(key)
            fail!("#{id}/#{origin} #{key} is empty or duplicated") unless names.is_a?(Array) && !names.empty? && names.uniq == names
          end
          side_windows = side.fetch('windows')
          fail!("#{id}/#{origin} window roster differs") unless side_windows.size == HELPER_WINDOWS.size
          side_windows.each_with_index do |window, wi|
            bounds = HELPER_WINDOWS.fetch(wi)
            fail!("#{id}/#{origin}/#{bounds['window']} window bounds differ") unless
              window['window'] == bounds['window'] && window['first_mark'] == bounds['first_mark'] && window['mark_count'] == bounds['mark_count']
            first = bounds['first_mark']
            count = bounds['mark_count']
            expected_rows = EXPECTED_BY_MARK[first, count] || []
            fail!("#{id}/#{origin}/#{bounds['window']} literal rows differ") unless window['rows_by_mark'] == expected_rows
          end
        end
        semantic_keys = %w[schema_declaration row_count mark_count mark_row_counts dynamic_actual_types windows]
        source_semantics = cell.fetch('source').select { |key, _| semantic_keys.include?(key) }
        library_semantics = cell.fetch('library').select { |key, _| semantic_keys.include?(key) }
        fail!("#{id} stock/library literal reads diverged") unless source_semantics == library_semantics
        @library_parts[id] = expected_library
        @library_snapshots[id] = send(:snapshot_part, expected_library)
      end
    end

    def attach_library_parts!
      CELLS.each do |profile, mode|
        id = cell_id(profile, mode)
        path = @library_parts.fetch(id)
        fail!("generated library part missing or noncanonical: #{id}") unless File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path
        send(:validate_plain_tree!, path)
        target = table(profile, mode, 'library')
        @executor.send(:attach_part!, path, send(:validate_store_path!, @data_paths.fetch(target)))
      end
    end

    def write_evidence(data)
      summary = {
        probe: 'W216 inferred Object Dynamic direct/Array(JSON) stock/library qualification',
        status: data[:status], fatal_error: data[:fatal_error],
        runtime: {path: @binary, expected_sha256: BINARY_SHA256, sha256_before: @binary_sha_before,
                  sha256_after: @binary_sha_after, expected_version: VERSION, expected_build: BUILD},
        helper_pin: {path: @helper, sha256_before: @helper_sha_before, sha256_after: @helper_sha_after},
        limits: {max_threads: 1, local_max_memory_usage_bytes: W202::MEMORY,
                 timeout_seconds: W202::TIMEOUT, termination_grace_seconds: W202::GRACE,
                 executor: 'JsonBinaryKernelW180Probe#execute'},
        declaration: DECLARATION, profiles: PROFILES, modes: MODES, cells: CELLS,
        input: @rowbinary_input, helper_input: @helper_input,
        literal_rows: ROWS, helper_windows: HELPER_WINDOWS,
        evidence_root: @root, invocations: @invocations,
      }.merge(data.reject { |key, _| %i[status fatal_error].include?(key) })
      send(:write_new, File.join(@root, 'qualifier.json'), JSON.pretty_generate(summary) + "\n")
    end
  end

  def self.run_cli
    options = {binary: BINARY, helper: nil, root: nil}
    OptionParser.new do |parser|
      parser.banner = 'usage: ruby scripts/probe_object_inferred_dynamic_json_w216.rb --crystal-helper PREBUILT --evidence-root EMPTY_DIRECT_CHILD_OF_PRIVATE_TMP [--clickhouse PINNED]'
      parser.on('--clickhouse PATH', 'Pinned ClickHouse 26.10.1.1201 executable') { |value| options[:binary] = value }
      parser.on('--crystal-helper PATH', 'Prebuilt Crystal helper; this runner never compiles it') { |value| options[:helper] = value }
      parser.on('--evidence-root PATH', 'Existing empty direct child of /private/tmp') { |value| options[:root] = value }
    end.parse!
    abort 'W216: --crystal-helper and --evidence-root are required' unless options[:helper] && options[:root]
    Probe.new(options[:binary], options[:helper], options[:root]).run ? 0 : 1
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit ProbeObjectInferredDynamicJSONW216.run_cli
  rescue StandardError => error
    warn "W216 runner error: #{error.class}: #{error.message}"
    exit 1
  end
end
