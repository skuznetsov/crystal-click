#!/usr/bin/env ruby
# W242 native-only type oracle for nested Dynamic sites and Tuple(JSON,
# Array(Dynamic)). It consumes authenticated W241 parts but never mutates them.

require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require 'find'
require_relative 'probe_object_shared_json_interop_w241'

module ProbeObjectRecursiveDynamicW242
  W241 = ProbeObjectSharedJSONInteropW241
  W240 = W241::W240
  FORMAT = 'object_recursive_dynamic_w242_native_type_oracle_v1'.freeze
  W241_HELPER_FORMAT = W241::Auditor::HELPER_FORMAT
  RECURSIVE_HELPER_FORMAT = 'object_recursive_dynamic_w242_helper_v1'.freeze
  RECURSIVE_INPUT_FORMAT = 'object_recursive_dynamic_w242_input_v1'.freeze
  RECURSIVE_HELPER_SOURCE_SHA256 = '913624ac415e876138c037b48e3297aa8af9ba78a9d71dc0eb8ca9ecf6a76eed'.freeze
  RECURSIVE_INPUT_MAX_BYTES = 1 * 1024 * 1024
  SUMMARY_MAX_BYTES = 8 * 1024 * 1024
  PART_FILE_MAX_BYTES = 16 * 1024 * 1024
  PART_TOTAL_MAX_BYTES = 64 * 1024 * 1024
  CHILD_TAG = '__W242_CHILD__'.freeze
  PATH_TAG = '__W242_PATH__'.freeze
  TUPLE_TAG = '__W242_TUPLE__'.freeze
  DEEP_TAG = '__W242_DEEP__'.freeze
  PIN_TAG = '__W241_PIN__'.freeze
  TUPLE_TYPE = 'Tuple(JSON, Array(Dynamic))'.freeze
  TUPLE_SELECTED_TYPE = "Nullable(#{TUPLE_TYPE})".freeze
  RECURSIVE_DIRECT_TAG = '__W242_RECURSIVE_DIRECT__'.freeze
  RECURSIVE_DIRECT_TYPE_TAG = '__W242_RECURSIVE_DIRECT_TYPE__'.freeze
  RECURSIVE_DIRECT_MIDDLE_TAG = '__W242_RECURSIVE_DIRECT_MIDDLE__'.freeze
  RECURSIVE_DIRECT_LAST_TAG = '__W242_RECURSIVE_DIRECT_LAST__'.freeze
  RECURSIVE_FULL_TAG = '__W242_RECURSIVE_FULL__'.freeze
  RECURSIVE_FULL_MIDDLE_TAG = '__W242_RECURSIVE_FULL_MIDDLE__'.freeze
  RECURSIVE_FULL_LAST_TAG = '__W242_RECURSIVE_FULL_LAST__'.freeze
  RECURSIVE_CHECK_TAG = '__W242_RECURSIVE_CHECK__'.freeze
  RECURSIVE_SCHEMA_TAG = '__W242_RECURSIVE_SCHEMA__'.freeze
  RECURSIVE_PART_TAG = '__W242_RECURSIVE_PART__'.freeze
  RECURSIVE_PATH_TAG = '__W242_RECURSIVE_PATH__'.freeze
  # Reuse the existing strict CHECK interval parser's literal markers.
  RECURSIVE_CHECK_BEGIN_TAG = '__W242_CHECK_BEGIN__'.freeze
  RECURSIVE_CHECK_END_TAG = '__W242_CHECK_END__'.freeze
  RECURSIVE_WINDOW_SPECS = {
    'middle' => {'first_mark' => 1, 'mark_count' => 2, 'pks' => [3, 4, 5, 6]},
    'last' => {'first_mark' => 3, 'mark_count' => 1, 'pks' => [7, 8]},
    'empty_interior' => {'first_mark' => 2, 'mark_count' => 0, 'pks' => []},
    'zero_count_end' => {'first_mark' => 4, 'mark_count' => 0, 'pks' => []},
  }.freeze
  RECURSIVE_JSON_DESCRIPTOR = 'JSON(max_dynamic_types=1, max_dynamic_paths=1, v UInt8)'.freeze
  RECURSIVE_ACTUAL_TYPE = 'Tuple(JSON(max_dynamic_types=1, max_dynamic_paths=1, v UInt8), Array(Dynamic(max_types=1)))'.freeze
  RECURSIVE_NESTED_DESCRIPTOR = 'Dynamic(max_types=1)'.freeze
  RECURSIVE_PATH_CARRIER = 'Dynamic(max_types=254)'.freeze
  # Canonical Variant order includes the implicit SharedVariant arm before
  # this Tuple actual, so the Tuple child site is arm 1.
  RECURSIVE_NESTED_SITE = 'root.arm.1.field.1.elements'.freeze
  RECURSIVE_EXPECTED_DOCS = [
    {'pk' => 1, 'doc' => {'payload' => [{'v' => 42}, [7, 'peer']] }},
    {'pk' => 2, 'doc' => {'payload' => [{'v' => 42}, [nil]]}},
    {'pk' => 3, 'doc' => {'payload' => [{'v' => 42}, []]}},
    {'pk' => 4, 'doc' => {}},
    {'pk' => 5, 'doc' => {'payload' => [{'v' => 42}, [7]]}},
    # Input Nothing NULL is omitted by ObjectDocumentCodec before storage;
    # full Object materialization therefore has the same empty document as pk4.
    {'pk' => 6, 'doc' => {}},
    {'pk' => 7, 'doc' => {'payload' => [{'v' => 42}, []]}},
    {'pk' => 8, 'doc' => {'payload' => [{'v' => 42}, ['late']]}},
  ].freeze
  RECURSIVE_EXPECTED_NESTED_TYPES = {
    'normal' => {1 => %w[Int64 String], 2 => ['NULL'], 3 => [], 4 => [], 5 => ['UInt8'], 6 => [], 7 => [], 8 => ['String']},
    'type_only' => {1 => %w[UInt8 String], 2 => ['NULL'], 3 => [], 4 => [], 5 => ['UInt8'], 6 => [], 7 => [], 8 => ['String']},
  }.freeze
  RECURSIVE_EXPECTED_WINDOWS = {
    'middle' => [3, 4, 5, 6],
    'last' => [7, 8],
    'empty_interior' => [],
    'zero_count_end' => [],
  }.freeze
  RECURSIVE_HELPER_TOP_KEYS = %w[format input_sha256 output_root requested_frame_bytes profile_ids profiles].freeze
  RECURSIVE_HELPER_PROFILE_KEYS = %w[
    id shared_version string_profile bucket_count outer_actual_type logical_dynamic_child_type
    shared_path_carrier_type normal_part type_only_part pair_comparison
  ].freeze
  RECURSIVE_HELPER_PART_KEYS = %w[
    role path schema_declaration columns_text count_text count shared_version bucket_count string_profile
    ordinary_string_profile mark_row_counts physical_stream_names physical_file_inventory full_rows
    direct_payload_rows nested_type_witnesses bounded_windows outer_actual_type nested_descriptor_path
    nested_dynamic_cap
  ].freeze
  RECURSIVE_PAIR_KEYS = %w[
    json_projection_equal type_change_preserved_json full_rows_equal direct_payload_rows_equal
    normal_pk1_nested_actual_type type_only_pk1_nested_actual_type normal_json_projection type_only_json_projection
  ].freeze
  DYNAMIC_COLUMN = 'Dynamic(max_types=8)'.freeze
  NATIVE_OBJECT_PATH_WRAPPER = 'Dynamic'.freeze
  ATTACHED_NATIVE_EXTRA_FILE = 'invalidated_system_columns.txt'.freeze
  ATTACHED_NATIVE_EXTRA_BYTES = "_block_offset\n_block_number\n".b.freeze
  CHILD_FIELDS = {'arr' => ['v', 's'], 'late' => ['v', 'late_only_child']}.freeze
  GENERATED_TYPES = {
    'arr' => {
      'outer' => 'Array(JSON(max_dynamic_types=1, max_dynamic_paths=1, v UInt8))',
      'element' => 'JSON(max_dynamic_types=1, max_dynamic_paths=1, v UInt8)',
      'fields' => {'v' => 'UInt8', 's' => 'String'},
    },
    'late' => {
      'outer' => 'Array(JSON(max_dynamic_types=1, max_dynamic_paths=2, v UInt8))',
      'element' => 'JSON(max_dynamic_types=1, max_dynamic_paths=2, v UInt8)',
      'fields' => {'v' => 'UInt8', 'late_only_child' => 'String'},
    },
  }.freeze
  EXPECTED_ROWS = W240::ROWS
  EXPECTED_CHILDREN = {
    'arr' => [
      [1, {'s' => 'one', 'v' => 1}], [1, {'s' => 'two', 'v' => 2}],
      [2, {'s' => 'three', 'v' => 3}], [5, {'s' => 'five', 'v' => 5}],
      [7, {'s' => 'seven', 'v' => 7}], [8, {'s' => 'eight', 'v' => 8}],
    ].freeze,
    'late' => [[8, {'late_only_child' => 'last-chunk-only', 'v' => 80}]].freeze,
  }.freeze

  class Failure < StandardError; end

  # Evidence envelopes are protocol objects: silently accepting a duplicate
  # key would make the last spelling win and could hide a forged earlier
  # value. Keep SQL-rendered logical JSON on JSON.parse's normal path below.
  class UniqueKeyJSONHash < Hash
    def []=(key, value)
      raise JSON::ParserError, "duplicate object key #{key.inspect}" if key?(key)
      super
    end
  end

  def self.parse_evidence_json!(bytes, label)
    JSON.parse(bytes, object_class: UniqueKeyJSONHash)
  rescue JSON::ParserError => error
    raise Failure, "#{label} is invalid evidence JSON: #{error.message}"
  end

  class Probe
    def self.preflight_w241_capture!(binary, w241_root, expected_w241_sha256)
      probe = allocate
      probe.instance_variable_set(:@root, nil)
      probe.instance_variable_set(:@binary, probe.send(:validate_executable, binary))
      probe.instance_variable_set(:@w241_root, probe.send(:validate_capture_root, w241_root))
      probe.instance_variable_set(:@expected_w241_sha256,
                                  probe.send(:validate_sha256, expected_w241_sha256, 'W241 summary'))
      probe.instance_variable_set(:@part_inputs, [])
      probe.instance_variable_set(:@part_snapshots, {})
      probe.send(:validate_w241_api_shape!)
      probe.send(:authenticate_w241_capture!)
      {
        status: 'w241_capture_authenticated_read_only',
        w241_root: probe.instance_variable_get(:@w241_root),
        summary_sha256: probe.instance_variable_get(:@w241_summary_sha256),
        helper_format: probe.instance_variable_get(:@helper_data).fetch('format'),
        profile_count: probe.instance_variable_get(:@profile_data).size,
        part_count: probe.instance_variable_get(:@part_inputs).size,
      }
    end

    def self.calibrate_retained_nested_capture!(binary, w241_root, expected_w241_sha256, w242_root)
      probe = allocate
      probe.instance_variable_set(:@root, nil)
      probe.instance_variable_set(:@binary, probe.send(:validate_executable, binary))
      probe.instance_variable_set(:@w241_root, probe.send(:validate_capture_root, w241_root))
      probe.instance_variable_set(:@expected_w241_sha256,
                                  probe.send(:validate_sha256, expected_w241_sha256, 'W241 summary'))
      probe.instance_variable_set(:@part_inputs, [])
      probe.instance_variable_set(:@part_snapshots, {})
      probe.instance_variable_set(:@profiles, [])
      probe.send(:authenticate_w241_capture!)
      stdout, label, = probe.send(:read_retained_w242_invocation!, w242_root,
                                  invocation_label: 'w241_nested_direct_types',
                                  last_stage: 'w241_nested_direct_types',
                                  failure_fragment: 'native selected-path wrapper cap differs')
      probe.send(:validate_nested_type_oracle_output!, stdout, invocation_label: label)
      group_count = probe.instance_variable_get(:@profiles).size
      native_query = probe.instance_variable_get(:@nested_query)
      mutant_lines = stdout.lines
      first_path_index = mutant_lines.index { |line| line.start_with?(PATH_TAG + "\t") }
      probe.send(:require_true, !first_path_index.nil?, 'retained W242 output has no path row to mutate')
      first_path_fields = mutant_lines.fetch(first_path_index).chomp.split("\t", -1)
      probe.send(:require_true, first_path_fields.size == 8 && first_path_fields[5] == NATIVE_OBJECT_PATH_WRAPPER,
                 'retained W242 first path row does not carry the exact native wrapper')
      first_path_fields[5] = 'Dynamic(max_types=254)'
      mutant_lines[first_path_index] = first_path_fields.join("\t") + "\n"
      probe.instance_variable_set(:@profiles, [])
      probe.instance_variable_set(:@nested_query, nil)
      wrapper_mutant_rejected = begin
        probe.send(:validate_nested_type_oracle_output!, mutant_lines.join, invocation_label: label)
        false
      rescue Failure => error
        error.message.include?('native Object-path wrapper differs')
      end
      probe.send(:require_true, wrapper_mutant_rejected,
                 'parser-only cap mutation was not rejected at the native wrapper boundary')
      {
        status: 'retained_nested_type_parser_observed',
        source_summary_sha256: probe.instance_variable_get(:@w241_summary_sha256),
        invocation: label,
        profile_path_group_count: group_count,
        native_path_rows: native_query.fetch(:path_row_count),
        native_child_rows: native_query.fetch(:child_row_count),
        selected_path_wrapper: NATIVE_OBJECT_PATH_WRAPPER,
        parser_only_wrong_wrapper_mutant_rejected: wrapper_mutant_rejected,
      }
    end

    def self.calibrate_retained_tuple_capture!(binary, w241_root, expected_w241_sha256, w242_root)
      probe = allocate
      probe.instance_variable_set(:@root, nil)
      probe.instance_variable_set(:@binary, probe.send(:validate_executable, binary))
      probe.instance_variable_set(:@w241_root, probe.send(:validate_capture_root, w241_root))
      probe.instance_variable_set(:@expected_w241_sha256,
                                  probe.send(:validate_sha256, expected_w241_sha256, 'W241 summary'))
      probe.instance_variable_set(:@part_inputs, [])
      probe.instance_variable_set(:@part_snapshots, {})
      probe.instance_variable_set(:@profiles, [])
      probe.send(:authenticate_w241_capture!)
      persisted_stdout, = probe.send(:read_retained_w242_invocation!, w242_root,
                                     invocation_label: 'tuple_json_array_dynamic_persist',
                                     last_stage: 'tuple_json_array_dynamic_reopen',
                                     failure_fragment: 'Tuple actual descriptor differs at pk 1')
      reopened_stdout, = probe.send(:read_retained_w242_invocation!, w242_root,
                                    invocation_label: 'tuple_json_array_dynamic_reopen',
                                    last_stage: 'tuple_json_array_dynamic_reopen',
                                    failure_fragment: 'Tuple actual descriptor differs at pk 1')
      root = File.expand_path(w242_root)
      probe.instance_variable_set(:@root, root)
      suffix = Digest::SHA256.hexdigest(root)[0, 8]
      tuple_table = "w242_#{suffix}_tuple"
      deep_table = "w242_#{suffix}_deep"
      probe.send(:validate_tuple_persist!, persisted_stdout, tuple_table, deep_table)
      tuple_rows = probe.send(:tagged_rows, reopened_stdout, TUPLE_TAG, 10)
      deep_rows = probe.send(:tagged_rows, reopened_stdout, DEEP_TAG, 8)
      probe.send(:validate_tuple_rows!, tuple_rows)
      probe.send(:validate_deep_rows!, deep_rows)
      {
        status: 'retained_tuple_parser_observed',
        tuple_rows: tuple_rows.size,
        deep_rows: deep_rows.size,
        exact_dynamic_actual_type: TUPLE_TYPE,
        exact_dynamic_element_type: TUPLE_SELECTED_TYPE,
        same_json_different_nested_dynamic_type: true,
      }
    end

    def initialize(binary, evidence_root, w241_root, expected_w241_sha256, recursive_helper)
      @binary = validate_executable(binary)
      @recursive_helper = validate_executable(recursive_helper, 'recursive Crystal helper')
      @root = validate_evidence_root(evidence_root)
      @w241_root = validate_capture_root(w241_root)
      @expected_w241_sha256 = validate_sha256(expected_w241_sha256, 'W241 summary')
      @runner = W241::Probe.new(@binary, @binary, @root)
      @invocations = @runner.instance_variable_get(:@invocations)
      @part_inputs = []
      @part_snapshots = {}
      @profiles = []
      @recursive_profiles = []
      @recursive_parts = []
      @recursive_part_snapshots = {}
      @recursive_capture = nil
      @fatal_error = nil
      @last_stage = nil
    end

    def run
      prepare_evidence_tree!
      @binary_sha_before = Digest::SHA256.file(@binary).hexdigest
      require_true(@binary_sha_before == W241::BINARY_SHA256, 'runtime SHA-256 differs from the W241 pin')
      authenticate_w241_capture!
      attach_w241_parts!
      capture_nested_type_oracle!
      capture_recursive_generated_parts!
      capture_persisted_tuple_oracle!
      assert_unchanged_inputs!
      @binary_sha_after = Digest::SHA256.file(@binary).hexdigest
      require_true(@binary_sha_after == W241::BINARY_SHA256, 'runtime SHA-256 changed during capture')
      write_summary('native_type_oracle_observed', nil)
      puts "W242 status=native_type_oracle_observed; path_groups=#{@profiles.size}; profiles=#{W241::PROFILE_IDS.size}; recursive_parts=#{@recursive_parts.size}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @binary_sha_after = Digest::SHA256.file(@binary).hexdigest rescue nil
      status = failure_status
      write_summary(status, @fatal_error) rescue nil
      warn "W242 native type oracle incomplete: status=#{status}; #{@fatal_error}"
      false
    end

    private

    def require_true(condition, message)
      raise Failure, "W242: #{message}" unless condition
    end

    def validate_sha256(value, label)
      require_true(value.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(value), "#{label} SHA-256 is malformed")
      value
    end

    def validate_executable(path, label = 'ClickHouse executable')
      require_true(path.is_a?(String) && !path.empty?, "#{label} path is required")
      expanded = File.expand_path(path)
      require_true(File.file?(expanded) && File.executable?(expanded) && !File.symlink?(expanded),
                   "#{label} is absent, non-executable, or symlinked")
      expanded
    end

    def validate_evidence_root(path)
      require_true(path.is_a?(String) && !path.empty?, 'evidence root is required')
      expanded = File.expand_path(path)
      require_true(File.dirname(expanded) == File.realpath('/private/tmp'),
                   'evidence root must be a direct child of /private/tmp')
      require_true(File.directory?(expanded) && !File.symlink?(expanded) &&
                   File.realpath(expanded) == expanded && Dir.children(expanded).empty?,
                   'evidence root must already exist, be canonical, and be empty')
      expanded
    rescue Errno::ENOENT
      raise Failure, 'evidence root must already exist'
    end

    def validate_capture_root(path)
      require_true(path.is_a?(String) && !path.empty?, 'W241 capture root is required')
      expanded = File.expand_path(path)
      require_true(File.dirname(expanded) == File.realpath('/private/tmp') &&
                   File.directory?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded,
                   'W241 capture root must be a canonical direct child of /private/tmp')
      require_true(expanded != @root, 'W241 and W242 roots must be distinct')
      expanded
    rescue Errno::ENOENT
      raise Failure, 'W241 capture root is unavailable'
    end

    def prepare_evidence_tree!
      %w[invocations stores parts].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      %w[w241 tuple recursive].each { |name| Dir.mkdir(File.join(@root, 'stores', name), 0o700) }
      Dir.mkdir(File.join(@root, 'generated_recursive'), 0o700)
    end

    def read_bounded(path, max_bytes, label)
      require_true(File.file?(path) && !File.symlink?(path), "#{label} is absent, non-regular, or symlinked")
      size = File.size(path)
      require_true(size >= 0 && size <= max_bytes, "#{label} exceeds its byte bound")
      bytes = File.binread(path)
      require_true(bytes.bytesize == size, "#{label} changed while reading")
      bytes
    end

    def authenticate_w241_capture!
      validate_w241_api_shape!
      summary_path = File.join(@w241_root, 'summary.json')
      summary_bytes = read_bounded(summary_path, SUMMARY_MAX_BYTES, 'W241 summary')
      observed_sha = Digest::SHA256.hexdigest(summary_bytes)
      require_true(observed_sha == @expected_w241_sha256, 'W241 summary SHA-256 differs from the supplied pin')
      summary = ProbeObjectRecursiveDynamicW242.parse_evidence_json!(summary_bytes, 'W241 summary')
      require_true(summary.is_a?(Hash) && summary['format'] == W241::FORMAT_CAPTURE &&
                   summary['status'] == 'paired_stock_crystal_observed' && summary['fatal_error'].nil?,
                   'W241 capture is not a complete successful paired observation')
      runtime = summary.fetch('runtime')
      require_true(runtime['sha256'] == W241::BINARY_SHA256 && runtime['version'] == W241::VERSION &&
                   runtime['build'] == W241::BUILD && runtime['sha256_before'] == W241::BINARY_SHA256 &&
                   runtime['sha256_after'] == W241::BINARY_SHA256,
                   'W241 runtime identity differs from the exact native pin')
      require_true(summary['profile_ids'] == W241::PROFILE_IDS &&
                   summary.fetch('profiles').map { |profile| profile.fetch('id') } == W241::PROFILE_IDS,
                   'W241 profile roster/order differs from the fixed eight-profile matrix')
      require_true(summary['requested_frame_bytes'] == 32 || summary['requested_frame_bytes'] == 64,
                   'W241 frame-size request is outside its closed profile')
      authenticate_helper_output!(summary)

      @w241_summary = summary
      @w241_summary_sha256 = observed_sha
      @helper_data = @authenticated_helper_data
      @profile_data = {}
      summary.fetch('profiles').each do |profile|
        canonical = W241::PROFILES.find { |candidate| candidate.fetch(:id) == profile.fetch('id') }
        require_true(canonical && profile['status'] == 'paired_stock_crystal_observed' &&
                     profile['shared_version'] == canonical.fetch(:layout).fetch(:enum) &&
                     profile['string_profile'] == canonical.fetch(:string).fetch(:id),
                     "W241 profile metadata differs for #{profile['id']}")
        @profile_data[profile.fetch('id')] = {summary: profile, canonical: canonical}
      end
      authenticate_parts!
      true
    rescue KeyError, JSON::ParserError, TypeError => error
      raise Failure, "W241 capture authentication failed: #{error.class}: #{error.message}"
    end

    def validate_w241_api_shape!
      require_true(W241::BINARY_SHA256.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(W241::BINARY_SHA256) &&
                   W241::VERSION.is_a?(String) && !W241::VERSION.empty? &&
                   W241::BUILD.is_a?(String) && !W241::BUILD.empty?,
                   'W241 runtime pin constants are malformed')
      require_true(W241::PROFILE_IDS.is_a?(Array) && W241::PROFILE_IDS.size == 8 &&
                   W241::PROFILE_IDS.all? { |id| id.is_a?(String) } &&
                   W241::PROFILES.is_a?(Array) && W241::PROFILES.size == W241::PROFILE_IDS.size &&
                   W241::PROFILES.map { |profile| profile.fetch(:id) } == W241::PROFILE_IDS,
                   'W241 fixed profile constants are malformed')
      require_true(W241::MEMORY.is_a?(Integer) && W241::MEMORY.positive? &&
                   W241::TIMEOUT.is_a?(Numeric) && W241::TIMEOUT.positive? &&
                   W241::GRACE.is_a?(Numeric) && W241::GRACE.positive? &&
                   W241::OUTER_RUN_SAFE_LIMIT.is_a?(Integer) && W241::OUTER_RUN_SAFE_LIMIT.positive?,
                   'W241 process-bound constants are malformed')
      require_true(W241::Auditor::HELPER_FORMAT.is_a?(String) && !W241::Auditor::HELPER_FORMAT.empty? &&
                   W241::W240::TYPE.is_a?(String) && W241::W240::ROWS.is_a?(Array) &&
                   W241::W185::Probe.respond_to?(:allocate) && W241::Auditor.respond_to?(:stream_hash),
                   'W241 helper, fixture, or audit API shape differs')
      true
    rescue KeyError, NameError, NoMethodError, TypeError => error
      raise Failure, "W241 API shape is incompatible: #{error.class}: #{error.message}"
    end

    def authenticate_helper_output!(summary)
      record = summary.fetch('helper')
      require_true(record.is_a?(Hash) && record['process_classification'] == 'success' && record['exit'] == 0 &&
                   record['signal'].nil? && record['timed_out'] == false && record['stderr_bytes'] == 0,
                   'W241 helper invocation is not a successful clean observation')
      name = record.fetch('stdout_file')
      require_true(File.basename(name) == name && /\A[a-zA-Z0-9_.-]+\z/.match?(name),
                   'W241 helper stdout basename is unsafe')
      bytes = read_bounded(File.join(@w241_root, 'invocations', name), PART_TOTAL_MAX_BYTES,
                           'W241 helper stdout')
      require_true(bytes.bytesize == record.fetch('stdout_bytes') &&
                   Digest::SHA256.hexdigest(bytes) == record.fetch('stdout_sha256'),
                   'W241 helper stdout digest/size differs from its captured invocation')
      data = ProbeObjectRecursiveDynamicW242.parse_evidence_json!(bytes, 'W241 helper stdout')
      require_true(data.is_a?(Hash) && data['format'] == W241_HELPER_FORMAT &&
                   data['profile_ids'] == W241::PROFILE_IDS,
                   'W241 helper output profile or format differs')
      input = summary.fetch('helper_input')
      require_true(input.is_a?(Hash) && input.keys.sort == %w[capture_root format frame_bytes profiles] &&
                   input['format'] == W241::FORMAT_INPUT && input['frame_bytes'] == summary.fetch('requested_frame_bytes') &&
                   input['capture_root'] == File.realpath('/private/tmp'),
                   'W241 helper input envelope differs from its closed schema')
      input_profiles = input.fetch('profiles')
      summary_profiles = summary.fetch('profiles').each_with_object({}) do |profile, result|
        result[profile.fetch('id')] = profile
      end
      require_true(input_profiles.is_a?(Array) && input_profiles.size == W241::PROFILE_IDS.size &&
                   input_profiles.map { |profile| profile.fetch('id') } == W241::PROFILE_IDS,
                   'W241 helper input profile order differs')
      input_profiles.each do |profile_input|
        profile = W241::PROFILES.find { |candidate| candidate.fetch(:id) == profile_input.fetch('id') }
        capture_profile = summary_profiles.fetch(profile_input.fetch('id'))
        stock_part_path = capture_profile.fetch('source_stock_part').fetch('path')
        expected_input = {
          'id' => profile.fetch(:id),
          'shared_version' => profile.fetch(:layout).fetch(:enum),
          'string_profile' => profile.fetch(:string).fetch(:id),
          'source_part' => stock_part_path,
        }
        require_true(profile_input == expected_input,
                     "W241 helper input source/profile binding differs for #{profile.fetch(:id)}")
      end
      input_bytes = read_bounded(File.join(@w241_root, 'generated', 'helper_input.json'), SUMMARY_MAX_BYTES,
                                 'W241 helper input')
      input_digest = Digest::SHA256.hexdigest(input_bytes)
      require_true(ProbeObjectRecursiveDynamicW242.parse_evidence_json!(input_bytes, 'W241 helper input') == input &&
                   data['input_sha256'] == input_digest,
                   'W241 helper output is not bound to the captured input')
      @authenticated_helper_input_sha256 = input_digest
      @authenticated_helper_data = data
    rescue KeyError, JSON::ParserError, TypeError => error
      raise Failure, "W241 helper evidence authentication failed: #{error.class}: #{error.message}"
    end

    def authenticate_parts!
      helper_profiles = @helper_data.fetch('profiles')
      require_true(helper_profiles.map { |profile| profile.fetch('id') } == W241::PROFILE_IDS,
                   'W241 helper output has a different profile order')
      W241::PROFILE_IDS.each do |id|
        profile_record = @profile_data.fetch(id)
        profile = profile_record.fetch(:canonical)
        capture_profile = profile_record.fetch(:summary)
        helper_profile = helper_profiles.find { |candidate| candidate.fetch('id') == id }
        require_true(helper_profile, "W241 helper output is missing #{id}")
        parts = {
          'stock_source' => [capture_profile.fetch('source_stock_part'), helper_profile.fetch('source_read'), 'stock source'],
          'crystal_generated' => [capture_profile.fetch('crystal_generated_part'), helper_profile.fetch('generated_read'), 'Crystal generated'],
        }
        parts.each do |role_key, (part_summary, helper_read, role)|
          path = canonical_part_path(part_summary.fetch('path'))
          inventory = part_summary.fetch('inventory')
          authenticate_part_files!(path, inventory, profile, role)
          validate_nested_expectations!(id, role_key, helper_read, helper_profile)
          snapshot = part_snapshot(path)
          key = "#{id}:#{role_key}"
          @part_snapshots[key] = {source_path: path, before: snapshot}
          @part_inputs << {profile_id: id, role: role_key, path: path, inventory: inventory,
                           helper_read: helper_read, profile: profile}
        end
      end
    rescue KeyError, TypeError => error
      raise Failure, "W241 part authentication failed: #{error.class}: #{error.message}"
    end

    def canonical_part_path(raw_path)
      require_true(raw_path.is_a?(String) && raw_path.start_with?(File::SEPARATOR) && !raw_path.include?("\0"),
                   'W241 part path is not absolute canonical text')
      path = raw_path.end_with?(File::SEPARATOR) ? raw_path[0...-1] : raw_path
      require_true(!path.end_with?(File::SEPARATOR) && File.expand_path(path) == path,
                   'W241 part path has noncanonical separators')
      root = File.realpath('/private/tmp')
      require_true(path.start_with?(root + File::SEPARATOR), 'W241 part path escaped /private/tmp')
      require_true(File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path,
                   'W241 part path is absent, symlinked, or noncanonical')
      tree = W241::W185::Probe.allocate
      tree.send(:validate_plain_tree!, path)
      path
    end

    def authenticate_part_files!(path, inventory, profile, role)
      names = inventory.fetch('physical_file_names')
      require_true(names.is_a?(Array) && names == names.sort && names.uniq == names,
                   "#{profile.fetch(:id)} #{role} physical file roster is malformed")
      actual_names = Dir.children(path).sort
      require_true(actual_names == names, "#{profile.fetch(:id)} #{role} physical file roster differs")
      total = 0
      actual_names.each do |name|
        require_true(File.basename(name) == name && /\A[a-zA-Z0-9_.-]+\z/.match?(name),
                     "#{profile.fetch(:id)} #{role} has unsafe physical basename")
        file_path = File.join(path, name)
        size = File.size(file_path)
        require_true(size >= 0 && size <= PART_FILE_MAX_BYTES,
                     "#{profile.fetch(:id)} #{role} file exceeds the per-file byte bound: #{name}")
        total += size
        require_true(total <= PART_TOTAL_MAX_BYTES,
                     "#{profile.fetch(:id)} #{role} part exceeds the total byte bound")
      end

      columns = read_bounded(File.join(path, 'columns.txt'), PART_FILE_MAX_BYTES, 'part columns.txt')
      columns_text = inventory.fetch('columns_text')
      require_true(columns == columns_text, "#{profile.fetch(:id)} #{role} columns.txt differs from captured metadata")
      W241.validate_part_columns!(columns_text, profile, role)
      substreams = read_bounded(File.join(path, 'columns_substreams.txt'), PART_FILE_MAX_BYTES,
                                'part columns_substreams.txt')
      require_true(substreams == inventory.fetch('columns_substreams_text'),
                   "#{profile.fetch(:id)} #{role} columns_substreams.txt differs from captured metadata")
      count = read_bounded(File.join(path, 'count.txt'), 1024, 'part count.txt').strip
      require_true(count == inventory.fetch('count_text') && count == '8',
                   "#{profile.fetch(:id)} #{role} count.txt differs from captured metadata")
      serialization = read_bounded(File.join(path, 'serialization.json'), PART_FILE_MAX_BYTES,
                                   'part serialization.json')
      require_true(Digest::SHA256.hexdigest(serialization) == inventory.fetch('serialization_json_sha256'),
                   "#{profile.fetch(:id)} #{role} serialization.json digest differs")
      checksums = read_bounded(File.join(path, 'checksums.txt'), PART_FILE_MAX_BYTES, 'part checksums.txt')
      require_true(Digest::SHA256.hexdigest(checksums) == inventory.fetch('checksums_sha256'),
                   "#{profile.fetch(:id)} #{role} checksums.txt digest differs")

      if role == 'Crystal generated'
        complete = inventory.fetch('complete_file_inventory')
        require_true(complete.is_a?(Hash) && complete.keys.sort == actual_names,
                     "#{profile.fetch(:id)} generated complete inventory roster differs")
        complete.each do |name, item|
          bytes = read_bounded(File.join(path, name), PART_FILE_MAX_BYTES, "generated part file #{name}")
          require_true(bytes.bytesize == item.fetch('size') && Digest::SHA256.hexdigest(bytes) == item.fetch('sha256'),
                       "#{profile.fetch(:id)} generated part file digest differs: #{name}")
        end
      else
        expected_stream_files = inventory.fetch('logical_substreams').flat_map do |stream|
          stem = W241::Auditor.stream_hash(stream)
          ["#{stem}.bin", "#{stem}.mrk2"]
        end.sort
        stream_inventory = inventory.fetch('stream_file_inventory')
        require_true(stream_inventory.is_a?(Hash) && stream_inventory.keys.sort == expected_stream_files,
                     "#{profile.fetch(:id)} source stream inventory roster differs")
        stream_inventory.each do |name, item|
          bytes = read_bounded(File.join(path, name), PART_FILE_MAX_BYTES, "source stream file #{name}")
          require_true(bytes.bytesize == item.fetch('size') && Digest::SHA256.hexdigest(bytes) == item.fetch('sha256'),
                       "#{profile.fetch(:id)} source stream file digest differs: #{name}")
        end
      end
      true
    rescue KeyError, TypeError => error
      raise Failure, "#{profile.fetch(:id)} #{role} inventory failed: #{error.class}: #{error.message}"
    end

    def validate_nested_expectations!(profile_id, role_key, helper_read, helper_profile)
      role = role_key == 'stock_source' ? 'stock source' : 'Crystal generated'
      witnesses = helper_read.fetch('nested_type_witnesses')
      require_true(witnesses.is_a?(Array) && witnesses.size == EXPECTED_ROWS.size,
                   "#{profile_id} #{role} nested type witness row domain differs")
      rows_by_pk = witnesses.each_with_object({}) { |row, result| result[row.fetch('pk')] = row }
      require_true(rows_by_pk.keys.sort == EXPECTED_ROWS.map { |row| row.fetch(:pk) }.sort,
                   "#{profile_id} #{role} nested type witness keys differ")
      {'arr' => 1, 'late' => 8}.each do |path, sample_pk|
        witness = rows_by_pk.fetch(sample_pk).fetch('paths').fetch(path)
        require_true(witness.fetch('outer_type').start_with?('Array(JSON(') || witness.fetch('outer_type') == 'Array(JSON)',
                     "#{profile_id} #{role} #{path} lacks the prepared Array(JSON) actual")
        require_true(witness.fetch('element_type').start_with?('JSON(') || witness.fetch('element_type') == 'JSON',
                     "#{profile_id} #{role} #{path} lacks an exact JSON element descriptor")
        fields = witness.fetch('first_element_child_types')
        require_true(fields.is_a?(Hash) && fields.keys.sort == CHILD_FIELDS.fetch(path).sort,
                     "#{profile_id} #{role} #{path} nested field type roster differs")
      end
      if role == 'Crystal generated'
        actuals = helper_profile.fetch('writer').fetch('prepared_actuals')
        expected = GENERATED_TYPES
        {'arr' => 1, 'late' => 2}.each do |path, paths_count|
          descriptor = "Array(JSON(max_dynamic_types=1, max_dynamic_paths=#{paths_count}, v UInt8))"
          prepared = actuals.find { |item| item.fetch('type') == descriptor }
          require_true(prepared && prepared.fetch('typed_child') == 'v UInt8' &&
                       prepared.fetch('dynamic_child') == (path == 'arr' ? 's String' : 'late_only_child String'),
                       "#{profile_id} generated #{path} actual descriptor/children differ from the prepared plan")
          native_expectation = expected.fetch(path)
          actual_witness = rows_by_pk.fetch(path == 'arr' ? 1 : 8).fetch('paths').fetch(path)
          require_true(actual_witness.fetch('outer_type') == native_expectation.fetch('outer') &&
                       actual_witness.fetch('element_type') == native_expectation.fetch('element') &&
                       actual_witness.fetch('first_element_child_types') == native_expectation.fetch('fields'),
                       "#{profile_id} generated #{path} reader witness differs from the exact plan")
        end
      end
      true
    rescue KeyError, TypeError => error
      raise Failure, "#{profile_id} #{role_key} nested type expectations failed: #{error.class}: #{error.message}"
    end

    def part_snapshot(path)
      entries = []
      Find.find(path) do |entry|
        stat = File.lstat(entry)
        require_true(!stat.symlink? && (stat.file? || stat.directory?), "symlink or special file in part: #{entry}")
        next if stat.directory?
        size = stat.size
        require_true(size <= PART_FILE_MAX_BYTES, "part file exceeds snapshot bound: #{entry}")
        entries << [entry.delete_prefix(path + File::SEPARATOR), size, Digest::SHA256.file(entry).hexdigest]
      end
      entries.sort
    end

    def table_name(profile_id, role)
      "w242_#{Digest::SHA256.hexdigest(@root)[0, 8]}_#{profile_id}_#{role}"
    end

    def native_stage(label, store, sql)
      @last_stage = label
      input = [@runner.send(:pin_sql), 'SET print_pretty_type_names=0;', 'SET output_format_json_quote_64bit_integers=0;', sql].join("\n")
      observation = @runner.send(:native, label, store, input)
      record = observation.fetch(:record)
      @current_native_observation = observation
      require_true(record.fetch(:binary_sha_before) == W241::BINARY_SHA256 &&
                   record.fetch(:binary_sha_after) == W241::BINARY_SHA256,
                   "#{label} did not preserve the pinned runtime identity")
      if observation.fetch(:classification) == 'success'
        @runner.send(:assert_native_success!, observation, label)
        @runner.send(:assert_pin!, observation.fetch(:stdout), label)
      end
      observation
    end

    def attach_w241_parts!
      store = File.join(@root, 'stores', 'w241')
      creates = []
      paths_query_names = []
      @part_inputs.each do |part|
        profile = part.fetch(:profile)
        id = profile.fetch(:id)
        role = part.fetch(:role)
        name = table_name(id, role == 'stock_source' ? 'source' : 'generated')
        part[:table] = name
        pk_type = W241.part_pk_type!(profile, role == 'stock_source' ? 'stock source' : 'Crystal generated')
        creates << "CREATE TABLE default.#{name} (pk #{pk_type}, doc #{W240::TYPE}) ENGINE=MergeTree ORDER BY pk SETTINGS #{@runner.send(:settings, profile)};"
        paths_query_names << "'#{name}'"
      end
      creates << "SELECT '__W242_PATH__', name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name IN (#{paths_query_names.join(',')}) ORDER BY name FORMAT TSVRaw;"
      created = native_stage('w241_target_create', store, creates.join("\n"))
      require_success!(created, 'W241 table creation')
      path_rows = tagged_rows(created.fetch(:stdout), PATH_TAG, 3)
      require_true(path_rows.size == @part_inputs.size, 'W241 target path roster differs')
      paths_by_name = path_rows.each_with_object({}) do |row, result|
        result[row[1]] = canonical_store_path(row[2], store)
      end
      require_true(paths_by_name.keys.sort == @part_inputs.map { |part| part.fetch(:table) }.sort,
                   'W241 target table path names differ')

      @part_inputs.each do |part|
        target_root = paths_by_name.fetch(part.fetch(:table))
        detached = File.join(target_root, 'detached')
        FileUtils.mkdir_p(detached, mode: 0o700)
        require_true(!File.symlink?(detached), 'target detached directory is symlinked')
        destination = File.join(detached, 'all_1_1_0')
        require_true(!File.exist?(destination) && !File.symlink?(destination), 'refusing to overwrite target part')
        FileUtils.cp_r(part.fetch(:path), destination, preserve: true)
        part[:copied_path] = destination
        part[:copied_snapshot] = part_snapshot(destination)
      end

      statements = []
      @part_inputs.each do |part|
        id = part.fetch(:profile).fetch(:id)
        table = part.fetch(:table)
        role = part.fetch(:role)
        statements << "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0';"
        statements << "SELECT '__W242_CHECK_BEGIN__', '#{id}', '#{role}' FORMAT TSVRaw;"
        statements << "CHECK TABLE default.#{table} FORMAT TSV;"
        statements << "SELECT '__W242_CHECK_END__', '#{id}', '#{role}' FORMAT TSVRaw;"
        statements << "SELECT '__W242_SCHEMA__', '#{id}', '#{role}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;"
        statements << "SELECT '__W242_PART__', '#{id}', '#{role}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;"
      end
      attached = native_stage('w241_attach_check', store, statements.join("\n"))
      require_success!(attached, 'W241 part ATTACH/CHECK')
      verify_attached_parts!(attached.fetch(:stdout))
      @part_inputs.each do |part|
        key = "#{part.fetch(:profile).fetch(:id)}:#{part.fetch(:role)}"
        @part_snapshots.fetch(key)[:attached_path] = part.fetch(:attached_path)
        @part_snapshots.fetch(key)[:attached_before] = part.fetch(:attached_snapshot)
      end
      true
    end

    def canonical_store_path(path, store)
      require_true(path.is_a?(String) && path.start_with?(File::SEPARATOR), 'native target path is not absolute')
      normalized = path.end_with?(File::SEPARATOR) ? path[0...-1] : path
      store_root = File.realpath(store)
      require_true(normalized.start_with?(store_root + File::SEPARATOR) && File.expand_path(normalized) == normalized,
                   'native target path escaped the isolated store')
      current = store_root
      normalized.delete_prefix(store_root + File::SEPARATOR).split(File::SEPARATOR).each do |component|
        current = File.join(current, component)
        require_true(!File.symlink?(current), "symlink in native target path #{current}") if File.exist?(current) || File.symlink?(current)
      end
      normalized
    end

    def verify_attached_parts!(stdout)
      W241::PROFILE_IDS.each do |id|
        %w[stock_source crystal_generated].each do |role|
          part = @part_inputs.find { |item| item.fetch(:profile).fetch(:id) == id && item.fetch(:role) == role }
          require_true(part, "missing attached input #{id}/#{role}")
          role_name = role_display(role)
          checks = check_rows_between(stdout, id, role)
          require_true(checks == ["all_1_1_0\t1\t"], "#{id}/#{role} native CHECK output differs")
          schemas = tagged_rows(stdout, '__W242_SCHEMA__', 5).select { |row| row[1] == id && row[2] == role }
          pk_type = W241.part_pk_type!(part.fetch(:profile), role_name)
          require_true(schemas.map { |row| row.drop(3) } == [['pk', pk_type], ['doc', W240::TYPE]],
                       "#{id}/#{role} attached schema differs")
          parts = tagged_rows(stdout, '__W242_PART__', 9).select { |row| row[1] == id && row[2] == role }
          require_true(parts.size == 1 && parts[0].values_at(3, 4, 6, 7, 8) ==
                       [part.fetch(:table), 'all_1_1_0', 'Wide', '8', '5'],
                       "#{id}/#{role} attached Wide part rows/marks differ")
          active_path = canonical_store_path(parts[0][5], File.join(@root, 'stores', 'w241'))
          part[:attached_path] = active_path
          attached_snapshot = part_snapshot(active_path)
          require_true(attached_snapshot_matches?(part.fetch(:copied_snapshot), active_path),
                       "#{id}/#{role} ATTACH changed copied files or added unexpected metadata")
          part[:attached_snapshot] = attached_snapshot
        end
      end
      true
    end

    def role_display(role)
      case role
      when 'stock_source' then 'stock source'
      when 'crystal_generated' then 'Crystal generated'
      else
        raise Failure, "unrecognized W241 part role: #{role.inspect}"
      end
    end

    def attached_snapshot_matches?(copied_snapshot, attached_path)
      copied = copied_snapshot.each_with_object({}) do |(name, size, sha256), result|
        result[name] = [size, sha256]
      end
      attached = part_snapshot(attached_path).each_with_object({}) do |(name, size, sha256), result|
        result[name] = [size, sha256]
      end
      require_true(!copied.key?(ATTACHED_NATIVE_EXTRA_FILE),
                   'copied source already contains native-only invalidation metadata')
      require_true((attached.keys - copied.keys) == [ATTACHED_NATIVE_EXTRA_FILE] &&
                   (copied.keys - attached.keys).empty?,
                   'ATTACH file roster differs from source plus the one native-added file')
      copied.each do |name, metadata|
        require_true(attached.fetch(name) == metadata, "ATTACH changed original copied file #{name}")
      end
      extra = read_bounded(File.join(attached_path, ATTACHED_NATIVE_EXTRA_FILE), 1024,
                           'ATTACH invalidated_system_columns.txt')
      require_true(extra == ATTACHED_NATIVE_EXTRA_BYTES,
                   'ATTACH native-added invalidation metadata differs from the exact admitted bytes')
      true
    end

    def check_rows_between(stdout, id, role)
      lines = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      begin_tag = "__W242_CHECK_BEGIN__\t#{id}\t#{role}"
      end_tag = "__W242_CHECK_END__\t#{id}\t#{role}"
      active = false
      matches = []
      lines.each do |line|
        if line == begin_tag
          require_true(!active, 'nested CHECK begin marker')
          active = true
        elsif line == end_tag
          require_true(active, 'CHECK end marker without begin')
          active = false
        elsif active
          matches << line
        end
      end
      require_true(!active, 'unterminated CHECK marker interval')
      matches
    end

    def tagged_rows(stdout, tag, fields)
      rows = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp).map do |line|
        next unless line.start_with?(tag + "\t")
        row = line.split("\t", -1)
        require_true(row.size == fields && row[0] == tag, "malformed #{tag} row")
        row
      end.compact
      rows
    end

    def capture_nested_type_oracle!
      sql = []
      @part_inputs.each do |part|
        profile = part.fetch(:profile)
        id = profile.fetch(:id)
        role = part.fetch(:role)
        role_name = role == 'stock_source' ? 'stock source' : 'Crystal generated'
        helper_read = part.fetch(:helper_read)
        witnesses = helper_read.fetch('nested_type_witnesses').each_with_object({}) do |row, result|
          result[row.fetch('pk')] = row
        end
        %w[arr late].each do |path|
          outer_types = witnesses.each_with_object({}) do |(pk, row), result|
            path_witness = row.fetch('paths').fetch(path, nil)
            result[pk] = path_witness.fetch('outer_type') if path_witness
          end
          type = outer_types.fetch(path == 'arr' ? 1 : 8)
          table = part.fetch(:table)
          sql << "SELECT '#{PATH_TAG}', '#{id}', '#{role_name}', '#{path}', toString(pk), toTypeName(doc.#{path}), if(isNull(doc.#{path}), 'NULL', dynamicType(doc.#{path})), if(isNull(doc.#{path}), '6e756c6c', hex(toJSONString(doc.#{path}))) FROM default.#{table} ORDER BY pk FORMAT TSVRaw;"
          fields = CHILD_FIELDS.fetch(path)
          expression = "dynamicElement(doc.#{path}, #{sql_quote(type)})"
          first_actual = role == 'stock_source' ? "dynamicType(child.#{fields[0]})" : "toTypeName(child.#{fields[0]})"
          second_actual = "dynamicType(child.#{fields[1]})"
          sql << "SELECT '#{CHILD_TAG}', '#{id}', '#{role_name}', '#{path}', toString(pk), toTypeName(child), hex(toJSONString(child)), hex(toJSONString(JSONAllPathsWithTypes(child))), toTypeName(child.#{fields[0]}), #{first_actual}, toTypeName(child.#{fields[1]}), #{second_actual} FROM default.#{table} ARRAY JOIN #{expression} AS child ORDER BY pk, hex(toJSONString(child)) FORMAT TSVRaw;"
        end
      end
      observed = native_stage('w241_nested_direct_types', File.join(@root, 'stores', 'w241'), sql.join("\n"))
      require_success!(observed, 'direct nested type query')
      validate_nested_type_oracle_output!(observed.fetch(:stdout), invocation_label: observed.fetch(:record).fetch(:label))
    end

    def validate_nested_type_oracle_output!(stdout, invocation_label:)
      path_rows = tagged_rows(stdout, PATH_TAG, 8)
      child_rows = tagged_rows(stdout, CHILD_TAG, 12)
      require_true(path_rows.size == W241::PROFILE_IDS.size * 2 * EXPECTED_ROWS.size * 2,
                   'nested native path oracle has extra or missing profile/role/path rows')
      expected_children_per_path = EXPECTED_CHILDREN.transform_values(&:size)
      require_true(child_rows.size == W241::PROFILE_IDS.size * 2 * expected_children_per_path.values.sum,
                   'nested native child oracle has extra or missing profile/role/path rows')
      @part_inputs.each do |part|
        profile_id = part.fetch(:profile).fetch(:id)
        role = part.fetch(:role)
        role_name = role == 'stock_source' ? 'stock source' : 'Crystal generated'
        helper_witnesses = part.fetch(:helper_read).fetch('nested_type_witnesses').each_with_object({}) do |row, result|
          result[row.fetch('pk')] = row
        end
        %w[arr late].each do |path|
          fields = CHILD_FIELDS.fetch(path)
          path_rows_for = path_rows.select { |row| row[1] == profile_id && row[2] == role_name && row[3] == path }
          require_true(path_rows_for.size == EXPECTED_ROWS.size, "#{profile_id}/#{role}/#{path} direct row domain differs")
          expected_values = EXPECTED_ROWS.map { |row| [row.fetch(:pk), row.fetch(:doc).fetch(path, nil)] }
          actual_by_pk = path_rows_for.each_with_object({}) do |row, result|
            pk = Integer(row[4], 10)
            actual_type = row[6]
            value = row[7] == '6e756c6c' ? nil : JSON.parse([row[7]].pack('H*'))
            result[pk] = {wrapper_type: row[5], actual_type: actual_type, value: value}
          end
          require_true(actual_by_pk.keys.sort == expected_values.map(&:first), "#{profile_id}/#{role}/#{path} direct keys differ")
          expected_values.each do |pk, expected_value|
            witness = helper_witnesses.fetch(pk).fetch('paths').fetch(path, nil)
            native = actual_by_pk.fetch(pk)
            require_true(native.fetch(:wrapper_type) == NATIVE_OBJECT_PATH_WRAPPER,
                         "#{profile_id}/#{role}/#{path} native Object-path wrapper differs")
            require_true(native.fetch(:value) == expected_value,
                         "#{profile_id}/#{role}/#{path} path value differs at pk #{pk}")
            if witness
              require_true(native.fetch(:actual_type) == witness.fetch('outer_type'),
                           "#{profile_id}/#{role}/#{path} actual arm type differs at pk #{pk}")
            else
              require_true(native.fetch(:actual_type) == 'NULL',
                           "#{profile_id}/#{role}/#{path} absent path is not NULL at pk #{pk}")
            end
          end

          actual_children = child_rows.select { |row| row[1] == profile_id && row[2] == role_name && row[3] == path }
          expected_children = EXPECTED_CHILDREN.fetch(path).map do |pk, value|
            {pk: pk, value: value, value_hex: value_json_hex(value)}
          end
          require_true(actual_children.size == expected_children.size,
                       "#{profile_id}/#{role}/#{path} child row count differs")
          normalized = actual_children.map { |row| normalize_child_row(row) }.sort_by { |row| [row.fetch(:pk), row.fetch(:value_hex)] }
          expected_sorted = expected_children.sort_by { |row| [row.fetch(:pk), row.fetch(:value_hex)] }
          require_true(normalized.map { |row| [row.fetch(:pk), row.fetch(:value)] } ==
                       expected_sorted.map { |row| [row.fetch(:pk), row.fetch(:value)] },
                       "#{profile_id}/#{role}/#{path} child logical values differ")
          normalized.each do |child|
            witness = helper_witnesses.fetch(child.fetch(:pk)).fetch('paths').fetch(path)
            exact_fields = witness.fetch('first_element_child_types')
            validate_child_types!(child, exact_fields, "#{profile_id}/#{role}/#{path}")
            require_true(child.fetch(:element_type) == witness.fetch('element_type'),
                         "#{profile_id}/#{role}/#{path} nested JSON element descriptor differs")
            require_true(child.fetch(:path_types) == exact_fields,
                         "#{profile_id}/#{role}/#{path} JSONAllPathsWithTypes differs")
            dynamic_cap = witness.fetch('element_type')[/\AJSON\(max_dynamic_types=(\d+),/, 1]
            require_true(dynamic_cap, "#{profile_id}/#{role}/#{path} nested JSON descriptor omits dynamic cap")
            expected_first_wrapper = role == 'stock_source' ? "Dynamic(max_types=#{dynamic_cap})" : exact_fields.fetch(fields[0])
            expected_second_wrapper = "Dynamic(max_types=#{dynamic_cap})"
            require_true(child.fetch(:first_field_wrapper) == expected_first_wrapper &&
                         child.fetch(:second_field_wrapper) == expected_second_wrapper &&
                         child.fetch(:first_field_actual) == exact_fields.fetch(fields[0]) &&
                         child.fetch(:second_field_actual) == exact_fields.fetch(fields[1]),
                         "#{profile_id}/#{role}/#{path} nested field wrapper/actual type differs")
          end
          @profiles << {id: profile_id, role: role, path: path,
                        outer_rows: path_rows_for.size, child_rows: normalized.size,
                        child_actual_types: normalized.map { |row| row.fetch(:path_types) }.uniq,
                        selected_path_wrapper: path_rows_for.first && path_rows_for.first[5],
                        nested_field_wrappers: normalized.map { |row| [row.fetch(:first_field_wrapper), row.fetch(:second_field_wrapper)] }.uniq}
        end
      end
      assert_source_generated_value_parity!(child_rows)
      @nested_query = {invocation_label: invocation_label,
                       path_row_count: path_rows.size, child_row_count: child_rows.size,
                       direct_sql_scope: 'doc.arr/doc.late projections only; no full doc expression',
                       rows: child_rows.map { |row| normalize_child_row(row) }}
      true
    end

    def read_retained_w242_invocation!(raw_root, invocation_label:, last_stage:, failure_fragment:)
      require_true(raw_root.is_a?(String) && !raw_root.empty?, 'retained W242 capture root is required')
      root = File.expand_path(raw_root)
      require_true(File.dirname(root) == File.realpath('/private/tmp') &&
                   File.directory?(root) && !File.symlink?(root) && File.realpath(root) == root &&
                   root != @w241_root,
                   'retained W242 root must be a canonical distinct direct child of /private/tmp')
      summary_bytes = read_bounded(File.join(root, 'summary.json'), SUMMARY_MAX_BYTES, 'retained W242 summary')
      summary = ProbeObjectRecursiveDynamicW242.parse_evidence_json!(summary_bytes, 'retained W242 summary')
      require_true(summary.is_a?(Hash) && summary['format'] == FORMAT &&
                   summary['status'] == 'capture_failure_inconclusive' &&
                   summary['last_stage'] == last_stage &&
                   summary['fatal_error'].to_s.include?(failure_fragment),
                   'retained W242 summary is not the expected parser-correction capture')
      runtime = summary.fetch('runtime')
      require_true(runtime.is_a?(Hash) && runtime['path'] == @binary &&
                   runtime['sha256'] == W241::BINARY_SHA256 &&
                   runtime['sha256_before'] == W241::BINARY_SHA256 &&
                   runtime['sha256_after'] == W241::BINARY_SHA256 &&
                   runtime['version'] == W241::VERSION && runtime['build'] == W241::BUILD,
                   'retained W242 summary runtime pin differs')
      source = summary.fetch('source_capture')
      require_true(source.is_a?(Hash) && source['w241_root'] == @w241_root &&
                   source['w241_summary_sha256'] == @w241_summary_sha256 &&
                   source['expected_summary_sha256'] == @expected_w241_sha256,
                   'retained W242 summary is not bound to the authenticated W241 source')
      records = summary.fetch('invocations').select { |item| item.is_a?(Hash) && item['label'] == invocation_label }
      require_true(records.size == 1, "retained W242 #{invocation_label} invocation is missing or duplicated")
      record = records.first
      require_true(record['process_kind'] == 'clickhouse-local' && record['process_classification'] == 'success' &&
                   record['exit'] == 0 && record['signal'].nil? && record['timed_out'] == false &&
                   record['spawn_error'].nil? && record['stdin_write_error'].nil? &&
                   record['stdout_read_error'].nil? && record['stderr_read_error'].nil? &&
                   record['binary_path'] == @binary && record['expected_binary_sha256'] == W241::BINARY_SHA256 &&
                   record['binary_sha_before'] == W241::BINARY_SHA256 &&
                   record['binary_sha_after'] == W241::BINARY_SHA256,
                   'retained W242 nested query is not a clean pinned native success')
      artifacts = {
        'argv_file' => ['argv_sha256', nil],
        'stdin_file' => ['stdin_sha256', 'stdin_bytes'],
        'stdout_file' => ['stdout_sha256', 'stdout_bytes'],
        'stderr_file' => ['stderr_sha256', 'stderr_bytes'],
      }
      artifact_bytes = {}
      artifacts.each do |file_key, (sha_key, size_key)|
        name = record.fetch(file_key)
        require_true(name.is_a?(String) && File.basename(name) == name && /\A[a-zA-Z0-9_.-]+\z/.match?(name),
                     "retained W242 #{file_key} basename is unsafe")
        bytes = read_bounded(File.join(root, 'invocations', name), PART_TOTAL_MAX_BYTES,
                             "retained W242 #{file_key}")
        require_true(Digest::SHA256.hexdigest(bytes) == record.fetch(sha_key),
                     "retained W242 #{file_key} digest differs")
        require_true(bytes.bytesize == record.fetch(size_key),
                     "retained W242 #{file_key} byte count differs") if size_key
        artifact_bytes[file_key] = bytes
      end
      argv_record = ProbeObjectRecursiveDynamicW242.parse_evidence_json!(artifact_bytes.fetch('argv_file'),
                                                                         'retained W242 argv file')
      require_true(argv_record == record.fetch('argv'), 'retained W242 argv file differs from the captured argv')
      stdout = artifact_bytes.fetch('stdout_file').force_encoding(Encoding::UTF_8)
      pins = tagged_rows(stdout, PIN_TAG, 3)
      require_true(pins == [[PIN_TAG, W241::VERSION, W241::BUILD]],
                   'retained W242 native output pin differs')
      [stdout, record.fetch('label'), root]
    rescue Errno::ENOENT, KeyError, JSON::ParserError, TypeError => error
      raise Failure, "retained W242 capture authentication failed: #{error.class}: #{error.message}"
    end

    def normalize_child_row(row)
      {
        profile_id: row[1], role: row[2], path: row[3], pk: Integer(row[4], 10),
        element_type: row[5], value_hex: row[6].downcase,
        value: JSON.parse([row[6]].pack('H*')),
        path_types: JSON.parse([row[7]].pack('H*')),
        first_field_wrapper: row[8], first_field_actual: row[9],
        second_field_wrapper: row[10], second_field_actual: row[11],
      }
    rescue JSON::ParserError, ArgumentError => error
      raise Failure, "malformed child type/value witness: #{error.class}: #{error.message}"
    end

    def validate_child_types!(row, expected_fields, label)
      require_true(row.fetch(:element_type).start_with?('JSON('), "#{label} child element is not parameterized JSON")
      require_true(row.fetch(:path_types).is_a?(Hash) && row.fetch(:path_types) == expected_fields,
                   "#{label} JSON path type map differs")
      fields = CHILD_FIELDS.fetch(row.fetch(:path))
      require_true(row.fetch(:first_field_actual) == expected_fields.fetch(fields[0]) &&
                   row.fetch(:second_field_actual) == expected_fields.fetch(fields[1]),
                   "#{label} direct child actual field types differ")
      true
    rescue KeyError, TypeError => error
      raise Failure, "#{label} child type fields malformed: #{error.class}: #{error.message}"
    end

    def value_json_hex(value)
      JSON.generate(value).unpack1('H*')
    end

    def assert_source_generated_value_parity!(raw_child_rows)
      rows = raw_child_rows.map { |row| normalize_child_row(row) }
      W241::PROFILE_IDS.each do |profile_id|
        %w[arr late].each do |path|
          source_rows = rows.select { |row| row.fetch(:profile_id) == profile_id && row.fetch(:role) == 'stock source' && row.fetch(:path) == path }
          generated_rows = rows.select { |row| row.fetch(:profile_id) == profile_id && row.fetch(:role) == 'Crystal generated' && row.fetch(:path) == path }
          source_values = source_rows.map { |row| [row.fetch(:pk), row.fetch(:value)] }.sort_by(&:first)
          generated_values = generated_rows.map { |row| [row.fetch(:pk), row.fetch(:value)] }.sort_by(&:first)
          require_true(source_values == generated_values, "#{profile_id}/#{path} stock/generated logical values differ")
          source = rows.find { |row| row.fetch(:profile_id) == profile_id && row.fetch(:role) == 'stock source' && row.fetch(:path) == path }
          generated = rows.find { |row| row.fetch(:profile_id) == profile_id && row.fetch(:role) == 'Crystal generated' && row.fetch(:path) == path }
          require_true(source && generated && source.fetch(:path_types).fetch('v') == 'Int64' &&
                       generated.fetch(:path_types).fetch('v') == 'UInt8',
                       "#{profile_id}/#{path} did not preserve the Int64-versus-UInt8 type discriminator")
          require_true(source.fetch(:value) == generated.fetch(:value),
                       "#{profile_id}/#{path} type discriminator changed the normalized child value")
          mutant = generated.dup
          mutant[:path_types] = generated.fetch(:path_types).merge('v' => source.fetch(:path_types).fetch('v'))
          rejected = begin
            validate_child_types!(mutant, GENERATED_TYPES.fetch(path).fetch('fields'), "#{profile_id} type-only mutant")
            false
          rescue Failure
            true
          end
          require_true(rejected && mutant.fetch(:value_hex) == generated.fetch(:value_hex),
                       "#{profile_id}/#{path} type-only UInt8-to-Int64 mutation was not rejected with value bytes unchanged")
        end
      end
      true
    end

    def capture_recursive_generated_parts!
      helper_source = File.expand_path('check_object_recursive_dynamic_w242.cr', __dir__)
      require_true(File.file?(helper_source) && !File.symlink?(helper_source),
                   'recursive helper source is absent or symlinked')
      @recursive_helper_source_sha_before = Digest::SHA256.file(helper_source).hexdigest
      require_true(@recursive_helper_source_sha_before == RECURSIVE_HELPER_SOURCE_SHA256,
                   'recursive helper source differs from the frozen implementation')
      frame_bytes = @w241_summary.fetch('requested_frame_bytes')
      input = {
        'format' => RECURSIVE_INPUT_FORMAT,
        'frame_bytes' => frame_bytes,
        'profiles' => W241::PROFILES.map do |profile|
          {'id' => profile.fetch(:id),
           'shared_version' => profile.fetch(:layout).fetch(:enum),
           'string_profile' => profile.fetch(:string).fetch(:id)}
        end,
      }
      input_bytes = JSON.pretty_generate(input) + "\n"
      input_path = File.join(@root, 'invocations', 'recursive_helper_input.json')
      File.open(input_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(input_bytes) }
      output_root = File.join(@root, 'generated_recursive')
      require_true(File.directory?(output_root) && !File.symlink?(output_root) && Dir.children(output_root).empty?,
                   'recursive helper output root must be a fresh isolated directory')

      @recursive_helper_sha_before = Digest::SHA256.file(@recursive_helper).hexdigest
      observation = @runner.send(:run_process, 'recursive_crystal_helper',
                                 [@recursive_helper, input_path, output_root], ''.b, 'crystal-helper',
                                 expected_sha: @recursive_helper_sha_before,
                                 binary_path: @recursive_helper)
      @recursive_helper_sha_after = Digest::SHA256.file(@recursive_helper).hexdigest
      @recursive_helper_source_sha_after = Digest::SHA256.file(helper_source).hexdigest
      require_true(@recursive_helper_sha_before == @recursive_helper_sha_after,
                   'recursive helper executable changed during generation')
      require_true(@recursive_helper_source_sha_before == @recursive_helper_source_sha_after &&
                   @recursive_helper_source_sha_after == RECURSIVE_HELPER_SOURCE_SHA256,
                   'recursive helper source changed during generation')
      require_true(observation.fetch(:classification) == 'success' && observation.fetch(:status)&.success? &&
                   observation.fetch(:status)&.termsig.nil? && observation.fetch(:stderr).empty? &&
                   observation.fetch(:record).fetch(:exit) == 0,
                   'recursive helper did not produce a clean bounded success')
      lines = observation.fetch(:stdout).force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      require_true(lines.size == 1 && !lines.first.empty?,
                   'recursive helper must emit exactly one JSON object')
      data = ProbeObjectRecursiveDynamicW242.parse_evidence_json!(lines.first, 'recursive helper stdout')
      validate_recursive_helper_output!(data, input_bytes, output_root, frame_bytes)
      @recursive_helper_data = data
      @recursive_input_sha256 = Digest::SHA256.hexdigest(input_bytes)
      @recursive_parts = @recursive_profiles.flat_map do |profile_record|
        ['normal', 'type_only'].map do |role|
          helper_part = profile_record.fetch(:data).fetch("#{role}_part")
          {profile: profile_record.fetch(:profile), profile_id: profile_record.fetch(:profile).fetch(:id),
           role: role, helper_part: helper_part, path: helper_part.fetch('path')}
        end
      end
      attach_recursive_generated_parts!
      capture_recursive_direct_oracle!
      capture_recursive_full_oracle!
      @recursive_capture = {
        helper_source: helper_source,
        helper_source_sha256: @recursive_helper_source_sha_after,
        helper_executable: @recursive_helper,
        helper_executable_sha256_before: @recursive_helper_sha_before,
        helper_executable_sha256_after: @recursive_helper_sha_after,
        helper_input: input,
        helper_input_sha256: @recursive_input_sha256,
        helper_invocation: observation.fetch(:record),
        helper_output: data,
        output_root: output_root,
        requested_frame_bytes: frame_bytes,
        attached_part_count: @recursive_parts.size,
        direct_oracle: @recursive_direct_oracle,
        full_oracle: @recursive_full_oracle,
        window_interpretation: 'middle/last native rows are SQL-predicate projections; helper physical mark windows are independently recorded, and SQL predicates do not establish native physical mark-window traversal',
      }
      true
    rescue KeyError, JSON::ParserError, TypeError => error
      raise Failure, "recursive generated helper capture failed: #{error.class}: #{error.message}"
    end

    def validate_recursive_helper_output!(data, input_bytes, output_root, frame_bytes)
      require_true(data.is_a?(Hash) && data.keys.sort == RECURSIVE_HELPER_TOP_KEYS.sort,
                   'recursive helper output key set differs')
      require_true(data.fetch('format') == RECURSIVE_HELPER_FORMAT &&
                   data.fetch('input_sha256') == Digest::SHA256.hexdigest(input_bytes) &&
                   data.fetch('output_root') == File.realpath(output_root) &&
                   data.fetch('requested_frame_bytes') == frame_bytes &&
                   data.fetch('profile_ids') == W241::PROFILE_IDS,
                   'recursive helper output is not bound to the exact input/root/profile/frame request')
      records = data.fetch('profiles')
      require_true(records.is_a?(Array) && records.size == W241::PROFILE_IDS.size &&
                   records.map { |record| record.fetch('id') } == W241::PROFILE_IDS,
                   'recursive helper profile order/count differs')
      @recursive_profiles = []
      records.each_with_index do |record, index|
        profile = W241::PROFILES.fetch(index)
        validate_recursive_helper_profile!(record, profile, output_root)
        @recursive_profiles << {profile: profile, data: record}
      end
      true
    end

    def validate_recursive_helper_profile!(record, profile, output_root)
      id = profile.fetch(:id)
      version = profile.fetch(:layout).fetch(:enum)
      string_id = profile.fetch(:string).fetch(:id)
      bucket_count = [0, 2].include?(version) ? 1 : 2
      require_true(record.is_a?(Hash) && record.keys.sort == RECURSIVE_HELPER_PROFILE_KEYS.sort,
                   "#{id} recursive helper profile key set differs")
      require_true(record.fetch('id') == id && record.fetch('shared_version') == version &&
                   record.fetch('string_profile') == string_id && record.fetch('bucket_count') == bucket_count &&
                   record.fetch('outer_actual_type') == RECURSIVE_ACTUAL_TYPE &&
                   record.fetch('logical_dynamic_child_type') == RECURSIVE_NESTED_DESCRIPTOR &&
                   record.fetch('shared_path_carrier_type') == RECURSIVE_PATH_CARRIER,
                   "#{id} recursive helper profile descriptor/layout differs")

      normal = record.fetch('normal_part')
      type_only = record.fetch('type_only_part')
      validate_recursive_helper_part!(normal, profile, 'normal', output_root, bucket_count)
      validate_recursive_helper_part!(type_only, profile, 'type_only', output_root, bucket_count)
      validate_recursive_pair!(record.fetch('pair_comparison'), normal, type_only, id)
      true
    end

    def validate_recursive_helper_part!(part, profile, role, output_root, bucket_count)
      id = profile.fetch(:id)
      version = profile.fetch(:layout).fetch(:enum)
      string_id = profile.fetch(:string).fetch(:id)
      expected_path = File.join(output_root, "#{id}_#{role}")
      require_true(part.is_a?(Hash) && part.keys.sort == RECURSIVE_HELPER_PART_KEYS.sort,
                   "#{id}/#{role} recursive helper part key set differs")
      path = part.fetch('path')
      require_true(path == expected_path && File.directory?(path) && !File.symlink?(path) &&
                   File.realpath(path) == expected_path,
                   "#{id}/#{role} recursive generated part path escaped its isolated output root")
      require_true(part.fetch('role') == role && part.fetch('schema_declaration') == W241::STOCK_TYPE &&
                   part.fetch('columns_text') == W241.part_columns_text('UInt64') &&
                   part.fetch('count_text').strip == '8' && part.fetch('count') == 8 &&
                   part.fetch('shared_version') == version && part.fetch('bucket_count') == bucket_count &&
                   part.fetch('string_profile') == string_id &&
                   part.fetch('ordinary_string_profile') == profile.fetch(:string).fetch(:version) &&
                   part.fetch('mark_row_counts') == W241::MARK_ROWS &&
                   part.fetch('outer_actual_type') == RECURSIVE_ACTUAL_TYPE &&
                   part.fetch('nested_descriptor_path') == RECURSIVE_NESTED_SITE &&
                   part.fetch('nested_dynamic_cap') == 1,
                   "#{id}/#{role} recursive generated schema/layout/type metadata differs")
      W241.validate_part_columns!(part.fetch('columns_text'), profile, 'Crystal generated')

      names = Dir.children(path).sort
      inventory = part.fetch('physical_file_inventory')
      require_true(inventory.is_a?(Array) && inventory.size == names.size,
                   "#{id}/#{role} recursive generated physical file inventory count differs")
      inventory_by_name = {}
      inventory.each do |entry|
        require_true(entry.is_a?(Hash) && entry.keys.sort == %w[name sha256 size],
                     "#{id}/#{role} recursive physical file entry key set differs")
        name = entry.fetch('name')
        require_true(name.is_a?(String) && /\A[a-zA-Z0-9_.-]+\z/.match?(name) &&
                     !inventory_by_name.key?(name),
                     "#{id}/#{role} recursive physical file name is unsafe or duplicated")
        full_path = File.join(path, name)
        require_true(File.file?(full_path) && !File.symlink?(full_path),
                     "#{id}/#{role} recursive physical entry is not a regular file")
        size = File.size(full_path)
        require_true(size >= 0 && size <= PART_FILE_MAX_BYTES && entry.fetch('size') == size,
                     "#{id}/#{role} recursive physical file size differs: #{name}")
        bytes = read_bounded(full_path, PART_FILE_MAX_BYTES, "#{id}/#{role} generated part #{name}")
        require_true(Digest::SHA256.hexdigest(bytes) == entry.fetch('sha256'),
                     "#{id}/#{role} recursive physical file digest differs: #{name}")
        inventory_by_name[name] = entry
      end
      require_true(inventory_by_name.keys.sort == names && names == part_snapshot(path).map(&:first),
                   "#{id}/#{role} recursive physical file roster differs")
      total_bytes = inventory.sum { |entry| entry.fetch('size') }
      require_true(total_bytes <= PART_TOTAL_MAX_BYTES,
                   "#{id}/#{role} recursive generated part exceeds its total byte bound")

      columns = read_bounded(File.join(path, 'columns.txt'), PART_FILE_MAX_BYTES,
                             "#{id}/#{role} generated columns.txt")
      require_true(columns == part.fetch('columns_text'),
                   "#{id}/#{role} recursive columns.txt differs from helper metadata")
      substreams = read_bounded(File.join(path, 'columns_substreams.txt'), PART_FILE_MAX_BYTES,
                                "#{id}/#{role} generated columns_substreams.txt")
      object_streams = calibrate_recursive_substream_metadata!(substreams, profile,
                                                               "#{id}/#{role}")
      physical_streams = part.fetch('physical_stream_names')
      require_true(physical_streams.is_a?(Array) && physical_streams.all? { |name| name.is_a?(String) } &&
                   physical_streams.uniq == physical_streams && physical_streams == physical_streams.sort &&
                   physical_streams == object_streams.sort,
                   "#{id}/#{role} recursive Object stream roster differs from actual columns_substreams.txt")
      count = read_bounded(File.join(path, 'count.txt'), 1024, "#{id}/#{role} generated count.txt").strip
      require_true(count == part.fetch('count_text').strip && count == '8',
                   "#{id}/#{role} recursive count.txt differs")

      expected_docs = RECURSIVE_EXPECTED_DOCS
      full_rows = part.fetch('full_rows')
      require_true(full_rows.is_a?(Array) && full_rows == expected_docs,
                   "#{id}/#{role} helper full rows differ from the fixed fixture")
      direct_rows = part.fetch('direct_payload_rows')
      require_true(direct_rows.is_a?(Array) && direct_rows.size == expected_docs.size,
                   "#{id}/#{role} helper selected payload row domain differs")
      direct_rows.each_with_index do |row, index|
        expected_row = expected_docs.fetch(index)
        payload_present = expected_row.fetch('doc').key?('payload')
        expected_value = payload_present ? expected_row.fetch('doc').fetch('payload') : nil
        actual_type = payload_present ? RECURSIVE_ACTUAL_TYPE : 'NULL'
        require_true(row.is_a?(Hash) && row.keys.sort == %w[pk type value wrapper_type] &&
                     row.fetch('pk') == expected_row.fetch('pk') &&
                     row.fetch('wrapper_type') == RECURSIVE_PATH_CARRIER &&
                     row.fetch('type') == actual_type && row.fetch('value') == expected_value,
                     "#{id}/#{role} helper selected payload row differs at pk #{index + 1}")
      end
      validate_recursive_nested_witnesses!(part.fetch('nested_type_witnesses'), role, id)
      validate_recursive_windows!(part.fetch('bounded_windows'), role, id)
      true
    rescue KeyError, TypeError, Errno::ENOENT => error
      raise Failure, "#{id}/#{role} recursive helper part authentication failed: #{error.class}: #{error.message}"
    end

    def validate_recursive_nested_witnesses!(witnesses, role, profile_id)
      require_true(witnesses.is_a?(Array) && witnesses.size == 8,
                   "#{profile_id}/#{role} recursive nested type witness row domain differs")
      witnesses.each_with_index do |row, index|
        pk = index + 1
        expected_docs = RECURSIVE_EXPECTED_DOCS.fetch(index).fetch('doc')
        types = RECURSIVE_EXPECTED_NESTED_TYPES.fetch(role).fetch(pk)
        payload_present = expected_docs.key?('payload')
        state = !payload_present ? 'missing' : (expected_docs['payload'].nil? ? 'outer_null' : 'value')
        actual_type = state == 'missing' ? 'MISSING' : (state == 'outer_null' ? 'NULL' : RECURSIVE_ACTUAL_TYPE)
        json_v = state == 'value' ? 42 : nil
        require_true(row.is_a?(Hash) && row.keys.sort == %w[
          actual_type json_descriptor json_v nested_actuals nested_cap nested_descriptor
          nested_descriptor_path payload_state pk
        ].sort && row.fetch('pk') == pk && row.fetch('payload_state') == state &&
                     row.fetch('actual_type') == actual_type &&
                     row.fetch('json_descriptor') == RECURSIVE_JSON_DESCRIPTOR &&
                     row.fetch('json_v') == json_v &&
                     row.fetch('nested_descriptor_path') == RECURSIVE_NESTED_SITE &&
                     row.fetch('nested_descriptor') == RECURSIVE_NESTED_DESCRIPTOR &&
                     row.fetch('nested_cap') == 1,
                     "#{profile_id}/#{role} recursive type witness differs at pk #{pk}")
        actuals = row.fetch('nested_actuals')
        require_true(actuals.is_a?(Array) && actuals.size == types.size,
                     "#{profile_id}/#{role} nested Dynamic child count differs at pk #{pk}")
        actuals.each_with_index do |actual, child_index|
          expected_type = types.fetch(child_index)
          expected_value = if expected_type == 'NULL'
                             nil
                           elsif pk == 1 && child_index == 0
                             7
                           elsif pk == 1 && child_index == 1
                             'peer'
                           elsif pk == 5
                             7
                           else
                             'late'
                           end
          require_true(actual.is_a?(Hash) && actual.keys.sort == %w[index is_null actual_type value wrapper_type].sort &&
                       actual.fetch('index') == child_index &&
                       actual.fetch('is_null') == (expected_type == 'NULL') &&
                       actual.fetch('wrapper_type') == RECURSIVE_NESTED_DESCRIPTOR &&
                       actual.fetch('actual_type') == expected_type && actual.fetch('value') == expected_value,
                       "#{profile_id}/#{role} nested Dynamic occurrence differs at pk #{pk}, index #{child_index}")
        end
      end
      true
    end

    def validate_recursive_windows!(windows, role, profile_id)
      require_true(windows.is_a?(Array) && windows.size == 8,
                   "#{profile_id}/#{role} bounded window roster differs")
      expected_windows = RECURSIVE_WINDOW_SPECS.flat_map do |name, spec|
        %w[whole_object selected_path].map do |consumer|
          {consumer: consumer, path: consumer == 'whole_object' ? nil : 'payload', name: name,
           first_mark: spec.fetch('first_mark'), mark_count: spec.fetch('mark_count'),
           pks: spec.fetch('pks')}
        end
      end
      require_true(windows.map do |window|
        [window.fetch('consumer'), window.fetch('path'), window.fetch('window'),
         window.fetch('first_mark'), window.fetch('mark_count')]
      end == expected_windows.map do |item|
        [item.fetch(:consumer), item.fetch(:path), item.fetch(:name), item.fetch(:first_mark), item.fetch(:mark_count)]
      end, "#{profile_id}/#{role} bounded window order/domain differs")

      windows.each_with_index do |window, index|
        spec = expected_windows.fetch(index)
        pks = spec.fetch(:pks)
        expected_counts = spec.fetch(:mark_count) == 0 ? [] : Array.new(spec.fetch(:mark_count), 2)
        expected_rows = if spec.fetch(:consumer) == 'whole_object'
                          RECURSIVE_EXPECTED_DOCS.select { |row| pks.include?(row.fetch('pk')) }
                        else
                          RECURSIVE_EXPECTED_DOCS.select { |row| pks.include?(row.fetch('pk')) }.map do |row|
                            payload_present = row.fetch('doc').key?('payload')
                            payload = payload_present ? row.fetch('doc').fetch('payload') : nil
                            {'pk' => row.fetch('pk'), 'type' => payload_present ? RECURSIVE_ACTUAL_TYPE : 'NULL',
                             'wrapper_type' => RECURSIVE_PATH_CARRIER, 'value' => payload}
                          end
                        end
        path = spec.fetch(:path)
        require_true(window.is_a?(Hash) && window.keys.sort == %w[
          actual_mark_row_counts actual_rows consumer expected_mark_row_counts expected_rows first_mark
          mark_count matches_full_slice path window
        ].sort && window.fetch('expected_mark_row_counts') == expected_counts &&
                     window.fetch('actual_mark_row_counts') == expected_counts &&
                     window.fetch('expected_rows') == expected_rows && window.fetch('actual_rows') == expected_rows &&
                     window.fetch('matches_full_slice') == true,
                     "#{profile_id}/#{role} #{spec.fetch(:consumer)} #{spec.fetch(:name)} window differs")
      end
      true
    rescue KeyError, TypeError => error
      raise Failure, "#{profile_id}/#{role} bounded window authentication failed: #{error.class}: #{error.message}"
    end

    def validate_recursive_pair!(pair, normal, type_only, profile_id)
      require_true(pair.is_a?(Hash) && pair.keys.sort == RECURSIVE_PAIR_KEYS.sort,
                   "#{profile_id} recursive pair comparison key set differs")
      require_true(pair['json_projection_equal'] == true && pair['type_change_preserved_json'] == true &&
                   pair['full_rows_equal'] == true && pair['direct_payload_rows_equal'] == true &&
                   pair['normal_pk1_nested_actual_type'] == 'Int64' &&
                   pair['type_only_pk1_nested_actual_type'] == 'UInt8',
                   "#{profile_id} recursive pair does not isolate the expected nested type change")
      normal_projection = recursive_json_projection(normal.fetch('nested_type_witnesses'))
      type_only_projection = recursive_json_projection(type_only.fetch('nested_type_witnesses'))
      expected_projection = RECURSIVE_EXPECTED_DOCS.map do |row|
        {'pk' => row.fetch('pk'), 'v' => row.fetch('doc').key?('payload') && !row.fetch('doc').fetch('payload').nil? ? 42 : nil}
      end
      require_true(normal_projection == expected_projection && type_only_projection == expected_projection &&
                   normal_projection == type_only_projection && pair['normal_json_projection'] == normal_projection &&
                   pair['type_only_json_projection'] == type_only_projection,
                   "#{profile_id} recursive pair JSON projection differs")
      require_true(normal.fetch('full_rows') == type_only.fetch('full_rows') &&
                   normal.fetch('direct_payload_rows').map { |row| row.fetch('value') } ==
                     type_only.fetch('direct_payload_rows').map { |row| row.fetch('value') },
                   "#{profile_id} type-only pair changes logical rows")
      normal_types = normal.fetch('nested_type_witnesses').map do |row|
        row.fetch('nested_actuals').map { |actual| actual.fetch('actual_type') }
      end
      type_only_types = type_only.fetch('nested_type_witnesses').map do |row|
        row.fetch('nested_actuals').map { |actual| actual.fetch('actual_type') }
      end
      expected_normal = RECURSIVE_EXPECTED_NESTED_TYPES.fetch('normal')
      expected_type_only = RECURSIVE_EXPECTED_NESTED_TYPES.fetch('type_only')
      require_true(normal_types == (1..8).map { |pk| expected_normal.fetch(pk) } &&
                   type_only_types == (1..8).map { |pk| expected_type_only.fetch(pk) },
                   "#{profile_id} recursive pair nested Dynamic type roster differs")
      changed = []
      normal_types.each_with_index do |types, row_index|
        types.each_with_index do |type, child_index|
          other = type_only_types.fetch(row_index).fetch(child_index)
          changed << [row_index + 1, child_index, type, other] unless type == other
        end
      end
      require_true(changed == [[1, 0, 'Int64', 'UInt8']],
                   "#{profile_id} recursive pair changes more than the one expected nested type")
      true
    end

    def recursive_expected_object_streams(profile, bucket_count)
      version = profile.fetch(:layout).fetch(:enum)
      require_true(bucket_count == ([0, 2].include?(version) ? 1 : 2),
                   "#{profile.fetch(:id)} recursive bucket count is not canonical for shared version #{version}")
      streams = ['doc.object_structure']
      case version
      when 0
        streams.concat(%w[
          doc.object_shared_data.size0
          doc.object_shared_data%2Epaths
          doc.object_shared_data%2Evalues
        ])
      when 1
        bucket_count.times do |bucket|
          prefix = "doc.object_shared_data.#{bucket}"
          streams.concat(["#{prefix}.size0", "#{prefix}%2Epaths", "#{prefix}%2Evalues"])
        end
      when 2, 3
        bucket_count.times do |bucket|
          prefix = "doc.object_shared_data.#{bucket}"
          streams.concat(%w[structure data paths_marks substreams substreams_marks paths_substreams_metadata]
                         .map { |lane| "#{prefix}.#{lane}" })
        end
        streams.concat(%w[
          doc.object_shared_data.copy.sizes
          doc.object_shared_data.copy.paths_indexes
          doc.object_shared_data.copy.values
        ])
      else
        raise Failure, "unsupported recursive shared version #{version.inspect}"
      end
      streams.uniq.sort
    end

    def parse_recursive_substreams!(text, profile, bucket_count, label)
      require_true(text.is_a?(String) && text.valid_encoding?, "#{label} columns_substreams is not valid text")
      lines = text.split("\n", -1)
      require_true(lines.pop == '', "#{label} columns_substreams lacks final newline")
      require_true(lines.shift == 'columns substreams version: 1', "#{label} columns_substreams version differs")
      require_true(lines.shift == '2 columns:', "#{label} columns_substreams table column count differs")

      sections = []
      until lines.empty?
        header = lines.shift
        match = /\A(0|[1-9][0-9]*) substreams for column `([a-z][a-z0-9_]*)`:\z/.match(header)
        require_true(match, "#{label} columns_substreams has malformed section header")
        count = Integer(match[1], 10)
        require_true(count <= 64 && lines.size >= count, "#{label} substream count exceeds bounded envelope")
        names = count.times.map do
          line = lines.shift
          entry = /\A\t([A-Za-z0-9_.%]+)\z/.match(line)
          require_true(entry, "#{label} has malformed logical stream name")
          entry[1]
        end
        sections << [match[2], names]
        require_true(sections.size <= 2, "#{label} has extra metadata column section")
      end
      require_true(sections.map(&:first) == %w[pk doc], "#{label} metadata column roles/order differ")
      table_streams = sections.flat_map(&:last)
      object_streams = sections.fetch(1).fetch(1)
      require_true(sections.fetch(0).fetch(1) == ['pk'], "#{label} pk must own exactly one pk stream")
      require_true(table_streams.uniq == table_streams && object_streams.uniq == object_streams,
                   "#{label} has duplicate or aliased logical streams")
      expected = recursive_expected_object_streams(profile, bucket_count)
      require_true(object_streams.sort == expected,
                   "#{label} Object logical stream roster differs from exact W242 profile layout")
      stems = table_streams.map { |name| W241::Auditor.stream_hash(name) }
      require_true(stems.uniq == stems, "#{label} logical stream names alias a physical stream stem")
      object_streams.sort
    rescue KeyError, ArgumentError, TypeError => error
      raise Failure, "#{label} recursive stream metadata malformed: #{error.class}: #{error.message}"
    end

    def reject_recursive_substream_mutation!(text, profile, bucket_count, label, mutation)
      parse_recursive_substreams!(mutation.call(text), profile, bucket_count, label)
      raise Failure, "#{label} accepted recursive substream mutation"
    rescue Failure => error
      raise if error.message == "#{label} accepted recursive substream mutation"
      true
    end

    def calibrate_recursive_substream_metadata!(text, profile, label)
      bucket_count = [0, 2].include?(profile.fetch(:layout).fetch(:enum)) ? 1 : 2
      baseline = parse_recursive_substreams!(text, profile, bucket_count, label)
      return baseline if @recursive_substream_calibrated

      reject_recursive_substream_mutation!(text, profile, bucket_count, label, lambda do |source|
        source.sub("1 substreams for column `pk`:\n\tpk\n", "0 substreams for column `pk`:\n")
      end)
      doc_header = /^([0-9]+) substreams for column `doc`:$/.match(text)
      require_true(doc_header, "#{label} cannot calibrate absent doc section")
      increased_count = Integer(doc_header[1], 10) + 1
      reject_recursive_substream_mutation!(text, profile, bucket_count, label, lambda do |source|
        revised = source.sub(doc_header[0], "#{increased_count} substreams for column `doc`:")
        "#{revised}\tdoc.w242_unexpected\n"
      end)
      first_doc_stream = text.lines.find { |line| line.start_with?("\tdoc.") }
      require_true(first_doc_stream, "#{label} cannot calibrate a doc stream")
      reject_recursive_substream_mutation!(text, profile, bucket_count, label, lambda do |source|
        revised = source.sub(doc_header[0], "#{increased_count} substreams for column `doc`:")
        revised.sub(first_doc_stream, first_doc_stream + first_doc_stream)
      end)
      @recursive_substream_calibrated = true
      baseline
    end

    def recursive_json_projection(witnesses)
      witnesses.map do |row|
        {'pk' => row.fetch('pk'), 'v' => row.fetch('json_v')}
      end
    end

    def recursive_table_name(profile_id, role)
      suffix = role == 'normal' ? 'normal' : (role == 'type_only' ? 'type_only' : nil)
      require_true(suffix, "unrecognized recursive part role: #{role.inspect}")
      "w242_#{Digest::SHA256.hexdigest(@root)[0, 8]}_recursive_#{profile_id}_#{suffix}"
    end

    def attach_recursive_generated_parts!
      store = File.join(@root, 'stores', 'recursive')
      creates = []
      table_names = []
      @recursive_parts.each do |part|
        profile = part.fetch(:profile)
        profile_id = profile.fetch(:id)
        role = part.fetch(:role)
        table = recursive_table_name(profile_id, role)
        part[:table] = table
        part[:source_snapshot] = part_snapshot(part.fetch(:path))
        creates << "CREATE TABLE default.#{table} (pk UInt64, doc #{W241::STOCK_TYPE}) ENGINE=MergeTree ORDER BY pk SETTINGS #{@runner.send(:settings, profile)};"
        table_names << "'#{table}'"
      end
      creates << "SELECT '#{RECURSIVE_PATH_TAG}', database, name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name IN (#{table_names.join(',')}) ORDER BY name FORMAT TSVRaw;"
      created = native_stage('recursive_generated_create', store, creates.join("\n"))
      require_success!(created, 'recursive generated table creation')
      path_rows = tagged_rows(created.fetch(:stdout), RECURSIVE_PATH_TAG, 4)
      require_true(path_rows.size == @recursive_parts.size, 'recursive generated target path roster differs')
      paths_by_table = path_rows.each_with_object({}) do |row, result|
        require_true(row[1] == 'default' && !result.key?(row[2]),
                     'recursive target path has an unexpected database or duplicate table')
        result[row[2]] = canonical_store_path(row[3], store)
      end
      require_true(paths_by_table.keys.sort == @recursive_parts.map { |part| part.fetch(:table) }.sort,
                   'recursive generated target table names differ')

      @recursive_parts.each do |part|
        target_root = paths_by_table.fetch(part.fetch(:table))
        detached = File.join(target_root, 'detached')
        FileUtils.mkdir_p(detached, mode: 0o700)
        require_true(!File.symlink?(detached), 'recursive target detached directory is symlinked')
        destination = File.join(detached, 'all_1_1_0')
        require_true(!File.exist?(destination) && !File.symlink?(destination),
                     'refusing to overwrite recursive target part')
        FileUtils.cp_r(part.fetch(:path), destination, preserve: true)
        part[:copied_path] = destination
        part[:copied_snapshot] = part_snapshot(destination)
      end

      statements = []
      @recursive_parts.each do |part|
        profile_id = part.fetch(:profile).fetch(:id)
        role = part.fetch(:role)
        table = part.fetch(:table)
        statements << "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0';"
        statements << "SELECT '#{RECURSIVE_CHECK_BEGIN_TAG}', '#{profile_id}', '#{role}' FORMAT TSVRaw;"
        statements << "CHECK TABLE default.#{table} FORMAT TSV;"
        statements << "SELECT '#{RECURSIVE_CHECK_END_TAG}', '#{profile_id}', '#{role}' FORMAT TSVRaw;"
        statements << "SELECT '#{RECURSIVE_SCHEMA_TAG}', '#{profile_id}', '#{role}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;"
        statements << "SELECT '#{RECURSIVE_PART_TAG}', '#{profile_id}', '#{role}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;"
      end
      attached = native_stage('recursive_generated_attach_check', store, statements.join("\n"))
      require_success!(attached, 'recursive generated ATTACH/CHECK')
      verify_recursive_attached_parts!(attached.fetch(:stdout))
      true
    end

    def verify_recursive_attached_parts!(stdout)
      store = File.join(@root, 'stores', 'recursive')
      @recursive_parts.each do |part|
        profile_id = part.fetch(:profile).fetch(:id)
        role = part.fetch(:role)
        checks = check_rows_between(stdout, profile_id, role)
        require_true(checks == ["all_1_1_0\t1\t"], "#{profile_id}/#{role} recursive native CHECK differs")
        schemas = tagged_rows(stdout, RECURSIVE_SCHEMA_TAG, 5).select do |row|
          row[1] == profile_id && row[2] == role
        end
        require_true(schemas.map { |row| row.drop(3) } == [['pk', 'UInt64'], ['doc', W241::STOCK_TYPE]],
                     "#{profile_id}/#{role} recursive attached schema differs")
        parts = tagged_rows(stdout, RECURSIVE_PART_TAG, 9).select do |row|
          row[1] == profile_id && row[2] == role
        end
        require_true(parts.size == 1 && parts[0].values_at(3, 4, 6, 7, 8) ==
                     [part.fetch(:table), 'all_1_1_0', 'Wide', '8', '5'],
                     "#{profile_id}/#{role} recursive attached Wide part identity/count differs")
        attached_path = canonical_store_path(parts[0][5], store)
        require_true(attached_snapshot_matches?(part.fetch(:copied_snapshot), attached_path),
                     "#{profile_id}/#{role} recursive ATTACH changed copied part files")
        part[:attached_path] = attached_path
        part[:attached_snapshot] = part_snapshot(attached_path)
        key = "#{profile_id}:#{role}"
        @recursive_part_snapshots[key] = {
          source_path: part.fetch(:path), source_snapshot: part.fetch(:source_snapshot),
          attached_path: attached_path, attached_snapshot: part.fetch(:attached_snapshot),
        }
      end
      true
    end

    def recursive_base_select(tag, part, fields, predicate = nil)
      where = predicate ? " WHERE #{predicate}" : ''
      profile_id = part.fetch(:profile).fetch(:id)
      role = part.fetch(:role)
      table = part.fetch(:table)
      "SELECT '#{tag}', '#{profile_id}', '#{role}', toString(pk), #{fields} FROM default.#{table}#{where} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;"
    end

    def capture_recursive_direct_oracle!
      statements = []
      @recursive_parts.each do |part|
        payload = 'doc.payload'
        tuple = "assumeNotNull(dynamicElement(doc.payload, #{sql_quote(RECURSIVE_ACTUAL_TYPE)}))"
        direct_fields = [
          "toTypeName(#{payload})",
          "if(isNull(#{payload}), 'NULL', dynamicType(#{payload}))",
          "if(isNull(#{payload}), 'NULL', hex(toJSONString(#{payload})))",
        ].join(', ')
        statements << recursive_base_select(RECURSIVE_DIRECT_TAG, part, direct_fields)
        statements << recursive_base_select(RECURSIVE_DIRECT_MIDDLE_TAG, part, direct_fields, 'pk BETWEEN 3 AND 6')
        statements << recursive_base_select(RECURSIVE_DIRECT_LAST_TAG, part, direct_fields, 'pk BETWEEN 7 AND 8')

        type_fields = [
          "toTypeName(#{payload})",
          "dynamicType(#{payload})",
          "toTypeName(#{tuple})",
          "toTypeName(#{tuple}.1)",
          "hex(toJSONString(JSONAllPathsWithTypes(#{tuple}.1)))",
          "hex(toJSONString(#{tuple}.1))",
          "toTypeName(#{tuple}.2)",
          "hex(toJSONString(arrayMap(x -> toTypeName(x), #{tuple}.2)))",
          "hex(toJSONString(arrayMap(x -> if(isNull(x), 'NULL', dynamicType(x)), #{tuple}.2)))",
          "hex(toJSONString(#{tuple}.2))",
        ].join(', ')
        statements << recursive_base_select(RECURSIVE_DIRECT_TYPE_TAG, part, type_fields,
                                           'isNotNull(doc.payload)')
      end
      observed = native_stage('recursive_direct_types', File.join(@root, 'stores', 'recursive'), statements.join("\n"))
      require_success!(observed, 'recursive direct-only nested type query')
      @recursive_direct_oracle = validate_recursive_direct_oracle!(observed.fetch(:stdout))
      @recursive_direct_oracle[:invocation] = observed.fetch(:record).fetch(:label)
      @recursive_direct_oracle[:invocation_record] = observed.fetch(:record)
      true
    end

    def parse_json_hex!(value, label)
      require_true(value.is_a?(String) && value.match?(/\A(?:[0-9a-fA-F]{2})*\z/), "#{label} hex is malformed")
      JSON.parse([value].pack('H*'))
    rescue JSON::ParserError => error
      raise Failure, "#{label} JSON hex is invalid: #{error.message}"
    end

    def recursive_expected_payload(pk)
      doc = RECURSIVE_EXPECTED_DOCS.fetch(pk - 1).fetch('doc')
      doc.key?('payload') ? doc.fetch('payload') : nil
    end

    def validate_recursive_direct_oracle!(stdout)
      direct = tagged_rows(stdout, RECURSIVE_DIRECT_TAG, 7)
      middle = tagged_rows(stdout, RECURSIVE_DIRECT_MIDDLE_TAG, 7)
      last = tagged_rows(stdout, RECURSIVE_DIRECT_LAST_TAG, 7)
      types = tagged_rows(stdout, RECURSIVE_DIRECT_TYPE_TAG, 14)
      require_true(direct.size == @recursive_parts.size * 8 &&
                   middle.size == @recursive_parts.size * 4 && last.size == @recursive_parts.size * 2 &&
                   types.size == @recursive_parts.size * 6,
                   'recursive direct-only native result domain differs')
      type_rows_by_part = {}
      types.each do |row|
        key = [row[1], row[2]]
        (type_rows_by_part[key] ||= {})[Integer(row[3], 10)] = row
      end
      @recursive_parts.each do |part|
        profile_id = part.fetch(:profile).fetch(:id)
        role = part.fetch(:role)
        part_direct = direct.select { |row| row[1] == profile_id && row[2] == role }
        part_middle = middle.select { |row| row[1] == profile_id && row[2] == role }
        part_last = last.select { |row| row[1] == profile_id && row[2] == role }
        require_true(part_direct.map { |row| Integer(row[3], 10) } == (1..8).to_a &&
                     part_middle.map { |row| Integer(row[3], 10) } == [3, 4, 5, 6] &&
                     part_last.map { |row| Integer(row[3], 10) } == [7, 8],
                     "#{profile_id}/#{role} native direct SQL predicate row domains differ")
        native_rows = {}
        part_direct.each do |row|
          pk = Integer(row[3], 10)
          value = row[6] == 'NULL' ? nil : parse_json_hex!(row[6], "#{profile_id}/#{role}/#{pk} direct value")
          require_true(row[4] == NATIVE_OBJECT_PATH_WRAPPER &&
                       row[5] == (recursive_expected_payload(pk).nil? ? 'NULL' : RECURSIVE_ACTUAL_TYPE) &&
                       value == recursive_expected_payload(pk),
                       "#{profile_id}/#{role} native direct payload value/type differs at pk #{pk}")
          native_rows[pk] = row.drop(4)
        end
        expected_type_rows = RECURSIVE_EXPECTED_NESTED_TYPES.fetch(role)
        part_types = type_rows_by_part.fetch([profile_id, role])
        expected_present_payload_pks = (1..8).select { |pk| !recursive_expected_payload(pk).nil? }
        require_true(part_types.keys.sort == expected_present_payload_pks,
                     "#{profile_id}/#{role} native nested-type row domain differs")
        part_types.each do |pk, row|
          expected_children = expected_type_rows.fetch(pk)
          require_true(row[4] == NATIVE_OBJECT_PATH_WRAPPER && row[5] == RECURSIVE_ACTUAL_TYPE &&
                       row[6] == RECURSIVE_ACTUAL_TYPE && row[7] == RECURSIVE_JSON_DESCRIPTOR &&
                       parse_json_hex!(row[8], "#{profile_id}/#{role}/#{pk} JSON path types") == {'v' => 'UInt8'} &&
                       parse_json_hex!(row[9], "#{profile_id}/#{role}/#{pk} JSON child") == {'v' => 42} &&
                       row[10] == 'Array(Dynamic(max_types=1))',
                       "#{profile_id}/#{role} native actual descriptor/type tree differs at pk #{pk}")
          wrappers = parse_json_hex!(row[11], "#{profile_id}/#{role}/#{pk} Dynamic wrappers")
          actual_types = parse_json_hex!(row[12], "#{profile_id}/#{role}/#{pk} Dynamic actual types")
          nested_values = parse_json_hex!(row[13], "#{profile_id}/#{role}/#{pk} Dynamic values")
          require_true(wrappers == Array.new(expected_children.size, RECURSIVE_NESTED_DESCRIPTOR) &&
                       actual_types == expected_children &&
                       nested_values == recursive_expected_payload(pk).fetch(1),
                       "#{profile_id}/#{role} native nested Dynamic children differ at pk #{pk}")
        end
        expected_middle = part_direct.select { |row| [3, 4, 5, 6].include?(Integer(row[3], 10)) }.map { |row| row.drop(1) }
        expected_last = part_direct.select { |row| [7, 8].include?(Integer(row[3], 10)) }.map { |row| row.drop(1) }
        require_true(part_middle.map { |row| row.drop(1) } == expected_middle &&
                     part_last.map { |row| row.drop(1) } == expected_last,
                     "#{profile_id}/#{role} native direct middle/last SQL projections differ from full direct rows")
      end
      {
        exact_profile_role_parts: @recursive_parts.size,
        direct_rows: direct.size,
        typed_rows: types.size,
        middle_rows: middle.size,
        last_rows: last.size,
        selected_path_wrapper: NATIVE_OBJECT_PATH_WRAPPER,
        nested_descriptor: RECURSIVE_NESTED_DESCRIPTOR,
        full_object_column_absent_from_queries: true,
        middle_last_are_sql_predicates_only: true,
      }
    rescue KeyError, ArgumentError, TypeError => error
      raise Failure, "recursive direct-only oracle malformed: #{error.class}: #{error.message}"
    end

    def capture_recursive_full_oracle!
      statements = []
      fields = "toTypeName(doc), hex(toJSONString(doc))"
      @recursive_parts.each do |part|
        statements << recursive_base_select(RECURSIVE_FULL_TAG, part, fields)
        statements << recursive_base_select(RECURSIVE_FULL_MIDDLE_TAG, part, fields, 'pk BETWEEN 3 AND 6')
        statements << recursive_base_select(RECURSIVE_FULL_LAST_TAG, part, fields, 'pk BETWEEN 7 AND 8')
      end
      observed = native_stage('recursive_full_objects', File.join(@root, 'stores', 'recursive'), statements.join("\n"))
      require_success!(observed, 'recursive separate full-Object query')
      @recursive_full_oracle = validate_recursive_full_oracle!(observed.fetch(:stdout))
      @recursive_full_oracle[:invocation] = observed.fetch(:record).fetch(:label)
      @recursive_full_oracle[:invocation_record] = observed.fetch(:record)
      true
    end

    def validate_recursive_full_oracle!(stdout)
      full = tagged_rows(stdout, RECURSIVE_FULL_TAG, 6)
      middle = tagged_rows(stdout, RECURSIVE_FULL_MIDDLE_TAG, 6)
      last = tagged_rows(stdout, RECURSIVE_FULL_LAST_TAG, 6)
      require_true(full.size == @recursive_parts.size * 8 && middle.size == @recursive_parts.size * 4 &&
                   last.size == @recursive_parts.size * 2,
                   'recursive full-Object native result domain differs')
      @recursive_parts.each do |part|
        profile_id = part.fetch(:profile).fetch(:id)
        role = part.fetch(:role)
        full_rows = full.select { |row| row[1] == profile_id && row[2] == role }
        middle_rows = middle.select { |row| row[1] == profile_id && row[2] == role }
        last_rows = last.select { |row| row[1] == profile_id && row[2] == role }
        require_true(full_rows.map { |row| Integer(row[3], 10) } == (1..8).to_a &&
                     middle_rows.map { |row| Integer(row[3], 10) } == [3, 4, 5, 6] &&
                     last_rows.map { |row| Integer(row[3], 10) } == [7, 8],
                     "#{profile_id}/#{role} native full SQL predicate row domains differ")
        full_rows.each do |row|
          pk = Integer(row[3], 10)
          document = parse_json_hex!(row[5], "#{profile_id}/#{role}/#{pk} full document")
          expected = RECURSIVE_EXPECTED_DOCS.fetch(pk - 1).fetch('doc')
          require_true(row[4] == W241::STOCK_TYPE && document == expected,
                       "#{profile_id}/#{role} native full-Object descriptor/value differs at pk #{pk}")
        end
        expected_middle = full_rows.select { |row| [3, 4, 5, 6].include?(Integer(row[3], 10)) }.map { |row| row.drop(1) }
        expected_last = full_rows.select { |row| [7, 8].include?(Integer(row[3], 10)) }.map { |row| row.drop(1) }
        require_true(middle_rows.map { |row| row.drop(1) } == expected_middle &&
                     last_rows.map { |row| row.drop(1) } == expected_last,
                     "#{profile_id}/#{role} native full middle/last SQL projections differ from full rows")
      end
      {
        exact_profile_role_parts: @recursive_parts.size,
        full_rows: full.size,
        middle_rows: middle.size,
        last_rows: last.size,
        document_type: W241::STOCK_TYPE,
        middle_last_are_sql_predicates_only: true,
        pk6_nothing_null_omitted: true,
      }
    rescue KeyError, ArgumentError, TypeError => error
      raise Failure, "recursive full-Object oracle malformed: #{error.class}: #{error.message}"
    end

    def capture_persisted_tuple_oracle!
      store = File.join(@root, 'stores', 'tuple')
      tuple_table = "w242_#{Digest::SHA256.hexdigest(@root)[0, 8]}_tuple"
      deep_table = "w242_#{Digest::SHA256.hexdigest(@root)[0, 8]}_deep"
      settings = [
        'index_granularity=2', 'index_granularity_bytes=10485760', 'enable_mixed_granularity_parts=1',
        'min_rows_for_wide_part=0', 'min_bytes_for_wide_part=0', 'compress_marks=0', 'compress_primary_key=0',
        'min_compress_block_size=0', 'max_compress_block_size=4096', "default_compression_codec='LZ4'",
        "dynamic_serialization_version='v3'", "object_serialization_version='v3'",
        'propagate_types_serialization_versions_to_nested_types=true',
      ].join(', ')
      tuple_sql = []
      tuple_sql << "CREATE TABLE default.#{tuple_table} (pk UInt64, d #{DYNAMIC_COLUMN}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings};"
      tuple_sql << persisted_tuple_insert_sql(tuple_table)
      tuple_sql << "CREATE TABLE default.#{deep_table} (pk UInt64, d #{DYNAMIC_COLUMN}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings};"
      tuple_sql << persisted_deep_insert_sql(deep_table)
      [tuple_table, deep_table].each do |table|
        tuple_sql << "SELECT '__W242_CHECK_BEGIN__', '#{table}', '' FORMAT TSVRaw;"
        tuple_sql << "CHECK TABLE default.#{table} FORMAT TSV;"
        tuple_sql << "SELECT '__W242_CHECK_END__', '#{table}', '' FORMAT TSVRaw;"
        tuple_sql << "SELECT '__W242_SCHEMA__', '#{table}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;"
        tuple_sql << "SELECT '__W242_PART__', '#{table}', name, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;"
      end
      persisted = native_stage('tuple_json_array_dynamic_persist', store, tuple_sql.join("\n"))
      require_success!(persisted, 'Tuple(JSON, Array(Dynamic)) persistence/CHECK')
      validate_tuple_persist!(persisted.fetch(:stdout), tuple_table, deep_table)
      reopened = native_stage('tuple_json_array_dynamic_reopen', store,
                              [tuple_reopen_sql(tuple_table), deep_reopen_sql(deep_table)].join("\n"))
      require_success!(reopened, 'fresh-process Tuple(JSON, Array(Dynamic)) read')
      tuple_rows = tagged_rows(reopened.fetch(:stdout), TUPLE_TAG, 10)
      deep_rows = tagged_rows(reopened.fetch(:stdout), DEEP_TAG, 8)
      validate_tuple_rows!(tuple_rows)
      validate_deep_rows!(deep_rows)
      @tuple_oracle = {
        table: tuple_table, deep_table: deep_table,
        persisted_invocation: persisted.fetch(:record).fetch(:label),
        reopened_invocation: reopened.fetch(:record).fetch(:label),
        rows: tuple_rows, deep_site_rows: deep_rows,
        discriminator: 'pk=1 and pk=2 have identical JSON-normalized Dynamic tuple values but Array(Dynamic) arm types Int64 versus UInt8',
      }
      true
    end

    def persisted_tuple_insert_sql(table)
      first = "CAST(tuple('{\"outer\":7}'::JSON, CAST([CAST(toInt64(7), 'Dynamic'), CAST('seven', 'Dynamic')], 'Array(Dynamic)')), 'Dynamic')"
      second = "CAST(tuple('{\"outer\":7}'::JSON, CAST([CAST(toUInt8(7), 'Dynamic'), CAST('seven', 'Dynamic')], 'Array(Dynamic)')), 'Dynamic')"
      rows = [
        [1, first], [2, second],
        [3, "CAST(tuple('{\"outer\":3}'::JSON, CAST([], 'Array(Dynamic)')), 'Dynamic')"],
        [4, "CAST(NULL, 'Dynamic')"],
        [5, "CAST(tuple('{\"outer\":5}'::JSON, CAST([CAST('five', 'Dynamic')], 'Array(Dynamic)')), 'Dynamic')"],
        [6, "CAST(tuple('{\"outer\":6}'::JSON, CAST([], 'Array(Dynamic)')), 'Dynamic')"],
        [7, "CAST(NULL, 'Dynamic')"],
        [8, "CAST(tuple('{\"outer\":8}'::JSON, CAST([CAST(toInt64(8), 'Dynamic')], 'Array(Dynamic)')), 'Dynamic')"],
      ]
      "INSERT INTO default.#{table} SELECT #{rows[0][0]}, #{rows[0][1]}\n" +
        rows.drop(1).map { |pk, value| "UNION ALL SELECT #{pk}, #{value}" }.join("\n") + ';'
    end

    def persisted_deep_insert_sql(table)
      first = "CAST(tuple('{\"outer\":1}'::JSON, CAST([CAST('{\"inner\":2}'::JSON, 'Dynamic'), CAST('sibling', 'Dynamic')], 'Array(Dynamic)')), 'Dynamic')"
      second = "CAST(tuple('{\"outer\":2}'::JSON, CAST([], 'Array(Dynamic)')), 'Dynamic')"
      "INSERT INTO default.#{table} SELECT 1, #{first} UNION ALL SELECT 2, #{second};"
    end

    def tuple_reopen_sql(table)
      inner = "dynamicElement(d, #{sql_quote(TUPLE_TYPE)})"
      "SELECT '#{TUPLE_TAG}', toString(pk), if(isNull(d), 'NULL', dynamicType(d)), " \
        "if(isNull(d), 'NULL', toTypeName(#{inner})), " \
        "if(isNull(d), 'NULL', hex(toJSONString(arrayMap(x -> dynamicType(x), #{inner}.2)))), " \
        "if(isNull(d), 'NULL', hex(toJSONString(d))), " \
        "if(isNull(d), 'NULL', hex(toJSONString(#{inner}.1))), " \
        "if(isNull(d), 'NULL', hex(toJSONString(#{inner}.2))), " \
        "if(isNull(d), 'NULL', hex(toJSONString(JSONAllPathsWithTypes(#{inner}.1)))), " \
        "if(isNull(d), 'NULL', toString(length(#{inner}.2))) " \
        "FROM default.#{table} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;"
    end

    def deep_reopen_sql(table)
      inner = "dynamicElement(d, #{sql_quote(TUPLE_TYPE)}).2"
      first_child = "#{inner}[1]"
      "SELECT '#{DEEP_TAG}', toString(pk), if(isNull(d), 'NULL', dynamicType(d)), " \
        "if(isNull(d), '[]', hex(toJSONString(arrayMap(x -> dynamicType(x), #{inner})))), " \
        "if(length(#{inner})=0, 'EMPTY', dynamicType(#{first_child})), " \
        "if(length(#{inner})=0, 'EMPTY', toTypeName(#{first_child})), " \
        "if(length(#{inner})=0, 'NULL', hex(toJSONString(#{first_child}))), " \
        "if(length(#{inner})=0, 'NULL', hex(toJSONString(JSONAllPathsWithTypes(dynamicElement(#{first_child}, 'JSON'))))) " \
        "FROM default.#{table} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;"
    end

    def validate_tuple_persist!(stdout, tuple_table, deep_table)
      [tuple_table, deep_table].each do |table|
        checks = check_rows_between(stdout, table, nil)
        require_true(checks == ["all_1_1_0\t1\t"], "#{table} native CHECK output differs")
        schema = tagged_rows(stdout, '__W242_SCHEMA__', 4).select { |row| row[1] == table }
        require_true(schema.map { |row| row.drop(2) } == [['pk', 'UInt64'], ['d', DYNAMIC_COLUMN]],
                     "#{table} schema differs")
        parts = tagged_rows(stdout, '__W242_PART__', 6).select { |row| row[1] == table }
        require_true(parts.size == 1 && parts[0].values_at(2, 3, 4, 5) == ['all_1_1_0', 'Wide', table == tuple_table ? '8' : '2', table == tuple_table ? '5' : '2'],
                     "#{table} persisted Wide part row/mark counts differ")
      end
    end

    def validate_tuple_rows!(rows)
      require_true(rows.size == 8 && rows.map { |row| Integer(row[1], 10) } == (1..8).to_a,
                   'Tuple persistence reopen row domain differs')
      by_pk = rows.each_with_object({}) { |row, result| result[Integer(row[1], 10)] = row }
      expected_types = {
        1 => ['Int64', 'String'], 2 => ['UInt8', 'String'], 3 => [], 4 => nil,
        5 => ['String'], 6 => [], 7 => nil, 8 => ['Int64'],
      }
      expected_types.each do |pk, types|
        row = by_pk.fetch(pk)
        if types.nil?
          require_true(row[2..9].all? { |value| value == 'NULL' },
                       "Tuple NULL state differs at pk #{pk}")
        else
          require_true(row[2] == TUPLE_TYPE && row[3] == TUPLE_SELECTED_TYPE,
                       "Tuple actual descriptor differs at pk #{pk}")
          actual_types = JSON.parse([row[4]].pack('H*'))
          require_true(actual_types == types, "nested Dynamic arm type roster differs at pk #{pk}")
          document = JSON.parse([row[5]].pack('H*'))
          tuple_json = JSON.parse([row[6]].pack('H*'))
          array_json = JSON.parse([row[7]].pack('H*'))
          json_path_types = JSON.parse([row[8]].pack('H*'))
          require_true(document == [tuple_json, array_json], "Tuple logical value components disagree at pk #{pk}")
          require_true(json_path_types.is_a?(Hash) && json_path_types.keys == ['outer'],
                       "Tuple JSON component path roster differs at pk #{pk}")
          require_true(Integer(row[9], 10) == array_json.size, "Tuple Array(Dynamic) element count differs at pk #{pk}")
        end
      end
      first = by_pk.fetch(1)
      second = by_pk.fetch(2)
      require_true(first[5] == second[5] && JSON.parse([first[4]].pack('H*')) != JSON.parse([second[4]].pack('H*')),
                   'Int64/UInt8 tuple discriminator did not preserve equal value bytes with distinct actual types')
      require_true(first[8] == second[8], 'identical Tuple JSON components have different path type witnesses')
      true
    rescue JSON::ParserError, ArgumentError, KeyError => error
      raise Failure, "Tuple reopen oracle malformed: #{error.class}: #{error.message}"
    end

    def validate_deep_rows!(rows)
      require_true(rows.size == 2 && rows.map { |row| Integer(row[1], 10) } == [1, 2],
                   'deeper Dynamic-site row domain differs')
      first, second = rows
      require_true(first[2] == 'Tuple(JSON, Array(Dynamic))' &&
                   JSON.parse([first[3]].pack('H*')) == ['JSON', 'String'] && first[4] == 'JSON' &&
                   !first[5].empty?,
                   'nested JSON Dynamic actual type differs')
      json_value = JSON.parse([first[6]].pack('H*'))
      path_types = JSON.parse([first[7]].pack('H*'))
      require_true(json_value == {'inner' => 2} && path_types.is_a?(Hash) && path_types.keys == ['inner'],
                   'nested JSON actual value/type witnesses disagree')
      require_true(second[2] == 'Tuple(JSON, Array(Dynamic))' && JSON.parse([second[3]].pack('H*')) == [],
                   'deeper empty Array(Dynamic) witness differs')
      require_true(second[4..7] == ['EMPTY', 'EMPTY', 'NULL', 'NULL'],
                   'deeper empty-array child witnesses are not empty')
      true
    rescue JSON::ParserError, ArgumentError => error
      raise Failure, "deeper Dynamic-site oracle malformed: #{error.class}: #{error.message}"
    end

    def sql_quote(value)
      "'#{value.to_s.gsub(/[\\']/) { |character| "\\#{character}" }}'"
    end

    def require_success!(observation, label)
      return if observation.fetch(:classification) == 'success' && observation.fetch(:status)&.success?
      raise Failure, "#{label} native process classification=#{observation.fetch(:classification)} exit=#{observation.fetch(:record).fetch(:exit).inspect}"
    end

    def assert_unchanged_inputs!
      @part_snapshots.each do |key, snapshot|
        require_true(part_snapshot(snapshot.fetch(:source_path)) == snapshot.fetch(:before),
                     "W241 input part changed during W242 reads: #{key}")
      end
      @part_inputs.each do |part|
        require_true(part_snapshot(part.fetch(:attached_path)) == part.fetch(:attached_snapshot),
                     "attached W241 copy changed during W242 reads: #{part.fetch(:profile).fetch(:id)}/#{part.fetch(:role)}")
      end
      @recursive_parts.each do |part|
        label = "#{part.fetch(:profile_id)}/#{part.fetch(:role)}"
        require_true(part_snapshot(part.fetch(:path)) == part.fetch(:source_snapshot),
                     "recursive generated source part changed during W242 reads: #{label}")
        require_true(part_snapshot(part.fetch(:attached_path)) == part.fetch(:attached_snapshot),
                     "recursive attached part changed during W242 reads: #{label}")
      end
      true
    end

    def failure_status
      record = @invocations.last
      if record && record[:process_classification] == 'server_exception' && record[:exit] && !record[:timed_out] &&
         record[:signal].nil? && record[:spawn_error].nil? && record[:stdin_write_error].nil? &&
         record[:stdout_read_error].nil? && record[:stderr_read_error].nil?
        'native_server_exception_observed'
      else
        'capture_failure_inconclusive'
      end
    end

    def write_summary(status, fatal_error)
      summary = {
        format: FORMAT, status: status, fatal_error: fatal_error,
        runtime: {path: @binary, sha256: W241::BINARY_SHA256, version: W241::VERSION, build: W241::BUILD,
                  sha256_before: @binary_sha_before, sha256_after: @binary_sha_after},
        source_capture: {w241_root: @w241_root, w241_summary_sha256: @w241_summary_sha256,
                         expected_summary_sha256: @expected_w241_sha256},
        limits: {max_threads: 1, local_max_memory_usage_bytes: W241::MEMORY,
                 outer_run_safe_memory_limit_bytes: W241::OUTER_RUN_SAFE_LIMIT,
                 timeout_seconds: W241::TIMEOUT, termination_grace_seconds: W241::GRACE},
        profiles: @profiles, nested_type_oracle: @nested_query, tuple_oracle: @tuple_oracle,
        recursive_dynamic_oracle: @recursive_capture,
        part_input_snapshots: @part_snapshots, invocations: @invocations,
        last_stage: @last_stage, evidence_root: @root,
        interpretation: {
          'native type oracle' => 'Captured direct-only native queries report exact Array(JSON) element descriptors, JSONAllPathsWithTypes, and child toTypeName values for every populated W241 array element. They are distinct from logical value equality.',
          'tuple discriminator' => 'Rows 1 and 2 persist the same Tuple(JSON, Array(Dynamic)) logical value with Int64 versus UInt8 Dynamic arms; the exact type roster is checked after a fresh-process reopen.',
          'recursive generated parts' => 'Fresh Crystal-generated Tuple(JSON, Array(Dynamic)) shared Object parts are independently inventoried, attached and CHECKed, then read by direct-only and separate full-Object native processes. Nested Dynamic actual types are compared separately from JSON-normalized values; middle/last are SQL predicates, not physical mark-window proof.',
          'deeper site' => 'A separately labeled persisted Tuple(JSON, Array(Dynamic)) control puts a JSON actual inside an Array(Dynamic) child; this is a native grammar/persistence control, not Crystal writer support.',
          'failure policy' => 'A ClickHouse server exception is reported separately from runtime, timeout, spawn, signal, or I/O failures; neither status is treated as support proof.',
        },
      }
      path = File.join(@root, 'summary.json')
      return if File.exist?(path) || File.symlink?(path)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.pretty_generate(summary) + "\n") }
    end
  end
