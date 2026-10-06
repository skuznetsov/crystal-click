#!/usr/bin/env ruby
# Root-run, stock-only capture for Object V3 ADVANCED/ADVANCED_CHUNKED shared
# layouts. This records observed bytes; it does not qualify Crystal support.

require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require_relative 'check_array_json_parts_w185'
require_relative 'check_object_shared_buckets_w190'
require_relative 'object_shared_advanced_layout_w191'
require_relative 'stock_part_probe_support_w191'

module ProbeObjectSharedAdvancedW191
  Layout = ObjectSharedAdvancedLayoutW191
  Binary = CheckArrayJSONPartsW185::BINARY.freeze
  BinarySHA256 = CheckArrayJSONPartsW185::BINARY_SHA256.freeze
  Version = CheckArrayJSONPartsW185::VERSION.freeze
  Build = CheckArrayJSONPartsW185::BUILD.freeze
  Memory = CheckArrayJSONPartsW185::MEMORY
  Timeout = CheckArrayJSONPartsW185::TIMEOUT
  Grace = CheckArrayJSONPartsW185::GRACE
  OuterRunSafeLimit = CheckArrayJSONPartsW185::OUTER_RUN_SAFE_LIMIT
  CompressedLimit = 65_536
  DecodedLimit = 1_048_576
  MarkRows = [2, 2, 2, 2, 0].freeze
  RootType = CheckArrayJSONPartsW185::ROOT_JSON.freeze
  ArrayType = CheckArrayJSONPartsW185::ARRAY_JSON.freeze
  Hashes = CheckObjectSharedBucketsW190::KeyHashes

  ROOT_ROWS = [
    {'t' => 1, 'alpha' => 'r-alpha-1'},
    {'t' => 2, 'aa' => 'r-aa-2', 'beta' => 'r-beta-2'},
    {'t' => 3, 'beta' => 'r-beta-3'},
    {'t' => 4, 'alpha' => 'r-alpha-4', 'aa' => 'r-aa-4'},
    {'t' => 5, 'aa' => 'r-aa-5', 'beta' => 'r-beta-5'},
    {'t' => 6, 'alpha' => 'r-alpha-6'},
    {'t' => 7, 'beta' => 'r-beta-7'},
    {'t' => 8, 'alpha' => 'r-alpha-8', 'aa' => 'r-aa-8', 'beta' => 'r-beta-8'},
  ].freeze

  ARRAY_ROWS = [
    [], [], [], [{'t' => 41, 'alpha' => 'a-alpha-41'}],
    [{'t' => 51, 'aa' => 'a-aa-51'}, {'t' => 52, 'beta' => 'a-beta-52'}],
    [{'t' => 61, 'alpha' => 'a-alpha-61', 'beta' => 'a-beta-61'}], [], [],
  ].freeze
  EMPTY_ROOT_ROWS = (1..8).map { |value| {'t' => value} }.freeze
  EMPTY_ARRAY_ROWS = Array.new(8) { [] }.freeze

  Profiles = [
    {id: 'root_advanced_v2', kind: :root, mode: 'advanced', expected_buckets: 2, rows: ROOT_ROWS},
    {id: 'root_advanced_chunked_v3', kind: :root, mode: 'advanced_chunked', expected_buckets: 2, rows: ROOT_ROWS},
    {id: 'array_advanced_v2', kind: :array, mode: 'advanced', expected_buckets: 2, rows: ARRAY_ROWS},
    {id: 'array_advanced_chunked_v3', kind: :array, mode: 'advanced_chunked', expected_buckets: 2, rows: ARRAY_ROWS},
    {id: 'empty_root_advanced_v2', kind: :root, mode: 'advanced', expected_buckets: 1, rows: EMPTY_ROOT_ROWS},
    {id: 'empty_root_advanced_chunked_v3', kind: :root, mode: 'advanced_chunked', expected_buckets: 1, rows: EMPTY_ROOT_ROWS},
    {id: 'empty_array_advanced_v2', kind: :array, mode: 'advanced', expected_buckets: 1, rows: EMPTY_ARRAY_ROWS},
    {id: 'empty_array_advanced_chunked_v3', kind: :array, mode: 'advanced_chunked', expected_buckets: 1, rows: EMPTY_ARRAY_ROWS},
  ].freeze

  class Probe
    def initialize(binary, evidence_root)
      @binary = File.expand_path(binary)
      @root = File.expand_path(evidence_root)
      @base = StockPartProbeSupportW191.new(binary, evidence_root)
      @advanced_parser = CheckObjectSharedBucketsW190::Probe.allocate
      @invocations = []
      @profiles = []
      @fatal_error = nil
    end

    def run
      validate_root!
      %w[invocations stores raw_streams].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
      @sha_before = binary_sha
      fail!('pinned ClickHouse executable SHA-256 mismatch before capture') unless @sha_before == BinarySHA256

      Profiles.each do |profile|
        if binary_sha != BinarySHA256
          @profiles << {id: profile.fetch(:id), status: 'skipped_after_binary_pin_mismatch'}
          next
        end
        @profiles << run_profile(profile)
      end

      @sha_after = binary_sha
      validate_evidence!
      status = @profiles.all? { |profile| profile[:status] == 'stock_profile_observed' } ?
        'all_stock_profiles_observed' : 'capture_incomplete_or_observations_differ'
      write_summary(status: status)
      puts "W191 status=#{status}; profiles=#{@profiles.count { |p| p[:status] == 'stock_profile_observed' }}/#{Profiles.size}; evidence=#{@root}"
      status == 'all_stock_profiles_observed'
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @sha_after = binary_sha rescue nil
      write_summary(status: 'runner_failure_or_observations_differ', fatal_error: @fatal_error) rescue nil
      warn "W191 stock capture failed: #{@fatal_error}"
      false
    end

    private

    def fail!(message)
      raise RuntimeError, "W191 shared ADVANCED capture: #{message}"
    end

    def validate_root!
      parent = File.realpath('/private/tmp')
      fail!('evidence root must be a direct child of /private/tmp') unless File.dirname(@root) == parent
      fail!('evidence root must not be a symlink') if File.symlink?(@root)
      fail!('evidence root must already exist, be canonical, and be empty') unless
        File.directory?(@root) && File.realpath(@root) == @root && Dir.children(@root).empty?
    rescue Errno::ENOENT
      fail!('evidence root must already exist')
    end

    def binary_sha
      fail!('pinned ClickHouse executable is missing, non-executable, or symlinked') unless
        File.file?(@binary) && File.executable?(@binary) && !File.symlink?(@binary)
      Digest::SHA256.file(@binary).hexdigest
    end

    def run_profile(profile)
      id = profile.fetch(:id)
      Dir.mkdir(File.join(@root, 'raw_streams', id), 0o700)
      store = File.join(@root, 'stores', 'native', id)
      Dir.mkdir(store, 0o700)
      label = "stock_#{id}"
      sql = profile_sql(profile)
      invocation = execute_captured(label, local_argv(store), sql.b, 'clickhouse local', memory_applicable: true)
      @base.send(:assert_native_invocation!, invocation)
      assert_pin!(invocation[:stdout])
      native = @base.send(:parse_native, invocation[:stdout])
      part = assert_native_profile!(native, profile)
      inventory = @base.send(:inspect_part, id, part.fetch(:path), part)
      fail!("#{id}: physical MRK2 row field is not the parent-mark grid") unless
        inventory.fetch(:mark_triples).values.all? { |triples| triples.map { |triple| triple[2] } == MarkRows }

      streams, decoded = capture_streams(id, inventory)
      hashes = parse_hashes(invocation.fetch(:stdout))
      fail!("#{id} SipHash vectors differ: #{hashes.inspect}") unless hashes == Hashes
      physical = inspect_profile_layout!(id, profile, native, inventory, streams, decoded, hashes)
      {
        id: id, status: 'stock_profile_observed', kind: profile.fetch(:kind).to_s,
        requested_shared_version: profile.fetch(:mode), configured_bucket_count: 2,
        expected_actual_bucket_count: profile.fetch(:expected_buckets),
        stock_schema: native.fetch(:schemas), stock_check: native.fetch(:checks),
        authored_literal_rows: expected_rows(profile), part: inventory,
        stream_captures: streams, physical_layout: physical,
        native_invocation: invocation_record(invocation),
      }
    rescue StandardError => error
      {id: id, status: 'runner_failure_or_observations_differ', error: "#{error.class}: #{error.message}"}
    end

    def local_argv(store)
      [@binary, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
       "--max_memory_usage=#{Memory}", '--multiquery']
    end

    def execute_captured(label, argv, input, process_kind, memory_applicable:)
      before = binary_sha
      fail!('pinned ClickHouse executable SHA-256 mismatch before subprocess') unless before == BinarySHA256
      stdin_file = process_kind == 'clickhouse local' ? "#{label}.stdin.sql" : "#{label}.stdin.bin"
      base = File.join(@root, 'invocations', label)
      @base.send(:write_new, "#{base}.#{process_kind == 'clickhouse local' ? 'stdin.sql' : 'stdin.bin'}", input)
      executor = JsonBinaryKernelW180Probe.allocate
      stdout, stderr, status, timed_out, spawn_error, stdin_error, stdout_error, stderr_error =
        executor.send(:execute, argv, input)
      classification = executor.send(:process_classification, status, timed_out, spawn_error,
                                     stdin_error, stdout_error, stderr_error, stderr)
      after = binary_sha
      argv_bytes = JSON.pretty_generate(argv) + "\n"
      record = {
        label: label, process_kind: process_kind, argv: argv, argv_file: "#{label}.argv.json",
        argv_sha256: Digest::SHA256.hexdigest(argv_bytes), stdin_file: stdin_file,
        stdin_bytes: input.bytesize, stdin_sha256: Digest::SHA256.hexdigest(input),
        exit: status&.exitstatus, signal: status&.termsig, timed_out: timed_out,
        timeout_seconds: Timeout, termination_grace_seconds: Grace, max_threads: 1,
        max_memory_usage_bytes: memory_applicable ? Memory : nil,
        max_memory_usage_applicable: memory_applicable,
        required_outer_run_safe_memory_limit_bytes: OuterRunSafeLimit,
        expected_binary_sha256: BinarySHA256, binary_sha_before: before, binary_sha_after: after,
        spawn_error: spawn_error, stdin_write_error: stdin_error,
        stdout_read_error: stdout_error, stderr_read_error: stderr_error,
        process_classification: classification,
        stdout_bytes: stdout.bytesize, stdout_sha256: Digest::SHA256.hexdigest(stdout),
        stderr_bytes: stderr.bytesize, stderr_sha256: Digest::SHA256.hexdigest(stderr),
        stdout_file: "#{label}.stdout", stderr_file: "#{label}.stderr",
      }
      @base.send(:write_new, "#{base}.argv.json", argv_bytes)
      @base.send(:write_new, "#{base}.stdout", stdout)
      @base.send(:write_new, "#{base}.stderr", stderr)
      @base.send(:write_new, "#{base}.json", JSON.pretty_generate(record) + "\n")
      @invocations << record
      fail!('pinned ClickHouse executable SHA-256 changed during subprocess') unless after == BinarySHA256
      {stdout: stdout, stderr: stderr, status: status, classification: classification, record: record}
    end

    def invocation_record(invocation)
      invocation.fetch(:record)
    end

    def assert_pin!(stdout)
      expected = "__W191_PIN__\t#{Version}\t#{Build}"
      line = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp).find { |item| item.start_with?("__W191_PIN__\t") }
      fail!("runtime pin mismatch: #{line.inspect}") unless line == expected
    end

    def settings(profile)
      base = CheckArrayJSONPartsW185::SETTINGS.split(', ').reject do |setting|
        setting.start_with?('object_shared_data_serialization_version_for_zero_level_parts=')
      end
      base.concat([
        "object_shared_data_serialization_version='#{profile.fetch(:mode)}'",
        "object_shared_data_serialization_version_for_zero_level_parts='#{profile.fetch(:mode)}'",
        'object_shared_data_buckets_for_wide_part=2',
      ])
      base << 'object_shared_data_target_chunk_rows=1' if profile.fetch(:mode) == 'advanced_chunked'
      base.join(', ')
    end

    def profile_sql(profile)
      column = profile.fetch(:kind) == :array ? 'a' : 'j'
      type = profile.fetch(:kind) == :array ? ArrayType : RootType
      inserts = profile.fetch(:rows).each_with_index.map do |value, index|
        document = if profile.fetch(:kind) == :array
                     inner = value.map { |item| "CAST(#{sql_string(JSON.generate(item))}, #{sql_string(RootType)})" }
                     "CAST([#{inner.join(',')}], #{sql_string(ArrayType)})"
                   else
                     "CAST(#{sql_string(JSON.generate(value))}, #{sql_string(RootType)})"
                   end
        "(#{index + 1}, #{document})"
      end
      row_length = profile.fetch(:kind) == :array ? "toString(length(#{column}))" : "'-'"
      [
        "SELECT '__W191_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
        "CREATE TABLE default.p (pk UInt64, #{column} #{type}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings(profile)};",
        "INSERT INTO default.p VALUES #{inserts.join(',')};",
        "SELECT '__W185_CHECK_BEGIN__', 'p' FORMAT TSVRaw;", 'CHECK TABLE default.p FORMAT TSV;',
        "SELECT '__W185_CHECK_END__', 'p' FORMAT TSVRaw;",
        "SELECT '__W185_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table='p' ORDER BY position FORMAT TSVRaw;",
        "SELECT '__W185_ROW__', 'p', toString(pk), #{row_length}, hex(toJSONString(#{column})) FROM default.p ORDER BY pk FORMAT TSVRaw;",
        "SELECT '__W185_MIDDLE_ROW__', 'p', toString(pk), #{row_length}, hex(toJSONString(#{column})) FROM default.p WHERE pk BETWEEN 3 AND 6 ORDER BY pk FORMAT TSVRaw;",
        "SELECT '__W185_DATA_PATH__', name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='p' FORMAT TSVRaw;",
        "SELECT '__W185_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='p' AND active ORDER BY name FORMAT TSVRaw;",
        "SELECT '__W191_HASH__', #{sql_string(Hashes.keys.first)}, toString(sipHash64(#{sql_string(Hashes.keys.first)})) FORMAT TSVRaw;",
        "SELECT '__W191_HASH__', #{sql_string(Hashes.keys.to_a[1])}, toString(sipHash64(#{sql_string(Hashes.keys.to_a[1])})) FORMAT TSVRaw;",
        "SELECT '__W191_HASH__', #{sql_string(Hashes.keys.to_a[2])}, toString(sipHash64(#{sql_string(Hashes.keys.to_a[2])})) FORMAT TSVRaw;",
      ].join("\n") + "\n"
    end

    def sql_string(value)
      @base.send(:sql_string, value)
    end

    def expected_rows(profile)
      profile.fetch(:rows).each_with_index.map do |value, index|
        logical = profile.fetch(:kind) == :array ? value : value
        [index + 1, profile.fetch(:kind) == :array ? value.size.to_s : '-', logical]
      end
    end

    def assert_native_profile!(native, profile)
      fail!("#{profile[:id]} CHECK differs: #{native[:checks].inspect}") unless native[:checks] == {'p' => ["all_1_1_0\t1\t"]}
      column = profile.fetch(:kind) == :array ? 'a' : 'j'
      type = profile.fetch(:kind) == :array ? ArrayType : RootType
      expected_schema = [['p', 'pk', 'UInt64'], ['p', column, type]]
      fail!("#{profile[:id]} schema differs: #{native[:schemas].inspect}") unless native[:schemas] == expected_schema
      expected = expected_rows(profile).map do |pk, length, row|
        ['p', pk.to_s, length, row]
      end
      decode_literal_rows!(native.fetch(:rows), "#{profile[:id]} full rows", expected)
      decode_literal_rows!(native.fetch(:middle_rows), "#{profile[:id]} middle rows", expected[2, 4])
      part = native.fetch(:parts)['p'] || fail!("#{profile[:id]} has no active part")
      fail!("#{profile[:id]} is not a single expected Wide part: #{part.inspect}") unless
        part.values_at(:name, :part_type, :rows, :marks) == ['all_1_1_0', 'Wide', '8', '5']
      fail!("#{profile[:id]} data path missing") unless native.fetch(:data_paths).key?('p')
      part
    end

    def decode_literal_rows!(records, label, expected)
      actual = records.map do |row|
        [row[0], row[1], row[2], JSON.parse([row[3]].pack('H*'))]
      rescue JSON::ParserError
        fail!("#{label}: invalid JSON hex")
      end
      fail!("#{label} differ: #{actual.inspect}") unless actual == expected
    end

    def capture_streams(id, inventory)
      decoded = {}
      captures = {}
      inventory.fetch(:logical_substreams).sort.each do |logical_name|
        stem = JsonArrayStorageW183.stream_hash(logical_name)
        filename = "#{stem}.bin"
        info = inventory.fetch(:stream_file_inventory).fetch(filename)
        input_path = File.join(inventory.fetch(:part_path), filename)
        compressed_size = File.size(input_path)
        fail!("#{id} #{logical_name} compressed input exceeds #{CompressedLimit}") if compressed_size > CompressedLimit
        compressed = File.binread(input_path)
        fail!("#{id} #{logical_name} input changed while reading") unless compressed.bytesize == compressed_size
        frames = if compressed.empty?
                   {spans: [], decoded_size: 0}
                 else
                   @advanced_parser.send(:compressed_frame_spans!, compressed, "#{id} #{logical_name}")
                 end
        output = if compressed.empty?
                   ''.b
                 else
                   label = "decompress_#{id}_#{stem}"
                   utility = execute_captured(label,
                     [@binary, 'compressor', '--decompress', '--threads=1'], compressed,
                     'clickhouse compressor --decompress', memory_applicable: false)
                   fail!("#{id} #{logical_name} decompressor failed; not a format rejection") unless successful?(utility)
                   fail!("#{id} #{logical_name} decompressor wrote stderr") unless utility[:stderr].empty?
                   utility[:stdout]
                 end
        fail!("#{id} #{logical_name} decoded output exceeds #{DecodedLimit}") if output.bytesize > DecodedLimit
        fail!("#{id} #{logical_name} decoded length differs from independent LZ4 frame walk") unless output.bytesize == frames.fetch(:decoded_size)
        decoded[logical_name] = output
        @base.send(:write_new, File.join(@root, 'raw_streams', id, "#{stem}.decoded.bin"), output)
        triples = inventory.fetch(:mark_triples).fetch(logical_name)
        normalized = triples.map do |compressed_offset, in_block_offset, rows|
          decoded_offset = Layout.decode_coordinate([compressed_offset, in_block_offset],
            frames.fetch(:spans), compressed.bytesize, output.bytesize, "#{id} #{logical_name} .mrk2")
          {compressed_offset: compressed_offset, in_block_offset: in_block_offset,
           decoded_offset: decoded_offset, physical_rows: rows}
        end
        fail!("#{id} #{logical_name} normalized marks move backwards") unless
          normalized.each_cons(2).all? { |left, right| right.fetch(:decoded_offset) >= left.fetch(:decoded_offset) }
        captures[logical_name] = {
          hashed_file: filename, compressed_bytes: compressed_size,
          compressed_sha256: info.fetch(:sha256), frames: frames.fetch(:spans),
          decoded_bytes: output.bytesize, decoded_sha256: Digest::SHA256.hexdigest(output),
          empty_no_frame: compressed.empty?, mrk2: normalized,
          decompressor_invocation: compressed.empty? ? nil : "decompress_#{id}_#{stem}",
        }
      end
      [captures, decoded]
    end

    def successful?(invocation)
      invocation[:classification] == 'success' && invocation[:status]&.success? && invocation[:status]&.termsig.nil?
    end

    def inspect_profile_layout!(id, profile, native, inventory, captures, decoded, hashes)
      column = profile.fetch(:kind) == :array ? 'a' : 'j'
      structure_name = "#{column}.object_structure"
      structure_bytes = decoded[structure_name] || fail!("#{id} lacks #{structure_name}")
      object_structure = @advanced_parser.send(:parse_structure_prefix!, structure_bytes, "#{id} #{structure_name}")
      fail!("#{id} Object wire version differs") unless object_structure.fetch(:version) == 4
      shared_version = profile.fetch(:mode) == 'advanced' ? 2 : 3
      fail!("#{id} shared mode differs: #{object_structure.inspect}") unless object_structure.fetch(:shared_data_version) == shared_version
      fail!("#{id} actual bucket count differs: #{object_structure.fetch(:bucket_count)}") unless
        object_structure.fetch(:bucket_count) == profile.fetch(:expected_buckets)

      array_sizes = nil
      child_counts = nil
      if profile.fetch(:kind) == :array
        size_name = 'a.size0'
        size_bytes = decoded[size_name] || fail!("#{id} lacks outer Array size stream")
        array_sizes = Layout.decode_sizes(size_bytes, "#{id} #{size_name}")
        expected_sizes = profile.fetch(:rows).map(&:size)
        fail!("#{id} Array outer per-row sizes differ from authored rows: #{array_sizes.inspect}") unless array_sizes == expected_sizes
        child_counts = array_sizes
        fail!("#{id} child schedule differs from independent size0 decode") unless child_counts == profile.fetch(:rows).map(&:size)
      end

      docs = profile.fetch(:kind) == :array ? profile.fetch(:rows).flatten(1) : profile.fetch(:rows)
      chunk_layout = parse_bucket_layout!(id, profile, column, inventory, decoded, docs, hashes, array_sizes)
      copy = parse_copy_lanes!(id, profile, column, decoded, chunk_layout, docs, hashes)
      {
        object_structure: object_structure,
        object_structure_bytes_hex: structure_bytes.unpack('H*').first,
        actual_shared_bucket_count: object_structure.fetch(:bucket_count),
        array_size0_per_parent_row_counts: array_sizes,
        array_child_occurrences_per_parent: child_counts,
        array_child_occurrences_per_outer_mark: child_counts && child_counts.each_slice(2).map(&:sum),
        chunk_layout: chunk_layout, whole_shared_copy: copy,
        layout_boundary: 'Raw per-path data/substream bytes are decompressed and inventoried; this probe does not decode each nested typed path stream or establish library reader support.',
      }
    end

    def parse_bucket_layout!(id, profile, column, inventory, decoded, docs, hashes, array_sizes)
      bucket_prefix = "#{column}.object_shared_data."
      bucket_ids = inventory.fetch(:logical_substreams).map do |name|
        match = /\A#{Regexp.escape(bucket_prefix)}([0-9]+)\./.match(name)
        match && Integer(match[1], 10)
      end.compact.uniq.sort
      expected_ids = (0...profile.fetch(:expected_buckets)).to_a
      has_shared_values = docs.any? { |doc| doc.keys.any? { |key| key != 't' } }
      if has_shared_values
        fail!("#{id} shared bucket IDs differ: #{bucket_ids.inspect}") unless bucket_ids == expected_ids
      end
      buckets = {}
      bucket_ids.each do |bucket|
        base = "#{bucket_prefix}#{bucket}"
        combined_name = "#{base}.structure"
        prefix_name = "#{base}.structure_prefix"
        suffix_name = "#{base}.structure_suffix"
        if decoded.key?(combined_name)
          fail!("#{id} bucket #{bucket} mixes combined and split structure records") if decoded.key?(prefix_name) || decoded.key?(suffix_name)
          records = Layout.parse_combined_structure(decoded.fetch(combined_name), "#{id} bucket #{bucket} structure")
        elsif decoded.key?(prefix_name)
          records = Layout.parse_chunk_prefixes(decoded.fetch(prefix_name), "#{id} bucket #{bucket} structure prefix")
          suffixes = decoded[suffix_name] || ''.b
          suffix_records = Layout.parse_suffix_stream(suffixes, records.size, "#{id} bucket #{bucket} structure suffix")
          records.each_with_index do |record, index|
            suffix_record = suffix_records[index]
            prefix = [record.fetch(:prefix_bytes_hex)].pack('H*')
            suffix = [suffix_record.fetch(:suffix_bytes_hex)].pack('H*')
            record[:suffix_bytes_hex] = suffix_record.fetch(:suffix_bytes_hex)
            record[:record_bytes_hex] = (prefix + suffix).unpack('H*').first
            record[:transport_pairs] = suffix_record.fetch(:transport_pairs)
          end
        else
          records = []
        end
        buckets[bucket.to_s] = {structure_streams: [combined_name, prefix_name, suffix_name].select { |name| decoded.key?(name) }, chunks: records}
      end
      nonempty = buckets.values.map { |bucket| bucket.fetch(:chunks) }
      schedules = nonempty.map { |records| records.map { |record| record.fetch(:rows) } }
      fail!("#{id} per-bucket chunk row schedules differ: #{schedules.inspect}") unless schedules.uniq.size <= 1
      records = nonempty.first || []
      logical_row_count = docs.size
      if has_shared_values
        fail!("#{id} shared chunk rows do not cover logical JSON occurrences: #{records.sum { |record| record.fetch(:rows) }} != #{logical_row_count}") unless records.sum { |record| record.fetch(:rows) } == logical_row_count
        expected_schedule = Layout.expected_chunk_row_schedule(profile, array_sizes)
        observed_schedule = records.map { |record| record.fetch(:rows) }
        fail!("#{id} shared chunk rows do not match independently derived parent-mark child schedule: #{observed_schedule.inspect} != #{expected_schedule.inspect}") unless observed_schedule == expected_schedule
      end
      expected_membership = {}
      if has_shared_values
        docs.flat_map { |doc| doc.keys.reject { |key| key == 't' } }.uniq.each do |key|
          expected_membership[key] = {hash: hashes.fetch(key), bucket: hashes.fetch(key) % profile.fetch(:expected_buckets)}
        end
      end
      {bucket_ids: bucket_ids, chunks_per_bucket: buckets.transform_values { |bucket| bucket.fetch(:chunks).map { |record| record.fetch(:rows) } },
       expected_hash_bucket_placement: expected_membership, buckets: buckets}
    end

    def parse_copy_lanes!(id, profile, column, decoded, chunk_layout, docs, hashes)
      prefix = "#{column}.object_shared_data.copy."
      size_name = "#{prefix}sizes"
      indexes_name = "#{prefix}paths_indexes"
      values_name = "#{prefix}values"
      sizes = decoded.key?(size_name) ? Layout.decode_sizes(decoded.fetch(size_name), "#{id} #{size_name}") : []
      indexes_bytes = decoded.fetch(indexes_name, ''.b)
      values_bytes = decoded.fetch(values_name, ''.b)
      total = 0
      expected_pairs_by_doc = docs.map do |doc|
        pairs = doc.reject { |key, _value| key == 't' }.map { |key, value| [key, value] }
        total += pairs.size
        pairs
      end
      expected_sizes = expected_pairs_by_doc.map(&:size)
      if !sizes.empty? || expected_sizes.any?(&:positive?)
        fail!("#{id} copy per-row sizes differ from authored shared values: #{sizes.inspect} != #{expected_sizes.inspect}") unless sizes == expected_sizes
      end
      records = chunk_layout.fetch(:buckets).values.first&.fetch(:chunks) || []
      values = Layout.parse_dynamic_string_envelopes(values_bytes, "#{id} #{values_name}")
      doc_cursor = 0
      index_cursor = 0
      value_cursor = 0
      index_byte_cursor = 0
      value_byte_cursor = 0
      actual_pairs = []
      chunk_reports = []
      records.each_with_index do |record, chunk_index|
        rows = record.fetch(:rows)
        chunk_docs = docs[doc_cursor, rows] || []
        doc_cursor += rows
        dictionary_by_bucket = chunk_layout.fetch(:buckets).to_h do |bucket_id, bucket|
          [Integer(bucket_id, 10), bucket.fetch(:chunks)[chunk_index].fetch(:paths)]
        end
        dictionary = dictionary_by_bucket.sort_by { |bucket_id, _paths| bucket_id }.flat_map(&:last)
        fail!("#{id} chunk #{chunk_index} duplicate combined path dictionary") unless dictionary.uniq == dictionary
        chunk_paths = chunk_docs.flat_map { |doc| doc.keys.reject { |key| key == 't' } }.uniq
        profile.fetch(:expected_buckets).times do |bucket_id|
          expected_paths = chunk_paths.select do |path|
            hashes.fetch(path) % profile.fetch(:expected_buckets) == bucket_id
          end.sort
          actual_paths = dictionary_by_bucket.fetch(bucket_id, [])
          fail!("#{id} chunk #{chunk_index} bucket #{bucket_id} path roster differs: #{actual_paths.inspect} != #{expected_paths.inspect}") unless actual_paths == expected_paths
        end

        entry_count = chunk_docs.sum { |doc| doc.keys.count { |key| key != 't' } }
        chunk_index_byte_start = index_byte_cursor
        index_chunk = Layout.decode_index_chunk(indexes_bytes, index_byte_cursor, entry_count, dictionary.size,
                                                "#{id} chunk #{chunk_index} indexes")
        width = index_chunk.fetch(:width)
        chunk_indexes_bytes = index_chunk.fetch(:bytes)
        chunk_values = values[value_cursor, entry_count] || []
        fail!("#{id} chunk #{chunk_index} copy index/value counts differ") unless chunk_values.size == entry_count
        chunk_value_byte_start = value_byte_cursor
        unless chunk_values.empty?
          fail!("#{id} chunk #{chunk_index} value byte range is discontinuous") unless
            chunk_values.first.fetch(:byte_start) == value_byte_cursor
          value_byte_cursor = chunk_values.last.fetch(:byte_end)
        end
        fail!("#{id} chunk #{chunk_index} value byte range exceeds decoded stream") if value_byte_cursor > values_bytes.bytesize
        chunk_indexes = index_chunk.fetch(:indexes)
        resolved = Layout.resolve_copy_indexes(chunk_indexes, chunk_values, dictionary,
                                               "#{id} chunk #{chunk_index} indexes")

        pair_cursor = 0
        doc_pairs = []
        chunk_docs.each_with_index do |_doc, row_index|
          expected_pairs = expected_pairs_by_doc[doc_cursor - rows + doc_pairs.size]
          count = expected_pairs.size
          actual = resolved[pair_cursor, count].to_a.map { |pair| [pair.fetch(:path), pair.fetch(:value_bytes)] }
          fail!("#{id} chunk #{chunk_index} row #{row_index} copy values differ") unless sort_pairs(actual) == sort_pairs(expected_pairs)
          doc_pairs << actual
          actual_pairs.concat(actual)
          pair_cursor += count
        end
        fail!("#{id} chunk #{chunk_index} has copy entries not assigned to a parent JSON row") unless pair_cursor == resolved.size
        chunk_reports << {
          chunk_index: chunk_index, rows: rows, per_bucket_paths: dictionary_by_bucket,
          combined_dictionary_order: dictionary, index_width_bytes: width,
          index_byte_range: [chunk_index_byte_start, index_chunk.fetch(:next_byte_offset)],
          value_byte_range: [chunk_value_byte_start, value_byte_cursor],
          index_bytes_hex: chunk_indexes_bytes.unpack('H*').first,
          indexes: chunk_indexes,
          resolved_key_value_pairs: resolved.map do |pair|
            {path: pair.fetch(:path), value_bytes_hex: pair.fetch(:value_bytes).unpack('H*').first}
          end,
        }
        index_cursor += entry_count
        value_cursor += entry_count
        index_byte_cursor = index_chunk.fetch(:next_byte_offset)
      end
      fail!("#{id} copy structure rows do not cover all authored docs") if total.positive? && doc_cursor != docs.size
      fail!("#{id} copy indexes have trailing bytes") unless index_byte_cursor == indexes_bytes.bytesize
      fail!("#{id} copy values have trailing bytes") unless value_byte_cursor == values_bytes.bytesize
      fail!("#{id} copy index total differs from authored shared values") unless index_cursor == total
      fail!("#{id} copy value envelopes have trailing entries") unless value_cursor == values.size
      fail!("#{id} copy values have unreferenced envelopes") unless values.size == total
      fail!("#{id} whole-shared copy value total differs") unless actual_pairs.size == total
      {
        size_lane_present: decoded.key?(size_name), per_row_sizes: sizes,
        indexes_lane_present: decoded.key?(indexes_name), index_bytes: indexes_bytes.bytesize,
        values_lane_present: decoded.key?(values_name), value_envelopes: values.map do |value|
          {type_tag: value.fetch(:type_tag), value_bytes_hex: value.fetch(:value_bytes).unpack('H*').first,
           byte_range: [value.fetch(:byte_start), value.fetch(:byte_end)],
           dynamic_bytes_hex: value.fetch(:dynamic_bytes_hex),
           raw_bytes_hex: value.fetch(:raw_bytes_hex)}
        end,
        chunks: chunk_reports,
      }
    end

    def sort_pairs(pairs)
      pairs.map { |key, value| [key.to_s, value.to_s.b.unpack('H*').first] }.sort
    end

    def parse_hashes(stdout)
      observed = {}
      stdout.force_encoding(Encoding::UTF_8).lines.each do |line|
        next unless line.start_with?("__W191_HASH__\t")
        fields = line.chomp.split("\t", -1)
        fail!("malformed native hash vector #{line.inspect}") unless fields.size == 3
        _tag, key, value = fields
        fail!("malformed native hash vector #{line.inspect}") unless value.match?(/\A[0-9]+\z/)
        fail!("duplicate native hash vector for #{key.inspect}") if observed.key?(key)
        observed[key] = Integer(value, 10)
      end
      observed
    end

    def validate_evidence!
      %w[invocations raw_streams].each { |name| @base.send(:validate_plain_tree!, File.join(@root, name)) }
      Profiles.each do |profile|
        store = File.join(@root, 'stores', 'native', profile.fetch(:id))
        # ClickHouse owns catalog symlinks below stores; validate only the exact
        # selected part path through W185's bounded part validator.
        fail!("#{profile[:id]} store directory is not a real directory") unless File.directory?(store) && !File.symlink?(store)
      end
    end

    def write_summary(status:, fatal_error: nil)
      summary = {
        probe: 'W191 stock-only Object V3 shared ADVANCED/ADVANCED_CHUNKED physical capture',
        status: status, fatal_error: fatal_error,
        runtime: {path: @binary, expected_sha256: BinarySHA256, sha256_before: @sha_before,
                  sha256_after: @sha_after, expected_version: Version, expected_build: Build,
                  source_revision: 'ef037e60fc7f5654c8c80eefb8be82e3c56f9a67'},
        limits: {max_threads: 1, local_max_memory_usage_bytes: Memory,
                 required_outer_run_safe_memory_limit_bytes: OuterRunSafeLimit,
                 timeout_seconds: Timeout, termination_grace_seconds: Grace,
                 per_stream_compressed_input_bytes: CompressedLimit,
                 per_stream_decoded_output_bytes: DecodedLimit,
                 utility_memory_cap_applicable: false,
                 executor: 'JsonBinaryKernelW180Probe#execute'},
        profiles: @profiles, invocations: @invocations, evidence_root: @root,
      }
      @base.send(:write_new, File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      success = status == 'all_stock_profiles_observed'
      lines = [
        '# W191 stock-only Object ADVANCED layout capture', '',
        "Status: `#{status}`", '',
        success ?
          'All authored root/Array and empty controls passed native pin, schema, CHECK, literal rows, Wide-part inventory, and bounded stream decoding. The capture records actual per-bucket structure chunks, transport coordinate pairs, Array size0 child schedule, and whole-shared copy lanes.' :
          'Intended scope: root and Array(JSON), ADVANCED v2 and ADVANCED_CHUNKED v3, plus empty shared/child controls. A failure is inconclusive; inspect each profile error and captured subprocess before drawing a format conclusion.',
        '',
        'Raw per-path data/substream lanes are decompressed and inventoried, but nested typed payload decoding and any Crystal reader/writer admission are outside this stock-only probe.',
        'The parent mark grid stays [2,2,2,2,0]; Array child occurrence counts are independently derived from the decoded a.size0 stream. Structure coordinates are transport offsets normalized through the captured LZ4 frames, not logical child counts.',
        '', "Evidence root: `#{@root}`", '',
      ]
      @base.send(:write_new, File.join(@root, 'summary.md'), lines.join("\n"))
    end
  end

  def self.self_test!
    Layout.self_test!
    true
  end

  def self.run(binary, root)
    Probe.new(binary, root).run
  end
end

if $PROGRAM_NAME == __FILE__
  options = {binary: ProbeObjectSharedAdvancedW191::Binary}
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/probe_object_shared_advanced_w191.rb --evidence-root EMPTY_CHILD_OF_PRIVATE_TMP [--binary CLICKHOUSE] [--self-test]'
    parser.on('--binary PATH') { |value| options[:binary] = value }
    parser.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
    parser.on('--self-test') { options[:self_test] = true }
  end.parse!
  if options[:self_test]
    ProbeObjectSharedAdvancedW191.self_test!
    puts 'W191 parser self-test passed'
    exit 0
  end
  raise 'evidence root required via --evidence-root' unless options[:evidence_root]
  exit(ProbeObjectSharedAdvancedW191.run(options[:binary], options[:evidence_root]) ? 0 : 1)
end
