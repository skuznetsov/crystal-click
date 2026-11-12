#!/usr/bin/env ruby
# Stock-first native witness for an ordinary JSON actual in a typed Dynamic
# field of a Compact root JSON column. This probe is an inventory/interop tool;
# it does not treat generated output as a semantic oracle.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'optparse'
require_relative 'probe_object_shared_json_interop_w241'

module ProbeCompactPartWriterW271
  W241 = ProbeObjectSharedJSONInteropW241
  FORMAT = 'compact_part_writer_w271_native_probe_v1'.freeze
  HELPER_FORMAT = 'compact_part_writer_w271_helper_v1'.freeze
  PART_NAME = 'all_1_1_0'.freeze
  BINARY = '/private/tmp/crystal-click-w263-runtime-recovery.B9uAPX/clickhouse-stripped'.freeze
  BINARY_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  VERSION = '26.10.1.1201'.freeze
  BUILD = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
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
  HELPER_SOURCE = File.expand_path('compact_part_writer_w271_helper.cr', __dir__).freeze
  FIXTURE_SOURCE = File.expand_path('support/compact_part_writer_w271_native_fixture.cr', __dir__).freeze
  LOCAL_FIXTURE_SOURCE = File.expand_path('../spec/support/compact_part_writer_w271_fixture.cr', __dir__).freeze
  W241_SOURCE = File.expand_path('probe_object_shared_json_interop_w241.rb', __dir__).freeze
  COLUMN = 'typed_dynamic_json'.freeze
  DECLARATION = 'JSON(max_dynamic_types=1,max_dynamic_paths=0,payload Dynamic(max_types=1))'.freeze
  HELPER_DECLARATION = 'JSON(max_dynamic_types=1, max_dynamic_paths=0, payload Dynamic(max_types=1))'.freeze
  ROWS = [11, nil, nil, nil, 51, 61, nil, 81].freeze
  KEYS = (1..8).to_a.freeze
  ROWS_PER_MARK = 2
  MARK_COUNT = 4
  MARK_COUNTS = [1, 0, 2, 1].freeze
  SQL_WINDOWS = {
    'full' => nil,
    'middle' => 'pk BETWEEN 3 AND 6',
    'zero_arm' => 'pk BETWEEN 3 AND 4',
    'last' => 'pk BETWEEN 7 AND 8',
    'empty' => 'pk > 8',
  }.freeze
  PHYSICAL_WINDOWS = {
    'full' => [0, 4].freeze,
    'middle' => [1, 2].freeze,
    'zero_arm' => [1, 1].freeze,
    'last' => [3, 1].freeze,
    'empty' => [4, 0].freeze,
  }.freeze
  MAX_PART_FILES = 160
  MAX_PART_BYTES = 64 * 1024 * 1024
  MAX_REPORT_BYTES = 2 * 1024 * 1024

  class Failure < StandardError; end

  class Probe
    def initialize(binary:, helper:, helper_sha256:, evidence_root:, source_root: SOURCE_ROOT)
      @binary = validate_executable(binary, 'pinned ClickHouse')
      @helper = validate_executable(helper, 'prebuilt W271 helper')
      @helper_expected_sha = helper_sha256
      fail!('--helper-sha256 must be a lowercase SHA-256') unless @helper_expected_sha&.match?(/\A[0-9a-f]{64}\z/)
      @source_root = File.expand_path(source_root)
      fail!('source root differs from the pinned checkout') unless @source_root == SOURCE_ROOT
      @root = validate_root(evidence_root)
      @token = Digest::SHA256.hexdigest(@root)[0, 8]
      @invocations = []
      @runner = W241::Probe.allocate
      @runner.instance_variable_set(:@binary, @binary)
      @runner.instance_variable_set(:@root, @root)
      @runner.instance_variable_set(:@invocations, @invocations)
      @table_names = {}
      @stock = {}
      validate_literals!
    end

    def run
      prepare!
      MODES.each { |mode| @stock[mode] = capture_stock!(mode) }
      generated = {}
      %w[mrk3 mrk4].product(MODES).each do |mark_format, mode|
        generated["#{mark_format}_#{mode}"] = capture_generated!(mark_format, mode, @stock.fetch(mode))
      end
      mutant = qualify_child_dynamic_version_mutant!(generated.fetch('mrk4_basic'))
      validate_pins!
      summary = {
        format: FORMAT,
        status: 'stock_first_native_and_generated_matrix_and_child_dynamic_negative_captured',
        runtime_pin: {binary: @binary, sha256: @binary_sha_after, version: VERSION, build: BUILD},
        source_pin: {root: @source_root, revision: SOURCE_REVISION, upstream_sha256: @upstream_hashes},
        probe_sources: @probe_hashes_after,
        helper: {path: @helper, sha256: @helper_sha_after, source: HELPER_SOURCE},
        fixture: {
          root_column: COLUMN, declared_type: DECLARATION,
          literal_rows: ROWS.each_with_index.map { |value, index| {pk: index + 1, value: value} },
          expected_fixture_full_insert_parent_dynamic_json_shared_counts: [4, 0],
          expected_fixture_parent_dynamic_counts_per_mark: MARK_COUNTS,
          actual_dynamic_arm: 'ordinary JSON',
          native_child_json_path_types: {'value' => 'Int64'},
          expected_fixture_child_dynamic_int64_shared_counts: [4, 0],
          counter_provenance: 'fixture-derived expectations; not parsed from generated part bytes',
          local_uint8_baseline: {
            source: LOCAL_FIXTURE_SOURCE,
            child_layout: {'value' => 'UInt8'},
            claim_boundary: 'independent local behavioral baseline; not asserted as native stock layout equivalence',
          },
          sql_windows: SQL_WINDOWS,
          physical_mark_windows: PHYSICAL_WINDOWS,
          rows_per_mark: ROWS_PER_MARK, row_count: ROWS.size, mark_count: MARK_COUNT,
        },
        stock_mrk4: @stock,
        generated: generated,
        resealed_child_dynamic_version_negative: mutant,
        invocations: @invocations,
        evidence_root: @root,
        claim_boundary: 'Stock literal/type/shared-data/path observations and stock MRK4 callback rosters are captured before writer use. Generated MRK4 rosters are compared to the matching stock mode. Native ATTACH/CHECK/SELECT and local mark reads are separate observations. This does not establish production compatibility or treat candidate bytes as the semantic oracle.',
      }
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      write_new(File.join(@root, 'summary.md'), render_summary(summary))
      puts "W271 status=#{summary.fetch(:status)}; stock=2; generated=#{generated.size}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      persist_inconclusive(error)
      warn "W271 probe inconclusive: #{@fatal_error}"
      false
    end

    private

    MODES = %w[basic compact].freeze

    def fail!(message)
      raise Failure, "W271: #{message}"
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

    def validate_literals!
      fail!('literal census must contain exactly eight ordered primary keys') unless KEYS == (1..8).to_a
      fail!('literal census differs from selected-mark counts') unless
        ROWS.each_slice(ROWS_PER_MARK).map { |mark| mark.count { |value| !value.nil? } } == MARK_COUNTS
      fail!('physical mark windows differ from the four-mark grid') unless
        PHYSICAL_WINDOWS.values == [[0, 4], [1, 2], [1, 1], [3, 1], [4, 0]]
      true
    end

    def prepare!
      %w[invocations stores parts source-inventories raw-records].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      @binary_sha_before = sha(@binary)
      fail!('ClickHouse executable differs from pinned runtime SHA-256') unless @binary_sha_before == BINARY_SHA256
      revision, stderr, status = Open3.capture3('git', '-C', @source_root, 'rev-parse', 'HEAD')
      fail!("pinned source revision check failed: #{stderr.strip}") unless status.success? && revision.strip == SOURCE_REVISION
      @upstream_hashes = SOURCE_FILES.to_h do |relative|
        path = File.join(@source_root, relative)
        fail!("pinned upstream source is missing or symlinked: #{relative}") unless File.file?(path) && !File.symlink?(path)
        [relative, sha(path)]
      end
      @probe_sources = [File.realpath(__FILE__), W241_SOURCE, HELPER_SOURCE, FIXTURE_SOURCE, LOCAL_FIXTURE_SOURCE]
      @probe_hashes_before = @probe_sources.to_h { |path| [path, sha(path)] }
      @helper_sha_before = sha(@helper)
      fail!('prebuilt helper SHA differs from CLI pin') unless @helper_sha_before == @helper_expected_sha
    end

    def validate_pins!
      @binary_sha_after = sha(@binary)
      @helper_sha_after = sha(@helper)
      @probe_hashes_after = @probe_sources.to_h { |path| [path, sha(path)] }
      fail!('ClickHouse executable changed during the probe') unless @binary_sha_after == BINARY_SHA256
      fail!('prebuilt helper changed during the probe') unless @helper_sha_after == @helper_sha_before
      fail!('probe source changed during the probe') unless @probe_hashes_after == @probe_hashes_before
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
      result = @runner.send(:native, label, store, [@runner.send(:pin_sql), sql].join("\n"))
      record = result.fetch(:record)
      fail!("#{label} timed out or had process infrastructure failure") unless
        !record[:timed_out] && record[:spawn_error].nil? && record[:stdin_write_error].nil? &&
        record[:stdout_read_error].nil? && record[:stderr_read_error].nil? && result[:status] && result[:status].termsig.nil?
      accepted = allow_server_error ? %w[success server_exception] : ['success']
      fail!("#{label} native classification #{result[:classification]} is outside #{accepted.inspect}") unless accepted.include?(result[:classification])
      if result[:classification] == 'success'
        fail!("#{label} ClickHouse process failed") unless result[:status].success?
        @runner.send(:assert_native_success!, result, label)
        @runner.send(:assert_pin!, result[:stdout], label)
      else
        fail!("#{label} ClickHouse identity changed") unless record[:binary_sha_after] == BINARY_SHA256
        @runner.send(:assert_pin!, result[:stdout], label)
      end
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
      value = "__W271_#{kind.upcase}_#{id.upcase}"
      value += "_#{suffix.upcase}" if suffix
      "#{value}__"
    end

    def sql_string(value)
      "'#{value.to_s.gsub(/[\\']/) { |character| "\\#{character}" }}'"
    end

    def settings(mode, mark_format: 'mrk4')
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
        "object_shared_data_serialization_version_for_zero_level_parts='map'", 'object_shared_data_buckets_for_compact_part=1',
        "dynamic_serialization_version='v3'", "use_compact_variant_discriminators_serialization=#{discriminator}",
        'allow_suspicious_low_cardinality_types=1',
      ].join(', ')
    end

    def source_actual(value)
      return "CAST('{\"payload\":null}', #{sql_string(DECLARATION)})" if value.nil?
      json = JSON.generate({'value' => value})
      inner = "CAST(CAST(#{sql_string(json)}, 'JSON(max_dynamic_paths=0,max_dynamic_types=0,value UInt8)'), 'Dynamic(max_types=1)')"
      tuple = "CAST(tuple(#{inner}), 'Tuple(payload Dynamic(max_types=1))')"
      "CAST(#{tuple}, #{sql_string(DECLARATION)})"
    end

    def table_name(id)
      "w271_#{@token}_#{id}"
    end

    def stock_sql(mode, table)
      inserts = ROWS.each_with_index.map do |value, index|
        "SELECT toUInt64(#{index + 1}) AS pk, #{source_actual(value)} AS #{COLUMN}"
      end
      "SET flatten_nested=0;\n" \
        "CREATE TABLE default.#{table} (pk UInt64, `#{COLUMN}` #{DECLARATION}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings(mode)};\n" \
        "INSERT INTO default.#{table}\n#{inserts.join("\nUNION ALL\n")};\n"
    end

    def safe_native_path(raw, store, label)
      fail!("#{label} native path is not absolute") unless raw.is_a?(String) && raw.start_with?(File::SEPARATOR)
      path = raw.end_with?(File::SEPARATOR) ? raw[0...-1] : raw
      root = File.realpath(store)
      fail!("#{label} native path escaped its isolated store") unless path.start_with?(root + File::SEPARATOR)
      fail!("#{label} native path is not canonical") unless File.expand_path(path) == path && File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path
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
      fail!("#{id} is not exactly one Compact part with eight rows/four marks") unless parts.size == 1 &&
        parts.first.values_at(1, 2, 4, 5, 6) == [table, PART_NAME, 'Compact', '8', '5']
      path = safe_native_path(parts.first.fetch(3), store, id)
      selected = File.join(path, "data.#{mark_format}")
      other = File.join(path, mark_format == 'mrk4' ? 'data.mrk3' : 'data.mrk4')
      fail!("#{id} selected mark format differs") unless File.file?(selected) && !File.exist?(other)
      {table: table, path: path, schema: canonical_schema, part: parts.first, mark_format: mark_format}
    end

    def tree_inventory(path)
      files = []
      total = 0
      Find.find(path) do |entry|
        next if entry == path
        stat = File.lstat(entry)
        fail!("symlink in part tree: #{entry}") if stat.symlink?
        next if stat.directory?
        fail!("non-regular part file: #{entry}") unless stat.file?
        fail!('part file-count bound exceeded') if files.size >= MAX_PART_FILES
        total += stat.size
        fail!('part byte bound exceeded') if total > MAX_PART_BYTES
        files << {path: entry.delete_prefix(path + File::SEPARATOR), size: stat.size, sha256: sha(entry)}
      end
      {files: files.sort_by { |entry| entry.fetch(:path) }, total_bytes: total}
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
      fail!("#{id} one or more callbacks has no physical stream") unless sections.all? { |section| !section[1].empty? }
      {text: text, sections: sections, roster: sections.flat_map { |column, streams| streams.map { |stream| [column, stream] } },
       sha256: Digest::SHA256.hexdigest(text)}
    end

    def save_stock!(id, part, roster)
      inventory = tree_inventory(part)
      safe = id.gsub(/[^A-Za-z0-9_.-]/, '_')
      write_new(File.join(@root, 'source-inventories', "#{safe}.columns_substreams.txt"), roster.fetch(:text))
      write_new(File.join(@root, 'source-inventories', "#{safe}.json"), JSON.pretty_generate(
        case_name: id, source_part_path: part, inventory: inventory,
        callback_sections: roster.fetch(:sections), callback_roster: roster.fetch(:roster),
        columns_substreams_sha256: roster.fetch(:sha256),
      ) + "\n")
      %w[data.bin data.mrk4 serialization.json checksums.txt].each do |name|
        source = File.join(part, name)
        fail!("#{id} stock raw file is absent: #{name}") unless File.file?(source) && !File.symlink?(source)
        write_new(File.join(@root, 'raw-records', "#{safe}.#{name}"), File.binread(source))
      end
      inventory
    end

    def copy_part(source, destination)
      fail!('part copy destination already exists') if File.exist?(destination) || File.symlink?(destination)
      FileUtils.cp_r(source, destination, preserve: true)
      fail!('stock part copy differs from the source inventory') unless tree_inventory(source) == tree_inventory(destination)
      destination
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

    def native_child_json_window!(id, table, store)
      tag = marker('mutant_child_json', id)
      dynamic = "`#{COLUMN}`.payload"
      json_actual = "dynamicElement(#{dynamic}, 'JSON')"
      path_types = "JSONAllPathsWithTypes(#{json_actual})"
      sql = "SELECT '#{tag}', toString(pk), if(isNull(#{dynamic}), 'None', dynamicType(#{dynamic})), " \
        "if(isNull(#{dynamic}), 'false', if(isDynamicElementInSharedData(#{dynamic}), 'true', 'false')), " \
        "if(isNull(#{dynamic}), '6E756C6C', hex(toJSONString(#{json_actual}))), " \
        "if(isNull(#{dynamic}), '6E756C6C', hex(toJSONString(#{path_types}))) " \
        "FROM default.#{table} WHERE pk BETWEEN 5 AND 6 ORDER BY pk " \
        "SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;\n"
      result = native("#{id}_child_json_window", store, sql, allow_server_error: true)
      if result[:classification] == 'server_exception'
        return {state: 'server_exception', invocation: result.fetch(:record)}
      end

      rows = tagged(native_lines(result, "#{id} child JSON window"), tag, 6, id)
      actual = rows.map do |fields|
        [fields[1], fields[2], fields[3], decode_hex_json(fields[4], "#{id}/child JSON/payload"),
         decode_hex_json(fields[5], "#{id}/child JSON/path types")]
      end
      expected = [
        ['5', 'JSON', 'false', {'value' => 51}, {'value' => 'Int64'}],
        ['6', 'JSON', 'false', {'value' => 61}, {'value' => 'Int64'}],
      ]
      fail!("#{id} mutated child JSON window unexpectedly remained exact") if actual == expected
      {state: 'value_mismatch', rows: actual, invocation: result.fetch(:record)}
    end

    def qualify_child_dynamic_version_mutant!(generated)
      id = 'resealed_child_dynamic_version_mrk4_basic'
      source = generated.fetch(:part_path)
      source_inventory = generated.fetch(:source_inventory)
      fail!("#{id} MRK4 BASIC source changed before copy") unless tree_inventory(source) == source_inventory
      destination = File.join(@root, 'parts', id)
      mutation = helper("#{id}_mutation", 'copy-child-dynamic-version-mutant', 'resealed', source,
                        destination, '2')
      expected_stream = "#{COLUMN}.payload.JSON.value.dynamic_structure"
      {
        'source_path' => source, 'mutant_path' => destination, 'column' => COLUMN,
        'stream' => expected_stream, 'mark' => 2, 'semantic_type' => 'Dynamic(Int64)',
        'version_before' => 4, 'version_after' => 5, 'raw_changed_offsets' => [mutation.fetch('logical_offset')],
        'compressed_size_before' => mutation.fetch('compressed_size_before'),
        'compressed_size_after' => mutation.fetch('compressed_size_before'), 'checksums_resealed' => true,
      }.each do |key, value|
        fail!("#{id} mutation metadata #{key} differs: #{mutation[key].inspect}") unless mutation[key] == value
      end

      fail!("#{id} source part changed during copy mutation") unless tree_inventory(source) == source_inventory
      mutant_inventory = tree_inventory(destination)
      original_files = source_inventory.fetch(:files).to_h { |entry| [entry.fetch(:path), entry] }
      mutant_files = mutant_inventory.fetch(:files).to_h { |entry| [entry.fetch(:path), entry] }
      changed_files = (original_files.keys | mutant_files.keys).select do |path|
        original_files[path] != mutant_files[path]
      end.sort
      fail!("#{id} changed files are not exactly data.bin/checksums.txt: #{changed_files.inspect}") unless
        changed_files == %w[checksums.txt data.bin]

      local = helper("#{id}_local_reject", 'read-native', destination, '2', '1', expected_statuses: ['rejected'])
      fail!("#{id} local read did not reject as CorruptPartError: #{local.inspect}") unless
        local.fetch('error_class') == 'CrystalClick::CorruptPartError'

      target = create_target!(id, 'basic', 'mrk4')
      attach = attach_copy!(id, destination, target)
      active_part = native_part!("#{id}_attached", target.fetch(:table), target.fetch(:store), mark_format: 'mrk4')
      active = attached_inventory!(id, active_part.fetch(:path), mutant_inventory)
      check = check!(id, target.fetch(:table), target.fetch(:store))
      fail!("#{id} native CHECK was not healthy") unless check.fetch(:state) == 'healthy'
      pk_control = native_pk_control!(id, target.fetch(:table), target.fetch(:store))
      child_window = native_child_json_window!(id, target.fetch(:table), target.fetch(:store))
      fail!("#{id} native child JSON window neither rejected nor differed") unless
        %w[server_exception value_mismatch].include?(child_window.fetch(:state))
      fail!("#{id} source part changed during native checks") unless tree_inventory(source) == source_inventory

      {
        mutation: mutation, changed_relative_paths: changed_files,
        source_inventory_unchanged: true, mutant_inventory: mutant_inventory,
        local_read: local, native_target: target, native_attach: attach,
        active_part: {path: active_part.fetch(:path), **active}, native_check: check,
        unaffected_pk_control: pk_control, selected_child_json_window: child_window,
        claim_boundary: 'copy-only same-extent checksum-resealed negative; generated output remains a diagnostic, not a semantic oracle',
      }
    end

    def decode_hex_json(value, label)
      fail!("#{label} malformed JSON hex") unless value.match?(/\A(?:[0-9a-f]{2})*\z/i)
      JSON.parse([value].pack('H*'))
    rescue JSON::ParserError => error
      fail!("#{label} invalid JSON payload: #{error.message}")
    end

    def expected_value_rows(window)
      selected = case window
                 when 'full' then KEYS
                 when 'middle' then (3..6).to_a
                 when 'zero_arm' then (3..4).to_a
                 when 'last' then (7..8).to_a
                 else []
                 end
      selected.map do |pk|
        value = ROWS.fetch(pk - 1)
        if value.nil?
          [pk.to_s, 'None', 'false', nil, nil]
        else
          [pk.to_s, 'JSON', 'false', {'value' => value}, {'value' => 'Int64'}]
        end
      end
    end

    def value_window_sql(table, id, window)
      tag = marker('values', id, window)
      predicate = SQL_WINDOWS.fetch(window)
      if window == 'empty'
        return "SELECT '#{tag}', toString(count()) FROM default.#{table} WHERE #{predicate} FORMAT TSVRaw;\n"
      end
      column = "`#{COLUMN}`"
      dynamic = "#{column}.payload"
      json_actual = "dynamicElement(#{dynamic}, 'JSON')"
      path_types = "JSONAllPathsWithTypes(#{json_actual})"
      where = predicate ? " WHERE #{predicate}" : ''
      "SELECT '#{tag}', toString(pk), if(isNull(#{dynamic}), 'None', dynamicType(#{dynamic})), " \
        "if(isNull(#{dynamic}), 'false', if(isDynamicElementInSharedData(#{dynamic}), 'true', 'false')), " \
        "if(isNull(#{dynamic}), '6E756C6C', hex(toJSONString(#{json_actual}))), " \
        "if(isNull(#{dynamic}), '6E756C6C', hex(toJSONString(#{path_types}))) " \
        "FROM default.#{table}#{where} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;\n"
    end

    def native_values!(id, table, store)
      result = {}
      SQL_WINDOWS.each_key do |window|
        invocation = native("#{id}_select_#{window}", store, value_window_sql(table, id, window))
        lines = native_lines(invocation, "#{id} #{window} SELECT")
        tag = marker('values', id, window)
        if window == 'empty'
          rows = tagged(lines, tag, 2, id)
          exact = rows == [[tag, '0']]
          result[window] = {state: exact ? 'exact_values' : 'value_mismatch', row_count: 0,
                            rows: rows, invocation: invocation.fetch(:record)}
          fail!("#{id} empty SQL window differs") unless exact
          next
        end
        rows = tagged(lines, tag, 6, id)
        actual = rows.map do |fields|
          [fields[1], fields[2], fields[3], decode_hex_json(fields[4], "#{id}/#{window}/payload"),
           decode_hex_json(fields[5], "#{id}/#{window}/path types")]
        end
        expected = expected_value_rows(window)
        exact = actual == expected
        result[window] = {state: exact ? 'exact_values' : 'value_mismatch', row_count: rows.size,
                          rows: actual, invocation: invocation.fetch(:record)}
        fail!("#{id} #{window} SQL literal/type/shared/path rows differ: #{actual.inspect}") unless exact
      end
      result
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

    def expected_signatures(first_mark, mark_count)
      ROWS.slice(first_mark * ROWS_PER_MARK, mark_count * ROWS_PER_MARK).map do |value|
        {'payload' => (value.nil? ? nil : {'value' => value})}
      end
    end

    def local_windows!(id, part)
      PHYSICAL_WINDOWS.to_h do |window, (first, count)|
        report = helper("#{id}_local_#{window}", 'read-native', part, first.to_s, count.to_s,
                        expected_statuses: ['accepted'])
        expected = expected_signatures(first, count)
        exact = report.fetch('row_count') == expected.size && report.fetch('signatures') == expected
        fail!("#{id} local #{window} mark window differs: #{report.inspect}") unless exact
        [window, {first_mark: first, mark_count: count, state: 'exact_values',
                  row_count: report.fetch('row_count'), signatures: report.fetch('signatures')}]
      end
    end

    def capture_stock!(mode)
      id = "stock_mrk4_#{mode}"
      table = table_name(id)
      store = store_path("native_#{id}")
      create = native("#{id}_create_insert", store, stock_sql(mode, table))
      part = native_part!(id, table, store, mark_format: 'mrk4')
      roster = parse_roster!(id, part.fetch(:path))
      inventory = save_stock!(id, part.fetch(:path), roster)
      copy = File.join(@root, 'parts', id)
      copied_part = copy_part(part.fetch(:path), copy)
      check = check!(id, table, store)
      values = native_values!(id, table, store)
      readers = local_windows!(id, copied_part)
      fail!("#{id} native stock part changed during capture") unless tree_inventory(part.fetch(:path)) == inventory
      {
        source: 'fresh pinned ClickHouse stock part, captured before generated writer use',
        mode: mode, table: table, store: store, native_source_path: part.fetch(:path),
        copied_part_path: copied_part, source_inventory: inventory,
        callback_sections: roster.fetch(:sections), callback_roster: roster.fetch(:roster),
        columns_substreams_sha256: roster.fetch(:sha256), create_insert: create.fetch(:record),
        check: check, native_literal_selects: values, local_physical_mark_reads: readers,
      }
    end

    def helper_write!(id, destination, mark_format, mode)
      report = helper("#{id}_writer", 'write-native', destination, mark_format, mode)
      expected = {
        'part_path' => destination, 'row_count' => ROWS.size, 'mark_count' => MARK_COUNT,
        'rows_per_mark' => ROWS_PER_MARK, 'mark_format' => mark_format,
        'discriminator_mode' => mode, 'column' => COLUMN,
        'declared_schema' => HELPER_DECLARATION, 'dynamic_actual_type' => 'JSON',
        'expected_fixture_dynamic_counts_json_shared' => [4, 0], 'child_object_path_types' => {'value' => 'Int64'},
        'expected_fixture_child_dynamic_counts_int64_shared' => [4, 0], 'expected_fixture_mark_arm_counts' => MARK_COUNTS,
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
      detached_inventory = tree_inventory(detached)
      fail!("#{id} detached part differs from source") unless detached_inventory == source_inventory
      invocation = native("#{id}_attach", target.fetch(:store), "ALTER TABLE default.#{target.fetch(:table)} ATTACH PART '#{PART_NAME}';\n")
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
        matching_stock_mrk4_roster_sha256: stock.fetch(:columns_substreams_sha256),
        generated_mrk4_roster_sha256: roster.fetch(:sha256),
        local_physical_mark_reads: local, native_target: target, native_attach: attach,
        active_part: {path: attached_part.fetch(:path), **attached},
        native_check: check, native_literal_selects: values,
      }
    end

    def render_summary(summary)
      lines = [
        '# W271 Compact typed-Dynamic JSON probe', '',
        "Status: `#{summary.fetch(:status)}`",
        "Runtime: `#{summary.fetch(:runtime_pin).fetch(:version)}` build `#{summary.fetch(:runtime_pin).fetch(:build)}` SHA `#{summary.fetch(:runtime_pin).fetch(:sha256)}`.",
        "Source: `#{summary.fetch(:source_pin).fetch(:revision)}` at `#{summary.fetch(:source_pin).fetch(:root)}`.",
        "Fixture: eight rows, four two-row marks, literals `#{ROWS.inspect}`, expected fixture mark counts `#{MARK_COUNTS.inspect}`.",
        'Native actual is ordinary JSON; child path `value` is checked as Int64. The local UInt8 fixture is a distinct baseline, not a stock-layout equivalence claim. Fixture counters are expected censuses, not parsed on-disk statistics.',
        'The generated MRK4 BASIC child-version mutant is a copy-only checksum-resealed diagnostic. It is admitted only if compressed frame extents remain unchanged; frame-size drift leaves the probe inconclusive.',
        '', 'The machine-readable report contains the stock-first MRK4 captures, generated MRK3/MRK4 × BASIC/COMPACT matrix, SQL windows, physical mark reads, inventories, and the isolated semantic negative.',
        '', summary.fetch(:claim_boundary), '',
      ]
      lines.join("\n")
    end

    def persist_inconclusive(error)
      return unless @root && File.directory?(File.join(@root, 'invocations'))
      report = {
        format: FORMAT, status: 'inconclusive_or_observations_differ', fatal_error: @fatal_error,
        error_class: error.class.name, runtime_pin: {expected_sha256: BINARY_SHA256, observed_sha256: (sha(@binary) rescue nil)},
        source_pin: {root: @source_root, expected_revision: SOURCE_REVISION},
        invocations: @invocations, evidence_root: @root,
        claim_boundary: 'A failed process, malformed output, mismatch, or unsupported native behavior is not silently converted into a format conclusion.',
      }
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(report) + "\n") unless File.exist?(File.join(@root, 'summary.json'))
    rescue StandardError
      nil
    end
  end
