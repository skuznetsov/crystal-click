#!/usr/bin/env ruby
# Stock-only persistence capture for QBit products inside Dynamic and
# Array(Dynamic). This runner does not invoke a library helper or compiler.

require 'digest'
require 'find'
require 'json'
require 'optparse'
require_relative 'recheck_aggregate_recursive_w224'

module RecheckRecursiveQBitDynamicW233
  extend self

  R = RecheckAggregateRecursiveW224
  SOURCE_ROOT = '/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1'.freeze
  SOURCE_REVISION = '0ca8150d9b1d0886edb2e3b4ab65eebb768d0357'.freeze
  CLICKHOUSE_BIN = '/private/tmp/crystal-click-w216-runtime-recovery.DmL9Kw/clickhouse-stripped'.freeze
  CLICKHOUSE_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  CLICKHOUSE_VERSION = '26.10.1.1201'.freeze
  CLICKHOUSE_BUILD = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  ROOT_PREFIX = 'crystal-click-w233-stock.'.freeze
  TABLE = 'w233_recursive_qbit_dynamic'.freeze
  MAP_PROBE_TABLE = 'w233_recursive_qbit_dynamic_map_probe'.freeze
  ROW_KEYS = [1, 2, 3, 4, 5, 6].freeze
  MARK_ROWS = [2, 2, 2].freeze
  PART_MARKS = 4
  MEMORY_LIMIT_BYTES = 1_073_741_824
  MAX_PROCESS_COUNT = 13
  MAX_CAPTURE_FILES = 4096
  MAX_CAPTURE_BYTES = 64 * 1024 * 1024

  STOCK_SETTINGS = [
    'index_granularity=2', 'index_granularity_bytes=10485760',
    'enable_mixed_granularity_parts=1', 'min_rows_for_wide_part=0',
    'min_bytes_for_wide_part=0', 'min_level_for_wide_part=0',
    'compress_marks=0', 'compress_primary_key=0', 'min_compress_block_size=0',
    'max_compress_block_size=4096', 'ratio_of_defaults_for_sparse_serialization=1.0',
    'compute_exact_num_defaults_for_sparse_columns=0', "default_compression_codec='LZ4'",
    "nullable_serialization_version='basic'", "string_serialization_version='single_stream'",
    "map_serialization_version='basic'", "map_serialization_version_for_zero_level_parts='basic'",
    "dynamic_serialization_version='v3'", "serialization_info_version='with_types'",
    'propagate_types_serialization_versions_to_nested_types=1',
    'use_compact_variant_discriminators_serialization=0',
  ].freeze

  # These are literal RowBinary type descriptors from the pinned
  # DataTypesBinaryEncoding grammar; Dynamic values carry descriptor + body.
  QBIT_DESC = [0x36, 0x07, 0x09].pack('C*').b.freeze # QBit(Int8, 9)
  ARRAY_QBIT_DESC = [0x1e].pack('C*').b + QBIT_DESC
  TUPLE_QBIT_U8_DESC = [0x20, 0x02, 0x01, 0x71].pack('C*').b + QBIT_DESC + [0x01, 0x6e, 0x01].pack('C*').b
  MAP_STRING_QBIT_DESC = [0x27, 0x15].pack('C*').b + QBIT_DESC
  ARRAY_VARIANT_QBIT_U64_DESC = [0x1e, 0x2a, 0x02].pack('C*').b + QBIT_DESC + [0x04].pack('C*').b

  def fail!(message)
    raise ArgumentError, message
  end

  def require_true(condition, message)
    fail!(message) unless condition
  end

  def write_new(path, bytes)
    R.write_new(path, bytes)
  end

  def make_dir(path)
    R.make_dir(path)
  end

  def sha256_file(path)
    Digest::SHA256.file(path).hexdigest
  end

  def validate_root(path)
    full = File.expand_path(path)
    require_true(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full && Dir.children(full).empty?,
      'capture root must be a fresh, empty, canonical directory')
    require_true(File.dirname(full) == File.realpath('/private/tmp') && File.basename(full).start_with?(ROOT_PREFIX),
      "capture root must be a direct /private/tmp child named #{ROOT_PREFIX}*")
    full
  end

  def validate_binary(path)
    full = File.expand_path(path)
    require_true(File.file?(full) && !File.symlink?(full) && File.realpath(full) == full && File.executable?(full),
      "ClickHouse runtime is absent, noncanonical, symlinked, or not executable: #{full}")
    require_true(full == CLICKHOUSE_BIN && sha256_file(full) == CLICKHOUSE_SHA256,
      'ClickHouse runtime differs from the fixed path/SHA pin')
    full
  end

  def varuint(value)
    require_true(value.is_a?(Integer) && value >= 0 && value <= 18_446_744_073_709_551_615,
      "invalid VarUInt literal: #{value.inspect}")
    bytes = []
    while value >= 0x80
      bytes << ((value & 0x7f) | 0x80)
      value >>= 7
    end
    (bytes << value).pack('C*').b
  end

  def uint64(value)
    require_true(value.is_a?(Integer) && value >= 0 && value <= 18_446_744_073_709_551_615,
      "invalid UInt64 literal: #{value.inspect}")
    Array.new(8) { |index| (value >> (index * 8)) & 0xff }.pack('C*').b
  end

  def string_bytes(value)
    bytes = value.encode(Encoding::UTF_8).b
    varuint(bytes.bytesize) + bytes
  end

  def qbit_bytes(hex)
    require_true(hex.match?(/\A(?:[0-9a-f]{2}){9}\z/), 'literal QBit(Int8, 9) width differs')
    varuint(9) + [hex].pack('H*').b
  end

  def dynamic_bytes(type_descriptor, value_bytes)
    type_descriptor + value_bytes
  end

  # Deliberately separate from rowbinary_rows, which is the expected full /
  # middle / zero output oracle for the six-row CAST probe.
  def map_ingestion_probe_input
    [
      0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, # UInt64 id=4, LE
      0x27, 0x15, 0x36, 0x07, 0x09,                   # Map(String, QBit(Int8, 9))
      0x01, 0x01, 0x61, 0x09,                         # one entry: key='a', QBit dimension=9
      0x09, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
      0x27, 0x15, 0x36, 0x07, 0x09,                   # same Dynamic descriptor, shared route
      0x01, 0x01, 0x61, 0x09,
      0x09, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
    ].pack('C*').b
  end

  def map_ingestion_probe_expected
    [
      0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, # UInt64 id=4, LE
      0x27, 0x15, 0x36, 0x07, 0x09,
      0x01, 0x01, 0x61, 0x09,
      0x09, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
      0x27, 0x15, 0x36, 0x07, 0x09,
      0x01, 0x01, 0x61, 0x09,
      0x09, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,
    ].pack('C*').b
  end

  def rowbinary_rows
    q2 = qbit_bytes('010203040506070809')
    q3 = qbit_bytes('ff0001020408102040')
    q4 = qbit_bytes('090807060504030201')
    q5 = qbit_bytes('020406080a0c0e1012')

    values = [
      [ARRAY_QBIT_DESC, varuint(0)],
      [ARRAY_QBIT_DESC, varuint(1) + q2],
      [TUPLE_QBIT_U8_DESC, q3 + [7].pack('C').b],
      [MAP_STRING_QBIT_DESC, varuint(1) + string_bytes('a') + q4],
      [ARRAY_VARIANT_QBIT_U64_DESC, varuint(1) + [0].pack('C').b + q5],
      [[0x00].pack('C').b, ''.b],
    ].map { |descriptor, body| dynamic_bytes(descriptor, body) }

    carrier = [
      varuint(0),
      varuint(1) + values[1],
      varuint(1) + values[2],
      varuint(1) + values[3],
      varuint(1) + values[4],
      varuint(1) + values[5],
    ]

    ROW_KEYS.each_index.map do |index|
      uint64(ROW_KEYS.fetch(index)) + values.fetch(index) + values.fetch(index) + carrier.fetch(index)
    end
  end

  # Input is independently authored from rowbinary_rows, which remains the
  # expected SELECT output oracle. Input order follows the declared schema:
  # id, root_d, carrier, shared_d.
  def rowbinary_insert_rows
    roots = [
      '1e36070900',
      '1e3607090109010203040506070809',
      '20020171360709016e0109ff000102040810204007',
      '271536070901016109090807060504030201',
      '1e2a0236070904010009020406080a0c0e1012',
      '00',
    ].map { |hex| [hex].pack('H*').b }
    carriers = ["\x00".b] + roots.drop(1).map { |value| "\x01".b + value }

    ROW_KEYS.each_index.map do |index|
      uint64(ROW_KEYS.fetch(index)) + roots.fetch(index) + carriers.fetch(index) + roots.fetch(index)
    end
  end

  def map_cast_diagnostic_sql
    qbit = "CAST([9, 8, 7, 6, 5, 4, 3, 2, 1], 'QBit(Int8, 9)')"
    map = "CAST(map('a', #{qbit}), 'Map(String, QBit(Int8, 9))')"
    "SELECT dynamicType(CAST(#{map}, 'Dynamic(max_types=4)')) SETTINGS print_pretty_type_names=0 FORMAT TSVRaw"
  end

  def clickhouse_argv(binary, store, sql)
    [binary, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
      '--max_insert_threads=1', '--max_execution_time=30', "--max_memory_usage=#{MEMORY_LIMIT_BYTES}",
      '--print_pretty_type_names=0', '--flatten_nested=0', '--multiquery', '--query', sql]
  end

  def inventory(path)
    full = File.realpath(path)
    entries = []
    count = 0
    bytes = 0
    Find.find(full) do |entry|
      next if entry == full || File.directory?(entry)
      require_true(!File.symlink?(entry) && File.file?(entry), "unsupported evidence file: #{entry}")
      count += 1
      bytes += File.size(entry)
      require_true(count <= MAX_CAPTURE_FILES && bytes <= MAX_CAPTURE_BYTES, 'capture exceeds fixed inventory bounds')
      next if File.basename(entry) == 'capture_inventory.json'
      entries << { 'path' => entry[(full.length + 1)..-1], 'size' => File.size(entry), 'sha256' => sha256_file(entry) }
    end
    entries.sort_by { |entry| entry.fetch('path') }
  end

  def check_sql
    "CHECK TABLE default.#{TABLE} FORMAT TSVRaw"
  end

  def schema_sql
    "SELECT name, type FROM system.columns WHERE database='default' AND table='#{TABLE}' ORDER BY position FORMAT TSVRaw"
  end

  def roster_sql
    "SELECT id, " \
      "if(isNull(root_d), 'NULL', dynamicType(root_d)), " \
      "if(isNull(root_d), '-', toString(toUInt8(isDynamicElementInSharedData(root_d)))), " \
      "if(isNull(shared_d), 'NULL', dynamicType(shared_d)), " \
      "if(isNull(shared_d), '-', toString(toUInt8(isDynamicElementInSharedData(shared_d)))) " \
      "FROM default.#{TABLE} ORDER BY id SETTINGS print_pretty_type_names=0 FORMAT TSVRaw"
  end

  def carrier_roster_sql
    "SELECT id, arrayStringConcat(arrayMap(x -> if(isNull(x), 'NULL', " \
      "concat(dynamicType(x), ':', toString(toUInt8(isDynamicElementInSharedData(x))))), carrier), '|') " \
      "FROM default.#{TABLE} ORDER BY id SETTINGS print_pretty_type_names=0 FORMAT TSVRaw"
  end

  def window_sql(window)
    predicate = { 'full' => '', 'middle' => ' WHERE id BETWEEN 3 AND 4', 'zero' => ' WHERE id=0' }.fetch(window)
    "SELECT id, root_d, shared_d, carrier FROM default.#{TABLE}#{predicate} ORDER BY id FORMAT RowBinary"
  end

  class Probe
    def initialize(options)
      @binary = RecheckRecursiveQBitDynamicW233.validate_binary(options.fetch(:clickhouse))
      @root = RecheckRecursiveQBitDynamicW233.validate_root(options.fetch(:capture_root))
      @recorder = R::Recorder.new(@root, @binary)
      @store = File.join(@root, 'store')
      @literal_dir = File.join(@root, 'literal_rowbinary')
    end

    def run
      RecheckRecursiveQBitDynamicW233.make_dir(File.join(@root, 'invocations'))
      RecheckRecursiveQBitDynamicW233.make_dir(@store)
      RecheckRecursiveQBitDynamicW233.make_dir(@literal_dir)

      pin('runtime-version', 'SELECT version() FORMAT TSVRaw', "#{CLICKHOUSE_VERSION}\n")
      pin('runtime-build', "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw",
        "VERSION_GITHASH=#{CLICKHOUSE_BUILD}\n")

      create_sql = "CREATE TABLE default.#{TABLE} (" \
        'id UInt64, root_d Dynamic(max_types=4), carrier Array(Dynamic(max_types=4)), shared_d Dynamic(max_types=0)' \
        ") ENGINE=MergeTree ORDER BY id SETTINGS #{STOCK_SETTINGS.join(', ')}"
      invoke('create', create_sql)
      insert_input = RecheckRecursiveQBitDynamicW233.rowbinary_insert_rows.join.b
      RecheckRecursiveQBitDynamicW233.write_new(File.join(@literal_dir, 'insert-schema-order.rowbin'), insert_input)
      insert = invoke('insert-rowbinary', "INSERT INTO default.#{TABLE} (id, root_d, carrier, shared_d) FORMAT RowBinary",
        input: insert_input)
      cast_diagnostic = invoke('cast-map-diagnostic', RecheckRecursiveQBitDynamicW233.map_cast_diagnostic_sql)

      check = invoke('check', RecheckRecursiveQBitDynamicW233.check_sql)
      RecheckRecursiveQBitDynamicW233.require_true(check.fetch('stdout') == "all_1_1_0\t1\t\n",
        "persisted CHECK output differs; raw capture at #{check.fetch('path')}")

      schema = invoke('schema', RecheckRecursiveQBitDynamicW233.schema_sql)
      expected_schema = [
        "id\tUInt64",
        "root_d\tDynamic(max_types=4)",
        "carrier\tArray(Dynamic(max_types=4))",
        "shared_d\tDynamic(max_types=0)",
      ].join("\n") + "\n"
      RecheckRecursiveQBitDynamicW233.require_true(schema.fetch('stdout') == expected_schema,
        "exact declared schema differs; raw capture at #{schema.fetch('path')}")

      roster = invoke('root-roster', RecheckRecursiveQBitDynamicW233.roster_sql)
      expected_roster = [
        "1\tArray(QBit(Int8, 9))\t0\tArray(QBit(Int8, 9))\t1",
        "2\tArray(QBit(Int8, 9))\t0\tArray(QBit(Int8, 9))\t1",
        "3\tTuple(q QBit(Int8, 9), n UInt8)\t0\tTuple(q QBit(Int8, 9), n UInt8)\t1",
        "4\tMap(String, QBit(Int8, 9))\t0\tMap(String, QBit(Int8, 9))\t1",
        "5\tArray(Variant(QBit(Int8, 9), UInt64))\t0\tArray(Variant(QBit(Int8, 9), UInt64))\t1",
        "6\tNULL\t-\tNULL\t-",
      ].join("\n") + "\n"
      RecheckRecursiveQBitDynamicW233.require_true(roster.fetch('stdout') == expected_roster,
        "ordinary/shared actual-type roster differs; raw capture at #{roster.fetch('path')}")

      carrier = invoke('carrier-roster', RecheckRecursiveQBitDynamicW233.carrier_roster_sql)
      expected_carrier = [
        "1\t",
        "2\tArray(QBit(Int8, 9)):0",
        "3\tTuple(q QBit(Int8, 9), n UInt8):0",
        "4\tMap(String, QBit(Int8, 9)):0",
        "5\tArray(Variant(QBit(Int8, 9), UInt64)):0",
        "6\tNULL",
      ].join("\n") + "\n"
      RecheckRecursiveQBitDynamicW233.require_true(carrier.fetch('stdout') == expected_carrier,
        "Array(Dynamic) actual-type roster differs; raw capture at #{carrier.fetch('path')}")

      part = invoke('part', "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts " \
        "WHERE database='default' AND table='#{TABLE}' AND active ORDER BY name FORMAT TSVRaw")
      fields = part.fetch('stdout').force_encoding(Encoding::UTF_8).lines.map { |line| line.chomp.split("\t", -1) }
      RecheckRecursiveQBitDynamicW233.require_true(fields.length == 1 && fields.first.length == 5 &&
        fields.first[0, 4] == ['all_1_1_0', '6', PART_MARKS.to_s, 'Wide'],
        "expected one six-row/four-mark Wide part; raw capture at #{part.fetch('path')}")
      part_path = File.expand_path(fields.first.fetch(4))
      RecheckRecursiveQBitDynamicW233.require_true(part_path.start_with?(@store + File::SEPARATOR) &&
        File.directory?(part_path) && !File.symlink?(part_path) && File.realpath(part_path) == part_path,
        'stock part escaped the isolated local store or is not canonical')

      literals = RecheckRecursiveQBitDynamicW233.rowbinary_rows
      literal_windows = {
        'full' => literals.join.b,
        'middle' => literals[2, 2].join.b,
        'zero' => ''.b,
      }
      literal_windows.each do |window, bytes|
        RecheckRecursiveQBitDynamicW233.write_new(File.join(@literal_dir, "#{window}.rowbin"), bytes)
      end

      windows = {}
      %w[full middle zero].each do |window|
        record = invoke("rowbinary-#{window}", RecheckRecursiveQBitDynamicW233.window_sql(window))
        expected = literal_windows.fetch(window)
        RecheckRecursiveQBitDynamicW233.require_true(record.fetch('stdout') == expected,
          "#{window} RowBinary differs from independent literal; raw capture at #{record.fetch('path')}")
        windows[window] = {
          'bytes' => expected.bytesize,
          'sha256' => Digest::SHA256.hexdigest(expected),
          'matches_independent_literal' => true,
          'capture_invocation' => File.basename(record.fetch('path')),
        }
      end

      part_inventory = RecheckRecursiveQBitDynamicW233.inventory(part_path)
      RecheckRecursiveQBitDynamicW233.write_new(File.join(@root, 'part_inventory.json'),
        JSON.pretty_generate({ 'part_path' => part_path, 'files' => part_inventory }) + "\n")
      witnesses = {
        'format' => 'recursive_qbit_dynamic_w233_stock_witness_v1',
        'source_reference' => "#{SOURCE_ROOT}@#{SOURCE_REVISION}",
        'runtime' => { 'path' => @binary, 'sha256' => CLICKHOUSE_SHA256,
          'version' => CLICKHOUSE_VERSION, 'build_hash' => CLICKHOUSE_BUILD,
          'source_is_separately_pinned_not_asserted_as_runtime_build_lineage' => true },
        'nominal_columns' => {
          'root_d' => 'Dynamic(max_types=4)',
          'carrier' => 'Array(Dynamic(max_types=4))',
          'shared_d' => 'Dynamic(max_types=0)',
        },
        'actual_types' => [
          'Array(QBit(Int8, 9))', 'Tuple(q QBit(Int8, 9), n UInt8)',
          'Map(String, QBit(Int8, 9))', 'Array(Variant(QBit(Int8, 9), UInt64))',
        ],
        'row_keys' => ROW_KEYS, 'mark_rows' => MARK_ROWS, 'part_type' => 'Wide',
        'part_path' => part_path, 'root_roster_capture' => File.basename(roster.fetch('path')),
        'carrier_roster_capture' => File.basename(carrier.fetch('path')),
        'check_capture' => File.basename(check.fetch('path')),
        'rowbinary_insert_capture' => File.basename(insert.fetch('path')),
        'rowbinary_insert_literal' => 'insert-schema-order.rowbin',
        'sql_cast_map_type_capture' => File.basename(cast_diagnostic.fetch('path')),
        'sql_cast_map_type_stdout' => cast_diagnostic.fetch('stdout').dup.force_encoding(Encoding::UTF_8),
        'windows' => windows,
        'scope' => 'stock RowBinary descriptor persistence falsifier; prior SQL CAST nominal-loss is captured separately; no library writer/reader equivalence claim',
      }
      RecheckRecursiveQBitDynamicW233.write_new(File.join(@root, 'witnesses.json'),
        JSON.pretty_generate(witnesses) + "\n")
      captures = RecheckRecursiveQBitDynamicW233.inventory(@root)
      RecheckRecursiveQBitDynamicW233.write_new(File.join(@root, 'capture_inventory.json'),
        JSON.pretty_generate({ 'files' => captures }) + "\n")
      puts "W233 stock captures: #{@recorder.records.length} invocations under #{@root}"
      puts 'Raw .stdout/.stderr/.status.json files, independent RowBinary literals, and inventories are preserved.'
      true
    end

    def run_map_ingestion_probe
      RecheckRecursiveQBitDynamicW233.make_dir(File.join(@root, 'invocations'))
      RecheckRecursiveQBitDynamicW233.make_dir(@store)
      RecheckRecursiveQBitDynamicW233.make_dir(@literal_dir)

      pin('runtime-version', 'SELECT version() FORMAT TSVRaw', "#{CLICKHOUSE_VERSION}\n")
      pin('runtime-build', "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw",
        "VERSION_GITHASH=#{CLICKHOUSE_BUILD}\n")

      create_sql = "CREATE TABLE default.#{MAP_PROBE_TABLE} (" \
        'id UInt64, d Dynamic(max_types=1), shared_d Dynamic(max_types=0)' \
        ") ENGINE=MergeTree ORDER BY id SETTINGS #{STOCK_SETTINGS.join(', ')}"
      invoke('map-probe-create', create_sql)

      input = RecheckRecursiveQBitDynamicW233.map_ingestion_probe_input
      expected = RecheckRecursiveQBitDynamicW233.map_ingestion_probe_expected
      RecheckRecursiveQBitDynamicW233.write_new(File.join(@literal_dir, 'map-ingestion-input.rowbin'), input)
      RecheckRecursiveQBitDynamicW233.write_new(File.join(@literal_dir, 'map-ingestion-expected.rowbin'), expected)
      invoke('map-probe-rowbinary-insert', "INSERT INTO default.#{MAP_PROBE_TABLE} FORMAT RowBinary", input: input)

      check = invoke('map-probe-check', "CHECK TABLE default.#{MAP_PROBE_TABLE} FORMAT TSVRaw")
      RecheckRecursiveQBitDynamicW233.require_true(check.fetch('stdout') == "all_1_1_0\t1\t\n",
        "Map descriptor persisted CHECK differs; raw capture at #{check.fetch('path')}")

      schema_sql = "SELECT name, type FROM system.columns WHERE database='default' AND table='#{MAP_PROBE_TABLE}' ORDER BY position FORMAT TSVRaw"
      schema = invoke('map-probe-schema', schema_sql)
      expected_schema = "id\tUInt64\nd\tDynamic(max_types=1)\nshared_d\tDynamic(max_types=0)\n"
      RecheckRecursiveQBitDynamicW233.require_true(schema.fetch('stdout') == expected_schema,
        "exact Map probe schema differs; raw capture at #{schema.fetch('path')}")

      roster_sql = "SELECT id, dynamicType(d), toString(toUInt8(isDynamicElementInSharedData(d))), " \
        "dynamicType(shared_d), toString(toUInt8(isDynamicElementInSharedData(shared_d))) " \
        "FROM default.#{MAP_PROBE_TABLE} ORDER BY id SETTINGS print_pretty_type_names=0 FORMAT TSVRaw"
      roster = invoke('map-probe-roster', roster_sql)
      expected_roster = "4\tMap(String, QBit(Int8, 9))\t0\tMap(String, QBit(Int8, 9))\t1\n"
      RecheckRecursiveQBitDynamicW233.require_true(roster.fetch('stdout') == expected_roster,
        "literal Map Dynamic descriptor did not retain ordinary/shared nominal type; raw capture at #{roster.fetch('path')}")

      output_sql = "SELECT id, d, shared_d FROM default.#{MAP_PROBE_TABLE} ORDER BY id FORMAT RowBinary"
      output = invoke('map-probe-rowbinary-output', output_sql)
      RecheckRecursiveQBitDynamicW233.require_true(output.fetch('stdout') == expected,
        "persisted Map RowBinary differs from independent expected literal; raw capture at #{output.fetch('path')}")

      part = invoke('map-probe-part', "SELECT name, toString(rows), part_type, path FROM system.parts " \
        "WHERE database='default' AND table='#{MAP_PROBE_TABLE}' AND active ORDER BY name FORMAT TSVRaw")
      fields = part.fetch('stdout').force_encoding(Encoding::UTF_8).lines.map { |line| line.chomp.split("\t", -1) }
      RecheckRecursiveQBitDynamicW233.require_true(fields.length == 1 && fields.first.length == 4 &&
        fields.first[1, 2] == ['1', 'Wide'],
        "expected one one-row Wide Map probe part; raw capture at #{part.fetch('path')}")
      part_path = File.expand_path(fields.first.fetch(3))
      RecheckRecursiveQBitDynamicW233.require_true(part_path.start_with?(@store + File::SEPARATOR) &&
        File.directory?(part_path) && !File.symlink?(part_path) && File.realpath(part_path) == part_path,
        'Map probe part escaped the isolated local store or is not canonical')

      RecheckRecursiveQBitDynamicW233.write_new(File.join(@root, 'part_inventory.json'),
        JSON.pretty_generate({ 'part_path' => part_path,
          'files' => RecheckRecursiveQBitDynamicW233.inventory(part_path) }) + "\n")
      witnesses = {
        'format' => 'recursive_qbit_dynamic_w233_map_rowbinary_probe_v1',
        'source_reference' => "#{SOURCE_ROOT}@#{SOURCE_REVISION}",
        'runtime' => { 'path' => @binary, 'sha256' => CLICKHOUSE_SHA256,
          'version' => CLICKHOUSE_VERSION, 'build_hash' => CLICKHOUSE_BUILD,
          'source_is_separately_pinned_not_asserted_as_runtime_build_lineage' => true },
        'declared_columns' => { 'd' => 'Dynamic(max_types=1)', 'shared_d' => 'Dynamic(max_types=0)' },
        'actual_type' => 'Map(String, QBit(Int8, 9))', 'row_key' => 4,
        'part_type' => 'Wide', 'part_path' => part_path,
        'rowbinary_input_capture' => 'map-ingestion-input.rowbin',
        'rowbinary_expected_capture' => 'map-ingestion-expected.rowbin',
        'roster_capture' => File.basename(roster.fetch('path')),
        'check_capture' => File.basename(check.fetch('path')),
        'output_capture' => File.basename(output.fetch('path')),
        'scope' => 'one-row stock persistence discriminator; direct descriptor input bypasses SQL CAST-to-Dynamic',
      }
      RecheckRecursiveQBitDynamicW233.write_new(File.join(@root, 'witnesses.json'), JSON.pretty_generate(witnesses) + "\n")
      captures = RecheckRecursiveQBitDynamicW233.inventory(@root)
      RecheckRecursiveQBitDynamicW233.write_new(File.join(@root, 'capture_inventory.json'),
        JSON.pretty_generate({ 'files' => captures }) + "\n")
      puts "W233 Map RowBinary probe captures: #{@recorder.records.length} invocations under #{@root}"
      puts 'Raw process captures, independent input/output literals, part inventory, and capture inventory are preserved.'
      true
    end

    private

    def invoke(label, sql, input: nil)
      RecheckRecursiveQBitDynamicW233.require_true(@recorder.records.length < MAX_PROCESS_COUNT,
        'fixed W233 process cap exceeded')
      @recorder.run(label, @store, sql, input: input, timeout: R::PROCESS_TIMEOUT_SECONDS,
        argv: RecheckRecursiveQBitDynamicW233.clickhouse_argv(@binary, @store, sql)).tap do |record|
        ok = record.fetch('classification') == 'process_success' && record.fetch('exitstatus') == 0 &&
          !record.fetch('signaled') && !record.fetch('timed_out') && record.fetch('spawn_error').nil?
        RecheckRecursiveQBitDynamicW233.require_true(ok,
          "stock invocation #{label} was not process-success; raw capture at #{record.fetch('path')}")
      end
    end

    def pin(label, sql, expected)
      record = invoke(label, sql)
      RecheckRecursiveQBitDynamicW233.require_true(record.fetch('stdout') == expected,
        "#{label} differs from separate runtime pin; raw capture at #{record.fetch('path')}")
    end
  end

  def main(argv)
    options = { clickhouse: CLICKHOUSE_BIN, map_ingestion_probe: false }
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/recheck_recursive_qbit_dynamic_w233.rb --capture-root EMPTY_DIR [--map-ingestion-probe] [--clickhouse PINNED_BIN]'
      opts.on('--capture-root PATH') { |value| options[:capture_root] = value }
      opts.on('--map-ingestion-probe', 'Run the one-row literal Map(String, QBit) RowBinary persistence discriminator') do
        options[:map_ingestion_probe] = true
      end
      opts.on('--clickhouse PATH') { |value| options[:clickhouse] = value }
    end
    parser.parse!(argv)
    require_true(argv.empty? && options.key?(:capture_root), parser.to_s)
    probe = Probe.new(options)
    options[:map_ingestion_probe] ? probe.run_map_ingestion_probe : probe.run
  rescue StandardError => error
    warn "W233 stock probe stopped with preserved raw captures: #{error.class}: #{error.message}"
    false
  end
end

exit(RecheckRecursiveQBitDynamicW233.main(ARGV) ? 0 : 1) if $PROGRAM_NAME == __FILE__
