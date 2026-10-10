#!/usr/bin/env ruby
# Offline auditor for a single W244 generated-part/native-read capture. It
# authenticates raw invocation and part artifacts, replays the literal native
# witnesses, and never launches ClickHouse or mutates captured data.

require 'digest'
require 'find'
require 'json'
require 'optparse'
require_relative 'probe_object_nested_dynamic_json_w244'

module AuditObjectNestedDynamicJSONW244
  W244 = ProbeObjectNestedDynamicJSONW244
  W241 = W244::W241
  SUMMARY_KEYS = %w[
    attachment evidence_root fatal_error format frame_bytes helper helper_output_sha256
    helper_sha256_after helper_sha256_before helper_source_sha256_after helper_source_sha256_before
    invocations native_observations part physical_mark_tuples profile_id runtime scope status
  ].freeze
  HELPER_KEYS = %w[
    helper_executable_sha256 helper_source_sha256 input_path input_sha256 invocation_label output_sha256
  ].freeze
  PROCESS_KEYS = %w[
    argv argv_file argv_sha256 binary_path binary_sha_after binary_sha_before exit expected_binary_sha256
    label max_memory_usage_applicable max_memory_usage_bytes max_threads process_classification process_kind
    required_outer_run_safe_memory_limit_bytes signal spawn_error stderr_bytes stderr_file stderr_read_error
    stderr_sha256 stdin_bytes stdin_file stdin_sha256 stdin_write_error store_path stdout_bytes stdout_file
    stdout_read_error stdout_sha256 termination_grace_seconds timed_out timeout_seconds
  ].freeze
  LABELS = %w[
    crystal_helper native_create_table native_attach_check native_type_values native_inner_json_child
    native_full_rows native_mark_windows native_query_column_placement_diagnostic
  ].freeze
  MAX_ARTIFACT_BYTES = 64 * 1024 * 1024
  PIN_TAG = '__W241_PIN__'.freeze

  class Failure < StandardError; end

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
      @clickhouse = canonical_file(clickhouse, 'ClickHouse')
      @helper_path = canonical_file(helper_path, 'W244 helper executable')
      @helper_sha256 = checked_sha(helper_sha256, 'helper executable')
      @helper_source_sha256 = checked_sha(helper_source_sha256, 'helper source')
      fail!('--self-test is required for a capture audit') unless self_test
      fail!('summary must be summary.json in a canonical direct child of /private/tmp') unless
        File.basename(@summary_path) == 'summary.json' && File.directory?(@root) && !File.symlink?(@root) &&
        File.realpath(@root) == @root && File.dirname(@root) == File.realpath('/private/tmp')
    end

    def run
      summary_bytes = read_bounded(@summary_path, MAX_ARTIFACT_BYTES, 'summary')
      @summary = parse_json!(summary_bytes, 'summary')
      same!(Digest::SHA256.hexdigest(summary_bytes), @summary_sha256, 'summary SHA-256 differs from supplied pin')
      authenticate_invocations_directory!
      authenticate_summary!
      authenticate_helper_and_part!
      authenticate_physical_marks!
      authenticate_processes!
      authenticate_attachment!
      replay_native_outputs!
      controls = self_test!
      {
        status: 'raw_capture_authenticated',
        summary_sha256: @summary_sha256,
        clickhouse_sha256: W241::BINARY_SHA256,
        helper_sha256: @helper_sha256,
        helper_source_sha256: @helper_source_sha256,
        profile_id: 'advanced_s0',
        frame_bytes: W244::FRAME_BYTES,
        part_file_count: @source_snapshot.size,
        physical_mark_file_count: @physical_marks.size,
        physical_mark_rows_with_eof: W244::MARK_ROWS_WITH_EOF,
        native_invocation_count: LABELS.size - 1,
        rows: W244::ROW_COUNT,
        controls: controls,
        interpretation: 'Only this library-written advanced_s0 part is covered; isDynamicElementInSharedData is retained as query-column placement diagnostic, not persisted per-mark roster proof.',
      }
    end

    # Cheap in-memory falsifiers for the two most important W244 distinctions:
    # same JSON value with the wrong leaf type, and a swapped JSON path name.
    def self_test!
      valid = [W244::CHILD_TAG, '1', '1', W244::INNER_ACTUAL_TYPE, W244::INNER_ACTUAL_TYPE,
               W244::INNER_JSON_TYPE, '7b2276223a22496e743634227d', 'Int64', '7', 'UInt8', '9']
      controls = {}
      controls[:baseline_child_accepted] = child_row_valid?(valid)

      uppercase_hex = valid.dup
      uppercase_hex[6] = uppercase_hex[6].upcase
      controls[:uppercase_equivalent_child_accepted] = child_row_valid?(uppercase_hex)

      malformed_hex = valid.dup
      malformed_hex[6] = '7BZZ'
      controls[:malformed_hex_rejected] = !child_row_valid?(malformed_hex)

      controls[:empty_helper_stdin_accepted] = valid_helper_stdin?(''.b)
      controls[:nonempty_helper_stdin_rejected] = !valid_helper_stdin?("unexpected\n".b)

      canonical_parent = '/private/tmp/w244-audit-self-test/table'
      controls[:single_trailing_separator_normalized] =
        normalize_recorded_directory_path(canonical_parent + '/') == canonical_parent &&
        canonical_descendant?(canonical_parent, canonical_parent, '/private/tmp/w244-audit-self-test')
      controls[:part_path_swap_rejected] =
        !exact_child_path?('/private/tmp/w244-audit-self-test/other/all_1_1_0', canonical_parent, 'all_1_1_0')
      escaped_lexical = canonical_parent + '/../outside'
      controls[:noncanonical_escape_rejected] =
        !canonical_descendant?(escaped_lexical, '/private/tmp/w244-audit-self-test/outside', canonical_parent)

      capture_parent = '/private/tmp/w244-audit-self-test'
      capture_dir = File.join(capture_parent, 'invocations')
      controls[:canonical_invocation_directory_accepted] =
        canonical_capture_directory?(capture_dir, capture_parent, capture_dir, false)
      controls[:invocation_directory_symlink_rejected] =
        !canonical_capture_directory?(capture_dir, capture_parent, capture_dir, true)
      controls[:invocation_directory_escape_rejected] =
        !canonical_capture_directory?('/private/tmp/other/invocations', capture_parent,
                                      '/private/tmp/other/invocations', false)

      wrong_type = valid.dup
      wrong_type[6] = hex_json({'v' => 'UInt8'})
      wrong_type[7] = 'UInt8'
      # The JSON scalar remains 7; only the typed descriptor changes.
      controls[:same_value_wrong_type_rejected] = !child_row_valid?(wrong_type)

      swapped_path = valid.dup
      swapped_path[6] = hex_json({'x' => 'Int64'})
      controls[:path_swap_rejected] = !child_row_valid?(swapped_path)
      fail!('W244 auditor self-test was not discriminating') unless controls.values.all?
      controls
    end

    private

    def fail!(message)
      raise Failure, "W244 audit: #{message}"
    end

    def checked_sha(value, label)
      fail!("#{label} SHA-256 is malformed") unless value.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(value)
      value
    end

    def canonical_file(path, label)
      fail!("#{label} path is required") unless path.is_a?(String) && !path.empty?
      expanded = File.expand_path(path)
      fail!("#{label} is absent, non-executable, or symlinked") unless
        File.file?(expanded) && File.executable?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded
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
      fail!("#{label} is invalid or contains duplicate keys: #{error.message}")
    end

    def exact_keys!(value, keys, label)
      fail!("#{label} key set differs") unless value.is_a?(Hash) && value.keys.sort == keys.sort
    end

    def same!(actual, expected, label)
      fail!("#{label} differs; observed #{actual.inspect}, expected #{expected.inspect}") unless actual == expected
    end

    def authenticate_summary!
      exact_keys!(@summary, SUMMARY_KEYS, 'summary')
      same!(@summary.fetch('format'), W244::FORMAT, 'summary format')
      same!(@summary.fetch('status'), 'library_written_native_read_observed', 'summary status')
      same!(@summary.fetch('fatal_error'), nil, 'summary failure state')
      same!(@summary.fetch('scope'), 'library_written_native_read_only; one advanced_s0 profile; no stock-authored W244 part claim', 'summary scope')
      same!(@summary.fetch('evidence_root'), @root, 'summary evidence root')
      same!(@summary.fetch('profile_id'), 'advanced_s0', 'profile identity')
      same!(@summary.fetch('frame_bytes'), W244::FRAME_BYTES, 'frame size')

      runtime = @summary.fetch('runtime')
      exact_keys!(runtime, %w[path sha256_expected sha256_before sha256_after], 'runtime')
      same!([runtime['path'], runtime['sha256_expected'], runtime['sha256_before'], runtime['sha256_after']],
            [@clickhouse, W241::BINARY_SHA256, W241::BINARY_SHA256, W241::BINARY_SHA256], 'runtime identity')
      same!(Digest::SHA256.file(@clickhouse).hexdigest, W241::BINARY_SHA256, 'current ClickHouse binary pin')

      same!(@summary.fetch('helper_sha256_before'), @helper_sha256, 'helper executable before pin')
      same!(@summary.fetch('helper_sha256_after'), @helper_sha256, 'helper executable after pin')
      same!(Digest::SHA256.file(@helper_path).hexdigest, @helper_sha256, 'current helper executable pin')
      same!(@summary.fetch('helper_source_sha256_before'), @helper_source_sha256, 'helper source before pin')
      same!(@summary.fetch('helper_source_sha256_after'), @helper_source_sha256, 'helper source after pin')
      same!(@helper_source_sha256, W244::HELPER_SOURCE_SHA256, 'frozen helper source pin')
      same!(Digest::SHA256.file(W244::HELPER_SOURCE).hexdigest, @helper_source_sha256, 'current helper source hash')
      true
    rescue KeyError, TypeError => error
      fail!("summary is malformed: #{error.class}: #{error.message}")
    end

    def authenticate_helper_and_part!
      helper = @summary.fetch('helper')
      exact_keys!(helper, HELPER_KEYS, 'helper record')
      same!([helper['helper_executable_sha256'], helper['helper_source_sha256'], helper['invocation_label']],
            [@helper_sha256, @helper_source_sha256, 'crystal_helper'], 'helper source/executable identity')
      generated = File.join(@root, 'generated')
      part_path = File.join(generated, 'advanced_s0')
      same!(helper['input_path'], File.join(@root, 'invocations', 'helper_input.json'), 'helper input path')
      input_bytes = read_bounded(invocation_artifact_path('helper_input.json'), 1024 * 1024, 'helper input')
      expected_input = JSON.generate({'format' => W244::HELPER_INPUT_FORMAT, 'frame_bytes' => W244::FRAME_BYTES}) + "\n"
      same!(input_bytes, expected_input, 'helper input bytes')
      same!(Digest::SHA256.hexdigest(input_bytes), helper['input_sha256'], 'helper input digest')

      stdout = read_bounded(invocation_artifact_path('crystal_helper.stdout'), MAX_ARTIFACT_BYTES, 'helper stdout')
      same!(Digest::SHA256.hexdigest(stdout), helper['output_sha256'], 'helper output digest')
      same!(Digest::SHA256.hexdigest(stdout), @summary.fetch('helper_output_sha256'), 'summary helper output digest')
      output = parse_single_json_line!(stdout, 'helper stdout')
      exact_keys!(output, %w[format input_sha256 output_root frame_bytes profile_id row_count mark_row_counts part], 'helper output')
      same!([output['format'], output['input_sha256'], output['output_root'], output['frame_bytes'], output['profile_id'], output['row_count'], output['mark_row_counts']],
            [W244::HELPER_OUTPUT_FORMAT, helper['input_sha256'], generated, W244::FRAME_BYTES, 'advanced_s0', W244::ROW_COUNT, W244::MARK_ROWS],
            'helper output envelope')

      part = output.fetch('part')
      exact_keys!(part, %w[
        path schema_declaration columns_text count_text count shared_version bucket_count mark_row_counts
        physical_file_inventory full_rows payload_rows nested_type_witnesses bounded_windows
        outer_actual_type nested_actual_type nested_dynamic_type nested_site nested_json_type
      ], 'helper part')
      same!(@summary.fetch('part'), part, 'summary/helper part join')
      same!([part['path'], part['schema_declaration'], part['count'], part['count_text'].strip,
             part['shared_version'], part['bucket_count'], part['mark_row_counts']],
            [part_path, W241::STOCK_TYPE, W244::ROW_COUNT, W244::ROW_COUNT.to_s, 2, 1, W244::MARK_ROWS],
            'part identity/layout')
      same!([part['outer_actual_type'], part['nested_actual_type'], part['nested_dynamic_type'], part['nested_site'], part['nested_json_type']],
            [W244::OUTER_ACTUAL_TYPE, W244::INNER_ACTUAL_TYPE, 'Dynamic(max_types=1)', W244::OUTER_NESTED_SITE, W244::INNER_JSON_TYPE],
            'recursive descriptor/site witness')
      same!(part['full_rows'], W244::EXPECTED_DOCS, 'helper full Object literals')
      same!(part['payload_rows'], expected_payload_rows, 'helper selected payload rows')
      same!(part['nested_type_witnesses'], expected_nested_witnesses, 'helper nested exact-type witnesses')
      same!(part['bounded_windows'], expected_helper_windows, 'helper bounded-window witnesses')
      expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`doc` #{W241::STOCK_TYPE}\n"
      same!(part['columns_text'], expected_columns, 'physical columns text')

      @source_snapshot = part_snapshot(part_path)
      same!(@source_snapshot, inventory_snapshot(part.fetch('physical_file_inventory')), 'helper/source file inventory')
      @part = part
      true
    rescue KeyError, TypeError, ArgumentError => error
      fail!("helper/part authentication failed: #{error.class}: #{error.message}")
    end

    def expected_payload_rows
      W244::EXPECTED_DOCS.map do |row|
        {'pk' => row.fetch('pk'), 'type' => W244::OUTER_ACTUAL_TYPE, 'value' => row.fetch('doc').fetch('payload')}
      end
    end

    def expected_nested_witnesses
      W244::EXPECTED_DOCS.map do |entry|
        pk = entry.fetch('pk')
        payload = entry.fetch('doc').fetch('payload')
        values = payload.fetch(1).each_with_index.map do |value, index|
          if value.nil?
            {'index' => index, 'type' => 'NULL', 'is_null' => true}
          elsif value.is_a?(Array)
            {'index' => index, 'type' => W244::INNER_ACTUAL_TYPE, 'is_null' => false,
             'json_type' => W244::INNER_JSON_TYPE, 'json_paths_with_types' => {'v' => 'Int64'},
             'v_type' => 'Int64', 'v' => 7, 'scalar_type' => 'UInt8', 'scalar' => 9}
          else
            {'index' => index, 'type' => 'String', 'is_null' => false, 'value' => value}
          end
        end
        {'pk' => pk, 'outer_actual_type' => W244::OUTER_ACTUAL_TYPE, 'outer_json_type' => W244::OUTER_JSON_TYPE,
         'outer_json_paths_with_types' => {'v' => 'UInt8'}, 'outer_v' => 7,
         'inner_array_type' => W244::INNER_ARRAY_TYPE, 'inner_items' => values}
      end
    end

    def expected_helper_windows
      W244::EXPECTED_MARK_WINDOWS.map do |name, specification|
        pks = specification.fetch('pks')
        rows = W244::EXPECTED_DOCS.select { |row| pks.include?(row.fetch('pk')) }
        {'window' => name, 'first_mark' => specification.fetch('first_mark'), 'mark_count' => specification.fetch('mark_count'),
         'mark_row_counts' => specification.fetch('mark_count').zero? ? [] : W244::MARK_ROWS.drop(specification.fetch('first_mark')).take(specification.fetch('mark_count')),
         'full_rows' => rows, 'payload_first_pk' => pks.empty? ? nil : pks.first, 'payload_rows' => pks.size}
      end
    end

    def parse_single_json_line!(bytes, label)
      lines = bytes.force_encoding(Encoding::UTF_8).lines
      fail!("#{label} is not exactly one UTF-8 JSON line") unless lines.size == 1 && lines.first.end_with?("\n") && lines.first.valid_encoding?
      parse_json!(lines.first, label)
    end

    def inventory_snapshot(inventory)
      fail!('helper physical inventory is malformed') unless inventory.is_a?(Array)
      entries = inventory.map do |entry|
        exact_keys!(entry, %w[name size sha256], 'helper inventory entry')
        name = entry.fetch('name')
        fail!('helper inventory contains unsafe file name') unless name.is_a?(String) && /\A[A-Za-z0-9_.-]+\z/.match?(name)
        size = entry.fetch('size')
        sha = checked_sha(entry.fetch('sha256'), 'part file')
        fail!('helper inventory size is malformed') unless size.is_a?(Integer) && size >= 0
        [name, size, sha]
      end
      fail!('helper inventory has duplicate names or is not sorted') unless entries.map(&:first).uniq.size == entries.size && entries == entries.sort
      entries
    end

    def part_snapshot(path)
      fail!("part directory is absent or symlinked: #{path}") unless File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path
      entries = []
      total = 0
      Find.find(path) do |entry|
        stat = File.lstat(entry)
        fail!("part contains a symlink or special file: #{entry}") unless !stat.symlink? && (stat.directory? || stat.file?)
        next if stat.directory?
        fail!("part file exceeds byte bound: #{entry}") unless stat.size <= 16 * 1024 * 1024
        total += stat.size
        fail!('part exceeds total byte bound') unless total <= 64 * 1024 * 1024
        entries << [entry.delete_prefix(path + File::SEPARATOR), stat.size, Digest::SHA256.file(entry).hexdigest]
      end
      entries.sort
    end

    def authenticate_physical_marks!
      mark_files = Dir.children(@part.fetch('path')).grep(/\.mrk2\z/).sort
      fail!('part has no plain .mrk2 files or includes compressed marks') unless !mark_files.empty? && Dir.children(@part.fetch('path')).none? { |name| name.end_with?('.cmrk2') }
      rows = mark_files.map do |name|
        path = File.join(@part.fetch('path'), name)
        bytes = read_bounded(path, 16 * 1024 * 1024, "physical mark #{name}")
        fail!("#{name} is not a sequence of complete 24-byte triples") unless !bytes.empty? && (bytes.bytesize % 24).zero?
        tuples = bytes.unpack('Q<*').each_slice(3).map(&:dup)
        fail!("#{name} does not contain exactly the two marks and terminal sentinel") unless
          tuples.map { |tuple| tuple.fetch(2) } == W244::MARK_ROWS_WITH_EOF
        {'name' => name, 'sha256' => Digest::SHA256.hexdigest(bytes), 'tuples' => tuples}
      end
      same!(@summary.fetch('physical_mark_tuples'), rows, 'captured physical mark tuples')
      inventory = @part.fetch('physical_file_inventory').to_h { |entry| [entry.fetch('name'), entry] }
      rows.each do |entry|
        file = inventory.fetch(entry.fetch('name'))
        same!([file.fetch('size'), file.fetch('sha256')],
              [File.size(File.join(@part.fetch('path'), entry.fetch('name'))), entry.fetch('sha256')],
              "#{entry.fetch('name')} helper inventory binding")
      end
      @physical_marks = rows
    rescue KeyError, TypeError, ArgumentError => error
      fail!("physical mark authentication failed: #{error.class}: #{error.message}")
    end

    def authenticate_processes!
      records = @summary.fetch('invocations')
      fail!('process invocation order/roster differs') unless records.is_a?(Array) && records.map { |record| record.fetch('label') } == LABELS
      @records = records.to_h { |record| [record.fetch('label'), record] }
      fail!('duplicate process labels') unless @records.size == LABELS.size
      LABELS.each do |label|
        record = @records.fetch(label)
        exact_keys!(record, PROCESS_KEYS, "process #{label}")
        validate_process_record!(record, label)
      end
      same!(@summary.fetch('helper').fetch('invocation_label'), 'crystal_helper', 'helper invocation label')
      true
    rescue KeyError, TypeError => error
      fail!("process records are malformed: #{error.class}: #{error.message}")
    end

    def validate_process_record!(record, label)
      fail!("#{label} process was not a clean success") unless
        record['process_classification'] == 'success' && record['exit'] == 0 && record['signal'].nil? &&
        record['timed_out'] == false && record['stderr_bytes'] == 0 && record['stderr_sha256'] == Digest::SHA256.hexdigest('') &&
        %w[spawn_error stdin_write_error stdout_read_error stderr_read_error].all? { |field| record[field].nil? }
      fail!("#{label} process limits differ") unless record['timeout_seconds'] == W241::TIMEOUT &&
        record['termination_grace_seconds'] == W241::GRACE && record['required_outer_run_safe_memory_limit_bytes'] == W241::OUTER_RUN_SAFE_LIMIT
      expected_native = label != 'crystal_helper'
      if expected_native
        store = File.join(@root, 'stores', 'native')
        expected_argv = [@clickhouse, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1', "--max_memory_usage=#{W241::MEMORY}", '--multiquery']
        same!([record['process_kind'], record['argv'], record['store_path'], record['binary_path'], record['expected_binary_sha256'],
               record['binary_sha_before'], record['binary_sha_after'], record['max_threads'], record['max_memory_usage_bytes'], record['max_memory_usage_applicable']],
              ['clickhouse-local', expected_argv, store, @clickhouse, W241::BINARY_SHA256,
               W241::BINARY_SHA256, W241::BINARY_SHA256, 1, W241::MEMORY, true], "#{label} native process identity")
      else
        expected_argv = [@helper_path, File.join(@root, 'invocations', 'helper_input.json'), File.join(@root, 'generated')]
        same!([record['process_kind'], record['argv'], record['store_path'], record['binary_path'], record['expected_binary_sha256'],
               record['binary_sha_before'], record['binary_sha_after'], record['max_threads'], record['max_memory_usage_bytes'], record['max_memory_usage_applicable']],
              ['crystal-helper', expected_argv, nil, @helper_path, @helper_sha256, @helper_sha256, @helper_sha256, nil, nil, false], 'helper process identity')
      end

      %w[argv_file stdin_file stdout_file stderr_file].each do |field|
        value = record.fetch(field)
        fail!("#{label} #{field} is not a safe basename") unless value.is_a?(String) && File.basename(value) == value && /\A[A-Za-z0-9_.-]+\z/.match?(value)
      end
      %w[argv_file stdin_file stdout_file stderr_file].zip(%w[argv_sha256 stdin_sha256 stdout_sha256 stderr_sha256]).each do |file_field, sha_field|
        bytes = read_bounded(invocation_artifact_path(record.fetch(file_field)), MAX_ARTIFACT_BYTES, "#{label} #{file_field}")
        same!(Digest::SHA256.hexdigest(bytes), record.fetch(sha_field), "#{label} #{file_field} digest")
        length_field = {'stdin_file' => 'stdin_bytes', 'stdout_file' => 'stdout_bytes', 'stderr_file' => 'stderr_bytes'}[file_field]
        same!(bytes.bytesize, record.fetch(length_field), "#{label} #{file_field} length") if length_field
      end
      stdout = read_bounded(invocation_artifact_path(record.fetch('stdout_file')), MAX_ARTIFACT_BYTES, "#{label} stdout")
      stderr = read_bounded(invocation_artifact_path(record.fetch('stderr_file')), MAX_ARTIFACT_BYTES, "#{label} stderr")
      fail!("#{label} stderr artifact is not empty") unless stderr.empty?
      argv_bytes = read_bounded(invocation_artifact_path(record.fetch('argv_file')), MAX_ARTIFACT_BYTES, "#{label} argv")
      same!(parse_json!(argv_bytes, "#{label} argv"), record.fetch('argv'), "#{label} argv artifact")
      stdin = read_bounded(invocation_artifact_path(record.fetch('stdin_file')), MAX_ARTIFACT_BYTES, "#{label} stdin")
      expected_stdin = if label == 'crystal_helper'
                         fail!("#{label} stdin is not empty") unless valid_helper_stdin?(stdin)
                         ''.b
                       else
                         expected_native_stdin(label)
                       end
      same!(stdin, expected_stdin.b, "#{label} exact command input")
      record_artifact = parse_json!(read_bounded(invocation_artifact_path("#{label}.json"), MAX_ARTIFACT_BYTES, "#{label} record"), "#{label} record")
      same!(record_artifact, record, "#{label} record artifact")
      if expected_native
        same!(tagged_rows(stdout, PIN_TAG, 3), [[PIN_TAG, W241::VERSION, W241::BUILD]], "#{label} runtime pin")
      end
    end

    def expected_helper_input
      JSON.generate({'format' => W244::HELPER_INPUT_FORMAT, 'frame_bytes' => W244::FRAME_BYTES}) + "\n"
    end

    def expected_native_stdin(label)
      pin = "SET output_format_json_quote_64bit_integers=0;\nSELECT '__W241_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;"
      sql = native_sql(label)
      [pin, 'SET print_pretty_type_names=0;', 'SET output_format_json_quote_64bit_integers=0;', sql].join("\n")
    end

    def native_sql(label)
      table = "w244_#{Digest::SHA256.hexdigest(@root)[0, 8]}_advanced_s0"
      case label
      when 'native_create_table'
        profile = W241::PROFILES.find { |item| item.fetch(:id) == 'advanced_s0' }
        runner = W241::Probe.allocate
        [
          "CREATE TABLE default.#{table} (pk UInt64, doc #{W241::STOCK_TYPE}) ENGINE=MergeTree ORDER BY pk SETTINGS #{runner.send(:settings, profile)};",
          "SELECT '#{W244::PATH_TAG}', database, name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw;",
        ].join("\n")
      when 'native_attach_check'
        [
          "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0';",
          "SELECT '#{W244::CHECK_BEGIN_TAG}', 'advanced_s0' FORMAT TSVRaw;",
          "CHECK TABLE default.#{table} FORMAT TSV;",
          "SELECT '#{W244::CHECK_END_TAG}', 'advanced_s0' FORMAT TSVRaw;",
          "SELECT '#{W244::SCHEMA_TAG}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;",
          "SELECT '#{W244::PART_TAG}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;",
        ].join("\n")
      when 'native_type_values'
        tuple = "assumeNotNull(dynamicElement(doc.payload, #{sql_string(W244::OUTER_ACTUAL_TYPE)}))"
        fields = [
          'toTypeName(doc.payload)', 'dynamicType(doc.payload)', "toTypeName(#{tuple})", "toTypeName(#{tuple}.1)",
          "hex(toJSONString(JSONAllPathsWithTypes(#{tuple}.1)))", "toTypeName(#{tuple}.2)",
          "hex(toJSONString(arrayMap(x -> if(isNull(x), 'NULL', dynamicType(x)), #{tuple}.2)))",
        ].join(', ')
        "SELECT '#{W244::TYPE_TAG}', toString(pk), #{fields} FROM default.#{table} WHERE isNotNull(doc.payload) ORDER BY pk FORMAT TSVRaw;"
      when 'native_inner_json_child'
        tuple = "assumeNotNull(dynamicElement(doc.payload, #{sql_string(W244::OUTER_ACTUAL_TYPE)}))"
        inner = "assumeNotNull(dynamicElement(item, #{sql_string(W244::INNER_ACTUAL_TYPE)}))"
        array_alias = "#{tuple}.2"
        "SELECT '#{W244::CHILD_TAG}', toString(pk), toString(item_index), dynamicType(item), " \
          "toTypeName(#{inner}), toTypeName(#{inner}.1), " \
          "hex(toJSONString(JSONAllPathsWithTypes(#{inner}.1))), " \
          "toTypeName(#{inner}.1.v), toString(#{inner}.1.v), " \
          "toTypeName(#{inner}.2), toString(#{inner}.2) " \
          "FROM (SELECT pk, #{array_alias} AS nested_array FROM default.#{table} WHERE isNotNull(doc.payload)) " \
          "ARRAY JOIN arrayEnumerate(nested_array) AS item_index, nested_array AS item " \
          "WHERE dynamicType(item) = #{sql_string(W244::INNER_ACTUAL_TYPE)} ORDER BY pk, item_index FORMAT TSVRaw;"
      when 'native_full_rows'
        "SELECT '#{W244::FULL_TAG}', toString(pk), toTypeName(doc), hex(toJSONString(doc)) FROM default.#{table} ORDER BY pk FORMAT TSVRaw;"
      when 'native_mark_windows'
        W244::EXPECTED_MARK_WINDOWS.map do |name, spec|
          lower = spec.fetch('first_mark') * 2 + 1
          upper = lower + spec.fetch('mark_count') * 2 - 1
          predicate = spec.fetch('mark_count').zero? ? 'pk > 4' : "pk BETWEEN #{lower} AND #{upper}"
          tuple = "assumeNotNull(dynamicElement(doc.payload, #{sql_string(W244::OUTER_ACTUAL_TYPE)}))"
          "SELECT '#{W244::WINDOW_TAG}', '#{name}', toString(pk), dynamicType(doc.payload), " \
            "hex(toJSONString(#{tuple}.2)) FROM default.#{table} WHERE #{predicate} ORDER BY pk FORMAT TSVRaw;"
        end.join("\n")
      when 'native_query_column_placement_diagnostic'
        W244::EXPECTED_MARK_WINDOWS.reject { |name, _spec| name == 'zero_count_end' }.map do |name, spec|
          first = spec.fetch('first_mark') * 2 + 1
          last = first + 1
          tuple = "assumeNotNull(dynamicElement(doc.payload, #{sql_string(W244::OUTER_ACTUAL_TYPE)}))"
          expression = "arrayMap(x -> if(isNull(x), 'NULL', if(isDynamicElementInSharedData(x), '1', '0')), #{tuple}.2)"
          "SELECT '#{W244::PLACEMENT_TAG}', '#{name}', toString(pk), hex(toJSONString(#{expression})) " \
            "FROM default.#{table} WHERE pk BETWEEN #{first} AND #{last} ORDER BY pk FORMAT TSVRaw;"
        end.join("\n")
      else
        fail!("unknown native invocation label #{label}")
      end
    end

    def sql_string(value)
      "'#{value.to_s.gsub(/[\\']/) { |character| "\\#{character}" }}'"
    end

    def authenticate_invocations_directory!
      path = File.join(@root, 'invocations')
      fail!('invocations artifact directory is absent, symlinked, or not a directory') unless
        File.directory?(path) && !File.symlink?(path)
      real = File.realpath(path)
      fail!('invocations artifact directory is not a canonical direct child of the evidence root') unless
        canonical_capture_directory?(path, @root, real, File.symlink?(path))
      @invocations_dir = real
    end

    def canonical_capture_directory?(path, parent, real_path, symlink)
      !symlink && path == File.join(parent, 'invocations') && File.dirname(path) == parent && real_path == path
    end

    def invocation_artifact_path(basename)
      fail!('invocations directory was not authenticated') unless @invocations_dir
      fail!('invocation artifact is not a safe basename') unless
        basename.is_a?(String) && File.basename(basename) == basename && /\A[A-Za-z0-9_.-]+\z/.match?(basename)
      File.join(@invocations_dir, basename)
    end

    def authenticate_attachment!
      create_stdout = stdout_for('native_create_table')
      paths = tagged_rows(create_stdout, W244::PATH_TAG, 4)
      fail!('native table/path binding is not unique') unless paths.size == 1
      path_row = paths.first
      table = "w244_#{Digest::SHA256.hexdigest(@root)[0, 8]}_advanced_s0"
      same!(path_row.values_at(1, 2), ['default', table], 'native table identity')
      data_path = canonical_contained(path_row.fetch(3), File.join(@root, 'stores', 'native'), 'native table path')

      attach_stdout = stdout_for('native_attach_check')
      checks = check_rows(attach_stdout)
      same!(checks, ["all_1_1_0\t1\t"], 'native CHECK TABLE')
      schema_rows = tagged_rows(attach_stdout, W244::SCHEMA_TAG, 3)
      same!(schema_rows.map { |row| row.drop(1) }, [['pk', 'UInt64'], ['doc', W241::STOCK_TYPE]], 'attached schema')
      parts = tagged_rows(attach_stdout, W244::PART_TAG, 7)
      fail!('native active-part identity/count is not unique') unless parts.size == 1
      active = parts.first
      same!(active.values_at(1, 2, 4, 5, 6), [table, 'all_1_1_0', 'Wide', '4', '3'], 'active part/table identity and counts')
      attached_path = canonical_contained(active.fetch(3), data_path, 'active part path')
      fail!('active part path does not exactly join from the table data path') unless
        exact_child_path?(attached_path, data_path, 'all_1_1_0')
      # ATTACH moves the detached staging part on this pinned runtime. The
      # coordinator captured its bytes before ATTACH; authenticate that
      # historical observation by requiring its digest to equal the generated
      # source snapshot. Do not claim the detached copy still exists now.
      source_digest = Digest::SHA256.hexdigest(JSON.generate(@source_snapshot))
      attachment = @summary.fetch('attachment')
      same!(attachment.fetch('source_snapshot_sha256'), source_digest, 'generated source snapshot digest')
      same!(attachment.fetch('copied_snapshot_sha256'), source_digest, 'pre-ATTACH copied snapshot digest')

      attached_snapshot = part_snapshot(attached_path)
      original = @source_snapshot.to_h { |name, size, sha| [name, [size, sha]] }
      actual = attached_snapshot.to_h { |name, size, sha| [name, [size, sha]] }
      metadata = 'invalidated_system_columns.txt'
      fail!('ATTACH file roster differs from original plus admitted metadata') unless
        !original.key?(metadata) && (actual.keys - original.keys) == [metadata] && (original.keys - actual.keys).empty?
      original.each { |name, identity| same!(actual.fetch(name), identity, "ATTACH file #{name}") }
      same!(read_bounded(File.join(attached_path, metadata), 1024, 'ATTACH invalidation metadata'), "_block_offset\n_block_number\n".b, 'ATTACH invalidation metadata bytes')

      expected_observation = {
        'check_rows' => checks,
        'schema' => schema_rows.map { |row| row.drop(1) },
        'active_part' => active.drop(1),
        'source_snapshot_sha256' => source_digest,
        'copied_snapshot_sha256' => source_digest,
        'attached_snapshot_sha256' => Digest::SHA256.hexdigest(JSON.generate(attached_snapshot)),
      }
      same!(@summary.fetch('attachment'), expected_observation, 'summary/native attachment observation')
      @active_part = active
      true
    rescue KeyError, TypeError => error
      fail!("attachment authentication failed: #{error.class}: #{error.message}")
    end

    def canonical_contained(path, parent, label)
      fail!("#{label} path is not a string") unless path.is_a?(String)
      lexical_path = normalize_recorded_directory_path(path)
      fail!("#{label} path has a noncanonical spelling") unless lexical_path
      canonical_parent = File.realpath(parent)
      fail!("#{label} parent is not canonical") unless canonical_parent == parent && !File.symlink?(parent)
      real = File.realpath(lexical_path)
      fail!("#{label} path is symlinked or noncanonical") unless real == lexical_path
      fail!("#{label} escapes its expected parent") unless canonical_descendant?(lexical_path, real, canonical_parent)
      real
    end

    def normalize_recorded_directory_path(path)
      return nil unless path.is_a?(String) && path.start_with?(File::SEPARATOR) && !path.include?("\0")
      lexical_path = path.end_with?(File::SEPARATOR) ? path[0...-1] : path
      return nil if lexical_path.empty? || lexical_path.end_with?(File::SEPARATOR)
      lexical_path
    end

    def canonical_descendant?(lexical_path, real_path, canonical_parent)
      lexical_path == real_path && real_path.start_with?(canonical_parent + File::SEPARATOR)
    end

    def exact_child_path?(path, parent, name)
      path == File.join(parent, name)
    end

    def valid_helper_stdin?(bytes)
      bytes == ''.b
    end

    def replay_native_outputs!
      type_rows = tagged_rows(stdout_for('native_type_values'), W244::TYPE_TAG, 9)
      validate_type_rows!(type_rows)
      child_rows = tagged_rows(stdout_for('native_inner_json_child'), W244::CHILD_TAG, 11)
      fail!('native nested child row differs') unless child_rows.size == 1 && child_row_valid?(child_rows.first)
      full_rows = tagged_rows(stdout_for('native_full_rows'), W244::FULL_TAG, 4)
      validate_full_rows!(full_rows)
      window_rows = tagged_rows(stdout_for('native_mark_windows'), W244::WINDOW_TAG, 5)
      windows = validate_window_rows!(window_rows)
      placement_rows = tagged_rows(stdout_for('native_query_column_placement_diagnostic'), W244::PLACEMENT_TAG, 4)
      placement = validate_placement_rows!(placement_rows)

      expected = {
        'type_rows' => type_rows.map { |row| row.drop(1) },
        'child_rows' => child_rows.map { |row| row.drop(1) },
        'full_rows' => full_rows.map { |row| row.drop(1) },
        'windows' => windows,
        'placement_diagnostic' => {
          'scope' => 'separate mark-filtered query outputs',
          'meaning' => 'isDynamicElementInSharedData reports in-memory query-column placement and is not persisted per-mark roster proof',
          'observations' => placement,
        },
        'type_invocation' => 'native_type_values',
        'child_invocation' => 'native_inner_json_child',
        'full_invocation' => 'native_full_rows',
        'window_invocation' => 'native_mark_windows',
        'placement_invocation' => 'native_query_column_placement_diagnostic',
        'exact_dynamic_type_and_value_checks' => true,
        'nested_json_descriptor_checks' => true,
        'isDynamicElementInSharedData_interpretation' => 'diagnostic query-column placement only; not persisted per-mark roster evidence',
      }
      same!(@summary.fetch('native_observations'), expected, 'summary/native output replay')
      true
    end

    def validate_type_rows!(rows)
      same!(rows.size, W244::ROW_COUNT, 'native root type row count')
      same!(rows.map { |row| Integer(row.fetch(1), 10) }, (1..W244::ROW_COUNT).to_a, 'native root type row domain')
      rows.each do |row|
        pk = Integer(row.fetch(1), 10)
        same!(row.values_at(2, 3, 4, 5, 7), ['Dynamic', W244::OUTER_ACTUAL_TYPE, W244::OUTER_ACTUAL_TYPE, W244::OUTER_JSON_TYPE, W244::INNER_ARRAY_TYPE], "pk#{pk} root descriptors")
        same!(parse_hex_json(row.fetch(6)), {'v' => 'UInt8'}, "pk#{pk} outer JSON type")
        same!(parse_hex_json(row.fetch(8)), W244::EXPECTED_ITEM_TYPES.fetch(pk), "pk#{pk} nested Dynamic actuals")
      end
    end

    def child_row_valid?(row)
      return false unless row.is_a?(Array) && row.size == 11
      row.values_at(1, 2, 3, 4, 5, 7, 8, 9, 10) ==
        ['1', '1', W244::INNER_ACTUAL_TYPE, W244::INNER_ACTUAL_TYPE, W244::INNER_JSON_TYPE,
         'Int64', '7', 'UInt8', '9'] && parse_hex_json(row.fetch(6)) == {'v' => 'Int64'}
    rescue Failure, TypeError
      false
    end

    def validate_full_rows!(rows)
      same!(rows.size, W244::ROW_COUNT, 'native full row count')
      same!(rows.map { |row| Integer(row.fetch(1), 10) }, (1..W244::ROW_COUNT).to_a, 'native full row domain')
      rows.each do |row|
        pk = Integer(row.fetch(1), 10)
        same!(row.fetch(2), W241::STOCK_TYPE, "pk#{pk} full Object type")
        same!(parse_hex_json(row.fetch(3)), W244::EXPECTED_DOCS.fetch(pk - 1).fetch('doc'), "pk#{pk} full Object value")
      end
    end

    def validate_window_rows!(rows)
      observations = {}
      W244::EXPECTED_MARK_WINDOWS.each do |name, specification|
        selected = rows.select { |row| row.fetch(1) == name }
        pks = selected.map { |row| Integer(row.fetch(2), 10) }
        same!(pks, specification.fetch('pks'), "native #{name} window domain")
        selected.each do |row|
          pk = Integer(row.fetch(2), 10)
          same!(row.fetch(3), W244::OUTER_ACTUAL_TYPE, "native #{name} outer actual at pk#{pk}")
          same!(parse_hex_json(row.fetch(4)), W244::EXPECTED_DOCS.fetch(pk - 1).fetch('doc').fetch('payload').fetch(1), "native #{name} nested values at pk#{pk}")
        end
        observations[name] = {'pks' => pks, 'row_count' => selected.size}
      end
      same!(rows.size, W244::ROW_COUNT, 'native window total row count')
      observations
    end

    def validate_placement_rows!(rows)
      same!(rows.size, W244::ROW_COUNT, 'placement diagnostic row count')
      expected_domain = [['first', 1], ['first', 2], ['last', 3], ['last', 4]]
      same!(rows.map { |row| [row.fetch(1), Integer(row.fetch(2), 10)] }, expected_domain,
            'placement diagnostic mark-window row domain')
      rows.map do |row|
        name = row.fetch(1)
        pk = Integer(row.fetch(2), 10)
        flags = parse_hex_json(row.fetch(3))
        expected_width = W244::EXPECTED_DOCS.fetch(pk - 1).fetch('doc').fetch('payload').fetch(1).size
        fail!('placement diagnostic is not a per-item flag array') unless
          flags.is_a?(Array) && flags.size == expected_width && flags.all? { |flag| %w[0 1 NULL].include?(flag) }
        {'window' => name, 'pk' => pk, 'flags' => flags}
      end
    end

    def check_rows(stdout)
      active = false
      result = []
      stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp).each do |line|
        if line == "#{W244::CHECK_BEGIN_TAG}\tadvanced_s0"
          fail!('nested CHECK interval') if active
          active = true
        elsif line == "#{W244::CHECK_END_TAG}\tadvanced_s0"
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
      stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp).each_with_object([]) do |line, rows|
        next unless line.start_with?(tag + "\t")
        fields = line.split("\t", -1)
        fail!("#{tag} row width differs") unless fields.size == width && fields.first == tag
        rows << fields
      end
    end

    def parse_hex_json(value)
      fail!('hex JSON field is malformed') unless value.is_a?(String) && /\A(?:[0-9a-fA-F]{2})*\z/.match?(value)
      parse_json!([value].pack('H*'), 'hex JSON field')
    end

    def hex_json(value)
      JSON.generate(value).unpack1('H*')
    end

    def stdout_for(label)
      record = @records.fetch(label)
      read_bounded(invocation_artifact_path(record.fetch('stdout_file')), MAX_ARTIFACT_BYTES, "#{label} stdout")
    end

    def check_rows_for_attach(stdout)
      check_rows(stdout)
    end
  end
