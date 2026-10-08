#!/usr/bin/env ruby
# Independent, read-only audit of raw W230 ClickHouse and library evidence.
# It does not invoke ClickHouse, Crystal, or the capture runner.

require 'digest'
require 'find'
require 'json'
require 'optparse'

module CheckRecursiveQBitEvidenceW230
  extend self

  REPO_ROOT = '/Users/sergey/Projects/Crystal/crystal-click'.freeze
  SOURCE_ROOT = '/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1'.freeze
  SOURCE_REVISION = '0ca8150d9b1d0886edb2e3b4ab65eebb768d0357'.freeze
  CLICKHOUSE_BIN = '/private/tmp/crystal-click-w216-runtime-recovery.DmL9Kw/clickhouse-stripped'.freeze
  CLICKHOUSE_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  CLICKHOUSE_VERSION = '26.10.1.1201'.freeze
  CLICKHOUSE_BUILD = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  SOURCE_PREFIX = 'crystal-click-w230-stock.'.freeze
  EVIDENCE_PREFIX = 'crystal-click-w230-evidence.'.freeze
  INPUT_FORMAT = 'recursive_qbit_w230_helper_input_v1'.freeze
  HELPER_FORMAT = 'recursive_qbit_w230_helper_v1'.freeze
  RESULT_FORMAT = 'recursive_qbit_w230_result_v1'.freeze
  PROCESS_TIMEOUT_SECONDS = 90
  HELPER_TIMEOUT_SECONDS = 600
  MEMORY_LIMIT_BYTES = 1_073_741_824
  ROW_KEYS = [1, 2, 3, 4, 5, 6].freeze
  MARK_ROWS = [2, 2, 2].freeze
  INVALIDATED_FILE = 'invalidated_system_columns.txt'.freeze
  INVALIDATED_NAMES = %w[_block_number _block_offset].freeze
  SETTINGS = [
    'index_granularity=2', 'index_granularity_bytes=10485760',
    'enable_mixed_granularity_parts=1', 'min_rows_for_wide_part=0',
    'min_bytes_for_wide_part=0', 'min_level_for_wide_part=0',
    'compress_marks=0', 'compress_primary_key=0', 'min_compress_block_size=0',
    'max_compress_block_size=4096', 'ratio_of_defaults_for_sparse_serialization=1.0',
    'compute_exact_num_defaults_for_sparse_columns=0', "default_compression_codec='LZ4'",
  ].freeze
  SOURCE_FILES = {
    'src/DataTypes/DataTypeQBit.cpp' => '9713cd968e6a8252bba54aaf9dd49cbe2e31edc9af7e4e1d473d74d435ce87d9',
    'src/DataTypes/DataTypeQBit.h' => '14ef033053d9585e42e84b26a50934836fe083d8f002b69a415ad698df276911',
    'src/DataTypes/Serializations/SerializationArray.cpp' => '825295e177ae7f406c1a1c155e0c9e17b4cc39f4747cb1f3fb327b54db043791',
    'src/DataTypes/Serializations/SerializationQBit.cpp' => '64a1638077a5807512dff9fb25ad310f5a8da80eb76d39d9c76d083d980fc5da',
    'src/DataTypes/Serializations/SerializationNullable.cpp' => '7f8f0f97725f21d196beabae47fefcc3bcb32e250f4a1f9a87b37f73eae7c43f',
    'src/DataTypes/Serializations/SerializationTuple.cpp' => '12e38b357204e005fc4780bac7e2e358b0a14357e0e246137414166062a1a884',
    'src/DataTypes/Serializations/ISerialization.cpp' => '87ca6647aeb0dd4022e3437a155f923f817d4447c547eff9ec29ab6876d16dd2',
    'src/DataTypes/DataTypeArray.h' => '660e6f37210922c200a7cbba5f25a0f01d579f79a51611768de72d1a3002be37',
    'src/DataTypes/DataTypeLowCardinality.cpp' => 'e75ef3196f929ed61313394fe8ba13c0a377446f73fac12f2b2425128d625c5c',
    'src/DataTypes/IDataType.h' => '6e9befee2cf642d989912710a4857c5a122fb7ba337eafc6b923c10f8eb33d5c',
  }.freeze
  BYTE_VALUES = {
    'Int8' => %w[fe ff 00 01 02 04 08 10 20].freeze,
    'BFloat16' => %w[00c0 80bf 0000 803f 0040 8040 0041 8041 0042].freeze,
    'Float32' => %w[000000c0 000080bf 00000000 0000803f 00000040 00008040 00000041 00008041 00000042].freeze,
    'Float64' => %w[00000000000000c0 000000000000f0bf 0000000000000000 000000000000f03f 0000000000000040 0000000000001040 0000000000002040 0000000000003040 0000000000004040].freeze,
  }.freeze
  CODES9 = [
    [0, 1, 2, 3, 4, 5, 6, 7, 8], [8, 7, 6, 5, 4, 3, 2, 1, 0],
    [2, 4, 6, 8, 0, 1, 3, 5, 7], [8, 6, 4, 2, 0, 7, 5, 3, 1],
    [1, 3, 5, 7, 0, 2, 4, 6, 8],
  ].freeze
  CODES16 = [
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 7, 6, 5, 4, 3, 2, 1],
    [8, 7, 6, 5, 4, 3, 2, 1, 0, 1, 2, 3, 4, 5, 6, 7],
    [2, 3, 4, 5, 6, 7, 8, 0, 1, 8, 7, 6, 5, 4, 3, 2],
    [6, 5, 4, 3, 2, 1, 0, 8, 7, 0, 1, 2, 3, 4, 5, 6],
    [1, 3, 5, 7, 0, 2, 4, 6, 8, 0, 8, 6, 4, 2, 1, 3],
  ].freeze
  CODES3 = [[0, 1, 2], [3, 4, 5], [6, 7, 8], [8, 7, 6], [5, 4, 3]].freeze
  TREE_ENTRY_CAP = 4_096
  TREE_BYTE_CAP = 64 * 1024 * 1024

  def assert!(condition, message)
    raise "W230 AUDIT FAIL: #{message}" unless condition
  end

  def plain_file!(path, label, executable: false)
    full = File.expand_path(path)
    assert!(!File.symlink?(full) && File.file?(full), "#{label} is not a plain file: #{full}")
    assert!(File.realpath(full) == full, "#{label} is not canonical: #{full}")
    assert!(!executable || File.executable?(full), "#{label} is not executable: #{full}")
    full
  end

  def plain_dir!(path, label)
    full = File.expand_path(path)
    assert!(!File.symlink?(full) && File.directory?(full), "#{label} is not a plain directory: #{full}")
    assert!(File.realpath(full) == full, "#{label} is not canonical: #{full}")
    full
  end

  def read_json(path, label)
    JSON.parse(File.binread(plain_file!(path, label)))
  rescue JSON::ParserError => error
    raise "W230 AUDIT FAIL: malformed #{label}: #{error.message}"
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

  def varuint(number)
    assert!(number.is_a?(Integer) && number >= 0 && number <= 18_446_744_073_709_551_615,
      "VarUInt outside unsigned 64-bit range: #{number.inspect}")
    result = []
    while number >= 0x80
      result << ((number & 0x7f) | 0x80)
      number >>= 7
    end
    (result << number).pack('C*').b
  end

  def uint64_le(number)
    assert!(number.is_a?(Integer) && number >= 0 && number <= 18_446_744_073_709_551_615,
      "UInt64 literal outside range: #{number.inspect}")
    Array.new(8) { |index| (number >> (index * 8)) & 0xff }.pack('C*').b
  end

  def vector(carrier, codes)
    BYTE_VALUES.fetch(carrier).values_at(*codes).join
  end

  def vector16(index)
    vector('BFloat16', CODES16.fetch(index))
  end

  def fixture_profiles
    vectors = CODES9.map { |codes| BYTE_VALUES.to_h { |carrier, values| [carrier, values.values_at(*codes).join] } }
    simple = %w[Int8 BFloat16 Float32 Float64].map do |carrier|
      { 'id' => "array_qbit_#{carrier.downcase}_9", 'declared_type' => "Array(QBit(#{carrier}, 9))",
        'carrier' => carrier, 'dimension' => 9, 'wrapper' => 'flat',
        'rows' => [[vectors[0].fetch(carrier), vectors[1].fetch(carrier)], [], [], [],
          [vectors[2].fetch(carrier), vectors[3].fetch(carrier)], [vectors[4].fetch(carrier)]] }
    end
    nested3 = CODES3.map { |codes| vector('Int8', codes) }
    simple + [
      { 'id' => 'array_qbit_bfloat16_16_stride8', 'declared_type' => 'Array(QBit(BFloat16, 16, 8))',
        'carrier' => 'BFloat16', 'dimension' => 16, 'wrapper' => 'flat',
        'rows' => [[vector16(0), vector16(1)], [], [], [], [vector16(2), vector16(3)], [vector16(4)]] },
      { 'id' => 'array_nullable_qbit_bfloat16_16', 'declared_type' => 'Array(Nullable(QBit(BFloat16, 16)))',
        'carrier' => 'BFloat16', 'dimension' => 16, 'wrapper' => 'nullable',
        'rows' => [[vector16(0), nil], [], [], [], [vector16(1), vector16(2)], [vector16(3)]] },
      { 'id' => 'array_array_qbit_int8_3', 'declared_type' => 'Array(Array(QBit(Int8, 3)))',
        'carrier' => 'Int8', 'dimension' => 3, 'wrapper' => 'nested',
        'rows' => [[[nested3[0], nested3[1]], []], [], [], [], [[nested3[2]], [nested3[3]]], [[nested3[4]]]] },
      { 'id' => 'array_qbit_bfloat16_16_all_empty', 'declared_type' => 'Array(QBit(BFloat16, 16))',
        'carrier' => 'BFloat16', 'dimension' => 16, 'wrapper' => 'flat',
        'rows' => [[], [], [], [], [], []] },
    ]
  end

  def qbit_bytes(profile, value_hex)
    raw = [value_hex].pack('H*').b
    bytes_per_value = BYTE_VALUES.fetch(profile.fetch('carrier')).first.size / 2
    assert!(raw.bytesize == bytes_per_value * profile.fetch('dimension'),
      "fixture QBit byte width differs for #{profile.fetch('id')}")
    varuint(profile.fetch('dimension')) + raw
  end

  def array_bytes(values)
    varuint(values.length) + values.join.b
  end

  def value_bytes(profile, value)
    case profile.fetch('wrapper')
    when 'flat'
      array_bytes(value.map { |item| qbit_bytes(profile, item) })
    when 'nullable'
      array_bytes(value.map { |item| item.nil? ? "\x01".b : "\x00".b + qbit_bytes(profile, item) })
    when 'nested'
      array_bytes(value.map { |child| array_bytes(child.map { |item| qbit_bytes(profile, item) }) })
    else
      raise "W230 AUDIT FAIL: unrecognized fixture wrapper #{profile.fetch('wrapper').inspect}"
    end
  end

  def literal_rowbinary(profile, index)
    uint64_le(ROW_KEYS.fetch(index)) + value_bytes(profile, profile.fetch('rows').fetch(index))
  end

  def literal_rowbinary_hex(profile)
    profile.fetch('rows').each_index.map { |index| literal_rowbinary(profile, index).unpack1('H*') }
  end

  def occurrence_grid(profile)
    profile.fetch('rows').each_slice(2).map do |mark|
      mark.sum do |row|
        case profile.fetch('wrapper')
        when 'flat', 'nullable' then row.length
        when 'nested' then row.sum(&:length)
        end
      end
    end
  end

  def selected_rows(profile, window)
    case window
    when 'full' then (0...6).to_a
    when 'middle' then [2, 3]
    when 'all-empty' then profile.fetch('rows').each_index.select { |index| profile.fetch('rows').fetch(index).empty? }
    when 'zero' then []
    else raise "W230 AUDIT FAIL: unknown fixed window #{window}"
    end
  end

  def expected_window(profile, window)
    selected_rows(profile, window).map { |index| literal_rowbinary(profile, index) }.join.b
  end

  def expected_sql_create(table, profile)
    "CREATE TABLE default.#{table} (id UInt64, q #{profile.fetch('declared_type')} CODEC(LZ4)) " \
      "ENGINE=MergeTree ORDER BY id SETTINGS #{SETTINGS.join(', ')}"
  end

  def table_name(profile, kind)
    "w230_#{kind}_#{profile.fetch('id')}"
  end

  def part_query(table)
    "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw"
  end

  def schema_query(table)
    "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw"
  end

  def check_query(table)
    "CHECK TABLE default.#{table} FORMAT TSVRaw"
  end

  def rowbinary_query(table, window)
    predicate = case window
                when 'full' then ''
                when 'middle' then ' WHERE id BETWEEN 3 AND 4'
                when 'all-empty' then ' WHERE length(q)=0'
                when 'zero' then ' WHERE id=0'
                end
    "SELECT id, q FROM default.#{table}#{predicate} ORDER BY id FORMAT RowBinary"
  end

  def rowbinary_windows(recorder_prefix, table, profile)
    %w[full middle all-empty zero].map do |window|
      ["#{recorder_prefix}-rowbinary-#{profile.fetch('id')}-#{window}",
       rowbinary_query(table, window), expected_window(profile, window)]
    end
  end

  def clickhouse_argv(store, sql)
    [CLICKHOUSE_BIN, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
      '--max_insert_threads=1', '--max_execution_time=30', "--max_memory_usage=#{MEMORY_LIMIT_BYTES}",
      '--print_pretty_type_names=0', '--multiquery', '--query', sql]
  end

  def expected_invocations(source_root, evidence_root, helper)
    source = []
    pin_store = File.join(source_root, 'stores', 'pins')
    source << ['runtime-version-pin', pin_store, 'SELECT version() FORMAT TSVRaw', nil]
    source << ['runtime-build-pin', pin_store,
      "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw", nil]
    profiles = fixture_profiles
    profiles.each do |profile|
      table = table_name(profile, 'stock')
      store = File.join(source_root, 'stores', profile.fetch('id'))
      insert = profile.fetch('rows').each_index.map { |index| literal_rowbinary(profile, index) }.join.b
      source << ["stock-create-#{profile.fetch('id')}", store, expected_sql_create(table, profile), nil]
      source << ["stock-insert-#{profile.fetch('id')}", store, "INSERT INTO default.#{table} FORMAT RowBinary", insert]
      source << ["stock-check-#{profile.fetch('id')}", store, check_query(table), nil]
      source << ["stock-schema-#{profile.fetch('id')}", store, schema_query(table), nil]
      source << ["stock-part-#{profile.fetch('id')}", store, part_query(table), nil]
      source.concat(rowbinary_windows('stock', table, profile).map do |label, sql, _bytes|
        [label, store, sql, nil]
      end)
    end

    generated_root = File.join(evidence_root, 'generated', 'parts')
    input_path = File.join(evidence_root, 'generated', 'helper-input.json')
    helper_argv = [helper, '--input', input_path]
    evidence = [['helper-read-write-roundtrip', File.join(evidence_root, 'generated'), nil, nil, helper_argv]]
    profiles.each do |profile|
      table = table_name(profile, 'native')
      store = File.join(evidence_root, 'stores', profile.fetch('id'))
      evidence << ["native-create-#{profile.fetch('id')}", store, expected_sql_create(table, profile), nil]
      evidence << ["native-data-path-#{profile.fetch('id')}", store,
        "SELECT arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw", nil]
      evidence << ["native-attach-#{profile.fetch('id')}", store,
        "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'", nil]
      evidence << ["native-check-#{profile.fetch('id')}", store, check_query(table), nil]
      evidence << ["native-schema-#{profile.fetch('id')}", store, schema_query(table), nil]
      evidence << ["native-part-#{profile.fetch('id')}", store, part_query(table), nil]
      evidence.concat(rowbinary_windows('native', table, profile).map do |label, sql, _bytes|
        [label, store, sql, nil]
      end)
    end
    [source, evidence]
  end

  def inventory(part)
    full = plain_dir!(part, 'part directory')
    entries = []
    count = 0
    bytes = 0
    Find.find(full) do |path|
      next if path == full
      count += 1
      assert!(count <= TREE_ENTRY_CAP, "part exceeds entry cap: #{full}")
      assert!(!File.symlink?(path), "part contains symlink: #{path}")
      next if File.directory?(path)
      assert!(File.file?(path), "part contains unsupported entry: #{path}")
      bytes += File.size(path)
      assert!(bytes <= TREE_BYTE_CAP, "part exceeds byte cap: #{full}")
      entries << { 'path' => path[(full.length + 1)..-1], 'size' => File.size(path), 'sha256' => sha256_file(path) }
    end
    entries.sort_by { |entry| entry.fetch('path') }
  end

  def parse_tsv(bytes, label)
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    assert!(text.valid_encoding?, "#{label} is not valid UTF-8 TSV")
    lines = text.lines.map { |line| line.chomp.sub(/\r\z/, '') }
    lines.map { |line| line.split("\t", -1) }
  end

  def one_tsv_row(bytes, count, label)
    rows = parse_tsv(bytes, label)
    assert!(rows.length == 1 && rows.first.length == count, "#{label} is not exactly one #{count}-field row: #{rows.inspect}")
    rows.first
  end

  def window_report(profile, prefix, process_records)
    %w[full middle all-empty zero].to_h do |window|
      label = "#{prefix}-rowbinary-#{profile.fetch('id')}-#{window}"
      record = process_records.find { |item| item.fetch('label') == label }
      assert!(record, "missing raw RowBinary process #{label}")
      bytes = record.fetch('stdout')
      assert!(bytes == expected_window(profile, window), "raw #{label} differs from fixed RowBinary bytes")
      [window, { 'bytes' => bytes.bytesize, 'sha256' => Digest::SHA256.hexdigest(bytes),
        'matches_independent_literal' => true }]
    end
  end

  def verify_process!(root, expected, index, helper_path)
    label, store, sql, input, argv_override = expected
    stem = format('%04d-%s', index + 1, label.gsub(/[^A-Za-z0-9_.-]/, '_'))
    base = File.join(root, 'invocations', stem)
    argv_record = read_json(base + '.argv.json', "#{label} argv")
    status = read_json(base + '.status.json', "#{label} status")
    stdout_path = plain_file!(base + '.stdout', "#{label} stdout")
    stderr_path = plain_file!(base + '.stderr', "#{label} stderr")
    stdout = File.binread(stdout_path)
    stderr = File.binread(stderr_path)
    expected_argv = argv_override || clickhouse_argv(store, sql)
    expected_timeout = label == 'helper-read-write-roundtrip' ? HELPER_TIMEOUT_SECONDS : PROCESS_TIMEOUT_SECONDS
    assert!(argv_record.keys.sort == %w[argv environment label stdin_bytes stdin_sha256 timeout_seconds].sort,
      "#{label} argv record fields differ")
    assert!(argv_record.fetch('label') == label && argv_record.fetch('argv') == expected_argv,
      "#{label} actual argv differs from fixed process plan")
    assert!(argv_record.fetch('environment') == { 'TZ' => 'UTC' } && argv_record.fetch('timeout_seconds') == expected_timeout,
      "#{label} process environment or timeout differs")
    sql_bytes = File.binread(plain_file!(base + '.sql', "#{label} SQL"))
    assert!(sql_bytes == (sql || "") + "\n", "#{label} SQL sidecar differs from fixed query")
    stdin_path = base + '.stdin.bin'
    if input
      actual_input = File.binread(plain_file!(stdin_path, "#{label} stdin"))
      assert!(actual_input == input, "#{label} literal RowBinary stdin differs")
      assert!(argv_record.fetch('stdin_bytes') == input.bytesize &&
        argv_record.fetch('stdin_sha256') == Digest::SHA256.hexdigest(input), "#{label} stdin metadata differs")
    else
      assert!(!File.exist?(stdin_path) && argv_record.fetch('stdin_bytes').nil? && argv_record.fetch('stdin_sha256').nil?,
        "#{label} unexpectedly records stdin")
    end
    assert!(status.fetch('classification') == 'process_success' && status.fetch('exitstatus') == 0 &&
      status.fetch('signaled') == false && status.fetch('timed_out') == false && status.fetch('spawn_error').nil?,
      "#{label} did not succeed as a process")
    assert!(status.fetch('stdout_bytes') == stdout.bytesize && status.fetch('stderr_bytes') == stderr.bytesize,
      "#{label} captured process byte counts differ from raw sidecars")
    assert!(status.fetch('duration_ms').is_a?(Integer) && status.fetch('duration_ms') >= 0,
      "#{label} raw status duration is invalid")
    if label == 'helper-read-write-roundtrip'
      assert!(argv_record.fetch('argv').first == helper_path, 'helper process did not use the externally pinned helper')
    end
    { 'label' => label, 'base' => base, 'stdout' => stdout, 'stderr' => stderr, 'status' => status }
  end

  def verify_invocation_directory!(root, expected)
    directory = plain_dir!(File.join(root, 'invocations'), 'invocation directory')
    expected_files = expected.each_with_index.flat_map do |entry, index|
      label = entry.fetch(0)
      stem = format('%04d-%s', index + 1, label.gsub(/[^A-Za-z0-9_.-]/, '_'))
      suffixes = %w[.argv.json .sql .stdout .stderr .status.json]
      suffixes << '.stdin.bin' if entry[3]
      suffixes.map { |suffix| stem + suffix }
    end.sort
    actual_files = Dir.children(directory).sort
    assert!(actual_files == expected_files, "invocation artifact roster differs: expected #{expected_files.length} files, saw #{actual_files.length}")
  end

  def expected_helper_input(source_root, evidence_root)
    generated_root = File.join(evidence_root, 'generated', 'parts')
    { 'format' => INPUT_FORMAT, 'capture_root' => source_root, 'generated_root' => generated_root,
      'profiles' => fixture_profiles.map do |profile|
        { 'id' => profile.fetch('id'), 'declared_type' => profile.fetch('declared_type'),
          'source_part_path' => File.join(source_root, 'parts', profile.fetch('id'), 'all_1_1_0'),
          'library_part_path' => File.join(generated_root, profile.fetch('id'), 'all_1_1_0'),
          'row_keys' => ROW_KEYS, 'mark_rows' => MARK_ROWS, 'rows' => profile.fetch('rows'),
          'literal_rowbinary_hex' => literal_rowbinary_hex(profile) }
      end }
  end

  def validate_stock!(source_root, profile, source_processes)
    id = profile.fetch('id')
    table = table_name(profile, 'stock')
    find = lambda do |label|
      record = source_processes.find { |item| item.fetch('label') == label }
      assert!(record, "missing raw stock process #{label}")
      record
    end
    check = find.call("stock-check-#{id}")
    assert!(check.fetch('stdout') == "all_1_1_0\t1\t\n", "stock CHECK for #{id} must contain exactly success and empty message")
    schema = find.call("stock-schema-#{id}")
    assert!(schema.fetch('stdout') == "id\tUInt64\nq\t#{profile.fetch('declared_type')}\n", "stock schema differs for #{id}")
    part_fields = one_tsv_row(find.call("stock-part-#{id}").fetch('stdout'), 5, "stock part census #{id}")
    assert!(part_fields[0, 4] == ['all_1_1_0', '6', '4', 'Wide'], "stock part identity/grid differs for #{id}")
    source_store = File.join(source_root, 'stores', id)
    stock_part = File.expand_path(part_fields[4])
    assert!(stock_part.start_with?(source_store + File::SEPARATOR), "stock part path escaped isolated store for #{id}")
    source_copy = File.join(source_root, 'parts', id, 'all_1_1_0')
    assert!(inventory(stock_part) == inventory(source_copy), "captured copy does not match stock part bytes for #{id}")
    expected_grid = id == 'array_qbit_bfloat16_16_all_empty' ? [0, 0, 0] : [2, 0, 3]
    assert!(occurrence_grid(profile) == expected_grid, "fixture leaf occurrences differ for #{id}")
    %w[full middle all-empty zero].each do |window|
      record = find.call("stock-rowbinary-#{id}-#{window}")
      assert!(record.fetch('stdout') == expected_window(profile, window), "stock #{window} RowBinary differs for #{id}")
    end
    [source_copy, stock_part].each { |path| plain_dir!(path, "stock source part #{id}") }
    { 'id' => id, 'source_part_path' => source_copy, 'source_inventory' => inventory(source_copy),
      'stock_part_path' => stock_part }
  end

  def validate_helper!(evidence_root, source_root, helper, expected_sha, helper_process)
    helper_path = plain_file!(helper, 'prebuilt helper', executable: true)
    assert!(sha256_file(helper_path) == expected_sha, 'prebuilt helper current SHA-256 differs from external pin')
    input_path = File.join(evidence_root, 'generated', 'helper-input.json')
    input = read_json(input_path, 'helper input')
    expected_input = expected_helper_input(source_root, evidence_root)
    assert!(input == expected_input, 'helper input differs from the independent fixed fixture')
    helper_output = JSON.parse(helper_process.fetch('stdout').force_encoding(Encoding::UTF_8))
    assert!(helper_output.fetch('format') == HELPER_FORMAT && helper_output.fetch('profile_count') == 8,
      'helper stdout magic/profile count differs')
    expected_profiles = expected_input.fetch('profiles')
    actual_profiles = helper_output.fetch('profiles')
    assert!(actual_profiles.length == expected_profiles.length, 'helper profile count differs')
    actual_profiles.zip(expected_profiles).each do |actual, expected|
      fields = %w[declared_type id library_part_path library_rows mark_rows row_keys source_part_path source_rows]
      assert!(actual.keys.sort == fields.sort, "helper output field roster differs for #{expected.fetch('id')}")
      %w[id declared_type library_part_path mark_rows row_keys source_part_path].each do |field|
        assert!(actual.fetch(field) == expected.fetch(field), "helper #{field} differs for #{expected.fetch('id')}")
      end
      assert!(actual.fetch('source_rows') == expected.fetch('rows') && actual.fetch('library_rows') == expected.fetch('rows'),
        "helper observed recursive rows differ for #{expected.fetch('id')}")
      source_part = expected.fetch('source_part_path')
      library_part = expected.fetch('library_part_path')
      assert!(inventory(source_part).length > 0, "stock source part inventory is empty for #{expected.fetch('id')}")
      assert!(library_part.start_with?(File.join(evidence_root, 'generated', 'parts') + File::SEPARATOR),
        "helper output part escaped generated root for #{expected.fetch('id')}")
      assert!(inventory(library_part).length > 0, "helper library part inventory is empty for #{expected.fetch('id')}")
    end
    helper_copy = read_json(File.join(evidence_root, 'generated', 'helper-output.json'), 'helper output copy')
    assert!(helper_copy == helper_output, 'helper output copy differs from raw stdout JSON')
    { 'output' => helper_output, 'input_sha256' => sha256_file(input_path),
      'stdout_sha256' => Digest::SHA256.hexdigest(helper_process.fetch('stdout')) }
  rescue JSON::ParserError => error
    raise "W230 AUDIT FAIL: helper stdout is not valid JSON: #{error.message}"
  end

  def validate_native!(evidence_root, profile, native_processes, helper_profile)
    id = profile.fetch('id')
    table = table_name(profile, 'native')
    find = lambda do |label|
      record = native_processes.find { |item| item.fetch('label') == label }
      assert!(record, "missing raw native process #{label}")
      record
    end
    store = File.join(evidence_root, 'stores', id)
    data_path_row = find.call("native-data-path-#{id}").fetch('stdout').strip
    data_path = File.expand_path(data_path_row)
    assert!(data_path.start_with?(store + File::SEPARATOR), "native data path escaped isolated store for #{id}")
    plain_dir!(File.join(data_path, 'detached'), "native detached directory #{id}")
    check = find.call("native-check-#{id}").fetch('stdout')
    assert!(check == "all_1_1_0\t1\t\n", "native CHECK for #{id} must contain exactly success and empty message")
    schema = find.call("native-schema-#{id}").fetch('stdout')
    assert!(schema == "id\tUInt64\nq\t#{profile.fetch('declared_type')}\n", "native schema differs for #{id}")
    fields = one_tsv_row(find.call("native-part-#{id}").fetch('stdout'), 5, "native part census #{id}")
    attached = File.join(data_path, 'all_1_1_0')
    assert!(fields[0, 4] == ['all_1_1_0', '6', '4', 'Wide'] && File.expand_path(fields[4]) == attached,
      "native attached part identity/grid/path differs for #{id}")
    generated = helper_profile.fetch('library_part_path')
    generated_files = inventory(generated)
    attached_files = inventory(attached)
    before = generated_files.to_h { |item| [item.fetch('path'), item] }
    after = attached_files.to_h { |item| [item.fetch('path'), item] }
    removed = before.keys - after.keys
    changed = before.keys.select { |path| after.key?(path) && before.fetch(path) != after.fetch(path) }
    added = after.keys - before.keys
    assert!(removed.empty? && changed.empty? && added == [INVALIDATED_FILE],
      "ATTACH changed unexpected part files for #{id}: removed=#{removed.inspect}, changed=#{changed.inspect}, added=#{added.inspect}")
    aux = File.binread(File.join(attached, INVALIDATED_FILE)).split("\n", -1)
    assert!(aux.pop == '' && aux.sort == INVALIDATED_NAMES.sort, "ATTACH invalidation file differs for #{id}")
    expected_columns = "columns format version: 1\n2 columns:\n`id` UInt64\n`q` #{profile.fetch('declared_type')}\n"
    assert!(File.binread(File.join(attached, 'columns.txt')) == expected_columns, "attached columns.txt differs for #{id}")
    assert!(File.binread(File.join(attached, 'default_compression_codec.txt')).strip == 'CODEC(LZ4)',
      "attached compression codec differs for #{id}")
    assert!(File.binread(File.join(attached, 'metadata_version.txt')).strip == '0', "attached metadata version differs for #{id}")
    %w[full middle all-empty zero].each do |window|
      actual = find.call("native-rowbinary-#{id}-#{window}").fetch('stdout')
      assert!(actual == expected_window(profile, window), "native #{window} RowBinary differs for #{id}")
    end
    { 'id' => id, 'attached_part_path' => attached, 'helper_part_path' => generated,
      'helper_part_inventory' => generated_files, 'attached_part_inventory' => attached_files,
      'check_output' => check }
  end

  def validate!(options)
    source_root = bounded_root!(options.fetch(:source_root), SOURCE_PREFIX, 'stock source root')
    evidence_root = bounded_root!(options.fetch(:evidence_root), EVIDENCE_PREFIX, 'evidence root')
    helper = File.expand_path(options.fetch(:helper))
    expected_helper_sha = options.fetch(:helper_sha256)
    assert!(/\A[0-9a-f]{64}\z/.match?(expected_helper_sha), 'external helper SHA must be lowercase SHA-256')
    binary = plain_file!(CLICKHOUSE_BIN, 'pinned ClickHouse binary', executable: true)
    assert!(sha256_file(binary) == CLICKHOUSE_SHA256, 'pinned ClickHouse binary SHA differs')

    result = read_json(File.join(evidence_root, 'result.json'), 'runner result')
    assert!(result.fetch('format') == RESULT_FORMAT && result.fetch('classification') == 'paired_recursive_qbit_profiles_observed' && result.fetch('success') == true,
      'runner result status/format differs')
    assert!(result.fetch('source_root') == source_root && result.fetch('evidence_root') == evidence_root,
      'runner result roots differ from auditor arguments')
    assert!(result.fetch('runtime_pin') == { 'binary' => binary, 'sha256' => CLICKHOUSE_SHA256,
      'version' => CLICKHOUSE_VERSION, 'build_hash' => CLICKHOUSE_BUILD,
      'source_correlation' => 'runtime binary and pinned source checkout are separate pins' }, 'runtime pin differs')
    actual_source_pin = source_manifest
    assert!(result.fetch('source_pin') == actual_source_pin, 'result source pin differs from recomputed pinned source hashes')
    assert!(read_json(File.join(source_root, 'source-pin.json'), 'source pin') == actual_source_pin &&
      read_json(File.join(source_root, 'source-pin-post.json'), 'source pin post') == actual_source_pin,
      'captured source pin artifacts differ from pinned source files')
    assert!(result.fetch('helper_path') == helper && result.fetch('helper_sha256_expected') == expected_helper_sha &&
      result.fetch('helper_sha256_observed_after') == expected_helper_sha, 'result helper pin differs from external helper pin')

    source_expected, evidence_expected = expected_invocations(source_root, evidence_root, helper)
    verify_invocation_directory!(source_root, source_expected)
    verify_invocation_directory!(evidence_root, evidence_expected)
    source_processes = source_expected.each_with_index.map do |expected, index|
      verify_process!(source_root, expected, index, helper)
    end
    evidence_processes = evidence_expected.each_with_index.map do |expected, index|
      verify_process!(evidence_root, expected, index, helper)
    end
    assert!(source_processes.first.fetch('stdout').strip == CLICKHOUSE_VERSION, 'raw runtime version differs')
    assert!(source_processes[1].fetch('stdout').strip == "VERSION_GITHASH=#{CLICKHOUSE_BUILD}", 'raw runtime build hash differs')
    assert!(result.fetch('process_rosters') == {
      'source' => source_expected.map(&:first), 'evidence' => evidence_expected.map(&:first) }, 'result process roster differs from raw invocation roster')
    assert!(result.fetch('counts') == { 'source_processes' => source_expected.length,
      'evidence_processes' => evidence_expected.length, 'profiles' => 8, 'source_parts' => 8,
      'library_parts' => 8, 'attached_parts' => 8 }, 'result process/profile counts differ from fixed roster')

    profile_fixtures = fixture_profiles
    stock_profiles = profile_fixtures.map do |profile|
      validate_stock!(source_root, profile, source_processes)
    end
    recorded_stock = result.fetch('stock_profiles')
    assert!(recorded_stock.length == profile_fixtures.length, 'result stock profile count differs')
    profile_fixtures.zip(stock_profiles, recorded_stock).each do |profile, observed, recorded|
      id = profile.fetch('id')
      assert!(recorded.fetch('id') == id && recorded.fetch('declared_type') == profile.fetch('declared_type') &&
        recorded.fetch('table') == table_name(profile, 'stock') && recorded.fetch('source_part_path') == observed.fetch('source_part_path') &&
        recorded.fetch('source_part_inventory') == observed.fetch('source_inventory') && recorded.fetch('rows') == profile.fetch('rows') &&
        recorded.fetch('row_keys') == ROW_KEYS && recorded.fetch('mark_rows') == MARK_ROWS &&
        recorded.fetch('leaf_slots_per_mark') == occurrence_grid(profile), "result stock profile differs from raw source for #{id}")
      check = source_processes.find { |item| item.fetch('label') == "stock-check-#{id}" }.fetch('stdout')
      schema = source_processes.find { |item| item.fetch('label') == "stock-schema-#{id}" }.fetch('stdout')
      assert!(recorded.fetch('check_output') == check && recorded.fetch('schema_output') == schema &&
        recorded.fetch('windows') == window_report(profile, 'stock', source_processes),
        "result stock observations differ from raw process files for #{id}")
      assert!(read_json(File.join(source_root, 'cases', id + '.json'), "stock case #{id}") == recorded,
        "stock case copy differs from result for #{id}")
    end
    source_inventory = stock_profiles.map { |item| { 'id' => item.fetch('id'), 'inventory' => item.fetch('source_inventory') } }
    pre = read_json(File.join(source_root, 'physical.pre.json'), 'stock physical pre-inventory')
    after_helper = read_json(File.join(source_root, 'physical.after-helper.json'), 'stock physical after-helper inventory')
    post = read_json(File.join(source_root, 'physical.post.json'), 'stock physical post-inventory')
    assert!(pre == { 'format' => 'recursive_qbit_w230_physical_v1', 'profiles' => source_inventory } &&
      after_helper == pre && post == pre,
      'source raw physical inventory differs from recomputed part bytes')

    helper_process = evidence_processes.fetch(0)
    helper_audit = validate_helper!(evidence_root, source_root, helper, expected_helper_sha, helper_process)
    assert!(result.fetch('helper_input_path') == File.join(evidence_root, 'generated', 'helper-input.json') &&
      result.fetch('helper_input_sha256') == helper_audit.fetch('input_sha256'), 'result helper input path/hash differs from raw input')
    assert!(result.fetch('helper_stdout_sha256') == helper_audit.fetch('stdout_sha256'), 'result helper stdout digest differs from raw stdout')
    assert!(result.fetch('helper_output') == helper_audit.fetch('output'), 'result helper output differs from raw stdout JSON')

    helper_profiles = helper_audit.fetch('output').fetch('profiles')
    native_profiles = profile_fixtures.zip(helper_profiles).map do |profile, helper_profile|
      validate_native!(evidence_root, profile, evidence_processes, helper_profile)
    end
    library_inventory = helper_profiles.map do |item|
      { 'id' => item.fetch('id'), 'path' => item.fetch('library_part_path'),
        'inventory' => inventory(item.fetch('library_part_path')) }
    end
    assert!(read_json(File.join(evidence_root, 'generated', 'library-physical.json'), 'library physical inventory') ==
      { 'format' => 'recursive_qbit_w230_library_physical_v1', 'profiles' => library_inventory },
      'library physical inventory copy differs from recomputed part bytes')
    assert!(result.fetch('library_inventories') == library_inventory, 'result library inventory differs from raw generated parts')
    assert!(result.fetch('native_profiles').length == native_profiles.length, 'result native profile count differs')
    native_profiles.each_with_index do |native, index|
      recorded = result.fetch('native_profiles').fetch(index)
      assert!(recorded.fetch('id') == native.fetch('id') && recorded.fetch('check_output') == "all_1_1_0\t1\t\n" &&
        recorded.fetch('attached_part_inventory') == native.fetch('attached_part_inventory') &&
        recorded.fetch('helper_part_inventory') == native.fetch('helper_part_inventory') &&
        recorded.fetch('attached_part_path') == native.fetch('attached_part_path') &&
        recorded.fetch('helper_part_path') == native.fetch('helper_part_path'),
        "result native profile disagrees with raw evidence for #{native.fetch('id')}")
      profile = profile_fixtures.fetch(index)
      raw_schema = evidence_processes.find { |item| item.fetch('label') == "native-schema-#{native.fetch('id')}" }.fetch('stdout')
      assert!(recorded.fetch('schema_output') == raw_schema &&
        recorded.fetch('windows') == window_report(profile, 'native', evidence_processes),
        "result native observations differ from raw process files for #{native.fetch('id')}")
      assert!(read_json(File.join(evidence_root, 'cases', native.fetch('id') + '.json'),
        "native case #{native.fetch('id')}") == recorded, "native case copy differs from result for #{native.fetch('id')}")
    end
    runner_path = File.join(REPO_ROOT, 'scripts', 'recheck_recursive_qbit_w230.rb')
    auditor_path = File.join(REPO_ROOT, 'scripts', 'check_recursive_qbit_evidence_w230.rb')
    actual_code_pins = {
      'scripts/recheck_recursive_qbit_w230.rb' => sha256_file(runner_path),
      'scripts/check_recursive_qbit_evidence_w230.rb' => sha256_file(auditor_path),
    }
    assert!(result.fetch('code_pins') == actual_code_pins, 'runner/auditor code pins are stale')
    puts "W230 raw evidence audit: 8 profiles, #{source_expected.length} source and #{evidence_expected.length} evidence processes; raw CHECK/RowBinary/part bytes agree."
    true
  end

  def main(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/check_recursive_qbit_evidence_w230.rb --source-root ROOT --evidence-root ROOT --helper BIN --helper-sha256 SHA'
      opts.on('--source-root PATH') { |value| options[:source_root] = value }
      opts.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
      opts.on('--helper PATH') { |value| options[:helper] = value }
      opts.on('--helper-sha256 SHA') { |value| options[:helper_sha256] = value }
    end
    parser.parse!(argv)
    assert!(argv.empty? && %i[source_root evidence_root helper helper_sha256].all? { |key| options.key?(key) }, parser.to_s)
    validate!(options)
  rescue StandardError => error
    warn "W230 evidence audit failed: #{error.class}: #{error.message}"
    false
  end
end

if $PROGRAM_NAME == __FILE__
  exit(CheckRecursiveQBitEvidenceW230.main(ARGV) ? 0 : 1)
end
