#!/usr/bin/env ruby
# Read-only raw audit for W237 stock-only or paired native evidence.

require 'digest'
require 'find'
require 'json'
require 'optparse'
require_relative 'recheck_aggregate_minmax_w237'

module CheckAggregateMinmaxEvidenceW237
  extend self

  M = RecheckAggregateMinmaxW237
  R = M::R
  EXPECTED_CHECK = M::CHECK_OUTPUT
  SOURCE_ROOT = M::SOURCE_ROOT
  SOURCE_REVISION = M::SOURCE_REVISION
  SOURCE_SHA256 = M::SOURCE_SHA256

  def fail!(message)
    raise ArgumentError, message
  end

  def require_true(condition, message)
    fail!(message) unless condition
  end

  def read_file(path, root)
    full = File.expand_path(path)
    require_true(File.file?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "missing, symlinked, or noncanonical evidence file: #{full}")
    prefix = File.realpath(root) + File::SEPARATOR
    require_true(full.start_with?(prefix), "evidence file escaped its root: #{full}")
    File.binread(full)
  end

  def json_file(path, root)
    JSON.parse(read_file(path, root).force_encoding(Encoding::UTF_8))
  rescue JSON::ParserError => error
    fail!("invalid JSON evidence #{path}: #{error.message}")
  end

  def canonical_root(path, prefix, label)
    full = File.expand_path(path)
    require_true(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "#{label} is absent, symlinked, or noncanonical")
    require_true(File.dirname(full) == File.realpath('/private/tmp') && full.start_with?(prefix),
      "#{label} is not a direct child of /private/tmp with its fixed prefix")
    full
  end

  def inventory(part)
    full = File.expand_path(part)
    require_true(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "part is absent, symlinked, or noncanonical: #{full}")
    files = []
    Find.find(full) do |path|
      next if path == full
      require_true(!File.symlink?(path), "part contains symlink: #{path}")
      next if File.directory?(path)
      require_true(File.file?(path), "part contains non-file entry: #{path}")
      bytes = File.binread(path)
      files << { 'path' => path[(full.length + 1)..-1], 'size' => bytes.bytesize,
        'sha256' => Digest::SHA256.hexdigest(bytes) }
    end
    files.sort_by { |row| row.fetch('path') }
  end

  def marker_section(stdout, start_marker, end_marker, label)
    lines = stdout.force_encoding(Encoding::UTF_8).scrub.lines
    starts = lines.each_index.select { |index| lines[index].chomp == start_marker }
    finishes = lines.each_index.select { |index| lines[index].chomp == end_marker }
    require_true(starts.length == 1 && finishes.length == 1 && finishes.first > starts.first,
      "raw stdout marker cardinality/order differs for #{label}")
    lines[(starts.first + 1)...finishes.first].join
  end

  def load_invocations(root)
    paths = Dir.glob(File.join(root, 'invocations', '*.argv.json')).sort
    require_true(!paths.empty?, "no raw ClickHouse invocations under #{root}")
    index = {}
    paths.each_with_index do |argv_path, position|
      argv_record = json_file(argv_path, root)
      label = argv_record.fetch('label')
      require_true(!index.key?(label), "duplicate raw ClickHouse invocation label: #{label}")
      base = argv_path.sub(/\.argv\.json\z/, '')
      expected_stem = format('%04d-%s', position + 1, R.safe_label(label))
      require_true(File.basename(base) == expected_stem, "raw invocation sequence/stem differs: #{label}")
      status = json_file(base + '.status.json', root)
      stdout = read_file(base + '.stdout', root)
      stderr = read_file(base + '.stderr', root)
      sql_bytes = read_file(base + '.sql', root)
      require_true(status.fetch('label') == label && status.fetch('stdout_bytes') == stdout.bytesize &&
        status.fetch('stderr_bytes') == stderr.bytesize, "raw status/stdout/stderr mismatch: #{label}")
      stdin_path = base + '.stdin.bin'
      if argv_record['stdin_bytes'].nil?
        require_true(argv_record['stdin_sha256'].nil? && !File.exist?(stdin_path) && !File.symlink?(stdin_path),
          "unexpected raw stdin sidecar: #{label}")
        stdin = nil
      else
        stdin = read_file(stdin_path, root)
        require_true(stdin.bytesize == argv_record.fetch('stdin_bytes') &&
          Digest::SHA256.hexdigest(stdin) == argv_record.fetch('stdin_sha256'),
          "raw stdin byte count/hash mismatch: #{label}")
      end
      sql = sql_bytes.force_encoding(Encoding::UTF_8)
      require_true(sql.valid_encoding? && sql.end_with?("\n") && sql.bytesize > 1,
        "raw SQL sidecar is empty or malformed: #{label}")
      index[label] = { 'argv_record' => argv_record, 'status' => status, 'stdout' => stdout,
        'stderr' => stderr, 'sql' => sql, 'stdin' => stdin, 'base' => base }
    end
    index
  end

  def stock_labels(profiles)
    labels = %w[runtime-version-pin runtime-build-pin constructor-positive-census
      constructor-invalid-dynamic-min constructor-invalid-dynamic-max
      constructor-invalid-variant-min constructor-invalid-variant-max]
    labels.concat(M::CONSTRUCTOR_ONLY_TYPES.map { |spec| "constructor-lc-only-#{spec.fetch('id')}" })
    labels.concat(profiles.map { |profile| "source-controls-#{profile.fetch('id')}" })
    labels.concat(%w[min max].flat_map do |operation|
      M::STRING_LEGACY_CASES.flat_map do |spec|
        id = "#{operation}_#{spec.fetch('id')}"
        %W[string-legacy-create-#{id} string-legacy-insert-#{id} string-legacy-readback-#{id}]
      end
    end)
    labels << 'stock-create-all'
    labels.concat(profiles.map { |profile| "stock-insert-#{profile.fetch('id')}" })
    labels << 'stock-capture-all'
    labels
  end

  def paired_labels
    %w[runtime-version-pin runtime-build-pin native-create-all native-attach-all native-capture-all]
  end

  def source_type_candidates(profile)
    operation = profile.fetch('operation')
    candidates = [profile.fetch('requested_type')]
    if profile.fetch('id').end_with?('_nested')
      candidates << "AggregateFunction(#{operation}, Array(Tuple(n UInt8, label String)))"
    elsif profile['wrapper'] == 'low_cardinality'
      candidates << "AggregateFunction(#{operation}, UInt16)"
    elsif profile['wrapper'] == 'low_cardinality_nullable'
      candidates << "AggregateFunction(#{operation}, Nullable(UInt8))"
    end
    candidates.uniq
  end

  def stock_profile_roster(matrix, profiles, root)
    require_true(matrix.fetch('format') == M::STOCK_FORMAT && matrix.fetch('row_keys') == M::ROW_KEYS &&
      matrix.fetch('mark_rows') == M::MARK_ROWS && matrix.fetch('profile_count') == profiles.length &&
      matrix.fetch('coverage') == M.coverage_manifest &&
      matrix.fetch('stock_settings') == R::STOCK_SETTINGS + ["string_serialization_version='single_stream'"],
      'stock matrix format, physical axes, finite coverage, or stock settings differ')
    observed = matrix.fetch('profiles')
    details = matrix.fetch('profile_evidence')
    require_true(observed.length == profiles.length && details.length == profiles.length,
      'stock matrix is incomplete for the finite type roster')
    profiles.each_with_index do |profile, index|
      core = observed.fetch(index)
      detail = details.fetch(index)
      id = profile.fetch('id')
      require_true(core.keys.sort == %w[declared_type id states_hex stock_part_path].sort &&
        core.fetch('id') == id && core.fetch('states_hex') == M.state_hex(profile),
        "stock matrix core/literal fixture differs: #{id}")
      require_true(detail.fetch('requested_type') == profile.fetch('requested_type'),
        "stock detail lost the exact requested type for #{id}")
      require_true(source_type_candidates(profile).include?(core.fetch('declared_type')),
        "source constructor emitted an unlisted/canonicalized type for #{id}: #{core.fetch('declared_type')}")
      expected_part = M.profile_part_path(root, profile)
      require_true(core.fetch('stock_part_path') == expected_part,
        "stock part path differs from canonical W237 path: #{id}")
      %w[id declared_type states_hex stock_part_path].each do |key|
        require_true(detail.fetch(key) == core.fetch(key), "stock detail/core cross-reference differs for #{id}/#{key}")
      end
      profile['declared_type'] = core.fetch('declared_type')
      profile['stock_path'] = expected_part
      profile['stock_detail'] = detail
    end
    profiles
  rescue KeyError => error
    fail!("stock matrix is missing a required field: #{error.message}")
  end

  def expected_sql(label, profiles, root, generated_profiles = nil)
    case label
    when 'runtime-version-pin'
      'SELECT version() FORMAT TSVRaw'
    when 'runtime-build-pin'
      "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw"
    when 'constructor-positive-census'
      columns = profiles.each_with_index.map { |profile, index| "p#{format('%03d', index)} #{profile.fetch('requested_type')}" }
      "CREATE TABLE default.w237_constructor (pk UInt8, #{columns.join(', ')}) ENGINE=Memory;\n" \
        "SELECT name, type FROM system.columns WHERE database='default' AND table='w237_constructor' ORDER BY position FORMAT TSVRaw"
    when /^constructor-invalid-(dynamic|variant)-(min|max)$/
      kind, operation = /\Aconstructor-invalid-(dynamic|variant)-(min|max)\z/.match(label).captures
      type = kind == 'dynamic' ? 'Dynamic' : 'Variant(UInt8, String)'
      "CREATE TABLE default.w237_refused_#{kind}_#{operation} (v AggregateFunction(#{operation}, #{type})) ENGINE=Memory"
    when /^constructor-lc-only-(.+)$/
      spec = M::CONSTRUCTOR_ONLY_TYPES.find { |item| item.fetch('id') == Regexp.last_match(1) }
      fail!("unlisted LC constructor-only label: #{label}") unless spec
      table = "w237_#{spec.fetch('id')}"
      id = spec.fetch('id')
      "CREATE TABLE default.#{table} (v #{spec.fetch('type')}) ENGINE=Memory;\n" \
        "SELECT 'W237_LC_CENSUS_BEGIN_#{id}' FORMAT TSVRaw;\n" \
        "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;\n" \
        "SELECT 'W237_LC_CENSUS_END_#{id}' FORMAT TSVRaw"
    when /^source-controls-(.+)$/
      profile = profiles.find { |item| item.fetch('id') == Regexp.last_match(1) }
      fail!("unlisted source-controls label: #{label}") unless profile
      M.source_control_sql(profile, root)
    when /^string-legacy-(create|insert|readback)-(min|max)_(.+)$/
      action, operation, case_id = Regexp.last_match.captures
      spec = M::STRING_LEGACY_CASES.find { |item| item.fetch('id') == case_id }
      fail!("unlisted legacy String case: #{label}") unless spec
      id = "#{operation}_#{case_id}"
      table = "w237_string_legacy_#{operation}_#{case_id}"
      case action
      when 'create'
        type = "AggregateFunction(#{operation}, String)"
        settings = R::STOCK_SETTINGS + ["string_serialization_version='single_stream'"]
        "CREATE TABLE default.#{table} (pk UInt64, v #{type}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings.join(', ')}"
      when 'insert'
        "INSERT INTO default.#{table} FORMAT RowBinary"
      when 'readback'
        path = File.join(root, 'cases', 'string-legacy', "#{id}.rowbinary")
        "SELECT v FROM default.#{table} ORDER BY pk INTO OUTFILE '#{M.quote_sql(path)}' FORMAT RowBinary"
      end
    when 'stock-create-all'
      profiles.map { |profile| M.create_sql(profile, M.table_name(profile)) }.join(";\n")
    when /^stock-insert-(.+)$/
      profile = profiles.find { |item| item.fetch('id') == Regexp.last_match(1) }
      fail!("unlisted stock insert label: #{label}") unless profile
      "INSERT INTO default.#{M.table_name(profile)} FORMAT RowBinary"
    when 'stock-capture-all'
      stock_capture_sql(profiles, root)
    when 'native-create-all'
      statements = []
      profiles.each do |profile|
        id = profile.fetch('id')
        table = M.table_name(profile, 'native')
        statements << M.create_sql(profile, table)
        statements << "SELECT 'W237_NATIVE_DATA_PATH_BEGIN_#{id}' FORMAT TSVRaw"
        statements << "SELECT arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw"
        statements << "SELECT 'W237_NATIVE_DATA_PATH_END_#{id}' FORMAT TSVRaw"
      end
      statements.join(";\n")
    when 'native-attach-all'
      profiles.map do |profile|
        "ALTER TABLE default.#{M.table_name(profile, 'native')} ATTACH PART 'all_1_1_0'"
      end.join(";\n")
    when 'native-capture-all'
      native_capture_sql(profiles, root)
    else
      fail!("unlisted raw ClickHouse invocation label: #{label}")
    end
  end

  def stock_capture_sql(profiles, root)
    statements = []
    profiles.each do |profile|
      id = profile.fetch('id')
      table = M.table_name(profile)
      statements.concat([
        "SELECT 'W237_CHECK_BEGIN_#{id}' FORMAT TSVRaw",
        "CHECK TABLE default.#{table} FORMAT TSVRaw",
        "SELECT 'W237_CHECK_END_#{id}' FORMAT TSVRaw",
        "SELECT 'W237_SCHEMA_BEGIN_#{id}' FORMAT TSVRaw",
        "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw",
        "SELECT 'W237_SCHEMA_END_#{id}' FORMAT TSVRaw",
        "SELECT 'W237_PART_BEGIN_#{id}' FORMAT TSVRaw",
        "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw",
        "SELECT 'W237_PART_END_#{id}' FORMAT TSVRaw",
      ])
      %w[full middle zero].each do |window|
        predicate = { 'full' => '', 'middle' => ' WHERE pk BETWEEN 22 AND 44', 'zero' => ' WHERE pk=0' }.fetch(window)
        path = File.join(root, 'cases', 'stock-rowbinary', "#{id}-#{window}.rowbinary")
        statements << "SELECT pk, v FROM default.#{table}#{predicate} ORDER BY pk INTO OUTFILE '#{M.quote_sql(path)}' FORMAT RowBinary"
      end
    end
    statements.join(";\n")
  end

  def native_capture_sql(profiles, root)
    statements = []
    profiles.each do |profile|
      id = profile.fetch('id')
      table = M.table_name(profile, 'native')
      statements.concat([
        "SELECT 'W237_NATIVE_CHECK_BEGIN_#{id}' FORMAT TSVRaw",
        "CHECK TABLE default.#{table} FORMAT TSVRaw",
        "SELECT 'W237_NATIVE_CHECK_END_#{id}' FORMAT TSVRaw",
        "SELECT 'W237_NATIVE_SCHEMA_BEGIN_#{id}' FORMAT TSVRaw",
        "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw",
        "SELECT 'W237_NATIVE_SCHEMA_END_#{id}' FORMAT TSVRaw",
        "SELECT 'W237_NATIVE_PART_BEGIN_#{id}' FORMAT TSVRaw",
        "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw",
        "SELECT 'W237_NATIVE_PART_END_#{id}' FORMAT TSVRaw",
      ])
      %w[full middle zero].each do |window|
        predicate = { 'full' => '', 'middle' => ' WHERE pk BETWEEN 22 AND 44', 'zero' => ' WHERE pk=0' }.fetch(window)
        path = File.join(root, 'cases', 'native-rowbinary', "#{id}-#{window}.rowbinary")
        statements << "SELECT pk, v FROM default.#{table}#{predicate} ORDER BY pk INTO OUTFILE '#{M.quote_sql(path)}' FORMAT RowBinary"
      end
    end
    statements.join(";\n")
  end

  def expected_store(label, root)
    case label
    when 'runtime-version-pin', 'runtime-build-pin'
      File.join(root, 'stores', 'pins')
    when 'constructor-positive-census'
      File.join(root, 'stores', 'construction')
    when /^constructor-invalid-(dynamic|variant)-(min|max)$/
      File.join(root, 'stores', 'construction', "#{Regexp.last_match(1)}-#{Regexp.last_match(2)}")
    when /^constructor-lc-only-(.+)$/
      File.join(root, 'stores', 'construction', Regexp.last_match(1))
    when /^source-controls-/
      File.join(root, 'stores', 'construction')
    when /^string-legacy-(?:create|insert|readback)-(min|max)_(.+)$/
      File.join(root, 'stores', 'string-legacy', "#{Regexp.last_match(1)}_#{Regexp.last_match(2)}")
    when /^stock-/
      File.join(root, 'stores', 'stock')
    when /^native-/
      File.join(root, 'stores', 'native')
    else
      fail!("unlisted store mapping for invocation: #{label}")
    end
  end

  def validate_clickhouse_invocations!(root, index, labels, profiles, stock_phase:, generated_profiles: nil)
    require_true(index.keys == labels, 'raw ClickHouse invocation order/roster differs from the requested phase')
    binary_record = index.fetch('runtime-version-pin')
    binary = binary_record.fetch('argv_record').fetch('argv').first
    binary = R.validate_binary!(binary)
    index.each do |label, item|
      argv_record = item.fetch('argv_record')
      sql = expected_sql(label, profiles, stock_phase ? root : root, generated_profiles)
      store = expected_store(label, root)
      expected_argv = [binary, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
        '--max_insert_threads=1', '--max_execution_time=30', "--max_memory_usage=#{R::MEMORY_LIMIT_BYTES}",
        '--print_pretty_type_names=0', '--multiquery', '--query', sql]
      require_true(argv_record.fetch('label') == label && argv_record.fetch('argv') == expected_argv &&
        argv_record.fetch('environment') == { 'TZ' => 'UTC' } &&
        argv_record.fetch('timeout_seconds') == R::PROCESS_TIMEOUT_SECONDS,
        "raw ClickHouse argv/environment/timeout differs: #{label}")
      require_true(item.fetch('sql') == (sql.end_with?("\n") ? sql : sql + "\n"),
        "raw SQL sidecar differs from independently reconstructed query: #{label}")
      query = item.fetch('sql').sub(/\n\z/, '')
      require_true(argv_record.fetch('argv').last == query, "argv query differs from SQL sidecar: #{label}")
      require_true(File.directory?(store) && !File.symlink?(store) && File.realpath(store) == store,
        "raw invocation store is absent/noncanonical: #{label}")
      validate_status!(item.fetch('status'), label, stock_phase)
      check_input!(item, label, profiles, stock_phase)
    end
    binary
  end

  def validate_status!(status, label, stock_phase)
    normal = !status.fetch('signaled') && !status.fetch('timed_out') && status.fetch('spawn_error').nil?
    require_true(normal, "process had a signal, timeout, or spawn error: #{label}")
    if label.start_with?('constructor-invalid-')
      require_true(status.fetch('classification') == 'process_nonzero_or_signaled_exit' &&
        status.fetch('exitstatus').is_a?(Integer) && status.fetch('exitstatus').positive?,
        "expected semantic constructor refusal status differs: #{label}")
    elsif stock_phase && (label.start_with?('constructor-lc-only-') || label.start_with?('string-legacy-'))
      if status.fetch('classification') == 'process_success'
        require_true(status.fetch('exitstatus') == 0, "successful source probe has nonzero status: #{label}")
      else
        require_true(status.fetch('classification') == 'process_nonzero_or_signaled_exit' &&
          status.fetch('exitstatus').is_a?(Integer) && status.fetch('exitstatus').positive?,
          "bounded source probe lacked a normal positive refusal exit: #{label}")
      end
    else
      require_true(status.fetch('classification') == 'process_success' && status.fetch('exitstatus') == 0,
        "unexpected nonzero native process: #{label}")
    end
  end

  def expected_input(label, profiles, stock_phase)
    if stock_phase && label.start_with?('stock-insert-')
      profile = profiles.find { |item| label == "stock-insert-#{item.fetch('id')}" }
      return M.rowbinary_rows(profile).join.b if profile
    elsif stock_phase && (match = /\Astring-legacy-insert-(min|max)_(.+)\z/.match(label))
      spec = M::STRING_LEGACY_CASES.find { |item| item.fetch('id') == match[2] }
      return M.little_unsigned(M::ROW_KEYS.first, 8) + [spec.fetch('input_hex')].pack('H*').b
    end
    nil
  end

  def check_input!(item, label, profiles, stock_phase)
    expected = expected_input(label, profiles, stock_phase)
    record = item.fetch('argv_record')
    actual = item.fetch('stdin')
    if expected.nil?
      require_true(actual.nil? && record['stdin_bytes'].nil? && record['stdin_sha256'].nil?,
        "unexpected stdin on raw invocation: #{label}")
    else
      require_true(actual == expected && record.fetch('stdin_bytes') == expected.bytesize &&
        record.fetch('stdin_sha256') == Digest::SHA256.hexdigest(expected),
        "raw stdin differs from independent fixture bytes: #{label}")
    end
  end

  def compare_summary_processes!(summary, index)
    records = summary.fetch('processes')
    require_true(records.map { |record| record.fetch('label') } == index.keys,
      'summary process roster/order differs from raw invocation sidecars')
    fields = %w[label classification exitstatus signaled termsig timed_out duration_ms spawn_error stdout_bytes stderr_bytes]
    records.each do |record|
      raw = index.fetch(record.fetch('label')).fetch('status')
      fields.each do |field|
        require_true(record[field] == raw[field], "summary/raw process status mismatch: #{record.fetch('label')}/#{field}")
      end
      input = index.fetch(record.fetch('label')).fetch('stdin')
      if input
        raw = index.fetch(record.fetch('label'))
        argv_record = raw.fetch('argv_record')
        input_sha256 = Digest::SHA256.hexdigest(input)
        require_true(argv_record.fetch('stdin_bytes') == input.bytesize &&
          argv_record.fetch('stdin_sha256') == input_sha256,
          "raw argv input evidence differs from actual stdin sidecar: #{record.fetch('label')}")

        # The runner summary's process rows are status-only records copied from
        # Recorder#records; stdin metadata lives in the raw argv/stdin sidecars.
        # If summary-level input metadata is ever emitted, cross-check it too.
        has_input_bytes = record.key?('input_bytes')
        has_input_sha256 = record.key?('input_sha256')
        require_true(has_input_bytes == has_input_sha256 &&
          (!has_input_bytes || (record.fetch('input_bytes') == input.bytesize &&
            record.fetch('input_sha256') == input_sha256)),
          "optional summary input evidence differs from raw stdin: #{record.fetch('label')}")
      else
        require_true(!record.key?('input_bytes') && !record.key?('input_sha256'),
          "summary claims input evidence absent from raw invocation: #{record.fetch('label')}")
      end
    end
  end

  def validate_runtime_pins!(summary, matrix, index, binary)
    version = index.fetch('runtime-version-pin')
    build = index.fetch('runtime-build-pin')
    require_true(version.fetch('stdout').strip == M::VERSION &&
      build.fetch('stdout').strip == "VERSION_GITHASH=#{M::BUILD_HASH}",
      'raw ClickHouse version/build pin stdout differs')
    pin = summary.fetch('runtime_pin')
    require_true(pin == matrix.fetch('runtime_pin') && pin.fetch('version') == M::VERSION &&
      pin.fetch('build_hash') == M::BUILD_HASH && pin.fetch('sha256') == Digest::SHA256.file(binary).hexdigest &&
      pin.fetch('runtime_source_correlation') == 'not_asserted',
      'runtime pin object differs from raw native identity or binary SHA')
  end

  def validate_source_pins!(matrix, summary)
    actual_pin = M.source_pin!
    source_pin = matrix.fetch('source_pin')
    require_true(summary.fetch('source_pin') == source_pin && source_pin == actual_pin &&
      source_pin.fetch('source_reference') == "#{SOURCE_ROOT}@#{SOURCE_REVISION}",
      'source revision/hash evidence differs from the actual pinned source files')
  end

  def validate_constructor_census!(root, matrix, profiles, index)
    raw = index.fetch('constructor-positive-census').fetch('stdout')
    rows = raw.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
    expected = ["pk\tUInt8"] + profiles.each_with_index.map do |profile, position|
      "p#{format('%03d', position)}\t#{profile.fetch('declared_type')}"
    end
    require_true(rows == expected, 'raw positive constructor census differs from stock matrix declarations')
    observations = matrix.fetch('constructor_observations')
    accepted_observations = observations.select do |item|
      item.fetch('classification') == 'source_constructor_acceptance_observed'
    end
    accepted = accepted_observations.first
    require_true(accepted_observations.length == 1 && accepted && accepted.fetch('profile_count') == profiles.length &&
      accepted.fetch('requested_types') == profiles.map { |profile| profile.fetch('requested_type') } &&
      accepted.fetch('declared_types') == profiles.map { |profile| profile.fetch('declared_type') } &&
      accepted.fetch('stdout') == raw &&
      accepted.fetch('process') == index.fetch('constructor-positive-census').fetch('status'),
      'constructor census witness differs from raw process output/status')
    invalid = observations.select { |item| item.fetch('classification') == 'expected_semantic_refusal' }
    expected_invalid_ids = %w[dynamic_min dynamic_max variant_min variant_max]
    require_true(observations.length == 5 && invalid.length == expected_invalid_ids.length &&
      invalid.map { |item| item.fetch('id') }.sort == expected_invalid_ids.sort,
      'constructor census lacks the exact four bounded Dynamic/Variant refusals')
    %w[dynamic variant].product(%w[min max]).each do |kind, operation|
      id = "#{kind}_#{operation}"
      label = "constructor-invalid-#{kind}-#{operation}"
      item = invalid.find { |entry| entry.fetch('id') == id }
      process = index.fetch(label)
      diagnostic = (process.fetch('stdout') + process.fetch('stderr')).force_encoding(Encoding::UTF_8).scrub
      require_true(item && item.fetch('process').fetch('exitstatus') == process.fetch('status').fetch('exitstatus') &&
        item.fetch('process') == process.fetch('status') &&
        item.fetch('stdout') == process.fetch('stdout') && item.fetch('stderr') == process.fetch('stderr') &&
        diagnostic.match?(/Illegal type .* of argument of aggregate function #{operation}/i),
        "raw source-level refusal diagnostic/evidence differs: #{label}")
    end
    lc_observations = matrix.fetch('lc_constructor_only_observations')
    require_true(lc_observations.length == M::CONSTRUCTOR_ONLY_TYPES.length &&
      lc_observations.map { |item| item.fetch('id') } == M::CONSTRUCTOR_ONLY_TYPES.map { |spec| spec.fetch('id') },
      'LC constructor-only observation count differs')
    M::CONSTRUCTOR_ONLY_TYPES.each do |spec|
      label = "constructor-lc-only-#{spec.fetch('id')}"
      item = lc_observations.find { |entry| entry.fetch('id') == spec.fetch('id') }
      process = index.fetch(label)
      if process.fetch('status').fetch('exitstatus') == 0
        schema = marker_section(process.fetch('stdout'), "W237_LC_CENSUS_BEGIN_#{spec.fetch('id')}",
          "W237_LC_CENSUS_END_#{spec.fetch('id')}", label).lines.map(&:chomp)
        expected_schema = ["v\t#{spec.fetch('type')}"]
        require_true(item && item.fetch('classification') == 'source_constructor_acceptance_observed' &&
          item.fetch('requested_type') == spec.fetch('type') &&
          item.fetch('process') == process.fetch('status') && item.fetch('schema') == schema &&
          schema == expected_schema,
          "LC constructor accepted but raw observed schema differs: #{label}")
      else
        diagnostic = (process.fetch('stdout') + process.fetch('stderr')).force_encoding(Encoding::UTF_8).scrub
        require_true(item && item.fetch('classification') == 'constructor_process_refusal_observed' &&
          item.fetch('requested_type') == spec.fetch('type') &&
          item.fetch('process') == process.fetch('status') &&
          process.fetch('status').fetch('exitstatus').is_a?(Integer) &&
          process.fetch('status').fetch('exitstatus').positive? &&
          diagnostic.match?(/DB::Exception/),
          "LC constructor refusal lacks raw diagnostic/status evidence: #{label}")
      end
      require_true(item.fetch('stdout') == process.fetch('stdout') && item.fetch('stderr') == process.fetch('stderr'),
        "LC constructor raw output differs from observation record: #{label}")
    end
  end

  def validate_source_controls!(root, matrix, profiles, index)
    controls = matrix.fetch('source_computed_controls')
    require_true(controls.length == profiles.length, 'source-computed control roster differs')
    profiles.each do |profile|
      id = profile.fetch('id')
      observation = controls.find { |item| item.fetch('id') == id }
      process = index.fetch("source-controls-#{id}")
      paths = M.source_control_paths(root, profile)
      observed_type = marker_section(process.fetch('stdout'), "W237_SOURCE_TYPE_BEGIN_#{id}",
        "W237_SOURCE_TYPE_END_#{id}", "source controls #{id}")
      candidate_types = source_type_candidates(profile)
      expected_nominal_type = "AggregateFunction(#{profile.fetch('operation')}, #{profile.fetch('argument_type')})\n"
      require_true(candidate_types.any? { |type| observed_type == "#{type}\n" } &&
        observation && observation.fetch('source_state_type_name') == observed_type &&
        observation.fetch('process') == process.fetch('status') &&
        observation.fetch('requested_type') == profile.fetch('requested_type') &&
        observation.fetch('declared_type') == profile.fetch('declared_type') &&
        observation.fetch('expected_type_name') == expected_nominal_type &&
        profile.fetch('requested_type') == expected_nominal_type.chomp &&
        observation.fetch('type_name_matches_nominal_request') == (observed_type == expected_nominal_type),
        "source-computed state type/nominal-normalization observation differs: #{id}")
      expected_states = { 'empty' => false, 'populated' => true }
      expected_states['all_null'] = false if paths.key?('all_null')
      expected_states.each do |kind, populated|
        path = paths.fetch(kind)
        bytes = read_file(path, root)
        expected = M.expected_control_state(profile, populated: populated)
        recorded = observation.fetch(kind)
        require_true(bytes == expected && recorded.fetch('path') == path && recorded.fetch('matches') == true &&
          recorded.fetch('literal_hex') == expected.unpack1('H*') &&
          recorded.fetch('observed_hex') == bytes.unpack1('H*') &&
          recorded.fetch('sha256') == Digest::SHA256.hexdigest(bytes) && recorded.fetch('bytes') == bytes.bytesize,
          "native source-computed #{kind} state differs from independent literal: #{id}")
      end
    end
  end

  def validate_string_legacy!(root, matrix, index)
    observations = matrix.fetch('string_legacy_observations')
    require_true(observations.length == 2 * M::STRING_LEGACY_CASES.length,
      'legacy String tolerance probe roster differs')
    %w[min max].each do |operation|
      M::STRING_LEGACY_CASES.each do |spec|
        id = "#{operation}_#{spec.fetch('id')}"
        observation = observations.find { |item| item.fetch('id') == id }
        labels = %W[string-legacy-create-#{id} string-legacy-insert-#{id} string-legacy-readback-#{id}]
        records = labels.map { |label| index.fetch(label) }
        require_true(observation.fetch('processes') == records.map { |record| record.fetch('status') },
          "legacy String process witnesses differ from raw statuses: #{id}")
        require_true(records.first.fetch('status').fetch('classification') == 'process_success' &&
          records.first.fetch('status').fetch('exitstatus') == 0,
          "legacy String table creation was not a successful source setup: #{id}")
        input = M.little_unsigned(M::ROW_KEYS.first, 8) + [spec.fetch('input_hex')].pack('H*').b
        require_true(records[1].fetch('stdin') == input && observation.fetch('raw_input_state_hex') == spec.fetch('input_hex') &&
          observation.fetch('expected_canonical_state_hex') == spec.fetch('expected_hex') &&
          observation.fetch('source_law') == spec.fetch('law'),
          "legacy String input/law differs from raw fixture: #{id}")
        if records.all? { |record| record.fetch('status').fetch('exitstatus') == 0 }
          path = File.join(root, 'cases', 'string-legacy', "#{id}.rowbinary")
          actual = read_file(path, root)
          expected = [spec.fetch('expected_hex')].pack('H*').b
          require_true(actual == expected && observation.fetch('classification') == 'source_compatibility_observed' &&
            observation.fetch('observed_output_state_hex') == actual.unpack1('H*'),
            "legacy String canonical readback differs from actual bytes: #{id}")
        else
          insert_status = records[1].fetch('status')
          insert_diagnostic = (records[1].fetch('stdout') + records[1].fetch('stderr'))
            .force_encoding(Encoding::UTF_8).scrub
          require_true(insert_status.fetch('classification') == 'process_nonzero_or_signaled_exit' &&
            insert_status.fetch('exitstatus').is_a?(Integer) && insert_status.fetch('exitstatus').positive? &&
            insert_diagnostic.match?(/DB::Exception/),
            "legacy String nonzero was not a clean source-level insert refusal: #{id}")
          output_path = File.join(root, 'cases', 'string-legacy', "#{id}.rowbinary")
          if File.file?(output_path) && !File.symlink?(output_path)
            require_true(read_file(output_path, root).empty?,
              "legacy String refusal produced unexpected persisted output bytes: #{id}")
          end
          require_true(observation.fetch('classification') == 'normal_process_refusal_observed' &&
            observation.fetch('observed_output_state_hex').nil?,
            "legacy String refusal classification differs from raw process status: #{id}")
        end
      end
    end
  end

  def validate_stock_parts!(root, matrix, profiles, index)
    capture = index.fetch('stock-capture-all').fetch('stdout')
    evidence = matrix.fetch('profile_evidence')
    profiles.each_with_index do |profile, index_in_roster|
      id = profile.fetch('id')
      item = evidence.fetch(index_in_roster)
      check = marker_section(capture, "W237_CHECK_BEGIN_#{id}", "W237_CHECK_END_#{id}", "stock CHECK #{id}")
      require_true(check == EXPECTED_CHECK && item.fetch('check_output') == check,
        "raw stock CHECK result is not exact clean success: #{id}")
      schema = marker_section(capture, "W237_SCHEMA_BEGIN_#{id}", "W237_SCHEMA_END_#{id}", "stock schema #{id}")
      schema_rows = schema.lines.map(&:chomp)
      require_true(schema_rows == ["pk\tUInt64", "v\t#{profile.fetch('declared_type')}"] && item.fetch('schema') == schema_rows,
        "stock system.columns differs from observed constructor declaration: #{id}")
      part_body = marker_section(capture, "W237_PART_BEGIN_#{id}", "W237_PART_END_#{id}", "stock part #{id}")
      part_rows = part_body.lines.map(&:chomp)
      require_true(part_rows.length == 1, "stock part census row cardinality differs: #{id}")
      fields = part_rows.first.split("\t", -1)
      require_true(fields.length == 5 && fields.first(4) == ['all_1_1_0', '5', '4', 'Wide'] &&
        item.fetch('part_census') == fields,
        "stock part name/grid/type differs: #{id}")
      original = File.expand_path(fields.fetch(4))
      store = File.join(root, 'stores', 'stock')
      require_true(original.start_with?(store + File::SEPARATOR), "stock part escaped native store: #{id}")
      copied = profile.fetch('stock_path')
      source_inventory = inventory(original)
      copied_inventory = inventory(copied)
      require_true(source_inventory == copied_inventory && item.fetch('physical').fetch('inventory') == copied_inventory,
        "stock source/copy part files or recorded inventory differ: #{id}")
      metadata = item.fetch('physical').fetch('metadata')
      serialization_bytes = read_file(File.join(copied, 'serialization.json'), root)
      serialization = JSON.parse(serialization_bytes.force_encoding(Encoding::UTF_8))
      metadata_version = read_file(File.join(copied, 'metadata_version.txt'), root).strip
      compression = read_file(File.join(copied, 'default_compression_codec.txt'), root).strip
      expected_serialization = { 'columns' => [], 'propagate_types_serialization_versions_to_nested_types' => true,
        'types_serialization_versions' => { 'string' => 0 }, 'version' => 1 }
      require_true(serialization == expected_serialization && metadata_version == '0' && compression == 'CODEC(LZ4)' &&
        metadata.fetch('serialization_json').fetch('parsed') == serialization &&
        metadata.fetch('serialization_json').fetch('sha256') == Digest::SHA256.hexdigest(serialization_bytes) &&
        metadata.fetch('metadata_version').fetch('text') == metadata_version &&
        metadata.fetch('compression_codec').fetch('text') == compression,
        "stock part physical metadata differs from pinned Wide/LZ4/single-stream settings: #{id}")
      validate_rowbinary_windows!(root, profile, item.fetch('rowbinary_windows'), 'stock-rowbinary')
    end
  end

  def validate_rowbinary_windows!(root, profile, recorded, directory)
    %w[full middle zero].each do |window|
      path = File.join(root, 'cases', directory, "#{profile.fetch('id')}-#{window}.rowbinary")
      actual = read_file(path, root)
      expected = M.rowbinary_window(profile, window)
      row = recorded.fetch(window)
      require_true(actual == expected && row.fetch('path') == path && row.fetch('bytes') == actual.bytesize &&
        row.fetch('sha256') == Digest::SHA256.hexdigest(actual) && row.fetch('literal_hex') == expected.unpack1('H*') &&
        row.fetch('matches_independent_literal') == true,
        "actual #{window} RowBinary differs from independent literal rows: #{profile.fetch('id')}")
    end
  end

  def validate_stock!(path)
    root = canonical_root(path, M::STOCK_PREFIX, 'stock root')
    matrix_path = File.join(root, 'stock-matrix.json')
    matrix_bytes = read_file(matrix_path, root)
    matrix = JSON.parse(matrix_bytes.force_encoding(Encoding::UTF_8))
    summary = json_file(File.join(root, 'summary.json'), root)
    profiles = M.profiles
    stock_profile_roster(matrix, profiles, root)
    require_true(summary.fetch('format') == M::SUMMARY_FORMAT && summary.fetch('success') == true &&
      summary.fetch('classification') == 'stock_minmax_profiles_observed' && summary.fetch('stock_only') == true &&
      summary.fetch('stock_root') == root && summary.fetch('evidence_root') == root &&
      summary.fetch('matrix_path') == matrix_path &&
      summary.fetch('stock_matrix_sha256') == Digest::SHA256.hexdigest(matrix_bytes) &&
      summary.fetch('profile_count_expected') == profiles.length && summary.fetch('stock_profile_count') == profiles.length &&
      summary.fetch('native_profile_count') == 0 && summary.fetch('coverage') == M.coverage_manifest,
      'stock summary success, root, matrix hash, or finite profile count differs')
    index = load_invocations(root)
    labels = stock_labels(profiles)
    binary = validate_clickhouse_invocations!(root, index, labels, profiles, stock_phase: true)
    compare_summary_processes!(summary, index)
    validate_runtime_pins!(summary, matrix, index, binary)
    validate_source_pins!(matrix, summary)
    validate_constructor_census!(root, matrix, profiles, index)
    validate_source_controls!(root, matrix, profiles, index)
    validate_string_legacy!(root, matrix, index)
    validate_stock_parts!(root, matrix, profiles, index)
    { 'phase' => 'stock', 'root' => root, 'profile_count' => profiles.length,
      'raw_invocation_count' => index.length, 'matrix_sha256' => Digest::SHA256.hexdigest(matrix_bytes) }
  rescue KeyError, JSON::ParserError => error
    fail!("stock evidence is malformed: #{error.message}")
  end

  def validate_helper_process!(summary, stock_root, evidence_root, generated_root, profiles, expected_helper_sha)
    helper_path = summary.fetch('helper_path')
    full_helper = File.expand_path(helper_path)
    require_true(File.file?(full_helper) && File.executable?(full_helper) && !File.symlink?(full_helper) &&
      File.realpath(full_helper) == full_helper, 'paired helper path is absent, symlinked, or noncanonical')
    helper_sha = Digest::SHA256.file(full_helper).hexdigest
    expected_helper_sha = R.validate_sha256_pin!(expected_helper_sha, 'external helper SHA-256 pin')
    require_true(helper_sha == summary.fetch('helper_sha256') && helper_sha == expected_helper_sha,
      'paired helper executable SHA differs from captured external pin')
    argv_record = json_file(File.join(evidence_root, 'helper.argv.json'), evidence_root)
    matrix_path = File.join(stock_root, 'stock-matrix.json')
    expected_argv = [full_helper, '--stock-matrix', matrix_path, '--output-root', generated_root]
    require_true(argv_record.fetch('label') == M::HELPER_LABEL && argv_record.fetch('argv') == expected_argv &&
      argv_record.fetch('timeout_seconds') == M::HELPER_TIMEOUT_SECONDS &&
      argv_record.fetch('environment') == { 'TZ' => 'UTC' }, 'raw helper argv/environment/timeout differs')
    status = json_file(File.join(evidence_root, 'helper.status.json'), evidence_root)
    stdout = read_file(File.join(evidence_root, 'helper.stdout'), evidence_root)
    stderr = read_file(File.join(evidence_root, 'helper.stderr'), evidence_root)
    require_true(status.fetch('label') == M::HELPER_LABEL && status.fetch('classification') == 'process_success' &&
      status.fetch('exitstatus') == 0 && !status.fetch('signaled') && !status.fetch('timed_out') &&
      status.fetch('spawn_error').nil? && status.fetch('stdout_bytes') == stdout.bytesize &&
      status.fetch('stderr_bytes') == stderr.bytesize &&
      Digest::SHA256.hexdigest(stdout) == summary.fetch('helper_stdout_sha256'),
      'raw helper status or captured stdout hash differs')
    process = summary.fetch('helper_process')
    %w[label classification exitstatus signaled termsig timed_out duration_ms spawn_error stdout_bytes stderr_bytes].each do |field|
      require_true(process[field] == status[field], "summary/raw helper process status differs: #{field}")
    end
    output = JSON.parse(stdout.force_encoding(Encoding::UTF_8))
    require_true(output.fetch('format') == M::HELPER_FORMAT && output.fetch('profile_count') == profiles.length &&
      output.fetch('profiles').length == profiles.length,
      'helper stdout is not the expected W237 JSON/profile count')
    output.fetch('profiles').each_with_index do |record, index|
      profile = profiles.fetch(index)
      expected_stock = profile.fetch('stock_path')
      expected_library = File.join(generated_root, 'generated', profile.fetch('id'), 'all_1_1_0')
      require_true(record.fetch('id') == profile.fetch('id') &&
        record.fetch('declared_type') == profile.fetch('declared_type') &&
        File.expand_path(record.fetch('stock_part_path')) == expected_stock &&
        File.expand_path(record.fetch('library_part_path')) == expected_library,
        "helper stdout profile identity/path differs: #{profile.fetch('id')}")
      profile['library_path'] = expected_library
      profile['helper_record'] = record
      profile['library_inventory'] = inventory(expected_library)
    end
    [output, stdout]
  rescue KeyError, JSON::ParserError => error
    fail!("helper process evidence is malformed: #{error.message}")
  end

  def validate_paired!(stock_root_path, evidence_path, generated_path, expected_helper_sha)
    stock_root = canonical_root(stock_root_path, M::STOCK_PREFIX, 'paired stock root')
    evidence_root = canonical_root(evidence_path, M::EVIDENCE_PREFIX, 'paired evidence root')
    generated_root = canonical_root(generated_path, M::GENERATED_PREFIX, 'generated root')
    matrix_bytes = read_file(File.join(stock_root, 'stock-matrix.json'), stock_root)
    matrix = JSON.parse(matrix_bytes.force_encoding(Encoding::UTF_8))
    profiles = M.profiles
    stock_profile_roster(matrix, profiles, stock_root)
    summary = json_file(File.join(evidence_root, 'summary.json'), evidence_root)
    require_true(summary.fetch('format') == M::SUMMARY_FORMAT && summary.fetch('success') == true &&
      summary.fetch('classification') == 'paired_minmax_profiles_observed' && summary.fetch('stock_only') == false &&
      summary.fetch('stock_root') == stock_root && summary.fetch('evidence_root') == evidence_root &&
      summary.fetch('generated_root') == generated_root && summary.fetch('matrix_path') == File.join(stock_root, 'stock-matrix.json') &&
      summary.fetch('stock_matrix_sha256') == Digest::SHA256.hexdigest(matrix_bytes) &&
      summary.fetch('profile_count_expected') == profiles.length && summary.fetch('native_profile_count') == profiles.length,
      'paired summary phase/root/stock matrix hash/profile count differs')
    helper_output, = validate_helper_process!(summary, stock_root, evidence_root, generated_root,
      profiles, expected_helper_sha)
    index = load_invocations(evidence_root)
    binary = validate_clickhouse_invocations!(evidence_root, index, paired_labels, profiles,
      stock_phase: false, generated_profiles: helper_output.fetch('profiles'))
    compare_summary_processes!(summary, index)
    validate_runtime_pins!(summary, matrix, index, binary)
    validate_source_pins!(matrix, summary)
    validate_stock_parts!(stock_root, matrix, profiles, load_invocations(stock_root))
    native_capture = index.fetch('native-capture-all').fetch('stdout')
    native_create = index.fetch('native-create-all').fetch('stdout')
    native_matrix = json_file(File.join(evidence_root, 'cases', 'native-matrix.json'), evidence_root)
    require_true(native_matrix.fetch('format') == 'aggregate_minmax_w237_native_v1' &&
      native_matrix.fetch('profile_count') == profiles.length && native_matrix.fetch('profiles').length == profiles.length,
      'paired native matrix format/profile count differs')
    native_processes = native_matrix.fetch('processes')
    require_true(native_processes.keys.sort == %w[attach capture create],
      'paired native process witness roster differs')
    { 'create' => 'native-create-all', 'attach' => 'native-attach-all',
      'capture' => 'native-capture-all' }.each do |key, label|
      require_true(native_processes.fetch(key) == index.fetch(label).fetch('status'),
        "native matrix process witness differs from raw status sidecar: #{label}")
    end
    native_store = File.join(evidence_root, 'stores', 'native')
    require_true(File.directory?(native_store) && !File.symlink?(native_store) &&
      File.realpath(native_store) == native_store,
      'isolated native store is absent or noncanonical')
    profiles.each_with_index do |profile, index_in_roster|
      id = profile.fetch('id')
      helper_record = helper_output.fetch('profiles').fetch(index_in_roster)
      native_record = native_matrix.fetch('profiles').fetch(index_in_roster)
      expected_library_inventory = profile.fetch('library_inventory')
      expected_native_keys = %w[attached_inventory attached_inventory_delta attached_part_path check_output
        declared_type detached_inventory_before_attach detached_part_path id library_inventory_after_attach
        library_inventory_before_attach library_part_path native_data_path part_census rowbinary_windows
        schema stock_part_path]
      require_true(native_record.keys.sort == expected_native_keys.sort,
        "native matrix profile schema differs: #{id}")
      require_true(native_record.fetch('id') == id && native_record.fetch('declared_type') == profile.fetch('declared_type') &&
        native_record.fetch('stock_part_path') == profile.fetch('stock_path') &&
        native_record.fetch('library_part_path') == profile.fetch('library_path') &&
        native_record.fetch('library_inventory_before_attach') == expected_library_inventory &&
        native_record.fetch('library_inventory_after_attach') == expected_library_inventory,
        "native/helper recorded path or source-file preservation differs: #{id}")
      actual_library_inventory = inventory(profile.fetch('library_path'))
      require_true(actual_library_inventory == expected_library_inventory,
        "helper part files changed after ATTACH or differ from raw inventory: #{id}")
      data_path_body = marker_section(native_create, "W237_NATIVE_DATA_PATH_BEGIN_#{id}",
        "W237_NATIVE_DATA_PATH_END_#{id}", "native table data path #{id}")
      data_path_rows = data_path_body.lines.map(&:chomp)
      require_true(data_path_rows.length == 1 && !data_path_rows.first.empty? &&
        !data_path_rows.first.include?("\t"),
        "raw native system.tables.data_paths result is malformed: #{id}")
      native_data_path = File.expand_path(data_path_rows.first)
      require_true(native_data_path.start_with?(native_store + File::SEPARATOR) &&
        File.directory?(native_data_path) && !File.symlink?(native_data_path) &&
        File.realpath(native_data_path) == native_data_path &&
        native_record.fetch('native_data_path') == native_data_path,
        "raw system.tables.data_paths escaped or differs from recorded native lineage: #{id}")
      detached_dir = File.join(native_data_path, 'detached')
      detached_path = File.join(detached_dir, 'all_1_1_0')
      require_true(File.directory?(detached_dir) && !File.symlink?(detached_dir) &&
        File.realpath(detached_dir) == detached_dir && !File.exist?(detached_path) &&
        !File.symlink?(detached_path) && native_record.fetch('detached_part_path') == detached_path &&
        native_record.fetch('detached_inventory_before_attach') == expected_library_inventory,
        "native detached-part lineage or pre-ATTACH inventory differs: #{id}")
      check = marker_section(native_capture, "W237_NATIVE_CHECK_BEGIN_#{id}", "W237_NATIVE_CHECK_END_#{id}", "native CHECK #{id}")
      require_true(check == EXPECTED_CHECK && native_record.fetch('check_output') == check,
        "native CHECK result is not exact clean success: #{id}")
      schema = marker_section(native_capture, "W237_NATIVE_SCHEMA_BEGIN_#{id}", "W237_NATIVE_SCHEMA_END_#{id}", "native schema #{id}")
      schema_rows = schema.lines.map(&:chomp)
      require_true(schema_rows == ["pk\tUInt64", "v\t#{profile.fetch('declared_type')}"] &&
        native_record.fetch('schema') == schema_rows, "native schema differs after ATTACH: #{id}")
      part_body = marker_section(native_capture, "W237_NATIVE_PART_BEGIN_#{id}", "W237_NATIVE_PART_END_#{id}", "native part #{id}")
      part_rows = part_body.lines.map(&:chomp)
      require_true(part_rows.length == 1, "native part census row cardinality differs: #{id}")
      fields = part_rows.first.split("\t", -1)
      require_true(fields.length == 5 && fields.first(4) == ['all_1_1_0', '5', '4', 'Wide'] &&
        native_record.fetch('part_census') == fields,
        "native attached part name/grid/type differs: #{id}")
      attached_path = File.expand_path(fields.fetch(4))
      expected_attached_path = File.join(native_data_path, 'all_1_1_0')
      require_true(attached_path == expected_attached_path &&
        attached_path.start_with?(native_store + File::SEPARATOR) &&
        File.directory?(attached_path) && !File.symlink?(attached_path) &&
        File.realpath(attached_path) == attached_path &&
        native_record.fetch('attached_part_path') == attached_path,
        "raw system.parts path does not match observed data_paths/ATTACH lineage: #{id}")
      attached_inventory = inventory(attached_path)
      source_by_path = expected_library_inventory.to_h { |item| [item.fetch('path'), item] }
      attached_by_path = attached_inventory.to_h { |item| [item.fetch('path'), item] }
      removed = (source_by_path.keys - attached_by_path.keys).sort
      changed = source_by_path.keys.select do |path|
        attached_by_path.key?(path) && source_by_path.fetch(path) != attached_by_path.fetch(path)
      end.sort
      added = (attached_by_path.keys - source_by_path.keys).sort
      require_true(removed.empty? && changed.empty? && [[], [M::INVALIDATED_FILE]].include?(added) &&
        native_record.fetch('attached_inventory') == attached_inventory &&
        native_record.fetch('attached_inventory_delta') == {
          'removed' => removed, 'changed' => changed, 'added' => added
        }, "attached inventory differs from generated files beyond the established optional system-columns file: #{id}")
      if added == [M::INVALIDATED_FILE]
        invalidated = File.binread(File.join(attached_path, M::INVALIDATED_FILE))
        require_true(["_block_number\n_block_offset\n", "_block_offset\n_block_number\n"].include?(invalidated),
          "attached invalidated-system-columns bytes are not one exact native NameSet permutation: #{id}")
      end
      validate_rowbinary_windows!(evidence_root, profile, native_record.fetch('rowbinary_windows'), 'native-rowbinary')
      require_true(helper_record.fetch('stock_part_path') == profile.fetch('stock_path'),
        "helper consumed unexpected stock part path: #{id}")
    end
    { 'phase' => 'paired', 'stock_root' => stock_root, 'evidence_root' => evidence_root,
      'generated_root' => generated_root, 'profile_count' => profiles.length,
      'raw_invocation_count' => index.length, 'helper_stdout_sha256' => Digest::SHA256.hexdigest(File.binread(File.join(evidence_root, 'helper.stdout'))),
      'stock_matrix_sha256' => Digest::SHA256.hexdigest(matrix_bytes) }
  rescue KeyError, JSON::ParserError => error
    fail!("paired evidence is malformed: #{error.message}")
  end

  def main(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = <<~USAGE
        Usage:
          ruby scripts/check_aggregate_minmax_evidence_w237.rb --stock-root STOCK_ROOT
          ruby scripts/check_aggregate_minmax_evidence_w237.rb --stock-root STOCK_ROOT --paired-root EVIDENCE_ROOT --generated-root GENERATED_ROOT --helper-sha256 HEX
      USAGE
      opts.on('--stock-root PATH') { |value| options[:stock_root] = value }
      opts.on('--paired-root PATH') { |value| options[:paired_root] = value }
      opts.on('--generated-root PATH') { |value| options[:generated_root] = value }
      opts.on('--helper-sha256 HEX') { |value| options[:helper_sha256] = value }
    end
    parser.parse!(argv)
    require_true(argv.empty? && options[:stock_root], parser.to_s)
    if options[:paired_root] || options[:generated_root]
      require_true(options[:paired_root] && options[:generated_root] && options[:helper_sha256], parser.to_s)
      result = validate_stock!(options.fetch(:stock_root))
      result['paired'] = validate_paired!(options.fetch(:stock_root), options.fetch(:paired_root),
        options.fetch(:generated_root), options.fetch(:helper_sha256))
    else
      require_true(!options[:helper_sha256], parser.to_s)
      result = validate_stock!(options.fetch(:stock_root))
    end
    puts JSON.pretty_generate({ 'format' => 'aggregate_minmax_w237_audit_v1', 'success' => true }.merge(result))
    true
  rescue StandardError => error
    warn "W237 evidence audit failed: #{error.class}: #{error.message}"
    false
  end
end

exit(CheckAggregateMinmaxEvidenceW237.main(ARGV) ? 0 : 1) if $PROGRAM_NAME == __FILE__
