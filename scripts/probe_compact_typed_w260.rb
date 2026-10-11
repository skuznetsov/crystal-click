#!/usr/bin/env ruby
# Reciprocal stock-native qualification for W260's typed Compact reader.
# The runner creates real Wide/.mrk2 and Compact/.mrk3/.mrk4 parts, checks
# ClickHouse's own CHECK/schema/literal values, then passes the actual parts to
# a separately prebuilt Crystal helper. It never builds either executable.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require_relative 'stock_part_probe_support_w191'

module ProbeCompactTypedW260
  FORMAT = 'compact_typed_w260_native_capture_v1'.freeze
  HELPER_FORMAT = 'compact_typed_w260_helper_v1'.freeze
  HELPER_SOURCE = File.expand_path('check_compact_typed_w260.cr', __dir__).freeze
  FIXTURE_SOURCE = File.expand_path('support/compact_typed_w260_fixture.cr', __dir__).freeze
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

  PART_NAME = 'all_1_1_0'.freeze
  WIDE_TABLE = 'wide_control'.freeze
  COMPACT_LABELS = %w[
    a_mrk3_s0_vbasic a_mrk3_s0_vcompact a_mrk3_s1_vbasic a_mrk3_s1_vcompact
    a_mrk4_s0_vbasic a_mrk4_s0_vcompact a_mrk4_s1_vbasic a_mrk4_s1_vcompact
    b_mrk3 b_mrk4
  ].freeze
  TABLES = ([WIDE_TABLE] + COMPACT_LABELS).freeze
  MARK_ROWS = [2, 2, 2, 2].freeze
  MARK_ROWS_WITH_EOF = [2, 2, 2, 2, 0].freeze
  MAX_CAPTURE_BYTES = 8 * 1024 * 1024
  MAX_PART_FILES = 4096
  MAX_PART_BYTES = 64 * 1024 * 1024

  SCHEMA_A = [
    ['pk', 'UInt64'], ['s', 'String'], ['n', 'Nullable(UInt64)'],
    ['arr', 'Array(Nullable(UInt64))'],
    ['pair', 'Tuple(left String, right String, code UInt64)'],
    ['seq', 'Array(Tuple(label String, value Nullable(UInt64)))'],
    ['lookup', 'Map(String, Array(Nullable(UInt64)))'],
    ['lc', 'LowCardinality(String)'], ['v', 'Variant(String, UInt64)'],
  ].map(&:freeze).freeze
  # Native Wide stays a nine-column CHECK/schema/value control. Its typed
  # control deliberately uses only the inherited supported seven-column set.
  SELECTED_WIDE = %w[pk s n arr pair lc v].freeze
  SCHEMA_B = [
    ['pk', 'UInt64'], ['label', 'String'],
    ['pair', 'Tuple(l Array(LowCardinality(UInt64)), v Array(Variant(String, UInt64)))'],
  ].map(&:freeze).freeze

  # Ruby-owned literals are the independent native and helper oracle. The
  # Crystal support fixture does not supply values to this runner.
  ROWS_A = [
    {pk: 7101, s: 'root-0', n: nil, arr: [], pair: ['left-0', 'right-0', 7301], seq: [], lookup: [], lc: 'dup', v_type: 'String', v: 'repeat'},
    {pk: 7102, s: 'root-1', n: 7202, arr: [], pair: ['left-1', 'right-1', 7302], seq: [], lookup: [], lc: 'dup', v_type: 'String', v: 'repeat'},
    {pk: 7103, s: 'root-2', n: nil, arr: [nil, 17], pair: ['left-2', 'right-2', 7303], seq: [['a', nil], ['b', 7403]], lookup: [['a', [nil, 7503]]], lc: 'green', v_type: 'UInt64', v: 7603},
    {pk: 7104, s: 'root-3', n: 7204, arr: [23], pair: ['left-3', 'right-3', 7304], seq: [], lookup: [], lc: '', v_type: 'UInt64', v: 7603},
    {pk: 7105, s: 'root-4', n: nil, arr: [], pair: ['left-4', 'right-4', 7305], seq: [], lookup: [], lc: 'blue', v_type: 'NULL', v: nil},
    {pk: 7106, s: 'root-5', n: 7206, arr: [], pair: ['left-5', 'right-5', 7306], seq: [], lookup: [], lc: 'blue', v_type: 'NULL', v: nil},
    {pk: 7107, s: 'root-6', n: 7207, arr: [7, 8, nil], pair: ['left-6', 'right-6', 7307], seq: [['z', 7407]], lookup: [['x', [7507, 7508]], ['empty', []]], lc: 'dup', v_type: 'String', v: 'last'},
    {pk: 7108, s: 'root-7', n: nil, arr: [nil, 9], pair: ['left-7', 'right-7', 7308], seq: [['tail', nil]], lookup: [['tail', [nil, 7508]]], lc: 'tail', v_type: 'UInt64', v: 7608},
  ].map(&:freeze).freeze
  ROWS_B = [
    {pk: 8101, label: 'b-0', left: [], right: []},
    {pk: 8102, label: 'b-1', left: [], right: []},
    {pk: 8103, label: 'b-2', left: [42, 42], right: [['String', 'inside-2'], ['UInt64', 8203]]},
    {pk: 8104, label: 'b-3', left: [43], right: [['UInt64', 8204]]},
    {pk: 8105, label: 'b-4', left: [], right: []},
    {pk: 8106, label: 'b-5', left: [], right: []},
    {pk: 8107, label: 'b-6', left: [42], right: [['String', 'inside-6']]},
    {pk: 8108, label: 'b-7', left: [44], right: [['UInt64', 8208]]},
  ].map(&:freeze).freeze

  TAG = {
    pin: '__W260_PIN__', check_begin: '__W260_CHECK_BEGIN__', check_end: '__W260_CHECK_END__',
    schema: '__W260_SCHEMA__', part: '__W260_PART__', rows_a: '__W260_ROW_A__',
    middle_a: '__W260_MIDDLE_A__', rows_b: '__W260_ROW_B__', middle_b: '__W260_MIDDLE_B__',
  }.freeze

  class Failure < StandardError; end

  class Probe
    def initialize(binary:, helper:, evidence_root:)
      @binary = validate_executable(binary, 'ClickHouse')
      @helper = validate_executable(helper, 'prebuilt Crystal helper')
      @root = validate_root(evidence_root)
      @capture = StockPartProbeSupportW191.new(@binary, @root)
      @store = File.join(@root, 'stores', 'native')
      @catalog_root = File.join(@root, 'offline_catalog')
      @invocations = []
      @stage = 'not_started'
      @source_files = [__FILE__, HELPER_SOURCE, FIXTURE_SOURCE,
                       File.expand_path('stock_part_probe_support_w191.rb', __dir__),
                       File.expand_path('check_array_json_parts_w185.rb', __dir__)].map { |path| File.realpath(path) }.uniq.sort
    end

    def run
      prepare_layout!
      @runtime_sha_before = sha(@binary)
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

      @stage = 'offline catalog copy and MV-source setup'
      catalog = prepare_offline_catalog!(source.fetch(:parts))
      manifest_path = write_manifest!(catalog, source.fetch(:parts))

      @stage = 'format-neutral public typed Compact helper'
      helper = run_helper(source.fetch(:parts).fetch(WIDE_TABLE).fetch(:path), manifest_path)
      assert_helper!(helper.fetch(:data), catalog.fetch(:mv_target_path))

      @stage = 'stable evidence and summary'
      @runtime_sha_after = sha(@binary)
      @helper_sha_after = sha(@helper)
      @source_sha_after = source_hashes
      fail!('pinned ClickHouse executable changed during probe') unless @runtime_sha_after == BINARY_SHA256
      fail!('prebuilt helper changed during probe') unless @helper_sha_after == @helper_sha_before
      fail!('probe source changed during probe') unless @source_sha_after == @source_sha_before
      fail!('native part inventory changed during helper execution') unless
        TABLES.to_h { |table| [table, file_snapshot(source.fetch(:parts).fetch(table).fetch(:path))] } ==
        TABLES.to_h { |table| [table, part_inventory.fetch(table).fetch(:files)] }
      catalog.fetch(:table_paths).each do |label, table_path|
        fail!("offline catalog part changed during helper execution: #{label}") unless
          file_snapshot(table_path.fetch(:part_path)) == table_path.fetch(:part_files_at_copy)
      end

      write_summary(
        status: 'stock_wide_and_compact_typed_values_green', native: source,
        parts: part_inventory, helper: helper[:data], catalog: catalog,
        native_invocation: native[:record], helper_invocation: helper[:record],
      )
      puts "W260 status=stock_wide_and_compact_typed_values_green; parts=#{TABLES.size}; compact=#{COMPACT_LABELS.size}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @runtime_sha_after = sha(@binary) rescue nil
      @helper_sha_after = sha(@helper) rescue nil
      @source_sha_after = source_hashes rescue nil
      write_summary(status: 'runner_failure_or_observations_differ', fatal_error: @fatal_error) rescue nil
      warn "W260 #{@stage} failed: #{@fatal_error}"
      false
    end

    private

    def fail!(message)
      raise Failure, "W260 Compact typed probe: #{message}"
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

    def source_hashes
      @source_files.map { |path| {path: path, sha256: sha(path)} }
    end

    def run_native(label, sql)
      fail!('unsafe invocation label') unless /\A[a-z0-9_]+\z/.match?(label)
      @capture.send(:write_new, File.join(@root, 'invocations', "#{label}.stdin.sql"), sql.b)
      argv = [@binary, 'local', '--path', @store, '--session_timezone=UTC', '--max_threads=1',
              "--max_memory_usage=#{W185::MEMORY}", '--output_format_json_quote_64bit_integers=0', '--multiquery']
      before_sha = sha(@binary)
      fail!('pinned ClickHouse executable SHA-256 mismatch before invocation') unless before_sha == BINARY_SHA256
      invocation = @capture.send(:execute_record, label, argv, sql.b, 'clickhouse local', BINARY_SHA256, @binary)
      invocation[:record][:binary_sha_before] = before_sha
      invocation[:record][:binary_sha_after] = sha(@binary)
      fail!('pinned ClickHouse executable changed during invocation') unless invocation[:record][:binary_sha_after] == BINARY_SHA256
      @invocations << invocation[:record]
      fail!("#{label} stdout exceeds #{MAX_CAPTURE_BYTES} bytes") if invocation[:stdout].bytesize > MAX_CAPTURE_BYTES
      fail!("#{label} stderr exceeds #{MAX_CAPTURE_BYTES} bytes") if invocation[:stderr].bytesize > MAX_CAPTURE_BYTES
      invocation
    end

    def run_helper(wide_part, manifest_path)
      argv = [@helper, 'roundtrip', wide_part, manifest_path]
      before_sha = sha(@helper)
      invocation = @capture.send(:execute_record, 'typed_public_reader_probe', argv, ''.b,
                                 'prebuilt Crystal helper', nil, nil)
      after_sha = sha(@helper)
      invocation[:record][:helper_sha_before] = before_sha
      invocation[:record][:helper_sha_after] = after_sha
      @invocations << invocation[:record]
      fail!('prebuilt helper changed during invocation') unless before_sha == after_sha
      fail!("helper stdout exceeds #{MAX_CAPTURE_BYTES} bytes") if invocation[:stdout].bytesize > MAX_CAPTURE_BYTES
      fail!("helper stderr exceeds #{MAX_CAPTURE_BYTES} bytes") if invocation[:stderr].bytesize > MAX_CAPTURE_BYTES
      unless invocation[:classification] == 'success' && invocation[:status]&.success? && invocation[:status]&.termsig.nil?
        fail!('helper process failed; an expected typed rejection is not a passing probe')
      end
      fail!('helper wrote stderr') unless invocation[:stderr].empty?
      lines = invocation[:stdout].force_encoding(Encoding::UTF_8).lines.map(&:chomp).reject(&:empty?)
      fail!('helper must emit exactly one JSON record') unless lines.size == 1
      {data: JSON.parse(lines.fetch(0)), record: invocation[:record]}
    rescue JSON::ParserError => error
      fail!("helper output is not valid JSON: #{error.message}")
    end

    def assert_pin!(invocation)
      pins = invocation[:stdout].force_encoding(Encoding::UTF_8).lines.map(&:chomp).select do |item|
        item.start_with?(TAG[:pin])
      end
      expected = "#{TAG[:pin]}\t#{VERSION}\t#{BUILD}"
      fail!("runtime pin marker is missing, duplicated, or contradictory: #{pins.inspect}") unless pins == [expected]
    end

    def assert_native_success!(invocation)
      unless invocation[:classification] == 'success' && invocation[:status]&.success? && invocation[:status]&.termsig.nil?
        fail!("ClickHouse process failed (#{invocation[:classification]})")
      end
      if W180::CLICKHOUSE_EXCEPTION.match?(invocation[:stderr]) || W180::SYSTEM_FAILURE.match?(invocation[:stderr])
        fail!('ClickHouse reported an exception or system error despite successful process classification')
      end
      fail!('ClickHouse wrote unclassified stderr') unless invocation[:stderr].empty?
    end

    def sql_string(value)
      "'#{value.to_s.gsub('\\') { '\\\\' }.gsub("'") { "\\'" }}'"
    end

    def nullable_uint64_sql(value)
      value.nil? ? "CAST(NULL, 'Nullable(UInt64)')" : "toUInt64(#{value})"
    end

    def array_nullable_uint64_sql(values)
      inner = values.map { |value| nullable_uint64_sql(value) }.join(', ')
      "CAST([#{inner}], 'Array(Nullable(UInt64))')"
    end

    def array_variant_sql(values)
      inner = values.map do |kind, value|
        scalar = case kind
                 when 'String' then sql_string(value)
                 when 'UInt64' then "toUInt64(#{value})"
                 when 'NULL' then 'CAST(NULL, \'Variant(String, UInt64)\')'
                 else fail!("unrecognized Variant input arm #{kind.inspect}")
                 end
        "CAST(#{scalar}, 'Variant(String, UInt64)')"
      end.join(', ')
      "CAST([#{inner}], 'Array(Variant(String, UInt64))')"
    end

    def row_a_sql(row)
      left, right, code = row.fetch(:pair)
      seq = row.fetch(:seq).map do |label, value|
        "tuple(#{sql_string(label)}, #{nullable_uint64_sql(value)})"
      end.join(', ')
      map = row.fetch(:lookup).map do |key, values|
        "#{sql_string(key)}, #{array_nullable_uint64_sql(values)}"
      end.join(', ')
      map_expression = map.empty? ? 'map()' : "map(#{map})"
      variant = case row.fetch(:v_type)
                when 'String' then sql_string(row.fetch(:v))
                when 'UInt64' then "toUInt64(#{row.fetch(:v)})"
                when 'NULL' then 'CAST(NULL, \'Variant(String, UInt64)\')'
                else fail!("unrecognized Variant input tag #{row.fetch(:v_type).inspect}")
                end
      [
        "toUInt64(#{row.fetch(:pk)})", sql_string(row.fetch(:s)), nullable_uint64_sql(row.fetch(:n)),
        array_nullable_uint64_sql(row.fetch(:arr)),
        "CAST(tuple(#{sql_string(left)}, #{sql_string(right)}, toUInt64(#{code})), 'Tuple(left String, right String, code UInt64)')",
        "CAST([#{seq}], 'Array(Tuple(label String, value Nullable(UInt64)))')",
        "CAST(#{map_expression}, 'Map(String, Array(Nullable(UInt64)))')",
        "CAST(#{sql_string(row.fetch(:lc))}, 'LowCardinality(String)')",
        "CAST(#{variant}, 'Variant(String, UInt64)')",
      ].join(', ')
    end

    def row_b_sql(row)
      left = row.fetch(:left).map { |value| "toUInt64(#{value})" }.join(', ')
      left_array = "CAST([#{left}], 'Array(LowCardinality(UInt64))')"
      right_array = array_variant_sql(row.fetch(:right))
      pair = "CAST(tuple(#{left_array}, #{right_array}), 'Tuple(l Array(LowCardinality(UInt64)), v Array(Variant(String, UInt64)))')"
      ["toUInt64(#{row.fetch(:pk)})", sql_string(row.fetch(:label)), pair].join(', ')
    end

    def schema_for(table)
      table.start_with?('b_') ? SCHEMA_B : SCHEMA_A
    end

    def settings_for(table)
      is_wide = table == WIDE_TABLE
      label = is_wide ? 'a_mrk4_s1_vbasic' : table
      mark_setting = if is_wide
                       'write_marks_for_substreams_in_compact_parts=0'
                     else
                       "write_marks_for_substreams_in_compact_parts=#{label.include?('mrk4') ? 1 : 0}"
                     end
      wide_thresholds = is_wide ?
        ['min_rows_for_wide_part=0', 'min_bytes_for_wide_part=0'] :
        ['min_rows_for_wide_part=1000000', 'min_bytes_for_wide_part=0']
      string_profile = label == 'b_mrk3' || label == 'b_mrk4' || label.include?('_s1_') ? 'with_size_stream' : 'single_stream'
      variant_mode = label.include?('vcompact') || label.start_with?('b_') ? 1 : 0
      [
        'index_granularity=2', 'index_granularity_bytes=10485760', 'enable_mixed_granularity_parts=1',
        'compress_marks=0', 'compress_primary_key=0', 'min_compress_block_size=0', 'max_compress_block_size=4096',
        'ratio_of_defaults_for_sparse_serialization=1', "default_compression_codec='LZ4'",
        "serialization_info_version='with_types'", 'propagate_types_serialization_versions_to_nested_types=1',
        "string_serialization_version='#{string_profile}'", "use_compact_variant_discriminators_serialization=#{variant_mode}",
        "nullable_serialization_version='basic'", "map_serialization_version='basic'",
        "map_serialization_version_for_zero_level_parts='basic'",
      ] + wide_thresholds + [mark_setting]
    end

    def create_sql(table)
      declarations = schema_for(table).map { |name, type| "`#{name}` #{type}" }.join(', ')
      "CREATE TABLE default.#{table} (#{declarations}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings_for(table).join(', ')};"
    end

    def insert_sql(table)
      rows = if table == WIDE_TABLE || table.start_with?('a_')
               ROWS_A.map { |row| "(#{row_a_sql(row)})" }
             else
               ROWS_B.map { |row| "(#{row_b_sql(row)})" }
             end
      "INSERT INTO default.#{table} VALUES\n#{rows.join(",\n")};"
    end

    def check_sql(table)
      ["SELECT '#{TAG[:check_begin]}', '#{table}' FORMAT TSVRaw;",
       "CHECK TABLE default.#{table} FORMAT TSV;",
       "SELECT '#{TAG[:check_end]}', '#{table}' FORMAT TSVRaw;"].join("\n")
    end

    def row_query(table, middle: false)
      schema_b = table.start_with?('b_')
      marker = if schema_b
                 middle ? TAG[:middle_b] : TAG[:rows_b]
               else
                 middle ? TAG[:middle_a] : TAG[:rows_a]
               end
      low = schema_b ? 8103 : 7103
      high = schema_b ? 8106 : 7106
      predicate = middle ? " WHERE pk BETWEEN #{low} AND #{high}" : ''
      expressions = if schema_b
                      [
                        'toString(pk)', 'hex(label)',
                        "hex(toJSONString(tupleElement(pair, 'l')))" ,
                        "hex(toJSONString(tupleElement(pair, 'v')))" ,
                        "hex(toJSONString(arrayMap(x -> variantType(x), tupleElement(pair, 'v'))))",
                      ]
                    else
                      [
                        'toString(pk)', 'hex(s)', "if(isNull(n), 'NULL', toString(n))", 'hex(toJSONString(arr))',
                        'hex(tupleElement(pair, 1))', 'hex(tupleElement(pair, 2))', 'toString(tupleElement(pair, 3))',
                        'hex(toJSONString(arrayMap(x -> tupleElement(x, 1), seq)))',
                        "hex(toJSONString(arrayMap(x -> if(isNull(tupleElement(x, 2)), 'NULL', toString(tupleElement(x, 2))), seq)))",
                        'hex(toJSONString(mapKeys(lookup)))', 'hex(toJSONString(mapValues(lookup)))', 'hex(lc)',
                        'variantType(v)', "hex(ifNull(toJSONString(v), 'null'))",
                      ]
                    end
      "SELECT '#{marker}', '#{table}', #{expressions.join(', ')} FROM default.#{table}#{predicate} ORDER BY pk FORMAT TSVRaw;"
    end

    def initial_sql
      statements = ["SET allow_suspicious_low_cardinality_types=1;",
                    "SELECT '#{TAG[:pin]}', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;"]
      TABLES.each { |table| statements << create_sql(table) }
      TABLES.each { |table| statements << insert_sql(table) }
      TABLES.each { |table| statements << check_sql(table) }
      quoted = TABLES.map { |table| sql_string(table) }.join(', ')
      statements << "SELECT '#{TAG[:schema]}', table, name, type FROM system.columns WHERE database='default' AND table IN (#{quoted}) ORDER BY table, position FORMAT TSVRaw;"
      TABLES.each do |table|
        statements << row_query(table)
        statements << row_query(table, middle: true)
      end
      statements << "SELECT '#{TAG[:part]}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table IN (#{quoted}) AND active ORDER BY table, name FORMAT TSVRaw;"
      statements.join("\n") + "\n"
    end

    def parse_native(stdout)
      lines = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      fields = ->(tag) do
        lines.each_with_object([]) do |line, selected|
          selected << line.split("\t", -1) if line.start_with?("#{tag}\t")
        end
      end
      checks = {}
      active = nil
      lines.each do |line|
        if line.start_with?("#{TAG[:check_begin]}\t")
          entry = line.split("\t", -1)
          fail!('malformed or duplicate CHECK begin marker') unless entry.size == 2 && TABLES.include?(entry[1]) && !checks.key?(entry[1]) && active.nil?
          active = entry[1]
          checks[active] = []
        elsif line.start_with?("#{TAG[:check_end]}\t")
          entry = line.split("\t", -1)
          fail!('malformed or unpaired CHECK end marker') unless entry.size == 2 && active == entry[1]
          active = nil
        elsif active
          checks.fetch(active) << line
        end
      end
      fail!('unterminated native CHECK block') if active

      parts = {}
      fields.call(TAG[:part]).each do |entry|
        fail!('native part row has wrong arity') unless entry.size == 7
        table = entry.fetch(1)
        fail!("duplicate active part for #{table}") if parts.key?(table)
        parts[table] = {name: entry.fetch(2), path: entry.fetch(3), type: entry.fetch(4), rows: entry.fetch(5), marks: entry.fetch(6)}
      end
      schemas = fields.call(TAG[:schema]).map { |entry| entry.drop(1) }
      rows_a = Hash.new { |hash, key| hash[key] = [] }
      middle_a = Hash.new { |hash, key| hash[key] = [] }
      rows_b = Hash.new { |hash, key| hash[key] = [] }
      middle_b = Hash.new { |hash, key| hash[key] = [] }
      fields.call(TAG[:rows_a]).each { |entry| rows_a[entry.fetch(1)] << parse_row_a(entry) }
      fields.call(TAG[:middle_a]).each { |entry| middle_a[entry.fetch(1)] << parse_row_a(entry) }
      fields.call(TAG[:rows_b]).each { |entry| rows_b[entry.fetch(1)] << parse_row_b(entry) }
      fields.call(TAG[:middle_b]).each { |entry| middle_b[entry.fetch(1)] << parse_row_b(entry) }
      {checks: checks, parts: parts, schemas: schemas, rows_a: rows_a, middle_a: middle_a,
       rows_b: rows_b, middle_b: middle_b}
    rescue IndexError => error
      fail!("native TSV row was truncated: #{error.message}")
    end

    def uint64(value, label)
      fail!("native #{label} is not canonical UInt64 decimal") unless /\A(?:0|[1-9][0-9]*)\z/.match?(value)
      parsed = value.to_i
      fail!("native #{label} exceeds UInt64") if parsed > ((1 << 64) - 1)
      parsed
    end

    def decode_hex(value, label)
      fail!("native #{label} is not even-width hexadecimal") unless /\A(?:[0-9a-fA-F]{2})*\z/.match?(value)
      decoded = [value].pack('H*').force_encoding(Encoding::UTF_8)
      fail!("native #{label} is not valid UTF-8") unless decoded.valid_encoding?
      decoded
    end

    def parse_json_hex(value, label)
      JSON.parse(decode_hex(value, label))
    rescue JSON::ParserError => error
      fail!("native #{label} is malformed JSON: #{error.message}")
    end

    def parse_row_a(entry)
      fail!('schema-A native row has wrong arity') unless entry.size == 16
      seq_names = parse_json_hex(entry[9], 'Array(Tuple) names')
      seq_values = parse_json_hex(entry[10], 'Array(Tuple) values').map do |value|
        value == 'NULL' ? nil : uint64(value, 'Array(Tuple).value')
      end
      fail!('native Array(Tuple) fields differ in length') unless seq_names.size == seq_values.size
      lookup_keys = parse_json_hex(entry[11], 'Map keys')
      lookup_values = parse_json_hex(entry[12], 'Map values')
      fail!('native Map fields differ in length') unless lookup_keys.size == lookup_values.size
      tag = entry[14] == 'None' ? 'NULL' : entry[14]
      {
        pk: uint64(entry[2], 'pk'), s: decode_hex(entry[3], 'String'),
        n: entry[4] == 'NULL' ? nil : uint64(entry[4], 'Nullable(UInt64)'),
        arr: parse_json_hex(entry[5], 'Array(Nullable(UInt64))'),
        pair: [decode_hex(entry[6], 'Tuple.left'), decode_hex(entry[7], 'Tuple.right'), uint64(entry[8], 'Tuple.code')],
        seq: seq_names.zip(seq_values), lookup: lookup_keys.zip(lookup_values),
        lc: decode_hex(entry[13], 'LowCardinality(String)'), v_type: tag,
        v: parse_json_hex(entry[15], 'Variant JSON'),
      }
    end

    def parse_row_b(entry)
      fail!('schema-B native row has wrong arity') unless entry.size == 7
      variant_values = parse_json_hex(entry[5], 'nested Variant values')
      variant_types = parse_json_hex(entry[6], 'nested Variant arm types')
      fail!('nested Variant values/types differ in length') unless variant_values.size == variant_types.size
      {
        pk: uint64(entry[2], 'pk'), label: decode_hex(entry[3], 'schema-B label'),
        left: parse_json_hex(entry[4], 'nested LowCardinality values'),
        right: variant_types.zip(variant_values).map { |kind, value| [kind == 'None' ? 'NULL' : kind, value] },
      }
    end

    def assert_native_fixture!(native)
      fail!('native active part roster differs from the sealed 11-part matrix') unless native[:parts].keys.sort == TABLES.sort
      fail!('native CHECK roster differs from the sealed 11-part matrix') unless native[:checks].keys.sort == TABLES.sort
      TABLES.each do |table|
        fail!("#{table} stock CHECK is not exact CHECK=1") unless native[:checks][table] == ["#{PART_NAME}\t1\t"]
      end
      expected_schemas = TABLES.sort.flat_map do |table|
        schema_for(table).map { |name, type| [table, name, type] }
      end
      fail!('native system.columns schema/order differs from independent declarations') unless native[:schemas] == expected_schemas
      fail!('native schema-A full literal rows differ') unless
        TABLES.select { |table| table == WIDE_TABLE || table.start_with?('a_') }.all? { |table| native[:rows_a][table] == ROWS_A }
      fail!('native schema-A middle literal rows differ') unless
        TABLES.select { |table| table == WIDE_TABLE || table.start_with?('a_') }.all? { |table| native[:middle_a][table] == ROWS_A[2, 4] }
      fail!('native schema-B full literal rows differ') unless COMPACT_LABELS.select { |table| table.start_with?('b_') }.all? { |table| native[:rows_b][table] == ROWS_B }
      fail!('native schema-B middle literal rows differ') unless COMPACT_LABELS.select { |table| table.start_with?('b_') }.all? { |table| native[:middle_b][table] == ROWS_B[2, 4] }
      fail!('native schema-A query returned extra/missing tables') unless native[:rows_a].keys.sort == TABLES.select { |table| table == WIDE_TABLE || table.start_with?('a_') }.sort
      fail!('native schema-B query returned extra/missing tables') unless native[:rows_b].keys.sort == COMPACT_LABELS.select { |table| table.start_with?('b_') }.sort

      TABLES.each do |table|
        part = native[:parts].fetch(table)
        expected_type = table == WIDE_TABLE ? 'Wide' : 'Compact'
        fail!("#{table} part identity/type/grid differs") unless
          part[:name] == PART_NAME && part[:type] == expected_type && part[:rows] == '8' && part[:marks] == '5'
        validate_native_part_path!(part[:path])
      end
    end

    def file_snapshot(path)
      path = File.expand_path(path)
      files = []
      total = 0
      Find.find(path) do |entry|
        stat = File.lstat(entry)
        fail!("part contains symbolic link #{entry}") if stat.symlink?
        next if entry == path || stat.directory?
        fail!("part contains non-regular entry #{entry}") unless stat.file?
        size = stat.size
        total += size
        fail!('part exceeds bounded byte inventory') if total > MAX_PART_BYTES
        relative = entry.delete_prefix(path + File::SEPARATOR)
        files << {path: relative, bytes: size, sha256: sha(entry)}
        fail!('part exceeds bounded file inventory') if files.size > MAX_PART_FILES
      end
      files.sort_by { |file| file[:path] }
    end

    def inspect_part(table, path, part, expected_type)
      fail!("#{table} part directory is absent or linked") unless File.directory?(path) && !File.symlink?(path)
      files = file_snapshot(path)
      by_path = files.to_h { |file| [file[:path], file] }
      required = %w[columns.txt count.txt checksums.txt primary.idx serialization.json default_compression_codec.txt metadata_version.txt]
      mark_ext = if expected_type == 'Wide'
                   '.mrk2'
                 elsif table.include?('mrk3')
                   '.mrk3'
                 else
                   '.mrk4'
                 end
      required << "data#{mark_ext}" if expected_type == 'Compact'
      required << 'data.bin' if expected_type == 'Compact'
      required << 'columns_substreams.txt' if expected_type == 'Wide' || mark_ext == '.mrk4'
      required.each { |name| fail!("#{table} part lacks #{name}") unless by_path.key?(name) }
      if mark_ext == '.mrk3'
        fail!("#{table} mrk3 part unexpectedly has a substream roster") if by_path.key?('columns_substreams.txt')
      end
      mark_files = files.select { |file| file[:path].match?(/\.c?mrk\d*\z/) }
      fail!("#{table} has compressed or unexpected marks") unless mark_files.size.positive? && mark_files.all? { |file| file[:path].end_with?(mark_ext) }
      if expected_type == 'Compact'
        fail!("#{table} Compact roster has wrong data/mark files") unless
          files.select { |file| file[:path].end_with?('.bin') }.map { |file| file[:path] } == ['data.bin'] &&
          mark_files.map { |file| file[:path] } == ["data#{mark_ext}"]
      end
      count_text = File.binread(File.join(path, 'count.txt'))
      fail!("#{table} count.txt is not canonical eight rows") unless count_text == '8'
      fail!("#{table} native part type changed") unless part[:type] == expected_type
      codec = File.binread(File.join(path, 'default_compression_codec.txt'))
      fail!("#{table} default codec is not LZ4") unless codec.strip == 'CODEC(LZ4)'
      metadata = JSON.parse(File.binread(File.join(path, 'serialization.json')))
      fail!("#{table} with-types metadata version differs") unless metadata['version'] == 1
      fail!("#{table} nested version propagation differs") unless metadata['propagate_types_serialization_versions_to_nested_types'] == true
      string_profile = table == WIDE_TABLE || table.include?('_s1_') || table.start_with?('b_') ? 1 : 0
      observed_string = metadata.fetch('types_serialization_versions', {}).fetch('string', 0)
      fail!("#{table} String profile metadata differs from requested #{string_profile}") unless observed_string == string_profile
      {
        path: path, part_name: part[:name], part_type: part[:type], rows: part[:rows], native_marks: part[:marks],
        mark_extension: mark_ext, string_profile: observed_string, files: files,
        serialization_json: metadata, columns_text: File.binread(File.join(path, 'columns.txt')).force_encoding(Encoding::UTF_8),
        substreams_text: by_path.key?('columns_substreams.txt') ? File.binread(File.join(path, 'columns_substreams.txt')).force_encoding(Encoding::UTF_8) : nil,
      }
    rescue JSON::ParserError => error
      fail!("#{table} serialization.json is malformed: #{error.message}")
    end

    def validate_native_part_path!(path)
      fail!('native part path is absent') unless path && !path.empty?
      full = File.expand_path(path)
      fail!("native part path escaped isolated store: #{path}") unless full.start_with?(@store + File::SEPARATOR)
      full
    end

    def prepare_offline_catalog!(parts)
      FileUtils.mkdir_p(File.join(@catalog_root, 'metadata'), mode: 0o700)
      FileUtils.mkdir_p(File.join(@catalog_root, 'store'), mode: 0o700)
      db_uuid = uuid_for('database')
      db_store = File.join(@catalog_root, 'store', db_uuid[0, 3], db_uuid)
      FileUtils.mkdir_p(db_store, mode: 0o700)
      write_new(File.join(@catalog_root, 'metadata', 'default.sql'), "ATTACH DATABASE _ UUID '#{db_uuid}'\nENGINE = Atomic\n".b)

      table_paths = {}
      COMPACT_LABELS.each do |label|
        uuid = uuid_for("table:#{label}")
        path = File.join(@catalog_root, 'store', uuid[0, 3], uuid)
        FileUtils.mkdir_p(path, mode: 0o700)
        FileUtils.mkdir_p(File.join(path, 'detached'), mode: 0o700)
        write_new(File.join(path, 'format_version.txt'), "1\n".b)
        declarations = schema_for(label).map { |name, type| "    `#{name}` #{type}" }.join(",\n")
        ddl = "ATTACH TABLE _ UUID '#{uuid}'\n(\n#{declarations}\n)\nENGINE = MergeTree\nORDER BY pk\n"
        write_new(File.join(db_store, "#{label}.sql"), ddl.b)
        copied = File.join(path, PART_NAME)
        FileUtils.cp_r(parts.fetch(label).fetch(:path), copied, preserve: true)
        source_files_at_copy = file_snapshot(parts.fetch(label).fetch(:path))
        copied_files_at_copy = file_snapshot(copied)
        fail!("offline catalog copy differs for #{label}") unless copied_files_at_copy == source_files_at_copy
        table_paths[label] = {
          uuid: uuid, path: path, part_path: copied, part_files_at_copy: copied_files_at_copy,
        }
      end

      target_uuid = uuid_for('mv-target')
      target_path = File.join(@catalog_root, 'store', target_uuid[0, 3], target_uuid)
      FileUtils.mkdir_p(File.join(target_path, 'detached'), mode: 0o700)
      write_new(File.join(target_path, 'format_version.txt'), "1\n".b)
      write_new(File.join(db_store, 'w260_mv_target.sql'),
                "ATTACH TABLE _ UUID '#{target_uuid}'\n(\n    `id` UInt64,\n    `value` String\n)\nENGINE = MergeTree\nORDER BY id\nSETTINGS index_granularity = 2, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0\n".b)
      view_uuid = uuid_for('mv-view')
      view_ddl = "ATTACH MATERIALIZED VIEW _ UUID '#{view_uuid}' TO default.w260_mv_target\n" \
                 "(\n    `id` UInt64,\n    `value` String\n)\n" \
                 "AS SELECT pk AS id, s AS value FROM default.a_mrk3_s0_vbasic\n"
      write_new(File.join(db_store, 'w260_mv.sql'), view_ddl.b)
      {database_uuid: db_uuid, database_store: db_store, table_paths: table_paths,
       mv_source_table: 'a_mrk3_s0_vbasic', mv_target_path: target_path, mv_target_uuid: target_uuid,
       mv_view_uuid: view_uuid}
    end

    def uuid_for(label)
      suffix = Digest::SHA256.hexdigest("#{@root}:w260:#{label}")[0, 12]
      "26000000-0000-4000-8000-#{suffix}"
    end

    def write_new(path, bytes)
      fail!("refusing to overwrite capture file #{path}") if File.exist?(path) || File.symlink?(path)
      File.open(path, 'wbx', 0o600) { |file| file.write(bytes) }
    end

    def write_manifest!(catalog, parts)
      path = File.join(@root, 'parts', 'compact_typed_w260_manifest.json')
      manifest = {
        'format' => 'compact_typed_w260_manifest_v1',
        'catalog_root' => @catalog_root,
        'parts' => COMPACT_LABELS.map do |label|
          { 'label' => label, 'table' => label, 'path' => catalog.fetch(:table_paths).fetch(label).fetch(:part_path) }
        end,
        'mv_source' => { 'label' => 'a_mrk3_s0_vbasic', 'target_path' => catalog.fetch(:mv_target_path) },
      }
      write_new(path, JSON.pretty_generate(manifest) + "\n")
      fail!('manifest part paths differ from observed native part identities') unless
        JSON.parse(File.read(path)).fetch('parts').map { |entry| entry.fetch('label') }.sort == COMPACT_LABELS.sort
      path
    end

    def expected_signatures_a(rows = ROWS_A, selected_columns = SCHEMA_A.map(&:first))
      signatures = {
        's' => rows.map { |row| string_sig(row.fetch(:s)) },
        'n' => rows.map { |row| nullable_sig(row.fetch(:n)) },
        'arr' => rows.map { |row| "array[#{row.fetch(:arr).map { |value| nullable_sig(value) }.join(',')}]" },
        'pair' => rows.map { |row| tuple_a_sig(row) },
        'seq' => rows.map { |row| "array[#{row.fetch(:seq).map { |label, value| "tuple[label=#{string_sig(label)},value=#{nullable_sig(value)}]" }.join(',')}]" },
        'lookup' => rows.map { |row| map_sig(row.fetch(:lookup)) },
        'lc' => rows.map { |row| string_sig(row.fetch(:lc)) },
        'v' => rows.map { |row| variant_sig(row.fetch(:v_type), row.fetch(:v)) },
      }
      signatures.select { |column, _values| selected_columns.include?(column) }
    end

    def expected_signatures_b(rows = ROWS_B)
      {
        'label' => rows.map { |row| string_sig(row.fetch(:label)) },
        'pair' => rows.map do |row|
          left = row.fetch(:left).map { |value| "lowcard(uint64:#{value})" }.join(',')
          right = row.fetch(:right).map { |kind, value| nested_variant_sig(kind, value) }.join(',')
          "tuple[l=array[#{left}],v=array[#{right}]]"
        end,
      }
    end

    def string_sig(value)
      "string:#{value.b.unpack1('H*')}"
    end

    def nullable_sig(value)
      value.nil? ? 'null' : "uint64:#{value}"
    end

    def tuple_a_sig(row)
      left, right, code = row.fetch(:pair)
      "tuple[left=#{string_sig(left)},right=#{string_sig(right)},code=uint64:#{code}]"
    end

    def map_sig(entries)
      parts = entries.map { |key, values| "#{key.b.unpack1('H*')}:[#{values.map { |value| nullable_sig(value) }.join(',')}]" }
      "map[#{parts.join(',')}]"
    end

    def variant_sig(kind, value)
      case kind
      when 'String' then "variant<String>(#{string_sig(value)})"
      when 'UInt64' then "variant<UInt64>(uint64:#{value})"
      when 'NULL' then 'variant<NULL>(null)'
      else fail!("unknown native Variant arm #{kind.inspect}")
      end
    end

    def nested_variant_sig(kind, value)
      case kind
      when 'String' then "variant<String>(#{string_sig(value)})"
      when 'UInt64' then "variant<UInt64>(uint64:#{value})"
      when 'NULL' then 'variant<NULL>(null)'
      else fail!("unknown nested Variant arm #{kind.inspect}")
      end
    end

    def expected_catalog_values(rows, signatures)
      {'pk' => rows.map { |row| "uint64:#{row.fetch(:pk)}" }}.merge(signatures)
    end

    def expected_keys(rows)
      rows.map { |row| row.fetch(:pk) }
    end

    def verify_scan!(scan, rows, signatures, label)
      keys = expected_keys(rows)
      fail!("#{label} keys differ from independent literal rows") unless scan.fetch('keys') == keys
      fail!("#{label} typed value signatures differ from independent literal rows") unless scan.fetch('columns') == signatures
      fail!("#{label} typed value column set differs") unless scan.fetch('columns').keys.sort == signatures.keys.sort
    end

    def verify_table_report!(report, label, rows, signatures, selected_columns)
      fail!("#{label} selected schema differs") unless report.fetch('columns') == selected_columns
      expected_types = schema_for(label == WIDE_TABLE ? 'a_mrk4_s1_vbasic' : label).select { |name, _type| selected_columns.include?(name) }
      fail!("#{label} selected nominal type roster differs") unless report.fetch('column_types') == expected_types
      sources = report.fetch('column_sources')
      fail!("#{label} source roster is malformed") unless sources.size == expected_types.size && sources.each_with_index.all? do |entry, i|
        entry[0] == expected_types[i][0] && entry[1] == expected_types[i][0] && entry[2] == expected_types[i][1]
      end
      fail!("#{label} part mark grid differs") unless report.fetch('part_mark_row_counts') == [MARK_ROWS]
      fail!("#{label} total row count differs") unless report.fetch('total_row_count') == 8

      keys = expected_keys(rows)
      verify_scan!(report.fetch('full'), rows, signatures, "#{label} full")
      verify_scan!(report.fetch('first'), rows[0, 2], slice_signatures(signatures, 0, 2), "#{label} first")
      verify_scan!(report.fetch('middle'), rows[2, 4], slice_signatures(signatures, 2, 4), "#{label} middle")
      verify_scan!(report.fetch('last'), rows[6, 2], slice_signatures(signatures, 6, 2), "#{label} last")
      verify_scan!(report.fetch('eof'), [], signatures.transform_values { [] }, "#{label} EOF")
      candidates = rows[0, 2] + rows[4, 2]
      verify_scan!(report.fetch('candidates'), candidates, slice_and_concat_signatures(signatures), "#{label} candidate marks")
      one = report.fetch('one_row_batches')
      verify_scan!(one, rows, signatures, "#{label} batch_rows=1")
      fail!("#{label} batch_rows=1 callback sizes differ") unless one.fetch('callback_rows') == Array.new(8, 1)
      expected_offsets = (0..7).map { |row| [row / 2, row, 1] }
      fail!("#{label} batch_rows=1 mark/source offsets differ") unless one.fetch('offsets') == expected_offsets
      expected_scan_shapes = {
        'full' => [Array.new(4, 2), [[0, 0, 2], [1, 2, 2], [2, 4, 2], [3, 6, 2]]],
        'first' => [[2], [[0, 0, 2]]],
        'middle' => [[2, 2], [[1, 2, 2], [2, 4, 2]]],
        'last' => [[2], [[3, 6, 2]]],
        'eof' => [[], []],
        'candidates' => [[2, 2], [[0, 0, 2], [2, 4, 2]]],
      }
      expected_scan_shapes.each do |scan_name, (callback_rows, offsets)|
        scan = report.fetch(scan_name)
        fail!("#{label} #{scan_name} callback bounds differ") unless scan.fetch('callback_rows') == callback_rows
        fail!("#{label} #{scan_name} mark/source offsets differ") unless scan.fetch('offsets') == offsets
      end
      fail!("#{label} EOF window contains rows") unless report.fetch('eof').fetch('keys').empty?
      nil
    end

    def verify_mixed_facade_report!(report)
      expected_scans = %w[full window candidates]
      fail!('mixed typed facade report fields differ') unless report.keys.sort == (expected_scans + ['schedule_mutated']).sort
      expected_scan_fields = %w[keys offsets strings]
      expected_full_keys = expected_keys(ROWS_A) * 2
      expected_full_strings = ROWS_A.map { |row| row.fetch(:s) } * 2
      expected_full_offsets = (0..1).flat_map do |part|
        (0..7).map { |row| [part, row / 2, row, part * 8 + row, 1] }
      end

      expected_window = {
        'keys' => [7107, 7108, 7101, 7102],
        'strings' => %w[root-6 root-7 root-0 root-1],
        'offsets' => [[0, 3, 6, 6, 2], [1, 0, 0, 8, 2]],
      }
      expected_candidates = {
        'keys' => [7103, 7104, 7107, 7108, 7101, 7102, 7105, 7106],
        'strings' => %w[root-2 root-3 root-6 root-7 root-0 root-1 root-4 root-5],
        'offsets' => [[0, 1, 2, 2, 2], [0, 3, 6, 6, 2], [1, 0, 0, 8, 2], [1, 2, 4, 12, 2]],
      }

      full = report.fetch('full')
      fail!('mixed full scan fields differ') unless full.keys.sort == expected_scan_fields
      fail!('mixed full scan literal keys, strings, or coordinates differ') unless
        full.fetch('keys') == expected_full_keys &&
        full.fetch('strings') == expected_full_strings &&
        full.fetch('offsets') == expected_full_offsets

      window = report.fetch('window')
      fail!('mixed window fields differ') unless window.keys.sort == expected_scan_fields
      fail!('mixed window literal keys, strings, or coordinates differ') unless window == expected_window

      candidates = report.fetch('candidates')
      fail!('mixed candidate fields differ') unless candidates.keys.sort == expected_scan_fields
      fail!('mixed candidate literal keys, strings, or coordinates differ') unless candidates == expected_candidates
      fail!('mixed candidate schedule was not mutated after snapshot') unless report.fetch('schedule_mutated') == true
      nil
    end

    def verify_compact_physical_report!(data)
      physical = data.fetch('compact_physical')
      fail!('Compact physical helper roster differs') unless physical.keys.sort == COMPACT_LABELS.sort
      COMPACT_LABELS.each do |label|
        schema = label.start_with?('b_') ? SCHEMA_B : SCHEMA_A
        entries = physical.fetch(label)
        fail!("#{label} physical column roster differs") unless entries.map { |entry| entry.fetch('column') } == schema.map(&:first)
        fail!("#{label} physical report entry fields differ") unless entries.all? do |entry|
          entry.keys.sort == %w[column logical_bytes shard_bytes] &&
            entry.fetch('logical_bytes').is_a?(Integer) && entry.fetch('logical_bytes') >= 0 &&
            entry.fetch('shard_bytes').is_a?(Integer) && entry.fetch('shard_bytes') >= 0 &&
            entry.fetch('logical_bytes') == entry.fetch('shard_bytes')
        end
        logical_total = entries.sum { |entry| entry.fetch('logical_bytes') }
        shard_total = entries.sum { |entry| entry.fetch('shard_bytes') }
        fail!("#{label} per-column logical and owned shard byte sums differ") unless logical_total == shard_total
      end

      two_column = data.fetch('physical_two_column')
      fail!('two-column physical roster differs') unless two_column.fetch('columns') == %w[alpha beta]
      fail!('two-column physical logical/shard byte sums differ') unless
        two_column.fetch('logical_bytes').is_a?(Integer) && two_column.fetch('shard_bytes').is_a?(Integer) &&
        two_column.fetch('logical_bytes') == two_column.fetch('shard_bytes')
      nil
    end

    def slice_signatures(signatures, start, count)
      signatures.transform_values { |values| values[start, count] }
    end

    def slice_and_concat_signatures(signatures)
      signatures.transform_values { |values| values[0, 2] + values[4, 2] }
    end

    def assert_helper!(data, mv_target_path)
      fail!('helper protocol/version differs') unless data.fetch('format') == HELPER_FORMAT
      wide = data.fetch('wide_control')
      verify_table_report!(wide, WIDE_TABLE, ROWS_A,
                           expected_signatures_a(ROWS_A, SELECTED_WIDE), SELECTED_WIDE)
      compact = data.fetch('compact')
      fail!('helper Compact report roster differs') unless compact.keys.sort == COMPACT_LABELS.sort
      COMPACT_LABELS.each do |label|
        schema_b = label.start_with?('b_')
        rows = schema_b ? ROWS_B : ROWS_A
        signatures = schema_b ? expected_signatures_b : expected_signatures_a
        selected = (schema_b ? SCHEMA_B : SCHEMA_A).map(&:first)
        entry = compact.fetch(label)
        %w[direct typed_facade].each do |surface|
          report = entry.fetch(surface)
          verify_table_report!(report, label, rows, signatures, selected)
        end
        direct = entry.fetch('direct')
        facade = entry.fetch('typed_facade')
        fail!("#{label} direct/facade full results differ") unless direct.fetch('full') == facade.fetch('full')
        catalog = entry.fetch('catalog')
        fail!("#{label} catalog .values differs from independent literals") unless
          catalog.fetch('values') == expected_catalog_values(rows, signatures)
        fail!("#{label} catalog PK candidate report fields differ") unless
          catalog.keys.sort == %w[candidate_callback_rows candidate_filtered_keys candidate_keys candidate_mark_indices values]
        candidate_keys = rows[0, 6].map { |row| row.fetch(:pk) }
        fail!("#{label} conservative public UInt64 PK candidates differ") unless catalog.fetch('candidate_keys') == candidate_keys
        fail!("#{label} public UInt64 PK candidate mark schedule differs") unless catalog.fetch('candidate_mark_indices') == [0, 1, 2]
        fail!("#{label} public UInt64 PK candidate callback bounds differ") unless catalog.fetch('candidate_callback_rows') == [2, 2, 2]
        exact_candidate_keys = rows[2, 4].map { |row| row.fetch(:pk) }
        fail!("#{label} caller-side exact PK predicate differs") unless catalog.fetch('candidate_filtered_keys') == exact_candidate_keys
      end
      verify_compact_physical_report!(data)
      verify_mixed_facade_report!(data.fetch('mixed_typed_facade'))
      mv = data.fetch('compact_mv_source')
      fail!('Compact MV source report fields differ') unless
        mv.keys.sort == %w[callback_count keys offsets output_path row_count source_table values]
      expected_offsets = (0..7).map { |row| [row / 2, row, 1] }
      fail!('Compact MV source table differs') unless mv.fetch('source_table') == 'a_mrk3_s0_vbasic'
      fail!('Compact MV source did not preserve exact caller-visible literals') unless
        mv.fetch('callback_count') == 1 && mv.fetch('row_count') == 8 &&
        mv.fetch('keys') == expected_keys(ROWS_A) && mv.fetch('values') == ROWS_A.map { |row| row.fetch(:s) } &&
        mv.fetch('offsets') == expected_offsets
      output_path = File.expand_path(mv.fetch('output_path'))
      expected_output_path = File.join(mv_target_path, 'detached', 'all_9_9_0')
      fail!('Compact MV output path differs from the selected target destination') unless output_path == File.expand_path(expected_output_path)
      fail!('Compact MV output part is absent') unless File.directory?(output_path) && !File.symlink?(output_path)
      nil
    end

    def write_summary(data)
      summary = {
        probe: FORMAT, status: data[:status], fatal_error: data[:fatal_error], stage: @stage,
        claim_boundary: 'one pinned ClickHouse runtime, native Wide nine-column CHECK/schema/literals, typed Wide seven-column inherited-supported control, eight Compact schema-A nine-column cells and two Compact schema-B three-column cells; public typed/direct/catalog/MV values are checked; not a claim for all Compact layouts or types',
        source_snapshot: SOURCE_SNAPSHOT,
        source_runtime_relation: 'the source snapshot and runtime executable are separately pinned; no source/runtime identity is asserted',
        runtime: {path: @binary, expected_sha256: BINARY_SHA256, sha256_before: @runtime_sha_before,
                  sha256_after: @runtime_sha_after, expected_version: VERSION, expected_build: BUILD},
        helper: {path: @helper, protocol: HELPER_FORMAT, invocation: 'roundtrip WIDE_PART MANIFEST.json',
                 sha256_before: @helper_sha_before, sha256_after: @helper_sha_after,
                 source_files_before: @source_sha_before, source_files_after: @source_sha_after},
        matrix: {tables: TABLES, compact_labels: COMPACT_LABELS, part_name: PART_NAME,
                 schema_a: SCHEMA_A, schema_b: SCHEMA_B, typed_wide_columns: SELECTED_WIDE,
                 rows_a: ROWS_A, rows_b: ROWS_B,
                 real_mark_rows: MARK_ROWS, terminal_row_count: 0,
                 axes: ['mrk3/mrk4', 'String v0/v1', 'Variant BASIC/COMPACT', 'independent recursive schema B']},
        limits: {max_threads: 1, max_memory_usage_bytes_per_native_process: W185::MEMORY,
                 process_timeout_seconds: W180::PROCESS_TIMEOUT_SECONDS,
                 termination_grace_seconds: W180::TERMINATION_GRACE_SECONDS,
                 max_capture_bytes_per_stream: MAX_CAPTURE_BYTES, part_max_files: MAX_PART_FILES, part_max_bytes: MAX_PART_BYTES},
        evidence_root: @root, native: data[:native], parts: data[:parts], catalog: data[:catalog],
        helper_result: data[:helper], invocations: @invocations,
      }
      @capture.send(:write_new, File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
    end
  end
end

def main
  options = {binary: ProbeCompactTypedW260::BINARY}
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/probe_compact_typed_w260.rb --helper PREBUILT_HELPER --root EMPTY_DIRECT_CHILD_OF_PRIVATE_TMP [--clickhouse PINNED_EXECUTABLE]'
    parser.on('--clickhouse PATH') { |value| options[:binary] = value }
    parser.on('--helper PATH') { |value| options[:helper] = value }
    parser.on('--root PATH') { |value| options[:evidence_root] = value }
  end.parse!
  raise 'prebuilt helper is required via --helper' unless options[:helper]
  exit(ProbeCompactTypedW260::Probe.new(**options).run ? 0 : 1)
rescue StandardError => error
  warn "W260 probe runner error: #{error.class}: #{error.message}"
  exit 1
end

main if $PROGRAM_NAME == __FILE__
