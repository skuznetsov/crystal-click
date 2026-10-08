#!/usr/bin/env ruby
# Bounded stock/library SharedVariant inline-JSON witness. The runner consumes
# only the pinned ClickHouse binary and a prebuilt Crystal helper; it never
# builds either implementation.

require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require_relative 'probe_nested_bulk_part_w202'

module ProbeDynamicSharedJSONW213
  W202 = ProbeNestedBulkPartW202
  BINARY = W202::BINARY
  BINARY_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  VERSION = '26.10.1.1201'.freeze
  BUILD = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  SOURCE_REVISION = '0ca8150d9b1d0886edb2e3b4ab65eebb768d0357'.freeze

  FORMAT_INPUT = 'dynamic_shared_json_w213_input_v1'.freeze
  FORMAT_OUTPUT = 'dynamic_shared_json_w213_helper_v1'.freeze
  CASE_IDS = %w[root_json root_array_json root_tuple_json array_dynamic_array_json].freeze
  PROFILE_IDS = %w[single_stream with_size_stream].freeze
  WINDOWS = %w[FULL FIRST_EMPTY LATER FINAL ZERO].freeze

  DYNAMIC = 'Dynamic(max_types=0)'.freeze
  JSON_USED = 'JSON(max_dynamic_types=1, max_dynamic_paths=1, id UInt8, maybe Nullable(UInt8))'.freeze
  ARRAY_JSON = "Array(#{JSON_USED})".freeze
  TUPLE_JSON = "Tuple(#{JSON_USED}, #{JSON_USED})".freeze
  ARRAY_DYNAMIC = "Array(#{DYNAMIC})".freeze
  PARENT_MARK_ROWS = [2, 2, 2, 2].freeze
  PARENT_MARK_THIRD_WORDS = [2, 2, 2, 2, 0].freeze
  OUTER_OCCURRENCE_COUNTS = [2, 3, 3, 5].freeze

  SETTINGS = [
    'index_granularity=2', 'index_granularity_bytes=10485760',
    'enable_mixed_granularity_parts=1', 'min_rows_for_wide_part=0',
    'min_bytes_for_wide_part=0', 'compress_marks=0', 'compress_primary_key=0',
    'min_compress_block_size=0', 'max_compress_block_size=4096',
    "default_compression_codec='LZ4'", "serialization_info_version='with_types'",
    'propagate_types_serialization_versions_to_nested_types=1',
    'use_compact_variant_discriminators_serialization=0',
    "dynamic_serialization_version='v3'", "object_serialization_version='v3'",
    "object_shared_data_serialization_version_for_zero_level_parts='map'",
    "map_serialization_version='basic'", "map_serialization_version_for_zero_level_parts='basic'",
  ].join(', ').freeze

  # Independent eight-row stock literals, two rows per parent mark. Typed
  # JSON fields are id UInt8 and maybe Nullable(UInt8)=NULL; counter is an
  # untyped Int64 JSON path. Dynamic max_types=0 makes every non-NULL actual a
  # SharedVariant value, but NULL remains discriminator 255.
  ROWS = {
    'root_json' => [
      {kind: :null}, {kind: :null},
      {kind: :json, id: 31}, {kind: :json, id: 32},
      {kind: :json, id: 33}, {kind: :json, id: 34},
      {kind: :json, id: 35}, {kind: :json, id: 36},
    ].freeze,
    'root_array_json' => [
      {kind: :null}, {kind: :null},
      {kind: :array_json, ids: []}, {kind: :array_json, ids: [41]},
      {kind: :array_json, ids: [42, 43]}, {kind: :array_json, ids: [44]},
      {kind: :array_json, ids: [45]}, {kind: :array_json, ids: [46, 47]},
    ].freeze,
    'root_tuple_json' => [
      {kind: :null}, {kind: :null},
      {kind: :tuple_json, ids: [51, 52]}, {kind: :tuple_json, ids: [53, 54]},
      {kind: :tuple_json, ids: [55, 56]}, {kind: :tuple_json, ids: [57, 58]},
      {kind: :tuple_json, ids: [59, 60]}, {kind: :tuple_json, ids: [61, 62]},
    ].freeze,
    'array_dynamic_array_json' => [
      {kind: :outer, values: [[:array_json, []]]},
      {kind: :outer, values: [[:array_json, []]]},
      {kind: :outer, values: [[:null, nil], [:array_json, [81]]]},
      {kind: :outer, values: [[:array_json, [82, 83]]]},
      {kind: :outer, values: [[:array_json, []], [:array_json, [84]]]},
      {kind: :outer, values: [[:array_json, [85, 86]]]},
      {kind: :outer, values: [[:array_json, [86]], [:array_json, []], [:array_json, [87]]]},
      {kind: :outer, values: [[:array_json, [88]], [:array_json, [89]]]},
    ].freeze,
  }.freeze

  # Independent literal SharedVariant wire descriptor. JSON row path ordering
  # is checked semantically because stock may choose a different path order.
  JSON_DESCRIPTOR = [
    0x30, 0x00, 0x01, 0x01, 0x02,
    0x02, 0x69, 0x64, 0x01,
    0x05, 0x6d, 0x61, 0x79, 0x62, 0x65, 0x23, 0x01,
    0x00, 0x00,
  ].pack('C*').b.freeze

  class Probe < W202::Probe
    def initialize(binary, crystal_helper, evidence_root)
      super(binary, crystal_helper, evidence_root)
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

      initial = run_clickhouse('native_sources', initial_sql)
      assert_native_invocation!(initial)
      native = parse_native(initial[:stdout])
      assert_pin!(native)
      assert_initial_native!(native)

      input_path = File.join(@root, 'generated', 'helper-input.json')
      input_bytes = JSON.pretty_generate(build_helper_input) + "\n"
      write_new(input_path, input_bytes)
      @helper_input = {path: input_path, bytes: input_bytes.bytesize,
                       sha256: Digest::SHA256.hexdigest(input_bytes)}
      helper = run_helper(input_path)
      assert_helper_output!(helper[:data])
      attach_library_parts!

      attached = run_clickhouse('attach_and_check', attached_sql)
      assert_native_invocation!(attached)
      attached_native = parse_native(attached[:stdout])
      assert_pin!(attached_native)
      assert_attached_native!(attached_native)

      @source_parts.each do |name, path|
        fail!("stock source part changed during ATTACH/SELECT: #{name}") unless
          snapshot_part(path) == @source_snapshots.fetch(name)
      end
      @library_parts.each do |key, path|
        fail!("published library part changed during ATTACH/SELECT: #{key.join('/')}") unless
          snapshot_part(path) == @library_snapshots.fetch(key)
      end
      @binary_sha_after = binary_sha
      @helper_sha_after = helper_sha
      fail!('pinned ClickHouse executable SHA changed during probe') unless @binary_sha_after == BINARY_SHA256
      fail!('prebuilt Crystal helper SHA changed during probe') unless @helper_sha_after == @helper_sha_before

      write_evidence(
        status: 'paired_shared_variant_inline_json_native_witness_observed',
        source: native, helper: helper[:data], helper_invocation: helper[:record],
        initial_invocation: initial[:record], attached: attached_native,
        attached_invocation: attached[:record], source_part_snapshots: @source_snapshots,
        library_part_snapshots: @library_snapshots, part_rosters: @part_rosters,
      )
      puts "W213 paired SharedVariant inline JSON cases=#{CASE_IDS.size} profiles=#{PROFILE_IDS.size}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @binary_sha_after = binary_sha rescue nil
      @helper_sha_after = helper_sha rescue nil
      write_evidence(status: 'runner_failure_or_observations_differ', fatal_error: @fatal_error) rescue nil
      warn "W213 probe failure (process failure is not format evidence): #{@fatal_error}"
      false
    end

    private

    def prepare_layout!
      super
      case_profiles.each do |case_id, profile|
        FileUtils.mkdir_p(File.join(@root, 'generated', case_id, profile), mode: 0o700)
        %w[source library].each do |origin|
          name = table(case_id, profile, origin)
          @table_identity[name] = [case_id, profile, origin]
        end
      end
    end

    def binary_sha
      Digest::SHA256.file(@binary).hexdigest
    end

    def helper_sha
      Digest::SHA256.file(@helper).hexdigest
    end

    def case_profiles
      CASE_IDS.flat_map { |case_id| PROFILE_IDS.map { |profile| [case_id, profile] } }
    end

    def table(case_id, profile, origin)
      "#{origin}_#{case_id}_#{profile}"
    end

    def all_tables
      case_profiles.flat_map { |case_id, profile| %w[source library].map { |origin| table(case_id, profile, origin) } }
    end

    def source_tables
      case_profiles.map { |case_id, profile| table(case_id, profile, 'source') }
    end

    def type_for(case_id)
      case_id == 'array_dynamic_array_json' ? ARRAY_DYNAMIC : DYNAMIC
    end

    def sql_quote(value)
      "'#{value.to_s.gsub(/[\\']/) { |character| "\\#{character}" }}'"
    end

    def json_sql(id)
      raw = JSON.generate({'id' => id, 'maybe' => nil, 'counter' => id * 10 + 1})
      "CAST(#{sql_quote(raw)}, '#{JSON_USED}')"
    end

    def dynamic_sql(expression)
      "CAST(#{expression}, '#{DYNAMIC}')"
    end

    def value_sql(case_id, row)
      case case_id
      when 'root_json'
        row[:kind] == :null ? dynamic_sql('NULL') : dynamic_sql(json_sql(row.fetch(:id)))
      when 'root_array_json'
        if row[:kind] == :null
          dynamic_sql('NULL')
        else
          children = row.fetch(:ids).map { |id| json_sql(id) }
          dynamic_sql("CAST([#{children.join(', ')}], '#{ARRAY_JSON}')")
        end
      when 'root_tuple_json'
        if row[:kind] == :null
          dynamic_sql('NULL')
        else
          children = row.fetch(:ids).map { |id| json_sql(id) }
          dynamic_sql("CAST(tuple(#{children.join(', ')}), '#{TUPLE_JSON}')")
        end
      when 'array_dynamic_array_json'
        children = row.fetch(:values).map do |arm, ids|
          if arm == :null
            dynamic_sql('NULL')
          else
            docs = ids.map { |id| json_sql(id) }
            dynamic_sql("CAST([#{docs.join(', ')}], '#{ARRAY_JSON}')")
          end
        end
        "CAST([#{children.join(', ')}], '#{ARRAY_DYNAMIC}')"
      else
        fail!("unrostered W213 SQL family #{case_id.inspect}")
      end
    end

    def initial_sql
      statements = [
        'SET flatten_nested=0;',
        'SET allow_suspicious_low_cardinality_types=1;',
        'SET output_format_json_named_tuples_as_objects=1;',
        'SET print_pretty_type_names=0;',
        "SELECT '__W202_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
      ]
      case_profiles.each do |case_id, profile|
        settings = "#{SETTINGS}, string_serialization_version='#{profile}'"
        %w[source library].each do |origin|
          name = table(case_id, profile, origin)
          statements << "CREATE TABLE default.#{name} (pk UInt64, payload #{type_for(case_id)}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings};"
        end
      end
      source_tables.each do |name|
        case_id, profile, = @table_identity.fetch(name)
        values = ROWS.fetch(case_id).each_with_index.map do |row, index|
          "(#{index + 1}, #{value_sql(case_id, row)})"
        end
        statements << "INSERT INTO default.#{name} VALUES\n#{values.join(",\n")};"
        statements << check_sql(name, profile)
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
      case_profiles.each do |case_id, profile|
        target = table(case_id, profile, 'library')
        statements << "ALTER TABLE default.#{target} ATTACH PART 'all_1_1_0';"
        statements << check_sql(target, profile)
      end
      names = all_tables.map { |name| "'#{name}'" }.join(',')
      statements << "SELECT '__W202_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{names}) ORDER BY table, position FORMAT TSVRaw;"
      statements << parts_sql(all_tables)
      all_tables.each { |name| statements.concat(value_queries(name)) }
      statements.join("\n") + "\n"
    end

    def projection_for(case_id)
      if case_id == 'array_dynamic_array_json'
        [
          "arrayStringConcat(arrayMap(x -> if(isNull(x), 'NULL', dynamicType(x)), payload), ',')",
          "arrayStringConcat(arrayMap(x -> toString(toUInt8(isDynamicElementInSharedData(x))), payload), ',')",
          'toString(length(payload))',
        ]
      else
        [
          "if(isNull(payload), 'NULL', dynamicType(payload))",
          'toString(toUInt8(isDynamicElementInSharedData(payload)))',
          "'1'",
        ]
      end
    end

    def json_value_hex_expression(case_id)
      if case_id == 'array_dynamic_array_json'
        'hex(toJSONString(payload))'
      else
        "if(isNull(payload), '6E756C6C', hex(toJSONString(payload)))"
      end
    end

    def value_queries(table_name)
      case_id, profile, = @table_identity.fetch(table_name)
      windows = {
        'FULL' => '', 'FIRST_EMPTY' => ' WHERE pk BETWEEN 1 AND 2',
        'LATER' => ' WHERE pk BETWEEN 3 AND 4', 'FINAL' => ' WHERE pk BETWEEN 7 AND 8',
        'ZERO' => ' WHERE pk > 8',
      }
      actual, shared, size = projection_for(case_id)
      value_hex = json_value_hex_expression(case_id)
      windows.flat_map do |window, predicate|
        query = "SELECT '__W202_VALUES_#{window}__', '#{table_name}', toString(pk), #{value_hex}, " \
                "toTypeName(payload), #{actual}, #{shared}, #{size} FROM default.#{table_name}#{predicate} " \
                "ORDER BY pk SETTINGS print_pretty_type_names=0 FORMAT TSVRaw;"
        if window == 'ZERO'
          ["SELECT '__W202_ZERO_BEGIN__', '#{table_name}', '#{profile}', 'values' FORMAT TSVRaw;",
           query,
           "SELECT '__W202_ZERO_END__', '#{table_name}', '#{profile}', 'values' FORMAT TSVRaw;"]
        else
          [query]
        end
      end
    end

    def run_clickhouse(label, sql)
      sql_bytes = sql.b
      send(:write_new, File.join(@root, 'invocations', "#{label}.stdin.sql"), sql_bytes)
      argv = [@binary, 'local', '--path', File.join(@root, 'stores', 'native'), '--session_timezone=UTC',
              '--max_threads=1', "--max_memory_usage=#{W202::MEMORY}", '--multiquery']
      before = binary_sha
      fail!('pinned ClickHouse executable SHA mismatch before native invocation') unless before == BINARY_SHA256
      invocation = @executor.send(:execute_record, label, argv, sql_bytes, 'clickhouse local', BINARY_SHA256, @binary)
      invocation[:record][:binary_sha_before] = before
      invocation[:record][:binary_sha_after] = binary_sha
      fail!('pinned ClickHouse executable SHA changed during invocation') unless invocation[:record][:binary_sha_after] == BINARY_SHA256
      annotate_invocation!(label, invocation[:record])
      @invocations << invocation[:record]
      invocation
    end

    def run_helper(input_path)
      before = helper_sha
      fail!('prebuilt helper changed before invocation') unless before == @helper_sha_before
      argv = [@helper, input_path, File.join(@root, 'generated')]
      invocation = @executor.send(:execute_record, 'crystal_helper', argv, ''.b,
                                  'prebuilt Crystal helper', before, @helper)
      annotate_invocation!('crystal_helper', invocation[:record])
      fail!('prebuilt helper process failed; not native format evidence') unless successful?(invocation)
      fail!('prebuilt helper emitted stderr') unless invocation[:stderr].empty?
      fail!('prebuilt helper changed during invocation') unless helper_sha == before
      lines = invocation[:stdout].lines.map(&:chomp).reject(&:empty?)
      fail!('prebuilt helper must emit exactly one JSON record') unless lines.size == 1
      data = JSON.parse(lines.fetch(0))
      fail!('prebuilt helper output format differs') unless data['format'] == FORMAT_OUTPUT
      @invocations << invocation[:record]
      {data: data, record: invocation[:record]}
    end

    def annotate_invocation!(label, record)
      # W202's inherited compiler-sized outer requirement is not this runner's
      # observed guard. The caller enforces the outer cap; this is a declaration.
      record.delete(:required_outer_run_safe_memory_limit_bytes)
      record[:outer_guard] = {
        memory_limit_mib: 1024, timeout_seconds: 120, status: 'declared_not_measured',
        note: 'Required guarded invocation; this runner does not enforce the outer process guard',
      }
      path = File.join(@root, 'invocations', "#{label}.json")
      stat = File.lstat(path)
      fail!("refusing to rewrite non-regular invocation evidence: #{label}") unless stat.file? && !stat.symlink?
      File.open(path, 'wb') { |file| file.write(JSON.pretty_generate(record) + "\n") }
    end

    def json_object(id)
      {'id' => id, 'maybe' => nil, 'counter' => id * 10 + 1}
    end

    def expected_value(case_id, row)
      case case_id
      when 'root_json'
        row[:kind] == :null ? nil : json_object(row.fetch(:id))
      when 'root_array_json'
        row[:kind] == :null ? nil : row.fetch(:ids).map { |id| json_object(id) }
      when 'root_tuple_json'
        row[:kind] == :null ? nil : row.fetch(:ids).map { |id| json_object(id) }
      when 'array_dynamic_array_json'
        row.fetch(:values).map do |arm, ids|
          arm == :null ? nil : ids.map { |id| json_object(id) }
        end
      else
        fail!("unrostered W213 expected value #{case_id.inspect}")
      end
    end

    def expected_actual(case_id, row)
      case case_id
      when 'root_json'
        row[:kind] == :null ? 'NULL' : JSON_USED
      when 'root_array_json'
        row[:kind] == :null ? 'NULL' : ARRAY_JSON
      when 'root_tuple_json'
        row[:kind] == :null ? 'NULL' : TUPLE_JSON
      when 'array_dynamic_array_json'
        row.fetch(:values).map { |arm, _ids| arm == :null ? 'NULL' : ARRAY_JSON }.join(',')
      else
        fail!("unrostered W213 actual type #{case_id.inspect}")
      end
    end

    def expected_shared(case_id, row)
      if case_id == 'array_dynamic_array_json'
        row.fetch(:values).map { |arm, _ids| arm == :null ? '0' : '1' }.join(',')
      else
        row[:kind] == :null ? '0' : '1'
      end
    end

    def expected_native_rows(case_id, window)
      all = ROWS.fetch(case_id)
      selected, first_key = case window
                            when 'FULL' then [all, 1]
                            when 'FIRST_EMPTY' then [all[0, 2], 1]
                            when 'LATER' then [all[2, 2], 3]
                            when 'FINAL' then [all[6, 2], 7]
                            when 'ZERO' then [[], 9]
                            else fail!("unknown W213 window #{window.inspect}")
                            end
      return [] if window == 'ZERO'
      selected.each_with_index.map do |row, index|
        [
          (first_key + index).to_s,
          expected_value(case_id, row),
          type_for(case_id),
          expected_actual(case_id, row),
          expected_shared(case_id, row),
          case_id == 'array_dynamic_array_json' ? row.fetch(:values).size.to_s : '1',
        ]
      end
    end

    def decode_hex_json(hex, label)
      fail!("malformed JSON hex for #{label}") unless hex.match?(/\A(?:[0-9A-Fa-f]{2})*\z/)
      JSON.parse([hex].pack('H*'))
    rescue JSON::ParserError => error
      fail!("invalid JSON for #{label}: #{error.message}")
    end

    def assert_value_windows!(native, table_name)
      case_id, = @table_identity.fetch(table_name)
      WINDOWS.each do |window|
        actual = native[:value_rows].fetch([table_name, window], [])
        next if window == 'ZERO'
        decoded = actual.map do |fields|
          [fields[0], decode_hex_json(fields[1], "#{table_name}/#{window}"), *fields.drop(2)]
        end
        expected = expected_native_rows(case_id, window)
        fail!("#{table_name}/#{window} values, nominal/actual types or shared flags differ: #{decoded.inspect}") unless decoded == expected
      end
    end

    def assert_initial_native!(native)
      expected_checks = source_tables.to_h do |name|
        _case_id, profile, = @table_identity.fetch(name)
        [[name, profile], ["all_1_1_0\t1\t"]]
      end
      fail!('stock source CHECK result differs') unless native[:checks] == expected_checks
      expected_schema = all_tables.sort.flat_map do |name|
        case_id, = @table_identity.fetch(name)
        [[name, 'pk', 'UInt64'], [name, 'payload', type_for(case_id)]]
      end
      fail!('stock source/empty-library nominal schema differs') unless native[:schemas] == expected_schema
      fail!('stock data-path roster differs') unless native[:data_paths].keys.sort == all_tables.sort
      native[:data_paths].each_value { |path| validate_store_path!(path) }
      @data_paths = native[:data_paths].dup
      fail!('stock source active-part roster differs') unless native[:parts].keys.sort == source_tables.sort
      expected_values = source_tables.product(WINDOWS.reject { |window| window == 'ZERO' }).sort
      fail!('stock source selected-value query roster differs') unless native[:value_rows].keys.sort == expected_values
      expected_zero = source_tables.flat_map do |name|
        profile = @table_identity.fetch(name)[1]
        [["__W202_ZERO_BEGIN__", name, profile, 'values'], ["__W202_ZERO_END__", name, profile, 'values']]
      end
      fail!('stock source zero-selection boundary roster differs') unless native[:zero_events] == expected_zero
      source_tables.each do |name|
        part = native[:parts].fetch(name)
        assert_part_grid!(part, name)
        path = validate_source_part!(part[:path])
        @source_parts[name] = path
        @source_snapshots[name] = snapshot_part(path)
        assert_value_windows!(native, name)
      end
    end

    def assert_attached_native!(native)
      library_tables = case_profiles.map { |case_id, profile| table(case_id, profile, 'library') }
      expected_checks = library_tables.to_h do |name|
        profile = @table_identity.fetch(name)[1]
        [[name, profile], ["all_1_1_0\t1\t"]]
      end
      fail!('stock library CHECK roster differs') unless native[:checks] == expected_checks
      expected_schema = all_tables.sort.flat_map do |name|
        case_id, = @table_identity.fetch(name)
        [[name, 'pk', 'UInt64'], [name, 'payload', type_for(case_id)]]
      end
      fail!('stock attached nominal schema differs') unless native[:schemas] == expected_schema
      fail!('stock attached part roster differs') unless native[:parts].keys.sort == all_tables.sort
      expected_values = all_tables.product(WINDOWS.reject { |window| window == 'ZERO' }).sort
      fail!('stock attached selected-value query roster differs') unless native[:value_rows].keys.sort == expected_values
      expected_zero = all_tables.flat_map do |name|
        profile = @table_identity.fetch(name)[1]
        [["__W202_ZERO_BEGIN__", name, profile, 'values'], ["__W202_ZERO_END__", name, profile, 'values']]
      end
      fail!('stock attached zero-selection boundary roster differs') unless native[:zero_events] == expected_zero
      all_tables.each do |name|
        assert_part_grid!(native[:parts].fetch(name), name)
        assert_value_windows!(native, name)
      end
    end

    def assert_part_grid!(part, table_name)
      fail!("#{table_name} is not one eight-row Wide part with four marks plus end sentinel") unless
        part[:name] == 'all_1_1_0' && part[:type] == 'Wide' && part[:rows] == '8' && part[:marks] == '5'
    end

    def build_helper_input
      capture_root = File.realpath(File.join(@root, 'stores', 'native'))
      cases = case_profiles.map do |case_id, profile|
        {
          'case_id' => case_id, 'profile_id' => profile, 'capture_root' => capture_root,
          'source_part' => @source_parts.fetch(table(case_id, profile, 'source')),
          'library_part' => File.join(@root, 'generated', case_id, profile, 'all_1_1_0'),
        }
      end
      {'format' => FORMAT_INPUT, 'capture_root' => capture_root, 'cases' => cases}
    end

    def expected_contents_by_mark(case_id)
      ROWS.fetch(case_id).each_slice(2).map do |parent_rows|
        parent_rows.flat_map do |row|
          case case_id
          when 'root_json'
            row[:kind] == :null ? [nil] : [row.fetch(:id).to_s]
          when 'root_array_json'
            row[:kind] == :null ? [nil] : [row.fetch(:ids).join(',')]
          when 'root_tuple_json'
            row[:kind] == :null ? [nil] : [row.fetch(:ids).join(',')]
          when 'array_dynamic_array_json'
            row.fetch(:values).map { |arm, ids| arm == :null ? nil : ids.join(',') }
          end
        end
      end
    end

    def json_signature(id)
      "J(#{id},#{id * 10 + 1})"
    end

    def dynamic_signature(kind, item)
      case kind
      when :null then 'null'
      when :json then "D[#{json_signature(item.fetch(:id))}]"
      when :array_json then "D[[#{item.fetch(:ids).map { |id| json_signature(id) }.join(',')}]]"
      when :tuple_json then "D[(#{item.fetch(:ids).map { |id| json_signature(id) }.join(',')})]"
      else fail!("unrostered W213 signature kind #{kind.inspect}")
      end
    end

    def expected_helper_signature(case_id, row)
      if case_id == 'array_dynamic_array_json'
        '[' + row.fetch(:values).map do |arm, ids|
          arm == :null ? 'null' : "D[[#{ids.map { |id| json_signature(id) }.join(',')}]]"
        end.join(',') + ']'
      else
        dynamic_signature(row.fetch(:kind), row)
      end
    end

    def expected_rows_by_mark(case_id)
      ROWS.fetch(case_id).each_slice(2).map do |rows|
        rows.map { |row| expected_helper_signature(case_id, row) }
      end
    end

    def varuint(value)
      out = +''.b
      loop do
        byte = value & 0x7f
        value >>= 7
        byte |= 0x80 unless value.zero?
        out << byte
        break if value.zero?
      end
      out
    end

    def wire_string(value)
      bytes = value.b
      varuint(bytes.bytesize) + bytes
    end

    def reordered_json_descriptor
      [0x30, 0x00, 0x01, 0x01, 0x02].pack('C*').b +
        wire_string('maybe') + "\x23\x01".b + wire_string('id') + "\x01\x00\x00".b
    end

    def json_row_wire(id)
      counter = id * 10 + 1
      [
        "\x03".b,
        wire_string('counter'), "\x0a".b, [counter].pack('q<'),
        wire_string('id'), [id].pack('C'),
        wire_string('maybe'), "\x01".b,
      ].join.b
    end

    def literal_envelope(case_id, content)
      ids = content.empty? ? [] : content.split(',').map(&:to_i)
      case case_id
      when 'root_json'
        JSON_DESCRIPTOR + json_row_wire(ids.fetch(0))
      when 'root_array_json', 'array_dynamic_array_json'
        "\x1e".b + JSON_DESCRIPTOR + varuint(ids.size) + ids.map { |id| json_row_wire(id) }.join.b
      when 'root_tuple_json'
        "\x1f\x02".b + JSON_DESCRIPTOR + JSON_DESCRIPTOR + ids.map { |id| json_row_wire(id) }.join.b
      else
        fail!("unrostered W213 literal envelope #{case_id.inspect}")
      end
    end

    def read_varuint(bytes, cursor)
      value = 0
      shift = 0
      10.times do
        fail!('truncated W213 VarUInt') if cursor >= bytes.bytesize
        byte = bytes.getbyte(cursor)
        cursor += 1
        fail!('overflowing W213 VarUInt') if shift == 63 && (byte & 0x7e) != 0
        value |= (byte & 0x7f) << shift
        return [value, cursor] if (byte & 0x80).zero?
        shift += 7
      end
      fail!('overlong W213 VarUInt')
    end

    def parse_json_row(bytes, cursor)
      count, cursor = read_varuint(bytes, cursor)
      fail!('literal W213 JSON row path count differs') unless count == 3
      values = {}
      count.times do
        length, cursor = read_varuint(bytes, cursor)
        fail!('literal W213 JSON path length is invalid') unless length.positive? && length <= 256 && length <= bytes.bytesize - cursor
        path = bytes.byteslice(cursor, length)
        cursor += length
        fail!("duplicate literal W213 path #{path.inspect}") if values.key?(path)
        case path
        when 'counter'
          fail!('counter path is not untyped Int64') unless bytes.getbyte(cursor) == 0x0a
          cursor += 1
          fail!('truncated W213 Int64 counter') if cursor > bytes.bytesize - 8
          values[path] = bytes.byteslice(cursor, 8).unpack1('q<')
          cursor += 8
        when 'id'
          fail!('truncated W213 typed id') if cursor >= bytes.bytesize
          values[path] = bytes.getbyte(cursor)
          cursor += 1
        when 'maybe'
          fail!('typed W213 maybe path is not NULL') unless bytes.getbyte(cursor) == 0x01
          values[path] = nil
          cursor += 1
        else
          fail!("unrostered W213 JSON path #{path.inspect}")
        end
      end
      fail!('literal W213 JSON path roster differs') unless values.keys.sort == %w[counter id maybe]
      [[values.fetch('id'), values.fetch('counter')], cursor]
    end

    def parse_json_descriptor(bytes, cursor)
      prefix = [0x30, 0x00, 0x01, 0x01, 0x02].pack('C*').b
      fail!('raw JSON descriptor prefix or fixed limits differ') unless
        cursor <= bytes.bytesize - prefix.bytesize && bytes.byteslice(cursor, prefix.bytesize) == prefix
      cursor += prefix.bytesize
      typed_paths = {}
      2.times do
        path_size_start = cursor
        length, cursor = read_varuint(bytes, cursor)
        fail!('raw JSON typed path name length is outside the fixed bound') unless
          length.positive? && length <= 32 && length <= bytes.bytesize - cursor
        fail!('raw JSON typed path length VarUInt is not canonical') unless cursor - path_size_start == 1
        path = bytes.byteslice(cursor, length)
        cursor += length
        fail!("raw JSON descriptor repeats typed path #{path.inspect}") if typed_paths.key?(path)
        case path
        when 'id'
          fail!('raw JSON id path length differs') unless length == 2
          fail!('raw JSON id typed child is not UInt8') unless bytes.getbyte(cursor) == 0x01
          typed_paths[path] = "\x01".b
          cursor += 1
        when 'maybe'
          fail!('raw JSON maybe path length differs') unless length == 5
          fail!('raw JSON maybe typed child is not Nullable(UInt8)') unless
            cursor <= bytes.bytesize - 2 && bytes.byteslice(cursor, 2) == "\x23\x01".b
          typed_paths[path] = "\x23\x01".b
          cursor += 2
        else
          fail!("raw JSON descriptor path is outside the fixed typed roster: #{path.inspect}")
        end
      end
      fail!('raw JSON descriptor typed-path map differs') unless
        typed_paths == {'id' => "\x01".b, 'maybe' => "\x23\x01".b}
      skips_start = cursor
      skips, cursor = read_varuint(bytes, cursor)
      skips_end = cursor
      regexes_start = cursor
      regexes, cursor = read_varuint(bytes, cursor)
      fail!('raw JSON descriptor skip or regex counts are nonzero or noncanonical') unless
        skips.zero? && regexes.zero? && skips_end - skips_start == 1 && cursor - regexes_start == 1
      cursor
    end

    def canonicalize_envelope_descriptor(bytes, case_id)
      # parse_envelope validates descriptors as an exact semantic map before
      # this replaces unordered-map iteration order with independent literal order.
      parse_envelope(bytes, case_id)
      prefix_size = case case_id
                    when 'root_json' then 0
                    when 'root_array_json', 'array_dynamic_array_json' then 1
                    when 'root_tuple_json' then 2
                    else fail!("unrostered W213 envelope #{case_id.inspect}")
                    end
      descriptor_count = case case_id
                         when 'root_tuple_json' then 2
                         else 1
                         end
      descriptor_end = prefix_size + JSON_DESCRIPTOR.bytesize * descriptor_count
      fail!('raw JSON descriptor envelope is truncated') if bytes.bytesize < descriptor_end
      bytes.byteslice(0, prefix_size).to_s.b + JSON_DESCRIPTOR * descriptor_count +
        bytes.byteslice(descriptor_end, bytes.bytesize - descriptor_end).to_s.b
    end

    def parse_envelope(bytes, case_id)
      cursor = 0
      case case_id
      when 'root_json'
        cursor = parse_json_descriptor(bytes, 0)
        count = 1
      when 'root_array_json', 'array_dynamic_array_json'
        fail!('Array(JSON) envelope tag differs from literal') unless bytes.getbyte(0) == 0x1e
        cursor = parse_json_descriptor(bytes, 1)
        count, cursor = read_varuint(bytes, cursor)
      when 'root_tuple_json'
        fail!('Tuple(JSON,JSON) envelope tag/count differs from literal') unless
          bytes.bytesize >= 2 && bytes.getbyte(0) == 0x1f && bytes.getbyte(1) == 0x02
        cursor = parse_json_descriptor(bytes, 2)
        cursor = parse_json_descriptor(bytes, cursor)
        count = 2
      else
        fail!("unrostered W213 envelope #{case_id.inspect}")
      end
      rows = Array.new(count) do
        values, cursor = parse_json_row(bytes, cursor)
        values
      end
      fail!('trailing bytes in W213 SharedVariant envelope') unless cursor == bytes.bytesize
      rows
    end

    def expected_roster(case_id, profile)
      names = %w[payload.dynamic_structure payload.variant_discr payload.SharedVariant]
      names << 'payload.SharedVariant.size' if profile == 'with_size_stream'
      names << 'payload.size0' if case_id == 'array_dynamic_array_json'
      names.sort
    end

    def assert_physical_roster!(observed, case_id, profile)
      expected = expected_roster(case_id, profile)
      fail!("#{case_id}/#{profile} physical stream roster differs from the literal SharedVariant-only roster") unless
        observed.is_a?(Array) && observed == expected && observed.uniq == observed
      fail!("#{case_id}/#{profile} Object or JSON child stream appeared in the physical roster") if
        observed.any? { |name| name.include?('object') || name.include?('counter') || name.include?('.id') || name.include?('.maybe') }
      true
    end

    def assert_wire_side!(case_id, side, origin)
      contents = expected_contents_by_mark(case_id)
      expected_discriminators = contents.map { |mark| mark.map { |content| content.nil? ? 255 : 0 } }
      expected_literal_hex = contents.map do |mark|
        mark.map { |content| content.nil? ? nil : literal_envelope(case_id, content).unpack1('H*') }
      end
      discriminator_rows = side.fetch('discriminator_bytes_by_mark')
      fail!("#{case_id}/#{origin} literal discriminator bytes differ") unless discriminator_rows == expected_discriminators
      literal_rows = side.fetch('literal_envelope_hex_by_mark')
      fail!("#{case_id}/#{origin} independent literal envelope hex differs") unless literal_rows == expected_literal_hex
      shared_rows = side.fetch('shared_envelope_hex_by_mark')
      fail!("#{case_id}/#{origin} SharedVariant envelope/Q counts differ") unless
        shared_rows.map(&:size) == contents.map(&:size)
      shared_rows.each_with_index do |mark, mark_index|
        mark.each_with_index do |hex, item_index|
          expected_content = contents.fetch(mark_index).fetch(item_index)
          if expected_content.nil?
            fail!("#{case_id}/#{origin} NULL discriminator unexpectedly has a SharedVariant envelope") unless hex.nil?
            next
          end
          fail!("#{case_id}/#{origin} shared discriminator lacks a SharedVariant envelope") unless hex
          bytes = [hex].pack('H*')
          ids = expected_content.empty? ? [] : expected_content.split(',').map(&:to_i)
          expected = ids.map { |id| [id, id * 10 + 1] }
          fail!("#{case_id}/#{origin} literal JSON semantic map differs") unless parse_envelope(bytes, case_id) == expected
          if origin == 'library'
            fail!("#{case_id} library SharedVariant envelope differs from independent canonical literal") unless
              hex == expected_literal_hex.fetch(mark_index).fetch(item_index)
          end
        end
      end
    end

    def assert_helper_side!(case_id, profile, origin, side)
      expected_keys = %w[
        checksum_file_names discriminator_bytes_by_mark literal_envelope_hex_by_mark mark_count
        mark_row_counts mark_row_words_by_file ordinary_profile physical_stream_names row_count
        rows_by_mark schema_declaration selected_checksum_names shared_envelope_hex_by_mark
        site_occurrence_counts windows
      ].sort
      expected_keys << 'owned_values' if origin == 'source'
      expected_keys.sort!
      fail!("#{case_id}/#{profile}/#{origin} helper side key set differs") unless side.keys.sort == expected_keys
      occurrence_counts = case_id == 'array_dynamic_array_json' ? OUTER_OCCURRENCE_COUNTS : PARENT_MARK_ROWS
      fail!("#{case_id}/#{profile}/#{origin} schema/grid/profile differs") unless
        side['schema_declaration'] == type_for(case_id) && side['row_count'] == 8 && side['mark_count'] == 4 &&
        side['mark_row_counts'] == PARENT_MARK_ROWS && side['site_occurrence_counts'] == occurrence_counts &&
        side['ordinary_profile'] == profile && side['windows'] == %w[full first middle final eof_zero]
      fail!("#{case_id}/#{profile}/#{origin} independent helper row signatures differ") unless
        side['rows_by_mark'] == expected_rows_by_mark(case_id)
      if origin == 'source'
        owned = side.fetch('owned_values')
        declaration = type_for(case_id)
        fail!("#{case_id}/#{profile} owned-values observation keys differ") unless
          owned.keys.sort == %w[mark_row_counts nominal_type_names_by_mark row_count schema_declaration values_by_mark]
        fail!("#{case_id}/#{profile} owned-values nominal schema or row/mark census differs") unless
          owned['schema_declaration'] == declaration && owned['row_count'] == 8 && owned['mark_row_counts'] == PARENT_MARK_ROWS
        expected_types = Array.new(PARENT_MARK_ROWS.size) { Array.new(2, declaration) }
        fail!("#{case_id}/#{profile} owned-values actual nominal descriptors differ") unless
          owned['nominal_type_names_by_mark'] == expected_types
        fail!("#{case_id}/#{profile} owned-values values differ from independent stock literals") unless
          owned['values_by_mark'] == expected_rows_by_mark(case_id)
      end

      physical = side.fetch('physical_stream_names')
      assert_physical_roster!(physical, case_id, profile)
      selected = side.fetch('selected_checksum_names')
      checksums = side.fetch('checksum_file_names')
      fail!("#{case_id}/#{profile}/#{origin} checksum names are incomplete/duplicated") unless
        checksums.is_a?(Array) && checksums == checksums.uniq.sort && !checksums.empty?
      fail!("#{case_id}/#{profile}/#{origin} Dynamic checksum selection differs") unless
        selected.is_a?(Array) && selected == selected.uniq.sort && selected.size == physical.size * 2 && (selected - checksums).empty?
      marks = side.fetch('mark_row_words_by_file')
      mark_names = marks.map { |entry| entry.fetch('file') }
      fail!("#{case_id}/#{profile}/#{origin} complete mark-file manifest differs") unless
        mark_names == mark_names.uniq.sort && mark_names == checksums.select { |name| name.end_with?('.mrk2') }.sort
      marks.each do |entry|
        fail!("#{case_id}/#{profile}/#{origin} physical mark third words differ from parent P") unless
          entry.keys.sort == %w[file third_words] && entry.fetch('third_words') == PARENT_MARK_THIRD_WORDS
      end
      @part_rosters[[case_id, profile, origin]] = {
        physical_stream_names: physical, selected_checksum_names: selected,
        checksum_file_names: checksums, mark_row_words_by_file: marks,
      }
      assert_wire_side!(case_id, side, origin)
    end

    def assert_helper_output!(data)
      required = %w[case_ids cases format matrix_count outer_site_occurrence_counts parent_mark_rows profile_ids].sort
      fail!('Crystal helper output keys or format differ') unless data.keys.sort == required && data['format'] == FORMAT_OUTPUT
      fail!('Crystal helper fixed matrix/grid differs') unless data['case_ids'] == CASE_IDS && data['profile_ids'] == PROFILE_IDS &&
        data['parent_mark_rows'] == PARENT_MARK_ROWS && data['outer_site_occurrence_counts'] == OUTER_OCCURRENCE_COUNTS &&
        data['matrix_count'] == 8 && data['cases'].is_a?(Array) && data['cases'].size == 8
      pairs = data['cases'].map { |item| [item.fetch('case_id'), item.fetch('profile_id')] }
      fail!('Crystal helper case/profile order differs') unless pairs == case_profiles
      data['cases'].each do |item|
        case_id = item.fetch('case_id')
        profile = item.fetch('profile_id')
        fail!("#{case_id}/#{profile} helper case keys differ") unless
          item.keys.sort == %w[case_id library library_part_path profile_id source]
        path = File.join(@root, 'generated', case_id, profile, 'all_1_1_0')
        fail!("#{case_id}/#{profile} generated library path differs") unless File.expand_path(item.fetch('library_part_path')) == path
        fail!("#{case_id}/#{profile} generated library part is absent or symlinked") unless
          File.directory?(path) && !File.symlink?(path)
        @library_parts[[case_id, profile]] = path
        @library_snapshots[[case_id, profile]] = snapshot_part(path)
        assert_helper_side!(case_id, profile, 'source', item.fetch('source'))
        assert_helper_side!(case_id, profile, 'library', item.fetch('library'))
      end
    end

    def attach_library_parts!
      case_profiles.each do |case_id, profile|
        path = @library_parts.fetch([case_id, profile])
        table_name = table(case_id, profile, 'library')
        native_path = validate_store_path!(@data_paths.fetch(table_name))
        @executor.send(:attach_part!, path, native_path)
      end
    end

    def json_signature_for(id)
      "J(#{id},#{id * 10 + 1})"
    end

    def assert_fixed_fixtures!
      fail!('W213 case/profile roster changed') unless CASE_IDS.size == 4 && PROFILE_IDS == %w[single_stream with_size_stream]
      fail!('W213 fixed fixtures are not eight rows each') unless ROWS.keys.sort == CASE_IDS.sort && ROWS.values.all? { |rows| rows.size == 8 }
      fail!('W213 P/Q discriminator changed') unless PARENT_MARK_ROWS == [2, 2, 2, 2] &&
        PARENT_MARK_THIRD_WORDS == [2, 2, 2, 2, 0] &&
        ROWS.fetch('array_dynamic_array_json').map { |row| row.fetch(:values).size }.each_slice(2).map(&:sum) == OUTER_OCCURRENCE_COUNTS
      fail!('W213 JSON descriptor is not the literal 19-byte descriptor') unless JSON_DESCRIPTOR.bytesize == 19
      CASE_IDS.each do |case_id|
        PROFILE_IDS.each do |profile|
          names = expected_roster(case_id, profile)
          assert_physical_roster!(names, case_id, profile)
          rejected = false
          begin
            assert_physical_roster!(names + ['payload.object_structure'], case_id, profile)
          rescue StandardError
            rejected = true
          end
          fail!('W213 negative roster mutation accepted') unless rejected
        end
      end
      tuple = literal_envelope('root_tuple_json', '51,52')
      fail!('W213 tuple literal parser failed') unless parse_envelope(tuple, 'root_tuple_json') == [[51, 511], [52, 521]]
      direct = literal_envelope('root_json', '31')
      direct_rows = direct.byteslice(JSON_DESCRIPTOR.bytesize, direct.bytesize - JSON_DESCRIPTOR.bytesize)
      reordered = reordered_json_descriptor
      reordered_wire = reordered + direct_rows
      fail!('W213 unordered JSON typed-path descriptor order was rejected') unless
        parse_envelope(reordered_wire, 'root_json') == [[31, 311]] &&
        canonicalize_envelope_descriptor(reordered_wire, 'root_json') == direct
      wrong_child = reordered.dup
      wrong_child.setbyte(16, 0x02)
      rejected_typed_child = false
      begin
        parse_envelope(wrong_child + direct_rows, 'root_json')
      rescue StandardError
        rejected_typed_child = true
      end
      fail!('W213 wrong typed-child descriptor mutation was accepted') unless rejected_typed_child
      tuple_prefix = "\x1f\x02".b
      tuple_rows = tuple.byteslice(2 + JSON_DESCRIPTOR.bytesize * 2, tuple.bytesize - 2 - JSON_DESCRIPTOR.bytesize * 2)
      tuple_reordered = tuple_prefix + reordered + reordered + tuple_rows
      fail!('W213 Tuple(JSON,JSON) rejected semantically equivalent descriptor order') unless
        parse_envelope(tuple_reordered, 'root_tuple_json') == [[51, 511], [52, 521]]
      array = literal_envelope('root_array_json', '41')
      array_offset = 1 + JSON_DESCRIPTOR.bytesize
      array_reordered = "\x1e".b + reordered + array.byteslice(array_offset, array.bytesize - array_offset)
      fail!('W213 Array(JSON) rejected semantically equivalent descriptor order') unless
        parse_envelope(array_reordered, 'root_array_json') == parse_envelope(array, 'root_array_json')
      empty = literal_envelope('root_array_json', '')
      fail!('W213 empty Array(JSON) literal parser failed') unless parse_envelope(empty, 'root_array_json').empty?
      true
    end

    def write_evidence(data)
      summary = {
        probe: 'W213 paired SharedVariant inline JSON native witness',
        status: data[:status], fatal_error: data[:fatal_error],
        runtime: {path: @binary, expected_sha256: BINARY_SHA256,
                  sha256_before: @binary_sha_before, sha256_after: @binary_sha_after,
                  expected_version: VERSION, expected_build: BUILD},
        source_reference: SOURCE_REVISION,
        helper_executable: {path: @helper, sha256_before: @helper_sha_before, sha256_after: @helper_sha_after},
        helper_input: @helper_input,
        limits: {max_threads: 1, local_max_memory_usage_bytes: W202::MEMORY,
                 timeout_seconds: W202::TIMEOUT, termination_grace_seconds: W202::GRACE,
                 executor: 'JsonBinaryKernelW180Probe#execute'},
        cases: CASE_IDS, profiles: PROFILE_IDS, evidence_root: @root,
        invocations: @invocations,
      }.merge(data.reject { |key, _| %i[status fatal_error].include?(key) })
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      write_new(File.join(@root, 'summary.md'), [
        '# W213 paired SharedVariant inline JSON native witness', '',
        "Status: `#{summary[:status]}`", '',
        'Scope: four fixed actual families across both ordinary String profiles; eight rows and four P=[2,2,2,2] parent marks per part. The outer Array(Dynamic(max_types=0)) has logical occurrence Q=[2,3,3,5], while every physical .mrk2 third-word row count remains P. Every non-NULL Dynamic actual is an all-shared JSON/Array(JSON) value; NULL is discriminator 255 and actual shared is discriminator 0.', '',
        "Runtime: #{VERSION} / VERSION_GITHASH #{BUILD} / SHA256 `#{BINARY_SHA256}`", '',
        "Source reference: ClickHouse `#{SOURCE_REVISION}` (separate from runtime binary)", '',
        "Evidence root: `#{@root}`", '',
      ].join("\n"))
    end
  end

  def self.self_test!
    probe = Probe.allocate
    probe.send(:assert_fixed_fixtures!)
    root_json_hex = probe.send(:json_value_hex_expression, 'root_json')
    outer_json_hex = probe.send(:json_value_hex_expression, 'array_dynamic_array_json')
    fail!('W213 root Dynamic SQL NULL sentinel projection changed') unless
      root_json_hex == "if(isNull(payload), '6E756C6C', hex(toJSONString(payload)))"
    fail!('W213 nonnullable outer Array projection unexpectedly gained a SQL NULL sentinel') unless
      outer_json_hex == 'hex(toJSONString(payload))'
    null_json = probe.send(:decode_hex_json, '6E756C6C', 'explicit SQL NULL sentinel')
    empty_array_json = probe.send(:decode_hex_json, '5B5D', 'shared empty Array(JSON)')
    fail!('W213 SQL NULL and shared empty Array(JSON) no longer distinguish') unless
      null_json.nil? && empty_array_json == [] && null_json != empty_array_json
    rejected_tsv_null = false
    begin
      probe.send(:decode_hex_json, '\\N', 'raw TSV SQL NULL marker')
    rescue StandardError
      rejected_tsv_null = true
    end
    fail!('W213 raw TSV SQL NULL marker was accepted as JSON hex') unless rejected_tsv_null
    first_array_rows = probe.send(:expected_native_rows, 'root_array_json', 'FIRST_EMPTY')
    later_array_rows = probe.send(:expected_native_rows, 'root_array_json', 'LATER')
    fail!('W213 NULL Dynamic and shared empty Array(JSON) fixture rows collapsed') unless
      first_array_rows.first[1].nil? && later_array_rows.first[1] == []
    CASE_IDS.each do |case_id|
      full = probe.send(:expected_native_rows, case_id, 'FULL')
      fail!('W213 full native fixture row count changed') unless full.size == 8
      fail!('W213 zero native window is not empty') unless probe.send(:expected_native_rows, case_id, 'ZERO').empty?
      contents = probe.send(:expected_contents_by_mark, case_id)
      fail!('W213 literal occurrence grid differs') unless contents.map(&:size) ==
        (case_id == 'array_dynamic_array_json' ? OUTER_OCCURRENCE_COUNTS : PARENT_MARK_ROWS)
    end
    puts "W213 Ruby fixture self-test passed matrix_count=#{CASE_IDS.size * PROFILE_IDS.size} P=#{PARENT_MARK_ROWS.inspect} outer_Q=#{OUTER_OCCURRENCE_COUNTS.inspect}"
  end

  def self.run_cli
    if ARGV == ['--self-test']
      self_test!
      return 0
    end
    options = {binary: BINARY, helper: nil, root: nil}
    OptionParser.new do |parser|
      parser.banner = 'usage: ruby scripts/probe_dynamic_shared_json_w213.rb --crystal-helper PREBUILT --evidence-root EMPTY_DIRECT_CHILD_OF_PRIVATE_TMP [--clickhouse PINNED]'
      parser.on('--clickhouse PATH', 'Pinned ClickHouse 26.10.1.1201 executable') { |value| options[:binary] = value }
      parser.on('--crystal-helper PATH', 'Prebuilt Crystal helper; this runner never compiles it') { |value| options[:helper] = value }
      parser.on('--evidence-root PATH', 'Existing empty direct child of /private/tmp') { |value| options[:root] = value }
    end.parse!
    abort 'W213: --crystal-helper and --evidence-root are required' unless options[:helper] && options[:root]
    Probe.new(options[:binary], options[:helper], options[:root]).run ? 0 : 1
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit ProbeDynamicSharedJSONW213.run_cli
  rescue StandardError => error
    warn "W213 runner error: #{error.class}: #{error.message}"
    exit 1
  end
end
