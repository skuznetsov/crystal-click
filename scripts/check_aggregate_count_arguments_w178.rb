# Root-only serial ClickHouse diagnostic. The caller supplies an existing,
# empty evidence directory under /private/tmp. This probes only the pinned
# stock executable; it does not compile source or claim general Count support.
require 'digest'
require 'json'
require 'open3'

class AggregateCountArgumentProbe
  BINARY = '/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped'
  SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'
  VERSION = "26.10.1.1201\td9bcb5ab007f0f6299f7f973f2642245bab3d028\n".b
  VERSION_SQL = "SELECT version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSV"
  ROW_BINARY_SQL = 'SELECT c FROM t ORDER BY finalizeAggregation(c) FORMAT RowBinary'
  TYPE_NAME_SQL = 'SELECT DISTINCT toTypeName(c) FROM t FORMAT TSVRaw'
  COLUMN_TYPE_SQL = "SELECT type FROM system.columns WHERE database='default' AND table='t' AND name='c' FORMAT TSVRaw"
  FINALIZE_SQL = 'SELECT finalizeAggregation(c) FROM t ORDER BY finalizeAggregation(c) FORMAT TSV'

  # These are independent literal Count VarUInts, not values produced by a
  # ClickHouse or Crystal encoder. Keep each item visible in the evidence.
  STATE_HEX = %w[00 7f 8001 808001 ffffffffffffffffff01].freeze
  STATES = STATE_HEX.map { |hex| [hex].pack('H*').b }.freeze
  INPUT = STATES.join.b.freeze
  COUNTS = %w[0 127 128 16384 18446744073709551615].freeze
  NULLABLE_NOTHING_ZERO_HEX = %w[00 00 00 00 00].freeze
  NULLABLE_NOTHING_ZERO_INPUT = NULLABLE_NOTHING_ZERO_HEX.map { |hex| [hex].pack('H*').b }.join.b.freeze
  ZERO_COUNTS = Array.new(STATE_HEX.length, '0').freeze
  NULLABLE_NOTHING_CANONICAL_TYPE = 'AggregateFunction(nothingUInt64, Nullable(Nothing))'.freeze

  # A successful CREATE is factory/metadata admission only. Bare Nothing is
  # tested as ordinary Count. Nullable(Nothing) gets separate five-zero and
  # nonzero-input witnesses because its supported serializer is zero-only.
  ARGUMENTS = [
    ['nothing', 'Nothing', 'candidate'],
    ['nullable_nothing', 'Nullable(Nothing)', 'special_case'],
    ['bool', 'Bool', 'candidate'],
    ['uint8', 'UInt8', 'candidate'],
    ['uint16', 'UInt16', 'candidate'],
    ['uint32', 'UInt32', 'candidate'],
    ['uint64', 'UInt64', 'candidate'],
    ['uint128', 'UInt128', 'candidate'],
    ['uint256', 'UInt256', 'candidate'],
    ['int8', 'Int8', 'candidate'],
    ['int16', 'Int16', 'candidate'],
    ['int32', 'Int32', 'candidate'],
    ['int64', 'Int64', 'candidate'],
    ['int128', 'Int128', 'candidate'],
    ['int256', 'Int256', 'candidate'],
    ['bfloat16', 'BFloat16', 'candidate'],
    ['float32', 'Float32', 'candidate'],
    ['float64', 'Float64', 'candidate'],
    ['string', 'String', 'candidate'],
    ['fixed_string_1', 'FixedString(1)', 'candidate'],
    ['fixed_string_16', 'FixedString(16)', 'candidate'],
    ['enum8', "Enum8('zero' = 0, 'one' = 1)", 'candidate'],
    ['enum16', "Enum16('zero' = 0, 'one' = 1)", 'candidate'],
    ['decimal32', 'Decimal32(2)', 'candidate'],
    ['decimal64', 'Decimal64(4)', 'candidate'],
    ['decimal128', 'Decimal128(8)', 'candidate'],
    ['decimal256', 'Decimal256(12)', 'candidate'],
    ['decimal_generic', 'Decimal(18, 4)', 'candidate'],
    ['date', 'Date', 'candidate'],
    ['date32', 'Date32', 'candidate'],
    ['datetime', 'DateTime', 'candidate'],
    ['datetime_utc', "DateTime('UTC')", 'candidate'],
    ['datetime_new_york', "DateTime('America/New_York')", 'candidate'],
    ['datetime64_0', 'DateTime64(0)', 'candidate'],
    ['datetime64_3', 'DateTime64(3)', 'candidate'],
    ['datetime64_9', 'DateTime64(9)', 'candidate'],
    ['datetime64_3_utc', "DateTime64(3, 'UTC')", 'candidate'],
    ['datetime64_3_new_york', "DateTime64(3, 'America/New_York')", 'candidate'],
    ['time', 'Time', 'candidate'],
    ['time64_0', 'Time64(0)', 'candidate'],
    ['time64_3', 'Time64(3)', 'candidate'],
    ['time64_9', 'Time64(9)', 'candidate'],
    ['time64_3_utc', "Time64(3, 'UTC')", 'candidate'],
    ['time64_3_berlin', "Time64(3, 'Europe/Berlin')", 'candidate'],
    ['uuid', 'UUID', 'candidate'],
    ['ipv4', 'IPv4', 'candidate'],
    ['ipv6', 'IPv6', 'candidate'],
    ['nullable_uint8', 'Nullable(UInt8)', 'candidate'],
    ['nullable_string', 'Nullable(String)', 'candidate'],
    ['nullable_decimal', 'Nullable(Decimal(9, 2))', 'candidate'],
    ['nullable_zoned_datetime64', "Nullable(DateTime64(3, 'UTC'))", 'candidate'],
    ['array_uint8', 'Array(UInt8)', 'candidate'],
    ['array_nullable_uint8', 'Array(Nullable(UInt8))', 'candidate'],
    ['tuple_scalars', 'Tuple(UInt8, String)', 'candidate'],
    ['tuple_named', 'Tuple(id UInt64, label Nullable(String))', 'candidate'],
    ['map_string_uint64', 'Map(String, UInt64)', 'candidate'],
    ['low_cardinality_string', 'LowCardinality(String)', 'candidate'],
    ['low_cardinality_nullable_string', 'LowCardinality(Nullable(String))', 'candidate'],
    # Nothing has no dictionary values, so this LC constructor is a grammar control.
    ['low_cardinality_nullable_nothing_control', 'LowCardinality(Nullable(Nothing))', 'known_negative'],
    ['variant', 'Variant(UInt8, String)', 'candidate'],
    ['dynamic', 'Dynamic', 'candidate'],
    ['json', 'JSON', 'candidate'],
    ['json_max_dynamic_paths', 'JSON(max_dynamic_paths=8)', 'candidate'],
    ['object_json', "Object('json')", 'candidate'],
    ['nested', 'Nested(x UInt8, y String)', 'candidate'],
    ['simple_aggregate_sum', 'SimpleAggregateFunction(sum, UInt64)', 'candidate'],
    ['simple_aggregate_any', 'SimpleAggregateFunction(any, String)', 'candidate'],
    ['aggregate_function_sum', 'AggregateFunction(sum, UInt64)', 'candidate'],
    ['aggregate_function_count', 'AggregateFunction(count)', 'candidate'],
    ['aggregate_function_count_uint64', 'AggregateFunction(count, UInt64)', 'candidate'],
    ['nullable_array_control', 'Nullable(Array(UInt8))', 'known_negative'],
    ['nullable_nullable_control', 'Nullable(Nullable(UInt8))', 'known_negative'],
  ].map do |id, argument, expectation|
    {id: id, argument: argument, column_type: "AggregateFunction(count, #{argument})", expectation: expectation}
  end + [
    {id: 'count_parameters_control', argument: nil,
     column_type: 'AggregateFunction(count(1), UInt64)', expectation: 'known_negative'},
    {id: 'count_two_arguments_control', argument: nil,
     column_type: 'AggregateFunction(count, UInt8, UInt64)', expectation: 'known_negative'},
    {id: 'outer_nullable_control', argument: nil,
     column_type: 'Nullable(AggregateFunction(count, UInt64))', expectation: 'known_negative'},
  ].freeze

  PROCESS_TIMEOUT_SECONDS = 10
  TERMINATION_GRACE_SECONDS = 2
  SYSTEM_FAILURE = /no space left|disk quota|read.only file system|permission denied|cannot allocate memory|out of memory|memory limit|i\/o error|bad file descriptor|too many open files|resource temporarily unavailable|cannot open file|cannot create file/i
  CLICKHOUSE_EXCEPTION = /\bCode:\s*\d+\.|\bDB::Exception:/
  TYPE_REJECTION_STAGES = %w[create insert rowbinary_read]

  Invocation = Struct.new(:record, :stdout, :stderr, :status, :timed_out, :spawn_error,
                          :stdin_write_error, :stdout_read_error, :stderr_read_error,
                          keyword_init: true)

  def initialize(root)
    raise 'usage requires one existing EMPTY evidence directory' unless root
    raise 'unsafe evidence directory' if File.symlink?(root)
    @root = File.realpath(root)
    unless @root.start_with?('/private/tmp/') && File.directory?(@root) && Dir.children(@root).empty?
      raise 'unsafe evidence directory: expected an existing empty /private/tmp child'
    end
    @records = []
    @results = []
  end

  def run
    before = Digest::SHA256.file(BINARY).hexdigest
    pin = nil
    pin_matches = false
    probe_status = 'not_run_runtime_pin_failed'

    if before == SHA256
      store = create_store('pin-store')
      pin = invoke('pin-version', store, VERSION_SQL)
      pin_matches = successful?(pin) && pin.stdout == VERSION
      if pin_matches
        probe_status = 'diagnostic_completed'
        ARGUMENTS.each { |profile| @results << probe_profile(profile) }
      end
    end

    # Recheck the build identity after the diagnostic as well as the executable
    # digest. Do not invoke an unpinned or changed binary for the second check.
    before_post_pin = Digest::SHA256.file(BINARY).hexdigest
    post_pin = nil
    post_pin_matches = false
    if before == SHA256 && before_post_pin == SHA256
      post_store = create_store('post-pin-store')
      post_pin = invoke('pin-version-after', post_store, VERSION_SQL)
      post_pin_matches = successful?(post_pin) && post_pin.stdout == VERSION
      probe_status = 'post_runtime_pin_failed' unless post_pin_matches
    else
      probe_status = 'post_runtime_hash_changed'
    end

    after = Digest::SHA256.file(BINARY).hexdigest
    summary = build_summary(before, after, pin, pin_matches, post_pin, post_pin_matches,
                            before_post_pin, probe_status)
    write_json('summary.json', summary)
    print_summary(summary)

    pin_matches && post_pin_matches && before == SHA256 && before == after &&
      !@results.any? { |result| result[:outcome] == 'runtime_or_system_error' }
  end

  private

  def create_store(name)
    path = File.join(@root, name)
    Dir.mkdir(path, 0o700)
    path
  end

  def invoke(label, store, sql, input = ''.b)
    raise 'unsafe evidence label' unless /\A[a-z0-9_-]+\z/.match?(label)
    args = [BINARY, 'local', '--path', store, '--max_threads=1', '--max_insert_threads=1',
            '--max_memory_usage=1073741824', '--query', sql]
    stdout, stderr, status, timed_out, spawn_error, stdin_error, stdout_error, stderr_error =
      execute(args, input)

    record = {
      label: label, sql: sql, argv: args,
      exit: status&.exitstatus, signal: status&.termsig, timed_out: timed_out,
      timeout_seconds: PROCESS_TIMEOUT_SECONDS,
      spawn_error: spawn_error, stdin_write_error: stdin_error,
      stdout_read_error: stdout_error, stderr_read_error: stderr_error,
      process_classification: process_classification(status, timed_out, spawn_error, stdin_error,
                                                     stdout_error, stderr_error, stderr),
      input_sha256: Digest::SHA256.hexdigest(input),
      stdout_sha256: Digest::SHA256.hexdigest(stdout),
      stderr_sha256: Digest::SHA256.hexdigest(stderr),
      input_file: "#{label}.input", stdout_file: "#{label}.stdout",
      stderr_file: "#{label}.stderr", record_file: "#{label}.json",
    }
    write(record[:input_file], input)
    write(record[:stdout_file], stdout)
    write(record[:stderr_file], stderr)
    write_json(record[:record_file], record)
    @records << record
    Invocation.new(record: record, stdout: stdout, stderr: stderr, status: status,
                   timed_out: timed_out, spawn_error: spawn_error, stdin_write_error: stdin_error,
                   stdout_read_error: stdout_error, stderr_read_error: stderr_error)
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

  def process_classification(status, timed_out, spawn_error, stdin_error, stdout_error, stderr_error, stderr)
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

  def successful?(invocation)
    invocation.record[:process_classification] == 'success'
  end

  def failure_outcome(invocation, stage)
    classification = invocation.record[:process_classification]
    if classification == 'server_exception'
      outcome = TYPE_REJECTION_STAGES.include?(stage) ? 'server_rejected' : 'server_operation_rejected'
    else
      outcome = 'runtime_or_system_error'
    end
    {outcome: outcome, failure_stage: stage, failure_classification: classification}
  end

  def probe_profile(profile)
    return probe_nullable_nothing_profile(profile) if profile.fetch(:id) == 'nullable_nothing'

    id = profile.fetch(:id)
    store = create_store("store-#{id}")
    result = {profile: id, expectation: profile.fetch(:expectation),
              argument_type: profile[:argument], declared_type: profile.fetch(:column_type),
              factory_admitted: false, input_accepted: false}

    create = invoke("#{id}-create", store,
                    "CREATE TABLE t (c #{profile.fetch(:column_type)}) ENGINE=MergeTree ORDER BY tuple()")
    result[:create_invocation] = create.record[:label]
    unless successful?(create)
      result.merge!(failure_outcome(create, 'create'))
      return persist_profile(result)
    end
    result[:factory_admitted] = true

    insert = invoke("#{id}-insert", store, 'INSERT INTO t FORMAT RowBinary', INPUT)
    result[:insert_invocation] = insert.record[:label]
    unless successful?(insert)
      result.merge!(failure_outcome(insert, 'insert'))
      return persist_profile(result)
    end
    result[:input_accepted] = true

    lane = invoke("#{id}-rowbinary", store, ROW_BINARY_SQL)
    result[:rowbinary_invocation] = lane.record[:label]
    unless successful?(lane)
      result.merge!(failure_outcome(lane, 'rowbinary_read'))
      return persist_profile(result)
    end
    result[:rowbinary_lane] = {
      expected_hex: STATE_HEX.join,
      actual_hex: lane.stdout.unpack1('H*'),
      expected_sha256: Digest::SHA256.hexdigest(INPUT),
      actual_sha256: Digest::SHA256.hexdigest(lane.stdout),
      expected_bytes: INPUT.bytesize,
      actual_bytes: lane.stdout.bytesize,
      exact_literal_match: lane.stdout == INPUT,
    }

    type_name = invoke("#{id}-type-name", store, TYPE_NAME_SQL)
    column_type = invoke("#{id}-column-type", store, COLUMN_TYPE_SQL)
    finalized = invoke("#{id}-finalize", store, FINALIZE_SQL)
    result[:type_name_invocation] = type_name.record[:label]
    result[:column_type_invocation] = column_type.record[:label]
    result[:finalize_invocation] = finalized.record[:label]

    inspection = {'type_name' => type_name, 'column_type' => column_type, 'finalize' => finalized}
    failed_inspection = inspection.find { |_name, invocation| !successful?(invocation) }
    if failed_inspection
      name, invocation = failed_inspection
      result.merge!(failure_outcome(invocation, name))
      result[:outcome] = 'server_operation_rejected' if result[:outcome] == 'server_rejected'
      return persist_profile(result)
    end

    type_names = type_name.stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
    column_types = column_type.stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
    result[:canonical_names] = {to_type_name: type_names, system_columns: column_types}
    result[:canonicalization_matches_storage_metadata] = type_names.length == 1 &&
      column_types.length == 1 && type_names.first == column_types.first
    result[:nominal_aggregate_function_count] = type_names.length == 1 &&
      type_names.first.start_with?('AggregateFunction(count, ')

    finalized_values = finalized.stdout.force_encoding(Encoding::UTF_8).lines.map(&:strip)
    result[:finalized_values] = finalized_values
    result[:finalized_matches_literal_counts] = finalized_values == COUNTS
    result[:finalized_all_zero] = !finalized_values.empty? && finalized_values.all? { |value| value == '0' }

    if result[:rowbinary_lane][:exact_literal_match] &&
       result[:canonicalization_matches_storage_metadata] &&
       result[:nominal_aggregate_function_count] &&
       result[:finalized_matches_literal_counts]
      result[:outcome] = 'admitted_exact_ordinary_count_lane'
    elsif result[:rowbinary_lane][:exact_literal_match] && result[:finalized_all_zero]
      result[:outcome] = 'admitted_stateless_or_zero_finalization_observed'
    else
      result[:outcome] = 'admitted_with_lane_nominal_or_finalization_mismatch'
    end
    persist_profile(result)
  end

  def persist_profile(result)
    write_json("profile-#{result.fetch(:profile)}.json", result)
    result
  end

  def probe_nullable_nothing_profile(profile)
    nonzero = probe_nullable_nothing_witness('nonzero', INPUT, COUNTS)
    zero_only = probe_nullable_nothing_witness('zero-only', NULLABLE_NOTHING_ZERO_INPUT, ZERO_COUNTS)
    witnesses = [nonzero, zero_only]
    canonical_names = zero_only[:canonical_names] || {}
    observed_type_names = canonical_names[:to_type_name] || []
    observed_column_types = canonical_names[:system_columns] || []
    exact_type_name = observed_type_names == [NULLABLE_NOTHING_CANONICAL_TYPE]
    exact_column_type = observed_column_types == [NULLABLE_NOTHING_CANONICAL_TYPE]
    result = {
      profile: profile.fetch(:id), expectation: profile.fetch(:expectation),
      argument_type: profile.fetch(:argument), declared_type: profile.fetch(:column_type),
      factory_admitted: witnesses.all? { |witness| witness[:factory_admitted] },
      input_accepted: zero_only[:input_accepted],
      nullable_nothing_nonzero_input_rejected: nonzero[:input_rejected],
      nullable_nothing_zero_only_input_accepted: zero_only[:input_accepted],
      canonical_names: canonical_names,
      normalized_function: {
        declared_function: 'count', canonical_function_name: 'nothingUInt64',
        expected_canonical_type: NULLABLE_NOTHING_CANONICAL_TYPE,
        to_type_name_exact_match: exact_type_name,
        system_columns_exact_match: exact_column_type,
        exact_expected_identity: exact_type_name && exact_column_type,
      },
      witnesses: {nonzero_input: nonzero, zero_only_input: zero_only},
    }

    if witnesses.any? { |witness| witness[:outcome] == 'runtime_or_system_error' }
      result[:outcome] = 'runtime_or_system_error'
    elsif witnesses.any? { |witness| witness[:outcome] == 'server_operation_rejected' }
      result[:outcome] = 'server_operation_rejected'
    elsif witnesses.any? { |witness| !witness[:factory_admitted] }
      result[:outcome] = witnesses.any? { |witness| witness[:outcome] == 'server_rejected' } ?
        'server_rejected' : 'runtime_or_system_error'
    elsif !zero_only[:input_accepted]
      result[:outcome] = zero_only[:outcome]
    elsif nonzero[:input_rejected] && exact_type_name && exact_column_type &&
          zero_only[:exact_lane_match] && zero_only[:finalized_matches_expected]
      result[:outcome] = 'canonicalized_to_nothing_uint64_zero_only_with_nonzero_rejection'
    elsif nonzero[:input_accepted]
      result[:outcome] = 'canonicalized_special_nonzero_input_not_rejected'
    else
      result[:outcome] = 'canonicalized_special_witness_mismatch'
    end

    persist_profile(result)
  end

  def probe_nullable_nothing_witness(name, input, expected_counts)
    store = create_store("store-nullable_nothing-#{name}")
    witness = {factory_admitted: false, input_accepted: false, input_rejected: false,
               expected_input_hex: input.unpack1('H*'), expected_counts: expected_counts}

    create = invoke("nullable-nothing-#{name}-create", store,
                    'CREATE TABLE t (c AggregateFunction(count, Nullable(Nothing))) ENGINE=MergeTree ORDER BY tuple()')
    witness[:create_invocation] = create.record[:label]
    unless successful?(create)
      witness.merge!(failure_outcome(create, 'create'))
      return witness
    end
    witness[:factory_admitted] = true

    insert = invoke("nullable-nothing-#{name}-insert", store, 'INSERT INTO t FORMAT RowBinary', input)
    witness[:insert_invocation] = insert.record[:label]
    unless successful?(insert)
      witness[:input_rejected] = insert.record[:process_classification] == 'server_exception'
      witness.merge!(failure_outcome(insert, 'insert'))
      return witness
    end
    witness[:input_accepted] = true

    lane = invoke("nullable-nothing-#{name}-rowbinary", store, ROW_BINARY_SQL)
    type_name = invoke("nullable-nothing-#{name}-type-name", store, TYPE_NAME_SQL)
    column_type = invoke("nullable-nothing-#{name}-column-type", store, COLUMN_TYPE_SQL)
    finalized = invoke("nullable-nothing-#{name}-finalize", store, FINALIZE_SQL)
    witness[:rowbinary_invocation] = lane.record[:label]
    witness[:type_name_invocation] = type_name.record[:label]
    witness[:column_type_invocation] = column_type.record[:label]
    witness[:finalize_invocation] = finalized.record[:label]

    inspection = {'rowbinary_read' => lane, 'type_name' => type_name,
                  'column_type' => column_type, 'finalize' => finalized}
    failed_inspection = inspection.find { |_name, invocation| !successful?(invocation) }
    if failed_inspection
      stage, invocation = failed_inspection
      witness.merge!(failure_outcome(invocation, stage))
      return witness
    end

    type_names = type_name.stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
    column_types = column_type.stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
    finalized_values = finalized.stdout.force_encoding(Encoding::UTF_8).lines.map(&:strip)
    witness[:canonical_names] = {to_type_name: type_names, system_columns: column_types}
    witness[:canonicalization_matches_storage_metadata] = type_names.length == 1 &&
      column_types.length == 1 && type_names.first == column_types.first
    witness[:actual_lane_hex] = lane.stdout.unpack1('H*')
    witness[:actual_lane_sha256] = Digest::SHA256.hexdigest(lane.stdout)
    witness[:expected_lane_sha256] = Digest::SHA256.hexdigest(input)
    witness[:exact_lane_match] = lane.stdout == input
    witness[:finalized_values] = finalized_values
    witness[:finalized_matches_expected] = finalized_values == expected_counts
    witness[:finalized_all_zero] = !finalized_values.empty? && finalized_values.all? { |value| value == '0' }
    witness[:outcome] = 'witness_observed'
    witness
  end

  def build_summary(before, after, pin, pin_matches, post_pin, post_pin_matches,
                    before_post_pin, probe_status)
    outcomes = @results.map { |result| result[:outcome] }
    canonical_names = @results.each_with_object({}) do |result, names|
      names[result[:profile]] = result[:canonical_names] if result[:canonical_names]
    end
    {
      classification: 'diagnostic_only_not_a_support_gate',
      runtime: {path: BINARY, expected_sha256: SHA256,
                sha256_before: before, sha256_before_post_pin: before_post_pin,
                sha256_after: after,
                expected_version_build_stdout: VERSION.force_encoding(Encoding::UTF_8)},
      pin_version_invocation: pin&.record&.fetch(:label),
      observed_version_build_stdout: pin&.stdout&.force_encoding(Encoding::UTF_8),
      version_pin_matches: pin_matches,
      post_pin_version_invocation: post_pin&.record&.fetch(:label),
      observed_post_pin_version_build_stdout: post_pin&.stdout&.force_encoding(Encoding::UTF_8),
      post_version_pin_matches: post_pin_matches,
      probe_status: probe_status,
      literal_states: {hex: STATE_HEX, input_sha256: Digest::SHA256.hexdigest(INPUT),
                       input_bytes: INPUT.bytesize, expected_finalized_values: COUNTS},
      counts: {
        planned: ARGUMENTS.length,
        attempted: @results.length,
        admitted: @results.count { |result| result[:factory_admitted] },
        rejected: outcomes.count { |outcome| outcome == 'server_rejected' },
        server_operation_rejections: outcomes.count { |outcome| outcome == 'server_operation_rejected' },
        exact_ordinary_count_lane: outcomes.count { |outcome| outcome == 'admitted_exact_ordinary_count_lane' },
        canonicalized_special_zero_only: outcomes.count do |outcome|
          outcome == 'canonicalized_to_nothing_uint64_zero_only_with_nonzero_rejection'
        end,
        zero_finalization_lane_observations: outcomes.count do |outcome|
          outcome == 'admitted_stateless_or_zero_finalization_observed'
        end,
        lane_nominal_or_finalization_mismatches: outcomes.count do |outcome|
          outcome == 'admitted_with_lane_nominal_or_finalization_mismatch' ||
            outcome == 'canonicalized_special_witness_mismatch' ||
            outcome == 'canonicalized_special_nonzero_input_not_rejected'
        end,
        nullable_nothing_nonzero_input_rejections: @results.count do |result|
          result[:nullable_nothing_nonzero_input_rejected]
        end,
        runtime_or_system_errors: outcomes.count { |outcome| outcome == 'runtime_or_system_error' },
      },
      canonical_names: canonical_names,
      planned_profiles: ARGUMENTS,
      profile_results: @results,
      invocations: @records,
      exit_policy: 'semantic rejections and representation mismatches are observations; runtime pin mismatch, binary hash drift, or runtime/system failures fail the runner',
    }
  end

  def print_summary(summary)
    counts = summary.fetch(:counts)
    puts "W178 Count argument diagnostic: #{counts[:attempted]}/#{counts[:planned]} profiles attempted; " \
         "admitted=#{counts[:admitted]}, rejected=#{counts[:rejected]}, " \
         "exact=#{counts[:exact_ordinary_count_lane]}, " \
         "canonicalized_special_zero_only=#{counts[:canonicalized_special_zero_only]}, " \
         "runtime_or_system_errors=#{counts[:runtime_or_system_errors]}"
    puts "Evidence: #{@root}"
  end

  def write(name, bytes)
    File.open(File.join(@root, name), 'wx', 0o600) { |file| file.write(bytes) }
  end

  def write_json(name, value)
    write(name, JSON.pretty_generate(value))
  end
end

abort 'usage: ruby check_aggregate_count_arguments_w178.rb EMPTY_TMP_EVIDENCE_DIR' unless ARGV.length == 1
exit(AggregateCountArgumentProbe.new(ARGV.fetch(0)).run ? 0 : 1)
