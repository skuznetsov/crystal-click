#!/usr/bin/env ruby
# Root-run stock Compact physical-context probe. Uses supplied executables as
# is; it never builds ClickHouse or the Crystal helper.

require 'digest'
require 'find'
require 'json'
require 'optparse'
require_relative 'stock_part_probe_support_w191'

module ProbeCompactPhysicalContextW259
  FORMAT = 'compact_physical_context_w259_probe_v1'.freeze
  HELPER_FORMAT = 'compact_physical_context_w259_helper_v1'.freeze
  HELPER_SOURCE = File.expand_path('check_compact_physical_context_w259.cr', __dir__).freeze
  W185 = CheckArrayJSONPartsW185
  W180 = JsonBinaryKernelW180Probe
  BINARY = '/private/tmp/crystal-click-w216-runtime-recovery.DmL9Kw/clickhouse-stripped'.freeze
  BINARY_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  VERSION = '26.10.1.1201'.freeze
  BUILD = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  SOURCE_SNAPSHOT = {
    path: '/private/tmp/clickhouse-w254-upstream.AqeqyC',
    revision: 'ed30948f095ecb70679986d7d60e27ad770ae27a',
    runtime_provenance_claimed: false,
  }.freeze

  WIDE_TABLE = 'wide_control'.freeze
  MRK3_TABLE = 'compact_mrk3'.freeze
  MRK4_TABLE = 'compact_mrk4'.freeze
  TABLES = [WIDE_TABLE, MRK3_TABLE, MRK4_TABLE].freeze
  PART_NAME = 'all_1_1_0'.freeze
  ROWS_PER_MARK = 2
  MARK_ROWS = [2, 2, 2, 2].freeze
  MARK_ROWS_WITH_TERMINAL = [2, 2, 2, 2, 0].freeze
  MAX_CAPTURE_BYTES = 1_048_576
  MAX_PART_FILES = 4096
  MAX_PART_BYTES = 64 * 1024 * 1024
  MAX_RAW_DECOMPRESSED_BYTES = 64 * 1024 * 1024
  MAX_RAW_FRAME_DECOMPRESSED_BYTES = 4096
  MAX_RAW_FRAME_COUNT = 4096
  RAW_WINDOWS = {
    'full' => [0, 4].freeze,
    'first' => [0, 1].freeze,
    'middle' => [1, 2].freeze,
    'last' => [3, 1].freeze,
    'eof' => [4, 0].freeze,
  }.freeze

  SCHEMA = [
    ['pk', 'UInt64'],
    ['u', 'UInt64'],
    ['side', 'String'],
    ['arr', 'Array(Nullable(UInt64))'],
    ['tup', 'Tuple(n UInt64, s String)'],
    ['lc', 'LowCardinality(String)'],
    ['v', 'Variant(String, UInt64)'],
  ].map(&:freeze).freeze
  VALUE_COLUMNS = %w[u side arr tup lc v].freeze

  # Independently authored oracle. Do not derive these rows from helper output
  # or a Crystal fixture.
  ROWS = [
    {pk: 1001, u: 2001, side: 'side-0', arr: [], tup: [3001, 'tuple-0'], lc: 'dup', v_type: 'String', v: 'variant-0'},
    {pk: 1002, u: 2002, side: 'side-1', arr: [], tup: [3002, 'tuple-1'], lc: 'red', v_type: 'UInt64', v: 4002},
    {pk: 1003, u: 2003, side: 'side-2', arr: [nil, 17], tup: [3003, 'tuple-2'], lc: 'dup', v_type: 'NULL', v: nil},
    {pk: 1004, u: 2004, side: 'side-3', arr: [23], tup: [3004, 'tuple-3'], lc: '', v_type: 'String', v: 'variant-3'},
    {pk: 1005, u: 2005, side: 'side-4', arr: [], tup: [3005, 'tuple-4'], lc: 'blue', v_type: 'UInt64', v: 4005},
    {pk: 1006, u: 2006, side: 'side-5', arr: [], tup: [3006, 'tuple-5'], lc: 'dup', v_type: 'String', v: 'variant-5'},
    {pk: 1007, u: 2007, side: 'side-6', arr: [7, 8, nil], tup: [3007, 'tuple-6'], lc: 'blue', v_type: 'UInt64', v: 4007},
    {pk: 1008, u: 2008, side: 'side-7', arr: [nil, 9], tup: [3008, 'tuple-7'], lc: 'tail', v_type: 'NULL', v: nil},
  ].map(&:freeze).freeze

  COMMON_SETTINGS = [
    'index_granularity=2', 'index_granularity_bytes=10485760',
    'enable_mixed_granularity_parts=1', 'compress_marks=0', 'compress_primary_key=0',
    'min_compress_block_size=0', 'max_compress_block_size=4096',
    'ratio_of_defaults_for_sparse_serialization=1', "default_compression_codec='LZ4'",
    "serialization_info_version='with_types'",
    'propagate_types_serialization_versions_to_nested_types=1',
    'use_compact_variant_discriminators_serialization=0',
    "string_serialization_version='with_size_stream'",
  ].freeze

  TAG = {
    pin: '__W259_PIN__', check_begin: '__W259_CHECK_BEGIN__', check_end: '__W259_CHECK_END__',
    schema: '__W259_SCHEMA__', part: '__W259_PART__', rows: '__W259_ROW__', middle: '__W259_MIDDLE_ROW__',
  }.freeze

  class Failure < StandardError; end

  class Probe
    def initialize(binary:, helper:, evidence_root:)
      @binary = validate_executable(binary, 'ClickHouse')
      @helper = validate_executable(helper, 'prebuilt Crystal helper')
      @root = validate_root(evidence_root)
      @capture = StockPartProbeSupportW191.new(@binary, @root)
      @store = File.join(@root, 'stores', 'native')
      @invocations = []
      @stage = 'not_started'
      @source_files = [__FILE__, HELPER_SOURCE].map { |path| File.realpath(path) }.uniq.sort
    end

    def run
      prepare_layout!
      @runtime_sha_before = binary_sha
      fail!('pinned ClickHouse executable SHA-256 mismatch before probe') unless @runtime_sha_before == BINARY_SHA256
      @helper_sha_before = sha(@helper)
      @source_sha_before = source_hashes

      @stage = 'stock Wide and Compact fixture creation/readback'
      native = run_native('native_source', initial_sql)
      assert_pin!(native)
      assert_native_success!(native)
      source = parse_native(native[:stdout])
      assert_native_fixture!(source)
      part_inventory = {}
      TABLES.each do |table|
        part = source.fetch(:parts).fetch(table)
        path = validate_native_part_path!(part[:path])
        expected_type = table == WIDE_TABLE ? 'Wide' : 'Compact'
        part_inventory[table] = inspect_part(table, path, part, expected_type)
      end

      @stage = 'public typed Wide control and Compact behavioral rejection'
      helper = run_helper(TABLES.map { |table| source.fetch(:parts).fetch(table).fetch(:path) })
      assert_helper!(helper.fetch(:data), part_inventory)

      @stage = 'stable evidence and summary'
      @runtime_sha_after = binary_sha
      @helper_sha_after = sha(@helper)
      @source_sha_after = source_hashes
      fail!('pinned ClickHouse executable changed during probe') unless @runtime_sha_after == BINARY_SHA256
      fail!('prebuilt helper changed during probe') unless @helper_sha_after == @helper_sha_before
      fail!('probe source changed during probe') unless @source_sha_after == @source_sha_before

      write_summary(
        status: 'stock_compact_physical_windows_green_typed_reader_guards_red', native: source,
        parts: part_inventory, helper: helper[:data], native_invocation: native[:record],
        helper_invocation: helper[:record],
      )
      puts "W259 status=stock_compact_physical_windows_green_typed_reader_guards_red; tables=#{TABLES.join(',')}; rows=#{ROWS.size}; marks=#{MARK_ROWS_WITH_TERMINAL.inspect}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @runtime_sha_after = binary_sha rescue nil
      @helper_sha_after = sha(@helper) rescue nil
      @source_sha_after = source_hashes rescue nil
      write_summary(status: 'runner_failure_or_observations_differ', fatal_error: @fatal_error) rescue nil
      warn "W259 #{@stage} failed: #{@fatal_error}"
      false
    end

    private

    def fail!(message)
      raise Failure, "W259 Compact physical-context probe: #{message}"
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
      @capture.send(:write_new, File.join(@root, 'invocations', "#{label}.stdin.sql"), sql.b)
      argv = [@binary, 'local', '--path', @store, '--session_timezone=UTC', '--max_threads=1',
              "--max_memory_usage=#{W185::MEMORY}", '--output_format_json_quote_64bit_integers=0', '--multiquery']
      before_sha = binary_sha
      fail!('pinned ClickHouse executable SHA-256 mismatch before invocation') unless before_sha == BINARY_SHA256
      invocation = @capture.send(:execute_record, label, argv, sql.b, 'clickhouse local', BINARY_SHA256, @binary)
      invocation[:record][:binary_sha_before] = before_sha
      invocation[:record][:binary_sha_after] = binary_sha
      fail!('pinned ClickHouse executable changed during invocation') unless invocation[:record][:binary_sha_after] == BINARY_SHA256
      @invocations << invocation[:record]
      fail!("#{label} stdout exceeds #{MAX_CAPTURE_BYTES} bytes") if invocation[:stdout].bytesize > MAX_CAPTURE_BYTES
      fail!("#{label} stderr exceeds #{MAX_CAPTURE_BYTES} bytes") if invocation[:stderr].bytesize > MAX_CAPTURE_BYTES
      invocation
    end

    def run_helper(paths)
      argv = [@helper, 'roundtrip', *paths]
      before_sha = sha(@helper)
      invocation = @capture.send(:execute_record, 'public_reader_probe', argv, ''.b,
                                 'prebuilt Crystal helper', nil, nil)
      after_sha = sha(@helper)
      invocation[:record][:helper_sha_before] = before_sha
      invocation[:record][:helper_sha_after] = after_sha
      @invocations << invocation[:record]
      fail!('prebuilt helper changed during invocation') unless before_sha == after_sha
      fail!("helper stdout exceeds #{MAX_CAPTURE_BYTES} bytes") if invocation[:stdout].bytesize > MAX_CAPTURE_BYTES
      fail!("helper stderr exceeds #{MAX_CAPTURE_BYTES} bytes") if invocation[:stderr].bytesize > MAX_CAPTURE_BYTES
      unless invocation[:classification] == 'success' && invocation[:status]&.success? && invocation[:status]&.termsig.nil?
        fail!('helper process failed; this is not an expected Compact format rejection')
      end
      fail!('helper wrote stderr') unless invocation[:stderr].empty?
      lines = invocation[:stdout].force_encoding(Encoding::UTF_8).lines.map(&:chomp).reject(&:empty?)
      fail!('helper must emit exactly one JSON record') unless lines.size == 1
      {data: JSON.parse(lines.fetch(0)), record: invocation[:record]}
    rescue JSON::ParserError => error
      fail!("helper output is not valid JSON: #{error.message}")
    end

    def assert_pin!(invocation)
      lines = invocation[:stdout].force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      observed = lines.find { |line| line.start_with?("#{TAG[:pin]}\t") }
      expected = "#{TAG[:pin]}\t#{VERSION}\t#{BUILD}"
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

    def settings_for(table)
      if table == WIDE_TABLE
        thresholds = ['min_rows_for_wide_part=0', 'min_bytes_for_wide_part=0']
        substream_marks = ['write_marks_for_substreams_in_compact_parts=0']
      else
        thresholds = ['min_rows_for_wide_part=1000000', 'min_bytes_for_wide_part=0']
        substream_marks = ["write_marks_for_substreams_in_compact_parts=#{table == MRK4_TABLE ? 1 : 0}"]
      end
      (COMMON_SETTINGS + thresholds + substream_marks).join(', ')
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

    def create_sql(table)
      declarations = SCHEMA.map { |name, type| "#{name} #{type}" }.join(', ')
      "CREATE TABLE default.#{table} (#{declarations}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings_for(table)};"
    end

    def insert_sql(table)
      rows = ROWS.map { |row| "(#{row_value_sql(row)})" }.join(",\n")
      "INSERT INTO default.#{table} VALUES\n#{rows};"
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
      statements = ["SELECT '#{TAG[:pin]}', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;"]
      TABLES.each { |table| statements << create_sql(table) }
      TABLES.each { |table| statements << insert_sql(table) }
      TABLES.each { |table| statements << check_sql(table) }
      statements << "SELECT '#{TAG[:schema]}', table, name, type FROM system.columns WHERE database='default' AND table IN ('#{TABLES.join("','")}') ORDER BY table, position FORMAT TSVRaw;"
      TABLES.each do |table|
        statements << row_sql(table)
        statements << row_sql(table, middle: true)
      end
      statements << "SELECT '#{TAG[:part]}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table IN ('#{TABLES.join("','")}') AND active ORDER BY table, name FORMAT TSVRaw;"
      statements.join("\n") + "\n"
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
          fail!('nested CHECK begin marker') if active_check
          marker = line.split("\t", -1)
          fail!('malformed CHECK begin marker') unless marker.size == 2 && TABLES.include?(marker[1])
          active_check = marker.fetch(1)
          fail!("duplicate CHECK marker for #{active_check}") if checks.key?(active_check)
          checks[active_check] = []
        elsif line.start_with?("#{TAG[:check_end]}\t")
          marker = line.split("\t", -1)
          fail!('malformed CHECK end marker') unless marker.size == 2 && TABLES.include?(marker[1])
          ended = marker.fetch(1)
          fail!("unpaired CHECK marker for #{ended}") unless active_check == ended
          active_check = nil
        elsif active_check
          checks[active_check] << line
        end
      end
      fail!('unterminated CHECK output block') if active_check

      parts = {}
      fields.call(TAG[:part]).each do |field|
        fail!('native query returned malformed part metadata') unless field.size == 7
        table = field.fetch(1)
        fail!("native query returned multiple active parts for #{table}") if parts.key?(table)
        parts[table] = {name: field.fetch(2), path: field.fetch(3), part_type: field.fetch(4),
                        rows: field.fetch(5), native_mark_count: field.fetch(6)}
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
      {checks: checks, schemas: schemas, parts: parts, rows: rows, middle_rows: middle_rows}
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

    def expected_schema
      TABLES.sort.flat_map { |table| SCHEMA.map { |name, type| [table, name, type] } }
    end

    def expected_native_rows(rows = ROWS)
      rows.map do |row|
        {pk: row[:pk], u: row[:u], side: row[:side], arr: row[:arr], tup: row[:tup], lc: row[:lc],
         v_type: row[:v_type] == 'NULL' ? 'None' : row[:v_type], v: row[:v]}
      end
    end

    def assert_native_fixture!(native)
      fail!('native part roster is not exactly one active part per fixture table') unless native[:parts].keys.sort == TABLES.sort
      fail!('native CHECK roster differs from the fixture tables') unless native[:checks].keys.sort == TABLES.sort
      TABLES.each do |table|
        fail!("#{table} CHECK differs: #{native[:checks][table].inspect}") unless native[:checks][table] == ["#{PART_NAME}\t1\t"]
      end
      fail!('native system.columns roster differs from the seven-column literal schema') unless native[:schemas] == expected_schema
      TABLES.each do |table|
        fail!("#{table} full stock rows differ from independent literals") unless native[:rows][table] == expected_native_rows
        fail!("#{table} middle stock rows differ from independent literals") unless native[:middle_rows][table] == expected_native_rows(ROWS[2, 4])
      end
      fail!('native row query returned unexpected tables') unless native[:rows].keys.sort == TABLES.sort && native[:middle_rows].keys.sort == TABLES.sort
      TABLES.each do |table|
        part = native[:parts].fetch(table)
        expected_type = table == WIDE_TABLE ? 'Wide' : 'Compact'
        fail!("#{table} is not the intended #{expected_type} part") unless
          part[:name] == PART_NAME && part[:part_type] == expected_type && part[:rows] == '8' && part[:native_mark_count] == '5'
        validate_native_part_path!(part[:path])
      end
    end

    def expected_signatures(rows = ROWS)
      VALUE_COLUMNS.each_with_object({}) do |column, result|
        result[column] = rows.map { |row| signature_for(column, row) }
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
        fail!("missing independent signature oracle for #{column}")
      end
    end

    def assert_helper!(result, part_inventory)
      fail!('helper format/version differs') unless result['format'] == HELPER_FORMAT
      wide = result.fetch('wide_control')
      fail!('Wide helper control did not return typed success') unless wide['status'] == 'ok'
      fail!('Wide control mark rows differ from four 2-row data marks') unless wide['mark_row_counts'] == [MARK_ROWS]
      verify_scan!(wide.fetch('full'), ROWS.map { |row| row[:pk] }, expected_signatures, 'Wide full')
      verify_scan!(wide.fetch('middle'), ROWS[2, 4].map { |row| row[:pk] }, expected_signatures(ROWS[2, 4]), 'Wide middle')
      expected_compact_reports = {
        'compact_mrk3' => {
          'status' => 'unsupported',
          'stage' => 'open',
          'error' => 'CrystalClick::UnsupportedFormatError: columns_substreams.txt is required for multi-column parts',
        },
        'compact_mrk4' => {
          'status' => 'missing_wide_streams',
          'stage' => 'open',
          'error' => 'CrystalClick::InvalidPartError: selected numeric stream files not found',
        },
      }
      expected_compact_reports.each do |name, expected|
        compact = result.fetch(name)
        unless compact['status'] == expected['status'] && compact['stage'] == expected['stage'] && compact['error'] == expected['error']
          fail!("#{name} baseline report differs from its exact expected guard: #{compact.inspect}")
        end
      end

      physical = result.fetch('compact_physical')
      fail!('raw Compact physical report modes differ') unless physical.keys.sort == %w[mrk3 mrk4]
      {'mrk3' => MRK3_TABLE, 'mrk4' => MRK4_TABLE}.each do |mode, table|
        expected = part_inventory.fetch(table).fetch(:compact_physical_expected)
        mode_report = physical.fetch(mode)
        fail!("#{mode} physical report envelope differs") unless mode_report.keys == ['windows']
        actual = mode_report.fetch('windows')
        fail!("#{mode} raw physical report differs from independent part-byte oracle") unless actual == expected
      end
    end

    def verify_scan!(scan, keys, columns, label)
      fail!("#{label} typed keys differ from independent literals") unless scan['keys'] == keys
      fail!("#{label} typed column signatures differ from independent literals") unless scan['columns'] == columns
      fail!("#{label} typed column set differs") unless scan['columns'].keys.sort == VALUE_COLUMNS.sort
      columns.each do |name, values|
        fail!("#{label} #{name} count differs from key alignment") unless scan['columns'].fetch(name).size == keys.size && values.size == keys.size
      end
    end

    def inspect_part(label, path, part, expected_type)
      fail!("#{label} part directory is absent or symlinked") unless File.directory?(path) && !File.symlink?(path)
      entries = []
      total_bytes = 0
      Find.find(path) do |entry|
        stat = File.lstat(entry)
        fail!("#{label} part contains a symlink") if stat.symlink?
        next if entry == path
        if stat.directory?
          next
        elsif stat.file?
          relative = entry.delete_prefix(path + File::SEPARATOR)
          total_bytes += stat.size
          fail!("#{label} part exceeds byte bound") if total_bytes > MAX_PART_BYTES
          entries << {path: relative, bytes: stat.size, sha256: sha(entry)}
          fail!("#{label} part exceeds file bound") if entries.size > MAX_PART_FILES
        else
          fail!("#{label} part contains a non-regular entry")
        end
      end
      entries.sort_by! { |file| file[:path] }
      by_path = entries.each_with_object({}) { |file, index| index[file[:path]] = file }
      has_substream_roster = expected_type == 'Wide' || label == MRK4_TABLE
      required_files = %w[columns.txt count.txt checksums.txt primary.idx serialization.json default_compression_codec.txt metadata_version.txt]
      required_files << 'columns_substreams.txt' if has_substream_roster
      required_files.each do |name|
        fail!("#{label} is missing #{name}") unless by_path.key?(name)
      end
      if !has_substream_roster && by_path.key?('columns_substreams.txt')
        fail!("#{label} unexpectedly has columns_substreams.txt for the Compact-without-substream-marks layout")
      end
      fail!("#{label} count.txt differs") unless File.read(File.join(path, 'count.txt')).strip == '8'
      fail!("#{label} part type changed after query") unless part[:part_type] == expected_type
      fail!("#{label} raw Compact oracle requires default CODEC(LZ4)") unless
        File.read(File.join(path, 'default_compression_codec.txt')).strip == 'CODEC(LZ4)'

      serialization_text = File.binread(File.join(path, 'serialization.json')).force_encoding(Encoding::UTF_8)
      serialization = JSON.parse(serialization_text)
      fail!("#{label} serialization metadata version differs") unless serialization['version'] == 1
      fail!("#{label} nested serialization version propagation differs") unless serialization['propagate_types_serialization_versions_to_nested_types'] == true
      fail!("#{label} String serialization version differs") unless serialization.dig('types_serialization_versions', 'string') == 1

      substreams = if has_substream_roster
                     parse_substreams(File.binread(File.join(path, 'columns_substreams.txt')).force_encoding(Encoding::UTF_8), label)
                   end
      roster = substreams && substreams.fetch(:columns)
      if roster
        fail!("#{label} substream roster columns differ from schema") unless roster.map { |entry| entry[:column] } == SCHEMA.map(&:first)
        fail!("#{label} contains an empty column substream roster") if roster.any? { |entry| entry[:streams].empty? }
      end

      expected_ext = expected_type == 'Wide' ? '.mrk2' : (label == MRK3_TABLE ? '.mrk3' : '.mrk4')
      mark_files = entries.select { |file| file[:path].match?(/\.c?mrk\d*\z/) }
      fail!("#{label} has compressed or unexpected mark files") unless mark_files.size.positive? && mark_files.all? { |file| file[:path].end_with?(expected_ext) }
      data_files = entries.select { |file| file[:path].end_with?('.bin') }
      if expected_type == 'Compact'
        fail!("#{label} Compact part lacks exactly one data.bin") unless data_files.map { |file| file[:path] } == ['data.bin']
        fail!("#{label} Compact part lacks exactly one #{expected_ext} record file") unless mark_files.size == 1 && mark_files.first[:path] == "data#{expected_ext}"
      else
        fail!("#{label} Wide control unexpectedly has Compact data.bin") if data_files.any? { |file| file[:path] == 'data.bin' }
      end

      marks = mark_files.each_with_object({}) do |file, records_by_path|
        bytes = File.binread(File.join(path, file[:path]))
        fail!("#{label} #{file[:path]} changed since its inventory hash") unless
          bytes.bytesize == file[:bytes] && Digest::SHA256.hexdigest(bytes) == file[:sha256]
        expected_pairs = if expected_ext == '.mrk4'
                           substreams.fetch(:total_substreams)
                         elsif expected_ext == '.mrk3'
                           SCHEMA.size
                         else
                           nil
                         end
        records = if expected_ext == '.mrk2'
                    parse_wide_marks(bytes, label, file[:path])
                  else
                    parse_compact_marks(bytes, label, file[:path], expected_pairs)
                  end
        records_by_path[file[:path]] = records
      end
      if expected_type == 'Compact'
        marks_path = "data#{expected_ext}"
        mark_record = marks.fetch(marks_path)
        fail!("#{label} mark coordinate-pair count differs from source roster") unless
          mark_record[:coordinate_pairs] == (expected_ext == '.mrk4' ? substreams[:total_substreams] : SCHEMA.size)
      else
        fail!("#{label} Wide mark files lack the pk marks") if marks.empty?
        fail!("#{label} Wide mark grid differs") unless marks.values.all? { |record| record[:row_counts] == MARK_ROWS_WITH_TERMINAL }
      end

      compact_raw = if expected_type == 'Compact'
                      compact_raw_oracle!(label, path, expected_ext, substreams, mark_record, data_files.fetch(0))
                    end

      {
        label: label, path: path, part_name: part[:name], part_type: part[:part_type], rows: part[:rows],
        native_mark_count: part[:native_mark_count],
        count_text: File.read(File.join(path, 'count.txt')).strip,
        metadata_version: File.read(File.join(path, 'metadata_version.txt')).strip,
        default_compression_codec: File.read(File.join(path, 'default_compression_codec.txt')).strip,
        serialization_json: serialization,
        serialization_json_sha256: Digest::SHA256.hexdigest(serialization_text),
        columns_text: File.binread(File.join(path, 'columns.txt')).force_encoding(Encoding::UTF_8),
        columns_substreams_text: has_substream_roster ? File.binread(File.join(path, 'columns_substreams.txt')).force_encoding(Encoding::UTF_8) : nil,
        substream_roster: roster, total_substreams: substreams && substreams[:total_substreams],
        compact_data_file: expected_type == 'Compact' ? data_files.first : nil,
        compact_raw_stream: compact_raw && compact_raw.fetch(:stream_evidence),
        compact_physical_expected: compact_raw && compact_raw.fetch(:windows),
        mark_records: marks, files: entries,
      }
    rescue JSON::ParserError => error
      fail!("#{label} serialization.json is malformed: #{error.message}")
    end

    def parse_substreams(text, label)
      lines = text.lines.map(&:chomp)
      fail!("#{label} substream metadata version differs") unless lines.shift == 'columns substreams version: 1'
      header = lines.shift
      match = /\A([0-9]+) columns:\z/.match(header.to_s)
      fail!("#{label} columns_substreams.txt header is malformed") unless match
      column_count = match[1].to_i
      fail!("#{label} columns_substreams.txt column count differs") unless column_count == SCHEMA.size
      columns = []
      total = 0
      column_count.times do |index|
        line = lines.shift
        entry_match = /\A([0-9]+) substreams for column `([^`]+)`:\z/.match(line.to_s)
        fail!("#{label} substream column header is malformed: #{line.inspect}") unless entry_match
        count = entry_match[1].to_i
        name = entry_match[2]
        fail!("#{label} substream columns are reordered or unexpected") unless name == SCHEMA[index][0]
        streams = count.times.map do
          stream_line = lines.shift
          fail!("#{label} malformed substream entry #{stream_line.inspect}") unless stream_line && stream_line.start_with?("\t") && stream_line.bytesize > 1
          stream_line[1..-1]
        end
        fail!("#{label} has duplicate stream names within #{name}") unless streams.uniq == streams
        total += count
        columns << {column: name, streams: streams}
      end
      fail!("#{label} columns_substreams.txt has trailing records") unless lines.empty?
      {columns: columns, total_substreams: total}
    end

    def parse_wide_marks(bytes, label, path)
      fail!("#{label} #{path} is not an integral .mrk2 triple sequence") unless bytes.bytesize.positive? && (bytes.bytesize % 24).zero?
      triples = bytes.unpack('Q<*').each_slice(3).map(&:dup)
      fail!("#{label} #{path} does not have five mark triples") unless triples.size == 5
      row_counts = triples.map { |triple| triple[2] }
      fail!("#{label} #{path} row counts differ from [2,2,2,2,0]") unless row_counts == MARK_ROWS_WITH_TERMINAL
      {bytes: bytes.bytesize, record_count: triples.size, record_words: 3, row_counts: row_counts, records: triples}
    end

    def parse_compact_marks(bytes, label, path, coordinate_pairs)
      fail!("#{label} #{path} has no expected mark pairs") unless coordinate_pairs && coordinate_pairs.positive?
      width = (coordinate_pairs * 2) + 1
      fail!("#{label} #{path} is not an integral compact mark-record sequence") unless bytes.bytesize.positive? && (bytes.bytesize % (width * 8)).zero?
      records = bytes.unpack('Q<*').each_slice(width).map(&:dup)
      fail!("#{label} #{path} does not have five mark records") unless records.size == 5
      row_counts = records.map { |record| record.last }
      fail!("#{label} #{path} row counts differ from [2,2,2,2,0]") unless row_counts == MARK_ROWS_WITH_TERMINAL
      {bytes: bytes.bytesize, record_count: records.size, record_words: width,
       coordinate_pairs: coordinate_pairs, row_counts: row_counts, records: records}
    end

    def compact_raw_oracle!(label, path, extension, substreams, mark_record, data_file)
      fail!("#{label} raw Compact oracle received a non-Compact mark extension") unless %w[.mrk3 .mrk4].include?(extension)
      slots = compact_physical_slots!(label, extension, substreams)
      fail!("#{label} raw mark slot count differs from physical roster") unless slots.size == mark_record.fetch(:coordinate_pairs)
      fail!("#{label} raw mark rows differ from the literal grid") unless mark_record.fetch(:row_counts) == MARK_ROWS_WITH_TERMINAL

      compressed_path = File.join(path, data_file.fetch(:path))
      compressed = File.binread(compressed_path)
      fail!("#{label} data.bin changed since its inventory hash") unless
        compressed.bytesize == data_file.fetch(:bytes) && Digest::SHA256.hexdigest(compressed) == data_file.fetch(:sha256)
      decoded = decode_compact_frames!(label, compressed)
      decoded_bytes = decoded.fetch(:bytes)
      frames = decoded.fetch(:frames)

      positions = mark_record.fetch(:records).map.with_index do |record, mark_index|
        row_count = record.fetch(-1)
        expected_row_count = MARK_ROWS_WITH_TERMINAL.fetch(mark_index)
        fail!("#{label} mark #{mark_index} row count changed") unless row_count == expected_row_count
        slots.map do |slot|
          compressed_offset = record.fetch(slot.fetch(:global_index) * 2)
          decompressed_offset = record.fetch(slot.fetch(:global_index) * 2 + 1)
          raw_logical_position!(label, compressed_offset, decompressed_offset, compressed.bytesize, frames)
        end
      end
      fail!("#{label} first Compact physical slot does not start at logical byte zero") unless positions.fetch(0).fetch(0) == 0
      fail!("#{label} terminal Compact mark is not exactly (data.bin EOF, 0) for every slot") unless
        mark_record.fetch(:records).last.each_slice(2).take(slots.size).all? { |pair| pair == [compressed.bytesize, 0] }
      flattened_positions = positions.flatten
      unless flattened_positions.each_cons(2).all? { |left, right| left <= right }
        fail!("#{label} flattened Compact mark positions are not monotone")
      end
      fail!("#{label} terminal logical position differs from decoded data EOF") unless positions.last.all? { |position| position == decoded_bytes.bytesize }

      windows = compact_expected_windows!(label, extension, slots, positions, mark_record.fetch(:row_counts), decoded_bytes)
      {
        windows: {
          'mode' => extension.delete_prefix('.'),
          'mark_rows' => mark_record.fetch(:row_counts).take(MARK_ROWS.size),
          'columns' => windows,
        },
        stream_evidence: {
          'data_file' => data_file.fetch(:path),
          'compressed_bytes' => compressed.bytesize,
          'compressed_sha256' => data_file.fetch(:sha256),
          'decoded_bytes' => decoded_bytes.bytesize,
          'decoded_sha256' => Digest::SHA256.hexdigest(decoded_bytes),
          'frame_checksum_validation' => 'not independently recomputed; stock CHECK TABLE ran separately',
          'frames' => frames,
          'global_mark_positions' => positions,
          'slot_roster' => slots,
        },
      }
    end

    def compact_physical_slots!(label, extension, substreams)
      if extension == '.mrk3'
        return SCHEMA.each_with_index.map do |(column, _type), global_index|
          {column: column, stream_name: nil, global_index: global_index, column_slot_index: 0}
        end
      end

      fail!("#{label} .mrk4 source roster is absent") unless substreams
      global_index = 0
      substreams.fetch(:columns).flat_map do |column_entry|
        column_entry.fetch(:streams).each_with_index.map do |stream_name, column_slot_index|
          slot = {column: column_entry.fetch(:column), stream_name: stream_name,
                  global_index: global_index, column_slot_index: column_slot_index}
          global_index += 1
          slot
        end
      end
    end

    def decode_compact_frames!(label, compressed)
      fail!("#{label} Compact data.bin is empty") if compressed.empty?
      offset = 0
      decoded = ''.b
      frames = []
      while offset < compressed.bytesize
        fail!("#{label} compressed frame count exceeds #{MAX_RAW_FRAME_COUNT}") if frames.size >= MAX_RAW_FRAME_COUNT
        remaining = compressed.bytesize - offset
        fail!("#{label} compressed frame header is truncated at #{offset}") if remaining < 25
        method = compressed.getbyte(offset + 16)
        fail!("#{label} data.bin frame at #{offset} is not LZ4 (method=0x#{method.to_s(16)})") unless method == 0x82
        compressed_size = compressed.byteslice(offset + 17, 4).unpack1('V')
        decompressed_size = compressed.byteslice(offset + 21, 4).unpack1('V')
        fail!("#{label} frame compressed size is invalid at #{offset}") if compressed_size < 9
        fail!("#{label} frame decoded size is zero or above configured 4096-byte block limit at #{offset}") if
          decompressed_size.zero? || decompressed_size > MAX_RAW_FRAME_DECOMPRESSED_BYTES
        fail!("#{label} aggregate decoded data exceeds #{MAX_RAW_DECOMPRESSED_BYTES} bytes") if
          decompressed_size > MAX_RAW_DECOMPRESSED_BYTES - decoded.bytesize
        frame_end = offset + 16 + compressed_size
        fail!("#{label} compressed frame extends past data.bin at #{offset}") if frame_end > compressed.bytesize
        payload_start = offset + 25
        payload_size = compressed_size - 9
        payload = compressed.byteslice(payload_start, payload_size)
        fail!("#{label} frame payload is truncated at #{offset}") unless payload && payload.bytesize == payload_size
        output = decode_lz4_block!(label, payload, decompressed_size)
        logical_start = decoded.bytesize
        decoded << output
        frames << {
          compressed_start: offset, compressed_end: frame_end,
          logical_start: logical_start, logical_end: decoded.bytesize,
          compressed_size: compressed_size, decompressed_size: decompressed_size,
          method: method,
        }
        offset = frame_end
      end
      fail!("#{label} data.bin has no complete compressed frames") if frames.empty?
      fail!("#{label} data.bin frame walk left trailing bytes") unless offset == compressed.bytesize
      {bytes: decoded, frames: frames}
    end

    def decode_lz4_block!(label, input, expected_size)
      output = ''.b
      input_index = 0
      while input_index < input.bytesize
        token = input.getbyte(input_index)
        input_index += 1
        literal_length, input_index = raw_lz4_length!(label, input, input_index, token >> 4)
        fail!("#{label} LZ4 literal overruns input") if literal_length > input.bytesize - input_index
        fail!("#{label} LZ4 literal overruns declared output") if literal_length > expected_size - output.bytesize
        output << input.byteslice(input_index, literal_length)
        input_index += literal_length
        break if input_index == input.bytesize

        fail!("#{label} LZ4 match offset is truncated") if input.bytesize - input_index < 2
        distance = input.getbyte(input_index) | (input.getbyte(input_index + 1) << 8)
        input_index += 2
        fail!("#{label} LZ4 match distance is invalid") if distance.zero? || distance > output.bytesize
        match_length, input_index = raw_lz4_length!(label, input, input_index, token & 0x0f)
        match_length += 4
        fail!("#{label} LZ4 match overruns declared output") if match_length > expected_size - output.bytesize
        match_length.times { output << output.getbyte(output.bytesize - distance) }
      end
      fail!("#{label} LZ4 decoded length #{output.bytesize} differs from declared #{expected_size}") unless output.bytesize == expected_size
      output
    end

    def raw_lz4_length!(label, input, input_index, nibble)
      length = nibble
      return [length, input_index] unless length == 15

      loop do
        fail!("#{label} LZ4 extended length is truncated") if input_index >= input.bytesize
        extension = input.getbyte(input_index)
        input_index += 1
        length += extension
        fail!("#{label} LZ4 extended length exceeds bounded output") if length > MAX_RAW_FRAME_DECOMPRESSED_BYTES
        break if extension != 255
      end
      [length, input_index]
    end

    def raw_logical_position!(label, compressed_offset, decompressed_offset, compressed_size, frames)
      if compressed_offset == compressed_size
        fail!("#{label} EOF coordinate has nonzero decompressed offset") unless decompressed_offset.zero?
        return frames.last.fetch(:logical_end)
      end
      fail!("#{label} mark compressed offset exceeds data.bin") if compressed_offset > compressed_size
      frame = frames.find { |candidate| candidate.fetch(:compressed_start) == compressed_offset }
      fail!("#{label} mark compressed offset #{compressed_offset} does not identify a frame start") unless frame
      fail!("#{label} mark decompressed offset exceeds its frame") if decompressed_offset > frame.fetch(:decompressed_size)
      frame.fetch(:logical_start) + decompressed_offset
    end

    def compact_expected_windows!(label, extension, slots, positions, row_counts, decoded_bytes)
      schema_columns = SCHEMA.map(&:first)
      grouped_slots = schema_columns.each_with_object({}) { |column, grouped| grouped[column] = [] }
      slots.each { |slot| grouped_slots.fetch(slot.fetch(:column)) << slot }
      fail!("#{label} physical roster column set differs from schema") unless grouped_slots.keys.sort == schema_columns.sort

      grouped_slots.each_with_object({}) do |(column, column_slots), expected_columns|
        expected_columns[column] = RAW_WINDOWS.each_with_object({}) do |(window_name, (first_mark, count)), column_windows|
          granules = count.times.map do |offset|
            mark = first_mark + offset
            row_offset = row_counts.take(mark).sum
            shards = column_slots.map do |slot|
              global_index = slot.fetch(:global_index)
              logical_start = positions.fetch(mark).fetch(global_index)
              logical_end = if global_index + 1 < slots.size
                              positions.fetch(mark).fetch(global_index + 1)
                            else
                              positions.fetch(mark + 1).fetch(0)
                            end
              fail!("#{label} #{column} slot #{global_index} has a reversed logical interval") if logical_end < logical_start
              bytes = decoded_bytes.byteslice(logical_start, logical_end - logical_start)
              fail!("#{label} #{column} slot #{global_index} logical range escaped decoded data") unless
                bytes && bytes.bytesize == logical_end - logical_start
              {
                'slot_index' => global_index,
                'stream_name' => extension == '.mrk3' ? nil : slot.fetch(:stream_name),
                'logical_start' => logical_start,
                'logical_end' => logical_end,
                'bytes_hex' => bytes.unpack1('H*'),
              }
            end
            {'mark' => mark, 'row_offset' => row_offset, 'row_count' => row_counts.fetch(mark), 'shards' => shards}
          end
          column_windows[window_name] = {
            'mode' => extension.delete_prefix('.'),
            'column' => column,
            'first_mark' => first_mark,
            'row_offset' => row_counts.take(first_mark).sum,
            'granules' => granules,
          }
        end
      end
    end

    def validate_native_part_path!(path)
      fail!('native part path is absent') unless path && !path.empty?
      full = File.expand_path(path)
      fail!("native part path escaped isolated store: #{path}") unless full.start_with?(@store + File::SEPARATOR)
      full
    end

    def write_summary(data)
      summary = {
        probe: FORMAT, status: data[:status], fatal_error: data[:fatal_error], stage: @stage,
        claim_boundary: 'one seven-column static fixture and one pinned runtime; Wide is a positive typed control; Compact physical windows are compared only for these literal parts; typed Compact remains at exact baseline guards; no general Compact compatibility claim',
        source_snapshot: SOURCE_SNAPSHOT,
        source_contract: {
          writer: [
            'Pinned ed30948f095ecb70679986d7d60e27ad770ae27a source builds the mrk4 roster by replaying each column prefix, empty-range bulk, and suffix hooks into a getter that records unique names in first-seen order (MergeTreeDataPartWriterOnDisk.cpp:727-744; ColumnsSubstreams.cpp:40-52).',
            'The live Compact writer replays prefix/bulk/suffix per column and emits substream marks in getter-call order (MergeTreeDataPartWriterCompact.cpp:174-205,306-369); mrk3 instead stores one coordinate pair per column.',
            'Next-global-slot interval interpretation is qualified to the observed monotone grid and matching callback-roster profile, not arbitrary serializers.'
          ].join(' '),
          source_runtime_relation: 'source snapshot and executable are separately pinned; source provenance for the executable is not asserted',
        },
        raw_oracle: {
          method: 'runner-owned Ruby frame walk and raw LZ4 block decoder; independently maps global .mrk3/.mrk4 slots to decoded data.bin ranges, then compares all per-column full/first/middle/last/EOF shards against helper bytes',
          window_end_rule: 'each slot ends at the next global slot in the same granule, or the first global slot of the next granule for the final slot',
          frame_checksum: 'CityHash128 is not independently recomputed; SHA-256 snapshots and stock CHECK TABLE are separate evidence',
          raw_frame_limit_bytes: MAX_RAW_FRAME_DECOMPRESSED_BYTES,
          raw_frame_count_limit: MAX_RAW_FRAME_COUNT,
          raw_decoded_stream_limit_bytes: MAX_RAW_DECOMPRESSED_BYTES,
        },
        runtime: {path: @binary, expected_sha256: BINARY_SHA256, sha256_before: @runtime_sha_before,
                  sha256_after: @runtime_sha_after, expected_version: VERSION, expected_build: BUILD},
        helper: {path: @helper, protocol: HELPER_FORMAT, mode: 'roundtrip WIDE_PART COMPACT_MRK3_PART COMPACT_MRK4_PART',
                 sha256_before: @helper_sha_before, sha256_after: @helper_sha_after,
                 source_provenance: 'the prebuilt helper is identified by hash; compilation from current source is not asserted',
                 source_files_before: @source_sha_before, source_files_after: @source_sha_after},
        settings: TABLES.to_h { |table| [table, settings_for(table)] }, schema: SCHEMA, independent_rows: ROWS,
        mark_grid: {rows_per_data_mark: ROWS_PER_MARK, data_mark_rows: MARK_ROWS,
                    expected_terminal_row_count: 0, wide_mark_rows_with_terminal: MARK_ROWS_WITH_TERMINAL,
                    array_empty_marks: [0, 2]},
        limits: {max_threads: 1, max_memory_usage_bytes_per_native_process: W185::MEMORY,
                 timeout_seconds: W180::PROCESS_TIMEOUT_SECONDS,
                 termination_grace_seconds: W180::TERMINATION_GRACE_SECONDS,
                 max_capture_bytes_per_stream: MAX_CAPTURE_BYTES,
                 part_max_files: MAX_PART_FILES, part_max_bytes: MAX_PART_BYTES,
                 raw_max_frame_decompressed_bytes: MAX_RAW_FRAME_DECOMPRESSED_BYTES,
                 raw_max_frame_count: MAX_RAW_FRAME_COUNT,
                 raw_max_total_decoded_bytes: MAX_RAW_DECOMPRESSED_BYTES,
                 capture_note: 'W180 executor applies the deadline and process management; output is rejected after capture if it exceeds the 1 MiB artifact bound'},
        evidence_root: @root, invocations: @invocations,
      }.merge(data.reject { |key, _| %i[status fatal_error].include?(key) })
      @capture.send(:write_new, File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
    end
  end
end

def main
  options = {binary: ProbeCompactPhysicalContextW259::BINARY}
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/probe_compact_physical_context_w259.rb --helper PREBUILT_HELPER --evidence-root EMPTY_DIRECT_CHILD_OF_PRIVATE_TMP [--binary CLICKHOUSE]'
    parser.on('--binary PATH') { |value| options[:binary] = value }
    parser.on('--helper PATH') { |value| options[:helper] = value }
    parser.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
  end.parse!
  raise 'prebuilt helper is required via --helper' unless options[:helper]
  exit(ProbeCompactPhysicalContextW259::Probe.new(**options).run ? 0 : 1)
rescue StandardError => error
  warn "W259 probe runner error: #{error.class}: #{error.message}"
  exit 1
end

main if $PROGRAM_NAME == __FILE__
