#!/usr/bin/env ruby
# Stock-first, depth-parameterized native witness for Array^depth(JSON) actuals
# in a typed Dynamic field of a Compact root JSON column. A typed Memory source
# column is observed before it is cast into the target declaration so empty
# arrays and NULL remain distinguishable.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'optparse'
require_relative 'probe_compact_part_writer_w271'

module ProbeCompactPartWriterW273
  W271 = ProbeCompactPartWriterW271
  W241 = W271::W241

  FORMAT = 'compact_part_writer_w273_native_probe_v1'.freeze
  HELPER_FORMAT = 'compact_part_writer_w273_helper_v1'.freeze
  STOCK_ONLY_SOURCE_SHA256 = '73e59b1a5bfd8104030cf3f89e8a4f4377c98752929e4dbf8b56726493c04e9e'.freeze
  PART_NAME = 'all_1_1_0'.freeze
  BINARY = W271::BINARY
  BINARY_SHA256 = W271::BINARY_SHA256
  VERSION = W271::VERSION
  BUILD = W271::BUILD
  SOURCE_ROOT = W271::SOURCE_ROOT
  SOURCE_REVISION = W271::SOURCE_REVISION
  SOURCE_FILES = W271::SOURCE_FILES
  W271_SOURCE = File.expand_path('probe_compact_part_writer_w271.rb', __dir__).freeze
  W241_SOURCE = File.expand_path('probe_object_shared_json_interop_w241.rb', __dir__).freeze
  HELPER_SOURCE = File.expand_path('compact_part_writer_w273_helper.cr', __dir__).freeze
  NATIVE_FIXTURE_SOURCE = File.expand_path('support/compact_part_writer_w273_native_fixture.cr', __dir__).freeze
  LOCAL_FIXTURE_SOURCE = File.expand_path('../spec/support/compact_part_writer_w273_fixture.cr', __dir__).freeze
  PROBE_SOURCE = File.expand_path(__FILE__).freeze

  COLUMN = 'typed_dynamic_nested_array_json'.freeze
  SOURCE_COLUMN = 'typed_dynamic_array_json_source'.freeze
  DECLARATION = 'JSON(max_dynamic_types=1,max_dynamic_paths=0,payload Dynamic(max_types=1))'.freeze
  HELPER_DECLARATION = 'JSON(max_dynamic_types=1, max_dynamic_paths=0, payload Dynamic(max_types=1))'.freeze
  ROWS_PER_MARK = 2
  ROW_COUNT = 8
  MARK_COUNT = 4
  MODES = %w[basic compact].freeze
  MARK_FORMATS = %w[mrk3 mrk4].freeze
  BINARY_JSON_NULL = '6e756c6c'.freeze
  MAX_PART_FILES = 160
  MAX_PART_BYTES = 64 * 1024 * 1024
  MAX_RAW_FILE_BYTES = 16 * 1024 * 1024
  MAX_REPORT_BYTES = 2 * 1024 * 1024

  # Integer leaves are deliberately native bare-JSON values. ClickHouse's
  # inferred JSON path type must be observed as Int64; the separate local spec
  # fixture uses UInt8 and is never used as native type evidence.
  ROWS_BY_DEPTH = {
    2 => [
      [[11, 12], [13]], nil, nil, nil, [], [[]], nil, [[81], [82, 83], []],
    ],
    3 => [
      [[[11, 12], []], [[13, 14]]], nil, nil, nil, [], [[]], [[[]]], [[[81]], [[82, 83], []], []],
    ],
  }.freeze
  EXPECTED_ACTUAL_COUNTS = {2 => [1, 0, 2, 1], 3 => [1, 0, 2, 2]}.freeze
  EXPECTED_SIZE_VECTORS = {
    2 => [
      [[2], [2, 1]], [[], []], [[0, 1], [0]], [[3], [1, 2, 0]],
    ],
    3 => [
      [[2], [2, 1], [2, 0, 2]], [[], [], []], [[0, 1], [0], []],
      [[1, 3], [1, 1, 2, 0], [0, 1, 2, 0]],
    ],
  }.freeze
  EXPECTED_ELEMENT_COUNTS = {
    2 => [[2, 0, 1, 3], [3, 0, 0, 3]],
    3 => [[2, 0, 1, 4], [3, 0, 0, 4], [4, 0, 0, 3]],
  }.freeze
  EXPECTED_JSON_LEAF_COUNTS = {2 => [3, 0, 0, 3], 3 => [4, 0, 0, 3]}.freeze
  EXPECTED_WHOLE_GRID_CALLBACK_COUNTS = {2 => 20, 3 => 21}.freeze
  EXPECTED_OBJECT_COLUMN_CALLBACK_COUNTS = {2 => 19, 3 => 20}.freeze
  EXPECTED_PK_CALLBACK_NAMES = ['pk'].freeze
  SQL_WINDOWS = {
    'full' => nil,
    'middle' => 'pk BETWEEN 3 AND 6',
    'zero_actual' => 'pk BETWEEN 3 AND 4',
    'selected_empty' => 'pk BETWEEN 5 AND 6',
    'last' => 'pk BETWEEN 7 AND 8',
    'unaffected' => 'pk BETWEEN 1 AND 2',
    'empty' => 'pk > 8',
  }.freeze
  PHYSICAL_WINDOWS = {
    'full' => [0, 4].freeze,
    'middle' => [1, 2].freeze,
    'zero_actual' => [1, 1].freeze,
    'selected_empty' => [2, 1].freeze,
    'last' => [3, 1].freeze,
    'unaffected' => [0, 1].freeze,
    'empty' => [4, 0].freeze,
  }.freeze

  class Failure < StandardError; end

  class Probe
    def initialize(binary:, source_root:, evidence_root:, depth:, stock_only: true, full_matrix: false,
                   helper: nil, helper_sha256: nil)
      @binary = validate_executable(binary, 'pinned ClickHouse')
      @source_root = File.expand_path(source_root)
      fail!('source root differs from the separately pinned upstream checkout') unless @source_root == SOURCE_ROOT
      @stock_only = stock_only
      @full_matrix = full_matrix
      fail!('select exactly one of --stock-only or --full-matrix') unless @stock_only != @full_matrix
      @depth = Integer(depth)
      fail!('W273 stock witness depth must be 2 or 3') unless ROWS_BY_DEPTH.key?(@depth)
      @rows = ROWS_BY_DEPTH.fetch(@depth)
      @array_type = 'Array(' * @depth + 'JSON' + ')' * @depth
      @source_declaration = "JSON(max_dynamic_paths=0,max_dynamic_types=0,payload #{@array_type})".freeze
      @helper = nil
      @helper_expected_sha = nil
      if @full_matrix
        @helper = validate_executable(helper, 'prebuilt W273 helper')
        @helper_expected_sha = helper_sha256
        fail!('--helper-sha256 must be a lowercase SHA-256') unless @helper_expected_sha&.match?(/\A[0-9a-f]{64}\z/)
      end
      @root = validate_root(evidence_root)
      @token = Digest::SHA256.hexdigest(@root)[0, 8]
      @invocations = []
      @runner = W241::Probe.allocate
      @runner.instance_variable_set(:@binary, @binary)
      @runner.instance_variable_set(:@root, @root)
      @runner.instance_variable_set(:@invocations, @invocations)
      @fatal_error = nil
      validate_fixture!
    rescue ArgumentError, TypeError => error
      raise Failure, "W273: invalid depth: #{error.message}"
    end

    def run
      prepare!
      if @stock_only
        stock = capture_stock!
        validate_pins!
        observation = stock.fetch(:observation)
        summary = {
          format: FORMAT,
          status: observation.fetch(:matches_expected_semantics) && stock.fetch(:source_observation).fetch(:matches_expected_semantics) ?
            'stock_native_semantics_exact' : 'stock_observation_differs',
          execution_mode: 'stock_only_no_crystal_helper_or_generated_writer',
          runtime_pin: {
            binary: @binary, sha256: @binary_sha_after, version: VERSION, build: BUILD,
            argv_policy: 'W241 clickhouse-local runner; one thread; bounded memory and timeout; every process records argv/stdin/stdout/stderr/status',
          },
          source_pin: {
            root: @source_root, revision: SOURCE_REVISION, sha256: @upstream_hashes,
            distinction: 'upstream source pin is validated separately from the runtime executable/build pin',
          },
          probe_sources: @probe_hashes_after,
          stock_capture_lineage: stock_capture_lineage,
          fixture: {
            target_column: COLUMN, target_declaration: DECLARATION,
            typed_source_column: SOURCE_COLUMN, typed_source_declaration: @source_declaration,
            depth: @depth, array_actual_type: @array_type,
            rows_by_pk: @rows.each_with_index.map { |value, index| {pk: index + 1, value: value} },
            rows_per_mark: ROWS_PER_MARK, row_count: ROW_COUNT, data_mark_count: MARK_COUNT,
            expected_nonnull_actual_counts_per_mark: EXPECTED_ACTUAL_COUNTS.fetch(@depth),
            expected_array_size_vectors_by_mark: EXPECTED_SIZE_VECTORS.fetch(@depth),
            expected_array_element_counts_by_level_and_mark: EXPECTED_ELEMENT_COUNTS.fetch(@depth),
            expected_json_leaf_counts_per_mark: EXPECTED_JSON_LEAF_COUNTS.fetch(@depth),
            expected_native_leaf_path_types: {'value' => 'Int64'},
            constructor: 'typed source COLUMN cast to declared Dynamic target; NULL rows cast directly to target',
            constructor_boundary: 'the constructor is intent only; source actual identity, target Dynamic actual/shared status, nested values, every Array size level, and JSON leaf path types are checked from native SQL',
          },
          stock: stock,
          invocations: @invocations,
          evidence_root: @root,
          claim_boundary: 'This is a stock-only native witness on one pinned runtime and one BASIC/MRK4 Compact part at the requested bounded depth. It does not qualify the Crystal writer, other mark/discriminator profiles, or equate native Int64 leaf JSON with the separate local UInt8 fixture.',
        }
      else
        stock = {}
        MODES.each { |mode| stock[mode] = capture_stock!(mode, full_matrix: true) }
        generated = {}
        MARK_FORMATS.product(MODES).each do |mark_format, mode|
          generated["#{mark_format}_#{mode}"] = capture_generated!(mark_format, mode, stock.fetch(mode))
        end
        mutant = qualify_child_dynamic_version_mutant!(generated.fetch('mrk4_basic'))
        validate_pins!
        summary = full_matrix_summary(stock, generated, mutant)
      end
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      write_new(File.join(@root, 'summary.md'), render_summary(summary))
      puts "W273 depth=#{@depth} status=#{summary.fetch(:status)}; stock=#{@stock_only ? 1 : stock.size}; generated=#{@stock_only ? 0 : generated.size}; evidence=#{@root}"
      @stock_only ? summary.fetch(:status) == 'stock_native_semantics_exact' : true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      persist_inconclusive(error)
      warn "W273 probe inconclusive: #{@fatal_error}"
      false
    end

    private

    def fail!(message)
      raise Failure, "W273: #{message}"
    end

    def validate_root(path)
      fail!('evidence root is required') unless path && !path.empty?
      expanded = File.expand_path(path)
      fail!('evidence root must be a direct child of /private/tmp') unless File.dirname(expanded) == File.realpath('/private/tmp')
      fail!('evidence root must be canonical, non-symlinked, and empty') unless
        !File.symlink?(expanded) && File.directory?(expanded) && File.realpath(expanded) == expanded && Dir.children(expanded).empty?
      expanded
    rescue Errno::ENOENT
      fail!('evidence root and /private/tmp must already exist')
    end

    def validate_executable(path, label)
      fail!("#{label} path is absent") unless path && !path.empty?
      expanded = File.expand_path(path)
      fail!("#{label} is absent, non-executable, or symlinked") unless
        File.file?(expanded) && File.executable?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded
      expanded
    end

    def validate_fixture!
      fail!('fixture must contain exactly eight ordered rows and four two-row marks') unless
        @rows.size == ROW_COUNT && @rows.each_slice(ROWS_PER_MARK).to_a.size == MARK_COUNT
      actual_counts = @rows.each_slice(ROWS_PER_MARK).map { |mark| mark.count { |value| !value.nil? } }
      fail!("literal actual counts differ: #{actual_counts.inspect}") unless actual_counts == EXPECTED_ACTUAL_COUNTS.fetch(@depth)
      vectors = expected_size_vectors_by_mark
      fail!("literal Array size vectors differ: #{vectors.inspect}") unless vectors == EXPECTED_SIZE_VECTORS.fetch(@depth)
      fail!('fixture must retain NULL, [], and [[]] as distinct rows') unless
        @rows[1].nil? && @rows[4] == [] && @rows[5] == [[]]
      fail!('depth-three fixture must retain [[[]]] independently') if @depth == 3 && @rows[6] != [[[]]]
    end

    def prepare!
      %w[invocations stores source-inventories raw-records parts].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      @binary_sha_before = sha(@binary)
      fail!('ClickHouse executable differs from pinned runtime SHA-256') unless @binary_sha_before == BINARY_SHA256
      revision, stderr, status = Open3.capture3('git', '-C', @source_root, 'rev-parse', 'HEAD')
      fail!("pinned upstream revision check failed: #{stderr.strip}") unless status.success? && revision.strip == SOURCE_REVISION
      @upstream_hashes = SOURCE_FILES.to_h do |relative|
        path = File.join(@source_root, relative)
        fail!("pinned upstream source is missing or symlinked: #{relative}") unless File.file?(path) && !File.symlink?(path)
        [relative, sha(path)]
      end
      @probe_sources = [File.realpath(PROBE_SOURCE), W271_SOURCE, W241_SOURCE]
      @probe_sources.concat([HELPER_SOURCE, NATIVE_FIXTURE_SOURCE, LOCAL_FIXTURE_SOURCE]) if @full_matrix
      @probe_hashes_before = @probe_sources.to_h { |path| [path, sha(path)] }
      if @full_matrix
        @helper_sha_before = sha(@helper)
        fail!('prebuilt helper SHA differs from CLI pin') unless @helper_sha_before == @helper_expected_sha
      end
    end

    def validate_pins!
      @binary_sha_after = sha(@binary)
      @probe_hashes_after = @probe_sources.to_h { |path| [path, sha(path)] }
      fail!('ClickHouse executable changed during stock capture') unless @binary_sha_after == BINARY_SHA256
      fail!('a probe or runner source changed during stock capture') unless @probe_hashes_after == @probe_hashes_before
      if @full_matrix
        @helper_sha_after = sha(@helper)
        fail!('prebuilt helper changed during the probe') unless @helper_sha_after == @helper_sha_before
      end
    end

    def sha(path)
      Digest::SHA256.file(path).hexdigest
    end

    def write_new(path, bytes)
      fail!('evidence record exceeds the report output cap') if bytes.bytesize > MAX_REPORT_BYTES
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes) }
    end

    def store_path(name)
      path = File.join(@root, 'stores', name)
      Dir.mkdir(path, 0o700) unless Dir.exist?(path)
      fail!("store path is symlinked or noncanonical: #{path}") if File.symlink?(path) || File.realpath(path) != path
      path
    end

    def native(label, store, sql, allow_server_error: false)
      pinned_sql = [@runner.send(:pin_sql), sql].join("\n")
      result = @runner.send(:native, label, store, pinned_sql)
      record = result.fetch(:record)
      fail!("#{label} timed out or had a process infrastructure failure") unless
        !record[:timed_out] && record[:spawn_error].nil? && record[:stdin_write_error].nil? &&
        record[:stdout_read_error].nil? && record[:stderr_read_error].nil? && result[:status] && result[:status].termsig.nil?
      accepted = allow_server_error ? %w[success server_exception] : ['success']
      fail!("#{label} native classification #{result[:classification]} is outside #{accepted.inspect}") unless
        accepted.include?(result[:classification])
      if result[:classification] == 'success'
        fail!("#{label} ClickHouse process failed") unless result[:status].success?
        @runner.send(:assert_native_success!, result, label)
      else
        fail!("#{label} ClickHouse identity changed") unless record[:binary_sha_after] == BINARY_SHA256
      end
      @runner.send(:assert_pin!, result[:stdout], label)
      result
    end

    def native_lines(result, label)
      output = result.fetch(:stdout).dup.force_encoding(Encoding::UTF_8)
      fail!("#{label} stdout is not newline-terminated UTF-8") unless output.valid_encoding? && output.end_with?("\n")
      output.lines.map(&:chomp)
    end

    def tagged(lines, tag, width, label)
      lines.select { |line| line.start_with?(tag + "\t") }.map do |line|
        fields = line.split("\t", -1)
        fail!("#{label} malformed tagged row") unless fields.size == width
        fields
      end
    end

    def marker(kind, id)
      "__W273_#{kind.upcase}_#{id.upcase}__"
    end

    def sql_string(value)
      "'#{value.to_s.gsub(/[\\']/) { |character| "\\#{character}" }}'"
    end

    def normalized_type(value)
      value.delete(' ')
    end

    def escaped_stream_component(value)
      value.to_s.each_byte.map do |byte|
        word = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) ||
          (byte >= 48 && byte <= 57) || byte == 95
        word ? byte.chr : format('%%%02X', byte)
      end.join
    end

    def nested_child_dynamic_structure_stream
      [COLUMN, 'payload', array_type, 'value'].map { |component| escaped_stream_component(component) }.join('.') + '.dynamic_structure'
    end

    def source_document(value)
      {'payload' => map_leaves(value) { |leaf| {'value' => leaf} }}
    end

    def map_leaves(value, &block)
      return yield(value) unless value.is_a?(Array)
      value.map { |child| map_leaves(child, &block) }
    end

    def leaf_types_tree(value)
      map_leaves(value) { |_leaf| {'value' => 'Int64'} }
    end

    def size_vectors_for(value)
      return Array.new(@depth) { [] } if value.nil?
      current = [value]
      Array.new(@depth) do
        sizes = current.map(&:size)
        current = current.flat_map(&:itself)
        sizes
      end
    end

    def expected_size_vectors_by_mark
      @rows.each_slice(ROWS_PER_MARK).map do |mark|
        per_row = mark.map { |value| size_vectors_for(value) }
        Array.new(@depth) do |level|
          per_row.flat_map { |vectors| vectors.fetch(level) }
        end
      end
    end

    def expected_element_counts_by_level_and_mark
      expected_size_vectors_by_mark.transpose.map { |marks| marks.map(&:sum) }
    end

    def expected_json_leaf_counts_by_mark
      expected_size_vectors_by_mark.map { |mark| mark.fetch(@depth - 1).sum }
    end

    def recursive_sizes_expression(base, level)
      return "[toUInt64(length(#{base}))]" if level.zero?
      build = lambda do |expression, remaining, ordinal|
        variable = "w273_size_#{ordinal}"
        remaining == 1 ? "arrayMap(#{variable} -> length(#{variable}), #{expression})" :
          "arrayMap(#{variable} -> #{build.call(variable, remaining - 1, ordinal + 1)}, #{expression})"
      end
      build.call(base, level, 0)
    end

    def leaf_types_expression(base, depth, ordinal = 0)
      variable = "w273_leaf_#{ordinal}"
      if depth == 1
        "arrayMap(#{variable} -> JSONAllPathsWithTypes(#{variable}), #{base})"
      else
        "arrayMap(#{variable} -> #{leaf_types_expression(variable, depth - 1, ordinal + 1)}, #{base})"
      end
    end

    def expected_payload_for(value)
      value.nil? ? nil : map_leaves(value) { |leaf| {'value' => leaf} }
    end

    def expected_leaf_types_for(value)
      value.nil? ? nil : leaf_types_tree(value)
    end

    def expected_source_rows
      @rows.each_with_index.map do |value, index|
        next if value.nil?
        [index + 1, expected_payload_for(value), size_vectors_for(value), expected_leaf_types_for(value)]
      end.compact
    end

    def array_type
      @array_type
    end

    def source_table_name(id)
      "#{table_name(id)}_typed_source"
    end

    def table_name(id)
      "w273_#{@token}_#{id}"
    end

    def source_insert_sql(id)
      source = source_table_name(id)
      rows = @rows.each_with_index.map do |value, index|
        next if value.nil?
        json = JSON.generate(source_document(value))
        "SELECT toUInt64(#{index + 1}) AS pk, CAST(#{sql_string(json)}, #{sql_string(@source_declaration)}) AS `#{SOURCE_COLUMN}`"
      end.compact
      "CREATE TABLE default.#{source} (pk UInt64, `#{SOURCE_COLUMN}` #{@source_declaration}) ENGINE=Memory;\n" \
        "INSERT INTO default.#{source}\n#{rows.join("\nUNION ALL\n")};\n"
    end

    def source_values_sql(id)
      tag = marker('source_values', id)
      source = "`#{SOURCE_COLUMN}`.payload"
      sizes = (0...@depth).map { |level| "hex(toJSONString(#{recursive_sizes_expression(source, level)}))" }
      leaf_types = "hex(toJSONString(#{leaf_types_expression(source, @depth)}))"
      fields = ["'#{tag}'", 'toString(pk)', "toTypeName(#{source})", "hex(toJSONString(#{source}))", leaf_types] + sizes
      "SELECT #{fields.join(', ')} FROM default.#{source_table_name(id)} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;\n"
    end

    def null_target_rows
      @rows.each_with_index.map do |value, index|
        next unless value.nil?
        "SELECT toUInt64(#{index + 1}) AS pk, CAST('{\"payload\":null}', #{sql_string(DECLARATION)}) AS `#{COLUMN}`"
      end.compact
    end

    def create_and_insert_sql(mode, id, mark_format: 'mrk4')
      source = source_table_name(id)
      table = table_name(id)
      nonnull = "SELECT pk, CAST(`#{SOURCE_COLUMN}`, #{sql_string(DECLARATION)}) AS `#{COLUMN}` FROM default.#{source}"
      inserts = [nonnull] + null_target_rows
      "SET flatten_nested=0;\n" \
        "#{source_insert_sql(id)}" \
        "#{source_values_sql(id)}" \
        "CREATE TABLE default.#{table} (pk UInt64, `#{COLUMN}` #{DECLARATION}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings(mode, mark_format: mark_format)};\n" \
        "INSERT INTO default.#{table}\n#{inserts.join("\nUNION ALL\n")};\n"
    end

    def settings(mode, mark_format: 'mrk4')
      fail!("unsupported discriminator mode #{mode.inspect}") unless MODES.include?(mode)
      discriminator = mode == 'compact' ? 1 : 0
      substream_marks = mark_format == 'mrk4' ? 1 : 0
      [
        'index_granularity=2', 'index_granularity_bytes=10485760', 'enable_mixed_granularity_parts=1',
        'min_rows_for_wide_part=1000000', 'min_bytes_for_wide_part=104857600', 'min_level_for_wide_part=0',
        'compress_marks=0', 'compress_primary_key=0', 'write_final_mark=1',
        "write_marks_for_substreams_in_compact_parts=#{substream_marks}",
        'min_compress_block_size=0', 'max_compress_block_size=4096', 'ratio_of_defaults_for_sparse_serialization=1.0',
        "default_compression_codec='LZ4'", "serialization_info_version='with_types'",
        'propagate_types_serialization_versions_to_nested_types=true', "string_serialization_version='single_stream'",
        "object_serialization_version='v3'", "object_shared_data_serialization_version_for_zero_level_parts='map'",
        'object_shared_data_buckets_for_compact_part=1', "dynamic_serialization_version='v3'",
        "use_compact_variant_discriminators_serialization=#{discriminator}", 'allow_suspicious_low_cardinality_types=1',
      ].join(', ')
    end

    def decode_hex_json(value, label)
      fail!("#{label} malformed JSON hex") unless value.match?(/\A(?:[0-9a-f]{2})*\z/i)
      JSON.parse([value].pack('H*'))
    rescue JSON::ParserError => error
      fail!("#{label} invalid JSON payload: #{error.message}")
    end

    def flatten_numbers(value)
      return [value] if value.is_a?(Integer)
      fail!('native Array size lane contains a non-array, non-integer value') unless value.is_a?(Array)
      value.flat_map { |child| flatten_numbers(child) }
    end

    def observe_source!(id, create_result)
      lines = native_lines(create_result, "#{id} source-column SELECT")
      tag = marker('source_values', id)
      rows = tagged(lines, tag, 5 + @depth, id)
      expected = expected_source_rows
      fail!("#{id} typed Memory source row count differs") unless rows.size == expected.size
      actual = rows.map do |fields|
        {
          pk: Integer(fields[1], 10), declared_array_type: fields[2],
          payload: decode_hex_json(fields[3], "#{id}/source/payload"),
          leaf_json_path_types: decode_hex_json(fields[4], "#{id}/source/leaf types"),
          array_size_vectors: fields.drop(5).map { |value| flatten_numbers(decode_hex_json(value, "#{id}/source/sizes")) },
        }
      end
      exact = actual.each_with_index.all? do |row, index|
        expected_pk, payload, sizes, types = expected.fetch(index)
        row.fetch(:pk) == expected_pk && normalized_type(row.fetch(:declared_array_type)) == array_type &&
          row.fetch(:payload) == payload && row.fetch(:array_size_vectors) == sizes && row.fetch(:leaf_json_path_types) == types
      end
      {
        state: exact ? 'typed_source_actual_and_nested_shapes_observed' : 'typed_source_observation_differs',
        matches_expected_semantics: exact, table: source_table_name(id), engine: 'Memory',
        column: SOURCE_COLUMN, declared_type: @source_declaration, rows: actual,
        expected_array_size_vectors_by_mark: EXPECTED_SIZE_VECTORS.fetch(@depth),
      }
    end

    def target_values_sql(id, table)
      tag = marker('values', id)
      dynamic = "`#{COLUMN}`.payload"
      actual = "dynamicElement(#{dynamic}, #{sql_string(array_type)})"
      leaf_types = leaf_types_expression(actual, @depth)
      sizes = (0...@depth).map do |level|
        "if(isNull(#{dynamic}), '#{BINARY_JSON_NULL}', hex(toJSONString(#{recursive_sizes_expression(actual, level)})))"
      end
      fields = [
        "'#{tag}'", 'toString(pk)', "if(isNull(#{dynamic}), 'None', dynamicType(#{dynamic}))",
        "if(isNull(#{dynamic}), 'false', if(isDynamicElementInSharedData(#{dynamic}), 'true', 'false'))",
        "if(isNull(#{dynamic}), '#{BINARY_JSON_NULL}', hex(toJSONString(#{actual})))",
        "if(isNull(#{dynamic}), '#{BINARY_JSON_NULL}', hex(toJSONString(#{leaf_types})))",
      ] + sizes
      "SELECT #{fields.join(', ')} FROM default.#{table} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;\n"
    end

    def selected_rows_by_window(id, table, window, store:, allow_server_error: false)
      predicate = SQL_WINDOWS.fetch(window)
      tag = marker('window_values', "#{id}_#{window}")
      if window == 'empty'
        result = native("#{id}_select_#{window}", store,
                        "SELECT '#{tag}', toString(count()) FROM default.#{table} WHERE #{predicate} FORMAT TSVRaw;\n")
        rows = tagged(native_lines(result, "#{id} #{window}"), tag, 2, id)
        fail!("#{id} empty SQL window differs") unless rows == [[tag, '0']]
        return {state: 'exact_values', row_count: 0, rows: [], invocation: result.fetch(:record)}
      end
      dynamic = "`#{COLUMN}`.payload"
      actual = "dynamicElement(#{dynamic}, #{sql_string(array_type)})"
      leaf_types = leaf_types_expression(actual, @depth)
      sizes = (0...@depth).map do |level|
        "if(isNull(#{dynamic}), '#{BINARY_JSON_NULL}', hex(toJSONString(#{recursive_sizes_expression(actual, level)})))"
      end
      where = predicate ? " WHERE #{predicate}" : ''
      fields = [
        "'#{tag}'", 'toString(pk)', "if(isNull(#{dynamic}), 'None', dynamicType(#{dynamic}))",
        "if(isNull(#{dynamic}), 'false', if(isDynamicElementInSharedData(#{dynamic}), 'true', 'false'))",
        "if(isNull(#{dynamic}), '#{BINARY_JSON_NULL}', hex(toJSONString(#{actual})))",
        "if(isNull(#{dynamic}), '#{BINARY_JSON_NULL}', hex(toJSONString(#{leaf_types})))",
      ] + sizes
      sql = "SELECT #{fields.join(', ')} FROM default.#{table}#{where} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;\n"
      result = native("#{id}_select_#{window}", store, sql,
                       allow_server_error: allow_server_error)
      if result[:classification] == 'server_exception'
        return {
          state: 'server_exception', classification: result[:classification],
          exit: result.fetch(:record).fetch(:exit), stderr: result.fetch(:stderr),
          invocation: result.fetch(:record),
        }
      end
      rows = tagged(native_lines(result, "#{id} #{window}"), tag, 6 + @depth, id)
      expected_pks = case window
                     when 'full' then (1..ROW_COUNT).to_a
                     when 'middle' then (3..6).to_a
                     when 'zero_actual' then [3, 4]
                     when 'selected_empty' then [5, 6]
                     when 'last' then [7, 8]
                     when 'unaffected' then [1, 2]
                     else []
                     end
      expected = expected_pks.map do |pk|
        value = @rows.fetch(pk - 1)
        expected_sizes = value.nil? ? Array.new(@depth) { nil } : size_vectors_for(value)
        [pk, value.nil? ? 'None' : array_type, false, expected_payload_for(value), expected_leaf_types_for(value), expected_sizes]
      end
      actual_rows = rows.map do |fields|
        fail!("#{id}/#{window} shared-data flag is not boolean") unless %w[true false].include?(fields[3])
        payload = fields[4] == BINARY_JSON_NULL ? nil : decode_hex_json(fields[4], "#{id}/#{window}/payload")
        leaf_types = fields[5] == BINARY_JSON_NULL ? nil : decode_hex_json(fields[5], "#{id}/#{window}/leaf types")
        sizes = fields.drop(6).map do |value|
          value == BINARY_JSON_NULL ? nil : flatten_numbers(decode_hex_json(value, "#{id}/#{window}/sizes"))
        end
        [Integer(fields[1], 10), normalized_type(fields[2]), fields[3] == 'true', payload, leaf_types, sizes]
      end
      exact = actual_rows == expected
      fail!("#{id} #{window} native nested actual/type/shared/payload/size/path observations differ: #{actual_rows.inspect}") unless exact
      {
        state: 'exact_values', row_count: actual_rows.size, rows: actual_rows,
        native_array_size_vectors: actual_rows.reject { |row| row[1] == 'None' }.map { |row| [row[0], row[5]] },
        invocation: result.fetch(:record),
      }
    end

    def observe_target!(id, table, store: store_path("native_#{id}"))
      windows = SQL_WINDOWS.to_h { |name, _| [name, selected_rows_by_window(id, table, name, store: store)] }
      rows = windows.fetch('full').fetch(:rows)
      actual_counts = rows.each_slice(ROWS_PER_MARK).map { |mark| mark.count { |row| row[1] != 'None' } }
      size_vectors_by_mark = rows.each_slice(ROWS_PER_MARK).map do |mark|
        Array.new(@depth) do |level|
          mark.reject { |row| row[1] == 'None' }.flat_map { |row| row[5].fetch(level) }
        end
      end
      element_counts = size_vectors_by_mark.transpose.map { |marks| marks.map(&:sum) }
      json_leaf_counts = size_vectors_by_mark.map { |mark| mark.fetch(@depth - 1).sum }
      exact_grid = actual_counts == EXPECTED_ACTUAL_COUNTS.fetch(@depth) &&
        size_vectors_by_mark == EXPECTED_SIZE_VECTORS.fetch(@depth) &&
        element_counts == EXPECTED_ELEMENT_COUNTS.fetch(@depth) &&
        json_leaf_counts == EXPECTED_JSON_LEAF_COUNTS.fetch(@depth)
      {
        state: exact_grid ? 'expected_native_semantics_observed' : 'observation_differs',
        matches_expected_semantics: exact_grid,
        actual_counts_per_mark: actual_counts,
        expected_actual_counts_per_mark: EXPECTED_ACTUAL_COUNTS.fetch(@depth),
        array_size_vectors_by_mark_and_level: size_vectors_by_mark,
        expected_array_size_vectors_by_mark_and_level: EXPECTED_SIZE_VECTORS.fetch(@depth),
        array_element_counts_by_level_and_mark: element_counts,
        expected_array_element_counts_by_level_and_mark: EXPECTED_ELEMENT_COUNTS.fetch(@depth),
        json_leaf_counts_per_mark: json_leaf_counts,
        expected_json_leaf_counts_per_mark: EXPECTED_JSON_LEAF_COUNTS.fetch(@depth),
        rows: rows, windows: windows,
      }
    end

    def safe_native_path(raw, store, label)
      fail!("#{label} native path is not absolute") unless raw.is_a?(String) && raw.start_with?(File::SEPARATOR)
      path = raw.end_with?(File::SEPARATOR) ? raw[0...-1] : raw
      root = File.realpath(store)
      fail!("#{label} native path escaped its isolated store") unless path.start_with?(root + File::SEPARATOR)
      fail!("#{label} native path is not canonical") unless
        File.expand_path(path) == path && File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path
      path
    rescue Errno::ENOENT, Errno::EACCES => error
      fail!("#{label} native path validation failed: #{error.class}: #{error.message}")
    end

    def inspect_part!(id, table, store, mark_format: 'mrk4')
      schema_tag = marker('schema', id)
      part_tag = marker('part', id)
      sql = "SELECT '#{schema_tag}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;\n" \
        "SELECT '#{part_tag}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;\n"
      result = native("#{id}_schema_part", store, sql)
      lines = native_lines(result, "#{id} schema and part")
      schema = tagged(lines, schema_tag, 3, id).map { |row| row.drop(1) }
      canonical_schema = schema.map { |name, type| [name, normalized_type(type)] }
      expected_schema = [['pk', 'UInt64'], [COLUMN, normalized_type(DECLARATION)]]
      fail!("#{id} declared schema differs: #{canonical_schema.inspect}") unless canonical_schema == expected_schema
      parts = tagged(lines, part_tag, 7, id)
      fail!("#{id} must have one Compact part with eight rows/five marks") unless parts.size == 1 &&
        parts.first.values_at(1, 2, 4, 5, 6) == [table, PART_NAME, 'Compact', ROW_COUNT.to_s, '5']
      path = safe_native_path(parts.first.fetch(3), store, id)
      mark_file = File.join(path, "data.#{mark_format}")
      other_mark_file = File.join(path, mark_format == 'mrk4' ? 'data.mrk3' : 'data.mrk4')
      fail!("#{id} witness does not have exactly the selected mark file") unless
        File.file?(mark_file) && !File.symlink?(mark_file) && !File.exist?(other_mark_file)
      {table: table, path: path, schema: canonical_schema, part: parts.first, mark_format: mark_format}
    end

    def tree_inventory(path)
      files = []
      total = 0
      Find.find(path) do |entry|
        next if entry == path
        stat = File.lstat(entry)
        fail!("symlink in stock part tree: #{entry}") if stat.symlink?
        next if stat.directory?
        fail!("non-regular stock part file: #{entry}") unless stat.file?
        fail!('stock part file-count bound exceeded') if files.size >= MAX_PART_FILES
        total += stat.size
        fail!('stock part byte bound exceeded') if total > MAX_PART_BYTES
        files << {path: entry.delete_prefix(path + File::SEPARATOR), size: stat.size, sha256: sha(entry)}
      end
      {files: files.sort_by { |item| item.fetch(:path) }, total_bytes: total}
    end

    def callback_roster!(id, path)
      file = File.join(path, 'columns_substreams.txt')
      fail!("#{id} callback roster missing or symlinked") unless File.file?(file) && !File.symlink?(file)
      text = File.binread(file).force_encoding(Encoding::UTF_8)
      lines = text.split("\n", -1)
      fail!("#{id} callback roster is not newline-terminated UTF-8") unless text.valid_encoding? && lines.pop == ''
      fail!("#{id} callback roster version differs") unless lines.shift == 'columns substreams version: 1'
      header = /\A(0|[1-9][0-9]*) columns:\z/.match(lines.shift.to_s)
      fail!("#{id} callback column count differs") unless header && header[1].to_i == 2
      sections = []
      until lines.empty?
        match = /\A(0|[1-9][0-9]*) substreams for column `([a-z][a-z0-9_]*)`:\z/.match(lines.shift)
        fail!("#{id} malformed callback section") unless match
        count = Integer(match[1], 10)
        fail!("#{id} callback count exceeds bound") unless count <= 512 && lines.size >= count
        names = count.times.map do
          entry = /\A\t([A-Za-z0-9_.%]+)\z/.match(lines.shift.to_s)
          fail!("#{id} malformed callback name") unless entry
          entry[1]
        end
        fail!("#{id} duplicate callback name") unless names.uniq.size == names.size
        sections << [match[2], names]
      end
      fail!("#{id} callback sections differ from schema") unless sections.map(&:first) == ['pk', COLUMN]
      roster = sections.flat_map { |column, names| names.map { |name| [column, name] } }
      pk_callbacks = sections.fetch(0).fetch(1)
      column_callbacks = sections.fetch(1).fetch(1)
      fail!("#{id} primary-key callbacks differ from the exact single-key roster") unless
        pk_callbacks == EXPECTED_PK_CALLBACK_NAMES
      fail!("#{id} whole-grid callback count differs from the depth-#{@depth} witness") unless
        roster.size == EXPECTED_WHOLE_GRID_CALLBACK_COUNTS.fetch(@depth)
      fail!("#{id} Object-column callback count differs from the depth-#{@depth} witness") unless
        column_callbacks.size == EXPECTED_OBJECT_COLUMN_CALLBACK_COUNTS.fetch(@depth)
      {
        sections: sections, roster: roster, text: text, sha256: Digest::SHA256.hexdigest(text),
        pk_callbacks: pk_callbacks, object_callback_count: column_callbacks.size,
        whole_grid_callback_count: roster.size,
      }
    end

    def capture_raw_files!(id, path, mark_format: 'mrk4')
      names = ["data.bin", "data.#{mark_format}", 'serialization.json', 'checksums.txt']
      names << 'columns_substreams.txt' if mark_format == 'mrk4'
      names.to_h do |name|
        source = File.join(path, name)
        fail!("#{id} required raw stock file is missing or symlinked: #{name}") unless File.file?(source) && !File.symlink?(source)
        bytes = File.binread(source)
        fail!("#{id} raw file exceeds per-file cap: #{name}") if bytes.bytesize > MAX_RAW_FILE_BYTES
        target = File.join(@root, 'raw-records', "#{id}.#{name}")
        write_new(target, bytes)
        [name, {path: target, size: bytes.bytesize, sha256: Digest::SHA256.hexdigest(bytes)}]
      end
    end

    def check!(id, table, store)
      begin_tag = marker('check_begin', id)
      end_tag = marker('check_end', id)
      sql = "SELECT '#{begin_tag}' FORMAT TSVRaw;\nCHECK TABLE default.#{table} FORMAT TSV;\nSELECT '#{end_tag}' FORMAT TSVRaw;\n"
      result = native("#{id}_check", store, sql)
      lines = native_lines(result, "#{id} CHECK")
      first = lines.index(begin_tag)
      last = lines.index(end_tag)
      body = first && last && last > first ? lines[(first + 1)...last] : nil
      fail!("#{id} CHECK was not exactly one healthy part: #{body.inspect}") unless body == ["#{PART_NAME}\t1\t"]
      {state: 'healthy', rows: body, invocation: result.fetch(:record)}
    end

    def stock_capture_lineage
      {
        frozen_stock_only_probe_sha256: STOCK_ONLY_SOURCE_SHA256,
        capture_scope: 'stock-only typed-source/target capture before generated-writer matrix additions',
        current_matrix_probe_source_sha256: @probe_hashes_after && @probe_hashes_after[File.realpath(PROBE_SOURCE)],
        distinction: 'the frozen stock-only source hash identifies the earlier stock captures; it is not the hash of this extended matrix probe',
      }
    end

    def copy_part(source, destination)
      fail!('part copy destination already exists') if File.exist?(destination) || File.symlink?(destination)
      FileUtils.cp_r(source, destination, preserve: true)
      fail!('copied part inventory differs from native stock') unless tree_inventory(source) == tree_inventory(destination)
      destination
    end

    def helper(label, *arguments, expected_statuses: ['ok'])
      argv = [@helper] + arguments
      result = @runner.send(:run_process, label, argv, ''.b, 'crystal-helper',
                            expected_sha: @helper_sha_before, binary_path: @helper)
      record = result.fetch(:record)
      fail!("#{label} helper had process infrastructure failure") unless
        !record[:timed_out] && record[:spawn_error].nil? && record[:stdin_write_error].nil? &&
        record[:stdout_read_error].nil? && record[:stderr_read_error].nil? && result[:status] &&
        result[:status].termsig.nil? && result[:status].success? && result[:stderr].empty?
      fail!("#{label} helper report exceeds bound") if result[:stdout].bytesize > MAX_REPORT_BYTES
      output = result[:stdout].dup.force_encoding(Encoding::UTF_8)
      fail!("#{label} helper output is not UTF-8") unless output.valid_encoding?
      report = JSON.parse(output)
      fail!("#{label} helper envelope differs") unless report.is_a?(Hash) &&
        report.fetch('format') == HELPER_FORMAT && report.fetch('action') == arguments.first &&
        expected_statuses.include?(report.fetch('status'))
      report
    rescue JSON::ParserError, KeyError => error
      fail!("#{label} helper output is invalid: #{error.class}: #{error.message}")
    end

    def expected_signatures(first_mark, mark_count)
      @rows.slice(first_mark * ROWS_PER_MARK, mark_count * ROWS_PER_MARK).map do |value|
        {'payload' => expected_payload_for(value)}
      end
    end

    def expected_reader_summary(first_mark, mark_count)
      literals = @rows.slice(first_mark * ROWS_PER_MARK, mark_count * ROWS_PER_MARK)
      { 'row_count' => literals.size, 'literals' => literals,
        'signatures' => expected_signatures(first_mark, mark_count) }
    end

    def local_windows!(id, part)
      PHYSICAL_WINDOWS.to_h do |window, (first, count)|
        report = helper("#{id}_local_#{window}", 'read-native', part, @depth.to_s, first.to_s, count.to_s,
                        expected_statuses: ['accepted'])
        expected = expected_reader_summary(first, count)
        expected_actuals = EXPECTED_ACTUAL_COUNTS.fetch(@depth).slice(first, count)
        expected_vectors = EXPECTED_SIZE_VECTORS.fetch(@depth).slice(first, count)
        expected_counts = EXPECTED_ELEMENT_COUNTS.fetch(@depth).map { |marks| marks.slice(first, count) }
        expected_leaves = EXPECTED_JSON_LEAF_COUNTS.fetch(@depth).slice(first, count)
        fail!("#{id} local #{window} recursive report differs") unless report.fetch('recursive') == expected
        fail!("#{id} local #{window} static report differs") unless report.fetch('static') == expected
        fail!("#{id} local #{window} parent-arm census differs") unless
          report.fetch('recursive_arm_counts_by_mark') == expected_actuals &&
          report.fetch('static_arm_counts_by_mark') == expected_actuals
        fail!("#{id} local #{window} per-parent size vectors differ") unless
          report.fetch('recursive_array_size_vectors_by_mark') == expected_vectors &&
          report.fetch('static_array_size_vectors_by_mark') == expected_vectors
        fail!("#{id} local #{window} per-level element counts differ") unless
          report.fetch('recursive_array_element_counts_by_level_and_mark') == expected_counts &&
          report.fetch('static_array_element_counts_by_level_and_mark') == expected_counts
        fail!("#{id} local #{window} JSON leaf counts differ") unless
          report.fetch('recursive_json_leaf_counts_by_mark') == expected_leaves &&
          report.fetch('static_json_leaf_counts_by_mark') == expected_leaves
        [window, {
          first_mark: first, mark_count: count, state: 'exact_values',
          row_count: expected.fetch('row_count'), recursive: report.fetch('recursive'),
          static: report.fetch('static'), actual_counts: expected_actuals,
          array_size_vectors_by_mark: expected_vectors,
          array_element_counts_by_level_and_mark: expected_counts,
          json_leaf_counts_by_mark: expected_leaves,
        }]
      end
    end

    def helper_write!(id, destination, mark_format, mode)
      report = helper("#{id}_writer", 'write-native', destination, @depth.to_s, mark_format, mode)
      actuals = EXPECTED_ACTUAL_COUNTS.fetch(@depth)
      leaves = EXPECTED_JSON_LEAF_COUNTS.fetch(@depth)
      expected = {
        'part_path' => destination, 'depth' => @depth, 'row_count' => ROW_COUNT,
        'mark_count' => MARK_COUNT, 'rows_per_mark' => ROWS_PER_MARK,
        'mark_format' => mark_format, 'discriminator_mode' => mode,
        'column' => COLUMN, 'declared_schema' => HELPER_DECLARATION,
        'dynamic_actual_type' => array_type,
        'expected_parent_dynamic_statistics' => [actuals.sum, 0],
        'child_json_path_types' => {'value' => 'Int64'},
        'expected_child_object_statistics' => [leaves.sum],
        'expected_child_dynamic_statistics' => [leaves.sum, 0],
        'expected_fixture_mark_actual_counts' => actuals,
        'expected_fixture_mark_array_size_vectors' => EXPECTED_SIZE_VECTORS.fetch(@depth),
        'expected_fixture_mark_array_element_counts_by_level' => EXPECTED_ELEMENT_COUNTS.fetch(@depth),
        'expected_fixture_mark_json_element_counts' => leaves,
        'literals' => @rows,
      }
      expected.each do |key, value|
        fail!("#{id} helper metadata #{key} differs: #{report[key].inspect}") unless report[key] == value
      end
      report
    end

    def create_target!(id, mode, mark_format)
      table = table_name("target_#{id}")
      store = store_path("target_#{id}")
      tag = marker('data_path', id)
      sql = "CREATE TABLE default.#{table} (pk UInt64, `#{COLUMN}` #{DECLARATION}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings(mode, mark_format: mark_format)};\n" \
        "SELECT '#{tag}', arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw;\n"
      result = native("#{id}_target_create", store, sql)
      paths = tagged(native_lines(result, "#{id} target path"), tag, 2, id)
      fail!("#{id} target data path is not unique") unless paths.size == 1 && !paths.first[1].empty?
      data_path = File.expand_path(paths.first[1])
      fail!("#{id} target data path escaped its store") unless data_path.start_with?(File.realpath(store) + File::SEPARATOR)
      fail!("#{id} target data path is not a canonical non-symlink directory") unless
        File.directory?(data_path) && !File.symlink?(data_path) && File.realpath(data_path) == data_path
      {table: table, store: store, data_path: data_path, create_invocation: result.fetch(:record)}
    end

    def attach_copy!(id, source, target)
      source_inventory = tree_inventory(source)
      @runner.send(:attach_part!, source, target.fetch(:data_path))
      detached = File.join(target.fetch(:data_path), 'detached', PART_NAME)
      detached_inventory = tree_inventory(detached)
      fail!("#{id} detached part differs from source") unless detached_inventory == source_inventory
      invocation = native("#{id}_attach", target.fetch(:store),
                          "ALTER TABLE default.#{target.fetch(:table)} ATTACH PART '#{PART_NAME}';\n")
      {state: 'success', invocation: invocation.fetch(:record), source_inventory: source_inventory,
       detached_inventory: detached_inventory}
    end

    def attached_inventory!(id, active_path, source_inventory)
      active_inventory = tree_inventory(active_path)
      source = source_inventory.fetch(:files).to_h { |entry| [entry.fetch(:path), entry] }
      active = active_inventory.fetch(:files).to_h { |entry| [entry.fetch(:path), entry] }
      fail!("#{id} ATTACH changed or removed source part files") unless source.all? { |name, entry| active[name] == entry }
      extras = active.keys - source.keys
      fail!("#{id} ATTACH added unexpected sidecars: #{extras.inspect}") unless extras == ['invalidated_system_columns.txt']
      sidecar = File.join(active_path, 'invalidated_system_columns.txt')
      bytes = File.binread(sidecar)
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      fail!("#{id} ATTACH sidecar differs") unless text.valid_encoding? && text.split("\n", -1) == ["_block_offset", "_block_number", '']
      {inventory: active_inventory, native_owned_sidecar: {path: 'invalidated_system_columns.txt', contents: text,
        size: bytes.bytesize, sha256: Digest::SHA256.hexdigest(bytes)}}
    end

    def capture_generated!(mark_format, mode, stock)
      id = "generated_#{mark_format}_#{mode}"
      part_path = File.join(@root, 'parts', id)
      write = helper_write!(id, part_path, mark_format, mode)
      source_inventory = tree_inventory(part_path)
      roster = if mark_format == 'mrk4'
                 parsed = callback_roster!(id, part_path)
                 fail!("#{id} callback roster differs from matching stock mode") unless
                   parsed.fetch(:roster) == stock.fetch(:callback_roster)
                 parsed
               else
                 path = File.join(part_path, 'columns_substreams.txt')
                 fail!("#{id} MRK3 unexpectedly has columns_substreams.txt") if File.exist?(path) || File.symlink?(path)
                 {sections: [], roster: [], sha256: nil}
               end
      raw_files = capture_raw_files!(id, part_path, mark_format: mark_format)
      local = local_windows!(id, part_path)
      target = create_target!(id, mode, mark_format)
      attach = attach_copy!(id, part_path, target)
      attached_part = inspect_part!("#{id}_attached", target.fetch(:table), target.fetch(:store), mark_format: mark_format)
      attached = attached_inventory!(id, attached_part.fetch(:path), source_inventory)
      check = check!(id, target.fetch(:table), target.fetch(:store))
      values = observe_target!(id, target.fetch(:table), store: target.fetch(:store))
      fail!("#{id} native generated values differ") unless values.fetch(:matches_expected_semantics)
      fail!("#{id} generated part changed while native consumers ran") unless tree_inventory(part_path) == source_inventory
      {
        mark_format: mark_format, discriminator_mode: mode, part_path: part_path,
        write_report: write, source_inventory: source_inventory, raw_files: raw_files,
        callback_sections: roster.fetch(:sections), callback_roster: roster.fetch(:roster),
        matching_stock_mrk4_roster_sha256: stock.fetch(:callback_roster_sha256),
        generated_mrk4_roster_sha256: roster.fetch(:sha256),
        local_physical_mark_reads: local, native_target: target, native_attach: attach,
        active_part: {path: attached_part.fetch(:path), **attached},
        native_check: check, native_literal_selects: values,
      }
    end

    def native_unaffected_window!(id, table, store)
      result = selected_rows_by_window(id, table, 'unaffected', store: store)
      fail!("#{id} unaffected SQL window did not read exact values") unless result.fetch(:state) == 'exact_values'
      result
    end

    def native_selected_dynamic_negative!(id, table, store)
      tag = marker('mutant_selected_dynamic', id)
      dynamic = "`#{COLUMN}`.payload"
      actual = "dynamicElement(#{dynamic}, #{sql_string(array_type)})"
      sql = "SELECT '#{tag}', toString(pk), if(isNull(#{dynamic}), 'None', dynamicType(#{dynamic})), " \
        "if(isNull(#{dynamic}), '#{BINARY_JSON_NULL}', hex(toJSONString(#{actual}))) " \
        "FROM default.#{table} WHERE pk=8 SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;\n"
      result = native("#{id}_selected_dynamic_query", store, sql, allow_server_error: true)
      fail!("#{id} corrupted Dynamic did not produce a ClickHouse server exception") unless result[:classification] == 'server_exception'
      record = result.fetch(:record)
      stderr = result.fetch(:stderr).dup.force_encoding(Encoding::UTF_8)
      fail!("#{id} Dynamic negative did not exit with ClickHouse error 117") unless record[:exit] == 117
      fail!("#{id} Dynamic negative lacked invalid-version diagnostic") unless
        stderr.valid_encoding? && stderr.include?('Code: 117') &&
        stderr.include?('Invalid version for Dynamic structure serialization: 5')
      {state: 'expected_invalid_dynamic_structure_version', exit: record[:exit],
       diagnostic: 'Invalid version for Dynamic structure serialization: 5', invocation: record}
    end

    def qualify_child_dynamic_version_mutant!(generated)
      id = 'resealed_child_dynamic_version_mrk4_basic'
      source = generated.fetch(:part_path)
      source_inventory = generated.fetch(:source_inventory)
      fail!("#{id} source part changed before copy") unless tree_inventory(source) == source_inventory
      destination = File.join(@root, 'parts', id)
      mutation = helper("#{id}_mutation", 'copy-child-dynamic-version-mutant', 'resealed', source,
                        destination, '3', @depth.to_s)
      expected_stream = nested_child_dynamic_structure_stream
      expected_mutation = {
        'source_path' => source, 'mutant_path' => destination,
        'column' => COLUMN, 'stream' => expected_stream, 'mark' => 3, 'depth' => @depth,
        'semantic_type' => 'Dynamic(Int64)', 'version_before' => 4, 'version_after' => 5,
        'raw_changed_offsets' => [mutation.fetch('logical_offset')],
        'compressed_size_after' => mutation.fetch('compressed_size_before'),
        'checksums_resealed' => true,
      }
      expected_mutation.each do |key, value|
        fail!("#{id} mutation metadata #{key} differs: #{mutation[key].inspect}") unless mutation[key] == value
      end
      fail!("#{id} source part changed during copy mutation") unless tree_inventory(source) == source_inventory
      mutant_inventory = tree_inventory(destination)
      original = source_inventory.fetch(:files).to_h { |entry| [entry.fetch(:path), entry] }
      mutant = mutant_inventory.fetch(:files).to_h { |entry| [entry.fetch(:path), entry] }
      changed = (original.keys | mutant.keys).select { |path| original[path] != mutant[path] }.sort
      fail!("#{id} changed files are not exactly data.bin/checksums.txt: #{changed.inspect}") unless
        changed == %w[checksums.txt data.bin]

      local_reject = helper("#{id}_local_reject", 'read-native', destination, @depth.to_s, '3', '1',
                            expected_statuses: ['rejected'])
      fail!("#{id} local reader did not reject as CorruptPartError") unless
        local_reject.fetch('error_class') == 'CrystalClick::CorruptPartError' &&
        local_reject.fetch('error_message').include?('version 5')
      local_unaffected = helper("#{id}_local_unaffected", 'read-native', destination, @depth.to_s, '0', '1',
                                expected_statuses: ['rejected'])
      local_preflight_diagnostic = 'Dynamic structure version 5 is outside the known part-version domain'
      fail!("#{id} local mark-0 request did not report the exact full-grid preflight rejection") unless
        local_unaffected.fetch('error_class') == 'CrystalClick::CorruptPartError' &&
        local_unaffected.fetch('error_message') == local_preflight_diagnostic

      target = create_target!(id, 'basic', 'mrk4')
      attach = attach_copy!(id, destination, target)
      active_part = inspect_part!("#{id}_attached", target.fetch(:table), target.fetch(:store), mark_format: 'mrk4')
      active = attached_inventory!(id, active_part.fetch(:path), mutant_inventory)
      check = check!(id, target.fetch(:table), target.fetch(:store))
      fail!("#{id} native CHECK was not healthy") unless check.fetch(:state) == 'healthy'
      unaffected = native_unaffected_window!(id, target.fetch(:table), target.fetch(:store))
      selected = native_selected_dynamic_negative!(id, target.fetch(:table), target.fetch(:store))
      fail!("#{id} source part changed during native checks") unless tree_inventory(source) == source_inventory
      {
        mutation: mutation, changed_relative_paths: changed, source_inventory_unchanged: true,
        mutant_inventory: mutant_inventory, local_reject: local_reject,
        local_unaffected_window: {
          state: 'whole_grid_preflight_rejected', request: {first_mark: 0, mark_count: 1},
          error_class: local_unaffected.fetch('error_class'), error_message: local_unaffected.fetch('error_message'),
          boundary: 'The read-native helper exits through recursive-reader delegated static full-grid preflight before a separate direct static bulk call. This is not a mark-isolated local comparison or an independent unaffected-window read.',
          report: local_unaffected,
        },
        native_target: target, native_attach: attach,
        active_part: {path: active_part.fetch(:path), **active}, native_check: check,
        native_unaffected_window: unaffected, selected_dynamic_window: selected,
        claim_boundary: 'copy-only same-extent checksum-resealed negative. The local mark-0 request is classified as whole_grid_preflight_rejected through the recursive-reader delegated static preparation path; it does not establish mark-isolated local behavior or a separate direct static bulk API result. Native CHECK and selected-window rejection are independent native observations; the native pk 1-2 unaffected query is asserted separately.',
      }
    end

    def full_matrix_summary(stock, generated, mutant)
      {
        format: FORMAT, status: 'stock_and_generated_array_chain_matrix_exact',
        execution_mode: 'stock_first_then_generated_writer_matrix',
        runtime_pin: {
          binary: @binary, sha256: @binary_sha_after, version: VERSION, build: BUILD,
          argv_policy: 'W241 bounded clickhouse-local runner; one thread; every invocation records argv/stdin/stdout/stderr/status',
        },
        source_pin: {
          root: @source_root, revision: SOURCE_REVISION, sha256: @upstream_hashes,
          distinction: 'upstream source pin is validated independently from the distinct runtime executable/build pin',
        },
        helper_pin: {path: @helper, sha256: @helper_sha_after},
        probe_sources: @probe_hashes_after,
        stock_capture_lineage: stock_capture_lineage,
        fixture: {
          column: COLUMN, declared_type: DECLARATION, actual_type: array_type,
          depth: @depth, native_leaf_path_types: {'value' => 'Int64'},
          rows_by_pk: @rows.each_with_index.map { |value, index| {pk: index + 1, value: value} },
          rows_per_mark: ROWS_PER_MARK, row_count: ROW_COUNT, data_marks: MARK_COUNT,
          expected_nonnull_actual_counts_per_mark: EXPECTED_ACTUAL_COUNTS.fetch(@depth),
          expected_array_size_vectors_by_mark_and_level: EXPECTED_SIZE_VECTORS.fetch(@depth),
          expected_array_element_counts_by_level_and_mark: EXPECTED_ELEMENT_COUNTS.fetch(@depth),
          expected_json_leaf_counts_per_mark: EXPECTED_JSON_LEAF_COUNTS.fetch(@depth),
          native_fixture_leaf_type: 'Int64', local_spec_fixture_leaf_type: 'UInt8',
          fixture_separation: 'native-shaped helper/source SQL evidence uses inferred Int64; frozen local spec fixture remains UInt8 and is not used as native type evidence',
        },
        stock: stock, generated: generated, child_dynamic_version_mutant: mutant,
        invocations: @invocations, evidence_root: @root,
        claim_boundary: 'Finite Array-chain depths two and three only: typed Dynamic actuals Array^depth(JSON) in a Compact root JSON Object, V3 MAP0/bucket1, both MRK3/MRK4 and BASIC/COMPACT. Stock native SQL is semantic evidence; generated positive windows are checked by local readers and pinned native ClickHouse. On the version-5 mutant, the local mark-0 read-native request is a whole-grid preflight rejection through the recursive-reader delegated static preparation path, not a mark-isolated unaffected read or a separate direct static bulk API result; the native pk 1-2 query remains a separate unaffected-window observation. This does not qualify arbitrary depth, standalone Dynamic, tuple/nullable wrappers, shared-data populated profiles, non-single-stream String, or compressed marks.',
      }
    end

    def capture_stock!(mode = 'basic', full_matrix: false)
      id = "stock_mrk4_#{mode}"
      table = table_name(id)
      store = store_path("native_#{id}")
      create = native("#{id}_create_insert", store, create_and_insert_sql(mode, id))
      source_observation = observe_source!(id, create)
      part = inspect_part!(id, table, store)
      inventory = tree_inventory(part.fetch(:path))
      roster = callback_roster!(id, part.fetch(:path))
      raw_files = capture_raw_files!(id, part.fetch(:path))
      copied_part = File.join(@root, 'parts', id)
      copy_part(part.fetch(:path), copied_part)
      check = check!(id, table, store)
      target_observation = observe_target!(id, table, store: store)
      if full_matrix
        fail!("#{id} typed Memory source column observation differs") unless
          source_observation.fetch(:matches_expected_semantics)
        fail!("#{id} native target observation differs") unless target_observation.fetch(:matches_expected_semantics)
      end
      local = local_windows!(id, copied_part) if full_matrix
      fail!('native stock part changed during capture') unless tree_inventory(part.fetch(:path)) == inventory
      {
        origin: 'fresh pinned ClickHouse stock Compact part', mark_format: 'mrk4', discriminator_mode: mode,
        table: table, store: store, native_part: part, part_inventory: inventory,
        callback_sections: roster.fetch(:sections), callback_roster: roster.fetch(:roster),
        callback_count: roster.fetch(:object_callback_count), callback_count_scope: 'Object column',
        whole_grid_callback_count: roster.fetch(:whole_grid_callback_count),
        pk_callback_names: roster.fetch(:pk_callbacks),
        callback_roster_sha256: roster.fetch(:sha256),
        raw_files: raw_files, copied_part_path: copied_part,
        create_insert: create.fetch(:record), source_observation: source_observation,
        check: check, observation: target_observation, local_physical_mark_reads: local,
      }
    end

    def render_summary(summary)
      unless @stock_only
        stock_rows = summary.fetch(:stock).map do |mode, entry|
          observation = entry.fetch(:observation)
          "- Stock MRK4 #{mode}: native windows exact; callbacks Object=#{entry.fetch(:callback_count)} / whole-grid=#{entry.fetch(:whole_grid_callback_count)}; local recursive/static windows exact."
        end
        generated_rows = summary.fetch(:generated).map do |name, _entry|
          "- Generated #{name}: attached/check healthy; native and local recursive/static windows exact."
        end
        return [
          '# W273 Compact Array-chain writer probe', '',
          "Status: `#{summary.fetch(:status)}`",
          "Depth: `#{@depth}`; native actual: `#{@array_type}`; target column: `#{COLUMN}`.",
          "Runtime: `#{VERSION}` build `#{BUILD}` SHA `#{BINARY_SHA256}`.",
          "Source: `#{SOURCE_REVISION}` at `#{SOURCE_ROOT}` (separate from runtime pin).",
          "Expected parent actual counts: `#{EXPECTED_ACTUAL_COUNTS.fetch(@depth).inspect}`; per-level Array element counts: `#{EXPECTED_ELEMENT_COUNTS.fetch(@depth).inspect}`; JSON leaf counts: `#{EXPECTED_JSON_LEAF_COUNTS.fetch(@depth).inspect}`.",
          'Native-shaped SQL/helper leaves are inferred Int64; the independent local spec fixture remains UInt8. The helper and native stock observations are pinned separately.',
          '', *stock_rows, *generated_rows,
          '- The copied MRK4 BASIC nested JSON child Dynamic version-5 negative is checksum-resealed at one raw byte with unchanged compressed extent; native CHECK stays healthy and the selected row query rejects with ClickHouse error 117. The local mark-0 request is reported as a whole-grid preflight rejection, not an unaffected-granule read; the native pk 1-2 window is asserted separately.',
          '', summary.fetch(:claim_boundary), '',
        ].join("\n")
      end
      stock = summary.fetch(:stock)
      observed = stock.fetch(:observation)
      [
        '# W273 Compact Array-chain stock-only probe', '',
        "Status: `#{summary.fetch(:status)}`",
        "Depth: `#{@depth}`; native actual: `#{@array_type}`; target column: `#{COLUMN}`.",
        "Runtime: `#{VERSION}` build `#{BUILD}` SHA `#{BINARY_SHA256}`.",
        "Source: `#{SOURCE_REVISION}` at `#{SOURCE_ROOT}` (separately source-pinned).",
        'Eight ordered rows form four two-row marks. NULL rows are omitted from the typed Memory source and inserted as explicit NULL casts; `[]`, `[[]]`, and (at depth three) `[[[]]]` are selected non-NULL actuals.',
        "Observed actual counts per mark: `#{observed.fetch(:actual_counts_per_mark).inspect}`.",
        "Observed Array size vectors by mark and level: `#{observed.fetch(:array_size_vectors_by_mark_and_level).inspect}`.",
        "Observed element counts by Array level and mark: `#{observed.fetch(:array_element_counts_by_level_and_mark).inspect}`.",
        "Observed JSON leaf counts per mark: `#{observed.fetch(:json_leaf_counts_per_mark).inspect}`.",
        "Typed source match: `#{stock.fetch(:source_observation).fetch(:matches_expected_semantics)}`; target semantic match: `#{observed.fetch(:matches_expected_semantics)}`.",
        'The report captures each native process record, part inventory, raw data/mark/serialization/checksum/callback-roster files, and both source and target value/type observations.',
        '', summary.fetch(:claim_boundary), '',
      ].join("\n")
    end

    def persist_inconclusive(error)
      return unless @root && File.directory?(File.join(@root, 'invocations'))
      report = {
        format: FORMAT, status: 'inconclusive', fatal_error: @fatal_error, error_class: error.class.name,
        depth: @depth, runtime_pin: {binary: @binary, expected_sha256: BINARY_SHA256, observed_sha256: (sha(@binary) rescue nil)},
        source_pin: {root: @source_root, expected_revision: SOURCE_REVISION},
        invocations: @invocations, evidence_root: @root,
        claim_boundary: 'A native process failure, SQL rejection, malformed capture, or observation mismatch is not converted into a writer compatibility conclusion.',
      }
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(report) + "\n") unless File.exist?(File.join(@root, 'summary.json'))
    rescue StandardError
      nil
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  options = {
    binary: ProbeCompactPartWriterW273::BINARY,
    source_root: ProbeCompactPartWriterW273::SOURCE_ROOT,
    depth: nil,
    evidence_root: nil,
    stock_only: false,
    full_matrix: false,
    helper: nil,
    helper_sha256: nil,
  }
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/probe_compact_part_writer_w273.rb (--stock-only | --full-matrix --helper PREBUILT --helper-sha256 SHA256) --depth 2|3 --evidence-root EMPTY_DIR [--binary PINNED_CLICKHOUSE] [--source-root PINNED_UPSTREAM]'
    parser.on('--stock-only', 'Capture the stock typed-source and native Compact target only; never invokes a Crystal helper') { options[:stock_only] = true }
    parser.on('--full-matrix', 'Run both stock modes, all four generated profiles, native/local windows, and the resealed negative') { options[:full_matrix] = true }
    parser.on('--helper PATH', 'Prebuilt W273 Crystal helper executable; required only for --full-matrix') { |value| options[:helper] = value }
    parser.on('--helper-sha256 SHA256', 'Exact lowercase SHA-256 for the prebuilt helper') { |value| options[:helper_sha256] = value }
    parser.on('--depth N', Integer, 'Bounded Array-chain witness depth (2 or 3)') { |value| options[:depth] = value }
    parser.on('--evidence-root EMPTY_DIR', 'Existing empty direct child directory of /private/tmp') { |value| options[:evidence_root] = value }
    parser.on('--binary PATH', 'Pinned ClickHouse runtime executable') { |value| options[:binary] = value }
    parser.on('--source-root PATH', 'Separately pinned upstream ClickHouse source checkout') { |value| options[:source_root] = value }
  end.parse!

  unless options[:stock_only] != options[:full_matrix] && !options[:depth].nil? && !options[:evidence_root].nil?
    warn 'W273: select exactly one of --stock-only or --full-matrix; both require --depth and --evidence-root'
    exit 2
  end
  if options[:stock_only] && (options[:helper] || options[:helper_sha256])
    warn 'W273: --helper and --helper-sha256 are only valid with --full-matrix'
    exit 2
  end
  if options[:full_matrix] && (!options[:helper] || !options[:helper_sha256])
    warn 'W273: --full-matrix requires --helper and --helper-sha256'
    exit 2
  end
  success = ProbeCompactPartWriterW273::Probe.new(**options).run
  exit(success ? 0 : 1)
end
