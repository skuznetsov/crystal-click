#!/usr/bin/env ruby
# Paired stock/library witness for W210 Dynamic -> JSON Object physical
# composition. Uses only supplied pinned executables and a prebuilt helper.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require_relative 'probe_nested_bulk_part_w202'

module ProbeDynamicJSONPhysicalW210
  W202 = ProbeNestedBulkPartW202
  W183 = JsonArrayStorageW183
  BINARY = W202::BINARY
  BINARY_SHA256 = W202::BINARY_SHA256
  VERSION = W202::VERSION
  BUILD = W202::BUILD
  MEMORY = W202::MEMORY
  TIMEOUT = W202::TIMEOUT
  GRACE = W202::GRACE
  OUTER_RUN_SAFE_LIMIT = W202::OUTER_RUN_SAFE_LIMIT

  FORMAT_INPUT = 'dynamic_json_physical_w210_input_v1'.freeze
  FORMAT_OUTPUT = 'dynamic_json_physical_w210_helper_v1'.freeze
  CASE_IDS = %w[root_dynamic array_dynamic].freeze
  PROFILE_IDS = %w[single_stream with_size_stream].freeze
  WINDOWS = %w[FULL FIRST_EMPTY LATER FINAL ZERO].freeze
  MAX_COLUMNS_SUBSTREAMS_BYTES = 1_048_576

  DYNAMIC = 'Dynamic(max_types=3)'.freeze
  ARRAY_DYNAMIC = "Array(#{DYNAMIC})".freeze
  JSON_USED = 'JSON(max_dynamic_types=1, max_dynamic_paths=1, id UInt8, maybe Nullable(UInt8))'.freeze
  JSON_UNUSED = 'JSON(max_dynamic_types=2, max_dynamic_paths=1, id UInt8, maybe Nullable(UInt8))'.freeze
  UINT8 = 'UInt8'.freeze

  SETTINGS = [
    'index_granularity=2', 'index_granularity_bytes=10485760',
    'enable_mixed_granularity_parts=1', 'min_rows_for_wide_part=0',
    'min_bytes_for_wide_part=0', 'compress_marks=0', 'compress_primary_key=0',
    'min_compress_block_size=0', 'max_compress_block_size=4096',
    "default_compression_codec='LZ4'", "serialization_info_version='with_types'",
    'propagate_types_serialization_versions_to_nested_types=1',
    'use_compact_variant_discriminators_serialization=0', "dynamic_serialization_version='v3'",
    "object_serialization_version='v3'",
    "object_shared_data_serialization_version_for_zero_level_parts='map'",
    "map_serialization_version='basic'", "map_serialization_version_for_zero_level_parts='basic'",
  ].join(', ').freeze

  # Independent native-value literals; never filled from helper output.
  ROOT_VALUES = [17, 18, 19, 20, {'id' => 41, 'maybe' => nil, 'counter' => 401},
                 {'id' => 42, 'maybe' => nil, 'counter' => 402}].freeze
  ARRAY_VALUES = [[], [], [17, 18], [19],
                  [{'id' => 41, 'maybe' => nil, 'counter' => 401}],
                  [{'id' => 42, 'maybe' => nil, 'counter' => 402}]].freeze
  ROWS = {'root_dynamic' => ROOT_VALUES, 'array_dynamic' => ARRAY_VALUES}.freeze
  PARENT_MARK_ROWS = [2, 2, 2].freeze
  OBJECT_CHILD_MARK_ROWS = [2, 2, 2, 0].freeze

  # Literal Object child stream suffixes expected from the bound typed-path,
  # Dynamic-path, and MAP owners. The inherited Array coordinate changes the
  # MAP size lane; with-size adds a lane to SharedVariant, not MAP paths/values.
  OBJECT_CHILD_SUFFIXES = {
    ['single_stream', 0] => %w[
      .object_structure .id .maybe.null .maybe
      .counter.dynamic_structure .counter.variant_discr .counter.SharedVariant .counter.Int64
      .object_shared_data.size0 .object_shared_data%2Epaths .object_shared_data%2Evalues
    ].freeze,
    ['single_stream', 1] => %w[
      .object_structure .id .maybe.null .maybe
      .counter.dynamic_structure .counter.variant_discr .counter.SharedVariant .counter.Int64
      .object_shared_data.size1 .object_shared_data%2Epaths .object_shared_data%2Evalues
    ].freeze,
    ['with_size_stream', 0] => %w[
      .object_structure .id .maybe.null .maybe
      .counter.dynamic_structure .counter.variant_discr .counter.SharedVariant .counter.SharedVariant.size .counter.Int64
      .object_shared_data.size0 .object_shared_data%2Epaths
      .object_shared_data%2Evalues
    ].freeze,
    ['with_size_stream', 1] => %w[
      .object_structure .id .maybe.null .maybe
      .counter.dynamic_structure .counter.variant_discr .counter.SharedVariant .counter.SharedVariant.size .counter.Int64
      .object_shared_data.size1 .object_shared_data%2Epaths
      .object_shared_data%2Evalues
    ].freeze,
  }.freeze

  def self.assert(ok, message)
    raise "W210 Dynamic JSON physical witness: #{message}" unless ok
  end

  def self.type_for(case_id)
    {'root_dynamic' => DYNAMIC, 'array_dynamic' => ARRAY_DYNAMIC}.fetch(case_id)
  end

  def self.table(case_id, profile, origin)
    "#{origin}_#{case_id}_#{profile}"
  end

  def self.case_profiles
    CASE_IDS.flat_map { |case_id| PROFILE_IDS.map { |profile| [case_id, profile] } }
  end

  def self.escaped_component(value)
    value.b.bytes.map do |byte|
      character = byte.chr
      character.match?(/[A-Za-z0-9_]/) ? character : format('%%%02X', byte)
    end.join
  end

  def self.arm_prefix(case_id, json_type)
    root = case case_id
           when 'root_dynamic', 'array_dynamic' then 'payload'
           else raise ArgumentError, "unknown W210 Dynamic JSON case #{case_id.inspect}"
           end
    "#{root}.#{escaped_component(json_type)}"
  end

  def self.object_child_names(case_id, profile, json_type)
    array_level = case_id == 'array_dynamic' ? 1 : 0
    suffixes = OBJECT_CHILD_SUFFIXES.fetch([profile, array_level])
    suffixes.map { |suffix| "#{arm_prefix(case_id, json_type)}#{suffix}" }.sort
  end

  def self.sql_quote(value)
    "'#{value.to_s.gsub(/[\\']/) { |character| "\\#{character}" }}'"
  end

  def self.json_sql(id, counter)
    raw = JSON.generate({'id' => id, 'maybe' => nil, 'counter' => counter})
    "CAST(CAST(#{sql_quote(raw)}, '#{JSON_USED}'), '#{DYNAMIC}')"
  end

  def self.uint8_dynamic_sql(value)
    "CAST(toUInt8(#{value}), '#{DYNAMIC}')"
  end

  def self.value_sql(case_id, value)
    if case_id == 'root_dynamic'
      value.is_a?(Hash) ? json_sql(value.fetch('id'), value.fetch('counter')) : uint8_dynamic_sql(value)
    else
      children = value.map do |item|
        item.is_a?(Hash) ? json_sql(item.fetch('id'), item.fetch('counter')) : uint8_dynamic_sql(item)
      end
      "CAST([#{children.join(', ')}], '#{ARRAY_DYNAMIC}')"
    end
  end

  def self.value_sql_rows(case_id)
    ROWS.fetch(case_id).each_with_index.map do |value, index|
      "(#{index + 1}, #{value_sql(case_id, value)})"
    end
  end

  def self.arm_projection(case_id)
    if case_id == 'root_dynamic'
      [
        "if(isNull(payload), 'NULL', dynamicType(payload))",
        "toString(toUInt8(isDynamicElementInSharedData(payload)))",
        "'1'",
      ]
    else
      [
        "arrayStringConcat(arrayMap(x -> if(isNull(x), 'NULL', dynamicType(x)), payload), ',')",
        "arrayStringConcat(arrayMap(x -> toString(toUInt8(isDynamicElementInSharedData(x))), payload), ',')",
        'toString(length(payload))',
      ]
    end
  end

  def self.counter_projection(case_id)
    if case_id == 'root_dynamic'
      counter = "(dynamicElement(payload, '#{JSON_USED}')).counter"
      [
        "if(dynamicType(payload) = '#{JSON_USED}', dynamicType(#{counter}), '-')",
        "if(dynamicType(payload) = '#{JSON_USED}', toString(toUInt8(isDynamicElementInSharedData(#{counter}))), '-')",
      ]
    else
      [
        "arrayStringConcat(arrayMap(x -> if(dynamicType(x) = '#{JSON_USED}', dynamicType((dynamicElement(x, '#{JSON_USED}')).counter), '-'), payload), ',')",
        "arrayStringConcat(arrayMap(x -> if(dynamicType(x) = '#{JSON_USED}', toString(toUInt8(isDynamicElementInSharedData((dynamicElement(x, '#{JSON_USED}')).counter))), '-'), payload), ',')",
      ]
    end
  end

  def self.counter_sql_rows(case_id, window)
    all = ROWS.fetch(case_id)
    values = case window
             when 'FULL' then all
             when 'FIRST_EMPTY' then all[0, 2]
             when 'LATER' then all[2, 2]
             when 'FINAL' then all[4, 2]
             else raise "unknown W210 counter window #{window.inspect}"
             end
    values.each_with_index.map do |value, index|
      pk = case window
           when 'FULL', 'FIRST_EMPTY' then index + 1
           when 'LATER' then index + 3
           when 'FINAL' then index + 5
           end
      counters = if case_id == 'root_dynamic'
                   value.is_a?(Hash) ? ['Int64', '0'] : ['-', '-']
                 else
                   types = value.map { |item| item.is_a?(Hash) ? 'Int64' : '-' }
                   shared = value.map { |item| item.is_a?(Hash) ? '0' : '-' }
                   [types.join(','), shared.join(',')]
                 end
      [pk.to_s, *counters]
    end
  end

  class Probe < W202::Probe
    def initialize(binary, crystal_helper, evidence_root)
      super
      @source_parts = {}
      @source_snapshots = {}
      @library_parts = {}
      @library_snapshots = {}
      @data_paths = {}
      @table_identity = {}
      @part_rosters = {}
      @fatal_error = nil
    end

    def run
      prepare_layout!
      @binary_sha_before = binary_sha
      fail!('pinned ClickHouse SHA-256 mismatch before probe') unless @binary_sha_before == BINARY_SHA256
      @helper_sha_before = helper_sha
      fail!('prebuilt helper SHA changed before probe') unless @helper_sha_before == helper_sha

      initial = run_clickhouse('native_sources', initial_sql)
      assert_native_invocation!(initial)
      native = parse_native(initial[:stdout])
      assert_pin!(native)
      assert_initial_native!(native)
      source_counter_rows = assert_counter_evidence!(initial[:stdout], source_tables)

      input_path = File.join(@root, 'generated', 'helper-input.json')
      helper_input = build_helper_input
      input_bytes = JSON.pretty_generate(helper_input) + "\n"
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
        fail!("stock source part changed during ATTACH/SELECT: #{name}") unless snapshot_part(path) == @source_snapshots.fetch(name)
      end
      @library_parts.each do |key, path|
        fail!("library part changed during ATTACH/SELECT: #{key.join('/')}") unless snapshot_part(path) == @library_snapshots.fetch(key)
      end
      @binary_sha_after = binary_sha
      @helper_sha_after = helper_sha
      fail!('pinned ClickHouse SHA changed during probe') unless @binary_sha_after == BINARY_SHA256
      fail!('prebuilt helper SHA changed during probe') unless @helper_sha_after == @helper_sha_before

      write_evidence(status: 'paired_dynamic_json_physical_composition_observed',
                     source: native, helper: helper[:data], helper_invocation: helper[:record],
                     source_counter_rows: normalized_counter_rows(source_counter_rows),
                     initial_invocation: initial[:record], attached: attached_native,
                     attached_counter_rows: normalized_counter_rows(attached_counter_rows),
                     attached_invocation: attached[:record])
      puts "W210 Dynamic JSON physical composition cases=#{CASE_IDS.size} profiles=#{PROFILE_IDS.size}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @binary_sha_after = binary_sha rescue nil
      @helper_sha_after = helper_sha rescue nil
      write_evidence(status: 'runner_failure_or_observations_differ', fatal_error: @fatal_error) rescue nil
      warn "W210 probe failure (process failure is not format evidence): #{@fatal_error}"
      false
    end

    private

    def fail!(message)
      raise "W210 Dynamic JSON physical witness: #{message}"
    end

    def prepare_layout!
      %w[invocations inputs stores generated].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
      ProbeDynamicJSONPhysicalW210.case_profiles.each do |case_id, profile|
        FileUtils.mkdir_p(File.join(@root, 'generated', case_id, profile), mode: 0o700)
        %w[source library].each do |origin|
          @table_identity[table(case_id, profile, origin)] = [case_id, profile, origin]
        end
      end
    end

    def table(case_id, profile, origin)
      ProbeDynamicJSONPhysicalW210.table(case_id, profile, origin)
    end

    def all_tables
      ProbeDynamicJSONPhysicalW210.case_profiles.flat_map do |case_id, profile|
        %w[source library].map { |origin| table(case_id, profile, origin) }
      end
    end

    def source_tables
      ProbeDynamicJSONPhysicalW210.case_profiles.map { |case_id, profile| table(case_id, profile, 'source') }
    end

    def initial_sql
      statements = [
        'SET flatten_nested=0;',
        'SET allow_suspicious_low_cardinality_types=1;',
        'SET output_format_json_named_tuples_as_objects=1;',
        'SET print_pretty_type_names=0;',
        "SELECT '__W202_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
      ]
      ProbeDynamicJSONPhysicalW210.case_profiles.each do |case_id, profile|
        type = ProbeDynamicJSONPhysicalW210.type_for(case_id)
        [table(case_id, profile, 'source'), table(case_id, profile, 'library')].each do |name|
          statements << "CREATE TABLE default.#{name} (pk UInt64, payload #{type}) ENGINE=MergeTree ORDER BY pk SETTINGS #{SETTINGS}, string_serialization_version='#{profile}';"
        end
        values = ProbeDynamicJSONPhysicalW210.value_sql_rows(case_id).join(",\n")
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
      ProbeDynamicJSONPhysicalW210.case_profiles.each do |case_id, profile|
        target = table(case_id, profile, 'library')
        statements << "ALTER TABLE default.#{target} ATTACH PART 'all_1_1_0';"
        statements << check_sql(table(case_id, profile, 'source'), profile)
        statements << check_sql(target, profile)
      end
      names = all_tables.map { |name| "'#{name}'" }.join(',')
      statements << "SELECT '__W202_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{names}) ORDER BY table, position FORMAT TSVRaw;"
      statements << parts_sql(all_tables)
      all_tables.each { |name| statements.concat(value_queries(name)) }
      statements.join("\n") + "\n"
    end

    def check_sql(table_name, profile)
      ["SELECT '__W202_CHECK_BEGIN__', '#{table_name}', '#{profile}' FORMAT TSVRaw;",
       "CHECK TABLE default.#{table_name} FORMAT TSV;",
       "SELECT '__W202_CHECK_END__', '#{table_name}', '#{profile}' FORMAT TSVRaw;"].join("\n")
    end

    def parts_sql(tables)
      names = tables.map { |name| "'#{name}'" }.join(',')
      "SELECT '__W202_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table IN (#{names}) AND active ORDER BY table,name FORMAT TSVRaw;"
    end

    def value_queries(table_name)
      case_id, profile, = @table_identity.fetch(table_name)
      type_name = ProbeDynamicJSONPhysicalW210.type_for(case_id)
      arm, shared, size = ProbeDynamicJSONPhysicalW210.arm_projection(case_id)
      counter_type, counter_shared = ProbeDynamicJSONPhysicalW210.counter_projection(case_id)
      windows = {
        'FULL' => '', 'FIRST_EMPTY' => ' WHERE pk BETWEEN 1 AND 2',
        'LATER' => ' WHERE pk BETWEEN 3 AND 4', 'FINAL' => ' WHERE pk BETWEEN 5 AND 6',
        'ZERO' => ' WHERE pk > 6',
      }
      windows.flat_map do |window, predicate|
        query = "SELECT '__W202_VALUES_#{window}__', '#{table_name}', toString(pk), hex(toJSONString(payload)), " \
                "toTypeName(payload), #{arm}, #{shared}, #{size} FROM default.#{table_name}#{predicate} " \
                "ORDER BY pk SETTINGS print_pretty_type_names=0 FORMAT TSVRaw;"
        counter_query = "SELECT '__W210_COUNTER_#{window}__', '#{table_name}', toString(pk), #{counter_type}, #{counter_shared} " \
                        "FROM default.#{table_name}#{predicate} ORDER BY pk SETTINGS print_pretty_type_names=0 FORMAT TSVRaw;"
        if window == 'ZERO'
          next ["SELECT '__W202_ZERO_BEGIN__', '#{table_name}', '#{profile}', 'values' FORMAT TSVRaw;",
                query,
                "SELECT '__W202_ZERO_END__', '#{table_name}', '#{profile}', 'values' FORMAT TSVRaw;"]
        end

        [query, counter_query]
      end
    end

    def run_helper(input_path)
      before = helper_sha
      fail!('prebuilt helper changed before invocation') unless before == @helper_sha_before
      argv = [@helper, input_path, File.join(@root, 'generated')]
      invocation = @executor.send(:execute_record, 'crystal_helper', argv, ''.b,
                                  'prebuilt Crystal helper', before, @helper)
      fail!('Crystal helper process failed; not a native format rejection') unless successful?(invocation)
      fail!('Crystal helper emitted diagnostics to stderr') unless invocation[:stderr].empty?
      fail!('Crystal helper changed during invocation') unless helper_sha == before
      lines = invocation[:stdout].lines.map(&:chomp).reject(&:empty?)
      fail!('Crystal helper must emit exactly one JSON record') unless lines.size == 1
      data = JSON.parse(lines.fetch(0))
      fail!('Crystal helper output format differs') unless data['format'] == FORMAT_OUTPUT
      @invocations << invocation[:record]
      {data: data, record: invocation[:record]}
    end

    def expected_native_rows(case_id, window)
      all = ProbeDynamicJSONPhysicalW210::ROWS.fetch(case_id)
      values = case window
               when 'FULL' then all
               when 'FIRST_EMPTY' then all[0, 2]
               when 'LATER' then all[2, 2]
               when 'FINAL' then all[4, 2]
               when 'ZERO' then []
               else raise "unknown W210 window #{window.inspect}"
               end
      values.each_with_index.map do |value, index|
        pk = case window
             when 'FULL' then index + 1
             when 'FIRST_EMPTY' then index + 1
             when 'LATER' then index + 3
             when 'FINAL' then index + 5
             else raise "unexpected W210 nonempty window #{window.inspect}"
             end
        if case_id == 'root_dynamic'
          json_value = value
          type_name = json_value.is_a?(Hash) ? JSON_USED : UINT8
          [pk.to_s, value, ProbeDynamicJSONPhysicalW210.type_for(case_id), type_name, '0', '1']
        else
          json_value = value
          type_names = json_value.map { |item| item.is_a?(Hash) ? JSON_USED : UINT8 }
          shared = json_value.map { '0' }.join(',')
          [pk.to_s, json_value, ProbeDynamicJSONPhysicalW210.type_for(case_id), type_names.join(','), shared, json_value.size.to_s]
        end
      end
    end

    def decode_hex_json(hex, label)
      fail!("malformed JSON hex for #{label}") unless hex.match?(/\A(?:[0-9A-Fa-f]{2})*\z/)
      JSON.parse([hex].pack('H*'))
    rescue JSON::ParserError => error
      raise "W210 invalid JSON value for #{label}: #{error.message}"
    end

    def parse_counter_rows(stdout)
      rows = {}
      stdout.dup.force_encoding(Encoding::UTF_8).lines.each do |line|
        next unless line.start_with?('__W210_COUNTER_')
        fields = line.chomp.split("\t", -1)
        fail!('counter evidence row has wrong width') unless fields.size == 5
        match = /\A__W210_COUNTER_(FULL|FIRST_EMPTY|LATER|FINAL)__\z/.match(fields[0])
        fail!('counter evidence window marker is malformed') unless match
        table_name = fields[1]
        fail!('counter evidence names an unknown table') unless @table_identity.key?(table_name)
        key = [table_name, match[1]]
        (rows[key] ||= []) << fields.drop(2)
      end
      rows
    end

    def assert_counter_evidence!(stdout, tables)
      actual = parse_counter_rows(stdout)
      windows = WINDOWS.reject { |window| window == 'ZERO' }
      expected = tables.flat_map do |table_name|
        case_id, = @table_identity.fetch(table_name)
        windows.map do |window|
          [[table_name, window], ProbeDynamicJSONPhysicalW210.counter_sql_rows(case_id, window)]
        end
      end.to_h
      fail!('nested counter evidence query roster differs') unless actual.keys.sort == expected.keys.sort
      expected.each do |key, rows|
        fail!("#{key.join('/')} nested counter type/shared evidence differs: #{actual.fetch(key).inspect}") unless actual.fetch(key) == rows
      end
      actual
    end

    def normalized_counter_rows(rows)
      rows.sort_by { |(table_name, window), _| [table_name, window] }.map do |(table_name, window), values|
        {'table' => table_name, 'window' => window, 'rows' => values}
      end
    end

    def assert_value_windows!(native, table_name)
      case_id, = @table_identity.fetch(table_name)
      WINDOWS.each do |window|
        actual = native[:value_rows].fetch([table_name, window], [])
        next if window == 'ZERO'
        expected = expected_native_rows(case_id, window)
        decoded = actual.map do |fields|
          [fields[0], decode_hex_json(fields[1], "#{table_name}/#{window}"), *fields.drop(2)]
        end
        fail!("#{table_name}/#{window} native values or actual JSON-arm type differ: #{decoded.inspect}") unless decoded == expected
      end
    end

    def assert_initial_native!(native)
      source = source_tables
      expected_checks = source.to_h do |name|
        _case_id, profile, = @table_identity.fetch(name)
        [[name, profile], ["all_1_1_0\t1\t"]]
      end
      fail!('source CHECK result differs') unless native[:checks] == expected_checks
      expected_schema = all_tables.sort.flat_map do |name|
        case_id, = @table_identity.fetch(name)
        [[name, 'pk', 'UInt64'], [name, 'payload', ProbeDynamicJSONPhysicalW210.type_for(case_id)]]
      end
      fail!('nominal source/empty-library schema differs') unless native[:schemas] == expected_schema
      fail!('native table data-path roster differs') unless native[:data_paths].keys.sort == all_tables.sort
      native[:data_paths].each_value { |path| validate_store_path!(path) }
      @data_paths = native[:data_paths].dup
      fail!('source part roster differs') unless native[:parts].keys.sort == source.sort
      expected_windows = source.product(WINDOWS.reject { |window| window == 'ZERO' }).sort
      fail!('stock selected-value query roster differs') unless native[:value_rows].keys.sort == expected_windows
      source.each do |name|
        part = native[:parts].fetch(name)
        fail!("#{name} is not one six-row Wide part with three marks plus sentinel") unless
          part[:name] == 'all_1_1_0' && part[:type] == 'Wide' && part[:rows] == '6' && part[:marks] == '4'
        path = validate_source_part!(part[:path])
        @source_parts[name] = path
        @source_snapshots[name] = snapshot_part(path)
        assert_value_windows!(native, name)
      end
    end

    def assert_attached_native!(native)
      fail!('attached CHECK block roster differs') unless native[:checks].keys.sort == all_tables.map { |name| [name, @table_identity.fetch(name)[1]] }.sort
      all_tables.each do |name|
        profile = @table_identity.fetch(name)[1]
        fail!("CHECK result differs for #{name}") unless native[:checks][[name, profile]] == ["all_1_1_0\t1\t"]
      end
      expected_schema = all_tables.sort.flat_map do |name|
        case_id, = @table_identity.fetch(name)
        [[name, 'pk', 'UInt64'], [name, 'payload', ProbeDynamicJSONPhysicalW210.type_for(case_id)]]
      end
      fail!('attached nominal schema differs') unless native[:schemas] == expected_schema
      fail!('attached part roster differs') unless native[:parts].keys.sort == all_tables.sort
      expected_windows = all_tables.product(WINDOWS.reject { |window| window == 'ZERO' }).sort
      fail!('attached value-query roster differs') unless native[:value_rows].keys.sort == expected_windows
      expected_zero = all_tables.flat_map do |name|
        profile = @table_identity.fetch(name)[1]
        [["__W202_ZERO_BEGIN__", name, profile, 'values'], ["__W202_ZERO_END__", name, profile, 'values']]
      end
      fail!('zero-selection boundary roster differs') unless native[:zero_events] == expected_zero
      all_tables.each do |name|
        part = native[:parts].fetch(name)
        fail!("#{name} attached part identity/grid differs") unless
          part[:name] == 'all_1_1_0' && part[:type] == 'Wide' && part[:rows] == '6' && part[:marks] == '4'
        assert_value_windows!(native, name)
      end
    end

    def build_helper_input
      capture_root = File.realpath(File.join(@root, 'stores', 'native'))
      cases = ProbeDynamicJSONPhysicalW210.case_profiles.map do |case_id, profile|
        {
          'case_id' => case_id,
          'profile_id' => profile,
          'capture_root' => capture_root,
          'source_part' => @source_parts.fetch(table(case_id, profile, 'source')),
          'library_part' => File.join(@root, 'generated', case_id, profile, 'all_1_1_0'),
        }
      end
      {'format' => FORMAT_INPUT, 'capture_root' => capture_root, 'cases' => cases}
    end

    def parse_manifest(path, label)
      manifest = File.join(path, 'columns_substreams.txt')
      stat = File.lstat(manifest)
      fail!("#{label} columns_substreams is not a bounded regular file") unless stat.file? && !stat.symlink? && stat.size <= MAX_COLUMNS_SUBSTREAMS_BYTES
      lines = File.binread(manifest, MAX_COLUMNS_SUBSTREAMS_BYTES + 1).force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      fail!("#{label} columns_substreams header differs") unless lines.shift == 'columns substreams version: 1'
      count_match = /\A([1-9][0-9]*) columns:\z/.match(lines.shift.to_s)
      fail!("#{label} columns_substreams column count is malformed") unless count_match
      columns = {}
      until lines.empty?
        header = lines.shift
        match = /\A([1-9][0-9]*) substreams for column `([^`]+)`:\z/.match(header.to_s)
        fail!("#{label} columns_substreams block is malformed") unless match
        count = Integer(match[1], 10)
        name = match[2]
        fail!("#{label} columns_substreams repeats a column") if columns.key?(name)
        fail!("#{label} columns_substreams block is truncated") if lines.size < count
        values = lines.shift(count).map do |line|
          name_match = /\A\t([^\t\r\n]+)\z/.match(line)
          fail!("#{label} substream line is malformed") unless name_match
          name_match[1]
        end
        fail!("#{label} substream names repeat") unless values.uniq == values
        columns[name] = values
      end
      fail!("#{label} declared column count differs") unless columns.size == Integer(count_match[1], 10)
      fail!("#{label} column roster differs") unless columns.keys.sort == %w[payload pk]
      fail!("#{label} primary-key substream differs") unless columns.fetch('pk') == ['pk']
      columns
    end

    def mark_rows(bytes, label)
      record_size = 24
      fail!("#{label} .mrk2 has a partial record") unless (bytes.bytesize % record_size).zero?
      bytes.bytes.each_slice(record_size).map do |record|
        record[16, 8].pack('C*').unpack1('Q<')
      end
    end

    def assert_part_roster!(path, side, case_id, profile, origin)
      validate_plain_tree!(path)
      columns = parse_manifest(path, "#{case_id}/#{profile}/#{origin}")
      names = columns.fetch('payload').sort
      fail!("#{case_id}/#{profile}/#{origin} physical names disagree with part metadata") unless names == side.fetch('physical_stream_names')
      root_used = ProbeDynamicJSONPhysicalW210.arm_prefix(case_id, JSON_USED)
      root_unused = ProbeDynamicJSONPhysicalW210.arm_prefix(case_id, JSON_UNUSED)
      expected_children = ProbeDynamicJSONPhysicalW210.object_child_names(case_id, profile, JSON_USED)
      if origin == 'library'
        expected_children += ProbeDynamicJSONPhysicalW210.object_child_names(case_id, profile, JSON_UNUSED)
        fail!("#{case_id}/#{profile} persisted binding names differ") unless side.fetch('bound_json_type_names').sort == [JSON_USED, JSON_UNUSED].sort
      end
      expected_children.sort!
      actual_children = side.fetch('object_child_stream_names').sort
      fail!("#{case_id}/#{profile}/#{origin} helper Object child roster differs from literal profile/level roster") unless actual_children == expected_children
      manifest_children = names.select do |name|
        name.start_with?(root_used + '.') || (origin == 'library' && name.start_with?(root_unused + '.'))
      end.sort
      fail!("#{case_id}/#{profile}/#{origin} manifest Object child roster differs from literal profile/level roster") unless manifest_children == expected_children

      stream_files = Dir.children(path).select { |name| name.end_with?('.bin') || name.end_with?('.mrk2') }
      fail!("#{case_id}/#{profile}/#{origin} has malformed stream filenames") unless stream_files.all? { |name| /\A[0-9a-f]{32}\.(?:bin|mrk2)\z/.match?(name) }
      binaries = stream_files.select { |name| name.end_with?('.bin') }.map { |name| name.delete_suffix('.bin') }.sort
      marks = stream_files.select { |name| name.end_with?('.mrk2') }.map { |name| name.delete_suffix('.mrk2') }.sort
      expected_hashes = (names + ['pk']).map { |name| W183.stream_hash(name) }.sort
      fail!("#{case_id}/#{profile}/#{origin} literal stream-name hashes collide") unless expected_hashes.uniq == expected_hashes
      fail!("#{case_id}/#{profile}/#{origin} stream file/checksum names do not map from physical streams") unless
        binaries == expected_hashes && marks == expected_hashes
      # The column reader selects payload streams, not the independent pk
      # column. The whole-part file audit above includes both columns.
      payload_hashes = names.map { |name| W183.stream_hash(name) }
      expected_checksum_files = payload_hashes.flat_map { |hash| ["#{hash}.bin", "#{hash}.mrk2"] }.sort
      fail!("#{case_id}/#{profile}/#{origin} helper checksum roster differs from literal stream hashes") unless
        side.fetch('selected_checksum_names').sort == expected_checksum_files
      mark_files = stream_files.select { |name| name.end_with?('.mrk2') }
      mark_files.each do |name|
        rows = mark_rows(File.binread(File.join(path, name)), "#{case_id}/#{profile}/#{origin}/#{name}")
        fail!("#{case_id}/#{profile}/#{origin} .mrk2 third-word physical P differs") unless rows == OBJECT_CHILD_MARK_ROWS
      end
      @part_rosters[[case_id, profile, origin].join('/')] = {
        payload_substreams: names, mark_row_words: mark_files.to_h { |name| [name, mark_rows(File.binread(File.join(path, name)), name)] },
      }
    end

    def assert_helper_output!(data)
      expected_keys = %w[case_ids cases format object_child_mark_rows parent_mark_rows profile_ids]
      fail!('helper root output keys/format differ') unless data.keys.sort == expected_keys && data['format'] == FORMAT_OUTPUT
      fail!('helper fixed case/profile roster differs') unless data['case_ids'] == CASE_IDS && data['profile_ids'] == PROFILE_IDS
      fail!('helper independent P vectors differ') unless data['parent_mark_rows'] == PARENT_MARK_ROWS && data['object_child_mark_rows'] == OBJECT_CHILD_MARK_ROWS
      expected_pairs = ProbeDynamicJSONPhysicalW210.case_profiles
      observed_pairs = data.fetch('cases').map { |item| [item.fetch('case_id'), item.fetch('profile_id')] }
      fail!('helper case/profile ordering differs') unless observed_pairs == expected_pairs
      expected_rows = {
        'root_dynamic' => [['u8:17', 'u8:18'], ['u8:19', 'u8:20'], ['json:41:null:counter=401', 'json:42:null:counter=402']],
        'array_dynamic' => [['[]', '[]'], ['[u8:17,u8:18]', '[u8:19]'], ['[json:41:null:counter=401]', '[json:42:null:counter=402]']],
      }
      data.fetch('cases').each do |item|
        case_id = item.fetch('case_id')
        profile = item.fetch('profile_id')
        fail!('helper case object keys differ') unless item.keys.sort == %w[case_id library library_part_path profile_id source]
        %w[source library].each do |origin|
          side = item.fetch(origin)
          required = %w[bound_json_type_names case_id mark_count mark_row_counts object_child_stream_names physical_stream_names profile_id row_count rows_by_mark schema_declaration selected_checksum_names windows]
          fail!("#{case_id}/#{profile}/#{origin} helper side keys differ") unless side.keys.sort == required
          fail!("#{case_id}/#{profile}/#{origin} helper shape differs") unless
            side['case_id'] == case_id && side['profile_id'] == profile && side['schema_declaration'] == ProbeDynamicJSONPhysicalW210.type_for(case_id) &&
            side['row_count'] == 6 && side['mark_count'] == 3 && side['mark_row_counts'] == PARENT_MARK_ROWS &&
            side['windows'] == %w[full first_empty_or_first middle final eof_zero] && side['rows_by_mark'] == expected_rows.fetch(case_id)
          fail!("#{case_id}/#{profile}/#{origin} physical/checksum names are malformed") unless
            side['physical_stream_names'].is_a?(Array) && !side['physical_stream_names'].empty? && side['physical_stream_names'].uniq == side['physical_stream_names'] &&
            side['selected_checksum_names'].is_a?(Array) && side['selected_checksum_names'].uniq == side['selected_checksum_names']
          path = origin == 'source' ? @source_parts.fetch(table(case_id, profile, origin)) : File.join(@root, 'generated', case_id, profile, 'all_1_1_0')
          assert_part_roster!(path, side, case_id, profile, origin)
        end
        expected_path = File.join(@root, 'generated', case_id, profile, 'all_1_1_0')
        fail!('library output path differs from fixed destination') unless File.expand_path(item.fetch('library_part_path')) == expected_path
        key = [case_id, profile]
        @library_parts[key] = expected_path
        @library_snapshots[key] = snapshot_part(expected_path)
      end
    end

    def attach_library_parts!
      ProbeDynamicJSONPhysicalW210.case_profiles.each do |case_id, profile|
        target = table(case_id, profile, 'library')
        path = @library_parts.fetch([case_id, profile])
        expected = File.join(@root, 'generated', case_id, profile, 'all_1_1_0')
        fail!('generated part path differs from fixed destination') unless File.expand_path(path) == expected
        validate_plain_tree!(expected)
        @executor.send(:attach_part!, expected, validate_store_path!(@data_paths.fetch(target)))
      end
    end

    def write_evidence(data)
      summary = {
        probe: 'W210 paired Dynamic JSON physical composition', status: data[:status], fatal_error: data[:fatal_error],
        runtime: {path: @binary, expected_sha256: BINARY_SHA256, sha256_before: @binary_sha_before,
                  sha256_after: @binary_sha_after, expected_version: VERSION, expected_version_git_hash: BUILD},
        helper: {path: @helper, sha256_before: @helper_sha_before, sha256_after: @helper_sha_after},
        helper_input: @helper_input, part_rosters: @part_rosters,
        limits: {max_threads: 1, local_max_memory_usage_bytes: MEMORY, required_outer_run_safe_memory_limit_bytes: OUTER_RUN_SAFE_LIMIT,
                 timeout_seconds: TIMEOUT, termination_grace_seconds: GRACE, executor: 'JsonBinaryKernelW180Probe#execute'},
        cases: CASE_IDS, profiles: PROFILE_IDS, evidence_root: @root, invocations: @invocations,
      }.merge(data.reject { |key, _| %i[status fatal_error].include?(key) })
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      write_new(File.join(@root, 'summary.md'), [
        '# W210 paired Dynamic JSON physical composition', '',
        "Status: `#{summary[:status]}`", '',
        'Scope: root Dynamic and Array(Dynamic), each with one six-row Wide part across both String profiles. The Array fixture has parent P=[2,2,2], Dynamic-site Q=[0,3,2], and selected-JSON R=[0,0,2]; library output additionally persists a bound-but-unused JSON arm. Native ATTACH/CHECK, literal values/actual types, and nested counter Int64/nonshared rows are the external compatibility witness; helper reads and checksums are supplementary.', '',
        "Runtime: #{VERSION} / VERSION_GITHASH #{BUILD} / SHA256 `#{BINARY_SHA256}`", '',
        "Evidence root: `#{@root}`", '',
      ].join("\n"))
    end
  end

  def self.self_test!
    assert(CASE_IDS == %w[root_dynamic array_dynamic] && PROFILE_IDS == %w[single_stream with_size_stream], 'case/profile roster changed')
    assert(ROWS.fetch('array_dynamic')[0, 2] == [[], []], 'Array Q=0 leading mark changed')
    assert(ROWS.fetch('array_dynamic')[2, 2].map(&:size) == [2, 1], 'Array Q=3 middle mark changed')
    assert(ROWS.fetch('array_dynamic')[4, 2].map(&:size) == [1, 1], 'Array JSON R=2 final mark changed')
    assert(PARENT_MARK_ROWS == [2, 1 + 1, 2] && OBJECT_CHILD_MARK_ROWS == [2, 2, 2, 0], 'physical P oracle changed')
    expected_json_prefix = 'payload.JSON%28max_dynamic_types%3D1%2C%20max_dynamic_paths%3D1%2C%20id%20UInt8%2C%20maybe%20Nullable%28UInt8%29%29'
    array_json_prefix = arm_prefix('array_dynamic', JSON_USED)
    assert(array_json_prefix == expected_json_prefix && array_json_prefix == arm_prefix('root_dynamic', JSON_USED) && !array_json_prefix.include?('.elements'), 'Array physical JSON arm prefix or escaping changed')
    invalid_case_rejected = begin
      arm_prefix('unknown_case', JSON_USED)
      false
    rescue ArgumentError
      true
    end
    assert(invalid_case_rejected, 'unknown Dynamic JSON case was accepted')
    assert(OBJECT_CHILD_SUFFIXES.fetch(['single_stream', 0]).size == 11, 'single-stream root Object child roster changed')
    assert(OBJECT_CHILD_SUFFIXES.fetch(['single_stream', 1]).include?('.object_shared_data.size1'), 'Array inherited level did not select size1')
    assert(OBJECT_CHILD_SUFFIXES.fetch(['with_size_stream', 0]).include?('.counter.SharedVariant.size'), 'String profile omitted Dynamic size lane')
    assert(OBJECT_CHILD_SUFFIXES.fetch(['with_size_stream', 1]).size == 12, 'with-size Array Object child roster changed')
    assert(OBJECT_CHILD_SUFFIXES.values.all? { |suffixes| !suffixes.include?('.object_shared_data%2Epaths.size') && !suffixes.include?('.object_shared_data%2Evalues.size') }, 'Object MAP paths/values unexpectedly have size lanes')
    single_stream_suffixes = OBJECT_CHILD_SUFFIXES.select { |key, _| key[0] == 'single_stream' }.values
    with_size_suffixes = OBJECT_CHILD_SUFFIXES.select { |key, _| key[0] == 'with_size_stream' }.values
    assert(single_stream_suffixes.all? { |suffixes| suffixes.include?('.counter.SharedVariant') && !suffixes.include?('.counter.SharedVariant.size') }, 'single-stream Object child unexpectedly has Dynamic size lane')
    assert(with_size_suffixes.all? { |suffixes| suffixes.include?('.counter.SharedVariant') && suffixes.include?('.counter.SharedVariant.size') }, 'with-size Object children omitted Dynamic size lane')
    assert(OBJECT_CHILD_SUFFIXES.values.all? { |suffixes| suffixes.include?('.counter.Int64') && !suffixes.include?('.counter.UInt64') }, 'Object child counter Int64 suffix oracle changed')
    assert(counter_sql_rows('root_dynamic', 'FINAL') == [['5', 'Int64', '0'], ['6', 'Int64', '0']], 'root JSON counter Int64 literal oracle changed')
    assert(counter_sql_rows('array_dynamic', 'FINAL') == [['5', 'Int64', '0'], ['6', 'Int64', '0']], 'Array JSON counter Int64 literal oracle changed')
    assert(counter_sql_rows('array_dynamic', 'FIRST_EMPTY') == [['1', '', ''], ['2', '', '']], 'empty Array counter placeholder oracle changed')
    assert(counter_sql_rows('array_dynamic', 'LATER') == [['3', '-,-', '-,-'], ['4', '-', '-']], 'ordinary Array counter placeholders changed')
    assert(value_sql('array_dynamic', []) == "CAST([], '#{ARRAY_DYNAMIC}')", 'empty Array SQL is not explicitly typed')
    assert(value_sql('root_dynamic', 17) == "CAST(toUInt8(17), '#{DYNAMIC}')", 'root Dynamic ordinary literal changed')
    puts 'W210 Ruby fixture self-test passed'
    exit 0
  end

  if $PROGRAM_NAME == __FILE__
    if ARGV == ['--self-test']
      self_test!
    else
      options = {binary: BINARY, helper: nil, root: nil}
      OptionParser.new do |parser|
        parser.banner = 'Usage: ruby scripts/probe_dynamic_json_physical_w210.rb --crystal-helper PREBUILT --evidence-root EMPTY_/private/tmp_CHILD [--clickhouse PINNED]'
        parser.on('--clickhouse PATH', 'Pinned ClickHouse executable') { |value| options[:binary] = value }
        parser.on('--crystal-helper PATH', 'Prebuilt Crystal helper; this runner never compiles it') { |value| options[:helper] = value }
        parser.on('--evidence-root PATH', 'Existing empty direct child of /private/tmp') { |value| options[:root] = value }
      end.parse!
      abort 'W210: --crystal-helper and --evidence-root are required' unless options[:helper] && options[:root]
      exit(Probe.new(options[:binary], options[:helper], options[:root]).run ? 0 : 1)
    end
  end
end
