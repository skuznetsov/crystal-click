#!/usr/bin/env ruby
# Offline verifier for a retained W195 paired-part run. It reuses the W191,
# W193, and W194 source checks and never invokes ClickHouse or the Crystal helper.

require 'digest'
require 'json'
require 'optparse'
require_relative 'check_array_json_parts_w185'
require_relative 'check_object_shared_advanced_parts_w195'
require_relative 'reconcile_object_shared_advanced_w191'
require_relative 'reconcile_object_shared_path_w193'
require_relative 'reconcile_object_shared_physical_w194'

module ReconcileObjectSharedAdvancedPartsW195
  extend self

  W185 = CheckArrayJSONPartsW185
  W195 = CheckObjectSharedAdvancedPartsW195
  R191 = ReconcileObjectSharedAdvancedW191
  R193 = ReconcileObjectSharedPathW193
  R194 = ReconcileObjectSharedPhysicalW194
  PROFILE_IDS = W195::PROFILE_IDS
  MARK_ROWS = W195::MARK_ROWS
  STOCK_METADATA_FILES = %w[
    checksums.txt
    columns.txt
    columns_substreams.txt
    count.txt
    default_compression_codec.txt
    metadata_version.txt
    primary.idx
    serialization.json
    statistics.packed
  ].freeze
  LIBRARY_METADATA_FILES = %w[
    checksums.txt
    columns.txt
    columns_substreams.txt
    count.txt
    default_compression_codec.txt
    metadata_version.txt
    primary.idx
    serialization.json
  ].freeze
  METADATA_FILES = STOCK_METADATA_FILES
  MAX_SUMMARY_BYTES = R191::MAX_SUMMARY_BYTES
  MAX_PART_FILE_BYTES = 16 * 1024 * 1024
  MAX_PART_TOTAL_BYTES = 64 * 1024 * 1024
  MAX_CAPTURE_BYTES = 32 * 1024 * 1024
  FORMAT = 'object_shared_advanced_parts_w195_offline_v1'.freeze

  class ReconcileError < StandardError; end

  def require!(condition, message)
    raise ReconcileError, message unless condition
  end

  def expected_metadata_files(kind)
    case kind
    when :stock
      STOCK_METADATA_FILES
    when :library
      LIBRARY_METADATA_FILES
    else
      raise ReconcileError, "unknown W195 part kind: #{kind.inspect}"
    end
  end

  def physical_roster_matches?(names, stream_files, kind)
    return false unless names.is_a?(Array) && stream_files.is_a?(Array)
    names == (expected_metadata_files(kind) + stream_files).sort
  end

  def native_binary_pins_match?(record)
    record['expected_binary_sha256'] == W185::BINARY_SHA256 &&
      record['binary_sha_before'] == W185::BINARY_SHA256 &&
      record['binary_sha_after'] == W185::BINARY_SHA256
  end

  # The W185 producer writes the local invocation artifact before adding
  # binary_sha_before to the in-memory summary record. No other projection is
  # admitted; helper records remain exact structural matches.
  def invocation_artifact_matches_summary?(artifact_record, summary_record, expected_kind)
    return false unless artifact_record.is_a?(Hash) && summary_record.is_a?(Hash)

    case expected_kind
    when 'clickhouse local'
      return false unless native_binary_pins_match?(summary_record)
      artifact_record == summary_record.reject { |field, _value| field == 'binary_sha_before' }
    when 'prebuilt Crystal helper'
      artifact_record == summary_record
    else
      false
    end
  end

  def read_plain_file(path, limit, label)
    require!(File.file?(path) && !File.symlink?(path), "#{label} is absent, non-file, or symlinked")
    size = File.size(path)
    require!(size <= limit, "#{label} exceeds #{limit} bytes")
    bytes = File.binread(path)
    require!(bytes.bytesize == size, "#{label} changed while being read")
    bytes
  end

  def read_json(path, limit, label)
    JSON.parse(read_plain_file(path, limit, label))
  rescue JSON::ParserError => error
    raise ReconcileError, "#{label} is invalid JSON: #{error.message}"
  end

  def sha256(bytes)
    Digest::SHA256.hexdigest(bytes)
  end

  def canonical_directory(path, label)
    require!(path.is_a?(String) && !path.empty?, "#{label} path is absent")
    require!(!File.symlink?(path), "#{label} path is a symlink")
    full = File.realpath(path)
    require!(File.directory?(full) && full == File.expand_path(path), "#{label} is not a canonical directory")
    full
  rescue SystemCallError => error
    raise ReconcileError, "#{label} path cannot be resolved: #{error.message}"
  end

  def ensure_no_symlink_ancestors!(path, stop_at)
    full = File.expand_path(path)
    stop = File.realpath(stop_at)
    require!(full.start_with?(stop + File::SEPARATOR), "path escapes its allowed root: #{path}")
    current = stop
    full.delete_prefix(stop + File::SEPARATOR).split(File::SEPARATOR).each do |component|
      current = File.join(current, component)
      next unless File.exist?(current) || File.symlink?(current)
      require!(!File.lstat(current).symlink?, "symlink in evidence path: #{current}")
      if current != full
        require!(File.directory?(current), "non-directory in evidence path: #{current}")
      end
    end
    full
  end

  def stringify_json(value)
    JSON.parse(JSON.generate(value))
  end

  def mark_grid_matches?(triples)
    triples.is_a?(Array) && triples.size == MARK_ROWS.size &&
      triples.all? { |triple| triple.is_a?(Array) && triple.size == 3 && triple.all? { |value| value.is_a?(Integer) && value >= 0 } } &&
      triples.map { |triple| triple[2] } == MARK_ROWS
  end

  # Object metadata has repeated real marks at its source-derived statistics
  # boundary; all other streams span decoded zero through logical EOF.
  def mark_offsets_valid_for_role?(logical_name, decoded_offsets, decoded_size, object_statistics_offset = nil)
    return false unless decoded_size.is_a?(Integer) && decoded_size >= 0
    return false unless decoded_offsets.is_a?(Array) && !decoded_offsets.empty?
    return false unless decoded_offsets.all? { |offset| offset.is_a?(Integer) && offset >= 0 && offset <= decoded_size }
    return false unless decoded_offsets.each_cons(2).all? { |left, right| right >= left }

    if logical_name == 'j.object_structure' || logical_name == 'a.object_structure'
      return false unless object_statistics_offset.is_a?(Integer) && object_statistics_offset >= 0 &&
                          object_statistics_offset < decoded_size
      return false unless decoded_offsets.size == MARK_ROWS.size && decoded_offsets.last == decoded_size
      decoded_offsets[0...-1].all? { |offset| offset == object_statistics_offset }
    else
      object_statistics_offset.nil? && decoded_offsets.first == 0 && decoded_offsets.last == decoded_size
    end
  end

  def object_statistics_offset_for_profile(source_profile, profile_id)
    expectation = R191::PROFILE_EXPECTATIONS.fetch(profile_id)
    require!(source_profile.fetch('id') == profile_id &&
             source_profile.fetch('kind') == expectation.fetch(:kind) &&
             source_profile.fetch('requested_shared_version') == expectation.fetch(:mode) &&
             source_profile.fetch('expected_actual_bucket_count') == expectation.fetch(:buckets),
      "#{profile_id}: authenticated Object profile identity differs")

    physical = source_profile.fetch('physical_layout')
    structure_hex = physical.fetch('object_structure_bytes_hex')
    require!(structure_hex.is_a?(String) && structure_hex.match?(/\A(?:[0-9a-f]{2})+\z/),
      "#{profile_id}: authenticated Object structure hex is malformed")
    structure_bytes = [structure_hex].pack('H*')
    parsed = R191.parse_object_structure(structure_bytes, "#{profile_id} authenticated Object structure")
    expected_shared_version = expectation.fetch(:mode) == 'advanced' ? 2 : 3
    require!(parsed.fetch('version') == 4 && parsed.fetch('dynamic_path_count') == 0 &&
             parsed.fetch('shared_data_version') == expected_shared_version &&
             parsed.fetch('bucket_count') == source_profile.fetch('expected_actual_bucket_count') &&
             parsed.fetch('statistics_flag') == 1,
      "#{profile_id}: authenticated Object structure header differs from the finite profile")

    statistics_offset = structure_bytes.bytesize - parsed.fetch('statistics_suffix_bytes') - 1
    require!(statistics_offset == 11 && statistics_offset < structure_bytes.bytesize,
      "#{profile_id}: authenticated Object statistics boundary differs from the finite profile")
    statistics_offset
  rescue KeyError => error
    raise ReconcileError, "#{profile_id}: authenticated Object header lacks #{error.key.inspect}"
  end

  def expected_native_probe
    probe = W195::Probe.allocate
    [probe.send(:initial_sql), probe.send(:attached_sql)]
  end

  def validate_summary_header!(root, summary, capture_root)
    require!(summary.is_a?(Hash), 'W195 summary must be a JSON object')
    required = %w[probe status fatal_error runtime helper capture_root manifest_sha256 limits claims invocations manifest source_profiles source_inventories library_inventories initial attached]
    require!(summary.keys.sort == required.sort, 'W195 summary field roster differs')
    require!(summary.fetch('probe') == 'W195 paired full-part Object ADVANCED/ADVANCED_CHUNKED qualification' &&
             summary.fetch('status') == 'paired_advanced_full_part_observed' && summary.fetch('fatal_error').nil?,
      'W195 summary is not a successful paired observation')
    require!(summary.fetch('capture_root') == capture_root, 'W195 summary capture root differs from supplied root')
    claims = summary.fetch('claims')
    require!(claims.keys.sort == %w[direct_dynamic_path_projection general_persisted_format_admission source_and_library_parts_attached_and_checked stock_capture_authenticated_by].sort &&
             claims.fetch('stock_capture_authenticated_by') == 'W191/W193/W194' &&
             claims.fetch('general_persisted_format_admission') == false &&
             summary.fetch('claims').fetch('source_and_library_parts_attached_and_checked') == true &&
             summary.fetch('claims').fetch('direct_dynamic_path_projection') == true,
      'W195 claim boundary is missing or broadened')
    runtime = summary.fetch('runtime')
    require!(runtime.keys.sort == %w[build expected_sha256 path sha256_after sha256_before version].sort,
      'W195 runtime field roster differs')
    require!(runtime.fetch('path') == W185::BINARY && runtime.fetch('expected_sha256') == W185::BINARY_SHA256 &&
             runtime.fetch('sha256_before') == W185::BINARY_SHA256 &&
             runtime.fetch('sha256_after') == W185::BINARY_SHA256 && runtime.fetch('version') == W185::VERSION &&
             runtime.fetch('build') == W185::BUILD,
      'W195 runtime/source pin differs from the bounded W185/W191 profile')
    limits = summary.fetch('limits')
    require!(limits.keys.sort == %w[local_max_memory_usage_bytes max_profiles max_threads required_outer_run_safe_memory_limit_bytes source_revision termination_grace_seconds timeout_seconds].sort,
      'W195 limit field roster differs')
    require!(limits.fetch('max_threads') == 1 &&
             limits.fetch('timeout_seconds') == W185::TIMEOUT &&
             limits.fetch('termination_grace_seconds') == W185::GRACE &&
             limits.fetch('max_profiles') == PROFILE_IDS.size &&
             summary.fetch('limits').fetch('local_max_memory_usage_bytes') == W185::MEMORY &&
             summary.fetch('limits').fetch('required_outer_run_safe_memory_limit_bytes') == W185::OUTER_RUN_SAFE_LIMIT &&
             summary.fetch('limits').fetch('source_revision') == R191::SOURCE_REVISION,
      'W195 execution limits or pinned source revision differ')
    require!(File.dirname(root) == File.realpath('/private/tmp'),
      'W195 evidence root must be a direct child of /private/tmp')
    require!(summary.fetch('invocations').is_a?(Array) && summary.fetch('invocations').size == 3,
      'W195 must contain exactly three captured process records')
  rescue KeyError => error
    raise ReconcileError, "W195 summary header lacks #{error.key.inspect}"
  end

  def validate_capture!(summary, capture_root)
    _root, source_summary, _copy_manifest, _details, _counts = R193.load_capture!(capture_root)
    manifest, manifest_json = R194.derive_manifest(capture_root)
    require!(sha256(manifest_json) == summary.fetch('manifest_sha256'), 'W195 source-manifest digest differs')
    require!(summary.fetch('manifest') == manifest, 'W195 embedded W194 manifest differs from rederived stock evidence')
    source_profiles = source_summary.fetch('profiles').to_h { |profile| [profile.fetch('id'), profile] }
    require!(source_profiles.keys.sort == PROFILE_IDS.sort, 'authenticated W191 source profile roster differs')
    require!(summary.fetch('source_profiles') == source_profiles,
      'W195 source profiles differ from reauthenticated W191 source capture')
    [manifest, source_profiles]
  rescue KeyError => error
    raise ReconcileError, "W195 source capture lacks #{error.key.inspect}"
  end

  def validate_invocation_record!(root, record, expected_label, expected_kind, expected_argv, expected_stdin)
    require!(record.is_a?(Hash) && record.fetch('process_kind') == expected_kind,
      "#{expected_label}: process identity differs")
    common_keys = %w[
      argv argv_sha256 binary_sha_after expected_binary_sha256 exit
      max_memory_usage_applicable max_memory_usage_bytes max_threads
      process_classification process_kind required_outer_run_safe_memory_limit_bytes
      signal spawn_error stderr_bytes stderr_file stderr_read_error stderr_sha256
      stdin_bytes stdin_sha256 stdin_write_error stdout_bytes stdout_file stdout_read_error
      stdout_sha256 termination_grace_seconds timed_out timeout_seconds
    ]
    local_keys = common_keys + %w[binary_sha_before stdin_file]
    require!(record.keys.sort == (expected_kind == 'clickhouse local' ? local_keys : common_keys).sort,
      "#{expected_label}: invocation record field roster differs")
    require!(record.fetch('argv') == expected_argv && record.fetch('exit') == 0 && record.fetch('signal').nil? &&
             record.fetch('timed_out') == false && record.fetch('process_classification') == 'success',
      "#{expected_label}: process status or argv differs")
    require!(record.fetch('timeout_seconds') == W185::TIMEOUT &&
             record.fetch('termination_grace_seconds') == W185::GRACE && record.fetch('max_threads') == 1 &&
             record.fetch('required_outer_run_safe_memory_limit_bytes') == W185::OUTER_RUN_SAFE_LIMIT,
      "#{expected_label}: bounded execution settings differ")
    %w[spawn_error stdin_write_error stdout_read_error stderr_read_error].each do |field|
      require!(record.fetch(field).nil?, "#{expected_label}: #{field} is non-nil")
    end
    require!(record.fetch('max_memory_usage_applicable') == (expected_kind == 'clickhouse local') &&
             record.fetch('max_memory_usage_bytes') == (expected_kind == 'clickhouse local' ? W185::MEMORY : nil),
      "#{expected_label}: memory applicability differs")
    invdir = File.join(root, 'invocations')
    require!(File.directory?(invdir) && !File.symlink?(invdir), 'invocation directory is absent or symlinked')
    ensure_no_symlink_ancestors!(invdir, root)
    label = expected_label
    argv_path = File.join(invdir, "#{label}.argv.json")
    record_file = "#{label}.json"
    stdout_file = "#{label}.stdout"
    stderr_file = "#{label}.stderr"
    require!(record.fetch('stdout_file') == stdout_file && record.fetch('stderr_file') == stderr_file,
      "#{label}: invocation artifact names differ")
    expected_stdin_file = expected_kind == 'clickhouse local' ? "#{label}.stdin.sql" : nil
    require!(record.fetch('stdin_file') == expected_stdin_file,
      "#{label}: stdin artifact name differs") if expected_kind == 'clickhouse local'
    argv_bytes = read_plain_file(argv_path, 64 * 1024, "#{label} argv")
    require!(JSON.parse(argv_bytes) == expected_argv && sha256(argv_bytes) == record.fetch('argv_sha256'),
      "#{label}: argv artifact differs")
    expected_argv_hash = sha256(JSON.pretty_generate(expected_argv) + "\n")
    require!(record.fetch('argv_sha256') == expected_argv_hash, "#{label}: recorded argv hash differs")
    stdout = read_plain_file(File.join(invdir, stdout_file), MAX_CAPTURE_BYTES, "#{label} stdout")
    stderr = read_plain_file(File.join(invdir, stderr_file), MAX_CAPTURE_BYTES, "#{label} stderr")
    require!(stderr.empty? && record.fetch('stderr_bytes') == 0 && record.fetch('stderr_sha256') == sha256(''.b),
      "#{label}: successful process has stderr")
    require!(record.fetch('stdout_bytes') == stdout.bytesize && record.fetch('stdout_sha256') == sha256(stdout),
      "#{label}: stdout artifact differs from invocation record")
    if expected_kind == 'clickhouse local'
      stdin = read_plain_file(File.join(invdir, expected_stdin_file), MAX_CAPTURE_BYTES, "#{label} stdin")
      require!(stdin == expected_stdin, "#{label}: stdin SQL differs from the fixed W195 query")
    else
      require!(expected_stdin.empty?, "#{label}: helper stdin expectation must be empty")
    end
    require!(record.fetch('stdin_bytes') == expected_stdin.bytesize &&
             record.fetch('stdin_sha256') == sha256(expected_stdin),
      "#{label}: stdin bytes/hash differ from the fixed invocation input")
    record_path = File.join(invdir, record_file)
    artifact_record = read_json(record_path, 256 * 1024, "#{label} record")
    require!(invocation_artifact_matches_summary?(artifact_record, record, expected_kind),
      "#{label}: captured invocation JSON differs from summary")
    if expected_kind == 'clickhouse local'
      require!(native_binary_pins_match?(record),
        "#{label}: runtime executable pin differs")
      pin = "__W195_PIN__\t#{W185::VERSION}\t#{W185::BUILD}"
      require!(stdout.lines.map(&:chomp).select { |line| line.start_with?("__W195_PIN__\t") } == [pin],
        "#{label}: stdout runtime pin differs")
    end
    {record: record, record_path: record_path, argv_path: argv_path, stdout: stdout, stderr: stderr}
  rescue KeyError => error
    raise ReconcileError, "#{expected_label} record lacks #{error.key.inspect}"
  rescue JSON::ParserError => error
    raise ReconcileError, "#{expected_label} capture JSON is invalid: #{error.message}"
  end

  def validate_invocations!(root, summary)
    records = summary.fetch('invocations')
    expected_labels = %w[native_create_targets crystal_pair_helper native_attach_check_read]
    require!(records.is_a?(Array) && records.size == expected_labels.size,
      'W195 process record roster/size differs')
    labels = records.map do |record|
      stdout_name = record.fetch('stdout_file')
      match = /\A([a-zA-Z0-9_-]+)\.stdout\z/.match(stdout_name)
      require!(match, 'W195 invocation stdout filename does not carry a safe label')
      match[1]
    end
    require!(labels == expected_labels && labels.uniq == labels, 'W195 process label roster/order differs')
    native_initial_sql, native_attached_sql = expected_native_probe
    binary = W185::BINARY
    store = File.join(root, 'stores', 'native')
    local_argv = [binary, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
                  "--max_memory_usage=#{W185::MEMORY}", '--multiquery']
    helper_record = records.fetch(1)
    helper_argv = helper_record.fetch('argv')
    require!(helper_argv.is_a?(Array) && helper_argv.size == 3 && helper_argv[0].is_a?(String) &&
             helper_argv[0].start_with?('/') && helper_argv[0] == File.expand_path(helper_argv[0]) &&
             helper_argv[1] == File.join(root, 'generated', 'input', 'helper-input.json') &&
             helper_argv[2] == File.join(root, 'generated'), 'W195 helper argv paths differ')
    initial = validate_invocation_record!(root, records.fetch(0), expected_labels.fetch(0),
      'clickhouse local', local_argv, native_initial_sql)
    helper = validate_invocation_record!(root, helper_record, expected_labels.fetch(1),
      'prebuilt Crystal helper', helper_argv, ''.b)
    attached = validate_invocation_record!(root, records.fetch(2), expected_labels.fetch(2),
      'clickhouse local', local_argv, native_attached_sql)
    expected_files = records.each_with_index.flat_map do |record, index|
      label = expected_labels.fetch(index)
      files = ["#{label}.argv.json", "#{label}.stdout", "#{label}.stderr", "#{label}.json"]
      files << record.fetch('stdin_file') if record.key?('stdin_file')
      files
    end.sort
    actual_files = Dir.children(File.join(root, 'invocations')).sort
    require!(actual_files == expected_files, 'W195 invocation artifact roster has missing, duplicate, or orphan files')
    [initial, helper, attached]
  rescue KeyError => error
    raise ReconcileError, "W195 invocation roster lacks #{error.key.inspect}"
  end

  def validate_native_tag_cardinality!(stdout, phase)
    lines = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
    expected = if phase == :initial
                 {
                   '__W195_PIN__' => 1,
                   '__W195_SCHEMA__' => PROFILE_IDS.size * 4,
                   '__W195_DATA_PATH__' => PROFILE_IDS.size * 2,
                   '__W195_PART__' => 0,
                 }
               else
                 {
                   '__W195_PIN__' => 1,
                   '__W195_CHECK_BEGIN__' => PROFILE_IDS.size * 2,
                   '__W195_CHECK_END__' => PROFILE_IDS.size * 2,
                   '__W195_SCHEMA__' => PROFILE_IDS.size * 4,
                   '__W195_ROW__' => PROFILE_IDS.size * 2 * 8,
                   '__W195_MIDDLE_ROW__' => PROFILE_IDS.size * 2 * 4,
                   '__W195_ZERO_BEGIN__' => PROFILE_IDS.size * 2,
                   '__W195_ZERO_ROW__' => 0,
                   '__W195_ZERO_END__' => PROFILE_IDS.size * 2,
                   '__W195_PATH_ROW__' => PROFILE_IDS.count { |id| R191::PROFILE_EXPECTATIONS.fetch(id).fetch(:buckets) == 2 } * 2 * 3 * 8,
                   '__W195_PART__' => PROFILE_IDS.size * 2,
                 }
               end
    actual = lines.each_with_object(Hash.new(0)) do |line, counts|
      tag = line.split("\t", 2).first
      counts[tag] += 1 if tag.start_with?('__W195_')
    end
    observed_tags = expected.select { |_tag, count| count > 0 }.keys.sort
    require!(actual.keys.sort == observed_tags && expected.all? { |tag, count| actual.fetch(tag, 0) == count },
      "W195 #{phase} stdout marker/cardinality roster differs")
    true
  end

  def validate_part!(root, capture_root, profile_id, inventory, source_profile, kind)
    require!(inventory.is_a?(Hash), "#{profile_id}: part inventory is not an object")
    expected_path = if kind == :stock
                      canonical_source_part_path(source_profile)
                    else
                      File.join(root, 'generated', profile_id, 'all_1_1_0')
                    end
    path = inventory.fetch('part_path')
    require!(path == expected_path, "#{profile_id} #{kind}: part path differs from its admitted destination")
    full = ensure_no_symlink_ancestors!(path, kind == :stock ? capture_root : root)
    require!(File.realpath(full) == full && File.directory?(full), "#{profile_id} #{kind}: invalid part directory")
    names = inventory.fetch('physical_file_names')
    require!(names.is_a?(Array) && names.uniq == names && names == names.sort,
      "#{profile_id} #{kind}: physical roster is malformed")
    actual_names = Dir.children(full).sort
    require!(actual_names == names, "#{profile_id} #{kind}: physical file roster differs from part directory")
    names.each do |name|
      require!(File.basename(name) == name && !File.symlink?(File.join(full, name)),
        "#{profile_id} #{kind}: unsafe part entry #{name}")
      stat = File.lstat(File.join(full, name))
      require!(stat.file?, "#{profile_id} #{kind}: non-regular part entry #{name}")
      require!(stat.size <= MAX_PART_FILE_BYTES, "#{profile_id} #{kind}: part entry exceeds size bound")
    end
    total_bytes = names.sum { |name| File.size(File.join(full, name)) }
    require!(total_bytes <= MAX_PART_TOTAL_BYTES, "#{profile_id} #{kind}: aggregate part exceeds size bound")

    logical = inventory.fetch('logical_substreams')
    require!(logical.is_a?(Array) && logical.uniq == logical, "#{profile_id} #{kind}: logical stream roster is malformed")
    columns_substreams = read_plain_file(File.join(full, 'columns_substreams.txt'), MAX_PART_FILE_BYTES,
      "#{profile_id} #{kind} columns_substreams.txt")
    observed_logical = columns_substreams.force_encoding(Encoding::UTF_8).lines.map do |line|
      line.start_with?("\t") ? line.strip.sub(/\A\*\s*/, '') : nil
    end.compact
    require!(observed_logical == logical && columns_substreams == inventory.fetch('columns_substreams_text').b,
      "#{profile_id} #{kind}: columns_substreams.txt differs from inventory")
    stream_files = logical.flat_map do |stream|
      stem = JsonArrayStorageW183.stream_hash(stream)
      ["#{stem}.bin", "#{stem}.mrk2"]
    end.sort
    require!(stream_files.uniq == stream_files, "#{profile_id} #{kind}: hashed stream filename collision")
    require!(physical_roster_matches?(names, stream_files, kind),
      "#{profile_id} #{kind}: physical roster differs from logical streams and metadata")
    require!(inventory.fetch('hashed_stream_files') == stream_files && inventory.fetch('plain_mrk2_only') == true,
      "#{profile_id} #{kind}: stream/mark format claim differs")

    stream_inventory = inventory.fetch('stream_file_inventory')
    require!(stream_inventory.is_a?(Hash) && stream_inventory.keys.sort == stream_files,
      "#{profile_id} #{kind}: stream inventory roster differs")
    mark_triples = {}
    stream_files.each do |filename|
      bytes = read_plain_file(File.join(full, filename), MAX_PART_FILE_BYTES, "#{profile_id} #{kind} #{filename}")
      item = stream_inventory.fetch(filename)
      require!(item.fetch('size') == bytes.bytesize && item.fetch('sha256') == sha256(bytes),
        "#{profile_id} #{kind} #{filename}: size/hash differs from recorded inventory")
      next unless filename.end_with?('.mrk2')
      require!((bytes.bytesize % 24).zero?, "#{profile_id} #{kind} #{filename}: malformed mark triples")
      triples = bytes.unpack('Q<*').each_slice(3).map(&:dup)
      require!(mark_grid_matches?(triples),
        "#{profile_id} #{kind} #{filename}: physical mark rows differ")
      logical_name = logical.find { |stream| JsonArrayStorageW183.stream_hash(stream) == filename.sub(/\.mrk2\z/, '') }
      require!(logical_name, "#{profile_id} #{kind} #{filename}: mark file lacks logical owner")
      bin_name = "#{filename.sub(/\.mrk2\z/, '')}.bin"
      compressed = read_plain_file(File.join(full, bin_name), MAX_PART_FILE_BYTES, "#{profile_id} #{kind} #{bin_name}")
      frames = R191.walk_compressed_frames(compressed, "#{profile_id} #{kind} #{logical_name}")
      decoded_offsets = triples.map do |compressed_offset, in_block_offset, _rows|
        R191.coordinate_to_decoded([compressed_offset, in_block_offset], frames.fetch(:spans),
          compressed.bytesize, frames.fetch(:decoded_bytes), "#{profile_id} #{kind} #{logical_name} mark")
      end
      require!(decoded_offsets.each_cons(2).all? { |left, right| right >= left },
        "#{profile_id} #{kind} #{logical_name}: normalized mark coordinates move backward")
      object_name = R191::PROFILE_EXPECTATIONS.fetch(profile_id).fetch(:kind) == 'array' ?
        'a.object_structure' : 'j.object_structure'
      object_statistics_offset = if logical_name == object_name
                                   object_statistics_offset_for_profile(source_profile, profile_id)
                                 end
      valid_boundaries = mark_offsets_valid_for_role?(logical_name, decoded_offsets,
        frames.fetch(:decoded_bytes), object_statistics_offset)
      boundary_error = logical_name == object_name ?
        'Object metadata real marks differ from statistics boundary' :
        'first/terminal mark coordinates do not span decoded data'
      require!(valid_boundaries, "#{profile_id} #{kind} #{logical_name}: #{boundary_error}")
      mark_triples[logical_name] = triples
    end
    require!(mark_triples == inventory.fetch('mark_triples'),
      "#{profile_id} #{kind}: raw .mrk2 triples differ from saved inventory")

    verify_metadata!(full, inventory, source_profile, profile_id, kind)
    require!(inventory.fetch('rows').to_s == '8' && inventory.fetch('marks').to_s == '5' &&
             inventory.fetch('count_text') == '8' && inventory.fetch('part_type') == 'Wide',
      "#{profile_id} #{kind}: part dimensions/type differ")
    true
  rescue KeyError => error
    raise ReconcileError, "#{profile_id} #{kind} inventory lacks #{error.key.inspect}"
  end

  def canonical_source_part_path(source_profile)
    part = source_profile.fetch('part')
    raw_path = part.fetch('part_path')
    require!(part.fetch('part_name') == 'all_1_1_0', 'W191 source part name differs')
    require!(raw_path.is_a?(String) && raw_path.start_with?(File::SEPARATOR),
      'W191 source part path must be absolute')
    normalized = File.expand_path(raw_path)
    require!(raw_path == normalized + File::SEPARATOR,
      'W191 source part path must be canonical with exactly one trailing separator')
    normalized
  rescue KeyError => error
    raise ReconcileError, "W191 source part metadata is missing #{error.key.inspect}"
  end

  def verify_metadata!(part_path, inventory, source_profile, profile_id, kind)
    checksums = read_plain_file(File.join(part_path, 'checksums.txt'), MAX_PART_FILE_BYTES,
      "#{profile_id} #{kind} checksums.txt")
    require!(checksums.bytesize == inventory.fetch('checksums_bytes') &&
             sha256(checksums) == inventory.fetch('checksums_sha256'),
      "#{profile_id} #{kind}: checksums.txt size/hash differs")
    serialization = read_plain_file(File.join(part_path, 'serialization.json'), MAX_PART_FILE_BYTES,
      "#{profile_id} #{kind} serialization.json")
    require!(sha256(serialization) == inventory.fetch('serialization_json_sha256'),
      "#{profile_id} #{kind}: serialization.json digest differs")
    parsed = JSON.parse(serialization)
    require!(parsed.fetch('version') == 1 && parsed.fetch('propagate_types_serialization_versions_to_nested_types') == true &&
             parsed.dig('types_serialization_versions', 'string') == inventory.fetch('ordinary_string_serialization_version'),
      "#{profile_id} #{kind}: serialization settings differ")
    columns = read_plain_file(File.join(part_path, 'columns.txt'), MAX_PART_FILE_BYTES,
      "#{profile_id} #{kind} columns.txt")
    require!(columns == inventory.fetch('columns_text').b, "#{profile_id} #{kind}: columns.txt differs")
    require!(columns == source_profile.fetch('part').fetch('columns_text').b,
      "#{profile_id} #{kind}: columns.txt differs from authenticated source schema")
    require!(read_plain_file(File.join(part_path, 'count.txt'), 1024, "#{profile_id} #{kind} count.txt").strip == '8',
      "#{profile_id} #{kind}: count.txt differs")
    require!(read_plain_file(File.join(part_path, 'default_compression_codec.txt'), 1024,
      "#{profile_id} #{kind} default codec").strip == 'CODEC(LZ4)', "#{profile_id} #{kind}: default codec differs")
    require!(read_plain_file(File.join(part_path, 'metadata_version.txt'), 1024,
      "#{profile_id} #{kind} metadata version").strip == '0' && inventory.fetch('metadata_version') == '0',
      "#{profile_id} #{kind}: metadata version differs")
    require!(inventory.fetch('default_compression_codec') == 'CODEC(LZ4)' &&
             inventory.fetch('checksums_sha256').is_a?(String), "#{profile_id} #{kind}: metadata claims malformed")
  rescue KeyError => error
    raise ReconcileError, "#{profile_id} #{kind} metadata lacks #{error.key.inspect}"
  rescue JSON::ParserError => error
    raise ReconcileError, "#{profile_id} #{kind} serialization metadata is invalid: #{error.message}"
  end

  def validate_helper!(root, summary, source_profiles, source_parts, library_parts, helper_record, stdout)
    helper_summary = summary.fetch('helper')
    require!(helper_summary.is_a?(Hash) && helper_summary.keys.sort == %w[data input_sha256 invocation].sort &&
             helper_summary.fetch('data').is_a?(Hash) &&
             helper_summary.fetch('invocation') == helper_record,
      'W195 helper summary does not bind its invocation/output')
    input_path = File.join(root, 'generated', 'input', 'helper-input.json')
    input_bytes = read_plain_file(input_path, MAX_SUMMARY_BYTES, 'W195 helper input')
    writer = W195::Probe.allocate
    writer.instance_variable_set(:@root, root)
    writer.instance_variable_set(:@capture_root, summary.fetch('capture_root'))
    expected_input = writer.send(:helper_input, source_profiles, source_parts, library_parts)
    expected_bytes = JSON.pretty_generate(expected_input) + "\n"
    require!(input_bytes == expected_bytes && sha256(input_bytes) == helper_summary.fetch('input_sha256'),
      'W195 helper input differs from authenticated source/literal destinations')
    output_lines = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp).reject(&:empty?)
    require!(output_lines.size == 1, 'W195 helper stdout must contain one JSON record')
    output_data = JSON.parse(output_lines.first)
    require!(output_data == helper_summary.fetch('data'), 'W195 helper output summary differs from captured stdout')
    helper = {data: output_data, invocation: helper_record, input_sha256: sha256(input_bytes)}
    verifier = W195::Probe.allocate
    verifier.send(:assert_helper!, helper, source_profiles, library_parts)
    validate_generated_tree!(root, summary.fetch('library_inventories'))
  rescue KeyError => error
    raise ReconcileError, "W195 helper evidence lacks #{error.key.inspect}"
  rescue W195::ProbeError => error
    raise ReconcileError, "W195 helper output failed W195 literal checks: #{error.message}"
  rescue JSON::ParserError => error
    raise ReconcileError, "W195 helper stdout JSON is invalid: #{error.message}"
  end

  def validate_generated_tree!(root, library_inventories)
    generated = File.join(root, 'generated')
    input_dir = File.join(generated, 'input')
    require!(File.directory?(input_dir) && !File.symlink?(input_dir), 'W195 generated input directory is absent or symlinked')
    expected_files = ['input/helper-input.json']
    expected_dirs = ['input']
    PROFILE_IDS.each do |id|
      inventory = library_inventories.fetch(id)
      part_rel = "#{id}/all_1_1_0"
      expected_dirs << id << part_rel
      expected_files.concat(inventory.fetch('physical_file_names').map { |name| "#{part_rel}/#{name}" })
    end
    entries = Dir.glob(File.join(generated, '**', '*'), File::FNM_DOTMATCH).reject do |entry|
      %w[. ..].include?(File.basename(entry))
    end
    require!(entries.none? { |entry| File.symlink?(entry) }, 'W195 generated tree contains a symlink')
    actual_files = entries.select { |entry| File.file?(entry) }
      .map { |entry| entry.sub(generated + File::SEPARATOR, '') }.sort
    actual_dirs = entries.select { |entry| File.directory?(entry) }
      .map { |entry| entry.sub(generated + File::SEPARATOR, '') }.sort
    require!(actual_files == expected_files.sort && actual_dirs == expected_dirs.uniq.sort,
      'W195 generated file/directory tree differs from exact helper input and part inventories')
    true
  rescue KeyError => error
    raise ReconcileError, "W195 generated tree inventory lacks #{error.key.inspect}"
  end

  def reconcile(evidence_root, capture_arg = nil)
    root = canonical_directory(evidence_root, 'W195 evidence root')
    summary = read_json(File.join(root, 'summary.json'), MAX_SUMMARY_BYTES, 'W195 summary')
    capture_root = canonical_directory(capture_arg || summary.fetch('capture_root'), 'W191 capture root')
    validate_summary_header!(root, summary, capture_root)
    manifest, source_profiles = validate_capture!(summary, capture_root)
    source_parts = source_profiles.transform_values { |profile| canonical_source_part_path(profile) }
    library_parts = PROFILE_IDS.to_h { |id| [id, File.join(root, 'generated', id, 'all_1_1_0')] }
    source_inventories = summary.fetch('source_inventories')
    library_inventories = summary.fetch('library_inventories')
    require!(source_inventories.keys.sort == PROFILE_IDS.sort && library_inventories.keys.sort == PROFILE_IDS.sort,
      'W195 source/library part inventory profile roster differs')
    PROFILE_IDS.each do |id|
      validate_part!(root, capture_root, id, source_inventories.fetch(id), source_profiles.fetch(id), :stock)
      validate_part!(root, capture_root, id, library_inventories.fetch(id), source_profiles.fetch(id), :library)
      require!(source_inventories.fetch(id).fetch('part_path') == source_parts.fetch(id),
        "#{id}: source inventory path differs from authenticated W191 part")
      require!(source_inventories.fetch(id).fetch('logical_substreams').sort ==
               library_inventories.fetch(id).fetch('logical_substreams').sort &&
               source_inventories.fetch(id).fetch('hashed_stream_files').sort ==
               library_inventories.fetch(id).fetch('hashed_stream_files').sort,
        "#{id}: source/library stream roster differs")
      verifier = W195::Probe.allocate
      verifier.send(:assert_same_roster!, id,
        symbolize_inventory(source_inventories.fetch(id)), symbolize_inventory(library_inventories.fetch(id)),
        manifest, source_profiles)
    end

    initial, helper, attached = validate_invocations!(root, summary)
    helper_record = helper.fetch(:record)
    helper_input = File.join(root, 'generated', 'input', 'helper-input.json')
    expected_helper_argv = [helper_record.fetch('argv').fetch(0), helper_input, File.join(root, 'generated')]
    require!(helper_record.fetch('argv') == expected_helper_argv && File.absolute_path(expected_helper_argv.fetch(0)) == expected_helper_argv.fetch(0),
      'W195 helper invocation paths differ')
    validate_helper!(root, summary, source_profiles, source_parts, library_parts, helper_record, helper.fetch(:stdout))

    verifier = W195::Probe.allocate
    verifier.instance_variable_set(:@root, root)
    validate_native_tag_cardinality!(initial.fetch(:stdout), :initial)
    validate_native_tag_cardinality!(attached.fetch(:stdout), :attached)
    native_initial = verifier.send(:parse_w195_native, initial.fetch(:stdout))
    native_attached = verifier.send(:parse_w195_native, attached.fetch(:stdout))
    verifier.send(:assert_initial_native!, native_initial)
    verifier.send(:assert_attached_native!, native_attached)
    require!(summary.fetch('initial') == stringify_json(native_initial) &&
             summary.fetch('attached') == stringify_json(native_attached),
      'W195 parsed native outputs differ from captured process stdout')
    require!(native_initial.fetch(:parts).empty?, 'initial ClickHouse store was not empty')
    check_recorded_binary!(summary)

    {
      'format' => FORMAT,
      'status' => 'offline_artifacts_reconciled',
      'evidence_root' => root,
      'capture_root' => capture_root,
      'source_revision' => R191::SOURCE_REVISION,
      'runtime' => {'version' => W185::VERSION, 'build' => W185::BUILD, 'sha256' => W185::BINARY_SHA256},
      'counts' => {'profiles' => PROFILE_IDS.size, 'part_directories' => PROFILE_IDS.size * 2,
                 'process_records' => summary.fetch('invocations').size,
                   'part_stream_files_rehashed' => PROFILE_IDS.sum { |id| source_inventories.fetch(id).fetch('stream_file_inventory').size + library_inventories.fetch(id).fetch('stream_file_inventory').size }},
      'manifest_sha256' => summary.fetch('manifest_sha256'),
      'limitations' => [
        'The verifier detects drift against retained capture artifacts; it is not tamper-proof against coordinated rewriting of summary and all referenced artifacts.',
        'The W195 helper executable hash was not recorded by the run, so helper binary/source identity cannot be independently authenticated offline; its captured argv, input, stdout, and generated part bytes are bound and checked.',
        'checksums.txt is byte-hash/size checked and the retained native CHECK TABLE result is replay-validated; the checksums serialization itself is opaque here.',
        'No native command is rerun; this is artifact reconciliation, not a fresh format qualification.'
      ],
    }
  rescue KeyError => error
    raise ReconcileError, "W195 evidence lacks #{error.key.inspect}"
  end

  def symbolize_inventory(hash)
    hash.to_h { |key, value| [key.to_sym, value] }
  end

  def check_recorded_binary!(summary)
    path = summary.fetch('runtime').fetch('path')
    require!(path == W185::BINARY && File.file?(path) && !File.symlink?(path),
      'pinned ClickHouse executable is unavailable or path differs')
    require!(Digest::SHA256.file(path).hexdigest == W185::BINARY_SHA256,
      'current ClickHouse executable differs from recorded W195 runtime pin')
  end

  def self_test!
    raise ReconcileError, 'W191/W195 profile order differs' unless PROFILE_IDS == R191::PROFILE_ORDER
    raise ReconcileError, 'W195 literal row counts differ' unless PROFILE_IDS.all? { |id| W195.exact_profile_rows(id).size == 8 }
    stock_metadata_contract = %w[
      checksums.txt
      columns.txt
      columns_substreams.txt
      count.txt
      default_compression_codec.txt
      metadata_version.txt
      primary.idx
      serialization.json
      statistics.packed
    ].sort
    library_metadata_contract = %w[
      checksums.txt
      columns.txt
      columns_substreams.txt
      count.txt
      default_compression_codec.txt
      metadata_version.txt
      primary.idx
      serialization.json
    ].sort
    raise ReconcileError, 'stock metadata constant differs from the exact nine-file contract' unless
      STOCK_METADATA_FILES.sort == stock_metadata_contract &&
      R191::METADATA_FILE_NAMES.sort == stock_metadata_contract
    raise ReconcileError, 'library metadata constant differs from the exact eight-file contract' unless
      LIBRARY_METADATA_FILES.sort == library_metadata_contract
    raise ReconcileError, 'stock metadata roster control failed' unless
      physical_roster_matches?(stock_metadata_contract, [], :stock)
    raise ReconcileError, 'library metadata roster control failed' unless
      physical_roster_matches?(library_metadata_contract, [], :library)
    raise ReconcileError, 'stock roster was accepted for the library role' if
      physical_roster_matches?(stock_metadata_contract, [], :library)
    raise ReconcileError, 'library roster was accepted for the stock role' if
      physical_roster_matches?(library_metadata_contract, [], :stock)
    missing_library_file = library_metadata_contract - ['columns.txt']
    raise ReconcileError, 'library roster with a missing metadata file was accepted' if
      physical_roster_matches?(missing_library_file, [], :library)
    extra_library_statistics = (library_metadata_contract + ['statistics.packed']).sort
    raise ReconcileError, 'library roster with stock statistics.packed was accepted' if
      physical_roster_matches?(extra_library_statistics, [], :library)
    unknown_kind_rejected = false
    begin
      expected_metadata_files(:unknown)
    rescue ReconcileError => error
      unknown_kind_rejected = error.message.include?('unknown W195 part kind')
    end
    raise ReconcileError, 'unknown part kind was not rejected' unless unknown_kind_rejected

    local_artifact_record = {
      'process_kind' => 'clickhouse local',
      'expected_binary_sha256' => W185::BINARY_SHA256,
      'binary_sha_after' => W185::BINARY_SHA256,
      'argv' => ['/pinned/clickhouse', 'local'],
    }
    local_summary_record = local_artifact_record.merge('binary_sha_before' => W185::BINARY_SHA256)
    raise ReconcileError, 'producer local two-layer snapshot was rejected' unless
      invocation_artifact_matches_summary?(local_artifact_record, local_summary_record, 'clickhouse local')
    raise ReconcileError, 'local snapshot without binary_sha_before was accepted' if
      invocation_artifact_matches_summary?(local_artifact_record,
        local_summary_record.reject { |field, _value| field == 'binary_sha_before' }, 'clickhouse local')
    raise ReconcileError, 'local snapshot with a wrong pre-invocation pin was accepted' if
      invocation_artifact_matches_summary?(local_artifact_record,
        local_summary_record.merge('binary_sha_before' => '0' * 64), 'clickhouse local')
    raise ReconcileError, 'local snapshot with a wrong expected binary pin was accepted' if
      invocation_artifact_matches_summary?(local_artifact_record,
        local_summary_record.merge('expected_binary_sha256' => '0' * 64), 'clickhouse local')
    raise ReconcileError, 'local snapshot with a wrong post-invocation pin was accepted' if
      invocation_artifact_matches_summary?(local_artifact_record,
        local_summary_record.merge('binary_sha_after' => '0' * 64), 'clickhouse local')
    raise ReconcileError, 'local snapshot with an artifact-only field was accepted' if
      invocation_artifact_matches_summary?(local_artifact_record.merge('unexpected' => true),
        local_summary_record, 'clickhouse local')
    raise ReconcileError, 'local snapshot missing a common field was accepted' if
      invocation_artifact_matches_summary?(local_artifact_record.reject { |field, _value| field == 'argv' },
        local_summary_record, 'clickhouse local')
    raise ReconcileError, 'local snapshot with a changed common field was accepted' if
      invocation_artifact_matches_summary?(local_artifact_record.merge('argv' => ['/other/clickhouse']),
        local_summary_record, 'clickhouse local')
    raise ReconcileError, 'local snapshot with an extra summary field was accepted' if
      invocation_artifact_matches_summary?(local_artifact_record,
        local_summary_record.merge('unexpected' => true), 'clickhouse local')

    helper_artifact_record = {'process_kind' => 'prebuilt Crystal helper', 'argv' => ['/probe/helper']}
    raise ReconcileError, 'exact helper invocation snapshot was rejected' unless
      invocation_artifact_matches_summary?(helper_artifact_record, helper_artifact_record, 'prebuilt Crystal helper')
    raise ReconcileError, 'helper invocation snapshot was not exact' if
      invocation_artifact_matches_summary?(helper_artifact_record,
        helper_artifact_record.merge('extra' => true), 'prebuilt Crystal helper')

    root_expected = W195.expected_path_rows('root_advanced_v2', 'root', 'alpha')
    array_expected = W195.expected_path_rows('array_advanced_v2', 'array', 'alpha')
    raise ReconcileError, 'root direct-path oracle lost missing parent rows' unless
      root_expected == ['r-alpha-1', nil, nil, 'r-alpha-4', nil, 'r-alpha-6', nil, 'r-alpha-8']
    raise ReconcileError, 'Array direct-path oracle lost empty/missing placements' unless
      array_expected == [[], [], [], ['a-alpha-41'], [nil, nil], ['a-alpha-61'], [], []]
    path_fixture = {'part' => {'part_name' => 'all_1_1_0',
      'part_path' => '/private/tmp/capture/all_1_1_0/'}}
    raise ReconcileError, 'W191 trailing-separator path normalization differs' unless
      canonical_source_part_path(path_fixture) == '/private/tmp/capture/all_1_1_0'
    begin
      canonical_source_part_path('part' => {'part_name' => 'all_1_1_0',
        'part_path' => '/private/tmp/capture/../capture/all_1_1_0/'})
      raise ReconcileError, 'noncanonical W191 source part path was accepted'
    rescue ReconcileError => error
      raise unless error.message.include?('canonical with exactly one trailing separator')
    end
    stock = [[0, 0, 2], [0, 8, 2], [0, 16, 2], [0, 24, 2], [0, 32, 0]]
    library = [[0, 0, 2], [0, 12, 2], [0, 24, 2], [0, 36, 2], [0, 48, 0]]
    raise ReconcileError, 'coordinate-independent mark control failed' unless
      mark_grid_matches?(stock) && mark_grid_matches?(library)
    changed_grid = library.map(&:dup)
    changed_grid[1][2] = 3
    raise ReconcileError, 'mark-grid mutation was not rejected by the predicate' if mark_grid_matches?(changed_grid)

    body_name = 'j.object_shared_data.0.structure'
    object_names = ['j.object_structure', 'a.object_structure']
    raise ReconcileError, 'valid shared body boundaries were rejected' unless
      mark_offsets_valid_for_role?(body_name, [0, 11, 30], 30)
    object_names.each do |object_name|
      raise ReconcileError, "#{object_name}: valid Object statistics boundaries were rejected" unless
        mark_offsets_valid_for_role?(object_name, [11, 11, 11, 11, 30], 30, 11)
    end
    PROFILE_IDS.select { |id| id.start_with?('empty_') }.each do |id|
      object_name = R191::PROFILE_EXPECTATIONS.fetch(id).fetch(:kind) == 'array' ?
        'a.object_structure' : 'j.object_structure'
      raise ReconcileError, "#{id}: empty Object metadata boundary/EOF pair was rejected" unless
        mark_offsets_valid_for_role?(object_name, [11, 11, 11, 11, 13], 13, 11)
      raise ReconcileError, "#{id}: statistics boundary equal to EOF was accepted" if
        mark_offsets_valid_for_role?(object_name, [13, 13, 13, 13, 13], 13, 13)
    end

    source_header_fixture = lambda do |id, overrides = {}|
      expectation = R191::PROFILE_EXPECTATIONS.fetch(id)
      shared_version = overrides.fetch(:shared_version,
        expectation.fetch(:mode) == 'advanced' ? 2 : 3)
      bucket_count = overrides.fetch(:wire_bucket_count, expectation.fetch(:buckets))
      raw = [overrides.fetch(:version, 4)].pack('Q<') +
        [overrides.fetch(:dynamic_path_count, 0), shared_version, bucket_count,
         overrides.fetch(:statistics_flag, 1), 0].pack('C*')
      {
        'id' => id,
        'kind' => overrides.fetch(:kind, expectation.fetch(:kind)),
        'requested_shared_version' => overrides.fetch(:mode, expectation.fetch(:mode)),
        'expected_actual_bucket_count' => overrides.fetch(:declared_bucket_count, expectation.fetch(:buckets)),
        'physical_layout' => {'object_structure_bytes_hex' => raw.unpack1('H*')},
      }
    end
    PROFILE_IDS.each do |id|
      header = source_header_fixture.call(id)
      raise ReconcileError, "#{id}: source-authenticated statistics boundary is not offset 11" unless
        object_statistics_offset_for_profile(header, id) == 11
    end
    reject_header = lambda do |id, overrides, label|
      begin
        object_statistics_offset_for_profile(source_header_fixture.call(id, overrides), id)
      rescue ReconcileError, R191::ReconcileError
        next
      end
      raise ReconcileError, "#{id}: malformed #{label} source header was accepted"
    end
    reject_header.call('root_advanced_v2', {version: 3}, 'version')
    reject_header.call('root_advanced_v2', {dynamic_path_count: 1}, 'dynamic-path roster')
    reject_header.call('root_advanced_v2', {shared_version: 3}, 'shared version')
    reject_header.call('root_advanced_v2', {wire_bucket_count: 1}, 'bucket count')
    reject_header.call('root_advanced_v2', {statistics_flag: 0}, 'statistics flag')
    reject_header.call('root_advanced_v2', {declared_bucket_count: 1}, 'declared bucket count')
    reject_header.call('root_advanced_v2', {mode: 'advanced_chunked'}, 'requested shared mode')
    reject_header.call('root_advanced_v2', {kind: 'array'}, 'profile kind')

    raise ReconcileError, 'changed Object real mark was accepted' if
      mark_offsets_valid_for_role?('j.object_structure', [11, 11, 12, 12, 30], 30, 11)
    raise ReconcileError, 'zero Object prefix mark was accepted' if
      mark_offsets_valid_for_role?('j.object_structure', [0, 11, 11, 11, 30], 30, 11)
    raise ReconcileError, 'short Object terminal mark was accepted' if
      mark_offsets_valid_for_role?('j.object_structure', [11, 11, 11, 11, 29], 30, 11)
    raise ReconcileError, 'nonzero shared body start was accepted' if
      mark_offsets_valid_for_role?(body_name, [1, 11, 30], 30)
    raise ReconcileError, 'backward shared body marks were accepted' if
      mark_offsets_valid_for_role?(body_name, [0, 20, 10, 30], 30)

    changed_path_rows = array_expected.map { |row| row.is_a?(Array) ? row.dup : row }
    changed_path_rows[3] = []
    raise ReconcileError, 'per-parent path-placement mutation was not distinguished' if changed_path_rows == array_expected
    initial_sql, = expected_native_probe
    raise ReconcileError, 'offline native oracle omits initial schema/parts SQL' unless
      initial_sql.include?("SELECT '__W195_SCHEMA__'") && initial_sql.include?("SELECT '__W195_PART__'")
    initial_markers = ["__W195_PIN__\t#{W185::VERSION}\t#{W185::BUILD}"]
    initial_markers.concat(Array.new(PROFILE_IDS.size * 4, "__W195_SCHEMA__\tdefault\tt\tUInt64"))
    initial_markers.concat(Array.new(PROFILE_IDS.size * 2, "__W195_DATA_PATH__\tt\t/private/tmp/store"))
    validate_native_tag_cardinality!(initial_markers.join("\n") + "\n", :initial)
    begin
      validate_native_tag_cardinality!(initial_markers.concat(["__W195_PART__\tt\tall_1_1_0"] ).join("\n") + "\n", :initial)
      raise ReconcileError, 'unexpected initial part marker was accepted'
    rescue ReconcileError => error
      raise unless error.message.include?('cardinality roster')
    end
    puts 'W195 offline self-test: fixture literals, per-parent path placement, and independent mark-grid controls passed'
  end

  def main(argv)
    options = {}
    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby scripts/reconcile_object_shared_advanced_parts_w195.rb --evidence-root W195_ROOT [--capture-root W191_ROOT] | --self-test'
      parser.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
      parser.on('--capture-root PATH') { |value| options[:capture_root] = value }
      parser.on('--self-test') { options[:self_test] = true }
    end.parse!(argv)
    if options[:self_test]
      self_test!
      return 0
    end
    require!(options[:evidence_root], 'W195 evidence root required')
    puts JSON.pretty_generate(reconcile(options[:evidence_root], options[:capture_root]))
    0
  rescue StandardError => error
    warn "W195 offline reconciliation failed: #{error.class}: #{error.message}"
    1
  end
end

exit ReconcileObjectSharedAdvancedPartsW195.main(ARGV) if $PROGRAM_NAME == __FILE__
