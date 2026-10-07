#!/usr/bin/env ruby
# Bounded checkpoint-A native metadata witness. Reuses the W202 process
# executor and prebuilt Crystal helper; it does not compile or ATTACH a part.

require 'digest'
require 'json'
require 'optparse'
require_relative 'probe_recursive_dynamic_json_w204'

module ProbeDynamicJSONMetadataW206
  W204 = ProbeRecursiveDynamicJSONW204
  W202 = W204::W202
  BINARY = W202::BINARY
  BINARY_SHA256 = W202::BINARY_SHA256
  VERSION = W202::VERSION
  BUILD = W202::BUILD
  MEMORY = W202::MEMORY
  TIMEOUT = W202::TIMEOUT
  GRACE = W202::GRACE
  OUTER_RUN_SAFE_LIMIT = W202::OUTER_RUN_SAFE_LIMIT
  SOURCE_ARCHIVE_COMMIT = W204::SOURCE_ARCHIVE_COMMIT

  CASE_ID = 'direct_dynamic_json'.freeze
  TABLE = 'source_direct_dynamic_json_w206'.freeze
  COLUMN = 'd'.freeze
  JSON_TYPE = 'JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8)'.freeze
  DYNAMIC_TYPE = 'Dynamic(max_types=1)'.freeze
  PROFILE = 'single_stream'.freeze
  FORMAT_INPUT = 'dynamic_json_metadata_w206_input_v1'.freeze
  FORMAT_OUTPUT = 'dynamic_json_metadata_w206_helper_v1'.freeze
  # UInt64LE(4), count=1, independent TAG_JSON descriptor, then the
  # independent JSON=8 / SharedVariant=0 statistics suffix.
  EXPECTED_METADATA_HEX = '0400000000000000013000010101017401000001080000'.freeze
  EXPECTED_STATISTICS_OFFSET = 19
  EXPECTED_LOGICAL_SIZE = 23
  SETTINGS = W204::SETTINGS

  # These JSON byte strings are independent expectations, not generated from
  # the INSERT fixture or from either reader's output.
  EXPECTED_VALUE_HEX = %w[
    7B2274223A317D 7B2274223A327D 7B2274223A337D 7B2274223A347D
    7B2274223A357D 7B2274223A367D 7B2274223A377D 7B2274223A387D
  ].freeze

  class Probe < W202::Probe
    def initialize(binary, crystal_helper, evidence_root)
      super
      @source_part = nil
      @source_snapshot_before_helper = nil
      @source_snapshot_after_helper = nil
      @native_observations = nil
      @helper_observations = nil
      @fatal_error = nil
    end

    def run
      prepare_layout!
      @binary_sha_before = binary_sha
      fail!('pinned ClickHouse executable SHA-256 mismatch before probe') unless @binary_sha_before == BINARY_SHA256
      @helper_sha_before = helper_sha

      initial = run_clickhouse('native_metadata_source', initial_sql)
      assert_native_invocation!(initial)
      native = parse_native(initial[:stdout])
      assert_pin!(native)
      assert_native!(native)
      @native_observations = native

      part = native.fetch(:parts).fetch(TABLE)
      @source_part = validate_source_part!(part.fetch(:path))
      validate_store_path!(native[:data_path][1])
      @source_snapshot_before_helper = snapshot_part(@source_part)

      helper_input = build_helper_input
      input_path = File.join(@root, 'generated', 'helper-input.json')
      input_bytes = JSON.pretty_generate(helper_input) + "\n"
      write_new(input_path, input_bytes)
      @helper_input = {
        path: input_path, bytes: input_bytes.bytesize,
        sha256: Digest::SHA256.hexdigest(input_bytes),
      }
      helper = run_helper(input_path)
      assert_helper!(helper[:data])
      @helper_observations = helper[:data]

      @source_snapshot_after_helper = snapshot_part(@source_part)
      fail!('stock-authored source part changed during metadata reading') unless
        @source_snapshot_after_helper == @source_snapshot_before_helper
      @binary_sha_after = binary_sha
      @helper_sha_after = helper_sha
      fail!('pinned ClickHouse executable SHA changed during probe') unless @binary_sha_after == BINARY_SHA256
      fail!('prebuilt Crystal helper SHA changed during probe') unless @helper_sha_after == @helper_sha_before

      write_evidence(status: 'stock_dynamic_json_metadata_observed')
      puts "W206 checkpoint-A direct Dynamic JSON metadata witness; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @binary_sha_after = binary_sha rescue nil
      @helper_sha_after = helper_sha rescue nil
      write_evidence(status: 'runner_failure_or_observations_differ', fatal_error: @fatal_error) rescue nil
      warn "W206 metadata probe failure (process failure is not format evidence): #{@fatal_error}"
      false
    end

    private

    def fail!(message)
      raise RuntimeError, "W206 checkpoint-A metadata oracle: #{message}"
    end

    def prepare_layout!
      %w[invocations inputs stores generated].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
    end

    # The inherited executor hashes stdin and names its evidence file, but
    # does not write it. Preserve the exact SQL separately before execution.
    def run_clickhouse(label, sql)
      argv = [@binary, 'local', '--path', File.join(@root, 'stores', 'native'),
              '--session_timezone=UTC', '--max_threads=1', "--max_memory_usage=#{MEMORY}", '--multiquery']
      before = binary_sha
      fail!('pinned ClickHouse executable SHA mismatch before native invocation') unless before == BINARY_SHA256
      write_new(File.join(@root, 'invocations', "#{label}.stdin.sql"), sql.b)
      invocation = @executor.send(:execute_record, label, argv, sql.b,
                                  'clickhouse local', BINARY_SHA256, @binary)
      invocation[:record][:binary_sha_before] = before
      fail!('pinned ClickHouse executable SHA changed during invocation') unless
        invocation[:record][:binary_sha_after] == BINARY_SHA256
      @invocations << invocation[:record]
      invocation
    end

    def initial_sql
      statements = [
        'SET flatten_nested=0;',
        'SET print_pretty_type_names=0;',
        "SELECT '__W206_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
      ]
      settings = "#{SETTINGS}, string_serialization_version='#{PROFILE}'"
      statements << "CREATE TABLE default.#{TABLE} (pk UInt64, #{COLUMN} #{DYNAMIC_TYPE}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings};"
      values = (1..8).map do |value|
        json = W204.sql_quote(%({"t":#{value}}))
        typed = "CAST(#{json}, #{W204.sql_quote(JSON_TYPE)})"
        dynamic = "CAST(#{typed}, #{W204.sql_quote(DYNAMIC_TYPE)})"
        "(#{value}, #{dynamic})"
      end
      statements << "INSERT INTO default.#{TABLE} VALUES\n#{values.join(",\n")};"
      statements << check_sql
      statements << "SELECT '__W206_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table='#{TABLE}' ORDER BY position FORMAT TSVRaw;"
      statements << "SELECT '__W206_DATA_PATH__', name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{TABLE}' FORMAT TSVRaw;"
      statements << parts_sql
      statements << values_sql
      statements.join("\n") + "\n"
    end

    def check_sql
      ["SELECT '__W206_CHECK_BEGIN__', '#{TABLE}' FORMAT TSVRaw;",
       "CHECK TABLE default.#{TABLE} FORMAT TSV;",
       "SELECT '__W206_CHECK_END__', '#{TABLE}' FORMAT TSVRaw;"].join("\n")
    end

    def parts_sql
      "SELECT '__W206_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{TABLE}' AND active ORDER BY name FORMAT TSVRaw;"
    end

    def values_sql
      "SELECT '__W206_VALUES__', '#{TABLE}', toString(pk), hex(toJSONString(#{COLUMN})), toTypeName(#{COLUMN}), dynamicType(#{COLUMN}), toString(toUInt8(isDynamicElementInSharedData(#{COLUMN}))) FROM default.#{TABLE} ORDER BY pk SETTINGS print_pretty_type_names=0 FORMAT TSVRaw;"
    end

    def parse_native(stdout)
      lines = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      records = ->(prefix) { lines.select { |line| line.start_with?("#{prefix}\t") }.map { |line| line.split("\t", -1) } }
      known = %w[__W206_PIN__ __W206_SCHEMA__ __W206_DATA_PATH__ __W206_PART__
                 __W206_CHECK_BEGIN__ __W206_CHECK_END__ __W206_VALUES__]
      unknown = lines.each_with_object([]) do |line, tags|
        next unless line.start_with?('__W206_')
        tag = line.split("\t", 2).first
        tags << tag unless known.include?(tag)
      end
      fail!("unknown native marker tags: #{unknown.uniq.inspect}") unless unknown.empty?

      checks = {}
      active = nil
      lines.each do |line|
        if line.start_with?("__W206_CHECK_BEGIN__\t")
          fields = line.split("\t", -1)
          fail!('malformed or nested CHECK begin') unless fields.size == 2 && !active
          fail!('CHECK begin table marker differs') unless fields[1] == TABLE
          active = fields[1]
          fail!('duplicate CHECK block') if checks.key?(active)
          checks[active] = []
        elsif line.start_with?("__W206_CHECK_END__\t")
          fields = line.split("\t", -1)
          fail!('malformed or mismatched CHECK end') unless fields.size == 2 && active == fields[1]
          fail!('CHECK end table marker differs') unless fields[1] == TABLE
          active = nil
        elsif active
          checks.fetch(active) << line
        end
      end
      fail!('unterminated CHECK block') if active

      pin = records.call('__W206_PIN__')
      fail!('runtime pin record width differs') unless pin.size == 1 && pin.first.size == 3
      schemas = records.call('__W206_SCHEMA__').map do |fields|
        fail!('schema record width differs') unless fields.size == 4
        fields.drop(1)
      end
      data_path = records.call('__W206_DATA_PATH__')
      fail!('data-path record width differs') unless data_path.size == 1 && data_path.first.size == 3
      part_records = records.call('__W206_PART__')
      fail!('active part record count differs') unless part_records.size == 1
      fail!('active part record roster contains a duplicate table') unless part_records.map { |fields| fields[1] }.uniq.size == part_records.size
      parts = part_records.to_h do |fields|
        fail!('part record width differs') unless fields.size == 7
        [fields[1], {name: fields[2], path: fields[3], type: fields[4], rows: fields[5], marks: fields[6]}]
      end
      value_rows = records.call('__W206_VALUES__').map do |fields|
        fail!('selected-value record width differs') unless fields.size == 7
        fail!('selected-value table marker differs') unless fields[1] == TABLE
        fields.drop(2)
      end
      {
        pin: pin.first.join("\t"), checks: checks, schemas: schemas,
        data_path: data_path.first.drop(1), parts: parts, value_rows: value_rows,
      }
    end

    def assert_pin!(native)
      expected = "__W206_PIN__\t#{VERSION}\t#{BUILD}"
      fail!("runtime version/build differs: #{native[:pin].inspect}") unless native[:pin] == expected
    end

    def assert_native!(native)
      fail!('stock CHECK does not establish a valid nonempty source part') unless
        native[:checks] == {TABLE => ["all_1_1_0\t1\t"]}
      fail!("stock schema differs: #{native[:schemas].inspect}") unless
        native[:schemas] == [[TABLE, 'pk', 'UInt64'], [TABLE, COLUMN, DYNAMIC_TYPE]]
      fail!('native table path record differs') unless native[:data_path][0] == TABLE && !native[:data_path][1].empty?
      fail!('native active part roster differs') unless native[:parts].keys == [TABLE]
      part = native[:parts].fetch(TABLE)
      fail!('stock part is not the expected fresh Wide part') unless
        part[:name] == 'all_1_1_0' && part[:type] == 'Wide' && part[:rows] == '8' && part[:marks] == '5'

      expected_rows = EXPECTED_VALUE_HEX.each_with_index.map do |hex, index|
        [(index + 1).to_s, hex, DYNAMIC_TYPE, JSON_TYPE, '0']
      end
      fail!("independent stock value/type/shared literals differ: #{native[:value_rows].inspect}") unless
        native[:value_rows] == expected_rows
    end

    def build_helper_input
      capture_root = File.realpath(File.join(@root, 'stores', 'native'))
      {
        'format' => FORMAT_INPUT, 'case_id' => CASE_ID, 'capture_root' => capture_root,
        'source_part' => @source_part,
      }
    end

    def run_helper(input_path)
      before = helper_sha
      fail!('prebuilt helper changed before invocation') unless before == @helper_sha_before
      argv = [@helper, input_path, File.join(@root, 'generated')]
      invocation = @executor.send(:execute_record, 'crystal_metadata_helper', argv, ''.b,
                                  'prebuilt Crystal helper', before, @helper)
      fail!('prebuilt Crystal helper failed; not a native format rejection') unless successful?(invocation)
      fail!('prebuilt Crystal helper emitted stderr') unless invocation[:stderr].empty?
      fail!('prebuilt Crystal helper SHA changed during invocation') unless helper_sha == before
      lines = invocation[:stdout].lines.map(&:chomp).reject(&:empty?)
      fail!('Crystal helper must emit exactly one JSON record') unless lines.size == 1
      data = JSON.parse(lines.first)
      fail!('Crystal helper output format differs') unless data['format'] == FORMAT_OUTPUT
      @invocations << invocation[:record]
      {data: data, record: invocation[:record]}
    end

    def assert_helper!(data)
      expected_keys = %w[actual_types byte_exact_reencode canonical_indices canonical_variant_names
                         case_id format logical_size mark_row_counts metadata_bytes_hex row_count schema_declaration
                         selected_stream_names shared_statistics_count statistics_counts
                         statistics_offset structure_stream_name]
      fail!('helper result fields/case identity differ') unless
        data.keys.sort == expected_keys && data['format'] == FORMAT_OUTPUT && data['case_id'] == CASE_ID
      fail!('helper read a different direct Dynamic declaration or row count') unless
        data['schema_declaration'] == DYNAMIC_TYPE && data['row_count'] == 8
      fail!('helper selected stream roster is malformed or duplicated') unless
        data['selected_stream_names'].is_a?(Array) &&
        data['selected_stream_names'].all? { |name| name.is_a?(String) } &&
        data['selected_stream_names'].uniq == data['selected_stream_names']
      fail!('helper did not observe the literal structure stream') unless
        data['structure_stream_name'] == 'd.dynamic_structure' &&
        data['selected_stream_names'].include?('d.dynamic_structure')
      fail!('helper actual descriptor differs from the independent JSON literal') unless
        data['actual_types'] == [JSON_TYPE]
      fail!('helper canonical names/indices differ from JSON then SharedVariant') unless
        data['canonical_variant_names'] == [JSON_TYPE, 'SharedVariant'] && data['canonical_indices'] == [0, 1]
      fail!('helper metadata statistics differ from JSON=8, SharedVariant=0') unless
        data['statistics_counts'] == [8, 0] && data['shared_statistics_count'] == 0
      fail!('helper observed a different P-grid or statistics byte offset') unless
        data['mark_row_counts'] == [2, 2, 2, 2] &&
        data['statistics_offset'] == EXPECTED_STATISTICS_OFFSET &&
        data['logical_size'] == EXPECTED_LOGICAL_SIZE
      fail!('stock Dynamic metadata bytes differ from the independent literal') unless
        data['metadata_bytes_hex'] == EXPECTED_METADATA_HEX
      fail!('full Dynamic metadata did not re-encode byte-for-byte') unless data['byte_exact_reencode'] == true
    end

    def self_test!
      probe = self
      valid_output = self_test_native_output
      native = probe.send(:parse_native, valid_output)
      probe.send(:assert_pin!, native)
      probe.send(:assert_native!, native)

      self_test_expect_rejected('wrong value') do
        changed = valid_output.sub(EXPECTED_VALUE_HEX.first, '7B2274223A397D')
        probe.send(:assert_native!, probe.send(:parse_native, changed))
      end
      self_test_expect_rejected('wrong type') do
        changed = valid_output.sub("\t#{DYNAMIC_TYPE}\t#{JSON_TYPE}\t0", "\tString\t#{JSON_TYPE}\t0")
        probe.send(:assert_native!, probe.send(:parse_native, changed))
      end
      self_test_expect_rejected('wrong shared flag') do
        changed = valid_output.sub("\t#{JSON_TYPE}\t0", "\t#{JSON_TYPE}\t1")
        probe.send(:assert_native!, probe.send(:parse_native, changed))
      end
      self_test_expect_rejected('duplicate part') do
        part = valid_output.lines.find { |line| line.start_with?("__W206_PART__\t") }
        probe.send(:parse_native, valid_output.sub(part, "#{part}#{part}"))
      end
      self_test_expect_rejected('wrong CHECK table marker') do
        probe.send(:parse_native, valid_output.sub("__W206_CHECK_BEGIN__\t#{TABLE}", "__W206_CHECK_BEGIN__\tother_table"))
      end
      self_test_expect_rejected('wrong value table marker') do
        probe.send(:parse_native, valid_output.sub("__W206_VALUES__\t#{TABLE}", '__W206_VALUES__\tother_table'))
      end

      helper = self_test_helper_data
      probe.send(:assert_helper!, helper)
      {
        'statistics count' => ['statistics_counts', [7, 1]],
        'statistics offset' => ['statistics_offset', EXPECTED_STATISTICS_OFFSET - 1],
        'logical size' => ['logical_size', EXPECTED_LOGICAL_SIZE + 1],
        'stream roster' => ['selected_stream_names', []],
        'metadata bytes' => ['metadata_bytes_hex', EXPECTED_METADATA_HEX.sub('01', '02')],
        'byte-exact flag' => ['byte_exact_reencode', false],
      }.each do |label, (key, value)|
        self_test_expect_rejected(label) do
          mutated = helper.merge(key => value)
          probe.send(:assert_helper!, mutated)
        end
      end

      # A semantic helper report must not overwrite executable provenance.
      writes = {}
      define_singleton_method(:write_new) { |path, content| writes[File.basename(path)] = content }
      @root = '/private/tmp/w206-self-test-not-written'
      @helper = 'pinned-helper-self-test'
      @helper_sha_before = @helper_sha_after = 'helper-sha-self-test'
      write_evidence(status: 'self-test', helper: 'must-not-overwrite-executable-identity')
      summary = JSON.parse(writes.fetch('summary.json'))
      raise 'W206 self-test lost executable provenance' unless summary['helper'] == {
        'path' => @helper, 'sha256_before' => @helper_sha_before, 'sha256_after' => @helper_sha_after,
      }

      puts 'W206 Ruby mutation self-test passed'
      true
    end

    def self_test_native_output
      lines = [
        "__W206_PIN__\t#{VERSION}\t#{BUILD}",
        "__W206_CHECK_BEGIN__\t#{TABLE}",
        "all_1_1_0\t1\t",
        "__W206_CHECK_END__\t#{TABLE}",
        "__W206_SCHEMA__\t#{TABLE}\tpk\tUInt64",
        "__W206_SCHEMA__\t#{TABLE}\t#{COLUMN}\t#{DYNAMIC_TYPE}",
        "__W206_DATA_PATH__\t#{TABLE}\t/tmp/w206/store",
        "__W206_PART__\t#{TABLE}\tall_1_1_0\t/tmp/w206/store/all_1_1_0\tWide\t8\t5",
      ]
      EXPECTED_VALUE_HEX.each_with_index do |hex, index|
        lines << "__W206_VALUES__\t#{TABLE}\t#{index + 1}\t#{hex}\t#{DYNAMIC_TYPE}\t#{JSON_TYPE}\t0"
      end
      lines.join("\n") + "\n"
    end

    def self_test_helper_data
      {
        'actual_types' => [JSON_TYPE], 'byte_exact_reencode' => true,
        'canonical_indices' => [0, 1],
        'canonical_variant_names' => [JSON_TYPE, 'SharedVariant'],
        'case_id' => CASE_ID, 'format' => FORMAT_OUTPUT,
        'logical_size' => EXPECTED_LOGICAL_SIZE,
        'mark_row_counts' => [2, 2, 2, 2],
        'metadata_bytes_hex' => EXPECTED_METADATA_HEX,
        'row_count' => 8, 'schema_declaration' => DYNAMIC_TYPE,
        'selected_stream_names' => ['d.dynamic_structure'],
        'shared_statistics_count' => 0, 'statistics_counts' => [8, 0],
        'statistics_offset' => EXPECTED_STATISTICS_OFFSET,
        'structure_stream_name' => 'd.dynamic_structure',
      }
    end

    def self_test_expect_rejected(label)
      yield
      raise "W206 self-test unexpectedly accepted #{label} mutation"
    rescue RuntimeError => error
      raise unless error.message.include?('W206 checkpoint-A metadata oracle')
    end

    def write_evidence(data)
      summary = {
        probe: 'W206 checkpoint-A stock-authored direct Dynamic JSON metadata witness',
        status: data[:status], fatal_error: data[:fatal_error],
        source_archive: {
          path: '/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1-ef037e60',
          audited_commit: SOURCE_ARCHIVE_COMMIT,
          disclaimer: 'read-only source archive; not the native runtime source',
        },
        runtime: {
          path: @binary, expected_sha256: BINARY_SHA256,
          sha256_before: @binary_sha_before, sha256_after: @binary_sha_after,
          expected_version: VERSION, expected_build: BUILD,
        },
        helper: {path: @helper, sha256_before: @helper_sha_before, sha256_after: @helper_sha_after},
        limits: {
          max_threads: 1, local_max_memory_usage_bytes: MEMORY,
          required_outer_run_safe_memory_limit_bytes: OUTER_RUN_SAFE_LIMIT,
          timeout_seconds: TIMEOUT, termination_grace_seconds: GRACE,
          executor: 'W202 Probe via W185 JsonBinaryKernelW180Probe#execute_record',
        },
        case_id: CASE_ID, string_profile: PROFILE, evidence_root: @root,
        native_independent_literals: {
          schema: [TABLE, COLUMN, DYNAMIC_TYPE],
          actual_json_type: JSON_TYPE, expected_value_hex: EXPECTED_VALUE_HEX,
          expected_shared_flags: Array.new(8, '0'), check: "all_1_1_0\t1\t",
          part: {name: 'all_1_1_0', type: 'Wide', rows: '8', marks: '5'},
          metadata_bytes_hex: EXPECTED_METADATA_HEX,
          statistics_offset: EXPECTED_STATISTICS_OFFSET, logical_size: EXPECTED_LOGICAL_SIZE,
        },
        helper_input: @helper_input, native_observations: @native_observations,
        helper_observations: @helper_observations,
        source_part_snapshot_before_helper: @source_snapshot_before_helper,
        source_part_snapshot_after_helper: @source_snapshot_after_helper,
        invocations: @invocations,
      }
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      write_new(File.join(@root, 'summary.md'), [
        '# W206 checkpoint-A direct Dynamic JSON metadata witness', '',
        "Status: `#{summary[:status]}`", '',
        'Scope: fresh stock-authored direct Dynamic JSON actual, metadata structure stream and byte-exact common-codec round trip. SQL selected values/type/shared state and CHECK authenticate nonempty source provenance. This is metadata-only: it does not qualify bare Dynamic value/storage admission, Object handoff, library writing, or ATTACH.', '',
        "Source archive: `#{SOURCE_ARCHIVE_COMMIT}` (not runtime).",
        "Runtime: #{VERSION} / #{BUILD} / SHA256 `#{BINARY_SHA256}`.",
        "Evidence root: `#{@root}`", '',
      ].join("\n"))
    end
  end
end

if $PROGRAM_NAME == __FILE__
  if ARGV == ['--self-test']
    ProbeDynamicJSONMetadataW206::Probe.allocate.send(:self_test!)
    exit 0
  end
  options = {}
  OptionParser.new do |parser|
    parser.banner = 'Usage: probe_dynamic_json_metadata_w206.rb --binary PATH --helper PATH --evidence-root EMPTY_DIR'
    parser.on('--binary PATH') { |value| options[:binary] = value }
    parser.on('--helper PATH') { |value| options[:helper] = value }
    parser.on('--evidence-root EMPTY_DIR') { |value| options[:root] = value }
  end.parse!
  abort 'unexpected positional arguments' unless ARGV.empty?
  probe = ProbeDynamicJSONMetadataW206::Probe.new(options[:binary], options[:helper], options[:root])
  exit(probe.run ? 0 : 1)
end
