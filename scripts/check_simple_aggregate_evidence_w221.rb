#!/usr/bin/env ruby
# Read-only independent audit of a completed W221 bulk qualification root.

require 'digest'
require 'find'
require 'json'
require 'optparse'

module CheckSimpleAggregateEvidenceW221
  extend self

  VERSION = '26.10.1.1201'.freeze
  BUILD_HASH = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  CLICKHOUSE_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  SOURCE_SNAPSHOT = '/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1@0ca8150d9b1d0886edb2e3b4ab65eebb768d0357'.freeze
  SOURCE_MATRIX_SHA256 = 'b026bad5ba3b3421b8be0e93aa0063e9ce32e3a9b94675677a46c77adb793333'.freeze
  SOURCE_MANIFEST_SHA256 = 'bb2b14094d60c28046a6e6bda55d7b536dedcb8c16cc9203b47de61795b2ed28'.freeze
  EVIDENCE_PREFIX = '/private/tmp/crystal-click-w221-bulk.'.freeze
  SOURCE_PREFIX = '/private/tmp/crystal-click-w221-physical.'.freeze
  INVALIDATED_FILE = 'invalidated_system_columns.txt'.freeze
  INVALIDATED_NAMES = %w[_block_number _block_offset].freeze
  WINDOWS = {
    'full' => (0...5).to_a,
    'middle' => [1, 2, 3],
    'empty' => [],
  }.freeze

  def fail!(message)
    raise ArgumentError, message
  end

  def plain_file(path, label)
    fail!("#{label} is missing, symlinked, or not a regular file: #{path}") unless File.file?(path) && !File.symlink?(path)
    path
  end

  def read_json(path, label)
    JSON.parse(File.binread(plain_file(path, label)))
  rescue JSON::ParserError => error
    fail!("#{label} is not valid JSON: #{error.message}")
  end

  def sha256(path)
    Digest::SHA256.file(plain_file(path, 'hash input')).hexdigest
  end

  def check_executable(path, expected_sha, label)
    full = File.expand_path(path)
    fail!("#{label} executable is missing, symlinked, or not executable: #{full}") unless
      File.file?(full) && File.executable?(full) && !File.symlink?(full)
    fail!("#{label} executable hash differs from its external pin") if expected_sha && sha256(full) != expected_sha
    full
  end

  def inventory(part, label)
    fail!("#{label} part is missing, symlinked, or noncanonical: #{part}") unless
      File.directory?(part) && !File.symlink?(part) && File.realpath(part) == part
    files = []
    Find.find(part) do |path|
      next if path == part
      fail!("symlink in #{label} part: #{path}") if File.symlink?(path)
      next if File.directory?(path)
      fail!("non-file entry in #{label} part: #{path}") unless File.file?(path)
      files << {
        'path' => path[(part.length + 1)..-1],
        'size' => File.size(path),
        'sha256' => Digest::SHA256.file(path).hexdigest,
      }
    end
    files.sort_by { |entry| entry.fetch('path') }
  end

  def expected_roster
    leaves = []
    %w[UInt8 UInt16 UInt32 UInt64 UInt128 UInt256 Int8 Int16 Int32 Int64 Int128 Int256].each do |name|
      leaves << [name.downcase, name]
    end
    leaves.concat([
      ['float32', 'Float32'], ['float64', 'Float64'], ['bfloat16', 'BFloat16'],
      ['string', 'String'], ['fixedstring3', 'FixedString(3)'],
      ['decimal_p9_s2', 'Decimal(9, 2)'], ['decimal_p18_s3', 'Decimal(18, 3)'],
      ['decimal_p38_s5', 'Decimal(38, 5)'], ['decimal_p76_s7', 'Decimal(76, 7)'],
      ['date', 'Date'], ['date32', 'Date32'], ['time', 'Time'], ['time64_s3', 'Time64(3)'],
      ['datetime_utc', "DateTime('UTC')"], ['datetime64_s3_utc', "DateTime64(3, 'UTC')"],
      ['datetime_long_zone', "DateTime('America/Argentina/ComodRivadavia')"],
      ['datetime64_s3_long_zone', "DateTime64(3, 'America/Argentina/ComodRivadavia')"],
    ])
    fail!('independent W221 leaf roster is not 29') unless leaves.length == 29
    result = []
    %w[any_respect_nulls anyLast_respect_nulls].each do |function|
      leaves.each do |key, leaf_type|
        %w[scalar inner_nullable outer_nullable].each do |shape|
          modes = key == 'string' ? %w[single_stream with_size_stream] : [nil]
          modes.each do |mode|
            suffix = mode ? "_#{mode}" : ''
            result << {
              'id' => "#{function}_#{key}_#{shape}#{suffix}",
              'kind' => 'matrix', 'function' => function, 'leaf_key' => key,
              'leaf_type' => leaf_type, 'shape' => shape,
              'string_serialization_mode' => mode,
            }
          end
        end
      end
    end
    [
      ['min', 'uint64', 'UInt64'], ['sum', 'uint64', 'UInt64'],
      ['sumWithOverflow', 'decimal_p38_s5', 'Decimal(38, 5)'],
      ['groupBitAnd', 'int32', 'Int32'], ['groupBitOr', 'int32', 'Int32'],
      ['groupBitXor', 'int32', 'Int32'],
    ].each do |function, key, leaf_type|
      result << {
        'id' => "control_#{function}_#{key}_inner_nullable", 'kind' => 'control',
        'function' => function, 'leaf_key' => key, 'leaf_type' => leaf_type,
        'shape' => 'inner_nullable', 'string_serialization_mode' => nil,
      }
    end
    fail!('independent W221 profile roster is not 186') unless result.length == 186
    result
  end

  def declared_type(profile)
    shape = profile.fetch('shape')
    leaf = profile.fetch('leaf_type')
    storage = shape == 'inner_nullable' ? "Nullable(#{leaf})" : leaf
    aggregate = "SimpleAggregateFunction(#{profile.fetch('function')}, #{storage})"
    shape == 'outer_nullable' ? "Nullable(#{aggregate})" : aggregate
  end

  def expected_rowbinary(source, indices)
    rows = source.fetch('rowbinary_values')
    output = +''.b
    indices.each do |index|
      row = rows.fetch(index)
      output << [row.fetch('key')].pack('Q<')
      hex = row.fetch('value_rowbinary_hex')
      fail!("stock RowBinary literal is malformed for #{source.fetch('id')}/#{index}") unless hex.match?(/\A(?:[0-9a-f]{2})*\z/)
      output << [hex].pack('H*')
    end
    output
  end

  def within(root, path, label)
    full = File.expand_path(path, root)
    real = File.realpath(full)
    fail!("#{label} escapes the evidence root: #{real}") unless real.start_with?(root + File::SEPARATOR)
    real
  rescue Errno::ENOENT, Errno::EACCES => error
    fail!("cannot safely resolve #{label}: #{error.message}")
  end

  def within_regular_file(root, path, label)
    full = File.expand_path(path, root)
    prefix = root + File::SEPARATOR
    fail!("#{label} escapes the evidence root: #{full}") unless full.start_with?(prefix)
    relative = full[(prefix.length)..-1]
    components = relative.split(File::SEPARATOR)
    fail!("#{label} has an invalid evidence path: #{path.inspect}") if components.empty? || components.any?(&:empty?)
    cursor = root
    components.each_with_index do |component, index|
      cursor = File.join(cursor, component)
      stat = File.lstat(cursor)
      fail!("#{label} contains a symlink: #{cursor}") if stat.symlink?
      if index == components.length - 1
        fail!("#{label} is not a regular file: #{cursor}") unless stat.file?
      else
        fail!("#{label} has a non-directory parent: #{cursor}") unless stat.directory?
      end
    end
    real = File.realpath(full)
    fail!("#{label} is noncanonical or escapes the evidence root: #{real}") unless
      real == full && real.start_with?(prefix)
    real
  rescue Errno::ENOENT, Errno::EACCES => error
    fail!("cannot safely resolve #{label}: #{error.message}")
  end

  def process_status_ok!(status, label)
    fail!("#{label} did not exit successfully: #{status.inspect}") unless
      status.fetch('success') == true && status.fetch('exitstatus') == 0 &&
      status.fetch('timed_out') == false && status.fetch('signaled') == false &&
      status['spawn_error'].nil? && status.fetch('reported_clickhouse_codes', []).empty?
  end

  def expected_invocation_roles(source_profiles, clickhouse, helper)
    roles = {
      'invocations/00001-pin-version' => clickhouse,
      'invocations/00002-pin-build' => clickhouse,
      'invocations/00003-generic-stock-read-library-write-read' => helper,
      'invocations/00004-create-186-native-targets' => clickhouse,
    }
    source_profiles.each_with_index do |profile, index|
      label = "#{profile.fetch('id')}-attach-check-rowbinary".gsub(/[^A-Za-z0-9_.-]/, '_')
      relative = File.join('invocations', format('%05d-%s', index + 5, label))
      fail!("duplicate expected invocation role: #{relative}") if roles.key?(relative)
      roles[relative] = clickhouse
    end
    roles
  end

  def invocation_files(root, relative, clickhouse, helper)
    fail!("invalid invocation record path: #{relative.inspect}") unless relative.is_a?(String) && relative.start_with?('invocations/') && !relative.include?('..')
    argv_path = within_regular_file(root, relative + '.argv.json', 'invocation argv')
    stem = argv_path.sub(/\.argv\.json\z/, '')
    fail!("invocation argv sidecar has an invalid suffix: #{relative}") if stem == argv_path
    status_path = within_regular_file(root, stem + '.status.json', 'invocation status')
    stdout_path = within_regular_file(root, stem + '.stdout', 'invocation stdout')
    stderr_path = within_regular_file(root, stem + '.stderr', 'invocation stderr')
    argv = read_json(argv_path, 'invocation argv')
    status = read_json(status_path, 'invocation status')
    stdout = File.binread(stdout_path)
    File.binread(stderr_path)
    process_status_ok!(status, relative)
    command = argv.fetch('argv')
    fail!("invocation is not one of the externally pinned executables: #{relative}") unless
      command.is_a?(Array) && [clickhouse, helper].include?(command.first)
    fail!("invocation environment/process policy differs: #{relative}") unless
      argv.fetch('environment') == {'TZ' => 'UTC'} && argv.fetch('process_group') == 'inherited'
    sql_candidate = stem + '.sql'
    sql_present = File.exist?(sql_candidate) || File.symlink?(sql_candidate)
    sql = sql_present ? File.binread(within_regular_file(root, sql_candidate, 'invocation SQL')) : nil
    [argv, status, sql, stdout]
  end

  def tagged_rows(stdout, tag)
    stdout.dup.force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp).map do |line|
      fields = line.split("\t", -1)
      fields if fields.first == tag
    end.compact
  end

  def verify_case!(root, index, source, helper_profile, case_record, targets, clickhouse, helper)
    id = source.fetch('id')
    declared = declared_type(source)
    fail!("case identity/declaration differs for #{id}") unless
      case_record.fetch('id') == id && case_record.fetch('declared_type') == declared &&
      case_record.fetch('classification') == 'physical_observed'
    fail!("case table name differs for #{id}") unless case_record.fetch('table_name') == format('safw221_t%03d', index)
    fail!("helper profile identity/declaration differs for #{id}") unless
      helper_profile.fetch('id') == id && helper_profile.fetch('classification') == 'physical_observed' &&
      helper_profile.fetch('declared_type') == declared
    %w[stock library].each do |side|
      declaration = helper_profile.fetch(side)
      fail!("#{side} declaration differs for #{id}") unless
        declaration.fetch('schema_declaration') == declared && declaration.fetch('source_declaration') == declared
    end

    invocation = case_record.fetch('invocation')
    expected_invocation = File.join('invocations', format('%05d-%s', index + 5,
      "#{id}-attach-check-rowbinary".gsub(/[^A-Za-z0-9_.-]/, '_')))
    fail!("case invocation identity differs for #{id}") unless invocation == expected_invocation
    argv, status, sql, stdout = invocation_files(root, invocation, clickhouse, helper)
    fail!("case process status does not match its status sidecar for #{id}") unless status == case_record.fetch('process_status')
    fail!("case invocation did not use the pinned ClickHouse binary for #{id}") unless argv.fetch('argv').first == clickhouse
    fail!("case SQL sidecar is missing for #{id}") unless sql
    table = case_record.fetch('table_name')
    fail!("case SQL omits exact attach/check/type operations for #{id}") unless
      sql.include?("ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0';") &&
      sql.include?("CHECK TABLE default.#{table} FORMAT TSV;") &&
      sql.include?("SELECT '__W221_TYPE__', toTypeName(k), toTypeName(v) FROM default.#{table} LIMIT 1 FORMAT TSVRaw;")
    expected_schema = [
      ['__W221_SCHEMA__', 'k', 'UInt64', '1'],
      ['__W221_SCHEMA__', 'v', declared, '2'],
    ]
    fail!("native system.columns stdout differs for #{id}") unless tagged_rows(stdout, '__W221_SCHEMA__') == expected_schema
    fail!("native toTypeName stdout differs for #{id}") unless
      tagged_rows(stdout, '__W221_TYPE__') == [['__W221_TYPE__', 'UInt64', declared]]
    part_rows = tagged_rows(stdout, '__W221_PART__')
    fail!("native active part census differs for #{id}") unless part_rows.length == 1 &&
      part_rows.first.length == 6 && part_rows.first[1, 4] == ['all_1_1_0', '5', '4', 'Wide']
    fail!("native active part path differs for #{id}") unless
      File.realpath(part_rows.first[5]) == case_record.fetch('attached_part_path')
    check_rows = stdout.dup.force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp).select { |line| line.start_with?("all_1_1_0\t") }
    fail!("native CHECK TABLE stdout differs for #{id}") unless check_rows == ["all_1_1_0\t1\t"]
    outputs = case_record.fetch('rowbinary')
    WINDOWS.each do |window, indices|
      row = outputs.fetch(window)
      output_path = within(root, row.fetch('path'), "#{id}/#{window} RowBinary")
      bytes = File.binread(plain_file(output_path, "#{id}/#{window} RowBinary"))
      expected = expected_rowbinary(source, indices)
      fail!("#{id}/#{window} RowBinary is not the stock literal stream") unless bytes == expected
      fail!("#{id}/#{window} RowBinary evidence hashes/lengths differ") unless
        row.fetch('bytes') == bytes.bytesize && row.fetch('sha256') == Digest::SHA256.hexdigest(bytes) &&
        row.fetch('expected_bytes') == expected.bytesize && row.fetch('expected_sha256') == Digest::SHA256.hexdigest(expected) &&
        row.fetch('matches_independent_raw_leaf_manifest') == true
    end
    exact_queries = {
      'full' => "SELECT k, v FROM default.#{table} ORDER BY k INTO OUTFILE '#{within(root, outputs.fetch('full').fetch('path'), "#{id}/full RowBinary")}' FORMAT RowBinary;",
      'middle' => "SELECT k, v FROM default.#{table} WHERE k BETWEEN 22 AND 44 ORDER BY k INTO OUTFILE '#{within(root, outputs.fetch('middle').fetch('path'), "#{id}/middle RowBinary")}' FORMAT RowBinary;",
      'empty' => "SELECT k, v FROM default.#{table} WHERE k=0 ORDER BY k INTO OUTFILE '#{within(root, outputs.fetch('empty').fetch('path'), "#{id}/empty RowBinary")}' FORMAT RowBinary;",
    }
    sql_lines = sql.lines.map(&:chomp)
    exact_queries.each do |window, query|
      fail!("case SQL omits the exact #{window} RowBinary query for #{id}") unless sql_lines.include?(query)
    end

    generated = case_record.fetch('generated_part_path')
    generated_real = within(root, generated, "#{id} generated library part")
    generated_inventory = inventory(generated_real, "#{id} generated library")
    original = case_record.fetch('generated_part_inventory_before_attach')
    copied = case_record.fetch('copied_part_inventory_before_attach')
    generated_after = case_record.fetch('generated_part_inventory_after_attach')
    fail!("generated/copy before/after inventories differ for #{id}") unless
      generated_inventory == original && original == copied && copied == generated_after
    fail!("helper output library inventory differs for #{id}") unless
      helper_profile.fetch('library_part_inventory') == original

    table_path = within(root, targets.fetch('table_paths').fetch(id), "#{id} native table")
    attached = File.join(table_path, 'all_1_1_0')
    attached_real = File.realpath(attached)
    fail!("attached part path differs from the target table for #{id}") unless
      attached_real == case_record.fetch('attached_part_path')
    attached_inventory = inventory(attached_real, "#{id} attached")
    recorded_after = case_record.fetch('attached_part_inventory_after_operations')
    fail!("attached part inventory differs from its case record for #{id}") unless attached_inventory == recorded_after
    fail!("metadata inventory differs from the attached part for #{id}") unless
      case_record.fetch('native_metadata').fetch('file_inventory') == attached_inventory
    before_by_path = original.each_with_object({}) { |entry, result| result[entry.fetch('path')] = entry }
    after_by_path = attached_inventory.each_with_object({}) { |entry, result| result[entry.fetch('path')] = entry }
    fail!("attached part removed original files for #{id}") unless (before_by_path.keys - after_by_path.keys).empty?
    changed = (before_by_path.keys & after_by_path.keys).select { |path| before_by_path.fetch(path) != after_by_path.fetch(path) }
    added = after_by_path.keys - before_by_path.keys
    fail!("attached part changed original file bytes for #{id}: #{changed.inspect}") unless changed.empty?
    fail!("attached part has an unexpected addition for #{id}: #{added.inspect}") unless added == [INVALIDATED_FILE]
    invalidated_path = File.join(attached_real, INVALIDATED_FILE)
    invalidated_bytes = File.binread(plain_file(invalidated_path, "#{id} invalidation metadata"))
    fail!("invalidated system columns contents differ for #{id}") unless
      invalidated_bytes.end_with?("\n") && invalidated_bytes.split("\n", -1).tap { |lines| lines.pop }.sort == INVALIDATED_NAMES.sort
    auxiliary = after_by_path.fetch(INVALIDATED_FILE)
    delta = case_record.fetch('attachment_inventory_delta')
    fail!("recorded invalidation delta differs for #{id}") unless
      delta.fetch('added_paths') == [INVALIDATED_FILE] && delta.fetch('removed_paths') == [] &&
      delta.fetch('changed_original_paths') == [] &&
      delta.fetch('all_preexisting_file_hashes_and_sizes_preserved') == true &&
      delta.fetch('only_source_backed_auxiliary_addition') == true &&
      delta.fetch('added_file').fetch('path') == INVALIDATED_FILE &&
      delta.fetch('added_file').fetch('size') == auxiliary.fetch('size') &&
      delta.fetch('added_file').fetch('sha256') == auxiliary.fetch('sha256') &&
      delta.fetch('added_file').fetch('lines_unordered') == INVALIDATED_NAMES.sort &&
      delta.fetch('added_file').fetch('content_utf8').b == invalidated_bytes
    true
  end

  def audit(options)
    root = File.expand_path(options.fetch(:evidence_root))
    fail!('evidence root is not a fresh canonical W221 /private/tmp child') unless
      File.directory?(root) && !File.symlink?(root) && File.realpath(root) == root &&
      root.start_with?(EVIDENCE_PREFIX) && File.dirname(root) == '/private/tmp'
    clickhouse = check_executable(options.fetch(:clickhouse), CLICKHOUSE_SHA256, 'ClickHouse')
    helper = check_executable(options.fetch(:crystal_helper), options.fetch(:helper_sha256), 'helper')
    summary = read_json(File.join(root, 'summary.json'), 'W221 summary')
    fail!('W221 run is not a successful paired observation') unless
      summary.fetch('success') == true && summary.fetch('classification') == 'paired_simple_aggregate_bulk_observed'
    expected_runtime = {'version' => VERSION, 'build_hash' => BUILD_HASH, 'sha256' => CLICKHOUSE_SHA256}
    fail!('summary runtime pin differs from the independent pin') unless
      summary.fetch('runtime_expected') == expected_runtime && summary.fetch('runtime_observed') == expected_runtime
    fail!('runtime pin record differs') unless read_json(File.join(root, 'runtime_pin.json'), 'runtime pin').fetch('runtime') == expected_runtime
    helper_pin = read_json(File.join(root, 'helper_pin.json'), 'helper pin')
    helper_sha = sha256(helper)
    fail!('helper executable path/hash differs from its prebuilt pin') unless
      File.expand_path(helper_pin.fetch('path')) == helper && helper_pin.fetch('sha256_before') == helper_sha &&
      summary.fetch('helper').fetch('path') == helper && summary.fetch('helper').fetch('sha256_before') == helper_sha &&
      summary.fetch('helper').fetch('sha256_after') == helper_sha

    source_matrix_path = File.expand_path(options.fetch(:source_matrix))
    fail!('source matrix path differs from the recorded external stock witness') unless
      source_matrix_path == summary.fetch('source_matrix_path') && source_matrix_path.start_with?(SOURCE_PREFIX) &&
      File.dirname(source_matrix_path) != root
    source_root = File.dirname(source_matrix_path)
    source_manifest_path = File.join(source_root, 'manifest.json')
    fail!('stock source matrix hash differs from the external source-witness pin') unless sha256(source_matrix_path) == SOURCE_MATRIX_SHA256
    fail!('stock source manifest hash differs from the external source-witness pin') unless sha256(source_manifest_path) == SOURCE_MANIFEST_SHA256
    source = read_json(source_matrix_path, 'stock physical matrix')
    source_manifest = read_json(source_manifest_path, 'stock physical manifest')
    fail!('source snapshot/runtime distinction differs') unless
      source_manifest.fetch('source_snapshot') == SOURCE_SNAPSHOT &&
      source_manifest.fetch('source_snapshot_is_not_asserted_to_build_runtime') == true &&
      source_manifest.fetch('runtime_pin_expected') == expected_runtime
    fail!('summary source snapshot/hash differs from the external witness') unless
      summary.fetch('source_snapshot') == SOURCE_SNAPSHOT &&
      summary.fetch('source_matrix_sha256') == SOURCE_MATRIX_SHA256
    fail!('stock witness does not report the complete successful 186-case matrix') unless
      source.fetch('case_count') == 186 && source.fetch('physical_observed') == 186 &&
      source.fetch('observed_type_refusals') == 0 && source.fetch('admission_mismatches') == 0 &&
      source.fetch('probe_failures') == 0 && source.fetch('physical_mismatches') == 0
    expected = expected_roster
    source_profiles = source.fetch('matrix')
    fail!('stock profile roster/order differs from the independently generated roster') unless
      source_profiles.map { |profile| profile.fetch('id') } == expected.map { |profile| profile.fetch('id') }
    source_profiles.each_with_index do |profile, index|
      expected_profile = expected.fetch(index)
      expected_profile.each { |key, value| fail!("stock profile #{profile.fetch('id')} differs on #{key}") unless profile.fetch(key) == value }
      fail!("stock declared type differs for #{profile.fetch('id')}") unless profile.fetch('declared_type') == declared_type(expected_profile)
      fail!("stock RowBinary row count differs for #{profile.fetch('id')}") unless profile.fetch('rowbinary_values').length == 5
    end
    process_roles = expected_invocation_roles(source_profiles, clickhouse, helper)

    manifest = read_json(File.join(root, 'manifest.json'), 'bulk manifest')
    fail!('bulk manifest source/runtime pin differs') unless
      manifest.fetch('source').fetch('source_snapshot') == SOURCE_SNAPSHOT &&
      manifest.fetch('source').fetch('source_matrix_sha256') == SOURCE_MATRIX_SHA256 &&
      manifest.fetch('source').fetch('source_manifest_sha256') == SOURCE_MANIFEST_SHA256 &&
      manifest.fetch('runtime_expected') == expected_runtime
    helper_output = read_json(File.join(root, 'generated', 'helper-output.json'), 'helper output')
    fail!('helper output count/classification differs') unless
      helper_output.fetch('profile_count') == 186 && helper_output.fetch('physical_observed') == 186 &&
      helper_output.fetch('mismatch_count') == 0 && helper_output.fetch('profiles').length == 186
    helper_profiles = helper_output.fetch('profiles')
    fail!('helper output profile roster differs from stock') unless
      helper_profiles.map { |profile| profile.fetch('id') } == source_profiles.map { |profile| profile.fetch('id') }

    cases = read_json(File.join(root, 'cases', 'matrix.json'), 'native case matrix')
    fail!('native case matrix count/classification differs') unless
      cases.fetch('case_count') == 186 && cases.fetch('observed') == 186 &&
      cases.fetch('mismatches') == 0 && cases.fetch('matrix').length == 186
    targets = read_json(File.join(root, 'native-targets.json'), 'native target inventory')
    fail!('native target roster size differs') unless
      targets.fetch('table_count') == 186 && targets.fetch('system_columns_rows') == 372 &&
      targets.fetch('table_paths').keys.sort == source_profiles.map { |profile| profile.fetch('id') }.sort

    process_status_paths = Dir.glob(File.join(root, 'invocations', '*.status.json')).sort
    fail!('not all recorded processes have the expected successful invocation count') unless
      process_status_paths.length == summary.fetch('counts').fetch('recorded_process_invocations') && process_status_paths.length == 190
    recorded_invocations = process_status_paths.map do |status_path|
      status_path.sub(/\.status\.json\z/, '')[(root.length + 1)..-1]
    end
    fail!('recorded invocation roster differs from the independently expected process roles') unless
      recorded_invocations.sort == process_roles.keys.sort
    process_status_paths.each do |status_path|
      stem = status_path.sub(/\.status\.json\z/, '')
      relative = stem[(root.length + 1)..-1]
      argv, _status, _sql, _stdout = invocation_files(root, relative, clickhouse, helper)
      fail!("recorded invocation used the wrong executable role: #{relative}") unless
        argv.fetch('argv').first == process_roles.fetch(relative)
    end

    helper_process = read_json(File.join(root, 'generated', 'helper-process.json'), 'helper process record')
    helper_invocation = summary.fetch('helper').fetch('invocation_record')
    fail!('helper process invocation identity differs') unless
      helper_invocation == 'invocations/00003-generic-stock-read-library-write-read'
    helper_argv, helper_status, _helper_sql, _helper_stdout = invocation_files(root, helper_invocation, clickhouse, helper)
    fail!('helper process did not run the externally pinned helper executable') unless helper_argv.fetch('argv').first == helper
    fail!('helper process record differs from summary') unless
      helper_process.fetch('status') == summary.fetch('helper').fetch('status') &&
      helper_process.fetch('invocation_record') == helper_invocation &&
      helper_status == summary.fetch('helper').fetch('status')
    native_invocation = targets.fetch('invocation')
    fail!('native target invocation identity differs') unless native_invocation == 'invocations/00004-create-186-native-targets'
    target_argv, _target_status, target_sql, _target_stdout = invocation_files(root, native_invocation, clickhouse, helper)
    fail!('native targets were not created by the externally pinned ClickHouse executable') unless target_argv.fetch('argv').first == clickhouse
    target_types_match = target_sql && source_profiles.each_with_index.all? do |profile, index|
      table = format('safw221_t%03d', index)
      target_sql.include?("CREATE TABLE default.#{table} (k UInt64, v #{declared_type(profile)}) ENGINE=MergeTree ORDER BY k SETTINGS ")
    end
    fail!('native CREATE TABLE SQL does not contain the exact stock declaration roster') unless target_types_match

    cases.fetch('matrix').each_with_index do |record, index|
      source_profile = source_profiles.fetch(index)
      helper_profile = helper_profiles.fetch(index)
      verify_case!(root, index, source_profile, helper_profile, record, targets, clickhouse, helper)
      label = record.fetch('id').gsub(/[^A-Za-z0-9_.-]/, '_')
      case_path = File.join(root, 'cases', 'profiles', format('%03d-%s', index, label), 'case.json')
      fail!("per-case evidence differs from matrix for #{record.fetch('id')}") unless read_json(case_path, 'case evidence') == record
    end
    puts "W221 evidence audit passed: 186 exact profiles, 190 successful processes, literal RowBinary windows, and source-backed attachment deltas."
    true
  end

  def parse_options(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/check_simple_aggregate_evidence_w221.rb --evidence-root PATH --source-matrix PATH --clickhouse PATH --crystal-helper PATH --helper-sha256 SHA256'
      opts.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
      opts.on('--source-matrix PATH') { |value| options[:source_matrix] = value }
      opts.on('--clickhouse PATH') { |value| options[:clickhouse] = value }
      opts.on('--crystal-helper PATH') { |value| options[:crystal_helper] = value }
      opts.on('--helper-sha256 SHA256') { |value| options[:helper_sha256] = value }
    end
    parser.parse!(argv)
    %i[evidence_root source_matrix clickhouse crystal_helper helper_sha256].each do |key|
      raise OptionParser::MissingArgument, "--#{key.to_s.tr('_', '-')}" unless options[key]
    end
    raise OptionParser::InvalidArgument, '--helper-sha256 must be 64 lowercase hex characters' unless options.fetch(:helper_sha256).match?(/\A[0-9a-f]{64}\z/)
    raise OptionParser::InvalidArgument, 'unexpected positional arguments' unless argv.empty?
    options
  end

  def main(argv)
    audit(parse_options(argv)) ? 0 : 1
  rescue StandardError => error
    warn "W221 evidence audit failed: #{error.class}: #{error.message}"
    1
  end
end

exit(CheckSimpleAggregateEvidenceW221.main(ARGV))
