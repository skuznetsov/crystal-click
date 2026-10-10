#!/usr/bin/env ruby
# Offline W245 auditor. It authenticates raw process artifacts and independently
# re-reads the generated, retained pre-attach, and active part trees; it never
# starts ClickHouse or modifies the evidence root.

require 'digest'
require 'find'
require 'json'
require 'optparse'
require_relative 'probe_object_shared_json_interop_w241'

module AuditSchemaWidePartW245
  W241 = ProbeObjectSharedJSONInteropW241
  FORMAT = 'schema_wide_part_w245_native_capture_v1'.freeze
  HELPER_FORMAT = 'schema_wide_part_w245_fixture_v1'.freeze
  PART_NAME = 'all_1_1_0'.freeze
  FRAME_BYTES = 32
  ROW_COUNT = 5
  MARK_ROWS = [2, 2, 1].freeze
  MARK_ROWS_WITH_EOF = [2, 2, 1, 0].freeze
  KEY = {'name' => 'pk', 'type' => 'UInt64'}.freeze
  VALUE_COLUMNS = [
    {'name' => 'state', 'type' => 'Tuple(label LowCardinality(String), total AggregateFunction(sum, UInt8))'},
    {'name' => 'dyn', 'type' => 'Dynamic(max_types=1)'},
    {'name' => 'object', 'type' => 'JSON(max_dynamic_types=1, max_dynamic_paths=1, label String)'},
    {'name' => 'recursive', 'type' => 'Array(Tuple(doc JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8), sample Dynamic(max_types=1)))'},
  ].map(&:freeze).freeze
  SCHEMA = ([KEY] + VALUE_COLUMNS).freeze
  EXPECTED_SUMS = [0, 42, 200, 255, 1000].freeze
  EXPECTED_LABELS = %w[red red blue red blue].freeze
  EXPECTED_DYN = [
    {'kind' => 'uint64', 'value' => 7}, {'kind' => 'string', 'value' => 'spill'}, {'kind' => 'null'},
    {'kind' => 'uint64', 'value' => 42}, {'kind' => 'string', 'value' => 'tail-spill'},
  ].freeze
  EXPECTED_SHAPES = [
    {'kind' => 'uint64', 'value' => 7}, {'kind' => 'string', 'value' => 'spill'}, {'kind' => 'null'},
    {'kind' => 'uint64', 'value' => 42}, {'kind' => 'string', 'value' => 'object-spill'},
  ].freeze
  EXPECTED_CHILDREN = [
    [], [],
    [{'doc' => {'t' => 31}, 'sample' => {'kind' => 'uint64', 'value' => 7}}],
    [{'doc' => {'t' => 41}, 'sample' => {'kind' => 'string', 'value' => 'recursive-spill'}}],
    [{'doc' => {'t' => 51}, 'sample' => {'kind' => 'uint64', 'value' => 42}},
     {'doc' => {'t' => 52}, 'sample' => {'kind' => 'string', 'value' => 'tail-recursive'}},
     {'doc' => {'t' => 53}, 'sample' => {'kind' => 'null'}}],
  ].freeze
  EXPECTED_ROWS = (1..ROW_COUNT).map do |pk|
    index = pk - 1
    {'pk' => pk,
     'state' => {'label' => EXPECTED_LABELS.fetch(index), 'sum' => EXPECTED_SUMS.fetch(index)},
     'dyn' => EXPECTED_DYN.fetch(index),
     'object' => {'label' => "doc-#{pk}", 'shape' => EXPECTED_SHAPES.fetch(index)},
     'recursive' => EXPECTED_CHILDREN.fetch(index)}
  end.freeze
  EXPECTED_AGGREGATE = 1497
  TAGS = {
    path: '__W245_PATH__', check_begin: '__W245_CHECK_BEGIN__', check_end: '__W245_CHECK_END__',
    schema: '__W245_SCHEMA__', part: '__W245_PART__', values: '__W245_VALUES__',
    children: '__W245_CHILDREN__', aggregate: '__W245_AGGREGATE__',
  }.freeze
  PIN_TAG = '__W241_PIN__'.freeze
  LABELS = %w[crystal_helper native_create_table native_attach_check native_typed_values
              native_recursive_children native_aggregate_finalize].freeze
  SUMMARY_KEYS = %w[
    format status fatal_error scope evidence_root runtime source_pins helper helper_executable
    helper_manifest helper_output_sha256 string_profile dynamic_mode profile_id frame_bytes
    string_serialization_version serialization columns_substreams_text substream_sections schema
    generated_snapshot pre_attach_snapshot detached_snapshot attached_snapshot physical_mark_tuples
    attachment native_observations invocations evidence_paths
  ].freeze
  PROCESS_KEYS = %w[
    label process_kind argv argv_file argv_sha256 stdin_file stdin_bytes stdin_sha256 stdout_file
    stdout_bytes stdout_sha256 stderr_file stderr_bytes stderr_sha256 exit signal timed_out
    timeout_seconds termination_grace_seconds max_threads max_memory_usage_bytes max_memory_usage_applicable
    required_outer_run_safe_memory_limit_bytes binary_path expected_binary_sha256 binary_sha_before
    binary_sha_after spawn_error stdin_write_error stdout_read_error stderr_read_error
    process_classification store_path
  ].freeze
  MAX_ARTIFACT_BYTES = 64 * 1024 * 1024
  MAX_PART_BYTES = 64 * 1024 * 1024
  MAX_PART_FILE_BYTES = W241::MAX_PART_FILE_BYTES

  class Failure < StandardError; end

  class UniqueKeyHash < Hash
    def []=(key, value)
      raise JSON::ParserError, "duplicate object key #{key.inspect}" if key?(key)
      super
    end
  end

  def self.ruby_source_closure_paths(root_source)
    scripts_root = File.realpath(__dir__)
    pending = [File.expand_path(root_source)]
    seen = {}
    until pending.empty?
      path = pending.pop
      canonical = File.realpath(path)
      unless canonical.start_with?(scripts_root + File::SEPARATOR) && File.file?(canonical) && !File.symlink?(path)
        raise Failure, "Ruby source dependency escapes the scripts tree or is not a regular file: #{path}"
      end
      next if seen.key?(canonical)
      seen[canonical] = true
      File.foreach(canonical) do |line|
        match = /^\s*require_relative\s+['"]([^'"]+)['"]/.match(line)
        next unless match
        dependency = File.expand_path(match[1], File.dirname(canonical))
        dependency += '.rb' if File.extname(dependency).empty?
        pending << dependency
      end
    end
    seen.keys.sort
  rescue Errno::ENOENT => error
    raise Failure, "Ruby source dependency is missing: #{error.message}"
  end

  def self.explicit_32_byte_frame_assignment?(text)
    assignments = text.each_line.select { |line| /\A[ \t]*FRAME_BYTES[ \t]*=/.match?(line) }
    assignments.size == 1 &&
      /\A[ \t]*FRAME_BYTES[ \t]*=[ \t]*32[ \t]*(?:\#[^\r\n]*)?\r?\n?\z/.match?(assignments.first)
  end

  class Auditor
    def initialize(summary_path:, summary_sha256:, clickhouse:, helper_path:, helper_sha256:,
                   probe_source:, probe_source_sha256:, helper_source:, helper_source_sha256:,
                   fixture_source:, fixture_source_sha256:, auditor_source:, auditor_source_sha256:,
                   self_test:)
      @summary_path = File.expand_path(summary_path)
      @root = File.dirname(@summary_path)
      @summary_sha = checked_sha(summary_sha256, 'summary')
      @clickhouse = canonical_executable(clickhouse, 'ClickHouse')
      @helper_path = canonical_executable(helper_path, 'Crystal fixture helper')
      @helper_sha = checked_sha(helper_sha256, 'helper executable')
      @probe_source = canonical_source(probe_source, 'Ruby probe source')
      @probe_source_sha = checked_sha(probe_source_sha256, 'Ruby probe source')
      @helper_source = canonical_source(helper_source, 'helper entrypoint source')
      @helper_source_sha = checked_sha(helper_source_sha256, 'helper entrypoint source')
      @fixture_source = canonical_source(fixture_source, 'fixture dependency source')
      @fixture_source_sha = checked_sha(fixture_source_sha256, 'fixture dependency source')
      @auditor_source = canonical_source(auditor_source, 'Ruby auditor source')
      @auditor_source_sha = checked_sha(auditor_source_sha256, 'Ruby auditor source')
      fail!('--self-test is required for a capture audit') unless self_test
      fail!('summary must be summary.json in a canonical direct child of /private/tmp') unless
        File.basename(@summary_path) == 'summary.json' && File.directory?(@root) && !File.symlink?(@root) &&
        File.realpath(@root) == @root && File.dirname(@root) == File.realpath('/private/tmp')
    end

    def run
      summary_bytes = read_bounded(@summary_path, MAX_ARTIFACT_BYTES, 'summary')
      @summary = parse_json!(summary_bytes, 'summary')
      same!(Digest::SHA256.hexdigest(summary_bytes), @summary_sha, 'summary SHA-256 differs from external pin')
      authenticate_root_layout!
      authenticate_summary_and_pins!
      authenticate_invocation_artifacts!
      authenticate_helper_part!
      authenticate_physical_layout!
      authenticate_attachment!
      replay_native_outputs!
      controls = self_test!
      {
        status: 'raw_capture_authenticated',
        summary_sha256: @summary_sha,
        runtime_sha256: W241::BINARY_SHA256,
        helper_sha256: @helper_sha,
        string_profile: @summary.fetch('string_profile'),
        dynamic_mode: @summary.fetch('dynamic_mode'),
        schema_columns: SCHEMA.map { |column| column.fetch('name') },
        rows: ROW_COUNT,
        parent_mark_rows: MARK_ROWS,
        child_occurrences_per_parent_mark: [0, 2, 3],
        physical_mark_files: @marks.size,
        controls: controls,
        interpretation: 'One fixture-produced library part read by the pinned stock local reader. No reciprocal writer, live table, broader type grammar, performance, RSS, or cryptographic execution-provenance claim.',
      }
    end

    # In-memory controls attack the typed-value distinction, full schema roster,
    # successful-exit CHECK=0, and ATTACH path lifecycle without touching evidence files.
    def self_test!
      baseline_type = 'UInt64'
      baseline_json = 7
      controls = {}
      controls[:typed_value_baseline_accepted] = typed_scalar_valid?(baseline_type, baseline_json, {'kind' => 'uint64', 'value' => 7})
      controls[:same_value_wrong_type_rejected] = !typed_scalar_valid?('UInt8', baseline_json, {'kind' => 'uint64', 'value' => 7})
      source_paths = ['/scripts/a.rb', '/scripts/b.rb']
      source_sha = {'/scripts/a.rb' => 'a' * 64, '/scripts/b.rb' => 'b' * 64}
      source_entries = source_paths.map { |path| {'path' => path, 'sha256' => source_sha.fetch(path)} }
      controls[:complete_source_closure_accepted] = source_closure_valid?(source_entries, source_paths, source_sha)
      controls[:incomplete_source_closure_rejected] = !source_closure_valid?(source_entries.drop(1), source_paths, source_sha)
      controls[:source_closure_hash_mismatch_rejected] = !source_closure_valid?(
        [source_entries.first, {'path' => source_paths.last, 'sha256' => 'c' * 64}], source_paths, source_sha)
      controls[:extra_source_closure_entry_rejected] = !source_closure_valid?(
        source_entries + [{'path' => '/scripts/c.rb', 'sha256' => 'd' * 64}], source_paths, source_sha)
      controls[:ordered_complete_schema_accepted] = schema_rows_valid?(SCHEMA.map { |column| [column.fetch('name'), column.fetch('type')] })
      controls[:incomplete_schema_rejected] = !schema_rows_valid?(SCHEMA[0...-1].map { |column| [column.fetch('name'), column.fetch('type')] })
      swapped = SCHEMA.map { |column| [column.fetch('name'), column.fetch('type')] }
      swapped[1], swapped[2] = swapped[2], swapped[1]
      controls[:swapped_schema_rejected] = !schema_rows_valid?(swapped)
      controls[:successful_exit_check_zero_rejected] = !check_success_valid?(0, ["#{PART_NAME}\t0\t"])
      controls[:successful_exit_check_one_accepted] = check_success_valid?(0, ["#{PART_NAME}\t1\t"])
      sample_tag = TAGS.fetch(:values)
      sample_rows = [[sample_tag, '1', 'UInt64']]
      sample_stdout = ([pin_line] + sample_rows.map { |row| row.join("\t") }).join("\n") + "\n"
      controls[:exact_pinned_tagged_stdout_accepted] = exact_pinned_tagged_stdout_valid?(sample_stdout, sample_tag, 3)
      controls[:unexpected_stdout_line_rejected] = !exact_pinned_tagged_stdout_valid?(sample_stdout + "unexpected\n", sample_tag, 3)
      expected_path_types = {'label' => 'String', 'shape' => 'UInt64'}
      controls[:exact_object_path_types_accepted] = exact_object_path_types_valid?(expected_path_types, {'kind' => 'uint64', 'value' => 7})
      controls[:extra_object_path_type_rejected] = !exact_object_path_types_valid?(
        expected_path_types.merge('unexpected' => 'String'), {'kind' => 'uint64', 'value' => 7})
      controls[:formatted_frame_assignment_accepted] =
        AuditSchemaWidePartW245.explicit_32_byte_frame_assignment?("  FRAME_BYTES     = 32  # pinned\n")
      controls[:wrong_frame_value_rejected] =
        !AuditSchemaWidePartW245.explicit_32_byte_frame_assignment?("FRAME_BYTES = 33\n")
      controls[:frame_expression_rejected] =
        !AuditSchemaWidePartW245.explicit_32_byte_frame_assignment?("FRAME_BYTES = 32 + 1\n")
      controls[:frame_prefix_number_rejected] =
        !AuditSchemaWidePartW245.explicit_32_byte_frame_assignment?("FRAME_BYTES = 320\n")
      controls[:comment_only_frame_rejected] =
        !AuditSchemaWidePartW245.explicit_32_byte_frame_assignment?("# FRAME_BYTES = 32\n")
      controls[:duplicate_frame_assignment_rejected] =
        !AuditSchemaWidePartW245.explicit_32_byte_frame_assignment?("FRAME_BYTES = 32\nFRAME_BYTES = 33\n")
      canonical_parent = '/private/tmp/w245-self-test/store/table'
      controls[:exact_child_path_accepted] = exact_child_path?(canonical_parent + '/' + PART_NAME, canonical_parent, PART_NAME)
      controls[:path_swap_rejected] = !exact_child_path?(canonical_parent + '/other/' + PART_NAME, canonical_parent, PART_NAME)
      controls[:symlink_escape_rejected] = !canonical_directory_binding?(canonical_parent + '/escaped',
                                                                         '/private/tmp/outside/escaped', canonical_parent)
      historical_detached = canonical_parent + '/detached/' + PART_NAME
      controls[:moved_detached_source_absence_accepted] = detached_path_after_attach_valid?(
        historical_detached, historical_detached, :absent)
      controls[:residual_detached_directory_rejected] = !detached_path_after_attach_valid?(
        historical_detached, historical_detached, :directory)
      controls[:residual_detached_symlink_rejected] = !detached_path_after_attach_valid?(
        historical_detached, historical_detached, :symlink)
      controls[:historical_detached_path_swap_rejected] = !detached_path_after_attach_valid?(
        canonical_parent + '/elsewhere/' + PART_NAME, historical_detached, :absent)
      fail!('W245 auditor self-test did not discriminate required controls') unless controls.values.all?
      controls
    end

    private

    def fail!(message)
      raise Failure, "W245 audit: #{message}"
    end

    def checked_sha(value, label)
      fail!("#{label} SHA-256 is malformed") unless value.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(value)
      value
    end

    def canonical_executable(path, label)
      expanded = canonical_source(path, label)
      fail!("#{label} is not executable") unless File.executable?(expanded)
      expanded
    end

    def canonical_source(path, label)
      fail!("#{label} path is required") unless path.is_a?(String) && !path.empty?
      expanded = File.expand_path(path)
      fail!("#{label} is absent, non-regular, or symlinked") unless
        File.file?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded
      expanded
    end

    def read_bounded(path, limit, label)
      fail!("#{label} is absent, non-regular, or symlinked") unless File.file?(path) && !File.symlink?(path)
      size = File.size(path)
      fail!("#{label} exceeds its byte bound") unless size >= 0 && size <= limit
      bytes = File.binread(path)
      fail!("#{label} changed while read") unless bytes.bytesize == size
      bytes
    end

    def parse_json!(bytes, label)
      JSON.parse(bytes, object_class: UniqueKeyHash)
    rescue JSON::ParserError => error
      fail!("#{label} is invalid or has duplicate keys: #{error.message}")
    end

    def exact_keys!(value, expected, label)
      fail!("#{label} key set differs") unless value.is_a?(Hash) && value.keys.sort == expected.sort
    end

    def same!(actual, expected, label)
      fail!("#{label} differs; observed #{actual.inspect}, expected #{expected.inspect}") unless actual == expected
    end

    def authenticate_root_layout!
      %w[generated invocations parts stores].each do |name|
        path = File.join(@root, name)
        fail!("evidence directory #{name} is absent, noncanonical, or symlinked") unless
          File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path
      end
      %w[pre_attach].each do |name|
        path = File.join(@root, 'parts', name)
        fail!("parts/#{name} is absent, noncanonical, or symlinked") unless
          File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path
      end
      native_store = File.join(@root, 'stores', 'native')
      fail!('native store is absent, symlinked, or noncanonical') unless
        File.directory?(native_store) && !File.symlink?(native_store) && File.realpath(native_store) == native_store
      @invocations_dir = File.join(@root, 'invocations')
      true
    end

    def authenticate_summary_and_pins!
      exact_keys!(@summary, SUMMARY_KEYS, 'summary')
      same!(@summary.fetch('format'), FORMAT, 'summary format')
      same!(@summary.fetch('status'), 'library_written_native_read_observed', 'summary status')
      same!(@summary.fetch('fatal_error'), nil, 'summary failure state')
      same!(@summary.fetch('scope'), 'library_written_stock_read_only; one String profile and one Dynamic discriminator mode; no reciprocal or live-table claim', 'summary scope')
      same!(@summary.fetch('evidence_root'), @root, 'summary evidence root')
      same!(@summary.fetch('schema'), SCHEMA, 'literal schema/order')
      same!(@summary.fetch('frame_bytes'), FRAME_BYTES, 'fixed writer frame bound')

      profile = @summary.fetch('string_profile')
      mode = @summary.fetch('dynamic_mode')
      fail!('String profile is not single or sized') unless %w[single sized].include?(profile)
      fail!('Dynamic discriminator mode is not basic or compact') unless %w[basic compact].include?(mode)
      same!(@summary.fetch('profile_id'), profile == 'single' ? 'advanced_s0' : 'advanced_s1', 'reader profile identity')
      same!(@summary.fetch('string_serialization_version'), profile == 'single' ? 0 : 1, 'String metadata version')

      runtime = @summary.fetch('runtime')
      exact_keys!(runtime, %w[path sha256_expected sha256_before sha256_after], 'runtime record')
      same!([runtime['path'], runtime['sha256_expected'], runtime['sha256_before'], runtime['sha256_after']],
            [@clickhouse, W241::BINARY_SHA256, W241::BINARY_SHA256, W241::BINARY_SHA256], 'runtime identity')
      same!(Digest::SHA256.file(@clickhouse).hexdigest, W241::BINARY_SHA256, 'current pinned ClickHouse executable')

      pins = @summary.fetch('source_pins')
      exact_keys!(pins, %w[
        ruby_probe_path ruby_probe_sha256_before ruby_probe_sha256_after
        ruby_source_closure_before ruby_source_closure_after
        helper_entrypoint_source_path helper_entrypoint_source_sha256_before helper_entrypoint_source_sha256_after
        fixture_source_path fixture_source_sha256_before fixture_source_sha256_after
      ], 'source pin record')
      same!([pins['ruby_probe_path'], pins['ruby_probe_sha256_before'], pins['ruby_probe_sha256_after']],
            [@probe_source, @probe_source_sha, @probe_source_sha], 'probe source identity')
      probe_closure_paths = AuditSchemaWidePartW245.ruby_source_closure_paths(@probe_source)
      probe_closure_sha = probe_closure_paths.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }
      fail!('probe source closure is incomplete, extra, reordered, or hash-mismatched') unless
        source_closure_valid?(pins['ruby_source_closure_before'], probe_closure_paths, probe_closure_sha) &&
        source_closure_valid?(pins['ruby_source_closure_after'], probe_closure_paths, probe_closure_sha)
      probe_entry = pins['ruby_source_closure_before'].find { |entry| entry['path'] == @probe_source }
      same!(probe_entry.fetch('sha256'), @probe_source_sha, 'probe source closure/direct pin agreement')
      same!([pins['helper_entrypoint_source_path'], pins['helper_entrypoint_source_sha256_before'], pins['helper_entrypoint_source_sha256_after']],
            [@helper_source, @helper_source_sha, @helper_source_sha], 'helper entrypoint source identity')
      same!([pins['fixture_source_path'], pins['fixture_source_sha256_before'], pins['fixture_source_sha256_after']],
            [@fixture_source, @fixture_source_sha, @fixture_source_sha], 'fixture dependency source identity')
      [[@probe_source, @probe_source_sha], [@helper_source, @helper_source_sha],
       [@fixture_source, @fixture_source_sha], [@auditor_source, @auditor_source_sha]].each do |path, sha|
        same!(Digest::SHA256.file(path).hexdigest, sha, "external source pin #{path}")
      end
      auditor_closure_paths = AuditSchemaWidePartW245.ruby_source_closure_paths(@auditor_source)
      same!(auditor_closure_paths - [@auditor_source],
            probe_closure_paths - [@probe_source], 'shared imported Ruby source closure')
      auditor_closure_paths.each do |path|
        expected_sha = path == @auditor_source ? @auditor_source_sha : probe_closure_sha.fetch(path)
        same!(Digest::SHA256.file(path).hexdigest, expected_sha, "auditor source closure #{path}")
      end
      same!(@fixture_source_sha, pins['fixture_source_sha256_before'], 'externally pinned fixture source')
      fixture_text = File.binread(@fixture_source)
      fail!('fixture source lacks the explicit 32-byte frame constant') unless
        AuditSchemaWidePartW245.explicit_32_byte_frame_assignment?(fixture_text)

      helper = @summary.fetch('helper')
      exact_keys!(helper, %w[invocation_label helper_executable_sha256 helper_source_sha256 fixture_source_sha256 output_sha256 source_snapshot_sha256], 'helper record')
      same!([helper['invocation_label'], helper['helper_executable_sha256'], helper['helper_source_sha256'], helper['fixture_source_sha256']],
            ['crystal_helper', @helper_sha, @helper_source_sha, @fixture_source_sha], 'helper source/executable binding')
      executable = @summary.fetch('helper_executable')
      exact_keys!(executable, %w[path sha256_before sha256_after], 'helper executable record')
      same!([executable['path'], executable['sha256_before'], executable['sha256_after']],
            [@helper_path, @helper_sha, @helper_sha], 'helper executable pin')
      same!(Digest::SHA256.file(@helper_path).hexdigest, @helper_sha, 'current helper executable pin')

      manifest = @summary.fetch('helper_manifest')
      exact_keys!(manifest, %w[format part_path key_column columns keys mark_row_counts string_profile dynamic_mode rows files], 'helper manifest')
      same!([manifest['format'], manifest['part_path'], manifest['key_column'], manifest['columns'], manifest['keys'], manifest['mark_row_counts'], manifest['string_profile'], manifest['dynamic_mode'], manifest['rows']],
            [HELPER_FORMAT, generated_part_path, KEY, VALUE_COLUMNS, (1..ROW_COUNT).to_a, MARK_ROWS, profile, mode, EXPECTED_ROWS],
            'literal helper fixture contract')
      true
    rescue KeyError, TypeError => error
      fail!("summary or source pins are malformed: #{error.class}: #{error.message}")
    end

    def generated_part_path
      File.join(@root, 'generated', PART_NAME)
    end

    def pre_attach_part_path
      File.join(@root, 'parts', 'pre_attach', PART_NAME)
    end

    def authenticate_invocation_artifacts!
      records = @summary.fetch('invocations')
      fail!('process invocation roster/order differs') unless records.is_a?(Array) && records.map { |record| record.fetch('label') } == LABELS
      @records = records.to_h { |record| [record.fetch('label'), record] }
      fail!('process invocation labels are duplicated') unless @records.size == LABELS.size
      expected_names = []
      LABELS.each do |label|
        record = @records.fetch(label)
        exact_keys!(record, PROCESS_KEYS, "process #{label}")
        validate_process!(record, label)
        %w[argv_file stdin_file stdout_file stderr_file].each { |field| expected_names << record.fetch(field) }
        expected_names << "#{label}.json"
      end
      actual_names = Dir.children(@invocations_dir).sort
      same!(actual_names, expected_names.sort, 'invocation artifact directory roster')
      true
    rescue KeyError, TypeError => error
      fail!("invocation records are malformed: #{error.class}: #{error.message}")
    end

    def validate_process!(record, label)
      fail!("#{label} did not exit cleanly") unless
        record['process_classification'] == 'success' && record['exit'] == 0 && record['signal'].nil? &&
        record['timed_out'] == false && record['stderr_bytes'] == 0 &&
        record['stderr_sha256'] == Digest::SHA256.hexdigest('') &&
        %w[spawn_error stdin_write_error stdout_read_error stderr_read_error].all? { |field| record[field].nil? }
      same!([record['timeout_seconds'], record['termination_grace_seconds'], record['required_outer_run_safe_memory_limit_bytes']],
            [W241::TIMEOUT, W241::GRACE, W241::OUTER_RUN_SAFE_LIMIT], "#{label} process bounds")
      if label == 'crystal_helper'
        same!([record['process_kind'], record['argv'], record['store_path'], record['binary_path'], record['expected_binary_sha256'],
               record['binary_sha_before'], record['binary_sha_after'], record['max_threads'], record['max_memory_usage_bytes'], record['max_memory_usage_applicable']],
              ['crystal-helper', [@helper_path, generated_part_path, @summary.fetch('string_profile'), @summary.fetch('dynamic_mode')],
               nil, @helper_path, @helper_sha, @helper_sha, @helper_sha, nil, nil, false], 'helper invocation identity')
      else
        store = File.join(@root, 'stores', 'native')
        same!([record['process_kind'], record['argv'], record['store_path'], record['binary_path'], record['expected_binary_sha256'],
               record['binary_sha_before'], record['binary_sha_after'], record['max_threads'], record['max_memory_usage_bytes'], record['max_memory_usage_applicable']],
              ['clickhouse-local', [@clickhouse, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
                                    "--max_memory_usage=#{W241::MEMORY}", '--multiquery'],
               store, @clickhouse, W241::BINARY_SHA256, W241::BINARY_SHA256, W241::BINARY_SHA256, 1, W241::MEMORY, true],
              "#{label} native process identity")
      end
      %w[argv_file stdin_file stdout_file stderr_file].each do |field|
        basename = record.fetch(field)
        fail!("#{label} #{field} is not a safe basename") unless basename.is_a?(String) && File.basename(basename) == basename && /\A[A-Za-z0-9_.-]+\z/.match?(basename)
      end
      {
        'argv_file' => ['argv_sha256', nil], 'stdin_file' => ['stdin_sha256', 'stdin_bytes'],
        'stdout_file' => ['stdout_sha256', 'stdout_bytes'], 'stderr_file' => ['stderr_sha256', 'stderr_bytes'],
      }.each do |field, (sha_field, size_field)|
        bytes = read_bounded(invocation_path(record.fetch(field)), MAX_ARTIFACT_BYTES, "#{label} #{field}")
        same!(Digest::SHA256.hexdigest(bytes), record.fetch(sha_field), "#{label} #{field} digest")
        same!(bytes.bytesize, record.fetch(size_field), "#{label} #{field} byte count") if size_field
      end
      argv_bytes = read_bounded(invocation_path(record.fetch('argv_file')), MAX_ARTIFACT_BYTES, "#{label} argv")
      same!(parse_json!(argv_bytes, "#{label} argv"), record.fetch('argv'), "#{label} argv artifact")
      same!(read_bounded(invocation_path(record.fetch('stderr_file')), MAX_ARTIFACT_BYTES, "#{label} stderr"), ''.b, "#{label} stderr")
      stdin = read_bounded(invocation_path(record.fetch('stdin_file')), MAX_ARTIFACT_BYTES, "#{label} stdin")
      same!(stdin, label == 'crystal_helper' ? ''.b : expected_stdin(label).b, "#{label} exact stdin")
      record_bytes = read_bounded(invocation_path("#{label}.json"), MAX_ARTIFACT_BYTES, "#{label} record")
      same!(parse_json!(record_bytes, "#{label} record"), record, "#{label} raw record artifact")
      stdout = stdout_for(label)
      same!(tagged_rows(stdout, PIN_TAG, 3), [[PIN_TAG, W241::VERSION, W241::BUILD]], "#{label} runtime pin") unless label == 'crystal_helper'
      true
    rescue KeyError, TypeError, ArgumentError => error
      fail!("#{label} process artifact validation failed: #{error.class}: #{error.message}")
    end

    def invocation_path(basename)
      fail!('invocation directory was not authenticated') unless @invocations_dir
      fail!('unsafe invocation artifact basename') unless basename.is_a?(String) && File.basename(basename) == basename && /\A[A-Za-z0-9_.-]+\z/.match?(basename)
      path = File.join(@invocations_dir, basename)
      fail!("invocation artifact is symlinked: #{basename}") if File.symlink?(path)
      path
    end

    def stdout_for(label)
      record = @records.fetch(label)
      read_bounded(invocation_path(record.fetch('stdout_file')), MAX_ARTIFACT_BYTES, "#{label} stdout")
    end

    def expected_stdin(label)
      pin = "SET output_format_json_quote_64bit_integers=0;\nSELECT '__W241_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;"
      sql = native_sql(label)
      [pin, 'SET print_pretty_type_names=0;', 'SET output_format_json_quote_64bit_integers=0;', sql].join("\n")
    end

    def native_sql(label)
      table = table_name
      case label
      when 'native_create_table'
        profile = reader_profile
        columns = SCHEMA.map { |column| "`#{column.fetch('name')}` #{column.fetch('type')}" }.join(', ')
        ["CREATE TABLE default.#{table} (#{columns}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings(profile)};",
         "SELECT '#{TAGS.fetch(:path)}', database, name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw;"].join("\n")
      when 'native_attach_check'
        ["ALTER TABLE default.#{table} ATTACH PART '#{PART_NAME}';",
         "SELECT '#{TAGS.fetch(:check_begin)}' FORMAT TSVRaw;", "CHECK TABLE default.#{table} FORMAT TSV;",
         "SELECT '#{TAGS.fetch(:check_end)}' FORMAT TSVRaw;",
         "SELECT '#{TAGS.fetch(:schema)}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;",
         "SELECT '#{TAGS.fetch(:part)}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;"].join("\n")
      when 'native_typed_values'
        "SELECT '#{TAGS.fetch(:values)}', toString(pk), toTypeName(state.1), state.1, " \
          "toTypeName(finalizeAggregation(state.2)), toString(finalizeAggregation(state.2)), " \
          "if(isNull(dyn), 'NULL', dynamicType(dyn)), if(isNull(dyn), 'null', hex(toJSONString(dyn))), " \
          "toTypeName(object.label), object.label, toTypeName(object.shape), " \
          "if(isNull(object.shape), 'NULL', dynamicType(object.shape)), " \
          "if(isNull(object.shape), 'null', hex(toJSONString(object.shape))), " \
          "hex(toJSONString(JSONAllPathsWithTypes(object))), hex(toJSONString(object)) " \
          "FROM default.#{table} ORDER BY pk FORMAT TSVRaw;"
      when 'native_recursive_children'
        "SELECT '#{TAGS.fetch(:children)}', toString(pk), toString(item_index), " \
          "toTypeName(item.doc), hex(toJSONString(item.doc)), " \
          "hex(toJSONString(JSONAllPathsWithTypes(item.doc))), toTypeName(item.doc.t), toString(item.doc.t), " \
          "toTypeName(item.sample), if(isNull(item.sample), 'NULL', dynamicType(item.sample)), " \
          "if(isNull(item.sample), 'null', hex(toJSONString(item.sample))) " \
          "FROM default.#{table} ARRAY JOIN arrayEnumerate(recursive) AS item_index, recursive AS item " \
          "ORDER BY pk, item_index FORMAT TSVRaw;"
      when 'native_aggregate_finalize'
        "SELECT '#{TAGS.fetch(:aggregate)}', toTypeName(sumMerge(state.2)), toString(sumMerge(state.2)) FROM default.#{table} FORMAT TSVRaw;"
      else
        fail!("unknown native label #{label.inspect}")
      end
    end

    def settings(profile)
      runner = W241::Probe.allocate
      runner.send(:settings, profile)
    end

    def reader_profile
      id = @summary.fetch('profile_id')
      W241::PROFILES.find { |item| item.fetch(:id) == id } || fail!('reader profile is absent from W241 settings')
    end

    def table_name
      "w245_#{Digest::SHA256.hexdigest(@root)[0, 8]}_#{@summary.fetch('string_profile')}_#{@summary.fetch('dynamic_mode')}"
    end

    def authenticate_helper_part!
      raw = stdout_for('crystal_helper')
      text = raw.dup.force_encoding(Encoding::UTF_8)
      fail!('helper stdout is not one UTF-8 JSON line') unless text.valid_encoding? && text.lines.size == 1 && text.end_with?("\n")
      manifest = parse_json!(text, 'helper stdout')
      same!(manifest, @summary.fetch('helper_manifest'), 'helper stdout/summary manifest join')
      same!(Digest::SHA256.hexdigest(raw), @summary.fetch('helper_output_sha256'), 'helper output SHA')
      helper = @summary.fetch('helper')
      same!(helper.fetch('output_sha256'), Digest::SHA256.hexdigest(raw), 'helper record output SHA')
      source_snapshot = snapshot_tree(generated_part_path)
      same!(source_snapshot, file_manifest_snapshot(manifest.fetch('files')), 'raw helper file inventory/current generated tree')
      same!(source_snapshot, @summary.fetch('generated_snapshot'), 'summary/generated tree snapshot')
      same!(Digest::SHA256.hexdigest(JSON.generate(source_snapshot)), helper.fetch('source_snapshot_sha256'), 'helper source snapshot digest')
      @source_snapshot = source_snapshot
      @manifest = manifest
      true
    rescue KeyError, TypeError, ArgumentError => error
      fail!("helper part authentication failed: #{error.class}: #{error.message}")
    end

    def file_manifest_snapshot(files)
      fail!('helper files manifest is malformed') unless files.is_a?(Array)
      entries = files.map do |entry|
        exact_keys!(entry, %w[name size sha256], 'helper file entry')
        name = entry.fetch('name')
        fail!('helper file name is unsafe') unless name.is_a?(String) && File.basename(name) == name && /\A[A-Za-z0-9_.-]+\z/.match?(name)
        size = entry.fetch('size')
        fail!('helper file size is malformed') unless size.is_a?(Integer) && size >= 0
        sha = checked_sha(entry.fetch('sha256'), 'part file')
        [name, size, sha]
      end
      fail!('helper file inventory has duplicates or is not sorted') unless entries.map(&:first).uniq.size == entries.size && entries == entries.sort
      entries
    end

    def snapshot_tree(path)
      fail!("part tree is absent, noncanonical, or symlinked: #{path}") unless
        File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path
      entries = []
      total = 0
      count = 0
      Find.find(path) do |entry|
        stat = File.lstat(entry)
        fail!("part contains symlink or special file: #{entry}") unless !stat.symlink? && (stat.directory? || stat.file?)
        next if stat.directory?
        name = entry.delete_prefix(path + File::SEPARATOR)
        fail!('Wide part contains nested file path') if name.include?(File::SEPARATOR)
        count += 1
        total += stat.size
        fail!('part file count/size exceeds bounds') unless count <= 4096 && stat.size <= MAX_PART_FILE_BYTES && total <= MAX_PART_BYTES
        entries << [name, stat.size, Digest::SHA256.file(entry).hexdigest]
      end
      entries.sort
    end

    def authenticate_physical_layout!
      same!(@summary.fetch('serialization'), read_json_file(generated_part_path, 'serialization.json'), 'raw serialization metadata')
      serialization = @summary.fetch('serialization')
      same!(serialization['version'], 1, 'serialization format version')
      same!(serialization['propagate_types_serialization_versions_to_nested_types'], true, 'nested type version propagation')
      expected_string = @summary.fetch('string_profile') == 'single' ? 0 : 1
      same!(serialization.dig('types_serialization_versions', 'string'), expected_string, 'on-disk String serialization profile')
      codec = read_plain(generated_part_path, 'default_compression_codec.txt', 1024).strip
      same!(codec, 'CODEC(LZ4)', 'part default codec')
      same!(read_plain(generated_part_path, 'metadata_version.txt', 1024).strip, '0', 'part metadata version')
      same!(read_plain(generated_part_path, 'count.txt', 1024).strip, ROW_COUNT.to_s, 'physical count.txt')
      columns = "columns format version: 1\n#{SCHEMA.size} columns:\n" + SCHEMA.map { |column| "`#{column.fetch('name')}` #{column.fetch('type')}\n" }.join
      same!(read_plain(generated_part_path, 'columns.txt', 1024 * 1024), columns.b, 'physical ordered column declarations')
      substream_text = read_plain(generated_part_path, 'columns_substreams.txt', 4 * 1024 * 1024)
      same!(substream_text, @summary.fetch('columns_substreams_text').b, 'raw columns_substreams summary binding')
      sections = parse_substream_sections!(substream_text)
      same!(sections, @summary.fetch('substream_sections'), 'summary logical owner roster')
      actual_stream_files = Dir.children(generated_part_path).select { |name| name.end_with?('.bin', '.mrk2') }.sort
      expected_stream_files = sections.flat_map { |_column, names| names.flat_map { |name| stem = stream_hash(name); ["#{stem}.bin", "#{stem}.mrk2"] } }.sort
      same!(actual_stream_files, expected_stream_files, 'actual hashed stream roster')
      fail!('part contains compressed marks or unexpected mark naming') if Dir.children(generated_part_path).any? { |name| name.include?('mrk') && !name.end_with?('.mrk2') }
      fail!('key logical stream is not the key column stream') unless sections.first == ['pk', ['pk']]
      fail!('a value owner has no logical substreams') unless sections.drop(1).all? { |_name, streams| !streams.empty? }
      streams = sections.flat_map(&:last)
      fail!('logical stream names are duplicated') unless streams.uniq == streams
      stems = streams.map { |name| stream_hash(name) }
      fail!('logical streams collide in hashed filename space') unless stems.uniq == stems
      @marks = sections.flat_map(&:last).map do |logical|
        name = "#{stream_hash(logical)}.mrk2"
        bytes = read_plain(generated_part_path, name, MAX_PART_FILE_BYTES)
        fail!("#{name} is not a nonempty complete 24-byte triple sequence") unless !bytes.empty? && (bytes.bytesize % 24).zero?
        tuples = bytes.unpack('Q<*').each_slice(3).map(&:dup)
        same!(tuples.map { |tuple| tuple.fetch(2) }, MARK_ROWS_WITH_EOF, "physical mark rows for #{logical}")
        {'name' => name, 'sha256' => Digest::SHA256.hexdigest(bytes), 'tuples' => tuples}
      end.sort_by { |entry| entry.fetch('name') }
      same!(@marks, @summary.fetch('physical_mark_tuples'), 'summary physical mark tuples')
      same!(snapshot_tree(generated_part_path), @source_snapshot, 'generated tree changed during audit')
      true
    rescue KeyError, TypeError, ArgumentError => error
      fail!("physical layout authentication failed: #{error.class}: #{error.message}")
    end

    def parse_substream_sections!(text)
      lines = text.dup.force_encoding(Encoding::UTF_8).split("\n", -1)
      fail!('columns_substreams is invalid UTF-8') unless text.dup.force_encoding(Encoding::UTF_8).valid_encoding?
      fail!('columns_substreams envelope or final newline differs') unless lines.pop == '' && lines.shift == 'columns substreams version: 1'
      match = /\A([1-9][0-9]*) columns:\z/.match(lines.shift.to_s)
      fail!('columns_substreams exact column count differs') unless match && match[1].to_i == SCHEMA.size
      sections = []
      until lines.empty?
        header = /\A(0|[1-9][0-9]*) substreams for column `([a-z][a-z0-9_]*)`:\z/.match(lines.shift.to_s)
        fail!('columns_substreams section header is malformed') unless header
        count = Integer(header[1], 10)
        fail!('columns_substreams section exceeds bound') unless count <= 4096 && lines.size >= count
        names = count.times.map do
          entry = /\A\t([A-Za-z0-9_.%]+)\z/.match(lines.shift.to_s)
          fail!('logical substream name is malformed') unless entry
          entry[1]
        end
        sections << [header[2], names]
      end
      same!(sections.map(&:first), SCHEMA.map { |column| column.fetch('name') }, 'complete ordered logical column roster')
      sections
    end

    def stream_hash(name)
      W241::Auditor.stream_hash(name)
    end

    def read_plain(root, name, limit)
      fail!('unsafe part basename') unless File.basename(name) == name && /\A[A-Za-z0-9_.-]+\z/.match?(name)
      read_bounded(File.join(root, name), limit, "part file #{name}")
    end

    def read_json_file(root, name)
      parse_json!(read_plain(root, name, 1024 * 1024), name)
    end

    def authenticate_attachment!
      same!(snapshot_tree(pre_attach_part_path), @source_snapshot, 'retained pre-attach copy')
      same!(@summary.fetch('pre_attach_snapshot'), @source_snapshot, 'pre-attach summary snapshot')
      same!(@summary.fetch('detached_snapshot'), @source_snapshot, 'captured detached-before-attach snapshot')
      expected_paths = @summary.fetch('evidence_paths')
      exact_keys!(expected_paths, %w[generated_part pre_attach_part detached_part attached_part data_path], 'evidence paths')
      same!([expected_paths['generated_part'], expected_paths['pre_attach_part']],
            [generated_part_path, pre_attach_part_path], 'generated/pre-attach path identities')

      create_lines = stdout_lines('native_create_table')
      pin = pin_line
      fail!('create-table raw output has unexpected lines') unless create_lines.size == 2 && create_lines.first == pin
      path_rows = tagged_rows(create_lines.join("\n") + "\n", TAGS.fetch(:path), 4)
      fail!('native data-path row is not unique') unless path_rows.size == 1
      path_row = path_rows.first
      same!(path_row.values_at(1, 2), ['default', table_name], 'created native table identity')
      @data_path = canonical_native_path(path_row.fetch(3), native_store, 'native table data path')
      same!(expected_paths['data_path'], @data_path, 'summary native data path')
      detached_root = File.join(@data_path, 'detached')
      fail!('detached directory is missing, symlinked, or noncanonical') unless
        File.directory?(detached_root) && !File.symlink?(detached_root) && File.realpath(detached_root) == detached_root
      detached_path = File.join(detached_root, PART_NAME)
      same!(expected_paths['detached_part'], detached_path, 'detached part path binding')
      detached_entry_kind = begin
        File.lstat(detached_path)
        :present
      rescue Errno::ENOENT
        :absent
      end
      fail!('ATTACH did not consume the exact detached source path') unless
        detached_path_after_attach_valid?(expected_paths['detached_part'], detached_path, detached_entry_kind)
      # ATTACH moves the source part out of detached/. The bytes at that path
      # were snapshotted before ATTACH by the pinned probe and are retained in
      # parts/pre_attach; do not reinterpret the historical snapshot as a
      # post-attach filesystem observation.
      @detached_path = detached_path
      @detached_snapshot = @summary.fetch('detached_snapshot')
      same!(@detached_snapshot, @source_snapshot, 'recorded detached-before-attach snapshot')

      attach_lines = stdout_lines('native_attach_check')
      fail!('attach output lacks exact CHECK markers') unless attach_lines.include?(TAGS.fetch(:check_begin)) && attach_lines.include?(TAGS.fetch(:check_end))
      checks = check_rows(stdout_for('native_attach_check'))
      same!(checks, ["#{PART_NAME}\t1\t"], 'successful stock CHECK TABLE result')
      schema_rows = tagged_rows(stdout_for('native_attach_check'), TAGS.fetch(:schema), 3)
      same!(schema_rows.map { |row| row.drop(1) }, SCHEMA.map { |column| [column.fetch('name'), column.fetch('type')] }, 'stock nominal schema/order')
      part_rows = tagged_rows(stdout_for('native_attach_check'), TAGS.fetch(:part), 7)
      fail!('active part row is not unique') unless part_rows.size == 1
      active = part_rows.first
      same!(active.values_at(1, 2, 4, 5, 6), [table_name, PART_NAME, 'Wide', ROW_COUNT.to_s, (MARK_ROWS.size + 1).to_s], 'active table/part/layout/count')
      @active_path = canonical_native_path(active.fetch(3), @data_path, 'active part path')
      fail!('active part path is swapped or not the exact table child') unless exact_child_path?(@active_path, @data_path, PART_NAME)
      same!(expected_paths['attached_part'], @active_path, 'summary active part path')
      @attached_snapshot = snapshot_tree(@active_path)
      original = @source_snapshot.to_h { |name, size, sha| [name, [size, sha]] }
      actual = @attached_snapshot.to_h { |name, size, sha| [name, [size, sha]] }
      metadata = 'invalidated_system_columns.txt'
      fail!('active part file roster differs from generated part plus admitted metadata') unless
        !original.key?(metadata) && (actual.keys - original.keys) == [metadata] && (original.keys - actual.keys).empty?
      original.each { |name, identity| same!(actual.fetch(name), identity, "active original file #{name}") }
      same!(read_plain(@active_path, metadata, 1024), "_block_offset\n_block_number\n".b, 'ClickHouse-added invalidation metadata')
      same!(@attached_snapshot, @summary.fetch('attached_snapshot'), 'summary active part snapshot')

      attachment = @summary.fetch('attachment')
      expected_attachment = {
        'check_rows' => checks,
        'schema' => schema_rows.map { |row| row.drop(1) },
        'active_part' => active.drop(1),
        'data_path' => @data_path,
        'active_path' => @active_path,
        'source_snapshot_sha256' => snapshot_sha(@source_snapshot),
        'pre_attach_snapshot_sha256' => snapshot_sha(@source_snapshot),
        'detached_snapshot_sha256' => snapshot_sha(@source_snapshot),
        'attached_snapshot_sha256' => snapshot_sha(@attached_snapshot),
      }
      same!(attachment, expected_attachment, 'summary/raw attachment observation')
      true
    rescue KeyError, TypeError => error
      fail!("attachment authentication failed: #{error.class}: #{error.message}")
    end

    def replay_native_outputs!
      create_lines = stdout_lines('native_create_table')
      attach_lines = stdout_lines('native_attach_check')
      expected_create = [pin_line, *tagged_rows(create_lines.join("\n") + "\n", TAGS.fetch(:path), 4).map { |row| row.join("\t") }]
      same!(create_lines, expected_create, 'create-table raw output roster')
      expected_attach = [pin_line, TAGS.fetch(:check_begin), "#{PART_NAME}\t1\t", TAGS.fetch(:check_end)] +
        tagged_rows(attach_lines.join("\n") + "\n", TAGS.fetch(:schema), 3).map { |row| row.join("\t") } +
        tagged_rows(attach_lines.join("\n") + "\n", TAGS.fetch(:part), 7).map { |row| row.join("\t") }
      same!(attach_lines, expected_attach, 'attach/check/schema/part raw output roster')
      value_rows = exact_pinned_tagged_rows!('native_typed_values', TAGS.fetch(:values), 15)
      child_rows = exact_pinned_tagged_rows!('native_recursive_children', TAGS.fetch(:children), 11)
      aggregate_rows = exact_pinned_tagged_rows!('native_aggregate_finalize', TAGS.fetch(:aggregate), 3)
      validate_native_value_rows!(value_rows)
      validate_native_child_rows!(child_rows)
      same!(aggregate_rows, [[TAGS.fetch(:aggregate), 'UInt64', EXPECTED_AGGREGATE.to_s]], 'native aggregate finalization')
      expected_observations = {
        'typed_value_rows' => value_rows.map { |row| row.drop(1) },
        'recursive_child_rows' => child_rows.map { |row| row.drop(1) },
        'aggregate_finalization' => aggregate_rows.map { |row| row.drop(1) },
        'type_checked_same_value' => true,
        'value_invocation' => 'native_typed_values', 'children_invocation' => 'native_recursive_children',
        'aggregate_invocation' => 'native_aggregate_finalize',
      }
      same!(@summary.fetch('native_observations'), expected_observations, 'summary/raw typed observations')
      true
    rescue KeyError, TypeError, ArgumentError => error
      fail!("native output replay failed: #{error.class}: #{error.message}")
    end

    def validate_native_value_rows!(rows)
      same!(rows.size, ROW_COUNT, 'native typed value row count')
      rows.each_with_index do |row, index|
        expected = EXPECTED_ROWS.fetch(index)
        same!(row.fetch(1), expected.fetch('pk').to_s, 'native key/order')
        same!(row.values_at(2, 3, 4, 5), ['LowCardinality(String)', expected.dig('state', 'label'), 'UInt64', expected.dig('state', 'sum').to_s], "pk#{index + 1} state exact type/value/finalized state")
        validate_native_tagged!(row.fetch(6), row.fetch(7), expected.fetch('dyn'), "pk#{index + 1} top-level Dynamic")
        object = expected.fetch('object')
        same!(row.values_at(8, 9, 10), ['String', object.fetch('label'), 'Dynamic(max_types=1)'], "pk#{index + 1} nominal JSON paths")
        shape = object.fetch('shape')
        validate_native_tagged!(row.fetch(11), row.fetch(12), shape, "pk#{index + 1} JSON Dynamic")
        path_types = parse_hex_json(row.fetch(13), "pk#{index + 1} JSON path types")
        fail!("pk#{index + 1} JSON path type map differs") unless exact_object_path_types_valid?(path_types, shape)
        object_value = {'label' => object.fetch('label')}
        object_value['shape'] = native_value(shape) unless shape.fetch('kind') == 'null'
        same!(parse_hex_json(row.fetch(14), "pk#{index + 1} full Object JSON"), object_value, "pk#{index + 1} full Object value")
      end
    end

    def validate_native_child_rows!(rows)
      expected = EXPECTED_ROWS.each_with_index.flat_map do |row, index|
        row.fetch('recursive').each_with_index.map { |child, child_index| [index + 1, child_index + 1, child] }
      end
      same!(rows.size, expected.size, 'recursive child count')
      rows.zip(expected).each do |observed, (pk, child_index, child)|
        doc_t = child.dig('doc', 't')
        sample = child.fetch('sample')
        same!(observed.values_at(1, 2, 3, 6, 7, 8),
              [pk.to_s, child_index.to_s, 'JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8)', 'UInt8', doc_t.to_s, 'Dynamic(max_types=1)'],
              "recursive child pk#{pk}/#{child_index} nominal types")
        same!(parse_hex_json(observed.fetch(4), "recursive child pk#{pk}/#{child_index} JSON"), {'t' => doc_t}, 'recursive JSON value')
        same!(parse_hex_json(observed.fetch(5), "recursive child pk#{pk}/#{child_index} path types"), {'t' => 'UInt8'}, 'recursive JSON leaf type')
        validate_native_tagged!(observed.fetch(9), observed.fetch(10), sample, "recursive Dynamic pk#{pk}/#{child_index}")
      end
    end

    def validate_native_tagged!(actual_type, json_hex, expected, label)
      if expected.fetch('kind') == 'null'
        fail!("#{label} NULL type/value differs") unless actual_type == 'NULL' && [nil, 'null'].include?(json_hex)
      else
        same!(actual_type, native_type(expected.fetch('kind')), "#{label} actual type")
        same!(parse_hex_json(json_hex, "#{label} JSON value"), expected.fetch('value'), "#{label} exact value")
      end
    end

    def typed_scalar_valid?(actual_type, actual_value, expected)
      actual_type == native_type(expected.fetch('kind')) && actual_value == expected['value']
    rescue KeyError
      false
    end

    def native_type(kind)
      {'uint64' => 'UInt64', 'string' => 'String', 'null' => 'NULL'}.fetch(kind)
    end

    def native_value(tagged)
      tagged.fetch('kind') == 'null' ? nil : tagged.fetch('value')
    end

    def schema_rows_valid?(rows)
      rows == SCHEMA.map { |column| [column.fetch('name'), column.fetch('type')] }
    end

    def check_success_valid?(exit_code, rows)
      exit_code == 0 && rows == ["#{PART_NAME}\t1\t"]
    end

    def canonical_native_path(path, parent, label)
      lexical = path.to_s
      lexical = lexical[0...-1] if lexical.end_with?(File::SEPARATOR)
      fail!("#{label} spelling is not canonical") if lexical.empty? || File.expand_path(lexical) != lexical
      canonical_parent = File.realpath(parent)
      fail!("#{label} parent is not canonical") unless canonical_parent == parent && !File.symlink?(parent)
      fail!("#{label} is missing, symlinked, or noncanonical") unless
        File.directory?(lexical) && !File.symlink?(lexical) && File.realpath(lexical) == lexical
      fail!("#{label} escapes expected parent") unless lexical.start_with?(canonical_parent + File::SEPARATOR)
      lexical
    rescue Errno::ENOENT
      fail!("#{label} is missing")
    end

    def canonical_directory_binding?(lexical, real, parent)
      lexical == real && real.start_with?(parent + File::SEPARATOR)
    end

    def exact_child_path?(path, parent, name)
      path == File.join(parent, name)
    end

    def detached_path_after_attach_valid?(historical_path, expected_path, entry_kind)
      historical_path == expected_path && exact_child_path?(historical_path, File.dirname(expected_path), PART_NAME) &&
        entry_kind == :absent
    end

    def source_closure_valid?(observed, expected_paths, actual_sha_by_path)
      return false unless observed.is_a?(Array) && expected_paths.is_a?(Array) && actual_sha_by_path.is_a?(Hash)
      return false unless expected_paths == expected_paths.uniq.sort
      return false unless observed.all? do |entry|
        entry.is_a?(Hash) && entry.keys.sort == %w[path sha256] &&
          entry['path'].is_a?(String) && entry['sha256'].is_a?(String) &&
          /\A[0-9a-f]{64}\z/.match?(entry['sha256'])
      end
      observed.map { |entry| entry.fetch('path') } == expected_paths &&
        observed.all? { |entry| actual_sha_by_path[entry.fetch('path')] == entry.fetch('sha256') }
    rescue KeyError
      false
    end

    def check_rows(stdout)
      active = false
      result = []
      stdout.dup.force_encoding(Encoding::UTF_8).lines.map(&:chomp).each do |line|
        if line == TAGS.fetch(:check_begin)
          fail!('nested CHECK interval') if active
          active = true
        elsif line == TAGS.fetch(:check_end)
          fail!('CHECK end without begin') unless active
          active = false
        elsif active
          result << line
        end
      end
      fail!('unterminated CHECK interval') if active
      result
    end

    def tagged_rows(stdout, tag, width)
      stdout.dup.force_encoding(Encoding::UTF_8).lines.map(&:chomp).each_with_object([]) do |line, rows|
        next unless line.start_with?(tag + "\t")
        fields = line.split("\t", -1)
        fail!("#{tag} row width differs") unless fields.size == width && fields.first == tag
        rows << fields
      end
    end

    def exact_pinned_tagged_rows!(label, tag, width)
      stdout = stdout_for(label)
      fail!("#{label} stdout is not exactly one runtime pin followed by tagged rows") unless
        exact_pinned_tagged_stdout_valid?(stdout, tag, width)
      tagged_rows(stdout, tag, width)
    end

    def exact_pinned_tagged_stdout_valid?(stdout, tag, width)
      text = stdout.dup.force_encoding(Encoding::UTF_8)
      return false unless text.valid_encoding? && text.end_with?("\n")

      lines = text.split("\n", -1)
      return false unless lines.pop == ''
      return false unless lines.first == pin_line && lines.count(pin_line) == 1

      rows = tagged_rows(text, tag, width)
      lines == [pin_line, *rows.map { |row| row.join("\t") }]
    rescue Failure, ArgumentError
      false
    end

    def exact_object_path_types_valid?(path_types, shape)
      return false unless path_types.is_a?(Hash)

      expected = {'label' => 'String'}
      expected['shape'] = native_type(shape.fetch('kind')) unless shape.fetch('kind') == 'null'
      path_types == expected
    rescue KeyError, ArgumentError
      false
    end

    def stdout_lines(label)
      stdout_for(label).dup.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
    end

    def pin_line
      [PIN_TAG, W241::VERSION, W241::BUILD].join("\t")
    end

    def parse_hex_json(value, label)
      fail!("#{label} is malformed hex JSON") unless value.is_a?(String) && /\A(?:[0-9a-fA-F]{2})*\z/.match?(value)
      parse_json!([value].pack('H*'), label)
    end

    def snapshot_sha(snapshot)
      Digest::SHA256.hexdigest(JSON.generate(snapshot))
    end

    def native_store
      File.join(@root, 'stores', 'native')
    end
  end
