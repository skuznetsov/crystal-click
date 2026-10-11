#!/usr/bin/env ruby
# Captures stock-authored Compact JSON/Object parts and checks either the
# baseline refusal or the W263 readers against independently authored values.
# It never builds the ClickHouse binary or the Crystal helper.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'optparse'
require_relative 'stock_part_probe_support_w191'

module ProbeCompactJSONW263
  FORMAT = 'compact_json_w263_native_manifest_v1'.freeze
  BASELINE_HELPER_FORMAT = 'compact_json_w263_baseline_helper_v1'.freeze
  GREEN_HELPER_FORMAT = 'compact_json_w263_green_helper_v1'.freeze
  HELPER_SOURCE = File.expand_path('check_compact_json_w263.cr', __dir__).freeze
  FIXTURE_SOURCE = File.expand_path('support/compact_json_w263_fixture.cr', __dir__).freeze
  BINARY = '/private/tmp/crystal-click-w216-runtime-recovery.DmL9Kw/clickhouse-stripped'.freeze
  BINARY_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  VERSION = '26.10.1.1201'.freeze
  BUILD = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  SOURCE_SNAPSHOT = {
    path: '/private/tmp/clickhouse-w254-upstream.AqeqyC',
    revision: 'ed30948f095ecb70679986d7d60e27ad770ae27a',
    runtime_provenance_claimed: false,
  }.freeze
  W185 = CheckArrayJSONPartsW185

  JSON_TYPE = 'JSON(max_dynamic_types=1, max_dynamic_paths=2, id UInt8, label String)'.freeze
  DYNAMIC = 'Dynamic(max_types=1)'.freeze
  VARIANT = 'Variant(String, UInt64)'.freeze
  DOCS = "Array(#{JSON_TYPE})".freeze
  TAGGED = "Array(Tuple(doc #{JSON_TYPE}, slot UInt8))".freeze
  PAIR = "Tuple(left #{JSON_TYPE}, right #{JSON_TYPE})".freeze
  SCHEMA = [
    ['pk', 'UInt64'], ['scalar', 'UInt8'], ['text', 'String'], ['payload', DYNAMIC],
    ['choice', VARIANT], ['root', JSON_TYPE], ['docs', DOCS], ['tagged', TAGGED], ['pair', PAIR],
  ].map(&:freeze).freeze
  LAYOUTS = [
    {object: 'v1', dynamic: 'v1', shared: 'map', wire: 0, shared_wire: 0, buckets: 1},
    {object: 'v2', dynamic: 'v2', shared: 'map', wire: 2, shared_wire: 0, buckets: 1},
    {object: 'v3', dynamic: 'v3', shared: 'map', wire: 4, shared_wire: 0, buckets: 1},
    {object: 'v3', dynamic: 'v3', shared: 'map_with_buckets', wire: 4, shared_wire: 1, buckets: 2},
    {object: 'v3', dynamic: 'v3', shared: 'advanced', wire: 4, shared_wire: 2, buckets: 2},
    {object: 'v3', dynamic: 'v3', shared: 'advanced_chunked', wire: 4, shared_wire: 3, buckets: 2},
  ].map(&:freeze).freeze
  # Independent oracle for persisted root Object structures. Keep these literal
  # triples separate from the settings descriptors above: settings requested
  # from ClickHouse are not proof of the bytes actually persisted.
  PERSISTED_LAYOUT_TRIPLES = {
    'obj_v1_dyn_v1_map' => [0, 0, 1],
    'obj_v2_dyn_v2_map' => [2, 0, 1],
    'obj_v3_dyn_v3_map' => [4, 0, 1],
    'obj_v3_dyn_v3_map_with_buckets' => [4, 1, 2],
    'obj_v3_dyn_v3_advanced' => [4, 2, 2],
    'obj_v3_dyn_v3_advanced_chunked' => [4, 3, 2],
  }.transform_values(&:freeze).freeze
  MARKS = [3, 4].freeze
  STRING_VERSIONS = [0, 1].freeze
  VARIANT_MODES = %w[basic compact].freeze
  LABELS = LAYOUTS.flat_map do |layout|
    MARKS.flat_map do |mark|
      STRING_VERSIONS.flat_map do |string_version|
        VARIANT_MODES.map do |variant_mode|
          "obj_#{layout.fetch(:object)}_dyn_#{layout.fetch(:dynamic)}_#{layout.fetch(:shared)}_mrk#{mark}_s#{string_version}_variant_#{variant_mode}"
        end
      end
    end
  end.freeze
  TABLES = LABELS.to_h { |label| [label, "w263_#{label}".freeze] }.freeze
  ROWS = 8
  MARK_ROWS = [2, 2, 2, 2].freeze
  DOC_COUNTS = [0, 1, 3, 2, 0, 2, 1, 4].freeze
  TAGGED_COUNTS = [2, 0, 1, 0, 3, 1, 0, 2].freeze
  SAMPLE_FLOATS = [1.5, 2.5, 3.75, 5.0, 6.25, 7.5, 8.5, 9.5].freeze
  PAYLOADS = [
    [:uint8, 7], [:string, 'payload-two'], [:float64, 1.5], [:uint64, 44],
    [:uint8, 15], [:string, 'payload-six'], [:float64, -2.25], [:uint64, 88],
  ].map(&:freeze).freeze
  CHOICES = [
    [:string, 'choice-one'], [:uint64, 22], [:string, 'choice-three'], [:uint64, 44],
    [:string, 'choice-five'], [:uint64, 66], [:string, 'choice-seven'], [:uint64, 88],
  ].map(&:freeze).freeze
  TAG = {
    pin: '__W263_PIN__', check_begin: '__W263_CHECK_BEGIN__', check_end: '__W263_CHECK_END__',
    schema: '__W263_SCHEMA__', part: '__W263_PART__', rows: '__W263_ROW__',
  }.freeze
  REFUSAL = 'selected Compact declaration is outside static or Dynamic BinaryBulk admission'.freeze
  OFFLINE_WRAPPER_REFUSAL = 'selected table column type is unsupported'.freeze
  JSON_COLUMNS = %w[root docs tagged pair].freeze
  OFFLINE_WRAPPERS = %w[docs tagged pair].freeze
  CHUNKED_SITE_OWNERS = {
    'root' => ['root'],
    'docs' => ['docs'],
    'tagged' => ['tagged%2Edoc'],
    'pair' => ['pair%2Eleft', 'pair%2Eright'],
  }.freeze
  CHUNKED_OCCURRENCES_BY_MARK = {
    'root' => [2, 2, 2, 2],
    'docs' => [1, 5, 2, 5],
    'tagged' => [2, 1, 4, 2],
    'pair' => [2, 2, 2, 2],
  }.freeze
  # Per-parent Object occurrence grids are independent fixture facts, not
  # inferred from the reader output. Empty Array rows and unequal sibling
  # counts are explicit; the helper additionally binds their sums to the
  # persisted one-row CHUNKED records for every bucket and mark.
  CHUNKED_PARENT_OCCURRENCES_BY_MARK = {
    'root' => [[1, 1], [1, 1], [1, 1], [1, 1]],
    'docs' => [[0, 1], [3, 2], [0, 2], [1, 4]],
    'tagged' => [[2, 0], [1, 0], [3, 1], [0, 2]],
    'pair' => [[1, 1], [1, 1], [1, 1], [1, 1]],
  }.transform_values { |marks| marks.map(&:freeze).freeze }.freeze
  GREEN_OFFLINE_COLUMNS = %w[scalar text payload choice root docs tagged pair].freeze
  MAX_CAPTURE_BYTES = 8 * 1024 * 1024
  MAX_PART_FILES = 4096
  MAX_PART_BYTES = 64 * 1024 * 1024

  class Failure < StandardError; end

  class Probe
    def initialize(binary:, helper:, evidence_root:, mode: 'baseline')
      fail!('mode must be baseline or green') unless %w[baseline green].include?(mode)
      self_check_layout_parser!
      self_check_refusal_validators!
      @mode = mode
      @binary = validate_executable(binary, 'pinned ClickHouse')
      @helper = validate_executable(helper, 'prebuilt Crystal helper')
      @root = validate_root(evidence_root)
      @capture = StockPartProbeSupportW191.new(@binary, @root)
      @store = File.join(@root, 'stores', 'native')
      @source_files = [__FILE__, HELPER_SOURCE, FIXTURE_SOURCE,
                       File.expand_path('stock_part_probe_support_w191.rb', __dir__),
                       File.expand_path('check_array_json_parts_w185.rb', __dir__),
                       File.expand_path('check_json_binary_kernel_w180.rb', __dir__),
                       File.expand_path('probe_json_array_storage_w183.rb', __dir__)].map do |path|
        File.realpath(path)
      end.uniq.sort
      @stage = 'not_started'
      @invocations = []
    end

    def run
      prepare_layout!
      @binary_sha_before = sha(@binary)
      fail!('pinned ClickHouse SHA-256 differs before probe') unless @binary_sha_before == BINARY_SHA256
      @source_revision_before = source_revision
      fail!('pinned ClickHouse source snapshot revision differs') unless @source_revision_before == SOURCE_SNAPSHOT.fetch(:revision)
      @source_hashes_before = source_hashes
      @helper_sha_before = sha(@helper)

      @stage = 'native 48-cell Compact JSON/Object fixture and independent literals'
      native = run_native('native_compact_json_w263', initial_sql)
      assert_pin!(native)
      assert_native_success!(native)
      observations = parse_native(native[:stdout])
      assert_native_fixture!(observations)
      parts = LABELS.to_h do |label|
        record = observations.fetch(:parts).fetch(label)
        path = validate_native_part_path!(record.fetch(:path))
        [label, inspect_part(label, path, record)]
      end
      manifest_path = write_manifest!(observations.fetch(:parts), parts)

      @stage = "prebuilt W263 helper in #{@mode} mode"
      helper = run_helper(manifest_path, @mode)
      assert_helper!(helper.fetch(:data), parts, @mode)

      @stage = 'pin, source, helper and native part stability'
      @binary_sha_after = sha(@binary)
      @source_revision_after = source_revision
      @source_hashes_after = source_hashes
      @helper_sha_after = sha(@helper)
      fail!('pinned ClickHouse binary changed during probe') unless @binary_sha_after == BINARY_SHA256
      fail!('pinned ClickHouse source snapshot changed during probe') unless @source_revision_after == @source_revision_before
      fail!('prebuilt Crystal helper changed during probe') unless @helper_sha_after == @helper_sha_before
      fail!('probe source files changed during execution') unless @source_hashes_after == @source_hashes_before
      parts.each do |label, part|
        fail!("#{label} native part changed during helper read") unless file_snapshot(part.fetch(:path)) == part.fetch(:files)
      end

      summary = {
        format: 'compact_json_w263_probe_summary_v1',
        status: @mode == 'baseline' ? 'expected_json_unsupported' : 'green_candidate',
        mode: @mode, cells: LABELS, row_count: ROWS, mark_rows: MARK_ROWS,
        clickhouse: {path: @binary, sha256: BINARY_SHA256, version: VERSION, build: BUILD},
        source_snapshot: SOURCE_SNAPSHOT.merge(observed_revision: @source_revision_before),
        helper: {path: @helper, sha256: @helper_sha_before, result: helper[:data]},
        native_invocation: native[:record], helper_invocation: helper[:record],
        schemas: observations[:schemas], native_rows: observations[:rows],
        parts: parts.transform_values { |part| part.reject { |key, _| key == :files } },
        source_hashes: @source_hashes_before,
      }
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      puts "W263 mode=#{@mode} status=#{summary[:status]}; cells=#{LABELS.size}; rows=#{ROWS}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @binary_sha_after = sha(@binary) rescue nil
      @helper_sha_after = sha(@helper) rescue nil
      @source_revision_after = source_revision rescue nil
      warn "W263 #{@stage} failed: #{@fatal_error}"
      write_new(File.join(@root, 'failure.json'), JSON.pretty_generate({
        format: 'compact_json_w263_probe_failure_v1', stage: @stage, error: @fatal_error,
        binary_sha_before: @binary_sha_before, binary_sha_after: @binary_sha_after,
        helper_sha_before: @helper_sha_before, helper_sha_after: @helper_sha_after,
        source_revision_before: @source_revision_before, source_revision_after: @source_revision_after,
        invocations: @invocations,
      }) + "\n") rescue nil
      false
    end

    private

    def fail!(message)
      raise Failure, "W263 Compact JSON probe: #{message}"
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
      fail!("#{label} is missing, non-executable or symlinked") unless
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

    def source_revision
      root = SOURCE_SNAPSHOT.fetch(:path)
      fail!('pinned source snapshot is missing or symlinked') unless File.directory?(root) && !File.symlink?(root)
      stdout, stderr, status = Open3.capture3('git', '-C', root, 'rev-parse', 'HEAD')
      fail!("cannot read pinned source snapshot revision: #{stderr.strip}") unless status.success? && stderr.empty?
      stdout.strip
    end

    def run_native(label, sql)
      write_new(File.join(@root, 'invocations', "#{label}.stdin.sql"), sql.b)
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
      fail!('prebuilt helper changed during invocation') unless sha(@helper) == before
      fail!('helper stdout exceeds capture bound') if invocation[:stdout].bytesize > MAX_CAPTURE_BYTES
      fail!('helper stderr exceeds capture bound') if invocation[:stderr].bytesize > MAX_CAPTURE_BYTES
      unless invocation[:classification] == 'success' && invocation[:status]&.success? && invocation[:status]&.termsig.nil?
        fail!('helper process failed; an expected format refusal must be caught and reported as data')
      end
      fail!('helper wrote stderr') unless invocation[:stderr].empty?
      lines = invocation[:stdout].force_encoding(Encoding::UTF_8).lines.map(&:chomp).reject(&:empty?)
      fail!('helper must emit exactly one JSON record') unless lines.size == 1
      {data: JSON.parse(lines.fetch(0)), record: invocation[:record]}
    rescue JSON::ParserError => error
      fail!("helper output is not valid JSON: #{error.message}")
    end

    def assert_pin!(invocation)
      lines = invocation[:stdout].force_encoding(Encoding::UTF_8).lines.map(&:chomp).select do |line|
        line.start_with?("#{TAG[:pin]}\t")
      end
      expected = "#{TAG[:pin]}\t#{VERSION}\t#{BUILD}"
      fail!("runtime pin marker differs: #{lines.inspect}") unless lines == [expected]
    end

    def assert_native_success!(invocation)
      unless invocation[:classification] == 'success' && invocation[:status]&.success? && invocation[:status]&.termsig.nil?
        fail!('ClickHouse process did not exit successfully')
      end
      fail!('ClickHouse wrote stderr') unless invocation[:stderr].empty?
    end

    def parse_native(stdout)
      lines = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      tagged = ->(tag) { lines.select { |line| line.start_with?("#{tag}\t") }.map { |line| line.split("\t", -1) } }
      checks = {}
      active = nil
      lines.each do |line|
        if line.start_with?("#{TAG[:check_begin]}\t")
          fields = line.split("\t", -1)
          fail!('malformed or duplicate CHECK begin') unless fields.size == 2 && TABLES.value?(fields[1]) && !checks.key?(fields[1]) && active.nil?
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
      parts = tagged.call(TAG[:part]).to_h do |fields|
        fail!('malformed system.parts row') unless fields.size == 7
        label = LABELS.find { |candidate| TABLES.fetch(candidate) == fields[1] }
        fail!("unexpected system.parts table #{fields[1].inspect}") unless label
        [label, {name: fields[2], path: fields[3], type: fields[4], rows: fields[5], marks: fields[6]}]
      end
      schemas = tagged.call(TAG[:schema]).map { |fields| fields.drop(1) }
      row_records = tagged.call(TAG[:rows])
      fail!('native row count differs from 48 x 8') unless row_records.size == LABELS.size * ROWS
      rows = row_records.to_h do |fields|
        fail!('malformed native literal row') unless fields.size == 20
        ["#{fields[1]}|#{fields[2]}", fields.drop(3)]
      end
      {checks: checks, parts: parts, schemas: schemas, rows: rows}
    rescue IndexError => error
      fail!("native TSV row is truncated: #{error.message}")
    end

    def assert_native_fixture!(native)
      fail!('native part roster differs from the ordered 48-cell matrix') unless native[:parts].keys.sort == LABELS.sort
      fail!('native CHECK roster differs from the 48 tables') unless native[:checks].keys.sort == TABLES.values.sort
      TABLES.each_value do |table|
        fail!("#{table} CHECK did not report exactly one valid part") unless native[:checks][table] == ["all_1_1_0\t1\t"]
      end
      expected_schema = TABLES.values.sort.flat_map { |table| SCHEMA.map { |name, type| [table, name, type] } }
      fail!('native system.columns schema differs from independent declaration') unless native[:schemas] == expected_schema
      expected_rows = {}
      LABELS.each do |label|
        1.upto(ROWS) do |identity|
          expected_rows["#{TABLES.fetch(label)}|#{identity}"] = expected_native_values(identity)
        end
      end
      fail!('native row roster differs from independent literals') unless native[:rows].keys.sort == expected_rows.keys.sort
      expected_rows.each do |key, expected|
        actual = native[:rows].fetch(key)
        fail!("#{key} scalar/text/Dynamic type and spill fields differ") unless actual[0, 4] == expected[0, 4]
        fail!("#{key} Dynamic payload literal differs") unless parse_hex_json(actual.fetch(4), "#{key} Dynamic payload") == expected.fetch(4)
        fail!("#{key} Variant type differs") unless actual.fetch(5) == expected.fetch(5)
        fail!("#{key} Variant literal differs") unless parse_hex_json(actual.fetch(6), "#{key} Variant") == expected.fetch(6)
      end
      native[:parts].each do |label, part|
        fail!("#{label} native part identity/grid differs") unless
          part[:name] == 'all_1_1_0' && part[:type] == 'Compact' && part[:rows] == '8' && part[:marks] == '5'
        validate_native_part_path!(part[:path])
      end
      # JSON and recursive payloads are parsed independently below after the
      # compact row-column positions have been checked for their scalar fields.
      assert_native_json_values!(native[:rows])
    end

    def assert_native_json_values!(rows)
      LABELS.each do |label|
        1.upto(ROWS) do |identity|
          key = "#{TABLES.fetch(label)}|#{identity}"
          fields = rows.fetch(key)
          expected = expected_native_values(identity)
          actual_payload = parse_hex_json(fields.fetch(4), "#{key} Dynamic payload")
          fail!("#{key} Dynamic payload literal differs") unless actual_payload == expected.fetch(4)
          fail!("#{key} Variant arm differs") unless fields.fetch(5) == expected.fetch(5)
          actual_variant = parse_hex_json(fields.fetch(6), "#{key} Variant")
          fail!("#{key} Variant literal differs") unless actual_variant == expected.fetch(6)
          actual_root = parse_hex_json(fields.fetch(7), "#{key} root JSON")
          fail!("#{key} root JSON literal differs") unless actual_root == root_json(identity)
          fail!("#{key} typed JSON paths differ") unless fields[8, 2] == [identity.to_s, hex('json-' + identity.to_s)]
          dynamic_paths = parse_hex_json(fields.fetch(10), "#{key} JSONDynamicPaths")
          shared_paths = parse_hex_json(fields.fetch(11), "#{key} JSONSharedDataPaths")
          fail!("#{key} inferred Dynamic path roster differs") unless dynamic_paths.sort == %w[note sample]
          fail!("#{key} Object shared path spill zz_overflow is absent") unless shared_paths.include?('zz_overflow')
          sample_type = identity.odd? ? 'Int64' : 'Float64'
          fail!("#{key} inferred sample type differs") unless fields[12] == sample_type
          actual_docs = parse_hex_json(fields.fetch(14), "#{key} Array(JSON)")
          fail!("#{key} Array(JSON) literal differs") unless actual_docs == docs_json(identity - 1)
          actual_tagged = parse_hex_json(fields.fetch(15), "#{key} Array(Tuple(JSON, UInt8))")
          fail!("#{key} recursive Array(Tuple(JSON, UInt8)) literal differs") unless actual_tagged == tagged_json(identity - 1)
          actual_pair = parse_hex_json(fields.fetch(16), "#{key} Tuple(JSON, JSON)")
          fail!("#{key} independent Tuple(JSON, JSON) literal differs") unless actual_pair == pair_json(identity)
        end
        # Positive per-cell persisted-value witnesses for direct Dynamic
        # SharedVariant and JSON's inferred Dynamic SharedVariant, separate
        # from the JSON object's shared-path spill checked above.
        cell_rows = (1..ROWS).map { |identity| rows.fetch("#{TABLES.fetch(label)}|#{identity}") }
        fail!("#{label} direct Dynamic SharedVariant spill was not observed") unless cell_rows.any? { |fields| fields.fetch(3) == '1' }
        fail!("#{label} JSON inferred Dynamic sample did not expose a SharedVariant occurrence") unless
          cell_rows.any? { |fields| fields.fetch(13) == '1' }
      end
    end

    def expected_native_values(identity)
      payload = PAYLOADS.fetch(identity - 1)
      choice = CHOICES.fetch(identity - 1)
      payload_type = payload.first == :float64 ? 'Float64' : payload.first.to_s.sub('uint8', 'UInt8').sub('uint64', 'UInt64').sub('string', 'String')
      payload_shared = payload.first == :uint8 ? '0' : '1'
      choice_type = choice.first == :string ? 'String' : 'UInt64'
      [identity.to_s, hex("text-#{identity}"), payload_type, payload_shared,
       payload.fetch(1), choice_type, choice.fetch(1)]
    end

    def root_json(identity)
      sample = identity.odd? ? identity * 10 : SAMPLE_FLOATS.fetch((identity - 1) % SAMPLE_FLOATS.size)
      {'id' => identity, 'label' => "json-#{identity}", 'note' => "note-#{identity}",
       'sample' => sample, 'zz_overflow' => "overflow-#{identity}"}
    end

    def docs_json(row_index)
      count = DOC_COUNTS.fetch(row_index)
      Array.new(count) do |child_index|
        identity = 20 + row_index * 4 + child_index
        root_json(identity).merge('label' => "doc-#{row_index + 1}-#{child_index + 1}")
      end
    end

    def tagged_json(row_index)
      count = TAGGED_COUNTS.fetch(row_index)
      Array.new(count) do |child_index|
        identity = 80 + row_index * 4 + child_index
        [root_json(identity).merge('label' => "tag-#{row_index + 1}-#{child_index + 1}"), child_index + 1]
      end
    end

    def pair_json(identity)
      [root_json(120 + identity).merge('label' => "left-#{identity}"),
       root_json(140 + identity).merge('label' => "right-#{identity}")]
    end

    def parse_hex_json(value, label)
      fail!("#{label} is not even-width hexadecimal") unless /\A(?:[0-9a-fA-F]{2})*\z/.match?(value)
      decoded = [value].pack('H*').force_encoding(Encoding::UTF_8)
      fail!("#{label} is invalid UTF-8") unless decoded.valid_encoding?
      JSON.parse(decoded)
    rescue JSON::ParserError => error
      fail!("#{label} is invalid JSON: #{error.message}")
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
        fail!("native part contains symlink #{entry}") if stat.symlink?
        next if entry == path || stat.directory?
        relative = entry.delete_prefix(path + File::SEPARATOR)
        total += stat.size
        fail!('native part file inventory exceeds capture bounds') if total > MAX_PART_BYTES || files.size >= MAX_PART_FILES
        files << {path: relative, bytes: stat.size, sha256: sha(entry)}
      end
      files.sort_by { |file| file[:path] }
    end

    def inspect_part(label, path, part)
      fail!("#{label} part is absent or linked") unless File.directory?(path) && !File.symlink?(path)
      files = file_snapshot(path)
      names = files.map { |file| file[:path] }
      mark_ext = label.include?('_mrk3_') ? '.mrk3' : '.mrk4'
      required = %w[columns.txt count.txt checksums.txt primary.idx serialization.json default_compression_codec.txt metadata_version.txt data.bin]
      required << "data#{mark_ext}"
      required << 'columns_substreams.txt' if mark_ext == '.mrk4'
      required.each { |name| fail!("#{label} Compact part lacks #{name}") unless names.include?(name) }
      fail!("#{label} mrk3 unexpectedly has columns_substreams.txt") if mark_ext == '.mrk3' && names.include?('columns_substreams.txt')
      fail!("#{label} has non-plain or multiple mark files") unless names.grep(/\.c?mrk\d*\z/) == ["data#{mark_ext}"]
      fail!("#{label} has a non-Compact data file inventory") unless names.grep(/\.bin\z/) == ['data.bin']
      fail!("#{label} count.txt differs") unless File.binread(File.join(path, 'count.txt')) == '8'
      fail!("#{label} default codec differs") unless File.binread(File.join(path, 'default_compression_codec.txt')).strip == 'CODEC(LZ4)'
      metadata = JSON.parse(File.binread(File.join(path, 'serialization.json')))
      expected_string = label.include?('_s1_') ? 1 : 0
      fail!("#{label} with_types metadata differs") unless metadata['version'] == 1
      fail!("#{label} effective nested serialization settings differ") unless
        metadata['propagate_types_serialization_versions_to_nested_types'] == true &&
        metadata.fetch('types_serialization_versions', {}).fetch('string', 0) == expected_string
      fail!("#{label} is not a Compact part") unless part[:type] == 'Compact'
      {
        path: path, part_name: part[:name], part_type: part[:type], rows: part[:rows], marks: part[:marks],
        mark_extension: mark_ext, string_version: expected_string, serialization: metadata,
        substreams_sha256: names.include?('columns_substreams.txt') ? sha(File.join(path, 'columns_substreams.txt')) : nil,
        files: files,
      }
    rescue JSON::ParserError => error
      fail!("#{label} serialization.json is malformed: #{error.message}")
    end

    def write_manifest!(native_parts, parts)
      path = File.join(@root, 'parts', 'native_manifest.json')
      manifest = {
        format: FORMAT, store_root: File.expand_path(@store), mode: @mode,
        clickhouse: {sha256: BINARY_SHA256, version: VERSION, build: BUILD},
        source_snapshot: SOURCE_SNAPSHOT.merge(observed_revision: @source_revision_before),
        parts: LABELS.map do |label|
          record = native_parts.fetch(label)
          {label: label, table: TABLES.fetch(label), path: File.expand_path(record.fetch(:path)),
           part_name: record.fetch(:name), part_type: record.fetch(:type), rows: record.fetch(:rows), marks: record.fetch(:marks),
           mark_extension: parts.fetch(label).fetch(:mark_extension), file_inventory: parts.fetch(label).fetch(:files)}
        end,
      }
      write_new(path, JSON.pretty_generate(manifest) + "\n")
      readback = JSON.parse(File.read(path))
      fail!('manifest does not preserve exact matrix order') unless readback.fetch('parts').map { |item| item.fetch('label') } == LABELS
      path
    end

    def assert_helper!(data, parts, mode)
      mode == 'baseline' ? assert_baseline_helper!(data, parts) : assert_green_helper!(data, parts)
    end

    def assert_baseline_helper!(data, parts)
      fail!('baseline helper output format/status differs') unless
        data['format'] == BASELINE_HELPER_FORMAT && data['status'] == 'expected_unsupported'
      fail!('baseline helper label roster differs') unless data.fetch('cells').map { |cell| cell.fetch('label') } == LABELS
      data.fetch('cells').each do |cell|
        label = cell.fetch('label')
        fail!("#{label} positive UInt64 control differs") unless
          cell.fetch('compact_pk') == (1..ROWS).to_a && cell.fetch('typed_pk') == (1..ROWS).to_a
        validate_persisted_layout!(label, cell.fetch('persisted_root_layout'))
        validate_json_refusals!(label, cell.fetch('refusals'))
        validate_offline_wrapper_refusals!(label, cell.fetch('offline_wrapper_refusals'))
      end
      validate_paired_chunked_schedules!(data.fetch('cells'))
    end

    def validate_json_refusals!(label, refusals)
      expected = JSON_COLUMNS.flat_map { |column| %w[compact typed].map { |api| [api, column] } }
      actual = refusals.map { |item| [item.fetch('api'), item.fetch('column')] }
      fail!("#{label} public JSON refusal API×column product differs") unless actual == expected
      fail!("#{label} public refusal text/class differs") unless refusals.all? do |item|
        item.fetch('error_class') == 'UnsupportedFormatError' && item.fetch('error') == REFUSAL
      end
    end

    def validate_offline_wrapper_refusals!(label, refusals)
      actual = refusals.map { |item| item.fetch('column') }
      fail!("#{label} offline wrapper .values refusal product differs") unless actual == OFFLINE_WRAPPERS
      fail!("#{label} offline wrapper refusal differs") unless refusals.all? do |item|
        item.fetch('error_class') == 'UnsupportedFormatError' && item.fetch('error') == OFFLINE_WRAPPER_REFUSAL
      end
    end

    def self_check_refusal_validators!
      public_records = JSON_COLUMNS.flat_map do |column|
        %w[compact typed].map do |api|
          {'api' => api, 'column' => column, 'error_class' => 'UnsupportedFormatError', 'error' => REFUSAL}
        end
      end
      offline_records = OFFLINE_WRAPPERS.map do |column|
        {'column' => column, 'error_class' => 'UnsupportedFormatError', 'error' => OFFLINE_WRAPPER_REFUSAL}
      end

      validate_json_refusals!('in-memory positive control', public_records)
      validate_offline_wrapper_refusals!('in-memory positive control', offline_records)
      [public_records[0...-1], public_records[0...-1] + [public_records.first]].each_with_index do |records, index|
        expect_validator_rejection!("public refusal negative control #{index}") do
          validate_json_refusals!('in-memory negative control', records)
        end
      end
      [offline_records[0...-1], offline_records[0...-1] + [offline_records.first]].each_with_index do |records, index|
        expect_validator_rejection!("offline refusal negative control #{index}") do
          validate_offline_wrapper_refusals!('in-memory negative control', records)
        end
      end
    end

    def expect_validator_rejection!(label)
      yield
      fail!("#{label} was not rejected")
    rescue Failure => error
      raise if error.message.include?("#{label} was not rejected")
      nil
    end

    def assert_green_helper!(data, parts)
      fail!('green helper output format/status differs') unless
        data['format'] == GREEN_HELPER_FORMAT && data['status'] == 'green_candidate'
      fail!('green helper label roster differs') unless data.fetch('cells').map { |cell| cell.fetch('label') } == LABELS
      data.fetch('cells').each do |cell|
        label = cell.fetch('label')
        expected_keys = (1..ROWS).to_a
        fail!("#{label} UInt64 positive control differs") unless cell.fetch('compact_pk') == expected_keys && cell.fetch('typed_pk') == expected_keys
        validate_persisted_layout!(label, cell.fetch('persisted_root_layout'))
        {'compact' => cell.fetch('compact'), 'typed' => cell.fetch('typed')}.each do |backend, report|
          fail!("#{label}/#{backend} mark grid differs") unless report.fetch('mark_rows') == [MARK_ROWS]
          expected_columns = expected_signatures
          {'full' => [0, ROWS], 'first' => [0, 2], 'middle' => [2, 4], 'last' => [6, 2], 'eof' => [8, 0]}.each do |window, (start, count)|
            scan = report.fetch(window)
            keys = expected_keys[start, count]
            fail!("#{label}/#{backend}/#{window} keys differ") unless scan.fetch('keys') == keys
            expected_columns.each do |column, values|
              fail!("#{label}/#{backend}/#{column}/#{window} values differ") unless scan.fetch('columns').fetch(column) == values[start, count]
            end
          end
        end
        offline = cell.fetch('offline')
        fail!("#{label} offline .values columns do not cover recursive JSON") unless
          offline.fetch('supported_columns') == GREEN_OFFLINE_COLUMNS
        expected_signatures.each do |column, values|
          fail!("#{label}/offline/#{column} values differ") unless offline.fetch(column) == values
        end
        fail!("#{label} offline .values key set differs") unless
          (offline.keys - ['supported_columns']).sort == GREEN_OFFLINE_COLUMNS.sort
      end
      validate_paired_chunked_schedules!(data.fetch('cells'))
    end

    def validate_persisted_layout!(label, layout)
      candidate = layout_for_label(label)
      expected = PERSISTED_LAYOUT_TRIPLES.fetch(layout_prefix(candidate))
      mark = label.include?('_mrk3_') ? 'mrk3' : 'mrk4'
      fail!("#{label} persisted mark format differs") unless layout.fetch('mark_format') == mark
      granules = layout.fetch('granules')
      fail!("#{label} persisted root granules differ") unless granules.size == MARK_ROWS.size
      granules.each_with_index do |granule, index|
        fail!("#{label} root mark #{index} row interval differs") unless
          granule.fetch('mark') == index && granule.fetch('row_offset') == index * 2 && granule.fetch('row_count') == 2
        fail!("#{label} Object wire version/shared layout/buckets differ") unless
          [granule.fetch('wire_version'), granule.fetch('shared_data_version'), granule.fetch('bucket_count')] ==
          expected
        fail!("#{label} persisted inferred Dynamic path roster differs at mark #{index}") unless
          granule.fetch('dynamic_paths').sort == %w[note sample]
        if mark == 'mrk4'
          fail!("#{label} mrk4 first root callback differs") unless granule.fetch('first_stream') == 'root.object_structure'
        end
        stats = granule.fetch('statistics_shared')
        if index.zero?
          fail!("#{label} first persisted shared-path statistics omit zz_overflow") unless
            stats.any? { |entry| entry.fetch('name') == 'zz_overflow' && entry.fetch('count').to_i.positive? }
        else
          counts = granule.fetch('statistics_counts')
          fail!("#{label} later Object prefix retained first-mark statistics") unless
            counts.all? { |count| count.to_i.zero? } && stats.all? { |entry| entry.fetch('count').to_i.zero? }
        end
      end
      if label.include?('_advanced_chunked_')
        validate_chunked_object_sites!(label, granules, mark)
      else
        fail!("#{label} unexpectedly contains CHUNKED child-site evidence") unless
          granules.all? { |granule| granule.fetch('object_sites') == [] }
      end
    end

    def validate_chunked_object_sites!(label, granules, mark)
      expected_sites = CHUNKED_SITE_OWNERS.flat_map { |column, owners| owners.map { |owner| [column, owner] } }
      observed_multichunk_sites = []
      granules.each_with_index do |granule, mark_index|
        fail!("#{label} mark #{mark_index} lacks the persisted mrk4 schedule comparison") unless
          granule.fetch('callback_schedule_matches_mrk4') == true
        sites = granule.fetch('object_sites')
        fail!("#{label} mark #{mark_index} Object-site roster differs") unless
          sites.map { |site| [site.fetch('column'), site.fetch('owner')] } == expected_sites
        sites.each do |site|
          column = site.fetch('column')
          owner = site.fetch('owner')
          site_label = "#{label}/#{mark}/#{column}/#{owner}"
          fail!("#{site_label} persisted Object/shared layout differs") unless
            [site.fetch('wire_version'), site.fetch('shared_data_version'), site.fetch('bucket_count')] == [4, 3, 2]
          fail!("#{site_label} persisted Dynamic path roster differs") unless
            site.fetch('dynamic_paths').sort == %w[note sample]
          expected_parent_rows = CHUNKED_PARENT_OCCURRENCES_BY_MARK.fetch(column).fetch(mark_index)
          fail!("#{site_label} per-parent Object occurrence vector differs") unless
            site.fetch('parent_row_occurrences') == expected_parent_rows
          if column == 'docs' || column == 'tagged'
            expected_array_sizes = (column == 'docs' ? DOC_COUNTS : TAGGED_COUNTS).slice(mark_index * 2, 2)
            fail!("#{site_label} duplicated occurrence oracle differs from the independent wrapper counts") unless
              expected_parent_rows == expected_array_sizes
            witness = site.fetch('array_size_witness') || fail!("#{site_label} lacks a persisted outer Array size witness")
            expected_stream = "#{column}.size0"
            fail!("#{site_label} outer Array size source differs") unless
              site.fetch('parent_occurrence_source') == 'outer_array_size0' &&
              witness.fetch('wrapper_stream') == expected_stream &&
              witness.fetch('source_mark_format') == 'mrk4'
            fail!("#{site_label} observed outer Array sizes differ from independent literals") unless
              witness.fetch('occurrences_by_parent') == expected_array_sizes &&
              witness.fetch('occurrences_by_parent') == site.fetch('parent_row_occurrences')
            callback_schedule = witness.fetch('wrapper_callback_schedule')
            callback_index = witness.fetch('wrapper_callback_index')
            fail!("#{site_label} outer Array callback index does not identify its actual saved callback") unless
              callback_index.is_a?(Integer) && callback_index >= 0 &&
              callback_schedule.fetch(callback_index, nil) == expected_stream &&
              callback_schedule.count(expected_stream) == 1
            fail!("#{site_label} outer Array callback leaked into the nested Object site schedule") unless
              !site.fetch('callback_order').include?(expected_stream)
            fail!("#{site_label} outer Array size byte interval differs from one UInt64 per parent row") unless
              witness.fetch('parent_row_count') == MARK_ROWS.fetch(mark_index) &&
              witness.fetch('logical_end') - witness.fetch('logical_start') == 8 * MARK_ROWS.fetch(mark_index)
          else
            fail!("#{site_label} non-Array Object site unexpectedly has an Array size witness") unless
              site.fetch('array_size_witness').nil? && site.fetch('parent_occurrence_source') == 'one_object_per_parent_row' &&
              expected_parent_rows == [1, 1]
          end
          fail!("#{site_label} parent occurrence total differs from persisted chunks") unless
            expected_parent_rows.sum == CHUNKED_OCCURRENCES_BY_MARK.fetch(column).fetch(mark_index)
          callback_order = site.fetch('callback_order')
          fail!("#{site_label} callback order omits Object structure") unless
            callback_order.first == "#{owner}.object_structure"
          fail!("#{site_label} callback schedule is empty or duplicated") unless
            callback_order.uniq == callback_order && callback_order.size > 1

          buckets = site.fetch('buckets')
          fail!("#{site_label} bucket roster differs") unless buckets.map { |bucket| bucket.fetch('bucket') } == [0, 1]
          expected_rows = CHUNKED_OCCURRENCES_BY_MARK.fetch(column).fetch(mark_index)
          shared_paths = []
          buckets.each do |bucket|
            chunks = bucket.fetch('chunks')
            fail!("#{site_label} bucket #{bucket.fetch('bucket')} chunk count differs from independent fixture rows") unless
              chunks.size == expected_rows
            fail!("#{site_label} bucket #{bucket.fetch('bucket')} lacks one-row persisted chunks") unless
              chunks.all? { |chunk| chunk.fetch('row_count') == 1 }
            chunks.each { |chunk| shared_paths.concat(chunk.fetch('paths')) }
            observed_multichunk_sites << [column, owner] if chunks.size > 1
          end
          fail!("#{site_label} persisted chunks omit Object shared spill path") unless shared_paths.include?('zz_overflow')
          buckets.each do |bucket|
            prefix = "#{owner}.object_shared_data.#{bucket.fetch('bucket')}.structure_prefix"
            suffix = "#{owner}.object_shared_data.#{bucket.fetch('bucket')}.structure_suffix"
            fail!("#{site_label} callback order omits chunk structure lanes") unless
              callback_order.index(prefix) && callback_order.index(suffix) && callback_order.index(prefix) < callback_order.index(suffix)
          end
        end
      end
      expected_sites.each do |column, owner|
        fail!("#{label} never persisted multiple chunks for #{column}/#{owner}") unless
          observed_multichunk_sites.include?([column, owner])
      end
      %w[docs tagged].each do |column|
        vectors = CHUNKED_PARENT_OCCURRENCES_BY_MARK.fetch(column)
        fail!("#{label} #{column} fixture lost empty parent occurrences") unless vectors.flatten.include?(0)
        fail!("#{label} #{column} fixture lost unequal parent occurrence counts") unless vectors.any? { |pair| pair[0] != pair[1] }
      end
    end

    def validate_paired_chunked_schedules!(cells)
      indexed = cells.to_h { |cell| [cell.fetch('label'), cell.fetch('persisted_root_layout')] }
      LABELS.select { |label| label.include?('_advanced_chunked_mrk3_') }.each do |mrk3_label|
        mrk4_label = mrk3_label.sub('_mrk3_', '_mrk4_')
        mrk3_granules = indexed.fetch(mrk3_label).fetch('granules')
        mrk4_granules = indexed.fetch(mrk4_label).fetch('granules')
        mrk3_granules.zip(mrk4_granules).each_with_index do |(left, right), mark_index|
          left_sites = left.fetch('object_sites').map do |site|
            [site.fetch('column'), site.fetch('owner'), site.fetch('callback_order'),
             site.fetch('parent_occurrence_source'), site.fetch('parent_row_occurrences'),
             site.fetch('array_size_witness')]
          end
          right_sites = right.fetch('object_sites').map do |site|
            [site.fetch('column'), site.fetch('owner'), site.fetch('callback_order'),
             site.fetch('parent_occurrence_source'), site.fetch('parent_row_occurrences'),
             site.fetch('array_size_witness')]
          end
          fail!("#{mrk3_label} mark #{mark_index} persisted callbacks/Array witnesses differ from its paired mrk4 part") unless left_sites == right_sites
        end
      end
    end

    def layout_prefix(layout)
      "obj_#{layout.fetch(:object)}_dyn_#{layout.fetch(:dynamic)}_#{layout.fetch(:shared)}"
    end

    def layout_for_label(label)
      match = /\A(?<prefix>obj_v[123]_dyn_v[123]_.+)_mrk[34]_s[01]_variant_(?:basic|compact)\z/.match(label)
      fail!("#{label.inspect} is not a complete W263 layout label") unless match
      prefix = match[:prefix]
      LAYOUTS.find { |candidate| layout_prefix(candidate) == prefix } ||
        fail!("#{label.inspect} has no exact W263 Object version/layout")
    end

    def self_check_layout_parser!
      configured_prefixes = LAYOUTS.map { |layout| layout_prefix(layout) }.sort
      oracle_prefixes = PERSISTED_LAYOUT_TRIPLES.keys.sort
      fail!('independent persisted-layout oracle does not cover the six settings layouts') unless
        configured_prefixes == oracle_prefixes && configured_prefixes.size == 6

      LAYOUTS.each do |layout|
        parsed = layout_for_label("#{layout_prefix(layout)}_mrk3_s0_variant_basic")
        fail!('exact layout parser changed a settings descriptor') unless parsed == layout
      end

      # Negative collision checks: longer names must not be admitted by their
      # shorter `_map` / `_advanced` prefix.
      {
        'obj_v3_dyn_v3_map_with_buckets_mrk3_s0_variant_basic' => 'map_with_buckets',
        'obj_v3_dyn_v3_advanced_chunked_mrk3_s0_variant_basic' => 'advanced_chunked',
      }.each do |label, expected_shared|
        parsed = layout_for_label(label)
        fail!("exact layout parser collapsed #{expected_shared} into #{parsed.fetch(:shared)}") unless
          parsed.fetch(:shared) == expected_shared
      end

      [
        'obj_v3_dyn_v3_map_with_buckets_suffix_mrk3_s0_variant_basic',
        'obj_v3_dyn_v3_advanced_chunked_suffix_mrk3_s0_variant_basic',
      ].each do |label|
        begin
          layout_for_label(label)
        rescue Failure
          next
        end
        fail!("layout parser accepted noncanonical collision label #{label}")
      end
    end

    def expected_signatures
      {
        'scalar' => (1..ROWS).map { |value| "UInt8:#{value}" },
        'text' => (1..ROWS).map { |value| "String:#{JSON.generate("text-#{value}")}" },
        'payload' => PAYLOADS.map { |value| dynamic_value_signature(value) },
        'choice' => CHOICES.map { |value| variant_value_signature(value) },
        'root' => (1..ROWS).map { |value| document_signature(root_json(value), JSON_TYPE) },
        'docs' => (0...ROWS).map do |row|
          docs_json(row).map { |doc| document_signature(doc, JSON_TYPE) }.then { |items| "#{DOCS}[#{items.join(';')}]" }
        end,
        'tagged' => (0...ROWS).map do |row|
          tagged_json(row).map do |doc, slot|
            "Tuple(doc #{JSON_TYPE}, slot UInt8)(#{document_signature(doc, JSON_TYPE)},UInt8:#{slot})"
          end.then { |items| "#{TAGGED}[#{items.join(';')}]" }
        end,
        'pair' => (1..ROWS).map do |value|
          left, right = pair_json(value)
          "#{PAIR}(#{document_signature(left, JSON_TYPE)},#{document_signature(right, JSON_TYPE)})"
        end,
      }
    end

    def document_signature(document, declaration)
      body = document.keys.sort.map { |path| "#{path}=#{json_leaf_signature(document.fetch(path), path)}" }.join(',')
      "#{declaration}{#{body}}"
    end

    def json_leaf_signature(value, path)
      case value
      when String then "String:#{JSON.generate(value)}"
      when Integer then path == 'id' ? "UInt8:#{value}" : "Int64:#{value}"
      when Float then "Float64:0x#{[value].pack('E').unpack1('Q<').to_s(16).rjust(16, '0')}"
      else fail!("unexpected independent JSON leaf #{value.inspect}")
      end
    end

    def dynamic_value_signature(value)
      kind, body = value
      leaf = case kind
             when :uint8 then "UInt8:#{body}"
             when :uint64 then "UInt64:#{body}"
             when :float64 then "Float64:0x#{[body].pack('E').unpack1('Q<').to_s(16).rjust(16, '0')}"
             when :string then "String:#{JSON.generate(body)}"
             else fail!("unexpected Dynamic literal #{value.inspect}")
             end
      "#{DYNAMIC}<#{leaf}>"
    end

    def variant_value_signature(value)
      kind, body = value
      if kind == :string
        "#{VARIANT}#0(String:#{JSON.generate(body)})"
      else
        "#{VARIANT}#1(UInt64:#{body})"
      end
    end

    def write_new(path, bytes)
      File.open(path, 'wbx', 0o600) { |file| file.write(bytes) }
    end

    def sql_string(value)
      "'#{value.to_s.gsub(/[\\']/) { |character| "\\#{character}" }}'"
    end

    def hex(value)
      value.to_s.b.unpack1('H*').upcase
    end

    def cast_json(value)
      "CAST(#{sql_string(JSON.generate(value))}, #{sql_string(JSON_TYPE)})"
    end

    def json_sql(identity, label: "json-#{identity}")
      cast_json({'id' => identity, 'label' => label, 'note' => "note-#{identity}",
                 'sample' => identity.odd? ? identity * 10 : SAMPLE_FLOATS.fetch((identity - 1) % SAMPLE_FLOATS.size),
                 'zz_overflow' => "overflow-#{identity}"})
    end

    def payload_sql(value)
      kind, body = value
      scalar = case kind
               when :uint8 then "toUInt8(#{body})"
               when :uint64 then "toUInt64(#{body})"
               when :float64 then "toFloat64(#{body})"
               when :string then sql_string(body)
               else fail!("unknown Dynamic payload literal #{value.inspect}")
               end
      "CAST(#{scalar}, #{sql_string(DYNAMIC)})"
    end

    def variant_sql(value)
      kind, body = value
      scalar = kind == :string ? sql_string(body) : "toUInt64(#{body})"
      "CAST(#{scalar}, #{sql_string(VARIANT)})"
    end

    def docs_sql(row_index)
      values = DOC_COUNTS.fetch(row_index).times.map do |child|
        identity = 20 + row_index * 4 + child
        json_sql(identity, label: "doc-#{row_index + 1}-#{child + 1}")
      end
      "CAST([#{values.join(', ')}], #{sql_string(DOCS)})"
    end

    def tagged_sql(row_index)
      values = TAGGED_COUNTS.fetch(row_index).times.map do |child|
        identity = 80 + row_index * 4 + child
        "tuple(#{json_sql(identity, label: "tag-#{row_index + 1}-#{child + 1}")}, toUInt8(#{child + 1}))"
      end
      "CAST([#{values.join(', ')}], #{sql_string(TAGGED)})"
    end

    def pair_sql(identity)
      left = json_sql(120 + identity, label: "left-#{identity}")
      right = json_sql(140 + identity, label: "right-#{identity}")
      "CAST(tuple(#{left}, #{right}), #{sql_string(PAIR)})"
    end

    def schema_for(label)
      SCHEMA
    end

    def settings_for(label)
      config = layout_for_label(label)
      string_version = label.include?('_s1_') ? 1 : 0
      string_setting = string_version == 1 ? 'with_size_stream' : 'single_stream'
      variant_setting = label.end_with?('_variant_compact') ? 1 : 0
      mark_setting = label.include?('_mrk4_') ? 1 : 0
      settings = [
        'index_granularity=2', 'index_granularity_bytes=10485760', 'enable_mixed_granularity_parts=1',
        'min_rows_for_wide_part=1000000', 'min_bytes_for_wide_part=0', 'compress_marks=0',
        'compress_primary_key=0', 'min_compress_block_size=0', 'max_compress_block_size=4096',
        'ratio_of_defaults_for_sparse_serialization=1', "default_compression_codec='LZ4'",
        "serialization_info_version='with_types'", 'propagate_types_serialization_versions_to_nested_types=1',
        "string_serialization_version='#{string_setting}'", "dynamic_serialization_version='#{config.fetch(:dynamic)}'",
        "object_serialization_version='#{config.fetch(:object)}'",
        "object_shared_data_serialization_version='#{config.fetch(:shared)}'",
        "object_shared_data_serialization_version_for_zero_level_parts='#{config.fetch(:shared)}'",
        "object_shared_data_buckets_for_compact_part=2", "use_compact_variant_discriminators_serialization=#{variant_setting}",
        "write_marks_for_substreams_in_compact_parts=#{mark_setting}",
        "nullable_serialization_version='basic'", "map_serialization_version='basic'",
        "map_serialization_version_for_zero_level_parts='basic'",
      ]
      settings << 'object_shared_data_target_chunk_rows=1' if config.fetch(:shared) == 'advanced_chunked'
      settings.join(', ')
    end

    def initial_sql
      statements = [
        'SET merge_tree_use_v1_object_and_dynamic_serialization=0;',
        'SET flatten_nested=0;', 'SET output_format_json_named_tuples_as_objects=0;',
        'SET print_pretty_type_names=0;',
        "SELECT '#{TAG[:pin]}', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
      ]
      LABELS.each do |label|
        table = TABLES.fetch(label)
        declarations = schema_for(label).map { |name, type| "`#{name}` #{type}" }.join(', ')
        statements << "CREATE TABLE default.#{table} (#{declarations}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings_for(label)};"
        values = (1..ROWS).map do |identity|
          ["toUInt64(#{identity})", "toUInt8(#{identity})", sql_string("text-#{identity}"),
           payload_sql(PAYLOADS.fetch(identity - 1)), variant_sql(CHOICES.fetch(identity - 1)),
           json_sql(identity), docs_sql(identity - 1), tagged_sql(identity - 1), pair_sql(identity)].join(', ')
        end
        statements << "INSERT INTO default.#{table} VALUES\n#{values.map { |row| "(#{row})" }.join(",\n")};"
        statements << "SELECT '#{TAG[:check_begin]}', '#{table}' FORMAT TSVRaw;"
        statements << "CHECK TABLE default.#{table} FORMAT TSV;"
        statements << "SELECT '#{TAG[:check_end]}', '#{table}' FORMAT TSVRaw;"
      end
      quoted_tables = TABLES.values.map { |table| sql_string(table) }.join(', ')
      statements << "SELECT '#{TAG[:schema]}', table, name, type FROM system.columns WHERE database='default' AND table IN (#{quoted_tables}) ORDER BY table, position FORMAT TSVRaw;"
      statements << "SELECT '#{TAG[:part]}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table IN (#{quoted_tables}) AND active ORDER BY table, name FORMAT TSVRaw;"
      LABELS.each do |label|
        table = TABLES.fetch(label)
        statements << "SELECT '#{TAG[:rows]}', '#{table}', toString(pk), toString(scalar), hex(text), dynamicType(payload), " \
          "toString(toUInt8(isDynamicElementInSharedData(payload))), hex(toJSONString(payload)), variantType(choice), " \
          "hex(toJSONString(choice)), hex(toJSONString(root)), toString(root.id), hex(root.label), " \
          "hex(toJSONString(JSONDynamicPaths(root))), hex(toJSONString(JSONSharedDataPaths(root))), " \
          "dynamicType(root.sample), toString(toUInt8(isDynamicElementInSharedData(root.sample))), " \
          "hex(toJSONString(docs)), hex(toJSONString(tagged)), hex(toJSONString(pair)) " \
          "FROM default.#{table} ORDER BY pk FORMAT TSVRaw;"
      end
      statements.join("\n") + "\n"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    options = {binary: ProbeCompactJSONW263::BINARY, helper: nil, root: nil, mode: 'baseline'}
    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby scripts/probe_compact_json_w263.rb --mode baseline|green --crystal-helper PREBUILT --evidence-root EMPTY_/private/tmp_CHILD [--clickhouse PINNED]'
      parser.on('--clickhouse PATH', 'Pinned ClickHouse 26.10.1.1201 executable') { |value| options[:binary] = value }
      parser.on('--crystal-helper PATH', 'Prebuilt Crystal helper; this runner never compiles it') { |value| options[:helper] = value }
      parser.on('--evidence-root PATH', 'Existing empty direct child of /private/tmp') { |value| options[:root] = value }
      parser.on('--mode MODE', %w[baseline green], 'baseline checks current JSON refusals; green checks admitted readers') { |value| options[:mode] = value }
    end.parse!
    abort 'W263: --crystal-helper and --evidence-root are required' unless options[:helper] && options[:root]
    ok = ProbeCompactJSONW263::Probe.new(binary: options[:binary], helper: options[:helper], evidence_root: options[:root], mode: options[:mode]).run
    exit(ok ? 0 : 1)
  rescue StandardError => error
    warn "W263 runner error: #{error.class}: #{error.message}"
    exit 1
  end
end
