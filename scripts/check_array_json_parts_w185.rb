#!/usr/bin/env ruby
# Root-run paired stock/Crystal qualification for one normalized Array(JSON)
# MAP profile. It never builds either executable and treats process failures as
# inconclusive runtime failures, not as expected format rejections.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require_relative 'check_json_binary_kernel_w180'
require_relative 'probe_json_array_storage_w183'

module CheckArrayJSONPartsW185
  BINARY = JsonBinaryKernelW180Probe::DEFAULT_BINARY.freeze
  BINARY_SHA256 = JsonBinaryKernelW180Probe::BINARY_SHA256.freeze
  VERSION = '26.10.1.1201'.freeze
  BUILD = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  MEMORY = JsonBinaryKernelW180Probe::MEMORY_LIMIT_BYTES
  TIMEOUT = JsonBinaryKernelW180Probe::PROCESS_TIMEOUT_SECONDS
  GRACE = JsonBinaryKernelW180Probe::TERMINATION_GRACE_SECONDS
  OUTER_RUN_SAFE_LIMIT = 12 * 1024 * 1024 * 1024
  ROOT_JSON = 'JSON(max_dynamic_types=0, max_dynamic_paths=0, t UInt8)'.freeze
  ARRAY_JSON = "Array(#{ROOT_JSON})".freeze
  TABLES = %w[source_mixed source_empty root_control library_target].freeze
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
  ].join(', ').freeze

  # Independently authored from the Crystal helper's own literals. Four
  # two-row marks contain a populated mark, an empty intermediate mark, a
  # later populated mark, and an empty trailing mark.
  MIXED = [
    {pk: 1, values: []},
    {pk: 2, values: ['{"t":7,"shared":"red"}']},
    {pk: 3, values: []},
    {pk: 4, values: []},
    {pk: 5, values: ['{"t":11,"shared":"blue"}', '{"t":13,"shared":"green"}']},
    {pk: 6, values: []},
    {pk: 7, values: []},
    {pk: 8, values: []},
  ].freeze
  EMPTY = (1..8).map { |pk| {pk: pk, values: []} }.freeze
  ROOT = (1..8).map { |pk| {pk: pk, value: "{\"t\":#{pk},\"shared\":\"root#{pk}\"}"} }.freeze
  EXPECTED_MIXED_ROWS = [[], ['7:red'], [], [], ['11:blue', '13:green'], [], [], []].freeze
  EXPECTED_EMPTY_ROWS = Array.new(8) { [] }.freeze

  class Probe
    def initialize(binary, crystal_probe, evidence_root)
      @binary = validate_executable(binary, 'ClickHouse')
      @crystal_probe = validate_executable(crystal_probe, 'Crystal helper')
      @root = validate_root(evidence_root)
      @invocations = []
      @fatal_error = nil
    end

    def run
      %w[invocations stores parts].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
      @sha_before = binary_sha
      fail!('pinned ClickHouse executable SHA-256 mismatch before probe') unless @sha_before == BINARY_SHA256

      initial = run_clickhouse('native_sources', initial_sql)
      assert_pin!(initial)
      assert_native_invocation!(initial)
      source = parse_native(initial[:stdout])
      assert_initial_native!(source)

      mixed_part = source.fetch(:parts).fetch('source_mixed').fetch(:path)
      empty_part = source.fetch(:parts).fetch('source_empty').fetch(:path)
      validate_part_path!(mixed_part)
      validate_part_path!(empty_part)
      mixed_inventory = inspect_part('stock_mixed', mixed_part, source[:parts]['source_mixed'])
      empty_inventory = inspect_part('stock_empty', empty_part, source[:parts]['source_empty'])
      root_part = source.fetch(:parts).fetch('root_control').fetch(:path)
      root_inventory = inspect_part('root_control', root_part, source[:parts]['root_control'])
      assert_site_rosters!(mixed_inventory, empty_inventory, root_inventory)

      library_part = File.join(@root, 'parts', 'library_1_1_0')
      crystal = run_crystal_helper(mixed_part, empty_part, library_part)
      assert_crystal!(crystal, library_part)
      library_inventory = inspect_part('library_array_json', library_part,
                                        {name: 'all_1_1_0', path: library_part,
                                         part_type: 'Wide', rows: '8', marks: 'unattached'},
                                        generated_library: true)
      assert_library_roster!(library_inventory, crystal)

      target_data_path = source.fetch(:data_paths).fetch('library_target')
      validate_store_path!(target_data_path)
      attach_part!(library_part, target_data_path)
      attached = run_clickhouse('attach_and_check', attached_sql)
      assert_pin!(attached)
      assert_native_invocation!(attached)
      attached_result = parse_native(attached[:stdout])
      assert_attached_native!(attached_result)

      @sha_after = binary_sha
      fail!('pinned ClickHouse executable SHA-256 changed during probe') unless @sha_after == BINARY_SHA256
      write_summary(
        status: 'paired_array_json_observed',
        source_invocation: initial[:record], helper_invocation: crystal[:invocation],
        attached_invocation: attached[:record], source: source,
        mixed_part: mixed_inventory, empty_part: empty_inventory,
        root_control_part: root_inventory, library_part: library_inventory,
        attached: attached_result,
      )
      puts "W185 status=paired_array_json_observed; mixed/empty/root=stock-checked; library=attached-and-checked; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @sha_after = binary_sha rescue nil
      write_summary(status: 'runner_failure_or_observations_differ', fatal_error: @fatal_error) rescue nil
      warn "W185 probe failed: #{@fatal_error}"
      false
    end

    private

    def validate_root(path)
      fail!('evidence root is required') unless path && !path.empty?
      expanded = File.expand_path(path)
      parent = File.realpath('/private/tmp')
      fail!('evidence root must be a direct child of /private/tmp') unless File.dirname(expanded) == parent
      fail!('evidence root must not be a symlink') if File.symlink?(expanded)
      fail!('evidence root must already exist and be empty') unless
        File.directory?(expanded) && File.realpath(expanded) == expanded && Dir.children(expanded).empty?
      expanded
    rescue Errno::ENOENT
      fail!('evidence root must already exist')
    end

    def validate_executable(path, label)
      fail!("#{label} executable path is required") unless path && !path.empty?
      expanded = File.expand_path(path)
      fail!("#{label} executable is missing, not executable, or symlinked: #{path}") unless
        File.file?(expanded) && File.executable?(expanded) && !File.symlink?(expanded)
      expanded
    end

    def binary_sha
      Digest::SHA256.file(@binary).hexdigest
    end

    def run_clickhouse(label, sql)
      store = File.join(@root, 'stores', 'native')
      sql_path = File.join(@root, 'invocations', "#{label}.stdin.sql")
      write_new(sql_path, sql.b)
      argv = [@binary, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
              "--max_memory_usage=#{MEMORY}", '--multiquery']
      before_sha = binary_sha
      fail!('pinned ClickHouse executable SHA-256 mismatch before invocation') unless before_sha == BINARY_SHA256
      invocation = execute_record(label, argv, sql.b, 'clickhouse local', BINARY_SHA256, @binary)
      invocation[:record][:binary_sha_before] = before_sha
      invocation[:record][:binary_sha_after] = binary_sha
      fail!('pinned ClickHouse executable SHA-256 changed during invocation') unless invocation[:record][:binary_sha_after] == BINARY_SHA256
      invocation
    end

    def run_crystal_helper(mixed_part, empty_part, library_part)
      fail!('library part destination already exists') if File.exist?(library_part) || File.symlink?(library_part)
      argv = [@crystal_probe, mixed_part, empty_part, library_part]
      invocation = execute_record('crystal_helper', argv, ''.b, 'prebuilt Crystal helper', nil, nil)
      fail!('Crystal helper failed; this is not a ClickHouse format rejection') unless successful?(invocation)
      fail!('Crystal helper wrote diagnostics to stderr') unless invocation[:stderr].empty?
      lines = invocation[:stdout].lines.map(&:chomp).reject(&:empty?)
      fail!('Crystal helper must emit exactly one JSON record') unless lines.size == 1
      parsed = JSON.parse(lines[0])
      {data: parsed, invocation: invocation[:record]}
    end

    def execute_record(label, argv, input, process_kind, expected_sha, sha_path)
      executor = JsonBinaryKernelW180Probe.allocate
      stdout, stderr, status, timed_out, spawn_error, stdin_error, stdout_error, stderr_error =
        executor.send(:execute, argv, input)
      classification = executor.send(:process_classification, status, timed_out, spawn_error,
                                     stdin_error, stdout_error, stderr_error, stderr)
      sha_after = sha_path ? Digest::SHA256.file(sha_path).hexdigest : nil
      record = {
        process_kind: process_kind, argv: argv,
        argv_sha256: Digest::SHA256.hexdigest(JSON.pretty_generate(argv) + "\n"),
        stdin_bytes: input.bytesize, stdin_sha256: Digest::SHA256.hexdigest(input),
        exit: status&.exitstatus, signal: status&.termsig,
        timed_out: timed_out, timeout_seconds: TIMEOUT, termination_grace_seconds: GRACE,
        max_threads: 1, max_memory_usage_bytes: process_kind == 'clickhouse local' ? MEMORY : nil,
        max_memory_usage_applicable: process_kind == 'clickhouse local',
        required_outer_run_safe_memory_limit_bytes: OUTER_RUN_SAFE_LIMIT,
        expected_binary_sha256: expected_sha, binary_sha_after: sha_after,
        spawn_error: spawn_error, stdin_write_error: stdin_error,
        stdout_read_error: stdout_error, stderr_read_error: stderr_error,
        process_classification: classification,
        stdout_bytes: stdout.bytesize, stdout_sha256: Digest::SHA256.hexdigest(stdout),
        stderr_bytes: stderr.bytesize, stderr_sha256: Digest::SHA256.hexdigest(stderr),
        stdout_file: "#{label}.stdout", stderr_file: "#{label}.stderr",
      }
      record[:stdin_file] = "#{label}.stdin.sql" if process_kind == 'clickhouse local'
      write_new(File.join(@root, 'invocations', "#{label}.argv.json"), JSON.pretty_generate(argv) + "\n")
      write_new(File.join(@root, 'invocations', "#{label}.stdout"), stdout)
      write_new(File.join(@root, 'invocations', "#{label}.stderr"), stderr)
      write_new(File.join(@root, 'invocations', "#{label}.json"), JSON.pretty_generate(record) + "\n")
      @invocations << record
      {stdout: stdout, stderr: stderr, status: status, classification: classification, record: record}
    end

    def successful?(invocation)
      invocation[:classification] == 'success' && invocation[:status]&.success? && invocation[:status]&.termsig.nil?
    end

    def assert_native_invocation!(invocation)
      fail!('ClickHouse process did not exit successfully') unless successful?(invocation)
      fail!('ClickHouse reported a server exception or system error despite a zero exit') if
        JsonBinaryKernelW180Probe::CLICKHOUSE_EXCEPTION.match?(invocation[:stderr]) ||
        JsonBinaryKernelW180Probe::SYSTEM_FAILURE.match?(invocation[:stderr])
      fail!('ClickHouse wrote unclassified stderr') unless invocation[:stderr].empty?
    end

    def assert_pin!(invocation)
      lines = invocation[:stdout].force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      observed = lines.find { |line| line.start_with?("__W185_PIN__\t") }
      expected = "__W185_PIN__\t#{VERSION}\t#{BUILD}"
      fail!("runtime pin mismatch: #{observed.inspect}") unless observed == expected
    end

    def initial_sql
      statements = [
        "SELECT '__W185_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
      ]
      TABLES.each do |table|
        statements << "CREATE TABLE default.#{table} (pk UInt64, a #{ARRAY_JSON}) ENGINE=MergeTree ORDER BY pk SETTINGS #{SETTINGS};" if %w[source_mixed source_empty library_target].include?(table)
      end
      statements << "CREATE TABLE default.root_control (pk UInt64, j #{ROOT_JSON}) ENGINE=MergeTree ORDER BY pk SETTINGS #{SETTINGS};"
      statements << insert_array_sql('source_mixed', MIXED)
      statements << insert_array_sql('source_empty', EMPTY)
      statements << insert_root_sql('root_control', ROOT)
      %w[source_mixed source_empty root_control].each do |table|
        statements << "SELECT '__W185_CHECK_BEGIN__', '#{table}' FORMAT TSVRaw;"
        statements << "CHECK TABLE default.#{table} FORMAT TSV;"
        statements << "SELECT '__W185_CHECK_END__', '#{table}' FORMAT TSVRaw;"
      end
      statements << "SELECT '__W185_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN ('source_mixed','source_empty','root_control','library_target') ORDER BY table, position FORMAT TSVRaw;"
      statements << array_rows_sql('source_mixed')
      statements << array_middle_rows_sql('source_mixed')
      statements << array_rows_sql('source_empty')
      statements << root_rows_sql('root_control')
      statements << "SELECT '__W185_DATA_PATH__', name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name IN ('source_mixed','source_empty','root_control','library_target') ORDER BY name FORMAT TSVRaw;"
      statements << "SELECT '__W185_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table IN ('source_mixed','source_empty','root_control') AND active ORDER BY table,name FORMAT TSVRaw;"
      statements.join("\n") + "\n"
    end

    def insert_array_sql(table, profile)
      values = profile.map do |row|
        elements = row[:values].map { |json| "CAST(#{sql_string(json)}, #{sql_string(ROOT_JSON)})" }
        array = "CAST([#{elements.join(', ')}], #{sql_string(ARRAY_JSON)})"
        "(#{row[:pk]}, #{array})"
      end.join(",\n")
      "INSERT INTO default.#{table} VALUES #{values};"
    end

    def insert_root_sql(table, profile)
      values = profile.map do |row|
        "(#{row[:pk]}, CAST(#{sql_string(row[:value])}, #{sql_string(ROOT_JSON)}))"
      end.join(",\n")
      "INSERT INTO default.#{table} VALUES #{values};"
    end

    def array_rows_sql(table)
      "SELECT '__W185_ROW__', '#{table}', toString(pk), toString(length(a)), hex(toJSONString(a)) FROM default.#{table} ORDER BY pk FORMAT TSVRaw;"
    end

    def array_middle_rows_sql(table)
      "SELECT '__W185_MIDDLE_ROW__', '#{table}', toString(pk), toString(length(a)), hex(toJSONString(a)) FROM default.#{table} WHERE pk BETWEEN 3 AND 6 ORDER BY pk FORMAT TSVRaw;"
    end

    def root_rows_sql(table)
      "SELECT '__W185_ROW__', '#{table}', toString(pk), '-', hex(toJSONString(j)) FROM default.#{table} ORDER BY pk FORMAT TSVRaw;"
    end

    def attached_sql
      [
        "SELECT '__W185_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
        "ALTER TABLE default.library_target ATTACH PART 'all_1_1_0';",
        "SELECT '__W185_CHECK_BEGIN__', 'library_target' FORMAT TSVRaw;",
        "CHECK TABLE default.library_target FORMAT TSV;",
        "SELECT '__W185_CHECK_END__', 'library_target' FORMAT TSVRaw;",
        "SELECT '__W185_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table='library_target' ORDER BY position FORMAT TSVRaw;",
        array_rows_sql('library_target'),
        array_middle_rows_sql('library_target'),
        "SELECT '__W185_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='library_target' AND active ORDER BY name FORMAT TSVRaw;",
      ].join("\n") + "\n"
    end

    def sql_string(value)
      "'#{value.to_s.gsub('\\') { '\\\\' }.gsub("'") { "\\'" }}'"
    end

    def parse_native(stdout)
      lines = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      fields = ->(tag) { lines.map { |line| line.split("\t", -1) if line.start_with?("#{tag}\t") }.compact }
      checks = {}
      active = nil
      lines.each do |line|
        if line.start_with?("__W185_CHECK_BEGIN__\t")
          active = line.split("\t", -1)[1]
          checks[active] = []
        elsif line.start_with?("__W185_CHECK_END__\t")
          active = nil
        elsif active
          checks[active] << line
        end
      end
      data_paths = {}
      fields.call('__W185_DATA_PATH__').each { |f| data_paths[f[1]] = f[2] }
      parts = {}
      fields.call('__W185_PART__').each do |f|
        parts[f[1]] = {name: f[2], path: f[3], part_type: f[4], rows: f[5], marks: f[6]}
      end
      {pin: lines.find { |line| line.start_with?("__W185_PIN__\t") }, checks: checks,
       schemas: fields.call('__W185_SCHEMA__').map { |f| f.drop(1) },
       rows: fields.call('__W185_ROW__').map { |f| f.drop(1) },
       middle_rows: fields.call('__W185_MIDDLE_ROW__').map { |f| f.drop(1) },
       data_paths: data_paths, parts: parts}
    end

    def assert_initial_native!(native)
      expected_checks = %w[source_mixed source_empty root_control].to_h { |table| [table, ["all_1_1_0\t1\t"]] }
      fail!("stock source CHECK differs: #{native[:checks].inspect}") unless native[:checks] == expected_checks
      expected_schemas = []
      %w[source_mixed source_empty].each do |table|
        expected_schemas << [table, 'pk', 'UInt64']
        expected_schemas << [table, 'a', ARRAY_JSON]
      end
      expected_schemas += [['root_control', 'pk', 'UInt64'], ['root_control', 'j', ROOT_JSON]]
      expected_schemas << ['library_target', 'pk', 'UInt64']
      expected_schemas << ['library_target', 'a', ARRAY_JSON]
      expected_schemas.sort_by! { |table, name, _type| [table, name == 'pk' ? 0 : 1] }
      fail!("stock schema differs: #{native[:schemas].inspect}") unless native[:schemas] == expected_schemas
      assert_array_rows!(native[:rows], 'source_mixed', MIXED, EXPECTED_MIXED_ROWS)
      assert_array_rows!(native[:middle_rows], 'source_mixed', MIXED.select { |row| (3..6).cover?(row[:pk]) },
                         EXPECTED_MIXED_ROWS[2, 4])
      assert_array_rows!(native[:rows], 'source_empty', EMPTY, EXPECTED_EMPTY_ROWS)
      root_rows = native[:rows].select { |f| f[0] == 'root_control' }
      expected_root = ROOT.map do |row|
        ['root_control', row[:pk].to_s, '-', JSON.parse(row[:value])]
      end
      decoded_root = decode_rows(root_rows)
      fail!('root JSON control literal rows differ') unless decoded_root == expected_root
      fail!('library target data path was not returned') unless native[:data_paths].key?('library_target')
      %w[source_mixed source_empty root_control].each do |table|
        part = native[:parts][table] || fail!("missing stock part for #{table}")
        fail!("#{table} is not one expected Wide part") unless part[:name] == 'all_1_1_0' && part[:part_type] == 'Wide' && part[:rows] == '8' && part[:marks] == '5'
      end
    end

    def assert_array_rows!(rows, table, profile, expected)
      selected = rows.select { |f| f[0] == table }
      decoded = selected.map do |f|
        [table, f[1], f[2], JSON.parse([f[3]].pack('H*'))]
      rescue JSON::ParserError
        fail!("#{table} row #{f[1]} was not valid JSON hex")
      end
      literal_rows = profile.map do |row|
        [table, row[:pk].to_s, row[:values].size.to_s, row[:values].map { |value| JSON.parse(value) }]
      end
      fail!("#{table} schema/literal row mismatch") unless decoded == literal_rows
      semantic = decoded.map { |f| f[3].map { |doc| "#{doc.fetch('t')}:#{doc.fetch('shared')}" } }
      fail!("#{table} nested row literals differ") unless semantic == expected
    end

    def decode_rows(rows)
      rows.map do |f|
        [f[0], f[1], f[2], JSON.parse([f[3]].pack('H*'))]
      end
    end

    def assert_crystal!(invocation, expected_library_path)
      result = invocation.fetch(:data)
      fail!('Crystal helper did not report the observed status') unless result['status'] == 'observed'
      fail!('Crystal helper library destination differs') unless File.expand_path(result.fetch('library_part_path')) == expected_library_path
      assert_reader_record!(result.fetch('stock_mixed'), 'stock mixed Array(JSON)', EXPECTED_MIXED_ROWS,
                            expected_marks: [2, 2, 2, 2])
      assert_reader_record!(result.fetch('stock_empty'), 'stock all-empty Array(JSON)', EXPECTED_EMPTY_ROWS,
                            expected_marks: [2, 2, 2, 2])
      assert_reader_record!(result.fetch('library_part'), 'library Array(JSON)', EXPECTED_MIXED_ROWS,
                            expected_marks: [2, 2, 2, 2])
      %w[stock_mixed library_part].each do |key|
        record = result.fetch(key)
        fail!("#{key} source declaration differs") unless record['schema_declaration'] == "Array(#{ROOT_JSON})"
        fail!("#{key} middle-mark rows differ") unless record['middle_rows'] == [
          [[], []], [['11:blue', '13:green'], []]
        ]
        fail!("#{key} batch table rows differ") unless record['table_rows'] == EXPECTED_MIXED_ROWS
      end
      empty = result.fetch('stock_empty')
      fail!('all-empty stock part returned nonempty table rows') unless empty['table_rows'] == EXPECTED_EMPTY_ROWS
      expected_inner = [
        'a.object_shared_data.size1', 'a.object_shared_data%2Epaths', 'a.object_shared_data%2Evalues', 'a.size0', 'a.t', 'a.object_structure',
      ]
      fail!("library stream roster does not contain the typed + shared MAP witness: #{result.dig('library_part', 'physical_stream_names').inspect}") unless
        (expected_inner - result.dig('library_part', 'physical_stream_names')).empty?
    end

    def assert_reader_record!(record, label, expected_rows, expected_marks:)
      fail!("#{label} outer row count differs") unless record['row_count'] == 8
      fail!("#{label} mark count differs") unless record['mark_count'] == expected_marks.size
      fail!("#{label} physical mark cardinality differs: #{record['mark_row_counts'].inspect}") unless record['mark_row_counts'] == expected_marks
      expected_full = expected_rows.each_slice(2).map { |rows| rows.map(&:dup) }
      fail!("#{label} full nested literals differ") unless record['full_rows'] == expected_full
    end

    def inspect_part(label, path, part, generated_library: false)
      if generated_library
        validate_library_part_path!(path)
      else
        validate_part_path!(path)
      end
      substreams_path = File.join(path, 'columns_substreams.txt')
      columns_path = File.join(path, 'columns.txt')
      count_path = File.join(path, 'count.txt')
      checksums_path = File.join(path, 'checksums.txt')
      serialization_path = File.join(path, 'serialization.json')
      codec_path = File.join(path, 'default_compression_codec.txt')
      metadata_version_path = File.join(path, 'metadata_version.txt')
      %w[columns_substreams.txt columns.txt count.txt checksums.txt primary.idx serialization.json default_compression_codec.txt metadata_version.txt].each do |name|
        fail!("#{label} part is missing #{name}") unless File.file?(File.join(path, name))
      end
      serialization_text = File.binread(serialization_path).force_encoding(Encoding::UTF_8)
      serialization = JSON.parse(serialization_text)
      fail!("#{label} serialization.json version differs") unless serialization['version'] == 1
      fail!("#{label} nested serializer propagation differs") unless serialization['propagate_types_serialization_versions_to_nested_types'] == true
      string_version = serialization.dig('types_serialization_versions', 'string')
      fail!("#{label} ordinary String serialization version is unsupported") unless [0, 1].include?(string_version)
      codec_text = File.read(codec_path).strip
      fail!("#{label} default compression codec differs") unless codec_text == 'CODEC(LZ4)'
      metadata_version = File.read(metadata_version_path).strip
      fail!("#{label} metadata version differs") unless metadata_version == '0'
      substreams = File.binread(substreams_path).force_encoding(Encoding::UTF_8)
      logical = substreams.lines.map do |line|
        next unless line.start_with?("\t")
        line.strip.sub(/\A\*\s*/, '')
      end.compact
      fail!("#{label} has duplicate logical substreams") unless logical.uniq == logical
      filenames = Dir.children(path).sort
      compressed_marks = filenames.grep(/mrk/).reject { |entry| entry.end_with?('.mrk2') }
      expected_stream_files = logical.flat_map do |name|
        stem = JsonArrayStorageW183.stream_hash(name)
        ["#{stem}.bin", "#{stem}.mrk2"]
      end.sort
      actual_stream_files = filenames.select { |name| name.end_with?('.bin', '.mrk2') }.sort
      fail!("#{label} hashed stream files differ from substream roster") unless actual_stream_files == expected_stream_files
      fail!("#{label} has compressed mark files outside the admitted plain .mrk2 profile") unless compressed_marks.empty?
      fail!("#{label} row count file differs") unless File.read(count_path).strip == '8'
      mark_triples = logical.to_h do |name|
        mark_name = "#{JsonArrayStorageW183.stream_hash(name)}.mrk2"
        values = File.binread(File.join(path, mark_name)).unpack('Q<*')
        fail!("#{label} #{name} has malformed plain mark triples") unless (values.size % 3).zero?
        [name, values.each_slice(3).map(&:dup)]
      end
      fail!("#{label} physical streams disagree on terminal mark count") unless
        mark_triples.values.all? { |triples| triples.size == 5 }
      validate_plain_tree!(path)
      {
        label: label, part_name: part[:name], part_path: path, part_type: part[:part_type],
        rows: part[:rows], marks: part[:marks], count_text: File.read(count_path).strip,
        metadata_version: metadata_version, default_compression_codec: codec_text,
        serialization_json_sha256: Digest::SHA256.hexdigest(serialization_text),
        ordinary_string_serialization_version: string_version,
        columns_text: File.read(columns_path), columns_substreams_text: substreams,
        logical_substreams: logical, physical_file_names: filenames,
        mark_triples: mark_triples,
        stream_file_inventory: actual_stream_files.to_h do |filename|
          [filename, {size: File.size(File.join(path, filename)), sha256: Digest::SHA256.file(File.join(path, filename)).hexdigest}]
        end,
        checksums_bytes: File.size(checksums_path), checksums_sha256: Digest::SHA256.file(checksums_path).hexdigest,
        hashed_stream_files: actual_stream_files, plain_mrk2_only: true,
      }
    end

    def assert_site_rosters!(mixed, empty, root)
      %w[a.size0 a.t a.object_shared_data.size1 a.object_shared_data%2Epaths a.object_shared_data%2Evalues a.object_structure].each do |name|
        fail!("stock Array(JSON) missing physical site stream #{name}") unless mixed[:logical_substreams].include?(name)
      end
      fail!('all-empty Array(JSON) did not retain its typed and wrapper size lanes') unless
        %w[a.size0 a.t].all? { |name| empty[:logical_substreams].include?(name) }
      fail!('root JSON typed control is missing its root typed or size0 lane') unless
        root[:logical_substreams].include?('j.t') && root[:logical_substreams].include?('j.object_shared_data.size0')
      fail!('root JSON control unexpectedly acquired nested Array size1 lane') if root[:logical_substreams].include?('j.object_shared_data.size1')
      expected_marks = [2, 2, 2, 2, 0]
      [[mixed, 'a.size0'], [empty, 'a.size0'], [root, 'j.object_shared_data.size0']].each do |part, stream|
        fail!("#{part[:label]} #{stream} terminal/outer mark grid differs") unless
          part[:mark_triples][stream]&.map { |triple| triple[2] } == expected_marks
      end
      fail!('nested shared MAP lane was serialized as a root size0 site') if mixed[:logical_substreams].include?('a.object_shared_data.size0')
    end

    def assert_library_roster!(part, crystal)
      streams = part[:logical_substreams]
      %w[a.size0 a.t a.object_shared_data.size1 a.object_shared_data%2Epaths a.object_shared_data%2Evalues a.object_structure].each do |name|
        fail!("library Array(JSON) missing physical site stream #{name}") unless streams.include?(name)
      end
      fail!('library shared MAP acquired the root JSON size0 role') if streams.include?('a.object_shared_data.size0')
      fail!('library Array(JSON) wrapper mark grid differs') unless part[:mark_triples]['a.size0']&.map { |triple| triple[2] } == [2, 2, 2, 2, 0]
      record = crystal.fetch(:data).fetch('library_part')
      array_streams = streams.select { |name| name.start_with?('a.') }
      reader_streams = record.fetch('physical_stream_names')
      fail!('library helper roster and published Array(JSON) roster differ') unless (array_streams - reader_streams).empty? &&
        (reader_streams - array_streams).empty?
    end

    def assert_attached_native!(native)
      expected_checks = {'library_target' => ["all_1_1_0\t1\t"]}
      fail!("stock CHECK rejected or failed the library-written part: #{native[:checks].inspect}") unless native[:checks] == expected_checks
      expected_schema = [['library_target', 'pk', 'UInt64'], ['library_target', 'a', ARRAY_JSON]]
      fail!("attached library schema differs: #{native[:schemas].inspect}") unless native[:schemas] == expected_schema
      assert_array_rows!(native[:rows], 'library_target', MIXED, EXPECTED_MIXED_ROWS)
      assert_array_rows!(native[:middle_rows], 'library_target', MIXED.select { |row| (3..6).cover?(row[:pk]) },
                         EXPECTED_MIXED_ROWS[2, 4])
      part = native[:parts]['library_target'] || fail!('stock did not publish the attached library part')
      fail!('stock attached a different part identity or physical layout') unless part[:name] == 'all_1_1_0' && part[:part_type] == 'Wide' && part[:rows] == '8' && part[:marks] == '5'
    end

    def attach_part!(library_part, data_path)
      detached = File.join(data_path, 'detached')
      ensure_plain_directory_chain!(data_path)
      FileUtils.mkdir_p(detached, mode: 0o700) unless File.directory?(detached)
      fail!('ClickHouse detached directory is symlinked') if File.symlink?(detached)
      destination = File.join(detached, 'all_1_1_0')
      fail!('refusing to overwrite an existing detached part') if File.exist?(destination) || File.symlink?(destination)
      FileUtils.cp_r(library_part, destination, preserve: true)
      validate_plain_tree!(destination)
    end

    def validate_store_path!(path)
      fail!('ClickHouse table data path is absent') unless path && !path.empty?
      full = File.expand_path(path)
      store = File.join(@root, 'stores', 'native')
      fail!("table data path escaped its local store: #{path}") unless full.start_with?(store + File::SEPARATOR)
      ensure_plain_directory_chain!(full)
      full
    end

    def ensure_plain_directory_chain!(path)
      full = File.expand_path(path)
      current = File::SEPARATOR
      full.delete_prefix(File::SEPARATOR).split(File::SEPARATOR).each do |component|
        current = File.join(current, component)
        next unless File.exist?(current) || File.symlink?(current)
        fail!("symlink in ClickHouse part path: #{current}") if File.lstat(current).symlink?
        fail!("non-directory in ClickHouse part path: #{current}") unless File.directory?(current)
      end
    end

    def validate_part_path!(path)
      fail!('reported part path is absent') unless path && !path.empty?
      full = File.expand_path(path)
      store = File.join(@root, 'stores', 'native')
      fail!("part path escaped native evidence store: #{path}") unless full.start_with?(store + File::SEPARATOR)
      validate_plain_tree!(full)
      File.realpath(full)
    end

    def validate_library_part_path!(path)
      fail!('library part path is absent') unless path && !path.empty?
      expected = File.join(@root, 'parts', 'library_1_1_0')
      full = File.expand_path(path)
      fail!("library part escaped its exact task-local destination: #{path}") unless full == expected
      fail!('library part destination is absent or not a directory') unless File.directory?(full)
      validate_plain_tree!(full)
      File.realpath(full)
    end

    def validate_plain_tree!(path)
      Find.find(path) do |entry|
        stat = File.lstat(entry)
        fail!("symlink in part evidence: #{entry}") if stat.symlink?
        fail!("non-regular part entry: #{entry}") unless stat.directory? || stat.file?
      end
    end

    def write_summary(data)
      summary = {
        probe: 'W185 paired persisted Array(JSON) stock/Crystal qualification',
        status: data[:status], fatal_error: data[:fatal_error],
        runtime: {path: @binary, expected_sha256: BINARY_SHA256, sha256_before: @sha_before,
                  sha256_after: @sha_after, expected_version: VERSION, expected_build: BUILD},
        helper: @crystal_probe,
        limits: {max_threads: 1, local_max_memory_usage_bytes: MEMORY,
                 required_outer_run_safe_memory_limit_bytes: OUTER_RUN_SAFE_LIMIT,
                 timeout_seconds: TIMEOUT, termination_grace_seconds: GRACE,
                 executor: 'JsonBinaryKernelW180Probe#execute'},
        settings: SETTINGS, evidence_root: @root, invocations: @invocations,
      }.merge(data.reject { |key, _| %i[status fatal_error].include?(key) })
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      write_new(File.join(@root, 'summary.md'), [
        '# W185 paired persisted Array(JSON) qualification', '',
        "Status: `#{summary[:status]}`", '',
        'The stock-written part is consumed through the Crystal ArrayObject reader and table batch. A separately library-written part is attached to the pinned stock runtime and checked with literal rows. The profile includes typed UInt8 `t`, a non-empty shared MAP String path, all-empty parent rows, a zero-child intermediate mark, and a zero-child trailing mark.', '',
        "Runtime: #{VERSION} / #{BUILD} / SHA256 `#{@sha_before}`", '',
        'The runner uses the W180 bounded process executor, pins the native binary before and after each native call, and records exact argv/stdin/stdout/stderr hashes. Runtime errors remain failures/indeterminate and are never treated as expected format rejection.', '',
        "Evidence root: `#{@root}`", '',
      ].join("\n"))
    end

    def write_new(path, bytes)
      fail!("refusing to overwrite evidence: #{path}") if File.exist?(path) || File.symlink?(path)
      File.open(path, 'wbx', 0o600) { |file| file.write(bytes) }
    end

    def fail!(message)
      raise RuntimeError, "W185 Array(JSON) paired oracle: #{message}"
    end
  end
end

def main
  options = {binary: CheckArrayJSONPartsW185::BINARY}
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/check_array_json_parts_w185.rb --evidence-root EMPTY_CHILD_OF_PRIVATE_TMP --crystal-probe PREBUILT_HELPER [--binary CLICKHOUSE]'
    parser.on('--binary PATH') { |value| options[:binary] = value }
    parser.on('--crystal-probe PATH') { |value| options[:crystal_probe] = value }
    parser.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
  end.parse!
  raise 'prebuilt Crystal helper is required via --crystal-probe' unless options[:crystal_probe]
  exit(CheckArrayJSONPartsW185::Probe.new(options[:binary], options[:crystal_probe], options[:evidence_root]).run ? 0 : 1)
rescue StandardError => error
  warn "W185 probe runner error: #{error.class}: #{error.message}"
  exit 1
end

main if $PROGRAM_NAME == __FILE__
