#!/usr/bin/env ruby
# Stock-only discriminator for Array(JSON) as an actual arm of a typed Dynamic
# value inside a Compact root JSON column. Cast intent is recorded as a
# hypothesis; native SQL observations remain the semantic evidence.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'optparse'
require_relative 'probe_compact_part_writer_w271'

module ProbeCompactPartWriterW272
  W271 = ProbeCompactPartWriterW271
  W241 = W271::W241

  FORMAT = 'compact_part_writer_w272_native_probe_v1'.freeze
  HELPER_FORMAT = 'compact_part_writer_w272_helper_v1'.freeze
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
  HELPER_SOURCE = File.expand_path('compact_part_writer_w272_helper.cr', __dir__).freeze
  NATIVE_FIXTURE_SOURCE = File.expand_path('support/compact_part_writer_w272_native_fixture.cr', __dir__).freeze
  LOCAL_FIXTURE_SOURCE = File.expand_path('../spec/support/compact_part_writer_w272_fixture.cr', __dir__).freeze

  COLUMN = 'typed_dynamic_array_json'.freeze
  SOURCE_COLUMN = 'typed_array_json_source'.freeze
  ARRAY_JSON_DECLARATION = 'JSON(max_dynamic_paths=0,max_dynamic_types=0,payload Array(JSON))'.freeze
  DECLARATION = 'JSON(max_dynamic_types=1,max_dynamic_paths=0,payload Dynamic(max_types=1))'.freeze
  HELPER_DECLARATION = 'JSON(max_dynamic_types=1, max_dynamic_paths=0, payload Dynamic(max_types=1))'.freeze
  ROWS = [[11, 12], nil, nil, nil, [], [61], nil, [81, 82, 83]].map(&:freeze).freeze
  KEYS = (1..8).to_a.freeze
  ROWS_PER_MARK = 2
  MARK_COUNT = 4
  EXPECTED_SELECTED_ARMS_PER_MARK = [1, 0, 2, 1].freeze
  EXPECTED_ORDINARY_ARRAY_JSON_ARM_COUNTS_PER_MARK = [1, 0, 2, 1].freeze
  EXPECTED_CHILD_JSON_ELEMENTS_PER_MARK = [2, 0, 1, 3].freeze
  MODES = %w[basic compact].freeze
  SQL_WINDOWS = {
    'full' => nil,
    'middle' => 'pk BETWEEN 3 AND 6',
    'zero_arm' => 'pk BETWEEN 3 AND 4',
    'selected_empty' => 'pk = 5',
    'last' => 'pk BETWEEN 7 AND 8',
    'empty' => 'pk > 8',
  }.freeze
  PHYSICAL_WINDOWS = {
    'full' => [0, 4].freeze,
    'middle' => [1, 2].freeze,
    'zero_arm' => [1, 1].freeze,
    'selected_empty' => [2, 1].freeze,
    'last' => [3, 1].freeze,
    'empty' => [4, 0].freeze,
  }.freeze
  MAX_PART_FILES = 160
  MAX_PART_BYTES = 64 * 1024 * 1024
  MAX_RAW_FILE_BYTES = 16 * 1024 * 1024
  MAX_REPORT_BYTES = 2 * 1024 * 1024

  class Failure < StandardError; end

  class Probe
    def initialize(binary:, source_root:, evidence_root:, stock_only:, full_matrix:, constructor:, helper:, helper_sha256:)
      @binary = validate_executable(binary, 'pinned ClickHouse')
      @source_root = File.expand_path(source_root)
      @stock_only = stock_only
      @full_matrix = full_matrix
      @constructor = constructor
      fail!('select exactly one of --stock-only or --full-matrix') unless @stock_only != @full_matrix
      fail!("unsupported constructor #{@constructor.inspect}") unless %w[tuple_dynamic typed_object column_object].include?(@constructor)
      fail!('full matrix requires the qualified column_object constructor') if @full_matrix && @constructor != 'column_object'
      fail!('source root differs from the pinned upstream checkout') unless @source_root == SOURCE_ROOT
      @helper = nil
      @helper_expected_sha = nil
      if @full_matrix
        @helper = validate_executable(helper, 'prebuilt W272 helper')
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
      validate_fixture_literals!
    end

    def run
      prepare!
      if @stock_only
        stock = capture_stock!('basic', mark_format: 'mrk4')
        validate_pins!
        semantic_match = stock.fetch(:observation).fetch(:matches_expected_semantics)
        status = semantic_match ? 'stock_array_json_observed' : 'stock_observation_differs'
        summary = {
        format: FORMAT,
        status: status,
        execution_mode: 'stock_only_no_crystal_helper_or_generated_writer',
        runtime_pin: {
          binary: @binary, sha256: @binary_sha_after, version: VERSION, build: BUILD,
          argv_policy: 'W241 clickhouse-local runner; one thread; bounded memory and timeout; each process has a recorded argv/stdin/stdout/stderr/status quartet',
        },
        source_pin: {
          root: @source_root, revision: SOURCE_REVISION, sha256: @upstream_hashes,
          distinction: 'upstream source pin is validated separately from the runtime executable/build pin',
        },
        probe_sources: @probe_hashes_after,
        fixture_hypothesis: {
          outer_column: COLUMN, declared_type: DECLARATION,
          values_by_pk: ROWS.each_with_index.map { |value, index| {pk: index + 1, array_values: value} },
          rows_per_mark: ROWS_PER_MARK, row_count: ROWS.size, selected_mark_count: MARK_COUNT,
          expected_nonnull_dynamic_actual_counts_per_mark: EXPECTED_SELECTED_ARMS_PER_MARK,
          expected_ordinary_array_json_arm_counts_per_mark: EXPECTED_ORDINARY_ARRAY_JSON_ARM_COUNTS_PER_MARK,
          expected_child_json_element_counts_per_mark: EXPECTED_CHILD_JSON_ELEMENTS_PER_MARK,
          proposed_actual_arm: 'ordinary Array(JSON)',
          proposed_child_path_types: {'value' => 'Int64'},
          constructor: @constructor,
          constructor_description: constructor_description,
          status_boundary: 'constructor casts are intent only; actual dynamicType, shared-data flag, payload, array length, and per-element JSON path types below are captured from native SQL',
        },
        stock: stock,
        invocations: @invocations,
        evidence_root: @root,
        claim_boundary: 'This stock-only capture tests the SQL constructor and native observations on one pinned BASIC/MRK4 Compact part. It does not qualify a Crystal writer, compatibility with other profiles, or the source-code behavior of a different runtime build.',
        }
      else
        stock = {}
        MODES.each { |mode| stock[mode] = capture_stock!(mode, mark_format: 'mrk4', full_matrix: true) }
        generated = {}
        %w[mrk3 mrk4].product(MODES).each do |mark_format, mode|
          generated["#{mark_format}_#{mode}"] = capture_generated!(mark_format, mode, stock.fetch(mode))
        end
        mutant = qualify_child_dynamic_version_mutant!(generated.fetch('mrk4_basic'))
        validate_pins!
        summary = full_matrix_summary(stock, generated, mutant)
      end
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      write_new(File.join(@root, 'summary.md'), render_summary(summary))
      puts "W272 status=#{summary.fetch(:status)}; stock=#{@stock_only ? 1 : stock.size}; generated=#{@stock_only ? 0 : generated.size}; evidence=#{@root}"
      @stock_only ? semantic_match : true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      persist_inconclusive(error)
      warn "W272 probe inconclusive: #{@fatal_error}"
      false
    end

    private

    def fail!(message)
      raise Failure, "W272: #{message}"
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

    def validate_fixture_literals!
      fail!('fixture must contain exactly eight ordered rows') unless ROWS.size == 8 && KEYS == (1..8).to_a
      fail!('fixture selected-arm census differs') unless
        ROWS.each_slice(ROWS_PER_MARK).map { |mark| mark.count { |value| !value.nil? } } == EXPECTED_SELECTED_ARMS_PER_MARK
      fail!('fixture ordinary Array(JSON) census differs') unless EXPECTED_ORDINARY_ARRAY_JSON_ARM_COUNTS_PER_MARK == EXPECTED_SELECTED_ARMS_PER_MARK
      fail!('fixture child-element census differs') unless
        ROWS.each_slice(ROWS_PER_MARK).map { |mark| mark.compact.sum(&:size) } == EXPECTED_CHILD_JSON_ELEMENTS_PER_MARK
      fail!('fixture must distinguish null from a selected empty array') unless ROWS[3].nil? && ROWS[4] == []
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
      @probe_sources = [File.realpath(__FILE__), W271_SOURCE, W241_SOURCE]
      if @full_matrix
        @probe_sources.concat([HELPER_SOURCE, NATIVE_FIXTURE_SOURCE, LOCAL_FIXTURE_SOURCE])
      end
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
      fail!('a probe/runner/source fixture changed during capture') unless @probe_hashes_after == @probe_hashes_before
      if @full_matrix
        @helper_sha_after = sha(@helper)
        fail!('prebuilt helper changed during the probe') unless @helper_sha_after == @helper_sha_before
      end
    end

    def sha(path)
      Digest::SHA256.file(path).hexdigest
    end

    def write_new(path, bytes)
      fail!('evidence record exceeds the output cap') if bytes.bytesize > MAX_REPORT_BYTES
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

    def marker(kind, id, suffix = nil)
      value = "__W272_#{kind.upcase}_#{id.upcase}"
      value += "_#{suffix.upcase}" if suffix
      "#{value}__"
    end

    def sql_string(value)
      "'#{value.to_s.gsub(/[\\']/) { |character| "\\#{character}" }}'"
    end

    def settings(mode = 'basic', mark_format: 'mrk4')
      fail!("unsupported discriminator mode #{mode.inspect}") unless MODES.include?(mode)
      fail!("unsupported mark format #{mark_format.inspect}") unless %w[mrk3 mrk4].include?(mark_format)
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

    def source_actual(array_values)
      return "CAST('{\"payload\":null}', #{sql_string(DECLARATION)})" if array_values.nil?
      if @constructor == 'typed_object'
        typed_object_text = JSON.generate({'payload' => array_values.map { |value| {'value' => value} }})
        typed_object = "CAST(#{sql_string(typed_object_text)}, #{sql_string(ARRAY_JSON_DECLARATION)})"
        return "CAST(#{typed_object}, #{sql_string(DECLARATION)})"
      end

      elements = array_values.map do |value|
        json = JSON.generate({'value' => value})
        "CAST(#{sql_string(json)}, 'JSON')"
      end
      array = "CAST([#{elements.join(', ')}], 'Array(JSON)')"
      dynamic = "CAST(#{array}, 'Dynamic(max_types=1)')"
      tuple = "CAST(tuple(#{dynamic}), 'Tuple(payload Dynamic(max_types=1))')"
      "CAST(#{tuple}, #{sql_string(DECLARATION)})"
    end

    def constructor_description
      if @constructor == 'typed_object'
        "For non-NULL rows, CAST the full JSON object as #{ARRAY_JSON_DECLARATION}, then CAST that typed Object as #{DECLARATION}; explicit NULL rows are directly CAST to the outer declaration so NULL is not coerced into non-nullable Array(JSON)."
      elsif @constructor == 'column_object'
        "Insert the four non-NULL JSON literals into a Memory table whose source column is declared #{ARRAY_JSON_DECLARATION}; SELECT and record its typed payloads before conversion, then INSERT SELECT CAST(source_column, #{sql_string(DECLARATION)}) into the target, UNION ALL the four explicit NULL rows."
      else
        'CAST each JSON object, form an explicitly cast Array(JSON), cast to Dynamic(max_types=1), place in the declared Tuple field, then cast to the outer JSON declaration; explicit NULL rows are directly cast to the outer declaration.'
      end
    end

    def table_name(id)
      "w272_#{@token}_#{id}"
    end

    def source_table_name(id)
      "#{table_name(id)}_typed_source"
    end

    def source_document(array_values)
      JSON.generate({'payload' => array_values.map { |value| {'value' => value} }})
    end

    def source_table_sql(id)
      source = source_table_name(id)
      rows = ROWS.each_with_index.map do |array_values, index|
        next if array_values.nil?
        "SELECT toUInt64(#{index + 1}) AS pk, CAST(#{sql_string(source_document(array_values))}, #{sql_string(ARRAY_JSON_DECLARATION)}) AS #{SOURCE_COLUMN}"
      end.compact
      "CREATE TABLE default.#{source} (pk UInt64, `#{SOURCE_COLUMN}` #{ARRAY_JSON_DECLARATION}) ENGINE=Memory;\n" \
        "INSERT INTO default.#{source}\n#{rows.join("\nUNION ALL\n")};\n"
    end

    def source_values_sql(id)
      tag = marker('source_values', id)
      source = "`#{SOURCE_COLUMN}`.payload"
      child_types = "arrayMap(element -> JSONAllPathsWithTypes(element), #{source})"
      "SELECT '#{tag}', toString(pk), toTypeName(#{source}), hex(toJSONString(#{source})), " \
        "toString(length(#{source})), hex(toJSONString(#{child_types})) " \
        "FROM default.#{source_table_name(id)} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;\n"
    end

    def target_column_object_insert_sql(table, id)
      source_rows = "SELECT pk, CAST(`#{SOURCE_COLUMN}`, #{sql_string(DECLARATION)}) AS `#{COLUMN}` FROM default.#{source_table_name(id)}"
      null_rows = ROWS.each_with_index.map do |array_values, index|
        next unless array_values.nil?
        "SELECT toUInt64(#{index + 1}) AS pk, CAST('{\"payload\":null}', #{sql_string(DECLARATION)}) AS `#{COLUMN}`"
      end.compact
      "INSERT INTO default.#{table}\n#{([source_rows] + null_rows).join("\nUNION ALL\n")};\n"
    end

    def stock_sql(mode, table, id)
      if @constructor == 'column_object'
        return "SET flatten_nested=0;\n" \
          "#{source_table_sql(id)}" \
          "#{source_values_sql(id)}" \
          "CREATE TABLE default.#{table} (pk UInt64, `#{COLUMN}` #{DECLARATION}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings(mode, mark_format: 'mrk4')};\n" \
          "#{target_column_object_insert_sql(table, id)}"
      end
      inserts = ROWS.each_with_index.map do |array_values, index|
        "SELECT toUInt64(#{index + 1}) AS pk, #{source_actual(array_values)} AS #{COLUMN}"
      end
      "SET flatten_nested=0;\n" \
        "CREATE TABLE default.#{table} (pk UInt64, `#{COLUMN}` #{DECLARATION}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings(mode, mark_format: 'mrk4')};\n" \
        "INSERT INTO default.#{table}\n#{inserts.join("\nUNION ALL\n")};\n"
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

    def native_part!(id, table, store, mark_format: 'mrk4')
      schema_tag = marker('schema', id)
      part_tag = marker('part', id)
      sql = "SELECT '#{schema_tag}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;\n" \
        "SELECT '#{part_tag}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts " \
        "WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;\n"
      result = native("#{id}_schema_part", store, sql)
      lines = native_lines(result, "#{id} schema and part")
      schema = tagged(lines, schema_tag, 3, id).map { |row| row.drop(1) }
      canonical_schema = schema.map { |name, type| [name, type.gsub(/\s+/, '')] }
      expected_schema = [['pk', 'UInt64'], [COLUMN, DECLARATION]].map { |name, type| [name, type.gsub(/\s+/, '')] }
      fail!("#{id} declared schema differs: #{canonical_schema.inspect}") unless canonical_schema == expected_schema
      parts = tagged(lines, part_tag, 7, id)
      fail!("#{id} is not exactly one Compact part with eight rows/four data marks") unless parts.size == 1 &&
        parts.first.values_at(1, 2, 4, 5, 6) == [table, PART_NAME, 'Compact', '8', '5']
      path = safe_native_path(parts.first.fetch(3), store, id)
      selected_marks = File.join(path, "data.#{mark_format}")
      other_marks = File.join(path, mark_format == 'mrk4' ? 'data.mrk3' : 'data.mrk4')
      fail!("#{id} selected mark format differs") unless File.file?(selected_marks) && !File.exist?(other_marks)
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

    def copy_part(source, destination)
      fail!('part copy destination already exists') if File.exist?(destination) || File.symlink?(destination)
      FileUtils.cp_r(source, destination, preserve: true)
      fail!('copied stock part differs from its source inventory') unless tree_inventory(source) == tree_inventory(destination)
      destination
    end

    def parse_roster!(id, part)
      path = File.join(part, 'columns_substreams.txt')
      fail!("#{id} MRK4 callback roster is absent or symlinked") unless File.file?(path) && !File.symlink?(path)
      text = File.binread(path).force_encoding(Encoding::UTF_8)
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
        fail!("#{id} callback count exceeds bound") unless count <= 256 && lines.size >= count
        streams = count.times.map do
          entry = /\A\t([A-Za-z0-9_.%]+)\z/.match(lines.shift.to_s)
          fail!("#{id} malformed physical callback name") unless entry
          entry[1]
        end
        fail!("#{id} duplicate callback name") unless streams.uniq.size == streams.size
        sections << [match[2], streams]
      end
      fail!("#{id} callback sections differ from the literal schema") unless sections.map(&:first) == ['pk', COLUMN]
      fail!("#{id} a column has no physical callback") unless sections.all? { |section| !section[1].empty? }
      {text: text, sections: sections, roster: sections.flat_map { |column, streams| streams.map { |stream| [column, stream] } },
       sha256: Digest::SHA256.hexdigest(text)}
    end

    def capture_raw_files!(id, part)
      names = %w[data.bin data.mrk4 serialization.json checksums.txt columns_substreams.txt]
      names.to_h do |name|
        source = File.join(part, name)
        fail!("#{id} required stock file is absent or symlinked: #{name}") unless File.file?(source) && !File.symlink?(source)
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

    def native_pk_control!(id, table, store)
      tag = marker('mutant_pk_control', id)
      sql = "SELECT '#{tag}', toString(pk) FROM default.#{table} WHERE pk BETWEEN 5 AND 6 ORDER BY pk FORMAT TSVRaw;\n"
      result = native("#{id}_pk_control", store, sql)
      rows = tagged(native_lines(result, "#{id} pk control"), tag, 2, id)
      expected = [[tag, '5'], [tag, '6']]
      fail!("#{id} unaffected primary-key control differs: #{rows.inspect}") unless rows == expected
      {state: 'exact_values', rows: rows, invocation: result.fetch(:record)}
    end

    def native_selected_child_json!(id, table, store)
      tag = marker('mutant_child_array_json', id)
      dynamic = "`#{COLUMN}`.payload"
      actual = "dynamicElement(#{dynamic}, 'Array(JSON)')"
      child_types = "arrayMap(element -> JSONAllPathsWithTypes(element), #{actual})"
      sql = "SELECT '#{tag}', toString(pk), if(isNull(#{dynamic}), 'None', dynamicType(#{dynamic})), " \
        "if(isNull(#{dynamic}), 'false', if(isDynamicElementInSharedData(#{dynamic}), 'true', 'false')), " \
        "if(isNull(#{dynamic}), '6E756C6C', hex(toJSONString(#{actual}))), " \
        "if(isNull(#{dynamic}), '6E756C6C', hex(toJSONString(#{child_types}))) " \
        "FROM default.#{table} WHERE pk=6 SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;\n"
      result = native("#{id}_selected_child_array_json", store, sql, allow_server_error: true)
      fail!("#{id} corrupted child Dynamic was not a native server exception") unless result[:classification] == 'server_exception'
      record = result.fetch(:record)
      fail!("#{id} child Dynamic negative did not exit with ClickHouse error 117") unless record[:exit] == 117
      stderr = result.fetch(:stderr).dup.force_encoding(Encoding::UTF_8)
      fail!("#{id} child Dynamic negative lacked the exact invalid-version diagnostic") unless
        stderr.valid_encoding? && stderr.include?('Code: 117') &&
        stderr.include?('Invalid version for Dynamic structure serialization: 5')
      {state: 'expected_invalid_dynamic_structure_version', exit: record[:exit],
       diagnostic: 'Invalid version for Dynamic structure serialization: 5', invocation: record}
    end

    def decode_hex_json(value, label)
      fail!("#{label} malformed JSON hex") unless value.match?(/\A(?:[0-9a-f]{2})*\z/i)
      JSON.parse([value].pack('H*'))
    rescue JSON::ParserError => error
      fail!("#{label} invalid JSON payload: #{error.message}")
    end

    def value_select_sql(id, table)
      tag = marker('values', id)
      dynamic = "`#{COLUMN}`.payload"
      actual = "dynamicElement(#{dynamic}, 'Array(JSON)')"
      child_types = "arrayMap(element -> JSONAllPathsWithTypes(element), #{actual})"
      "SELECT '#{tag}', toString(pk), if(isNull(#{dynamic}), 'None', dynamicType(#{dynamic})), " \
        "if(isNull(#{dynamic}), 'false', if(isDynamicElementInSharedData(#{dynamic}), 'true', 'false')), " \
        "if(isNull(#{dynamic}), '6E756C6C', hex(toJSONString(#{actual}))), " \
        "if(isNull(#{dynamic}), '-', toString(length(#{actual}))), " \
        "if(isNull(#{dynamic}), '6E756C6C', hex(toJSONString(#{child_types}))) " \
        "FROM default.#{table} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;\n"
    end

    def array_json_type?(type)
      type.delete(' ') == 'Array(JSON)'
    end

    def observe_source_values!(id, create_result)
      lines = native_lines(create_result, "#{id} source-column SELECT")
      rows = tagged(lines, marker('source_values', id), 6, id)
      expected = ROWS.each_with_index.map do |array_values, index|
        next if array_values.nil?
        {pk: index + 1, values: array_values}
      end.compact
      fail!("#{id} typed source must contain exactly the four non-NULL fixture rows") unless rows.size == expected.size
      actual = rows.map do |fields|
        payload = decode_hex_json(fields[3], "#{id}/source/pk#{fields[1]}/payload")
        child_types = decode_hex_json(fields[5], "#{id}/source/pk#{fields[1]}/child types")
        {
          pk: Integer(fields[1], 10), declared_child_type: fields[2], payload: payload,
          array_length: Integer(fields[4], 10), child_json_path_types: child_types,
        }
      end
      exact = actual.each_with_index.all? do |row, index|
        expected_row = expected.fetch(index)
        row.fetch(:pk) == expected_row.fetch(:pk) && array_json_type?(row.fetch(:declared_child_type)) &&
          row.fetch(:payload) == expected_row.fetch(:values).map { |value| {'value' => value} } &&
          row.fetch(:array_length) == expected_row.fetch(:values).size &&
          row.fetch(:child_json_path_types) == expected_row.fetch(:values).map { {'value' => 'Int64'} }
      end
      fail!("#{id} typed source table observation differs: #{actual.inspect}") unless exact
      {
        state: 'typed_array_json_source_observed_before_target_conversion', table: source_table_name(id),
        engine: 'Memory', column: SOURCE_COLUMN, declared_type: ARRAY_JSON_DECLARATION,
        selected_row_count: actual.size, rows: actual,
      }
    end

    def expected_array_rows(window)
      selected = case window
                 when 'full' then KEYS
                 when 'middle' then (3..6).to_a
                 when 'zero_arm' then (3..4).to_a
                 when 'selected_empty' then [5]
                 when 'last' then (7..8).to_a
                 else []
                 end
      selected.map do |pk|
        values = ROWS.fetch(pk - 1)
        if values.nil?
          [pk.to_s, 'None', 'false', nil, nil, nil]
        else
          payload = values.map { |value| {'value' => value} }
          types = values.map { {'value' => 'Int64'} }
          [pk.to_s, 'Array(JSON)', 'false', payload, values.size, types]
        end
      end
    end

    def array_value_window_sql(id, table, window)
      tag = marker('values', id, window)
      predicate = SQL_WINDOWS.fetch(window)
      if window == 'empty'
        return "SELECT '#{tag}', toString(count()) FROM default.#{table} WHERE #{predicate} FORMAT TSVRaw;\n"
      end
      dynamic = "`#{COLUMN}`.payload"
      actual = "dynamicElement(#{dynamic}, 'Array(JSON)')"
      child_types = "arrayMap(element -> JSONAllPathsWithTypes(element), #{actual})"
      where = predicate ? " WHERE #{predicate}" : ''
      "SELECT '#{tag}', toString(pk), if(isNull(#{dynamic}), 'None', dynamicType(#{dynamic})), " \
        "if(isNull(#{dynamic}), 'false', if(isDynamicElementInSharedData(#{dynamic}), 'true', 'false')), " \
        "if(isNull(#{dynamic}), '6E756C6C', hex(toJSONString(#{actual}))), " \
        "if(isNull(#{dynamic}), '-', toString(length(#{actual}))), " \
        "if(isNull(#{dynamic}), '6E756C6C', hex(toJSONString(#{child_types}))) " \
        "FROM default.#{table}#{where} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;\n"
    end

    def native_values!(id, table, store)
      SQL_WINDOWS.to_h do |window, _predicate|
        invocation = native("#{id}_select_#{window}", store, array_value_window_sql(id, table, window))
        lines = native_lines(invocation, "#{id} #{window} Array(JSON) SELECT")
        tag = marker('values', id, window)
        if window == 'empty'
          rows = tagged(lines, tag, 2, id)
          exact = rows == [[tag, '0']]
          fail!("#{id} empty SQL window differs") unless exact
          [window, {state: 'exact_values', row_count: 0, rows: [], invocation: invocation.fetch(:record)}]
        else
          rows = tagged(lines, tag, 7, id)
          actual = rows.map do |fields|
            fail!("#{id}/#{window} shared-data flag is not boolean") unless %w[true false].include?(fields[3])
            payload = fields[4] == '6E756C6C' ? nil : decode_hex_json(fields[4], "#{id}/#{window}/payload")
            child_types = fields[6] == '6E756C6C' ? nil : decode_hex_json(fields[6], "#{id}/#{window}/child types")
            length = fields[5] == '-' ? nil : Integer(fields[5], 10)
            [fields[1], fields[2], fields[3], payload, length, child_types]
          end
          expected = expected_array_rows(window)
          fail!("#{id} #{window} native Array(JSON) literal/type/shared/length/path rows differ: #{actual.inspect}") unless actual == expected
          [window, {state: 'exact_values', row_count: rows.size, rows: actual, invocation: invocation.fetch(:record)}]
        end
      end
    end

    def observe_values!(id, table, store)
      result = native("#{id}_select_all_rows", store, value_select_sql(id, table))
      lines = native_lines(result, "#{id} all-row SELECT")
      rows = tagged(lines, marker('values', id), 7, id)
      fail!("#{id} SELECT must emit exactly eight ordered rows") unless rows.size == ROWS.size
      actual = rows.each_with_index.map do |fields, index|
        fail!("#{id} SELECT primary-key order differs") unless fields[1] == KEYS.fetch(index).to_s
        fail!("#{id} SELECT shared-data flag is not boolean") unless %w[true false].include?(fields[3])
        payload = fields[4] == '6E756C6C' ? nil : decode_hex_json(fields[4], "#{id}/pk#{fields[1]}/payload")
        child_types = fields[6] == '6E756C6C' ? nil : decode_hex_json(fields[6], "#{id}/pk#{fields[1]}/child types")
        length = fields[5] == '-' ? nil : Integer(fields[5], 10)
        {
          pk: Integer(fields[1], 10), dynamic_type: fields[2],
          dynamic_actual_class: fields[2] == 'None' ? 'null' : (array_json_type?(fields[2]) ? 'Array(JSON)' : 'unexpected'),
          shared_data: fields[3] == 'true', payload: payload, array_length: length,
          child_json_path_types: child_types,
        }
      end
      expected_exact = ROWS.each_with_index.all? do |array_values, index|
        row = actual.fetch(index)
        expected_payload = array_values&.map { |value| {'value' => value} }
        expected_child_types = array_values&.map { {'value' => 'Int64'} }
        type_ok = array_values.nil? ? row.fetch(:dynamic_type) == 'None' : array_json_type?(row.fetch(:dynamic_type))
        type_ok && row.fetch(:shared_data) == false && row.fetch(:payload) == expected_payload &&
          row.fetch(:array_length) == array_values&.size && row.fetch(:child_json_path_types) == expected_child_types
      end
      dynamic_counts = actual.each_slice(ROWS_PER_MARK).map { |mark| mark.count { |row| row.fetch(:dynamic_type) != 'None' } }
      ordinary_counts = actual.each_slice(ROWS_PER_MARK).map do |mark|
        mark.count { |row| row.fetch(:dynamic_actual_class) == 'Array(JSON)' && !row.fetch(:shared_data) }
      end
      element_counts = actual.each_slice(ROWS_PER_MARK).map { |mark| mark.sum { |row| row.fetch(:array_length) || 0 } }
      census = dynamic_counts == EXPECTED_SELECTED_ARMS_PER_MARK &&
        ordinary_counts == EXPECTED_ORDINARY_ARRAY_JSON_ARM_COUNTS_PER_MARK &&
        element_counts == EXPECTED_CHILD_JSON_ELEMENTS_PER_MARK
      {
        state: expected_exact && census ? 'expected_native_semantics_observed' : 'observation_differs',
        matches_expected_semantics: expected_exact && census, rows: actual,
        expected_nonnull_dynamic_counts_per_mark: EXPECTED_SELECTED_ARMS_PER_MARK,
        actual_nonnull_dynamic_counts_per_mark: dynamic_counts,
        expected_ordinary_array_json_arm_counts_per_mark: EXPECTED_ORDINARY_ARRAY_JSON_ARM_COUNTS_PER_MARK,
        actual_ordinary_array_json_arm_counts_per_mark: ordinary_counts,
        expected_child_json_element_counts_per_mark: EXPECTED_CHILD_JSON_ELEMENTS_PER_MARK,
        actual_child_json_element_counts_per_mark: element_counts, invocation: result.fetch(:record),
      }
    end

    def expected_signatures(first_mark, mark_count)
      ROWS.slice(first_mark * ROWS_PER_MARK, mark_count * ROWS_PER_MARK).map do |array_values|
        {'payload' => (array_values.nil? ? nil : array_values.map { |value| {'value' => value} })}
      end
    end

    def expected_reader_summary(first_mark, mark_count)
      literals = ROWS.slice(first_mark * ROWS_PER_MARK, mark_count * ROWS_PER_MARK)
      {
        'row_count' => literals.size,
        'literals' => literals,
        'signatures' => expected_signatures(first_mark, mark_count),
      }
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
      report = JSON.parse(result[:stdout].dup.force_encoding(Encoding::UTF_8))
      fail!("#{label} helper envelope differs") unless report.is_a?(Hash) &&
        report.fetch('format') == HELPER_FORMAT && report.fetch('action') == arguments.first &&
        expected_statuses.include?(report.fetch('status'))
      report
    rescue JSON::ParserError, KeyError => error
      fail!("#{label} helper output is invalid: #{error.class}: #{error.message}")
    end

    def local_windows!(id, part)
      PHYSICAL_WINDOWS.to_h do |window, (first, count)|
        report = helper("#{id}_local_#{window}", 'read-native', part, first.to_s, count.to_s,
                        expected_statuses: ['accepted'])
        expected = expected_reader_summary(first, count)
        arms = EXPECTED_SELECTED_ARMS_PER_MARK.slice(first, count)
        elements = EXPECTED_CHILD_JSON_ELEMENTS_PER_MARK.slice(first, count)
        fail!("#{id} local #{window} recursive report differs") unless report.fetch('recursive') == expected
        fail!("#{id} local #{window} static report differs") unless report.fetch('static') == expected
        fail!("#{id} local #{window} parent-arm census differs") unless
          report.fetch('recursive_arm_counts_by_mark') == arms && report.fetch('static_arm_counts_by_mark') == arms
        fail!("#{id} local #{window} child-element census differs") unless
          report.fetch('recursive_child_element_counts_by_mark') == elements &&
          report.fetch('static_child_element_counts_by_mark') == elements
        [window, {first_mark: first, mark_count: count, state: 'exact_values',
                  row_count: expected.fetch('row_count'), recursive: report.fetch('recursive'),
                  static: report.fetch('static'), arm_counts: arms, child_element_counts: elements}]
      end
    end

    def helper_write!(id, destination, mark_format, mode)
      report = helper("#{id}_writer", 'write-native', destination, mark_format, mode)
      expected = {
        'part_path' => destination, 'row_count' => ROWS.size, 'mark_count' => MARK_COUNT,
        'rows_per_mark' => ROWS_PER_MARK, 'mark_format' => mark_format,
        'discriminator_mode' => mode, 'column' => 'typed_dynamic_array_json',
        'declared_schema' => HELPER_DECLARATION, 'dynamic_actual_type' => 'Array(JSON)',
        'expected_parent_dynamic_statistics' => [4, 0],
        'child_json_path_types' => {'value' => 'Int64'},
        'expected_child_object_statistics' => [6],
        'expected_child_dynamic_statistics' => [6, 0],
        'expected_fixture_mark_arm_counts' => EXPECTED_SELECTED_ARMS_PER_MARK,
        'expected_fixture_child_element_counts' => EXPECTED_CHILD_JSON_ELEMENTS_PER_MARK,
        'literals' => ROWS,
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
      fail!("#{id} target data path is symlinked") if File.symlink?(data_path)
      {table: table, store: store, data_path: data_path, create_invocation: result.fetch(:record)}
    end

    def attach_copy!(id, source, target)
      source_inventory = tree_inventory(source)
      @runner.send(:attach_part!, source, target.fetch(:data_path))
      detached = File.join(target.fetch(:data_path), 'detached', PART_NAME)
      # ATTACH moves this tree. Authenticate its inventory before the mutation;
      # never try to re-read the detached path after ClickHouse consumes it.
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
                 parsed = parse_roster!(id, part_path)
                 fail!("#{id} MRK4 callback roster differs from matching stock mode") unless
                   parsed.fetch(:roster) == stock.fetch(:callback_roster)
                 parsed
               else
                 path = File.join(part_path, 'columns_substreams.txt')
                 fail!("#{id} MRK3 unexpectedly has columns_substreams.txt") if File.exist?(path) || File.symlink?(path)
                 {sections: [], roster: [], sha256: nil}
               end
      local = local_windows!(id, part_path)
      target = create_target!(id, mode, mark_format)
      attach = attach_copy!(id, part_path, target)
      attached_part = native_part!("#{id}_attached", target.fetch(:table), target.fetch(:store), mark_format: mark_format)
      attached = attached_inventory!(id, attached_part.fetch(:path), source_inventory)
      check = check!(id, target.fetch(:table), target.fetch(:store))
      values = native_values!(id, target.fetch(:table), target.fetch(:store))
      fail!("#{id} generated part changed while native consumers ran") unless tree_inventory(part_path) == source_inventory
      {
        mark_format: mark_format, discriminator_mode: mode, part_path: part_path,
        write_report: write, source_inventory: source_inventory,
        callback_sections: roster.fetch(:sections), callback_roster: roster.fetch(:roster),
        matching_stock_mrk4_roster_sha256: stock.fetch(:callback_roster_sha256),
        generated_mrk4_roster_sha256: roster.fetch(:sha256),
        local_physical_mark_reads: local, native_target: target, native_attach: attach,
        active_part: {path: attached_part.fetch(:path), **attached},
        native_check: check, native_literal_selects: values,
      }
    end

    def qualify_child_dynamic_version_mutant!(generated)
      id = 'resealed_child_dynamic_version_mrk4_basic'
      source = generated.fetch(:part_path)
      source_inventory = generated.fetch(:source_inventory)
      fail!("#{id} source part changed before copy") unless tree_inventory(source) == source_inventory
      destination = File.join(@root, 'parts', id)
      mutation = helper("#{id}_mutation", 'copy-child-dynamic-version-mutant', 'resealed', source,
                        destination, '2')
      expected_stream = 'typed_dynamic_array_json.payload.Array%28JSON%29.value.dynamic_structure'
      expected_mutation = {
        'source_path' => source, 'mutant_path' => destination,
        'column' => 'typed_dynamic_array_json', 'stream' => expected_stream,
        'mark' => 2, 'semantic_type' => 'Dynamic(Int64)',
        'version_before' => 4, 'version_after' => 5,
        'raw_changed_offsets' => [mutation.fetch('logical_offset')],
        'compressed_size_after' => mutation.fetch('compressed_size_before'),
        'checksums_resealed' => true,
      }
      expected_mutation.each do |key, value|
        fail!("#{id} mutation metadata #{key} differs: #{mutation[key].inspect}") unless mutation[key] == value
      end

      fail!("#{id} source part changed during copy mutation") unless tree_inventory(source) == source_inventory
      mutant_inventory = tree_inventory(destination)
      original_files = source_inventory.fetch(:files).to_h { |entry| [entry.fetch(:path), entry] }
      mutant_files = mutant_inventory.fetch(:files).to_h { |entry| [entry.fetch(:path), entry] }
      changed_files = (original_files.keys | mutant_files.keys).select { |path| original_files[path] != mutant_files[path] }.sort
      fail!("#{id} changed files are not exactly data.bin/checksums.txt: #{changed_files.inspect}") unless
        changed_files == %w[checksums.txt data.bin]

      local = helper("#{id}_local_reject", 'read-native', destination, '2', '1', expected_statuses: ['rejected'])
      fail!("#{id} local read did not reject as CorruptPartError: #{local.inspect}") unless
        local.fetch('error_class') == 'CrystalClick::CorruptPartError' && local.fetch('error_message').include?('version 5')

      target = create_target!(id, 'basic', 'mrk4')
      attach = attach_copy!(id, destination, target)
      active_part = native_part!("#{id}_attached", target.fetch(:table), target.fetch(:store), mark_format: 'mrk4')
      active = attached_inventory!(id, active_part.fetch(:path), mutant_inventory)
      check = check!(id, target.fetch(:table), target.fetch(:store))
      fail!("#{id} native CHECK was not healthy") unless check.fetch(:state) == 'healthy'
      pk_control = native_pk_control!(id, target.fetch(:table), target.fetch(:store))
      child = native_selected_child_json!(id, target.fetch(:table), target.fetch(:store))
      fail!("#{id} source part changed during native checks") unless tree_inventory(source) == source_inventory

      {
        mutation: mutation, changed_relative_paths: changed_files,
        source_inventory_unchanged: true, mutant_inventory: mutant_inventory,
        local_read: local, native_target: target, native_attach: attach,
        active_part: {path: active_part.fetch(:path), **active}, native_check: check,
        unaffected_pk_control: pk_control, selected_child_array_json_window: child,
        claim_boundary: 'copy-only same-extent checksum-resealed negative; generated bytes are diagnostic, not a semantic oracle',
      }
    end

    def capture_stock!(mode, mark_format: 'mrk4', full_matrix: false)
      id = "stock_#{mark_format}_#{mode}"
      table = table_name(id)
      store = store_path("native_#{id}")
      create = native("#{id}_create_insert", store, stock_sql(mode, table, id))
      source_observation = observe_source_values!(id, create) if @constructor == 'column_object'
      part = native_part!(id, table, store, mark_format: mark_format)
      roster = parse_roster!(id, part.fetch(:path))
      inventory = tree_inventory(part.fetch(:path))
      raw_files = capture_raw_files!(id, part.fetch(:path))
      copy = File.join(@root, 'parts', id)
      copied_part = copy_part(part.fetch(:path), copy)
      check = check!(id, table, store)
      observation = full_matrix ? nil : observe_values!(id, table, store)
      values = full_matrix ? native_values!(id, table, store) : nil
      readers = full_matrix ? local_windows!(id, copied_part) : nil
      fail!("#{id} native stock part changed during capture") unless tree_inventory(part.fetch(:path)) == inventory
      {
        origin: 'fresh pinned ClickHouse stock Compact part', mark_format: 'mrk4',
        discriminator_mode: mode, table: table, store: store, native_part: part,
        part_inventory: inventory, raw_files: raw_files,
        callback_sections: roster.fetch(:sections), callback_roster: roster.fetch(:roster),
        callback_roster_sha256: roster.fetch(:sha256), create_insert: create.fetch(:record),
        source_observation: source_observation,
        check: check, observation: observation, native_literal_selects: values,
        copied_part_path: copied_part, local_physical_mark_reads: readers,
      }
    end

    def full_matrix_summary(stock, generated, mutant)
      {
        format: FORMAT, status: 'all_stock_and_generated_array_json_observations_exact',
        execution_mode: 'stock_first_then_generated_writer_matrix',
        runtime_pin: {
          binary: @binary, sha256: @binary_sha_after, version: VERSION, build: BUILD,
          argv_policy: 'W241 bounded clickhouse-local runner; one thread; every invocation has recorded argv/stdin/stdout/stderr/status',
        },
        source_pin: {
          root: @source_root, revision: SOURCE_REVISION, sha256: @upstream_hashes,
          distinction: 'upstream source pin is validated independently from the runtime executable/build pin',
        },
        helper_pin: {path: @helper, sha256: @helper_sha_after},
        probe_sources: @probe_hashes_after,
        fixture: {
          declared_type: DECLARATION, actual_dynamic_type: 'Array(JSON)',
          child_json_path_types: {'value' => 'Int64'}, values_by_pk: ROWS.each_with_index.map { |value, i| {pk: i + 1, array_values: value} },
          rows_per_mark: ROWS_PER_MARK, row_count: ROWS.size, data_marks: MARK_COUNT,
          expected_nonnull_dynamic_counts_per_mark: EXPECTED_SELECTED_ARMS_PER_MARK,
          expected_ordinary_array_json_arm_counts_per_mark: EXPECTED_ORDINARY_ARRAY_JSON_ARM_COUNTS_PER_MARK,
          expected_child_json_element_counts_per_mark: EXPECTED_CHILD_JSON_ELEMENTS_PER_MARK,
          census_authority: 'literal fixture and independent native SELECT; helper counters are checked against literals and are not treated as on-disk evidence',
        },
        stock: stock, generated: generated, child_dynamic_version_mutant: mutant,
        invocations: @invocations, evidence_root: @root,
        claim_boundary: 'Finite W272 witness only: direct typed-Dynamic Array(JSON) in an existing Compact root JSON Object, V3 child Object MAP0/bucket1, MRK3/MRK4 and BASIC/COMPACT. Stock native SQL is the semantic oracle; generated bytes are inspected as physical evidence and consumed by both local readers and pinned native ClickHouse. This does not qualify standalone Dynamic, wrappers/root-Dynamic JSON, nested JSON descendants, advanced/chunked shared-data profiles, non-single-stream String, or compressed marks.',
      }
    end

    def render_summary(summary)
      unless @stock_only
        stock_rows = summary.fetch(:stock).map do |mode, entry|
          values = entry.fetch(:native_literal_selects)
          "- Stock MRK4 #{mode}: exact six SQL windows; local recursive/static reads exact."
        end
        generated_rows = summary.fetch(:generated).map do |name, entry|
          "- Generated #{name}: attached/check healthy; native and local windows exact."
        end
        return [
          '# W272 Compact Array(JSON) writer probe', '',
          "Status: `#{summary.fetch(:status)}`",
          "Runtime: `#{VERSION}` build `#{BUILD}` SHA `#{BINARY_SHA256}`.",
          "Source: `#{SOURCE_REVISION}` at `#{SOURCE_ROOT}` (separately pinned from runtime).",
          'The row fixture is `[ [11,12], NULL, NULL, NULL, [], [61], NULL, [81,82,83] ]`; four two-row marks have non-NULL Dynamic/ordinary Array(JSON) arm counts `[1,0,2,1]` and child element counts `[2,0,1,3]`.',
          'Stock source-column observations precede generated writer construction. Each native check separately asserts Dynamic type, shared flag, array payload/length, and per-element JSON path type.',
          '', *stock_rows, *generated_rows,
          '- The copied MRK4 BASIC child Dynamic version-5 negative is checksum-resealed with unchanged compressed extent; native CHECK stays healthy, the selected child query rejects with the pinned invalid-version diagnostic, and the independent PK control stays exact.',
          '', summary.fetch(:claim_boundary), '',
        ].join("\n")
      end

      observation = summary.fetch(:stock).fetch(:observation)
      nonnull_counts = observation[:actual_nonnull_dynamic_counts_per_mark]
      ordinary_counts = observation[:actual_ordinary_array_json_arm_counts_per_mark]
      source_observation = summary.fetch(:stock)[:source_observation]
      [
        '# W272 Compact Array(JSON) stock-only probe', '',
        "Status: `#{summary.fetch(:status)}`",
        "Runtime: `#{VERSION}` build `#{BUILD}` SHA `#{BINARY_SHA256}`.",
        "Source: `#{SOURCE_REVISION}` at `#{SOURCE_ROOT}` (separately source-pinned).",
        'Eight rows form four two-row marks. The report keeps non-NULL Dynamic counts separate from ordinary `Array(JSON)` arm counts; each is expected to be `[1, 0, 2, 1]`. Expected child JSON element counts are `[2, 0, 1, 3]`.',
        "Observed non-NULL Dynamic counts: `#{nonnull_counts.inspect}`; observed ordinary `Array(JSON)` arm counts: `#{ordinary_counts.inspect}`.",
        ("Typed source observed before conversion: `#{source_observation.fetch(:state)}` with `#{source_observation.fetch(:selected_row_count)}` non-NULL rows." if source_observation),
        'The native query separately records Dynamic type, ordinary/shared placement, payload, array length, and each element’s JSONAllPathsWithTypes. Cast construction is not treated as proof of the actual arm.',
        "Observed semantic match: `#{observation.fetch(:matches_expected_semantics)}`.",
        'This invocation is stock-only and never calls a Crystal helper or writes a generated part.', '',
      ].join("\n")
    end

    def persist_inconclusive(error)
      return unless @root && File.directory?(File.join(@root, 'invocations'))
      report = {
        format: FORMAT, status: 'inconclusive', fatal_error: @fatal_error, error_class: error.class.name,
        runtime_pin: {binary: @binary, expected_sha256: BINARY_SHA256, observed_sha256: (sha(@binary) rescue nil)},
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
    binary: ProbeCompactPartWriterW272::BINARY,
    source_root: ProbeCompactPartWriterW272::SOURCE_ROOT,
    stock_only: false,
    full_matrix: false,
    constructor: 'tuple_dynamic',
    helper: nil,
    helper_sha256: nil,
  }
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/probe_compact_part_writer_w272.rb (--stock-only | --full-matrix) --constructor tuple_dynamic|typed_object|column_object --evidence-root EMPTY_DIR [--helper PREBUILT_HELPER --helper-sha256 SHA256] [--binary PINNED_CLICKHOUSE] [--source-root PINNED_UPSTREAM]'
    parser.on('--stock-only', 'Create and inspect only the native stock fixture; never invoke a Crystal helper') { options[:stock_only] = true }
    parser.on('--full-matrix', 'Capture stock first, then generated MRK3/MRK4 BASIC/COMPACT writer/readback witnesses') { options[:full_matrix] = true }
    parser.on('--constructor NAME', 'Stock SQL constructor: tuple_dynamic, typed_object, or column_object') { |value| options[:constructor] = value }
    parser.on('--helper PATH', 'Prebuilt W272 helper executable for full-matrix mode') { |value| options[:helper] = value }
    parser.on('--helper-sha256 SHA256', 'Expected SHA-256 of the prebuilt helper') { |value| options[:helper_sha256] = value }
    parser.on('--binary PATH', 'Pinned ClickHouse executable') { |value| options[:binary] = value }
    parser.on('--source-root PATH', 'Pinned upstream source checkout') { |value| options[:source_root] = value }
    parser.on('--evidence-root EMPTY_DIR', 'Existing empty direct child of /private/tmp') { |value| options[:evidence_root] = value }
  end.parse!

  abort('select exactly one of --stock-only or --full-matrix') unless options[:stock_only] != options[:full_matrix]
  abort('missing --evidence-root') unless options[:evidence_root]
  abort('--full-matrix requires --constructor column_object') if options[:full_matrix] && options[:constructor] != 'column_object'
  abort('--full-matrix requires --helper and --helper-sha256') if options[:full_matrix] && (!options[:helper] || !options[:helper_sha256])
  probe = ProbeCompactPartWriterW272::Probe.new(**options)
  exit(probe.run ? 0 : 1)
end
