#!/usr/bin/env ruby
# Independent, read-only audit of W226's raw ClickHouse and helper evidence.

require 'digest'
require 'find'
require 'json'
require 'optparse'
require_relative 'recheck_aggregate_recursive_w224'

module CheckAggregateDynamicEvidenceW226
  extend self

  R = RecheckAggregateRecursiveW224
  VERSION = R::VERSION.freeze
  BUILD_HASH = R::BUILD_HASH.freeze
  SOURCE_ROOT = R::SOURCE_ROOT.freeze
  SOURCE_REVISION = R::SOURCE_REVISION.freeze
  SOURCE_PREFIX = '/private/tmp/crystal-click-w226-native.'.freeze
  EVIDENCE_PREFIX = '/private/tmp/crystal-click-w226-evidence.'.freeze
  INPUT_FORMAT = 'aggregate_dynamic_w226_input_v1'.freeze
  HELPER_FORMAT = 'aggregate_dynamic_w226_helper_v1'.freeze
  MATRIX_FORMAT = 'aggregate_dynamic_w226_stock_matrix_v1'.freeze
  SUMMARY_FORMAT = 'aggregate_dynamic_w226_summary_v1'.freeze
  CHECK_OUTPUT = "all_1_1_0\t1\t\n".freeze
  DYNAMIC_SETTING = 'use_compact_variant_discriminators_serialization=0'.freeze
  INVALIDATED_FILE = 'invalidated_system_columns.txt'.freeze
  INVALIDATED_NAMES = %w[_block_number _block_offset].freeze
  CHECKS = %w[source_full source_middle source_zero library_full library_middle library_zero
    typed_scan_callbacks generic_scan_values window_middle window_eof owned_values
    rowbinary_full rowbinary_middle rowbinary_zero pqr_schedule source_roster_placement_expectation].freeze
  PROFILE_IDS = %w[
    known_count_shared_sum_single_stream
    known_count_shared_sum_with_size_stream
    all_shared_single_stream
    all_shared_with_size_stream
    actual_array_sum_single_stream
    actual_array_sum_with_size_stream
    outer_array_dynamic_single_stream
    outer_array_dynamic_with_size_stream
  ].freeze
  SOURCE_HASHES = {
    'src/Columns/ColumnDynamic.cpp' => 'aa358c9ac40b8d20d7cc15e7292cdc7eb6aa218ced66d023b80628cac904c04a',
    'src/Columns/ColumnDynamic.h' => '5375cf777d0982c26ce59baafb4db65dea90b76091ed1e2e794508fa5387de5c',
    'src/DataTypes/Serializations/SerializationDynamic.cpp' => 'ae052b671cf6b00ea87ac41aa80983bd48439235dcd035726fc9063a7ab81491',
    'src/DataTypes/DataTypesBinaryEncoding.h' => '92c3362477dc283302fc84713413f45fd6c92c7273309c6efb41425d22c5485f',
    'src/DataTypes/DataTypesBinaryEncoding.cpp' => '78ba394f20ccd2a00f5be6b8c4d470fafb1c91a6f87bb27c301c2d3203f28f87',
    'src/DataTypes/DataTypeVariant.cpp' => '10cf25b1ad0c1fd00eec3637bca21756207122d45ef09f97518c5748d6ae300d',
    'src/DataTypes/Serializations/SerializationVariant.cpp' => '9e91cc5a2aa9498841aa7524193247d55a30c77682c65a0991c77a2968b9e022',
  }.freeze
  COUNT_DESCRIPTOR = ['250005636f756e740000'].pack('H*').b.freeze
  SUM_U8_DESCRIPTOR = ['25000373756d000101'].pack('H*').b.freeze
  ARRAY_SUM_U8_DESCRIPTOR = ("\x1e".b + SUM_U8_DESCRIPTOR).freeze
  NOTHING_DESCRIPTOR = "\x00".b.freeze
  STRING_VERSIONS = { 'single_stream' => 0, 'with_size_stream' => 1 }.freeze
  MAX_U64 = 18_446_744_073_709_551_615

  def fail!(message)
    raise ArgumentError, message
  end

  def require_true(condition, message)
    fail!(message) unless condition
  end

  def canonical_root(path, prefix, label)
    full = File.expand_path(path)
    require_true(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "#{label} is absent, symlinked, or noncanonical")
    require_true(File.dirname(full) == File.realpath('/private/tmp') && full.start_with?(prefix),
      "#{label} must be a direct /private/tmp child with prefix #{prefix}")
    full
  end

  def read_file(path, root = nil)
    full = File.expand_path(path)
    require_true(File.file?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "missing, symlinked, or noncanonical evidence file: #{full}")
    if root
      require_true(full.start_with?(File.realpath(root) + File::SEPARATOR), "file escaped evidence root: #{full}")
    end
    File.binread(full)
  end

  def json_file(path, root = nil)
    JSON.parse(read_file(path, root).force_encoding(Encoding::UTF_8))
  rescue JSON::ParserError => error
    fail!("invalid JSON evidence #{path}: #{error.message}")
  end

  def inventory(part)
    full = File.expand_path(part)
    require_true(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "part is absent, symlinked, or noncanonical: #{full}")
    entries = []
    Find.find(full) do |path|
      next if path == full
      require_true(!File.symlink?(path), "part contains symlink: #{path}")
      next if File.directory?(path)
      require_true(File.file?(path), "part contains non-file entry: #{path}")
      entries << { 'path' => path[(full.length + 1)..-1], 'size' => File.size(path),
        'sha256' => Digest::SHA256.file(path).hexdigest }
    end
    entries.sort_by { |entry| entry.fetch('path') }
  end

  def u64(value)
    number = Integer(value)
    require_true(number >= 0 && number <= MAX_U64, "UInt64 literal outside range: #{value.inspect}")
    Array.new(8) { |index| (number >> (index * 8)) & 0xff }.pack('C*').b
  end

  def varuint(value)
    number = Integer(value)
    require_true(number >= 0 && number <= MAX_U64, "VarUInt literal outside range: #{value.inspect}")
    bytes = []
    while number >= 0x80
      bytes << ((number & 0x7f) | 0x80)
      number >>= 7
    end
    (bytes << number).pack('C*').b
  end

  def count(value)
    { 'kind' => 'count', 'value' => value.to_s }
  end

  def sum(value)
    { 'kind' => 'sum', 'value' => Integer(value) }
  end

  def null_value
    { 'kind' => 'null' }
  end

  def array_sum(*values)
    { 'kind' => 'array_sum', 'items' => values.map { |value| Integer(value) } }
  end

  def outer(*values)
    { 'kind' => 'outer', 'items' => values }
  end

  def cases
    values = [count(1), sum(256), null_value, count(MAX_U64), count(0)]
    [
      { 'case_id' => 'known_count_shared_sum', 'declared_type' => 'Dynamic(max_types=1)', 'site' => 'root',
        'source_types' => ['AggregateFunction(count)'],
        'source_shared' => [[false], [true], [nil], [false], [false]], 'rows' => values },
      { 'case_id' => 'all_shared', 'declared_type' => 'Dynamic(max_types=0)', 'site' => 'root',
        'source_types' => [], 'source_shared' => [[true], [true], [nil], [true], [true]], 'rows' => values },
      { 'case_id' => 'actual_array_sum', 'declared_type' => 'Dynamic(max_types=1)', 'site' => 'root',
        'source_types' => ['Array(AggregateFunction(sum, UInt8))'],
        'source_shared' => [[false], [true], [nil], [false], [false]],
        'rows' => [array_sum, count(256), null_value, array_sum(7, 17), array_sum(0)] },
      { 'case_id' => 'outer_array_dynamic', 'declared_type' => 'Array(Dynamic(max_types=1))', 'site' => 'root.elements',
        'source_types' => ['AggregateFunction(count)'],
        'source_shared' => [[], [], [false, true, nil], [false], [true, false]],
        'rows' => [outer, outer, outer(count(1), sum(256), null_value), outer(count(256)), outer(sum(0), count(MAX_U64))] },
    ]
  end

  def profiles
    cases.flat_map do |item|
      %w[single_stream with_size_stream].map do |profile|
        id = "#{item.fetch('case_id')}_#{profile}"
        item.merge('id' => id, 'profile' => profile,
          'source_types' => { item.fetch('site') => item.fetch('source_types') },
          'source_shared' => { item.fetch('site') => item.fetch('source_shared') },
          'mark_rows' => [2, 2, 1], 'row_keys' => [11, 22, 33, 44, 55])
      end
    end
  end

  def actual_descriptor(value)
    case value.fetch('kind')
    when 'count' then COUNT_DESCRIPTOR
    when 'sum' then SUM_U8_DESCRIPTOR
    when 'array_sum' then ARRAY_SUM_U8_DESCRIPTOR
    when 'null' then NOTHING_DESCRIPTOR
    else fail!("unlisted W226 actual kind: #{value.fetch('kind')}")
    end
  end

  def actual_body(value)
    case value.fetch('kind')
    when 'count' then varuint(Integer(value.fetch('value'), 10))
    when 'sum' then u64(value.fetch('value'))
    when 'array_sum'
      items = value.fetch('items')
      varuint(items.length) + items.map { |item| u64(item) }.join.b
    when 'null' then ''.b
    else fail!("unlisted W226 state kind: #{value.fetch('kind')}")
    end
  end

  def dynamic_body(value)
    actual_descriptor(value) + actual_body(value)
  end

  def row_body(profile, row_index)
    value = profile.fetch('rows').fetch(row_index)
    return dynamic_body(value) unless profile.fetch('case_id') == 'outer_array_dynamic'
    items = value.fetch('items')
    varuint(items.length) + items.map { |item| dynamic_body(item) }.join.b
  end

  def rowbinary_rows(profile)
    profile.fetch('rows').each_index.map do |index|
      u64(profile.fetch('row_keys').fetch(index)) + row_body(profile, index)
    end
  end

  def expected_windows(profile)
    rows = profile.fetch('rows').each_index.map { |index| row_body(profile, index) }
    { 'full' => rows.join.b, 'middle' => rows[2, 2].join.b, 'zero' => ''.b }
  end

  def expected_signatures(profile)
    declared = if profile.fetch('case_id') == 'outer_array_dynamic'
                 "\x1e\x2b\x01".b
               else
                 "\x2b".b + [profile.fetch('case_id') == 'all_shared' ? 0 : 1].pack('C').b
               end
    profile.fetch('rows').each_index.map do |index|
      "#{profile.fetch('declared_type')}|#{(declared + row_body(profile, index)).unpack1('H*')}"
    end
  end

  def expected_pqr(profile)
    outer_case = profile.fetch('case_id') == 'outer_array_dynamic'
    q = outer_case ? [0, 0, 3, 1, 2] : [1, 1, 1, 1, 1]
    r = outer_case ? [0, 0, 2, 1, 2] : [1, 1, 0, 1, 1]
    { 'parent_mark_rows' => [2, 2, 1], 'dynamic_values_by_parent_row' => q,
      'selected_non_null_actuals_by_parent_row' => r,
      'dynamic_values_by_mark' => [q[0, 2].sum, q[2, 2].sum, q[4, 1].sum],
      'selected_non_null_actuals_by_mark' => [r[0, 2].sum, r[2, 2].sum, r[4, 1].sum] }
  end

  def expected_raw_placement(profile)
    case profile.fetch('case_id')
    when 'known_count_shared_sum'
      { 'types' => ['AggregateFunction(count)', 'AggregateFunction(sum, UInt8)', 'None',
        'AggregateFunction(count)', 'AggregateFunction(count)'], 'flags' => [false, true, false, false, false] }
    when 'all_shared'
      { 'types' => ['AggregateFunction(count)', 'AggregateFunction(sum, UInt8)', 'None',
        'AggregateFunction(count)', 'AggregateFunction(count)'], 'flags' => [true, true, false, true, true] }
    when 'actual_array_sum'
      { 'types' => ['Array(AggregateFunction(sum, UInt8))', 'AggregateFunction(count)', 'None',
        'Array(AggregateFunction(sum, UInt8))', 'Array(AggregateFunction(sum, UInt8))'],
        'flags' => [false, true, false, false, false] }
    when 'outer_array_dynamic'
      { 'types' => [[], [], ['AggregateFunction(count)', 'AggregateFunction(sum, UInt8)', 'None'],
        ['AggregateFunction(count)'], ['AggregateFunction(sum, UInt8)', 'AggregateFunction(count)']],
        'flags' => [[], [], [false, true, false], [false], [true, false]] }
    else fail!('unlisted W226 placement case')
    end
  end

  def expected_type_grid(profile)
    raw = expected_raw_placement(profile).fetch('types')
    raw.map do |value|
      if value.is_a?(Array)
        value.map { |name| name == 'None' ? 'Nothing' : name }
      else
        [value == 'None' ? 'Nothing' : value]
      end
    end
  end

  def expected_source_roster(profile)
    { profile.fetch('site') => profile.fetch('source_types').fetch(profile.fetch('site')) }
  end

  def expected_create_sql(profile, table)
    settings = R::STOCK_SETTINGS + ["string_serialization_version='#{profile.fetch('profile')}'",
      "dynamic_serialization_version='v3'", DYNAMIC_SETTING]
    "CREATE TABLE default.#{table} (pk UInt64, v #{profile.fetch('declared_type')}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings.join(', ')}"
  end

  def table_name(profile, native = false)
    "w226_#{native ? 'native_' : ''}#{profile.fetch('id')}"
  end

  def expected_labels(profiles)
    labels = %w[runtime-version-pin runtime-build-pin generic-stock-read-library-write-read]
    profiles.each do |profile|
      id = profile.fetch('id')
      labels.concat(%W[stock-create-#{id} stock-insert-#{id} stock-check-#{id} stock-metadata-#{id}
        stock-type-name-#{id} stock-placement-#{id} stock-part-#{id} stock-rowbinary-#{id}-full
        stock-rowbinary-#{id}-middle stock-rowbinary-#{id}-zero])
      labels.concat(%W[native-create-#{id} native-data-path-#{id} native-attach-#{id} native-check-#{id}
        native-metadata-#{id} native-type-name-#{id} native-placement-#{id} native-part-#{id}
        native-rowbinary-#{id}-full native-rowbinary-#{id}-middle native-rowbinary-#{id}-zero])
    end
    labels
  end

  def invocation_index(root)
    directory = File.join(root, 'invocations')
    require_true(File.directory?(directory) && !File.symlink?(directory) && File.realpath(directory) == directory,
      'raw invocation directory is absent, symlinked, or noncanonical')
    index = {}
    expected_files = []
    Dir.glob(File.join(directory, '*.argv.json')).sort.each do |argv_path|
      argv_record = json_file(argv_path, root)
      require_true(argv_record.keys.sort == %w[argv environment label stdin_bytes stdin_sha256 timeout_seconds],
        'raw argv sidecar has an unexpected field set')
      label = argv_record.fetch('label')
      require_true(!index.key?(label), "duplicate raw invocation label: #{label}")
      base = argv_path.sub(/\.argv\.json\z/, '')
      status = json_file(base + '.status.json', root)
      require_true(status.keys.sort == %w[classification duration_ms exitstatus label signaled spawn_error stderr_bytes stdout_bytes termsig timed_out] &&
        status.fetch('label') == label, "raw status sidecar has unexpected fields: #{label}")
      stdout = read_file(base + '.stdout', root)
      stderr = read_file(base + '.stderr', root)
      sql = read_file(base + '.sql', root)
      require_true(status.fetch('stdout_bytes') == stdout.bytesize && status.fetch('stderr_bytes') == stderr.bytesize,
        "raw process byte counts differ: #{label}")
      if argv_record['stdin_bytes'].nil?
        require_true(!File.exist?(base + '.stdin.bin') && argv_record['stdin_sha256'].nil?, "unexpected stdin sidecar: #{label}")
        stdin = nil
      else
        stdin = read_file(base + '.stdin.bin', root)
        require_true(stdin.bytesize == argv_record.fetch('stdin_bytes') &&
          Digest::SHA256.hexdigest(stdin) == argv_record.fetch('stdin_sha256'), "raw stdin bytes/hash differ: #{label}")
      end
      %w[.argv.json .sql .status.json .stderr .stdout].each { |suffix| expected_files << File.basename(base + suffix) }
      expected_files << File.basename(base + '.stdin.bin') unless stdin.nil?
      index[label] = { 'argv_record' => argv_record, 'status' => status, 'stdout' => stdout,
        'stderr' => stderr, 'sql' => sql, 'stdin' => stdin, 'base' => base }
    end
    require_true(Dir.children(directory).sort == expected_files.sort, 'raw invocation directory has missing or extra sidecars')
    index
  end

  def record_from_status(item)
    item.fetch('status').merge('label' => item.fetch('argv_record').fetch('label'))
  end

  def assert_sql!(item, expected, label)
    require_true(item.fetch('sql') == expected + "\n" && item.fetch('argv_record').fetch('argv').last == expected,
      "raw SQL/argv differs: #{label}")
  end

  def assert_processes!(invocations, profiles, binary, source_root, evidence_root)
    wanted = expected_labels(profiles).sort
    require_true(invocations.keys.sort == wanted, 'raw invocation label roster differs')
    invocations.each do |label, item|
      status = item.fetch('status')
      require_true(status.fetch('classification') == 'process_success' && status.fetch('exitstatus') == 0 &&
        !status.fetch('signaled') && status.fetch('termsig').nil? && !status.fetch('timed_out') && status.fetch('spawn_error').nil?,
        "raw process failed: #{label}")
      argv = item.fetch('argv_record')
      if label == 'generic-stock-read-library-write-read'
        next
      end
      require_true(argv.fetch('environment') == { 'TZ' => 'UTC' }, "process environment differs: #{label}")
      command_sql = item.fetch('sql').sub(/\n\z/, '')
      require_true(item.fetch('sql') == command_sql + "\n", "process SQL sidecar newline differs: #{label}")
      if label.start_with?('runtime-')
        store = File.join(source_root, 'stores', 'pins')
      else
        profile = profiles.find { |candidate| label.include?(candidate.fetch('id')) }
        require_true(!profile.nil?, "raw process label lacks a profile: #{label}")
        side = label.start_with?('stock-') ? 'stock' : 'native'
        store = side == 'stock' ? File.join(source_root, 'stores', 'profiles', profile.fetch('id')) :
          File.join(evidence_root, 'stores', 'native', profile.fetch('id'))
      end
      expected_argv = if label == 'generic-stock-read-library-write-read'
                        nil
                      else
                        [binary, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
                          '--max_insert_threads=1', '--max_execution_time=30', "--max_memory_usage=#{R::MEMORY_LIMIT_BYTES}",
                          '--print_pretty_type_names=0', '--multiquery', '--query', command_sql]
                      end
      require_true(expected_argv.nil? || argv.fetch('argv') == expected_argv, "ClickHouse argv differs: #{label}")
      if label != 'generic-stock-read-library-write-read'
        require_true(argv.fetch('timeout_seconds') == R::PROCESS_TIMEOUT_SECONDS && File.directory?(store) &&
          !File.symlink?(store) && File.realpath(store) == store, "ClickHouse timeout/store differs: #{label}")
      end
    end
    helper = invocations.fetch('generic-stock-read-library-write-read')
    require_true(helper.fetch('argv_record').fetch('timeout_seconds') == R::HELPER_TIMEOUT_SECONDS &&
      helper.fetch('argv_record').fetch('stdin_bytes').nil? && helper.fetch('stdin').nil? && helper.fetch('sql') == "\n",
      'helper raw timeout/stdin/sql sidecars differ')
  end

  def assert_runtime!(summary, matrix, invocations)
    runtime = summary.fetch('runtime_pin')
    require_true(runtime.is_a?(Hash) && runtime.keys.sort == %w[build_hash runtime_source_correlation sha256 version] &&
      runtime.fetch('version') == VERSION && runtime.fetch('build_hash') == BUILD_HASH &&
      runtime.fetch('sha256') == R::RUNTIME_SHA256 && runtime.fetch('runtime_source_correlation') == 'not_asserted' &&
      matrix.fetch('runtime_pin') == runtime, 'runtime version/build/hash/source correlation differs')
    version = invocations.fetch('runtime-version-pin')
    build = invocations.fetch('runtime-build-pin')
    assert_sql!(version, 'SELECT version() FORMAT TSVRaw', 'runtime version')
    assert_sql!(build, "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw", 'runtime build')
    require_true(version.fetch('stdout').strip == VERSION && build.fetch('stdout').strip == "VERSION_GITHASH=#{BUILD_HASH}",
      'raw runtime version/build query output differs')
    binary = version.fetch('argv_record').fetch('argv').first
    require_true(R.validate_binary!(binary) == binary && Digest::SHA256.file(binary).hexdigest == runtime.fetch('sha256'),
      'runtime binary is not the independently pinned executable')
    binary
  end

  def assert_source_pin!(source_root, summary, matrix)
    pin = json_file(File.join(source_root, 'source_pin.json'), source_root)
    require_true(pin == summary.fetch('source_pin') && pin == matrix.fetch('source_pin'),
      'source pin differs across source carrier, summary, and matrix')
    require_true(pin.fetch('source_reference') == "#{SOURCE_ROOT}@#{SOURCE_REVISION}" &&
      pin.fetch('runtime_built_from_this_source_not_asserted') == true, 'source revision/runtime relation differs')
    base = R.pin_source!
    require_true(pin.fetch('file_hashes') == base.fetch('file_hashes') &&
      pin.fetch('source_laws') == base.fetch('source_laws') &&
      pin.fetch('file_hashes').all? { |row| row.fetch('matches') && row.fetch('expected_sha256') == row.fetch('actual_sha256') },
      'independently pinned W224 source anchors differ')
    dynamic_hashes = SOURCE_HASHES.map do |relative, expected|
      path = File.join(SOURCE_ROOT, relative)
      require_true(File.file?(path) && !File.symlink?(path), "Dynamic source file absent or symlinked: #{relative}")
      actual = Digest::SHA256.file(path).hexdigest
      { 'path' => relative, 'expected_sha256' => expected, 'actual_sha256' => actual, 'matches' => actual == expected }
    end
    require_true(dynamic_hashes.all? { |row| row.fetch('matches') } &&
      pin.fetch('dynamic_source_hashes') == dynamic_hashes, 'Dynamic/Variant pinned source hashes differ')
    pin
  end

  def assert_part_census!(stdout, expected_path, label)
    lines = stdout.split("\n", -1)
    require_true(lines.length == 2 && lines.last.empty?, "#{label} census line shape differs")
    fields = lines.first.split("\t", -1)
    require_true(fields.length == 5 && fields.first(4) == ['all_1_1_0', '5', '4', 'Wide'], "#{label} census identity differs")
    require_true([expected_path, expected_path + File::SEPARATOR].include?(fields.fetch(4)) &&
      File.directory?(expected_path) && File.realpath(expected_path) == expected_path,
      "#{label} census path differs")
  end

  def validate_raw_placement!(profile, stdout)
    rows = stdout.lines.map { |line| JSON.parse(line) }
    expected = expected_raw_placement(profile)
    require_true(rows.length == 5, "#{profile.fetch('id')} placement row count differs")
    raw_types = []
    raw_flags = []
    rows.each_with_index do |row, index|
      require_true(row.keys.sort == %w[pk shared types] && Integer(row.fetch('pk'), 10) == profile.fetch('row_keys').fetch(index),
        "#{profile.fetch('id')} placement row keys/order differ")
      types = row.fetch('types')
      flags = row.fetch('shared')
      if profile.fetch('case_id') == 'outer_array_dynamic'
        require_true(types.is_a?(Array) && flags.is_a?(Array) && types.length == flags.length,
          "#{profile.fetch('id')} nested placement grid shape differs")
        raw_types << types
        raw_flags << flags
      else
        require_true(types.is_a?(String) && (flags == true || flags == false),
          "#{profile.fetch('id')} scalar placement types/flag are not JSON primitives")
        raw_types << types
        raw_flags << flags
      end
    end
    require_true(raw_types == expected.fetch('types') && raw_flags == expected.fetch('flags'),
      "#{profile.fetch('id')} raw dynamicType/isDynamicElementInSharedData rows differ")
    normalized_types = expected_type_grid(profile)
    normalized_flags = profile.fetch('source_shared').fetch(profile.fetch('site'))
    roster = expected_source_roster(profile)
    { 'types_grid' => normalized_types, 'source_types' => roster, 'source_shared' => profile.fetch('source_shared'),
      'raw_types_grid' => expected.fetch('types'), 'raw_shared_grid' => expected.fetch('flags') }
  rescue JSON::ParserError, ArgumentError => error
    fail!("#{profile.fetch('id')} raw placement JSON invalid: #{error.message}")
  end

  def assert_raw_invocation!(record, label, sql, store, binary, stdin = nil, timeout = R::PROCESS_TIMEOUT_SECONDS)
    assert_sql!(record, sql, label)
    argv = [binary, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1', '--max_insert_threads=1',
      '--max_execution_time=30', "--max_memory_usage=#{R::MEMORY_LIMIT_BYTES}", '--print_pretty_type_names=0',
      '--multiquery', '--query', sql]
    meta = record.fetch('argv_record')
    require_true(meta.fetch('argv') == argv && meta.fetch('environment') == { 'TZ' => 'UTC' } &&
      meta.fetch('timeout_seconds') == timeout, "#{label} raw argv/environment/timeout differs")
    if stdin.nil?
      require_true(record.fetch('stdin').nil? && meta.fetch('stdin_bytes').nil? && meta.fetch('stdin_sha256').nil?,
        "#{label} unexpectedly has stdin")
    else
      require_true(record.fetch('stdin') == stdin && meta.fetch('stdin_bytes') == stdin.bytesize &&
        meta.fetch('stdin_sha256') == Digest::SHA256.hexdigest(stdin), "#{label} exact stdin bytes differ")
    end
  end

  def rowbinary_output_path(root, side, profile, window)
    File.join(root, 'cases', "#{side}-#{profile.fetch('id')}-#{window}.rowbinary")
  end

  def assert_rowbinary_window!(record, side, profile, window, table, store, root)
    output = rowbinary_output_path(root, side, profile, window)
    predicate = case window
                when 'full' then ''
                when 'middle' then ' WHERE pk BETWEEN 33 AND 44'
                when 'zero' then ' WHERE pk=0'
                else fail!("unlisted W226 RowBinary window: #{window}")
                end
    sql = "SELECT pk, v FROM default.#{table}#{predicate} ORDER BY pk INTO OUTFILE '#{output}' FORMAT RowBinary"
    assert_raw_invocation!(record, "#{side}-rowbinary-#{profile.fetch('id')}-#{window}", sql, store,
      record.fetch('argv_record').fetch('argv').first)
    raw = read_file(output, root)
    expected_indexes = { 'full' => [0, 1, 2, 3, 4], 'middle' => [2, 3], 'zero' => [] }.fetch(window)
    literal = expected_indexes.map { |index| rowbinary_rows(profile).fetch(index) }.join.b
    require_true(raw == literal, "#{side}/#{profile.fetch('id')}/#{window} raw RowBinary differs from literal")
    raw
  end

  def assert_profile_processes!(invocations, profile, source_root, evidence_root, binary)
    id = profile.fetch('id')
    stock_store = File.join(source_root, 'stores', 'profiles', id)
    stock_table = table_name(profile)
    native_store = File.join(evidence_root, 'stores', 'native', id)
    native_table = table_name(profile, true)
    create_sql = expected_create_sql(profile, stock_table)
    assert_raw_invocation!(invocations.fetch("stock-create-#{id}"), "stock-create-#{id}", create_sql, stock_store, binary)
    insert_sql = "INSERT INTO default.#{stock_table} FORMAT RowBinary"
    assert_raw_invocation!(invocations.fetch("stock-insert-#{id}"), "stock-insert-#{id}", insert_sql, stock_store, binary,
      rowbinary_rows(profile).join.b)
    assert_raw_invocation!(invocations.fetch("stock-check-#{id}"), "stock-check-#{id}",
      "CHECK TABLE default.#{stock_table} FORMAT TSVRaw", stock_store, binary)
    assert_raw_invocation!(invocations.fetch("stock-metadata-#{id}"), "stock-metadata-#{id}",
      "SELECT name, type FROM system.columns WHERE database='default' AND table='#{stock_table}' ORDER BY position FORMAT TSVRaw", stock_store, binary)
    assert_raw_invocation!(invocations.fetch("stock-type-name-#{id}"), "stock-type-name-#{id}",
      "SELECT toTypeName(v) FROM default.#{stock_table} LIMIT 1 FORMAT TSVRaw", stock_store, binary)
    assert_raw_invocation!(invocations.fetch("stock-placement-#{id}"), "stock-placement-#{id}", placement_sql(profile, stock_table), stock_store, binary)
    assert_raw_invocation!(invocations.fetch("stock-part-#{id}"), "stock-part-#{id}", census_sql(stock_table), stock_store, binary)
    %w[full middle zero].each do |window|
      assert_rowbinary_window!(invocations.fetch("stock-rowbinary-#{id}-#{window}"), 'stock', profile, window, stock_table, stock_store, evidence_root)
    end
    stock_labels = ["stock-create-#{id}", "stock-insert-#{id}", "stock-check-#{id}", "stock-metadata-#{id}",
      "stock-type-name-#{id}", "stock-part-#{id}", "stock-placement-#{id}"] +
      %w[full middle zero].map { |window| "stock-rowbinary-#{id}-#{window}" }
    stock_records = stock_labels.map { |label| record_from_status(invocations.fetch(label)) }
    require_true(json_file(File.join(source_root, 'cases', 'profiles', "#{id}.json"), source_root).fetch('processes') == stock_records,
      "stock per-profile process carrier differs from raw sidecars: #{id}")

    assert_raw_invocation!(invocations.fetch("native-create-#{id}"), "native-create-#{id}",
      expected_create_sql(profile, native_table), native_store, binary)
    assert_raw_invocation!(invocations.fetch("native-data-path-#{id}"), "native-data-path-#{id}",
      "SELECT arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{native_table}' FORMAT TSVRaw", native_store, binary)
    assert_raw_invocation!(invocations.fetch("native-attach-#{id}"), "native-attach-#{id}",
      "ALTER TABLE default.#{native_table} ATTACH PART 'all_1_1_0'", native_store, binary)
    assert_raw_invocation!(invocations.fetch("native-check-#{id}"), "native-check-#{id}",
      "CHECK TABLE default.#{native_table} FORMAT TSVRaw", native_store, binary)
    assert_raw_invocation!(invocations.fetch("native-metadata-#{id}"), "native-metadata-#{id}",
      "SELECT name, type FROM system.columns WHERE database='default' AND table='#{native_table}' ORDER BY position FORMAT TSVRaw", native_store, binary)
    assert_raw_invocation!(invocations.fetch("native-type-name-#{id}"), "native-type-name-#{id}",
      "SELECT toTypeName(v) FROM default.#{native_table} LIMIT 1 FORMAT TSVRaw", native_store, binary)
    assert_raw_invocation!(invocations.fetch("native-placement-#{id}"), "native-placement-#{id}", placement_sql(profile, native_table), native_store, binary)
    assert_raw_invocation!(invocations.fetch("native-part-#{id}"), "native-part-#{id}", census_sql(native_table), native_store, binary)
    %w[full middle zero].each do |window|
      assert_rowbinary_window!(invocations.fetch("native-rowbinary-#{id}-#{window}"), 'native', profile, window, native_table, native_store, evidence_root)
    end
  end

  def placement_sql(profile, table)
    if profile.fetch('case_id') == 'outer_array_dynamic'
      "SELECT toString(pk) AS pk, arrayMap(x -> dynamicType(x), v) AS types, arrayMap(x -> isDynamicElementInSharedData(x), v) AS shared FROM default.#{table} ORDER BY pk FORMAT JSONEachRow"
    else
      "SELECT toString(pk) AS pk, dynamicType(v) AS types, isDynamicElementInSharedData(v) AS shared FROM default.#{table} ORDER BY pk FORMAT JSONEachRow"
    end
  end

  def census_sql(table)
    "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw"
  end

  def assert_stock_matrix!(source_root, summary, matrix, profiles, invocations)
    require_true(matrix.keys.sort == %w[dynamic_serialization_version format mark_rows profile_count profiles row_keys runtime_pin source_pin string_versions variant_discriminator_mode],
      'stock matrix field set differs')
    require_true(matrix.fetch('format') == MATRIX_FORMAT && matrix.fetch('profile_count') == profiles.length &&
      matrix.fetch('row_keys') == [11, 22, 33, 44, 55] && matrix.fetch('mark_rows') == [2, 2, 1] &&
      matrix.fetch('string_versions') == STRING_VERSIONS && matrix.fetch('dynamic_serialization_version') == 'v3' &&
      matrix.fetch('variant_discriminator_mode') == 'BASIC' &&
      matrix.fetch('profiles').map { |item| item.fetch('id') } == PROFILE_IDS,
      'stock matrix profile axes/settings differ')
    matrix_path = File.join(source_root, 'matrix.json')
    require_true(Digest::SHA256.file(matrix_path).hexdigest == summary.fetch('source_matrix_sha256'),
      'source matrix raw SHA-256 differs from summary')
    binary = invocations.fetch('runtime-version-pin').fetch('argv_record').fetch('argv').first
    matrix.fetch('profiles').each_with_index do |item, index|
      profile = profiles.fetch(index)
      id = profile.fetch('id')
      site = profile.fetch('site')
      expected_roster = expected_source_roster(profile)
      expected_shared = profile.fetch('source_shared')
      expected_windows_hex = expected_windows(profile).transform_values { |bytes| bytes.unpack1('H*') }
      require_true(item.fetch('id') == id && item.fetch('case_id') == profile.fetch('case_id') &&
        item.fetch('profile') == profile.fetch('profile') && item.fetch('declared_type') == profile.fetch('declared_type') &&
        item.fetch('source_types') == expected_roster && item.fetch('source_shared') == expected_shared &&
        item.fetch('expected_rowbinary_hex') == expected_windows_hex && item.fetch('mark_rows') == [2, 2, 1] &&
        item.fetch('row_keys') == [11, 22, 33, 44, 55], "stock matrix finite profile differs: #{id}")
      source_part = File.join(source_root, 'parts', 'profiles', id, 'all_1_1_0')
      require_true(item.fetch('source_part_path') == source_part &&
        inventory(source_part) == item.fetch('source_inventory'), "stock part path/inventory differs: #{id}")
      serialization = json_file(File.join(source_part, 'serialization.json'), source_root)
      require_true(serialization == item.fetch('source_serialization') && serialization.fetch('version') == 1 &&
        serialization.fetch('propagate_types_serialization_versions_to_nested_types') == true &&
        serialization.fetch('types_serialization_versions').fetch('string') == STRING_VERSIONS.fetch(profile.fetch('profile')) &&
        read_file(File.join(source_part, 'metadata_version.txt'), source_root).strip == '0' &&
        read_file(File.join(source_part, 'default_compression_codec.txt'), source_root).strip == 'CODEC(LZ4)' &&
        read_file(File.join(source_part, 'count.txt'), source_root).strip == '5', "stock part serialization metadata differs: #{id}")
      windows = item.fetch('stock_windows')
      require_true(windows.keys.sort == %w[full middle zero], "stock matrix windows differ: #{id}")
      %w[full middle zero].each do |window|
        carrier = windows.fetch(window)
        evidence_root = summary.fetch('evidence_root')
        expected_path = rowbinary_output_path(evidence_root, 'stock', profile, window)
        expected_process = record_from_status(invocations.fetch("stock-rowbinary-#{id}-#{window}"))
        require_true(carrier.keys.sort == %w[bytes literal_hex matches_independent_literal path process sha256] &&
          carrier.fetch('path') == expected_path && carrier.fetch('process') == expected_process,
          "stock source RowBinary carrier identity/process differs: #{id}/#{window}")
        raw = read_file(carrier.fetch('path'), evidence_root)
        expected = window == 'zero' ? ''.b : (window == 'full' ? rowbinary_rows(profile).join.b : rowbinary_rows(profile)[2, 2].join.b)
        require_true(raw == expected && carrier.fetch('literal_hex') == expected.unpack1('H*') &&
          carrier.fetch('sha256') == Digest::SHA256.hexdigest(raw) &&
          carrier.fetch('bytes') == raw.bytesize && carrier.fetch('matches_independent_literal') == true,
          "stock source RowBinary window differs: #{id}/#{window}")
      end
      placement = item.fetch('stock_placement')
      raw_sql = invocations.fetch("stock-placement-#{id}").fetch('stdout')
      observed = validate_raw_placement!(profile, raw_sql)
      require_true(placement.fetch('source_types') == expected_roster && placement.fetch('source_shared') == expected_shared &&
        placement.fetch('types_grid') == expected_type_grid(profile) &&
        placement.fetch('placement_rows_json') == raw_sql && placement.fetch('raw_types_grid') == observed.fetch('raw_types_grid') &&
        placement.fetch('raw_shared_grid') == observed.fetch('raw_shared_grid'), "stock raw placement carrier differs: #{id}")
      require_true(item.fetch('stock_processes').is_a?(Array), "stock process carrier missing: #{id}")
      source_case = json_file(File.join(source_root, 'cases', 'profiles', "#{id}.json"), source_root)
      require_true(source_case.fetch('id') == id && source_case.fetch('case_id') == profile.fetch('case_id') &&
        source_case.fetch('profile') == profile.fetch('profile') && source_case.fetch('classification') == 'stock_physical_observed' &&
        source_case.fetch('declared_type') == profile.fetch('declared_type') && source_case.fetch('source_part_path') == source_part &&
        source_case.fetch('source_types') == expected_roster && source_case.fetch('source_shared') == expected_shared &&
        source_case.fetch('types_grid') == expected_type_grid(profile) && source_case.fetch('source_inventory') == item.fetch('source_inventory') &&
        source_case.fetch('rowbinary_windows') == windows && source_case.fetch('check_output') == CHECK_OUTPUT &&
        source_case.fetch('processes') == item.fetch('stock_processes'), "stock case carrier differs: #{id}")
      table = table_name(profile)
      require_true(invocations.fetch("stock-check-#{id}").fetch('stdout') == CHECK_OUTPUT &&
        invocations.fetch("stock-metadata-#{id}").fetch('stdout') == "pk\tUInt64\nv\t#{profile.fetch('declared_type')}\n" &&
        invocations.fetch("stock-type-name-#{id}").fetch('stdout') == "#{profile.fetch('declared_type')}\n",
        "stock raw CHECK/schema/typeName differs: #{id}")
      census = invocations.fetch("stock-part-#{id}").fetch('stdout')
      original_raw = census.split("\n", -1).fetch(0).split("\t", -1).fetch(4)
      original = File.expand_path(original_raw)
      store = invocations.fetch("stock-create-#{id}").fetch('argv_record').fetch('argv').fetch(3)
      require_true([original, original + File::SEPARATOR].include?(original_raw) &&
        original.start_with?(store + File::SEPARATOR) && inventory(original) == item.fetch('source_inventory'),
        "stock original store part/inventory differs: #{id}")
      assert_part_census!(census, original, "stock #{id}")
      assert_profile_processes!(invocations, profile, source_root, summary.fetch('evidence_root'), binary)
    end
  end

  def assert_helper!(root, source_root, summary, profiles, invocations, expected_helper_sha)
    helper_record = invocations.fetch('generic-stock-read-library-write-read')
    helper_argv = helper_record.fetch('argv_record').fetch('argv')
    helper = helper_argv.fetch(0)
    require_true(File.file?(helper) && File.executable?(helper) && !File.symlink?(helper) && File.realpath(helper) == helper,
      'prebuilt W226 helper is missing, redirected, or not executable')
    actual_sha = Digest::SHA256.file(helper).hexdigest
    require_true(actual_sha == expected_helper_sha && summary.fetch('helper_sha256_expected') == expected_helper_sha &&
      summary.fetch('helper_sha256_at_start') == actual_sha && summary.fetch('helper_sha256_after_execute') == actual_sha,
      'helper binary SHA-256 differs from independent pin or captured hashes')
    input_path = File.join(root, 'generated', 'helper-input.json')
    input_bytes = read_file(input_path, root)
    require_true(Digest::SHA256.hexdigest(input_bytes) == summary.fetch('helper_input_sha256'), 'helper input SHA differs from summary')
    input = JSON.parse(input_bytes.force_encoding(Encoding::UTF_8))
    require_true(input.keys.sort == %w[format profiles] && input.fetch('format') == INPUT_FORMAT &&
      input.fetch('profiles').length == profiles.length, 'helper input top-level contract differs')
    require_true(helper_argv == [helper, input_path, File.join(root, 'generated'), source_root] &&
      helper_record.fetch('argv_record').fetch('environment') == { 'TZ' => 'UTC' } &&
      helper_record.fetch('argv_record').fetch('timeout_seconds') == R::HELPER_TIMEOUT_SECONDS &&
      helper_record.fetch('sql') == "\n" && helper_record.fetch('stdin').nil?,
      'helper exact argv/environment/timeout/stdin differs')
    require_true(JSON.parse(helper_record.fetch('stdout').force_encoding(Encoding::UTF_8)) ==
      json_file(File.join(root, 'generated', 'helper-output.json'), root), 'helper output file differs from raw stdout')
    output = json_file(File.join(root, 'generated', 'helper-output.json'), root)
    require_true(output.keys.sort == %w[format profiles] && output.fetch('format') == HELPER_FORMAT &&
      output.fetch('profiles').map { |row| row.fetch('id') } == PROFILE_IDS,
      'raw helper output format/profile roster differs')
    process_carrier = json_file(File.join(root, 'generated', 'helper-process.json'), root)
    require_true(process_carrier == record_from_status(helper_record), 'helper process status carrier differs from raw sidecar')
    profiles.each_with_index do |profile, index|
      id = profile.fetch('id')
      source_part = File.join(source_root, 'parts', 'profiles', id, 'all_1_1_0')
      destination = File.join(root, 'generated', 'parts', format('%02d-%s', index, id), 'all_1_1_0')
      windows = expected_windows(profile).transform_values { |bytes| bytes.unpack1('H*') }
      expected_input = { 'id' => id, 'case_id' => profile.fetch('case_id'), 'profile' => profile.fetch('profile'),
        'declared_type' => profile.fetch('declared_type'), 'source_part_path' => source_part,
        'destination_path' => destination, 'expected_rowbinary_hex' => windows,
        'source_types' => expected_source_roster(profile), 'source_shared' => profile.fetch('source_shared') }
      require_true(input.fetch('profiles').fetch(index).keys.sort == expected_input.keys.sort &&
        input.fetch('profiles').fetch(index) == expected_input, "helper input finite fixture differs: #{id}")
      item = output.fetch('profiles').fetch(index)
      require_true(item.keys.sort == %w[case_id checks id library_part logicalroles mark_rows owned_signatures physicalstreams pqr profile stock_part type],
        "helper output profile field set differs: #{id}")
      require_true(item.fetch('case_id') == profile.fetch('case_id') && item.fetch('profile') == profile.fetch('profile') &&
        item.fetch('type') == profile.fetch('declared_type') && item.fetch('checks') == CHECKS && item.fetch('mark_rows') == [2, 2, 1] &&
        item.fetch('pqr') == expected_pqr(profile) && item.fetch('owned_signatures') == expected_signatures(profile),
        "helper identity/checks/mark/PQR/owned signatures differ: #{id}")
      expected_roles = expected_source_roster(profile)
      roles = item.fetch('logicalroles')
      roles_match = roles.keys.sort == %w[library stock] && %w[library stock].all? { |side|
        roles.fetch(side).keys.sort == ['ordinary'] && roles.fetch(side).fetch('ordinary') == expected_roles
      }
      require_true(roles_match, "helper stock/library ordinary roster differs: #{id}")
      streams = item.fetch('physicalstreams')
      require_true(streams.keys.sort == %w[library stock] && streams.fetch('stock').is_a?(Array) &&
        streams.fetch('library').is_a?(Array) && streams.fetch('stock') == streams.fetch('library') &&
        streams.fetch('stock') == streams.fetch('stock').sort && streams.fetch('stock').uniq == streams.fetch('stock') &&
        streams.fetch('stock').all? { |name| name.is_a?(String) && !name.empty? }, "helper stream roster differs: #{id}")
      %w[stock_part library_part].each do |key|
        part = item.fetch(key)
        path = key == 'stock_part' ? source_part : destination
        require_true(part.keys.sort == %w[full_rowbinary_hex middle_rowbinary_hex path zero_rowbinary_hex] &&
          part.fetch('path') == path && part.fetch('full_rowbinary_hex') == windows.fetch('full') &&
          part.fetch('middle_rowbinary_hex') == windows.fetch('middle') && part.fetch('zero_rowbinary_hex') == windows.fetch('zero'),
          "helper #{key} value-body/path differs: #{id}")
      end
      source_case = json_file(File.join(source_root, 'cases', 'profiles', "#{id}.json"), source_root)
      source_inventory = source_case.fetch('source_inventory')
      require_true(inventory(source_part) == source_inventory && inventory(destination).any?,
        "helper stock/library part inventory missing or stock part changed: #{id}")
      helper_case = json_file(File.join(root, 'cases', "#{id}-helper.json"), root)
      require_true(helper_case.fetch('id') == id && helper_case.fetch('case_id') == profile.fetch('case_id') &&
        helper_case.fetch('profile') == profile.fetch('profile') && helper_case.fetch('declared_type') == profile.fetch('declared_type') &&
        helper_case.fetch('stock_part_path') == source_part && helper_case.fetch('library_part_path') == destination &&
        helper_case.fetch('stock_inventory') == source_inventory && helper_case.fetch('library_inventory') == inventory(destination) &&
        helper_case.fetch('helper_profile') == item, "helper case inventory/profile carrier differs: #{id}")
    end
  rescue JSON::ParserError => error
    fail!("helper evidence JSON invalid: #{error.message}")
  end

  def assert_native_cases!(root, profiles, invocations)
    profiles.each do |profile|
      id = profile.fetch('id')
      table = table_name(profile, true)
      store = File.join(root, 'stores', 'native', id)
      data_path = File.expand_path(invocations.fetch("native-data-path-#{id}").fetch('stdout').strip)
      require_true(data_path.start_with?(store + File::SEPARATOR) && File.directory?(data_path) &&
        !File.symlink?(data_path) && File.realpath(data_path) == data_path, "native data path escaped isolated store: #{id}")
      attached = File.join(data_path, 'all_1_1_0')
      census = invocations.fetch("native-part-#{id}").fetch('stdout')
      assert_part_census!(census, attached, "native #{id}")
      require_true(invocations.fetch("native-check-#{id}").fetch('stdout') == CHECK_OUTPUT &&
        invocations.fetch("native-metadata-#{id}").fetch('stdout') == "pk\tUInt64\nv\t#{profile.fetch('declared_type')}\n" &&
        invocations.fetch("native-type-name-#{id}").fetch('stdout') == "#{profile.fetch('declared_type')}\n",
        "native raw CHECK/schema/typeName differs: #{id}")
      placement = validate_raw_placement!(profile, invocations.fetch("native-placement-#{id}").fetch('stdout'))
      require_true(placement.fetch('source_types') == expected_source_roster(profile) &&
        placement.fetch('source_shared') == profile.fetch('source_shared'), "native raw placement differs: #{id}")
      generated = File.join(root, 'generated', 'parts', format('%02d-%s', PROFILE_IDS.index(id), id), 'all_1_1_0')
      gen_inventory = inventory(generated)
      attached_inventory = inventory(attached)
      before = Hash[gen_inventory.map { |entry| [entry.fetch('path'), entry] }]
      after = Hash[attached_inventory.map { |entry| [entry.fetch('path'), entry] }]
      added = after.keys - before.keys
      changed = before.keys.select { |path| after.key?(path) && before.fetch(path) != after.fetch(path) }
      removed = before.keys - after.keys
      require_true(removed.empty? && changed.empty? && added == [INVALIDATED_FILE] &&
        read_file(File.join(attached, INVALIDATED_FILE), attached).split("\n", -1).tap { |lines| require_true(lines.pop == '', "#{id} invalidated columns newline differs") }.sort == INVALIDATED_NAMES.sort,
        "native ATTACH file delta is outside the exact invalidated-system-columns allowance: #{id}")
      expected_delta = { 'removed' => removed, 'changed' => changed, 'added' => added,
        'attached_inventory' => attached_inventory }
      columns = read_file(File.join(attached, 'columns.txt'), attached).force_encoding(Encoding::UTF_8).scrub
      require_true(columns == "columns format version: 1\n2 columns:\n`pk` UInt64\n`v` #{profile.fetch('declared_type')}\n",
        "native attached columns.txt differs: #{id}")
      serialization = json_file(File.join(attached, 'serialization.json'), attached)
      require_true(serialization.fetch('version') == 1 && serialization.fetch('propagate_types_serialization_versions_to_nested_types') == true &&
        serialization.fetch('types_serialization_versions').fetch('string') == STRING_VERSIONS.fetch(profile.fetch('profile')) &&
        read_file(File.join(attached, 'metadata_version.txt'), attached).strip == '0' &&
        read_file(File.join(attached, 'default_compression_codec.txt'), attached).strip == 'CODEC(LZ4)' &&
        read_file(File.join(attached, 'count.txt'), attached).strip == '5', "native attached part metadata differs: #{id}")
      windows = {}
      %w[full middle zero].each do |window|
        windows[window] = assert_rowbinary_window!(invocations.fetch("native-rowbinary-#{id}-#{window}"),
          'native', profile, window, table, store, root)
      end
      record = json_file(File.join(root, 'cases', "#{id}-attached.json"), root)
      require_true(record.fetch('classification') == 'native_attached_check_and_rowbinary_observed' &&
        record.fetch('native_schema') == "pk\tUInt64\nv\t#{profile.fetch('declared_type')}\n" &&
        record.fetch('type_name') == "#{profile.fetch('declared_type')}\n" && record.fetch('check_output') == CHECK_OUTPUT &&
        record.fetch('source_types') == expected_source_roster(profile) && record.fetch('source_shared') == profile.fetch('source_shared') &&
        record.fetch('placement').fetch('placement_rows_json') == invocations.fetch("native-placement-#{id}").fetch('stdout') &&
        record.fetch('generated_inventory') == gen_inventory && record.fetch('attached_inventory') == attached_inventory &&
        record.fetch('file_delta') == expected_delta && record.fetch('columns_txt') == columns &&
        record.fetch('serialization_json') == serialization && record.fetch('rowbinary_windows').keys.sort == %w[full middle zero],
        "native attached case carrier differs: #{id}")
      native_labels = ["native-data-path-#{id}", "native-attach-#{id}", "native-check-#{id}",
        "native-metadata-#{id}", "native-type-name-#{id}", "native-part-#{id}", "native-placement-#{id}"] +
        %w[full middle zero].map { |window| "native-rowbinary-#{id}-#{window}" }
      require_true(record.fetch('processes') == native_labels.map { |label| record_from_status(invocations.fetch(label)) },
        "native per-profile process carrier differs from raw sidecars: #{id}")
      %w[full middle zero].each do |window|
        carrier = record.fetch('rowbinary_windows').fetch(window)
        expected = windows.fetch(window)
        require_true(carrier.keys.sort == %w[bytes literal_hex matches_independent_literal path process sha256] &&
          carrier.fetch('path') == rowbinary_output_path(root, 'native', profile, window) &&
          carrier.fetch('process') == record_from_status(invocations.fetch("native-rowbinary-#{id}-#{window}")) &&
          carrier.fetch('matches_independent_literal') == true && read_file(carrier.fetch('path'), root) == expected &&
          carrier.fetch('literal_hex') == expected.unpack1('H*') &&
          carrier.fetch('bytes') == expected.bytesize && carrier.fetch('sha256') == Digest::SHA256.hexdigest(expected),
          "native attached case RowBinary carrier differs: #{id}/#{window}")
      end
    end
  end

  def audit(source_root, evidence_root, expected_helper_sha)
    source_root = canonical_root(source_root, SOURCE_PREFIX, 'W226 source root')
    evidence_root = canonical_root(evidence_root, EVIDENCE_PREFIX, 'W226 evidence root')
    require_true(source_root != evidence_root, 'source/evidence roots must be distinct')
    summary = json_file(File.join(evidence_root, 'summary.json'), evidence_root)
    require_true(summary.keys.sort == %w[classification counts error evidence_root format helper_input_sha256
      helper_sha256_after_execute helper_sha256_at_start helper_sha256_expected process_status_counts
      runtime_pin source_matrix_sha256 source_pin source_root success].sort &&
      summary.fetch('format') == SUMMARY_FORMAT && summary.fetch('classification') == 'paired_dynamic_aggregate_profiles_observed' &&
      summary.fetch('success') == true && summary['error'].nil? && summary.fetch('source_root') == source_root &&
      summary.fetch('evidence_root') == evidence_root, 'W226 summary identity/classification differs')
    profiles = profiles()
    require_true(profiles.map { |profile| profile.fetch('id') } == PROFILE_IDS, 'independent W226 profile order differs')
    invocations = invocation_index(evidence_root)
    binary = invocations.fetch('runtime-version-pin').fetch('argv_record').fetch('argv').first
    assert_processes!(invocations, profiles, binary, source_root, evidence_root)
    expected_process_count = expected_labels(profiles).length
    counts = summary.fetch('counts')
    require_true(counts == { 'profiles_expected' => 8, 'stock_profiles' => 8, 'helper_profiles' => 8,
      'native_profiles' => 8, 'processes' => expected_process_count } &&
      summary.fetch('process_status_counts') == { 'success_exit0' => expected_process_count,
        'nonzero_or_signaled' => 0, 'timeout' => 0, 'spawn_failure' => 0 },
      'summary count/status carriers differ from independently observed raw process roster')
    matrix = json_file(File.join(source_root, 'matrix.json'), source_root)
    assert_source_pin!(source_root, summary, matrix)
    assert_runtime!(summary, matrix, invocations)
    assert_stock_matrix!(source_root, summary, matrix, profiles, invocations)
    assert_helper!(evidence_root, source_root, summary, profiles, invocations, expected_helper_sha)
    assert_native_cases!(evidence_root, profiles, invocations)
    puts "W226 evidence audit passed: profiles=#{profiles.length}, raw_processes=#{expected_process_count}"
    true
  end

  def main(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/check_aggregate_dynamic_evidence_w226.rb --source-root DIR --evidence-root DIR --helper-sha256 HEX'
      opts.on('--source-root PATH') { |value| options[:source_root] = value }
      opts.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
      opts.on('--helper-sha256 HEX') { |value| options[:helper_sha256] = value }
    end
    parser.parse!(argv)
    require_true(argv.empty? && %i[source_root evidence_root helper_sha256].all? { |key| options.key?(key) }, parser.to_s)
    require_true(options.fetch(:helper_sha256).is_a?(String) && /\A[0-9a-f]{64}\z/.match?(options.fetch(:helper_sha256)),
      'expected helper SHA-256 must be 64 lowercase hexadecimal characters')
    audit(options.fetch(:source_root), options.fetch(:evidence_root), options.fetch(:helper_sha256))
  rescue StandardError => error
    warn "W226 evidence audit failed: #{error.class}: #{error.message}"
    false
  end
end

exit(CheckAggregateDynamicEvidenceW226.main(ARGV) ? 0 : 1) if $PROGRAM_NAME == __FILE__
