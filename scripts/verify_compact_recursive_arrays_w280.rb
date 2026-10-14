#!/usr/bin/env ruby
# Read-only auditor for the captured W280 Compact recursive-Array matrix.
# Validates source-bound literals, raw invocation/part sidecars, and plain MRK
# metadata without launching ClickHouse, Crystal, or a build.

require 'digest'
require 'find'
require 'json'
require 'open3'
require 'optparse'
require 'tmpdir'
require 'fileutils'
require_relative 'probe_compact_recursive_arrays_w280_matrix'

module VerifyCompactRecursiveArraysW280
  Matrix = ProbeCompactRecursiveArraysW280Matrix
  W280 = Matrix::W280
  FORMAT = 'compact_recursive_arrays_w280_matrix_v1'.freeze
  HELPER_FORMAT = 'compact_recursive_arrays_w280_helper_v3'.freeze
  EXPECTED_STATUS = 'generated_native_interop_matrix_exact'.freeze
  PIN_SQL = "SELECT '__W280_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;\n".b.freeze
  PIN_LINE = "__W280_PIN__\t#{W280::VERSION}\t#{W280::BUILD}".freeze
  TICK = "\x60".freeze
  MAX_SUMMARY_BYTES = 16 * 1024 * 1024
  MAX_CAPTURE_BYTES = 16 * 1024 * 1024
  MAX_PART_FILES = 256
  MAX_PART_BYTES = 128 * 1024 * 1024
  MAX_PART_FILE_BYTES = 64 * 1024 * 1024
  INVOCATION_RECORD_BASE_KEYS = %w[
    label process_kind argv argv_file argv_sha256 stdin_file stdin_bytes stdin_sha256
    stdout_file stdout_bytes stdout_sha256 stderr_file stderr_bytes stderr_sha256
    exit signal timed_out timeout_seconds termination_grace_seconds max_threads
    max_memory_usage_bytes max_memory_usage_applicable required_outer_run_safe_memory_limit_bytes
    binary_path expected_binary_sha256 binary_sha_before binary_sha_after
    spawn_error stdin_write_error stdout_read_error stderr_read_error
    process_classification store_path
  ].sort.freeze
  INVOCATION_RECORD_NATIVE_ROWBINARY_KEYS = (INVOCATION_RECORD_BASE_KEYS + ['stdin_encoding']).sort.freeze
  INVOCATION_RECORD_KEY_VARIANTS = [INVOCATION_RECORD_BASE_KEYS, INVOCATION_RECORD_NATIVE_ROWBINARY_KEYS].freeze
  ROW_BYTES_PER_SLOT = 16
  ROW_COUNT_BYTES = 8
  RAW_MARK_FILE_ROWS = [2, 2, 2, 2, 0].freeze
  PUBLIC_READER_MARK_ROWS = [2, 2, 2, 2].freeze
  ATTACHED_NATIVE_SIDECAR_PATH = 'invalidated_system_columns.txt'.freeze
  ATTACHED_NATIVE_SIDECAR_BYTES = "_block_offset\n_block_number\n".b.freeze
  ATTACHED_NATIVE_SIDECAR_ENTRY = {
    'path' => ATTACHED_NATIVE_SIDECAR_PATH,
    'size' => 28,
    'sha256' => '7409424ab45090c1261e622f7423393905102e7e8cba36a6db88eb513ce1e06c',
  }.freeze
  ATTACHED_INVENTORY_CONTRACT_STATE = 'generated_files_byte_preserved_with_exact_native_sidecar'.freeze

  class AuditFailure < StandardError; end

  class Auditor
    def initialize(root)
      @root = canonical_directory!(File.expand_path(root), 'evidence root')
      @summary = JSON.parse(read_root_file!('summary.json', max_bytes: MAX_SUMMARY_BYTES))
    rescue JSON::ParserError => error
      raise AuditFailure, "summary.json is malformed: #{error.message}"
    end

    def run
      validate_summary!
      validate_pins!
      validate_invocations!
      validate_cases!
      puts "W280 evidence audit passed: status=#{EXPECTED_STATUS}; cases=10; invocations=#{@records.size}; root=#{@root}"
      true
    rescue StandardError => error
      warn "W280 evidence audit failed: #{error.class}: #{error.message}"
      false
    end

    def self.self_test!
      auditor = allocate
      auditor.instance_variable_set(:@root, '/private/tmp/w280-auditor-self-test')
      auditor.instance_variable_set(:@summary, {})
      auditor.send(:self_test_core!)
      puts 'W280 auditor Ruby-only self-test passed (no native or Crystal execution).'
      true
    rescue StandardError => error
      warn "W280 auditor self-test failed: #{error.class}: #{error.message}"
      false
    end

    private

    def need!(condition, message)
      raise AuditFailure, message unless condition
    end

    def canonical_directory!(path, label)
      need!(path.is_a?(String) && path == File.expand_path(path), "#{label} path is not canonical")
      stat = File.lstat(path)
      need!(stat.directory? && !stat.symlink? && File.realpath(path) == path, "#{label} is absent, symlinked, or non-canonical: #{path}")
      path
    rescue Errno::ENOENT
      raise AuditFailure, "#{label} is absent: #{path}"
    end

    def canonical_file!(path, label, max_bytes: MAX_CAPTURE_BYTES)
      stat = File.lstat(path)
      need!(stat.file? && !stat.symlink? && File.realpath(path) == path, "#{label} is absent, non-regular, symlinked, or non-canonical: #{path}")
      need!(stat.size <= max_bytes, "#{label} exceeds #{max_bytes} bytes")
      path
    rescue Errno::ENOENT
      raise AuditFailure, "#{label} is absent: #{path}"
    end

    def safe_relative!(relative, label)
      need!(relative.is_a?(String) && !relative.empty?, "#{label} is missing")
      pieces = relative.split(/[\\\/]/, -1)
      need!(!relative.start_with?('/', '\\') && pieces.none? { |piece| piece.empty? || piece == '.' || piece == '..' },
            "#{label} is not a safe relative path: #{relative.inspect}")
      relative
    end

    def read_root_file!(relative, max_bytes: MAX_CAPTURE_BYTES)
      safe_relative!(relative, 'evidence sidecar path')
      path = File.join(@root, relative)
      canonical_directory!(File.dirname(path), "sidecar parent for #{relative}")
      canonical_file!(path, relative, max_bytes: max_bytes)
      File.binread(path)
    end

    def sha(bytes)
      Digest::SHA256.hexdigest(bytes)
    end

    def file_sha(path, label, max_bytes: MAX_PART_FILE_BYTES)
      canonical_file!(path, label, max_bytes: max_bytes)
      Digest::SHA256.file(path).hexdigest
    end

    def json_clone(value)
      JSON.parse(JSON.generate(value))
    end

    def validate_summary!
      need!(@summary.is_a?(Hash), 'summary root is not an object')
      need!(@summary['format'] == FORMAT && @summary['status'] == EXPECTED_STATUS,
            "expected a full-matrix summary with status #{EXPECTED_STATUS}")
      need!(@summary['evidence_root'] == @root, 'summary evidence_root differs from canonical audit root')
      need!(@summary['claim_boundary'].is_a?(String) &&
            @summary['claim_boundary'].include?('byte-for-byte preservation of every generated file through ATTACH') &&
            @summary['claim_boundary'].include?('exactly one pinned native invalidated_system_columns.txt sidecar with exact bytes') &&
            @summary['claim_boundary'].include?('No arbitrary type-topology or performance claim'),
            'summary claim boundary is absent or widened')
      expected_parameters = {
        'object_serialization_version' => 'v3',
        'object_shared_data_serialization_version' => 'map',
        'map_layout_value' => 0,
        'object_shared_data_buckets_for_compact_part' => 1,
        'string_serialization_version' => 'single_stream (S0)',
        'mark_compression' => 'plain',
        'variant_discriminator_mode' => 'basic',
        'mark_formats' => Matrix::MARK_FORMATS,
      }
      need!(@summary['schema_parameters'] == expected_parameters, 'top-level schema parameter pin differs')
      fixture = @summary.fetch('fixture')
      need!(fixture['schemas'] == Matrix::SCHEMAS, 'fixture schemas differ from checked-in literal schema oracle')
      need!(fixture['literal_rows'] == Matrix::ROWS, 'fixture rows differ from checked-in literal row oracle')
      need!(fixture['row_count'] == Matrix::ROW_COUNT && fixture['rows_per_mark'] == Matrix::ROWS_PER_MARK &&
            fixture['data_marks'] == Matrix::DATA_MARK_COUNT, 'literal row/mark parameters differ')
      need!(fixture['raw_mark_file_rows'] == RAW_MARK_FILE_ROWS &&
            fixture['public_reader_mark_rows'] == PUBLIC_READER_MARK_ROWS,
            'literal raw mark-file/public reader grids differ')
      need!(RAW_MARK_FILE_ROWS.size == Matrix::DATA_MARK_COUNT + 1 &&
            PUBLIC_READER_MARK_ROWS.size == Matrix::DATA_MARK_COUNT &&
            RAW_MARK_FILE_ROWS != PUBLIC_READER_MARK_ROWS,
            'raw mark-file EOF sentinel and public data-mark grids were conflated')
      need!(fixture['native_windows'] == Matrix::WINDOWS &&
            fixture['physical_windows'] == Matrix::PHYSICAL_WINDOWS &&
            fixture['typed_windows'] == Matrix::TYPED_WINDOWS, 'physical or typed window oracle differs')
      expected_site_counts = Matrix::CASES.to_h { |kind| [kind, Matrix::JSON_SITE_COUNTS.fetch(kind)] }
      need!(fixture['json_site_counts'] == expected_site_counts, 'JSON-site count basis differs')
      need!(fixture['json_site_domain_counts'] == json_site_domain_oracle,
            'JSON-site domains differ from traversal of independent literal rows')

      @cases = @summary['cases']
      @case_ids = Matrix::MARK_FORMATS.flat_map { |mark| Matrix::CASES.map { |kind| "#{kind}_#{mark}" } }
      need!(@cases.is_a?(Hash) && @cases.keys.sort == @case_ids.sort,
            'summary does not contain exactly ten stock/generated basis cells')
      @cases.each do |id, entry|
        kind, mark = parse_case_id(id)
        need!(entry['case_id'] == id && entry['schema_kind'] == kind && entry['mark_format'] == mark,
              "#{id} case identity differs")
        need!(entry['status'] == 'exact_native_values', "#{id} stock observation is not exact native values")
        need!(entry['schema_parameters'] == case_schema_parameters, "#{id} case schema parameters differ")
        need!(entry['table'] == table_name(id) && entry['store'] == File.join(@root, 'stores', id),
              "#{id} stock table/store identity differs")
        need!(entry.dig('library_stock_read', 'status') == 'exact_public_recursive_and_typed_reads',
              "#{id} public stock read is not exact")
        generated = entry['library_generated']
        need!(generated.is_a?(Hash) && generated['status'] == 'exact_generated_native_interop',
              "#{id} generated writer/native interop is not exact")
        generated_inventory = generated.fetch('inventory')
        expected_attached_contract = {
          'state' => ATTACHED_INVENTORY_CONTRACT_STATE,
          'generated_file_count' => generated_inventory.fetch('files').size,
          'native_sidecar' => ATTACHED_NATIVE_SIDECAR_ENTRY,
        }
        need!(generated['attached_inventory_contract'] == expected_attached_contract,
              "#{id} attached generated-byte/native-sidecar contract report differs")
        need!(entry['windows'].is_a?(Hash) && entry['windows'].keys.sort == Matrix::WINDOWS.keys.sort &&
              generated['native_windows'].is_a?(Hash) &&
              generated['native_windows'].keys.sort == Matrix::WINDOWS.keys.sort,
              "#{id} full/middle/last/EOF window roster differs")
      end
      validate_invocation_topology!
      true
    rescue KeyError => error
      raise AuditFailure, "summary is missing a required field: #{error.message}"
    end

    def case_schema_parameters
      {
        'object_serialization_version' => 'v3',
        'object_shared_data_serialization_version' => 'map',
        'map_layout_value' => 0,
        'buckets' => 1,
        'string_serialization_version' => 'single_stream (S0)',
        'mark_compression' => 'plain',
        'variant_discriminator_mode' => 'basic',
      }
    end

    def parse_case_id(id)
      mark = Matrix::MARK_FORMATS.find { |candidate| id.end_with?("_#{candidate}") }
      kind = mark && id.delete_suffix("_#{mark}")
      need!(mark && Matrix::CASES.include?(kind), "invalid case id #{id.inspect}")
      [kind, mark]
    end

    def table_name(id)
      token = Digest::SHA256.hexdigest(@root)[0, 8]
      "w280m_#{token}_#{id}"
    end

    def expected_target_table(id)
      table_name("target_#{id}")
    end

    def json_site_domain_oracle
      Matrix::CASES.to_h do |kind|
        counts = Hash.new(0)
        Matrix::ROWS.fetch(kind).each do |row|
          walk_json_domains(Matrix::TYPE_DEFS.fetch(kind), row, 'root', counts)
        end
        [kind, counts.sort.to_h]
      end
    end

    def walk_json_domains(type, value, path, counts)
      case type.kind
      when :json
        counts[path] += 1
      when :uint8
        nil
      when :array
        value.each { |child| walk_json_domains(type.child, child, "#{path}/array[0]", counts) }
      when :tuple
        type.fields.each_with_index do |(name, child_type), index|
          child = value.is_a?(Hash) ? value.fetch(name) : value.fetch(index)
          walk_json_domains(child_type, child, "#{path}/tuple[#{index}]", counts)
        end
      else
        raise AuditFailure, "unknown literal type node #{type.kind.inspect}"
      end
    end

    def validate_pins!
      runtime = @summary.fetch('runtime_pin')
      need!(runtime['binary'] == W280::BINARY && runtime['expected_sha256'] == W280::BINARY_SHA256 &&
            runtime['sha256_before'] == W280::BINARY_SHA256 && runtime['sha256_after'] == W280::BINARY_SHA256 &&
            runtime['version'] == W280::VERSION && runtime['build'] == W280::BUILD,
            'runtime pin metadata differs from W280 pin')
      actual_runtime_sha = file_sha(W280::BINARY, 'pinned ClickHouse runtime', max_bytes: 1024 * 1024 * 1024)
      need!(actual_runtime_sha == W280::BINARY_SHA256, 'actual ClickHouse runtime bytes differ from pinned SHA-256')

      source = @summary.fetch('source_pin')
      need!(source['root'] == W280::SOURCE_ROOT && source['revision_expected'] == W280::SOURCE_REVISION &&
            source['revision_before'] == W280::SOURCE_REVISION && source['revision_after'] == W280::SOURCE_REVISION,
            'source revision pin metadata differs from W280 pin')
      revision, stderr, status = Open3.capture3('git', '-C', W280::SOURCE_ROOT, 'rev-parse', 'HEAD')
      need!(status.success? && stderr.empty? && revision.strip == W280::SOURCE_REVISION,
            'actual upstream checkout HEAD differs from separate W280 source pin')
      before = source.fetch('source_sha256_before')
      after = source.fetch('source_sha256_after')
      expected_sources = W280::SOURCE_FILES
      need!(before.is_a?(Hash) && before.keys.sort == expected_sources.sort &&
            after.is_a?(Hash) && after.keys.sort == expected_sources.sort && before == after,
            'upstream source before/after seal roster differs')
      actual_sources = expected_sources.to_h do |relative|
        path = File.join(W280::SOURCE_ROOT, relative)
        need!(File.file?(path) && !File.symlink?(path), "pinned upstream source is absent or symlinked: #{relative}")
        [relative, file_sha(path, "upstream source #{relative}", max_bytes: MAX_CAPTURE_BYTES)]
      end
      need!(before == actual_sources, 'upstream source seal differs from current pinned source bytes')

      helper = @summary.fetch('helper_pin')
      need!(helper.is_a?(Hash) && helper['source'] == Matrix::HELPER_SOURCE,
            'helper pin is absent or points to another source')
      helper_sha = helper.fetch('expected_sha256')
      need!(helper['sha256_before'] == helper_sha && helper['sha256_after'] == helper_sha &&
            helper_sha.match?(/\A[0-9a-f]{64}\z/), 'helper before/after SHA pin differs')
      helper_path = canonical_file!(helper.fetch('path'), 'prebuilt helper', max_bytes: 1024 * 1024 * 1024)
      need!(File.executable?(helper_path) && file_sha(helper_path, 'prebuilt helper', max_bytes: 1024 * 1024 * 1024) == helper_sha,
            'actual prebuilt helper differs from captured SHA pin')

      pins = @summary.fetch('matrix_source_pins')
      pin_before = pins.fetch('sha256_before')
      pin_after = pins.fetch('sha256_after')
      source_paths = [Matrix::PROBE_SOURCE, Matrix::HELPER_SOURCE, Matrix::FIXTURE_SOURCE].map { |path| File.realpath(path) }.uniq.sort
      need!(pin_before.is_a?(Hash) && pin_before.keys.sort == source_paths &&
            pin_after.is_a?(Hash) && pin_after.keys.sort == source_paths && pin_before == pin_after,
            'matrix source before/after seal roster differs')
      current = source_paths.to_h do |path|
        need!(File.file?(path) && !File.symlink?(path), "matrix source is absent or symlinked: #{path}")
        [path, file_sha(path, "matrix source #{path}", max_bytes: MAX_CAPTURE_BYTES)]
      end
      need!(pin_before == current, 'matrix source seals differ from current probe/helper/fixture bytes')
      true
    rescue KeyError => error
      raise AuditFailure, "pin summary is missing a required field: #{error.message}"
    end

    def validate_invocation_topology!
      roster = @summary.fetch('invocation_roster')
      need!(roster.is_a?(Array) && !roster.empty?, 'invocation roster is absent')
      labels = roster.map { |entry| entry.fetch('label') }
      need!(labels.uniq == labels, 'invocation roster has duplicate labels')
      expected = []
      Matrix::MARK_FORMATS.each do |mark|
        Matrix::CASES.each do |kind|
          id = "#{kind}_#{mark}"
          expected.concat(["#{id}_create", "#{id}_insert", "#{id}_schema_part", "#{id}_native_check"])
          expected.concat(Matrix::WINDOWS.keys.map { |window| "#{id}_values_#{window}" })
        end
      end
      @case_ids.each { |id| expected << "#{id}_helper_stock" }
      Matrix::MARK_FORMATS.each do |mark|
        Matrix::CASES.each do |kind|
          id = "#{kind}_#{mark}"
          expected.concat([
            "#{id}_helper_write", "#{id}_target_create", "#{id}_attach", "#{id}_attached_check",
            "#{id}_attached_schema_part",
          ])
          expected.concat(Matrix::WINDOWS.keys.map { |window| "#{id}_attached_values_#{window}" })
        end
      end
      need!(labels == expected, 'invocation roster is incomplete, reordered, or not stock-first')
      referenced = []
      walk = lambda do |value|
        case value
        when Hash
          referenced << value['label'] if value['label'].is_a?(String) && labels.include?(value['label'])
          value.each { |key, child| walk.call(child) unless key == 'invocation_roster' }
        when Array
          value.each { |child| walk.call(child) }
        end
      end
      @summary.each { |key, value| walk.call(value) unless key == 'invocation_roster' }
      need!(referenced.uniq.sort == labels.sort, 'one or more raw invocations are not referenced by summary stages')
      @expected_labels = labels
      true
    rescue KeyError => error
      raise AuditFailure, "invocation roster is missing a field: #{error.message}"
    end

    def validate_invocations!
      roster = @summary.fetch('invocation_roster')
      invocation_dir = File.join(@root, 'invocations')
      canonical_directory!(invocation_dir, 'invocations directory')
      @records = {}
      expected_sidecars = []
      roster.each do |roster_entry|
        label = roster_entry.fetch('label')
        %w[json argv.json stdout stderr].each { |suffix| expected_sidecars << "#{label}.#{suffix}" }
        record = load_invocation_record!(label)
        validate_roster_matches_record!(roster_entry, record)
        validate_stage_references!(label, record)
        expected = expected_invocation_spec(label)
        validate_invocation_record!(label, record, expected)
        @records[label] = record
      end
      expected_sidecars.concat(roster.map { |item| item.fetch('stdin_file') })
      need!(Dir.children(invocation_dir).sort == expected_sidecars.sort,
            'invocation sidecar directory has missing, duplicate, or unrostered files')
      true
    rescue KeyError => error
      raise AuditFailure, "invocation record is missing a required field: #{error.message}"
    end

    def load_invocation_record!(label)
      path = File.join(@root, 'invocations', "#{label}.json")
      bytes = File.binread(canonical_file!(path, "#{label} process record"))
      record = JSON.parse(bytes)
      need!(record.is_a?(Hash) && INVOCATION_RECORD_KEY_VARIANTS.include?(record.keys.sort),
            "#{label} process record field roster is not a known producer variant")
      need!(bytes == JSON.pretty_generate(record) + "\n", "#{label} process record is not canonical JSON")
      record
    end

    def validate_roster_matches_record!(roster, record)
      %w[label process_kind binary_path store_path argv stdin_file argv_file stdout_file stderr_file].each do |key|
        need!(roster[key] == record[key], "invocation roster #{record['label']} field #{key} differs from raw process record")
      end
      need!(roster['record_file'] == "#{record['label']}.json", "invocation roster #{record['label']} record filename differs")
    end

    def validate_stage_references!(label, record)
      walk = lambda do |value|
        case value
        when Hash
          if value['label'] == label && value.key?('classification')
            {
              'classification' => 'process_classification',
              'exit' => 'exit', 'signal' => 'signal', 'stdout_file' => 'stdout_file',
              'stdout_bytes' => 'stdout_bytes', 'stdout_sha256' => 'stdout_sha256',
              'stderr_file' => 'stderr_file', 'stderr_bytes' => 'stderr_bytes',
              'stderr_sha256' => 'stderr_sha256', 'argv_file' => 'argv_file', 'argv' => 'argv',
              'stdin_file' => 'stdin_file', 'stdin_bytes' => 'stdin_bytes',
              'stdin_sha256' => 'stdin_sha256', 'record_file' => nil,
            }.each do |summary_key, record_key|
              next unless value.key?(summary_key)
              expected = record_key ? record[record_key] : "#{label}.json"
              need!(value[summary_key] == expected, "summary stage #{label} field #{summary_key} differs from raw process record")
            end
          end
          value.each { |key, child| walk.call(child) unless key == 'invocation_roster' }
        when Array
          value.each { |child| walk.call(child) }
        end
      end
      @summary.each { |key, value| walk.call(value) unless key == 'invocation_roster' }
      true
    end

    def validate_invocation_record!(label, record, expected)
      validate_invocation_record_key_roster!(label, record, expected)
      base = File.join(@root, 'invocations')
      need!(record['label'] == label && record['process_kind'] == expected.fetch(:process_kind),
            "#{label} process identity differs")
      need!(record['argv'] == expected.fetch(:argv) &&
            record['argv_file'] == "#{label}.argv.json" &&
            record['stdin_file'] == "#{label}.stdin.#{expected.fetch(:stdin_extension)}",
            "#{label} argv or stdin sidecar roster differs")
      need!(record['stdout_file'] == "#{label}.stdout" && record['stderr_file'] == "#{label}.stderr",
            "#{label} stdout/stderr filenames differ")
      argv_bytes = (JSON.pretty_generate(expected.fetch(:argv)) + "\n").b
      argv_sidecar = File.binread(canonical_file!(File.join(base, record['argv_file']), "#{label} argv sidecar"))
      need!(argv_sidecar == argv_bytes && record['argv_sha256'] == sha(argv_bytes),
            "#{label} exact argv bytes/hash differ")
      stdin = File.binread(canonical_file!(File.join(base, record['stdin_file']), "#{label} stdin sidecar"))
      need!(stdin == expected.fetch(:stdin) && record['stdin_bytes'] == stdin.bytesize && record['stdin_sha256'] == sha(stdin),
            "#{label} exact stdin bytes/hash differ")
      stdout = File.binread(canonical_file!(File.join(base, record['stdout_file']), "#{label} stdout sidecar"))
      stderr = File.binread(canonical_file!(File.join(base, record['stderr_file']), "#{label} stderr sidecar"))
      need!(record['stdout_bytes'] == stdout.bytesize && record['stdout_sha256'] == sha(stdout) &&
            record['stderr_bytes'] == stderr.bytesize && record['stderr_sha256'] == sha(stderr),
            "#{label} stdout/stderr bytes or hashes differ")
      need!(record['exit'] == 0 && record['signal'].nil? && record['timed_out'] == false &&
            record['process_classification'] == 'success' && stderr.empty? &&
            record.values_at('spawn_error', 'stdin_write_error', 'stdout_read_error', 'stderr_read_error').all?(&:nil?),
            "#{label} process status/stderr is not a clean successful capture")
      validate_invocation_resource_contract!(label, record, expected.fetch(:process_kind))
      need!(record['store_path'] == expected.fetch(:store_path) &&
            record['binary_path'] == expected.fetch(:binary_path) &&
            record['expected_binary_sha256'] == expected.fetch(:binary_sha256) &&
            record['binary_sha_before'] == expected.fetch(:binary_sha256) &&
            record['binary_sha_after'] == expected.fetch(:binary_sha256),
            "#{label} runtime/helper pin or store path differs")
      true
    end

    def expected_invocation_resource_record(process_kind)
      w241 = W280::W241
      common = {
        'timeout_seconds' => w241::TIMEOUT,
        'termination_grace_seconds' => w241::GRACE,
        'required_outer_run_safe_memory_limit_bytes' => w241::OUTER_RUN_SAFE_LIMIT,
      }
      case process_kind
      when 'clickhouse-local'
        common.merge(
          'max_threads' => 1,
          'max_memory_usage_bytes' => w241::MEMORY,
          'max_memory_usage_applicable' => true,
        )
      when 'crystal-helper'
        common.merge(
          'max_threads' => nil,
          'max_memory_usage_bytes' => nil,
          'max_memory_usage_applicable' => false,
        )
      else
        raise AuditFailure, "process kind is not an admitted resource origin: #{process_kind.inspect}"
      end
    end

    def validate_invocation_resource_contract!(label, record, process_kind)
      expected = expected_invocation_resource_record(process_kind)
      actual = expected.keys.to_h { |key| [key, record[key]] }
      need!(actual == expected,
            "#{label} process resource/timeout record differs from #{process_kind} producer contract")
      true
    end

    def validate_invocation_record_key_roster!(label, record, expected)
      process_kind = expected.fetch(:process_kind)
      need!(record.is_a?(Hash) && record['process_kind'] == process_kind,
            "#{label} process origin differs from the reconstructed invocation")
      stdin_extension = expected.fetch(:stdin_extension)
      case process_kind
      when 'clickhouse-local'
        case stdin_extension
        when 'sql'
          need!(record.keys.sort == INVOCATION_RECORD_BASE_KEYS,
                "#{label} native SQL process record field roster differs")
        when 'bin'
          need!(label.end_with?('_insert'), "#{label} native binary input is not an INSERT origin")
          need!(record.keys.sort == INVOCATION_RECORD_NATIVE_ROWBINARY_KEYS,
                "#{label} native RowBinary process record field roster differs")
          need!(record['stdin_encoding'] == 'rowbinary',
                "#{label} native stdin encoding differs from reconstructed RowBinary input")
        else
          raise AuditFailure, "#{label} native stdin extension is unsupported"
        end
      when 'crystal-helper'
        need!(stdin_extension == 'bin', "#{label} helper stdin extension differs from producer origin")
        need!(record.keys.sort == INVOCATION_RECORD_BASE_KEYS,
              "#{label} helper process record field roster differs")
      else
        raise AuditFailure, "#{label} process kind is not an admitted record origin"
      end
      true
    rescue KeyError => error
      raise AuditFailure, "#{label} process record variant is missing a required field: #{error.message}"
    end

    def expected_invocation_spec(label)
      if label.end_with?('_helper_stock') || label.end_with?('_helper_write')
        action = label.end_with?('_helper_stock') ? 'read' : 'write'
        suffix = action == 'read' ? '_helper_stock' : '_helper_write'
        id = label.delete_suffix(suffix)
        kind, mark = parse_case_id(id)
        part = action == 'read' ? @cases.fetch(id).dig('schema_part', 'part', 'path') :
          File.join(@root, 'parts', id, W280::PART_NAME)
        helper = @summary.fetch('helper_pin')
        return {
          process_kind: 'crystal-helper', binary_path: helper.fetch('path'),
          binary_sha256: helper.fetch('expected_sha256'), store_path: nil,
          argv: [helper.fetch('path'), action, kind, mark, part], stdin_extension: 'bin', stdin: ''.b,
        }
      end

      id = label
      action = nil
      window = nil
      origin = 'stock'
      if (match = /\A(.+)_attached_values_(full|middle|last|eof)\z/.match(label))
        id = match[1]; action = 'attached_values'; window = match[2]; origin = 'attached'
      elsif (match = /\A(.+)_values_(full|middle|last|eof)\z/.match(label))
        id = match[1]; action = 'values'; window = match[2]
      elsif label.end_with?('_attached_schema_part')
        id = label.delete_suffix('_attached_schema_part'); action = 'schema_part'; origin = 'attached'
      elsif label.end_with?('_schema_part')
        id = label.delete_suffix('_schema_part'); action = 'schema_part'
      elsif label.end_with?('_attached_check')
        id = label.delete_suffix('_attached_check'); action = 'check'; origin = 'attached'
      elsif label.end_with?('_native_check')
        id = label.delete_suffix('_native_check'); action = 'check'
      elsif label.end_with?('_target_create')
        id = label.delete_suffix('_target_create'); action = 'target_create'; origin = 'generated'
      elsif label.end_with?('_attach')
        id = label.delete_suffix('_attach'); action = 'attach'; origin = 'generated'
      elsif label.end_with?('_create')
        id = label.delete_suffix('_create'); action = 'create'
      elsif label.end_with?('_insert')
        id = label.delete_suffix('_insert'); action = 'insert'
      end
      need!(action, "cannot classify expected invocation #{label}")
      kind, mark = parse_case_id(id)
      entry = @cases.fetch(id)
      generated = origin != 'stock'
      table = generated ? expected_target_table(id) : entry.fetch('table')
      store = File.join(@root, 'stores', generated ? "target_#{id}" : id)
      query_id = origin == 'attached' ? "#{id}_attached" :
        action == 'check' ? "#{id}_native" : id
      sql = case action
            when 'create' then create_sql(table, kind, mark)
            when 'target_create' then target_create_sql(id, table, kind, mark)
            when 'schema_part' then schema_part_sql(query_id, table)
            when 'check' then check_sql(query_id, table)
            when 'attach' then "ALTER TABLE default.#{table} ATTACH PART '#{W280::PART_NAME}';\n"
            when 'values', 'attached_values' then values_sql(query_id, table, window)
            when 'insert' then nil
            else raise AuditFailure, "unsupported invocation action #{action.inspect}"
            end
      common = {
        process_kind: 'clickhouse-local', binary_path: W280::BINARY,
        binary_sha256: W280::BINARY_SHA256, store_path: store, stdin_extension: 'sql',
      }
      if action == 'insert'
        rowbinary = rowbinary_for(kind)
        query = "INSERT INTO default.#{entry.fetch('table')} FORMAT RowBinary"
        common.merge(
          argv: [W280::BINARY, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
                 "--max_memory_usage=#{W280::MEMORY_LIMIT}", '--input_format_binary_read_json_as_string=0',
                 '--query', query],
          stdin_extension: 'bin', stdin: rowbinary,
        )
      else
        common.merge(
          argv: [W280::BINARY, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
                 "--max_memory_usage=#{W280::MEMORY_LIMIT}", '--multiquery'],
          stdin: PIN_SQL + sql.b,
        )
      end
    end

    def create_sql(table, kind, mark)
      schema = Matrix::SCHEMAS.fetch(kind).map { |name, type| "#{TICK}#{name}#{TICK} #{type}" }.join(', ')
      settings = [
        'index_granularity=2', 'index_granularity_bytes=10485760', 'enable_mixed_granularity_parts=1',
        'min_rows_for_wide_part=1000000', 'min_bytes_for_wide_part=104857600', 'min_level_for_wide_part=0',
        'compress_marks=0', "marks_compression_codec='LZ4'", 'compress_primary_key=0', 'write_final_mark=1',
        "write_marks_for_substreams_in_compact_parts=#{mark == 'mrk4' ? 1 : 0}",
        'min_compress_block_size=0', 'max_compress_block_size=4096',
        'ratio_of_defaults_for_sparse_serialization=1.0', "default_compression_codec='LZ4'",
        "serialization_info_version='with_types'", 'propagate_types_serialization_versions_to_nested_types=true',
        "string_serialization_version='single_stream'", "object_serialization_version='v3'",
        "object_shared_data_serialization_version='map'",
        "object_shared_data_serialization_version_for_zero_level_parts='map'",
        'object_shared_data_buckets_for_compact_part=1', 'object_shared_data_target_chunk_rows=1',
        "dynamic_serialization_version='v3'", 'use_compact_variant_discriminators_serialization=0',
        'allow_suspicious_low_cardinality_types=1',
      ].join(', ')
      "SET flatten_nested=0;\nSET allow_suspicious_low_cardinality_types=1;\nSET use_variant_as_common_type=1;\n" \
        "CREATE TABLE default.#{table} (#{schema}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings};\n"
    end

    def target_create_sql(id, table, kind, mark)
      schema_tag = marker('target_schema', id)
      path_tag = marker('target_path', id)
      create_sql(table, kind, mark) +
        "SELECT '#{schema_tag}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;\n" \
        "SELECT '#{path_tag}', arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw;\n"
    end

    def schema_part_sql(id, table)
      schema_tag = marker('schema', id)
      part_tag = marker('part', id)
      path_tag = marker('table_path', id)
      "SELECT '#{schema_tag}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;\n" \
        "SELECT '#{part_tag}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;\n" \
        "SELECT '#{path_tag}', arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw;\n"
    end

    def check_sql(id, table)
      begin_tag = marker('check_begin', id)
      end_tag = marker('check_end', id)
      "SELECT '#{begin_tag}' FORMAT TSVRaw;\nCHECK TABLE default.#{table} FORMAT TSV;\nSELECT '#{end_tag}' FORMAT TSVRaw;\n"
    end

    def values_sql(id, table, window)
      tag = marker('values', id, window)
      predicate = Matrix::WINDOWS.fetch(window)
      return "SELECT '#{tag}', toString(count()) FROM default.#{table} WHERE #{predicate} FORMAT TSVRaw;\n" if window == 'eof'
      where = predicate ? " WHERE #{predicate}" : ''
      "SELECT '#{tag}', toString(pk), lower(hex(toJSONString(recursive_json_w280))) " \
        "FROM default.#{table}#{where} ORDER BY pk SETTINGS " \
        "output_format_json_named_tuples_as_objects=0, output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;\n"
    end

    def marker(kind, id, window = nil)
      suffix = window ? "_#{window.upcase}" : ''
      "__W280M_#{kind.to_s.upcase}_#{id.upcase}#{suffix}__"
    end

    def rowbinary_for(kind)
      Matrix::ROWS.fetch(kind).each_with_index.map do |value, index|
        [index + 1].pack('Q<').b + encode_value(Matrix::TYPE_DEFS.fetch(kind), value)
      end.join.b
    end

    def varuint(value)
      raise AuditFailure, 'invalid VarUInt oracle value' unless value.is_a?(Integer) && value >= 0
      bytes = []
      loop do
        byte = value & 0x7f
        value >>= 7
        bytes << (value.zero? ? byte : byte | 0x80)
        break if value.zero?
      end
      bytes.pack('C*').b
    end

    def rb_string(value)
      bytes = value.to_s.b
      varuint(bytes.bytesize) + bytes
    end

    def encode_json(document)
      paths = [['id', [Integer(document.fetch('id'))].pack('Q<').b]]
      varuint(paths.size) + paths.map { |path, bytes| rb_string(path) + bytes }.join.b
    end

    def encode_value(type, value)
      case type.kind
      when :json then encode_json(value)
      when :uint8 then [Integer(value)].pack('C').b
      when :array then varuint(value.size) + value.map { |child| encode_value(type.child, child) }.join.b
      when :tuple
        type.fields.each_with_index.map do |(name, child_type), index|
          child = value.is_a?(Hash) ? value.fetch(name) : value.fetch(index)
          encode_value(child_type, child)
        end.join.b
      else
        raise AuditFailure, "unsupported RowBinary type #{type.kind.inspect}"
      end
    end

    def expected_native_rows(kind, window)
      indexes = case window
                when 'full' then (0...Matrix::ROW_COUNT).to_a
                when 'middle' then (2...6).to_a
                when 'last' then (6...8).to_a
                else raise AuditFailure, "not a value-bearing SQL window: #{window}"
                end
      indexes.map { |index| [index + 1, Matrix::ROWS.fetch(kind).fetch(index)] }
    end

    def verify_window_output!(stdout, id, kind, window, observed)
      text = stdout.dup.force_encoding(Encoding::UTF_8)
      need!(text.valid_encoding?, "#{id}/#{window} stdout is not valid UTF-8")
      lines = text.split("\n", -1)
      need!(lines.pop == '', "#{id}/#{window} stdout is not newline terminated")
      need!(lines.shift == PIN_LINE, "#{id}/#{window} runtime version/build pin differs")
      tag = marker('values', id, window)
      if window == 'eof'
        need!(lines == ["#{tag}\t0"], "#{id}/EOF raw output is not one zero count")
        expected = [[tag, '0']]
        need!(observed['rows'] == expected && observed['expected_rows'] == expected,
              "#{id}/EOF summary differs from raw SQL output")
        return true
      end
      expected_rows = expected_native_rows(kind, window)
      raw = expected_rows.map { |pk, value| [tag, pk.to_s, JSON.generate(value).unpack1('H*')].join("\t") }
      need!(lines == raw, "#{id}/#{window} exact raw SQL output differs from literal JSON/PK oracle")
      parsed = lines.map do |line|
        fields = line.split("\t", -1)
        need!(fields.size == 3 && fields[0] == tag && fields[2].match?(/\A(?:[0-9a-f]{2})+\z/),
              "#{id}/#{window} raw value line has wrong tag, width, or hex encoding")
        [Integer(fields[1], 10), JSON.parse([fields[2]].pack('H*'))]
      end
      objects = parsed.map { |pk, value| {'pk' => pk, 'value' => value} }
      need!(observed['rows'] == objects && observed['expected_rows'] == objects,
            "#{id}/#{window} summary parsed rows differ from raw output/literal oracle")
      need!(observed['raw_rows'] == lines.map { |line| line.split("\t", -1) },
            "#{id}/#{window} summary raw rows differ from stdout sidecar")
      true
    rescue JSON::ParserError, ArgumentError => error
      raise AuditFailure, "#{id}/#{window} output could not be independently decoded: #{error.message}"
    end

    def validate_cases!
      @case_ids.each do |id|
        kind, mark = parse_case_id(id)
        entry = @cases.fetch(id)
        validate_case_schema!(id, kind, entry)
        validate_case_literals!(id, kind, entry)
        validate_stock_part!(id, kind, mark, entry)
        validate_helper_report!(id, kind, mark, entry.fetch('library_stock_read'), 'read',
                                entry.dig('schema_part', 'part', 'path'))
        validate_windows!(id, kind, entry.fetch('windows'), id)

        generated = entry.fetch('library_generated')
        target = generated.fetch('native_target')
        need!(target['state'] == 'ready' && target['table'] == expected_target_table(id) &&
              target['store'] == File.join(@root, 'stores', "target_#{id}"),
              "#{id} generated target state/table/store differs")
        need!(generated.fetch('attach').fetch('state') == 'attached' &&
              generated.dig('check', 'state') == 'healthy', "#{id} native ATTACH/CHECK did not pass")
        need!(generated.fetch('part_path') == File.join(@root, 'parts', id, W280::PART_NAME),
              "#{id} generated source part path differs")
        validate_helper_report!(id, kind, mark, generated.fetch('helper_report'), 'write', generated.fetch('part_path'))
        validate_generated_part!(id, kind, mark, generated)
        validate_windows!(id, kind, generated.fetch('native_windows'), "#{id}_attached")
      end
      true
    end

    def validate_case_schema!(id, kind, entry)
      expected = Matrix::SCHEMAS.fetch(kind).map { |name, type| [name, type.gsub(/\s+/, '')] }
      need!(entry.dig('schema_part', 'schema') == expected, "#{id} actual stock schema differs")
      part = entry.dig('schema_part', 'part')
      validate_native_active_part_rows!("#{id} stock", entry.dig('schema_part', 'active_parts'),
                                        marker('part', id), entry.fetch('table'), W280::PART_NAME,
                                        part.fetch('path'))
      true
    end

    def expected_native_active_part_rows(tag, table, part_name, canonical_part_path)
      need!(canonical_part_path.is_a?(String) && canonical_part_path == File.expand_path(canonical_part_path) &&
            !canonical_part_path.end_with?(File::SEPARATOR),
            "#{tag} canonical part path is not a slash-free absolute path")
      [[tag, table, part_name, canonical_part_path + File::SEPARATOR, 'Compact',
        Matrix::ROW_COUNT.to_s, RAW_MARK_FILE_ROWS.size.to_s]]
    end

    def validate_native_active_part_rows!(label, actual, tag, table, part_name, canonical_part_path)
      expected = expected_native_active_part_rows(tag, table, part_name, canonical_part_path)
      need!(actual == expected, "#{label} active-part row/physical mark count differs")
      true
    end

    def validate_case_literals!(id, kind, entry)
      input = entry.fetch('literal_input')
      need!(input['schema_kind'] == kind && input['row_count'] == Matrix::ROW_COUNT &&
            input['query'] == "INSERT INTO default.#{entry.fetch('table')} FORMAT RowBinary",
            "#{id} RowBinary input envelope differs")
      expected_rows = Matrix::ROWS.fetch(kind).each_with_index.map do |row, index|
        encoded = [index + 1].pack('Q<').b + encode_value(Matrix::TYPE_DEFS.fetch(kind), row)
        {'pk' => index + 1, 'values' => row, 'rowbinary_hex' => encoded.unpack1('H*')}
      end
      bytes = rowbinary_for(kind)
      need!(input['rows'] == expected_rows && input['stdin_bytes'] == bytes.bytesize &&
            input['stdin_sha256'] == sha(bytes), "#{id} RowBinary literals differ from independent encoder")
      true
    end

    def validate_helper_report!(id, kind, mark, wrapper, action, part_path)
      need!(wrapper.is_a?(Hash) && wrapper['status'] == 'exact_public_recursive_and_typed_reads',
            "#{id} helper #{action} wrapper status differs")
      report = wrapper.fetch('report')
      expected_origin = action == 'read' ? 'stock' : 'generated'
      need!(report['format'] == HELPER_FORMAT && report['action'] == action &&
            report['case'] == kind && report['mark_format'] == mark && report['status'] == 'ok' &&
            report['row_count'] == Matrix::ROW_COUNT && report['data_mark_count'] == Matrix::DATA_MARK_COUNT &&
            report['part_origin'] == expected_origin && report['public_reader_grid'] == 'nonempty_data_marks' &&
            report['public_reader_mark_count'] == Matrix::DATA_MARK_COUNT &&
            report['public_reader_mark_rows'] == PUBLIC_READER_MARK_ROWS && report['part_path'] == part_path &&
            report['schema'].to_s.gsub(/\s+/, '') == Matrix::SCHEMAS.fetch(kind).last.last.gsub(/\s+/, ''),
            "#{id} helper #{action} envelope/schema/action grid differs")
      signatures = expected_signatures(kind)
      windows = {
        'full' => signatures, 'middle' => signatures.drop(2).take(4),
        'last' => signatures.drop(6).take(2), 'eof' => [],
      }
      recursive = report.fetch('recursive_windows')
      typed = report.fetch('typed_windows')
      need!(recursive.keys.sort == Matrix::WINDOWS.keys.sort && typed.keys.sort == Matrix::WINDOWS.keys.sort,
            "#{id} helper #{action} public window roster differs")
      windows.each do |window, expected|
        rec = recursive.fetch(window)
        typ = typed.fetch(window)
        first_mark, mark_count = Matrix::PHYSICAL_WINDOWS.fetch(window)
        start_row, = Matrix::TYPED_WINDOWS.fetch(window)
        need!(rec['signatures'] == expected && rec['first_mark'] == first_mark && rec['mark_count'] == mark_count &&
              typ['signatures'] == expected && typ['start_row'] == start_row && typ['row_count'] == expected.size,
              "#{id}/#{window} helper #{action} recursive/typed read differs")
      end
      true
    rescue KeyError => error
      raise AuditFailure, "#{id} helper report is incomplete: #{error.message}"
    end

    def expected_signatures(kind)
      Matrix::ROWS.fetch(kind).map { |row| typed_signature(Matrix::TYPE_DEFS.fetch(kind), row) }
    end

    def typed_signature(type, value)
      case type.kind
      when :json then "J#{value.fetch('id')}"
      when :uint8 then "U#{Integer(value)}"
      when :array then "A[#{value.map { |child| typed_signature(type.child, child) }.join(',')}]"
      when :tuple
        children = type.fields.each_with_index.map do |(name, child_type), index|
          child = value.is_a?(Hash) ? value.fetch(name) : value.fetch(index)
          typed_signature(child_type, child)
        end
        "T(#{children.join(',')})"
      else
        raise AuditFailure, "unknown typed-signature node #{type.kind.inspect}"
      end
    end

    def validate_stock_part!(id, kind, mark, entry)
      physical = entry.fetch('schema_part').fetch('part')
      raw = physical.fetch('raw_capture')
      path = physical.fetch('path')
      need!(raw.fetch('mark_file') == "data.#{mark}", "#{id} stock mark filename differs")
      validate_part_snapshot!(id, path, raw.fetch('inventory'), raw.fetch('snapshot'), raw.fetch('callback_roster'),
                              raw.fetch('serialization_metadata'), raw.fetch('serialization_metadata_sha256'),
                              raw.fetch('serialization_metadata_raw_file'), expected_location: :store)
      validate_mark_and_roster!(id, kind, mark, path, raw.fetch('inventory'), raw.fetch('callback_roster'),
                                raw.fetch('mark_raw_file'), raw.fetch('mark_sha256'), raw.fetch('mark_bytes'),
                                RAW_MARK_FILE_ROWS, action: 'stock')
      true
    end

    def validate_generated_part!(id, kind, mark, generated)
      path = generated.fetch('part_path')
      inventory = generated.fetch('inventory')
      metadata = generated.fetch('serialization_metadata')
      callback = generated.fetch('callback_roster')
      source_snapshot = generated.fetch('part_snapshot')
      need!(metadata.is_a?(Hash) && metadata['parsed'].is_a?(Hash), "#{id} generated metadata snapshot is absent")
      validate_part_snapshot!(id + '_generated', path, inventory, source_snapshot, callback,
                              metadata.fetch('parsed'), metadata.fetch('raw_sha256'),
                              "raw-records/#{id}_generated.serialization.json", expected_location: :generated)
      validate_mark_and_roster!(id + '_generated', kind, mark, path, inventory, callback,
                                "raw-records/#{id}_generated.data.#{mark}", entry_for(inventory, "data.#{mark}")['sha256'],
                                entry_for(inventory, "data.#{mark}")['size'], RAW_MARK_FILE_ROWS, action: 'generated')

      active = generated.fetch('active_part')
      active_part = active.fetch('part')
      raw = active_part.fetch('raw_capture')
      active_path = active_part.fetch('path')
      need!(raw.fetch('mark_file') == "data.#{mark}", "#{id} attached mark filename differs")
      need!(active['schema'] == Matrix::SCHEMAS.fetch(kind).map { |name, type| [name, type.gsub(/\s+/, '')] },
            "#{id} attached active schema differs")
      validate_native_active_part_rows!("#{id} attached", active['active_parts'],
                                        marker('part', "#{id}_attached"), expected_target_table(id),
                                        W280::PART_NAME, active_path)
      validate_part_snapshot!("#{id}_attached", active_path, raw.fetch('inventory'), raw.fetch('snapshot'),
                              raw.fetch('callback_roster'), raw.fetch('serialization_metadata'),
                              raw.fetch('serialization_metadata_sha256'), raw.fetch('serialization_metadata_raw_file'),
                              expected_location: :store)
      validate_attached_generated_inventory!(id, inventory, raw.fetch('inventory'), active_path)
      validate_mark_and_roster!("#{id}_attached", kind, mark, active_path, raw.fetch('inventory'),
                                raw.fetch('callback_roster'), raw.fetch('mark_raw_file'), raw.fetch('mark_sha256'),
                                raw.fetch('mark_bytes'), RAW_MARK_FILE_ROWS, action: 'attached generated')
      true
    end

    def validate_part_snapshot!(id, part_path, inventory, snapshot, callback, parsed_metadata,
                                metadata_sha, metadata_raw_name, expected_location:)
      canonical_directory!(part_path, "#{id} part directory")
      prefix = expected_location == :generated ? File.join(@root, 'parts') + File::SEPARATOR :
        File.join(@root, 'stores') + File::SEPARATOR
      need!(part_path.start_with?(prefix), "#{id} part is outside its expected evidence tree")
      inventory = inventory_from_summary(inventory)
      need!(disk_inventory(part_path) == inventory, "#{id} actual part inventory differs")
      safe = id.gsub(/[^a-zA-Z0-9_.-]/, '_')
      need!(snapshot.is_a?(Hash) && snapshot['inventory'] == inventory &&
            snapshot['raw_prefix'] == "raw-records/#{id}." &&
            snapshot['inventory_file'] == "source-inventories/#{id}.json",
            "#{id} part snapshot sidecar roster differs")
      snapshot_path = "source-inventories/#{safe}.json"
      snapshot_bytes = File.binread(canonical_file!(File.join(@root, snapshot_path), "#{id} inventory snapshot"))
      snapshot_json = JSON.parse(snapshot_bytes)
      need!(snapshot_json['case_name'] == id && snapshot_json['source_part_path'] == part_path &&
            snapshot_json['inventory'] == inventory && snapshot_json['callback_roster'] == callback,
            "#{id} persisted part snapshot does not bind to part inventory/callback bytes")
      metadata_path = File.join(part_path, 'serialization.json')
      metadata_raw = File.binread(canonical_file!(metadata_path, "#{id} serialization.json"))
      metadata = JSON.parse(metadata_raw)
      need!(sha(metadata_raw) == metadata_sha && metadata == parsed_metadata,
            "#{id} serialization metadata parsed/raw hash differs")
      raw_name = "raw-records/#{safe}.serialization.json"
      need!(metadata_raw_name == raw_name, "#{id} serialization raw-sidecar path differs")
      saved_metadata = File.binread(canonical_file!(File.join(@root, raw_name), "#{id} raw serialization sidecar"))
      need!(saved_metadata == metadata_raw, "#{id} serialization raw-sidecar bytes differ")
      snapshot_metadata = snapshot_json.fetch('serialization_metadata')
      need!(snapshot_metadata['raw'] == metadata_raw && snapshot_metadata['raw_sha256'] == metadata_sha &&
            (snapshot_metadata['parsed'].nil? || snapshot_metadata['parsed'] == metadata),
            "#{id} source inventory metadata differs from raw serialization bytes")
      inventory.fetch('files').each do |item|
        relative = item.fetch('path')
        safe_relative!(relative, "#{id} part inventory name")
        actual = File.binread(canonical_file!(File.join(part_path, relative), "#{id}/#{relative}"))
        need!(actual.bytesize == item.fetch('size') && sha(actual) == item.fetch('sha256'),
              "#{id}/#{relative} actual part bytes differ from inventory")
        copied = File.binread(canonical_file!(File.join(@root, "raw-records/#{safe}.#{relative}"),
                                              "#{id}/#{relative} raw part copy"))
        need!(copied == actual, "#{id}/#{relative} raw part copy differs from on-disk bytes")
      end
      true
    rescue KeyError, JSON::ParserError => error
      raise AuditFailure, "#{id} part snapshot is incomplete: #{error.message}"
    end

    def inventory_from_summary(inventory)
      need!(inventory.is_a?(Hash) && inventory['files'].is_a?(Array) &&
            inventory['total_bytes'].is_a?(Integer), 'part inventory object is malformed')
      inventory
    end

    def validate_attached_generated_inventory!(id, generated_inventory, attached_inventory, attached_path,
                                               sidecar_bytes: nil)
      generated_files = inventory_files_by_path!(id, generated_inventory, 'generated')
      attached_files = inventory_files_by_path!(id, attached_inventory, 'attached')

      generated_files.each do |path, entry|
        need!(attached_files[path] == entry, "#{id} ATTACH changed or omitted generated file #{path.inspect}")
      end
      extra_paths = attached_files.keys - generated_files.keys
      need!(extra_paths == [ATTACHED_NATIVE_SIDECAR_PATH],
            "#{id} ATTACH added files outside the pinned native sidecar: #{extra_paths.inspect}")
      need!(attached_files.fetch(ATTACHED_NATIVE_SIDECAR_PATH) == ATTACHED_NATIVE_SIDECAR_ENTRY,
            "#{id} ATTACH native sidecar inventory entry differs")

      if sidecar_bytes.nil?
        sidecar_path = canonical_file!(File.join(attached_path, ATTACHED_NATIVE_SIDECAR_PATH),
                                       "#{id} ATTACH native sidecar", max_bytes: ATTACHED_NATIVE_SIDECAR_BYTES.bytesize)
        sidecar_bytes = File.binread(sidecar_path)
      end
      need!(sidecar_bytes == ATTACHED_NATIVE_SIDECAR_BYTES,
            "#{id} ATTACH native sidecar bytes differ")
      true
    rescue KeyError, TypeError, NoMethodError => error
      raise AuditFailure, "#{id} ATTACH inventory contract is incomplete: #{error.class}: #{error.message}"
    end

    def inventory_files_by_path!(id, inventory, origin)
      need!(inventory.is_a?(Hash) && inventory['files'].is_a?(Array) &&
            inventory['total_bytes'].is_a?(Integer), "#{id} #{origin} inventory is malformed")
      files = inventory.fetch('files')
      paths = files.map do |entry|
        need!(entry.is_a?(Hash) && entry.keys.sort == %w[path sha256 size] &&
              entry['path'].is_a?(String) && entry['size'].is_a?(Integer) && entry['size'] >= 0 &&
              entry['sha256'].is_a?(String) && entry['sha256'].match?(/\A[0-9a-f]{64}\z/),
              "#{id} #{origin} inventory entry is malformed")
        entry.fetch('path')
      end
      need!(paths.uniq == paths && paths == paths.sort,
            "#{id} #{origin} inventory paths are duplicated or not canonical")
      need!(inventory.fetch('total_bytes') == files.sum { |entry| entry.fetch('size') },
            "#{id} #{origin} inventory byte total differs")
      files.to_h { |entry| [entry.fetch('path'), entry] }
    rescue KeyError, TypeError, NoMethodError => error
      raise AuditFailure, "#{id} #{origin} inventory is incomplete: #{error.class}: #{error.message}"
    end

    def disk_inventory(path)
      files = []
      total = 0
      Find.find(path) do |entry|
        next if entry == path
        stat = File.lstat(entry)
        need!(!stat.symlink?, "symlink in part tree: #{entry}")
        next if stat.directory?
        need!(stat.file?, "non-regular part file: #{entry}")
        need!(stat.size <= MAX_PART_FILE_BYTES, "part file too large: #{entry}")
        need!(files.size < MAX_PART_FILES, 'part file-count bound exceeded')
        relative = entry.delete_prefix(path + File::SEPARATOR)
        safe_relative!(relative, 'part inventory path')
        total += stat.size
        need!(total <= MAX_PART_BYTES, 'part byte bound exceeded')
        files << {'path' => relative, 'size' => stat.size, 'sha256' => Digest::SHA256.file(entry).hexdigest}
      end
      {'files' => files.sort_by { |item| item.fetch('path') }, 'total_bytes' => total}
    end

    def validate_mark_and_roster!(id, kind, mark, part_path, inventory, callback, raw_mark_file,
                                  expected_sha, expected_bytes, expected_rows, action:)
      mark_name = "data.#{mark}"
      item = entry_for(inventory, mark_name)
      need!(inventory.fetch('files').none? { |file| file.fetch('path').match?(/\Adata\.cmrk[34]\z/) },
            "#{id} part unexpectedly uses compressed marks")
      mark_bytes = File.binread(canonical_file!(File.join(part_path, mark_name), "#{id} #{mark_name}"))
      safe = id.gsub(/[^a-zA-Z0-9_.-]/, '_')
      expected_raw_name = "raw-records/#{safe}.#{mark_name}"
      need!(raw_mark_file == expected_raw_name && mark_bytes.bytesize == expected_bytes &&
            sha(mark_bytes) == expected_sha && item['size'] == expected_bytes && item['sha256'] == expected_sha,
            "#{id} raw plain mark filename/length/hash differs for #{action}")
      copied = File.binread(canonical_file!(File.join(@root, raw_mark_file), "#{id} raw mark copy"))
      need!(copied == mark_bytes, "#{id} raw mark sidecar differs from part bytes")

      columns = Matrix::SCHEMAS.fetch(kind).map(&:first)
      slots = if mark == 'mrk3'
                expected_roster = columns.each_with_index.map { |column, index| [index, column, nil] }
                need!(callback['state'] == 'mrk3_single_unlabelled_slot_per_column' &&
                      callback['sections'].nil? && callback['roster'] == expected_roster &&
                      callback['text'].nil? && callback['sha256'].nil?,
                      "#{id} MRK3 roster is not one unlabeled slot per declared column")
                need!(!inventory.fetch('files').any? { |file| file.fetch('path') == 'columns_substreams.txt' },
                      "#{id} MRK3 part contains MRK4 roster metadata")
                expected_roster.map { |_index, column, _stream| [column, nil] }
              else
                text = File.binread(canonical_file!(File.join(part_path, 'columns_substreams.txt'), "#{id} columns_substreams.txt"))
                need!(entry_for(inventory, 'columns_substreams.txt')['sha256'] == sha(text),
                      "#{id} MRK4 roster file hash differs from inventory")
                parsed = parse_mrk4_roster(text, columns, id)
                need!(callback['state'] == 'native_substream_callback_roster_observed' &&
                      callback['text'] == text.dup.force_encoding(Encoding::UTF_8).to_s &&
                      callback['sections'] == parsed.fetch(:sections) &&
                      callback['roster'] == parsed.fetch(:roster) && callback['sha256'] == sha(text),
                      "#{id} stored callback roster differs from raw columns_substreams.txt")
                saved = File.binread(canonical_file!(File.join(@root, "source-inventories/#{safe}.columns_substreams.txt"),
                                                    "#{id} persisted raw MRK4 roster"))
                need!(saved == text, "#{id} MRK4 roster snapshot bytes differ")
                parsed.fetch(:roster).map { |slot| [slot[1], slot[2]] }
              end
      parsed_marks = parse_plain_mark_file(mark_bytes, slots.size, expected_rows, "#{id}/#{mark}")
      need!(parsed_marks.fetch(:slot_count) == slots.size && parsed_marks.fetch(:mark_rows) == expected_rows,
            "#{id} plain #{mark} physical slot/domain grid differs for #{action}")
      {slots: slots, mark_rows: parsed_marks.fetch(:mark_rows), coordinates: parsed_marks.fetch(:coordinates)}
    end

    def entry_for(inventory, path)
      entry = inventory.fetch('files').find { |item| item.fetch('path') == path }
      need!(entry, "part inventory is missing #{path}")
      entry
    end

    def parse_mrk4_roster(bytes, expected_columns, label)
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      need!(text.valid_encoding?, "#{label} MRK4 roster is not UTF-8")
      lines = text.split("\n", -1)
      need!(lines.pop == '', "#{label} MRK4 roster is not newline terminated")
      need!(lines.shift == 'columns substreams version: 1', "#{label} MRK4 roster version differs")
      header = /\A(0|[1-9][0-9]*) columns:\z/.match(lines.shift.to_s)
      need!(header && Integer(header[1], 10) == expected_columns.size, "#{label} MRK4 column count differs")
      sections = []
      until lines.empty?
        match = /\A(0|[1-9][0-9]*) substreams for column \x60([a-z][a-z0-9_]*)\x60:\z/.match(lines.shift.to_s)
        need!(match, "#{label} MRK4 roster has malformed section")
        count = Integer(match[1], 10)
        need!(count.between?(1, 512) && lines.size >= count, "#{label} MRK4 slot count is invalid")
        streams = count.times.map do
          item = /\A\t([A-Za-z0-9_.%]+)\z/.match(lines.shift.to_s)
          need!(item, "#{label} MRK4 physical slot is malformed")
          item[1]
        end
        need!(streams.uniq == streams, "#{label} MRK4 column has duplicate physical slots")
        sections << [match[2], streams]
      end
      need!(sections.map(&:first) == expected_columns, "#{label} MRK4 columns are missing, duplicated, or reordered")
      flat = sections.flat_map { |column, streams| streams.map { |stream| [column, stream] } }
      roster = flat.each_with_index.map { |(column, stream), index| [index, column, stream] }
      {sections: sections, roster: roster}
    end

    def parse_plain_mark_file(bytes, slot_count, expected_rows, label)
      need!(slot_count.is_a?(Integer) && slot_count.positive?, "#{label} has no physical slots")
      stride = slot_count * ROW_BYTES_PER_SLOT + ROW_COUNT_BYTES
      need!(bytes.bytesize == expected_rows.size * stride,
            "#{label} plain mark byte length differs from marks x physical slots")
      cursor = 0
      marks = expected_rows.map do
        coordinates = slot_count.times.map do
          pair = [bytes.byteslice(cursor, 8).unpack1('Q<'), bytes.byteslice(cursor + 8, 8).unpack1('Q<')]
          cursor += ROW_BYTES_PER_SLOT
          pair
        end
        rows = bytes.byteslice(cursor, 8).unpack1('Q<')
        cursor += ROW_COUNT_BYTES
        {coordinates: coordinates, rows: rows}
      end
      need!(cursor == bytes.bytesize && marks.map { |item| item.fetch(:rows) } == expected_rows,
            "#{label} mark row domains differ")
      slot_count.times do |slot|
        previous = nil
        marks.each_with_index do |item, mark_index|
          current = item.fetch(:coordinates).fetch(slot)
          monotone = previous.nil? || current[0] > previous[0] ||
            (current[0] == previous[0] && current[1] >= previous[1])
          need!(monotone, "#{label} coordinates regressed at mark #{mark_index}, slot #{slot}")
          previous = current
        end
      end
      {slot_count: slot_count, mark_rows: marks.map { |item| item.fetch(:rows) },
       coordinates: marks.map { |item| item.fetch(:coordinates) }}
    rescue NoMethodError, TypeError => error
      raise AuditFailure, "#{label} mark parse failed: #{error.message}"
    end

    def validate_windows!(id, kind, windows, query_id)
      Matrix::WINDOWS.keys.each do |window|
        observed = windows.fetch(window)
        need!(observed['state'] == 'exact_values', "#{id}/#{window} state is not exact_values")
        label = "#{query_id}_values_#{window}"
        record = @records.fetch(label)
        sql = File.binread(File.join(@root, 'invocations', record.fetch('stdin_file')))
        expected_sql = PIN_SQL + values_sql(query_id, table_for_query_id(query_id), window).b
        need!(sql == expected_sql, "#{label} captured SQL differs from exact window query")
        stdout = File.binread(File.join(@root, 'invocations', record.fetch('stdout_file')))
        verify_window_output!(stdout, query_id, kind, window, observed)
      end
      true
    end

    def table_for_query_id(query_id)
      if query_id.end_with?('_attached')
        expected_target_table(query_id.delete_suffix('_attached'))
      else
        @cases.fetch(query_id).fetch('table')
      end
    end

    def self_test_core!
      test_grid_contract!
      test_native_active_part_contract!
      test_helper_report_wrapper_contract!
      test_mrk4_slot_contract!
      test_mark_domain_contract!
      test_attached_inventory_contract!
      test_window_contract!
      test_invocation_roster_contract!
      test_invocation_origin_contract!
      test_pin_sidecar_contract!
      true
    end

    def test_reject!(label)
      begin
        yield
      rescue AuditFailure
        return true
      end
      raise AuditFailure, "self-test accepted negative control: #{label}"
    end

    def validate_raw_public_grids!(raw_rows, public_rows)
      need!(raw_rows == RAW_MARK_FILE_ROWS, 'raw mark-file grid differs')
      need!(public_rows == PUBLIC_READER_MARK_ROWS, 'public reader data-mark grid differs')
    end

    def test_grid_contract!
      validate_raw_public_grids!(RAW_MARK_FILE_ROWS, PUBLIC_READER_MARK_ROWS)
      test_reject!('raw/public mark-grid confusion: no EOF record in raw file') do
        validate_raw_public_grids!(PUBLIC_READER_MARK_ROWS, PUBLIC_READER_MARK_ROWS)
      end
      test_reject!('raw/public mark-grid confusion: EOF record exposed as a data mark') do
        validate_raw_public_grids!(RAW_MARK_FILE_ROWS, RAW_MARK_FILE_ROWS)
      end
    end

    def test_native_active_part_contract!
      path = '/private/tmp/w280-auditor-self-test/all_1_1_0'
      tag = marker('part', 'self_test')
      table = 'w280_self_test'
      expected = [[tag, table, W280::PART_NAME, path + File::SEPARATOR, 'Compact',
                   Matrix::ROW_COUNT.to_s, RAW_MARK_FILE_ROWS.size.to_s]]
      need!(validate_native_active_part_rows!('self-test valid', expected, tag, table,
                                              W280::PART_NAME, path),
            'valid native active-part row seed was rejected')
      test_reject!('native active-part path without output slash') do
        validate_native_active_part_rows!('self-test missing slash',
                                          [[tag, table, W280::PART_NAME, path, 'Compact',
                                            Matrix::ROW_COUNT.to_s, RAW_MARK_FILE_ROWS.size.to_s]],
                                          tag, table, W280::PART_NAME, path)
      end
      test_reject!('native active-part row exposes data-mark count instead of physical mark count') do
        validate_native_active_part_rows!('self-test public mark count',
                                          [[tag, table, W280::PART_NAME, path + File::SEPARATOR, 'Compact',
                                            Matrix::ROW_COUNT.to_s, PUBLIC_READER_MARK_ROWS.size.to_s]],
                                          tag, table, W280::PART_NAME, path)
      end
      test_reject!('native active-part path has duplicate output slash') do
        validate_native_active_part_rows!('self-test duplicate slash',
                                          [[tag, table, W280::PART_NAME, path + File::SEPARATOR * 2, 'Compact',
                                            Matrix::ROW_COUNT.to_s, RAW_MARK_FILE_ROWS.size.to_s]],
                                          tag, table, W280::PART_NAME, path)
      end
      true
    end

    def test_helper_report_wrapper_contract!
      id = 'array_json_mrk3'
      kind = 'array_json'
      mark = 'mrk3'
      path = '/private/tmp/w280-auditor-self-test/all_1_1_0'
      expected = expected_signatures(kind)
      windows = {
        'full' => expected,
        'middle' => expected.drop(2).take(4),
        'last' => expected.drop(6).take(2),
        'eof' => [],
      }
      recursive = windows.to_h do |name, signatures|
        first_mark, mark_count = Matrix::PHYSICAL_WINDOWS.fetch(name)
        [name, {'signatures' => signatures, 'first_mark' => first_mark, 'mark_count' => mark_count}]
      end
      typed = windows.to_h do |name, signatures|
        start_row, = Matrix::TYPED_WINDOWS.fetch(name)
        [name, {'signatures' => signatures, 'start_row' => start_row, 'row_count' => signatures.size}]
      end
      report = {
        'format' => HELPER_FORMAT, 'action' => 'read', 'case' => kind, 'mark_format' => mark,
        'status' => 'ok', 'row_count' => Matrix::ROW_COUNT, 'data_mark_count' => Matrix::DATA_MARK_COUNT,
        'part_origin' => 'stock', 'public_reader_grid' => 'nonempty_data_marks',
        'public_reader_mark_count' => Matrix::DATA_MARK_COUNT,
        'public_reader_mark_rows' => PUBLIC_READER_MARK_ROWS, 'part_path' => path,
        'schema' => Matrix::SCHEMAS.fetch(kind).last.last,
        'recursive_windows' => recursive, 'typed_windows' => typed,
      }
      wrapper = {'status' => 'exact_public_recursive_and_typed_reads', 'report' => report}
      need!(validate_helper_report!(id, kind, mark, wrapper, 'read', path),
            'valid nested helper report wrapper was rejected')
      test_reject!('flattened helper report passed instead of wrapper') do
        validate_helper_report!(id, kind, mark, report, 'read', path)
      end
      test_reject!('helper report wrapper status drift') do
        validate_helper_report!(id, kind, mark, wrapper.merge('status' => 'incomplete'), 'read', path)
      end
      true
    end

    def test_mrk4_slot_contract!
      valid = "columns substreams version: 1\n2 columns:\n1 substreams for column #{TICK}pk#{TICK}:\n\tpk\n2 substreams for column #{TICK}recursive_json_w280#{TICK}:\n\trecursive_json_w280.size0\n\trecursive_json_w280.id\n"
      parsed = parse_mrk4_roster(valid.b, %w[pk recursive_json_w280], 'self-test')
      expected = %w[pk recursive_json_w280.size0 recursive_json_w280.id]
      need!(parsed.fetch(:roster).map { |slot| slot[2] } == expected, 'valid MRK4 slot seed failed')
      missing = valid.sub("2 substreams for column #{TICK}recursive_json_w280#{TICK}:",
                          "1 substreams for column #{TICK}recursive_json_w280#{TICK}:").sub("\n\trecursive_json_w280.id\n", "\n")
      test_reject!('missing MRK4 slot') do
        value = parse_mrk4_roster(missing.b, %w[pk recursive_json_w280], 'self-test missing')
        need!(value.fetch(:roster).size == expected.size, 'slot count changed')
      end
      reordered = valid.sub("\n\trecursive_json_w280.size0\n\trecursive_json_w280.id\n",
                            "\n\trecursive_json_w280.id\n\trecursive_json_w280.size0\n")
      test_reject!('reordered MRK4 slot') do
        value = parse_mrk4_roster(reordered.b, %w[pk recursive_json_w280], 'self-test reordered')
        need!(value.fetch(:roster).map { |slot| slot[2] } == expected, 'slot order changed')
      end
    end

    def mark_bytes_for_test(slot_count, rows)
      bytes = ''.b
      rows.each_with_index do |row_count, mark_index|
        slot_count.times { |slot| bytes << [mark_index, slot].pack('Q<Q<') }
        bytes << [row_count].pack('Q<')
      end
      bytes
    end

    def test_mark_domain_contract!
      valid = mark_bytes_for_test(2, RAW_MARK_FILE_ROWS)
      parsed = parse_plain_mark_file(valid, 2, RAW_MARK_FILE_ROWS, 'self-test valid raw grid')
      need!(parsed.fetch(:mark_rows) == RAW_MARK_FILE_ROWS, 'valid raw mark-file grid seed failed')
      test_reject!('wrong mark row domain') do
        parse_plain_mark_file(mark_bytes_for_test(2, [2, 2, 1, 2, 0]), 2, RAW_MARK_FILE_ROWS, 'self-test domain')
      end
      test_reject!('public data-mark grid cannot parse raw mark-file bytes') do
        parse_plain_mark_file(valid, 2, PUBLIC_READER_MARK_ROWS, 'self-test raw/public confusion')
      end
    end

    def test_attached_inventory_contract!
      need!(ATTACHED_NATIVE_SIDECAR_BYTES.bytesize == ATTACHED_NATIVE_SIDECAR_ENTRY.fetch('size') &&
            sha(ATTACHED_NATIVE_SIDECAR_BYTES) == ATTACHED_NATIVE_SIDECAR_ENTRY.fetch('sha256'),
            'pinned native sidecar literal differs from its size/hash')
      generated = {
        'files' => [
          {'path' => 'checksums.txt', 'size' => 2, 'sha256' => 'a' * 64},
          {'path' => 'data.bin', 'size' => 8, 'sha256' => 'b' * 64},
        ],
        'total_bytes' => 10,
      }
      attached = {
        'files' => (generated.fetch('files') + [ATTACHED_NATIVE_SIDECAR_ENTRY]).sort_by { |entry| entry.fetch('path') },
        'total_bytes' => generated.fetch('total_bytes') + ATTACHED_NATIVE_SIDECAR_ENTRY.fetch('size'),
      }
      need!(validate_attached_generated_inventory!('self_test_valid', generated, attached,
                                                   '/private/tmp/w280-auditor-self-test',
                                                   sidecar_bytes: ATTACHED_NATIVE_SIDECAR_BYTES) == true,
            'valid generated-byte/native-sidecar inventory seed was rejected')

      missing = json_clone(attached)
      missing['files'].delete_if { |entry| entry.fetch('path') == 'data.bin' }
      missing['total_bytes'] -= 8
      test_reject!('missing generated attachment file') do
        validate_attached_generated_inventory!('self_test_missing', generated, missing,
                                               '/private/tmp/w280-auditor-self-test',
                                               sidecar_bytes: ATTACHED_NATIVE_SIDECAR_BYTES)
      end

      mutated = json_clone(attached)
      mutated['files'].find { |entry| entry.fetch('path') == 'data.bin' }['sha256'] = 'c' * 64
      test_reject!('mutated generated attachment bytes') do
        validate_attached_generated_inventory!('self_test_mutated', generated, mutated,
                                               '/private/tmp/w280-auditor-self-test',
                                               sidecar_bytes: ATTACHED_NATIVE_SIDECAR_BYTES)
      end

      unexpected = json_clone(attached)
      unexpected['files'] << {'path' => 'unexpected.txt', 'size' => 1, 'sha256' => 'd' * 64}
      unexpected['files'].sort_by! { |entry| entry.fetch('path') }
      unexpected['total_bytes'] += 1
      test_reject!('unexpected attachment extra') do
        validate_attached_generated_inventory!('self_test_extra', generated, unexpected,
                                               '/private/tmp/w280-auditor-self-test',
                                               sidecar_bytes: ATTACHED_NATIVE_SIDECAR_BYTES)
      end

      altered_sidecar = json_clone(attached)
      altered_sidecar['files'].find { |entry| entry.fetch('path') == ATTACHED_NATIVE_SIDECAR_PATH }['sha256'] = 'e' * 64
      test_reject!('altered native sidecar inventory') do
        validate_attached_generated_inventory!('self_test_sidecar', generated, altered_sidecar,
                                               '/private/tmp/w280-auditor-self-test',
                                               sidecar_bytes: ATTACHED_NATIVE_SIDECAR_BYTES)
      end

      test_reject!('altered native sidecar bytes') do
        validate_attached_generated_inventory!('self_test_sidecar_bytes', generated, attached,
                                               '/private/tmp/w280-auditor-self-test',
                                               sidecar_bytes: ATTACHED_NATIVE_SIDECAR_BYTES + 'x')
      end
    end

    def test_window_contract!
      kind = 'array_json'
      id = 'array_json_mrk3'
      tag = marker('values', id, 'middle')
      expected = expected_native_rows(kind, 'middle')
      raw_rows = expected.map { |pk, value| [tag, pk.to_s, JSON.generate(value).unpack1('H*')] }
      observed = {
        'rows' => expected.map { |pk, value| {'pk' => pk, 'value' => value} },
        'expected_rows' => expected.map { |pk, value| {'pk' => pk, 'value' => value} },
        'raw_rows' => raw_rows,
      }
      stdout = ([PIN_LINE] + raw_rows.map { |row| row.join("\t") }).join("\n") + "\n"
      verify_window_output!(stdout, id, kind, 'middle', observed)
      test_reject!('false native signature') do
        verify_window_output!(stdout.sub(raw_rows.first.last, '00'), id, kind, 'middle', observed)
      end
      test_reject!('false native window tag') do
        verify_window_output!(stdout.sub('_MIDDLE__', '_LAST__'), id, kind, 'middle', observed)
      end
    end

    def test_invocation_roster_contract!
      label = 'self_test_record'
      record = {
        'label' => label, 'process_kind' => 'clickhouse-local', 'binary_path' => '/tmp/clickhouse',
        'store_path' => '/tmp/store', 'argv' => ['/tmp/clickhouse', 'local'],
        'stdin_file' => "#{label}.stdin.sql", 'argv_file' => "#{label}.argv.json",
        'stdout_file' => "#{label}.stdout", 'stderr_file' => "#{label}.stderr",
      }
      roster = record.merge('record_file' => "#{label}.json")
      validate_roster_matches_record!(roster, record)
      drifted = roster.merge('record_file' => "#{label}.other.json")
      test_reject!('invocation roster record_file drift') do
        validate_roster_matches_record!(drifted, record)
      end
    end

    def test_invocation_origin_contract!
      id = 'nested_five_sites_mrk4'
      stock_table = 'self_test_stock_table'
      previous_root = @root
      previous_cases = @cases
      @root = '/private/tmp/w280-invocation-origin-self-test'
      @cases = {id => {'table' => stock_table}}
      target_table = expected_target_table(id)
      stock_store = File.join(@root, 'stores', id)
      target_store = File.join(@root, 'stores', "target_#{id}")
      argv_for = lambda do |store|
        [W280::BINARY, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
         "--max_memory_usage=#{W280::MEMORY_LIMIT}", '--multiquery']
      end
      begin
        stock_check = expected_invocation_spec("#{id}_native_check")
        attached_check = expected_invocation_spec("#{id}_attached_check")
        stock_schema = expected_invocation_spec("#{id}_schema_part")
        attached_schema = expected_invocation_spec("#{id}_attached_schema_part")

        need!(stock_check == {
          process_kind: 'clickhouse-local', binary_path: W280::BINARY,
          binary_sha256: W280::BINARY_SHA256, store_path: stock_store, stdin_extension: 'sql',
          argv: argv_for.call(stock_store), stdin: PIN_SQL + check_sql("#{id}_native", stock_table).b,
        }, 'stock CHECK argv/stdin seed differs')
        need!(attached_check == {
          process_kind: 'clickhouse-local', binary_path: W280::BINARY,
          binary_sha256: W280::BINARY_SHA256, store_path: target_store, stdin_extension: 'sql',
          argv: argv_for.call(target_store), stdin: PIN_SQL + check_sql("#{id}_attached", target_table).b,
        }, 'attached CHECK argv/stdin seed differs')
        need!(stock_schema == {
          process_kind: 'clickhouse-local', binary_path: W280::BINARY,
          binary_sha256: W280::BINARY_SHA256, store_path: stock_store, stdin_extension: 'sql',
          argv: argv_for.call(stock_store), stdin: PIN_SQL + schema_part_sql(id, stock_table).b,
        }, 'stock schema/part argv/stdin seed differs')
        need!(attached_schema == {
          process_kind: 'clickhouse-local', binary_path: W280::BINARY,
          binary_sha256: W280::BINARY_SHA256, store_path: target_store, stdin_extension: 'sql',
          argv: argv_for.call(target_store), stdin: PIN_SQL + schema_part_sql("#{id}_attached", target_table).b,
        }, 'attached schema/part argv/stdin seed differs')
        need!(attached_check[:argv] != stock_check[:argv] && attached_check[:stdin] != stock_check[:stdin] &&
              attached_schema[:argv] != stock_schema[:argv] && attached_schema[:stdin] != stock_schema[:stdin],
              'attached invocation origin collapsed to stock table/store')
        test_invocation_record_key_contract!
        test_invocation_resource_contract!
      ensure
        @root = previous_root
        @cases = previous_cases
      end
    end

    def test_invocation_record_key_contract!
      base = INVOCATION_RECORD_BASE_KEYS.to_h { |key| [key, nil] }
      helper_expected = {process_kind: 'crystal-helper', stdin_extension: 'bin'}
      native_sql_expected = {process_kind: 'clickhouse-local', stdin_extension: 'sql'}
      native_binary_expected = {process_kind: 'clickhouse-local', stdin_extension: 'bin'}

      helper_record = base.merge('process_kind' => 'crystal-helper')
      native_sql_record = base.merge('process_kind' => 'clickhouse-local')
      native_binary_record = base.merge('process_kind' => 'clickhouse-local', 'stdin_encoding' => 'rowbinary')
      validate_invocation_record_key_roster!('self_test_helper', helper_record, helper_expected)
      validate_invocation_record_key_roster!('self_test_native_sql', native_sql_record, native_sql_expected)
      validate_invocation_record_key_roster!('self_test_native_binary_insert', native_binary_record,
                                             native_binary_expected)

      test_reject!('missing native RowBinary encoding') do
        validate_invocation_record_key_roster!('self_test_missing_encoding_insert',
                                               native_sql_record, native_binary_expected)
      end
      test_reject!('wrong native RowBinary encoding') do
        validate_invocation_record_key_roster!('self_test_wrong_encoding_insert',
                                               native_binary_record.merge('stdin_encoding' => 'sql'),
                                               native_binary_expected)
      end
      test_reject!('extra helper stdin encoding') do
        validate_invocation_record_key_roster!('self_test_extra_helper_encoding',
                                               native_binary_record.merge('process_kind' => 'crystal-helper'),
                                               helper_expected)
      end
      test_reject!('extra native SQL stdin encoding') do
        validate_invocation_record_key_roster!('self_test_extra_sql_encoding',
                                               native_binary_record, native_sql_expected)
      end
      test_reject!('helper/native origin confusion') do
        validate_invocation_record_key_roster!('self_test_origin_confusion_insert',
                                               helper_record, native_binary_expected)
      end
      test_reject!('unknown process record field') do
        validate_invocation_record_key_roster!('self_test_unknown_field',
                                               native_sql_record.merge('extra' => true), native_sql_expected)
      end
      true
    end

    def test_invocation_resource_contract!
      native_expected = expected_invocation_resource_record('clickhouse-local')
      helper_expected = expected_invocation_resource_record('crystal-helper')
      validate_invocation_resource_contract!('self_test_native_resources', native_expected, 'clickhouse-local')
      validate_invocation_resource_contract!('self_test_helper_resources', helper_expected, 'crystal-helper')

      {
        'native thread limit drift' => [native_expected.merge('max_threads' => 2), 'clickhouse-local'],
        'native memory limit drift' => [native_expected.merge('max_memory_usage_bytes' => 1), 'clickhouse-local'],
        'helper thread limit drift' => [helper_expected.merge('max_threads' => 1), 'crystal-helper'],
        'helper memory limit drift' => [helper_expected.merge('max_memory_usage_bytes' => 1), 'crystal-helper'],
        'outer memory guard drift' => [helper_expected.merge('required_outer_run_safe_memory_limit_bytes' => 1), 'crystal-helper'],
        'timeout drift' => [helper_expected.merge('timeout_seconds' => helper_expected.fetch('timeout_seconds') + 1), 'crystal-helper'],
        'termination grace drift' => [native_expected.merge('termination_grace_seconds' => native_expected.fetch('termination_grace_seconds') + 1), 'clickhouse-local'],
      }.each do |label, (record, process_kind)|
        test_reject!(label) { validate_invocation_resource_contract!("self_test_#{label.tr(' ', '_')}", record, process_kind) }
      end
      true
    end

    def test_pin_sidecar_contract!
      Dir.mktmpdir('w280-auditor-self-test-', '/private/tmp') do |temp|
        base = File.join(temp, 'invocations')
        Dir.mkdir(base)
        label = 'self_test'
        argv = ['/tmp/clickhouse', 'local']
        argv_bytes = (JSON.pretty_generate(argv) + "\n").b
        stdin = "seed\n".b
        stdout = "ok\n".b
        stderr = ''.b
        pin = 'a' * 64
        record = {
          'label' => label, 'process_kind' => 'clickhouse-local', 'argv' => argv,
          'argv_file' => "#{label}.argv.json", 'argv_sha256' => sha(argv_bytes),
          'stdin_file' => "#{label}.stdin.sql", 'stdin_bytes' => stdin.bytesize, 'stdin_sha256' => sha(stdin),
          'stdout_file' => "#{label}.stdout", 'stdout_bytes' => stdout.bytesize, 'stdout_sha256' => sha(stdout),
          'stderr_file' => "#{label}.stderr", 'stderr_bytes' => 0, 'stderr_sha256' => sha(stderr),
          'exit' => 0, 'signal' => nil, 'timed_out' => false,
          'binary_path' => '/tmp/clickhouse', 'expected_binary_sha256' => pin,
          'binary_sha_before' => pin, 'binary_sha_after' => pin, 'spawn_error' => nil,
          'stdin_write_error' => nil, 'stdout_read_error' => nil, 'stderr_read_error' => nil,
          'process_classification' => 'success', 'store_path' => '/tmp/store',
        }.merge(expected_invocation_resource_record('clickhouse-local'))
        {
          "#{label}.argv.json" => argv_bytes, "#{label}.stdin.sql" => stdin,
          "#{label}.stdout" => stdout, "#{label}.stderr" => stderr,
          "#{label}.json" => (JSON.pretty_generate(record) + "\n").b,
        }.each { |name, bytes| File.binwrite(File.join(base, name), bytes) }
        old_root = @root
        @root = temp
        begin
          expected = {
            process_kind: 'clickhouse-local', argv: argv, stdin_extension: 'sql', stdin: stdin,
            binary_path: '/tmp/clickhouse', binary_sha256: pin, store_path: '/tmp/store',
          }
          validate_invocation_record!(label, record, expected)
          drifted = json_clone(record)
          drifted['binary_sha_after'] = 'b' * 64
          test_reject!('binary pin drift') { validate_invocation_record!(label, drifted, expected) }
          File.binwrite(File.join(base, "#{label}.stdout"), "tampered\n")
          test_reject!('stdout sidecar drift') { validate_invocation_record!(label, record, expected) }
        ensure
          @root = old_root
        end
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  options = {evidence_root: nil, self_test: false}
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/verify_compact_recursive_arrays_w280.rb --evidence-root PATH | --self-test'
    parser.on('--evidence-root PATH', 'Existing W280 full-matrix evidence root; read-only') { |value| options[:evidence_root] = value }
    parser.on('--self-test', 'Run seeded Ruby-only negative controls; no native or Crystal execution') { options[:self_test] = true }
  end.parse!
  if options[:self_test]
    exit(VerifyCompactRecursiveArraysW280::Auditor.self_test! ? 0 : 1)
  end
  unless options[:evidence_root]
    warn 'W280 evidence audit: provide --evidence-root or --self-test'
    exit 2
  end
  exit(VerifyCompactRecursiveArraysW280::Auditor.new(options[:evidence_root]).run ? 0 : 1)
end
