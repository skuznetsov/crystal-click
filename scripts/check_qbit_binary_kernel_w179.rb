# Root-owned, serial native qualification runner for W179. Invoke only beneath
# the externally established ClickHouse resource guard; this script never
# builds ClickHouse or Crystal. It consumes literal library-authored parts and
# preserves stock-authored parts plus per-process provenance.
require 'digest'
require 'json'
require 'open3'
require 'fileutils'

class QBitBinaryKernelW179Probe
  BINARY = '/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped'.freeze
  SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  VERSION = "26.10.1.1201\td9bcb5ab007f0f6299f7f973f2642245bab3d028\n".b.freeze
  VERSION_SQL = "SELECT version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSV".freeze
  PROCESS_TIMEOUT_SECONDS = 10
  TERMINATION_GRACE_SECONDS = 2
  MEMORY_LIMIT_BYTES = 1_073_741_824
  W103_SETTINGS = "index_granularity = 2, index_granularity_bytes = 10485760, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, ratio_of_defaults_for_sparse_serialization = 1.0, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, default_compression_codec = 'LZ4', compute_exact_num_defaults_for_sparse_columns = 0".freeze
  SYSTEM_FAILURE = /no space left|disk quota|read.only file system|permission denied|cannot allocate memory|out of memory|memory limit|i\/o error|bad file descriptor|too many open files|resource temporarily unavailable|cannot open file|cannot create file/i
  CLICKHOUSE_EXCEPTION = /\bCode:\s*\d+\.|\bDB::Exception:/

  CARRIERS = [
    {name: 'Int8', width: 1, bits: 8, tag: 0x07},
    {name: 'BFloat16', width: 2, bits: 16, tag: 0x31},
    {name: 'Float32', width: 4, bits: 32, tag: 0x0d},
    {name: 'Float64', width: 8, bits: 64, tag: 0x0e},
  ].freeze
  SHAPES = [
    {name: 'dim3', dimension: 3, stride: 3, explicit_stride: false},
    {name: 'dim9', dimension: 9, stride: 9, explicit_stride: false},
    {name: 'stride16-8', dimension: 16, stride: 8, explicit_stride: true},
  ].freeze

  Invocation = Struct.new(:record, :stdout, :stderr, :status, :timed_out,
                          keyword_init: true)

  def initialize(evidence_root, library_root)
    raise 'usage requires one existing EMPTY evidence directory' unless evidence_root
    raise 'unsafe evidence directory' if File.symlink?(evidence_root)
    @root = File.realpath(evidence_root)
    tmp_root = File.realpath('/private/tmp')
    unless @root.start_with?(tmp_root + File::SEPARATOR) && File.directory?(@root) && Dir.children(@root).empty?
      raise 'unsafe evidence directory: expected an existing empty /private/tmp child'
    end

    raise 'W179_LIBRARY_PART_ROOT is required' unless library_root && !library_root.empty?
    raise 'library part root must not be a symbolic link' if File.symlink?(library_root)
    @library_root = File.realpath(library_root)
    raise 'library part root must be a directory' unless File.directory?(@library_root)

    @profiles = build_profiles
    @library_parts = validate_library_parts
    @invocations = []
    @stock_results = []
    @library_results = []
    @runtime_failures = 0
  end

  def run
    before = Digest::SHA256.file(BINARY).hexdigest
    before_pin = nil
    before_pin_matches = false
    status = 'runtime_hash_mismatch'

    if before == SHA256
      before_pin = invoke('pin-before', create_store('pin-before-store'), VERSION_SQL)
      before_pin_matches = successful?(before_pin) && before_pin.stdout == VERSION
      if before_pin_matches
        status = 'native_profiles_incomplete'
        FileUtils.mkdir_p(File.join(@root, 'stock'), mode: 0o700)
        @profiles.each { |profile| @stock_results << probe_stock_profile(profile) }
        write_stock_manifest
        @profiles.each { |profile| @library_results << probe_library_profile(profile) }
        status = if @stock_results.all? { |result| result[:ok] } && @library_results.all? { |result| result[:ok] }
                   'all_profiles_match'
                 else
                   'profile_mismatch'
                 end
      else
        status = 'runtime_version_pin_mismatch'
      end
    end

    before_post_pin = Digest::SHA256.file(BINARY).hexdigest
    after_pin = nil
    after_pin_matches = false
    if before == SHA256 && before_post_pin == SHA256
      after_pin = invoke('pin-after', create_store('pin-after-store'), VERSION_SQL)
      after_pin_matches = successful?(after_pin) && after_pin.stdout == VERSION
      status = 'post_runtime_version_pin_mismatch' unless after_pin_matches
    else
      status = 'post_runtime_hash_mismatch'
    end
    after = Digest::SHA256.file(BINARY).hexdigest

    summary = {
      qualification: 'W179 bounded native QBit scalar/plane/part witnesses',
      claim_boundary: 'pinned stock executable only; not a build of the fresh ClickHouse source snapshot',
      runtime: {
        path: BINARY, expected_sha256: SHA256, sha256_before: before,
        sha256_before_post_pin: before_post_pin, sha256_after: after,
        expected_version_build_stdout: VERSION.dup.force_encoding(Encoding::UTF_8),
        before_pin_invocation: before_pin&.record&.fetch(:label),
        before_pin_matches: before_pin_matches,
        observed_before_pin_stdout: before_pin&.stdout&.dup&.force_encoding(Encoding::UTF_8),
        after_pin_invocation: after_pin&.record&.fetch(:label),
        after_pin_matches: after_pin_matches,
        observed_after_pin_stdout: after_pin&.stdout&.dup&.force_encoding(Encoding::UTF_8),
      },
      evidence_root: @root,
      library_part_root: @library_root,
      process_timeout_seconds: PROCESS_TIMEOUT_SECONDS,
      memory_limit_bytes_per_native_process: MEMORY_LIMIT_BYTES,
      profile_count: @profiles.length,
      stock_profiles_ok: @stock_results.count { |result| result[:ok] },
      library_profiles_ok: @library_results.count { |result| result[:ok] },
      runtime_or_process_failures: @runtime_failures,
      status: status,
      profiles: {stock_created: @stock_results, library_attached: @library_results},
      invocations: @invocations,
      exit_policy: 'all 24 profiles in both directions, exact nominal metadata and literal bytes, both runtime pins, and zero native process failures are required',
    }
    write_json('summary.json', summary)
    puts "W179 native qualification: stock=#{summary[:stock_profiles_ok]}/24, library=#{summary[:library_profiles_ok]}/24, process_failures=#{@runtime_failures}"
    puts "Evidence: #{@root}"

    before == SHA256 && before_post_pin == SHA256 && after == SHA256 &&
      before_pin_matches && after_pin_matches && @runtime_failures.zero? &&
      @stock_results.length == 24 && @stock_results.all? { |result| result[:ok] } &&
      @library_results.length == 24 && @library_results.all? { |result| result[:ok] }
  end

  private

  def build_profiles
    profiles = []
    CARRIERS.each_with_index do |carrier, carrier_index|
      SHAPES.each do |shape|
        [false, true].each do |nullable|
          qbit_name = if shape[:explicit_stride]
                        "QBit(#{carrier[:name]}, #{shape[:dimension]}, #{shape[:stride]})"
                      else
                        "QBit(#{carrier[:name]}, #{shape[:dimension]})"
                      end
          id = "#{carrier[:name].downcase}-#{shape[:name]}#{nullable ? '-nullable' : ''}"
          profile = {
            id: id, element: carrier[:name], width: carrier[:width], bits: carrier[:bits],
            tag: carrier[:tag], dimension: shape[:dimension], stride: shape[:stride],
            explicit_stride: shape[:explicit_stride], nullable: nullable,
            type: nullable ? "Nullable(#{qbit_name})" : qbit_name,
            raw_rows: [],
          }
          profile[:raw_rows] = (0...3).map { |row| literal_raw_row(profile, carrier_index, row) }
          profiles << profile
        end
      end
    end
    profiles.freeze
  end

  # These first-three-element bytes are hand-authored little-endian witnesses:
  # Int8 -1/0/-128; BFloat16/Float32/Float64 negative zero plus two qNaNs with
  # distinct payloads. No decimal float formatting or library codec is used.
  def literal_prefix(element, row)
    rows = case element
           when 'Int8'
             [[0xff, 0x00, 0x80], [0x00, 0x80, 0xff], [0x80, 0xff, 0x00]]
           when 'BFloat16'
             [[0x00, 0x80, 0xc1, 0x7f, 0xc2, 0x7f],
              [0xc1, 0x7f, 0xc2, 0x7f, 0x00, 0x80],
              [0xc2, 0x7f, 0x00, 0x80, 0xc1, 0x7f]]
           when 'Float32'
             [[0x00, 0x00, 0x00, 0x80, 0x01, 0x00, 0xc0, 0x7f, 0x02, 0x00, 0xc0, 0x7f],
              [0x01, 0x00, 0xc0, 0x7f, 0x02, 0x00, 0xc0, 0x7f, 0x00, 0x00, 0x00, 0x80],
              [0x02, 0x00, 0xc0, 0x7f, 0x00, 0x00, 0x00, 0x80, 0x01, 0x00, 0xc0, 0x7f]]
           when 'Float64'
             [[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80,
               0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0x7f,
               0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0x7f],
              [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0x7f,
               0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0x7f,
               0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80],
              [0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0x7f,
               0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80,
               0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0x7f]]
           else
             raise "unknown literal QBit element #{element}"
           end
    rows.fetch(row).pack('C*').b
  end

  def literal_raw_row(profile, carrier_index, row)
    prefix = literal_prefix(profile[:element], row)
    byte_count = profile[:dimension] * profile[:width]
    bytes = Array.new(byte_count) do |index|
      if index < prefix.bytesize
        prefix.getbyte(index)
      else
        (row * 67 + index * 31 + carrier_index * 19 + profile[:dimension] * 11 + profile[:stride] * 7) & 0xff
      end
    end
    bytes.pack('C*').b
  end

  def validate_library_parts
    raise 'library part root must be a symbol-free plain directory' if File.symlink?(@library_root)
    manifest_path = File.join(@library_root, 'manifest.json')
    raise 'library part manifest is missing' unless File.file?(manifest_path) && !File.symlink?(manifest_path)
    manifest = JSON.parse(File.read(manifest_path))
    raise 'library part manifest version mismatch' unless manifest.fetch('version') == 1
    records = manifest.fetch('profiles')
    expected_ids = @profiles.map { |profile| profile[:id] }
    actual_ids = records.map { |record| record.fetch('id') }
    raise 'library part profile roster mismatch' unless actual_ids.sort == expected_ids.sort && actual_ids.uniq == actual_ids
    expected_children = (expected_ids + ['manifest.json']).sort
    raise 'library part root contains unexpected entries' unless Dir.children(@library_root).sort == expected_children

    profile_by_id = @profiles.each_with_object({}) do |profile, index|
      index[profile[:id]] = profile
    end
    records.each_with_object({}) do |record, parts|
      profile = profile_by_id.fetch(record.fetch('id'))
      expected_part = "#{profile[:id]}/all_1_1_0"
      unless record.fetch('type') == profile[:type] && record.fetch('nullable') == profile[:nullable] &&
             record.fetch('rows') == 3 && record.fetch('part') == expected_part
        raise "library part manifest mismatch for #{profile[:id]}"
      end
      profile_root = File.join(@library_root, profile[:id])
      part_root = File.join(profile_root, 'all_1_1_0')
      raise "library profile directory missing for #{profile[:id]}" unless File.directory?(profile_root)
      files = plain_tree_files(part_root)
      raise "library part tree is empty for #{profile[:id]}" if files.empty?
      parts[profile[:id]] = {path: part_root, files: files, sha256: tree_sha256(part_root)}
    end
  end

  def plain_tree_files(root)
    raise "tree root is not a plain directory: #{root}" if File.symlink?(root) || !File.directory?(root)
    files = []
    pending = [root]
    until pending.empty?
      directory = pending.pop
      Dir.children(directory).sort.each do |name|
        path = File.join(directory, name)
        raise "symbolic link in tree: #{path}" if File.symlink?(path)
        if File.directory?(path)
          pending << path
        elsif File.file?(path)
          files << path
        else
          raise "unsupported filesystem entry in tree: #{path}"
        end
      end
    end
    files.sort
  end

  def tree_sha256(root)
    files = plain_tree_files(root)
    digest = Digest::SHA256.new
    files.each do |path|
      relative = path.delete_prefix(root + File::SEPARATOR)
      digest.update(relative.b)
      digest.update("\0".b)
      digest.update(File.binread(path))
    end
    digest.hexdigest
  end

  def create_store(name)
    path = File.join(@root, name)
    Dir.mkdir(path, 0o700)
    path
  end

  def invoke(label, store, sql, input = ''.b)
    raise 'unsafe evidence label' unless /\A[a-z0-9_-]+\z/.match?(label)
    args = [BINARY, 'local', '--path', store, '--max_threads=1', '--max_insert_threads=1',
            "--max_memory_usage=#{MEMORY_LIMIT_BYTES}", '--query', sql]
    stdout, stderr, status, timed_out, spawn_error, stdin_error, stdout_error, stderr_error = execute(args, input)
    classification = process_classification(status, timed_out, spawn_error, stdin_error,
                                            stdout_error, stderr_error, stderr)
    @runtime_failures += 1 unless classification == 'success'
    argv_bytes = JSON.generate(args)
    record = {
      label: label, argv: args, argv_file: "#{label}.argv.json",
      argv_sha256: Digest::SHA256.hexdigest(argv_bytes),
      sql: sql, sql_file: "#{label}.sql", sql_sha256: Digest::SHA256.hexdigest(sql.b),
      cwd: Dir.pwd, environment: {'TZ' => 'UTC'},
      exit: status&.exitstatus, signal: status&.termsig, timed_out: timed_out,
      timeout_seconds: PROCESS_TIMEOUT_SECONDS,
      spawn_error: spawn_error, stdin_write_error: stdin_error,
      stdout_read_error: stdout_error, stderr_read_error: stderr_error,
      process_classification: classification,
      input_bytes: input.bytesize, input_sha256: Digest::SHA256.hexdigest(input),
      stdout_bytes: stdout.bytesize, stdout_sha256: Digest::SHA256.hexdigest(stdout),
      stderr_bytes: stderr.bytesize, stderr_sha256: Digest::SHA256.hexdigest(stderr),
      input_file: "#{label}.input", stdout_file: "#{label}.stdout",
      stderr_file: "#{label}.stderr", record_file: "#{label}.json",
    }
    write_artifact(record[:argv_file], argv_bytes)
    write_artifact(record[:sql_file], sql.b)
    write_artifact(record[:input_file], input)
    write_artifact(record[:stdout_file], stdout)
    write_artifact(record[:stderr_file], stderr)
    write_json(record[:record_file], record)
    @invocations << record
    Invocation.new(record: record, stdout: stdout, stderr: stderr,
                   status: status, timed_out: timed_out)
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

  def profile_sql_create(profile)
    # Reuse W103's complete Wide/LZ4/plain-mark environment. Exact defaults
    # counting is disabled for this runner's three-row fixture; this does not
    # qualify per-column serializers or widen the admitted sparse profile.
    "CREATE TABLE t (pk UInt64, payload #{profile[:type]}) ENGINE=MergeTree ORDER BY pk SETTINGS #{W103_SETTINGS}"
  end

  def expected_substreams(profile)
    payload_streams = []
    payload_streams << 'payload.null' if profile[:nullable]
    (1..plane_count(profile)).each { |plane| payload_streams << "payload%2E#{plane}" }
    lines = [
      'columns substreams version: 1', '2 columns:',
      '1 substreams for column `pk`:', "\tpk",
      "#{payload_streams.length} substreams for column `payload`:",
    ]
    payload_streams.each { |stream| lines << "\t#{stream}" }
    lines.join("\n") + "\n"
  end

  def read_mark_records(path)
    bytes = File.binread(path)
    raise "#{File.basename(path)} has a partial adaptive mark record" unless (bytes.bytesize % 24).zero?
    Array.new(bytes.bytesize / 24) do |index|
      offset = index * 24
      [bytes.byteslice(offset, 8).unpack1('Q<'),
       bytes.byteslice(offset + 8, 8).unpack1('Q<'),
       bytes.byteslice(offset + 16, 8).unpack1('Q<')]
    end
  end

  def stock_part_layout_checks(profile, part_path)
    entries = Dir.children(part_path)
    mark_names = entries.select { |name| name.end_with?('.mrk2') }.sort
    bin_names = entries.select { |name| name.end_with?('.bin') }.sort
    expected_count = 1 + plane_count(profile) + (profile[:nullable] ? 1 : 0)
    mark_bases = mark_names.map { |name| name.delete_suffix('.mrk2') }.sort
    bin_bases = bin_names.map { |name| name.delete_suffix('.bin') }.sort
    compressed_marks = entries.select { |name| /\.cmrk\d*\z/.match?(name) }.sort

    codec_path = File.join(part_path, 'default_compression_codec.txt')
    codec = File.file?(codec_path) ? File.binread(codec_path) : nil
    result = {
      default_compression_codec: {
        equal: codec == 'CODEC(LZ4)', expected: 'CODEC(LZ4)', actual: codec,
      },
      primary_index_layout: {
        equal: File.file?(File.join(part_path, 'primary.idx')) &&
               !File.exist?(File.join(part_path, 'primary.cidx')),
        expected: 'plain primary.idx; no primary.cidx',
        primary_idx: File.file?(File.join(part_path, 'primary.idx')),
        primary_cidx: File.exist?(File.join(part_path, 'primary.cidx')),
      },
      columns_substreams: begin
        path = File.join(part_path, 'columns_substreams.txt')
        actual = File.file?(path) ? File.binread(path) : nil
        {equal: actual == expected_substreams(profile),
         expected: expected_substreams(profile), actual: actual}
      end,
      mark_inventory: {
        equal: mark_names.length == expected_count && bin_names.length == expected_count &&
               mark_bases == bin_bases && compressed_marks.empty?,
        expected_plain_stream_count: expected_count,
        actual_plain_mrk2_count: mark_names.length,
        actual_bin_count: bin_names.length,
        paired_hashed_basenames: mark_bases == bin_bases,
        compressed_mark_files: compressed_marks,
      },
    }

    expected_rows = [2, 1, 0]
    actual_grids = {}
    errors = []
    mark_names.each do |mark_name|
      mark_path = File.join(part_path, mark_name)
      bin_path = File.join(part_path, mark_name.delete_suffix('.mrk2') + '.bin')
      begin
        records = read_mark_records(mark_path)
        grid = records.map { |record| record[2] }
        actual_grids[mark_name] = records
        errors << "#{mark_name}: row grid #{grid.inspect}, expected #{expected_rows.inspect}" unless grid == expected_rows
        unless File.file?(bin_path)
          errors << "#{mark_name}: paired .bin stream is missing"
          next
        end
        data_bytes = File.size(bin_path)
        records.each do |compressed_offset, _decompressed_offset, _rows|
          errors << "#{mark_name}: compressed offset exceeds paired .bin extent" if compressed_offset > data_bytes
        end
        records.each_cons(2) do |previous, current|
          ordered = current[0] > previous[0] ||
            (current[0] == previous[0] && current[1] >= previous[1])
          errors << "#{mark_name}: adaptive mark coordinates are not ordered" unless ordered
        end
      rescue StandardError => error
        errors << "#{mark_name}: #{error.class}: #{error.message}"
      end
    end
    result[:adaptive_mark_grid] = {
      equal: actual_grids.length == expected_count && errors.empty?,
      expected_rows_per_record: expected_rows,
      actual_records: actual_grids,
      errors: errors,
    }
    result
  end

  def insert_sql
    'INSERT INTO t FORMAT RowBinary'
  end

  def input_rowbinary(profile)
    output = ''.b
    profile[:raw_rows].each_with_index do |raw, index|
      output << [[11, 22, 33].fetch(index)].pack('Q<').b
      if profile[:nullable]
        if index == 1
          output << "\x01".b
          next
        end
        output << "\x00".b
      end
      output << varuint(profile[:dimension]) << raw
    end
    output
  end

  def varuint(value)
    remaining = value
    output = ''.b
    loop do
      byte = remaining & 0x7f
      remaining >>= 7
      output << [byte | (remaining.zero? ? 0 : 0x80)].pack('C')
      break if remaining.zero?
    end
    output
  end

  def qbit_descriptor(profile)
    output = [profile[:explicit_stride] ? 0x37 : 0x36, profile[:tag]].pack('C*').b
    output << varuint(profile[:dimension])
    output << varuint(profile[:stride]) if profile[:explicit_stride]
    output
  end

  def expected_payload_rowbinary(profile)
    output = ''.b
    profile[:raw_rows].each_with_index do |raw, index|
      if profile[:nullable]
        if index == 1
          output << "\x01".b
          next
        end
        output << "\x00".b
      end
      output << varuint(profile[:dimension]) << raw
    end
    output
  end

  def expected_full_rowbinary(profile)
    input_rowbinary(profile)
  end

  def expected_dynamic_rowbinary(profile)
    output = ''.b
    profile[:raw_rows].each_with_index do |raw, index|
      next if profile[:nullable] && index == 1
      output << qbit_descriptor(profile) << varuint(profile[:dimension]) << raw
    end
    output
  end

  def expected_plane_rowbinary(profile)
    output = ''.b
    row_indexes = profile[:nullable] ? [0, 2] : [0, 1, 2]
    # Native RowBinary is row-major across selected FixedString subcolumns.
    row_indexes.each do |row|
      plane_count(profile).times do |plane|
        output << independent_plane_bytes(profile, profile[:raw_rows][row], plane)
      end
    end
    output
  end

  def plane_count(profile)
    profile[:bits] * (profile[:dimension] / profile[:stride])
  end

  # Independent port of the published transpose law used by W103: group-major
  # planes, reversed byte order within each FixedString lane, LSB-first bits.
  def independent_plane_bytes(profile, raw, plane)
    width = (profile[:stride] + 7) / 8
    group = plane / profile[:bits]
    bit_in_group = plane % profile[:bits]
    source_bit = profile[:bits] - 1 - bit_in_group
    output = Array.new(width, 0)
    total_bits = width * 8
    profile[:dimension].times do |global_index|
      row_group = global_index / profile[:stride]
      next unless row_group == group
      local_index = global_index - row_group * profile[:stride]
      bit_index = total_bits - 1 - (local_index ^ 7)
      source_byte = global_index * profile[:width] + source_bit / 8
      source_mask = 1 << (source_bit % 8)
      next if (raw.getbyte(source_byte) & source_mask).zero?
      output[bit_index / 8] |= 1 << (bit_index % 8)
    end
    output.pack('C*').b
  end

  def plane_select_sql(profile)
    expression = profile[:nullable] ? 'assumeNotNull(payload)' : 'payload'
    fields = (1..plane_count(profile)).map { |plane| "#{expression}.#{plane}" }.join(', ')
    where = profile[:nullable] ? ' WHERE payload IS NOT NULL' : ''
    "SELECT #{fields} FROM t#{where} ORDER BY pk FORMAT RowBinary"
  end

  def dynamic_select_sql(profile)
    expression = profile[:nullable] ? 'assumeNotNull(payload)' : 'payload'
    where = profile[:nullable] ? ' WHERE payload IS NOT NULL' : ''
    "SELECT CAST(#{expression} AS Dynamic) FROM t#{where} ORDER BY pk FORMAT RowBinary"
  end

  def compare_bytes(expected, actual)
    {
      equal: expected == actual,
      expected_bytes: expected.bytesize,
      actual_bytes: actual.bytesize,
      expected_hex: expected.unpack1('H*'),
      actual_hex: actual.unpack1('H*'),
      expected_sha256: Digest::SHA256.hexdigest(expected),
      actual_sha256: Digest::SHA256.hexdigest(actual),
    }
  end

  def exact_single_text(expected, actual)
    observed = actual.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
    {equal: observed == [expected], expected: [expected], actual: observed}
  end

  def add_process(result, stage, invocation)
    result[:processes] << {stage: stage, label: invocation.record[:label],
                           classification: invocation.record[:process_classification],
                           exit: invocation.record[:exit], signal: invocation.record[:signal],
                           timed_out: invocation.record[:timed_out]}
  end

  def probe_stock_profile(profile)
    result = {id: profile[:id], type: profile[:type], nullable: profile[:nullable], rows: 3,
              checks: {}, processes: [], part: nil}
    result[:input_hex] = input_rowbinary(profile).unpack1('H*')
    store = create_store("stock-store-#{profile[:id]}")
    create = invoke("stock-#{profile[:id]}-create", store, profile_sql_create(profile))
    add_process(result, 'create', create)
    return persist_profile('stock', result) unless successful?(create)

    input = input_rowbinary(profile)
    insert = invoke("stock-#{profile[:id]}-insert", store, insert_sql, input)
    add_process(result, 'insert', insert)
    return persist_profile('stock', result) unless successful?(insert)

    payload = invoke("stock-#{profile[:id]}-payload-rowbinary", store,
                     'SELECT payload FROM t ORDER BY pk FORMAT RowBinary')
    add_process(result, 'payload_rowbinary', payload)
    result[:checks][:payload_rowbinary] = compare_bytes(expected_payload_rowbinary(profile), payload.stdout)

    full = invoke("stock-#{profile[:id]}-full-rowbinary", store,
                  'SELECT pk, payload FROM t ORDER BY pk FORMAT RowBinary')
    add_process(result, 'full_rowbinary', full)
    result[:checks][:full_rowbinary] = compare_bytes(expected_full_rowbinary(profile), full.stdout)

    dynamic = invoke("stock-#{profile[:id]}-dynamic-rowbinary", store, dynamic_select_sql(profile))
    add_process(result, 'dynamic_rowbinary', dynamic)
    result[:checks][:dynamic_rowbinary] = compare_bytes(expected_dynamic_rowbinary(profile), dynamic.stdout)

    planes = invoke("stock-#{profile[:id]}-planes-rowbinary", store, plane_select_sql(profile))
    add_process(result, 'planes_rowbinary', planes)
    expected_planes = expected_plane_rowbinary(profile)
    result[:checks][:planes_rowbinary] = compare_bytes(expected_planes, planes.stdout)

    type_name = invoke("stock-#{profile[:id]}-type-name", store,
                       'SELECT toTypeName(payload) FROM t LIMIT 1 FORMAT TSVRaw')
    add_process(result, 'type_name', type_name)
    result[:checks][:type_name] = exact_single_text(profile[:type], type_name.stdout)

    column_type = invoke("stock-#{profile[:id]}-column-type", store,
                         "SELECT type FROM system.columns WHERE database='default' AND table='t' AND name='payload' FORMAT TSVRaw")
    add_process(result, 'system_columns_type', column_type)
    result[:checks][:system_columns_type] = exact_single_text(profile[:type], column_type.stdout)

    part_info = invoke("stock-#{profile[:id]}-part-info", store,
                       "SELECT name, part_type, rows, path FROM system.parts WHERE database='default' AND table='t' AND active FORMAT TSVRaw")
    add_process(result, 'part_info', part_info)
    result[:checks][:part_info], part_path = parse_part_info(part_info, store)

    profile_root = File.join(@root, 'stock', profile[:id])
    Dir.mkdir(profile_root, 0o700)
    if successful?(planes)
      write_artifact(File.join('stock', profile[:id], 'planes.rowbinary'), planes.stdout)
      result[:planes_artifact] = "#{profile[:id]}/planes.rowbinary"
    end
    if part_path
      serialization = JSON.parse(File.read(File.join(part_path, 'serialization.json')))
      expected_serialization = {
        'version' => 1, 'columns' => [], 'types_serialization_versions' => {'string' => 1},
        'propagate_types_serialization_versions_to_nested_types' => true,
      }
      result[:checks][:serialization_profile] = {
        equal: serialization == expected_serialization,
        expected: expected_serialization, actual: serialization,
      }
      result[:checks].merge!(stock_part_layout_checks(profile, part_path))
      destination = File.join(profile_root, 'all_1_1_0')
      FileUtils.cp_r(part_path, destination)
      copied_sha = tree_sha256(destination)
      result[:part] = {relative_path: "#{profile[:id]}/all_1_1_0", source_path: part_path,
                       sha256: copied_sha, bytes_sha256_match: copied_sha == tree_sha256(part_path)}
    end
    result[:ok] = result[:processes].all? { |process| process[:classification] == 'success' } &&
      result[:checks].values.all? { |check| check[:equal] } && result[:part] &&
      result[:part][:bytes_sha256_match]
    persist_profile('stock', result)
  rescue StandardError => error
    result[:error] = "#{error.class}: #{error.message}"
    result[:ok] = false
    persist_profile('stock', result)
  end

  def parse_part_info(invocation, store)
    return [{equal: false, error: 'part metadata process failed'}, nil] unless successful?(invocation)
    lines = invocation.stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
    return [{equal: false, error: 'expected exactly one active part', actual: lines}, nil] unless lines.length == 1
    fields = lines.first.split("\t", -1)
    return [{equal: false, error: 'malformed system.parts row', actual: fields}, nil] unless fields.length == 4
    name, part_type, row_count, reported_path = fields
    metadata_equal = name == 'all_1_1_0' && part_type == 'Wide' && row_count == '3'
    path = File.expand_path(reported_path, store)
    real_store = File.realpath(store)
    real_path = File.realpath(path)
    unless real_path.start_with?(real_store + File::SEPARATOR) && File.directory?(real_path)
      raise 'native part path escaped the isolated store'
    end
    plain_tree_files(real_path)
    [{equal: metadata_equal, expected: {name: 'all_1_1_0', part_type: 'Wide', rows: '3'},
      actual: {name: name, part_type: part_type, rows: row_count, path: reported_path}}, real_path]
  rescue StandardError => error
    [{equal: false, error: "#{error.class}: #{error.message}"}, nil]
  end

  def probe_library_profile(profile)
    result = {id: profile[:id], type: profile[:type], nullable: profile[:nullable], rows: 3,
              source_part_sha256: @library_parts.fetch(profile[:id])[:sha256], checks: {}, processes: []}
    store = create_store("library-store-#{profile[:id]}")
    create = invoke("library-#{profile[:id]}-create", store, profile_sql_create(profile))
    add_process(result, 'create', create)
    return persist_profile('library', result) unless successful?(create)

    data_path = invoke("library-#{profile[:id]}-table-path", store,
                       "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='t' FORMAT TSVRaw")
    add_process(result, 'table_path', data_path)
    unless successful?(data_path)
      result[:checks][:table_path] = {equal: false, error: 'table data path query failed'}
      return persist_profile('library', result)
    end
    table_path_text = data_path.stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp).fetch(0)
    table_path = File.realpath(File.expand_path(table_path_text, store))
    real_store = File.realpath(store)
    raise 'table data path escaped the isolated store' unless table_path.start_with?(real_store + File::SEPARATOR)
    detached = File.join(table_path, 'detached')
    raise 'detached directory is unsafe' if File.symlink?(detached)
    FileUtils.mkdir_p(detached, mode: 0o700)
    target_part = File.join(detached, 'all_1_1_0')
    source_part = @library_parts.fetch(profile[:id])[:path]
    FileUtils.cp_r(source_part, target_part)
    result[:copied_library_part_sha256] = tree_sha256(target_part)
    result[:checks][:library_part_copy] = {
      equal: result[:copied_library_part_sha256] == @library_parts.fetch(profile[:id])[:sha256],
      expected_sha256: @library_parts.fetch(profile[:id])[:sha256],
      actual_sha256: result[:copied_library_part_sha256],
    }

    attach = invoke("library-#{profile[:id]}-attach", store,
                    "ALTER TABLE default.t ATTACH PART 'all_1_1_0'")
    add_process(result, 'attach_part', attach)
    return persist_profile('library', result) unless successful?(attach)

    type_name = invoke("library-#{profile[:id]}-type-name", store,
                       'SELECT toTypeName(payload) FROM t LIMIT 1 FORMAT TSVRaw')
    add_process(result, 'type_name', type_name)
    result[:checks][:type_name] = exact_single_text(profile[:type], type_name.stdout)

    column_type = invoke("library-#{profile[:id]}-column-type", store,
                         "SELECT type FROM system.columns WHERE database='default' AND table='t' AND name='payload' FORMAT TSVRaw")
    add_process(result, 'system_columns_type', column_type)
    result[:checks][:system_columns_type] = exact_single_text(profile[:type], column_type.stdout)

    full = invoke("library-#{profile[:id]}-full-rowbinary", store,
                  'SELECT pk, payload FROM t ORDER BY pk FORMAT RowBinary')
    add_process(result, 'full_rowbinary', full)
    result[:checks][:full_rowbinary] = compare_bytes(expected_full_rowbinary(profile), full.stdout)

    planes = invoke("library-#{profile[:id]}-planes-rowbinary", store, plane_select_sql(profile))
    add_process(result, 'planes_rowbinary', planes)
    result[:checks][:planes_rowbinary] = compare_bytes(expected_plane_rowbinary(profile), planes.stdout)

    part_info = invoke("library-#{profile[:id]}-part-info", store,
                       "SELECT name, part_type, rows FROM system.parts WHERE database='default' AND table='t' AND active FORMAT TSVRaw")
    add_process(result, 'part_info', part_info)
    result[:checks][:part_info] = exact_single_text("all_1_1_0\tWide\t3", part_info.stdout)

    result[:ok] = result[:processes].all? { |process| process[:classification] == 'success' } &&
      result[:checks].values.all? { |check| check[:equal] }
    persist_profile('library', result)
  rescue StandardError => error
    result[:error] = "#{error.class}: #{error.message}"
    result[:ok] = false
    persist_profile('library', result)
  end

  def persist_profile(direction, result)
    result[:ok] = false unless result.key?(:ok)
    write_json("#{direction}-profile-#{result[:id]}.json", result)
    result
  end

  def write_stock_manifest
    profiles = @stock_results.map do |result|
      next unless result[:part]
      {
        id: result[:id], type: result[:type], nullable: result[:nullable], rows: result[:rows],
        part: result[:part][:relative_path], native_planes: result[:planes_artifact],
      }
    end.compact
    manifest = {
      version: 1,
      runtime: {path: BINARY, sha256: SHA256,
                version_build: VERSION.dup.force_encoding(Encoding::UTF_8)},
      profiles: profiles,
    }
    write_json('stock/manifest.json', manifest)
  end

  def write_artifact(name, bytes)
    path = File.join(@root, name)
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700) unless File.dirname(path) == @root
    File.open(path, 'wx', 0o600) { |file| file.write(bytes) }
  end

  def write_json(name, value)
    write_artifact(name, JSON.pretty_generate(value))
  end
end

abort 'usage: W179_LIBRARY_PART_ROOT=EXISTING_LIBRARY_ROOT ruby check_qbit_binary_kernel_w179.rb EMPTY_TMP_EVIDENCE_DIR' unless ARGV.length == 1
library_root = ENV['W179_LIBRARY_PART_ROOT']
exit(QBitBinaryKernelW179Probe.new(ARGV.fetch(0), library_root).run ? 0 : 1)
