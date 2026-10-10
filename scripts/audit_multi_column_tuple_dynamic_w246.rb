#!/usr/bin/env ruby
# Offline W246 raw-evidence auditor. It never launches ClickHouse/Crystal and
# never modifies the capture. It independently joins the fixture's bytes to the
# raw native SQL/output and exact typed-value/child oracle.
#
# Usage is parallel to audit_schema_wide_part_w245.rb; root supplies external
# SHA-256 pins for the summary, executables, and source entrypoints.

require 'digest'
require 'find'
require 'json'
require 'optparse'
require_relative 'probe_object_shared_json_interop_w241'

module AuditMultiColumnTupleDynamicW246
  W241 = ProbeObjectSharedJSONInteropW241
  FORMAT = 'multi_column_tuple_dynamic_w246_native_capture_v1'.freeze
  HELPER_FORMAT = 'multi_column_tuple_dynamic_w246_fixture_v1'.freeze
  PART_NAME = 'all_1_1_0'.freeze
  FRAME = 32
  MARK_ROWS = [2, 2, 1].freeze
  MARKS_WITH_EOF = [2, 2, 1, 0].freeze
  KEY = {'name' => 'pk', 'type' => 'UInt64'}.freeze
  DYNAMIC = 'Dynamic(max_types=1)'.freeze
  ARRAY_DYNAMIC = 'Array(Dynamic(max_types=1))'.freeze
  NAMED_TYPE = 'Tuple(sequence Dynamic(max_types=1), items Array(Dynamic(max_types=1)))'.freeze
  UNNAMED_TYPE = 'Tuple(Dynamic(max_types=1), Dynamic(max_types=1))'.freeze
  COLUMNS = [
    {'name' => 'named_tuple', 'type' => NAMED_TYPE, 'tuple_kind' => 'named', 'fields' => [
      {'name' => 'sequence', 'type' => DYNAMIC, 'dynamic_site' => 'root.field.0', 'registered_actual_types' => ['UInt64']},
      {'name' => 'items', 'type' => ARRAY_DYNAMIC, 'dynamic_site' => 'root.field.1.elements', 'registered_actual_types' => ['String']},
    ]},
    {'name' => 'unnamed_tuple', 'type' => UNNAMED_TYPE, 'tuple_kind' => 'unnamed', 'fields' => [
      {'name' => nil, 'type' => DYNAMIC, 'dynamic_site' => 'root.field.0', 'registered_actual_types' => ['Bool']},
      {'name' => nil, 'type' => DYNAMIC, 'dynamic_site' => 'root.field.1', 'registered_actual_types' => ['UInt32']},
    ]},
  ].freeze
  TAGS = {path: '__W246_PATH__', check_begin: '__W246_CHECK_BEGIN__', check_end: '__W246_CHECK_END__',
          schema: '__W246_SCHEMA__', part: '__W246_PART__', values: '__W246_VALUES__',
          children: '__W246_CHILDREN__'}.freeze
  LABELS = %w[crystal_helper native_create_table native_attach_check native_typed_values native_array_children].freeze
  SUMMARY_KEYS = %w[
    format status fatal_error evidence_root write_mode string_profile requested_operation_mode
    actual_bulk_discriminator_mode frame_bytes schema keys mark_row_counts rows serialization
    helper_manifest runtime helper source_pins limits parts native_rows invocations paths
  ].freeze
  PROCESS_KEYS = %w[
    label process_kind argv argv_file argv_sha256 stdin_file stdin_bytes stdin_sha256 stdout_file
    stdout_bytes stdout_sha256 stderr_file stderr_bytes stderr_sha256 exit signal timed_out
    timeout_seconds termination_grace_seconds max_threads max_memory_usage_bytes max_memory_usage_applicable
    required_outer_run_safe_memory_limit_bytes binary_path expected_binary_sha256 binary_sha_before
    binary_sha_after spawn_error stdin_write_error stdout_read_error stderr_read_error
    process_classification store_path
  ].freeze
  BASE_FILES = %w[
    checksums.txt columns.txt columns_substreams.txt count.txt default_compression_codec.txt
    metadata_version.txt primary.idx serialization.json
  ].freeze
  MAX_ARTIFACT_BYTES = 64 * 1024 * 1024
  MAX_PART_BYTES = 64 * 1024 * 1024
  MAX_PART_FILE_BYTES = W241::MAX_PART_FILE_BYTES

  class Failure < StandardError; end

  class UniqueKeyHash < Hash
    def []=(key, value)
      raise JSON::ParserError, "duplicate JSON key #{key.inspect}" if key?(key)
      super
    end
  end

  def self.dynamic(type, storage, value)
    {'actual_type' => type, 'storage' => storage, 'value' => value}
  end

  # This is intentionally duplicated as a literal audit oracle, not loaded
  # from either the probe or fixture manifest.
  def self.rows
    [
      {'pk' => 1, 'named_tuple' => {'sequence' => dynamic('UInt64', 'dedicated', 7), 'items' => []},
       'unnamed_tuple' => [dynamic('Bool', 'dedicated', true), dynamic('UInt32', 'dedicated', 10)]},
      {'pk' => 2, 'named_tuple' => {'sequence' => dynamic(nil, 'null', nil), 'items' => []},
       'unnamed_tuple' => [dynamic('String', 'shared', 'left-overflow'), dynamic('UInt64', 'shared', 20)]},
      {'pk' => 3, 'named_tuple' => {'sequence' => dynamic('UInt64', 'dedicated', 42), 'items' => [
         dynamic('String', 'dedicated', 'array-dedicated'), dynamic('UInt8', 'shared', 9), dynamic(nil, 'null', nil)]},
       'unnamed_tuple' => [dynamic(nil, 'null', nil), dynamic('UInt32', 'dedicated', 42)]},
      {'pk' => 4, 'named_tuple' => {'sequence' => dynamic('String', 'shared', 'sequence-overflow'),
                                    'items' => [dynamic('UInt64', 'shared', 99)]},
       'unnamed_tuple' => [dynamic('Bool', 'dedicated', false), dynamic(nil, 'null', nil)]},
      {'pk' => 5, 'named_tuple' => {'sequence' => dynamic('String', 'shared', 'sequence-overflow-tail'),
                                    'items' => [dynamic('String', 'dedicated', 'array-dedicated-tail'), dynamic(nil, 'null', nil)]},
       'unnamed_tuple' => [dynamic('String', 'shared', 'left-overflow-tail'), dynamic('UInt64', 'shared', 100)]},
    ]
  end

  def self.ruby_closure(root_source)
    closure([root_source], File.realpath(__dir__), /^\s*require_relative\s+['"]([^'"]+)['"]/, '.rb')
  end

  def self.crystal_closure(roots, boundary)
    closure(roots, boundary, /^\s*require\s+['"]((?:\.\/|\.\.\/)[^'"]+)['"]/, '.cr')
  end

  def self.closure(roots, boundary, pattern, suffix)
    root = File.realpath(boundary)
    pending = roots.map { |path| File.expand_path(path) }
    seen = {}
    until pending.empty?
      path = pending.pop
      canonical = File.realpath(path)
      unless canonical.start_with?(root + File::SEPARATOR) && File.file?(canonical) && !File.symlink?(path)
        raise Failure, "source dependency escapes its tree or is not a regular file: #{path}"
      end
      next if seen.key?(canonical)
      seen[canonical] = true
      File.foreach(canonical) do |line|
        match = pattern.match(line)
        next unless match
        dependency = File.expand_path(match[1], File.dirname(canonical))
        dependency += suffix if File.extname(dependency).empty?
        pending << dependency
      end
    end
    seen.keys.sort
  rescue Errno::ENOENT => error
    raise Failure, "source dependency is missing: #{error.message}"
  end

  class Auditor
    def initialize(summary_path:, summary_sha256:, clickhouse:, helper_path:, helper_sha256:,
                   probe_source:, probe_source_sha256:, helper_source:, helper_source_sha256:,
                   fixture_source:, fixture_source_sha256:, auditor_source:, auditor_source_sha256:,
                   self_test:)
      @summary_path = canonical_file(summary_path, 'summary')
      @root = File.dirname(@summary_path)
      @summary_sha = checked_sha(summary_sha256, 'summary')
      @clickhouse = canonical_executable(clickhouse, 'ClickHouse')
      @helper = canonical_executable(helper_path, 'fixture helper')
      @helper_sha = checked_sha(helper_sha256, 'helper')
      @probe_source = canonical_file(probe_source, 'probe source')
      @probe_source_sha = checked_sha(probe_source_sha256, 'probe source')
      @helper_source = canonical_file(helper_source, 'helper source')
      @helper_source_sha = checked_sha(helper_source_sha256, 'helper source')
      @fixture_source = canonical_file(fixture_source, 'fixture source')
      @fixture_source_sha = checked_sha(fixture_source_sha256, 'fixture source')
      @auditor_source = canonical_file(auditor_source, 'auditor source')
      @auditor_source_sha = checked_sha(auditor_source_sha256, 'auditor source')
      fail!('--self-test is required for a capture audit') unless self_test
      fail!('summary must be summary.json in a canonical direct child of /private/tmp') unless
        File.basename(@summary_path) == 'summary.json' && File.directory?(@root) && !File.symlink?(@root) &&
        File.realpath(@root) == @root && File.dirname(@root) == File.realpath('/private/tmp')
      scripts = File.realpath(__dir__)
      same!(@probe_source, File.join(scripts, 'probe_multi_column_tuple_dynamic_w246.rb'), 'expected W246 probe source path')
      same!(@helper_source, File.join(scripts, 'check_multi_column_tuple_dynamic_w246.cr'), 'expected W246 helper source path')
      same!(@fixture_source, File.join(scripts, 'support', 'multi_column_tuple_dynamic_w246_fixture.cr'), 'expected W246 fixture source path')
      same!(@auditor_source, File.join(scripts, 'audit_multi_column_tuple_dynamic_w246.rb'), 'expected W246 auditor source path')
      # A recovered runtime may live at a different canonical path. Its exact
      # digest, build/version and every captured invocation remain pinned below.
      fail!('auditor source SHA differs from its external pin') unless sha_file(@auditor_source) == @auditor_source_sha
    end

    def run
      @summary = parse_json!(read_file(@summary_path, MAX_ARTIFACT_BYTES, 'summary'), 'summary')
      same!(sha_file(@summary_path), @summary_sha, 'external summary SHA')
      authenticate_layout!
      authenticate_contract!
      authenticate_sources!
      authenticate_invocations!
      authenticate_generated_part!
      authenticate_attached_part!
      replay_native_outputs!
      controls = self_test!
      {status: 'raw_capture_authenticated', summary_sha256: @summary_sha,
       runtime_sha256: W241::BINARY_SHA256, helper_sha256: @helper_sha,
       write_mode: @write_mode, string_profile: @profile, requested_operation_mode: @mode,
       actual_bulk_discriminator_mode: 'BASIC', columns: expected_columns.map { |column| column.fetch('name') },
       rows: 5, mark_row_counts: MARK_ROWS, controls: controls,
       interpretation: 'One fixture-produced Wide part read by the pinned stock local reader. This is not reciprocal-writer, broader-type, performance, memory, or crash-durability evidence.'}
    end

    private

    def fail!(message)
      raise Failure, "W246 audit: #{message}"
    end

    def same!(actual, expected, label)
      fail!("#{label} differs; observed #{actual.inspect}") unless actual == expected
    end

    def checked_sha(value, label)
      fail!("#{label} SHA-256 is malformed") unless value.is_a?(String) && /\A[0-9a-f]{64}\z/i.match?(value)
      value.downcase
    end

    def sha_file(path)
      Digest::SHA256.file(path).hexdigest
    end

    def sha_bytes(bytes)
      Digest::SHA256.hexdigest(bytes)
    end

    def canonical_file(path, label)
      expanded = File.expand_path(path)
      fail!("#{label} is absent, symlinked, or noncanonical") unless File.file?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded
      expanded
    rescue Errno::ENOENT, Errno::EACCES => error
      fail!("#{label} is inaccessible: #{error.message}")
    end

    def canonical_executable(path, label)
      expanded = canonical_file(path, label)
      fail!("#{label} is not executable") unless File.executable?(expanded)
      expanded
    end

    def read_file(path, limit, label)
      fail!("#{label} is symlinked or not a regular file") unless File.file?(path) && !File.symlink?(path)
      size = File.size(path)
      fail!("#{label} exceeds its byte bound") unless size <= limit
      bytes = File.binread(path)
      fail!("#{label} changed while read") unless bytes.bytesize == size
      bytes
    end

    def parse_json!(bytes, label)
      JSON.parse(bytes, object_class: UniqueKeyHash)
    rescue JSON::ParserError => error
      fail!("#{label} is malformed or has duplicate keys: #{error.message}")
    end

    def exact_keys!(value, keys, label)
      fail!("#{label} key set differs") unless value.is_a?(Hash) && value.keys.sort == keys.sort
    end

    def root_path(*parts)
      File.join(@root, *parts)
    end

    def authenticate_layout!
      same!(Dir.children(@root).sort, %w[generated invocations parts stores summary.json], 'evidence root children')
      %w[generated invocations parts stores].each do |name|
        path = root_path(name)
        fail!("#{name} is absent, symlinked, or noncanonical") unless File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path
      end
      %w[pre_attach].each do |name|
        path = root_path('parts', name)
        fail!("parts/#{name} is absent, symlinked, or noncanonical") unless File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path
      end
      native = root_path('stores', 'native')
      fail!('native store is absent, symlinked, or noncanonical') unless File.directory?(native) && !File.symlink?(native) && File.realpath(native) == native
      same!(Dir.children(root_path('generated')).sort, [PART_NAME], 'generated part directory roster')
      same!(Dir.children(root_path('parts', 'pre_attach')).sort, [PART_NAME], 'pre-attach directory roster')
    end

    def authenticate_contract!
      exact_keys!(@summary, SUMMARY_KEYS, 'summary')
      same!(@summary['format'], FORMAT, 'capture format')
      same!(@summary['status'], 'library_written_stock_read_observed', 'capture status')
      same!(@summary['fatal_error'], nil, 'capture fatal error')
      same!(@summary['evidence_root'], @root, 'evidence root binding')
      @write_mode = @summary['write_mode']
      @profile = @summary['string_profile']
      @mode = @summary['requested_operation_mode']
      fail!('write mode is not legacy or multi') unless %w[legacy multi].include?(@write_mode)
      fail!('String profile is not single or sized') unless %w[single sized].include?(@profile)
      fail!('requested operation mode is not basic or compact') unless %w[basic compact].include?(@mode)
      fail!('legacy API cannot claim a compact argument') if @write_mode == 'legacy' && @mode != 'basic'
      same!(@summary['actual_bulk_discriminator_mode'], 'BASIC', 'actual physical Dynamic mode')
      same!(@summary['frame_bytes'], FRAME, 'frame bound')
      same!(@summary['schema'], expected_schema, 'literal schema/order')
      same!(@summary['keys'], [1, 2, 3, 4, 5], 'literal keys')
      same!(@summary['mark_row_counts'], MARK_ROWS, 'parent mark grid')
      same!(@summary['rows'], expected_rows, 'literal semantic rows and Dynamic storage assignments')
      same!(@summary['serialization'], expected_serialization, 'literal serialization metadata')
      same!(@summary['limits'], expected_limits, 'bounded process limits')
      authenticate_runtime_and_helper!
    end

    def expected_columns
      @write_mode == 'legacy' ? [COLUMNS[0]] : COLUMNS
    end

    def expected_rows
      AuditMultiColumnTupleDynamicW246.rows.map do |row|
        @write_mode == 'legacy' ? row.reject { |key, _value| key == 'unnamed_tuple' } : row
      end
    end

    def expected_schema
      ([KEY] + expected_columns).map { |column| {'name' => column.fetch('name'), 'type' => column.fetch('type')} }
    end

    def expected_serialization
      columns = @write_mode == 'legacy' ? [
        {'exact_num_defaults' => true, 'kind' => 'Default', 'name' => 'pk', 'num_defaults' => 0, 'num_rows' => 5}
      ] : []
      {'columns' => columns, 'propagate_types_serialization_versions_to_nested_types' => true,
       'types_serialization_versions' => {'string' => (@profile == 'single' ? 0 : 1)}, 'version' => 1}
    end

    def expected_limits
      {'timeout_seconds' => W241::TIMEOUT, 'termination_grace_seconds' => W241::GRACE,
       'max_threads' => 1, 'max_memory_usage_bytes' => W241::MEMORY,
       'outer_run_safe_memory_limit_bytes' => W241::OUTER_RUN_SAFE_LIMIT}
    end

    def authenticate_runtime_and_helper!
      runtime = @summary.fetch('runtime')
      exact_keys!(runtime, %w[path sha256_before sha256_after version build], 'runtime record')
      same!([runtime['path'], runtime['sha256_before'], runtime['sha256_after'], runtime['version'], runtime['build']],
            [@clickhouse, W241::BINARY_SHA256, W241::BINARY_SHA256, W241::VERSION, W241::BUILD], 'pinned stock runtime record')
      same!(sha_file(@clickhouse), W241::BINARY_SHA256, 'current pinned ClickHouse executable')
      helper = @summary.fetch('helper')
      exact_keys!(helper, %w[path sha256_before sha256_after], 'helper record')
      same!([helper['path'], helper['sha256_before'], helper['sha256_after']], [@helper, @helper_sha, @helper_sha], 'helper executable record')
      same!(sha_file(@helper), @helper_sha, 'current helper executable')
      profile_id = @profile == 'single' ? 'advanced_s0' : 'advanced_s1'
      @reader_profile = W241::PROFILES.find { |profile| profile.fetch(:id) == profile_id }
      fail!('reader profile is absent from the pinned W241 settings') unless @reader_profile
      @table = "w246_#{Digest::SHA256.hexdigest(@root)[0, 8]}_#{@write_mode}_#{@profile}_#{@mode}"
    end

    def authenticate_sources!
      pins = @summary.fetch('source_pins')
      exact_keys!(pins, %w[ruby_before ruby_after crystal_before crystal_after], 'source pin record')
      repo = File.realpath(File.expand_path('..', __dir__))
      ruby_paths = AuditMultiColumnTupleDynamicW246.ruby_closure(@probe_source)
      crystal_paths = AuditMultiColumnTupleDynamicW246.crystal_closure([@helper_source, @fixture_source], repo)
      ruby_entries = source_entries(ruby_paths)
      crystal_entries = source_entries(crystal_paths)
      verify_source_closure!(pins['ruby_before'], ruby_entries, 'complete current Ruby source closure before capture')
      verify_source_closure!(pins['ruby_after'], ruby_entries, 'complete current Ruby source closure after capture')
      verify_source_closure!(pins['crystal_before'], crystal_entries, 'complete current Crystal/helper source closure before capture')
      verify_source_closure!(pins['crystal_after'], crystal_entries, 'complete current Crystal/helper source closure after capture')
      same!(sha_file(@probe_source), @probe_source_sha, 'external probe source pin')
      same!(sha_file(@helper_source), @helper_source_sha, 'external helper source pin')
      same!(sha_file(@fixture_source), @fixture_source_sha, 'external fixture source pin')
      same!(sha_file(@auditor_source), @auditor_source_sha, 'external auditor source pin')
      ruby_map = ruby_entries.each_with_object({}) { |entry, memo| memo[entry.fetch('path')] = entry.fetch('sha256') }
      audit_paths = AuditMultiColumnTupleDynamicW246.ruby_closure(@auditor_source)
      audit_paths.reject { |path| path == @auditor_source }.each do |path|
        fail!("reused auditor dependency is absent from the probe's captured closure: #{path}") unless ruby_map[path] == sha_file(path)
      end
      true
    end

    def source_entries(paths)
      paths.map { |path| {'path' => path, 'sha256' => sha_file(path)} }
    end

    def verify_source_closure!(observed, expected, label)
      fail!("#{label} is not an array") unless observed.is_a?(Array)
      observed.each do |entry|
        exact_keys!(entry, %w[path sha256], label)
        fail!("#{label} contains a malformed path") unless entry['path'].is_a?(String) && entry['path'].start_with?(File::SEPARATOR)
        checked_sha(entry['sha256'], label)
      end
      same!(observed, expected, label)
    end

    def authenticate_invocations!
      records = @summary.fetch('invocations')
      fail!('invocation roster/order differs') unless records.is_a?(Array) && records.map { |record| record['label'] } == LABELS
      @records = {}
      @details = {}
      names = []
      records.each do |record|
        exact_keys!(record, PROCESS_KEYS, 'process record')
        label = record.fetch('label')
        fail!("duplicate process label #{label}") if @records.key?(label)
        @records[label] = record
        %w[argv_file stdin_file stdout_file stderr_file].each { |field| names << record.fetch(field) }
        names << "#{label}.json"
      end
      same!(Dir.children(root_path('invocations')).sort, names.sort, 'raw invocation artifact inventory')
      LABELS.each do |label|
        record = @records.fetch(label)
        if label == 'crystal_helper'
          @details[label] = authenticate_helper_invocation!(record)
        else
          @details[label] = W241::Auditor.authenticate_w241_invocation!(@root, record, "W246 #{label}")
          same!(record['label'], label, "#{label} raw record label")
          same!(record['argv'], [@clickhouse, 'local', '--path', root_path('stores', 'native'),
            '--session_timezone=UTC', '--max_threads=1', "--max_memory_usage=#{W241::MEMORY}", '--multiquery'],
            "#{label} bounded clickhouse-local argv")
          same!(record['required_outer_run_safe_memory_limit_bytes'], W241::OUTER_RUN_SAFE_LIMIT, "#{label} outer bound")
          same!(@details[label][:input].b, native_input(label).b, "#{label} exact raw SQL")
        end
      end
      true
    rescue KeyError, TypeError, ArgumentError => error
      fail!("raw process validation failed: #{error.class}: #{error.message}")
    rescue StandardError => error
      raise if error.is_a?(Failure)
      fail!("raw process validation failed: #{error.class}: #{error.message}")
    end

    def authenticate_helper_invocation!(record)
      same!(record['label'], 'crystal_helper', 'helper invocation label')
      same!([record['process_kind'], record['process_classification'], record['exit'], record['signal'], record['timed_out']],
            ['crystal-helper', 'success', 0, nil, false], 'helper process outcome')
      same!([record['timeout_seconds'], record['termination_grace_seconds'], record['required_outer_run_safe_memory_limit_bytes']],
            [W241::TIMEOUT, W241::GRACE, W241::OUTER_RUN_SAFE_LIMIT], 'helper process limits')
      same!([record['binary_path'], record['expected_binary_sha256'], record['binary_sha_before'], record['binary_sha_after'],
             record['max_threads'], record['max_memory_usage_bytes'], record['max_memory_usage_applicable'], record['store_path']],
            [@helper, @helper_sha, @helper_sha, @helper_sha, nil, nil, false, nil], 'helper process identity')
      same!([record['argv_file'], record['stdin_file'], record['stdout_file'], record['stderr_file']],
            %w[crystal_helper.argv.json crystal_helper.stdin.bin crystal_helper.stdout crystal_helper.stderr],
            'helper artifact filenames')
      same!(%w[spawn_error stdin_write_error stdout_read_error stderr_read_error].map { |key| record[key]},
            [nil, nil, nil, nil], 'helper process errors')
      same!(record['argv'], [@helper, root_path('generated', PART_NAME), @profile, @mode, @write_mode], 'helper process argv')
      input = read_invocation(record, 'stdin_file', 'stdin_sha256', 'stdin_bytes')
      stdout = read_invocation(record, 'stdout_file', 'stdout_sha256', 'stdout_bytes')
      stderr = read_invocation(record, 'stderr_file', 'stderr_sha256', 'stderr_bytes')
      argv_bytes = read_invocation(record, 'argv_file', 'argv_sha256', nil)
      same!(input, ''.b, 'helper stdin')
      same!(stderr, ''.b, 'helper stderr')
      same!(parse_json!(argv_bytes, 'helper argv artifact'), record['argv'], 'helper argv artifact content')
      raw_record = parse_json!(read_file(root_path('invocations', 'crystal_helper.json'), 1024 * 1024, 'helper raw record'), 'helper raw record')
      same!(raw_record, record, 'helper raw record binding')
      text = stdout.dup.force_encoding(Encoding::UTF_8)
      fail!('helper stdout is not exactly one UTF-8 JSON line') unless text.valid_encoding? && text.lines.size == 1 && text.end_with?("\n")
      manifest = parse_json!(text, 'helper output manifest')
      same!(manifest, @summary.fetch('helper_manifest'), 'helper stdout/summary manifest binding')
      [record, manifest, stdout]
    end

    def read_invocation(record, file_field, sha_field, size_field)
      name = record.fetch(file_field)
      fail!("unsafe invocation artifact name #{name.inspect}") unless name.is_a?(String) && File.basename(name) == name && /\A[A-Za-z0-9_.-]+\z/.match?(name)
      bytes = read_file(root_path('invocations', name), MAX_ARTIFACT_BYTES, "invocation #{name}")
      same!(sha_bytes(bytes), record.fetch(sha_field), "#{name} SHA-256")
      same!(bytes.bytesize, record.fetch(size_field), "#{name} byte count") if size_field
      bytes
    end

    def authenticate_generated_part!
      @part = root_path('generated', PART_NAME)
      @pre_attach = root_path('parts', 'pre_attach', PART_NAME)
      @generated = snapshot(@part)
      @pre_attach_snapshot = snapshot(@pre_attach)
      parts = @summary.fetch('parts')
      exact_keys!(parts, %w[generated pre_attach detached attached marks check schema active_part active_path], 'part evidence record')
      same!(parts['generated'], @generated, 'actual generated regular-file inventory/checksums')
      same!(parts['pre_attach'], @pre_attach_snapshot, 'actual pre-attach regular-file inventory/checksums')
      same!(@pre_attach_snapshot, @generated, 'pre-attach copy/generated file identity')
      same!(parts['detached'], @generated, 'captured detached-copy snapshot/generated identity')
      same!(Dir.children(@part).sort, @generated.map(&:first).sort, 'generated direct-file inventory')
      same!(Dir.children(@pre_attach).sort, @pre_attach_snapshot.map(&:first).sort, 'pre-attach direct-file inventory')
      @manifest = @details.fetch('crystal_helper')[1]
      authenticate_manifest!
      authenticate_physical_layout!
      same!(parts['marks'], @marks, 'summary mark inventory')
      true
    end

    def authenticate_manifest!
      expected_keys = %w[format status part_path write_mode requested_string_profile requested_operation_mode
                         actual_bulk_discriminator_mode frame_bytes rows_per_mark key_column columns keys
                         mark_row_counts rows serialization files]
      exact_keys!(@manifest, expected_keys, 'helper manifest')
      same!([@manifest['format'], @manifest['status'], @manifest['part_path'], @manifest['write_mode'],
             @manifest['requested_string_profile'], @manifest['requested_operation_mode'], @manifest['actual_bulk_discriminator_mode'],
             @manifest['frame_bytes'], @manifest['rows_per_mark'], @manifest['key_column'], @manifest['columns'],
             @manifest['keys'], @manifest['mark_row_counts'], @manifest['rows'], @manifest['serialization']],
            [HELPER_FORMAT, 'part_created', @part, @write_mode, @profile, @mode, 'basic', FRAME, 2, KEY,
             expected_columns, [1, 2, 3, 4, 5], MARK_ROWS, expected_rows, expected_serialization],
            'literal helper manifest contract')
      manifest_files = @manifest.fetch('files').map do |entry|
        exact_keys!(entry, %w[path size sha256], 'helper file inventory entry')
        [entry.fetch('path'), entry.fetch('size'), checked_sha(entry.fetch('sha256'), 'helper file')]
      end
      same!(manifest_files, @generated, 'raw helper file roster/current generated files')
      true
    end

    def snapshot(path)
      fail!("part tree is absent, symlinked, or noncanonical: #{path}") unless File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path
      result = []
      total = 0
      Find.find(path) do |entry|
        stat = File.lstat(entry)
        fail!("part contains a symlink or special entry: #{entry}") unless !stat.symlink? && (stat.directory? || stat.file?)
        next if stat.directory?
        relative = entry.delete_prefix(path + File::SEPARATOR)
        fail!('part must contain direct child regular files only') if relative.include?(File::SEPARATOR)
        total += stat.size
        fail!('part exceeds file/count/byte bounds') unless stat.size <= MAX_PART_FILE_BYTES && total <= MAX_PART_BYTES && result.size < 4096
        result << [relative, stat.size, sha_file(entry)]
      end
      result.sort
    end

    def read_part(path, name, limit)
      fail!("unsafe part filename #{name.inspect}") unless name.is_a?(String) && File.basename(name) == name && /\A[A-Za-z0-9_.-]+\z/.match?(name)
      read_file(File.join(path, name), limit, "part file #{name}")
    end

    def authenticate_physical_layout!
      expected_columns_text = "columns format version: 1\n#{expected_columns.size + 1} columns:\n`pk` UInt64\n" +
        expected_columns.map { |column| "`#{column.fetch('name')}` #{column.fetch('type')}\n" }.join
      same!(read_part(@part, 'columns.txt', 1024 * 1024), expected_columns_text.b, 'ordered physical columns')
      actual_serialization = parse_json!(read_part(@part, 'serialization.json', 1024 * 1024), 'serialization.json')
      same!(actual_serialization, expected_serialization, 'raw serialization.json')
      same!(read_part(@part, 'default_compression_codec.txt', 1024).strip, 'CODEC(LZ4)', 'default codec')
      same!(read_part(@part, 'metadata_version.txt', 1024).strip, '0', 'metadata version')
      same!(read_part(@part, 'count.txt', 1024).strip, '5', 'physical row count')
      sections = parse_substreams(read_part(@part, 'columns_substreams.txt', 4 * 1024 * 1024))
      same!(sections.map(&:first), (['pk'] + expected_columns.map { |column| column.fetch('name') }), 'logical column roster/order')
      fail!('key logical substream is not exactly pk') unless sections.first == ['pk', ['pk']]
      fail!('a declared value column has no logical stream') unless sections.drop(1).all? { |_column, streams| !streams.empty? }
      streams = sections.flat_map(&:last)
      fail!('logical substream names are duplicated') unless streams.uniq == streams
      stems = streams.map { |stream| W241::Auditor.stream_hash(stream) }
      fail!('logical substreams collide in physical filename hashes') unless stems.uniq == stems
      stream_files = stems.flat_map { |stem| ["#{stem}.bin", "#{stem}.mrk2"] }
      fail!('physical file roster does not match every logical stream') unless
        @generated.map(&:first).sort == (BASE_FILES + stream_files).sort
      @marks = streams.map do |stream|
        name = "#{W241::Auditor.stream_hash(stream)}.mrk2"
        bytes = read_part(@part, name, MAX_PART_FILE_BYTES)
        fail!("#{name} is not a complete nonempty mark triple stream") if bytes.empty? || (bytes.bytesize % 24) != 0
        tuples = bytes.unpack('Q<*').each_slice(3).map(&:dup)
        same!(tuples.map { |tuple| tuple.fetch(2) }, MARKS_WITH_EOF, "mark row counts for #{stream}")
        {'name' => name, 'sha256' => sha_bytes(bytes), 'tuples' => tuples}
      end.sort_by { |mark| mark.fetch('name') }
      true
    end

    def parse_substreams(bytes)
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      fail!('columns_substreams.txt is invalid UTF-8') unless text.valid_encoding?
      lines = text.split("\n", -1)
      fail!('columns_substreams envelope/final newline differs') unless lines.pop == '' && lines.shift == 'columns substreams version: 1'
      count_header = /\A([1-9][0-9]*) columns:\z/.match(lines.shift.to_s)
      fail!('columns_substreams column count differs') unless count_header && count_header[1].to_i == expected_columns.size + 1
      sections = []
      until lines.empty?
        header = /\A(0|[1-9][0-9]*) substreams for column `([a-z][a-z0-9_]*)`:\z/.match(lines.shift.to_s)
        fail!('malformed columns_substreams section header') unless header
        amount = Integer(header[1], 10)
        fail!('columns_substreams section exceeds bounds') unless amount <= 4096 && lines.size >= amount
        streams = amount.times.map do
          row = /\A\t([A-Za-z0-9_.%]+)\z/.match(lines.shift.to_s)
          fail!('malformed logical substream name') unless row
          row[1]
        end
        sections << [header[2], streams]
      end
      sections
    end

    def authenticate_attached_part!
      parts = @summary.fetch('parts')
      paths = @summary.fetch('paths')
      exact_keys!(paths, %w[generated pre_attach detached attached data_path], 'part path record')
      same!([paths['generated'], paths['pre_attach']], [@part, @pre_attach], 'generated/pre-attach paths')
      @data_path = canonical_store_path(parts.fetch('active_path'), 'active part')
      same!(parts['active_path'], @data_path, 'active path binding')
      same!(paths['attached'], @data_path, 'attached path binding')
      same!(paths['data_path'], File.dirname(@data_path), 'table data path binding')
      @detached = File.join(paths['data_path'], 'detached', PART_NAME)
      same!(paths['detached'], @detached, 'detached path binding')
      same!(@data_path, root_path('stores', 'native') + File::SEPARATOR + relative_store_suffix(@data_path), 'native store containment')
      fail!('detached source remains after ATTACH') if File.exist?(@detached) || File.symlink?(@detached)
      @attached_snapshot = snapshot(@data_path)
      same!(parts['attached'], @attached_snapshot, 'actual attached regular-file inventory/checksums')
      generated_map = @generated.each_with_object({}) { |(name, size, hash), map| map[name] = [size, hash] }
      attached_map = @attached_snapshot.each_with_object({}) { |(name, size, hash), map| map[name] = [size, hash] }
      same!(attached_map.keys.sort, (generated_map.keys + ['invalidated_system_columns.txt']).sort, 'attached file names')
      generated_map.each { |name, identity| same!(attached_map[name], identity, "ATTACH preserved #{name}") }
      same!(read_part(@data_path, 'invalidated_system_columns.txt', 1024), "_block_offset\n_block_number\n".b, 'ATTACH invalidation metadata')
      true
    end

    def relative_store_suffix(path)
      prefix = root_path('stores', 'native') + File::SEPARATOR
      fail!('active part escaped its isolated native store') unless path.start_with?(prefix)
      suffix = path.delete_prefix(prefix)
      fail!('active part has unexpected path depth/name') unless suffix.split(File::SEPARATOR, -1).last == PART_NAME
      suffix
    end

    def canonical_store_path(path, label)
      fail!("#{label} path is not a canonical absolute path") unless
        path.is_a?(String) && path.start_with?(File::SEPARATOR) && !path.include?("\0") &&
        !path.end_with?(File::SEPARATOR * 2)
      normalized = path.end_with?(File::SEPARATOR) ? path[0...-1] : path
      fail!("#{label} path is not canonical") unless !normalized.empty? && File.expand_path(normalized) == normalized
      root = root_path('stores', 'native')
      prefix = root + File::SEPARATOR
      fail!("#{label} path escaped the isolated native store") unless normalized.start_with?(prefix)
      current = root
      normalized.delete_prefix(prefix).split(File::SEPARATOR).each do |component|
        fail!("#{label} path contains invalid component") if component.empty? || component == '.' || component == '..'
        current = File.join(current, component)
        fail!("#{label} path contains symlink") if File.symlink?(current)
      end
      fail!("#{label} directory is absent or noncanonical") unless File.directory?(normalized) && File.realpath(normalized) == normalized
      normalized
    end

    def native_sql(label)
      case label
      when 'native_create_table'
        declarations = ([KEY] + expected_columns).map { |column| "`#{column.fetch('name')}` #{column.fetch('type')}" }.join(', ')
        ["CREATE TABLE default.#{@table} (#{declarations}) ENGINE=MergeTree ORDER BY pk SETTINGS #{reader_settings};",
         "SELECT '#{TAGS[:path]}', database, name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{@table}' FORMAT TSVRaw;"].join("\n")
      when 'native_attach_check'
        ["ALTER TABLE default.#{@table} ATTACH PART '#{PART_NAME}';",
         "SELECT '#{TAGS[:check_begin]}' FORMAT TSVRaw;", "CHECK TABLE default.#{@table} FORMAT TSV;",
         "SELECT '#{TAGS[:check_end]}' FORMAT TSVRaw;",
         "SELECT '#{TAGS[:schema]}', name, type FROM system.columns WHERE database='default' AND table='#{@table}' ORDER BY position FORMAT TSVRaw;",
         "SELECT '#{TAGS[:part]}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{@table}' AND active ORDER BY name FORMAT TSVRaw;"].join("\n")
      when 'native_typed_values'
        expressions = ['toTypeName(named_tuple)', 'toTypeName(named_tuple.sequence)', dynamic_witness('named_tuple.sequence'),
                       'toTypeName(named_tuple.items)', 'toString(length(named_tuple.items))']
        if @write_mode == 'multi'
          expressions.concat(['toTypeName(unnamed_tuple)', 'toTypeName(unnamed_tuple.1)', dynamic_witness('unnamed_tuple.1'),
                              'toTypeName(unnamed_tuple.2)', dynamic_witness('unnamed_tuple.2')])
        end
        "SELECT '#{TAGS[:values]}', toString(pk), #{expressions.join(', ')} FROM default.#{@table} ORDER BY pk FORMAT TSVRaw;"
      when 'native_array_children'
        "SELECT '#{TAGS[:children]}', toString(pk), toString(item_index), toTypeName(item), #{dynamic_witness('item')} " \
          "FROM default.#{@table} ARRAY JOIN arrayEnumerate(named_tuple.items) AS item_index, named_tuple.items AS item ORDER BY pk, item_index FORMAT TSVRaw;"
      else
        fail!("unexpected native label #{label.inspect}")
      end
    end

    def dynamic_witness(expression)
      "if(isNull(#{expression}), 'NULL', dynamicType(#{expression})), if(isNull(#{expression}), 'null', hex(toJSONString(#{expression})))"
    end

    def reader_settings
      W241::Probe.allocate.send(:settings, @reader_profile)
    end

    def native_input(label)
      pin = W241::Probe.allocate.send(:pin_sql)
      [pin, 'SET print_pretty_type_names=0;', native_sql(label)].join("\n") + "\n"
    end

    def replay_native_outputs!
      create_lines = lines(@details.fetch('native_create_table')[:stdout])
      path_rows = tagged(create_lines, TAGS[:path], 4)
      same!(path_rows.size, 1, 'native table path result count')
      same!(path_rows.first.values_at(1, 2), ['default', @table], 'native table identity')
      raw_data_path = path_rows.first[3]
      normalized_data_path = canonical_store_path(raw_data_path, 'native created data path')
      create_data_path = canonical_store_path(normalized_data_path + File::SEPARATOR + PART_NAME, 'created table')
      same!(File.dirname(create_data_path), @summary.fetch('paths').fetch('data_path'), 'native created table data path')
      expected_create_lines = ["__W241_PIN__\t#{W241::VERSION}\t#{W241::BUILD}", path_rows.first.join("\t")]
      same!(create_lines, expected_create_lines, 'native create raw stdout')

      attach_lines = lines(@details.fetch('native_attach_check')[:stdout])
      check = verify_check_result!(attach_lines)
      schema_rows = tagged(attach_lines, TAGS[:schema], 3).map { |row| row.drop(1) }
      same!(schema_rows, expected_schema.map { |column| [column.fetch('name'), column.fetch('type')] }, 'stock schema and field order')
      part_rows = tagged(attach_lines, TAGS[:part], 7)
      same!(part_rows.size, 1, 'active part count')
      part = part_rows.first
      same!(part.values_at(1, 2, 4, 5, 6), [@table, PART_NAME, 'Wide', '5', '4'], 'active one-part identity/count')
      same!(canonical_store_path(part[3], 'active part'), @summary.fetch('parts').fetch('active_path'), 'native active part path')
      expected_attach_lines = ["__W241_PIN__\t#{W241::VERSION}\t#{W241::BUILD}", TAGS[:check_begin],
        "#{PART_NAME}\t1\t", TAGS[:check_end]] + schema_rows.map { |row| ([TAGS[:schema]] + row).join("\t") } + [part.join("\t")]
      same!(attach_lines, expected_attach_lines, 'native ATTACH/CHECK raw stdout and tagged output roster')
      same!(@summary.fetch('parts').fetch('check'), check, 'summary CHECK result')
      same!(@summary.fetch('parts').fetch('schema'), schema_rows, 'summary stock schema')
      same!(@summary.fetch('parts').fetch('active_part'), part.drop(1), 'summary active part row')
      replay_values!
      replay_children!
      true
    end

    def lines(stdout)
      text = stdout.dup.force_encoding(Encoding::UTF_8)
      fail!('native stdout is not valid UTF-8 or lacks final newline') unless text.valid_encoding? && text.end_with?("\n")
      text.lines.map(&:chomp)
    end

    def tagged(rows, tag, width)
      rows.select { |line| line.start_with?(tag + "\t") }.map do |line|
        fields = line.split("\t", -1)
        same!(fields.size, width, "#{tag} TSV field count")
        fields
      end
    end

    def check_lines(rows)
      active = false
      checks = []
      rows.each do |line|
        if line == TAGS[:check_begin]
          fail!('nested CHECK begin marker') if active
          active = true
        elsif line == TAGS[:check_end]
          fail!('unmatched CHECK end marker') unless active
          active = false
        elsif active
          checks << line
        end
      end
      fail!('unterminated CHECK markers') if active
      checks
    end

    def verify_check_result!(rows)
      checks = check_lines(rows)
      same!(checks, ["#{PART_NAME}\t1\t"], 'stock ATTACH CHECK=1')
      checks
    end

    def compare_dynamic!(actual_type, json_hex, expected)
      expected_type = expected.fetch('actual_type') || 'NULL'
      same!(actual_type, expected_type, 'Dynamic actual type')
      if expected_type == 'NULL'
        same!(json_hex, 'null', 'NULL Dynamic JSON witness')
        actual_value = nil
      else
        fail!('Dynamic JSON witness is not even-length hexadecimal') unless json_hex.is_a?(String) && /\A(?:[0-9a-fA-F]{2})+\z/.match?(json_hex)
        actual_value = parse_json!([json_hex].pack('H*'), 'Dynamic JSON witness')
      end
      same!(actual_value, expected.fetch('value'), 'Dynamic semantic value')
    end

    def replay_values!
      expected = AuditMultiColumnTupleDynamicW246.rows
      observed = tagged(lines(@details.fetch('native_typed_values')[:stdout]), TAGS[:values], @write_mode == 'multi' ? 15 : 8)
      same!(observed.size, expected.size, 'typed row count')
      observed.zip(expected).each do |row, want|
        same!(row[1], want.fetch('pk').to_s, 'typed row key/order')
        named = want.fetch('named_tuple')
        same!(row.values_at(2, 3, 6, 7), [NAMED_TYPE, DYNAMIC, ARRAY_DYNAMIC, named.fetch('items').length.to_s], 'named Tuple declaration/Array count')
        compare_dynamic!(row[4], row[5], named.fetch('sequence'))
        next if @write_mode == 'legacy'
        unnamed = want.fetch('unnamed_tuple')
        same!(row.values_at(8, 9, 12), [UNNAMED_TYPE, DYNAMIC, DYNAMIC], 'unnamed Tuple declaration/field order')
        compare_dynamic!(row[10], row[11], unnamed[0])
        compare_dynamic!(row[13], row[14], unnamed[1])
      end
      same!(lines(@details.fetch('native_typed_values')[:stdout]).size, observed.size + 1, 'typed output has only runtime pin plus rows')
    end

    def replay_children!
      expected = child_oracle
      observed = tagged(lines(@details.fetch('native_array_children')[:stdout]), TAGS[:children], 6)
      verify_children!(observed, expected)
      same!(lines(@details.fetch('native_array_children')[:stdout]).size, observed.size + 1, 'Array child output has only runtime pin plus children')
    end

    def verify_children!(observed, expected)
      same!(observed.size, expected.size, 'Array child occurrence count/order')
      observed.zip(expected).each do |actual, (pk, index, item)|
        same!(actual[0], TAGS[:children], 'Array child tag')
        same!(actual.values_at(1, 2, 3), [pk, index, DYNAMIC], 'Array child row/position/type')
        compare_dynamic!(actual[4], actual[5], item)
      end
      true
    end

    def self_test!
      controls = {}
      expected = AuditMultiColumnTupleDynamicW246.dynamic('UInt64', 'dedicated', 7)
      controls['exact_type_value_accepted'] = dynamic_valid?('UInt64', '37', expected)
      controls['same_value_wrong_actual_type_rejected'] = !dynamic_valid?('UInt8', '37', expected)
      controls['uppercase_hex_accepted'] = dynamic_valid?('String', '226A22', AuditMultiColumnTupleDynamicW246.dynamic('String', 'shared', 'j'))
      child_rows = encoded_child_oracle
      controls['missing_child_rejected'] = !children_valid?(child_rows[0...-1], child_oracle)
      controls['swapped_child_rejected'] = !children_valid?(child_rows.reverse, child_oracle)
      controls['check_zero_rejected'] = !check_valid?("#{PART_NAME}\t0\t")
      closure = [{'path' => '/a', 'sha256' => 'a' * 64}, {'path' => '/b', 'sha256' => 'b' * 64}]
      controls['incomplete_source_closure_rejected'] = !source_closure_valid?(closure[0...-1], closure)
      fail!('auditor adversary controls did not reject the expected mutations') unless controls.values.all?
      controls
    end

    def dynamic_valid?(actual_type, json_hex, expected)
      compare_dynamic!(actual_type, json_hex, expected)
      true
    rescue Failure
      false
    end

    def child_oracle
      AuditMultiColumnTupleDynamicW246.rows.flat_map do |row|
        row.fetch('named_tuple').fetch('items').each_with_index.map do |item, index|
          [row.fetch('pk').to_s, (index + 1).to_s, item]
        end
      end
    end

    def encoded_child_oracle
      child_oracle.map do |pk, index, item|
        [TAGS[:children], pk, index, DYNAMIC, item.fetch('actual_type') || 'NULL', witness_hex(item)]
      end
    end

    def witness_hex(item)
      item.fetch('actual_type').nil? ? 'null' : JSON.generate(item.fetch('value')).unpack('H*').first
    end

    def children_valid?(observed, expected)
      verify_children!(observed, expected)
      true
    rescue Failure
      false
    end

    def check_valid?(line)
      verify_check_result!([TAGS[:check_begin], line, TAGS[:check_end]])
      true
    rescue Failure
      false
    end

    def source_closure_valid?(observed, expected)
      verify_source_closure!(observed, expected, 'self-test source closure')
      true
    rescue Failure
      false
    end
  end