end

def main
  options = {}
  preflight_only = false
  retained_nested_only = false
  retained_tuple_only = false
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/probe_object_recursive_dynamic_w242.rb --clickhouse PATH --recursive-helper PATH --w241-root CAPTURE --w241-summary-sha256 SHA256 --evidence-root EMPTY_CHILD_OF_PRIVATE_TMP'
    parser.on('--preflight-w241-only') { preflight_only = true }
    parser.on('--calibrate-retained-nested-only') { retained_nested_only = true }
    parser.on('--calibrate-retained-tuple-only') { retained_tuple_only = true }
    parser.on('--clickhouse PATH') { |value| options[:binary] = value }
    parser.on('--recursive-helper PATH') { |value| options[:recursive_helper] = value }
    parser.on('--w241-root PATH') { |value| options[:w241_root] = value }
    parser.on('--w241-summary-sha256 SHA256') { |value| options[:w241_sha256] = value }
    parser.on('--w242-root CAPTURE') { |value| options[:w242_root] = value }
    parser.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
  end.parse!
  %i[binary w241_root w241_sha256].each do |key|
    raise "required option missing: --#{key.to_s.tr('_', '-')}" unless options[key]
  end
  if preflight_only
    result = ProbeObjectRecursiveDynamicW242::Probe.preflight_w241_capture!(
      options[:binary], options[:w241_root], options[:w241_sha256]
    )
    puts JSON.pretty_generate(result)
    exit 0
  end
  if retained_nested_only
    raise 'required option missing: --w242-root' unless options[:w242_root]
    result = ProbeObjectRecursiveDynamicW242::Probe.calibrate_retained_nested_capture!(
      options[:binary], options[:w241_root], options[:w241_sha256], options[:w242_root]
    )
    puts JSON.pretty_generate(result)
    exit 0
  end
  if retained_tuple_only
    raise 'required option missing: --w242-root' unless options[:w242_root]
    result = ProbeObjectRecursiveDynamicW242::Probe.calibrate_retained_tuple_capture!(
      options[:binary], options[:w241_root], options[:w241_sha256], options[:w242_root]
    )
    puts JSON.pretty_generate(result)
    exit 0
  end
  raise 'required option missing: --evidence-root' unless options[:evidence_root]
  raise 'required option missing: --recursive-helper' unless options[:recursive_helper]
  exit(ProbeObjectRecursiveDynamicW242::Probe.new(options[:binary], options[:evidence_root],
                                                  options[:w241_root], options[:w241_sha256],
                                                  options[:recursive_helper]).run ? 0 : 1)
end

main if $PROGRAM_NAME == __FILE__
