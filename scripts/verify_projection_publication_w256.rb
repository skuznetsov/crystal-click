#!/usr/bin/env ruby
# Bounded stock-to-library precomputed projection publication witness.
# This runner consumes only supplied executables; it does not build either.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require_relative 'check_array_json_parts_w185'

module VerifyProjectionPublicationW256
  W185 = CheckArrayJSONPartsW185
  W180 = JsonBinaryKernelW180Probe
  VERSION = '26.10.1.1201'.freeze
  BUILD = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  BINARY_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  MEMORY = 536_870_912
  TIMEOUT = 10
  GRACE = 2
  OUTER_RUN_SAFE_LIMIT = 12 * 1024 * 1024 * 1024
  MAX_PART_FILES = 256
  MAX_PART_BYTES = 16 * 1024 * 1024
  MAX_ROW_ARRAY_ELEMENTS = 64
  HELPER_FORMAT = 'projection_publication_w256_helper_v1'.freeze
  STATUS = 'paired_projection_publication_observed'.freeze
  TABLES = %w[source_projection library_projection].freeze
  PROJECTION = 'by_score'.freeze
  KEY_NAME = 'id'.freeze
  SCORE_NAME = 'score'.freeze
  LABEL_NAME = 'label'.freeze
  ITEMS_NAME = 'items'.freeze
  PARENT_MARK_ROWS = [2, 2, 2].freeze
  LIBRARY_PROJECTION_MARK_ROWS = [3, 3].freeze
  SETTINGS = [
    'index_granularity=2', 'index_granularity_bytes=10485760',
    'enable_mixed_granularity_parts=1', 'min_rows_for_wide_part=0',
    'min_bytes_for_wide_part=0', 'compress_marks=0', 'compress_primary_key=0',
    'min_compress_block_size=0', 'max_compress_block_size=4096',
    'ratio_of_defaults_for_sparse_serialization=1',
    'propagate_types_serialization_versions_to_nested_types=true',
    "serialization_info_version='with_types'",
    "default_compression_codec='LZ4'", "string_serialization_version='with_size_stream'",
  ].join(', ').freeze

  # Independent source/native literals. Do not derive these from helper JSON.
  ROWS = [
    {id: 1, score: 50, label: "a\0b", items: [1, 2]},
    {id: 2, score: 10, label: '', items: []},
    {id: 3, score: 40, label: 'café', items: [3]},
    {id: 4, score: 20, label: "z\0", items: [2, 4]},
    {id: 5, score: 60, label: 'é', items: []},
    {id: 6, score: 30, label: 'hi', items: [6, 7]},
  ].map(&:freeze).freeze
  SCORE_ROWS = ROWS.sort_by { |row| row[:score] }.freeze
  EXPECTED_COLUMNS = [
    ['id', 'UInt64'], ['score', 'UInt64'], ['label', 'String'], ['items', 'Array(UInt16)'],
  ].freeze
  EXPECTED_PROJECTION_COLUMNS = [
    ['score', 'UInt64'], ['id', 'UInt64'], ['label', 'String'], ['items', 'Array(UInt16)'],
  ].freeze

  class RowBinaryReader
    attr_reader :offset

    def initialize(bytes)
      @bytes = bytes.b
      @offset = 0
    end

    def uint64
      read_bytes(8).unpack1('Q<')
    end

    def string
      read_bytes(varuint)
    end

    def uint16_array
      count = varuint
      raise 'RowBinary Array(UInt16) count exceeds fixture bound' if count > MAX_ROW_ARRAY_ELEMENTS
      Array.new(count) { read_bytes(2).unpack1('v') }
    end

    def varuint
      value = 0
      shift = 0
      10.times do
        byte = byte_at
        payload = byte & 0x7f
        raise 'RowBinary VarUInt overflow' if shift == 63 && payload > 1
        value |= payload << shift
        return value if (byte & 0x80).zero?
        shift += 7
      end
      raise 'unterminated RowBinary VarUInt'
    end

    def eof?
      @offset == @bytes.bytesize
    end

    private

    def byte_at
      raise 'truncated RowBinary value' if @offset >= @bytes.bytesize
      byte = @bytes.getbyte(@offset)
      @offset += 1
      byte
    end

    def read_bytes(length)
      raise 'negative RowBinary length' if length.negative?
      finish = @offset + length
      raise 'truncated RowBinary value' if finish > @bytes.bytesize
      bytes = @bytes.byteslice(@offset, length).to_s.b
      @offset = finish
      bytes
    end
  end

  class Probe
    def initialize(binary, helper, evidence_root, helper_mode)
      @binary = validate_executable(binary, 'ClickHouse')
      @helper = validate_executable(helper, 'prebuilt Crystal helper')
      @root = validate_root(evidence_root)
      fail!('helper mode must be debug or release') unless %w[debug release].include?(helper_mode)
      @helper_mode = helper_mode
      @store = File.join(@root, 'stores', 'native')
      @library_part = File.join(@root, 'generated', 'all_1_1_0')
      @invocations = []
      @source_snapshots = {}
      @native_part_snapshots = {}
      @status = 'not_started'
      @fatal_error = nil
    end

    def run
      prepare_layout!
      @binary_sha_before = binary_sha
      @helper_sha_before = helper_sha
      fail!('pinned ClickHouse executable SHA-256 mismatch before probe') unless @binary_sha_before == BINARY_SHA256
      write_new(File.join(@root, 'inputs', 'source.rowbinary'), rowbinary_source)

      initial = run_native('native_sources', initial_sql)
      assert_native_process!(initial)
      initial_state = parse_native(initial[:stdout])
      assert_pin!(initial_state)
      source_paths = assert_native_state!(initial_state, ['source_projection'], :source, data_path_tables: TABLES)
      source_parent = source_paths.fetch('source_projection')
      @source_snapshots[source_parent] = snapshot_tree(source_parent, allow_projection_child: true)
      native_parent_rows = query_rowbinary('source_parent_rows', parent_query('source_projection', 'id'))
      native_projection_rows = query_rowbinary('source_projection_rows', projection_query('source_projection'))
      assert_rows!(native_parent_rows, ROWS, 'stock parent')
      assert_rows!(native_projection_rows, SCORE_ROWS, 'stock projection')

      helper_output = run_helper(source_parent)
      validate_helper_output!(helper_output)
      @generated_snapshot = snapshot_tree(@library_part, allow_projection_child: true)

      library_data_path = initial_state.fetch(:data_paths).fetch('library_projection')
      attach_generated_part!(library_data_path)
      attached = run_native('native_attach_check', attached_sql)
      assert_native_process!(attached)
      attached_state = parse_native(attached[:stdout])
      assert_pin!(attached_state)
      attached_paths = assert_native_state!(attached_state, TABLES, :attached)
      attached_paths.each do |table, part_path|
        @native_part_snapshots[table] = snapshot_tree(part_path, allow_projection_child: true)
      end

      library_parent_rows = query_rowbinary('library_parent_rows', parent_query('library_projection', 'id'))
      library_projection_rows = query_rowbinary('library_projection_rows', projection_query('library_projection'))
      forced_projection_rows = query_rowbinary('forced_projection_rows', forced_projection_query)
      assert_rows!(library_parent_rows, ROWS, 'attached library parent')
      assert_rows!(library_projection_rows, SCORE_ROWS, 'library projection table function')
      assert_rows!(forced_projection_rows, SCORE_ROWS, 'forced projection SELECT')
      explain = run_native('forced_projection_explain', explain_projection_query)
      assert_native_process!(explain)
      @explain_witness = assert_explain_projection_read!(explain[:stdout])

      fail!('stock source part changed during probe') unless snapshot_tree(source_parent, allow_projection_child: true) == @source_snapshots.fetch(source_parent)
      fail!('generated parent/projection bytes changed during attach') unless snapshot_tree(@library_part, allow_projection_child: true) == @generated_snapshot
      @binary_sha_after = binary_sha
      @helper_sha_after = helper_sha
      fail!('pinned ClickHouse executable SHA changed during probe') unless @binary_sha_after == BINARY_SHA256
      fail!('prebuilt Crystal helper SHA changed during probe') unless @helper_sha_after == @helper_sha_before

      write_summary(
        status: STATUS, initial_native: initial_state, attached_native: attached_state,
        source_parent_snapshot: @source_snapshots.fetch(source_parent),
        generated_parent_snapshot: @generated_snapshot, native_attached_snapshots: @native_part_snapshots,
        native_values: {
          source_parent: native_parent_rows, source_projection: native_projection_rows,
          library_parent: library_parent_rows, library_projection: library_projection_rows,
          forced_projection: forced_projection_rows,
        }, helper_output: helper_output, explain_witness: @explain_witness,
      )
      puts "W256 status=#{STATUS}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @binary_sha_after = binary_sha rescue nil
      @helper_sha_after = helper_sha rescue nil
      write_summary(status: 'runner_failure_or_observations_differ', fatal_error: @fatal_error) rescue nil
      warn "W256 probe failure (process failure is not format evidence): #{@fatal_error}"
      false
    end

    private

    def validate_root(path)
      fail!('evidence root is required') unless path && !path.empty?
      full = File.expand_path(path)
      fail!('evidence root must be a direct child of /private/tmp') unless File.dirname(full) == File.realpath('/private/tmp')
      fail!('evidence root must be an existing empty non-symlink directory') unless
        File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full && Dir.children(full).empty?
      full
    rescue Errno::ENOENT
      fail!('evidence root must already exist')
    end

    def validate_executable(path, label)
      fail!("#{label} path is required") unless path && !path.empty?
      full = File.expand_path(path)
      fail!("#{label} is missing, non-executable, or symlinked") unless
        File.file?(full) && File.executable?(full) && !File.symlink?(full)
      full
    end

    def prepare_layout!
      %w[invocations inputs stores generated].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(@store, 0o700)
    end

    def binary_sha
      Digest::SHA256.file(@binary).hexdigest
    end

    def helper_sha
      Digest::SHA256.file(@helper).hexdigest
    end

    def run_native(label, sql)
      input = sql.b
      write_new(File.join(@root, 'invocations', "#{label}.stdin.sql"), input)
      before = binary_sha
      fail!('pinned ClickHouse executable SHA-256 mismatch before native invocation') unless before == BINARY_SHA256
      argv = [@binary, 'local', '--path', @store, '--session_timezone=UTC', '--max_threads=1',
              "--max_memory_usage=#{MEMORY}", '--multiquery']
      run_process(label, argv, input, 'clickhouse local', BINARY_SHA256, @binary, before)
    end

    def run_helper(source_part)
      fail!('helper destination unexpectedly exists') if File.exist?(@library_part) || File.symlink?(@library_part)
      before = helper_sha
      invocation = run_process('crystal_helper', [@helper, source_part, @library_part], ''.b,
                               'prebuilt Crystal helper', before, @helper, before)
      fail!('Crystal helper process failed; not native format evidence') unless successful?(invocation)
      fail!('Crystal helper emitted stderr') unless invocation[:stderr].empty?
      fail!('Crystal helper emitted more than one JSON record') unless invocation[:stdout].lines.size == 1
      JSON.parse(invocation[:stdout])
    end

    def run_process(label, argv, input, process_kind, expected_sha, sha_path, before_sha)
      executor = W180.allocate
      stdout, stderr, status, timed_out, spawn_error, stdin_error, stdout_error, stderr_error =
        executor.send(:execute, argv, input)
      after_sha = sha_path ? Digest::SHA256.file(sha_path).hexdigest : nil
      classification = executor.send(:process_classification, status, timed_out, spawn_error,
                                     stdin_error, stdout_error, stderr_error, stderr)
      record = {
        process_kind: process_kind, argv: argv,
        argv_sha256: Digest::SHA256.hexdigest(JSON.pretty_generate(argv) + "\n"),
        stdin_bytes: input.bytesize, stdin_sha256: Digest::SHA256.hexdigest(input),
        exit: status&.exitstatus, signal: status&.termsig, timed_out: timed_out,
        timeout_seconds: TIMEOUT, termination_grace_seconds: GRACE,
        max_threads: 1, max_memory_usage_bytes: process_kind == 'clickhouse local' ? MEMORY : nil,
        max_memory_usage_applicable: process_kind == 'clickhouse local',
        required_outer_run_safe_memory_limit_bytes: OUTER_RUN_SAFE_LIMIT,
        expected_binary_sha256: expected_sha, binary_sha_before: before_sha, binary_sha_after: after_sha,
        spawn_error: spawn_error, stdin_write_error: stdin_error, stdout_read_error: stdout_error,
        stderr_read_error: stderr_error, process_classification: classification,
        stdout_bytes: stdout.bytesize, stdout_sha256: Digest::SHA256.hexdigest(stdout),
        stderr_bytes: stderr.bytesize, stderr_sha256: Digest::SHA256.hexdigest(stderr),
        stdout_file: "#{label}.stdout", stderr_file: "#{label}.stderr",
        stdin_file: process_kind == 'clickhouse local' ? "#{label}.stdin.sql" : nil,
      }
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

    def assert_native_process!(invocation)
      fail!('process did not exit successfully') unless successful?(invocation)
      fail!('ClickHouse stderr contains server or system failure') if
        W180::CLICKHOUSE_EXCEPTION.match?(invocation[:stderr]) || W180::SYSTEM_FAILURE.match?(invocation[:stderr])
      fail!('process wrote unclassified stderr') unless invocation[:stderr].empty?
    end

    def initial_sql
      statements = [
        "SELECT '__W256_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
      ]
      TABLES.each { |table| statements << create_table_sql(table) }
      path = File.join(@root, 'inputs', 'source.rowbinary').gsub('\\') { '\\\\' }.gsub("'") { "\\'" }
      statements << "INSERT INTO default.source_projection SELECT * FROM file('#{path}', 'RowBinary', 'id UInt64, score UInt64, label String, items Array(UInt16)');"
      statements << check_sql('source_projection')
      statements.concat(metadata_sql(['source_projection'], data_path_tables: TABLES))
      statements.join("\n") + "\n"
    end

    def create_table_sql(table)
      "CREATE TABLE default.#{table} (id UInt64, score UInt64, label String, items Array(UInt16), PROJECTION #{PROJECTION} (SELECT score, id, label, items ORDER BY score)) ENGINE=MergeTree ORDER BY id SETTINGS #{SETTINGS};"
    end

    def attached_sql
      statements = [
        "SELECT '__W256_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
        "ALTER TABLE default.library_projection ATTACH PART 'all_1_1_0';",
      ]
      TABLES.each { |table| statements << check_sql(table) }
      statements.concat(metadata_sql(TABLES))
      statements.join("\n") + "\n"
    end

    def check_sql(table)
      [
        "SELECT '__W256_CHECK_BEGIN__', '#{table}' FORMAT TSVRaw;",
        "CHECK TABLE default.#{table} FORMAT TSV;",
        "SELECT '__W256_CHECK_END__', '#{table}' FORMAT TSVRaw;",
      ].join("\n")
    end

    def metadata_sql(tables, data_path_tables: tables)
      list = tables.map { |table| "'#{table}'" }.join(',')
      data_path_list = data_path_tables.map { |table| "'#{table}'" }.join(',')
      [
        "SELECT '__W256_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{list}) ORDER BY table, position FORMAT TSVRaw;",
        "SELECT '__W256_DATA_PATH__', name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name IN (#{data_path_list}) ORDER BY name FORMAT TSVRaw;",
        "SELECT '__W256_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table IN (#{list}) AND active ORDER BY table,name FORMAT TSVRaw;",
        "SELECT '__W256_PROJECTION_PART__', table, name, parent_name, part_type, parent_part_type, toString(active), toString(marks), toString(rows), toString(parent_marks), toString(parent_rows), path FROM system.projection_parts WHERE database='default' AND table IN (#{list}) AND active ORDER BY table,name FORMAT TSVRaw;",
      ]
    end

    def parent_query(table, order_by)
      "SELECT id, score, label, items FROM default.#{table} ORDER BY #{order_by} FORMAT RowBinary;"
    end

    def projection_query(table)
      "SELECT id, score, label, items FROM mergeTreeProjection('default', '#{table}', '#{PROJECTION}') ORDER BY score FORMAT RowBinary;"
    end

    def forced_projection_query
      "SELECT id, score, label, items FROM default.library_projection ORDER BY score SETTINGS force_optimize_projection=1, force_optimize_projection_name='#{PROJECTION}' FORMAT RowBinary;"
    end

    def explain_projection_query
      "EXPLAIN json=1, description=1, projections=1 SELECT id, score, label, items FROM default.library_projection ORDER BY score SETTINGS force_optimize_projection=1, force_optimize_projection_name='#{PROJECTION}' FORMAT JSONEachRow;"
    end

    def query_rowbinary(label, sql)
      invocation = run_native(label, sql)
      assert_native_process!(invocation)
      reader = RowBinaryReader.new(invocation[:stdout])
      rows = Array.new(ROWS.size) do
        {id: reader.uint64, score: reader.uint64, label: reader.string.force_encoding(Encoding::UTF_8), items: reader.uint16_array}
      end
      fail!("#{label} RowBinary has trailing bytes") unless reader.eof?
      rows
    end

    def expected_helper_rows(rows)
      rows.map { |row| [row[:id], row[:score], row[:label], row[:items]] }
    end

    def validate_helper_side!(side, expected_rows, expected_grid, expected_schema, semantic_origin, label)
      fail!("#{label} helper side is not an object") unless side.is_a?(Hash)
      fail!("#{label} helper schema differs") unless side['schema'] == expected_schema.map { |name, type| {'name' => name, 'type' => type} }
      fail!("#{label} helper row count differs") unless side['row_count'] == expected_rows.size
      fail!("#{label} helper mark schedule differs") unless side['mark_row_counts'] == expected_grid
      fail!("#{label} helper semantic rows differ from independent literals") unless side['rows'] == expected_helper_rows(expected_rows)
      fail!("#{label} helper semantic origin differs") unless side['semantic_origin'] == semantic_origin
    end

    def validate_helper_output!(data)
      fail!('helper output is not an object') unless data.is_a?(Hash)
      fail!('helper output format differs') unless data['format'] == HELPER_FORMAT
      fail!('helper status is not observed') unless data['status'] == 'observed'
      validate_helper_side!(data['source_parent'], ROWS, PARENT_MARK_ROWS, EXPECTED_COLUMNS, 'stock-authored', 'source parent')
      validate_helper_side!(data['source_projection'], SCORE_ROWS, PARENT_MARK_ROWS, EXPECTED_PROJECTION_COLUMNS, 'stock-authored', 'source projection')
      validate_helper_side!(data['library_parent'], ROWS, PARENT_MARK_ROWS, EXPECTED_COLUMNS, 'library-generated', 'library parent')
      validate_helper_side!(data['library_projection'], SCORE_ROWS, LIBRARY_PROJECTION_MARK_ROWS, EXPECTED_PROJECTION_COLUMNS, 'library-generated', 'library projection')
      fail!('helper library path differs from fixed generated destination') unless File.expand_path(data['library_part_path']) == @library_part
      summary = data['projection_summary']
      fail!('helper projection summary entry differs') unless summary.is_a?(Hash) && summary['entry'] == "#{PROJECTION}.proj"
      child_path = File.join(@library_part, "#{PROJECTION}.proj")
      child_snapshot = snapshot_tree(child_path)
      fail!('helper child inventory differs from generated projection directory') unless
        summary['child_file_names'] == child_snapshot.select { |entry| entry[:type] == 'file' }.map { |entry| File.basename(entry[:path]) }.sort
      fail!('helper summary physical size is not a nonnegative integer') unless summary['physical_size'].is_a?(Integer) && summary['physical_size'] >= 0
      hash_words = summary['file_hash']
      valid_hash_words = hash_words.is_a?(Array) && hash_words.size == 2 && hash_words.all? { |word|
        word.is_a?(String) && word.match?(/\A(?:0|[1-9][0-9]*)\z/) &&
          (word.length < 20 || (word.length == 20 && word <= '18446744073709551615'))
      }
      fail!('helper summary hash must have two canonical unsigned 64-bit decimal words') unless valid_hash_words
      @helper_summary = summary
    end

    def parse_native(stdout)
      lines = stdout.dup.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      fail!('native metadata stdout is not valid UTF-8') unless lines.all?(&:valid_encoding?)
      tags = %w[__W256_PIN__ __W256_SCHEMA__ __W256_DATA_PATH__ __W256_PART__ __W256_PROJECTION_PART__ __W256_CHECK_BEGIN__ __W256_CHECK_END__]
      unknown = lines.select { |line| line.start_with?('__W256_') && tags.none? { |tag| line.start_with?("#{tag}\t") } }
      fail!("unknown native marker rows: #{unknown.inspect}") unless unknown.empty?
      rows = ->(tag) { lines.select { |line| line.start_with?("#{tag}\t") }.map { |line| line.split("\t", -1) } }
      checks = {}
      current = nil
      lines.each do |line|
        if line.start_with?("__W256_CHECK_BEGIN__\t")
          fields = line.split("\t", -1)
          fail!('malformed/nested CHECK begin marker') unless fields.size == 2 && current.nil?
          current = fields[1]
          fail!('duplicate CHECK marker') if checks.key?(current)
          checks[current] = []
        elsif line.start_with?("__W256_CHECK_END__\t")
          fields = line.split("\t", -1)
          fail!('malformed/unmatched CHECK end marker') unless fields.size == 2 && current == fields[1]
          current = nil
        elsif current
          checks.fetch(current) << line
        end
      end
      fail!('unterminated CHECK marker') unless current.nil?
      parts = rows.call('__W256_PART__').map do |fields|
        fail!('malformed system.parts marker') unless fields.size == 7
        {table: fields[1], name: fields[2], path: fields[3], part_type: fields[4], rows: fields[5], marks: fields[6]}
      end
      projection_parts = rows.call('__W256_PROJECTION_PART__').map do |fields|
        fail!('malformed system.projection_parts marker') unless fields.size == 12
        {table: fields[1], name: fields[2], parent_name: fields[3], part_type: fields[4], parent_part_type: fields[5], active: fields[6], marks: fields[7], rows: fields[8], parent_marks: fields[9], parent_rows: fields[10], path: fields[11]}
      end
      data_path_rows = rows.call('__W256_DATA_PATH__').map do |fields|
        fail!('malformed system.tables data path marker') unless fields.size == 3
        {table: fields[1], path: fields[2]}
      end
      data_path_names = data_path_rows.map { |entry| entry[:table] }
      fail!('duplicate system.tables data path marker') unless data_path_names.uniq == data_path_names
      {
        pin: rows.call('__W256_PIN__').map { |fields| fields.drop(1) },
        schemas: rows.call('__W256_SCHEMA__').map { |fields| fields.drop(1) },
        data_paths: data_path_rows.to_h { |entry| [entry[:table], entry[:path]] },
        parts: parts.to_h { |part| [part[:table], part] },
        projection_parts: projection_parts.to_h { |part| [part[:table], part] }, checks: checks,
      }
    end

    def assert_pin!(native)
      fail!('native runtime pin differs') unless native[:pin] == [[VERSION, BUILD]]
    end

    def assert_native_state!(native, expected_tables, phase, data_path_tables: nil)
      expected_tables = expected_tables.sort
      data_path_tables = (data_path_tables || expected_tables).sort
      expected_schema = expected_tables.flat_map do |table|
        EXPECTED_COLUMNS.map { |name, type| [table, name, type] }
      end
      fail!("#{phase} exact system.columns roster differs") unless native[:schemas] == expected_schema
      expected_checks = expected_tables.to_h { |table| [table, ["all_1_1_0\t1\t"]] }
      fail!("#{phase} CHECK result differs") unless native[:checks] == expected_checks
      fail!("#{phase} system.parts roster differs") unless native[:parts].keys.sort == expected_tables
      fail!("#{phase} system.projection_parts roster differs") unless native[:projection_parts].keys.sort == expected_tables
      paths = {}
      expected_tables.each do |table|
        part = native[:parts].fetch(table)
        fail!("#{phase} #{table} parent part identity/layout differs") unless
          part[:name] == 'all_1_1_0' && part[:part_type] == 'Wide' && part[:rows] == '6' && part[:marks] == '4'
        paths[table] = validate_native_part_path!(part[:path])
        projection = native[:projection_parts].fetch(table)
        child_marks = table == 'source_projection' ? '4' : '3'
        fail!("#{phase} #{table} projection-part schedule or ownership differs") unless
          projection[:name] == PROJECTION && projection[:parent_name] == 'all_1_1_0' &&
          projection[:part_type] == 'Wide' && projection[:parent_part_type] == 'Wide' && projection[:active] == '1' &&
          projection[:marks] == child_marks && projection[:rows] == '6' &&
          projection[:parent_marks] == '4' && projection[:parent_rows] == '6'
        projected_path = File.expand_path(projection[:path])
        fail!("#{phase} #{table} projection path escaped its parent part") unless
          projected_path == File.join(paths.fetch(table), "#{PROJECTION}.proj") || projected_path.start_with?(File.join(paths.fetch(table), "#{PROJECTION}.proj") + File::SEPARATOR)
        validate_plain_tree!(projected_path)
      end
      fail!("#{phase} exact system.tables data path roster differs") unless native[:data_paths].keys.sort == data_path_tables
      data_path_tables.each do |table|
        validate_store_directory!(native[:data_paths].fetch(table))
      end
      paths
    end

    def validate_native_part_path!(path)
      full = File.expand_path(path)
      fail!('native part path escaped task store') unless full.start_with?(@store + File::SEPARATOR)
      fail!('native part path is absent or noncanonical') unless File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full
      validate_plain_tree!(full, allow_projection_child: true)
      full
    end

    def validate_store_directory!(path)
      full = File.expand_path(path)
      fail!('system.tables data path escaped task store') unless full.start_with?(@store + File::SEPARATOR)
      ensure_plain_chain!(full)
      fail!('system.tables data path is absent or noncanonical') unless File.directory?(full) && File.realpath(full) == full
      full
    end

    def attach_generated_part!(table_data_path)
      full = validate_store_directory!(table_data_path)
      detached = File.join(full, 'detached')
      if File.exist?(detached) || File.symlink?(detached)
        fail!('detached directory is a symlink or non-directory') unless File.directory?(detached) && !File.symlink?(detached)
      else
        Dir.mkdir(detached, 0o700)
      end
      destination = File.join(detached, 'all_1_1_0')
      fail!('detached part destination already exists') if File.exist?(destination) || File.symlink?(destination)
      FileUtils.cp_r(@library_part, destination, preserve: true)
      validate_plain_tree!(destination, allow_projection_child: true)
    end

    def assert_rows!(actual, expected, label)
      fail!("#{label} raw RowBinary values differ from independent literals") unless actual == expected
    end

    def assert_explain_projection_read!(stdout)
      lines = stdout.dup.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      fail!('EXPLAIN output is not valid UTF-8') unless lines.all?(&:valid_encoding?)
      parsed = []
      lines.each do |line|
        begin
          parsed << JSON.parse(line)
        rescue JSON::ParserError
          next
        end
      end
      fail!('EXPLAIN did not emit a JSON plan row') if parsed.empty?
      objects = []
      walk_json(parsed) do |object|
        objects << object if object.is_a?(Hash)
      end
      readers = objects.select { |object| object['Node Type'] == 'ReadFromMergeTree' }
      fail!('EXPLAIN must contain exactly one ReadFromMergeTree step') unless readers.size == 1
      reader = readers.first
      fail!('EXPLAIN ReadFromMergeTree description differs from the selected projection') unless reader['Description'] == PROJECTION
      node_id = reader['Node Id']
      fail!('EXPLAIN ReadFromMergeTree node id is absent') unless node_id.is_a?(String) && !node_id.empty?
      {
        read_step_count: readers.size, node_type: reader['Node Type'], node_id: node_id,
        projection_name: PROJECTION, description: reader['Description'],
      }
    end

    def walk_json(value, &block)
      yield value
      case value
      when Hash
        value.each_value { |child| walk_json(child, &block) }
      when Array
        value.each { |child| walk_json(child, &block) }
      when String
        begin
          parsed = JSON.parse(value)
          walk_json(parsed, &block) if parsed.is_a?(Hash) || parsed.is_a?(Array)
        rescue JSON::ParserError
          nil
        end
      end
    end

    def rowbinary_source
      ROWS.map do |row|
        [row[:id], row[:score]].pack('Q<Q<') + wire_string(row[:label]) + wire_varuint(row[:items].size) + row[:items].pack('v*')
      end.join.b
    end

    def wire_string(value)
      bytes = value.b
      wire_varuint(bytes.bytesize) + bytes
    end

    def wire_varuint(value)
      output = +''.b
      loop do
        byte = value & 0x7f
        value >>= 7
        byte |= 0x80 unless value.zero?
        output << byte
        break if value.zero?
      end
      output
    end

    def snapshot_tree(path, allow_projection_child: false)
      inspect_part_tree(path, allow_projection_child: allow_projection_child, include_hashes: true)
    end

    def validate_plain_tree!(path, allow_projection_child: false)
      inspect_part_tree(path, allow_projection_child: allow_projection_child, include_hashes: false)
      true
    end

    def inspect_part_tree(path, allow_projection_child:, include_hashes:)
      full = File.expand_path(path)
      fail!("part tree is missing or symlinked: #{path}") unless File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full
      entries = []
      file_count = 0
      total_bytes = 0
      Find.find(full) do |entry|
        stat = File.lstat(entry)
        fail!("symlink in part tree: #{entry}") if stat.symlink?
        fail!("special entry in part tree: #{entry}") unless stat.directory? || stat.file?
        next if entry == full
        relative = entry.delete_prefix(full + File::SEPARATOR)
        depth = relative.split(File::SEPARATOR).size
        if stat.directory?
          fail!("unexpected nested directory in part tree: #{relative}") unless
            allow_projection_child && depth == 1 && relative == "#{PROJECTION}.proj"
          entries << {path: relative, type: 'directory'}
        else
          max_depth = allow_projection_child && relative.start_with?("#{PROJECTION}.proj#{File::SEPARATOR}") ? 2 : 1
          fail!("part-tree file exceeds admitted depth: #{relative}") if depth > max_depth
          file_count += 1
          total_bytes += stat.size
          fail!('part tree exceeds bounded inventory limits') if file_count > MAX_PART_FILES || total_bytes > MAX_PART_BYTES
          file = {path: relative, type: 'file', size: stat.size}
          file[:sha256] = Digest::SHA256.file(entry).hexdigest if include_hashes
          entries << file
        end
      end
      entries.sort_by { |entry| entry[:path] }
    end

    def ensure_plain_chain!(path)
      current = File::SEPARATOR
      File.expand_path(path).delete_prefix(File::SEPARATOR).split(File::SEPARATOR).each do |component|
        current = File.join(current, component)
        next unless File.exist?(current) || File.symlink?(current)
        fail!("symlink in path: #{current}") if File.lstat(current).symlink?
        fail!("non-directory path component: #{current}") unless File.directory?(current)
      end
    end

    def write_summary(data)
      summary = {
        probe: 'W256 precomputed projection publication interoperability',
        status: data[:status], fatal_error: data[:fatal_error], helper_mode: @helper_mode,
        runtime: {path: @binary, sha256_expected: BINARY_SHA256, sha256_before: @binary_sha_before,
                  sha256_after: @binary_sha_after, version: VERSION, build: BUILD},
        helper: {path: @helper, sha256_before: @helper_sha_before, sha256_after: @helper_sha_after},
        source: {repository: '/private/tmp/clickhouse-w254-upstream.AqeqyC', revision: 'ed30948f095ecb70679986d7d60e27ad770ae27a'},
        limits: {max_threads: 1, local_max_memory_usage_bytes: MEMORY,
                 required_outer_run_safe_memory_limit_bytes: OUTER_RUN_SAFE_LIMIT,
                 timeout_seconds: TIMEOUT, termination_grace_seconds: GRACE,
                 executor: 'JsonBinaryKernelW180Probe#execute'},
        fixture: {rows: ROWS, parent_mark_rows: PARENT_MARK_ROWS,
                  stock_projection_mark_rows: PARENT_MARK_ROWS,
                  library_projection_mark_rows: LIBRARY_PROJECTION_MARK_ROWS,
                  native_system_marks_include_terminal_eof: true,
                  projection_name: PROJECTION, string_serialization_version: 'with_size_stream'},
        invocations: @invocations,
      }.merge(data.reject { |key, _| %i[status fatal_error].include?(key) })
      write_once_or_replace_failure_summary(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      markdown = [
        '# W256 precomputed projection publication', '',
        "Status: `#{summary[:status]}`", '',
        'Scope: one caller-materialized by_score child, generic Wide parent plus projection child, different child granularity, pinned stock ATTACH/CHECK/direct reads/forced projection read. This does not establish SQL projection computation, provenance, freshness, optimizer policy beyond the forced witness, Compact, nested projections, or performance.', '',
        "Runtime: #{VERSION} / #{BUILD} / SHA256 `#{BINARY_SHA256}`", '',
        "Evidence root: `#{@root}`", '',
      ].join("\n")
      write_once_or_replace_failure_summary(File.join(@root, 'summary.md'), markdown)
    end

    def write_once_or_replace_failure_summary(path, bytes)
      if File.exist?(path) || File.symlink?(path)
        fail!('summary path was unexpectedly created before finalization') unless @fatal_error
        File.open(path, 'wb', 0o600) { |file| file.write(bytes) }
      else
        write_new(path, bytes)
      end
    end

    def write_new(path, bytes)
      fail!("refusing to overwrite evidence file: #{path}") if File.exist?(path) || File.symlink?(path)
      File.open(path, 'wbx', 0o600) { |file| file.write(bytes) }
    end

    def fail!(message)
      raise message
    end
  end

  def self.main(arguments)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'usage: verify_projection_publication_w256.rb --clickhouse PINNED --crystal-helper PREBUILT --evidence-root EMPTY_DIRECT_CHILD --helper-mode debug|release'
      opts.on('--clickhouse PATH') { |value| options[:binary] = value }
      opts.on('--crystal-helper PATH') { |value| options[:helper] = value }
      opts.on('--evidence-root PATH') { |value| options[:root] = value }
      opts.on('--helper-mode MODE') { |value| options[:mode] = value }
    end
    parser.parse!(arguments)
    raise OptionParser::MissingArgument, '--clickhouse' unless options[:binary]
    raise OptionParser::MissingArgument, '--crystal-helper' unless options[:helper]
    raise OptionParser::MissingArgument, '--evidence-root' unless options[:root]
    raise OptionParser::MissingArgument, '--helper-mode' unless options[:mode]
    raise OptionParser::InvalidArgument, 'unexpected positional arguments' unless arguments.empty?
    success = Probe.new(options[:binary], options[:helper], options[:root], options[:mode]).run
    exit(success ? 0 : 1)
  rescue OptionParser::ParseError => error
    warn error.message
    warn parser
    exit 64
  end
end

VerifyProjectionPublicationW256.main(ARGV) if $PROGRAM_NAME == __FILE__
