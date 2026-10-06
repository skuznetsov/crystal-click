#!/usr/bin/env ruby
# Root-run paired native oracle for seven fixed JSON v0 descriptor and
# structured RowBinary witnesses. This script never builds ClickHouse or Crystal.
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'

class JsonBinaryKernelW180Probe
  DEFAULT_BINARY = '/private/tmp/crystal-click-w144-runtime-recovery.Pm8VNb/clickhouse-stripped'.freeze
  BINARY_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  VERSION = "26.10.1.1201\td9bcb5ab007f0f6299f7f973f2642245bab3d028\n".b.freeze
  VERSION_SQL = "SELECT version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSV".freeze
  PROCESS_TIMEOUT_SECONDS = 10
  TERMINATION_GRACE_SECONDS = 2
  MEMORY_LIMIT_BYTES = 536_870_912
  STRUCTURED_JSON_SETTINGS = {
    'input_format_binary_read_json_as_string' => 0,
    'output_format_binary_write_json_as_string' => 0,
  }.freeze
  SYSTEM_FAILURE = /no space left|disk quota|read.only file system|permission denied|cannot allocate memory|out of memory|memory limit|i\/o error|bad file descriptor|too many open files|resource temporarily unavailable|cannot open file|cannot create file/i
  CLICKHOUSE_EXCEPTION = /\bCode:\s*\d+\.|\bDB::Exception:/
  PROFILE_IDS = %w[
    bare_json caps_0_0 caps_0_0_runtime_string caps_1_1 caps_10000_254 typed_uint8_n
    typed_nullable_uint8_array_item
  ].freeze

  PROFILES = [
    {
      id: 'bare_json', type: 'JSON', sql_type: 'JSON', sql_value: '{}',
      descriptor: [0x30, 0x00, 0x80, 0x08, 0x20, 0x00, 0x00, 0x00].pack('C*').b,
      row: [0x00].pack('C*').b, json: '{}',
    },
    {
      id: 'caps_0_0', type: 'JSON(max_dynamic_types=0, max_dynamic_paths=0)',
      sql_type: 'JSON(max_dynamic_types=0, max_dynamic_paths=0)', sql_value: '{}',
      descriptor: [0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00].pack('C*').b,
      row: [0x00].pack('C*').b, json: '{}',
    },
    {
      id: 'caps_0_0_runtime_string', type: 'JSON(max_dynamic_types=0, max_dynamic_paths=0)',
      sql_type: 'JSON(max_dynamic_types=0, max_dynamic_paths=0)', sql_value: '{"s":"x"}',
      descriptor: [0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00].pack('C*').b,
      row: [0x01, 0x01, 0x73, 0x15, 0x01, 0x78].pack('C*').b, json: '{"s":"x"}',
    },
    {
      id: 'caps_1_1', type: 'JSON(max_dynamic_types=1, max_dynamic_paths=1)',
      sql_type: 'JSON(max_dynamic_types=1, max_dynamic_paths=1)', sql_value: '{}',
      descriptor: [0x30, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00].pack('C*').b,
      row: [0x00].pack('C*').b, json: '{}',
    },
    {
      id: 'caps_10000_254', type: 'JSON(max_dynamic_types=254, max_dynamic_paths=10000)',
      sql_type: 'JSON(max_dynamic_types=254, max_dynamic_paths=10000)', sql_value: '{}',
      descriptor: [0x30, 0x00, 0x90, 0x4e, 0xfe, 0x00, 0x00, 0x00].pack('C*').b,
      row: [0x00].pack('C*').b, json: '{}',
    },
    {
      id: 'typed_uint8_n',
      type: 'JSON(max_dynamic_types=1, max_dynamic_paths=1, n UInt8)',
      sql_type: 'JSON(max_dynamic_types=1, max_dynamic_paths=1, n UInt8)',
      sql_value: '{"n":42}',
      descriptor: [0x30, 0x00, 0x01, 0x01, 0x01, 0x01, 0x6e, 0x01, 0x00, 0x00].pack('C*').b,
      row: [0x01, 0x01, 0x6e, 0x2a].pack('C*').b, json: '{"n":42}',
    },
    {
      id: 'typed_nullable_uint8_array_item',
      type: 'JSON(max_dynamic_types=1, max_dynamic_paths=1, item Array(Nullable(UInt8)))',
      sql_type: 'JSON(max_dynamic_types=1, max_dynamic_paths=1, item Array(Nullable(UInt8)))',
      sql_value: '{"item":[null,0,255]}',
      descriptor: [
        0x30, 0x00, 0x01, 0x01, 0x01, 0x04, 0x69, 0x74, 0x65, 0x6d,
        0x1e, 0x23, 0x01, 0x00, 0x00,
      ].pack('C*').b,
      row: [0x01, 0x04, 0x69, 0x74, 0x65, 0x6d, 0x03, 0x01, 0x00, 0x00, 0x00, 0xff].pack('C*').b,
      json: '{"item":[null,0,255]}',
    },
  ].map(&:freeze).freeze

  Invocation = Struct.new(:record, :stdout, :stderr, :status, :timed_out,
                          keyword_init: true)

  class BinaryReader
    attr_reader :offset

    def initialize(bytes)
      @bytes = bytes.b
      @offset = 0
    end

    def read_byte
      raise 'truncated RowBinary header' if @offset >= @bytes.bytesize
      byte = @bytes.getbyte(@offset)
      @offset += 1
      byte
    end

    def read_bytes(length)
      raise 'negative binary length' if length.negative?
      finish = @offset + length
      raise 'truncated RowBinary header' if finish > @bytes.bytesize
      value = @bytes.byteslice(@offset, length).to_s.b
      @offset = finish
      value
    end

    def read_varuint
      value = 0
      shift = 0
      10.times do
        byte = read_byte
        payload = byte & 0x7f
        raise 'VarUInt overflow' if shift == 63 && payload > 1
        value |= payload << shift
        return value if (byte & 0x80).zero?
        shift += 7
      end
      raise 'unterminated VarUInt'
    end

    def read_string
      length = read_varuint
      raise 'unreasonable header string size' if length > 4096
      read_bytes(length)
    end
  end

  def initialize(binary, evidence_root, library_root)
    @binary = binary
    @root = validate_evidence_root(evidence_root)
    @library_root = validate_library_root(library_root)
    @library_profiles = validate_library_manifest
    @invocations = []
    @process_failures = 0
    @profile_results = []
    @status = 'not_started'
  end

  def run
    FileUtils.mkdir_p(File.join(@root, 'stock_to_library'), mode: 0o700)
    FileUtils.mkdir_p(File.join(@root, 'stock_observations'), mode: 0o700)
    FileUtils.mkdir_p(File.join(@root, 'library_inputs'), mode: 0o700)
    FileUtils.mkdir_p(File.join(@root, 'stores'), mode: 0o700)
    comparator_self_test!

    before_sha = file_sha256(@binary)
    before_pin = nil
    before_pin_ok = false
    results_ran = false
    version_fields = VERSION.chomp.split("\t", 2)
    version_fields_valid = version_fields.length == 2 &&
                           version_fields.all? { |field| !field.empty? } &&
                           !version_fields.last.include?("\t")
    if before_sha == BINARY_SHA256
      before_pin = invoke('pin-before', VERSION_SQL)
      before_pin_ok = version_fields_valid && successful?(before_pin) && before_pin.stdout == VERSION
      if before_pin_ok
        @runtime_identity = {
          path: @binary, sha256: before_sha,
          version: version_fields[0],
          build_hash: version_fields[1],
        }
        @status = 'profiles_incomplete'
        run_profiles
        results_ran = true
      else
        @status = 'runtime_version_pin_mismatch'
      end
    else
      @status = 'runtime_hash_mismatch'
    end

    before_after_sha = file_sha256(@binary)
    after_pin = nil
    after_pin_ok = false
    if before_sha == BINARY_SHA256 && before_after_sha == BINARY_SHA256
      after_pin = invoke('pin-after', VERSION_SQL)
      after_pin_ok = successful?(after_pin) && after_pin.stdout == VERSION
      @status = 'post_runtime_version_pin_mismatch' unless after_pin_ok
    else
      @status = 'post_runtime_hash_mismatch'
    end
    after_sha = file_sha256(@binary)

    profiles_match = results_ran && @profile_results.length == PROFILES.length &&
                     @profile_results.all? { |result| result[:ok] }
    if @status == 'profiles_incomplete'
      @status = profiles_match ? 'all_profiles_match' : 'profile_mismatch'
    end
    if before_sha != BINARY_SHA256 || before_after_sha != BINARY_SHA256 || after_sha != BINARY_SHA256
      @status = 'runtime_hash_mismatch'
    elsif !before_pin_ok || !after_pin_ok
      @status = 'runtime_version_pin_mismatch'
    end

    summary = {
      qualification: 'pinned stock ClickHouse oracle for seven fixed JSON v0 descriptors and structured RowBinary witnesses',
      claim_boundary: 'pinned runtime only; no claim that it was built from a fresh ClickHouse source snapshot',
      runtime: {
        path: @binary, expected_sha256: BINARY_SHA256,
        sha256_before: before_sha, sha256_before_after_profiles: before_after_sha,
        sha256_after: after_sha, expected_version_build_stdout: VERSION.dup.force_encoding(Encoding::UTF_8),
        before_pin_matches: before_pin_ok, before_pin_stdout: utf8(before_pin&.stdout),
        after_pin_matches: after_pin_ok, after_pin_stdout: utf8(after_pin&.stdout),
      },
      evidence_root: @root, library_root: @library_root,
      process_timeout_seconds: PROCESS_TIMEOUT_SECONDS,
      memory_limit_bytes_per_native_process: MEMORY_LIMIT_BYTES,
      max_threads: 1,
      structured_json_settings: STRUCTURED_JSON_SETTINGS,
      stock_fixture_interface: 'stock_to_library/<profile-id>/{descriptor.bin,row.bin,metadata.json}',
      finite_profile_boundary: 'Four profiles are empty cap-only rows; one is a single runtime String path at zero caps; two are typed-path values (UInt8 and Array(Nullable(UInt8))). This finite roster does not qualify a broader dynamic-path/type grammar.',
      profile_count: PROFILES.length,
      profiles_ok: @profile_results.count { |result| result[:ok] },
      native_process_failures: @process_failures,
      status: @status,
      error_interpretation_policy: 'any error, ClickHouse exception, timeout, signal, or system failure is a runner failure and is not semantic rejection evidence',
      profiles: @profile_results,
      invocations: @invocations,
    }
    write_json('summary.json', summary)
    puts "W180 JSON binary oracle: profiles=#{summary[:profiles_ok]}/#{PROFILES.length}, process_failures=#{@process_failures}, status=#{@status}"
    puts "Evidence: #{@root}"
    @status == 'all_profiles_match' && @process_failures.zero?
  end

  private

  def validate_evidence_root(path)
    fail!('evidence root is required') unless path && !path.empty?
    fail!('evidence root must not be a symbolic link') if File.symlink?(path)
    root = File.realpath(path)
    tmp_root = File.realpath('/private/tmp')
    unless File.directory?(root) && File.expand_path(path) == root &&
           File.dirname(root) == tmp_root && Dir.children(root).empty?
      fail!('evidence root must be an existing empty direct child of /private/tmp')
    end
    root
  end

  def validate_library_root(path)
    fail!('library root is required') unless path && !path.empty?
    fail!('library root must not be a symbolic link') if File.symlink?(path)
    root = File.realpath(path)
    fail!('library root must be a directory') unless File.directory?(root)
    root
  end

  def validate_library_manifest
    manifest_path = File.join(@library_root, 'manifest.json')
    fail!('library manifest is missing or not a plain file') unless File.file?(manifest_path) && !File.symlink?(manifest_path)
    manifest = JSON.parse(File.binread(manifest_path))
    fail!('library manifest keys differ') unless manifest.is_a?(Hash) && manifest.keys.sort == %w[profiles version]
    fail!('library manifest version mismatch') unless manifest.fetch('version') == 1
    records = manifest.fetch('profiles')
    fail!('library manifest profile roster is malformed') unless records.is_a?(Array)
    fail!('library manifest profile count differs') unless records.length == PROFILES.length

    expected_children = (PROFILE_IDS + ['manifest.json']).sort
    fail!('library root contains unexpected entries') unless Dir.children(@library_root).sort == expected_children
    records_by_id = {}
    records.each do |record|
      fail!('library manifest profile is malformed') unless record.is_a?(Hash) &&
        record.keys.sort == %w[descriptor id row type]
      id = record.fetch('id')
      fail!("unknown or duplicate library profile #{id.inspect}") unless PROFILE_IDS.include?(id) && !records_by_id.key?(id)
      profile = profile(id)
      expected_record = {
        'id' => id, 'type' => profile[:type],
        'descriptor' => "#{id}/descriptor.bin", 'row' => "#{id}/row.bin",
      }
      fail!("library manifest differs for #{id}") unless record == expected_record
      profile_root = File.join(@library_root, id)
      fail!("library profile directory is not plain for #{id}") if File.symlink?(profile_root) || !File.directory?(profile_root)
      fail!("unexpected library profile files for #{id}") unless Dir.children(profile_root).sort == %w[descriptor.bin row.bin]
      descriptor_path = File.join(profile_root, 'descriptor.bin')
      row_path = File.join(profile_root, 'row.bin')
      [descriptor_path, row_path].each do |file|
        fail!("library fixture is not a plain file for #{id}") unless File.file?(file) && !File.symlink?(file)
      end
      descriptor = File.binread(descriptor_path)
      row = File.binread(row_path)
      records_by_id[id] = {
        type: record.fetch('type'), descriptor: descriptor, row: row,
        descriptor_sha256: Digest::SHA256.hexdigest(descriptor),
        row_sha256: Digest::SHA256.hexdigest(row),
      }
    end
    fail!('library manifest does not cover the literal profile roster') unless records_by_id.keys.sort == PROFILE_IDS.sort
    records_by_id
  rescue JSON::ParserError, KeyError, TypeError => error
    fail!("invalid library manifest: #{error.class}: #{error.message}")
  end

  def profile(id)
    PROFILES.find { |candidate| candidate[:id] == id } || fail!("unknown profile #{id}")
  end

  def run_profiles
    PROFILES.each do |item|
      result = {
        id: item[:id], expected_type: item[:type],
        expected_descriptor_hex: item[:descriptor].unpack1('H*'),
        expected_row_hex: item[:row].unpack1('H*'),
        library_descriptor_sha256: @library_profiles.fetch(item[:id])[:descriptor_sha256],
        library_row_sha256: @library_profiles.fetch(item[:id])[:row_sha256],
        stock_wire_exact: false, stock_readback_exact: false, library_wire_exact: false,
        library_readback_exact: false, ok: false,
      }
      begin
        stock = capture_stock(item)
        result[:stock_wire_exact] = stock[:wire_exact]
        result[:stock_readback] = stock[:readback_record]
        result[:stock_readback_exact] = stock[:readback_exact]

        library = read_library_fixture(item)
        result[:library_wire_exact] = library[:wire_exact]
        result[:library_readback] = library[:readback_record]
        result[:library_readback_exact] = library[:readback_exact]
        result[:ok] = [result[:stock_wire_exact], result[:stock_readback_exact],
                       result[:library_wire_exact], result[:library_readback_exact]].all?
      rescue StandardError => error
        result[:runner_error] = "#{error.class}: #{error.message}"
      end
      @profile_results << result
    end
  end

  def capture_stock(item)
    fixture_directory = File.join(@root, 'stock_to_library', item[:id])
    observation_directory = File.join(@root, 'stock_observations', item[:id])
    Dir.mkdir(fixture_directory, 0o700)
    Dir.mkdir(observation_directory, 0o700)
    expression = "CAST(#{sql_string(item[:sql_value])}, #{sql_string(item[:sql_type])}) AS payload"
    sql = "SELECT #{expression} SETTINGS output_format_binary_encode_types_in_binary_format=1, " \
          "output_format_binary_write_json_as_string=0, input_format_binary_read_json_as_string=0 " \
          'FORMAT RowBinaryWithNamesAndTypes'
    invocation = invoke("stock-#{item[:id]}", sql)
    raw_path = File.join(observation_directory, 'rowbinary_with_names_and_types.bin')
    write_path(raw_path, invocation.stdout)
    parsed = nil
    parse_error = nil
    begin
      parsed = parse_stock_rowbinary(invocation.stdout)
    rescue StandardError => error
      parse_error = "#{error.class}: #{error.message}"
    end
    expected_header = rowbinary_header(item[:descriptor])
    wire_exact = successful?(invocation) && parsed &&
                 parsed[:names] == ['payload'.b] &&
                 bytes_equal?(parsed[:header], expected_header) &&
                 bytes_equal?(parsed[:descriptor], item[:descriptor]) &&
                 bytes_equal?(parsed[:row], item[:row])
    if parsed
      write_path(File.join(observation_directory, 'header.bin'), parsed[:header])
      write_path(File.join(observation_directory, 'descriptor.bin'), parsed[:descriptor])
      write_path(File.join(observation_directory, 'row.bin'), parsed[:row])
      write_path(File.join(fixture_directory, 'descriptor.bin'), parsed[:descriptor])
      write_path(File.join(fixture_directory, 'row.bin'), parsed[:row])
      metadata = {
        version: 1, profile_id: item[:id], type: item[:type],
        source: 'pinned stock ClickHouse RowBinaryWithNamesAndTypes output',
        runtime: @runtime_identity,
        structured_json_settings: STRUCTURED_JSON_SETTINGS,
        header_format: 'RowBinaryWithNamesAndTypes', row_format: 'structured RowBinary',
        header_hex: parsed[:header].unpack1('H*'),
        header_sha256: Digest::SHA256.hexdigest(parsed[:header]),
        descriptor_bytes: parsed[:descriptor].bytesize,
        descriptor_sha256: Digest::SHA256.hexdigest(parsed[:descriptor]),
        row_bytes: parsed[:row].bytesize,
        row_sha256: Digest::SHA256.hexdigest(parsed[:row]),
        rowbinary_sha256: Digest::SHA256.hexdigest(invocation.stdout),
        stock_wire_exact: !!wire_exact,
      }
      write_path(File.join(fixture_directory, 'metadata.json'), JSON.pretty_generate(metadata) + "\n")
    end

    readback = read_wire("stock-readback-#{item[:id]}", raw_path, item)
    {
      wire_exact: !!wire_exact,
      parse_error: parse_error,
      readback_exact: readback[:exact],
      readback_record: readback[:record],
    }
  end

  def read_library_fixture(item)
    library = @library_profiles.fetch(item[:id])
    wire_exact = bytes_equal?(library[:descriptor], item[:descriptor]) &&
                 bytes_equal?(library[:row], item[:row])
    directory = File.join(@root, 'library_inputs')
    raw_path = File.join(directory, "#{item[:id]}.rowbinary_with_names_and_types.bin")
    write_path(raw_path, rowbinary_header(library[:descriptor]) + library[:row])
    readback = read_wire("library-readback-#{item[:id]}", raw_path, item)
    {
      wire_exact: wire_exact,
      readback_exact: readback[:exact],
      readback_record: readback[:record],
    }
  end

  def read_wire(label, path, item)
    quoted_path = sql_string(path)
    sql = "SELECT toTypeName(payload), toJSONString(payload) FROM file(#{quoted_path}, 'RowBinaryWithNamesAndTypes') " \
          'SETTINGS input_format_binary_decode_types_in_binary_format=1, ' \
          'input_format_binary_read_json_as_string=0, output_format_binary_write_json_as_string=0 FORMAT TSVRaw'
    invocation = invoke(label, sql, query_file: path)
    expected = "#{item[:type]}\t#{item[:json]}\n".b
    {
      exact: successful?(invocation) && bytes_equal?(invocation.stdout, expected),
      record: invocation.record,
    }
  end

  def rowbinary_header(descriptor)
    varuint(1) + ch_string('payload') + descriptor
  end

  def parse_stock_rowbinary(bytes)
    reader = BinaryReader.new(bytes)
    column_count = reader.read_varuint
    raise "unexpected RowBinary header column count #{column_count}" unless column_count == 1
    names = Array.new(column_count) { reader.read_string }
    descriptor_start = reader.offset
    parse_json_descriptor(reader)
    header_end = reader.offset
    {
      names: names,
      header: bytes.byteslice(0, header_end).to_s.b,
      descriptor: bytes.byteslice(descriptor_start, header_end - descriptor_start).to_s.b,
      row: bytes.byteslice(header_end..).to_s.b,
    }
  end

  def parse_json_descriptor(reader)
    raise 'unexpected JSON descriptor type code' unless reader.read_byte == 0x30
    raise 'unsupported JSON descriptor version' unless reader.read_byte == 0
    max_dynamic_paths = reader.read_varuint
    max_dynamic_types = reader.read_byte
    raise 'unreasonable JSON max_dynamic_paths' if max_dynamic_paths > 10_000
    raise 'unreasonable JSON max_dynamic_types' if max_dynamic_types > 254
    typed_paths = reader.read_varuint
    raise 'unexpected number of typed JSON paths' if typed_paths > 1
    typed_paths.times do
      reader.read_string
      parse_typed_path_type(reader)
    end
    raise 'SKIP paths are outside this oracle profile' unless reader.read_varuint.zero?
    raise 'SKIP regexps are outside this oracle profile' unless reader.read_varuint.zero?
  end

  def parse_typed_path_type(reader, depth = 0)
    raise 'typed JSON path descriptor nesting exceeds oracle bound' if depth > 4
    tag = reader.read_byte
    case tag
    when 0x01 # UInt8
      nil
    when 0x1e, 0x23 # Array, Nullable
      parse_typed_path_type(reader, depth + 1)
    else
      raise format('typed JSON path has unsupported descriptor tag 0x%02x', tag)
    end
  end

  def varuint(value)
    remaining = Integer(value)
    fail!('negative VarUInt') if remaining.negative?
    output = ''.b
    loop do
      byte = remaining & 0x7f
      remaining >>= 7
      output << [byte | (remaining.zero? ? 0 : 0x80)].pack('C')
      break if remaining.zero?
    end
    output
  end

  def ch_string(value)
    bytes = value.to_s.b
    varuint(bytes.bytesize) + bytes
  end

  def bytes_equal?(left, right)
    left == right
  end

  def comparator_self_test!
    literal = [0x00, 0xff].pack('C*').b
    fail!('byte comparator accepted a changed byte') if bytes_equal?(literal, [0x00, 0xfe].pack('C*').b)
    fail!('byte comparator accepted a truncated payload') if bytes_equal?(literal, literal.byteslice(0, 1))
    fail!('byte comparator accepted an appended byte') if bytes_equal?(literal, literal + "\x00".b)
    fail!('byte comparator rejected an exact payload') unless bytes_equal?(literal, literal.dup)
  end

  def sql_string(value)
    escaped = value.to_s.gsub(/[\\']/) { |character| "\\#{character}" }
    "'#{escaped}'"
  end

  def invoke(label, sql, query_file: nil)
    fail!('unsafe evidence label') unless /\A[a-z0-9_-]+\z/.match?(label)
    store = File.join(@root, 'stores', label)
    Dir.mkdir(store, 0o700)
    args = [@binary, 'local', '--path', store, '--max_threads=1',
            "--max_memory_usage=#{MEMORY_LIMIT_BYTES}", '--query', sql]
    stdout, stderr, status, timed_out, spawn_error, stdin_error, stdout_error, stderr_error = execute(args, ''.b)
    classification = process_classification(status, timed_out, spawn_error, stdin_error,
                                            stdout_error, stderr_error, stderr)
    @process_failures += 1 unless classification == 'success'
    argv_bytes = JSON.generate(args)
    record = {
      label: label, argv: args, argv_file: "#{label}.argv.json",
      argv_sha256: Digest::SHA256.hexdigest(argv_bytes),
      sql: sql, sql_file: "#{label}.sql", sql_sha256: Digest::SHA256.hexdigest(sql.b),
      cwd: Dir.pwd, environment: {'TZ' => 'UTC'}, store: store,
      structured_json_settings: if sql.include?('input_format_binary_read_json_as_string=0') &&
                                   sql.include?('output_format_binary_write_json_as_string=0')
                                  STRUCTURED_JSON_SETTINGS
                                end,
      exit: status&.exitstatus, signal: status&.termsig, timed_out: timed_out,
      timeout_seconds: PROCESS_TIMEOUT_SECONDS,
      spawn_error: spawn_error, stdin_write_error: stdin_error,
      stdout_read_error: stdout_error, stderr_read_error: stderr_error,
      process_classification: classification,
      input_bytes: 0, input_sha256: Digest::SHA256.hexdigest(''.b),
      stdout_bytes: stdout.bytesize, stdout_sha256: Digest::SHA256.hexdigest(stdout),
      stderr_bytes: stderr.bytesize, stderr_sha256: Digest::SHA256.hexdigest(stderr),
      input_file: "#{label}.input", stdout_file: "#{label}.stdout",
      stderr_file: "#{label}.stderr", record_file: "#{label}.json",
    }
    if query_file
      record[:query_file_input] = {
        path: query_file, bytes: File.size(query_file),
        sha256: Digest::SHA256.file(query_file).hexdigest,
      }
    end
    write_artifact("invocations/#{label}.argv.json", argv_bytes)
    write_artifact("invocations/#{label}.sql", sql.b)
    write_artifact("invocations/#{label}.input", ''.b)
    write_artifact("invocations/#{label}.stdout", stdout)
    write_artifact("invocations/#{label}.stderr", stderr)
    write_json("invocations/#{label}.json", record)
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

  def file_sha256(path)
    fail!("pinned runtime is missing, non-executable, or a symbolic link: #{path}") unless
      File.file?(path) && File.executable?(path) && !File.symlink?(path)
    Digest::SHA256.file(path).hexdigest
  end

  def write_path(path, bytes)
    File.open(path, 'wbx', 0o600) { |file| file.write(bytes) }
  end

  def write_artifact(relative, bytes)
    path = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    write_path(path, bytes)
  end

  def write_json(relative, value)
    write_artifact(relative, JSON.pretty_generate(value) + "\n")
  end

  def utf8(bytes)
    bytes&.dup&.force_encoding(Encoding::UTF_8)
  end

  def fail!(message)
    raise RuntimeError, "W180 JSON binary oracle: #{message}"
  end
end

def main
  options = {binary: JsonBinaryKernelW180Probe::DEFAULT_BINARY, evidence_root: nil, library_root: nil}
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/check_json_binary_kernel_w180.rb --evidence-root EMPTY_DIR --library-root DIR [--clickhouse PATH]'
    parser.on('--clickhouse PATH', 'Pinned stock ClickHouse executable') { |value| options[:binary] = value }
    parser.on('--evidence-root PATH', 'Existing empty direct child of /private/tmp') { |value| options[:evidence_root] = value }
    parser.on('--library-root PATH', 'Root containing manifest.json and the seven descriptor/row fixtures') { |value| options[:library_root] = value }
  end.parse!
  probe = JsonBinaryKernelW180Probe.new(options[:binary], options[:evidence_root], options[:library_root])
  exit(probe.run ? 0 : 1)
rescue StandardError => error
  warn "W180 JSON binary oracle failed: #{error.class}: #{error.message}"
  exit 1
end

if $PROGRAM_NAME == __FILE__
  main
end