end

def main
  options = {}
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/audit_object_nested_dynamic_json_w244.rb --summary PATH --summary-sha256 SHA --clickhouse PATH --helper PATH --helper-sha256 SHA --helper-source-sha256 SHA --self-test'
    parser.on('--summary PATH') { |value| options[:summary] = value }
    parser.on('--summary-sha256 SHA') { |value| options[:summary_sha256] = value }
    parser.on('--clickhouse PATH') { |value| options[:clickhouse] = value }
    parser.on('--helper PATH') { |value| options[:helper_path] = value }
    parser.on('--helper-sha256 SHA') { |value| options[:helper_sha256] = value }
    parser.on('--helper-source-sha256 SHA') { |value| options[:helper_source_sha256] = value }
    parser.on('--self-test') { options[:self_test] = true }
    parser.on('--self-test-only') { options[:self_test_only] = true }
  end.parse!

  if options[:self_test_only]
    controls = AuditObjectNestedDynamicJSONW244::Auditor.allocate.self_test!
    puts JSON.generate({status: 'self_test_passed', controls: controls})
    exit 0
  end
  %i[summary summary_sha256 clickhouse helper_path helper_sha256 helper_source_sha256].each do |key|
    raise ArgumentError, "--#{key.to_s.tr('_', '-')} is required" unless options[key]
  end
  result = AuditObjectNestedDynamicJSONW244::Auditor.new(
    summary_path: options[:summary], summary_sha256: options[:summary_sha256],
    clickhouse: options[:clickhouse], helper_path: options[:helper_path],
    helper_sha256: options[:helper_sha256], helper_source_sha256: options[:helper_source_sha256],
    self_test: options[:self_test],
  ).run
  puts JSON.generate(result)
rescue AuditObjectNestedDynamicJSONW244::Failure, ArgumentError, KeyError, TypeError => error
  warn error.message
  exit 1
end

main if $PROGRAM_NAME == __FILE__
