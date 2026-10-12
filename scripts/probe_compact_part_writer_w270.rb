#!/usr/bin/env ruby
# Stock-first native witness for typed Dynamic payloads nested in JSON/Object.
# Native values and the literal census below are independent of the Crystal writer.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'optparse'
require_relative 'probe_object_shared_json_interop_w241'

module ProbeCompactPartWriterW270
  W241 = ProbeObjectSharedJSONInteropW241
  FORMAT = 'compact_part_writer_w270_native_probe_v1'.freeze
  HELPER_FORMAT = 'compact_part_writer_w270_helper_v1'.freeze
  PART_NAME = 'all_1_1_0'.freeze
  HELPER_SOURCE = File.expand_path('compact_part_writer_w270_helper.cr', __dir__).freeze
  FIXTURE_SOURCE = File.expand_path('support/compact_part_writer_w270_fixture.cr', __dir__).freeze
  W241_SOURCE = File.expand_path('probe_object_shared_json_interop_w241.rb', __dir__).freeze
  BINARY = '/private/tmp/crystal-click-w263-runtime-recovery.B9uAPX/clickhouse-stripped'.freeze
  BINARY_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  SOURCE_ROOT = '/private/tmp/clickhouse-w254-upstream.AqeqyC'.freeze
  SOURCE_REVISION = 'ed30948f095ecb70679986d7d60e27ad770ae27a'.freeze
  SOURCE_FILES = %w[
    src/DataTypes/Serializations/SerializationObject.cpp
    src/DataTypes/Serializations/SerializationObjectSharedData.cpp
    src/DataTypes/Serializations/SerializationDynamic.cpp
    src/DataTypes/Serializations/SerializationArray.cpp
    src/DataTypes/Serializations/SerializationNullable.cpp
    src/DataTypes/Serializations/SerializationTuple.cpp
    src/DataTypes/Serializations/SerializationVariant.cpp
    src/DataTypes/Serializations/SerializationJSON.cpp
    src/DataTypes/Serializations/ISerialization.cpp
    src/DataTypes/Serializations/SerializationInfo.cpp
    src/Storages/MergeTree/MergeTreeSettings.cpp
  ].freeze
  MAX_PART_FILES = 160
  MAX_PART_BYTES = 64 * 1024 * 1024
  ROW_COUNT = 6
  ROWS_PER_MARK = 2
  MARK_COUNT = 3
  PHYSICAL_MARK_ROWS = [2, 2, 2, 0].freeze
  JSON_TYPE = 'JSON(max_dynamic_types=1,max_dynamic_paths=2,id UInt64,label String,payload Dynamic(max_types=1))'.freeze
  SCHEMA = [
    ['pk', 'UInt64'],
    ['root_json', JSON_TYPE],
    ['array_json', "Array(#{JSON_TYPE})"],
    ['tagged_json', "Array(Tuple(doc #{JSON_TYPE}, tag UInt8))"],
    ['pair_json', "Tuple(left #{JSON_TYPE}, right #{JSON_TYPE})"],
  ].map(&:freeze).freeze
  COLUMNS = SCHEMA.map(&:first).freeze
  VALUES = {
    full: (1..6).to_a.freeze,
    middle: [3, 4].freeze,
    last: [6].freeze,
    empty: [].freeze,
    last_mark: [5, 6].freeze,
  }.freeze
  SQL_WINDOWS = {
    'full' => '1', 'middle' => 'pk BETWEEN 3 AND 4',
    'last' => 'pk = 6', 'empty' => 'pk > 6',
  }.freeze
  SITE_KEYS = {
    'root_json' => 'root', 'array_json' => 'root/array[0]',
    'tagged_json' => 'root/array[0]/tuple[0]',
    'pair.left' => 'root/tuple[0]', 'pair.right' => 'root/tuple[1]',
  }.freeze
  DYNAMIC_CENSUS = {
    'root' => {array_count: 4, shared_variant_string_count: 1, null_count: 1},
    'root/array[0]' => {array_count: 3, shared_variant_string_count: 1, null_count: 1},
    'root/array[0]/tuple[0]' => {array_count: 4, shared_variant_string_count: 2, null_count: 1},
    'root/tuple[0]' => {array_count: 4, shared_variant_string_count: 1, null_count: 1},
    'root/tuple[1]' => {array_count: 3, shared_variant_string_count: 2, null_count: 1},
  }.freeze

  def self.doc(id, label, payload, hot, mid, spill = :absent)
    value = {'id' => id, 'label' => label, 'payload' => payload, 'hot' => hot, 'mid' => mid}
    value['spill'] = spill unless spill == :absent
    value.freeze
  end

  # Six literal SQL rows. NULL is tracked separately from Array/SharedVariant.
  ROWS = [
    {pk: 1,
     root_json: doc(1, 'r1', [11], 'r1-hot', true, 'r1-spill'),
     array_json: [doc(101, 'a11', [21], true, 'a11-mid', 'a11-spill')],
     tagged_json: [{doc: doc(201, 't1', [31], 't1-hot', true, 't1-spill'), tag: 11},
                   {doc: doc(202, 't2', nil, 't2-hot', false), tag: 12}],
     pair_json: {left: doc(301, 'l1', [51], true, 'l1-mid', 'l1-spill'),
                 right: doc(401, 'q1', [61], 'q1-hot', true, 'q1-spill')}},
    {pk: 2,
     root_json: doc(2, 'r2', [12], 'r2-hot', false),
     array_json: [doc(102, 'a21', nil, false, 'a21-mid')],
     tagged_json: [{doc: doc(203, 't3', [33], 't3-hot', true, true), tag: 13}],
     pair_json: {left: doc(302, 'l2', [52], false, 'l2-mid'),
                 right: doc(402, 'q2', nil, 'q2-hot', false)}},
    {pk: 3,
     root_json: doc(3, 'r3', nil, 'r3-hot', true),
     array_json: [],
     tagged_json: [{doc: doc(204, 't4', 'late-tagged', 't4-hot', 't4-mid'), tag: 14}],
     pair_json: {left: doc(303, 'l3', nil, true, 'l3-mid', false),
                 right: doc(403, 'q3', [63], 'q3-hot', true, true)}},
    {pk: 4,
     root_json: doc(4, 'r4', [], 'r4-hot', 'r4-mid'),
     array_json: [],
     tagged_json: [{doc: doc(205, 't5', [35], true, true), tag: 15}],
     pair_json: {left: doc(304, 'l4', [54], true, 'l4-mid'),
                 right: doc(404, 'q4', 'late-right', 'q4-hot', 'q4-mid')}},
    {pk: 5,
     root_json: doc(5, 'r5', 'late-root', true, true),
     array_json: [doc(105, 'a51', [55], true, 'a51-mid')],
     tagged_json: [{doc: doc(206, 't6', [36], false, false, 't6-spill'), tag: 16}],
     pair_json: {left: doc(305, 'l5', 'late-left', 'l5-hot', 'l5-mid', 'l5-spill'),
                 right: doc(405, 'q5', [65], true, true, 'q5-spill')}},
    {pk: 6,
     root_json: doc(6, 'r6', [16, nil, 17], false, false, 'r6-spill'),
     array_json: [doc(106, 'a61', [26, nil], 'a61-hot', true),
                  doc(107, 'a62', 'late-array', true, 'a62-mid', 'a62-spill')],
     tagged_json: [{doc: doc(207, 't7', 'late-tagged-2', true, false), tag: 17}],
     pair_json: {left: doc(306, 'l6', [56], 'l6-hot', false),
                 right: doc(406, 'q6', 'late-right-2', false, false, 'q6-spill')}},
  ].map(&:freeze).freeze

  UINT8_TYPE = 'JSON(max_dynamic_types=1,max_dynamic_paths=0,payload Dynamic(max_types=1))'.freeze
  UINT8_COLUMN_TYPE = "Array(#{UINT8_TYPE})".freeze
  UINT8_ROW_COUNT = 8
  UINT8_MARK_COUNT = 4
  UINT8_VALUES = {
    full: (1..8).to_a.freeze,
    middle: [3, 4].freeze,
    last: [8].freeze,
    empty: [].freeze,
  }.freeze
  UINT8_SQL_WINDOWS = {
    'full' => '1', 'middle' => 'pk BETWEEN 3 AND 4',
    'last' => 'pk = 8', 'empty' => 'pk > 8',
  }.freeze
  UINT8_ROWS = [
    [{payload: [11]}], [], [], [], [{payload: []}, {payload: [31, 32]}], [], [], [],
  ].map(&:freeze).freeze
  UINT8_LOCAL_MARK_WINDOWS = {
    full: [0, 4].freeze, middle: [1, 1].freeze,
    last_mark: [3, 1].freeze, eof: [4, 0].freeze,
  }.freeze

  class Failure < StandardError; end

  class Probe
    def initialize(binary:, helper:, helper_sha256:, evidence_root:, generated:)
      @binary = validate_executable(binary, 'pinned ClickHouse')
      @helper = helper && validate_executable(helper, 'prebuilt W270 helper')
      @helper_expected_sha = helper_sha256
      @generated = generated
      fail!('--generated requires --crystal-helper and --helper-sha256') if @generated && (!@helper || !@helper_expected_sha)
      @root = validate_root(evidence_root)
      @invocations = []
      @token = Digest::SHA256.hexdigest(@root)[0, 8]
      @runner = W241::Probe.allocate
      @runner.instance_variable_set(:@binary, @binary)
      @runner.instance_variable_set(:@root, @root)
      @runner.instance_variable_set(:@invocations, @invocations)
      @stock = {}
      @source_files = [__FILE__, W241_SOURCE, FIXTURE_SOURCE]
      @source_files << HELPER_SOURCE if @helper
      @source_files = @source_files.map { |path| File.realpath(path) }
      validate_literals!
    end

    def run
      validate_label_plan!
      prepare!
      %w[map map_with_buckets].each do |layout|
        %w[basic compact].each do |mode|
          key = cell_key('mrk4', layout, mode)
          @stock[key] = capture_stock!(layout, mode)
        end
      end
      capture_stock_readers! if @generated
      generated = @generated ? capture_generated! : nil
      uint8 = @generated ? capture_uint8_witness! : nil
      mutant = @generated ? qualify_array_size_mutant!(generated.fetch(cell_key('mrk4', 'map_with_buckets', 'compact'))) : nil
      validate_pins!
      status = @generated ? 'stock_first_matrix_uint8_witness_and_resealed_size_mutant_captured' : 'stock_native_only_captured'
      summary = {
        format: FORMAT, status: status, runtime: runtime_record,
        source: {root: SOURCE_ROOT, revision: SOURCE_REVISION, files: @source_hashes_before,
                 upstream_files: @upstream_hashes},
        fixture: {schema: SCHEMA, rows: ROWS, windows: VALUES, physical_mark_rows_plus_eof: PHYSICAL_MARK_ROWS,
                  required_empty_child_mark: {column: 'array_json', pks: [3, 4]},
                  full_insert_dynamic_census: census_report,
                  statistics_semantics: 'Dynamic counts include non-null actual values only; NULL is recorded separately and is not SharedVariant.'},
        metadata_contract: {serialization_info_version: 'with_types', string_version: 0,
                            propagate_types_serialization_versions_to_nested_types: true,
                            JSON_or_dynamic_serialization_version_metadata: 'none'},
        uint8_witness_fixture: {column: 'nested_dynamic_json', type: UINT8_COLUMN_TYPE,
                                fixture_source: FIXTURE_SOURCE,
                                rows: UINT8_ROWS, row_count: UINT8_ROW_COUNT, mark_count: UINT8_MARK_COUNT,
                                keys: (1..UINT8_ROW_COUNT).to_a, key_count: UINT8_ROW_COUNT,
                                rows_per_mark: 2, full_insert_dynamic_counts: [3, 0],
                                windows: UINT8_VALUES,
                                local_mark_windows: UINT8_LOCAL_MARK_WINDOWS,
                                physical_mark_rows_plus_eof: [2, 2, 2, 2, 0]},
        native_stock_mrk4: @stock, generated_matrix: generated, uint8_array_json_witness: uint8,
        resealed_array_size_mutant: mutant, invocations: @invocations, evidence_root: @root,
        claim_boundary: 'Stock native values, type names, schemas, callback rosters and raw source captures precede helper use. Native full/middle/last/empty SQL is compared to literal rows; helper last_mark is the separate two-row physical mark. CHECK is structural, not semantic. Mutant clean controls establish observed key/other-column behavior only; no granule-I/O locality is claimed.',
      }
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      write_new(File.join(@root, 'summary.md'), render_summary(summary))
      puts "W270 status=#{status}; stock=4; generated=#{generated ? 8 : 0}; uint8=#{uint8 ? 2 : 0}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      persist_inconclusive(error)
      warn "W270 probe inconclusive: #{@fatal_error}"
      false
    end

    private

    def fail!(message)
      raise Failure, "W270: #{message}"
    end

    def validate_root(path)
      fail!('evidence root must be an existing empty direct child of /private/tmp') unless path && File.directory?(File.expand_path(path))
      expanded = File.expand_path(path)
      fail!('evidence root must be a direct child of /private/tmp') unless File.dirname(expanded) == File.realpath('/private/tmp')
      fail!('evidence root must be canonical, non-symlinked, and empty') unless
        !File.symlink?(expanded) && File.realpath(expanded) == expanded && Dir.children(expanded).empty?
      expanded
    rescue Errno::ENOENT
      fail!('evidence root or /private/tmp is absent')
    end

    def validate_executable(path, label)
      fail!("#{label} is absent, non-executable, or symlinked") unless path && File.file?(File.expand_path(path)) &&
        File.executable?(File.expand_path(path)) && !File.symlink?(File.expand_path(path))
      File.realpath(path)
    end

    def validate_literals!
      fail!('literal fixture must contain exactly six ordered primary keys') unless ROWS.map { |row| row.fetch(:pk) } == (1..6).to_a
      fail!('UInt8 literal fixture must contain exactly eight rows') unless UINT8_ROWS.size == UINT8_ROW_COUNT && UINT8_ROW_COUNT == 8
      fail!('UInt8 literal typed-JSON document positions differ') unless UINT8_ROWS.map(&:length) == [1, 0, 0, 0, 2, 0, 0, 0]
      uint8_document_count = UINT8_ROWS.inject(0) { |count, row| count + row.length }
      fail!('UInt8 literal fixture full-block Dynamic count must be three') unless uint8_document_count == 3
      fail!('the middle Array(JSON) mark must be empty at both rows 3 and 4') unless ROWS.values_at(2, 3).all? { |row| row.fetch(:array_json).empty? }
      actual = census_report.to_h { |site| [site.fetch(:site_key), site.fetch(:dynamic)] }
      expected = DYNAMIC_CENSUS
      fail!("literal non-null Dynamic census differs: #{actual.inspect}") unless actual == expected
      true
    end

    def prepare!
      %w[invocations stores parts source-inventories raw-records].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      @binary_sha_before = binary_sha
      fail!('ClickHouse executable differs from pinned native SHA-256') unless @binary_sha_before == BINARY_SHA256
      revision, stderr, status = Open3.capture3('git', '-C', SOURCE_ROOT, 'rev-parse', 'HEAD')
      fail!("pinned source revision check failed: #{stderr.strip}") unless status.success? && revision.strip == SOURCE_REVISION
      @helper_sha_before = helper_sha if @helper
      @source_hashes_before = @source_files.to_h { |path| [path, sha(path)] }
      if @helper
        fail!('prebuilt W270 helper SHA differs from CLI pin') unless @helper_sha_before == @helper_expected_sha
      end
      @upstream_hashes = SOURCE_FILES.to_h do |relative|
        path = File.join(SOURCE_ROOT, relative)
        fail!("pinned upstream source is missing: #{relative}") unless File.file?(path) && !File.symlink?(path)
        [relative, sha(path)]
      end
    end

    def binary_sha
      Digest::SHA256.file(@binary).hexdigest
    end

    def helper_sha
      Digest::SHA256.file(@helper).hexdigest
    end

    def sha(path)
      Digest::SHA256.file(path).hexdigest
    end

    def write_new(path, bytes)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes) }
    end

    def pin_sql
      @runner.send(:pin_sql)
    end

    def native(label, store, sql, allow_server_error: false)
      result = @runner.send(:native, label, store, [pin_sql, sql].join("\n"))
      record = result.fetch(:record)
      fail!("#{label} timed out or had process infrastructure failure") unless
        !record[:timed_out] && record[:spawn_error].nil? && record[:stdin_write_error].nil? &&
        record[:stdout_read_error].nil? && record[:stderr_read_error].nil? && result[:status] && result[:status].termsig.nil?
      accepted = allow_server_error ? %w[success server_exception] : ['success']
      fail!("#{label} native classification #{result[:classification]} is outside #{accepted.inspect}") unless accepted.include?(result[:classification])
      if result[:classification] == 'success'
        @runner.send(:assert_native_success!, result, label)
        @runner.send(:assert_pin!, result[:stdout], label)
      else
        fail!("#{label} ClickHouse identity changed") unless record[:binary_sha_after] == BINARY_SHA256
      end
      result
    end

    def native_lines(result, label)
      output = result[:stdout].dup.force_encoding(Encoding::UTF_8)
      fail!("#{label} stdout is not newline-terminated UTF-8") unless output.valid_encoding? && output.end_with?("\n")
      output.lines.map(&:chomp)
    end

    def marker(kind, id, suffix = nil)
      value = "__W270_#{kind.upcase}_#{id.upcase}"
      value += "_#{suffix.upcase}" if suffix
      "#{value}__"
    end

    def tagged(lines, tag, width, label)
      lines.select { |line| line.start_with?(tag + "\t") }.map do |line|
        fields = line.split("\t", -1)
        fail!("#{label} malformed tagged output") unless fields.size == width
        fields
      end
    end

    def settings(layout, mode, mark_format: 'mrk4')
      buckets = layout == 'map' ? 1 : 2
      layout_value = layout == 'map' ? 'map' : 'map_with_buckets'
      discriminator = mode == 'compact' ? 1 : 0
      substream_marks = mark_format == 'mrk4' ? 1 : 0
      [
        'index_granularity=2', 'index_granularity_bytes=10485760', 'enable_mixed_granularity_parts=1',
        'min_rows_for_wide_part=1000000', 'min_bytes_for_wide_part=104857600', 'min_level_for_wide_part=0',
        'compress_marks=0', 'compress_primary_key=0', 'write_final_mark=1',
        "write_marks_for_substreams_in_compact_parts=#{substream_marks}",
        'min_compress_block_size=0', 'max_compress_block_size=4096',
        'ratio_of_defaults_for_sparse_serialization=1.0', "default_compression_codec='LZ4'",
        "serialization_info_version='with_types'", 'propagate_types_serialization_versions_to_nested_types=true',
        "string_serialization_version='single_stream'", "object_serialization_version='v3'",
        "object_shared_data_serialization_version='#{layout_value}'",
        "object_shared_data_serialization_version_for_zero_level_parts='#{layout_value}'",
        "object_shared_data_buckets_for_compact_part=#{buckets}", "dynamic_serialization_version='v3'",
        "use_compact_variant_discriminators_serialization=#{discriminator}", 'allow_suspicious_low_cardinality_types=1',
      ].join(', ')
    end

    def declarations
      SCHEMA.map { |name, type| "`#{name}` #{type}" }.join(', ')
    end

    def sql_string(value)
      "'#{value.to_s.gsub(/[\\']/) { |character| "\\#{character}" }}'"
    end

    def cast_doc(value)
      "CAST(#{sql_string(JSON.generate(value))}, #{sql_string(JSON_TYPE)})"
    end

    def sql_row(row)
      array = "CAST([#{row.fetch(:array_json).map { |document| cast_doc(document) }.join(', ')}], #{sql_string("Array(#{JSON_TYPE})")})"
      tagged_items = row.fetch(:tagged_json).map do |item|
        "(#{cast_doc(item.fetch(:doc))}, toUInt8(#{item.fetch(:tag)}))"
      end.join(', ')
      tagged = "CAST([#{tagged_items}], #{sql_string("Array(Tuple(doc #{JSON_TYPE}, tag UInt8))")})"
      pair = row.fetch(:pair_json)
      pair_value = "CAST(tuple(#{cast_doc(pair.fetch(:left))}, #{cast_doc(pair.fetch(:right))}), #{sql_string("Tuple(left #{JSON_TYPE}, right #{JSON_TYPE})")})"
      "(toUInt64(#{row.fetch(:pk)}), #{cast_doc(row.fetch(:root_json))}, #{array}, #{tagged}, #{pair_value})"
    end

    def stock_sql(layout, mode, table)
      values = ROWS.map { |row| sql_row(row) }.join(",\n")
      "SET flatten_nested=0;\nSET allow_suspicious_low_cardinality_types=1;\n" \
        "CREATE TABLE default.#{table} (#{declarations}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings(layout, mode)};\n" \
        "INSERT INTO default.#{table} VALUES\n#{values};\n"
    end

    def table_name(key, phase)
      "w270_#{@token}_#{key}_#{phase}"
    end

    def store_path(key)
      path = File.join(@root, 'stores', key)
      Dir.mkdir(path, 0o700) unless Dir.exist?(path)
      path
    end

    def cell_key(mark_format, layout, mode)
      [mark_format, layout, mode].join('_')
    end

    def tree_inventory(path)
      files = []
      total = 0
      Find.find(path) do |entry|
        next if entry == path
        stat = File.lstat(entry)
        fail!("symlink in part tree: #{entry}") if stat.symlink?
        next if stat.directory?
        fail!("non-regular part entry: #{entry}") unless stat.file?
        total += stat.size
        fail!('part file-count bound exceeded') if files.size >= MAX_PART_FILES
        fail!('part byte bound exceeded') if total > MAX_PART_BYTES
        files << {path: entry.delete_prefix(path + File::SEPARATOR), size: stat.size,
                  sha256: Digest::SHA256.file(entry).hexdigest}
      end
      {files: files.sort_by { |entry| entry.fetch(:path) }, total_bytes: total}
    end

    def safe_native_path(path, store)
      real = File.realpath(path)
      root = File.realpath(store)
      fail!("native part escaped its isolated store: #{path}") unless real.start_with?(root + File::SEPARATOR)
      fail!('native part path is not a canonical directory') unless File.directory?(real) && !File.symlink?(path)
      real
    end

    def parse_roster!(id, part)
      path = File.join(part, 'columns_substreams.txt')
      fail!("#{id} columns_substreams is missing or symlinked") unless File.file?(path) && !File.symlink?(path)
      text = File.binread(path).force_encoding(Encoding::UTF_8)
      lines = text.split("\n", -1)
      fail!("#{id} columns_substreams is not newline-terminated UTF-8") unless text.valid_encoding? && lines.pop == ''
      fail!("#{id} columns_substreams version differs") unless lines.shift == 'columns substreams version: 1'
      head = /\A(0|[1-9][0-9]*) columns:\z/.match(lines.shift.to_s)
      fail!("#{id} columns_substreams column count differs") unless head && head[1].to_i == COLUMNS.size
      sections = []
      until lines.empty?
        match = /\A(0|[1-9][0-9]*) substreams for column `([a-z][a-z0-9_]*)`:\z/.match(lines.shift)
        fail!("#{id} malformed physical callback section") unless match
        count = Integer(match[1], 10)
        fail!("#{id} callback count exceeds bound") unless count <= 256 && lines.size >= count
        streams = count.times.map do
          stream = /\A\t([A-Za-z0-9_.%]+)\z/.match(lines.shift.to_s)
          fail!("#{id} malformed callback name") unless stream
          stream[1]
        end
        fail!("#{id} duplicate physical callback") unless streams.uniq.size == streams.size
        sections << [match[2], streams]
      end
      fail!("#{id} physical columns do not match the literal table order") unless sections.map(&:first) == COLUMNS
      fail!("#{id} one or more schema columns has no physical callback") unless sections.all? { |section| !section[1].empty? }
      roster = sections.flat_map { |column, streams| streams.map { |stream| [column, stream] } }
      {text: text, sections: sections, roster: roster}
    end

    def save_stock_capture!(id, part, roster)
      inventory = tree_inventory(part)
      dir = File.join(@root, 'source-inventories')
      safe = id.gsub(/[^A-Za-z0-9_.-]/, '_')
      write_new(File.join(dir, "#{safe}.columns_substreams.txt"), roster.fetch(:text))
      record = {case_name: id, source_part_path: part, inventory: inventory,
                callback_sections: roster.fetch(:sections), callback_roster: roster.fetch(:roster),
                columns_substreams_sha256: Digest::SHA256.hexdigest(roster.fetch(:text))}
      write_new(File.join(dir, "#{safe}.json"), JSON.pretty_generate(record) + "\n")
      %w[data.bin data.mrk4 serialization.json checksums.txt].each do |name|
        source = File.join(part, name)
        fail!("#{id} stock raw evidence file is absent: #{name}") unless File.file?(source) && !File.symlink?(source)
        write_new(File.join(@root, 'raw-records', "#{safe}.#{name}"), File.binread(source))
      end
      inventory
    end

    def copy_part(source, destination)
      fail!('evidence copy destination already exists') if File.exist?(destination) || File.symlink?(destination)
      FileUtils.cp_r(source, destination, preserve: true)
      fail!('stock part copy changed source inventory') unless tree_inventory(source) == tree_inventory(destination)
      destination
    end

    def native_part!(id, table, store, mark_format: 'mrk4', expected_schema: SCHEMA, rows: ROW_COUNT)
      schema_tag = marker('schema', id)
      part_tag = marker('part', id)
      sql = "SELECT '#{schema_tag}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;\n" \
        "SELECT '#{part_tag}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts " \
        "WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;\n"
      result = native("#{id}_schema_part", store, sql)
      lines = native_lines(result, "#{id} schema/part")
      schemas = tagged(lines, schema_tag, 3, id).map { |fields| fields.drop(1) }
      canonical = schemas.map { |name, type| [name, type.gsub(/\s+/, '')] }
      expected = expected_schema.map { |name, type| [name, type.gsub(/\s+/, '')] }
      fail!("#{id} schema differs from literal DDL: #{canonical.inspect}") unless canonical == expected
      parts = tagged(lines, part_tag, 7, id)
      expected_marks = (rows / ROWS_PER_MARK) + 1
      fail!("#{id} is not one Compact part with exact row/mark counts") unless parts.size == 1 &&
        parts.first.values_at(1, 2, 4, 5, 6) == [table, PART_NAME, 'Compact', rows.to_s, expected_marks.to_s]
      path = safe_native_path(parts.first.fetch(3), store)
      selected = File.join(path, "data.#{mark_format}")
      other = File.join(path, mark_format == 'mrk4' ? 'data.mrk3' : 'data.mrk4')
      fail!("#{id} native physical mark format differs") unless File.file?(selected) && !File.exist?(other)
      {path: path, schema: canonical, part: parts.first, marks: expected_marks}
    end

    def check_sql(id, table)
      "SELECT '#{marker('check_begin', id)}' FORMAT TSVRaw;\nCHECK TABLE default.#{table} FORMAT TSV;\n" \
        "SELECT '#{marker('check_end', id)}' FORMAT TSVRaw;\n"
    end

    def native_check!(id, table, store)
      result = native("#{id}_check", store, check_sql(id, table))
      lines = native_lines(result, "#{id} CHECK")
      first = lines.index(marker('check_begin', id))
      last = lines.index(marker('check_end', id))
      rows = first && last && last > first ? lines[(first + 1)...last] : nil
      {state: rows == ["#{PART_NAME}\t1\t"] ? 'healthy' : 'unexpected', rows: rows, invocation: result.fetch(:record)}
    end

    def sql_type_expression(document)
      "if(isNull(#{document}.payload), 'NULL', dynamicType(#{document}.payload))"
    end

    def select_projection(fields)
      result = ["'#{fields.fetch(:marker)}'", 'toString(pk)']
      result << 'hex(toJSONString(root_json))' if fields.fetch(:root, false)
      result << 'hex(toJSONString(array_json))' if fields.fetch(:array, false)
      if fields.fetch(:tagged, false)
        result << "hex(toJSONString(arrayMap(x -> tupleElement(x, 'doc'), tagged_json)))"
        result << "hex(toJSONString(arrayMap(x -> tupleElement(x, 'tag'), tagged_json)))"
      end
      if fields.fetch(:pair, false)
        result << "hex(toJSONString(tupleElement(pair_json, 'left')))"
        result << "hex(toJSONString(tupleElement(pair_json, 'right')))"
      end
      result << "hex(toJSONString(#{sql_type_expression('root_json')}))" if fields.fetch(:root, false)
      result << "hex(toJSONString(arrayMap(x -> #{sql_type_expression('x')}, array_json)))" if fields.fetch(:array, false)
      if fields.fetch(:tagged, false)
        result << "hex(toJSONString(arrayMap(x -> #{sql_type_expression("tupleElement(x, 'doc')")}, tagged_json)))"
      end
      if fields.fetch(:pair, false)
        result << "hex(toJSONString(#{sql_type_expression("tupleElement(pair_json, 'left')")}))"
        result << "hex(toJSONString(#{sql_type_expression("tupleElement(pair_json, 'right')")}))"
      end
      result.join(', ')
    end

    def native_window_sql(table, id, window, fields)
      tag = marker('native', id, window)
      predicate = SQL_WINDOWS.fetch(window)
      if window == 'empty'
        return "SELECT '#{tag}', toString(count()) FROM default.#{table} WHERE #{predicate} FORMAT TSVRaw;\n"
      end
      projection = select_projection(fields.merge(marker: tag))
      "SELECT #{projection} FROM default.#{table} WHERE #{predicate} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;\n"
    end

    def literal_json(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, child), out| out[key.to_s] = literal_json(child) }
      when Array
        value.map { |child| literal_json(child) }
      else
        value
      end
    end

    def type_name(value)
      return 'NULL' if value.nil?
      return 'Array(Nullable(Int64))' if value.is_a?(Array)
      return 'String' if value.is_a?(String)
      fail!("unadmitted Dynamic literal type #{value.class}")
    end

    def docs_for(row, column)
      case column
      when 'root_json' then [row.fetch(:root_json)]
      when 'array_json' then row.fetch(:array_json)
      when 'tagged_json' then row.fetch(:tagged_json).map { |item| item.fetch(:doc) }
      when 'pair.left' then [row.fetch(:pair_json).fetch(:left)]
      when 'pair.right' then [row.fetch(:pair_json).fetch(:right)]
      else fail!("unknown typed Dynamic site #{column}")
      end
    end

    def expected_types(row, fields)
      result = []
      result << type_name(row.fetch(:root_json).fetch('payload')) if fields.fetch(:root, false)
      result << row.fetch(:array_json).map { |doc| type_name(doc.fetch('payload')) } if fields.fetch(:array, false)
      if fields.fetch(:tagged, false)
        result << row.fetch(:tagged_json).map { |item| type_name(item.fetch(:doc).fetch('payload')) }
      end
      if fields.fetch(:pair, false)
        result << type_name(row.fetch(:pair_json).fetch(:left).fetch('payload'))
        result << type_name(row.fetch(:pair_json).fetch(:right).fetch('payload'))
      end
      result
    end

    def expected_native_columns(row, fields)
      result = []
      result << row.fetch(:root_json) if fields.fetch(:root, false)
      result << row.fetch(:array_json) if fields.fetch(:array, false)
      if fields.fetch(:tagged, false)
        result << row.fetch(:tagged_json).map { |item| item.fetch(:doc) }
        result << row.fetch(:tagged_json).map { |item| item.fetch(:tag) }
      end
      if fields.fetch(:pair, false)
        result << row.fetch(:pair_json).fetch(:left)
        result << row.fetch(:pair_json).fetch(:right)
      end
      result.concat(expected_types(row, fields))
      literal_json(result)
    end

    def parse_hex_json(value, label)
      fail!("#{label} output is not even hex") unless value.match?(/\A(?:[0-9a-fA-F]{2})*\z/)
      JSON.parse([value.downcase].pack('H*'))
    rescue JSON::ParserError => error
      fail!("#{label} output contains invalid JSON: #{error.message}")
    end

    def native_select!(id, table, store, window, fields: {root: true, array: true, tagged: true, pair: true}, strict: true)
      result = native("#{id}_select_#{fields.keys.join('_')}_#{window}", store,
                      native_window_sql(table, id, window, fields), allow_server_error: !strict)
      if result[:classification] != 'success'
        fail!("#{id} #{window} SELECT unexpectedly rejected") if strict
        return {state: 'server_exception', invocation: result.fetch(:record)}
      end
      lines = native_lines(result, "#{id} #{window} SELECT")
      tag = marker('native', id, window)
      if window == 'empty'
        rows = tagged(lines, tag, 2, id)
        exact = rows == [[tag, '0']]
        parsed = []
      else
        type_field_count = %i[root array tagged].count { |key| fields.fetch(key, false) } +
          (fields.fetch(:pair, false) ? 2 : 0)
        field_count = 2 + %i[root array].count { |key| fields.fetch(key, false) } +
          (fields.fetch(:tagged, false) ? 2 : 0) + (fields.fetch(:pair, false) ? 2 : 0) + type_field_count
        rows = tagged(lines, tag, field_count, id)
        parsed = rows.map { |row| row.drop(2).map { |value| parse_hex_json(value, "#{id} #{window}") } }
        pks = VALUES.fetch(window.to_sym)
        expected = ROWS.select { |row| pks.include?(row.fetch(:pk)) }.map { |row| expected_native_columns(row, fields) }
        exact = rows.map { |row| row[1].to_i } == pks && parsed == expected
      end
      state = exact ? 'exact_values' : 'value_mismatch'
      fail!("#{id} #{window} values or Dynamic type names differ from independent literals") if strict && !exact
      {state: state, row_count: window == 'empty' ? 0 : parsed.size,
       rows: parsed, invocation: result.fetch(:record)}
    end

    def native_selects!(id, table, store)
      result = {}
      %w[full middle last empty].each do |window|
        result[window] = native_select!(id, table, store, window)
      end
      result
    end

    def census_report
      sites = [
        ['root', 'root_json'], ['root/array[0]', 'array_json'],
        ['root/array[0]/tuple[0]', 'tagged_json'], ['root/tuple[0]', 'pair.left'],
        ['root/tuple[1]', 'pair.right'],
      ]
      sites.map do |site, column|
        values = ROWS.flat_map { |row| docs_for(row, column) }
        counts = {array_count: 0, shared_variant_string_count: 0, null_count: 0}
        values.each do |doc|
          payload = doc.fetch('payload')
          if payload.nil?
            counts[:null_count] += 1
          elsif payload.is_a?(Array)
            counts[:array_count] += 1
          elsif payload.is_a?(String)
            counts[:shared_variant_string_count] += 1
          else
            fail!("#{site} payload literal has an unadmitted type")
          end
        end
        {site_key: site, dynamic: counts}
      end
    end

    def capture_stock!(layout, mode)
      key = cell_key('mrk4', layout, mode)
      table = table_name(key, 'stock')
      store = store_path(key)
      create = native("#{key}_create_insert", store, stock_sql(layout, mode, table))
      part = native_part!(key, table, store)
      roster = parse_roster!(key, part.fetch(:path))
      inventory = save_stock_capture!(key, part.fetch(:path), roster)
      destination = File.join(@root, 'parts', "stock_#{key}")
      copied = copy_part(part.fetch(:path), destination)
      check = native_check!(key, table, store)
      fail!("#{key} stock CHECK did not return one healthy part") unless check.fetch(:state) == 'healthy'
      selects = native_selects!(key, table, store)
      fail!("#{key} stock literal SELECT did not exactly match") unless selects.values.all? { |entry| entry.fetch(:state) == 'exact_values' }
      fail!("#{key} stock part changed while capturing") unless tree_inventory(part.fetch(:path)) == inventory
      {layout: layout, variant_mode: mode, table: table, store: store,
       copied_part_path: copied, native_source_path: part.fetch(:path),
       source_inventory: inventory, callback_sections: roster.fetch(:sections), callback_roster: roster.fetch(:roster),
       create_insert: create.fetch(:record), check: check, native_literal_selects: selects,
       observed_dynamic_types: selects.fetch('full').fetch(:rows)}
    end

    def capture_stock_readers!
      @stock.each do |key, stock|
        part = stock.fetch(:copied_part_path)
        stock[:local_stock_full_readers] = COLUMNS.drop(1).map do |column|
          local_read!("stock_#{key}", part, column, 'full')
        end
        stock[:local_selected_windows] = {}
        next unless key == cell_key('mrk4', 'map_with_buckets', 'compact')

        %w[middle last_mark eof].each do |window|
          stock[:local_selected_windows][window] = COLUMNS.drop(1).map do |column|
            local_read!("stock_#{key}", part, column, window)
          end
        end
      end
    end

    def helper(label, *arguments, expected_statuses: ['ok'])
      fail!('generated mode has no prebuilt helper') unless @helper
      result = @runner.send(:run_process, label, [@helper] + arguments, ''.b, 'crystal-helper',
                            expected_sha: @helper_sha_before, binary_path: @helper)
      record = result.fetch(:record)
      fail!("#{label} helper process failed or exceeded bounds") unless !record[:timed_out] && record[:spawn_error].nil? &&
        record[:stdin_write_error].nil? && record[:stdout_read_error].nil? && record[:stderr_read_error].nil? &&
        result[:status] && result[:status].termsig.nil? && result[:status].success? && result[:stderr].empty?
      report = JSON.parse(result[:stdout].dup.force_encoding(Encoding::UTF_8))
      fail!("#{label} helper report envelope differs") unless report.is_a?(Hash) && report.fetch('format') == HELPER_FORMAT &&
        report.fetch('action') == arguments.first && expected_statuses.include?(report.fetch('status'))
      report
    rescue JSON::ParserError => error
      fail!("#{label} helper stdout is invalid JSON: #{error.message}")
    end

    def local_read!(key, part, column, window)
      first, count = case window
                     when 'full' then [0, 3]
                     when 'middle' then [1, 1]
                     when 'last_mark' then [2, 1]
                     when 'empty', 'eof' then [3, 0]
                     else fail!("unknown local mark window #{window}")
                     end
      report = helper("#{key}_local_#{column}_#{window}", 'read-main', part, column, first.to_s, count.to_s,
                      expected_statuses: ['accepted'])
      fail!("#{key} local reader rejected #{column}/#{window}") unless report.fetch('status') == 'accepted'
      pks = VALUES.fetch(window == 'eof' ? :empty : window.to_sym)
      expected_rows = ROWS.select { |row| pks.include?(row.fetch(:pk)) }.map { |row| literal_json(row.fetch(column.to_sym)) }
      fail!("#{key} local #{column}/#{window} differs from fixture literals") unless report.fetch('signatures') == expected_rows
      {status: report.fetch('status'), column: column, window: window,
       row_count: report.fetch('row_count'), signatures: report.fetch('signatures')}
    end

    def create_target!(key, layout, mode, mark_format, schema: SCHEMA, order_by: 'pk')
      store = store_path("target_#{key}")
      table = table_name(key, 'target')
      declarations = schema.map { |name, type| "`#{name}` #{type}" }.join(', ')
      tag = marker('path', key)
      sql = "CREATE TABLE default.#{table} (#{declarations}) ENGINE=MergeTree ORDER BY #{order_by} SETTINGS #{settings(layout, mode, mark_format: mark_format)};\n" \
        "SELECT '#{tag}', arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw;\n"
      result = native("#{key}_target_create", store, sql)
      paths = tagged(native_lines(result, "#{key} target create"), tag, 2, key)
      fail!("#{key} target data path is not unique") unless paths.size == 1 && !paths.first[1].empty?
      {table: table, store: store, data_path: safe_native_path(paths.first[1], store), create_invocation: result.fetch(:record)}
    end

    def attach_copy!(key, source, target)
      source_inventory = tree_inventory(source)
      @runner.send(:attach_part!, source, target.fetch(:data_path))
      detached = File.join(target.fetch(:data_path), 'detached', PART_NAME)
      detached_inventory = tree_inventory(detached)
      fail!("#{key} detached part differs from generated source") unless detached_inventory == source_inventory
      result = native("#{key}_attach", target.fetch(:store), "ALTER TABLE default.#{target.fetch(:table)} ATTACH PART '#{PART_NAME}';\n")
      fail!("#{key} native ATTACH was refused") unless result[:classification] == 'success'
      {state: 'success', invocation: result.fetch(:record), source_inventory: source_inventory, detached_inventory: detached_inventory}
    end

    def validate_attached_inventory!(key, active, source_inventory)
      active_inventory = tree_inventory(active)
      source = source_inventory.fetch(:files).to_h { |entry| [entry.fetch(:path), entry] }
      active_files = active_inventory.fetch(:files).to_h { |entry| [entry.fetch(:path), entry] }
      fail!("#{key} ATTACH changed/removed original files") unless source.all? { |name, entry| active_files[name] == entry }
      extras = active_files.keys - source.keys
      fail!("#{key} ATTACH added unexpected files") unless extras == ['invalidated_system_columns.txt']
      sidecar_path = File.join(active, 'invalidated_system_columns.txt')
      bytes = File.binread(sidecar_path)
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      fail!("#{key} ATTACH invalidation sidecar differs") unless text.valid_encoding? &&
        text.split("\n", -1) == ["_block_offset", "_block_number", '']
      {inventory: active_inventory, native_owned_sidecar: {path: 'invalidated_system_columns.txt',
       contents: text, size: bytes.bytesize, sha256: Digest::SHA256.hexdigest(bytes)}}
    end

    def capture_generated!
      result = {}
      %w[mrk3 mrk4].product(%w[map map_with_buckets], %w[basic compact]).each do |mark_format, layout, mode|
        key = cell_key(mark_format, layout, mode)
        stock = @stock.fetch(cell_key('mrk4', layout, mode))
        result[key] = capture_generated_cell!(key, mark_format, layout, mode, stock)
      end
      result
    end

    def capture_generated_cell!(key, mark_format, layout, mode, stock)
      part = File.join(@root, 'parts', "generated_#{key}")
      write = helper("#{key}_writer", 'write-main', part, mark_format, layout, mode)
      fail!("#{key} helper write report differs") unless write.fetch('part_path') == part &&
        write.fetch('row_count') == ROW_COUNT && write.fetch('mark_format') == mark_format &&
        write.fetch('shared_layout') == layout && write.fetch('variant_discriminator_mode') == (mode == 'compact' ? 1 : 0)
      source_inventory = tree_inventory(part)
      roster = if mark_format == 'mrk4'
                 parsed = parse_roster!(key, part)
                 fail!("#{key} generated physical roster differs from exact matching stock cell") unless parsed.fetch(:roster) == stock.fetch(:callback_roster)
                 parsed
               else
                 sidecar = File.join(part, 'columns_substreams.txt')
                 fail!("#{key} MRK3 part unexpectedly has a physical-roster sidecar") if File.exist?(sidecar) || File.symlink?(sidecar)
                 {sections: [], roster: []}
               end
      local_full = COLUMNS.drop(1).map { |column| local_read!(key, part, column, 'full') }
      local_windows = {}
      if key == cell_key('mrk4', 'map_with_buckets', 'compact')
        %w[middle last_mark empty].each do |window|
          local_windows[window] = COLUMNS.drop(1).map { |column| local_read!(key, part, column, window) }
        end
      end
      target = create_target!("generated_#{key}", layout, mode, mark_format)
      attach = attach_copy!("generated_#{key}", part, target)
      active = native_part!("generated_#{key}_attached", target.fetch(:table), target.fetch(:store), mark_format: mark_format)
      attached = validate_attached_inventory!(key, active.fetch(:path), source_inventory)
      check = native_check!("generated_#{key}", target.fetch(:table), target.fetch(:store))
      fail!("#{key} attached CHECK did not return one healthy part") unless check.fetch(:state) == 'healthy'
      selects = native_selects!("generated_#{key}", target.fetch(:table), target.fetch(:store))
      fail!("#{key} generated native values differ from independent literals") unless selects.values.all? { |entry| entry.fetch(:state) == 'exact_values' }
      fail!("#{key} generated source changed during native consumption") unless tree_inventory(part) == source_inventory
      {mark_format: mark_format, layout: layout, variant_mode: mode, part_path: part,
       write_report: write, source_inventory: source_inventory, callback_sections: roster.fetch(:sections),
       callback_roster: roster.fetch(:roster), local_full_readers: local_full, local_selected_windows: local_windows,
       native_target: target, native_attach: attach, active_part: {path: active.fetch(:path), **attached},
       native_check: check, native_literal_selects: selects}
    end

    def capture_uint8_witness!
      results = {}
      %w[mrk3 mrk4].each do |mark_format|
        key = "uint8_#{mark_format}_basic"
        part = File.join(@root, 'parts', "generated_#{key}")
        write = helper("#{key}_writer", 'write-uint8-witness', part, mark_format, 'basic')
        fail!("#{key} fixture metadata differs") unless write.fetch('typed_dynamic_type') == 'Array(UInt8)' &&
          write.fetch('row_count') == UINT8_ROW_COUNT && write.fetch('mark_count') == UINT8_MARK_COUNT &&
          write.fetch('dynamic_prefix_full_insert_counts') == [3, 0] &&
          write.fetch('key_count') == UINT8_ROW_COUNT && write.fetch('rows_per_mark') == 2
        inventory = tree_inventory(part)
        local_mark_reads = uint8_local_mark_reads!(key, part)
        target = create_target!("generated_#{key}", 'map', 'basic', mark_format,
                                schema: [['pk', 'UInt64'], ['nested_dynamic_json', UINT8_COLUMN_TYPE]])
        attach = attach_copy!("generated_#{key}", part, target)
        active = native_part!("generated_#{key}_attached", target.fetch(:table), target.fetch(:store), mark_format: mark_format,
                              rows: UINT8_ROW_COUNT,
                              expected_schema: [['pk', 'UInt64'], ['nested_dynamic_json', UINT8_COLUMN_TYPE]])
        attached = validate_attached_inventory!(key, active.fetch(:path), inventory)
        check = native_check!("generated_#{key}", target.fetch(:table), target.fetch(:store))
        fail!("#{key} attached CHECK did not return healthy") unless check.fetch(:state) == 'healthy'
        selects = uint8_native_selects!(key, target.fetch(:table), target.fetch(:store))
        fail!("#{key} Array(UInt8) native values/types differ") unless selects.values.all? { |entry| entry.fetch(:state) == 'exact_values' }
        results[key] = {mark_format: mark_format, write_report: write, source_inventory: inventory,
                        local_mark_reads: local_mark_reads,
                        native_target: target, native_attach: attach, active_part: {path: active.fetch(:path), **attached},
                        native_check: check, native_literal_selects: selects}
      end
      results
    end

    def uint8_local_mark_reads!(key, part)
      UINT8_LOCAL_MARK_WINDOWS.each_with_object({}) do |(window, (first_mark, mark_count)), result|
        read = helper("#{key}_local_#{window}", 'read-uint8-witness', part,
                      first_mark.to_s, mark_count.to_s, expected_statuses: ['accepted'])
        expected_rows = UINT8_ROWS.slice(first_mark * 2, mark_count * 2).map do |row|
          literal_json(row.map { |entry| {'payload' => entry.fetch(:payload)} })
        end
        fail!("#{key} local #{window} UInt8 reader rejected") unless read.fetch('status') == 'accepted'
        fail!("#{key} local #{window} UInt8 row count differs") unless read.fetch('row_count') == expected_rows.size
        fail!("#{key} local #{window} UInt8 values differ from independent literals") unless
          read.fetch('signatures') == expected_rows
        result[window] = {first_mark: first_mark, mark_count: mark_count,
                          status: read.fetch('status'), row_count: read.fetch('row_count'),
                          signatures: read.fetch('signatures')}
      end
    end

    def uint8_native_selects!(id, table, store)
      windows = {}
      %w[full middle last empty].each do |window|
        tag = marker('native', id, window)
        if window == 'empty'
          predicate = UINT8_SQL_WINDOWS.fetch(window)
          result = native("#{id}_select_nested_dynamic_json_empty", store,
                          "SELECT '#{tag}', toString(count()) FROM default.#{table} WHERE #{predicate} FORMAT TSVRaw;\n")
          rows = tagged(native_lines(result, id), tag, 2, id)
          state = rows == [[tag, '0']] ? 'exact_values' : 'value_mismatch'
          windows[window] = {state: state, row_count: 0, invocation: result.fetch(:record)}
          next
        end
        pks = UINT8_VALUES.fetch(window.to_sym)
        predicate = UINT8_SQL_WINDOWS.fetch(window)
        sql = "SELECT '#{tag}', toString(pk), hex(toJSONString(nested_dynamic_json)), " \
          "hex(toJSONString(arrayMap(x -> if(isNull(x.payload), 'NULL', dynamicType(x.payload)), nested_dynamic_json))) " \
          "FROM default.#{table} WHERE #{predicate} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;\n"
        result = native("#{id}_select_nested_dynamic_json_#{window}", store, sql)
        rows = tagged(native_lines(result, id), tag, 4, id)
        actual = rows.map { |row| row.drop(2).map { |value| parse_hex_json(value, "#{id} #{window}") } }
        expected = pks.map do |pk|
          payloads = UINT8_ROWS.fetch(pk - 1)
          value = payloads.map { |entry| {'payload' => entry.fetch(:payload)} }
          types = payloads.map { |_entry| 'Array(UInt8)' }
          [literal_json(value), types]
        end
        exact = rows.map { |row| row[1].to_i } == pks && actual == expected
        windows[window] = {state: exact ? 'exact_values' : 'value_mismatch', row_count: rows.size,
                           rows: actual, invocation: result.fetch(:record)}
      end
      windows
    end

    def qualify_array_size_mutant!(cell)
      source = cell.fetch(:part_path)
      source_before = tree_inventory(source)
      mutant_path = File.join(@root, 'parts', 'resealed_root_middle_array_size')
      mutation = helper('resealed_root_middle_array_size_mutation', 'copy-array-size-mutant', 'resealed', source, mutant_path)
      mutant_inventory = tree_inventory(mutant_path)
      source_files = source_before.fetch(:files).to_h { |entry| [entry.fetch(:path), entry] }
      mutant_files = mutant_inventory.fetch(:files).to_h { |entry| [entry.fetch(:path), entry] }
      changed = (source_files.keys | mutant_files.keys).sort.select { |name| source_files[name] != mutant_files[name] }
      fail!('ArraySizes mutant changed files beyond data.bin/checksums.txt') unless changed == %w[checksums.txt data.bin]
      fail!('ArraySizes mutant changed mark bytes or compressed data size') unless
        source_files.fetch('data.mrk4') == mutant_files.fetch('data.mrk4') &&
        source_files.fetch('data.bin').fetch(:size) == mutant_files.fetch('data.bin').fetch(:size)
      fail!('ArraySizes mutation report is not exactly one zero-to-one byte at root_json mark 1') unless
        mutation.fetch('column') == 'root_json' && mutation.fetch('mark') == 1 &&
        mutation.fetch('semantic_type') == 'Array(Nullable(Int64))' && mutation.fetch('value_before') == 0 &&
        mutation.fetch('value_after') == 1 && mutation.fetch('raw_changed_offsets').size == 1 &&
        mutation.fetch('checksums_resealed') == true
      local = helper('resealed_root_middle_array_size_local_read', 'read-main', mutant_path, 'root_json', '1', '1',
                     expected_statuses: %w[accepted rejected])
      local_state = local.fetch('status')
      fail!('local root_json middle mutant did not reject or visibly differ') unless
        local_state == 'rejected' || local.fetch('signatures') != VALUES.fetch(:middle).map { |pk| literal_json(ROWS.fetch(pk - 1).fetch(:root_json)) }

      target = create_target!('resealed_root_middle_array_size', 'map_with_buckets', 'compact', 'mrk4')
      attach = attach_copy!('resealed_root_middle_array_size', mutant_path, target)
      active = native_part!('resealed_root_middle_array_size_attached', target.fetch(:table), target.fetch(:store))
      attached = validate_attached_inventory!('resealed_root_middle_array_size', active.fetch(:path), mutant_inventory)
      check = native_check!('resealed_root_middle_array_size', target.fetch(:table), target.fetch(:store))
      fail!('resealed mutant native CHECK was not separately healthy') unless check.fetch(:state) == 'healthy'
      bad = native_select!('resealed_root_middle_array_size', target.fetch(:table), target.fetch(:store), 'middle',
                           fields: {root: true}, strict: false)
      fail!('native root_json middle did not reject or visibly differ after size mutation') unless
        %w[server_exception value_mismatch].include?(bad.fetch(:state))
      controls = {
        pk_middle: native_select!('resealed_root_middle_array_size_pk', target.fetch(:table), target.fetch(:store),
                                  'middle', fields: {}, strict: true),
        other_column_middle: native_select!('resealed_root_middle_array_size_other', target.fetch(:table), target.fetch(:store),
                                            'middle', fields: {array: true}, strict: true),
      }
      fail!('mutant controls changed the active or source parts') unless tree_inventory(active.fetch(:path)) == attached.fetch(:inventory) &&
        tree_inventory(mutant_path) == mutant_inventory && tree_inventory(source) == source_before
      {mutation: mutation, source_inventory: source_before, mutant_inventory: mutant_inventory,
       changed_files: changed, local_middle_observation: {status: local_state},
       native_target: target, native_attach: attach, native_active_part: {path: active.fetch(:path), **attached},
       native_check_nonsemantic: check, native_selected_middle_observation: bad, native_clean_controls: controls}
    end

    def validate_label_plan!
      keys = %w[map map_with_buckets].product(%w[basic compact]).map { |layout, mode| cell_key('mrk4', layout, mode) }
      labels = keys.flat_map do |key|
        ["#{key}_create_insert", "#{key}_schema_part", "#{key}_check"] +
          %w[full middle last empty].map { |window| "#{key}_select_root_array_tagged_pair_#{window}" }
      end
      generated = %w[mrk3 mrk4].product(%w[map map_with_buckets], %w[basic compact]).map do |format, layout, mode|
        "generated_#{cell_key(format, layout, mode)}"
      end
      fail!('native invocation labels collide') unless labels.uniq.size == labels.size && (labels & generated).empty?
      true
    end

    def validate_pins!
      fail!('pinned ClickHouse SHA changed during capture') unless binary_sha == BINARY_SHA256
      fail!('prebuilt helper SHA changed during capture') if @helper && helper_sha != @helper_sha_before
      @source_hashes_before.each do |path, expected|
        fail!("probe source changed during capture: #{path}") unless sha(path) == expected
      end
      @upstream_hashes.each do |relative, expected|
        fail!("pinned upstream source changed during capture: #{relative}") unless sha(File.join(SOURCE_ROOT, relative)) == expected
      end
      true
    end

    def runtime_record
      {path: @binary, sha256: BINARY_SHA256, version: W241::VERSION, build: W241::BUILD,
       sha256_before: @binary_sha_before, sha256_after: binary_sha}
    end

    def render_summary(summary)
      [
        '# W270 stock-first typed-Dynamic JSON witness', '',
        "- Status: `#{summary.fetch(:status)}`.",
        "- Runtime: ClickHouse #{W241::VERSION} / `#{W241::BUILD}` / SHA-256 `#{BINARY_SHA256}`.",
        "- Evidence root: `#{@root}`.",
        '- The first four cells are native stock MRK4 MAP/MAP_WITH_BUCKETS × BASIC/COMPACT.',
        '- Generated MRK3/MRK4 cells and the Array(UInt8) witness are captured only after all stock literal windows and callback rosters.',
        '- Dynamic NULL counts are reported separately and excluded from SharedVariant statistics.',
        '- CHECK is structural; exact SELECT values/types are the semantic oracle. No physical I/O locality claim is made.', '',
      ].join("\n")
    end

    def persist_inconclusive(error)
      return unless @root && File.directory?(@root) && !File.exist?(File.join(@root, 'summary.json'))
      summary = {format: FORMAT, status: 'runner_failure_inconclusive', fatal_error: "#{error.class}: #{error.message}",
                 runtime: {path: @binary, sha256: BINARY_SHA256}, native_stock_mrk4: @stock,
                 invocations: @invocations, evidence_root: @root}
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
    rescue StandardError => write_error
      warn "W270 failure-summary persistence failed: #{write_error.class}: #{write_error.message}"
    end
  end

  def self.main
    options = {binary: BINARY}
    selected = nil
    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby scripts/probe_compact_part_writer_w270.rb (--stock-only | --generated) --evidence-root EMPTY_DIRECT_CHILD_OF_PRIVATE_TMP [--clickhouse PATH] [--crystal-helper PREBUILT_HELPER --helper-sha256 HEX]'
      parser.on('--stock-only', 'Capture four native stock cells and literal value/type windows; never invokes helper') do
        abort 'W270: choose one mode' if selected
        selected = :stock
      end
      parser.on('--generated', 'Capture stock first, then eight generated cells, UInt8 witness, and copy-only size mutant') do
        abort 'W270: choose one mode' if selected
        selected = :generated
      end
      parser.on('--clickhouse PATH', 'Pinned ClickHouse executable') { |value| options[:binary] = value }
      parser.on('--crystal-helper PATH', 'Prebuilt helper executable; the driver does not compile') { |value| options[:helper] = value }
      parser.on('--helper-sha256 HEX', 'Independently measured prebuilt helper SHA-256') { |value| options[:helper_sha256] = value }
      parser.on('--evidence-root PATH', 'Existing empty direct child of /private/tmp') { |value| options[:evidence_root] = value }
    end.parse!
    abort 'W270: choose a mode and provide --evidence-root' unless selected && options[:evidence_root]
    abort 'W270: --generated requires --crystal-helper and --helper-sha256' if selected == :generated && (!options[:helper] || !options[:helper_sha256])
    probe = Probe.new(binary: options[:binary], helper: options[:helper], helper_sha256: options[:helper_sha256],
                      evidence_root: options[:evidence_root], generated: selected == :generated)
    exit(probe.run ? 0 : 1)
  rescue StandardError => error
    warn "W270 runner error: #{error.class}: #{error.message}"
    exit 1
  end
end

if $PROGRAM_NAME == __FILE__
  ProbeCompactPartWriterW270.main
end
