#!/usr/bin/env ruby
# Paired stock/library witness for recursive JSON leaves in Dynamic actuals.
# This runner consumes only a prebuilt helper and the pinned ClickHouse binary;
# it does not compile either implementation.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require_relative 'probe_nested_bulk_part_w202'

module ProbeDynamicJSONRecursiveW212
  W202 = ProbeNestedBulkPartW202
  W183 = JsonArrayStorageW183
  BINARY = W202::BINARY
  BINARY_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  VERSION = '26.10.1.1201'.freeze
  BUILD = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  SOURCE_REVISION = '0ca8150d9b1d0886edb2e3b4ab65eebb768d0357'.freeze
  MEMORY = 512 * 1024 * 1024
  TIMEOUT = 10
  GRACE = 2

  FORMAT_INPUT = 'dynamic_json_recursive_w212_input_v1'.freeze
  FORMAT_OUTPUT = 'dynamic_json_recursive_w212_helper_v1'.freeze
  CASE_IDS = %w[
    root_array_json root_named_tuple_json root_deep_nullable_json
    root_map_json root_array_variant_json array_dynamic_array_json
  ].freeze
  PROFILE_IDS = %w[single_stream with_size_stream].freeze
  WINDOWS = %w[FULL FIRST_EMPTY LATER FINAL ZERO].freeze
  MAX_COLUMNS_SUBSTREAMS_BYTES = 1_048_576

  DYNAMIC = 'Dynamic(max_types=4)'.freeze
  ARRAY_DYNAMIC = "Array(#{DYNAMIC})".freeze
  JSON_USED = 'JSON(max_dynamic_types=1, max_dynamic_paths=1, id UInt8, maybe Nullable(UInt8))'.freeze
  JSON_UNUSED = 'JSON(max_dynamic_types=2, max_dynamic_paths=1, id UInt8, maybe Nullable(UInt8))'.freeze
  UINT8 = 'UInt8'.freeze
  ARRAY_JSON = "Array(#{JSON_USED})".freeze
  NAMED_TUPLE_JSON = "Tuple(left #{JSON_USED}, right #{JSON_USED})".freeze
  DEEP_NULLABLE_JSON = "Array(Tuple(String, Nullable(#{JSON_USED})))".freeze
  MAP_JSON = "Map(String, #{JSON_USED})".freeze
  ARRAY_VARIANT_JSON = "Array(Variant(#{JSON_USED}, UInt8))".freeze

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

  # Independent six-row stock literals. The first two rows in each root case
  # select UInt8; the outer Array(Dynamic) begins with two genuinely empty rows.
  # Every JSON document has an untyped integer counter which stock infers as
  # Int64, while id/maybe exercise the explicitly typed JSON paths.
  ROWS = {
    'root_array_json' => [
      {kind: :u8, value: 11}, {kind: :u8, value: 12},
      {kind: :array_json, ids: []}, {kind: :array_json, ids: [31, 32]},
      {kind: :array_json, ids: [33, 34, 35]}, {kind: :array_json, ids: []},
    ].freeze,
    'root_named_tuple_json' => [
      {kind: :u8, value: 13}, {kind: :u8, value: 14},
      {kind: :named_tuple_json, left: 41, right: 42},
      {kind: :named_tuple_json, left: 43, right: 44},
      {kind: :named_tuple_json, left: 0, right: 45},
      {kind: :named_tuple_json, left: 46, right: 47},
    ].freeze,
    'root_deep_nullable_json' => [
      {kind: :u8, value: 15}, {kind: :u8, value: 16},
      {kind: :deep_json, pairs: []},
      {kind: :deep_json, pairs: [['nil', nil], ['present', 61]]},
      {kind: :deep_json, pairs: [['default', 62], ['null-default', nil]]},
      {kind: :deep_json, pairs: []},
    ].freeze,
    'root_map_json' => [
      {kind: :u8, value: 17}, {kind: :u8, value: 18},
      {kind: :map_json, entries: []},
      {kind: :map_json, entries: [['alpha', 71], ['beta', 72]]},
      {kind: :map_json, entries: [['omega', 73]]}, {kind: :map_json, entries: []},
    ].freeze,
    'root_array_variant_json' => [
      {kind: :u8, value: 19}, {kind: :u8, value: 20},
      {kind: :array_variant, choices: []},
      {kind: :array_variant, choices: [[:json, 81], [:u8, 82], [:null, nil]]},
      {kind: :array_variant, choices: [[:json, 83], [:json, 84]]},
      {kind: :array_variant, choices: []},
    ].freeze,
    'array_dynamic_array_json' => [
      {kind: :outer, values: []}, {kind: :outer, values: []},
      {kind: :outer, values: [[:array_json, []], [:u8, 91], [:array_json, [101]]]},
      {kind: :outer, values: []},
      {kind: :outer, values: [[:array_json, [111, 112]], [:u8, 92], [:array_json, [113]],
                              [:array_json, [114]], [:u8, 93]]},
      {kind: :outer, values: []},
    ].freeze,
  }.freeze

  ACTUAL_TYPES = {
    'root_array_json' => ARRAY_JSON,
    'root_named_tuple_json' => NAMED_TUPLE_JSON,
    'root_deep_nullable_json' => DEEP_NULLABLE_JSON,
    'root_map_json' => MAP_JSON,
    'root_array_variant_json' => ARRAY_VARIANT_JSON,
    'array_dynamic_array_json' => ARRAY_JSON,
  }.freeze

  PARENT_MARK_ROWS = [2, 2, 2].freeze
  OBJECT_CHILD_MARK_ROWS = [2, 2, 2, 0].freeze

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
    ['single_stream', 2] => %w[
      .object_structure .id .maybe.null .maybe
      .counter.dynamic_structure .counter.variant_discr .counter.SharedVariant .counter.Int64
      .object_shared_data.size2 .object_shared_data%2Epaths .object_shared_data%2Evalues
    ].freeze,
    ['with_size_stream', 0] => %w[
      .object_structure .id .maybe.null .maybe
      .counter.dynamic_structure .counter.variant_discr .counter.SharedVariant .counter.SharedVariant.size .counter.Int64
      .object_shared_data.size0 .object_shared_data%2Epaths .object_shared_data%2Evalues
    ].freeze,
    ['with_size_stream', 1] => %w[
      .object_structure .id .maybe.null .maybe
      .counter.dynamic_structure .counter.variant_discr .counter.SharedVariant .counter.SharedVariant.size .counter.Int64
      .object_shared_data.size1 .object_shared_data%2Epaths .object_shared_data%2Evalues
    ].freeze,
    ['with_size_stream', 2] => %w[
      .object_structure .id .maybe.null .maybe
      .counter.dynamic_structure .counter.variant_discr .counter.SharedVariant .counter.SharedVariant.size .counter.Int64
      .object_shared_data.size2 .object_shared_data%2Epaths .object_shared_data%2Evalues
    ].freeze,
  }.freeze

  class Probe < W202::Probe
    def initialize(binary, crystal_helper, evidence_root, outer_guard_memory_mib, outer_guard_timeout_seconds)
      super(binary, crystal_helper, evidence_root)
      @outer_guard_memory_mib = outer_guard_memory_mib
      @outer_guard_timeout_seconds = outer_guard_timeout_seconds
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
        fail!("stock source part changed during ATTACH/SELECT: #{name}") unless snapshot_part(path) == @source_snapshots.fetch(name)
      end
      @library_parts.each do |key, path|
        fail!("library part changed during ATTACH/SELECT: #{key.join('/')}") unless snapshot_part(path) == @library_snapshots.fetch(key)
      end
      @binary_sha_after = binary_sha
      @helper_sha_after = helper_sha
      fail!('pinned ClickHouse executable SHA changed during probe') unless @binary_sha_after == BINARY_SHA256
      fail!('prebuilt Crystal helper SHA changed during probe') unless @helper_sha_after == @helper_sha_before

      write_evidence(
        status: 'paired_recursive_dynamic_json_native_witness_observed',
        source: native, helper: helper[:data], helper_invocation: helper[:record],
        initial_invocation: initial[:record], attached: attached_native,
        attached_invocation: attached[:record], source_part_snapshots: @source_snapshots,
        library_part_snapshots: @library_snapshots,
      )
      puts "W212 paired recursive Dynamic JSON cases=#{CASE_IDS.size} profiles=#{PROFILE_IDS.size}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @binary_sha_after = binary_sha rescue nil
      @helper_sha_after = helper_sha rescue nil
      write_evidence(status: 'runner_failure_or_observations_differ', fatal_error: @fatal_error) rescue nil
      warn "W212 probe failure (process failure is not format evidence): #{@fatal_error}"
      false
    end

    private

    def fail!(message)
      raise "W212 recursive Dynamic JSON witness: #{message}"
    end

    def binary_sha
      Digest::SHA256.file(@binary).hexdigest
    end

    def helper_sha
      Digest::SHA256.file(@helper).hexdigest
    end

    def prepare_layout!
      %w[invocations inputs stores generated].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
      case_profiles.each do |case_id, profile|
        FileUtils.mkdir_p(File.join(@root, 'generated', case_id, profile), mode: 0o700)
        %w[source library].each { |origin| @table_identity[table(case_id, profile, origin)] = [case_id, profile, origin] }
      end
    end

    def table(case_id, profile, origin)
      "#{origin}_#{case_id}_#{profile}"
    end

    def case_profiles
      CASE_IDS.flat_map { |case_id| PROFILE_IDS.map { |profile| [case_id, profile] } }
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
      "CAST(CAST(#{sql_quote(raw)}, '#{JSON_USED}'), '#{DYNAMIC}')"
    end

    def actual_sql(kind, value)
      case kind
      when :u8
        "CAST(toUInt8(#{value.fetch(:value)}), '#{DYNAMIC}')"
      when :array_json
        children = value.fetch(:ids).map { |id| "CAST(CAST(#{sql_quote(JSON.generate({'id' => id, 'maybe' => nil, 'counter' => id * 10 + 1}))}, '#{JSON_USED}'), '#{JSON_USED}')" }
        "CAST(CAST([#{children.join(', ')}], '#{ARRAY_JSON}'), '#{DYNAMIC}')"
      when :named_tuple_json
        left = json_value_sql(value.fetch(:left))
        right = json_value_sql(value.fetch(:right))
        "CAST(CAST(tuple(#{left}, #{right}), '#{NAMED_TUPLE_JSON}'), '#{DYNAMIC}')"
      when :deep_json
        pairs = value.fetch(:pairs).map do |label, id|
          doc = id.nil? ? "CAST(NULL, 'Nullable(#{JSON_USED})')" : "CAST(#{json_value_sql(id)}, 'Nullable(#{JSON_USED})')"
          "(#{sql_quote(label)}, #{doc})"
        end
        "CAST(CAST([#{pairs.join(', ')}], '#{DEEP_NULLABLE_JSON}'), '#{DYNAMIC}')"
      when :map_json
        entries = value.fetch(:entries).map { |key, id| "#{sql_quote(key)}, #{json_value_sql(id)}" }
        map = entries.empty? ? "CAST([], '#{MAP_JSON}')" : "CAST(map(#{entries.join(', ')}), '#{MAP_JSON}')"
        "CAST(#{map}, '#{DYNAMIC}')"
      when :array_variant
        variant = "Variant(#{JSON_USED}, UInt8)"
        choices = value.fetch(:choices).map do |arm, item|
          case arm
          when :json then "CAST(#{json_value_sql(item)}, '#{variant}')"
          when :u8 then "CAST(toUInt8(#{item}), '#{variant}')"
          when :null then "CAST(NULL, '#{variant}')"
          else fail!("unrostered Variant literal #{arm.inspect}")
          end
        end
        "CAST(CAST([#{choices.join(', ')}], '#{ARRAY_VARIANT_JSON}'), '#{DYNAMIC}')"
      when :outer
        children = value.fetch(:values).map do |arm, item|
          if arm == :u8
            "CAST(toUInt8(#{item}), '#{DYNAMIC}')"
          elsif arm == :array_json
            ids = item.map { |id| json_value_sql(id) }
            "CAST(CAST([#{ids.join(', ')}], '#{ARRAY_JSON}'), '#{DYNAMIC}')"
          else
            fail!("unrostered outer Dynamic literal #{arm.inspect}")
          end
        end
        "CAST([#{children.join(', ')}], '#{ARRAY_DYNAMIC}')"
      else
        fail!("unrostered native literal #{kind.inspect}")
      end
    end

    def json_value_sql(id)
      raw = JSON.generate({'id' => id, 'maybe' => nil, 'counter' => id * 10 + 1})
      "CAST(#{sql_quote(raw)}, '#{JSON_USED}')"
    end

    def value_sql(case_id, value)
      actual_sql(value.fetch(:kind), value)
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
        [table(case_id, profile, 'source'), table(case_id, profile, 'library')].each do |name|
          settings = "#{SETTINGS}, string_serialization_version='#{profile}'"
          statements << "CREATE TABLE default.#{name} (pk UInt64, payload #{type_for(case_id)}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings};"
        end
        rows = ROWS.fetch(case_id).each_with_index
        source_name = table(case_id, profile, 'source')
        if case_id == 'root_map_json'
          # VALUES evaluates expressions through Field before inserting into Dynamic. That
          # round-trip can erase nested JSON parameters from Map(String, JSON(...)). Keep
          # the expression's typed column through INSERT SELECT instead.
          selects = rows.map { |value, index| "SELECT #{index + 1} AS pk, #{value_sql(case_id, value)} AS payload" }
          statements << "INSERT INTO default.#{source_name}\n#{selects.join("\nUNION ALL\n")};"
        else
          values = rows.map { |value, index| "(#{index + 1}, #{value_sql(case_id, value)})" }
          statements << "INSERT INTO default.#{source_name} VALUES\n#{values.join(",\n")};"
        end
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
      case_profiles.each do |case_id, profile|
        statements << "ALTER TABLE default.#{table(case_id, profile, 'library')} ATTACH PART 'all_1_1_0';"
        statements << check_sql(table(case_id, profile, 'source'), profile)
        statements << check_sql(table(case_id, profile, 'library'), profile)
      end
      names = all_tables.map { |name| "'#{name}'" }.join(',')
      statements << "SELECT '__W202_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{names}) ORDER BY table, position FORMAT TSVRaw;"
      statements << parts_sql(all_tables)
      all_tables.each { |name| statements.concat(value_queries(name)) }
      statements.join("\n") + "\n"
    end

    def value_queries(table_name)
      windows = {
        'FULL' => '', 'FIRST_EMPTY' => ' WHERE pk BETWEEN 1 AND 2',
        'LATER' => ' WHERE pk BETWEEN 3 AND 4', 'FINAL' => ' WHERE pk BETWEEN 5 AND 6',
        'ZERO' => ' WHERE pk > 6',
      }
      windows.flat_map do |window, predicate|
        name = "__W202_VALUES_#{window}__"
        actual, shared, size = projection_for(table_name)
        query = "SELECT '#{name}', '#{table_name}', toString(pk), hex(toJSONString(payload)), " \
                "toTypeName(payload), #{actual}, #{shared}, #{size} FROM default.#{table_name}#{predicate} " \
                "ORDER BY pk SETTINGS print_pretty_type_names=0 FORMAT TSVRaw;"
        if window == 'ZERO'
          profile = @table_identity.fetch(table_name)[1]
          next ["SELECT '__W202_ZERO_BEGIN__', '#{table_name}', '#{profile}', 'values' FORMAT TSVRaw;",
                query,
                "SELECT '__W202_ZERO_END__', '#{table_name}', '#{profile}', 'values' FORMAT TSVRaw;"]
        end
        [query]
      end
    end

    def projection_for(table_name)
      case_id, = @table_identity.fetch(table_name)
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

    def expected_actual(case_id, value)
      if case_id == 'array_dynamic_array_json'
        value.fetch(:values).map do |arm, _item|
          arm == :u8 ? UINT8 : ARRAY_JSON
        end.join(',')
      else
        value.fetch(:kind) == :u8 ? UINT8 : ACTUAL_TYPES.fetch(case_id)
      end
    end

    def expected_shared(case_id, value)
      case_id == 'array_dynamic_array_json' ? value.fetch(:values).map { '0' }.join(',') : '0'
    end

    def expected_json_value(case_id, value)
      json = ->(id) { {'id' => id, 'maybe' => nil, 'counter' => id * 10 + 1} }
      case value.fetch(:kind)
      when :u8 then value.fetch(:value)
      when :array_json then value.fetch(:ids).map(&json)
      when :named_tuple_json then {'left' => json.call(value.fetch(:left)), 'right' => json.call(value.fetch(:right))}
      when :deep_json then value.fetch(:pairs).map { |label, id| [label, id.nil? ? nil : json.call(id)] }
      when :map_json then value.fetch(:entries).to_h { |key, id| [key, json.call(id)] }
      when :array_variant
        value.fetch(:choices).map do |arm, item|
          case arm
          when :json then json.call(item)
          when :u8 then item
          when :null then nil
          end
        end
      when :outer
        value.fetch(:values).map do |arm, item|
          arm == :u8 ? item : item.map(&json)
        end
      else
        fail!("unrostered expected value kind #{value[:kind].inspect}")
      end
    end

    def expected_native_rows(case_id, window)
      all = ROWS.fetch(case_id)
      selected = case window
                 when 'FULL' then all
                 when 'FIRST_EMPTY' then all[0, 2]
                 when 'LATER' then all[2, 2]
                 when 'FINAL' then all[4, 2]
                 when 'ZERO' then []
                 else fail!("unknown value window #{window.inspect}")
                 end
      selected.each_with_index.map do |value, index|
        pk = case window
             when 'FULL', 'FIRST_EMPTY' then index + 1
             when 'LATER' then index + 3
             when 'FINAL' then index + 5
             else fail!("unexpected nonempty value window #{window.inspect}")
             end
        [pk.to_s, expected_json_value(case_id, value), type_for(case_id),
         expected_actual(case_id, value), expected_shared(case_id, value),
         case_id == 'array_dynamic_array_json' ? value.fetch(:values).size.to_s : '1']
      end
    end

    def decode_hex_json(hex, label)
      fail!("malformed JSON hex for #{label}") unless hex.match?(/\A(?:[0-9A-Fa-f]{2})*\z/)
      JSON.parse([hex].pack('H*'))
    rescue JSON::ParserError => error
      raise "W212 invalid JSON for #{label}: #{error.message}"
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
        fail!("#{table_name}/#{window} values, nominal/actual types or Dynamic storage differ: #{decoded.inspect}") unless decoded == expected
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
        fail!("#{name} is not one six-row Wide part with three marks plus sentinel") unless
          part[:name] == 'all_1_1_0' && part[:type] == 'Wide' && part[:rows] == '6' && part[:marks] == '4'
        path = validate_source_part!(part[:path])
        @source_parts[name] = path
        @source_snapshots[name] = snapshot_part(path)
        assert_value_windows!(native, name)
      end
    end

    def assert_attached_native!(native)
      expected_checks = all_tables.to_h do |name|
        profile = @table_identity.fetch(name)[1]
        [[name, profile], ["all_1_1_0\t1\t"]]
      end
      fail!('stock source/library CHECK roster differs') unless native[:checks] == expected_checks
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
        part = native[:parts].fetch(name)
        fail!("#{name} attached part identity/grid differs") unless
          part[:name] == 'all_1_1_0' && part[:type] == 'Wide' && part[:rows] == '6' && part[:marks] == '4'
        assert_value_windows!(native, name)
      end
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

    def run_helper(input_path)
      before = helper_sha
      fail!('prebuilt helper changed before invocation') unless before == @helper_sha_before
      argv = [@helper, input_path, File.join(@root, 'generated')]
      invocation = @executor.send(:execute_record, 'crystal_helper', argv, ''.b,
                                  'prebuilt Crystal helper', before, @helper)
      annotate_invocation!('crystal_helper', invocation[:record])
      fail!('prebuilt helper process failed; not native format evidence') unless successful?(invocation)
      fail!('prebuilt helper emitted diagnostics to stderr') unless invocation[:stderr].empty?
      fail!('prebuilt helper changed during invocation') unless helper_sha == before
      lines = invocation[:stdout].lines.map(&:chomp).reject(&:empty?)
      fail!('prebuilt helper must emit exactly one JSON record') unless lines.size == 1
      data = JSON.parse(lines.fetch(0))
      fail!('prebuilt helper output format differs') unless data['format'] == FORMAT_OUTPUT
      @invocations << invocation[:record]
      {data: data, record: invocation[:record]}
    end

    def run_clickhouse(label, sql)
      invocation = super
      annotate_invocation!(label, invocation[:record])
      invocation
    end

    def annotate_invocation!(label, record)
      record.delete(:required_outer_run_safe_memory_limit_bytes)
      record[:outer_guard] = {
        memory_limit_mib: @outer_guard_memory_mib,
        timeout_seconds: @outer_guard_timeout_seconds,
        status: 'declared_not_measured',
        note: 'Required CLI declarations; this runner does not enforce the outer process guard',
      }
      record[:bounded_child_executor] = {
        executor: 'JsonBinaryKernelW180Probe#execute',
        invocation_timeout_seconds: TIMEOUT,
        termination_grace_seconds: GRACE,
        clickhouse_local_max_threads: 1,
        clickhouse_local_max_memory_usage_bytes: MEMORY,
      }

      path = File.join(@root, 'invocations', "#{label}.json")
      stat = File.lstat(path)
      fail!("refusing to rewrite non-regular invocation evidence: #{label}") unless stat.file? && !stat.symlink?
      File.open(path, 'wb') { |file| file.write(JSON.pretty_generate(record) + "\n") }
    end

    def escaped_component(value)
      value.b.bytes.map do |byte|
        character = byte.chr
        character.match?(/[A-Za-z0-9_]/) ? character : format('%%%02X', byte)
      end.join
    end

    def arm_prefix(json_type)
      "payload.#{escaped_component(json_type)}"
    end

    def leaf_roster(case_id, origin)
      # Dynamic arms are rooted at their full actual type. Wrapper substreams
      # below that arm contribute only their independent suffixes; ArrayElements
      # is transparent in ClickHouse's physical filename formatter.
      dynamic_actual_type = ACTUAL_TYPES.fetch(case_id)
      selected = case case_id
                 when 'root_array_json' then [[dynamic_actual_type, '', 1]]
                 when 'root_named_tuple_json' then [[dynamic_actual_type, '%2Eleft', 0], [dynamic_actual_type, '%2Eright', 0]]
                 # Nullable's NullMap is a sibling `.null` stream; its
                 # NullableElements path leaves Object children rooted at the
                 # tuple field itself.
                 when 'root_deep_nullable_json' then [[dynamic_actual_type, '%2E2', 1]]
                 when 'root_map_json' then [[dynamic_actual_type, '%2Evalues', 1]]
                 when 'root_array_variant_json' then [[dynamic_actual_type, ".#{escaped_component(JSON_USED)}", 1]]
                 when 'array_dynamic_array_json' then [[dynamic_actual_type, '', 2]]
                 else fail!("unknown physical leaf case #{case_id.inspect}")
                 end
      if origin == 'library'
        selected << [JSON_UNUSED, '', case_id == 'array_dynamic_array_json' ? 1 : 0]
      end
      selected.map { |type, suffix, level| [arm_prefix(type) + suffix, level] }
    end

    def expected_object_child_names(case_id, profile, origin)
      leaf_roster(case_id, origin).flat_map do |prefix, level|
        OBJECT_CHILD_SUFFIXES.fetch([profile, level]).map { |suffix| "#{prefix}#{suffix}" }
      end.sort
    end

    # The manifest is the independent physical-name census. Do not use the
    # helper's filtered object_child_stream_names as a completeness oracle:
    # require the exact Object subtree below every literal JSON leaf prefix.
    # The pinned source reference SOURCE_REVISION defines this boundary in
    # src/DataTypes/Serializations: ISerialization.cpp:302-355 formats
    # ArraySizes as `.size<array_level>`, makes ArrayElements transparent,
    # escapes each whole TupleElement segment, appends `.null` for NullMap,
    # and escapes VariantElement's canonical type. SerializationArray::
    # enumerateStreams (255-293) emits its size lane before transparent
    # elements; SerializationNullable::enumerateStreams (43-69) emits NullMap
    # beside transparent NullableElements; SerializationTuple::enumerateStreams
    # (766-800) adds its literal child elements; and SerializationMap::
    # enumerateStreams (652-720) uses its BASIC Array(Tuple(K,V)) storage.
    # SerializationDynamic::enumerateStreams (108-134) delegates through its
    # actual Variant, whose SerializationVariant::enumerateStreams (115-193)
    # visits every canonical arm. That method's VariantElementNullMap lane is
    # a virtual subcolumn (174-193), not evidence of a persisted part stream,
    # so it is deliberately NOT whitelisted. Only the explicitly listed
    # physical ArraySizes and Nullable NullMap wrapper siblings may coexist
    # under these leaf prefixes. Every other descendant must be in
    # OBJECT_CHILD_SUFFIXES.
    # The full arm and wrapper prefix oracle remains literal in leaf_roster.
    def expected_leaf_wrapper_siblings(case_id, prefix)
      actual_prefix = arm_prefix(ACTUAL_TYPES.fetch(case_id))
      case case_id
      when 'root_array_json'
        prefix == actual_prefix ? ["#{prefix}.size0"] : []
      when 'root_deep_nullable_json'
        prefix == "#{actual_prefix}%2E2" ? ["#{prefix}.null"] : []
      when 'array_dynamic_array_json'
        # The outer Array(Dynamic) consumes array level 0 before the actual
        # Array(JSON) arm emits its own offsets.
        prefix == actual_prefix ? ["#{prefix}.size1"] : []
      else
        []
      end
    end

    def assert_exact_leaf_stream_rosters!(physical_names, case_id, profile, origin)
      leaf_roster(case_id, origin).each do |prefix, level|
        expected = OBJECT_CHILD_SUFFIXES.fetch([profile, level]).map { |suffix| "#{prefix}#{suffix}" }
        observed = physical_names.select { |name| name == prefix || name.start_with?("#{prefix}.") }
        allowed_siblings = expected_leaf_wrapper_siblings(case_id, prefix)
        missing = expected - observed
        unfamiliar = observed - expected - allowed_siblings
        fail!("#{case_id}/#{profile}/#{origin} exact JSON-leaf stream roster differs at #{prefix.inspect}; missing=#{missing.inspect}, unfamiliar=#{unfamiliar.inspect}") unless
          missing.empty? && unfamiliar.empty?
      end
    end

    def canonical_dynamic_index(case_id, actual_type)
      arm_types = [ACTUAL_TYPES.fetch(case_id), JSON_UNUSED, UINT8]
      (arm_types + ['SharedVariant']).sort.index(actual_type) || fail!('literal Dynamic actual arm index is absent')
    end

    def expected_binding_keys(case_id)
      site = case_id == 'array_dynamic_array_json' ? 'root.elements' : 'root'
      used_index = canonical_dynamic_index(case_id, ACTUAL_TYPES.fetch(case_id))
      unused_index = canonical_dynamic_index(case_id, JSON_UNUSED)
      paths = case case_id
              when 'root_array_json', 'array_dynamic_array_json' then ['0']
              when 'root_named_tuple_json' then ['0', '1']
              when 'root_deep_nullable_json' then ['0,1,0']
              when 'root_map_json' then ['1']
              when 'root_array_variant_json' then ['0,0']
              else fail!('binding path oracle is incomplete')
              end
      (paths.map { |path| "#{site}/#{used_index}/#{path}" } + ["#{site}/#{unused_index}/"]).sort
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
        match = /\A([1-9][0-9]*) substreams for column `([^`]+)`:\z/.match(lines.shift.to_s)
        fail!("#{label} columns_substreams block is malformed") unless match
        count = Integer(match[1], 10)
        name = match[2]
        fail!("#{label} columns_substreams repeats a column") if columns.key?(name)
        fail!("#{label} columns_substreams block is truncated") if lines.size < count
        values = lines.shift(count).map do |line|
          item = /\A\t([^\t\r\n]+)\z/.match(line)
          fail!("#{label} substream line is malformed") unless item
          item[1]
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
      fail!("#{label} .mrk2 has a partial record") unless (bytes.bytesize % 24).zero?
      bytes.bytes.each_slice(24).map { |record| record[16, 8].pack('C*').unpack1('Q<') }
    end

    def assert_part_roster!(path, side, case_id, profile, origin)
      validate_plain_tree!(path)
      columns = parse_manifest(path, "#{case_id}/#{profile}/#{origin}")
      names = columns.fetch('payload').sort
      fail!("#{case_id}/#{profile}/#{origin} helper and on-disk physical names differ") unless names == side.fetch('physical_stream_names').sort
      expected_children = expected_object_child_names(case_id, profile, origin)
      assert_exact_leaf_stream_rosters!(names, case_id, profile, origin)
      fail!("#{case_id}/#{profile}/#{origin} literal recursive Object-child filename oracle differs") unless
        side.fetch('object_child_stream_names').sort == expected_children
      manifest_children = names.select { |name| expected_children.include?(name) }.sort
      fail!("#{case_id}/#{profile}/#{origin} on-disk Object-child roster differs") unless manifest_children == expected_children

      stream_files = Dir.children(path).select { |name| name.end_with?('.bin') || name.end_with?('.mrk2') }
      fail!("#{case_id}/#{profile}/#{origin} stream filenames are malformed") unless stream_files.all? { |name| /\A[0-9a-f]{32}\.(?:bin|mrk2)\z/.match?(name) }
      binaries = stream_files.select { |name| name.end_with?('.bin') }.map { |name| name.delete_suffix('.bin') }.sort
      marks = stream_files.select { |name| name.end_with?('.mrk2') }.map { |name| name.delete_suffix('.mrk2') }.sort
      expected_hashes = (names + ['pk']).map { |name| W183.stream_hash(name) }.sort
      fail!("#{case_id}/#{profile}/#{origin} stream-name hash oracle collides") unless expected_hashes.uniq == expected_hashes
      fail!("#{case_id}/#{profile}/#{origin} native stream files do not match physical names") unless binaries == expected_hashes && marks == expected_hashes
      payload_hashes = names.map { |name| W183.stream_hash(name) }
      expected_checksums = payload_hashes.flat_map { |hash| ["#{hash}.bin", "#{hash}.mrk2"] }.sort
      fail!("#{case_id}/#{profile}/#{origin} selected checksum roster differs") unless side.fetch('selected_checksum_names').sort == expected_checksums
      mark_files = stream_files.select { |name| name.end_with?('.mrk2') }
      mark_files.each do |name|
        actual = mark_rows(File.binread(File.join(path, name)), "#{case_id}/#{profile}/#{origin}/#{name}")
        fail!("#{case_id}/#{profile}/#{origin} mark third words do not preserve root P") unless actual == OBJECT_CHILD_MARK_ROWS
      end
      @part_rosters[[case_id, profile, origin].join('/')] = {
        payload_substreams: names, mark_row_words: mark_files.to_h { |name| [name, mark_rows(File.binread(File.join(path, name)), name)] },
      }
    end

    def assert_helper_output!(data)
      required = %w[case_ids cases format object_child_mark_rows parent_mark_rows profile_ids]
      fail!('helper root output keys or format differ') unless data.keys.sort == required && data['format'] == FORMAT_OUTPUT
      fail!('helper case/profile roster differs') unless data['case_ids'] == CASE_IDS && data['profile_ids'] == PROFILE_IDS
      fail!('helper parent and Object mark grids differ') unless data['parent_mark_rows'] == PARENT_MARK_ROWS && data['object_child_mark_rows'] == OBJECT_CHILD_MARK_ROWS
      pairs = data.fetch('cases').map { |item| [item.fetch('case_id'), item.fetch('profile_id')] }
      fail!('helper case/profile ordering differs') unless pairs == case_profiles

      expected_signatures = {
        'root_array_json' => [['D[U8:11]', 'D[U8:12]'], ['D[[]]', 'D[[J(31,311),J(32,321)]]'], ['D[[J(33,331),J(34,341),J(35,351)]]', 'D[[]]']],
        'root_named_tuple_json' => [['D[U8:13]', 'D[U8:14]'], ['D[(left=J(41,411),right=J(42,421))]', 'D[(left=J(43,431),right=J(44,441))]'], ['D[(left=J(0,1),right=J(45,451))]', 'D[(left=J(46,461),right=J(47,471))]']],
        'root_deep_nullable_json' => [['D[U8:15]', 'D[U8:16]'], ['D[[]]', 'D[[(nil,null),(present,J(61,611))]]'], ['D[[(default,J(62,621)),(null-default,null)]]', 'D[[]]']],
        'root_map_json' => [['D[U8:17]', 'D[U8:18]'], ['D[{}]', 'D[{alpha=J(71,711),beta=J(72,721)}]'], ['D[{omega=J(73,731)}]', 'D[{}]']],
        'root_array_variant_json' => [['D[U8:19]', 'D[U8:20]'], ['D[[]]', 'D[[V0=J(81,811),V1=U8:82,Vnull]]'], ['D[[V0=J(83,831),V0=J(84,841)]]', 'D[[]]']],
        'array_dynamic_array_json' => [['[]', '[]'], ['[D[[]],D[U8:91],D[[J(101,1011)]]]', '[]'], ['[D[[J(111,1111),J(112,1121)]],D[U8:92],D[[J(113,1131)]],D[[J(114,1141)]],D[U8:93]]', '[]']],
      }.freeze
      data.fetch('cases').each do |item|
        case_id = item.fetch('case_id')
        profile = item.fetch('profile_id')
        fail!('helper case object keys differ') unless item.keys.sort == %w[case_id library library_part_path profile_id source]
        %w[source library].each do |origin|
          side = item.fetch(origin)
          expected_keys = %w[bound_json_leaf_keys bound_json_type_names case_id mark_count mark_row_counts object_child_stream_names physical_stream_names profile_id row_count rows_by_mark schema_declaration selected_checksum_names windows]
          fail!("#{case_id}/#{profile}/#{origin} helper side key set differs") unless side.keys.sort == expected_keys
          fail!("#{case_id}/#{profile}/#{origin} helper schema, mark grid, rows or windows differ") unless
            side['case_id'] == case_id && side['profile_id'] == profile && side['schema_declaration'] == type_for(case_id) &&
            side['row_count'] == 6 && side['mark_count'] == 3 && side['mark_row_counts'] == PARENT_MARK_ROWS &&
            side['rows_by_mark'] == expected_signatures.fetch(case_id) &&
            side['windows'] == %w[full first middle final eof_zero]
          fail!("#{case_id}/#{profile}/#{origin} physical/checksum names are malformed") unless
            side['physical_stream_names'].is_a?(Array) && !side['physical_stream_names'].empty? && side['physical_stream_names'].uniq == side['physical_stream_names'] &&
            side['selected_checksum_names'].is_a?(Array) && side['selected_checksum_names'].uniq == side['selected_checksum_names']

          if origin == 'source'
            fail!("#{case_id}/#{profile} source reader incorrectly requires library-only unused binding") unless side['bound_json_leaf_keys'].empty? && side['bound_json_type_names'].empty?
          else
            fail!("#{case_id}/#{profile} library binding key roster differs") unless side['bound_json_leaf_keys'].sort == expected_binding_keys(case_id)
            expected_types = Array.new(case_id == 'root_named_tuple_json' ? 2 : 1, JSON_USED) + [JSON_UNUSED]
            fail!("#{case_id}/#{profile} library bound JSON type roster differs") unless side['bound_json_type_names'].sort == expected_types.sort
          end

          path = if origin == 'source'
                   @source_parts.fetch(table(case_id, profile, origin))
                 else
                   File.join(@root, 'generated', case_id, profile, 'all_1_1_0')
                 end
          assert_part_roster!(path, side, case_id, profile, origin)
        end
        expected_path = File.join(@root, 'generated', case_id, profile, 'all_1_1_0')
        fail!('helper library output path differs from fixed destination') unless File.expand_path(item.fetch('library_part_path')) == expected_path
        key = [case_id, profile]
        @library_parts[key] = expected_path
        @library_snapshots[key] = snapshot_part(expected_path)
      end
    end

    def attach_library_parts!
      case_profiles.each do |case_id, profile|
        target = table(case_id, profile, 'library')
        path = @library_parts.fetch([case_id, profile])
        expected = File.join(@root, 'generated', case_id, profile, 'all_1_1_0')
        fail!('generated library part path differs from fixed destination') unless File.expand_path(path) == expected
        validate_plain_tree!(expected)
        @executor.send(:attach_part!, expected, validate_store_path!(@data_paths.fetch(target)))
      end
    end

    def write_evidence(data)
      status = data.delete(:status)
      fatal = data.delete(:fatal_error)
      summary = {
        status: status, fatal_error: fatal,
        runtime: {version: VERSION, build: BUILD, sha256: BINARY_SHA256, source_revision: SOURCE_REVISION},
        helper_sha256: @helper_sha_before, helper_sha256_after: @helper_sha_after,
        binary_sha256_before: @binary_sha_before, binary_sha256_after: @binary_sha_after,
        helper_input: @helper_input, part_rosters: @part_rosters,
        outer_guard: {
          memory_limit_mib: @outer_guard_memory_mib,
          timeout_seconds: @outer_guard_timeout_seconds,
          status: 'declared_not_measured',
          note: 'Required CLI declarations; this runner does not enforce the outer process guard',
        },
        child_executor_limits: {
          clickhouse_local_max_threads: 1,
          clickhouse_local_max_memory_usage_bytes: MEMORY,
          invocation_timeout_seconds: TIMEOUT,
          termination_grace_seconds: GRACE,
          executor: 'JsonBinaryKernelW180Probe#execute',
        },
        cases: CASE_IDS, profiles: PROFILE_IDS, evidence_root: @root,
        invocations: @invocations,
      }.merge(data)
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      write_new(File.join(@root, 'summary.md'), [
        '# W212 paired recursive Dynamic JSON native witness', '',
        "Status: `#{status}`", '',
        'Scope: six explicit ordinary Dynamic actual families across both String profiles, one six-row Wide part per source/library table. Stock-authored values are independently checked before and after ATTACH; library parts are written from independent BinaryValue fixtures and then directly ATTACH/CHECKed by stock. Root P=[2,2,2]; the outer Array(Dynamic) fixture has Q=[0,3,5], selected Array(JSON) R=[0,2,3], and selected JSON-leaf E=[0,1,4]. The library descriptor additionally binds an unused direct JSON arm; stock source readers are not required to contain that library-only binding.', '',
        "Runtime: #{VERSION} / VERSION_GITHASH #{BUILD} / SHA256 `#{BINARY_SHA256}`", '',
        "Source reference: ClickHouse `#{SOURCE_REVISION}` (separate from runtime binary)", '',
        "Outer guard declaration: #{@outer_guard_memory_mib} MiB / #{@outer_guard_timeout_seconds}s (`declared_not_measured`; enforced outside this runner).", '',
        "Child executor: ClickHouse `--max_threads=1`, `--max_memory_usage=#{MEMORY}` bytes; #{@executor.class} invocation timeout #{TIMEOUT}s plus #{GRACE}s termination grace.", '',
        "Evidence root: `#{@root}`", '',
      ].join("\n"))
    end
  end

  def self.self_test!
    raise 'W212 case/profile roster changed' unless CASE_IDS.size == 6 && PROFILE_IDS == %w[single_stream with_size_stream]
    raise 'W212 literal rows are not six rows/case' unless ROWS.keys.sort == CASE_IDS.sort && ROWS.values.all? { |rows| rows.size == 6 }
    outer = ROWS.fetch('array_dynamic_array_json')
    q = outer.map { |row| row.fetch(:values).size }
    r = outer.map { |row| row.fetch(:values).count { |arm, _| arm == :array_json } }
    e = outer.map { |row| row.fetch(:values).sum { |arm, item| arm == :array_json ? item.size : 0 } }
    raise 'W212 P/Q/R/E fixture discriminator changed' unless PARENT_MARK_ROWS == [2, 2, 2] && q.each_slice(2).map(&:sum) == [0, 3, 5] && r.each_slice(2).map(&:sum) == [0, 2, 3] && e.each_slice(2).map(&:sum) == [0, 1, 4]
    raise 'W212 Object child profile/level oracle changed' unless OBJECT_CHILD_SUFFIXES.size == 6 && OBJECT_CHILD_SUFFIXES.values.all? { |suffixes| suffixes.any? { |suffix| suffix.end_with?('.counter.Int64') } && !suffixes.any? { |suffix| suffix.end_with?('.counter.UInt64') } }
    (0..2).each do |level|
      single = OBJECT_CHILD_SUFFIXES.fetch(['single_stream', level])
      with_size = OBJECT_CHILD_SUFFIXES.fetch(['with_size_stream', level])
      map_single = single.select { |suffix| suffix.start_with?('.object_shared_data.') || suffix.start_with?('.object_shared_data%') }.sort
      map_with_size = with_size.select { |suffix| suffix.start_with?('.object_shared_data.') || suffix.start_with?('.object_shared_data%') }.sort
      raise 'W212 Object shared MAP changed with ordinary String profile' unless map_single == map_with_size
      raise 'W212 Object shared MAP paths/values gained size streams' if map_single.any? { |suffix| suffix.end_with?('.paths.size') || suffix.end_with?('.values.size') }
      raise 'W212 ordinary String profile is not independently reflected' unless single.include?('.counter.SharedVariant') && !single.include?('.counter.SharedVariant.size') && with_size.include?('.counter.SharedVariant.size')
    end
    probe = Probe.allocate
    CASE_IDS.each do |case_id|
      PROFILE_IDS.each do |profile|
        %w[source library].each do |origin|
          # Validate every literal arm/profile/origin leaf using the same
          # independent roster constructor used against columns_substreams.
          expected_children = probe.send(:expected_object_child_names, case_id, profile, origin)
          wrapper_siblings = probe.send(:leaf_roster, case_id, origin).flat_map do |prefix, _level|
            probe.send(:expected_leaf_wrapper_siblings, case_id, prefix)
          end
          probe.send(:assert_exact_leaf_stream_rosters!, (expected_children + wrapper_siblings).uniq,
                     case_id, profile, origin)
        end
      end
    end

    # Negative falsifier: the old expected-name filter (and a helper that
    # reports only recognized children) both omit this unfamiliar physical
    # lane. The complete manifest census must still reject it.
    case_id = 'root_array_json'
    profile = 'single_stream'
    origin = 'source'
    prefix = probe.send(:arm_prefix, ACTUAL_TYPES.fetch(case_id))
    expected_children = probe.send(:expected_object_child_names, case_id, profile, origin)
    valid_names = expected_children + ["#{prefix}.size0"]
    probe.send(:assert_exact_leaf_stream_rosters!, valid_names, case_id, profile, origin)
    unfamiliar = "#{prefix}.unexpected_child_lane"
    mutated_manifest = valid_names + [unfamiliar]
    helper_physical_names = mutated_manifest.dup # matching full physical roster, as emitted by the helper
    manifest_filtered_children = mutated_manifest.select { |name| expected_children.include?(name) }.sort
    helper_filtered_children = helper_physical_names.select { |name| expected_children.include?(name) }.sort
    raise 'W212 negative roster mutation did not reproduce filtered omission' unless
      helper_physical_names.sort == mutated_manifest.sort &&
      manifest_filtered_children == expected_children.sort && helper_filtered_children == expected_children.sort &&
      !manifest_filtered_children.include?(unfamiliar) && !helper_filtered_children.include?(unfamiliar)
    begin
      probe.send(:assert_exact_leaf_stream_rosters!, mutated_manifest, case_id, profile, origin)
    rescue RuntimeError => error
      raise 'W212 negative roster mutation failed for the wrong reason' unless error.message.include?('unfamiliar=')
    else
      raise 'W212 exact leaf roster accepted an unfamiliar child lane hidden from filtered rosters'
    end
    escaped = lambda { |value| value.b.bytes.map { |byte| c = byte.chr; c.match?(/[A-Za-z0-9_]/) ? c : format('%%%02X', byte) }.join }
    raise 'W212 escaped tuple or array prefix oracle changed' unless escaped.call('.left') == '%2Eleft' && !arm_prefix_for(ARRAY_JSON).include?('.elements')
    puts 'W212 Ruby fixture self-test passed'
  end

  def self.arm_prefix_for(type)
    escaped = type.b.bytes.map { |byte| c = byte.chr; c.match?(/[A-Za-z0-9_]/) ? c : format('%%%02X', byte) }.join
    "payload.#{escaped}"
  end

  def self.run_cli
    if ARGV == ['--self-test']
      self_test!
      return
    end
    options = {binary: BINARY}
    OptionParser.new do |parser|
      parser.banner = 'usage: ruby scripts/probe_dynamic_json_recursive_w212.rb --crystal-helper PATH --evidence-root EMPTY_DIRECT_CHILD_OF_PRIVATE_TMP --outer-guard-memory-mib MIB --outer-guard-timeout-seconds SECONDS [--clickhouse PATH]'
      parser.on('--clickhouse PATH', 'Pinned stock ClickHouse executable') { |value| options[:binary] = value }
      parser.on('--crystal-helper PATH', 'Prebuilt Crystal helper; this runner never compiles it') { |value| options[:helper] = value }
      parser.on('--evidence-root PATH', 'Existing empty direct child of /private/tmp') { |value| options[:root] = value }
      parser.on('--outer-guard-memory-mib MIB', Integer, 'Declared external outer-run memory guard') { |value| options[:outer_guard_memory_mib] = value }
      parser.on('--outer-guard-timeout-seconds SECONDS', Integer, 'Declared external outer-run timeout guard') { |value| options[:outer_guard_timeout_seconds] = value }
    end.parse!
    abort 'W212: --crystal-helper, --evidence-root, --outer-guard-memory-mib, and --outer-guard-timeout-seconds are required' unless
      options[:helper] && options[:root] && options[:outer_guard_memory_mib] && options[:outer_guard_timeout_seconds]
    abort 'W212: outer guard values must be positive integers' unless
      options[:outer_guard_memory_mib].positive? && options[:outer_guard_timeout_seconds].positive?
    exit(Probe.new(options[:binary], options[:helper], options[:root],
                   options[:outer_guard_memory_mib], options[:outer_guard_timeout_seconds]).run ? 0 : 1)
  end
end

ProbeDynamicJSONRecursiveW212.run_cli if $PROGRAM_NAME == __FILE__
