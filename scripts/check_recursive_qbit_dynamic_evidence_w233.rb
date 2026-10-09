#!/usr/bin/env ruby
# Independent read-only audit of the fixed W233 stock, public helper, and
# native ATTACH captures. This auditor does not load the runner or invoke tools.

require 'digest'
require 'find'
require 'json'
require 'optparse'

module CheckRecursiveQBitDynamicEvidenceW233
  extend self

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
  PROFILES = [
    { 'id' => 'root_dynamic', 'column' => 'root_d', 'type' => 'Dynamic(max_types=4)' },
    { 'id' => 'carrier_dynamic', 'column' => 'carrier', 'type' => 'Array(Dynamic(max_types=4))' },
    { 'id' => 'shared_dynamic', 'column' => 'shared_d', 'type' => 'Dynamic(max_types=0)' },
  ].freeze
  IDS = [1, 2, 3, 4, 5, 6].freeze
  MARK_ROWS = [2, 2, 2].freeze
  SYSTEM_MARKS = 4
  SOURCE_LABELS = %w[
    runtime-version runtime-build create insert-rowbinary cast-map-diagnostic check schema
    root-roster carrier-roster part rowbinary-full rowbinary-middle rowbinary-zero
  ].freeze
  SETTINGS = [
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
  INVALIDATED_FILE = 'invalidated_system_columns.txt'.freeze
  INVALIDATED_NAMES = %w[_block_number _block_offset].freeze
  MAX_FILES = 4096
  MAX_TOTAL_BYTES = 64 * 1024 * 1024
  MAX_TREE_ENTRIES = 4096
  MAX_TREE_BYTES = 64 * 1024 * 1024
  MEMORY_LIMIT_BYTES = 1_073_741_824
  PROCESS_TIMEOUT_SECONDS = 90
  HELPER_TIMEOUT_SECONDS = 600

  # The values are frozen RowBinary Dynamic descriptor/body literals. The
  # separate Ruby encoder below only adds row keys and Array(Dynamic) counts.
  ROOT_HEX = [
    '1e36070900',
    '1e3607090109010203040506070809',
    '20020171360709016e0109ff000102040810204007',
    '271536070901016109090807060504030201',
    '1e2a0236070904010009020406080a0c0e1012',
    '00',
  ].freeze

  def fail!(message)
    raise "W233 AUDIT FAIL: #{message}"
  end

  def assert!(condition, message)
    fail!(message) unless condition
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

  def read_json(path, label)
    JSON.parse(File.binread(plain_file!(path, label)).force_encoding(Encoding::UTF_8))
  rescue JSON::ParserError => error
    fail!("malformed #{label}: #{error.message}")
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

  def uint64_le(value)
    Array.new(8) { |index| (value >> (8 * index)) & 0xff }.pack('C*').b
  end

  def root_values
    ROOT_HEX.map { |value| [value].pack('H*').b }
  end

  def carrier_values
    root_values.each_with_index.map { |value, index| index.zero? ? "\x00".b : "\x01".b + value }
  end

  def stock_rows
    root = root_values
    carrier = carrier_values
    IDS.each_index.map do |index|
      uint64_le(IDS.fetch(index)) + root.fetch(index) + root.fetch(index) + carrier.fetch(index)
    end
  end

  def stock_insert_rows
    root = root_values
    carrier = carrier_values
    IDS.each_index.map do |index|
      uint64_le(IDS.fetch(index)) + root.fetch(index) + carrier.fetch(index) + root.fetch(index)
    end
  end

  def native_rows(profile)
    values = profile.fetch('id') == 'carrier_dynamic' ? carrier_values : root_values
    IDS.each_index.map { |index| uint64_le(IDS.fetch(index)) + values.fetch(index) }
  end

  def indexes(window)
    { 'full' => (0...IDS.length).to_a, 'middle' => [2, 3], 'zero' => [] }.fetch(window)
  end

  def expected_window(rows, window)
    indexes(window).map { |index| rows.fetch(index) }.join.b
  end

  def expected_value_hex(profile)
    profile.fetch('id') == 'carrier_dynamic' ? carrier_values.map { |value| value.unpack1('H*') } : ROOT_HEX
  end

  def part_inventory(path)
    root = plain_dir!(path, 'part directory')
    entries = []
    count = 0
    bytes = 0
    Find.find(root) do |entry|
      next if entry == root
      count += 1
      assert!(count <= MAX_TREE_ENTRIES && !File.symlink?(entry), 'part inventory exceeds bound or contains symlink')
      next if File.directory?(entry)
      assert!(File.file?(entry), 'part has unsupported filesystem entry')
      size = File.size(entry)
      bytes += size
      assert!(bytes <= MAX_TREE_BYTES, 'part bytes exceed cap')
      entries << { 'path' => entry[(root.length + 1)..-1], 'size' => size, 'sha256' => sha256_file(entry) }
    end
    entries.sort_by { |entry| entry.fetch('path') }
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
        fail!("unsupported capture symlink: #{entry}")
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

  def root_inventory(path)
    root = plain_dir!(path, 'capture root')
    entries = []
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
      assert!(File.file?(entry), "capture contains unsupported file: #{entry}")
      count += 1
      bytes += File.size(entry)
      assert!(count <= MAX_FILES && bytes <= MAX_TOTAL_BYTES, 'capture exceeds file/byte cap')
      next if entry == File.join(root, 'capture_inventory.json')
      entries << { 'path' => entry[(root.length + 1)..-1], 'size' => File.size(entry), 'sha256' => sha256_file(entry) }
    end
    entries.sort_by { |entry| entry.fetch('path') }
  end

  def tsv_row!(bytes, count, label)
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    assert!(text.valid_encoding?, "#{label} is not UTF-8 TSV")
    lines = text.lines.map { |line| line.chomp.sub(/\r\z/, '') }
    assert!(lines.length == 1, "#{label} expected one TSV row")
    fields = lines.first.split("\t", -1)
    assert!(fields.length == count, "#{label} field count differs")
    fields
  end

  def raw_invocation(root, sequence, label, store, sql, input: nil, command: :clickhouse, helper: nil, helper_input: nil, helper_output: nil)
    stem = format('%04d-%s', sequence, label)
    base = File.join(root, 'invocations', stem)
    argv_path = plain_file!(base + '.argv.json', "#{label} argv capture")
    status_path = plain_file!(base + '.status.json', "#{label} status capture")
    sql_path = plain_file!(base + '.sql', "#{label} SQL capture")
    out_path = plain_file!(base + '.stdout', "#{label} stdout capture")
    err_path = plain_file!(base + '.stderr', "#{label} stderr capture")
    argv_record = read_json(argv_path, "#{label} argv")
    status = read_json(status_path, "#{label} status")
    sql_bytes = File.binread(sql_path)
    stdout = File.binread(out_path)
    stderr = File.binread(err_path)
    assert!(argv_record.fetch('label') == label && status.fetch('label') == label, "#{label} raw label differs")
    expected_sql = sql.nil? ? "\n" : (sql.end_with?("\n") ? sql : "#{sql}\n")
    assert!(sql_bytes == expected_sql.b, "#{label} raw SQL differs")
    assert!(argv_record.fetch('environment') == { 'TZ' => 'UTC' }, "#{label} timezone capture differs")
    expected_timeout = command == :helper ? HELPER_TIMEOUT_SECONDS : PROCESS_TIMEOUT_SECONDS
    assert!(argv_record.fetch('timeout_seconds') == expected_timeout, "#{label} timeout cap differs")
    if input
      stdin_path = plain_file!(base + '.stdin.bin', "#{label} stdin capture")
      stdin_bytes = File.binread(stdin_path)
      assert!(stdin_bytes == input && argv_record.fetch('stdin_bytes') == input.bytesize &&
        argv_record.fetch('stdin_sha256') == Digest::SHA256.hexdigest(input), "#{label} stdin literal differs")
    else
      assert!(!File.exist?(base + '.stdin.bin') && argv_record['stdin_bytes'].nil? && argv_record['stdin_sha256'].nil?,
        "#{label} unexpected stdin capture")
    end
    if command == :helper
      expected_argv = [helper, helper_input, helper_output]
    else
      expected_argv = [CLICKHOUSE_BIN, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
        '--max_insert_threads=1', '--max_execution_time=30', "--max_memory_usage=#{MEMORY_LIMIT_BYTES}",
        '--print_pretty_type_names=0', '--flatten_nested=0', '--multiquery', '--query', sql]
    end
    assert!(argv_record.fetch('argv') == expected_argv, "#{label} exact process argv differs")
    success = status.fetch('classification') == 'process_success' && status.fetch('exitstatus') == 0 &&
      status.fetch('signaled') == false && status.fetch('timed_out') == false && status.fetch('spawn_error').nil?
    assert!(success, "#{label} raw process status is not successful")
    assert!(status.fetch('stdout_bytes') == stdout.bytesize && status.fetch('stderr_bytes') == stderr.bytesize,
      "#{label} raw status byte census differs")
    { 'label' => label, 'base' => base, 'status' => status, 'argv' => argv_record,
      'sql' => sql_bytes, 'stdout' => stdout, 'stderr' => stderr }
  rescue KeyError, JSON::ParserError => error
    fail!("malformed raw invocation #{label}: #{error.message}")
  end

  def source_sql(label, root)
    table = 'w233_recursive_qbit_dynamic'
    case label
    when 'runtime-version' then 'SELECT version() FORMAT TSVRaw'
    when 'runtime-build' then "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw"
    when 'create'
      "CREATE TABLE default.#{table} (id UInt64, root_d Dynamic(max_types=4), carrier Array(Dynamic(max_types=4)), shared_d Dynamic(max_types=0)) " \
        "ENGINE=MergeTree ORDER BY id SETTINGS #{SETTINGS.join(', ')}"
    when 'insert-rowbinary' then "INSERT INTO default.#{table} (id, root_d, carrier, shared_d) FORMAT RowBinary"
    when 'cast-map-diagnostic'
      qbit = "CAST([9, 8, 7, 6, 5, 4, 3, 2, 1], 'QBit(Int8, 9)')"
      map = "CAST(map('a', #{qbit}), 'Map(String, QBit(Int8, 9))')"
      "SELECT dynamicType(CAST(#{map}, 'Dynamic(max_types=4)')) SETTINGS print_pretty_type_names=0 FORMAT TSVRaw"
    when 'check' then "CHECK TABLE default.#{table} FORMAT TSVRaw"
    when 'schema'
      "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw"
    when 'root-roster'
      "SELECT id, if(isNull(root_d), 'NULL', dynamicType(root_d)), " \
        "if(isNull(root_d), '-', toString(toUInt8(isDynamicElementInSharedData(root_d)))), " \
        "if(isNull(shared_d), 'NULL', dynamicType(shared_d)), " \
        "if(isNull(shared_d), '-', toString(toUInt8(isDynamicElementInSharedData(shared_d)))) " \
        "FROM default.#{table} ORDER BY id SETTINGS print_pretty_type_names=0 FORMAT TSVRaw"
    when 'carrier-roster'
      "SELECT id, arrayStringConcat(arrayMap(x -> if(isNull(x), 'NULL', " \
        "concat(dynamicType(x), ':', toString(toUInt8(isDynamicElementInSharedData(x))))), carrier), '|') " \
        "FROM default.#{table} ORDER BY id SETTINGS print_pretty_type_names=0 FORMAT TSVRaw"
    when 'part'
      "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts " \
        "WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw"
    when 'rowbinary-full' then "SELECT id, root_d, shared_d, carrier FROM default.#{table} ORDER BY id FORMAT RowBinary"
    when 'rowbinary-middle' then "SELECT id, root_d, shared_d, carrier FROM default.#{table} WHERE id BETWEEN 3 AND 4 ORDER BY id FORMAT RowBinary"
    when 'rowbinary-zero' then "SELECT id, root_d, shared_d, carrier FROM default.#{table} WHERE id=0 ORDER BY id FORMAT RowBinary"
    else fail!("unknown stock label #{label}")
    end
  end

  def source_plan(root)
    store = File.join(root, 'store')
    SOURCE_LABELS.map do |label|
      input = label == 'insert-rowbinary' ? stock_insert_rows.join.b : nil
      [label, store, source_sql(label, root), input]
    end
  end

  def check_source!(root)
    assert!(Dir.children(root).sort == %w[capture_inventory.json invocations literal_rowbinary part_inventory.json store witnesses.json].sort,
      'stock root inventory roster differs')
    plan = source_plan(root)
    records = {}
    plan.each_with_index do |(label, store, sql, input), index|
      records[label] = raw_invocation(root, index + 1, label, store, sql, input: input)
    end
    assert!(records.fetch('runtime-version').fetch('stdout') == "#{CLICKHOUSE_VERSION}\n", 'stock runtime version differs')
    assert!(records.fetch('runtime-build').fetch('stdout') == "VERSION_GITHASH=#{CLICKHOUSE_BUILD}\n", 'stock runtime build differs')
    assert!(records.fetch('check').fetch('stdout') == "all_1_1_0\t1\t\n", 'stock raw CHECK output is not exact success')
    expected_schema = "id\tUInt64\nroot_d\tDynamic(max_types=4)\ncarrier\tArray(Dynamic(max_types=4))\nshared_d\tDynamic(max_types=0)\n"
    assert!(records.fetch('schema').fetch('stdout') == expected_schema, 'stock raw schema differs')
    assert!(records.fetch('cast-map-diagnostic').fetch('stdout') == "Map(String, QBit(Int8, 9))\n",
      'stock SQL CAST nominal diagnostic differs')
    expected_root = [
      "1\tArray(QBit(Int8, 9))\t0\tArray(QBit(Int8, 9))\t1",
      "2\tArray(QBit(Int8, 9))\t0\tArray(QBit(Int8, 9))\t1",
      "3\tTuple(q QBit(Int8, 9), n UInt8)\t0\tTuple(q QBit(Int8, 9), n UInt8)\t1",
      "4\tMap(String, QBit(Int8, 9))\t0\tMap(String, QBit(Int8, 9))\t1",
      "5\tArray(Variant(QBit(Int8, 9), UInt64))\t0\tArray(Variant(QBit(Int8, 9), UInt64))\t1",
      "6\tNULL\t-\tNULL\t-",
    ].join("\n") + "\n"
    assert!(records.fetch('root-roster').fetch('stdout') == expected_root, 'stock root ordinary/shared actual roster differs')
    expected_carrier = [
      "1\t", "2\tArray(QBit(Int8, 9)):0", "3\tTuple(q QBit(Int8, 9), n UInt8):0",
      "4\tMap(String, QBit(Int8, 9)):0", "5\tArray(Variant(QBit(Int8, 9), UInt64)):0", "6\tNULL",
    ].join("\n") + "\n"
    assert!(records.fetch('carrier-roster').fetch('stdout') == expected_carrier, 'stock Array(Dynamic) roster differs')
    expected_insert = stock_insert_rows.join.b
    assert!(File.binread(File.join(root, 'literal_rowbinary', 'insert-schema-order.rowbin')) == expected_insert,
      'stock saved INSERT literal differs')
    rows = stock_rows
    %w[full middle zero].each do |window|
      expected = expected_window(rows, window)
      record = records.fetch("rowbinary-#{window}")
      assert!(record.fetch('stdout') == expected, "stock #{window} raw RowBinary output differs from fixed literal")
      assert!(File.binread(File.join(root, 'literal_rowbinary', "#{window}.rowbin")) == expected,
        "stock #{window} independent saved literal differs")
    end
    fields = tsv_row!(records.fetch('part').fetch('stdout'), 5, 'stock part')
    assert!(fields[0, 4] == ['all_1_1_0', '6', SYSTEM_MARKS.to_s, 'Wide'], 'stock part rows/marks/type differs')
    part = File.expand_path(fields.fetch(4))
    assert!(part.start_with?(File.join(root, 'store') + File::SEPARATOR), 'stock part is outside isolated store')
    physical = part_inventory(part)
    part_manifest = read_json(File.join(root, 'part_inventory.json'), 'stock part inventory')
    assert!(part_manifest.fetch('part_path') == part && part_manifest.fetch('files') == physical,
      'stock part raw inventory differs')
    witnesses = read_json(File.join(root, 'witnesses.json'), 'stock witness metadata')
    assert!(witnesses.fetch('source_reference') == "#{SOURCE_ROOT}@#{SOURCE_REVISION}" &&
      witnesses.fetch('runtime').fetch('sha256') == CLICKHOUSE_SHA256 && witnesses.fetch('part_path') == part,
      'stock witness pin bindings differ (raw status/output remain the evidence authority)')
    inventory = root_inventory(root)
    manifest = read_json(File.join(root, 'capture_inventory.json'), 'stock raw inventory')
    assert!(manifest.fetch('files') == inventory, 'stock root file inventory differs from current raw files')
    { 'records' => records, 'part_path' => part, 'part_inventory' => physical, 'capture_inventory' => inventory }
  end

  def clickhouse_argv(store, sql)
    [CLICKHOUSE_BIN, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
      '--max_insert_threads=1', '--max_execution_time=30', "--max_memory_usage=#{MEMORY_LIMIT_BYTES}",
      '--print_pretty_type_names=0', '--flatten_nested=0', '--multiquery', '--query', sql]
  end

  def evidence_process_plan(evidence_root, helper, helper_input, generated)
    plan = []
    pin = File.join(evidence_root, 'stores', 'pins')
    plan << ['runtime-version-pin', pin, 'SELECT version() FORMAT TSVRaw', :clickhouse]
    plan << ['runtime-build-pin', pin,
      "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw", :clickhouse]
    plan << ['helper-read-write-roundtrip', generated, nil, :helper]
    PROFILES.each do |profile|
      id = profile.fetch('id')
      table = "w233_native_#{id}"
      store = File.join(evidence_root, 'stores', id)
      create = "CREATE TABLE default.#{table} (id UInt64, #{profile.fetch('column')} #{profile.fetch('type')} CODEC(LZ4)) " \
        "ENGINE=MergeTree ORDER BY id SETTINGS #{SETTINGS.join(', ')}"
      plan << ["native-create-#{id}", store, create, :clickhouse]
      plan << ["native-data-path-#{id}", store,
        "SELECT arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw", :clickhouse]
      plan << ["native-attach-#{id}", store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'", :clickhouse]
      plan << ["native-check-#{id}", store, "CHECK TABLE default.#{table} FORMAT TSVRaw", :clickhouse]
      plan << ["native-schema-#{id}", store,
        "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw", :clickhouse]
      plan << ["native-part-#{id}", store,
        "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw", :clickhouse]
      %w[full middle zero].each do |window|
        predicate = { 'full' => '', 'middle' => ' WHERE id BETWEEN 3 AND 4', 'zero' => ' WHERE id=0' }.fetch(window)
        sql = "SELECT id, #{profile.fetch('column')} FROM default.#{table}#{predicate} ORDER BY id FORMAT RowBinary"
        plan << ["native-rowbinary-#{id}-#{window}", store, sql, :clickhouse]
      end
    end
    plan
  end

  def read_plan!(root, plan, helper: nil, helper_input: nil, helper_output: nil)
    records = {}
    plan.each_with_index do |(label, store, sql, command), index|
      records[label] = raw_invocation(root, index + 1, label, store, sql, command: command,
        helper: helper, helper_input: helper_input, helper_output: helper_output)
    end
    expected_files = plan.each_with_index.flat_map do |(label, _store, _sql, _command), index|
      stem = format('%04d-%s', index + 1, label)
      %w[.argv.json .sql .stdout .stderr .status.json].map { |suffix| stem + suffix }
    end.sort
    actual_files = Dir.children(File.join(root, 'invocations')).sort
    assert!(actual_files == expected_files, 'raw invocation file roster differs from fixed plan')
    records
  end

  def validate_helper_output!(stock, stock_part, evidence, helper, helper_sha)
    input_path = File.join(evidence, 'generated', 'helper-input.json')
    generated = File.join(evidence, 'generated')
    expected_input = {
      'format' => HELPER_INPUT_FORMAT,
      'stock_root' => stock,
      'profiles' => PROFILES.map do |profile|
        { 'id' => profile.fetch('id'), 'source_part' => stock_part,
          'library_part' => File.join(generated, 'parts', profile.fetch('id'), 'all_1_1_0') }
      end,
    }
    input = read_json(input_path, 'helper input')
    assert!(input == expected_input, 'helper input differs from independently fixed profile/path roster')
    raw = raw_invocation(evidence, 3, 'helper-read-write-roundtrip', generated, nil,
      command: :helper, helper: helper, helper_input: input_path, helper_output: generated)
    output = JSON.parse(raw.fetch('stdout').force_encoding(Encoding::UTF_8))
    assert!(output.keys.sort == %w[format profile_ids profiles].sort && output.fetch('format') == HELPER_OUTPUT_FORMAT &&
      output.fetch('profile_ids') == PROFILES.map { |profile| profile.fetch('id') }, 'raw helper output envelope differs')
    assert!(read_json(File.join(generated, 'helper-output.json'), 'saved helper output') == output,
      'saved helper output differs from raw helper stdout')
    helper_profiles = output.fetch('profiles')
    assert!(helper_profiles.length == PROFILES.length, 'helper output profile count differs')
    library_inventory = {}
    helper_profiles.zip(PROFILES).each do |actual, profile|
      fields = %w[column declared_type id library_part_path library source_part_path source].sort
      assert!(actual.keys.sort == fields, "helper output fields differ for #{profile.fetch('id')}")
      expected_part = File.join(generated, 'parts', profile.fetch('id'), 'all_1_1_0')
      assert!(actual.fetch('id') == profile.fetch('id') && actual.fetch('column') == profile.fetch('column') &&
        actual.fetch('declared_type') == profile.fetch('type') && actual.fetch('source_part_path') == stock_part &&
        actual.fetch('library_part_path') == expected_part, "helper output nominal/path binding differs for #{profile.fetch('id')}")
      sites = profile.fetch('id') == 'carrier_dynamic' ? ['root.elements'] : ['root']
      values = expected_value_hex(profile)
      [actual.fetch('source'), actual.fetch('library')].each_with_index do |side, index|
        label = index.zero? ? 'source' : 'library'
        expected_fields = %w[dynamic_site_paths exact_type_and_literal_checks full_rowbinary_hex mark_row_counts middle_rowbinary_hex physical_stream_names row_count schema_declaration typed_full_rowbinary_hex typed_middle_rowbinary_hex windows].sort
        assert!(side.keys.sort == expected_fields, "helper #{label} evidence fields differ for #{profile.fetch('id')}")
        assert!(side.fetch('schema_declaration') == profile.fetch('type') && side.fetch('row_count') == 6 &&
          side.fetch('mark_row_counts') == MARK_ROWS && side.fetch('dynamic_site_paths') == sites &&
          side.fetch('windows') == %w[full middle zero_marks zero_candidates eof] &&
          side.fetch('exact_type_and_literal_checks') == true,
          "helper #{label} scan/type/site record differs for #{profile.fetch('id')}")
        assert!(side.fetch('full_rowbinary_hex') == values &&
          side.fetch('typed_full_rowbinary_hex') == values && side.fetch('middle_rowbinary_hex') == values[2, 2] &&
          side.fetch('typed_middle_rowbinary_hex') == values[2, 2] && side.fetch('physical_stream_names').is_a?(Array) &&
          !side.fetch('physical_stream_names').empty? && side.fetch('physical_stream_names').uniq == side.fetch('physical_stream_names'),
          "helper #{label} exact literals/physical roster differ for #{profile.fetch('id')}")
      end
      assert!(actual.fetch('source').fetch('physical_stream_names') == actual.fetch('library').fetch('physical_stream_names'),
        "stock and library physical stream rosters differ for #{profile.fetch('id')}")
      library_inventory[profile.fetch('id')] = part_inventory(expected_part)
    end
    library_manifest = {
      'format' => 'recursive_qbit_dynamic_w233_library_physical_v1',
      'profiles' => PROFILES.map do |profile|
        { 'id' => profile.fetch('id'), 'path' => File.join(generated, 'parts', profile.fetch('id'), 'all_1_1_0'),
          'inventory' => library_inventory.fetch(profile.fetch('id')) }
      end,
    }
    assert!(read_json(File.join(generated, 'library-physical.json'), 'library physical inventory') == library_manifest,
      'library physical inventory sidecar differs from current part files')
    { 'output' => output, 'input_sha256' => sha256_file(input_path),
      'stdout_sha256' => Digest::SHA256.hexdigest(raw.fetch('stdout')), 'library_inventory' => library_inventory }
  rescue JSON::ParserError => error
    fail!("malformed helper stdout JSON: #{error.message}")
  end

  def validate_native_profiles!(evidence, records, helper_output, library_inventory)
    output_by_id = helper_output.fetch('profiles').to_h { |item| [item.fetch('id'), item] }
    reconstructed = []
    PROFILES.each do |profile|
      id = profile.fetch('id')
      table = "w233_native_#{id}"
      store = File.join(evidence, 'stores', id)
      path_record = records.fetch("native-data-path-#{id}")
      data_path = File.expand_path(path_record.fetch('stdout').strip)
      assert!(data_path.start_with?(store + File::SEPARATOR), "native store path escaped for #{id}")
      plain_dir!(data_path, "native data path for #{id}")
      detached = File.join(data_path, 'detached')
      plain_dir!(detached, "native detached path for #{id}")
      check = records.fetch("native-check-#{id}").fetch('stdout')
      schema = records.fetch("native-schema-#{id}").fetch('stdout')
      assert!(check == "all_1_1_0\t1\t\n", "native raw CHECK result differs for #{id}")
      assert!(schema == "id\tUInt64\n#{profile.fetch('column')}\t#{profile.fetch('type')}\n",
        "native exact schema differs for #{id}")
      fields = tsv_row!(records.fetch("native-part-#{id}").fetch('stdout'), 5, "native part #{id}")
      attached = File.join(data_path, 'all_1_1_0')
      assert!(fields[0, 4] == ['all_1_1_0', '6', SYSTEM_MARKS.to_s, 'Wide'] &&
        File.expand_path(fields.fetch(4)) == attached, "native part census/path differs for #{id}")
      library = output_by_id.fetch(id).fetch('library_part_path')
      before = part_inventory(library)
      after = part_inventory(attached)
      first = before.to_h { |entry| [entry.fetch('path'), entry] }
      second = after.to_h { |entry| [entry.fetch('path'), entry] }
      removed = (first.keys - second.keys).sort
      changed = first.keys.select { |path| second.key?(path) && first.fetch(path) != second.fetch(path) }.sort
      added = (second.keys - first.keys).sort
      assert!(removed.empty? && changed.empty? && added == [INVALIDATED_FILE], "ATTACH inventory delta differs for #{id}")
      invalidated = File.binread(File.join(attached, INVALIDATED_FILE)).split("\n", -1)
      assert!(invalidated.pop == '' && invalidated.sort == INVALIDATED_NAMES.sort, "ATTACH invalidation roster differs for #{id}")
      columns = File.binread(File.join(attached, 'columns.txt'))
      expected_columns = "columns format version: 1\n2 columns:\n`id` UInt64\n`#{profile.fetch('column')}` #{profile.fetch('type')}\n".b
      assert!(columns == expected_columns, "attached columns metadata differs for #{id}")
      codec = File.binread(File.join(attached, 'default_compression_codec.txt')).strip
      metadata = File.binread(File.join(attached, 'metadata_version.txt')).strip
      assert!(codec == 'CODEC(LZ4)' && metadata == '0', "attached codec or metadata differs for #{id}")
      windows = {}
      %w[full middle zero].each do |window|
        raw = records.fetch("native-rowbinary-#{id}-#{window}").fetch('stdout')
        expected = expected_window(native_rows(profile), window)
        assert!(raw == expected, "native #{window} RowBinary differs from independent literal for #{id}")
        windows[window] = { 'bytes' => expected.bytesize, 'sha256' => Digest::SHA256.hexdigest(expected),
          'capture' => File.basename(records.fetch("native-rowbinary-#{id}-#{window}").fetch('base')) }
      end
      record = {
        'id' => id, 'table' => table, 'declared_type' => profile.fetch('type'),
        'library_part_path' => library, 'attached_part_path' => attached,
        'library_inventory' => before, 'attached_inventory' => after,
        'removed_paths' => removed, 'changed_paths' => changed, 'added_paths' => added,
        'check_output' => check, 'schema_output' => schema,
        'columns_sha256' => Digest::SHA256.hexdigest(columns), 'default_compression_codec' => codec,
        'metadata_version' => metadata, 'windows' => windows,
      }
      assert!(read_json(File.join(evidence, 'cases', "#{id}.json"), "native case #{id}") == record,
        "native case summary differs from raw process/part reconstruction for #{id}")
      reconstructed << record
    end
    reconstructed
  end

  def audit(stock_arg, evidence_arg, helper_arg, helper_sha)
    stock = bounded_root!(stock_arg, STOCK_PREFIX, 'stock root')
    evidence = bounded_root!(evidence_arg, EVIDENCE_PREFIX, 'evidence root')
    helper = plain_file!(helper_arg, 'prebuilt Crystal helper', executable: true)
    assert!(/\A[0-9a-f]{64}\z/.match?(helper_sha) && sha256_file(helper) == helper_sha, 'helper path/SHA binding differs')
    binary = plain_file!(CLICKHOUSE_BIN, 'pinned ClickHouse runtime', executable: true)
    assert!(sha256_file(binary) == CLICKHOUSE_SHA256, 'ClickHouse binary SHA pin differs')
    source = check_source!(stock)
    assert!(Dir.children(evidence).sort == %w[capture_inventory.json cases generated invocations result.json stores].sort,
      'evidence root layout differs')
    assert!(Dir.children(File.join(evidence, 'cases')).sort == PROFILES.map { |p| "#{p.fetch('id')}.json" }.sort,
      'evidence case roster differs')
    assert!(Dir.children(File.join(evidence, 'generated')).sort == %w[helper-input.json helper-output.json library-physical.json parts].sort,
      'generated helper artifact roster differs')
    assert!(Dir.children(File.join(evidence, 'generated', 'parts')).sort == PROFILES.map { |p| p.fetch('id') }.sort,
      'library part profile directory roster differs')
    assert!(Dir.children(File.join(evidence, 'stores')).sort == (PROFILES.map { |p| p.fetch('id') } + ['pins']).sort,
      'native isolated store roster differs')
    PROFILES.each do |profile|
      assert!(Dir.children(File.join(evidence, 'generated', 'parts', profile.fetch('id'))).sort == ['all_1_1_0'],
        "library part path roster differs for #{profile.fetch('id')}")
    end
    generated = File.join(evidence, 'generated')
    plan = evidence_process_plan(evidence, helper, File.join(generated, 'helper-input.json'), generated)
    records = read_plan!(evidence, plan, helper: helper,
      helper_input: File.join(generated, 'helper-input.json'), helper_output: generated)
    assert!(records.fetch('runtime-version-pin').fetch('stdout') == "#{CLICKHOUSE_VERSION}\n" &&
      records.fetch('runtime-build-pin').fetch('stdout') == "VERSION_GITHASH=#{CLICKHOUSE_BUILD}\n",
      'paired runtime raw SQL pins differ')
    helper_audit = validate_helper_output!(stock, source.fetch('part_path'), evidence, helper, helper_sha)
    native_profiles = validate_native_profiles!(evidence, records, helper_audit.fetch('output'), helper_audit.fetch('library_inventory'))
    assert!(part_inventory(source.fetch('part_path')) == source.fetch('part_inventory'),
      'stock part changed during paired helper/native phase')

    result = read_json(File.join(evidence, 'result.json'), 'paired result')
    assert!(result.fetch('format') == RESULT_FORMAT &&
      result.fetch('classification') == 'recursive_qbit_dynamic_paired_profiles_observed' && result.fetch('success') == true,
      'paired result summary envelope differs (it is checked only after raw evidence)')
    assert!(result.fetch('stock_root') == stock && result.fetch('evidence_root') == evidence &&
      result.fetch('source_pin') == { 'root' => SOURCE_ROOT, 'revision' => SOURCE_REVISION },
      'paired result root/source pins differ')
    runtime_pin = { 'binary' => binary, 'sha256' => CLICKHOUSE_SHA256, 'version' => CLICKHOUSE_VERSION,
      'build_hash' => CLICKHOUSE_BUILD, 'source_correlation' => 'source revision and runtime build are pinned separately' }
    assert!(result.fetch('runtime_pin') == runtime_pin, 'paired runtime pin summary differs')
    assert!(result.fetch('helper_path') == helper && result.fetch('helper_sha256') == helper_sha &&
      result.fetch('helper_sha256_after') == helper_sha, 'paired helper hash summary differs')
    input_path = File.join(generated, 'helper-input.json')
    helper_raw = records.fetch('helper-read-write-roundtrip').fetch('stdout')
    assert!(result.fetch('helper_input_path') == input_path && result.fetch('helper_input_sha256') == sha256_file(input_path) &&
      result.fetch('helper_stdout_sha256') == Digest::SHA256.hexdigest(helper_raw) &&
      result.fetch('helper_output') == helper_audit.fetch('output'), 'paired helper hashes/content differ from raw captures')
    assert!(result.fetch('profiles') == PROFILES && result.fetch('stock_part_path') == source.fetch('part_path') &&
      result.fetch('stock_part_inventory_before') == source.fetch('part_inventory') &&
      result.fetch('stock_part_inventory_after') == source.fetch('part_inventory'), 'paired stock binding/inventory differs')
    assert!(result.fetch('library_inventories') == helper_audit.fetch('library_inventory') &&
      result.fetch('native_profiles') == native_profiles, 'paired helper/native inventory records differ')
    expected_labels = plan.map(&:first)
    assert!(result.fetch('evidence_process_count') == expected_labels.length &&
      result.fetch('evidence_process_labels') == expected_labels, 'paired process roster/count differs')
    expected_scope = 'three fixed W233 profiles (root Dynamic, Array(Dynamic), forced-shared Dynamic), actual Array/Tuple/Map/Array(Variant) QBit products; stock RowBinary input was separately audited; no general recursive-type or performance claim'
    assert!(result.fetch('scope') == expected_scope, 'paired scope text differs or overclaims')
    code_paths = %w[
      scripts/recheck_recursive_qbit_dynamic_w233.rb
      scripts/check_recursive_qbit_dynamic_w233.cr
      scripts/recheck_recursive_qbit_dynamic_evidence_w233.rb
      scripts/check_recursive_qbit_dynamic_evidence_w233.rb
      scripts/recheck_aggregate_recursive_w224.rb
    ]
    code_pins = code_paths.to_h { |relative| [relative, sha256_file(File.join(REPO_ROOT, relative))] }
    assert!(result.fetch('code_pins') == code_pins, 'runner/helper/auditor/recorder code pin differs')
    actual_capture_inventory = root_inventory(evidence)
    capture_inventory = read_json(File.join(evidence, 'capture_inventory.json'), 'paired capture inventory')
    assert!(capture_inventory.fetch('files') == actual_capture_inventory,
      'paired raw file inventory differs from independently recomputed inventory')
    puts "W233 raw evidence audit: stock=#{SOURCE_LABELS.length} exact-status probes; evidence=#{plan.length} raw invocations; 3 helper/native profiles; independent CHECK, schema, full/middle/zero literals, ATTACH metadata, and bounded inventories agree."
    true
  rescue KeyError, JSON::ParserError => error
    fail!("malformed evidence: #{error.message}")
  end

  def main(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/check_recursive_qbit_dynamic_evidence_w233.rb --stock-root ROOT --evidence-root ROOT --helper BIN --helper-sha256 SHA'
      opts.on('--stock-root PATH') { |value| options[:stock_root] = value }
      opts.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
      opts.on('--helper PATH') { |value| options[:helper] = value }
      opts.on('--helper-sha256 SHA') { |value| options[:helper_sha256] = value }
    end
    parser.parse!(argv)
    assert!(argv.empty? && %i[stock_root evidence_root helper helper_sha256].all? { |key| options.key?(key) }, parser.to_s)
    audit(options.fetch(:stock_root), options.fetch(:evidence_root), options.fetch(:helper), options.fetch(:helper_sha256))
  rescue StandardError => error
    warn "W233 independent raw audit failed: #{error.class}: #{error.message}"
    false
  end
end

exit(CheckRecursiveQBitDynamicEvidenceW233.main(ARGV) ? 0 : 1) if $PROGRAM_NAME == __FILE__