end

def main
  options = {}
  parser = OptionParser.new do |opts|
    opts.banner = 'Usage: ruby scripts/audit_schema_wide_part_w245.rb --summary PATH --summary-sha256 SHA --clickhouse PATH --helper PATH --helper-sha256 SHA --probe-source PATH --probe-source-sha256 SHA --helper-source PATH --helper-source-sha256 SHA --fixture-source PATH --fixture-source-sha256 SHA --auditor-source PATH --auditor-source-sha256 SHA --self-test'
    opts.on('--summary PATH') { |value| options[:summary_path] = value }
    opts.on('--summary-sha256 SHA') { |value| options[:summary_sha256] = value }
    opts.on('--clickhouse PATH') { |value| options[:clickhouse] = value }
    opts.on('--helper PATH') { |value| options[:helper_path] = value }
    opts.on('--helper-sha256 SHA') { |value| options[:helper_sha256] = value }
    opts.on('--probe-source PATH') { |value| options[:probe_source] = value }
    opts.on('--probe-source-sha256 SHA') { |value| options[:probe_source_sha256] = value }
    opts.on('--helper-source PATH') { |value| options[:helper_source] = value }
    opts.on('--helper-source-sha256 SHA') { |value| options[:helper_source_sha256] = value }
    opts.on('--fixture-source PATH') { |value| options[:fixture_source] = value }
    opts.on('--fixture-source-sha256 SHA') { |value| options[:fixture_source_sha256] = value }
    opts.on('--auditor-source PATH') { |value| options[:auditor_source] = value }
    opts.on('--auditor-source-sha256 SHA') { |value| options[:auditor_source_sha256] = value }
    opts.on('--self-test') { options[:self_test] = true }
    opts.on('--self-test-only') { options[:self_test_only] = true }
  end
  parser.parse!
  if options[:self_test_only]
    controls = AuditSchemaWidePartW245::Auditor.allocate.self_test!
    puts JSON.generate({status: 'self_test_passed', controls: controls})
    exit 0
  end
  %i[summary_path summary_sha256 clickhouse helper_path helper_sha256 probe_source probe_source_sha256
     helper_source helper_source_sha256 fixture_source fixture_source_sha256 auditor_source auditor_source_sha256].each do |key|
    raise ArgumentError, "--#{key.to_s.tr('_', '-')} is required" unless options[key]
  end
  result = AuditSchemaWidePartW245::Auditor.new(**options).run
  puts JSON.generate(result)
rescue AuditSchemaWidePartW245::Failure, ArgumentError, KeyError, TypeError => error
  warn error.message
  exit 1
end

main if $PROGRAM_NAME == __FILE__
