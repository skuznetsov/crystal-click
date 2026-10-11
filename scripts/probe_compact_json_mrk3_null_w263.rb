#!/usr/bin/env ruby
# Captures a bounded stock Compact MRK3 JSON part with a Dynamic NULL arm.
# A sibling COMPACT-Variant table is retained as a refusal-only control; this
# runner captures stock evidence and does not claim Crystal reader admission.

require 'digest'
require 'find'
require 'json'
require 'open3'
require 'optparse'
require_relative 'stock_part_probe_support_w191'

module ProbeCompactJSONMRK3NullW263
  FORMAT = 'compact_json_mrk3_null_w263_native_manifest_v1'.freeze
  BINARY = '/private/tmp/crystal-click-w263-runtime-recovery.B9uAPX/clickhouse-stripped'.freeze
  BINARY_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  VERSION = '26.10.1.1201'.freeze
  BUILD = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  SOURCE_SNAPSHOT = {
    path: '/private/tmp/clickhouse-w254-upstream.AqeqyC',
    revision: 'ed30948f095ecb70679986d7d60e27ad770ae27a',
    runtime_provenance_claimed: false,
  }.freeze
  JSON_TYPE = 'JSON(max_dynamic_types=1, max_dynamic_paths=2, id UInt8, label String)'.freeze
  NATIVE_NULL_DYNAMIC_TYPE = 'None'.freeze
  TABLES = {basic: 'w263n_mrk3_basic', compact: 'w263n_mrk3_compact'}.freeze
  SCHEMA = [['pk', 'UInt64'], ['root', JSON_TYPE]].map(&:freeze).freeze
  MARK_ROWS = [2, 2].freeze
  ROWS = [
    {pk: 1, id: 1, label: 'r1', maybe: 'alpha'},
    {pk: 2, id: 2, label: 'r2', maybe: nil},
    {pk: 3, id: 3, label: 'r3', maybe: nil},
    {pk: 4, id: 4, label: 'r4', maybe: nil},
  ].map(&:freeze).freeze
  TAG = {
    pin: '__W263N_PIN__', check_begin: '__W263N_CHECK_BEGIN__',
    check_end: '__W263N_CHECK_END__', schema: '__W263N_SCHEMA__',
    part: '__W263N_PART__', row: '__W263N_ROW__',
  }.freeze
  MAX_CAPTURE_BYTES = 2 * 1024 * 1024
  MAX_PART_FILES = 256
  MAX_PART_BYTES = 16 * 1024 * 1024
  W185 = CheckArrayJSONPartsW185

  class Failure < StandardError; end

  class Probe
    def initialize(binary:, evidence_root:)
      @binary = validate_executable(binary)
      @root = validate_root(evidence_root)
      @capture = StockPartProbeSupportW191.new(@binary, @root)
      @store = File.join(@root, 'stores', 'native')
      @source_files = [
        File.expand_path(__FILE__),
        File.expand_path('stock_part_probe_support_w191.rb', __dir__),
        File.expand_path('check_array_json_parts_w185.rb', __dir__),
        File.expand_path('check_json_binary_kernel_w180.rb', __dir__),
        File.expand_path('probe_json_array_storage_w183.rb', __dir__),
      ].map { |path| File.realpath(path) }.uniq.sort
      @invocations = []
      @stage = 'not_started'
    end

    def run
      prepare_layout!
      verify_runtime_before!
      verify_source_before!

      @stage = 'stock BASIC and COMPACT sibling MRK3 tables'
      native = run_native(initial_sql)
      assert_native_success!(native)
      observations = parse_native(native[:stdout])
      assert_pin!(observations.fetch(:pin))
      assert_observations!(observations)

      parts = TABLES.to_h do |mode, table|
        native_part = observations.fetch(:parts).fetch(mode)
        path = validate_part_path!(native_part.fetch(:path))
        [mode, inspect_part(mode, path, native_part)]
      end

      # The native process is already closed. Take a second exact inventory
      # after all readers/queries have exited so the manifest records stable
      # stock artifacts rather than a live-writer snapshot.
      parts.each do |mode, part|
        after_close = file_snapshot(part.fetch(:path))
        fail!("#{mode} part inventory changed after ClickHouse closed") unless after_close == part.fetch(:file_inventory)
        part[:post_close_file_inventory] = after_close
      end

      verify_runtime_after!
      verify_source_after!

      manifest = {
        format: FORMAT,
        status: 'stock_native_capture_observed',
        scope: 'two stock Compact MRK3 Object-v1/Dynamic-v1/MAP tables; BASIC is the target and COMPACT is refusal-only',
        row_count: ROWS.size,
        mark_rows: MARK_ROWS,
        pins: {
          runtime: {
            path: @binary, expected_sha256: BINARY_SHA256,
            observed_sha256_before: @binary_sha_before,
            observed_sha256_after: @binary_sha_after,
            version: VERSION, build: BUILD,
          },
          source: {
            path: SOURCE_SNAPSHOT.fetch(:path),
            expected_revision: SOURCE_SNAPSHOT.fetch(:revision),
            observed_revision_before: @source_revision_before,
            observed_revision_after: @source_revision_after,
            tracked_worktree_clean_before: @source_clean_before,
            tracked_worktree_clean_after: @source_clean_after,
            runtime_provenance_claimed: false,
          },
        },
        native_invocation: native.fetch(:record),
        checks: observations.fetch(:checks),
        schema: observations.fetch(:schema),
        rows: observations.fetch(:rows),
        parts: parts,
        source_hashes: @source_hashes_before,
        part_quiescence: {
          native_process_closed_before_inventory: true,
          post_close_inventory_equal: true,
          note: 'Each part was inventoried after the single native process exited and re-inventoried before manifest publication.',
        },
      }
      write_new(File.join(@root, 'native_manifest.json'), JSON.pretty_generate(manifest) + "\n")
      puts "W263 MRK3 NULL stock capture observed; tables=#{TABLES.keys.join(',')}; rows=#{ROWS.size}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @binary_sha_after = sha(@binary) rescue nil
      @source_revision_after = source_revision rescue nil
      warn "W263 MRK3 NULL #{@stage} failed: #{@fatal_error}"
      write_new(File.join(@root, 'failure.json'), JSON.pretty_generate({
        format: 'compact_json_mrk3_null_w263_native_failure_v1',
        stage: @stage, error: @fatal_error,
        binary_sha_before: @binary_sha_before, binary_sha_after: @binary_sha_after,
        source_revision_before: @source_revision_before, source_revision_after: @source_revision_after,
        invocations: @invocations,
      }) + "\n") rescue nil
      false
    end

    private

    def fail!(message)
      raise Failure, "W263 Compact MRK3 NULL probe: #{message}"
    end

    def validate_root(path)
      fail!('evidence root is required') unless path && !path.empty?
      expanded = File.expand_path(path)
      fail!('evidence root must be a direct child of /private/tmp') unless
        File.dirname(expanded) == File.realpath('/private/tmp')
      fail!('evidence root must not be symlinked') if File.symlink?(expanded)
      fail!('evidence root must be an existing empty canonical directory') unless
        File.directory?(expanded) && File.realpath(expanded) == expanded && Dir.children(expanded).empty?
      expanded
    rescue Errno::ENOENT
      fail!('evidence root must already exist')
    end

    def validate_executable(path)
      fail!('pinned ClickHouse path is required') unless path && !path.empty?
      expanded = File.expand_path(path)
      fail!('pinned ClickHouse is missing, non-executable or symlinked') unless
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

    def source_revision
      stdout, stderr, status = Open3.capture3('git', '-C', SOURCE_SNAPSHOT.fetch(:path), 'rev-parse', 'HEAD')
      fail!("cannot read pinned ClickHouse source revision: #{stderr.strip}") unless status.success? && stderr.empty?
      stdout.strip
    end

    def source_clean?
      stdout, stderr, status = Open3.capture3('git', '-C', SOURCE_SNAPSHOT.fetch(:path), 'status', '--porcelain', '--untracked-files=no')
      fail!("cannot inspect pinned ClickHouse source status: #{stderr.strip}") unless status.success? && stderr.empty?
      stdout.empty?
    end

    def source_hashes
      @source_files.map { |path| {path: path, sha256: sha(path)} }
    end

    def verify_source_before!
      fail!('pinned source snapshot is missing or symlinked') unless
        File.directory?(SOURCE_SNAPSHOT.fetch(:path)) && !File.symlink?(SOURCE_SNAPSHOT.fetch(:path))
      @source_revision_before = source_revision
      fail!('pinned ClickHouse source revision differs') unless @source_revision_before == SOURCE_SNAPSHOT.fetch(:revision)
      @source_clean_before = source_clean?
      fail!('pinned ClickHouse source has tracked modifications') unless @source_clean_before
      @source_hashes_before = source_hashes
    end

    def verify_source_after!
      @source_revision_after = source_revision
      @source_clean_after = source_clean?
      @source_hashes_after = source_hashes
      fail!('pinned ClickHouse source revision changed during capture') unless @source_revision_after == @source_revision_before
      fail!('pinned ClickHouse source tracked worktree changed during capture') unless @source_clean_after == @source_clean_before
      fail!('probe source scripts changed during capture') unless @source_hashes_after == @source_hashes_before
    end

    def verify_runtime_before!
      @binary_sha_before = sha(@binary)
      fail!('pinned ClickHouse SHA-256 differs before capture') unless @binary_sha_before == BINARY_SHA256
    end

    def verify_runtime_after!
      @binary_sha_after = sha(@binary)
      fail!('pinned ClickHouse SHA-256 differs after capture') unless @binary_sha_after == BINARY_SHA256
      fail!('pinned ClickHouse binary changed during capture') unless @binary_sha_after == @binary_sha_before
    end

    def run_native(sql)
      write_new(File.join(@root, 'invocations', 'stock_mrk3_null.stdin.sql'), sql.b)
      argv = [@binary, 'local', '--path', @store, '--session_timezone=UTC', '--max_threads=1',
              "--max_memory_usage=#{W185::MEMORY}", '--output_format_json_quote_64bit_integers=0', '--multiquery']
      invocation = @capture.send(:execute_record, 'stock_mrk3_null', argv, sql.b,
                                 'clickhouse local', BINARY_SHA256, @binary)
      @invocations << invocation.fetch(:record)
      fail!('ClickHouse stdout exceeds capture bound') if invocation.fetch(:stdout).bytesize > MAX_CAPTURE_BYTES
      fail!('ClickHouse stderr exceeds capture bound') if invocation.fetch(:stderr).bytesize > MAX_CAPTURE_BYTES
      invocation
    end

    def assert_native_success!(invocation)
      unless invocation[:classification] == 'success' && invocation[:status]&.success? && invocation[:status]&.termsig.nil?
        fail!('ClickHouse process did not exit successfully')
      end
      fail!('ClickHouse wrote stderr') unless invocation[:stderr].empty?
    end

    def assert_pin!(records)
      expected = [VERSION, BUILD]
      fail!("runtime version/build marker differs: #{records.inspect}") unless records == [expected]
    end

    def parse_native(stdout)
      lines = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      fail!('ClickHouse stdout is invalid UTF-8') unless lines.all?(&:valid_encoding?)
      records = ->(tag) { lines.select { |line| line.start_with?("#{tag}\t") }.map { |line| line.split("\t", -1) } }

      checks = {}
      active = nil
      lines.each do |line|
        if line.start_with?("#{TAG[:check_begin]}\t")
          fields = line.split("\t", -1)
          mode = TABLES.key(fields.fetch(1)) if fields.size == 2
          fail!('malformed, duplicate or nested CHECK begin') unless mode && !checks.key?(mode) && active.nil?
          active = mode
          checks[active] = []
        elsif line.start_with?("#{TAG[:check_end]}\t")
          fields = line.split("\t", -1)
          mode = TABLES.key(fields.fetch(1)) if fields.size == 2
          fail!('malformed or mismatched CHECK end') unless mode && active == mode
          active = nil
        elsif active
          checks.fetch(active) << line
        end
      end
      fail!('unterminated CHECK block') if active

      parts = records.call(TAG[:part]).to_h do |fields|
        fail!('malformed system.parts row') unless fields.size == 7
        mode = TABLES.key(fields.fetch(1))
        fail!("unexpected system.parts table #{fields.fetch(1).inspect}") unless mode
        [mode, {table: fields[1], name: fields[2], path: fields[3], type: fields[4], rows: fields[5], marks: fields[6]}]
      end
      schema = records.call(TAG[:schema]).map do |fields|
        fail!('malformed system.columns row') unless fields.size == 4
        fields.drop(1)
      end
      rows = records.call(TAG[:row]).map do |fields|
        fail!('malformed row observation') unless fields.size == 11
        {
          table: fields[1], pk: fields[2], id: fields[3], label_hex: fields[4],
          maybe_type: fields[5], maybe_value_hex: fields[6],
          maybe_json_hex: fields[7], dynamic_paths_hex: fields[8],
          shared_paths_hex: fields[9], root_json_hex: fields[10],
        }
      end
      fail!('unexpected native marker records') unless
        lines.grep(/\A__W263N_/).all? { |line| TAG.values.include?(line.split("\t", 2).first) }
      pin = records.call(TAG[:pin]).map { |fields| fields.drop(1) }
      {pin: pin, checks: checks, parts: parts, schema: schema, rows: rows}
    rescue IndexError => error
      fail!("native TSV row is truncated: #{error.message}")
    end

    def assert_observations!(native)
      fail!('native part roster differs') unless native.fetch(:parts).keys.sort == TABLES.keys.sort
      fail!('CHECK roster differs') unless native.fetch(:checks).keys.sort == TABLES.keys.sort
      TABLES.each_key do |mode|
        fail!("#{mode} CHECK did not report one valid stock part") unless
          native.fetch(:checks).fetch(mode) == ["all_1_1_0\t1\t"]
      end
      expected_schema = TABLES.values.sort.flat_map do |table|
        SCHEMA.map { |name, type| [table, name, type] }
      end
      fail!('native schema differs from the independent declaration') unless native.fetch(:schema) == expected_schema
      fail!('native row count differs from two tables x four literals') unless native.fetch(:rows).size == TABLES.size * ROWS.size

      expected_rows = TABLES.values.product(ROWS).to_h do |table, row|
        ["#{table}|#{row.fetch(:pk)}", [row.fetch(:id).to_s, row.fetch(:label), row.fetch(:maybe)]]
      end
      actual_rows = native.fetch(:rows).to_h do |row|
        table = TABLES.values.find { |name| name == row.fetch(:table) }
        fail!("unexpected row table #{row.fetch(:table).inspect}") unless table
        pk = Integer(row.fetch(:pk), 10)
        key = "#{table}|#{pk}"
        label = decode_hex_string(row.fetch(:label_hex), "#{key} label")
        # This pinned runtime displays its internal Dynamic Nothing arm as
        # `None`; keep that observed native spelling distinct here.
        maybe_value = if row.fetch(:maybe_type) == NATIVE_NULL_DYNAMIC_TYPE
                        nil
                      elsif row.fetch(:maybe_type) == 'String'
                        decode_hex_string(row.fetch(:maybe_value_hex), "#{key} maybe")
                      else
                        fail!("#{key} has unexpected Dynamic type #{row.fetch(:maybe_type).inspect}")
                      end
        paths = parse_hex_json_array(row.fetch(:dynamic_paths_hex), "#{key} JSONDynamicPaths")
        shared = parse_hex_json_array(row.fetch(:shared_paths_hex), "#{key} JSONSharedDataPaths")
        maybe_json = parse_hex_json(row.fetch(:maybe_json_hex), "#{key} maybe JSON value")
        decoded_root = parse_hex_json_object(row.fetch(:root_json_hex), "#{key} root JSON")
        [key, {
          table: table, pk: pk, id: Integer(row.fetch(:id), 10), label: label,
          maybe_type: row.fetch(:maybe_type), maybe_value: maybe_value,
          maybe_json: maybe_json, dynamic_paths: paths, shared_paths: shared, root_json: decoded_root,
        }]
      end
      fail!('native row identities differ from independent four-row literals') unless actual_rows.keys.sort == expected_rows.keys.sort
      expected_rows.each do |key, (id, label, maybe)|
        actual = actual_rows.fetch(key)
        expected_type = maybe.nil? ? NATIVE_NULL_DYNAMIC_TYPE : 'String'
        fail!("#{key} typed id/label differs") unless actual.values_at(:id, :label) == [Integer(id, 10), label]
        fail!("#{key} Dynamic type/Nothing semantics differ") unless actual.fetch(:maybe_type) == expected_type && actual.fetch(:maybe_value) == maybe
        fail!("#{key} JSONDynamicPaths differs") unless actual.fetch(:dynamic_paths) == (maybe.nil? ? [] : ['maybe'])
        fail!("#{key} JSONSharedDataPaths is not empty") unless actual.fetch(:shared_paths).empty?
        fail!("#{key} JSON value differs") unless actual.fetch(:maybe_json) == maybe
        expected_root = {'id' => Integer(id, 10), 'label' => label}
        expected_root['maybe'] = maybe unless maybe.nil?
        fail!("#{key} root JSON fields differ") unless actual.fetch(:root_json) == expected_root
      end
      TABLES.values.each do |table|
        %w[1 2 3 4].each do |pk|
          key = "#{table}|#{pk}"
          row = actual_rows.fetch(key)
          raw = native.fetch(:rows).find { |entry| entry.fetch(:table) == table && entry.fetch(:pk) == pk }
          row[:native_root_json_hex] = raw.fetch(:root_json_hex)
        end
      end
      native[:rows] = actual_rows.sort.to_h.values
      native.fetch(:parts).each do |mode, part|
        fail!("#{mode} part identity/grid differs") unless
          part.values_at(:name, :type, :rows, :marks) == ['all_1_1_0', 'Compact', '4', '3']
      end
    end

    def inspect_part(mode, path, part)
      fail!("#{mode} part is absent or linked") unless File.directory?(path) && !File.symlink?(path)
      files = file_snapshot(path)
      names = files.map { |file| file.fetch(:path) }
      required = %w[columns.txt count.txt checksums.txt primary.idx serialization.json default_compression_codec.txt metadata_version.txt data.bin data.mrk3]
      required.each { |name| fail!("#{mode} part lacks #{name}") unless names.include?(name) }
      fail!("#{mode} part unexpectedly has a substream mark roster") if names.include?('columns_substreams.txt')
      fail!("#{mode} part has marks other than PlainMRK3") unless names.grep(/\.c?mrk\d*\z/) == ['data.mrk3']
      fail!("#{mode} part has unexpected binary lanes") unless names.grep(/\.bin\z/) == ['data.bin']
      fail!("#{mode} count.txt differs") unless File.binread(File.join(path, 'count.txt')) == '4'
      fail!("#{mode} default compression differs") unless
        File.binread(File.join(path, 'default_compression_codec.txt')).strip == 'CODEC(LZ4)'
      serialization = JSON.parse(File.binread(File.join(path, 'serialization.json')))
      fail!("#{mode} metadata is not with-types") unless serialization['version'] == 1
      fail!("#{mode} nested String serialization is not effective v0") unless
        serialization['propagate_types_serialization_versions_to_nested_types'] == true &&
        serialization.fetch('types_serialization_versions', {}).fetch('string', 0) == 0
      fail!("#{mode} part is not Compact") unless part.fetch(:type) == 'Compact'
      {
        table: part.fetch(:table), path: path,
        part_name: part.fetch(:name), part_type: part.fetch(:type),
        rows: Integer(part.fetch(:rows), 10), marks: Integer(part.fetch(:marks), 10),
        data_format: 'PlainMRK3', dynamic_variant_mode: mode.to_s,
        serialization: serialization,
        file_inventory: files,
      }
    rescue JSON::ParserError => error
      fail!("#{mode} serialization.json is malformed: #{error.message}")
    end

    def validate_part_path!(path)
      fail!('native part path is empty') unless path && !path.empty?
      full = File.expand_path(path)
      fail!("native part escaped isolated store: #{path}") unless full.start_with?(@store + File::SEPARATOR)
      full
    end

    def file_snapshot(path)
      files = []
      total = 0
      Find.find(path) do |entry|
        stat = File.lstat(entry)
        fail!("native part contains symlink #{entry}") if stat.symlink?
        next if entry == path || stat.directory?
        relative = entry.delete_prefix(path + File::SEPARATOR)
        total += stat.size
        fail!('native part inventory exceeds configured bounds') if total > MAX_PART_BYTES || files.size >= MAX_PART_FILES
        files << {path: relative, bytes: stat.size, sha256: sha(entry)}
      end
      files.sort_by { |file| file.fetch(:path) }
    end

    def parse_hex_json_array(value, label)
      parsed = parse_hex_json(value, label)
      fail!("#{label} is not an array of path names") unless parsed.is_a?(Array) && parsed.all? { |item| item.is_a?(String) }
      parsed
    end

    def parse_hex_json_object(value, label)
      parsed = parse_hex_json(value, label)
      fail!("#{label} is not an object") unless parsed.is_a?(Hash)
      parsed
    end

    def parse_hex_json(value, label)
      fail!("#{label} is not even-width hexadecimal") unless /\A(?:[0-9a-fA-F]{2})*\z/.match?(value)
      text = [value].pack('H*').force_encoding(Encoding::UTF_8)
      fail!("#{label} is invalid UTF-8") unless text.valid_encoding?
      JSON.parse(text)
    rescue JSON::ParserError => error
      fail!("#{label} is invalid JSON: #{error.message}")
    end

    def decode_hex_string(value, label)
      fail!("#{label} is not even-width hexadecimal") unless /\A(?:[0-9a-fA-F]{2})*\z/.match?(value)
      text = [value].pack('H*').force_encoding(Encoding::UTF_8)
      fail!("#{label} is invalid UTF-8") unless text.valid_encoding?
      text
    end

    def initial_sql
      statements = [
        'SET merge_tree_use_v1_object_and_dynamic_serialization=0;',
        'SET flatten_nested=0;',
        'SET print_pretty_type_names=0;',
        "SELECT '#{TAG[:pin]}', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
      ]
      TABLES.each do |mode, table|
        statements << "CREATE TABLE default.#{table} (pk UInt64, root #{JSON_TYPE}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings_for(mode)};"
        values = ROWS.map do |row|
          document = JSON.generate(row.reject { |key, _| key == :pk })
          "(toUInt64(#{row.fetch(:pk)}), CAST(#{sql_string(document)}, #{sql_string(JSON_TYPE)}))"
        end
        statements << "INSERT INTO default.#{table} VALUES\n#{values.join(",\n")};"
        statements << "SELECT '#{TAG[:check_begin]}', '#{table}' FORMAT TSVRaw;"
        statements << "CHECK TABLE default.#{table} FORMAT TSV;"
        statements << "SELECT '#{TAG[:check_end]}', '#{table}' FORMAT TSVRaw;"
      end
      table_list = TABLES.values.map { |table| sql_string(table) }.join(', ')
      statements << "SELECT '#{TAG[:schema]}', table, name, type FROM system.columns WHERE database='default' AND table IN (#{table_list}) ORDER BY table, position FORMAT TSVRaw;"
      statements << "SELECT '#{TAG[:part]}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table IN (#{table_list}) AND active ORDER BY table, name FORMAT TSVRaw;"
      TABLES.each do |mode, table|
        statements << "SELECT '#{TAG[:row]}', '#{table}', toString(pk), toString(root.id), hex(root.label), " \
          "dynamicType(root.maybe), " \
          "if(isNull(root.maybe), '-', hex(toString(root.maybe))), " \
          "if(isNull(root.maybe), '6e756c6c', hex(toJSONString(root.maybe))), " \
          "hex(toJSONString(JSONDynamicPaths(root))), hex(toJSONString(JSONSharedDataPaths(root))), " \
          "hex(toJSONString(root)) FROM default.#{table} ORDER BY pk FORMAT TSVRaw;"
      end
      statements.join("\n") + "\n"
    end

    def settings_for(mode)
      compact_variant = mode == :compact ? 1 : 0
      [
        'index_granularity=2', 'index_granularity_bytes=10485760',
        'enable_mixed_granularity_parts=1', 'min_rows_for_wide_part=1000000',
        'min_bytes_for_wide_part=0', 'compress_marks=0', 'compress_primary_key=0',
        'min_compress_block_size=0', 'max_compress_block_size=4096',
        'ratio_of_defaults_for_sparse_serialization=1', "default_compression_codec='LZ4'",
        "serialization_info_version='with_types'", 'propagate_types_serialization_versions_to_nested_types=1',
        "string_serialization_version='single_stream'", "dynamic_serialization_version='v1'",
        "object_serialization_version='v1'", "object_shared_data_serialization_version='map'",
        "object_shared_data_serialization_version_for_zero_level_parts='map'",
        "use_compact_variant_discriminators_serialization=#{compact_variant}",
        'write_marks_for_substreams_in_compact_parts=0', "map_serialization_version='basic'",
        "map_serialization_version_for_zero_level_parts='basic'",
      ].join(', ')
    end

    def sql_string(value)
      "'#{value.to_s.gsub(/[\\']/) { |character| "\\#{character}" }}'"
    end

    def write_new(path, content)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(content) }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    options = {binary: ProbeCompactJSONMRK3NullW263::BINARY, root: nil}
    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby scripts/probe_compact_json_mrk3_null_w263.rb --evidence-root EMPTY_/private/tmp_CHILD [--clickhouse PINNED]'
      parser.on('--clickhouse PATH', 'Pinned ClickHouse 26.10.1.1201 executable') { |value| options[:binary] = value }
      parser.on('--evidence-root PATH', 'Existing empty direct child of /private/tmp') { |value| options[:root] = value }
    end.parse!
    abort 'W263 MRK3 NULL: --evidence-root is required' unless options[:root]
    ok = ProbeCompactJSONMRK3NullW263::Probe.new(binary: options[:binary], evidence_root: options[:root]).run
    exit(ok ? 0 : 1)
  rescue StandardError => error
    warn "W263 MRK3 NULL runner error: #{error.class}: #{error.message}"
    exit 1
  end
end
