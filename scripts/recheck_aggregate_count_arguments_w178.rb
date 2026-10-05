# Root-only, serial ClickHouse component gate for the bounded W178 Count
# argument matrix. It creates/checks stock-authored parts for the external
# Crystal W178_STOCK_ROOT consumer spec, and separately attaches/checks the 63
# library-authored parts in ClickHouse. It does not itself consume stock parts
# with Crystal; the overall paired qualification also requires that external
# 63-profile consumer gate to pass. The caller owns process containment and
# supplies three existing /private/tmp roots: empty evidence, the 63
# library-authored parts, and empty stock-part output. This script never builds
# Crystal or accesses the network.
require 'digest'
require 'find'
require 'json'
require 'open3'

class AggregateCountArgumentPairedOracle
  BINARY = '/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped'.freeze
  SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  VERSION = "26.10.1.1201\td9bcb5ab007f0f6299f7f973f2642245bab3d028\n".b.freeze
  VERSION_SQL = "SELECT version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSV".freeze
  PROCESS_TIMEOUT_SECONDS = 10
  TERMINATION_GRACE_SECONDS = 2
  MAX_MEMORY_BYTES = 1_073_741_824
  EXPECTED_ROWS = 5
  EXPECTED_MARKS = 4

  # The expected argument spelling is independent of either the Crystal writer
  # or the stock server's reported type name. The Decimal64(3) case is distinct
  # from generic Decimal(18, 4), keeping all 63 advertised canonical arguments
  # unique.
  PROFILE_ROWS = [
    ['nothing', 'Nothing', 'Nothing'],
    ['bool', 'Bool', 'Bool'],
    ['uint8', 'UInt8', 'UInt8'],
    ['uint16', 'UInt16', 'UInt16'],
    ['uint32', 'UInt32', 'UInt32'],
    ['uint64', 'UInt64', 'UInt64'],
    ['uint128', 'UInt128', 'UInt128'],
    ['uint256', 'UInt256', 'UInt256'],
    ['int8', 'Int8', 'Int8'],
    ['int16', 'Int16', 'Int16'],
    ['int32', 'Int32', 'Int32'],
    ['int64', 'Int64', 'Int64'],
    ['int128', 'Int128', 'Int128'],
    ['int256', 'Int256', 'Int256'],
    ['bfloat16', 'BFloat16', 'BFloat16'],
    ['float32', 'Float32', 'Float32'],
    ['float64', 'Float64', 'Float64'],
    ['string', 'String', 'String'],
    ['uuid', 'UUID', 'UUID'],
    ['ipv4', 'IPv4', 'IPv4'],
    ['ipv6', 'IPv6', 'IPv6'],
    ['fixed_string_1', 'FixedString(1)', 'FixedString(1)'],
    ['fixed_string_16', 'FixedString(16)', 'FixedString(16)'],
    ['enum8', "Enum8('zero' = 0, 'one' = 1)", "Enum8('zero' = 0, 'one' = 1)"],
    ['enum8_quoted', "Enum8('comma, label' = 1, 'it\\'s\\\\safe' = 2)", "Enum8('comma, label' = 1, 'it\\'s\\\\safe' = 2)"],
    ['enum16', "Enum16('zero' = 0, 'one' = 1)", "Enum16('zero' = 0, 'one' = 1)"],
    ['decimal32', 'Decimal32(2)', 'Decimal(9, 2)'],
    ['decimal64', 'Decimal64(3)', 'Decimal(18, 3)'],
    ['decimal128', 'Decimal128(4)', 'Decimal(38, 4)'],
    ['decimal256', 'Decimal256(4)', 'Decimal(76, 4)'],
    ['decimal_18_4', 'Decimal(18, 4)', 'Decimal(18, 4)'],
    ['date', 'Date', 'Date'],
    ['date32', 'Date32', 'Date32'],
    ['datetime', 'DateTime', 'DateTime'],
    ['datetime_utc', "DateTime('UTC')", "DateTime('UTC')"],
    ['datetime_new_york', "DateTime('America/New_York')", "DateTime('America/New_York')"],
    ['datetime64_0', 'DateTime64(0)', 'DateTime64(0)'],
    ['datetime64_3', 'DateTime64(3)', 'DateTime64(3)'],
    ['datetime64_9', 'DateTime64(9)', 'DateTime64(9)'],
    ['datetime64_3_utc', "DateTime64(3, 'UTC')", "DateTime64(3, 'UTC')"],
    ['datetime64_3_new_york', "DateTime64(3, 'America/New_York')", "DateTime64(3, 'America/New_York')"],
    ['time', 'Time', 'Time'],
    ['time64_0', 'Time64(0)', 'Time64(0)'],
    ['time64_3', 'Time64(3)', 'Time64(3)'],
    ['time64_9', 'Time64(9)', 'Time64(9)'],
    ['interval_nanosecond', 'IntervalNanosecond', 'IntervalNanosecond'],
    ['nullable_uint8', 'Nullable(UInt8)', 'Nullable(UInt8)'],
    ['nullable_string', 'Nullable(String)', 'Nullable(String)'],
    ['nullable_decimal', 'Nullable(Decimal(9, 2))', 'Nullable(Decimal(9, 2))'],
    ['nullable_datetime64_utc', "Nullable(DateTime64(3, 'UTC'))", "Nullable(DateTime64(3, 'UTC'))"],
    ['array_uint8', 'Array(UInt8)', 'Array(UInt8)'],
    ['array_nullable_uint8', 'Array(Nullable(UInt8))', 'Array(Nullable(UInt8))'],
    ['tuple_scalars', 'Tuple(UInt8, String)', 'Tuple(UInt8, String)'],
    ['tuple_quoted_fields', "Tuple(`from` UInt64, `a\\`b` Nullable(String))", "Tuple(`from` UInt64, `a\\`b` Nullable(String))"],
    ['map_string_uint64', 'Map(String, UInt64)', 'Map(String, UInt64)'],
    ['nested_named', 'Nested(id UInt8, payload String)', 'Nested(id UInt8, payload String)'],
    ['low_cardinality_string', 'LowCardinality(String)', 'LowCardinality(String)'],
    ['low_cardinality_nullable_string', 'LowCardinality(Nullable(String))', 'LowCardinality(Nullable(String))'],
    ['variant', 'Variant(UInt8, String)', 'Variant(String, UInt8)'],
    ['dynamic', 'Dynamic', 'Dynamic'],
    ['dynamic_max_types_7', 'Dynamic(max_types=7)', 'Dynamic(max_types=7)'],
    ['simple_aggregate_sum_uint64', 'SimpleAggregateFunction(sum, UInt64)', 'SimpleAggregateFunction(sum, UInt64)'],
    ['simple_aggregate_any_string', 'SimpleAggregateFunction(any, String)', 'SimpleAggregateFunction(any, String)'],
  ].map do |id, argument_sql, argument_name|
    {id: id.freeze, argument_sql: argument_sql.freeze, argument_name: argument_name.freeze,
     count_type: "AggregateFunction(count, #{argument_name})".freeze}.freeze
  end.freeze

  STATE_HEX = %w[00 7f 8001 808001 ffffffffffffffffff01].freeze
  STATES = STATE_HEX.map { |hex| [hex].pack('H*').b.freeze }.freeze
  COUNTS = %w[0 127 128 16384 18446744073709551615].freeze
  KEYS = [7, 13, 22, 31, 50].freeze
  CHECK_OUTPUT = "all_1_1_0\t1\t\n".b.freeze
  QUERY_CHECK = 'CHECK TABLE t FORMAT TSV'.freeze
  QUERY_SCHEMA = "SELECT name,type FROM system.columns WHERE database='default' AND table='t' ORDER BY position FORMAT TSVRaw".freeze
  QUERY_TYPE_NAME = 'SELECT DISTINCT toTypeName(c) FROM t FORMAT TSVRaw'.freeze
  QUERY_PART = "SELECT name,path,part_type,rows,marks FROM system.parts WHERE database='default' AND table='t' AND active FORMAT TSV".freeze
  QUERY_TABLE_PATH = "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='t' FORMAT TSVRaw".freeze
  QUERY_FULL = 'SELECT pk,c FROM t ORDER BY pk FORMAT RowBinary'.freeze
  QUERY_WINDOW = 'SELECT pk,c FROM t WHERE pk>=22 AND pk<=31 ORDER BY pk FORMAT RowBinary'.freeze
  QUERY_EMPTY = 'SELECT pk,c FROM t WHERE pk=0 ORDER BY pk FORMAT RowBinary'.freeze
  QUERY_FINAL = 'SELECT finalizeAggregation(c) FROM t ORDER BY pk FORMAT TSV'.freeze

  SYSTEM_FAILURE = /no space left|disk quota|read.only file system|permission denied|cannot allocate memory|out of memory|memory limit|i\/o error|bad file descriptor|too many open files|resource temporarily unavailable|cannot open file|cannot create file/i.freeze
  CLICKHOUSE_EXCEPTION = /\bCode:\s*\d+\.|\bDB::Exception:/.freeze

  Invocation = Struct.new(:record, :stdout, :stderr, :status, keyword_init: true)

  class InvocationFailure < StandardError
    attr_reader :record

    def initialize(record)
      @record = record
      super("#{record.fetch('label')}: #{record.fetch('process_classification')}")
    end
  end

  def initialize(evidence_root, library_root, stock_root)
    raise 'usage requires evidence, library-part, and stock-part roots' unless evidence_root && library_root && stock_root
    @evidence_root = validate_tmp_root(evidence_root, empty: true, label: 'evidence')
    @library_root = validate_tmp_root(library_root, empty: false, label: 'library parts')
    @stock_root = validate_tmp_root(stock_root, empty: true, label: 'stock output')
    roots = [@evidence_root, @library_root, @stock_root]
    roots.combination(2) do |left, right|
      if left == right || left.start_with?(right + '/') || right.start_with?(left + '/')
        raise 'evidence, library, and stock roots must be disjoint'
      end
    end

    expected_ids = PROFILE_ROWS.map { |row| row.fetch(:id) }
    expected_names = PROFILE_ROWS.map { |row| row.fetch(:argument_name) }
    raise 'W178 profile labels must be unique' unless expected_ids.uniq.length == expected_ids.length
    raise 'W178 canonical arguments must be 63 distinct names' unless expected_names.length == 63 && expected_names.uniq.length == 63
    validate_library_parts!(expected_ids)

    @invocations = []
    @failures = []
    @direction_results = []
    @fatal_error = nil
    @sensitivity_observed = nil
    @runtime_before = nil
    @runtime_after = nil
    @pin_before = nil
    @pin_after = nil
  end

  def run
    begin
      @runtime_before = file_sha256(BINARY)
      if @runtime_before != SHA256
        add_failure('runtime', 'pinned ClickHouse executable SHA-256 mismatch', expected: SHA256, actual: @runtime_before)
      else
        pin_store = create_store('runtime-pin-before')
        pin = query('runtime-pin-before', pin_store, VERSION_SQL)
        @pin_before = pin.stdout
        unless @pin_before == VERSION
          add_failure('runtime', 'pre-run version/build pin mismatch', expected: VERSION, actual: @pin_before)
        else
          PROFILE_ROWS.each do |profile_row|
            break if @fatal_error
            profile = profile(profile_row)
            run_direction(profile, 'stock_to_library')
            break if @fatal_error
            run_direction(profile, 'library_to_stock')
          end
        end
      end
    rescue InvocationFailure => error
      @fatal_error = error.message
    rescue StandardError => error
      @fatal_error = "#{error.class}: #{error.message}"
    ensure
      run_postflight_pin
      assess_in_memory_literal_control
      write_json('summary.json', summary)
    end

    @failures.empty? && @fatal_error.nil? && @direction_results.length == PROFILE_ROWS.length * 2 &&
      @direction_results.all? { |result| result.fetch('status') == 'qualified' }
  end

  private

  def profile(row)
    argument_name = row.fetch(:argument_name)
    {id: row.fetch(:id), argument_sql: row.fetch(:argument_sql), argument_name: argument_name,
     count_type: "AggregateFunction(count, #{argument_name})"}
  end

  def validate_tmp_root(path, empty:, label:)
    expanded = File.expand_path(path)
    prefix = '/private/tmp/'
    raise "unsafe #{label} root: must be a /private/tmp child" unless expanded.start_with?(prefix)
    current = '/private/tmp'
    raise 'temporary root base is not a directory' unless File.directory?(current)
    expanded.delete_prefix(prefix).split('/').each do |component|
      raise "unsafe #{label} root component" if component.empty? || component == '.' || component == '..'
      current = File.join(current, component)
      stat = File.lstat(current)
      raise "symlink in #{label} root path" if stat.symlink?
      raise "non-directory in #{label} root path" unless stat.directory?
    end
    real = File.realpath(expanded)
    raise "noncanonical #{label} root" unless real == expanded
    raise "#{label} root is not empty" if empty && !Dir.children(real).empty?
    real
  rescue Errno::ENOENT
    raise "#{label} root must already exist"
  end

  def validate_library_parts!(expected_ids)
    expected = expected_ids.map { |id| "part-#{id}" }.sort
    actual = Dir.children(@library_root).sort
    raise 'library root must contain exactly the 63 spec-authored part directories' unless actual == expected
    expected_ids.each do |id|
      part_root = File.join(@library_root, "part-#{id}")
      stat = File.lstat(part_root)
      raise "library profile #{id} is not a regular directory" unless stat.directory? && !stat.symlink?
      raise "library profile #{id} must contain only all_1_1_0" unless Dir.children(part_root) == ['all_1_1_0']
      part_path = File.join(part_root, 'all_1_1_0')
      part_stat = File.lstat(part_path)
      raise "library profile #{id} part is not a regular directory" unless part_stat.directory? && !part_stat.symlink?
      validate_tree!(part_path)
    end
  end

  def validate_tree!(root)
    Find.find(root) do |path|
      stat = File.lstat(path)
      raise "symlink in part tree: #{path}" if stat.symlink?
      raise "special file in part tree: #{path}" unless stat.file? || stat.directory?
    end
  end

  def create_store(name)
    raise 'unsafe evidence directory label' unless /\A[a-z0-9_-]+\z/.match?(name)
    path = File.join(@evidence_root, name)
    Dir.mkdir(path, 0o700)
    path
  end

  def ddl(type)
    "CREATE TABLE t (pk UInt64, c #{type}) ENGINE=MergeTree ORDER BY pk SETTINGS " \
      'index_granularity=2,index_granularity_bytes=10485760,enable_mixed_granularity_parts=1,' \
      'min_rows_for_wide_part=0,min_bytes_for_wide_part=0,ratio_of_defaults_for_sparse_serialization=0.9375,' \
      'compress_marks=0,compress_primary_key=0,min_compress_block_size=0,max_compress_block_size=4096,' \
      "default_compression_codec='LZ4'"
  end

  def rowbinary(row_indexes)
    row_indexes.map { |index| [KEYS.fetch(index)].pack('Q<') + STATES.fetch(index) }.join.b
  end

  def expected_finalized(row_indexes)
    row_indexes.map { |index| COUNTS.fetch(index) }.join("\n").concat("\n").b
  end

  def query(label, store, sql, input = ''.b)
    raise 'unsafe invocation label' unless /\A[a-z0-9_-]+\z/.match?(label)
    args = [BINARY, 'local', '--path', store, '--max_threads=1', '--max_insert_threads=1',
            "--max_memory_usage=#{MAX_MEMORY_BYTES}", '--query', sql]
    stdout, stderr, status, timed_out, spawn_error, stdin_error, stdout_error, stderr_error = execute(args, input)
    record = {
      'label' => label, 'sql' => sql, 'argv' => args,
      'exit' => status&.exitstatus, 'signal' => status&.termsig,
      'timed_out' => timed_out, 'timeout_seconds' => PROCESS_TIMEOUT_SECONDS,
      'spawn_error' => spawn_error, 'stdin_write_error' => stdin_error,
      'stdout_read_error' => stdout_error, 'stderr_read_error' => stderr_error,
      'process_classification' => classify_process(status, timed_out, spawn_error, stdin_error,
                                                   stdout_error, stderr_error, stderr),
      'input_sha256' => Digest::SHA256.hexdigest(input),
      'stdout_sha256' => Digest::SHA256.hexdigest(stdout),
      'stderr_sha256' => Digest::SHA256.hexdigest(stderr),
      'input_bytes' => input.bytesize, 'stdout_bytes' => stdout.bytesize, 'stderr_bytes' => stderr.bytesize,
      'input_file' => "#{label}.input", 'stdout_file' => "#{label}.stdout",
      'stderr_file' => "#{label}.stderr", 'record_file' => "#{label}.json",
    }
    write_exclusive(record.fetch('input_file'), input)
    write_exclusive(record.fetch('stdout_file'), stdout)
    write_exclusive(record.fetch('stderr_file'), stderr)
    write_json(record.fetch('record_file'), record)
    @invocations << record
    invocation = Invocation.new(record: record, stdout: stdout, stderr: stderr, status: status)
    unless record.fetch('process_classification') == 'success'
      raise InvocationFailure.new(record)
    end
    invocation
  end

  def execute(args, input)
    stdout_bytes = ''.b
    stderr_bytes = ''.b
    status = nil
    timed_out = false
    spawn_error = nil
    stdin_error = nil
    stdout_error = nil
    stderr_error = nil

    begin
      Open3.popen3({'TZ' => 'UTC'}, *args) do |stdin, stdout, stderr, waiter|
        stdin.binmode
        stdout.binmode
        stderr.binmode
        stdout_reader = Thread.new { read_pipe(stdout) }
        stderr_reader = Thread.new { read_pipe(stderr) }
        begin
          stdin.write(input) unless input.empty?
        rescue IOError, SystemCallError => error
          stdin_error = "#{error.class}: #{error.message}"
        ensure
          stdin.close unless stdin.closed?
        end

        unless waiter.join(PROCESS_TIMEOUT_SECONDS)
          timed_out = true
          signal_process('TERM', waiter.pid)
          unless waiter.join(TERMINATION_GRACE_SECONDS)
            signal_process('KILL', waiter.pid)
            waiter.join
          end
        end
        status = waiter.value
        stdout_bytes, stdout_error = stdout_reader.value
        stderr_bytes, stderr_error = stderr_reader.value
      end
    rescue IOError, SystemCallError => error
      spawn_error = "#{error.class}: #{error.message}"
      stderr_bytes = "#{spawn_error}\n".b
    end

    [stdout_bytes, stderr_bytes, status, timed_out, spawn_error, stdin_error, stdout_error, stderr_error]
  end

  def read_pipe(io)
    [io.read.b, nil]
  rescue IOError, SystemCallError => error
    [''.b, "#{error.class}: #{error.message}"]
  end

  def signal_process(signal, pid)
    Process.kill(signal, pid)
  rescue Errno::ESRCH
    nil
  end

  def classify_process(status, timed_out, spawn_error, stdin_error, stdout_error, stderr_error, stderr)
    return 'runtime_or_system_error' if timed_out || spawn_error || stdout_error || stderr_error
    if status&.success? && status.termsig.nil?
      return 'runtime_or_system_error' if stdin_error
      return 'success'
    end
    return 'runtime_or_system_error' unless status
    return 'signaled' if status.termsig
    return 'runtime_or_system_error' if SYSTEM_FAILURE.match?(stderr)
    return 'server_exception' if CLICKHOUSE_EXCEPTION.match?(stderr)
    return 'runtime_or_system_error' if stdin_error
    'runtime_or_system_error'
  end

  def query_profile!(result, stage, store, sql, input = ''.b)
    label = "#{result.fetch('direction')}-#{result.fetch('profile')}-#{stage}"
    invocation = query(label, store, sql, input)
    result.fetch('invocations')[stage] = label
    invocation.stdout
  rescue InvocationFailure => error
    result.fetch('invocations')[stage] = label
    result['failure'] = error.record
    raise
  end

  def run_direction(profile, direction)
    result = {
      'profile' => profile.fetch(:id), 'argument_sql' => profile.fetch(:argument_sql),
      'expected_argument_name' => profile.fetch(:argument_name),
      'expected_count_type' => profile.fetch(:count_type),
      'direction' => direction, 'status' => 'running',
      'checks' => {}, 'invocations' => {},
    }
    begin
      if direction == 'stock_to_library'
        run_stock_direction(profile, result)
      else
        run_library_direction(profile, result)
      end
      result['status'] = result.fetch('checks').values.all? { |check| check.fetch('passed') } ? 'qualified' : 'mismatch'
    rescue InvocationFailure => error
      result['status'] = error.record.fetch('process_classification')
      @fatal_error ||= error.message if error.record.fetch('process_classification') != 'server_exception'
      @failures << {
        'profile' => profile.fetch(:id), 'direction' => direction,
        'stage' => error.record.fetch('label'), 'classification' => error.record.fetch('process_classification'),
        'exit' => error.record.fetch('exit'), 'signal' => error.record.fetch('signal'),
        'stderr_sha256' => error.record.fetch('stderr_sha256'),
      }
    rescue StandardError => error
      result['status'] = 'script_or_local_error'
      result['error'] = "#{error.class}: #{error.message}"
      @fatal_error ||= result['error']
      @failures << {'profile' => profile.fetch(:id), 'direction' => direction, 'error' => result['error']}
    ensure
      @direction_results << result
      write_json("result-#{direction}-#{profile.fetch(:id)}.json", result)
    end
  end

  def run_stock_direction(profile, result)
    store = create_store("stock-store-#{profile.fetch(:id)}")
    query_profile!(result, 'create', store, ddl(profile.fetch(:count_type)))
    query_profile!(result, 'insert', store, 'INSERT INTO t FORMAT RowBinary', rowbinary((0...EXPECTED_ROWS).to_a))
    live_table_checks(profile, result, store)

    profile_output = File.join(@stock_root, "part-#{profile.fetch(:id)}")
    Dir.mkdir(profile_output, 0o700)
    part_output = File.join(profile_output, 'all_1_1_0')
    copy_part_from_stock_store!(profile.fetch(:id), store, part_output, result)
  end

  def run_library_direction(profile, result)
    source = File.join(@library_root, "part-#{profile.fetch(:id)}", 'all_1_1_0')
    source_hash_before = tree_sha256(source)
    store = create_store("library-store-#{profile.fetch(:id)}")
    query_profile!(result, 'create', store, ddl(profile.fetch(:count_type)))
    table_path_text = query_profile!(result, 'table-path', store, QUERY_TABLE_PATH)
    table_path = checked_table_path!(table_path_text, store)
    detached = File.join(table_path, 'detached')
    if File.exist?(detached) || File.symlink?(detached)
      stat = File.lstat(detached)
      raise 'detached path is a symlink or non-directory' unless stat.directory? && !stat.symlink?
      raise 'fresh detached directory is not empty' unless Dir.children(detached).empty?
    else
      Dir.mkdir(detached, 0o700)
    end
    destination = File.join(detached, 'all_1_1_0')
    copy_tree_exclusive!(source, destination)
    result['library_part_tree_sha256'] = source_hash_before
    result['copied_part_tree_sha256'] = tree_sha256(destination)
    compare(result, 'library_part_copy', result.fetch('copied_part_tree_sha256'), source_hash_before)
    query_profile!(result, 'attach', store, "ALTER TABLE t ATTACH PART 'all_1_1_0'")
    live_table_checks(profile, result, store)
    source_hash_after = tree_sha256(source)
    result['library_part_tree_sha256_after'] = source_hash_after
    compare(result, 'library_part_unchanged', source_hash_after, source_hash_before)
  end

  def live_table_checks(profile, result, store)
    check = query_profile!(result, 'check', store, QUERY_CHECK)
    compare_bytes(result, 'check_table', check, CHECK_OUTPUT)

    schema = query_profile!(result, 'schema', store, QUERY_SCHEMA)
    expected_schema = "pk\tUInt64\nc\t#{profile.fetch(:count_type)}\n".b
    compare_bytes(result, 'system_columns_schema', schema, expected_schema)

    type_name = query_profile!(result, 'type-name', store, QUERY_TYPE_NAME)
    compare_bytes(result, 'to_type_name', type_name, "#{profile.fetch(:count_type)}\n".b)

    part_info = query_profile!(result, 'part-info', store, QUERY_PART)
    part_path = validate_part_axes(profile, result, part_info, store)
    result['part_path_relative_to_store'] = part_path && part_path.delete_prefix(File.realpath(store) + '/')

    full = query_profile!(result, 'full-rowbinary', store, QUERY_FULL)
    expected_full = rowbinary((0...EXPECTED_ROWS).to_a)
    compare_bytes(result, 'full_rowbinary_literals', full, expected_full)
    @sensitivity_observed = full if profile.fetch(:id) == 'nothing' && result.fetch('direction') == 'stock_to_library'

    middle = query_profile!(result, 'middle-rowbinary', store, QUERY_WINDOW)
    compare_bytes(result, 'middle_rowbinary_literals', middle, rowbinary([2, 3]))

    empty = query_profile!(result, 'empty-rowbinary', store, QUERY_EMPTY)
    compare_bytes(result, 'empty_rowbinary', empty, ''.b)

    finalized = query_profile!(result, 'finalize', store, QUERY_FINAL)
    compare_bytes(result, 'finalized_counts', finalized, expected_finalized((0...EXPECTED_ROWS).to_a))
  end

  def validate_part_axes(profile, result, output, store)
    lines = output.force_encoding(Encoding::UTF_8).lines(chomp: true)
    unless lines.length == 1
      compare(result, 'part_row_count', lines.length, 1)
      return nil
    end
    fields = lines.first.split("\t", -1)
    unless fields.length == 5
      compare(result, 'part_axes_field_count', fields.length, 5)
      return nil
    end

    name, raw_path, part_type, rows, marks = fields
    compare(result, 'part_name', name, 'all_1_1_0')
    compare(result, 'part_type', part_type, 'Wide')
    compare(result, 'part_rows', rows, EXPECTED_ROWS.to_s)
    compare(result, 'part_marks', marks, EXPECTED_MARKS.to_s)
    path = checked_part_path!(raw_path, store)
    path
  rescue EncodingError => error
    result['checks']['part_axes_encoding'] = {'passed' => false, 'error' => error.message}
    @failures << {'profile' => profile.fetch(:id), 'direction' => result.fetch('direction'), 'check' => 'part_axes_encoding'}
    nil
  end

  def copy_part_from_stock_store!(id, store, destination, result)
    # The exact path was safety-checked while validating system.parts. Resolve
    # it again from the captured invocation output instead of trusting summary
    # JSON or a caller-provided path.
    raw = @invocations.reverse.find { |record| record.fetch('label') == result.fetch('invocations').fetch('part-info') }
    raise 'missing recorded part-info invocation' unless raw
    stdout_path = File.join(@evidence_root, raw.fetch('stdout_file'))
    data = File.binread(stdout_path)
    fields = data.force_encoding(Encoding::UTF_8).lines(chomp: true).first.to_s.split("\t", -1)
    raise 'stock part-info row is malformed' unless fields.length == 5
    source = checked_part_path!(fields[1], store)
    raise 'stock output destination escapes its root' unless destination.start_with?(@stock_root + '/')
    copy_tree_exclusive!(source, destination)
    copied_hash = tree_sha256(destination)
    source_hash = tree_sha256(source)
    compare(result, 'stock_part_copy', copied_hash, source_hash)
    result['stock_part_tree_sha256'] = source_hash
    result['stock_output_relative_path'] = destination.delete_prefix(@stock_root + '/')
    nil
  end

  def checked_table_path!(text, store)
    lines = text.force_encoding(Encoding::UTF_8).lines(chomp: true).reject(&:empty?)
    raise 'table data path query did not return exactly one path' unless lines.length == 1
    path = File.expand_path(lines.first)
    checked_path_under_store!(path, store)
    stat = File.lstat(path)
    raise 'ClickHouse table path is symlink or not a directory' unless stat.directory? && !stat.symlink?
    File.realpath(path)
  end

  def checked_part_path!(raw_path, store)
    raise 'ClickHouse part path is empty' if raw_path.empty?
    path = File.expand_path(raw_path)
    checked_path_under_store!(path, store)
    stat = File.lstat(path)
    raise 'ClickHouse part path is symlink or not a directory' unless stat.directory? && !stat.symlink?
    validate_tree!(path)
    File.realpath(path)
  end

  def checked_path_under_store!(path, store)
    real_store = File.realpath(store)
    raise 'ClickHouse returned a path outside its private store' unless path.start_with?(real_store + '/')
    raise 'ClickHouse returned a noncanonical store path' unless File.realpath(path) == path
    nil
  end

  def copy_tree_exclusive!(source, destination)
    raise 'copy source must be a real directory' if File.symlink?(source) || !File.directory?(source)
    source_real = File.realpath(source)
    destination_parent = File.dirname(destination)
    raise 'copy destination parent must be a real directory' if File.symlink?(destination_parent) || !File.directory?(destination_parent)
    raise 'copy destination already exists' if File.exist?(destination) || File.symlink?(destination)
    validate_tree!(source_real)
    copy_directory_contents(source_real, destination)
    raise 'copied part tree differs from source' unless tree_sha256(source_real) == tree_sha256(destination)
    nil
  end

  def copy_directory_contents(source, destination)
    Dir.mkdir(destination, 0o700)
    Dir.children(source).sort.each do |name|
      raise 'part entry contains a path separator' if name.include?('/') || name == '.' || name == '..'
      source_entry = File.join(source, name)
      destination_entry = File.join(destination, name)
      stat = File.lstat(source_entry)
      raise "symlink or special part entry: #{name}" if stat.symlink? || !(stat.file? || stat.directory?)
      if stat.directory?
        copy_directory_contents(source_entry, destination_entry)
      else
        copy_regular_file_exclusive(source_entry, destination_entry, stat)
      end
    end
    File.chmod(0o700, destination)
  end

  def copy_regular_file_exclusive(source, destination, source_stat)
    File.open(source, 'rb') do |input|
      opened = input.stat
      unless opened.file? && opened.dev == source_stat.dev && opened.ino == source_stat.ino
        raise 'part file changed or ceased to be regular during copy'
      end
      File.open(destination, 'wbx', 0o600) do |output|
        while (chunk = input.read(65_536))
          output.write(chunk)
        end
        output.flush
        output.fsync
      end
    end
    File.chmod(0o600, destination)
  end

  def tree_sha256(root)
    digest = Digest::SHA256.new
    visit = lambda do |path, relative|
      stat = File.lstat(path)
      raise "symlink or special tree entry: #{path}" if stat.symlink? || !(stat.file? || stat.directory?)
      digest.update(stat.directory? ? "D\0#{relative}\0" : "F\0#{relative}\0#{stat.size}\0")
      if stat.directory?
        Dir.children(path).sort.each do |name|
          child_relative = relative.empty? ? name : "#{relative}/#{name}"
          visit.call(File.join(path, name), child_relative)
        end
      else
        File.open(path, 'rb') do |file|
          while (chunk = file.read(65_536))
            digest.update(chunk)
          end
        end
      end
    end
    visit.call(root, '')
    digest.hexdigest
  end

  def compare_bytes(result, name, actual, expected)
    pass = actual.b == expected.b
    result.fetch('checks')[name] = {
      'passed' => pass, 'expected_sha256' => Digest::SHA256.hexdigest(expected.b),
      'actual_sha256' => Digest::SHA256.hexdigest(actual.b),
      'expected_bytes' => expected.bytesize, 'actual_bytes' => actual.bytesize,
      'expected_hex' => expected.unpack1('H*'), 'actual_hex' => actual.unpack1('H*'),
    }
    record_check_failure(result, name) unless pass
    pass
  end

  def compare(result, name, actual, expected)
    pass = actual == expected
    result.fetch('checks')[name] = {'passed' => pass, 'expected' => expected, 'actual' => actual}
    record_check_failure(result, name) unless pass
    pass
  end

  def record_check_failure(result, name)
    @failures << {
      'profile' => result.fetch('profile'), 'direction' => result.fetch('direction'),
      'check' => name, 'outcome' => 'qualification_mismatch',
    }
  end

  def add_failure(area, message, details = {})
    @failures << {'area' => area, 'error' => message}.merge(details)
  end

  # This only checks that the in-memory literal comparator distinguishes 128
  # from 129. It does not mutate, reread, or CHECK a physical part.
  def assess_in_memory_literal_control
    expected = rowbinary((0...EXPECTED_ROWS).to_a)
    control_expected = expected.dup
    third_state_offset = KEYS.take(2).sum { |key| 8 + STATES[KEYS.index(key)].bytesize } + 8
    raise 'W178 128->129 sensitivity offset is invalid' unless expected.byteslice(third_state_offset, 2) == [0x80, 0x01].pack('C*')
    control_expected.setbyte(third_state_offset, 0x81)
    baseline_match = @sensitivity_observed == expected
    control_distinguished = !(@sensitivity_observed == control_expected)
    @sensitivity = {
      'kind' => 'in_memory_expected_rowbinary_literal_control_only',
      'profile' => 'nothing', 'row_index' => 2, 'expected_count' => 128,
      'control_count' => 129, 'baseline_literal_match' => baseline_match,
      'control_expected_hex' => control_expected.unpack1('H*'),
      'control_distinguished_by_exact_rowbinary_comparator' => control_distinguished,
      'no_physical_part_mutation_or_reread' => true,
      'qualified' => baseline_match && control_distinguished,
    }
    unless @sensitivity.fetch('qualified')
      add_failure('sensitivity', '128-to-129 in-memory literal comparator control did not qualify', @sensitivity)
    end
  end

  def run_postflight_pin
    @runtime_after = file_sha256(BINARY)
    if @runtime_before == SHA256 && @runtime_after == SHA256
      begin
        store = create_store('runtime-pin-after')
        invocation = query('runtime-pin-after', store, VERSION_SQL)
        @pin_after = invocation.stdout
        add_failure('runtime', 'post-run version/build pin mismatch', expected: VERSION, actual: @pin_after) unless @pin_after == VERSION
      rescue StandardError => error
        add_failure('runtime', 'post-run version/build could not be verified', error: "#{error.class}: #{error.message}")
      end
    else
      add_failure('runtime', 'pinned ClickHouse executable hash changed during oracle',
                  expected: SHA256, before: @runtime_before, after: @runtime_after)
    end
  rescue StandardError => error
    add_failure('runtime', 'post-run binary hash check failed', error: "#{error.class}: #{error.message}")
  end

  def summary
    {
      'classification' => 'clickhouse_component_gate_for_paired_w178_qualification',
      'qualification_scope' => 'This component creates and checks stock-authored parts for the external Crystal W178_STOCK_ROOT consumer spec, then attaches and checks library-authored parts in ClickHouse. The overall paired qualification additionally requires the separately executed external 63-profile Crystal stock-part consumer gate; this script does not execute that consumer gate.',
      'runtime' => {
        'path' => BINARY, 'expected_sha256' => SHA256,
        'sha256_before' => @runtime_before, 'sha256_after' => @runtime_after,
        'expected_version_build_stdout' => VERSION.dup.force_encoding(Encoding::UTF_8),
        'observed_pre_version_build_stdout' => @pin_before&.dup&.force_encoding(Encoding::UTF_8),
        'observed_post_version_build_stdout' => @pin_after&.dup&.force_encoding(Encoding::UTF_8),
      },
      'roots' => {'evidence' => @evidence_root, 'library_parts' => @library_root, 'stock_parts' => @stock_root},
      'matrix' => {
        'planned_profiles' => PROFILE_ROWS.length,
        'distinct_canonical_arguments' => PROFILE_ROWS.map { |row| row.fetch(:argument_name) }.uniq.length,
        'completed_directions' => @direction_results.count { |result| result.fetch('status') == 'qualified' },
        'expected_directions' => PROFILE_ROWS.length * 2,
        'stock_to_library' => @direction_results.count { |result| result.fetch('direction') == 'stock_to_library' && result.fetch('status') == 'qualified' },
        'library_to_stock' => @direction_results.count { |result| result.fetch('direction') == 'library_to_stock' && result.fetch('status') == 'qualified' },
      },
      'literal_oracle' => {'states_hex' => STATE_HEX, 'keys' => KEYS, 'finalized_counts' => COUNTS},
      'in_memory_literal_comparator_control' => @sensitivity,
      'gate_failures' => @failures,
      'fatal_error' => @fatal_error,
      'direction_results' => @direction_results,
      'invocations' => @invocations,
      'exit_policy' => 'This ClickHouse component exits zero only if its 63 stock-part creation/check/export cases and 63 library-part attach/check cases qualify. The overall paired DoD additionally requires a separately executed external Crystal spec with W178_STOCK_ROOT set, passing all 63 stock-authored-part consumer cases. This script does not execute that Crystal consumer gate. Semantic server rejection, nominal drift, literal mismatch, CHECK failure, or physical-axis mismatch in this component returns nonzero.',
    }
  end

  def file_sha256(path)
    Digest::SHA256.file(path).hexdigest
  end

  def write_exclusive(name, bytes)
    raise 'unsafe evidence filename' unless /\A[a-zA-Z0-9_.-]+\z/.match?(name)
    path = File.join(@evidence_root, name)
    File.open(path, 'wbx', 0o600) { |file| file.write(bytes); file.flush; file.fsync }
    File.chmod(0o600, path)
    path
  end

  def write_json(name, value)
    write_exclusive(name, JSON.pretty_generate(value))
  end
end

abort 'usage: ruby recheck_aggregate_count_arguments_w178.rb EMPTY_EVIDENCE_ROOT LIBRARY_PART_ROOT EMPTY_STOCK_PART_ROOT' unless ARGV.length == 3
exit(AggregateCountArgumentPairedOracle.new(ARGV.fetch(0), ARGV.fetch(1), ARGV.fetch(2)).run ? 0 : 1)
