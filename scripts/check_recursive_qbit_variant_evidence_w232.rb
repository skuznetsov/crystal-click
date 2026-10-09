#!/usr/bin/env ruby
# Independent, read-only audit of the bounded W232 stock-authored and
# Crystal-written static QBit-in-Variant evidence. This auditor does not load
# the capture runner and never invokes ClickHouse, Crystal, or another process.

require 'digest'
require 'find'
require 'json'
require 'optparse'

module CheckRecursiveQBitVariantEvidenceW232
  extend self

  REPO_ROOT = '/Users/sergey/Projects/Crystal/crystal-click'.freeze
  SOURCE_ROOT = '/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1'.freeze
  SOURCE_REVISION = '0ca8150d9b1d0886edb2e3b4ab65eebb768d0357'.freeze
  CLICKHOUSE_BIN = '/private/tmp/crystal-click-w216-runtime-recovery.DmL9Kw/clickhouse-stripped'.freeze
  CLICKHOUSE_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  CLICKHOUSE_VERSION = '26.10.1.1201'.freeze
  CLICKHOUSE_BUILD = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  SOURCE_PREFIX = 'crystal-click-w232-stock.'.freeze
  EVIDENCE_PREFIX = 'crystal-click-w232-evidence.'.freeze
  INPUT_FORMAT = 'recursive_qbit_variant_w232_helper_input_v1'.freeze
  HELPER_FORMAT = 'recursive_qbit_variant_w232_helper_output_v1'.freeze
  RESULT_FORMAT = 'recursive_qbit_variant_w232_result_v1'.freeze
  PROCESS_TIMEOUT_SECONDS = 90
  HELPER_TIMEOUT_SECONDS = 600
  MEMORY_LIMIT_BYTES = 1_073_741_824
  ROW_KEYS = [1, 2, 3, 4, 5, 6].freeze
  MARK_ROWS = [2, 2, 2].freeze
  PHYSICAL_MARKS = 4
  INVALIDATED_FILE = 'invalidated_system_columns.txt'.freeze
  INVALIDATED_NAMES = %w[_block_number _block_offset].freeze
  MAX_FILES = 1_024
  MAX_TOTAL_BYTES = 16 * 1024 * 1024
  MAX_TREE_ENTRIES = 4_096
  MAX_TREE_BYTES = 16 * 1024 * 1024

  SETTINGS = [
    'index_granularity=2', 'index_granularity_bytes=10485760',
    'enable_mixed_granularity_parts=1', 'min_rows_for_wide_part=0',
    'min_bytes_for_wide_part=0', 'min_level_for_wide_part=0',
    'compress_marks=0', 'compress_primary_key=0', 'min_compress_block_size=0',
    'max_compress_block_size=4096', 'ratio_of_defaults_for_sparse_serialization=1.0',
    'compute_exact_num_defaults_for_sparse_columns=0', "default_compression_codec='LZ4'",
    "nullable_serialization_version='basic'", "string_serialization_version='single_stream'",
    "map_serialization_version='basic'", "map_serialization_version_for_zero_level_parts='basic'",
    "serialization_info_version='with_types'", 'propagate_types_serialization_versions_to_nested_types=1',
    'allow_suspicious_low_cardinality_types=1', 'use_compact_variant_discriminators_serialization=0',
  ].freeze

  SOURCE_FILES = {
    'src/DataTypes/DataTypeVariant.cpp' => '10cf25b1ad0c1fd00eec3637bca21756207122d45ef09f97518c5748d6ae300d',
    'src/DataTypes/DataTypeVariant.h' => '2ebdfa5ebb1c1d1d682c52902b7cae8cb8d3b70d0cce98e75710013ecd994bb0',
    'src/DataTypes/DataTypeQBit.cpp' => '9713cd968e6a8252bba54aaf9dd49cbe2e31edc9af7e4e1d473d74d435ce87d9',
    'src/DataTypes/DataTypeArray.h' => '660e6f37210922c200a7cbba5f25a0f01d579f79a51611768de72d1a3002be37',
    'src/DataTypes/DataTypeMap.cpp' => 'dfc839fd14ad6f0b726d65cdc266622cc62912cc48adfb60e61bdb0b49752c73',
    'src/DataTypes/DataTypeTuple.cpp' => '350d50a6d0c5cefbf8b31bad1106f7e2200cc69ada1bac50704723d66edde2a0',
    'src/DataTypes/Serializations/ISerialization.cpp' => '87ca6647aeb0dd4022e3437a155f923f817d4447c547eff9ec29ab6876d16dd2',
    'src/DataTypes/Serializations/SerializationArray.cpp' => '825295e177ae7f406c1a1c155e0c9e17b4cc39f4747cb1f3fb327b54db043791',
    'src/DataTypes/Serializations/SerializationMap.cpp' => '191c35c896507f303b06b2527277148d748ba5b8c62ffbefbdab739b1a6a8056',
    'src/DataTypes/Serializations/SerializationQBit.cpp' => '64a1638077a5807512dff9fb25ad310f5a8da80eb76d39d9c76d083d980fc5da',
    'src/DataTypes/Serializations/SerializationTuple.cpp' => '12e38b357204e005fc4780bac7e2e358b0a14357e0e246137414166062a1a884',
    'src/DataTypes/Serializations/SerializationVariant.cpp' => '9e91cc5a2aa9498841aa7524193247d55a30c77682c65a0991c77a2968b9e022',
    'src/Storages/MergeTree/MergeTreeSettings.cpp' => 'b8bdea86a07f61481c747517b56035855fa9726217d5b7183f292a5432b9b515',
  }.freeze

  DIRECT_TYPE = 'Variant(QBit(Int8, 9), UInt64)'.freeze
  ARRAY_TYPE = 'Array(Variant(QBit(Int8, 9), UInt64))'.freeze
  COMPOSED_TYPE = 'Variant(Array(QBit(Int8, 9)), Map(String, QBit(Int8, 9)), Tuple(q QBit(Int8, 9), n UInt8))'.freeze
  ALTERNATIVE_INDEX = {
    'QBit(Int8, 9)' => 0, 'UInt64' => 1,
    'Array(QBit(Int8, 9))' => 0,
    'Map(String, QBit(Int8, 9))' => 1,
    'Tuple(q QBit(Int8, 9), n UInt8)' => 2,
  }.freeze

  def assert!(condition, message)
    raise "W232 AUDIT FAIL: #{message}" unless condition
  end

  def plain_file!(path, label, executable: false)
    full = File.expand_path(path)
    assert!(File.file?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "#{label} is absent, symlinked, or noncanonical: #{full}")
    assert!(!executable || File.executable?(full), "#{label} is not executable: #{full}")
    full
  end

  def plain_dir!(path, label)
    full = File.expand_path(path)
    assert!(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "#{label} is absent, symlinked, or noncanonical: #{full}")
    full
  end

  def read_json(path, label)
    JSON.parse(File.binread(plain_file!(path, label)).force_encoding(Encoding::UTF_8))
  rescue JSON::ParserError => error
    raise "W232 AUDIT FAIL: malformed #{label}: #{error.message}"
  end

  def sha256_file(path)
    Digest::SHA256.file(plain_file!(path, 'hashed file')).hexdigest
  end

  def bounded_root!(path, prefix, label)
    full = plain_dir!(path, label)
    assert!(File.dirname(full) == File.realpath('/private/tmp') && File.basename(full).start_with?(prefix),
      "#{label} must be a direct bounded /private/tmp child")
    full
  end

  def source_manifest
    files = SOURCE_FILES.map do |relative, expected|
      actual = sha256_file(File.join(SOURCE_ROOT, relative))
      assert!(actual == expected, "pinned ClickHouse source changed: #{relative}")
      { 'path' => relative, 'sha256' => actual }
    end
    { 'root' => SOURCE_ROOT, 'revision' => SOURCE_REVISION, 'files' => files }
  end

  def varuint(value)
    assert!(value.is_a?(Integer) && value >= 0 && value <= 18_446_744_073_709_551_615,
      "fixture VarUInt outside UInt64: #{value.inspect}")
    bytes = []
    while value >= 0x80
      bytes << ((value & 0x7f) | 0x80)
      value >>= 7
    end
    (bytes << value).pack('C*').b
  end

  def uint64_le(value)
    assert!(value.is_a?(Integer) && value >= 0 && value <= 18_446_744_073_709_551_615,
      "fixture UInt64 outside range: #{value.inspect}")
    Array.new(8) { |index| (value >> (index * 8)) & 0xff }.pack('C*').b
  end

  def q(hex)
    assert!(hex.is_a?(String) && /\A(?:[0-9a-f]{2}){9}\z/.match?(hex), 'QBit(Int8, 9) literal width differs')
    { 'kind' => 'qbit', 'hex' => hex }
  end

  def variant(alternative, value)
    { 'kind' => 'variant', 'alternative' => alternative, 'value' => value }
  end

  def array(items)
    { 'kind' => 'array', 'items' => items }
  end

  # Frozen auditor-side fixture: it is not read from runner output, helper input,
  # or the ClickHouse RowBinary captures.
  def profiles
    null = { 'kind' => 'variant_null' }
    direct = [
      variant('QBit(Int8, 9)', q('feff00010204081020')),
      variant('QBit(Int8, 9)', q('080706050403020100')),
      variant('UInt64', { 'kind' => 'uint64', 'value' => 0x1122_3344_5566_7788 }),
      variant('QBit(Int8, 9)', q('020406080a0c0e1012')),
      null, null,
    ]
    array_variants = [
      array([variant('QBit(Int8, 9)', q('feff00010204081020')), null]),
      array([]),
      array([variant('UInt64', { 'kind' => 'uint64', 'value' => 7 }),
        variant('QBit(Int8, 9)', q('01030507090b0d0f11'))]),
      array([null]), array([]), array([null]),
    ]
    composed = [
      variant('Array(QBit(Int8, 9))', array([])),
      variant('Array(QBit(Int8, 9))', array([q('feff00010204081020'), q('080706050403020100')])),
      variant('Tuple(q QBit(Int8, 9), n UInt8)', {
        'kind' => 'tuple', 'fields' => [q('01030507090b0d0f11'), { 'kind' => 'uint8', 'value' => 7 }],
      }),
      variant('Map(String, QBit(Int8, 9))', {
        'kind' => 'map', 'entries' => [['a', q('020406080a0c0e1012')], ['xy', q('101112131415161718')]],
      }),
      null, null,
    ]
    output = [
      { 'id' => 'root_variant', 'type' => DIRECT_TYPE, 'rows' => direct },
      { 'id' => 'array_variant', 'type' => ARRAY_TYPE, 'rows' => array_variants },
      { 'id' => 'variant_array_tuple_map', 'type' => COMPOSED_TYPE, 'rows' => composed },
    ]
    assert!(output.length == 3 && output.all? { |item| item.fetch('rows').length == ROW_KEYS.length },
      'fixed six-row profile roster differs')
    output
  end

  def encode_node(spec)
    kind = spec.fetch('kind')
    case kind
    when 'qbit'
      varuint(9) + [spec.fetch('hex')].pack('H*').b
    when 'variant_null'
      "\xff".b
    when 'variant'
      index = ALTERNATIVE_INDEX.fetch(spec.fetch('alternative')) { raise 'unlisted Variant arm' }
      [index].pack('C').b + encode_node(spec.fetch('value'))
    when 'array'
      items = spec.fetch('items')
      varuint(items.length) + items.map { |item| encode_node(item) }.join.b
    when 'map'
      entries = spec.fetch('entries')
      varuint(entries.length) + entries.map do |key, value|
        bytes = key.encode(Encoding::UTF_8).b
        varuint(bytes.bytesize) + bytes + encode_node(value)
      end.join.b
    when 'tuple'
      spec.fetch('fields').map { |field| encode_node(field) }.join.b
    when 'string'
      bytes = spec.fetch('value').encode(Encoding::UTF_8).b
      varuint(bytes.bytesize) + bytes
    when 'uint8'
      value = spec.fetch('value')
      assert!(value.is_a?(Integer) && (0..255).cover?(value), 'UInt8 literal outside range')
      [value].pack('C').b
    when 'uint64'
      uint64_le(spec.fetch('value'))
    else
      raise "unlisted RowBinary node #{kind.inspect}"
    end
  end

  def rowbinary(profile, index)
    uint64_le(ROW_KEYS.fetch(index)) + encode_node(profile.fetch('rows').fetch(index))
  end

  def expected_window(profile, window)
    indices = { 'full' => (0...ROW_KEYS.length).to_a, 'middle' => [2, 3], 'zero' => [] }.fetch(window)
    indices.map { |index| rowbinary(profile, index) }.join.b
  end

  def literal_hex(profile)
    ROW_KEYS.each_index.map { |index| rowbinary(profile, index).unpack1('H*') }
  end

  def clickhouse_argv(store, sql)
    [CLICKHOUSE_BIN, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
      '--max_insert_threads=1', '--max_execution_time=30', "--max_memory_usage=#{MEMORY_LIMIT_BYTES}",
      '--print_pretty_type_names=0', '--flatten_nested=0', '--multiquery', '--query', sql]
  end

  def create_sql(table, profile)
    "CREATE TABLE default.#{table} (id UInt64, v #{profile.fetch('type')} CODEC(LZ4)) " \
      "ENGINE=MergeTree ORDER BY id SETTINGS #{SETTINGS.join(', ')}"
  end

  def check_sql(table)
    "CHECK TABLE default.#{table} FORMAT TSVRaw"
  end

  def schema_sql(table)
    "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw"
  end

  def part_sql(table)
    "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw"
  end

  def window_sql(table, window)
    predicate = { 'full' => '', 'middle' => ' WHERE id BETWEEN 3 AND 4', 'zero' => ' WHERE id=0' }.fetch(window)
    "SELECT id, v FROM default.#{table}#{predicate} ORDER BY id FORMAT RowBinary"
  end

  def invocations(source_root, evidence_root, helper)
    source = []
    pin_store = File.join(source_root, 'stores', 'pins')
    source << ['runtime-version-pin', pin_store, 'SELECT version() FORMAT TSVRaw', nil, nil, PROCESS_TIMEOUT_SECONDS]
    source << ['runtime-build-pin', pin_store,
      "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw", nil, nil, PROCESS_TIMEOUT_SECONDS]
    profiles.each do |profile|
      id = profile.fetch('id')
      table = "w232_stock_#{id}"
      store = File.join(source_root, 'stores', id)
      input = ROW_KEYS.each_index.map { |index| rowbinary(profile, index) }.join.b
      source << ["stock-create-#{id}", store, create_sql(table, profile), nil, nil, PROCESS_TIMEOUT_SECONDS]
      source << ["stock-insert-#{id}", store, "INSERT INTO default.#{table} FORMAT RowBinary", input, nil, PROCESS_TIMEOUT_SECONDS]
      source << ["stock-check-#{id}", store, check_sql(table), nil, nil, PROCESS_TIMEOUT_SECONDS]
      source << ["stock-schema-#{id}", store, schema_sql(table), nil, nil, PROCESS_TIMEOUT_SECONDS]
      source << ["stock-part-#{id}", store, part_sql(table), nil, nil, PROCESS_TIMEOUT_SECONDS]
      %w[full middle zero].each do |window|
        source << ["stock-rowbinary-#{id}-#{window}", store, window_sql(table, window), nil, nil, PROCESS_TIMEOUT_SECONDS]
      end
    end

    input_path = File.join(evidence_root, 'generated', 'helper-input.json')
    evidence = [['helper-read-write-roundtrip', File.join(evidence_root, 'generated'), nil, nil,
      [helper, '--input', input_path], HELPER_TIMEOUT_SECONDS]]
    profiles.each do |profile|
      id = profile.fetch('id')
      table = "w232_native_#{id}"
      store = File.join(evidence_root, 'stores', id)
      evidence << ["native-create-#{id}", store, create_sql(table, profile), nil, nil, PROCESS_TIMEOUT_SECONDS]
      evidence << ["native-data-path-#{id}", store,
        "SELECT arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw", nil, nil, PROCESS_TIMEOUT_SECONDS]
      evidence << ["native-attach-#{id}", store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'", nil, nil, PROCESS_TIMEOUT_SECONDS]
      evidence << ["native-check-#{id}", store, check_sql(table), nil, nil, PROCESS_TIMEOUT_SECONDS]
      evidence << ["native-schema-#{id}", store, schema_sql(table), nil, nil, PROCESS_TIMEOUT_SECONDS]
      evidence << ["native-part-#{id}", store, part_sql(table), nil, nil, PROCESS_TIMEOUT_SECONDS]
      %w[full middle zero].each do |window|
        evidence << ["native-rowbinary-#{id}-#{window}", store, window_sql(table, window), nil, nil, PROCESS_TIMEOUT_SECONDS]
      end
    end
    [source, evidence, input_path]
  end

  def inventory(part)
    root = plain_dir!(part, 'part directory')
    entries = []
    count = 0
    bytes = 0
    Find.find(root) do |path|
      next if path == root
      count += 1
      assert!(count <= MAX_TREE_ENTRIES && !File.symlink?(path), 'part tree exceeds bound or contains a symlink')
      next if File.directory?(path)
      assert!(File.file?(path), 'part tree contains an unsupported entry')
      size = File.size(path)
      bytes += size
      assert!(bytes <= MAX_TREE_BYTES, 'part tree exceeds byte bound')
      entries << { 'path' => path[(root.length + 1)..-1], 'size' => size, 'sha256' => sha256_file(path) }
    end
    entries.sort_by { |entry| entry.fetch('path') }
  end

  def inventory_delta(before, after)
    first = before.to_h { |entry| [entry.fetch('path'), entry] }
    second = after.to_h { |entry| [entry.fetch('path'), entry] }
    [(first.keys - second.keys).sort,
     first.keys.select { |path| second.key?(path) && first.fetch(path) != second.fetch(path) }.sort,
     (second.keys - first.keys).sort]
  end

  def tsv_row!(bytes, count, label)
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    assert!(text.valid_encoding?, "#{label} is not UTF-8 TSV")
    lines = text.lines.map { |line| line.chomp.sub(/\r\z/, '') }
    assert!(lines.length == 1, "#{label} is not exactly one row")
    fields = lines.first.split("\t", -1)
    assert!(fields.length == count, "#{label} field count differs")
    fields
  end

  def verify_capture_budget!(root)
    files = 0
    bytes = 0
    Find.find(root) do |path|
      next if path == root || File.directory?(path)
      assert!(!File.symlink?(path) && File.file?(path), "unsupported or symlinked capture file: #{path}")
      files += 1
      bytes += File.size(path)
      assert!(files <= MAX_FILES && bytes <= MAX_TOTAL_BYTES, 'capture exceeds file/byte cap')
    end
  end

  def verify_invocation_directory!(root, expected)
    directory = plain_dir!(File.join(root, 'invocations'), 'invocation directory')
    expected_names = expected.each_with_index.flat_map do |entry, index|
      stem = format('%04d-%s', index + 1, entry.fetch(0).gsub(/[^A-Za-z0-9_.-]/, '_'))
      suffixes = %w[.argv.json .sql .stdout .stderr .status.json]
      suffixes << '.stdin.bin' if entry.fetch(3)
      suffixes.map { |suffix| stem + suffix }
    end.sort
    assert!(Dir.children(directory).sort == expected_names, 'raw invocation artifact roster differs')
  end

  def verify_processes(root, expected, helper)
    expected.each_with_index.map do |entry, index|
      label, store, sql, stdin, argv_override, timeout = entry
      stem = format('%04d-%s', index + 1, label.gsub(/[^A-Za-z0-9_.-]/, '_'))
      base = File.join(root, 'invocations', stem)
      argv = read_json(base + '.argv.json', "#{label} argv")
      status = read_json(base + '.status.json', "#{label} status")
      stdout = File.binread(plain_file!(base + '.stdout', "#{label} stdout"))
      stderr = File.binread(plain_file!(base + '.stderr', "#{label} stderr"))
      command = argv_override || clickhouse_argv(store, sql)
      assert!(argv.keys.sort == %w[argv environment label stdin_bytes stdin_sha256 timeout_seconds].sort &&
        argv.fetch('label') == label && argv.fetch('argv') == command, "#{label} argv differs from independent plan")
      assert!(argv.fetch('environment') == { 'TZ' => 'UTC' } && argv.fetch('timeout_seconds') == timeout,
        "#{label} environment/timeout differs")
      sql_bytes = File.binread(plain_file!(base + '.sql', "#{label} SQL"))
      assert!(sql_bytes == ((sql || '') + "\n").b, "#{label} exact SQL sidecar differs")
      stdin_path = base + '.stdin.bin'
      if stdin
        bytes = File.binread(plain_file!(stdin_path, "#{label} stdin"))
        assert!(bytes == stdin && argv.fetch('stdin_bytes') == stdin.bytesize &&
          argv.fetch('stdin_sha256') == Digest::SHA256.hexdigest(stdin), "#{label} input bytes/hash differ")
      else
        assert!(!File.exist?(stdin_path) && argv.fetch('stdin_bytes').nil? && argv.fetch('stdin_sha256').nil?,
          "#{label} unexpectedly has input")
      end
      fields = %w[label classification duration_ms exitstatus signaled termsig timed_out spawn_error stdout_bytes stderr_bytes]
      assert!(status.keys.sort == fields.sort && status.fetch('label') == label, "#{label} status roster differs")
      assert!(status.fetch('classification') == 'process_success' && status.fetch('exitstatus') == 0 &&
        status.fetch('signaled') == false && status.fetch('termsig').nil? && status.fetch('timed_out') == false &&
        status.fetch('spawn_error').nil?, "#{label} was not a successful process")
      assert!(status.fetch('duration_ms').is_a?(Integer) && status.fetch('duration_ms') >= 0 &&
        status.fetch('stdout_bytes') == stdout.bytesize && status.fetch('stderr_bytes') == stderr.bytesize,
        "#{label} status byte counts/duration disagree")
      assert!(label != 'helper-read-write-roundtrip' || argv.fetch('argv').first == helper,
        'helper invocation did not use the separately pinned helper path')
      { 'label' => label, 'stdout' => stdout, 'stderr' => stderr, 'status' => status, 'base' => base }
    end
  end

  def process_for(records, label)
    found = records.find { |item| item.fetch('label') == label }
    assert!(found, "missing raw process #{label}")
    found
  end

  def clean_status(record)
    record.fetch('status')
  end

  def expected_windows(profile, prefix, process_records)
    %w[full middle zero].to_h do |window|
      label = "#{prefix}-rowbinary-#{profile.fetch('id')}-#{window}"
      actual = process_for(process_records, label).fetch('stdout')
      expected = expected_window(profile, window)
      assert!(actual == expected, "#{label} differs from independent literal RowBinary")
      [window, { 'bytes' => actual.bytesize, 'sha256' => Digest::SHA256.hexdigest(actual),
        'matches_independent_literals' => true }]
    end
  end

  def expected_helper_input(source_root, evidence_root, fixture_profiles)
    generated = File.join(evidence_root, 'generated', 'parts')
    { 'format' => INPUT_FORMAT, 'capture_root' => source_root, 'generated_root' => generated,
      'profiles' => fixture_profiles.map do |profile|
        { 'id' => profile.fetch('id'), 'declared_type' => profile.fetch('type'),
          'source_part_path' => File.join(source_root, 'parts', profile.fetch('id'), 'all_1_1_0'),
          'library_part_path' => File.join(generated, profile.fetch('id'), 'all_1_1_0'),
          'row_keys' => ROW_KEYS, 'mark_rows' => MARK_ROWS, 'rows' => profile.fetch('rows'),
          'literal_rowbinary_hex' => literal_hex(profile) }
      end }
  end

  def source_profile_record(source_root, profile, processes)
    id = profile.fetch('id')
    table = "w232_stock_#{id}"
    check = process_for(processes, "stock-check-#{id}").fetch('stdout')
    schema = process_for(processes, "stock-schema-#{id}").fetch('stdout')
    assert!(check == "all_1_1_0\t1\t\n", "stock CHECK is not exact success for #{id}")
    assert!(schema == "id\tUInt64\nv\t#{profile.fetch('type')}\n", "stock schema differs for #{id}")
    fields = tsv_row!(process_for(processes, "stock-part-#{id}").fetch('stdout'), 5, "stock part #{id}")
    actual_path = File.expand_path(fields.fetch(4))
    store = File.join(source_root, 'stores', id)
    assert!(fields[0, 4] == ['all_1_1_0', '6', PHYSICAL_MARKS.to_s, 'Wide'], "stock part grid differs for #{id}")
    assert!(actual_path.start_with?(store + File::SEPARATOR), "stock part path escapes isolated store for #{id}")
    plain_dir!(actual_path, "stock part #{id}")
    captured = File.join(source_root, 'parts', id, 'all_1_1_0')
    actual_inventory = inventory(actual_path)
    captured_inventory = inventory(captured)
    assert!(actual_inventory == captured_inventory, "captured stock part differs from active part for #{id}")
    windows = expected_windows(profile, 'stock', processes)
    {
      'id' => id, 'declared_type' => profile.fetch('type'), 'table' => table, 'store' => store,
      'source_part_path' => captured, 'source_part_inventory' => captured_inventory,
      'rows' => profile.fetch('rows'), 'row_keys' => ROW_KEYS, 'mark_rows' => MARK_ROWS,
      'check_output' => check, 'schema_output' => schema,
      'literal_rowbinary_hex' => literal_hex(profile), 'windows' => windows,
      'processes' => %w[create insert check schema part].map do |kind|
        label = "stock-#{kind}-#{id}"
        clean_status(process_for(processes, label))
      end,
    }
  end

  def validate_scan!(scan, profile, label)
    full_hex = ROW_KEYS.each_index.map { |index| rowbinary(profile, index).unpack1('H*') }
    middle_hex = [2, 3].map { |index| rowbinary(profile, index).unpack1('H*') }
    expected_full_schedule = [[0, 0, 0, 0], [1, 0, 2, 2], [2, 0, 4, 4]]
    expected_middle_schedule = [[1, 0, 2, 2]]
    fields = %w[eof_callbacks exact_type_and_literal_checks full_rowbinary_hex full_rows full_schedule middle_rowbinary_hex middle_rows middle_schedule zero_mark_callbacks]
    assert!(scan.keys.sort == fields.sort, "#{label} typed scan output fields differ")
    assert!(scan.fetch('full_rows') == 6 && scan.fetch('middle_rows') == 2 &&
      scan.fetch('full_schedule') == expected_full_schedule && scan.fetch('middle_schedule') == expected_middle_schedule,
      "#{label} typed full/middle schedule differs")
    assert!(scan.fetch('full_rowbinary_hex') == full_hex && scan.fetch('middle_rowbinary_hex') == middle_hex,
      "#{label} typed full/middle RowBinary differs from independent fixture")
    assert!(scan.fetch('zero_mark_callbacks') == 0 && scan.fetch('eof_callbacks') == 0 &&
      scan.fetch('exact_type_and_literal_checks') == true, "#{label} typed zero/EOF/type evidence differs")
  end

  def validate_helper!(source_root, evidence_root, helper, helper_sha, helper_process, fixture_profiles)
    assert!(sha256_file(helper) == helper_sha, 'prebuilt helper hash changed from CLI pin')
    input_path = File.join(evidence_root, 'generated', 'helper-input.json')
    input = read_json(input_path, 'helper input manifest')
    expected_input = expected_helper_input(source_root, evidence_root, fixture_profiles)
    assert!(input == expected_input, 'helper input differs from independent literal profiles and roots')
    raw = helper_process.fetch('stdout')
    output = JSON.parse(raw.dup.force_encoding(Encoding::UTF_8))
    assert!(output.keys.sort == %w[format profile_count profiles].sort &&
      output.fetch('format') == HELPER_FORMAT && output.fetch('profile_count') == fixture_profiles.length,
      'helper raw stdout envelope differs')
    expected_input.fetch('profiles').zip(fixture_profiles).each_with_index do |(binding, profile), index|
      actual = output.fetch('profiles').fetch(index)
      fields = %w[declared_type id library_part_path library_rows_match_independent_literals mark_rows row_keys source_part_path source_rows_match_independent_literals source_scan library_scan]
      assert!(actual.keys.sort == fields.sort, "helper output fields differ for #{profile.fetch('id')}")
      %w[id declared_type library_part_path mark_rows row_keys source_part_path].each do |key|
        assert!(actual.fetch(key) == binding.fetch(key), "helper output #{key} binding differs for #{profile.fetch('id')}")
      end
      assert!(actual.fetch('source_rows_match_independent_literals') == true &&
        actual.fetch('library_rows_match_independent_literals') == true, "helper literal comparison failed for #{profile.fetch('id')}")
      validate_scan!(actual.fetch('source_scan'), profile, "#{profile.fetch('id')} source")
      validate_scan!(actual.fetch('library_scan'), profile, "#{profile.fetch('id')} library")
      source_part = binding.fetch('source_part_path')
      library_part = binding.fetch('library_part_path')
      assert!(!inventory(source_part).empty? && !inventory(library_part).empty?, "empty helper source/library part for #{profile.fetch('id')}")
    end
    copied = read_json(File.join(evidence_root, 'generated', 'helper-output.json'), 'helper output copy')
    assert!(copied == output, 'helper output copy differs from raw stdout')
    { 'output' => output, 'input_path' => input_path, 'input_sha256' => sha256_file(input_path),
      'stdout_sha256' => Digest::SHA256.hexdigest(raw) }
  rescue JSON::ParserError => error
    raise "W232 AUDIT FAIL: malformed helper stdout: #{error.message}"
  end

  def native_profile_record(evidence_root, profile, processes, helper_profile)
    id = profile.fetch('id')
    table = "w232_native_#{id}"
    store = File.join(evidence_root, 'stores', id)
    path_raw = process_for(processes, "native-data-path-#{id}").fetch('stdout')
    data_path = File.expand_path(path_raw.strip)
    assert!(data_path.start_with?(store + File::SEPARATOR), "native data path escapes isolated store for #{id}")
    plain_dir!(data_path, "native data path #{id}")
    plain_dir!(File.join(data_path, 'detached'), "native detached path #{id}")
    check = process_for(processes, "native-check-#{id}").fetch('stdout')
    schema = process_for(processes, "native-schema-#{id}").fetch('stdout')
    assert!(check == "all_1_1_0\t1\t\n", "native CHECK is not exact success for #{id}")
    assert!(schema == "id\tUInt64\nv\t#{profile.fetch('type')}\n", "native schema differs for #{id}")
    fields = tsv_row!(process_for(processes, "native-part-#{id}").fetch('stdout'), 5, "native part #{id}")
    attached = File.join(data_path, 'all_1_1_0')
    assert!(fields[0, 4] == ['all_1_1_0', '6', PHYSICAL_MARKS.to_s, 'Wide'] &&
      File.expand_path(fields.fetch(4)) == attached, "native part identity/path differs for #{id}")
    library = helper_profile.fetch('library_part_path')
    before = inventory(library)
    after = inventory(attached)
    removed, changed, added = inventory_delta(before, after)
    assert!(removed.empty? && changed.empty? && added == [INVALIDATED_FILE], "ATTACH inventory delta differs for #{id}")
    invalidated = File.binread(File.join(attached, INVALIDATED_FILE)).split("\n", -1)
    assert!(invalidated.pop == '' && invalidated.sort == INVALIDATED_NAMES.sort, "ATTACH invalidation file differs for #{id}")
    columns = File.binread(File.join(attached, 'columns.txt'))
    expected_columns = "columns format version: 1\n2 columns:\n`id` UInt64\n`v` #{profile.fetch('type')}\n".b
    assert!(columns == expected_columns, "attached columns metadata differs for #{id}")
    codec = File.binread(File.join(attached, 'default_compression_codec.txt')).strip
    metadata = File.binread(File.join(attached, 'metadata_version.txt')).strip
    assert!(codec == 'CODEC(LZ4)' && metadata == '0', "attached codec/metadata differs for #{id}")
    windows = expected_windows(profile, 'native', processes)
    record = {
      'id' => id, 'table' => table, 'declared_type' => profile.fetch('type'),
      'helper_part_path' => library, 'attached_part_path' => attached,
      'helper_part_inventory' => before, 'attached_part_inventory' => after,
      'removed_paths' => removed, 'changed_paths' => changed, 'added_paths' => added,
      'check_output' => check, 'schema_output' => schema,
      'columns_sha256' => Digest::SHA256.hexdigest(columns),
      'default_compression_codec' => codec, 'metadata_version' => metadata, 'windows' => windows,
      'processes' => %w[attach check schema part].map do |kind|
        clean_status(process_for(processes, "native-#{kind}-#{id}"))
      end,
    }
    assert!(read_json(File.join(evidence_root, 'cases', "#{id}.json"), "native case #{id}") == record,
      "native case record differs from independent reconstruction for #{id}")
    record
  end

  def verify_layout!(source_root, evidence_root, fixture_profiles)
    ids = fixture_profiles.map { |profile| profile.fetch('id') }
    assert!(Dir.children(source_root).sort == %w[cases invocations parts physical.after-helper.json physical.post.json physical.pre.json source-pin-post.json source-pin.json stores].sort,
      'stock root has unexpected/missing artifacts')
    assert!(Dir.children(evidence_root).sort == %w[cases generated invocations result.json stores].sort,
      'evidence root has unexpected/missing artifacts')
    assert!(Dir.children(File.join(source_root, 'parts')).sort == ids.sort, 'stock profile part directories differ')
    assert!(Dir.children(File.join(source_root, 'cases')).sort == (ids + ids.map { |id| "#{id}.json" }).sort,
      'stock case artifact roster differs')
    assert!(Dir.children(File.join(evidence_root, 'cases')).sort == (ids + ids.map { |id| "#{id}.json" }).sort,
      'native case artifact roster differs')
    ids.each do |id|
      assert!(Dir.children(File.join(source_root, 'cases', id)).empty? && Dir.children(File.join(evidence_root, 'cases', id)).empty?,
        "case scratch directory is not empty for #{id}")
      assert!(Dir.children(File.join(source_root, 'parts', id)).sort == ['all_1_1_0'] &&
        Dir.children(File.join(evidence_root, 'generated', 'parts', id)).sort == ['all_1_1_0'],
        "part directory roster differs for #{id}")
    end
    assert!(Dir.children(File.join(source_root, 'stores')).sort == (ids + ['pins']).sort &&
      Dir.children(File.join(evidence_root, 'stores')).sort == ids.sort, 'isolated store roster differs')
    assert!(Dir.children(File.join(evidence_root, 'generated')).sort == %w[helper-input.json helper-output.json library-physical.json parts].sort,
      'generated helper artifact roster differs')
  end

  def validate!(options)
    source_root = bounded_root!(options.fetch(:source_root), SOURCE_PREFIX, 'stock root')
    evidence_root = bounded_root!(options.fetch(:evidence_root), EVIDENCE_PREFIX, 'evidence root')
    helper = plain_file!(options.fetch(:helper), 'prebuilt Crystal helper', executable: true)
    helper_sha = options.fetch(:helper_sha256)
    assert!(/\A[0-9a-f]{64}\z/.match?(helper_sha), 'helper SHA pin must be lowercase 64-hex')
    assert!(sha256_file(helper) == helper_sha, 'helper file differs from CLI SHA pin')
    binary = plain_file!(CLICKHOUSE_BIN, 'separately pinned stock runtime', executable: true)
    assert!(binary == CLICKHOUSE_BIN && sha256_file(binary) == CLICKHOUSE_SHA256, 'runtime path/SHA pin differs')
    fixture_profiles = profiles
    verify_layout!(source_root, evidence_root, fixture_profiles)

    result = read_json(File.join(evidence_root, 'result.json'), 'runner result')
    assert!(result.fetch('format') == RESULT_FORMAT && result.fetch('classification') == 'paired_static_qbit_variant_profiles_observed' && result.fetch('success') == true,
      'runner result format/classification/success differs')
    assert!(result.fetch('source_root') == source_root && result.fetch('evidence_root') == evidence_root, 'result roots differ')
    source_pin = source_manifest
    assert!(result.fetch('source_pin') == source_pin &&
      read_json(File.join(source_root, 'source-pin.json'), 'source pin') == source_pin &&
      read_json(File.join(source_root, 'source-pin-post.json'), 'source pin post') == source_pin,
      'archived source pin differs from recomputed fixed source hashes')
    runtime_pin = { 'binary' => binary, 'sha256' => CLICKHOUSE_SHA256, 'version' => CLICKHOUSE_VERSION,
      'build_hash' => CLICKHOUSE_BUILD,
      'source_correlation' => 'runtime and source are separately pinned; no build identity claim' }
    assert!(result.fetch('runtime_pin') == runtime_pin, 'runtime version/build pin record differs')
    assert!(result.fetch('settings') == SETTINGS && result.fetch('variant_discriminator_mode') == 'BASIC',
      'Wide/LZ4/plain-mrk2/BASIC/typed-version mode differs')
    expected_scope = 'three fixed static QBit-in-Variant products: root Variant, Array(Variant), and Variant(Array, Map, Tuple); BASIC discriminator, no Dynamic/LowCardinality/Nullable or performance claim'
    assert!(result.fetch('scope') == expected_scope, 'result scope overstates or changes the fixed qualification boundary')

    source_plan, evidence_plan, input_path = invocations(source_root, evidence_root, helper)
    verify_invocation_directory!(source_root, source_plan)
    verify_invocation_directory!(evidence_root, evidence_plan)
    source_processes = verify_processes(source_root, source_plan, helper)
    evidence_processes = verify_processes(evidence_root, evidence_plan, helper)
    assert!(process_for(source_processes, 'runtime-version-pin').fetch('stdout').strip == CLICKHOUSE_VERSION,
      'raw runtime version differs')
    assert!(process_for(source_processes, 'runtime-build-pin').fetch('stdout').strip == "VERSION_GITHASH=#{CLICKHOUSE_BUILD}",
      'raw runtime build differs')
    expected_rosters = { 'source' => source_plan.map(&:first), 'evidence' => evidence_plan.map(&:first) }
    assert!(result.fetch('process_rosters') == expected_rosters, 'result process roster differs')
    expected_counts = { 'source_processes' => source_plan.length, 'evidence_processes' => evidence_plan.length,
      'profiles' => 3, 'source_parts' => 3, 'library_parts' => 3, 'attached_parts' => 3 }
    assert!(result.fetch('counts') == expected_counts && result.fetch('profile_count') == 3,
      'result process/profile counts differ')

    source_records = fixture_profiles.map { |profile| source_profile_record(source_root, profile, source_processes) }
    physical = source_records.map { |record| { 'id' => record.fetch('id'), 'inventory' => inventory(record.fetch('source_part_path')) } }
    expected_physical = { 'format' => 'recursive_qbit_variant_w232_source_physical_v1', 'profiles' => physical }
    %w[physical.pre.json physical.after-helper.json physical.post.json].each do |name|
      assert!(read_json(File.join(source_root, name), name) == expected_physical, "#{name} does not match current source part bytes")
    end
    assert!(result.fetch('stock_profiles') == source_records, 'result stock records differ from reconstructed captures')

    helper_process = process_for(evidence_processes, 'helper-read-write-roundtrip')
    helper_audit = validate_helper!(source_root, evidence_root, helper, helper_sha, helper_process, fixture_profiles)
    assert!(result.fetch('helper_path') == helper && result.fetch('helper_sha256_expected') == helper_sha &&
      result.fetch('helper_sha256_observed_after') == helper_sha, 'result helper hash/path binding differs')
    assert!(result.fetch('helper_input_path') == input_path && result.fetch('helper_input_sha256') == helper_audit.fetch('input_sha256') &&
      result.fetch('helper_stdout_sha256') == helper_audit.fetch('stdout_sha256') &&
      result.fetch('helper_output') == helper_audit.fetch('output'), 'result helper input/output hashes or content differ')
    helper_profiles = helper_audit.fetch('output').fetch('profiles')
    native_records = fixture_profiles.zip(helper_profiles).map do |profile, helper_profile|
      native_profile_record(evidence_root, profile, evidence_processes, helper_profile)
    end
    libraries = helper_profiles.map do |item|
      { 'id' => item.fetch('id'), 'path' => item.fetch('library_part_path'), 'inventory' => inventory(item.fetch('library_part_path')) }
    end
    assert!(read_json(File.join(evidence_root, 'generated', 'library-physical.json'), 'library physical') ==
      { 'format' => 'recursive_qbit_variant_w232_library_physical_v1', 'profiles' => libraries },
      'library physical inventory sidecar differs')
    assert!(result.fetch('library_inventories') == libraries && result.fetch('native_profiles') == native_records,
      'result library/native inventories differ from current part files and raw captures')

    code_pins = %w[
      scripts/recheck_recursive_qbit_variant_w232.rb
      scripts/check_recursive_qbit_variant_w232.cr
      scripts/check_recursive_qbit_variant_evidence_w232.rb
      scripts/recheck_aggregate_recursive_w224.rb
    ].to_h { |relative| [relative, sha256_file(File.join(REPO_ROOT, relative))] }
    assert!(result.fetch('code_pins') == code_pins, 'capture/helper/auditor/recorder code hash binding is stale')
    verify_capture_budget!(source_root)
    verify_capture_budget!(evidence_root)
    puts "W232 raw evidence audit: 3 static Variant/QBit profiles; #{source_plan.length} stock and #{evidence_plan.length} evidence processes; independent RowBinary, typed windows, CHECK, metadata and inventories agree."
    true
  end

  def main(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/check_recursive_qbit_variant_evidence_w232.rb --source-root ROOT --evidence-root ROOT --helper BIN --helper-sha256 SHA'
      opts.on('--source-root PATH') { |value| options[:source_root] = value }
      opts.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
      opts.on('--helper PATH') { |value| options[:helper] = value }
      opts.on('--helper-sha256 SHA') { |value| options[:helper_sha256] = value }
    end
    parser.parse!(argv)
    assert!(argv.empty? && %i[source_root evidence_root helper helper_sha256].all? { |key| options.key?(key) }, parser.to_s)
    validate!(options)
  rescue StandardError => error
    warn "W232 evidence audit failed: #{error.class}: #{error.message}"
    false
  end
end

exit(CheckRecursiveQBitVariantEvidenceW232.main(ARGV) ? 0 : 1) if $PROGRAM_NAME == __FILE__
