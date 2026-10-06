#!/usr/bin/env ruby
# Root-run finite paired oracle for nested JSON scalar RowBinary values.
# Reuses W180's bounded supervisor only; it never builds ClickHouse or Crystal.
require_relative 'check_json_binary_kernel_w180'

class JsonNestedScalarW182Probe < JsonBinaryKernelW180Probe
  INNER_JSON_TYPE = 'JSON(max_dynamic_types=1, max_dynamic_paths=1, n UInt8)'.freeze
  INNER_JSON_DESCRIPTOR = ['3000010101016e010000'].pack('H*').b.freeze
  JSON_TYPE_DESCRIPTOR = ['3000800820000000'].pack('H*').b.freeze
  JSON_ROW_42 = ['01016e2a'].pack('H*').b.freeze
  JSON_ROW_7 = ['01016e07'].pack('H*').b.freeze

  PROFILE = lambda do |id, type, descriptor_hex, row_hex|
    {
      id: id.freeze,
      type: type.freeze,
      descriptor: [descriptor_hex].pack('H*').b.freeze,
      row: [row_hex].pack('H*').b.freeze,
      descriptor_hex: descriptor_hex.freeze,
      row_hex: row_hex.freeze,
    }.freeze
  end

  PROFILES = [
    PROFILE.call(
      'array_json', "Array(#{INNER_JSON_TYPE})",
      '1e3000010101016e010000', '0201016e2a01016e07'
    ),
    PROFILE.call(
      'tuple_json_u8', "Tuple(#{INNER_JSON_TYPE}, UInt8)",
      '1f023000010101016e01000001', '01016e2a07'
    ),
    PROFILE.call(
      'nested_json_u8', "Nested(j #{INNER_JSON_TYPE}, u UInt8)",
      '2f02016a3000010101016e010000017501', '0101016e2a07'
    ),
    PROFILE.call(
      'map_string_json', "Map(String, #{INNER_JSON_TYPE})",
      '27153000010101016e010000', '01016b01016e07'
    ),
    PROFILE.call(
      'map_json_u8', "Map(#{INNER_JSON_TYPE}, UInt8)",
      '273000010101016e01000001', '0101016e2a07'
    ),
    PROFILE.call(
      'nullable_json_present', "Nullable(#{INNER_JSON_TYPE})",
      '233000010101016e010000', '0001016e2a'
    ),
    PROFILE.call(
      'nullable_json_null', "Nullable(#{INNER_JSON_TYPE})",
      '233000010101016e010000', '01'
    ),
    PROFILE.call(
      'variant_json_arm', "Variant(#{INNER_JSON_TYPE}, UInt8)",
      '2a023000010101016e01000001', '0001016e2a'
    ),
    PROFILE.call(
      'variant_u8_arm', "Variant(#{INNER_JSON_TYPE}, UInt8)",
      '2a023000010101016e01000001', '0107'
    ),
    PROFILE.call(
      'variant_null', "Variant(#{INNER_JSON_TYPE}, UInt8)",
      '2a023000010101016e01000001', 'ff'
    ),
    PROFILE.call(
      'array_tuple_json_u8', "Array(Tuple(#{INNER_JSON_TYPE}, UInt8))",
      '1e1f023000010101016e01000001', '0101016e2a07'
    ),
    PROFILE.call(
      'json_typed_child_json', "JSON(item #{INNER_JSON_TYPE})",
      '300080082001046974656d3000010101016e0100000000',
      '01046974656d01016e2a'
    ),
    PROFILE.call(
      'json_typed_child_array_json', "JSON(item Array(#{INNER_JSON_TYPE}))",
      '300080082001046974656d1e3000010101016e0100000000',
      '01046974656d0201016e2a01016e07'
    ),
    PROFILE.call(
      'json_runtime_child_json', 'JSON',
      '3000800820000000', '01046974656d3000010101016e01000001016e2a'
    ),
    PROFILE.call(
      'dynamic_json', 'Dynamic(max_types=0)',
      '2b00', '3000010101016e01000001016e2a'
    ),
  ].freeze
  PROFILE_IDS = PROFILES.map { |item| item[:id] }.freeze

  ROWBINARY_SETTINGS = [
    'input_format_binary_read_json_as_string=0',
    'output_format_binary_write_json_as_string=0',
    'output_format_binary_encode_types_in_binary_format=1',
    'flatten_nested=0',
  ].join(', ').freeze
  LIBRARY_INPUT_SETTINGS = [
    'input_format_binary_decode_types_in_binary_format=1',
    'input_format_binary_read_json_as_string=0',
    'output_format_binary_write_json_as_string=0',
    'output_format_binary_encode_types_in_binary_format=1',
    'flatten_nested=0',
  ].join(', ').freeze

  def initialize(evidence_root, library_root)
    @binary = DEFAULT_BINARY
    @root = validate_evidence_root(evidence_root)
    @library_root = validate_library_root(library_root)
    @invocations = []
    @process_failures = 0
    @profile_results = []
    @status = 'not_started'
  end

  def run
    Dir.mkdir(File.join(@root, 'profiles'), 0o700)
    Dir.mkdir(File.join(@root, 'stores'), 0o700)
    comparator_self_test!

    library_before = library_snapshot
    runtime_before = file_sha256(@binary)
    version_before = nil
    version_before_ok = false
    profiles_ran = false

    if runtime_before == BINARY_SHA256
      version_before = invoke('pin-before', VERSION_SQL)
      version_before_ok = successful?(version_before) && version_before.stdout == VERSION
      if version_before_ok
        @runtime_identity = {
          path: @binary, sha256: runtime_before,
          version: VERSION.chomp.split("\t", 2)[0],
          build_hash: VERSION.chomp.split("\t", 2)[1],
        }
        @status = 'profiles_incomplete'
        run_profiles
        profiles_ran = true
      else
        @status = 'runtime_version_pin_mismatch'
      end
    else
      @status = 'runtime_hash_mismatch'
    end

    runtime_before_after_profiles = file_sha256(@binary)
    version_after = nil
    version_after_ok = false
    if runtime_before == BINARY_SHA256 && runtime_before_after_profiles == BINARY_SHA256
      version_after = invoke('pin-after', VERSION_SQL)
      version_after_ok = successful?(version_after) && version_after.stdout == VERSION
      @status = 'post_runtime_version_pin_mismatch' unless version_after_ok
    else
      @status = 'post_runtime_hash_mismatch'
    end
    runtime_after = file_sha256(@binary)
    library_after = library_snapshot
    library_unchanged = library_before == library_after

    profiles_match = profiles_ran && @profile_results.length == PROFILES.length &&
                     @profile_results.all? { |item| item[:ok] }
    if @status == 'profiles_incomplete'
      @status = profiles_match ? 'all_profiles_match' : 'profile_mismatch'
    end
    if [runtime_before, runtime_before_after_profiles, runtime_after].any? { |sha| sha != BINARY_SHA256 }
      @status = 'runtime_hash_mismatch'
    elsif !version_before_ok || !version_after_ok
      @status = 'runtime_version_pin_mismatch'
    elsif !library_unchanged
      @status = 'library_fixture_changed'
    end

    summary = {
      qualification: 'paired pinned-stock oracle for 15 nested JSON scalar RowBinary witnesses',
      claim_boundary: 'finite scalar RowBinary descriptors and rows only; no persisted-part or complete grammar/layout claim',
      status: @status,
      profile_count: PROFILES.length,
      profiles_ok: @profile_results.count { |item| item[:ok] },
      profiles: @profile_results,
      native_process_failures: @process_failures,
      runtime: {
        path: @binary, expected_sha256: BINARY_SHA256,
        sha256_before: runtime_before,
        sha256_before_after_profiles: runtime_before_after_profiles,
        sha256_after: runtime_after,
        expected_version_build_stdout: VERSION.dup.force_encoding(Encoding::UTF_8),
        before_pin_matches: version_before_ok,
        before_pin_record: version_before && version_before.record,
        after_pin_matches: version_after_ok,
        after_pin_record: version_after && version_after.record,
      },
      library_root: @library_root,
      library_fixture_hashes_before: library_before,
      library_fixture_hashes_after: library_after,
      library_fixtures_unchanged: library_unchanged,
      rowbinary_settings: ROWBINARY_SETTINGS,
      library_input_settings: LIBRARY_INPUT_SETTINGS,
      invocations: @invocations,
    }
    write_json('summary.json', summary)

    ok = @status == 'all_profiles_match' && @process_failures.zero? &&
         @profile_results.length == PROFILES.length && @profile_results.all? { |item| item[:ok] } &&
         library_unchanged
    if ok
      puts "PASS: W182 nested JSON scalar oracle: #{summary[:profiles_ok]}/#{PROFILES.length}, process_failures=#{@process_failures}, pin=true"
    else
      puts "W182 nested JSON scalar oracle: #{summary[:profiles_ok]}/#{PROFILES.length}, process_failures=#{@process_failures}, status=#{@status}"
    end
    puts "Evidence: #{@root}"
    ok
  end

  private

  def validate_library_root(path)
    fail!('library fixture root is required') unless path && !path.empty?
    fail!('library fixture root must not be a symbolic link') if File.symlink?(path)
    root = File.realpath(path)
    fail!('library fixture root must be a directory') unless File.directory?(root)
    fail!('library fixture root path must be canonical') unless File.expand_path(path) == root
    root
  end

  def library_snapshot
    fail!('library fixture profile roster differs') unless Dir.children(@library_root).sort == PROFILE_IDS.sort
    snapshot = {}
    PROFILES.each do |item|
      profile_root = File.join(@library_root, item[:id])
      fail!("library profile directory is not plain for #{item[:id]}") if
        File.symlink?(profile_root) || !File.directory?(profile_root)
      fail!("library profile files differ for #{item[:id]}") unless
        Dir.children(profile_root).sort == %w[descriptor.bin row.bin]
      record = {}
      %w[descriptor.bin row.bin].each do |name|
        file = File.join(profile_root, name)
        fail!("library fixture is not a plain file for #{item[:id]}/#{name}") unless
          File.file?(file) && !File.symlink?(file)
        record[name] = {
          bytes: File.size(file), sha256: Digest::SHA256.file(file).hexdigest,
        }
      end
      snapshot[item[:id]] = record
    end
    snapshot
  end

  def run_profiles
    PROFILES.each do |item|
      result = {
        id: item[:id], type: item[:type],
        expected_descriptor_hex: item[:descriptor_hex],
        expected_row_hex: item[:row_hex],
        stock_literal_exact: false, library_binary_input_exact: false,
        ok: false,
      }
      begin
        stock = read_stock_literal(item)
        result[:stock_literal_exact] = stock[:exact]
        result[:stock_literal_invocation] = stock[:invocation]
        result[:stock_output_sha256] = stock[:stdout_sha256]

        library = read_library_binary_input(item)
        result[:library_descriptor_sha256] = library[:descriptor_sha256]
        result[:library_row_sha256] = library[:row_sha256]
        result[:library_input_sha256] = library[:input_sha256]
        result[:library_output_sha256] = library[:stdout_sha256]
        result[:library_binary_input_exact] = library[:exact]
        result[:library_invocation] = library[:invocation]
        result[:ok] = result[:stock_literal_exact] && result[:library_binary_input_exact]
      rescue StandardError => error
        result[:runner_error] = "#{error.class}: #{error.message}"
      end
      @profile_results << result
    end
  end

  def read_stock_literal(item)
    directory = File.join(@root, 'profiles', item[:id])
    Dir.mkdir(directory, 0o700)
    literal_path = File.join(directory, 'literal-row.bin')
    write_path(literal_path, item[:row])
    schema = "payload #{item[:type]}"
    sql = "SELECT payload FROM file(#{sql_string(literal_path)}, 'RowBinary', #{sql_string(schema)}) " \
          "SETTINGS #{ROWBINARY_SETTINGS} FORMAT RowBinaryWithNamesAndTypes"
    invocation = invoke("literal-#{item[:id]}", sql, query_file: literal_path)
    expected = rowbinary_header(item[:descriptor]) + item[:row]
    output_path = File.join(directory, 'literal-stock-output.bin')
    write_path(output_path, invocation.stdout)
    parsed = nil
    parse_error = nil
    begin
      parsed = parse_known_rowbinary(invocation.stdout, item[:descriptor].bytesize)
    rescue StandardError => error
      parse_error = "#{error.class}: #{error.message}"
    end
    if parsed
      write_path(File.join(directory, 'descriptor.bin'), parsed[:descriptor])
      write_path(File.join(directory, 'row.bin'), parsed[:row])
    end
    {
      exact: successful?(invocation) && parsed && parsed[:names] == ['payload'.b] &&
             bytes_equal?(parsed[:header], rowbinary_header(item[:descriptor])) &&
             bytes_equal?(parsed[:descriptor], item[:descriptor]) &&
             bytes_equal?(parsed[:row], item[:row]) && bytes_equal?(invocation.stdout, expected),
      invocation: invocation.record,
      stdout_sha256: Digest::SHA256.hexdigest(invocation.stdout),
      parse_error: parse_error,
    }
  end

  def read_library_binary_input(item)
    profile_root = File.join(@library_root, item[:id])
    descriptor_path = File.join(profile_root, 'descriptor.bin')
    row_path = File.join(profile_root, 'row.bin')
    descriptor = File.binread(descriptor_path)
    row = File.binread(row_path)
    input = rowbinary_header(descriptor) + row
    input_path = File.join(@root, 'profiles', item[:id], 'library-input.bin')
    write_path(input_path, input)
    sql = "SELECT payload FROM file(#{sql_string(input_path)}, 'RowBinaryWithNamesAndTypes') " \
          "SETTINGS #{LIBRARY_INPUT_SETTINGS} FORMAT RowBinaryWithNamesAndTypes"
    invocation = invoke("library-#{item[:id]}", sql, query_file: input_path)
    expected = rowbinary_header(item[:descriptor]) + item[:row]
    output_path = File.join(@root, 'profiles', item[:id], 'library-stock-output.bin')
    write_path(output_path, invocation.stdout)
    {
      exact: successful?(invocation) && bytes_equal?(descriptor, item[:descriptor]) &&
             bytes_equal?(row, item[:row]) && bytes_equal?(invocation.stdout, expected),
      descriptor_sha256: Digest::SHA256.hexdigest(descriptor),
      row_sha256: Digest::SHA256.hexdigest(row),
      input_sha256: Digest::SHA256.hexdigest(input),
      stdout_sha256: Digest::SHA256.hexdigest(invocation.stdout),
      invocation: invocation.record,
    }
  end

  def parse_known_rowbinary(bytes, descriptor_size)
    reader = BinaryReader.new(bytes)
    column_count = reader.read_varuint
    fail!("unexpected RowBinary header column count #{column_count}") unless column_count == 1
    names = Array.new(column_count) { reader.read_string }
    descriptor_start = reader.offset
    header_end = descriptor_start + descriptor_size
    fail!('truncated binary type descriptor in RowBinary header') if header_end > bytes.bytesize
    {
      names: names,
      header: bytes.byteslice(0, header_end).to_s.b,
      descriptor: bytes.byteslice(descriptor_start, descriptor_size).to_s.b,
      row: bytes.byteslice(header_end..).to_s.b,
    }
  end

  def rowbinary_header(descriptor)
    varuint(1) + ch_string('payload') + descriptor
  end

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

  def fail!(message)
    raise RuntimeError, "W182 nested JSON scalar oracle: #{message}"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    evidence_root, library_root = ARGV
    unless ARGV.length == 2
      raise ArgumentError, 'usage: ruby scripts/check_json_nested_scalar_w182.rb EMPTY_EVIDENCE_ROOT LIBRARY_FIXTURE_ROOT'
    end
    probe = JsonNestedScalarW182Probe.new(evidence_root, library_root)
    exit(probe.run ? 0 : 1)
  rescue StandardError => error
    warn "W182 nested JSON scalar oracle failed: #{error.class}: #{error.message}"
    exit 1
  end
end
