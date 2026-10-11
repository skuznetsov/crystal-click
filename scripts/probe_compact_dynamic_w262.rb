#!/usr/bin/env ruby
# Captures pinned ClickHouse Compact Dynamic parts and checks either the
# baseline refusal or the context-owned reader against independent literals.
# It never builds either executable.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require_relative 'stock_part_probe_support_w191'

module ProbeCompactDynamicW262
  FORMAT = 'compact_dynamic_w262_native_manifest_v1'.freeze
  HELPER_FORMAT = 'compact_dynamic_w262_baseline_helper_v1'.freeze
  GREEN_HELPER_FORMAT = 'compact_dynamic_w262_green_helper_v1'.freeze
  HELPER_SOURCE = File.expand_path('check_compact_dynamic_w262.cr', __dir__).freeze
  BINARY = '/private/tmp/crystal-click-w216-runtime-recovery.DmL9Kw/clickhouse-stripped'.freeze
  BINARY_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  VERSION = '26.10.1.1201'.freeze
  BUILD = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  W185 = CheckArrayJSONPartsW185
  DYNAMIC = 'Dynamic(max_types=1)'.freeze
  ARRAY_TUPLE = 'Array(Tuple(choice Variant(String, UInt64), payload Dynamic(max_types=1)))'.freeze
  MAP_DYNAMIC = 'Map(String, Dynamic(max_types=1))'.freeze
  VARIANT = 'Variant(String, UInt64)'.freeze
  LABELS = %w[
    mrk3_s0_vbasic mrk3_s0_vcompact mrk3_s1_vbasic mrk3_s1_vcompact
    mrk4_s0_vbasic mrk4_s0_vcompact mrk4_s1_vbasic mrk4_s1_vcompact
  ].freeze
  TABLES = LABELS.to_h { |label| [label, "w262_#{label}".freeze] }.freeze
  SCHEMA = [
    ['pk', 'UInt64'], ['root', DYNAMIC], ['nested', ARRAY_TUPLE],
    ['by_name', MAP_DYNAMIC], ['choice', VARIANT],
  ].map(&:freeze).freeze
  ROOT_ROWS = [
    [:uint8, 7], [:string, 'root-shared-1'], [:float64, 3.5], [:null, nil],
    [:string, 'root-shared-2'], [:float64, -2.25], [:uint64, 99], [:string, 'root-tail'],
  ].map(&:freeze).freeze
  NESTED_ROWS = [
    [], [],
    [[[:string, 'n3'], [:uint8, 31]]],
    [[[:uint64, 44], [:string, 'nested-shared']], [[:string, 'n4b'], [:float64, 4.5]]],
    [], [],
    [[[:string, 'n7'], [:uint8, 77]]],
    [[[:uint64, 88], [:string, 'nested-tail']], [[:string, 'n8b'], [:float64, -8.5]]],
  ].map { |row| row.map { |item| item.map(&:freeze).freeze }.freeze }.freeze
  MAP_ROWS = [
    [], [],
    [['a', [:string, 'map-three']]],
    [['b', [:uint8, 14]], ['c', [:float64, 1.25]]],
    [], [],
    [['a', [:uint8, 17]]],
    [['z', [:string, 'map-tail']], ['q', [:float64, -1.5]]],
  ].map { |row| row.map { |item| item.map(&:freeze).freeze }.freeze }.freeze
  CHOICE_ROWS = [
    [:string, 'v0'], [:uint64, 102], [:string, 'v2'], [:uint64, 104],
    [:string, 'v4'], [:uint64, 106], [:string, 'v6'], [:uint64, 108],
  ].map(&:freeze).freeze
  TAG = {
    pin: '__W262_PIN__', check_begin: '__W262_CHECK_BEGIN__', check_end: '__W262_CHECK_END__',
    schema: '__W262_SCHEMA__', rows: '__W262_ROOT_ROW__', part: '__W262_PART__',
  }.freeze
  MAX_CAPTURE_BYTES = 8 * 1024 * 1024
  MAX_PART_FILES = 4096
  MAX_PART_BYTES = 64 * 1024 * 1024

  # Crystal's Float64 signature renders the numeric IEEE-754 bit pattern,
  # while Ruby's `pack('E').unpack1('H*')` renders the little-endian wire bytes.
  # Decode the same little-endian bytes as an integer before formatting so
  # this independent literal oracle compares the same quantity.
  def self.float64_signature(value)
    bits = [Float(value)].pack('E').unpack1('Q<')
    "Float64:0x#{bits.to_s(16).rjust(16, '0')}"
  end

  class Failure < StandardError; end

  class Probe
    def initialize(binary:, helper:, evidence_root:, mode: 'baseline')
      fail!('mode must be baseline or green') unless %w[baseline green].include?(mode)
      @mode = mode
      @binary = validate_executable(binary, 'ClickHouse')
      @helper = validate_executable(helper, 'prebuilt Crystal helper')
      @root = validate_root(evidence_root)
      @capture = StockPartProbeSupportW191.new(@binary, @root)
      @store = File.join(@root, 'stores', 'native')
      @source_files = [__FILE__, HELPER_SOURCE,
                       File.expand_path('support/compact_dynamic_w262_fixture.cr', __dir__),
                       File.expand_path('support/compact_typed_w260_fixture.cr', __dir__),
                       File.expand_path('stock_part_probe_support_w191.rb', __dir__),
                       File.expand_path('check_array_json_parts_w185.rb', __dir__)].map { |path| File.realpath(path) }.uniq.sort
      @invocations = []
      @stage = 'not_started'
    end

    def run
      prepare_layout!
      fail!('pinned ClickHouse SHA-256 differs before probe') unless sha(@binary) == BINARY_SHA256
      @source_hashes_before = source_hashes
      @helper_sha_before = sha(@helper)

      @stage = 'native Compact fixture and literal oracle'
      native = run_native('native_compact_dynamic', initial_sql)
      assert_pin!(native)
      assert_native_success!(native)
      observations = parse_native(native[:stdout])
      assert_native_fixture!(observations)
      parts = LABELS.to_h do |label|
        record = observations.fetch(:parts).fetch(label)
        path = validate_native_part_path!(record.fetch(:path))
        [label, inspect_part(label, path, record)]
      end
      manifest_path = write_manifest!(observations.fetch(:parts))

      @stage = "prebuilt Compact Dynamic #{@mode} helper"
      helper = run_helper(manifest_path, @mode)
      assert_helper!(helper.fetch(:data), @mode)

      fail!('pinned ClickHouse binary changed during probe') unless sha(@binary) == BINARY_SHA256
      fail!('prebuilt helper changed during probe') unless sha(@helper) == @helper_sha_before
      fail!('probe sources changed during execution') unless source_hashes == @source_hashes_before
      parts.each do |label, part|
        fail!("#{label} part files changed during helper read") unless file_snapshot(part.fetch(:path)) == part.fetch(:files)
      end

      summary = {
        format: 'compact_dynamic_w262_probe_summary_v1', status: @mode == 'green' ? 'green_candidate' : 'expected_unsupported',
        mode: @mode,
        clickhouse_sha256: BINARY_SHA256, version: VERSION, build: BUILD,
        cells: LABELS, root_dynamic_rows: ROOT_ROWS.size,
        native_invocation: native[:record], helper_invocation: helper[:record],
        helper: helper[:data], parts: parts.transform_values { |part| part.reject { |key, _| key == :files } },
        source_hashes: @source_hashes_before,
      }
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      puts "W262 mode=#{@mode} status=#{@mode == 'green' ? 'green_candidate' : 'expected_unsupported'}; cells=#{LABELS.size}; root_witness=UInt8+String+Float64+NULL; evidence=#{@root}"
      true
    rescue StandardError => error
      warn "W262 #{@stage} failed: #{error.class}: #{error.message}"
      false
    end

    private

    def fail!(message)
      raise Failure, "W262 Compact Dynamic baseline: #{message}"
    end

    def validate_root(path)
      fail!('evidence root is required') unless path && !path.empty?
      expanded = File.expand_path(path)
      fail!('evidence root must be a direct child of /private/tmp') unless File.dirname(expanded) == File.realpath('/private/tmp')
      fail!('evidence root must not be symlinked') if File.symlink?(expanded)
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
      @capture.send(:write_new, File.join(@root, 'invocations', "#{label}.stdin.sql"), sql.b)
      argv = [@binary, 'local', '--path', @store, '--session_timezone=UTC', '--max_threads=1',
              "--max_memory_usage=#{W185::MEMORY}", '--output_format_json_quote_64bit_integers=0', '--multiquery']
      invocation = @capture.send(:execute_record, label, argv, sql.b, 'clickhouse local', BINARY_SHA256, @binary)
      @invocations << invocation[:record]
      fail!('native stdout exceeds capture bound') if invocation[:stdout].bytesize > MAX_CAPTURE_BYTES
      fail!('native stderr exceeds capture bound') if invocation[:stderr].bytesize > MAX_CAPTURE_BYTES
      invocation
    end

    def run_helper(manifest_path, mode)
      before = sha(@helper)
      fail!('prebuilt helper changed before invocation') unless before == @helper_sha_before
      argv = [@helper, mode, manifest_path]
      invocation = @capture.send(:execute_record, "#{mode}_helper", argv, ''.b,
                                 'prebuilt Crystal helper', before, @helper)
      @invocations << invocation[:record]
      fail!('helper changed during invocation') unless sha(@helper) == before
      unless invocation[:classification] == 'success' && invocation[:status]&.success? && invocation[:status]&.termsig.nil?
        fail!('helper process failed; this is not an expected Dynamic format refusal')
      end
      fail!('helper wrote stderr') unless invocation[:stderr].empty?
      lines = invocation[:stdout].force_encoding(Encoding::UTF_8).lines.map(&:chomp).reject(&:empty?)
      fail!('helper must emit one JSON record') unless lines.size == 1
      {data: JSON.parse(lines.fetch(0)), record: invocation[:record]}
    rescue JSON::ParserError => error
      fail!("helper output is not valid JSON: #{error.message}")
    end

    def assert_pin!(invocation)
      line = invocation[:stdout].force_encoding(Encoding::UTF_8).lines.map(&:chomp).find { |row| row.start_with?("#{TAG[:pin]}\t") }
      fail!("runtime pin mismatch: #{line.inspect}") unless line == "#{TAG[:pin]}\t#{VERSION}\t#{BUILD}"
    end

    def assert_native_success!(invocation)
      unless invocation[:classification] == 'success' && invocation[:status]&.success? && invocation[:status]&.termsig.nil?
        fail!('ClickHouse did not exit successfully')
      end
      fail!('ClickHouse wrote stderr') unless invocation[:stderr].empty?
    end

    def parse_native(stdout)
      lines = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      records = ->(tag) { lines.select { |line| line.start_with?("#{tag}\t") }.map { |line| line.split("\t", -1) } }
      checks = {}
      active = nil
      lines.each do |line|
        if line.start_with?("#{TAG[:check_begin]}\t")
          fields = line.split("\t", -1)
          fail!('malformed/duplicate CHECK begin') unless fields.size == 2 && TABLES.value?(fields[1]) && !checks.key?(fields[1]) && active.nil?
          active = fields[1]
          checks[active] = []
        elsif line.start_with?("#{TAG[:check_end]}\t")
          fields = line.split("\t", -1)
          fail!('unpaired CHECK end') unless fields.size == 2 && active == fields[1]
          active = nil
        elsif active
          checks.fetch(active) << line
        end
      end
      fail!('unterminated CHECK block') if active
      parts = records.call(TAG[:part]).to_h do |fields|
        fail!('malformed system.parts row') unless fields.size == 7
        table = fields[1]
        label = LABELS.find { |candidate| TABLES.fetch(candidate) == table }
        fail!("unexpected native part table #{table.inspect}") unless label
        [label, {name: fields[2], path: fields[3], type: fields[4], rows: fields[5], marks: fields[6]}]
      end
      schemas = records.call(TAG[:schema]).map { |fields| fields.drop(1) }
      rows = records.call(TAG[:rows]).to_h do |fields|
        fail!('malformed root literal row') unless fields.size == 9
        ["#{fields[1]}|#{fields[2]}", fields.drop(3)]
      end
      {checks: checks, parts: parts, schemas: schemas, rows: rows}
    end

    def assert_native_fixture!(native)
      fail!('native part roster differs') unless native[:parts].keys.sort == LABELS.sort
      fail!('native CHECK roster differs') unless native[:checks].keys.sort == TABLES.values.sort
      TABLES.each_value do |table|
        fail!("#{table} CHECK did not report exactly one valid part") unless native[:checks][table] == ["all_1_1_0\t1\t"]
      end
      expected_schema = TABLES.values.sort.flat_map { |table| SCHEMA.map { |name, type| [table, name, type] } }
      fail!('native system.columns schema differs from independent declaration') unless native[:schemas] == expected_schema
      expected_rows = ROOT_ROWS.each_with_index.to_h do |(kind, value), index|
        json = JSON.generate(value)
        dynamic_type = {uint8: 'UInt8', uint64: 'UInt64', float64: 'Float64', string: 'String', null: 'NULL'}.fetch(kind)
        shared = kind == :null || index.zero? ? '0' : '1'
        expected_nested = [0, 0, 1, 2, 0, 0, 1, 2].fetch(index).to_s
        expected_map = [0, 0, 1, 2, 0, 0, 1, 2].fetch(index).to_s
        variant_type = CHOICE_ROWS.fetch(index).first == :string ? 'String' : 'UInt64'
        ["#{index + 1}", [dynamic_type, shared, json.unpack1('H*').upcase, expected_nested, expected_map, variant_type]]
      end
      # The first UInt8 is Dynamic's nominal type. Later concrete arms spill to
      # SharedVariant; NULL is neither a concrete arm nor a shared value.
      TABLES.each_value do |table|
        table_rows = native[:rows].select { |key, _| key.start_with?("#{table}|") }
        expected_table_rows = expected_rows.transform_keys { |pk| "#{table}|#{pk}" }
        unless table_rows == expected_table_rows
          mismatches = expected_table_rows.keys.filter_map do |key|
            next if table_rows[key] == expected_table_rows[key]
            {key: key, expected: expected_table_rows[key], actual: table_rows[key]}
          end
          fail!("#{table} root witness rows differ from Ruby literals: #{JSON.generate(mismatches)}")
        end
      end
      native[:parts].each do |label, part|
        fail!("#{label} part type/grid differs") unless part[:name] == 'all_1_1_0' && part[:type] == 'Compact' && part[:rows] == '8' && part[:marks] == '5'
        validate_native_part_path!(part[:path])
      end
    end

    def validate_native_part_path!(path)
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
        fail!("part contains symlink #{entry}") if stat.symlink?
        next if entry == path || stat.directory?
        relative = entry.delete_prefix(path + File::SEPARATOR)
        total += stat.size
        fail!('part inventory exceeds byte/file bounds') if total > MAX_PART_BYTES || files.size >= MAX_PART_FILES
        files << {path: relative, bytes: stat.size, sha256: sha(entry)}
      end
      files.sort_by { |item| item[:path] }
    end

    def inspect_part(label, path, part)
      fail!("#{label} part path is missing or linked") unless File.directory?(path) && !File.symlink?(path)
      files = file_snapshot(path)
      names = files.map { |entry| entry[:path] }
      mark_ext = label.start_with?('mrk3') ? '.mrk3' : '.mrk4'
      %w[columns.txt count.txt checksums.txt primary.idx serialization.json default_compression_codec.txt metadata_version.txt data.bin].each do |name|
        fail!("#{label} lacks #{name}") unless names.include?(name)
      end
      fail!("#{label} lacks data#{mark_ext}") unless names.include?("data#{mark_ext}")
      if mark_ext == '.mrk4'
        fail!("#{label} lacks columns_substreams.txt") unless names.include?('columns_substreams.txt')
        roster = File.binread(File.join(path, 'columns_substreams.txt'), 1_048_577).force_encoding(Encoding::UTF_8)
        fail!("#{label} substream roster is invalid or too large") unless roster.valid_encoding? && roster.bytesize <= 1_048_576
        %w[root.dynamic_structure root.variant_discr root.SharedVariant root.UInt8].each do |stream|
          fail!("#{label} roster lacks #{stream}") unless roster.lines.any? { |line| line.chomp == "\t#{stream}" }
        end
      else
        fail!("#{label} mrk3 unexpectedly has columns_substreams.txt") if names.include?('columns_substreams.txt')
      end
      metadata = JSON.parse(File.binread(File.join(path, 'serialization.json')))
      expected_string_version = label.include?('_s1_') ? 1 : 0
      fail!("#{label} serialization versions differ") unless metadata['version'] == 1 &&
        metadata['propagate_types_serialization_versions_to_nested_types'] == true &&
        metadata.fetch('types_serialization_versions', {}).fetch('string', 0) == expected_string_version
      fail!("#{label} String profile differs") unless File.binread(File.join(path, 'default_compression_codec.txt')).strip == 'CODEC(LZ4)'
      {
        path: path, part_name: part[:name], part_type: part[:type], rows: part[:rows], marks: part[:marks],
        mark_extension: mark_ext, string_version: expected_string_version,
        variant_mode: label.include?('vcompact') ? 'compact' : 'basic',
        roster_sha256: names.include?('columns_substreams.txt') ? sha(File.join(path, 'columns_substreams.txt')) : nil,
        files: files,
      }
    rescue JSON::ParserError => error
      fail!("#{label} serialization.json is malformed: #{error.message}")
    end

    def write_manifest!(parts)
      path = File.join(@root, 'parts', 'native_manifest.json')
      data = {
        format: FORMAT,
        store_root: File.expand_path(@store),
        parts: LABELS.map do |label|
          {label: label, table: table_name(label), path: File.expand_path(parts.fetch(label).fetch(:path))}
        end,
      }
      write_new(path, JSON.pretty_generate(data) + "\n")
      path
    end

    def assert_helper!(data, mode)
      if mode == 'baseline'
        assert_baseline_helper!(data)
      else
        assert_green_helper!(data)
      end
    end

    def assert_baseline_helper!(data)
      fail!('helper output shape/status differs') unless data['format'] == HELPER_FORMAT && data['status'] == 'expected_unsupported'
      fail!('helper cell roster differs') unless data.fetch('cells').map { |cell| cell.fetch('label') } == LABELS
      data.fetch('cells').each do |cell|
        fail!("#{cell.fetch('label')} did not positively read pk values first") unless
          cell.fetch('compact_pk') == (1..8).to_a && cell.fetch('typed_pk') == (1..8).to_a
        refusals = cell.fetch('refusals')
        fail!("#{cell.fetch('label')} expected six exact Dynamic refusals") unless refusals.size == 6 &&
          refusals.all? { |refusal| refusal['error_class'] == 'UnsupportedFormatError' &&
            refusal['error'] == 'selected Compact declaration is outside static BinaryBulk admission' }
      end
    end

    def assert_green_helper!(data)
      fail!('helper output shape/status differs') unless data['format'] == GREEN_HELPER_FORMAT && data['status'] == 'green_candidate'
      fail!('helper cell roster differs') unless data.fetch('cells').map { |cell| cell.fetch('label') } == LABELS
      expected = {
        'root' => expected_root_signatures,
        'nested' => expected_nested_signatures,
        'by_name' => expected_map_signatures,
      }
      expected_keys = (1..8).to_a
      expected_windows = {'first' => [0, 2], 'middle' => [2, 4], 'last' => [6, 2], 'eof' => [8, 0]}
      data.fetch('cells').each do |cell|
        label = cell.fetch('label')
        fail!("#{label} did not positively read pk values first") unless
          cell.fetch('compact_pk') == expected_keys && cell.fetch('typed_pk') == expected_keys
        expected.each do |column, values|
          marks = values.each_slice(2).to_a
          direct = cell.fetch('direct').fetch(column)
          fail!("#{label}/#{column} direct mark grid differs") unless direct.fetch('mark_rows') == [2, 2, 2, 2]
          fail!("#{label}/#{column} direct full values differ from independent literals") unless direct.fetch('full') == marks
          fail!("#{label}/#{column} direct first/middle/last/EOF windows differ") unless
            direct.fetch('first') == marks[0, 1] && direct.fetch('middle') == marks[1, 2] &&
            direct.fetch('last') == marks[3, 1] && direct.fetch('eof') == []
          %w[compact typed].each do |backend|
            report = cell.fetch(backend)
            fail!("#{label}/#{backend} mark grid differs") unless report.fetch('mark_rows') == [[2, 2, 2, 2]]
            full = report.fetch('full')
            fail!("#{label}/#{backend} positive keys differ") unless full.fetch('keys') == expected_keys
            fail!("#{label}/#{backend}/#{column} full literal values differ") unless full.fetch('columns').fetch(column) == values
            expected_windows.each do |window, (start, count)|
              scan = report.fetch(window)
              slice = values[start, count]
              keys = expected_keys[start, count]
              fail!("#{label}/#{backend}/#{column} #{window} keys differ") unless scan.fetch('keys') == keys
              fail!("#{label}/#{backend}/#{column} #{window} values differ") unless scan.fetch('columns').fetch(column) == slice
            end
          end
          fail!("#{label}/offline/#{column} values differ from independent literals") unless cell.fetch('offline').fetch(column) == values
        end
      end
    end

    def dynamic_signature(value)
      kind, body = value
      return 'Dynamic(max_types=1)=NULL' if kind == :null
      "Dynamic(max_types=1)<#{leaf_signature(value)}>"
    end

    def leaf_signature(value)
      kind, body = value
      case kind
      when :uint8 then "UInt8:#{Integer(body)}"
      when :uint64 then "UInt64:#{Integer(body)}"
      when :float64 then ProbeCompactDynamicW262.float64_signature(body)
      when :string then "String:#{JSON.generate(body)}"
      else fail!("unrostered literal leaf #{value.inspect}")
      end
    end

    def expected_root_signatures
      ROOT_ROWS.map { |value| dynamic_signature(value) }
    end

    def variant_signature(value)
      kind, = value
      index = kind == :string ? 0 : 1
      "Variant(String, UInt64)##{index}(#{leaf_signature(value)})"
    end

    def expected_nested_signatures
      tuple_type = 'Tuple(choice Variant(String, UInt64), payload Dynamic(max_types=1))'
      NESTED_ROWS.map do |items|
        children = items.map do |choice, payload|
          "#{tuple_type}(#{variant_signature(choice)},#{dynamic_signature(payload)})"
        end
        "Array(#{tuple_type})[#{children.join(';')}]"
      end
    end

    def expected_map_signatures
      MAP_ROWS.map do |entries|
        values = entries.map do |key, value|
          "String:#{JSON.generate(key)}=#{dynamic_signature(value)}"
        end
        "Map(String, Dynamic(max_types=1)){#{values.join(',')}}"
      end
    end

    def write_new(path, contents)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(contents) }
    end

    def sql_quote(value)
      "'#{value.to_s.gsub(/[\\']/) { |character| "\\#{character}" }}'"
    end

    def dynamic_sql(value)
      type, body = value
      expression = case type
                   when :uint8 then "toUInt8(#{body})"
                   when :uint64 then "toUInt64(#{body})"
                   when :float64 then "toFloat64(#{body})"
                   when :string then sql_quote(body)
                   when :null then "NULL"
                   else fail!("unrostered Dynamic literal #{value.inspect}")
                   end
      "CAST(#{expression}, #{sql_quote(DYNAMIC)})"
    end

    def variant_sql(value)
      kind, body = value
      expression = kind == :string ? sql_quote(body) : "toUInt64(#{Integer(body)})"
      "CAST(#{expression}, #{sql_quote(VARIANT)})"
    end

    def nested_sql(items)
      tuples = items.map { |choice, payload| "tuple(#{variant_sql(choice)}, #{dynamic_sql(payload)})" }
      "CAST([#{tuples.join(', ')}], #{sql_quote(ARRAY_TUPLE)})"
    end

    def map_sql(entries)
      pairs = entries.flat_map { |key, value| [sql_quote(key), dynamic_sql(value)] }
      expression = pairs.empty? ? 'map()' : "map(#{pairs.join(', ')})"
      "CAST(#{expression}, #{sql_quote(MAP_DYNAMIC)})"
    end

    def table_name(label)
      TABLES.fetch(label)
    end

    def settings_for(label)
      mark_mode = label.start_with?('mrk4') ? 1 : 0
      string_mode = label.include?('_s1_') ? 'with_size_stream' : 'single_stream'
      variant_mode = label.include?('vcompact') ? 1 : 0
      [
        'index_granularity=2', 'index_granularity_bytes=10485760', 'enable_mixed_granularity_parts=1',
        'min_rows_for_wide_part=1000000', 'min_bytes_for_wide_part=0', 'compress_marks=0',
        'compress_primary_key=0', 'min_compress_block_size=0', 'max_compress_block_size=4096',
        'ratio_of_defaults_for_sparse_serialization=1', "nullable_serialization_version='basic'",
        "default_compression_codec='LZ4'", "serialization_info_version='with_types'",
        'propagate_types_serialization_versions_to_nested_types=1', "string_serialization_version='#{string_mode}'",
        "map_serialization_version='basic'", "map_serialization_version_for_zero_level_parts='basic'",
        "dynamic_serialization_version='v3'", "use_compact_variant_discriminators_serialization=#{variant_mode}",
        "write_marks_for_substreams_in_compact_parts=#{mark_mode}",
      ].join(', ')
    end

    def initial_sql
      statements = [
        'SET flatten_nested=0;', 'SET allow_suspicious_low_cardinality_types=1;',
        'SET output_format_json_named_tuples_as_objects=0;', 'SET print_pretty_type_names=0;',
        "SELECT '#{TAG[:pin]}', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
      ]
      LABELS.each do |label|
        table = table_name(label)
        declarations = SCHEMA.map { |name, type| "`#{name}` #{type}" }.join(', ')
        statements << "CREATE TABLE default.#{table} (#{declarations}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings_for(label)};"
        values = ROOT_ROWS.each_index.map do |index|
          ["toUInt64(#{index + 1})", dynamic_sql(ROOT_ROWS.fetch(index)), nested_sql(NESTED_ROWS.fetch(index)),
           map_sql(MAP_ROWS.fetch(index)), variant_sql(CHOICE_ROWS.fetch(index))].join(', ')
        end
        statements << "INSERT INTO default.#{table} VALUES\n#{values.map { |value| "(#{value})" }.join(",\n")};"
        statements << "SELECT '#{TAG[:check_begin]}', '#{table}' FORMAT TSVRaw;"
        statements << "CHECK TABLE default.#{table} FORMAT TSV;"
        statements << "SELECT '#{TAG[:check_end]}', '#{table}' FORMAT TSVRaw;"
      end
      quoted_tables = TABLES.values.map { |name| sql_quote(name) }.join(', ')
      statements << "SELECT '#{TAG[:schema]}', table, name, type FROM system.columns WHERE database='default' AND table IN (#{quoted_tables}) ORDER BY table, position FORMAT TSVRaw;"
      statements << "SELECT '#{TAG[:part]}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table IN (#{quoted_tables}) AND active ORDER BY table,name FORMAT TSVRaw;"
      LABELS.each do |label|
        table = table_name(label)
        statements << "SELECT '#{TAG[:rows]}', '#{table}', toString(pk), if(isNull(root), 'NULL', dynamicType(root)), if(isNull(root), '0', toString(toUInt8(isDynamicElementInSharedData(root)))), hex(if(isNull(root), 'null', toJSONString(root))), toString(length(nested)), toString(length(mapKeys(by_name))), variantType(choice) FROM default.#{table} ORDER BY pk FORMAT TSVRaw;"
      end
      statements.join("\n") + "\n"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    options = {binary: ProbeCompactDynamicW262::BINARY, helper: nil, root: nil, mode: 'baseline'}
    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby scripts/probe_compact_dynamic_w262.rb --mode baseline|green --crystal-helper PREBUILT --evidence-root EMPTY_/private/tmp_CHILD [--clickhouse PINNED]'
      parser.on('--clickhouse PATH', 'Pinned ClickHouse 26.10.1.1201 executable') { |value| options[:binary] = value }
      parser.on('--crystal-helper PATH', 'Prebuilt Crystal helper; this runner never compiles it') { |value| options[:helper] = value }
      parser.on('--evidence-root PATH', 'Existing empty direct child of /private/tmp') { |value| options[:root] = value }
      parser.on('--mode MODE', %w[baseline green], 'baseline checks the unchanged-head refusal; green checks the context-owned reader') { |value| options[:mode] = value }
    end.parse!
    abort 'W262: --crystal-helper and --evidence-root are required' unless options[:helper] && options[:root]
    exit(ProbeCompactDynamicW262::Probe.new(binary: options[:binary], helper: options[:helper], evidence_root: options[:root], mode: options[:mode]).run ? 0 : 1)
  rescue StandardError => error
    warn "W262 runner error: #{error.class}: #{error.message}"
    exit 1
  end
end
