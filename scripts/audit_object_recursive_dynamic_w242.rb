#!/usr/bin/env ruby
# Read-only offline auditor for a completed W242 recursive Dynamic capture.
# It authenticates captured files and replays the same literal TSV oracles; it
# never starts ClickHouse, changes a part, or treats SQL-normalized values as
# an actual-type witness.

require 'digest'
require 'json'
require 'optparse'
require_relative 'probe_object_recursive_dynamic_w242'

module AuditObjectRecursiveDynamicW242
  W242 = ProbeObjectRecursiveDynamicW242
  W241 = W242::W241
  RECORD_KEYS = %w[
    argv argv_file argv_sha256 binary_path binary_sha_after binary_sha_before exit expected_binary_sha256
    label max_memory_usage_applicable max_memory_usage_bytes max_threads process_classification process_kind
    required_outer_run_safe_memory_limit_bytes signal spawn_error stderr_bytes stderr_file stderr_read_error
    stderr_sha256 stdin_bytes stdin_file stdin_sha256 stdin_write_error store_path stdout_bytes stdout_file
    stdout_read_error stdout_sha256 termination_grace_seconds timed_out timeout_seconds
  ].freeze
  SUMMARY_KEYS = %w[
    evidence_root fatal_error format interpretation invocations last_stage limits nested_type_oracle
    part_input_snapshots profiles recursive_dynamic_oracle runtime source_capture status tuple_oracle
  ].freeze
  INVOCATION_LABELS = %w[
    w241_target_create w241_attach_check w241_nested_direct_types recursive_crystal_helper
    recursive_generated_create recursive_generated_attach_check recursive_direct_types recursive_full_objects
    tuple_json_array_dynamic_persist tuple_json_array_dynamic_reopen
  ].freeze
  MAX_ARTIFACT_BYTES = 64 * 1024 * 1024

  class Failure < StandardError; end

  class Auditor
    def initialize(summary_path:, summary_sha256:, w241_summary_sha256:, clickhouse:, recursive_helper:, self_test:)
      @summary_path = File.expand_path(summary_path)
      @root = File.dirname(@summary_path)
      @summary_sha256 = checked_sha(summary_sha256, 'W242 summary')
      @w241_sha256 = checked_sha(w241_summary_sha256, 'W241 summary')
      @clickhouse = canonical_executable(clickhouse, 'ClickHouse')
      @recursive_helper = canonical_executable(recursive_helper, 'recursive helper')
      fail!('--self-test is required; the auditor must run its captured-output falsifiers') unless self_test
      fail!('summary path must be <canonical direct child of /private/tmp>/summary.json') unless
        File.basename(@summary_path) == 'summary.json' &&
        File.dirname(@root) == File.realpath('/private/tmp') && File.directory?(@root) &&
        !File.symlink?(@root) && File.realpath(@root) == @root
    end

    def run
      summary_bytes = read_bounded(@summary_path, W242::SUMMARY_MAX_BYTES, 'W242 summary')
      fail!('W242 summary SHA-256 differs from supplied pin') unless Digest::SHA256.hexdigest(summary_bytes) == @summary_sha256
      @summary = parse_json!(summary_bytes, 'W242 summary')
      authenticate_summary!
      initialize_probe!
      authenticate_w241_and_parts!
      authenticate_invocations!
      replay_native_oracles!
      adversarial_controls!
      {
        status: 'raw_capture_authenticated',
        summary_sha256: @summary_sha256,
        w241_summary_sha256: @w241_sha256,
        runtime_sha256: W241::BINARY_SHA256,
        frame_bytes: @summary.fetch('recursive_dynamic_oracle').fetch('requested_frame_bytes'),
        profile_count: W241::PROFILE_IDS.size,
        recursive_part_count: @recursive_parts.size,
        native_invocation_count: INVOCATION_LABELS.size - 1,
        direct_rows: @direct_result.fetch(:direct_rows),
        nested_type_rows: @direct_result.fetch(:typed_rows),
        full_rows: @full_result.fetch(:full_rows),
        controls: @control_results,
        interpretation: 'captured-output mutations are in-memory parser controls only; no on-disk or native mutation was performed',
      }
    end

    private

    def fail!(message)
      raise Failure, "W242 audit: #{message}"
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

    def read_bounded(path, max, label)
      fail!("#{label} is absent, non-regular, or symlinked") unless File.file?(path) && !File.symlink?(path)
      size = File.size(path)
      fail!("#{label} exceeds its byte bound") unless size >= 0 && size <= max
      bytes = File.binread(path)
      fail!("#{label} changed while read") unless bytes.bytesize == size
      bytes
    end

    def parse_json!(bytes, label)
      W242.parse_evidence_json!(bytes, label)
    rescue W242::Failure => error
      fail!(error.message)
    end

    def authenticate_summary!
      fail!('summary key set differs') unless @summary.is_a?(Hash) && @summary.keys.sort == SUMMARY_KEYS.sort
      fail!('summary format/status is not a completed native observation') unless
        @summary['format'] == W242::FORMAT && @summary['status'] == 'native_type_oracle_observed' &&
        @summary['fatal_error'].nil? && @summary['last_stage'] == 'tuple_json_array_dynamic_reopen' &&
        @summary['evidence_root'] == @root
      source = @summary.fetch('source_capture')
      fail!('supplied W241 SHA differs from both embedded W241 pins') unless
        source.is_a?(Hash) && source['w241_summary_sha256'] == @w241_sha256 &&
        source['expected_summary_sha256'] == @w241_sha256
      runtime = @summary.fetch('runtime')
      fail!('runtime identity/path does not match the pinned native binary') unless
        runtime.is_a?(Hash) && runtime['path'] == @clickhouse && runtime['sha256'] == W241::BINARY_SHA256 &&
        runtime['sha256_before'] == W241::BINARY_SHA256 && runtime['sha256_after'] == W241::BINARY_SHA256 &&
        runtime['version'] == W241::VERSION && runtime['build'] == W241::BUILD &&
        Digest::SHA256.file(@clickhouse).hexdigest == W241::BINARY_SHA256
      @w241_root = source.fetch('w241_root')
      fail!('W241 source root is not a canonical direct child of /private/tmp') unless
        @w241_root.is_a?(String) && File.directory?(@w241_root) && !File.symlink?(@w241_root) &&
        File.realpath(@w241_root) == @w241_root && File.dirname(@w241_root) == File.realpath('/private/tmp') &&
        @w241_root != @root
      limits = @summary.fetch('limits')
      fail!('process bounds differ from the frozen one-thread/512MiB profile') unless
        limits == {
          'max_threads' => 1,
          'local_max_memory_usage_bytes' => W241::MEMORY,
          'outer_run_safe_memory_limit_bytes' => W241::OUTER_RUN_SAFE_LIMIT,
          'timeout_seconds' => W241::TIMEOUT,
          'termination_grace_seconds' => W241::GRACE,
        }
      frame = @summary.fetch('recursive_dynamic_oracle').fetch('requested_frame_bytes')
      fail!('requested frame size is outside the closed 32/64 profile') unless [32, 64].include?(frame)
    rescue KeyError, TypeError => error
      fail!("summary fields malformed: #{error.class}: #{error.message}")
    end

    def initialize_probe!
      @probe = W242::Probe.allocate
      {
        :@root => @root,
        :@binary => @clickhouse,
        :@recursive_helper => @recursive_helper,
        :@w241_root => @w241_root,
        :@expected_w241_sha256 => @w241_sha256,
        :@part_inputs => [],
        :@part_snapshots => {},
        :@profiles => [],
        :@recursive_profiles => [],
        :@recursive_parts => [],
        :@recursive_part_snapshots => {},
        :@recursive_substream_calibrated => false,
      }.each { |name, value| @probe.instance_variable_set(name, value) }
      runner = W241::Probe.allocate
      runner.instance_variable_set(:@root, @root)
      runner.instance_variable_set(:@token, Digest::SHA256.hexdigest(@root)[0, 8])
      @probe.instance_variable_set(:@runner, runner)
    end

    def authenticate_w241_and_parts!
      w241_invocations_dir = File.join(@w241_root, 'invocations')
      fail!('W241 invocations directory is absent, symlinked, or noncanonical') unless
        File.directory?(w241_invocations_dir) && !File.symlink?(w241_invocations_dir) &&
        File.realpath(w241_invocations_dir) == w241_invocations_dir
      @probe.send(:authenticate_w241_capture!)
      fail!('W241 summary digest recomputation differs') unless @probe.instance_variable_get(:@w241_summary_sha256) == @w241_sha256
      snapshots = @summary.fetch('part_input_snapshots')
      expected_keys = W241::PROFILE_IDS.flat_map { |id| %w[stock_source crystal_generated].map { |role| "#{id}:#{role}" } }
      fail!('W241 source/attached snapshot roster differs') unless snapshots.is_a?(Hash) && snapshots.keys.sort == expected_keys.sort
      parts = @probe.instance_variable_get(:@part_inputs)
      fail!('authenticated W241 parts do not contain the exact 16-role matrix') unless parts.size == 16
      parts.each do |part|
        id = part.fetch(:profile).fetch(:id)
        role = part.fetch(:role)
        snapshot = snapshots.fetch("#{id}:#{role}")
        fail!("#{id}/#{role} source path differs from authenticated W241 capture") unless snapshot.fetch('source_path') == part.fetch(:path)
        before = normalize_snapshot(snapshot.fetch('before'), "#{id}/#{role} source snapshot")
        fail!("#{id}/#{role} source files changed since W242 capture") unless @probe.send(:part_snapshot, part.fetch(:path)) == before
        attached_path = snapshot.fetch('attached_path')
        canonical_store_path(attached_path, File.join(@root, 'stores', 'w241'), "#{id}/#{role} attached")
        attached_before = normalize_snapshot(snapshot.fetch('attached_before'), "#{id}/#{role} attached snapshot")
        fail!("#{id}/#{role} attached files changed since W242 capture") unless @probe.send(:part_snapshot, attached_path) == attached_before
        @probe.send(:attached_snapshot_matches?, before, attached_path)
        part[:table] = @probe.send(:table_name, id, role == 'stock_source' ? 'source' : 'generated')
        part[:copied_snapshot] = before
        part[:attached_path] = attached_path
        part[:attached_snapshot] = attached_before
      end
      @probe.instance_variable_set(:@part_snapshots, snapshots.each_with_object({}) do |(key, value), result|
        result[key] = {source_path: value.fetch('source_path'), before: normalize_snapshot(value.fetch('before'), key)}
      end)

      helper_profiles = @probe.instance_variable_get(:@helper_data).fetch('profiles')
      parts.each do |part|
        helper_profile = helper_profiles.find { |entry| entry.fetch('id') == part.fetch(:profile).fetch(:id) }
        part[:helper_read] = helper_profile.fetch(part.fetch(:role) == 'stock_source' ? 'source_read' : 'generated_read')
      end
      @w241_part_inputs = parts
      true
    rescue KeyError, TypeError => error
      fail!("W241 source/part authentication failed: #{error.class}: #{error.message}")
    end

    def normalize_snapshot(raw, label)
      fail!("#{label} malformed") unless raw.is_a?(Array)
      normalized = raw.map do |entry|
        fail!("#{label} entry malformed") unless entry.is_a?(Array) && entry.size == 3
        name, size, sha = entry
        fail!("#{label} contains unsafe file name") unless name.is_a?(String) && /\A[a-zA-Z0-9_.-]+\z/.match?(name)
        fail!("#{label} contains malformed size/digest") unless size.is_a?(Integer) && size >= 0 && sha.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(sha)
        [name, size, sha]
      end
      fail!("#{label} has duplicate or unsorted paths") unless normalized.map(&:first) == normalized.map(&:first).sort && normalized.map(&:first).uniq == normalized.map(&:first)
      normalized
    end

    def canonical_store_path(path, store, label)
      fail!("#{label} path escaped its expected store") unless path.is_a?(String) && path.start_with?(store + File::SEPARATOR) &&
        File.expand_path(path) == path && File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path
      current = store
      path.delete_prefix(store + File::SEPARATOR).split(File::SEPARATOR).each do |component|
        current = File.join(current, component)
        fail!("#{label} path contains a symlink") if File.symlink?(current)
      end
      path
    end

    def authenticate_invocations!
      invocations_dir = File.join(@root, 'invocations')
      fail!('invocations directory is absent, symlinked, or noncanonical') unless
        File.directory?(invocations_dir) && !File.symlink?(invocations_dir) && File.realpath(invocations_dir) == invocations_dir
      records = @summary.fetch('invocations')
      fail!('invocation labels/order differ from the ten-stage capture') unless records.is_a?(Array) && records.map { |r| r.fetch('label') } == INVOCATION_LABELS
      fail!('recursive helper executable differs from CLI path') unless @recursive_helper == File.realpath(@recursive_helper)
      fail!('helper source SHA differs from frozen implementation') unless
        File.file?(File.join(__dir__, 'check_object_recursive_dynamic_w242.cr')) &&
        Digest::SHA256.file(File.join(__dir__, 'check_object_recursive_dynamic_w242.cr')).hexdigest == W242::RECURSIVE_HELPER_SOURCE_SHA256
      @records = records.each_with_object({}) { |record, map| map[record.fetch('label')] = record }
      expected_sql = expected_sql_by_label
      records.each do |record|
        label = record.fetch('label')
        fail!("#{label} record key set differs") unless record.is_a?(Hash) && record.keys.sort == RECORD_KEYS.sort
        validate_invocation_record!(record, label, expected_sql.fetch(label, nil))
      end
      rd = @summary.fetch('recursive_dynamic_oracle')
      fail!('embedded helper invocation differs from top-level captured process record') unless rd.fetch('helper_invocation') == @records.fetch('recursive_crystal_helper')
      %w[direct_oracle full_oracle].each do |field|
        oracle = rd.fetch(field)
        label = field == 'direct_oracle' ? 'recursive_direct_types' : 'recursive_full_objects'
        fail!("#{field} is not joined to its exact invocation") unless oracle.fetch('invocation') == label && oracle.fetch('invocation_record') == @records.fetch(label)
      end
      true
    rescue KeyError, TypeError => error
      fail!("invocation roster malformed: #{error.class}: #{error.message}")
    end

    def validate_invocation_record!(record, label, expected_sql)
      fail!("#{label} is not a clean successful process") unless record['process_classification'] == 'success' &&
        record['exit'] == 0 && record['signal'].nil? && record['timed_out'] == false &&
        %w[spawn_error stdin_write_error stdout_read_error stderr_read_error].all? { |key| record[key].nil? } &&
        record['stderr_bytes'] == 0 && record['stderr_sha256'] == Digest::SHA256.hexdigest('')
      %w[argv_file stdin_file stdout_file stderr_file].each do |key|
        name = record.fetch(key)
        fail!("#{label} #{key} basename is unsafe") unless name.is_a?(String) && File.basename(name) == name && /\A[a-zA-Z0-9_.-]+\z/.match?(name)
      end
      %w[argv_file stdin_file stdout_file stderr_file].each do |key|
        sha_key = {'argv_file' => 'argv_sha256', 'stdin_file' => 'stdin_sha256', 'stdout_file' => 'stdout_sha256', 'stderr_file' => 'stderr_sha256'}.fetch(key)
        size_key = {'stdin_file' => 'stdin_bytes', 'stdout_file' => 'stdout_bytes', 'stderr_file' => 'stderr_bytes'}[key]
        bytes = read_bounded(File.join(@root, 'invocations', record.fetch(key)), MAX_ARTIFACT_BYTES, "#{label} #{key}")
        fail!("#{label} #{key} SHA-256 differs") unless Digest::SHA256.hexdigest(bytes) == record.fetch(sha_key)
        fail!("#{label} #{key} size differs") if size_key && bytes.bytesize != record.fetch(size_key)
        instance_variable_set("@#{label}_#{key.sub('_file', '')}_bytes", bytes)
      end
      record_file = File.join(@root, 'invocations', "#{label}.json")
      record_bytes = read_bounded(record_file, MAX_ARTIFACT_BYTES, "#{label} process-record artifact")
      fail!("#{label} process-record artifact differs from the pinned summary record") unless
        parse_json!(record_bytes, "#{label} process-record artifact") == record
      fail!("#{label} artifact names differ from stem-derived names") unless
        record['argv_file'] == "#{label}.argv.json" && record['stdin_file'] == "#{label}.#{label == 'recursive_crystal_helper' ? 'stdin.bin' : 'stdin.sql'}" &&
        record['stdout_file'] == "#{label}.stdout" && record['stderr_file'] == "#{label}.stderr"
      argv_bytes = instance_variable_get("@#{label}_argv_bytes")
      argv = parse_json!(argv_bytes, "#{label} argv artifact")
      fail!("#{label} argv artifact differs from summary") unless argv == record.fetch('argv')
      fail!("#{label} argv must be a closed string array") unless argv.is_a?(Array) && argv.all? { |item| item.is_a?(String) }
      stdout = instance_variable_get("@#{label}_stdout_bytes")
      fail!("#{label} process stderr is not empty") unless instance_variable_get("@#{label}_stderr_bytes").empty?
      fail!("#{label} stdout exceeds its record bound") unless stdout.bytesize == record.fetch('stdout_bytes')

      if label == 'recursive_crystal_helper'
        validate_helper_record!(record, argv, expected_sql)
      else
        validate_native_record!(record, label, argv, expected_sql)
        pin_rows = @probe.send(:tagged_rows, stdout, W242::PIN_TAG, 3)
        fail!("#{label} actual stdout does not contain exactly the pinned runtime marker") unless pin_rows == [[W242::PIN_TAG, W241::VERSION, W241::BUILD]]
      end
    rescue KeyError, TypeError, JSON::ParserError => error
      fail!("#{label} artifact validation failed: #{error.class}: #{error.message}")
    end

    def validate_native_record!(record, label, argv, expected_sql)
      expected_store = if %w[w241_target_create w241_attach_check w241_nested_direct_types].include?(label)
                         File.join(@root, 'stores', 'w241')
                       elsif %w[recursive_generated_create recursive_generated_attach_check recursive_direct_types recursive_full_objects].include?(label)
                         File.join(@root, 'stores', 'recursive')
                       else
                         File.join(@root, 'stores', 'tuple')
                       end
      expected_argv = [@clickhouse, 'local', '--path', expected_store, '--session_timezone=UTC', '--max_threads=1',
                       "--max_memory_usage=#{W241::MEMORY}", '--multiquery']
      fail!("#{label} argv/store/process bounds differ") unless record['process_kind'] == 'clickhouse-local' && argv == expected_argv &&
        record['store_path'] == expected_store && record['max_threads'] == 1 &&
        record['max_memory_usage_bytes'] == W241::MEMORY && record['max_memory_usage_applicable'] == true &&
        record['timeout_seconds'] == W241::TIMEOUT && record['termination_grace_seconds'] == W241::GRACE &&
        record['required_outer_run_safe_memory_limit_bytes'] == W241::OUTER_RUN_SAFE_LIMIT &&
        record['binary_path'] == @clickhouse && record['expected_binary_sha256'] == W241::BINARY_SHA256 &&
        record['binary_sha_before'] == W241::BINARY_SHA256 && record['binary_sha_after'] == W241::BINARY_SHA256
      fail!("#{label} has no independently reconstructed SQL") unless expected_sql.is_a?(String)
      stdin = instance_variable_get("@#{label}_stdin_bytes")
      fail!("#{label} captured SQL differs from exact source-literal query") unless stdin == expected_sql.b
      fail!("#{label} stdin is not UTF-8 SQL") unless stdin.dup.force_encoding(Encoding::UTF_8).valid_encoding?
    end

    def validate_helper_record!(record, argv, _expected_sql)
      rd = @summary.fetch('recursive_dynamic_oracle')
      expected_argv = [@recursive_helper, File.join(@root, 'invocations', 'recursive_helper_input.json'), rd.fetch('output_root')]
      fail!('helper invocation argv/limits/source pin differ') unless record['process_kind'] == 'crystal-helper' && argv == expected_argv &&
        record['store_path'].nil? && record['max_threads'].nil? && record['max_memory_usage_bytes'].nil? &&
        record['max_memory_usage_applicable'] == false && record['timeout_seconds'] == W241::TIMEOUT &&
        record['termination_grace_seconds'] == W241::GRACE &&
        record['required_outer_run_safe_memory_limit_bytes'] == W241::OUTER_RUN_SAFE_LIMIT &&
        record['binary_path'] == @recursive_helper && record['expected_binary_sha256'] == rd.fetch('helper_executable_sha256_before') &&
        record['binary_sha_before'] == rd.fetch('helper_executable_sha256_before') &&
        record['binary_sha_after'] == rd.fetch('helper_executable_sha256_after') &&
        Digest::SHA256.file(@recursive_helper).hexdigest == rd.fetch('helper_executable_sha256_before') &&
        rd.fetch('helper_executable_sha256_before') == rd.fetch('helper_executable_sha256_after')
      input_bytes = read_bounded(expected_argv[1], W242::RECURSIVE_INPUT_MAX_BYTES, 'recursive helper input')
      input = parse_json!(input_bytes, 'recursive helper input')
      fail!('recursive helper input bytes do not equal the closed captured profile request') unless
        input == rd.fetch('helper_input') && Digest::SHA256.hexdigest(input_bytes) == rd.fetch('helper_input_sha256')
      fail!('helper stdout is not empty input-bound JSON') unless record['stdin_bytes'] == 0 &&
        instance_variable_get('@recursive_crystal_helper_stdin_bytes').empty?
      helper_stdout = instance_variable_get('@recursive_crystal_helper_stdout_bytes')
      lines = helper_stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      fail!('helper must emit exactly one UTF-8 JSON object') unless lines.size == 1 && !lines.first.empty?
      data = parse_json!(lines.first, 'recursive helper stdout')
      fail!('embedded helper output differs from captured stdout') unless data == rd.fetch('helper_output')
      helper_source = File.expand_path('check_object_recursive_dynamic_w242.cr', __dir__)
      fail!('helper source path or frozen SHA differs') unless rd.fetch('helper_source') == helper_source &&
        rd.fetch('helper_source_sha256') == W242::RECURSIVE_HELPER_SOURCE_SHA256 &&
        Digest::SHA256.file(helper_source).hexdigest == W242::RECURSIVE_HELPER_SOURCE_SHA256
      true
    end

    def invocation_stdout(label)
      instance_variable_get("@#{label}_stdout_bytes").dup.force_encoding(Encoding::UTF_8)
    end

    def verify_target_path_rows!(stdout, parts, tag, field_count, store, recursive)
      rows = @probe.send(:tagged_rows, stdout, tag, field_count)
      fail!('native table-path roster count differs') unless rows.size == parts.size
      by_name = {}
      rows.each do |row|
        name = recursive ? row[2] : row[1]
        path = recursive ? row[3] : row[2]
        fail!('native table-path rows contain duplicate names') if by_name.key?(name)
        by_name[name] = @probe.send(:canonical_store_path, path, store)
      end
      expected = parts.map { |part| part.fetch(:table) }.sort
      fail!('native table-path identity roster differs') unless by_name.keys.sort == expected
      true
    end

    def prepare_recursive_parts!
      rd = @summary.fetch('recursive_dynamic_oracle')
      helper_data = rd.fetch('helper_output')
      input_bytes = read_bounded(File.join(@root, 'invocations', 'recursive_helper_input.json'),
                                 W242::RECURSIVE_INPUT_MAX_BYTES, 'recursive helper input')
      frame = rd.fetch('requested_frame_bytes')
      fail!('requested frame differs between helper and capture') unless frame == @summary.fetch('recursive_dynamic_oracle').fetch('requested_frame_bytes')
      @probe.send(:validate_recursive_helper_output!, helper_data, input_bytes, rd.fetch('output_root'), frame)
      profiles = @probe.instance_variable_get(:@recursive_profiles)
      @recursive_parts = profiles.flat_map do |profile_record|
        %w[normal type_only].map do |role|
          helper_part = profile_record.fetch(:data).fetch("#{role}_part")
          part = {
            profile: profile_record.fetch(:profile), profile_id: profile_record.fetch(:profile).fetch(:id),
            role: role, helper_part: helper_part, path: helper_part.fetch('path'),
          }
          part[:table] = @probe.send(:recursive_table_name, part.fetch(:profile_id), role)
          part[:source_snapshot] = @probe.send(:part_snapshot, part.fetch(:path))
          part[:copied_snapshot] = part.fetch(:source_snapshot)
          part
        end
      end
      fail!('recursive helper did not authenticate exactly 16 generated parts') unless @recursive_parts.size == 16
      create_stdout = invocation_stdout('recursive_generated_create')
      verify_target_path_rows!(create_stdout, @recursive_parts, W242::RECURSIVE_PATH_TAG, 4,
                               File.join(@root, 'stores', 'recursive'), true)
      @probe.instance_variable_set(:@recursive_parts, @recursive_parts)
      @probe.instance_variable_set(:@recursive_part_snapshots, {})
      @probe.send(:verify_recursive_attached_parts!, invocation_stdout('recursive_generated_attach_check'))
      true
    end

    def replay_native_oracles!
      verify_target_path_rows!(invocation_stdout('w241_target_create'), @w241_part_inputs,
                               '__W242_PATH__', 3, File.join(@root, 'stores', 'w241'), false)
      attach_sql = invocation_stdout('w241_attach_check')
      # Recheck the native part table schema/CHECK against actual source and active attached files.
      @probe.send(:verify_attached_parts!, attach_sql)
      @w241_part_inputs.each do |part|
        id = part.fetch(:profile).fetch(:id)
        snapshot = @summary.fetch('part_input_snapshots').fetch("#{id}:#{part.fetch(:role)}")
        fail!('W241 attached path changed from the captured active part') unless
          part.fetch(:attached_path) == snapshot.fetch('attached_path')
      end
      @nested_result = @probe.send(:validate_nested_type_oracle_output!, invocation_stdout('w241_nested_direct_types'),
                                   invocation_label: 'w241_nested_direct_types')
      @probe.instance_variable_set(:@recursive_parts, [])
      prepare_recursive_parts!
      @direct_result = @probe.send(:validate_recursive_direct_oracle!, invocation_stdout('recursive_direct_types'))
      @full_result = @probe.send(:validate_recursive_full_oracle!, invocation_stdout('recursive_full_objects'))

      suffix = Digest::SHA256.hexdigest(@root)[0, 8]
      tuple_table = "w242_#{suffix}_tuple"
      deep_table = "w242_#{suffix}_deep"
      @probe.send(:validate_tuple_persist!, invocation_stdout('tuple_json_array_dynamic_persist'), tuple_table, deep_table)
      reopen = invocation_stdout('tuple_json_array_dynamic_reopen')
      tuple_rows = @probe.send(:tagged_rows, reopen, W242::TUPLE_TAG, 10)
      deep_rows = @probe.send(:tagged_rows, reopen, W242::DEEP_TAG, 8)
      @probe.send(:validate_tuple_rows!, tuple_rows)
      @probe.send(:validate_deep_rows!, deep_rows)
      nested_projection = JSON.parse(JSON.generate(@probe.instance_variable_get(:@nested_query)))
      fail!('summary nested oracle differs from replayed raw stdout') unless @summary.fetch('nested_type_oracle') == nested_projection
      tuple_summary = @summary.fetch('tuple_oracle')
      fail!('tuple oracle discriminator/result differs from replayed raw stdout') unless
        tuple_summary['table'] == tuple_table && tuple_summary['deep_table'] == deep_table &&
        tuple_summary['persisted_invocation'] == 'tuple_json_array_dynamic_persist' &&
        tuple_summary['reopened_invocation'] == 'tuple_json_array_dynamic_reopen' &&
        tuple_summary['rows'] == tuple_rows && tuple_summary['deep_site_rows'] == deep_rows
      @probe.send(:assert_unchanged_inputs!)
      true
    rescue KeyError, TypeError => error
      fail!("raw native oracle replay failed: #{error.class}: #{error.message}")
    end

    def expected_sql_by_label
      result = {}
      native_prefix = lambda do |stage|
        [@probe.instance_variable_get(:@runner).send(:pin_sql), 'SET print_pretty_type_names=0;',
         'SET output_format_json_quote_64bit_integers=0;', stage].join("\n")
      end
      w241_tables = []
      @w241_part_inputs.each do |part|
        id = part.fetch(:profile).fetch(:id)
        role = part.fetch(:role)
        name = part.fetch(:table)
        profile = part.fetch(:profile)
        pk = W241.part_pk_type!(profile, role == 'stock_source' ? 'stock source' : 'Crystal generated')
        w241_tables << [id, role, name, profile, pk]
      end
      creates = w241_tables.map do |_id, _role, table, profile, pk|
        "CREATE TABLE default.#{table} (pk #{pk}, doc #{W241::W240::TYPE}) ENGINE=MergeTree ORDER BY pk SETTINGS #{@probe.instance_variable_get(:@runner).send(:settings, profile)};"
      end
      names = w241_tables.map { |row| "'#{row[2]}'" }
      creates << "SELECT '__W242_PATH__', name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name IN (#{names.join(',')}) ORDER BY name FORMAT TSVRaw;"
      result['w241_target_create'] = native_prefix.call(creates.join("\n"))

      statements = []
      w241_tables.each do |id, role, table, _profile, _pk|
        statements << "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0';"
        statements << "SELECT '__W242_CHECK_BEGIN__', '#{id}', '#{role}' FORMAT TSVRaw;"
        statements << "CHECK TABLE default.#{table} FORMAT TSV;"
        statements << "SELECT '__W242_CHECK_END__', '#{id}', '#{role}' FORMAT TSVRaw;"
        statements << "SELECT '__W242_SCHEMA__', '#{id}', '#{role}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;"
        statements << "SELECT '__W242_PART__', '#{id}', '#{role}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;"
      end
      result['w241_attach_check'] = native_prefix.call(statements.join("\n"))

      nested = []
      @w241_part_inputs.each do |part|
        id = part.fetch(:profile).fetch(:id)
        fail!('W241 part profile id disagrees with its authenticated role record') unless id == part.fetch(:profile_id)
        role, table = part.values_at(:role, :table)
        human_role = role == 'stock_source' ? 'stock source' : 'Crystal generated'
        nested_witnesses = part.fetch(:helper_read).fetch('nested_type_witnesses')
        %w[arr late].each do |path|
          value_type = nested_witnesses.map { |w| w.fetch('paths').fetch(path, nil) }.compact.first.fetch('outer_type')
          nested << "SELECT '__W242_PATH__', '#{id}', '#{human_role}', '#{path}', toString(pk), toTypeName(doc.#{path}), if(isNull(doc.#{path}), 'NULL', dynamicType(doc.#{path})), if(isNull(doc.#{path}), '6e756c6c', hex(toJSONString(doc.#{path}))) FROM default.#{table} ORDER BY pk FORMAT TSVRaw;"
          fields = W242::CHILD_FIELDS.fetch(path)
          expression = "dynamicElement(doc.#{path}, #{@probe.send(:sql_quote, value_type)})"
          first_actual = role == 'stock_source' ? "dynamicType(child.#{fields[0]})" : "toTypeName(child.#{fields[0]})"
          second_actual = "dynamicType(child.#{fields[1]})"
          nested << "SELECT '__W242_CHILD__', '#{id}', '#{human_role}', '#{path}', toString(pk), toTypeName(child), hex(toJSONString(child)), hex(toJSONString(JSONAllPathsWithTypes(child))), toTypeName(child.#{fields[0]}), #{first_actual}, toTypeName(child.#{fields[1]}), #{second_actual} FROM default.#{table} ARRAY JOIN #{expression} AS child ORDER BY pk, hex(toJSONString(child)) FORMAT TSVRaw;"
        end
      end
      result['w241_nested_direct_types'] = native_prefix.call(nested.join("\n"))

      recursive_parts = recursive_part_context_from_summary
      recursive_creates = []
      names = []
      recursive_parts.each do |part|
        id, role, table, profile = part.values_at(:profile_id, :role, :table, :profile)
        recursive_creates << "CREATE TABLE default.#{table} (pk UInt64, doc #{W241::STOCK_TYPE}) ENGINE=MergeTree ORDER BY pk SETTINGS #{@probe.instance_variable_get(:@runner).send(:settings, profile)};"
        names << "'#{table}'"
      end
      recursive_creates << "SELECT '__W242_RECURSIVE_PATH__', database, name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name IN (#{names.join(',')}) ORDER BY name FORMAT TSVRaw;"
      result['recursive_generated_create'] = native_prefix.call(recursive_creates.join("\n"))

      attach = []
      recursive_parts.each do |part|
        id, role, table = part.values_at(:profile_id, :role, :table)
        attach << "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0';"
        attach << "SELECT '__W242_CHECK_BEGIN__', '#{id}', '#{role}' FORMAT TSVRaw;"
        attach << "CHECK TABLE default.#{table} FORMAT TSV;"
        attach << "SELECT '__W242_CHECK_END__', '#{id}', '#{role}' FORMAT TSVRaw;"
        attach << "SELECT '__W242_RECURSIVE_SCHEMA__', '#{id}', '#{role}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;"
        attach << "SELECT '__W242_RECURSIVE_PART__', '#{id}', '#{role}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;"
      end
      result['recursive_generated_attach_check'] = native_prefix.call(attach.join("\n"))

      direct_sql = []
      recursive_parts.each do |part|
        payload = 'doc.payload'
        tuple = "assumeNotNull(dynamicElement(doc.payload, #{@probe.send(:sql_quote, W242::RECURSIVE_ACTUAL_TYPE)}))"
        direct_fields = ["toTypeName(#{payload})", "if(isNull(#{payload}), 'NULL', dynamicType(#{payload}))",
                         "if(isNull(#{payload}), 'NULL', hex(toJSONString(#{payload})))"].join(', ')
        direct_sql << @probe.send(:recursive_base_select, W242::RECURSIVE_DIRECT_TAG, part, direct_fields)
        direct_sql << @probe.send(:recursive_base_select, W242::RECURSIVE_DIRECT_MIDDLE_TAG, part, direct_fields, 'pk BETWEEN 3 AND 6')
        direct_sql << @probe.send(:recursive_base_select, W242::RECURSIVE_DIRECT_LAST_TAG, part, direct_fields, 'pk BETWEEN 7 AND 8')
        type_fields = [
          "toTypeName(#{payload})", "dynamicType(#{payload})", "toTypeName(#{tuple})", "toTypeName(#{tuple}.1)",
          "hex(toJSONString(JSONAllPathsWithTypes(#{tuple}.1)))", "hex(toJSONString(#{tuple}.1))", "toTypeName(#{tuple}.2)",
          "hex(toJSONString(arrayMap(x -> toTypeName(x), #{tuple}.2)))",
          "hex(toJSONString(arrayMap(x -> if(isNull(x), 'NULL', dynamicType(x)), #{tuple}.2)))",
          "hex(toJSONString(#{tuple}.2))",
        ].join(', ')
        direct_sql << @probe.send(:recursive_base_select, W242::RECURSIVE_DIRECT_TYPE_TAG, part, type_fields, 'isNotNull(doc.payload)')
      end
      result['recursive_direct_types'] = native_prefix.call(direct_sql.join("\n"))

      full_sql = []
      recursive_parts.each do |part|
        fields = 'toTypeName(doc), hex(toJSONString(doc))'
        full_sql << @probe.send(:recursive_base_select, W242::RECURSIVE_FULL_TAG, part, fields)
        full_sql << @probe.send(:recursive_base_select, W242::RECURSIVE_FULL_MIDDLE_TAG, part, fields, 'pk BETWEEN 3 AND 6')
        full_sql << @probe.send(:recursive_base_select, W242::RECURSIVE_FULL_LAST_TAG, part, fields, 'pk BETWEEN 7 AND 8')
      end
      result['recursive_full_objects'] = native_prefix.call(full_sql.join("\n"))

      tuple_settings = [
        'index_granularity=2', 'index_granularity_bytes=10485760', 'enable_mixed_granularity_parts=1',
        'min_rows_for_wide_part=0', 'min_bytes_for_wide_part=0', 'compress_marks=0', 'compress_primary_key=0',
        'min_compress_block_size=0', 'max_compress_block_size=4096', "default_compression_codec='LZ4'",
        "dynamic_serialization_version='v3'", "object_serialization_version='v3'",
        'propagate_types_serialization_versions_to_nested_types=true',
      ].join(', ')
      suffix = Digest::SHA256.hexdigest(@root)[0, 8]
      tuple_table = "w242_#{suffix}_tuple"
      deep_table = "w242_#{suffix}_deep"
      tuple_sql = [
        "CREATE TABLE default.#{tuple_table} (pk UInt64, d #{W242::DYNAMIC_COLUMN}) ENGINE=MergeTree ORDER BY pk SETTINGS #{tuple_settings};",
        @probe.send(:persisted_tuple_insert_sql, tuple_table),
        "CREATE TABLE default.#{deep_table} (pk UInt64, d #{W242::DYNAMIC_COLUMN}) ENGINE=MergeTree ORDER BY pk SETTINGS #{tuple_settings};",
        @probe.send(:persisted_deep_insert_sql, deep_table),
      ]
      [tuple_table, deep_table].each do |table|
        tuple_sql << "SELECT '__W242_CHECK_BEGIN__', '#{table}', '' FORMAT TSVRaw;"
        tuple_sql << "CHECK TABLE default.#{table} FORMAT TSV;"
        tuple_sql << "SELECT '__W242_CHECK_END__', '#{table}', '' FORMAT TSVRaw;"
        tuple_sql << "SELECT '__W242_SCHEMA__', '#{table}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;"
        tuple_sql << "SELECT '__W242_PART__', '#{table}', name, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;"
      end
      result['tuple_json_array_dynamic_persist'] = native_prefix.call(tuple_sql.join("\n"))
      result['tuple_json_array_dynamic_reopen'] = native_prefix.call([@probe.send(:tuple_reopen_sql, tuple_table), @probe.send(:deep_reopen_sql, deep_table)].join("\n"))
      result
    end

    def recursive_part_context_from_summary
      profile_map = W241::PROFILES.each_with_object({}) { |profile, map| map[profile.fetch(:id)] = profile }
      W241::PROFILE_IDS.flat_map do |id|
        %w[normal type_only].map do |role|
          {profile_id: id, role: role, profile: profile_map.fetch(id),
           table: @probe.send(:recursive_table_name, id, role)}
        end
      end
    end

    def adversarial_controls!
      helper_stdout = instance_variable_get('@recursive_crystal_helper_stdout_bytes')
      summary_bytes = read_bounded(@summary_path, W242::SUMMARY_MAX_BYTES, 'W242 summary self-test input')
      duplicate_top = helper_stdout.sub(/\A\{/, '{"format":"forged",')
      duplicate_nested = helper_stdout.sub('"normal_part":', '"normal_part":null,"normal_part":')
      fail!('cannot construct duplicate-key self-test mutations from helper output') if
        duplicate_top == helper_stdout || duplicate_nested == helper_stdout
      fail!('ordinary JSON parser no longer demonstrates last-key-wins on self-test') unless
        JSON.parse(duplicate_top)['format'] == W242::RECURSIVE_HELPER_FORMAT
      strict_top_rejected = strict_json_mutant_rejected?(duplicate_top, 'duplicate top-level helper key')
      strict_nested_rejected = strict_json_mutant_rejected?(duplicate_nested, 'duplicate nested helper key')
      summary_duplicate = summary_bytes.sub(/\A\{/, '{"format":"forged",')
      strict_summary_rejected = strict_json_mutant_rejected?(summary_duplicate, 'duplicate summary key')

      direct_stdout = invocation_stdout('recursive_direct_types')
      normal_row = direct_stdout.lines.find do |line|
        line.start_with?(W242::RECURSIVE_DIRECT_TYPE_TAG + "\tmap_s0\tnormal\t1\t")
      end
      fail!('captured direct oracle lacks the type-only discriminator row') unless normal_row
      fields = normal_row.chomp.split("\t", -1)
      fail!('captured discriminator row shape differs') unless fields.size == 14 &&
        @probe.send(:parse_json_hex!, fields[12], 'self-test nested actual types') == %w[Int64 String]
      old_values = fields.values_at(8, 9, 13)
      fields[12] = JSON.generate(%w[UInt8 String]).unpack1('H*')
      type_mutant = direct_stdout.sub(normal_row, fields.join("\t") + "\n")
      fail!('type-only mutation unexpectedly changed normalized values') unless fields.values_at(8, 9, 13) == old_values
      type_mutant_rejected = validator_mutant_rejected?(type_mutant, 'same-value Int64-to-UInt8 actual-type mutation')

      direct_lines = direct_stdout.lines
      direct_index = direct_lines.index { |line| line.start_with?(W242::RECURSIVE_DIRECT_TAG + "\t") }
      fail!('captured direct oracle has no direct value row') unless direct_index
      duplicate_row = direct_stdout + direct_lines.fetch(direct_index)
      duplicate_row_rejected = validator_mutant_rejected?(duplicate_row, 'duplicate direct row')
      missing_lines = direct_lines.dup
      missing_lines.delete_at(direct_index)
      missing_row_rejected = validator_mutant_rejected?(missing_lines.join, 'missing direct row')

      @control_results = {
        duplicate_top_level_helper_key_rejected: strict_top_rejected,
        duplicate_nested_helper_key_rejected: strict_nested_rejected,
        duplicate_summary_key_rejected: strict_summary_rejected,
        same_value_int64_to_uint8_type_witness_rejected: type_mutant_rejected,
        duplicate_direct_row_rejected: duplicate_row_rejected,
        missing_direct_row_rejected: missing_row_rejected,
        mutation_scope: 'decoded captured-output mutations in memory only; no native or on-disk mutation',
      }
      failed_controls = @control_results.reject { |key, value| key == :mutation_scope || value == true }.keys
      fail!("adversarial controls did not reject every required mutant: #{failed_controls.join(', ')}") unless failed_controls.empty?
      true
    end

    def strict_json_mutant_rejected?(bytes, label)
      W242.parse_evidence_json!(bytes, label)
      false
    rescue W242::Failure
      true
    end

    def validator_mutant_rejected?(stdout, label)
      @probe.send(:validate_recursive_direct_oracle!, stdout)
      false
    rescue W242::Failure
      true
    end
  end
end

def main
  options = {}
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/audit_object_recursive_dynamic_w242.rb --summary PATH --summary-sha256 SHA --w241-summary-sha256 SHA --clickhouse PATH --recursive-helper PATH --self-test'
    parser.on('--summary PATH') { |value| options[:summary] = value }
    parser.on('--summary-sha256 SHA') { |value| options[:summary_sha256] = value }
    parser.on('--w241-summary-sha256 SHA') { |value| options[:w241_sha256] = value }
    parser.on('--clickhouse PATH') { |value| options[:clickhouse] = value }
    parser.on('--recursive-helper PATH') { |value| options[:recursive_helper] = value }
    parser.on('--self-test') { options[:self_test] = true }
  end.parse!
  required = %i[summary summary_sha256 w241_sha256 clickhouse recursive_helper self_test]
  missing = required.reject { |key| options.key?(key) }
  raise "required options missing: #{missing.join(', ')}" unless missing.empty?
  result = AuditObjectRecursiveDynamicW242::Auditor.new(
    summary_path: options.fetch(:summary), summary_sha256: options.fetch(:summary_sha256),
    w241_summary_sha256: options.fetch(:w241_sha256), clickhouse: options.fetch(:clickhouse),
    recursive_helper: options.fetch(:recursive_helper), self_test: options.fetch(:self_test)
  ).run
  puts JSON.pretty_generate(result)
rescue AuditObjectRecursiveDynamicW242::Failure => error
  warn error.message
  exit 1
end

main if $PROGRAM_NAME == __FILE__
