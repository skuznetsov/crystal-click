#!/usr/bin/env ruby
# Stock-first native witness for JSON Object children carried by typed Dynamic
# fields, including direct JSON and Array^2/Array^3 JSON Dynamic actuals.
# Native RowBinary literals and read expectations are independent of the
# Crystal fixture/helper.

require 'digest'
require 'json'
require 'open3'
require 'optparse'
require 'set'
require_relative 'probe_compact_advanced_json_writer_w278'

module ProbeCompactChildJsonWriterW279
  W278 = ProbeCompactAdvancedJsonWriterW278
  W277 = W278::W277
  W276 = W278::W276
  W271 = W278::W271
  W241 = W278::W241

  FORMAT = 'compact_child_json_writer_w279_native_probe_v1'.freeze
  HELPER_FORMAT = 'compact_child_json_writer_w279_helper_v1'.freeze
  PART_NAME = W277::PART_NAME
  BINARY = W278::BINARY
  BINARY_SHA256 = W278::BINARY_SHA256
  VERSION = W278::VERSION
  BUILD = W278::BUILD
  SOURCE_ROOT = W278::SOURCE_ROOT
  SOURCE_REVISION = W278::SOURCE_REVISION
  SOURCE_FILES = (W278::SOURCE_FILES + %w[
    src/DataTypes/Serializations/SerializationObject.h
    src/DataTypes/Serializations/SerializationObject.cpp
    src/DataTypes/DataTypesBinaryEncoding.cpp
    src/DataTypes/DataTypesBinaryEncoding.h
  ]).uniq.freeze

  PROBE_SOURCE = File.expand_path(__FILE__).freeze
  W278_SOURCE = W278::PROBE_SOURCE
  W277_SOURCE = W277::PROBE_SOURCE
  W276_SOURCE = W276::PROBE_SOURCE
  W241_SOURCE = W276::W241_SOURCE
  W271_SOURCE = W276::W271_SOURCE
  W273_SOURCE = W276::W273_SOURCE
  W264_SOURCE = W276::W264_SOURCE
  HELPER_SOURCE = File.expand_path('compact_child_json_writer_w279_helper.cr', __dir__).freeze
  NATIVE_FIXTURE_SOURCE = File.expand_path('support/compact_part_writer_w279_native_fixture.cr', __dir__).freeze

  ROWS_PER_MARK = 2
  ROW_COUNT = 8
  DATA_MARK_COUNT = 4
  PHYSICAL_MARK_ROWS_WITH_EOF = [2, 2, 2, 2, 0].freeze
  WRITER_MARK_ROWS = [2, 2, 2, 2].freeze
  MAX_W279_JSON_SUMMARY_BYTES = 128 * 1024 * 1024
  MAX_W279_MARKDOWN_SUMMARY_BYTES = 1024 * 1024
  MAX_RAW_FILE_BYTES = W277::MAX_RAW_FILE_BYTES
  MAX_HELPER_REPORT_BYTES = W277::MAX_REPORT_BYTES
  MAX_PART_FILES = W277::MAX_PART_FILES
  MAX_PART_BYTES = W277::MAX_PART_BYTES

  LAYOUTS = %w[map map_with_buckets advanced advanced_chunked].freeze
  SHARED_VERSIONS = LAYOUTS
  PROFILES = %w[s0 s1].freeze
  MARK_FORMATS = %w[mrk3 mrk4].freeze
  MARK_COMPRESSION = %w[plain compressed].freeze
  VARIANT_MODES = %w[basic compact].freeze
  EFFECTIVE_BUCKETS = {map: 1, map_with_buckets: 2, advanced: 2, advanced_chunked: 2}.freeze
  SHARED_VERSION_VALUES = {map: 0, map_with_buckets: 1, advanced: 2, advanced_chunked: 3}.freeze
  WINDOWS = W277::WINDOWS
  PHYSICAL_WINDOWS = W277::PHYSICAL_WINDOWS

  ROOT_TYPE = 'JSON(max_dynamic_types=1,max_dynamic_paths=0,payload Dynamic(max_types=1))'.freeze
  LEAF_TYPE = 'JSON(max_dynamic_types=0, max_dynamic_paths=0, id UInt64, label String)'.freeze
  ACTUAL_TYPES = {
    'typed_dynamic_json_w279' => LEAF_TYPE,
    'typed_dynamic_array2_json_w279' => "Array(Array(#{LEAF_TYPE}))".freeze,
    'typed_dynamic_array3_json_w279' => "Array(Array(Array(#{LEAF_TYPE})))".freeze,
  }.freeze
  COLUMN_DEPTHS = {
    'typed_dynamic_json_w279' => 0,
    'typed_dynamic_array2_json_w279' => 2,
    'typed_dynamic_array3_json_w279' => 3,
  }.freeze
  VALUE_COLUMNS = ACTUAL_TYPES.keys.freeze
  SCHEMA = ([['pk', 'UInt64']] + VALUE_COLUMNS.map { |name| [name, ROOT_TYPE] }).map(&:freeze).freeze
  SCHEMAS = LAYOUTS.to_h { |layout| [layout, SCHEMA] }.freeze

  JSON_LEAF_BINARY_TYPE = ['300000000202696404056c6162656c150000'].pack('H*').b.freeze
  ARRAY_BINARY_TYPE = "\x1e".b.freeze
  LONG_STRING = ('long:' + ('x' * 256)).b.freeze
  BINARY_STRING = ['00ff8041'].pack('H*').b.freeze
  SHARED_NUL = "shared\0nul".b.freeze
  SHARED_PATHS = %w[aa alpha beta].freeze
  SHARED_VALUE_ORDER = %w[alpha aa beta].freeze

  def self.shared_values(index, prefix)
    {
      'alpha' => index == 0 ? ''.b : (index == 3 ? LONG_STRING : "#{prefix}-alpha-shared-#{index}".b),
      'aa' => index == 1 ? BINARY_STRING : "#{prefix}-aa-shared-#{index}".b,
      'beta' => index == 5 ? SHARED_NUL : "#{prefix}-beta-shared-#{index}".b,
    }.freeze
  end

  # Literal input is intentionally independent from the Crystal fixture.
  # The three root JSON columns all have the same declared shape; their
  # `payload` Dynamic actuals are JSON, Array(Array(JSON)), and
  # Array(Array(Array(JSON))) respectively.
  CHILD_DOCS = {
    11 => {id: 11, label: 'child-11'.b, shared: shared_values(0, 'child')},
    12 => {id: 12, label: 'child-12'.b, shared: shared_values(1, 'child')},
    13 => {id: 13, label: 'child-13'.b, shared: shared_values(5, 'child')},
    14 => {id: 14, label: 'child-14'.b, shared: shared_values(2, 'child')},
    81 => {id: 81, label: 'child-81'.b, shared: shared_values(4, 'child')},
    82 => {id: 82, label: 'child-82'.b, shared: shared_values(3, 'child')},
    83 => {id: 83, label: 'child-83'.b, shared: shared_values(6, 'child')},
  }.freeze
  PAYLOADS = {
    'typed_dynamic_json_w279' => [11, nil, nil, nil, 82, nil, nil, 83],
    'typed_dynamic_array2_json_w279' => [[[11, 12], [13]], nil, nil, nil, [], [[]], nil, [[81], [82, 83], []]],
    'typed_dynamic_array3_json_w279' => [[[[11, 12], []], [[13, 14]]], nil, nil, nil, [], [[]], [[[]]], [[[81]], [[82, 83], []], []]],
  }.freeze
  ROOT_SHARED = VALUE_COLUMNS.to_h do |column|
    [column, ROW_COUNT.times.map { |index| shared_values(index, column) }.freeze]
  end.freeze

  class Failure < StandardError; end

  class Probe < W278::Probe
    def initialize(binary:, source_root:, evidence_root:, stock_only: true, full_matrix: false,
                   helper: nil, helper_sha256: nil, case_limit: nil, cell: [])
      super(binary: binary, source_root: source_root, evidence_root: evidence_root,
            stock_only: stock_only, full_matrix: full_matrix, helper: helper, helper_sha256: helper_sha256)
      @case_limit = case_limit.nil? ? nil : Integer(case_limit)
      @cell_selectors = Array(cell).dup
      fail!('--case-limit must be between 1 and 64') if @case_limit && !@case_limit.between?(1, 64)
      fail!('--case-limit and --cell cannot be combined') if @case_limit && !@cell_selectors.empty?
      @selected_axes, @selection_mode = select_cells
      @profiles_by_id = {}
    rescue ArgumentError => error
      fail!("invalid case limit: #{error.message}")
    end

    def run
      prepare!
      @selected_axes.each do |layout, profile, mark_format, compression, mode|
        id = cell_id('stock', layout, profile, mark_format, compression, mode)
        @stock[id] = capture_stock!(id, layout, profile, mark_format, compression, mode)
      end
      assert_profile_roster_deltas! if @selected_axes.size == 64
      if @full_matrix
        @stock.each { |id, entry| capture_w279_stock_helper!(id, entry) }
        @selected_axes.each do |layout, profile, mark_format, compression, mode|
          id = cell_id('generated', layout, profile, mark_format, compression, mode)
          @generated[id] = capture_w279_generated!(id, layout, profile, mark_format, compression, mode)
        end
      end
      validate_process_evidence!
      validate_pins!
      summary = build_summary
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      write_new(File.join(@root, 'summary.md'), render_summary(summary))
      puts "W279 status=#{summary.fetch(:status)}; stock=#{@stock.size}; generated=#{@generated.size}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      persist_inconclusive(error)
      warn "W279 probe inconclusive: #{@fatal_error}"
      false
    end

    private

    def fail!(message)
      raise Failure, "W279: #{message}"
    end

    def validate_literals!
      fail!('W279 requires exactly three root JSON columns with the frozen typed Dynamic declaration') unless
        SCHEMA == [['pk', 'UInt64']] + VALUE_COLUMNS.map { |name| [name, ROOT_TYPE] }
      fail!('native fixture must contain eight ordered keys and four two-row data marks') unless
        ROW_COUNT == 8 && (1..8).to_a.each_slice(ROWS_PER_MARK).to_a.size == DATA_MARK_COUNT
      fail!('direct/Array^2/Array^3 payload roster changed') unless
        PAYLOADS.fetch(VALUE_COLUMNS.fetch(0)).values_at(1, 2, 3, 5, 6).all?(&:nil?) &&
        PAYLOADS.fetch(VALUE_COLUMNS.fetch(1)).values_at(1, 2, 3, 6).all?(&:nil?) &&
        PAYLOADS.fetch(VALUE_COLUMNS.fetch(2)).values_at(1, 2, 3).all?(&:nil?)
      fail!('native fixture no longer includes empty, nested-empty, and EOF payload cases') unless
        PAYLOADS.fetch(VALUE_COLUMNS.fetch(1)).values_at(4, 5) == [[], [[]]] &&
        PAYLOADS.fetch(VALUE_COLUMNS.fetch(2)).values_at(4, 5, 6) == [[], [[]], [[[]]]]
      fail!('native child literals do not contain exactly the referenced ids') unless
        PAYLOADS.values.flatten.compact.flat_map { |item| flatten_ids(item) }.uniq.sort == CHILD_DOCS.keys.sort
      fail!('matrix is not the exact 64-cell W279 cross-product') unless
        LAYOUTS.size * PROFILES.size * MARK_FORMATS.size * MARK_COMPRESSION.size * VARIANT_MODES.size == 64
      true
    end

    def flatten_ids(value)
      value.is_a?(Array) ? value.flat_map { |child| flatten_ids(child) } : [value]
    end

    def prepare!
      %w[invocations stores source-inventories raw-records parts].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      @binary_sha_before = sha(@binary)
      fail!('ClickHouse executable differs from pinned runtime SHA-256') unless @binary_sha_before == BINARY_SHA256
      revision, stderr, status = Open3.capture3('git', '-C', @source_root, 'rev-parse', 'HEAD')
      fail!("pinned upstream source revision check failed: #{stderr.strip}") unless status.success? && revision.strip == SOURCE_REVISION
      @source_revision_before = revision.strip
      @upstream_hashes = SOURCE_FILES.to_h do |relative|
        path = File.join(@source_root, relative)
        fail!("pinned upstream source is missing or symlinked: #{relative}") unless File.file?(path) && !File.symlink?(path)
        [relative, sha(path)]
      end
      @source_guard = source_guard!
      @probe_sources = [PROBE_SOURCE, W278_SOURCE, W277_SOURCE, W276_SOURCE, W241_SOURCE,
                        W271_SOURCE, W273_SOURCE, W264_SOURCE].map { |path| File.realpath(path) }.uniq.sort
      @probe_sources.concat([HELPER_SOURCE, NATIVE_FIXTURE_SOURCE].map { |path| File.realpath(path) }) if @full_matrix
      @probe_hashes_before = @probe_sources.to_h { |path| [path, sha(path)] }
      if @full_matrix
        @helper_sha_before = sha(@helper)
        fail!('prebuilt W279 helper SHA differs from CLI pin') unless @helper_sha_before == @helper_expected_sha
      end
    end

    def source_guard!
      facts = super
      settings = File.binread(File.join(@source_root, 'src/Storages/MergeTree/MergeTreeSettings.cpp')).force_encoding(Encoding::UTF_8)
      object_header = File.binread(File.join(@source_root, 'src/DataTypes/Serializations/SerializationObject.h')).force_encoding(Encoding::UTF_8)
      facts[:object_setting_v3_supports_shared_layouts] = settings.include?('Only version `v3` supports changing the shared data serialization version.') &&
        settings.include?('object_shared_data_serialization_version') && settings.include?('object_shared_data_buckets_for_compact_part')
      facts[:object_wire_v3_is_enum_value_4] = object_header.include?('V3 = 4,')
      fail!('pinned source does not distinguish Object setting v3 from physical wire enum value 4') unless
        facts[:object_setting_v3_supports_shared_layouts] && facts[:object_wire_v3_is_enum_value_4]
      facts.merge(object_setting: 'v3', expected_wire_version_enum: 4,
                  scope: 'setting selects the format family; parsed physical child header is checked only by full helper mode')
    end

    def validate_pins!
      @binary_sha_after = sha(@binary)
      @probe_hashes_after = @probe_sources.to_h { |path| [path, sha(path)] }
      fail!('ClickHouse runtime changed during capture') unless @binary_sha_after == BINARY_SHA256
      fail!('W279 Ruby probe or inherited Ruby source changed during capture') unless @probe_hashes_after == @probe_hashes_before
      if @full_matrix
        @helper_sha_after = sha(@helper)
        fail!('prebuilt W279 helper changed during capture') unless @helper_sha_after == @helper_sha_before
        @source_revision_after, stderr, status = Open3.capture3('git', '-C', @source_root, 'rev-parse', 'HEAD')
        fail!("pinned upstream source revision recheck failed: #{stderr.strip}") unless status.success?
        @source_revision_after = @source_revision_after.strip
        fail!('pinned upstream source revision changed during capture') unless @source_revision_after == SOURCE_REVISION
        @upstream_hashes_after = SOURCE_FILES.to_h do |relative|
          path = File.join(@source_root, relative)
          fail!("pinned upstream source disappeared or became symlinked: #{relative}") unless File.file?(path) && !File.symlink?(path)
          [relative, sha(path)]
        end
        fail!('pinned upstream source changed during capture') unless @upstream_hashes_after == @upstream_hashes
      end
    end

    def select_cells
      axes = LAYOUTS.product(PROFILES, MARK_FORMATS, MARK_COMPRESSION, VARIANT_MODES)
      if !@cell_selectors.empty?
        parsed = @cell_selectors.map do |selector|
          parts = selector.split(':', -1)
          fail!("--cell must be layout:profile:mark:compression:mode: #{selector.inspect}") unless parts.size == 5 &&
            parts[0].then { |v| LAYOUTS.include?(v) } && PROFILES.include?(parts[1]) &&
            MARK_FORMATS.include?(parts[2]) && MARK_COMPRESSION.include?(parts[3]) && VARIANT_MODES.include?(parts[4])
          parts
        end
        fail!('--cell selectors must be unique') unless parsed.uniq == parsed
        [parsed, 'explicit']
      elsif @case_limit
        [axes.first(@case_limit), 'canonical_prefix']
      else
        [axes, 'full']
      end
    end

    def cell_id(prefix, layout, profile, mark_format, compression, mode)
      [prefix, layout, profile, mark_format, compression, mode].join('_')
    end

    def marker(kind, id, window = nil)
      suffix = window ? "_#{window.upcase}" : ''
      "__W279_#{kind.to_s.upcase}_#{id.upcase}#{suffix}__"
    end

    def table_name(id)
      "w279_#{@token}_#{id}"
    end

    def schema_for(layout)
      SCHEMAS.fetch(layout) { fail!("unknown Object shared-data layout #{layout.inspect}") }
    end

    def settings(layout, mark_format, compression, mode)
      buckets = EFFECTIVE_BUCKETS.fetch(layout.to_sym)
      substream_marks = mark_format == 'mrk4' ? 1 : 0
      compress_marks = compression == 'compressed' ? 1 : 0
      discriminator = mode == 'compact' ? 1 : 0
      profile = @active_profile || fail!('active String profile is missing while creating the native table')
      string_version = profile == 's1' ? 'with_size_stream' : 'single_stream'
      [
        'index_granularity=2', 'index_granularity_bytes=10485760', 'enable_mixed_granularity_parts=1',
        'min_rows_for_wide_part=1000000', 'min_bytes_for_wide_part=104857600', 'min_level_for_wide_part=0',
        "compress_marks=#{compress_marks}", "marks_compression_codec='LZ4'", 'compress_primary_key=0',
        'write_final_mark=1', "write_marks_for_substreams_in_compact_parts=#{substream_marks}",
        'min_compress_block_size=0', 'max_compress_block_size=4096', 'ratio_of_defaults_for_sparse_serialization=1.0',
        "default_compression_codec='LZ4'", "serialization_info_version='with_types'",
        'propagate_types_serialization_versions_to_nested_types=true', "string_serialization_version='#{string_version}'",
        "object_serialization_version='v3'", "object_shared_data_serialization_version='#{layout}'",
        "object_shared_data_serialization_version_for_zero_level_parts='#{layout}'",
        "object_shared_data_buckets_for_compact_part=#{buckets}", 'object_shared_data_target_chunk_rows=1',
        "dynamic_serialization_version='v3'", "use_compact_variant_discriminators_serialization=#{discriminator}",
        'allow_suspicious_low_cardinality_types=1',
      ].join(', ')
    end

    def create_sql(table, layout, mark_format, compression, mode)
      declarations = schema_for(layout).map { |name, type| "`#{name}` #{type}" }.join(', ')
      "SET flatten_nested=0;\nSET allow_suspicious_low_cardinality_types=1;\nSET use_variant_as_common_type=1;\n" \
        "CREATE TABLE default.#{table} (#{declarations}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings(layout, mark_format, compression, mode)};\n"
    end

    def capture_stock!(id, layout, profile, mark_format, compression, mode)
      @active_profile = profile
      @profiles_by_id[id] = profile
      stock = super(id, layout, profile, mark_format, compression, mode)
      stock
    end

    def capture_w279_stock_helper!(id, stock)
      layout = stock.fetch(:shared_layout)
      profile = stock.fetch(:profile)
      mark_format = stock.fetch(:mark_format)
      part = stock.fetch(:path)
      roster = stock.fetch(:callback_roster)
      metadata = stock.fetch(:serialization_metadata)
      labels = {}
      reports = {}
      actions = {
        audit: ['audit', part, layout, profile],
        full: ['read', part, layout, profile, 'all', '0', DATA_MARK_COUNT.to_s],
        middle: ['read', part, layout, profile, 'all', '1', '2'],
        eof: ['read', part, layout, profile, 'all', DATA_MARK_COUNT.to_s, '0'],
      }
      actions.each do |window, arguments|
        label = "#{id}_helper_stock_#{window}"
        labels[window] = label
        action = arguments.first
        report = w279_helper_report!(label, *arguments)
        first_mark, mark_count = {audit: [0, DATA_MARK_COUNT], full: [0, DATA_MARK_COUNT],
                                  middle: [1, 2], eof: [DATA_MARK_COUNT, 0]}.fetch(window)
        validate_w279_helper_report!(report, id, action, first_mark, mark_count, part, layout, profile,
                                     mark_format, stock.fetch(:part_inventory), roster, metadata)
        reports[window] = report
      end
      fail!("#{id} stock part changed during helper reads") unless tree_inventory(part) == stock.fetch(:part_inventory)
      stock[:helper_stock] = {audit: reports.fetch(:audit), reads: reports.reject { |key, _| key == :audit },
                              invocation_labels: labels}
      stock
    end

    def capture_w279_generated!(id, layout, profile, mark_format, compression, mode)
      @active_profile = profile
      @profiles_by_id[id] = profile
      part = File.join(@root, 'parts', id, PART_NAME)
      Dir.mkdir(File.dirname(part), 0o700)
      write_label = "#{id}_helper_generated_write"
      write = w279_helper_report!(write_label, 'write', part, layout, mark_format, compression, mode, profile)
      inventory = tree_inventory(part)
      helper_inventory!(write, id, inventory)
      candidate_roster = native_callback_roster!("#{id}_generated", part, mark_format, layout)
      assert_stock_callback_roster!("#{id}_generated", candidate_roster, mark_format, layout)
      metadata = serialization_metadata!(id, part)
      snapshot = save_part_snapshot!(id, part, inventory, candidate_roster, metadata)
      stock = @stock.fetch(cell_id('stock', layout, profile, mark_format, compression, mode))
      validate_w279_helper_report!(write, id, 'write', 0, DATA_MARK_COUNT, part, layout, profile,
                                   mark_format, inventory, candidate_roster, metadata,
                                   requested_compression: compression, requested_mode: mode)

      target = create_target!(id, layout, mark_format, compression, mode)
      attached = attach_candidate!(id, part, inventory, target)
      check = check!("#{id}_attached", target.fetch(:table), target.fetch(:store))
      active = inspect_attached_part!(id, target.fetch(:table), target.fetch(:store), layout,
                                      mark_format, compression, mode, inventory, candidate_roster)
      values = native_values!("#{id}_attached", target.fetch(:table), target.fetch(:store), layout)
      fail!("#{id} attached native full/middle/EOF values differ") unless values.fetch(:state) == 'exact_values'
      fail!("#{id} source candidate changed during ATTACH/CHECK/read") unless tree_inventory(part) == inventory

      labels = {}
      reports = {}
      actions = {
        audit: ['audit', part, layout, profile],
        full: ['read', part, layout, profile, 'all', '0', DATA_MARK_COUNT.to_s],
        middle: ['read', part, layout, profile, 'all', '1', '2'],
        eof: ['read', part, layout, profile, 'all', DATA_MARK_COUNT.to_s, '0'],
      }
      actions.each do |window, arguments|
        label = "#{id}_helper_generated_#{window}"
        labels[window] = label
        action = arguments.first
        report = w279_helper_report!(label, *arguments)
        first_mark, mark_count = {audit: [0, DATA_MARK_COUNT], full: [0, DATA_MARK_COUNT],
                                  middle: [1, 2], eof: [DATA_MARK_COUNT, 0]}.fetch(window)
        validate_w279_helper_report!(report, id, action, first_mark, mark_count, part, layout, profile,
                                     mark_format, inventory, candidate_roster, metadata,
                                     requested_compression: nil, requested_mode: nil)
        reports[window] = report
      end
      fail!("#{id} generated part changed during helper reads") unless tree_inventory(part) == inventory
      {
        axes: axes_hash(layout, profile, mark_format, compression, mode),
        table: target.fetch(:table), part_path: part,
        library_write: {report: write, invocation_label: write_label},
        part_snapshot: snapshot, inventory: inventory,
        native: {target: target, attach: attached, check: check, active_part: active, values: values,
                 catalog_settings: active.fetch(:native_table_settings)},
        helper_generated: {audit: reports.fetch(:audit), reads: reports.reject { |key, _| key == :audit },
                           invocation_labels: labels},
      }
    end

    def w279_helper_report!(label, *arguments)
      report = helper(label, *arguments)
      record = @invocations.find { |item| item.fetch(:label) == label }
      fail!("#{label} helper process record is missing") unless record
      stdout_name = record.fetch(:stdout_file)
      fail!("#{label} stdout sidecar name is unsafe") unless stdout_name == "#{label}.stdout"
      stdout_path = File.join(@root, 'invocations', stdout_name)
      fail!("#{label} stdout sidecar is missing, symlinked, or oversized") unless
        File.file?(stdout_path) && !File.symlink?(stdout_path) && File.size(stdout_path) <= MAX_HELPER_REPORT_BYTES
      stdout = File.binread(stdout_path).force_encoding(Encoding::UTF_8)
      fail!("#{label} raw helper stdout is not valid UTF-8") unless stdout.valid_encoding?
      parsed = JSON.parse(stdout)
      fail!("#{label} sidecar JSON differs from the parsed helper report") unless parsed == report
      fail!("#{label} helper envelope differs") unless report.is_a?(Hash) &&
        report.fetch('format') == HELPER_FORMAT && report.fetch('action') == arguments.first && report.fetch('status') == 'ok'
      report
    rescue JSON::ParserError, KeyError => error
      fail!("#{label} helper report is malformed: #{error.class}: #{error.message}")
    end

    def validate_w279_helper_report!(report, id, action, first_mark, mark_count, part, layout, profile,
                                     mark_format, inventory, callback_roster, metadata,
                                     requested_compression: nil, requested_mode: nil)
      label = "#{id}/#{action}/#{first_mark}+#{mark_count}"
      shared_version = SHARED_VERSION_VALUES.fetch(layout.to_sym)
      expected_buckets = EFFECTIVE_BUCKETS.fetch(layout.to_sym)
      fail!("#{label} helper layout/profile/window differs") unless
        report.fetch('part_path') == part && report.fetch('shared_version') == layout &&
        report.fetch('shared_version_value') == shared_version && report.fetch('effective_bucket_count') == expected_buckets &&
        report.fetch('profile') == profile && report.fetch('mark_format') == mark_format &&
        report.fetch('first_mark') == first_mark && report.fetch('selected_mark_count') == mark_count
      fail!("#{label} helper row/mark grid differs") unless report.fetch('row_count') == ROW_COUNT &&
        report.fetch('data_mark_count') == DATA_MARK_COUNT && report.fetch('mark_row_counts') == WRITER_MARK_ROWS
      if action == 'write'
        fail!("#{label} write request echoes differ") unless report.fetch('requested_mark_format') == mark_format &&
          report.fetch('requested_compression') == requested_compression && report.fetch('requested_mode') == requested_mode
      else
        fail!("#{label} non-write report contains request echoes") unless report['requested_mark_format'].nil? &&
          report['requested_compression'].nil? && report['requested_mode'].nil?
      end
      first_row = first_mark * ROWS_PER_MARK
      end_row = (first_mark + mark_count) * ROWS_PER_MARK
      expected_keys = (first_row...end_row).map { |index| index + 1 }
      fail!("#{label} selected native keys differ") unless report.fetch('keys') == expected_keys
      expected_string_version = profile == 's1' ? 1 : 0
      observed_metadata = report.fetch('serialization_metadata')
      fail!("#{label} propagated String metadata differs") unless
        observed_metadata.fetch('version') == metadata.fetch(:version) &&
        observed_metadata.fetch('string_version') == metadata.fetch(:types_serialization_versions).fetch('string') &&
        observed_metadata.fetch('string_version') == expected_string_version &&
        observed_metadata.fetch('propagate_types_serialization_versions_to_nested_types') == true &&
        observed_metadata.fetch('raw') == metadata.fetch(:raw)

      columns = report.fetch('columns')
      fail!("#{label} column roster differs") unless columns.map { |column| column.fetch('name') } == VALUE_COLUMNS
      expected_signatures = expected_helper_signatures
      columns.each do |column|
        name = column.fetch('name')
        expected_type = ROOT_TYPE
        expected = expected_signatures.fetch(name).drop(first_mark * ROWS_PER_MARK).take(mark_count * ROWS_PER_MARK)
        fail!("#{label}/#{name} helper declaration/profile differs") unless
          normalize_helper_type(column.fetch('type')) == normalize_helper_type(expected_type) &&
          column.fetch('profile') == (profile == 's1' ? 'with_size_stream' : 'single_stream') &&
          column.fetch('mark_row_counts') == WRITER_MARK_ROWS && column.fetch('signatures') == expected
      end
      observed_roster = normalize_helper_roster(report.fetch('physical_roster'))
      fail!("#{label} helper callback roster differs from the captured part") unless
        observed_roster == callback_roster.fetch(:roster)
      helper_inventory!(report, label, inventory)

      expected_headers = VALUE_COLUMNS.flat_map { |column| (first_mark...(first_mark + mark_count)).map { |mark| [column, mark] } }
      headers = report.fetch('child_headers')
      fail!("#{label} child-header count differs") unless headers.size == expected_headers.size &&
        report.fetch('child_header_observation_count') == expected_headers.size
      expected_zero_count = 0
      headers.each_with_index do |header, index|
        column_name, mark = expected_headers.fetch(index)
        depth = COLUMN_DEPTHS.fetch(column_name)
        payloads = PAYLOADS.fetch(column_name)
        mark_rows = payloads.slice(mark * ROWS_PER_MARK, ROWS_PER_MARK)
        actual_count = mark_rows.count { |payload| !payload.nil? }
        leaf_count = mark_rows.compact.sum { |payload| flatten_ids(payload).size }
        expected_actual_type = ACTUAL_TYPES.fetch(column_name)
        fail!("#{label}/#{column_name}/mark#{mark} child identity/count differs") unless
          header.fetch('parent_column') == column_name && header.fetch('mark') == mark &&
          normalize_helper_type(header.fetch('actual_type')) == normalize_helper_type(expected_actual_type) &&
          header.fetch('actual_count') == actual_count && header.fetch('json_leaf_count') == leaf_count
        expected_zero_count += 1 if actual_count.zero?
        key = header.fetch('leaf_key')
        fail!("#{label}/#{column_name}/mark#{mark} exact typed-Dynamic leaf key differs") unless
          key.fetch('dynamic_site') == 'root' && key.fetch('canonical_arm_index') == 0 &&
          key.fetch('descriptor_child_path') == Array.new(depth, 0)
        parent = header.fetch('parent')
        parsed = header.fetch('parsed')
        fail!("#{label}/#{column_name}/mark#{mark} parent/child Object layout differs") unless
          parent.fetch('version') == 4 && parsed.fetch('version') == 4 &&
          parent.fetch('shared_data_version') == shared_version && parsed.fetch('shared_data_version') == shared_version &&
          parent.fetch('bucket_count') == expected_buckets && parsed.fetch('bucket_count') == expected_buckets &&
          parent.fetch('payload_dynamic_type') == header.fetch('actual_type') &&
          header.fetch('child_shared_bucket_count') == expected_buckets &&
          header.fetch('ordinary_profile') == profile && header.fetch('child_profile') == profile
        header_hex = header.fetch('header_hex')
        fail!("#{label}/#{column_name}/mark#{mark} captured ObjectStructure bytes are malformed") unless
          header_hex.match?(/\A(?:[0-9a-f]{2})+\z/) && header.fetch('header_bytes') == header_hex.length / 2
        fail!("#{label}/#{column_name}/mark#{mark} child owner prefix is incomplete") unless
          %w[physical_prefix raw_prefix canonical_prefix callback_name captured_prefix_name object_structure_stream_name].all? do |name|
            value = header.fetch(name)
            value.is_a?(String) && !value.empty?
          end
        fail!("#{label}/#{column_name}/mark#{mark} raw and retained ObjectStructure names differ") unless
          header.fetch('callback_name') == "#{header.fetch('raw_prefix')}.object_structure" &&
          header.fetch('captured_prefix_name') == header.fetch('object_structure_stream_name') &&
          header.fetch('object_structure_stream_name') == "#{header.fetch('canonical_prefix')}.object_structure"
        fail!("#{label}/#{column_name}/mark#{mark} child statistics context is not explicit") unless
          %w[prefix_only complete].include?(header.fetch('statistics_context'))
        validate_header_slot!(header, column_name, mark_format, callback_roster, label)
        validate_child_body_roster!(header, profile, label)
      end
      fail!("#{label} zero-occurrence header count differs") unless report.fetch('zero_occurrence_header_count') == expected_zero_count
      expected_eof = first_mark == DATA_MARK_COUNT && mark_count.zero?
      fail!("#{label} EOF observation flag differs") unless report.fetch('eof_zero_observations') == expected_eof
      report
    rescue KeyError, TypeError, NoMethodError => error
      fail!("#{label} helper report is incomplete: #{error.class}: #{error.message}")
    end

    def helper_inventory!(report, label, expected_inventory)
      observed = report.fetch('files').map { |file| [file.fetch('path'), file.fetch('size'), file.fetch('sha256')] }.sort
      expected = expected_inventory.fetch(:files).map { |file| [file.fetch(:path), file.fetch(:size), file.fetch(:sha256)] }.sort
      fail!("#{label} helper file inventory differs from the captured part") unless observed == expected
      true
    end

    def normalize_helper_type(type)
      type.gsub(/\s+/, '')
    end

    def expected_helper_signatures
      VALUE_COLUMNS.to_h do |column|
        signatures = ROW_COUNT.times.map do |row_index|
          paths = ROOT_SHARED.fetch(column).fetch(row_index).to_h do |path, bytes|
            [path, helper_string_signature(bytes)]
          end
          payload = PAYLOADS.fetch(column).fetch(row_index)
          paths['payload'] = if payload.nil?
                               'NULL(Dynamic(max_types=1))'
                             else
                               depth = COLUMN_DEPTHS.fetch(column)
                               "D<#{ACTUAL_TYPES.fetch(column)}>[#{helper_actual_signature(payload, depth)}]"
                             end
          helper_json_signature(paths)
        end
        [column, signatures]
      end
    end

    def helper_json_signature(paths)
      fields = paths.keys.sort_by(&:b).map do |path|
        "#{path.bytesize}:#{path.unpack1('H*')}=#{paths.fetch(path)}"
      end
      "JSON{#{fields.join(';')}}"
    end

    def helper_string_signature(bytes)
      "S#{bytes.bytesize}:#{bytes.unpack1('H*')}"
    end

    def helper_actual_signature(value, depth)
      return helper_json_leaf_signature(value) if depth.zero?

      type = Array.new(depth) { 'Array(' }.join + LEAF_TYPE + (')' * depth)
      children = value.map { |child| helper_actual_signature(child, depth - 1) }
      "A<#{type}>[#{children.join(';')}]"
    end

    def helper_json_leaf_signature(child_id)
      document = CHILD_DOCS.fetch(child_id)
      paths = {
        'id' => "U64:#{document.fetch(:id)}",
        'label' => "S#{document.fetch(:label).bytesize}:#{document.fetch(:label).unpack1('H*')}",
      }
      document.fetch(:shared).each do |path, bytes|
        paths[path] = helper_string_signature(bytes)
      end
      "J<#{LEAF_TYPE}>{#{paths.keys.sort_by(&:b).map { |path| "#{path.bytesize}:#{path.unpack1('H*')}=#{paths.fetch(path)}" }.join(';')}}"
    end

    def validate_header_slot!(header, column_name, mark_format, callback_roster, label)
      roster = callback_roster.fetch(:roster)
      slot = header.fetch('parent_physical_slot')
      fail!("#{label}/#{column_name} parent Object slot is not in the captured physical roster") unless
        slot.fetch('column') == column_name && roster.include?([slot.fetch('index'), column_name, slot['stream']])
      stream = header.fetch('physical_stream_name')
      object_stream = header.fetch('object_structure_stream_name')
      if mark_format == 'mrk3'
        sequential = header.fetch('mrk3_sequential_owner_slot')
        fail!("#{label}/#{column_name} MRK3 child is not sequentially owned by its parent slot") unless
          stream.nil? && header.fetch('owner_mode') == 'sequential_inline' &&
          header['mrk4_physical_slot'].nil? && sequential == slot && slot['stream'].nil? &&
          slot.fetch('index').is_a?(Integer) && sequential.fetch('index') == slot.fetch('index')
      else
        child_slot = header.fetch('mrk4_physical_slot')
        fail!("#{label}/#{column_name} MRK4 child ObjectStructure slot is not exact") unless
          stream == object_stream && header.fetch('owner_mode') == 'named' &&
          child_slot.fetch('column') == column_name && child_slot.fetch('stream') == object_stream &&
          roster.include?([child_slot.fetch('index'), column_name, object_stream])
      end
      true
    end

    def validate_child_body_roster!(header, profile, label)
      roster = header.fetch('child_body_callback_roster')
      fail!("#{label} child body callback capture is incomplete") unless
        header.fetch('child_body_callback_count') == roster.size && roster.all? do |pair|
          pair.fetch('canonical_name').is_a?(String) && !pair.fetch('canonical_name').empty? &&
            pair.fetch('callback_name').is_a?(String) && !pair.fetch('callback_name').empty?
        end
      canonical_names = roster.map { |pair| pair.fetch('canonical_name') }
      fail!("#{label} child body callback names are duplicated") unless canonical_names.uniq == canonical_names
      callbacks = header.fetch('child_label_callbacks')
      # `root.string_sizes` is the semantic plan role; the captured physical
      # callback lane is the label prefix plus `.size`. Preserve the full
      # canonical owner names rather than guessing the nested owner prefix.
      callback_names = callbacks.map { |callback| callback.fetch('canonical_name') }
      label_names = callback_names.select { |name| name == 'label' || name.end_with?('.label') }
      size_names = callback_names.select { |name| name.end_with?('.label.size') }
      expected_callbacks = profile == 's1' ? 2 : 1
      fail!("#{label} retained label data/size lanes differ from String profile") unless
        callbacks.size == expected_callbacks && label_names.size == 1 &&
        size_names.size == (profile == 's1' ? 1 : 0) &&
        (profile != 's1' || size_names.first == "#{label_names.first}.size") &&
        (callback_names - canonical_names).empty? &&
        callbacks.all? do |callback|
          callback.fetch('callback_name').is_a?(String) && !callback.fetch('callback_name').empty? &&
            callback.fetch('byte_count').is_a?(Integer) && callback.fetch('byte_count') >= 0 &&
            callback.fetch('sha256').match?(/\A[0-9a-f]{64}\z/)
        end && header.fetch('child_label_size_callback_count') == (profile == 's1' ? 1 : 0)
      true
    end

    def axes_hash(layout, profile, mark_format, compression, mode)
      {layout: layout, profile: profile, mark_format: mark_format, compression: compression, variant_mode: mode}
    end

    def assert_stock_callback_roster!(id, roster, mark_format, layout)
      expected = schema_for(layout).map(&:first)
      if mark_format == 'mrk3'
        slots = expected.each_with_index.map { |column, index| [index, column, nil] }
        fail!("#{id} MRK3 roster is not one sequential unlabelled slot per root column") unless roster.fetch(:roster) == slots
      else
        sections = roster.fetch(:sections).to_h
        fail!("#{id} MRK4 callback sections differ from root schema order") unless sections.keys == expected
        fail!("#{id} has a root JSON column without physical callbacks") unless sections.values.all? { |streams| !streams.empty? }
      end
      true
    end

    def table_settings!(id, table, store, layout, profile, mark_format, compression, mode)
      tag = marker('table_ddl', id)
      sql = "SELECT '#{tag}', lower(hex(create_table_query)) FROM system.tables " \
        "WHERE database='default' AND name='#{table}' FORMAT TSVRaw;\n"
      result = native(id, store, sql)
      rows = tagged(native_lines(result, "#{id} observed system.tables DDL settings"), tag, 2, id)
      fail!("#{id} table definition is not uniquely observed") unless rows.size == 1
      ddl_hex = rows.first.fetch(1)
      fail!("#{id} table definition is not even-length lower hex") unless ddl_hex.match?(/\A(?:[0-9a-f]{2})+\z/)
      ddl = [ddl_hex].pack('H*').force_encoding(Encoding::UTF_8)
      fail!("#{id} catalog table definition is not valid UTF-8") unless ddl.valid_encoding?
      expected = {
        'object_serialization_version' => 'v3',
        'object_shared_data_serialization_version' => layout,
        'object_shared_data_serialization_version_for_zero_level_parts' => layout,
        'object_shared_data_buckets_for_compact_part' => EFFECTIVE_BUCKETS.fetch(layout.to_sym).to_s,
        'object_shared_data_target_chunk_rows' => '1',
        'string_serialization_version' => profile == 's1' ? 'with_size_stream' : 'single_stream',
        'propagate_types_serialization_versions_to_nested_types' => 'true',
        'write_marks_for_substreams_in_compact_parts' => mark_format == 'mrk4' ? '1' : '0',
        'compress_marks' => compression == 'compressed' ? '1' : '0',
        'use_compact_variant_discriminators_serialization' => mode == 'compact' ? '1' : '0',
      }
      observed = expected.keys.to_h { |name| [name, extract_table_setting!(ddl, name, id)] }
      fail!("#{id} persisted table settings differ from requested cell") unless observed == expected
      {state: 'observed_catalog_create_table_query', settings: observed,
       ddl_sha256: Digest::SHA256.hexdigest(ddl.b), invocation: result.fetch(:record)}
    end

    def rowbinary_var_uint(value)
      fail!('RowBinary VarUInt must be non-negative') unless value.is_a?(Integer) && value >= 0
      bytes = []
      loop do
        byte = value & 0x7f
        value >>= 7
        bytes << (value.zero? ? byte : byte | 0x80)
        break if value.zero?
      end
      bytes.pack('C*').b
    end

    def rowbinary_string(value)
      bytes = value.to_s.b
      rowbinary_var_uint(bytes.bytesize) + bytes
    end

    def rowbinary_dynamic_string(value)
      "\x15".b + rowbinary_string(value)
    end

    def rowbinary_leaf_body(child_id)
      doc = CHILD_DOCS.fetch(child_id)
      fields = [
        ['id', [doc.fetch(:id)].pack('Q<')],
        ['label', rowbinary_string(doc.fetch(:label))],
      ]
      doc.fetch(:shared).each { |path, bytes| fields << [path, rowbinary_dynamic_string(bytes)] }
      rowbinary_var_uint(fields.size) + fields.map { |path, bytes| rowbinary_string(path) + bytes }.join.b
    end

    def rowbinary_array_body(value, levels_remaining)
      if levels_remaining.zero?
        return rowbinary_leaf_body(value)
      end
      rowbinary_var_uint(value.size) + value.map { |child| rowbinary_array_body(child, levels_remaining - 1) }.join.b
    end

    def rowbinary_payload(value, depth)
      descriptor = (ARRAY_BINARY_TYPE * depth) + JSON_LEAF_BINARY_TYPE
      descriptor.b + rowbinary_array_body(value, depth)
    end

    def rowbinary_root_json(column, row_index)
      payload = PAYLOADS.fetch(column).fetch(row_index)
      paths = []
      paths << ['payload', rowbinary_payload(payload, COLUMN_DEPTHS.fetch(column))] unless payload.nil?
      ROOT_SHARED.fetch(column).fetch(row_index).each do |path, bytes|
        paths << [path, rowbinary_dynamic_string(bytes)]
      end
      rowbinary_var_uint(paths.size) + paths.map { |path, bytes| rowbinary_string(path) + bytes }.join.b
    end

    def rowbinary_rows(_layout)
      ROW_COUNT.times.map do |index|
        ([[index + 1].pack('Q<')] + VALUE_COLUMNS.map { |column| rowbinary_root_json(column, index) }).join.b
      end.join.b
    end

    def native_values_sql(table, id, window)
      tag = marker('values', id, window)
      predicate = WINDOWS.fetch(window)
      if window == 'eof'
        return "SELECT '#{tag}', toString(count()) FROM default.#{table} WHERE #{predicate} FORMAT TSVRaw;\n"
      end
      fields = ["'#{tag}'", 'toString(pk)']
      VALUE_COLUMNS.each do |column|
        dynamic = "#{column}.payload"
        type = ACTUAL_TYPES.fetch(column)
        actual = "dynamicElement(#{dynamic}, '#{type}')"
        projected = recursive_leaf_token(actual, COLUMN_DEPTHS.fetch(column))
        fields.concat([
          "if(isNull(#{dynamic}), 'NULL', dynamicType(#{dynamic}))",
          "if(isNull(#{dynamic}), 'NULL', toString(toUInt8(isDynamicElementInSharedData(#{dynamic}))))",
          "if(isNull(#{dynamic}), '-', lower(hex(toJSONString(#{projected}))))",
        ])
      end
      root_paths = VALUE_COLUMNS.map do |column|
        "[arraySort(JSONDynamicPaths(#{column})),arraySort(JSONSharedDataPaths(#{column}))]"
      end
      fields << "lower(hex(toJSONString([#{root_paths.join(',')} ])))"
      SHARED_VALUE_ORDER.each do |path|
        values = VALUE_COLUMNS.map { |column| "lower(hex(#{column}.#{path}))" }
        args = values.each_with_index.flat_map { |value, index| index.zero? ? [value] : ["'|'", value] }
        fields << "concat(#{args.join(',')})"
      end
      where = predicate ? " WHERE #{predicate}" : ''
      "SELECT #{fields.join(', ')} FROM default.#{table}#{where} ORDER BY pk " \
        "SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;\n"
    end

    def recursive_leaf_token(expression, depth, ordinal = 0)
      return leaf_token_sql(expression) if depth.zero?
      variable = "w279_leaf_#{ordinal}"
      "arrayMap(#{variable} -> #{recursive_leaf_token(variable, depth - 1, ordinal + 1)}, #{expression})"
    end

    def leaf_token_sql(expression)
      paths = "lower(hex(toJSONString(arraySort(JSONDynamicPaths(#{expression})))))"
      shared_paths = "lower(hex(toJSONString(arraySort(JSONSharedDataPaths(#{expression})))))"
      shared_values = SHARED_VALUE_ORDER.map { |path| "lower(hex(#{expression}.#{path}))" }
      "concat(toString(#{expression}.id), '|', lower(hex(#{expression}.label)), '|', #{paths}, '|', #{shared_paths}, '|', #{shared_values.join(", '|', ")})"
    end

    def native_values!(id, table, store, _layout)
      sql = %w[full middle eof].map { |window| native_values_sql(table, id, window) }.join
      result = native("#{id}_values", store, sql)
      lines = native_lines(result, "#{id} exact native full/middle/EOF values")
      observations = {}
      %w[full middle eof].each do |window|
        tag = marker('values', id, window)
        if window == 'eof'
          rows = tagged(lines, tag, 2, "#{id}/#{window}")
          fail!("#{id} EOF query differs") unless rows == [[tag, '0']]
          observations[window] = {state: 'exact_values', rows: [], count: 0, raw_rows: rows}
          next
        end
        rows = tagged(lines, tag, 15, "#{id}/#{window}")
        parsed = rows.map { |fields| parse_native_row(fields, id, window) }
        expected = expected_native_rows(window)
        fail!("#{id}/#{window} native values/types/shared flags/path rosters differ: #{parsed.inspect}") unless parsed == expected
        observations[window] = {state: 'exact_values', rows: parsed, raw_rows: rows}
      end
      {state: 'exact_values', windows: observations, invocation: result.fetch(:record)}
    end

    def parse_native_row(fields, id, window)
      fail!("#{id}/#{window} native row width differs") unless fields.size == 15
      columns = {}
      VALUE_COLUMNS.each_with_index do |column, index|
        offset = 2 + index * 3
        type = fields.fetch(offset)
        flag = fields.fetch(offset + 1)
        tree_hex = fields.fetch(offset + 2)
        if type == 'NULL'
          fail!("#{id}/#{window}/#{column} null type must have NULL flag and '-' tree") unless flag == 'NULL' && tree_hex == '-'
          columns[column] = {actual_type: nil, is_shared: nil, tree: nil}
        else
          fail!("#{id}/#{window}/#{column} Dynamic shared flag must be 0") unless flag == '0'
          fail!("#{id}/#{window}/#{column} tree must be even lowercase hex") unless tree_hex.match?(/\A(?:[0-9a-f]{2})+\z/)
          columns[column] = {actual_type: type, is_shared: false,
                             tree: decode_hex_json(tree_hex, "#{id}/#{window}/#{column} tree")}
        end
      end
      path_roster = decode_hex_json(fields.fetch(11), "#{id}/#{window} root path roster")
      shared_values = {}
      SHARED_VALUE_ORDER.each_with_index do |path, index|
        parts = fields.fetch(12 + index).split('|', -1)
        fail!("#{id}/#{window}/root #{path} triplet width differs") unless parts.size == 3 && parts.all? { |part| part.match?(/\A(?:[0-9a-f]{2})*\z/) }
        shared_values[path] = parts
      end
      {pk: Integer(fields.fetch(1), 10), columns: columns, root_path_roster: path_roster,
       root_shared_values: shared_values}
    rescue ArgumentError => error
      fail!("#{id}/#{window} malformed native value row: #{error.message}")
    end

    def decode_hex_json(value, label)
      fail!("#{label} is not even-length lowercase hex JSON") unless value.match?(/\A(?:[0-9a-f]{2})+\z/)
      JSON.parse([value].pack('H*'))
    rescue JSON::ParserError => error
      fail!("#{label} contains malformed JSON: #{error.message}")
    end

    def expected_native_rows(window)
      selected = case window
                 when 'full' then (1..ROW_COUNT).to_a
                 when 'middle' then (3..6).to_a
                 else fail!("unexpected non-empty native window #{window.inspect}")
                 end
      selected.map do |pk|
        index = pk - 1
        columns = VALUE_COLUMNS.to_h do |column|
          payload = PAYLOADS.fetch(column).fetch(index)
          type = ACTUAL_TYPES.fetch(column)
          tree = payload.nil? ? nil : leaf_tokens(payload, COLUMN_DEPTHS.fetch(column))
          [column, {actual_type: payload.nil? ? nil : type, is_shared: payload.nil? ? nil : false, tree: tree}]
        end
        root_shared = SHARED_VALUE_ORDER.to_h do |path|
          [path, VALUE_COLUMNS.map { |column| ROOT_SHARED.fetch(column).fetch(index).fetch(path).unpack1('H*') }]
        end
        root_paths = VALUE_COLUMNS.map { [[], SHARED_PATHS] }
        {pk: pk, columns: columns, root_path_roster: root_paths, root_shared_values: root_shared}
      end
    end

    def leaf_tokens(value, depth)
      return child_token(value) if depth.zero?
      value.map { |child| leaf_tokens(child, depth - 1) }
    end

    def child_token(child_id)
      doc = CHILD_DOCS.fetch(child_id)
      shared = doc.fetch(:shared)
      [doc.fetch(:id), doc.fetch(:label).unpack1('H*'), '5b5d', '5b226161222c22616c706861222c2262657461225d',
       shared.fetch('alpha').unpack1('H*'), shared.fetch('aa').unpack1('H*'), shared.fetch('beta').unpack1('H*')].join('|')
    end

    def assert_profile_roster_deltas!
      MARK_FORMATS.each do |mark_format|
        next unless mark_format == 'mrk4'
        LAYOUTS.each do |layout|
          MARK_COMPRESSION.each do |compression|
            VARIANT_MODES.each do |mode|
              s0 = @stock.fetch(cell_id('stock', layout, 's0', mark_format, compression, mode))
              s1 = @stock.fetch(cell_id('stock', layout, 's1', mark_format, compression, mode))
              fail!('stock String metadata profiles are not independently observed') unless
                s0.dig(:serialization_metadata, :string_version) == 0 && s1.dig(:serialization_metadata, :string_version) == 1
              left = s0.fetch(:callback_roster).fetch(:sections).to_h.transform_values(&:to_set)
              right = s1.fetch(:callback_roster).fetch(:sections).to_h.transform_values(&:to_set)
              VALUE_COLUMNS.each do |column|
                added = right.fetch(column) - left.fetch(column)
                fail!("#{layout}/#{column} has no S1-only String-size callback") unless added.any? { |stream| stream.match?(/\.size\z/) }
                fail!("#{layout}/#{column} S1 adds a non-size callback unexpectedly") unless added.all? { |stream| stream.match?(/\.size\z/) }
              end
            end
          end
        end
      end
      true
    end

    def write_new(path, bytes)
      cap = File.basename(path) == 'summary.md' ? MAX_W279_MARKDOWN_SUMMARY_BYTES : MAX_W279_JSON_SUMMARY_BYTES
      fail!("evidence record #{File.basename(path)} exceeds W279 cap #{cap}") if bytes.bytesize > cap
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes) }
    end

    def build_summary
      all_ids = LAYOUTS.product(PROFILES, MARK_FORMATS, MARK_COMPRESSION, VARIANT_MODES).map { |axes| cell_id('stock', *axes) }
      status = if @full_matrix
                 if @selection_mode == 'full' && @selected_axes.size == 64 && @stock.keys == all_ids &&
                    @generated.keys == all_ids.map { |id| id.sub(/\Astock_/, 'generated_') }
                   'stock_native_and_library_generated_matrix_exact'
                 elsif @selection_mode == 'canonical_prefix'
                   'stock_native_and_library_generated_selected_prefix_exact'
                 else
                   'stock_native_and_library_generated_selected_subset_exact'
                 end
               elsif @selected_axes.size == 64 && @stock.keys == all_ids
                 'stock_native_matrix_exact'
               elsif @selection_mode == 'canonical_prefix'
                 'stock_native_selected_prefix_exact'
               else
                 'stock_native_selected_subset_exact'
               end
      summary = {
        format: FORMAT, status: status,
        execution_order: 'Selected independent stock/native cells: version/build-pinned CREATE, exact RowBinary INSERT argv/stdin, schema/part/callback/metadata/CHECK, one tagged full/middle/EOF native values invocation and observed catalog settings. This stock-only probe never opens the Crystal helper or makes a physical child-header claim.',
        runtime_pin: {binary: @binary, expected_sha256: BINARY_SHA256, sha256_before: @binary_sha_before,
                      sha256_after: @binary_sha_after, version: VERSION, build: BUILD,
                      distinction: 'runtime executable SHA/version/build and upstream source revision are pinned independently'},
        source_pin: {root: @source_root, revision: SOURCE_REVISION, sha256: @upstream_hashes, guards: @source_guard},
        helper_pin: nil,
        probe_sources: @probe_hashes_after,
        fixture: {
          schemas: SCHEMAS, row_count: ROW_COUNT, rows_per_mark: ROWS_PER_MARK, data_marks: DATA_MARK_COUNT,
          stock_native_mark_rows_with_eof: PHYSICAL_MARK_ROWS_WITH_EOF,
          generated_data_mark_rows: WRITER_MARK_ROWS, generated_physical_mark_rows_with_eof: PHYSICAL_MARK_ROWS_WITH_EOF,
          keys: (1..8).to_a, middle_keys: [3, 4, 5, 6], native_literal_rows: literal_summary_rows,
          native_windows: WINDOWS, physical_windows: PHYSICAL_WINDOWS,
          native_type_contract: {root: ROOT_TYPE, actual_payloads: ACTUAL_TYPES, dynamic_shared_flag_expected: false},
          shared_value_contract: {paths: SHARED_PATHS, order: SHARED_VALUE_ORDER, long_bytes: LONG_STRING.bytesize,
                                  binary_hex: BINARY_STRING.unpack1('H*'), nul_hex: SHARED_NUL.unpack1('H*'),
                                  root_columns_populated: VALUE_COLUMNS},
          child_occurrence_counts: VALUE_COLUMNS.to_h do |column|
            payloads = PAYLOADS.fetch(column)
            [column, {non_null_actuals: payloads.count { |item| !item.nil? }, json_leaves: payloads.compact.sum { |item| flatten_ids(item).size }}]
          end,
        },
        matrix: {layouts: LAYOUTS, shared_data_versions: SHARED_VERSIONS, profiles: PROFILES,
                 mark_formats: MARK_FORMATS, mark_compression: MARK_COMPRESSION, variant_modes: VARIANT_MODES,
                 effective_buckets: EFFECTIVE_BUCKETS, object_serialization_version: 'v3', expected_object_wire_version: 4,
                 target_chunk_rows: 1, propagation: true, canonical_cell_count: 64,
                 selection: {mode: @selection_mode, case_limit: @case_limit, selectors: @cell_selectors,
                             selected_cells: @stock.keys + pending_stock_ids},
                 selected_cells: @stock.keys + pending_stock_ids, stock_cells: @stock.keys,
                 generated_cells: @generated.keys},
        stock: @stock, generated: @generated, invocations: @invocations, evidence_root: @root,
        claim_boundary: 'Finite native eight-row/four-data-mark witness for three root JSON columns with identical typed Dynamic declarations and registered Dynamic actuals JSON, Array(Array(JSON)), and Array(Array(Array(JSON))). Stock-native windows, exact types/shared flags, empty/null distinctions, root/leaf JSON paths and values, Compact/CHECK, source/runtime pins, catalog settings and RowBinary evidence are checked. Stock-only has no physical Object child-header claim. Full helper mode must identify the actual child Object stream under each parent-column payload owner and parse its physical header directly; outer settings and requested helper versions are not substitutes. No claim for arbitrary schemas/settings, all array depths, all shared layouts or all recursive codecs.',
      }
      return summary unless @full_matrix

      selection = {
        mode: @selection_mode, case_limit: @case_limit, selectors: @cell_selectors,
        selected_count: @selected_axes.size,
        selected_axes: @selected_axes.map { |axes| axes_hash(*axes) },
        selected_stock_cells: @stock.keys, selected_generated_cells: @generated.keys,
      }
      invocation_roster = @invocations.each_with_index.map do |record, index|
        label = record.fetch(:label)
        {
          sequence: index + 1, label: label, process_kind: record.fetch(:process_kind),
          binary_path: record.fetch(:binary_path), store_path: record.fetch(:store_path), argv: record.fetch(:argv),
          stdin_file: record.fetch(:stdin_file), argv_file: record.fetch(:argv_file),
          stdout_file: record.fetch(:stdout_file), stderr_file: record.fetch(:stderr_file),
          record_file: "#{label}.json",
        }
      end
      summary.merge(
        producer_mode: 'full_matrix',
        execution_order: 'For every selected cell, capture the independent stock-native CREATE, RowBinary insert, schema/part/callback/metadata, CHECK, full/middle/EOF native value windows, and catalog settings first. Then, in selected-cell order, run helper audit plus full (0,4), middle (1,2), and EOF (4,0) reads against each stock part and verify its inventory is unchanged. Only after all stock helper reads, for each selected cell write a library part, capture its exact inventory/callback roster/metadata snapshot, independently create a native target, attach the part, CHECK it, inspect the active catalog/part, and read native full/middle/EOF values; finally audit and read the generated part with the helper. Invocation order and five sidecars are retained per process. The original captured child ObjectStructure callback bytes are reported by parent column, mark, actual and typed-Dynamic leaf key; this is not an independent whole-frame proof.',
        source_pin: {
          root: @source_root, revision: SOURCE_REVISION,
          revision_before: @source_revision_before, revision_after: @source_revision_after,
          sha256: @upstream_hashes, sha256_before: @upstream_hashes, sha256_after: @upstream_hashes_after,
          guards: @source_guard,
        },
        helper_pin: {
          path: @helper, expected_sha256: @helper_expected_sha,
          sha256_before: @helper_sha_before, sha256_after: @helper_sha_after,
        },
        producer_pin: {
          paths: @probe_sources, sha256_before: @probe_hashes_before, sha256_after: @probe_hashes_after,
        },
        selection: selection,
        matrix: summary.fetch(:matrix).merge(
          selection: selection, selected_axes: selection.fetch(:selected_axes),
          selected_stock_cells: @stock.keys, selected_generated_cells: @generated.keys,
        ),
        invocation_roster: invocation_roster,
        claim_boundary: 'Finite selected-cell witness for three typed-Dynamic JSON parent columns whose actuals are JSON, Array(Array(JSON)), and Array(Array(Array(JSON))). Each cell has independent native stock controls and helper audit/full/middle/EOF reads, then a library-generated part with file inventory and exact snapshot followed by native ATTACH/CHECK/catalog/full/middle/EOF validation and helper audit/reads. The helper binds the actual child ObjectStructure callback bytes to each parent column, mark, actual count, and typed-Dynamic leaf key; parent and child headers must show matching wire version 4, shared layout/version, bucket count, profile and S0/S1 label callbacks. This proves only these selected finite fixtures and admitted cells, not an independent whole-frame parse proof, arbitrary schemas/settings, arbitrary Array depth, or all recursive codecs.',
      )
    end

    def pending_stock_ids
      @selected_axes.map { |axes| cell_id('stock', *axes) }.reject { |id| @stock.key?(id) }
    end

    def literal_summary_rows
      ROW_COUNT.times.map do |index|
        {pk: index + 1,
         columns: VALUE_COLUMNS.to_h do |column|
           payload = PAYLOADS.fetch(column).fetch(index)
           [column, {payload_child_ids: payload, root_shared_values: ROOT_SHARED.fetch(column).fetch(index).transform_values { |bytes| bytes.unpack1('H*') }}]
         end}
      end
    end

    def render_summary(summary)
      lines = [
        '# W279 Compact typed-Dynamic JSON-child native matrix', '',
        "Status: `#{summary.fetch(:status)}`",
        "Runtime: `#{VERSION}` build `#{BUILD}` SHA-256 `#{BINARY_SHA256}`.",
        "Source: `#{SOURCE_REVISION}` at `#{SOURCE_ROOT}` (independent pin).",
        'Every selected native part has eight rows, four two-row data marks, and a fifth zero-row EOF mark. RowBinary input is encoded independently in Ruby; each insert query and exact `.stdin.bin` payload are captured.',
      ]
      @stock.each do |id, entry|
        helper_suffix = if @full_matrix
                          '; helper stock audit plus full/middle/EOF reads exact'
                        else
                          ''
                        end
        lines << "- #{id}: Compact/CHECK healthy; #{entry.fetch(:shared_layout)}, String#{entry.fetch(:profile) == 's1' ? 1 : 0}, #{entry.fetch(:mark_format)}, #{entry.fetch(:compression)}, #{entry.fetch(:variant_mode)}; native full/middle/EOF exact#{helper_suffix}."
      end
      if @full_matrix
        @generated.each do |id, entry|
          lines << "- #{id}: library write inventory/snapshot exact; native ATTACH/CHECK/catalog/full/middle/EOF and helper audit/full/middle/EOF exact."
        end
      end
      lines.concat(['', summary.fetch(:claim_boundary), ''])
      lines.join("\n")
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  options = {
    binary: ProbeCompactChildJsonWriterW279::BINARY,
    source_root: ProbeCompactChildJsonWriterW279::SOURCE_ROOT,
    evidence_root: nil, stock_only: false, full_matrix: false, helper: nil, helper_sha256: nil,
    case_limit: nil, cell: [],
  }
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/probe_compact_child_json_writer_w279.rb (--stock-only | --full-matrix --helper PREBUILT --helper-sha256 SHA256) --evidence-root EMPTY_DIR [--case-limit N | --cell LAYOUT:PROFILE:MARK:COMPRESSION:MODE ...] [--binary PINNED_CLICKHOUSE] [--source-root PINNED_UPSTREAM]'
    parser.on('--stock-only', 'Run selected independent stock/native cells only; never starts the Crystal helper') { options[:stock_only] = true }
    parser.on('--full-matrix', 'Run selected stock controls, helper reads, and library-generated/native ATTACH/CHECK/read cells') { options[:full_matrix] = true }
    parser.on('--helper PATH', 'Prebuilt W279 Crystal helper; full-matrix only') { |value| options[:helper] = value }
    parser.on('--helper-sha256 SHA256', 'Exact lowercase SHA-256 for the prebuilt helper') { |value| options[:helper_sha256] = value }
    parser.on('--case-limit N', Integer, 'Select the first N cells in canonical matrix order (1..64)') { |value| options[:case_limit] = value }
    parser.on('--cell SELECTOR', 'Select exact layout:profile:mark:compression:mode cell; repeatable') { |value| options[:cell] << value }
    parser.on('--evidence-root EMPTY_DIR', 'Existing empty direct child of /private/tmp') { |value| options[:evidence_root] = value }
    parser.on('--binary PATH', 'Pinned ClickHouse runtime executable, distinct from source checkout') { |value| options[:binary] = value }
    parser.on('--source-root PATH', 'Separately pinned upstream ClickHouse source checkout') { |value| options[:source_root] = value }
  end.parse!

  unless options[:stock_only] != options[:full_matrix] && options[:evidence_root]
    warn 'W279: select exactly one of --stock-only or --full-matrix and provide --evidence-root'
    exit 2
  end
  if options[:stock_only] && (options[:helper] || options[:helper_sha256])
    warn 'W279: --helper and --helper-sha256 are valid only with --full-matrix'
    exit 2
  end
  if options[:full_matrix] && (!options[:helper] || !options[:helper_sha256])
    warn 'W279: --full-matrix requires --helper and --helper-sha256'
    exit 2
  end
  probe = ProbeCompactChildJsonWriterW279::Probe.new(**options)
  exit(probe.run ? 0 : 1)
end
