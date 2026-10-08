#!/usr/bin/env ruby
# Read-only structural and literal audit for a completed W224 paired probe.

require 'digest'
require 'find'
require 'json'
require_relative 'recheck_aggregate_recursive_w224'

module CheckAggregateRecursiveEvidenceW224
  extend self

  R = RecheckAggregateRecursiveW224
  STRING_VERSIONS = { 'single_stream' => 0, 'with_size_stream' => 1 }.freeze
  EXPECTED_CHECK = "all_1_1_0\t1\t\n".freeze
  INVALIDATED_FILE = 'invalidated_system_columns.txt'.freeze
  INVALIDATED_NAMES = %w[_block_number _block_offset].freeze

  def fail!(message)
    raise ArgumentError, message
  end

  def validate_sha256_pin!(value, label)
    require_true(value.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(value),
      "#{label} must be exactly 64 lowercase hexadecimal characters")
    value
  end

  def require_true(condition, message)
    fail!(message) unless condition
  end

  def read_file(path, root = nil)
    full = File.expand_path(path)
    require_true(File.file?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "missing, symlinked, or noncanonical evidence file: #{full}")
    if root
      prefix = File.realpath(root) + File::SEPARATOR
      require_true(full.start_with?(prefix), "evidence path escaped its root: #{full}")
    end
    File.binread(full)
  end

  def json_file(path, root = nil)
    JSON.parse(read_file(path, root).force_encoding(Encoding::UTF_8))
  rescue JSON::ParserError => error
    fail!("invalid JSON evidence #{path}: #{error.message}")
  end

  def canonical_root(path, prefix, label)
    full = File.expand_path(path)
    require_true(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "#{label} is absent, symlinked, or noncanonical")
    require_true(File.dirname(full) == File.realpath('/private/tmp') && full.start_with?(prefix),
      "#{label} is outside its fixed direct-child /private/tmp prefix")
    full
  end

  def inventory(part)
    full = File.expand_path(part)
    require_true(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "part is absent, symlinked, or noncanonical: #{full}")
    rows = []
    Find.find(full) do |path|
      next if path == full
      require_true(!File.symlink?(path), "part contains symlink: #{path}")
      next if File.directory?(path)
      require_true(File.file?(path), "part contains non-file entry: #{path}")
      rows << { 'path' => path[(full.length + 1)..-1], 'size' => File.size(path),
        'sha256' => Digest::SHA256.file(path).hexdigest }
    end
    rows.sort_by { |row| row.fetch('path') }
  end

  def diagnostic_messages(stdout, stderr)
    (stdout + stderr).lines.each_with_object([]) do |line, messages|
      match = /\ACode: [0-9]+\. DB::Exception: (.*?)(?:\r?\n)?\z/.match(line)
      next unless match
      message = match[1].sub(/\s+\([A-Z_]+\)(?:\s+\(version [^)]+\))?\z/, '')
      messages << message.sub(/\.\z/, '')
    end
  end

  def expected_labels(profiles)
    labels = %w[runtime-version-pin runtime-build-pin generic-stock-read-library-write-read
      constructor-nullable-aggregate-function constructor-low-cardinality-aggregate-function
      constructor-map-aggregate-function-key]
    profiles.each do |profile|
      id = profile.fetch('id')
      labels.concat(R.stock_process_labels(id))
      labels.concat(%W[native-create-#{id} native-data-path-#{id} native-attach-#{id} native-check-#{id}
        native-metadata-#{id} native-part-#{id} native-type-name-#{id}
        native-rowbinary-#{id}-full native-rowbinary-#{id}-middle native-rowbinary-#{id}-empty])
    end
    labels
  end

  def invocation_index(root)
    index = {}
    paths = Dir.glob(File.join(root, 'invocations', '*.argv.json')).sort
    paths.each do |argv_path|
      argv_record = json_file(argv_path, root)
      label = argv_record.fetch('label')
      require_true(!index.key?(label), "duplicate raw invocation label: #{label}")
      base = argv_path.sub(/\.argv\.json\z/, '')
      status_path = base + '.status.json'
      stdout_path = base + '.stdout'
      stderr_path = base + '.stderr'
      sql_path = base + '.sql'
      stdin_path = base + '.stdin.bin'
      status = json_file(status_path, root)
      stdout = read_file(stdout_path, root)
      stderr = read_file(stderr_path, root)
      sql = read_file(sql_path, root)
      require_true(status.fetch('stdout_bytes') == stdout.bytesize && status.fetch('stderr_bytes') == stderr.bytesize,
        "raw process byte counts differ: #{label}")
      stdin_bytes = argv_record['stdin_bytes']
      if stdin_bytes.nil?
        require_true(!File.exist?(stdin_path) && !File.symlink?(stdin_path) && argv_record['stdin_sha256'].nil?,
          "unexpected raw stdin sidecar: #{label}")
        stdin = nil
      else
        stdin = read_file(stdin_path, root)
        require_true(stdin.bytesize == stdin_bytes && Digest::SHA256.hexdigest(stdin) == argv_record.fetch('stdin_sha256'),
          "raw stdin bytes/hash differ: #{label}")
      end
      index[label] = { 'argv_record' => argv_record, 'status' => status, 'stdout' => stdout,
        'stderr' => stderr, 'sql' => sql, 'stdin' => stdin, 'base' => base }
    end
    index
  end

  def assert_process_statuses!(invocations, expected)
    actual = invocations.keys.sort
    require_true(actual == expected.sort, "raw invocation label roster differs (wanted #{expected.length}, saw #{actual.length})")
    invocations.each do |label, record|
      status = record.fetch('status')
      if label == 'constructor-nullable-aggregate-function' || label == 'constructor-low-cardinality-aggregate-function'
        require_true(status.fetch('classification') == 'process_nonzero_or_signaled_exit' &&
          status.fetch('exitstatus') && status.fetch('exitstatus').positive? && !status.fetch('signaled') &&
          !status.fetch('timed_out') && !status.fetch('spawn_error'),
          "source-predicted constructor refusal has wrong raw process status: #{label}")
      elsif label == 'constructor-map-aggregate-function-key'
        next
      else
        require_true(status.fetch('classification') == 'process_success' && status['exitstatus'] == 0 &&
          !status.fetch('signaled') && !status.fetch('timed_out') && !status.fetch('spawn_error'),
          "unexpected process failure (not a semantic refusal): #{label}")
      end
    end
  end

  def assert_sql!(record, sql, label)
    require_true(record.fetch('sql') == (sql.end_with?("\n") ? sql : sql + "\n") &&
      record.fetch('argv_record').fetch('argv').last == sql.sub(/\n\z/, ''),
      "recorded SQL/argv differs: #{label}")
  end

  def expected_create_sql(profile, table)
    mode = profile.fetch('profile')
    require_true(STRING_VERSIONS.key?(mode), "unlisted DDL String serialization profile: #{mode}")
    settings = R::STOCK_SETTINGS + ["string_serialization_version='#{mode}'"]
    "CREATE TABLE default.#{table} (pk UInt64, v #{profile.fetch('declared_type')}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings.join(', ')}"
  end

  def validate_clickhouse_argv!(invocations, binary, root, source_root)
    invocations.each do |label, record|
      next if label == 'generic-stock-read-library-write-read'
      argv_record = record.fetch('argv_record')
      sql = record.fetch('sql')
      require_true(argv_record.fetch('environment') == { 'TZ' => 'UTC' } &&
        argv_record.fetch('timeout_seconds') == R::PROCESS_TIMEOUT_SECONDS,
        "runtime environment/timeout differs: #{label}")
      require_true(sql.end_with?("\n") && sql.bytesize > 1, "runtime SQL sidecar is empty: #{label}")
      query = sql.sub(/\n\z/, '')
      store = argv_record.fetch('argv').fetch(3)
      allowed = [File.join(source_root, 'stores') + File::SEPARATOR,
        File.join(root, 'stores') + File::SEPARATOR]
      require_true(allowed.any? { |prefix| store.start_with?(prefix) } && File.directory?(store) &&
        !File.symlink?(store) && File.realpath(store) == store,
        "ClickHouse store escaped evidence roots: #{label}")
      expected = [binary, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
        '--max_insert_threads=1', '--max_execution_time=30', "--max_memory_usage=#{R::MEMORY_LIMIT_BYTES}",
        '--print_pretty_type_names=0',
        '--multiquery', '--query', query]
      require_true(argv_record.fetch('argv') == expected, "ClickHouse argv/options differ: #{label}")
    end
  end

  def validate_constructor_cases!(source_root, invocations)
    nullable = json_file(File.join(source_root, 'cases', 'construction', 'nullable_aggregate_function.json'), source_root)
    low_cardinality = json_file(File.join(source_root, 'cases', 'construction', 'low_cardinality_aggregate_function.json'), source_root)
    cases = [
      [nullable, 'constructor-nullable-aggregate-function', 'Nested type AggregateFunction(sum, UInt8) cannot be inside Nullable type', 'src/DataTypes/DataTypeNullable.cpp:29-34'],
      [low_cardinality, 'constructor-low-cardinality-aggregate-function', 'DataTypeLowCardinality is supported only for numbers, strings, Date or DateTime, but got AggregateFunction(sum, UInt8)', 'src/DataTypes/DataTypeLowCardinality.cpp:30-40; src/DataTypes/IDataType.h:373-374'],
    ]
    cases.each do |record, label, expected, anchor|
      process = invocations.fetch(label)
      sql = case label
            when 'constructor-nullable-aggregate-function'
              'CREATE TABLE default.w224_refused_nullable_af (v Nullable(AggregateFunction(sum, UInt8))) ENGINE=Memory'
            when 'constructor-low-cardinality-aggregate-function'
              'CREATE TABLE default.w224_refused_low_cardinality_af (v LowCardinality(AggregateFunction(sum, UInt8))) ENGINE=Memory'
            end
      assert_sql!(process, sql, label)
      messages = diagnostic_messages(process.fetch('stdout'), process.fetch('stderr'))
      require_true(record.fetch('classification') == 'expected_semantic_refusal' &&
        record.fetch('expected_diagnostic') == expected && record.fetch('observed_diagnostics') == [expected] &&
        record.fetch('source_anchor') == anchor && messages == [expected],
        "constructor refusal evidence differs: #{label}")
      raw = record.fetch('process')
      require_true(raw.fetch('classification') == 'expected_semantic_refusal' && raw.fetch('exitstatus').positive? &&
        raw.fetch('exitstatus') == process.fetch('status').fetch('exitstatus'),
        "constructor semantic result disagrees with raw status: #{label}")
    end

    map_case = json_file(File.join(source_root, 'cases', 'construction', 'map_aggregate_function_key.json'), source_root)
    map_process = invocations.fetch('constructor-map-aggregate-function-key')
    assert_sql!(map_process,
      'CREATE TABLE default.w224_map_af_key (v Map(AggregateFunction(sum, UInt8), UInt8)) ENGINE=Memory',
      'constructor-map-aggregate-function-key')
    require_true(map_case.fetch('source_anchor') == 'src/DataTypes/DataTypeMap.cpp:88-92,152-154' &&
      map_case.fetch('admission_policy').include?('candidate guard only'), 'Map(AF key) source/guard note differs')
    case map_case.fetch('classification')
    when 'source_constructor_acceptance_observed'
      require_true(map_process.fetch('status').fetch('classification') == 'process_success' &&
        map_case.fetch('observed_diagnostics').empty?, 'Map(AF key) acceptance does not match process status')
    when 'runtime_constructor_refusal_observed'
      require_true(map_process.fetch('status').fetch('classification') == 'process_nonzero_or_signaled_exit' &&
        map_process.fetch('status').fetch('exitstatus').positive? && !map_process.fetch('status').fetch('signaled') &&
        !map_process.fetch('status').fetch('timed_out') && !map_process.fetch('status').fetch('spawn_error') &&
        map_case.fetch('observed_diagnostics') == diagnostic_messages(map_process.fetch('stdout'), map_process.fetch('stderr')) &&
        !map_case.fetch('observed_diagnostics').empty?, 'Map(AF key) refusal lacks the observed raw diagnostic/status')
    else
      fail!("unrecognized Map(AF key) observation: #{map_case.fetch('classification')}")
    end
    map_case
  end

  def assert_lanes!(actual, expected, label)
    require_true(actual == expected, "#{label} independent lane bytes or mark offsets differ")
  end

  def assert_part_census!(stdout, expected_path, label)
    rows = stdout.split("\n", -1)
    require_true(rows.length == 2 && rows.last.empty?, "raw #{label} part census row shape differs")
    fields = rows.first.split("\t", -1)
    require_true(fields.length == 5 && fields.first(4) == ['all_1_1_0', '5', '4', 'Wide'],
      "raw #{label} part census fields differ")
    path = fields.fetch(4)
    require_true([expected_path, expected_path + File::SEPARATOR].include?(path) &&
      File.realpath(path) == expected_path,
      "raw #{label} part census path differs from canonical path or its single trailing separator")
  end

  def validate_source_profiles!(source_root, matrix, profiles, invocations)
    observed = matrix.fetch('profiles')
    require_true(observed.map { |item| item.fetch('id') } == profiles.map { |item| item.fetch('id') },
      'source matrix profile roster/order differs')
    profiles.each_with_index do |profile, index|
      item = observed.fetch(index)
      id = profile.fetch('id')
      requested = profile.fetch('declared_type')
      source_type = item.fetch('source_type')
      classification = item.fetch('classification')
      canonicalization = item.fetch('physical').fetch('canonicalization')
      allowed_source_type = source_type == requested ||
        (id == 'nested_count_sum_flatten_nested_0' && source_type == R::NESTED_ARRAY_TYPE)
      require_true(allowed_source_type, "unlisted stock declaration/canonicalization: #{id}=#{source_type}")
      expected_classification = source_type == requested ? 'stock_physical_observed' : 'stock_canonicalization_observed_not_nominally_qualified'
      require_true(classification == expected_classification && item.fetch('physical').fetch('requested_type') == requested &&
        item.fetch('physical').fetch('to_type_name') == source_type && item.fetch('physical').fetch('columns_schema') ==
        ["pk\tUInt64", "v\t#{source_type}"], "source type/schema classification differs: #{id}")
      expected_canonicalization = source_type == requested ? 'exact_declared_type' : 'stock_declaration_differs_from_requested_nested'
      require_true(canonicalization == expected_canonicalization, "source canonicalization label differs: #{id}")
      physical = item.fetch('physical')
      require_true(physical.fetch('rows') == 5 && physical.fetch('marks_with_terminal') == 4 &&
        physical.fetch('real_mark_rows') == R::MARK_ROWS && physical.fetch('native_part_name') == 'all_1_1_0' &&
        physical.fetch('part_type') == 'Wide' && physical.fetch('default_compression_codec') == 'CODEC(LZ4)' &&
        physical.fetch('metadata_version') == '0', "source physical axes/profile differs: #{id}")
      source_part = File.expand_path(physical.fetch('source_part_path'))
      require_true(source_part.start_with?(source_root + File::SEPARATOR), "stock part escaped source root: #{id}")
      require_true(inventory(source_part) == physical.fetch('inventory'), "stock part inventory/hash differs: #{id}")
      original_part = File.expand_path(physical.fetch('original_part_path'))
      source_store = invocations.fetch("stock-create-#{id}").fetch('argv_record').fetch('argv').fetch(3)
      require_true(original_part.start_with?(source_store + File::SEPARATOR) &&
        inventory(original_part) == physical.fetch('inventory'), "original stock part path/inventory differs: #{id}")
      assert_part_census!(invocations.fetch("stock-part-#{id}").fetch('stdout'), original_part, "stock/#{id}")
      part_serialization = json_file(File.join(source_part, 'serialization.json'), source_root)
      require_true(part_serialization == physical.fetch('serialization_json'), "stock part serialization metadata differs: #{id}")
      expected_source_serialization = { 'columns' => [], 'propagate_types_serialization_versions_to_nested_types' => true,
        'types_serialization_versions' => { 'string' => STRING_VERSIONS.fetch(profile.fetch('profile')) }, 'version' => 1 }
      require_true(part_serialization == expected_source_serialization &&
        physical.fetch('string_serialization_profile') == profile.fetch('profile') &&
        physical.fetch('string_serialization_version_expected') == STRING_VERSIONS.fetch(profile.fetch('profile')) &&
        physical.fetch('string_serialization_version_observed') == part_serialization.fetch('types_serialization_versions').fetch('string'),
        "stock serialization version/profile differs: #{id}")
      require_true(File.binread(File.join(source_part, 'metadata_version.txt')).strip == '0' &&
        File.binread(File.join(source_part, 'default_compression_codec.txt')).strip == 'CODEC(LZ4)',
        "stock part metadata files differ: #{id}")

      validation = R.validate_literal_rows!(profile)
      validation_file = json_file(File.join(source_root, 'cases', 'profiles', "#{id}-literal-validation.json"), source_root)
      profile_file = json_file(File.join(source_root, 'cases', 'profiles', "#{id}.json"), source_root)
      expected_rows = R.expected_rowbinary(profile)
      expected_hex = expected_rows.map { |row| row.unpack1('H*') }
      require_true(validation_file == validation && profile_file.fetch('independent_literal_validation') == validation &&
        profile_file.fetch('validated_before_insert') == true && profile_file.fetch('literal_rowbinary_hex') == expected_hex,
        "independent RowBinary literal-vs-metadata evidence differs: #{id}")
      require_true(profile_file.fetch('check_output') == EXPECTED_CHECK && profile_file.fetch('schema') == physical.fetch('columns_schema'),
        "stock CHECK/schema evidence differs: #{id}")
      table = "w224_#{R.safe_label(id)}"
      insert = invocations.fetch("stock-insert-#{id}")
      expected_insert = R.expected_rowbinary(profile).join.b
      require_true(insert.fetch('stdin') == expected_insert && insert.fetch('argv_record').fetch('stdin_bytes') == expected_insert.bytesize &&
        insert.fetch('argv_record').fetch('stdin_sha256') == Digest::SHA256.hexdigest(expected_insert),
        "stock INSERT stdin differs from the independently validated literal rows: #{id}")
      assert_sql!(invocations.fetch("stock-create-#{id}"), expected_create_sql(profile, table),
        "stock-create-#{id}")
      assert_sql!(insert, "INSERT INTO default.#{table} FORMAT RowBinary", "stock-insert-#{id}")
      assert_sql!(invocations.fetch("stock-check-#{id}"), "CHECK TABLE default.#{table} FORMAT TSVRaw", "stock-check-#{id}")
      require_true(invocations.fetch("stock-check-#{id}").fetch('stdout') == EXPECTED_CHECK &&
        invocations.fetch("stock-metadata-#{id}").fetch('stdout').force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp) == physical.fetch('columns_schema') &&
        invocations.fetch("stock-type-name-#{id}").fetch('stdout') == "#{source_type}\n",
        "raw stock CHECK/schema/type-name command evidence differs: #{id}")
      assert_sql!(invocations.fetch("stock-metadata-#{id}"),
        "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw",
        "stock-metadata-#{id}")
      assert_sql!(invocations.fetch("stock-type-name-#{id}"),
        "SELECT toTypeName(v) FROM default.#{table} LIMIT 1 FORMAT TSVRaw", "stock-type-name-#{id}")
      assert_sql!(invocations.fetch("stock-part-#{id}"),
        "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw",
        "stock-part-#{id}")

      source_values = R.source_values_for(profile, source_type)
      source_lanes = R.expected_lanes(profile.merge('values' => source_values))
      nominal_lanes = R.expected_lanes(profile)
      assert_lanes!(profile_file.fetch('source_expected_lanes'), source_lanes, "#{id}/source")
      assert_lanes!(profile_file.fetch('expected_lanes'), nominal_lanes, "#{id}/nominal")
      assert_lanes!(physical.fetch('rowbinary_windows').transform_values { |window| window.fetch('matches_independent_literal') },
        { 'full' => true, 'middle' => true, 'empty' => true }, "#{id}/window roster")
      { 'full' => [0, 1, 2, 3, 4], 'middle' => [1, 2, 3], 'empty' => [] }.each do |window, indices|
        record = physical.fetch('rowbinary_windows').fetch(window)
        predicate = case window
                    when 'full' then ''
                    when 'middle' then ' WHERE pk BETWEEN 22 AND 44'
                    when 'empty' then ' WHERE pk=0'
                    end
        query_path = File.join(source_root, 'cases', 'profiles', "#{id}-#{window}.rowbinary")
        assert_sql!(invocations.fetch("stock-rowbinary-#{id}-#{window}"),
          "SELECT pk, v FROM default.#{table}#{predicate} ORDER BY pk INTO OUTFILE '#{query_path}' FORMAT RowBinary",
          "stock-rowbinary-#{id}-#{window}")
        bytes = read_file(record.fetch('path'), source_root)
        expected = indices.map { |row| expected_rows.fetch(row) }.join.b
        require_true(bytes == expected && record.fetch('bytes') == bytes.bytesize &&
          record.fetch('sha256') == Digest::SHA256.hexdigest(bytes), "stock #{window} RowBinary differs: #{id}")
      end
      expected_serialization = { 'columns' => [], 'propagate_types_serialization_versions_to_nested_types' => true,
        'types_serialization_versions' => { 'string' => STRING_VERSIONS.fetch(profile.fetch('profile')) }, 'version' => 1 }
      require_true(part_serialization == expected_serialization, "stock serialization contract differs: #{id}")
    end
  end

  def validate_helper_and_library!(root, source_root, profiles, invocations, summary, expected_helper_sha256)
    input_path = File.join(root, 'generated', 'helper-input.json')
    input_bytes = read_file(input_path, root)
    require_true(Digest::SHA256.hexdigest(input_bytes) == summary.fetch('helper_input_sha256'), 'helper input digest differs')
    input = JSON.parse(input_bytes.force_encoding(Encoding::UTF_8))
    output = json_file(File.join(root, 'generated', 'helper-output.json'), root)
    process = invocations.fetch('generic-stock-read-library-write-read')
    helper_path = process.fetch('argv_record').fetch('argv').first
    helper_is_canonical = File.file?(helper_path) && File.executable?(helper_path) && !File.symlink?(helper_path) &&
      File.realpath(helper_path) == helper_path
    require_true(helper_is_canonical, 'prebuilt Crystal helper path is missing, non-executable, symlinked, or noncanonical')
    helper_sha256_observed = Digest::SHA256.file(helper_path).hexdigest
    require_true(helper_sha256_observed == expected_helper_sha256 &&
      summary.fetch('helper_sha256_expected') == expected_helper_sha256 &&
      summary.fetch('helper_sha256_observed_at_start') == helper_sha256_observed &&
      summary.fetch('helper_sha256_observed_before_execute') == helper_sha256_observed &&
      summary.fetch('helper_sha256_observed_after_execute') == helper_sha256_observed,
      'prebuilt Crystal helper digest differs from external pin or recorded observations')
    require_true(input.fetch('format') == R::FORMAT_INPUT && input.fetch('capture_root') == source_root &&
        input.fetch('profiles').map { |item| item.fetch('id') } == profiles.map { |item| item.fetch('id') },
        'helper input contract/profile roster differs')
    helper_argv = process.fetch('argv_record')
    require_true(helper_argv.fetch('environment') == { 'TZ' => 'UTC' } &&
      helper_argv.fetch('timeout_seconds') == R::HELPER_TIMEOUT_SECONDS && helper_argv['stdin_bytes'].nil? &&
      helper_argv['stdin_sha256'].nil? && process.fetch('stdin').nil? && process.fetch('sql') == "\n" &&
      helper_argv.fetch('argv') == [helper_path, input_path, File.join(root, 'generated'), source_root],
      'prebuilt helper argv/environment/input contract differs')
    require_true(output.fetch('format') == R::FORMAT_HELPER && output.fetch('profile_count') == profiles.length &&
      output.fetch('observed_count') == profiles.length && output.fetch('mismatch_count') == 0 &&
      output.fetch('profiles').map { |item| item.fetch('id') } == profiles.map { |item| item.fetch('id') },
      'helper output contract/profile roster differs')
    expected_profiles = R.fixture_profiles
    output.fetch('profiles').each_with_index do |result, index|
      profile = expected_profiles.fetch(index)
      source_matrix = json_file(File.join(source_root, 'matrix.json'), source_root).fetch('profiles').fetch(index)
      expected_source_values = R.source_values_for(profile, source_matrix.fetch('source_type'))
      input_profile = input.fetch('profiles').fetch(index)
      expected_lanes = R.expected_lanes(profile)
      expected_source_lanes = R.expected_lanes(profile.merge('values' => expected_source_values))
      expected_library_part = File.join(root, 'generated', 'parts', format('%02d-%s', index, R.safe_label(profile.fetch('id'))), 'all_1_1_0')
      require_true(input_profile.fetch('declared_type') == profile.fetch('declared_type') &&
        input_profile.fetch('profile') == profile.fetch('profile') &&
        input_profile.fetch('source_type') == source_matrix.fetch('source_type') &&
        input_profile.fetch('values') == profile.fetch('values') && input_profile.fetch('source_values') == expected_source_values &&
        input_profile.fetch('expected_lanes') == expected_lanes && input_profile.fetch('source_expected_lanes') == expected_source_lanes &&
        input_profile.fetch('source_part') == source_matrix.fetch('physical').fetch('source_part_path') &&
        File.expand_path(input_profile.fetch('library_part')) == expected_library_part,
        "helper input logical values/literal lanes differ: #{profile.fetch('id')}")
      require_true(result.fetch('classification') == 'generic_stock_read_library_write_read_observed' &&
        result.fetch('declared_type') == profile.fetch('declared_type') && result.fetch('source_type') == source_matrix.fetch('source_type') &&
        result.fetch('profile') == profile.fetch('profile') &&
        result.fetch('row_keys') == R::ROW_KEYS && result.fetch('mark_rows') == R::MARK_ROWS &&
        result.fetch('source_part_path') == input_profile.fetch('source_part') &&
        File.expand_path(result.fetch('library_part_path')) == File.expand_path(input_profile.fetch('library_part')) &&
        result.fetch('independent_values') == profile.fetch('values') &&
        result.fetch('independent_lanes') == expected_lanes && result.fetch('source_independent_lanes') == expected_source_lanes,
        "helper result declaration/independent literal contract differs: #{profile.fetch('id')}")
      %w[source library].each do |side|
        reader = result.fetch(side)
        expected_type = side == 'source' ? source_matrix.fetch('source_type') : profile.fetch('declared_type')
        require_true(reader.fetch('schema_declaration') == expected_type && reader.fetch('source_declaration') == expected_type &&
          reader.fetch('row_count') == 5 && reader.fetch('mark_row_counts') == R::MARK_ROWS &&
          reader.fetch('terminal_empty_window') == true, "helper #{side} part axes/declaration differ: #{profile.fetch('id')}")
        lane_expected = side == 'source' ? expected_source_lanes : expected_lanes
        lane_rows = reader.fetch('independent_lane_bytes').map do |lane|
          [lane.fetch('role'), { 'hex' => lane.fetch('hex'), 'offsets' => lane.fetch('offsets') }]
        end.to_h
        require_true(lane_rows == lane_expected, "helper #{side} lane byte evidence differs: #{profile.fetch('id')}")
      end
      %w[source_public_scan library_public_scan].each do |key|
        schedule = [[0, 0, 2], [1, 2, 2], [2, 4, 1]]
        scan = result.fetch(key)
        require_true(scan.fetch('batch_schedule') == schedule && scan.fetch('window_rows') == 3 &&
          scan.fetch('exact_nominal_states') == true, "generic batch/window evidence differs: #{profile.fetch('id')}/#{key}")
      end
      require_true(result.fetch('offline_values').fetch('rows') == 5 && result.fetch('offline_values').fetch('window_rows') == 3 &&
        result.fetch('offline_values').fetch('exact_nominal_states') == true,
        "offline owned-values/window evidence differs: #{profile.fetch('id')}")
      library_part = File.expand_path(result.fetch('library_part_path'))
      require_true(library_part.start_with?(File.join(root, 'generated', 'parts') + File::SEPARATOR),
        "library part escaped generated evidence root: #{profile.fetch('id')}")
      attached = json_file(File.join(root, 'cases', "#{profile.fetch('id')}-attached.json"), root)
      generated_inventory = attached.fetch('generated_part_inventory')
      require_true(attached.fetch('id') == profile.fetch('id') &&
        attached.fetch('declared_type') == profile.fetch('declared_type') &&
        attached.fetch('check_output') == EXPECTED_CHECK, "native attach/check evidence differs: #{profile.fetch('id')}")
      require_true(inventory(library_part) == generated_inventory,
        "runner-recorded generated part inventory differs from helper path: #{profile.fetch('id')}")
      native_type = attached.fetch('native_type')
      nested = profile.fetch('id') == 'nested_count_sum_flatten_nested_0'
      table = "w224_#{R.safe_label(profile.fetch('id'))}"
      assert_sql!(invocations.fetch("native-create-#{profile.fetch('id')}"),
        expected_create_sql(profile, table),
        "native-create-#{profile.fetch('id')}")
      assert_sql!(invocations.fetch("native-data-path-#{profile.fetch('id')}"),
        "SELECT arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw",
        "native-data-path-#{profile.fetch('id')}")
      assert_sql!(invocations.fetch("native-attach-#{profile.fetch('id')}"),
        "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'", "native-attach-#{profile.fetch('id')}")
      assert_sql!(invocations.fetch("native-check-#{profile.fetch('id')}"),
        "CHECK TABLE default.#{table} FORMAT TSVRaw", "native-check-#{profile.fetch('id')}")
      assert_sql!(invocations.fetch("native-metadata-#{profile.fetch('id')}"),
        "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw",
        "native-metadata-#{profile.fetch('id')}")
      assert_sql!(invocations.fetch("native-part-#{profile.fetch('id')}"),
        "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw",
        "native-part-#{profile.fetch('id')}")
      assert_sql!(invocations.fetch("native-type-name-#{profile.fetch('id')}"),
        "SELECT toTypeName(v) FROM default.#{table} LIMIT 1 FORMAT TSVRaw", "native-type-name-#{profile.fetch('id')}")
      require_true(native_type == profile.fetch('declared_type') || (nested && native_type == R::NESTED_ARRAY_TYPE),
        "unlisted native attached type/canonicalization: #{profile.fetch('id')}=#{native_type}")
      expected_native_class = native_type == profile.fetch('declared_type') ? 'native_attached_and_check_observed' :
        'native_attached_with_canonicalization_observed_not_nominally_qualified'
      require_true(attached.fetch('classification') == expected_native_class &&
        attached.fetch('native_schema') == ["pk\tUInt64", "v\t#{native_type}"],
        "native canonicalization classification/schema differs: #{profile.fetch('id')}")

      native_data = invocations.fetch("native-data-path-#{profile.fetch('id')}").fetch('stdout').force_encoding(Encoding::UTF_8).strip
      attached_part = File.join(native_data, 'all_1_1_0')
      native_store = invocations.fetch("native-create-#{profile.fetch('id')}").fetch('argv_record').fetch('argv').fetch(3)
      require_true(native_data.start_with?(native_store + File::SEPARATOR),
        "native table data path escaped its isolated store: #{profile.fetch('id')}")
      require_true(attached_part.start_with?(File.join(root, 'stores', 'native') + File::SEPARATOR) &&
        inventory(attached_part) == attached.fetch('attached_part_inventory'),
        "native attached part path/inventory differs: #{profile.fetch('id')}")
      assert_part_census!(invocations.fetch("native-part-#{profile.fetch('id')}").fetch('stdout'), attached_part,
        "native/#{profile.fetch('id')}")
      require_true(attached.fetch('removed_paths').empty? && attached.fetch('changed_paths').empty? &&
        attached.fetch('added_paths') == [INVALIDATED_FILE], "native ATTACH file delta differs: #{profile.fetch('id')}")
      attached_file_set = attached.fetch('attached_part_inventory').map { |entry| entry.fetch('path') }
      require_true(attached_file_set.sort == (generated_inventory.map { |entry| entry.fetch('path') } + [INVALIDATED_FILE]).sort,
        "native ATTACH file roster differs: #{profile.fetch('id')}")
      aux = read_file(File.join(attached_part, INVALIDATED_FILE), root).split("\n", -1)
      require_true(aux.pop == '' && aux.sort == INVALIDATED_NAMES.sort, "native ATTACH auxiliary file differs: #{profile.fetch('id')}")
      columns = read_file(File.join(attached_part, 'columns.txt'), root).force_encoding(Encoding::UTF_8)
      expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`v` #{profile.fetch('declared_type')}\n"
      require_true(columns == expected_columns && attached.fetch('columns_txt') == expected_columns,
        "library part nominal columns.txt differs: #{profile.fetch('id')}")
      serialization = json_file(File.join(attached_part, 'serialization.json'), root)
      expected_library_serialization = { 'columns' => [{ 'exact_num_defaults' => true, 'kind' => 'Default', 'name' => 'pk', 'num_defaults' => 0, 'num_rows' => 5 }],
        'propagate_types_serialization_versions_to_nested_types' => true,
        'types_serialization_versions' => { 'string' => STRING_VERSIONS.fetch(profile.fetch('profile')) }, 'version' => 1 }
      require_true(attached.fetch('string_serialization_profile') == profile.fetch('profile') &&
        attached.fetch('string_serialization_version_expected') == STRING_VERSIONS.fetch(profile.fetch('profile')) &&
        attached.fetch('string_serialization_version_observed') == serialization.fetch('types_serialization_versions').fetch('string'),
        "native attached serialization version/profile differs: #{profile.fetch('id')}")
      require_true(serialization == expected_library_serialization && attached.fetch('serialization_json') == expected_library_serialization &&
        attached.fetch('metadata_version') == '0' && attached.fetch('codec') == 'CODEC(LZ4)',
        "library attached part metadata differs: #{profile.fetch('id')}")
      require_true(File.binread(File.join(attached_part, 'metadata_version.txt')).strip == '0' &&
        File.binread(File.join(attached_part, 'default_compression_codec.txt')).strip == 'CODEC(LZ4)' &&
        File.binread(File.join(attached_part, 'count.txt')).strip == '5',
        "library attached part physical metadata files differ: #{profile.fetch('id')}")
      require_true(invocations.fetch("native-check-#{profile.fetch('id')}").fetch('stdout') == EXPECTED_CHECK &&
        invocations.fetch("native-metadata-#{profile.fetch('id')}").fetch('stdout').force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp) == attached.fetch('native_schema') &&
        invocations.fetch("native-type-name-#{profile.fetch('id')}").fetch('stdout') == "#{native_type}\n",
        "raw native CHECK/schema/type-name command evidence differs: #{profile.fetch('id')}")
      expected_windows = { 'full' => [0, 1, 2, 3, 4], 'middle' => [1, 2, 3], 'empty' => [] }
      expected_windows.each do |window, indices|
        record = attached.fetch('rowbinary_windows').fetch(window)
        predicate = case window
                    when 'full' then ''
                    when 'middle' then ' WHERE pk BETWEEN 22 AND 44'
                    when 'empty' then ' WHERE pk=0'
                    end
        output_path = File.join(root, 'cases', "#{profile.fetch('id')}-#{window}.rowbinary")
        assert_sql!(invocations.fetch("native-rowbinary-#{profile.fetch('id')}-#{window}"),
          "SELECT pk, v FROM default.#{table}#{predicate} ORDER BY pk INTO OUTFILE '#{output_path}' FORMAT RowBinary",
          "native-rowbinary-#{profile.fetch('id')}-#{window}")
        bytes = read_file(record.fetch('path'), root)
        expected = indices.map { |row| R.expected_rowbinary(profile).fetch(row) }.join.b
        require_true(bytes == expected && record.fetch('matches_independent_literal') == true &&
          record.fetch('bytes') == bytes.bytesize && record.fetch('sha256') == Digest::SHA256.hexdigest(bytes),
          "library native #{window} RowBinary differs: #{profile.fetch('id')}")
      end
    end
    true
  end

  def audit(root_path, expected_helper_sha256)
    expected_helper_sha256 = validate_sha256_pin!(expected_helper_sha256, 'expected helper SHA-256')
    root = canonical_root(root_path, R::EVIDENCE_PREFIX, 'W224 evidence root')
    summary = json_file(File.join(root, 'summary.json'), root)
    require_true(summary.fetch('format') == 'aggregate_recursive_w224_summary_v1' &&
      summary.fetch('classification') == 'paired_recursive_profiles_observed' && summary.fetch('success') == true &&
      summary['error'].nil? && File.realpath(summary.fetch('evidence_root')) == root,
      'runner summary is not a successful paired observation')
    source_root = canonical_root(summary.fetch('source_root'), R::SOURCE_PREFIX, 'stock source root')
    matrix_path = File.join(source_root, 'matrix.json')
    matrix_bytes = read_file(matrix_path, source_root)
    require_true(Digest::SHA256.hexdigest(matrix_bytes) == summary.fetch('source_matrix_sha256'), 'stock matrix digest differs from summary')
    matrix = JSON.parse(matrix_bytes.force_encoding(Encoding::UTF_8))
    require_true(matrix.fetch('format') == R::FORMAT_SOURCE && matrix.fetch('case_count') == 9 &&
      matrix.fetch('nested_canonicalization_is_not_nominal_qualification') == true &&
      matrix.fetch('source_observed_count') == 9 &&
      matrix.fetch('source_pin').fetch('runtime_built_from_this_source_not_asserted') == true,
      'source matrix format/scope differs')
    source_pin = matrix.fetch('source_pin')
    require_true(source_pin.fetch('source_reference') == "#{R::SOURCE_ROOT}@#{R::SOURCE_REVISION}" &&
      source_pin.fetch('runtime_built_from_this_source_not_asserted') == true &&
      source_pin.fetch('file_hashes').all? { |item| item.fetch('matches') && item.fetch('expected_sha256') == item.fetch('actual_sha256') },
      'pinned source evidence/correlation boundary differs')
    current_pin = R.pin_source!
    require_true(current_pin.fetch('file_hashes') == source_pin.fetch('file_hashes'), 'current pinned source hashes differ from captured matrix')
    runtime_pin = json_file(File.join(source_root, 'runtime_pin.json'), source_root)
    require_true(runtime_pin == summary.fetch('runtime_pin') && runtime_pin == matrix.fetch('runtime_pin') &&
      runtime_pin.fetch('version') == R::VERSION && runtime_pin.fetch('build_hash') == R::BUILD_HASH &&
      runtime_pin.fetch('sha256') == R::RUNTIME_SHA256 && runtime_pin.fetch('runtime_source_correlation') == 'not_asserted',
      'runtime pin or source/runtime distinction differs')

    profiles = R.fixture_profiles
    invocations = invocation_index(root)
    assert_process_statuses!(invocations, expected_labels(profiles))
    version = invocations.fetch('runtime-version-pin')
    build = invocations.fetch('runtime-build-pin')
    require_true(version.fetch('stdout').strip == R::VERSION &&
      build.fetch('stdout').strip == "VERSION_GITHASH=#{R::BUILD_HASH}", 'runtime pin query outputs differ')
    binary = version.fetch('argv_record').fetch('argv').first
    require_true(File.file?(binary) && File.executable?(binary) && !File.symlink?(binary) &&
      File.realpath(binary) == binary && Digest::SHA256.file(binary).hexdigest == R::RUNTIME_SHA256,
      'pinned runtime binary path/hash differs')
    assert_sql!(version, 'SELECT version() FORMAT TSVRaw', 'runtime-version-pin')
    assert_sql!(build,
      "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw",
      'runtime-build-pin')
    constructor_map = validate_constructor_cases!(source_root, invocations)
    validate_clickhouse_argv!(invocations, binary, root, source_root)
    validate_source_profiles!(source_root, matrix, profiles, invocations)
    validate_helper_and_library!(root, source_root, profiles, invocations, summary, expected_helper_sha256)

    construction_count = matrix.fetch('construction_cases').length
    stock_exact = profiles.count { |profile| matrix.fetch('profiles').find { |item| item.fetch('id') == profile.fetch('id') }.fetch('classification') == 'stock_physical_observed' }
    stock_canonical = profiles.length - stock_exact
    attached = profiles.map { |profile| json_file(File.join(root, 'cases', "#{profile.fetch('id')}-attached.json"), root) }
    native_exact = attached.count { |item| item.fetch('classification') == 'native_attached_and_check_observed' }
    native_canonical = attached.length - native_exact
    counts = summary.fetch('counts')
    require_true(construction_count == 3 && summary.fetch('semantic_refusal_count') == 2 &&
      summary.fetch('constructor_observations').map { |item| item.fetch('id') } == matrix.fetch('construction_cases').map { |item| item.fetch('id') } &&
      summary.fetch('map_af_key_observation') == constructor_map &&
      matrix.fetch('source_observed_count') == profiles.length && matrix.fetch('stock_exact_nominal_count') == stock_exact &&
      counts.fetch('expected_profiles') == profiles.length && counts.fetch('stock_observed') == stock_exact &&
      counts.fetch('stock_canonicalized_not_nominal') == stock_canonical && counts.fetch('helper_observed') == profiles.length &&
      counts.fetch('native_attached_exact_nominal') == native_exact &&
      counts.fetch('native_attached_canonicalized_not_nominal') == native_canonical &&
      counts.fetch('construction_cases') == construction_count,
      'construction observations are missing or disagree between summary and source matrix')
    statuses = invocations.values.map { |record| record.fetch('status').fetch('classification') }
    expected_map_nonzero = constructor_map.fetch('classification') == 'runtime_constructor_refusal_observed'
    require_true(summary.fetch('process_status_counts').fetch('success_exit0') == statuses.count { |status| status == 'process_success' } &&
      summary.fetch('process_status_counts').fetch('nonzero_or_signaled') == statuses.count { |status| status == 'process_nonzero_or_signaled_exit' } &&
      summary.fetch('process_status_counts').fetch('nonzero_or_signaled') == (expected_map_nonzero ? 3 : 2) &&
      summary.fetch('counts').fetch('processes') == statuses.length,
      'summary process status counts disagree with raw sidecars')
    puts "W224 evidence audit ROBUST: profiles=#{profiles.length}; constructor refusals=2; Map(AF key)=#{constructor_map.fetch('classification')}; evidence=#{root}"
    true
  rescue StandardError => error
    warn "W224 evidence audit failed: #{error.class}: #{error.message}"
    false
  end

  def main(argv)
    unless argv.length == 2
      warn 'Usage: ruby scripts/check_aggregate_recursive_evidence_w224.rb EVIDENCE_ROOT EXPECTED_HELPER_SHA256'
      return false
    end
    audit(argv.fetch(0), argv.fetch(1))
  end
end

exit(CheckAggregateRecursiveEvidenceW224.main(ARGV) ? 0 : 1) if $PROGRAM_NAME == __FILE__
