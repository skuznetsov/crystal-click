#!/usr/bin/env ruby
# Bounded W243 generated-part/native-reader qualification for a JSON child
# nested under an inferred Dynamic Array(JSON) descendant.
#
# Scope is deliberately one-way: Crystal-written parts are read back by the
# Crystal helper and by a pinned stock ClickHouse runtime. This does not claim
# stock-authored W243 part coverage.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require_relative 'probe_object_shared_json_interop_w241'
require_relative 'probe_object_recursive_dynamic_w242'

module ProbeObjectDescendantJSONW243
  W241 = ProbeObjectSharedJSONInteropW241
  W242 = ProbeObjectRecursiveDynamicW242

  FORMAT = 'object_descendant_json_w243_capture_v1'.freeze
  HELPER_INPUT_FORMAT = 'object_descendant_json_w243_input_v1'.freeze
  HELPER_OUTPUT_FORMAT = 'object_descendant_json_w243_helper_v1'.freeze
  HELPER_SOURCE = File.expand_path('check_object_descendant_json_w243.cr', __dir__).freeze
  HELPER_SOURCE_SHA256 = '2e4d7835a07fc596220d1d1b0b9daf5dd52684ca1b4773ba818cd98d468ba08e'.freeze

  ROW_COUNT = 8
  FRAME_BYTES_OPTIONS = [32, 64].freeze
  MARK_ROWS = [2, 2, 2, 2].freeze
  PHYSICAL_MARKS = 5 # Four real marks plus the zero-row terminal sentinel.
  MAX_HELPER_OUTPUT_BYTES = 32 * 1024 * 1024
  MAX_PART_FILE_BYTES = 16 * 1024 * 1024
  MAX_PART_TOTAL_BYTES = 64 * 1024 * 1024

  PATH_TAG = '__W243_PATH__'.freeze
  CHECK_BEGIN_TAG = '__W243_CHECK_BEGIN__'.freeze
  CHECK_END_TAG = '__W243_CHECK_END__'.freeze
  SCHEMA_TAG = '__W243_SCHEMA__'.freeze
  PART_TAG = '__W243_PART__'.freeze
  DIRECT_TAG = '__W243_DIRECT__'.freeze
  NESTED_TAG = '__W243_NESTED__'.freeze
  CHILD_TAG = '__W243_CHILD__'.freeze
  FULL_TAG = '__W243_FULL__'.freeze

  STOCK_TYPE = W241::STOCK_TYPE
  OUTER_ACTUAL_TYPE = 'Tuple(JSON(max_dynamic_types=2, max_dynamic_paths=1, v UInt8), Array(Dynamic(max_types=1)))'.freeze
  PARENT_JSON_TYPE = 'JSON(max_dynamic_types=2, max_dynamic_paths=1, v UInt8)'.freeze
  PARENT_ITEMS_TYPE = 'Dynamic(max_types=2)'.freeze
  NATIVE_PATH_WRAPPER = 'Dynamic'.freeze
  DYNAMIC_PATH_CARRIER = 'Dynamic(max_types=254)'.freeze
  LEAF_JSON_TYPES = {
    'normal' => 'JSON(max_dynamic_types=0, max_dynamic_paths=0, v UInt8)',
    'type_only' => 'JSON(max_dynamic_types=0, max_dynamic_paths=0, v Int64)',
  }.freeze
  ITEM_ARRAY_TYPES = LEAF_JSON_TYPES.each_with_object({}) do |(role, descriptor), result|
    result[role] = "Array(#{descriptor})"
  end.freeze
  PROFILE_LAYOUTS = {
    'map' => 0,
    'map_with_buckets' => 1,
    'advanced' => 2,
    'advanced_chunked' => 3,
  }.freeze
  BUCKETS_BY_VERSION = {0 => 1, 1 => 2, 2 => 1, 3 => 2}.freeze

  WINDOWS = {
    'middle' => {first_mark: 1, mark_count: 2, pks: [3, 4, 5, 6]},
    'last' => {first_mark: 3, mark_count: 1, pks: [7, 8]},
    'empty_interior' => {first_mark: 2, mark_count: 0, pks: []},
    'zero_count_end' => {first_mark: 4, mark_count: 0, pks: []},
  }.freeze

  EXPECTED_DOCS = [
    {'pk' => 1, 'doc' => {'payload' => [{'v' => 42, 'items' => [{'v' => 7}, {'v' => 8}]}, []]}},
    {'pk' => 2, 'doc' => {'payload' => [{'v' => 42, 'items' => []}, []]}},
    {'pk' => 3, 'doc' => {'payload' => [{'v' => 42}, []]}},
    {'pk' => 4, 'doc' => {}},
    {'pk' => 5, 'doc' => {'payload' => [{'v' => 42, 'items' => [{'v' => 7}]}, []]}},
    # ObjectDocument materialization omits the input Nothing/NULL payload.
    {'pk' => 6, 'doc' => {}},
    {'pk' => 7, 'doc' => {'payload' => [{'v' => 42, 'items' => []}, []]}},
    {'pk' => 8, 'doc' => {'payload' => [{'v' => 42, 'items' => [{'v' => 77}]}, []]}},
  ].freeze

  ITEMS_BY_PK = {
    1 => [{'v' => 7}, {'v' => 8}],
    2 => [],
    3 => nil,
    4 => nil,
    5 => [{'v' => 7}],
    6 => nil,
    7 => [],
    8 => [{'v' => 77}],
  }.freeze

  class Failure < StandardError; end

  class Probe
    def initialize(binary, helper, evidence_root, frame_bytes)
      require_true(FRAME_BYTES_OPTIONS.include?(frame_bytes), 'frame_bytes must be exactly 32 or 64')
      @binary = validate_executable(binary, 'ClickHouse')
      @helper = validate_executable(helper, 'W243 Crystal helper')
      @root = validate_root(evidence_root)
      @frame_bytes = frame_bytes
      @token = Digest::SHA256.hexdigest(@root)[0, 8]
      @runner = W241::Probe.new(@binary, @helper, @root, @frame_bytes)
      @invocations = @runner.instance_variable_get(:@invocations)
      @parts = []
      @profiles = []
      @tables = {}
      @fatal_error = nil
      @last_stage = nil
    end

    def run
      prepare_tree!
      @runtime_sha_before = Digest::SHA256.file(@binary).hexdigest
      require_true(@runtime_sha_before == W241::BINARY_SHA256, 'runtime binary SHA differs from the pinned ClickHouse executable')
      @helper_sha_before = Digest::SHA256.file(@helper).hexdigest
      @helper_source_sha_before = hash_bounded_file(HELPER_SOURCE, 2 * 1024 * 1024, 'W243 helper source')
      require_true(@helper_source_sha_before == HELPER_SOURCE_SHA256, 'W243 helper source SHA differs from its frozen pin')

      capture_generated_parts!
      create_native_tables!
      attach_and_check_parts!
      capture_direct_oracles!
      capture_full_oracles!
      assert_unchanged_parts!

      @runtime_sha_after = Digest::SHA256.file(@binary).hexdigest
      @helper_sha_after = Digest::SHA256.file(@helper).hexdigest
      @helper_source_sha_after = hash_bounded_file(HELPER_SOURCE, 2 * 1024 * 1024, 'W243 helper source')
      require_true(@runtime_sha_after == W241::BINARY_SHA256, 'runtime binary changed during the capture')
      require_true(@helper_sha_after == @helper_sha_before, 'helper executable changed during the capture')
      require_true(@helper_source_sha_after == HELPER_SOURCE_SHA256, 'W243 helper source changed during the capture')

      write_summary('library_written_native_read_observed', nil)
      puts "W243 status=library_written_native_read_observed; profiles=#{@profiles.size}/#{W241::PROFILE_IDS.size}; parts=#{@parts.size}; frame_bytes=#{@frame_bytes}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @runtime_sha_after = Digest::SHA256.file(@binary).hexdigest rescue nil
      @helper_sha_after = Digest::SHA256.file(@helper).hexdigest rescue nil
      @helper_source_sha_after = hash_bounded_file(HELPER_SOURCE, 2 * 1024 * 1024, 'W243 helper source') rescue nil
      write_summary('capture_failure_inconclusive', @fatal_error) rescue nil
      warn "W243 generated/native oracle incomplete: #{@fatal_error}"
      false
    end

    private

    def require_true(condition, message)
      raise Failure, "W243: #{message}" unless condition
    end

    def validate_executable(path, label)
      require_true(path.is_a?(String) && !path.empty?, "#{label} path is required")
      expanded = File.expand_path(path)
      require_true(File.file?(expanded) && File.executable?(expanded) && !File.symlink?(expanded),
                   "#{label} must be a regular executable, not a symlink")
      expanded
    end

    def validate_root(path)
      require_true(path.is_a?(String) && !path.empty?, 'evidence root is required')
      expanded = File.expand_path(path)
      require_true(File.dirname(expanded) == File.realpath('/private/tmp') &&
                   File.directory?(expanded) && !File.symlink?(expanded) &&
                   File.realpath(expanded) == expanded && Dir.children(expanded).empty?,
                   'evidence root must be a canonical empty direct child of /private/tmp')
      expanded
    rescue Errno::ENOENT
      raise Failure, 'evidence root must already exist'
    end

    def prepare_tree!
      %w[invocations stores parts generated].each do |name|
        Dir.mkdir(File.join(@root, name), 0o700)
      end
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
    end

    def hash_bounded_file(path, limit, label)
      require_true(File.file?(path) && !File.symlink?(path), "#{label} is absent or symlinked")
      size = File.size(path)
      require_true(size >= 0 && size <= limit, "#{label} exceeds its byte bound")
      bytes = File.binread(path)
      require_true(bytes.bytesize == size, "#{label} changed while reading")
      Digest::SHA256.hexdigest(bytes)
    end

    def read_bounded(path, limit, label)
      require_true(File.file?(path) && !File.symlink?(path), "#{label} is absent or symlinked")
      size = File.size(path)
      require_true(size >= 0 && size <= limit, "#{label} exceeds its byte bound")
      bytes = File.binread(path)
      require_true(bytes.bytesize == size, "#{label} changed while reading")
      bytes
    end

    def write_new(path, bytes)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes) }
    end

    def helper_input
      profiles = W241::PROFILES.map do |profile|
        {
          'id' => profile.fetch(:id),
          'shared_version' => profile.fetch(:layout).fetch(:enum),
          'string_profile' => profile.fetch(:string).fetch(:id),
        }
      end
      JSON.generate({'format' => HELPER_INPUT_FORMAT, 'frame_bytes' => @frame_bytes, 'profiles' => profiles}) + "\n"
    end

    def capture_generated_parts!
      input_bytes = helper_input
      input_path = File.join(@root, 'invocations', 'helper_input.json')
      output_root = File.join(@root, 'generated')
      write_new(input_path, input_bytes)
      helper_sha = Digest::SHA256.file(@helper).hexdigest
      invocation = @runner.send(:run_process, 'crystal_helper', [@helper, input_path, output_root], ''.b,
                                'crystal-helper', expected_sha: helper_sha, binary_path: @helper)
      require_process_success!(invocation, 'Crystal helper')
      stdout = invocation.fetch(:stdout)
      require_true(stdout.bytesize <= MAX_HELPER_OUTPUT_BYTES, 'W243 helper output exceeds its byte bound')
      helper_data = W242.parse_evidence_json!(stdout, 'W243 helper output')
      validate_helper_output!(helper_data, input_bytes, output_root)
      @helper_record = invocation.fetch(:record)
      @helper_output_sha256 = Digest::SHA256.hexdigest(stdout)
      @helper_input_sha256 = Digest::SHA256.hexdigest(input_bytes)
      @helper_data = helper_data
      true
    end

    def validate_helper_output!(data, input_bytes, output_root)
      exact_keys!(data, %w[format input_sha256 output_root requested_frame_bytes profile_ids profiles], 'helper top-level')
      require_true(data.fetch('format') == HELPER_OUTPUT_FORMAT, 'helper output format differs')
      require_true(data.fetch('input_sha256') == Digest::SHA256.hexdigest(input_bytes), 'helper input SHA differs')
      require_true(data.fetch('output_root') == output_root, 'helper output root differs')
      require_true(data.fetch('requested_frame_bytes') == @frame_bytes, 'helper frame-size request differs')
      require_true(data.fetch('profile_ids') == W241::PROFILE_IDS, 'helper fixed profile roster differs')
      profiles = data.fetch('profiles')
      require_true(profiles.is_a?(Array) && profiles.size == W241::PROFILES.size, 'helper profile count differs')
      profiles.each_with_index do |entry, index|
        profile = W241::PROFILES.fetch(index)
        validate_helper_profile!(entry, profile, output_root)
      end
      true
    rescue KeyError, TypeError => error
      raise Failure, "W243 helper envelope is malformed: #{error.class}: #{error.message}"
    end

    def validate_helper_profile!(entry, profile, output_root)
      exact_keys!(entry, %w[
        id shared_version string_profile bucket_count outer_actual_type parent_json_type
        normal_item_array_type type_only_item_array_type normal_part type_only_part pair_comparison
      ], "helper profile #{profile.fetch(:id)}")
      id = profile.fetch(:id)
      version = profile.fetch(:layout).fetch(:enum)
      string_id = profile.fetch(:string).fetch(:id)
      bucket_count = BUCKETS_BY_VERSION.fetch(version)
      require_true(entry.fetch('id') == id && entry.fetch('shared_version') == version &&
                   entry.fetch('string_profile') == string_id && entry.fetch('bucket_count') == bucket_count,
                   "#{id} helper profile metadata differs")
      require_true(entry.fetch('outer_actual_type') == OUTER_ACTUAL_TYPE &&
                   entry.fetch('parent_json_type') == PARENT_JSON_TYPE &&
                   entry.fetch('normal_item_array_type') == ITEM_ARRAY_TYPES.fetch('normal') &&
                   entry.fetch('type_only_item_array_type') == ITEM_ARRAY_TYPES.fetch('type_only'),
                   "#{id} helper descriptor roster differs")

      normal = validate_helper_part!(entry.fetch('normal_part'), profile, 'normal', output_root, bucket_count)
      type_only = validate_helper_part!(entry.fetch('type_only_part'), profile, 'type_only', output_root, bucket_count)
      validate_helper_pair!(entry.fetch('pair_comparison'), normal, type_only, id)
      @parts << normal.merge(profile: profile, role: 'normal')
      @parts << type_only.merge(profile: profile, role: 'type_only')
      @profiles << {id: id, shared_version: version, string_profile: string_id,
                    bucket_count: bucket_count, status: 'helper_part_observed'}
      true
    rescue KeyError, TypeError => error
      raise Failure, "#{profile.fetch(:id)} helper profile is malformed: #{error.class}: #{error.message}"
    end

    def validate_helper_part!(part, profile, role, output_root, bucket_count)
      exact_keys!(part, %w[
        role path schema_declaration columns_text count_text count shared_version bucket_count
        string_profile ordinary_string_profile mark_row_counts physical_stream_names
        physical_file_inventory full_rows direct_payload_rows nested_type_witnesses bounded_windows
        outer_actual_type parent_json_type item_array_type leaf_json_type nested_path
      ], "#{profile.fetch(:id)}/#{role} helper part")
      id = profile.fetch(:id)
      version = profile.fetch(:layout).fetch(:enum)
      string_id = profile.fetch(:string).fetch(:id)
      expected_path = File.join(output_root, "#{id}_#{role}")
      path = part.fetch('path')
      require_true(path == expected_path && File.directory?(path) && !File.symlink?(path) &&
                   File.realpath(path) == path,
                   "#{id}/#{role} helper part path differs or is not canonical")
      require_true(part.fetch('role') == role && part.fetch('schema_declaration') == STOCK_TYPE &&
                   part.fetch('shared_version') == version && part.fetch('bucket_count') == bucket_count &&
                   part.fetch('string_profile') == string_id &&
                   part.fetch('ordinary_string_profile') == (string_id == 's0' ? 0 : 1),
                   "#{id}/#{role} helper part profile/type differs")
      require_true(part.fetch('count') == ROW_COUNT && part.fetch('count_text').strip == ROW_COUNT.to_s &&
                   part.fetch('mark_row_counts') == MARK_ROWS,
                   "#{id}/#{role} helper row/real-mark domain differs")
      require_true(part.fetch('outer_actual_type') == OUTER_ACTUAL_TYPE &&
                   part.fetch('parent_json_type') == PARENT_JSON_TYPE &&
                   part.fetch('item_array_type') == ITEM_ARRAY_TYPES.fetch(role) &&
                   part.fetch('leaf_json_type') == LEAF_JSON_TYPES.fetch(role) &&
                   part.fetch('nested_path') == 'payload.1.items[]',
                   "#{id}/#{role} helper nested descriptor/site differs")

      expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`doc` #{STOCK_TYPE}\n"
      columns = read_bounded(File.join(path, 'columns.txt'), 4096, "#{id}/#{role} columns.txt")
      require_true(part.fetch('columns_text') == columns && columns == expected_columns,
                   "#{id}/#{role} physical columns differ")
      files = authenticate_part_inventory!(path, part.fetch('physical_file_inventory'), id, role)
      metadata = validate_part_metadata!(path, profile, part, id, role)

      full_rows = part.fetch('full_rows')
      expected_full = EXPECTED_DOCS
      require_true(full_rows == expected_full, "#{id}/#{role} library full read differs from the fixture")
      direct_rows = expected_direct_rows(role)
      require_true(part.fetch('direct_payload_rows') == direct_rows,
                   "#{id}/#{role} library selected-path rows differ from the fixture")
      witnesses = part.fetch('nested_type_witnesses')
      validate_nested_witnesses!(witnesses, role, id)
      windows = part.fetch('bounded_windows')
      validate_windows!(windows, role, id)
      {
        profile: profile, role: role, path: path, table: nil,
        source_snapshot: files.fetch(:snapshot), part_inventory: files.fetch(:inventory),
        physical_stream_names: metadata.fetch(:doc_streams),
        part_metadata: metadata,
        helper_part: part,
      }
    rescue KeyError, TypeError => error
      raise Failure, "#{profile.fetch(:id)}/#{role} helper part is malformed: #{error.class}: #{error.message}"
    end

    def validate_helper_pair!(pair, normal, type_only, id)
      exact_keys!(pair, %w[
        full_rows_equal direct_payload_rows_equal nested_json_values_equal
        normal_nested_values type_only_nested_values normal_nested_types type_only_nested_types
      ], "#{id} helper pair")
      require_true(pair.fetch('full_rows_equal') == true && pair.fetch('direct_payload_rows_equal') == true &&
                   pair.fetch('nested_json_values_equal') == true,
                   "#{id} helper type-only comparison did not preserve logical values")
      normal_witness = normal.fetch(:helper_part).fetch('nested_type_witnesses')
      type_witness = type_only.fetch(:helper_part).fetch('nested_type_witnesses')
      normal_projection = nested_value_projection(normal_witness)
      type_projection = nested_value_projection(type_witness)
      require_true(pair.fetch('normal_nested_values') == normal_projection &&
                   pair.fetch('type_only_nested_values') == type_projection && normal_projection == type_projection,
                   "#{id} helper nested type-only pair changed JSON values")
      require_true(pair.fetch('normal_nested_types') == nested_type_projection(normal_witness, 'normal') &&
                   pair.fetch('type_only_nested_types') == nested_type_projection(type_witness, 'type_only'),
                   "#{id} helper nested type-only descriptors differ")
      true
    rescue KeyError, TypeError => error
      raise Failure, "#{id} helper pair is malformed: #{error.class}: #{error.message}"
    end

    def exact_keys!(object, expected, label)
      require_true(object.is_a?(Hash) && object.keys.sort == expected.sort,
                   "#{label} key set differs")
    end

    def expected_direct_rows(role)
      expected = EXPECTED_DOCS.map do |row|
        pk = row.fetch('pk')
        payload = row.fetch('doc').fetch('payload', nil)
        type = payload.nil? ? 'NULL' : OUTER_ACTUAL_TYPE
        {'pk' => pk, 'type' => type, 'wrapper_type' => DYNAMIC_PATH_CARRIER, 'value' => payload}
      end
      # The logical projection is common to both roles; only the nested typed
      # descriptor changes. Its values are identical by construction.
      expected
    end

    def nested_value_projection(witnesses)
      witnesses.map do |row|
        {
          'pk' => row.fetch('pk'),
          'state' => row.fetch('items_state'),
          'items' => row.fetch('nested_items').map do |item|
            {'index' => item.fetch('index'), 'v_value' => item.fetch('v_value')}
          end,
        }
      end
    end

    def nested_type_projection(witnesses, role)
      witnesses.map do |row|
        {'pk' => row.fetch('pk'), 'v_types' => row.fetch('nested_items').map { LEAF_VALUE_TYPES.fetch(role) }}
      end
    end

    LEAF_VALUE_TYPES = {'normal' => 'UInt8', 'type_only' => 'Int64'}.freeze

    def validate_nested_witnesses!(witnesses, role, id)
      require_true(witnesses.is_a?(Array) && witnesses.size == ROW_COUNT,
                   "#{id}/#{role} nested witness row count differs")
      witnesses.each_with_index do |row, index|
        pk = index + 1
        exact_keys!(row, %w[
          pk payload_state payload_actual_type parent_json_type parent_v_type parent_v items_state
          items_actual_type leaf_json_type nested_path nested_items
        ], "#{id}/#{role}/pk#{pk} nested witness")
        expected_doc = EXPECTED_DOCS.fetch(index).fetch('doc')
        payload = expected_doc.fetch('payload', nil)
        items = ITEMS_BY_PK.fetch(pk)
        expected_items_state = if [4, 6].include?(pk)
                                 'missing_payload'
                               elsif pk == 3
                                 'absent'
                               elsif items.empty?
                                 'empty'
                               else
                                 'populated'
                               end
        expected_nested = (items || []).each_with_index.map do |item, item_index|
          value = item.fetch('v')
          {'index' => item_index, 'actual_type' => LEAF_JSON_TYPES.fetch(role),
           'paths_types' => {'v' => LEAF_VALUE_TYPES.fetch(role)},
           'v_type' => LEAF_VALUE_TYPES.fetch(role), 'v_value' => value}
        end
        require_true(row.fetch('pk') == pk && row.fetch('payload_state') == (payload.nil? ? 'missing' : 'value') &&
                     row.fetch('payload_actual_type') == (payload.nil? ? 'MISSING' : OUTER_ACTUAL_TYPE) &&
                     row.fetch('parent_json_type') == PARENT_JSON_TYPE && row.fetch('parent_v_type') == 'UInt8' &&
                     row.fetch('parent_v') == (payload.nil? ? nil : 42) &&
                     row.fetch('items_state') == expected_items_state &&
                     row.fetch('items_actual_type') == ([4, 6, 3].include?(pk) ? 'MISSING' : ITEM_ARRAY_TYPES.fetch(role)) &&
                     row.fetch('leaf_json_type') == LEAF_JSON_TYPES.fetch(role) &&
                     row.fetch('nested_path') == 'payload.1.items[]' && row.fetch('nested_items') == expected_nested,
                     "#{id}/#{role} nested descriptor/value witness differs at pk #{pk}")
      end
      last = witnesses.last
      require_true(last.fetch('pk') == 8 && last.fetch('items_state') == 'populated' &&
                   last.fetch('nested_items').size == 1 && last.fetch('nested_items').first.fetch('v_value') == 77,
                   "#{id}/#{role} last-real-mark descendant witness differs")
      true
    rescue KeyError, TypeError => error
      raise Failure, "#{id}/#{role} nested witness is malformed: #{error.class}: #{error.message}"
    end

    def validate_windows!(windows, role, id)
      require_true(windows.is_a?(Array) && windows.size == 8, "#{id}/#{role} bounded-window count differs")
      expected_roster = WINDOWS.flat_map do |window, spec|
        [['whole_object', nil, window, spec], ['selected_path', 'payload', window, spec]]
      end
      windows.each_with_index do |row, index|
        consumer, path, window, spec = expected_roster.fetch(index)
        exact_keys!(row, %w[
          consumer path window first_mark mark_count expected_mark_row_counts actual_mark_row_counts
          expected_rows actual_rows matches_full_slice
        ], "#{id}/#{role} bounded window #{index}")
        pks = spec.fetch(:pks)
        rows = if consumer == 'whole_object'
                 EXPECTED_DOCS.select { |entry| pks.include?(entry.fetch('pk')) }
               else
                 expected_direct_rows(role).select { |entry| pks.include?(entry.fetch('pk')) }
               end
        counts = (0...spec.fetch(:mark_count)).map { |offset| MARK_ROWS.fetch(spec.fetch(:first_mark) + offset) }
        require_true(row.fetch('consumer') == consumer && row.fetch('path') == path &&
                     row.fetch('window') == window && row.fetch('first_mark') == spec.fetch(:first_mark) &&
                     row.fetch('mark_count') == spec.fetch(:mark_count) &&
                     row.fetch('expected_mark_row_counts') == counts && row.fetch('actual_mark_row_counts') == counts &&
                     row.fetch('expected_rows') == rows && row.fetch('actual_rows') == rows &&
                     row.fetch('matches_full_slice') == true,
                     "#{id}/#{role} bounded #{consumer}/#{window} witness differs")
      end
      true
    rescue KeyError, TypeError => error
      raise Failure, "#{id}/#{role} bounded windows are malformed: #{error.class}: #{error.message}"
    end

    def authenticate_part_inventory!(path, inventory, id, role)
      require_true(inventory.is_a?(Array) && inventory.size <= 4096, "#{id}/#{role} file inventory is malformed")
      expected = {}
      inventory.each do |entry|
        exact_keys!(entry, %w[name size sha256], "#{id}/#{role} inventory entry")
        name = entry.fetch('name')
        require_true(name.is_a?(String) && name.match?(/\A[a-zA-Z0-9_.-]+\z/) && !expected.key?(name),
                     "#{id}/#{role} inventory contains an unsafe or duplicate filename")
        size = entry.fetch('size')
        sha = entry.fetch('sha256')
        require_true(size.is_a?(Integer) && size >= 0 && size <= MAX_PART_FILE_BYTES &&
                     sha.is_a?(String) && sha.match?(/\A[0-9a-f]{64}\z/),
                     "#{id}/#{role}/#{name} inventory size/hash is malformed")
        expected[name] = [size, sha]
      end
      names = Dir.children(path).sort
      require_true(names == expected.keys.sort, "#{id}/#{role} physical file roster differs from its hash inventory")
      total = 0
      actual = {}
      names.each do |name|
        file = File.join(path, name)
        require_true(File.file?(file) && !File.symlink?(file), "#{id}/#{role}/#{name} is not a regular file")
        size = File.size(file)
        require_true(size <= MAX_PART_FILE_BYTES, "#{id}/#{role}/#{name} exceeds the file-size limit")
        total += size
        require_true(total <= MAX_PART_TOTAL_BYTES, "#{id}/#{role} exceeds the part-size limit")
        bytes = read_bounded(file, MAX_PART_FILE_BYTES, "#{id}/#{role}/#{name}")
        digest = Digest::SHA256.hexdigest(bytes)
        require_true([size, digest] == expected.fetch(name), "#{id}/#{role}/#{name} differs from the helper inventory")
        actual[name] = [size, digest]
      end
      tree = W241::W185::Probe.allocate
      tree.send(:validate_plain_tree!, path)
      {
        inventory: actual,
        snapshot: actual.map { |name, (size, sha)| [name, size, sha] }.sort,
      }
    rescue KeyError, TypeError => error
      raise Failure, "#{id}/#{role} physical inventory is malformed: #{error.class}: #{error.message}"
    end

    def validate_part_metadata!(path, profile, part, id, role)
      names = Dir.children(path).sort
      required = %w[checksums.txt columns.txt columns_substreams.txt count.txt default_compression_codec.txt metadata_version.txt primary.idx serialization.json]
      require_true((required - names).empty?, "#{id}/#{role} misses required part metadata")
      stream_names = part.fetch('physical_stream_names')
      require_true(stream_names.is_a?(Array) && !stream_names.empty? && stream_names.uniq == stream_names.sort,
                   "#{id}/#{role} physical stream list is not sorted/unique")
      roles = parse_columns_substreams(read_bounded(File.join(path, 'columns_substreams.txt'), 256 * 1024,
                                                     "#{id}/#{role} columns_substreams.txt"))
      require_true(roles.fetch('pk') == ['pk'] && roles.fetch('doc').sort == stream_names,
                   "#{id}/#{role} physical doc/pk substream owners differ")
      allowed_nonstream = required + (names.include?('txn_version.txt') ? ['txn_version.txt'] : [])
      expected_stream_files = stream_file_names(roles.values.flatten)
      expected_names = (allowed_nonstream + expected_stream_files).uniq.sort
      require_true(names == expected_names,
                   "#{id}/#{role} complete physical role roster differs")
      require_true(File.read(File.join(path, 'count.txt')).strip == ROW_COUNT.to_s,
                   "#{id}/#{role} count.txt differs")
      require_true(File.read(File.join(path, 'default_compression_codec.txt')).strip == 'CODEC(LZ4)',
                   "#{id}/#{role} default codec differs")
      require_true(File.read(File.join(path, 'metadata_version.txt')).strip == '0',
                   "#{id}/#{role} metadata version differs")
      serialization_bytes = read_bounded(File.join(path, 'serialization.json'), 1024 * 1024,
                                         "#{id}/#{role} serialization.json")
      serialization = W242.parse_evidence_json!(serialization_bytes, "#{id}/#{role} serialization.json")
      require_true(serialization.fetch('version') == 1 &&
                   serialization.fetch('types_serialization_versions').fetch('string') ==
                     (profile.fetch(:string).fetch(:id) == 's0' ? 0 : 1),
                   "#{id}/#{role} actual String serialization metadata differs")
      {
        doc_streams: stream_names,
        table_streams: ['pk'] + roles.fetch('doc').sort,
        serialization_json_sha256: Digest::SHA256.hexdigest(serialization_bytes),
      }
    rescue KeyError, TypeError => error
      raise Failure, "#{id}/#{role} physical metadata is malformed: #{error.class}: #{error.message}"
    end

    def parse_columns_substreams(bytes)
      lines = bytes.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      require_true(lines.size >= 2 && lines[0] == 'columns substreams version: 1' && lines[1] == '2 columns:',
                   'columns_substreams header differs')
      cursor = 2
      output = {}
      2.times do
        header = lines.fetch(cursor)
        cursor += 1
        match = /\A(\d+) substreams for column `([^`]+)`:\z/.match(header)
        require_true(match, 'columns_substreams column header is malformed')
        count = Integer(match[1], 10)
        column = match[2]
        require_true(count.positive? && %w[pk doc].include?(column) && !output.key?(column),
                     'columns_substreams has an unknown, empty, or duplicate column role')
        stream_names = []
        count.times do
          stream_line = lines.fetch(cursor)
          cursor += 1
          require_true(stream_line.start_with?("\t") && stream_line.bytesize > 1,
                       'columns_substreams stream line is malformed')
          stream = stream_line[1..-1]
          stream = stream.sub(/\A\*\s*/, '')
          require_true(!stream.empty? && !stream_names.include?(stream),
                       'columns_substreams has an empty or duplicate stream role')
          stream_names << stream
        end
        output[column] = stream_names
      end
      require_true(cursor == lines.size && output.keys.sort == %w[doc pk],
                   'columns_substreams has trailing or missing column records')
      output
    rescue IndexError, ArgumentError
      raise Failure, 'columns_substreams is truncated or has an invalid count'
    end

    def stream_file_names(stream_names)
      stream_names.flat_map do |name|
        stem = W241::Auditor.stream_hash(name)
        ["#{stem}.bin", "#{stem}.mrk2"]
      end
    end

    def create_native_tables!
      store = File.join(@root, 'stores', 'native')
      statements = []
      table_names = []
      @parts.each do |part|
        profile = part.fetch(:profile)
        id = profile.fetch(:id)
        role = part.fetch(:role)
        table = table_name(id, role)
        part[:table] = table
        @tables[[id, role]] = table
        statements << "CREATE TABLE default.#{table} (pk UInt64, doc #{STOCK_TYPE}) ENGINE=MergeTree ORDER BY pk SETTINGS #{@runner.send(:settings, profile)};"
        table_names << @runner.send(:sql_string, table)
      end
      statements << "SELECT '#{PATH_TAG}', database, name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name IN (#{table_names.join(',')}) ORDER BY name FORMAT TSVRaw;"
      invocation = native_stage('native_create_tables', store, statements.join("\n"))
      require_process_success!(invocation, 'native table creation')
      rows = tagged_rows(invocation.fetch(:stdout), PATH_TAG, 4)
      require_true(rows.size == @parts.size, 'native target table path row count differs')
      paths = {}
      rows.each do |row|
        database, table, raw_path = row.values_at(1, 2, 3)
        require_true(database == 'default' && @tables.values.include?(table) && !paths.key?(table),
                     'native target table path identity is unknown or duplicated')
        paths[table] = @runner.send(:validate_store_path!, raw_path)
      end
      require_true(paths.keys.sort == @tables.values.sort, 'native target table path roster differs')
      @parts.each do |part|
        data_path = paths.fetch(part.fetch(:table))
        @runner.send(:attach_part!, part.fetch(:path), data_path)
        destination = File.join(data_path, 'detached', 'all_1_1_0')
        part[:copied_path] = destination
        part[:copied_snapshot] = part_snapshot(destination)
        require_true(part[:copied_snapshot] == part.fetch(:source_snapshot),
                     "#{part_label(part)} copied bytes differ from generated source")
        part[:data_path] = data_path
      end
      @create_record = invocation.fetch(:record)
      true
    end

    def attach_and_check_parts!
      statements = []
      @parts.each do |part|
        id = part.fetch(:profile).fetch(:id)
        role = part.fetch(:role)
        table = part.fetch(:table)
        statements << "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0';"
        statements << "SELECT '#{CHECK_BEGIN_TAG}', '#{id}', '#{role}' FORMAT TSVRaw;"
        statements << "CHECK TABLE default.#{table} FORMAT TSV;"
        statements << "SELECT '#{CHECK_END_TAG}', '#{id}', '#{role}' FORMAT TSVRaw;"
        statements << "SELECT '#{SCHEMA_TAG}', '#{id}', '#{role}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;"
        statements << "SELECT '#{PART_TAG}', '#{id}', '#{role}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;"
      end
      invocation = native_stage('native_attach_check', File.join(@root, 'stores', 'native'), statements.join("\n"))
      require_process_success!(invocation, 'native ATTACH/CHECK')
      @parts.each { |part| validate_attached_part!(invocation.fetch(:stdout), part) }
      @attach_record = invocation.fetch(:record)
      true
    end

    def validate_attached_part!(stdout, part)
      id = part.fetch(:profile).fetch(:id)
      role = part.fetch(:role)
      table = part.fetch(:table)
      checks = check_rows_between(stdout, id, role)
      require_true(checks == ["all_1_1_0\t1\t"], "#{part_label(part)} native CHECK result differs")
      schemas = tagged_rows(stdout, SCHEMA_TAG, 5).select { |row| row[1] == id && row[2] == role }
      require_true(schemas.map { |row| row.drop(3) } == [['pk', 'UInt64'], ['doc', STOCK_TYPE]],
                   "#{part_label(part)} attached native schema differs")
      rows = tagged_rows(stdout, PART_TAG, 9).select { |row| row[1] == id && row[2] == role }
      require_true(rows.size == 1 && rows.first.values_at(3, 4, 6, 7, 8) ==
                   [table, 'all_1_1_0', 'Wide', ROW_COUNT.to_s, PHYSICAL_MARKS.to_s],
                   "#{part_label(part)} attached Wide part identity/rows/marks differs")
      attached_path = @runner.send(:validate_store_path!, rows.first.fetch(5))
      require_true(attached_snapshot_matches?(part.fetch(:copied_snapshot), attached_path),
                   "#{part_label(part)} ATTACH modified copied part files beyond the exact native metadata exception")
      part[:attached_path] = attached_path
      part[:attached_snapshot] = part_snapshot(attached_path)
      true
    end

    def capture_direct_oracles!
      @profiles.each do |profile_record|
        profile = profile_for(profile_record.fetch(:id))
        id = profile.fetch(:id)
        statements = []
        %w[normal type_only].each do |role|
          table = @tables.fetch([id, role])
          statements << direct_rows_sql(table, id, role)
          statements << nested_rows_sql(table, id, role)
          statements << child_rows_sql(table, id, role)
        end
        invocation = native_stage("native_direct_#{id}", File.join(@root, 'stores', 'native'), statements.join("\n"))
        require_process_success!(invocation, "#{id} separate direct-only native queries")
        observations = validate_direct_output!(invocation.fetch(:stdout), id)
        profile_record[:native_direct] = {invocation: invocation.fetch(:record), observations: observations}
      end
      true
    end

    def direct_rows_sql(table, id, role)
      payload = 'doc.payload'
      "SELECT '#{DIRECT_TAG}', '#{id}', '#{role}', toString(pk), toTypeName(#{payload}), " \
        "if(isNull(#{payload}), 'NULL', dynamicType(#{payload})), " \
        "if(isNull(#{payload}), '6e756c6c', hex(toJSONString(#{payload}))) " \
        "FROM default.#{table} ORDER BY pk FORMAT TSVRaw;"
    end

    def nested_rows_sql(table, id, role)
      tuple_value = "assumeNotNull(dynamicElement(doc.payload, #{@runner.send(:sql_string, OUTER_ACTUAL_TYPE)}))"
      parent = "tupleElement(#{tuple_value}, 1)"
      items = "#{parent}.items"
      array_type = ITEM_ARRAY_TYPES.fetch(role)
      items_json = "dynamicElement(#{items}, #{@runner.send(:sql_string, array_type)})"
      "SELECT '#{NESTED_TAG}', '#{id}', '#{role}', toString(pk), " \
        "toTypeName(doc.payload), dynamicType(doc.payload), toTypeName(#{tuple_value}), " \
        "toTypeName(#{parent}), hex(toJSONString(JSONAllPathsWithTypes(#{parent}))), " \
        "toTypeName(#{parent}.v), toString(#{parent}.v), toTypeName(#{items}), " \
        "if(isNull(#{items}), 'NULL', dynamicType(#{items})), " \
        "if(isNull(#{items}), '6e756c6c', hex(toJSONString(#{items_json}))) " \
        "FROM default.#{table} WHERE isNotNull(doc.payload) ORDER BY pk FORMAT TSVRaw;"
    end

    def child_rows_sql(table, id, role)
      tuple_value = "assumeNotNull(dynamicElement(doc.payload, #{@runner.send(:sql_string, OUTER_ACTUAL_TYPE)}))"
      parent = "tupleElement(#{tuple_value}, 1)"
      array_type = ITEM_ARRAY_TYPES.fetch(role)
      item_array = "assumeNotNull(dynamicElement(parent.items, #{@runner.send(:sql_string, array_type)}))"
      "SELECT '#{CHILD_TAG}', '#{id}', '#{role}', toString(pk), toString(item_index), " \
        "toTypeName(parent.items), dynamicType(parent.items), toTypeName(item), " \
        "hex(toJSONString(JSONAllPathsWithTypes(item))), toTypeName(item.v), toString(item.v), " \
        "hex(toJSONString(item)) FROM (" \
        "SELECT pk, #{parent} AS parent FROM default.#{table} WHERE pk IN (1, 5, 8)" \
        ") AS nested ARRAY JOIN arrayEnumerate(#{item_array}) AS item_index, #{item_array} AS item " \
        "ORDER BY pk, item_index FORMAT TSVRaw;"
    end

    def validate_direct_output!(stdout, id)
      direct = tagged_rows(stdout, DIRECT_TAG, 7)
      nested = tagged_rows(stdout, NESTED_TAG, 14)
      children = tagged_rows(stdout, CHILD_TAG, 12)
      require_true(direct.size == 16 && nested.size == 12 && children.size == 8,
                   "#{id} direct native result row counts differ")
      roles = %w[normal type_only]
      direct_by_role = {}
      nested_by_role = {}
      children_by_role = {}
      roles.each do |role|
        part = @parts.find { |item| item.fetch(:profile).fetch(:id) == id && item.fetch(:role) == role }
        require_true(part, "#{id}/#{role} helper part is absent during direct audit")
        direct_rows = direct.select { |row| row[1] == id && row[2] == role }
        nested_rows = nested.select { |row| row[1] == id && row[2] == role }
        child_rows = children.select { |row| row[1] == id && row[2] == role }
        require_true(direct_rows.map { |row| Integer(row[3], 10) } == (1..ROW_COUNT).to_a,
                     "#{id}/#{role} direct native row key domain differs")
        require_true(nested_rows.map { |row| Integer(row[3], 10) } == [1, 2, 3, 5, 7, 8],
                     "#{id}/#{role} nested native row key domain differs")
        validate_direct_path_rows!(direct_rows, id, role)
        validate_nested_native_rows!(nested_rows, id, role)
        validate_child_native_rows!(child_rows, id, role)
        direct_by_role[role] = direct_rows.size
        nested_by_role[role] = nested_rows.size
        children_by_role[role] = child_rows.size
      end
      {
        path_rows: direct_by_role.values.inject(0, :+),
        nested_type_rows: nested_by_role.values.inject(0, :+),
        child_rows: children_by_role.values.inject(0, :+),
        direct_sql_has_no_full_doc_expression: true,
        nested_type_witness_is_native_dynamic_type_and_json_path_roster: true,
      }
    rescue KeyError, ArgumentError, TypeError => error
      raise Failure, "#{id} direct native output is malformed: #{error.class}: #{error.message}"
    end

    def validate_direct_path_rows!(rows, id, role)
      rows.each do |row|
        pk = Integer(row.fetch(3), 10)
        payload = expected_payload(pk)
        actual_type = payload.nil? ? 'NULL' : OUTER_ACTUAL_TYPE
        actual_value = row[6] == '6e756c6c' ? nil : parse_hex_json(row[6], "#{id}/#{role}/pk#{pk} payload")
        require_true(row[4] == NATIVE_PATH_WRAPPER && row[5] == actual_type && actual_value == payload,
                     "#{id}/#{role} native direct payload type/value differs at pk #{pk}")
      end
    end

    def validate_nested_native_rows!(rows, id, role)
      leaf_type = role == 'normal' ? 'UInt8' : 'Int64'
      array_type = ITEM_ARRAY_TYPES.fetch(role)
      rows.each do |row|
        pk = Integer(row.fetch(3), 10)
        parent_expected = expected_parent(pk)
        expected_items = ITEMS_BY_PK.fetch(pk)
        expected_paths = {'v' => 'UInt8'}
        # JSONAllPathsWithTypes reports the actual Array(JSON) arm recorded
        # for this Dynamic path; toTypeName(parent.items) below separately
        # witnesses the declared Dynamic(max_types=2) wrapper.
        expected_paths['items'] = array_type unless expected_items.nil?
        items_actual = expected_items.nil? ? 'NULL' : array_type
        encoded_items = row[13] == '6e756c6c' ? nil : parse_hex_json(row[13], "#{id}/#{role}/pk#{pk} nested items")
        expected_type_value = expected_items.nil? ? nil : expected_items
        require_true(row[4] == NATIVE_PATH_WRAPPER && row[5] == OUTER_ACTUAL_TYPE &&
                     row[6] == OUTER_ACTUAL_TYPE && row[7] == PARENT_JSON_TYPE &&
                     parse_hex_json(row[8], "#{id}/#{role}/pk#{pk} parent JSON types") == expected_paths &&
                     row[9] == 'UInt8' && Integer(row[10], 10) == 42 &&
                     row[11] == PARENT_ITEMS_TYPE && row[12] == items_actual &&
                     encoded_items == expected_type_value && parent_expected['v'] == 42,
                     "#{id}/#{role} native nested descriptor/value differs at pk #{pk}")
      end
    end

    def validate_child_native_rows!(rows, id, role)
      leaf_type = role == 'normal' ? 'UInt8' : 'Int64'
      array_type = ITEM_ARRAY_TYPES.fetch(role)
      leaf_json_type = LEAF_JSON_TYPES.fetch(role)
      expected = [[1, 1, 7], [1, 2, 8], [5, 1, 7], [8, 1, 77]]
      actual_keys = rows.map { |row| [Integer(row[3], 10), Integer(row[4], 10)] }
      require_true(actual_keys == expected.map { |pk, index, _value| [pk, index] },
                   "#{id}/#{role} native nonempty descendant child key domain differs")
      rows.zip(expected).each do |row, (pk, index, value)|
        item = {'v' => value}
        require_true(row[5] == PARENT_ITEMS_TYPE && row[6] == array_type && row[7] == leaf_json_type &&
                     parse_hex_json(row[8], "#{id}/#{role}/pk#{pk}/item#{index} JSON paths") == {'v' => leaf_type} &&
                     row[9] == leaf_type && Integer(row[10], 10) == value &&
                     parse_hex_json(row[11], "#{id}/#{role}/pk#{pk}/item#{index} JSON value") == item,
                     "#{id}/#{role} native descendant Array(JSON) type/value differs at pk#{pk}/item#{index}")
      end
    end

    def capture_full_oracles!
      @profiles.each do |profile_record|
        id = profile_record.fetch(:id)
        statements = %w[normal type_only].map do |role|
          table = @tables.fetch([id, role])
          "SELECT '#{FULL_TAG}', '#{id}', '#{role}', toString(pk), toTypeName(doc), " \
            "hex(toJSONString(doc)) FROM default.#{table} ORDER BY pk FORMAT TSVRaw;"
        end
        invocation = native_stage("native_full_#{id}", File.join(@root, 'stores', 'native'), statements.join("\n"))
        require_process_success!(invocation, "#{id} separate full-Object native query")
        observation = validate_full_output!(invocation.fetch(:stdout), id)
        profile_record[:native_full] = {invocation: invocation.fetch(:record), observations: observation}
      end
      true
    end

    def validate_full_output!(stdout, id)
      rows = tagged_rows(stdout, FULL_TAG, 6)
      require_true(rows.size == 16, "#{id} native full-Object row count differs")
      %w[normal type_only].each do |role|
        part_rows = rows.select { |row| row[1] == id && row[2] == role }
        require_true(part_rows.map { |row| Integer(row[3], 10) } == (1..ROW_COUNT).to_a,
                     "#{id}/#{role} native full row domain differs")
        part_rows.each do |row|
          pk = Integer(row[3], 10)
          doc = parse_hex_json(row[5], "#{id}/#{role}/pk#{pk} full document")
          require_true(row[4] == STOCK_TYPE && doc == EXPECTED_DOCS.fetch(pk - 1).fetch('doc'),
                       "#{id}/#{role} separate native full-Object type/value differs at pk #{pk}")
        end
      end
      {
        rows: rows.size,
        document_type: STOCK_TYPE,
        full_query_contains_no_direct_descendant_projection: true,
      }
    rescue KeyError, ArgumentError, TypeError => error
      raise Failure, "#{id} full native output is malformed: #{error.class}: #{error.message}"
    end

    def native_stage(label, store, sql)
      @last_stage = label
      envelope = [@runner.send(:pin_sql), 'SET print_pretty_type_names=0;',
                  'SET output_format_json_quote_64bit_integers=0;', sql].join("\n")
      observation = @runner.send(:native, label, store, envelope)
      record = observation.fetch(:record)
      require_true(record.fetch(:binary_sha_before) == W241::BINARY_SHA256 &&
                   record.fetch(:binary_sha_after) == W241::BINARY_SHA256,
                   "#{label} did not preserve the exact pinned runtime identity")
      observation
    end

    def require_process_success!(invocation, label)
      @runner.send(:assert_native_success!, invocation, label) if invocation.fetch(:record).fetch(:process_kind) == 'clickhouse-local'
      if invocation.fetch(:record).fetch(:process_kind) != 'clickhouse-local'
        record = invocation.fetch(:record)
        require_true(invocation.fetch(:classification) == 'success' && invocation.fetch(:status)&.success? &&
                     invocation.fetch(:stderr).empty? && record.fetch(:binary_sha_after) == record.fetch(:expected_binary_sha256),
                     "#{label} did not exit cleanly: #{record.inspect}")
      end
      @runner.send(:assert_pin!, invocation.fetch(:stdout), label) if invocation.fetch(:record).fetch(:process_kind) == 'clickhouse-local'
      true
    end

    def tagged_rows(stdout, tag, width)
      rows = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp).map do |line|
        next unless line.start_with?(tag + "\t")
        fields = line.split("\t", -1)
        require_true(fields.size == width && fields[0] == tag, "malformed #{tag} marker row")
        fields
      end.compact
      rows
    end

    def check_rows_between(stdout, id, role)
      begin_line = "#{CHECK_BEGIN_TAG}\t#{id}\t#{role}"
      end_line = "#{CHECK_END_TAG}\t#{id}\t#{role}"
      active = false
      rows = []
      stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp).each do |line|
        if line == begin_line
          require_true(!active, 'nested native CHECK interval')
          active = true
        elsif line == end_line
          require_true(active, 'native CHECK end without matching begin')
          active = false
        elsif active
          rows << line
        end
      end
      require_true(!active, 'unterminated native CHECK interval')
      rows
    end

    def parse_hex_json(value, label)
      require_true(value.is_a?(String) && value.match?(/\A(?:[0-9a-fA-F]{2})*\z/), "#{label} has malformed hex JSON")
      W242.parse_evidence_json!([value].pack('H*'), label)
    rescue W242::Failure => error
      raise Failure, error.message
    end

    def expected_payload(pk)
      EXPECTED_DOCS.fetch(pk - 1).fetch('doc').fetch('payload', nil)
    end

    def expected_parent(pk)
      payload = expected_payload(pk)
      payload ? {'v' => 42}.merge(payload.fetch(0)) : {}
    end

    def table_name(id, role)
      require_true(W241::PROFILE_IDS.include?(id) && %w[normal type_only].include?(role), 'unrostered table identity')
      "w243_#{@token}_#{id}_#{role}"
    end

    def profile_for(id)
      W241::PROFILES.find { |profile| profile.fetch(:id) == id } || raise(Failure, "unknown profile #{id.inspect}")
    end

    def part_label(part)
      "#{part.fetch(:profile).fetch(:id)}/#{part.fetch(:role)}"
    end

    def part_snapshot(path)
      require_true(File.directory?(path) && !File.symlink?(path), "part is absent or symlinked: #{path}")
      entries = []
      total = 0
      Find.find(path) do |entry|
        stat = File.lstat(entry)
        require_true(!stat.symlink? && (stat.directory? || stat.file?), "part contains a symlink/special file: #{entry}")
        next if stat.directory?
        require_true(stat.size <= MAX_PART_FILE_BYTES, "part file exceeds bound: #{entry}")
        total += stat.size
        require_true(total <= MAX_PART_TOTAL_BYTES, 'part exceeds total byte bound')
        entries << [entry.delete_prefix(path + File::SEPARATOR), stat.size, Digest::SHA256.file(entry).hexdigest]
      end
      entries.sort
    end

    def attached_snapshot_matches?(copied_snapshot, attached_path)
      copied = copied_snapshot.each_with_object({}) { |(name, size, sha), result| result[name] = [size, sha] }
      attached_snapshot = part_snapshot(attached_path)
      attached = attached_snapshot.each_with_object({}) { |(name, size, sha), result| result[name] = [size, sha] }
      extra_name = 'invalidated_system_columns.txt'
      extra_bytes = "_block_offset\n_block_number\n".b
      require_true(!copied.key?(extra_name) && (attached.keys - copied.keys) == [extra_name] &&
                   (copied.keys - attached.keys).empty?, 'native ATTACH file roster differs from source plus admitted metadata')
      copied.each { |name, info| require_true(attached.fetch(name) == info, "ATTACH modified original file #{name}") }
      bytes = read_bounded(File.join(attached_path, extra_name), 1024, 'native invalidation metadata')
      bytes == extra_bytes
    end

    def assert_unchanged_parts!
      @parts.each do |part|
        require_true(part_snapshot(part.fetch(:path)) == part.fetch(:source_snapshot),
                     "#{part_label(part)} generated source part changed after capture")
        require_true(part_snapshot(part.fetch(:attached_path)) == part.fetch(:attached_snapshot),
                     "#{part_label(part)} attached part changed after native read")
      end
      true
    end

    def write_summary(status, fatal_error)
      return unless @root && File.directory?(@root)
      summary = {
        format: FORMAT,
        status: status,
        fatal_error: fatal_error,
        scope: 'library_written_native_read_only; no stock-authored W243 part is covered',
        frame_bytes: @frame_bytes,
        runtime: {path: @binary, sha256: W241::BINARY_SHA256,
                  version: W241::VERSION, build: W241::BUILD,
                  sha256_before: @runtime_sha_before, sha256_after: @runtime_sha_after},
        helper: {path: @helper, sha256_before: @helper_sha_before, sha256_after: @helper_sha_after,
                 source_path: HELPER_SOURCE, source_sha256_expected: HELPER_SOURCE_SHA256,
                 source_sha256_before: @helper_source_sha_before, source_sha256_after: @helper_source_sha_after,
                 input_sha256: @helper_input_sha256, output_sha256: @helper_output_sha256,
                 invocation: @helper_record},
        limits: {max_threads: 1, local_max_memory_usage_bytes: W241::MEMORY,
                 outer_run_safe_memory_limit_bytes: W241::OUTER_RUN_SAFE_LIMIT,
                 timeout_seconds: W241::TIMEOUT, termination_grace_seconds: W241::GRACE},
        profiles: @profiles,
        parts: @parts.map do |part|
          {
            id: part.fetch(:profile).fetch(:id), role: part.fetch(:role),
            shared_version: part.fetch(:profile).fetch(:layout).fetch(:enum),
            string_profile: part.fetch(:profile).fetch(:string).fetch(:id),
            table: part[:table], path: part.fetch(:path), data_path: part[:data_path],
            attached_path: part[:attached_path], part_metadata: part[:part_metadata],
            source_snapshot: part[:source_snapshot], copied_snapshot: part[:copied_snapshot],
            attached_snapshot: part[:attached_snapshot],
          }
        end,
        invocations: @invocations,
        last_stage: @last_stage,
        evidence_root: @root,
        interpretation: {
          'generated_part_direction' => 'All 16 parts are generated by the pinned Crystal helper, then independently inventoried, attached, CHECKed, and read by fresh pinned native processes. This does not claim reciprocal stock-authored W243 part coverage.',
          'direct_native' => 'Fresh direct-only SELECTs project doc.payload, its nested parent JSON metadata, and every populated descendant Array(JSON) element; no full doc expression occurs in these SELECTs.',
          'full_native' => 'Separate fresh full-Object SELECTs read doc and compare exact fixture values. They do not provide the direct nested type proof.',
          'physical_windows' => 'The Crystal helper reads four real-mark windows. Native pk predicates are not represented as physical mark-window evidence; the fifth zero-row mark is only the physical terminal sentinel.',
          'type_discriminator' => 'Normal/type_only parts preserve the same JSON values while changing only the nested grandchild v type UInt8 versus Int64. Native nested toTypeName and JSONAllPathsWithTypes are asserted separately from JSON value equality.',
          'failure_policy' => 'Any spawn, timeout, process, SQL, schema, inventory, CHECK, direct, or full assertion failure is inconclusive, never a native format-refusal proof.',
        },
      }
      path = File.join(@root, 'summary.json')
      return if File.exist?(path) || File.symlink?(path)
      write_new(path, JSON.pretty_generate(summary) + "\n")
    end
  end
end

def main
  options = {binary: ProbeObjectDescendantJSONW243::W241::BINARY, frame_bytes: 32}
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/probe_object_descendant_json_w243.rb --evidence-root EMPTY_CHILD_OF_PRIVATE_TMP --crystal-helper EXECUTABLE [--clickhouse PATH] [--frame-bytes 32|64]'
    parser.on('--clickhouse PATH') { |value| options[:binary] = value }
    parser.on('--crystal-helper PATH') { |value| options[:helper] = value }
    parser.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
    parser.on('--frame-bytes N', Integer) { |value| options[:frame_bytes] = value }
  end.parse!
  raise 'evidence root is required via --evidence-root' unless options[:evidence_root]
  raise 'prebuilt W243 Crystal helper is required via --crystal-helper' unless options[:helper]
  unless ProbeObjectDescendantJSONW243::FRAME_BYTES_OPTIONS.include?(options[:frame_bytes])
    warn '--frame-bytes must be exactly 32 or 64'
    exit 64
  end
  exit(ProbeObjectDescendantJSONW243::Probe.new(options[:binary], options[:helper], options[:evidence_root], options[:frame_bytes]).run ? 0 : 1)
end

main if $PROGRAM_NAME == __FILE__
