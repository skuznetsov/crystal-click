#!/usr/bin/env ruby
# Offline evidence authentication for the finite W241 paired shared-JSON run.
# This file contains no process execution and does not promote summary fields
# without checking the referenced invocation and part artifacts.

require 'digest'
require 'find'
require 'json'
require_relative 'check_array_json_parts_w185'
require_relative 'check_object_shared_buckets_w190'
require_relative 'probe_object_shared_advanced_w191'
require_relative 'object_shared_advanced_layout_w191'

module ReconcileObjectSharedJSONInteropW241
  extend self

  W185 = CheckArrayJSONPartsW185
  W191 = ObjectSharedAdvancedLayoutW191
  W190_PROBE = CheckObjectSharedBucketsW190::Probe
  FORMAT = 'object_shared_json_interop_w241_evidence_v1'.freeze
  CAPTURE_FORMAT = 'object_shared_json_interop_w241_capture_v2'.freeze
  INPUT_FORMAT = 'object_shared_json_interop_w241_input_v2'.freeze
  HELPER_FORMAT = 'object_shared_json_interop_w241_helper_v2'.freeze
  W240_COLUMNS_TEXT = "columns format version: 1\n2 columns:\n`pk` UInt8\n`doc` JSON(max_dynamic_paths=0)\n".freeze
  W241_COLUMNS_TEXT = "columns format version: 1\n2 columns:\n`pk` UInt64\n`doc` JSON(max_dynamic_paths=0)\n".freeze
  FRAME_BYTES_OPTIONS = [32, 64].freeze
  W240_ROOT = '/private/tmp/crystal-click-w240-stock-rerun.T9COXO'.freeze
  W240_SUMMARY_SHA256 = '8b0375c94007d123170362a647dc8b95578fc54daf8f66bac2f0ad047c24cf70'.freeze
  SOURCE_RUNTIME = {
    'version' => '26.10.1.1201',
    'build' => 'd9bcb5ab007f0f6299f7f973f2642245bab3d028',
    'sha256' => 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2',
  }.freeze
  STOCK_TYPE = 'JSON(max_dynamic_paths=0)'.freeze
  LAYOUTS = [
    {id: 'map', enum: 0, setting: 'map'},
    {id: 'map_with_buckets', enum: 1, setting: 'map_with_buckets'},
    {id: 'advanced', enum: 2, setting: 'advanced'},
    {id: 'advanced_chunked', enum: 3, setting: 'advanced_chunked'},
  ].map(&:freeze).freeze
  STRING_PROFILES = [
    {id: 's0', setting: 'single_stream', version: 0},
    {id: 's1', setting: 'with_size_stream', version: 1},
  ].map(&:freeze).freeze
  PROFILE_IDS = LAYOUTS.flat_map do |layout|
    STRING_PROFILES.map { |string| "#{layout.fetch(:id)}_#{string.fetch(:id)}" }
  end.freeze
  ROWS = [
    {pk: 1, doc: {'arr' => [{'v' => 1, 's' => 'one'}, {'v' => 2, 's' => 'two'}], 'mixed' => 1, 'label' => 'one'}},
    {pk: 2, doc: {'arr' => [{'v' => 3, 's' => 'three'}], 'mixed' => 'two', 'label' => 2}},
    {pk: 3, doc: {'arr' => [], 'mixed' => true, 'label' => 'three'}},
    {pk: 4, doc: {}},
    {pk: 5, doc: {'arr' => [{'v' => 5, 's' => 'five'}], 'mixed' => 2, 'label' => 5}},
    {pk: 6, doc: {'arr' => [], 'mixed' => 'six', 'label' => 'six'}},
    {pk: 7, doc: {'arr' => [{'v' => 7, 's' => 'seven'}], 'mixed' => false, 'label' => 7}},
    {pk: 8, doc: {'arr' => [{'v' => 8, 's' => 'eight'}], 'mixed' => 3, 'label' => 'last',
                  'late' => [{'v' => 80, 'late_only_child' => 'last-chunk-only'}]}},
  ].map(&:freeze).freeze
  REAL_MARK_ROWS = [2, 2, 2, 2].freeze
  PHYSICAL_MARK_ROWS = [2, 2, 2, 2, 0].freeze
  NEGATIVE_PROFILE_IDS = %w[
    advanced_chunked_s0_negative_data_corrupt
    advanced_chunked_s0_negative_copy_truncated
  ].freeze
  NEGATIVE_PART_SUMMARY_FIELDS = %w[
    complete_file_inventory logical_substreams object_substreams path physical_file_names
    raw_shared_streams source_kind
  ].sort.freeze
  NEGATIVE_PART_REOPENED_FIELDS = (NEGATIVE_PART_SUMMARY_FIELDS + %w[columns_substreams_text physical_layout])
    .sort.freeze
  NEGATIVE_DIRECT_RAW_ROW_FIELDS = %i[
    arr arr_type late late_type mixed mixed_type arr_wrapper_type mixed_wrapper_type late_wrapper_type
  ].sort_by(&:to_s).freeze
  NEGATIVE_DIRECT_SUMMARY_ROW_FIELDS = %w[arr arr_type late late_type mixed mixed_type].sort.freeze
  NEGATIVE_DIRECT_RAW_FIELDS = %i[rows_by_pk].freeze
  NEGATIVE_FULL_RAW_FIELDS = %i[bounded_docs_by_tag full_docs_by_pk zero_selection].sort_by(&:to_s).freeze
  NEGATIVE_FULL_SUMMARY_FIELDS = %w[full_docs_by_pk].freeze
  ATTACHED_NATIVE_EXTRA_FILE = 'invalidated_system_columns.txt'.freeze
  ATTACHED_NATIVE_EXTRA_BYTES = ['5f626c6f636b5f6f66667365740a5f626c6f636b5f6e756d6265720a'].pack('H*').freeze
  TARGET_CREATE_BASE_SETTINGS = {
    'index_granularity' => '2',
    'index_granularity_bytes' => '10485760',
    'enable_mixed_granularity_parts' => '1',
    'min_rows_for_wide_part' => '0',
    'min_bytes_for_wide_part' => '0',
    'compress_marks' => '0',
    'compress_primary_key' => '0',
    'min_compress_block_size' => '0',
    'max_compress_block_size' => '4096',
    'ratio_of_defaults_for_sparse_serialization' => '1',
    'default_compression_codec' => "'LZ4'",
    'serialization_info_version' => "'with_types'",
    'dynamic_serialization_version' => "'v3'",
    'object_serialization_version' => "'v3'",
    'propagate_types_serialization_versions_to_nested_types' => 'true',
    'object_shared_data_buckets_for_wide_part' => '2',
  }.freeze
  W240_LAYOUT_STREAMS = {
    'map' => %w[
      pk doc.object_structure doc.object_shared_data.size0
      doc.object_shared_data%2Epaths doc.object_shared_data%2Evalues
    ],
    'map_with_buckets' => %w[
      pk doc.object_structure
      doc.object_shared_data.0.size0 doc.object_shared_data.0%2Epaths doc.object_shared_data.0%2Evalues
      doc.object_shared_data.1.size0 doc.object_shared_data.1%2Epaths doc.object_shared_data.1%2Evalues
    ],
    'advanced' => %w[
      pk doc.object_structure
      doc.object_shared_data.0.structure doc.object_shared_data.0.data
      doc.object_shared_data.0.paths_marks doc.object_shared_data.0.substreams
      doc.object_shared_data.0.substreams_marks doc.object_shared_data.0.paths_substreams_metadata
      doc.object_shared_data.1.structure doc.object_shared_data.1.data
      doc.object_shared_data.1.paths_marks doc.object_shared_data.1.substreams
      doc.object_shared_data.1.substreams_marks doc.object_shared_data.1.paths_substreams_metadata
      doc.object_shared_data.copy.sizes doc.object_shared_data.copy.paths_indexes
      doc.object_shared_data.copy.values
    ],
    'advanced_chunked' => %w[
      pk doc.object_structure
      doc.object_shared_data.0.structure doc.object_shared_data.0.data
      doc.object_shared_data.0.paths_marks doc.object_shared_data.0.substreams
      doc.object_shared_data.0.substreams_marks doc.object_shared_data.0.paths_substreams_metadata
      doc.object_shared_data.1.structure doc.object_shared_data.1.data
      doc.object_shared_data.1.paths_marks doc.object_shared_data.1.substreams
      doc.object_shared_data.1.substreams_marks doc.object_shared_data.1.paths_substreams_metadata
      doc.object_shared_data.copy.sizes doc.object_shared_data.copy.paths_indexes
      doc.object_shared_data.copy.values
    ],
  }.freeze
  MAX_SUMMARY_BYTES = 16 * 1024 * 1024
  MAX_PART_FILE_BYTES = 16 * 1024 * 1024
  MAX_PART_TOTAL_BYTES = 64 * 1024 * 1024
  MAX_PART_FILES = 4096
  # Source-literal Compact outer callback tape from
  # SerializationObjectSharedData.cpp:762-839 and :842-885, plus the role
  # names enumerated by :162-182 and :199-201. These are callback suffixes,
  # not inferred from the helper's lane plan.
  NESTED_ADVANCED_INLINE_CALLBACK_SUFFIXES = %w[
    object_shared_data.0.structure_prefix
    object_shared_data.0.data
    object_shared_data.0.paths_marks
    object_shared_data.0.substreams
    object_shared_data.0.substreams_marks
    object_shared_data.0.paths_substreams_metadata
    object_shared_data.0.structure_suffix
    object_shared_data.1.structure_prefix
    object_shared_data.1.data
    object_shared_data.1.paths_marks
    object_shared_data.1.substreams
    object_shared_data.1.substreams_marks
    object_shared_data.1.paths_substreams_metadata
    object_shared_data.1.structure_suffix
    object_shared_data.copy.sizes
    object_shared_data.copy.paths_indexes
    object_shared_data.copy.values
  ].freeze

  class AuditError < StandardError; end

  def require!(condition, message)
    raise AuditError, message unless condition
  end

  def sha256(bytes)
    Digest::SHA256.hexdigest(bytes)
  end

  def read_plain(path, limit, label)
    require!(File.file?(path) && !File.symlink?(path), "#{label} is absent, non-regular, or symlinked")
    size = File.size(path)
    require!(size <= limit, "#{label} exceeds #{limit} bytes")
    bytes = File.binread(path)
    require!(bytes.bytesize == size, "#{label} changed while reading")
    bytes
  end

  def canonical_root(path, label)
    require!(path.is_a?(String) && !path.empty?, "#{label} is absent")
    require!(!File.symlink?(path), "#{label} is symlinked")
    full = File.realpath(path)
    require!(File.directory?(full) && File.expand_path(path) == full, "#{label} is not a canonical directory")
    full
  rescue SystemCallError => error
    raise AuditError, "#{label} cannot be resolved: #{error.message}"
  end

  def canonical_child(path, root, label)
    base = canonical_root(root, "#{label} root")
    require!(path.is_a?(String) && !path.empty?, "#{label} path is absent")
    expanded = File.expand_path(path)
    require!(expanded.start_with?(base + File::SEPARATOR), "#{label} escaped its evidence root")
    current = base
    expanded.delete_prefix(base + File::SEPARATOR).split(File::SEPARATOR).each do |part|
      current = File.join(current, part)
      next unless File.exist?(current) || File.symlink?(current)
      require!(!File.lstat(current).symlink?, "symlink in #{label}: #{current}")
      require!(File.directory?(current), "non-directory in #{label}: #{current}") if current != expanded
    end
    full = File.realpath(expanded)
    require!(full == expanded && File.directory?(full), "#{label} is not a canonical directory")
    full
  rescue SystemCallError => error
    raise AuditError, "#{label} cannot be resolved: #{error.message}"
  end

  def plain_tree!(root, label)
    total = 0
    count = 0
    Find.find(root) do |entry|
      stat = File.lstat(entry)
      require!(!stat.symlink?, "symlink in #{label}: #{entry}")
      require!(stat.directory? || stat.file?, "special file in #{label}: #{entry}")
      next unless stat.file?
      count += 1
      total += stat.size
      require!(count <= MAX_PART_FILES, "#{label} exceeds the file-count bound")
      require!(stat.size <= MAX_PART_FILE_BYTES, "#{label} has an oversized file: #{entry}")
      require!(total <= MAX_PART_TOTAL_BYTES, "#{label} exceeds the total-size bound")
    end
    {files: count, bytes: total}
  end

  # Independently authenticate the W240 s1 parts before they can be supplied
  # to the W241 Crystal reader. The pinned summary is an index only: all
  # invocation files, part files, metadata bytes, and mark grids are reopened.
  def authenticate_w240!(root = W240_ROOT, expected_summary_sha = W240_SUMMARY_SHA256)
    root = canonical_root(root, 'W240 source root')
    require!(root == W240_ROOT, 'W240 source root differs from the pinned capture')
    summary_path = File.join(root, 'summary.json')
    summary_bytes = read_plain(summary_path, MAX_SUMMARY_BYTES, 'W240 summary')
    observed_summary_sha = sha256(summary_bytes)
    require!(observed_summary_sha == expected_summary_sha, 'W240 summary SHA-256 differs from the authenticated capture')
    summary = JSON.parse(summary_bytes)
    require!(summary.is_a?(Hash) && summary['probe'] == 'W240 stock-only JSON-bearing inline shared Object qualification' &&
             summary['status'] == 'all_stock_profiles_observed' && summary['fatal_error'].nil?,
      'W240 summary is not a complete successful stock-only capture')
    runtime = summary.fetch('runtime')
    require!(runtime['expected_version'] == SOURCE_RUNTIME.fetch('version') &&
             runtime['expected_build'] == SOURCE_RUNTIME.fetch('build') &&
             runtime['expected_sha256'] == SOURCE_RUNTIME.fetch('sha256') &&
             runtime['sha256_before'] == SOURCE_RUNTIME.fetch('sha256') &&
             runtime['sha256_after'] == SOURCE_RUNTIME.fetch('sha256'),
      'W240 runtime identity differs from the pinned runtime')
    require!(summary['type'] == STOCK_TYPE, 'W240 stock schema differs')
    profiles = summary.fetch('profiles')
    require!(profiles.is_a?(Array) && profiles.map { |item| item['id'] } == LAYOUTS.map { |item| item.fetch(:id) },
      'W240 profile order differs from the four physical layouts')
    result = {}
    profiles.each do |profile|
      id = profile.fetch('id')
      layout = LAYOUTS.find { |entry| entry.fetch(:id) == id } || raise(AuditError, "unrostered W240 profile #{id.inspect}")
      require!(profile['enum_value'] == layout.fetch(:enum) && profile['status'] == 'stock_profile_observed',
        "W240 #{id} profile status or enum differs")
      stages = profile.fetch('stages')
      %w[write direct full].each do |stage|
        record = stages.fetch(stage)
        require!(record['status'] == 'stage_observed', "W240 #{id}/#{stage} was not observed")
        authenticate_invocation!(root, record.fetch('invocation'), "W240 #{id}/#{stage}")
      end
      write = stages.fetch('write').fetch('observations')
      inventory = write.fetch('part_inventory')
      part_path = canonical_child(inventory.fetch('part_path'), File.join(root, 'stores', 'native'), "W240 #{id} part")
      physical = authenticate_part!(part_path, inventory, layout)
      authenticate_w240_queries!(root, id, stages)
      result[id] = {part_path: part_path, part_inventory: inventory, physical_layout: physical,
                    source_stage_records: stages}
    end
    {root: root, summary_sha256: observed_summary_sha, runtime: runtime, profiles: result}
  rescue KeyError, JSON::ParserError => error
    raise AuditError, "W240 source evidence is malformed: #{error.message}"
  end

  # W185 writes the invocation JSON inside execute_record, then W240's
  # run_clickhouse adds binary_sha_before to the returned in-memory record.
  # The summary is therefore allowed exactly this one pinned summary-only
  # field; every artifact key and value must otherwise match.
  def authenticate_w240_invocation_record_artifact!(record, artifact_record, label)
    require!(record.is_a?(Hash) && artifact_record.is_a?(Hash),
      "#{label} invocation record artifact is malformed")
    require!(record.key?('binary_sha_before') &&
             record['binary_sha_before'] == SOURCE_RUNTIME.fetch('sha256'),
      "#{label} summary-only pre-invocation SHA differs from the pinned runtime")
    base_record = record.reject { |key, _value| key == 'binary_sha_before' }
    require!(artifact_record.keys.sort == base_record.keys.sort,
      "#{label} invocation artifact has missing or extra fields beyond the permitted pre-invocation SHA")
    require!(artifact_record == base_record,
      "#{label} invocation record artifact differs beyond the permitted pre-invocation SHA")
    true
  end

  def authenticate_invocation!(root, record, label)
    require!(record.is_a?(Hash), "#{label} invocation record is malformed")
    require!(record['process_classification'] == 'success' && record['exit'] == 0 && record['signal'].nil? &&
             record['timed_out'] == false && record['max_threads'] == 1 &&
             record['max_memory_usage_bytes'] == W185::MEMORY &&
             record['max_memory_usage_applicable'] == true &&
             record['expected_binary_sha256'] == SOURCE_RUNTIME.fetch('sha256') &&
             record['binary_sha_after'] == SOURCE_RUNTIME.fetch('sha256') &&
             record['spawn_error'].nil? && record['stdin_write_error'].nil? &&
             record['stdout_read_error'].nil? && record['stderr_read_error'].nil?,
      "#{label} process was not a bounded successful pinned native invocation")
    argv = record.fetch('argv')
    require!(argv.is_a?(Array) && argv.size == 8 && argv[1] == 'local' && argv[3] == File.join(root, 'stores', 'native') &&
             argv.include?('--max_threads=1') && argv.include?("--max_memory_usage=#{W185::MEMORY}") &&
             argv.include?('--multiquery'), "#{label} argv differs from isolated bounded clickhouse-local")
    names = {
      'stdout' => record.fetch('stdout_file'), 'stderr' => record.fetch('stderr_file'),
      'stdin' => record.fetch('stdin_file'),
    }
    names['argv'] = record.fetch('argv_file') if record.key?('argv_file')
    names.each do |kind, name|
      require!(name.is_a?(String) && File.basename(name) == name && name.match?(/\A[a-zA-Z0-9_.-]+\z/),
        "#{label} #{kind} artifact basename is unsafe")
    end
    stem = record.fetch('stdout_file').sub(/\.stdout\z/, '')
    require!(record.fetch('stdout_file') == "#{stem}.stdout" && record.fetch('stderr_file') == "#{stem}.stderr" &&
             record.fetch('stdin_file') == "#{stem}.stdin.sql", "#{label} artifact stems disagree")
    argv_name = record.fetch('argv_file', "#{stem}.argv.json")
    require!(argv_name == "#{stem}.argv.json", "#{label} argv artifact stem differs")
    invocation_dir = File.join(root, 'invocations')
    files = {
      'argv' => [argv_name, record.fetch('argv_sha256'), nil],
      'stdout' => [record.fetch('stdout_file'), record.fetch('stdout_sha256'), record.fetch('stdout_bytes')],
      'stderr' => [record.fetch('stderr_file'), record.fetch('stderr_sha256'), record.fetch('stderr_bytes')],
      'stdin' => [record.fetch('stdin_file'), record.fetch('stdin_sha256'), record.fetch('stdin_bytes')],
    }
    argv_bytes = read_plain(File.join(invocation_dir, files.fetch('argv')[0]), 1024 * 1024, "#{label} argv artifact")
    require!(sha256(argv_bytes) == record.fetch('argv_sha256'), "#{label} raw argv SHA-256 differs")
    actual_argv = JSON.parse(argv_bytes)
    require!(actual_argv == argv, "#{label} argv artifact differs")
    artifact_record = JSON.parse(read_plain(File.join(invocation_dir, "#{stem}.json"), 1024 * 1024,
      "#{label} invocation record artifact"))
    authenticate_w240_invocation_record_artifact!(record, artifact_record, label)
    files.each do |kind, (name, expected_sha, expected_size)|
      next if kind == 'argv'
      bytes = read_plain(File.join(invocation_dir, name), 16 * 1024 * 1024, "#{label} #{kind} artifact")
      require!(sha256(bytes) == expected_sha && bytes.bytesize == expected_size, "#{label} #{kind} artifact digest/size differs")
    end
    sql = read_plain(File.join(invocation_dir, record.fetch('stdin_file')), 1024 * 1024, "#{label} SQL")
    stdout = read_plain(File.join(invocation_dir, record.fetch('stdout_file')), 16 * 1024 * 1024, "#{label} stdout")
    require!(sql.include?('output_format_json_quote_64bit_integers=0'), "#{label} SQL did not pin integer rendering")
    audit_native_runtime_pin!(stdout, '__W240_PIN__', label)
    stderr = read_plain(File.join(invocation_dir, record.fetch('stderr_file')), 16 * 1024 * 1024, "#{label} stderr")
    require!(stderr.empty?, "#{label} wrote stderr")
    {sql: sql.force_encoding(Encoding::UTF_8), stdout: stdout.force_encoding(Encoding::UTF_8)}
  rescue KeyError, JSON::ParserError => error
    raise AuditError, "#{label} invocation artifacts are malformed: #{error.message}"
  end

  def authenticate_part!(path, inventory, layout)
    tree = plain_tree!(path, "W240 #{layout.fetch(:id)} part")
    names = Dir.children(path).sort
    require!(inventory.fetch('physical_file_names') == names, "W240 #{layout.fetch(:id)} physical file roster differs")
    require!(inventory.fetch('plain_mrk2_only') == true, "W240 #{layout.fetch(:id)} mark format differs")
    serialization = read_plain(File.join(path, 'serialization.json'), MAX_PART_FILE_BYTES, 'W240 serialization.json')
    require!(sha256(serialization) == inventory.fetch('serialization_json_sha256'),
      "W240 #{layout.fetch(:id)} serialization.json digest differs")
    parsed_serialization = JSON.parse(serialization)
    require!(parsed_serialization == inventory.fetch('serialization_json') &&
             parsed_serialization['version'] == 1 &&
             parsed_serialization['propagate_types_serialization_versions_to_nested_types'] == true &&
             parsed_serialization.dig('types_serialization_versions', 'string') == 1 &&
             inventory.fetch('ordinary_string_serialization_version') == 1,
      "W240 #{layout.fetch(:id)} serialized String version differs from s1")
    substreams = read_plain(File.join(path, 'columns_substreams.txt'), MAX_PART_FILE_BYTES,
      'W240 columns_substreams.txt').force_encoding(Encoding::UTF_8)
    require!(substreams == inventory.fetch('columns_substreams_text'),
      "W240 #{layout.fetch(:id)} columns_substreams.txt differs from retained bytes")
    roster = parse_columns_substreams_roster!(substreams, layout.fetch(:id), "W240 #{layout.fetch(:id)}")
    logical = roster.fetch(:logical_substreams)
    object_substreams = roster.fetch(:object_substreams)
    assert_physical_stream_file_roster!(names, logical, "W240 #{layout.fetch(:id)}")
    require!(logical == inventory.fetch('logical_substreams'), "W240 #{layout.fetch(:id)} logical stream roster differs")
    if inventory.key?('object_substreams')
      require!(object_substreams == inventory.fetch('object_substreams'),
        "W240 #{layout.fetch(:id)} Object stream roster differs")
    end
    require!(inventory.fetch('mark_triples').is_a?(Hash) &&
             inventory.fetch('mark_triples').keys.sort == logical.sort,
      "W240 #{layout.fetch(:id)} mark triple roster differs")
    checksums = read_plain(File.join(path, 'checksums.txt'), MAX_PART_FILE_BYTES, 'W240 checksums.txt')
    require!(checksums.bytesize == inventory.fetch('checksums_bytes') &&
             sha256(checksums) == inventory.fetch('checksums_sha256'),
      "W240 #{layout.fetch(:id)} checksums artifact differs")
    stream_inventory = inventory.fetch('stream_file_inventory')
    expected_stream_files = stream_inventory.keys.sort
    require!(inventory.fetch('hashed_stream_files') == expected_stream_files, "W240 #{layout.fetch(:id)} hashed stream list differs")
    columns_text = read_plain(File.join(path, 'columns.txt'), MAX_PART_FILE_BYTES, 'W240 columns.txt')
    require!(columns_text == W240_COLUMNS_TEXT, "W240 #{layout.fetch(:id)} columns.txt schema differs")
    expected_stream_files.each do |name|
      require!(name.match?(/\A[0-9a-f]{32}\.(?:bin|mrk2)\z/), "W240 #{layout.fetch(:id)} stream filename is malformed")
      bytes = read_plain(File.join(path, name), MAX_PART_FILE_BYTES, "W240 stream #{name}")
      retained = stream_inventory.fetch(name)
      require!(bytes.bytesize == retained.fetch('size') && sha256(bytes) == retained.fetch('sha256'),
        "W240 #{layout.fetch(:id)} stream #{name} digest differs")
    end
    mark_triples = {}
    logical.each do |stream|
      stream_stem = stream_hash(stream)
      mark_path = File.join(path, "#{stream_stem}.mrk2")
      bytes = read_plain(mark_path, MAX_PART_FILE_BYTES, "W240 mark #{stream}")
      words = bytes.unpack('Q<*')
      require!((words.size % 3).zero?, "W240 mark #{stream} has incomplete triples")
      triples = words.each_slice(3).map(&:dup)
      require!(triples == inventory.fetch('mark_triples').fetch(stream), "W240 mark #{stream} differs from retained triples")
      require!(triples.size == 5 && triples.map { |triple| triple[2] } == [2, 2, 2, 2, 0],
        "W240 mark #{stream} differs from the four-mark fixture")
      mark_triples[stream] = triples
    end
    {logical_substreams: logical, object_substreams: object_substreams, serialization: parsed_serialization,
     ordinary_string_serialization_version: 1, mark_triples: mark_triples,
     physical_file_names: names, bytes: tree.fetch(:bytes)}
  rescue KeyError, JSON::ParserError => error
    raise AuditError, "W240 #{layout.fetch(:id)} part inventory is malformed: #{error.message}"
  end

  def stream_hash(logical_name)
    require!(defined?(JsonArrayStorageW183), 'W185 stream-name hash helper is unavailable')
    JsonArrayStorageW183.stream_hash(logical_name)
  end

  # Parse the part metadata independently of either helper inventory. The
  # table-wide order is retained here; ObjectColumnReader deliberately reports
  # only the doc-owned streams, in sorted order.
  def parse_columns_substreams_roster!(text, layout_id, label)
    require!(text.is_a?(String) && text.valid_encoding?, "#{label} columns_substreams is not valid text")
    lines = text.split("\n", -1)
    require!(lines.pop == '', "#{label} columns_substreams lacks its final newline")
    require!(lines.shift == 'columns substreams version: 1', "#{label} columns_substreams version differs")
    require!(lines.shift == '2 columns:', "#{label} columns_substreams column count differs")

    sections = []
    until lines.empty?
      header = lines.shift
      match = /\A(0|[1-9][0-9]*) substreams for column `([a-z][a-z0-9_]*)`:\z/.match(header)
      require!(!match.nil?, "#{label} has a malformed column substream section")
      count = Integer(match[1], 10)
      require!(count <= 64 && lines.size >= count, "#{label} substream section exceeds bounded metadata")
      names = Array.new(count) do
        entry = /\A\t([A-Za-z0-9_.%]+)\z/.match(lines.shift)
        require!(!entry.nil?, "#{label} has a malformed logical substream name")
        entry[1]
      end
      sections << [match[2], names]
      require!(sections.size <= 2, "#{label} has an unexpected extra column section")
    end

    require!(sections.map(&:first) == %w[pk doc], "#{label} metadata column roles/order differ")
    table_streams = sections.flat_map(&:last)
    object_streams = sections.fetch(1).fetch(1)
    require!(sections.fetch(0).fetch(1) == ['pk'], "#{label} pk column must own exactly the pk stream")
    require!(table_streams.uniq == table_streams, "#{label} has duplicate or cross-column aliased substreams")

    expected_object_streams = W240_LAYOUT_STREAMS.fetch(layout_id).reject { |name| name == 'pk' }
    require!(expected_object_streams.uniq == expected_object_streams,
      "#{label} pinned Object roster contains duplicate roles")
    require!(object_streams.uniq == object_streams && object_streams.sort == expected_object_streams.sort,
      "#{label} Object substream roles/count differ for #{layout_id}")
    physical_stems = table_streams.map { |name| stream_hash(name) }
    require!(physical_stems.uniq == physical_stems, "#{label} logical streams alias a physical stream stem")
    {logical_substreams: table_streams, object_substreams: object_streams}
  rescue KeyError, ArgumentError => error
    raise AuditError, "#{label} columns_substreams roster is malformed: #{error.message}"
  end

  def audit_helper_stream_roster!(read, layout_id, label)
    roster = parse_columns_substreams_roster!(read.fetch('columns_substreams_text'), layout_id, label)
    object_sorted = roster.fetch(:object_substreams).sort
    physical_names = read.fetch('physical_stream_names')
    require!(physical_names.is_a?(Array) && physical_names.all? { |name| name.is_a?(String) } &&
             physical_names == object_sorted,
      "#{label} helper physical_stream_names is not the sorted doc-only roster")
    marks = read.fetch('mark_triples')
    require!(marks.is_a?(Hash) && marks.keys.all? { |name| name.is_a?(String) } && marks.keys.sort == object_sorted,
      "#{label} helper mark_triples keys differ from the sorted doc-only roster")
    raw = read.fetch('raw_shared_streams')
    require!(raw.is_a?(Hash) && raw.keys.all? { |name| name.is_a?(String) } && raw.keys.sort == object_sorted,
      "#{label} helper raw_shared_streams keys differ from the sorted doc-only roster")
    roster
  rescue KeyError => error
    raise AuditError, "#{label} helper stream roster is malformed: #{error.message}"
  end

  def expected_helper_columns_text(read, layout_id, label)
    require!(LAYOUTS.any? { |layout| layout.fetch(:id) == layout_id }, "#{label} has an unknown layout")
    string_profile = STRING_PROFILES.find { |entry| entry.fetch(:version) == read.fetch('ordinary_string_profile') }
    require!(!string_profile.nil?, "#{label} has an unknown String profile")
    expected = case read.fetch('role')
               when 'stock_source'
                 string_profile.fetch(:version) == 1 ? W240_COLUMNS_TEXT : W241_COLUMNS_TEXT
               when 'crystal_generated'
                 W241_COLUMNS_TEXT
               else
                 raise AuditError, "#{label} has an unknown helper read role"
               end
    require!(read.fetch('columns_text') == expected, "#{label} columns.txt schema differs for role/profile")
    expected
  rescue KeyError => error
    raise AuditError, "#{label} column schema evidence is malformed: #{error.message}"
  end

  def audit_helper_columns_schema!(read, layout_id, label, check_part: false)
    expected = expected_helper_columns_text(read, layout_id, label)
    return expected unless check_part

    part_path = read.fetch('part_path')
    require!(File.directory?(part_path) && !File.symlink?(part_path) && File.realpath(part_path) == part_path,
      "#{label} part path is noncanonical for schema check")
    actual = read_plain(File.join(part_path, 'columns.txt'), MAX_PART_FILE_BYTES, "#{label} columns.txt")
    require!(actual == expected, "#{label} actual columns.txt bytes differ from role/profile schema")
    expected
  rescue KeyError => error
    raise AuditError, "#{label} column schema evidence is malformed: #{error.message}"
  end

  def expected_w241_part_columns_text(profile_id, role, label)
    require!(PROFILE_IDS.include?(profile_id), "#{label} has an unknown W241 profile")
    case role
    when 'source'
      profile_id.end_with?('_s1') ? W240_COLUMNS_TEXT : W241_COLUMNS_TEXT
    when 'generated'
      W241_COLUMNS_TEXT
    else
      raise AuditError, "#{label} has an unknown W241 part role"
    end
  end

  def expected_w241_negative_columns_text(profile_id, role, label)
    match = /\Aadvanced_chunked_s0_negative_(data_corrupt|copy_truncated)\z/.match(profile_id)
    require!(!match.nil? && role == "negative_#{match[1]}", "#{label} has an unknown negative profile/role")
    W241_COLUMNS_TEXT
  end

  def assert_physical_stream_file_roster!(file_names, logical_substreams, label)
    observed = file_names.select { |name| name.end_with?('.bin', '.mrk2') }.sort
    expected = logical_substreams.flat_map do |stream|
      stem = stream_hash(stream)
      ["#{stem}.bin", "#{stem}.mrk2"]
    end.sort
    require!(observed == expected, "#{label} physical .bin/.mrk2 roster differs from metadata-derived streams")
    true
  end

  def rewrite_doc_substream_section(text, names)
    lines = text.split("\n", -1)
    header_index = lines.index { |line| /\A[0-9]+ substreams for column `doc`:\z/.match?(line) }
    require!(!header_index.nil?, 'cannot rewrite absent doc substream section')
    header = lines.fetch(header_index)
    count = Integer(header[/\A[0-9]+/], 10)
    end_index = header_index + 1 + count
    require!(end_index < lines.size, 'doc substream section is truncated')
    replacement = ["#{names.size} substreams for column `doc`:", *names.map { |name| "\t#{name}" }]
    lines[header_index..end_index - 1] = replacement
    lines.join("\n")
  end

  # Call with a captured one-line helper stdout to authenticate all embedded
  # role/profile schemas against their part bytes, then attack roster metadata.
  def self_test_helper_stream_roster_auditor!(helper_stdout_path)
    stdout = read_plain(helper_stdout_path, MAX_SUMMARY_BYTES, 'W241 helper stdout calibration')
    lines = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp).reject(&:empty?)
    require!(lines.size == 1, 'W241 helper stdout calibration expected exactly one JSON line')
    helper = JSON.parse(lines.first)
    require!(helper.fetch('format') == HELPER_FORMAT, 'W241 helper stdout calibration format differs')
    profiles = helper.fetch('profiles')
    require!(profiles.is_a?(Array) && profiles.map { |entry| entry.fetch('id') }.sort == PROFILE_IDS.sort,
      'W241 helper stdout calibration profile roster differs')
    calibrated_reads = []
    profiles.each do |profile|
      layout_id = profile.fetch('id').sub(/_s[01]\z/, '')
      %w[source_read generated_read].each do |read_role|
        read = profile.fetch(read_role)
        require!(read.fetch('role') == (read_role == 'source_read' ? 'stock_source' : 'crystal_generated'),
          "W241 #{profile.fetch('id')} #{read_role} role differs")
        expected_columns = audit_helper_columns_schema!(read, layout_id,
          "W241 actual helper calibration #{profile.fetch('id')} #{read_role}", check_part: true)
        wrong_columns = expected_columns == W240_COLUMNS_TEXT ? W241_COLUMNS_TEXT : W240_COLUMNS_TEXT
        wrong_type_read = JSON.parse(JSON.generate(read))
        wrong_type_read['columns_text'] = wrong_columns
        expect_reject!("#{profile.fetch('id')} #{read_role} wrong pk type") do
          audit_helper_columns_schema!(wrong_type_read, layout_id,
            "W241 wrong-type calibration #{profile.fetch('id')} #{read_role}")
        end
        roster = audit_helper_stream_roster!(read, layout_id,
          "W241 actual helper calibration #{profile.fetch('id')} #{read_role}")
        calibrated_reads << [profile.fetch('id'), read_role, read, roster]
      end
    end
    require!(calibrated_reads.size == 16, 'W241 helper stdout calibration did not cover all 16 source/generated reads')

    profile_id, read_role, read, positive = calibrated_reads.find do |id, role, _record, _roster|
      id == 'map_s0' && role == 'generated_read'
    end
    require!(!read.nil?, 'W241 helper stdout calibration map_s0 generated read is absent')
    original_text = read.fetch('columns_substreams_text')
    original_doc = positive.fetch(:object_substreams)

    missing_pk = original_text.sub("1 substreams for column `pk`:\n\tpk\n", "0 substreams for column `pk`:\n")
    expect_reject!('helper metadata missing pk role') do
      parse_columns_substreams_roster!(missing_pk, 'map', 'missing-pk calibration')
    end

    expect_reject!('helper metadata with an extra doc role') do
      rewrite_doc_substream_section(original_text, original_doc + ['doc.w241_unexpected']).then do |mutated|
        parse_columns_substreams_roster!(mutated, 'map', 'extra-doc calibration')
      end
    end
    expect_reject!('helper metadata with a duplicate doc role') do
      rewrite_doc_substream_section(original_text, original_doc + [original_doc.first]).then do |mutated|
        parse_columns_substreams_roster!(mutated, 'map', 'duplicate-doc calibration')
      end
    end

    reassigned_pk = original_text.sub("\tpk\n", "\tdoc.object_structure\n")
    expect_reject!('helper metadata with a reassigned pk role') do
      parse_columns_substreams_roster!(reassigned_pk, 'map', 'reassigned-role calibration')
    end

    reversed_doc_text = rewrite_doc_substream_section(original_text, original_doc.reverse)
    reversed_read = JSON.parse(JSON.generate(read))
    reversed_read['columns_substreams_text'] = reversed_doc_text
    reversed_roster = audit_helper_stream_roster!(reversed_read, 'map', 'reverse-doc visitation calibration')
    require!(reversed_roster.fetch(:object_substreams) == original_doc.reverse &&
             reversed_roster.fetch(:logical_substreams) == ['pk', *original_doc.reverse],
      'reverse doc visitation did not preserve metadata order')

    reordered_reader_names = JSON.parse(JSON.generate(read))
    reordered_reader_names['physical_stream_names'] = read.fetch('physical_stream_names').reverse
    expect_reject!('helper physical_stream_names in noncanonical order') do
      audit_helper_stream_roster!(reordered_reader_names, 'map', 'reordered helper roster calibration')
    end
    reordered_maps = JSON.parse(JSON.generate(read))
    reordered_maps['mark_triples'] = read.fetch('mark_triples').sort.reverse.to_h
    reordered_maps['raw_shared_streams'] = read.fetch('raw_shared_streams').sort.reverse.to_h
    reordered_roster = audit_helper_stream_roster!(reordered_maps, 'map', 'reordered map insertion calibration')
    require!(reordered_roster.fetch(:object_substreams) == original_doc,
      'reordered map insertion changed metadata-derived doc roster')

    missing_marks = JSON.parse(JSON.generate(read))
    missing_marks.fetch('mark_triples').delete(original_doc.last)
    expect_reject!('helper mark_triples missing a doc key') do
      audit_helper_stream_roster!(missing_marks, 'map', 'missing mark key calibration')
    end
    extra_marks = JSON.parse(JSON.generate(read))
    extra_marks.fetch('mark_triples')['doc.w241_unexpected'] = []
    expect_reject!('helper mark_triples has an extra doc key') do
      audit_helper_stream_roster!(extra_marks, 'map', 'extra mark key calibration')
    end
    missing_raw = JSON.parse(JSON.generate(read))
    missing_raw.fetch('raw_shared_streams').delete(original_doc.last)
    expect_reject!('helper raw_shared_streams missing a doc key') do
      audit_helper_stream_roster!(missing_raw, 'map', 'missing raw key calibration')
    end
    extra_raw = JSON.parse(JSON.generate(read))
    extra_raw.fetch('raw_shared_streams')['doc.w241_unexpected'] = {}
    expect_reject!('helper raw_shared_streams has an extra doc key') do
      audit_helper_stream_roster!(extra_raw, 'map', 'extra raw key calibration')
    end
    true
  rescue KeyError, JSON::ParserError => error
    raise AuditError, "W241 helper stream calibration is malformed: #{error.message}"
  end

  def authenticate_w240_queries!(root, id, stages)
    direct = authenticate_invocation!(root, stages.fetch('direct').fetch('invocation'), "W240 #{id}/direct")
    full = authenticate_invocation!(root, stages.fetch('full').fetch('invocation'), "W240 #{id}/full")
    direct_sql = direct.fetch(:sql)
    full_sql = full.fetch(:sql)
    require!(direct_sql.include?('doc.arr') && direct_sql.include?('doc.mixed') && direct_sql.include?('doc.late') &&
             !direct_sql.match?(/SELECT[^;]*\bdoc\b\s*[,)]/mi) && !direct_sql.include?('JSONDynamicPaths') &&
             !direct_sql.include?('JSONSharedDataPaths'), "W240 #{id} direct SELECT is not path-only")
    require!(full_sql.include?('toJSONString(doc)') && full_sql.include?('JSONSharedDataPaths(doc)'),
      "W240 #{id} full-object SELECT is absent")
    authenticate_query_stdout!(direct.fetch(:stdout), id, :direct)
    authenticate_query_stdout!(full.fetch(:stdout), id, :full)
    true
  end

  def authenticate_query_stdout!(stdout, id, stage)
    tag = stage == :direct ? '__W240_DIRECT__' : '__W240_FULL__'
    rows = stdout.lines.map(&:chomp).select { |line| line.start_with?("#{tag}\t") }
      .map { |line| line.split("\t", -1) }
    require!(rows.length == ROWS.size, "W240 #{id}/#{stage} raw output has the wrong row count")
    actual = {}
    rows.each do |fields|
      require!(fields[1] == id, "W240 #{id}/#{stage} raw output profile differs")
      pk = Integer(fields[2], 10)
      require!(!actual.key?(pk), "W240 #{id}/#{stage} duplicated pk #{pk}")
      if stage == :direct
        require!(fields.size == 12, "W240 #{id} direct stdout row width differs")
        values = fields.values_at(5, 8, 11).map { |hex| parse_hex_json(hex, "W240 #{id}/direct pk #{pk}") }
        expected = ROWS.find { |row| row.fetch(:pk) == pk } || raise(AuditError, "W240 direct pk #{pk} is unrostered")
        require!(values == [expected.fetch(:doc).fetch('arr', nil), expected.fetch(:doc).fetch('mixed', nil),
                            expected.fetch(:doc).fetch('late', nil)],
          "W240 #{id}/direct pk #{pk} logical value differs")
        if expected.fetch(:doc).key?('arr') && expected.fetch(:doc).fetch('arr').empty?
          require!(fields[4] == 'Array(Nullable(String))' && values[0] == [],
            "W240 #{id}/direct pk #{pk} empty-array carrier differs")
        end
        if expected.fetch(:doc).key?('late')
          require!(fields[10].start_with?('Array(JSON('), "W240 #{id}/direct late-only actual type is absent")
        end
      else
        require!(fields.size == 7, "W240 #{id} full stdout row width differs")
        actual_doc = parse_hex_json(fields[4], "W240 #{id}/full pk #{pk}")
        expected = ROWS.find { |row| row.fetch(:pk) == pk } || raise(AuditError, "W240 full pk #{pk} is unrostered")
        require!(actual_doc == expected.fetch(:doc), "W240 #{id}/full pk #{pk} logical value differs")
        dynamic_paths = parse_hex_json(fields[5], "W240 #{id}/dynamic paths pk #{pk}")
        shared_paths = parse_hex_json(fields[6], "W240 #{id}/shared paths pk #{pk}")
        require!(dynamic_paths == [] && shared_paths.sort == expected.fetch(:doc).keys.sort,
          "W240 #{id}/full pk #{pk} path roster differs")
      end
      actual[pk] = true
    end
    require!(actual.keys.sort == ROWS.map { |row| row.fetch(:pk) }, "W240 #{id}/#{stage} pk set differs")
    true
  rescue ArgumentError => error
    raise AuditError, "W240 #{id}/#{stage} raw output is malformed: #{error.message}"
  end

  def parse_hex_json(hex, label)
    require!(hex.is_a?(String) && hex.match?(/\A(?:[0-9a-f]{2})*\z/i), "#{label} hex JSON is malformed")
    JSON.parse([hex].pack('H*'))
  rescue JSON::ParserError => error
    raise AuditError, "#{label} is invalid JSON: #{error.message}"
  end

  # W241 capture acceptance starts from the raw evidence tree. The summary is
  # only an index: invocation artifacts, helper output, and every current part
  # file are reopened and hashed before any observed label is accepted.
  def audit_capture!(summary_path, collect_context: nil)
    require!(collect_context.nil? || (collect_context.is_a?(Hash) && collect_context.empty?),
      'W241 audit context collector must be an empty Hash')
    require!(summary_path.is_a?(String) && !summary_path.empty? && !File.symlink?(summary_path),
      'W241 summary path is absent or symlinked')
    full = File.realpath(summary_path)
    root = File.dirname(full)
    require!(File.basename(full) == 'summary.json' && File.directory?(root) && File.realpath(root) == root,
      'W241 summary is not in a canonical evidence root')
    summary_bytes = read_plain(full, MAX_SUMMARY_BYTES, 'W241 summary')
    summary = JSON.parse(summary_bytes)
    staged_context = collect_context ? {} : nil
    audit_capture_document!(summary, root, collect_context: staged_context)
    result = {root: root, summary_sha256: sha256(summary_bytes), status: summary.fetch('status'),
              profile_count: summary.fetch('profiles').size}
    collect_context.merge!(staged_context) if collect_context
    result
  rescue KeyError, JSON::ParserError => error
    raise AuditError, "W241 capture summary is malformed: #{error.message}"
  end

  def audit_capture_document!(summary, root, collect_context: nil)
    require!(collect_context.nil? || (collect_context.is_a?(Hash) && collect_context.empty?),
      'W241 document context collector must be an empty Hash')
    require!(summary.is_a?(Hash) && summary['format'] == CAPTURE_FORMAT &&
             summary['status'] == 'paired_stock_crystal_observed' && summary['fatal_error'].nil?,
      'W241 capture is not a complete paired observation')
    require!(summary['evidence_root'] == root, 'W241 summary root differs from its canonical parent')
    requested_frame_bytes = summary.fetch('requested_frame_bytes')
    require!(FRAME_BYTES_OPTIONS.include?(requested_frame_bytes),
      'W241 requested frame_bytes is outside the fixed 32/64 allowlist')
    runtime = summary.fetch('runtime')
    require!(runtime['sha256'] == SOURCE_RUNTIME.fetch('sha256') &&
             runtime['sha256_before'] == SOURCE_RUNTIME.fetch('sha256') &&
             runtime['sha256_after'] == SOURCE_RUNTIME.fetch('sha256') &&
             runtime['version'] == SOURCE_RUNTIME.fetch('version') && runtime['build'] == SOURCE_RUNTIME.fetch('build'),
      'W241 pinned native runtime identity differs')
    limits = summary.fetch('limits')
    require!(limits['native_max_threads'] == 1 && limits['native_max_memory_usage_bytes'] == W185::MEMORY,
      'W241 native resource bounds differ')
    source = summary.fetch('source_capture')
    require!(source['w240_root'] == W240_ROOT && source['w240_summary_sha256'] == W240_SUMMARY_SHA256,
      'W241 source W240 identity differs')
    profiles = summary.fetch('profiles')
    require!(profiles.is_a?(Array) && profiles.map { |profile| profile.fetch('id') } == PROFILE_IDS,
      'W241 profile roster/order differs')
    require!(summary.fetch('profile_ids') == PROFILE_IDS, 'W241 declared profile roster differs')
    w240 = authenticate_w240!(W240_ROOT, W240_SUMMARY_SHA256)

    invocation_records = summary.fetch('invocations')
    require!(invocation_records.is_a?(Array), 'W241 invocation roster is malformed')
    by_label = {}
    invocation_records.each do |record|
      label = record.fetch('label')
      require!(!by_label.key?(label), "duplicate W241 invocation #{label}")
      by_label[label] = record
      authenticate_w241_invocation!(root, record, "W241 #{label}")
    end
    expected_labels = expected_w241_labels(summary)
    require!(by_label.keys.sort == expected_labels.sort, 'W241 process invocation roster is incomplete or contains extras')

    helper = summary.fetch('helper')
    helper_record = by_label.fetch('crystal_helper')
    require!(helper == helper_record, 'W241 helper invocation summary differs from the invocation roster')
    helper_sha_before = summary.fetch('helper_sha256_before')
    helper_sha_after = summary.fetch('helper_sha256_after')
    require!(helper_sha_before == helper_sha_after && helper_record['expected_binary_sha256'] == helper_sha_before &&
             helper_record['binary_sha_before'] == helper_sha_before && helper_record['binary_sha_after'] == helper_sha_after,
      'W241 Crystal helper identity changed during execution')
    helper_input = summary.fetch('helper_input')
    require!(helper_input.is_a?(Hash) && helper_input.keys.sort == %w[capture_root format frame_bytes profiles].sort &&
             helper_input.fetch('format') == INPUT_FORMAT && helper_input.fetch('frame_bytes') == requested_frame_bytes,
      'W241 helper input frame_bytes/envelope differs from the retained request')
    helper_input_path = helper_record.fetch('argv')[1]
    helper_output_root = helper_record.fetch('argv')[2]
    require!(File.expand_path(helper_input_path) == File.join(root, 'generated', 'helper_input.json') &&
             File.expand_path(helper_output_root) == File.join(root, 'generated'),
      'W241 helper input/output paths differ from the bounded evidence root')
    input_bytes = read_plain(helper_input_path, 1024 * 1024, 'W241 helper input')
    require!(JSON.parse(input_bytes) == helper_input, 'W241 helper input bytes differ from retained input')
    helper_stdout = read_plain(File.join(root, 'invocations', helper_record.fetch('stdout_file')), 16 * 1024 * 1024,
      'W241 helper stdout')
    lines = helper_stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp).reject(&:empty?)
    require!(lines.size == 1, 'W241 helper stdout is not one JSON object')
    helper_result = JSON.parse(lines.first)
    require!(helper_result['format'] == HELPER_FORMAT &&
             helper_result['requested_frame_bytes'] == requested_frame_bytes &&
             helper_result['input_sha256'] == sha256(input_bytes) && helper_result['profile_ids'] == PROFILE_IDS,
      'W241 helper result envelope/input binding differs')
    helper_profiles = helper_result.fetch('profiles')
    require!(helper_profiles.is_a?(Array) && helper_profiles.map { |item| item.fetch('id') } == PROFILE_IDS,
      'W241 helper profile output differs')

    input_profiles = helper_input.fetch('profiles')
    require!(input_profiles.map { |item| item.fetch('id') } == PROFILE_IDS, 'W241 helper input profile roster differs')
    profiles.zip(helper_profiles, input_profiles).each do |profile, helper_profile, helper_input_profile|
      audit_w241_profile!(root, profile, helper_profile, helper_input_profile, by_label, w240,
        requested_frame_bytes: requested_frame_bytes)
    end
    audit_w241_negative_controls!(root, summary, helper_result, by_label,
      requested_frame_bytes: requested_frame_bytes)
    if collect_context
      index = PROFILE_IDS.index('advanced_s0') || raise(AuditError, 'advanced_s0 scoped-control profile is unrostered')
      collect_context.merge!(
        root: root,
        summary: summary,
        helper_result: helper_result,
        helper_input: helper_input,
        profile: profiles.fetch(index),
        helper_profile: helper_profiles.fetch(index),
        helper_input_profile: input_profiles.fetch(index),
        by_label: by_label,
        w240: w240,
        requested_frame_bytes: requested_frame_bytes,
        layout: LAYOUTS.find { |entry| entry.fetch(:id) == 'advanced' } ||
          raise(AuditError, 'advanced scoped-control layout is unrostered'),
      )
    end
    true
  rescue KeyError, JSON::ParserError => error
    raise AuditError, "W241 evidence is malformed: #{error.message}"
  end

  def expected_w241_labels(summary)
    labels = ['crystal_helper']
    LAYOUTS.each do |layout|
      id = "#{layout.fetch(:id)}_s0"
      labels.concat(["source_write_#{id}", "source_direct_#{id}", "source_full_#{id}"])
    end
    PROFILE_IDS.each do |id|
      labels.concat(["target_create_#{id}", "target_attach_check_#{id}", "generated_direct_#{id}", "generated_full_#{id}"])
      layout_id = id.sub(/_s[01]\z/, '')
      expected_decode_streams(layout_id).each do |stream|
        labels << native_decode_label(id, 'source', stream)
        labels << native_decode_label(id, 'generated', stream)
      end
    end
    %w[data_corrupt copy_truncated].each do |kind|
      control = summary.fetch('negative_controls').find { |entry| entry.fetch('kind') == kind }
      labels.concat(["negative_create_#{kind}", "negative_attach_check_#{kind}"])
      expected_decode_streams('advanced_chunked').each do |stream|
        labels << native_decode_label("advanced_chunked_s0_negative_#{kind}", "negative_#{kind}", stream)
      end
      labels << "negative_direct_#{kind}" if control.fetch('direct').key?('invocation')
      labels << "negative_full_#{kind}" if control.fetch('full').key?('invocation')
    end
    labels
  end

  def expected_decode_streams(layout_id)
    W240_LAYOUT_STREAMS.fetch(layout_id).select do |stream|
      stream == 'doc.object_structure' || stream.start_with?('doc.object_shared_data')
    end.sort
  end

  def native_decode_label(profile_id, role, stream)
    "decompress_#{role}_#{profile_id}_#{stream_hash(stream)}"
  end

  def audit_w241_negative_controls!(root, summary, helper_result, by_label, requested_frame_bytes:)
    controls = summary.fetch('negative_controls')
    helper_controls = helper_result.fetch('negative_controls')
    require!(controls.is_a?(Array) && controls.map { |entry| entry.fetch('kind') } == %w[data_corrupt copy_truncated],
      'W241 negative-control roster/order differs')
    baseline_read = helper_result.fetch('profiles').find { |entry| entry.fetch('id') == 'advanced_chunked_s0' }
      .fetch('generated_read')
    baseline_layout = LAYOUTS.find { |entry| entry.fetch(:id) == 'advanced_chunked' }
    baseline_path = File.join(root, 'generated', 'advanced_chunked_s0', 'all_1_1_0')
    require!(baseline_read.fetch('part_path') == baseline_path, 'W241 negative-control baseline path differs')
    baseline_profile = summary.fetch('profiles').find { |entry| entry.fetch('id') == 'advanced_chunked_s0' }
    baseline_decodes = baseline_profile.fetch('native_stream_decodes').fetch('generated')
    audit_helper_part!(baseline_read, baseline_layout, 'W241 negative-control baseline', root: root,
      by_label: by_label, profile_id: 'advanced_chunked_s0', role: 'generated', native_decodes: baseline_decodes,
      requested_frame_bytes: requested_frame_bytes)
    baseline_files = baseline_read.fetch('physical_file_inventory').each_with_object({}) do |entry, result|
      result[entry.fetch('name')] = {'size' => entry.fetch('size'), 'sha256' => entry.fetch('sha256')}
    end
    baseline_roster = parse_columns_substreams_roster!(baseline_read.fetch('columns_substreams_text'),
      'advanced_chunked', 'W241 negative-control baseline')
    baseline_logical = baseline_roster.fetch(:logical_substreams)
    baseline_raw = baseline_read.fetch('raw_shared_streams')
    specs = [
      ['data_corrupt', 'data_corrupt_part', 'data_corrupt_inventory'],
      ['copy_truncated', 'copy_truncated_part', 'copy_truncated_inventory'],
    ]
    specs.each_with_index do |(kind, path_key, inventory_key), index|
      control = controls.fetch(index)
      part_path = File.join(root, 'generated', 'negative_controls',
        kind == 'data_corrupt' ? 'advanced_chunked_s0_data_corrupt' : 'advanced_chunked_s0_copy_truncated',
        'all_1_1_0')
      require!(control.fetch('part_path') == part_path && helper_controls.fetch(path_key) == part_path,
        "W241 #{kind} part path differs")
      helper_inventory = helper_controls.fetch(inventory_key)
      negative_part = audit_negative_helper_part!(part_path, helper_inventory, kind, baseline_files,
        baseline_logical, baseline_raw, baseline_read.fetch('columns_substreams_text'), baseline_layout,
        root: root, by_label: by_label, profile_id: "advanced_chunked_s0_negative_#{kind}",
        role: "negative_#{kind}", native_decodes: control.fetch('native_stream_decodes'))
      reported_part = control.fetch('part_inventory')
      assert_negative_part_projection!(reported_part, negative_part, "W241 #{kind}")
      require!(reported_part.fetch('source_kind') == kind, "W241 #{kind} source-kind label differs")

      id = "advanced_chunked_s0_negative_#{kind}"
      create = by_label.fetch("negative_create_#{kind}")
      attach = by_label.fetch("negative_attach_check_#{kind}")
      require!(control.fetch('attach_invocation') == attach &&
               control.fetch('attach_process_classification') == attach.fetch('process_classification'),
        "W241 #{kind} attach invocation/classification reference differs")
      create_details = authenticate_w241_invocation!(root, create, "W241 #{kind} create")
      origin = audit_generated_target_create!(create_details, id, baseline_layout, 0, "W241 #{kind}", root)
      store_root = File.join(root, 'stores', 'native')
      target_path = canonical_child(origin.fetch(:data_path), store_root, "W241 #{kind} target data path")

      attach_details = authenticate_w241_invocation!(root, attach, "W241 #{kind} attach/CHECK")
      attach_sql = attach_details.fetch(:input)
      authenticate_generated_attach_sql!(attach_sql, id, origin.fetch(:table), "W241 #{kind}")
      attach_success = attach.fetch('process_classification') == 'success' && attach.fetch('exit') == 0 &&
        attach.fetch('signal').nil? && attach.fetch('timed_out') == false
      attached_part = nil
      if attach_success
        audit_native_check_output!(attach_details.fetch(:stdout), id, "W241 #{kind}")
        attached_part = audit_attached_check_schema!(attach_details.fetch(:stdout), id,
          origin.fetch(:table), store_root)
        authenticate_target_part_path!(target_path, attached_part, "W241 #{kind}")
        audit_attached_copy!(negative_part.fetch(:path), negative_part.fetch(:complete_file_inventory),
          attached_part, "W241 #{kind}")
      else
        require!(control.fetch('direct').fetch('status') == 'not_run_attach_or_CHECK_failure_inconclusive' &&
                 control.fetch('full').fetch('status') == 'not_run_attach_or_CHECK_failure_inconclusive',
          "W241 #{kind} queries ran after attach/CHECK failure")
      end

      observations = {}
      %w[direct full].each do |stage|
        stage_record = control.fetch(stage)
        if stage_record.key?('invocation')
          label = "negative_#{stage}_#{kind}"
          invocation = by_label.fetch(label)
          require!(stage_record.fetch('invocation') == invocation, "W241 #{kind} #{stage} invocation reference differs")
          details = authenticate_w241_invocation!(root, invocation, "W241 #{kind} #{stage}")
          require!(attach_success, "W241 #{kind} #{stage} ran without successful attach/CHECK")
          authenticate_generated_query_table!(details.fetch(:input), stage, origin.fetch(:table), id,
            "W241 #{kind} #{stage}")
          if stage_record.fetch('status') == 'stage_observed'
            require!(invocation.fetch('process_classification') == 'success' && invocation.fetch('exit') == 0 &&
                     invocation.fetch('stderr_bytes') == 0, "W241 #{kind} #{stage} stage status contradicts process")
            raw_observation = audit_w241_query_output!(details, stage, id, origin.fetch(:table), positive: false)
            assert_negative_query_observation_projection!(raw_observation, stage_record.fetch('observations'),
              stage, "W241 #{kind} #{stage}")
            if (kind == 'data_corrupt' && %w[direct full].include?(stage)) ||
               (kind == 'copy_truncated' && stage == 'direct')
              self_test_negative_query_observation_projection!(raw_observation,
                stage_record.fetch('observations'), stage, "W241 #{kind} #{stage} actual-artifact projection")
            end
            observations[stage] = raw_observation
          elsif stage_record.fetch('status') == 'process_failed_observed'
            require!(stage_record.fetch('stdout') == details.fetch(:stdout) && stage_record.fetch('stderr') == details.fetch(:stderr),
              "W241 #{kind} #{stage} failed-process output differs from artifacts")
            require!(kind == 'copy_truncated' && stage == 'full',
              "W241 #{kind} #{stage} process failure is inconclusive, not targeted negative evidence")
            authenticate_copy_truncation_query_sql!(details.fetch(:input), origin.fetch(:table),
              "W241 #{kind} #{stage}")
            authenticate_copy_truncation_failure!(invocation, details, id, origin.fetch(:table), attached_part,
              "W241 #{kind} #{stage}")
            observations[stage] = :authenticated_copy_truncation
          elsif stage_record.fetch('status') == 'process_or_observation_failure_inconclusive'
            observations[stage] = nil
          else
            raise AuditError, "W241 #{kind} #{stage} has an unrostered status"
          end
        else
          require!(!attach_success && stage_record.fetch('status') == 'not_run_attach_or_CHECK_failure_inconclusive',
            "W241 #{kind} #{stage} invocation is missing for its status")
          observations[stage] = nil
        end
      end
      expected = derive_negative_outcome(kind, control.fetch('direct').fetch('status'), observations['direct'],
        control.fetch('full').fetch('status'), observations['full'],
        targeted_copy_failure: observations['full'] == :authenticated_copy_truncation)
      require!(control.fetch('status') == expected.fetch(:status) &&
               control.fetch('observed_effect') == expected.fetch(:effect) &&
               control.fetch('interpretation') == expected.fetch(:interpretation),
        "W241 #{kind} outcome does not follow from independently parsed process evidence")
    end
    true
  rescue KeyError, JSON::ParserError => error
    raise AuditError, "W241 negative-control evidence is malformed: #{error.message}"
  end

  def audit_negative_helper_part!(path, reported, kind, baseline_files, baseline_logical, baseline_raw,
                                  baseline_columns, layout, root:, by_label:, profile_id:, role:, native_decodes:)
    evidence_root = root
    part_root = File.realpath(path)
    require!(part_root == path && File.directory?(part_root) && !File.symlink?(part_root), "W241 #{kind} part is noncanonical")
    tree = plain_tree!(part_root, "W241 #{kind} part")
    entries = reported.fetch('physical_file_inventory')
    names = entries.map { |entry| entry.fetch('name') }.sort
    require!(names == Dir.children(part_root).sort, "W241 #{kind} complete file roster differs")
    files = {}
    entries.each do |entry|
      name = entry.fetch('name')
      require!(File.basename(name) == name && name.match?(/\A[a-zA-Z0-9_.-]+\z/), "W241 #{kind} filename is unsafe")
      bytes = read_plain(File.join(part_root, name), MAX_PART_FILE_BYTES, "W241 #{kind} #{name}")
      require!(bytes.bytesize == entry.fetch('size') && sha256(bytes) == entry.fetch('sha256'),
        "W241 #{kind} file digest differs: #{name}")
      files[name] = {'size' => bytes.bytesize, 'sha256' => sha256(bytes)}
    end
    require!(tree.fetch(:files) == names.size && tree.fetch(:bytes) == files.values.sum { |entry| entry.fetch('size') },
      "W241 #{kind} part bounds differ")
    columns_bytes = read_plain(File.join(part_root, 'columns_substreams.txt'), MAX_PART_FILE_BYTES,
      "W241 #{kind} columns_substreams")
    columns = columns_bytes.force_encoding(Encoding::UTF_8)
    roster = parse_columns_substreams_roster!(columns, layout.fetch(:id), "W241 #{kind}")
    logical = roster.fetch(:logical_substreams)
    object_substreams = roster.fetch(:object_substreams)
    assert_physical_stream_file_roster!(names, logical, "W241 #{kind}")
    require!(columns == reported.fetch('columns_substreams_text') && logical == reported.fetch('physical_stream_names') &&
             logical == baseline_logical && columns == baseline_columns,
      "W241 #{kind} table-wide logical stream inventory differs")
    columns_schema = read_plain(File.join(part_root, 'columns.txt'), MAX_PART_FILE_BYTES,
      "W241 #{kind} columns")
    expected_columns = expected_w241_negative_columns_text(profile_id, role, "W241 #{kind}")
    require!(columns_schema == expected_columns, "W241 #{kind} columns.txt schema differs")
    raw = reported.fetch('raw_shared_streams')
    require!(raw.is_a?(Hash) && raw.keys.sort == expected_decode_streams(layout.fetch(:id)),
      "W241 #{kind} raw Object stream roster differs from doc metadata")
    object_substreams.each do |stream|
      next unless stream == 'doc.object_structure' || stream.start_with?('doc.object_shared_data')
      entry = raw.fetch(stream)
      physical_name = "#{stream_hash(stream)}.bin"
      require!(entry.fetch('physical_file') == physical_name &&
               files.fetch(physical_name).fetch('sha256') == entry.fetch('physical_sha256'),
        "W241 #{kind} raw stream physical binding differs: #{stream}")
      hex = entry.fetch('decoded_hex')
      require!(hex.match?(/\A(?:[0-9a-f]{2})*\z/i) && sha256([hex].pack('H*')) == entry.fetch('decoded_sha256'),
        "W241 #{kind} decoded stream digest differs: #{stream}")
    end
    native_streams = audit_native_stream_decodes!(evidence_root, {part_path: part_root, raw_shared_streams: raw}, layout,
      profile_id, role, native_decodes, by_label, "W241 #{kind}")
    physical = audit_w241_physical_layout!(logical, raw, layout, "W241 #{kind}")
    logical.each do |stream|
      mark = read_plain(File.join(part_root, "#{stream_hash(stream)}.mrk2"), MAX_PART_FILE_BYTES, "W241 #{kind} mark #{stream}")
      words = mark.unpack('Q<*')
      require!((words.size % 3).zero? && words.each_slice(3).map { |triple| triple[2] } == [2, 2, 2, 2, 0],
        "W241 #{kind} mark row schedule differs: #{stream}")
    end
    data_name = "#{stream_hash('doc.object_shared_data.0.data')}.bin"
    copy_name = "#{stream_hash('doc.object_shared_data.copy.values')}.bin"
    target_name = kind == 'data_corrupt' ? data_name : copy_name
    target_mark = "#{stream_hash(kind == 'data_corrupt' ? 'doc.object_shared_data.0.data' : 'doc.object_shared_data.copy.values')}.mrk2"
    changed = files.keys.select { |name| files.fetch(name) != baseline_files.fetch(name) }.sort
    allowed = [target_name, target_mark, 'checksums.txt'].sort
    require!(changed.include?(target_name) && changed.include?('checksums.txt') && (changed - allowed).empty?,
      "W241 #{kind} changed file roster is not limited to its target lane/marks/checksums")
    if kind == 'data_corrupt'
      require!(files.fetch(copy_name) == baseline_files.fetch(copy_name) &&
               raw.fetch('doc.object_shared_data.copy.values').fetch('decoded_sha256') == baseline_raw.fetch('doc.object_shared_data.copy.values').fetch('decoded_sha256'),
        'W241 Data corruption did not preserve Copy bytes')
    else
      require!(files.fetch(data_name) == baseline_files.fetch(data_name) &&
               raw.fetch('doc.object_shared_data.0.data').fetch('decoded_sha256') == baseline_raw.fetch('doc.object_shared_data.0.data').fetch('decoded_sha256'),
        'W241 Copy truncation changed ordinary Data')
    end
    %w[columns.txt count.txt serialization.json].each do |name|
      require!(files.fetch(name) == baseline_files.fetch(name), "W241 #{kind} changed unrelated metadata #{name}")
    end
    {path: part_root, physical_file_names: names, complete_file_inventory: files, logical_substreams: logical,
     object_substreams: object_substreams,
     columns_substreams_text: columns, raw_shared_streams: raw, source_kind: kind, physical_layout: physical}
  rescue KeyError, JSON::ParserError => error
    raise AuditError, "W241 #{kind} negative part is malformed: #{error.message}"
  end

  # JSON-decoded summary fields are String-keyed; the independently reopened
  # part result is an internal Symbol-keyed Hash. Keep this boundary explicit
  # instead of trying alternate key spellings on either side.
  def assert_negative_part_projection!(reported_part, reopened_part, label)
    require!(reported_part.is_a?(Hash) && reopened_part.is_a?(Hash),
      "#{label} part projection is malformed")
    require!(reported_part.keys.all? { |key| key.is_a?(String) } &&
             reported_part.keys.sort == NEGATIVE_PART_SUMMARY_FIELDS,
      "#{label} summary field roster differs")
    expected_reopened_keys = NEGATIVE_PART_REOPENED_FIELDS.map(&:to_sym).sort_by(&:to_s)
    require!(reopened_part.keys.all? { |key| key.is_a?(Symbol) } &&
             reopened_part.keys.sort_by(&:to_s) == expected_reopened_keys,
      "#{label} reopened field roster differs")
    [
      ['path', :path],
      ['physical_file_names', :physical_file_names],
      ['complete_file_inventory', :complete_file_inventory],
      ['logical_substreams', :logical_substreams],
      ['object_substreams', :object_substreams],
      ['raw_shared_streams', :raw_shared_streams],
      ['source_kind', :source_kind],
    ].each do |summary_key, reopened_key|
      require!(reported_part.key?(summary_key), "#{label} summary is missing #{summary_key}")
      require!(reopened_part.key?(reopened_key), "#{label} reopened part is missing #{summary_key}")
      require!(reported_part.fetch(summary_key) == reopened_part.fetch(reopened_key),
        "#{label} summary #{summary_key} differs from reopened part")
    end
    true
  end

  # The raw query oracle retains fields needed for independent checks that the
  # compact summary intentionally omits. Bind only the explicitly emitted
  # projection, after validating both key domains and row schemas exactly.
  def negative_query_observation_projection!(raw_observation, stage, label)
    require!(raw_observation.is_a?(Hash) && raw_observation.keys.all? { |key| key.is_a?(Symbol) },
      "#{label} raw observation key domain differs")
    expected_pks = ROWS.map { |row| row.fetch(:pk) }.sort

    case stage
    when 'direct'
      require!(raw_observation.keys.sort_by(&:to_s) == NEGATIVE_DIRECT_RAW_FIELDS,
        "#{label} raw direct outer fields differ")
      raw_rows = raw_observation.fetch(:rows_by_pk)
      require!(raw_rows.is_a?(Hash) && raw_rows.keys.all? { |pk| pk.is_a?(Integer) } &&
               raw_rows.keys.sort == expected_pks,
        "#{label} raw direct row domain differs")
      projected_rows = raw_rows.each_with_object({}) do |(pk, row), result|
        require!(row.is_a?(Hash) && row.keys.all? { |key| key.is_a?(Symbol) } &&
                 row.keys.sort_by(&:to_s) == NEGATIVE_DIRECT_RAW_ROW_FIELDS,
          "#{label} raw direct row fields differ at pk #{pk}")
        result[pk.to_s] = NEGATIVE_DIRECT_SUMMARY_ROW_FIELDS.to_h do |field|
          [field, row.fetch(field.to_sym)]
        end
      end
      {'rows_by_pk' => projected_rows}
    when 'full'
      require!(raw_observation.keys.sort_by(&:to_s) == NEGATIVE_FULL_RAW_FIELDS,
        "#{label} raw full outer fields differ")
      require!(raw_observation.fetch(:bounded_docs_by_tag).is_a?(Hash) &&
               raw_observation.fetch(:zero_selection).is_a?(Hash),
        "#{label} raw full auxiliary checks are absent")
      raw_documents = raw_observation.fetch(:full_docs_by_pk)
      require!(raw_documents.is_a?(Hash) && raw_documents.keys.all? { |pk| pk.is_a?(Integer) } &&
               raw_documents.keys.sort == expected_pks,
        "#{label} raw full row domain differs")
      raw_documents.each do |pk, document|
        require!(document.is_a?(Hash) && document.keys.all? { |key| key.is_a?(String) },
          "#{label} raw full document fields differ at pk #{pk}")
      end
      {'full_docs_by_pk' => raw_documents.to_h { |pk, document| [pk.to_s, document] }}
    else
      raise AuditError, "#{label} stage is not a negative direct/full projection"
    end
  end

  def assert_negative_query_observation_projection!(raw_observation, reported_observation, stage, label)
    projected = negative_query_observation_projection!(raw_observation, stage, label)
    require!(reported_observation.is_a?(Hash) && reported_observation.keys.all? { |key| key.is_a?(String) } &&
             reported_observation.keys.sort == projected.keys.sort,
      "#{label} summary outer fields differ")

    if stage == 'direct'
      rows = reported_observation.fetch('rows_by_pk')
      expected_domain = projected.fetch('rows_by_pk').keys.sort
      require!(rows.is_a?(Hash) && rows.keys.all? { |pk| pk.is_a?(String) } && rows.keys.sort == expected_domain,
        "#{label} summary direct row domain differs")
      rows.each do |pk, row|
        require!(row.is_a?(Hash) && row.keys.all? { |key| key.is_a?(String) } &&
                 row.keys.sort == NEGATIVE_DIRECT_SUMMARY_ROW_FIELDS,
          "#{label} summary direct row fields differ at pk #{pk}")
      end
    elsif stage == 'full'
      documents = reported_observation.fetch('full_docs_by_pk')
      expected_documents = projected.fetch('full_docs_by_pk')
      require!(documents.is_a?(Hash) && documents.keys.all? { |pk| pk.is_a?(String) } &&
               documents.keys.sort == expected_documents.keys.sort,
        "#{label} summary full row domain differs")
      documents.each do |pk, document|
        expected_document = expected_documents.fetch(pk)
        require!(document.is_a?(Hash) && document.keys.all? { |key| key.is_a?(String) } &&
                 document.keys.sort == expected_document.keys.sort,
          "#{label} summary full document fields differ at pk #{pk}")
      end
    end

    require!(reported_observation == projected,
      "#{label} summary values differ from the exact raw projection")
    true
  end

  # Called on the already-authenticated frozen data_corrupt direct/full and
  # copy_truncated direct artifacts. These mutations exercise the same normal
  # projection guard without changing or re-hashing any captured binary.
  def self_test_negative_query_observation_projection!(raw_observation, reported_observation, stage, label)
    assert_negative_query_observation_projection!(raw_observation, reported_observation, stage, label)
    raw_copy = Marshal.load(Marshal.dump(raw_observation))
    summary_copy = Marshal.load(Marshal.dump(reported_observation))
    rejection = lambda do |description, raw, summary|
      expect_reject!("#{label} #{description}") do
        assert_negative_query_observation_projection!(raw, summary, stage, "#{label} #{description}")
      end
    end

    if stage == 'direct'
      wrong_value = Marshal.load(Marshal.dump(summary_copy))
      wrong_value.fetch('rows_by_pk').fetch('1')['arr_type'] = 'forged-type'
      rejection.call('wrong value', raw_copy, wrong_value)
      missing_value = Marshal.load(Marshal.dump(summary_copy))
      missing_value.fetch('rows_by_pk').fetch('1')['arr'] = nil
      rejection.call('missing-equivalent value', raw_copy, missing_value)
      missing_row_field = Marshal.load(Marshal.dump(summary_copy))
      missing_row_field.fetch('rows_by_pk').fetch('1').delete('arr_type')
      rejection.call('missing row field', raw_copy, missing_row_field)
      extra_row_field = Marshal.load(Marshal.dump(summary_copy))
      extra_row_field.fetch('rows_by_pk').fetch('1')['unexpected'] = true
      rejection.call('extra row field', raw_copy, extra_row_field)
      missing_row = Marshal.load(Marshal.dump(summary_copy))
      missing_row.fetch('rows_by_pk').delete('8')
      rejection.call('missing row-domain entry', raw_copy, missing_row)
      extra_row = Marshal.load(Marshal.dump(summary_copy))
      extra_row.fetch('rows_by_pk')['9'] = extra_row.fetch('rows_by_pk').fetch('1')
      rejection.call('extra row-domain entry', raw_copy, extra_row)
      missing_outer = Marshal.load(Marshal.dump(summary_copy))
      missing_outer.delete('rows_by_pk')
      rejection.call('missing outer field', raw_copy, missing_outer)
      extra_outer = Marshal.load(Marshal.dump(summary_copy))
      extra_outer['unexpected'] = true
      rejection.call('extra outer field', raw_copy, extra_outer)
    else
      wrong_value = Marshal.load(Marshal.dump(summary_copy))
      wrong_value.fetch('full_docs_by_pk').fetch('1')['arr'] = nil
      rejection.call('wrong value', raw_copy, wrong_value)
      missing_row_field = Marshal.load(Marshal.dump(summary_copy))
      missing_row_field.fetch('full_docs_by_pk').fetch('1').delete('label')
      rejection.call('missing document field', raw_copy, missing_row_field)
      extra_row_field = Marshal.load(Marshal.dump(summary_copy))
      extra_row_field.fetch('full_docs_by_pk').fetch('1')['unexpected'] = true
      rejection.call('extra document field', raw_copy, extra_row_field)
      missing_row = Marshal.load(Marshal.dump(summary_copy))
      missing_row.fetch('full_docs_by_pk').delete('8')
      rejection.call('missing row-domain entry', raw_copy, missing_row)
      extra_row = Marshal.load(Marshal.dump(summary_copy))
      extra_row.fetch('full_docs_by_pk')['9'] = extra_row.fetch('full_docs_by_pk').fetch('1')
      rejection.call('extra row-domain entry', raw_copy, extra_row)
      missing_outer = Marshal.load(Marshal.dump(summary_copy))
      missing_outer.delete('full_docs_by_pk')
      rejection.call('missing outer field', raw_copy, missing_outer)
      extra_outer = Marshal.load(Marshal.dump(summary_copy))
      extra_outer['unexpected'] = true
      rejection.call('extra outer field', raw_copy, extra_outer)
    end
    true
  end

  def authenticate_copy_truncation_failure!(record, details, id, table, part_path, label)
    require!(id == 'advanced_chunked_s0_negative_copy_truncated' &&
             table.is_a?(String) &&
             table.match?(/\Aw241_[0-9a-f]{8}_#{Regexp.escape(id)}_target\z/) &&
             part_path.is_a?(String) && File.expand_path(part_path) == part_path &&
             File.basename(part_path) == 'all_1_1_0',
      "#{label} failure is not bound to the sealed Copy-truncation target")
    require!(record.fetch('label') == 'negative_full_copy_truncated' &&
             record.fetch('process_kind') == 'clickhouse-local' &&
             record.fetch('process_classification') == 'server_exception' && record.fetch('exit') == 33 &&
             record.fetch('signal').nil? && record.fetch('timed_out') == false &&
             %w[spawn_error stdin_write_error stdout_read_error stderr_read_error].all? { |field| record.fetch(field).nil? },
      "#{label} failed process is not the bounded server-side exit-33 exception")
    expected_stdout = "__W241_PIN__\t#{SOURCE_RUNTIME.fetch('version')}\t#{SOURCE_RUNTIME.fetch('build')}"
    stdout = details.fetch(:stdout)
    require!(stdout.is_a?(String) && stdout.lines.map(&:chomp) == [expected_stdout],
      "#{label} stdout is not exactly the pinned runtime row")
    stderr = details.fetch(:stderr)
    expected_context = "from part #{part_path}/ in table default.#{table} "
    context_lines = stderr.is_a?(String) ? stderr.lines.select { |line| line.include?(expected_context) } : []
    require!(stderr.is_a?(String) && stderr.include?('Code: 33.') && stderr.include?('Cannot read all data') &&
             stderr.include?('(CANNOT_READ_ALL_DATA)') && stderr.include?('(while reading column doc)') &&
             context_lines.size == 1 && context_lines.first.include?('from mark 3 with max_rows_to_read = 2'),
      "#{label} stderr lacks the pinned doc/mark-3 error for the authenticated active part/table")
    true
  rescue KeyError => error
    raise AuditError, "#{label} failure evidence is malformed: #{error.message}"
  end

  def authenticate_copy_truncation_query_sql!(sql, table, label)
    require!(sql.is_a?(String) && table.is_a?(String) &&
             table.match?(/\Aw241_[0-9a-f]{8}_advanced_chunked_s0_negative_copy_truncated_target\z/),
      "#{label} target table is not the sealed Copy-truncation table")
    full_select = lambda do |tag, predicate = nil|
      where = predicate ? " WHERE #{predicate}" : ''
      "SELECT '#{tag}', '#{table}', toString(pk), toTypeName(doc), hex(toJSONString(doc)), " \
        "hex(toJSONString(JSONDynamicPaths(doc))), hex(toJSONString(JSONSharedDataPaths(doc))) " \
        "FROM default.#{table}#{where} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw"
    end
    expected = [
      'SET output_format_json_quote_64bit_integers=0',
      "SELECT '__W241_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw",
      full_select.call('__W241_FULL__'),
      full_select.call('__W241_MIDDLE__', 'pk BETWEEN 3 AND 6'),
      full_select.call('__W241_LAST__', 'pk = 8'),
      "SELECT '__W241_ZERO_QUERY__', toString(count()), hex(toJSONString(groupArray(doc))) " \
        "FROM default.#{table} WHERE pk > 8 SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw",
    ]
    normalized = sql.end_with?("\n") ? sql : "#{sql}\n"
    require!(sql_statements!(normalized, label) == expected,
      "#{label} SQL is not the exact pinned full Copy-truncation query")
    true
  end

  def derive_negative_outcome(kind, direct_status, direct, full_status, full, targeted_copy_failure: false)
    expected_docs = ROWS.each_with_object({}) { |row, result| result[row.fetch(:pk)] = row.fetch(:doc) }
    if kind == 'data_corrupt'
      unless direct_status == 'stage_observed' && full_status == 'stage_observed'
        return {status: 'inconclusive', effect: 'attach_or_direct_or_full_not_observed',
                interpretation: 'No conclusion: attach/CHECK or separate direct/full query did not complete.'}
      end
      direct_rows = direct.fetch(:rows_by_pk)
      direct_except_late = expected_docs.all? do |pk, doc|
        observed = direct_rows.fetch(pk)
        observed.fetch(:arr) == doc.fetch('arr', nil) && observed.fetch(:mixed) == doc.fetch('mixed', nil) &&
          (pk == 8 || observed.fetch(:late) == doc.fetch('late', nil))
      end
      late = direct_rows.fetch(8).fetch(:late)
      expected_late = [{'v' => 80, 'late_only_child' => 'last-chunk-onlz'}]
      full_unchanged = full.fetch(:full_docs_by_pk) == expected_docs
      observed = direct_except_late && late == expected_late && full_unchanged
      {status: observed ? 'negative_control_observed' : 'inconclusive',
       effect: observed ? 'advanced Data late-only payload changed; direct arr/mixed and full Copy stayed original' :
         'negative did not produce the targeted Data-only discriminator',
       interpretation: 'A scoped Data/Copy discriminator only: changed late Data at pk 8 with unchanged arr/mixed and full Object confirms Copy stayed independent for this fixture.'}
    else
      unless direct_status == 'stage_observed'
        return {status: 'inconclusive', effect: 'attach_or_direct_not_observed',
                interpretation: 'No conclusion: attach/CHECK or direct-only query did not complete.'}
      end
      direct_rows = direct.fetch(:rows_by_pk)
      direct_unchanged = expected_docs.all? do |pk, doc|
        row = direct_rows.fetch(pk)
        row.fetch(:arr) == doc.fetch('arr', nil) && row.fetch(:mixed) == doc.fetch('mixed', nil) &&
          row.fetch(:late) == doc.fetch('late', nil)
      end
      full_bad = if full_status == 'process_failed_observed'
                   targeted_copy_failure && full == :authenticated_copy_truncation
                 elsif full_status == 'stage_observed'
                   full.fetch(:full_docs_by_pk) != expected_docs
                 else
                   false
                 end
      observed = direct_unchanged && full_bad
      {status: observed ? 'negative_control_observed' : 'inconclusive',
       effect: observed ? 'direct Data unchanged; full Copy was unreadable or differed' :
         'Copy truncation did not yield a direct-versus-full discriminator',
       interpretation: 'A scoped Copy-consumption discriminator: direct Data stays original while whole-Object Copy consumption must fail or differ.'}
    end
  end

  def authenticate_w241_invocation!(root, record, label)
    require!(record.is_a?(Hash), "#{label} record is malformed")
    record_label = record.fetch('label')
    require!(record_label.is_a?(String) && File.basename(record_label) == record_label &&
             record_label.match?(/\A[a-zA-Z0-9_.-]+\z/), "#{label} label is not a safe artifact stem")
    names = %w[argv_file stdin_file stdout_file stderr_file]
    names.each do |field|
      name = record.fetch(field)
      require!(name.is_a?(String) && File.basename(name) == name && name.match?(/\A[a-zA-Z0-9_.-]+\z/),
        "#{label} #{field} is not a safe local basename")
    end
    artifact_suffixes = {
      'argv_file' => "#{record_label}.argv.json",
      'stdin_file' => "#{record_label}.stdin.#{record['process_kind'] == 'clickhouse-local' ? 'sql' : 'bin'}",
      'stdout_file' => "#{record_label}.stdout",
      'stderr_file' => "#{record_label}.stderr",
    }
    artifact_suffixes.each do |field, expected|
      require!(record.fetch(field) == expected, "#{label} #{field} is not bound to its local artifact stem")
    end
    require!(record['timeout_seconds'] == W185::TIMEOUT && record['termination_grace_seconds'] == W185::GRACE,
      "#{label} timeout bounds differ")
    native = record['process_kind'] == 'clickhouse-local'
    helper = record['process_kind'] == 'crystal-helper'
    compressor = record['process_kind'] == 'clickhouse-compressor'
    require!(native || helper || compressor, "#{label} process kind is unrostered")
    binary_path = record.fetch('binary_path')
    require!(binary_path.is_a?(String) && File.file?(binary_path) && !File.symlink?(binary_path) && File.executable?(binary_path),
      "#{label} executable is absent or unsafe")
    observed_binary_sha = Digest::SHA256.file(binary_path).hexdigest
    if native
      require!(record['max_threads'] == 1 && record['max_memory_usage_bytes'] == W185::MEMORY &&
               record['max_memory_usage_applicable'] == true &&
               record['expected_binary_sha256'] == SOURCE_RUNTIME.fetch('sha256') &&
               record['binary_sha_before'] == SOURCE_RUNTIME.fetch('sha256') &&
               record['binary_sha_after'] == SOURCE_RUNTIME.fetch('sha256') &&
               observed_binary_sha == SOURCE_RUNTIME.fetch('sha256'), "#{label} native identity/bounds differ")
    end
    if helper
      require!(record['max_threads'].nil? && record['max_memory_usage_bytes'].nil? &&
               record['max_memory_usage_applicable'] == false &&
               record['expected_binary_sha256'] == record['binary_sha_before'] &&
               record['binary_sha_before'] == record['binary_sha_after'] &&
               observed_binary_sha == record['binary_sha_after'], "#{label} helper identity differs")
    end
    if compressor
      require!(record['max_threads'] == 1 && record['max_memory_usage_bytes'].nil? &&
               record['max_memory_usage_applicable'] == false &&
               record['expected_binary_sha256'] == SOURCE_RUNTIME.fetch('sha256') &&
               record['binary_sha_before'] == SOURCE_RUNTIME.fetch('sha256') &&
               record['binary_sha_after'] == SOURCE_RUNTIME.fetch('sha256') &&
               observed_binary_sha == SOURCE_RUNTIME.fetch('sha256'), "#{label} compressor identity/bounds differ")
    end
    argv = record.fetch('argv')
    require!(argv.is_a?(Array) && argv[0] == record.fetch('binary_path'), "#{label} argv executable differs")
    if native
      require!(argv.size == 8 && argv[1] == 'local' && argv[3] == File.join(root, 'stores', 'native') &&
               argv.include?('--max_threads=1') && argv.include?("--max_memory_usage=#{W185::MEMORY}") &&
               argv.include?('--multiquery'), "#{label} is not bounded isolated clickhouse-local")
      require!(record['store_path'] == File.join(root, 'stores', 'native'), "#{label} native store differs")
    elsif helper
      require!(argv.size == 3 && record['max_memory_usage_applicable'] == false, "#{label} helper argv differs")
    else
      require!(argv == [binary_path, 'compressor', '--decompress', '--threads=1'] &&
               record['max_threads'] == 1 && record['store_path'].nil?,
        "#{label} is not the pinned bounded decompressor")
    end
    invocations = File.join(root, 'invocations')
    argv_bytes = read_plain(File.join(invocations, record.fetch('argv_file')), 1024 * 1024, "#{label} argv")
    require!(sha256(argv_bytes) == record.fetch('argv_sha256') && JSON.parse(argv_bytes) == argv,
      "#{label} argv digest/contents differ")
    input = read_plain(File.join(invocations, record.fetch('stdin_file')), 16 * 1024 * 1024, "#{label} stdin")
    stdout = read_plain(File.join(invocations, record.fetch('stdout_file')), 16 * 1024 * 1024, "#{label} stdout")
    stderr = read_plain(File.join(invocations, record.fetch('stderr_file')), 16 * 1024 * 1024, "#{label} stderr")
    require!(sha256(input) == record.fetch('stdin_sha256') && input.bytesize == record.fetch('stdin_bytes') &&
             sha256(stdout) == record.fetch('stdout_sha256') && stdout.bytesize == record.fetch('stdout_bytes') &&
             sha256(stderr) == record.fetch('stderr_sha256') && stderr.bytesize == record.fetch('stderr_bytes'),
      "#{label} artifact digest/size differs")
    artifact_record = JSON.parse(read_plain(File.join(invocations, "#{record_label}.json"), 1024 * 1024,
      "#{label} invocation JSON"))
    require!(artifact_record == record, "#{label} invocation JSON differs")
    if native
      require!(input.include?('output_format_json_quote_64bit_integers=0'), "#{label} SQL lacks fixed integer rendering")
      if record['process_classification'] == 'success'
        require!(record['exit'] == 0 && record['signal'].nil? && !record['timed_out'] && stderr.empty?,
          "#{label} successful native process lacks exact runtime/output evidence")
        audit_native_runtime_pin!(stdout, '__W241_PIN__', label)
      else
        require!(record['process_classification'] != 'success', "#{label} failure classification is contradictory")
      end
    else
      if helper
        require!(record['process_classification'] == 'success' && record['exit'] == 0 && stderr.empty?,
          "#{label} helper process did not complete cleanly")
      else
        require!(record['process_classification'] == 'success' && record['exit'] == 0 &&
                 record['signal'].nil? && !record['timed_out'] && stderr.empty? &&
                 stdout.bytesize <= 1024 * 1024 && input.bytesize <= MAX_PART_FILE_BYTES,
          "#{label} bounded compressor process did not complete cleanly")
      end
    end
    {argv: argv,
     input: compressor ? input.b : input.force_encoding(Encoding::UTF_8),
     stdout: compressor ? stdout.b : stdout.force_encoding(Encoding::UTF_8),
     stderr: stderr.force_encoding(Encoding::UTF_8)}
  rescue KeyError, JSON::ParserError => error
    raise AuditError, "#{label} invocation evidence is malformed: #{error.message}"
  end

  def audit_w241_profile!(root, profile, helper_profile, helper_input_profile, by_label, w240,
                          requested_frame_bytes:)
    id = profile.fetch('id')
    layout_id, string_id = id.split('_s', 2)
    layout = LAYOUTS.find { |entry| entry.fetch(:id) == layout_id } || raise(AuditError, "#{id} layout is unrostered")
    string_version = Integer(string_id, 10)
    require!(profile['status'] == 'paired_stock_crystal_observed' && profile['shared_version'] == layout.fetch(:enum) &&
             profile['string_profile'] == "s#{string_version}", "#{id} profile status or setting differs")
    require!(helper_profile['id'] == id && helper_profile['shared_version'] == layout.fetch(:enum) &&
             helper_profile['string_profile'] == "s#{string_version}", "#{id} helper profile differs")
    require!(helper_profile.fetch('writer').fetch('requested_frame_bytes') == requested_frame_bytes,
      "#{id} writer frame_bytes witness differs from the coordinator request")
    source = helper_profile.fetch('source_read')
    generated = helper_profile.fetch('generated_read')
    authenticate_helper_read_roles!(source, generated, id)
    expected_rows = ROWS.map { |row| {'pk' => row.fetch(:pk), 'doc' => row.fetch(:doc)} }
    [source, generated].each_with_index do |read, index|
      role = index.zero? ? 'stock source' : 'Crystal generated'
      require!(read.fetch('full_rows') == expected_rows, "#{id} #{role} full-object logical rows differ")
      assert_helper_direct!(read, id, role)
      assert_helper_type_witnesses!(read, id, role)
      audit_bounded_windows!(read, id, role)
      require!(read['actual_shared_data_version'] == layout.fetch(:enum) &&
               read['ordinary_string_profile'] == string_version &&
               read.dig('serialization_json', 'types_serialization_versions', 'string') == string_version &&
               read['mark_row_counts'] == REAL_MARK_ROWS, "#{id} #{role} real reader mark metadata differs")
      expected_semantics = layout.fetch(:enum) < 2 ? 'bounded selected shared MAP lane; not physically selective' :
        'selected shared Data path; whole-Object read was performed by a separate reader'
      require!(read['direct_shared_path_semantics'] == expected_semantics, "#{id} #{role} path stage semantics label differs")
    end
    require!(profile.fetch('source_stock_part').fetch('path') == source.fetch('part_path'), "#{id} source path differs")
    require!(File.expand_path(helper_input_profile.fetch('source_part')) == File.expand_path(source.fetch('part_path')) &&
             helper_input_profile.fetch('shared_version') == layout.fetch(:enum) &&
             helper_input_profile.fetch('string_profile') == "s#{string_version}", "#{id} helper input binding differs")
    if string_version == 1
      expected_source = w240.fetch(:profiles).fetch(layout.fetch(:id)).fetch(:part_path)
      require!(source.fetch('part_path') == expected_source, "#{id} reused source is not the authenticated W240 part")
    else
      require!(source.fetch('part_path') == profile.fetch('source_stock_part').fetch('path') &&
               source.fetch('part_path').start_with?(File.join(root, 'stores', 'native') + File::SEPARATOR),
        "#{id} fresh source part escaped local store")
    end
    require!(generated.fetch('part_path') == File.join(root, 'generated', id, 'all_1_1_0'),
      "#{id} generated part is not in the exact helper destination")
    assert_inventory_projection!(profile.fetch('source_helper_inventory'),
      helper_inventory_projection(source, layout.fetch(:id)), "#{id} source")
    assert_inventory_projection!(profile.fetch('crystal_generated_part').fetch('inventory'),
      helper_inventory_projection(generated, layout.fetch(:id)), "#{id} generated")
    decode_manifest = profile.fetch('native_stream_decodes')
    source_physical = audit_helper_part!(source, layout, "#{id} stock source", root: root,
      by_label: by_label, profile_id: id, role: 'source', native_decodes: decode_manifest.fetch('source'),
      requested_frame_bytes: requested_frame_bytes)
    generated_physical = audit_helper_part!(generated, layout, "#{id} Crystal generated", root: root,
      by_label: by_label, profile_id: id, role: 'generated', native_decodes: decode_manifest.fetch('generated'),
      requested_frame_bytes: requested_frame_bytes)
    assert_physical_projection!(profile.fetch('source_helper_physical_layout'), source_physical, "#{id} source")
    assert_physical_projection!(profile.fetch('crystal_generated_part').fetch('physical_layout'), generated_physical, "#{id} generated")
    source_native_results = {}
    source_creation = nil
    %w[write direct full].each do |stage|
      next if string_version == 1
      record = find_source_record(profile, stage)
      if stage != 'write'
        require!(record.fetch('status') == 'stage_observed', "#{id} source #{stage} was not observed")
        record = record.fetch('invocation')
      end
      details = authenticate_w241_invocation!(root, by_label.fetch("source_#{stage}_#{id}"), "#{id} source #{stage}")
      require!(record == by_label.fetch("source_#{stage}_#{id}"), "#{id} source #{stage} reference differs")
      if stage == 'write'
        source_creation = audit_source_stage_output!(details, stage, id, layout, string_version, root)
        authenticate_source_part_path!(source.fetch('part_path'), source_creation.fetch(:part_path), id)
      else
        require!(source_creation.is_a?(Hash), "#{id} source #{stage} has no authenticated write")
        observation = audit_source_stage_output!(details, stage, id, layout, string_version, root,
          expected_table: source_creation.fetch(:table))
      end
      source_native_results[stage] = observation if %w[direct full].include?(stage)
    end
    target = profile.fetch('native_attach_check_schema')
    create = target.fetch('create')
    attach = target.fetch('attach_check')
    require!(create == by_label.fetch("target_create_#{id}") && attach == by_label.fetch("target_attach_check_#{id}"),
      "#{id} target invocation references differ")
    create_details = authenticate_w241_invocation!(root, create, "#{id} target create")
    attach_details = authenticate_w241_invocation!(root, attach, "#{id} target attach/CHECK")
    origin = audit_generated_target_create!(create_details, id, layout, string_version, "#{id} target", root)
    store_root = File.join(root, 'stores', 'native')
    target_data_path = canonical_child(origin.fetch(:data_path), store_root, "#{id} target data path")
    authenticate_generated_attach_sql!(attach_details.fetch(:input), id, origin.fetch(:table), "#{id} target")
    attached_part = audit_attached_check_schema!(attach_details.fetch(:stdout), id,
      origin.fetch(:table), store_root)
    authenticate_target_part_path!(target_data_path, attached_part, "#{id} target")
    audit_attached_copy!(generated.fetch('part_path'), generated.fetch('physical_file_inventory'),
      attached_part, "#{id} generated target")
    generated_native_results = {}
    %w[direct full].each do |stage|
      label = "generated_#{stage}_#{id}"
      query = authenticate_w241_invocation!(root, by_label.fetch(label), "#{id} generated #{stage}")
      stage_record = profile.fetch('native_queries').fetch(stage == 'full' ? 'full_middle_last_zero' : 'direct')
      require!(stage_record.fetch('status') == 'stage_observed' && stage_record.fetch('invocation') == by_label.fetch(label),
        "#{id} generated #{stage} stage reference/status differs")
      authenticate_generated_query_table!(query.fetch(:input), stage, origin.fetch(:table), id,
        "#{id} generated #{stage}")
      generated_native_results[stage] = audit_w241_query_output!(query, stage, id,
        origin.fetch(:table), positive: true)
    end
    if source_native_results.key?('full')
      assert_helper_full_rows_match_native!(source, source_native_results.fetch('full'), id, 'stock source')
      assert_helper_direct_types_match_native!(source, source_native_results.fetch('direct'), id, 'stock source')
    end
    assert_helper_full_rows_match_native!(generated, generated_native_results.fetch('full'), id, 'Crystal generated')
    assert_helper_direct_types_match_native!(generated, generated_native_results.fetch('direct'), id, 'Crystal generated')
    true
  rescue KeyError, ArgumentError => error
    raise AuditError, "W241 #{id} profile is malformed: #{error.message}"
  end

  def find_source_record(profile, stage)
    profile.fetch('source_stock_part').fetch('native_stages').fetch(stage)
  end

  def helper_inventory_projection(read, layout_id)
    audit_helper_columns_schema!(read, layout_id, "#{layout_id} helper inventory projection")
    roster = audit_helper_stream_roster!(read, layout_id, "#{layout_id} helper inventory projection")
    part_path = read.fetch('part_path')
    require!(File.directory?(part_path) && !File.symlink?(part_path) && File.realpath(part_path) == part_path,
      "#{layout_id} helper inventory part path is noncanonical")
    pk_mark_name = "#{stream_hash('pk')}.mrk2"
    pk_mark_entry = read.fetch('physical_file_inventory').find { |item| item.fetch('name') == pk_mark_name }
    require!(!pk_mark_entry.nil?, "#{layout_id} helper inventory pk mark file is absent")
    pk_mark_bytes = read_plain(File.join(part_path, pk_mark_name), MAX_PART_FILE_BYTES,
      "#{layout_id} helper inventory pk mark")
    require!(pk_mark_bytes.bytesize == pk_mark_entry.fetch('size') &&
             sha256(pk_mark_bytes) == pk_mark_entry.fetch('sha256'),
      "#{layout_id} helper inventory pk mark file differs from its physical inventory")
    pk_mark_words = pk_mark_bytes.unpack('Q<*')
    require!((pk_mark_words.size % 3).zero?, "#{layout_id} helper inventory pk mark triples are incomplete")
    pk_mark_triples = pk_mark_words.each_slice(3).to_a
    audit_physical_mark_grid!(pk_mark_triples, "#{layout_id} helper inventory pk")
    mark_triples = {'pk' => pk_mark_triples}
    read.fetch('mark_triples').each { |stream, triples| mark_triples[stream] = triples }
    {
      'path' => read.fetch('part_path'),
      'physical_file_names' => read.fetch('physical_file_inventory').map { |item| item.fetch('name') }.sort,
      'complete_file_inventory' => read.fetch('physical_file_inventory').each_with_object({}) do |item, result|
        result[item.fetch('name')] = {'size' => item.fetch('size'), 'sha256' => item.fetch('sha256')}
      end,
      'logical_substreams' => roster.fetch(:logical_substreams),
      'object_substreams' => roster.fetch(:object_substreams),
      'columns_substreams_text' => read.fetch('columns_substreams_text'),
      'columns_text' => read.fetch('columns_text'), 'count_text' => read.fetch('count_text'),
      'serialization_json' => read.fetch('serialization_json'),
      'serialization_json_sha256' => read.fetch('serialization_json_sha256'),
      'checksums_sha256' => read.fetch('checksums_sha256'),
      'ordinary_string_serialization_version' => read.fetch('ordinary_string_profile'),
      'mark_triples' => mark_triples,
    }
  end

  def assert_inventory_projection!(reported, actual, label)
    %w[path physical_file_names complete_file_inventory logical_substreams object_substreams
       columns_substreams_text columns_text
       count_text serialization_json serialization_json_sha256 checksums_sha256
       ordinary_string_serialization_version mark_triples].each do |key|
      require!(reported.fetch(key) == actual.fetch(key), "#{label} #{key} inventory projection differs")
    end
  end

  def assert_physical_projection!(reported, actual, label)
    require!(reported.fetch('header').fetch('shared_data_version') == actual.fetch(:header).fetch(:shared_data_version) &&
             reported.fetch('header').fetch('bucket_count') == actual.fetch(:header).fetch(:bucket_count) &&
             reported.fetch('family') == actual.fetch(:family) &&
             reported.fetch('bucket_ids') == actual.fetch(:bucket_ids), "#{label} physical layout differs from actual stream bytes")
    chunks = actual.fetch(:physical)[:chunks]
    if chunks
      reported_chunks = reported.fetch('physical').fetch('chunks').fetch('observed_rows_per_chunk')
      require!(reported_chunks == chunks.fetch(:observed_rows_per_chunk), "#{label} actual chunk schedule differs")
    end
    true
  end

  def assert_helper_direct!(read, id, role)
    paths = read.fetch('direct_shared_path_rows')
    expected = {
      'arr' => ROWS.map { |row| {'pk' => row.fetch(:pk), 'value' => row.fetch(:doc).fetch('arr', nil)} },
      'mixed' => ROWS.map { |row| {'pk' => row.fetch(:pk), 'value' => row.fetch(:doc).fetch('mixed', nil)} },
      'late' => ROWS.map { |row| {'pk' => row.fetch(:pk), 'value' => row.fetch(:doc).fetch('late', nil)} },
    }
    expected.each do |path, rows|
      actual = paths.fetch(path).map { |entry| {'pk' => entry.fetch('pk'), 'value' => entry.fetch('value')} }
      require!(actual == rows, "#{id} #{role} direct #{path} logical rows differ")
    end
    empty = paths.fetch('arr').find { |row| row.fetch('pk') == 3 }
    require!(empty.fetch('value') == [] && empty.fetch('type') == 'Array(Nullable(String))',
      "#{id} #{role} empty-array carrier differs")
    true
  end

  def assert_helper_full_rows_match_native!(read, native_observation, id, role)
    native_rows = native_observation.fetch(:full_docs_by_pk)
    helper_rows = read.fetch('full_rows').to_h do |row|
      [Integer(row.fetch('pk')), row.fetch('doc')]
    end
    require!(helper_rows == native_rows, "#{id} #{role} bounded-window base rows differ from native full readback")
    true
  rescue KeyError, ArgumentError, TypeError => error
    raise AuditError, "#{id} #{role} full-row cross-binding is malformed: #{error.message}"
  end

  def assert_helper_direct_types_match_native!(read, native_observation, id, role)
    expected_role = case role
                    when 'stock source' then 'stock_source'
                    when 'Crystal generated' then 'crystal_generated'
                    else raise AuditError, "#{id} direct type bridge has an unrostered role"
                    end
    require!(PROFILE_IDS.include?(id) && read.fetch('role') == expected_role,
      "#{id} direct type bridge is not bound to its authenticated helper role")
    native_rows = native_observation.fetch(:rows_by_pk)
    paths = read.fetch('direct_shared_path_rows')
    require!(paths.is_a?(Hash) && paths.keys.sort == %w[arr late mixed],
      "#{id} #{role} direct path roster differs")
    %w[arr mixed late].each do |path|
      type_key = "#{path}_type".to_sym
      wrapper_key = "#{path}_wrapper_type".to_sym
      require!(paths.fetch(path).is_a?(Array) && paths.fetch(path).size == ROWS.size,
        "#{id} #{role} direct #{path} row roster differs")
      seen_pks = {}
      paths.fetch(path).each do |row|
        pk = Integer(row.fetch('pk'))
        require!(!seen_pks.key?(pk), "#{id} #{role} direct #{path} duplicates pk #{pk}")
        seen_pks[pk] = true
        native = native_rows.fetch(pk)
        require!(row.fetch('wrapper_type') == 'Dynamic(max_types=254)' &&
                 native.fetch(wrapper_key) == 'Dynamic',
          "#{id} #{role} #{path} carrier/logical wrapper boundary differs")
        require!(row.fetch('type') == native.fetch(type_key) &&
                 row.fetch('value') == native.fetch(path.to_sym),
          "#{id} #{role} #{path} child type or value differs from native direct readback")
      end
      require!(seen_pks.keys.sort == ROWS.map { |entry| entry.fetch(:pk) },
        "#{id} #{role} direct #{path} pk domain differs")
    end
    true
  rescue KeyError, ArgumentError, TypeError => error
    raise AuditError, "#{id} #{role} direct type cross-binding is malformed: #{error.message}"
  end

  def audit_bounded_windows!(read, id, role)
    windows = read.fetch('bounded_windows')
    require!(windows.is_a?(Array) && windows.size == 16,
      "#{id} #{role} bounded-window roster is not the exact 16-record matrix")
    require!(read.fetch('mark_row_counts') == REAL_MARK_ROWS,
      "#{id} #{role} reader mark metadata includes the physical EOF sentinel")

    specs = {
      'middle' => {first_mark: 1, mark_count: 2, rows: [2, 2]},
      'last' => {first_mark: 3, mark_count: 1, rows: [2]},
      'empty_interior' => {first_mark: 2, mark_count: 0, rows: []},
      'zero_count_end' => {first_mark: 4, mark_count: 0, rows: []},
    }
    consumers = [['whole_object', nil]] + %w[arr mixed late].map { |path| ['selected_path', path] }
    expected_keys = consumers.flat_map do |consumer, path|
      specs.keys.map { |window| [consumer, path, window] }
    end
    required_fields = %w[consumer path window first_mark mark_count expected_mark_row_counts
                         actual_mark_row_counts expected_rows actual_rows matches_full_slice].sort
    by_key = {}
    windows.each do |entry|
      require!(entry.is_a?(Hash) && entry.keys.sort == required_fields,
        "#{id} #{role} bounded-window record fields differ")
      consumer = entry.fetch('consumer')
      path = entry.fetch('path')
      window = entry.fetch('window')
      key = [consumer, path, window]
      require!(expected_keys.include?(key) && !by_key.key?(key),
        "#{id} #{role} bounded-window identity is extra or duplicated")
      by_key[key] = entry
    end
    require!(expected_keys.all? { |key| by_key.key?(key) },
      "#{id} #{role} bounded-window identity matrix is incomplete")

    whole_rows = read.fetch('full_rows')
    path_rows = read.fetch('direct_shared_path_rows')
    require!(whole_rows.is_a?(Array) && path_rows.is_a?(Hash),
      "#{id} #{role} full-reader rows are malformed")
    consumers.each do |consumer, path|
      full_rows = consumer == 'whole_object' ? whole_rows : path_rows.fetch(path)
      require!(full_rows.is_a?(Array) && full_rows.size == ROWS.size,
        "#{id} #{role} #{consumer}/#{path} full-reader row domain differs")
      specs.each do |window, spec|
        entry = by_key.fetch([consumer, path, window])
        first_mark = entry.fetch('first_mark')
        mark_count = entry.fetch('mark_count')
        require!(first_mark.is_a?(Integer) && mark_count.is_a?(Integer) &&
                 first_mark == spec.fetch(:first_mark) && mark_count == spec.fetch(:mark_count),
          "#{id} #{role} #{consumer}/#{path}/#{window} mark coordinates differ")
        expected_mark_rows = spec.fetch(:rows)
        require!(entry.fetch('expected_mark_row_counts') == expected_mark_rows &&
                 entry.fetch('actual_mark_row_counts') == expected_mark_rows,
          "#{id} #{role} #{consumer}/#{path}/#{window} mark-row counts differ")

        row_start = REAL_MARK_ROWS.take(first_mark).sum
        row_count = expected_mark_rows.sum
        full_slice = full_rows.slice(row_start, row_count) || []
        expected_rows = entry.fetch('expected_rows')
        actual_rows = entry.fetch('actual_rows')
        require!(expected_rows.is_a?(Array) && actual_rows.is_a?(Array) &&
                 expected_rows == full_slice && actual_rows == full_slice,
          "#{id} #{role} #{consumer}/#{path}/#{window} rows differ from the authenticated full-reader slice")
        require!(entry.fetch('matches_full_slice') == true && actual_rows == full_slice,
          "#{id} #{role} #{consumer}/#{path}/#{window} full-slice equality witness is false or forged")
      end
    end
    true
  rescue KeyError, ArgumentError, TypeError => error
    raise AuditError, "#{id} #{role} bounded-window witness is malformed: #{error.message}"
  end

  def assert_helper_type_witnesses!(read, id, role)
    rows = read.fetch('nested_type_witnesses')
    row_one = rows.find { |row| row.fetch('pk') == 1 } || raise(AuditError, "#{id} #{role} nested row 1 witness absent")
    row_eight = rows.find { |row| row.fetch('pk') == 8 } || raise(AuditError, "#{id} #{role} nested row 8 witness absent")
    [['arr', row_one], ['late', row_eight]].each do |path, row|
      witness = row.fetch('paths').fetch(path)
      outer = witness.fetch('outer_type')
      element = witness.fetch('element_type')
      require!(outer == 'Array(JSON)' || outer.match?(/\AArray\(JSON\(.*\)\)\z/) , "#{id} #{role} #{path} outer type absent")
      require!(element == 'JSON' || element.start_with?('JSON('), "#{id} #{role} #{path} element type absent")
      children = witness.fetch('first_element_child_types')
      expected_names = path == 'arr' ? %w[s v] : %w[late_only_child v]
      require!(children.keys.sort == expected_names && !children.fetch('v').empty?, "#{id} #{role} #{path} actual child types absent")
      if role == 'Crystal generated'
        require!(children.fetch('v') == 'UInt8', "#{id} generated #{path}.v is not the prepared UInt8 child")
        child = path == 'arr' ? 's' : 'late_only_child'
        require!(children.fetch(child) == 'String', "#{id} generated #{path}.#{child} is not the dynamic String child")
      end
    end
    true
  end

  def audit_helper_part!(read, layout, label, root:, by_label:, profile_id:, role:, native_decodes:,
                        requested_frame_bytes:)
    path = read.fetch('part_path')
    evidence_root = root
    part_root = File.realpath(path)
    require!(part_root == path && File.directory?(part_root) && !File.symlink?(part_root), "#{label} part path is noncanonical")
    tree = plain_tree!(part_root, label)
    inventory = read.fetch('physical_file_inventory')
    names = inventory.map { |item| item.fetch('name') }.sort
    require!(names == Dir.children(part_root).sort, "#{label} part file roster differs")
    inventory.each do |item|
      name = item.fetch('name')
      require!(File.basename(name) == name && name.match?(/\A[a-zA-Z0-9_.-]+\z/), "#{label} part filename unsafe")
      bytes = read_plain(File.join(part_root, name), MAX_PART_FILE_BYTES, "#{label} #{name}")
      require!(bytes.bytesize == item.fetch('size') && sha256(bytes) == item.fetch('sha256'), "#{label} part digest differs: #{name}")
    end
    require!(tree.fetch(:files) == names.size && tree.fetch(:bytes) == inventory.sum { |item| item.fetch('size') },
      "#{label} part tree bounds/inventory differ")
    columns = read_plain(File.join(part_root, 'columns_substreams.txt'), MAX_PART_FILE_BYTES, "#{label} columns_substreams")
    require!(columns.force_encoding(Encoding::UTF_8) == read.fetch('columns_substreams_text'), "#{label} columns_substreams bytes differ")
    roster = audit_helper_stream_roster!(read, layout.fetch(:id), label)
    logical = roster.fetch(:logical_substreams)
    object_substreams = roster.fetch(:object_substreams)
    assert_physical_stream_file_roster!(names, logical, label)
    columns_text = read_plain(File.join(part_root, 'columns.txt'), MAX_PART_FILE_BYTES, "#{label} columns")
    columns_text = columns_text.force_encoding(Encoding::UTF_8)
    expected_columns = expected_w241_part_columns_text(profile_id, role, label)
    helper_columns = audit_helper_columns_schema!(read, layout.fetch(:id), label)
    require!(helper_columns == expected_columns && columns_text == expected_columns && read.fetch('columns_text') == expected_columns,
      "#{label} columns.txt schema differs")
    count = read_plain(File.join(part_root, 'count.txt'), MAX_PART_FILE_BYTES, "#{label} count").strip
    require!(count == '8' && read.fetch('count_text') == '8', "#{label} count differs")
    serialization = read_plain(File.join(part_root, 'serialization.json'), MAX_PART_FILE_BYTES, "#{label} serialization")
    require!(sha256(serialization) == read.fetch('serialization_json_sha256') &&
             JSON.parse(serialization) == read.fetch('serialization_json') &&
             JSON.parse(serialization).dig('types_serialization_versions', 'string') == read.fetch('ordinary_string_profile'),
      "#{label} serialization metadata differs")
    checksums = read_plain(File.join(part_root, 'checksums.txt'), MAX_PART_FILE_BYTES, "#{label} checksums")
    require!(sha256(checksums) == read.fetch('checksums_sha256'), "#{label} checksums bytes differ")
    marks = read.fetch('mark_triples')
    object_substreams.each do |stream|
      bytes = read_plain(File.join(part_root, "#{stream_hash(stream)}.mrk2"), MAX_PART_FILE_BYTES, "#{label} mark #{stream}")
      words = bytes.unpack('Q<*')
      require!((words.size % 3).zero?, "#{label} mark words incomplete")
      triples = words.each_slice(3).to_a
      expected_triples = marks.fetch(stream).map { |triple| triple.map(&:to_i) }
      audit_physical_mark_triples!(triples, expected_triples, "#{label} #{stream}")
    end
    pk_bytes = read_plain(File.join(part_root, "#{stream_hash('pk')}.mrk2"), MAX_PART_FILE_BYTES, "#{label} pk mark")
    pk_words = pk_bytes.unpack('Q<*')
    require!((pk_words.size % 3).zero?, "#{label} pk mark words are incomplete")
    audit_physical_mark_grid!(pk_words.each_slice(3).to_a, "#{label} pk")
    raw = read.fetch('raw_shared_streams')
    object_substreams.each do |stream|
      entry = raw.fetch(stream)
      stem = stream_hash(stream)
      physical = read_plain(File.join(part_root, "#{stem}.bin"), MAX_PART_FILE_BYTES, "#{label} stream #{stream}")
      file_entry = inventory.find { |item| item.fetch('name') == "#{stem}.bin" } || raise(AuditError, "#{label} raw stream file absent")
      require!(sha256(physical) == file_entry.fetch('sha256') && sha256(physical) == entry.fetch('physical_sha256'),
        "#{label} raw stream physical digest differs: #{stream}")
      hex = entry.fetch('decoded_hex')
      require!(hex.match?(/\A(?:[0-9a-f]{2})*\z/i) && sha256([hex].pack('H*')) == entry.fetch('decoded_sha256'),
        "#{label} raw stream decode digest differs: #{stream}")
    end
    native_streams = audit_native_stream_decodes!(evidence_root, read, layout, profile_id, role, native_decodes, by_label, label)
    physical = audit_w241_physical_layout!(logical, raw, layout, label)
    if layout.fetch(:enum) >= 2
      binding = audit_ordinary_json_binding!(read, logical, physical, native_streams, label,
        requested_frame_bytes: requested_frame_bytes)
      physical[:ordinary_data_binding] = binding
    end
    physical
  rescue KeyError, JSON::ParserError => error
    raise AuditError, "#{label} part evidence is malformed: #{error.message}"
  end

  def audit_physical_mark_triples!(triples, expected_triples, label)
    audit_physical_mark_grid!(triples, label)
    require!(triples == expected_triples, "#{label} physical mark triples differ from helper witness")
    true
  end

  def audit_physical_mark_grid!(triples, label)
    require!(triples.is_a?(Array) && triples.size == PHYSICAL_MARK_ROWS.size &&
             triples.all? { |triple| triple.is_a?(Array) && triple.size == 3 && triple.all? { |word| word.is_a?(Integer) && word >= 0 } } &&
             triples.map { |triple| triple[2] } == PHYSICAL_MARK_ROWS,
      "#{label} physical mark grid differs from the four real marks plus terminal sentinel")
    true
  end

  def audit_native_stream_decodes!(root, read, layout, profile_id, role, native_decodes, by_label, label)
    raw_streams = read.fetch(:raw_shared_streams) { read.fetch('raw_shared_streams') }
    streams = expected_decode_streams(layout.fetch(:id))
    require!(raw_streams.is_a?(Hash) && raw_streams.keys.sort == streams,
      "#{label} raw stream inventory is not the exact semantic roster")
    require!(native_decodes.is_a?(Array) && native_decodes.size == streams.size,
      "#{label} native decompressor manifest is incomplete")
    by_stream = native_decodes.to_h do |entry|
      [entry.fetch('stream'), entry]
    end
    require!(by_stream.keys.sort == streams, "#{label} native decompressor stream roster differs")
    part_path = read.fetch(:part_path) { read.fetch('part_path') }
    part_root = File.realpath(part_path)
    require!(part_root == part_path && File.directory?(part_root) && !File.symlink?(part_root),
      "#{label} part path is noncanonical")
    decoded_streams = {}
    frame_spans = {}
    compressed_sizes = {}
    frame_walker = W190_PROBE.allocate
    streams.each do |stream|
      entry = by_stream.fetch(stream)
      raw = raw_streams.fetch(stream)
      expected_label = native_decode_label(profile_id, role, stream)
      require!(entry.fetch('profile_id') == profile_id && entry.fetch('role') == role &&
               entry.fetch('invocation_label') == expected_label &&
               entry.fetch('physical_file') == raw.fetch('physical_file') &&
               entry.fetch('physical_sha256') == raw.fetch('physical_sha256') &&
               entry.fetch('decoded_bytes') == raw.fetch('decoded_bytes') &&
               entry.fetch('decoded_sha256') == raw.fetch('decoded_sha256'),
        "#{label} native decompressor manifest does not match helper stream evidence: #{stream}")
      record = by_label.fetch(expected_label)
      details = authenticate_w241_invocation!(root, record, "#{label} compressor #{stream}")
      physical = read_plain(File.join(part_root, raw.fetch('physical_file')),
        MAX_PART_FILE_BYTES, "#{label} physical compressed stream #{stream}")
      frames = frame_walker.send(:compressed_frame_spans!, physical, "#{label} #{stream}")
      require!(frames.fetch(:decoded_size) <= 1024 * 1024, "#{label} decoded stream exceeds the W241 limit: #{stream}")
      decoded_hex = raw.fetch('decoded_hex')
      require!(decoded_hex.is_a?(String) && decoded_hex.match?(/\A(?:[0-9a-f]{2})*\z/),
        "#{label} helper raw stream is malformed: #{stream}")
      decoded = [decoded_hex].pack('H*')
      require!(details.fetch(:input) == physical && sha256(physical) == entry.fetch('physical_sha256'),
        "#{label} compressor stdin is not the actual physical stream: #{stream}")
      require!(details.fetch(:stdout) == decoded && details.fetch(:stdout).bytesize == entry.fetch('decoded_bytes') &&
               sha256(details.fetch(:stdout)) == entry.fetch('decoded_sha256'),
        "#{label} compressor stdout differs from the helper raw stream witness: #{stream}")
      decoded_streams[stream] = details.fetch(:stdout)
      frame_spans[stream] = frames.fetch(:spans)
      compressed_sizes[stream] = physical.bytesize
    end
    {decoded_streams: decoded_streams, frame_spans: frame_spans, compressed_sizes: compressed_sizes}
  rescue KeyError, JSON::ParserError => error
    raise AuditError, "#{label} native decompressor evidence is malformed: #{error.message}"
  end

  def audit_w241_physical_layout!(logical, raw, layout, label)
    prefix = 'doc.object_shared_data'
    shared = logical.grep(/\A#{Regexp.escape(prefix)}(?:\.|%2E)/)
    buckets = shared.map { |name| /\A#{Regexp.escape(prefix)}\.(\d+)(?:\.|%2E)/.match(name) }.compact.map { |match| Integer(match[1], 10) }.uniq.sort
    structure = raw.fetch('doc.object_structure')
    header = parse_object_header([structure.fetch('decoded_hex')].pack('H*'), "#{label} object structure")
    require!(header.fetch(:shared_data_version) == layout.fetch(:enum), "#{label} actual wire version differs")
    require!(header.fetch(:bucket_count) == (layout.fetch(:enum) == 0 ? 1 : 2), "#{label} actual bucket count differs")
    physical = case layout.fetch(:enum)
    when 0
      lanes = ["#{prefix}.size0", "#{prefix}%2Epaths", "#{prefix}%2Evalues"]
      require!((lanes - logical).empty? && buckets.empty? && shared.none? { |name| name.include?('.data') || name.include?('.copy.') },
        "#{label} actual MAP lanes differ")
      {family: 'map', bucket_ids: [], lanes: lanes}
    when 1
      require!(buckets == [0, 1], "#{label} actual MAP bucket roster differs")
      lanes = [0, 1].flat_map { |bucket| ["#{prefix}.#{bucket}.size0", "#{prefix}.#{bucket}%2Epaths", "#{prefix}.#{bucket}%2Evalues"] }
      require!((lanes - logical).empty?, "#{label} actual bucket lanes differ")
      {family: 'map_with_buckets', bucket_ids: buckets, lanes: lanes}
    when 2, 3
      require!(buckets == [0, 1], "#{label} actual ADVANCED bucket roster differs")
      data = [0, 1].map { |bucket| "#{prefix}.#{bucket}.data" }
      copy = %w[sizes paths_indexes values].map { |suffix| "#{prefix}.copy.#{suffix}" }
      require!((data + copy).all? { |name| logical.include?(name) }, "#{label} actual advanced Data/Copy lane absent")
      schedules = []
      chunks_by_bucket = {}
      [0, 1].each do |bucket|
        name = "#{prefix}.#{bucket}.structure"
        decoded = [raw.fetch(name).fetch('decoded_hex')].pack('H*')
        records = W191.parse_combined_structure(decoded, "#{label} #{name}")
        require!(records.sum { |record| record.fetch(:rows) } == 8, "#{label} chunk schedule does not cover eight rows")
        schedules << records.map { |record| record.fetch(:rows) }
        chunks_by_bucket[bucket.to_s] = records.map { |record| {rows: record.fetch(:rows), paths: record.fetch(:paths)} }
      end
      require!(schedules.uniq.size == 1, "#{label} advanced bucket chunk schedules differ")
      require!(raw.fetch("#{prefix}.copy.sizes").fetch('decoded_hex') && raw.fetch("#{prefix}.copy.values").fetch('decoded_hex'),
        "#{label} Copy streams are not decoded evidence")
      {family: layout.fetch(:setting), bucket_ids: buckets, data: data, copy: copy,
       chunks: {chunks_by_bucket: chunks_by_bucket, actual_chunk_count_per_bucket: schedules.first.size,
                observed_rows_per_chunk: schedules.first}}
    end
    {header: header, family: physical.fetch(:family), bucket_ids: buckets,
     shared_streams: shared.sort, physical: physical}
  end

  # Independently walk the authenticated physical Data/Substreams lanes and
  # outer mark coordinates. The helper's Dynamic roster is accepted only when
  # it is attached to these exact per-path bytes and getter callbacks.
  def audit_ordinary_json_binding!(read, logical, physical_layout, native_streams, label,
                                   requested_frame_bytes:)
    prefix = 'doc.object_shared_data'
    parts = read.fetch('part_path')
    marks = read.fetch('mark_triples')
    raw = read.fetch('raw_shared_streams')
    decoded = native_streams.fetch(:decoded_streams)
    frames = native_streams.fetch(:frame_spans)
    compressed_sizes = native_streams.fetch(:compressed_sizes)
    occurrences = []
    [0, 1].each do |bucket|
      names = {
        structure: "#{prefix}.#{bucket}.structure",
        data: "#{prefix}.#{bucket}.data",
        paths_marks: "#{prefix}.#{bucket}.paths_marks",
        substreams: "#{prefix}.#{bucket}.substreams",
        substreams_marks: "#{prefix}.#{bucket}.substreams_marks",
        metadata: "#{prefix}.#{bucket}.paths_substreams_metadata",
      }
      names.each_value do |stream|
        require!(logical.include?(stream) && decoded.key?(stream), "#{label} missing authenticated advanced lane #{stream}")
      end
      lane_bytes = names.each_with_object({}) { |(lane, stream), result| result[lane] = decoded.fetch(stream) }
      decoded_sizes_by_stream = names.each_with_object({}) do |(_lane, stream), result|
        result[stream] = decoded.fetch(stream).bytesize
      end
      lane_positions = names.each_with_object({}) do |(lane, stream), result|
        triples = marks.fetch(stream).map { |triple| triple.map { |value| Integer(value) } }
        require!(triples.size == 5 && triples.map { |triple| triple.fetch(2) } == [2, 2, 2, 2, 0],
          "#{label} #{stream} physical mark grid differs")
        result[lane] = triples.map do |compressed_offset, in_block_offset, _rows|
          W191.decode_coordinate([compressed_offset, in_block_offset], frames.fetch(stream),
            compressed_sizes.fetch(stream), lane_bytes.fetch(lane).bytesize, "#{label} #{stream} mark")
        end
      end
      4.times do |parent_mark|
        starts = lane_positions.transform_values { |positions| positions.fetch(parent_mark) }
        ends = lane_positions.transform_values { |positions| positions.fetch(parent_mark + 1) }
        cursors = starts.dup
        structure_start = starts.fetch(:structure)
        structure_end = ends.fetch(:structure)
        require!(structure_start >= 0 && structure_end > structure_start && structure_end <= lane_bytes.fetch(:structure).bytesize,
          "#{label} bucket #{bucket} parent structure interval is invalid")
        records = W191.parse_combined_structure(
          lane_bytes.fetch(:structure).byteslice(structure_start, structure_end - structure_start),
          "#{label} bucket #{bucket} parent #{parent_mark} structure",
        )
        require!(records.sum { |record| record.fetch(:rows) } == 2,
          "#{label} bucket #{bucket} parent #{parent_mark} chunk rows differ from its physical mark")
        records.each_with_index do |record, chunk_index|
          pairs = record.fetch(:transport_pairs)
          data_start = W191.decode_coordinate(pairs.fetch(:data), frames.fetch(names.fetch(:data)),
            compressed_sizes.fetch(names.fetch(:data)), lane_bytes.fetch(:data).bytesize,
            "#{label} bucket #{bucket} chunk Data start")
          paths_start = W191.decode_coordinate(pairs.fetch(:paths_marks), frames.fetch(names.fetch(:paths_marks)),
            compressed_sizes.fetch(names.fetch(:paths_marks)), lane_bytes.fetch(:paths_marks).bytesize,
            "#{label} bucket #{bucket} chunk PathsMarks start")
          metadata_start = W191.decode_coordinate(pairs.fetch(:paths_substreams_metadata), frames.fetch(names.fetch(:metadata)),
            compressed_sizes.fetch(names.fetch(:metadata)), lane_bytes.fetch(:metadata).bytesize,
            "#{label} bucket #{bucket} chunk metadata start")
          require!(data_start == cursors.fetch(:data) && paths_start == cursors.fetch(:paths_marks) &&
                   metadata_start == cursors.fetch(:metadata),
            "#{label} bucket #{bucket} chunk starts are not contiguous")
          following = records[chunk_index + 1]
          data_end = if following
                       W191.decode_coordinate(following.fetch(:transport_pairs).fetch(:data), frames.fetch(names.fetch(:data)),
                         compressed_sizes.fetch(names.fetch(:data)), lane_bytes.fetch(:data).bytesize,
                         "#{label} bucket #{bucket} next chunk Data start")
                     else
                       ends.fetch(:data)
                     end
          path_count = record.fetch(:paths).size
          path_marks_end = cursors.fetch(:paths_marks) + path_count * 16
          metadata_end = cursors.fetch(:metadata) + path_count * 32
          require!(path_marks_end <= ends.fetch(:paths_marks) && metadata_end <= ends.fetch(:metadata),
            "#{label} bucket #{bucket} chunk path metadata exceeds its parent")
          if path_count.zero?
            require!(data_end == data_start, "#{label} bucket #{bucket} pathless chunk owns Data bytes")
          end
          record.fetch(:paths).each_with_index do |path, path_index|
            path_mark_offset = cursors.fetch(:paths_marks) + path_index * 16
            path_data_start = decode_pair_at(lane_bytes.fetch(:paths_marks), path_mark_offset,
              names.fetch(:data), frames, compressed_sizes, decoded_sizes_by_stream, "#{label} path Data start")
            path_data_end = if path_index + 1 < path_count
                              decode_pair_at(lane_bytes.fetch(:paths_marks), path_mark_offset + 16,
                                names.fetch(:data), frames, compressed_sizes, decoded_sizes_by_stream,
                                "#{label} next path Data start")
                            else
                              data_end
                            end
            require!(path_data_start >= data_start && path_data_end >= path_data_start && path_data_end <= data_end &&
                     (path_index != 0 || path_data_start == data_start),
              "#{label} bucket #{bucket} path Data interval is invalid")
            metadata_offset = cursors.fetch(:metadata) + path_index * 32
            substreams_start = decode_pair_at(lane_bytes.fetch(:metadata), metadata_offset,
              names.fetch(:substreams), frames, compressed_sizes, decoded_sizes_by_stream,
              "#{label} substreams start")
            substreams_marks_start = decode_pair_at(lane_bytes.fetch(:metadata), metadata_offset + 16,
              names.fetch(:substreams_marks), frames, compressed_sizes, decoded_sizes_by_stream,
              "#{label} substream marks start")
            require!(substreams_start == cursors.fetch(:substreams) &&
                     substreams_marks_start == cursors.fetch(:substreams_marks),
              "#{label} path callback starts are not contiguous")
            next_substreams = if path_index + 1 < path_count
                                decode_pair_at(lane_bytes.fetch(:metadata), metadata_offset + 32,
                                  names.fetch(:substreams), frames, compressed_sizes, decoded_sizes_by_stream,
                                  "#{label} next substreams start")
                              else
                                ends.fetch(:substreams)
                              end
            next_substreams_marks = if path_index + 1 < path_count
                                      decode_pair_at(lane_bytes.fetch(:metadata), metadata_offset + 48,
                                        names.fetch(:substreams_marks), frames, compressed_sizes,
                                        decoded_sizes_by_stream, "#{label} next substream marks start")
                                    else
                                      ends.fetch(:substreams_marks)
                                    end
            events, parsed_substreams_end = parse_callback_roster(
              lane_bytes.fetch(:substreams), substreams_start, next_substreams,
              lane_bytes.fetch(:substreams_marks), substreams_marks_start, next_substreams_marks,
              lane_bytes.fetch(:data), path_data_start, path_data_end, frames.fetch(names.fetch(:data)),
              compressed_sizes.fetch(names.fetch(:data)), names.fetch(:data), "#{label} #{path} callbacks",
            )
            if %w[arr late].include?(path)
              data = lane_bytes.fetch(:data).byteslice(path_data_start, path_data_end - path_data_start)
              row_start = REAL_MARK_ROWS.take(parent_mark).sum +
                records.take(chunk_index).sum { |prior| prior.fetch(:rows) }
              occurrences << {
                'path' => path, 'bucket_id' => bucket, 'parent_mark' => parent_mark,
                'chunk_index' => chunk_index, 'row_start' => row_start,
                'row_count' => record.fetch(:rows),
                'containing_data_stream' => names.fetch(:data),
                'path_data_start' => path_data_start, 'path_data_end' => path_data_end,
                'data_hex' => data.unpack1('H*'), 'data_sha256' => sha256(data),
                'events' => events,
              }
            end
            cursors[:substreams] = parsed_substreams_end
            cursors[:substreams_marks] = next_substreams_marks
          end
          cursors[:data] = data_end
          cursors[:paths_marks] = path_marks_end
          cursors[:metadata] = metadata_end
        end
        cursors[:structure] = structure_end
        require!(cursors == ends, "#{label} bucket #{bucket} parent leaves unowned lane bytes")
      end
    end
    require!(occurrences.any? { |entry| entry.fetch('path') == 'arr' } &&
             occurrences.any? { |entry| entry.fetch('path') == 'late' },
      "#{label} physical advanced Data lacks arr or late path occurrences")
    require!(occurrences.select { |entry| entry.fetch('path') == 'late' }.all? { |entry| entry.fetch('parent_mark') == 3 },
      "#{label} late-only path was not confined to the last physical mark")
    witnesses = read.fetch('selected_path_structure_witnesses')
    require!(witnesses.is_a?(Array), "#{label} helper selected-path structure witness roster is absent")
    expected_keys = occurrences.map { |entry| occurrence_key(entry) }.sort
    observed_keys = witnesses.map { |entry| occurrence_key(entry) }.sort
    require!(observed_keys == expected_keys, "#{label} helper path-structure witness coordinates differ from physical lanes")
    json_bearing_paths = {'arr' => false, 'late' => false}
    json_bearing_count_by_path = {'arr' => 0, 'late' => 0}
    witnesses.each do |witness|
      key = occurrence_key(witness)
      actual = occurrences.find { |entry| occurrence_key(entry) == key } || raise(AuditError, "#{label} witness is unbound")
      require!(witness.fetch('data_hex') == actual.fetch('data_hex') &&
               witness.fetch('data_sha256') == actual.fetch('data_sha256') &&
               witness.fetch('containing_data_stream') == actual.fetch('containing_data_stream') &&
               event_projection(witness.fetch('events')) == event_projection(actual.fetch('events')),
        "#{label} helper Data/callback witness differs from authenticated physical coordinates")
      structures = witness.fetch('structures')
      require!(structures.is_a?(Array) && !structures.empty?, "#{label} decoded Dynamic structures are absent")
      structures.each do |structure|
        types = structure.fetch('types')
        require!(structure.fetch('type_count') == types.size, "#{label} Dynamic structure type count differs")
      end
      json_bearing = audit_selected_path_occurrence_context!(
        witness.fetch('path'), actual.fetch('row_start'), actual.fetch('row_count'), structures,
        read.fetch('direct_shared_path_rows').fetch(witness.fetch('path')),
        actual.fetch('events'), "#{label} #{witness.fetch('path')} mark #{witness.fetch('parent_mark')} chunk #{witness.fetch('chunk_index')}",
        role: read.fetch('role'),
      )
      json_bearing_paths[witness.fetch('path')] ||= json_bearing
      json_bearing_count_by_path[witness.fetch('path')] += 1 if json_bearing
    end
    require!(json_bearing_paths.values.all?,
      "#{label} arr or late has no physically bound JSON-bearing occurrence")
    nested_inline = if read.fetch('role') == 'crystal_generated'
                      nested = audit_nested_inline_callbacks!(occurrences, physical_layout, native_streams, label,
                        requested_frame_bytes: requested_frame_bytes)
                      audited_paths = nested.fetch(:observed_paths)
                      require!(audited_paths == %w[arr late],
                        "#{label} generated full fixture nested-inline audit must observe arr and late")
                      audited_coordinates = nested.fetch(:observed_path_coordinates)
                      arr_buckets = audited_coordinates.select { |entry| entry.fetch(:path) == 'arr' }
                        .map { |entry| entry.fetch(:bucket_id) }.uniq
                      late_coordinates = audited_coordinates.select { |entry| entry.fetch(:path) == 'late' }
                      late_buckets = late_coordinates.map { |entry| entry.fetch(:bucket_id) }.uniq
                      require!(!late_coordinates.empty? && late_coordinates.all? { |entry| entry.fetch(:parent_mark) == 3 },
                        "#{label} generated full fixture nested-inline audit must observe late at parent mark 3")
                      require!(arr_buckets.size == 1 && late_buckets.size == 1 && arr_buckets.first != late_buckets.first,
                        "#{label} generated arr and late nested-inline audits must cover opposite root buckets")
                      nested
                    end
    root_type_rosters = witnesses.group_by { |entry| entry.fetch('path') }.transform_values do |entries|
      entries.flat_map do |entry|
        entry.fetch('structures').find { |structure| structure.fetch('path') == 'root' }.fetch('types')
      end.uniq.sort
    end
    {status: 'authenticated_from_native_streams_and_mark_coordinates',
     occurrences: occurrences.size, root_dynamic_type_rosters: root_type_rosters,
     json_bearing_occurrences_by_path: json_bearing_count_by_path,
     object_structure_callbacks: witnesses.sum { |entry| entry.fetch('events').count { |event| event.fetch('name').include?('object_structure') } },
     nested_inline: nested_inline}
  rescue KeyError, ArgumentError => error
    raise AuditError, "#{label} ordinary JSON binding is malformed: #{error.message}"
  end

  def occurrence_key(entry)
    [entry.fetch('path'), Integer(entry.fetch('bucket_id')), Integer(entry.fetch('parent_mark')),
     Integer(entry.fetch('chunk_index')), Integer(entry.fetch('row_count'))]
  end

  # Bind each decoded root Dynamic roster to the exact direct-read rows covered
  # by this physical occurrence. The two admitted roles intentionally have
  # different ordinary-arm policies: stock source registers every non-NULL
  # actual type in this serialized unit (including the empty-array carrier),
  # while the generated writer registers only prepared JSON-bearing actuals
  # and spills non-JSON actuals through SharedVariant. This is fixture-specific
  # evidence, not a general Dynamic registry-pruning rule. Descendant Dynamic
  # sites are deliberately not flattened into the root roster.
  def audit_selected_path_occurrence_context!(path, row_start, row_count, structures,
                                              direct_rows, events, label, role:)
    require!(%w[arr late].include?(path), "#{label} path is outside the JSON occurrence roster")
    require!(%w[stock_source crystal_generated].include?(role),
      "#{label} role is outside the selected-path registry policy")
    row_start = Integer(row_start)
    row_count = Integer(row_count)
    require!(row_start >= 0 && row_count.positive? && row_start + row_count <= ROWS.size,
      "#{label} row interval is outside the authenticated fixture")
    require!(direct_rows.is_a?(Array) && direct_rows.size == ROWS.size,
      "#{label} direct selected-path rows are incomplete")
    rows_by_pk = {}
    direct_rows.each do |row|
      pk = Integer(row.fetch('pk'))
      require!(!rows_by_pk.key?(pk), "#{label} direct selected-path rows duplicate pk #{pk}")
      rows_by_pk[pk] = row
    end
    require!(rows_by_pk.keys.sort == ROWS.map { |row| row.fetch(:pk) },
      "#{label} direct selected-path pk domain differs")

    observed_actual_types = []
    ROWS.slice(row_start, row_count).each do |fixture_row|
      pk = fixture_row.fetch(:pk)
      observed = rows_by_pk.fetch(pk)
      expected_value = fixture_row.fetch(:doc).fetch(path, nil)
      require!(observed.fetch('value') == expected_value,
        "#{label} direct value differs for pk #{pk}")
      actual_type = observed.fetch('type')
      require!(actual_type.is_a?(String), "#{label} actual descriptor is not a string for pk #{pk}")
      if expected_value.nil?
        require!(actual_type == 'NULL', "#{label} missing path is not reported as NULL for pk #{pk}")
      elsif actual_type == 'Array(Nullable(String))' && path == 'arr' && expected_value == []
        require!(actual_type == 'Array(Nullable(String))',
          "#{label} empty arr carrier differs for pk #{pk}")
        observed_actual_types << actual_type
      elsif array_json_type?(actual_type) && expected_value.is_a?(Array)
        # A typed JSON-bearing empty array remains an ordinary JSON arm even
        # though this row contributes no JSON elements. Its registered arm
        # still owns the object_structure callback.
        observed_actual_types << actual_type
      else
        raise AuditError, "#{label} actual descriptor #{actual_type.inspect} is illegal for pk #{pk}"
      end
    end
    expected_root_types = case role
                          when 'stock_source'
                            observed_actual_types.uniq.sort
                          when 'crystal_generated'
                            observed_actual_types.select { |type| array_json_type?(type) }.uniq.sort
                          else
                            # The explicit role allowlist above makes this unreachable.
                            raise AuditError, "#{label} role has no ordinary-arm policy"
                          end

    require!(structures.is_a?(Array), "#{label} Dynamic structure roster is not an array")
    structures.each do |structure|
      types = structure.fetch('types')
      require!(structure.fetch('type_count') == types.size && types.all? { |type| type.is_a?(String) },
        "#{label} Dynamic structure type count or names differ")
    end
    roots = structures.select { |structure| structure.fetch('path') == 'root' }
    require!(roots.size == 1, "#{label} does not contain exactly one root Dynamic structure")
    root = roots.first
    require!(root.fetch('types') == expected_root_types,
      "#{label} root Dynamic roster differs from the role-specific policy for this physical occurrence")

    # Callback obligation follows the authenticated registered roster, not
    # whether JSON values happen to be nonempty in the local rows.
    registered_json_types = root.fetch('types').select { |type| array_json_type?(type) }
    expected_object_structure_names = registered_json_types
      .map { |type| ".#{type}.object_structure" }
    actual_object_structure_names = events.select { |event| event.fetch('name').end_with?('.object_structure') }
      .map { |event| event.fetch('name') }
    require!(actual_object_structure_names == expected_object_structure_names,
      "#{label} JSON-bearing root descriptors and object_structure callbacks differ")
    unless expected_object_structure_names.empty?
      return true
    end

    advanced_callbacks = events.select do |event|
      NESTED_ADVANCED_INLINE_CALLBACK_SUFFIXES.any? do |suffix|
        event.fetch('name').end_with?(suffix)
      end
    end
    require!(advanced_callbacks.empty?, "#{label} non-JSON occurrence contains nested advanced Object callbacks")
    false
  rescue KeyError, ArgumentError, TypeError => error
    raise AuditError, "#{label} occurrence context is malformed: #{error.message}"
  end

  def event_projection(events)
    require!(events.is_a?(Array), 'callback event witness is not an array')
    events.map do |event|
      {'name' => event.fetch('name'), 'relative_offset' => Integer(event.fetch('relative_offset'))}
    end
  end

  # Validate the source-defined Compact callback payloads for an inline nested
  # advanced Object. The event marks and all 16-byte coordinates are resolved
  # against the independently decompressed containing root Data stream. This
  # intentionally does not trust a helper relocation list or a detached child
  # frame map.
  def audit_nested_inline_callbacks!(occurrences, physical_layout, native_streams, label,
                                     requested_frame_bytes:, run_wire_mutants: true)
    candidates = occurrences.select { |entry| %w[arr late].include?(entry.fetch('path')) }
    observed = []
    candidates.each do |occurrence|
      path_bytes = [occurrence.fetch('data_hex')].pack('H*')
      events = occurrence.fetch('events')
      named = events.map do |event|
        suffix = NESTED_ADVANCED_INLINE_CALLBACK_SUFFIXES.find do |role|
          event.fetch('name').end_with?(role)
        end
        suffix && [suffix, event]
      end.compact
      next if named.empty?

      roles = named.map(&:first)
      require!(roles == NESTED_ADVANCED_INLINE_CALLBACK_SUFFIXES,
        "#{label} inline child callback order differs from pinned Compact source roles")
      require!(named.map(&:first).uniq.size == NESTED_ADVANCED_INLINE_CALLBACK_SUFFIXES.size,
        "#{label} inline child callback roles are duplicated")
      role_events = named.to_h
      role_bodies = {}
      role_events.each do |role, event|
        event_index = events.index(event)
        require!(event_index, "#{label} inline callback event disappeared")
        start = Integer(event.fetch('relative_offset'))
        next_offset = if event_index + 1 < events.size
                        Integer(events[event_index + 1].fetch('relative_offset'))
                      else
                        path_bytes.bytesize
                      end
        require!(start >= 0 && next_offset >= start && next_offset <= path_bytes.bytesize,
          "#{label} inline callback body range is invalid")
        role_bodies[role] = path_bytes.byteslice(start, next_offset - start)
      end

      prefix_records = W191.parse_chunk_prefixes(
        role_bodies.fetch('object_shared_data.0.structure_prefix'),
        "#{label} inline nested bucket-0 prefix",
      )
      require!(!prefix_records.empty?, "#{label} inline nested prefix has no chunks")
      rows = prefix_records.map { |record| record.fetch(:rows) }
      suffixes_by_bucket = {}
      [0, 1].each do |bucket|
        prefix = "object_shared_data.#{bucket}."
        records = W191.parse_chunk_prefixes(
          role_bodies.fetch("#{prefix}structure_prefix"),
          "#{label} inline nested bucket-#{bucket} prefix",
        )
        require!(records.map { |record| record.fetch(:rows) } == rows,
          "#{label} inline nested bucket chunk schedules differ")
        suffixes_by_bucket[bucket] = W191.parse_suffix_stream(
          role_bodies.fetch("#{prefix}structure_suffix"), records.size,
          "#{label} inline nested bucket-#{bucket} suffix",
        )
      end

      stream = occurrence.fetch('containing_data_stream')
      data_frames = native_streams.fetch(:frame_spans).fetch(stream)
      compressed_size = native_streams.fetch(:compressed_sizes).fetch(stream)
      data_size = native_streams.fetch(:decoded_streams).fetch(stream).bytesize
      path_start = Integer(occurrence.fetch('path_data_start'))
      coordinate_witnesses_by_bucket = {0 => [], 1 => []}

      [0, 1].each do |bucket|
        prefix = "object_shared_data.#{bucket}."
        prefix_records = W191.parse_chunk_prefixes(
          role_bodies.fetch("#{prefix}structure_prefix"),
          "#{label} inline nested bucket-#{bucket} prefix",
        )
        paths_body = role_bodies.fetch("#{prefix}paths_marks")
        metadata_body = role_bodies.fetch("#{prefix}paths_substreams_metadata")
        data_event = role_events.fetch("#{prefix}data")
        paths_event = role_events.fetch("#{prefix}paths_marks")
        substreams_event = role_events.fetch("#{prefix}substreams")
        substreams_marks_event = role_events.fetch("#{prefix}substreams_marks")
        metadata_event = role_events.fetch("#{prefix}paths_substreams_metadata")
        suffix_event = role_events.fetch("#{prefix}structure_suffix")
        data_range = callback_absolute_range(data_event, events, path_start, path_bytes.bytesize, label)
        paths_range = callback_absolute_range(paths_event, events, path_start, path_bytes.bytesize, label)
        substreams_range = callback_absolute_range(substreams_event, events, path_start, path_bytes.bytesize, label)
        substreams_marks_range = callback_absolute_range(substreams_marks_event, events, path_start, path_bytes.bytesize, label)
        metadata_range = callback_absolute_range(metadata_event, events, path_start, path_bytes.bytesize, label)
        suffix_range = callback_absolute_range(suffix_event, events, path_start, path_bytes.bytesize, label)

        expected_path_cursor = 0
        expected_metadata_cursor = 0
        nested_substreams_cursor = 0
        nested_marks_cursor = 0
        data_starts = suffixes_by_bucket.fetch(bucket).map.with_index do |suffix, chunk_index|
          decode_nested_inline_pair(
            suffix.fetch(:transport_pairs).fetch(:data), data_frames, compressed_size, data_size,
            "#{label} bucket-#{bucket} chunk-#{chunk_index} suffix Data",
          )
        end
        # SerializationObjectSharedData.cpp captures data_stream_mark once at
        # each serializeChunkBucketData entry, before writing that chunk's
        # paths. Therefore the next chunk mark (or callback end) bounds this
        # chunk's containing-Data interval; a pathless chunk writes no bytes.
        require!(data_starts.each_cons(2).all? { |left, right| right >= left },
          "#{label} nested chunk Data starts are not monotone")
        prefix_records.each_with_index do |record, chunk_index|
          suffix_pairs = suffixes_by_bucket.fetch(bucket).fetch(chunk_index).fetch(:transport_pairs)
          actual_data_start = data_starts.fetch(chunk_index)
          data_end = data_starts.fetch(chunk_index + 1, data_range.fetch(:finish))
          require!(actual_data_start >= data_range.fetch(:start) && data_end >= actual_data_start &&
                   data_end <= data_range.fetch(:finish),
            "#{label} nested chunk Data interval escapes its containing callback")
          if record.fetch(:paths).empty?
            require!(data_end == actual_data_start,
              "#{label} pathless nested chunk owns Data bytes")
          end
          expected_paths_start = paths_range.fetch(:start) + expected_path_cursor
          expected_metadata_start = metadata_range.fetch(:start) + expected_metadata_cursor
          actual_paths_start = decode_nested_inline_pair(
            suffix_pairs.fetch(:paths_marks), data_frames, compressed_size, data_size,
            "#{label} bucket-#{bucket} chunk-#{chunk_index} suffix PathsMarks",
          )
          actual_metadata_start = decode_nested_inline_pair(
            suffix_pairs.fetch(:paths_substreams_metadata), data_frames, compressed_size, data_size,
            "#{label} bucket-#{bucket} chunk-#{chunk_index} suffix metadata",
          )
          require!(actual_paths_start == expected_paths_start && actual_metadata_start == expected_metadata_start,
            "#{label} nested suffix marks are not in the containing root Data coordinate space")
          bucket_witnesses = coordinate_witnesses_by_bucket.fetch(bucket)
          append_nested_coordinate_witness!(bucket_witnesses, path_bytes, path_start,
            suffix_pairs.fetch(:data), actual_data_start, suffix_range.fetch(:start) + chunk_index * 48,
            'suffix_data', label)
          append_nested_coordinate_witness!(bucket_witnesses, path_bytes, path_start,
            suffix_pairs.fetch(:paths_marks), actual_paths_start, suffix_range.fetch(:start) + chunk_index * 48 + 16,
            'suffix_paths_marks', label)
          append_nested_coordinate_witness!(bucket_witnesses, path_bytes, path_start,
            suffix_pairs.fetch(:paths_substreams_metadata), actual_metadata_start,
            suffix_range.fetch(:start) + chunk_index * 48 + 32, 'suffix_metadata', label)

          record.fetch(:paths).each_with_index do |_path, path_index|
            path_pair_offset = expected_path_cursor + path_index * 16
            require!(path_pair_offset <= paths_body.bytesize - 16,
              "#{label} nested PathsMarks callback is truncated")
            path_pair = paths_body.byteslice(path_pair_offset, 16).unpack('Q<2')
            path_absolute = decode_nested_inline_pair(
              path_pair, data_frames, compressed_size, data_size,
              "#{label} bucket-#{bucket} chunk-#{chunk_index} path Data mark",
            )
            require!(path_absolute >= data_range.fetch(:start) && path_absolute <= data_range.fetch(:finish),
              "#{label} nested path mark escapes the containing Data callback")
            require!(path_absolute >= actual_data_start && path_absolute <= data_end,
              "#{label} nested path mark escapes its chunk Data interval")
            append_nested_coordinate_witness!(bucket_witnesses, path_bytes, path_start,
              path_pair, path_absolute, paths_range.fetch(:start) + path_pair_offset,
              path_index.zero? ? 'nested_path_mark_first' : 'nested_path_mark', label)
            if path_index.zero?
              require!(actual_data_start == path_absolute,
                "#{label} nested suffix Data does not begin at its first path mark")
            end

            metadata_offset = expected_metadata_cursor + path_index * 32
            require!(metadata_offset <= metadata_body.bytesize - 32,
              "#{label} nested path metadata callback is truncated")
            substream_pair = metadata_body.byteslice(metadata_offset, 16).unpack('Q<2')
            marks_pair = metadata_body.byteslice(metadata_offset + 16, 16).unpack('Q<2')
            substream_absolute = decode_nested_inline_pair(
              substream_pair, data_frames, compressed_size, data_size,
              "#{label} nested path substreams mark",
            )
            marks_absolute = decode_nested_inline_pair(
              marks_pair, data_frames, compressed_size, data_size,
              "#{label} nested path substream-marks mark",
            )
            require!(substream_absolute == substreams_range.fetch(:start) + nested_substreams_cursor &&
                     marks_absolute == substreams_marks_range.fetch(:start) + nested_marks_cursor,
              "#{label} nested metadata marks do not address the actual callback bodies")
            append_nested_coordinate_witness!(bucket_witnesses, path_bytes, path_start,
              substream_pair, substream_absolute, metadata_range.fetch(:start) + metadata_offset,
              'nested_substreams_start', label)
            append_nested_coordinate_witness!(bucket_witnesses, path_bytes, path_start,
              marks_pair, marks_absolute, metadata_range.fetch(:start) + metadata_offset + 16,
              'nested_substreams_marks_start', label)

            count, cursor = W191.read_varuint(
              role_bodies.fetch("#{prefix}substreams"), nested_substreams_cursor,
              "#{label} nested substream roster",
            )
            names = []
            count.times do
              name, cursor = W191.read_binary_string(
                role_bodies.fetch("#{prefix}substreams"), cursor,
                "#{label} nested substream roster",
              )
              names << name
            end
            require!(nested_marks_cursor <= role_bodies.fetch("#{prefix}substreams_marks").bytesize - count * 16,
              "#{label} nested substream mark list is truncated")
            count.times do |event_index|
              mark_pair = role_bodies.fetch("#{prefix}substreams_marks")
                .byteslice(nested_marks_cursor + event_index * 16, 16).unpack('Q<2')
              mark_absolute = decode_nested_inline_pair(
                mark_pair, data_frames, compressed_size, data_size,
                "#{label} nested #{names.fetch(event_index)} event mark",
              )
              require!(mark_absolute >= data_range.fetch(:start) && mark_absolute <= data_range.fetch(:finish),
                "#{label} nested event mark escapes the containing Data callback")
              append_nested_coordinate_witness!(bucket_witnesses, path_bytes, path_start,
                mark_pair, mark_absolute,
                substreams_marks_range.fetch(:start) + nested_marks_cursor + event_index * 16,
                'nested_substream_mark', label)
            end
            nested_substreams_cursor = cursor
            nested_marks_cursor += count * 16
          end
          expected_path_cursor += record.fetch(:paths).size * 16
          expected_metadata_cursor += record.fetch(:paths).size * 32
        end
        require!(expected_path_cursor == paths_body.bytesize && expected_metadata_cursor == metadata_body.bytesize &&
                 nested_substreams_cursor == role_bodies.fetch("#{prefix}substreams").bytesize &&
                 nested_marks_cursor == role_bodies.fetch("#{prefix}substreams_marks").bytesize,
          "#{label} nested inline callback lanes have unowned bytes")
      end

      observed << {
        occurrence: occurrence, rows: rows, bucket_ids: [0, 1],
        coordinate_witnesses_by_bucket: coordinate_witnesses_by_bucket,
        data_frame_count: data_frames.size,
      }
    end
    require!(!observed.empty?, "#{label} generated Array(JSON) has no source-ordered nested advanced callbacks")

    if physical_layout.fetch(:family) == 'advanced_chunked'
      qualifying = observed.find do |entry|
        occurrence = entry.fetch(:occurrence)
        occurrence.fetch('path') == 'arr' && occurrence.fetch('parent_mark') == 0 && entry.fetch(:rows) == [2, 1]
      end
      require!(qualifying, "#{label} v3 nested Array(JSON) does not expose the actual [2,1] child chunk schedule")
      stream = qualifying.fetch(:occurrence).fetch('containing_data_stream')
      frames = native_streams.fetch(:frame_spans).fetch(stream)
      require!(frames.size > 1, "#{label} containing root Data has only one actual compressed frame")
      require!(FRAME_BYTES_OPTIONS.include?(requested_frame_bytes),
        "#{label} requested frame_bytes is outside the fixed 32/64 allowlist")
      full_frames = frames.select { |frame| frame.fetch(:decoded_size) == requested_frame_bytes }
      require!(!full_frames.empty?,
        "#{label} native-authenticated containing root Data has no complete #{requested_frame_bytes}-byte frame")
      nonzero_by_bucket = qualifying.fetch(:coordinate_witnesses_by_bucket).each_with_object({}) do |(bucket, witnesses), result|
        result[bucket] = witnesses.any? do |witness|
          pair = witness.fetch(:pair)
          frame = frames.find { |candidate| candidate.fetch(:compressed_offset) == pair.fetch(0) }
          pair.fetch(0) > 0 && frame && frame.fetch(:decoded_offset) > 0 && witness.fetch(:absolute) > 0
        end
      end
      require!(nonzero_by_bucket.keys.sort == [0, 1] && nonzero_by_bucket.values.all?,
        "#{label} each nested bucket must expose a coordinate on a nonzero containing-frame base")
      wire_check = run_wire_mutants ? self_test_captured_nested_wire_mutants!(
        qualifying.fetch(:occurrence), qualifying.fetch(:coordinate_witnesses_by_bucket),
        physical_layout, native_streams, frames, label, requested_frame_bytes: requested_frame_bytes,
      ) : {positive_control: nil, mutants: []}
    else
      wire_check = {positive_control: nil, mutants: []}
    end
    observed_path_coordinates = observed.map do |entry|
      occurrence = entry.fetch(:occurrence)
      {
        path: occurrence.fetch('path'),
        bucket_id: Integer(occurrence.fetch('bucket_id')),
        parent_mark: Integer(occurrence.fetch('parent_mark')),
        chunk_index: Integer(occurrence.fetch('chunk_index')),
      }
    end.uniq.sort_by { |entry| [entry.fetch(:path), entry.fetch(:parent_mark), entry.fetch(:chunk_index)] }
    {callback_roster: NESTED_ADVANCED_INLINE_CALLBACK_SUFFIXES,
     observed_nested_occurrences: observed.size,
     observed_paths: observed.map { |entry| entry.fetch(:occurrence).fetch('path') }.uniq.sort,
     observed_path_coordinates: observed_path_coordinates,
     v3_multiframe_data_occurrences: observed.count { |entry| entry.fetch(:data_frame_count) > 1 },
     requested_frame_bytes: requested_frame_bytes,
     observed_full_requested_size_frames: physical_layout.fetch(:family) == 'advanced_chunked' ? full_frames.size : 0,
     coordinate_space: 'authenticated containing root Data frames',
     decoded_captured_wire_positive_single_occurrence_control: wire_check.fetch(:positive_control),
     decoded_captured_wire_mutants_rejected: wire_check.fetch(:mutants)}
  rescue KeyError, ArgumentError, TypeError => error
    raise AuditError, "#{label} nested inline coordinate audit is malformed: #{error.message}"
  end

  def callback_absolute_range(event, events, path_start, path_size, label)
    index = events.index(event)
    require!(index, "#{label} callback event is absent")
    start_relative = Integer(event.fetch('relative_offset'))
    finish_relative = if index + 1 < events.size
                        Integer(events[index + 1].fetch('relative_offset'))
                      else
                        path_size
                      end
    require!(start_relative >= 0 && finish_relative >= start_relative && finish_relative <= path_size,
      "#{label} callback range is outside the selected path")
    {start: path_start + start_relative, finish: path_start + finish_relative}
  end

  def decode_nested_inline_pair(pair, frames, compressed_size, decoded_size, label)
    require!(pair.is_a?(Array) && pair.size == 2, "#{label} coordinate pair is malformed")
    pair = pair.map { |word| Integer(word) }
    W191.decode_coordinate(pair, frames, compressed_size, decoded_size, label)
  rescue ArgumentError => error
    raise AuditError, "#{label} is not a containing-stream coordinate: #{error.message}"
  end

  def append_nested_coordinate_witness!(witnesses, path_bytes, path_start, pair, absolute,
                                        source_offset, role, label)
    pair = pair.map { |word| Integer(word) }
    relative_source = source_offset - path_start
    require!(relative_source >= 0 && relative_source <= path_bytes.bytesize - 16,
      "#{label} #{role} source field is outside the captured path bytes")
    stored_pair = path_bytes.byteslice(relative_source, 16).unpack('Q<2')
    require!(stored_pair == pair, "#{label} #{role} source field differs from its parsed coordinate")
    witnesses << {pair: pair, absolute: absolute, source_offset: source_offset, role: role}
  end

  # Mutate two fixed-width fields in clones of native-decompressed captured
  # root Data. Callback extents and authenticated frame descriptors remain
  # unchanged; the same source-literal parser must reject both decoded-wire
  # mutants. This is not an on-disk part mutation or native rejection test.
  def self_test_captured_nested_wire_mutants!(occurrence, witnesses_by_bucket, physical_layout,
                                              native_streams, frames, label, requested_frame_bytes:)
    stream = occurrence.fetch('containing_data_stream')
    original_data = native_streams.fetch(:decoded_streams).fetch(stream)
    original_snapshot = original_data.dup
    path_start = Integer(occurrence.fetch('path_data_start'))
    path_end = Integer(occurrence.fetch('path_data_end'))
    path_size = path_end - path_start
    require!(path_start >= 0 && path_size >= 0 && path_end <= original_data.bytesize,
      "#{label} captured path extent is outside native-decompressed root Data")
    original_path = original_data.byteslice(path_start, path_size)
    require!(sha256(original_path) == occurrence.fetch('data_sha256') &&
             original_path.unpack1('H*') == occurrence.fetch('data_hex'),
      "#{label} captured occurrence is not bound to native-decompressed root Data")

    # Suffix PathsMarks exists once for every bucket chunk even when its child
    # path roster is empty. Unlike a nested path mark, this field is therefore
    # present in the generated fixture whose child shared dictionaries can be
    # empty. The source-literal oracle independently binds it to the containing
    # root Data callback's PathsMarks start.
    positive_control = audit_nested_inline_callbacks!([occurrence], physical_layout, native_streams,
      "#{label} unchanged single-occurrence control", requested_frame_bytes: requested_frame_bytes,
      run_wire_mutants: false)
    control_path = occurrence.fetch('path')
    require!(positive_control.fetch(:observed_paths) == [control_path] &&
             positive_control.fetch(:observed_nested_occurrences) == 1,
      "#{label} unchanged single-occurrence control did not positively audit its captured path")
    positive_control_result = {
      path: control_path,
      bucket_id: Integer(occurrence.fetch('bucket_id')),
      parent_mark: Integer(occurrence.fetch('parent_mark')),
      result: 'accepted_by_same_source_literal_audit',
    }

    source_bucket = [0, 1].find do |bucket|
      witnesses_by_bucket.fetch(bucket).any? do |witness|
        witness.fetch(:role) == 'suffix_paths_marks' && witness.fetch(:absolute) > 1 &&
          witness.fetch(:pair) != [0, 0]
      end
    end
    require!(source_bucket, "#{label} v3 captured path has no nonzero suffix PathsMarks source field")
    source = witnesses_by_bucket.fetch(source_bucket).find do |witness|
      witness.fetch(:role) == 'suffix_paths_marks' && witness.fetch(:absolute) > 1 && witness.fetch(:pair) != [0, 0]
    end
    first_frame = frames.first || raise(AuditError, "#{label} containing root Data has no frame")
    require!(first_frame.fetch(:compressed_offset).zero?,
      "#{label} first containing Data frame does not begin at compressed offset zero")
    zero_pair = [0, 0]
    zero_target = decode_nested_inline_pair(zero_pair, frames,
      native_streams.fetch(:compressed_sizes).fetch(stream), original_data.bytesize,
      "#{label} candidate zero local coordinate")
    require!(zero_target != source.fetch(:absolute),
      "#{label} zero-coordinate mutation would retain the captured target")
    local_offsets = (1..[first_frame.fetch(:decoded_size), 8].min).to_a
    local_pair = local_offsets.map { |offset| [first_frame.fetch(:compressed_offset), offset] }.find do |pair|
      target = decode_nested_inline_pair(pair, frames, native_streams.fetch(:compressed_sizes).fetch(stream),
        original_data.bytesize, "#{label} candidate local-lane coordinate")
      target != source.fetch(:absolute)
    end
    require!(local_pair, "#{label} has no valid local-lane-looking coordinate distinct from the captured target")
    local_target = decode_nested_inline_pair(local_pair, frames, native_streams.fetch(:compressed_sizes).fetch(stream),
      original_data.bytesize, "#{label} selected local-lane coordinate")
    require!(local_target != source.fetch(:absolute), "#{label} local-lane mutation did not change the target")

    replacements = [
      ['decoded captured-wire coordinate replaced with [0,0]', zero_pair, zero_target],
      ['decoded captured-wire coordinate replaced with valid local-lane-looking pair', local_pair, local_target],
    ]
    mutation_results = replacements.map do |description, replacement_pair, replacement_target|
      require!(replacement_pair != source.fetch(:pair), "#{label} #{description} would not change the source field")
      field_offset = source.fetch(:source_offset)
      original_field = original_data.byteslice(field_offset, 16)
      require!(original_field == source.fetch(:pair).pack('Q<2'),
        "#{label} captured nested coordinate source bytes changed")
      replacement_bytes = replacement_pair.pack('Q<2')
      require!(replacement_bytes.bytesize == 16, "#{label} nested coordinate mutation changed field width")
      mutated_data = original_data.dup
      mutated_data[field_offset, 16] = replacement_bytes
      require!(mutated_data.bytesize == original_data.bytesize && original_data == original_snapshot,
        "#{label} decoded-wire mutation changed frame extent or original capture")
      mutated_path = mutated_data.byteslice(path_start, path_size)
      mutated_occurrence = occurrence.merge(
        'data_hex' => mutated_path.unpack1('H*'),
        'data_sha256' => sha256(mutated_path),
      )
      decoded_streams = native_streams.fetch(:decoded_streams).merge(stream => mutated_data)
      mutated_native_streams = native_streams.merge(decoded_streams: decoded_streams)
      rejection = expect_reject!("#{label} source-literal audit accepted #{description}") do
        audit_nested_inline_callbacks!([mutated_occurrence], physical_layout, mutated_native_streams,
          "#{label} #{description}", requested_frame_bytes: requested_frame_bytes, run_wire_mutants: false)
      end
      {'mutation' => description, 'bucket_id' => source_bucket,
       'source_pair' => source.fetch(:pair), 'source_absolute' => source.fetch(:absolute),
       'replacement_pair' => replacement_pair, 'replacement_absolute' => replacement_target,
       'result' => 'rejected_by_same_source_literal_audit', 'rejection' => rejection,
       'scope' => 'decoded captured-wire clone; not an on-disk part or native rejection'}
    end
    {positive_control: positive_control_result, mutants: mutation_results}
  end

  def require_nested_pair_targets!(pair, expected_absolute, frames, compressed_size, decoded_size, label)
    actual_absolute = decode_nested_inline_pair(pair, frames, compressed_size, decoded_size, label)
    require!(actual_absolute == expected_absolute,
      "#{label} resolves to #{actual_absolute}, expected containing-stream offset #{expected_absolute}")
    actual_absolute
  end

  def self_test_nested_coordinate_oracle!
    frames = [
      {compressed_offset: 0, decoded_offset: 0, decoded_size: 32},
      {compressed_offset: 100, decoded_offset: 32, decoded_size: 32},
    ]
    require_nested_pair_targets!([100, 8], 40, frames, 200, 64, 'seeded actual containing-frame coordinate')
    expect_reject!('seeded local-zero nested coordinate') do
      require_nested_pair_targets!([0, 0], 40, frames, 200, 64, 'seeded local-zero nested coordinate')
    end
    expect_reject!('seeded independently-compressed child coordinate') do
      require_nested_pair_targets!([60, 8], 40, frames, 200, 64, 'seeded independently-compressed child coordinate')
    end
    true
  end

  def self_test_coordinate_lane_key_domains!
    stream = 'doc.object_shared_data.0.data'
    frames = {stream => [{compressed_offset: 0, decoded_offset: 0, decoded_size: 8}]}
    compressed_sizes = {stream => 16}
    decoded_sizes = {stream => 8}
    pair_bytes = [0, 4].pack('Q<2')
    actual = decode_pair_at(pair_bytes, 0, stream, frames, compressed_sizes, decoded_sizes,
      'seeded physical-string stream coordinate')
    require!(actual == 4, 'physical-string stream coordinate resolved to the wrong decoded offset')

    expect_reject!('coordinate names an unregistered physical stream') do
      decode_pair_at(pair_bytes, 0, 'doc.object_shared_data.1.data', frames, compressed_sizes,
        decoded_sizes, 'wrong physical-string stream coordinate')
    end
    expect_reject!('coordinate has no decoded-size binding for its physical stream') do
      decode_pair_at(pair_bytes, 0, stream, frames, compressed_sizes, {},
        'missing decoded-size stream binding')
    end
    expect_reject!('coordinate exceeds the decoded frame extent') do
      decode_pair_at([0, 9].pack('Q<2'), 0, stream, frames, compressed_sizes, decoded_sizes,
        'out-of-range physical-stream coordinate')
    end
    true
  end

  def json_data_type_name?(name)
    return false unless name.is_a?(String)
    return true if name == 'JSON' || name == 'Array(JSON)'
    balanced_type_envelope?(name, 'JSON(') || balanced_type_envelope?(name, 'Array(JSON(')
  end

  def balanced_type_envelope?(name, prefix)
    return false unless name.start_with?(prefix) && name.end_with?(')')
    depth = 0
    name.each_char.with_index do |character, index|
      depth += 1 if character == '('
      if character == ')'
        depth -= 1
        return false if depth.negative? || (depth.zero? && index != name.length - 1)
      end
    end
    depth.zero?
  end

  def decode_pair_at(bytes, offset, stream, frames_by_stream, compressed_sizes_by_stream,
                     decoded_sizes_by_stream, label)
    require!(offset >= 0 && offset <= bytes.bytesize - 16, "#{label} coordinate pair is truncated")
    pair = bytes.byteslice(offset, 16).unpack('Q<2')
    W191.decode_coordinate(pair, frames_by_stream.fetch(stream), compressed_sizes_by_stream.fetch(stream),
      decoded_sizes_by_stream.fetch(stream), label)
  rescue KeyError, ArgumentError => error
    raise AuditError, "#{label} has an absent stream binding or invalid coordinate: #{error.message}"
  end

  def parse_callback_roster(substreams, start, finish, marks, marks_start, marks_finish,
                            data, path_data_start, path_data_end, data_frames, data_compressed_size,
                            containing_data_stream, label)
    require!(start >= 0 && finish >= start && finish <= substreams.bytesize &&
             marks_start >= 0 && marks_finish >= marks_start && marks_finish <= marks.bytesize,
      "#{label} callback range is invalid")
    slice = substreams.byteslice(start, finish - start)
    count, cursor = W191.read_varuint(slice, 0, label)
    require!(count <= 4096, "#{label} callback count exceeds the bounded profile")
    require!(finish - start >= cursor && marks_finish - marks_start == count * 16,
      "#{label} callback marks extent differs")
    events = []
    count.times do |index|
      name, cursor = W191.read_binary_string(slice, cursor, label)
      mark_pair = marks.byteslice(marks_start + index * 16, 16).unpack('Q<2')
      absolute = W191.decode_coordinate(mark_pair, data_frames, data_compressed_size, data.bytesize, label)
      relative = absolute - path_data_start
      require!(relative >= 0 && absolute <= path_data_end && (index != 0 || relative == 0) &&
               (events.empty? || relative >= events.last.fetch('relative_offset')),
        "#{label} callback coordinate is outside or unordered in path Data")
      frame = data_frames.find { |candidate| candidate.fetch(:compressed_offset) == mark_pair.fetch(0) }
      terminal = mark_pair.fetch(0) == data_compressed_size && mark_pair.fetch(1).zero? && absolute == data.bytesize
      require!(frame || terminal, "#{label} callback coordinate has no containing compressed frame")
      events << {
        'name' => name,
        'relative_offset' => relative,
        'coordinate_pair' => mark_pair,
        'absolute_decompressed_offset' => absolute,
        'containing_data_stream' => containing_data_stream,
        'frame_compressed_offset' => frame && frame.fetch(:compressed_offset),
        'frame_decompressed_offset' => frame && frame.fetch(:decoded_offset),
      }
    end
    require!(cursor == slice.bytesize, "#{label} callback bytes have an unowned suffix")
    [events, finish]
  end

  def authenticate_helper_read_roles!(source, generated, label)
    require!(source.fetch('role') == 'stock_source' && generated.fetch('role') == 'crystal_generated',
      "#{label} source/generated helper slot roles differ")
    true
  end

  def authenticate_source_part_path!(helper_part_path, source_write_part_path, label)
    require!(helper_part_path.is_a?(String) && !helper_part_path.empty? &&
             source_write_part_path.is_a?(String) && source_write_part_path == helper_part_path,
      "#{label} fresh source write PART path differs from source_read.part_path")
    true
  end

  def authenticate_source_query_table!(query_table, source_write_table, label)
    require!(source_write_table.is_a?(String) && !source_write_table.empty? &&
             query_table == source_write_table,
      "#{label} source query table differs from the authenticated write table")
    true
  end

  def sql_statements!(sql, label)
    require!(sql.is_a?(String) && sql.end_with?("\n"), "#{label} SQL is not newline-terminated")
    statements = sql.split(';').map(&:strip).reject(&:empty?)
    require!(!statements.empty?, "#{label} SQL has no statements")
    statements
  end

  def expected_generated_target_settings(layout, string_version)
    require!(LAYOUTS.include?(layout), 'generated target layout is not in the closed layout roster')
    string = STRING_PROFILES.find { |entry| entry.fetch(:version) == string_version }
    require!(!string.nil?, 'generated target String profile is outside the closed roster')
    settings = TARGET_CREATE_BASE_SETTINGS.map { |name, value| "#{name}=#{value}" }
    settings.concat([
      "object_shared_data_serialization_version='#{layout.fetch(:setting)}'",
      "object_shared_data_serialization_version_for_zero_level_parts='#{layout.fetch(:setting)}'",
      "string_serialization_version='#{string.fetch(:setting)}'",
    ])
    settings << 'object_shared_data_target_chunk_rows=2' if layout.fetch(:enum) == 3
    settings.join(', ')
  end

  def audit_generated_target_create!(details, id, layout, string_version, label, capture_root)
    allowed_id = PROFILE_IDS.include?(id) || NEGATIVE_PROFILE_IDS.include?(id)
    require!(allowed_id, "#{label} target id is outside the positive/negative allowlist")
    if NEGATIVE_PROFILE_IDS.include?(id)
      require!(id == 'advanced_chunked_s0_negative_data_corrupt' ||
               id == 'advanced_chunked_s0_negative_copy_truncated',
        "#{label} negative target id is not closed")
      require!(layout.fetch(:id) == 'advanced_chunked' && string_version == 0,
        "#{label} negative target is not the sealed advanced_chunked_s0 context")
    end
    create_table_match = /CREATE TABLE default\.([a-zA-Z0-9_]+)/.match(details.fetch(:input))
    require!(!create_table_match.nil?, "#{label} CREATE table is absent")
    table_match = /\Aw241_([0-9a-f]{8})_#{Regexp.escape(id)}_target\z/.match(create_table_match[1])
    require!(!table_match.nil?, "#{label} CREATE table is not bound to its canonical id/token")
    canonical_root = File.expand_path(capture_root)
    expected_token = Digest::SHA256.hexdigest(canonical_root)[0, 8]
    require!(table_match[1] == expected_token,
      "#{label} CREATE token is not derived from the authenticated capture root")
    table = "w241_#{expected_token}_#{id}_target"
    statements = sql_statements!(details.fetch(:input), label)
    expected_create = "CREATE TABLE default.#{table} (pk UInt64, doc #{STOCK_TYPE}) " \
      "ENGINE=MergeTree ORDER BY pk SETTINGS #{expected_generated_target_settings(layout, string_version)}"
    expected_target_query = "SELECT '__W241_TARGET_PATH__', '#{id}', arrayElement(data_paths, 1) " \
      "FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw"
    expected_statements = [
      'SET output_format_json_quote_64bit_integers=0',
      "SELECT '__W241_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw",
      expected_create,
      expected_target_query,
    ]
    require!(statements == expected_statements,
      "#{label} CREATE/target-path SQL differs from the exact generated origin")

    marker_rows = details.fetch(:stdout).lines.map(&:chomp).select do |line|
      line.split("\t", -1).first == '__W241_TARGET_PATH__'
    end
    require!(marker_rows.size == 1, "#{label} target path marker is absent or duplicated")
    fields = marker_rows.first.split("\t", -1)
    require!(fields.size == 3 && fields[0] == '__W241_TARGET_PATH__' && fields[1] == id,
      "#{label} target path marker identity/field count differs")
    data_path = fields.fetch(2)
    expanded_path = File.expand_path(data_path)
    store_root = File.expand_path(details.fetch(:argv).fetch(3))
    require!(store_root == File.join(canonical_root, 'stores', 'native'),
      "#{label} client store argument is not the authenticated native store")
    require!((data_path == expanded_path || data_path == "#{expanded_path}#{File::SEPARATOR}") &&
             expanded_path.start_with?(store_root + File::SEPARATOR),
      "#{label} target data path is noncanonical or outside the authenticated store")
    {table: table, data_path: data_path, token: table_match[1]}
  rescue KeyError, ArgumentError => error
    raise AuditError, "#{label} generated target origin is malformed: #{error.message}"
  end

  def authenticate_generated_attach_sql!(sql, id, table, label)
    require!(PROFILE_IDS.include?(id) || NEGATIVE_PROFILE_IDS.include?(id),
      "#{label} attach id is outside the positive/negative allowlist")
    expected = [
      'SET output_format_json_quote_64bit_integers=0',
      "SELECT '__W241_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw",
      "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'",
      "SELECT '__W241_CHECK_BEGIN__', '#{id}' FORMAT TSVRaw",
      "CHECK TABLE default.#{table} FORMAT TSV",
      "SELECT '__W241_CHECK_END__', '#{id}' FORMAT TSVRaw",
      "SELECT '__W241_SCHEMA__', '#{id}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw",
      "SELECT '__W241_PART__', '#{id}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw",
    ]
    require!(sql_statements!(sql, "#{label} attach/CHECK") == expected,
      "#{label} attach/CHECK/schema/PART SQL is not bound to the target table")
    true
  end

  def authenticate_generated_query_table!(sql, stage, expected_table, id, label)
    require!(%w[direct full].include?(stage), "#{label} query stage is unrostered")
    require!(PROFILE_IDS.include?(id) || NEGATIVE_PROFILE_IDS.include?(id),
      "#{label} query id is outside the positive/negative allowlist")
    require!(sql.is_a?(String) && !sql.empty?, "#{label} query SQL is absent")
    terminated_sql = sql.end_with?("\n") ? sql[0...-1] : sql
    require!(terminated_sql.end_with?(';'), "#{label} query SQL is not semicolon-terminated")
    statements = sql_statements!(sql.end_with?("\n") ? sql : "#{sql}\n", label)
    source_statements = statements.select { |statement| statement.match?(/\bFROM\s+default\./i) }
    expected_count = stage == 'direct' ? 1 : 4
    require!(source_statements.size == expected_count,
      "#{label} query has an extra or missing table-reading statement")
    tables = source_statements.flat_map do |statement|
      statement.scan(/\b(?:FROM|JOIN)\s+default\.([a-zA-Z0-9_]+)/i).flatten
    end
    require!(tables.size == expected_count && tables.all? { |table| table == expected_table },
      "#{label} query statement is not bound to the authenticated target table")
    true
  end

  def authenticate_target_part_path!(data_path, part_path, label)
    expected = File.join(File.expand_path(data_path), 'all_1_1_0')
    require!(part_path == expected, "#{label} active PART.path is not target data_path/all_1_1_0")
    true
  end

  def normalize_attached_source_inventory(inventory, label)
    entries = case inventory
              when Array
                names = inventory.map { |entry| entry.fetch('name') }
                require!(names.all? { |name| name.is_a?(String) } && names.uniq == names,
                  "#{label} source inventory has duplicate or malformed names")
                inventory.to_h do |entry|
                  [entry.fetch('name'), {'size' => entry.fetch('size'), 'sha256' => entry.fetch('sha256')}]
                end
              when Hash
                inventory
              else
                raise AuditError, "#{label} original file inventory is not a map or array"
              end
    require!(entries.size.positive? && entries.keys.all? do |name|
      name.is_a?(String) && File.basename(name) == name && name.match?(/\A[a-zA-Z0-9_.-]+\z/) &&
        name != ATTACHED_NATIVE_EXTRA_FILE
    end, "#{label} original file inventory has unsafe, duplicate, or native-only names")
    entries.each do |name, entry|
      require!(entry.is_a?(Hash) && entry.fetch('size').is_a?(Integer) && entry.fetch('size') >= 0 &&
               entry.fetch('sha256').is_a?(String) && entry.fetch('sha256').match?(/\A[0-9a-f]{64}\z/),
        "#{label} original inventory entry is malformed: #{name}")
    end
    entries
  rescue KeyError, TypeError => error
    raise AuditError, "#{label} original file inventory is malformed: #{error.message}"
  end

  def authenticate_attached_file_roster!(source_names, attached_names, label)
    source = source_names.sort
    attached = attached_names.sort
    require!(source.uniq == source && !source.include?(ATTACHED_NATIVE_EXTRA_FILE),
      "#{label} source file roster is duplicate or already contains the native-added file")
    expected = (source + [ATTACHED_NATIVE_EXTRA_FILE]).sort
    require!(attached.uniq == attached && attached == expected,
      "#{label} attached file roster differs from source plus the one authenticated native-added file")
    true
  end

  def authenticate_attached_file_bytes!(name, source_bytes, attached_bytes, label)
    require!(name.is_a?(String) && source_bytes.is_a?(String) && attached_bytes.is_a?(String) &&
             source_bytes == attached_bytes,
      "#{label} attached bytes differ from the authenticated source: #{name}")
    true
  end

  def audit_attached_copy!(source_path, source_inventory, attached_path, label)
    source_root = canonical_root(source_path, "#{label} source part")
    attached_root = canonical_root(attached_path, "#{label} attached part")
    source_tree = plain_tree!(source_root, "#{label} source part")
    attached_tree = plain_tree!(attached_root, "#{label} attached part")
    inventory = normalize_attached_source_inventory(source_inventory, label)
    source_names = Dir.children(source_root).sort
    attached_names = Dir.children(attached_root).sort
    require!(source_names == inventory.keys.sort, "#{label} source file roster differs from authenticated helper inventory")
    authenticate_attached_file_roster!(source_names, attached_names, label)
    require!(source_tree.fetch(:files) == source_names.size &&
             attached_tree.fetch(:files) == attached_names.size,
      "#{label} attached/source part contains nested or unrostered files")
    inventory.each do |name, expected|
      source_bytes = read_plain(File.join(source_root, name), MAX_PART_FILE_BYTES, "#{label} source #{name}")
      attached_bytes = read_plain(File.join(attached_root, name), MAX_PART_FILE_BYTES, "#{label} attached #{name}")
      require!(source_bytes.bytesize == expected.fetch('size') && sha256(source_bytes) == expected.fetch('sha256'),
        "#{label} source file changed after helper authentication: #{name}")
      authenticate_attached_file_bytes!(name, source_bytes, attached_bytes, label)
    end
    extra = read_plain(File.join(attached_root, ATTACHED_NATIVE_EXTRA_FILE), MAX_PART_FILE_BYTES,
      "#{label} native-added attached metadata")
    require!(extra == ATTACHED_NATIVE_EXTRA_BYTES,
      "#{label} native-added attached metadata differs from the sole observed file")
    true
  end

  def audit_source_stage_output!(details, stage, id, layout, string_version, root, expected_table: nil)
    sql = details.fetch(:input)
    stdout = details.fetch(:stdout)
    case stage
    when 'write'
      table = /CREATE TABLE default\.([a-zA-Z0-9_]+) \(pk UInt64, doc #{Regexp.escape(STOCK_TYPE)}\)/.match(sql)&.[](1)
      require!(table && sql.include?("INSERT INTO default.#{table} VALUES") &&
               sql.include?("object_shared_data_serialization_version='#{layout.fetch(:setting)}'") &&
               sql.include?("object_shared_data_serialization_version_for_zero_level_parts='#{layout.fetch(:setting)}'") &&
               sql.include?("string_serialization_version='#{string_version.zero? ? 'single_stream' : 'with_size_stream'}'"),
        "#{id} source write SQL/profile differs")
      part_path = audit_attached_check_schema!(stdout, id, table, File.join(root, 'stores', 'native'))
      return {table: table, part_path: part_path}
    when 'direct', 'full'
      table = table_from_sql(sql)
      authenticate_source_query_table!(table, expected_table, "#{id} source #{stage}")
      return audit_w241_query_output!(details, stage, id, table, positive: true)
    end
    true
  end

  def audit_attached_check_schema!(stdout, id, expected_table, store_root)
    audit_native_check_output!(stdout, id, "#{id} attached")
    schema_rows = stdout.lines.map(&:chomp).select do |line|
      line.split("\t", -1).first == '__W241_SCHEMA__'
    end.map { |line| line.split("\t", -1) }
    require!(schema_rows == [
      ['__W241_SCHEMA__', id, 'pk', 'UInt64'],
      ['__W241_SCHEMA__', id, 'doc', STOCK_TYPE],
    ], "#{id} attached schema rows differ or contain extra identities")
    part_rows = stdout.lines.map(&:chomp).select { |line| line.start_with?("__W241_PART__\t") }
      .map { |line| line.split("\t", -1) }
    require!(part_rows.size == 1 && part_rows[0].size == 8,
      "#{id} attached output does not contain exactly one complete 8-field PART row")
    part = part_rows[0]
    require!(part.values_at(0, 1, 2, 3, 5, 6, 7) ==
             ['__W241_PART__', id, expected_table, 'all_1_1_0', 'Wide', '8', '5'],
      "#{id} attached active part identity/count differs")
    path = part.fetch(4)
    expanded_path = File.expand_path(path)
    expanded_root = File.expand_path(store_root)
    require!(path == "#{expanded_path}#{File::SEPARATOR}" &&
             expanded_path.start_with?("#{expanded_root}#{File::SEPARATOR}") &&
             File.basename(expanded_path) == 'all_1_1_0',
      "#{id} attached PART path is not a canonical part directory in the isolated store")
    expanded_path
  end

  def audit_native_runtime_pin!(stdout, tag, label)
    expected = "#{tag}\t#{SOURCE_RUNTIME.fetch('version')}\t#{SOURCE_RUNTIME.fetch('build')}"
    rows = stdout.lines.map(&:chomp).select { |line| line.split("\t", -1).first == tag }
    require!(rows == [expected], "#{label} stdout does not contain exactly one complete pinned runtime row")
    true
  end

  def audit_native_check_output!(stdout, id, label)
    lines = stdout.lines.map(&:chomp)
    begin_tag = "__W241_CHECK_BEGIN__\t#{id}"
    end_tag = "__W241_CHECK_END__\t#{id}"
    begin_indexes = lines.each_index.select { |index| lines[index] == begin_tag }
    end_indexes = lines.each_index.select { |index| lines[index] == end_tag }
    require!(begin_indexes.size == 1 && end_indexes.size == 1 && begin_indexes.first < end_indexes.first,
      "#{label} CHECK delimiters differ")
    check_lines = lines[(begin_indexes.first + 1)...end_indexes.first]
    require!(check_lines == ["all_1_1_0\t1\t"], "#{label} CHECK result differs")
    true
  end

  def table_from_sql(sql)
    match = /FROM default\.([a-zA-Z0-9_]+)/.match(sql)
    match && match[1]
  end

  def array_json_type?(name)
    name == 'Array(JSON)' || name.match?(/\AArray\(JSON\(.+\)\)\z/)
  end

  def tagged_sql_statement(sql, tag, table, label)
    tag_expression = /\ASELECT\s+'#{Regexp.escape(tag)}'/i
    candidates = sql.split(';').map(&:strip).reject(&:empty?).select { |statement| statement.match?(tag_expression) }
    require!(candidates.size == 1, "#{label} SQL tag #{tag} is absent or duplicated")
    statement = candidates.first
    require!(statement.match?(/\bFROM\s+default\.#{Regexp.escape(table)}\b/i),
      "#{label} SQL tag #{tag} is bound to another table")
    statement
  end

  def sql_predicate(statement)
    match = /\bWHERE\s+(.+?)(?=\s+SETTINGS\b|\s+ORDER\s+BY\b|\s+FORMAT\b|\z)/im.match(statement)
    match && match[1].strip.gsub(/\s+/, ' ')
  end

  def audit_native_zero_selection!(statement, stdout, id)
    require!(sql_predicate(statement) == 'pk > 8' &&
             statement.match?(/\btoString\s*\(\s*count\s*\(\s*\)\s*\)/i) &&
             statement.match?(/\bgroupArray\s*\(\s*doc\s*\)/i) &&
             statement.match?(/\bhex\s*\(\s*toJSONString\s*\(\s*groupArray\s*\(\s*doc\s*\)\s*\)\s*\)/i),
      "#{id} native zero-query predicate or aggregate expression differs")
    rows = stdout.lines.map(&:chomp).select { |line| line.start_with?("__W241_ZERO_QUERY__\t") }
    require!(rows.size == 1, "#{id} native zero-query marker is absent or duplicated")
    fields = rows.first.split("\t", -1)
    require!(fields.size == 3 && fields[0] == '__W241_ZERO_QUERY__' && fields[1] == '0' &&
             parse_hex_json(fields[2], "#{id} native zero-query grouped documents") == [],
      "#{id} native zero-query output is not the exact empty SQL selection")
    {selection_count: 0, grouped_documents: [], evidence_scope: 'empty_sql_selection_not_physical_eof'}
  end

  def audit_w241_query_output!(details, stage, id, table, positive:)
    sql = details.fetch(:input)
    stdout = details.fetch(:stdout)
    require!(table.is_a?(String) && !table.empty?, "#{id} #{stage} SQL table cannot be identified")
    if stage == 'direct'
      require!(sql.include?('doc.arr') && sql.include?('doc.mixed') && sql.include?('doc.late') &&
               !sql.include?('toJSONString(doc)') && !sql.include?('JSONSharedDataPaths') &&
               !sql.match?(/SELECT[^;]*\bdoc\s*[,)]/mi),
        "#{id} direct SQL is not direct-path-only")
      rows = stdout.lines.map(&:chomp).select { |line| line.start_with?("__W241_DIRECT__\t#{id}\t") }
      require!(rows.size == ROWS.size, "#{id} direct query row count differs")
      actual = {}
      rows.each do |line|
        fields = line.split("\t", -1)
        require!(fields.size == 12 && fields[1] == id, "#{id} direct row shape/profile differs")
        pk = Integer(fields.fetch(2), 10)
        require!(!actual.key?(pk), "#{id} direct query duplicated pk #{pk}")
        expected = ROWS.find { |row| row.fetch(:pk) == pk } || raise(AuditError, "#{id} direct pk outside fixture")
        values = fields.values_at(5, 8, 11).map { |hex| parse_hex_json(hex, "#{id} direct pk #{pk}") }
        type_witnesses = fields.values_at(4, 7, 10)
        require!(type_witnesses.none?(&:empty?), "#{id} direct dynamic type witness is empty at pk #{pk}")
        if expected.fetch(:doc).fetch('arr', nil) == []
          require!(fields[4] == 'Array(Nullable(String))' && values[0] == [],
            "#{id} direct empty-array carrier differs at pk #{pk}")
        elsif expected.fetch(:doc).fetch('arr', nil).is_a?(Array)
          require!(array_json_type?(fields[4]), "#{id} direct Array(JSON) type witness differs at pk #{pk}")
        end
        if pk == 8
          require!(array_json_type?(fields[10]), "#{id} direct late-only Array(JSON) witness is absent")
        end
        doc = expected.fetch(:doc)
        require!(values == [doc.fetch('arr', nil), doc.fetch('mixed', nil), doc.fetch('late', nil)],
          "#{id} direct query logical values differ at pk #{pk}") if positive
        actual[pk] = {arr: values[0], mixed: values[1], late: values[2],
                      arr_type: fields[4], mixed_type: fields[7], late_type: fields[10],
                      arr_wrapper_type: fields[3], mixed_wrapper_type: fields[6], late_wrapper_type: fields[9]}
      end
      require!(actual.keys.sort == ROWS.map { |row| row.fetch(:pk) }, "#{id} direct pk domain differs")
      {rows_by_pk: actual}
    else
      require!(sql.include?('toJSONString(doc)') && sql.include?('JSONSharedDataPaths(doc)'),
        "#{id} full SQL projections are absent")
      expected_predicates = {
        '__W241_FULL__' => nil,
        '__W241_MIDDLE__' => 'pk BETWEEN 3 AND 6',
        '__W241_LAST__' => 'pk = 8',
        '__W241_ZERO_QUERY__' => 'pk > 8',
      }
      statements = expected_predicates.to_h do |tag, predicate|
        statement = tagged_sql_statement(sql, tag, table, "#{id} full")
        require!(sql_predicate(statement) == predicate,
          "#{id} full SQL predicate differs for #{tag}")
        [tag, statement]
      end
      expected_tags = {'__W241_FULL__' => ROWS.map { |row| row.fetch(:pk) },
                       '__W241_MIDDLE__' => [3, 4, 5, 6], '__W241_LAST__' => [8]}
      result = {}
      expected_tags.each do |tag, domain|
        lines = stdout.lines.map(&:chomp).select { |line| line.start_with?("#{tag}\t") }
        require!(lines.size == domain.size, "#{id} #{tag} row count differs")
        actual = {}
        lines.each do |line|
          fields = line.split("\t", -1)
          require!(fields.size == 7 && fields[1] == table, "#{id} #{tag} row shape/table differs")
          pk = Integer(fields.fetch(2), 10)
          require!(domain.include?(pk) && !actual.key?(pk), "#{id} #{tag} pk is outside/duplicated in its domain")
          expected = ROWS.find { |row| row.fetch(:pk) == pk } || raise(AuditError, "#{id} full pk outside fixture")
          document = parse_hex_json(fields.fetch(4), "#{id} full pk #{pk}")
          dynamic_paths = parse_hex_json(fields.fetch(5), "#{id} dynamic paths pk #{pk}")
          shared_paths = parse_hex_json(fields.fetch(6), "#{id} shared paths pk #{pk}")
          require!(dynamic_paths == [] && shared_paths.is_a?(Array) && shared_paths.sort == document.keys.sort,
            "#{id} #{tag} path roster differs at pk #{pk}")
          require!(document == expected.fetch(:doc),
            "#{id} full query logical document differs at pk #{pk}") if positive
          actual[pk] = document
        end
        require!(actual.keys.sort == domain.sort, "#{id} #{tag} pk domain differs")
        result[tag] = actual
      end
      full_rows = result.fetch('__W241_FULL__')
      ['__W241_MIDDLE__', '__W241_LAST__'].each do |bounded_tag|
        result.fetch(bounded_tag).each do |pk, document|
          require!(document == full_rows.fetch(pk),
            "#{id} #{bounded_tag} row differs from the authenticated full result at pk #{pk}")
        end
      end
      zero = audit_native_zero_selection!(statements.fetch('__W241_ZERO_QUERY__'), stdout, id)
      {full_docs_by_pk: result.fetch('__W241_FULL__'), bounded_docs_by_tag: result,
       zero_selection: zero}
    end
  rescue ArgumentError, IndexError => error
    raise AuditError, "#{id} #{stage} query output is malformed: #{error.message}"
  end

  # W240's object_structure files are the physical authority for actual shared
  # version and bucket count; CREATE settings and summary enum are not used as
  # a substitute. W241 adds the decoded ADVANCED schedules to the same record.
  def parse_object_header(bytes, label)
    W190_PROBE.allocate.send(:parse_structure_prefix!, bytes, label)
  end

  def self_test!(summary_path)
    # This first pass is the full raw-evidence auditor, not a parser-only
    # smoke test. It authenticates the two newly written, checksum-repaired
    # negative parts, their current inventories, decompressor captures, and
    # native attach/CHECK/query outcomes before scoped normal-guard mutations.
    scoped_context = {}
    accepted = audit_capture!(summary_path, collect_context: scoped_context)
    self_test_source_provenance_guards!
    self_test_generated_origin_guards!
    self_test_selected_path_carrier_bridge!
    self_test_ordinary_json_occurrence_context!
    self_test_w240_invocation_record_enrichment!
    self_test_nested_coordinate_oracle!
    self_test_coordinate_lane_key_domains!
    self_test_bounded_window_auditor!
    self_test_native_zero_selection_auditor!
    self_test_negative_part_projection!
    self_test_copy_truncation_failure_guard!
    original = scoped_context.fetch(:summary)
    root = accepted.fetch(:root)
    negative_statuses = original.fetch('negative_controls').to_h do |control|
      [control.fetch('kind'), control.fetch('status')]
    end
    require!(negative_statuses.keys.sort == %w[copy_truncated data_corrupt],
      'W241 self-test did not audit both freshly generated negative controls')
    require!(negative_statuses.values.all? { |status| status == 'negative_control_observed' },
      'W241 self-test did not observe both negative-control effects')

    scoped_mutations = self_test_scoped_mutation_controls!(scoped_context)
    {root: root, negative_control_statuses: negative_statuses,
     source_provenance_oracle: 'helper roles, fresh source PART identity, and source query table bound to the write',
     selected_path_carrier_oracle: 'one outer carrier bridge; exact selected-path actual descriptors and values; no stock nested-child Dynamic type oracle',
     w240_invocation_record_enrichment: 'exact pinned summary-only SHA accepted; forged, missing, and extra fields rejected',
     nested_coordinate_oracle: 'seeded parser controls only; no captured part was mutated',
     bounded_window_oracle: 'positive full-slice control accepted; forged expected and actual rows rejected',
     native_zero_selection_oracle: 'pk > 8 empty SQL selection accepted; wrong predicate and nonempty grouped output rejected',
     negative_query_projection_oracle: 'summary emits exact direct fields and full docs only; raw wrapper, bounded-window, and zero-selection checks remain independent; actual-capture mutations rejected',
     negative_part_projection_oracle: 'exact emitted seven-field summary joins to reopened Symbol-key fields; missing, extra, and mismatched fields rejected',
     copy_truncation_failure_oracle: 'only the pinned exit-33 doc/mark-3 failure on the exact Copy target counts as evidence; process and context mutants rejected',
     scoped_mutation_controls: scoped_mutations}
  end

  def self_test_negative_part_projection!
    summary = {
      'path' => '/part',
      'physical_file_names' => ['a.bin', 'columns.txt'],
      'complete_file_inventory' => {'a.bin' => {'size' => 1}, 'columns.txt' => {'size' => 2}},
      'logical_substreams' => ['doc.object_structure'],
      'object_substreams' => ['doc.object_structure'],
      'raw_shared_streams' => {'doc.object_structure' => {'decoded_sha256' => 'abc'}},
      'source_kind' => 'copy_truncated',
    }
    reopened = {
      path: '/part',
      physical_file_names: ['a.bin', 'columns.txt'],
      complete_file_inventory: {'a.bin' => {'size' => 1}, 'columns.txt' => {'size' => 2}},
      logical_substreams: ['doc.object_structure'],
      object_substreams: ['doc.object_structure'],
      columns_substreams_text: "columns\n",
      raw_shared_streams: {'doc.object_structure' => {'decoded_sha256' => 'abc'}},
      source_kind: 'copy_truncated',
      physical_layout: {'version' => 1},
    }
    assert_negative_part_projection!(summary, reopened, 'W241 projection self-test')

    missing_summary_path = summary.reject { |key, _value| key == 'path' }
    expect_exact_reject!('negative part projection with missing summary path',
      'W241 projection self-test summary field roster differs') do
      assert_negative_part_projection!(missing_summary_path, reopened, 'W241 projection self-test')
    end

    extra_summary_columns_text = summary.merge('columns_substreams_text' => "columns\n")
    expect_exact_reject!('negative part summary with un-emitted columns text field',
      'W241 projection self-test summary field roster differs') do
      assert_negative_part_projection!(extra_summary_columns_text, reopened, 'W241 projection self-test')
    end

    missing_reopened_path = reopened.reject { |key, _value| key == :path }
    expect_exact_reject!('negative part reopened projection with missing path',
      'W241 projection self-test reopened field roster differs') do
      assert_negative_part_projection!(summary, missing_reopened_path, 'W241 projection self-test')
    end

    missing_reopened_columns = reopened.reject { |key, _value| key == :columns_substreams_text }
    expect_exact_reject!('negative part reopened projection with missing columns text',
      'W241 projection self-test reopened field roster differs') do
      assert_negative_part_projection!(summary, missing_reopened_columns, 'W241 projection self-test')
    end

    missing_reopened_layout = reopened.reject { |key, _value| key == :physical_layout }
    expect_exact_reject!('negative part reopened projection with missing physical layout',
      'W241 projection self-test reopened field roster differs') do
      assert_negative_part_projection!(summary, missing_reopened_layout, 'W241 projection self-test')
    end

    extra_reopened_field = reopened.merge(unexpected_internal_field: true)
    expect_exact_reject!('negative part reopened projection with extra internal field',
      'W241 projection self-test reopened field roster differs') do
      assert_negative_part_projection!(summary, extra_reopened_field, 'W241 projection self-test')
    end

    wrong_summary_path = summary.merge('path' => '/other-part')
    expect_exact_reject!('negative part projection with mismatched path',
      'W241 projection self-test summary path differs from reopened part') do
      assert_negative_part_projection!(wrong_summary_path, reopened, 'W241 projection self-test')
    end

    string_lookalike_inventory = reopened.reject { |key, _value| key == :complete_file_inventory }
      .merge('complete_file_inventory' => reopened.fetch(:complete_file_inventory))
    expect_exact_reject!('negative part projection with only a String-key reopened inventory',
      'W241 projection self-test reopened field roster differs') do
      assert_negative_part_projection!(summary, string_lookalike_inventory, 'W241 projection self-test')
    end

    wrong_inventory = reopened.merge(complete_file_inventory: {'a.bin' => {'size' => 99}})
    expect_exact_reject!('negative part projection with mismatched inventory',
      'W241 projection self-test summary complete_file_inventory differs from reopened part') do
      assert_negative_part_projection!(summary, wrong_inventory, 'W241 projection self-test')
    end

    wrong_source_kind = reopened.merge(source_kind: 'data_corrupt')
    expect_exact_reject!('negative part projection with mismatched source kind',
      'W241 projection self-test summary source_kind differs from reopened part') do
      assert_negative_part_projection!(summary, wrong_source_kind, 'W241 projection self-test')
    end
    true
  end

  def self_test_copy_truncation_failure_guard!
    id = 'advanced_chunked_s0_negative_copy_truncated'
    table = 'w241_1234abcd_advanced_chunked_s0_negative_copy_truncated_target'
    part_path = '/private/tmp/w241-copy-truncation-self-test/all_1_1_0'
    record = {
      'label' => 'negative_full_copy_truncated', 'process_kind' => 'clickhouse-local',
      'process_classification' => 'server_exception', 'exit' => 33, 'signal' => nil,
      'timed_out' => false, 'spawn_error' => nil, 'stdin_write_error' => nil,
      'stdout_read_error' => nil, 'stderr_read_error' => nil,
    }
    stdout = "__W241_PIN__\t#{SOURCE_RUNTIME.fetch('version')}\t#{SOURCE_RUNTIME.fetch('build')}\n"
    stderr = "Code: 33. DB::Exception: Cannot read all data (while reading column doc): " \
      "from part #{part_path}/ in table default.#{table} (uuid), from mark 3 with max_rows_to_read = 2 " \
      '(CANNOT_READ_ALL_DATA)'
    details = {stdout: stdout, stderr: stderr}
    authenticate_copy_truncation_failure!(record, details, id, table, part_path,
      'copy truncation positive self-test')
    authenticate_copy_truncation_query_sql!(
      expected_copy_truncation_query_sql(table), table, 'copy truncation SQL positive self-test')

    failure_mutations = {
      'timeout' => record.merge('timed_out' => true),
      'spawn error' => record.merge('spawn_error' => 'spawn failed'),
      'signal' => record.merge('signal' => 9),
      'wrong exit code' => record.merge('exit' => 32),
      'wrong process classification' => record.merge('process_classification' => 'process_failed'),
    }
    failure_mutations.each do |description, mutated|
      expect_reject!("copy truncation #{description} self-test") do
        authenticate_copy_truncation_failure!(mutated, details, id, table, part_path,
          "copy truncation #{description} self-test")
      end
    end
    expect_reject!('copy truncation wrong table diagnostic self-test') do
      authenticate_copy_truncation_failure!(record,
        details.merge(stderr: stderr.sub("table default.#{table}", 'table default.w241_other_target')),
        id, table, part_path, 'copy truncation wrong table self-test')
    end
    expect_reject!('copy truncation wrong active part diagnostic self-test') do
      authenticate_copy_truncation_failure!(record,
        details.merge(stderr: stderr.sub(part_path, '/private/tmp/w241-other/all_1_1_0')),
        id, table, part_path, 'copy truncation wrong part self-test')
    end
    expect_reject!('copy truncation missing pin self-test') do
      authenticate_copy_truncation_failure!(record, details.merge(stdout: 'not pinned\n'),
        id, table, part_path, 'copy truncation missing pin self-test')
    end
    expect_reject!('copy truncation extra output row self-test') do
      authenticate_copy_truncation_failure!(record,
        details.merge(stdout: stdout + "__W241_FULL__\tunexpected\n"),
        id, table, part_path, 'copy truncation extra output self-test')
    end
    expect_reject!('copy truncation wrong full-query predicate self-test') do
      authenticate_copy_truncation_query_sql!(
        expected_copy_truncation_query_sql(table).sub('pk > 8', 'pk >= 8'), table,
        'copy truncation wrong predicate self-test')
    end

    direct = {rows_by_pk: ROWS.to_h do |row|
      doc = row.fetch(:doc)
      [row.fetch(:pk), {arr: doc.fetch('arr', nil), mixed: doc.fetch('mixed', nil), late: doc.fetch('late', nil)}]
    end}
    inconclusive_failure = derive_negative_outcome('copy_truncated', 'stage_observed', direct,
      'process_failed_observed', nil)
    require!(inconclusive_failure.fetch(:status) == 'inconclusive',
      'unvalidated process_failed status produced a Copy negative conclusion')
    targeted_failure = derive_negative_outcome('copy_truncated', 'stage_observed', direct,
      'process_failed_observed', :authenticated_copy_truncation, targeted_copy_failure: true)
    require!(targeted_failure.fetch(:status) == 'negative_control_observed',
      'validated Copy truncation did not produce the targeted negative conclusion')
    inconclusive_status = derive_negative_outcome('copy_truncated', 'stage_observed', direct,
      'process_or_observation_failure_inconclusive', nil, targeted_copy_failure: true)
    require!(inconclusive_status.fetch(:status) == 'inconclusive',
      'inconclusive process status produced a Copy negative conclusion')
    true
  end

  def expected_copy_truncation_query_sql(table)
    full_select = lambda do |tag, predicate = nil|
      where = predicate ? " WHERE #{predicate}" : ''
      "SELECT '#{tag}', '#{table}', toString(pk), toTypeName(doc), hex(toJSONString(doc)), " \
        "hex(toJSONString(JSONDynamicPaths(doc))), hex(toJSONString(JSONSharedDataPaths(doc))) " \
        "FROM default.#{table}#{where} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;"
    end
    [
      'SET output_format_json_quote_64bit_integers=0;',
      "SELECT '__W241_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
      full_select.call('__W241_FULL__'),
      full_select.call('__W241_MIDDLE__', 'pk BETWEEN 3 AND 6'),
      full_select.call('__W241_LAST__', 'pk = 8'),
      "SELECT '__W241_ZERO_QUERY__', toString(count()), hex(toJSONString(groupArray(doc))) " \
        "FROM default.#{table} WHERE pk > 8 SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;",
    ].join("\n")
  end

  def self_test_scoped_mutation_controls!(context)
    id = 'advanced_s0'
    profile = context.fetch(:profile)
    helper_profile = context.fetch(:helper_profile)
    helper_input_profile = context.fetch(:helper_input_profile)
    by_label = context.fetch(:by_label)
    w240 = context.fetch(:w240)
    root = context.fetch(:root)
    layout = context.fetch(:layout)

    missing_data_manifest = profile.fetch('native_stream_decodes').fetch('generated')
      .reject { |entry| entry.fetch('stream') == 'doc.object_shared_data.0.data' }
    missing_data_error = expect_exact_reject!(
      'scoped missing generated Data manifest',
      'scoped advanced_s0 generated native decompressor manifest is incomplete',
    ) do
      audit_native_stream_decodes!(root, helper_profile.fetch('generated_read'), layout, id, 'generated',
        missing_data_manifest, by_label, 'scoped advanced_s0 generated')
    end

    wrong_version_profile = profile.dup
    wrong_version_profile['shared_version'] = 0
    wrong_version_error = expect_exact_reject!(
      'scoped wrong shared_version',
      'advanced_s0 profile status or setting differs',
    ) do
      audit_w241_profile!(root, wrong_version_profile, helper_profile, helper_input_profile, by_label, w240,
        requested_frame_bytes: context.fetch(:requested_frame_bytes))
    end

    {
      missing_generated_data_manifest: missing_data_error,
      wrong_shared_version: wrong_version_error,
      scope: 'scoped normal-guard mutations after one complete authenticated audit; not mutated-capture replays',
    }
  end

  def self_test_bounded_window_auditor!
    full_rows = ROWS.map { |row| {'pk' => row.fetch(:pk), 'doc' => row.fetch(:doc)} }
    paths = %w[arr mixed late].to_h do |path|
      rows = ROWS.map do |row|
        {'pk' => row.fetch(:pk), 'type' => 'JSON', 'wrapper_type' => 'Dynamic',
         'value' => row.fetch(:doc).fetch(path, nil)}
      end
      [path, rows]
    end
    specs = {
      'middle' => {first_mark: 1, mark_count: 2, rows: [2, 2]},
      'last' => {first_mark: 3, mark_count: 1, rows: [2]},
      'empty_interior' => {first_mark: 2, mark_count: 0, rows: []},
      'zero_count_end' => {first_mark: 4, mark_count: 0, rows: []},
    }
    consumers = [['whole_object', nil, full_rows]] + paths.map { |path, rows| ['selected_path', path, rows] }
    windows = consumers.flat_map do |consumer, path, rows|
      specs.map do |window, spec|
        row_start = REAL_MARK_ROWS.take(spec.fetch(:first_mark)).sum
        slice = rows.slice(row_start, spec.fetch(:rows).sum) || []
        {'consumer' => consumer, 'path' => path, 'window' => window,
         'first_mark' => spec.fetch(:first_mark), 'mark_count' => spec.fetch(:mark_count),
         'expected_mark_row_counts' => spec.fetch(:rows), 'actual_mark_row_counts' => spec.fetch(:rows),
         'expected_rows' => slice, 'actual_rows' => slice, 'matches_full_slice' => true}
      end
    end
    read = {'bounded_windows' => windows, 'full_rows' => full_rows, 'direct_shared_path_rows' => paths,
            'mark_row_counts' => REAL_MARK_ROWS}
    audit_bounded_windows!(read, 'w241-self-test', 'synthetic positive')

    forged = JSON.parse(JSON.generate(read))
    late_last = forged.fetch('bounded_windows').find do |entry|
      entry.fetch('consumer') == 'selected_path' && entry.fetch('path') == 'late' &&
        entry.fetch('window') == 'last'
    end
    late_last.fetch('expected_rows').first['wrapper_type'] = 'forged'
    late_last.fetch('actual_rows').first['wrapper_type'] = 'forged'
    expect_reject!('bounded-window expected and actual rows forged while equality witness remains true') do
      audit_bounded_windows!(forged, 'w241-self-test', 'forged expected and actual rows')
    end

    phantom_window = JSON.parse(JSON.generate(read))
    windows = phantom_window.fetch('bounded_windows')
    empty_index = windows.index do |entry|
      entry.fetch('consumer') == 'whole_object' && entry.fetch('window') == 'empty_interior'
    end || raise(AuditError, 'synthetic empty-interior window is absent')
    windows[empty_index] = windows.fetch(empty_index).merge(
      'window' => 'terminal_eof', 'first_mark' => 4, 'mark_count' => 1,
      'expected_mark_row_counts' => [0], 'actual_mark_row_counts' => [0],
      'expected_rows' => [], 'actual_rows' => [],
    )
    require!(windows.size == 16, 'synthetic phantom-window control changed the roster size')
    expect_reject!('bounded-window matrix with a phantom sentinel consumer read') do
      audit_bounded_windows!(phantom_window, 'w241-self-test', 'phantom EOF window')
    end

    phantom_mark = JSON.parse(JSON.generate(read))
    phantom_mark['mark_row_counts'] = PHYSICAL_MARK_ROWS
    expect_reject!('reader descriptor that exposes the physical EOF sentinel as a real mark') do
      audit_bounded_windows!(phantom_mark, 'w241-self-test', 'five-mark reader descriptor')
    end

    physical_triples = [[0, 0, 2], [1, 0, 2], [2, 0, 2], [3, 0, 2], [4, 0, 0]]
    audit_physical_mark_triples!(physical_triples, physical_triples, 'synthetic physical mark positive')
    tampered_eof = JSON.parse(JSON.generate(physical_triples))
    tampered_eof[4][0] = 5
    expect_reject!('raw physical EOF tuple coordinate tampering') do
      audit_physical_mark_triples!(tampered_eof, physical_triples, 'tampered physical EOF')
    end
    true
  end

  def self_test_native_zero_selection_auditor!
    statement = "SELECT '__W241_ZERO_QUERY__', toString(count()), hex(toJSONString(groupArray(doc))) " \
      'FROM default.w241_self_test WHERE pk > 8 SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw'
    audit_native_zero_selection!(statement, "__W241_ZERO_QUERY__\t0\t5B5D\n", 'w241-self-test')

    wrong_predicate = statement.sub('pk > 8', 'pk >= 8')
    expect_reject!('native zero-selection query with changed predicate') do
      audit_native_zero_selection!(wrong_predicate, "__W241_ZERO_QUERY__\t0\t5B5D\n", 'w241-self-test')
    end
    expect_reject!('native zero-selection query with nonempty grouped result') do
      audit_native_zero_selection!(statement, "__W241_ZERO_QUERY__\t1\t5B7B7D5D\n", 'w241-self-test')
    end
    true
  end

  def self_test_source_provenance_guards!
    id = 'map_s0'
    layout = LAYOUTS.find { |entry| entry.fetch(:id) == 'map' }
    source = {'role' => 'stock_source'}
    generated = {'role' => 'crystal_generated'}
    authenticate_helper_read_roles!(source, generated, 'source provenance self-test')
    expect_reject!('source/generated helper slots with their roles flipped') do
      authenticate_helper_read_roles!({'role' => 'crystal_generated'}, {'role' => 'stock_source'}, id)
    end

    root = '/private/tmp/w241-source-provenance-self-test'
    source_path = File.join(root, 'stores', 'native', 'source', 'all_1_1_0')
    table = 'w241_source_map_s0'
    write = audit_source_stage_output!(
      source_write_self_test_details(id, table, source_path), 'write', id, layout, 0, root)
    authenticate_source_part_path!(source_path, write.fetch(:part_path), id)

    other_canonical_path = File.join(root, 'stores', 'native', 'other', 'all_1_1_0')
    other_write = audit_source_stage_output!(
      source_write_self_test_details(id, table, other_canonical_path), 'write', id, layout, 0, root)
    expect_reject!('another canonical in-store PART path substituted for source_read.part_path') do
      authenticate_source_part_path!(source_path, other_write.fetch(:part_path), id)
    end

    direct = source_direct_self_test_details(id, table)
    audit_source_stage_output!(direct, 'direct', id, layout, 0, root, expected_table: write.fetch(:table))
    wrong_table_direct = direct.merge(input: direct.fetch(:input).sub(
      "FROM default.#{table}", 'FROM default.w241_other_map_s0'))
    expect_reject!('otherwise-valid direct output queried from another table') do
      audit_source_stage_output!(wrong_table_direct, 'direct', id, layout, 0, root,
        expected_table: write.fetch(:table))
    end
    true
  end

  def self_test_generated_origin_guards!
    id = 'map_s0'
    layout = LAYOUTS.find { |entry| entry.fetch(:id) == 'map' }
    root = '/private/tmp/w241-generated-origin-self-test'
    store_root = File.join(root, 'stores', 'native')
    token = Digest::SHA256.hexdigest(File.expand_path(root))[0, 8]
    table = "w241_#{token}_#{id}_target"
    data_path = File.join(store_root, 'data', table)
    create_details = generated_target_create_self_test_details(root, store_root, id, layout, 0, table, data_path)
    origin = audit_generated_target_create!(create_details, id, layout, 0, 'generated-origin self-test', root)

    wrong_table_sql = create_details.fetch(:input).sub(table, "w241_00000000_#{id}_target")
    expect_reject!('generated CREATE origin with a substituted table/token') do
      audit_generated_target_create!(create_details.merge(input: wrong_table_sql), id, layout, 0,
        'wrong generated table self-test', root)
    end
    wrong_path = create_details.fetch(:stdout).sub(data_path, File.join('/private/tmp/outside-store', table))
    expect_reject!('generated CREATE origin with a canonical path outside its native store') do
      audit_generated_target_create!(create_details.merge(stdout: wrong_path), id, layout, 0,
        'wrong generated path self-test', root)
    end

    attach_sql = generated_attach_sql_self_test(id, table)
    authenticate_generated_attach_sql!(attach_sql, id, table, 'generated-origin self-test')
    wrong_attach = attach_sql.sub("ALTER TABLE default.#{table}", 'ALTER TABLE default.w241_other_target')
    expect_reject!('generated ATTACH/CHECK chain bound to a different table') do
      authenticate_generated_attach_sql!(wrong_attach, id, table, 'wrong generated attach self-test')
    end

    part_path = File.join(data_path, 'all_1_1_0')
    attach_stdout = generated_attach_stdout_self_test(id, table, part_path)
    attached = audit_attached_check_schema!(attach_stdout, id, table, store_root)
    authenticate_target_part_path!(origin.fetch(:data_path), attached, 'generated-origin self-test')
    wrong_schema = attach_stdout + "__W241_SCHEMA__\tother_profile\textra\tString\n"
    expect_reject!('generated ATTACH output with an extra schema identity') do
      audit_attached_check_schema!(wrong_schema, id, table, store_root)
    end
    other_part = File.join(store_root, 'other', 'all_1_1_0')
    wrong_part = audit_attached_check_schema!(generated_attach_stdout_self_test(id, table, other_part),
      id, table, store_root)
    expect_reject!('another canonical in-store PART path substituted for target data_path/all_1_1_0') do
      authenticate_target_part_path!(origin.fetch(:data_path), wrong_part, 'wrong attached part self-test')
    end

    direct_sql = "SELECT doc.arr FROM default.#{table} FORMAT TSVRaw;\n"
    authenticate_generated_query_table!(direct_sql, 'direct', table, id, 'generated-origin direct self-test')
    direct_no_newline = direct_sql[0...-1]
    authenticate_generated_query_table!(direct_no_newline, 'direct', table, id,
      'generated-origin no-newline direct self-test')
    wrong_direct = direct_sql.sub("FROM default.#{table}", 'FROM default.w241_other_target')
    expect_reject!('generated direct query bound to a different table') do
      authenticate_generated_query_table!(wrong_direct, 'direct', table, id, 'wrong generated direct self-test')
    end
    wrong_direct_no_newline = direct_no_newline.sub("FROM default.#{table}", 'FROM default.w241_other_target')
    expect_reject!('no-newline generated direct query bound to a different table') do
      authenticate_generated_query_table!(wrong_direct_no_newline, 'direct', table, id,
        'wrong no-newline generated direct self-test')
    end
    full_sql = %w[__W241_FULL__ __W241_MIDDLE__ __W241_LAST__ __W241_ZERO_QUERY__].map do |tag|
      "SELECT '#{tag}' FROM default.#{table}"
    end.join(";\n") + ";\n"
    authenticate_generated_query_table!(full_sql, 'full', table, id, 'generated-origin full self-test')
    full_no_newline = full_sql[0...-1]
    authenticate_generated_query_table!(full_no_newline, 'full', table, id,
      'generated-origin no-newline full self-test')
    wrong_full = full_sql.sub("FROM default.#{table}", 'FROM default.w241_other_target')
    expect_reject!('one generated full-query table reference bound elsewhere') do
      authenticate_generated_query_table!(wrong_full, 'full', table, id, 'wrong generated full self-test')
    end
    wrong_full_no_newline = full_no_newline.sub("FROM default.#{table}", 'FROM default.w241_other_target')
    expect_reject!('no-newline generated full query has one table reference bound elsewhere') do
      authenticate_generated_query_table!(wrong_full_no_newline, 'full', table, id,
        'wrong no-newline generated full self-test')
    end

    source_names = %w[a.bin b.mrk2]
    attached_names = (source_names + [ATTACHED_NATIVE_EXTRA_FILE]).sort
    authenticate_attached_file_roster!(source_names, attached_names, 'generated-origin roster self-test')
    expect_reject!('attached generated part missing its one native-added metadata file') do
      authenticate_attached_file_roster!(source_names, source_names, 'missing generated extra self-test')
    end
    expect_reject!('attached generated part with an unrostered extra file') do
      authenticate_attached_file_roster!(source_names, (source_names + ['unexpected.bin']).sort,
        'unexpected generated extra self-test')
    end
    authenticate_attached_file_bytes!('a.bin', 'same bytes', 'same bytes', 'generated-origin bytes self-test')
    expect_reject!('attached generated source bytes changed after helper authentication') do
      authenticate_attached_file_bytes!('a.bin', 'source bytes', 'different bytes', 'changed generated bytes self-test')
    end
    true
  end

  def generated_target_create_self_test_details(root, store_root, id, layout, string_version, table, data_path)
    statements = [
      'SET output_format_json_quote_64bit_integers=0',
      "SELECT '__W241_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw",
      "CREATE TABLE default.#{table} (pk UInt64, doc #{STOCK_TYPE}) ENGINE=MergeTree ORDER BY pk SETTINGS #{expected_generated_target_settings(layout, string_version)}",
      "SELECT '__W241_TARGET_PATH__', '#{id}', arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw",
    ]
    {input: statements.join(";\n") + ";\n",
     stdout: "__W241_TARGET_PATH__\t#{id}\t#{data_path}/\n",
     argv: ['clickhouse-client', '--query', 'captured', store_root],
     capture_root: root}
  end

  def generated_attach_sql_self_test(id, table)
    [
      'SET output_format_json_quote_64bit_integers=0',
      "SELECT '__W241_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw",
      "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'",
      "SELECT '__W241_CHECK_BEGIN__', '#{id}' FORMAT TSVRaw",
      "CHECK TABLE default.#{table} FORMAT TSV",
      "SELECT '__W241_CHECK_END__', '#{id}' FORMAT TSVRaw",
      "SELECT '__W241_SCHEMA__', '#{id}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw",
      "SELECT '__W241_PART__', '#{id}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw",
    ].join(";\n") + ";\n"
  end

  def generated_attach_stdout_self_test(id, table, part_path)
    [
      "__W241_CHECK_BEGIN__\t#{id}",
      "all_1_1_0\t1\t",
      "__W241_CHECK_END__\t#{id}",
      "__W241_SCHEMA__\t#{id}\tpk\tUInt64",
      "__W241_SCHEMA__\t#{id}\tdoc\t#{STOCK_TYPE}",
      "__W241_PART__\t#{id}\t#{table}\tall_1_1_0\t#{part_path}/\tWide\t8\t5",
    ].join("\n") + "\n"
  end

  def self_test_selected_path_carrier_bridge!
    helper_by_path = %w[arr mixed late].to_h do |path|
      rows = ROWS.map do |row|
        value = row.fetch(:doc).fetch(path, nil)
        type = case path
               when 'arr'
                 value.nil? ? 'NULL' : (value.empty? ? 'Array(Nullable(String))' : 'Array(JSON(max_dynamic_types=16, max_dynamic_paths=0))')
               when 'late'
                 value.nil? ? 'NULL' : 'Array(JSON(max_dynamic_types=16, max_dynamic_paths=0))'
               else
                 'JSON'
               end
        {'pk' => row.fetch(:pk), 'value' => value, 'type' => type, 'wrapper_type' => 'Dynamic(max_types=254)'}
      end
      [path, rows]
    end
    native_rows = ROWS.to_h do |row|
      pk = row.fetch(:pk)
      doc = row.fetch(:doc)
      [pk, {
        arr: doc.fetch('arr', nil), mixed: doc.fetch('mixed', nil), late: doc.fetch('late', nil),
        arr_type: helper_by_path.fetch('arr').find { |entry| entry.fetch('pk') == pk }.fetch('type'),
        mixed_type: helper_by_path.fetch('mixed').find { |entry| entry.fetch('pk') == pk }.fetch('type'),
        late_type: helper_by_path.fetch('late').find { |entry| entry.fetch('pk') == pk }.fetch('type'),
        arr_wrapper_type: 'Dynamic', mixed_wrapper_type: 'Dynamic', late_wrapper_type: 'Dynamic',
      }]
    end
    helper = {'role' => 'stock_source', 'direct_shared_path_rows' => helper_by_path}
    native = {rows_by_pk: native_rows}
    assert_helper_direct_types_match_native!(helper, native, 'map_s0', 'stock source')

    wrong_helper_cap = JSON.parse(JSON.generate(helper))
    wrong_helper_cap.fetch('direct_shared_path_rows').fetch('arr').first['wrapper_type'] = 'Dynamic(max_types=16)'
    expect_reject!('selected-path carrier with a changed helper outer max_types cap') do
      assert_helper_direct_types_match_native!(wrong_helper_cap, native, 'map_s0', 'stock source')
    end

    wrong_native_cap = Marshal.load(Marshal.dump(native))
    wrong_native_cap.fetch(:rows_by_pk).fetch(1)[:arr_wrapper_type] = 'Dynamic(max_types=254)'
    expect_reject!('selected-path carrier bridge with a changed native logical wrapper') do
      assert_helper_direct_types_match_native!(helper, wrong_native_cap, 'map_s0', 'stock source')
    end

    wrong_child_type = JSON.parse(JSON.generate(helper))
    wrong_child_type.fetch('direct_shared_path_rows').fetch('arr').first['type'] =
      'Array(JSON(max_dynamic_types=16, max_dynamic_paths=1))'
    expect_reject!('selected-path bridge with a nested JSON child cap mismatch') do
      assert_helper_direct_types_match_native!(wrong_child_type, native, 'map_s0', 'stock source')
    end

    wrong_nested_dynamic = JSON.parse(JSON.generate(helper))
    wrong_nested_dynamic.fetch('direct_shared_path_rows').fetch('late').last['type'] =
      'Array(Dynamic(max_types=16))'
    expect_reject!('selected-path bridge with a nested Dynamic cap-string mismatch') do
      assert_helper_direct_types_match_native!(wrong_nested_dynamic, native, 'map_s0', 'stock source')
    end

    wrong_child_value = JSON.parse(JSON.generate(helper))
    wrong_child_value.fetch('direct_shared_path_rows').fetch('late').last['value'] = []
    expect_reject!('selected-path bridge with a changed late child value') do
      assert_helper_direct_types_match_native!(wrong_child_value, native, 'map_s0', 'stock source')
    end

    wrong_role = JSON.parse(JSON.generate(helper))
    wrong_role['role'] = 'crystal_generated'
    expect_reject!('selected-path bridge attached to the wrong helper origin role') do
      assert_helper_direct_types_match_native!(wrong_role, native, 'map_s0', 'stock source')
    end
    true
  end

  def self_test_ordinary_json_occurrence_context!
    direct_rows = ROWS.map do |row|
      value = row.fetch(:doc).fetch('arr', nil)
      type = if value.nil?
               'NULL'
             elsif value.empty?
               'Array(Nullable(String))'
             else
               'Array(JSON(max_dynamic_types=16, max_dynamic_paths=0))'
             end
      {'pk' => row.fetch(:pk), 'type' => type, 'value' => value}
    end
    root = {'path' => 'root', 'type_count' => 1, 'types' => ['Array(Nullable(String))']}
    descendant = {'path' => 'root.arm.0', 'type_count' => 1, 'types' => ['String']}
    no_json_events = [
      {'name' => '.dynamic_structure', 'relative_offset' => 0},
      {'name' => '.Array(Nullable(String)).size0', 'relative_offset' => 16},
    ]
    accepted_empty = audit_selected_path_occurrence_context!('arr', 2, 2, [root, descendant],
      direct_rows, no_json_events, 'seeded stock empty-array plus missing-row occurrence', role: 'stock_source')
    require!(!accepted_empty, 'seeded empty-array/missing-row occurrence was classified as JSON-bearing')

    empty_generated_root = {'path' => 'root', 'type_count' => 0, 'types' => []}
    generated_empty = audit_selected_path_occurrence_context!('arr', 2, 2, [empty_generated_root],
      direct_rows, no_json_events, 'seeded generated empty-array plus missing-row occurrence', role: 'crystal_generated')
    require!(!generated_empty, 'generated empty-array/missing-row occurrence was classified as JSON-bearing')

    json_type = 'Array(JSON(max_dynamic_types=16, max_dynamic_paths=0))'
    json_root = {'path' => 'root', 'type_count' => 1, 'types' => [json_type]}
    json_events = [{'name' => ".#{json_type}.object_structure", 'relative_offset' => 24}]
    accepted_json = audit_selected_path_occurrence_context!('arr', 0, 2, [json_root], direct_rows,
      json_events, 'seeded stock JSON-bearing occurrence', role: 'stock_source')
    require!(accepted_json, 'seeded JSON-bearing occurrence was not classified as JSON-bearing')

    generated_json_type = 'Array(JSON(max_dynamic_types=1, max_dynamic_paths=1, v UInt8))'
    generated_json_root = {'path' => 'root', 'type_count' => 1, 'types' => [generated_json_type]}
    generated_json_events = [{'name' => ".#{generated_json_type}.object_structure", 'relative_offset' => 24}]
    generated_json_rows = Marshal.load(Marshal.dump(direct_rows))
    generated_json_rows.find { |row| row.fetch('pk') == 1 }['type'] = generated_json_type
    generated_json_rows.find { |row| row.fetch('pk') == 2 }['type'] = generated_json_type
    generated_json = audit_selected_path_occurrence_context!('arr', 0, 2, [generated_json_root], generated_json_rows,
      generated_json_events, 'seeded generated JSON-bearing occurrence', role: 'crystal_generated')
    require!(generated_json, 'generated prepared JSON arm was not classified as JSON-bearing')

    # The explicit JSON descriptor remains a registered arm even when its
    # direct logical array is empty, so its object_structure callback is owed.
    typed_empty_rows = Marshal.load(Marshal.dump(direct_rows))
    typed_empty_rows.find { |row| row.fetch('pk') == 3 }['type'] = generated_json_type
    typed_empty_root = {'path' => 'root', 'type_count' => 1, 'types' => [generated_json_type]}
    typed_empty = audit_selected_path_occurrence_context!('arr', 2, 2, [typed_empty_root], typed_empty_rows,
      generated_json_events, 'seeded generated typed empty JSON arm', role: 'crystal_generated')
    require!(typed_empty, 'registered typed empty JSON arm lost its callback obligation')

    forged_json_callback = no_json_events + [
      {'name' => ".#{json_type}.object_structure", 'relative_offset' => 24},
    ]
    expect_reject!('empty-array/missing-row occurrence with a forged JSON callback') do
      audit_selected_path_occurrence_context!('arr', 2, 2, [root], direct_rows,
        forged_json_callback, 'seeded forged JSON callback', role: 'stock_source')
    end

    expect_reject!('JSON-bearing occurrence with its required object_structure callback removed') do
      audit_selected_path_occurrence_context!('arr', 0, 2, [json_root], direct_rows,
        no_json_events, 'seeded missing JSON callback', role: 'stock_source')
    end

    expect_reject!('registered empty JSON arm with its required object_structure callback removed') do
      audit_selected_path_occurrence_context!('arr', 2, 2, [typed_empty_root], typed_empty_rows,
        no_json_events, 'seeded missing callback for typed empty JSON arm', role: 'crystal_generated')
    end

    expect_reject!('generated registry retaining a non-JSON empty-array arm') do
      audit_selected_path_occurrence_context!('arr', 2, 2, [root], direct_rows,
        no_json_events, 'seeded generated unregistered carrier arm', role: 'crystal_generated')
    end

    expect_reject!('stock registry with an unregistered JSON arm') do
      audit_selected_path_occurrence_context!('arr', 2, 2, [json_root], direct_rows,
        json_events, 'seeded stock unregistered JSON arm', role: 'stock_source')
    end

    expect_reject!('unknown selected-path registry role') do
      audit_selected_path_occurrence_context!('arr', 2, 2, [], direct_rows,
        no_json_events, 'seeded unknown role', role: 'other')
    end

    unknown_rows = Marshal.load(Marshal.dump(direct_rows))
    unknown_rows.find { |row| row.fetch('pk') == 3 }['type'] = 'Array(UInt8)'
    expect_reject!('empty-array occurrence with an unknown actual descriptor') do
      audit_selected_path_occurrence_context!('arr', 2, 2,
        [{'path' => 'root', 'type_count' => 1, 'types' => ['Array(UInt8)']}],
        unknown_rows, no_json_events, 'seeded unknown descriptor', role: 'stock_source')
    end
    true
  end

  def source_write_self_test_details(id, table, part_path)
    sql = [
      "CREATE TABLE default.#{table} (pk UInt64, doc #{STOCK_TYPE})",
      "INSERT INTO default.#{table} VALUES",
      "object_shared_data_serialization_version='map'",
      "object_shared_data_serialization_version_for_zero_level_parts='map'",
      "string_serialization_version='single_stream'",
    ].join("\n")
    stdout = [
      "__W241_CHECK_BEGIN__\t#{id}",
      "all_1_1_0\t1\t",
      "__W241_CHECK_END__\t#{id}",
      "__W241_SCHEMA__\t#{id}\tpk\tUInt64",
      "__W241_SCHEMA__\t#{id}\tdoc\t#{STOCK_TYPE}",
      "__W241_PART__\t#{id}\t#{table}\tall_1_1_0\t#{part_path}/\tWide\t8\t5",
    ].join("\n") + "\n"
    {input: sql, stdout: stdout}
  end

  def source_direct_self_test_details(id, table)
    sql = "SELECT doc.arr, doc.mixed, doc.late FROM default.#{table} " \
      'SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw'
    stdout = ROWS.map do |row|
      doc = row.fetch(:doc)
      arr = doc.fetch('arr', nil)
      late = doc.fetch('late', nil)
      arr_type = if arr.nil?
                   'NULL'
                 elsif arr.empty?
                   'Array(Nullable(String))'
                 else
                   'Array(JSON(max_dynamic_paths=16))'
                 end
      late_type = late.nil? ? 'NULL' : 'Array(JSON(max_dynamic_paths=16))'
      fields = [
        '__W241_DIRECT__', id, row.fetch(:pk).to_s,
        'Dynamic', arr_type, JSON.generate(arr).unpack1('H*'),
        'Dynamic', 'JSON', JSON.generate(doc.fetch('mixed', nil)).unpack1('H*'),
        'Dynamic', late_type, JSON.generate(late).unpack1('H*'),
      ]
      fields.join("\t")
    end.join("\n") + "\n"
    {input: sql, stdout: stdout}
  end

  def self_test_w240_invocation_record_enrichment!
    pin = SOURCE_RUNTIME.fetch('sha256')
    artifact_record = {
      'process_classification' => 'success',
      'exit' => 0,
      'signal' => nil,
      'timed_out' => false,
      'expected_binary_sha256' => pin,
      'binary_sha_after' => pin,
    }
    summary_record = artifact_record.merge('binary_sha_before' => pin)
    authenticate_w240_invocation_record_artifact!(summary_record, artifact_record,
      'W240 enrichment self-test')

    forged_pin = summary_record.merge('binary_sha_before' => '0' * 64)
    expect_reject!('W240 invocation summary with an unpinned pre-invocation SHA') do
      authenticate_w240_invocation_record_artifact!(forged_pin, artifact_record,
        'W240 forged-pin self-test')
    end

    missing_artifact_field = artifact_record.reject { |key, _value| key == 'exit' }
    expect_reject!('W240 invocation artifact missing a base field') do
      authenticate_w240_invocation_record_artifact!(summary_record, missing_artifact_field,
        'W240 missing-field self-test')
    end

    extra_artifact_field = artifact_record.merge('unexpected' => true)
    expect_reject!('W240 invocation artifact with an unrostered extra field') do
      authenticate_w240_invocation_record_artifact!(summary_record, extra_artifact_field,
        'W240 extra-field self-test')
    end
  end

  def expect_reject!(label)
    yield
  rescue AuditError => error
    error.message
  else
    raise AuditError, "self-test accepted #{label}"
  end

  def expect_exact_reject!(label, expected_message)
    actual_message = expect_reject!(label) { yield }
    require!(actual_message == expected_message,
      "#{label} rejected for an unexpected reason: #{actual_message.inspect}")
    actual_message
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    if ARGV.size == 2 && ARGV.first == '--self-test'
      result = ReconcileObjectSharedJSONInteropW241.self_test!(ARGV.fetch(1))
      negative = result.fetch(:negative_control_statuses).map { |kind, status| "#{kind}=#{status}" }.join(',')
      puts "W241 audit self-test passed: full capture audit, negative controls [#{negative}], bounded-window and native zero-selection controls, exact W240 summary-only SHA enrichment controls, scoped missing-Data/version normal-guard controls (not full-capture replays), and seeded coordinate parser controls only"
    else
      warn 'Usage: ruby scripts/reconcile_object_shared_json_interop_w241.rb --self-test SUMMARY.json'
      exit 64
    end
  rescue StandardError => error
    warn "W241 audit failed: #{error.class}: #{error.message}"
    exit 1
  end
end
