#!/usr/bin/env ruby
# Small stock-only persistence discriminator for QBit inside JSON/Object.
# This records ClickHouse children and literal RowBinary oracles; it does not
# invoke Crystal, edit product code, or claim library writer/reader equivalence.

require 'digest'
require 'find'
require 'json'
require 'optparse'
require_relative 'recheck_recursive_qbit_dynamic_w233'

module RecheckObjectQBitRecursiveStockW234
  extend self

  Q = RecheckRecursiveQBitDynamicW233
  R = Q::R
  SOURCE_ROOT = '/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1'.freeze
  SOURCE_REVISION = '0ca8150d9b1d0886edb2e3b4ab65eebb768d0357'.freeze
  CLICKHOUSE_BIN = Q::CLICKHOUSE_BIN
  CLICKHOUSE_SHA256 = Q::CLICKHOUSE_SHA256
  CLICKHOUSE_VERSION = '26.10.1.1201'.freeze
  CLICKHOUSE_BUILD = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  ROOT_PREFIX = 'crystal-click-w234-stock.'.freeze
  ROW_KEYS = [1, 2, 3, 4, 5, 6].freeze
  MARK_ROWS = [2, 2, 2].freeze
  PART_MARKS = 4
  MEMORY_LIMIT_BYTES = 1_073_741_824
  PROCESS_TIMEOUT_SECONDS = 90
  MAX_PROCESS_COUNT = 32
  MAX_CAPTURE_FILES = 4096
  MAX_CAPTURE_BYTES = 64 * 1024 * 1024
  UUID_RE = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/.freeze

  # RowBinary dynamic descriptors are literal protocol bytes from the pinned
  # DataTypesBinaryEncoding grammar.
  DESC_ARRAY_QBIT = [0x1e, 0x36, 0x07, 0x09].pack('C*').b.freeze
  DESC_TUPLE_QBIT_U8 = [0x20, 0x02, 0x01, 0x71, 0x36, 0x07, 0x09, 0x01, 0x6e, 0x01].pack('C*').b.freeze
  DESC_MAP_STRING_QBIT = [0x27, 0x15, 0x36, 0x07, 0x09].pack('C*').b.freeze

  # Expected Dynamic actuals: Array(QBit) with two values, empty Array(QBit),
  # named Tuple(QBit, UInt8), Map(String, QBit) with uneven key lengths,
  # one-element zero Array(QBit), and NULL for a missing q path. These fixed
  # body literals are independent of the complete Object RowBinary input rows.
  QBIT_VALUES_HEX = [
    '010203040506070809', '000000000000000000', 'ff0001020408102040',
    '090807060504030201',
  ].freeze

  # Exact Object RowBinary input. Each row is id UInt64, then Object's
  # (path-count, path, Dynamic descriptor+body). Missing q is a zero-path
  # object. Expected direct-path output is constructed separately below.
  OBJECT_INPUT_ROW_HEX = [
    '01000000000000000101711e360709020901020304050607080909000000000000000000',
    '02000000000000000101711e36070900',
    '030000000000000001017120020171360709016e0109ff000102040810204007',
    '0400000000000000010171271536070902016109010203040506070809046c6f6e6709090807060504030201',
    '05000000000000000101711e3607090109000000000000000000',
    '060000000000000000',
  ].freeze

  STOCK_SETTINGS = [
    'index_granularity=2', 'index_granularity_bytes=10485760',
    'enable_mixed_granularity_parts=1', 'min_rows_for_wide_part=0',
    'min_bytes_for_wide_part=0', 'min_level_for_wide_part=0',
    'compress_marks=0', 'compress_primary_key=0', 'min_compress_block_size=0',
    'max_compress_block_size=4096', 'ratio_of_defaults_for_sparse_serialization=1.0',
    "default_compression_codec='LZ4'", "string_serialization_version='single_stream'",
    "nullable_serialization_version='basic'", "serialization_info_version='with_types'",
    'propagate_types_serialization_versions_to_nested_types=1',
    "dynamic_serialization_version='v3'", "object_serialization_version='v3'",
    "object_shared_data_serialization_version='advanced_chunked'",
    "object_shared_data_serialization_version_for_zero_level_parts='advanced_chunked'",
    'object_shared_data_buckets_for_wide_part=2',
    'object_shared_data_target_chunk_rows=1',
    "map_serialization_version='basic'", "map_serialization_version_for_zero_level_parts='basic'",
    'use_compact_variant_discriminators_serialization=0', 'flatten_nested=0',
  ].freeze

  PROFILES = [
    {
      'id' => 'typed_dynamic', 'table' => 'w234_json_typed_dynamic',
      'type' => 'JSON(max_dynamic_paths=0, q Dynamic(max_types=3))', 'ingestion' => 'RowBinary',
      'kind' => 'typed_dynamic',
    },
    {
      'id' => 'inferred_dynamic', 'table' => 'w234_json_inferred_dynamic',
      'type' => 'JSON(max_dynamic_types=3, max_dynamic_paths=1)', 'ingestion' => 'RowBinary',
      'kind' => 'inferred_dynamic',
    },
    {
      'id' => 'forced_shared', 'table' => 'w234_json_forced_shared',
      'type' => 'JSON(max_dynamic_types=3, max_dynamic_paths=0)', 'ingestion' => 'RowBinary',
      'kind' => 'forced_shared',
    },
  ].freeze

  def fail!(message)
    raise ArgumentError, message
  end

  def require_true(condition, message)
    fail!(message) unless condition
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
    full = Q.validate_binary(path)
    require_true(full == CLICKHOUSE_BIN && sha256_file(full) == CLICKHOUSE_SHA256,
      'runtime differs from the W234 fixed path/SHA pin')
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

  def qbit_literal(hex)
    require_true(hex.match?(/\A(?:[0-9a-f]{2}){9}\z/), 'literal QBit(Int8, 9) must contain exactly 9 bytes')
    varuint(9) + [hex].pack('H*').b
  end

  def direct_dynamic_values
    [
      DESC_ARRAY_QBIT + varuint(2) + qbit_literal(QBIT_VALUES_HEX.fetch(0)) + qbit_literal(QBIT_VALUES_HEX.fetch(1)),
      DESC_ARRAY_QBIT + varuint(0),
      DESC_TUPLE_QBIT_U8 + qbit_literal(QBIT_VALUES_HEX.fetch(2)) + [7].pack('C').b,
      DESC_MAP_STRING_QBIT + varuint(2) + string_bytes('a') + qbit_literal(QBIT_VALUES_HEX.fetch(0)) +
        string_bytes('long') + qbit_literal(QBIT_VALUES_HEX.fetch(3)),
      DESC_ARRAY_QBIT + varuint(1) + qbit_literal(QBIT_VALUES_HEX.fetch(1)),
      [0x00].pack('C').b,
    ]
  end

  def direct_path_expected_rows
    values = direct_dynamic_values
    ROW_KEYS.each_with_index.map { |key, index| uint64(key) + values.fetch(index) }
  end

  def actual_roster_expected(profile)
    type_names = [
      'Array(QBit(Int8, 9))', 'Array(QBit(Int8, 9))',
      'Tuple(q QBit(Int8, 9), n UInt8)', 'Map(String, QBit(Int8, 9))',
      'Array(QBit(Int8, 9))', 'None',
    ]
    ROW_KEYS.each_with_index.map do |key, index|
      dynamic_path, shared_path = case profile.fetch('kind')
                                  when 'typed_dynamic' then [0, 0]
                                  when 'inferred_dynamic' then [index == 5 ? 0 : 1, 0]
                                  when 'forced_shared' then [0, index == 5 ? 0 : 1]
                                  else fail!("unlisted route profile: #{profile.fetch('kind')}")
                                  end
      "#{key}\t#{type_names.fetch(index)}\t0\t#{dynamic_path}\t#{shared_path}\n"
    end.join
  end

  def object_rowbinary_input
    OBJECT_INPUT_ROW_HEX.map { |hex| [hex].pack('H*').b }.join.b
  end

  def expected_schema(profile)
    "id\tUInt64\nj\t#{profile.fetch('type')}\n"
  end

  def schema_sql(profile)
    "SELECT name, type FROM system.columns WHERE database='default' AND table='#{profile.fetch('table')}' ORDER BY position FORMAT TSVRaw"
  end

  def check_sql(profile)
    "CHECK TABLE default.#{profile.fetch('table')} FORMAT TSVRaw"
  end

  def actual_roster_sql(profile)
    "SELECT id, dynamicType(j.q), toUInt8(isDynamicElementInSharedData(j.q)), " \
      "has(JSONDynamicPaths(j), 'q'), has(JSONSharedDataPaths(j), 'q') " \
      "FROM default.#{profile.fetch('table')} ORDER BY id FORMAT TSVRaw"
  end

  def window_sql(profile, window)
    predicate = { 'full' => '', 'middle' => ' WHERE id BETWEEN 3 AND 4', 'zero' => ' WHERE id=0' }.fetch(window)
    "SELECT id, j.q FROM default.#{profile.fetch('table')}#{predicate} ORDER BY id " \
      'SETTINGS output_format_binary_write_json_as_string=0 FORMAT RowBinary'
  end

  def create_sql(profile)
    "CREATE TABLE default.#{profile.fetch('table')} (id UInt64, j #{profile.fetch('type')}) " \
      "ENGINE=MergeTree ORDER BY id SETTINGS #{STOCK_SETTINGS.join(', ')}"
  end

  def part_sql(profile)
    "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts " \
      "WHERE database='default' AND table='#{profile.fetch('table')}' AND active ORDER BY name FORMAT TSVRaw"
  end

  def validate_atomic_directory_alias(path, store, table_name)
    relative = path[(store.length + 1)..-1]
    raw_target = File.readlink(path)
    if relative == 'metadata/default'
      match = /\A\.\.\/store\/([0-9a-f]{3})\/([0-9a-f-]{36})\z/.match(raw_target)
    elsif relative == "data/default/#{table_name}"
      match = /\A\.\.\/\.\.\/store\/([0-9a-f]{3})\/([0-9a-f-]{36})\z/.match(raw_target)
    else
      fail!("unexpected Atomic directory symlink: #{relative}")
    end
    require_true(match && UUID_RE.match?(match[2]) && match[1] == match[2][0, 3],
      "Atomic directory alias target does not match its UUID/fanout grammar: #{relative}")
    require_true(File.symlink?(path) && File.directory?(path), "Atomic alias is not a directory symlink: #{relative}")
    target = File.expand_path(raw_target, File.dirname(path))
    physical_store = File.join(store, 'store')
    require_true(File.directory?(physical_store) && !File.symlink?(physical_store) && File.realpath(physical_store) == physical_store,
      "Atomic physical store is not canonical: #{physical_store}")
    require_true(target.start_with?(physical_store + File::SEPARATOR) && File.directory?(target) &&
      !File.symlink?(target) && File.realpath(target) == target,
      "Atomic alias resolves outside the local store or through a chained/missing target: #{relative}")
    [
      { 'path' => relative, 'target' => raw_target, 'resolved_target' => target },
      target,
    ]
  end

  def inventory_tree(root, allowed_stores: {})
    full = File.realpath(root)
    entries = []
    aliases = []
    count = 0
    bytes = 0
    Find.find(full) do |entry|
      next if entry == full
      if File.symlink?(entry)
        store = allowed_stores.keys.find { |candidate| entry.start_with?(candidate + File::SEPARATOR) }
        require_true(store, "symlink outside a fixed local store: #{entry}")
        table_name = allowed_stores.fetch(store)
        alias_record, _target = validate_atomic_directory_alias(entry, store, table_name)
        alias_record['store'] = store
        aliases << alias_record
        next
      end
      next if File.directory?(entry)
      require_true(File.file?(entry), "non-regular inventory entry: #{entry}")
      count += 1
      bytes += File.size(entry)
      require_true(count <= MAX_CAPTURE_FILES && bytes <= MAX_CAPTURE_BYTES, 'capture exceeds fixed inventory bounds')
      next if File.basename(entry) == 'capture_inventory.json'
      entries << { 'path' => entry[(full.length + 1)..-1], 'size' => File.size(entry), 'sha256' => sha256_file(entry) }
    end
    { 'files' => entries.sort_by { |item| item.fetch('path') }, 'directory_aliases' => aliases.sort_by { |item| item.fetch('path') } }
  end

  class Probe
    def initialize(options)
      @binary = RecheckObjectQBitRecursiveStockW234.validate_binary(options.fetch(:clickhouse))
      @root = RecheckObjectQBitRecursiveStockW234.validate_root(options.fetch(:capture_root))
      @recorder = R::Recorder.new(@root, @binary)
      @stores = {}
      @part_records = []
      @profile_records = []
    end

    def run
      R.make_dir(File.join(@root, 'invocations'))
      R.make_dir(File.join(@root, 'literal_rowbinary'))
      R.make_dir(File.join(@root, 'stores'))
      PROFILES.each do |profile|
        store = File.join(@root, 'stores', profile.fetch('id'))
        R.make_dir(store)
        @stores[profile.fetch('id')] = store
      end

      pin_runtime(PROFILES.first)
      PROFILES.each { |profile| run_profile(profile) }
      write_part_inventory
      write_witness
      write_capture_inventory
      puts JSON.generate(
        'status' => 'stock_persistence_observed', 'source' => "#{SOURCE_ROOT}@#{SOURCE_REVISION}",
        'runtime_version' => CLICKHOUSE_VERSION, 'runtime_build' => CLICKHOUSE_BUILD,
        'invocations' => @recorder.records.length, 'capture_root' => @root,
        'profiles' => @profile_records.map { |item| item.fetch('id') },
      )
      true
    rescue StandardError => error
      warn "W234 stock discriminator stopped with raw captures preserved: #{error.class}: #{error.message}"
      false
    end

    private

    def invoke!(label, profile, sql, input: nil)
      RecheckObjectQBitRecursiveStockW234.require_true(@recorder.records.length < MAX_PROCESS_COUNT,
        'fixed W234 child-process cap exceeded')
      store = @stores.fetch(profile.fetch('id'))
      record = @recorder.run(label, store, sql, input: input,
        timeout: PROCESS_TIMEOUT_SECONDS,
        argv: Q.clickhouse_argv(@binary, store, sql))
      success = record.fetch('classification') == 'process_success' && record.fetch('exitstatus') == 0 &&
        !record.fetch('signaled') && !record.fetch('timed_out') && record.fetch('spawn_error').nil?
      RecheckObjectQBitRecursiveStockW234.require_true(success,
        "ClickHouse child #{label} did not exit successfully; raw capture at #{record.fetch('path')}")
      record
    end

    def pin_runtime(profile)
      version = invoke!('runtime-version', profile, 'SELECT version() FORMAT TSVRaw')
      RecheckObjectQBitRecursiveStockW234.require_true(version.fetch('stdout') == "#{CLICKHOUSE_VERSION}\n",
        'runtime version differs from the W234 pin')
      build = invoke!('runtime-build', profile,
        "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw")
      RecheckObjectQBitRecursiveStockW234.require_true(build.fetch('stdout') == "VERSION_GITHASH=#{CLICKHOUSE_BUILD}\n",
        'runtime build hash differs from the W234 pin')
      @runtime_pin = {
        'path' => @binary, 'sha256' => CLICKHOUSE_SHA256, 'version' => CLICKHOUSE_VERSION,
        'build_hash' => CLICKHOUSE_BUILD,
        'source_revision_is_separately_pinned_not_asserted_as_runtime_lineage' => true,
        'version_capture' => File.basename(version.fetch('path')),
        'build_capture' => File.basename(build.fetch('path')),
      }
    end

    def insert_input(profile)
      RecheckObjectQBitRecursiveStockW234.object_rowbinary_input
    end

    def expected_rows(profile)
      RecheckObjectQBitRecursiveStockW234.direct_path_expected_rows
    end

    def run_profile(profile)
      table = profile.fetch('table')
      id = profile.fetch('id')
      input = insert_input(profile)
      literal_dir = File.join(@root, 'literal_rowbinary')
      input_name = "#{id}-input.rowbin"
      R.write_new(File.join(literal_dir, input_name), input)

      invoke!("#{id}-create", profile, RecheckObjectQBitRecursiveStockW234.create_sql(profile))
      insert_sql = "INSERT INTO default.#{table} SETTINGS input_format_binary_read_json_as_string=0 FORMAT RowBinary"
      insert = invoke!("#{id}-insert-#{profile.fetch('ingestion').downcase}", profile, insert_sql, input: input)

      check = invoke!("#{id}-check", profile, RecheckObjectQBitRecursiveStockW234.check_sql(profile))
      RecheckObjectQBitRecursiveStockW234.require_true(check.fetch('stdout') == "all_1_1_0\t1\t\n",
        "persisted CHECK result differs for #{id}; raw capture at #{check.fetch('path')}")

      schema = invoke!("#{id}-schema", profile, RecheckObjectQBitRecursiveStockW234.schema_sql(profile))
      RecheckObjectQBitRecursiveStockW234.require_true(schema.fetch('stdout') ==
        RecheckObjectQBitRecursiveStockW234.expected_schema(profile),
        "exact nominal JSON schema differs for #{id}; raw capture at #{schema.fetch('path')}")

      roster = invoke!("#{id}-actual-roster", profile, RecheckObjectQBitRecursiveStockW234.actual_roster_sql(profile))
      RecheckObjectQBitRecursiveStockW234.require_true(roster.fetch('stdout') ==
        RecheckObjectQBitRecursiveStockW234.actual_roster_expected(profile),
        "actual type or Object/Dynamic route roster differs; raw capture at #{roster.fetch('path')}")

      part = invoke!("#{id}-part", profile, RecheckObjectQBitRecursiveStockW234.part_sql(profile))
      fields = part.fetch('stdout').force_encoding(Encoding::UTF_8).lines.map { |line| line.chomp.split("\t", -1) }
      RecheckObjectQBitRecursiveStockW234.require_true(fields.length == 1 && fields.first.length == 5 &&
        fields.first[0, 4] == ['all_1_1_0', '6', PART_MARKS.to_s, 'Wide'],
        "expected one six-row/four-mark Wide part for #{id}; raw capture at #{part.fetch('path')}")
      part_path = File.expand_path(fields.first.fetch(4))
      store = @stores.fetch(id)
      RecheckObjectQBitRecursiveStockW234.require_true(part_path.start_with?(store + File::SEPARATOR) &&
        File.directory?(part_path) && !File.symlink?(part_path) && File.realpath(part_path) == part_path,
        "part escaped its isolated store or is not canonical for #{id}")

      literals = expected_rows(profile)
      literal_windows = {
        'full' => literals.join.b,
        'middle' => literals[2, 2].join.b,
        'zero' => ''.b,
      }
      windows = {}
      %w[full middle zero].each do |window|
        expected = literal_windows.fetch(window)
        expected_file = File.join(literal_dir, "#{id}-#{window}-expected.rowbin")
        R.write_new(expected_file, expected)
        output = invoke!("#{id}-direct-path-rowbinary-#{window}", profile,
          RecheckObjectQBitRecursiveStockW234.window_sql(profile, window))
        RecheckObjectQBitRecursiveStockW234.require_true(output.fetch('stdout') == expected,
          "#{window} RowBinary differs from independent literal for #{id}; raw capture at #{output.fetch('path')}")
        windows[window] = {
          'bytes' => expected.bytesize, 'sha256' => Digest::SHA256.hexdigest(expected),
          'matches_independent_literal' => true, 'expected_literal' => File.basename(expected_file),
          'capture_invocation' => File.basename(output.fetch('path')),
        }
      end

      part_inventory = RecheckObjectQBitRecursiveStockW234.inventory_tree(part_path)
      @part_records << {
        'id' => id, 'part_path' => part_path, 'files' => part_inventory.fetch('files'),
      }
      @profile_records << {
        'id' => id, 'table' => table, 'nominal_type' => profile.fetch('type'),
        'ingestion_format' => profile.fetch('ingestion'), 'row_keys' => ROW_KEYS,
        'rows_per_mark' => MARK_ROWS, 'part_type' => 'Wide', 'part_marks' => PART_MARKS,
        'insert_literal' => input_name, 'schema_capture' => File.basename(schema.fetch('path')),
        'check_capture' => File.basename(check.fetch('path')), 'check_stdout' => check.fetch('stdout'),
        'actual_roster_capture' => File.basename(roster.fetch('path')),
        'part_capture' => File.basename(part.fetch('path')), 'part_inventory_files' => part_inventory.fetch('files').length,
        'rowbinary_windows' => windows,
        'insert_capture' => File.basename(insert.fetch('path')),
      }
    end

    def write_part_inventory
      R.write_new(File.join(@root, 'part_inventories.json'), JSON.pretty_generate({ 'parts' => @part_records }) + "\n")
    end

    def write_witness
      witness = {
        'format' => 'object_qbit_recursive_stock_w234_v1',
        'source_reference' => "#{SOURCE_ROOT}@#{SOURCE_REVISION}",
        'runtime' => @runtime_pin,
        'profiles' => @profile_records,
        'actual_type_scope' => [
          'Array(QBit(Int8, 9))', 'Tuple(q QBit(Int8, 9), n UInt8)', 'Map(String, QBit(Int8, 9))',
        ],
        'settings' => STOCK_SETTINGS,
        'scope' => 'three stock MergeTree Object runtime profiles: explicitly typed Dynamic q path, inferred dynamic q path, and forced Object shared q path; six exact Object RowBinary inputs and independent direct-path Dynamic RowBinary output literals; no Crystal library equivalence claim',
      }
      R.write_new(File.join(@root, 'witnesses.json'), JSON.pretty_generate(witness) + "\n")
    end

    def write_capture_inventory
      allowed_stores = @stores.each_with_object({}) do |(id, path), result|
        result[File.realpath(path)] = PROFILES.find { |profile| profile.fetch('id') == id }.fetch('table')
      end
      inventory = RecheckObjectQBitRecursiveStockW234.inventory_tree(@root, allowed_stores: allowed_stores)
      R.write_new(File.join(@root, 'capture_inventory.json'), JSON.pretty_generate(inventory) + "\n")
    end
  end

  def main(argv)
    options = { clickhouse: CLICKHOUSE_BIN }
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/recheck_object_qbit_recursive_stock_w234.rb --capture-root EMPTY_DIR [--clickhouse PINNED_BIN]'
      opts.on('--capture-root PATH') { |value| options[:capture_root] = value }
      opts.on('--clickhouse PATH') { |value| options[:clickhouse] = value }
    end
    parser.parse!(argv)
    require_true(argv.empty? && options.key?(:capture_root), parser.to_s)
    Probe.new(options).run
  rescue StandardError => error
    warn "W234 stock probe setup failed: #{error.class}: #{error.message}"
    false
  end
end

exit(RecheckObjectQBitRecursiveStockW234.main(ARGV) ? 0 : 1) if $PROGRAM_NAME == __FILE__