end

if __FILE__ == $PROGRAM_NAME
options = {
  binary: ProbeCompactPartWriterW271::BINARY,
  source_root: ProbeCompactPartWriterW271::SOURCE_ROOT,
}
OptionParser.new do |parser|
  parser.banner = 'Usage: ruby scripts/probe_compact_part_writer_w271.rb --helper PATH --helper-sha256 SHA256 --evidence-root EMPTY_DIR'
  parser.on('--binary PATH', 'Pinned ClickHouse executable') { |value| options[:binary] = value }
  parser.on('--source-root PATH', 'Pinned source checkout') { |value| options[:source_root] = value }
  parser.on('--helper PATH', 'Prebuilt W271 Crystal helper') { |value| options[:helper] = value }
  parser.on('--helper-sha256 SHA256', 'Expected SHA-256 of the helper executable') { |value| options[:helper_sha256] = value }
  parser.on('--evidence-root EMPTY_DIR', 'Existing empty direct child of /private/tmp') { |value| options[:evidence_root] = value }
end.parse!

%i[helper helper_sha256 evidence_root].each do |name|
  abort("missing --#{name.to_s.tr('_', '-')}") unless options[name]
end

probe = ProbeCompactPartWriterW271::Probe.new(**options)
exit(probe.run ? 0 : 1)
end
