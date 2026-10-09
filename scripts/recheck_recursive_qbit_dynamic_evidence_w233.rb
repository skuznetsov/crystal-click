#!/usr/bin/env ruby
# Paired public-library and native ATTACH evidence for the fixed W233 stock
# Dynamic(QBit-product) parts. Stock creation is audited from the prior capture;
# this runner does not rewrite or mutate the stock store.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require_relative 'recheck_aggregate_recursive_w224'

module RecheckRecursiveQBitDynamicEvidenceW233
  extend self

  R = RecheckAggregateRecursiveW224
  REPO_ROOT = '/Users/sergey/Projects/Crystal/crystal-click'.freeze
  SOURCE_ROOT = '/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1'.freeze
  SOURCE_REVISION = '0ca8150d9b1d0886edb2e3b4ab65eebb768d0357'.freeze
  CLICKHOUSE_BIN = '/private/tmp/crystal-click-w216-runtime-recovery.DmL9Kw/clickhouse-stripped'.freeze
  CLICKHOUSE_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  CLICKHOUSE_VERSION = '26.10.1.1201'.freeze
  CLICKHOUSE_BUILD = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  STOCK_PREFIX = 'crystal-click-w233-stock.'.freeze
  EVIDENCE_PREFIX = 'crystal-click-w233-evidence.'.freeze
  HELPER_INPUT_FORMAT = 'recursive_qbit_dynamic_w233_helper_input_v1'.freeze
  HELPER_OUTPUT_FORMAT = 'recursive_qbit_dynamic_w233_helper_output_v1'.freeze
  RESULT_FORMAT = 'recursive_qbit_dynamic_w233_evidence_v1'.freeze
  PROFILE_IDS = %w[root_dynamic carrier_dynamic shared_dynamic].freeze
  PROFILES = [
    { 'id' => 'root_dynamic', 'column' => 'root_d', 'type' => 'Dynamic(max_types=4)' },
    { 'id' => 'carrier_dynamic', 'column' => 'carrier', 'type' => 'Array(Dynamic(max_types=4))' },
    { 'id' => 'shared_dynamic', 'column' => 'shared_d', 'type' => 'Dynamic(max_types=0)' },
  ].freeze
  ROW_KEYS = [1, 2, 3, 4, 5, 6].freeze
  MARK_ROWS = [2, 2, 2].freeze
  SYSTEM_MARKS = 4
  STOCK_LABELS = %w[
    runtime-version runtime-build create insert-rowbinary cast-map-diagnostic check schema
    root-roster carrier-roster part rowbinary-full rowbinary-middle rowbinary-zero
  ].freeze
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
  MEMORY_LIMIT_BYTES = 1_073_741_824
  PROCESS_TIMEOUT_SECONDS = 90
  HELPER_TIMEOUT_SECONDS = 600
  MAX_PROCESSES = 40
  MAX_FILES = 4096
  MAX_TOTAL_BYTES = 64 * 1024 * 1024
  MAX_TREE_ENTRIES = 4096
  MAX_TREE_BYTES = 64 * 1024 * 1024
  INVALIDATED_FILE = 'invalidated_system_columns.txt'.freeze
  INVALIDATED_NAMES = %w[_block_number _block_offset].freeze

  # Literal Dynamic actual values; these include the DataTypesBinaryEncoding
  # descriptor and QBit payload, independent of Crystal BinaryValue encoding.
  ROOT_VALUE_HEX = [
    '1e36070900',
    '1e3607090109010203040506070809',
    '20020171360709016e0109ff000102040810204007',
    '271536070901016109090807060504030201',
    '1e2a0236070904010009020406080a0c0e1012',
    '00',
  ].freeze

  def assert!(condition, message)
    raise ArgumentError, "W233 evidence setup failed: #{message}" unless condition
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
    assert!(false, "refusing to reuse directory: #{path}")
  end

  def plain_file!(path, label, executable: false)
    full = File.expand_path(path)
    assert!(File.file?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "#{label} is absent, symlinked, or noncanonical: #{full}")
    assert!(!executable || File.executable?(full), "#{label} is not executable")
    full
  end

  def plain_dir!(path, label)
    full = File.expand_path(path)
    assert!(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "#{label} is absent, symlinked, or noncanonical: #{full}")
    full
  end

  def validate_empty_root(path, prefix, label)
    full = plain_dir!(path, label)
    assert!(File.dirname(full) == File.realpath('/private/tmp') && File.basename(full).start_with?(prefix),
      "#{label} must be a direct bounded /private/tmp child named #{prefix}*")
    assert!(Dir.children(full).empty?, "#{label} must be fresh and empty")
    full
  end

  def validate_stock_root(path)
    full = plain_dir!(path, 'stock capture root')
    assert!(File.dirname(full) == File.realpath('/private/tmp') && File.basename(full).start_with?(STOCK_PREFIX),
      'stock capture must be a direct bounded /private/tmp child')
    full
  end

  def uint64(value)
    Array.new(8) { |index| (value >> (index * 8)) & 0xff }.pack('C*').b
  end

  def root_values
    ROOT_VALUE_HEX.map { |hex| [hex].pack('H*').b }
  end

  def carrier_values
    root_values.each_with_index.map { |value, index| index.zero? ? "\x00".b : "\x01".b + value }
  end

  def expected_value_hex(profile)
    values = profile.fetch('id') == 'carrier_dynamic' ? carrier_values : root_values
    values.map { |value| value.unpack1('H*') }
  end

  def stock_output_rows
    roots = root_values
    carriers = carrier_values
    ROW_KEYS.each_index.map do |index|
      uint64(ROW_KEYS.fetch(index)) + roots.fetch(index) + roots.fetch(index) + carriers.fetch(index)
    end
  end

  def stock_input_rows
    roots = root_values
    carriers = carrier_values
    ROW_KEYS.each_index.map do |index|
      uint64(ROW_KEYS.fetch(index)) + roots.fetch(index) + carriers.fetch(index) + roots.fetch(index)
    end
  end

  def window_indexes(window)
    { 'full' => (0...ROW_KEYS.length).to_a, 'middle' => [2, 3], 'zero' => [] }.fetch(window)
  end

  def expected_bytes(rows, window)
    window_indexes(window).map { |index| rows.fetch(index) }.join.b
  end

  def raw_record(root, label, sequence)
    stem = format('%04d-%s', sequence, label)
    base = File.join(root, 'invocations', stem)
    status_path = base + '.status.json'
    assert!(File.file?(status_path) && !File.symlink?(status_path), "missing raw status for #{label}")
    status = JSON.parse(File.binread(status_path).force_encoding(Encoding::UTF_8))
    argv = JSON.parse(File.binread(base + '.argv.json').force_encoding(Encoding::UTF_8))
    sql = File.binread(base + '.sql')
    stdout = File.binread(base + '.stdout')
    stderr = File.binread(base + '.stderr')
    assert!(argv.fetch('label') == label && status.fetch('label') == label, "raw label differs for #{label}")
    success = status.fetch('classification') == 'process_success' && status.fetch('exitstatus') == 0 &&
      status.fetch('signaled') == false && status.fetch('timed_out') == false && status.fetch('spawn_error').nil?
    assert!(success, "raw process status is not success for #{label}")
    assert!(status.fetch('stdout_bytes') == stdout.bytesize && status.fetch('stderr_bytes') == stderr.bytesize,
      "raw byte census differs for #{label}")
    { 'base' => base, 'label' => label, 'status' => status, 'argv' => argv, 'sql' => sql,
      'stdout' => stdout, 'stderr' => stderr }
  rescue JSON::ParserError, KeyError => error
    raise ArgumentError, "W233 raw invocation malformed for #{label}: #{error.message}"
  end

  def tsv_row!(bytes, count, label)
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    assert!(text.valid_encoding?, "#{label} is not UTF-8 TSV")
    lines = text.lines.map { |line| line.chomp.sub(/\r\z/, '') }
    assert!(lines.length == 1, "#{label} expected exactly one line")
    fields = lines.first.split("\t", -1)
    assert!(fields.length == count, "#{label} TSV field count differs")
    fields
  end

  def inventory(path)
    root = plain_dir!(path, 'part directory')
    files = []
    count = 0
    bytes = 0
    Find.find(root) do |entry|
      next if entry == root
      count += 1
      assert!(count <= MAX_TREE_ENTRIES && !File.symlink?(entry), 'part inventory exceeded bound or has symlink')
      next if File.directory?(entry)
      assert!(File.file?(entry), 'part contains unsupported entry')
      bytes += File.size(entry)
      assert!(bytes <= MAX_TREE_BYTES, 'part inventory exceeded byte cap')
      files << { 'path' => entry[(root.length + 1)..-1], 'size' => File.size(entry), 'sha256' => sha256_file(entry) }
    end
    files.sort_by { |entry| entry.fetch('path') }
  end

  def validate_atomic_directory_alias!(root, entry)
    relative = entry[(root.length + 1)..-1]
    local_store_root = nil
    target_depth = nil

    case relative
    when 'store/metadata/default'
      assert!(File.basename(root).start_with?(STOCK_PREFIX), 'stock metadata alias appeared outside stock root')
      local_store_root = File.join(root, 'store')
      target_depth = 1
    when 'store/data/default/w233_recursive_qbit_dynamic'
      assert!(File.basename(root).start_with?(STOCK_PREFIX), 'stock table alias appeared outside stock root')
      local_store_root = File.join(root, 'store')
      target_depth = 2
    else
      if (match = /\Astores\/(pins|root_dynamic|carrier_dynamic|shared_dynamic)\/metadata\/default\z/.match(relative))
        assert!(File.basename(root).start_with?(EVIDENCE_PREFIX), 'paired metadata alias appeared outside evidence root')
        local_store_root = File.join(root, 'stores', match[1])
        target_depth = 1
      elsif (match = /\Astores\/(root_dynamic|carrier_dynamic|shared_dynamic)\/data\/default\/w233_native_(root_dynamic|carrier_dynamic|shared_dynamic)\z/.match(relative))
        assert!(File.basename(root).start_with?(EVIDENCE_PREFIX), 'paired table alias appeared outside evidence root')
        assert!(match[1] == match[2], 'paired table alias profile differs from its isolated store')
        local_store_root = File.join(root, 'stores', match[1])
        target_depth = 2
      else
        assert!(false, "unsupported capture symlink: #{entry}")
      end
    end

    link_target = File.readlink(entry)
    target_pattern = if target_depth == 1
                       /\A\.\.\/store\/([0-9a-f]{3})\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\z/
                     else
                       /\A\.\.\/\.\.\/store\/([0-9a-f]{3})\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\z/
                     end
    target_match = target_pattern.match(link_target)
    assert!(target_match, "Atomic directory alias target grammar differs: #{entry}")
    fanout = target_match[1]
    uuid = target_match[2]
    assert!(fanout == uuid[0, 3], "Atomic directory alias fanout differs from UUID: #{entry}")

    physical_store = File.join(local_store_root, 'store')
    fanout_dir = File.join(physical_store, fanout)
    resolved_target = File.join(fanout_dir, uuid)
    assert!(File.expand_path(link_target, File.dirname(entry)) == resolved_target,
      "Atomic directory alias escapes its isolated store: #{entry}")
    [local_store_root, physical_store, fanout_dir, resolved_target].each do |directory|
      assert!(File.directory?(directory) && !File.symlink?(directory) && File.realpath(directory) == directory,
        "Atomic directory alias target is missing, non-directory, or chained: #{directory}")
    end
    assert!(File.directory?(entry) && File.realpath(entry) == resolved_target,
      "Atomic directory alias does not resolve to its canonical local directory: #{entry}")
  end

  def root_inventory(path, ignored: [])
    root = plain_dir!(path, 'capture root')
    files = []
    count = 0
    bytes = 0
    Find.find(root) do |entry|
      next if entry == root
      if File.symlink?(entry)
        validate_atomic_directory_alias!(root, entry)
        Find.prune
        next
      end
      next if File.directory?(entry)
      assert!(File.file?(entry), "unsupported capture file: #{entry}")
      count += 1
      bytes += File.size(entry)
      assert!(count <= MAX_FILES && bytes <= MAX_TOTAL_BYTES, 'capture exceeded file/byte bound')
      next if ignored.include?(File.basename(entry))
      files << { 'path' => entry[(root.length + 1)..-1], 'size' => File.size(entry), 'sha256' => sha256_file(entry) }
    end
    files.sort_by { |entry| entry.fetch('path') }
  end

  def verify_stock!(root)
    expected_labels = STOCK_LABELS.each_with_index.to_h { |label, index| [label, index + 1] }
    records = expected_labels.to_h { |label, sequence| [label, raw_record(root, label, sequence)] }
    expected_schema = "id\tUInt64\nroot_d\tDynamic(max_types=4)\ncarrier\tArray(Dynamic(max_types=4))\nshared_d\tDynamic(max_types=0)\n"
    assert!(records.fetch('check').fetch('stdout') == "all_1_1_0\t1\t\n", 'stock raw CHECK output differs')
    assert!(records.fetch('schema').fetch('stdout') == expected_schema, 'stock declared schema differs')
    expected_roster = [
      "1\tArray(QBit(Int8, 9))\t0\tArray(QBit(Int8, 9))\t1",
      "2\tArray(QBit(Int8, 9))\t0\tArray(QBit(Int8, 9))\t1",
      "3\tTuple(q QBit(Int8, 9), n UInt8)\t0\tTuple(q QBit(Int8, 9), n UInt8)\t1",
      "4\tMap(String, QBit(Int8, 9))\t0\tMap(String, QBit(Int8, 9))\t1",
      "5\tArray(Variant(QBit(Int8, 9), UInt64))\t0\tArray(Variant(QBit(Int8, 9), UInt64))\t1",
      "6\tNULL\t-\tNULL\t-",
    ].join("\n") + "\n"
    assert!(records.fetch('root-roster').fetch('stdout') == expected_roster, 'stock ordinary/shared roster differs')
    expected_carrier = [
      "1\t", "2\tArray(QBit(Int8, 9)):0", "3\tTuple(q QBit(Int8, 9), n UInt8):0",
      "4\tMap(String, QBit(Int8, 9)):0", "5\tArray(Variant(QBit(Int8, 9), UInt64)):0", "6\tNULL",
    ].join("\n") + "\n"
    assert!(records.fetch('carrier-roster').fetch('stdout') == expected_carrier, 'stock Array(Dynamic) roster differs')
    insert = records.fetch('insert-rowbinary')
    insert_literal = File.binread(File.join(root, 'literal_rowbinary', 'insert-schema-order.rowbin'))
    expected_insert = stock_input_rows.join.b
    assert!(insert_literal == expected_insert && File.binread(insert.fetch('base') + '.stdin.bin') == expected_insert,
      'stock independent RowBinary INSERT differs')
    %w[full middle zero].each do |window|
      record = records.fetch("rowbinary-#{window}")
      assert!(record.fetch('stdout') == expected_bytes(stock_output_rows, window),
        "stock #{window} raw RowBinary differs from literal values")
      expected_literal = expected_bytes(stock_output_rows, window)
      actual_literal = File.binread(File.join(root, 'literal_rowbinary', "#{window}.rowbin"))
      assert!(actual_literal == expected_literal, "stock #{window} literal file differs")
    end
    fields = tsv_row!(records.fetch('part').fetch('stdout'), 5, 'stock Wide part')
    assert!(fields[0, 4] == ['all_1_1_0', '6', SYSTEM_MARKS.to_s, 'Wide'], 'stock part grid differs')
    part = File.expand_path(fields.fetch(4))
    store = File.join(root, 'store')
    assert!(part.start_with?(store + File::SEPARATOR), 'stock part path escaped its isolated store')
    actual_part_inventory = inventory(part)
    expected_inventory = JSON.parse(File.binread(File.join(root, 'part_inventory.json')).force_encoding(Encoding::UTF_8))
    assert!(expected_inventory.fetch('part_path') == part && expected_inventory.fetch('files') == actual_part_inventory,
      'stock captured part inventory differs from actual part bytes')
    root_files = root_inventory(root, ignored: ['capture_inventory.json'])
    recorded_inventory = JSON.parse(File.binread(File.join(root, 'capture_inventory.json')).force_encoding(Encoding::UTF_8))
    assert!(recorded_inventory.fetch('files') == root_files, 'stock raw capture inventory differs')
    { 'records' => records, 'part_path' => part, 'part_inventory' => actual_part_inventory,
      'capture_inventory' => root_files }
  rescue JSON::ParserError, KeyError => error
    raise ArgumentError, "W233 stock capture malformed: #{error.message}"
  end

  def clickhouse_argv(binary, store, sql)
    [binary, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
      '--max_insert_threads=1', '--max_execution_time=30', "--max_memory_usage=#{MEMORY_LIMIT_BYTES}",
      '--print_pretty_type_names=0', '--flatten_nested=0', '--multiquery', '--query', sql]
  end

  class Probe
    def initialize(options)
      @binary = RecheckRecursiveQBitDynamicEvidenceW233.plain_file!(options.fetch(:clickhouse), 'runtime binary', executable: true)
      assert_runtime_pin!
      @helper = RecheckRecursiveQBitDynamicEvidenceW233.plain_file!(options.fetch(:helper), 'prebuilt helper', executable: true)
      @helper_sha = options.fetch(:helper_sha256)
      RecheckRecursiveQBitDynamicEvidenceW233.assert!(/\A[0-9a-f]{64}\z/.match?(@helper_sha), 'helper SHA must be fixed lowercase hex')
      RecheckRecursiveQBitDynamicEvidenceW233.assert!(RecheckRecursiveQBitDynamicEvidenceW233.sha256_file(@helper) == @helper_sha,
        'prebuilt helper differs from CLI SHA pin')
      @helper_sha_at_start = @helper_sha
      @stock_root = RecheckRecursiveQBitDynamicEvidenceW233.validate_stock_root(options.fetch(:stock_root))
      @evidence_root = RecheckRecursiveQBitDynamicEvidenceW233.validate_empty_root(
        options.fetch(:evidence_root), EVIDENCE_PREFIX, 'evidence root')
      @recorder = R::Recorder.new(@evidence_root, @binary)
      @stock = RecheckRecursiveQBitDynamicEvidenceW233.verify_stock!(@stock_root)
      @helper_output = nil
      @helper_input_sha = nil
      @library_inventories = {}
      @native_records = []
    end

    def assert_runtime_pin!
      RecheckRecursiveQBitDynamicEvidenceW233.assert!(@binary == CLICKHOUSE_BIN &&
        RecheckRecursiveQBitDynamicEvidenceW233.sha256_file(@binary) == CLICKHOUSE_SHA256,
        'ClickHouse runtime differs from fixed path/SHA pin')
    end

    def write_json(path, value)
      RecheckRecursiveQBitDynamicEvidenceW233.write_json(path, value)
    end

    def run_clickhouse(label, store, sql)
      assert_process_budget!
      record = @recorder.run(label, store, sql, timeout: PROCESS_TIMEOUT_SECONDS,
        argv: RecheckRecursiveQBitDynamicEvidenceW233.clickhouse_argv(@binary, store, sql))
      process_success!(record, label)
    end

    def process_success!(record, label)
      ok = record.fetch('classification') == 'process_success' && record.fetch('exitstatus') == 0 &&
        !record.fetch('signaled') && !record.fetch('timed_out') && record.fetch('spawn_error').nil?
      RecheckRecursiveQBitDynamicEvidenceW233.assert!(ok, "#{label} did not exit successfully")
      record
    end

    def assert_process_budget!
      RecheckRecursiveQBitDynamicEvidenceW233.assert!(@recorder.records.length < MAX_PROCESSES,
        'W233 fixed evidence process cap exceeded')
    end

    def check_budget!
      RecheckRecursiveQBitDynamicEvidenceW233.root_inventory(@evidence_root)
    end

    def prepare_layout
      %w[invocations stores generated cases].each do |name|
        RecheckRecursiveQBitDynamicEvidenceW233.make_dir(File.join(@evidence_root, name))
      end
      RecheckRecursiveQBitDynamicEvidenceW233.make_dir(File.join(@evidence_root, 'generated', 'parts'))
      RecheckRecursiveQBitDynamicEvidenceW233.make_dir(File.join(@evidence_root, 'stores', 'pins'))
      PROFILES.each do |profile|
        id = profile.fetch('id')
        RecheckRecursiveQBitDynamicEvidenceW233.make_dir(File.join(@evidence_root, 'stores', id))
        RecheckRecursiveQBitDynamicEvidenceW233.make_dir(File.join(@evidence_root, 'generated', 'parts', id))
      end
    end

    def pin_runtime
      store = File.join(@evidence_root, 'stores', 'pins')
      version = run_clickhouse('runtime-version-pin', store, 'SELECT version() FORMAT TSVRaw')
      RecheckRecursiveQBitDynamicEvidenceW233.assert!(version.fetch('stdout') == "#{CLICKHOUSE_VERSION}\n",
        'runtime version result differs')
      build = run_clickhouse('runtime-build-pin', store,
        "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw")
      RecheckRecursiveQBitDynamicEvidenceW233.assert!(build.fetch('stdout') == "VERSION_GITHASH=#{CLICKHOUSE_BUILD}\n",
        'runtime build result differs')
      { 'binary' => @binary, 'sha256' => CLICKHOUSE_SHA256, 'version' => CLICKHOUSE_VERSION,
        'build_hash' => CLICKHOUSE_BUILD, 'source_correlation' => 'source revision and runtime build are pinned separately' }
    end

    def helper_input
      generated = File.join(@evidence_root, 'generated', 'parts')
      {
        'format' => HELPER_INPUT_FORMAT,
        'stock_root' => @stock_root,
        'profiles' => PROFILES.map do |profile|
          # All three source columns share the same immutable stock part; the
          # public helper reads the exact part and selects the nominal column.
          {
            'id' => profile.fetch('id'),
            'source_part' => @stock.fetch('part_path'),
            'library_part' => File.join(generated, profile.fetch('id'), 'all_1_1_0'),
          }
        end,
      }
    end

    def run_helper
      input_path = File.join(@evidence_root, 'generated', 'helper-input.json')
      input = helper_input
      write_json(input_path, input)
      input.fetch('profiles').each do |profile|
        RecheckRecursiveQBitDynamicEvidenceW233.assert!(!File.exist?(profile.fetch('library_part')) &&
          !File.symlink?(profile.fetch('library_part')), 'library part output is not fresh')
      end
      RecheckRecursiveQBitDynamicEvidenceW233.assert!(RecheckRecursiveQBitDynamicEvidenceW233.sha256_file(@helper) == @helper_sha_at_start,
        'helper changed before invocation')
      @helper_input_sha = RecheckRecursiveQBitDynamicEvidenceW233.sha256_file(input_path)
      record = @recorder.run('helper-read-write-roundtrip', File.join(@evidence_root, 'generated'), nil,
        timeout: HELPER_TIMEOUT_SECONDS, argv: [@helper, input_path, File.join(@evidence_root, 'generated')])
      process_success!(record, 'public helper')
      output = JSON.parse(record.fetch('stdout').force_encoding(Encoding::UTF_8))
      RecheckRecursiveQBitDynamicEvidenceW233.assert!(output.fetch('format') == HELPER_OUTPUT_FORMAT &&
        output.fetch('profile_ids') == PROFILE_IDS, 'public helper output envelope/profile roster differs')
      helper_profiles = output.fetch('profiles')
      RecheckRecursiveQBitDynamicEvidenceW233.assert!(helper_profiles.map { |item| item.fetch('id') } == PROFILE_IDS,
        'public helper per-profile order differs')
      helper_profiles.zip(PROFILES).each do |item, profile|
        RecheckRecursiveQBitDynamicEvidenceW233.assert!(item.fetch('column') == profile.fetch('column') &&
          item.fetch('declared_type') == profile.fetch('type'), "public helper type binding differs for #{profile.fetch('id')}")
        %w[source library].each do |side|
          scan = item.fetch(side)
          expected_sites = profile.fetch('id') == 'carrier_dynamic' ? ['root.elements'] : ['root']
          RecheckRecursiveQBitDynamicEvidenceW233.assert!(scan.fetch('row_count') == 6 &&
            scan.fetch('mark_row_counts') == MARK_ROWS && scan.fetch('dynamic_site_paths') == expected_sites &&
            scan.fetch('exact_type_and_literal_checks') == true &&
            scan.fetch('windows') == %w[full middle zero_marks zero_candidates eof] &&
            scan.fetch('full_rowbinary_hex') == RecheckRecursiveQBitDynamicEvidenceW233.expected_value_hex(profile) &&
            scan.fetch('typed_full_rowbinary_hex') == RecheckRecursiveQBitDynamicEvidenceW233.expected_value_hex(profile) &&
            scan.fetch('middle_rowbinary_hex') == RecheckRecursiveQBitDynamicEvidenceW233.expected_value_hex(profile)[2, 2] &&
            scan.fetch('typed_middle_rowbinary_hex') == RecheckRecursiveQBitDynamicEvidenceW233.expected_value_hex(profile)[2, 2],
            "public helper #{side} physical/readback record differs for #{profile.fetch('id')}")
        end
        library = item.fetch('library_part_path')
        RecheckRecursiveQBitDynamicEvidenceW233.assert!(library == input.fetch('profiles').find { |p| p.fetch('id') == profile.fetch('id') }.fetch('library_part'),
          "public helper library path differs for #{profile.fetch('id')}")
        @library_inventories[profile.fetch('id')] = RecheckRecursiveQBitDynamicEvidenceW233.inventory(library)
      end
      write_json(File.join(@evidence_root, 'generated', 'helper-output.json'), output)
      write_json(File.join(@evidence_root, 'generated', 'library-physical.json'), {
        'format' => 'recursive_qbit_dynamic_w233_library_physical_v1',
        'profiles' => PROFILES.map do |profile|
          { 'id' => profile.fetch('id'), 'path' => helper_profiles.find { |item| item.fetch('id') == profile.fetch('id') }.fetch('library_part_path'),
            'inventory' => @library_inventories.fetch(profile.fetch('id')) }
        end,
      })
      RecheckRecursiveQBitDynamicEvidenceW233.assert!(RecheckRecursiveQBitDynamicEvidenceW233.sha256_file(@helper) == @helper_sha_at_start &&
        RecheckRecursiveQBitDynamicEvidenceW233.sha256_file(input_path) == @helper_input_sha,
        'helper or helper input changed during execution')
      output
    rescue JSON::ParserError => error
      raise ArgumentError, "W233 helper stdout is not JSON: #{error.message}"
    end

    def native_rows(profile)
      values = profile.fetch('id') == 'carrier_dynamic' ? RecheckRecursiveQBitDynamicEvidenceW233.carrier_values :
        RecheckRecursiveQBitDynamicEvidenceW233.root_values
      ROW_KEYS.each_index.map { |index| RecheckRecursiveQBitDynamicEvidenceW233.uint64(ROW_KEYS.fetch(index)) + values.fetch(index) }
    end

    def create_native(profile)
      id = profile.fetch('id')
      table = "w233_native_#{id}"
      store = File.join(@evidence_root, 'stores', id)
      sql = "CREATE TABLE default.#{table} (id UInt64, #{profile.fetch('column')} #{profile.fetch('type')} CODEC(LZ4)) " \
        "ENGINE=MergeTree ORDER BY id SETTINGS #{STOCK_SETTINGS.join(', ')}"
      create = run_clickhouse("native-create-#{id}", store, sql)
      path_record = run_clickhouse("native-data-path-#{id}", store,
        "SELECT arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw")
      data_path = File.expand_path(path_record.fetch('stdout').strip)
      RecheckRecursiveQBitDynamicEvidenceW233.assert!(data_path.start_with?(store + File::SEPARATOR) &&
        File.directory?(data_path) && !File.symlink?(data_path) && File.realpath(data_path) == data_path,
        "native data path escaped store for #{id}")
      detached = File.join(data_path, 'detached')
      RecheckRecursiveQBitDynamicEvidenceW233.plain_dir!(detached, "native detached path for #{id}")
      { 'id' => id, 'table' => table, 'store' => store, 'data_path' => data_path,
        'detached_part_path' => File.join(detached, 'all_1_1_0'), 'create' => create, 'data_path_record' => path_record }
    end

    def native_window_sql(profile, table, window)
      predicate = { 'full' => '', 'middle' => ' WHERE id BETWEEN 3 AND 4', 'zero' => ' WHERE id=0' }.fetch(window)
      "SELECT id, #{profile.fetch('column')} FROM default.#{table}#{predicate} ORDER BY id FORMAT RowBinary"
    end

    def attach_native(profile, target, helper_profile)
      id = profile.fetch('id')
      library = helper_profile.fetch('library_part_path')
      before = RecheckRecursiveQBitDynamicEvidenceW233.inventory(library)
      RecheckRecursiveQBitDynamicEvidenceW233.assert!(before == @library_inventories.fetch(id),
        "library part changed before ATTACH for #{id}")
      detached = target.fetch('detached_part_path')
      RecheckRecursiveQBitDynamicEvidenceW233.assert!(!File.exist?(detached) && !File.symlink?(detached),
        "native ATTACH destination is not fresh for #{id}")
      FileUtils.cp_r(library, detached)
      RecheckRecursiveQBitDynamicEvidenceW233.assert!(RecheckRecursiveQBitDynamicEvidenceW233.inventory(detached) == before,
        "detached copy differs from library part for #{id}")
      attach = run_clickhouse("native-attach-#{id}", target.fetch('store'),
        "ALTER TABLE default.#{target.fetch('table')} ATTACH PART 'all_1_1_0'")
      check = run_clickhouse("native-check-#{id}", target.fetch('store'),
        "CHECK TABLE default.#{target.fetch('table')} FORMAT TSVRaw")
      RecheckRecursiveQBitDynamicEvidenceW233.assert!(check.fetch('stdout') == "all_1_1_0\t1\t\n",
        "native raw CHECK result differs for #{id}")
      schema = run_clickhouse("native-schema-#{id}", target.fetch('store'),
        "SELECT name, type FROM system.columns WHERE database='default' AND table='#{target.fetch('table')}' ORDER BY position FORMAT TSVRaw")
      expected_schema = "id\tUInt64\n#{profile.fetch('column')}\t#{profile.fetch('type')}\n"
      RecheckRecursiveQBitDynamicEvidenceW233.assert!(schema.fetch('stdout') == expected_schema,
        "native exact nominal schema differs for #{id}")
      part = run_clickhouse("native-part-#{id}", target.fetch('store'),
        "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{target.fetch('table')}' AND active ORDER BY name FORMAT TSVRaw")
      fields = RecheckRecursiveQBitDynamicEvidenceW233.tsv_row!(part.fetch('stdout'), 5, "native part #{id}")
      attached = File.join(target.fetch('data_path'), 'all_1_1_0')
      RecheckRecursiveQBitDynamicEvidenceW233.assert!(fields[0, 4] == ['all_1_1_0', '6', SYSTEM_MARKS.to_s, 'Wide'] &&
        File.expand_path(fields.fetch(4)) == attached, "native part grid/path differs for #{id}")
      after = RecheckRecursiveQBitDynamicEvidenceW233.inventory(attached)
      first = before.to_h { |entry| [entry.fetch('path'), entry] }
      second = after.to_h { |entry| [entry.fetch('path'), entry] }
      removed = (first.keys - second.keys).sort
      changed = first.keys.select { |path| second.key?(path) && first.fetch(path) != second.fetch(path) }.sort
      added = (second.keys - first.keys).sort
      RecheckRecursiveQBitDynamicEvidenceW233.assert!(removed.empty? && changed.empty? && added == [INVALIDATED_FILE],
        "native ATTACH inventory delta differs for #{id}")
      invalidated = File.binread(File.join(attached, INVALIDATED_FILE)).split("\n", -1)
      RecheckRecursiveQBitDynamicEvidenceW233.assert!(invalidated.pop == '' && invalidated.sort == INVALIDATED_NAMES.sort,
        "native invalidated system-column list differs for #{id}")
      columns = File.binread(File.join(attached, 'columns.txt'))
      expected_columns = "columns format version: 1\n2 columns:\n`id` UInt64\n`#{profile.fetch('column')}` #{profile.fetch('type')}\n".b
      RecheckRecursiveQBitDynamicEvidenceW233.assert!(columns == expected_columns,
        "attached columns metadata differs for #{id}")
      codec = File.binread(File.join(attached, 'default_compression_codec.txt')).strip
      metadata = File.binread(File.join(attached, 'metadata_version.txt')).strip
      RecheckRecursiveQBitDynamicEvidenceW233.assert!(codec == 'CODEC(LZ4)' && metadata == '0',
        "attached codec/metadata differs for #{id}")
      windows = {}
      %w[full middle zero].each do |window|
        record = run_clickhouse("native-rowbinary-#{id}-#{window}", target.fetch('store'),
          native_window_sql(profile, target.fetch('table'), window))
        expected = RecheckRecursiveQBitDynamicEvidenceW233.expected_bytes(native_rows(profile), window)
        RecheckRecursiveQBitDynamicEvidenceW233.assert!(record.fetch('stdout') == expected,
          "native #{window} RowBinary differs from independent literals for #{id}")
        windows[window] = { 'bytes' => expected.bytesize, 'sha256' => Digest::SHA256.hexdigest(expected),
          'capture' => File.basename(record.fetch('path')) }
      end
      record = {
        'id' => id, 'table' => target.fetch('table'), 'declared_type' => profile.fetch('type'),
        'library_part_path' => library, 'attached_part_path' => attached,
        'library_inventory' => before, 'attached_inventory' => after,
        'removed_paths' => removed, 'changed_paths' => changed, 'added_paths' => added,
        'check_output' => check.fetch('stdout'), 'schema_output' => schema.fetch('stdout'),
        'columns_sha256' => Digest::SHA256.hexdigest(columns), 'default_compression_codec' => codec,
        'metadata_version' => metadata, 'windows' => windows,
      }
      write_json(File.join(@evidence_root, 'cases', "#{id}.json"), record)
      record
    end

    def run
      prepare_layout
      stock_part_inventory_before = RecheckRecursiveQBitDynamicEvidenceW233.inventory(@stock.fetch('part_path'))
      RecheckRecursiveQBitDynamicEvidenceW233.assert!(stock_part_inventory_before == @stock.fetch('part_inventory'),
        'stock physical inventory changed after initial validation')
      runtime_pin = pin_runtime
      helper_output = run_helper
      helper_profiles = helper_output.fetch('profiles').to_h { |item| [item.fetch('id'), item] }
      PROFILES.each do |profile|
        target = create_native(profile)
        @native_records << attach_native(profile, target, helper_profiles.fetch(profile.fetch('id')))
      end
      stock_part_inventory_after = RecheckRecursiveQBitDynamicEvidenceW233.inventory(@stock.fetch('part_path'))
      RecheckRecursiveQBitDynamicEvidenceW233.assert!(stock_part_inventory_after == stock_part_inventory_before,
        'paired helper/native process changed stock part bytes')
      code_paths = %w[
        scripts/recheck_recursive_qbit_dynamic_w233.rb
        scripts/check_recursive_qbit_dynamic_w233.cr
        scripts/recheck_recursive_qbit_dynamic_evidence_w233.rb
        scripts/check_recursive_qbit_dynamic_evidence_w233.rb
        scripts/recheck_aggregate_recursive_w224.rb
      ]
      code_pins = code_paths.to_h do |relative|
        path = RecheckRecursiveQBitDynamicEvidenceW233.plain_file!(File.join(REPO_ROOT, relative), "capture code #{relative}")
        [relative, RecheckRecursiveQBitDynamicEvidenceW233.sha256_file(path)]
      end
      input_path = File.join(@evidence_root, 'generated', 'helper-input.json')
      helper_capture = RecheckRecursiveQBitDynamicEvidenceW233.raw_record(
        @evidence_root, 'helper-read-write-roundtrip', 3)
      result = {
        'format' => RESULT_FORMAT,
        'classification' => 'recursive_qbit_dynamic_paired_profiles_observed',
        'success' => true,
        'stock_root' => @stock_root,
        'evidence_root' => @evidence_root,
        'source_pin' => { 'root' => SOURCE_ROOT, 'revision' => SOURCE_REVISION },
        'runtime_pin' => runtime_pin,
        'helper_path' => @helper,
        'helper_sha256' => @helper_sha_at_start,
        'helper_sha256_after' => RecheckRecursiveQBitDynamicEvidenceW233.sha256_file(@helper),
        'helper_input_path' => input_path,
        'helper_input_sha256' => @helper_input_sha,
        'helper_stdout_sha256' => Digest::SHA256.hexdigest(helper_capture.fetch('stdout')),
        'code_pins' => code_pins,
        'profiles' => PROFILES,
        'stock_part_path' => @stock.fetch('part_path'),
        'stock_part_inventory_before' => stock_part_inventory_before,
        'stock_part_inventory_after' => stock_part_inventory_after,
        'helper_output' => helper_output,
        'library_inventories' => @library_inventories,
        'native_profiles' => @native_records,
        'evidence_process_count' => @recorder.records.length,
        'evidence_process_labels' => @recorder.records.map { |item| item.fetch('label') },
        'scope' => 'three fixed W233 profiles (root Dynamic, Array(Dynamic), forced-shared Dynamic), actual Array/Tuple/Map/Array(Variant) QBit products; stock RowBinary input was separately audited; no general recursive-type or performance claim',
      }
      write_json(File.join(@evidence_root, 'result.json'), result)
      write_json(File.join(@evidence_root, 'capture_inventory.json'), {
        'files' => RecheckRecursiveQBitDynamicEvidenceW233.root_inventory(@evidence_root,
          ignored: ['capture_inventory.json']),
      })
      check_budget!
      puts "W233 paired helper/native evidence: 3 fixed profiles; #{result.fetch('evidence_process_count')} raw processes; evidence root #{@evidence_root}"
      true
    rescue StandardError => error
      warn "W233 paired evidence stopped with raw captures preserved: #{error.class}: #{error.message}"
      false
    end
  end

  def main(argv)
    options = { clickhouse: CLICKHOUSE_BIN }
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/recheck_recursive_qbit_dynamic_evidence_w233.rb --stock-root ROOT --evidence-root EMPTY_ROOT --helper BIN --helper-sha256 SHA [--clickhouse PINNED_BIN]'
      opts.on('--stock-root PATH') { |value| options[:stock_root] = value }
      opts.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
      opts.on('--helper PATH') { |value| options[:helper] = value }
      opts.on('--helper-sha256 SHA') { |value| options[:helper_sha256] = value }
      opts.on('--clickhouse PATH') { |value| options[:clickhouse] = value }
    end
    parser.parse!(argv)
    assert!(argv.empty? && %i[stock_root evidence_root helper helper_sha256].all? { |key| options.key?(key) }, parser.to_s)
    Probe.new(options).run
  rescue StandardError => error
    warn "W233 evidence runner setup stopped: #{error.class}: #{error.message}"
    false
  end
end

exit(RecheckRecursiveQBitDynamicEvidenceW233.main(ARGV) ? 0 : 1) if $PROGRAM_NAME == __FILE__
