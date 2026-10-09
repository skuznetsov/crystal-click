#!/usr/bin/env ruby
# Independent raw-evidence replay for the W234 Object recursive-QBit slice.
# This file intentionally imports neither the paired runner nor stock probe.

require 'digest'
require 'find'
require 'json'
require 'optparse'

module CheckObjectRecursiveQBitEvidenceW234
  extend self

  REPO_ROOT = '/Users/sergey/Projects/Crystal/crystal-click'.freeze
  SOURCE_ROOT = '/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1'.freeze
  SOURCE_REVISION = '0ca8150d9b1d0886edb2e3b4ab65eebb768d0357'.freeze
  CLICKHOUSE_BIN = '/private/tmp/crystal-click-w216-runtime-recovery.DmL9Kw/clickhouse-stripped'.freeze
  CLICKHOUSE_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  CLICKHOUSE_VERSION = '26.10.1.1201'.freeze
  CLICKHOUSE_BUILD = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  STOCK_PREFIX = 'crystal-click-w234-stock.'.freeze
  EVIDENCE_PREFIX = 'crystal-click-w234-evidence.'.freeze
  RESULT_FORMAT = 'object_recursive_qbit_evidence_w234_v1'.freeze
  HELPER_INPUT_FORMAT = 'object_recursive_qbit_w234_input_v1'.freeze
  HELPER_OUTPUT_FORMAT = 'object_recursive_qbit_w234_helper_v1'.freeze
  IDS = %w[typed_dynamic inferred_dynamic forced_shared].freeze
  PROFILES = [
    { 'id' => 'typed_dynamic', 'table' => 'w234_json_typed_dynamic', 'type' => 'JSON(max_dynamic_paths=0, q Dynamic(max_types=3))', 'ingestion' => 'RowBinary', 'kind' => 'typed_dynamic' },
    { 'id' => 'inferred_dynamic', 'table' => 'w234_json_inferred_dynamic', 'type' => 'JSON(max_dynamic_types=3, max_dynamic_paths=1)', 'ingestion' => 'RowBinary', 'kind' => 'inferred_dynamic' },
    { 'id' => 'forced_shared', 'table' => 'w234_json_forced_shared', 'type' => 'JSON(max_dynamic_types=3, max_dynamic_paths=0)', 'ingestion' => 'RowBinary', 'kind' => 'forced_shared' },
  ].freeze
  ROW_KEYS = [1, 2, 3, 4, 5, 6].freeze
  MARK_ROWS = [2, 2, 2].freeze
  SYSTEM_MARKS = 4
  MAX_FILES = 4096
  MAX_TOTAL_BYTES = 64 * 1024 * 1024
  MAX_TREE_ENTRIES = 4096
  MAX_TREE_BYTES = 64 * 1024 * 1024
  MAX_OBJECT_METADATA_BYTES = 4 * 1024 * 1024
  MAX_OBJECT_METADATA_LINE_BYTES = 64 * 1024
  MAX_OBJECT_SUBSTREAMS = 65_536
  MEMORY_LIMIT_BYTES = 1_073_741_824
  PROCESS_TIMEOUT_SECONDS = 90
  HELPER_TIMEOUT_SECONDS = 600
  INVALIDATED_FILE = 'invalidated_system_columns.txt'.freeze
  INVALIDATED_NAMES = %w[_block_number _block_offset].freeze
  UUID_RE = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/.freeze
  SETTINGS = [
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
  # Independent literal q-path RowBinary values. These do not come from the
  # Object RowBinary input fixture or from helper output.
  DIRECT_HEX = [
    '1e360709020901020304050607080909000000000000000000',
    '1e36070900',
    '20020171360709016e0109ff000102040810204007',
    '271536070902016109010203040506070809046c6f6e6709090807060504030201',
    '1e3607090109000000000000000000',
    '00',
  ].freeze
  QBIT_RAW_HEX = [
    ['010203040506070809', '000000000000000000'], [], ['ff0001020408102040'],
    ['010203040506070809', '090807060504030201'], ['000000000000000000'], [],
  ].freeze
  ACTUAL_NAMES = [
    'Array(QBit(Int8, 9))', 'Array(QBit(Int8, 9))', 'Tuple(q QBit(Int8, 9), n UInt8)',
    'Map(String, QBit(Int8, 9))', 'Array(QBit(Int8, 9))', 'None',
  ].freeze
  DYNAMIC_TYPES = ['Array(QBit(Int8, 9))', 'Map(String, QBit(Int8, 9))', 'Tuple(q QBit(Int8, 9), n UInt8)'].sort.freeze
  CODE_PATHS = %w[
    scripts/recheck_object_qbit_recursive_stock_w234.rb
    scripts/recheck_object_recursive_qbit_evidence_w234.rb
    scripts/check_object_recursive_qbit_evidence_w234.rb
    scripts/check_object_recursive_qbit_w234.cr
    scripts/recheck_recursive_qbit_dynamic_w233.rb
    scripts/recheck_aggregate_recursive_w224.rb
  ].freeze

  def fail!(message)
    raise "W234 AUDIT FAIL: #{message}"
  end

  def assert!(condition, message)
    fail!(message) unless condition
  end

  def plain_file!(path, label, executable: false)
    full = File.expand_path(path)
    assert!(File.file?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "#{label} absent, symlinked, or noncanonical: #{full}")
    assert!(!executable || File.executable?(full), "#{label} is not executable")
    full
  end

  def plain_dir!(path, label)
    full = File.expand_path(path)
    assert!(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "#{label} absent, symlinked, or noncanonical: #{full}")
    full
  end

  def read_json(path, label)
    JSON.parse(File.binread(plain_file!(path, label)).force_encoding(Encoding::UTF_8))
  rescue JSON::ParserError => error
    fail!("malformed #{label}: #{error.message}")
  end

  def sha256_file(path)
    Digest::SHA256.file(plain_file!(path, 'hashed file')).hexdigest
  end

  def bounded_root!(path, prefix, label)
    root = plain_dir!(path, label)
    assert!(File.dirname(root) == File.realpath('/private/tmp') && File.basename(root).start_with?(prefix),
      "#{label} must be a direct bounded /private/tmp child named #{prefix}*")
    root
  end

  def uint64_le(value)
    Array.new(8) { |index| (value >> (8 * index)) & 0xff }.pack('C*').b
  end

  def stock_input_rows
    [
      '01000000000000000101711e360709020901020304050607080909000000000000000000',
      '02000000000000000101711e36070900',
      '030000000000000001017120020171360709016e0109ff000102040810204007',
      '0400000000000000010171271536070902016109010203040506070809046c6f6e6709090807060504030201',
      '05000000000000000101711e3607090109000000000000000000',
      '060000000000000000',
    ].map { |hex| [hex].pack('H*').b }.join.b
  end

  def direct_rows
    ROW_KEYS.each_with_index.map { |id, index| uint64_le(id) + [DIRECT_HEX.fetch(index)].pack('H*').b }
  end

  def indexes(window)
    { 'full' => (0...ROW_KEYS.size).to_a, 'middle' => [2, 3], 'zero' => [] }.fetch(window)
  end

  def expected_bytes(rows, window)
    indexes(window).map { |index| rows.fetch(index) }.join.b
  end

  def expected_schema(profile)
    "id\tUInt64\nj\t#{profile.fetch('type')}\n"
  end

  def stock_schema(profile)
    "id\tUInt64\nj\t#{profile.fetch('type')}\n"
  end

  def create_sql(profile, table: profile.fetch('table'))
    "CREATE TABLE default.#{table} (id UInt64, j #{profile.fetch('type')}) ENGINE=MergeTree ORDER BY id SETTINGS #{SETTINGS.join(', ')}"
  end

  def stock_insert_sql(profile)
    "INSERT INTO default.#{profile.fetch('table')} SETTINGS input_format_binary_read_json_as_string=0 FORMAT RowBinary"
  end

  def check_sql(table)
    "CHECK TABLE default.#{table} FORMAT TSVRaw"
  end

  def schema_sql(table)
    "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw"
  end

  def actual_roster_sql(table)
    "SELECT id, dynamicType(j.q), toUInt8(isDynamicElementInSharedData(j.q)), has(JSONDynamicPaths(j), 'q'), has(JSONSharedDataPaths(j), 'q') FROM default.#{table} ORDER BY id FORMAT TSVRaw"
  end

  def expected_roster(profile)
    ACTUAL_NAMES.each_with_index.map do |name, index|
      dynamic, shared = case profile.fetch('kind')
                        when 'typed_dynamic' then [0, 0]
                        when 'inferred_dynamic' then [index == 5 ? 0 : 1, 0]
                        when 'forced_shared' then [0, index == 5 ? 0 : 1]
                        else fail!("unadmitted profile #{profile.fetch('kind')}")
                        end
      "#{index + 1}\t#{name}\t0\t#{dynamic}\t#{shared}\n"
    end.join
  end

  def part_sql(table)
    "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw"
  end

  def window_sql(table, window)
    predicate = { 'full' => '', 'middle' => ' WHERE id BETWEEN 3 AND 4', 'zero' => ' WHERE id=0' }.fetch(window)
    "SELECT id, j.q FROM default.#{table}#{predicate} ORDER BY id SETTINGS output_format_binary_write_json_as_string=0 FORMAT RowBinary"
  end

  def clickhouse_argv(store, sql)
    [CLICKHOUSE_BIN, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
      '--max_insert_threads=1', '--max_execution_time=30', "--max_memory_usage=#{MEMORY_LIMIT_BYTES}",
      '--print_pretty_type_names=0', '--flatten_nested=0', '--multiquery', '--query', sql]
  end

  def raw_invocation(root, sequence, label, expected_store:, sql:, input: nil, helper: nil, helper_input: nil, helper_output: nil)
    base = File.join(root, 'invocations', format('%04d-%s', sequence, label))
    argv_record = read_json(base + '.argv.json', "#{label} argv")
    status = read_json(base + '.status.json', "#{label} status")
    sql_bytes = File.binread(plain_file!(base + '.sql', "#{label} SQL"))
    stdout = File.binread(plain_file!(base + '.stdout', "#{label} stdout"))
    stderr = File.binread(plain_file!(base + '.stderr', "#{label} stderr"))
    assert!(argv_record.fetch('label') == label && status.fetch('label') == label, "#{label} raw label mismatch")
    expected_sql = ((sql || '').end_with?("\n") ? (sql || '') : (sql || '') + "\n").b
    assert!(sql_bytes == expected_sql, "#{label} SQL bytes differ from fixed action")
    assert!(argv_record.fetch('environment') == { 'TZ' => 'UTC' }, "#{label} environment differs")
    timeout = helper ? HELPER_TIMEOUT_SECONDS : PROCESS_TIMEOUT_SECONDS
    assert!(argv_record.fetch('timeout_seconds') == timeout, "#{label} timeout cap differs")
    expected_argv = if helper
                      [helper, helper_input, helper_output]
                    else
                      clickhouse_argv(expected_store, sql)
                    end
    assert!(argv_record.fetch('argv') == expected_argv, "#{label} exact argv differs")
    if input
      stdin = File.binread(plain_file!(base + '.stdin.bin', "#{label} stdin"))
      assert!(stdin == input.b && argv_record.fetch('stdin_bytes') == stdin.bytesize &&
        argv_record.fetch('stdin_sha256') == Digest::SHA256.hexdigest(stdin), "#{label} stdin literal/hash differs")
    else
      assert!(!File.exist?(base + '.stdin.bin') && argv_record['stdin_bytes'].nil? && argv_record['stdin_sha256'].nil?,
        "#{label} unexpected stdin file")
    end
    assert!(status.fetch('classification') == 'process_success' && status.fetch('exitstatus') == 0 &&
      status.fetch('signaled') == false && status.fetch('timed_out') == false && status.fetch('spawn_error').nil?,
      "#{label} raw process status is not success")
    assert!(status.fetch('stdout_bytes') == stdout.bytesize && status.fetch('stderr_bytes') == stderr.bytesize,
      "#{label} byte census differs from raw files")
    { 'base' => base, 'status' => status, 'argv' => argv_record, 'sql' => sql_bytes,
      'stdout' => stdout, 'stderr' => stderr }
  rescue KeyError, JSON::ParserError => error
    fail!("malformed raw action #{label}: #{error.message}")
  end

  def part_inventory(path)
    root = plain_dir!(path, 'part inventory root')
    files = []
    entries = 0
    bytes = 0
    Find.find(root) do |entry|
      next if entry == root
      entries += 1
      assert!(entries <= MAX_TREE_ENTRIES && !File.symlink?(entry), 'part contains a symlink or exceeds entry bound')
      next if File.directory?(entry)
      assert!(File.file?(entry), "part contains unsupported entry: #{entry}")
      bytes += File.size(entry)
      assert!(bytes <= MAX_TREE_BYTES, 'part exceeds byte inventory bound')
      files << { 'path' => entry[(root.length + 1)..-1], 'size' => File.size(entry), 'sha256' => sha256_file(entry) }
    end
    files.sort_by { |item| item.fetch('path') }
  end

  def selected_j_stream_names(part_path)
    part = plain_dir!(part_path, 'Object part for stream roster')
    metadata = plain_file!(File.join(part, 'columns_substreams.txt'), 'Object columns_substreams.txt')
    size = File.size(metadata)
    assert!(size <= MAX_OBJECT_METADATA_BYTES, 'columns_substreams.txt exceeds independent audit bound')
    bytes = File.binread(metadata)
    assert!(bytes.bytesize == size && bytes.end_with?("\n") && !bytes.include?("\r") && !bytes.include?("\0"),
      'columns_substreams.txt is truncated or noncanonical')
    lines = bytes.split("\n", -1)
    assert!(lines.pop == '', 'columns_substreams.txt lacks its final newline')
    assert!(lines.all? { |line| line.bytesize + 1 <= MAX_OBJECT_METADATA_LINE_BYTES },
      'columns_substreams.txt line exceeds independent audit bound')
    assert!(lines.length >= 2 && lines[0] == 'columns substreams version: 1',
      'unsupported columns_substreams.txt version')
    column_count_line = lines[1]
    column_match = /\A(0|[1-9][0-9]*) columns:\z/.match(column_count_line)
    assert!(column_match && column_match[1] == '2',
      'Object part must have exactly the fixed id,j substream columns')

    cursor = 2
    total_substreams = 0
    selected = []
    %w[id j].each do |column_name|
      header = lines.fetch(cursor) { fail!('columns_substreams.txt ended before fixed column headers') }
      match = /\A(0|[1-9][0-9]*) substreams for column `#{column_name}`:\z/.match(header)
      assert!(match, "columns_substreams.txt column order/header differs at #{column_name}")
      count = Integer(match[1], 10)
      assert!(count <= MAX_OBJECT_SUBSTREAMS - total_substreams,
        'columns_substreams.txt exceeds independent substream bound')
      total_substreams += count
      cursor += 1
      count.times do
        lane = lines.fetch(cursor) { fail!("columns_substreams.txt ended within #{column_name} lanes") }
        assert!(lane.start_with?("\t"), "columns_substreams.txt lane lacks its tab prefix for #{column_name}")
        name = lane.byteslice(1, lane.bytesize - 1)
        assert!(!name.empty? && name.bytesize <= MAX_OBJECT_METADATA_LINE_BYTES &&
          name.each_byte.all? { |byte| byte >= 0x20 && byte != 0x7f },
          "columns_substreams.txt has an invalid lane name for #{column_name}")
        if column_name == 'j'
          assert!(!name.include?('/') && !name.include?("\\"), 'selected j lane is not a filename component')
          selected << name
        end
        cursor += 1
      end
    end
    assert!(cursor == lines.length, 'columns_substreams.txt has trailing records')
    assert!(selected.uniq == selected, 'selected j stream roster contains duplicates')
    selected.sort
  rescue IndexError, ArgumentError => error
    fail!("malformed columns_substreams.txt: #{error.message}")
  end

  def validate_alias!(root, entry)
    relative = entry[(root.length + 1)..-1]
    match = /\Astores\/(typed_dynamic|inferred_dynamic|forced_shared)\/(metadata\/default|data\/default\/(w234_json_(?:typed_dynamic|inferred_dynamic|forced_shared)|w234_native_(?:typed_dynamic|inferred_dynamic|forced_shared)))\z/.match(relative)
    assert!(match, "unbounded symlink in local evidence inventory: #{relative}")
    id = match[1]
    store = File.join(root, 'stores', id)
    suffix = match[2]
    if suffix == 'metadata/default'
      depth = 1
    else
      table = suffix.split('/').last
      expected = table.start_with?('w234_native_') ? "w234_native_#{id}" : "w234_json_#{id}"
      assert!(table == expected, "Atomic table alias/profile mismatch: #{relative}")
      depth = 2
    end
    target = File.readlink(entry)
    pattern = depth == 1 ? /\A\.\.\/store\/([0-9a-f]{3})\/([0-9a-f-]{36})\z/ : /\A\.\.\/\.\.\/store\/([0-9a-f]{3})\/([0-9a-f-]{36})\z/
    parts = pattern.match(target)
    assert!(parts && UUID_RE.match?(parts[2]) && parts[1] == parts[2][0, 3], "Atomic alias target grammar/fanout invalid: #{relative}")
    physical = File.join(store, 'store')
    resolved = File.join(physical, parts[1], parts[2])
    assert!(File.expand_path(target, File.dirname(entry)) == resolved, "Atomic alias escapes local physical store: #{relative}")
    [physical, File.join(physical, parts[1]), resolved].each do |path|
      assert!(File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path,
        "Atomic alias target missing/chained/noncanonical: #{path}")
    end
    assert!(File.directory?(entry) && File.realpath(entry) == resolved, "Atomic alias does not resolve to expected target: #{relative}")
    { 'path' => relative, 'target' => target, 'resolved_target' => resolved }
  end

  def root_inventory(root)
    files = []
    aliases = []
    count = 0
    bytes = 0
    Find.find(root) do |entry|
      next if entry == root
      if File.symlink?(entry)
        aliases << validate_alias!(root, entry)
        Find.prune
        next
      end
      next if File.directory?(entry)
      assert!(File.file?(entry), "capture contains unsupported path: #{entry}")
      count += 1
      bytes += File.size(entry)
      assert!(count <= MAX_FILES && bytes <= MAX_TOTAL_BYTES, 'capture inventory exceeded bounds')
      next if entry == File.join(root, 'capture_inventory.json')
      files << { 'path' => entry[(root.length + 1)..-1], 'size' => File.size(entry), 'sha256' => sha256_file(entry) }
    end
    { 'files' => files.sort_by { |item| item.fetch('path') }, 'directory_aliases' => aliases.sort_by { |item| item.fetch('path') } }
  end

  def expected_stock_labels
    ['runtime-version', 'runtime-build'] + PROFILES.flat_map do |profile|
      id = profile.fetch('id')
      ["#{id}-create", "#{id}-insert-rowbinary", "#{id}-check", "#{id}-schema", "#{id}-actual-roster", "#{id}-part",
        *%w[full middle zero].map { |window| "#{id}-direct-path-rowbinary-#{window}" }]
    end
  end

  def validate_invocation_census!(root, labels, stdin_labels)
    expected = labels.each_with_index.flat_map do |label, index|
      base = format('%04d-%s', index + 1, label)
      suffixes = %w[argv.json sql stdout stderr status.json]
      suffixes << 'stdin.bin' if stdin_labels.include?(label)
      suffixes.map { |suffix| "#{base}.#{suffix}" }
    end.sort
    directory = plain_dir!(File.join(root, 'invocations'), 'invocations directory')
    actual = Dir.children(directory).sort
    assert!(actual == expected, 'raw invocation files do not match exact action/status/stdin census')
    actual.each { |name| plain_file!(File.join(directory, name), "raw invocation #{name}") }
  end

  def verify_stock!(root)
    stores = IDS.to_h { |id| [id, File.join(root, 'stores', id)] }
    witnesses = read_json(File.join(root, 'witnesses.json'), 'stock witness')
    assert!(witnesses.fetch('format') == 'object_qbit_recursive_stock_w234_v1' &&
      witnesses.fetch('source_reference') == "#{SOURCE_ROOT}@#{SOURCE_REVISION}", 'stock witness source pin differs')
    runtime = witnesses.fetch('runtime')
    assert!(runtime.fetch('path') == CLICKHOUSE_BIN && runtime.fetch('sha256') == CLICKHOUSE_SHA256 &&
      runtime.fetch('version') == CLICKHOUSE_VERSION && runtime.fetch('build_hash') == CLICKHOUSE_BUILD,
      'stock witness runtime pin differs')
    assert!(witnesses.fetch('settings') == SETTINGS, 'stock settings differ')
    assert!(witnesses.fetch('profiles').map { |item| item.fetch('id') } == IDS, 'stock profile order differs')

    raws = {}
    raws['runtime-version'] = raw_invocation(root, 1, 'runtime-version', expected_store: stores.fetch(IDS.first), sql: 'SELECT version() FORMAT TSVRaw')
    build_sql = "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw"
    raws['runtime-build'] = raw_invocation(root, 2, 'runtime-build', expected_store: stores.fetch(IDS.first), sql: build_sql)
    assert!(raws.fetch('runtime-version').fetch('stdout') == "#{CLICKHOUSE_VERSION}\n" &&
      raws.fetch('runtime-build').fetch('stdout') == "VERSION_GITHASH=#{CLICKHOUSE_BUILD}\n", 'stock raw runtime pins differ')
    inventories = read_json(File.join(root, 'part_inventories.json'), 'stock part inventories').fetch('parts')
    assert!(inventories.map { |item| item.fetch('id') } == IDS, 'stock part inventory profile order differs')
    profiles = []
    sequence = 3
    PROFILES.each do |profile|
      id, store, table = profile.values_at('id', nil, 'table')
      store = stores.fetch(id)
      actions = {}
      labels = ["#{id}-create", "#{id}-insert-rowbinary", "#{id}-check", "#{id}-schema", "#{id}-actual-roster", "#{id}-part",
        *%w[full middle zero].map { |window| "#{id}-direct-path-rowbinary-#{window}" }]
      labels.each do |label|
        tail = label.sub("#{id}-", '')
        sql, input = case tail
                     when 'create' then [create_sql(profile), nil]
                     when 'insert-rowbinary' then ["INSERT INTO default.#{table} SETTINGS input_format_binary_read_json_as_string=0 FORMAT RowBinary", stock_input_rows]
                     when 'check' then [check_sql(table), nil]
                     when 'schema' then ["SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw", nil]
                     when 'actual-roster' then [actual_roster_sql(table), nil]
                     when 'part' then [part_sql(table), nil]
                     else [window_sql(table, tail.delete_prefix('direct-path-rowbinary-')), nil]
                     end
        actions[label] = raw_invocation(root, sequence, label, expected_store: store, sql: sql, input: input)
        sequence += 1
      end
      check = actions.fetch("#{id}-check")
      schema = actions.fetch("#{id}-schema")
      roster = actions.fetch("#{id}-actual-roster")
      part = actions.fetch("#{id}-part")
      assert!(check.fetch('stdout') == "all_1_1_0\t1\t\n", "stock raw CHECK result/error field is not exact for #{id}")
      assert!(schema.fetch('stdout') == stock_schema(profile), "stock exact schema differs for #{id}")
      assert!(roster.fetch('stdout') == expected_roster(profile), "stock nominal actual/route roster differs for #{id}")
      fields = part.fetch('stdout').force_encoding(Encoding::UTF_8).lines.map { |line| line.chomp.split("\t", -1) }
      assert!(fields.size == 1 && fields.first.size == 5 && fields.first[0, 4] == ['all_1_1_0', '6', SYSTEM_MARKS.to_s, 'Wide'],
        "stock part row/mark/type differs for #{id}")
      path = File.expand_path(fields.first.fetch(4))
      assert!(path.start_with?(store + File::SEPARATOR) && File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path,
        "stock part path escaped store for #{id}")
      measured = part_inventory(path)
      captured_part = inventories.find { |item| item.fetch('id') == id }
      assert!(captured_part && captured_part.fetch('part_path') == path && captured_part.fetch('files') == measured,
        "stock part hash inventory differs for #{id}")
      input_file = File.binread(plain_file!(File.join(root, 'literal_rowbinary', "#{id}-input.rowbin"), "#{id} literal input"))
      insert_stdin = File.binread(actions.fetch("#{id}-insert-rowbinary").fetch('base') + '.stdin.bin')
      assert!(input_file == stock_input_rows && insert_stdin == stock_input_rows, "stock independent input bytes differ for #{id}")
      %w[full middle zero].each do |window|
        expected = expected_bytes(direct_rows, window)
        output = actions.fetch("#{id}-direct-path-rowbinary-#{window}")
        literal = File.binread(plain_file!(File.join(root, 'literal_rowbinary', "#{id}-#{window}-expected.rowbin"), "#{id} #{window} literal"))
        assert!(output.fetch('stdout') == expected && literal == expected, "stock #{window} direct RowBinary differs for #{id}")
      end
      profiles << { 'id' => id, 'table' => table, 'type' => profile.fetch('type'), 'part_path' => path, 'part_inventory' => measured }
      raws.merge!(actions)
    end
    assert!(raws.keys == expected_stock_labels, 'stock process roster/count differs from exact action order')
    stdin_labels = PROFILES.map { |profile| "#{profile.fetch('id')}-insert-rowbinary" }
    validate_invocation_census!(root, expected_stock_labels, stdin_labels)
    root_files = stock_root_inventory(root)
    captured = read_json(File.join(root, 'capture_inventory.json'), 'stock capture inventory')
    assert!(captured.fetch('files') == root_files.fetch('files') && captured.fetch('directory_aliases') == root_files.fetch('directory_aliases'),
      'stock raw file or bounded Atomic-alias inventory differs')
    { 'records' => raws, 'profiles' => profiles, 'capture_inventory' => root_files }
  end

  def stock_root_inventory(root)
    files = []
    aliases = []
    stores = IDS.to_h { |id| [id, File.join(root, 'stores', id)] }
    count = 0
    bytes = 0
    Find.find(root) do |entry|
      next if entry == root
      if File.symlink?(entry)
        relative = entry[(root.length + 1)..-1]
        match = /\Astores\/(typed_dynamic|inferred_dynamic|forced_shared)\/(metadata\/default|data\/default\/(w234_json_(?:typed_dynamic|inferred_dynamic|forced_shared)))\z/.match(relative)
        assert!(match, "unexpected stock directory alias: #{relative}")
        id, tail = match[1], match[2]
        if tail == 'metadata/default'
          depth = 1
        else
          assert!(tail.split('/').last == PROFILES.find { |p| p.fetch('id') == id }.fetch('table'), "stock alias table/profile mismatch: #{relative}")
          depth = 2
        end
        raw = File.readlink(entry)
        pattern = depth == 1 ? /\A\.\.\/store\/([0-9a-f]{3})\/([0-9a-f-]{36})\z/ : /\A\.\.\/\.\.\/store\/([0-9a-f]{3})\/([0-9a-f-]{36})\z/
        link = pattern.match(raw)
        assert!(link && UUID_RE.match?(link[2]) && link[1] == link[2][0, 3], "stock Atomic alias grammar invalid: #{relative}")
        physical = File.join(stores.fetch(id), 'store')
        target = File.join(physical, link[1], link[2])
        assert!(File.expand_path(raw, File.dirname(entry)) == target, "stock alias escapes its isolated store: #{relative}")
        [physical, File.join(physical, link[1]), target].each do |path|
          assert!(File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path, "stock alias target invalid: #{path}")
        end
        assert!(File.directory?(entry) && File.realpath(entry) == target, "stock alias does not resolve canonically: #{relative}")
        # Stock captures use a store-relative alias path and identify its store
        # separately; retain the independently checked root-relative grammar.
        aliases << { 'path' => tail, 'target' => raw, 'resolved_target' => target, 'store' => stores.fetch(id) }
        Find.prune
        next
      end
      next if File.directory?(entry)
      assert!(File.file?(entry), "stock capture has unsupported entry: #{entry}")
      count += 1
      bytes += File.size(entry)
      assert!(count <= MAX_FILES && bytes <= MAX_TOTAL_BYTES, 'stock capture exceeds inventory bound')
      next if entry == File.join(root, 'capture_inventory.json')
      files << { 'path' => entry[(root.length + 1)..-1], 'size' => File.size(entry), 'sha256' => sha256_file(entry) }
    end
    { 'files' => files.sort_by { |item| item.fetch('path') }, 'directory_aliases' => aliases.sort_by { |item| item.fetch('path') } }
  end

  def helper_expected_rows(profile)
    rows = []
    ROW_KEYS.each_with_index do |id, index|
      typed = profile.fetch('id') == 'typed_dynamic'
      present = index < 5 || typed
      rows << {
        'id' => id, 'path_present' => present, 'dynamic_type' => ACTUAL_NAMES.fetch(index),
        'qbit_raw_hex' => QBIT_RAW_HEX.fetch(index), 'direct_rowbinary_hex' => DIRECT_HEX.fetch(index),
      }
    end
    rows
  end

  def expected_structure(profile)
    id = profile.fetch('id')
    dynamic_type = { 'path' => 'q', 'types' => DYNAMIC_TYPES }
    if id == 'typed_dynamic'
      { 'object_dynamic_paths' => [], 'typed_paths' => ['q'], 'typed_dynamic_paths' => ['q'],
        'object_version' => 4, 'dynamic_type_rosters' => [], 'typed_dynamic_type_rosters' => [dynamic_type],
        'shared_data_version' => 3, 'bucket_count' => 1 }
    elsif id == 'inferred_dynamic'
      { 'object_dynamic_paths' => ['q'], 'typed_paths' => [], 'typed_dynamic_paths' => [],
        'object_version' => 4, 'dynamic_type_rosters' => [dynamic_type], 'typed_dynamic_type_rosters' => [],
        'shared_data_version' => 3, 'bucket_count' => 1 }
    else
      { 'object_dynamic_paths' => [], 'typed_paths' => [], 'typed_dynamic_paths' => [],
        'object_version' => 4, 'dynamic_type_rosters' => [], 'typed_dynamic_type_rosters' => [],
        'shared_data_version' => 3, 'bucket_count' => 2 }
    end
  end

  def expected_schema_declaration(profile)
    profile.fetch('type')
  end

  def validate_helper!(output, helper_input, stock, evidence, helper, helper_sha)
    assert!(output.fetch('format') == HELPER_OUTPUT_FORMAT && output.fetch('profile_ids') == IDS,
      'public helper output envelope/profile list differs')
    helper_profiles = output.fetch('profiles')
    assert!(helper_profiles.is_a?(Array) && helper_profiles.length == PROFILES.length,
      'public helper profile row count differs from the exact fixed roster')
    helper_ids = helper_profiles.map do |item|
      assert!(item.is_a?(Hash), 'public helper profile row is not an object')
      item.fetch('id')
    end
    assert!(helper_ids == IDS, 'public helper profile IDs/order differ from the exact fixed roster')
    expected_parts = helper_input.fetch('profiles').to_h { |item| [item.fetch('id'), item] }
    library_inventories = {}
    expected_profiles = []
    helper_profiles.zip(PROFILES).each do |item, profile|
      id = profile.fetch('id')
      expected = expected_parts.fetch(id)
      source_part = stock.fetch('profiles').find { |p| p.fetch('id') == id }.fetch('part_path')
      library_part = expected.fetch('library_part')
      assert!(item.fetch('id') == id && item.fetch('column') == 'j' &&
        item.fetch('declared_type') == expected_schema_declaration(profile), "helper nominal binding differs for #{id}")
      assert!(item.fetch('source_part_path') == source_part &&
        item.fetch('library_part_path') == library_part, "helper source/library part path differs for #{id}")
      expected_stream_rosters = {
        'stock-source' => selected_j_stream_names(source_part),
        'library-output' => selected_j_stream_names(library_part),
      }
      source, library = item.values_at('source', 'library')
      [source, library].each_with_index do |scan, side_index|
        side = side_index.zero? ? 'stock-source' : 'library-output'
        assert!(scan.fetch('row_count') == 6 && scan.fetch('mark_row_counts') == MARK_ROWS &&
          scan.fetch('schema_declaration') == expected_schema_declaration(profile) &&
          scan.fetch('ordinary_string_profile') == 'single_stream' &&
          scan.fetch('structure') == expected_structure(profile) &&
          scan.fetch('exact_nominal_and_qbit_literal_checks') == true,
          "helper #{side} schema/grid/route differs for #{id}")
        expected_rows = helper_expected_rows(profile)
        assert!(scan.fetch('rows') == expected_rows, "helper #{side} actual type/path/QBit row literals differ for #{id}")
        windows = scan.fetch('windows')
        direct_hex = DIRECT_HEX
        assert!(windows.fetch('full') == direct_hex && windows.fetch('middle') == direct_hex[2, 2] &&
          windows.fetch('zero') == [] && windows.fetch('eof_returned_marks') == 0,
          "helper #{side} direct-path full/middle/zero/EOF witnesses differ for #{id}")
        streams = scan.fetch('physical_stream_names')
        assert!(streams.is_a?(Array) && !streams.empty? && streams.all? { |name| name.is_a?(String) } &&
          streams == streams.sort && streams.uniq == streams, "helper #{side} physical stream roster malformed for #{id}")
        assert!(streams == expected_stream_rosters.fetch(side),
          "helper #{side} physical stream roster differs from independently parsed j columns_substreams.txt for #{id}")
      end
      assert!(source == library, "public Object source/library full-read records differ for #{id}")
      physical = part_inventory(expected.fetch('library_part'))
      library_inventories[id] = physical
      expected_profiles << { 'id' => id, 'path' => expected.fetch('library_part'), 'files' => physical }
    end
    [output, library_inventories, expected_profiles]
  rescue KeyError => error
    fail!("public helper output missing field: #{error.message}")
  end

  def native_actions(evidence, profile, helper_profile, sequence_start)
    id = profile.fetch('id')
    store = File.join(evidence, 'stores', id)
    native_table = "w234_native_#{id}"
    data_path_sql = "SELECT arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{native_table}' FORMAT TSVRaw"
    actions = []
    actions << ["native-create-#{id}", create_sql(profile, table: native_table)]
    actions << ["native-data-path-#{id}", data_path_sql]
    actions << ["native-attach-#{id}", "ALTER TABLE default.#{native_table} ATTACH PART 'all_1_1_0'"]
    actions << ["native-check-#{id}", check_sql(native_table)]
    actions << ["native-schema-#{id}", schema_sql(native_table)]
    actions << ["native-roster-#{id}", actual_roster_sql(native_table)]
    actions << ["native-part-#{id}", part_sql(native_table)]
    %w[full middle zero].each { |window| actions << ["native-rowbinary-#{id}-#{window}", window_sql(native_table, window)] }
    records = {}
    actions.each_with_index do |(label, sql), index|
      records[label] = raw_invocation(evidence, sequence_start + index, label, expected_store: store, sql: sql)
    end
    [records, sequence_start + actions.length]
  end

  def validate_native!(profile, records, helper_profile, library_inventory)
    id = profile.fetch('id')
    table = "w234_native_#{id}"
    create = records.fetch("native-create-#{id}")
    path_record = records.fetch("native-data-path-#{id}")
    # Derive the isolated store from the fixed invocation location, then require
    # that the captured argv selected exactly that store.
    root = File.dirname(File.dirname(path_record.fetch('base')))
    expected_store = File.join(root, 'stores', id)
    store = path_record.fetch('argv').fetch('argv').fetch(3)
    assert!(store == expected_store,
      "native store argv/path mismatch for #{id}")
    data_path = File.expand_path(path_record.fetch('stdout').strip)
    assert!(data_path.start_with?(store + File::SEPARATOR) && File.directory?(data_path) && !File.symlink?(data_path) &&
      File.realpath(data_path) == data_path, "native data path escaped store for #{id}")
    library = helper_profile.fetch('library_part_path')
    assert!(part_inventory(library) == library_inventory, "library part changed before native attach for #{id}")
    attach = records.fetch("native-attach-#{id}")
    check = records.fetch("native-check-#{id}")
    schema = records.fetch("native-schema-#{id}")
    roster = records.fetch("native-roster-#{id}")
    part = records.fetch("native-part-#{id}")
    assert!(check.fetch('stdout') == "all_1_1_0\t1\t\n", "native raw CHECK error/status field differs for #{id}")
    assert!(schema.fetch('stdout') == expected_schema(profile), "native exact schema differs for #{id}")
    assert!(roster.fetch('stdout') == expected_roster(profile), "native actual type/route roster differs for #{id}")
    fields = part.fetch('stdout').force_encoding(Encoding::UTF_8).lines.map { |line| line.chomp.split("\t", -1) }
    attached = File.join(data_path, 'all_1_1_0')
    assert!(fields.size == 1 && fields.first.size == 5 && fields.first[0, 4] == ['all_1_1_0', '6', SYSTEM_MARKS.to_s, 'Wide'] &&
      File.expand_path(fields.first.fetch(4)) == attached && File.directory?(attached) && !File.symlink?(attached),
      "native part query did not identify attached Wide part for #{id}")
    after = part_inventory(attached)
    old = library_inventory.to_h { |item| [item.fetch('path'), item] }
    new_files = after.to_h { |item| [item.fetch('path'), item] }
    removed = (old.keys - new_files.keys).sort
    changed = old.keys.select { |key| new_files.key?(key) && old.fetch(key) != new_files.fetch(key) }.sort
    added = (new_files.keys - old.keys).sort
    assert!(removed.empty? && changed.empty? && [[], [INVALIDATED_FILE]].include?(added),
      "native ATTACH inventory delta exceeds optional invalidated-system-columns file for #{id}")
    if added == [INVALIDATED_FILE]
      names = File.binread(File.join(attached, INVALIDATED_FILE)).split("\n", -1)
      assert!(names.pop == '' && names.sort == INVALIDATED_NAMES.sort, "native invalidated-system-column names differ for #{id}")
    end
    columns = File.binread(File.join(attached, 'columns.txt'))
    assert!(columns == "columns format version: 1\n2 columns:\n`id` UInt64\n`j` #{profile.fetch('type')}\n".b,
      "native columns.txt declaration differs for #{id}")
    codec = File.binread(File.join(attached, 'default_compression_codec.txt')).strip
    metadata = File.binread(File.join(attached, 'metadata_version.txt')).strip
    assert!(codec == 'CODEC(LZ4)' && metadata == '0', "native persisted codec/metadata version differs for #{id}")
    windows = {}
    %w[full middle zero].each do |window|
      output = records.fetch("native-rowbinary-#{id}-#{window}").fetch('stdout')
      expected = expected_bytes(direct_rows, window)
      assert!(output == expected, "native #{window} literal direct-path bytes differ for #{id}")
      file = File.join(root, 'literal_rowbinary', "native-#{id}-#{window}-expected.rowbin")
      literal = File.binread(plain_file!(file, "native #{id} #{window} literal"))
      assert!(literal == expected, "native #{window} independent expected file differs for #{id}")
      windows[window] = { 'bytes' => expected.bytesize, 'sha256' => Digest::SHA256.hexdigest(expected),
        'expected_literal' => File.basename(file), 'capture' => File.basename(records.fetch("native-rowbinary-#{id}-#{window}").fetch('base')) }
    end
    {
      'id' => id, 'table' => table, 'declared_type' => profile.fetch('type'), 'library_part_path' => library,
      'attached_part_path' => attached, 'library_inventory' => library_inventory, 'attached_inventory' => after,
      'removed_paths' => removed, 'changed_paths' => changed, 'added_paths' => added,
      'check_output' => check.fetch('stdout'), 'schema_output' => schema.fetch('stdout'),
      'roster_output' => roster.fetch('stdout'), 'columns_sha256' => Digest::SHA256.hexdigest(columns),
      'default_compression_codec' => codec, 'metadata_version' => metadata, 'windows' => windows,
    }
  end

  def audit(stock_root, evidence_root, helper, helper_sha)
    stock = bounded_root!(stock_root, STOCK_PREFIX, 'stock root')
    evidence = bounded_root!(evidence_root, EVIDENCE_PREFIX, 'evidence root')
    helper = plain_file!(helper, 'prebuilt helper', executable: true)
    assert!(helper_sha.match?(/\A[0-9a-f]{64}\z/) && sha256_file(helper) == helper_sha, 'helper path/hash pin differs')
    assert!(sha256_file(CLICKHOUSE_BIN) == CLICKHOUSE_SHA256, 'runtime binary hash differs from fixed pin')
    stock_audit = verify_stock!(stock)
    input_path = File.join(evidence, 'generated', 'helper-input.json')
    helper_input = read_json(input_path, 'helper input manifest')
    expected_input = {
      'format' => HELPER_INPUT_FORMAT, 'stock_root' => stock,
      'profiles' => PROFILES.map do |profile|
        source = stock_audit.fetch('profiles').find { |item| item.fetch('id') == profile.fetch('id') }
        { 'id' => profile.fetch('id'), 'source_part' => source.fetch('part_path'),
          'library_part' => File.join(evidence, 'generated', 'parts', profile.fetch('id'), 'all_1_1_0') }
      end,
    }
    assert!(helper_input == expected_input, 'helper input manifest does not bind fixed stock parts and generated targets')
    invocation_labels = ['runtime-version-pin', 'runtime-build-pin', 'helper-public-object-roundtrip']
    actions = {}
    first_store = File.join(evidence, 'stores', IDS.first)
    actions['runtime-version-pin'] = raw_invocation(evidence, 1, 'runtime-version-pin', expected_store: first_store,
      sql: 'SELECT version() FORMAT TSVRaw')
    build_sql = "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw"
    actions['runtime-build-pin'] = raw_invocation(evidence, 2, 'runtime-build-pin', expected_store: first_store, sql: build_sql)
    assert!(actions.fetch('runtime-version-pin').fetch('stdout') == "#{CLICKHOUSE_VERSION}\n" &&
      actions.fetch('runtime-build-pin').fetch('stdout') == "VERSION_GITHASH=#{CLICKHOUSE_BUILD}\n", 'paired raw runtime pins differ')
    output_dir = File.join(evidence, 'generated')
    actions['helper-public-object-roundtrip'] = raw_invocation(evidence, 3, 'helper-public-object-roundtrip',
      expected_store: output_dir, sql: nil, helper: helper, helper_input: input_path, helper_output: output_dir)
    helper_output = JSON.parse(actions.fetch('helper-public-object-roundtrip').fetch('stdout').force_encoding(Encoding::UTF_8))
    helper_output, library_inventories, library_inventory_records = validate_helper!(helper_output, helper_input, stock_audit, evidence, helper, helper_sha)
    expected_generated = JSON.parse(File.binread(plain_file!(File.join(output_dir, 'helper-output.json'), 'helper output file')).force_encoding(Encoding::UTF_8))
    assert!(expected_generated == helper_output, 'persisted helper-output.json differs from raw stdout')
    expected_library_index = { 'profiles' => library_inventory_records }
    actual_library_index = read_json(File.join(output_dir, 'library-inventories.json'), 'library inventory index')
    assert!(actual_library_index == expected_library_index, 'library inventory index differs from part bytes')

    native = []
    PROFILES.each do |profile|
      id = profile.fetch('id')
      records, next_sequence = native_actions(evidence, profile, nil, invocation_labels.length + 1)
      invocation_labels.concat(records.keys)
      actions.merge!(records)
      native_record = validate_native!(profile, records, helper_output.fetch('profiles').find { |item| item.fetch('id') == id }, library_inventories.fetch(id))
      case_file = read_json(File.join(evidence, 'cases', "#{id}.json"), "#{id} case record")
      assert!(case_file == native_record, "#{id} case JSON differs from independently replayed raw evidence")
      native << native_record
      invocation_labels = actions.keys
    end
    expected_labels = ['runtime-version-pin', 'runtime-build-pin', 'helper-public-object-roundtrip'] + PROFILES.flat_map do |profile|
      id = profile.fetch('id')
      ["native-create-#{id}", "native-data-path-#{id}", "native-attach-#{id}", "native-check-#{id}",
        "native-schema-#{id}", "native-roster-#{id}", "native-part-#{id}",
        *%w[full middle zero].map { |window| "native-rowbinary-#{id}-#{window}" }]
    end
    expected_labels.each_with_index do |label, index|
      assert!(actions.fetch(label), "missing raw evidence action #{label}")
    end
    assert!(actions.keys == expected_labels, 'paired raw action roster/count/order differs')
    validate_invocation_census!(evidence, expected_labels, [])
    process_count = expected_labels.length

    # The result is validated after all claims have been recomputed from raw
    # files. It is a redundant index, never the source of expected values.
    result = read_json(File.join(evidence, 'result.json'), 'paired result')
    expected_code_pins = CODE_PATHS.to_h { |path| [path, sha256_file(File.join(REPO_ROOT, path))] }
    helper_raw = actions.fetch('helper-public-object-roundtrip').fetch('stdout')
    assert!(result.fetch('format') == RESULT_FORMAT && result.fetch('classification') == 'object_recursive_qbit_paired_profiles_observed' &&
      result.fetch('success') == true, 'paired result success envelope differs')
    assert!(result.fetch('stock_root') == stock && result.fetch('evidence_root') == evidence &&
      result.fetch('source_pin') == { 'root' => SOURCE_ROOT, 'revision' => SOURCE_REVISION }, 'result source/root pins differ')
    # Runner emits this exact field name; source revision and build hash are intentionally separate pins.
    expected_runtime_pin = { 'binary' => CLICKHOUSE_BIN, 'sha256' => CLICKHOUSE_SHA256,
      'version' => CLICKHOUSE_VERSION, 'build_hash' => CLICKHOUSE_BUILD,
      'source_revision_is_separately_pinned_not_asserted_as_runtime_lineage' => true,
      'version_capture' => '0001-runtime-version-pin', 'build_capture' => '0002-runtime-build-pin' }
    assert!(result.fetch('runtime_pin') == expected_runtime_pin, 'paired runtime result summary differs from raw SQL pins')
    assert!(result.fetch('helper_path') == helper && result.fetch('helper_sha256') == helper_sha &&
      result.fetch('helper_sha256_after') == helper_sha, 'helper path/hash summary differs')
    assert!(result.fetch('helper_input_path') == input_path && result.fetch('helper_input_sha256') == sha256_file(input_path) &&
      result.fetch('helper_stdout_sha256') == Digest::SHA256.hexdigest(helper_raw), 'helper input/output digest summary differs')
    assert!(result.fetch('code_pins') == expected_code_pins, 'source script/helper/auditor/recorder code pins differ')
    assert!(result.fetch('profiles') == PROFILES && result.fetch('stock_profiles') == stock_audit.fetch('profiles'),
      'profile/stock-part summary differs')
    assert!(result.fetch('helper_output') == helper_output && result.fetch('library_inventories') == library_inventories &&
      result.fetch('native_profiles') == native, 'helper/library/native summary differs from raw replay')
    assert!(result.fetch('evidence_process_count') == process_count && result.fetch('evidence_process_labels') == expected_labels,
      'paired process count/labels differ from independently derived action plan')
    expected_scope = 'three fixed Object runtime profiles: typed Dynamic q, inferred Dynamic q, and forced-shared q; six-row/three-mark actuals Array(QBit), named Tuple(QBit, UInt8), and Map(String, QBit); public read/write, native ATTACH/CHECK, and literal direct-path RowBinary windows; no all-types or performance claim'
    assert!(result.fetch('scope') == expected_scope, 'scope statement overclaims or differs')
    stock_audit.fetch('profiles').each do |profile|
      assert!(part_inventory(profile.fetch('part_path')) == profile.fetch('part_inventory'),
        "stock part changed after paired verification for #{profile.fetch('id')}")
    end
    calculated_inventory = root_inventory(evidence)
    captured_inventory = read_json(File.join(evidence, 'capture_inventory.json'), 'paired capture inventory')
    assert!(captured_inventory == calculated_inventory, 'paired raw file/Atomic-alias inventory differs')
    puts "W234 independent audit: stock=29 raw actions; paired=#{process_count} raw actions; 3 profiles; exact CHECK/status, public helper values, native ATTACH, and full/middle/zero literals agree."
    true
  rescue KeyError, JSON::ParserError => error
    fail!("malformed capture: #{error.message}")
  end

  def main(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/check_object_recursive_qbit_evidence_w234.rb --stock-root ROOT --evidence-root ROOT --helper BIN --helper-sha256 SHA'
      opts.on('--stock-root PATH') { |value| options[:stock_root] = value }
      opts.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
      opts.on('--helper PATH') { |value| options[:helper] = value }
      opts.on('--helper-sha256 SHA') { |value| options[:helper_sha256] = value }
    end
    parser.parse!(argv)
    assert!(argv.empty? && %i[stock_root evidence_root helper helper_sha256].all? { |key| options.key?(key) }, parser.to_s)
    audit(options.fetch(:stock_root), options.fetch(:evidence_root), options.fetch(:helper), options.fetch(:helper_sha256))
  rescue StandardError => error
    warn "W234 independent audit failed: #{error.class}: #{error.message}"
    false
  end
end

exit(CheckObjectRecursiveQBitEvidenceW234.main(ARGV) ? 0 : 1) if $PROGRAM_NAME == __FILE__
