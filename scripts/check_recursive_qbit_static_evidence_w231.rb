#!/usr/bin/env ruby
# Independent read-only audit of W231 stock-authored and Crystal-written
# static recursive QBit evidence. This file deliberately does not load the
# capture runner or invoke ClickHouse, Crystal, or another subprocess.

require 'digest'
require 'find'
require 'json'
require 'optparse'

module CheckRecursiveQBitStaticEvidenceW231
  extend self

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
  SETTINGS = [
    'index_granularity=2', 'index_granularity_bytes=10485760',
    'enable_mixed_granularity_parts=1', 'min_rows_for_wide_part=0',
    'min_bytes_for_wide_part=0', 'min_level_for_wide_part=0',
    'compress_marks=0', 'compress_primary_key=0', 'min_compress_block_size=0',
    'max_compress_block_size=4096', 'ratio_of_defaults_for_sparse_serialization=1.0',
    'compute_exact_num_defaults_for_sparse_columns=0', "default_compression_codec='LZ4'",
    "nullable_serialization_version='basic'", "map_serialization_version='basic'",
    "map_serialization_version_for_zero_level_parts='basic'",
  ].freeze
  BYTE_VALUES = {
    'Int8' => %w[fe ff 00 01 02 04 08 10 20].freeze,
    'BFloat16' => %w[00c0 80bf 0000 803f 0040 8040 0041 8041 0042].freeze,
    'Float32' => %w[000000c0 000080bf 00000000 0000803f 00000040 00008040 00000041 00008041 00000042].freeze,
  }.freeze
  VECTORS_9 = [
    [0, 1, 2, 3, 4, 5, 6, 7, 8], [8, 7, 6, 5, 4, 3, 2, 1, 0],
    [2, 4, 6, 8, 0, 1, 3, 5, 7], [8, 6, 4, 2, 0, 7, 5, 3, 1],
    [1, 3, 5, 7, 0, 2, 4, 6, 8],
  ].freeze
  VECTORS_16 = [
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 7, 6, 5, 4, 3, 2, 1],
    [8, 7, 6, 5, 4, 3, 2, 1, 0, 1, 2, 3, 4, 5, 6, 7],
    [2, 3, 4, 5, 6, 7, 8, 0, 1, 8, 7, 6, 5, 4, 3, 2],
    [6, 5, 4, 3, 2, 1, 0, 8, 7, 0, 1, 2, 3, 4, 5, 6],
    [1, 3, 5, 7, 0, 2, 4, 6, 8, 0, 8, 6, 4, 2, 1, 3],
  ].freeze
  VECTORS_3 = [[0, 1, 2], [3, 4, 5], [6, 7, 8], [8, 7, 6], [5, 4, 3]].freeze

  def assert!(condition, message)
    raise "W231 AUDIT FAIL: #{message}" unless condition
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
    raise "W231 AUDIT FAIL: malformed #{label}: #{error.message}"
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

  def vector(carrier, indices)
    BYTE_VALUES.fetch(carrier).values_at(*indices).join
  end

  def vector9(carrier, index)
    vector(carrier, VECTORS_9.fetch(index % VECTORS_9.length))
  end

  def vector16(index)
    vector('BFloat16', VECTORS_16.fetch(index % VECTORS_16.length))
  end

  def vector3(index)
    vector('Int8', VECTORS_3.fetch(index % VECTORS_3.length))
  end

  def qnode(carrier, dimension)
    [:qbit, carrier, dimension]
  end

  def array_node(child)
    [:array, child]
  end

  def tuple_node(fields)
    [:tuple, fields]
  end

  def vectors(carrier, dimension, count, start)
    Array.new(count) do |index|
      if dimension == 3
        vector3(start + index)
      elsif dimension == 16
        vector16(start + index)
      else
        vector9(carrier, start + index)
      end
    end
  end

  # This is a frozen audit-side fixture, independent of the runner's helper,
  # result summaries, helper output and captured RowBinary.
  def profiles
    left_lengths = [2, 0, 0, 1, 3, 0]
    right_lengths = [0, 3, 1, 0, 0, 2]
    sibling_type = 'Tuple(left Array(QBit(Int8, 9)), right Array(QBit(Float32, 9)))'
    sibling_shape = tuple_node([
      ['left', array_node(qnode('Int8', 9))], ['right', array_node(qnode('Float32', 9))],
    ])
    sibling_rows = 6.times.map do |row|
      { 'left' => vectors('Int8', 9, left_lengths[row], row),
        'right' => vectors('Float32', 9, right_lengths[row], row + 2) }
    end
    output = [
      { 'id' => 'tuple_sibling_arrays', 'declared_type' => sibling_type, 'shape' => sibling_shape, 'rows' => sibling_rows },
      { 'id' => 'tuple_sibling_arrays_all_empty', 'declared_type' => sibling_type, 'shape' => sibling_shape,
        'rows' => Array.new(6) { { 'left' => [], 'right' => [] } } },
    ]

    direct_type = 'Tuple(direct QBit(BFloat16, 16), maybe Nullable(QBit(Int8, 3)))'
    direct_shape = tuple_node([
      ['direct', qnode('BFloat16', 16)], ['maybe', [:nullable, qnode('Int8', 3)]],
    ])
    output << { 'id' => 'tuple_direct_nullable', 'declared_type' => direct_type, 'shape' => direct_shape,
      'rows' => 6.times.map { |row| { 'direct' => vector16(row), 'maybe' => [1, 4].include?(row) ? nil : vector3(row + 1) } } }

    tuple_array_type = 'Array(Tuple(left QBit(Int8, 9), right QBit(Float32, 9)))'
    tuple_array_shape = array_node(tuple_node([
      ['left', qnode('Int8', 9)], ['right', qnode('Float32', 9)],
    ]))
    parent_lengths = [2, 0, 3, 1, 0, 2]
    output << { 'id' => 'array_tuple_sites', 'declared_type' => tuple_array_type, 'shape' => tuple_array_shape,
      'rows' => 6.times.map do |row|
        Array.new(parent_lengths[row]) do |entry|
          { 'left' => vector9('Int8', row + entry), 'right' => vector9('Float32', row + entry + 1) }
        end
      end }

    nested_type = 'Nested(direct QBit(Int8, 9), children Array(QBit(BFloat16, 16)))'
    nested_shape = array_node(tuple_node([
      ['direct', qnode('Int8', 9)], ['children', array_node(qnode('BFloat16', 16))],
    ]))
    inner_lengths = [1, 0, 2, 0, 1, 0]
    output << { 'id' => 'nested_sites', 'declared_type' => nested_type, 'shape' => nested_shape,
      'rows' => 6.times.map do |row|
        Array.new(parent_lengths[row]) do |entry|
          { 'direct' => vector9('Int8', row + entry + 2),
            'children' => vectors('BFloat16', 16, inner_lengths[(row + entry) % inner_lengths.length], row + entry) }
        end
      end }

    output << { 'id' => 'map_value_site', 'declared_type' => 'Map(String, QBit(Float32, 9))',
      'shape' => [:map, [:string], qnode('Float32', 9)],
      'rows' => 6.times.map do |row|
        Array.new(parent_lengths[row]) { |entry| ["k#{row}_#{entry}", vector9('Float32', row + entry)] }
      end }
    output << { 'id' => 'map_key_site', 'declared_type' => 'Map(QBit(Int8, 9), UInt64)',
      'shape' => [:map, qnode('Int8', 9), [:uint64]],
      'rows' => 6.times.map do |row|
        Array.new(parent_lengths[row]) { |entry| [vector9('Int8', row + entry + 1), row * 100 + entry] }
      end }

    nullable_type = 'Nullable(Tuple(direct QBit(Int8, 9), children Array(QBit(BFloat16, 16))))'
    nullable_shape = [:nullable, tuple_node([
      ['direct', qnode('Int8', 9)], ['children', array_node(qnode('BFloat16', 16))],
    ])]
    nullable_rows = 6.times.map do |row|
      if [1, 3].include?(row)
        nil
      else
        { 'direct' => vector9('Int8', row + 3),
          'children' => vectors('BFloat16', 16, [2, 0, 1, 0, 1, 0][row], row + 1) }
      end
    end
    output << { 'id' => 'nullable_tuple_hidden', 'declared_type' => nullable_type,
      'shape' => nullable_shape, 'rows' => nullable_rows }
    assert!(output.length == 8 && output.map { |item| item.fetch('id') }.uniq.length == 8,
      'fixed W231 profile roster is not exactly eight unique IDs')
    assert!(output.all? { |item| item.fetch('rows').length == ROW_KEYS.length }, 'fixed row count differs')
    output
  end

  def encode(shape, value, where)
    case shape.fetch(0)
    when :qbit
      carrier, dimension = shape.fetch(1), shape.fetch(2)
      assert!(value.is_a?(String) && /\A(?:[0-9a-f]{2})+\z/.match?(value), "#{where} QBit hex malformed")
      raw = [value].pack('H*').b
      width = BYTE_VALUES.fetch(carrier).first.bytesize / 2
      assert!(raw.bytesize == width * dimension, "#{where} QBit length differs")
      varuint(dimension) + raw
    when :array
      assert!(value.is_a?(Array), "#{where} Array is not an array")
      varuint(value.length) + value.each_with_index.map { |child, index| encode(shape.fetch(1), child, "#{where}[#{index}]") }.join.b
    when :tuple
      fields = shape.fetch(1)
      assert!(value.is_a?(Hash) && value.keys.sort == fields.map(&:first).sort, "#{where} tuple fields differ")
      fields.map { |name, child| encode(child, value.fetch(name), "#{where}.#{name}") }.join.b
    when :nullable
      value.nil? ? "\x01".b : "\x00".b + encode(shape.fetch(1), value, where)
    when :map
      key_shape, value_shape = shape.fetch(1), shape.fetch(2)
      assert!(value.is_a?(Array), "#{where} Map is not entry-pairs")
      varuint(value.length) + value.each_with_index.map do |pair, index|
        assert!(pair.is_a?(Array) && pair.length == 2, "#{where} map entry #{index} is malformed")
        encode(key_shape, pair[0], "#{where}.key[#{index}]") + encode(value_shape, pair[1], "#{where}.value[#{index}]")
      end.join.b
    when :string
      assert!(value.is_a?(String), "#{where} String value is malformed")
      raw = value.encode(Encoding::UTF_8).b
      varuint(raw.bytesize) + raw
    when :uint64
      uint64_le(value)
    else
      raise "W231 AUDIT FAIL: unsupported literal node #{shape.fetch(0).inspect}"
    end
  end

  def rowbinary(profile, index)
    uint64_le(ROW_KEYS.fetch(index)) + encode(profile.fetch('shape'), profile.fetch('rows').fetch(index), profile.fetch('id'))
  end

  def rowbinary_hex(profile)
    profile.fetch('rows').each_index.map { |index| rowbinary(profile, index).unpack1('H*') }
  end

  def window_bytes(profile, window)
    indices = case window
              when 'full' then (0...ROW_KEYS.length).to_a
              when 'middle' then [2, 3]
              when 'zero' then []
              else raise "W231 AUDIT FAIL: unexpected fixed query window #{window}"
              end
    indices.map { |index| rowbinary(profile, index) }.join.b
  end

  def table_name(profile, side)
    "w231_#{side}_#{profile.fetch('id')}"
  end

  def create_sql(table, profile)
    "CREATE TABLE default.#{table} (id UInt64, q #{profile.fetch('declared_type')} CODEC(LZ4)) " \
      "ENGINE=MergeTree ORDER BY id SETTINGS #{SETTINGS.join(', ')}"
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
    filter = case window
             when 'full' then ''
             when 'middle' then ' WHERE id BETWEEN 3 AND 4'
             when 'zero' then ' WHERE id=0'
             else raise "W231 AUDIT FAIL: unexpected query window #{window}"
             end
    "SELECT id, q FROM default.#{table}#{filter} ORDER BY id FORMAT RowBinary"
  end

  def expected_schema(profile)
    "id\t#{'UInt64'.unpack1('H*')}\nq\t#{profile.fetch('declared_type').unpack1('H*')}\n"
  end

  def clickhouse_argv(store, sql)
    [CLICKHOUSE_BIN, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
      '--max_insert_threads=1', '--max_execution_time=30', "--max_memory_usage=#{MEMORY_LIMIT_BYTES}",
      '--print_pretty_type_names=0', '--flatten_nested=0', '--multiquery', '--query', sql]
  end

  def invocations(source_root, evidence_root, helper)
    stock = []
    pin_store = File.join(source_root, 'stores', 'pins')
    stock << ['runtime-version-pin', pin_store, 'SELECT version() FORMAT TSVRaw', nil, nil, PROCESS_TIMEOUT_SECONDS]
    stock << ['runtime-build-pin', pin_store,
      "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw", nil, nil, PROCESS_TIMEOUT_SECONDS]
    profiles.each do |profile|
      id = profile.fetch('id')
      table = table_name(profile, 'stock')
      store = File.join(source_root, 'stores', id)
      input = profile.fetch('rows').each_index.map { |index| rowbinary(profile, index) }.join.b
      stock << ["stock-create-#{id}", store, create_sql(table, profile), nil, nil, PROCESS_TIMEOUT_SECONDS]
      stock << ["stock-insert-#{id}", store, "INSERT INTO default.#{table} FORMAT RowBinary", input, nil, PROCESS_TIMEOUT_SECONDS]
      stock << ["stock-check-#{id}", store, check_sql(table), nil, nil, PROCESS_TIMEOUT_SECONDS]
      stock << ["stock-schema-#{id}", store, schema_sql(table), nil, nil, PROCESS_TIMEOUT_SECONDS]
      stock << ["stock-part-#{id}", store, part_sql(table), nil, nil, PROCESS_TIMEOUT_SECONDS]
      %w[full middle zero].each do |window|
        stock << ["stock-rowbinary-#{id}-#{window}", store, rowbinary_sql(table, window), nil, nil, PROCESS_TIMEOUT_SECONDS]
      end
    end

    library_root = File.join(evidence_root, 'generated', 'parts')
    input_path = File.join(evidence_root, 'generated', 'helper-input.json')
    evidence = [['helper-read-write-roundtrip', File.join(evidence_root, 'generated'), nil, nil,
      [helper, '--input', input_path], HELPER_TIMEOUT_SECONDS]]
    profiles.each do |profile|
      id = profile.fetch('id')
      table = table_name(profile, 'native')
      store = File.join(evidence_root, 'stores', id)
      evidence << ["native-create-#{id}", store, create_sql(table, profile), nil, nil, PROCESS_TIMEOUT_SECONDS]
      evidence << ["native-data-path-#{id}", store,
        "SELECT arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw", nil, nil, PROCESS_TIMEOUT_SECONDS]
      evidence << ["native-attach-#{id}", store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'", nil, nil, PROCESS_TIMEOUT_SECONDS]
      evidence << ["native-check-#{id}", store, check_sql(table), nil, nil, PROCESS_TIMEOUT_SECONDS]
      evidence << ["native-schema-#{id}", store, schema_sql(table), nil, nil, PROCESS_TIMEOUT_SECONDS]
      evidence << ["native-part-#{id}", store, part_sql(table), nil, nil, PROCESS_TIMEOUT_SECONDS]
      %w[full middle zero].each do |window|
        evidence << ["native-rowbinary-#{id}-#{window}", store, rowbinary_sql(table, window), nil, nil, PROCESS_TIMEOUT_SECONDS]
      end
    end
    [stock, evidence, library_root, input_path]
  end

  def inventory(part)
    root = plain_dir!(part, 'part directory')
    items = []
    count = 0
    bytes = 0
    Find.find(root) do |path|
      next if path == root
      count += 1
      assert!(count <= TREE_ENTRY_CAP, "part inventory exceeds entry cap: #{root}")
      assert!(!File.symlink?(path), "part contains a symlink: #{path}")
      next if File.directory?(path)
      assert!(File.file?(path), "part contains unsupported entry: #{path}")
      bytes += File.size(path)
      assert!(bytes <= TREE_BYTE_CAP, "part inventory exceeds byte cap: #{root}")
      items << { 'path' => path[(root.length + 1)..-1], 'size' => File.size(path), 'sha256' => sha256_file(path) }
    end
    items.sort_by { |item| item.fetch('path') }
  end

  def inventory_delta(before, after)
    first = before.to_h { |entry| [entry.fetch('path'), entry] }
    second = after.to_h { |entry| [entry.fetch('path'), entry] }
    [(first.keys - second.keys).sort,
     first.keys.select { |path| second.key?(path) && first.fetch(path) != second.fetch(path) }.sort,
     (second.keys - first.keys).sort]
  end

  def tsv_row!(bytes, field_count, label)
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    assert!(text.valid_encoding?, "#{label} is not UTF-8 TSV")
    lines = text.lines.map { |line| line.chomp.sub(/\r\z/, '') }
    assert!(lines.length == 1, "#{label} is not exactly one row: #{lines.inspect}")
    fields = lines.first.split("\t", -1)
    assert!(fields.length == field_count, "#{label} field count differs: #{fields.inspect}")
    fields
  end

  def expected_helper_input(source_root, evidence_root, fixture_profiles)
    generated_root = File.join(evidence_root, 'generated', 'parts')
    { 'format' => INPUT_FORMAT, 'capture_root' => source_root, 'generated_root' => generated_root,
      'profiles' => fixture_profiles.map do |profile|
        { 'id' => profile.fetch('id'), 'declared_type' => profile.fetch('declared_type'),
          'source_part_path' => File.join(source_root, 'parts', profile.fetch('id'), 'all_1_1_0'),
          'library_part_path' => File.join(generated_root, profile.fetch('id'), 'all_1_1_0'),
          'row_keys' => ROW_KEYS, 'mark_rows' => MARK_ROWS, 'rows' => profile.fetch('rows'),
          'literal_rowbinary_hex' => rowbinary_hex(profile) }
      end }
  end

  def verify_invocation_directory!(root, expected)
    directory = plain_dir!(File.join(root, 'invocations'), 'raw invocation directory')
    expected_names = expected.each_with_index.flat_map do |entry, index|
      stem = format('%04d-%s', index + 1, entry.fetch(0).gsub(/[^A-Za-z0-9_.-]/, '_'))
      suffixes = %w[.argv.json .sql .stdout .stderr .status.json]
      suffixes << '.stdin.bin' if entry.fetch(3)
      suffixes.map { |suffix| stem + suffix }
    end.sort
    assert!(Dir.children(directory).sort == expected_names,
      "raw invocation artifact roster differs: expected #{expected_names.length} files")
  end

  def verify_processes(root, expected, helper)
    expected.each_with_index.map do |entry, index|
      label, store, sql, stdin, argv_override, timeout = entry
      stem = format('%04d-%s', index + 1, label.gsub(/[^A-Za-z0-9_.-]/, '_'))
      base = File.join(root, 'invocations', stem)
      argv = JSON.parse(File.binread(plain_file!(base + '.argv.json', "#{label} argv")).force_encoding(Encoding::UTF_8))
      status = JSON.parse(File.binread(plain_file!(base + '.status.json', "#{label} status")).force_encoding(Encoding::UTF_8))
      stdout = File.binread(plain_file!(base + '.stdout', "#{label} stdout"))
      stderr = File.binread(plain_file!(base + '.stderr', "#{label} stderr"))
      expected_argv = argv_override || clickhouse_argv(store, sql)
      assert!(argv.keys.sort == %w[argv environment label stdin_bytes stdin_sha256 timeout_seconds].sort,
        "#{label} argv sidecar fields differ")
      assert!(argv.fetch('label') == label && argv.fetch('argv') == expected_argv,
        "#{label} argv differs from the independent fixed plan")
      assert!(argv.fetch('environment') == { 'TZ' => 'UTC' } && argv.fetch('timeout_seconds') == timeout,
        "#{label} environment/timeout differs")
      sql_bytes = File.binread(plain_file!(base + '.sql', "#{label} SQL"))
      assert!(sql_bytes == ((sql || '') + "\n").b, "#{label} exact SQL sidecar differs")
      stdin_path = base + '.stdin.bin'
      if stdin
        actual_stdin = File.binread(plain_file!(stdin_path, "#{label} stdin"))
        assert!(actual_stdin == stdin, "#{label} literal RowBinary insert bytes differ")
        assert!(argv.fetch('stdin_bytes') == stdin.bytesize && argv.fetch('stdin_sha256') == Digest::SHA256.hexdigest(stdin),
          "#{label} literal RowBinary metadata differs")
      else
        assert!(!File.exist?(stdin_path) && argv.fetch('stdin_bytes').nil? && argv.fetch('stdin_sha256').nil?,
          "#{label} unexpectedly has stdin")
      end
      expected_status_fields = %w[label classification duration_ms exitstatus signaled termsig timed_out spawn_error stdout_bytes stderr_bytes]
      assert!(status.keys.sort == expected_status_fields.sort, "#{label} raw process status fields differ")
      assert!(status.fetch('label') == label, "#{label} raw process status label differs")
      assert!(status.fetch('classification') == 'process_success' && status.fetch('exitstatus') == 0 &&
        status.fetch('signaled') == false && status.fetch('termsig').nil? && status.fetch('timed_out') == false &&
        status.fetch('spawn_error').nil?, "#{label} was not a clean process success")
      assert!(status.fetch('stdout_bytes') == stdout.bytesize && status.fetch('stderr_bytes') == stderr.bytesize &&
        status.fetch('duration_ms').is_a?(Integer) && status.fetch('duration_ms') >= 0,
        "#{label} raw process byte counts/duration disagree")
      assert!(label != 'helper-read-write-roundtrip' || argv.fetch('argv').first == helper,
        'helper process did not use the CLI-pinned external helper')
      { 'label' => label, 'stdout' => stdout, 'stderr' => stderr, 'status' => status, 'base' => base }
    end
  rescue JSON::ParserError => error
    raise "W231 AUDIT FAIL: malformed raw process JSON: #{error.message}"
  end

  def process_for(records, label)
    found = records.find { |item| item.fetch('label') == label }
    assert!(found, "missing raw process #{label}")
    found
  end

  def windows_for(profile, prefix, process_records)
    %w[full middle zero].to_h do |window|
      label = "#{prefix}-rowbinary-#{profile.fetch('id')}-#{window}"
      actual = process_for(process_records, label).fetch('stdout')
      expected = window_bytes(profile, window)
      assert!(actual == expected, "#{label} raw RowBinary differs from independently encoded literals")
      [window, { 'bytes' => actual.bytesize, 'sha256' => Digest::SHA256.hexdigest(actual),
        'matches_independent_literal' => true }]
    end
  end

  def validate_stock(source_root, profile, source_processes)
    id = profile.fetch('id')
    table = table_name(profile, 'stock')
    check = process_for(source_processes, "stock-check-#{id}").fetch('stdout')
    assert!(check == "all_1_1_0\t1\t\n", "stock CHECK for #{id} must be one exact success row with an empty message")
    schema = process_for(source_processes, "stock-schema-#{id}").fetch('stdout')
    assert!(schema == expected_schema(profile), "stock exact schema hex differs for #{id}")
    fields = tsv_row!(process_for(source_processes, "stock-part-#{id}").fetch('stdout'), 5, "stock part #{id}")
    assert!(fields[0, 4] == ['all_1_1_0', '6', '4', 'Wide'], "stock part identity/grid differs for #{id}")
    isolated_store = File.join(source_root, 'stores', id)
    actual = File.expand_path(fields[4])
    assert!(actual.start_with?(isolated_store + File::SEPARATOR), "stock part path escaped its isolated store for #{id}")
    plain_dir!(actual, "stock part #{id}")
    captured = File.join(source_root, 'parts', id, 'all_1_1_0')
    copied_inventory = inventory(captured)
    assert!(inventory(actual) == copied_inventory, "captured stock part bytes differ from actual part for #{id}")
    part_windows = windows_for(profile, 'stock', source_processes)
    record = { 'id' => id, 'declared_type' => profile.fetch('declared_type'), 'table' => table,
      'store' => isolated_store, 'source_part_path' => captured, 'source_part_inventory' => copied_inventory,
      'rows' => profile.fetch('rows'), 'row_keys' => ROW_KEYS, 'mark_rows' => MARK_ROWS,
      'check_output' => check, 'schema_output' => schema, 'windows' => part_windows }
    case_file = read_json(File.join(source_root, 'cases', "#{id}.json"), "stock case #{id}")
    assert!(case_file == record, "stock case copy for #{id} differs from independently recomputed raw evidence")
    record
  end

  def validate_helper(source_root, evidence_root, helper, expected_sha, helper_process, fixture_profiles)
    helper = plain_file!(helper, 'external helper', executable: true)
    assert!(sha256_file(helper) == expected_sha, 'external helper current SHA differs from CLI pin')
    input_path = File.join(evidence_root, 'generated', 'helper-input.json')
    input = read_json(input_path, 'helper input manifest')
    expected_input = expected_helper_input(source_root, evidence_root, fixture_profiles)
    assert!(input == expected_input, 'helper input manifest differs from independent fixed profile bytes')
    raw_stdout = helper_process.fetch('stdout')
    output = JSON.parse(raw_stdout.dup.force_encoding(Encoding::UTF_8))
    assert!(output.fetch('format') == HELPER_FORMAT && output.fetch('profile_count') == fixture_profiles.length,
      'helper raw stdout magic/profile count differs')
    expected_profiles = expected_input.fetch('profiles')
    output_profiles = output.fetch('profiles')
    assert!(output_profiles.length == expected_profiles.length, 'helper output profile count differs')
    output_profiles.zip(expected_profiles).each do |actual, expected|
      fields = %w[declared_type id library_part_path library_rows mark_rows row_keys source_part_path source_rows]
      assert!(actual.keys.sort == fields.sort, "helper output field roster differs for #{expected.fetch('id')}")
      %w[id declared_type library_part_path mark_rows row_keys source_part_path].each do |field|
        assert!(actual.fetch(field) == expected.fetch(field), "helper output #{field} differs for #{expected.fetch('id')}")
      end
      assert!(actual.fetch('source_rows') == expected.fetch('rows') && actual.fetch('library_rows') == expected.fetch('rows'),
        "helper source/library semantic rows differ for #{expected.fetch('id')}")
      source_part = expected.fetch('source_part_path')
      assert!(plain_dir!(source_part, "helper source part #{expected.fetch('id')}") == source_part,
        "helper source path is noncanonical for #{expected.fetch('id')}")
      library_part = expected.fetch('library_part_path')
      allowed = File.realpath(File.join(evidence_root, 'generated', 'parts')) + File::SEPARATOR
      assert!(library_part.start_with?(allowed), "helper part escaped generated root for #{expected.fetch('id')}")
      assert!(plain_dir!(library_part, "helper library part #{expected.fetch('id')}") == library_part,
        "helper library path is noncanonical for #{expected.fetch('id')}")
      assert!(!inventory(source_part).empty? && !inventory(library_part).empty?,
        "source/library part inventory is empty for #{expected.fetch('id')}")
    end
    copied_output = read_json(File.join(evidence_root, 'generated', 'helper-output.json'), 'helper output copy')
    assert!(copied_output == output, 'helper output copy differs from raw stdout JSON')
    { 'output' => output, 'input_path' => input_path, 'input_sha256' => sha256_file(input_path),
      'stdout_sha256' => Digest::SHA256.hexdigest(raw_stdout) }
  rescue JSON::ParserError => error
    raise "W231 AUDIT FAIL: helper stdout is malformed JSON: #{error.message}"
  end

  def validate_native(evidence_root, profile, evidence_processes, helper_profile)
    id = profile.fetch('id')
    table = table_name(profile, 'native')
    store = File.join(evidence_root, 'stores', id)
    data_row = process_for(evidence_processes, "native-data-path-#{id}").fetch('stdout')
    data_path = File.expand_path(data_row.strip)
    assert!(data_path.start_with?(store + File::SEPARATOR), "native data path escaped isolated store for #{id}")
    assert!(plain_dir!(data_path, "native data path #{id}") == data_path, "native data path is noncanonical for #{id}")
    detached = File.join(data_path, 'detached')
    plain_dir!(detached, "native detached directory #{id}")
    check = process_for(evidence_processes, "native-check-#{id}").fetch('stdout')
    assert!(check == "all_1_1_0\t1\t\n", "native CHECK for #{id} must be one exact success row with an empty message")
    schema = process_for(evidence_processes, "native-schema-#{id}").fetch('stdout')
    assert!(schema == expected_schema(profile), "native exact schema hex differs for #{id}")
    fields = tsv_row!(process_for(evidence_processes, "native-part-#{id}").fetch('stdout'), 5, "native part #{id}")
    attached = File.join(data_path, 'all_1_1_0')
    assert!(fields[0, 4] == ['all_1_1_0', '6', '4', 'Wide'] && File.expand_path(fields[4]) == attached,
      "native attached part identity/grid/path differs for #{id}")
    generated = helper_profile.fetch('library_part_path')
    generated_inventory = inventory(generated)
    attached_inventory = inventory(attached)
    removed, changed, added = inventory_delta(generated_inventory, attached_inventory)
    assert!(removed.empty? && changed.empty? && added == [INVALIDATED_FILE],
      "ATTACH retained-part inventory differs for #{id}: removed=#{removed.inspect}, changed=#{changed.inspect}, added=#{added.inspect}")
    invalidated = File.binread(File.join(attached, INVALIDATED_FILE)).split("\n", -1)
    assert!(invalidated.pop == '' && invalidated.sort == INVALIDATED_NAMES.sort,
      "ATTACH invalidated-system-columns bytes differ for #{id}")
    expected_columns = "columns format version: 1\n2 columns:\n`id` UInt64\n`q` #{profile.fetch('declared_type')}\n"
    columns_bytes = File.binread(File.join(attached, 'columns.txt'))
    assert!(columns_bytes == expected_columns.b, "ATTACH exact columns.txt differs for #{id}")
    codec = File.binread(File.join(attached, 'default_compression_codec.txt')).strip
    assert!(codec == 'CODEC(LZ4)', "ATTACH default codec differs for #{id}")
    metadata = File.binread(File.join(attached, 'metadata_version.txt')).strip
    assert!(metadata == '0', "ATTACH metadata version differs for #{id}")
    windows = windows_for(profile, 'native', evidence_processes)
    record = { 'id' => id, 'table' => table, 'declared_type' => profile.fetch('declared_type'),
      'helper_part_path' => generated, 'attached_part_path' => attached,
      'helper_part_inventory' => generated_inventory, 'attached_part_inventory' => attached_inventory,
      'removed_paths' => removed, 'changed_paths' => changed, 'added_paths' => added,
      'check_output' => check, 'schema_output' => schema,
      'columns_sha256' => Digest::SHA256.hexdigest(columns_bytes),
      'default_compression_codec' => codec, 'metadata_version' => metadata, 'windows' => windows }
    case_file = read_json(File.join(evidence_root, 'cases', "#{id}.json"), "native case #{id}")
    assert!(case_file == record, "native case copy for #{id} differs from independently recomputed raw evidence")
    record
  end

  def verify_layout!(source_root, evidence_root, fixture_profiles)
    ids = fixture_profiles.map { |profile| profile.fetch('id') }
    assert!(Dir.children(source_root).sort == %w[cases invocations parts physical.after-helper.json physical.post.json physical.pre.json source-pin-post.json source-pin.json stores].sort,
      'stock root contains an unexpected or missing top-level artifact')
    assert!(Dir.children(evidence_root).sort == %w[cases generated invocations result.json stores].sort,
      'evidence root contains an unexpected or missing top-level artifact')
    assert!(Dir.children(File.join(source_root, 'parts')).sort == ids.sort, 'stock part-profile directory roster differs')
    assert!(Dir.children(File.join(source_root, 'cases')).sort == (ids + ids.map { |id| "#{id}.json" }).sort,
      'stock case directory/file roster differs')
    assert!(Dir.children(File.join(evidence_root, 'cases')).sort == (ids + ids.map { |id| "#{id}.json" }).sort,
      'native case directory/file roster differs')
    (ids).each do |id|
      assert!(Dir.children(File.join(source_root, 'cases', id)).empty?, "stock case scratch directory is not empty: #{id}")
      assert!(Dir.children(File.join(evidence_root, 'cases', id)).empty?, "native case scratch directory is not empty: #{id}")
      assert!(Dir.children(File.join(source_root, 'parts', id)).sort == ['all_1_1_0'], "stock part path roster differs for #{id}")
      assert!(Dir.children(File.join(evidence_root, 'generated', 'parts', id)).sort == ['all_1_1_0'], "library part path roster differs for #{id}")
    end
    assert!(Dir.children(File.join(source_root, 'stores')).sort == (ids + ['pins']).sort, 'stock store roster differs')
    assert!(Dir.children(File.join(evidence_root, 'stores')).sort == ids.sort, 'native store roster differs')
    assert!(Dir.children(File.join(evidence_root, 'generated')).sort == %w[helper-input.json helper-output.json library-physical.json parts].sort,
      'generated helper artifact roster differs')
  end

  def validate!(options)
    source_root = bounded_root!(options.fetch(:source_root), SOURCE_PREFIX, 'stock root')
    evidence_root = bounded_root!(options.fetch(:evidence_root), EVIDENCE_PREFIX, 'evidence root')
    helper = File.expand_path(options.fetch(:helper))
    helper_sha = options.fetch(:helper_sha256)
    assert!(/\A[0-9a-f]{64}\z/.match?(helper_sha), 'external helper SHA-256 must be lowercase 64-hex')
    binary = plain_file!(CLICKHOUSE_BIN, 'separately pinned ClickHouse runtime', executable: true)
    assert!(binary == CLICKHOUSE_BIN && sha256_file(binary) == CLICKHOUSE_SHA256,
      'ClickHouse runtime binary differs from pinned path/SHA')
    fixture_profiles = profiles
    verify_layout!(source_root, evidence_root, fixture_profiles)

    result = read_json(File.join(evidence_root, 'result.json'), 'runner result')
    assert!(result.fetch('format') == RESULT_FORMAT &&
      result.fetch('classification') == 'paired_recursive_qbit_static_profiles_observed' && result.fetch('success') == true,
      'runner result format/classification/success differs')
    assert!(result.fetch('source_root') == source_root && result.fetch('evidence_root') == evidence_root,
      'runner result capture roots differ from CLI roots')
    expected_runtime_pin = { 'binary' => binary, 'sha256' => CLICKHOUSE_SHA256, 'version' => CLICKHOUSE_VERSION,
      'build_hash' => CLICKHOUSE_BUILD, 'source_correlation' => 'runtime binary and source checkout are separately pinned' }
    assert!(result.fetch('runtime_pin') == expected_runtime_pin, 'runtime pin record differs')
    source_pin = source_manifest
    assert!(result.fetch('source_pin') == source_pin, 'result source pin differs from recomputed selected source hashes')
    assert!(read_json(File.join(source_root, 'source-pin.json'), 'captured source pin') == source_pin &&
      read_json(File.join(source_root, 'source-pin-post.json'), 'captured source pin post') == source_pin,
      'captured source pin files differ from current selected source hashes')

    source_expected, evidence_expected, library_root, input_path = invocations(source_root, evidence_root, helper)
    verify_invocation_directory!(source_root, source_expected)
    verify_invocation_directory!(evidence_root, evidence_expected)
    source_processes = verify_processes(source_root, source_expected, helper)
    evidence_processes = verify_processes(evidence_root, evidence_expected, helper)
    assert!(source_processes.fetch(0).fetch('stdout').strip == CLICKHOUSE_VERSION, 'raw runtime version pin differs')
    assert!(source_processes.fetch(1).fetch('stdout').strip == "VERSION_GITHASH=#{CLICKHOUSE_BUILD}",
      'raw runtime build-hash pin differs')

    expected_rosters = { 'source' => source_expected.map(&:first), 'evidence' => evidence_expected.map(&:first) }
    assert!(result.fetch('process_rosters') == expected_rosters, 'result process roster differs from actual fixed invocation roster')
    expected_counts = { 'source_processes' => source_expected.length, 'evidence_processes' => evidence_expected.length,
      'profiles' => 8, 'source_parts' => 8, 'library_parts' => 8, 'attached_parts' => 8 }
    assert!(result.fetch('counts') == expected_counts && result.fetch('profile_count') == 8,
      'result process/profile counts differ from fixed roster')
    expected_scope = 'eight fixed static QBit product fixtures: Tuple sibling arrays/direct nullable, Array(Tuple), Nested, BASIC Map key/value and Nullable(Tuple); no Variant/runtime envelope/LowCardinality widening'
    assert!(result.fetch('scope') == expected_scope, 'result scope claim differs from frozen W231 boundary')

    source_records = fixture_profiles.map { |profile| validate_stock(source_root, profile, source_processes) }
    inventory_records = source_records.map do |record|
      { 'id' => record.fetch('id'), 'inventory' => inventory(record.fetch('source_part_path')) }
    end
    expected_physical = { 'format' => 'recursive_qbit_static_w231_source_physical_v1', 'profiles' => inventory_records }
    %w[physical.pre.json physical.after-helper.json physical.post.json].each do |name|
      assert!(read_json(File.join(source_root, name), name) == expected_physical,
        "#{name} differs from independently inventoried source part files")
    end
    assert!(result.fetch('stock_profiles') == source_records, 'result stock profiles differ from raw stock evidence')

    helper_process = process_for(evidence_processes, 'helper-read-write-roundtrip')
    helper_audit = validate_helper(source_root, evidence_root, helper, helper_sha, helper_process, fixture_profiles)
    assert!(result.fetch('helper_path') == helper && result.fetch('helper_sha256_expected') == helper_sha &&
      result.fetch('helper_sha256_observed_after') == helper_sha, 'result helper path/SHA differs from caller pin')
    assert!(result.fetch('helper_input_path') == input_path &&
      result.fetch('helper_input_sha256') == helper_audit.fetch('input_sha256'), 'result helper input path/hash differs from raw manifest')
    assert!(result.fetch('helper_stdout_sha256') == helper_audit.fetch('stdout_sha256'),
      'result helper stdout hash differs from raw helper output')
    assert!(result.fetch('helper_output') == helper_audit.fetch('output'), 'result helper output differs from raw stdout JSON')

    helper_profiles = helper_audit.fetch('output').fetch('profiles')
    native_records = fixture_profiles.zip(helper_profiles).map do |profile, helper_profile|
      validate_native(evidence_root, profile, evidence_processes, helper_profile)
    end
    library_inventories = helper_profiles.map do |item|
      { 'id' => item.fetch('id'), 'path' => item.fetch('library_part_path'),
        'inventory' => inventory(item.fetch('library_part_path')) }
    end
    physical_library = { 'format' => 'recursive_qbit_static_w231_library_physical_v1', 'profiles' => library_inventories }
    assert!(read_json(File.join(evidence_root, 'generated', 'library-physical.json'), 'library physical inventory') == physical_library,
      'library physical inventory copy differs from recomputed part files')
    assert!(result.fetch('library_inventories') == library_inventories, 'result library inventory differs from actual part files')
    assert!(result.fetch('native_profiles') == native_records, 'result native profiles differ from raw native evidence')

    actual_code_pins = %w[
      scripts/recheck_recursive_qbit_static_w231.rb
      scripts/check_recursive_qbit_static_evidence_w231.rb
      scripts/recheck_aggregate_recursive_w224.rb
    ].to_h do |relative|
      [relative, sha256_file(File.join(REPO_ROOT, relative))]
    end
    assert!(result.fetch('code_pins') == actual_code_pins, 'capture/audit/recorder code hashes are stale')
    puts "W231 raw evidence audit: 8 static QBit product profiles, #{source_expected.length} stock and #{evidence_expected.length} evidence processes; exact CHECK, RowBinary, schemas and inventories agree."
    true
  end

  def main(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/check_recursive_qbit_static_evidence_w231.rb --source-root ROOT --evidence-root ROOT --helper BIN --helper-sha256 SHA'
      opts.on('--source-root PATH') { |value| options[:source_root] = value }
      opts.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
      opts.on('--helper PATH') { |value| options[:helper] = value }
      opts.on('--helper-sha256 SHA') { |value| options[:helper_sha256] = value }
    end
    parser.parse!(argv)
    assert!(argv.empty? && %i[source_root evidence_root helper helper_sha256].all? { |key| options.key?(key) }, parser.to_s)
    validate!(options)
  rescue StandardError => error
    warn "W231 evidence audit failed: #{error.class}: #{error.message}"
    false
  end
end

if $PROGRAM_NAME == __FILE__
  exit(CheckRecursiveQBitStaticEvidenceW231.main(ARGV) ? 0 : 1)
end
