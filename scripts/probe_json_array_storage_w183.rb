#!/usr/bin/env ruby
# Root-run stock physical probe; it does not build ClickHouse/Crystal or claim
# that this library can read the resulting recursive JSON part.

require 'digest'
require 'find'
require 'json'
require 'optparse'
require_relative 'check_json_binary_kernel_w180'

module JsonArrayStorageW183
  BINARY = JsonBinaryKernelW180Probe::DEFAULT_BINARY
  SHA256 = JsonBinaryKernelW180Probe::BINARY_SHA256
  VERSION = '26.10.1.1201'
  BUILD = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'
  MEMORY = JsonBinaryKernelW180Probe::MEMORY_LIMIT_BYTES
  TIMEOUT = JsonBinaryKernelW180Probe::PROCESS_TIMEOUT_SECONDS
  GRACE = JsonBinaryKernelW180Probe::TERMINATION_GRACE_SECONDS
  COMPRESSED_INPUT_LIMIT = 64 * 1024
  OUTER_RUN_SAFE_LIMIT = 12 * 1024 * 1024 * 1024
  ROOT_JSON = 'JSON(max_dynamic_types=0, max_dynamic_paths=0, t UInt8)'
  ARRAY_JSON = "Array(#{ROOT_JSON})"
  SETTINGS = [
    'index_granularity=2', 'index_granularity_bytes=10485760',
    'enable_mixed_granularity_parts=1', 'min_rows_for_wide_part=0',
    'min_bytes_for_wide_part=0', 'compress_marks=0', 'compress_primary_key=0',
    'min_compress_block_size=0', 'max_compress_block_size=4096',
    'ratio_of_defaults_for_sparse_serialization=1', "default_compression_codec='LZ4'",
    "object_serialization_version='v3'",
    "object_shared_data_serialization_version_for_zero_level_parts='map'",
    'propagate_types_serialization_versions_to_nested_types=true',
    "map_serialization_version='basic'", "map_serialization_version_for_zero_level_parts='basic'",
  ].join(', ')
  PROFILES = [
    {id: 'array_json_mixed', kind: :array, rows: [
      {id: 1, value: []}, {id: 2, value: []},
      {id: 3, value: []}, {id: 4, value: ['{"t":7}']},
      {id: 5, value: ['{"t":11}', '{"t":13}']}, {id: 6, value: ['{"t":17}']},
      {id: 7, value: []}, {id: 8, value: []},
    ]},
    {id: 'array_json_all_empty', kind: :array,
      rows: (1..8).map { |id| {id: id, value: []} }},
    {id: 'root_json_typed_control', kind: :root,
      rows: (1..8).map { |id| {id: id, value: "{\"t\":#{id}}"} }},
  ].freeze

  class Probe
    def initialize(binary, evidence_root)
      @binary = File.expand_path(binary)
      @root = validate_root(evidence_root)
      @invocations = []
      @profiles = []
      @fatal_error = nil
    end

    def run
      %w[invocations stores parts].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      @sha_before = binary_sha
      if @sha_before != SHA256
        @fatal_error = "pinned executable SHA-256 mismatch: #{@sha_before}"
      else
        PROFILES.each do |profile|
          break unless binary_sha == SHA256
          result = run_profile(profile)
          @profiles << result
          break unless result[:runtime_pin_matches] && result[:binary_sha_after] == SHA256
        end
      end
      PROFILES.drop(@profiles.size).each { |p| @profiles << {id: p[:id], status: 'skipped_pin_or_binary_mismatch'} }
      @sha_after = binary_sha
      # ClickHouse owns legitimate catalog links under stores/*/data. Only
      # selected part paths and our captured evidence must be plain trees.
      %w[invocations parts].each { |name| validate_plain_tree!(File.join(@root, name)) }
      write_summary
      puts "W183 status=#{overall_status}; profiles=#{@profiles.size}/#{PROFILES.size}; evidence=#{@root}"
      overall_status == 'observed_all_profiles'
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @sha_after = binary_sha rescue nil
      write_summary rescue nil
      warn "W183 probe runner error: #{@fatal_error}"
      false
    end

    private

    def validate_root(path)
      raise 'evidence root is required' unless path && !path.empty?
      expanded = File.expand_path(path)
      parent = File.realpath('/private/tmp')
      raise 'evidence root must be a direct child of /private/tmp' unless File.dirname(expanded) == parent
      raise 'evidence root must not be a symlink' if File.symlink?(expanded)
      raise 'evidence root must be an existing empty directory' unless
        File.directory?(expanded) && File.realpath(expanded) == expanded && Dir.children(expanded).empty?
      expanded
    rescue Errno::ENOENT
      raise 'evidence root must already exist'
    end

    def binary_sha
      raise "pinned executable is missing, non-executable, or symlinked: #{@binary}" unless
        File.file?(@binary) && File.executable?(@binary) && !File.symlink?(@binary)
      Digest::SHA256.file(@binary).hexdigest
    end

    def run_profile(profile)
      id = profile[:id]
      store = File.join(@root, 'stores', id)
      Dir.mkdir(store, 0o700)
      sql = profile_sql(profile)
      sql_path = File.join(@root, 'invocations', "#{id}.stdin.sql")
      write_new(sql_path, sql)
      argv = [@binary, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
              "--max_memory_usage=#{MEMORY}", '--multiquery']
      executor = JsonBinaryKernelW180Probe.allocate
      before_sha = binary_sha
      stdout, stderr, status, timed_out, spawn_error, stdin_error, stdout_error, stderr_error =
        executor.send(:execute, argv, sql)
      classification = executor.send(:process_classification, status, timed_out, spawn_error,
                                     stdin_error, stdout_error, stderr_error, stderr)
      after_sha = binary_sha
      invocation = save_invocation(id, argv, sql, stdout, stderr, status, timed_out,
                                   spawn_error, stdin_error, stdout_error, stderr_error, classification,
                                   binary_sha_before: before_sha, binary_sha_after: after_sha)
      output = parse_output(stdout)
      pin_matches = output[:pin] == "__W183_PIN__\t#{VERSION}\t#{BUILD}"
      result = {
        id: id, kind: profile[:kind].to_s, status: nil,
        process_classification: classification, runtime_pin_observed: output[:pin],
        runtime_pin_matches: pin_matches, binary_sha_after: after_sha,
        check_output: output[:check], schema_rows: output[:schema], literal_rows: output[:rows],
        schema_matches: output[:schema] == expected_schema(profile),
        literal_rows_match: output[:rows] == expected_rows(profile),
        data_path: output[:data_path], active_parts: output[:parts], invocation: invocation,
      }
      begin
        result[:part] = inspect_part(id, output[:data_path], output[:parts])
      rescue StandardError => error
        result[:part] = {complete: false}
        result[:part_inspection_error] = "#{error.class}: #{error.message}"
      end
      result[:payload_verifications] = verify_payloads(profile, result[:part])
      result[:payloads_match] = result[:payload_verifications].all? { |entry| entry[:status] == 'literal_payload_match' }
      result[:status] = if classification != 'success'
                          classification == 'server_exception' ? 'indeterminate_server_exception' : 'runner_failure'
                        elsif before_sha != SHA256
                          'runtime_binary_hash_mismatch'
                        elsif after_sha != SHA256
                          'runtime_binary_hash_changed'
                        elsif !pin_matches
                          'runtime_pin_mismatch'
                        elsif result[:schema_matches] && result[:literal_rows_match] &&
                              output[:check] == ["all_1_1_0\t1\t"] && result[:part][:complete] && result[:payloads_match]
                          'stock_accepts_and_literal_lanes_match'
                        else
                          'observations_differ_or_part_incomplete'
                        end
      result
    rescue StandardError => error
      {id: id, kind: profile[:kind].to_s, status: 'probe_runner_error',
       runtime_pin_matches: false, runner_error: "#{error.class}: #{error.message}"}
    end

    def profile_sql(profile)
      type = profile[:kind] == :array ? ARRAY_JSON : ROOT_JSON
      values = profile[:rows].map do |row|
        value = if profile[:kind] == :array
                  elements = row[:value].map { |json| "CAST(#{sql_string(json)}, #{sql_string(ROOT_JSON)})" }
                  "CAST([#{elements.join(', ')}], #{sql_string(ARRAY_JSON)})"
                else
                  "CAST(#{sql_string(row[:value])}, #{sql_string(ROOT_JSON)})"
                end
        "(#{row[:id]}, #{value})"
      end.join(",\n")
      row_query = profile[:kind] == :array ?
        "SELECT '__W183_ROW__', toString(pk), toString(length(a)), hex(toJSONString(a)) FROM default.p ORDER BY pk FORMAT TSVRaw;" :
        "SELECT '__W183_ROW__', toString(pk), '-', hex(toJSONString(a)) FROM default.p ORDER BY pk FORMAT TSVRaw;"
      [
        "SELECT '__W183_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
        "CREATE TABLE default.p (pk UInt64, a #{type}) ENGINE=MergeTree ORDER BY pk SETTINGS #{SETTINGS};",
        "INSERT INTO default.p VALUES #{values};",
        "SELECT '__W183_CHECK_BEGIN__' FORMAT TSVRaw;", 'CHECK TABLE default.p FORMAT TSV;',
        "SELECT '__W183_CHECK_END__' FORMAT TSVRaw;",
        "SELECT '__W183_SCHEMA__', name, type FROM system.columns WHERE database='default' AND table='p' ORDER BY position FORMAT TSVRaw;",
        row_query,
        "SELECT '__W183_DATA_PATH__', arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='p' FORMAT TSVRaw;",
        "SELECT '__W183_PART__', name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='p' AND active ORDER BY name FORMAT TSVRaw;",
      ].join("\n") + "\n"
    end

    def sql_string(value)
      "'#{value.to_s.gsub('\\') { '\\\\' }.gsub("'") { "\\'" }}'"
    end

    def expected_schema(profile)
      type = profile[:kind] == :array ? ARRAY_JSON : ROOT_JSON
      ["__W183_SCHEMA__\tpk\tUInt64", "__W183_SCHEMA__\ta\t#{type}"]
    end

    def expected_rows(profile)
      profile[:rows].map do |row|
        value = profile[:kind] == :array ? row[:value].map { |s| JSON.parse(s) } : JSON.parse(row[:value])
        count = profile[:kind] == :array ? row[:value].size.to_s : '-'
        "__W183_ROW__\t#{row[:id]}\t#{count}\t#{JSON.generate(value).b.unpack1('H*').upcase}"
      end
    end

    # These expected lanes come only from the authored SQL literals above.
    # They are deliberately independent of the stock query output and marks.
    def expected_payloads(profile)
      values = profile[:rows].flat_map do |row|
        json_values = profile[:kind] == :array ? row[:value] : [row[:value]]
        json_values.map { |json| JSON.parse(json).fetch('t') }
      end
      lanes = {}
      if profile[:kind] == :array
        lanes['a.size0'] = profile[:rows].map { |row| row[:value].size }.pack('Q<*').b
      end
      lanes['a.t'] = values.pack('C*').b
      lanes
    end

    def verify_payloads(profile, part)
      expected_payloads(profile).map do |logical_name, expected|
        label = "#{profile[:id]}_#{logical_name.tr('.', '_')}_decompress"
        entry = {label: label, logical_stream: logical_name,
                 expected_bytes: expected.bytesize, expected_sha256: Digest::SHA256.hexdigest(expected)}
        begin
          stream = part[:streams].find { |candidate| candidate[:logical_name] == logical_name }
          raise 'selected part stream is unavailable' unless part[:complete] && stream
          input_path = File.join(part[:part_path], stream[:data_file])
          input_size = File.size(input_path)
          raise "compressed input exceeds #{COMPRESSED_INPUT_LIMIT} bytes" if input_size > COMPRESSED_INPUT_LIMIT
          compressed = File.binread(input_path)
          raise 'compressed input changed while being read' unless compressed.bytesize == input_size
          before_sha = binary_sha
          raise 'pinned executable SHA-256 mismatch before compressor' unless before_sha == SHA256
          stdin_filename = "#{label}.stdin.bin"
          write_new(File.join(@root, 'invocations', stdin_filename), compressed)
          argv = [@binary, 'compressor', '--decompress', '--threads=1']
          executor = JsonBinaryKernelW180Probe.allocate
          stdout, stderr, status, timed_out, spawn_error, stdin_error, stdout_error, stderr_error =
            executor.send(:execute, argv, compressed)
          classification = executor.send(:process_classification, status, timed_out, spawn_error,
                                         stdin_error, stdout_error, stderr_error, stderr)
          after_sha = binary_sha
          invocation = save_invocation(label, argv, compressed, stdout, stderr, status, timed_out,
                                       spawn_error, stdin_error, stdout_error, stderr_error, classification,
                                       stdin_filename: stdin_filename, max_memory_usage_bytes: nil,
                                       max_memory_usage_applicable: false, process_kind: 'clickhouse compressor --decompress',
                                       binary_sha_before: before_sha, binary_sha_after: after_sha)
          entry.merge!(input_bytes: compressed.bytesize, input_sha256: Digest::SHA256.hexdigest(compressed),
                       decoded_bytes: stdout.bytesize, decoded_sha256: Digest::SHA256.hexdigest(stdout),
                       process_classification: classification, invocation: invocation)
          entry[:status] = if classification != 'success'
                             classification == 'server_exception' ? 'indeterminate_server_exception' : 'utility_failure'
                           elsif after_sha != SHA256
                             'runtime_binary_hash_changed'
                           elsif stdout == expected
                             'literal_payload_match'
                           else
                             'literal_payload_mismatch'
                           end
        rescue StandardError => error
          entry[:status] = 'verification_runner_error'
          entry[:runner_error] = "#{error.class}: #{error.message}"
        end
        entry
      end
    end

    def parse_output(stdout)
      lines = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      first = lines.index('__W183_CHECK_BEGIN__')
      last = lines.index('__W183_CHECK_END__')
      fields = ->(tag) { lines.map { |line| line.split("\t", -1) if line.start_with?("#{tag}\t") }.compact }
      {
        pin: lines.find { |line| line.start_with?("__W183_PIN__\t") },
        check: first && last && last > first ? lines[(first + 1)...last] : [],
        schema: lines.select { |line| line.start_with?("__W183_SCHEMA__\t") },
        rows: lines.select { |line| line.start_with?("__W183_ROW__\t") },
        data_path: fields.call('__W183_DATA_PATH__').dig(0, 1),
        parts: fields.call('__W183_PART__').map { |f| f.drop(1) },
      }
    end

    def save_invocation(id, argv, input, stdout, stderr, status, timed_out,
                        spawn_error, stdin_error, stdout_error, stderr_error, classification,
                        stdin_filename: nil, max_memory_usage_bytes: MEMORY,
                        max_memory_usage_applicable: true, process_kind: 'clickhouse local',
                        binary_sha_before: nil, binary_sha_after: nil)
      dir = File.join(@root, 'invocations')
      stdin_filename ||= "#{id}.stdin.sql"
      argv_bytes = JSON.pretty_generate(argv) + "\n"
      write_new(File.join(dir, "#{id}.argv.json"), argv_bytes)
      write_new(File.join(dir, "#{id}.stdout"), stdout)
      write_new(File.join(dir, "#{id}.stderr"), stderr)
      record = {
        process_kind: process_kind,
        argv: argv, argv_file: "#{id}.argv.json", argv_sha256: Digest::SHA256.hexdigest(argv_bytes),
        stdin_file: stdin_filename, stdin_bytes: input.bytesize, stdin_sha256: Digest::SHA256.hexdigest(input),
        exit: status&.exitstatus, signal: status&.termsig, timed_out: timed_out,
        timeout_seconds: TIMEOUT, termination_grace_seconds: GRACE,
        max_threads: 1, max_memory_usage_bytes: max_memory_usage_bytes,
        max_memory_usage_applicable: max_memory_usage_applicable,
        required_outer_run_safe_memory_limit_bytes: OUTER_RUN_SAFE_LIMIT,
        binary_sha_before: binary_sha_before, binary_sha_after: binary_sha_after,
        spawn_error: spawn_error, stdin_write_error: stdin_error,
        stdout_read_error: stdout_error, stderr_read_error: stderr_error,
        process_classification: classification,
        stdout_sha256: Digest::SHA256.hexdigest(stdout), stderr_sha256: Digest::SHA256.hexdigest(stderr),
        stdout_file: "#{id}.stdout", stderr_file: "#{id}.stderr", environment_delta: {'TZ' => 'UTC'},
      }
      write_new(File.join(dir, "#{id}.json"), JSON.pretty_generate(record) + "\n")
      @invocations << record
      record
    end

    def inspect_part(id, data_path, parts)
      raise 'expected one active part' unless parts.size == 1 && parts[0].size == 5
      name, raw_path, part_type, rows, marks = parts[0]
      store = File.join(@root, 'stores', id)
      part = within_root!(raw_path)
      data = within_root!(data_path)
      raise 'reported data path escaped this profile store' unless data.start_with?(store + File::SEPARATOR)
      raise 'reported part path escaped this profile store' unless part.start_with?(store + File::SEPARATOR)
      raise 'reported part path escaped the table data path' unless part.start_with?(data + File::SEPARATOR)
      validate_plain_tree!(part)
      substreams = File.binread(File.join(part, 'columns_substreams.txt'))
      count = File.binread(File.join(part, 'count.txt')).strip
      logical = substreams.lines.map do |line|
        next unless line.start_with?("\t")
        line.strip.sub(/\A\*\s*/, '')
      end.compact
      hashes = logical.map { |stream| JsonArrayStorageW183.stream_hash(stream) }
      raise 'duplicate logical substream or hashed stream name' unless logical.uniq == logical && hashes.uniq == hashes
      names = Dir.children(part)
      compressed_marks = names.grep(/mrk/).reject { |entry| entry.end_with?('.mrk2') }
      streams = logical.zip(hashes).map do |stream, hash|
        bin, mark = "#{hash}.bin", "#{hash}.mrk2"
        bin_path, mark_path = File.join(part, bin), File.join(part, mark)
        raise "missing stream pair for #{stream}" unless File.file?(bin_path) && File.file?(mark_path)
        mark_bytes = File.binread(mark_path)
        raise "#{stream}: malformed plain .mrk2 triples" unless (mark_bytes.bytesize % 24).zero?
        {
          logical_name: stream, hashed_stem: hash,
          data_file: bin, data_bytes: File.size(bin_path), data_sha256: Digest::SHA256.file(bin_path).hexdigest,
          data_prefix_hex: (File.binread(bin_path, 32) || ''.b).unpack1('H*'),
          mark_file: mark, mark_bytes: mark_bytes.bytesize,
          mark_sha256: Digest::SHA256.hexdigest(mark_bytes),
          mark_triples: mark_bytes.bytes.each_slice(24).map { |r| r.pack('C*').unpack('Q<Q<Q<') },
        }
      end
      expected = hashes.flat_map { |hash| ["#{hash}.bin", "#{hash}.mrk2"] }.sort
      actual = names.select { |n| n.end_with?('.bin', '.mrk2') }.sort
      # Stock records four real two-row marks plus a zero-row final mark.
      # These are outer table rows, not the JSON element count at a child site.
      outer_names = ['pk']
      outer_names << 'a.size0' if id.start_with?('array_json_')
      outer_grid_matches = outer_names.all? do |stream_name|
        stream = streams.find { |entry| entry[:logical_name] == stream_name }
        stream && stream[:mark_triples].map(&:last) == [2, 2, 2, 2, 0]
      end
      stream_mark_counts_match = streams.all? { |stream| stream[:mark_triples].size == 5 }
      complete = part_type == 'Wide' && rows == '8' && count == '8' &&
        marks == '5' && !logical.empty? && compressed_marks.empty? && actual == expected &&
        outer_grid_matches && stream_mark_counts_match
      observation = {
        part_name: name, part_path: part, part_type: part_type, rows: rows, marks: marks,
        data_path: data, count_text: count, columns_substreams_text: substreams.force_encoding('UTF-8'),
        logical_substreams: logical, physical_file_names: names.sort,
        plain_mrk2_only: compressed_marks.empty?, outer_mark_grid_matches: outer_grid_matches,
        stream_mark_counts_match: stream_mark_counts_match, streams: streams, complete: complete,
      }
      write_new(File.join(@root, 'parts', "#{id}.json"), JSON.pretty_generate(observation) + "\n")
      observation
    end

    def within_root!(path)
      raise 'reported path is absent' unless path && !path.empty?
      full = File.expand_path(path)
      raise "reported path is outside evidence root: #{path}" unless full.start_with?(@root + File::SEPARATOR)
      current = @root
      full.delete_prefix(@root + File::SEPARATOR).split(File::SEPARATOR).each do |component|
        current = File.join(current, component)
        raise "symlink in reported path: #{current}" if File.lstat(current).symlink?
      end
      File.realpath(full)
    end

    def validate_plain_tree!(path)
      Find.find(path) do |entry|
        stat = File.lstat(entry)
        raise "symlink in evidence tree: #{entry}" if stat.symlink?
        raise "non-regular evidence entry: #{entry}" unless stat.directory? || stat.file?
      end
    end

    def write_new(path, bytes)
      raise "refusing overwrite: #{path}" if File.exist?(path) || File.symlink?(path)
      File.open(path, 'wbx', 0o600) { |file| file.write(bytes) }
    end

    def overall_status
      return 'runtime_or_evidence_hash_failure' if @fatal_error || @sha_before != SHA256 || @sha_after != SHA256
      return 'observed_all_profiles' if @profiles.size == PROFILES.size &&
        @profiles.all? { |p| p[:status] == 'stock_accepts_and_literal_lanes_match' }
      'observations_incomplete_or_differ'
    end

    def write_summary
      summary = {
        probe: 'W183 Array(JSON) stock physical-site discriminator',
        discriminator: 'Observe outer-grid marks plus decoded a.size0 and a.t primitive lanes for authored 0/1/2 child occurrences, with leading/trailing all-empty outer marks; compare an all-empty Array(JSON) profile and root JSON typed control.',
        boundary: 'Only the UInt64 array-size and UInt8 typed-leaf streams are decompressed and matched to authored literals. Object structure/shared-data streams remain compressed-file inventories; mark third fields are recorded, not interpreted as child counts. ClickHouse errors are not semantic rejection. No claim of Crystal reader support.',
        runtime: {path: @binary, expected_sha256: SHA256, sha256_before: @sha_before, sha256_after: @sha_after,
                  expected_version: VERSION, expected_build: BUILD},
        limits: {max_threads: 1, local_max_memory_usage_bytes: MEMORY, compressor_max_memory_usage_bytes: nil,
                 compressor_memory_limit_applicable: false, compressed_input_limit_bytes: COMPRESSED_INPUT_LIMIT,
                 required_outer_run_safe_memory_limit_bytes: OUTER_RUN_SAFE_LIMIT, timeout_seconds: TIMEOUT, grace_seconds: GRACE,
                 executor: 'JsonBinaryKernelW180Probe#execute; requiring W180 does not run its CLI'},
        settings: SETTINGS, evidence_root: @root, status: overall_status,
        fatal_error: @fatal_error, profiles: @profiles, invocations: @invocations,
      }
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      lines = ['# W183 Array(JSON) stock probe', '', "Status: `#{summary[:status]}`", '', summary[:discriminator], '', summary[:boundary], '',
               "Runtime: #{VERSION} / #{BUILD} / SHA256 `#{@sha_before}`", '',
               '| Profile | Status | Schema | Rows | Part complete | Primitive lanes |', '|---|---|---:|---:|---:|---:|']
      @profiles.each do |p|
        lines << "| #{p[:id]} | #{p[:status]} | #{p[:schema_matches]} | #{p[:literal_rows_match]} | #{p.dig(:part, :complete)} | #{p[:payloads_match]} |"
      end
      lines << '' << 'Exact argv/stdin/stdout/stderr, hashes, schema/rows/CHECK output, count, substreams, stream inventories/raw .mrk2 triples, and decoded primitive-lane evidence are retained under this evidence root.' << ''
      write_new(File.join(@root, 'summary.md'), lines.join("\n"))
    end
  end

  MASK = (1 << 64) - 1
  def self.rotl(x, n)
    ((x << n) | (x >> (64 - n))) & MASK
  end
  def self.round(v0, v1, v2, v3)
    a = (v0 + v1) & MASK; b = rotl(v1, 13) ^ a; a = rotl(a, 32)
    c = (v2 + v3) & MASK; d = rotl(v3, 16) ^ c
    a = (a + d) & MASK; d = rotl(d, 21) ^ a; c = (c + b) & MASK
    b = rotl(b, 17) ^ c; c = rotl(c, 32)
    [a, b, c, d]
  end
  def self.stream_hash(name)
    bytes = name.to_s.b
    v = [0x736f6d6570736575, 0x646f72616e646f6d, 0x6c7967656e657261, 0x7465646279746573]
    i = 0
    while i + 8 <= bytes.bytesize
      word = bytes.byteslice(i, 8).unpack1('Q<'); v[3] ^= word
      2.times { v = round(*v) }; v[0] ^= word; i += 8
    end
    word = (bytes.bytesize & 0xff) << 56
    bytes.byteslice(i..).to_s.bytes.each_with_index { |byte, j| word |= byte << (j * 8) }
    v[3] ^= word; 2.times { v = round(*v) }; v[0] ^= word; v[2] ^= 0xff
    4.times { v = round(*v) }
    [v[2] ^ v[3], v[0] ^ v[1]].map { |x| (x & MASK).to_s(16).rjust(16, '0') }.join
  end
  raise 'W183 stream hash self-test failed' unless stream_hash('pk') == 'fcc8daf1be9ac27649fa2186ad926aea'
end

def main
  options = {binary: JsonArrayStorageW183::BINARY}
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/probe_json_array_storage_w183.rb --evidence-root EMPTY_CHILD_OF_PRIVATE_TMP [--clickhouse PATH]'
    parser.on('--clickhouse PATH') { |value| options[:binary] = value }
    parser.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
  end.parse!
  exit(JsonArrayStorageW183::Probe.new(options[:binary], options[:evidence_root]).run ? 0 : 1)
rescue StandardError => error
  warn "W183 probe failed: #{error.class}: #{error.message}"
  exit 1
end

main if $PROGRAM_NAME == __FILE__
