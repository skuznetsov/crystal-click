#!/usr/bin/env ruby
# Read-only auditor for W261 stock-native captures. It verifies captured bytes
# and their fixture-bound claims; it never builds or runs either executable.

require 'digest'
require 'json'
require 'optparse'
require_relative 'probe_wide_ragged_selected_metadata_w261'

module AuditWideRaggedSelectedMetadataW261
  Runner = ProbeWideRaggedSelectedMetadataW261
  Probe = Runner::Probe
  FORMAT = 'wide_ragged_selected_metadata_w261_auditor_v1'.freeze
  SOURCE_REVISION = 'ed30948f095ecb70679986d7d60e27ad770ae27a'.freeze
  SOURCE_PATH = '/private/tmp/clickhouse-w254-upstream.AqeqyC'.freeze
  MAX_SUMMARY_BYTES = 2 * 1024 * 1024
  MAX_SOURCE_BYTES = 16 * 1024 * 1024
  MAX_CAPTURE_BYTES = Runner::MAX_CAPTURE_BYTES
  MAX_PART_BYTES = Runner::MAX_PART_BYTES
  MAX_PART_FILES = Runner::MAX_PART_FILES
  ASSERTIONS = %w[direct full window eof selected_table offline_values exact_types exact_budgets].freeze
  NATIVE_LABEL = 'stock_source'.freeze
  HELPER_LABEL = 'typed_admission'.freeze
  SELECTED_TABLES = %w[WidePartTable TypedPartTable].freeze
  SOURCE_KEYS = %w[path sha256].freeze
  # Exact canonical escaped stream roster for this ten-column witness. These
  # logical names are intentionally distinct from on-disk filename hashes.
  EXPECTED_SUBSTREAMS = {
    'pk' => %w[pk],
    'u' => %w[u],
    'side' => %w[side.size side],
    'seq' => %w[
      seq.size0 seq%2Eid seq%2Edetails%2Enote.null seq%2Edetails%2Enote.size
      seq%2Edetails%2Enote seq%2Edetails%2Escore
    ],
    'mapped' => %w[
      mapped.size0 mapped%2Ekeys.size mapped%2Ekeys
      mapped%2Evalues%2Emeta%2Enote.null mapped%2Evalues%2Emeta%2Enote.size
      mapped%2Evalues%2Emeta%2Enote mapped%2Evalues%2Emeta%2Eid
      mapped%2Evalues%2Escore.null mapped%2Evalues%2Escore
    ],
    'simple' => %w[
      simple.size0 simple%2Ekeys simple%2Evalues.null simple%2Evalues
    ],
    'lookup' => %w[
      lookup.size0 lookup%2Ekeys.size lookup%2Ekeys lookup%2Evalues.size1
      lookup%2Evalues.null lookup%2Evalues
    ],
    'tup' => %w[tup%2En tup%2Es.size tup%2Es],
    'lc' => %w[lc.dict lc],
    'v' => %w[v.variant_discr v.String.size v.String v.UInt64],
  }.freeze
  EXPECTED_MARK_FILE_COUNT = EXPECTED_SUBSTREAMS.values.sum(&:size)
  INVOCATION_BASE_KEYS = %w[
    process_kind argv argv_sha256 stdin_bytes stdin_sha256 exit signal timed_out
    timeout_seconds termination_grace_seconds max_threads max_memory_usage_bytes
    max_memory_usage_applicable required_outer_run_safe_memory_limit_bytes
    expected_binary_sha256 binary_sha_after spawn_error stdin_write_error
    stdout_read_error stderr_read_error process_classification stdout_bytes
    stdout_sha256 stderr_bytes stderr_sha256 stdout_file stderr_file
  ].freeze

  class AuditFailure < StandardError; end

  def self.need!(condition, message)
    raise AuditFailure, message unless condition
  end

  def self.json_clone(value)
    JSON.parse(JSON.generate(value))
  end

  def self.sha256(bytes)
    Digest::SHA256.hexdigest(bytes)
  end

  def self.file_sha256(path)
    Digest::SHA256.file(path).hexdigest
  end

  def self.hash_rows(rows)
    JSON.parse(JSON.generate(rows))
  end

  def self.source_file_paths
    [
      File.realpath(File.expand_path('probe_wide_ragged_selected_metadata_w261.rb', __dir__)),
      File.realpath(Runner::HELPER_SOURCE),
      File.realpath(Runner::FIXTURE_SOURCE),
    ].uniq.sort
  end

  def self.canonical_directory!(path, label)
    need!(path.is_a?(String) && !path.empty? && path == File.expand_path(path), "#{label} path is not canonical: #{path.inspect}")
    need!(File.directory?(path) && !File.symlink?(path), "#{label} is absent or symlinked: #{path}")
    need!(File.realpath(path) == path, "#{label} resolves through a non-canonical path: #{path}")
    path
  rescue Errno::ENOENT
    raise AuditFailure, "#{label} is absent: #{path}"
  end

  def self.canonical_file!(path, label, executable: false, max_bytes: nil)
    need!(path.is_a?(String) && !path.empty? && path == File.expand_path(path), "#{label} path is not canonical: #{path.inspect}")
    stat = File.lstat(path)
    need!(stat.file? && !stat.symlink?, "#{label} is absent, non-regular, or symlinked: #{path}")
    need!(File.realpath(path) == path, "#{label} resolves through a non-canonical path: #{path}")
    need!(!executable || File.executable?(path), "#{label} is not executable: #{path}")
    need!(max_bytes.nil? || stat.size <= max_bytes, "#{label} exceeds its #{max_bytes}-byte bound")
    path
  rescue Errno::ENOENT
    raise AuditFailure, "#{label} is absent: #{path}"
  end

  def self.safe_relative!(relative, label)
    need!(relative.is_a?(String) && !relative.empty?, "#{label} is absent")
    need!(!PathnameLike.absolute?(relative), "#{label} must be relative")
    pieces = relative.split(/[\\\/]/)
    need!(pieces.none? { |piece| piece.empty? || piece == '.' || piece == '..' }, "#{label} contains an unsafe path component")
    relative
  end

  # Avoid requiring pathname merely for absolute-path classification.
  module PathnameLike
    def self.absolute?(path)
      path.start_with?('/', '\\') || /\A[A-Za-z]:[\\\/]/.match?(path)
    end
  end

  def self.read_root_file!(root, relative, label, max_bytes: MAX_CAPTURE_BYTES)
    safe_relative!(relative, label)
    path = File.join(root, relative)
    parent = File.dirname(path)
    canonical_directory!(parent, "#{label} parent")
    canonical_file!(path, label, max_bytes: max_bytes)
    File.binread(path)
  end

  def self.read_canonical_source!(path)
    canonical_file!(path, 'captured source file', max_bytes: MAX_SOURCE_BYTES)
    file_sha256(path)
  end

  def self.directory_files!(root)
    canonical_directory!(root, 'stock part')
    files = {}
    total = 0
    walk = lambda do |directory, prefix|
      Dir.children(directory).sort.each do |name|
        relative = prefix.empty? ? name : "#{prefix}/#{name}"
        full = File.join(directory, name)
        stat = File.lstat(full)
        need!(!stat.symlink?, "stock part contains a symlink: #{relative}")
        if stat.directory?
          need!(File.realpath(full) == full, "stock part directory is non-canonical: #{relative}")
          walk.call(full, relative)
        else
          need!(stat.file?, "stock part contains a non-regular entry: #{relative}")
          total += stat.size
          need!(files.size < MAX_PART_FILES, "stock part exceeds #{MAX_PART_FILES} files")
          need!(total <= MAX_PART_BYTES, "stock part exceeds #{MAX_PART_BYTES} bytes")
          files[relative] = File.binread(full)
        end
      end
    end
    walk.call(root, '')
    need!(!files.empty?, 'stock part has no regular files')
    [files, total]
  end

  def self.actual_inventory(files)
    files.map do |path, bytes|
      { 'path' => path, 'bytes' => bytes.bytesize, 'sha256' => sha256(bytes) }
    end.sort_by { |item| item.fetch('path') }
  end

  def self.expected_summary_keys
    %w[
      probe status stage fatal_error claim_boundary source_snapshot runtime
      helper_provenance schema selected_columns_without_pk independent_rows
      settings mark_grid limits evidence_root invocations native part_inventory
      helper native_invocation helper_invocation
    ].sort
  end

  def self.validate_summary_static!(summary, root)
    need!(summary.is_a?(Hash), 'summary.json must contain one JSON object')
    need!(summary.keys.sort == expected_summary_keys, 'summary.json field roster differs')
    need!(summary['probe'] == Runner::FORMAT, 'summary probe format differs')
    need!(summary['status'] == 'stock_capture_with_green_assertions', 'capture is not a fresh GREEN-mode capture')
    need!(summary['stage'] == 'stable evidence and summary', 'runner did not finish its stable-evidence stage')
    need!(summary['fatal_error'].nil?, 'runner recorded a fatal error')
    need!(summary['claim_boundary'] == 'one ten-column Wide/.mrk2 LZ4 stock fixture on the pinned runtime and selected readers explicitly exercised; no other physical profile or universal compatibility claim', 'claim boundary differs')
    need!(summary['evidence_root'] == root, 'summary evidence root differs from its canonical directory')
    validate_fixture_binding!(summary)
    need!(summary['settings'] == { 'table' => Runner::SETTINGS, 'json' => Runner::JSON_SETTINGS }, 'summary settings differ from the runner pins')
    need!(summary['mark_grid'] == { 'data_mark_rows' => Runner::MARK_ROWS, 'rows_with_terminal' => Runner::MARK_ROWS_WITH_EOF }, 'summary mark grid differs')
    expected_limits = {
      'max_threads' => 1,
      'max_memory_usage_bytes_per_native_process' => Runner::W185::MEMORY,
      'timeout_seconds' => Runner::W180::PROCESS_TIMEOUT_SECONDS,
      'termination_grace_seconds' => Runner::W180::TERMINATION_GRACE_SECONDS,
      'max_capture_bytes_per_stream' => MAX_CAPTURE_BYTES,
      'max_part_files' => MAX_PART_FILES,
      'max_part_bytes' => MAX_PART_BYTES,
    }
    need!(summary['limits'] == expected_limits, 'summary process or inventory limits differ')
    need!(summary['source_snapshot'] == hash_rows(Runner::SOURCE_SNAPSHOT), 'comparison source snapshot is not the exact pinned revision/path (runtime provenance is separate)')
    source_path = summary.fetch('source_snapshot').fetch('path')
    need!(source_path == SOURCE_PATH, 'comparison source path differs from the pinned local snapshot')
    need!(summary.fetch('source_snapshot').fetch('revision') == SOURCE_REVISION, 'comparison source revision differs from the pinned snapshot')
    need!(summary.fetch('source_snapshot').fetch('runtime_provenance_claimed') == false, 'source snapshot was incorrectly presented as runtime provenance')
    need!(summary['runtime'].is_a?(Hash), 'runtime pin is missing')
    need!(summary['runtime'].keys.sort == %w[path expected_sha256 sha256_before sha256_after expected_version expected_build].sort, 'runtime field roster differs')
    runtime = summary['runtime']
    need!(runtime['expected_sha256'] == Runner::BINARY_SHA256, 'runtime expected SHA pin differs')
    need!(runtime['expected_version'] == Runner::VERSION && runtime['expected_build'] == Runner::BUILD, 'runtime version/build pins differ')
    need!(runtime['sha256_before'] == Runner::BINARY_SHA256 && runtime['sha256_after'] == Runner::BINARY_SHA256, 'runtime before/after SHA does not match the pinned binary')
    canonical_file!(runtime['path'], 'pinned ClickHouse runtime', executable: true)
    need!(summary['invocations'].is_a?(Array) && summary['invocations'].size == 2, 'summary must contain exactly the native and helper invocations')
    need!(summary['native_invocation'] == summary['invocations'][0], 'nested native invocation differs from the invocation roster')
    need!(summary['helper_invocation'] == summary['invocations'][1], 'nested helper invocation differs from the invocation roster')
    need!(summary['helper'].is_a?(Hash), 'helper report is missing')
    need!(summary['part_inventory'].is_a?(Hash), 'stock part inventory is missing')
    true
  rescue KeyError => error
    raise AuditFailure, "summary is missing a required field: #{error.message}"
  end

  def self.validate_fixture_binding!(summary)
    need!(summary['schema'] == Runner::SCHEMA, 'summary full schema/type/order differs from the independent fixture')
    need!(summary['selected_columns_without_pk'] == Runner::SELECTED_COLUMNS, 'summary selected-column roster/order differs')
    need!(summary['independent_rows'] == hash_rows(Runner::ROWS), 'summary independent row literals differ')
    need!(summary['mark_grid'] == { 'data_mark_rows' => Runner::MARK_ROWS, 'rows_with_terminal' => Runner::MARK_ROWS_WITH_EOF }, 'summary mark grid differs')
    true
  end

  # Resolve the checkout's pinned HEAD using only its small .git control files;
  # this deliberately does not launch Git or inspect/mutate the object database.
  def self.git_head_revision!(source_root)
    git_marker = File.join(source_root, '.git')
    marker_stat = File.lstat(git_marker)
    need!(!marker_stat.symlink?, 'comparison source .git marker is symlinked')
    git_dir = if marker_stat.directory?
                git_marker
              elsif marker_stat.file?
                marker = File.binread(git_marker).force_encoding(Encoding::UTF_8)
                need!(marker.valid_encoding? && marker.start_with?('gitdir: '), 'comparison source .git file is malformed')
                raw_git_dir = marker.delete_prefix('gitdir: ').strip
                need!(!raw_git_dir.empty?, 'comparison source gitdir is empty')
                File.expand_path(raw_git_dir, source_root)
              else
                raise AuditFailure, 'comparison source .git marker is not a directory or regular file'
              end
    canonical_directory!(git_dir, 'comparison source git directory')
    head_path = File.join(git_dir, 'HEAD')
    canonical_file!(head_path, 'comparison source HEAD', max_bytes: 4096)
    head = File.binread(head_path).force_encoding(Encoding::UTF_8)
    need!(head.valid_encoding?, 'comparison source HEAD is not UTF-8')
    text = head.strip
    if text.start_with?('ref: ')
      reference = text.delete_prefix('ref: ')
      safe_relative!(reference, 'comparison source HEAD reference')
      ref_path = File.join(git_dir, reference)
      if File.exist?(ref_path) || File.symlink?(ref_path)
        canonical_file!(ref_path, 'comparison source loose HEAD reference', max_bytes: 4096)
        revision = File.read(ref_path, encoding: 'UTF-8').strip
      else
        packed_path = File.join(git_dir, 'packed-refs')
        canonical_file!(packed_path, 'comparison source packed refs', max_bytes: 16 * 1024 * 1024)
        matches = File.readlines(packed_path, encoding: 'UTF-8').map do |line|
          next if line.start_with?('#', '^')
          oid, name = line.split(' ', 2)
          oid if name&.strip == reference
        end.compact
        need!(matches.size == 1, 'comparison source HEAD reference is absent or ambiguous in packed-refs')
        revision = matches.fetch(0)
      end
    else
      revision = text
    end
    need!(revision.match?(/\A[0-9a-f]{40}\z/) && revision == SOURCE_REVISION, 'comparison source checkout HEAD differs from the exact pinned revision')
    revision
  rescue Errno::ENOENT
    raise AuditFailure, 'comparison source snapshot or Git HEAD control files are absent'
  end

  def self.expected_invocation_keys(kind)
    extras = case kind
             when 'clickhouse local' then %w[stdin_file binary_sha_before]
             when 'prebuilt Crystal checker' then %w[helper_sha_before helper_sha_after]
             else []
             end
    (INVOCATION_BASE_KEYS + extras).sort
  end

  def self.validate_invocation_core!(record:, stdout:, stderr:, stdin:, argv_file:, expected_argv:, kind:, max_memory:, expected_binary_sha:)
    need!(record.is_a?(Hash), 'invocation record is not an object')
    need!(record.keys.sort == expected_invocation_keys(kind), "#{kind} invocation field roster differs")
    need!(record['process_kind'] == kind, "#{kind} process kind differs")
    need!(record['argv'] == expected_argv, "#{kind} argv differs from the exact runner invocation")
    expected_argv_file = (JSON.pretty_generate(expected_argv) + "\n").b
    need!(argv_file == expected_argv_file, "#{kind} argv.json bytes differ")
    need!(record['argv_sha256'] == sha256(expected_argv_file), "#{kind} argv digest differs from the W185 support algorithm")
    need!(record['stdin_bytes'] == stdin.bytesize && record['stdin_sha256'] == sha256(stdin), "#{kind} stdin byte count/digest differs from captured bytes")
    need!(record['stdout_bytes'] == stdout.bytesize && record['stdout_sha256'] == sha256(stdout), "#{kind} stdout byte count/digest differs from captured bytes")
    need!(stdout.bytesize <= MAX_CAPTURE_BYTES && stderr.bytesize <= MAX_CAPTURE_BYTES && stdin.bytesize <= MAX_CAPTURE_BYTES, "#{kind} stream exceeds the capture bound")
    need!(record['stderr_bytes'] == stderr.bytesize && record['stderr_sha256'] == sha256(stderr), "#{kind} stderr byte count/digest differs from captured bytes")
    need!(record['exit'] == 0 && record['signal'].nil? && record['timed_out'] == false, "#{kind} did not exit 0 without signal/timeout")
    need!(record['spawn_error'].nil? && record['stdin_write_error'].nil? && record['stdout_read_error'].nil? && record['stderr_read_error'].nil?, "#{kind} recorded a process read/write/spawn error")
    need!(record['process_classification'] == 'success', "#{kind} classification is not success")
    need!(stderr.empty?, "#{kind} wrote stderr")
    need!(record['timeout_seconds'] == Runner::W180::PROCESS_TIMEOUT_SECONDS && record['termination_grace_seconds'] == Runner::W180::TERMINATION_GRACE_SECONDS, "#{kind} timeout pins differ")
    need!(record['max_threads'] == 1, "#{kind} max_threads differs")
    need!(record['max_memory_usage_bytes'] == max_memory && record['max_memory_usage_applicable'] == !max_memory.nil?, "#{kind} memory guard differs")
    need!(record['required_outer_run_safe_memory_limit_bytes'] == Runner::W185::OUTER_RUN_SAFE_LIMIT, "#{kind} outer safe-memory limit differs")
    need!(record['expected_binary_sha256'] == expected_binary_sha, "#{kind} expected executable pin differs")
    need!(record['binary_sha_after'] == expected_binary_sha, "#{kind} executable after-hash differs")
    if kind == 'clickhouse local'
      need!(record['binary_sha_before'] == expected_binary_sha, 'native executable before-hash differs')
    end
    true
  rescue KeyError => error
    raise AuditFailure, "#{kind} invocation is missing a required field: #{error.message}"
  end

  def self.validate_helper_provenance!(provenance, actual_sha, actual_source_hashes, expected_paths)
    need!(provenance.is_a?(Hash), 'helper_provenance is missing; baseline captures are intentionally not accepted as GREEN')
    need!(provenance.keys.sort == %w[path protocol mode sha256_before sha256_after source_files_before source_files_after].sort, 'helper provenance field roster differs')
    need!(provenance['protocol'] == Runner::HELPER_FORMAT && provenance['mode'] == 'green', 'helper protocol/mode is not GREEN W261')
    need!(provenance['path'].is_a?(String), 'helper binary path is missing')
    need!(provenance['sha256_before'] == actual_sha && provenance['sha256_after'] == actual_sha, 'helper binary before/after hashes do not close over the actual helper')
    before = provenance['source_files_before']
    after = provenance['source_files_after']
    need!(before.is_a?(Array) && after.is_a?(Array), 'helper source-file before/after arrays are missing')
    normalize_sources = lambda do |entries, label|
      need!(entries.all? { |entry| entry.is_a?(Hash) && entry.keys.sort == SOURCE_KEYS.sort }, "#{label} source hash entry schema differs")
      paths = entries.map { |entry| entry['path'] }
      need!(paths == expected_paths, "#{label} source-file roster/order differs")
      entries.each do |entry|
        digest = entry['sha256']
        need!(digest.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(digest), "#{label} source hash is malformed")
      end
      entries.to_h { |entry| [entry['path'], entry['sha256']] }
    end
    before_map = normalize_sources.call(before, 'before')
    after_map = normalize_sources.call(after, 'after')
    need!(before_map == after_map && after_map == actual_source_hashes, 'source-file hashes do not close over stable current runner/helper/fixture bytes')
    true
  rescue KeyError => error
    raise AuditFailure, "helper provenance is missing a required field: #{error.message}"
  end

  def self.validate_green_report!(report)
    need!(report.is_a?(Hash), 'helper stdout report must be one JSON object')
    expected_keys = %w[
      format status assertions ordinary_controls selected_columns_without_pk
      row_count mark_row_counts direct_rows_by_column selected_table_attempts
      offline_values offline_budgets
    ]
    need!(report.keys == expected_keys, 'GREEN helper report field roster/order differs')
    need!(report['format'] == Runner::HELPER_FORMAT && report['status'] == 'green_all_assertions', 'helper report format/status differs')
    need!(report['assertions'] == ASSERTIONS, 'helper report assertion roster/order differs')
    need!(report['ordinary_controls'] == 'green', 'ordinary pk/u/side controls are not GREEN')
    columns = Runner::SELECTED_COLUMNS
    rows = Runner::ROWS.size
    need!(report['selected_columns_without_pk'] == columns, 'helper selected-column roster/order differs')
    need!(report['row_count'] == rows, 'helper total row count differs')
    need!(report['mark_row_counts'] == Runner::MARK_ROWS, 'helper mark grid differs')
    direct = report['direct_rows_by_column']
    need!(direct.is_a?(Array) && direct.size == columns.size, 'helper direct-column result roster is missing')
    direct.each_with_index do |entry, index|
      need!(entry.is_a?(Hash) && entry.keys == %w[column rows full_and_window_literals], 'direct-column report schema/order differs')
      need!(entry['column'] == columns[index] && entry['rows'] == rows && entry['full_and_window_literals'] == 'green', 'direct full/window row/type assertion report differs')
    end
    tables = report['selected_table_attempts']
    need!(tables.is_a?(Array) && tables.size == SELECTED_TABLES.size, 'selected-table result roster is missing')
    tables.each_with_index do |entry, index|
      need!(entry.is_a?(Hash) && entry.keys == %w[name status rows window_rows eof_callbacks], 'selected-table report schema/order differs')
      need!(entry['name'] == SELECTED_TABLES[index] && entry['status'] == 'green', 'selected-table names/order/status differ')
      need!(entry['rows'] == rows && entry['window_rows'] == 4 && entry['eof_callbacks'] == 0, 'selected-table full/window/EOF counts differ')
    end
    offline = report['offline_values']
    need!(offline.is_a?(Hash) && offline.keys == columns, 'offline value roster/order differs')
    need!(columns.all? { |column| offline[column] == rows }, 'offline value cardinalities differ')
    budgets = report['offline_budgets']
    need!(budgets.is_a?(Hash) && budgets.keys == columns, 'offline budget roster/order differs')
    columns.each do |column|
      # The helper fixture is the independent budget source; the runner report
      # is checked against literal values mirrored here, not against itself.
      budget = {
        'u' => [0, 0], 'side' => [64, 0], 'seq' => [17, 15],
        'mapped' => [30, 18], 'simple' => [0, 0], 'lookup' => [17, 0],
        'tup' => [64, 16], 'lc' => [24, 0], 'v' => [19, 0],
      }.fetch(column)
      got = budgets[column]
      need!(got.is_a?(Hash) && got.keys == %w[string_bytes tuple_cells one_less_string_rejected one_less_tuple_rejected], "#{column} budget field roster/order differs")
      need!(got['string_bytes'] == budget[0] && got['tuple_cells'] == budget[1], "#{column} exact budget output differs")
      need!(got['one_less_string_rejected'] == (budget[0] > 0) && got['one_less_tuple_rejected'] == (budget[1] > 0), "#{column} one-less budget boundary output differs")
    end
    true
  rescue KeyError => error
    raise AuditFailure, "GREEN helper report is missing a required field: #{error.message}"
  end

  def self.validate_substream_roster!(text)
    need!(text.is_a?(String) && text.end_with?("\n"), 'columns_substreams.txt is absent or lacks its final newline')
    lines = text.lines(chomp: true)
    need!(lines[0] == 'columns substreams version: 1', 'columns_substreams version differs')
    need!(lines[1] == "#{Runner::SCHEMA.size} columns:", 'columns_substreams column count differs')
    index = 2
    seen_streams = []
    Runner::SCHEMA.each do |name, _type|
      expected_streams = EXPECTED_SUBSTREAMS.fetch(name)
      header = lines[index]
      match = header && /\A([1-9][0-9]*) substreams for column `([^`]+)`:\z/.match(header)
      need!(match && match[2] == name, "columns_substreams logical roster/order differs at #{name}")
      count = Integer(match[1], 10)
      need!(count == expected_streams.size, "columns_substreams exact stream count differs for #{name}")
      index += 1
      streams = lines[index, count]
      need!(streams && streams.size == count, "columns_substreams stream count is truncated for #{name}")
      actual_streams = streams.map do |line|
        need!(line.start_with?("\t") && line.bytesize > 1, "columns_substreams has a malformed stream entry for #{name}")
        line.delete_prefix("\t")
      end
      need!(actual_streams == expected_streams, "columns_substreams exact canonical escaped stream roster/order differs for #{name}")
      seen_streams.concat(actual_streams)
      index += count
    end
    need!(index == lines.size, 'columns_substreams contains trailing or unrostered entries')
    need!(seen_streams.uniq == seen_streams, 'columns_substreams contains duplicate logical stream names')
    true
  end

  def self.validate_part_inventory!(inventory, files, native_part)
    need!(inventory.is_a?(Hash), 'part_inventory must be an object')
    expected_keys = %w[
      name part_type rows marks count_text metadata_version codec
      serialization_json serialization_json_sha256 columns_text
      columns_substreams_text plain_mark_rows_by_file plain_mark_file_count
      compressed_mark_files files
    ].sort
    need!(inventory.keys.sort == expected_keys, 'part_inventory field roster differs')
    need!(files.is_a?(Hash) && files.size <= MAX_PART_FILES, 'actual stock part file set exceeds its bound')
    need!(files.values.all? { |bytes| bytes.is_a?(String) }, 'actual stock part contains a non-byte entry')
    need!(files.values.sum(&:bytesize) <= MAX_PART_BYTES, 'actual stock part byte total exceeds its bound')
    need!(inventory['files'] == actual_inventory(files), 'summary part file paths/sizes/SHA-256 differ from actual canonical bytes')
    need!(inventory['name'] == Runner::PART_NAME && inventory['part_type'] == 'Wide' && inventory['rows'] == '8' && inventory['marks'] == '5', 'part inventory identity/geometry differs from native part metadata')
    need!(inventory['name'] == native_part.fetch(:name) && inventory['part_type'] == native_part.fetch(:part_type) && inventory['rows'] == native_part.fetch(:rows) && inventory['marks'] == native_part.fetch(:marks), 'summary part identity differs from parsed native part metadata')
    required = %w[columns.txt columns_substreams.txt count.txt checksums.txt primary.idx serialization.json default_compression_codec.txt metadata_version.txt]
    need!((required - files.keys).empty?, 'actual stock part omits required Wide metadata files')
    columns = (['columns format version: 1', "#{Runner::SCHEMA.size} columns:"] + Runner::SCHEMA.map { |name, type| "`#{name}` #{type}" }).join("\n") + "\n"
    need!(files['columns.txt'] == columns.b && inventory['columns_text'] == columns, 'actual columns.txt differs from the exact ten-column schema')
    substreams = files.fetch('columns_substreams.txt').dup.force_encoding(Encoding::UTF_8)
    need!(substreams.valid_encoding?, 'actual columns_substreams.txt is not UTF-8')
    validate_substream_roster!(substreams)
    need!(inventory['columns_substreams_text'] == substreams, 'summary columns_substreams text differs from actual bytes')
    need!(files['count.txt'].dup.force_encoding(Encoding::UTF_8).strip == '8' && inventory['count_text'] == '8', 'actual count.txt differs from eight rows')
    need!(files['metadata_version.txt'].dup.force_encoding(Encoding::UTF_8).strip == '0' && inventory['metadata_version'] == '0', 'actual metadata_version.txt differs from plain mrk2 profile')
    codec = files['default_compression_codec.txt'].dup.force_encoding(Encoding::UTF_8).strip
    need!(codec == 'CODEC(LZ4)' && inventory['codec'] == codec, 'actual default compression codec differs from LZ4')
    serialization_bytes = files.fetch('serialization.json')
    serialization = JSON.parse(serialization_bytes.dup.force_encoding(Encoding::UTF_8))
    need!(serialization['version'] == 1 && serialization['propagate_types_serialization_versions_to_nested_types'] == true, 'actual serialization.json version/propagation differs')
    need!(serialization.dig('types_serialization_versions', 'string') == 1, 'actual String serialization version differs from with_size_stream/v1')
    need!(inventory['serialization_json'] == serialization, 'summary serialization JSON differs from actual bytes')
    need!(inventory['serialization_json_sha256'] == sha256(serialization_bytes), 'summary serialization JSON SHA differs from actual bytes')
    mark_files = files.keys.select { |path| path.end_with?('.mrk2') }.sort
    compressed = files.keys.select { |path| /\.cmrk\d*\z/.match?(path) }.sort
    need!(!mark_files.empty?, 'actual stock part has no plain mrk2 files')
    need!(mark_files.size == EXPECTED_MARK_FILE_COUNT, 'actual mrk2 file count differs from the exact physical stream roster')
    need!(compressed.empty? && inventory['compressed_mark_files'] == [], 'actual stock part unexpectedly contains compressed marks')
    mark_rows = {}
    mark_files.each do |path|
      bytes = files.fetch(path)
      need!(bytes.bytesize.positive? && (bytes.bytesize % 24).zero?, "#{path} is not a sequence of mrk2 triples")
      triples = bytes.unpack('Q<*').each_slice(3).to_a
      need!(triples.size == 5, "#{path} does not contain the five-mark grid")
      positions = triples.map { |triple| triple[0, 2] }
      need!(positions.each_cons(2).all? { |left, right| (left <=> right) <= 0 }, "#{path} mark offsets are not monotonic")
      grid = triples.map { |triple| triple[2] }
      need!(grid == Runner::MARK_ROWS_WITH_EOF, "#{path} mark row grid differs from the four-data-mark plus EOF schedule")
      mark_rows[path] = grid
    end
    need!(mark_files.include?("#{Runner::KEY_HASH}.mrk2"), 'pk stock mark file is absent')
    need!(inventory['plain_mark_rows_by_file'] == mark_rows, 'summary mark rows differ from actual mrk2 bytes')
    need!(inventory['plain_mark_file_count'] == mark_files.size, 'summary plain mark file count differs')
    true
  rescue JSON::ParserError => error
    raise AuditFailure, "actual stock metadata JSON is malformed: #{error.message}"
  rescue KeyError => error
    raise AuditFailure, "part inventory is missing a required field: #{error.message}"
  end

  def self.record_sidecar!(sidecar_bytes, summary_record, kind)
    sidecar = JSON.parse(sidecar_bytes.dup.force_encoding(Encoding::UTF_8))
    omitted = kind == 'clickhouse local' ? %w[binary_sha_before] : %w[helper_sha_before helper_sha_after]
    expected = summary_record.reject { |key, _value| omitted.include?(key) }
    need!(sidecar == expected, "#{kind} sidecar record differs from the summary capture")
    need!(sidecar_bytes == (JSON.pretty_generate(sidecar) + "\n").b, "#{kind} sidecar record is not canonical runner JSON")
    true
  rescue JSON::ParserError => error
    raise AuditFailure, "invocation sidecar is invalid JSON: #{error.message}"
  end

  def self.audit_capture(path_or_root)
    expanded = File.expand_path(path_or_root)
    root = File.file?(expanded) ? File.dirname(expanded) : expanded
    canonical_directory!(root, 'evidence root')
    need!(File.dirname(root) == File.realpath('/private/tmp'), 'evidence root is not a direct child of /private/tmp')
    summary_path = File.join(root, 'summary.json')
    canonical_file!(summary_path, 'summary.json', max_bytes: MAX_SUMMARY_BYTES)
    if File.file?(expanded)
      need!(expanded == summary_path, 'input file must be the evidence root summary.json')
    end
    summary_bytes = File.binread(summary_path)
    summary = JSON.parse(summary_bytes.dup.force_encoding(Encoding::UTF_8))
    need!(summary_bytes == (JSON.pretty_generate(summary) + "\n").b, 'summary.json bytes are not canonical runner JSON')
    validate_summary_static!(summary, root)

    helper_provenance = summary.fetch('helper_provenance')
    need!(helper_provenance.is_a?(Hash), 'helper_provenance is missing; baseline captures are not accepted as GREEN')
    runtime_path = summary.fetch('runtime').fetch('path')
    helper_path = helper_provenance.fetch('path')
    canonical_file!(runtime_path, 'pinned ClickHouse runtime', executable: true)
    canonical_file!(helper_path, 'prebuilt GREEN checker', executable: true)
    runtime_sha = file_sha256(runtime_path)
    helper_sha = file_sha256(helper_path)
    need!(runtime_sha == Runner::BINARY_SHA256, 'actual ClickHouse runtime SHA differs from the pinned binary')

    records = summary.fetch('invocations')
    native_record, helper_record = records
    native_stdout_rel = native_record.fetch('stdout_file')
    helper_stdout_rel = helper_record.fetch('stdout_file')
    need!(native_stdout_rel == "#{NATIVE_LABEL}.stdout" && helper_stdout_rel == "#{HELPER_LABEL}.stdout", 'invocation labels/order differ')
    need!(native_record['stderr_file'] == "#{NATIVE_LABEL}.stderr" && native_record['stdin_file'] == "#{NATIVE_LABEL}.stdin.sql", 'native invocation artifact names differ')
    need!(helper_record['stderr_file'] == "#{HELPER_LABEL}.stderr" && helper_record['stdin_bytes'] == 0, 'helper invocation artifact names/stdin declaration differ')
    native_base = "invocations/#{NATIVE_LABEL}"
    helper_base = "invocations/#{HELPER_LABEL}"
    native_stdout = read_root_file!(root, "#{native_base}.stdout", 'native stdout')
    native_stderr = read_root_file!(root, "#{native_base}.stderr", 'native stderr')
    native_stdin = read_root_file!(root, "#{native_base}.stdin.sql", 'native stdin SQL')
    native_argv_file = read_root_file!(root, "#{native_base}.argv.json", 'native argv JSON')
    native_sidecar = read_root_file!(root, "#{native_base}.json", 'native invocation sidecar')
    helper_stdout = read_root_file!(root, "#{helper_base}.stdout", 'helper stdout')
    helper_stderr = read_root_file!(root, "#{helper_base}.stderr", 'helper stderr')
    helper_argv_file = read_root_file!(root, "#{helper_base}.argv.json", 'helper argv JSON')
    helper_sidecar = read_root_file!(root, "#{helper_base}.json", 'helper invocation sidecar')
    helper_stdin = ''.b
    need!(helper_record['stdin_file'].nil?, 'helper unexpectedly declares a captured stdin file')
    expected_invocation_files = %w[
      stock_source.argv.json stock_source.json stock_source.stderr stock_source.stdin.sql stock_source.stdout
      typed_admission.argv.json typed_admission.json typed_admission.stderr typed_admission.stdout
    ].sort
    invocations_dir = File.join(root, 'invocations')
    canonical_directory!(invocations_dir, 'invocations directory')
    need!(Dir.children(invocations_dir).sort == expected_invocation_files, 'invocations directory has missing or unrostered capture artifacts')

    store = File.join(root, 'stores', 'native')
    canonical_directory!(File.dirname(store), 'stores directory')
    canonical_directory!(store, 'native store')
    expected_native_argv = [runtime_path, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1', "--max_memory_usage=#{Runner::W185::MEMORY}", '--output_format_json_quote_64bit_integers=0', '--multiquery']
    validate_invocation_core!(record: native_record, stdout: native_stdout, stderr: native_stderr, stdin: native_stdin,
                              argv_file: native_argv_file, expected_argv: expected_native_argv,
                              kind: 'clickhouse local', max_memory: Runner::W185::MEMORY,
                              expected_binary_sha: Runner::BINARY_SHA256)
    need!(native_record['binary_sha_before'] == runtime_sha && native_record['binary_sha_after'] == runtime_sha, 'native invocation runtime before/after SHA differs')
    record_sidecar!(native_sidecar, native_record, 'clickhouse local')
    native_probe = Probe.allocate
    native_probe.instance_variable_set(:@store, store)
    parsed_native = native_probe.send(:parse_native, native_stdout.dup.force_encoding(Encoding::UTF_8))
    pin_lines = native_stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp).select { |line| line.start_with?("#{Runner::TAG[:pin]}\t") }
    need!(pin_lines.size == 1, 'native stdout must contain exactly one runtime pin row')
    need!(native_stdout.dup.force_encoding(Encoding::UTF_8).valid_encoding?, 'native stdout is not valid UTF-8')
    native_probe.send(:assert_pin!, { stdout: native_stdout })
    native_probe.send(:assert_native_fixture!, parsed_native)
    expected_parsed_native = hash_rows(parsed_native)
    need!(summary['native'] == expected_parsed_native, 'summary native result differs from parsing its actual stdout bytes')
    expected_stdin = native_probe.send(:initial_sql).b
    need!(native_stdin == expected_stdin, 'native stdin SQL differs from the exact W261 runner fixture')

    part_path = File.expand_path(parsed_native.fetch(:part).fetch(:path))
    canonical_directory!(part_path, 'stock part directory')
    need!(part_path.start_with?(store + File::SEPARATOR), 'stock part escaped the isolated native store')
    stock_path_file = read_root_file!(root, 'stock-part.path', 'stock part path receipt', max_bytes: 4096)
    need!(stock_path_file == "#{part_path}\n".b, 'stock-part.path receipt differs from native part metadata')
    actual_part_files, = directory_files!(part_path)
    validate_part_inventory!(summary.fetch('part_inventory'), actual_part_files, parsed_native.fetch(:part))

    helper_work = File.join(root, 'helper-work', 'checker-work')
    canonical_directory!(File.dirname(helper_work), 'helper work parent')
    canonical_directory!(helper_work, 'helper work directory')
    expected_helper_argv = [helper_path, 'green', part_path, helper_work]
    validate_invocation_core!(record: helper_record, stdout: helper_stdout, stderr: helper_stderr, stdin: helper_stdin,
                              argv_file: helper_argv_file, expected_argv: expected_helper_argv,
                              kind: 'prebuilt Crystal checker', max_memory: nil, expected_binary_sha: nil)
    need!(helper_record['helper_sha_before'] == helper_sha && helper_record['helper_sha_after'] == helper_sha, 'helper invocation before/after SHA differs from the actual binary')
    record_sidecar!(helper_sidecar, helper_record, 'prebuilt Crystal checker')
    helper_lines = helper_stdout.dup.force_encoding(Encoding::UTF_8).lines.map(&:chomp).reject(&:empty?)
    need!(helper_lines.size == 1 && helper_stdout == "#{helper_lines.fetch(0)}\n".b, 'helper stdout must be exactly one JSON record and newline')
    helper_report = JSON.parse(helper_lines.fetch(0))
    validate_green_report!(helper_report)
    need!(summary['helper'] == helper_report, 'summary helper report differs from captured helper stdout')
    need!(helper_provenance['path'] == helper_path, 'helper provenance path differs')

    expected_sources = source_file_paths
    actual_sources = expected_sources.to_h { |source| [source, read_canonical_source!(source)] }
    validate_helper_provenance!(helper_provenance, helper_sha, actual_sources, expected_sources)
    source_root = summary.fetch('source_snapshot').fetch('path')
    canonical_directory!(source_root, 'pinned ClickHouse comparison source snapshot')
    need!(git_head_revision!(source_root) == SOURCE_REVISION, 'comparison source HEAD differs from the pinned revision')

    {
      'status' => 'audited_green_capture',
      'evidence_root' => root,
      'source_revision' => SOURCE_REVISION,
      'runtime_sha256' => runtime_sha,
      'helper_sha256' => helper_sha,
      'native_rows' => Runner::ROWS.size,
      'selected_columns' => Runner::SELECTED_COLUMNS,
      'part_files' => actual_part_files.size,
      'part_bytes' => actual_part_files.values.sum(&:bytesize),
      'helper_assertions' => ASSERTIONS,
    }
  rescue JSON::ParserError => error
    raise AuditFailure, "capture JSON is malformed: #{error.message}"
  rescue KeyError => error
    raise AuditFailure, "capture is missing a required field: #{error.message}"
  end

  def self.audit(path_or_root, peer_root: nil)
    primary = audit_capture(path_or_root)
    return primary unless peer_root
    peer = audit_capture(peer_root)
    need!(primary['source_revision'] == peer['source_revision'] && primary['runtime_sha256'] == peer['runtime_sha256'], 'DEBUG/RELEASE peer does not share the exact source/runtime pins')
    need!(primary['selected_columns'] == peer['selected_columns'] && primary['native_rows'] == peer['native_rows'], 'DEBUG/RELEASE peer fixture roster differs')
    {
      'status' => 'audited_green_peer_captures',
      'primary' => primary,
      'peer' => peer,
      'peer_helper_binaries_distinct' => primary['helper_sha256'] != peer['helper_sha256'],
    }
  end

  def self.synthetic_record
    argv = ['/pinned/clickhouse', 'local']
    stdout = "observed\n".b
    stderr = ''.b
    stdin = "SELECT 1\n".b
    argv_bytes = (JSON.pretty_generate(argv) + "\n").b
    {
      'process_kind' => 'clickhouse local', 'argv' => argv,
      'argv_sha256' => sha256(argv_bytes), 'stdin_bytes' => stdin.bytesize,
      'stdin_sha256' => sha256(stdin), 'exit' => 0, 'signal' => nil,
      'timed_out' => false, 'timeout_seconds' => Runner::W180::PROCESS_TIMEOUT_SECONDS,
      'termination_grace_seconds' => Runner::W180::TERMINATION_GRACE_SECONDS,
      'max_threads' => 1, 'max_memory_usage_bytes' => 123,
      'max_memory_usage_applicable' => true,
      'required_outer_run_safe_memory_limit_bytes' => Runner::W185::OUTER_RUN_SAFE_LIMIT,
      'expected_binary_sha256' => 'a' * 64,
      'spawn_error' => nil, 'stdin_write_error' => nil, 'stdout_read_error' => nil,
      'stderr_read_error' => nil, 'process_classification' => 'success',
      'stdout_bytes' => stdout.bytesize, 'stdout_sha256' => sha256(stdout),
      'stderr_bytes' => 0, 'stderr_sha256' => sha256(stderr),
      'stdout_file' => 'stock_source.stdout', 'stderr_file' => 'stock_source.stderr',
      'stdin_file' => 'stock_source.stdin.sql', 'binary_sha_before' => 'a' * 64,
      'binary_sha_after' => 'a' * 64,
    }.tap { |record| @self_test_bytes = { stdout: stdout, stderr: stderr, stdin: stdin, argv: argv, argv_file: argv_bytes } }
  end

  def self.synthetic_report
    columns = Runner::SELECTED_COLUMNS
    budgets = {
      'u' => [0, 0], 'side' => [64, 0], 'seq' => [17, 15],
      'mapped' => [30, 18], 'simple' => [0, 0], 'lookup' => [17, 0],
      'tup' => [64, 16], 'lc' => [24, 0], 'v' => [19, 0],
    }
    {
      'format' => Runner::HELPER_FORMAT, 'status' => 'green_all_assertions',
      'assertions' => ASSERTIONS, 'ordinary_controls' => 'green',
      'selected_columns_without_pk' => columns, 'row_count' => Runner::ROWS.size,
      'mark_row_counts' => Runner::MARK_ROWS,
      'direct_rows_by_column' => columns.map { |column| { 'column' => column, 'rows' => Runner::ROWS.size, 'full_and_window_literals' => 'green' } },
      'selected_table_attempts' => SELECTED_TABLES.map { |name| { 'name' => name, 'status' => 'green', 'rows' => 8, 'window_rows' => 4, 'eof_callbacks' => 0 } },
      'offline_values' => columns.to_h { |column| [column, 8] },
      'offline_budgets' => columns.to_h do |column|
        string_bytes, tuple_cells = budgets.fetch(column)
        [column, { 'string_bytes' => string_bytes, 'tuple_cells' => tuple_cells,
                   'one_less_string_rejected' => string_bytes > 0,
                   'one_less_tuple_rejected' => tuple_cells > 0 }]
      end,
    }
  end

  def self.synthetic_part_files
    columns = (['columns format version: 1', "#{Runner::SCHEMA.size} columns:"] + Runner::SCHEMA.map { |name, type| "`#{name}` #{type}" }).join("\n") + "\n"
    substreams = +"columns substreams version: 1\n#{Runner::SCHEMA.size} columns:\n"
    Runner::SCHEMA.each do |name, _type|
      expected_streams = EXPECTED_SUBSTREAMS.fetch(name)
      substreams << "#{expected_streams.size} substreams for column `#{name}`:\n"
      expected_streams.each { |stream| substreams << "\t#{stream}\n" }
    end
    serialization = JSON.pretty_generate({ 'version' => 1, 'propagate_types_serialization_versions_to_nested_types' => true,
                                           'types_serialization_versions' => { 'string' => 1 } }) + "\n"
    mark_rows = Runner::MARK_ROWS_WITH_EOF
    mark_bytes = mark_rows.each_with_index.flat_map { |rows, index| [index * 24, 24, rows] }.pack('Q<*')
    mark_paths = [Runner::KEY_HASH] + (1...EXPECTED_MARK_FILE_COUNT).map { |index| format('%032x', index) }
    files = {
      'columns.txt' => columns.b,
      'columns_substreams.txt' => substreams.b,
      'count.txt' => "8\n".b,
      'checksums.txt' => ''.b,
      'primary.idx' => ''.b,
      'serialization.json' => serialization.b,
      'default_compression_codec.txt' => "CODEC(LZ4)\n".b,
      'metadata_version.txt' => "0\n".b,
    }
    mark_paths.each { |path| files["#{path}.mrk2"] = mark_bytes.dup }
    files
  end

  def self.synthetic_inventory(files, native_part)
    serialization = JSON.parse(files.fetch('serialization.json'))
    mark_rows = files.keys.select { |path| path.end_with?('.mrk2') }.sort.to_h do |mark_path|
      rows = files.fetch(mark_path).unpack('Q<*').each_slice(3).map { |triple| triple[2] }
      [mark_path, rows]
    end
    {
      'name' => native_part[:name], 'part_type' => native_part[:part_type],
      'rows' => native_part[:rows], 'marks' => native_part[:marks],
      'count_text' => '8', 'metadata_version' => '0', 'codec' => 'CODEC(LZ4)',
      'serialization_json' => serialization,
      'serialization_json_sha256' => sha256(files.fetch('serialization.json')),
      'columns_text' => files.fetch('columns.txt').dup.force_encoding(Encoding::UTF_8),
      'columns_substreams_text' => files.fetch('columns_substreams.txt').dup.force_encoding(Encoding::UTF_8),
      'plain_mark_rows_by_file' => mark_rows,
      'plain_mark_file_count' => mark_rows.size, 'compressed_mark_files' => [],
      'files' => actual_inventory(files),
    }
  end

  def self.synthetic_provenance(paths, source_hashes, helper_sha = 'c' * 64)
    entries = paths.map { |path| { 'path' => path, 'sha256' => source_hashes.fetch(path) } }
    {
      'path' => '/tmp/checker', 'protocol' => Runner::HELPER_FORMAT,
      'mode' => 'green', 'sha256_before' => helper_sha, 'sha256_after' => helper_sha,
      'source_files_before' => json_clone(entries), 'source_files_after' => json_clone(entries),
    }
  end

  def self.self_test!
    controls = []
    record = synthetic_record
    bytes = @self_test_bytes
    base = lambda do |candidate|
      validate_invocation_core!(record: candidate, stdout: bytes[:stdout], stderr: bytes[:stderr], stdin: bytes[:stdin],
                                argv_file: bytes[:argv_file], expected_argv: bytes[:argv], kind: 'clickhouse local',
                                max_memory: 123, expected_binary_sha: 'a' * 64)
    end
    base.call(record)
    record_mutations = {
      'nonzero exit' => ->(x) { x['exit'] = 1 },
      'signal' => ->(x) { x['signal'] = 9 },
      'timeout' => ->(x) { x['timed_out'] = true },
      'classification' => ->(x) { x['process_classification'] = 'runtime_or_system_error' },
      'spawn error' => ->(x) { x['spawn_error'] = 'spawn failed' },
      'stdin write error' => ->(x) { x['stdin_write_error'] = 'write failed' },
      'stdout read error' => ->(x) { x['stdout_read_error'] = 'read failed' },
      'stderr read error' => ->(x) { x['stderr_read_error'] = 'read failed' },
      'stdout size' => ->(x) { x['stdout_bytes'] += 1 },
      'stdout digest' => ->(x) { x['stdout_sha256'] = '0' * 64 },
      'stderr size' => ->(x) { x['stderr_bytes'] = 1 },
      'stderr digest' => ->(x) { x['stderr_sha256'] = '0' * 64 },
      'stdin size' => ->(x) { x['stdin_bytes'] += 1 },
      'stdin digest' => ->(x) { x['stdin_sha256'] = '0' * 64 },
      'argv digest algorithm' => ->(x) { x['argv_sha256'] = '0' * 64 },
      'argv order/value' => ->(x) { x['argv'] = x['argv'].reverse },
      'wrong runtime pin' => ->(x) { x['expected_binary_sha256'] = 'b' * 64 },
      'before runtime hash' => ->(x) { x['binary_sha_before'] = 'b' * 64 },
      'after runtime hash' => ->(x) { x['binary_sha_after'] = 'b' * 64 },
      'memory cap' => ->(x) { x['max_memory_usage_bytes'] += 1 },
      'thread cap' => ->(x) { x['max_threads'] = 2 },
    }
    record_mutations.each do |name, mutate|
      candidate = json_clone(record)
      mutate.call(candidate)
      begin
        base.call(candidate)
        raise AuditFailure, "self-test failed to reject #{name}"
      rescue AuditFailure => error
        raise if error.message == "self-test failed to reject #{name}"
        controls << name
      end
    end

    report = synthetic_report
    validate_green_report!(report)
    report_mutations = {
      'missing selected type column' => ->(x) { x['selected_columns_without_pk'].pop },
      'selected-column order' => ->(x) { x['selected_columns_without_pk'].reverse! },
      'full row count' => ->(x) { x['row_count'] = 7 },
      'data mark grid' => ->(x) { x['mark_row_counts'][-1] = 1 },
      'direct report order' => ->(x) { x['direct_rows_by_column'].reverse! },
      'direct report cardinality' => ->(x) { x['direct_rows_by_column'][0]['rows'] = 7 },
      'direct full/window literal claim' => ->(x) { x['direct_rows_by_column'][0]['full_and_window_literals'] = 'red' },
      'selected-table roster' => ->(x) { x['selected_table_attempts'].reverse! },
      'selected-table status' => ->(x) { x['selected_table_attempts'][0]['status'] = 'rejected' },
      'selected-table full rows' => ->(x) { x['selected_table_attempts'][0]['rows'] = 7 },
      'selected-table window rows' => ->(x) { x['selected_table_attempts'][0]['window_rows'] = 3 },
      'EOF callback count' => ->(x) { x['selected_table_attempts'][0]['eof_callbacks'] = 1 },
      'offline typed value missing' => ->(x) { x['offline_values'].delete('mapped') },
      'offline typed cardinality' => ->(x) { x['offline_values']['seq'] = 7 },
      'budget string bytes' => ->(x) { x['offline_budgets']['side']['string_bytes'] = 63 },
      'budget tuple cells' => ->(x) { x['offline_budgets']['seq']['tuple_cells'] = 14 },
      'budget one-less guard' => ->(x) { x['offline_budgets']['mapped']['one_less_tuple_rejected'] = false },
      'assertion roster' => ->(x) { x['assertions'].delete('eof') },
      'helper report missing field' => ->(x) { x.delete('offline_values') },
    }
    report_mutations.each do |name, mutate|
      candidate = json_clone(report)
      mutate.call(candidate)
      begin
        validate_green_report!(candidate)
        raise AuditFailure, "self-test failed to reject #{name}"
      rescue AuditFailure => error
        raise if error.message == "self-test failed to reject #{name}"
        controls << name
      end
    end

    binding = {
      'schema' => Runner::SCHEMA,
      'selected_columns_without_pk' => Runner::SELECTED_COLUMNS,
      'independent_rows' => hash_rows(Runner::ROWS),
      'mark_grid' => { 'data_mark_rows' => Runner::MARK_ROWS, 'rows_with_terminal' => Runner::MARK_ROWS_WITH_EOF },
    }
    validate_fixture_binding!(binding)
    binding_mutations = {
      'missing typed schema' => ->(x) { x['schema'].pop },
      'wrong stock type' => ->(x) { x['schema'][1][1] = 'String' },
      'schema column order' => ->(x) { x['schema'].reverse! },
      'selected typed value missing' => ->(x) { x['selected_columns_without_pk'].delete('mapped') },
      'independent row literal' => ->(x) { x['independent_rows'][0]['u'] = 0 },
      'terminal mark schedule' => ->(x) { x['mark_grid']['rows_with_terminal'].pop },
    }
    binding_mutations.each do |name, mutate|
      candidate = json_clone(binding)
      mutate.call(candidate)
      begin
        validate_fixture_binding!(candidate)
        raise AuditFailure, "self-test failed to reject #{name}"
      rescue AuditFailure => error
        raise if error.message == "self-test failed to reject #{name}"
        controls << name
      end
    end

    source_paths = %w[runner.rb helper.cr fixture.cr]
    source_hashes = source_paths.to_h { |path| [path, 'd' * 64] }
    provenance = synthetic_provenance(source_paths, source_hashes)
    validate_helper_provenance!(provenance, 'c' * 64, source_hashes, source_paths)
    provenance_mutations = {
      'missing helper provenance' => ->(x, _actual) { x.clear },
      'helper mode' => ->(x, _actual) { x['mode'] = 'baseline' },
      'helper binary before/after' => ->(x, _actual) { x['sha256_after'] = 'e' * 64 },
      'missing source file' => ->(x, _actual) { x['source_files_before'].pop },
      'source order' => ->(x, _actual) { x['source_files_after'].reverse! },
      'source hash changed' => ->(x, _actual) { x['source_files_after'][0]['sha256'] = 'f' * 64 },
      'actual source bytes differ' => ->(_x, actual) { actual['fixture.cr'] = '0' * 64 },
    }
    provenance_mutations.each do |name, mutate|
      candidate = json_clone(provenance)
      actual = source_hashes.dup
      mutate.call(candidate, actual)
      candidate = nil if name == 'missing helper provenance'
      begin
        validate_helper_provenance!(candidate, 'c' * 64, actual, source_paths)
        raise AuditFailure, "self-test failed to reject #{name}"
      rescue AuditFailure => error
        raise if error.message == "self-test failed to reject #{name}"
        controls << name
      end
    end

    native_part = { name: Runner::PART_NAME, part_type: 'Wide', rows: '8', marks: '5' }
    part_files = synthetic_part_files
    inventory = synthetic_inventory(part_files, native_part)
    validate_part_inventory!(inventory, part_files, native_part)
    inventory_mutations = {
      'manifest omits stock file' => lambda do |x, files|
        x['files'].pop
      end,
      'manifest file digest' => lambda do |x, _files|
        x['files'][0]['sha256'] = '0' * 64
      end,
      'part count metadata' => lambda do |x, _files|
        x['count_text'] = '7'
      end,
      'serialization metadata bytes' => lambda do |x, files|
        files['serialization.json'] = files['serialization.json'].sub('"version": 1', '"version": 2')
        x.replace(synthetic_inventory(files, native_part))
      end,
      'logical roster differs from admitted schema' => lambda do |x, files|
        files['columns_substreams.txt'] = files['columns_substreams.txt'].sub('column `mapped`', 'column `other`')
        x.replace(synthetic_inventory(files, native_part))
      end,
      'escaped stream identity is not canonical' => lambda do |x, files|
        files['columns_substreams.txt'] = files['columns_substreams.txt'].sub('seq%2Edetails%2Escore', 'seq.details.score')
        x.replace(synthetic_inventory(files, native_part))
      end,
      'escaped stream identity uses a false prefix' => lambda do |x, files|
        files['columns_substreams.txt'] = files['columns_substreams.txt'].sub('mapped%2Evalues%2Emeta%2Eid', 'mapped.values.meta.id')
        x.replace(synthetic_inventory(files, native_part))
      end,
      'mrk2 terminal grid' => lambda do |x, files|
        mark = "#{Runner::KEY_HASH}.mrk2"
        triples = files.fetch(mark).unpack('Q<*').each_slice(3).map(&:dup)
        triples[-1][2] = 1
        files[mark] = triples.flatten.pack('Q<*')
        x.replace(synthetic_inventory(files, native_part))
      end,
      'nested stream mrk2 row grid' => lambda do |x, files|
        mark = files.keys.select { |path| path.end_with?('.mrk2') && path != "#{Runner::KEY_HASH}.mrk2" }.sort.fetch(0)
        triples = files.fetch(mark).unpack('Q<*').each_slice(3).map(&:dup)
        triples[1][2] = 1
        files[mark] = triples.flatten.pack('Q<*')
        x.replace(synthetic_inventory(files, native_part))
      end,
      'mark file count' => lambda do |x, _files|
        x['plain_mark_file_count'] = 2
      end,
      'part geometry' => lambda do |x, _files|
        x['marks'] = '4'
      end,
    }
    inventory_mutations.each do |name, mutate|
      candidate = json_clone(inventory)
      files = part_files.transform_values(&:dup)
      mutate.call(candidate, files)
      begin
        validate_part_inventory!(candidate, files, native_part)
        raise AuditFailure, "self-test failed to reject #{name}"
      rescue AuditFailure => error
        raise if error.message == "self-test failed to reject #{name}"
        controls << name
      end
    end

    need!(controls.size >= 55, "self-test covered only #{controls.size} negative controls")
    { 'status' => 'self_test_passed', 'negative_controls_rejected' => controls.size, 'controls' => controls }
  ensure
    @self_test_bytes = nil
  end
