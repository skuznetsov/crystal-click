#!/usr/bin/env ruby
# Bounded paired native witness for the W251 JSON SQL-type-name parser slice.
# One invocation covers only V1/single_stream or V2/with_size_stream and the
# root Dynamic plus Array(Dynamic) cases. It consumes supplied pinned binaries
# and a prebuilt helper; it never compiles either executable.

require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require_relative 'probe_dynamic_json_physical_w210'

module ProbeJSONSQLTypeNameW251
  W210 = ProbeDynamicJSONPhysicalW210
  FORMAT_INPUT = 'json_sql_type_name_w251_input_v1'.freeze
  FORMAT_OUTPUT = 'json_sql_type_name_w251_helper_v1'.freeze
  VERSION_PROFILES = {'v1' => 'single_stream', 'v2' => 'with_size_stream'}.freeze
  CASE_IDS = %w[root_dynamic array_dynamic].freeze
  WINDOWS = %w[FULL FIRST_EMPTY LATER FINAL].freeze
  SOURCE_FILES = %w[
    probe_json_sql_type_name_w251.rb check_json_sql_type_name_w251.cr
    check_dynamic_json_physical_w210.cr probe_dynamic_json_physical_w210.rb
    probe_nested_bulk_part_w202.rb check_array_json_parts_w185.rb
    probe_json_array_storage_w183.rb check_json_binary_kernel_w180.rb
    support/dynamic_owned_values_w220.cr
  ].map { |name| File.expand_path(name, __dir__) }.freeze
  EXPECTED_ROWS = {
    'root_dynamic' => [
      %w[u8:17 u8:18], %w[u8:19 u8:20],
      %w[json:41:null:counter=401 json:42:null:counter=402],
    ].freeze,
    'array_dynamic' => [
      %w[[] []], %w[[u8:17,u8:18] [u8:19]],
      %w[[json:41:null:counter=401] [json:42:null:counter=402]],
    ].freeze,
  }.freeze
  PARENT_MARK_ROWS = [2, 2, 2].freeze
  JSON_CHILD_MARK_ROWS = [2, 2, 2, 0].freeze

  class Probe < W210::Probe
    def initialize(binary, crystal_helper, evidence_root, dynamic_version, helper_mode)
      super(binary, crystal_helper, evidence_root)
      @dynamic_version = dynamic_version
      fail_w251!('Dynamic version must be v1 or v2') unless VERSION_PROFILES.key?(@dynamic_version)
      @helper_mode = helper_mode
      fail_w251!('helper mode must be debug or release') unless %w[debug release].include?(@helper_mode)
      @profile = VERSION_PROFILES.fetch(@dynamic_version)
      @case_profiles = CASE_IDS.map { |case_id| [case_id, @profile] }
      @table_identity = {}
      @case_profiles.each do |case_id, profile|
        %w[source library].each do |origin|
          @table_identity[table(case_id, profile, origin)] = [case_id, profile, origin]
        end
      end
      @source_pins_before = source_pins
    end

    def run
      prepare_layout!
      @binary_sha_before = binary_sha
      fail_w251!('pinned ClickHouse SHA-256 mismatch before probe') unless @binary_sha_before == W210::BINARY_SHA256
      @helper_sha_before = helper_sha
      fail_w251!('prebuilt helper SHA changed before probe') unless @helper_sha_before == helper_sha

      initial = run_clickhouse('native_sources', initial_sql)
      assert_native_invocation!(initial)
      native = parse_native(initial[:stdout])
      assert_pin!(native)
      assert_initial_native!(native)
      source_counter_rows = assert_counter_evidence!(initial[:stdout], source_tables)

      input_path = File.join(@root, 'generated', 'helper-input.json')
      input = build_helper_input
      input_bytes = JSON.pretty_generate(input) + "\n"
      write_new(input_path, input_bytes)
      @helper_input = {path: input_path, bytes: input_bytes.bytesize, sha256: Digest::SHA256.hexdigest(input_bytes)}
      helper = run_helper(input_path)
      assert_helper_output!(helper[:data])
      attach_library_parts!

      attached = run_clickhouse('attach_and_check', attached_sql)
      assert_native_invocation!(attached)
      attached_native = parse_native(attached[:stdout])
      assert_pin!(attached_native)
      assert_attached_native!(attached_native)
      attached_counter_rows = assert_counter_evidence!(attached[:stdout], all_tables)

      @source_parts.each do |name, path|
        fail_w251!("stock source part changed during ATTACH/SELECT: #{name}") unless
          snapshot_part(path) == @source_snapshots.fetch(name)
      end
      @library_parts.each do |key, path|
        fail_w251!("library part changed during ATTACH/SELECT: #{key.join('/')}") unless
          snapshot_part(path) == @library_snapshots.fetch(key)
      end
      @binary_sha_after = binary_sha
      @helper_sha_after = helper_sha
      fail_w251!('pinned ClickHouse SHA changed during probe') unless @binary_sha_after == W210::BINARY_SHA256
      fail_w251!('prebuilt helper SHA changed during probe') unless @helper_sha_after == @helper_sha_before
      @source_pins_after = source_pins
      fail_w251!('a pinned W251/inherited harness source changed during capture') unless
        @source_pins_after == @source_pins_before

      write_evidence(
        status: "paired_dynamic_json_type_name_#{@dynamic_version}_observed",
        initial: native, helper_output: helper[:data], helper_invocation: helper[:record],
        source_counter_rows: normalize_counter_rows(source_counter_rows),
        initial_invocation: initial[:record], attached: attached_native,
        attached_counter_rows: normalize_counter_rows(attached_counter_rows),
        attached_invocation: attached[:record],
      )
      puts "W251 Dynamic JSON SQL-type-name profile=#{@profile} version=#{@dynamic_version} helper_mode=#{@helper_mode} cases=#{CASE_IDS.size}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @binary_sha_after = binary_sha rescue nil
      @helper_sha_after = helper_sha rescue nil
      @source_pins_after = source_pins rescue nil
      write_evidence(status: 'runner_failure_or_observations_differ', fatal_error: @fatal_error) rescue nil
      warn "W251 probe failure (process failure is not format evidence): #{@fatal_error}"
      false
    end

    private

    def fail_w251!(message)
      raise "W251 Dynamic JSON SQL-type-name witness: #{message}"
    end

    def source_pins
      SOURCE_FILES.map do |path|
        fail_w251!("pinned harness source is missing or symlinked: #{path}") unless
          File.file?(path) && !File.symlink?(path)
        {'path' => path, 'sha256' => Digest::SHA256.file(path).hexdigest}
      end
    end

    def prepare_layout!
      %w[invocations inputs stores generated].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
      @case_profiles.each do |case_id, profile|
        FileUtils.mkdir_p(File.join(@root, 'generated', case_id, profile), mode: 0o700)
      end
    end

    def all_tables
      @case_profiles.flat_map do |case_id, profile|
        %w[source library].map { |origin| table(case_id, profile, origin) }
      end
    end

    def source_tables
      @case_profiles.map { |case_id, profile| table(case_id, profile, 'source') }
    end

    def initial_sql
      statements = [
        'SET flatten_nested=0;',
        'SET allow_suspicious_low_cardinality_types=1;',
        'SET output_format_json_named_tuples_as_objects=1;',
        'SET print_pretty_type_names=0;',
        "SELECT '__W202_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
      ]
      @case_profiles.each do |case_id, profile|
        type = W210.type_for(case_id)
        base_settings = W210::SETTINGS
        dynamic_setting = "dynamic_serialization_version='v3'"
        fail_w251!('inherited native settings lost the W210 Dynamic version slot') unless base_settings.scan(dynamic_setting).size == 1
        base_settings = base_settings.sub(dynamic_setting, "dynamic_serialization_version='#{@dynamic_version}'")
        settings = "#{base_settings}, string_serialization_version='#{profile}'"
        %w[source library].each do |origin|
          name = table(case_id, profile, origin)
          statements << "CREATE TABLE default.#{name} (pk UInt64, payload #{type}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings};"
        end
        values = W210.value_sql_rows(case_id).join(",\n")
        statements << "INSERT INTO default.#{table(case_id, profile, 'source')} VALUES\n#{values};"
        statements << check_sql(table(case_id, profile, 'source'), profile)
      end
      names = all_tables.map { |name| "'#{name}'" }.join(',')
      statements << "SELECT '__W202_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{names}) ORDER BY table, position FORMAT TSVRaw;"
      statements << "SELECT '__W202_DATA_PATH__', name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name IN (#{names}) ORDER BY name FORMAT TSVRaw;"
      statements << parts_sql(source_tables)
      source_tables.each { |name| statements.concat(value_queries(name)) }
      statements.join("\n") + "\n"
    end

    def attached_sql
      statements = [
        'SET flatten_nested=0;',
        'SET allow_suspicious_low_cardinality_types=1;',
        'SET output_format_json_named_tuples_as_objects=1;',
        'SET print_pretty_type_names=0;',
        "SELECT '__W202_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
      ]
      @case_profiles.each do |case_id, profile|
        source = table(case_id, profile, 'source')
        library = table(case_id, profile, 'library')
        statements << "ALTER TABLE default.#{library} ATTACH PART 'all_1_1_0';"
        statements << check_sql(source, profile)
        statements << check_sql(library, profile)
      end
      names = all_tables.map { |name| "'#{name}'" }.join(',')
      statements << "SELECT '__W202_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{names}) ORDER BY table, position FORMAT TSVRaw;"
      statements << parts_sql(all_tables)
      all_tables.each { |name| statements.concat(value_queries(name)) }
      statements.join("\n") + "\n"
    end

    def assert_initial_native!(native)
      expected_checks = source_tables.to_h do |name|
        [[name, @profile], ["all_1_1_0\t1\t"]]
      end
      fail_w251!('stock source CHECK result differs') unless native[:checks] == expected_checks
      expected_schema = all_tables.sort.flat_map do |name|
        case_id, = @table_identity.fetch(name)
        [[name, 'pk', 'UInt64'], [name, 'payload', W210.type_for(case_id)]]
      end
      fail_w251!('nominal source/empty-library schema differs') unless native[:schemas] == expected_schema
      fail_w251!('native table data-path roster differs') unless native[:data_paths].keys.sort == all_tables.sort
      native[:data_paths].each_value { |path| validate_store_path!(path) }
      @data_paths = native[:data_paths].dup
      fail_w251!('stock source part roster differs') unless native[:parts].keys.sort == source_tables.sort
      expected_windows = source_tables.product(WINDOWS).sort
      fail_w251!('stock selected-value query roster differs') unless native[:value_rows].keys.sort == expected_windows
      expected_zero = source_tables.flat_map do |name|
        [['__W202_ZERO_BEGIN__', name, @profile, 'values'], ['__W202_ZERO_END__', name, @profile, 'values']]
      end
      fail_w251!('stock zero-selection boundary roster differs') unless native[:zero_events] == expected_zero
      source_tables.each do |name|
        part = native[:parts].fetch(name)
        fail_w251!("#{name} is not one six-row Wide part with three marks plus sentinel") unless
          part[:name] == 'all_1_1_0' && part[:type] == 'Wide' && part[:rows] == '6' && part[:marks] == '4'
        path = validate_source_part!(part[:path])
        @source_parts[name] = path
        @source_snapshots[name] = snapshot_part(path)
        assert_value_windows!(native, name)
      end
    end

    def assert_attached_native!(native)
      expected_checks = all_tables.to_h do |name|
        [[name, @profile], ["all_1_1_0\t1\t"]]
      end
      fail_w251!('attached CHECK block roster differs') unless native[:checks] == expected_checks
      expected_schema = all_tables.sort.flat_map do |name|
        case_id, = @table_identity.fetch(name)
        [[name, 'pk', 'UInt64'], [name, 'payload', W210.type_for(case_id)]]
      end
      fail_w251!('attached nominal schema differs') unless native[:schemas] == expected_schema
      fail_w251!('attached part roster differs') unless native[:parts].keys.sort == all_tables.sort
      fail_w251!('attached value-query roster differs') unless native[:value_rows].keys.sort == all_tables.product(WINDOWS).sort
      expected_zero = all_tables.flat_map do |name|
        [['__W202_ZERO_BEGIN__', name, @profile, 'values'], ['__W202_ZERO_END__', name, @profile, 'values']]
      end
      fail_w251!('zero-selection boundary roster differs') unless native[:zero_events] == expected_zero
      all_tables.each do |name|
        part = native[:parts].fetch(name)
        fail_w251!("#{name} attached part identity/grid differs") unless
          part[:name] == 'all_1_1_0' && part[:type] == 'Wide' && part[:rows] == '6' && part[:marks] == '4'
        assert_value_windows!(native, name)
      end
    end

    def build_helper_input
      capture_root = File.realpath(File.join(@root, 'stores', 'native'))
      cases = @case_profiles.map do |case_id, profile|
        {
          'case_id' => case_id, 'profile_id' => profile,
          'capture_root' => capture_root, 'version' => @dynamic_version,
          'source_part' => @source_parts.fetch(table(case_id, profile, 'source')),
          'library_part' => File.join(@root, 'generated', case_id, profile, 'all_1_1_0'),
        }
      end
      {'format' => FORMAT_INPUT, 'dynamic_version' => @dynamic_version,
       'profile_id' => @profile, 'capture_root' => capture_root, 'cases' => cases}
    end

    def run_helper(input_path)
      before = helper_sha
      fail_w251!('prebuilt helper changed before invocation') unless before == @helper_sha_before
      argv = [@helper, input_path, File.join(@root, 'generated')]
      invocation = @executor.send(:execute_record, 'crystal_helper', argv, ''.b,
                                  'prebuilt Crystal helper', before, @helper)
      fail_w251!('Crystal helper process failed; this is not a native compatibility result') unless successful?(invocation)
      fail_w251!('Crystal helper emitted diagnostics to stderr') unless invocation[:stderr].empty?
      fail_w251!('Crystal helper changed during invocation') unless helper_sha == before
      lines = invocation[:stdout].lines.map(&:chomp).reject(&:empty?)
      fail_w251!('Crystal helper must emit exactly one JSON record') unless lines.size == 1
      data = JSON.parse(lines.fetch(0))
      fail_w251!('Crystal helper output format differs') unless data['format'] == FORMAT_OUTPUT
      @invocations << invocation[:record]
      {data: data, record: invocation[:record]}
    end

    def assert_helper_output!(data)
      expected_keys = %w[case_ids dynamic_version dynamic_version_wire format profile_id parent_mark_rows json_child_mark_rows cases]
      fail_w251!('helper root output keys/format differ') unless data.keys.sort == expected_keys.sort && data['format'] == FORMAT_OUTPUT
      expected_wire_version = @dynamic_version == 'v1' ? 1 : 2
      fail_w251!('helper selected version/profile differs') unless
        data['dynamic_version'] == @dynamic_version && data['dynamic_version_wire'] == expected_wire_version &&
        data['profile_id'] == @profile && data['case_ids'] == CASE_IDS &&
        data['parent_mark_rows'] == PARENT_MARK_ROWS && data['json_child_mark_rows'] == JSON_CHILD_MARK_ROWS
      cases = data.fetch('cases')
      fail_w251!('helper case roster/order differs') unless cases.map { |item| item.fetch('case_id') } == CASE_IDS
      cases.each do |item|
        case_id = item.fetch('case_id')
        fail_w251!("#{case_id} helper case keys/profile differ") unless
          item.keys.sort == %w[case_id library library_part_path profile_id source] && item['profile_id'] == @profile
        fail_w251!("#{case_id} helper library path differs") unless
          File.expand_path(item.fetch('library_part_path')) == File.join(@root, 'generated', case_id, @profile, 'all_1_1_0')
        %w[source library].each do |origin|
          side = item.fetch(origin)
          expected_side_keys = %w[
            case_id profile_id schema_declaration row_count mark_count mark_row_counts rows_by_mark
            physical_stream_names selected_checksum_names structure_audits owned_values windows
          ]
          fail_w251!("#{case_id}/#{origin} helper side keys differ") unless side.keys.sort == expected_side_keys.sort
          expected_type = W210.type_for(case_id)
          fail_w251!("#{case_id}/#{origin} nominal/value/mark census differs") unless
            side['case_id'] == case_id && side['profile_id'] == @profile &&
            side['schema_declaration'] == expected_type && side['row_count'] == 6 &&
            side['mark_count'] == 3 && side['mark_row_counts'] == PARENT_MARK_ROWS &&
            side['rows_by_mark'] == EXPECTED_ROWS.fetch(case_id) &&
            side['windows'] == %w[candidate_marks middle_window eof_zero]
          fail_w251!("#{case_id}/#{origin} stream/checksum roster is malformed") unless
            side['physical_stream_names'].is_a?(Array) && !side['physical_stream_names'].empty? &&
            side['physical_stream_names'].uniq == side['physical_stream_names'] &&
            side['selected_checksum_names'].is_a?(Array) && side['selected_checksum_names'].uniq == side['selected_checksum_names']
          if origin == 'source'
            owned = side.fetch('owned_values')
            fail_w251!("#{case_id} OfflineTable owned-value fields differ") unless
              owned.keys.sort == %w[mark_row_counts nominal_type_names_by_mark row_count schema_declaration values_by_mark] &&
              owned['schema_declaration'] == expected_type && owned['row_count'] == 6 &&
              owned['mark_row_counts'] == PARENT_MARK_ROWS && owned['values_by_mark'] == EXPECTED_ROWS.fetch(case_id) &&
              owned['nominal_type_names_by_mark'] == Array.new(3) { Array.new(2, expected_type) }
          else
            fail_w251!("#{case_id} library unexpectedly reports owned source values") unless side['owned_values'].nil?
          end
          assert_structure_audits!(side.fetch('structure_audits'), case_id, origin)
          part_path = if origin == 'source'
                        @source_parts.fetch(table(case_id, @profile, 'source'))
                      else
                        File.join(@root, 'generated', case_id, @profile, 'all_1_1_0')
                      end
          assert_w210_part_roster!(side, case_id, origin, part_path)
        end
        path = File.join(@root, 'generated', case_id, @profile, 'all_1_1_0')
        @library_parts[[case_id, @profile]] = path
        @library_snapshots[[case_id, @profile]] = snapshot_part(path)
      end
    end

    def assert_structure_audits!(audits, case_id, origin)
      site = case_id == 'root_dynamic' ? 'root' : 'root.elements'
      json_type_names = if origin == 'library'
                          [W210::JSON_USED, W210::JSON_UNUSED]
                        else
                          [W210::JSON_USED]
                        end
      fail_w251!("#{case_id}/#{origin} Dynamic/Object structure audit count differs") unless audits.size == 1 + json_type_names.size
      parent_types = origin == 'library' ? [W210::JSON_USED, W210::JSON_UNUSED, W210::UINT8] : [W210::JSON_USED, W210::UINT8]
      uint8_occurrences = case case_id
                          when 'root_dynamic' then 4
                          when 'array_dynamic' then 3
                          else fail_w251!("#{case_id} is outside the fixed W251 roster")
                          end
      expected_parent_counts = {W210::UINT8 => uint8_occurrences, W210::JSON_USED => 2}
      validate_structure_audit!(audits.fetch(0), owner: 'dynamic_parent', site_path: site,
                                json_type_name: nil, types: parent_types,
                                literal_counts: expected_parent_counts, mark_rows: PARENT_MARK_ROWS)
      json_type_names.each_with_index do |json_type, index|
        child_literal_counts = json_type == W210::JSON_USED ? {'Int64' => 2} : {}
        validate_structure_audit!(audits.fetch(index + 1), owner: 'json_counter_dynamic',
                                  site_path: "#{site}/#{json_type}/counter", json_type_name: json_type,
                                  types: ['Int64'], literal_counts: child_literal_counts, mark_rows: PARENT_MARK_ROWS)
      end
    end

    def assert_w210_part_roster!(side, case_id, origin, path)
      audits = side.fetch('structure_audits')
      json_audits = audits.select { |audit| audit.fetch('owner') == 'json_counter_dynamic' }
      bound_json_type_names = json_audits.map { |audit| audit.fetch('json_type_name') }
      prefixes = bound_json_type_names.map { |json_type| W210.arm_prefix(case_id, json_type) }
      object_child_stream_names = side.fetch('physical_stream_names').select do |name|
        prefixes.any? { |prefix| name.start_with?("#{prefix}.") }
      end
      audit_side = side.merge(
        'bound_json_type_names' => bound_json_type_names,
        'object_child_stream_names' => object_child_stream_names,
      )
      assert_part_roster!(path, audit_side, case_id, @profile, origin)
    end

    def validate_structure_audit!(audit, owner:, site_path:, json_type_name:, types:, literal_counts:, mark_rows:)
      fail_w251!("#{owner}/#{site_path} audit keys differ") unless audit.keys.sort == %w[
        owner site_path json_type_name physical_name version legacy_max_dynamic_types types
        canonical_variant_names mandatory_statistics statistics statistics_prefix_offset physical_grid literal_actual_type_counts
      ].sort
      expected_version = @dynamic_version == 'v1' ? 1 : 2
      canonical = (types + ['SharedVariant']).sort
      expected_counts = canonical.map { |name| name == 'SharedVariant' ? 0 : literal_counts.fetch(name, 0) }
      fail_w251!("#{owner}/#{site_path} raw/decoded nominal structure differs") unless
        audit['owner'] == owner && audit['site_path'] == site_path &&
        audit['json_type_name'] == json_type_name && audit['physical_name'].is_a?(String) &&
        !audit['physical_name'].empty? && audit['version'] == expected_version &&
        audit['types'].sort == types.sort && audit['canonical_variant_names'] == canonical &&
        audit['legacy_max_dynamic_types'] == (@dynamic_version == 'v1' ? types.size : nil) &&
        audit['mandatory_statistics'] == true && audit['literal_actual_type_counts'] == literal_counts
      statistics = audit.fetch('statistics')
      fail_w251!("#{owner}/#{site_path} mandatory versioned statistics differ") unless
        statistics.keys.sort == %w[counts shared] && statistics['counts'] == expected_counts && statistics['shared'] == []
      grid = audit.fetch('physical_grid')
      prefix = audit.fetch('statistics_prefix_offset')
      positions = grid.fetch('mark_positions')
      fail_w251!("#{owner}/#{site_path} physical zero-prefix mark witness differs") unless
        prefix.is_a?(Integer) && prefix >= 0 && grid['prefix_size'] == prefix &&
        grid['mark_row_counts'] == mark_rows && positions.size == mark_rows.size + 1 &&
        positions[0, mark_rows.size].all? { |position| position == prefix } &&
        grid['terminal_position'] == grid['logical_size'] && positions.last == grid['logical_size'] &&
        grid['logical_size'].is_a?(Integer) && grid['logical_size'] >= prefix
    end

    def attach_library_parts!
      @case_profiles.each do |case_id, profile|
        table_name = table(case_id, profile, 'library')
        path = @library_parts.fetch([case_id, profile])
        expected = File.join(@root, 'generated', case_id, profile, 'all_1_1_0')
        fail_w251!('generated part path differs from fixed destination') unless File.expand_path(path) == expected
        validate_plain_tree!(expected)
        @executor.send(:attach_part!, expected, validate_store_path!(@data_paths.fetch(table_name)))
      end
    end

    def normalize_counter_rows(rows)
      rows.sort_by { |(table_name, window), _| [table_name, window] }.map do |(table_name, window), values|
        {'table' => table_name, 'window' => window, 'rows' => values}
      end
    end

    def write_evidence(data)
      summary = {
        'format' => FORMAT_OUTPUT,
        'status' => data[:status],
        'fatal_error' => data[:fatal_error],
        'scope' => {
          'dynamic_version' => @dynamic_version, 'string_profile' => @profile,
          'helper_mode' => @helper_mode,
          'case_ids' => CASE_IDS, 'claim' => 'only V1/single_stream or V2/with_size_stream; root Dynamic and Array(Dynamic)',
          'parent_mark_rows' => PARENT_MARK_ROWS, 'json_counter_dynamic_mark_rows' => JSON_CHILD_MARK_ROWS,
          'unused_json_arm' => 'library-generated part only',
        },
        'runtime' => {'path' => @binary, 'expected_sha256' => W210::BINARY_SHA256,
                      'sha256_before' => @binary_sha_before, 'sha256_after' => @binary_sha_after,
                      'expected_version' => W210::VERSION, 'expected_version_git_hash' => W210::BUILD},
        'helper' => {'path' => @helper, 'mode' => @helper_mode,
                     'sha256_before' => @helper_sha_before, 'sha256_after' => @helper_sha_after,
                     'source_path' => SOURCE_FILES.fetch(1), 'source_sha256' => source_pin_for(SOURCE_FILES.fetch(1))},
        'harness_source_pins' => {'before' => @source_pins_before, 'after' => @source_pins_after},
        'helper_input' => @helper_input,
        'invocations' => @invocations,
        'part_snapshots' => {'stock_source' => @source_snapshots, 'library_generated' => @library_snapshots},
        'part_rosters' => @part_rosters,
        'limits' => {'max_threads' => 1, 'local_max_memory_usage_bytes' => W210::MEMORY,
                     'required_outer_run_safe_memory_limit_bytes' => W210::OUTER_RUN_SAFE_LIMIT,
                     'timeout_seconds' => W210::TIMEOUT, 'termination_grace_seconds' => W210::GRACE,
                     'executor' => 'JsonBinaryKernelW180Probe#execute'},
      }.merge(data.reject { |key, _| %i[status fatal_error].include?(key) })
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      write_new(File.join(@root, 'summary.md'), [
        '# W251 Dynamic JSON SQL-type-name compatibility', '',
        "Status: `#{summary['status']}`", '',
        "Scope: exactly `#{@dynamic_version}` / `#{@profile}` for root Dynamic and Array(Dynamic), six rows with parent P=[2,2,2]. JSON counter structure streams retain the physical parent grid [2,2,2,0], including its sentinel; this is not their value-occurrence domain. The library part additionally registers one unused JSON arm. The native reciprocal ATTACH/CHECK and literal values/types are the compatibility witness; helper structure bytes/statistics/marks are bounded corroborating observations.", '',
        "Runtime: #{W210::VERSION} / VERSION_GITHASH #{W210::BUILD} / SHA256 `#{W210::BINARY_SHA256}`", '',
        "Evidence root: `#{@root}`", '',
      ].join("\n"))
    end

    def source_pin_for(path)
      @source_pins_before.find { |item| item['path'] == path }&.fetch('sha256')
    end
  end

  if $PROGRAM_NAME == __FILE__
    options = {binary: W210::BINARY, helper: nil, root: nil, dynamic_version: nil}
    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby scripts/probe_json_sql_type_name_w251.rb --dynamic-version v1|v2 --helper-mode debug|release --crystal-helper PREBUILT --evidence-root EMPTY_/private/tmp_CHILD [--clickhouse PINNED]'
      parser.on('--clickhouse PATH', 'Pinned ClickHouse executable') { |value| options[:binary] = value }
      parser.on('--crystal-helper PATH', 'Prebuilt W251 Crystal helper; this runner never compiles it') { |value| options[:helper] = value }
      parser.on('--evidence-root PATH', 'Existing empty direct child of /private/tmp') { |value| options[:root] = value }
      parser.on('--dynamic-version VERSION', 'One fixed pair: v1/single_stream or v2/with_size_stream') { |value| options[:dynamic_version] = value }
      parser.on('--helper-mode MODE', 'Mode of the prebuilt Crystal helper: debug or release') { |value| options[:helper_mode] = value }
    end.parse!
    abort 'W251: --dynamic-version v1|v2, --helper-mode debug|release, --crystal-helper and --evidence-root are required' unless
      options[:helper] && options[:root] && options[:dynamic_version] && options[:helper_mode]
    exit(Probe.new(options[:binary], options[:helper], options[:root], options[:dynamic_version], options[:helper_mode]).run ? 0 : 1)
  end
end
