#!/usr/bin/env ruby
# Bounded, root-run stock/library ATTACH qualification for recursive Dynamic
# complete parts. This script uses supplied pinned executables only: it never
# starts a compiler or builds ClickHouse. The Ruby literals below are the stock
# oracle and are intentionally independent of the Crystal fixture.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require_relative 'probe_nested_bulk_part_w202'

module ProbeDynamicBulkPartW203
  W202 = ProbeNestedBulkPartW202
  W185 = W202::W185

  BINARY = W202::BINARY
  BINARY_SHA256 = W202::BINARY_SHA256
  VERSION = W202::VERSION
  BUILD = W202::BUILD
  MEMORY = W202::MEMORY
  TIMEOUT = W202::TIMEOUT
  GRACE = W202::GRACE
  OUTER_RUN_SAFE_LIMIT = W202::OUTER_RUN_SAFE_LIMIT

  FORMAT_INPUT = 'dynamic_bulk_part_w203_input_v1'.freeze
  FORMAT_OUTPUT = 'dynamic_bulk_part_w203_helper_v1'.freeze
  PROFILE_IDS = %w[single_stream with_size_stream].freeze
  CASE_IDS = %w[root_dynamic array_dynamic tuple_dynamic nested_dynamic dynamic_tuple_dynamic].freeze
  WINDOWS = %w[FULL FIRST_EMPTY MARK_1 MARK_2 FINAL ZERO].freeze
  DYNAMIC = 'Dynamic(max_types=1)'.freeze
  UINT64 = 'UInt64'.freeze
  STRING = 'String'.freeze
  VARIANT = 'Variant(String, UInt64)'.freeze
  NESTED = 'Nested(label LowCardinality(Nullable(String)), choice Variant(String, UInt64), d Dynamic(max_types=1), text String)'.freeze
  INNER_TUPLE = 'Tuple(Dynamic(max_types=1))'.freeze
  MAX_COLUMNS_SUBSTREAMS_BYTES = 1_048_576

  # Each row is a plain Ruby literal model. It is used only by the independent
  # stock SQL generator and expected observations, never populated from the
  # Crystal helper's output.
  FIXTURES = {
    'root_dynamic' => [nil, nil, 7, 'root-spill-a', 0, 'root-spill-b', 99, 'root-spill-c'].freeze,
    'array_dynamic' => [[], [], [7, 'array-spill-a'], [nil], [0, 42, 'array-spill-b'], [], ['array-spill-c'], [99, nil]].freeze,
    'tuple_dynamic' => [
      [nil, 'first-null'], [nil, 'second-null'], [7, 'ordinary'], ['tuple-spill-a', 'shared'],
      [0, 'zero'], [nil, 'null-again'], ['tuple-spill-b', 'novel'], [99, 'last'],
    ].freeze,
    'nested_dynamic' => [
      [], [],
      [[nil, [:string, 'after-empty'], 7, 'a'], ['x', [:uint64, 701], 'nested-spill-a', 'num-first'], ['x', [:null, nil], 9, 'third']],
      [['x', [:string, 'repeat'], 11, 'repeat']],
      [],
      [['', [:uint64, 0], 0, 'default-label'], [nil, [:uint64, 42], 'nested-spill-b', 'null-label']],
      [['novel', [:string, 'last'], 'nested-spill-c', 'final']],
      [['x', [:uint64, 999], 99, 'final-num'], ['x', [:null, nil], nil, 'tail'], ['novel', [:string, 'repeat'], 10, 'repeat']],
    ].freeze,
    'dynamic_tuple_dynamic' => [
      nil, nil, [:tuple, 7], [:tuple, 'inner-spill-a'], 'outer-spill', [:tuple, nil],
      [:tuple, 99], [:tuple, 'inner-spill-b'],
    ].freeze,
  }.freeze

  STATIC_STRING_COUNTS = {
    'root_dynamic' => 0,
    'array_dynamic' => 0,
    'tuple_dynamic' => 1,
    # The LowCardinality(String) dictionary is not a profile-controlled String
    # lane. Only Variant(String) and the trailing String field contribute here.
    'nested_dynamic' => 2,
    'dynamic_tuple_dynamic' => 0,
  }.freeze

  # Independent fixture law: stock chooses String as Array(Dynamic)'s
  # ordinary arm here; the library writer uses its explicit UInt64 roster.
  DYNAMIC_ORDINARY_STRING_SITES = {
    'source' => {'array_dynamic' => 1}.freeze,
    'library' => {}.freeze,
  }.freeze

  # Fixed W203 role roster authored independently from the Crystal plan. These
  # are logical occurrence roles, not names queried from the helper. A profile
  # adds exactly the String size roles listed separately below.
  BASE_LOGICAL_ROLES = {
    'root_dynamic' => {
      'source' => %w[root.discriminators root.arm.0.data root.arm.1.data root.dynamic_structure].freeze,
      'library' => %w[root.discriminators root.arm.0.data root.arm.1.data root.dynamic_structure].freeze,
    }.freeze,
    'array_dynamic' => {
      'source' => %w[root.sizes root.elements.discriminators root.elements.arm.0.data root.elements.arm.1.data root.elements.dynamic_structure].freeze,
      'library' => %w[root.sizes root.elements.discriminators root.elements.arm.0.data root.elements.arm.1.data root.elements.dynamic_structure].freeze,
    }.freeze,
    'tuple_dynamic' => {
      'source' => %w[root.field.0.discriminators root.field.0.arm.0.data root.field.0.arm.1.data root.field.0.dynamic_structure root.field.1.data].freeze,
      'library' => %w[root.field.0.discriminators root.field.0.arm.0.data root.field.0.arm.1.data root.field.0.dynamic_structure root.field.1.data].freeze,
    }.freeze,
    'nested_dynamic' => {
      'source' => %w[root.sizes root.elements.field.0.dictionary root.elements.field.0.indexes root.elements.field.1.discriminators root.elements.field.1.arm.0.data root.elements.field.1.arm.1.data root.elements.field.2.discriminators root.elements.field.2.arm.0.data root.elements.field.2.arm.1.data root.elements.field.2.dynamic_structure root.elements.field.3.data].freeze,
      'library' => %w[root.sizes root.elements.field.0.dictionary root.elements.field.0.indexes root.elements.field.1.discriminators root.elements.field.1.arm.0.data root.elements.field.1.arm.1.data root.elements.field.2.discriminators root.elements.field.2.arm.0.data root.elements.field.2.arm.1.data root.elements.field.2.dynamic_structure root.elements.field.3.data].freeze,
    }.freeze,
    'dynamic_tuple_dynamic' => {
      'source' => %w[root.discriminators root.arm.0.data root.arm.1.field.0.discriminators root.arm.1.field.0.arm.0.data root.arm.1.field.0.arm.1.data root.arm.1.field.0.dynamic_structure root.dynamic_structure].freeze,
      'library' => %w[root.discriminators root.arm.0.data root.arm.1.field.0.discriminators root.arm.1.field.0.arm.0.data root.arm.1.field.0.arm.1.data root.arm.1.field.0.dynamic_structure root.dynamic_structure].freeze,
    }.freeze,
  }.freeze

  SIZE_LOGICAL_ROLES = {
    'root_dynamic' => {
      'source' => %w[root.arm.0.string_sizes].freeze,
      'library' => %w[root.arm.0.string_sizes].freeze,
    }.freeze,
    'array_dynamic' => {
      'source' => %w[root.elements.arm.0.string_sizes root.elements.arm.1.string_sizes].freeze,
      'library' => %w[root.elements.arm.0.string_sizes].freeze,
    }.freeze,
    'tuple_dynamic' => {
      'source' => %w[root.field.0.arm.0.string_sizes root.field.1.string_sizes].freeze,
      'library' => %w[root.field.0.arm.0.string_sizes root.field.1.string_sizes].freeze,
    }.freeze,
    'nested_dynamic' => {
      'source' => %w[root.elements.field.1.arm.0.string_sizes root.elements.field.2.arm.0.string_sizes root.elements.field.3.string_sizes].freeze,
      'library' => %w[root.elements.field.1.arm.0.string_sizes root.elements.field.2.arm.0.string_sizes root.elements.field.3.string_sizes].freeze,
    }.freeze,
    'dynamic_tuple_dynamic' => {
      'source' => %w[root.arm.0.string_sizes root.arm.1.field.0.arm.0.string_sizes].freeze,
      'library' => %w[root.arm.0.string_sizes root.arm.1.field.0.arm.0.string_sizes].freeze,
    }.freeze,
  }.freeze

  # Literal ClickHouse columns_substreams.txt names observed for the pinned
  # source fixtures. These are the exact escaped payload-column logical names;
  # only the Array(Dynamic) source uses String as its ordinary arm. String
  # profile additions are explicit, rather than reconstructed from the
  # library's physical plan.
  BASE_PAYLOAD_SUBSTREAMS = {
    'root_dynamic' => {
      'source' => %w[payload.dynamic_structure payload.variant_discr payload.SharedVariant payload.UInt64].freeze,
      'library' => %w[payload.dynamic_structure payload.variant_discr payload.SharedVariant payload.UInt64].freeze,
    }.freeze,
    'array_dynamic' => {
      'source' => %w[payload.dynamic_structure payload.variant_discr payload.size0 payload.SharedVariant payload.String].freeze,
      'library' => %w[payload.dynamic_structure payload.variant_discr payload.size0 payload.SharedVariant payload.UInt64].freeze,
    }.freeze,
    'tuple_dynamic' => {
      'source' => %w[payload%2Ed.dynamic_structure payload%2Ed.variant_discr payload%2Ed.SharedVariant payload%2Ed.UInt64 payload%2Etext].freeze,
      'library' => %w[payload%2Ed.dynamic_structure payload%2Ed.variant_discr payload%2Ed.SharedVariant payload%2Ed.UInt64 payload%2Etext].freeze,
    }.freeze,
    'nested_dynamic' => {
      'source' => %w[payload%2Elabel.dict payload%2Echoice.variant_discr payload%2Ed.dynamic_structure payload%2Ed.variant_discr payload.size0 payload%2Elabel payload%2Echoice.String payload%2Echoice.UInt64 payload%2Ed.SharedVariant payload%2Ed.UInt64 payload%2Etext].freeze,
      'library' => %w[payload%2Elabel.dict payload%2Echoice.variant_discr payload%2Ed.dynamic_structure payload%2Ed.variant_discr payload.size0 payload%2Elabel payload%2Echoice.String payload%2Echoice.UInt64 payload%2Ed.SharedVariant payload%2Ed.UInt64 payload%2Etext].freeze,
    }.freeze,
    'dynamic_tuple_dynamic' => {
      'source' => %w[payload.dynamic_structure payload.variant_discr payload.Tuple%28Dynamic%28max_types%3D1%29%29%2E1.dynamic_structure payload.Tuple%28Dynamic%28max_types%3D1%29%29%2E1.variant_discr payload.SharedVariant payload.Tuple%28Dynamic%28max_types%3D1%29%29%2E1.SharedVariant payload.Tuple%28Dynamic%28max_types%3D1%29%29%2E1.UInt64].freeze,
      'library' => %w[payload.dynamic_structure payload.variant_discr payload.Tuple%28Dynamic%28max_types%3D1%29%29%2E1.dynamic_structure payload.Tuple%28Dynamic%28max_types%3D1%29%29%2E1.variant_discr payload.SharedVariant payload.Tuple%28Dynamic%28max_types%3D1%29%29%2E1.SharedVariant payload.Tuple%28Dynamic%28max_types%3D1%29%29%2E1.UInt64].freeze,
    }.freeze,
  }.freeze

  SIZE_PAYLOAD_SUBSTREAMS = {
    'root_dynamic' => {
      'source' => %w[payload.SharedVariant.size].freeze,
      'library' => %w[payload.SharedVariant.size].freeze,
    }.freeze,
    'array_dynamic' => {
      'source' => %w[payload.SharedVariant.size payload.String.size].freeze,
      'library' => %w[payload.SharedVariant.size].freeze,
    }.freeze,
    'tuple_dynamic' => {
      'source' => %w[payload%2Ed.SharedVariant.size payload%2Etext.size].freeze,
      'library' => %w[payload%2Ed.SharedVariant.size payload%2Etext.size].freeze,
    }.freeze,
    'nested_dynamic' => {
      'source' => %w[payload%2Echoice.String.size payload%2Ed.SharedVariant.size payload%2Etext.size].freeze,
      'library' => %w[payload%2Echoice.String.size payload%2Ed.SharedVariant.size payload%2Etext.size].freeze,
    }.freeze,
    'dynamic_tuple_dynamic' => {
      'source' => %w[payload.SharedVariant.size payload.Tuple%28Dynamic%28max_types%3D1%29%29%2E1.SharedVariant.size].freeze,
      'library' => %w[payload.SharedVariant.size payload.Tuple%28Dynamic%28max_types%3D1%29%29%2E1.SharedVariant.size].freeze,
    }.freeze,
  }.freeze

  def self.expected_string_size_lanes(case_id, origin)
    STATIC_STRING_COUNTS.fetch(case_id) + site_paths(case_id).size +
      DYNAMIC_ORDINARY_STRING_SITES.fetch(origin).fetch(case_id, 0)
  end

  def self.expected_logical_roles(case_id, origin, profile)
    roles = BASE_LOGICAL_ROLES.fetch(case_id).fetch(origin).dup
    roles.concat(SIZE_LOGICAL_ROLES.fetch(case_id).fetch(origin)) if profile == 'with_size_stream'
    roles.sort
  end

  def self.expected_payload_substreams(case_id, origin, profile)
    names = BASE_PAYLOAD_SUBSTREAMS.fetch(case_id).fetch(origin).dup
    names.concat(SIZE_PAYLOAD_SUBSTREAMS.fetch(case_id).fetch(origin)) if profile == 'with_size_stream'
    names.sort
  end

  SETTINGS = [
    'index_granularity=2', 'index_granularity_bytes=10485760',
    'enable_mixed_granularity_parts=1', 'min_rows_for_wide_part=0',
    'min_bytes_for_wide_part=0', 'compress_marks=0', 'compress_primary_key=0',
    'min_compress_block_size=0', 'max_compress_block_size=4096',
    "default_compression_codec='LZ4'", "serialization_info_version='with_types'",
    'propagate_types_serialization_versions_to_nested_types=1',
    'use_compact_variant_discriminators_serialization=0',
    "dynamic_serialization_version='v3'",
  ].join(', ').freeze

  def self.assert(ok, message)
    raise "W203 recursive Dynamic oracle: #{message}" unless ok
  end

  def self.type_for(case_id)
    case case_id
    when 'root_dynamic', 'dynamic_tuple_dynamic' then DYNAMIC
    when 'array_dynamic' then "Array(#{DYNAMIC})"
    when 'tuple_dynamic' then "Tuple(d #{DYNAMIC}, text String)"
    when 'nested_dynamic' then NESTED
    else raise "unknown W203 case #{case_id.inspect}"
    end
  end

  def self.sql_quote(value)
    "'#{value.to_s.gsub(/[\\']/) { |character| "\\#{character}" }}'"
  end

  def self.dynamic_sql(value)
    inner = if value.nil?
              'NULL'
            elsif value.is_a?(Integer)
              "toUInt64(#{value})"
            else
              sql_quote(value)
            end
    "CAST(#{inner}, '#{DYNAMIC}')"
  end

  def self.variant_sql(value)
    kind, body = value
    inner = case kind
            when :null then 'NULL'
            when :uint64 then "toUInt64(#{body})"
            when :string then sql_quote(body)
            else raise "unknown W203 Variant literal #{value.inspect}"
            end
    "CAST(#{inner}, '#{VARIANT}')"
  end

  def self.value_sql(case_id, value)
    case case_id
    when 'root_dynamic'
      dynamic_sql(value)
    when 'array_dynamic'
      "[#{value.map { |item| dynamic_sql(item) }.join(', ')}]"
    when 'tuple_dynamic'
      "(#{dynamic_sql(value[0])}, #{sql_quote(value[1])})"
    when 'nested_dynamic'
      records = value.map do |label, choice, payload, text|
        label_sql = label.nil? ? 'CAST(NULL, \'Nullable(String)\')' : sql_quote(label)
        "(#{label_sql}, #{variant_sql(choice)}, #{dynamic_sql(payload)}, #{sql_quote(text)})"
      end
      "[#{records.join(', ')}]"
    when 'dynamic_tuple_dynamic'
      if value.nil?
        dynamic_sql(nil)
      elsif value[0] == :tuple
        child = dynamic_sql(value[1])
        "CAST(tuple(#{child}), '#{DYNAMIC}')"
      else
        dynamic_sql(value)
      end
    else
      raise "unknown W203 case #{case_id.inspect}"
    end
  end

  def self.value_sql_rows(case_id)
    FIXTURES.fetch(case_id).each_with_index.map do |value, index|
      "(#{index + 1}, #{value_sql(case_id, value)})"
    end
  end

  def self.hex_json(value)
    JSON.generate(value).unpack1('H*')
  end

  def self.decode_hex_json(value, label)
    assert(value.match?(/\A(?:[0-9A-Fa-f]{2})*\z/), "malformed JSON hex in #{label}")
    JSON.parse([value].pack('H*'))
  rescue JSON::ParserError => error
    raise "W203 recursive Dynamic oracle: invalid JSON hex in #{label}: #{error.message}"
  end

  def self.dynamic_state(value, max_types: 1, ordinary_type: UINT64)
    return 'NULL' if value.nil?
    if value.is_a?(Array) && value[0] == :tuple
      "Tuple(Dynamic(max_types=#{max_types})):0"
    else
      actual = value.is_a?(Integer) ? UINT64 : STRING
      "#{actual}:#{actual == ordinary_type ? 0 : 1}"
    end
  end

  def self.value_projection(case_id)
    case case_id
    when 'root_dynamic'
      ["hex(ifNull(toJSONString(payload), 'null'))", "toTypeName(payload)", dynamic_state_sql('payload')]
    when 'array_dynamic'
      ["hex(toJSONString(payload))", "toTypeName(payload)",
       "arrayStringConcat(arrayMap(x -> if(isNull(x), 'NULL', concat(dynamicType(x), ':', toString(toUInt8(isDynamicElementInSharedData(x))))), payload), ',')"]
    when 'tuple_dynamic'
      ["hex(ifNull(toJSONString(tupleElement(payload, 1)), 'null'))", "hex(toJSONString(tupleElement(payload, 2)))",
       "toTypeName(payload)", dynamic_state_sql('tupleElement(payload, 1)')]
    when 'nested_dynamic'
      ["hex(toJSONString(payload.label))", "hex(toJSONString(payload.choice))",
       "hex(toJSONString(payload.d))", "hex(toJSONString(payload.text))", "toTypeName(payload)",
       "arrayStringConcat(arrayMap(x -> if(isNull(x), 'NULL', concat(dynamicType(x), ':', toString(toUInt8(isDynamicElementInSharedData(x))))), payload.d), ',')",
       "arrayStringConcat(arrayMap(x -> if(isNull(x), 'NULL', variantType(x)), payload.choice), ',')"]
    when 'dynamic_tuple_dynamic'
      extracted = "dynamicElement(payload, '#{INNER_TUPLE}')"
      inner = "tupleElement(assumeNotNull(#{extracted}), 1)"
      ["hex(ifNull(toJSONString(payload), 'null'))", "toTypeName(payload)", dynamic_state_sql('payload'),
       "if(dynamicType(payload) = '#{INNER_TUPLE}', if(isNull(#{inner}), 'NULL', concat(dynamicType(#{inner}), ':', toString(toUInt8(isDynamicElementInSharedData(#{inner}))))), '')"]
    else
      raise "unknown W203 case #{case_id.inspect}"
    end
  end

  def self.dynamic_state_sql(expression)
    "if(isNull(#{expression}), 'NULL', concat(dynamicType(#{expression}), ':', toString(toUInt8(isDynamicElementInSharedData(#{expression})))))"
  end

  def self.expected_projection(case_id, value, origin = 'source')
    ordinary_type = if case_id == 'array_dynamic' && origin == 'source'
                      STRING
                    else
                      UINT64
                    end
    case case_id
    when 'root_dynamic'
      [value, DYNAMIC, dynamic_state(value, ordinary_type: ordinary_type)]
    when 'array_dynamic'
      json = value
      state = value.map { |item| item.nil? ? 'NULL' : dynamic_state(item, ordinary_type: ordinary_type) }.join(',')
      [json, "Array(#{DYNAMIC})", state]
    when 'tuple_dynamic'
      [value[0], value[1], "Tuple(d #{DYNAMIC}, text String)", dynamic_state(value[0], ordinary_type: ordinary_type)]
    when 'nested_dynamic'
      labels = value.map { |record| record[0] }
      choices = value.map { |record| record[1][0] == :null ? nil : record[1][1] }
      dynamics = value.map { |record| record[2] }
      texts = value.map { |record| record[3] }
      dynamic_types = value.map { |record| record[2].nil? ? 'NULL' : dynamic_state(record[2], ordinary_type: ordinary_type) }.join(',')
      variant_types = value.map { |record| record[1][0] == :null ? 'NULL' : record[1][0] == :string ? 'String' : 'UInt64' }.join(',')
      [labels, choices, dynamics, texts, NESTED, dynamic_types, variant_types]
    when 'dynamic_tuple_dynamic'
      if value.nil?
        [nil, DYNAMIC, 'NULL', '']
      elsif value[0] == :tuple
        [ [value[1]], DYNAMIC, dynamic_state(value, ordinary_type: ordinary_type), dynamic_state(value[1]) ]
      else
        [value, DYNAMIC, dynamic_state(value, ordinary_type: ordinary_type), '']
      end
    else
      raise "unknown W203 case #{case_id.inspect}"
    end
  end

  def self.exact_type(case_id)
    type_for(case_id)
  end

  def self.expected_value_rows(case_id, window, origin = 'source')
    rows = FIXTURES.fetch(case_id).each_with_index.map { |value, index| [index + 1, value] }
    selected = case window
               when 'FULL' then rows
               when 'FIRST_EMPTY' then rows[0, 2]
               when 'MARK_1' then rows[2, 2]
               when 'MARK_2' then rows[4, 2]
               when 'FINAL' then rows[6, 2]
               when 'ZERO' then []
               else raise "unknown W203 window #{window.inspect}"
               end
    selected.map do |pk, value|
      [pk.to_s] + expected_projection(case_id, value, origin).map do |field|
        field.is_a?(String) && field == exact_type(case_id) ? field : field
      end
    end
  end

  def self.table(case_id, profile, origin = 'source')
    "#{origin}_#{case_id}_#{profile}"
  end

  def self.case_profiles
    CASE_IDS.flat_map { |case_id| PROFILE_IDS.map { |profile| [case_id, profile] } }
  end

  def self.site_paths(case_id)
    {
      'root_dynamic' => ['root'],
      'array_dynamic' => ['root.elements'],
      'tuple_dynamic' => ['root.field.0'],
      'nested_dynamic' => ['root.elements.field.2'],
      'dynamic_tuple_dynamic' => ['root', 'root.arm.1.field.0'],
    }.fetch(case_id)
  end

  class Probe < W202::Probe
    def initialize(binary, crystal_helper, evidence_root)
      super
      @source_parts = {}
      @source_snapshots = {}
      @library_parts = {}
      @library_snapshots = {}
      @independent_roster_evidence = {}
      @data_paths = {}
      @case_profile_by_table = {}
      @fatal_error = nil
    end

    def run
      prepare_layout!
      @binary_sha_before = binary_sha
      fail!('pinned ClickHouse executable SHA-256 mismatch before probe') unless @binary_sha_before == BINARY_SHA256
      @helper_sha_before = helper_sha
      fail!('Crystal helper SHA changed before probe') unless @helper_sha_before == helper_sha

      initial = run_clickhouse('native_sources', initial_sql)
      assert_native_invocation!(initial)
      native = parse_native(initial[:stdout])
      assert_pin!(native)
      assert_initial_native!(native)

      input = build_helper_input
      input_path = File.join(@root, 'generated', 'helper-input.json')
      helper_input_bytes = JSON.pretty_generate(input) + "\n"
      write_new(input_path, helper_input_bytes)
      @helper_input_evidence = {
        path: input_path, bytes: helper_input_bytes.bytesize,
        sha256: Digest::SHA256.hexdigest(helper_input_bytes),
      }
      helper = run_helper(input_path)
      assert_helper_output!(helper[:data])
      attach_library_parts!

      attached = run_clickhouse('attach_and_check', attached_sql)
      assert_native_invocation!(attached)
      attached_native = parse_native(attached[:stdout])
      assert_pin!(attached_native)
      assert_attached_native!(attached_native)

      @source_parts.each do |table_name, path|
        fail!("stock source part changed during ATTACH/SELECT: #{table_name}") unless snapshot_part(path) == @source_snapshots.fetch(table_name)
      end
      @library_parts.each do |key, path|
        fail!("published library part changed during ATTACH/SELECT: #{key}") unless snapshot_part(path) == @library_snapshots.fetch(key)
      end
      @binary_sha_after = binary_sha
      @helper_sha_after = helper_sha
      fail!('pinned ClickHouse executable SHA changed during probe') unless @binary_sha_after == BINARY_SHA256
      fail!('prebuilt Crystal helper SHA changed during probe') unless @helper_sha_after == @helper_sha_before

      write_summary(status: 'paired_recursive_dynamic_bulk_part_observed', source: native,
                    helper: helper[:data], helper_invocation: helper[:record],
                    helper_input: @helper_input_evidence,
                    initial_invocation: initial[:record], attached: attached_native,
                    attached_invocation: attached[:record], source_part_snapshots: @source_snapshots,
                    library_part_snapshots: @library_snapshots)
      puts "W203 paired recursive Dynamic complete parts cases=#{CASE_IDS.size} profiles=#{PROFILE_IDS.size}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @binary_sha_after = binary_sha rescue nil
      @helper_sha_after = helper_sha rescue nil
      write_summary(status: 'runner_failure_or_observations_differ', fatal_error: @fatal_error) rescue nil
      warn "W203 probe failure (process failure is not format evidence): #{@fatal_error}"
      false
    end

    private

    # Probe is an instance API layered over module-level fixture/oracle
    # helpers. Ruby does not make module singleton methods available to nested
    # class instances, so keep the delegation explicit at this boundary.
    def case_profiles
      ProbeDynamicBulkPartW203.case_profiles
    end

    def table(case_id, profile, origin = 'source')
      ProbeDynamicBulkPartW203.table(case_id, profile, origin)
    end

    def type_for(case_id)
      ProbeDynamicBulkPartW203.type_for(case_id)
    end

    def value_sql_rows(case_id)
      ProbeDynamicBulkPartW203.value_sql_rows(case_id)
    end

    def value_projection(case_id)
      ProbeDynamicBulkPartW203.value_projection(case_id)
    end

    def decode_hex_json(value, label)
      ProbeDynamicBulkPartW203.decode_hex_json(value, label)
    end

    def fail!(message)
      raise "W203 recursive Dynamic oracle: #{message}"
    end

    def parse_columns_substreams(bytes, label)
      fail!("#{label} columns_substreams.txt is too large") if bytes.bytesize > MAX_COLUMNS_SUBSTREAMS_BYTES
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      fail!("#{label} columns_substreams.txt is not UTF-8") unless text.valid_encoding?
      lines = text.lines.map(&:chomp)
      fail!("#{label} columns_substreams header differs") unless lines.shift == 'columns substreams version: 1'
      fail!("#{label} columns_substreams column count differs") unless lines.shift == '2 columns:'

      columns = {}
      until lines.empty?
        header = lines.shift
        match = /\A([1-9][0-9]*) substreams for column `([^`]+)`:\z/.match(header)
        fail!("#{label} columns_substreams block header is malformed") unless match
        count = Integer(match[1], 10)
        column = match[2]
        fail!("#{label} columns_substreams repeats a column") if columns.key?(column)
        fail!("#{label} columns_substreams block is truncated") if lines.size < count
        names = lines.shift(count).map do |line|
          name_match = /\A\t([^\t\r\n]+)\z/.match(line)
          fail!("#{label} columns_substreams name line is malformed") unless name_match
          name_match[1]
        end
        fail!("#{label} columns_substreams repeats a name in #{column}") unless names.uniq == names
        columns[column] = names
      end
      fail!("#{label} columns_substreams column roster differs") unless columns.keys.sort == %w[payload pk]
      fail!("#{label} columns_substreams primary-key roster differs") unless columns.fetch('pk') == ['pk']
      columns
    rescue ArgumentError => error
      raise "W203 recursive Dynamic oracle: #{label} columns_substreams count is invalid: #{error.message}"
    end

    def assert_independent_part_roster!(part_path, case_id, origin, profile, expected_payload_names)
      validate_plain_tree!(part_path)
      manifest_path = File.join(part_path, 'columns_substreams.txt')
      manifest_stat = File.lstat(manifest_path)
      fail!("#{case_id}/#{profile}/#{origin} columns_substreams.txt is not a regular file") unless manifest_stat.file? && !manifest_stat.symlink?
      fail!("#{case_id}/#{profile}/#{origin} columns_substreams.txt exceeds the bounded read size") if manifest_stat.size > MAX_COLUMNS_SUBSTREAMS_BYTES
      manifest_bytes = File.binread(manifest_path, MAX_COLUMNS_SUBSTREAMS_BYTES + 1)
      columns = parse_columns_substreams(manifest_bytes, "#{case_id}/#{profile}/#{origin}")
      actual_payload_names = columns.fetch('payload').sort
      fail!("#{case_id}/#{profile}/#{origin} part metadata differs from independent literal names") unless actual_payload_names == expected_payload_names

      stream_files = Dir.children(part_path).select { |name| name.end_with?('.bin') || name.end_with?('.mrk2') }
      malformed = stream_files.reject { |name| /\A[0-9a-f]{32}\.(?:bin|mrk2)\z/.match?(name) }
      fail!("#{case_id}/#{profile}/#{origin} has a noncanonical hashed stream filename") unless malformed.empty?
      binary_stems = stream_files.select { |name| name.end_with?('.bin') }.map { |name| name.sub(/\.bin\z/, '') }.sort
      mark_stems = stream_files.select { |name| name.end_with?('.mrk2') }.map { |name| name.sub(/\.mrk2\z/, '') }.sort
      expected_count = expected_payload_names.size + 1 # plus the independently fixed pk lane
      # The raw manifest authenticates exact logical names. This Ruby check
      # deliberately does not reimplement ClickHouse's StreamName hash; it
      # corroborates one canonical data/mark filename pair per manifest lane.
      fail!("#{case_id}/#{profile}/#{origin} physical stream file count differs from manifest") unless
        binary_stems.size == expected_count && binary_stems.uniq == binary_stems &&
        mark_stems.size == expected_count && mark_stems.uniq == mark_stems && binary_stems == mark_stems

      @independent_roster_evidence[[case_id, profile, origin].join('/')] = {
        manifest: manifest_bytes.force_encoding(Encoding::UTF_8),
        payload_substreams: actual_payload_names,
        hashed_stream_stems: binary_stems,
      }
      true
    end

    def prepare_layout!
      %w[invocations inputs stores generated].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
      CASE_IDS.each do |case_id|
        PROFILE_IDS.each do |profile|
          parent = File.join(@root, 'generated', case_id)
          Dir.mkdir(parent, 0o700) unless Dir.exist?(parent)
          Dir.mkdir(File.join(parent, profile), 0o700)
        end
      end
    end

    def binary_sha
      Digest::SHA256.file(@binary).hexdigest
    end

    def helper_sha
      Digest::SHA256.file(@helper).hexdigest
    end

    def all_tables
      CASE_IDS.flat_map { |case_id| PROFILE_IDS.flat_map { |profile| [table(case_id, profile, 'source'), table(case_id, profile, 'library')] } }
    end

    def source_tables
      CASE_IDS.flat_map { |case_id| PROFILE_IDS.map { |profile| table(case_id, profile, 'source') } }
    end

    def initial_sql
      statements = [
        'SET flatten_nested=0;',
        'SET allow_suspicious_low_cardinality_types=1;',
        'SET output_format_json_named_tuples_as_objects=0;',
        'SET print_pretty_type_names=0;',
        "SELECT '__W203_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
      ]
      case_profiles.each do |case_id, profile|
        type = type_for(case_id)
        settings = "#{SETTINGS}, string_serialization_version='#{profile}'"
        source = table(case_id, profile, 'source')
        library = table(case_id, profile, 'library')
        @case_profile_by_table[source] = [case_id, profile]
        @case_profile_by_table[library] = [case_id, profile]
        [source, library].each do |name|
          statements << "CREATE TABLE default.#{name} (pk UInt64, payload #{type}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings};"
        end
        values = value_sql_rows(case_id).join(",\n")
        statements << "INSERT INTO default.#{source} VALUES\n#{values};"
        statements << check_sql(source, case_id, profile)
      end
      names = all_tables.map { |name| "'#{name}'" }.join(',')
      statements << "SELECT '__W203_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{names}) ORDER BY table, position FORMAT TSVRaw;"
      statements << "SELECT '__W203_DATA_PATH__', name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name IN (#{names}) ORDER BY name FORMAT TSVRaw;"
      statements << parts_sql(source_tables)
      case_profiles.each { |case_id, profile| statements.concat(value_queries(table(case_id, profile, 'source'), case_id)) }
      statements.join("\n") + "\n"
    end

    def attached_sql
      statements = [
        'SET flatten_nested=0;',
        'SET allow_suspicious_low_cardinality_types=1;',
        'SET output_format_json_named_tuples_as_objects=0;',
        'SET print_pretty_type_names=0;',
        "SELECT '__W203_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
      ]
      case_profiles.each do |case_id, profile|
        target = table(case_id, profile, 'library')
        statements << "ALTER TABLE default.#{target} ATTACH PART 'all_1_1_0';"
        statements << check_sql(table(case_id, profile, 'source'), case_id, profile)
        statements << check_sql(target, case_id, profile)
      end
      names = all_tables.map { |name| "'#{name}'" }.join(',')
      statements << "SELECT '__W203_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{names}) ORDER BY table, position FORMAT TSVRaw;"
      statements << parts_sql(all_tables)
      case_profiles.each do |case_id, profile|
        statements.concat(value_queries(table(case_id, profile, 'source'), case_id))
        statements.concat(value_queries(table(case_id, profile, 'library'), case_id))
      end
      statements.join("\n") + "\n"
    end

    def check_sql(table_name, case_id, profile)
      ["SELECT '__W203_CHECK_BEGIN__', '#{table_name}', '#{case_id}', '#{profile}' FORMAT TSVRaw;",
       "CHECK TABLE default.#{table_name} FORMAT TSV;",
       "SELECT '__W203_CHECK_END__', '#{table_name}', '#{case_id}', '#{profile}' FORMAT TSVRaw;"].join("\n")
    end

    def parts_sql(tables)
      names = tables.map { |name| "'#{name}'" }.join(',')
      "SELECT '__W203_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table IN (#{names}) AND active ORDER BY table,name FORMAT TSVRaw;"
    end

    def value_queries(table_name, case_id)
      windows = {
        'FULL' => '',
        'FIRST_EMPTY' => ' WHERE pk BETWEEN 1 AND 2',
        'MARK_1' => ' WHERE pk BETWEEN 3 AND 4',
        'MARK_2' => ' WHERE pk BETWEEN 5 AND 6',
        'FINAL' => ' WHERE pk BETWEEN 7 AND 8',
        'ZERO' => ' WHERE pk > 8',
      }
      projection = value_projection(case_id).join(', ')
      windows.flat_map do |window, predicate|
        query = "SELECT '__W203_VALUES_#{window}__', '#{table_name}', toString(pk), #{projection} FROM default.#{table_name}#{predicate} ORDER BY pk SETTINGS print_pretty_type_names=0 FORMAT TSVRaw;"
        if window == 'ZERO'
          case_id, profile = @case_profile_by_table.fetch(table_name)
          ["SELECT '__W203_ZERO_BEGIN__', '#{table_name}', '#{case_id}', '#{profile}', 'values' FORMAT TSVRaw;",
           query,
           "SELECT '__W203_ZERO_END__', '#{table_name}', '#{case_id}', '#{profile}', 'values' FORMAT TSVRaw;"]
        else
          [query]
        end
      end
    end

    def run_helper(input_path)
      before = helper_sha
      fail!('Crystal helper SHA changed before invocation') unless before == @helper_sha_before
      argv = [@helper, input_path, File.join(@root, 'generated')]
      invocation = @executor.send(:execute_record, 'crystal_helper', argv, ''.b,
                                  'prebuilt Crystal helper', before, @helper)
      fail!('Crystal helper failed; not a native format rejection') unless successful?(invocation)
      fail!('Crystal helper emitted diagnostics to stderr') unless invocation[:stderr].empty?
      fail!('Crystal helper SHA changed during invocation') unless helper_sha == before
      lines = invocation[:stdout].lines.map(&:chomp).reject(&:empty?)
      fail!('Crystal helper must emit exactly one JSON record') unless lines.size == 1
      data = JSON.parse(lines.fetch(0))
      fail!('Crystal helper output format differs') unless data['format'] == FORMAT_OUTPUT
      @invocations << invocation[:record]
      {data: data, record: invocation[:record]}
    end

    def parse_native(stdout)
      lines = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      records = ->(prefix) { lines.select { |line| line.start_with?("#{prefix}\t") }.map { |line| line.split("\t", -1) } }
      known = %w[__W203_PIN__ __W203_SCHEMA__ __W203_DATA_PATH__ __W203_PART__
                 __W203_CHECK_BEGIN__ __W203_CHECK_END__ __W203_ZERO_BEGIN__ __W203_ZERO_END__] +
        WINDOWS.map { |window| "__W203_VALUES_#{window}__" }
      unknown = lines.each_with_object([]) do |line, tags|
        next unless line.start_with?('__W203_')
        tag = line.split("\t", 2).first
        tags << tag unless known.include?(tag)
      end
      fail!("unknown marker tags: #{unknown.uniq.inspect}") unless unknown.empty?

      check_blocks = {}
      active = nil
      lines.each do |line|
        if line.start_with?("__W203_CHECK_BEGIN__\t")
          fields = line.split("\t", -1)
          fail!('malformed/nested CHECK begin') unless fields.size == 4 && !active
          active = fields.drop(1)
          fail!('duplicate CHECK block') if check_blocks.key?(active)
          check_blocks[active] = []
        elsif line.start_with?("__W203_CHECK_END__\t")
          fields = line.split("\t", -1)
          fail!('malformed CHECK end') unless fields.size == 4 && active == fields.drop(1)
          active = nil
        elsif active
          check_blocks[active] << line
        end
      end
      fail!('unterminated CHECK block') if active

      pin_rows = records.call('__W203_PIN__')
      fail!('runtime pin must occur once') unless pin_rows.size == 1 && pin_rows.first.size == 3
      schemas = records.call('__W203_SCHEMA__').map do |fields|
        fail!('schema record width differs') unless fields.size == 4
        fields.drop(1)
      end
      path_rows = records.call('__W203_DATA_PATH__')
      fail!('duplicate data-path record') unless path_rows.map { |fields| fields[1] }.uniq.size == path_rows.size
      paths = path_rows.to_h do |fields|
        fail!('data-path record width differs') unless fields.size == 3
        [fields[1], fields[2]]
      end
      part_rows = records.call('__W203_PART__')
      fail!('duplicate active-part record') unless part_rows.map { |fields| fields[1] }.uniq.size == part_rows.size
      parts = part_rows.to_h do |fields|
        fail!('part record width differs') unless fields.size == 7
        [fields[1], {name: fields[2], path: fields[3], type: fields[4], rows: fields[5], marks: fields[6]}]
      end
      value_rows = {}
      WINDOWS.each do |window|
        records.call("__W203_VALUES_#{window}__").each do |fields|
          fail!('selected-value row has too few fields') unless fields.size >= 5
          key = [fields[1], window]
          (value_rows[key] ||= []) << fields.drop(2)
        end
      end
      zero_events = lines.select { |line| line.start_with?("__W203_ZERO_BEGIN__\t") || line.start_with?("__W203_ZERO_END__\t") }
                         .map { |line| line.split("\t", -1) }
      {pin: lines.find { |line| line.start_with?("__W203_PIN__\t") }, checks: check_blocks,
       schemas: schemas, data_paths: paths, parts: parts, value_rows: value_rows, zero_events: zero_events}
    end

    def assert_pin!(native)
      expected = "__W203_PIN__\t#{VERSION}\t#{BUILD}"
      fail!("runtime version/build/SHA scope differs: #{native[:pin].inspect}") unless native[:pin] == expected
    end

    def assert_initial_native!(native)
      expected_checks = source_tables.to_h do |name|
        case_id, profile = @case_profile_by_table.fetch(name)
        [[name, case_id, profile], ["all_1_1_0\t1\t"]]
      end
      fail!("stock source CHECK grid differs: #{native[:checks].inspect}") unless native[:checks] == expected_checks
      expected_schemas = all_tables.sort.flat_map do |name|
        case_id, = @case_profile_by_table.fetch(name)
        [[name, 'pk', 'UInt64'], [name, 'payload', type_for(case_id)]]
      end
      fail!('source/empty-target nominal declarations differ') unless native[:schemas] == expected_schemas
      fail!('native data paths do not cover exact table roster') unless native[:data_paths].keys.sort == all_tables.sort
      native[:data_paths].each_value { |path| validate_store_path!(path) }
      @data_paths = native[:data_paths].dup
      fail!('stock source part roster differs') unless native[:parts].keys.sort == source_tables.sort
      expected_windows = source_tables.product(WINDOWS.reject { |name| name == 'ZERO' }).sort
      fail!('stock selected-value query roster differs') unless native[:value_rows].keys.sort == expected_windows
      expected_zero = source_tables.flat_map do |name|
        case_id, profile = @case_profile_by_table.fetch(name)
        [["__W203_ZERO_BEGIN__", name, case_id, profile, 'values'], ["__W203_ZERO_END__", name, case_id, profile, 'values']]
      end
      fail!('native zero-window boundary roster differs') unless native[:zero_events] == expected_zero

      source_tables.each do |name|
        case_id, profile = @case_profile_by_table.fetch(name)
        part = native[:parts].fetch(name)
        fail!("#{name} is not a single eight-row Wide part with four marks and end sentinel") unless
          part[:name] == 'all_1_1_0' && part[:type] == 'Wide' && part[:rows] == '8' && part[:marks] == '5'
        path = validate_source_part!(part[:path])
        @source_parts[name] = path
        @source_snapshots[name] = snapshot_part(path)
        assert_value_windows!(native, name, case_id, 'source')
      end
    end

    def assert_attached_native!(native)
      expected_check_keys = all_tables.map do |name|
        case_id, profile = @case_profile_by_table.fetch(name)
        [name, case_id, profile]
      end.sort
      fail!('native CHECK block roster differs') unless native[:checks].keys.sort == expected_check_keys
      all_tables.each do |name|
        case_id, profile = @case_profile_by_table.fetch(name)
        fail!("native CHECK result differs for #{name}: #{native[:checks].inspect}") unless native[:checks][[name, case_id, profile]] == ["all_1_1_0\t1\t"]
      end
      expected_schemas = all_tables.sort.flat_map do |name|
        case_id, = @case_profile_by_table.fetch(name)
        [[name, 'pk', 'UInt64'], [name, 'payload', type_for(case_id)]]
      end
      fail!('attached nominal declarations differ') unless native[:schemas] == expected_schemas
      fail!('attached part roster differs') unless native[:parts].keys.sort == all_tables.sort
      expected_windows = all_tables.product(WINDOWS.reject { |name| name == 'ZERO' }).sort
      fail!('attached selected-value query roster differs') unless native[:value_rows].keys.sort == expected_windows
      expected_zero = all_tables.flat_map do |name|
        case_id, profile = @case_profile_by_table.fetch(name)
        [["__W203_ZERO_BEGIN__", name, case_id, profile, 'values'], ["__W203_ZERO_END__", name, case_id, profile, 'values']]
      end
      fail!('attached zero-window boundary roster differs') unless native[:zero_events] == expected_zero
      all_tables.each do |name|
        case_id, = @case_profile_by_table.fetch(name)
        part = native[:parts].fetch(name)
        fail!("attached identity/grid differs for #{name}") unless
          part[:name] == 'all_1_1_0' && part[:type] == 'Wide' && part[:rows] == '8' && part[:marks] == '5'
        assert_value_windows!(native, name, case_id, origin_for_table(name))
      end
    end

    def assert_value_windows!(native, table_name, case_id, origin)
      WINDOWS.each do |window|
        actual = native[:value_rows].fetch([table_name, window], [])
        next if window == 'ZERO'
        expected = ProbeDynamicBulkPartW203.expected_value_rows(case_id, window, origin)
        decoded = actual.map do |fields|
          values = fields.dup
          hex_positions = case case_id
                          when 'root_dynamic', 'array_dynamic', 'dynamic_tuple_dynamic' then [1]
                          when 'tuple_dynamic' then [1, 2]
                          when 'nested_dynamic' then [1, 2, 3, 4]
                          end
          hex_positions.each { |position| values[position] = decode_hex_json(values[position], "#{table_name}/#{window}") }
          values
        end
        fail!("#{table_name} #{window} differs from independent stock literals: #{decoded.inspect}") unless decoded == expected
      end
    end

    def origin_for_table(table_name)
      return 'source' if table_name.start_with?('source_')
      return 'library' if table_name.start_with?('library_')
      fail!("native table has unknown origin: #{table_name.inspect}")
    end

    def assert_helper_output!(data)
      fail!('Crystal helper keys or format differ') unless data.keys.sort == %w[case_ids cases format profile_ids] && data['format'] == FORMAT_OUTPUT
      fail!('Crystal helper carrier/profile roster differs') unless data['case_ids'] == CASE_IDS && data['profile_ids'] == PROFILE_IDS
      expected_pairs = case_profiles
      observed_pairs = data['cases'].map { |item| [item['case_id'], item['profile_id']] }
      fail!('Crystal helper case/profile roster or order differs') unless observed_pairs == expected_pairs
      data['cases'].each do |item|
        case_id = item.fetch('case_id')
        profile = item.fetch('profile_id')
        fail!('Crystal helper result keys differ') unless item.keys.sort == %w[case_id library library_part_path profile_id source]
        fail!('Crystal helper source/library type or windows differ') unless %w[source library].all? do |origin|
          side = item.fetch(origin)
          side.keys.sort == %w[dynamic_site_paths logical_stream_roles mark_count mark_row_counts ordinary_profile physical_stream_names row_count schema_declaration windows] &&
            side['schema_declaration'] == type_for(case_id) && side['row_count'] == 8 && side['mark_count'] == 4 &&
            side['mark_row_counts'] == [2, 2, 2, 2] && side['ordinary_profile'] == profile &&
            side['windows'] == %w[full first_empty_mark mark_1 mark_2 final_mark zero_end_window]
        end
        expected_sites = expected_site_paths(case_id)
        %w[source library].each do |origin|
          side = item.fetch(origin)
          fail!("helper #{case_id}/#{profile}/#{origin} Dynamic occurrence paths differ") unless side['dynamic_site_paths'] == expected_sites
          streams = side['physical_stream_names']
          roles = side['logical_stream_roles']
          fail!('physical stream basename roster is empty or duplicated') unless streams.is_a?(Array) && !streams.empty? && streams.uniq == streams
          fail!('logical stream role roster is empty or duplicated') unless roles.is_a?(Array) && !roles.empty? && roles.uniq == roles
          expected_roles = ProbeDynamicBulkPartW203.expected_logical_roles(case_id, origin, profile)
          fail!("#{case_id}/#{profile}/#{origin} logical stream roles differ from fixed occurrence literals") unless roles == expected_roles
          expected_streams = ProbeDynamicBulkPartW203.expected_payload_substreams(case_id, origin, profile)
          fail!("#{case_id}/#{profile}/#{origin} physical stream names differ from fixed ClickHouse roster literals") unless streams == expected_streams
          expected_size_lanes = ProbeDynamicBulkPartW203.expected_string_size_lanes(case_id, origin)
          size_roles = roles.count { |role| role.end_with?('.string_sizes') }
          physical_sizes = streams.count { |name| name.end_with?('.size') }
          expected_for_profile = profile == 'single_stream' ? 0 : expected_size_lanes
          fail!("#{case_id}/#{profile} logical String profile lane count differs") unless size_roles == expected_for_profile
          fail!("#{case_id}/#{profile} physical String profile lane count differs") unless physical_sizes == expected_for_profile
          fail!('physical/logical String lane counts disagree') unless physical_sizes == size_roles

          part_path = if origin == 'source'
                        @source_parts.fetch(table(case_id, profile, 'source'))
                      else
                        File.join(@root, 'generated', case_id, profile, 'all_1_1_0')
                      end
          assert_independent_part_roster!(part_path, case_id, origin, profile, expected_streams)
        end
        expected_path = File.join(@root, 'generated', case_id, profile, 'all_1_1_0')
        fail!('helper library part path escaped its fixed output') unless File.expand_path(item['library_part_path']) == expected_path
        key = [case_id, profile]
        @library_parts[key] = expected_path
        @library_snapshots[key] = snapshot_part(expected_path)
      end
    end

    def expected_site_paths(case_id)
      ProbeDynamicBulkPartW203.site_paths(case_id)
    end

    def build_helper_input
      capture_root = File.realpath(File.join(@root, 'stores', 'native'))
      cases = case_profiles.map do |case_id, profile|
        source = table(case_id, profile, 'source')
        {
          'case_id' => case_id,
          'profile_id' => profile,
          'capture_root' => capture_root,
          'source_part' => @source_parts.fetch(source),
          'library_part' => File.join(@root, 'generated', case_id, profile, 'all_1_1_0'),
        }
      end
      {'format' => FORMAT_INPUT, 'capture_root' => capture_root, 'cases' => cases}
    end

    def attach_library_parts!
      case_profiles.each do |case_id, profile|
        target = table(case_id, profile, 'library')
        path = @library_parts.fetch([case_id, profile])
        validate_generated_part!(path, case_id, profile)
        data_path = validate_store_path!(@data_paths.fetch(target))
        @executor.send(:attach_part!, path, data_path)
      end
    end

    def validate_generated_part!(path, case_id, profile)
      expected = File.join(@root, 'generated', case_id, profile, 'all_1_1_0')
      fail!("generated library part path differs for #{case_id}/#{profile}") unless File.expand_path(path) == expected
      fail!("generated library part absent for #{case_id}/#{profile}") unless File.directory?(expected) && !File.symlink?(expected)
      validate_plain_tree!(expected)
      expected
    end

    def validate_store_path!(path)
      fail!('native table data path is absent') unless path && !path.empty?
      full = File.expand_path(path)
      store = File.join(@root, 'stores', 'native')
      fail!("native table path escaped evidence store: #{path}") unless full.start_with?(store + File::SEPARATOR)
      ensure_plain_directory_chain!(full)
      full
    end

    def validate_source_part!(path)
      full = File.expand_path(path)
      store = File.join(@root, 'stores', 'native')
      fail!('stock part path escaped native store') unless full.start_with?(store + File::SEPARATOR)
      fail!('stock source part is absent, symlinked, or noncanonical') unless File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full
      validate_plain_tree!(full)
      full
    end

    def ensure_plain_directory_chain!(path)
      current = File::SEPARATOR
      File.expand_path(path).delete_prefix(File::SEPARATOR).split(File::SEPARATOR).each do |component|
        current = File.join(current, component)
        next unless File.exist?(current) || File.symlink?(current)
        fail!("symlink in native path: #{current}") if File.lstat(current).symlink?
        fail!("non-directory native path component: #{current}") unless File.directory?(current)
      end
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

    def write_summary(data)
      summary = {
        probe: 'W203 paired recursive Dynamic complete-part qualification',
        status: data[:status], fatal_error: data[:fatal_error],
        runtime: {path: @binary, expected_sha256: BINARY_SHA256,
                  sha256_before: @binary_sha_before, sha256_after: @binary_sha_after,
                  expected_version: VERSION, expected_version_git_hash: BUILD},
        helper: {path: @helper, sha256_before: @helper_sha_before, sha256_after: @helper_sha_after},
        helper_input: @helper_input_evidence,
        independent_part_rosters: @independent_roster_evidence,
        limits: {max_threads: 1, local_max_memory_usage_bytes: MEMORY,
                 required_outer_run_safe_memory_limit_bytes: OUTER_RUN_SAFE_LIMIT,
                 timeout_seconds: TIMEOUT, termination_grace_seconds: GRACE,
                 executor: 'JsonBinaryKernelW180Probe#execute'},
        cases: CASE_IDS, profiles: PROFILE_IDS, evidence_root: @root, invocations: @invocations,
      }.merge(data.reject { |key, _| %i[status fatal_error].include?(key) })
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      write_new(File.join(@root, 'summary.md'), [
        '# W203 paired recursive Dynamic complete-part qualification', '',
        "Status: `#{summary[:status]}`", '',
        'Scope: five JSON-free carrier shapes (root Dynamic, Array, Tuple, nominal Nested, and Dynamic actual Tuple containing Dynamic) across both String profiles. Dynamic V3, BASIC Variant, LZ4, hashed streams, uncompressed adaptive marks, one eight-row Wide part per carrier/profile, and direct ATTACH. Stock literal value/type/shared-state queries in both directions are the semantic oracle; CHECK is supplementary.', '',
        "Runtime: #{VERSION} / VERSION_GITHASH #{BUILD} / SHA256 `#{BINARY_SHA256}`", '',
        "Evidence root: `#{@root}`", '',
      ].join("\n"))
    end

    def write_new(path, bytes)
      fail!("refusing to overwrite evidence: #{path}") if File.exist?(path) || File.symlink?(path)
      File.open(path, 'wbx', 0o600) { |file| file.write(bytes) }
    end
  end

  def self.self_test!
    assert(CASE_IDS == FIXTURES.keys, 'fixed carrier fixture roster/order changed')
    assert(PROFILE_IDS == %w[single_stream with_size_stream], 'String profile roster changed')
    assert(FIXTURES.values.all? { |rows| rows.size == 8 }, 'fixture row count changed')
    assert(FIXTURES.fetch('array_dynamic')[0, 2] == [[], []], 'first empty Array(Dynamic) mark changed')
    assert(FIXTURES.fetch('nested_dynamic')[0, 2] == [[], []], 'first empty Nested mark changed')
    assert(FIXTURES.fetch('dynamic_tuple_dynamic')[2] == [:tuple, 7], 'outer actual Tuple literal changed')
    assert(site_paths('dynamic_tuple_dynamic') == ['root', 'root.arm.1.field.0'], 'actual-container site roster changed')
    assert(value_sql('dynamic_tuple_dynamic', [:tuple, 7]) == "CAST(tuple(CAST(toUInt64(7), 'Dynamic(max_types=1)')), 'Dynamic(max_types=1)')",
      'stock actual Tuple(Dynamic) SQL literal changed')
    expected_lanes = {
      'source' => {'root_dynamic' => 1, 'array_dynamic' => 2, 'tuple_dynamic' => 2,
                   'nested_dynamic' => 3, 'dynamic_tuple_dynamic' => 2},
      'library' => {'root_dynamic' => 1, 'array_dynamic' => 1, 'tuple_dynamic' => 2,
                    'nested_dynamic' => 3, 'dynamic_tuple_dynamic' => 2},
    }
    expected_lanes.each do |origin, counts|
      actual_counts = CASE_IDS.to_h do |case_id|
        [case_id, expected_string_size_lanes(case_id, origin)]
      end
      assert(actual_counts == counts, "independent #{origin} String lane census changed")
    end
    array_stock = expected_value_rows('array_dynamic', 'MARK_1', 'source').first.last
    array_library = expected_value_rows('array_dynamic', 'MARK_1', 'library').first.last
    assert(array_stock == 'UInt64:1,String:0' && array_library == 'UInt64:0,String:1',
      'Array(Dynamic) stock/library ordinary/shared state law changed')
    assert(value_projection('root_dynamic').first == "hex(ifNull(toJSONString(payload), 'null'))" &&
      value_projection('tuple_dynamic').first == "hex(ifNull(toJSONString(tupleElement(payload, 1)), 'null'))" &&
      value_projection('dynamic_tuple_dynamic').first == "hex(ifNull(toJSONString(payload), 'null'))",
      'nullable Dynamic JSON observations are not normalized to JSON null')
    WINDOWS.each do |window|
      CASE_IDS.each do |case_id|
        expected = expected_value_rows(case_id, window)
        assert(expected == [] || expected.all? { |row| row.size == expected.first.size }, "#{case_id}/#{window} oracle row widths differ")
      end
    end
    # Exercise both complete SQL generators without creating evidence files or
    # invoking either native executable. This catches instance/module helper
    # scope mistakes before a stock-only probe can reach ClickHouse.
    probe = Probe.allocate
    probe.instance_variable_set(:@case_profile_by_table, {})
    initial_sql = probe.send(:initial_sql)
    attached_sql = probe.send(:attached_sql)
    assert(initial_sql.scan('CREATE TABLE default.').size == CASE_IDS.size * PROFILE_IDS.size * 2,
      'initial SQL table roster differs')
    assert(initial_sql.scan('INSERT INTO default.source_').size == CASE_IDS.size * PROFILE_IDS.size,
      'initial SQL stock insert roster differs')
    assert(initial_sql.include?('SET flatten_nested=0;') && attached_sql.include?('SET flatten_nested=0;'),
      'flatten_nested=0 is not pinned in both SQL phases')
    assert(initial_sql.include?("dynamic_serialization_version='v3'") &&
      initial_sql.scan("string_serialization_version='single_stream'").size == CASE_IDS.size * PROFILE_IDS.size &&
      initial_sql.scan("string_serialization_version='with_size_stream'").size == CASE_IDS.size * PROFILE_IDS.size,
      'initial SQL Dynamic/String profile grid differs')
    assert(attached_sql.scan('ATTACH PART').size == CASE_IDS.size * PROFILE_IDS.size,
      'ATTACH SQL target roster differs')
    valid_native = [
      "__W203_PIN__\t#{VERSION}\t#{BUILD}",
      "__W203_SCHEMA__\tfixture\tpayload\t#{DYNAMIC}",
      "__W203_DATA_PATH__\tfixture\t/tmp/native/fixture",
      "__W203_PART__\tfixture\tall_1_1_0\t/tmp/native/fixture/all_1_1_0\tWide\t8\t5",
      "__W203_CHECK_BEGIN__\tfixture\troot_dynamic\tsingle_stream",
      "all_1_1_0\t1\t",
      "__W203_CHECK_END__\tfixture\troot_dynamic\tsingle_stream",
      "__W203_VALUES_FULL__\tfixture\t1\t7\t7\tUInt64:0",
      "__W203_ZERO_BEGIN__\tfixture\troot_dynamic\tsingle_stream\tvalues",
      "__W203_ZERO_END__\tfixture\troot_dynamic\tsingle_stream\tvalues",
    ].join("\n") + "\n"
    parsed = probe.send(:parse_native, valid_native)
    assert(parsed[:pin] == "__W203_PIN__\t#{VERSION}\t#{BUILD}" &&
      parsed[:checks] == {['fixture', 'root_dynamic', 'single_stream'] => ["all_1_1_0\t1\t"]} &&
      parsed[:schemas] == [['fixture', 'payload', DYNAMIC]] &&
      parsed[:data_paths] == {'fixture' => '/tmp/native/fixture'} &&
      parsed[:parts] == {'fixture' => {name: 'all_1_1_0', path: '/tmp/native/fixture/all_1_1_0', type: 'Wide', rows: '8', marks: '5'}} &&
      parsed[:value_rows] == {['fixture', 'FULL'] => [['1', '7', '7', 'UInt64:0']]} &&
      parsed[:zero_events] == [
        ['__W203_ZERO_BEGIN__', 'fixture', 'root_dynamic', 'single_stream', 'values'],
        ['__W203_ZERO_END__', 'fixture', 'root_dynamic', 'single_stream', 'values'],
      ], 'strict parser valid-record self-test differs')
    malformed_rejected = false
    begin
      probe.send(:parse_native, valid_native + "__W203_UNEXPECTED__\tfixture\n")
    rescue RuntimeError => error
      malformed_rejected = error.message.include?('unknown marker tags')
    end
    assert(malformed_rejected, 'strict parser accepted an unknown W203 marker')
    assert(expected_logical_roles('nested_dynamic', 'source', 'single_stream').include?('root.sizes'),
      'Nested parent cardinality role is not rooted at the carrier')
    assert(expected_payload_substreams('array_dynamic', 'source', 'single_stream').include?('payload.String') &&
      expected_payload_substreams('array_dynamic', 'library', 'single_stream').include?('payload.UInt64'),
      'origin-specific Array(Dynamic) physical roster literals changed')
    manifest = [
      'columns substreams version: 1', '2 columns:',
      '1 substreams for column `pk`:', "\tpk",
      '2 substreams for column `payload`:', "\tpayload.dynamic_structure", "\tpayload.variant_discr",
    ].join("\n") + "\n"
    parsed_manifest = probe.send(:parse_columns_substreams, manifest, 'self-test')
    assert(parsed_manifest == {'pk' => ['pk'], 'payload' => %w[payload.dynamic_structure payload.variant_discr]},
      'independent columns_substreams parser valid-roster self-test differs')
    malformed_manifest_rejected = false
    begin
      probe.send(:parse_columns_substreams, manifest + "\tunexpected\n", 'self-test')
    rescue RuntimeError => error
      malformed_manifest_rejected = error.message.include?('block header is malformed')
    end
    assert(malformed_manifest_rejected, 'independent columns_substreams parser accepted an unframed name')

    # Route a fully synthetic native observation roster through the same
    # validator used for actual TSVRaw observations. The three mutations target
    # value, declared type identity, and Dynamic shared-state selection.
    valid_observations = {value_rows: {}}
    WINDOWS.each do |window|
      rows = expected_value_rows('root_dynamic', window, 'source')
      next if window == 'ZERO'
      valid_observations[:value_rows][['fixture', window]] = rows.map do |row|
        [row[0], hex_json(row[1])] + row.drop(2)
      end
    end
    probe.send(:assert_value_windows!, valid_observations, 'fixture', 'root_dynamic', 'source')
    mutations = [
      ['value 7 to 8', 1, hex_json(8)],
      ['nominal type identity', 2, 'String'],
      ['actual Dynamic type identity', 3, 'String:0'],
      ['Dynamic shared state', 3, 'UInt64:1'],
    ]
    mutations.each do |label, field_index, replacement|
      mutant = {value_rows: valid_observations[:value_rows].each_with_object({}) do |(key, rows), copy|
        copy[key] = rows.map(&:dup)
      end}
      mutant[:value_rows][['fixture', 'MARK_1']][0][field_index] = replacement
      rejected = false
      begin
        probe.send(:assert_value_windows!, mutant, 'fixture', 'root_dynamic', 'source')
      rescue RuntimeError => error
        rejected = error.message.include?('differs from independent stock literals')
      end
      assert(rejected, "assert_value_windows! accepted #{label} mutation")
    end
    true
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    if ARGV == ['--self-test']
      ProbeDynamicBulkPartW203.self_test!
      puts 'W203 Ruby fixture/oracle self-test passed'
      exit 0
    end
    options = {binary: ProbeDynamicBulkPartW203::BINARY, helper: nil, root: nil}
    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby scripts/probe_dynamic_bulk_part_w203.rb --crystal-helper PREBUILT --evidence-root EMPTY_/private/tmp_CHILD [--clickhouse PINNED]'
      parser.on('--clickhouse PATH', 'Pinned ClickHouse 26.10.1.1201 executable') { |value| options[:binary] = value }
      parser.on('--crystal-helper PATH', 'Prebuilt Crystal helper; this runner never compiles it') { |value| options[:helper] = value }
      parser.on('--evidence-root PATH', 'Existing empty direct child of /private/tmp') { |value| options[:root] = value }
    end.parse!
    abort 'W203: --crystal-helper and --evidence-root are required' unless options[:helper] && options[:root]
    exit(ProbeDynamicBulkPartW203::Probe.new(options[:binary], options[:helper], options[:root]).run ? 0 : 1)
  rescue StandardError => error
    warn "W203 runner error: #{error.class}: #{error.message}"
    exit 1
  end
end
