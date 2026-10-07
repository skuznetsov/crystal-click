#!/usr/bin/env ruby
# Bounded stock-created Nested/Array(Tuple) LC+String kernel qualification.
# This runner never builds either executable and does not ATTACH/write a part.
require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require_relative 'check_json_binary_kernel_w180'

module ProbeNestedSpecializedBulkW201
  BINARY = JsonBinaryKernelW180Probe::DEFAULT_BINARY
  SHA256 = JsonBinaryKernelW180Probe::BINARY_SHA256
  VERSION = '26.10.1.1201'.freeze
  BUILD = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  MEMORY = JsonBinaryKernelW180Probe::MEMORY_LIMIT_BYTES
  TIMEOUT = JsonBinaryKernelW180Probe::PROCESS_TIMEOUT_SECONDS
  GRACE = JsonBinaryKernelW180Probe::TERMINATION_GRACE_SECONDS
  NESTED = 'Nested(label LowCardinality(Nullable(String)), text String)'.freeze
  ARRAY = 'Array(Tuple(label LowCardinality(Nullable(String)), text String))'.freeze
  TABLES = %w[nested_single array_single nested_size array_size].freeze
  # Independently-authored source rows: first mark is empty-element arrays;
  # later marks exercise NULL, empty/default, repeated and novel LC/String values.
  ROWS = [
    [1, []], [2, []], [3, [[nil, 'after-empty-null']]],
    [4, [['x', 'repeat'], ['x', '']]],
    [5, [['', 'default-label'], [nil, 'null-again']]], [6, []],
    [7, [['x', 'last']]], [8, [['x', 'repeat'], ['x', 'repeat']]],
  ].freeze
  SETTINGS = [
    'index_granularity=2', 'index_granularity_bytes=10485760',
    'enable_mixed_granularity_parts=1', 'min_rows_for_wide_part=0',
    'min_bytes_for_wide_part=0', 'compress_marks=0', 'compress_primary_key=0',
    'min_compress_block_size=0', 'max_compress_block_size=4096',
    "default_compression_codec='LZ4'", "serialization_info_version='with_types'",
    'propagate_types_serialization_versions_to_nested_types=1',
  ].join(', ').freeze

  class Runner
    def initialize(options)
      @binary = executable(options.fetch(:binary), 'ClickHouse')
      @helper = executable(options.fetch(:helper), 'prebuilt Crystal helper')
      @root = empty_root(options.fetch(:root))
      @executor = JsonBinaryKernelW180Probe.allocate
      %w[invocations stores].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      @store = File.join(@root, 'stores', 'native')
      Dir.mkdir(@store, 0o700)
    end

    def run
      before = sha(@binary)
      fail!('ClickHouse binary SHA mismatch before probe') unless before == SHA256
      sql = source_sql
      write_new('invocations/stock.stdin.sql', sql)
      stock = invoke('stock', [@binary, 'local', '--path', @store, '--session_timezone=UTC',
                               '--max_threads=1', "--max_memory_usage=#{MEMORY}", '--multiquery'], sql)
      fail!("stock invocation failed: #{stock[:classification]}") unless stock[:classification] == 'success'
      fail!('stock stderr was nonempty') unless stock[:stderr].empty?
      rows = parse_stock(stock[:stdout])
      validate_stock!(rows)
      after_stock = sha(@binary)
      fail!('ClickHouse binary changed during stock capture') unless after_stock == SHA256

      profiles = TABLES.map do |table|
        part = rows.fetch(:parts).fetch(table)
        path = File.realpath(part.fetch(:path))
        fail!("part escaped stock store: #{table}") unless path.start_with?(@store + '/')
        fail!("#{table} is not a single Wide part with eight rows") unless
          part.fetch(:type) == 'Wide' && part.fetch(:rows) == '8'
        {id: table, carrier: table.start_with?('nested_') ? 'nested' : 'array_tuple',
         string_profile: table.end_with?('_size') ? 'with_size_stream' : 'single_stream',
         sql_type: table.start_with?('nested_') ? NESTED : ARRAY,
         part_path: path, part_roster: inventory(path)}
      end
      manifest = {
        probe: 'W201 kernel-only stock Nested specialized-child qualification',
        scope: 'stock-created Wide parts -> BinaryBulkPhysicalPlan/CompressedMarkReader/BinaryBulkCodec decode; no public writer or ATTACH claim',
        source_reference_revision: 'ef037e60fc7f5654c8c80eefb8be82e3c56f9a67',
        clickhouse_binary: @binary, clickhouse_binary_sha256_before: before,
        clickhouse_binary_sha256_after_stock: after_stock,
        clickhouse_version: VERSION, clickhouse_build: BUILD,
        rows_per_mark: [2, 2, 2, 2], literal_rows: ROWS,
        profiles: profiles,
      }
      write_new('helper-manifest.json', JSON.pretty_generate(manifest) + "\n")
      before_helper = profiles.to_h { |item| [item[:id], inventory(item[:part_path])] }
      helper = invoke('crystal-helper', [@helper, File.join(@root, 'helper-manifest.json')], ''.b)
      after_helper = sha(@binary)
      fail!('ClickHouse binary changed during helper decode') unless after_helper == SHA256
      fail!("helper invocation failed: #{helper[:classification]}") unless helper[:classification] == 'success'
      fail!('helper stderr was nonempty') unless helper[:stderr].empty?
      after_files = profiles.to_h { |item| [item[:id], inventory(item[:part_path])] }
      fail!('stock part files changed during helper decode') unless before_helper == after_files
      validate_helper!(helper[:stdout])
      summary = {status: 'kernel_only_stock_decode_observed', stock_invocation: stock[:record],
                 helper_invocation: helper[:record], clickhouse_binary_sha256_after: after_helper,
                 part_files_unchanged: true, output: helper[:stdout].strip}
      write_new('summary.json', JSON.pretty_generate(summary) + "\n")
      puts "W201 status=kernel_only_stock_decode_observed; 4 stock profiles; parts unchanged; evidence=#{@root}"
      true
    rescue StandardError => error
      warn "W201 probe failure: #{error.class}: #{error.message}"
      false
    end

    private

    def source_sql
      statements = [
        'SET flatten_nested=0;', 'SET allow_suspicious_low_cardinality_types=1;',
        'SET output_format_json_named_tuples_as_objects=0;',
        "SELECT '__W201_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
      ]
      TABLES.each do |table|
        type = table.start_with?('nested_') ? NESTED : ARRAY
        profile = table.end_with?('_size') ? 'with_size_stream' : 'single_stream'
        statements << "CREATE TABLE default.#{table} (pk UInt64, payload #{type}) ENGINE=MergeTree ORDER BY pk SETTINGS #{SETTINGS}, string_serialization_version='#{profile}';"
        values = ROWS.map do |pk, records|
          array = records.map { |label, text| "(#{label.nil? ? 'NULL' : sql_string(label)}, #{sql_string(text)})" }.join(', ')
          "(#{pk}, [#{array}])"
        end.join(",\n")
        statements << "INSERT INTO default.#{table} (pk, payload) VALUES\n#{values};"
      end
      names = TABLES.map { |table| "'#{table}'" }.join(',')
      statements << "SELECT '__W201_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{names}) ORDER BY table, position FORMAT TSVRaw;"
      statements << "SELECT '__W201_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table IN (#{names}) AND active ORDER BY table,name FORMAT TSVRaw;"
      TABLES.each do |table|
        statements << "SELECT '__W201_LITERAL__', '#{table}', toString(pk), toJSONString(payload) FROM default.#{table} ORDER BY pk FORMAT TSVRaw;"
      end
      statements.join("\n") + "\n"
    end

    def parse_stock(stdout)
      result = {schema: Hash.new { |hash, key| hash[key] = [] }, parts: {}, literal: {}}
      stdout.force_encoding(Encoding::UTF_8).each_line do |line|
        fields = line.chomp.split("\t", -1)
        case fields[0]
        when '__W201_PIN__'
          fail!('duplicate runtime pin record') if result[:pin]
          result[:pin] = fields[1, 2]
        when '__W201_SCHEMA__'
          result[:schema][fields[1]] << [fields[2], fields[3]]
        when '__W201_PART__'
          fail!("duplicate active part record for #{fields[1]}") if result[:parts].key?(fields[1])
          result[:parts][fields[1]] = {name: fields[2], path: fields[3], type: fields[4], rows: fields[5], marks: fields[6]}
        when '__W201_LITERAL__'
          table = fields[1]
          result[:literal][table] ||= []
          result[:literal][table] << [Integer(fields[2]), fields[3]]
        end
      end
      result
    end

    def validate_stock!(data)
      fail!('runtime version/build pin mismatch') unless data[:pin] == [VERSION, BUILD]
      TABLES.each do |table|
        expected = table.start_with?('nested_') ? NESTED : ARRAY
        expected_columns = [['pk', 'UInt64'], ['payload', expected]]
        fail!("system.columns type mismatch for #{table}: #{data[:schema][table].inspect}") unless data[:schema][table] == expected_columns
        part = data[:parts][table] || fail!("no active part for #{table}")
        fail!("expected one part for #{table}") unless part[:name] && part[:type] == 'Wide' && part[:rows] == '8'
        observed = data[:literal][table] || []
        expected = ROWS.map { |pk, records| [pk, JSON.generate(records)] }
        fail!("stock literal rows differ for #{table}: #{observed.inspect}") unless observed == expected
      end
    end

    def validate_helper!(stdout)
      fail!('helper must emit exactly one structured W201 record') unless stdout.lines.size == 1
      marker, json = stdout.chomp.split("\t", 2)
      fail!('helper result marker is missing') unless marker == '__W201_RESULT__' && json
      result = JSON.parse(json)
      fail!('helper did not report successful decode') unless result['status'] == 'decoded'
      fail!('helper profile census is incomplete') unless result['profile_ids'].sort == TABLES.sort && result['profile_count'] == 4
      fail!('helper full decode row census is incomplete') unless result['full_rows'] == 8
      expected_windows = %w[full first_empty_mark later_populated_mark final_populated_mark zero_end_window]
      fail!('helper window census is incomplete') unless result['windows'].sort == expected_windows.sort
      observations = result['observations']
      fail!('helper physical lane observations are incomplete') unless observations.is_a?(Array) && observations.size == 4
      TABLES.each do |table|
        observation = observations.find { |item| item.start_with?("#{table}:observed_roles=") }
        fail!("missing observed physical role list for #{table}") unless observation
        wanted_size_lanes = table.end_with?('_size') ? 1 : 0
        fail!("String-profile lane observation mismatch for #{table}") unless
          observation.include?("string_size_lanes=#{wanted_size_lanes},")
      end
    rescue JSON::ParserError => error
      fail!("invalid helper JSON record: #{error.message}")
    end

    def inventory(part)
      Find.find(part).sort.map do |path|
        next if path == part
        relative = path.delete_prefix(part + '/')
        stat = File.lstat(path)
        fail!("symlink in part: #{path}") if stat.symlink?
        fail!("non-file entry in Wide part: #{path}") unless stat.file? || stat.directory?
        {name: relative, kind: stat.directory? ? 'directory' : 'file',
         size: stat.directory? ? 0 : stat.size,
         sha256: stat.file? ? Digest::SHA256.file(path).hexdigest : nil}
      end.compact
    end

    def invoke(label, argv, input)
      stdout, stderr, status, timed_out, spawn_error, stdin_error, stdout_error, stderr_error = @executor.send(:execute, argv, input)
      classification = @executor.send(:process_classification, status, timed_out, spawn_error,
                                      stdin_error, stdout_error, stderr_error, stderr)
      record = {argv: argv, stdin_bytes: input.bytesize, stdin_sha256: Digest::SHA256.hexdigest(input),
                stdin_file: label == 'stock' ? 'stock.stdin.sql' : nil,
                exit: status&.exitstatus, signal: status&.termsig, timed_out: timed_out,
                timeout_seconds: TIMEOUT, termination_grace_seconds: GRACE,
                process_classification: classification,
                spawn_error: spawn_error, stdin_error: stdin_error, stdout_error: stdout_error,
                stderr_error: stderr_error, stdout_bytes: stdout.bytesize,
                stdout_sha256: Digest::SHA256.hexdigest(stdout), stderr_bytes: stderr.bytesize,
                stderr_sha256: Digest::SHA256.hexdigest(stderr),
                process_kind: label == 'stock' ? 'clickhouse local' : 'prebuilt Crystal helper',
                max_threads: label == 'stock' ? 1 : nil,
                max_memory_usage_bytes: label == 'stock' ? MEMORY : nil}
      write_new("invocations/#{label}.argv.json", JSON.pretty_generate(argv) + "\n")
      write_new("invocations/#{label}.stdout", stdout)
      write_new("invocations/#{label}.stderr", stderr)
      write_new("invocations/#{label}.json", JSON.pretty_generate(record) + "\n")
      {stdout: stdout, stderr: stderr, classification: classification, record: record}
    end

    def sql_string(value)
      "'#{value.gsub('\\', '\\\\').gsub("'", "\\'")}'"
    end

    def executable(path, label)
      path = File.expand_path(path)
      fail!("#{label} missing, non-executable, or symlinked") unless File.file?(path) && File.executable?(path) && !File.symlink?(path)
      path
    end

    def empty_root(path)
      fail!('evidence root required') unless path
      path = File.expand_path(path)
      fail!('evidence root must be an existing empty direct child of /private/tmp') unless
        File.dirname(path) == File.realpath('/private/tmp') && File.directory?(path) &&
        !File.symlink?(path) && File.realpath(path) == path && Dir.children(path).empty?
      path
    end

    def sha(path)
      Digest::SHA256.file(path).hexdigest
    end

    def write_new(relative, bytes)
      File.open(File.join(@root, relative), 'wbx', 0o600) { |file| file.write(bytes) }
    end

    def fail!(message)
      raise RuntimeError, "W201: #{message}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    options = {binary: ProbeNestedSpecializedBulkW201::BINARY, helper: nil, root: nil}
    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby scripts/probe_nested_specialized_bulk_w201.rb --crystal-helper PATH --evidence-root EMPTY_/private/tmp_CHILD [--clickhouse PATH]'
      parser.on('--clickhouse PATH') { |value| options[:binary] = value }
      parser.on('--crystal-helper PATH', 'Prebuilt Crystal helper; never built by this runner') { |value| options[:helper] = value }
      parser.on('--evidence-root PATH', 'Existing empty direct child of /private/tmp') { |value| options[:root] = value }
    end.parse!
    abort 'W201: --crystal-helper and --evidence-root are required' unless options[:helper] && options[:root]
    exit(ProbeNestedSpecializedBulkW201::Runner.new(options).run ? 0 : 1)
  rescue StandardError => error
    warn "W201 runner error: #{error.class}: #{error.message}"
    exit 1
  end
end
