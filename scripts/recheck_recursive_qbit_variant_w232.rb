#!/usr/bin/env ruby
# Paired ClickHouse / Crystal evidence capture for fixed static QBit-in-Variant
# products. Source and runtime are separately pinned; this runner makes no
# claim that the recovered runtime was built from the archived source checkout.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require_relative 'recheck_aggregate_recursive_w224'

module RecheckRecursiveQBitVariantW232
  extend self

  R = RecheckAggregateRecursiveW224
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
  MAX_ROWS = 6
  ROW_KEYS = [1, 2, 3, 4, 5, 6].freeze
  MARK_ROWS = [2, 2, 2].freeze
  PART_MARKS = 4
  MAX_PROFILES = 3
  MAX_PROCESSES = 80
  MAX_FILES = 1024
  MAX_TOTAL_BYTES = 16 * 1024 * 1024
  MAX_INPUT_BYTES = 64 * 1024
  PROCESS_TIMEOUT_SECONDS = 90
  HELPER_TIMEOUT_SECONDS = 600
  MEMORY_LIMIT_BYTES = 1_073_741_824
  INVALIDATED_FILE = 'invalidated_system_columns.txt'.freeze
  INVALIDATED_NAMES = %w[_block_number _block_offset].freeze
  TREE_ENTRY_CAP = 4096

  # Fixed modes: Wide, BASIC Variant discriminator, LZ4 data, typed part
  # declarations, one-stream String layout, basic Map, and uncompressed mrk2.
  STOCK_SETTINGS = [
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

  def fail!(message)
    raise ArgumentError, message
  end

  def require_true(condition, message)
    fail!(message) unless condition
  end

  def sha256_file(path)
    Digest::SHA256.file(path).hexdigest
  end

  def write_new(path, bytes)
    R.write_new(path, bytes)
  end

  def write_json(path, value)
    write_new(path, JSON.pretty_generate(value) + "\n")
  end

  def make_dir(path)
    Dir.mkdir(path, 0o700)
  rescue Errno::EEXIST
    fail!("refusing to reuse W232 directory: #{path}")
  end

  def plain_file!(path, label, executable: false)
    full = File.expand_path(path)
    require_true(File.file?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "#{label} is absent, symlinked, or noncanonical: #{full}")
    require_true(!executable || File.executable?(full), "#{label} is not executable")
    full
  end

  def validate_root(path, prefix, label)
    full = File.expand_path(path)
    require_true(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full && Dir.children(full).empty?,
      "#{label} must be a fresh, empty, canonical directory")
    require_true(File.dirname(full) == File.realpath('/private/tmp') && File.basename(full).start_with?(prefix),
      "#{label} must be a direct /private/tmp child with prefix #{prefix}")
    full
  end

  def validate_binary!(path)
    full = plain_file!(path, 'stock ClickHouse runtime', executable: true)
    require_true(full == CLICKHOUSE_BIN && sha256_file(full) == CLICKHOUSE_SHA256,
      'runtime binary differs from fixed independent path/SHA pin')
    full
  end

  def validate_helper!(path, expected_sha)
    require_true(/\A[0-9a-f]{64}\z/.match?(expected_sha), 'helper SHA must be 64 lowercase hex')
    full = plain_file!(path, 'prebuilt Crystal helper', executable: true)
    actual = sha256_file(full)
    require_true(actual == expected_sha, "prebuilt helper SHA differs: #{actual}")
    [full, actual]
  end

  def source_manifest
    files = SOURCE_FILES.map do |relative, expected|
      path = plain_file!(File.join(SOURCE_ROOT, relative), "pinned source #{relative}")
      actual = sha256_file(path)
      require_true(actual == expected, "pinned source file changed: #{relative} #{actual}")
      { 'path' => relative, 'sha256' => actual }
    end
    { 'root' => SOURCE_ROOT, 'revision' => SOURCE_REVISION, 'files' => files }
  end

  def uint64_le(number)
    require_true(number.is_a?(Integer) && number >= 0 && number <= 18_446_744_073_709_551_615, 'UInt64 literal out of range')
    Array.new(8) { |index| (number >> (index * 8)) & 0xff }.pack('C*').b
  end

  def varuint(number)
    require_true(number.is_a?(Integer) && number >= 0 && number <= 18_446_744_073_709_551_615, 'VarUInt literal out of range')
    bytes = []
    while number >= 0x80
      bytes << ((number & 0x7f) | 0x80)
      number >>= 7
    end
    (bytes << number).pack('C*').b
  end

  def qbit(raw_hex)
    require_true(raw_hex.is_a?(String) && /\A(?:[0-9a-f]{2}){9}\z/.match?(raw_hex), 'QBit(Int8, 9) literal width differs')
    varuint(9) + [raw_hex].pack('H*').b
  end

  def encode_node(spec)
    kind = spec.fetch('kind')
    case kind
    when 'qbit' then qbit(spec.fetch('hex'))
    when 'variant_null' then "\xff".b
    when 'variant'
      alternative = spec.fetch('alternative')
      index = ALTERNATIVE_INDEX.fetch(alternative) { fail!("unlisted Variant alternative #{alternative}") }
      [index].pack('C').b + encode_node(spec.fetch('value'))
    when 'array'
      items = spec.fetch('items')
      varuint(items.length) + items.map { |item| encode_node(item) }.join.b
    when 'map'
      entries = spec.fetch('entries')
      varuint(entries.length) + entries.map do |key, value|
        key_bytes = key.encode(Encoding::UTF_8).b
        varuint(key_bytes.bytesize) + key_bytes + encode_node(value)
      end.join.b
    when 'tuple'
      spec.fetch('fields').map { |field| encode_node(field) }.join.b
    when 'string'
      bytes = spec.fetch('value').encode(Encoding::UTF_8).b
      varuint(bytes.bytesize) + bytes
    when 'uint8'
      value = spec.fetch('value')
      require_true(value.is_a?(Integer) && (0..255).cover?(value), 'UInt8 fixture is outside range')
      [value].pack('C').b
    when 'uint64'
      uint64_le(spec.fetch('value'))
    else
      fail!("unlisted W232 literal node #{kind.inspect}")
    end
  end

  def rowbinary(profile, index)
    uint64_le(ROW_KEYS.fetch(index)) + encode_node(profile.fetch('rows').fetch(index))
  end

  def literal_hex(profile)
    MAX_ROWS.times.map { |index| rowbinary(profile, index).unpack1('H*') }
  end

  def profiles
    q = ->(hex) { { 'kind' => 'qbit', 'hex' => hex } }
    variant = ->(alternative, value) { { 'kind' => 'variant', 'alternative' => alternative, 'value' => value } }
    null = { 'kind' => 'variant_null' }
    array = ->(items) { { 'kind' => 'array', 'items' => items } }
    direct = [
      variant.call('QBit(Int8, 9)', q.call('feff00010204081020')),
      variant.call('QBit(Int8, 9)', q.call('080706050403020100')),
      variant.call('UInt64', { 'kind' => 'uint64', 'value' => 0x1122_3344_5566_7788 }),
      variant.call('QBit(Int8, 9)', q.call('020406080a0c0e1012')),
      null, null,
    ]
    array_variants = [
      array.call([variant.call('QBit(Int8, 9)', q.call('feff00010204081020')), null]),
      array.call([]),
      array.call([variant.call('UInt64', { 'kind' => 'uint64', 'value' => 7 }),
        variant.call('QBit(Int8, 9)', q.call('01030507090b0d0f11'))]),
      array.call([null]), array.call([]), array.call([null]),
    ]
    composed = [
      variant.call('Array(QBit(Int8, 9))', array.call([])),
      variant.call('Array(QBit(Int8, 9))', array.call([
        q.call('feff00010204081020'), q.call('080706050403020100'),
      ])),
      variant.call('Tuple(q QBit(Int8, 9), n UInt8)', {
        'kind' => 'tuple', 'fields' => [q.call('01030507090b0d0f11'), { 'kind' => 'uint8', 'value' => 7 }],
      }),
      variant.call('Map(String, QBit(Int8, 9))', {
        'kind' => 'map', 'entries' => [['a', q.call('020406080a0c0e1012')], ['xy', q.call('101112131415161718')]],
      }),
      null, null,
    ]
    [
      { 'id' => 'root_variant', 'type' => DIRECT_TYPE, 'rows' => direct },
      { 'id' => 'array_variant', 'type' => ARRAY_TYPE, 'rows' => array_variants },
      { 'id' => 'variant_array_tuple_map', 'type' => COMPOSED_TYPE, 'rows' => composed },
    ]
  end

  def clickhouse_argv(binary, store, sql)
    [binary, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
      '--max_insert_threads=1', '--max_execution_time=30', "--max_memory_usage=#{MEMORY_LIMIT_BYTES}",
      '--print_pretty_type_names=0', '--flatten_nested=0', '--multiquery', '--query', sql]
  end

  def process_success!(record, label)
    success = record.fetch('classification') == 'process_success' && record.fetch('exitstatus') == 0 &&
      !record.fetch('signaled') && !record.fetch('timed_out') && record.fetch('spawn_error').nil?
    require_true(success, "#{label} failed as a process; preserve raw capture and do not call it a CH refusal")
    record
  end

  def clean_record(record)
    record.reject { |key, _value| %w[stdout stderr path].include?(key) }
  end

  def check_root_budget!(root)
    files = 0
    bytes = 0
    Find.find(root) do |path|
      next if path == root || File.directory?(path)
      require_true(!File.symlink?(path) && File.file?(path), "unsupported or symlinked evidence path: #{path}")
      files += 1
      bytes += File.size(path)
      require_true(files <= MAX_FILES && bytes <= MAX_TOTAL_BYTES, 'capture exceeded fixed file/byte cap')
    end
  end

  def inventory(part)
    full = File.expand_path(part)
    require_true(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full, "part is noncanonical: #{full}")
    entries = []
    count = 0
    bytes = 0
    Find.find(full) do |path|
      next if path == full
      count += 1
      require_true(count <= TREE_ENTRY_CAP && !File.symlink?(path), "part tree exceeds bound or contains symlink")
      next if File.directory?(path)
      require_true(File.file?(path), "part tree contains unsupported entry")
      size = File.size(path)
      bytes += size
      require_true(bytes <= MAX_TOTAL_BYTES, 'part exceeds byte bound')
      entries << { 'path' => path[(full.length + 1)..-1], 'size' => size, 'sha256' => sha256_file(path) }
    end
    entries.sort_by { |entry| entry.fetch('path') }
  end

  def parse_tsv_row(bytes, count, label)
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    require_true(text.valid_encoding?, "#{label} is not UTF-8 TSV")
    lines = text.lines.map { |line| line.chomp.sub(/\r\z/, '') }
    require_true(lines.length == 1, "#{label} expected one row")
    fields = lines.first.split("\t", -1)
    require_true(fields.length == count, "#{label} field count differs")
    fields
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

  def expected_window(profile, window)
    indices = { 'full' => (0...MAX_ROWS).to_a, 'middle' => [2, 3], 'zero' => [] }.fetch(window)
    indices.map { |index| rowbinary(profile, index) }.join.b
  end

  def validate_check!(record, label)
    require_true(record.fetch('stdout') == "all_1_1_0\t1\t\n", "#{label} CHECK result differs")
  end

  def validate_schema!(bytes, profile, label)
    expected = "id\tUInt64\nv\t#{profile.fetch('type')}\n"
    require_true(bytes == expected, "#{label} exact schema differs: #{bytes.inspect}")
  end

  class Probe
    def initialize(options)
      @binary = RecheckRecursiveQBitVariantW232.validate_binary!(options.fetch(:clickhouse))
      @helper, @helper_sha = RecheckRecursiveQBitVariantW232.validate_helper!(options.fetch(:helper), options.fetch(:helper_sha256))
      @helper_sha_at_start = RecheckRecursiveQBitVariantW232.sha256_file(@helper)
      @source_root = RecheckRecursiveQBitVariantW232.validate_root(options.fetch(:source_root), SOURCE_PREFIX, 'stock root')
      @evidence_root = RecheckRecursiveQBitVariantW232.validate_root(options.fetch(:evidence_root), EVIDENCE_PREFIX, 'evidence root')
      @profiles = RecheckRecursiveQBitVariantW232.profiles
      @source_recorder = R::Recorder.new(@source_root, @binary)
      @evidence_recorder = R::Recorder.new(@evidence_root, @binary)
      @stock_profiles = []
      @native_profiles = []
    end

    # Keep module-level capture utilities explicit at the instance boundary.
    def require_true(condition, message)
      RecheckRecursiveQBitVariantW232.require_true(condition, message)
    end

    def write_json(path, value)
      RecheckRecursiveQBitVariantW232.write_json(path, value)
    end

    def sha256_file(path)
      RecheckRecursiveQBitVariantW232.sha256_file(path)
    end

    def process_success!(record, label)
      RecheckRecursiveQBitVariantW232.process_success!(record, label)
    end

    def check_sql(table)
      RecheckRecursiveQBitVariantW232.check_sql(table)
    end

    def schema_sql(table)
      RecheckRecursiveQBitVariantW232.schema_sql(table)
    end

    def part_sql(table)
      RecheckRecursiveQBitVariantW232.part_sql(table)
    end

    def prepare_layout
      %w[invocations stores parts cases].each { |name| RecheckRecursiveQBitVariantW232.make_dir(File.join(@source_root, name)) }
      %w[invocations stores generated cases].each { |name| RecheckRecursiveQBitVariantW232.make_dir(File.join(@evidence_root, name)) }
      RecheckRecursiveQBitVariantW232.make_dir(File.join(@evidence_root, 'generated', 'parts'))
      RecheckRecursiveQBitVariantW232.make_dir(File.join(@source_root, 'stores', 'pins'))
      @profiles.each do |profile|
        id = profile.fetch('id')
        [File.join(@source_root, 'stores', id), File.join(@source_root, 'parts', id), File.join(@source_root, 'cases', id),
         File.join(@evidence_root, 'stores', id), File.join(@evidence_root, 'generated', 'parts', id),
         File.join(@evidence_root, 'cases', id)].each { |path| RecheckRecursiveQBitVariantW232.make_dir(path) }
      end
    end

    def run_clickhouse(recorder, root, label, store, sql, input = nil)
      require_true(recorder.records.length < MAX_PROCESSES, 'process cap reached')
      require_true(input.nil? || input.bytesize <= MAX_INPUT_BYTES, "#{label} input exceeds byte cap")
      record = recorder.run(label, store, sql, input: input, timeout: PROCESS_TIMEOUT_SECONDS,
        argv: RecheckRecursiveQBitVariantW232.clickhouse_argv(@binary, store, sql))
      RecheckRecursiveQBitVariantW232.process_success!(record, label)
      RecheckRecursiveQBitVariantW232.check_root_budget!(root)
      record
    end

    def runtime_pin
      store = File.join(@source_root, 'stores', 'pins')
      version = run_clickhouse(@source_recorder, @source_root, 'runtime-version-pin', store, 'SELECT version() FORMAT TSVRaw')
      require_true(version.fetch('stdout').strip == CLICKHOUSE_VERSION, 'runtime version SQL pin differs')
      build = run_clickhouse(@source_recorder, @source_root, 'runtime-build-pin', store,
        "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw")
      require_true(build.fetch('stdout').strip == "VERSION_GITHASH=#{CLICKHOUSE_BUILD}", 'runtime build SQL pin differs')
      { 'binary' => @binary, 'sha256' => CLICKHOUSE_SHA256, 'version' => CLICKHOUSE_VERSION,
        'build_hash' => CLICKHOUSE_BUILD, 'source_correlation' => 'runtime and source are separately pinned; no build identity claim' }
    end

    def capture_windows(recorder, root, label_prefix, store, table, profile)
      %w[full middle zero].to_h do |window|
        sql = RecheckRecursiveQBitVariantW232.window_sql(table, window)
        record = run_clickhouse(recorder, root, "#{label_prefix}-rowbinary-#{profile.fetch('id')}-#{window}", store, sql)
        actual = record.fetch('stdout')
        expected = RecheckRecursiveQBitVariantW232.expected_window(profile, window)
        require_true(actual == expected, "#{label_prefix}/#{profile.fetch('id')}/#{window} RowBinary differs from independent bytes")
        [window, { 'bytes' => actual.bytesize, 'sha256' => Digest::SHA256.hexdigest(actual), 'matches_independent_literals' => true }]
      end
    end

    def capture_stock(profile)
      id = profile.fetch('id')
      store = File.join(@source_root, 'stores', id)
      table = "w232_stock_#{id}"
      sql = "CREATE TABLE default.#{table} (id UInt64, v #{profile.fetch('type')} CODEC(LZ4)) " \
        "ENGINE=MergeTree ORDER BY id SETTINGS #{STOCK_SETTINGS.join(', ')}"
      create = run_clickhouse(@source_recorder, @source_root, "stock-create-#{id}", store, sql)
      literal_rows = profile.fetch('rows').each_index.map { |index| RecheckRecursiveQBitVariantW232.rowbinary(profile, index) }
      input = literal_rows.join.b
      insert = run_clickhouse(@source_recorder, @source_root, "stock-insert-#{id}", store,
        "INSERT INTO default.#{table} FORMAT RowBinary", input)
      check = run_clickhouse(@source_recorder, @source_root, "stock-check-#{id}", store, check_sql(table))
      RecheckRecursiveQBitVariantW232.validate_check!(check, "stock #{id}")
      schema = run_clickhouse(@source_recorder, @source_root, "stock-schema-#{id}", store, schema_sql(table))
      schema_bytes = schema.fetch('stdout')
      RecheckRecursiveQBitVariantW232.validate_schema!(schema_bytes, profile, "stock #{id}")
      part = run_clickhouse(@source_recorder, @source_root, "stock-part-#{id}", store, part_sql(table))
      fields = RecheckRecursiveQBitVariantW232.parse_tsv_row(part.fetch('stdout'), 5, "stock #{id} part")
      require_true(fields[0, 4] == ['all_1_1_0', '6', PART_MARKS.to_s, 'Wide'], "stock #{id} part grid differs: #{fields.inspect}")
      original = File.expand_path(fields.fetch(4))
      require_true(original.start_with?(store + File::SEPARATOR) && File.directory?(original) &&
        !File.symlink?(original) && File.realpath(original) == original, "stock #{id} part escaped isolated store")
      copy = File.join(@source_root, 'parts', id, 'all_1_1_0')
      require_true(!File.exist?(copy) && !File.symlink?(copy), "stock copy exists: #{copy}")
      FileUtils.cp_r(original, copy)
      inventory = RecheckRecursiveQBitVariantW232.inventory(copy)
      windows = capture_windows(@source_recorder, @source_root, 'stock', store, table, profile)
      record = {
        'id' => id, 'declared_type' => profile.fetch('type'), 'table' => table, 'store' => store,
        'source_part_path' => copy, 'source_part_inventory' => inventory, 'rows' => profile.fetch('rows'),
        'row_keys' => ROW_KEYS, 'mark_rows' => MARK_ROWS, 'check_output' => check.fetch('stdout'),
        'schema_output' => schema_bytes, 'literal_rowbinary_hex' => literal_rows.map { |bytes| bytes.unpack1('H*') },
        'windows' => windows, 'processes' => [create, insert, check, schema, part].map { |item| RecheckRecursiveQBitVariantW232.clean_record(item) },
      }
      @stock_profiles << record
      write_json(File.join(@source_root, 'cases', id + '.json'), record)
      record
    end

    def helper_input
      generated_root = File.join(@evidence_root, 'generated', 'parts')
      { 'format' => INPUT_FORMAT, 'capture_root' => @source_root, 'generated_root' => generated_root,
        'profiles' => @profiles.map do |profile|
          { 'id' => profile.fetch('id'), 'declared_type' => profile.fetch('type'),
            'source_part_path' => File.join(@source_root, 'parts', profile.fetch('id'), 'all_1_1_0'),
            'library_part_path' => File.join(generated_root, profile.fetch('id'), 'all_1_1_0'),
            'row_keys' => ROW_KEYS, 'mark_rows' => MARK_ROWS, 'rows' => profile.fetch('rows'),
            'literal_rowbinary_hex' => RecheckRecursiveQBitVariantW232.literal_hex(profile) }
        end }
    end

    def run_helper
      input_path = File.join(@evidence_root, 'generated', 'helper-input.json')
      input = helper_input
      write_json(input_path, input)
      input.fetch('profiles').each do |profile|
        require_true(!File.exist?(profile.fetch('library_part_path')) && !File.symlink?(profile.fetch('library_part_path')),
          "library output is not fresh: #{profile.fetch('library_part_path')}")
      end
      require_true(sha256_file(@helper) == @helper_sha_at_start, 'helper changed before execution')
      @helper_input_sha = sha256_file(input_path)
      helper = @evidence_recorder.run('helper-read-write-roundtrip', File.join(@evidence_root, 'generated'), nil,
        timeout: HELPER_TIMEOUT_SECONDS, argv: [@helper, '--input', input_path])
      process_success!(helper, 'prebuilt helper')
      @helper_invocation_path = helper.fetch('path')
      @helper_stdout = File.binread(@helper_invocation_path + '.stdout')
      @helper_output = JSON.parse(@helper_stdout.force_encoding(Encoding::UTF_8))
      require_true(@helper_output.fetch('format') == HELPER_FORMAT && @helper_output.fetch('profile_count') == @profiles.size,
        'helper output format/profile count differs')
      expected_ids = @profiles.map { |profile| profile.fetch('id') }
      actual_profiles = @helper_output.fetch('profiles')
      require_true(actual_profiles.map { |profile| profile.fetch('id') } == expected_ids, 'helper profile roster differs')
      actual_profiles.zip(input.fetch('profiles')).each do |actual, expected|
        require_true(actual.fetch('declared_type') == expected.fetch('declared_type') &&
          actual.fetch('row_keys') == expected.fetch('row_keys') && actual.fetch('mark_rows') == expected.fetch('mark_rows') &&
          actual.fetch('source_part_path') == expected.fetch('source_part_path') &&
          actual.fetch('library_part_path') == expected.fetch('library_part_path'), 'helper output bindings differ from input')
        %w[source_scan library_scan].each do |key|
          scan = actual.fetch(key)
          require_true(scan.fetch('full_rows') == 6 && scan.fetch('middle_rows') == 2 &&
            scan.fetch('zero_mark_callbacks') == 0 && scan.fetch('eof_callbacks') == 0 &&
            scan.fetch('exact_type_and_literal_checks') == true, "helper #{key} public scan evidence differs")
        end
      end
      write_json(File.join(@evidence_root, 'generated', 'helper-output.json'), @helper_output)
      @library_inventories = actual_profiles.map do |profile|
        { 'id' => profile.fetch('id'), 'path' => profile.fetch('library_part_path'),
          'inventory' => RecheckRecursiveQBitVariantW232.inventory(profile.fetch('library_part_path')) }
      end
      current_source_inventory = @stock_profiles.map do |profile|
        { 'id' => profile.fetch('id'), 'inventory' => RecheckRecursiveQBitVariantW232.inventory(profile.fetch('source_part_path')) }
      end
      require_true(sha256_file(@helper) == @helper_sha && sha256_file(input_path) == @helper_input_sha,
        'helper or input hash changed during execution')
      require_true(current_source_inventory == @source_inventory_pre,
        'stock source parts changed between pre-helper and post-helper inventories')
      @helper
    end

    def create_native_target(profile)
      id = profile.fetch('id')
      store = File.join(@evidence_root, 'stores', id)
      table = "w232_native_#{id}"
      sql = "CREATE TABLE default.#{table} (id UInt64, v #{profile.fetch('type')} CODEC(LZ4)) " \
        "ENGINE=MergeTree ORDER BY id SETTINGS #{STOCK_SETTINGS.join(', ')}"
      run_clickhouse(@evidence_recorder, @evidence_root, "native-create-#{id}", store, sql)
      path_record = run_clickhouse(@evidence_recorder, @evidence_root, "native-data-path-#{id}", store,
        "SELECT arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw")
      data_path = File.expand_path(path_record.fetch('stdout').strip)
      require_true(data_path.start_with?(store + File::SEPARATOR) && File.directory?(data_path) &&
        !File.symlink?(data_path) && File.realpath(data_path) == data_path, "native data path escaped store for #{id}")
      detached = File.join(data_path, 'detached')
      require_true(File.directory?(detached) && !File.symlink?(detached) && File.realpath(detached) == detached,
        "native detached directory is invalid for #{id}")
      { 'id' => id, 'store' => store, 'table' => table, 'data_path' => data_path,
        'detached_part_path' => File.join(detached, 'all_1_1_0') }
    end

    def attach_native(profile, target, helper_profile, library_inventory)
      id = profile.fetch('id')
      library = helper_profile.fetch('library_part_path')
      before = RecheckRecursiveQBitVariantW232.inventory(library)
      require_true(before == library_inventory.fetch(id), "library part changed before attach for #{id}")
      detached = target.fetch('detached_part_path')
      require_true(!File.exist?(detached) && !File.symlink?(detached), "native detached destination is not fresh for #{id}")
      FileUtils.cp_r(library, detached)
      require_true(RecheckRecursiveQBitVariantW232.inventory(detached) == before, "native copy differs for #{id}")
      attach = run_clickhouse(@evidence_recorder, @evidence_root, "native-attach-#{id}", target.fetch('store'),
        "ALTER TABLE default.#{target.fetch('table')} ATTACH PART 'all_1_1_0'")
      check = run_clickhouse(@evidence_recorder, @evidence_root, "native-check-#{id}", target.fetch('store'),
        RecheckRecursiveQBitVariantW232.check_sql(target.fetch('table')))
      RecheckRecursiveQBitVariantW232.validate_check!(check, "native #{id}")
      schema = run_clickhouse(@evidence_recorder, @evidence_root, "native-schema-#{id}", target.fetch('store'),
        RecheckRecursiveQBitVariantW232.schema_sql(target.fetch('table')))
      schema_bytes = schema.fetch('stdout')
      RecheckRecursiveQBitVariantW232.validate_schema!(schema_bytes, profile, "native #{id}")
      part = run_clickhouse(@evidence_recorder, @evidence_root, "native-part-#{id}", target.fetch('store'),
        RecheckRecursiveQBitVariantW232.part_sql(target.fetch('table')))
      fields = RecheckRecursiveQBitVariantW232.parse_tsv_row(part.fetch('stdout'), 5, "native #{id} part")
      attached = File.join(target.fetch('data_path'), 'all_1_1_0')
      require_true(fields[0, 4] == ['all_1_1_0', '6', PART_MARKS.to_s, 'Wide'] && File.expand_path(fields[4]) == attached,
        "native attached part identity/grid/path differs for #{id}: #{fields.inspect}")
      after = RecheckRecursiveQBitVariantW232.inventory(attached)
      before_map = before.to_h { |entry| [entry.fetch('path'), entry] }
      after_map = after.to_h { |entry| [entry.fetch('path'), entry] }
      removed = before_map.keys - after_map.keys
      changed = before_map.keys.select { |path| after_map.key?(path) && before_map.fetch(path) != after_map.fetch(path) }
      added = after_map.keys - before_map.keys
      require_true(removed.empty? && changed.empty? && added == [INVALIDATED_FILE],
        "ATTACH changed unexpected files for #{id}: #{[removed, changed, added].inspect}")
      names = File.binread(File.join(attached, INVALIDATED_FILE)).split("\n", -1)
      require_true(names.pop == '' && names.sort == INVALIDATED_NAMES.sort, "invalidated system-column roster differs for #{id}")
      columns_before = File.binread(File.join(library, 'columns.txt'))
      columns_after = File.binread(File.join(attached, 'columns.txt'))
      require_true(columns_before == columns_after, "ATTACH changed columns.txt bytes for #{id}")
      codec = File.binread(File.join(attached, 'default_compression_codec.txt')).strip
      metadata = File.binread(File.join(attached, 'metadata_version.txt')).strip
      require_true(codec == 'CODEC(LZ4)' && metadata == '0', "attached codec/metadata differs for #{id}")
      windows = capture_windows(@evidence_recorder, @evidence_root, 'native', target.fetch('store'), target.fetch('table'), profile)
      record = { 'id' => id, 'table' => target.fetch('table'), 'declared_type' => profile.fetch('type'),
        'helper_part_path' => library, 'attached_part_path' => attached, 'helper_part_inventory' => before,
        'attached_part_inventory' => after, 'removed_paths' => removed.sort, 'changed_paths' => changed.sort,
        'added_paths' => added.sort, 'check_output' => check.fetch('stdout'), 'schema_output' => schema_bytes,
        'columns_sha256' => Digest::SHA256.hexdigest(columns_after), 'default_compression_codec' => codec,
        'metadata_version' => metadata, 'windows' => windows,
        'processes' => [attach, check, schema, part].map { |item| RecheckRecursiveQBitVariantW232.clean_record(item) } }
      write_json(File.join(@evidence_root, 'cases', id + '.json'), record)
      record
    end

    def run
      prepare_layout
      @source_pin = RecheckRecursiveQBitVariantW232.source_manifest
      write_json(File.join(@source_root, 'source-pin.json'), @source_pin)
      @runtime_pin = runtime_pin
      @profiles.each { |profile| capture_stock(profile) }
      @source_inventory_pre = @stock_profiles.map do |profile|
        { 'id' => profile.fetch('id'), 'inventory' => RecheckRecursiveQBitVariantW232.inventory(profile.fetch('source_part_path')) }
      end
      write_json(File.join(@source_root, 'physical.pre.json'), { 'format' => 'recursive_qbit_variant_w232_source_physical_v1', 'profiles' => @source_inventory_pre })
      run_helper
      helper_profiles = @helper_output.fetch('profiles').to_h { |item| [item.fetch('id'), item] }
      library_inventories = @library_inventories.to_h { |item| [item.fetch('id'), item.fetch('inventory')] }
      @profiles.each do |profile|
        target = create_native_target(profile)
        @native_profiles << attach_native(profile, target, helper_profiles.fetch(profile.fetch('id')), library_inventories)
      end
      source_post = @stock_profiles.map do |profile|
        { 'id' => profile.fetch('id'), 'inventory' => RecheckRecursiveQBitVariantW232.inventory(profile.fetch('source_part_path')) }
      end
      require_true(source_post == @source_inventory_pre, 'stock part changed after helper/native phase')
      %w[physical.after-helper.json physical.post.json].each do |name|
        write_json(File.join(@source_root, name), { 'format' => 'recursive_qbit_variant_w232_source_physical_v1', 'profiles' => source_post })
      end
      source_post_pin = RecheckRecursiveQBitVariantW232.source_manifest
      require_true(source_post_pin == @source_pin, 'pinned source files changed during capture')
      write_json(File.join(@source_root, 'source-pin-post.json'), source_post_pin)
      helper_sha_after = RecheckRecursiveQBitVariantW232.sha256_file(@helper)
      require_true(helper_sha_after == @helper_sha &&
        RecheckRecursiveQBitVariantW232.sha256_file(File.join(@evidence_root, 'generated', 'helper-input.json')) == @helper_input_sha,
        'helper or input changed during paired capture')
      helper_stdout_sha = RecheckRecursiveQBitVariantW232.sha256_file(@helper_invocation_path + '.stdout')
      code_pins = %w[
        scripts/recheck_recursive_qbit_variant_w232.rb
        scripts/check_recursive_qbit_variant_w232.cr
        scripts/check_recursive_qbit_variant_evidence_w232.rb
        scripts/recheck_aggregate_recursive_w224.rb
      ].to_h do |relative|
        path = RecheckRecursiveQBitVariantW232.plain_file!(File.join(REPO_ROOT, relative), "capture code #{relative}")
        [relative, RecheckRecursiveQBitVariantW232.sha256_file(path)]
      end
      write_json(File.join(@evidence_root, 'generated', 'library-physical.json'),
        { 'format' => 'recursive_qbit_variant_w232_library_physical_v1', 'profiles' => @library_inventories })
      write_json(File.join(@evidence_root, 'result.json'), {
        'format' => RESULT_FORMAT, 'classification' => 'paired_static_qbit_variant_profiles_observed', 'success' => true,
        'source_root' => @source_root, 'evidence_root' => @evidence_root, 'source_pin' => @source_pin,
        'runtime_pin' => @runtime_pin, 'helper_path' => @helper, 'helper_sha256_expected' => @helper_sha,
        'helper_sha256_observed_after' => helper_sha_after,
        'helper_input_path' => File.join(@evidence_root, 'generated', 'helper-input.json'),
        'helper_input_sha256' => @helper_input_sha, 'helper_stdout_sha256' => helper_stdout_sha,
        'code_pins' => code_pins, 'profile_count' => @profiles.length, 'stock_profiles' => @stock_profiles,
        'helper_output' => @helper_output, 'library_inventories' => @library_inventories,
        'native_profiles' => @native_profiles,
        'counts' => { 'source_processes' => @source_recorder.records.length,
          'evidence_processes' => @evidence_recorder.records.length, 'profiles' => @profiles.length,
          'source_parts' => @stock_profiles.length, 'library_parts' => @library_inventories.length,
          'attached_parts' => @native_profiles.length },
        'process_rosters' => { 'source' => @source_recorder.records.map { |item| item.fetch('label') },
          'evidence' => @evidence_recorder.records.map { |item| item.fetch('label') } },
        'settings' => STOCK_SETTINGS, 'variant_discriminator_mode' => 'BASIC',
        'scope' => 'three fixed static QBit-in-Variant products: root Variant, Array(Variant), and Variant(Array, Map, Tuple); BASIC discriminator, no Dynamic/LowCardinality/Nullable or performance claim',
      })
      RecheckRecursiveQBitVariantW232.check_root_budget!(@source_root)
      RecheckRecursiveQBitVariantW232.check_root_budget!(@evidence_root)
      puts "W232 paired Variant/QBit capture: #{@profiles.length} profiles; stock=#{@source_recorder.records.length} native/helper=#{@evidence_recorder.records.length}; root=#{@evidence_root}"
      true
    rescue StandardError => error
      warn "W232 paired capture failed: #{error.class}: #{error.message}"
      false
    end
  end

  def main(argv)
    options = { clickhouse: CLICKHOUSE_BIN }
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/recheck_recursive_qbit_variant_w232.rb --helper PREBUILT --helper-sha256 SHA --source-root EMPTY_ROOT --evidence-root EMPTY_ROOT [--clickhouse PINNED]'
      opts.on('--clickhouse PATH') { |value| options[:clickhouse] = value }
      opts.on('--helper PATH') { |value| options[:helper] = value }
      opts.on('--helper-sha256 SHA') { |value| options[:helper_sha256] = value }
      opts.on('--source-root PATH') { |value| options[:source_root] = value }
      opts.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
    end
    parser.parse!(argv)
    require_true(argv.empty? && %i[helper helper_sha256 source_root evidence_root].all? { |key| options.key?(key) }, parser.to_s)
    Probe.new(options).run
  rescue StandardError => error
    warn "W232 runner setup failed: #{error.class}: #{error.message}"
    false
  end
end

exit(RecheckRecursiveQBitVariantW232.main(ARGV) ? 0 : 1) if $PROGRAM_NAME == __FILE__
