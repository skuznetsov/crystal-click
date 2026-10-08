#!/usr/bin/env ruby
# Paired stock ClickHouse / Crystal capture for the fixed W231 static QBit
# product roster. The Crystal helper is external and already built.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require_relative 'recheck_aggregate_recursive_w224'

module RecheckRecursiveQBitStaticW231
  extend self

  R = RecheckAggregateRecursiveW224
  REPO_ROOT = '/Users/sergey/Projects/Crystal/crystal-click'.freeze
  SOURCE_ROOT = '/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1'.freeze
  SOURCE_REVISION = '0ca8150d9b1d0886edb2e3b4ab65eebb768d0357'.freeze
  CLICKHOUSE_BIN = '/private/tmp/crystal-click-w216-runtime-recovery.DmL9Kw/clickhouse-stripped'.freeze
  CLICKHOUSE_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  CLICKHOUSE_VERSION = '26.10.1.1201'.freeze
  CLICKHOUSE_BUILD = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  SOURCE_PREFIX = 'crystal-click-w231-stock.'.freeze
  EVIDENCE_PREFIX = 'crystal-click-w231-evidence.'.freeze
  INPUT_FORMAT = 'recursive_qbit_static_w231_helper_input_v1'.freeze
  HELPER_FORMAT = 'recursive_qbit_static_w231_helper_v1'.freeze
  RESULT_FORMAT = 'recursive_qbit_static_w231_result_v1'.freeze
  PROCESS_TIMEOUT_SECONDS = 90
  HELPER_TIMEOUT_SECONDS = 600
  MEMORY_LIMIT_BYTES = 1_073_741_824
  ROW_KEYS = [1, 2, 3, 4, 5, 6].freeze
  MARK_ROWS = [2, 2, 2].freeze
  INVALIDATED_FILE = 'invalidated_system_columns.txt'.freeze
  INVALIDATED_NAMES = %w[_block_number _block_offset].freeze
  TREE_ENTRY_CAP = 4_096
  TREE_BYTE_CAP = 64 * 1024 * 1024
  STOCK_SETTINGS = [
    'index_granularity=2', 'index_granularity_bytes=10485760',
    'enable_mixed_granularity_parts=1', 'min_rows_for_wide_part=0',
    'min_bytes_for_wide_part=0', 'min_level_for_wide_part=0',
    'compress_marks=0', 'compress_primary_key=0', 'min_compress_block_size=0',
    'max_compress_block_size=4096', 'ratio_of_defaults_for_sparse_serialization=1.0',
    'compute_exact_num_defaults_for_sparse_columns=0', "default_compression_codec='LZ4'",
    "nullable_serialization_version='basic'", "map_serialization_version='basic'",
    "map_serialization_version_for_zero_level_parts='basic'",
  ].freeze
  SOURCE_FILES = {
    'src/Core/Settings.cpp' => '1feab11c05a33d9df8c6e4886ad00a81efa358ba320803d720db32eef4f9db9a',
    'src/Storages/MergeTree/MergeTreeSettings.cpp' => 'b8bdea86a07f61481c747517b56035855fa9726217d5b7183f292a5432b9b515',
    'src/DataTypes/DataTypeArray.h' => '660e6f37210922c200a7cbba5f25a0f01d579f79a51611768de72d1a3002be37',
    'src/DataTypes/DataTypeLowCardinality.cpp' => 'e75ef3196f929ed61313394fe8ba13c0a377446f73fac12f2b2425128d625c5c',
    'src/DataTypes/DataTypeMap.cpp' => 'dfc839fd14ad6f0b726d65cdc266622cc62912cc48adfb60e61bdb0b49752c73',
    'src/DataTypes/DataTypeNested.cpp' => 'bb0cd02e0c94e0bd8520f6c8a83f64c7089fc47e5dc09f9d72e15f81367f16e4',
    'src/DataTypes/DataTypeNullable.cpp' => '68c4e432a0f555712906d796a4db1d950b32abac2d6c2eba4c1117ad39793e64',
    'src/DataTypes/DataTypeQBit.cpp' => '9713cd968e6a8252bba54aaf9dd49cbe2e31edc9af7e4e1d473d74d435ce87d9',
    'src/DataTypes/DataTypeQBit.h' => '14ef033053d9585e42e84b26a50934836fe083d8f002b69a415ad698df276911',
    'src/DataTypes/DataTypeTuple.cpp' => '350d50a6d0c5cefbf8b31bad1106f7e2200cc69ada1bac50704723d66edde2a0',
    'src/DataTypes/DataTypeTuple.h' => '9ebb2d555efa56456e4d57d873dcdbf231e48c96fcf87fa41d067f8073e9953b',
    'src/DataTypes/IDataType.h' => '6e9befee2cf642d989912710a4857c5a122fb7ba337eafc6b923c10f8eb33d5c',
    'src/DataTypes/Serializations/ISerialization.cpp' => '87ca6647aeb0dd4022e3437a155f923f817d4447c547eff9ec29ab6876d16dd2',
    'src/DataTypes/Serializations/SerializationArray.cpp' => '825295e177ae7f406c1a1c155e0c9e17b4cc39f4747cb1f3fb327b54db043791',
    'src/DataTypes/Serializations/SerializationMap.cpp' => '191c35c896507f303b06b2527277148d748ba5b8c62ffbefbdab739b1a6a8056',
    'src/DataTypes/Serializations/SerializationNullable.cpp' => '7f8f0f97725f21d196beabae47fefcc3bcb32e250f4a1f9a87b37f73eae7c43f',
    'src/DataTypes/Serializations/SerializationQBit.cpp' => '64a1638077a5807512dff9fb25ad310f5a8da80eb76d39d9c76d083d980fc5da',
    'src/DataTypes/Serializations/SerializationTuple.cpp' => '12e38b357204e005fc4780bac7e2e358b0a14357e0e246137414166062a1a884',
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

  def fail!(message)
    raise ArgumentError, message
  end

  def clickhouse_argv(binary, store, sql)
    [binary, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
      '--max_insert_threads=1', '--max_execution_time=30', "--max_memory_usage=#{MEMORY_LIMIT_BYTES}",
      '--print_pretty_type_names=0', '--flatten_nested=0', '--multiquery', '--query', sql]
  end

  def require_true(condition, message)
    fail!(message) unless condition
  end

  def sha256_file(path)
    Digest::SHA256.file(path).hexdigest
  end

  def safe_label(value)
    value.gsub(/[^A-Za-z0-9_.-]/, '_')
  end

  def write_new(path, bytes)
    File.open(path, 'wbx', 0o600) { |file| file.write(bytes) }
  rescue Errno::EEXIST
    fail!("refusing to overwrite W231 evidence: #{path}")
  end

  def write_json(path, value)
    write_new(path, JSON.pretty_generate(value) + "\n")
  end

  def make_dir(path)
    Dir.mkdir(path, 0o700)
  rescue Errno::EEXIST
    fail!("refusing to reuse W231 directory: #{path}")
  end

  def plain_file!(path, label, executable: false)
    full = File.expand_path(path)
    require_true(File.file?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "#{label} is absent, symlinked, or noncanonical: #{full}")
    require_true(!executable || File.executable?(full), "#{label} is not executable: #{full}")
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
    full = R.validate_binary!(path)
    require_true(full == CLICKHOUSE_BIN && sha256_file(full) == CLICKHOUSE_SHA256,
      'ClickHouse binary differs from the separate W231 runtime pin')
    full
  end

  def validate_helper!(path, expected_sha)
    R.validate_sha256_pin!(expected_sha, 'expected helper SHA-256')
    full = R.validate_program!(path, 'prebuilt Crystal helper')
    actual = sha256_file(full)
    require_true(actual == expected_sha, "prebuilt helper SHA-256 differs from external pin: #{actual}")
    [full, actual]
  end

  def source_manifest
    files = SOURCE_FILES.map do |relative, expected|
      path = File.join(SOURCE_ROOT, relative)
      plain_file!(path, "pinned ClickHouse source #{relative}")
      actual = sha256_file(path)
      require_true(actual == expected, "pinned ClickHouse source changed: #{relative} #{actual}")
      { 'path' => relative, 'sha256' => actual }
    end
    { 'root' => SOURCE_ROOT, 'revision' => SOURCE_REVISION, 'files' => files }
  end

  def varuint(number)
    require_true(number.is_a?(Integer) && number >= 0 && number <= 18_446_744_073_709_551_615,
      "VarUInt outside unsigned 64-bit range: #{number.inspect}")
    bytes = []
    while number >= 0x80
      bytes << ((number & 0x7f) | 0x80)
      number >>= 7
    end
    (bytes << number).pack('C*').b
  end

  def uint64_le(number)
    require_true(number.is_a?(Integer) && number >= 0 && number <= 18_446_744_073_709_551_615,
      "UInt64 fixture outside range: #{number.inspect}")
    Array.new(8) { |index| (number >> (index * 8)) & 0xff }.pack('C*').b
  end

  def vector(carrier, codes)
    BYTE_VALUES.fetch(carrier).values_at(*codes).join
  end

  def vector9(carrier, index)
    vector(carrier, CODES9.fetch(index % CODES9.length))
  end

  def vector16(index)
    vector('BFloat16', CODES16.fetch(index % CODES16.length))
  end

  def vector3(index)
    vector('Int8', CODES3.fetch(index % CODES3.length))
  end

  def qbit_node(carrier, dimension)
    [:qbit, carrier, dimension]
  end

  def array_node(child)
    [:array, child]
  end

  def tuple_node(fields)
    [:tuple, fields]
  end

  def qbits(carrier, dimension, count, seed)
    Array.new(count) { |index| dimension == 3 ? vector3(seed + index) : dimension == 16 ? vector16(seed + index) : vector9(carrier, seed + index) }
  end

  def fixture_profiles
    left_counts = [2, 0, 0, 1, 3, 0]
    right_counts = [0, 3, 1, 0, 0, 2]
    sibling_type = 'Tuple(left Array(QBit(Int8, 9)), right Array(QBit(Float32, 9)))'
    sibling_shape = tuple_node([
      ['left', array_node(qbit_node('Int8', 9))],
      ['right', array_node(qbit_node('Float32', 9))],
    ])
    sibling_rows = 6.times.map do |row|
      { 'left' => qbits('Int8', 9, left_counts[row], row),
        'right' => qbits('Float32', 9, right_counts[row], row + 2) }
    end
    profiles = [
      { 'id' => 'tuple_sibling_arrays', 'declared_type' => sibling_type,
        'shape' => sibling_shape, 'rows' => sibling_rows },
      { 'id' => 'tuple_sibling_arrays_all_empty', 'declared_type' => sibling_type,
        'shape' => sibling_shape,
        'rows' => Array.new(6) { { 'left' => [], 'right' => [] } } },
    ]

    direct_nullable_type = 'Tuple(direct QBit(BFloat16, 16), maybe Nullable(QBit(Int8, 3)))'
    direct_nullable_shape = tuple_node([
      ['direct', qbit_node('BFloat16', 16)],
      ['maybe', [:nullable, qbit_node('Int8', 3)]],
    ])
    profiles << { 'id' => 'tuple_direct_nullable', 'declared_type' => direct_nullable_type,
      'shape' => direct_nullable_shape,
      'rows' => 6.times.map do |row|
        { 'direct' => vector16(row), 'maybe' => [1, 4].include?(row) ? nil : vector3(row + 1) }
      end }

    array_tuple_type = 'Array(Tuple(left QBit(Int8, 9), right QBit(Float32, 9)))'
    array_tuple_shape = array_node(tuple_node([
      ['left', qbit_node('Int8', 9)], ['right', qbit_node('Float32', 9)],
    ]))
    outer_counts = [2, 0, 3, 1, 0, 2]
    profiles << { 'id' => 'array_tuple_sites', 'declared_type' => array_tuple_type,
      'shape' => array_tuple_shape,
      'rows' => 6.times.map do |row|
        Array.new(outer_counts[row]) do |entry|
          { 'left' => vector9('Int8', row + entry), 'right' => vector9('Float32', row + entry + 1) }
        end
      end }

    nested_type = 'Nested(direct QBit(Int8, 9), children Array(QBit(BFloat16, 16)))'
    nested_shape = array_node(tuple_node([
      ['direct', qbit_node('Int8', 9)],
      ['children', array_node(qbit_node('BFloat16', 16))],
    ]))
    child_counts = [1, 0, 2, 0, 1, 0]
    profiles << { 'id' => 'nested_sites', 'declared_type' => nested_type,
      'shape' => nested_shape,
      'rows' => 6.times.map do |row|
        Array.new(outer_counts[row]) do |entry|
          { 'direct' => vector9('Int8', row + entry + 2),
            'children' => qbits('BFloat16', 16, child_counts[(row + entry) % child_counts.length], row + entry) }
        end
      end }

    map_value_type = 'Map(String, QBit(Float32, 9))'
    map_value_shape = [:map, [:string], qbit_node('Float32', 9)]
    profiles << { 'id' => 'map_value_site', 'declared_type' => map_value_type,
      'shape' => map_value_shape,
      'rows' => 6.times.map do |row|
        Array.new(outer_counts[row]) { |entry| ["k#{row}_#{entry}", vector9('Float32', row + entry)] }
      end }

    map_key_type = 'Map(QBit(Int8, 9), UInt64)'
    map_key_shape = [:map, qbit_node('Int8', 9), [:uint64]]
    profiles << { 'id' => 'map_key_site', 'declared_type' => map_key_type,
      'shape' => map_key_shape,
      'rows' => 6.times.map do |row|
        Array.new(outer_counts[row]) { |entry| [vector9('Int8', row + entry + 1), (row * 100 + entry)] }
      end }

    nullable_tuple_type = 'Nullable(Tuple(direct QBit(Int8, 9), children Array(QBit(BFloat16, 16))))'
    nullable_tuple_shape = [:nullable, tuple_node([
      ['direct', qbit_node('Int8', 9)],
      ['children', array_node(qbit_node('BFloat16', 16))],
    ])]
    nullable_rows = 6.times.map do |row|
      if [1, 3].include?(row)
        nil
      else
        { 'direct' => vector9('Int8', row + 3),
          'children' => qbits('BFloat16', 16, [2, 0, 1, 0, 1, 0][row], row + 1) }
      end
    end
    profiles << { 'id' => 'nullable_tuple_hidden', 'declared_type' => nullable_tuple_type,
      'shape' => nullable_tuple_shape, 'rows' => nullable_rows }

    require_true(profiles.length == 8 && profiles.map { |profile| profile.fetch('id') }.uniq.length == 8,
      'fixed W231 profile roster is not eight unique IDs')
    require_true(profiles.all? { |profile| profile.fetch('rows').length == ROW_KEYS.length },
      'fixed W231 profile row count differs from keys')
    profiles
  end

  def encode_node(shape, value, label)
    kind = shape.fetch(0)
    case kind
    when :qbit
      carrier = shape.fetch(1)
      dimension = shape.fetch(2)
      require_true(value.is_a?(String) && /\A(?:[0-9a-f]{2})+\z/.match?(value), "#{label} QBit literal is invalid")
      raw = [value].pack('H*').b
      bytes_per_element = BYTE_VALUES.fetch(carrier).first.bytesize / 2
      require_true(raw.bytesize == bytes_per_element * dimension, "#{label} QBit width differs")
      varuint(dimension) + raw
    when :array
      require_true(value.is_a?(Array), "#{label} Array value is not an array")
      varuint(value.length) + value.each_with_index.map { |child, index| encode_node(shape.fetch(1), child, "#{label}[#{index}]") }.join.b
    when :tuple
      fields = shape.fetch(1)
      require_true(value.is_a?(Hash) && value.keys.sort == fields.map(&:first).sort, "#{label} Tuple fields differ")
      fields.map { |name, child| encode_node(child, value.fetch(name), "#{label}.#{name}") }.join.b
    when :nullable
      value.nil? ? "\x01".b : "\x00".b + encode_node(shape.fetch(1), value, label)
    when :map
      key_shape = shape.fetch(1)
      value_shape = shape.fetch(2)
      require_true(value.is_a?(Array), "#{label} Map value is not entry pairs")
      varuint(value.length) + value.each_with_index.map do |pair, index|
        require_true(pair.is_a?(Array) && pair.length == 2, "#{label} Map entry #{index} is not a pair")
        encode_node(key_shape, pair[0], "#{label}.key[#{index}]") + encode_node(value_shape, pair[1], "#{label}.value[#{index}]")
      end.join.b
    when :string
      require_true(value.is_a?(String), "#{label} String value is invalid")
      varuint(value.bytesize) + value.b
    when :uint64
      uint64_le(value)
    else
      fail!("#{label} has unknown fixed RowBinary node #{kind.inspect}")
    end
  end

  def literal_rowbinary(profile, index)
    uint64_le(ROW_KEYS.fetch(index)) + encode_node(profile.fetch('shape'), profile.fetch('rows').fetch(index), profile.fetch('id'))
  end

  def literal_rowbinary_hex(profile)
    profile.fetch('rows').each_index.map { |index| literal_rowbinary(profile, index).unpack1('H*') }
  end

  def expected_window(profile, window)
    indices = case window
              when 'full' then (0...ROW_KEYS.length).to_a
              when 'middle' then [2, 3]
              when 'zero' then []
              else fail!("unlisted W231 RowBinary window: #{window}")
              end
    indices.map { |index| literal_rowbinary(profile, index) }.join.b
  end

  def table_name(profile, kind)
    "w231_#{kind}_#{safe_label(profile.fetch('id'))}"
  end

  def create_sql(table, profile)
    "CREATE TABLE default.#{table} (id UInt64, q #{profile.fetch('declared_type')} CODEC(LZ4)) " \
      "ENGINE=MergeTree ORDER BY id SETTINGS #{STOCK_SETTINGS.join(', ')}"
  end

  def schema_sql(table)
    "SELECT name, lower(hex(type)) FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw"
  end

  def part_sql(table)
    "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw"
  end

  def check_sql(table)
    "CHECK TABLE default.#{table} FORMAT TSVRaw"
  end

  def rowbinary_sql(table, window)
    predicate = case window
                when 'full' then ''
                when 'middle' then ' WHERE id BETWEEN 3 AND 4'
                when 'zero' then ' WHERE id=0'
                else fail!("unlisted W231 RowBinary window: #{window}")
                end
    "SELECT id, q FROM default.#{table}#{predicate} ORDER BY id FORMAT RowBinary"
  end

  def parse_single_tsv_row!(bytes, fields, label)
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    require_true(text.valid_encoding?, "#{label} is not valid UTF-8 TSV")
    lines = text.lines.map { |line| line.chomp.sub(/\r\z/, '') }
    require_true(lines.length == 1, "#{label} expected one TSV line: #{lines.inspect}")
    values = lines.first.split("\t", -1)
    require_true(values.length == fields, "#{label} expected #{fields} TSV fields: #{values.inspect}")
    values
  end

  def expected_schema(profile)
    "id\t#{'UInt64'.unpack1('H*')}\nq\t#{profile.fetch('declared_type').unpack1('H*')}\n"
  end

  def require_check!(record, label)
    actual = File.binread(record.fetch('path') + '.stdout')
    require_true(actual == "all_1_1_0\t1\t\n", "#{label} must be one exact success row with empty message; got #{actual.inspect}")
  end

  def inventory(part)
    full = File.expand_path(part)
    require_true(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "part is missing, symlinked, or noncanonical: #{full}")
    entries = []
    count = 0
    bytes = 0
    Find.find(full) do |path|
      next if path == full
      count += 1
      require_true(count <= TREE_ENTRY_CAP, "part tree exceeds entry cap: #{full}")
      require_true(!File.symlink?(path), "part contains symlink: #{path}")
      next if File.directory?(path)
      require_true(File.file?(path), "part contains unsupported entry: #{path}")
      bytes += File.size(path)
      require_true(bytes <= TREE_BYTE_CAP, "part tree exceeds byte cap: #{full}")
      entries << { 'path' => path[(full.length + 1)..-1], 'size' => File.size(path), 'sha256' => sha256_file(path) }
    end
    entries.sort_by { |entry| entry.fetch('path') }
  end

  def inventory_delta(before, after)
    before_map = before.to_h { |entry| [entry.fetch('path'), entry] }
    after_map = after.to_h { |entry| [entry.fetch('path'), entry] }
    removed = before_map.keys - after_map.keys
    changed = before_map.keys.select { |path| after_map.key?(path) && before_map.fetch(path) != after_map.fetch(path) }
    added = after_map.keys - before_map.keys
    [removed.sort, changed.sort, added.sort]
  end

  def process_success!(record, label)
    require_true(record.fetch('classification') == 'process_success' && record.fetch('exitstatus') == 0 &&
      !record.fetch('signaled') && !record.fetch('timed_out') && !record.fetch('spawn_error'),
      "#{label} failed as a process; this is not a semantic refusal: #{record.inspect}")
    record
  end

  class Probe
    def initialize(options)
      @binary = RecheckRecursiveQBitStaticW231.validate_binary!(options.fetch(:clickhouse))
      @helper, @helper_sha = RecheckRecursiveQBitStaticW231.validate_helper!(options.fetch(:helper), options.fetch(:helper_sha256))
      @helper_sha_at_start = RecheckRecursiveQBitStaticW231.sha256_file(@helper)
      @source_root = RecheckRecursiveQBitStaticW231.validate_root(options.fetch(:source_root), SOURCE_PREFIX, 'stock capture root')
      @evidence_root = RecheckRecursiveQBitStaticW231.validate_root(options.fetch(:evidence_root), EVIDENCE_PREFIX, 'evidence root')
      @profiles = RecheckRecursiveQBitStaticW231.fixture_profiles
      @source_recorder = R::Recorder.new(@source_root, @binary)
      @evidence_recorder = R::Recorder.new(@evidence_root, @binary)
      @stock_profiles = []
      @native_profiles = []
      @fatal = nil
    end

    def prepare_layout
      [File.join(@source_root, 'invocations'), File.join(@source_root, 'stores'), File.join(@source_root, 'parts'),
       File.join(@source_root, 'cases'), File.join(@evidence_root, 'invocations'), File.join(@evidence_root, 'stores'),
       File.join(@evidence_root, 'generated'), File.join(@evidence_root, 'generated', 'parts'),
       File.join(@evidence_root, 'cases')].each { |path| RecheckRecursiveQBitStaticW231.make_dir(path) }
      @profiles.each do |profile|
        id = profile.fetch('id')
        [File.join(@source_root, 'stores', id), File.join(@source_root, 'parts', id), File.join(@source_root, 'cases', id),
         File.join(@evidence_root, 'stores', id), File.join(@evidence_root, 'generated', 'parts', id),
         File.join(@evidence_root, 'cases', id)].each { |path| RecheckRecursiveQBitStaticW231.make_dir(path) }
      end
      RecheckRecursiveQBitStaticW231.make_dir(File.join(@source_root, 'stores', 'pins'))
    end

    def run_source(label, store, sql, input: nil)
      record = @source_recorder.run(label, store, sql, input: input, timeout: PROCESS_TIMEOUT_SECONDS,
        argv: RecheckRecursiveQBitStaticW231.clickhouse_argv(@binary, store, sql))
      RecheckRecursiveQBitStaticW231.process_success!(record, label)
    end

    def run_evidence(label, store, sql, input: nil)
      record = @evidence_recorder.run(label, store, sql, input: input, timeout: PROCESS_TIMEOUT_SECONDS,
        argv: RecheckRecursiveQBitStaticW231.clickhouse_argv(@binary, store, sql))
      RecheckRecursiveQBitStaticW231.process_success!(record, label)
    end

    def pin_runtime
      store = File.join(@source_root, 'stores', 'pins')
      version = run_source('runtime-version-pin', store, 'SELECT version() FORMAT TSVRaw')
      version_bytes = File.binread(version.fetch('path') + '.stdout')
      RecheckRecursiveQBitStaticW231.require_true(version_bytes.strip == CLICKHOUSE_VERSION, 'runtime version differs from fixed binary pin')
      build = run_source('runtime-build-pin', store,
        "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw")
      build_bytes = File.binread(build.fetch('path') + '.stdout')
      RecheckRecursiveQBitStaticW231.require_true(build_bytes.strip == "VERSION_GITHASH=#{CLICKHOUSE_BUILD}", 'runtime build differs from fixed binary pin')
      @runtime_pin = { 'binary' => @binary, 'sha256' => CLICKHOUSE_SHA256, 'version' => CLICKHOUSE_VERSION,
        'build_hash' => CLICKHOUSE_BUILD, 'source_correlation' => 'runtime binary and source checkout are separately pinned' }
    end

    def capture_stock(profile)
      id = profile.fetch('id')
      table = RecheckRecursiveQBitStaticW231.table_name(profile, 'stock')
      store = File.join(@source_root, 'stores', id)
      create = run_source("stock-create-#{id}", store, RecheckRecursiveQBitStaticW231.create_sql(table, profile))
      input = profile.fetch('rows').each_index.map do |index|
        RecheckRecursiveQBitStaticW231.literal_rowbinary(profile, index)
      end.join.b
      insert = run_source("stock-insert-#{id}", store, "INSERT INTO default.#{table} FORMAT RowBinary", input: input)
      check = run_source("stock-check-#{id}", store, RecheckRecursiveQBitStaticW231.check_sql(table))
      RecheckRecursiveQBitStaticW231.require_check!(check, "stock CHECK #{id}")
      schema = run_source("stock-schema-#{id}", store, RecheckRecursiveQBitStaticW231.schema_sql(table))
      schema_bytes = File.binread(schema.fetch('path') + '.stdout')
      RecheckRecursiveQBitStaticW231.require_true(schema_bytes == RecheckRecursiveQBitStaticW231.expected_schema(profile),
        "stock exact schema hex differs for #{id}: #{schema_bytes.inspect}")
      part_query = run_source("stock-part-#{id}", store, RecheckRecursiveQBitStaticW231.part_sql(table))
      fields = RecheckRecursiveQBitStaticW231.parse_single_tsv_row!(File.binread(part_query.fetch('path') + '.stdout'), 5, "stock part #{id}")
      RecheckRecursiveQBitStaticW231.require_true(fields[0, 4] == ['all_1_1_0', '6', '4', 'Wide'],
        "stock part identity/grid differs for #{id}: #{fields.inspect}")
      original_part = File.expand_path(fields[4])
      RecheckRecursiveQBitStaticW231.require_true(original_part.start_with?(store + File::SEPARATOR) &&
        File.directory?(original_part) && !File.symlink?(original_part) && File.realpath(original_part) == original_part,
        "stock part escaped its isolated store for #{id}")
      copied_part = File.join(@source_root, 'parts', id, 'all_1_1_0')
      RecheckRecursiveQBitStaticW231.require_true(!File.exist?(copied_part) && !File.symlink?(copied_part),
        "stock part destination already exists: #{copied_part}")
      FileUtils.cp_r(original_part, copied_part)
      source_inventory = RecheckRecursiveQBitStaticW231.inventory(copied_part)
      windows = capture_windows(@source_recorder, @source_root, store, table, profile, 'stock')
      record = {
        'id' => id, 'declared_type' => profile.fetch('declared_type'), 'table' => table, 'store' => store,
        'source_part_path' => copied_part, 'source_part_inventory' => source_inventory,
        'rows' => profile.fetch('rows'), 'row_keys' => ROW_KEYS, 'mark_rows' => MARK_ROWS,
        'check_output' => File.binread(check.fetch('path') + '.stdout'), 'schema_output' => schema_bytes,
        'windows' => windows,
      }
      @stock_profiles << record
      RecheckRecursiveQBitStaticW231.write_json(File.join(@source_root, 'cases', id + '.json'), record)
      record
    end

    def capture_windows(recorder, root, store, table, profile, prefix)
      %w[full middle zero].to_h do |window|
        sql = RecheckRecursiveQBitStaticW231.rowbinary_sql(table, window)
        record = RecheckRecursiveQBitStaticW231.process_success!(recorder.run(
          "#{prefix}-rowbinary-#{profile.fetch('id')}-#{window}", store, sql, timeout: PROCESS_TIMEOUT_SECONDS,
          argv: RecheckRecursiveQBitStaticW231.clickhouse_argv(@binary, store, sql)),
          "#{prefix} RowBinary #{profile.fetch('id')} #{window}")
        actual = File.binread(record.fetch('path') + '.stdout')
        expected = RecheckRecursiveQBitStaticW231.expected_window(profile, window)
        RecheckRecursiveQBitStaticW231.require_true(actual == expected,
          "#{prefix} #{window} RowBinary differs from fixed literal for #{profile.fetch('id')}")
        [window, { 'bytes' => actual.bytesize, 'sha256' => Digest::SHA256.hexdigest(actual),
          'matches_independent_literal' => true }]
      end
    end

    def capture_stock_profiles
      @source_pin = RecheckRecursiveQBitStaticW231.source_manifest
      RecheckRecursiveQBitStaticW231.write_json(File.join(@source_root, 'source-pin.json'), @source_pin)
      pin_runtime
      @profiles.each { |profile| capture_stock(profile) }
      @source_inventory_pre = @stock_profiles.map do |record|
        { 'id' => record.fetch('id'), 'inventory' => RecheckRecursiveQBitStaticW231.inventory(record.fetch('source_part_path')) }
      end
      RecheckRecursiveQBitStaticW231.write_json(File.join(@source_root, 'physical.pre.json'),
        { 'format' => 'recursive_qbit_static_w231_source_physical_v1', 'profiles' => @source_inventory_pre })
    end

    def helper_input
      generated_root = File.join(@evidence_root, 'generated', 'parts')
      {
        'format' => INPUT_FORMAT, 'capture_root' => @source_root, 'generated_root' => generated_root,
        'profiles' => @profiles.map do |profile|
          {
            'id' => profile.fetch('id'), 'declared_type' => profile.fetch('declared_type'),
            'source_part_path' => File.join(@source_root, 'parts', profile.fetch('id'), 'all_1_1_0'),
            'library_part_path' => File.join(generated_root, profile.fetch('id'), 'all_1_1_0'),
            'row_keys' => ROW_KEYS, 'mark_rows' => MARK_ROWS, 'rows' => profile.fetch('rows'),
            'literal_rowbinary_hex' => RecheckRecursiveQBitStaticW231.literal_rowbinary_hex(profile),
          }
        end,
      }
    end

    def capture_helper
      input_path = File.join(@evidence_root, 'generated', 'helper-input.json')
      input = helper_input
      RecheckRecursiveQBitStaticW231.write_json(input_path, input)
      input.fetch('profiles').each do |profile|
        RecheckRecursiveQBitStaticW231.require_true(!File.exist?(profile.fetch('library_part_path')) &&
          !File.symlink?(profile.fetch('library_part_path')), "library part already exists: #{profile.fetch('library_part_path')}")
      end
      RecheckRecursiveQBitStaticW231.require_true(RecheckRecursiveQBitStaticW231.sha256_file(@helper) == @helper_sha_at_start,
        'prebuilt helper changed before execution')
      @helper_input_sha = RecheckRecursiveQBitStaticW231.sha256_file(input_path)
      helper_record = @evidence_recorder.run('helper-read-write-roundtrip', File.join(@evidence_root, 'generated'), nil,
        timeout: HELPER_TIMEOUT_SECONDS, argv: [@helper, '--input', input_path])
      RecheckRecursiveQBitStaticW231.process_success!(helper_record, 'prebuilt Crystal helper')
      @helper_invocation_path = helper_record.fetch('path')
      helper_stdout = File.binread(@helper_invocation_path + '.stdout')
      @helper_output = JSON.parse(helper_stdout.force_encoding(Encoding::UTF_8))
      RecheckRecursiveQBitStaticW231.require_true(@helper_output.fetch('format') == HELPER_FORMAT &&
        @helper_output.fetch('profile_count') == @profiles.length, 'helper output format/count differs')
      actual_profiles = @helper_output.fetch('profiles')
      RecheckRecursiveQBitStaticW231.require_true(actual_profiles.map { |item| item.fetch('id') } == @profiles.map { |item| item.fetch('id') },
        'helper output profile order differs')
      actual_profiles.zip(input.fetch('profiles')).each do |actual, expected|
        expected_keys = %w[declared_type id library_part_path library_rows mark_rows row_keys source_part_path source_rows]
        RecheckRecursiveQBitStaticW231.require_true(actual.keys.sort == expected_keys.sort,
          "helper output fields differ for #{expected.fetch('id')}")
        %w[id declared_type library_part_path mark_rows row_keys source_part_path].each do |key|
          RecheckRecursiveQBitStaticW231.require_true(actual.fetch(key) == expected.fetch(key),
            "helper output #{key} differs for #{expected.fetch('id')}")
        end
        RecheckRecursiveQBitStaticW231.require_true(actual.fetch('source_rows') == expected.fetch('rows') &&
          actual.fetch('library_rows') == expected.fetch('rows'), "helper rows differ for #{expected.fetch('id')}")
        source_part = expected.fetch('source_part_path')
        library_part = expected.fetch('library_part_path')
        RecheckRecursiveQBitStaticW231.require_true(File.directory?(source_part) && File.realpath(source_part) == source_part,
          "helper source part is not canonical for #{expected.fetch('id')}")
        generated_root = File.realpath(File.join(@evidence_root, 'generated', 'parts')) + File::SEPARATOR
        RecheckRecursiveQBitStaticW231.require_true(library_part.start_with?(generated_root) && File.directory?(library_part) &&
          !File.symlink?(library_part) && File.realpath(library_part) == library_part,
          "helper output escaped generated part root for #{expected.fetch('id')}")
      end
      RecheckRecursiveQBitStaticW231.write_json(File.join(@evidence_root, 'generated', 'helper-output.json'), @helper_output)
      @library_inventories = actual_profiles.map do |item|
        { 'id' => item.fetch('id'), 'path' => item.fetch('library_part_path'),
          'inventory' => RecheckRecursiveQBitStaticW231.inventory(item.fetch('library_part_path')) }
      end
      RecheckRecursiveQBitStaticW231.require_true(RecheckRecursiveQBitStaticW231.sha256_file(@helper) == @helper_sha,
        'prebuilt helper changed during execution')
      RecheckRecursiveQBitStaticW231.require_true(RecheckRecursiveQBitStaticW231.sha256_file(input_path) == @helper_input_sha,
        'helper input manifest changed during execution')
      source_after = @stock_profiles.map do |record|
        { 'id' => record.fetch('id'), 'inventory' => RecheckRecursiveQBitStaticW231.inventory(record.fetch('source_part_path')) }
      end
      RecheckRecursiveQBitStaticW231.require_true(source_after == @source_inventory_pre, 'helper changed a stock source part')
      RecheckRecursiveQBitStaticW231.write_json(File.join(@source_root, 'physical.after-helper.json'),
        { 'format' => 'recursive_qbit_static_w231_source_physical_v1', 'profiles' => source_after })
      RecheckRecursiveQBitStaticW231.write_json(File.join(@evidence_root, 'generated', 'library-physical.json'),
        { 'format' => 'recursive_qbit_static_w231_library_physical_v1', 'profiles' => @library_inventories })
    rescue JSON::ParserError => error
      RecheckRecursiveQBitStaticW231.fail!("helper stdout is not JSON: #{error.message}")
    end

    def create_native_target(profile)
      id = profile.fetch('id')
      table = RecheckRecursiveQBitStaticW231.table_name(profile, 'native')
      store = File.join(@evidence_root, 'stores', id)
      create = run_evidence("native-create-#{id}", store, RecheckRecursiveQBitStaticW231.create_sql(table, profile))
      data_path_query = run_evidence("native-data-path-#{id}", store,
        "SELECT arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw")
      data_path = File.expand_path(File.binread(data_path_query.fetch('path') + '.stdout').strip)
      RecheckRecursiveQBitStaticW231.require_true(data_path.start_with?(store + File::SEPARATOR) && File.directory?(data_path) &&
        !File.symlink?(data_path) && File.realpath(data_path) == data_path, "native data path escaped isolated store for #{id}")
      detached = File.join(data_path, 'detached')
      RecheckRecursiveQBitStaticW231.require_true(File.directory?(detached) && !File.symlink?(detached) &&
        File.realpath(detached) == detached, "native detached directory is invalid for #{id}")
      { 'id' => id, 'table' => table, 'store' => store, 'data_path' => data_path,
        'detached_part_path' => File.join(detached, 'all_1_1_0') }
    end

    def attach_profile(profile, target, helper_profile, generated_inventory)
      id = profile.fetch('id')
      generated = helper_profile.fetch('library_part_path')
      generated_before = RecheckRecursiveQBitStaticW231.inventory(generated)
      detached = target.fetch('detached_part_path')
      RecheckRecursiveQBitStaticW231.require_true(!File.exist?(detached) && !File.symlink?(detached),
        "native detached path already exists for #{id}")
      FileUtils.cp_r(generated, detached)
      RecheckRecursiveQBitStaticW231.require_true(RecheckRecursiveQBitStaticW231.inventory(detached) == generated_before &&
        generated_before == generated_inventory.fetch(id), "helper part copy differs before ATTACH for #{id}")
      attach = run_evidence("native-attach-#{id}", target.fetch('store'),
        "ALTER TABLE default.#{target.fetch('table')} ATTACH PART 'all_1_1_0'")
      check = run_evidence("native-check-#{id}", target.fetch('store'), RecheckRecursiveQBitStaticW231.check_sql(target.fetch('table')))
      RecheckRecursiveQBitStaticW231.require_check!(check, "native CHECK #{id}")
      schema = run_evidence("native-schema-#{id}", target.fetch('store'), RecheckRecursiveQBitStaticW231.schema_sql(target.fetch('table')))
      schema_bytes = File.binread(schema.fetch('path') + '.stdout')
      RecheckRecursiveQBitStaticW231.require_true(schema_bytes == RecheckRecursiveQBitStaticW231.expected_schema(profile),
        "native exact schema hex differs for #{id}")
      part_query = run_evidence("native-part-#{id}", target.fetch('store'), RecheckRecursiveQBitStaticW231.part_sql(target.fetch('table')))
      fields = RecheckRecursiveQBitStaticW231.parse_single_tsv_row!(File.binread(part_query.fetch('path') + '.stdout'), 5,
        "native part #{id}")
      attached = File.join(target.fetch('data_path'), 'all_1_1_0')
      RecheckRecursiveQBitStaticW231.require_true(fields[0, 4] == ['all_1_1_0', '6', '4', 'Wide'] &&
        File.expand_path(fields[4]) == attached, "native attached part identity/grid/path differs for #{id}")
      attached_inventory = RecheckRecursiveQBitStaticW231.inventory(attached)
      removed, changed, added = RecheckRecursiveQBitStaticW231.inventory_delta(generated_before, attached_inventory)
      RecheckRecursiveQBitStaticW231.require_true(removed.empty? && changed.empty? && added == [INVALIDATED_FILE],
        "ATTACH changed unexpected part files for #{id}: removed=#{removed.inspect}, changed=#{changed.inspect}, added=#{added.inspect}")
      auxiliary = File.binread(File.join(attached, INVALIDATED_FILE)).split("\n", -1)
      RecheckRecursiveQBitStaticW231.require_true(auxiliary.pop == '' && auxiliary.sort == INVALIDATED_NAMES.sort,
        "ATTACH invalidated-system-columns file differs for #{id}")
      columns_before = File.binread(File.join(generated, 'columns.txt'))
      columns_after = File.binread(File.join(attached, 'columns.txt'))
      RecheckRecursiveQBitStaticW231.require_true(columns_after == columns_before,
        "ATTACH changed exact columns.txt bytes for #{id}")
      codec = File.binread(File.join(attached, 'default_compression_codec.txt')).strip
      RecheckRecursiveQBitStaticW231.require_true(codec == 'CODEC(LZ4)', "attached default codec differs for #{id}: #{codec.inspect}")
      metadata = File.binread(File.join(attached, 'metadata_version.txt')).strip
      RecheckRecursiveQBitStaticW231.require_true(metadata == '0', "attached metadata version differs for #{id}")
      windows = capture_windows(@evidence_recorder, @evidence_root, target.fetch('store'), target.fetch('table'), profile, 'native')
      record = {
        'id' => id, 'table' => target.fetch('table'), 'declared_type' => profile.fetch('declared_type'),
        'helper_part_path' => generated, 'attached_part_path' => attached,
        'helper_part_inventory' => generated_before, 'attached_part_inventory' => attached_inventory,
        'removed_paths' => removed, 'changed_paths' => changed, 'added_paths' => added,
        'check_output' => File.binread(check.fetch('path') + '.stdout'), 'schema_output' => schema_bytes,
        'columns_sha256' => Digest::SHA256.hexdigest(columns_after), 'default_compression_codec' => codec,
        'metadata_version' => metadata, 'windows' => windows,
      }
      @native_profiles << record
      RecheckRecursiveQBitStaticW231.write_json(File.join(@evidence_root, 'cases', id + '.json'), record)
      record
    end

    def run
      prepare_layout
      capture_stock_profiles
      capture_helper
      helper_profiles = @helper_output.fetch('profiles').to_h { |item| [item.fetch('id'), item] }
      generated_inventory = @library_inventories.to_h { |item| [item.fetch('id'), item.fetch('inventory')] }
      @profiles.each do |profile|
        target = create_native_target(profile)
        attach_profile(profile, target, helper_profiles.fetch(profile.fetch('id')), generated_inventory)
      end
      source_post = @stock_profiles.map do |record|
        { 'id' => record.fetch('id'), 'inventory' => RecheckRecursiveQBitStaticW231.inventory(record.fetch('source_part_path')) }
      end
      RecheckRecursiveQBitStaticW231.require_true(source_post == @source_inventory_pre,
        'stock part inventory changed during native attach/readback')
      RecheckRecursiveQBitStaticW231.write_json(File.join(@source_root, 'physical.post.json'),
        { 'format' => 'recursive_qbit_static_w231_source_physical_v1', 'profiles' => source_post })
      @source_pin_post = RecheckRecursiveQBitStaticW231.source_manifest
      RecheckRecursiveQBitStaticW231.require_true(@source_pin_post == @source_pin, 'pinned source changed during capture')
      RecheckRecursiveQBitStaticW231.write_json(File.join(@source_root, 'source-pin-post.json'), @source_pin_post)
      @helper_sha_after = RecheckRecursiveQBitStaticW231.sha256_file(@helper)
      RecheckRecursiveQBitStaticW231.require_true(@helper_sha_after == @helper_sha, 'prebuilt helper changed during capture')
      input_path = File.join(@evidence_root, 'generated', 'helper-input.json')
      RecheckRecursiveQBitStaticW231.require_true(RecheckRecursiveQBitStaticW231.sha256_file(input_path) == @helper_input_sha,
        'helper input changed during capture')
      @code_pins = %w[
        scripts/recheck_recursive_qbit_static_w231.rb
        scripts/check_recursive_qbit_static_evidence_w231.rb
        scripts/recheck_aggregate_recursive_w224.rb
      ].to_h do |relative|
        path = File.join(REPO_ROOT, relative)
        RecheckRecursiveQBitStaticW231.plain_file!(path, "pinned capture/audit code #{relative}")
        [relative, RecheckRecursiveQBitStaticW231.sha256_file(path)]
      end
      RecheckRecursiveQBitStaticW231.write_json(File.join(@evidence_root, 'result.json'), {
        'format' => RESULT_FORMAT, 'classification' => 'paired_recursive_qbit_static_profiles_observed',
        'success' => true, 'source_root' => @source_root, 'evidence_root' => @evidence_root,
        'runtime_pin' => @runtime_pin, 'source_pin' => @source_pin,
        'helper_path' => @helper, 'helper_sha256_expected' => @helper_sha,
        'helper_sha256_observed_after' => @helper_sha_after,
        'helper_input_path' => input_path, 'helper_input_sha256' => @helper_input_sha,
        'helper_stdout_sha256' => RecheckRecursiveQBitStaticW231.sha256_file(@helper_invocation_path + '.stdout'),
        'code_pins' => @code_pins,
        'profile_count' => @profiles.length, 'stock_profiles' => @stock_profiles,
        'helper_output' => @helper_output, 'library_inventories' => @library_inventories,
        'native_profiles' => @native_profiles,
        'counts' => { 'source_processes' => @source_recorder.records.length,
          'evidence_processes' => @evidence_recorder.records.length, 'profiles' => @profiles.length,
          'source_parts' => @stock_profiles.length, 'library_parts' => @library_inventories.length,
          'attached_parts' => @native_profiles.length },
        'process_rosters' => { 'source' => @source_recorder.records.map { |item| item.fetch('label') },
          'evidence' => @evidence_recorder.records.map { |item| item.fetch('label') } },
        'scope' => 'eight fixed static QBit product fixtures: Tuple sibling arrays/direct nullable, Array(Tuple), Nested, BASIC Map key/value and Nullable(Tuple); no Variant/runtime envelope/LowCardinality widening',
      })
      puts "W231 paired static QBit capture: #{@profiles.length} profiles; source processes=#{@source_recorder.records.length}; evidence processes=#{@evidence_recorder.records.length}; root=#{@evidence_root}"
      true
    rescue StandardError => error
      @fatal ||= "#{error.class}: #{error.message}"
      warn "W231 recursive QBit capture failed: #{@fatal}"
      false
    end
  end

  def main(argv)
    options = { clickhouse: CLICKHOUSE_BIN }
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/recheck_recursive_qbit_static_w231.rb --helper PREBUILT --helper-sha256 SHA --source-root EMPTY_ROOT --evidence-root EMPTY_ROOT [--clickhouse PINNED]'
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
    warn "W231 runner setup failure: #{error.class}: #{error.message}"
    false
  end
end

exit(RecheckRecursiveQBitStaticW231.main(ARGV) ? 0 : 1) if $PROGRAM_NAME == __FILE__
