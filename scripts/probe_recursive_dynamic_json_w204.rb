#!/usr/bin/env ruby
# Bounded stock/library complete-part probe for mixed recursive JSON and
# JSON-free Dynamic bulk sites. This runner consumes a supplied prebuilt helper
# and pinned ClickHouse executable; it never invokes a compiler.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require_relative 'probe_nested_bulk_part_w202'

module ProbeRecursiveDynamicJSONW204
  W202 = ProbeNestedBulkPartW202
  BINARY = W202::BINARY
  BINARY_SHA256 = W202::BINARY_SHA256
  VERSION = W202::VERSION
  BUILD = W202::BUILD
  MEMORY = W202::MEMORY
  TIMEOUT = W202::TIMEOUT
  GRACE = W202::GRACE
  OUTER_RUN_SAFE_LIMIT = W202::OUTER_RUN_SAFE_LIMIT

  # This is the source archive audited for compatibility, not the runtime pin.
  SOURCE_ARCHIVE_COMMIT = 'ef037e60fc7f5654c8c80eefb8be82e3c56f9a67'.freeze
  FORMAT_INPUT = 'recursive_dynamic_json_w204_input_v1'.freeze
  FORMAT_OUTPUT = 'recursive_dynamic_json_w204_helper_v1'.freeze
  JSON_TYPE = 'JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8)'.freeze
  DYNAMIC = 'Dynamic(max_types=1)'.freeze
  PROFILE_IDS = %w[single_stream with_size_stream].freeze
  CASE_IDS = %w[root_tuple array_tuple ragged_array_tuple lc_bulk_tuple].freeze
  WINDOWS = %w[FULL FIRST_EMPTY LATER MIDDLE FINAL ZERO].freeze
  MAX_COLUMNS_SUBSTREAMS_BYTES = 1_048_576

  TUPLE_TYPE = "Tuple(doc #{JSON_TYPE}, d #{DYNAMIC})".freeze
  ARRAY_TUPLE_TYPE = "Array(#{TUPLE_TYPE})".freeze
  RAGGED_ARRAY_TUPLE_TYPE = "Array(Array(#{TUPLE_TYPE}))".freeze
  BULK_STATE_TYPE = "Tuple(label LowCardinality(String), d #{DYNAMIC}, text String, nested Array(#{DYNAMIC}))".freeze
  LC_BULK_TUPLE_TYPE = "Array(Tuple(doc #{JSON_TYPE}, state #{BULK_STATE_TYPE}))".freeze

  # Independent literal payload roster for columns_substreams.txt and the
  # recursive reader metadata. The escaped field prefixes follow the stock
  # Tuple(JSON) W186 and Array/Tuple(JSON) W187 controls; Dynamic and String
  # profile lanes follow W203. This is intentionally not generated from the
  # helper's BinaryBulk plan.
  BASE_PAYLOAD_SUBSTREAMS = {
    'root_tuple' => {
      'source' => %w[payload%2Edoc.object_structure payload%2Edoc.t payload%2Edoc.object_shared_data.size0 payload%2Edoc.object_shared_data%2Epaths payload%2Edoc.object_shared_data%2Evalues payload%2Edoc.s.dynamic_structure payload%2Edoc.s.variant_discr payload%2Edoc.s.SharedVariant payload%2Edoc.s.String payload%2Ed.dynamic_structure payload%2Ed.variant_discr payload%2Ed.SharedVariant payload%2Ed.UInt64].freeze,
      'library' => %w[payload%2Edoc.object_structure payload%2Edoc.t payload%2Edoc.object_shared_data.size0 payload%2Edoc.object_shared_data%2Epaths payload%2Edoc.object_shared_data%2Evalues payload%2Edoc.s.dynamic_structure payload%2Edoc.s.variant_discr payload%2Edoc.s.SharedVariant payload%2Edoc.s.String payload%2Ed.dynamic_structure payload%2Ed.variant_discr payload%2Ed.SharedVariant payload%2Ed.UInt64].freeze,
    }.freeze,
    'array_tuple' => {
      'source' => %w[payload.size0 payload%2Edoc.object_structure payload%2Edoc.t payload%2Edoc.object_shared_data.size1 payload%2Edoc.object_shared_data%2Epaths payload%2Edoc.object_shared_data%2Evalues payload%2Edoc.s.dynamic_structure payload%2Edoc.s.variant_discr payload%2Edoc.s.SharedVariant payload%2Edoc.s.String payload%2Ed.dynamic_structure payload%2Ed.variant_discr payload%2Ed.SharedVariant payload%2Ed.UInt64].freeze,
      'library' => %w[payload.size0 payload%2Edoc.object_structure payload%2Edoc.t payload%2Edoc.object_shared_data.size1 payload%2Edoc.object_shared_data%2Epaths payload%2Edoc.object_shared_data%2Evalues payload%2Edoc.s.dynamic_structure payload%2Edoc.s.variant_discr payload%2Edoc.s.SharedVariant payload%2Edoc.s.String payload%2Ed.dynamic_structure payload%2Ed.variant_discr payload%2Ed.SharedVariant payload%2Ed.UInt64].freeze,
    }.freeze,
    'ragged_array_tuple' => {
      'source' => %w[payload.size0 payload.size1 payload%2Edoc.object_structure payload%2Edoc.t payload%2Edoc.object_shared_data.size2 payload%2Edoc.object_shared_data%2Epaths payload%2Edoc.object_shared_data%2Evalues payload%2Edoc.s.dynamic_structure payload%2Edoc.s.variant_discr payload%2Edoc.s.SharedVariant payload%2Edoc.s.String payload%2Ed.dynamic_structure payload%2Ed.variant_discr payload%2Ed.SharedVariant payload%2Ed.UInt64].freeze,
      'library' => %w[payload.size0 payload.size1 payload%2Edoc.object_structure payload%2Edoc.t payload%2Edoc.object_shared_data.size2 payload%2Edoc.object_shared_data%2Epaths payload%2Edoc.object_shared_data%2Evalues payload%2Edoc.s.dynamic_structure payload%2Edoc.s.variant_discr payload%2Edoc.s.SharedVariant payload%2Edoc.s.String payload%2Ed.dynamic_structure payload%2Ed.variant_discr payload%2Ed.SharedVariant payload%2Ed.UInt64].freeze,
    }.freeze,
    'lc_bulk_tuple' => {
      'source' => %w[payload.size0 payload%2Edoc.object_structure payload%2Edoc.t payload%2Edoc.object_shared_data.size1 payload%2Edoc.object_shared_data%2Epaths payload%2Edoc.object_shared_data%2Evalues payload%2Edoc.s.dynamic_structure payload%2Edoc.s.variant_discr payload%2Edoc.s.SharedVariant payload%2Edoc.s.String payload%2Estate%2Elabel.dict payload%2Estate%2Elabel payload%2Estate%2Ed.dynamic_structure payload%2Estate%2Ed.variant_discr payload%2Estate%2Ed.SharedVariant payload%2Estate%2Ed.UInt64 payload%2Estate%2Etext payload%2Estate%2Enested.dynamic_structure payload%2Estate%2Enested.variant_discr payload%2Estate%2Enested.size1 payload%2Estate%2Enested.SharedVariant payload%2Estate%2Enested.UInt64].freeze,
      'library' => %w[payload.size0 payload%2Edoc.object_structure payload%2Edoc.t payload%2Edoc.object_shared_data.size1 payload%2Edoc.object_shared_data%2Epaths payload%2Edoc.object_shared_data%2Evalues payload%2Edoc.s.dynamic_structure payload%2Edoc.s.variant_discr payload%2Edoc.s.SharedVariant payload%2Edoc.s.String payload%2Estate%2Elabel.dict payload%2Estate%2Elabel payload%2Estate%2Ed.dynamic_structure payload%2Estate%2Ed.variant_discr payload%2Estate%2Ed.SharedVariant payload%2Estate%2Ed.UInt64 payload%2Estate%2Etext payload%2Estate%2Enested.dynamic_structure payload%2Estate%2Enested.variant_discr payload%2Estate%2Enested.size1 payload%2Estate%2Enested.SharedVariant payload%2Estate%2Enested.UInt64].freeze,
    }.freeze,
  }.freeze

  SIZE_PAYLOAD_SUBSTREAMS = {
    'root_tuple' => {
      'source' => %w[payload%2Edoc.s.SharedVariant.size payload%2Edoc.s.String.size payload%2Ed.SharedVariant.size].freeze,
      'library' => %w[payload%2Edoc.s.SharedVariant.size payload%2Edoc.s.String.size payload%2Ed.SharedVariant.size].freeze,
    }.freeze,
    'array_tuple' => {
      'source' => %w[payload%2Edoc.s.SharedVariant.size payload%2Edoc.s.String.size payload%2Ed.SharedVariant.size].freeze,
      'library' => %w[payload%2Edoc.s.SharedVariant.size payload%2Edoc.s.String.size payload%2Ed.SharedVariant.size].freeze,
    }.freeze,
    'ragged_array_tuple' => {
      'source' => %w[payload%2Edoc.s.SharedVariant.size payload%2Edoc.s.String.size payload%2Ed.SharedVariant.size].freeze,
      'library' => %w[payload%2Edoc.s.SharedVariant.size payload%2Edoc.s.String.size payload%2Ed.SharedVariant.size].freeze,
    }.freeze,
    'lc_bulk_tuple' => {
      'source' => %w[payload%2Edoc.s.SharedVariant.size payload%2Edoc.s.String.size payload%2Estate%2Ed.SharedVariant.size payload%2Estate%2Etext.size payload%2Estate%2Enested.SharedVariant.size].freeze,
      'library' => %w[payload%2Edoc.s.SharedVariant.size payload%2Edoc.s.String.size payload%2Estate%2Ed.SharedVariant.size payload%2Estate%2Etext.size payload%2Estate%2Enested.SharedVariant.size].freeze,
    }.freeze,
  }.freeze

  def self.doc(index)
    {'t' => index, 's' => "json-#{index}"}.freeze
  end

  def self.element(index, dynamic_value)
    {'doc' => doc(index), 'd' => dynamic_value}.freeze
  end

  def self.state_record(index, label, dynamic_value, text, nested)
    {'doc' => doc(index),
     'state' => {'label' => label, 'd' => dynamic_value, 'text' => text, 'nested' => nested}.freeze}.freeze
  end

  ROOT_VALUES = [nil, nil, 7, 'spill-a', 0, nil, 'spill-b', 99].freeze
  ROOT_ROWS = ROOT_VALUES.each_with_index.map { |value, i| {'doc' => doc(i + 1), 'd' => value}.freeze }.freeze
  ARRAY_ROWS = [
    [], [], [element(3, 7)], [element(4, 'spill-a')], [],
    [element(6, nil), element(6, 0)], [element(7, 'spill-b')], [],
  ].freeze
  RAGGED_ROWS = [
    [], [], [[], [element(3, 7)]], [[element(4, 'spill-a')]],
    [[], []], [[element(6, nil), element(6, 0)]], [[element(7, 'spill-b')]], [],
  ].freeze
  LC_BULK_ROWS = [
    [], [],
    [state_record(3, 'red', 7, 'text-a', [12, nil])],
    [state_record(4, 'blue', 'spill-a', 'text-b', [13])],
    [],
    [state_record(6, 'red', nil, 'text-c', []), state_record(6, 'green', 0, 'text-d', [14, 'spill-nested-b'])],
    [state_record(7, 'blue', 'spill-b', 'text-e', [15])], [],
  ].freeze
  FIXTURES = {
    'root_tuple' => ROOT_ROWS,
    'array_tuple' => ARRAY_ROWS,
    'ragged_array_tuple' => RAGGED_ROWS,
    'lc_bulk_tuple' => LC_BULK_ROWS,
  }.freeze

  # The native oracle is origin-specific: ClickHouse may promote the ordinary
  # arm while inserting, whereas the library writer is given UInt64 explicitly.
  # These recursive Tuple-site fixtures align with the W203 Nested/tuple
  # controls; they do not use the distinct Array(Dynamic) ordinary-arm rule.
  ORDINARY_DYNAMIC_TYPE = {
    'source' => CASE_IDS.to_h { |case_id| [case_id, 'UInt64'] }.freeze,
    'library' => CASE_IDS.to_h { |case_id| [case_id, 'UInt64'] }.freeze,
  }.freeze

  SETTINGS = [
    'index_granularity=2', 'index_granularity_bytes=10485760',
    'enable_mixed_granularity_parts=1', 'min_rows_for_wide_part=0',
    'min_bytes_for_wide_part=0', 'compress_marks=0', 'compress_primary_key=0',
    'min_compress_block_size=0', 'max_compress_block_size=4096',
    'ratio_of_defaults_for_sparse_serialization=1', "default_compression_codec='LZ4'",
    "serialization_info_version='with_types'", 'propagate_types_serialization_versions_to_nested_types=true',
    "object_serialization_version='v3'", "object_shared_data_serialization_version_for_zero_level_parts='map'",
    "map_serialization_version='basic'", "map_serialization_version_for_zero_level_parts='basic'",
    'use_compact_variant_discriminators_serialization=0', "dynamic_serialization_version='v3'",
  ].join(', ').freeze

  def self.type_for(case_id)
    case case_id
    when 'root_tuple' then TUPLE_TYPE
    when 'array_tuple' then ARRAY_TUPLE_TYPE
    when 'ragged_array_tuple' then RAGGED_ARRAY_TUPLE_TYPE
    when 'lc_bulk_tuple' then LC_BULK_TUPLE_TYPE
    else raise "unknown W204 case #{case_id.inspect}"
    end
  end

  def self.expected_payload_substreams(case_id, profile, origin)
    names = BASE_PAYLOAD_SUBSTREAMS.fetch(case_id).fetch(origin).dup
    names.concat(SIZE_PAYLOAD_SUBSTREAMS.fetch(case_id).fetch(origin)) if profile == 'with_size_stream'
    names.sort
  end

  def self.table(case_id, profile, origin)
    "#{origin}_#{case_id}_#{profile}"
  end

  def self.sql_quote(value)
    "'#{value.to_s.gsub(/[\\']/) { |character| "\\#{character}" }}'"
  end

  def self.json_sql(value)
    "CAST(#{sql_quote(JSON.generate(value))}, #{sql_quote(JSON_TYPE)})"
  end

  def self.dynamic_sql(value)
    inner = if value.nil?
              'NULL'
            elsif value.is_a?(Integer)
              "toUInt64(#{value})"
            else
              sql_quote(value)
            end
    "CAST(#{inner}, #{sql_quote(DYNAMIC)})"
  end

  def self.tuple_sql(value)
    "CAST(tuple(#{json_sql(value.fetch('doc'))}, #{dynamic_sql(value.fetch('d'))}), #{sql_quote(TUPLE_TYPE)})"
  end

  def self.bulk_state_sql(value)
    state = value.fetch('state')
    label = "CAST(#{sql_quote(state.fetch('label'))}, 'LowCardinality(String)')"
    nested_type = "Array(#{DYNAMIC})"
    nested = state.fetch('nested').map { |item| dynamic_sql(item) }
    nested_array = "CAST([#{nested.join(', ')}], #{sql_quote(nested_type)})"
    state_tuple = "CAST(tuple(#{label}, #{dynamic_sql(state.fetch('d'))}, #{sql_quote(state.fetch('text'))}, #{nested_array}), #{sql_quote(BULK_STATE_TYPE)})"
    "CAST(tuple(#{json_sql(value.fetch('doc'))}, #{state_tuple}), #{sql_quote("Tuple(doc #{JSON_TYPE}, state #{BULK_STATE_TYPE})")})"
  end

  def self.value_sql(case_id, value)
    case case_id
    when 'root_tuple'
      tuple_sql(value)
    when 'array_tuple'
      "CAST([#{value.map { |item| tuple_sql(item) }.join(', ')}], #{sql_quote(ARRAY_TUPLE_TYPE)})"
    when 'ragged_array_tuple'
      inner_type = "Array(#{TUPLE_TYPE})"
      inner = value.map { |group| "CAST([#{group.map { |item| tuple_sql(item) }.join(', ')}], #{sql_quote(inner_type)})" }
      "CAST([#{inner.join(', ')}], #{sql_quote(RAGGED_ARRAY_TUPLE_TYPE)})"
    when 'lc_bulk_tuple'
      element_type = "Tuple(doc #{JSON_TYPE}, state #{BULK_STATE_TYPE})"
      elements = value.map { |item| bulk_state_sql(item) }
      "CAST([#{elements.join(', ')}], #{sql_quote(LC_BULK_TUPLE_TYPE)})"
    else
      raise "unknown W204 case #{case_id.inspect}"
    end
  end

  def self.value_sql_rows(case_id)
    FIXTURES.fetch(case_id).each_with_index.map do |value, index|
      "(#{index + 1}, #{value_sql(case_id, value)})"
    end
  end

  def self.dynamic_state_sql(expression)
    "if(isNull(#{expression}), 'NULL', concat(dynamicType(#{expression}), ':', toString(toUInt8(isDynamicElementInSharedData(#{expression})))))"
  end

  def self.dynamic_state_expressions(case_id)
    empty_array = "CAST([], 'Array(String)')"
    case case_id
    when 'root_tuple'
      [dynamic_state_sql('tupleElement(payload, 2)'), empty_array]
    when 'array_tuple'
      state = dynamic_state_sql('tupleElement(x, 2)')
      ["arrayMap(x -> #{state}, payload)", empty_array]
    when 'ragged_array_tuple'
      state = dynamic_state_sql('tupleElement(y, 2)')
      ["arrayMap(x -> arrayMap(y -> #{state}, x), payload)", empty_array]
    when 'lc_bulk_tuple'
      direct_state = dynamic_state_sql('tupleElement(tupleElement(y, 2), 2)')
      nested_state = dynamic_state_sql('z')
      direct = "arrayMap(y -> #{direct_state}, payload)"
      nested = "arrayMap(y -> arrayMap(z -> #{nested_state}, tupleElement(tupleElement(y, 2), 4)), payload)"
      [direct, nested]
    else
      raise "unknown W204 case #{case_id.inspect}"
    end
  end

  def self.expected_state(value, ordinary_type)
    return 'NULL' if value.nil?
    actual = value.is_a?(Integer) ? 'UInt64' : 'String'
    "#{actual}:#{actual == ordinary_type ? 0 : 1}"
  end

  def self.expected_states(case_id, value, ordinary_type)
    case case_id
    when 'root_tuple'
      [expected_state(value.fetch('d'), ordinary_type), []]
    when 'array_tuple'
      [value.map { |item| expected_state(item.fetch('d'), ordinary_type) }, []]
    when 'ragged_array_tuple'
      [value.map { |group| group.map { |item| expected_state(item.fetch('d'), ordinary_type) } }, []]
    when 'lc_bulk_tuple'
      direct = value.map { |item| expected_state(item.fetch('state').fetch('d'), ordinary_type) }
      nested = value.map { |item| item.fetch('state').fetch('nested').map { |child| expected_state(child, ordinary_type) } }
      [direct, nested]
    else
      raise "unknown W204 case #{case_id.inspect}"
    end
  end

  def self.helper_dynamic(value)
    return nil if value.nil?
    {'type' => (value.is_a?(Integer) ? 'UInt64' : 'String'), 'value' => value}
  end

  def self.helper_value(case_id, value)
    case case_id
    when 'root_tuple'
      {'doc' => value.fetch('doc'), 'd' => helper_dynamic(value.fetch('d'))}
    when 'array_tuple'
      value.map { |item| helper_value('root_tuple', item) }
    when 'ragged_array_tuple'
      value.map { |group| group.map { |item| helper_value('root_tuple', item) } }
    when 'lc_bulk_tuple'
      value.map do |item|
        state = item.fetch('state')
        {'doc' => item.fetch('doc'),
         'state' => {'label' => state.fetch('label'), 'd' => helper_dynamic(state.fetch('d')),
                     'text' => state.fetch('text'), 'nested' => state.fetch('nested').map { |child| helper_dynamic(child) }}}
      end
    else
      raise "unknown W204 case #{case_id.inspect}"
    end
  end

  def self.helper_rows(case_id, row_indexes)
    row_indexes.map { |index| [(index + 1).to_s, helper_value(case_id, FIXTURES.fetch(case_id).fetch(index))] }
  end

  def self.sql_value_windows(table_name, case_id, profile)
    states = dynamic_state_expressions(case_id)
    windows = {
      'FULL' => '', 'FIRST_EMPTY' => ' WHERE pk BETWEEN 1 AND 2',
      'LATER' => ' WHERE pk BETWEEN 3 AND 4', 'MIDDLE' => ' WHERE pk BETWEEN 5 AND 6',
      'FINAL' => ' WHERE pk BETWEEN 7 AND 8', 'ZERO' => ' WHERE pk > 8',
    }
    windows.flat_map do |window, predicate|
      tag = "__W204_VALUES_#{window}__"
      query = "SELECT '#{tag}', '#{table_name}', toString(pk), hex(toJSONString(payload)), toTypeName(payload), " \
              "hex(toJSONString(#{states[0]})), hex(toJSONString(#{states[1]})) " \
              "FROM default.#{table_name}#{predicate} ORDER BY pk SETTINGS print_pretty_type_names=0 FORMAT TSVRaw;"
      if window == 'ZERO'
        ["SELECT '__W204_ZERO_BEGIN__', '#{table_name}', '#{case_id}', '#{profile}', 'values' FORMAT TSVRaw;",
         query,
         "SELECT '__W204_ZERO_END__', '#{table_name}', '#{case_id}', '#{profile}', 'values' FORMAT TSVRaw;"]
      else
        [query]
      end
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
      @roster_evidence = {}
      @fatal_error = nil
    end

    def run
      prepare_layout!
      @binary_sha_before = binary_sha
      fail!('pinned ClickHouse executable SHA-256 mismatch before probe') unless @binary_sha_before == BINARY_SHA256
      @helper_sha_before = helper_sha
      fail!('prebuilt Crystal helper SHA changed before probe') unless @helper_sha_before == helper_sha

      initial = run_clickhouse('native_sources', initial_sql)
      assert_native_invocation!(initial)
      native = parse_native(initial[:stdout])
      assert_pin!(native)
      assert_initial_native!(native)

      helper_input = build_helper_input
      input_path = File.join(@root, 'generated', 'helper-input.json')
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

      @source_parts.each do |key, path|
        fail!("stock source part changed during ATTACH/SELECT: #{key.join('/')}") unless snapshot_part(path) == @source_snapshots.fetch(key)
      end
      @library_parts.each do |key, path|
        fail!("published library part changed during ATTACH/SELECT: #{key.join('/')}") unless snapshot_part(path) == @library_snapshots.fetch(key)
      end
      @binary_sha_after = binary_sha
      @helper_sha_after = helper_sha
      fail!('pinned ClickHouse executable SHA changed during probe') unless @binary_sha_after == BINARY_SHA256
      fail!('prebuilt Crystal helper SHA changed during probe') unless @helper_sha_after == @helper_sha_before

      write_evidence(status: 'paired_recursive_json_dynamic_observed', source: native,
                     helper: helper[:data], helper_invocation: helper[:record],
                     initial_invocation: initial[:record], attached: attached_native,
                     attached_invocation: attached[:record])
      puts "W204 recursive JSON/Dynamic parts cases=#{CASE_IDS.size} profiles=#{PROFILE_IDS.size}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @binary_sha_after = binary_sha rescue nil
      @helper_sha_after = helper_sha rescue nil
      write_evidence(status: 'runner_failure_or_observations_differ', fatal_error: @fatal_error) rescue nil
      warn "W204 probe failure (process failure is not format evidence): #{@fatal_error}"
      false
    end

    private

    def fail!(message)
      raise "W204 recursive JSON/Dynamic oracle: #{message}"
    end

    def prepare_layout!
      %w[invocations inputs stores generated].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
      PROFILE_IDS.each do |profile|
        profile_root = File.join(@root, 'generated', profile)
        Dir.mkdir(profile_root, 0o700)
        CASE_IDS.each { |case_id| Dir.mkdir(File.join(profile_root, case_id), 0o700) }
      end
      CASE_IDS.each do |case_id|
        PROFILE_IDS.each do |profile|
          %w[source library].each do |origin|
            @table_identity[table(case_id, profile, origin)] = [case_id, profile, origin]
          end
        end
      end
    end

    def table(case_id, profile, origin)
      ProbeRecursiveDynamicJSONW204.table(case_id, profile, origin)
    end

    def all_tables
      CASE_IDS.flat_map { |case_id| PROFILE_IDS.flat_map { |profile| %w[source library].map { |origin| table(case_id, profile, origin) } } }
    end

    def source_tables
      CASE_IDS.flat_map { |case_id| PROFILE_IDS.map { |profile| table(case_id, profile, 'source') } }
    end

    def initial_sql
      statements = [
        'SET flatten_nested=0;', 'SET allow_suspicious_low_cardinality_types=1;',
        'SET output_format_json_named_tuples_as_objects=1;', 'SET print_pretty_type_names=0;',
        "SELECT '__W204_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
      ]
      CASE_IDS.each do |case_id|
        type = ProbeRecursiveDynamicJSONW204.type_for(case_id)
        PROFILE_IDS.each do |profile|
          settings = "#{SETTINGS}, string_serialization_version='#{profile}'"
          source = table(case_id, profile, 'source')
          library = table(case_id, profile, 'library')
          [source, library].each do |name|
            statements << "CREATE TABLE default.#{name} (pk UInt64, payload #{type}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings};"
          end
          values = ProbeRecursiveDynamicJSONW204.value_sql_rows(case_id).join(",\n")
          statements << "INSERT INTO default.#{source} VALUES\n#{values};"
          statements << check_sql(source, case_id, profile)
        end
      end
      names = all_tables.map { |name| "'#{name}'" }.join(',')
      statements << "SELECT '__W204_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{names}) ORDER BY table, position FORMAT TSVRaw;"
      statements << "SELECT '__W204_DATA_PATH__', name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name IN (#{names}) ORDER BY name FORMAT TSVRaw;"
      statements << parts_sql(source_tables)
      source_tables.each do |name|
        case_id, = @table_identity.fetch(name)
        statements.concat(ProbeRecursiveDynamicJSONW204.sql_value_windows(name, case_id, @table_identity.fetch(name)[1]))
      end
      statements.join("\n") + "\n"
    end

    def attached_sql
      statements = [
        'SET flatten_nested=0;', 'SET allow_suspicious_low_cardinality_types=1;',
        'SET output_format_json_named_tuples_as_objects=1;', 'SET print_pretty_type_names=0;',
        "SELECT '__W204_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
      ]
      CASE_IDS.each do |case_id|
        PROFILE_IDS.each do |profile|
          target = table(case_id, profile, 'library')
          statements << "ALTER TABLE default.#{target} ATTACH PART 'all_1_1_0';"
          statements << check_sql(table(case_id, profile, 'source'), case_id, profile)
          statements << check_sql(target, case_id, profile)
        end
      end
      names = all_tables.map { |name| "'#{name}'" }.join(',')
      statements << "SELECT '__W204_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{names}) ORDER BY table, position FORMAT TSVRaw;"
      statements << parts_sql(all_tables)
      all_tables.each do |name|
        case_id, = @table_identity.fetch(name)
        statements.concat(ProbeRecursiveDynamicJSONW204.sql_value_windows(name, case_id, @table_identity.fetch(name)[1]))
      end
      statements.join("\n") + "\n"
    end

    def check_sql(table_name, case_id, profile)
      ["SELECT '__W204_CHECK_BEGIN__', '#{table_name}', '#{case_id}', '#{profile}' FORMAT TSVRaw;",
       "CHECK TABLE default.#{table_name} FORMAT TSV;",
       "SELECT '__W204_CHECK_END__', '#{table_name}', '#{case_id}', '#{profile}' FORMAT TSVRaw;"].join("\n")
    end

    def parts_sql(tables)
      names = tables.map { |name| "'#{name}'" }.join(',')
      "SELECT '__W204_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table IN (#{names}) AND active ORDER BY table,name FORMAT TSVRaw;"
    end

    def parse_native(stdout)
      lines = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      records = ->(prefix) { lines.select { |line| line.start_with?("#{prefix}\t") }.map { |line| line.split("\t", -1) } }
      known = %w[__W204_PIN__ __W204_SCHEMA__ __W204_DATA_PATH__ __W204_PART__
                 __W204_CHECK_BEGIN__ __W204_CHECK_END__ __W204_ZERO_BEGIN__ __W204_ZERO_END__] +
        WINDOWS.map { |window| "__W204_VALUES_#{window}__" }
      unknown = lines.each_with_object([]) do |line, tags|
        next unless line.start_with?('__W204_')
        tag = line.split("\t", 2).first
        tags << tag unless known.include?(tag)
      end
      fail!("unknown native marker tags: #{unknown.uniq.inspect}") unless unknown.empty?

      checks = {}
      active = nil
      lines.each do |line|
        if line.start_with?("__W204_CHECK_BEGIN__\t")
          fields = line.split("\t", -1)
          fail!('malformed/nested CHECK begin') unless fields.size == 4 && !active
          active = fields.drop(1)
          fail!('duplicate CHECK block') if checks.key?(active)
          checks[active] = []
        elsif line.start_with?("__W204_CHECK_END__\t")
          fields = line.split("\t", -1)
          fail!('malformed/mismatched CHECK end') unless fields.size == 4 && active == fields.drop(1)
          active = nil
        elsif active
          checks.fetch(active) << line
        end
      end
      fail!('unterminated CHECK block') if active

      pin_rows = records.call('__W204_PIN__')
      fail!('runtime pin must occur exactly once') unless pin_rows.size == 1 && pin_rows.first.size == 3
      schemas = records.call('__W204_SCHEMA__').map do |fields|
        fail!('schema record width differs') unless fields.size == 4
        fields.drop(1)
      end
      path_rows = records.call('__W204_DATA_PATH__')
      fail!('duplicate table data path') unless path_rows.map { |fields| fields[1] }.uniq.size == path_rows.size
      data_paths = path_rows.to_h do |fields|
        fail!('data-path record width differs') unless fields.size == 3
        [fields[1], fields[2]]
      end
      part_rows = records.call('__W204_PART__')
      fail!('duplicate active part record') unless part_rows.map { |fields| fields[1] }.uniq.size == part_rows.size
      parts = part_rows.to_h do |fields|
        fail!('part record width differs') unless fields.size == 7
        [fields[1], {name: fields[2], path: fields[3], type: fields[4], rows: fields[5], marks: fields[6]}]
      end
      value_rows = lines.select { |line| line.start_with?('__W204_VALUES_') }
                        .map { |line| line.split("\t", -1) }
                        .each_with_object({}) do |fields, output|
        fail!('selected-value row width differs') unless fields.size == 7
        window = fields[0].delete_prefix('__W204_VALUES_').delete_suffix('__')
        (output[[fields[1], window]] ||= []) << fields.drop(2)
      end
      zero_events = lines.select { |line| line.start_with?("__W204_ZERO_BEGIN__\t") || line.start_with?("__W204_ZERO_END__\t") }
                         .map { |line| line.split("\t", -1) }
      {pin: lines.find { |line| line.start_with?('__W204_PIN__') }, checks: checks, schemas: schemas,
       data_paths: data_paths, parts: parts, value_rows: value_rows, zero_events: zero_events}
    end

    def assert_pin!(native)
      expected = "__W204_PIN__\t#{VERSION}\t#{BUILD}"
      fail!("runtime version/build differs: #{native[:pin].inspect}") unless native[:pin] == expected
    end

    def expected_schemas
      all_tables.sort.flat_map do |name|
        case_id, = @table_identity.fetch(name)
        [[name, 'pk', 'UInt64'], [name, 'payload', ProbeRecursiveDynamicJSONW204.type_for(case_id)]]
      end
    end

    def assert_initial_native!(native)
      expected_checks = source_tables.to_h do |name|
        case_id, profile, = @table_identity.fetch(name)
        [[name, case_id, profile], ["all_1_1_0\t1\t"]]
      end
      fail!("stock CHECK results differ: #{native[:checks].inspect}") unless native[:checks] == expected_checks
      fail!('stock schema roster differs from exact declarations') unless native[:schemas] == expected_schemas
      fail!('initial data-path roster differs') unless native[:data_paths].keys.sort == all_tables.sort
      native[:data_paths].each_value { |path| validate_store_path!(path) }
      @data_paths = native[:data_paths].dup
      fail!('stock source active part roster differs') unless native[:parts].keys.sort == source_tables.sort
      source_tables.each do |name|
        case_id, profile, = @table_identity.fetch(name)
        part = native[:parts].fetch(name)
        fail!("#{name} is not one eight-row Wide part with four marks plus end sentinel") unless
          part[:name] == 'all_1_1_0' && part[:type] == 'Wide' && part[:rows] == '8' && part[:marks] == '5'
        path = validate_source_part!(part[:path])
        key = [case_id, profile]
        @source_parts[key] = path
        @source_snapshots[key] = snapshot_part(path)
        assert_native_values!(native, name, 'source')
      end
      expected_zero = source_tables.flat_map do |name|
        case_id, profile, = @table_identity.fetch(name)
        [["__W204_ZERO_BEGIN__", name, case_id, profile, 'values'], ["__W204_ZERO_END__", name, case_id, profile, 'values']]
      end
      fail!('stock zero-window boundary roster differs') unless native[:zero_events] == expected_zero
    end

    def assert_attached_native!(native)
      expected_checks = all_tables.to_h do |name|
        case_id, profile, = @table_identity.fetch(name)
        [[name, case_id, profile], ["all_1_1_0\t1\t"]]
      end
      fail!("stock source/attached CHECK results differ: #{native[:checks].inspect}") unless native[:checks] == expected_checks
      fail!('attached schema roster differs') unless native[:schemas] == expected_schemas
      fail!('attached part roster differs') unless native[:parts].keys.sort == all_tables.sort
      all_tables.each do |name|
        case_id, profile, origin = @table_identity.fetch(name)
        part = native[:parts].fetch(name)
        fail!("#{name} part identity/P grid differs") unless
          part[:name] == 'all_1_1_0' && part[:type] == 'Wide' && part[:rows] == '8' && part[:marks] == '5'
        assert_native_values!(native, name, origin)
      end
      expected_zero = all_tables.flat_map do |name|
        case_id, profile, = @table_identity.fetch(name)
        [["__W204_ZERO_BEGIN__", name, case_id, profile, 'values'], ["__W204_ZERO_END__", name, case_id, profile, 'values']]
      end
      fail!('attached zero-window boundary roster differs') unless native[:zero_events] == expected_zero
    end

    def assert_native_values!(native, table_name, origin)
      case_id, = @table_identity.fetch(table_name)
      ordinary = ORDINARY_DYNAMIC_TYPE.fetch(origin).fetch(case_id)
      expected_windows = {
        'FULL' => (0...8).to_a, 'FIRST_EMPTY' => (0...2).to_a,
        'LATER' => (2...4).to_a, 'MIDDLE' => (4...6).to_a,
        'FINAL' => (6...8).to_a, 'ZERO' => [],
      }
      expected_windows.each do |window, indexes|
        actual = native[:value_rows].fetch([table_name, window], [])
        expected = indexes.map do |index|
          value = FIXTURES.fetch(case_id).fetch(index)
          states = ProbeRecursiveDynamicJSONW204.expected_states(case_id, value, ordinary)
          [(index + 1).to_s, value, ProbeRecursiveDynamicJSONW204.type_for(case_id), states[0], states[1]]
        end
        decoded = actual.map do |fields|
          [fields[0], decode_json_hex(fields[1], 'payload'), fields[2],
           decode_json_hex(fields[3], 'direct Dynamic state'), decode_json_hex(fields[4], 'nested Dynamic state')]
        end
        fail!("#{table_name}/#{window} native selected observations differ from independent literals: #{decoded.inspect}") unless decoded == expected
      end
      nonzero_keys = expected_windows.keys.reject { |window| window == 'ZERO' }.map { |window| [table_name, window] }.sort
      fail!("#{table_name} selected-value window roster differs") unless
        native[:value_rows].keys.select { |key| key[0] == table_name }.sort == nonzero_keys
    end

    def decode_json_hex(hex, label)
      fail!("malformed #{label} hex") unless hex.match?(/\A(?:[0-9A-Fa-f]{2})*\z/)
      JSON.parse([hex].pack('H*'))
    rescue JSON::ParserError => error
      fail!("#{label} is not JSON: #{error.message}")
    end

    def build_helper_input
      capture_root = File.realpath(File.join(@root, 'stores', 'native'))
      cases = CASE_IDS.flat_map do |case_id|
        PROFILE_IDS.map do |profile|
          source = table(case_id, profile, 'source')
          {'case_id' => case_id, 'profile_id' => profile, 'capture_root' => capture_root,
           'source_part' => @source_parts.fetch([case_id, profile]),
           'library_part' => File.join(@root, 'generated', profile, case_id, 'all_1_1_0')}
        end
      end
      {'format' => FORMAT_INPUT, 'capture_root' => capture_root, 'cases' => cases}
    end

    def run_helper(input_path)
      before = helper_sha
      fail!('prebuilt helper changed before invocation') unless before == @helper_sha_before
      argv = [@helper, input_path, File.join(@root, 'generated')]
      invocation = @executor.send(:execute_record, 'crystal_helper', argv, ''.b,
                                  'prebuilt Crystal helper', before, @helper)
      fail!('prebuilt helper process failed; not a native format rejection') unless successful?(invocation)
      fail!('prebuilt helper emitted stderr') unless invocation[:stderr].empty?
      fail!('prebuilt helper SHA changed during invocation') unless helper_sha == before
      lines = invocation[:stdout].lines.map(&:chomp).reject(&:empty?)
      fail!('helper must emit exactly one JSON record') unless lines.size == 1
      data = JSON.parse(lines.fetch(0))
      fail!('helper output format differs') unless data['format'] == FORMAT_OUTPUT
      @invocations << invocation[:record]
      {data: data, record: invocation[:record]}
    end

    def assert_helper_output!(data)
      fail!('helper output key/format roster differs') unless
        data.keys.sort == %w[case_ids cases format profile_ids] && data['format'] == FORMAT_OUTPUT
      fail!('helper case/profile roster differs') unless data['case_ids'] == CASE_IDS && data['profile_ids'] == PROFILE_IDS
      expected_keys = CASE_IDS.product(PROFILE_IDS)
      fail!('helper case count/order differs') unless data['cases'].is_a?(Array) && data['cases'].size == expected_keys.size
      data['cases'].zip(expected_keys).each do |result, (case_id, profile)|
        fail!("helper case identity differs for #{case_id}/#{profile}") unless
          result.keys.sort == %w[case_id library_part_path library_reader library_table_rows profile_id schema_declaration stock_reader stock_table_rows] &&
          result['case_id'] == case_id && result['profile_id'] == profile &&
          result['schema_declaration'] == ProbeRecursiveDynamicJSONW204.type_for(case_id)
        expected_path = File.join(@root, 'generated', profile, case_id, 'all_1_1_0')
        fail!("helper part path escaped fixed output for #{case_id}/#{profile}") unless File.expand_path(result['library_part_path']) == expected_path
        part = validate_generated_part!(expected_path, profile, case_id)
        key = [case_id, profile]
        @library_parts[key] = part
        @library_snapshots[key] = snapshot_part(part)

        expected_table_rows = (0...8).map do |index|
          [(index + 1).to_s, ProbeRecursiveDynamicJSONW204.helper_value(case_id, FIXTURES.fetch(case_id).fetch(index))]
        end
        %w[stock_table_rows library_table_rows].each do |field|
          fail!("#{case_id}/#{profile}/#{field} differs from helper literals") unless result[field] == expected_table_rows
        end
        source_reader = result.fetch('stock_reader')
        library_reader = result.fetch('library_reader')
        assert_reader!(source_reader, case_id, profile, 'stock')
        assert_reader!(library_reader, case_id, profile, 'library')
        build_roster_evidence!(case_id, profile, @source_parts.fetch(key), part,
                               {'stock_reader' => source_reader, 'library_reader' => library_reader})
        fail!("#{case_id}/#{profile} reader metadata differs between origins") unless
          source_reader['physical_stream_names'].sort == library_reader['physical_stream_names'].sort &&
          source_reader['selected_checksum_names'].sort == library_reader['selected_checksum_names'].sort
      end
      assert_profile_roster_delta!(data)
    end

    def expected_dynamic_grids(case_id)
      FIXTURES.fetch(case_id).each_slice(2).map do |rows|
        object_count = 0
        direct = 0
        nested = 0
        rows.each do |row|
          case case_id
          when 'root_tuple'
            object_count += 1
            direct += 1
          when 'array_tuple'
            object_count += row.size
            direct += row.size
          when 'ragged_array_tuple'
            count = row.sum(&:size)
            object_count += count
            direct += count
          when 'lc_bulk_tuple'
            object_count += row.size
            direct += row.size
            nested += row.sum { |item| item.fetch('state').fetch('nested').size }
          end
        end
        [object_count, direct, nested]
      end
    end

    def expected_structural_site_grids(case_id)
      entries = case case_id
                when 'root_tuple' then ['root/tuple[1]::root']
                when 'array_tuple' then ['root/array[0]/tuple[1]::root']
                when 'ragged_array_tuple' then ['root/array[0]/array[0]/tuple[1]::root']
                when 'lc_bulk_tuple'
                  ['root/array[0]/tuple[1]::root.field.1', 'root/array[0]/tuple[1]::root.field.3.elements']
                end
      expected_dynamic_grids(case_id).map do |_objects, direct, nested|
        values = [direct] + (case_id == 'lc_bulk_tuple' ? [nested] : [])
        entries.zip(values).to_h
      end
    end

    def expected_reader_windows(case_id)
      marks = (0...8).each_slice(2).map { |indexes| ProbeRecursiveDynamicJSONW204.helper_rows(case_id, indexes) }
      {'full' => marks, 'first' => marks[0, 1], 'later' => marks[1, 1], 'middle' => marks[2, 1],
       'final' => marks[3, 1], 'end_zero' => []}
    end

    def assert_reader!(reader, case_id, profile, origin)
      expected_keys = %w[schema_declaration source_declaration row_count mark_row_counts dynamic_site_keys physical_stream_names selected_checksum_names occurrence_counts_by_parent_mark dynamic_site_occurrences_by_parent_mark windows]
      fail!("#{case_id}/#{profile}/#{origin} reader result fields differ") unless reader.keys.sort == expected_keys.sort
      type = ProbeRecursiveDynamicJSONW204.type_for(case_id)
      fail!("#{case_id}/#{profile}/#{origin} schema/P grid differs") unless
        reader['schema_declaration'] == type && reader['source_declaration'] == type &&
        reader['row_count'] == 8 && reader['mark_row_counts'] == [2, 2, 2, 2]
      fail!("#{case_id}/#{profile}/#{origin} object/Dynamic Q grid differs") unless
        reader['occurrence_counts_by_parent_mark'] == expected_dynamic_grids(case_id).map { |objects, direct, nested| {'object' => objects, 'dynamic' => direct + nested} }
      fail!("#{case_id}/#{profile}/#{origin} per-site Dynamic Q grid differs") unless
        reader['dynamic_site_occurrences_by_parent_mark'] == expected_structural_site_grids(case_id)
      expected_sites = case case_id
                       when 'root_tuple' then ['root/tuple[1]']
                       when 'array_tuple' then ['root/array[0]/tuple[1]']
                       when 'ragged_array_tuple' then ['root/array[0]/array[0]/tuple[1]']
                       when 'lc_bulk_tuple' then ['root/array[0]/tuple[1]']
                       end
      fail!("#{case_id}/#{profile}/#{origin} structural site roster differs") unless reader['dynamic_site_keys'] == expected_sites
      streams = reader['physical_stream_names']
      checksums = reader['selected_checksum_names']
      fail!("#{case_id}/#{profile}/#{origin} stream/checksum roster empty or duplicated") unless
        streams.is_a?(Array) && !streams.empty? && streams.uniq == streams &&
        checksums.is_a?(Array) && !checksums.empty? && checksums.uniq == checksums
      origin_key = origin == 'stock' ? 'source' : 'library'
      expected_streams = ProbeRecursiveDynamicJSONW204.expected_payload_substreams(case_id, profile, origin_key)
      fail!("#{case_id}/#{profile}/#{origin} physical roster differs from independent literal") unless
        streams.sort == expected_streams
      case case_id
      when 'array_tuple', 'ragged_array_tuple', 'lc_bulk_tuple'
        fail!("#{case_id}/#{profile}/#{origin} inherited outer size0 lane differs") unless streams.include?('payload.size0')
      end
      if case_id == 'ragged_array_tuple'
        fail!("#{case_id}/#{profile}/#{origin} inherited ragged size1 lane differs") unless streams.include?('payload.size1')
      elsif case_id == 'lc_bulk_tuple'
        fail!("#{case_id}/#{profile}/#{origin} nested Dynamic Array size1 lane differs") unless
          streams.include?('payload%2Estate%2Enested.size1')
      end
      fail!("#{case_id}/#{profile}/#{origin} parent read windows differ") unless reader['windows'] == expected_reader_windows(case_id)
      expected = [2, 2, 2, 2]
      fail!("#{case_id}/#{profile}/#{origin} P mark window roster differs") unless expected.sum == 8
    end

    def assert_profile_roster_delta!(data)
      CASE_IDS.each do |case_id|
        pair = PROFILE_IDS.map { |profile| data['cases'].find { |entry| entry['case_id'] == case_id && entry['profile_id'] == profile } }
        %w[stock_reader library_reader].each do |consumer|
          one = pair[0].fetch(consumer).fetch('physical_stream_names').sort
          sized = pair[1].fetch(consumer).fetch('physical_stream_names').sort
          added = sized - one
          removed = one - sized
          fail!("#{case_id}/#{consumer} String profile did not add size lanes") if added.empty?
          fail!("#{case_id}/#{consumer} String profile changed non-size physical names") unless
            (added + removed).all? { |name| name.end_with?('.size') }
        end
      end
    end

    def attach_library_parts!
      CASE_IDS.each do |case_id|
        PROFILE_IDS.each do |profile|
          path = @library_parts.fetch([case_id, profile])
          table_name = table(case_id, profile, 'library')
          @executor.send(:attach_part!, path, validate_store_path!(@data_paths.fetch(table_name)))
        end
      end
    end

    def validate_generated_part!(path, profile, case_id)
      expected_parent = File.join(@root, 'generated', profile, case_id)
      full = File.expand_path(path)
      fail!('generated library path escaped its profile directory') unless File.dirname(full) == expected_parent
      fail!('generated library part absent or noncanonical') unless File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full
      validate_plain_tree!(full)
      full
    end

    def validate_plain_tree!(path)
      Find.find(path) do |entry|
        stat = File.lstat(entry)
        fail!("symlink in part tree: #{entry}") if stat.symlink?
        fail!("non-regular part tree entry: #{entry}") unless stat.directory? || stat.file?
      end
      true
    end

    def snapshot_part(path)
      validate_plain_tree!(path)
      Find.find(path).sort.each_with_object({}) do |entry, output|
        next if entry == path
        relative = entry.delete_prefix(path + File::SEPARATOR)
        stat = File.lstat(entry)
        output[relative] = if stat.directory?
                             {type: 'directory'}
                           else
                             {type: 'file', size: stat.size, sha256: Digest::SHA256.file(entry).hexdigest}
                           end
      end
    end

    def parse_substreams(part_path, label)
      manifest = File.join(part_path, 'columns_substreams.txt')
      stat = File.lstat(manifest)
      fail!("#{label} substream manifest is not a bounded plain file") unless stat.file? && !stat.symlink? && stat.size <= MAX_COLUMNS_SUBSTREAMS_BYTES
      text = File.binread(manifest, MAX_COLUMNS_SUBSTREAMS_BYTES + 1).force_encoding(Encoding::UTF_8)
      fail!("#{label} substream manifest is not UTF-8") unless text.valid_encoding?
      parse_substream_manifest(text, label)
    rescue ArgumentError => error
      fail!("#{label} manifest count invalid: #{error.message}")
    end

    def parse_substream_manifest(text, label)
      lines = text.lines.map(&:chomp)
      fail!("#{label} manifest header differs") unless lines.shift == 'columns substreams version: 1'
      count_line = lines.shift
      count_match = count_line && /\A([1-9][0-9]*) columns?:\z/.match(count_line)
      fail!("#{label} manifest column count differs") unless count_match
      declared_column_count = Integer(count_match[1], 10)
      columns = {}
      until lines.empty?
        match = /\A([1-9][0-9]*) substreams for column `([^`]+)`:\z/.match(lines.shift)
        fail!("#{label} substream block malformed") unless match
        count = Integer(match[1], 10)
        column = match[2]
        fail!("#{label} repeated manifest column") if columns.key?(column)
        fail!("#{label} truncated substream block") if lines.size < count
        names = lines.shift(count).map do |line|
          name = /\A\t([^\t\r\n]+)\z/.match(line)
          fail!("#{label} malformed substream name") unless name
          name[1]
        end
        fail!("#{label} repeated substream name") unless names.uniq == names
        columns[column] = names
      end
      fail!("#{label} manifest declared column count differs from parsed blocks") unless columns.size == declared_column_count
      fail!("#{label} manifest columns differ") unless columns.keys.sort == %w[payload pk]
      fail!("#{label} primary-key manifest differs") unless columns.fetch('pk') == ['pk']
      columns.fetch('payload').sort
    end

    def build_roster_evidence!(case_id, profile, source_part, library_part, readers)
      source_names = parse_substreams(source_part, "#{case_id}/#{profile}/stock")
      library_names = parse_substreams(library_part, "#{case_id}/#{profile}/library")
      expected_source = ProbeRecursiveDynamicJSONW204.expected_payload_substreams(case_id, profile, 'source')
      expected_library = ProbeRecursiveDynamicJSONW204.expected_payload_substreams(case_id, profile, 'library')
      fail!("#{case_id}/#{profile} stock columns_substreams differs from independent literal") unless source_names == expected_source
      fail!("#{case_id}/#{profile} library columns_substreams differs from independent literal") unless library_names == expected_library
      {'stock_reader' => expected_source, 'library_reader' => expected_library}.each do |name, expected_names|
        fail!("#{case_id}/#{profile}/#{name} differs from literal columns_substreams roster") unless
          readers.fetch(name).fetch('physical_stream_names').sort == expected_names
      end
      stream_files = Dir.children(source_part).select { |name| name.end_with?('.bin') || name.end_with?('.mrk2') }
      fail!("#{case_id}/#{profile} malformed hashed stream filename") unless stream_files.all? { |name| /\A[0-9a-f]{32}\.(?:bin|mrk2)\z/.match?(name) }
      binary = stream_files.grep(/\.bin\z/).map { |name| name.delete_suffix('.bin') }.sort
      marks = stream_files.grep(/\.mrk2\z/).map { |name| name.delete_suffix('.mrk2') }.sort
      expected_file_count = source_names.size + 1 # payload lanes plus the fixed pk lane
      fail!("#{case_id}/#{profile} stream file names/count differ from manifest") unless
        binary.size == expected_file_count && marks.size == expected_file_count && binary == marks && binary.uniq == binary
      @roster_evidence[[case_id, profile]] = {
        stock_payload_substreams: source_names, library_payload_substreams: library_names,
        hashed_stream_stems: binary,
      }
    end

    def write_evidence(data)
      summary = {
        probe: 'W204 mixed recursive JSON and JSON-free Dynamic complete parts',
        status: data[:status], fatal_error: data[:fatal_error],
        source_archive: {path: '/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1-ef037e60', audited_commit: SOURCE_ARCHIVE_COMMIT,
                         disclaimer: 'read-only source archive; not the native runtime'},
        runtime: {path: @binary, expected_sha256: BINARY_SHA256, sha256_before: @binary_sha_before,
                  sha256_after: @binary_sha_after, expected_version: VERSION, expected_build: BUILD},
        helper: {path: @helper, sha256_before: @helper_sha_before, sha256_after: @helper_sha_after},
        limits: {max_threads: 1, local_max_memory_usage_bytes: MEMORY,
                 required_outer_run_safe_memory_limit_bytes: OUTER_RUN_SAFE_LIMIT,
                 timeout_seconds: TIMEOUT, termination_grace_seconds: GRACE},
        cases: CASE_IDS, profiles: PROFILE_IDS, evidence_root: @root,
        helper_input: @helper_input, invocations: @invocations, roster_evidence: @roster_evidence,
      }.merge(data.reject { |key, _| %i[status fatal_error].include?(key) })
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      write_new(File.join(@root, 'summary.md'), [
        '# W204 recursive JSON/Dynamic complete-part probe', '',
        "Status: `#{summary[:status]}`", '',
        'Scope: four finite mixed Tuple/Array carriers, two String profiles, JSON Object MAP, Dynamic V3 BASIC; no JSON actual or Variant actual is stored inside Dynamic. Sparse and empty occurrences are tested within these carriers, but there is no whole-part all-zero-Q carrier. Native CHECK is supplementary; independent literal SELECT observations and matching physical manifests are the semantic oracle.', '',
        "Source archive commit: `#{SOURCE_ARCHIVE_COMMIT}` (not runtime).", "Runtime: #{VERSION} / #{BUILD} / SHA256 `#{BINARY_SHA256}`.",
        "Evidence root: `#{@root}`", '',
      ].join("\n"))
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    if ARGV == ['--self-test']
      unless ProbeRecursiveDynamicJSONW204::CASE_IDS.size == 4 && ProbeRecursiveDynamicJSONW204::PROFILE_IDS.size == 2
        raise 'W204 finite carrier/profile matrix changed'
      end
      ProbeRecursiveDynamicJSONW204::CASE_IDS.each do |case_id|
        raise "W204 fixture row count changed: #{case_id}" unless ProbeRecursiveDynamicJSONW204::FIXTURES.fetch(case_id).size == 8
      end
      parser = ProbeRecursiveDynamicJSONW204::Probe.allocate
      valid_manifest = "columns substreams version: 1\n2 columns:\n1 substreams for column `payload`:\n\tpayload.s.dynamic_structure\n1 substreams for column `pk`:\n\tpk\n"
      parsed = parser.send(:parse_substream_manifest, valid_manifest, 'self-test')
      raise 'W204 valid manifest parser regression' unless parsed == ['payload.s.dynamic_structure']
      begin
        parser.send(:parse_substream_manifest, valid_manifest.sub('2 columns:', '99 columns:'), 'self-test')
      rescue RuntimeError => error
        raise unless error.message.include?('manifest declared column count differs from parsed blocks')
      else
        raise 'W204 manifest parser accepted an incorrect declared column count'
      end
      puts 'W204 Ruby fixture self-test passed'
      exit 0
    end
    options = {binary: ProbeRecursiveDynamicJSONW204::BINARY, helper: nil, root: nil}
    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby scripts/probe_recursive_dynamic_json_w204.rb --crystal-helper PREBUILT --evidence-root EMPTY_/private/tmp_CHILD [--clickhouse PINNED]'
      parser.on('--clickhouse PATH', 'Pinned ClickHouse 26.10.1.1201 executable') { |value| options[:binary] = value }
      parser.on('--crystal-helper PATH', 'Prebuilt Crystal helper; this runner never compiles it') { |value| options[:helper] = value }
      parser.on('--evidence-root PATH', 'Existing empty direct child of /private/tmp') { |value| options[:root] = value }
    end.parse!
    abort 'W204: --crystal-helper and --evidence-root are required' unless options[:helper] && options[:root]
    exit(ProbeRecursiveDynamicJSONW204::Probe.new(options[:binary], options[:helper], options[:root]).run ? 0 : 1)
  rescue StandardError => error
    warn "W204 runner error: #{error.class}: #{error.message}"
    exit 1
  end
end
