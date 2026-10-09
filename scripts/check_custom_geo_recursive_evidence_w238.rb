#!/usr/bin/env ruby
# Independent raw-sidecar auditor for W238 stock and paired Custom Geo evidence.
# It reconstructs the finite expected SQL and binary literals; summaries are
# cross-checked, never accepted as substitutes for argv/status/files on disk.

require 'digest'
require 'find'
require 'json'
require 'optparse'
require_relative 'recheck_aggregate_recursive_w224'
require_relative 'custom_geo_w238_fixtures'
require_relative 'probe_custom_geo_w238'
require_relative 'recheck_custom_geo_recursive_w238'

module CheckCustomGeoRecursiveEvidenceW238
  extend self

  R = RecheckAggregateRecursiveW224
  F = CustomGeoW238Fixtures
  P = ProbeCustomGeoW238
  W = RecheckCustomGeoRecursiveW238
  STOCK_PREFIX = P::OUTPUT_PREFIX
  EVIDENCE_PREFIX = W::EVIDENCE_PREFIX
  GENERATED_PREFIX = W::GENERATED_PREFIX
  MAX_JSON_BYTES = 64 * 1024 * 1024

  def fail!(message)
    raise ArgumentError, "W238 evidence audit failed: #{message}"
  end

  def require_true(condition, message)
    fail!(message) unless condition
  end

  def canonical_root(path, prefix, label)
    full = File.expand_path(path)
    require_true(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "#{label} must be a canonical directory")
    require_true(File.dirname(full) == File.realpath('/private/tmp') && full.start_with?(prefix),
      "#{label} must be a direct /private/tmp child with the fixed prefix")
    full
  end

  def read_regular(path, max_bytes: nil)
    full = File.expand_path(path)
    require_true(File.file?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "evidence path is absent, non-regular, symlinked, or noncanonical: #{full}")
    require_true(File.size(full) <= max_bytes, "evidence file exceeds its bound: #{full}") if max_bytes
    File.binread(full)
  end

  def json_file(path)
    JSON.parse(read_regular(path, max_bytes: MAX_JSON_BYTES).force_encoding(Encoding::UTF_8))
  rescue JSON::ParserError => error
    fail!("malformed JSON #{path}: #{error.message}")
  end

  def inventory(part)
    root = File.expand_path(part)
    require_true(File.directory?(root) && !File.symlink?(root) && File.realpath(root) == root,
      "part is absent or noncanonical: #{root}")
    entries = []
    Find.find(root) do |path|
      next if path == root
      require_true(!File.symlink?(path), "part contains a symlink: #{path}")
      next if File.directory?(path)
      require_true(File.file?(path), "part contains a non-regular file: #{path}")
      bytes = File.binread(path)
      entries << { 'path' => path[(root.length + 1)..-1], 'bytes' => bytes.bytesize,
        'sha256' => Digest::SHA256.hexdigest(bytes) }
    end
    entries.sort_by { |entry| entry.fetch('path') }
  end

  def marker_section(stdout, before, after, label)
    lines = stdout.dup.force_encoding(Encoding::UTF_8).scrub.lines
    starts = lines.each_index.select { |i| lines[i].chomp == before }
    ends = lines.each_index.select { |i| lines[i].chomp == after }
    require_true(starts.length == 1 && ends.length == 1 && ends.first > starts.first,
      "raw stdout marker pair is missing or ambiguous: #{label}")
    lines[(starts.first + 1)...ends.first].join
  end

  def normalized_sql(sql)
    (sql.end_with?("\n") ? sql : sql + "\n").b
  end

  def expected_argv(binary, store, sql, stdin: nil, special: nil)
    base = [binary, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
      '--max_insert_threads=1', '--max_execution_time=30', "--max_memory_usage=#{R::MEMORY_LIMIT_BYTES}",
      '--print_pretty_type_names=0']
    return base + ['--input_format_binary_decode_types_in_binary_format=1', '--query', sql] if special == :binary_type_input
    base + ['--multiquery', '--query', sql]
  end

  def audit_call(root, stem, label:, sql:, binary:, store:, expected: :success, stdin: nil,
      special: nil, summary_record: nil, diagnostic: nil)
    base = File.join(root, 'invocations', stem)
    meta = json_file(base + '.argv.json')
    status = json_file(base + '.status.json')
    stdout = read_regular(base + '.stdout')
    stderr = read_regular(base + '.stderr')
    raw_sql = read_regular(base + '.sql')
    require_true(meta.fetch('label') == label && meta.fetch('environment') == { 'TZ' => 'UTC' },
      "argv metadata label/environment differs for #{label}")
    require_true(meta.fetch('timeout_seconds') == R::PROCESS_TIMEOUT_SECONDS,
      "timeout metadata differs for #{label}")
    require_true(meta.fetch('argv') == expected_argv(binary, store, sql, stdin: stdin, special: special),
      "actual recorded argv differs from reconstructed command for #{label}")
    require_true(raw_sql == normalized_sql(sql), "actual .sql sidecar differs from reconstructed SQL for #{label}")
    if stdin
      actual_stdin = read_regular(base + '.stdin.bin')
      require_true(actual_stdin == stdin && meta.fetch('stdin_bytes') == stdin.bytesize &&
        meta.fetch('stdin_sha256') == Digest::SHA256.hexdigest(stdin),
        "actual stdin bytes/hash/argv metadata differ for #{label}")
    else
      require_true(!File.exist?(base + '.stdin.bin') && meta['stdin_bytes'].nil? && meta['stdin_sha256'].nil?,
        "unexpected stdin payload or metadata for #{label}")
    end
    require_true(status.fetch('label') == label && status.fetch('stdout_bytes') == stdout.bytesize &&
      status.fetch('stderr_bytes') == stderr.bytesize && status.fetch('timed_out') == false &&
      status.fetch('signaled') == false && status['termsig'].nil? && status['spawn_error'].nil? &&
      status.fetch('duration_ms').is_a?(Integer) && status.fetch('duration_ms') >= 0,
      "raw status sidecar conflicts with captured streams or has timeout/signal/spawn failure for #{label}")
    case expected
    when :success
      require_true(status.fetch('classification') == 'process_success' && status.fetch('exitstatus') == 0,
        "expected successful exit 0 for #{label}")
    when :refusal
      require_true(status.fetch('classification') == 'process_nonzero_or_signaled_exit' &&
        status.fetch('exitstatus').is_a?(Integer) && status.fetch('exitstatus').positive?,
        "expected a normal positive refusal exit for #{label}")
      text = (stdout + stderr).force_encoding(Encoding::UTF_8).scrub
      require_true(diagnostic && text.match?(diagnostic), "raw database diagnostic does not establish refusal for #{label}")
    else
      fail!("unknown expected process class #{expected.inspect}")
    end
    require_true(summary_record == status, "summary status differs from raw status sidecar for #{label}") if summary_record
    [status, stdout, stderr]
  rescue KeyError => error
    fail!("raw process sidecar missing required field for #{label}: #{error.message}")
  end

  def expected_process_stems(root)
    Dir.glob(File.join(root, 'invocations', '*.argv.json')).map { |path| File.basename(path, '.argv.json') }.sort
  end

  def verify_raw_sidecar_roster!(root, stems, stdin_labels: [], ancillary_stems: [])
    native_stems = stems.sort
    all_stems = (native_stems + ancillary_stems).sort
    argv_stems = Dir.glob(File.join(root, 'invocations', '*.argv.json')).map do |path|
      File.basename(path, '.argv.json')
    end.sort
    require_true(argv_stems == all_stems, 'raw .argv.json sidecar roster differs')
    { 'status.json' => all_stems, 'sql' => native_stems,
      'stdout' => all_stems, 'stderr' => all_stems }.each do |suffix, expected_stems|
      actual = Dir.glob(File.join(root, 'invocations', "*.#{suffix}")).map do |path|
        File.basename(path, ".#{suffix}")
      end.sort
      require_true(actual == expected_stems, "raw .#{suffix} sidecar roster differs")
    end
    expected_stdin = stdin_labels.map do |label|
      stem = all_stems.find do |candidate|
        json_file(File.join(root, 'invocations', "#{candidate}.argv.json")).fetch('label') == label
      end
      fail!("stdin sidecar label missing: #{label}") unless stem
      stem
    end.sort
    actual_stdin = Dir.glob(File.join(root, 'invocations', '*.stdin.bin')).map do |path|
      File.basename(path, '.stdin.bin')
    end.sort
    require_true(actual_stdin == expected_stdin, 'raw stdin sidecar roster differs')
  end

  def verify_process_roster!(root, expected_labels, summary_processes, ancillary_stems: [])
    all_stems = expected_process_stems(root)
    ancillary_stems = ancillary_stems.sort
    require_true((all_stems & ancillary_stems).sort == ancillary_stems,
      'required ancillary invocation stem is missing')
    stems = all_stems - ancillary_stems
    labels = stems.map { |stem| json_file(File.join(root, 'invocations', "#{stem}.argv.json")).fetch('label') }
    require_true(labels == expected_labels, "raw invocation label/sequence roster differs: #{labels.inspect}")
    require_true(stems.length == summary_processes.length, 'raw invocation count differs from summary process count')
    summary_by_label = summary_processes.to_h { |record| [record.fetch('label'), record] }
    require_true(summary_by_label.keys.sort == expected_labels.sort, 'summary process label roster differs')
    [stems, summary_by_label]
  end

  def validate_binary_from_argv!(root, expected_sha)
    stems = expected_process_stems(root)
    first = json_file(File.join(root, 'invocations', "#{stems.first}.argv.json"))
    binary = first.fetch('argv').first
    full = File.expand_path(binary)
    require_true(File.file?(full) && File.executable?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "captured native binary is not canonical/executable: #{full}")
    require_true(Digest::SHA256.file(full).hexdigest == expected_sha, 'captured native executable SHA-256 differs from pinned runtime')
    full
  end

  def runtime_sqls
    [
      ['runtime-version-pin', 'SELECT version() FORMAT TSVRaw'],
      ['runtime-build-pin', "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw"],
    ]
  end

  def stock_schema_sql(id)
    table = "w238_stock_#{id}"
    [
      "SELECT 'W238_SCHEMA_BEGIN_#{id}' FORMAT TSVRaw",
      "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw",
      "SELECT 'W238_SCHEMA_END_#{id}' FORMAT TSVRaw",
      "SELECT 'W238_PART_BEGIN_#{id}' FORMAT TSVRaw",
      "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw",
      "SELECT 'W238_PART_END_#{id}' FORMAT TSVRaw",
      "SELECT 'W238_CHECK_BEGIN_#{id}' FORMAT TSVRaw",
      "CHECK TABLE default.#{table} FORMAT TSVRaw",
      "SELECT 'W238_CHECK_END_#{id}' FORMAT TSVRaw",
    ].join(";\n")
  end

  def stock_create_sql(profile)
    id = profile.fetch('id')
    type = profile.fetch('declared_type')
    rows = F::ROW_KEYS.zip(profile.fetch('values')).map do |key, value|
      "(#{key}, #{F.sql_expression(profile, value)})"
    end
    table = "w238_stock_#{id}"
    "CREATE TABLE default.#{table} (pk UInt64, payload #{type}) ENGINE=MergeTree ORDER BY pk SETTINGS #{P::STOCK_SETTINGS.join(', ')};\n" \
      "INSERT INTO default.#{table} (pk, payload) VALUES #{rows.join(', ')}"
  end

  def stock_rbnwt_sql(id)
    "SELECT payload FROM default.w238_stock_#{id} ORDER BY pk SETTINGS " \
      'output_format_binary_encode_types_in_binary_format=1, print_pretty_type_names=0, flatten_nested=0 FORMAT RowBinaryWithNamesAndTypes'
  end

  def stock_windows_sql(root, id)
    table = "w238_stock_#{id}"
    paths = %w[full middle zero].to_h do |window|
      [window, File.join(root, 'captures', "#{id}-#{window}.rowbinary")]
    end
    predicates = { 'full' => '', 'middle' => ' WHERE pk BETWEEN 22 AND 44', 'zero' => ' WHERE pk > 55' }
    predicates.map do |window, predicate|
      "SELECT pk, payload FROM default.#{table}#{predicate} ORDER BY pk INTO OUTFILE '#{paths.fetch(window)}' FORMAT RowBinary"
    end.join(";\n")
  end

  def validate_stock_source_pin!(root, summary)
    pin = summary.fetch('source_pin')
    source = File.expand_path(pin.fetch('checkout'))
    require_true(File.directory?(source) && !File.symlink?(source) && File.realpath(source) == source &&
      source.start_with?(P::SOURCE_PREFIX) && File.basename(source) == 'clickhouse', 'stock source checkout path is invalid')
    require_true(pin.fetch('revision') == P::SOURCE_REVISION && pin.fetch('runtime_built_from_this_source_not_asserted') == true,
      'stock source revision/provenance scope differs')
    raw_pin = json_file(File.join(root, 'pins', 'source-pin.json'))
    require_true(raw_pin == pin, 'source-pin.json differs from summary source pin')
    revision_stdout = read_regular(File.join(root, 'pins', 'source-revision.stdout'))
    revision_stderr = read_regular(File.join(root, 'pins', 'source-revision.stderr'))
    require_true(revision_stdout.strip == P::SOURCE_REVISION && revision_stderr.empty?,
      'raw source revision command output differs')
    rows = pin.fetch('file_hashes')
    require_true(rows.length == P::SOURCE_SHA256.length, 'source file pin roster length differs')
    rows.each do |row|
      relative = row.fetch('path')
      expected = P::SOURCE_SHA256.fetch(relative)
      bytes_path = File.join(source, relative)
      require_true(row.fetch('expected_sha256') == expected && File.file?(bytes_path) && !File.symlink?(bytes_path),
        "source file pin identity/path differs for #{relative}")
      actual = Digest::SHA256.file(bytes_path).hexdigest
      require_true(actual == expected && row.fetch('actual_sha256') == actual && row.fetch('matches') == true,
        "source file SHA-256 differs for #{relative}")
    end
  end

  def audit_stock!(root)
    root = canonical_root(root, STOCK_PREFIX, 'stock root')
    matrix_path = File.join(root, 'stock-matrix.json')
    matrix_bytes = read_regular(matrix_path, max_bytes: MAX_JSON_BYTES)
    matrix = JSON.parse(matrix_bytes.force_encoding(Encoding::UTF_8))
    summary = json_file(File.join(root, 'summary.json'))
    require_true(summary.fetch('format') == P::SUMMARY_FORMAT && summary.fetch('classification') == 'stock_custom_geo_profiles_observed' &&
      summary.fetch('success') == true && summary['error'].nil?, 'stock summary does not claim the complete observed profile roster')
    require_true(summary.fetch('matrix_path') == matrix_path && summary.fetch('matrix_sha256') == Digest::SHA256.hexdigest(matrix_bytes),
      'stock summary matrix path/hash differs from the actual matrix file')
    validate_stock_source_pin!(root, summary)
    require_true(matrix.fetch('source_pin') == summary.fetch('source_pin'), 'stock matrix and summary source pins differ')

    require_true(matrix.fetch('format') == P::MATRIX_FORMAT && matrix.fetch('row_keys') == F::ROW_KEYS &&
      matrix.fetch('mark_rows') == F::MARK_ROWS && matrix.fetch('profile_count') == F.profiles.length &&
      matrix.fetch('stock_settings') == P::STOCK_SETTINGS && matrix.fetch('output_settings') == [
        'output_format_binary_encode_types_in_binary_format=1', 'print_pretty_type_names=0', 'flatten_nested=0'],
      'stock matrix format/axes/settings differ from the finite fixture contract')
    require_true(summary.fetch('coverage') == matrix.fetch('coverage'), 'summary and matrix roster manifests differ')
    profile_rows = matrix.fetch('profiles')
    details = matrix.fetch('profile_evidence')
    require_true(profile_rows.length == F.profiles.length && details.length == F.profiles.length,
      'stock positive profiles are incomplete')

    expected_labels = runtime_sqls.map(&:first)
    F.profiles.each do |profile|
      id = profile.fetch('id')
      expected_labels.concat(["stock-create-insert-#{id}", "stock-schema-part-check-#{id}",
        "stock-rbnwt-#{id}", "stock-rowbinary-windows-#{id}"])
    end
    expected_labels.concat(F.source_refusal_cases.map { |row| "constructor-refusal-#{row.fetch('id')}" })
    expected_labels << 'unknown-custom-descriptor-decode'
    stems, summary_by_label = verify_process_roster!(root, expected_labels, summary.fetch('processes'))
    verify_raw_sidecar_roster!(root, stems, stdin_labels: ['unknown-custom-descriptor-decode'])
    binary, = validate_binary_from_argv!(root, R::RUNTIME_SHA256)
    runtime_pin = json_file(File.join(root, 'pins', 'runtime-pin.json'))
    require_true(runtime_pin == summary.fetch('runtime_pin') && runtime_pin == matrix.fetch('runtime_pin') &&
      File.expand_path(runtime_pin.fetch('binary')) == binary && runtime_pin.fetch('version') == R::VERSION &&
      runtime_pin.fetch('build_hash') == R::BUILD_HASH && runtime_pin.fetch('sha256') == R::RUNTIME_SHA256 &&
      runtime_pin.fetch('source_correlation') == 'not_asserted',
      'raw stock runtime pin file differs from summary/matrix or captured runtime identity')
    store = File.join(root, 'stores', 'main')
    require_true(File.directory?(store) && !File.symlink?(store) && File.realpath(store) == store,
      'stock ClickHouse store path is invalid')

    runtime_sqls.each do |label, sql|
      status, stdout, = audit_call(root, stems.find { |stem| stem.end_with?(label) }, label: label,
        sql: sql, binary: binary, store: store, summary_record: summary_by_label.fetch(label))
      expected = label == 'runtime-version-pin' ? "#{R::VERSION}\n" : "VERSION_GITHASH=#{R::BUILD_HASH}\n"
      require_true(stdout == expected, "raw runtime pin output differs for #{label}")
    end

    profile_rows.zip(details).zip(F.profiles).each do |((core, detail), profile)|
      id = profile.fetch('id')
      type = profile.fetch('declared_type')
      value_hex = F.values_hex(profile)
      descriptor_hex = F.descriptor_hex(type)
      require_true(core.fetch('id') == id && core.fetch('declared_type') == type &&
        core.fetch('observed_declared_type') == type && core.fetch('descriptor_hex') == descriptor_hex &&
        core.fetch('values_hex') == value_hex && detail.fetch('classification') == 'stock_profile_observed' &&
        detail.fetch('requested_type') == type && detail.fetch('observed_declared_type') == type &&
        detail.fetch('descriptor_hex') == descriptor_hex && detail.fetch('values_hex') == value_hex,
        "stock witness identity/type/literals differ for #{id}")
      create_label = "stock-create-insert-#{id}"
      audit_call(root, stems.find { |stem| stem.end_with?(create_label) }, label: create_label,
        sql: stock_create_sql(profile), binary: binary, store: store,
        summary_record: summary_by_label.fetch(create_label))

      schema_label = "stock-schema-part-check-#{id}"
      schema_status, schema_stdout, = audit_call(root, stems.find { |stem| stem.end_with?(schema_label) },
        label: schema_label, sql: stock_schema_sql(id), binary: binary, store: store,
        summary_record: summary_by_label.fetch(schema_label))
      require_true(schema_status.fetch('exitstatus') == 0, "stock schema/part/CHECK failed for #{id}")
      schema = marker_section(schema_stdout, "W238_SCHEMA_BEGIN_#{id}", "W238_SCHEMA_END_#{id}", "stock schema #{id}").lines.map(&:chomp)
      require_true(schema == ["pk\tUInt64", "payload\t#{type}"], "raw stock nominal schema differs for #{id}")
      part_text = marker_section(schema_stdout, "W238_PART_BEGIN_#{id}", "W238_PART_END_#{id}", "stock part #{id}")
      part_rows = part_text.lines.map(&:chomp)
      require_true(part_rows.length == 1, "raw stock part census not singular for #{id}")
      part = part_rows.first.split("\t", -1)
      require_true(part.length == 5 && part[0, 4] == ['all_1_1_0', '5', '4', 'Wide'],
        "raw stock part identity/mark census differs for #{id}")
      check = marker_section(schema_stdout, "W238_CHECK_BEGIN_#{id}", "W238_CHECK_END_#{id}", "stock CHECK #{id}")
      require_true(check == W::CHECK_OUTPUT && detail.fetch('check_output') == W::CHECK_OUTPUT,
        "stock CHECK did not report exact 1 for #{id}")
      copied_part = File.join(root, 'stock-parts', id, 'all_1_1_0')
      reported_path = File.expand_path(part.fetch(4))
      require_true(reported_path.start_with?(store + File::SEPARATOR) &&
        detail.fetch('source_system_parts_path') == reported_path &&
        detail.fetch('stock_part_path') == copied_part && core.fetch('stock_part_path') == copied_part,
        "stock system.parts path/copy lineage differs for #{id}")
      actual_inventory = inventory(copied_part)
      require_true(inventory(reported_path) == actual_inventory && actual_inventory == detail.fetch('physical').fetch('inventory'),
        "actual stock part file inventory differs for #{id}")
      require_true(detail.fetch('part_census') == part, "stock summary part census differs from raw output for #{id}")

      rbnwt_label = "stock-rbnwt-#{id}"
      rbnwt_status, rbnwt_bytes, = audit_call(root, stems.find { |stem| stem.end_with?(rbnwt_label) },
        label: rbnwt_label, sql: stock_rbnwt_sql(id), binary: binary, store: store,
        summary_record: summary_by_label.fetch(rbnwt_label))
      expected_rbnwt = F.rowbinary_with_names_and_types(profile)
      capture_path = File.join(root, 'captures', "#{id}.rowbinary-with-names-and-types")
      require_true(rbnwt_status.fetch('exitstatus') == 0 && rbnwt_bytes == expected_rbnwt &&
        read_regular(capture_path) == expected_rbnwt && core.fetch('rbnwt').fetch('observed_hex') == expected_rbnwt.unpack1('H*'),
        "actual RBNWT header/descriptor/values differ from independent literals for #{id}")

      windows_label = "stock-rowbinary-windows-#{id}"
      audit_call(root, stems.find { |stem| stem.end_with?(windows_label) }, label: windows_label,
        sql: stock_windows_sql(root, id), binary: binary, store: store,
        summary_record: summary_by_label.fetch(windows_label))
      F.rowbinary_windows(profile).each do |window, expected_bytes|
        path = File.join(root, 'captures', "#{id}-#{window}.rowbinary")
        require_true(read_regular(path) == expected_bytes &&
          core.fetch('rowbinary_windows').fetch(window).fetch('observed_hex') == expected_bytes.unpack1('H*'),
          "actual stock #{window} RowBinary bytes differ for #{id}")
      end
    end

    F.source_refusal_cases.each do |item|
      label = "constructor-refusal-#{item.fetch('id')}"
      sql = "CREATE TABLE default.w238_refused_#{item.fetch('id')} (payload #{item.fetch('type')}) ENGINE=Memory"
      audit_call(root, stems.find { |stem| stem.end_with?(label) }, label: label, sql: sql,
        binary: binary, store: store, expected: :refusal, diagnostic: item.fetch('diagnostic'),
        summary_record: summary_by_label.fetch(label))
    end
    unknown_name = 'CustomGeoW238Unknown'
    unknown_descriptor = "\x2c".b + F.rb_string(unknown_name)
    unknown_input = F.varuint(1) + F.rb_string('payload') + unknown_descriptor
    unknown_label = 'unknown-custom-descriptor-decode'
    unknown_sql = 'INSERT INTO default.w238_stock_point (payload) FORMAT RowBinaryWithNamesAndTypes'
    unknown_diag = /Unknown|CustomGeoW238Unknown/i
    unknown_stem = stems.find { |stem| stem.end_with?(unknown_label) }
    audit_call(root, unknown_stem, label: unknown_label, sql: unknown_sql, binary: binary, store: store,
      expected: :refusal, stdin: unknown_input, special: :binary_type_input,
      diagnostic: unknown_diag, summary_record: summary_by_label.fetch(unknown_label))
    refusal_rows = matrix.fetch('refusal_observations')
    require_true(refusal_rows.length == F.source_refusal_cases.length + 1 &&
      refusal_rows.all? { |row| row.fetch('classification').start_with?('expected_normal_') },
      'matrix refusal classifications are incomplete')
    expected_capture_files = F.profiles.flat_map do |profile|
      id = profile.fetch('id')
      ["#{id}.rowbinary-with-names-and-types"] + %w[full middle zero].map { |window| "#{id}-#{window}.rowbinary" }
    end.sort
    actual_capture_files = Dir.glob(File.join(root, 'captures', '**', '*')).select { |path| File.file?(path) }
      .map { |path| path.delete_prefix(File.join(root, 'captures') + File::SEPARATOR) }.sort
    require_true(actual_capture_files == expected_capture_files,
      'stock actual capture file inventory contains missing or unexpected files')
    unknown_fixture = File.join(root, 'fixtures', 'unknown-custom-descriptor.rowbinary-with-names-and-types')
    require_true(read_regular(unknown_fixture) == unknown_input,
      'unknown custom descriptor fixture file differs from the raw input literal')
    require_true(Dir.children(File.join(root, 'stock-parts')).sort == F.profiles.map { |profile| profile.fetch('id') }.sort,
      'stock copied-part directory roster differs')
    puts "W238 stock raw evidence audit passed: #{F.profiles.length} profiles, #{expected_labels.length} process captures"
    true
  rescue KeyError, IndexError => error
    fail!("stock evidence shape mismatch: #{error.message}")
  end

  def native_create_sql(evidence_root)
    statements = []
    F.profiles.each do |profile|
      id = profile.fetch('id')
      table = "w238_native_#{id}"
      statements << "CREATE TABLE default.#{table} (pk UInt64, payload #{profile.fetch('declared_type')}) ENGINE=MergeTree ORDER BY pk SETTINGS #{W::STOCK_SETTINGS.join(', ')}"
      statements << "SELECT 'W238_NATIVE_DATA_PATH_BEGIN_#{id}' FORMAT TSVRaw"
      statements << "SELECT arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw"
      statements << "SELECT 'W238_NATIVE_DATA_PATH_END_#{id}' FORMAT TSVRaw"
    end
    statements.join(";\n")
  end

  def native_capture_sql(root)
    statements = []
    F.profiles.each do |profile|
      id = profile.fetch('id')
      table = "w238_native_#{id}"
      statements.concat([
        "SELECT 'W238_NATIVE_CHECK_BEGIN_#{id}' FORMAT TSVRaw",
        "CHECK TABLE default.#{table} FORMAT TSVRaw",
        "SELECT 'W238_NATIVE_CHECK_END_#{id}' FORMAT TSVRaw",
        "SELECT 'W238_NATIVE_SCHEMA_BEGIN_#{id}' FORMAT TSVRaw",
        "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw",
        "SELECT 'W238_NATIVE_SCHEMA_END_#{id}' FORMAT TSVRaw",
        "SELECT 'W238_NATIVE_PART_BEGIN_#{id}' FORMAT TSVRaw",
        "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw",
        "SELECT 'W238_NATIVE_PART_END_#{id}' FORMAT TSVRaw",
      ])
      { 'full' => '', 'middle' => ' WHERE pk BETWEEN 22 AND 44', 'zero' => ' WHERE pk > 55' }.each do |window, predicate|
        path = File.join(root, 'captures', 'native-rowbinary', "#{id}-#{window}.rowbinary")
        statements << "SELECT pk, payload FROM default.#{table}#{predicate} ORDER BY pk INTO OUTFILE '#{path}' FORMAT RowBinary"
      end
    end
    statements.join(";\n")
  end

  def audit_helper!(root, summary, profiles, matrix_path, generated_root)
    invocation_root = File.join(root, 'invocations')
    base = File.join(invocation_root, 'helper')
    meta = json_file(base + '.argv.json')
    status = json_file(base + '.status.json')
    stdout = read_regular(base + '.stdout')
    stderr = read_regular(base + '.stderr')
    helper_path = File.expand_path(summary.fetch('helper_path'))
    helper_sha = summary.fetch('helper_sha256')
    require_true(File.file?(helper_path) && File.executable?(helper_path) && !File.symlink?(helper_path) &&
      File.realpath(helper_path) == helper_path && Digest::SHA256.file(helper_path).hexdigest == helper_sha &&
      summary.fetch('helper_sha256_at_start') == helper_sha,
      'paired helper path/hash is not stable and pinned')
    expected_argv = [helper_path, '--stock-matrix', matrix_path, '--output-root', generated_root]
    require_true(meta.fetch('label') == W::HELPER_LABEL && meta.fetch('argv') == expected_argv &&
      meta.fetch('environment') == { 'TZ' => 'UTC' } && meta.fetch('timeout_seconds') == W::HELPER_TIMEOUT_SECONDS,
      'raw helper argv/environment/timeout differs from the helper contract')
    require_true(!File.exist?(base + '.stdin.bin') && status.fetch('classification') == 'process_success' &&
      status.fetch('exitstatus') == 0 && status.fetch('timed_out') == false && status.fetch('signaled') == false &&
      status['termsig'].nil? && status['spawn_error'].nil? && status.fetch('stdout_bytes') == stdout.bytesize &&
      status.fetch('stderr_bytes') == stderr.bytesize &&
      summary.fetch('helper_process').reject { |key, _| key == 'argv' } == status &&
      summary.fetch('helper_process').fetch('argv') == expected_argv,
      'raw helper process status is not a clean exit 0 or differs from summary')
    require_true(summary.fetch('helper_output_path') == base + '.stdout' &&
      summary.fetch('helper_stdout_sha256') == Digest::SHA256.hexdigest(stdout), 'helper stdout hash/path differs')
    output = JSON.parse(stdout.force_encoding(Encoding::UTF_8))
    require_true(output.fetch('format') == W::HELPER_FORMAT && output.fetch('matrix_path') == matrix_path &&
      output.fetch('matrix_sha256') == summary.fetch('stock_matrix_sha256') && output.fetch('output_root') == generated_root &&
      output.fetch('row_keys') == F::ROW_KEYS && output.fetch('mark_rows') == F::MARK_ROWS,
      'actual helper stdout provenance/axes differ')
    observed = output.fetch('profiles')
    require_true(observed.length == profiles.length, 'actual helper stdout profile roster is incomplete')
    generated_profiles_root = File.join(generated_root, 'generated')
    require_true(File.directory?(generated_profiles_root) && !File.symlink?(generated_profiles_root) &&
      File.realpath(generated_profiles_root) == generated_profiles_root &&
      Dir.children(generated_profiles_root).sort == profiles.map { |profile| profile.fetch('id') }.sort,
      'actual generated-part profile directory roster differs')
    observed.zip(profiles).each do |helper, profile|
      id = profile.fetch('id')
      type = profile.fetch('declared_type')
      values = F.values_hex(profile)
      require_true(helper.fetch('id') == id && helper.fetch('declared_type') == type &&
        helper.fetch('type_shape') == F.expected_type_shape(type) &&
        helper.fetch('descriptor_hex') == F.descriptor_hex(type) && helper.fetch('values_hex') == values &&
        File.expand_path(helper.fetch('stock_part_path')) == profile.fetch('stock_part_path'),
        "actual helper profile identity/literal differs for #{id}")
      require_true(helper.fetch('writer') == {
        'api' => 'WidePartWriter.write_uint64_custom_geo_bulk_part',
        'rows_per_mark' => 2, 'profile' => 'with_size_stream',
        'granule_row_counts' => F::MARK_ROWS,
      }, "actual helper writer metadata/profile differs for #{id}")
      generated_part = File.join(generated_root, 'generated', id, 'all_1_1_0')
      require_true(File.expand_path(helper.fetch('library_part_path')) == generated_part,
        "helper generated part path differs for #{id}")
      require_true(Dir.children(File.join(generated_profiles_root, id)).sort == ['all_1_1_0'],
        "actual generated-part directory contains unexpected entries for #{id}")
      %w[stock_direct_reader direct_reader].each do |key|
        reader = helper.fetch(key)
        require_true(reader.fetch('schema_declaration') == type && reader.fetch('source_declaration') == type &&
          reader.fetch('row_count') == F::ROW_KEYS.length && reader.fetch('mark_rows') == F::MARK_ROWS &&
          reader.fetch('mark_count') == F::MARK_ROWS.length && reader.fetch('full_values_hex') == values &&
          reader.fetch('middle_values_hex') == values[2, 2] && reader.fetch('final_short_values_hex') == values[4, 1] &&
          reader.fetch('eof_empty') == true && reader.fetch('physical_stream_names').is_a?(Array) &&
          !reader.fetch('physical_stream_names').empty? && reader.fetch('selected_checksum_names').is_a?(Array) &&
          !reader.fetch('selected_checksum_names').empty?, "helper raw JSON #{key} witness differs for #{id}")
      end
      if F::TYPED_CONSUMER_IDS.include?(id)
        %w[stock_typed_consumer typed_consumer].each do |key|
          consumer = helper.fetch(key)
          require_true(consumer.fetch('keys') == F::ROW_KEYS && consumer.fetch('values_hex') == values &&
            consumer.fetch('full_values_hex') == values && consumer.fetch('middle_window_values_hex') == values[1, 3] &&
            consumer.fetch('eof_callbacks') == 0, "helper raw JSON #{key} witness differs for #{id}")
        end
      else
        require_true(helper.fetch('stock_typed_consumer').nil? && helper.fetch('typed_consumer').nil?,
          "helper emits unrostered consumer for #{id}")
      end
      require_true(inventory(generated_part).length > 0, "actual generated part inventory is empty for #{id}")
    end
    output
  rescue JSON::ParserError, KeyError => error
    fail!("helper raw output contract malformed: #{error.message}")
  end

  def audit_paired!(evidence_root)
    root = canonical_root(evidence_root, EVIDENCE_PREFIX, 'paired evidence root')
    summary = json_file(File.join(root, 'summary.json'))
    require_true(summary.fetch('format') == W::SUMMARY_FORMAT && summary.fetch('classification') == 'paired_custom_geo_profiles_observed' &&
      summary.fetch('success') == true && summary['error'].nil? && summary.fetch('profile_count_expected') == F.profiles.length &&
      summary.fetch('profile_count_observed') == F.profiles.length,
      'paired summary does not claim complete observed profiles')
    stock_root = canonical_root(summary.fetch('stock_root'), STOCK_PREFIX, 'paired stock root')
    matrix_path = File.join(stock_root, 'stock-matrix.json')
    require_true(summary.fetch('stock_matrix_path') == matrix_path &&
      summary.fetch('stock_matrix_sha256') == Digest::SHA256.file(matrix_path).hexdigest,
      'paired stock matrix lineage hash/path differs')
    matrix = json_file(matrix_path)
    require_true(matrix.fetch('format') == P::MATRIX_FORMAT, 'paired stock matrix format differs')
    generated_root = canonical_root(summary.fetch('generated_root'), GENERATED_PREFIX, 'generated root')
    reference = json_file(File.join(root, 'stock-matrix-reference.json'))
    require_true(reference.fetch('path') == matrix_path && reference.fetch('sha256') == summary.fetch('stock_matrix_sha256') &&
      reference.fetch('format') == P::MATRIX_FORMAT && reference.fetch('stock_root') == stock_root,
      'paired matrix reference sidecar differs')
    profiles = F.profiles.map(&:dup)
    matrix_profiles = matrix.fetch('profiles')
    details = matrix.fetch('profile_evidence')
    require_true(matrix_profiles.length == profiles.length && details.length == profiles.length,
      'paired source matrix is incomplete')
    profiles.each_with_index do |profile, index|
      core = matrix_profiles.fetch(index)
      detail = details.fetch(index)
      id = profile.fetch('id')
      require_true(core.fetch('id') == id && core.fetch('declared_type') == profile.fetch('declared_type') &&
        core.fetch('descriptor_hex') == F.descriptor_hex(profile.fetch('declared_type')) &&
        core.fetch('values_hex') == F.values_hex(profile), "paired stock literal lineage differs for #{id}")
      stock_part = File.join(stock_root, 'stock-parts', id, 'all_1_1_0')
      require_true(core.fetch('stock_part_path') == stock_part && inventory(stock_part) == detail.fetch('physical').fetch('inventory'),
        "actual stock part lineage/inventory differs for #{id}")
      profile['stock_part_path'] = stock_part
    end

    expected_labels = W.expected_native_labels
    stems, summary_by_label = verify_process_roster!(root, expected_labels, summary.fetch('processes'),
      ancillary_stems: ['helper'])
    verify_raw_sidecar_roster!(root, stems, ancillary_stems: ['helper'])
    binary, = validate_binary_from_argv!(root, R::RUNTIME_SHA256)
    store = File.join(root, 'stores', 'native')
    runtime_pin = summary.fetch('runtime_pin')
    require_true(File.expand_path(runtime_pin.fetch('binary')) == binary &&
      runtime_pin.fetch('version') == R::VERSION && runtime_pin.fetch('build_hash') == R::BUILD_HASH &&
      runtime_pin.fetch('sha256') == R::RUNTIME_SHA256 && runtime_pin.fetch('source_correlation') == 'not_asserted',
      'paired summary runtime pin differs from actual executable/source-runtime boundary')
    runtime_sqls.each do |label, sql|
      _, stdout, = audit_call(root, stems.find { |stem| stem.end_with?(label) }, label: label,
        sql: sql, binary: binary, store: store, summary_record: summary_by_label.fetch(label))
      expected = label == 'runtime-version-pin' ? "#{R::VERSION}\n" : "VERSION_GITHASH=#{R::BUILD_HASH}\n"
      require_true(stdout == expected, "paired raw runtime pin output differs for #{label}")
    end
    helper_output = audit_helper!(root, summary, profiles, matrix_path, generated_root)
    create_label = 'native-create-all'
    create_sql = native_create_sql(root)
    _, create_stdout, = audit_call(root, stems.find { |stem| stem.end_with?(create_label) }, label: create_label,
      sql: create_sql, binary: binary, store: store, summary_record: summary_by_label.fetch(create_label))
    native_paths = {}
    profiles.each do |profile|
      id = profile.fetch('id')
      section = marker_section(create_stdout, "W238_NATIVE_DATA_PATH_BEGIN_#{id}",
        "W238_NATIVE_DATA_PATH_END_#{id}", "native data path #{id}").lines.map(&:chomp)
      require_true(section.length == 1 && !section.first.empty?, "native system.tables.data_paths raw result malformed for #{id}")
      path = File.expand_path(section.first)
      require_true(path.start_with?(store + File::SEPARATOR) && File.directory?(path) &&
        !File.symlink?(path) && File.realpath(path) == path,
        "native system.tables.data_paths escaped evidence store for #{id}")
      native_paths[id] = path
    end

    attach_label = 'native-attach-all'
    attach_sql = profiles.map { |profile| "ALTER TABLE default.w238_native_#{profile.fetch('id')} ATTACH PART 'all_1_1_0'" }.join(";\n")
    audit_call(root, stems.find { |stem| stem.end_with?(attach_label) }, label: attach_label,
      sql: attach_sql, binary: binary, store: store, summary_record: summary_by_label.fetch(attach_label))
    capture_label = 'native-capture-all'
    capture_status, capture_stdout, = audit_call(root, stems.find { |stem| stem.end_with?(capture_label) },
      label: capture_label, sql: native_capture_sql(root), binary: binary, store: store,
      summary_record: summary_by_label.fetch(capture_label))
    require_true(capture_status.fetch('exitstatus') == 0, 'native capture process did not exit zero')

    paired_profiles = summary.fetch('profiles')
    require_true(paired_profiles.length == profiles.length, 'paired summary profile records are incomplete')
    helper_profiles = helper_output.fetch('profiles')
    detached_snapshot_root = File.join(root, 'parts', 'native')
    require_true(Dir.children(detached_snapshot_root).sort == profiles.map { |profile| profile.fetch('id') }.sort,
      'preserved native detached-copy profile roster differs')
    profiles.each_with_index do |profile, index|
      id = profile.fetch('id')
      type = profile.fetch('declared_type')
      expected_values = F.values_hex(profile)
      row = paired_profiles.fetch(index)
      helper = helper_profiles.fetch(index)
      native_path = native_paths.fetch(id)
      attached_path = File.join(native_path, 'all_1_1_0')
      require_true(row.fetch('id') == id && row.fetch('declared_type') == type &&
        row.fetch('descriptor_hex') == F.descriptor_hex(type) && row.fetch('values_hex') == expected_values &&
        File.expand_path(row.fetch('native_data_path')) == native_path &&
        File.expand_path(row.fetch('attached_part_path')) == attached_path,
        "paired summary identity/path differs for #{id}")
      generated_part = File.join(generated_root, 'generated', id, 'all_1_1_0')
      generated_inventory = inventory(generated_part)
      detached_path = File.expand_path(row.fetch('detached_part_path'))
      expected_detached_path = File.join(native_path, 'detached', 'all_1_1_0')
      detached_snapshot = File.join(detached_snapshot_root, id, 'all_1_1_0')
      require_true(Dir.children(File.join(detached_snapshot_root, id)).sort == ['all_1_1_0'],
        "preserved native detached-copy directory has unexpected entries for #{id}")
      require_true(detached_path == expected_detached_path &&
        row.fetch('detached_inventory_before_attach') == generated_inventory &&
        File.expand_path(row.fetch('detached_snapshot_path')) == detached_snapshot &&
        inventory(detached_snapshot) == generated_inventory &&
        !File.exist?(detached_path) && !File.symlink?(detached_path),
        "actual detached-copy inventory/path/consumption differs for #{id}")
      require_true(row.fetch('helper_profile') == helper,
        "paired summary helper profile differs from actual helper output for #{id}")
      check = marker_section(capture_stdout, "W238_NATIVE_CHECK_BEGIN_#{id}",
        "W238_NATIVE_CHECK_END_#{id}", "native CHECK #{id}")
      require_true(check == W::CHECK_OUTPUT && row.fetch('native_check_output') == check,
        "actual native CHECK does not show exactly one valid part for #{id}")
      schema = marker_section(capture_stdout, "W238_NATIVE_SCHEMA_BEGIN_#{id}",
        "W238_NATIVE_SCHEMA_END_#{id}", "native schema #{id}").lines.map(&:chomp)
      require_true(schema == ["pk\tUInt64", "payload\t#{type}"] && row.fetch('native_schema_rows') == schema,
        "actual attached native schema/nominal type differs for #{id}")
      part_rows = marker_section(capture_stdout, "W238_NATIVE_PART_BEGIN_#{id}",
        "W238_NATIVE_PART_END_#{id}", "native part #{id}").lines.map(&:chomp)
      require_true(part_rows.length == 1, "actual native part census is not singular for #{id}")
      fields = part_rows.first.split("\t", -1)
      require_true(fields.length == 5 && fields[0, 4] == ['all_1_1_0', '5', '4', 'Wide'] &&
        File.expand_path(fields[4]) == attached_path && row.fetch('native_part_census') == fields,
        "actual attached native rows/marks/path differ for #{id}")
      attached_inventory = inventory(attached_path)
      comparison = row.fetch('inventory_comparison')
      by_generated = generated_inventory.to_h { |entry| [entry.fetch('path'), entry] }
      by_attached = attached_inventory.to_h { |entry| [entry.fetch('path'), entry] }
      removed = (by_generated.keys - by_attached.keys).sort
      changed = by_generated.keys.select { |name| by_attached.key?(name) && by_generated.fetch(name) != by_attached.fetch(name) }.sort
      added = (by_attached.keys - by_generated.keys).sort
      require_true(removed.empty? && changed.empty? && [[], [W::INVALIDATED_FILE]].include?(added) &&
        comparison.fetch('generated_inventory') == generated_inventory &&
        comparison.fetch('attached_inventory') == attached_inventory && comparison.fetch('removed') == removed &&
        comparison.fetch('changed') == changed && comparison.fetch('added') == added,
        "actual ATTACH inventory lineage differs for #{id}")
      if added == [W::INVALIDATED_FILE]
        invalidated = read_regular(File.join(attached_path, W::INVALIDATED_FILE))
        require_true(["_block_number\n_block_offset\n", "_block_offset\n_block_number\n"].include?(invalidated) &&
          comparison.fetch('invalidated_system_columns_hex') == invalidated.unpack1('H*'),
          "actual invalidated system columns file differs for #{id}")
      else
        require_true(comparison['invalidated_system_columns_hex'].nil?, "unexpected invalidation witness for #{id}")
      end
      windows = F.rowbinary_windows(profile)
      windows.each do |window, expected|
        path = File.join(root, 'captures', 'native-rowbinary', "#{id}-#{window}.rowbinary")
        actual = read_regular(path)
        evidence = row.fetch('rowbinary_windows').fetch(window)
        require_true(actual == expected && evidence.fetch('path') == path && evidence.fetch('matches') == true &&
          evidence.fetch('literal_hex') == expected.unpack1('H*') && evidence.fetch('observed_hex') == actual.unpack1('H*') &&
          evidence.fetch('sha256') == Digest::SHA256.hexdigest(actual),
          "actual native #{window} RowBinary bytes differ for #{id}")
      end
      require_true(helper.fetch('direct_reader').fetch('full_values_hex') == expected_values &&
        helper.fetch('stock_direct_reader').fetch('full_values_hex') == expected_values,
        "helper raw reader output differs from independent values for #{id}")
    end
    puts "W238 paired raw evidence audit passed: #{profiles.length} profiles, exact native CHECK/schema/RowBinary and part inventories"
    true
  rescue KeyError, IndexError => error
    fail!("paired evidence shape mismatch: #{error.message}")
  end

  def main(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = <<~USAGE
        Usage:
          ruby scripts/check_custom_geo_recursive_evidence_w238.rb --stock-root STOCK_ROOT [--evidence-root PAIRED_EVIDENCE_ROOT]
        Audits actual W238 raw argv/status/sql/stdout/stderr/stdin sidecars and actual part/RowBinary files.
        A canonical stock root is required; evidence-root adds the paired native/helper audit.
      USAGE
      opts.on('--stock-root PATH') { |value| options[:stock_root] = value }
      opts.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
    end
    parser.parse!(argv)
    require_true(argv.empty? && options.key?(:stock_root), parser.to_s)
    audit_stock!(options.fetch(:stock_root))
    audit_paired!(options.fetch(:evidence_root)) if options.key?(:evidence_root)
    true
  rescue StandardError => error
    warn "W238 independent raw evidence audit failed: #{error.class}: #{error.message}"
    false
  end
end

exit(CheckCustomGeoRecursiveEvidenceW238.main(ARGV) ? 0 : 1) if $PROGRAM_NAME == __FILE__
