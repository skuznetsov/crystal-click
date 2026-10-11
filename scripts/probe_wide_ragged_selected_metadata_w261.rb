#!/usr/bin/env ruby
# Bounded stock-native capture for W261's ten-column ragged Wide fixture.
# The runner consumes supplied executables and never builds either one.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require_relative 'stock_part_probe_support_w191'

module ProbeWideRaggedSelectedMetadataW261
  FORMAT = 'wide_ragged_selected_metadata_w261_stock_capture_v1'.freeze
  HELPER_FORMAT = 'wide_ragged_selected_metadata_w261_checker_v1'.freeze
  HELPER_SOURCE = File.expand_path('check_wide_ragged_selected_metadata_w261.cr', __dir__).freeze
  FIXTURE_SOURCE = File.expand_path('support/wide_ragged_selected_metadata_w261_fixture.cr', __dir__).freeze
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
  KEY_HASH = 'fcc8daf1be9ac27649fa2186ad926aea'.freeze
  TABLE = 'source'.freeze
  MARK_ROWS = [2, 2, 2, 2].freeze
  MARK_ROWS_WITH_EOF = [2, 2, 2, 2, 0].freeze
  MAX_CAPTURE_BYTES = 8 * 1024 * 1024
  MAX_PART_FILES = 4096
  MAX_PART_BYTES = 64 * 1024 * 1024

  SCHEMA = [
    ['pk', 'UInt64'], ['u', 'UInt64'], ['side', 'String'],
    ['seq', 'Array(Tuple(id UInt64, details Tuple(note Nullable(String), score UInt32)))'],
    ['mapped', 'Map(String, Tuple(meta Tuple(note Nullable(String), id UInt64), score Nullable(Float64)))'],
    ['simple', 'Map(UInt64, Nullable(UInt64))'],
    ['lookup', 'Map(String, Array(Nullable(UInt64)))'],
    ['tup', 'Tuple(n UInt64, s String)'],
    ['lc', 'LowCardinality(String)'], ['v', 'Variant(String, UInt64)'],
  ].map(&:freeze).freeze
  SELECTED_COLUMNS = %w[u side seq mapped simple lookup tup lc v].freeze

  SETTINGS = [
    'index_granularity=2', 'index_granularity_bytes=10485760',
    'enable_mixed_granularity_parts=1', 'min_rows_for_wide_part=0',
    'min_bytes_for_wide_part=0', 'compress_marks=0', 'compress_primary_key=0',
    'min_compress_block_size=0', 'max_compress_block_size=4096',
    'ratio_of_defaults_for_sparse_serialization=1', "default_compression_codec='LZ4'",
    "serialization_info_version='with_types'", 'propagate_types_serialization_versions_to_nested_types=1',
    "string_serialization_version='with_size_stream'", "map_serialization_version='basic'",
    "map_serialization_version_for_zero_level_parts='basic'", 'use_compact_variant_discriminators_serialization=0',
  ].join(', ').freeze
  JSON_SETTINGS = {
    'output_format_json_map_as_array_of_tuples' => 'true',
    'output_format_json_named_tuples_as_objects' => 'true',
    'output_format_json_skip_null_value_in_named_tuples' => 'false',
    'output_format_json_quote_64bit_integers' => 'false',
  }.freeze

  # Independent Ruby literal oracle. Map columns are ordered entry arrays,
  # never Ruby Hashes, so duplicate keys survive capture and comparison.
  ROWS = [
    {pk: 8101, u: 9101, side: 'side-0', seq: [], mapped: [], simple: [[1, nil]], lookup: [], tup: [3101, 'tuple-0'], lc: 'dup', v_type: 'String', v: 'variant-0'},
    {pk: 8102, u: 9102, side: 'side-1', seq: [], mapped: [], simple: [], lookup: [['one', [nil, 9202]]], tup: [3102, 'tuple-1'], lc: 'red', v_type: 'UInt64', v: 4202},
    {pk: 8103, u: 9103, side: "mark-1\0mid", seq: [[1201, {note: "a\0b", score: 21}], [1202, {note: nil, score: 22}]], mapped: [['dup', {meta: {note: nil, id: 2201}, score: 1.5}], ['dup', {meta: {note: "m\0", id: 2202}, score: nil}], ['雪', {meta: {note: 'café', id: 2203}, score: -2.25}]], simple: [], lookup: [], tup: [3103, "tuple-2\0λ"], lc: 'dup', v_type: 'NULL', v: nil},
    {pk: 8104, u: 9104, side: 'π-snow-雪', seq: [], mapped: [], simple: [[3, 3003], [3, 3004]], lookup: [['empty', []], ['dup', [nil, 9401]]], tup: [3104, '雪-tuple-3'], lc: '', v_type: 'String', v: "v\0three"},
    {pk: 8105, u: 9105, side: 'side-4', seq: [], mapped: [], simple: [], lookup: [], tup: [3105, 'tuple-4'], lc: 'blue', v_type: 'UInt64', v: 4205},
    {pk: 8106, u: 9106, side: "nul\0and-尾", seq: [], mapped: [], simple: [[5, 5005]], lookup: [], tup: [3106, "nul\0five"], lc: 'dup', v_type: 'String', v: '尾'},
    {pk: 8107, u: 9107, side: 'side-6', seq: [[1601, {note: 'π', score: 61}]], mapped: [['tail', {meta: {note: '尾', id: 2601}, score: 0.5}]], simple: [], lookup: [['π', [9606, nil]]], tup: [3107, 'tuple-6'], lc: 'blue', v_type: 'UInt64', v: 4207},
    {pk: 8108, u: 9108, side: 'tail-✓', seq: [[1701, {note: 'tail-雪', score: 71}], [1702, {note: 'last', score: 72}]], mapped: [['end', {meta: {note: '!', id: 2701}, score: nil}], ['end', {meta: {note: nil, id: 2702}, score: 8.0}]], simple: [[7, nil]], lookup: [['tail', [9707]]], tup: [3108, 'tail-α'], lc: 'tail', v_type: 'NULL', v: nil},
  ].map(&:freeze).freeze

  TAG = {
    pin: '__W261_PIN__', settings: '__W261_JSON_SETTINGS__', check_begin: '__W261_CHECK_BEGIN__',
    check_end: '__W261_CHECK_END__', schema: '__W261_SCHEMA__', path: '__W261_DATA_PATH__',
    engine: '__W261_ENGINE__', part: '__W261_PART__', full: '__W261_JSON_FULL__', middle: '__W261_JSON_MIDDLE__',
  }.freeze

  class Failure < StandardError; end

  class Probe
    def initialize(binary:, helper:, evidence_root:, mode:)
      @binary = validate_executable(binary, 'ClickHouse')
      @helper = validate_executable(helper, 'prebuilt Crystal checker')
      @mode = mode
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

      @stage = 'stock native capture'
      native = run_native('stock_source', initial_sql)
      assert_pin!(native)
      assert_native_success!(native)
      result = parse_native(native[:stdout])
      assert_native_fixture!(result)
      part_path = validate_native_part_path!(result.fetch(:part).fetch(:path))
      inventory = inspect_part(part_path, result.fetch(:part))

      @stage = 'baseline typed admission capture'
      helper_work_parent = File.join(@root, 'helper-work')
      Dir.mkdir(helper_work_parent, 0o700)
      helper_work = File.join(helper_work_parent, 'checker-work')
      helper = run_helper(part_path, helper_work)
      assert_helper_baseline!(helper.fetch(:data)) if @mode == 'baseline'
      assert_helper_green!(helper.fetch(:data)) if @mode == 'green'

      @stage = 'stable evidence and summary'
      @runtime_sha_after = binary_sha
      @helper_sha_after = sha(@helper)
      @source_sha_after = source_hashes
      fail!('pinned ClickHouse executable changed during probe') unless @runtime_sha_after == BINARY_SHA256
      fail!('prebuilt Crystal checker changed during probe') unless @helper_sha_after == @helper_sha_before
      fail!('probe source or fixture changed during probe') unless @source_sha_after == @source_sha_before
      fail!('stock part changed while helper inspected it') unless inspect_part(part_path, result.fetch(:part))[:files] == inventory[:files]

      File.write(File.join(@root, 'stock-part.path'), part_path + "\n", mode: 'wbx', perm: 0o600)
      write_summary(status: @mode == 'baseline' ? 'stock_capture_with_baseline_admission' : 'stock_capture_with_green_assertions',
                    native: result, part_inventory: inventory, helper: helper.fetch(:data),
                    native_invocation: native[:record], helper_invocation: helper[:record])
      puts "W261 mode=#{@mode}; runtime=#{VERSION}/#{BUILD}; schema_columns=#{SCHEMA.size}; rows=#{ROWS.size}; marks=#{MARK_ROWS_WITH_EOF.inspect}; helper_status=#{helper.fetch(:data).fetch('status')}; stock_part=#{part_path}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @runtime_sha_after = binary_sha rescue nil
      @helper_sha_after = sha(@helper) rescue nil
      @source_sha_after = source_hashes rescue nil
      write_summary(status: 'runner_failure_or_observations_differ', fatal_error: @fatal_error) rescue nil
      warn "W261 #{@stage} failed: #{@fatal_error}"
      false
    end

    private

    def fail!(message)
      raise Failure, "W261 selected-metadata Wide stock capture: #{message}"
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
      sql_path = File.join(@root, 'invocations', "#{label}.stdin.sql")
      @capture.send(:write_new, sql_path, sql.b)
      argv = [@binary, 'local', '--path', @store, '--session_timezone=UTC', '--max_threads=1',
              "--max_memory_usage=#{W185::MEMORY}", '--output_format_json_quote_64bit_integers=0', '--multiquery']
      before_sha = binary_sha
      fail!('pinned ClickHouse executable SHA-256 mismatch before invocation') unless before_sha == BINARY_SHA256
      invocation = @capture.send(:execute_record, label, argv, sql.b, 'clickhouse local', BINARY_SHA256, @binary)
      invocation[:record][:binary_sha_before] = before_sha
      invocation[:record][:binary_sha_after] = binary_sha
      fail!('pinned ClickHouse executable changed during invocation') unless invocation[:record][:binary_sha_after] == BINARY_SHA256
      @invocations << invocation[:record]
      fail!("#{label} stdout capture exceeds #{MAX_CAPTURE_BYTES} bytes") if invocation[:stdout].bytesize > MAX_CAPTURE_BYTES
      fail!("#{label} stderr capture exceeds #{MAX_CAPTURE_BYTES} bytes") if invocation[:stderr].bytesize > MAX_CAPTURE_BYTES
      invocation
    end

    def run_helper(part_path, work_root)
      argv = [@helper, @mode, part_path, work_root]
      before_sha = sha(@helper)
      invocation = @capture.send(:execute_record, 'typed_admission', argv, ''.b,
                                 'prebuilt Crystal checker', nil, nil)
      after_sha = sha(@helper)
      invocation[:record][:helper_sha_before] = before_sha
      invocation[:record][:helper_sha_after] = after_sha
      @invocations << invocation[:record]
      fail!('prebuilt helper changed during invocation') unless before_sha == after_sha
      fail!("helper stdout capture exceeds #{MAX_CAPTURE_BYTES} bytes") if invocation[:stdout].bytesize > MAX_CAPTURE_BYTES
      fail!("helper stderr capture exceeds #{MAX_CAPTURE_BYTES} bytes") if invocation[:stderr].bytesize > MAX_CAPTURE_BYTES
      unless invocation[:classification] == 'success' && invocation[:status]&.success? && invocation[:status]&.termsig.nil?
        fail!('checker process failed; its error is not a storage-format rejection')
      end
      fail!('checker wrote stderr') unless invocation[:stderr].empty?
      lines = invocation[:stdout].force_encoding(Encoding::UTF_8).lines.map(&:chomp).reject(&:empty?)
      fail!('checker must emit exactly one JSON record') unless lines.size == 1
      {data: JSON.parse(lines.fetch(0)), record: invocation[:record]}
    rescue JSON::ParserError => error
      fail!("checker output is not valid JSON: #{error.message}")
    end

    def assert_helper_baseline!(data)
      fail!('checker format/version differs') unless data['format'] == HELPER_FORMAT
      fail!('ordinary pk/u/side controls were not independently GREEN') unless data['ordinary_controls'] == 'green'
      fail!('baseline checker omitted direct selected attempts') unless data['direct_selected_attempts'].is_a?(Array) && data['direct_selected_attempts'].size == SELECTED_COLUMNS.size
      fail!('baseline checker omitted selected table attempts') unless data['selected_table_attempts'].is_a?(Array) && data['selected_table_attempts'].size == 2
      fail!('baseline result hid typed admission statuses') unless %w[baseline_red_captured baseline_typed_green].include?(data['status'])
      data['direct_selected_attempts'].each_with_index do |attempt, index|
        fail!('direct attempt roster/order differs') unless attempt['name'] == SELECTED_COLUMNS[index]
        fail!('direct attempt has an unknown status') unless %w[green rejected value_mismatch metadata_mismatch].include?(attempt['status'])
      end
      fail!('selected table attempt roster/order differs') unless data['selected_table_attempts'].map { |attempt| attempt['name'] } == %w[WidePartTable TypedPartTable]
      data['selected_table_attempts'].each do |attempt|
        fail!('selected table attempt has an unknown status') unless %w[green rejected value_mismatch metadata_mismatch].include?(attempt['status'])
      end
    end

    def assert_helper_green!(data)
      # The checker owns comprehensive independent literal, window, EOF,
      # cardinality, type, and OfflineTable budget assertions in GREEN mode.
      fail!('checker format/version differs') unless data['format'] == HELPER_FORMAT
      fail!('GREEN checker did not report the all-assertions status') unless data['status'] == 'green_all_assertions'
      fail!('GREEN checker did not name its complete assertion set') unless data['assertions'] == %w[direct full window eof selected_table offline_values exact_types exact_budgets]
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
        fail!('ClickHouse reported an exception or system error despite successful process classification')
      end
      fail!('ClickHouse wrote unclassified stderr') unless invocation[:stderr].empty?
    end

    def sql_string(value)
      escaped = value.to_s.gsub('\\') { '\\\\' }.gsub("\0") { '\\0' }.gsub("'") { "\\'" }
      "'#{escaped}'"
    end

    def nullable_string(value)
      value.nil? ? "CAST(NULL, 'Nullable(String)')" : "CAST(#{sql_string(value)}, 'Nullable(String)')"
    end

    def nullable_uint64(value)
      value.nil? ? "CAST(NULL, 'Nullable(UInt64)')" : "CAST(toUInt64(#{value}), 'Nullable(UInt64)')"
    end

    def nullable_float64(value)
      value.nil? ? "CAST(NULL, 'Nullable(Float64)')" : "CAST(toFloat64(#{value}), 'Nullable(Float64)')"
    end

    def seq_sql(entries)
      items = entries.map do |id, details|
        "tuple(toUInt64(#{id}), tuple(#{nullable_string(details.fetch(:note))}, toUInt32(#{details.fetch(:score)})))"
      end.join(', ')
      "CAST([#{items}], #{sql_string(SCHEMA.fetch(3).fetch(1))})"
    end

    def mapped_sql(entries)
      items = entries.map do |key, value|
        meta = value.fetch(:meta)
        "tuple(#{sql_string(key)}, tuple(tuple(#{nullable_string(meta.fetch(:note))}, toUInt64(#{meta.fetch(:id)})), #{nullable_float64(value.fetch(:score))}))"
      end.join(', ')
      "CAST([#{items}], #{sql_string(SCHEMA.fetch(4).fetch(1))})"
    end

    def simple_sql(entries)
      items = entries.map { |key, value| "tuple(toUInt64(#{key}), #{nullable_uint64(value)})" }.join(', ')
      "CAST([#{items}], #{sql_string(SCHEMA.fetch(5).fetch(1))})"
    end

    def lookup_sql(entries)
      items = entries.map do |key, values|
        array = values.map { |value| value.nil? ? "CAST(NULL, 'Nullable(UInt64)')" : "toUInt64(#{value})" }.join(', ')
        "tuple(#{sql_string(key)}, CAST([#{array}], 'Array(Nullable(UInt64))'))"
      end.join(', ')
      "CAST([#{items}], #{sql_string(SCHEMA.fetch(6).fetch(1))})"
    end

    def row_values(row)
      variant = case row.fetch(:v_type)
                when 'String' then sql_string(row.fetch(:v))
                when 'UInt64' then "toUInt64(#{row.fetch(:v)})"
                when 'NULL' then "CAST(NULL, 'Variant(String, UInt64)')"
                else fail!("unknown Variant oracle type #{row.fetch(:v_type).inspect}")
                end
      ["toUInt64(#{row.fetch(:pk)})", "toUInt64(#{row.fetch(:u)})", sql_string(row.fetch(:side)),
       seq_sql(row.fetch(:seq)), mapped_sql(row.fetch(:mapped)), simple_sql(row.fetch(:simple)), lookup_sql(row.fetch(:lookup)),
       "CAST(tuple(toUInt64(#{row.fetch(:tup).fetch(0)}), #{sql_string(row.fetch(:tup).fetch(1))}), #{sql_string(SCHEMA.fetch(7).fetch(1))})",
       "CAST(#{sql_string(row.fetch(:lc))}, #{sql_string(SCHEMA.fetch(8).fetch(1))})",
       "CAST(#{variant}, #{sql_string(SCHEMA.fetch(9).fetch(1))})"]
    end

    def create_sql
      declarations = SCHEMA.map { |name, type| "`#{name}` #{type}" }.join(', ')
      "CREATE TABLE default.#{TABLE} (#{declarations}) ENGINE=MergeTree ORDER BY pk SETTINGS #{SETTINGS};"
    end

    def insert_sql
      values = ROWS.map { |row| "(#{row_values(row).join(', ')})" }.join(",\n")
      "INSERT INTO default.#{TABLE} VALUES\n#{values};"
    end

    def check_sql
      ["SELECT '#{TAG[:check_begin]}', '#{TABLE}' FORMAT TSVRaw;",
       "CHECK TABLE default.#{TABLE} FORMAT TSV;",
       "SELECT '#{TAG[:check_end]}', '#{TABLE}' FORMAT TSVRaw;"].join("\n")
    end

    def json_row_sql(middle: false)
      marker = middle ? TAG[:middle] : TAG[:full]
      predicate = middle ? ' WHERE src.pk BETWEEN 8103 AND 8106' : ''
      "SELECT '#{marker}' AS __w261_tag, toString(src.pk) AS pk, toString(src.u) AS u, hex(src.side) AS side_hex, " \
        "toJSONString(src.seq) AS seq_json, toJSONString(mapKeys(src.mapped)) AS mapped_keys_json, toJSONString(mapValues(src.mapped)) AS mapped_values_json, " \
        "toJSONString(mapKeys(src.simple)) AS simple_keys_json, toJSONString(mapValues(src.simple)) AS simple_values_json, " \
        "toJSONString(mapKeys(src.lookup)) AS lookup_keys_json, toJSONString(mapValues(src.lookup)) AS lookup_values_json, " \
        "toJSONString(src.tup) AS tup_json, hex(src.lc) AS lc_hex, if(variantType(src.v)='None', 'NULL', variantType(src.v)) AS v_type, ifNull(toJSONString(src.v), 'null') AS v_json " \
        "FROM default.#{TABLE} AS src#{predicate} ORDER BY src.pk FORMAT JSONEachRow;"
    end

    def initial_sql
      statements = [
        "SET output_format_json_map_as_array_of_tuples=1;",
        "SET output_format_json_named_tuples_as_objects=1;",
        "SET output_format_json_skip_null_value_in_named_tuples=0;",
        "SET output_format_json_quote_64bit_integers=0;",
        "SELECT '#{TAG[:pin]}', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
        "SELECT '#{TAG[:settings]}', #{JSON_SETTINGS.keys.map { |name| "toString(getSetting(#{sql_string(name)}))" }.join(', ')} FORMAT TSVRaw;",
        create_sql, insert_sql, check_sql,
        "SELECT '#{TAG[:schema]}', name, type FROM system.columns WHERE database='default' AND table='#{TABLE}' ORDER BY position FORMAT TSVRaw;",
        json_row_sql, json_row_sql(middle: true),
        "SELECT '#{TAG[:path]}', arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{TABLE}' FORMAT TSVRaw;",
        "SELECT '#{TAG[:engine]}', engine_full FROM system.tables WHERE database='default' AND name='#{TABLE}' FORMAT TSVRaw;",
        "SELECT '#{TAG[:part]}', name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{TABLE}' AND active ORDER BY name FORMAT TSVRaw;",
      ]
      statements.join("\n") + "\n"
    end

    def parse_native(stdout)
      lines = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      fields = ->(tag) { lines.map { |line| line.split("\t", -1) if line.start_with?("#{tag}\t") }.compact }
      checks = {}
      active = nil
      lines.each do |line|
        if line.start_with?("#{TAG[:check_begin]}\t")
          parts = line.split("\t", -1)
          fail!('malformed or duplicate CHECK begin marker') unless parts.size == 2 && parts[1] == TABLE && active.nil? && !checks.key?(TABLE)
          active = TABLE
          checks[TABLE] = []
        elsif line.start_with?("#{TAG[:check_end]}\t")
          parts = line.split("\t", -1)
          fail!('malformed or unpaired CHECK end marker') unless parts.size == 2 && active == parts[1]
          active = nil
        elsif active
          checks.fetch(active) << line
        end
      end
      fail!('unterminated native CHECK block') if active

      settings_fields = fields.call(TAG[:settings])
      fail!('native JSON setting pin is absent or repeated') unless settings_fields.size == 1
      setting_values = settings_fields.fetch(0).drop(1)
      fail!('native JSON format settings differ from explicit pins') unless setting_values == JSON_SETTINGS.values.to_a
      schemas = fields.call(TAG[:schema]).map { |entry| entry.drop(1) }
      path_fields = fields.call(TAG[:path])
      engine_fields = fields.call(TAG[:engine])
      part_fields = fields.call(TAG[:part])
      fail!('native source data path query is absent or repeated') unless path_fields.size == 1 && path_fields.first.size == 2
      fail!('native table engine metadata is absent or repeated') unless engine_fields.size == 1 && engine_fields.first.size == 2
      fail!('native active part metadata is absent or repeated') unless part_fields.size == 1 && part_fields.first.size == 6
      rows = Hash.new { |hash, tag| hash[tag] = [] }
      [TAG[:full], TAG[:middle]].each do |tag|
        lines.each do |line|
          next unless line.start_with?('{')
          item = JSON.parse(line)
          rows[item.fetch('__w261_tag')] << item if item['__w261_tag'] == tag
        end
      end
      part = part_fields.first
      {checks: checks, schemas: schemas, data_path: path_fields.first.fetch(1), engine_full: engine_fields.first.fetch(1),
       json_settings: JSON_SETTINGS, rows: rows,
       part: {name: part.fetch(1), path: part.fetch(2), part_type: part.fetch(3), rows: part.fetch(4), marks: part.fetch(5)}}
    rescue JSON::ParserError, KeyError, IndexError => error
      fail!("native output is malformed: #{error.class}: #{error.message}")
    end

    def parse_uint(value, label)
      fail!("native #{label} is not canonical decimal") unless value.is_a?(String) && /\A(?:0|[1-9][0-9]*)\z/.match?(value)
      value.to_i
    end

    def parse_json_field(row, name)
      value = row.fetch(name)
      fail!("native #{name} must be a JSON string") unless value.is_a?(String)
      JSON.parse(value)
    rescue JSON::ParserError => error
      fail!("native #{name} is malformed JSON: #{error.message}")
    end

    def expected_native_row(row)
      {
        'pk' => row.fetch(:pk).to_s, 'u' => row.fetch(:u).to_s,
        'side_hex' => row.fetch(:side).b.unpack1('H*'),
        'seq' => row.fetch(:seq).map { |id, details| {'id' => id, 'details' => {'note' => details.fetch(:note), 'score' => details.fetch(:score)}} },
        'mapped_keys' => row.fetch(:mapped).map(&:first),
        'mapped_values' => row.fetch(:mapped).map { |_key, value| {'meta' => {'note' => value.fetch(:meta).fetch(:note), 'id' => value.fetch(:meta).fetch(:id)}, 'score' => value.fetch(:score)} },
        'simple_keys' => row.fetch(:simple).map(&:first), 'simple_values' => row.fetch(:simple).map(&:last),
        'lookup_keys' => row.fetch(:lookup).map(&:first), 'lookup_values' => row.fetch(:lookup).map(&:last),
        'tup' => {'n' => row.fetch(:tup).first, 's' => row.fetch(:tup).last},
        'lc_hex' => row.fetch(:lc).b.unpack1('H*'),
        'v_type' => row.fetch(:v_type),
        'v' => row.fetch(:v),
      }
    end

    def normalize_native_row(row)
      {
        'pk' => row.fetch('pk'), 'u' => row.fetch('u'), 'side_hex' => row.fetch('side_hex').downcase,
        'seq' => parse_json_field(row, 'seq_json'),
        'mapped_keys' => parse_json_field(row, 'mapped_keys_json'),
        'mapped_values' => parse_json_field(row, 'mapped_values_json'),
        'simple_keys' => parse_json_field(row, 'simple_keys_json'),
        'simple_values' => parse_json_field(row, 'simple_values_json'),
        'lookup_keys' => parse_json_field(row, 'lookup_keys_json'),
        'lookup_values' => parse_json_field(row, 'lookup_values_json'),
        'tup' => parse_json_field(row, 'tup_json'), 'lc_hex' => row.fetch('lc_hex').downcase,
        'v_type' => row.fetch('v_type'), 'v' => parse_json_field(row, 'v_json'),
      }
    end

    def assert_native_fixture!(native)
      fail!('source CHECK is not exact CHECK=1') unless native[:checks] == {TABLE => ["#{PART_NAME}\t1\t"]}
      fail!('system.columns order/types differ from independent ten-column schema') unless native[:schemas] == SCHEMA
      fail!('stock ordered full JSONEachRow values differ from independent literals') unless
        native[:rows][TAG[:full]].map { |row| normalize_native_row(row) } == ROWS.map { |row| expected_native_row(row) }
      fail!('stock ordered middle JSONEachRow values differ from independent literals') unless
        native[:rows][TAG[:middle]].map { |row| normalize_native_row(row) } == ROWS[2, 4].map { |row| expected_native_row(row) }
      fail!('unexpected source row tag was captured') unless native[:rows].keys.sort == [TAG[:full], TAG[:middle]].sort
      fail!('source data path is empty or escaped the isolated store') unless
        native[:data_path].is_a?(String) && !native[:data_path].empty? && File.expand_path(native[:data_path]).start_with?(@store + File::SEPARATOR)
      engine = native[:engine_full].gsub(/\s+/, '')
      %w[map_serialization_version map_serialization_version_for_zero_level_parts].each do |name|
        fail!("resolved table engine omits #{name}=basic") unless engine.include?("#{name}='basic'") || engine.include?("#{name}=basic")
      end
      part = native[:part]
      fail!('source is not one active Wide 8-row part with the five-mark grid') unless
        part[:name] == PART_NAME && part[:part_type] == 'Wide' && part[:rows] == '8' && part[:marks] == '5'
      validate_native_part_path!(part[:path])
    end

    def validate_native_part_path!(path)
      fail!('native part path is absent') unless path && !path.empty?
      full = File.expand_path(path)
      fail!("native part path escaped isolated store: #{path}") unless full.start_with?(@store + File::SEPARATOR)
      full
    end

    def inspect_part(path, part)
      path = File.expand_path(path)
      fail!('native Wide part directory is absent or symlinked') unless File.directory?(path) && !File.symlink?(path)
      files = []
      total = 0
      Find.find(path) do |entry|
        stat = File.lstat(entry)
        fail!("stock part contains a symlink: #{entry}") if stat.symlink?
        next if entry == path || stat.directory?
        fail!("stock part contains a non-regular file: #{entry}") unless stat.file?
        total += stat.size
        fail!('stock part exceeds byte inventory bound') if total > MAX_PART_BYTES
        files << {path: entry.delete_prefix(path + File::SEPARATOR), bytes: stat.size, sha256: sha(entry)}
        fail!('stock part exceeds file inventory bound') if files.size > MAX_PART_FILES
      end
      files.sort_by! { |item| item[:path] }
      by_path = files.to_h { |item| [item[:path], item] }
      %w[columns.txt columns_substreams.txt count.txt checksums.txt primary.idx serialization.json default_compression_codec.txt metadata_version.txt].each do |name|
        fail!("stock part is missing #{name}") unless by_path.key?(name)
      end
      expected_columns = (["columns format version: 1", "#{SCHEMA.size} columns:"] +
                          SCHEMA.map { |name, type| "`#{name}` #{type}" }).join("\n") + "\n"
      fail!('stock columns.txt differs from the literal schema') unless File.read(File.join(path, 'columns.txt')) == expected_columns
      fail!('count.txt differs from eight literal rows') unless File.read(File.join(path, 'count.txt')).strip == '8'
      metadata_version = File.read(File.join(path, 'metadata_version.txt')).strip
      fail!('metadata_version.txt differs from plain mrk2 profile') unless metadata_version == '0'
      codec = File.read(File.join(path, 'default_compression_codec.txt')).strip
      fail!('part default codec is not LZ4') unless codec == 'CODEC(LZ4)'
      serialization_bytes = File.binread(File.join(path, 'serialization.json'))
      serialization = JSON.parse(serialization_bytes.force_encoding(Encoding::UTF_8))
      fail!('serialization.json version is not WITH_TYPES v1') unless serialization['version'] == 1
      fail!('nested serialization-version propagation is not true') unless serialization['propagate_types_serialization_versions_to_nested_types'] == true
      string_version = serialization.dig('types_serialization_versions', 'string')
      fail!('String serialization version is not with_size_stream/v1') unless string_version == 1
      # BASIC Map is pinned by the resolved CREATE TABLE engine settings; the
      # stock SerializationInfo writer omits BASIC Map from this version map.
      marks = files.select { |item| item[:path].end_with?('.mrk2') }
      compressed = files.select { |item| /\.cmrk\d*\z/.match?(item[:path]) }
      fail!('stock part has no plain mrk2 streams') if marks.empty?
      fail!('stock part unexpectedly has compressed mark files') unless compressed.empty?
      mark_rows = marks.to_h do |item|
        bytes = File.binread(File.join(path, item[:path]))
        fail!("#{item[:path]} is malformed plain mrk2 triples") unless bytes.bytesize.positive? && (bytes.bytesize % 24).zero?
        triples = bytes.unpack('Q<*').each_slice(3).map(&:dup)
        fail!("#{item[:path]} has wrong mark count") unless triples.size == 5
        [item[:path], triples.map { |triple| triple[2] }]
      end
      fail!("pk mark row grid differs: #{mark_rows["#{KEY_HASH}.mrk2"].inspect}") unless mark_rows["#{KEY_HASH}.mrk2"] == MARK_ROWS_WITH_EOF
      {
        name: part[:name], part_type: part[:part_type], rows: part[:rows], marks: part[:marks],
        count_text: '8', metadata_version: metadata_version, codec: codec,
        serialization_json: serialization, serialization_json_sha256: Digest::SHA256.hexdigest(serialization_bytes),
        columns_text: File.binread(File.join(path, 'columns.txt')).force_encoding(Encoding::UTF_8),
        columns_substreams_text: File.binread(File.join(path, 'columns_substreams.txt')).force_encoding(Encoding::UTF_8),
        plain_mark_rows_by_file: mark_rows, plain_mark_file_count: marks.size, compressed_mark_files: compressed.map { |item| item[:path] },
        files: files,
      }
    rescue JSON::ParserError => error
      fail!("stock serialization.json is malformed: #{error.message}")
    end

    def assert_path_allowed!(path, base)
      full = File.expand_path(path)
      fail!("path escaped expected root #{base}") unless full.start_with?(base + File::SEPARATOR)
      full
    end

    def write_summary(data)
      summary = {
        probe: FORMAT, status: data[:status], stage: @stage, fatal_error: data[:fatal_error],
        claim_boundary: 'one ten-column Wide/.mrk2 LZ4 stock fixture on the pinned runtime and selected readers explicitly exercised; no other physical profile or universal compatibility claim',
        source_snapshot: SOURCE_SNAPSHOT,
        runtime: {path: @binary, expected_sha256: BINARY_SHA256, sha256_before: @runtime_sha_before,
                  sha256_after: @runtime_sha_after, expected_version: VERSION, expected_build: BUILD},
        helper_provenance: {path: @helper, protocol: HELPER_FORMAT, mode: @mode,
                            sha256_before: @helper_sha_before, sha256_after: @helper_sha_after,
                            source_files_before: @source_sha_before, source_files_after: @source_sha_after},
        schema: SCHEMA, selected_columns_without_pk: SELECTED_COLUMNS, independent_rows: ROWS,
        settings: {table: SETTINGS, json: JSON_SETTINGS},
        mark_grid: {data_mark_rows: MARK_ROWS, rows_with_terminal: MARK_ROWS_WITH_EOF},
        limits: {max_threads: 1, max_memory_usage_bytes_per_native_process: W185::MEMORY,
                 timeout_seconds: W180::PROCESS_TIMEOUT_SECONDS, termination_grace_seconds: W180::TERMINATION_GRACE_SECONDS,
                 max_capture_bytes_per_stream: MAX_CAPTURE_BYTES, max_part_files: MAX_PART_FILES, max_part_bytes: MAX_PART_BYTES},
        evidence_root: @root, invocations: @invocations,
      }.merge(data.reject { |key, _| %i[status fatal_error].include?(key) })
      @capture.send(:write_new, File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      markdown = [
        '# W261 selected-metadata Wide stock capture', '',
        "Status: `#{summary[:status]}`", '',
        'The native stage writes one stock Wide part from eight independent Ruby rows. Map keys and values are selected into ordered arrays before JSON parsing, so duplicate keys are not collapsed. The helper stage reports ordinary controls separately from selected typed admission attempts; baseline typed rejection is data, not a runner failure.', '',
        "Runtime: #{VERSION} / #{BUILD} / SHA-256 `#{@runtime_sha_before}`", '',
        "Comparison source snapshot: `#{SOURCE_SNAPSHOT[:revision]}` at `#{SOURCE_SNAPSHOT[:path]}`; this is not claimed as the runtime binary provenance.", '',
        "Stock part for the focused Crystal spec: `#{@root}/stock-part.path` and `CRYSTAL_CLICK_W261_STOCK_PART=#{data[:native]&.dig(:part, :path)}`.", '',
        "Evidence root: `#{@root}`", '',
      ].join("\n")
      @capture.send(:write_new, File.join(@root, 'summary.md'), markdown)
    end
  end
end

def main
  options = {binary: ProbeWideRaggedSelectedMetadataW261::BINARY, mode: 'baseline'}
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/probe_wide_ragged_selected_metadata_w261.rb --helper PREBUILT_CHECKER --evidence-root EMPTY_DIRECT_CHILD_OF_PRIVATE_TMP [--mode baseline|green] [--binary CLICKHOUSE]'
    parser.on('--binary PATH') { |value| options[:binary] = value }
    parser.on('--helper PATH') { |value| options[:helper] = value }
    parser.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
    parser.on('--mode MODE', %w[baseline green]) { |value| options[:mode] = value }
  end.parse!
  raise 'prebuilt checker is required via --helper' unless options[:helper]
  exit(ProbeWideRaggedSelectedMetadataW261::Probe.new(**options).run ? 0 : 1)
rescue StandardError => error
  warn "W261 probe runner error: #{error.class}: #{error.message}"
  exit 1
end

main if $PROGRAM_NAME == __FILE__
