#!/usr/bin/env ruby
# Bounded W252 reciprocal native witness for opaque JSON SQL-path identity.
# Uses only caller-supplied pinned executables and a prebuilt Crystal helper.

require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require_relative 'probe_json_sql_type_name_w251'

module ProbeJSONPathIdentityW252
  W251 = ProbeJSONSQLTypeNameW251
  W210 = W251::W210
  FORMAT_INPUT = 'json_path_identity_w252_input_v1'.freeze
  FORMAT_HELPER = 'json_path_identity_w252_helper_v1'.freeze
  FORMAT_CAPTURE = 'json_path_identity_w252_capture_v1'.freeze
  VERSION_PROFILES = {'v1' => 'single_stream', 'v2' => 'with_size_stream'}.freeze
  CASE_IDS = %w[root_dynamic array_dynamic root_object].freeze
  DYNAMIC_CASES = %w[root_dynamic array_dynamic].freeze
  SOURCE_FILES = ([
    File.expand_path(__FILE__),
    File.expand_path('check_json_path_identity_w252.cr', __dir__),
  ] + W251::SOURCE_FILES).uniq.freeze
  PARENT_MARK_ROWS = [2, 2, 2].freeze
  JSON_CHILD_MARK_ROWS = [2, 2, 2, 0].freeze
  RAW_PATHS = ['a.b', 'a%2Eb', 'a`b', 'id', 'maybe', 'x=y'].freeze
  JSON_TYPE = 'JSON(max_dynamic_types=1, max_dynamic_paths=1, `a%2Eb` UInt8, `a.b` UInt8, `a\\`b` UInt8, id UInt8, maybe Nullable(UInt8), `x=y` UInt8)'.freeze
  DYNAMIC_TYPE = 'Dynamic(max_types=3)'.freeze
  ARRAY_DYNAMIC_TYPE = "Array(#{DYNAMIC_TYPE})".freeze
  OBJECT_TYPE = JSON_TYPE
  COUNTER_TYPE = 'Int64'.freeze
  UINT8_TYPE = 'UInt8'.freeze
  WINDOWS = %w[all zero].freeze

  class Probe < W210::Probe
    def initialize(binary, crystal_helper, evidence_root, dynamic_version, helper_mode)
      super(binary, crystal_helper, evidence_root)
      fail_w252!('Dynamic version must be v1 or v2') unless VERSION_PROFILES.key?(dynamic_version)
      fail_w252!('helper mode must be debug or release') unless %w[debug release].include?(helper_mode)
      @dynamic_version = dynamic_version
      @profile = VERSION_PROFILES.fetch(dynamic_version)
      @helper_mode = helper_mode
      @all_tables = CASE_IDS.flat_map { |case_id| %w[source library].map { |origin| table(case_id, origin) } }
      @source_tables = CASE_IDS.map { |case_id| table(case_id, 'source') }
      @table_identity = CASE_IDS.flat_map do |case_id|
        %w[source library].map { |origin| [table(case_id, origin), [case_id, origin]] }
      end.to_h
      @source_pins_before = source_pins
    end

    def run
      prepare_layout!
      @binary_sha_before = binary_sha
      fail_w252!('pinned ClickHouse SHA-256 mismatch before probe') unless @binary_sha_before == W210::BINARY_SHA256
      @helper_sha_before = helper_sha
      @invocations = []

      initial = run_native('native_sources', initial_sql)
      @native_initial = parse_native(initial[:stdout])
      assert_pin!(@native_initial)
      assert_initial_native!(@native_initial)

      input = build_helper_input
      input_path = File.join(@root, 'generated', 'helper-input.json')
      input_bytes = JSON.pretty_generate(input) + "\n"
      write_new(input_path, input_bytes)
      @helper_input = {path: input_path, bytes: input_bytes.bytesize, sha256: Digest::SHA256.hexdigest(input_bytes)}
      helper = run_helper(input_path)
      @helper_output = helper[:data]
      assert_helper_output!(@helper_output)
      attach_library_parts!

      attached = run_native('native_attach_check', attached_sql)
      @native_attached = parse_native(attached[:stdout])
      assert_pin!(@native_attached)
      assert_attached_native!(@native_attached)
      assert_invocation_roster!

      @source_parts.each do |name, path|
        fail_w252!("stock source part changed during ATTACH/SELECT: #{name}") unless snapshot_part(path) == @source_snapshots.fetch(name)
      end
      @library_parts.each do |name, path|
        fail_w252!("library part changed during ATTACH/SELECT: #{name}") unless snapshot_part(path) == @library_snapshots.fetch(name)
      end
      @binary_sha_after = binary_sha
      @helper_sha_after = helper_sha
      fail_w252!('pinned ClickHouse SHA changed during probe') unless @binary_sha_after == W210::BINARY_SHA256
      fail_w252!('prebuilt helper SHA changed during probe') unless @helper_sha_after == @helper_sha_before
      @source_pins_after = source_pins
      fail_w252!('a pinned harness source changed during capture') unless @source_pins_after == @source_pins_before

      write_summary('bounded_cell_observed')
      puts "W252 JSON opaque path identity version=#{@dynamic_version} profile=#{@profile} mode=#{@helper_mode} cases=#{CASE_IDS.join(',')}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @binary_sha_after = binary_sha rescue nil
      @helper_sha_after = helper_sha rescue nil
      @source_pins_after = source_pins rescue nil
      write_summary('runner_failure_or_observations_differ') rescue nil
      warn "W252 probe failure (process failure is not native compatibility evidence): #{@fatal_error}"
      false
    end

    private

    def fail_w252!(message)
      raise "W252 JSON path identity witness: #{message}"
    end

    def source_pins
      SOURCE_FILES.map do |path|
        fail_w252!("pinned harness source is missing or symlinked: #{path}") unless File.file?(path) && !File.symlink?(path)
        {'path' => path, 'sha256' => Digest::SHA256.file(path).hexdigest}
      end
    end

    def prepare_layout!
      %w[invocations inputs stores generated].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
      CASE_IDS.each { |case_id| FileUtils.mkdir_p(File.join(@root, 'generated', case_id, @profile), mode: 0o700) }
      @source_parts = {}
      @source_snapshots = {}
      @library_parts = {}
      @library_snapshots = {}
      @data_paths = {}
    end

    def table(case_id, origin)
      "#{origin}_#{case_id}_#{@dynamic_version}"
    end

    def quote_sql(value)
      "'#{value.to_s.gsub(/[\\']/) { |character| "\\#{character}" }}'"
    end

    def identifier(path)
      escaped = path.gsub(/`/) { '\\`' }
      "`#{escaped}`"
    end

    def table_type(case_id)
      case case_id
      when 'root_dynamic' then DYNAMIC_TYPE
      when 'array_dynamic' then ARRAY_DYNAMIC_TYPE
      when 'root_object' then OBJECT_TYPE
      else fail_w252!("unknown case #{case_id.inspect}")
      end
    end

    def settings
      expected = "dynamic_serialization_version='v3'"
      fail_w252!('inherited native settings lost the W210 Dynamic version slot') unless W210::SETTINGS.scan(expected).size == 1
      W210::SETTINGS.sub(expected, "dynamic_serialization_version='#{@dynamic_version}'") + ", string_serialization_version='#{@profile}'"
    end

    def object_row(index)
      {
        'a' => {'b' => 17 + index}, 'a%2Eb' => 23 + index, 'a`b' => 31 + index,
        'id' => 41 + index, 'maybe' => nil, 'x=y' => 42 + index,
      }
    end

    def dynamic_json_row(index)
      row = object_row(index)
      row['counter'] = 401 + index
      row
    end

    def dynamic_json_sql(index)
      json = JSON.generate(dynamic_json_row(index))
      "CAST(CAST(#{quote_sql(json)}, #{quote_sql(JSON_TYPE)}), #{quote_sql(DYNAMIC_TYPE)})"
    end

    def dynamic_uint8_sql(value)
      "CAST(toUInt8(#{value}), #{quote_sql(DYNAMIC_TYPE)})"
    end

    def array_dynamic_sql(values)
      items = values.map do |item|
        item.is_a?(Integer) ? dynamic_uint8_sql(item) : dynamic_json_sql(item.fetch('json_index'))
      end
      "CAST([#{items.join(', ')}], #{quote_sql(ARRAY_DYNAMIC_TYPE)})"
    end

    def source_value_rows(case_id)
      values = case case_id
               when 'root_dynamic'
                 [dynamic_uint8_sql(17), dynamic_uint8_sql(18), dynamic_uint8_sql(19), dynamic_uint8_sql(20), dynamic_json_sql(0), dynamic_json_sql(1)]
               when 'array_dynamic'
                 [array_dynamic_sql([]), array_dynamic_sql([]), array_dynamic_sql([17, 18]), array_dynamic_sql([19]),
                  array_dynamic_sql([{'json_index' => 0}]), array_dynamic_sql([{'json_index' => 1}])]
               when 'root_object'
                 (0...6).map { |index| "CAST(#{quote_sql(JSON.generate(object_row(index)))}, #{quote_sql(OBJECT_TYPE)})" }
               else
                 fail_w252!("unknown source case #{case_id.inspect}")
               end
      values.each_with_index.map { |value, index| "(#{index + 1}, #{value})" }
    end

    def check_sql(table_name)
      ["SELECT '__W252_CHECK_BEGIN__', '#{table_name}' FORMAT TSVRaw;",
       "CHECK TABLE default.#{table_name} FORMAT TSV;",
       "SELECT '__W252_CHECK_END__', '#{table_name}' FORMAT TSVRaw;"].join("\n")
    end

    def parts_sql(tables)
      names = tables.map { |name| "'#{name}'" }.join(',')
      "SELECT '__W252_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table IN (#{names}) AND active ORDER BY table,name FORMAT TSVRaw;"
    end

    def schema_sql
      names = @all_tables.map { |name| "'#{name}'" }.join(',')
      "SELECT '__W252_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{names}) ORDER BY table,position FORMAT TSVRaw;"
    end

    def data_path_sql
      names = @all_tables.map { |name| "'#{name}'" }.join(',')
      "SELECT '__W252_DATA_PATH__', name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name IN (#{names}) ORDER BY name FORMAT TSVRaw;"
    end

    def value_queries(table_name, case_id)
      if case_id == 'root_object'
        fields = RAW_PATHS.map do |path|
          path == 'maybe' ? "toString(isNull(payload.#{identifier(path)}))" : "toString(payload.#{identifier(path)})"
        end
        query = "SELECT '__W252_OBJECT_VALUES__', '#{table_name}', toString(pk), hex(toTypeName(payload)), #{fields.join(', ')} FROM default.#{table_name} ORDER BY pk FORMAT TSVRaw;"
      else
        path_expressions = RAW_PATHS.map do |path|
          expression = "(dynamicElement(payload, #{quote_sql(JSON_TYPE)})).#{identifier(path)}"
          path == 'maybe' ? "toString(isNull(#{expression}))" : "toString(#{expression})"
        end
        counter = "(dynamicElement(payload, #{quote_sql(JSON_TYPE)})).counter"
        guard = "dynamicType(payload) = #{quote_sql(JSON_TYPE)}"
        if case_id == 'root_dynamic'
          fields = path_expressions.map { |expression| "if(#{guard}, #{expression}, '-')" }
          fields << "if(#{guard}, hex(dynamicType(#{counter})), '-')"
          fields << "if(#{guard}, toString(#{counter}), '-')"
          query = "SELECT '__W252_DYNAMIC_VALUES__', '#{table_name}', toString(pk), hex(dynamicType(payload)), #{fields.join(', ')} FROM default.#{table_name} ORDER BY pk SETTINGS print_pretty_type_names=0 FORMAT TSVRaw;"
        else
          path_expressions = RAW_PATHS.map do |path|
            expression = "(dynamicElement(x, #{quote_sql(JSON_TYPE)})).#{identifier(path)}"
            path == 'maybe' ? "toString(isNull(#{expression}))" : "toString(#{expression})"
          end
          fields = ["arrayStringConcat(arrayMap(x -> hex(dynamicType(x)), payload), ',')"]
          path_expressions.each do |expression|
            fields << "arrayStringConcat(arrayMap(x -> if(dynamicType(x) = #{quote_sql(JSON_TYPE)}, #{expression.gsub('payload', 'x')}, '-'), payload), ',')"
          end
          array_counter = "(dynamicElement(x, #{quote_sql(JSON_TYPE)})).counter"
          fields << "arrayStringConcat(arrayMap(x -> if(dynamicType(x) = #{quote_sql(JSON_TYPE)}, hex(dynamicType(#{array_counter})), '-'), payload), ',')"
          fields << "arrayStringConcat(arrayMap(x -> if(dynamicType(x) = #{quote_sql(JSON_TYPE)}, toString(#{array_counter}), '-'), payload), ',')"
          query = "SELECT '__W252_DYNAMIC_VALUES__', '#{table_name}', toString(pk), #{fields.join(', ')} FROM default.#{table_name} ORDER BY pk SETTINGS print_pretty_type_names=0 FORMAT TSVRaw;"
        end
      end
      [query,
       "SELECT '__W252_ZERO_BEGIN__', '#{table_name}', '#{@profile}', 'values' FORMAT TSVRaw;",
       "SELECT '__W252_ZERO_ROW__', '#{table_name}', toString(pk) FROM default.#{table_name} WHERE pk > 6 ORDER BY pk FORMAT TSVRaw;",
       "SELECT '__W252_ZERO_END__', '#{table_name}', '#{@profile}', 'values' FORMAT TSVRaw;"].compact
    end

    def initial_sql
      statements = [
        'SET flatten_nested=0;', 'SET allow_suspicious_low_cardinality_types=1;',
        'SET output_format_json_named_tuples_as_objects=1;', 'SET print_pretty_type_names=0;',
        'SET json_type_escape_dots_in_keys=0;',
        "SELECT '__W252_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
      ]
      CASE_IDS.each do |case_id|
        [table(case_id, 'source'), table(case_id, 'library')].each do |name|
          statements << "CREATE TABLE default.#{name} (pk UInt64, payload #{table_type(case_id)}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings};"
        end
        rows = source_value_rows(case_id).join(",\n")
        source = table(case_id, 'source')
        statements << "INSERT INTO default.#{source} VALUES\n#{rows};"
        statements << check_sql(source)
      end
      statements << schema_sql
      statements << data_path_sql
      statements << parts_sql(@source_tables)
      @source_tables.each do |name|
        case_id = @table_identity.fetch(name).first
        statements.concat(value_queries(name, case_id))
      end
      statements.join("\n") + "\n"
    end

    def attached_sql
      statements = [
        'SET flatten_nested=0;', 'SET allow_suspicious_low_cardinality_types=1;',
        'SET output_format_json_named_tuples_as_objects=1;', 'SET print_pretty_type_names=0;',
        'SET json_type_escape_dots_in_keys=0;',
        "SELECT '__W252_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
      ]
      CASE_IDS.each do |case_id|
        source = table(case_id, 'source')
        library = table(case_id, 'library')
        statements << "ALTER TABLE default.#{library} ATTACH PART 'all_1_1_0';"
        statements << check_sql(source)
        statements << check_sql(library)
      end
      statements << schema_sql
      statements << data_path_sql
      statements << parts_sql(@all_tables)
      @all_tables.each do |name|
        case_id = @table_identity.fetch(name).first
        statements.concat(value_queries(name, case_id))
      end
      statements.join("\n") + "\n"
    end

    def run_native(label, sql)
      result = send(:run_clickhouse, label, sql)
      fail_w252!("#{label} process failed or emitted stderr") unless send(:successful?, result) && result[:stderr].empty?
      result
    end

    def parse_native(stdout)
      lines = stdout.dup.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      fail_w252!('native output is not valid UTF-8') unless lines.all?(&:valid_encoding?)
      known = %w[__W252_PIN__ __W252_SCHEMA__ __W252_DATA_PATH__ __W252_PART__ __W252_CHECK_BEGIN__ __W252_CHECK_END__ __W252_OBJECT_VALUES__ __W252_DYNAMIC_VALUES__ __W252_ZERO_BEGIN__ __W252_ZERO_END__ __W252_ZERO_ROW__]
      unknown = lines.select { |line| line.start_with?('__W252_') }.map { |line| line.split("\t", 2).first }.uniq - known
      fail_w252!("unknown native marker tags #{unknown.inspect}") unless unknown.empty?
      records = ->(tag) { lines.select { |line| line.start_with?("#{tag}\t") }.map { |line| line.split("\t", -1) } }
      pins = records.call('__W252_PIN__')
      fail_w252!('native pin row shape differs') unless pins.size == 1 && pins.first.size == 3
      schemas = records.call('__W252_SCHEMA__').map do |fields|
        fail_w252!('native schema row width differs') unless fields.size == 4
        fields.drop(1)
      end
      path_rows = records.call('__W252_DATA_PATH__')
      paths = path_rows.to_h do |fields|
        fail_w252!('native data-path row width differs') unless fields.size == 3
        [fields[1], fields[2]]
      end
      part_rows = records.call('__W252_PART__')
      parts = part_rows.to_h do |fields|
        fail_w252!('native part row width differs') unless fields.size == 7
        [fields[1], {name: fields[2], path: fields[3], type: fields[4], rows: fields[5], marks: fields[6]}]
      end
      fail_w252!('native data-path rows contain duplicates') unless path_rows.map { |fields| fields[1] }.uniq.size == path_rows.size
      fail_w252!('native part rows contain duplicates') unless part_rows.map { |fields| fields[1] }.uniq.size == part_rows.size
      check_blocks = {}
      active = nil
      lines.each do |line|
        if line.start_with?("__W252_CHECK_BEGIN__\t")
          fields = line.split("\t", -1)
          fail_w252!('CHECK begin boundary malformed or nested') unless fields.size == 2 && !active
          active = fields[1]
          fail_w252!('duplicate CHECK block') if check_blocks.key?(active)
          check_blocks[active] = []
        elsif line.start_with?("__W252_CHECK_END__\t")
          fields = line.split("\t", -1)
          fail_w252!('CHECK end boundary malformed') unless fields.size == 2 && active == fields[1]
          active = nil
        elsif active
          check_blocks.fetch(active) << line
        end
      end
      fail_w252!('unterminated CHECK block') if active
      value_rows = records.call('__W252_OBJECT_VALUES__').map { |fields| ['object', fields.drop(1)] }
      value_rows.concat(records.call('__W252_DYNAMIC_VALUES__').map { |fields| ['dynamic', fields.drop(1)] })
      values = Hash.new { |hash, key| hash[key] = [] }
      value_rows.each do |kind, fields|
        expected_width = kind == 'object' ? 9 : 11
        fail_w252!("#{kind} native value row width differs") unless fields.size == expected_width
        values[[fields[0], kind]] << fields.drop(1)
      end
      zero_events = lines.select { |line| line.start_with?("__W252_ZERO_BEGIN__\t") || line.start_with?("__W252_ZERO_END__\t") }.map { |line| line.split("\t", -1) }
      zero_rows = records.call('__W252_ZERO_ROW__')
      {pin: pins.first, schemas: schemas, data_paths: paths, parts: parts, checks: check_blocks,
       values: values, zero_events: zero_events, zero_rows: zero_rows}
    end

    def assert_pin!(native)
      expected = ["__W252_PIN__", W210::VERSION, W210::BUILD]
      fail_w252!("runtime version/build pin differs: #{native[:pin].inspect}") unless native[:pin] == expected
    end

    def assert_invocation_roster!
      expected = %w[native_sources crystal_helper native_attach_check]
      actual = @invocations.map { |invocation| File.basename(invocation.fetch(:stdout_file), '.stdout') }
      fail_w252!("raw invocation roster/order differs: #{actual.inspect}") unless actual == expected
    end

    def expected_schemas(table_names)
      table_names.sort.flat_map do |name|
        case_id = @table_identity.fetch(name).first
        [[name, 'pk', 'UInt64'], [name, 'payload', table_type(case_id)]]
      end
    end

    def assert_native_common!(native, table_names, value_tables, expected_checks, expected_parts)
      fail_w252!('native CHECK roster/result differs') unless native[:checks] == expected_checks
      fail_w252!('native schema differs from exact SQL descriptors') unless native[:schemas] == expected_schemas(table_names)
      fail_w252!('native data-path roster differs') unless native[:data_paths].keys.sort == @all_tables.sort
      native[:data_paths].each_value { |path| send(:validate_store_path!, path) }
      fail_w252!('native part roster differs') unless native[:parts].keys.sort == expected_parts.sort
      expected_zero = value_tables.flat_map do |name|
        [['__W252_ZERO_BEGIN__', name, @profile, 'values'], ['__W252_ZERO_END__', name, @profile, 'values']]
      end
      fail_w252!('native zero-selection boundaries differ') unless native[:zero_events] == expected_zero
      fail_w252!('native zero-selection query unexpectedly returned rows') unless native[:zero_rows].empty?
      expected_parts.each do |name|
        part = native[:parts].fetch(name)
        fail_w252!("#{name} is not the expected six-row Wide part") unless part[:name] == 'all_1_1_0' && part[:type] == 'Wide' && part[:rows] == '6' && part[:marks] == '4'
      end
      native[:values].each_key do |table_name, kind|
        fail_w252!("unexpected native value case #{table_name}/#{kind}") unless @table_identity.key?(table_name)
      end
    end

    def expected_dynamic_rows(case_id)
      uint_hex = UINT8_TYPE.unpack1('H*').upcase
      json_hex = JSON_TYPE.unpack1('H*').upcase
      int_hex = COUNTER_TYPE.unpack1('H*').upcase
      if case_id == 'root_dynamic'
        ([17, 18, 19, 20].each_with_index.map do |value, index|
          [index + 1, uint_hex, '-', '-', '-', '-', '-', '-', '-', '-'].map(&:to_s)
        end + [
          ['5', json_hex, '17', '23', '31', '41', '1', '42', int_hex, '401'],
          ['6', json_hex, '18', '24', '32', '42', '1', '43', int_hex, '402'],
        ])
      else
        [
          ['1', '', '', '', '', '', '', '', '', ''],
          ['2', '', '', '', '', '', '', '', '', ''],
          ['3', [uint_hex, uint_hex].join(','), '-,-', '-,-', '-,-', '-,-', '-,-', '-,-', '-,-', '-,-'],
          ['4', uint_hex, '-', '-', '-', '-', '-', '-', '-', '-'],
          ['5', json_hex, '17', '23', '31', '41', '1', '42', int_hex, '401'],
          ['6', json_hex, '18', '24', '32', '42', '1', '43', int_hex, '402'],
        ]
      end
    end

    def expected_object_rows
      type_hex = OBJECT_TYPE.unpack1('H*').upcase
      (0...6).map do |index|
        [table('root_object', 'source'), (index + 1).to_s, type_hex, (17 + index).to_s, (23 + index).to_s,
         (31 + index).to_s, (41 + index).to_s, '1', (42 + index).to_s]
      end
    end

    def assert_values!(native, table_names)
      table_names.each do |name|
        case_id = @table_identity.fetch(name).first
        if case_id == 'root_object'
          actual = native[:values].fetch([name, 'object'], [])
          expected = expected_object_rows.map { |row| row.drop(1) }
          fail_w252!("#{name} raw Object path values differ: #{actual.inspect}") unless actual == expected
        else
          actual = native[:values].fetch([name, 'dynamic'], [])
          expected = expected_dynamic_rows(case_id)
          fail_w252!("#{name} Dynamic JSON path/value/type rows differ: #{actual.inspect}") unless actual == expected
        end
      end
      expected_keys = table_names.map { |name| [name, @table_identity.fetch(name).first == 'root_object' ? 'object' : 'dynamic'] }.sort
      fail_w252!('native value query roster differs') unless native[:values].keys.sort == expected_keys
    end

    def assert_initial_native!(native)
      expected_checks = @source_tables.to_h { |name| [name, ["all_1_1_0\t1\t"]] }
      assert_native_common!(native, @all_tables, @source_tables, expected_checks, @source_tables)
      fail_w252!('source native values differ') unless native[:values].keys.map(&:first).sort == @source_tables.sort
      @data_paths = native[:data_paths].dup
      @source_tables.each do |name|
        path = native[:parts].fetch(name)[:path]
        full = send(:validate_source_part!, path)
        @source_parts[name] = full
        @source_snapshots[name] = send(:snapshot_part, full)
      end
      assert_values!(native, @source_tables)
    end

    def assert_attached_native!(native)
      expected_checks = @all_tables.to_h { |name| [name, ["all_1_1_0\t1\t"]] }
      assert_native_common!(native, @all_tables, @all_tables, expected_checks, @all_tables)
      assert_values!(native, @all_tables)
    end

    def build_helper_input
      capture_root = File.realpath(File.join(@root, 'stores', 'native'))
      cases = CASE_IDS.map do |case_id|
        {
          'case_id' => case_id, 'profile_id' => @profile, 'capture_root' => capture_root,
          'version' => @dynamic_version,
          'source_part' => @source_parts.fetch(table(case_id, 'source')),
          'library_part' => File.join(@root, 'generated', case_id, @profile, 'all_1_1_0'),
        }
      end
      {'format' => FORMAT_INPUT, 'dynamic_version' => @dynamic_version,
       'profile_id' => @profile, 'capture_root' => capture_root, 'cases' => cases}
    end

    def run_helper(input_path)
      before = helper_sha
      fail_w252!('prebuilt helper changed before invocation') unless before == @helper_sha_before
      argv = [@helper, input_path, File.join(@root, 'generated')]
      invocation = @executor.send(:execute_record, 'crystal_helper', argv, ''.b,
                                  'prebuilt W252 Crystal helper', before, @helper)
      fail_w252!('Crystal helper process failed') unless send(:successful?, invocation)
      fail_w252!('Crystal helper emitted stderr') unless invocation[:stderr].empty?
      fail_w252!('Crystal helper changed during invocation') unless helper_sha == before
      lines = invocation[:stdout].lines.map(&:chomp).reject(&:empty?)
      fail_w252!('Crystal helper must emit exactly one JSON record') unless lines.size == 1
      data = JSON.parse(lines.first)
      fail_w252!('Crystal helper output format differs') unless data['format'] == FORMAT_HELPER
      @invocations << invocation[:record]
      {data: data, record: invocation[:record]}
    end

    def expected_helper_rows(case_id)
      json1 = 'json[17,23,31,41,null,42;counter=401]'
      json2 = 'json[18,24,32,42,null,43;counter=402]'
      case case_id
      when 'root_dynamic' then [['u8:17', 'u8:18'], ['u8:19', 'u8:20'], [json1, json2]]
      when 'array_dynamic' then [['[]', '[]'], ['[u8:17|u8:18]', '[u8:19]'], ["[#{json1}]", "[#{json2}]"]]
      when 'root_object' then (0...6).each_slice(2).map { |indices| indices.map { |i| [17 + i, 23 + i, 31 + i, 41 + i, 'null', 42 + i].join(',') } }
      else fail_w252!("unknown helper case #{case_id.inspect}")
      end
    end

    def assert_helper_output!(data)
      root_keys = %w[case_ids cases dynamic_version dynamic_version_wire format json_child_mark_rows parent_mark_rows profile_id]
      fail_w252!('helper output keys/format differ') unless data.keys.sort == root_keys && data['format'] == FORMAT_HELPER
      expected_wire = @dynamic_version == 'v1' ? 1 : 2
      fail_w252!('helper version/profile/P contract differs') unless data['dynamic_version'] == @dynamic_version && data['dynamic_version_wire'] == expected_wire &&
        data['profile_id'] == @profile && data['case_ids'] == CASE_IDS && data['parent_mark_rows'] == PARENT_MARK_ROWS && data['json_child_mark_rows'] == JSON_CHILD_MARK_ROWS
      cases = data.fetch('cases')
      fail_w252!('helper case roster/order differs') unless cases.map { |item| item.fetch('case_id') } == CASE_IDS
      expected_side_keys = %w[case_id profile_id schema_declaration row_count mark_count mark_row_counts rows_by_mark physical_stream_names selected_checksum_names object_child_stream_names bound_json_type_names structure_audits owned_values offline_values windows].sort
      cases.each do |item|
        case_id = item.fetch('case_id')
        expected_path = File.join(@root, 'generated', case_id, @profile, 'all_1_1_0')
        fail_w252!("#{case_id} helper case keys/path differ") unless item.keys.sort == %w[case_id library library_part_path profile_id source] && item['profile_id'] == @profile && File.expand_path(item['library_part_path']) == expected_path
        %w[source library].each do |origin|
          side = item.fetch(origin)
          fail_w252!("#{case_id}/#{origin} helper keys differ") unless side.keys.sort == expected_side_keys
          fail_w252!("#{case_id}/#{origin} helper nominal/value/P census differs") unless side['case_id'] == case_id && side['profile_id'] == @profile &&
            side['schema_declaration'] == table_type(case_id) && side['row_count'] == 6 && side['mark_count'] == 3 &&
            side['mark_row_counts'] == PARENT_MARK_ROWS && side['rows_by_mark'] == expected_helper_rows(case_id)
          fail_w252!("#{case_id}/#{origin} physical name report is malformed") unless side['physical_stream_names'].is_a?(Array) && side['physical_stream_names'].uniq == side['physical_stream_names'] &&
            side['selected_checksum_names'].is_a?(Array) && side['selected_checksum_names'].uniq == side['selected_checksum_names'] &&
            side['object_child_stream_names'].is_a?(Array) && side['bound_json_type_names'].is_a?(Array)
          if case_id == 'root_object'
            fail_w252!("#{case_id}/#{origin} offline owned rows differ") unless side['offline_values'] == expected_helper_rows(case_id).flatten && side['owned_values'].nil?
          else
            fail_w252!("#{case_id}/#{origin} Dynamic offline-values field should be null") unless side['offline_values'].nil?
          end
          if case_id != 'root_object'
            owned = side['owned_values']
            fail_w252!("#{case_id} OfflineTable owned-values census differs") unless owned.is_a?(Hash) && owned['schema_declaration'] == table_type(case_id) && owned['row_count'] == 6 && owned['mark_row_counts'] == PARENT_MARK_ROWS && owned['values_by_mark'] == expected_helper_rows(case_id)
          elsif case_id == 'root_object'
            fail_w252!("#{case_id}/#{origin} unexpected Dynamic owned-values report") unless side['owned_values'].nil?
          end
        end
        library_path = item.fetch('library_part_path')
        send(:validate_plain_tree!, library_path)
        @library_parts[case_id] = library_path
        @library_snapshots[case_id] = send(:snapshot_part, library_path)
      end
    end

    def attach_library_parts!
      CASE_IDS.each do |case_id|
        target = table(case_id, 'library')
        part = @library_parts.fetch(case_id)
        send(:validate_plain_tree!, part)
        store = send(:validate_store_path!, @data_paths.fetch(target))
        @executor.send(:attach_part!, part, store)
      end
    end

    def normalized_native(native)
      {
        'pin' => native[:pin],
        'schemas' => native[:schemas],
        'data_paths' => native[:data_paths],
        'parts' => native[:parts].transform_values { |part| part.transform_keys(&:to_s) },
        'checks' => native[:checks].map { |table_name, rows| {'table' => table_name, 'rows' => rows} },
        'values' => native[:values].map { |(table_name, kind), rows| {'table' => table_name, 'kind' => kind, 'rows' => rows} },
        'zero_events' => native[:zero_events],
        'zero_rows' => native[:zero_rows],
      }
    end

    def write_summary(status)
      return unless @root && File.directory?(@root) && File.directory?(File.join(@root, 'invocations'))
      summary = {
        'format' => FORMAT_CAPTURE, 'status' => status, 'fatal_error' => @fatal_error,
        'scope' => {
          'dynamic_version' => @dynamic_version, 'dynamic_version_wire' => (@dynamic_version == 'v1' ? 1 : 2),
          'string_profile' => @profile, 'helper_mode' => @helper_mode, 'case_ids' => CASE_IDS,
          'claim' => 'finite typed opaque-path identity witness: root Dynamic, Array(Dynamic), and root Object only',
          'typed_raw_paths' => RAW_PATHS, 'dot_setting' => 'json_type_escape_dots_in_keys=0',
          'parent_mark_rows' => PARENT_MARK_ROWS, 'json_child_mark_rows' => JSON_CHILD_MARK_ROWS,
          'unused_json_arm' => 'library-generated Dynamic parent only',
        },
        'runtime' => {'path' => @binary, 'expected_sha256' => W210::BINARY_SHA256,
                      'sha256_before' => @binary_sha_before, 'sha256_after' => @binary_sha_after,
                      'expected_version' => W210::VERSION, 'expected_version_git_hash' => W210::BUILD},
        'helper' => {'path' => @helper, 'mode' => @helper_mode,
                     'sha256_before' => @helper_sha_before, 'sha256_after' => @helper_sha_after,
                     'source_path' => File.expand_path('check_json_path_identity_w252.cr', __dir__),
                     'source_sha256' => source_pin_for(File.expand_path('check_json_path_identity_w252.cr', __dir__))},
        'harness_source_pins' => {'before' => @source_pins_before, 'after' => @source_pins_after},
        'helper_input' => @helper_input, 'helper_output' => @helper_output,
        'invocations' => @invocations,
        'native' => {'initial' => (@native_initial && normalized_native(@native_initial)),
                     'attached' => (@native_attached && normalized_native(@native_attached))},
        'parts' => {'source_paths' => @source_parts, 'library_paths' => @library_parts,
                    'source_snapshots' => @source_snapshots, 'library_snapshots' => @library_snapshots},
        'limits' => {'max_threads' => 1, 'local_max_memory_usage_bytes' => W210::MEMORY,
                     'required_outer_run_safe_memory_limit_bytes' => W210::OUTER_RUN_SAFE_LIMIT,
                     'timeout_seconds' => W210::TIMEOUT, 'termination_grace_seconds' => W210::GRACE,
                     'executor' => 'JsonBinaryKernelW180Probe#execute'},
      }
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n") unless File.exist?(File.join(@root, 'summary.json'))
      write_new(File.join(@root, 'summary.md'), [
        '# W252 JSON SQL path identity compatibility', '', "Status: `#{status}`", '',
        "Scope: `#{@dynamic_version}` / `#{@profile}`, cases #{CASE_IDS.join(', ')}. The native source and attached library rows are compared to explicit path/value/type literals; nested input key `a` then `b` is separated from the literal percent key under `json_type_escape_dots_in_keys=0`. This is a finite witness, not a general JSON-layout closure claim.", '',
        "Runtime: #{W210::VERSION} / VERSION_GITHASH #{W210::BUILD} / SHA256 `#{W210::BINARY_SHA256}`", '',
        "Evidence root: `#{@root}`", '',
      ].join("\n")) unless File.exist?(File.join(@root, 'summary.md'))
    end

    def source_pin_for(path)
      @source_pins_before&.find { |item| item['path'] == path }&.fetch('sha256')
    end
  end

  if $PROGRAM_NAME == __FILE__
    options = {binary: W210::BINARY, helper: nil, root: nil, dynamic_version: nil, helper_mode: nil}
    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby scripts/probe_json_path_identity_w252.rb --dynamic-version v1|v2 --helper-mode debug|release --crystal-helper PREBUILT --evidence-root EMPTY_/private/tmp_CHILD [--clickhouse PINNED]'
      parser.on('--clickhouse PATH', 'Pinned ClickHouse executable') { |value| options[:binary] = value }
      parser.on('--crystal-helper PATH', 'Prebuilt W252 Crystal helper; this runner never compiles it') { |value| options[:helper] = value }
      parser.on('--evidence-root PATH', 'Existing empty direct child of /private/tmp') { |value| options[:root] = value }
      parser.on('--dynamic-version VERSION', 'One pair: v1/single_stream or v2/with_size_stream') { |value| options[:dynamic_version] = value }
      parser.on('--helper-mode MODE', 'Prebuilt Crystal helper mode: debug or release') { |value| options[:helper_mode] = value }
    end.parse!
    abort 'W252: --dynamic-version, --helper-mode, --crystal-helper and --evidence-root are required' unless
      options[:helper] && options[:root] && options[:dynamic_version] && options[:helper_mode]
    exit(Probe.new(options[:binary], options[:helper], options[:root], options[:dynamic_version], options[:helper_mode]).run ? 0 : 1)
  end
end