end

def main
  options = {}
  parser = OptionParser.new do |opts|
    opts.banner = 'Usage: ruby scripts/audit_multi_column_tuple_dynamic_w246.rb --summary PATH --summary-sha256 SHA --clickhouse PATH --helper PATH --helper-sha256 SHA --probe-source PATH --probe-source-sha256 SHA --helper-source PATH --helper-source-sha256 SHA --fixture-source PATH --fixture-source-sha256 SHA --auditor-source PATH --auditor-source-sha256 SHA --self-test'
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
    auditor = AuditMultiColumnTupleDynamicW246::Auditor.allocate
    controls = auditor.send(:self_test!)
    puts JSON.generate(status: 'self_test_passed', controls: controls)
    return
  end
  %i[summary_path summary_sha256 clickhouse helper_path helper_sha256 probe_source probe_source_sha256
     helper_source helper_source_sha256 fixture_source fixture_source_sha256 auditor_source auditor_source_sha256].each do |key|
    raise ArgumentError, "--#{key.to_s.tr('_', '-')} is required" unless options[key]
  end
  puts JSON.generate(AuditMultiColumnTupleDynamicW246::Auditor.new(**options).run)
rescue AuditMultiColumnTupleDynamicW246::Failure, ArgumentError, KeyError, TypeError => error
  warn error.message
  exit 1
end

main if $PROGRAM_NAME == __FILE__
