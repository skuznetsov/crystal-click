#!/usr/bin/env ruby
# Root-run paired stock/library qualification for nested JSON actual values.
# This runner never builds ClickHouse or the Crystal helper; both are supplied
# as pinned, prebuilt executables and all subprocesses use the W180 supervisor.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require_relative 'check_array_json_parts_w185'

module CheckObjectSharedNestedPartsW198
  W185 = CheckArrayJSONPartsW185
  W180 = JsonBinaryKernelW180Probe
  BINARY = W185::BINARY
  BINARY_SHA256 = W185::BINARY_SHA256
  VERSION = W185::VERSION
  BUILD = W185::BUILD
  MEMORY = W185::MEMORY
  TIMEOUT = W185::TIMEOUT
  GRACE = W185::GRACE
  OUTER_RUN_SAFE_LIMIT = W185::OUTER_RUN_SAFE_LIMIT

  FORMAT_INPUT = 'object_shared_nested_parts_w198_input_v1'.freeze
  FORMAT_OUTPUT = 'object_shared_nested_parts_w198_helper_v1'.freeze
  COLUMN_TYPE = 'JSON(max_dynamic_types=1, max_dynamic_paths=0)'.freeze
  NESTED_TYPE = 'Nested(n UInt8, s String)'.freeze
  ARRAY_TUPLE_TYPE = 'Array(Tuple(n UInt8, s String))'.freeze
  PROFILE_DEFS = [
    ['nested_v2_s0', 'nested', 2, 0],
    ['nested_v2_s1', 'nested', 2, 1],
    ['nested_v3_s0', 'nested', 3, 0],
    ['nested_v3_s1', 'nested', 3, 1],
    ['array_tuple_v2_s0', 'array_tuple', 2, 0],
    ['array_tuple_v2_s1', 'array_tuple', 2, 1],
    ['array_tuple_v3_s0', 'array_tuple', 3, 0],
    ['array_tuple_v3_s1', 'array_tuple', 3, 1],
  ].map(&:freeze).freeze

  # Independent logical literals. Do not derive these from helper readback.
  OBJECTS = [
    {'n' => [{'n' => 7, 's' => 'one'}]},
    {},
    {'n' => []},
    {'n' => [{'n' => 9, 's' => 'four'}]},
    {'n' => [{'n' => 11, 's' => 'a'}, {'n' => 12, 's' => 'bb'}]},
    {},
    {'n' => []},
    {'n' => [{'n' => 0, 's' => ''}]},
  ].freeze
  TYPE_NAMES = {
    'nested' => NESTED_TYPE,
    'array_tuple' => ARRAY_TUPLE_TYPE,
  }.freeze
  DESCRIPTOR_HEX = {
    'nested' => '2f02016e01017315',
    'array_tuple' => '1e2002016e01017315',
  }.freeze

  class Probe
    def initialize(binary, crystal_helper, evidence_root)
      @binary = validate_executable(binary, 'ClickHouse')
      @crystal_helper = validate_executable(crystal_helper, 'Crystal helper')
      @root = validate_root(evidence_root)
      @base = W185::Probe.new(@binary, @crystal_helper, @root)
      @invocations = []
      @fatal_error = nil
      @profile_rows = {}
      @parts = {}
      @part_paths = {}
    end

    def run
      prepare_evidence_layout!
      @native_sha_before = binary_sha
      fail!('pinned ClickHouse executable SHA-256 mismatch before probe') unless @native_sha_before == BINARY_SHA256
      @helper_sha_before = helper_sha
      fail!('Crystal helper SHA changed before probe') unless @helper_sha_before == helper_sha

      PROFILE_DEFS.each do |profile_id, kind, shared_version, string_profile|
        input_path = File.join(@root, 'inputs', "#{kind}.rowbinary")
        write_new(input_path, rowbinary(kind)) unless File.exist?(input_path)
      end

      initial = run_clickhouse('native_sources', initial_sql)
      assert_pin!(initial)
      assert_native_invocation!(initial)
      source = parse_native(initial[:stdout])
      assert_initial_native!(source)

      helper_input = build_helper_input(source)
      # The Crystal helper deliberately accepts input only from beneath its
      # output root; keep this manifest beside, not outside, generated parts.
      helper_input_path = File.join(@root, 'generated', 'helper-input.json')
      write_new(helper_input_path, JSON.pretty_generate(helper_input) + "\n")
      output_root = File.join(@root, 'generated')
      helper = run_helper(helper_input_path, output_root)
      assert_helper_output!(helper[:data], helper_input)

      attach_library_parts!(source)
      attached = run_clickhouse('attach_and_check', attached_sql)
      assert_pin!(attached)
      assert_native_invocation!(attached)
      attached_result = parse_native(attached[:stdout])
      assert_attached_native!(attached_result)

      @native_sha_after = binary_sha
      @helper_sha_after = helper_sha
      fail!('pinned ClickHouse executable SHA changed during probe') unless @native_sha_after == BINARY_SHA256
      fail!('Crystal helper SHA changed during probe') unless @helper_sha_after == @helper_sha_before
      write_summary(
        status: 'paired_nested_json_observed', source: source,
        helper: helper[:data], helper_invocation: helper[:record],
        attached: attached_result, initial_invocation: initial[:record],
        attached_invocation: attached[:record], part_file_snapshots: @parts,
      )
      puts "W198 paired nested JSON profiles=#{PROFILE_DEFS.size}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @native_sha_after = binary_sha rescue nil
      @helper_sha_after = helper_sha rescue nil
      write_summary(status: 'runner_failure_or_observations_differ', fatal_error: @fatal_error) rescue nil
      warn "W198 probe failed: #{@fatal_error}"
      false
    end

    private

    def validate_root(path)
      fail!('evidence root is required') unless path && !path.empty?
      expanded = File.expand_path(path)
      parent = File.realpath('/private/tmp')
      fail!('evidence root must be a direct child of /private/tmp') unless File.dirname(expanded) == parent
      fail!('evidence root must not be a symlink') if File.symlink?(expanded)
      fail!('evidence root must already exist and be empty') unless
        File.directory?(expanded) && File.realpath(expanded) == expanded && Dir.children(expanded).empty?
      expanded
    rescue Errno::ENOENT
      fail!('evidence root must already exist')
    end

    def validate_executable(path, label)
      fail!("#{label} executable path is required") unless path && !path.empty?
      expanded = File.expand_path(path)
      fail!("#{label} executable is missing, non-executable, or symlinked") unless
        File.file?(expanded) && File.executable?(expanded) && !File.symlink?(expanded)
      expanded
    end

    def prepare_evidence_layout!
      %w[invocations inputs stores generated].each do |name|
        Dir.mkdir(File.join(@root, name), 0o700)
      end
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
    end

    def binary_sha
      Digest::SHA256.file(@binary).hexdigest
    end

    def helper_sha
      Digest::SHA256.file(@crystal_helper).hexdigest
    end

    def settings(shared_version, string_profile)
      inherited = W185::SETTINGS.split(', ').reject do |setting|
        setting.start_with?('object_shared_data_serialization_version=') ||
          setting.start_with?('object_shared_data_serialization_version_for_zero_level_parts=') ||
          setting.start_with?('object_shared_data_buckets_for_wide_part=') ||
          setting.start_with?('object_shared_data_target_chunk_rows=') ||
          setting.start_with?('string_serialization_version=') ||
          setting.start_with?('serialization_info_version=') ||
          setting.start_with?('propagate_types_serialization_versions_to_nested_types=') ||
          setting.start_with?('map_serialization_version=') ||
          setting.start_with?('map_serialization_version_for_zero_level_parts=')
      end
      shared_name = shared_version == 2 ? 'advanced' : 'advanced_chunked'
      string_name = string_profile == 0 ? 'single_stream' : 'with_size_stream'
      inherited.concat([
        "object_shared_data_serialization_version='#{shared_name}'",
        "object_shared_data_serialization_version_for_zero_level_parts='#{shared_name}'",
        'object_shared_data_buckets_for_wide_part=2',
        'object_shared_data_target_chunk_rows=1',
        "serialization_info_version='with_types'",
        "string_serialization_version='#{string_name}'",
        'propagate_types_serialization_versions_to_nested_types=1',
      ])
      inherited.join(', ')
    end

    def initial_sql
      statements = [pin_sql]
      PROFILE_DEFS.each do |profile_id, _kind, shared_version, string_profile|
        source = source_table(profile_id)
        target = library_table(profile_id)
        table_settings = settings(shared_version, string_profile)
        statements << "CREATE TABLE default.#{source} (pk UInt64, j #{COLUMN_TYPE}) ENGINE=MergeTree ORDER BY pk SETTINGS #{table_settings};"
        statements << "CREATE TABLE default.#{target} (pk UInt64, j #{COLUMN_TYPE}) ENGINE=MergeTree ORDER BY pk SETTINGS #{table_settings};"
        input_path = File.join(@root, 'inputs', "#{kind_for(profile_id)}.rowbinary")
        statements << insert_sql(source, input_path)
        statements << check_sql(source, profile_id)
      end
      statements << schema_sql(all_tables)
      statements << data_paths_sql(all_tables)
      statements << parts_sql(source_tables)
      PROFILE_DEFS.each do |profile_id, kind, _shared_version, _string_profile|
        statements.concat(read_queries(source_table(profile_id), profile_id, kind))
      end
      statements.join("\n") + "\n"
    end

    def attached_sql
      statements = [pin_sql]
      PROFILE_DEFS.each do |profile_id, _kind, _shared_version, _string_profile|
        table = library_table(profile_id)
        statements << "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0';"
        statements << check_sql(source_table(profile_id), profile_id)
        statements << check_sql(table, profile_id)
      end
      statements << schema_sql(all_tables)
      statements << parts_sql(all_tables)
      PROFILE_DEFS.each do |profile_id, kind, _shared_version, _string_profile|
        statements.concat(read_queries(library_table(profile_id), profile_id, kind))
      end
      statements.join("\n") + "\n"
    end

    def pin_sql
      "SELECT '__W198_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;"
    end

    def source_table(profile_id)
      "source_#{profile_id}"
    end

    def library_table(profile_id)
      "library_#{profile_id}"
    end

    def source_tables
      PROFILE_DEFS.map { |profile_id, *_| source_table(profile_id) }
    end

    def all_tables
      PROFILE_DEFS.flat_map { |profile_id, *_| [source_table(profile_id), library_table(profile_id)] }
    end

    def kind_for(profile_id)
      profile_id.start_with?('nested_') ? 'nested' : 'array_tuple'
    end

    def check_sql(table, profile_id)
      [
        "SELECT '__W198_CHECK_BEGIN__', '#{table}', '#{profile_id}' FORMAT TSVRaw;",
        "CHECK TABLE default.#{table} FORMAT TSV;",
        "SELECT '__W198_CHECK_END__', '#{table}', '#{profile_id}' FORMAT TSVRaw;",
      ].join("\n")
    end

    def schema_sql(tables)
      names = tables.map { |name| "'#{name}'" }.join(',')
      "SELECT '__W198_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{names}) ORDER BY table, position FORMAT TSVRaw;"
    end

    def data_paths_sql(tables)
      names = tables.map { |name| "'#{name}'" }.join(',')
      "SELECT '__W198_DATA_PATH__', name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name IN (#{names}) ORDER BY name FORMAT TSVRaw;"
    end

    def parts_sql(tables)
      names = tables.map { |name| "'#{name}'" }.join(',')
      "SELECT '__W198_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table IN (#{names}) AND active ORDER BY table,name FORMAT TSVRaw;"
    end

    def insert_sql(table, input_path)
      escaped_path = input_path.gsub("'", "\\'")
      "INSERT INTO default.#{table} SELECT * FROM file('#{escaped_path}', 'RowBinary', 'pk UInt64, j #{COLUMN_TYPE}') SETTINGS input_format_binary_read_json_as_string=0, flatten_nested=0, allow_suspicious_low_cardinality_types=1;"
    end

    def read_queries(table, profile_id, kind)
      type = TYPE_NAMES.fetch(kind).gsub("'", "''")
      queries = []
      %w[full middle zero].each do |window|
        predicate = case window
                    when 'full' then ''
                    when 'middle' then ' WHERE pk BETWEEN 3 AND 6'
                    when 'zero' then ' WHERE pk > 8'
                    end
        window_condition = predicate.empty? ? '' : predicate
        [
          ['whole', "SELECT '__W198_WHOLE_#{window.upcase}__', '#{table}', toString(pk), hex(toJSONString(j)) FROM default.#{table}#{window_condition} ORDER BY pk FORMAT TSVRaw;"],
          ['type', "SELECT '__W198_TYPE_#{window.upcase}__', '#{table}', toString(pk), dynamicType(j.n) FROM default.#{table}#{window_condition} ORDER BY pk FORMAT TSVRaw;"],
          ['direct', "SELECT '__W198_DIRECT_#{window.upcase}__', '#{table}', toString(pk), dynamicType(j.n), hex(formatRow('RowBinary', dynamicElement(j.n, '#{type}'))) FROM default.#{table}#{window_condition} ORDER BY pk FORMAT TSVRaw;"],
        ].each do |kind_name, statement|
          if window == 'zero'
            queries << "SELECT '__W198_ZERO_BEGIN__', '#{table}', '#{window}', '#{kind_name}' FORMAT TSVRaw;"
          end
          queries << statement
          if window == 'zero'
            queries << "SELECT '__W198_ZERO_END__', '#{table}', '#{window}', '#{kind_name}' FORMAT TSVRaw;"
          end
        end
      end
      queries
    end

    def rowbinary(kind)
      descriptor = [DESCRIPTOR_HEX.fetch(kind)].pack('H*')
      OBJECTS.each_with_index.map do |object, index|
        fields = object.empty? ? [] : [['n', descriptor + nested_body(object.fetch('n'))]]
        payload = varuint(fields.size) + fields.map { |name, bytes| wire_string(name) + bytes }.join.b
        [index + 1].pack('Q<') + payload
      end.join.b
    end

    def nested_body(elements)
      varuint(elements.size) + elements.map do |entry|
        [entry.fetch('n')].pack('C') + wire_string(entry.fetch('s'))
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

    def wire_string(value)
      bytes = value.b
      varuint(bytes.bytesize) + bytes
    end

    def run_clickhouse(label, sql)
      sql_path = File.join(@root, 'invocations', "#{label}.stdin.sql")
      write_new(sql_path, sql.b)
      argv = [@binary, 'local', '--path', File.join(@root, 'stores', 'native'), '--session_timezone=UTC',
              '--max_threads=1', "--max_memory_usage=#{MEMORY}", '--multiquery']
      before_sha = binary_sha
      fail!('pinned ClickHouse executable SHA-256 mismatch before invocation') unless before_sha == BINARY_SHA256
      invocation = @base.send(:execute_record, label, argv, sql.b, 'clickhouse local', BINARY_SHA256, @binary)
      invocation[:record][:binary_sha_before] = before_sha
      invocation[:record][:binary_sha_after] = binary_sha
      fail!('pinned ClickHouse executable SHA changed during invocation') unless invocation[:record][:binary_sha_after] == BINARY_SHA256
      @invocations << invocation[:record]
      invocation
    end

    def run_helper(input_path, output_root)
      argv = [@crystal_helper, input_path, output_root]
      before_sha = helper_sha
      invocation = @base.send(:execute_record, 'crystal_helper', argv, ''.b, 'prebuilt Crystal helper', before_sha, @crystal_helper)
      fail!('Crystal helper failed; this is not a native format rejection') unless invocation[:classification] == 'success' && invocation[:status]&.success?
      fail!('Crystal helper emitted stderr') unless invocation[:stderr].empty?
      fail!('Crystal helper SHA changed during invocation') unless helper_sha == before_sha
      lines = invocation[:stdout].lines.map(&:chomp).reject(&:empty?)
      fail!('Crystal helper must emit exactly one JSON object') unless lines.size == 1
      data = JSON.parse(lines.fetch(0))
      fail!('Crystal helper output format differs') unless data['format'] == FORMAT_OUTPUT
      {data: data, record: invocation[:record]}
    end

    def build_helper_input(source)
      capture_root = File.realpath(File.join(@root, 'stores', 'native'))
      profiles = PROFILE_DEFS.map do |profile_id, kind, shared_version, string_profile|
        part = source.fetch(:parts).fetch(source_table(profile_id))
        source_path = validate_source_part!(part.fetch(:path))
        @part_paths[source_table(profile_id)] = source_path
        {
          'profile_id' => profile_id, 'kind' => kind, 'shared_version' => shared_version,
          'string_profile' => string_profile, 'source_part' => source_path,
          'library_part' => File.join(@root, 'generated', profile_id, 'all_1_1_0'),
          'capture_root' => capture_root,
        }
      end
      {
        'format' => FORMAT_INPUT, 'capture_root' => capture_root, 'profiles' => profiles,
      }
    end

    def attach_library_parts!(source)
      PROFILE_DEFS.each do |profile_id, _kind, _shared_version, _string_profile|
        path = File.join(@root, 'generated', profile_id, 'all_1_1_0')
        validate_generated_part!(path, profile_id)
        @part_paths[library_table(profile_id)] = File.realpath(path)
        @parts[library_table(profile_id)] = snapshot_part(path)
        data_path = source.fetch(:data_paths).fetch(library_table(profile_id))
        validate_store_path!(data_path)
        @base.send(:attach_part!, path, data_path)
      end
    end

    def parse_native(stdout)
      lines = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      fields = ->(tag) { lines.map { |line| line.split("\t", -1) if line.start_with?("#{tag}\t") }.compact }
      checks = {}
      active = nil
      lines.each do |line|
        if line.start_with?("__W198_CHECK_BEGIN__\t")
          fields_for = line.split("\t", -1)
          fail!('CHECK begin marker has the wrong field width') unless fields_for.size == 3
          fail!('nested or duplicate CHECK begin marker') if active
          active = [fields_for[1], fields_for[2]]
          fail!('duplicate CHECK block key') if checks.key?(active)
          checks[active] = []
        elsif line.start_with?("__W198_CHECK_END__\t")
          fields_for = line.split("\t", -1)
          fail!('CHECK end marker has the wrong field width') unless fields_for.size == 3
          fail!('CHECK end marker has no matching begin') unless active
          fail!('CHECK end marker does not match its begin') unless active == [fields_for[1], fields_for[2]]
          active = nil
        elsif active
          checks[active] << line
        end
      end
      fail!('unclosed CHECK block') if active
      data_paths = {}
      fields.call('__W198_DATA_PATH__').each do |f|
        fail!('data-path record has the wrong field width') unless f.size == 3
        fail!('duplicate data-path table record') if data_paths.key?(f[1])
        data_paths[f[1]] = f[2]
      end
      parts = {}
      fields.call('__W198_PART__').each do |f|
        fail!('part record has the wrong field width') unless f.size == 7
        fail!('duplicate active-part table record') if parts.key?(f[1])
        parts[f[1]] = {name: f[2], path: f[3], part_type: f[4], rows: f[5], marks: f[6]}
      end
      zero_events = lines.each_with_object([]) do |line, events|
        next unless line.start_with?("__W198_ZERO_BEGIN__\t") || line.start_with?("__W198_ZERO_END__\t")
        fields_for = line.split("\t", -1)
        fail!('zero-window marker has the wrong field width') unless fields_for.size == 4
        events << fields_for
      end
      pin_rows = fields.call('__W198_PIN__')
      fail!('runtime pin marker must occur exactly once') unless pin_rows.size == 1 && pin_rows[0].size == 3
      {
        pin: lines.find { |line| line.start_with?("__W198_PIN__\t") },
        checks: checks,
        schemas: fields.call('__W198_SCHEMA__').map { |f| f.drop(1) },
        data_paths: data_paths, parts: parts,
        whole: parse_rows_by_tag(lines, '__W198_WHOLE_'),
        types: parse_rows_by_tag(lines, '__W198_TYPE_'),
        direct: parse_rows_by_tag(lines, '__W198_DIRECT_'),
        zero_events: zero_events,
      }
    end

    def parse_rows_by_tag(lines, prefix)
      lines.each_with_object([]) do |line, rows|
        next unless line.start_with?(prefix)
        fields = line.split("\t", -1)
        rows << {tag: fields[0], table: fields[1], fields: fields.drop(2)}
      end
    end

    def assert_pin!(invocation)
      pin_rows = invocation[:stdout].force_encoding(Encoding::UTF_8).lines.map(&:chomp)
                       .select { |entry| entry.start_with?("__W198_PIN__\t") }
      fail!('runtime pin marker must occur exactly once') unless pin_rows.size == 1 && pin_rows.first.split("\t", -1).size == 3
      line = pin_rows.first
      expected = "__W198_PIN__\t#{VERSION}\t#{BUILD}"
      fail!("runtime pin mismatch: #{line.inspect}") unless line == expected
    end

    def assert_native_invocation!(invocation)
      fail!('ClickHouse process did not exit successfully') unless invocation[:classification] == 'success' && invocation[:status]&.success? && invocation[:status]&.termsig.nil?
      fail!('ClickHouse stderr is not empty') unless invocation[:stderr].empty?
    end

    def assert_initial_native!(native)
      assert_checks!(native, source_tables)
      assert_schemas!(native, all_tables)
      fail!('source part inventory is incomplete') unless native[:parts].keys.sort == source_tables.sort
      fail!('native data-path inventory is incomplete') unless native[:data_paths].keys.sort == all_tables.sort
      native[:data_paths].each_value { |path| validate_store_path!(path) }
      PROFILE_DEFS.each do |profile_id, kind, _version, _string_profile|
        table = source_table(profile_id)
        part = native[:parts].fetch(table)
        fail!("#{table} is not the expected fresh Wide part") unless part[:name] == 'all_1_1_0' && part[:part_type] == 'Wide' && part[:rows] == '8' && part[:marks] == '5'
        path = validate_source_part!(part[:path])
        @parts[table] = snapshot_part(path)
        @part_paths[table] = path
        assert_windows!(native, table, kind)
      end
    end

    def assert_attached_native!(native)
      assert_checks!(native, all_tables)
      assert_schemas!(native, all_tables)
      fail!('attached part inventory differs from exact 16-table roster') unless native[:parts].keys.sort == all_tables.sort
      PROFILE_DEFS.each do |profile_id, kind, _version, _string_profile|
        source = source_table(profile_id)
        library = library_table(profile_id)
        assert_windows!(native, library, kind)
        [source, library].each do |table|
          part = native[:parts].fetch(table)
          fail!("#{table} part identity differs") unless part[:name] == 'all_1_1_0' && part[:part_type] == 'Wide' && part[:rows] == '8' && part[:marks] == '5'
        end
        source_path = @part_paths.fetch(source)
        fail!("#{source} source part changed after attachment") unless snapshot_part(source_path) == @parts.fetch(source)
        library_path = @part_paths.fetch(library)
        fail!("#{library} generated part changed after attachment") unless snapshot_part(library_path) == @parts.fetch(library)
      end
    end

    def assert_checks!(native, tables)
      expected = tables.to_h { |table| [[table, profile_for_table(table)], ["all_1_1_0\t1\t"]] }
      fail!("stock CHECK results differ: #{native[:checks].inspect}") unless native[:checks] == expected
    end

    def profile_for_table(table)
      table.sub(/\A(?:source|library)_/, '')
    end

    def assert_schemas!(native, tables)
      expected = tables.sort.flat_map { |table| [[table, 'pk', 'UInt64'], [table, 'j', COLUMN_TYPE]] }
      fail!("schema roster differs: #{native[:schemas].inspect}") unless native[:schemas] == expected
    end

    def assert_windows!(native, table, kind)
      type_name = TYPE_NAMES.fetch(kind)
      expected_by_window = {
        'FULL' => (1..8).to_a,
        'MIDDLE' => (3..6).to_a,
        'ZERO' => [],
      }
      expected_by_window.each do |window, pks|
        expected_whole = pks.map do |pk|
          object = OBJECTS.fetch(pk - 1)
          [table, pk.to_s, JSON.parse(JSON.generate(object))]
        end
        actual_whole = native[:whole].select { |r| r[:table] == table && r[:tag].end_with?("_#{window}__") }.map do |record|
          fields = record[:fields]
          fail!("#{table} whole #{window} row has wrong dimensions") unless fields.size == 2
          json = JSON.parse([fields[1]].pack('H*'))
          [table, fields[0], json]
        rescue JSON::ParserError
          fail!("#{table} whole #{window} row has invalid JSON hex")
        end
        fail!("#{table} whole #{window} rows differ from independent literals") unless actual_whole == expected_whole

        expected_types = pks.map do |pk|
          object = OBJECTS.fetch(pk - 1)
          [table, pk.to_s, object.key?('n') ? type_name : 'None']
        end
        actual_types = native[:types].select { |r| r[:table] == table && r[:tag].end_with?("_#{window}__") }.map do |record|
          fields = record[:fields]
          fail!("#{table} type #{window} row has wrong dimensions") unless fields.size == 2
          [table, fields[0], fields[1]]
        end
        fail!("#{table} dynamicType #{window} rows differ") unless actual_types == expected_types

        expected_direct = pks.map do |pk|
          object = OBJECTS.fetch(pk - 1)
          [table, pk.to_s, object.key?('n') ? type_name : 'None', body_hex(kind, object)]
        end
        actual_direct = native[:direct].select { |r| r[:table] == table && r[:tag].end_with?("_#{window}__") }.map do |record|
          fields = record[:fields]
          fail!("#{table} direct #{window} row has wrong dimensions") unless fields.size == 3
          [table, fields[0], fields[1], fields[2].upcase]
        end
        fail!("#{table} direct path #{window} rows differ from independently authored RowBinary literals") unless actual_direct == expected_direct
      end
      expected_zero = %w[whole type direct].flat_map do |kind_name|
        [['__W198_ZERO_BEGIN__', table, 'zero', kind_name], ['__W198_ZERO_END__', table, 'zero', kind_name]]
      end
      actual_zero = native[:zero_events].select { |f| f[1] == table }
      fail!("#{table} explicit zero-window boundary roster differs") unless actual_zero == expected_zero
    end

    def body_hex(kind, object)
      return '00' unless object.key?('n')
      nested_body(object.fetch('n')).unpack1('H*').upcase
    end

    def assert_helper_output!(output, input)
      fail!('helper output keys/format differ') unless output.keys.sort == %w[format profile_ids profiles] && output['format'] == FORMAT_OUTPUT
      expected_ids = PROFILE_DEFS.map(&:first)
      fail!('helper top-level profile ID order differs') unless output['profile_ids'] == expected_ids
      profiles = output['profiles']
      fail!('helper output profile count differs') unless profiles.is_a?(Array) && profiles.size == PROFILE_DEFS.size
      profiles.each_with_index do |record, index|
        profile_id, kind, shared_version, string_profile = PROFILE_DEFS.fetch(index)
        source = input['profiles'].fetch(index)
        fail!("helper profile #{index} identity differs") unless record['profile_id'] == profile_id && source['profile_id'] == profile_id
        fail!("helper profile #{profile_id} keys differ") unless record.keys.sort == %w[kind library library_part_path profile_id shared_version source string_profile]
        %w[kind shared_version string_profile].each do |field|
          expected = {'kind' => kind, 'shared_version' => shared_version, 'string_profile' => string_profile}.fetch(field)
          fail!("helper #{profile_id} #{field} differs") unless record[field] == expected
        end
        %w[source library].each do |origin|
          side = record.fetch(origin)
          fail!("helper #{profile_id} #{origin} dimensions differ") unless side['row_count'] == 8 && side['mark_row_counts'] == [2, 2, 2, 2]
          expected_side_keys = %w[full_rows mark_row_counts middle_rows ordinary_string_profile physical_stream_names row_count schema_declaration shared_data_version source_declaration zero_rows]
          fail!("helper #{profile_id} #{origin} keys differ") unless side.keys.sort == expected_side_keys
          fail!("helper #{profile_id} #{origin} source declaration differs") unless side['source_declaration'] == COLUMN_TYPE
          fail!("helper #{profile_id} #{origin} expected schema differs") unless side['schema_declaration'] == COLUMN_TYPE
          fail!("helper #{profile_id} #{origin} persisted shared-data version differs") unless side['shared_data_version'] == shared_version
          fail!("helper #{profile_id} #{origin} ordinary String profile differs") unless side['ordinary_string_profile'] == string_profile
          assert_helper_windows!(side, profile_id, kind, origin)
        end
      end
      expected_library = input['profiles'].map { |p| File.expand_path(p.fetch('library_part')) }
      actual_library = profiles.map { |p| File.expand_path(p.fetch('library_part_path')) }
      fail!('helper library part destinations differ from preauthorized paths') unless actual_library == expected_library
    end

    def assert_helper_windows!(side, profile_id, kind, origin)
      expected_windows = {
        'full_rows' => (1..8).to_a,
        'middle_rows' => (3..6).to_a,
        'zero_rows' => [],
      }
      expected_windows.each do |key, pks|
        rows = side.fetch(key)
        fail!("#{profile_id} #{origin} #{key} row count differs") unless rows.size == pks.size
        expected = pks.map { |pk| helper_row(kind, pk) }
        fail!("#{profile_id} #{origin} #{key} literals differ") unless rows == expected
      end
      streams = side.fetch('physical_stream_names')
      fail!("#{profile_id} #{origin} physical stream names are empty or duplicated") unless streams.is_a?(Array) && !streams.empty? && streams.uniq == streams
    end

    def helper_row(kind, pk)
      object = OBJECTS.fetch(pk - 1)
      {
        'pk' => pk, 'path_present' => object.key?('n'),
        'type_name' => object.key?('n') ? TYPE_NAMES.fetch(kind) : '',
        'value_hex' => object.key?('n') ? (DESCRIPTOR_HEX.fetch(kind) + nested_body(object.fetch('n')).unpack1('H*')) : '',
      }
    end

    def validate_source_part!(path)
      fail!('reported source part path is absent') unless path && !path.empty?
      full = File.expand_path(path.chomp(File::SEPARATOR))
      root = File.join(@root, 'stores', 'native')
      fail!("source part escaped the task-local native store: #{path}") unless full.start_with?(root + File::SEPARATOR)
      fail!('source part is absent') unless File.directory?(full)
      validate_plain_tree!(full)
      File.realpath(full)
    end

    def validate_generated_part!(path, profile_id)
      expected = File.join(@root, 'generated', profile_id, 'all_1_1_0')
      fail!("generated part path differs for #{profile_id}") unless File.expand_path(path) == expected
      fail!("generated part absent for #{profile_id}") unless File.directory?(expected)
      validate_plain_tree!(expected)
      File.realpath(expected)
    end

    def snapshot_part(path)
      files = Dir.children(path).sort
      fail!('part contains symlink/non-regular entries') unless validate_plain_tree!(path)
      files.to_h do |name|
        full = File.join(path, name)
        next [name, {type: 'directory'}] if File.directory?(full)
        [name, {size: File.size(full), sha256: Digest::SHA256.file(full).hexdigest}]
      end
    end

    def validate_store_path!(path)
      fail!('ClickHouse table data path is absent') unless path && !path.empty?
      full = File.expand_path(path)
      store = File.join(@root, 'stores', 'native')
      fail!("table data path escaped local store: #{path}") unless full.start_with?(store + File::SEPARATOR)
      ensure_plain_directory_chain!(full)
      full
    end

    def ensure_plain_directory_chain!(path)
      current = File::SEPARATOR
      File.expand_path(path).delete_prefix(File::SEPARATOR).split(File::SEPARATOR).each do |component|
        current = File.join(current, component)
        next unless File.exist?(current) || File.symlink?(current)
        fail!("symlink in task-local path: #{current}") if File.lstat(current).symlink?
        fail!("non-directory path component: #{current}") unless File.directory?(current)
      end
    end

    def validate_plain_tree!(path)
      Find.find(path) do |entry|
        stat = File.lstat(entry)
        fail!("symlink in evidence tree: #{entry}") if stat.symlink?
        fail!("non-regular evidence entry: #{entry}") unless stat.directory? || stat.file?
      end
      true
    end

    def write_summary(data)
      summary = {
        probe: 'W198 paired public Nested/Array(Tuple) Object part qualification',
        status: data[:status], fatal_error: data[:fatal_error],
        runtime: {path: @binary, expected_sha256: BINARY_SHA256, sha256_before: @native_sha_before,
                  sha256_after: @native_sha_after, expected_version: VERSION, expected_build: BUILD},
        helper_executable: {path: @crystal_helper, sha256_before: @helper_sha_before, sha256_after: @helper_sha_after},
        limits: {max_threads: 1, local_max_memory_usage_bytes: MEMORY,
                 required_outer_run_safe_memory_limit_bytes: OUTER_RUN_SAFE_LIMIT,
                 timeout_seconds: TIMEOUT, termination_grace_seconds: GRACE,
                 executor: 'JsonBinaryKernelW180Probe#execute'},
        profile_ids: PROFILE_DEFS.map(&:first), settings: PROFILE_DEFS.map { |id, _kind, version, string_profile| {id: id, shared_version: version, string_profile: string_profile} },
        evidence_root: @root, invocations: @invocations,
      }.merge(data.reject { |key, _| %i[status fatal_error].include?(key) })
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      write_new(File.join(@root, 'summary.md'), [
        '# W198 paired public Nested/Array(Tuple) Object qualification', '',
        "Status: `#{summary[:status]}`", '',
        'The source and library parts are consumed by the pinned stock runtime, and the same parts are opened through the public Crystal Object reader. Whole-object JSON and direct typed path reads are separate native SELECTs. This finite fixture covers Nested and Array(Tuple), shared-data versions 2/3, and ordinary String profiles 0/1; it does not claim all actual types or all Object layouts.', '',
        "Runtime: #{VERSION} / #{BUILD} / SHA256 `#{@native_sha_before}`", '',
        "Evidence root: `#{@root}`", '',
      ].join("\n"))
    end

    def write_new(path, bytes)
      fail!("refusing to overwrite evidence: #{path}") if File.exist?(path) || File.symlink?(path)
      File.open(path, 'wbx', 0o600) { |file| file.write(bytes) }
    end

    def fail!(message)
      raise RuntimeError, "W198 nested JSON paired oracle: #{message}"
    end
  end

  def self.self_test!
    probe = Probe.allocate
    # Descriptor and literal body are pinned independently from a helper.
    raise 'Nested descriptor changed' unless [DESCRIPTOR_HEX.fetch('nested')].pack('H*').unpack1('H*') == '2f02016e01017315'
    raise 'Array(Tuple) descriptor changed' unless [DESCRIPTOR_HEX.fetch('array_tuple')].pack('H*').unpack1('H*') == '1e2002016e01017315'
    raise 'pk1 Nested body changed' unless probe.send(:nested_body, OBJECTS[0].fetch('n')).unpack1('H*') == '0107036f6e65'
    raise 'pk5 multi-element body changed' unless probe.send(:nested_body, OBJECTS[4].fetch('n')).unpack1('H*') == '020b01610c026262'
    raise 'empty body changed' unless probe.send(:nested_body, OBJECTS[2].fetch('n')).unpack1('H*') == '00'
    tab = "\t"
    table = 'source_nested_v2_s0'
    profile = 'nested_v2_s0'
    sample = [
      "__W198_PIN__#{tab}#{VERSION}#{tab}#{BUILD}",
      "__W198_CHECK_BEGIN__#{tab}#{table}#{tab}#{profile}",
      "all_1_1_0#{tab}1#{tab}",
      "__W198_CHECK_END__#{tab}#{table}#{tab}#{profile}",
      "__W198_ZERO_BEGIN__#{tab}#{table}#{tab}zero#{tab}whole",
      "__W198_ZERO_END__#{tab}#{table}#{tab}zero#{tab}whole",
    ].join("\n")
    parsed = probe.send(:parse_native, sample)
    raise 'TSV pin tab parsing changed' unless parsed[:pin] == "__W198_PIN__#{tab}#{VERSION}#{tab}#{BUILD}"
    raise 'TSV check boundary parsing changed' unless parsed[:checks] == {[table, profile] => ["all_1_1_0#{tab}1#{tab}"]}
    raise 'TSV zero-window boundary parsing changed' unless parsed[:zero_events] == [
      ['__W198_ZERO_BEGIN__', table, 'zero', 'whole'],
      ['__W198_ZERO_END__', table, 'zero', 'whole'],
    ]

    reject = lambda do |label, &operation|
      begin
        operation.call
      rescue StandardError
        next
      end
      raise "#{label} was accepted"
    end
    pin_line = "__W198_PIN__#{tab}#{VERSION}#{tab}#{BUILD}"
    reject.call('duplicate CHECK begin') do
      probe.send(:parse_native, [pin_line,
        "__W198_CHECK_BEGIN__#{tab}#{table}#{tab}#{profile}",
        "__W198_CHECK_BEGIN__#{tab}#{table}#{tab}#{profile}"].join("\n"))
    end
    reject.call('mismatched CHECK end') do
      probe.send(:parse_native, [pin_line,
        "__W198_CHECK_BEGIN__#{tab}#{table}#{tab}#{profile}",
        "__W198_CHECK_END__#{tab}other#{tab}#{profile}"].join("\n"))
    end
    reject.call('unclosed CHECK block') do
      probe.send(:parse_native, [pin_line, "__W198_CHECK_BEGIN__#{tab}#{table}#{tab}#{profile}"].join("\n"))
    end
    reject.call('duplicate data-path record') do
      probe.send(:parse_native, [pin_line,
        "__W198_DATA_PATH__#{tab}#{table}#{tab}/tmp/a",
        "__W198_DATA_PATH__#{tab}#{table}#{tab}/tmp/b"].join("\n"))
    end
    reject.call('malformed active-part field width') do
      probe.send(:parse_native, [pin_line, "__W198_PART__#{tab}#{table}#{tab}all_1_1_0"].join("\n"))
    end
    reject.call('duplicate runtime pin') do
      probe.send(:parse_native, [pin_line, pin_line].join("\n"))
    end

    input_profiles = PROFILE_DEFS.map do |profile_id, kind, shared_version, string_profile|
      {'profile_id' => profile_id, 'kind' => kind, 'shared_version' => shared_version,
       'string_profile' => string_profile, 'library_part' => "/private/tmp/w198-self-test/#{profile_id}/all_1_1_0"}
    end
    helper_side = lambda do |kind, string_profile|
      {
        'source_declaration' => COLUMN_TYPE, 'schema_declaration' => COLUMN_TYPE,
        'shared_data_version' => 2,
        'row_count' => 8, 'mark_row_counts' => [2, 2, 2, 2],
        'physical_stream_names' => ['j.n'], 'ordinary_string_profile' => string_profile,
        'full_rows' => (1..8).map { |pk| probe.send(:helper_row, kind, pk) },
        'middle_rows' => (3..6).map { |pk| probe.send(:helper_row, kind, pk) },
        'zero_rows' => [],
      }
    end
    build_output = lambda do
      records = PROFILE_DEFS.map do |profile_id, kind, shared_version, string_profile|
        side = helper_side.call(kind, string_profile)
        side['shared_data_version'] = shared_version
        {'profile_id' => profile_id, 'kind' => kind, 'shared_version' => shared_version,
         'string_profile' => string_profile,
         'library_part_path' => "/private/tmp/w198-self-test/#{profile_id}/all_1_1_0",
         'source' => JSON.parse(JSON.generate(side)), 'library' => JSON.parse(JSON.generate(side))}
      end
      {'format' => FORMAT_OUTPUT, 'profile_ids' => PROFILE_DEFS.map(&:first), 'profiles' => records}
    end
    input = {'profiles' => input_profiles}
    valid_output = build_output.call
    probe.send(:assert_helper_output!, valid_output, input)
    bad_nominal = build_output.call
    bad_nominal['profiles'][0]['library']['full_rows'][0]['type_name'] = 'String'
    reject.call('poisoned nominal actual type') do
      probe.send(:assert_helper_output!, bad_nominal, input)
    end
    bad_value = build_output.call
    bad_value['profiles'][4]['source']['middle_rows'][0]['value_hex'] = '2f02016e010173150101'
    reject.call('poisoned Nested payload bytes') do
      probe.send(:assert_helper_output!, bad_value, input)
    end
    bad_shared_version = build_output.call
    bad_shared_version['profiles'][2]['library']['shared_data_version'] = 2
    reject.call('poisoned persisted shared-data version') do
      probe.send(:assert_helper_output!, bad_shared_version, input)
    end
    true
  end
end

def main
  options = {binary: CheckObjectSharedNestedPartsW198::BINARY}
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/check_object_shared_nested_parts_w198.rb --evidence-root EMPTY_CHILD_OF_PRIVATE_TMP --crystal-probe PREBUILT_HELPER [--binary CLICKHOUSE] [--self-test]'
    parser.on('--binary PATH') { |value| options[:binary] = value }
    parser.on('--crystal-probe PATH') { |value| options[:crystal_probe] = value }
    parser.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
    parser.on('--self-test') { options[:self_test] = true }
  end.parse!
  if options[:self_test]
    CheckObjectSharedNestedPartsW198.self_test!
    puts 'W198 Ruby literal self-test passed'
    exit 0
  end
  raise 'prebuilt Crystal helper is required via --crystal-probe' unless options[:crystal_probe]
  exit(CheckObjectSharedNestedPartsW198::Probe.new(options[:binary], options[:crystal_probe], options[:evidence_root]).run ? 0 : 1)
rescue StandardError => error
  warn "W198 probe runner error: #{error.class}: #{error.message}"
  exit 1
end

main if $PROGRAM_NAME == __FILE__
