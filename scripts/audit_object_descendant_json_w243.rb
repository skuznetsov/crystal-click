#!/usr/bin/env ruby
# Read-only raw auditor for a completed W243 generated-part/native-reader
# capture. It independently authenticates process artifacts and part bytes,
# then replays the finite native TSV/type/value oracle. It never starts a
# server, writes a part, or treats helper self-report alone as evidence.

require 'digest'
require 'find'
require 'json'
require 'optparse'

module AuditObjectDescendantJSONW243
  FORMAT = 'object_descendant_json_w243_capture_v1'.freeze
  HELPER_INPUT_FORMAT = 'object_descendant_json_w243_input_v1'.freeze
  HELPER_OUTPUT_FORMAT = 'object_descendant_json_w243_helper_v1'.freeze
  CLICKHOUSE_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  CLICKHOUSE_VERSION = '26.10.1.1201'.freeze
  CLICKHOUSE_BUILD = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  MEMORY_BYTES = 512 * 1024 * 1024
  OUTER_MEMORY_BYTES = 12 * 1024 * 1024 * 1024
  TIMEOUT_SECONDS = 10
  GRACE_SECONDS = 2
  MAX_SUMMARY_BYTES = 32 * 1024 * 1024
  MAX_PROCESS_ARTIFACT_BYTES = 64 * 1024 * 1024
  MAX_HELPER_OUTPUT_BYTES = 32 * 1024 * 1024
  MAX_PART_FILE_BYTES = 16 * 1024 * 1024
  MAX_PART_TOTAL_BYTES = 64 * 1024 * 1024

  PROFILE_IDS = %w[
    map_s0 map_s1 map_with_buckets_s0 map_with_buckets_s1
    advanced_s0 advanced_s1 advanced_chunked_s0 advanced_chunked_s1
  ].freeze
  VERSIONS = {
    'map_s0' => 0, 'map_s1' => 0,
    'map_with_buckets_s0' => 1, 'map_with_buckets_s1' => 1,
    'advanced_s0' => 2, 'advanced_s1' => 2,
    'advanced_chunked_s0' => 3, 'advanced_chunked_s1' => 3,
  }.freeze
  STRING_PROFILES = {
    'map_s0' => 's0', 'map_s1' => 's1',
    'map_with_buckets_s0' => 's0', 'map_with_buckets_s1' => 's1',
    'advanced_s0' => 's0', 'advanced_s1' => 's1',
    'advanced_chunked_s0' => 's0', 'advanced_chunked_s1' => 's1',
  }.freeze
  BUCKET_COUNTS = {0 => 1, 1 => 2, 2 => 1, 3 => 2}.freeze
  ROLES = %w[normal type_only].freeze
  REAL_MARK_ROWS = [2, 2, 2, 2].freeze
  PHYSICAL_MARKS = 5
  SIPHASH_MASK = (1 << 64) - 1

  STOCK_TYPE = 'JSON(max_dynamic_paths=0)'.freeze
  OUTER_ACTUAL_TYPE = 'Tuple(JSON(max_dynamic_types=2, max_dynamic_paths=1, v UInt8), Array(Dynamic(max_types=1)))'.freeze
  PARENT_JSON_TYPE = 'JSON(max_dynamic_types=2, max_dynamic_paths=1, v UInt8)'.freeze
  PARENT_ITEMS_WRAPPER = 'Dynamic(max_types=2)'.freeze
  SELECTED_PATH_WRAPPER = 'Dynamic(max_types=254)'.freeze
  NATIVE_PATH_WRAPPER = 'Dynamic'.freeze
  LEAF_JSON_TYPES = {
    'normal' => 'JSON(max_dynamic_types=0, max_dynamic_paths=0, v UInt8)',
    'type_only' => 'JSON(max_dynamic_types=0, max_dynamic_paths=0, v Int64)',
  }.freeze
  ITEM_ARRAY_TYPES = LEAF_JSON_TYPES.each_with_object({}) do |(role, type), result|
    result[role] = "Array(#{type})"
  end.freeze
  LEAF_VALUE_TYPES = {'normal' => 'UInt8', 'type_only' => 'Int64'}.freeze

  DIRECT_TAG = '__W243_DIRECT__'.freeze
  NESTED_TAG = '__W243_NESTED__'.freeze
  CHILD_TAG = '__W243_CHILD__'.freeze
  FULL_TAG = '__W243_FULL__'.freeze
  PATH_TAG = '__W243_PATH__'.freeze
  CHECK_BEGIN_TAG = '__W243_CHECK_BEGIN__'.freeze
  CHECK_END_TAG = '__W243_CHECK_END__'.freeze
  SCHEMA_TAG = '__W243_SCHEMA__'.freeze
  PART_TAG = '__W243_PART__'.freeze
  PIN_ROW = ['__W241_PIN__', CLICKHOUSE_VERSION, CLICKHOUSE_BUILD].freeze

  EXPECTED_DOCS = [
    {'pk' => 1, 'doc' => {'payload' => [{'v' => 42, 'items' => [{'v' => 7}, {'v' => 8}]}, []]}},
    {'pk' => 2, 'doc' => {'payload' => [{'v' => 42, 'items' => []}, []]}},
    {'pk' => 3, 'doc' => {'payload' => [{'v' => 42}, []]}},
    {'pk' => 4, 'doc' => {}},
    {'pk' => 5, 'doc' => {'payload' => [{'v' => 42, 'items' => [{'v' => 7}]}, []]}},
    {'pk' => 6, 'doc' => {}},
    {'pk' => 7, 'doc' => {'payload' => [{'v' => 42, 'items' => []}, []]}},
    {'pk' => 8, 'doc' => {'payload' => [{'v' => 42, 'items' => [{'v' => 77}]}, []]}},
  ].freeze
  ITEMS_BY_PK = {
    1 => [{'v' => 7}, {'v' => 8}], 2 => [], 3 => nil, 4 => nil,
    5 => [{'v' => 7}], 6 => nil, 7 => [], 8 => [{'v' => 77}],
  }.freeze
  WINDOWS = [
    ['middle', 1, 2, [3, 4, 5, 6]],
    ['last', 3, 1, [7, 8]],
    ['empty_interior', 2, 0, []],
    ['zero_count_end', 4, 0, []],
  ].freeze

  RECORD_KEYS = %w[
    argv argv_file argv_sha256 binary_path binary_sha_after binary_sha_before exit expected_binary_sha256
    label max_memory_usage_applicable max_memory_usage_bytes max_threads process_classification process_kind
    required_outer_run_safe_memory_limit_bytes signal spawn_error stderr_bytes stderr_file stderr_read_error
    stderr_sha256 stdin_bytes stdin_file stdin_sha256 stdin_write_error store_path stdout_bytes stdout_file
    stdout_read_error stdout_sha256 termination_grace_seconds timed_out timeout_seconds
  ].freeze
  INVOCATION_LABELS = (['crystal_helper', 'native_create_tables', 'native_attach_check'] +
    PROFILE_IDS.map { |id| "native_direct_#{id}" } + PROFILE_IDS.map { |id| "native_full_#{id}" }).freeze
  SUMMARY_KEYS = %w[
    evidence_root fatal_error format frame_bytes helper interpretation invocations last_stage limits
    parts profiles runtime scope status
  ].freeze
  HELPER_TOP_KEYS = %w[format input_sha256 output_root requested_frame_bytes profile_ids profiles].freeze
  HELPER_PROFILE_KEYS = %w[
    id shared_version string_profile bucket_count outer_actual_type parent_json_type
    normal_item_array_type type_only_item_array_type normal_part type_only_part pair_comparison
  ].freeze
  HELPER_PART_KEYS = %w[
    role path schema_declaration columns_text count_text count shared_version bucket_count
    string_profile ordinary_string_profile mark_row_counts physical_stream_names physical_file_inventory
    full_rows direct_payload_rows nested_type_witnesses bounded_windows outer_actual_type
    parent_json_type item_array_type leaf_json_type nested_path
  ].freeze

  class Failure < StandardError; end

  # Evidence documents are closed protocol objects. JSON.parse's default Hash
  # silently keeps the last duplicate key, so all evidence and SQL JSON values
  # use this duplicate-rejecting object class.
  class UniqueKeyHash < Hash
    def []=(key, value)
      raise JSON::ParserError, "duplicate object key #{key.inspect}" if key?(key)
      super
    end
  end

  class Auditor
    def initialize(summary_path:, summary_sha256:, clickhouse:, helper_path:, helper_sha256:, helper_source_sha256:, self_test:)
      @summary_path = File.expand_path(summary_path)
      @root = File.dirname(@summary_path)
      @summary_sha256 = checked_sha(summary_sha256, 'summary')
      @clickhouse = canonical_executable(clickhouse, 'ClickHouse')
      @helper_path = canonical_executable(helper_path, 'W243 helper executable')
      @helper_sha256 = checked_sha(helper_sha256, 'helper executable')
      @helper_source_sha256 = checked_sha(helper_source_sha256, 'helper source')
      fail!('--self-test is required for a capture audit') unless self_test
      fail!('summary must be summary.json in a canonical direct child of /private/tmp') unless
        File.basename(@summary_path) == 'summary.json' && File.directory?(@root) && !File.symlink?(@root) &&
        File.realpath(@root) == @root && File.dirname(@root) == File.realpath('/private/tmp')
    end

    def run
      summary_bytes = read_bounded(@summary_path, MAX_SUMMARY_BYTES, 'summary.json')
      fail!('summary SHA-256 differs from supplied pin') unless Digest::SHA256.hexdigest(summary_bytes) == @summary_sha256
      @summary = parse_json!(summary_bytes, 'summary')
      authenticate_summary!
      authenticate_helper_source!
      authenticate_processes!
      authenticate_parts!
      replay_native_outputs!
      controls = self_test!
      {
        status: 'raw_capture_authenticated',
        summary_sha256: @summary_sha256,
        clickhouse_sha256: CLICKHOUSE_SHA256,
        helper_sha256: @helper_sha256,
        helper_source_sha256: @helper_source_sha256,
        frame_bytes: @summary.fetch('frame_bytes'),
        profile_count: PROFILE_IDS.size,
        generated_part_count: @parts.size,
        native_invocation_count: INVOCATION_LABELS.size - 1,
        direct_rows: @counts.fetch(:direct),
        nested_rows: @counts.fetch(:nested),
        child_rows: @counts.fetch(:children),
        full_rows: @counts.fetch(:full),
        controls: controls,
        interpretation: 'Only Crystal-generated W243 parts are covered: bytes were independently inventoried, copied, attached, CHECKed, and read by pinned native processes. No reciprocal stock-authored W243 part claim is made. Self-test mutations are in-memory validator controls only.',
      }
    end

    # This callable route is intentionally independent of a native capture.
    # It uses the same strict parsers and row validators as run.
    def self_test!
      controls = {}
      controls[:siphash_stream_name_vector] = siphash128('pk') == 'fcc8daf1be9ac27649fa2186ad926aea'
      duplicate = '{"format":"a","nested":{"x":1,"x":2}}'
      controls[:duplicate_key_rejected] = rejects? { parse_json!(duplicate, 'self-test duplicate') }

      valid_substreams = [
        'columns substreams version: 1',
        '2 columns:',
        '1 substreams for column `pk`:',
        "\tpk",
        '1 substreams for column `doc`:',
        "\tdoc",
      ].join("\n") + "\n"
      controls[:baseline_substreams_roster_accepted] =
        parse_substreams(valid_substreams) == {'pk' => ['pk'], 'doc' => ['doc']}
      duplicate_same_column = [
        'columns substreams version: 1',
        '2 columns:',
        '2 substreams for column `pk`:',
        "\tpk",
        "\tpk",
        '1 substreams for column `doc`:',
        "\tdoc",
      ].join("\n") + "\n"
      controls[:same_column_substream_duplicate_rejected] = rejects? do
        parse_substreams(duplicate_same_column)
      end
      duplicate_cross_column = [
        'columns substreams version: 1',
        '2 columns:',
        '1 substreams for column `pk`:',
        "\tshared",
        '1 substreams for column `doc`:',
        "\tshared",
      ].join("\n") + "\n"
      controls[:cross_column_substream_duplicate_rejected] = rejects? do
        parse_substreams(duplicate_cross_column)
      end

      valid_children = ROLES.flat_map { |role| synthetic_child_rows('map_s0', role) }
      controls[:baseline_child_types_accepted] = begin
        ROLES.each do |role|
          validate_child_rows!(valid_children.select { |row| row[2] == role }, 'map_s0', role)
        end
        true
      rescue Failure
        false
      end

      type_mutant = valid_children.map(&:dup)
      row = type_mutant.find { |item| item[2] == 'type_only' && item[3] == '1' && item[4] == '1' }
      paths = parse_hex_json(row[8], 'self-test child paths').each_with_object({}) do |(key, value), copy|
        copy[key] = value
      end
      paths['v'] = 'UInt8'
      row[8] = hex_json(paths)
      row[9] = 'UInt8'
      # The JSON value remains 7; only its witnessed native type changes.
      controls[:same_value_wrong_type_rejected] = rejects? do
        validate_child_rows!(type_mutant.select { |item| item[2] == 'type_only' }, 'map_s0', 'type_only')
      end

      duplicate_row = valid_children.select { |item| item[2] == 'normal' }.map(&:dup)
      duplicate_row << duplicate_row.first.dup
      controls[:duplicate_child_row_rejected] = rejects? do
        validate_child_rows!(duplicate_row, 'map_s0', 'normal')
      end

      missing_row = valid_children.select { |item| item[2] == 'normal' }.map(&:dup)
      missing_row.pop
      controls[:missing_child_row_rejected] = rejects? do
        validate_child_rows!(missing_row, 'map_s0', 'normal')
      end

      valid_witnesses = expected_nested_witnesses('normal')
      witness_mutant = deep_dup(valid_witnesses)
      witness_mutant[0]['nested_items'][0]['v_type'] = 'Int64'
      controls[:helper_type_witness_mutant_rejected] = rejects? do
        require_equal!(witness_mutant, valid_witnesses, 'self-test helper witness')
      end

      controls[:baseline_helper_witness_accepted] = valid_witnesses == expected_nested_witnesses('normal')
      fail!('one or more auditor self-tests were not discriminating') unless controls.values.all?
      controls
    end

    private

    def fail!(message)
      raise Failure, "W243 audit: #{message}"
    end

    def checked_sha(value, label)
      fail!("#{label} SHA-256 is malformed") unless value.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(value)
      value
    end

    def canonical_executable(path, label)
      fail!("#{label} path is required") unless path.is_a?(String) && !path.empty?
      expanded = File.expand_path(path)
      fail!("#{label} is absent, non-executable, or symlinked") unless
        File.file?(expanded) && File.executable?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded
      expanded
    end

    def read_bounded(path, limit, label)
      fail!("#{label} is absent, non-regular, or symlinked") unless File.file?(path) && !File.symlink?(path)
      size = File.size(path)
      fail!("#{label} exceeds its byte limit") unless size >= 0 && size <= limit
      bytes = File.binread(path)
      fail!("#{label} changed while read") unless bytes.bytesize == size
      bytes
    end

    def parse_json!(bytes, label)
      JSON.parse(bytes, object_class: UniqueKeyHash)
    rescue JSON::ParserError => error
      fail!("#{label} is invalid or has duplicate keys: #{error.message}")
    end

    def authenticate_summary!
      exact_keys!(@summary, SUMMARY_KEYS, 'summary')
      fail!('summary is not a completed, successful W243 native observation') unless
        @summary['format'] == FORMAT && @summary['status'] == 'library_written_native_read_observed' &&
        @summary['fatal_error'].nil? && @summary['last_stage'] == 'native_full_advanced_chunked_s1' &&
        @summary['scope'] == 'library_written_native_read_only; no stock-authored W243 part is covered' &&
        @summary['evidence_root'] == @root
      fail!('summary frame size is outside the closed 32/64 profiles') unless [32, 64].include?(@summary['frame_bytes'])
      runtime = @summary.fetch('runtime')
      exact_keys!(runtime, %w[path sha256 version build sha256_before sha256_after], 'runtime')
      fail!('runtime path/version/build/hash differs from the pinned native executable') unless
        runtime['path'] == @clickhouse && runtime['sha256'] == CLICKHOUSE_SHA256 &&
        runtime['sha256_before'] == CLICKHOUSE_SHA256 && runtime['sha256_after'] == CLICKHOUSE_SHA256 &&
        runtime['version'] == CLICKHOUSE_VERSION && runtime['build'] == CLICKHOUSE_BUILD &&
        Digest::SHA256.file(@clickhouse).hexdigest == CLICKHOUSE_SHA256
      limits = @summary.fetch('limits')
      exact_keys!(limits, %w[max_threads local_max_memory_usage_bytes outer_run_safe_memory_limit_bytes timeout_seconds termination_grace_seconds], 'limits')
      require_equal!(limits, {
        'max_threads' => 1, 'local_max_memory_usage_bytes' => MEMORY_BYTES,
        'outer_run_safe_memory_limit_bytes' => OUTER_MEMORY_BYTES,
        'timeout_seconds' => TIMEOUT_SECONDS, 'termination_grace_seconds' => GRACE_SECONDS,
      }, 'process limits')
      interpretation = @summary.fetch('interpretation')
      exact_keys!(interpretation, %w[generated_part_direction direct_native full_native physical_windows type_discriminator failure_policy], 'interpretation')
      fail!('summary overclaims the direction of W243 coverage') unless
        interpretation['generated_part_direction'] == 'All 16 parts are generated by the pinned Crystal helper, then independently inventoried, attached, CHECKed, and read by fresh pinned native processes. This does not claim reciprocal stock-authored W243 part coverage.'
      true
    rescue KeyError, TypeError => error
      fail!("summary shape is malformed: #{error.class}: #{error.message}")
    end

    def authenticate_helper_source!
      helper = @summary.fetch('helper')
      exact_keys!(helper, %w[path sha256_before sha256_after source_path source_sha256_expected source_sha256_before source_sha256_after input_sha256 output_sha256 invocation], 'helper summary')
      source_path = File.expand_path('check_object_descendant_json_w243.cr', __dir__)
      fail!('helper executable path or before/after pin differs') unless
        helper['path'] == @helper_path && helper['sha256_before'] == @helper_sha256 &&
        helper['sha256_after'] == @helper_sha256 && Digest::SHA256.file(@helper_path).hexdigest == @helper_sha256
      fail!('helper source path/SHA does not match the independently pinned source') unless
        helper['source_path'] == source_path && helper['source_sha256_expected'] == @helper_source_sha256 &&
        helper['source_sha256_before'] == @helper_source_sha256 && helper['source_sha256_after'] == @helper_source_sha256 &&
        Digest::SHA256.file(source_path).hexdigest == @helper_source_sha256
      true
    rescue KeyError, TypeError => error
      fail!("helper pin record is malformed: #{error.class}: #{error.message}")
    end

    def authenticate_parts!
      @parts = @summary.fetch('parts')
      fail!('summary part roster/order differs from eight profiles × two roles') unless
        @parts.is_a?(Array) && @parts.size == PROFILE_IDS.size * ROLES.size &&
        @parts.map { |part| [part.fetch('id'), part.fetch('role')] } == PROFILE_IDS.flat_map { |id| ROLES.map { |role| [id, role] } }
      @part_by_identity = {}
      @parts.each do |part|
        id = part.fetch('id')
        role = part.fetch('role')
        version = VERSIONS.fetch(id)
        string_profile = STRING_PROFILES.fetch(id)
        table = table_name(id, role)
        exact_keys!(part, %w[id role shared_version string_profile table path data_path attached_path part_metadata source_snapshot copied_snapshot attached_snapshot], "summary part #{id}/#{role}")
        fail!("#{id}/#{role} summary identity differs") unless
          part['shared_version'] == version && part['string_profile'] == string_profile && part['table'] == table
        source_path = File.join(@root, 'generated', "#{id}_#{role}")
        fail!("#{id}/#{role} generated source path differs") unless part['path'] == source_path
        canonical_directory!(source_path, File.join(@root, 'generated'), "#{id}/#{role} source part")
        source = part_snapshot(source_path)
        expected_snapshot = normalize_snapshot(part.fetch('source_snapshot'), "#{id}/#{role} source snapshot")
        require_equal!(source, expected_snapshot, "#{id}/#{role} source file snapshot")
        require_equal!(normalize_snapshot(part.fetch('copied_snapshot'), "#{id}/#{role} copied snapshot"), source,
                       "#{id}/#{role} detached copy snapshot")

        data_path = part.fetch('data_path')
        canonical_directory!(data_path, File.join(@root, 'stores', 'native'), "#{id}/#{role} native table directory")
        # ClickHouse stores table data under UUID-based `store/<prefix>/<uuid>`
        # paths, not a directory named after the table. The exact table-to-path
        # binding is checked against the captured native system.tables row in
        # validate_create_output!; this check here enforces containment only.
        attached_path = part.fetch('attached_path')
        expected_attached = File.join(data_path, 'all_1_1_0')
        fail!("#{id}/#{role} attached path differs") unless File.expand_path(attached_path) == expected_attached
        canonical_directory!(attached_path, data_path, "#{id}/#{role} attached part")
        attached = part_snapshot(attached_path)
        require_equal!(normalize_snapshot(part.fetch('attached_snapshot'), "#{id}/#{role} attached snapshot"), attached,
                       "#{id}/#{role} attached file snapshot")
        verify_attach_copy!(source, attached_path, attached, id, role)

        @part_by_identity[[id, role]] = part
      end

      helper_stdout = read_bounded(File.join(@root, 'invocations', 'crystal_helper.stdout'), MAX_HELPER_OUTPUT_BYTES, 'helper stdout')
      helper_data = parse_single_json_line!(helper_stdout, 'helper stdout')
      helper_record = @summary.fetch('helper')
      fail!('helper stdout SHA differs from summary') unless Digest::SHA256.hexdigest(helper_stdout) == helper_record['output_sha256']
      helper_input_path = File.join(@root, 'invocations', 'helper_input.json')
      input_bytes = read_bounded(helper_input_path, 1024 * 1024, 'helper input')
      input = parse_json!(input_bytes, 'helper input')
      expected_input = {
        'format' => HELPER_INPUT_FORMAT,
        'frame_bytes' => @summary.fetch('frame_bytes'),
        'profiles' => PROFILE_IDS.map do |id|
          {'id' => id, 'shared_version' => VERSIONS.fetch(id), 'string_profile' => STRING_PROFILES.fetch(id)}
        end,
      }
      require_equal!(input, expected_input, 'helper input profile request')
      require_equal!(Digest::SHA256.hexdigest(input_bytes), helper_record['input_sha256'], 'helper input SHA')
      validate_helper_output!(helper_data, input_bytes)
      @helper_data = helper_data
      true
    rescue KeyError, TypeError => error
      fail!("part/source authentication failed: #{error.class}: #{error.message}")
    end

    def validate_helper_output!(data, input_bytes)
      exact_keys!(data, HELPER_TOP_KEYS, 'helper output')
      require_equal!(data['format'], HELPER_OUTPUT_FORMAT, 'helper output format')
      require_equal!(data['input_sha256'], Digest::SHA256.hexdigest(input_bytes), 'helper output input binding')
      require_equal!(data['output_root'], File.join(@root, 'generated'), 'helper output root')
      require_equal!(data['requested_frame_bytes'], @summary.fetch('frame_bytes'), 'helper requested frame size')
      require_equal!(data['profile_ids'], PROFILE_IDS, 'helper profile roster')
      profiles = data.fetch('profiles')
      fail!('helper profile records are not the exact ordered eight') unless profiles.is_a?(Array) && profiles.size == PROFILE_IDS.size
      profiles.each_with_index do |profile, index|
        id = PROFILE_IDS.fetch(index)
        version = VERSIONS.fetch(id)
        string = STRING_PROFILES.fetch(id)
        exact_keys!(profile, HELPER_PROFILE_KEYS, "helper profile #{id}")
        require_equal!(profile['id'], id, "helper profile #{id} identity")
        require_equal!(profile['shared_version'], version, "helper profile #{id} version")
        require_equal!(profile['string_profile'], string, "helper profile #{id} String profile")
        require_equal!(profile['bucket_count'], BUCKET_COUNTS.fetch(version), "helper profile #{id} bucket count")
        require_equal!(profile['outer_actual_type'], OUTER_ACTUAL_TYPE, "helper profile #{id} outer actual descriptor")
        require_equal!(profile['parent_json_type'], PARENT_JSON_TYPE, "helper profile #{id} parent JSON descriptor")
        require_equal!(profile['normal_item_array_type'], ITEM_ARRAY_TYPES.fetch('normal'), "helper profile #{id} normal nested descriptor")
        require_equal!(profile['type_only_item_array_type'], ITEM_ARRAY_TYPES.fetch('type_only'), "helper profile #{id} type-only nested descriptor")
        ROLES.each { |role| validate_helper_part!(profile.fetch("#{role == 'normal' ? 'normal' : 'type_only'}_part"), id, role, version, string) }
        validate_helper_pair!(profile.fetch('pair_comparison'), id)
      end
      true
    rescue KeyError, TypeError => error
      fail!("helper output envelope is malformed: #{error.class}: #{error.message}")
    end

    def validate_helper_part!(part, id, role, version, string_profile)
      exact_keys!(part, HELPER_PART_KEYS, "helper part #{id}/#{role}")
      part_path = File.join(@root, 'generated', "#{id}_#{role}")
      require_equal!(part['role'], role, "helper part #{id}/#{role} role")
      require_equal!(part['path'], part_path, "helper part #{id}/#{role} path")
      require_equal!(part['schema_declaration'], STOCK_TYPE, "helper part #{id}/#{role} schema declaration")
      expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`doc` #{STOCK_TYPE}\n"
      require_equal!(part['columns_text'], expected_columns, "helper part #{id}/#{role} columns witness")
      require_equal!(part['count_text'].to_s.strip, '8', "helper part #{id}/#{role} count text")
      require_equal!(part['count'], 8, "helper part #{id}/#{role} count")
      require_equal!(part['shared_version'], version, "helper part #{id}/#{role} shared version")
      require_equal!(part['bucket_count'], BUCKET_COUNTS.fetch(version), "helper part #{id}/#{role} bucket count")
      require_equal!(part['string_profile'], string_profile, "helper part #{id}/#{role} String profile")
      require_equal!(part['ordinary_string_profile'], string_profile == 's0' ? 0 : 1, "helper part #{id}/#{role} ordinary String serialization")
      require_equal!(part['mark_row_counts'], REAL_MARK_ROWS, "helper part #{id}/#{role} real mark counts")
      require_equal!(part['outer_actual_type'], OUTER_ACTUAL_TYPE, "helper part #{id}/#{role} outer descriptor")
      require_equal!(part['parent_json_type'], PARENT_JSON_TYPE, "helper part #{id}/#{role} parent descriptor")
      require_equal!(part['item_array_type'], ITEM_ARRAY_TYPES.fetch(role), "helper part #{id}/#{role} Array(JSON) descriptor")
      require_equal!(part['leaf_json_type'], LEAF_JSON_TYPES.fetch(role), "helper part #{id}/#{role} leaf JSON descriptor")
      require_equal!(part['nested_path'], 'payload.1.items[]', "helper part #{id}/#{role} nested site")

      actual = part_snapshot(part_path)
      expected_from_helper = inventory_snapshot(part.fetch('physical_file_inventory'), "helper inventory #{id}/#{role}")
      require_equal!(actual, expected_from_helper, "helper physical inventory #{id}/#{role}")
      summary_part = @part_by_identity.fetch([id, role])
      require_equal!(actual, normalize_snapshot(summary_part.fetch('source_snapshot'), "summary inventory #{id}/#{role}"),
                     "summary/helper actual files #{id}/#{role}")
      validate_plain_part!(part_path, part, id, role, version, string_profile)

      require_equal!(part['full_rows'], EXPECTED_DOCS, "helper full rows #{id}/#{role}")
      require_equal!(part['direct_payload_rows'], expected_direct_rows, "helper selected payload rows #{id}/#{role}")
      require_equal!(part['nested_type_witnesses'], expected_nested_witnesses(role), "helper nested type/value witnesses #{id}/#{role}")
      require_equal!(part['bounded_windows'], expected_windows(role), "helper bounded mark-window witnesses #{id}/#{role}")
      true
    rescue KeyError, TypeError => error
      fail!("helper part #{id}/#{role} is malformed: #{error.class}: #{error.message}")
    end

    def validate_plain_part!(path, part, id, role, version, string_profile)
      names = Dir.children(path).sort
      %w[checksums.txt columns.txt columns_substreams.txt count.txt default_compression_codec.txt metadata_version.txt primary.idx serialization.json].each do |name|
        fail!("#{id}/#{role} required part metadata #{name} is missing") unless names.include?(name)
      end
      require_equal!(read_bounded(File.join(path, 'columns.txt'), 4096, "#{id}/#{role} columns.txt").force_encoding('UTF-8'), part['columns_text'], "#{id}/#{role} physical columns")
      require_equal!(read_bounded(File.join(path, 'count.txt'), 1024, "#{id}/#{role} count.txt").force_encoding('UTF-8').strip, '8', "#{id}/#{role} physical count")
      require_equal!(read_bounded(File.join(path, 'default_compression_codec.txt'), 1024, "#{id}/#{role} codec").force_encoding('UTF-8').strip, 'CODEC(LZ4)', "#{id}/#{role} codec")
      require_equal!(read_bounded(File.join(path, 'metadata_version.txt'), 1024, "#{id}/#{role} metadata version").force_encoding('UTF-8').strip, '0', "#{id}/#{role} metadata version")
      substreams = parse_substreams(read_bounded(File.join(path, 'columns_substreams.txt'), 256 * 1024, "#{id}/#{role} columns_substreams"))
      streams = part.fetch('physical_stream_names')
      fail!("#{id}/#{role} physical doc stream roster is malformed") unless streams.is_a?(Array) && streams.uniq == streams.sort
      require_equal!(substreams.fetch('pk'), ['pk'], "#{id}/#{role} pk stream roster")
      require_equal!(substreams.fetch('doc').sort, streams, "#{id}/#{role} doc stream roster")
      # Checksums v4 has a binary record payload. The helper/source inventory
      # authenticates these exact bytes; native CHECK validates record meaning.
      checksums = read_bounded(File.join(path, 'checksums.txt'), 1024 * 1024, "#{id}/#{role} checksums").b
      checksum_header = "checksums format version: 4\n".b
      fail!("#{id}/#{role} checksums format header differs") unless checksums.start_with?(checksum_header) && checksums.bytesize > checksum_header.bytesize
      stream_files = substreams.values.flatten.flat_map { |name| stream_file_names(name) }
      non_stream = %w[checksums.txt columns.txt columns_substreams.txt count.txt default_compression_codec.txt metadata_version.txt primary.idx serialization.json]
      non_stream << 'txn_version.txt' if names.include?('txn_version.txt')
      expected_names = (non_stream + stream_files).uniq.sort
      require_equal!(names.sort, expected_names, "#{id}/#{role} complete physical role roster")
      serialization_bytes = read_bounded(File.join(path, 'serialization.json'), 1024 * 1024, "#{id}/#{role} serialization.json")
      serialization = parse_json!(serialization_bytes, "#{id}/#{role} serialization.json")
      require_equal!(serialization.fetch('version'), 1, "#{id}/#{role} serialization version")
      require_equal!(serialization.fetch('types_serialization_versions').fetch('string'), string_profile == 's0' ? 0 : 1,
                     "#{id}/#{role} actual ordinary String version")
      metadata = @part_by_identity.fetch([id, role]).fetch('part_metadata')
      require_equal!(metadata.fetch('doc_streams'), streams, "#{id}/#{role} summary doc streams")
      require_equal!(metadata.fetch('table_streams'), ['pk'] + substreams.fetch('doc').sort, "#{id}/#{role} table streams")
      require_equal!(metadata.fetch('serialization_json_sha256'), Digest::SHA256.hexdigest(serialization_bytes), "#{id}/#{role} serialization hash")
      fail!("#{id}/#{role} physical version/bucket request differs") unless version == VERSIONS.fetch(id) && BUCKET_COUNTS.fetch(version) == part['bucket_count']
      true
    end

    def parse_substreams(bytes)
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      fail!('columns_substreams is not valid UTF-8') unless text.valid_encoding?
      lines = text.split("\n", -1)
      fail!('columns_substreams lacks one final newline') unless lines.pop == ''
      fail!('columns_substreams header differs') unless lines.shift == 'columns substreams version: 1' && lines.shift == '2 columns:'
      result = {}
      while !lines.empty?
        header = lines.shift
        match = /\A(\d+) substreams for column `([^`]+)`:\z/.match(header)
        fail!('columns_substreams section header malformed') unless match
        count = Integer(match[1], 10)
        name = match[2]
        fail!('columns_substreams unknown or duplicate column') unless %w[pk doc].include?(name) && !result.key?(name) && count.positive? && count <= 128 && lines.size >= count
        streams = []
        count.times do
          line = lines.shift
          fail!('columns_substreams stream line malformed') unless line.start_with?("\t") && line.bytesize > 1
          stream = line[1..-1].sub(/\A\*\s*/, '')
          fail!('columns_substreams stream is unsafe or duplicate') unless /\A[A-Za-z0-9_.%]+\z/.match?(stream) && !streams_seen?(result, streams, stream)
          streams << stream
        end
        result[name] = streams
      end
      fail!('columns_substreams roles differ') unless result.keys.sort == %w[doc pk]
      result
    rescue ArgumentError, TypeError, NoMethodError
      fail!('columns_substreams is malformed')
    end

    def streams_seen?(result, local, stream)
      result.values.any? { |streams| streams.include?(stream) } || local.include?(stream)
    end

    def stream_file_names(logical_name)
      stem = siphash128(logical_name)
      ["#{stem}.bin", "#{stem}.mrk2"]
    end

    def siphash_round(v0, v1, v2, v3)
      a = (v0 + v1) & SIPHASH_MASK
      b = rotate_left(v1, 13) ^ a
      a = rotate_left(a, 32)
      c = (v2 + v3) & SIPHASH_MASK
      d = rotate_left(v3, 16) ^ c
      a = (a + d) & SIPHASH_MASK
      d = rotate_left(d, 21) ^ a
      c = (c + b) & SIPHASH_MASK
      b = rotate_left(b, 17) ^ c
      c = rotate_left(c, 32)
      [a, b, c, d]
    end

    def rotate_left(value, amount)
      ((value << amount) | (value >> (64 - amount))) & SIPHASH_MASK
    end

    # ClickHouse stream filenames are SipHash-128(logical name). Reconstruct
    # this exact role mapping rather than accepting a roster from helper output.
    def siphash128(logical_name)
      bytes = logical_name.to_s.b
      state = [0x736f6d6570736575, 0x646f72616e646f6d, 0x6c7967656e657261, 0x7465646279746573]
      offset = 0
      while offset + 8 <= bytes.bytesize
        word = bytes.byteslice(offset, 8).unpack1('Q<')
        state[3] ^= word
        2.times { state = siphash_round(*state) }
        state[0] ^= word
        offset += 8
      end
      word = (bytes.bytesize & 0xff) << 56
      bytes.byteslice(offset..).to_s.bytes.each_with_index { |byte, index| word |= byte << (index * 8) }
      state[3] ^= word
      2.times { state = siphash_round(*state) }
      state[0] ^= word
      state[2] ^= 0xff
      4.times { state = siphash_round(*state) }
      [state[2] ^ state[3], state[0] ^ state[1]].map do |value|
        (value & SIPHASH_MASK).to_s(16).rjust(16, '0')
      end.join
    end

    def validate_helper_pair!(pair, id)
      exact_keys!(pair, %w[
        full_rows_equal direct_payload_rows_equal nested_json_values_equal
        normal_nested_values type_only_nested_values normal_nested_types type_only_nested_types
      ], "helper pair #{id}")
      %w[full_rows_equal direct_payload_rows_equal nested_json_values_equal].each do |key|
        require_equal!(pair[key], true, "helper pair #{id} #{key}")
      end
      normal_values = expected_nested_value_projection
      normal_types = expected_nested_type_projection('normal')
      type_types = expected_nested_type_projection('type_only')
      require_equal!(pair['normal_nested_values'], normal_values, "helper pair #{id} normal values")
      require_equal!(pair['type_only_nested_values'], normal_values, "helper pair #{id} type-only values")
      require_equal!(pair['normal_nested_types'], normal_types, "helper pair #{id} normal exact types")
      require_equal!(pair['type_only_nested_types'], type_types, "helper pair #{id} type-only exact types")
      true
    end

    def authenticate_processes!
      dir = File.join(@root, 'invocations')
      canonical_directory!(dir, @root, 'invocations directory')
      records = @summary.fetch('invocations')
      fail!('process invocation order/roster differs') unless records.is_a?(Array) && records.map { |entry| entry.fetch('label') } == INVOCATION_LABELS
      @records = records.each_with_object({}) { |record, map| map[record.fetch('label')] = record }
      fail!('duplicate process labels') unless @records.size == INVOCATION_LABELS.size
      expected_sql = expected_sql_by_label
      records.each do |record|
        label = record.fetch('label')
        exact_keys!(record, RECORD_KEYS, "process record #{label}")
        validate_process_record!(record, label, expected_sql.fetch(label))
      end
      helper_record = @summary.fetch('helper').fetch('invocation')
      require_equal!(helper_record, @records.fetch('crystal_helper'), 'helper process-record join')
      profiles = @summary.fetch('profiles')
      fail!('summary profile order/roster differs') unless profiles.is_a?(Array) && profiles.size == PROFILE_IDS.size &&
        profiles.map { |entry| entry.fetch('id') } == PROFILE_IDS
      PROFILE_IDS.each_with_index do |id, index|
        profile = profiles.fetch(index)
        exact_keys!(profile, %w[id shared_version string_profile bucket_count status native_direct native_full], "summary profile #{id}")
        require_equal!(profile.values_at('shared_version', 'string_profile', 'bucket_count', 'status'),
                       [VERSIONS.fetch(id), STRING_PROFILES.fetch(id), BUCKET_COUNTS.fetch(VERSIONS.fetch(id)), 'helper_part_observed'],
                       "summary profile #{id} identity/status")
        expected_sections = {
          'native_direct' => [{
            'path_rows' => 16, 'nested_type_rows' => 12, 'child_rows' => 8,
            'direct_sql_has_no_full_doc_expression' => true,
            'nested_type_witness_is_native_dynamic_type_and_json_path_roster' => true,
          }, "native_direct_#{id}"],
          'native_full' => [{
            'rows' => 16, 'document_type' => STOCK_TYPE,
            'full_query_contains_no_direct_descendant_projection' => true,
          }, "native_full_#{id}"],
        }
        expected_sections.each do |kind, (observations, label)|
          section = profile.fetch(kind)
          exact_keys!(section, %w[invocation observations], "summary profile #{id} #{kind}")
          require_equal!(section.fetch('invocation'), @records.fetch(label), "summary profile #{id} #{kind} process-record join")
          require_equal!(section.fetch('observations'), observations, "summary profile #{id} #{kind} observation contract")
        end
      end
      true
    rescue KeyError, TypeError => error
      fail!("invocation records malformed: #{error.class}: #{error.message}")
    end

    def validate_process_record!(record, label, expected_sql)
      fail!("#{label} was not a clean successful process") unless
        record['process_classification'] == 'success' && record['exit'] == 0 && record['signal'].nil? &&
        record['timed_out'] == false && %w[spawn_error stdin_write_error stdout_read_error stderr_read_error].all? { |field| record[field].nil? } &&
        record['stderr_bytes'] == 0 && record['stderr_sha256'] == Digest::SHA256.hexdigest('')
      %w[argv_file stdin_file stdout_file stderr_file].each do |field|
        value = record.fetch(field)
        fail!("#{label} #{field} is not a safe basename") unless value.is_a?(String) && File.basename(value) == value && /\A[A-Za-z0-9_.-]+\z/.match?(value)
      end
      fail!("#{label} file stems differ") unless record['argv_file'] == "#{label}.argv.json" &&
        record['stdin_file'] == "#{label}.#{label == 'crystal_helper' ? 'stdin.bin' : 'stdin.sql'}" &&
        record['stdout_file'] == "#{label}.stdout" && record['stderr_file'] == "#{label}.stderr"
      bytes = {}
      {
        'argv_file' => ['argv_sha256', nil],
        'stdin_file' => ['stdin_sha256', 'stdin_bytes'],
        'stdout_file' => ['stdout_sha256', 'stdout_bytes'],
        'stderr_file' => ['stderr_sha256', 'stderr_bytes'],
      }.each do |file_field, (sha_field, size_field)|
        artifact = read_bounded(File.join(@root, 'invocations', record.fetch(file_field)), MAX_PROCESS_ARTIFACT_BYTES, "#{label} #{file_field}")
        require_equal!(Digest::SHA256.hexdigest(artifact), record.fetch(sha_field), "#{label} #{file_field} digest")
        require_equal!(artifact.bytesize, record.fetch(size_field), "#{label} #{file_field} bytes") if size_field
        bytes[file_field] = artifact
      end
      record_path = File.join(@root, 'invocations', "#{label}.json")
      record_artifact = parse_json!(read_bounded(record_path, MAX_PROCESS_ARTIFACT_BYTES, "#{label} record artifact"), "#{label} record artifact")
      require_equal!(record_artifact, record, "#{label} record artifact join")
      argv = parse_json!(bytes.fetch('argv_file'), "#{label} argv")
      require_equal!(bytes.fetch('argv_file'), JSON.pretty_generate(argv) + "\n", "#{label} canonical argv bytes")
      require_equal!(argv, record['argv'], "#{label} argv record")
      fail!("#{label} stderr artifact is not empty") unless bytes.fetch('stderr_file').empty?
      fail!("#{label} argv is not a String array") unless argv.is_a?(Array) && argv.all? { |arg| arg.is_a?(String) }
      fail!("#{label} stdin differs from reconstructed SQL") unless bytes.fetch('stdin_file') == expected_sql.b
      fail!("#{label} SQL is invalid UTF-8") unless bytes.fetch('stdin_file').dup.force_encoding(Encoding::UTF_8).valid_encoding?

      if label == 'crystal_helper'
        expected_argv = [@helper_path, File.join(@root, 'invocations', 'helper_input.json'), File.join(@root, 'generated')]
        require_equal!(argv, expected_argv, 'helper argv')
        require_equal!(record['process_kind'], 'crystal-helper', 'helper process kind')
        require_equal!(record['store_path'], nil, 'helper store path')
        require_equal!(record['binary_path'], @helper_path, 'helper executable path')
        require_equal!(record['expected_binary_sha256'], @helper_sha256, 'helper executable pin')
        require_equal!(record['binary_sha_before'], @helper_sha256, 'helper before hash')
        require_equal!(record['binary_sha_after'], @helper_sha256, 'helper after hash')
        require_equal!(Digest::SHA256.file(@helper_path).hexdigest, @helper_sha256, 'helper executable current hash')
        require_equal!(record['max_threads'], nil, 'helper thread bound')
        require_equal!(record['max_memory_usage_bytes'], nil, 'helper local memory field')
        require_equal!(record['max_memory_usage_applicable'], false, 'helper memory applicability')
      else
        validate_native_record!(record, argv, label)
        require_equal!(tagged_rows(bytes.fetch('stdout_file'), '__W241_PIN__', 3), [PIN_ROW], "#{label} runtime pin output")
      end
      true
    rescue KeyError, TypeError => error
      fail!("#{label} process artifact validation failed: #{error.class}: #{error.message}")
    end

    def validate_native_record!(record, argv, label)
      store = File.join(@root, 'stores', 'native')
      expected_argv = [@clickhouse, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
                       "--max_memory_usage=#{MEMORY_BYTES}", '--multiquery']
      require_equal!(argv, expected_argv, "#{label} native argv")
      require_equal!(record['process_kind'], 'clickhouse-local', "#{label} process kind")
      require_equal!(record['store_path'], store, "#{label} store path")
      require_equal!(record['binary_path'], @clickhouse, "#{label} binary path")
      require_equal!(record['expected_binary_sha256'], CLICKHOUSE_SHA256, "#{label} expected binary pin")
      require_equal!(record['binary_sha_before'], CLICKHOUSE_SHA256, "#{label} binary before hash")
      require_equal!(record['binary_sha_after'], CLICKHOUSE_SHA256, "#{label} binary after hash")
      require_equal!(record['max_threads'], 1, "#{label} thread limit")
      require_equal!(record['max_memory_usage_bytes'], MEMORY_BYTES, "#{label} memory limit")
      require_equal!(record['max_memory_usage_applicable'], true, "#{label} memory applicable")
      true
    end

    def replay_native_outputs!
      create = @records.fetch('native_create_tables')
      attach = @records.fetch('native_attach_check')
      validate_create_output!(stdout_for(create))
      validate_attach_output!(stdout_for(attach))
      @counts = {direct: 0, nested: 0, children: 0, full: 0}
      PROFILE_IDS.each do |id|
        direct_record = @records.fetch("native_direct_#{id}")
        full_record = @records.fetch("native_full_#{id}")
        validate_direct_output!(stdout_for(direct_record), id)
        validate_full_output!(stdout_for(full_record), id)
      end
      true
    end

    def stdout_for(record)
      read_bounded(File.join(@root, 'invocations', record.fetch('stdout_file')), MAX_PROCESS_ARTIFACT_BYTES, "#{record.fetch('label')} stdout")
    end

    def validate_create_output!(stdout)
      rows = tagged_rows(stdout, PATH_TAG, 4)
      expected_tables = PROFILE_IDS.flat_map { |id| ROLES.map { |role| table_name(id, role) } }.sort
      require_equal!(rows.map { |row| row[2] }.sort, expected_tables, 'native system.tables path roster')
      fail!('duplicate native table path row') unless rows.map { |row| row[2] }.uniq.size == rows.size
      rows.each do |row|
        table = row[2]
        part = @parts.find { |entry| entry.fetch('table') == table }
        fail!("native path row names unknown table #{table}") unless part
        require_equal!(row[1], 'default', "#{table} database")
        require_equal!(canonical_existing_path(row[3], File.join(@root, 'stores', 'native'), "#{table} native data path"),
                       canonical_existing_path(part.fetch('data_path'), File.join(@root, 'stores', 'native'), "#{table} summary data path"),
                       "#{table} native table data path")
      end
      true
    end

    def validate_attach_output!(stdout)
      intervals = parse_check_intervals(stdout)
      require_equal!(intervals.keys.sort, PROFILE_IDS.flat_map { |id| ROLES.map { |role| [id, role] } }.sort,
                     'native CHECK identity roster')
      intervals.each do |(id, role), rows|
        require_equal!(rows, ["all_1_1_0\t1\t"], "#{id}/#{role} native CHECK result")
      end
      schemas = tagged_rows(stdout, SCHEMA_TAG, 5)
      parts = tagged_rows(stdout, PART_TAG, 9)
      require_equal!(schemas.size, 16 * 2, 'attached native schema row count')
      require_equal!(parts.size, 16, 'attached native part row count')
      @parts.each do |part|
        id, role, table = part.values_at('id', 'role', 'table')
        schema_rows = schemas.select { |row| row[1] == id && row[2] == role }
        require_equal!(schema_rows.map { |row| row.drop(3) }, [['pk', 'UInt64'], ['doc', STOCK_TYPE]], "#{id}/#{role} native ATTACH schema")
        part_rows = parts.select { |row| row[1] == id && row[2] == role }
        require_equal!(part_rows.size, 1, "#{id}/#{role} active part count")
        row = part_rows.first
        require_equal!(row.values_at(3, 4, 6, 7, 8), [table, 'all_1_1_0', 'Wide', '8', PHYSICAL_MARKS.to_s], "#{id}/#{role} native part identity/counts")
        require_equal!(canonical_existing_path(row[5], File.join(@root, 'stores', 'native'), "#{id}/#{role} native attached path"),
                       canonical_existing_path(part.fetch('attached_path'), File.join(@root, 'stores', 'native'), "#{id}/#{role} summary attached path"),
                       "#{id}/#{role} attached path")
      end
      true
    end

    def parse_check_intervals(stdout)
      active = nil
      result = {}
      stdout_lines(stdout).each do |line|
        if line.start_with?(CHECK_BEGIN_TAG + "\t")
          fields = line.split("\t", -1)
          fail!('malformed CHECK begin marker') unless fields.size == 3 && PROFILE_IDS.include?(fields[1]) && ROLES.include?(fields[2])
          key = [fields[1], fields[2]]
          fail!('duplicate/nested CHECK interval') if active || result.key?(key)
          active = [key, []]
        elsif line.start_with?(CHECK_END_TAG + "\t")
          fields = line.split("\t", -1)
          fail!('malformed CHECK end marker') unless fields.size == 3 && active && active[0] == fields.drop(1)
          result[active[0]] = active[1]
          active = nil
        elsif active
          active[1] << line
        end
      end
      fail!('unterminated CHECK interval') if active
      result
    end

    def validate_direct_output!(stdout, id)
      direct = tagged_rows(stdout, DIRECT_TAG, 7)
      nested = tagged_rows(stdout, NESTED_TAG, 14)
      children = tagged_rows(stdout, CHILD_TAG, 12)
      require_equal!(direct.size, 16, "#{id} direct row count")
      require_equal!(nested.size, 12, "#{id} nested type row count")
      require_equal!(children.size, 8, "#{id} child row count")
      ROLES.each do |role|
        direct_rows = direct.select { |row| row[1] == id && row[2] == role }
        nested_rows = nested.select { |row| row[1] == id && row[2] == role }
        child_rows = children.select { |row| row[1] == id && row[2] == role }
        require_equal!(direct_rows.map { |row| Integer(row[3], 10) }, (1..8).to_a, "#{id}/#{role} direct key domain")
        require_equal!(nested_rows.map { |row| Integer(row[3], 10) }, [1, 2, 3, 5, 7, 8], "#{id}/#{role} nested key domain")
        validate_direct_rows!(direct_rows, id, role)
        validate_nested_rows!(nested_rows, id, role)
        validate_child_rows!(child_rows, id, role)
      end
      @counts[:direct] += direct.size
      @counts[:nested] += nested.size
      @counts[:children] += children.size
      true
    rescue ArgumentError, KeyError, TypeError => error
      fail!("#{id} direct output malformed: #{error.class}: #{error.message}")
    end

    def validate_direct_rows!(rows, id, role)
      rows.each do |row|
        pk = Integer(row.fetch(3), 10)
        payload = EXPECTED_DOCS.fetch(pk - 1).fetch('doc').fetch('payload', nil)
        actual = row[6] == '6e756c6c' ? nil : parse_hex_json(row[6], "#{id}/#{role}/pk#{pk} payload")
        require_equal!(row[4], NATIVE_PATH_WRAPPER, "#{id}/#{role}/pk#{pk} selected wrapper")
        require_equal!(row[5], payload.nil? ? 'NULL' : OUTER_ACTUAL_TYPE, "#{id}/#{role}/pk#{pk} actual payload type")
        require_equal!(actual, payload, "#{id}/#{role}/pk#{pk} direct payload value")
      end
    end

    def validate_nested_rows!(rows, id, role)
      rows.each do |row|
        pk = Integer(row.fetch(3), 10)
        items = ITEMS_BY_PK.fetch(pk)
        expected_paths = {'v' => 'UInt8'}
        expected_paths['items'] = ITEM_ARRAY_TYPES.fetch(role) unless items.nil?
        expected_array = items.nil? ? nil : ITEM_ARRAY_TYPES.fetch(role)
        actual_items = row[13] == '6e756c6c' ? nil : parse_hex_json(row[13], "#{id}/#{role}/pk#{pk} child array")
        require_equal!(row.values_at(4, 5, 6, 7), [NATIVE_PATH_WRAPPER, OUTER_ACTUAL_TYPE, OUTER_ACTUAL_TYPE, PARENT_JSON_TYPE], "#{id}/#{role}/pk#{pk} nested descriptors")
        require_equal!(parse_hex_json(row[8], "#{id}/#{role}/pk#{pk} JSON path roster"), expected_paths, "#{id}/#{role}/pk#{pk} JSONAllPathsWithTypes")
        require_equal!(row[9], 'UInt8', "#{id}/#{role}/pk#{pk} parent typed v")
        require_equal!(Integer(row[10], 10), 42, "#{id}/#{role}/pk#{pk} parent v")
        require_equal!(row[11], PARENT_ITEMS_WRAPPER, "#{id}/#{role}/pk#{pk} declared child wrapper")
        require_equal!(row[12], expected_array || 'NULL', "#{id}/#{role}/pk#{pk} actual items array type")
        require_equal!(actual_items, items, "#{id}/#{role}/pk#{pk} nested JSON value")
      end
    end

    def validate_child_rows!(rows, id, role)
      expected = [[1, 1, 7], [1, 2, 8], [5, 1, 7], [8, 1, 77]]
      keys = rows.map { |row| [Integer(row.fetch(3), 10), Integer(row.fetch(4), 10)] }
      require_equal!(keys, expected.map { |pk, index, _value| [pk, index] }, "#{id}/#{role} child occurrence domain")
      leaf_type = LEAF_VALUE_TYPES.fetch(role)
      expected.zip(rows).each do |(pk, index, value), row|
        paths = parse_hex_json(row[8], "#{id}/#{role}/pk#{pk}/item#{index} JSONAllPathsWithTypes")
        item = parse_hex_json(row[11], "#{id}/#{role}/pk#{pk}/item#{index} JSON")
        require_equal!(row.values_at(5, 6, 7), [PARENT_ITEMS_WRAPPER, ITEM_ARRAY_TYPES.fetch(role), LEAF_JSON_TYPES.fetch(role)], "#{id}/#{role}/pk#{pk}/item#{index} descriptor chain")
        require_equal!(paths, {'v' => leaf_type}, "#{id}/#{role}/pk#{pk}/item#{index} leaf path type")
        require_equal!(row[9], leaf_type, "#{id}/#{role}/pk#{pk}/item#{index} leaf value type")
        require_equal!(Integer(row[10], 10), value, "#{id}/#{role}/pk#{pk}/item#{index} leaf scalar")
        require_equal!(item, {'v' => value}, "#{id}/#{role}/pk#{pk}/item#{index} JSON value")
      end
      true
    rescue ArgumentError, KeyError, TypeError => error
      fail!("#{id}/#{role} child witness malformed: #{error.class}: #{error.message}")
    end

    def validate_full_output!(stdout, id)
      rows = tagged_rows(stdout, FULL_TAG, 6)
      require_equal!(rows.size, 16, "#{id} full row count")
      ROLES.each do |role|
        subset = rows.select { |row| row[1] == id && row[2] == role }
        require_equal!(subset.map { |row| Integer(row[3], 10) }, (1..8).to_a, "#{id}/#{role} full row domain")
        subset.each do |row|
          pk = Integer(row[3], 10)
          require_equal!(row[4], STOCK_TYPE, "#{id}/#{role}/pk#{pk} full Object type")
          require_equal!(parse_hex_json(row[5], "#{id}/#{role}/pk#{pk} full Object"), EXPECTED_DOCS.fetch(pk - 1).fetch('doc'), "#{id}/#{role}/pk#{pk} full value")
        end
      end
      @counts[:full] += rows.size
      true
    rescue ArgumentError, KeyError, TypeError => error
      fail!("#{id} full output malformed: #{error.class}: #{error.message}")
    end

    def expected_sql_by_label
      token = Digest::SHA256.hexdigest(@root)[0, 8]
      tables = {}
      PROFILE_IDS.each { |id| ROLES.each { |role| tables[[id, role]] = "w243_#{token}_#{id}_#{role}" } }
      input_path = File.join(@root, 'invocations', 'helper_input.json')
      helper_sql = ''.b
      prefix = [
        'SET output_format_json_quote_64bit_integers=0;',
        "SELECT '__W241_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
        'SET print_pretty_type_names=0;',
        'SET output_format_json_quote_64bit_integers=0;',
      ].join("\n")
      create_statements = []
      table_literals = []
      PROFILE_IDS.each do |id|
        version = VERSIONS.fetch(id)
        layout = %w[map map_with_buckets advanced advanced_chunked].fetch(version)
        string = STRING_PROFILES.fetch(id)
        string_setting = string == 's0' ? 'single_stream' : 'with_size_stream'
        setting_list = [
          'index_granularity=2', 'index_granularity_bytes=10485760',
          'enable_mixed_granularity_parts=1', 'min_rows_for_wide_part=0', 'min_bytes_for_wide_part=0',
          'compress_marks=0', 'compress_primary_key=0', 'min_compress_block_size=0', 'max_compress_block_size=4096',
          'ratio_of_defaults_for_sparse_serialization=1', "default_compression_codec='LZ4'",
          "serialization_info_version='with_types'", "dynamic_serialization_version='v3'",
          "object_serialization_version='v3'", 'propagate_types_serialization_versions_to_nested_types=true',
          'object_shared_data_buckets_for_wide_part=2',
          "object_shared_data_serialization_version='#{layout}'",
          "object_shared_data_serialization_version_for_zero_level_parts='#{layout}'",
          "string_serialization_version='#{string_setting}'",
        ]
        setting_list << 'object_shared_data_target_chunk_rows=2' if version == 3
        ROLES.each do |role|
          table = tables.fetch([id, role])
          create_statements << "CREATE TABLE default.#{table} (pk UInt64, doc #{STOCK_TYPE}) ENGINE=MergeTree ORDER BY pk SETTINGS #{setting_list.join(', ')};"
          table_literals << "'#{table}'"
        end
      end
      create_statements << "SELECT '#{PATH_TAG}', database, name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name IN (#{table_literals.join(',')}) ORDER BY name FORMAT TSVRaw;"
      sql = {}
      sql['crystal_helper'] = helper_sql
      sql['native_create_tables'] = prefix + "\n" + create_statements.join("\n")
      attach = []
      PROFILE_IDS.each do |id|
        ROLES.each do |role|
          table = tables.fetch([id, role])
          attach << "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0';"
          attach << "SELECT '#{CHECK_BEGIN_TAG}', '#{id}', '#{role}' FORMAT TSVRaw;"
          attach << "CHECK TABLE default.#{table} FORMAT TSV;"
          attach << "SELECT '#{CHECK_END_TAG}', '#{id}', '#{role}' FORMAT TSVRaw;"
          attach << "SELECT '#{SCHEMA_TAG}', '#{id}', '#{role}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;"
          attach << "SELECT '#{PART_TAG}', '#{id}', '#{role}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;"
        end
      end
      sql['native_attach_check'] = prefix + "\n" + attach.join("\n")
      PROFILE_IDS.each do |id|
        direct = []
        ROLES.each do |role|
          table = tables.fetch([id, role])
          direct << direct_sql(table, id, role)
          direct << nested_sql(table, id, role)
          direct << child_sql(table, id, role)
        end
        sql["native_direct_#{id}"] = prefix + "\n" + direct.join("\n")
        full = ROLES.map do |role|
          table = tables.fetch([id, role])
          "SELECT '#{FULL_TAG}', '#{id}', '#{role}', toString(pk), toTypeName(doc), hex(toJSONString(doc)) FROM default.#{table} ORDER BY pk FORMAT TSVRaw;"
        end
        sql["native_full_#{id}"] = prefix + "\n" + full.join("\n")
      end
      sql
    end

    def direct_sql(table, id, role)
      "SELECT '#{DIRECT_TAG}', '#{id}', '#{role}', toString(pk), toTypeName(doc.payload), if(isNull(doc.payload), 'NULL', dynamicType(doc.payload)), if(isNull(doc.payload), '6e756c6c', hex(toJSONString(doc.payload))) FROM default.#{table} ORDER BY pk FORMAT TSVRaw;"
    end

    def nested_sql(table, id, role)
      tuple_value = "assumeNotNull(dynamicElement(doc.payload, '#{OUTER_ACTUAL_TYPE}'))"
      parent = "tupleElement(#{tuple_value}, 1)"
      items = "#{parent}.items"
      item_type = ITEM_ARRAY_TYPES.fetch(role)
      items_json = "dynamicElement(#{items}, '#{item_type}')"
      "SELECT '#{NESTED_TAG}', '#{id}', '#{role}', toString(pk), toTypeName(doc.payload), dynamicType(doc.payload), toTypeName(#{tuple_value}), toTypeName(#{parent}), hex(toJSONString(JSONAllPathsWithTypes(#{parent}))), toTypeName(#{parent}.v), toString(#{parent}.v), toTypeName(#{items}), if(isNull(#{items}), 'NULL', dynamicType(#{items})), if(isNull(#{items}), '6e756c6c', hex(toJSONString(#{items_json}))) FROM default.#{table} WHERE isNotNull(doc.payload) ORDER BY pk FORMAT TSVRaw;"
    end

    def child_sql(table, id, role)
      tuple_value = "assumeNotNull(dynamicElement(doc.payload, '#{OUTER_ACTUAL_TYPE}'))"
      parent = "tupleElement(#{tuple_value}, 1)"
      item_type = ITEM_ARRAY_TYPES.fetch(role)
      item_array = "assumeNotNull(dynamicElement(parent.items, '#{item_type}'))"
      "SELECT '#{CHILD_TAG}', '#{id}', '#{role}', toString(pk), toString(item_index), toTypeName(parent.items), dynamicType(parent.items), toTypeName(item), hex(toJSONString(JSONAllPathsWithTypes(item))), toTypeName(item.v), toString(item.v), hex(toJSONString(item)) FROM (SELECT pk, #{parent} AS parent FROM default.#{table} WHERE pk IN (1, 5, 8)) AS nested ARRAY JOIN arrayEnumerate(#{item_array}) AS item_index, #{item_array} AS item ORDER BY pk, item_index FORMAT TSVRaw;"
    end

    def stdout_lines(stdout)
      text = stdout.dup.force_encoding(Encoding::UTF_8)
      fail!('native stdout is invalid UTF-8') unless text.valid_encoding?
      text.split("\n", -1).tap { |lines| lines.pop if lines.last == '' }
    end

    def tagged_rows(stdout, tag, width)
      rows = []
      stdout_lines(stdout).each do |line|
        next unless line.start_with?(tag + "\t")
        fields = line.split("\t", -1)
        fail!("#{tag} row width differs") unless fields.size == width && fields[0] == tag
        rows << fields
      end
      rows
    end

    def parse_hex_json(value, label)
      fail!("#{label} is not even-length hexadecimal") unless value.is_a?(String) && /\A(?:[0-9a-fA-F]{2})+\z/.match?(value)
      parse_json!([value].pack('H*'), label)
    end

    def parse_single_json_line!(bytes, label)
      lines = stdout_lines(bytes)
      fail!("#{label} must contain exactly one JSON line") unless lines.size == 1 && !lines.first.empty?
      parse_json!(lines.first, label)
    end

    def expected_direct_rows
      EXPECTED_DOCS.map do |entry|
        value = entry.fetch('doc').fetch('payload', nil)
        {'pk' => entry.fetch('pk'), 'type' => value.nil? ? 'NULL' : OUTER_ACTUAL_TYPE,
         'wrapper_type' => SELECTED_PATH_WRAPPER, 'value' => value}
      end
    end

    def expected_nested_witnesses(role)
      (1..8).map do |pk|
        doc = EXPECTED_DOCS.fetch(pk - 1).fetch('doc')
        payload = doc.fetch('payload', nil)
        items = ITEMS_BY_PK.fetch(pk)
        state = if [4, 6].include?(pk)
                  'missing_payload'
                elsif pk == 3
                  'absent'
                elsif items.empty?
                  'empty'
                else
                  'populated'
                end
        nested_items = (items || []).each_with_index.map do |item, index|
          leaf_value = item.fetch('v')
          {'index' => index, 'actual_type' => LEAF_JSON_TYPES.fetch(role),
           'paths_types' => {'v' => LEAF_VALUE_TYPES.fetch(role)},
           'v_type' => LEAF_VALUE_TYPES.fetch(role), 'v_value' => leaf_value}
        end
        {'pk' => pk, 'payload_state' => payload.nil? ? 'missing' : 'value',
         'payload_actual_type' => payload.nil? ? 'MISSING' : OUTER_ACTUAL_TYPE,
         'parent_json_type' => PARENT_JSON_TYPE, 'parent_v_type' => 'UInt8',
         'parent_v' => payload.nil? ? nil : 42, 'items_state' => state,
         'items_actual_type' => [3, 4, 6].include?(pk) ? 'MISSING' : ITEM_ARRAY_TYPES.fetch(role),
         'leaf_json_type' => LEAF_JSON_TYPES.fetch(role), 'nested_path' => 'payload.1.items[]',
         'nested_items' => nested_items}
      end
    end

    def expected_windows(role)
      WINDOWS.flat_map do |window, first_mark, count, pks|
        expected_counts = Array.new(count) { |offset| REAL_MARK_ROWS.fetch(first_mark + offset) }
        rows = pks.map { |pk| EXPECTED_DOCS.fetch(pk - 1) }
        direct = expected_direct_rows.select { |row| pks.include?(row.fetch('pk')) }
        [
          {'consumer' => 'whole_object', 'path' => nil, 'window' => window,
           'first_mark' => first_mark, 'mark_count' => count,
           'expected_mark_row_counts' => expected_counts, 'actual_mark_row_counts' => expected_counts,
           'expected_rows' => rows, 'actual_rows' => rows, 'matches_full_slice' => true},
          {'consumer' => 'selected_path', 'path' => 'payload', 'window' => window,
           'first_mark' => first_mark, 'mark_count' => count,
           'expected_mark_row_counts' => expected_counts, 'actual_mark_row_counts' => expected_counts,
           'expected_rows' => direct, 'actual_rows' => direct, 'matches_full_slice' => true},
        ]
      end
    end

    def expected_nested_value_projection
      expected_nested_witnesses('normal').map do |row|
        {'pk' => row.fetch('pk'), 'state' => row.fetch('items_state'),
         'items' => row.fetch('nested_items').map { |item| {'index' => item.fetch('index'), 'v_value' => item.fetch('v_value')} }}
      end
    end

    def expected_nested_type_projection(role)
      expected_nested_witnesses(role).map do |row|
        {'pk' => row.fetch('pk'), 'v_types' => row.fetch('nested_items').map { LEAF_VALUE_TYPES.fetch(role) }}
      end
    end

    def synthetic_child_rows(id, role)
      expected = [[1, 1, 7], [1, 2, 8], [5, 1, 7], [8, 1, 77]]
      expected.map do |pk, index, value|
        leaf = LEAF_VALUE_TYPES.fetch(role)
        [CHILD_TAG, id, role, pk.to_s, index.to_s, PARENT_ITEMS_WRAPPER,
         ITEM_ARRAY_TYPES.fetch(role), LEAF_JSON_TYPES.fetch(role),
         hex_json({'v' => leaf}), leaf, value.to_s, hex_json({'v' => value})]
      end
    end

    def hex_json(value)
      JSON.generate(value).unpack1('H*')
    end

    def expected_part_snapshot(path)
      part_snapshot(path)
    end

    def part_snapshot(path)
      fail!("part path #{path} is not a directory") unless File.directory?(path) && !File.symlink?(path)
      result = []
      total = 0
      Find.find(path) do |entry|
        stat = File.lstat(entry)
        fail!("part contains symlink/special entry #{entry}") unless !stat.symlink? && (stat.directory? || stat.file?)
        next if stat.directory?
        fail!("part file exceeds size cap #{entry}") if stat.size > MAX_PART_FILE_BYTES
        total += stat.size
        fail!('part exceeds aggregate size cap') if total > MAX_PART_TOTAL_BYTES
        bytes = read_bounded(entry, MAX_PART_FILE_BYTES, 'part file')
        result << [entry.delete_prefix(path + File::SEPARATOR), stat.size, Digest::SHA256.hexdigest(bytes)]
      end
      result.sort
    end

    def inventory_snapshot(inventory, label)
      fail!("#{label} is malformed") unless inventory.is_a?(Array) && inventory.size <= 4096
      result = inventory.map do |entry|
        exact_keys!(entry, %w[name size sha256], "#{label} entry")
        name = entry.fetch('name')
        fail!("#{label} has unsafe or duplicate filename") unless name.is_a?(String) && /\A[a-zA-Z0-9_.-]+\z/.match?(name)
        size = entry.fetch('size')
        sha = entry.fetch('sha256')
        fail!("#{label} has invalid size/digest") unless size.is_a?(Integer) && size >= 0 && size <= MAX_PART_FILE_BYTES && sha.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(sha)
        [name, size, sha]
      end
      fail!("#{label} has duplicate/unsorted filenames") unless result.map(&:first).uniq == result.map(&:first) && result.map(&:first) == result.map(&:first).sort
      result
    end

    def normalize_snapshot(value, label)
      fail!("#{label} malformed") unless value.is_a?(Array)
      result = value.map do |entry|
        fail!("#{label} entry malformed") unless entry.is_a?(Array) && entry.size == 3
        name, size, sha = entry
        fail!("#{label} entry invalid") unless name.is_a?(String) && /\A[a-zA-Z0-9_.-]+\z/.match?(name) && size.is_a?(Integer) && size >= 0 && sha.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(sha)
        [name, size, sha]
      end
      fail!("#{label} duplicate/unsorted") unless result.map(&:first).uniq == result.map(&:first) && result.map(&:first) == result.map(&:first).sort
      result
    end

    def verify_attach_copy!(source_snapshot, attached_path, attached_snapshot, id, role)
      source = source_snapshot.each_with_object({}) { |(name, size, sha), result| result[name] = [size, sha] }
      attached = attached_snapshot.each_with_object({}) { |(name, size, sha), result| result[name] = [size, sha] }
      marker = 'invalidated_system_columns.txt'
      require_equal!(attached.keys - source.keys, [marker], "#{id}/#{role} native ATTACH-only file roster")
      require_equal!(source.keys - attached.keys, [], "#{id}/#{role} attached missing files")
      source.each { |name, value| require_equal!(attached.fetch(name), value, "#{id}/#{role} attached original file #{name}") }
      marker_bytes = read_bounded(File.join(attached_path, marker), 1024, 'native invalidated system columns marker')
      require_equal!(marker_bytes, "_block_offset\n_block_number\n".b, "#{id}/#{role} ATTACH marker bytes")
    end

    def canonical_directory!(path, expected_parent, label)
      fail!("#{label} is not absolute/canonical") unless path.is_a?(String) && File.expand_path(path) == path && File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path
      parent = File.expand_path(expected_parent)
      fail!("#{label} escaped expected parent") unless path.start_with?(parent + File::SEPARATOR)
      cursor = parent
      path.delete_prefix(parent + File::SEPARATOR).split(File::SEPARATOR).each do |component|
        cursor = File.join(cursor, component)
        fail!("#{label} traverses symlink #{cursor}") if File.symlink?(cursor)
      end
      path
    end

    def canonical_existing_path(raw, expected_parent, label)
      fail!("#{label} is not absolute") unless raw.is_a?(String) && raw.start_with?(File::SEPARATOR)
      expanded = File.expand_path(raw)
      canonical_directory!(expanded, expected_parent, label)
      expanded
    end

    def table_name(id, role)
      fail!('unrostered W243 table identity') unless PROFILE_IDS.include?(id) && ROLES.include?(role)
      "w243_#{Digest::SHA256.hexdigest(@root)[0, 8]}_#{id}_#{role}"
    end

    def exact_keys!(value, keys, label)
      fail!("#{label} is not an object with exact keys") unless value.is_a?(Hash) && value.keys.sort == keys.sort
      true
    end

    def require_equal!(actual, expected, label)
      fail!("#{label} differs; got #{actual.inspect}, expected #{expected.inspect}") unless actual == expected
      true
    end

    def rejects?
      yield
      false
    rescue Failure, JSON::ParserError, KeyError, ArgumentError, TypeError
      true
    end

    def deep_dup(value)
      case value
      when Hash then value.each_with_object({}) { |(key, nested), copy| copy[key] = deep_dup(nested) }
      when Array then value.map { |nested| deep_dup(nested) }
      else value
      end
    end
  end
end

def main
  options = {}
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/audit_object_descendant_json_w243.rb --summary PATH --summary-sha256 SHA --clickhouse PATH --crystal-helper PATH --helper-sha256 SHA --helper-source-sha256 SHA --self-test'
    parser.on('--summary PATH') { |value| options[:summary] = value }
    parser.on('--summary-sha256 SHA') { |value| options[:summary_sha256] = value }
    parser.on('--clickhouse PATH') { |value| options[:clickhouse] = value }
    parser.on('--crystal-helper PATH') { |value| options[:helper_path] = value }
    parser.on('--helper-sha256 SHA') { |value| options[:helper_sha256] = value }
    parser.on('--helper-source-sha256 SHA') { |value| options[:helper_source_sha256] = value }
    parser.on('--self-test') { options[:self_test] = true }
    parser.on('--self-test-only') { options[:self_test_only] = true }
  end.parse!

  if options[:self_test_only]
    auditor = AuditObjectDescendantJSONW243::Auditor.allocate
    result = auditor.self_test!
    puts JSON.generate({status: 'self_test_passed', controls: result})
    exit 0
  end
  %i[summary summary_sha256 clickhouse helper_path helper_sha256 helper_source_sha256].each do |key|
    raise ArgumentError, "--#{key.to_s.tr('_', '-')} is required" unless options[key]
  end
  result = AuditObjectDescendantJSONW243::Auditor.new(
    summary_path: options[:summary], summary_sha256: options[:summary_sha256],
    clickhouse: options[:clickhouse], helper_path: options[:helper_path],
    helper_sha256: options[:helper_sha256], helper_source_sha256: options[:helper_source_sha256],
    self_test: options[:self_test],
  ).run
  puts JSON.generate(result)
rescue AuditObjectDescendantJSONW243::Failure, ArgumentError, KeyError, TypeError => error
  warn error.message
  exit 1
end

main if $PROGRAM_NAME == __FILE__