end

def main
  options = { peer_root: nil, self_test: false }
  parser = OptionParser.new do |opts|
    opts.banner = 'Usage: ruby scripts/audit_wide_ragged_selected_metadata_w261.rb SUMMARY.json|EVIDENCE_ROOT [--peer-root DEBUG_OR_RELEASE_ROOT]'
    opts.on('--peer-root PATH', 'Independently audit a paired DEBUG/RELEASE GREEN evidence root') { |value| options[:peer_root] = value }
    opts.on('--self-test', 'Exercise in-memory audit falsifiers without reading or writing capture files') { options[:self_test] = true }
  end
  parser.parse!
  if options[:self_test]
    raise AuditWideRaggedSelectedMetadataW261::AuditFailure, '--self-test takes no capture input or peer root' unless ARGV.empty? && options[:peer_root].nil?
    result = AuditWideRaggedSelectedMetadataW261.self_test!
  else
    raise AuditWideRaggedSelectedMetadataW261::AuditFailure, 'one GREEN summary.json or evidence root is required' unless ARGV.size == 1
    result = AuditWideRaggedSelectedMetadataW261.audit(ARGV.fetch(0), peer_root: options[:peer_root])
  end
  puts JSON.pretty_generate(result)
rescue StandardError => error
  warn "W261 audit rejected capture: #{error.class}: #{error.message}"
  exit 1
end

main if $PROGRAM_NAME == __FILE__
