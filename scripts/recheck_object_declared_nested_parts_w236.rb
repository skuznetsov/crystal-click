#!/usr/bin/env ruby
# Paired native consumer for the five generated W236 Nested library parts.
# The parts root is read-only. Expected RowBinary is rebuilt from literals and
# is never taken as authority from the generator manifest.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require_relative 'recheck_recursive_qbit_dynamic_w233'
require_relative 'recheck_object_qbit_recursive_stock_w234'

module RecheckObjectDeclaredNestedPartsW236
  extend self

  Q = RecheckRecursiveQBitDynamicW233
  R = Q::R
  I = RecheckObjectQBitRecursiveStockW234
  SOURCE_ROOT = '/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1'.freeze
  SOURCE_REVISION = '0ca8150d9b1d0886edb2e3b4ab65eebb768d0357'.freeze
  CLICKHOUSE_BIN = '/private/tmp/crystal-click-w216-runtime-recovery.DmL9Kw/clickhouse-stripped'.freeze
  CLICKHOUSE_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  CLICKHOUSE_VERSION = '26.10.1.1201'.freeze
  CLICKHOUSE_BUILD = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  ROOT_PREFIX = 'crystal-click-w236-consumer.'.freeze
  MANIFEST_NAME = 'object_declared_nested_parts_w236.json'.freeze
  STOCK_FORMAT = 'object_declared_nested_stock_w236_v1'.freeze
  PARTS_FORMAT = 'object_declared_nested_parts_w236_v1'.freeze
  PROCESS_TIMEOUT_SECONDS = 90
  MAX_EXECUTION_SECONDS = 30
  MEMORY_LIMIT_BYTES = 1_073_741_824
  MAX_PROCESS_COUNT = 50
  EXPECTED_PROCESS_COUNT = 42
  MAX_TREE_ENTRIES = 8192
  MAX_TREE_BYTES = 64 * 1024 * 1024
  MAX_MANIFEST_BYTES = 4 * 1024 * 1024
  MAX_CAPTURE_FILES = 4096
  MAX_CAPTURE_BYTES = 64 * 1024 * 1024
  MAX_PART_FILES = 512
  MAX_PART_BYTES = 64 * 1024 * 1024
  PART_MARKS = 4
  LIBRARY_MARK_ROWS = [2, 2, 2].freeze
  ROW_IDS = [1, 2, 3, 4, 5, 6].freeze
  NESTED_TYPE = 'Nested(n UInt8, s String)'.freeze

  # Fixed from the W236 stock witness. The consumer independently rebuilds
  # each DDL and compares the generator's exact copy against it.
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
    'object_shared_data_buckets_for_wide_part=2', 'object_shared_data_target_chunk_rows=1',
    "map_serialization_version='basic'", "map_serialization_version_for_zero_level_parts='basic'",
    'use_compact_variant_discriminators_serialization=0', 'flatten_nested=0',
  ].freeze

  # Each literal is one RowBinary body for j.q. UInt64 parent ids are added
  # separately below. These bytes do not come from either input manifest.
  CASES = [
    {
      'id' => 'direct_nested', 'table' => 'w236_json_nested_direct',
      'inner_type' => NESTED_TYPE,
      'row_values' => [
        [[1, 'a'], [2, 'long']], [], nil, [[255, 'x']],
        [[0, 'left'], [17, 'r'], [42, 'longer-right']], nil,
      ],
      'body_hex' => [
        '0201016102046c6f6e67', '00', '00', '01ff0178',
        '0300046c6566741101722a0c6c6f6e6765722d7269676874', '00',
      ],
    },
    {
      'id' => 'array_nested', 'table' => 'w236_json_nested_array',
      'inner_type' => "Array(#{NESTED_TYPE})",
      'row_values' => [
        [[[1, 'a'], [2, 'long']], [[3, 'm']]], [], nil, [[]],
        [[[0, 'left'], [17, 'r']]], [[[4, 'tail'], [8, 'x']], [[9, 'long']]],
      ],
      'body_hex' => [
        '020201016102046c6f6e670103016d', '00', '00', '0100',
        '010200046c656674110172', '020204047461696c0801780109046c6f6e67',
      ],
    },
    {
      'id' => 'tuple_nested', 'table' => 'w236_json_nested_tuple',
      'inner_type' => "Tuple(items #{NESTED_TYPE}, tag UInt8)",
      'row_values' => [
        { 'items' => [[1, 't'], [2, 'side']], 'tag' => 7 },
        { 'items' => [], 'tag' => 9 }, nil,
        { 'items' => [[255, 'x']], 'tag' => 255 },
        { 'items' => [[0, 'left'], [17, 'r'], [42, 'longer-right']], 'tag' => 5 },
        { 'items' => [], 'tag' => 0 },
      ],
      'body_hex' => [
        '0201017402047369646507', '0009', '0000', '01ff0178ff',
        '0300046c6566741101722a0c6c6f6e6765722d726967687405', '0000',
      ],
    },
    {
      'id' => 'map_nested', 'table' => 'w236_json_nested_map',
      'inner_type' => "Map(String, #{NESTED_TYPE})",
      'row_values' => [
        [['a', [[1, 'a'], [2, 'long']]], ['long-key', [[3, 'm']]]],
        [], nil, [['x', []]],
        [['left', [[0, 'left'], [17, 'r'], [42, 'longer-right']]]],
        [['tail', [[9, 'z']]]],
      ],
      'body_hex' => [
        '0201610201016102046c6f6e67086c6f6e672d6b65790103016d',
        '00', '00', '01017800',
        '01046c6566740300046c6566741101722a0c6c6f6e6765722d7269676874',
        '01047461696c0109017a',
      ],
    },
    {
      'id' => 'variant_nested', 'table' => 'w236_json_nested_variant',
      'inner_type' => "Variant(#{NESTED_TYPE}, String)",
      'row_values' => [
        { 'variant' => 'nested', 'value' => [[1, 'a'], [2, 'long']] },
        { 'variant' => 'string', 'value' => 'v' }, nil,
        { 'variant' => 'nested', 'value' => [[255, 'x']] },
        { 'variant' => 'string', 'value' => 'much-longer' },
        { 'variant' => 'nested', 'value' => [[0, 'left'], [17, 'r'], [42, 'longer-right']] },
      ],
      'body_hex' => [
        '000201016102046c6f6e67', '010176', 'ff', '0001ff0178',
        '010b6d7563682d6c6f6e676572',
        '000300046c6566741101722a0c6c6f6e6765722d7269676874',
      ],
    },
  ].map { |item| item.freeze }.freeze

  class ProbeFailure < StandardError; end

  def fail!(message)
    raise ProbeFailure, message
  end

  def require_true(condition, message)
    fail!(message) unless condition
  end

  def sha256_file(path)
    Digest::SHA256.file(path).hexdigest
  end

  def safe_relative_path(root, relative, label)
    require_true(relative.is_a?(String) && !relative.empty? &&
      !relative.start_with?(File::SEPARATOR) && !relative.include?("\0"),
      "#{label} must be a non-empty relative path")
    segments = relative.split(File::SEPARATOR, -1)
    require_true(segments.none? { |segment| segment.empty? || segment == '.' || segment == '..' },
      "#{label} contains an unsafe path segment")
    full = File.expand_path(relative, root)
    require_true(full.start_with?(root + File::SEPARATOR), "#{label} escapes its root")
    full
  end

  def validate_capture_root(path)
    full = File.expand_path(path)
    require_true(File.directory?(full) && !File.symlink?(full) &&
      File.realpath(full) == full && Dir.children(full).empty?,
      'capture root must be a fresh, empty, canonical directory')
    require_true(File.dirname(full) == File.realpath('/private/tmp') &&
      File.basename(full).start_with?(ROOT_PREFIX),
      "capture root must be a direct /private/tmp child named #{ROOT_PREFIX}*")
    full
  end

  def validate_parts_root(path)
    full = File.expand_path(path)
    require_true(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full,
      'parts root must be an existing canonical directory')
    require_true(File.dirname(full) == File.realpath('/private/tmp'),
      'parts root must be a direct /private/tmp child')
    full
  end

  def validate_binary(path)
    full = File.expand_path(path)
    require_true(File.file?(full) && !File.symlink?(full) && File.realpath(full) == full &&
      File.executable?(full), "ClickHouse runtime is absent, noncanonical, symlinked, or not executable: #{full}")
    require_true(full == CLICKHOUSE_BIN && sha256_file(full) == CLICKHOUSE_SHA256,
      'ClickHouse runtime differs from the W236 fixed path/SHA pin')
    full
  end

  def load_json_file(path, max_bytes:, label:)
    require_true(File.file?(path) && !File.symlink?(path) && File.realpath(path) == path,
      "#{label} is absent, symlinked, or noncanonical: #{path}")
    require_true(File.size(path) <= max_bytes, "#{label} exceeds the fixed byte cap")
    JSON.parse(File.binread(path))
  rescue JSON::ParserError => error
    fail!("#{label} is malformed JSON: #{error.message}")
  end

  # Bounds all entries, including empty directories, before file hashing or
  # native work. Input roots normally reject symlinks; the stock Atomic store
  # is validated separately by the inherited W234 alias checker.
  def bounded_tree!(root, allow_symlinks: false, max_entries: MAX_TREE_ENTRIES, max_bytes: MAX_TREE_BYTES)
    full = File.realpath(root)
    count = 0
    bytes = 0
    Find.find(full) do |entry|
      next if entry == full
      count += 1
      require_true(count <= max_entries, "tree exceeds the fixed entry cap: #{full}")
      if File.symlink?(entry)
        require_true(allow_symlinks, "tree contains an unowned symlink: #{entry}")
        next
      end
      next if File.directory?(entry)
      require_true(File.file?(entry), "tree contains a non-regular entry: #{entry}")
      bytes += File.size(entry)
      require_true(bytes <= max_bytes, "tree exceeds the fixed byte cap: #{full}")
    end
    { 'entries' => count, 'bytes' => bytes }
  end

  def part_inventory(path)
    root = File.realpath(path)
    require_true(File.directory?(root) && !File.symlink?(path), "part root is not a plain directory: #{path}")
    files = []
    count = 0
    bytes = 0
    Find.find(root) do |entry|
      next if entry == root
      count += 1
      require_true(count <= MAX_PART_FILES, "part exceeds the fixed entry cap: #{root}")
      require_true(!File.symlink?(entry), "part contains a symlink: #{entry}")
      next if File.directory?(entry)
      require_true(File.file?(entry), "part contains a non-regular entry: #{entry}")
      bytes += File.size(entry)
      require_true(bytes <= MAX_PART_BYTES, "part exceeds the fixed byte cap: #{root}")
      relative = entry[(root.length + 1)..-1]
      require_true(relative && !relative.empty? &&
        relative.split('/').none? { |segment| segment.empty? || segment == '.' || segment == '..' },
        "part has an unsafe relative path: #{entry}")
      files << { 'path' => relative, 'size' => File.size(entry), 'sha256' => sha256_file(entry) }
    end
    files.sort_by { |item| item.fetch('path') }
  end

  def uint64(value)
    require_true(value.is_a?(Integer) && value >= 0 && value <= 18_446_744_073_709_551_615,
      "invalid UInt64 row id: #{value.inspect}")
    Array.new(8) { |index| (value >> (index * 8)) & 0xff }.pack('C*').b
  end

  def expected_rows(profile)
    body_hex = profile.fetch('body_hex')
    require_true(body_hex.length == ROW_IDS.length, "literal row count differs for #{profile.fetch('id')}")
    body_hex.each_with_index.map do |hex, index|
      require_true(hex.is_a?(String) && /\A(?:[0-9a-f]{2})*\z/.match?(hex),
        "literal RowBinary body is malformed for #{profile.fetch('id')} row #{index + 1}")
      uint64(ROW_IDS.fetch(index)) + [hex].pack('H*').b
    end
  end

  def semantic_row_values(profile)
    values = profile.fetch('row_values')
    require_true(values.length == ROW_IDS.length, "semantic row count differs for #{profile.fetch('id')}")
    values.each_with_index.map do |value, index|
      { 'id' => ROW_IDS.fetch(index), 'q_present' => !value.nil?, 'value' => value }
    end
  end

  def json_type(profile)
    "JSON(q #{profile.fetch('inner_type')})"
  end

  def create_sql(profile)
    "CREATE TABLE default.#{profile.fetch('table')} (id UInt64, j #{json_type(profile)}) " \
      "ENGINE=MergeTree ORDER BY id SETTINGS #{STOCK_SETTINGS.join(', ')}"
  end

  def schema_sql(table)
    "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw"
  end

  def check_sql(table)
    "CHECK TABLE default.#{table} FORMAT TSVRaw"
  end

  def part_sql(table)
    "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts " \
      "WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw"
  end

  def before_attach_sql(table)
    schema = "SELECT concat('__W236_SCHEMA__', name, '\\t', type) FROM system.columns " \
      "WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw"
    data_path = "SELECT concat('__W236_DATA_PATH__', arrayElement(data_paths, 1)) " \
      "FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw"
    "#{schema}; #{data_path}"
  end

  def after_attach_sql(table)
    schema = "SELECT concat('__W236_SCHEMA__', name, '\\t', type) FROM system.columns " \
      "WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw"
    part = "SELECT concat('__W236_PART__', name, '\\t', toString(rows), '\\t', " \
      "toString(marks), '\\t', part_type, '\\t', path) FROM system.parts " \
      "WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw"
    "#{schema}; #{part}"
  end

  def window_sql(table, window)
    predicate = {
      'full' => '',
      'middle' => ' WHERE id BETWEEN 3 AND 4',
      'empty' => ' WHERE id=0',
    }.fetch(window)
    "SELECT id, j.q FROM default.#{table}#{predicate} ORDER BY id " \
      'SETTINGS output_format_binary_write_json_as_string=0 FORMAT RowBinary'
  end

  def schema_stdout(profile)
    "id\tUInt64\nj\t#{json_type(profile)}\n"
  end

  def process_success?(record)
    record.fetch('classification') == 'process_success' &&
      record.fetch('exitstatus') == 0 && record.fetch('signaled') == false &&
      record.fetch('timed_out') == false && record.fetch('termsig').nil? &&
      record.fetch('spawn_error').nil?
  end

  def failure_kind(record)
    return 'timeout' if record.fetch('timed_out')
    return 'spawn_or_plumbing_failure' if record.fetch('spawn_error')
    return 'signal' if record.fetch('signaled') || record.fetch('termsig')
    return 'native_nonzero_exit' if record.fetch('exitstatus') && record.fetch('exitstatus') != 0

    'unexpected_process_outcome'
  end

  def process_summary(record)
    {
      'classification' => record.fetch('classification'),
      'exitstatus' => record.fetch('exitstatus'),
      'signaled' => record.fetch('signaled'),
      'termsig' => record.fetch('termsig'),
      'timed_out' => record.fetch('timed_out'),
      'spawn_error' => record.fetch('spawn_error'),
      'duration_ms' => record.fetch('duration_ms'),
      'stdout_bytes' => record.fetch('stdout_bytes'),
      'stderr_bytes' => record.fetch('stderr_bytes'),
      'stdout_sha256' => Digest::SHA256.hexdigest(record.fetch('stdout')),
      'stderr_sha256' => Digest::SHA256.hexdigest(record.fetch('stderr')),
      'failure_kind' => process_success?(record) ? nil : failure_kind(record),
      'capture_prefix' => "invocations/#{File.basename(record.fetch('path'))}",
    }
  end

  class Probe
    include RecheckObjectDeclaredNestedPartsW236

    def initialize(options)
      @binary = RecheckObjectDeclaredNestedPartsW236.validate_binary(options.fetch(:clickhouse))
      @root = RecheckObjectDeclaredNestedPartsW236.validate_capture_root(options.fetch(:capture_root))
      @parts_root = RecheckObjectDeclaredNestedPartsW236.validate_parts_root(options.fetch(:parts_root))
      @recorder = R::Recorder.new(@root, @binary)
      @stores = {}
      @profile_records = []
      @global_steps = {}
      @manifest_sha256 = nil
      @stock_root = nil
      @stock_inventory = nil
      @source_parts = {}
      @source_inventories = {}
      @fatal_error = nil
    end

    def run
      prepare_layout
      preflight_inputs
      pin_runtime
      CASES.each { |profile| run_profile(profile) }
      require_true(@recorder.records.length == EXPECTED_PROCESS_COUNT,
        "native process count differs: #{@recorder.records.length}, expected #{EXPECTED_PROCESS_COUNT}")
      require_true(@profile_records.map { |item| item.fetch('id') } == CASES.map { |item| item.fetch('id') },
        'native profile roster/order is incomplete')
      require_true(@profile_records.all? { |item| item.fetch('status') == 'attached_checked_and_all_literal_windows_matched' },
        'one or more native profile windows did not match')
      save_evidence
      puts JSON.generate(
        'status' => 'all_five_native_roundtrips_matched_independent_literals',
        'capture_root' => @root, 'parts_root' => @parts_root,
        'stock_root' => @stock_root, 'runtime_version' => CLICKHOUSE_VERSION,
        'runtime_build' => CLICKHOUSE_BUILD, 'invocations' => @recorder.records.length,
        'profile_ids' => @profile_records.map { |item| item.fetch('id') },
      )
      true
    rescue StandardError => error
      @fatal_error = "#{error.class}: #{error.message}"
      warn "W236 generated-part consumer stopped with captures preserved: #{@fatal_error}"
      begin
        save_evidence
      rescue StandardError => evidence_error
        warn "W236 partial evidence index could not be completed: #{evidence_error.class}: #{evidence_error.message}"
      end
      puts JSON.generate(
        'status' => 'generated_part_consumer_inconclusive',
        'capture_root' => @root, 'parts_root' => @parts_root,
        'stock_root' => @stock_root, 'invocations' => @recorder.records.length,
        'fatal_error' => @fatal_error,
      )
      false
    end

    private

    def require_true(condition, message)
      RecheckObjectDeclaredNestedPartsW236.require_true(condition, message)
    end

    def prepare_layout
      %w[invocations literal_rowbinary stores].each do |relative|
        R.make_dir(File.join(@root, relative))
      end
      CASES.each do |profile|
        store = File.join(@root, 'stores', profile.fetch('id'))
        R.make_dir(store)
        @stores[profile.fetch('id')] = store
      end
    end

    def source_file(relative, label, max_bytes: MAX_MANIFEST_BYTES)
      path = RecheckObjectDeclaredNestedPartsW236.safe_relative_path(@parts_root, relative, label)
      require_true(File.file?(path) && !File.symlink?(path) && File.realpath(path) == path,
        "#{label} is absent, symlinked, or noncanonical")
      require_true(File.size(path) <= max_bytes, "#{label} exceeds its fixed byte cap")
      path
    end

    def stock_file(relative, label, max_bytes: MAX_MANIFEST_BYTES)
      path = RecheckObjectDeclaredNestedPartsW236.safe_relative_path(@stock_root, relative, label)
      require_true(File.file?(path) && !File.symlink?(path) && File.realpath(path) == path,
        "#{label} is absent, symlinked, or noncanonical")
      require_true(File.size(path) <= max_bytes, "#{label} exceeds its fixed byte cap")
      path
    end

    def expected_literal(profile, window)
      rows = RecheckObjectDeclaredNestedPartsW236.expected_rows(profile)
      case window
      when 'full' then rows.join.b
      when 'middle' then rows[2, 2].join.b
      when 'empty' then ''.b
      else fail!("unlisted RowBinary window: #{window.inspect}")
      end
    end

    def preflight_inputs
      bounded_tree!(@parts_root, allow_symlinks: false)
      manifest_path = File.join(@parts_root, MANIFEST_NAME)
      manifest = load_json_file(manifest_path, max_bytes: MAX_MANIFEST_BYTES,
        label: 'generated-parts manifest')
      require_true(manifest.fetch('format') == PARTS_FORMAT, 'generated-parts manifest format differs')
      profiles = manifest.fetch('profiles')
      expected_ids = CASES.map { |profile| profile.fetch('id') }
      require_true(profiles.is_a?(Array) && profiles.map { |item| item.fetch('id') } == expected_ids,
        'generated-parts manifest must contain exactly five fixed profiles in order')
      @manifest_sha256 = sha256_file(manifest_path)
      validate_stock_source(profiles)
      @manifest = manifest
    rescue KeyError, TypeError => error
      fail!("generated-parts manifest is missing or malformed: #{error.message}")
    end

    def validate_stock_source(generated_profiles)
      generated_profiles.each do |profile|
        stock = profile.fetch('stock')
        relative = stock.fetch('part_path_relative')
        segments = relative.split('/')
        require_true(segments.length == 6 && segments[0] == 'stores' &&
        segments[1] == profile.fetch('id') && segments[2] == 'store' &&
        /\A[0-9a-f]{3}\z/.match?(segments[3]) &&
          /\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/.match?(segments[4]) &&
          segments[4].delete('-').start_with?(segments[3]) &&
          segments[5] == 'all_1_1_0',
          "stock part-relative path does not match fixed Atomic store grammar: #{relative}")
        suffix = "#{File::SEPARATOR}#{relative}"
        part_path = stock.fetch('part_path')
        require_true(part_path.is_a?(String) && part_path.end_with?(suffix),
          "stock absolute and relative part paths disagree for #{profile.fetch('id')}")
        root = part_path.delete_suffix(suffix)
        if @stock_root
          require_true(@stock_root == root, 'generated profiles refer to multiple stock roots')
        else
          @stock_root = root
          require_true(File.directory?(@stock_root) && !File.symlink?(@stock_root) &&
            File.realpath(@stock_root) == @stock_root &&
            File.dirname(@stock_root) == File.realpath('/private/tmp') &&
            File.basename(@stock_root).start_with?('crystal-click-w236-stock.'),
            'stock root is not the fixed canonical W236 /private/tmp capture')
        end
      end

      witness = load_json_file(File.join(@stock_root, 'witnesses.json'),
        max_bytes: MAX_MANIFEST_BYTES, label: 'stock W236 witness')
      require_true(witness.fetch('format') == STOCK_FORMAT &&
        witness.fetch('source_reference') == "#{SOURCE_ROOT}@#{SOURCE_REVISION}",
        'stock witness format or pinned source reference differs')
      runtime = witness.fetch('runtime')
      require_true(runtime.fetch('path') == CLICKHOUSE_BIN &&
        runtime.fetch('sha256') == CLICKHOUSE_SHA256 &&
        runtime.fetch('version') == CLICKHOUSE_VERSION &&
        runtime.fetch('build_hash') == CLICKHOUSE_BUILD &&
        runtime.fetch('source_revision_is_separately_pinned_not_asserted_as_runtime_lineage') == true,
        'stock witness runtime/source pin differs')
      require_true(witness.fetch('process_count') == 50 && witness.fetch('process_cap') == 64 &&
        witness.fetch('fatal_error').nil?,
        'stock witness did not complete its exact 50-child discriminator')

      stock_profiles = witness.fetch('profiles')
      expected_ids = CASES.map { |profile| profile.fetch('id') } + ['ordinary_json_control']
      require_true(stock_profiles.map { |item| item.fetch('id') } == expected_ids,
        'stock witness profile/control roster differs')
      validate_stock_capture_inventory(stock_profiles)
      stock_by_id = stock_profiles.to_h { |item| [item.fetch('id'), item] }
      generated_profiles.zip(CASES).each do |generated, fixed|
        validate_stock_profile(stock_by_id.fetch(fixed.fetch('id')), generated, fixed)
      end
      control = stock_by_id.fetch('ordinary_json_control')
      require_true(control.fetch('status') == 'persisted_and_literal_rowbinary_matched' &&
        control.fetch('check_matches_expected') == true,
        'stock ordinary JSON positive control did not persist and pass CHECK')
    rescue KeyError, TypeError => error
      fail!("stock witness is missing required fields: #{error.message}")
    end

    def validate_stock_capture_inventory(stock_profiles)
      allowed_stores = stock_profiles.to_h do |profile|
        id = profile.fetch('id')
        store = File.join(@stock_root, 'stores', id)
        require_true(File.directory?(store) && !File.symlink?(store) && File.realpath(store) == store,
          "stock store is absent or noncanonical for #{id}")
        [store, profile.fetch('table')]
      end
      bounded_tree!(@stock_root, allow_symlinks: true)
      calculated = I.inventory_tree(@stock_root, allowed_stores: allowed_stores)
      recorded = load_json_file(File.join(@stock_root, 'capture_inventory.json'),
        max_bytes: MAX_MANIFEST_BYTES, label: 'stock capture inventory')
      require_true(recorded == calculated, 'stock raw capture inventory differs from fresh traversal')
      @stock_inventory = calculated
      parts_doc = load_json_file(File.join(@stock_root, 'part_inventories.json'),
        max_bytes: MAX_MANIFEST_BYTES, label: 'stock part inventory')
      @stock_part_records = parts_doc.fetch('parts')
      expected = CASES.map { |profile| profile.fetch('id') } + ['ordinary_json_control']
      require_true(@stock_part_records.map { |item| item.fetch('id') } == expected,
        'stock part inventory roster differs')
    end

    def validate_stock_profile(stock, generated, fixed)
      id = fixed.fetch('id')
      type = json_type(fixed)
      table = fixed.fetch('table')
      require_true(stock.fetch('table') == table && stock.fetch('declared_type') == type &&
        stock.fetch('status') == 'persisted_and_literal_rowbinary_matched' &&
        stock.fetch('failures') == [] && stock.fetch('check_matches_expected') == true,
        "stock persistence/type status is not a clean positive result for #{id}")
      expected_schema = schema_stdout(fixed)
      require_true(stock.fetch('schema_stdout') == expected_schema &&
        stock.fetch('nested_type_spelling_class') == 'nominal_custom_nested_name_preserved' &&
        stock.fetch('check_stdout') == "all_1_1_0\t1\t\n",
        "stock exact nominal schema or CHECK output differs for #{id}")
      require_true(stock.fetch('part_marks_expected') == PART_MARKS &&
        stock.fetch('part_type_expected') == 'Wide' && stock.fetch('row_keys') == ROW_IDS &&
        stock.fetch('rows_per_mark') == LIBRARY_MARK_ROWS,
        "stock row/mark shape differs for #{id}")

      relative = stock.fetch('part_path_relative')
      stock_part = safe_relative_path(@stock_root, relative, "stock part #{id}")
      require_true(File.expand_path(stock.fetch('part_path')) == stock_part &&
        File.directory?(stock_part) && !File.symlink?(stock_part) && File.realpath(stock_part) == stock_part,
        "stock part absolute/relative path is inconsistent for #{id}")
      fresh_stock_inventory = part_inventory(stock_part)
      part_record = @stock_part_records.find { |item| item.fetch('id') == id }
      require_true(part_record && part_record.fetch('part_path') == stock_part &&
        part_record.fetch('part_path_relative') == relative &&
        part_record.fetch('files') == fresh_stock_inventory &&
        stock.fetch('part_inventory_file_count') == fresh_stock_inventory.length,
        "stock part inventory differs from current files for #{id}")

      expected_ddl = "CREATE TABLE default.#{table} (id UInt64, j #{type}) " \
        "ENGINE=MergeTree ORDER BY id SETTINGS #{STOCK_SETTINGS.join(', ')}"
      require_true(generated.fetch('table') == table && generated.fetch('declared_type') == type &&
        generated.fetch('ddl') == expected_ddl && generated.fetch('schema_stdout') == expected_schema &&
        generated.fetch('nested_type_spelling_class') == 'nominal_custom_nested_name_preserved',
        "generated manifest DDL/schema/type differs from stock type for #{id}")
      independent_values = semantic_row_values(fixed)
      require_true(generated.fetch('row_values') == independent_values &&
        stock.fetch('row_values') == independent_values,
        "generated/stock row values differ from independently fixed literals for #{id}")
      shape = {
        'rows' => 6, 'library_mark_row_counts' => LIBRARY_MARK_ROWS,
        'library_data_mark_count' => 3, 'stock_system_parts_marks_count' => PART_MARKS,
        'part_type' => 'Wide',
      }
      require_true(generated.fetch('part_shape') == shape,
        "generated part shape conflates library mark groups with native system.parts marks for #{id}")

      stock_ref = generated.fetch('stock')
      require_true(stock_ref.fetch('part_path') == stock.fetch('part_path') &&
        stock_ref.fetch('part_path_relative') == relative &&
        stock_ref.fetch('part_capture') == stock.fetch('part_capture') &&
        stock_ref.fetch('check_capture') == stock.fetch('steps').fetch('check').fetch('capture_prefix') &&
        stock_ref.fetch('schema_capture') == stock.fetch('steps').fetch('schema').fetch('capture_prefix') &&
        stock_ref.fetch('check_stdout') == stock.fetch('check_stdout') &&
        stock_ref.fetch('schema_stdout') == stock.fetch('schema_stdout'),
        "generated stock cross-reference differs from fixed stock witness for #{id}")

      validate_stock_raw_step(stock, 'create', expected_ddl + "\n", expected_stdout: ''.b)
      validate_stock_raw_step(stock, 'schema', schema_sql(table) + "\n", expected_stdout: expected_schema.b)
      validate_stock_raw_step(stock, 'insert',
        "INSERT INTO default.#{table} SETTINGS input_format_binary_read_json_as_string=0 FORMAT RowBinary\n")
      validate_stock_raw_step(stock, 'check', check_sql(table) + "\n",
        expected_stdout: "all_1_1_0\t1\t\n".b)
      part_capture = validate_stock_raw_step(stock, 'part', part_sql(table) + "\n")
      fields = part_capture.fetch('stdout').force_encoding(Encoding::UTF_8).split("\t", -1)
      require_true(fields.length == 5 && fields[0, 4] == ['all_1_1_0', '6', PART_MARKS.to_s, 'Wide'] &&
        File.expand_path(fields.fetch(4).strip) == stock_part,
        "stock raw system.parts output differs from source part for #{id}")

      expected_windows = generated.fetch('expected_rowbinary')
      stock_windows = stock.fetch('rowbinary_windows')
      require_true(expected_windows.keys.sort == %w[empty full middle] &&
        stock_windows.keys.sort == %w[empty full middle],
        "generated/stock window set differs for #{id}")
      %w[full middle empty].each do |window|
        expected = expected_literal(fixed, window)
        expected_path = "literal_rowbinary/#{id}-#{window}-expected.rowbin"
        generated_window = expected_windows.fetch(window)
        require_true(generated_window.fetch('file') == expected_path &&
          generated_window.fetch('bytes') == expected.bytesize &&
          generated_window.fetch('sha256') == Digest::SHA256.hexdigest(expected),
          "generated expected RowBinary metadata differs from independent literal for #{id}/#{window}")
        require_true(File.binread(source_file(expected_path, "generated literal #{id}/#{window}")) == expected,
          "generated expected RowBinary file differs from independent literal for #{id}/#{window}")
        stock_window = stock_windows.fetch(window)
        require_true(stock_window.fetch('expected_literal') == expected_path &&
          stock_window.fetch('expected_bytes') == expected.bytesize &&
          stock_window.fetch('expected_sha256') == Digest::SHA256.hexdigest(expected) &&
          stock_window.fetch('matches_independent_literal') == true,
          "stock RowBinary metadata differs from independent literal for #{id}/#{window}")
        validate_stock_window(stock_window, fixed, window, expected)
      end

      generated_relative = "parts/#{id}"
      generated_root = File.join(@parts_root, generated_relative)
      require_true(generated.fetch('generated_part_path_relative') == generated_relative &&
        generated.fetch('generated_part_path') == generated_root &&
        File.directory?(generated_root) && !File.symlink?(generated_root) &&
        File.realpath(generated_root) == generated_root,
        "generated part path does not match fixed parts/<id> root for #{id}")
      inventory = part_inventory(generated_root)
      listed = generated.fetch('part_inventory')
      require_true(listed.is_a?(Array) &&
        listed.map { |item| item.fetch('path') } == listed.map { |item| item.fetch('path') }.sort &&
        listed == inventory,
        "generated part inventory differs from fresh bounded traversal for #{id}")
      tick = 0x60.chr
      columns = "columns format version: 1\n2 columns:\n#{tick}id#{tick} UInt64\n#{tick}j#{tick} #{type}\n".b
      require_true(File.binread(File.join(generated_root, 'columns.txt')) == columns,
        "generated columns.txt does not declare exact nominal Nested type for #{id}")
      @source_parts[id] = generated_root
      @source_inventories[id] = inventory
    rescue KeyError, TypeError => error
      fail!("stock/generated profile is malformed for #{id}: #{error.message}")
    end

    def validate_stock_raw_step(profile, name, expected_sql, expected_stdout: nil)
      summary = profile.fetch('steps').fetch(name)
      require_true(process_success?(summary),
        "stock #{name} process is not an exact success for #{profile.fetch('id')}")
      prefix = summary.fetch('capture_prefix')
      validate_stock_prefix!(prefix)
      base = File.join(@stock_root, prefix)
      require_true(File.binread(base + '.sql') == expected_sql.b,
        "stock raw SQL differs for #{profile.fetch('id')}/#{name}")
      argv_doc = load_json_file(base + '.argv.json', max_bytes: 128 * 1024,
        label: "stock argv #{profile.fetch('id')}/#{name}")
      argv = argv_doc.fetch('argv')
      query = expected_sql.end_with?("\n") ? expected_sql[0...-1] : expected_sql
      expected_argv = Q.clickhouse_argv(CLICKHOUSE_BIN,
        File.join(@stock_root, 'stores', profile.fetch('id')), query)
      require_true(argv == expected_argv &&
        argv_doc.fetch('timeout_seconds') == PROCESS_TIMEOUT_SECONDS &&
        argv_doc.fetch('environment') == { 'TZ' => 'UTC' },
        "stock raw argv differs from the exact fixed invocation for #{profile.fetch('id')}/#{name}")
      stdout = File.binread(base + '.stdout')
      stderr = File.binread(base + '.stderr')
      status = load_json_file(base + '.status.json', max_bytes: 128 * 1024,
        label: "stock status #{profile.fetch('id')}/#{name}")
      require_true(stdout.bytesize == summary.fetch('stdout_bytes') &&
        Digest::SHA256.hexdigest(stdout) == summary.fetch('stdout_sha256') &&
        stderr.bytesize == summary.fetch('stderr_bytes') &&
        Digest::SHA256.hexdigest(stderr) == summary.fetch('stderr_sha256'),
        "stock raw stdout/stderr differ from witness summary for #{profile.fetch('id')}/#{name}")
      %w[classification exitstatus signaled termsig timed_out spawn_error duration_ms stdout_bytes stderr_bytes].each do |key|
        require_true(status.fetch(key) == summary.fetch(key),
          "stock raw process status differs for #{profile.fetch('id')}/#{name}/#{key}")
      end
      require_true(stdout == expected_stdout, "stock substantive stdout differs for #{profile.fetch('id')}/#{name}") if expected_stdout
      if argv_doc['stdin_bytes']
        input = File.binread(base + '.stdin.bin')
        require_true(input.bytesize == argv_doc.fetch('stdin_bytes') &&
          Digest::SHA256.hexdigest(input) == argv_doc.fetch('stdin_sha256'),
          "stock input capture hash differs for #{profile.fetch('id')}/#{name}")
      end
      summary.merge('stdout' => stdout)
    rescue Errno::ENOENT, KeyError, TypeError => error
      fail!("stock raw capture is incomplete for #{profile.fetch('id')}/#{name}: #{error.message}")
    end

    def validate_stock_prefix!(prefix)
      require_true(prefix.is_a?(String) &&
        /\Ainvocations\/[0-9]{4}-[a-z0-9][a-z0-9_-]*\z/.match?(prefix),
        "stock capture prefix is malformed: #{prefix.inspect}")
      safe_relative_path(@stock_root, prefix, 'stock invocation prefix')
    end

    def validate_stock_window(stock_window, fixed, window, expected)
      process = stock_window.fetch('process')
      require_true(process_success?(process), "stock RowBinary process failed for #{fixed.fetch('id')}/#{window}")
      prefix = stock_window.fetch('capture_prefix')
      require_true(prefix == process.fetch('capture_prefix'), 'stock window capture references disagree')
      validate_stock_prefix!(prefix)
      base = File.join(@stock_root, prefix)
      sql = window_sql(fixed.fetch('table'), window) + "\n"
      require_true(File.binread(base + '.sql') == sql.b,
        "stock RowBinary SQL differs for #{fixed.fetch('id')}/#{window}")
      argv_doc = load_json_file(base + '.argv.json', max_bytes: 128 * 1024,
        label: "stock RowBinary argv #{fixed.fetch('id')}/#{window}")
      expected_argv = Q.clickhouse_argv(CLICKHOUSE_BIN,
        File.join(@stock_root, 'stores', fixed.fetch('id')),
        window_sql(fixed.fetch('table'), window))
      require_true(argv_doc.fetch('argv') == expected_argv &&
        argv_doc.fetch('timeout_seconds') == PROCESS_TIMEOUT_SECONDS &&
        argv_doc.fetch('environment') == { 'TZ' => 'UTC' },
        "stock RowBinary raw argv differs from fixed invocation for #{fixed.fetch('id')}/#{window}")
      stdout = File.binread(base + '.stdout')
      stderr = File.binread(base + '.stderr')
      require_true(stdout == expected && stdout.bytesize == process.fetch('stdout_bytes') &&
        Digest::SHA256.hexdigest(stdout) == process.fetch('stdout_sha256') &&
        stderr.bytesize == process.fetch('stderr_bytes') &&
        Digest::SHA256.hexdigest(stderr) == process.fetch('stderr_sha256'),
        "stock RowBinary raw output differs from independent literal for #{fixed.fetch('id')}/#{window}")
      status = load_json_file(base + '.status.json', max_bytes: 128 * 1024,
        label: "stock RowBinary status #{fixed.fetch('id')}/#{window}")
      %w[classification exitstatus signaled termsig timed_out spawn_error duration_ms stdout_bytes stderr_bytes].each do |key|
        require_true(status.fetch(key) == process.fetch(key),
          "stock RowBinary raw status differs for #{fixed.fetch('id')}/#{window}/#{key}")
      end
      stock_expected = safe_relative_path(@stock_root, stock_window.fetch('expected_literal'),
        'stock expected RowBinary path')
      require_true(File.file?(stock_expected) && !File.symlink?(stock_expected) &&
        File.binread(stock_expected) == expected,
        "stock expected RowBinary file differs from independent literal for #{fixed.fetch('id')}/#{window}")
    rescue Errno::ENOENT, KeyError, TypeError => error
      fail!("stock RowBinary capture is incomplete for #{fixed.fetch('id')}/#{window}: #{error.message}")
    end

    def pin_runtime
      store = @stores.fetch(CASES.first.fetch('id'))
      version = invoke('runtime-version-pin', store, 'SELECT version() FORMAT TSVRaw')
      @global_steps['runtime_version'] = process_summary(version)
      require_child_success!(version, 'runtime version pin')
      require_true(version.fetch('stdout') == "#{CLICKHOUSE_VERSION}\n",
        'native runtime version output differs from fixed pin')
      sql = "SELECT concat(name, '=', value) FROM system.build_options " \
        "WHERE name='VERSION_GITHASH' FORMAT TSVRaw"
      build = invoke('runtime-build-pin', store, sql)
      @global_steps['runtime_build'] = process_summary(build)
      require_child_success!(build, 'runtime build pin')
      require_true(build.fetch('stdout') == "VERSION_GITHASH=#{CLICKHOUSE_BUILD}\n",
        'native runtime build hash output differs from fixed pin')
      @runtime_pin = {
        'path' => @binary, 'sha256' => CLICKHOUSE_SHA256, 'version' => CLICKHOUSE_VERSION,
        'build_hash' => CLICKHOUSE_BUILD,
        'source_revision_is_separately_pinned_not_asserted_as_runtime_lineage' => true,
        'version_capture' => @global_steps.fetch('runtime_version').fetch('capture_prefix'),
        'build_capture' => @global_steps.fetch('runtime_build').fetch('capture_prefix'),
      }
    end

    def invoke(label, store, sql)
      require_true(@recorder.records.length < MAX_PROCESS_COUNT,
        'fixed W236 native child-process cap exceeded')
      argv = Q.clickhouse_argv(@binary, store, sql)
      require_true(argv.include?("--max_execution_time=#{MAX_EXECUTION_SECONDS}") &&
        argv.include?("--max_memory_usage=#{MEMORY_LIMIT_BYTES}"),
        'reused W233 argv builder no longer supplies W236 execution/memory bounds')
      @recorder.run(label, store, sql, timeout: PROCESS_TIMEOUT_SECONDS, argv: argv)
    end

    def require_child_success!(record, label)
      require_true(process_success?(record),
        "#{label} did not exit with exact success fields (#{failure_kind(record)}); raw capture preserved at #{record.fetch('path')}")
    end

    def record_step(profile_record, name, process)
      profile_record.fetch('steps')[name] = process_summary(process)
      require_child_success!(process, "#{profile_record.fetch('id')}/#{name}")
      process
    end

    def run_profile(profile)
      id = profile.fetch('id')
      record = {
        'id' => id, 'table' => profile.fetch('table'),
        'declared_type' => json_type(profile), 'ddl' => create_sql(profile),
        'expected_schema' => schema_stdout(profile),
        'library_part_path' => @source_parts.fetch(id),
        'library_inventory' => @source_inventories.fetch(id),
        'steps' => {}, 'rowbinary_windows' => {}, 'failures' => [],
        'status' => 'in_progress',
      }
      @profile_records << record
      store = @stores.fetch(id)
      record_step(record, 'create', invoke("#{id}-create", store, create_sql(profile)))

      before = record_step(record, 'pre-attach-schema-and-data-path',
        invoke("#{id}-pre-attach-schema-and-data-path", store, before_attach_sql(profile.fetch('table'))))
      _pre_schema, data_path = parse_before_attach(before.fetch('stdout'), profile)
      record['data_path'] = data_path
      detached_dir = File.join(data_path, 'detached')
      require_true(File.directory?(detached_dir) && !File.symlink?(detached_dir) &&
        File.realpath(detached_dir) == detached_dir,
        "native detached directory is absent/noncanonical for #{id}")
      detached_part = File.join(detached_dir, 'all_1_1_0')
      require_true(!File.exist?(detached_part) && !File.symlink?(detached_part),
        "native detached destination is not fresh for #{id}")

      source_part = @source_parts.fetch(id)
      require_true(part_inventory(source_part) == @source_inventories.fetch(id),
        "generated source part changed after preflight for #{id}")
      FileUtils.cp_r(source_part, detached_part)
      copied = part_inventory(detached_part)
      require_true(copied == @source_inventories.fetch(id),
        "exact copied part differs from validated generated part for #{id}")
      record['detached_part_path'] = detached_part
      record['copied_part_inventory'] = copied

      record_step(record, 'attach', invoke("#{id}-attach", store,
        "ALTER TABLE default.#{profile.fetch('table')} ATTACH PART 'all_1_1_0'"))
      check = record_step(record, 'check', invoke("#{id}-check", store, check_sql(profile.fetch('table'))))
      record['check_stdout'] = check.fetch('stdout').dup.force_encoding(Encoding::UTF_8).scrub
      require_true(check.fetch('stdout') == "all_1_1_0\t1\t\n", "native CHECK output differs for #{id}")

      after = record_step(record, 'post-attach-schema-and-part',
        invoke("#{id}-post-attach-schema-and-part", store, after_attach_sql(profile.fetch('table'))))
      post_schema, part_fields = parse_after_attach(after.fetch('stdout'), profile)
      record['schema_stdout'] = post_schema
      require_true(post_schema == schema_stdout(profile), "native exact schema differs after ATTACH for #{id}")
      record['part_stdout_fields'] = part_fields
      expected_path = File.join(data_path, 'all_1_1_0')
      observed_path = File.expand_path(part_fields.fetch(4).strip)
      require_true(part_fields[0, 4] == ['all_1_1_0', '6', PART_MARKS.to_s, 'Wide'] &&
        observed_path == expected_path && File.directory?(expected_path) &&
        !File.symlink?(expected_path) && File.realpath(expected_path) == expected_path,
        "native system.parts row/type/marks/path differs for #{id}")
      record['attached_part_path'] = expected_path
      validate_attached_inventory(record, profile)

      %w[full middle empty].each do |window|
        expected = expected_literal(profile, window)
        output = record_step(record, "rowbinary-#{window}",
          invoke("#{id}-rowbinary-#{window}", store, window_sql(profile.fetch('table'), window)))
        matches = output.fetch('stdout') == expected
        expected_relative = "literal_rowbinary/#{id}-#{window}-expected.rowbin"
        expected_path = File.join(@root, expected_relative)
        R.write_new(expected_path, expected)
        record.fetch('rowbinary_windows')[window] = {
          'expected_literal' => expected_relative,
          'expected_bytes' => expected.bytesize,
          'expected_sha256' => Digest::SHA256.hexdigest(expected),
          'capture_prefix' => "invocations/#{File.basename(output.fetch('path'))}",
          'process' => process_summary(output),
          'matches_independent_literal' => matches,
        }
        require_true(matches, "native #{window} RowBinary differs from independent literal for #{id}")
      end
      record['status'] = 'attached_checked_and_all_literal_windows_matched'
    rescue StandardError => error
      if record
        record.fetch('failures') << { 'error' => "#{error.class}: #{error.message}" }
        record['status'] = 'native_or_plumbing_failure'
      end
      raise
    end

    def parse_before_attach(stdout, profile)
      lines = stdout.dup.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      schema_rows = lines.select { |line| line.start_with?('__W236_SCHEMA__') }
      data_rows = lines.select { |line| line.start_with?('__W236_DATA_PATH__') }
      require_true(lines.length == 3 && schema_rows.length == 2 && data_rows.length == 1,
        "pre-ATTACH schema/data-path query returned unexpected lines for #{profile.fetch('id')}")
      schema = schema_rows.map { |line| line.delete_prefix('__W236_SCHEMA__') }.join("\n") + "\n"
      require_true(schema == schema_stdout(profile), "native exact schema differs before ATTACH for #{profile.fetch('id')}")
      raw_path = data_rows.first.delete_prefix('__W236_DATA_PATH__')
      require_true(!raw_path.empty? && !raw_path.include?("\n"), "native data path is malformed for #{profile.fetch('id')}")
      path = File.expand_path(raw_path)
      store = @stores.fetch(profile.fetch('id'))
      require_true(path.start_with?(store + File::SEPARATOR) && File.directory?(path) &&
        !File.symlink?(path) && File.realpath(path) == path,
        "native data path escaped isolated store for #{profile.fetch('id')}")
      [schema, path]
    end

    def parse_after_attach(stdout, profile)
      lines = stdout.dup.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      schema_rows = lines.select { |line| line.start_with?('__W236_SCHEMA__') }
      part_rows = lines.select { |line| line.start_with?('__W236_PART__') }
      require_true(lines.length == 3 && schema_rows.length == 2 && part_rows.length == 1,
        "post-ATTACH schema/part query returned unexpected lines for #{profile.fetch('id')}")
      schema = schema_rows.map { |line| line.delete_prefix('__W236_SCHEMA__') }.join("\n") + "\n"
      fields = part_rows.first.delete_prefix('__W236_PART__').split("\t", -1)
      require_true(fields.length == 5 && schema == schema_stdout(profile),
        "post-ATTACH exact schema or part row is malformed for #{profile.fetch('id')}")
      [schema, fields]
    end

    def validate_attached_inventory(record, profile)
      id = profile.fetch('id')
      source = @source_inventories.fetch(id)
      attached = part_inventory(record.fetch('attached_part_path'))
      source_by_path = source.to_h { |item| [item.fetch('path'), item] }
      attached_by_path = attached.to_h { |item| [item.fetch('path'), item] }
      removed = (source_by_path.keys - attached_by_path.keys).sort
      changed = source_by_path.keys.select do |path|
        attached_by_path.key?(path) && source_by_path.fetch(path) != attached_by_path.fetch(path)
      end.sort
      added = (attached_by_path.keys - source_by_path.keys).sort
      require_true(removed.empty? && changed.empty? &&
        [[], ['invalidated_system_columns.txt']].include?(added),
        "native ATTACH changed the library part outside the optional invalidated columns file for #{id}")
      if added == ['invalidated_system_columns.txt']
        contents = File.binread(File.join(record.fetch('attached_part_path'), 'invalidated_system_columns.txt'))
        # IMergeTreeDataPart writes a NameSet (unordered_set), not an ordered
        # column roster. Admit only the two exact permutations of that set.
        require_true(["_block_number\n_block_offset\n", "_block_offset\n_block_number\n"].include?(contents),
          "native invalidated columns contents differ for #{id}")
      end
      tick = 0x60.chr
      expected_columns = "columns format version: 1\n2 columns:\n#{tick}id#{tick} UInt64\n#{tick}j#{tick} #{json_type(profile)}\n".b
      require_true(File.binread(File.join(record.fetch('attached_part_path'), 'columns.txt')) == expected_columns,
        "native attached columns metadata differs for #{id}")
      record['attached_part_inventory'] = attached
      record['attached_part_added_files'] = added
      record['attached_part_removed_files'] = removed
      record['attached_part_changed_files'] = changed
    end

    def save_evidence
      return unless File.directory?(@root) && File.directory?(File.join(@root, 'invocations')) &&
        File.directory?(File.join(@root, 'stores'))
      witness_path = File.join(@root, 'object_declared_nested_parts_consumer_w236.json')
      unless File.exist?(witness_path)
        witness = {
          'format' => 'object_declared_nested_parts_consumer_w236_v1',
          'source_reference' => "#{SOURCE_ROOT}@#{SOURCE_REVISION}",
          'runtime' => @runtime_pin,
          'parts_root' => @parts_root,
          'parts_manifest_sha256' => @manifest_sha256,
          'stock_root' => @stock_root,
          'stock_capture_inventory' => @stock_inventory,
          'settings' => STOCK_SETTINGS,
          'profiles' => @profile_records,
          'global_steps' => @global_steps,
          'process_count' => @recorder.records.length,
          'process_cap' => MAX_PROCESS_COUNT,
          'expected_process_count' => EXPECTED_PROCESS_COUNT,
          'process_timeout_seconds' => PROCESS_TIMEOUT_SECONDS,
          'max_execution_time_seconds' => MAX_EXECUTION_SECONDS,
          'max_memory_usage_bytes' => MEMORY_LIMIT_BYTES,
          'fatal_error' => @fatal_error,
          'scope' => 'Five stock-pinned JSON(q Nested(...)) declarations, direct or recursively wrapped by Array, Tuple, Map, or Variant; each generated Wide part is attached in an isolated native store, checked, and read through independent full, middle, and empty RowBinary literals.',
          'limitations' => [
            'The generated manifest and expected RowBinary files are checked for consistency but are not the consumer oracle.',
            'The stock witness is read-only and is cross-checked against raw invocation captures and a fresh part inventory.',
            'Library mark row groups [2,2,2] and stock system.parts marks=4 are distinct quantities.',
            'Nonzero exit, signal, timeout, spawn failure, malformed output, or missing profile makes the result inconclusive.',
            'A successful native consumer does not alone admit production runtime-owner types or projection behavior.',
          ],
        }
        R.write_new(witness_path, JSON.pretty_generate(witness) + "\n")
      end
      allowed_stores = CASES.to_h do |profile|
        [File.realpath(@stores.fetch(profile.fetch('id'))), profile.fetch('table')]
      end
      bounded_tree!(@root, allow_symlinks: true)
      inventory = I.inventory_tree(@root, allowed_stores: allowed_stores)
      path = File.join(@root, 'capture_inventory.json')
      R.write_new(path, JSON.pretty_generate(inventory) + "\n") unless File.exist?(path)
    end
  end

  def main(argv)
    options = { clickhouse: CLICKHOUSE_BIN }
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/recheck_object_declared_nested_parts_w236.rb --parts-root ROOT --capture-root EMPTY_DIR [--clickhouse PINNED_BIN]'
      opts.on('--parts-root PATH') { |value| options[:parts_root] = value }
      opts.on('--capture-root PATH') { |value| options[:capture_root] = value }
      opts.on('--clickhouse PATH') { |value| options[:clickhouse] = value }
    end
    parser.parse!(argv)
    require_true(argv.empty? && %i[parts_root capture_root].all? { |key| options.key?(key) }, parser.to_s)
    Probe.new(options).run
  rescue StandardError => error
    warn "W236 generated-part consumer setup failed: #{error.class}: #{error.message}"
    false
  end
end

exit(RecheckObjectDeclaredNestedPartsW236.main(ARGV) ? 0 : 1) if $PROGRAM_NAME == __FILE__
