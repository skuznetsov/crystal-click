#!/usr/bin/env ruby
# Bounded W258 seven-column Wide reciprocal probe. The supplied native and
# helper executables are used as-is; this runner never builds either one.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require_relative 'stock_part_probe_support_w191'

module ProbeStaticRecursiveSelectedMetadataW258
  FORMAT = 'static_recursive_selected_metadata_w258_probe_v1'.freeze
  HELPER_FORMAT = 'static_recursive_selected_metadata_w258_roundtrip_v1'.freeze
  HELPER_SOURCE = File.expand_path('check_static_recursive_selected_metadata_w258.cr', __dir__).freeze
  FIXTURE_SOURCE = File.expand_path('support/static_recursive_selected_metadata_w258_fixture.cr', __dir__).freeze
  W185 = CheckArrayJSONPartsW185
  W180 = JsonBinaryKernelW180Probe
  BINARY = W180::DEFAULT_BINARY.freeze
  BINARY_SHA256 = W180::BINARY_SHA256.freeze
  VERSION = '26.10.1.1201'.freeze
  BUILD = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  SOURCE_SNAPSHOT = {
    path: '/private/tmp/clickhouse-w254-upstream.AqeqyC',
    revision: 'ed30948f095ecb70679986d7d60e27ad770ae27a',
    runtime_provenance_claimed: false,
  }.freeze
  # system.columns is selected with ORDER BY table, position.
  TABLES = %w[library_target source].freeze
  PART_NAME = 'all_1_1_0'.freeze
  KEY_HASH = 'fcc8daf1be9ac27649fa2186ad926aea'.freeze
  ROWS_PER_MARK = 2
  MARK_ROWS = [2, 2, 2, 2].freeze
  MARK_ROWS_WITH_TERMINAL = [2, 2, 2, 2, 0].freeze
  MAX_CAPTURE_BYTES = 1_048_576
  MAX_PART_FILES = 4096
  MAX_PART_BYTES = 64 * 1024 * 1024
  SCHEMA = [
    ['pk', 'UInt64'],
    ['u', 'UInt64'],
    ['side', 'String'],
    ['arr', 'Array(Nullable(UInt64))'],
    ['tup', 'Tuple(n UInt64, s String)'],
    ['lc', 'LowCardinality(String)'],
    ['v', 'Variant(String, UInt64)'],
  ].map(&:freeze).freeze
  SELECTED_COLUMNS = %w[u side arr tup lc v].freeze

  # Independently authored oracle: do not load values from the Crystal
  # fixture or from ClickHouse output to populate these rows.
  ROWS = [
    {pk: 1001, u: 2001, side: 'side-0', arr: [], tup: [3001, 'tuple-0'], lc: 'dup', v_type: 'String', v: 'variant-0'},
    {pk: 1002, u: 2002, side: 'side-1', arr: [], tup: [3002, 'tuple-1'], lc: 'red', v_type: 'UInt64', v: 4002},
    {pk: 1003, u: 2003, side: 'side-2', arr: [nil, 17], tup: [3003, 'tuple-2'], lc: 'dup', v_type: 'NULL', v: nil},
    {pk: 1004, u: 2004, side: 'side-3', arr: [23], tup: [3004, 'tuple-3'], lc: '', v_type: 'String', v: 'variant-3'},
    {pk: 1005, u: 2005, side: 'side-4', arr: [0, nil], tup: [3005, 'tuple-4'], lc: 'blue', v_type: 'UInt64', v: 4005},
    {pk: 1006, u: 2006, side: 'side-5', arr: [], tup: [3006, 'tuple-5'], lc: 'dup', v_type: 'String', v: 'variant-5'},
    {pk: 1007, u: 2007, side: 'side-6', arr: [7, 8, nil], tup: [3007, 'tuple-6'], lc: 'blue', v_type: 'UInt64', v: 4007},
    {pk: 1008, u: 2008, side: 'side-7', arr: [nil, 9], tup: [3008, 'tuple-7'], lc: 'tail', v_type: 'NULL', v: nil},
  ].map(&:freeze).freeze

  SETTINGS = [
    'index_granularity=2', 'index_granularity_bytes=10485760',
    'enable_mixed_granularity_parts=1', 'min_rows_for_wide_part=0',
    'min_bytes_for_wide_part=0', 'compress_marks=0', 'compress_primary_key=0',
    'min_compress_block_size=0', 'max_compress_block_size=4096',
    'ratio_of_defaults_for_sparse_serialization=1', "default_compression_codec='LZ4'",
    "serialization_info_version='with_types'",
    'propagate_types_serialization_versions_to_nested_types=1',
    'use_compact_variant_discriminators_serialization=0',
    "string_serialization_version='with_size_stream'",
  ].join(', ').freeze

  TAG = {
    pin: '__W258_PIN__', check_begin: '__W258_CHECK_BEGIN__', check_end: '__W258_CHECK_END__',
    schema: '__W258_SCHEMA__', path: '__W258_DATA_PATH__', part: '__W258_PART__',
    rows: '__W258_ROW__', middle: '__W258_MIDDLE_ROW__',
  }.freeze

  class Failure < StandardError; end

  class Probe
    def initialize(binary:, helper:, evidence_root:)
      @binary = validate_executable(binary, 'ClickHouse')
      @helper = validate_executable(helper, 'prebuilt helper')
      @root = validate_root(evidence_root)
      @capture = StockPartProbeSupportW191.new(@binary, @root)
      @store = File.join(@root, 'stores', 'native')
      @invocations = []
      @stage = 'not_started'
      @source_files = [__FILE__, HELPER_SOURCE, FIXTURE_SOURCE].map { |path| File.realpath(path) }.uniq.sort
    end

    def run
      prepare_layout!
      @runtime_sha_before = binary_sha
      fail!('pinned ClickHouse executable SHA-256 mismatch before probe') unless @runtime_sha_before == BINARY_SHA256
      @helper_sha_before = sha(@helper)
      @source_sha_before = source_hashes

      @stage = 'native stock source'
      native_source = run_native('native_source', initial_sql)
      assert_pin!(native_source)
      assert_native_success!(native_source)
      source = parse_native(native_source[:stdout])
      assert_source_native!(source)
      stock_path = source.fetch(:parts).fetch('source').fetch(:path)
      stock_part = inspect_part('stock_source', stock_path, source[:parts]['source'])

      @stage = 'helper stock reader and library writer'
      library_path = File.join(@root, 'parts', PART_NAME)
      helper = run_helper(stock_path, library_path)
      assert_helper!(helper, stock_path, library_path, stock_part)
      library_part = inspect_part('library_part', library_path,
                                  {name: PART_NAME, path: library_path, part_type: 'Wide', rows: '8', marks: '5'},
                                  library: true)
      verify_helper_part!(helper.fetch(:data).fetch('library'), 'library_wide', library_path, library_part)

      @stage = 'attach library part into isolated native store'
      target_data_path = validate_store_path!(source.fetch(:data_paths).fetch('library_target'))
      @capture.send(:attach_part!, library_path, target_data_path)
      attached_path = validate_store_path!(File.join(target_data_path, 'detached', PART_NAME))
      attached_part = inspect_part('attached_library_part', attached_path,
                                   {name: PART_NAME, path: attached_path, part_type: 'Wide', rows: '8', marks: '5'},
                                   attached: true)
      fail!('copied detached part differs from the library writer output') unless file_projection(attached_part) == file_projection(library_part)

      @stage = 'native attach, CHECK, and exact row oracle'
      native_attach = run_native('native_attach_check', attached_sql)
      assert_pin!(native_attach)
      assert_native_success!(native_attach)
      attached = parse_native(native_attach[:stdout])
      assert_attached_native!(attached)

      @stage = 'stable evidence and summary'
      @runtime_sha_after = binary_sha
      @helper_sha_after = sha(@helper)
      @source_sha_after = source_hashes
      fail!('pinned ClickHouse executable changed during probe') unless @runtime_sha_after == BINARY_SHA256
      fail!('prebuilt helper executable changed during probe') unless @helper_sha_after == @helper_sha_before
      fail!('probe source or fixture changed during probe') unless @source_sha_after == @source_sha_before

      write_summary(
        status: 'paired_wide_observed', source: source, stock_part: stock_part,
        helper: helper[:data], library_part: library_part, attached_part: attached_part,
        attached: attached, source_invocation: native_source[:record],
        helper_invocation: helper[:record], attach_invocation: native_attach[:record],
      )
      puts "W258 status=paired_wide_observed; columns=#{SCHEMA.size}; rows=#{ROWS.size}; marks_with_terminal=#{MARK_ROWS_WITH_TERMINAL.inspect}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @runtime_sha_after = binary_sha rescue nil
      @helper_sha_after = sha(@helper) rescue nil
      @source_sha_after = source_hashes rescue nil
      write_summary(status: 'runner_failure_or_observations_differ', fatal_error: @fatal_error) rescue nil
      warn "W258 #{@stage} failed: #{@fatal_error}"
      false
    end

    private

    def fail!(message)
      raise Failure, "W258 selected-metadata Wide probe: #{message}"
    end

    def validate_root(path)
      fail!('evidence root is required') unless path && !path.empty?
      expanded = File.expand_path(path)
      fail!('evidence root must be a direct child of /private/tmp') unless File.dirname(expanded) == File.realpath('/private/tmp')
      fail!('evidence root must not be a symlink') if File.symlink?(expanded)
      fail!('evidence root must be an existing empty canonical directory') unless
        File.directory?(expanded) && File.realpath(expanded) == expanded && Dir.children(expanded).empty?
      expanded
    rescue Errno::ENOENT
      fail!('evidence root must already exist')
    end

    def validate_executable(path, label)
      fail!("#{label} path is required") unless path && !path.empty?
      expanded = File.expand_path(path)
      fail!("#{label} is missing, non-executable, or symlinked") unless
        File.file?(expanded) && File.executable?(expanded) && !File.symlink?(expanded)
      expanded
    end

    def prepare_layout!
      %w[invocations stores parts].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(@store, 0o700)
    end

    def sha(path)
      Digest::SHA256.file(path).hexdigest
    end

    def binary_sha
      sha(@binary)
    end

    def source_hashes
      @source_files.map { |path| {path: path, sha256: sha(path)} }
    end

    def run_native(label, sql)
      fail!('unsafe invocation label') unless /\A[a-z0-9_]+\z/.match?(label)
      sql_path = File.join(@root, 'invocations', "#{label}.stdin.sql")
      @capture.send(:write_new, sql_path, sql.b)
      argv = [@binary, 'local', '--path', @store, '--session_timezone=UTC', '--max_threads=1',
              "--max_memory_usage=#{W185::MEMORY}", '--output_format_json_quote_64bit_integers=0', '--multiquery']
      before_sha = binary_sha
      fail!('pinned ClickHouse executable SHA-256 mismatch before invocation') unless before_sha == BINARY_SHA256
      invocation = @capture.send(:execute_record, label, argv, sql.b,
                                 'clickhouse local', BINARY_SHA256, @binary)
      invocation[:record][:binary_sha_before] = before_sha
      invocation[:record][:binary_sha_after] = binary_sha
      fail!('pinned ClickHouse executable changed during invocation') unless invocation[:record][:binary_sha_after] == BINARY_SHA256
      @invocations << invocation[:record]
      fail!("#{label} stdout capture exceeds 1 MiB") if invocation[:stdout].bytesize > MAX_CAPTURE_BYTES
      fail!("#{label} stderr capture exceeds 1 MiB") if invocation[:stderr].bytesize > MAX_CAPTURE_BYTES
      invocation
    end

    def run_helper(stock_path, library_path)
      fail!('library part destination already exists') if File.exist?(library_path) || File.symlink?(library_path)
      argv = [@helper, 'roundtrip', stock_path, library_path]
      before_sha = sha(@helper)
      invocation = @capture.send(:execute_record, 'library_roundtrip', argv, ''.b,
                                 'prebuilt Crystal helper', nil, nil)
      after_sha = sha(@helper)
      invocation[:record][:helper_sha_before] = before_sha
      invocation[:record][:helper_sha_after] = after_sha
      @invocations << invocation[:record]
      fail!('prebuilt helper executable changed during invocation') unless before_sha == after_sha
      fail!('helper stdout capture exceeds 1 MiB') if invocation[:stdout].bytesize > MAX_CAPTURE_BYTES
      fail!('helper stderr capture exceeds 1 MiB') if invocation[:stderr].bytesize > MAX_CAPTURE_BYTES
      unless invocation[:classification] == 'success' && invocation[:status]&.success? && invocation[:status]&.termsig.nil?
        fail!('helper process failed; a helper error is not a storage-format rejection')
      end
      fail!('helper wrote stderr') unless invocation[:stderr].empty?
      records = invocation[:stdout].force_encoding(Encoding::UTF_8).lines.map(&:chomp).reject(&:empty?)
      fail!('helper must emit exactly one JSON record') unless records.size == 1
      {data: JSON.parse(records.fetch(0)), record: invocation[:record]}
    rescue JSON::ParserError => error
      fail!("helper output is not valid JSON: #{error.message}")
    end

    def assert_pin!(invocation)
      lines = invocation[:stdout].force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      expected = "#{TAG[:pin]}\t#{VERSION}\t#{BUILD}"
      observed = lines.find { |line| line.start_with?("#{TAG[:pin]}\t") }
      fail!("runtime version/build mismatch: #{observed.inspect}") unless observed == expected
    end

    def assert_native_success!(invocation)
      unless invocation[:classification] == 'success' && invocation[:status]&.success? && invocation[:status]&.termsig.nil?
        fail!("ClickHouse process failed (#{invocation[:classification]})")
      end
      if W180::CLICKHOUSE_EXCEPTION.match?(invocation[:stderr]) || W180::SYSTEM_FAILURE.match?(invocation[:stderr])
        fail!('ClickHouse reported an exception or system error despite a successful process classification')
      end
      fail!('ClickHouse wrote unclassified stderr') unless invocation[:stderr].empty?
    end

    def sql_string(value)
      "'#{value.to_s.gsub('\\') { '\\\\' }.gsub("'") { "\\'" }}'"
    end

    def row_value_sql(row)
      arr = row[:arr].map { |value| value.nil? ? 'NULL' : "toUInt64(#{value})" }.join(', ')
      tuple = "tuple(toUInt64(#{row[:tup][0]}), #{sql_string(row[:tup][1])})"
      variant = if row[:v_type] == 'NULL'
                  'NULL'
                elsif row[:v_type] == 'UInt64'
                  "toUInt64(#{row[:v]})"
                else
                  sql_string(row[:v])
                end
      [row[:pk], "toUInt64(#{row[:u]})", sql_string(row[:side]),
       "CAST([#{arr}], #{sql_string(SCHEMA[3][1])})",
       "CAST(#{tuple}, #{sql_string(SCHEMA[4][1])})",
       "CAST(#{sql_string(row[:lc])}, #{sql_string(SCHEMA[5][1])})",
       "CAST(#{variant}, #{sql_string(SCHEMA[6][1])})"].join(', ')
    end

    def insert_sql(table)
      rows = ROWS.map { |row| "(#{row_value_sql(row)})" }.join(",\n")
      "INSERT INTO default.#{table} VALUES\n#{rows};"
    end

    def create_sql(table)
      declarations = SCHEMA.map { |name, type| "#{name} #{type}" }.join(', ')
      "CREATE TABLE default.#{table} (#{declarations}) ENGINE=MergeTree ORDER BY pk SETTINGS #{SETTINGS};"
    end

    def check_sql(table)
      ["SELECT '#{TAG[:check_begin]}', '#{table}' FORMAT TSVRaw;",
       "CHECK TABLE default.#{table} FORMAT TSV;",
       "SELECT '#{TAG[:check_end]}', '#{table}' FORMAT TSVRaw;"].join("\n")
    end

    def row_sql(table, middle: false)
      marker = middle ? TAG[:middle] : TAG[:rows]
      predicate = middle ? ' WHERE pk BETWEEN 1003 AND 1006' : ''
      "SELECT '#{marker}', '#{table}', toString(pk), toString(u), hex(side), " \
        "hex(toJSONString(arr)), toString(tupleElement(tup, 1)), hex(tupleElement(tup, 2)), " \
        "hex(lc), variantType(v), hex(ifNull(toJSONString(v), 'null')) FROM default.#{table}#{predicate} ORDER BY pk FORMAT TSVRaw;"
    end

    def initial_sql
      statements = [
        "SELECT '#{TAG[:pin]}', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
        create_sql('source'), create_sql('library_target'), insert_sql('source'), check_sql('source'),
        "SELECT '#{TAG[:schema]}', table, name, type FROM system.columns WHERE database='default' AND table IN ('source','library_target') ORDER BY table, position FORMAT TSVRaw;",
        row_sql('source'), row_sql('source', middle: true),
        "SELECT '#{TAG[:path]}', name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name IN ('source','library_target') ORDER BY name FORMAT TSVRaw;",
        "SELECT '#{TAG[:part]}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='source' AND active ORDER BY name FORMAT TSVRaw;",
      ]
      statements.join("\n") + "\n"
    end

    def attached_sql
      [
        "SELECT '#{TAG[:pin]}', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
        "ALTER TABLE default.library_target ATTACH PART '#{PART_NAME}';",
        check_sql('library_target'),
        "SELECT '#{TAG[:schema]}', table, name, type FROM system.columns WHERE database='default' AND table='library_target' ORDER BY position FORMAT TSVRaw;",
        row_sql('library_target'), row_sql('library_target', middle: true),
        "SELECT '#{TAG[:part]}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='library_target' AND active ORDER BY name FORMAT TSVRaw;",
      ].join("\n") + "\n"
    end

    def parse_native(stdout)
      lines = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      fields = lambda do |tag|
        lines.map { |line| line.split("\t", -1) if line.start_with?("#{tag}\t") }.compact
      end
      checks = {}
      active_check = nil
      lines.each do |line|
        if line.start_with?("#{TAG[:check_begin]}\t")
          active_check = line.split("\t", -1)[1]
          fail!("duplicate CHECK marker for #{active_check}") if checks.key?(active_check)
          checks[active_check] = []
        elsif line.start_with?("#{TAG[:check_end]}\t")
          ended = line.split("\t", -1)[1]
          fail!("unpaired CHECK marker for #{ended}") unless active_check == ended
          active_check = nil
        elsif active_check
          checks[active_check] << line
        end
      end
      fail!('unterminated CHECK output block') if active_check

      data_paths = {}
      fields.call(TAG[:path]).each { |field| data_paths[field.fetch(1)] = field.fetch(2) }
      parts = {}
      fields.call(TAG[:part]).each do |field|
        fail!('native query returned malformed part metadata') unless field.size == 7
        table = field.fetch(1)
        fail!("native query returned multiple active part records for #{table}") if parts.key?(table)
        parts[table] = {name: field.fetch(2), path: field.fetch(3), part_type: field.fetch(4),
                        rows: field.fetch(5), marks: field.fetch(6)}
      end
      schemas = fields.call(TAG[:schema]).map { |field| field.drop(1) }
      rows = Hash.new { |hash, table| hash[table] = [] }
      middle_rows = Hash.new { |hash, table| hash[table] = [] }
      parse_rows = lambda do |tag, target|
        fields.call(tag).each do |field|
          fail!('native row output has an unexpected field count') unless field.size == 11
          target[field.fetch(1)] << {
            pk: parse_uint64(field.fetch(2), 'pk'), u: parse_uint64(field.fetch(3), 'u'), side: decode_hex(field.fetch(4)),
            arr: parse_json_hex(field.fetch(5)), tup: [parse_uint64(field.fetch(6), 'tup.n'), decode_hex(field.fetch(7))],
            lc: decode_hex(field.fetch(8)), v_type: field.fetch(9), v: parse_json_hex(field.fetch(10)),
          }
        end
      end
      parse_rows.call(TAG[:rows], rows)
      parse_rows.call(TAG[:middle], middle_rows)
      {checks: checks, schemas: schemas, data_paths: data_paths, parts: parts,
       rows: rows, middle_rows: middle_rows}
    end

    def decode_hex(value)
      fail!('native hex field is not even-width hexadecimal') unless /\A(?:[0-9a-fA-F]{2})*\z/.match?(value)
      decoded = [value].pack('H*').force_encoding(Encoding::UTF_8)
      fail!('native hex field is not valid UTF-8') unless decoded.valid_encoding?
      decoded
    end

    def parse_uint64(value, label)
      fail!("native #{label} is not canonical UInt64 decimal") unless /\A(?:0|[1-9][0-9]*)\z/.match?(value)
      parsed = value.to_i
      fail!("native #{label} exceeds UInt64") if parsed > ((1 << 64) - 1)
      parsed
    end

    def parse_json_hex(value)
      JSON.parse(decode_hex(value))
    rescue JSON::ParserError => error
      fail!("native row JSON is malformed: #{error.message}")
    end

    def expected_schema(table_names)
      table_names.flat_map { |table| SCHEMA.map { |name, type| [table, name, type] } }
    end

    def expected_native_rows(rows = ROWS)
      rows.map do |row|
        {pk: row[:pk], u: row[:u], side: row[:side], arr: row[:arr], tup: row[:tup],
         lc: row[:lc], v_type: row[:v_type] == 'NULL' ? 'None' : row[:v_type], v: row[:v]}
      end
    end

    def assert_source_native!(native)
      fail!('native source part roster is not exactly one active part') unless native[:parts].keys == ['source']
      fail!("source CHECK differs: #{native[:checks].inspect}") unless native[:checks] == {'source' => ["#{PART_NAME}\t1\t"]}
      fail!('source and target system.columns roster differs from the seven-column literal schema') unless
        native[:schemas] == expected_schema(TABLES)
      fail!('stock source full ordered rows differ from independent literals') unless
        native[:rows]['source'] == expected_native_rows
      fail!('stock source middle ordered rows differ from independent literals') unless
        native[:middle_rows]['source'] == expected_native_rows(ROWS[2, 4])
      fail!('native returned rows for an unexpected table') unless
        (native[:rows].keys - ['source']).empty? && (native[:middle_rows].keys - ['source']).empty?
      %w[source library_target].each do |table|
        fail!("#{table} data path is absent") unless native[:data_paths][table] && !native[:data_paths][table].empty?
      end
      part = native[:parts]['source'] || fail!('stock source part metadata is absent')
      fail!('source part is not one expected active Wide part with EOF sentinel') unless
        part[:name] == PART_NAME && part[:part_type] == 'Wide' && part[:rows] == '8' && part[:marks] == '5'
      validate_native_part_path!(part[:path])
    end

    def assert_helper!(helper, stock_path, library_path, stock_part)
      result = helper.fetch(:data)
      fail!('helper format/version differs') unless result['format'] == HELPER_FORMAT
      expected_profile = {
        'ordinary_string' => 'with_size_stream', 'shared_string' => 'single_stream',
        'variant_discriminator' => 'BASIC', 'frame_bytes' => 32, 'rows_per_mark' => ROWS_PER_MARK,
      }
      fail!("helper writer profile differs: #{result['writer_profile'].inspect}") unless result['writer_profile'] == expected_profile
      fail!('helper key column differs') unless result['key_column'] == 'pk'
      verify_helper_part!(result.fetch('stock'), 'stock_wide', stock_path, stock_part)
      library = result.fetch('library')
      fail!('helper library writer target differs') unless File.expand_path(library.fetch('path')) == library_path
    end

    def verify_helper_part!(record, label, path, inventory)
      fail!("helper #{label} label differs") unless record['label'] == label
      fail!("helper #{label} path differs") unless File.expand_path(record.fetch('path')) == File.expand_path(path)
      expected_keys = ROWS.map { |row| row[:pk] }
      fail!("helper #{label} mark row counts differ") unless record['mark_row_counts'] == MARK_ROWS
      fail!("helper #{label} keys differ") unless record['keys'] == expected_keys
      verify_scan!(record.fetch('full_public'), expected_keys, expected_signatures, "#{label} public full")
      verify_scan!(record.fetch('middle_public'), expected_keys[2, 4], expected_signatures(ROWS[2, 4]), "#{label} public middle")
      fail!("helper #{label} EOF window yielded callbacks") unless record['eof_callbacks'] == 0
      verify_scan!(record.fetch('offline'), expected_keys, expected_signatures, "#{label} OfflineTable.values")
      verify_helper_files!(record, path, label)
      helper_inventory = record.fetch('files')
      expected_files = inventory[:files].map do |file|
        {'path' => file[:path], 'bytes' => file[:bytes], 'sha256' => file[:sha256]}
      end
      fail!("helper #{label} file inventory differs from independent inventory") unless helper_inventory == expected_files
    end

    def verify_helper_files!(record, path, label)
      files = record.fetch('files')
      fail!("helper #{label} file inventory is empty") unless files.is_a?(Array) && !files.empty?
      fail!("helper #{label} file inventory exceeds file bound") if files.size > MAX_PART_FILES
      fail!("helper #{label} file entries are not ordered") unless files.map { |file| file.fetch('path') } == files.map { |file| file.fetch('path') }.sort
      total = files.sum { |file| file.fetch('bytes') }
      fail!("helper #{label} file inventory exceeds byte bound") if total > MAX_PART_BYTES
      files.each do |file|
        relative = file.fetch('path')
        fail!("helper #{label} file path is not a safe relative path") if
          relative.empty? || relative.start_with?(File::SEPARATOR) ||
          relative.split(File::SEPARATOR).any? { |component| component.empty? || component == '.' || component == '..' }
        fail!("helper #{label} file digest is malformed") unless /\A[0-9a-f]{64}\z/.match?(file.fetch('sha256'))
        full = File.join(path, relative)
        fail!("helper #{label} inventory file is absent or symlinked") unless File.file?(full) && !File.symlink?(full)
        fail!("helper #{label} file size/hash differs") unless File.size(full) == file.fetch('bytes') && sha(full) == file.fetch('sha256')
      end
    end

    def verify_scan!(scan, keys, columns, label)
      fail!("#{label} keys differ") unless scan.fetch('keys') == keys
      fail!("#{label} typed signatures differ from independent literals") unless scan.fetch('columns') == columns
      fail!("#{label} column set differs") unless scan.fetch('columns').keys.sort == SELECTED_COLUMNS.sort
      columns.each do |name, values|
        fail!("#{label} #{name} value count differs from key alignment") unless scan.fetch('columns').fetch(name).size == keys.size && values.size == keys.size
      end
    end

    def expected_signatures(rows = ROWS)
      SELECTED_COLUMNS.to_h do |column|
        [column, rows.map { |row| signature_for(column, row) }]
      end
    end

    def signature_for(column, row)
      case column
      when 'u'
        "uint64:#{row[:u]}"
      when 'side', 'lc'
        "string:#{row[column.to_sym].b.unpack1('H*')}"
      when 'arr'
        values = row[:arr].map { |value| value.nil? ? 'null' : "uint64:#{value}" }
        "array[#{values.join(',')}]"
      when 'tup'
        "tuple[uint64:#{row[:tup][0]},string:#{row[:tup][1].b.unpack1('H*')}]"
      when 'v'
        case row[:v_type]
        when 'String' then "variant<String>(string:#{row[:v].b.unpack1('H*')})"
        when 'UInt64' then "variant<UInt64>(uint64:#{row[:v]})"
        when 'NULL' then 'variant<NULL>(null)'
        else fail!("unknown oracle Variant tag #{row[:v_type]}")
        end
      else
        fail!("missing signature oracle for #{column}")
      end
    end

    def inspect_part(label, path, part, library: false, attached: false)
      full = if library
               expected = File.join(@root, 'parts', PART_NAME)
               fail!("library part escaped parts/#{PART_NAME}") unless File.expand_path(path) == expected
               expected
             elsif attached
               validate_native_part_path!(path)
             else
               validate_native_part_path!(path)
             end
      fail!("#{label} part directory is absent or symlinked") unless File.directory?(full) && !File.symlink?(full)
      entries = []
      total_bytes = 0
      Find.find(full) do |entry|
        stat = File.lstat(entry)
        fail!("#{label} part contains a symlink") if stat.symlink?
        next if entry == full
        if stat.directory?
          next
        elsif stat.file?
          relative = entry.delete_prefix(full + File::SEPARATOR)
          size = stat.size
          total_bytes += size
          fail!("#{label} part exceeds its byte bound") if total_bytes > MAX_PART_BYTES
          entries << {path: relative, bytes: size, sha256: sha(entry)}
          fail!("#{label} part exceeds its file bound") if entries.size > MAX_PART_FILES
        else
          fail!("#{label} part contains a non-regular entry")
        end
      end
      entries.sort_by! { |file| file[:path] }
      by_path = entries.to_h { |file| [file[:path], file] }
      %w[columns.txt columns_substreams.txt count.txt checksums.txt primary.idx serialization.json default_compression_codec.txt metadata_version.txt].each do |name|
        fail!("#{label} is missing #{name}") unless by_path.key?(name)
      end
      fail!("#{label} count.txt differs") unless File.read(File.join(full, 'count.txt')).strip == '8'
      metadata_version = File.read(File.join(full, 'metadata_version.txt')).strip
      fail!("#{label} metadata_version.txt differs") unless metadata_version == '0'
      codec = File.read(File.join(full, 'default_compression_codec.txt')).strip
      fail!("#{label} default codec differs") unless codec == 'CODEC(LZ4)'
      serialization_text = File.binread(File.join(full, 'serialization.json')).force_encoding(Encoding::UTF_8)
      serialization = JSON.parse(serialization_text)
      fail!("#{label} serialization.json version differs") unless serialization['version'] == 1
      fail!("#{label} nested serialization-version propagation differs") unless serialization['propagate_types_serialization_versions_to_nested_types'] == true
      string_version = serialization.dig('types_serialization_versions', 'string')
      fail!("#{label} String serialization version is not with-size") unless string_version == 1
      plain_marks = entries.select { |file| file[:path].end_with?('.mrk2') }
      compressed_marks = entries.select { |file| /\.cmrk\d*\z/.match?(file[:path]) }
      fail!("#{label} has no plain .mrk2 streams") if plain_marks.empty?
      fail!("#{label} unexpectedly contains compressed mark streams") unless compressed_marks.empty?
      marks = plain_marks.to_h do |file|
        bytes = File.binread(File.join(full, file[:path]))
        fail!("#{label} #{file[:path]} has malformed .mrk2 triples") unless bytes.bytesize.positive? && (bytes.bytesize % 24).zero?
        triples = bytes.unpack('Q<*').each_slice(3).map(&:dup)
        fail!("#{label} #{file[:path]} mark count differs from data part") unless triples.size == 5
        [file[:path], triples]
      end
      key_marks = marks["#{KEY_HASH}.mrk2"]
      fail!("#{label} pk .mrk2 EOF grid differs: #{key_marks&.map { |triple| triple[2] }.inspect}") unless key_marks&.map { |triple| triple[2] } == MARK_ROWS_WITH_TERMINAL
      {
        label: label, path: full, part_name: part[:name], part_type: part[:part_type],
        rows: part[:rows], marks: part[:marks], count_text: '8', metadata_version: metadata_version,
        default_compression_codec: codec, serialization_json: serialization,
        serialization_json_sha256: Digest::SHA256.hexdigest(serialization_text),
        columns_text: File.binread(File.join(full, 'columns.txt')).force_encoding(Encoding::UTF_8),
        columns_substreams_text: File.binread(File.join(full, 'columns_substreams.txt')).force_encoding(Encoding::UTF_8),
        plain_mark_rows_by_file: marks.transform_values { |triples| triples.map { |triple| triple[2] } },
        plain_mark_records: plain_marks.size, compressed_mark_files: compressed_marks.map { |file| file[:path] },
        files: entries,
      }
    rescue JSON::ParserError => error
      fail!("#{label} serialization.json is malformed: #{error.message}")
    end

    def file_projection(inventory)
      inventory[:files].map do |file|
        {path: file[:path], bytes: file[:bytes], sha256: file[:sha256]}
      end
    end

    def validate_native_part_path!(path)
      fail!('native part path is absent') unless path && !path.empty?
      full = File.expand_path(path)
      fail!("native part path escaped isolated store: #{path}") unless full.start_with?(@store + File::SEPARATOR)
      full
    end

    def validate_store_path!(path)
      fail!('library_target data path is absent') unless path && !path.empty?
      full = File.expand_path(path)
      fail!("library_target data path escaped isolated store: #{path}") unless full.start_with?(@store + File::SEPARATOR)
      current = @store
      full.delete_prefix(@store + File::SEPARATOR).split(File::SEPARATOR).each do |component|
        current = File.join(current, component)
        next unless File.exist?(current) || File.symlink?(current)
        fail!("symlink in native table path: #{current}") if File.lstat(current).symlink?
        fail!("non-directory in native table path: #{current}") unless File.directory?(current)
      end
      full
    end

    def assert_attached_native!(native)
      fail!('native attached part roster is not exactly one active part') unless native[:parts].keys == ['library_target']
      fail!("library CHECK differs: #{native[:checks].inspect}") unless native[:checks] == {'library_target' => ["#{PART_NAME}\t1\t"]}
      fail!('attached library target schema differs') unless native[:schemas] == expected_schema(['library_target'])
      fail!('stock ClickHouse rows after attach differ from independent full literals') unless
        native[:rows]['library_target'] == expected_native_rows
      fail!('stock ClickHouse middle rows after attach differ from independent literals') unless
        native[:middle_rows]['library_target'] == expected_native_rows(ROWS[2, 4])
      fail!('attach query returned rows for unexpected tables') unless
        (native[:rows].keys - ['library_target']).empty? && (native[:middle_rows].keys - ['library_target']).empty?
      part = native[:parts]['library_target'] || fail!('attached active part metadata is absent')
      fail!('stock did not attach one Wide 8-row part with five marks') unless
        part[:name] == PART_NAME && part[:part_type] == 'Wide' && part[:rows] == '8' && part[:marks] == '5'
      validate_native_part_path!(part[:path])
    end

    def write_summary(data)
      summary = {
        probe: FORMAT,
        status: data[:status], fatal_error: data[:fatal_error], stage: @stage,
        claim_boundary: 'one seven-column static Wide fixture and pinned runtime only; no Compact success, general storage compatibility, or source/runtime identity claim',
        source_snapshot: SOURCE_SNAPSHOT,
        runtime: {path: @binary, expected_sha256: BINARY_SHA256, sha256_before: @runtime_sha_before,
                  sha256_after: @runtime_sha_after, expected_version: VERSION, expected_build: BUILD},
        helper: {path: @helper, protocol: HELPER_FORMAT, mode: 'roundtrip STOCK_PART LIBRARY_PART',
                 sha256_before: @helper_sha_before, sha256_after: @helper_sha_after,
                 source_provenance: 'the prebuilt executable is identified by hash; compilation from current source files is not asserted',
                 source_files_before: @source_sha_before, source_files_after: @source_sha_after},
        settings: SETTINGS, schema: SCHEMA, independent_rows: ROWS,
        mark_grid: {rows_per_data_mark: ROWS_PER_MARK, data_mark_rows: MARK_ROWS,
                    pk_mrk2_rows_with_terminal: MARK_ROWS_WITH_TERMINAL},
        limits: {max_threads: 1, max_memory_usage_bytes_per_native_process: W185::MEMORY,
                 timeout_seconds: W180::PROCESS_TIMEOUT_SECONDS,
                 termination_grace_seconds: W180::TERMINATION_GRACE_SECONDS,
                 max_capture_bytes_per_stream: MAX_CAPTURE_BYTES,
                 capture_note: 'output is captured by the established W180 executor, then rejected if over the 1 MiB artifact bound'},
        evidence_root: @root, invocations: @invocations,
      }.merge(data.reject { |key, _| %i[status fatal_error].include?(key) })
      @capture.send(:write_new, File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
    end
  end
end

def main
  options = {binary: ProbeStaticRecursiveSelectedMetadataW258::BINARY}
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/probe_static_recursive_selected_metadata_w258.rb --helper PREBUILT_HELPER --evidence-root EMPTY_DIRECT_CHILD_OF_PRIVATE_TMP [--binary CLICKHOUSE]'
    parser.on('--binary PATH') { |value| options[:binary] = value }
    parser.on('--helper PATH') { |value| options[:helper] = value }
    parser.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
  end.parse!
  raise 'prebuilt helper is required via --helper' unless options[:helper]
  exit(ProbeStaticRecursiveSelectedMetadataW258::Probe.new(**options).run ? 0 : 1)
rescue StandardError => error
  warn "W258 probe runner error: #{error.class}: #{error.message}"
  exit 1
end

main if $PROGRAM_NAME == __FILE__
