#!/usr/bin/env ruby
# Stock-first native witness for Compact JSON writers using ADVANCED and
# ADVANCED_CHUNKED Object shared data. RowBinary literals and SQL expectations
# are independent of the Crystal fixture and helper.

require 'digest'
require 'json'
require 'open3'
require 'optparse'
require 'set'
require_relative 'probe_compact_context_string_writer_w277'

module ProbeCompactAdvancedJsonWriterW278
  W277 = ProbeCompactContextStringWriterW277
  W276 = W277::W276
  W271 = W277::W271
  W241 = W277::W241

  FORMAT = 'compact_advanced_json_writer_w278_native_probe_v1'.freeze
  HELPER_FORMAT = 'compact_advanced_json_writer_w278_helper_v1'.freeze
  PART_NAME = W277::PART_NAME
  BINARY = W277::BINARY
  BINARY_SHA256 = W277::BINARY_SHA256
  VERSION = W277::VERSION
  BUILD = W277::BUILD
  SOURCE_ROOT = W277::SOURCE_ROOT
  SOURCE_REVISION = W277::SOURCE_REVISION
  SOURCE_FILES = (W277::SOURCE_FILES + %w[
    src/Storages/MergeTree/MergeTreeSettings.cpp
    src/Storages/MergeTree/MergeTreeIOSettings.cpp
    src/Storages/MergeTree/MergeTreeDataPartWriterCompact.cpp
  ]).uniq.freeze

  HELPER_SOURCE = File.expand_path('compact_advanced_json_writer_w278_helper.cr', __dir__).freeze
  PROBE_SOURCE = File.expand_path(__FILE__).freeze
  FIXTURE_SOURCE = File.expand_path('../spec/support/compact_part_writer_w278_fixture.cr', __dir__).freeze
  W277_SOURCE = W277::PROBE_SOURCE
  W276_SOURCE = W276::PROBE_SOURCE
  W241_SOURCE = W276::W241_SOURCE
  W271_SOURCE = W276::W271_SOURCE
  W273_SOURCE = W276::W273_SOURCE
  W264_SOURCE = W276::W264_SOURCE

  ROWS_PER_MARK = 2
  ROW_COUNT = 8
  DATA_MARK_COUNT = 4
  PHYSICAL_MARK_ROWS_WITH_EOF = [2, 2, 2, 2, 0].freeze
  WRITER_MARK_ROWS = [2, 2, 2, 2].freeze
  MAX_W278_JSON_SUMMARY_BYTES = 32 * 1024 * 1024
  MAX_W278_MARKDOWN_SUMMARY_BYTES = 1024 * 1024
  MAX_RAW_FILE_BYTES = W277::MAX_RAW_FILE_BYTES
  MAX_PART_FILES = W277::MAX_PART_FILES
  MAX_PART_BYTES = W277::MAX_PART_BYTES

  SHARED_VERSIONS = %w[advanced advanced_chunked].freeze
  PROFILES = %w[s0 s1].freeze
  MARK_FORMATS = %w[mrk3 mrk4].freeze
  MARK_COMPRESSION = %w[plain compressed].freeze
  VARIANT_MODES = %w[basic compact].freeze
  WINDOWS = W277::WINDOWS
  PHYSICAL_WINDOWS = W277::PHYSICAL_WINDOWS

  JSON_TYPE = 'JSON(max_dynamic_types=1,max_dynamic_paths=1,id UInt64,label String)'.freeze
  SCHEMA = [
    ['pk', 'UInt64'],
    ['root_json', JSON_TYPE],
    ['array_json', "Array(#{JSON_TYPE})"],
    ['tagged_json', "Array(Tuple(#{JSON_TYPE},UInt8))"],
    ['pair_json', "Tuple(#{JSON_TYPE},#{JSON_TYPE})"],
  ].map(&:freeze).freeze
  SCHEMAS = SHARED_VERSIONS.to_h { |version| [version, SCHEMA] }.freeze
  VALUE_COLUMNS = %w[root_json array_json tagged_json pair_json].freeze
  TYPE_NAMES = VALUE_COLUMNS.to_h do |name|
    [name, SCHEMA.find { |column, _| column == name }.fetch(1)]
  end.freeze

  LONG_STRING = ('long:' + ('x' * 256)).b.freeze
  BINARY_STRING = ['00ff8041'].pack('H*').b.freeze
  SHARED_NUL = "shared\0nul".b.freeze
  SHARED_PATHS = %w[aa alpha beta].freeze
  SHARED_VALUE_ORDER = %w[alpha aa beta].freeze

  literal_doc = lambda do |id, label, payload, shared_index|
    shared = {
      'alpha' => shared_index == 0 ? ''.b : (shared_index == 3 ? LONG_STRING : "alpha-shared-#{shared_index}".b),
      'aa' => shared_index == 1 ? BINARY_STRING : "aa-shared-#{shared_index}".b,
      'beta' => shared_index == 5 ? SHARED_NUL : "beta-shared-#{shared_index}".b,
    }
    {kind: :json, id: id, label: label.to_s.b, payload: payload&.to_s&.b, shared: shared}.freeze
  end

  # The native oracle is fixed here, not imported from the Crystal fixture.
  # Documents contain four candidate String paths. The native Dynamic versus
  # shared-data classification is observed from ClickHouse, not predicted from
  # the schema because max_dynamic_paths=1 leaves selection to statistics.
  # A missing payload is absent, not an empty String.
  ROOT_ROWS = [
    literal_doc.call(1, 'root-0', ''.b, 0),
    literal_doc.call(2, 'root-1', nil, 1),
    literal_doc.call(3, 'root-2', 'root-2'.b, 2),
    literal_doc.call(4, 'root-3', LONG_STRING, 3),
    literal_doc.call(5, 'root-4', BINARY_STRING, 4),
    literal_doc.call(6, 'root-5', "nul\0tail".b, 5),
    literal_doc.call(7, 'root-6', 'root-6'.b, 6),
    literal_doc.call(8, 'root-7', 'root-7'.b, 7),
  ].freeze
  ARRAY_ROWS = [
    [literal_doc.call(101, 'array-0a', 'array-first'.b, 0), literal_doc.call(102, 'array-0b', ''.b, 1)],
    [], [], [],
    [literal_doc.call(105, 'array-4', BINARY_STRING, 4)],
    [literal_doc.call(106, 'array-5a', LONG_STRING, 5), literal_doc.call(107, 'array-5b', "array\0tail".b, 6)],
    [],
    [literal_doc.call(108, 'array-7a', 'last-a'.b, 7), literal_doc.call(109, 'array-7b', 'last-b'.b, 0)],
  ].map(&:freeze).freeze
  TAGGED_ROWS = [
    [[literal_doc.call(201, 'tag-0a', 'tag-first'.b, 0), 1], [literal_doc.call(202, 'tag-0b', ''.b, 1), 2]],
    [], [], [],
    [[literal_doc.call(205, 'tag-4', BINARY_STRING, 4), 5]],
    [[literal_doc.call(206, 'tag-5a', LONG_STRING, 5), 6], [literal_doc.call(207, 'tag-5b', "tag\0tail".b, 6), 7]],
    [],
    [[literal_doc.call(208, 'tag-7a', 'last-a'.b, 7), 8], [literal_doc.call(209, 'tag-7b', 'last-b'.b, 0), 9]],
  ].map(&:freeze).freeze
  PAIR_ROWS = [
    [literal_doc.call(301, 'left-0', 'left-first'.b, 0), literal_doc.call(401, 'right-0', nil, 1)],
    [literal_doc.call(302, 'left-1', nil, 2), literal_doc.call(402, 'right-1', nil, 3)],
    [literal_doc.call(303, 'left-2', 'left-middle'.b, 4), literal_doc.call(403, 'right-2', 'right-middle'.b, 5)],
    [literal_doc.call(304, 'left-3', nil, 6), literal_doc.call(404, 'right-3', nil, 7)],
    [literal_doc.call(305, 'left-4', LONG_STRING, 0), literal_doc.call(405, 'right-4', nil, 1)],
    [literal_doc.call(306, 'left-5', nil, 2), literal_doc.call(406, 'right-5', BINARY_STRING, 3)],
    [literal_doc.call(307, 'left-6', "left\0tail".b, 4), literal_doc.call(407, 'right-6', nil, 5)],
    [literal_doc.call(308, 'left-7', nil, 6), literal_doc.call(408, 'right-7', 'right-last'.b, 7)],
  ].map(&:freeze).freeze

  class Failure < StandardError; end
  TupleValue = Struct.new(:values)

  class Probe < W277::Probe
    def run
      prepare!
      SHARED_VERSIONS.each do |shared_version|
        PROFILES.each do |profile|
          MARK_FORMATS.each do |mark_format|
            MARK_COMPRESSION.each do |compression|
              VARIANT_MODES.each do |mode|
                id = cell_id('stock', shared_version, profile, mark_format, compression, mode)
                @stock[id] = capture_stock!(id, shared_version, profile, mark_format, compression, mode)
              end
            end
          end
        end
      end
      assert_profile_roster_deltas!
      unless @stock_only
        @stock.each { |id, entry| capture_stock_local_reads!(id, entry) }
        SHARED_VERSIONS.each do |shared_version|
          PROFILES.each do |profile|
            MARK_FORMATS.each do |mark_format|
              MARK_COMPRESSION.each do |compression|
                VARIANT_MODES.each do |mode|
                  id = cell_id('generated', shared_version, profile, mark_format, compression, mode)
                  @generated[id] = capture_generated!(id, shared_version, profile, mark_format, compression, mode)
                end
              end
            end
          end
        end
      end
      validate_process_evidence!
      validate_pins!
      summary = build_summary
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      write_new(File.join(@root, 'summary.md'), render_summary(summary))
      puts "W278 status=#{summary.fetch(:status)}; stock=#{@stock.size}; generated=#{@generated.size}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      persist_inconclusive(error)
      warn "W278 probe inconclusive: #{@fatal_error}"
      false
    end

    private

    def fail!(message)
      raise Failure, "W278: #{message}"
    end

    def write_new(path, bytes)
      cap = case File.basename(path)
            when 'summary.json' then MAX_W278_JSON_SUMMARY_BYTES
            when 'summary.md' then MAX_W278_MARKDOWN_SUMMARY_BYTES
            else return super
            end
      fail!("evidence record #{File.basename(path)} is #{bytes.bytesize} bytes; W278 cap is #{cap} bytes") if bytes.bytesize > cap
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes) }
    end

    def validate_literals!
      fail!('native literal corpus must have eight rows and four two-row marks') unless
        ROOT_ROWS.size == ROW_COUNT && ARRAY_ROWS.size == ROW_COUNT && TAGGED_ROWS.size == ROW_COUNT &&
        PAIR_ROWS.size == ROW_COUNT && ROOT_ROWS.map { |row| row.fetch(:id) } == (1..8).to_a
      fail!('native literal child grid differs from the frozen W278 contract') unless
        ARRAY_ROWS.values_at(1, 2, 3, 6).all?(&:empty?) &&
        TAGGED_ROWS.values_at(1, 2, 3, 6).all?(&:empty?) &&
        ARRAY_ROWS[0].size == 2 && TAGGED_ROWS[0].size == 2 &&
        PAIR_ROWS.all? { |row| row.size == 2 }
      fail!('matrix is not the exact 32-cell W278 cross-product') unless
        SHARED_VERSIONS.size * PROFILES.size * MARK_FORMATS.size * MARK_COMPRESSION.size * VARIANT_MODES.size == 32
      true
    end

    def prepare!
      %w[invocations stores source-inventories raw-records parts].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      @binary_sha_before = sha(@binary)
      fail!('ClickHouse executable differs from pinned runtime SHA-256') unless @binary_sha_before == BINARY_SHA256
      revision, stderr, status = Open3.capture3('git', '-C', @source_root, 'rev-parse', 'HEAD')
      fail!("pinned upstream source revision check failed: #{stderr.strip}") unless status.success? && revision.strip == SOURCE_REVISION
      @upstream_hashes = SOURCE_FILES.to_h do |relative|
        path = File.join(@source_root, relative)
        fail!("pinned upstream source is missing or symlinked: #{relative}") unless File.file?(path) && !File.symlink?(path)
        [relative, sha(path)]
      end
      @source_guard = source_guard!
      @probe_sources = [PROBE_SOURCE, HELPER_SOURCE, FIXTURE_SOURCE, W277_SOURCE, W276_SOURCE, W241_SOURCE,
                        W271_SOURCE, W273_SOURCE, W264_SOURCE].map { |path| File.realpath(path) }.uniq.sort
      @probe_hashes_before = @probe_sources.to_h { |path| [path, sha(path)] }
      @profiles_by_id = {}
      if @full_matrix
        @helper_sha_before = sha(@helper)
        fail!('prebuilt W278 helper SHA differs from CLI pin') unless @helper_sha_before == @helper_expected_sha
      end
    end

    def source_guard!
      facts = super
      shared_data = File.binread(File.join(@source_root, 'src/DataTypes/Serializations/SerializationObjectSharedData.cpp')).force_encoding(Encoding::UTF_8)
      settings = File.binread(File.join(@source_root, 'src/Storages/MergeTree/MergeTreeSettings.cpp')).force_encoding(Encoding::UTF_8)
      compact_writer = File.binread(File.join(@source_root, 'src/Storages/MergeTree/MergeTreeDataPartWriterCompact.cpp')).force_encoding(Encoding::UTF_8)
      facts[:advanced_and_chunked_wire_branches_pinned] =
        shared_data.include?('MergeTreeObjectSharedDataSerializationVersion::ADVANCED') &&
        shared_data.include?('MergeTreeObjectSharedDataSerializationVersion::ADVANCED_CHUNKED') &&
        shared_data.include?('serialization_version.value == SerializationVersion::ADVANCED') &&
        shared_data.include?('serialization_version.value == SerializationVersion::ADVANCED_CHUNKED') &&
        shared_data.include?('size_t target_chunk_rows = settings.object_shared_data_target_chunk_rows')
      facts[:small_shared_chunk_target_pinned] = settings.include?('object_shared_data_target_chunk_rows') &&
        settings.include?('NonZeroUInt64, object_shared_data_target_chunk_rows') &&
        compact_writer.include?('serialize_settings.object_shared_data_target_chunk_rows = settings.object_shared_data_target_chunk_rows')
      fail!('pinned upstream source lacks ADVANCED/ADVANCED_CHUNKED chunk dispatch or Compact setting propagation') unless
        facts[:advanced_and_chunked_wire_branches_pinned] && facts[:small_shared_chunk_target_pinned]
      facts
    end

    def validate_pins!
      @binary_sha_after = sha(@binary)
      @probe_hashes_after = @probe_sources.to_h { |path| [path, sha(path)] }
      fail!('ClickHouse runtime changed during capture') unless @binary_sha_after == BINARY_SHA256
      fail!('W278 probe, helper, fixture, or inherited probe source changed during capture') unless @probe_hashes_after == @probe_hashes_before
      if @full_matrix
        @helper_sha_after = sha(@helper)
        fail!('prebuilt W278 helper changed during capture') unless @helper_sha_after == @helper_sha_before
      end
    end

    def cell_id(prefix, *parts)
      if parts.size == 5
        [prefix, *parts].join('_')
      elsif parts.size == 4
        [prefix, parts[0], @active_profile || fail!('profile missing for inherited W277 cell lookup'), *parts.drop(1)].join('_')
      else
        fail!("invalid cell id dimensions #{parts.inspect}")
      end
    end

    def marker(kind, id, window = nil)
      suffix = window ? "_#{window.upcase}" : ''
      "__W278_#{kind.to_s.upcase}_#{id.upcase}#{suffix}__"
    end

    def table_name(id)
      "w278_#{@token}_#{id}"
    end

    def schema_for(shared_version)
      SCHEMAS.fetch(shared_version) { fail!("unknown Object shared-data version #{shared_version.inspect}") }
    end

    def settings(shared_version, mark_format, compression, mode)
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
        "object_serialization_version='v3'", "object_shared_data_serialization_version='#{shared_version}'",
        "object_shared_data_serialization_version_for_zero_level_parts='#{shared_version}'",
        'object_shared_data_buckets_for_compact_part=2', 'object_shared_data_target_chunk_rows=1',
        "dynamic_serialization_version='v3'", "use_compact_variant_discriminators_serialization=#{discriminator}",
        'allow_suspicious_low_cardinality_types=1',
      ].join(', ')
    end

    def create_sql(table, shared_version, mark_format, compression, mode)
      declarations = schema_for(shared_version).map { |name, type| "`#{name}` #{type}" }.join(', ')
      "SET flatten_nested=0;\nSET allow_suspicious_low_cardinality_types=1;\nSET use_variant_as_common_type=1;\n" \
        "CREATE TABLE default.#{table} (#{declarations}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings(shared_version, mark_format, compression, mode)};\n"
    end

    def rowbinary_var_uint(value)
      fail!('RowBinary VarUInt value must be a non-negative integer') unless value.is_a?(Integer) && value >= 0
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

    def rowbinary_dynamic(value)
      return "\x00".b if value.nil?
      fail!('W278 Dynamic RowBinary payload must be a String') unless value.is_a?(String)
      "\x15".b + rowbinary_string(value)
    end

    def rowbinary_object(document)
      fields = [
        ['id', [document.fetch(:id)].pack('Q<')],
        ['label', rowbinary_string(document.fetch(:label))],
      ]
      payload = document.fetch(:payload)
      fields << ['payload', rowbinary_dynamic(payload)] unless payload.nil?
      document.fetch(:shared).each { |path, value| fields << [path, rowbinary_dynamic(value)] }
      rowbinary_var_uint(fields.size) + fields.map { |path, bytes| rowbinary_string(path) + bytes }.join.b
    end

    def rowbinary_rows(_shared_version)
      ROW_COUNT.times.map do |index|
        values = [
          [index + 1].pack('Q<'),
          rowbinary_object(ROOT_ROWS.fetch(index)),
          rowbinary_var_uint(ARRAY_ROWS.fetch(index).size) + ARRAY_ROWS.fetch(index).map { |document| rowbinary_object(document) }.join.b,
          rowbinary_var_uint(TAGGED_ROWS.fetch(index).size) + TAGGED_ROWS.fetch(index).map { |document, tag| rowbinary_object(document) + [tag].pack('C') }.join.b,
          PAIR_ROWS.fetch(index).map { |document| rowbinary_object(document) }.join.b,
        ]
        values.join.b
      end.join.b
    end

    def capture_stock!(id, shared_version, profile, mark_format, compression, mode)
      @active_profile = profile
      @profiles_by_id[id] = profile
      stock = super(id, shared_version, mark_format, compression, mode)
      stock.merge(
        profile: profile,
        native_table_settings: table_settings!("#{id}_catalog_settings", stock.fetch(:table), stock.fetch(:store),
                                                shared_version, profile, mark_format, compression, mode),
      )
    end

    def capture_stock_local_reads!(id, stock)
      shared_version = stock.fetch(:shared_layout)
      profile = stock.fetch(:profile)
      part = stock.fetch(:path)
      audit = helper("#{id}_helper_audit", 'audit', part, shared_version, profile)
      validate_helper_report!(audit, id, 'audit', 0, DATA_MARK_COUNT, stock)
      middle = helper("#{id}_helper_middle", 'read', part, shared_version, profile, 'all', '1', '2')
      validate_helper_report!(middle, id, 'read', 1, 2, stock)
      eof = helper("#{id}_helper_eof", 'read', part, shared_version, profile, 'all', '4', '0')
      validate_helper_report!(eof, id, 'read', 4, 0, stock)
      stock[:local_reader] = {audit: audit, middle: middle, eof: eof,
                              claim: 'Crystal typed recursive JSON reads match the independent Ruby literals and captured stock inventory'}
      stock
    end

    def validate_helper_report!(report, id, action, first_mark, mark_count, stock, candidate_mark: nil)
      fail!("#{id} helper report format/action/status differs") unless
        report.fetch('format') == HELPER_FORMAT && report.fetch('action') == action && report.fetch('status') == 'ok'
      shared_version = stock.fetch(:shared_layout)
      profile = stock.fetch(:profile) || @active_profile
      fail!("#{id} helper shared-version/profile/window differs") unless
        report.fetch('shared_version') == shared_version && report.fetch('profile') == profile &&
        report.fetch('first_mark') == first_mark && report.fetch('selected_mark_count') == mark_count
      fail!("#{id} helper row/mark metadata differs") unless report.fetch('row_count') == ROW_COUNT &&
        report.fetch('data_mark_count') == DATA_MARK_COUNT && report.fetch('mark_row_counts') == WRITER_MARK_ROWS
      expected_string_version = profile == 's1' ? 1 : 0
      metadata = report.fetch('serialization_metadata')
      observed_metadata = stock[:serialization_metadata]
      fail!("#{id} helper metadata does not preserve String profile propagation") unless
        metadata.fetch('version') == 1 && metadata.fetch('string_version') == expected_string_version &&
        metadata.fetch('propagate_types_serialization_versions_to_nested_types') == true &&
        (!observed_metadata ||
         (metadata.fetch('version') == observed_metadata.fetch(:version) &&
          metadata.fetch('string_version') == observed_metadata.fetch(:string_version) &&
          metadata.fetch('propagate_types_serialization_versions_to_nested_types') ==
            observed_metadata.fetch(:propagate_types_serialization_versions_to_nested_types)))
      first_row = first_mark * ROWS_PER_MARK
      finish_row = (first_mark + mark_count) * ROWS_PER_MARK
      selected_keys = (first_row...finish_row).map { |index| index + 1 }
      fail!("#{id} helper key values differ") unless report.fetch('keys') == selected_keys
      columns = report.fetch('columns')
      fail!("#{id} helper column roster differs") unless columns.map { |column| column.fetch('name') } == VALUE_COLUMNS
      expected_signatures = literal_signatures
      columns.each do |column|
        name = column.fetch('name')
        fail!("#{id}/#{name} helper type differs") unless normalize_type(column.fetch('type')) == normalize_type(TYPE_NAMES.fetch(name))
        fail!("#{id}/#{name} helper profile differs") unless column.fetch('profile') == (profile == 's1' ? 'with_size_stream' : 'single_stream')
        expected = expected_signatures.fetch(name).drop(first_mark * ROWS_PER_MARK).take(mark_count * ROWS_PER_MARK)
        fail!("#{id}/#{name} helper signatures differ from independent literal oracle") unless column.fetch('signatures') == expected
        fail!("#{id}/#{name} helper physical mark grid differs") unless column.fetch('mark_row_counts') == WRITER_MARK_ROWS
      end
      roster = normalize_helper_roster(report.fetch('physical_roster'))
      expected_roster = stock.fetch(:callback_roster).fetch(:roster)
      fail!("#{id} helper callback roster differs from the independently captured part roster") unless roster == expected_roster
      if action == 'audit' && candidate_mark.nil?
        observed = report.fetch('files').map { |file| [file.fetch('path'), file.fetch('size'), file.fetch('sha256')] }.sort
        expected = stock.fetch(:part_inventory).fetch(:files).map { |file| [file.fetch(:path), file.fetch(:size), file.fetch(:sha256)] }.sort
        fail!("#{id} helper inventory differs from captured stock part") unless observed == expected
      end
      report
    end

    def normalize_helper_roster(roster)
      fail!('helper callback roster is malformed') unless roster.is_a?(Array)
      roster.each_with_index.map do |slot, index|
        fail!('helper callback roster indices are not globally contiguous') unless slot.fetch('index') == index
        [index, slot.fetch('column'), slot['stream']]
      end
    end

    def capture_generated!(id, shared_version, profile, mark_format, compression, mode)
      @active_profile = profile
      @profiles_by_id[id] = profile
      part = File.join(@root, 'parts', id, PART_NAME)
      Dir.mkdir(File.dirname(part), 0o700)
      write = helper("#{id}_writer", 'write', part, shared_version, mark_format, compression, mode, profile)
      fail!("#{id} helper writer request differs") unless write.fetch('format') == HELPER_FORMAT &&
        write.fetch('action') == 'write' && write.fetch('status') == 'ok' && write.fetch('part_path') == part &&
        write.fetch('shared_version') == shared_version && write.fetch('profile') == profile &&
        write.fetch('requested_mark_format') == mark_format && write.fetch('mark_format') == mark_format &&
        write.fetch('requested_compression') == compression && write.fetch('requested_mode') == mode
      inventory = tree_inventory(part)
      helper_files = write.fetch('files').map { |file| [file.fetch('path'), file.fetch('size'), file.fetch('sha256')] }.sort
      fail!("#{id} helper writer inventory differs") unless helper_files == inventory.fetch(:files).map { |file| [file.fetch(:path), file.fetch(:size), file.fetch(:sha256)] }.sort
      candidate_roster = native_callback_roster!("#{id}_generated", part, mark_format, shared_version)
      assert_stock_callback_roster!("#{id}_generated", candidate_roster, mark_format, shared_version)
      candidate_metadata = serialization_metadata!(id, part)
      snapshot = save_part_snapshot!(id, part, inventory, candidate_roster, candidate_metadata)
      validate_helper_report!(write, id, 'write', 0, DATA_MARK_COUNT,
                              {shared_layout: shared_version, profile: profile, callback_roster: candidate_roster,
                               serialization_metadata: candidate_metadata},
                              candidate_mark: mark_format)
      middle = helper("#{id}_helper_middle", 'read', part, shared_version, profile, 'all', '1', '2')
      validate_helper_report!(middle, id, 'read', 1, 2,
                              {shared_layout: shared_version, profile: profile, callback_roster: candidate_roster,
                               serialization_metadata: candidate_metadata},
                              candidate_mark: mark_format)
      eof = helper("#{id}_helper_eof", 'read', part, shared_version, profile, 'all', '4', '0')
      validate_helper_report!(eof, id, 'read', 4, 0,
                              {shared_layout: shared_version, profile: profile, callback_roster: candidate_roster,
                               serialization_metadata: candidate_metadata},
                              candidate_mark: mark_format)
      target = create_target!(id, shared_version, mark_format, compression, mode)
      attached = attach_candidate!(id, part, inventory, target)
      check = check!("#{id}_attached", target.fetch(:table), target.fetch(:store))
      active = inspect_attached_part!(id, target.fetch(:table), target.fetch(:store), shared_version,
                                      mark_format, compression, mode, inventory, candidate_roster)
      native_values = native_values!("#{id}_attached", target.fetch(:table), target.fetch(:store), shared_version)
      fail!("#{id} attached native full/middle/EOF values differ") unless native_values.fetch(:state) == 'exact_values'
      fail!("#{id} source candidate changed during ATTACH/CHECK/read") unless tree_inventory(part) == inventory
      {
        origin: 'Crystal-generated Compact JSON part; local full/middle/EOF reads; pre-ATTACH inventory; native ATTACH/CHECK/exact full-middle-EOF values',
        part_path: part, shared_layout: shared_version, profile: profile, mark_format: mark_format,
        compression: compression, variant_mode: mode, helper_write: write, helper_middle: middle, helper_eof: eof,
        candidate_callback_roster: candidate_roster, candidate_metadata: candidate_metadata,
        part_inventory: inventory, evidence_snapshot: snapshot, native_target: target, attach: attached,
        native_check: check, active_part: active, native_values: native_values,
      }
    end

    def settings_for_current_profile(shared_version, mark_format, compression, mode)
      settings(shared_version, mark_format, compression, mode)
    end

    def serialization_metadata!(id, part)
      path = File.join(part, 'serialization.json')
      fail!("#{id} serialization metadata missing, symlinked, or oversized") unless
        File.file?(path) && !File.symlink?(path) && File.size(path) <= MAX_RAW_FILE_BYTES
      raw = File.binread(path)
      metadata = JSON.parse(raw)
      versions = metadata.fetch('types_serialization_versions')
      profile = @profiles_by_id[id] || @active_profile || fail!("#{id} String profile is unavailable for metadata validation")
      expected = profile == 's1' ? 1 : 0
      fail!("#{id} serialization metadata does not match propagated String#{expected}") unless
        metadata.fetch('version') == 1 && versions.fetch('string') == expected &&
        metadata.fetch('propagate_types_serialization_versions_to_nested_types') == true
      {
        raw: raw, raw_sha256: Digest::SHA256.hexdigest(raw), version: metadata.fetch('version'),
        types_serialization_versions: versions, string_version: versions.fetch('string'),
        propagate_types_serialization_versions_to_nested_types: true,
        serializer_records: metadata.fetch('columns'),
      }
    rescue JSON::ParserError, KeyError => error
      fail!("#{id} serialization.json is malformed: #{error.message}")
    end

    def table_settings!(id, table, store, shared_version, profile, mark_format, compression, mode)
      tag = marker('table_ddl', id)
      sql = "SELECT '#{tag}', lower(hex(create_table_query)) FROM system.tables " \
        "WHERE database='default' AND name='#{table}' FORMAT TSVRaw;\n"
      result = native(id, store, sql)
      lines = native_lines(result, "#{id} observed system.tables DDL settings")
      rows = tagged(lines, tag, 2, id)
      fail!("#{id} table definition is not uniquely observed") unless rows.size == 1
      ddl_hex = rows.first.fetch(1)
      fail!("#{id} table definition is not even-length lower hex") unless ddl_hex.match?(/\A(?:[0-9a-f]{2})+\z/)
      ddl = [ddl_hex].pack('H*').force_encoding(Encoding::UTF_8)
      fail!("#{id} catalog table definition is not valid UTF-8") unless ddl.valid_encoding?
      expected = {
        'object_serialization_version' => 'v3',
        'object_shared_data_serialization_version' => shared_version,
        'object_shared_data_serialization_version_for_zero_level_parts' => shared_version,
        'object_shared_data_buckets_for_compact_part' => '2',
        'object_shared_data_target_chunk_rows' => '1',
        'string_serialization_version' => profile == 's1' ? 'with_size_stream' : 'single_stream',
        'propagate_types_serialization_versions_to_nested_types' => 'true',
        'write_marks_for_substreams_in_compact_parts' => mark_format == 'mrk4' ? '1' : '0',
        'compress_marks' => compression == 'compressed' ? '1' : '0',
        'use_compact_variant_discriminators_serialization' => mode == 'compact' ? '1' : '0',
      }
      observed = expected.keys.to_h { |name| [name, extract_table_setting!(ddl, name, id)] }
      fail!("#{id} persisted table settings differ from the requested native cell") unless observed == expected
      {state: 'observed_catalog_create_table_query', settings: observed,
       ddl_sha256: Digest::SHA256.hexdigest(ddl.b), invocation: result.fetch(:record)}
    end

    def extract_table_setting!(ddl, name, id)
      normalized = ddl.downcase.gsub(/\s+/, '').delete('`')
      match = normalized.match(/(?:settings|,)#{Regexp.escape(name)}=(?:'([^']*)'|([^,;]+))/)
      fail!("#{id} catalog DDL omits setting #{name}") unless match
      match[1] || match[2]
    end

    def inspect_attached_part!(id, table, store, shared_version, mark_format, compression, mode,
                               source_inventory, expected_candidate_roster)
      schema_tag = marker('active_schema', id)
      part_tag = marker('active_part', id)
      table_path_tag = marker('active_table_path', id)
      sql = "SELECT '#{schema_tag}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;\n" \
        "SELECT '#{part_tag}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;\n" \
        "SELECT '#{table_path_tag}', arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw;\n"
      result = native("#{id}_active_part", store, sql)
      lines = native_lines(result, "#{id} attached active part")
      schema = tagged(lines, schema_tag, 3, id).map { |row| [row[1], row[2].gsub(/\s+/, '')] }
      expected_schema = schema_for(shared_version).map { |name, type| [name, type.gsub(/\s+/, '')] }
      fail!("#{id} attached schema differs") unless schema == expected_schema
      parts = tagged(lines, part_tag, 7, id)
      fail!("#{id} attached part is not a Compact eight-row/five-mark part") unless parts.size == 1 &&
        parts.first.values_at(1, 2, 4, 5, 6) == [table, PART_NAME, 'Compact', ROW_COUNT.to_s, PHYSICAL_MARK_ROWS_WITH_EOF.size.to_s]
      table_paths = tagged(lines, table_path_tag, 2, id)
      fail!("#{id} attached table data path is not unique") unless table_paths.size == 1 && !table_paths.first[1].empty?
      table_path = safe_native_path(table_paths.first[1], store, "#{id} target table")
      part_path = safe_native_path(parts.first.fetch(3), store, "#{id} active part")
      fail!("#{id} active part is not directly inside its table data directory") unless File.dirname(part_path) == table_path
      attached = attached_inventory!(id, part_path, source_inventory)
      roster = native_callback_roster!(id, part_path, mark_format, shared_version)
      assert_stock_callback_roster!(id, roster, mark_format, shared_version)
      fail!("#{id} attached roster differs from its own pre-ATTACH generated roster") unless
        roster.fetch(:roster) == expected_candidate_roster.fetch(:roster)
      metadata = serialization_metadata!("#{id}_attached", part_path)
      profile = @profiles_by_id[id] || @active_profile || fail!("#{id} attached profile was not observed")
      native_settings = table_settings!("#{id}_attached_catalog_settings", table, store,
                                         shared_version, profile, mark_format, compression, mode)
      {part_row: parts.first, table_data_path: table_path, path: part_path, schema: schema,
       inventory: attached.fetch(:inventory), native_owned_sidecar: attached.fetch(:native_owned_sidecar),
       callback_roster: roster, serialization_metadata: metadata, native_table_settings: native_settings,
       invocation: result.fetch(:record)}
    end

    def assert_stock_callback_roster!(id, roster, mark_format, shared_version)
      if mark_format == 'mrk3'
        expected = schema_for(shared_version).each_with_index.map { |(column, _), index| [index, column, nil] }
        fail!("#{id} MRK3 callback roster differs from the declared columns") unless roster.fetch(:roster) == expected
      else
        sections = roster.fetch(:sections).to_h
        expected_columns = schema_for(shared_version).map(&:first)
        fail!("#{id} MRK4 callback columns differ from declaration") unless sections.keys == expected_columns
        VALUE_COLUMNS.each do |name|
          fail!("#{id}/#{name} has no native physical callbacks") if sections.fetch(name).empty?
        end
        fail!("#{id} native JSON callbacks omit all shared-data representation") unless
          sections.values.flatten.any? { |stream| stream.match?(/shared|bucket|copy/i) }
      end
      true
    end

    def native_values_sql(table, id, shared_version, window)
      tag = marker('values', id, window)
      predicate = WINDOWS.fetch(window)
      if window == 'eof'
        return "SELECT '#{tag}', toString(count()) FROM default.#{table} WHERE #{predicate} FORMAT TSVRaw;\n"
      end
      root_token = json_token_sql('root_json')
      array_token = json_token_sql('w278_array_doc')
      tagged_token = json_token_sql('tupleElement(w278_tag, 1)')
      left_token = json_token_sql('tupleElement(pair_json, 1)')
      right_token = json_token_sql('tupleElement(pair_json, 2)')
      tagged_expr = "arrayMap(w278_tag -> concat(#{tagged_token}, '#', toString(tupleElement(w278_tag, 2))), tagged_json)"
      array_expr = "arrayMap(w278_array_doc -> #{array_token}, array_json)"
      fields = [
        "'#{tag}'", 'toString(pk)', root_token,
        "lower(hex(toJSONString(#{array_expr})))",
        "lower(hex(toJSONString(#{tagged_expr})))",
        "concat(#{left_token}, '#', #{right_token})",
      ]
      where = predicate ? " WHERE #{predicate}" : ''
      "SELECT #{fields.join(', ')} FROM default.#{table}#{where} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;\n"
    end

    def json_token_sql(expression)
      "concat(toString(#{expression}.id), '|', lower(hex(#{expression}.label)), '|', " \
        "lower(hex(toJSONString(arraySort(JSONDynamicPaths(#{expression}))))), '|', " \
        "lower(hex(toJSONString(arraySort(JSONSharedDataPaths(#{expression}))))), '|', " \
        "if(isNull(#{expression}.payload), 'NULL', concat(dynamicType(#{expression}.payload), ':', lower(hex(dynamicElement(#{expression}.payload, 'String'))))), '|', " \
        "lower(hex(#{expression}.alpha)), '|', lower(hex(#{expression}.aa)), '|', lower(hex(#{expression}.beta)))"
    end

    def native_values!(id, table, store, shared_version)
      sql = WINDOWS.keys.map { |window| native_values_sql(table, id, shared_version, window) }.join
      result = native("#{id}_values", store, sql)
      lines = native_lines(result, "#{id} exact native full/middle/EOF values")
      observations = {}
      WINDOWS.each_key do |window|
        tag = marker('values', id, window)
        if window == 'eof'
          rows = tagged(lines, tag, 2, "#{id}/#{window}")
          fail!("#{id} EOF native query is not exactly zero rows") unless rows == [[tag, '0']]
          observations[window] = {state: 'exact_values', rows: [], count: 0, raw_rows: rows}
          next
        end
        rows = tagged(lines, tag, 6, "#{id}/#{window}")
        parsed_rows = rows.map { |fields| parse_native_row(fields, id, window) }
        actual = parsed_rows.map { |row| row.fetch(:values) }
        expected = expected_native_rows(window)
        fail!("#{id} #{window} full literal/type signatures differ: #{actual.inspect}") unless actual == expected
        observations[window] = {
          state: 'exact_values', rows: actual,
          observed_path_classifications: parsed_rows.map { |row| row.fetch(:path_observations) }, raw_rows: rows,
        }
      end
      {state: 'exact_values', windows: observations, invocation: result.fetch(:record)}
    end

    def parse_native_row(fields, id, window)
      fail!("#{id}/#{window} native row width differs") unless fields.size == 6
      pk = Integer(fields[1], 10)
      actual_docs = {
        pk: pk,
        root_json: normalize_native_token(fields[2], "#{id}/#{window}/root JSON"),
        array_json: decode_hex_json(fields[3], "#{id}/#{window}/Array JSON").map do |token|
          normalize_native_token(token, "#{id}/#{window}/Array JSON element")
        end,
        tagged_json: decode_hex_json(fields[4], "#{id}/#{window}/tagged JSON").map do |token|
          parts = token.split('#', -1)
          fail!("#{id}/#{window} tagged JSON token grammar differs") unless
            parts.size == 2 && parts[1].match?(/\A(?:0|[1-9][0-9]*)\z/)
          [normalize_native_token(parts[0], "#{id}/#{window}/tagged JSON element"), Integer(parts[1], 10)]
        end,
        pair_json: fields[5].split('#', -1).map do |token|
          normalize_native_token(token, "#{id}/#{window}/pair JSON")
        end,
      }
      actual = {
        pk: pk,
        root_json: actual_docs.fetch(:root_json).fetch(:values),
        array_json: actual_docs.fetch(:array_json).map { |document| document.fetch(:values) },
        tagged_json: actual_docs.fetch(:tagged_json).map { |document, tag| [document.fetch(:values), tag] },
        pair_json: actual_docs.fetch(:pair_json).map { |document| document.fetch(:values) },
      }
      expected = literal_row(pk)
      fail!("#{id}/#{window} native row pk=#{pk} differs from independent literal fields: actual=#{actual.inspect}; expected=#{expected.inspect}") unless actual == expected
      {
        values: actual,
        path_observations: {
          root_json: actual_docs.fetch(:root_json).fetch(:paths),
          array_json: actual_docs.fetch(:array_json).map { |document| document.fetch(:paths) },
          tagged_json: actual_docs.fetch(:tagged_json).map { |document, _tag| document.fetch(:paths) },
          pair_json: actual_docs.fetch(:pair_json).map { |document| document.fetch(:paths) },
        },
      }
    rescue ArgumentError => error
      fail!("#{id}/#{window} native row is malformed: #{error.message}")
    end

    def normalize_native_token(token, label)
      fields = token.split('|', -1)
      fail!("#{label} token grammar/field count differs") unless fields.size == 8 && fields[0].match?(/\A(?:0|[1-9][0-9]*)\z/)
      label_hex = normalized_native_hex(fields[1], "#{label} label")
      dynamic_path_hex = normalized_native_hex(fields[2], "#{label} Dynamic paths")
      shared_path_hex = normalized_native_hex(fields[3], "#{label} shared-data paths")
      dynamic_paths = decode_hex_json(dynamic_path_hex, "#{label} Dynamic paths")
      shared_paths = decode_hex_json(shared_path_hex, "#{label} shared-data paths")
      [dynamic_paths, shared_paths].each do |paths|
        fail!("#{label} path list must contain unique sorted String names") unless
          paths.is_a?(Array) && paths.all? { |path| path.is_a?(String) } &&
          paths == paths.sort_by(&:b) && paths.uniq == paths
      end
      payload_token = fields[4]
      fail!("#{label} payload token differs") unless
        payload_token == 'NULL' || payload_token.match?(/\AString:(?:[0-9a-f]{2})*\z/)
      shared_hex = fields[5..7].map { |value| normalized_native_hex(value, "#{label} shared String") }
      known_paths = SHARED_PATHS + (payload_token == 'NULL' ? [] : ['payload'])
      all_paths = dynamic_paths + shared_paths
      fail!("#{label} observed Dynamic/shared path classification is not a disjoint complete partition") unless
        (dynamic_paths & shared_paths).empty? && all_paths.sort_by(&:b) == known_paths.sort_by(&:b) && dynamic_paths.size <= 1
      {
        values: {
          id: Integer(fields[0], 10), label_hex: label_hex,
          payload: payload_token == 'NULL' ? nil : payload_token,
          shared_values: SHARED_VALUE_ORDER.zip(shared_hex).to_h,
        },
        paths: {dynamic: dynamic_paths, shared_data: shared_paths},
      }
    end

    def normalized_native_hex(value, label)
      fail!("#{label} is not even-length lowercase byte hex") unless value.match?(/\A(?:[0-9a-f]{2})*\z/)
      value
    end

    def decode_hex_json(value, label)
      fail!("#{label} is not even-length hex") unless value.match?(/\A(?:[0-9a-fA-F]{2})*\z/)
      JSON.parse([value].pack('H*'))
    rescue JSON::ParserError => error
      fail!("#{label} contains malformed JSON: #{error.message}")
    end

    def expected_native_rows(window)
      selected = case window
                 when 'full' then (0...ROW_COUNT).to_a
                 when 'middle' then (2...6).to_a
                 else fail!("unknown native row window #{window.inspect}")
                 end
      selected.map { |index| literal_row(index + 1) }
    end

    def literal_row(pk)
      index = pk - 1
      {
        pk: pk,
        root_json: expected_doc_value(ROOT_ROWS.fetch(index)),
        array_json: ARRAY_ROWS.fetch(index).map { |document| expected_doc_value(document) },
        tagged_json: TAGGED_ROWS.fetch(index).map { |document, tag| [expected_doc_value(document), tag] },
        pair_json: PAIR_ROWS.fetch(index).map { |document| expected_doc_value(document) },
      }
    end

    def expected_doc_value(document)
      payload = document.fetch(:payload)
      shared = document.fetch(:shared)
      {
        id: document.fetch(:id), label_hex: document.fetch(:label).unpack1('H*'),
        payload: payload.nil? ? nil : "String:#{payload.unpack1('H*')}",
        shared_values: shared.transform_values { |value| value.unpack1('H*') },
      }
    end

    def literal_rows_by_column
      {
        'root_json' => ROOT_ROWS,
        'array_json' => ARRAY_ROWS,
        'tagged_json' => TAGGED_ROWS.map { |row| row.map { |document, tag| TupleValue.new([document, tag]) } },
        'pair_json' => PAIR_ROWS.map { |row| TupleValue.new(row) },
      }
    end

    def literal_signatures
      literal_rows_by_column.transform_values { |rows| rows.map { |value| storage_signature(value) } }
    end

    def storage_signature(value)
      if value.is_a?(Hash) && value[:kind] == :json
        fields = {'id' => [:u64, value.fetch(:id)], 'label' => [:string, value.fetch(:label)]}
        value.fetch(:shared).each { |path, bytes| fields[path] = [:string, bytes] }
        fields['payload'] = [:string, value.fetch(:payload)] unless value.fetch(:payload).nil?
        members = fields.keys.sort_by(&:b).map do |path|
          kind, leaf = fields.fetch(path)
          "#{path.bytesize}:#{path.unpack1('H*')}=#{kind == :u64 ? "U64:#{leaf}" : string_signature(leaf)}"
        end
        "JSON{#{members.join(';')}}"
      elsif value.is_a?(Array)
        "Array[#{value.map { |child| storage_signature(child) }.join(';')}]"
      elsif value.is_a?(TupleValue)
        "Tuple(#{value.values.map { |child| storage_signature(child) }.join(';')})"
      elsif value.is_a?(Integer)
        "U8:#{value}"
      else
        fail!("unknown independent W278 literal node #{value.inspect}")
      end
    end

    def string_signature(bytes)
      "S#{bytes.bytesize}:#{bytes.unpack1('H*')}"
    end

    def normalize_type(value)
      value.gsub(/\s+/, '').gsub(
        'JSON(max_dynamic_paths=1,max_dynamic_types=1,',
        'JSON(max_dynamic_types=1,max_dynamic_paths=1,'
      )
    end

    def assert_profile_roster_deltas!
      MARK_FORMATS.each do |mark_format|
        next unless mark_format == 'mrk4'
        SHARED_VERSIONS.each do |shared_version|
          MARK_COMPRESSION.each do |compression|
            VARIANT_MODES.each do |mode|
              s0 = @stock.fetch(cell_id('stock', shared_version, 's0', mark_format, compression, mode))
              s1 = @stock.fetch(cell_id('stock', shared_version, 's1', mark_format, compression, mode))
              fail!('stock String metadata profiles are not independently observed') unless
                s0.dig(:serialization_metadata, :string_version) == 0 && s1.dig(:serialization_metadata, :string_version) == 1
              left = s0.fetch(:callback_roster).fetch(:sections).to_h.transform_values(&:to_set)
              right = s1.fetch(:callback_roster).fetch(:sections).to_h.transform_values(&:to_set)
              VALUE_COLUMNS.each do |column|
                added = right.fetch(column) - left.fetch(column)
                fail!("#{shared_version}/#{column} has no S1-only String-size callback") unless
                  added.any? { |stream| stream.match?(/\.size\z/) }
                fail!("#{shared_version}/#{column} S1 adds a non-size callback unexpectedly") unless
                  added.all? { |stream| stream.match?(/\.size\z/) }
              end
            end
          end
        end
      end
      true
    end

    def build_summary
      status = @stock_only ? 'stock_native_matrix_exact' : 'stock_first_native_and_generated_matrix_exact'
      {
        format: FORMAT, status: status,
        execution_order: '32 independent stock/native cells: pinned CREATE, exact RowBinary INSERT argv/stdin, exact JSON full/middle/EOF values, part/schema/CHECK/callback/profile assertions; optional local stock helper reads only after all stock controls; then 32 generated parts with local reads and detached native ATTACH/CHECK/value windows',
        runtime_pin: {binary: @binary, expected_sha256: BINARY_SHA256, sha256_before: @binary_sha_before,
                      sha256_after: @binary_sha_after, version: VERSION, build: BUILD,
                      distinction: 'runtime executable hash/version/build and upstream source revision are separately pinned'},
        source_pin: {root: @source_root, revision: SOURCE_REVISION, sha256: @upstream_hashes, guards: @source_guard},
        helper_pin: @full_matrix ? {path: @helper, sha256: @helper_sha_after} : nil,
        probe_sources: @probe_hashes_after,
        fixture: {
          schema: SCHEMA, row_count: ROW_COUNT, rows_per_mark: ROWS_PER_MARK,
          data_marks: DATA_MARK_COUNT, stock_physical_mark_rows_with_eof: PHYSICAL_MARK_ROWS_WITH_EOF,
          generated_data_mark_rows: WRITER_MARK_ROWS, generated_physical_mark_rows_with_eof: PHYSICAL_MARK_ROWS_WITH_EOF,
          keys: (1..8).to_a, middle_keys: [3, 4, 5, 6],
          native_literal_rows: literal_summary_rows,
          native_windows: WINDOWS, physical_windows: PHYSICAL_WINDOWS,
          string_profile_observation: 'S0/S1 serialization.json metadata and MRK4 per-column callback deltas are independently checked; all four columns must gain at least one String .size callback under S1',
          advanced_chunking: {object_shared_data_target_chunk_rows: 1, expected_data_rows_per_parent_mark: 2,
                              purpose: 'force multiple shared-data chunks for ADVANCED_CHUNKED while keeping S1/S0 context and bucket layout fixed'},
        },
        matrix: {shared_data_versions: SHARED_VERSIONS, profiles: PROFILES, mark_formats: MARK_FORMATS,
                 mark_compression: MARK_COMPRESSION, variant_modes: VARIANT_MODES,
                 buckets: 2, propagation: true, stock_cells: @stock.keys, generated_cells: @generated.keys},
        stock: @stock, generated: @generated, invocations: @invocations, evidence_root: @root,
        claim_boundary: 'Finite eight-row/four-data-mark witness at direct schema-bound JSON root, Array(JSON), Array(Tuple(JSON,UInt8)), and Tuple(JSON,JSON) sites. Cells request Object shared-data version V2/ADVANCED or V3/ADVANCED_CHUNKED with bucket_count=2, ordinary String profiles S0/S1, MRK3/MRK4, and plain/compressed marks. BASIC/COMPACT discriminator settings are persisted and observed, but no mode-specific wire effect is claimed. Stock exact typed values, observed DynamicPaths/SharedDataPaths, Compact/CHECK, metadata, callbacks, and RowBinary process evidence are required before optional Crystal work; helper requested-version fields are request echoes, not per-site wire observations. Full mode additionally checks recursive local typed reads, generated inventory, detached native ATTACH/CHECK, and exact value windows. This does not qualify typed-Dynamic child-owned JSON layouts, arbitrary schemas/settings, or all recursive codecs.',
      }
    end

    def literal_summary_rows
      ROW_COUNT.times.map do |index|
        {pk: index + 1, root: literal_summary_doc(ROOT_ROWS.fetch(index)),
         array: ARRAY_ROWS.fetch(index).map { |document| literal_summary_doc(document) },
         tagged: TAGGED_ROWS.fetch(index).map { |document, tag| [literal_summary_doc(document), tag] },
         pair: PAIR_ROWS.fetch(index).map { |document| literal_summary_doc(document) }}
      end
    end

    def render_summary(summary)
      lines = [
        '# W278 Compact ADVANCED/ADVANCED_CHUNKED propagated-String native matrix', '',
        "Status: `#{summary.fetch(:status)}`",
        "Runtime: `#{VERSION}` build `#{BUILD}` SHA-256 `#{BINARY_SHA256}`.",
        "Source: `#{SOURCE_REVISION}` at `#{SOURCE_ROOT}` (independent pin).",
        'Every stock part is eight rows, four two-row data marks, plus the physical zero-row EOF mark. Independent Ruby RowBinary preserves binary/NUL literals; each insert query is in argv and its exact payload is captured as `.stdin.bin`.',
      ]
      @stock.each do |id, entry|
        values = entry.fetch(:native_values).fetch(:windows)
        lines << "- #{id}: Compact/CHECK healthy; String#{entry.fetch(:profile) == 's1' ? 1 : 0}, #{entry.fetch(:shared_layout)}, MRK#{entry.fetch(:mark_format).delete_prefix('mrk')}, #{entry.fetch(:compression)}, #{entry.fetch(:variant_mode)}; full/middle/EOF exact."
      end
      unless @stock_only
        @generated.each do |id, entry|
          lines << "- #{id}: local full/middle/EOF, pre-ATTACH inventory, native ATTACH/CHECK and exact values; active part `#{entry.fetch(:active_part).fetch(:part_row)[4]}`."
        end
      end
      lines.concat(['', summary.fetch(:claim_boundary), ''])
      lines.join("\n")
    end

    def literal_summary_doc(document)
      {id: document.fetch(:id), label_hex: document.fetch(:label).unpack1('H*'),
       payload_hex: document.fetch(:payload)&.unpack1('H*'),
       shared_values: document.fetch(:shared).transform_values { |value| value.unpack1('H*') }}
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  options = {
    binary: ProbeCompactAdvancedJsonWriterW278::BINARY,
    source_root: ProbeCompactAdvancedJsonWriterW278::SOURCE_ROOT,
    evidence_root: nil, stock_only: false, full_matrix: false, helper: nil, helper_sha256: nil,
  }
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/probe_compact_advanced_json_writer_w278.rb (--stock-only | --full-matrix --helper PREBUILT --helper-sha256 SHA256) --evidence-root EMPTY_DIR [--binary PINNED_CLICKHOUSE] [--source-root PINNED_UPSTREAM]'
    parser.on('--stock-only', 'Run all 32 independent stock/native cells; never starts the Crystal helper') { options[:stock_only] = true }
    parser.on('--full-matrix', 'Run 32 stock cells first, then helper reads and 32 generated/native ATTACH/CHECK cells') { options[:full_matrix] = true }
    parser.on('--helper PATH', 'Prebuilt W278 Crystal helper; required only with --full-matrix') { |value| options[:helper] = value }
    parser.on('--helper-sha256 SHA256', 'Exact lowercase SHA-256 for the prebuilt helper') { |value| options[:helper_sha256] = value }
    parser.on('--evidence-root EMPTY_DIR', 'Existing empty direct child of /private/tmp') { |value| options[:evidence_root] = value }
    parser.on('--binary PATH', 'Pinned ClickHouse runtime executable, distinct from source checkout') { |value| options[:binary] = value }
    parser.on('--source-root PATH', 'Separately pinned upstream ClickHouse source checkout') { |value| options[:source_root] = value }
  end.parse!

  unless options[:stock_only] != options[:full_matrix] && options[:evidence_root]
    warn 'W278: select exactly one of --stock-only or --full-matrix and provide --evidence-root'
    exit 2
  end
  if options[:stock_only] && (options[:helper] || options[:helper_sha256])
    warn 'W278: --helper and --helper-sha256 are valid only with --full-matrix'
    exit 2
  end
  if options[:full_matrix] && (!options[:helper] || !options[:helper_sha256])
    warn 'W278: --full-matrix requires --helper and --helper-sha256'
    exit 2
  end
  probe = ProbeCompactAdvancedJsonWriterW278::Probe.new(**options)
  exit(probe.run ? 0 : 1)
end
