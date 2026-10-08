#!/usr/bin/env ruby
# Independent read-only audit of W227's stock, helper, and native avg evidence.

require 'digest'
require 'find'
require 'json'
require 'optparse'
require_relative 'recheck_aggregate_recursive_w224'

module CheckAggregateAvgEvidenceW227
  extend self

  R = RecheckAggregateRecursiveW224
  SOURCE_ROOT = R::SOURCE_ROOT.freeze
  SOURCE_REVISION = R::SOURCE_REVISION.freeze
  SOURCE_PREFIX = '/private/tmp/crystal-click-w227-native.'.freeze
  EVIDENCE_PREFIX = '/private/tmp/crystal-click-w227-evidence.'.freeze
  INPUT_FORMAT = 'aggregate_avg_w227_input_v1'.freeze
  HELPER_FORMAT = 'aggregate_avg_w227_helper_v1'.freeze
  SUMMARY_FORMAT = 'aggregate_avg_w227_summary_v1'.freeze
  MATRIX_FORMAT = 'aggregate_avg_w227_stock_matrix_v1'.freeze
  NATIVE_FORMAT = 'aggregate_avg_w227_native_matrix_v1'.freeze
  HELPER_LABEL = 'generic-stock-read-library-write-read'.freeze
  CHECK_OUTPUT = "all_1_1_0\t1\t\n".freeze
  MAX_U64 = 18_446_744_073_709_551_615
  COUNT_WIRES = [0, 127, 128, 16_384, MAX_U64].freeze
  ROW_KEYS = [11, 22, 33, 44, 55].freeze
  MARK_ROWS = [2, 2, 1].freeze
  INVALIDATED_FILE = 'invalidated_system_columns.txt'.freeze
  INVALIDATED_NAMES = %w[_block_number _block_offset].freeze
  SOURCE_HASHES = {
    'src/AggregateFunctions/AggregateFunctionAvg.cpp' => 'fa4b350334ca402d4e17928823ca244cc4ca698ee1cb1fd465646ec770cfb48c',
    'src/AggregateFunctions/AggregateFunctionAvg.h' => 'f9760157c55129578105501dc771896cc6ac9995a3b1809552a00911f3406c6e',
    'src/AggregateFunctions/AggregateFunctionFactory.cpp' => '19edf542a3fc0364ffece33db8051d788613fd2125354679f501b9ddd038330a',
    'src/AggregateFunctions/Combinators/AggregateFunctionNull.cpp' => '829d45d95c8c17471a6093cc5a2ae3238c8728fd73cb57e0b908b412d4012efc',
    'src/AggregateFunctions/Combinators/AggregateFunctionNull.h' => '94eee4ce82872fb54d40b440519278282eae46871fe94d7d4f8c64f6caeb9501',
    'src/AggregateFunctions/IAggregateFunction.h' => '07b52aa8d08744674ee677f2b1ec55089c72870cf16e2aafaa0f815c34073b0d',
    'src/AggregateFunctions/FactoryHelpers.h' => 'abe6d4e6f20b93b1089c0c0bce90999dd58a421918d70b5dd1d186f5ed278b96',
    'src/AggregateFunctions/Helpers.h' => '1ef65dadd04fcf968998f35db36f300877550d7732c88d25b8e0fe8109857892',
    'src/Core/Field.h' => '42fd21be18892643bcfae9962485b0605441fa39e8d56df2a6e13da5554ea0c4',
    'base/base/Decimal_fwd.h' => '6f2bca44c9ded6aceabbbac2316a4100983655939a386c35aeffe11a4c1bf9da',
    'src/DataTypes/IDataType.h' => '6e9befee2cf642d989912710a4857c5a122fb7ba337eafc6b923c10f8eb33d5c',
    'src/DataTypes/DataTypeDomainBool.cpp' => '3de0e1b9e943e381270216d676c46ab8a5cf19bd70f7c41b52831ef0fa9a8d68',
    'src/DataTypes/DataTypeLowCardinality.cpp' => 'e75ef3196f929ed61313394fe8ba13c0a377446f73fac12f2b2425128d625c5c',
    'src/DataTypes/DataTypeLowCardinality.h' => '5f2e0e468177df1ce933240f7303d3558a2ba94a63e4dcdf4f92951f9520f0b2',
    'src/DataTypes/DataTypeNumberBase.h' => '277d1f9233b3ec0c58a02f8865b28f75320dc09587fe303a0425be47297d54e0',
    'src/DataTypes/DataTypeDecimalBase.h' => '9cc360ca7218629d9b697c46acdf0e2855604d78704d760e5d5fe620368f1955',
    'src/DataTypes/DataTypesDecimal.cpp' => 'c5aafee0387ea3bdd9b558759c654b8d48e492b4c6bc6b2b486b2283e2d17d6e',
    'src/DataTypes/DataTypeInterval.h' => '5ad4cc9f20ea828d13f531f25a6d4cfacc8669ea54e26bc1f4fd06d866d6d8a7',
    'src/DataTypes/DataTypeInterval.cpp' => 'feac362223d5a6445f810574c625f245acf6ebe183d4f97f506422b94daf347a',
    'src/Common/IntervalKind.h' => 'c4ad758a9d01d3c935bd2399c1c6aad7df668fab14ff881b731cc4d9bbf161ed',
    'src/DataTypes/DataTypeAggregateFunction.cpp' => '81a26eab248379dd3f055fb716a4e7cb3a5f08a90239116f6df3af5b8c83b4ec',
    'src/DataTypes/Serializations/SerializationAggregateFunction.cpp' => '1fa59453165a7cdb33811e8cf8eb55d7f7b18abd4d28281397470dd217dd4950',
    'src/DataTypes/DataTypeDateTime64.cpp' => 'e585bd8190c92fd52bbcb28165a272e41a8c507e823d246716c38e942e888adf',
    'src/DataTypes/DataTypeDateTime64.h' => '587ca9498e2321309578e0dde78937875e2bd241ad9e90edb15d9b4266c6e098',
    'src/DataTypes/DataTypeTime64.cpp' => '01d3e9ab70e1dcb71b02e0040383cbda2273a2ec50decf8a69af23292ccad8a9',
    'src/DataTypes/DataTypeTime64.h' => 'fd3b4eb7d7c730366ac45747a7793e1e1777c182b8b15145b63ccb73684df55f',
    'src/DataTypes/DataTypeDate.cpp' => 'a93159bbe79e556a896698250b5cd2b1fea46ab267f5fcef95b47a2b7e967ea8',
    'src/DataTypes/DataTypeDate32.cpp' => '54850ab01593a1edc9698b2e11149dbd148dec1c9c9d46e39b4599786a5ee665',
    'src/DataTypes/DataTypeDateTime.cpp' => 'f9d5fbfe0d896bd55e995e5f71bfb759ee02f6b4a6880e8c5abd25dac2be0f7c',
    'src/DataTypes/DataTypeTime.cpp' => '8c35c3bb4e01a35ffa82c273091d6a42d4e9459214b738130d355c3ed9e5a65b',
  }.freeze

  def fail!(message)
    raise ArgumentError, message
  end

  def require_true(condition, message)
    fail!(message) unless condition
  end

  def read_file(path, root = nil)
    full = File.expand_path(path)
    require_true(File.file?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "missing, symlinked, or noncanonical evidence file: #{full}")
    if root
      require_true(full.start_with?(File.realpath(root) + File::SEPARATOR), "evidence path escaped root: #{full}")
    end
    File.binread(full)
  end

  def json_file(path, root = nil)
    JSON.parse(read_file(path, root).force_encoding(Encoding::UTF_8))
  rescue JSON::ParserError => error
    fail!("invalid JSON evidence #{path}: #{error.message}")
  end

  def canonical_root(path, prefix, label)
    full = File.expand_path(path)
    require_true(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "#{label} is absent, symlinked, or noncanonical")
    require_true(File.dirname(full) == File.realpath('/private/tmp') && full.start_with?(prefix),
      "#{label} must be a direct /private/tmp child with prefix #{prefix}")
    full
  end

  def inventory(part)
    full = File.expand_path(part)
    require_true(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "part is absent, symlinked, or noncanonical: #{full}")
    rows = []
    Find.find(full) do |path|
      next if path == full
      require_true(!File.symlink?(path), "part contains symlink: #{path}")
      next if File.directory?(path)
      require_true(File.file?(path), "part contains non-file entry: #{path}")
      rows << { 'path' => path[(full.length + 1)..-1], 'size' => File.size(path),
        'sha256' => Digest::SHA256.file(path).hexdigest }
    end
    rows.sort_by { |row| row.fetch('path') }
  end

  def slug(type)
    type.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
  end

  def roster
    leaves = []
    %w[UInt8 UInt16 UInt32 UInt64].each { |type| leaves << [type, 'integer', 8, true] }
    leaves << ['UInt128', 'integer', 16, true] << ['UInt256', 'integer', 32, true]
    %w[Int8 Int16 Int32 Int64].each { |type| leaves << [type, 'integer', 8, true] }
    leaves << ['Int128', 'integer', 16, true] << ['Int256', 'integer', 32, true]
    %w[BFloat16 Float32 Float64].each { |type| leaves << [type, 'float64', 8, true] }
    leaves << ['Bool', 'integer', 8, true]
    [['Decimal(9, 0)', 16], ['Decimal(18, 0)', 16], ['Decimal(38, 0)', 16], ['Decimal(76, 0)', 32]].each do |type, width|
      leaves << [type, 'integer', width, false]
    end
    %w[Date Date32 DateTime Time].each { |type| leaves << [type, 'integer', 8, true] }
    leaves << ['DateTime64(3)', 'integer', 16, false]
    leaves << ['Time64(3)', 'integer', 16, false]
    %w[IntervalNanosecond IntervalMicrosecond IntervalMillisecond IntervalSecond IntervalMinute
       IntervalHour IntervalDay IntervalWeek IntervalMonth IntervalQuarter IntervalYear].each do |type|
      leaves << [type, 'integer', 8, true]
    end
    witnesses = [
      ["DateTime('UTC')", 'integer', 8, true],
      ["DateTime64(0, 'UTC')", 'integer', 16, false],
      ["DateTime64(9, 'UTC')", 'integer', 16, false],
      ['Time64(0)', 'integer', 16, false], ['Time64(9)', 'integer', 16, false],
    ]
    profiles = []
    (leaves + witnesses).each do |type, kind, width, lc|
      shells = lc ? %w[bare nullable low_cardinality low_cardinality_nullable] : %w[bare nullable]
      shells.each do |shell|
        argument = case shell
                   when 'bare' then type
                   when 'nullable' then "Nullable(#{type})"
                   when 'low_cardinality' then "LowCardinality(#{type})"
                   when 'low_cardinality_nullable' then "LowCardinality(Nullable(#{type}))"
                   end
        profiles << { 'id' => "avg_#{slug(type)}_#{shell}", 'argument_type' => argument,
          'declared_type' => "AggregateFunction(avg, #{argument})", 'shell' => shell,
          'nullable_state' => argument.include?('Nullable('), 'numerator_kind' => kind,
          'numerator_width' => width, 'leaf_type' => type }
      end
    end
    require_true(leaves.length == 37 && profiles.length == 148 && profiles.take(136).length == 136,
      'independent finite avg roster count differs')
    require_true(profiles.map { |row| row.fetch('id') }.uniq.length == profiles.length, 'avg roster IDs collide')
    profiles.each_with_index { |row, index| row['ordinal'] = index }
    profiles
  end

  def little_unsigned(value, width)
    number = Integer(value)
    require_true(number >= 0 && number < (1 << (8 * width)), 'literal numerator is out of range')
    Array.new(width) { |index| (number >> (8 * index)) & 0xff }.pack('C*').b
  end

  def u64(value)
    little_unsigned(value, 8)
  end

  def varuint(value)
    number = Integer(value)
    require_true(number >= 0 && number <= MAX_U64, 'literal count is out of UInt64 range')
    bytes = []
    while number >= 0x80
      bytes << ((number & 0x7f) | 0x80)
      number >>= 7
    end
    (bytes << number).pack('C*').b
  end

  def count_for(profile, index)
    return [0, 127, nil, 16_384, MAX_U64].fetch(index) if profile.fetch('nullable_state')
    COUNT_WIRES.fetch(index)
  end

  def state_bytes(profile, index)
    return "\x00".b if profile.fetch('nullable_state') && index == 2
    count = count_for(profile, index)
    value = count == MAX_U64 ? 0 : count
    numerator = if profile.fetch('numerator_kind') == 'float64'
                  [value.to_f].pack('E').b
                else
                  little_unsigned(value, profile.fetch('numerator_width'))
                end
    body = numerator + varuint(count)
    profile.fetch('nullable_state') ? "\x01".b + body : body
  end

  def state_hex(profile)
    ROW_KEYS.each_index.map { |index| state_bytes(profile, index).unpack1('H*') }
  end

  def rowbinary_rows(profile)
    ROW_KEYS.each_index.map { |index| u64(ROW_KEYS.fetch(index)) + state_bytes(profile, index) }
  end

  def computed_probes
    [
      ['empty_uint8', 'UInt8', 'integer', 8, 0, 0, "SELECT avgState(toUInt8(number)) FROM numbers(0)"],
      ['uint8_count_127', 'UInt8', 'integer', 8, 8001, 127, "SELECT avgState(toUInt8(number)) FROM numbers(127)"],
      ['uint8_count_128', 'UInt8', 'integer', 8, 8128, 128, "SELECT avgState(toUInt8(number)) FROM numbers(128)"],
      ['signed_int8', 'Int8', 'integer', 8, 3, 3, "SELECT avgState(toInt8(x)) FROM (SELECT arrayJoin([-2, 1, 4]) AS x)"],
      ['float32_accumulates_float64', 'Float32', 'float64', 8, 8.0, 3, "SELECT avgState(toFloat32(x)) FROM (SELECT arrayJoin([1.5, 2.25, 4.25]) AS x)"],
      ['decimal32_scale2', 'Decimal(9, 2)', 'integer', 16, 200, 3, "SELECT avgState(toDecimal32(x, 2)) FROM (SELECT arrayJoin([1, 2, -1]) AS x)"],
      ['date', 'Date', 'integer', 8, 2, 2, "SELECT avgState(toDate(x)) FROM (SELECT arrayJoin(['1970-01-01', '1970-01-03']) AS x)"],
      ['date32', 'Date32', 'integer', 8, 2, 2, "SELECT avgState(toDate32(x)) FROM (SELECT arrayJoin(['1970-01-01', '1970-01-03']) AS x)"],
      ['datetime_utc', "DateTime('UTC')", 'integer', 8, 3, 2, "SELECT avgState(toDateTime(x, 'UTC')) FROM (SELECT arrayJoin([1, 2]) AS x)"],
      ['time', 'Time', 'integer', 8, 3, 2, "SELECT avgState(toTime(toDateTime(x, 'UTC'))) FROM (SELECT arrayJoin([1, 2]) AS x)"],
      ['datetime64_scale9_utc', "DateTime64(9, 'UTC')", 'integer', 16, 3_000_000_000, 2, "SELECT avgState(toDateTime64(x, 9, 'UTC')) FROM (SELECT arrayJoin([1, 2]) AS x)"],
      ['time64_scale9', 'Time64(9)', 'integer', 16, 3, 2, "SELECT avgState(toTime64(x, 9)) FROM (SELECT arrayJoin(['00:00:00.000000001', '00:00:00.000000002']) AS x)"],
      ['interval_day', 'IntervalDay', 'integer', 8, 3, 2, "SELECT avgState(toIntervalDay(x)) FROM (SELECT arrayJoin([1, 2]) AS x)"],
    ].map do |id, type, kind, width, numerator, count, select|
      payload = (kind == 'float64' ? [numerator].pack('E').b : little_unsigned(numerator, width)) + varuint(count)
      { 'id' => id, 'argument_type' => type, 'query' => "#{select} INTO OUTFILE '%PATH%' FORMAT RowBinary",
        'hex' => payload.unpack1('H*'), 'bytes' => payload }
    end
  end

  def index_token(index)
    format('%03d', index)
  end

  def stock_table(profile)
    "w227_stock_p#{index_token(profile.fetch('ordinal'))}"
  end

  def native_table(profile)
    "w227_native_p#{index_token(profile.fetch('ordinal'))}"
  end

  def create_sql(profile, table)
    settings = R::STOCK_SETTINGS
    "CREATE TABLE default.#{table} (pk UInt64, v #{profile.fetch('declared_type')}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings.join(', ')}"
  end

  def all_create_sql(profiles, side)
    profiles.map do |profile|
      table = side == 'stock' ? stock_table(profile) : native_table(profile)
      create_sql(profile, table)
    end.join(";\n")
  end

  def enum_sql(width)
    "CREATE TABLE default.w227_refused_enum#{width} (v AggregateFunction(avg, Enum#{width}('a' = 1, 'b' = 2))) ENGINE=Memory"
  end

  def constructor_sql(profiles)
    columns = profiles.each_with_index.map { |profile, index| "p#{index_token(index)} #{profile.fetch('declared_type')}" }
    "CREATE TABLE default.w227_constructor (pk UInt8, #{columns.join(', ')}) ENGINE=Memory;\n" \
      "SELECT name, type FROM system.columns WHERE database='default' AND table='w227_constructor' ORDER BY position FORMAT TSVRaw"
  end

  def stock_capture_sql(profiles, source_root)
    sql = []
    profiles.each do |profile|
      id = profile.fetch('id')
      table = stock_table(profile)
      sql << "SELECT 'W227_CHECK_BEGIN_#{id}' FORMAT TSVRaw"
      sql << "CHECK TABLE default.#{table} FORMAT TSVRaw"
      sql << "SELECT 'W227_CHECK_END_#{id}' FORMAT TSVRaw"
      %w[full middle zero].each do |window|
        predicate = { 'full' => '', 'middle' => ' WHERE pk BETWEEN 22 AND 44', 'zero' => ' WHERE pk=0' }.fetch(window)
        path = File.join(source_root, 'cases', 'rowbinary', "stock-#{id}-#{window}.rowbinary")
        sql << "SELECT pk, v FROM default.#{table}#{predicate} ORDER BY pk INTO OUTFILE '#{path}' FORMAT RowBinary"
      end
    end
    sql.join(";\n")
  end

  def inspect_sql(profiles, side)
    sql = []
    profiles.each do |profile|
      id = profile.fetch('id')
      table = side == 'stock' ? stock_table(profile) : native_table(profile)
      %w[schema type part].each do |kind|
        sql << "SELECT 'W227_#{side.upcase}_#{kind.upcase}_BEGIN_#{id}' FORMAT TSVRaw"
        query = case kind
                when 'schema'
                  "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw"
                when 'type'
                  "SELECT toTypeName(v) FROM default.#{table} LIMIT 1 FORMAT TSVRaw"
                when 'part'
                  "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw"
                end
        sql << query
        sql << "SELECT 'W227_#{side.upcase}_#{kind.upcase}_END_#{id}' FORMAT TSVRaw"
      end
    end
    sql.join(";\n")
  end

  def native_capture_sql(profiles, evidence_root)
    sql = []
    profiles.each do |profile|
      id = profile.fetch('id')
      table = native_table(profile)
      sql << "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'"
      sql << "SELECT 'W227_CHECK_BEGIN_#{id}' FORMAT TSVRaw"
      sql << "CHECK TABLE default.#{table} FORMAT TSVRaw"
      sql << "SELECT 'W227_CHECK_END_#{id}' FORMAT TSVRaw"
      %w[full middle zero].each do |window|
        predicate = { 'full' => '', 'middle' => ' WHERE pk BETWEEN 22 AND 44', 'zero' => ' WHERE pk=0' }.fetch(window)
        path = File.join(evidence_root, 'cases', 'rowbinary', "native-#{id}-#{window}.rowbinary")
        sql << "SELECT pk, v FROM default.#{table}#{predicate} ORDER BY pk INTO OUTFILE '#{path}' FORMAT RowBinary"
      end
    end
    sql.join(";\n")
  end

  def expected_labels(profiles)
    labels = %w[runtime-version-pin runtime-build-pin constructor-positive-census constructor-invalid-enum8
      constructor-invalid-enum16 avgstate-computed-probes stock-create-all stock-capture-all stock-inspect-all
      generic-stock-read-library-write-read native-create-all native-data-paths native-attach-and-capture-all native-inspect-all]
    labels.concat(profiles.map { |profile| "stock-insert-#{profile.fetch('id')}" })
    labels
  end

  def invocation_index(root)
    paths = Dir.glob(File.join(root, 'invocations', '*.argv.json')).sort
    index = {}
    paths.each_with_index do |path, sequence|
      argv_record = json_file(path, root)
      label = argv_record.fetch('label')
      require_true(!index.key?(label), "duplicate raw invocation label #{label}")
      base = path.sub(/\.argv\.json\z/, '')
      require_true(File.basename(base).start_with?(format('%04d-', sequence + 1)), "invocation sequence gap at #{label}")
      status = json_file(base + '.status.json', root)
      stdout = read_file(base + '.stdout', root)
      stderr = read_file(base + '.stderr', root)
      sql = read_file(base + '.sql', root)
      require_true(status.fetch('stdout_bytes') == stdout.bytesize && status.fetch('stderr_bytes') == stderr.bytesize,
        "raw stdout/stderr byte counts differ for #{label}")
      stdin_path = base + '.stdin.bin'
      stdin = if argv_record['stdin_bytes'].nil?
                require_true(!File.exist?(stdin_path) && !File.symlink?(stdin_path) && argv_record['stdin_sha256'].nil?,
                  "unexpected raw stdin sidecar for #{label}")
                nil
              else
                bytes = read_file(stdin_path, root)
                require_true(bytes.bytesize == argv_record.fetch('stdin_bytes') &&
                  Digest::SHA256.hexdigest(bytes) == argv_record.fetch('stdin_sha256'), "raw stdin hash differs for #{label}")
                bytes
              end
      index[label] = { 'argv_record' => argv_record, 'status' => status, 'stdout' => stdout,
        'stderr' => stderr, 'sql' => sql, 'stdin' => stdin, 'base' => base }
    end
    expected_files = paths.length * 5 + index.values.count { |row| !row.fetch('stdin').nil? }
    require_true(Dir.children(File.join(root, 'invocations')).length == expected_files,
      'invocations directory contains missing or unlisted sidecars')
    index
  end

  def expected_status!(label, row)
    status = row.fetch('status')
    if %w[constructor-invalid-enum8 constructor-invalid-enum16].include?(label)
      width = label.end_with?('enum8') ? 8 : 16
      require_true(status.fetch('classification') == 'process_nonzero_or_signaled_exit' &&
        status.fetch('exitstatus').to_i.positive? && !status.fetch('signaled') &&
        !status.fetch('timed_out') && !status.fetch('spawn_error'), "Enum#{width} is not an ordinary nonzero semantic refusal")
      diagnostics = (row.fetch('stdout') + row.fetch('stderr')).lines.map do |line|
        match = /\ACode: [0-9]+\. DB::Exception: (.*?)(?:\r?\n)?\z/.match(line)
        match && match[1].sub(/\s+\([A-Z_]+\)(?:\s+\(version [^)]+\))?\z/, '').sub(/\.$/, '')
      end.compact
      require_true(diagnostics.length == 1 && diagnostics.first.start_with?("Illegal type Enum#{width}") &&
        diagnostics.first.include?('of argument for aggregate function avg'), "Enum#{width} diagnostic differs from source-predicted refusal")
    else
      require_true(status.fetch('classification') == 'process_success' && status['exitstatus'] == 0 &&
        !status.fetch('signaled') && !status.fetch('timed_out') && !status.fetch('spawn_error'),
        "raw process failed (not semantic refusal): #{label}")
    end
  end

  def assert_invocation!(row, binary, store, sql, stdin = nil, timeout = R::PROCESS_TIMEOUT_SECONDS)
    argv_record = row.fetch('argv_record')
    require_true(argv_record.fetch('environment') == { 'TZ' => 'UTC' } &&
      argv_record.fetch('timeout_seconds') == timeout, 'raw invocation environment or timeout differs')
    expected_sql = (sql || '').end_with?("\n") ? (sql || '') : (sql || '') + "\n"
    require_true(row.fetch('sql') == expected_sql, "raw SQL sidecar differs for #{argv_record.fetch('label')}")
    expected_argv = [binary, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
      '--max_insert_threads=1', '--max_execution_time=30', "--max_memory_usage=#{R::MEMORY_LIMIT_BYTES}",
      '--print_pretty_type_names=0', '--multiquery', '--query', (sql || '')]
    require_true(argv_record.fetch('argv') == expected_argv, "raw ClickHouse argv differs for #{argv_record.fetch('label')}")
    require_true(row.fetch('stdin') == stdin, "raw stdin bytes differ for #{argv_record.fetch('label')}")
  end

  def section(stdout, start_marker, end_marker, label)
    lines = stdout.lines
    starts = lines.each_index.select { |index| lines[index].chomp == start_marker }
    ends = lines.each_index.select { |index| lines[index].chomp == end_marker }
    require_true(starts.length == 1 && ends.length == 1 && starts.first < ends.first,
      "missing, duplicate, or reversed raw section markers for #{label}")
    lines[(starts.first + 1)...ends.first].join
  end

  def assert_source_pin!(source_pin, matrix, summary)
    require_true(source_pin == matrix.fetch('source_pin') && source_pin == summary.fetch('source_pin'),
      'source pin copies disagree')
    require_true(source_pin.fetch('source_reference') == "#{SOURCE_ROOT}@#{SOURCE_REVISION}" &&
      source_pin.fetch('runtime_built_from_this_source_not_asserted') == true,
      'pinned ClickHouse source reference/runtime caveat differs')
    avg = source_pin.fetch('aggregate_avg_source_hashes')
    require_true(avg.map { |row| row.fetch('path') }.sort == SOURCE_HASHES.keys.sort,
      'AggregateFunction(avg) source hash roster differs')
    avg.each do |row|
      expected = SOURCE_HASHES.fetch(row.fetch('path'))
      path = File.join(SOURCE_ROOT, row.fetch('path'))
      require_true(row.fetch('expected_sha256') == expected && row.fetch('actual_sha256') == expected &&
        row.fetch('matches') == true && File.file?(path) && !File.symlink?(path) &&
        Digest::SHA256.file(path).hexdigest == expected, "pinned avg source hash differs: #{row.fetch('path')}")
    end
    base = source_pin.fetch('file_hashes')
    require_true(base == R.pin_source!.fetch('file_hashes'), 'W224 base source hash record differs')
  end

  def assert_raw_processes!(root, source_root, evidence_root, profiles, expected_helper_sha)
    invocations = invocation_index(evidence_root)
    require_true(invocations.keys.sort == expected_labels(profiles).sort && invocations.length == 162,
      'raw W227 process roster differs from 148 profiles plus 14 fixed commands')
    runtime = invocations.fetch('runtime-version-pin')
    binary = runtime.fetch('argv_record').fetch('argv').first
    require_true(File.file?(binary) && File.executable?(binary) && !File.symlink?(binary) &&
      File.realpath(binary) == binary && Digest::SHA256.file(binary).hexdigest == R::RUNTIME_SHA256,
      'recorded ClickHouse executable fails exact runtime hash pin')
    invocations.each { |label, row| expected_status!(label, row) }
    stock = File.join(source_root, 'stores', 'stock')
    construction = File.join(source_root, 'stores', 'construction')
    native = File.join(evidence_root, 'stores', 'native')
    fixed_sql = {
      'runtime-version-pin' => [File.join(source_root, 'stores', 'pins'), 'SELECT version() FORMAT TSVRaw'],
      'runtime-build-pin' => [File.join(source_root, 'stores', 'pins'), "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw"],
      'constructor-positive-census' => [construction, constructor_sql(profiles)],
      'constructor-invalid-enum8' => [File.join(construction, 'enum8'), enum_sql(8)],
      'constructor-invalid-enum16' => [File.join(construction, 'enum16'), enum_sql(16)],
      'stock-create-all' => [stock, all_create_sql(profiles, 'stock')],
      'stock-capture-all' => [stock, stock_capture_sql(profiles, source_root)],
      'stock-inspect-all' => [stock, inspect_sql(profiles, 'stock')],
      'native-create-all' => [native, all_create_sql(profiles, 'native')],
      'native-attach-and-capture-all' => [native, native_capture_sql(profiles, evidence_root)],
      'native-inspect-all' => [native, inspect_sql(profiles, 'native')],
    }
    native_names = profiles.map { |profile| "'#{native_table(profile)}'" }
    fixed_sql['native-data-paths'] = [native,
      "SELECT name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name IN (#{native_names.join(', ')}) ORDER BY name FORMAT TSVRaw"]
    fixed_sql.each do |label, (store, sql)|
      assert_invocation!(invocations.fetch(label), binary, store, sql)
    end
    pin = invocations.fetch('runtime-version-pin')
    require_true(pin.fetch('stdout').strip == R::VERSION, 'raw runtime version pin stdout differs')
    build = invocations.fetch('runtime-build-pin')
    require_true(build.fetch('stdout').strip == "VERSION_GITHASH=#{R::BUILD_HASH}", 'raw build hash pin stdout differs')
    census = ["pk\tUInt8\n"] + profiles.each_with_index.map do |profile, index|
      "p#{index_token(index)}\t#{profile.fetch('declared_type')}\n"
    end
    require_true(invocations.fetch('constructor-positive-census').fetch('stdout') == census.join,
      'raw positive construction census differs from all 148 declared signatures')
    probes = computed_probes
    probe_sql = probes.map { |probe| probe.fetch('query').sub('%PATH%', File.join(evidence_root, 'cases', 'rowbinary', "computed-#{probe.fetch('id')}.rowbinary")) }.join(";\n")
    assert_invocation!(invocations.fetch('avgstate-computed-probes'), binary, construction, probe_sql)
    probes.each do |probe|
      path = File.join(evidence_root, 'cases', 'rowbinary', "computed-#{probe.fetch('id')}.rowbinary")
      require_true(read_file(path, evidence_root) == probe.fetch('bytes'), "source-generated avgState literal differs: #{probe.fetch('id')}")
    end
    profiles.each do |profile|
      id = profile.fetch('id')
      sql = "INSERT INTO default.#{stock_table(profile)} FORMAT RowBinary"
      input = rowbinary_rows(profile).join.b
      assert_invocation!(invocations.fetch("stock-insert-#{id}"), binary, stock, sql, input)
    end
    helper = invocations.fetch(HELPER_LABEL)
    argv_record = helper.fetch('argv_record')
    helper_path = argv_record.fetch('argv').fetch(0)
    helper_input = File.join(evidence_root, 'generated', 'helper-input.json')
    expected_argv = [helper_path, helper_input, File.join(evidence_root, 'generated'), source_root]
    require_true(argv_record.fetch('argv') == expected_argv && argv_record.fetch('environment') == { 'TZ' => 'UTC' } &&
      argv_record.fetch('timeout_seconds') == R::HELPER_TIMEOUT_SECONDS && helper.fetch('sql') == "\n" &&
      helper.fetch('stdin').nil? && Digest::SHA256.file(helper_path).hexdigest == expected_helper_sha,
      'raw Crystal helper invocation identity, input, or hash differs')
    invocations
  end

  def assert_source_artifacts!(source_root, evidence_root, profiles, matrix, input, invocations)
    require_true(matrix.fetch('format') == MATRIX_FORMAT && matrix.fetch('profile_count') == 148 &&
      matrix.fetch('base_source_valid_count') == 136 && matrix.fetch('metadata_witness_count') == 12 &&
      matrix.fetch('row_keys') == ROW_KEYS && matrix.fetch('mark_rows') == MARK_ROWS &&
      matrix.fetch('count_wire_values') == COUNT_WIRES.map(&:to_s), 'source matrix header differs')
    require_true(matrix.fetch('profiles').length == profiles.length, 'source matrix profile count differs')
    stock_check = profiles.map do |profile|
      "W227_CHECK_BEGIN_#{profile.fetch('id')}\n#{CHECK_OUTPUT}W227_CHECK_END_#{profile.fetch('id')}\n"
    end.join
    require_true(invocations.fetch('stock-capture-all').fetch('stdout') == stock_check,
      'raw stock CHECK result bit is not exactly one successful Wide part per signature')
    stock_inspect = invocations.fetch('stock-inspect-all').fetch('stdout')
    source_matrix_profiles = matrix.fetch('profiles')
    helper_input_profiles = input.fetch('profiles')
    require_true(input.fetch('format') == INPUT_FORMAT && input.fetch('capture_root') == source_root &&
      helper_input_profiles.length == profiles.length, 'helper input root/format/roster differs')
    profiles.each_with_index do |profile, index|
      expected_states = state_hex(profile)
      expected_rows = rowbinary_rows(profile).map { |row| row.unpack1('H*') }
      source = source_matrix_profiles.fetch(index)
      helper_input = helper_input_profiles.fetch(index)
      id = profile.fetch('id')
      expected_core = profile.slice('id', 'argument_type', 'declared_type', 'shell', 'nullable_state', 'numerator_kind', 'numerator_width')
      require_true(source.slice(*expected_core.keys) == expected_core && source.fetch('state_hex') == expected_states &&
        source.fetch('literal_rowbinary_hex') == expected_rows, "source matrix literals/identity differ for #{id}")
      require_true(helper_input.fetch('id') == id && helper_input.fetch('declared_type') == profile.fetch('declared_type') &&
        helper_input.fetch('argument_type') == profile.fetch('argument_type') && helper_input.fetch('row_keys') == ROW_KEYS &&
        helper_input.fetch('mark_rows') == MARK_ROWS && helper_input.fetch('state_hex') == expected_states &&
        helper_input.fetch('literal_rowbinary_hex') == expected_rows, "helper input literals/identity differ for #{id}")
      source_part = File.join(source_root, 'parts', 'profiles', id, 'all_1_1_0')
      library_part = File.join(evidence_root, 'generated', 'parts', "library-#{index_token(index)}-#{id}", 'all_1_1_0')
      require_true(helper_input.fetch('source_part') == source_part && helper_input.fetch('library_part') == library_part,
        "helper part path escaped/collapsed for #{id}")
      schema = section(stock_inspect, "W227_STOCK_SCHEMA_BEGIN_#{id}", "W227_STOCK_SCHEMA_END_#{id}", "stock schema #{id}")
      type_name = section(stock_inspect, "W227_STOCK_TYPE_BEGIN_#{id}", "W227_STOCK_TYPE_END_#{id}", "stock type #{id}")
      part_line = section(stock_inspect, "W227_STOCK_PART_BEGIN_#{id}", "W227_STOCK_PART_END_#{id}", "stock part #{id}")
      require_true(schema == "pk\tUInt64\nv\t#{profile.fetch('declared_type')}\n" &&
        type_name == "#{profile.fetch('declared_type')}\n", "stock exact type metadata differs for #{id}")
      fields = part_line.chomp.split("\t", -1)
      require_true(fields.length == 5 && fields.first(4) == ['all_1_1_0', '5', '4', 'Wide'], "stock part grid differs for #{id}")
      original = File.expand_path(fields.fetch(4))
      require_true(original.start_with?(File.join(source_root, 'stores', 'stock') + File::SEPARATOR),
        "stock part escaped isolated store for #{id}")
      original_inventory = inventory(original)
      require_true(source.fetch('stock_part_path') == original && source.fetch('source_part') == source_part &&
        source.fetch('source_inventory') == inventory(source_part) && inventory(source_part) == original_inventory,
        "stock source part inventory/copy differs for #{id}")
      check = stock_check.lines.grep(/\AW227_CHECK_BEGIN_#{Regexp.escape(id)}\n/).length
      require_true(check == 1 && source.fetch('stock_check_output') == CHECK_OUTPUT,
        "stock exact CHECK capture missing for #{id}")
      %w[full middle zero].each do |window|
        path = File.join(source_root, 'cases', 'rowbinary', "stock-#{id}-#{window}.rowbinary")
        rows = rowbinary_rows(profile)
        bytes = case window
                when 'full' then rows.join.b
                when 'middle' then rows[1, 3].join.b
                when 'zero' then ''.b
                end
        observed = read_file(path, source_root)
        require_true(observed == bytes, "stock #{window} literal RowBinary differs for #{id}")
        record = source.fetch('stock_rowbinary_windows').fetch(window)
        require_true(record.fetch('path') == path && record.fetch('bytes') == bytes.bytesize &&
          record.fetch('sha256') == Digest::SHA256.hexdigest(bytes) && record.fetch('literal_hex') == bytes.unpack1('H*') &&
          record.fetch('matches_independent_literal') == true, "stock #{window} matrix digest differs for #{id}")
      end
    end
    require_true(Digest::SHA256.file(File.join(source_root, 'matrix.json')).hexdigest ==
      JSON.parse(read_file(File.join(evidence_root, 'summary.json'), evidence_root)).fetch('source_matrix_sha256'),
      'stock matrix whole-file digest differs')
    computed_matrix = matrix.fetch('computed_probes')
    expected_computed = computed_probes
    require_true(computed_matrix.length == expected_computed.length, 'computed avgState matrix count differs')
    expected_computed.each_with_index do |probe, index|
      observed = computed_matrix.fetch(index)
      require_true(observed.fetch('id') == probe.fetch('id') && observed.fetch('argument_type') == probe.fetch('argument_type') &&
        observed.fetch('expected_hex') == probe.fetch('hex') && observed.fetch('actual_hex') == probe.fetch('hex') &&
        observed.fetch('matches_independent_literal') == true && observed.fetch('bytes') == probe.fetch('bytes').bytesize &&
        observed.fetch('sha256') == Digest::SHA256.hexdigest(probe.fetch('bytes')), "computed avgState matrix literal differs for #{probe.fetch('id')}")
    end
  end

  def helper_side(profile, observed, input, side)
    states = input.fetch('state_hex')
    # The part persists column stream "v"; "root.data" below is its logical role.
    expected_grid = { 'row_count' => 5, 'mark_rows' => MARK_ROWS, 'mark_count' => 3, 'physical_stream_names' => ['v'] }
    require_true(observed.fetch('grid') == expected_grid, "helper #{side} grid differs for #{profile.fetch('id')}")
    bytes = states.map { |hex| [hex].pack('H*').b }
    offsets = [0, bytes[0, 2].sum(&:bytesize), bytes[0, 4].sum(&:bytesize), bytes.sum(&:bytesize)]
    expected_stream = [{ 'role' => 'root.data', 'byte_count' => bytes.sum(&:bytesize),
      'bytes_hex' => bytes.join.b.unpack1('H*'), 'mark_offsets' => offsets }]
    require_true(observed.fetch('streams') == expected_stream, "helper #{side} opaque bytes/marks differ for #{profile.fetch('id')}")
    expected_windows = {
      'full' => { 'first_mark' => 0, 'mark_count' => 3, 'row_keys' => ROW_KEYS, 'state_hex' => states },
      'first_mark' => { 'first_mark' => 0, 'mark_count' => 1, 'row_keys' => ROW_KEYS[0, 2], 'state_hex' => states[0, 2] },
      'middle_mark' => { 'first_mark' => 1, 'mark_count' => 1, 'row_keys' => ROW_KEYS[2, 2], 'state_hex' => states[2, 2] },
      'final_short_mark' => { 'first_mark' => 2, 'mark_count' => 1, 'row_keys' => ROW_KEYS[4, 1], 'state_hex' => states[4, 1] },
      'eof_empty' => { 'first_mark' => 3, 'mark_count' => 0, 'row_keys' => [], 'state_hex' => [] },
    }
    require_true(observed.fetch('windows') == expected_windows, "helper #{side} mark windows differ for #{profile.fetch('id')}")
  end

  def assert_helper!(root, source_root, profiles, input, output, expected_helper_sha, invocations)
    helper_row = invocations.fetch(HELPER_LABEL)
    helper_path = helper_row.fetch('argv_record').fetch('argv').first
      require_true(File.file?(helper_path) && File.executable?(helper_path) && !File.symlink?(helper_path) &&
        File.realpath(helper_path) == helper_path && Digest::SHA256.file(helper_path).hexdigest == expected_helper_sha,
        'helper executable path/hash differs from supplied pin')
    helper_process = json_file(File.join(root, 'generated', 'helper-process.json'), root)
    require_true(helper_process == helper_row.fetch('status'), 'helper process status evidence differs from raw invocation')
    stdout = helper_row.fetch('stdout')
    require_true(JSON.parse(stdout) == output && output.fetch('format') == HELPER_FORMAT &&
      output.fetch('profile_count') == profiles.length && output.fetch('profiles').length == profiles.length,
      'helper stdout and captured helper output differ')
    require_true(output.fetch('profiles').map { |item| item.fetch('id') } == profiles.map { |item| item.fetch('id') },
      'helper output roster/order differs')
    profiles.each_with_index do |profile, index|
      input_profile = input.fetch('profiles').fetch(index)
      observed = output.fetch('profiles').fetch(index)
      id = profile.fetch('id')
      identity = { 'id' => id, 'declared_type' => profile.fetch('declared_type'),
        'argument_type' => profile.fetch('argument_type'), 'library_part_path' => input_profile.fetch('library_part'),
        'row_keys' => ROW_KEYS, 'mark_rows' => MARK_ROWS, 'exact_state_hex' => state_hex(profile) }
      identity.each { |key, value| require_true(observed.fetch(key) == value, "helper #{key} differs for #{id}") }
      %w[source library].each { |side| helper_side(profile, observed.fetch(side), input_profile, side) }
      values = ROW_KEYS.each_with_index.map do |key, row|
        { 'key' => key, 'type' => profile.fetch('declared_type'), 'state_hex' => state_hex(profile).fetch(row) }
      end
      owned = state_hex(profile).map { |hex| { 'type' => profile.fetch('declared_type'), 'state_hex' => hex } }
      require_true(observed.fetch('public_values') == { 'source' => values, 'library' => values } &&
        observed.fetch('owned_values') == { 'source' => owned, 'library' => owned }, "helper typed/owned values differ for #{id}")
      library_part = input_profile.fetch('library_part')
      require_true(File.directory?(library_part) && !File.symlink?(library_part) && File.realpath(library_part) == library_part,
        "helper generated part missing or redirected for #{id}")
      require_true(inventory(input_profile.fetch('source_part')) == inventory(File.join(source_root, 'parts', 'profiles', id, 'all_1_1_0')),
        "helper changed stock source part for #{id}")
      case_file = json_file(File.join(root, 'cases', "helper-#{id}.json"), root)
      require_true(case_file.fetch('input') == input_profile && case_file.fetch('helper_profile') == observed &&
        case_file.fetch('source_inventory') == inventory(input_profile.fetch('source_part')) &&
        case_file.fetch('library_inventory') == inventory(library_part), "per-profile helper evidence differs for #{id}")
    end
  end

  def assert_native!(root, profiles, output, invocations)
    capture = invocations.fetch('native-attach-and-capture-all')
    expected_check = profiles.map do |profile|
      "W227_CHECK_BEGIN_#{profile.fetch('id')}\n#{CHECK_OUTPUT}W227_CHECK_END_#{profile.fetch('id')}\n"
    end.join
    require_true(capture.fetch('stdout') == expected_check,
      'raw native CHECK result bit is not exactly one successful attached part per signature')
    matrix = json_file(File.join(root, 'cases', 'native-matrix.json'), root)
    require_true(matrix.fetch('format') == NATIVE_FORMAT && matrix.fetch('profile_count') == profiles.length &&
      matrix.fetch('profiles').length == profiles.length, 'native matrix format/count differs')
    native_inspect = invocations.fetch('native-inspect-all').fetch('stdout')
    data_lines = invocations.fetch('native-data-paths').fetch('stdout').lines.map { |line| line.chomp.split("\t", -1) }
    require_true(data_lines.length == profiles.length && data_lines.all? { |row| row.length == 2 }, 'native path census shape differs')
    data_paths = data_lines.to_h
    profiles.each_with_index do |profile, index|
      item = matrix.fetch('profiles').fetch(index)
      id = profile.fetch('id')
      require_true(item.fetch('id') == id && item.fetch('declared_type') == profile.fetch('declared_type') &&
        item.fetch('check_output') == CHECK_OUTPUT, "native matrix identity/CHECK differs for #{id}")
      native_store = File.join(root, 'stores', 'native')
      data_path = File.expand_path(data_paths.fetch(native_table(profile)))
      require_true(data_path == item.fetch('native_data_path') && data_path.start_with?(native_store + File::SEPARATOR) &&
        File.directory?(data_path) && !File.symlink?(data_path) && File.realpath(data_path) == data_path,
        "native data path escaped evidence root for #{id}")
      schema = section(native_inspect, "W227_NATIVE_SCHEMA_BEGIN_#{id}", "W227_NATIVE_SCHEMA_END_#{id}", "native schema #{id}")
      type_name = section(native_inspect, "W227_NATIVE_TYPE_BEGIN_#{id}", "W227_NATIVE_TYPE_END_#{id}", "native type #{id}")
      part_line = section(native_inspect, "W227_NATIVE_PART_BEGIN_#{id}", "W227_NATIVE_PART_END_#{id}", "native part #{id}")
      expected_schema = "pk\tUInt64\nv\t#{profile.fetch('declared_type')}\n"
      require_true(schema == expected_schema && type_name == "#{profile.fetch('declared_type')}\n" &&
        item.fetch('native_schema') == schema && item.fetch('native_type_name') == type_name,
        "native exact metadata differs for #{id}")
      fields = part_line.chomp.split("\t", -1)
      require_true(fields.length == 5 && fields.first(4) == ['all_1_1_0', '5', '4', 'Wide'], "native part grid differs for #{id}")
      attached = File.join(data_path, 'all_1_1_0')
      require_true(File.expand_path(fields.fetch(4)) == attached && item.fetch('attached_part_path') == attached,
        "native attached part location differs for #{id}")
      lib = File.join(root, 'generated', 'parts', "library-#{index_token(index)}-#{id}", 'all_1_1_0')
      before = inventory(lib)
      after = inventory(attached)
      require_true(before == after.reject { |entry| entry.fetch('path') == INVALIDATED_FILE },
        "ATTACH retained part files changed for #{id}")
      require_true(item.fetch('library_inventory') == before && item.fetch('attached_inventory') == after,
        "native/library part file inventories differ from matrix for #{id}")
      delta = item.fetch('file_delta')
      require_true(delta.fetch('removed') == [] && delta.fetch('changed') == [] &&
        delta.fetch('added') == [INVALIDATED_FILE] && after.map { |entry| entry.fetch('path') } ==
          (before.map { |entry| entry.fetch('path') } + [INVALIDATED_FILE]).sort,
        "ATTACH part-file delta differs for #{id}")
      require_true(delta.fetch('attached_inventory') == after, "ATTACH nested file delta inventory differs for #{id}")
      invalidated = read_file(File.join(attached, INVALIDATED_FILE))
      require_true(invalidated.end_with?("\n") && invalidated.lines.map(&:chomp).sort == INVALIDATED_NAMES.sort,
        "ATTACH invalidated sidecar content differs for #{id}")
      columns = read_file(File.join(attached, 'columns.txt')).force_encoding(Encoding::UTF_8).scrub
      expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`v` #{profile.fetch('declared_type')}\n"
      require_true(columns == expected_columns && item.fetch('columns_txt') == columns,
        "attached columns.txt differs for #{id}")
      serialization = json_file(File.join(attached, 'serialization.json'))
      require_true(serialization == json_file(File.join(lib, 'serialization.json')) &&
        item.fetch('serialization_json') == serialization, "attached serialization metadata differs for #{id}")
      { 'metadata_version.txt' => '0', 'default_compression_codec.txt' => 'CODEC(LZ4)', 'count.txt' => '5' }.each do |name, value|
        require_true(read_file(File.join(attached, name)).strip == value, "attached #{name} differs for #{id}")
      end
      %w[full middle zero].each do |window|
        rows = rowbinary_rows(profile)
        bytes = case window
                when 'full' then rows.join.b
                when 'middle' then rows[1, 3].join.b
                when 'zero' then ''.b
                end
        path = File.join(root, 'cases', 'rowbinary', "native-#{id}-#{window}.rowbinary")
        actual = read_file(path, root)
        row = item.fetch('rowbinary_windows').fetch(window)
        require_true(actual == bytes && row.fetch('path') == path && row.fetch('bytes') == bytes.bytesize &&
          row.fetch('sha256') == Digest::SHA256.hexdigest(bytes) && row.fetch('literal_hex') == bytes.unpack1('H*') &&
          row.fetch('matches_independent_literal') == true, "native #{window} exact RowBinary differs for #{id}")
      end
    end
    require_true(output.fetch('format') == HELPER_FORMAT, 'helper format was lost before native audit')
  end

  def audit(source_root_arg, evidence_root_arg, expected_helper_sha)
    source_root = canonical_root(source_root_arg, SOURCE_PREFIX, 'stock source root')
    root = canonical_root(evidence_root_arg, EVIDENCE_PREFIX, 'evidence root')
    require_true(File.realpath(SOURCE_ROOT) == SOURCE_ROOT, 'pinned source checkout is absent/noncanonical')
    profiles = roster
    summary = json_file(File.join(root, 'summary.json'), root)
    matrix = json_file(File.join(source_root, 'matrix.json'), source_root)
    input = json_file(File.join(root, 'generated', 'helper-input.json'), root)
    output = json_file(File.join(root, 'generated', 'helper-output.json'), root)
    require_true(summary.fetch('format') == SUMMARY_FORMAT && summary.fetch('classification') == 'paired_aggregate_avg_profiles_observed' &&
      summary.fetch('success') == true && summary['error'].nil? && summary.fetch('source_root') == source_root &&
      summary.fetch('evidence_root') == root && summary.fetch('profile_count_expected') == profiles.length &&
      summary.fetch('base_source_valid_count') == 136 && summary.fetch('metadata_witness_count') == 12 &&
      summary.fetch('stock_profile_count') == profiles.length && summary.fetch('helper_profile_count') == profiles.length &&
      summary.fetch('native_profile_count') == profiles.length && summary.fetch('construction_count') == profiles.length &&
      summary.fetch('computed_probe_count') == computed_probes.length && summary.fetch('process_count') == 162,
      'W227 summary outcome/counts differ from independently enumerated full corpus')
    runtime_pin = summary.fetch('runtime_pin')
    require_true(runtime_pin.fetch('version') == R::VERSION && runtime_pin.fetch('build_hash') == R::BUILD_HASH &&
      runtime_pin.fetch('sha256') == R::RUNTIME_SHA256 && runtime_pin.fetch('runtime_source_correlation') == 'not_asserted' &&
      runtime_pin == matrix.fetch('runtime_pin'), 'runtime pin copies differ from exact W224 runtime identity')
    require_true(Digest::SHA256.file(File.join(source_root, 'matrix.json')).hexdigest == summary.fetch('source_matrix_sha256') &&
      Digest::SHA256.file(File.join(root, 'generated', 'helper-input.json')).hexdigest == summary.fetch('helper_input_sha256') &&
      Digest::SHA256.file(File.join(root, 'cases', 'native-matrix.json')).hexdigest == summary.fetch('native_matrix_sha256'),
      'top-level W227 artifact hash does not match raw file')
    assert_source_pin!(summary.fetch('source_pin'), matrix, summary)
    invocations = assert_raw_processes!(root, source_root, root, profiles, expected_helper_sha)
    require_true(summary.fetch('helper_sha256_expected') == expected_helper_sha &&
      summary.fetch('helper_sha256_at_start') == expected_helper_sha && summary.fetch('helper_sha256_after_execute') == expected_helper_sha,
      'helper executable hashes do not all match supplied pin')
    require_true(summary.fetch('process_status_counts') == { 'success_exit0' => 160,
      'nonzero_or_signaled' => 2, 'timeout' => 0, 'spawn_failure' => 0 }, 'summary raw process status census differs')
    assert_source_artifacts!(source_root, root, profiles, matrix, input, invocations)
    assert_helper!(root, source_root, profiles, input, output, expected_helper_sha, invocations)
    assert_native!(root, profiles, output, invocations)
    puts "W227 evidence audit passed: 148 source-valid signatures (136 base + 12 metadata witnesses), 13 computed avgState probes, 162 raw processes"
    true
  end

  def main(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/check_aggregate_avg_evidence_w227.rb --source-root DIR --evidence-root DIR --helper-sha256 HEX'
      opts.on('--source-root DIR') { |value| options[:source_root] = value }
      opts.on('--evidence-root DIR') { |value| options[:evidence_root] = value }
      opts.on('--helper-sha256 HEX') { |value| options[:helper_sha256] = value }
    end
    parser.parse!(argv)
    require_true(argv.empty? && %i[source_root evidence_root helper_sha256].all? { |key| options.key?(key) }, parser.to_s)
    require_true(/\A[0-9a-f]{64}\z/.match?(options.fetch(:helper_sha256)), 'helper SHA-256 must be 64 lowercase hex characters')
    audit(options.fetch(:source_root), options.fetch(:evidence_root), options.fetch(:helper_sha256))
  rescue StandardError => error
    warn "W227 avg evidence audit failed: #{error.class}: #{error.message}"
    false
  end
end

exit(CheckAggregateAvgEvidenceW227.main(ARGV) ? 0 : 1) if $PROGRAM_NAME == __FILE__
