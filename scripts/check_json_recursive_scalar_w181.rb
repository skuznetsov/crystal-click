#!/usr/bin/env ruby
# Root-run finite paired JSON scalar oracle. It reuses only W180's bounded
# process supervisor and artifact writer, not its seven-profile expectations.
require_relative 'check_json_binary_kernel_w180'

class JsonRecursiveScalarW181Probe < JsonBinaryKernelW180Probe
  PATH_WIRE = [4].pack('C') + 'item'.b
  REJECTED_TYPED_PROFILES = [
    ['qbit', 'QBit(Float32, 2)'],
    ['nullable_qbit', 'Nullable(QBit(Float32, 2))'],
    ['count', 'AggregateFunction(count, UInt8)'],
    ['numeric_map', 'Map(UInt8, UInt8)'],
    ['interval', 'IntervalSecond'],
    ['bfloat16', 'BFloat16'],
    ['nullable_nothing', 'Nullable(Nothing)'],
  ].map(&:freeze).freeze
  REJECTED_RUNTIME_PROFILES = [
    ['variant', '2a021501012a', 'Nested Variant types are not allowed'],
    ['dynamic', '2b20012a', 'Dynamic type is not allowed inside Variant type'],
    ['lc_nullable', '262315000161', 'Nullable/LowCardinality(Nullable) types are not allowed inside Variant type'],
  ].map(&:freeze).freeze
  PROFILES = [
    ['lc_string', 'LowCardinality(String)', '2615', '0161'],
    ['variant_uint8', 'Variant(String, UInt8)', '2a021501', '012a'],
    ['variant_null', 'Variant(String, UInt8)', '2a021501', 'ff'],
    ['dynamic_array_nullable', 'Dynamic', '2b20', '1e23010301002a0007'],
    ['nested', 'Nested(n String, v UInt8)', '2f02016e15017601', '020161070000'],
    ['saf_sum', 'SimpleAggregateFunction(sum, UInt64)', '2e0373756d000104', '2a00000000000000'],
    ['array_lc_nullable', 'Array(LowCardinality(Nullable(String)))', '1e262315', '03000001000161'],
    ['map_string', 'Map(String, UInt8)', '271501', '0101612a'],
    ['map_lc_string', 'Map(LowCardinality(String), UInt8)', '27261501', '0101612a'],
  ].map do |id, child_name, child_hex, value_hex|
    child = [child_hex].pack('H*')
    descriptor = [0x30, 0, 0x80, 8, 0x20, 1].pack('C*') + PATH_WIRE + child + [0, 0].pack('C*')
    {id: id, type: "JSON(item #{child_name})", child_type: child_name,
     descriptor: descriptor, row: [1].pack('C') + PATH_WIRE + [value_hex].pack('H*')}.freeze
  end.concat([
    ['runtime_lc_string', 'LowCardinality(String)', '2615', '0161'],
    ['runtime_nested', 'Nested(n String, v UInt8)', '2f02016e15017601', '020161070000'],
    ['runtime_saf_sum', 'SimpleAggregateFunction(sum, UInt64)', '2e0373756d000104', '2a00000000000000'],
    ['runtime_interval', 'IntervalSecond', '2203', '2a00000000000000'],
    ['runtime_bfloat16', 'BFloat16', '31', '803f'],
    ['runtime_numeric_map', 'Map(UInt8, UInt8)', '270101', '012a07'],
  ].map do |id, child_name, child_hex, value_hex|
    {id: id, type: 'JSON', child_type: child_name,
     descriptor: [0x30, 0, 0x80, 8, 0x20, 0, 0, 0].pack('C*'),
     row: [1].pack('C') + PATH_WIRE + [child_hex + value_hex].pack('H*')}.freeze
  end).freeze

  def initialize(evidence_root, library_root = nil)
    @binary = DEFAULT_BINARY
    @root = validate_evidence_root(evidence_root)
    @library_root = library_root && File.realpath(library_root)
    @invocations = []
    @process_failures = 0
  end

  def run
    Dir.mkdir(File.join(@root, 'stores'), 0o700)
    comparator_self_test!
    before_sha = file_sha256(@binary)
    fail!('runtime hash mismatch') unless before_sha == BINARY_SHA256
    before_pin = invoke('pin-before', VERSION_SQL)
    fail!('runtime version mismatch') unless successful?(before_pin) && before_pin.stdout == VERSION
    results = PROFILES.map do |item|
      id = item[:id]
      root = File.join(@root, id)
      Dir.mkdir(root, 0o700)
      literal_path = File.join(root, 'literal-row.bin')
      write_path(literal_path, item[:row])
      expression = "file(#{sql_string(literal_path)}, 'RowBinary', #{sql_string('payload ' + item[:type])})"
      settings = ' SETTINGS input_format_binary_read_json_as_string=0, output_format_binary_write_json_as_string=0, output_format_binary_encode_types_in_binary_format=1'
      stock = invoke('stock-' + id, "SELECT payload FROM #{expression}#{settings} FORMAT RowBinaryWithNamesAndTypes", query_file: literal_path)
      expected = [1].pack('C') + ch_string('payload') + item[:descriptor] + item[:row]
      exact = successful?(stock) && bytes_equal?(stock.stdout, expected)
      if exact
        header_prefix = [1].pack('C') + ch_string('payload')
        write_path(File.join(root, 'descriptor.bin'), stock.stdout.byteslice(header_prefix.bytesize, item[:descriptor].bytesize))
        write_path(File.join(root, 'row.bin'), stock.stdout.byteslice(expected.bytesize - item[:row].bytesize, item[:row].bytesize))
      end
      result = {id: id, type: item[:type], expected_descriptor_hex: item[:descriptor].unpack1('H*'),
                expected_row_hex: item[:row].unpack1('H*'), stock_wire_exact: exact,
                stock_exit: stock.record[:exit], stock_signal: stock.record[:signal], stock_timeout: stock.record[:timed_out]}
      if @library_root
        source_dir = File.join(@library_root, id)
        descriptor_path = File.join(source_dir, 'descriptor.bin')
        row_path = File.join(source_dir, 'row.bin')
        fail!('missing/nonplain library input') unless [descriptor_path, row_path].all? { |p| File.file?(p) && !File.symlink?(p) }
        descriptor, row = File.binread(descriptor_path), File.binread(row_path)
        result[:library_descriptor_sha256] = Digest::SHA256.hexdigest(descriptor)
        result[:library_row_sha256] = Digest::SHA256.hexdigest(row)
        result[:library_wire_exact] = descriptor == item[:descriptor] && row == item[:row]
        before = Digest::SHA256.file(row_path).hexdigest
        header_path = File.join(root, 'actual-library-rowbinary.bin')
        write_path(header_path, [1].pack('C') + ch_string('payload') + descriptor + row)
        library_sql = "SELECT payload FROM file(#{sql_string(header_path)}, 'RowBinaryWithNamesAndTypes')#{settings}, input_format_binary_decode_types_in_binary_format=1 FORMAT RowBinaryWithNamesAndTypes"
        readback = invoke('library-' + id, library_sql, query_file: header_path)
        fail!('library row changed') unless before == Digest::SHA256.file(row_path).hexdigest
        result[:library_stock_exact] = successful?(readback) && readback.stdout == expected
      end
      result[:ok] = exact && (!@library_root || (result[:library_wire_exact] && result[:library_stock_exact]))
      result
    end
    rejections = REJECTED_TYPED_PROFILES.map do |id, child|
      sql = "SELECT CAST('{}', #{sql_string('JSON(item ' + child + ')')}) SETTINGS output_format_binary_write_json_as_string=0 FORMAT RowBinary"
      rejection = invoke('reject-' + id, sql)
      record = rejection.record
      expected = record[:exit] == 43 && record[:signal].nil? && !record[:timed_out] &&
                 rejection.stdout.empty? && rejection.stderr.include?('JSON serialization doesn\'t support the return type schema:') &&
                 record[:spawn_error].nil? && record[:stdin_write_error].nil? &&
                 record[:stdout_read_error].nil? && record[:stderr_read_error].nil? &&
                 !SYSTEM_FAILURE.match?(rejection.stderr)
      # Preserve the actual exception classification/status; only expected
      # schema refusals are removed from the unexpected-failure counter.
      @process_failures -= 1 if expected && record[:process_classification] != 'success'
      {id: id, child_type: child, expected_refusal: expected, expected_exit: 43,
       refusal_boundary: 'json_static_schema', invocation: record}
    end
    rejections.concat(REJECTED_RUNTIME_PROFILES.map do |id, hex, message|
      path = File.join(@root, 'rejected-runtime-' + id + '.bin')
      write_path(path, [1].pack('C') + PATH_WIRE + [hex].pack('H*'))
      sql = "SELECT payload FROM file(#{sql_string(path)}, 'RowBinary', 'payload JSON') SETTINGS input_format_binary_read_json_as_string=0, output_format_binary_write_json_as_string=0 FORMAT RowBinary"
      rejection = invoke('reject-runtime-' + id, sql, query_file: path)
      record = rejection.record
      expected = record[:exit] == 36 && record[:signal].nil? && !record[:timed_out] &&
                 rejection.stdout.empty? && rejection.stderr.include?(message) &&
                 record[:spawn_error].nil? && record[:stdin_write_error].nil? &&
                 record[:stdout_read_error].nil? && record[:stderr_read_error].nil? &&
                 !SYSTEM_FAILURE.match?(rejection.stderr)
      @process_failures -= 1 if expected && record[:process_classification] != 'success'
      {id: id, expected_refusal: expected, expected_exit: 36,
       refusal_boundary: 'dynamic_actual_roster', invocation: record}
    end)
    after_pin = invoke('pin-after', VERSION_SQL)
    after_sha = file_sha256(@binary)
    pin_ok = after_sha == BINARY_SHA256 && successful?(after_pin) && after_pin.stdout == VERSION
    summary = {version: 1, finite_profile_count: PROFILES.size, profiles_ok: results.count { |r| r[:ok] },
               profiles: results, expected_rejections: rejections, invocations: @invocations, process_failures: @process_failures,
               runtime_sha256_before: before_sha, runtime_sha256_after: after_sha, runtime_pin_ok: pin_ok,
               library_root: @library_root, boundary: 'finite scalar RowBinary witnesses, no persisted-part or complete grammar/layout claim'}
    write_json('summary.json', summary)
    puts "W181 JSON scalar oracle: #{summary[:profiles_ok]}/#{PROFILES.size}, process_failures=#{@process_failures}, pin=#{pin_ok}"
    puts "Evidence: #{@root}"
    pin_ok && @process_failures.zero? && results.all? { |r| r[:ok] } && rejections.all? { |r| r[:expected_refusal] }
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    evidence_root, library_root = ARGV
    exit(JsonRecursiveScalarW181Probe.new(evidence_root, library_root).run ? 0 : 1)
  rescue StandardError => error
    warn "W181 JSON scalar oracle failed: #{error.class}: #{error.message}"
    exit 1
  end
end
