#!/usr/bin/env ruby
# Paired stock ClickHouse / Crystal recursive QBit part capture. The Crystal
# helper is supplied prebuilt; this runner never compiles application code.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require_relative 'recheck_aggregate_recursive_w224'

module RecheckRecursiveQBitW230
  extend self

  R = RecheckAggregateRecursiveW224
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
  MARK_ROWS = [2, 2, 2].freeze
  ROW_KEYS = [1, 2, 3, 4, 5, 6].freeze
  INVALIDATED_FILE = 'invalidated_system_columns.txt'.freeze
  INVALIDATED_NAMES = %w[_block_number _block_offset].freeze
  STOCK_SETTINGS = [
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

  VALUE_HEX = {
    'Int8' => %w[fe ff 00 01 02 04 08 10 20].freeze,
    'BFloat16' => %w[00c0 80bf 0000 803f 0040 8040 0041 8041 0042].freeze,
    'Float32' => %w[000000c0 000080bf 00000000 0000803f 00000040 00008040 00000041 00008041 00000042].freeze,
    'Float64' => %w[00000000000000c0 000000000000f0bf 0000000000000000 000000000000f03f 0000000000000040 0000000000001040 0000000000002040 0000000000003040 0000000000004040].freeze,
  }.freeze
  VECTOR9_CODES = [
    [0, 1, 2, 3, 4, 5, 6, 7, 8],
    [8, 7, 6, 5, 4, 3, 2, 1, 0],
    [2, 4, 6, 8, 0, 1, 3, 5, 7],
    [8, 6, 4, 2, 0, 7, 5, 3, 1],
    [1, 3, 5, 7, 0, 2, 4, 6, 8],
  ].freeze
  VECTOR16_CODES = [
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 7, 6, 5, 4, 3, 2, 1],
    [8, 7, 6, 5, 4, 3, 2, 1, 0, 1, 2, 3, 4, 5, 6, 7],
    [2, 3, 4, 5, 6, 7, 8, 0, 1, 8, 7, 6, 5, 4, 3, 2],
    [6, 5, 4, 3, 2, 1, 0, 8, 7, 0, 1, 2, 3, 4, 5, 6],
    [1, 3, 5, 7, 0, 2, 4, 6, 8, 0, 8, 6, 4, 2, 1, 3],
  ].freeze
  VECTOR3_CODES = [
    [0, 1, 2], [3, 4, 5], [6, 7, 8], [8, 7, 6], [5, 4, 3],
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

  def safe_label(value)
    value.gsub(/[^A-Za-z0-9_.-]/, '_')
  end

  def write_new(path, bytes)
    File.open(path, 'wbx', 0o600) { |file| file.write(bytes) }
  rescue Errno::EEXIST
    fail!("refusing to overwrite W230 evidence: #{path}")
  end

  def write_json(path, value)
    write_new(path, JSON.pretty_generate(value) + "\n")
  end

  def make_dir(path)
    Dir.mkdir(path, 0o700)
  rescue Errno::EEXIST
    fail!("refusing to reuse W230 directory: #{path}")
  end

  def plain_file!(path, label, executable: false)
    full = File.expand_path(path)
    require_true(File.file?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "#{label} is absent, symlinked, or noncanonical: #{full}")
    require_true(!executable || File.executable?(full), "#{label} is not executable: #{full}")
    full
  end

  def validate_program!(path, label)
    plain_file!(path, label, executable: true)
  end

  def validate_root(path, prefix, label)
    full = File.expand_path(path)
    require_true(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full && Dir.children(full).empty?,
      "#{label} must be a fresh, empty, canonical directory")
    require_true(File.dirname(full) == File.realpath('/private/tmp') && File.basename(full).start_with?(prefix),
      "#{label} must be a direct /private/tmp child with prefix #{prefix}")
    full
  end

  def validate_sha256!(value, label)
    require_true(value.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(value),
      "#{label} must be 64 lowercase hexadecimal characters")
    value
  end

  def validate_binary!(path)
    full = validate_program!(path, 'pinned ClickHouse binary')
    require_true(full == CLICKHOUSE_BIN, "ClickHouse binary path differs from pin: #{full}")
    actual = sha256_file(full)
    require_true(actual == CLICKHOUSE_SHA256, "ClickHouse SHA-256 differs from pin: #{actual}")
    full
  end

  def validate_helper!(path, expected_sha)
    validate_sha256!(expected_sha, 'expected helper SHA-256')
    full = validate_program!(path, 'prebuilt Crystal helper')
    actual = sha256_file(full)
    require_true(actual == expected_sha, "prebuilt helper SHA-256 differs from external pin: #{actual}")
    [full, actual]
  end

  def source_manifest
    entries = SOURCE_FILES.map do |relative, expected|
      path = File.join(SOURCE_ROOT, relative)
      plain_file!(path, "pinned ClickHouse source #{relative}")
      actual = sha256_file(path)
      require_true(actual == expected, "pinned ClickHouse source changed: #{relative} #{actual}")
      { 'path' => relative, 'sha256' => actual }
    end
    { 'root' => SOURCE_ROOT, 'revision' => SOURCE_REVISION, 'files' => entries }
  end

  def hex_bytes(hex, label)
    require_true(hex.is_a?(String) && /\A(?:[0-9a-f]{2})+\z/.match?(hex), "invalid literal hex for #{label}")
    [hex].pack('H*').b
  end

  def varuint(value)
    require_true(value.is_a?(Integer) && value >= 0, "negative RowBinary VarUInt: #{value.inspect}")
    bytes = []
    while value >= 0x80
      bytes << ((value & 0x7f) | 0x80)
      value >>= 7
    end
    bytes << value
    bytes.pack('C*').b
  end

  def uint64_le(value)
    require_true(value.is_a?(Integer) && value >= 0 && value <= 18_446_744_073_709_551_615,
      "RowBinary UInt64 outside range: #{value.inspect}")
    Array.new(8) { |index| (value >> (index * 8)) & 0xff }.pack('C*').b
  end

  def qbit_hex(carrier, codes)
    VALUE_HEX.fetch(carrier).values_at(*codes).join
  end

  def vector16(carrier, index)
    qbit_hex(carrier, VECTOR16_CODES.fetch(index))
  end

  def base_rows(carrier)
    vectors = VECTOR9_CODES.map { |codes| qbit_hex(carrier, codes) }
    [[vectors[0], vectors[1]], [], [], [], [vectors[2], vectors[3]], [vectors[4]]]
  end

  def profiles
    output = %w[Int8 BFloat16 Float32 Float64].map do |carrier|
      { 'id' => "array_qbit_#{carrier.downcase}_9", 'declared_type' => "Array(QBit(#{carrier}, 9))",
        'wrapper' => :flat, 'leaf_type' => carrier, 'dimension' => 9, 'rows' => base_rows(carrier) }
    end
    output << {
      'id' => 'array_qbit_bfloat16_16_stride8', 'declared_type' => 'Array(QBit(BFloat16, 16, 8))',
      'wrapper' => :flat, 'leaf_type' => 'BFloat16', 'dimension' => 16,
      'rows' => [[vector16('BFloat16', 0), vector16('BFloat16', 1)], [], [], [],
        [vector16('BFloat16', 2), vector16('BFloat16', 3)], [vector16('BFloat16', 4)]],
    }
    output << {
      'id' => 'array_nullable_qbit_bfloat16_16', 'declared_type' => 'Array(Nullable(QBit(BFloat16, 16)))',
      'wrapper' => :nullable, 'leaf_type' => 'BFloat16', 'dimension' => 16,
      'rows' => [[vector16('BFloat16', 0), nil], [], [], [],
        [vector16('BFloat16', 1), vector16('BFloat16', 2)], [vector16('BFloat16', 3)]],
    }
    nested_vectors = VECTOR3_CODES.map { |codes| qbit_hex('Int8', codes) }
    output << {
      'id' => 'array_array_qbit_int8_3', 'declared_type' => 'Array(Array(QBit(Int8, 3)))',
      'wrapper' => :nested, 'leaf_type' => 'Int8', 'dimension' => 3,
      'rows' => [[[nested_vectors[0], nested_vectors[1]], []], [], [], [],
        [[nested_vectors[2]], [nested_vectors[3]]], [[nested_vectors[4]]]],
    }
    output << {
      'id' => 'array_qbit_bfloat16_16_all_empty', 'declared_type' => 'Array(QBit(BFloat16, 16))',
      'wrapper' => :flat, 'leaf_type' => 'BFloat16', 'dimension' => 16,
      'rows' => [[], [], [], [], [], []],
    }
    require_true(output.map { |profile| profile.fetch('id') }.uniq.size == 8, 'W230 fixed profile roster is not unique')
    output
  end

  def qbit_bytes(profile, value_hex)
    raw = hex_bytes(value_hex, "#{profile.fetch('id')} QBit value")
    expected_size = VALUE_HEX.fetch(profile.fetch('leaf_type')).first.size / 2 * profile.fetch('dimension')
    require_true(raw.bytesize == expected_size, "#{profile.fetch('id')} QBit value length differs")
    varuint(profile.fetch('dimension')) + raw
  end

  def array_bytes(values)
    varuint(values.length) + values.join.b
  end

  def value_bytes(profile, value)
    case profile.fetch('wrapper')
    when :flat
      array_bytes(value.map { |hex| qbit_bytes(profile, hex) })
    when :nullable
      array_bytes(value.map do |hex|
        hex.nil? ? [1].pack('C').b : [0].pack('C').b + qbit_bytes(profile, hex)
      end)
    when :nested
      array_bytes(value.map { |inner| array_bytes(inner.map { |hex| qbit_bytes(profile, hex) }) })
    else
      fail!("unhandled W230 wrapper: #{profile.fetch('wrapper').inspect}")
    end
  end

  def literal_rowbinary(profile, index)
    uint64_le(ROW_KEYS.fetch(index)) + value_bytes(profile, profile.fetch('rows').fetch(index))
  end

  def literal_rowbinary_hex(profile)
    profile.fetch('rows').each_index.map { |index| literal_rowbinary(profile, index).unpack1('H*') }
  end

  def row_indices(profile, window)
    case window
    when 'full' then (0...6).to_a
    when 'middle' then [2, 3]
    when 'all-empty'
      profile.fetch('rows').each_index.select { |index| profile.fetch('rows').fetch(index).empty? }
    when 'zero' then []
    else fail!("unlisted W230 RowBinary window: #{window}")
    end
  end

  def expected_window(profile, window)
    row_indices(profile, window).map { |index| literal_rowbinary(profile, index) }.join.b
  end

  def leaf_slots(value, wrapper)
    case wrapper
    when :flat then value.length
    when :nullable then value.length # Null still owns one flattened nullable slot.
    when :nested then value.sum { |inner| inner.length }
    else 0
    end
  end

  def occurrence_grid(profile)
    profile.fetch('rows').each_slice(2).map do |rows|
      rows.sum { |row| leaf_slots(row, profile.fetch('wrapper')) }
    end
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
      require_true(count <= 4096, "part tree exceeds entry cap: #{full}")
      require_true(!File.symlink?(path), "part contains symlink: #{path}")
      next if File.directory?(path)
      require_true(File.file?(path), "part contains unsupported entry: #{path}")
      size = File.size(path)
      bytes += size
      require_true(bytes <= 64 * 1024 * 1024, "part tree exceeds byte cap: #{full}")
      entries << { 'path' => path[(full.length + 1)..-1], 'size' => size, 'sha256' => sha256_file(path) }
    end
    entries.sort_by { |entry| entry.fetch('path') }
  end

  def create_sql(table, profile)
    settings = STOCK_SETTINGS
    "CREATE TABLE default.#{table} (id UInt64, q #{profile.fetch('declared_type')} CODEC(LZ4)) " \
      "ENGINE=MergeTree ORDER BY id SETTINGS #{settings.join(', ')}"
  end

  def table_name(profile, kind)
    "w230_#{kind}_#{safe_label(profile.fetch('id'))}"
  end

  def checked_success!(record, label)
    require_true(record.fetch('classification') == 'process_success' && record.fetch('exitstatus') == 0 &&
      !record.fetch('signaled') && !record.fetch('timed_out') && !record.fetch('spawn_error'),
      "#{label} failed as a process: #{record.inspect}")
    record
  end

  def output_bytes(record)
    File.binread(record.fetch('path') + '.stdout')
  end

  def require_check!(record, label)
    actual = output_bytes(record)
    require_true(actual == "all_1_1_0\t1\t\n", "#{label} must be exactly one successful CHECK row with empty message; got #{actual.inspect}")
  end

  def parse_tsv_line!(text, fields, label)
    rows = text.force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp)
    require_true(rows.length == 1, "#{label} expected one TSV row: #{rows.inspect}")
    values = rows.first.split("\t", -1)
    require_true(values.length == fields, "#{label} TSV field count differs: #{values.inspect}")
    values
  end

  def capture_windows!(recorder, root, store, table, profile, prefix)
    rows = {}
    %w[full middle all-empty zero].each do |window|
      predicate = case window
                  when 'full' then ''
                  when 'middle' then ' WHERE id BETWEEN 3 AND 4'
                  when 'all-empty' then ' WHERE length(q)=0'
                  when 'zero' then ' WHERE id=0'
                  end
      sql = "SELECT id, q FROM default.#{table}#{predicate} ORDER BY id FORMAT RowBinary"
      record = checked_success!(recorder.run("#{prefix}-rowbinary-#{profile.fetch('id')}-#{window}", store, sql),
        "#{prefix} #{window} RowBinary #{profile.fetch('id')}")
      expected = expected_window(profile, window)
      actual = output_bytes(record)
      require_true(actual == expected,
        "#{prefix} #{window} RowBinary differs from fixed literal for #{profile.fetch('id')}: #{actual.unpack1('H*')}")
      rows[window] = { 'bytes' => actual.bytesize, 'sha256' => Digest::SHA256.hexdigest(actual),
        'matches_independent_literal' => true }
    end
    rows
  end

  class Probe
    def initialize(options)
      @binary = RecheckRecursiveQBitW230.validate_binary!(options.fetch(:clickhouse))
      @helper, @helper_sha = RecheckRecursiveQBitW230.validate_helper!(options.fetch(:helper), options.fetch(:helper_sha256))
      @helper_sha_at_start = RecheckRecursiveQBitW230.sha256_file(@helper)
      @source_root = RecheckRecursiveQBitW230.validate_root(options.fetch(:source_root), SOURCE_PREFIX, 'stock capture root')
      @evidence_root = RecheckRecursiveQBitW230.validate_root(options.fetch(:evidence_root), EVIDENCE_PREFIX, 'evidence root')
      @profiles = RecheckRecursiveQBitW230.profiles
      @source_recorder = R::Recorder.new(@source_root, @binary)
      @evidence_recorder = R::Recorder.new(@evidence_root, @binary)
      @stock_records = []
      @native_records = []
      @profile_records = []
      @helper_output = nil
      @fatal = nil
    end

    def prepare_layout
      [File.join(@source_root, 'invocations'), File.join(@source_root, 'stores'), File.join(@source_root, 'parts'),
       File.join(@source_root, 'cases'), File.join(@evidence_root, 'invocations'), File.join(@evidence_root, 'stores'),
       File.join(@evidence_root, 'generated'), File.join(@evidence_root, 'generated', 'parts'),
       File.join(@evidence_root, 'cases')].each { |path| RecheckRecursiveQBitW230.make_dir(path) }
      @profiles.each do |profile|
        id = profile.fetch('id')
        [File.join(@source_root, 'stores', id), File.join(@source_root, 'parts', id),
         File.join(@source_root, 'cases', id), File.join(@evidence_root, 'stores', id),
         File.join(@evidence_root, 'cases', id), File.join(@evidence_root, 'generated', 'parts', id)].each do |path|
          RecheckRecursiveQBitW230.make_dir(path)
        end
      end
      RecheckRecursiveQBitW230.make_dir(File.join(@source_root, 'stores', 'pins'))
    end

    def run_stock(label, store, sql, input: nil)
      record = RecheckRecursiveQBitW230.checked_success!(@source_recorder.run(label, store, sql, input: input,
        timeout: RecheckRecursiveQBitW230::PROCESS_TIMEOUT_SECONDS), label)
      @stock_records << record.reject { |key, _| %w[stdout stderr path].include?(key) }
      record
    end

    def run_native(label, store, sql, input: nil)
      record = RecheckRecursiveQBitW230.checked_success!(@evidence_recorder.run(label, store, sql, input: input,
        timeout: RecheckRecursiveQBitW230::PROCESS_TIMEOUT_SECONDS), label)
      @native_records << record.reject { |key, _| %w[stdout stderr path].include?(key) }
      record
    end

    def pin_runtime
      store = File.join(@source_root, 'stores', 'pins')
      version = run_stock('runtime-version-pin', store, 'SELECT version() FORMAT TSVRaw')
      RecheckRecursiveQBitW230.require_true(RecheckRecursiveQBitW230.output_bytes(version).strip == RecheckRecursiveQBitW230::CLICKHOUSE_VERSION,
        'ClickHouse runtime version differs from pin')
      build = run_stock('runtime-build-pin', store,
        "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw")
      RecheckRecursiveQBitW230.require_true(RecheckRecursiveQBitW230.output_bytes(build).strip == "VERSION_GITHASH=#{RecheckRecursiveQBitW230::CLICKHOUSE_BUILD}",
        'ClickHouse runtime build hash differs from pin')
      @runtime_pin = { 'binary' => @binary, 'sha256' => CLICKHOUSE_SHA256,
        'version' => RecheckRecursiveQBitW230::CLICKHOUSE_VERSION, 'build_hash' => RecheckRecursiveQBitW230::CLICKHOUSE_BUILD,
        'source_correlation' => 'runtime binary and pinned source checkout are separate pins' }
    end

    def capture_stock_profile(profile)
      id = profile.fetch('id')
      table = RecheckRecursiveQBitW230.table_name(profile, 'stock')
      store = File.join(@source_root, 'stores', id)
      create = run_stock("stock-create-#{id}", store, RecheckRecursiveQBitW230.create_sql(table, profile))
      insert_bytes = RecheckRecursiveQBitW230.literal_rowbinary_hex(profile).map { |hex| RecheckRecursiveQBitW230.hex_bytes(hex, "#{id} RowBinary row") }.join.b
      insert = run_stock("stock-insert-#{id}", store, "INSERT INTO default.#{table} FORMAT RowBinary", input: insert_bytes)
      check = run_stock("stock-check-#{id}", store, "CHECK TABLE default.#{table} FORMAT TSVRaw")
      RecheckRecursiveQBitW230.require_check!(check, "stock CHECK #{id}")
      schema = run_stock("stock-schema-#{id}", store,
        "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
      expected_schema = "id\tUInt64\nq\t#{profile.fetch('declared_type')}\n"
      RecheckRecursiveQBitW230.require_true(RecheckRecursiveQBitW230.output_bytes(schema) == expected_schema, "stock exact schema differs for #{id}")
      part_query = run_stock("stock-part-#{id}", store,
        "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw")
      fields = RecheckRecursiveQBitW230.parse_tsv_line!(RecheckRecursiveQBitW230.output_bytes(part_query), 5, "stock part census #{id}")
      RecheckRecursiveQBitW230.require_true(fields[0] == 'all_1_1_0' && fields[1] == '6' && fields[2] == '4' && fields[3] == 'Wide',
        "stock part identity/grid differs for #{id}: #{fields.inspect}")
      original = File.expand_path(fields[4])
      RecheckRecursiveQBitW230.require_true(original.start_with?(store + File::SEPARATOR) && File.directory?(original) && !File.symlink?(original) &&
        File.realpath(original) == original, "stock part path escaped its isolated store for #{id}")
      part_parent = File.join(@source_root, 'parts', id)
      copied = File.join(part_parent, 'all_1_1_0')
      RecheckRecursiveQBitW230.require_true(!File.exist?(copied) && !File.symlink?(copied), "stock part destination already exists: #{copied}")
      FileUtils.cp_r(original, copied)
      source_inventory = RecheckRecursiveQBitW230.inventory(copied)
      windows = RecheckRecursiveQBitW230.capture_windows!(@source_recorder, @source_root, store, table, profile, 'stock')
      row_grid = RecheckRecursiveQBitW230.occurrence_grid(profile)
      expected_grid = profile.fetch('id') == 'array_qbit_bfloat16_16_all_empty' ? [0, 0, 0] : [2, 0, 3]
      RecheckRecursiveQBitW230.require_true(row_grid == expected_grid, "fixed QBit occurrence grid changed for #{id}: #{row_grid.inspect}")
      record = {
        'id' => id, 'declared_type' => profile.fetch('declared_type'), 'table' => table,
        'store' => store, 'source_part_path' => copied, 'source_part_inventory' => source_inventory,
        'rows' => profile.fetch('rows'), 'row_keys' => RecheckRecursiveQBitW230::ROW_KEYS, 'mark_rows' => RecheckRecursiveQBitW230::MARK_ROWS,
        'leaf_slots_per_mark' => row_grid, 'check_output' => RecheckRecursiveQBitW230.output_bytes(check), 'schema_output' => RecheckRecursiveQBitW230.output_bytes(schema),
        'windows' => windows,
        'processes' => [create, insert, check, schema, part_query].map { |item| item.reject { |key, _| %w[stdout stderr path].include?(key) } } +
          @source_recorder.records.select { |item| item.fetch('label').start_with?("stock-rowbinary-#{id}-") },
      }
      @profile_records << record
      RecheckRecursiveQBitW230.write_json(File.join(@source_root, 'cases', id + '.json'), record)
      record
    end

    def capture_stock_profiles
      @profiles.each { |profile| capture_stock_profile(profile) }
      @source_inventory_pre = @profile_records.map do |record|
        { 'id' => record.fetch('id'), 'inventory' => RecheckRecursiveQBitW230.inventory(record.fetch('source_part_path')) }
      end
      RecheckRecursiveQBitW230.write_json(File.join(@source_root, 'physical.pre.json'),
        { 'format' => 'recursive_qbit_w230_physical_v1', 'profiles' => @source_inventory_pre })
    end

    def helper_input
      generated_root = File.join(@evidence_root, 'generated', 'parts')
      {
        'format' => RecheckRecursiveQBitW230::INPUT_FORMAT,
        'capture_root' => @source_root,
        'generated_root' => generated_root,
        'profiles' => @profiles.map do |profile|
          {
            'id' => profile.fetch('id'), 'declared_type' => profile.fetch('declared_type'),
            'source_part_path' => File.join(@source_root, 'parts', profile.fetch('id'), 'all_1_1_0'),
            'library_part_path' => File.join(generated_root, profile.fetch('id'), 'all_1_1_0'),
            'row_keys' => RecheckRecursiveQBitW230::ROW_KEYS, 'mark_rows' => RecheckRecursiveQBitW230::MARK_ROWS,
            'rows' => profile.fetch('rows'), 'literal_rowbinary_hex' => RecheckRecursiveQBitW230.literal_rowbinary_hex(profile),
          }
        end,
      }
    end

    def capture_helper
      input_path = File.join(@evidence_root, 'generated', 'helper-input.json')
      manifest = helper_input
      RecheckRecursiveQBitW230.write_json(input_path, manifest)
      manifest.fetch('profiles').each do |profile|
        RecheckRecursiveQBitW230.require_true(!File.exist?(profile.fetch('library_part_path')) && !File.symlink?(profile.fetch('library_part_path')),
          "library output part already exists: #{profile.fetch('library_part_path')}")
      end
      RecheckRecursiveQBitW230.require_true(RecheckRecursiveQBitW230.sha256_file(@helper) == @helper_sha_at_start,
        'prebuilt helper changed after initial validation')
      @helper_input_sha = RecheckRecursiveQBitW230.sha256_file(input_path)
      argv = [@helper, '--input', input_path]
      record = @evidence_recorder.run('helper-read-write-roundtrip', File.join(@evidence_root, 'generated'), nil,
        timeout: RecheckRecursiveQBitW230::HELPER_TIMEOUT_SECONDS, argv: argv)
      RecheckRecursiveQBitW230.checked_success!(record, 'prebuilt Crystal helper')
      @helper_invocation_path = record.fetch('path')
      output = JSON.parse(RecheckRecursiveQBitW230.output_bytes(record).force_encoding(Encoding::UTF_8))
      RecheckRecursiveQBitW230.require_true(output.fetch('format') == RecheckRecursiveQBitW230::HELPER_FORMAT && output.fetch('profile_count') == @profiles.length,
        'helper output magic or profile count differs')
      actual_profiles = output.fetch('profiles')
      RecheckRecursiveQBitW230.require_true(actual_profiles.length == @profiles.length &&
        actual_profiles.map { |item| item.fetch('id') } == @profiles.map { |item| item.fetch('id') },
        'helper output profile roster/order differs')
      actual_profiles.zip(manifest.fetch('profiles')).each do |actual, expected|
        expected_keys = %w[declared_type id library_part_path library_rows mark_rows row_keys source_part_path source_rows]
        RecheckRecursiveQBitW230.require_true(actual.keys.sort == expected_keys.sort, "helper output fields differ for #{expected.fetch('id')}")
        %w[id declared_type source_part_path library_part_path row_keys mark_rows].each do |key|
          RecheckRecursiveQBitW230.require_true(actual.fetch(key) == expected.fetch(key), "helper #{key} differs for #{expected.fetch('id')}")
        end
        RecheckRecursiveQBitW230.require_true(actual.fetch('source_rows') == expected.fetch('rows') && actual.fetch('library_rows') == expected.fetch('rows'),
          "helper source/library values differ from independent fixture for #{expected.fetch('id')}")
        source_part = expected.fetch('source_part_path')
        generated_part = expected.fetch('library_part_path')
        RecheckRecursiveQBitW230.require_true(File.realpath(source_part) == source_part && File.directory?(source_part),
          "helper source path is invalid for #{expected.fetch('id')}")
        allowed = File.realpath(File.join(@evidence_root, 'generated', 'parts')) + File::SEPARATOR
        RecheckRecursiveQBitW230.require_true(generated_part.start_with?(allowed) && File.directory?(generated_part) &&
          !File.symlink?(generated_part) && File.realpath(generated_part) == generated_part,
          "helper library part escaped generated root for #{expected.fetch('id')}")
      end
      @helper_output = output
      @helper_process = record.reject { |key, _| %w[stdout stderr path].include?(key) }
      RecheckRecursiveQBitW230.write_json(File.join(@evidence_root, 'generated', 'helper-output.json'), output)
      @library_inventories = actual_profiles.map do |item|
        { 'id' => item.fetch('id'), 'path' => item.fetch('library_part_path'), 'inventory' => RecheckRecursiveQBitW230.inventory(item.fetch('library_part_path')) }
      end
      @helper_sha_after = RecheckRecursiveQBitW230.sha256_file(@helper)
      RecheckRecursiveQBitW230.require_true(@helper_sha_after == @helper_sha, 'prebuilt helper changed during capture')
      RecheckRecursiveQBitW230.require_true(RecheckRecursiveQBitW230.sha256_file(input_path) == @helper_input_sha, 'helper input manifest changed during helper execution')
      source_post = @profile_records.map do |item|
        { 'id' => item.fetch('id'), 'inventory' => RecheckRecursiveQBitW230.inventory(item.fetch('source_part_path')) }
      end
      RecheckRecursiveQBitW230.require_true(source_post == @source_inventory_pre, 'helper changed a stock-authored source part')
      RecheckRecursiveQBitW230.write_json(File.join(@source_root, 'physical.after-helper.json'),
        { 'format' => 'recursive_qbit_w230_physical_v1', 'profiles' => source_post })
      RecheckRecursiveQBitW230.write_json(File.join(@evidence_root, 'generated', 'library-physical.json'),
        { 'format' => 'recursive_qbit_w230_library_physical_v1', 'profiles' => @library_inventories })
    rescue JSON::ParserError => error
      RecheckRecursiveQBitW230.fail!("helper stdout is not one JSON document: #{error.message}")
    end

    def create_native_target(profile)
      id = profile.fetch('id')
      table = RecheckRecursiveQBitW230.table_name(profile, 'native')
      store = File.join(@evidence_root, 'stores', id)
      create = run_native("native-create-#{id}", store, RecheckRecursiveQBitW230.create_sql(table, profile))
      data_path_record = run_native("native-data-path-#{id}", store,
        "SELECT arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw")
      data_path = File.expand_path(RecheckRecursiveQBitW230.output_bytes(data_path_record).strip)
      RecheckRecursiveQBitW230.require_true(data_path.start_with?(store + File::SEPARATOR) && File.directory?(data_path) &&
        !File.symlink?(data_path) && File.realpath(data_path) == data_path,
        "native table path escaped isolated store for #{id}")
      detached = File.join(data_path, 'detached')
      RecheckRecursiveQBitW230.require_true(File.directory?(detached) && !File.symlink?(detached) && File.realpath(detached) == detached,
        "native detached directory invalid for #{id}")
      { 'id' => id, 'table' => table, 'store' => store, 'data_path' => data_path,
        'detached_part_path' => File.join(detached, 'all_1_1_0'),
        'create_processes' => [create, data_path_record].map { |item| item.reject { |key, _| %w[stdout stderr path].include?(key) } } }
    end

    def inventory_delta(before, after)
      before_map = before.to_h { |entry| [entry.fetch('path'), entry] }
      after_map = after.to_h { |entry| [entry.fetch('path'), entry] }
      removed = before_map.keys - after_map.keys
      changed = before_map.keys.select { |path| after_map.key?(path) && before_map.fetch(path) != after_map.fetch(path) }
      added = after_map.keys - before_map.keys
      [removed.sort, changed.sort, added.sort]
    end

    def attach_profile(profile, target, helper_profile, generated_inventory)
      id = profile.fetch('id')
      generated_part = helper_profile.fetch('library_part_path')
      generated_before = RecheckRecursiveQBitW230.inventory(generated_part)
      detached_part = target.fetch('detached_part_path')
      RecheckRecursiveQBitW230.require_true(!File.exist?(detached_part) && !File.symlink?(detached_part),
        "native detached destination already exists for #{id}")
      FileUtils.cp_r(generated_part, detached_part)
      detached_before = RecheckRecursiveQBitW230.inventory(detached_part)
      RecheckRecursiveQBitW230.require_true(detached_before == generated_before && generated_before == generated_inventory.fetch(id),
        "copied helper part differs before ATTACH for #{id}")
      attach = run_native("native-attach-#{id}", target.fetch('store'),
        "ALTER TABLE default.#{target.fetch('table')} ATTACH PART 'all_1_1_0'")
      check = run_native("native-check-#{id}", target.fetch('store'),
        "CHECK TABLE default.#{target.fetch('table')} FORMAT TSVRaw")
      RecheckRecursiveQBitW230.require_check!(check, "native CHECK #{id}")
      schema = run_native("native-schema-#{id}", target.fetch('store'),
        "SELECT name, type FROM system.columns WHERE database='default' AND table='#{target.fetch('table')}' ORDER BY position FORMAT TSVRaw")
      expected_schema = "id\tUInt64\nq\t#{profile.fetch('declared_type')}\n"
      RecheckRecursiveQBitW230.require_true(RecheckRecursiveQBitW230.output_bytes(schema) == expected_schema, "native attached schema differs for #{id}")
      part_query = run_native("native-part-#{id}", target.fetch('store'),
        "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{target.fetch('table')}' AND active ORDER BY name FORMAT TSVRaw")
      fields = RecheckRecursiveQBitW230.parse_tsv_line!(RecheckRecursiveQBitW230.output_bytes(part_query), 5, "native part census #{id}")
      expected_part_path = File.join(target.fetch('data_path'), 'all_1_1_0')
      RecheckRecursiveQBitW230.require_true(fields[0] == 'all_1_1_0' && fields[1] == '6' && fields[2] == '4' && fields[3] == 'Wide' &&
        File.expand_path(fields[4]) == expected_part_path,
        "native attached part identity/grid/path differs for #{id}: #{fields.inspect}")
      attached_inventory = RecheckRecursiveQBitW230.inventory(expected_part_path)
      removed, changed, added = inventory_delta(generated_before, attached_inventory)
      RecheckRecursiveQBitW230.require_true(removed.empty? && changed.empty? && added == [RecheckRecursiveQBitW230::INVALIDATED_FILE],
        "ATTACH changed unexpected files for #{id}: removed=#{removed.inspect}, changed=#{changed.inspect}, added=#{added.inspect}")
      aux = File.binread(File.join(expected_part_path, RecheckRecursiveQBitW230::INVALIDATED_FILE)).split("\n", -1)
      RecheckRecursiveQBitW230.require_true(aux.pop == '' && aux.sort == RecheckRecursiveQBitW230::INVALIDATED_NAMES.sort,
        "ATTACH invalidated-system-columns auxiliary differs for #{id}")
      columns = File.binread(File.join(expected_part_path, 'columns.txt')).force_encoding(Encoding::UTF_8).scrub
      expected_columns = "columns format version: 1\n2 columns:\n`id` UInt64\n`q` #{profile.fetch('declared_type')}\n"
      RecheckRecursiveQBitW230.require_true(columns == expected_columns, "library attached exact columns declaration differs for #{id}")
      type_file = File.binread(File.join(expected_part_path, 'default_compression_codec.txt')).strip
      RecheckRecursiveQBitW230.require_true(type_file == 'CODEC(LZ4)', "attached part default codec differs for #{id}: #{type_file.inspect}")
      metadata_version = File.binread(File.join(expected_part_path, 'metadata_version.txt')).strip
      RecheckRecursiveQBitW230.require_true(metadata_version == '0', "attached part metadata version differs for #{id}")
      windows = RecheckRecursiveQBitW230.capture_windows!(@evidence_recorder, @evidence_root, target.fetch('store'), target.fetch('table'), profile, 'native')
      {
        'id' => id, 'classification' => 'native_attached_check_and_rowbinary_observed',
        'table' => target.fetch('table'), 'declared_type' => profile.fetch('declared_type'),
        'helper_part_path' => generated_part, 'attached_part_path' => expected_part_path,
        'helper_part_inventory' => generated_before, 'attached_part_inventory' => attached_inventory,
        'removed_paths' => removed, 'changed_paths' => changed, 'added_paths' => added,
        'check_output' => RecheckRecursiveQBitW230.output_bytes(check), 'schema_output' => RecheckRecursiveQBitW230.output_bytes(schema),
        'columns_txt' => columns, 'default_compression_codec' => type_file,
        'metadata_version' => metadata_version, 'windows' => windows,
        'processes' => target.fetch('create_processes') +
          [attach, check, schema, part_query].map { |item| item.reject { |key, _| %w[stdout stderr path].include?(key) } } +
          @evidence_recorder.records.select { |item| item.fetch('label').start_with?("native-rowbinary-#{id}-") },
      }
    end

    def run
      prepare_layout
      @source_pin = RecheckRecursiveQBitW230.source_manifest
      RecheckRecursiveQBitW230.write_json(File.join(@source_root, 'source-pin.json'), @source_pin)
      pin_runtime
      capture_stock_profiles
      capture_helper
      generated_inventory = @library_inventories.to_h { |item| [item.fetch('id'), item.fetch('inventory')] }
      attached = @profiles.map do |profile|
        target = create_native_target(profile)
        helper_profile = @helper_output.fetch('profiles').find { |item| item.fetch('id') == profile.fetch('id') }
        record = attach_profile(profile, target, helper_profile, generated_inventory)
        @native_records << record
        RecheckRecursiveQBitW230.write_json(File.join(@evidence_root, 'cases', profile.fetch('id') + '.json'), record)
        record
      end
      source_post = RecheckRecursiveQBitW230.source_manifest
      RecheckRecursiveQBitW230.require_true(@source_pin == source_post, 'pinned ClickHouse source files changed during capture')
      RecheckRecursiveQBitW230.write_json(File.join(@source_root, 'source-pin-post.json'), source_post)
      RecheckRecursiveQBitW230.require_true(RecheckRecursiveQBitW230.sha256_file(@helper) == @helper_sha && RecheckRecursiveQBitW230.sha256_file(@helper) == @helper_sha_after,
        'prebuilt helper changed during the capture')
      input_path = File.join(@evidence_root, 'generated', 'helper-input.json')
      RecheckRecursiveQBitW230.require_true(RecheckRecursiveQBitW230.sha256_file(input_path) == @helper_input_sha, 'captured helper input changed')
      source_post_inventory = @profile_records.map do |item|
        { 'id' => item.fetch('id'), 'inventory' => RecheckRecursiveQBitW230.inventory(item.fetch('source_part_path')) }
      end
      RecheckRecursiveQBitW230.require_true(source_post_inventory == @source_inventory_pre, 'stock part inventory changed after attach reads')
      RecheckRecursiveQBitW230.write_json(File.join(@source_root, 'physical.post.json'),
        { 'format' => 'recursive_qbit_w230_physical_v1', 'profiles' => source_post_inventory })
      script_paths = %w[scripts/recheck_recursive_qbit_w230.rb scripts/check_recursive_qbit_evidence_w230.rb]
        .map { |relative| File.join(RecheckRecursiveQBitW230::REPO_ROOT, relative) }
      @code_pins = script_paths.to_h do |path|
        RecheckRecursiveQBitW230.plain_file!(path, 'W230 script source')
        [path.delete_prefix(RecheckRecursiveQBitW230::REPO_ROOT + File::SEPARATOR), RecheckRecursiveQBitW230.sha256_file(path)]
      end
      RecheckRecursiveQBitW230.write_json(File.join(@evidence_root, 'result.json'), {
        'format' => RecheckRecursiveQBitW230::RESULT_FORMAT, 'classification' => 'paired_recursive_qbit_profiles_observed',
        'success' => true, 'source_root' => @source_root, 'evidence_root' => @evidence_root,
        'runtime_pin' => @runtime_pin, 'source_pin' => @source_pin,
        'helper_path' => @helper, 'helper_sha256_expected' => @helper_sha,
        'helper_sha256_observed_after' => @helper_sha_after,
        'helper_input_path' => input_path, 'helper_input_sha256' => @helper_input_sha,
        'helper_stdout_sha256' => RecheckRecursiveQBitW230.sha256_file(@helper_invocation_path + '.stdout'),
        'code_pins' => @code_pins,
        'profile_count' => @profiles.length, 'stock_profiles' => @profile_records,
        'helper_output' => @helper_output, 'library_inventories' => @library_inventories,
        'native_profiles' => attached,
        'counts' => { 'source_processes' => @source_recorder.records.length,
          'evidence_processes' => @evidence_recorder.records.length,
          'profiles' => @profiles.length, 'source_parts' => @profile_records.length,
          'library_parts' => @library_inventories.length, 'attached_parts' => attached.length },
        'process_rosters' => { 'source' => @source_recorder.records.map { |item| item.fetch('label') },
          'evidence' => @evidence_recorder.records.map { |item| item.fetch('label') } },
        'scope' => 'static Array chains over QBit or direct Nullable(QBit); no Tuple, Map, Variant, Dynamic, JSON, or Nested widening',
      })
      puts "W230 paired recursive QBit capture: #{@profiles.length} profiles; source processes=#{@source_recorder.records.length}; evidence processes=#{@evidence_recorder.records.length}; root=#{@evidence_root}"
      true
    rescue StandardError => error
      @fatal ||= "#{error.class}: #{error.message}"
      begin
      RecheckRecursiveQBitW230.write_json(File.join(@evidence_root, 'runner_failure.json'),
          { 'format' => 'recursive_qbit_w230_failure_v1', 'error_class' => error.class.name, 'error' => error.message })
      rescue StandardError
        # Preserve the original diagnostic when a fresh evidence root is unavailable.
      end
      warn "W230 recursive QBit runner failure: #{@fatal}"
      false
    end
  end

  def main(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/recheck_recursive_qbit_w230.rb --clickhouse BIN --helper PREBUILT --helper-sha256 SHA --source-root EMPTY_ROOT --evidence-root EMPTY_ROOT'
      opts.on('--clickhouse PATH') { |value| options[:clickhouse] = value }
      opts.on('--helper PATH') { |value| options[:helper] = value }
      opts.on('--helper-sha256 SHA') { |value| options[:helper_sha256] = value }
      opts.on('--source-root PATH') { |value| options[:source_root] = value }
      opts.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
    end
    parser.parse!(argv)
    RecheckRecursiveQBitW230.require_true(argv.empty? && %i[clickhouse helper helper_sha256 source_root evidence_root].all? { |key| options.key?(key) }, parser.to_s)
    Probe.new(options).run
  rescue StandardError => error
    warn "W230 runner setup failure: #{error.class}: #{error.message}"
    false
  end
end

if $PROGRAM_NAME == __FILE__
  options = { clickhouse: RecheckRecursiveQBitW230::CLICKHOUSE_BIN }
  exit(RecheckRecursiveQBitW230.main(ARGV) ? 0 : 1)
end
