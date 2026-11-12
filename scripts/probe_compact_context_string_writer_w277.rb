#!/usr/bin/env ruby
# Stock-first native witness for propagated String1 in admitted Compact
# Dynamic/JSON contexts. RowBinary literal input and SQL read expectations are
# independent of the Crystal fixture and helper.

require 'digest'
require 'json'
require 'open3'
require 'optparse'
require_relative 'probe_compact_string_writer_w276'

module ProbeCompactContextStringWriterW277
  W276 = ProbeCompactStringWriterW276
  W273 = W276::W273
  W271 = W276::W271
  W241 = W276::W241

  FORMAT = 'compact_context_string_writer_w277_native_probe_v1'.freeze
  HELPER_FORMAT = 'compact_context_string_writer_w277_helper_v1'.freeze
  PART_NAME = 'all_1_1_0'.freeze
  BINARY = W271::BINARY
  BINARY_SHA256 = W271::BINARY_SHA256
  VERSION = W271::VERSION
  BUILD = W271::BUILD
  SOURCE_ROOT = W271::SOURCE_ROOT
  SOURCE_REVISION = W271::SOURCE_REVISION
  SOURCE_FILES = (W276::SOURCE_FILES + %w[
    src/Columns/ColumnObject.cpp
    src/DataTypes/DataTypeObject.cpp
    src/DataTypes/Serializations/SerializationJSON.cpp
    src/DataTypes/Serializations/SerializationObject.cpp
    src/DataTypes/Serializations/SerializationObjectSharedData.cpp
    src/DataTypes/Serializations/SerializationDynamic.cpp
    src/DataTypes/Serializations/SerializationArray.cpp
    src/DataTypes/Serializations/SerializationTuple.cpp
    src/DataTypes/Serializations/ISerialization.cpp
    src/DataTypes/DataTypesBinaryEncoding.cpp
    src/DataTypes/DataTypesBinaryEncoding.h
    src/DataTypes/Serializations/SerializationString.cpp
    src/Formats/FormatFactory.cpp
    src/Formats/FormatSettings.h
    src/Formats/registerFormats.cpp
  ]).uniq.freeze

  HELPER_SOURCE = File.expand_path('compact_context_string_writer_w277_helper.cr', __dir__).freeze
  PROBE_SOURCE = File.expand_path(__FILE__).freeze
  FIXTURE_SOURCE = File.expand_path('../spec/support/compact_part_writer_w277_fixture.cr', __dir__).freeze
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
  MAX_PART_FILES = 192
  MAX_PART_BYTES = 64 * 1024 * 1024
  MAX_RAW_FILE_BYTES = 16 * 1024 * 1024
  MAX_REPORT_BYTES = 8 * 1024 * 1024
  LAYOUTS = %w[map map_with_buckets].freeze
  MARK_FORMATS = %w[mrk3 mrk4].freeze
  MARK_COMPRESSION = %w[plain compressed].freeze
  VARIANT_MODES = %w[basic compact].freeze
  WINDOWS = {
    'full' => nil,
    'middle' => 'pk BETWEEN 3 AND 6',
    'eof' => 'pk > 8',
  }.freeze
  PHYSICAL_WINDOWS = {
    'full' => [0, 4].freeze,
    'middle' => [1, 2].freeze,
    'eof' => [4, 0].freeze,
  }.freeze

  ROOT_DYNAMIC_TYPE = 'Dynamic(max_types=1)'.freeze
  TUPLE_ARRAY_TYPE = 'Tuple(label String,items Array(Dynamic(max_types=1)))'.freeze
  ROOT_JSON_TYPE = 'JSON(max_dynamic_types=1,max_dynamic_paths=1,id UInt64,label String)'.freeze
  TYPED_JSON_TYPE = 'JSON(max_dynamic_types=1,max_dynamic_paths=0,payload Dynamic(max_types=1))'.freeze
  LEAF_JSON_TYPE = 'JSON(max_dynamic_types=0,max_dynamic_paths=0,value String)'.freeze
  ARRAY_JSON_TYPE = "Array(Array(#{LEAF_JSON_TYPE}))".freeze
  # BinaryTypeIndex::JSON(0x30), serialization version 0, zero dynamic paths,
  # zero dynamic types, one typed path `value String`, and no skipped paths or
  # regexps. This is the pinned RowBinary type tag for ARRAY_JSON_TYPE.
  ARRAY_JSON_BINARY_TYPE = ['1e1e30000000010576616c7565150000'].pack('H*').freeze
  DYNAMIC_TYPE_NAMES = {
    'root_dynamic_string' => ROOT_DYNAMIC_TYPE,
    'tuple_array_dynamic_string' => TUPLE_ARRAY_TYPE,
    'json_root_string' => ROOT_JSON_TYPE,
    'typed_dynamic_depth2_array_json_string' => TYPED_JSON_TYPE,
  }.freeze
  SCHEMA_COMMON = [
    ['pk', 'UInt64'],
    ['root_dynamic_string', ROOT_DYNAMIC_TYPE],
    ['tuple_array_dynamic_string', TUPLE_ARRAY_TYPE],
    ['json_root_string', ROOT_JSON_TYPE],
  ].map(&:freeze).freeze
  SCHEMA_MAP = (SCHEMA_COMMON + [['typed_dynamic_depth2_array_json_string', TYPED_JSON_TYPE].freeze]).map(&:freeze).freeze
  SCHEMAS = {'map' => SCHEMA_MAP, 'map_with_buckets' => SCHEMA_COMMON}.freeze
  VALUE_COLUMNS = {
    'map' => %w[root_dynamic_string tuple_array_dynamic_string json_root_string typed_dynamic_depth2_array_json_string].freeze,
    'map_with_buckets' => %w[root_dynamic_string tuple_array_dynamic_string json_root_string].freeze,
  }.freeze

  LONG_STRING = ('long:' + ('x' * 256)).b.freeze
  BINARY_STRING = ['00ff8041'].pack('H*').freeze
  # Literal native rows are deliberately duplicated here rather than loaded
  # from the local Crystal fixture or helper.
  ROWS = [
    {pk: 1, root: ''.b, items: [[:uint16, 1], [:string, ''.b]], json_payload: ''.b,
     json_label: 'json-0'.b, shared_text: 'shared-0'.b, nested_json: [['alpha'.b, ''.b], [LONG_STRING]]},
    {pk: 2, root: nil, items: [], json_payload: nil,
     json_label: 'json-1'.b, shared_text: 'shared-1'.b, nested_json: nil},
    {pk: 3, root: 'root-2'.b, items: [[:string, 'nested'.b], [:uint16, 2]], json_payload: 'payload-2'.b,
     json_label: 'json-2'.b, shared_text: 'shared-2'.b, nested_json: nil},
    {pk: 4, root: LONG_STRING, items: [[:null, nil]], json_payload: LONG_STRING,
     json_label: 'json-3'.b, shared_text: 'shared-3'.b, nested_json: nil},
    {pk: 5, root: BINARY_STRING, items: [[:uint16, 3]], json_payload: BINARY_STRING,
     json_label: 'json-4'.b, shared_text: 'shared-4'.b, nested_json: []},
    {pk: 6, root: "nul\0tail".b, items: [[:string, BINARY_STRING]], json_payload: "json\0tail".b,
     json_label: 'json-5'.b, shared_text: 'shared-5'.b, nested_json: [[]]},
    {pk: 7, root: 'root-6'.b, items: [], json_payload: 'payload-6'.b,
     json_label: 'json-6'.b, shared_text: 'shared-6'.b, nested_json: nil},
    {pk: 8, root: 'root-7'.b, items: [[:string, LONG_STRING]], json_payload: 'payload-7'.b,
     json_label: 'json-7'.b, shared_text: 'shared-7'.b, nested_json: [[BINARY_STRING]]},
  ].map(&:freeze).freeze

  HELPER_SIGNATURES = {
    'root_dynamic_string' => [
      'S0:', 'NULL', 'S6:726f6f742d32', "S261:6c6f6e673a#{'78' * 256}", 'S4:00ff8041',
      'S8:6e756c007461696c', 'S6:726f6f742d36', 'S6:726f6f742d37',
    ].freeze,
    'tuple_array_dynamic_string' => [
      'row00:[UInt16:1,S0:]', 'row01:[]', 'row02:[S6:6e6573746564,UInt16:2]', 'row03:[NULL]',
      'row04:[UInt16:3]', 'row05:[S4:00ff8041]', "row06:[]", "row07:[S261:6c6f6e673a#{'78' * 256}]",
    ].freeze,
    'json_root_string' => [
      "U64:1|S6:6a736f6e2d30|S0:|S8:7368617265642d30",
      "U64:2|S6:6a736f6e2d31|NULL|S8:7368617265642d31",
      "U64:3|S6:6a736f6e2d32|S9:7061796c6f61642d32|S8:7368617265642d32",
      "U64:4|S6:6a736f6e2d33|S261:6c6f6e673a#{'78' * 256}|S8:7368617265642d33",
      "U64:5|S6:6a736f6e2d34|S4:00ff8041|S8:7368617265642d34",
      "U64:6|S6:6a736f6e2d35|S9:6a736f6e007461696c|S8:7368617265642d35",
      "U64:7|S6:6a736f6e2d36|S9:7061796c6f61642d36|S8:7368617265642d36",
      "U64:8|S6:6a736f6e2d37|S9:7061796c6f61642d37|S8:7368617265642d37",
    ].freeze,
    'typed_dynamic_depth2_array_json_string' => [
      "D:[[J(S5:616c706861),J(S0:)],[J(S261:6c6f6e673a#{'78' * 256})]]",
      'NULL', 'NULL', 'NULL', 'D:[]', 'D:[[]]', 'NULL', 'D:[[J(S4:00ff8041)]]',
    ].freeze,
  }.freeze

  class Failure < StandardError; end

  class Probe < W276::Probe
    def run
      prepare!
      LAYOUTS.each do |layout|
        MARK_FORMATS.each do |mark_format|
          MARK_COMPRESSION.each do |compression|
            VARIANT_MODES.each do |mode|
              id = cell_id('stock', layout, mark_format, compression, mode)
              @stock[id] = capture_stock!(id, layout, mark_format, compression, mode)
            end
          end
        end
      end
      unless @stock_only
        @stock.each { |id, entry| capture_stock_local_reads!(id, entry) }
        LAYOUTS.each do |layout|
          MARK_FORMATS.each do |mark_format|
            MARK_COMPRESSION.each do |compression|
              VARIANT_MODES.each do |mode|
                id = cell_id('generated', layout, mark_format, compression, mode)
                @generated[id] = capture_generated!(id, layout, mark_format, compression, mode)
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
      puts "W277 status=#{summary.fetch(:status)}; stock=#{@stock.size}; generated=#{@generated.size}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      persist_inconclusive(error)
      warn "W277 probe inconclusive: #{@fatal_error}"
      false
    end

    private

    def fail!(message)
      raise Failure, "W277: #{message}"
    end

    def validate_literals!
      fail!('literal native oracle must contain eight ordered rows and four two-row marks') unless
        ROWS.size == ROW_COUNT && ROWS.map { |row| row.fetch(:pk) } == (1..8).to_a &&
        ROWS.each_slice(ROWS_PER_MARK).to_a.size == DATA_MARK_COUNT
      fail!('layout column roster differs from the frozen W277 fixture contract') unless
        VALUE_COLUMNS.fetch('map').size == 4 && VALUE_COLUMNS.fetch('map_with_buckets').size == 3 &&
        ROWS[4].fetch(:nested_json) == [] && ROWS[5].fetch(:nested_json) == [[]]
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
      @probe_sources = [PROBE_SOURCE, HELPER_SOURCE, FIXTURE_SOURCE, W276_SOURCE, W241_SOURCE, W271_SOURCE,
                        W273_SOURCE, W264_SOURCE].map { |path| File.realpath(path) }.uniq.sort
      @probe_hashes_before = @probe_sources.to_h { |path| [path, sha(path)] }
      if @full_matrix
        @helper_sha_before = sha(@helper)
        fail!('prebuilt W277 helper SHA differs from CLI pin') unless @helper_sha_before == @helper_expected_sha
      end
    end

    def source_guard!
      string_guard = super
      serialization_object = File.binread(File.join(@source_root, 'src/DataTypes/Serializations/SerializationObject.cpp')).force_encoding(Encoding::UTF_8)
      serialization_dynamic = File.binread(File.join(@source_root, 'src/DataTypes/Serializations/SerializationDynamic.cpp')).force_encoding(Encoding::UTF_8)
      binary_encoding = File.binread(File.join(@source_root, 'src/DataTypes/DataTypesBinaryEncoding.cpp')).force_encoding(Encoding::UTF_8)
      serialization_string = File.binread(File.join(@source_root, 'src/DataTypes/Serializations/SerializationString.cpp')).force_encoding(Encoding::UTF_8)
      serialization_array = File.binread(File.join(@source_root, 'src/DataTypes/Serializations/SerializationArray.cpp')).force_encoding(Encoding::UTF_8)
      format_factory = File.binread(File.join(@source_root, 'src/Formats/FormatFactory.cpp')).force_encoding(Encoding::UTF_8)
      formats = File.binread(File.join(@source_root, 'src/Formats/registerFormats.cpp')).force_encoding(Encoding::UTF_8)
      facts = {
        inherited_string1_and_size_stream_guard: string_guard,
        object_rowbinary_path_dispatch_pinned: serialization_object.include?('void SerializationObject::deserializeBinary(IColumn & col') &&
          serialization_object.include?('readVarUInt(number_of_paths, istr)') && serialization_object.include?('read_json_as_string') &&
          serialization_object.include?('dynamic_serialization->deserializeBinary(*dynamic_column, istr, settings)'),
        dynamic_type_tag_dispatch_pinned: serialization_dynamic.include?('auto variant_type = decodeDataType(istr') &&
          serialization_dynamic.include?('void SerializationDynamic::deserializeBinary(ColumnDynamic & dynamic_column'),
        rowbinary_type_encoding_pinned: binary_encoding.include?('case BinaryTypeIndex::JSON:') &&
          binary_encoding.include?('TYPE_JSON_SERIALIZATION_VERSION = 0') && binary_encoding.include?('case BinaryTypeIndex::Dynamic:'),
        string_and_array_rowbinary_lengths_pinned: serialization_string.include?('readVarUInt(size, istr)') &&
          serialization_string.include?('istr.readStrict(reinterpret_cast<char*>(&data[offset - size]), size)') &&
          serialization_array.include?('readVarUInt(size, istr)'),
        rowbinary_registration_pinned: formats.include?('registerInputFormatRowBinary(factory)'),
        binary_json_setting_binding_pinned: format_factory.include?('format_settings.binary.read_json_as_string = settings[Setting::input_format_binary_read_json_as_string]'),
        runtime_source_are_distinct_pins: @source_root != @binary,
      }
      fail!('pinned source does not expose the guarded RowBinary Object/Dynamic String input route') unless
        facts[:object_rowbinary_path_dispatch_pinned] && facts[:dynamic_type_tag_dispatch_pinned] &&
        facts[:rowbinary_type_encoding_pinned] && facts[:string_and_array_rowbinary_lengths_pinned] &&
        facts[:rowbinary_registration_pinned] && facts[:binary_json_setting_binding_pinned] && facts[:runtime_source_are_distinct_pins]
      facts
    end

    def validate_pins!
      @binary_sha_after = sha(@binary)
      @probe_hashes_after = @probe_sources.to_h { |path| [path, sha(path)] }
      fail!('ClickHouse runtime changed during capture') unless @binary_sha_after == BINARY_SHA256
      fail!('W277 probe, helper source, or fixture changed during capture') unless @probe_hashes_after == @probe_hashes_before
      if @full_matrix
        @helper_sha_after = sha(@helper)
        fail!('prebuilt W277 helper changed during capture') unless @helper_sha_after == @helper_sha_before
      end
    end

    def cell_id(prefix, layout, mark_format, compression, mode)
      [prefix, layout, mark_format, compression, mode].join('_')
    end

    def marker(kind, id, window = nil)
      suffix = window ? "_#{window.upcase}" : ''
      "__W277_#{kind.to_s.upcase}_#{id.upcase}#{suffix}__"
    end

    def table_name(id)
      "w277_#{@token}_#{id}"
    end

    def schema_for(layout)
      SCHEMAS.fetch(layout) { fail!("unknown shared-data layout #{layout.inspect}") }
    end

    def settings(layout, mark_format, compression, mode)
      buckets = layout == 'map' ? 1 : 2
      shared_version = layout == 'map' ? 'map' : 'map_with_buckets'
      substream_marks = mark_format == 'mrk4' ? 1 : 0
      compress_marks = compression == 'compressed' ? 1 : 0
      discriminator = mode == 'compact' ? 1 : 0
      [
        'index_granularity=2', 'index_granularity_bytes=10485760', 'enable_mixed_granularity_parts=1',
        'min_rows_for_wide_part=1000000', 'min_bytes_for_wide_part=104857600', 'min_level_for_wide_part=0',
        "compress_marks=#{compress_marks}", "marks_compression_codec='LZ4'", 'compress_primary_key=0',
        'write_final_mark=1', "write_marks_for_substreams_in_compact_parts=#{substream_marks}",
        'min_compress_block_size=0', 'max_compress_block_size=4096', 'ratio_of_defaults_for_sparse_serialization=1.0',
        "default_compression_codec='LZ4'", "serialization_info_version='with_types'",
        'propagate_types_serialization_versions_to_nested_types=true', "string_serialization_version='with_size_stream'",
        "object_serialization_version='v3'", "object_shared_data_serialization_version='#{shared_version}'",
        "object_shared_data_serialization_version_for_zero_level_parts='#{shared_version}'",
        "object_shared_data_buckets_for_compact_part=#{buckets}", "dynamic_serialization_version='v3'",
        "use_compact_variant_discriminators_serialization=#{discriminator}", 'allow_suspicious_low_cardinality_types=1',
      ].join(', ')
    end

    def create_sql(table, layout, mark_format, compression, mode)
      declarations = schema_for(layout).map { |name, type| "`#{name}` #{type}" }.join(', ')
      "SET flatten_nested=0;\nSET allow_suspicious_low_cardinality_types=1;\nSET use_variant_as_common_type=1;\n" \
        "CREATE TABLE default.#{table} (#{declarations}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings(layout, mark_format, compression, mode)};\n"
    end

    def sql_string(value)
      "'#{value.to_s.gsub(/[\\']/) { |character| "\\#{character}" }}'"
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
      if value.is_a?(Integer)
        fail!('RowBinary UInt16 literal is outside its declared range') unless value.between?(0, 0xffff)
        return "\x02".b + [value].pack('v')
      end
      fail!('RowBinary Dynamic literal must be String, UInt16, or NULL') unless value.is_a?(String)
      "\x15".b + rowbinary_string(value)
    end

    def rowbinary_array_dynamic(values)
      rowbinary_var_uint(values.size) + values.map { |item| rowbinary_dynamic(item) }.join.b
    end

    def rowbinary_tuple(label, values)
      rowbinary_string(label) + rowbinary_array_dynamic(values.map { |kind, value|
        case kind
        when :uint16, :string then value
        when :null then nil
        else fail!('RowBinary tuple literal has an unsupported Dynamic arm')
        end
      })
    end

    def rowbinary_json_path(path, value)
      rowbinary_string(path) + value
    end

    def rowbinary_root_json(row)
      paths = [
        rowbinary_json_path('id', [row.fetch(:pk)].pack('Q<')),
        rowbinary_json_path('label', rowbinary_string(row.fetch(:json_label))),
      ]
      payload = row.fetch(:json_payload)
      paths << rowbinary_json_path('payload', rowbinary_dynamic(payload)) unless payload.nil?
      paths << rowbinary_json_path('shared_text', rowbinary_dynamic(row.fetch(:shared_text)))
      rowbinary_var_uint(paths.size) + paths.join.b
    end

    def rowbinary_leaf_json(value)
      rowbinary_var_uint(1) + rowbinary_json_path('value', rowbinary_string(value))
    end

    def rowbinary_nested_json(value)
      return "\x00".b if value.nil?
      body = rowbinary_var_uint(value.size)
      value.each do |group|
        body << rowbinary_var_uint(group.size)
        group.each { |leaf| body << rowbinary_leaf_json(leaf) }
      end
      ARRAY_JSON_BINARY_TYPE + body
    end

    def rowbinary_typed_json(value)
      rowbinary_var_uint(1) + rowbinary_json_path('payload', rowbinary_nested_json(value))
    end

    def rowbinary_rows(layout)
      ROWS.map do |row|
        values = [
          [row.fetch(:pk)].pack('Q<'),
          rowbinary_dynamic(row.fetch(:root)),
          rowbinary_tuple(format('row%02d', row.fetch(:pk) - 1), row.fetch(:items)),
          rowbinary_root_json(row),
        ]
        values << rowbinary_typed_json(row.fetch(:nested_json)) if layout == 'map'
        values.join.b
      end.join.b
    end

    def capture_stock!(id, layout, mark_format, compression, mode)
      table = table_name(id)
      store = store_path(id)
      create = native("#{id}_create", store, create_sql(table, layout, mark_format, compression, mode))
      insert = native_rowbinary("#{id}_insert_rowbinary", store, table, layout)
      stage = inspect_native_part!(id, table, store, layout, mark_format, compression, mode)
      check = check!(id, table, store)
      values = native_values!(id, table, store, layout)
      fail!("#{id} native independent literal values/types/path roster differ") unless values.fetch(:state) == 'exact_values'
      insert_record = insert.fetch(:record)
      stage.merge(create: create.fetch(:record), rowbinary_insert: insert_record,
                  rowbinary_ingress: {
                    format: 'RowBinary', stdin_encoding: 'rowbinary', read_json_as_string: false,
                    setting: '--input_format_binary_read_json_as_string=0',
                    query: insert_record.fetch(:argv).last, rows: ROW_COUNT,
                    stdin_file: insert_record.fetch(:stdin_file), stdin_bytes: insert_record.fetch(:stdin_bytes),
                    stdin_sha256: insert_record.fetch(:stdin_sha256),
                    version_build_observation: {
                      invocation: create.fetch(:record).fetch(:label), version: VERSION, build: BUILD,
                      scope: 'observed by the immediately preceding _create pin SQL; not selected in the RowBinary process',
                    },
                    executable_sha256_before: insert_record.fetch(:binary_sha_before),
                    executable_sha256_after: insert_record.fetch(:binary_sha_after),
                  }, check: check, native_values: values)
    end

    def native_rowbinary(label, store, table, layout)
      query = "INSERT INTO default.#{table} FORMAT RowBinary"
      input = rowbinary_rows(layout)
      argv = [@binary, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
              "--max_memory_usage=#{W241::MEMORY}", '--input_format_binary_read_json_as_string=0', '--query', query]
      register_expected!(label, argv, input, 'clickhouse-local', @binary, BINARY_SHA256, store, stdin_encoding: 'rowbinary')
      result = @runner.send(:run_process, label, argv, input, 'clickhouse-local',
                            expected_sha: BINARY_SHA256, binary_path: @binary, store: store)
      rename_binary_stdin_sidecar!(label)
      record = result.fetch(:record)
      fail!("#{label} timed out or had process infrastructure failure") unless
        !record[:timed_out] && record[:spawn_error].nil? && record[:stdin_write_error].nil? &&
        record[:stdout_read_error].nil? && record[:stderr_read_error].nil? && result[:status] && result[:status].termsig.nil?
      fail!("#{label} RowBinary INSERT process was not successful: #{record.inspect}") unless
        result[:classification] == 'success' && result[:status].success?
      @runner.send(:assert_native_success!, result, label)
      fail!("#{label} must not emit server output") unless result.fetch(:stdout).empty?
      result
    end

    def rename_binary_stdin_sidecar!(label)
      base = File.join(@root, 'invocations')
      sql_name = "#{label}.stdin.sql"
      binary_name = "#{label}.stdin.bin"
      sql_path = File.join(base, sql_name)
      binary_path = File.join(base, binary_name)
      fail!("#{label} RowBinary stdin sidecar rename target already exists") if File.exist?(binary_path)
      File.rename(sql_path, binary_path)
      record = @invocations.find { |item| item.fetch(:label) == label }
      fail!("#{label} process capture record is missing") unless record && record.fetch(:stdin_file) == sql_name
      record[:stdin_file] = binary_name
      record[:stdin_encoding] = 'rowbinary'
      record_path = File.join(base, "#{label}.json")
      File.open(record_path, 'wb') { |file| file.write(JSON.pretty_generate(record) + "\n") }
    end

    def register_expected!(label, argv, input, kind, binary_path, expected_sha, store, stdin_encoding: nil)
      super(label, argv, input, kind, binary_path, expected_sha, store)
      encoding = stdin_encoding || (kind == 'clickhouse-local' ? 'sql' : 'bin')
      fail!("#{label} has an unsupported captured stdin encoding #{encoding.inspect}") unless %w[sql bin rowbinary].include?(encoding)
      @expected_processes.fetch(label)[:stdin_encoding] = encoding
    end

    def validate_process_evidence!
      fail!('process invocation roster differs from registered commands') unless
        @invocations.map { |item| item.fetch(:label) }.sort == @expected_processes.keys.sort
      expected_files = []
      @invocations.each do |record|
        label = record.fetch(:label)
        expected = @expected_processes.fetch(label)
        base = File.join(@root, 'invocations')
        argv_bytes = JSON.pretty_generate(expected.fetch(:argv)) + "\n"
        encoding = expected.fetch(:stdin_encoding)
        stdin_extension = encoding == 'rowbinary' ? 'bin' : encoding
        stdin_name = "#{label}.stdin.#{stdin_extension}"
        argv_name = "#{label}.argv.json"
        stdout_name = "#{label}.stdout"
        stderr_name = "#{label}.stderr"
        record_name = "#{label}.json"
        expected_files.concat([stdin_name, argv_name, stdout_name, stderr_name, record_name])
        fail!("#{label} captured sidecar names or stdin encoding differ") unless
          record.fetch(:stdin_file) == stdin_name && record.fetch(:argv_file) == argv_name &&
          record.fetch(:stdout_file) == stdout_name && record.fetch(:stderr_file) == stderr_name &&
          (encoding != 'rowbinary' || record.fetch(:stdin_encoding) == 'rowbinary')
        fail!("#{label} argv identity differs") unless record.fetch(:argv) == expected.fetch(:argv) &&
          File.binread(File.join(base, argv_name)) == argv_bytes && record.fetch(:argv_sha256) == Digest::SHA256.hexdigest(argv_bytes)
        stdin = File.binread(File.join(base, stdin_name))
        fail!("#{label} stdin identity differs") unless stdin == expected.fetch(:stdin) &&
          record.fetch(:stdin_bytes) == stdin.bytesize && record.fetch(:stdin_sha256) == Digest::SHA256.hexdigest(stdin)
        stdout = File.binread(File.join(base, stdout_name))
        stderr = File.binread(File.join(base, stderr_name))
        fail!("#{label} stdout/stderr sidecar identity differs") unless
          record.fetch(:stdout_bytes) == stdout.bytesize && record.fetch(:stdout_sha256) == Digest::SHA256.hexdigest(stdout) &&
          record.fetch(:stderr_bytes) == stderr.bytesize && record.fetch(:stderr_sha256) == Digest::SHA256.hexdigest(stderr)
        fail!("#{label} process status or binary identity differs") unless
          record.fetch(:label) == label && record.fetch(:process_kind) == expected.fetch(:process_kind) &&
          record.fetch(:binary_path) == expected.fetch(:binary_path) && record.fetch(:store_path) == expected.fetch(:store_path) &&
          record.fetch(:expected_binary_sha256) == expected.fetch(:expected_sha256) &&
          record.fetch(:binary_sha_before) == expected.fetch(:expected_sha256) &&
          record.fetch(:binary_sha_after) == expected.fetch(:expected_sha256) && record.fetch(:exit) == 0 &&
          record.fetch(:signal).nil? && !record.fetch(:timed_out) && record.fetch(:spawn_error).nil? &&
          record.fetch(:stdin_write_error).nil? && record.fetch(:stdout_read_error).nil? && record.fetch(:stderr_read_error).nil? &&
          record.fetch(:process_classification) == 'success' && stderr.empty?
        saved_record = JSON.parse(File.binread(File.join(base, record_name)))
        fail!("#{label} persisted process record differs") unless saved_record == JSON.parse(JSON.generate(record))
      end
      fail!('invocation sidecar directory has unexpected files') unless
        Dir.children(File.join(@root, 'invocations')).sort == expected_files.sort
      true
    end

    def inspect_native_part!(id, table, store, layout, mark_format, compression, mode)
      schema_tag = marker('schema', id)
      part_tag = marker('part', id)
      table_path_tag = marker('table_path', id)
      sql = "SELECT '#{schema_tag}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;\n" \
        "SELECT '#{part_tag}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;\n" \
        "SELECT '#{table_path_tag}', arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw;\n"
      result = native("#{id}_schema_part", store, sql)
      lines = native_lines(result, "#{id} schema/part")
      schema = tagged(lines, schema_tag, 3, id).map { |row| [row[1], row[2].gsub(/\s+/, '')] }
      expected_schema = schema_for(layout).map { |name, type| [name, type.gsub(/\s+/, '')] }
      fail!("#{id} native schema/type/order differs: #{schema.inspect}") unless schema == expected_schema
      part_rows = tagged(lines, part_tag, 7, id)
      fail!("#{id} is not one Compact eight-row part with four data marks plus EOF") unless part_rows.size == 1 &&
        part_rows.first.values_at(1, 2, 4, 5, 6) == [table, PART_NAME, 'Compact', ROW_COUNT.to_s, PHYSICAL_MARK_ROWS_WITH_EOF.size.to_s]
      table_paths = tagged(lines, table_path_tag, 2, id)
      fail!("#{id} table data path is not unique") unless table_paths.size == 1 && !table_paths.first[1].empty?
      table_path = safe_native_path(table_paths.first[1], store, "#{id} table")
      path = safe_native_path(part_rows.first.fetch(3), store, "#{id} part")
      fail!("#{id} native part path is not directly inside its table data path") unless File.dirname(path) == table_path
      selected_mark = mark_filename(mark_format, compression)
      fail!("#{id} expected mark file missing or wrong") unless File.file?(File.join(path, selected_mark))
      fail!("#{id} has an unexpected alternate mark file") if %w[data.mrk3 data.mrk4 data.cmrk3 data.cmrk4].any? { |name| name != selected_mark && File.exist?(File.join(path, name)) }
      inventory = tree_inventory(path)
      roster = native_callback_roster!(id, path, mark_format, layout)
      assert_stock_callback_roster!(id, roster, mark_format, layout)
      metadata = serialization_metadata!(id, path)
      snapshot = save_part_snapshot!(id, path, inventory, roster, metadata)
      fail!("#{id} stock part changed during snapshot capture") unless tree_inventory(path) == inventory
      {
        origin: 'independent fixed Ruby literal rows encoded as RowBinary into a fresh pinned ClickHouse stock table; no Crystal fixture/helper input',
        table: table, store: store, table_data_path: table_path, path: path, schema: schema, part_row: part_rows.first,
        shared_layout: layout, mark_format: mark_format, compression: compression, variant_mode: mode,
        mark_file: selected_mark, part_inventory: inventory, callback_roster: roster,
        serialization_metadata: metadata, evidence_snapshot: snapshot, schema_part_invocation: result.fetch(:record),
      }
    end

    def mark_filename(mark_format, compression)
      prefix = compression == 'compressed' ? 'data.cmrk' : 'data.mrk'
      "#{prefix}#{mark_format.delete_prefix('mrk')}"
    end

    def native_callback_roster!(id, part, mark_format, layout)
      selected_schema = schema_for(layout)
      if mark_format == 'mrk3'
        slots = selected_schema.each_with_index.map { |(column, _), index| [index, column, nil] }
        return {state: 'mrk3_single_unlabelled_slot_per_column', text: nil, sections: nil, roster: slots, sha256: nil}
      end
      path = File.join(part, 'columns_substreams.txt')
      fail!("#{id} MRK4 callback roster is missing, symlinked, or oversized") unless
        File.file?(path) && !File.symlink?(path) && File.size(path) <= MAX_RAW_FILE_BYTES
      text = File.binread(path).force_encoding(Encoding::UTF_8)
      lines = text.split("\n", -1)
      fail!("#{id} callback roster is not newline-terminated UTF-8") unless text.valid_encoding? && lines.pop == ''
      fail!("#{id} callback roster version differs") unless lines.shift == 'columns substreams version: 1'
      header = /\A(0|[1-9][0-9]*) columns:\z/.match(lines.shift.to_s)
      fail!("#{id} callback roster column count differs") unless header && header[1].to_i == selected_schema.size
      sections = []
      until lines.empty?
        match = /\A(0|[1-9][0-9]*) substreams for column `([a-z][a-z0-9_]*)`:\z/.match(lines.shift.to_s)
        fail!("#{id} malformed callback section") unless match
        count = Integer(match[1], 10)
        fail!("#{id} callback count exceeds fixed bound") unless count <= 512 && lines.size >= count
        streams = count.times.map do
          entry = /\A\t([A-Za-z0-9_.%]+)\z/.match(lines.shift.to_s)
          fail!("#{id} malformed physical callback name") unless entry
          entry[1]
        end
        fail!("#{id} duplicate callback within column") unless streams.uniq == streams
        sections << [match[2], streams]
      end
      fail!("#{id} callback columns differ from literal schema order") unless sections.map(&:first) == selected_schema.map(&:first)
      fail!("#{id} callback roster contains an empty serializer") unless sections.all? { |_name, streams| !streams.empty? }
      flattened = sections.flat_map { |column, streams| streams.map { |stream| [column, stream] } }
      {
        state: 'native_substream_callback_roster_observed', text: text, sections: sections,
        roster: flattened.each_with_index.map { |(column, stream), index| [index, column, stream] },
        sha256: Digest::SHA256.hexdigest(text),
      }
    end

    def assert_stock_callback_roster!(id, roster, mark_format, layout)
      expected_schema = schema_for(layout)
      if mark_format == 'mrk3'
        expected = expected_schema.each_with_index.map { |(column, _), index| [index, column, nil] }
        fail!("#{id} MRK3 roster is not one unlabelled slot per declared column") unless roster.fetch(:roster) == expected
      else
        sections = roster.fetch(:sections).to_h
        fail!("#{id} MRK4 callback columns differ from native declaration") unless sections.keys == expected_schema.map(&:first)
        fail!("#{id} ordinary root Dynamic callback roster is empty") if sections.fetch('root_dynamic_string').empty?
        fail!("#{id} tuple/Dynamic callback roster is empty") if sections.fetch('tuple_array_dynamic_string').empty?
        fail!("#{id} JSON callback roster is empty") if sections.fetch('json_root_string').empty?
        if layout == 'map'
          fail!("#{id} typed nested JSON callback roster is empty") if sections.fetch('typed_dynamic_depth2_array_json_string').empty?
        end
      end
      true
    end

    def serialization_metadata!(id, part)
      path = File.join(part, 'serialization.json')
      fail!("#{id} serialization metadata missing, symlinked, or oversized") unless
        File.file?(path) && !File.symlink?(path) && File.size(path) <= MAX_RAW_FILE_BYTES
      raw = File.binread(path)
      metadata = JSON.parse(raw)
      versions = metadata.fetch('types_serialization_versions')
      fail!("#{id} serialization metadata is not propagated String1") unless
        metadata.fetch('version') == 1 && versions.fetch('string') == 1 &&
        metadata.fetch('propagate_types_serialization_versions_to_nested_types') == true
      {
        raw: raw, raw_sha256: Digest::SHA256.hexdigest(raw), version: metadata.fetch('version'),
        types_serialization_versions: versions, string_version: versions.fetch('string'),
        propagate_types_serialization_versions_to_nested_types: metadata.fetch('propagate_types_serialization_versions_to_nested_types'),
        serializer_records: metadata.fetch('columns'),
      }
    rescue JSON::ParserError, KeyError => error
      fail!("#{id} serialization.json is malformed: #{error.message}")
    end

    def native_values_sql(table, id, layout, window)
      tag = marker('values', id, window)
      predicate = WINDOWS.fetch(window)
      if window == 'eof'
        return "SELECT '#{tag}', toString(count()) FROM default.#{table} WHERE #{predicate} FORMAT TSVRaw;\n"
      end
      root = 'root_dynamic_string'
      items = "tupleElement(tuple_array_dynamic_string, 'items')"
      root_json = 'json_root_string'
      root_payload = "#{root_json}.payload"
      child_json = 'typed_dynamic_depth2_array_json_string'
      child_payload = "#{child_json}.payload"
      item_tokens = "arrayMap(w277_x -> if(isNull(w277_x), 'NULL', concat(dynamicType(w277_x), ':', toString(toUInt8(isDynamicElementInSharedData(w277_x))), ':', if(dynamicType(w277_x) = 'String', lower(hex(dynamicElement(w277_x, 'String'))), toString(dynamicElement(w277_x, 'UInt16'))))), #{items})"
      fields = [
        "'#{tag}'", 'toString(pk)',
        "if(isNull(#{root}), 'None', dynamicType(#{root}))",
        "if(isNull(#{root}), 'false', if(isDynamicElementInSharedData(#{root}), 'true', 'false'))",
        "if(isNull(#{root}), '-', lower(hex(dynamicElement(#{root}, 'String'))))",
        "lower(hex(tupleElement(tuple_array_dynamic_string, 'label')))"
      ]
      fields << "hex(toJSONString(#{item_tokens}))"
      fields.concat([
        "toString(#{root_json}.id)", "lower(hex(#{root_json}.label))",
        "hex(toJSONString(JSONDynamicPaths(#{root_json})))", "hex(toJSONString(JSONSharedDataPaths(#{root_json})))",
        "if(isNull(#{root_payload}), 'None', dynamicType(#{root_payload}))",
        "if(isNull(#{root_payload}), 'false', if(isDynamicElementInSharedData(#{root_payload}), 'true', 'false'))",
        "if(isNull(#{root_payload}), '-', lower(hex(dynamicElement(#{root_payload}, 'String'))))",
        "lower(hex(#{root_json}.shared_text))",
      ])
      if layout == 'map'
        nested = "dynamicElement(#{child_payload}, #{sql_string(ARRAY_JSON_TYPE)})"
        nested_hex = "arrayMap(w277_outer -> arrayMap(w277_leaf -> lower(hex(w277_leaf.value)), w277_outer), #{nested})"
        fields.concat([
          "if(isNull(#{child_payload}), 'None', dynamicType(#{child_payload}))",
          "if(isNull(#{child_payload}), 'false', if(isDynamicElementInSharedData(#{child_payload}), 'true', 'false'))",
          "if(isNull(#{child_payload}), '-', hex(toJSONString(#{nested_hex})))",
        ])
      end
      where = predicate ? " WHERE #{predicate}" : ''
      "SELECT #{fields.join(', ')} FROM default.#{table}#{where} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;\n"
    end

    def native_values!(id, table, store, layout)
      sql = WINDOWS.keys.map { |window| native_values_sql(table, id, layout, window) }.join
      result = native("#{id}_values", store, sql)
      lines = native_lines(result, "#{id} exact native full/middle/EOF values")
      observations = {}
      WINDOWS.each_key do |window|
        tag = marker('values', id, window)
        if window == 'eof'
          rows = tagged(lines, tag, 2, "#{id}/#{window}")
          fail!("#{id} EOF query differs") unless rows == [[tag, '0']]
          observations[window] = {state: 'exact_values', rows: [], count: 0, raw_rows: rows}
          next
        end
        width = layout == 'map' ? 18 : 15
        rows = tagged(lines, tag, width, "#{id}/#{window}")
        actual = rows.map { |fields| parse_native_row(fields, layout, id, window) }
        expected = expected_native_rows(window, layout)
        fail!("#{id} #{window} native raw/type/profile/path signature differs: #{actual.inspect}") unless actual == expected
        observations[window] = {state: 'exact_values', rows: actual, raw_rows: rows}
      end
      {state: 'exact_values', windows: observations, invocation: result.fetch(:record)}
    end

    def parse_native_row(fields, layout, id, window)
      expected_width = layout == 'map' ? 18 : 15
      fail!("#{id}/#{window} native row width differs") unless fields.size == expected_width
      row = {
        pk: Integer(fields[1], 10),
        root_dynamic: [fields[2], native_bool(fields[3], "#{id}/#{window}/root shared flag"), normalized_hex(fields[4], "#{id}/#{window}/root String")],
        tuple_label_hex: normalized_hex(fields[5], "#{id}/#{window}/tuple label"),
        tuple_items: decode_hex_json(fields[6], "#{id}/#{window}/tuple Dynamic items"),
        json_id: Integer(fields[7], 10),
        json_label_hex: normalized_hex(fields[8], "#{id}/#{window}/JSON label"),
        json_dynamic_paths: decode_hex_json(fields[9], "#{id}/#{window}/JSON Dynamic paths"),
        json_shared_data_paths: decode_hex_json(fields[10], "#{id}/#{window}/JSON SharedData paths"),
        json_payload: [fields[11], native_bool(fields[12], "#{id}/#{window}/JSON payload shared flag"), normalized_hex(fields[13], "#{id}/#{window}/JSON payload")],
        json_shared_text_hex: normalized_hex(fields[14], "#{id}/#{window}/JSON shared String"),
      }
      if layout == 'map'
        type_name = fields[15] == 'None' ? 'None' : fields[15].gsub(/\s+/, '')
        row[:typed_dynamic_json] = [type_name, native_bool(fields[16], "#{id}/#{window}/nested JSON shared flag"), fields[17] == '-' ? nil : decode_hex_json(fields[17], "#{id}/#{window}/nested JSON String leaves")]
      end
      row
    rescue ArgumentError => error
      fail!("#{id}/#{window} malformed native exact row: #{error.message}")
    end

    def native_bool(value, label)
      case value
      when 'true' then true
      when 'false' then false
      else fail!("#{label} is not the exact native boolean token true/false")
      end
    end

    def normalized_hex(value, label)
      fail!("#{label} is not '-' or even-length hex") unless value == '-' || value.match?(/\A(?:[0-9a-fA-F]{2})*\z/)
      value == '-' ? '-' : value.downcase
    end

    def decode_hex_json(value, label)
      fail!("#{label} is not even-length hex JSON") unless value.match?(/\A(?:[0-9a-fA-F]{2})*\z/)
      JSON.parse([value].pack('H*'))
    rescue JSON::ParserError => error
      fail!("#{label} contains malformed JSON: #{error.message}")
    end

    def expected_native_rows(window, layout)
      selected = case window
                 when 'full' then ROWS
                 when 'middle' then ROWS[2, 4]
                 else fail!("unknown native value window #{window.inspect}")
                 end
      selected.map { |row| expected_native_row(row, layout) }
    end

    def expected_native_row(row, layout)
      root = row.fetch(:root)
      payload = row.fetch(:json_payload)
      tuple_items = row.fetch(:items).map do |kind, value|
        case kind
        when :null then 'NULL'
        when :uint16 then "UInt16:0:#{value}"
        when :string then "String:1:#{value.unpack1('H*')}"
        else fail!('native literal contains an unsupported Dynamic type')
        end
      end
      expected = {
        pk: row.fetch(:pk),
        root_dynamic: [root.nil? ? 'None' : 'String', false, root.nil? ? '-' : root.unpack1('H*')],
        tuple_label_hex: format('row%02d', row.fetch(:pk) - 1).b.unpack1('H*'),
        tuple_items: tuple_items,
        json_id: row.fetch(:pk),
        json_label_hex: row.fetch(:json_label).unpack1('H*'),
        # JSONDynamicPaths is a row-value observation. The binary literal omits
        # `payload` entirely when json_payload is nil; physical part topology is
        # checked separately by the callback-roster oracle.
        json_dynamic_paths: payload.nil? ? [] : ['payload'],
        json_shared_data_paths: ['shared_text'],
        json_payload: [payload.nil? ? 'None' : 'String', false, payload.nil? ? '-' : payload.unpack1('H*')],
        json_shared_text_hex: row.fetch(:shared_text).unpack1('H*'),
      }
      if layout == 'map'
        nested = row.fetch(:nested_json)
        expected[:typed_dynamic_json] = [nested.nil? ? 'None' : ARRAY_JSON_TYPE.gsub(/\s+/, ''), false,
                                         nested.nil? ? nil : nested.map { |group| group.map { |value| value.unpack1('H*') } }]
      end
      expected
    end

    def capture_stock_local_reads!(id, stock)
      layout = stock.fetch(:shared_layout)
      part = stock.fetch(:path)
      audit = helper("#{id}_helper_audit", 'audit', part, layout)
      validate_helper_report!(audit, id, 'audit', 0, DATA_MARK_COUNT, stock)
      middle = helper("#{id}_helper_middle", 'read', part, layout, 'all', '1', '2')
      validate_helper_report!(middle, id, 'read', 1, 2, stock)
      eof = helper("#{id}_helper_eof", 'read', part, layout, 'all', '4', '0')
      validate_helper_report!(eof, id, 'read', 4, 0, stock)
      stock[:local_reader] = {audit: audit, middle: middle, eof: eof,
                              claim: 'Crystal typed reads match independent Ruby literals and the exact captured stock inventory'}
      stock
    end

    def validate_helper_report!(report, id, action, first_mark, mark_count, stock, candidate_mark: nil)
      fail!("#{id} helper report format/action/status differs") unless
        report.fetch('format') == HELPER_FORMAT && report.fetch('action') == action && report.fetch('status') == 'ok'
      fail!("#{id} helper layout/window differs") unless report.fetch('shared_layout') == stock.fetch(:shared_layout) &&
        report.fetch('first_mark') == first_mark && report.fetch('selected_mark_count') == mark_count
      fail!("#{id} helper row/mark metadata differs") unless report.fetch('row_count') == ROW_COUNT &&
        report.fetch('data_mark_count') == DATA_MARK_COUNT && report.fetch('mark_row_counts') == WRITER_MARK_ROWS
      fail!("#{id} helper metadata is not propagated String1") unless
        report.dig('serialization_metadata', 'version') == 1 && report.dig('serialization_metadata', 'string_version') == 1 &&
        report.dig('serialization_metadata', 'propagate_types_serialization_versions_to_nested_types') == true
      first_row = first_mark * ROWS_PER_MARK
      finish_row = (first_mark + mark_count) * ROWS_PER_MARK
      selected_keys = (first_row...finish_row).map { |index| index + 1 }
      fail!("#{id} helper key values differ") unless report.fetch('keys') == selected_keys
      columns = report.fetch('columns')
      names = VALUE_COLUMNS.fetch(stock.fetch(:shared_layout))
      fail!("#{id} helper column roster differs") unless columns.map { |column| column.fetch('name') } == names
      columns.each do |column|
        name = column.fetch('name')
        fail!("#{id}/#{name} helper declaration differs") unless column.fetch('type').gsub(/\s+/, '') == DYNAMIC_TYPE_NAMES.fetch(name).gsub(/\s+/, '')
        fail!("#{id}/#{name} profile differs") unless column.fetch('profile') == 'with_size_stream'
        signatures = HELPER_SIGNATURES.fetch(name).drop(first_mark * ROWS_PER_MARK).take(mark_count * ROWS_PER_MARK)
        fail!("#{id}/#{name} helper signature differs from independent literal oracle") unless column.fetch('signatures') == signatures
        fail!("#{id}/#{name} helper data-mark grid differs") unless column.fetch('mark_row_counts') == WRITER_MARK_ROWS
      end
      roster = normalize_helper_roster(report.fetch('physical_roster'))
      if candidate_mark
        expected = stock.fetch(:callback_roster).fetch(:roster)
        fail!("#{id} generated helper callback roster differs from native stock") unless roster == expected
      else
        fail!("#{id} stock local helper callback roster differs from native stock") unless roster == stock.fetch(:callback_roster).fetch(:roster)
      end
      if action == 'audit' && candidate_mark.nil?
        observed = report.fetch('files').map { |file| [file.fetch('path'), file.fetch('size'), file.fetch('sha256')] }.sort
        expected = stock.fetch(:part_inventory).fetch(:files).map { |file| [file.fetch(:path), file.fetch(:size), file.fetch(:sha256)] }.sort
        fail!("#{id} stock helper inventory differs from pre-ATTACH raw capture") unless observed == expected
      end
      report
    end

    def normalize_helper_roster(roster)
      fail!('helper physical roster is malformed') unless roster.is_a?(Array)
      roster.each_with_index.map do |slot, index|
        fail!('helper physical roster indices are not globally contiguous') unless slot.fetch('index') == index
        [index, slot.fetch('column'), slot['stream']]
      end
    end

    def capture_generated!(id, layout, mark_format, compression, mode)
      part = File.join(@root, 'parts', id, PART_NAME)
      Dir.mkdir(File.dirname(part), 0o700)
      write = helper("#{id}_writer", 'write', part, mark_format, compression, mode, layout)
      fail!("#{id} helper writer request/report differs") unless write.fetch('format') == HELPER_FORMAT &&
        write.fetch('action') == 'write' && write.fetch('status') == 'ok' && write.fetch('part_path') == part &&
        write.fetch('shared_layout') == layout && write.fetch('requested_mark_format') == mark_format &&
        write.fetch('mark_format') == mark_format && write.fetch('requested_compression') == compression &&
        write.fetch('requested_mode') == mode
      inventory = tree_inventory(part)
      helper_files = write.fetch('files').map { |file| [file.fetch('path'), file.fetch('size'), file.fetch('sha256')] }.sort
      fail!("#{id} helper writer file inventory differs") unless helper_files == inventory.fetch(:files).map { |file| [file.fetch(:path), file.fetch(:size), file.fetch(:sha256)] }.sort
      stock = @stock.fetch(cell_id('stock', layout, mark_format, compression, mode))
      snapshot = save_part_snapshot!(id, part, inventory, stock.fetch(:callback_roster), write.fetch('serialization_metadata'))
      validate_helper_report!(write, id, 'write', 0, DATA_MARK_COUNT,
                              {shared_layout: layout, callback_roster: stock.fetch(:callback_roster)}, candidate_mark: mark_format)
      middle = helper("#{id}_helper_middle", 'read', part, layout, 'all', '1', '2')
      validate_helper_report!(middle, id, 'read', 1, 2,
                              {shared_layout: layout, callback_roster: stock.fetch(:callback_roster)}, candidate_mark: mark_format)
      eof = helper("#{id}_helper_eof", 'read', part, layout, 'all', '4', '0')
      validate_helper_report!(eof, id, 'read', 4, 0,
                              {shared_layout: layout, callback_roster: stock.fetch(:callback_roster)}, candidate_mark: mark_format)
      target = create_target!(id, layout, mark_format, compression, mode)
      attached = attach_candidate!(id, part, inventory, target)
      check = check!("#{id}_attached", target.fetch(:table), target.fetch(:store))
      active = inspect_attached_part!(id, target.fetch(:table), target.fetch(:store), layout,
                                      mark_format, compression, mode, inventory)
      native_values = native_values!("#{id}_attached", target.fetch(:table), target.fetch(:store), layout)
      fail!("#{id} native attached literal windows differ") unless native_values.fetch(:state) == 'exact_values'
      fail!("#{id} source candidate changed during ATTACH/CHECK/read") unless tree_inventory(part) == inventory
      {
        origin: 'Crystal-generated Compact part; local full/middle/EOF read; copied to detached; native ATTACH/CHECK/full/middle/EOF read',
        part_path: part, shared_layout: layout, mark_format: mark_format, compression: compression, variant_mode: mode,
        helper_write: write, helper_middle: middle, helper_eof: eof, part_inventory: inventory, evidence_snapshot: snapshot,
        native_target: target, attach: attached, native_check: check, active_part: active, native_values: native_values,
      }
    end

    def create_target!(id, layout, mark_format, compression, mode)
      table = table_name("target_#{id}")
      store = store_path("target_#{id}")
      path_tag = marker('target_path', id)
      schema_tag = marker('target_schema', id)
      sql = create_sql(table, layout, mark_format, compression, mode) +
        "SELECT '#{schema_tag}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;\n" \
        "SELECT '#{path_tag}', arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw;\n"
      result = native("#{id}_target_create", store, sql)
      lines = native_lines(result, "#{id} target creation")
      schema = tagged(lines, schema_tag, 3, id).map { |row| [row[1], row[2].gsub(/\s+/, '')] }
      expected = schema_for(layout).map { |name, type| [name, type.gsub(/\s+/, '')] }
      fail!("#{id} detached target schema differs") unless schema == expected
      paths = tagged(lines, path_tag, 2, id)
      fail!("#{id} target path is not unique") unless paths.size == 1 && !paths.first[1].empty?
      path = File.expand_path(paths.first[1])
      fail!("#{id} target path escaped isolated store") unless path.start_with?(File.realpath(store) + File::SEPARATOR)
      fail!("#{id} target data path is not canonical and non-symlinked") unless
        File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path
      {table: table, store: store, data_path: path, create: result.fetch(:record)}
    end

    def attach_candidate!(id, part, inventory, target)
      @runner.send(:attach_part!, part, target.fetch(:data_path))
      detached = File.join(target.fetch(:data_path), 'detached', PART_NAME)
      fail!("#{id} detached candidate inventory differs") unless tree_inventory(detached) == inventory
      result = native("#{id}_attach", target.fetch(:store), "ALTER TABLE default.#{target.fetch(:table)} ATTACH PART '#{PART_NAME}';\n")
      {state: 'attached', invocation: result.fetch(:record), source_inventory: inventory, detached_inventory: inventory}
    end

    def inspect_attached_part!(id, table, store, layout, mark_format, compression, mode, source_inventory)
      schema_tag = marker('active_schema', id)
      part_tag = marker('active_part', id)
      table_path_tag = marker('active_table_path', id)
      sql = "SELECT '#{schema_tag}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;\n" \
        "SELECT '#{part_tag}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;\n" \
        "SELECT '#{table_path_tag}', arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw;\n"
      result = native("#{id}_active_part", store, sql)
      lines = native_lines(result, "#{id} attached active part")
      schema = tagged(lines, schema_tag, 3, id).map { |row| [row[1], row[2].gsub(/\s+/, '')] }
      expected_schema = schema_for(layout).map { |name, type| [name, type.gsub(/\s+/, '')] }
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
      roster = native_callback_roster!(id, part_path, mark_format, layout)
      assert_stock_callback_roster!(id, roster, mark_format, layout)
      metadata = serialization_metadata!(id, part_path)
      fail!("#{id} attached callback roster differs from stock reference") unless roster.fetch(:roster) == @stock.fetch(cell_id('stock', layout, mark_format, compression, mode)).fetch(:callback_roster).fetch(:roster)
      {part_row: parts.first, table_data_path: table_path, path: part_path, schema: schema,
       inventory: attached.fetch(:inventory), native_owned_sidecar: attached.fetch(:native_owned_sidecar),
       callback_roster: roster, serialization_metadata: metadata, invocation: result.fetch(:record)}
    end

    def build_summary
      status = @stock_only ? 'stock_native_matrix_exact' : 'stock_first_native_and_generated_matrix_exact'
      {
        format: FORMAT, status: status,
        execution_order: '16 independent stock/native cells: version/build-pinned CREATE, exact RowBinary INSERT argv/stdin capture, then literal value/path/metadata/roster/CHECK assertions; optional local stock reads follow; then 16 generated cells and detached native ATTACH/CHECK/value windows',
        runtime_pin: {binary: @binary, expected_sha256: BINARY_SHA256, sha256_before: @binary_sha_before,
                      sha256_after: @binary_sha_after, version: VERSION, build: BUILD,
                      distinction: 'runtime executable SHA/version/build are pinned independently from upstream source revision and hashes'},
        source_pin: {root: @source_root, revision: SOURCE_REVISION, sha256: @upstream_hashes, guards: @source_guard},
        helper_pin: @full_matrix ? {path: @helper, sha256: @helper_sha_after} : nil,
        probe_sources: @probe_hashes_after,
        fixture: {
          schemas: SCHEMAS, row_count: ROW_COUNT, rows_per_mark: ROWS_PER_MARK, data_marks: DATA_MARK_COUNT,
          stock_native_mark_rows_with_eof: PHYSICAL_MARK_ROWS_WITH_EOF,
          generated_data_mark_rows: WRITER_MARK_ROWS, generated_physical_mark_rows_with_eof: PHYSICAL_MARK_ROWS_WITH_EOF,
          keys: ROWS.map { |row| row.fetch(:pk) }, middle_keys: ROWS[2, 4].map { |row| row.fetch(:pk) },
          native_literal_rows: literal_summary_rows,
          native_windows: WINDOWS, physical_windows: PHYSICAL_WINDOWS,
          logical_value_encoding: 'String values are reported as lowercase byte hex; Dynamic type/shared placement is explicit; JSON Dynamic/SharedData path rosters are separate; nested JSON leaves are exact byte-hex arrays; NULL and empty arrays remain distinct',
        },
        matrix: {shared_layouts: LAYOUTS, mark_formats: MARK_FORMATS, mark_compression: MARK_COMPRESSION,
                 variant_modes: VARIANT_MODES, string_profile: 'String1/with_size_stream', propagation: true,
                 stock_cells: @stock.keys, generated_cells: @generated.keys},
        stock: @stock, generated: @generated, invocations: @invocations, evidence_root: @root,
        claim_boundary: 'Finite eight-row/four-data-mark witness for ordinary String-bearing Dynamic/JSON contexts under MAP0 and admitted root MAP_WITH_BUCKETS layouts, MRK3/MRK4, plain/compressed marks, BASIC/COMPACT shared-Variant discriminators. Stock exact values, dynamic types/shared flags, JSON DynamicPaths/SharedDataPaths, String1 metadata and callback rosters are required before optional Crystal work. Full mode additionally checks local typed reads, generated inventory, native ATTACH/CHECK and full/middle/EOF values. This does not qualify ADVANCED/CHUNKED shared contexts, unsupported JSON child/layout intersections, arbitrary types, input paths, settings or all recursive codecs.',
      }
    end

    def literal_summary_rows
      ROWS.map do |row|
        {pk: row.fetch(:pk), root_dynamic_hex: row.fetch(:root)&.unpack1('H*'),
         tuple_label: format('row%02d', row.fetch(:pk) - 1), tuple_items: row.fetch(:items).map { |kind, value| [kind, value.is_a?(String) ? value.unpack1('H*') : value] },
         json_id: row.fetch(:pk), json_label_hex: row.fetch(:json_label).unpack1('H*'),
         json_payload_hex: row.fetch(:json_payload)&.unpack1('H*'), json_shared_text_hex: row.fetch(:shared_text).unpack1('H*'),
         typed_dynamic_nested_json_leaf_hex: row.fetch(:nested_json)&.map { |group| group.map { |value| value.unpack1('H*') } }}
      end
    end

    def render_summary(summary)
      lines = [
        '# W277 Compact context-owned propagated String1 native matrix', '',
        "Status: `#{summary.fetch(:status)}`",
        "Runtime: `#{VERSION}` build `#{BUILD}` SHA-256 `#{BINARY_SHA256}`.",
        "Source: `#{SOURCE_REVISION}` at `#{SOURCE_ROOT}` (independent pin).",
        'Every native part has eight rows, four two-row data marks, and a fifth zero-row EOF mark. Native rows are independent fixed Ruby literals encoded as RowBinary, not helper output; each INSERT has an exact query in argv and a captured `.stdin.bin` payload. Version/build is observed in the immediately preceding `_create`; each RowBinary process separately records executable SHA-256 before/after.',
      ]
      @stock.each do |id, entry|
        values = entry.fetch(:native_values).fetch(:windows)
        lines << "- #{id}: Compact/CHECK healthy, MAP layout `#{entry.fetch(:shared_layout)}`, String1 metadata and native callbacks captured; full/middle/EOF `#{values.values.map { |item| item.fetch(:state) }.join('/')}`."
      end
      unless @stock_only
        @generated.each do |id, entry|
          lines << "- #{id}: local full/middle/EOF reads, pre-ATTACH inventory, detached copy, native ATTACH/CHECK and exact values; active part `#{entry.fetch(:active_part).fetch(:part_row)[4]}`."
        end
      end
      lines.concat(['', summary.fetch(:claim_boundary), ''])
      lines.join("\n")
    end

    def persist_inconclusive(error)
      return unless @root && File.directory?(File.join(@root, 'invocations'))
      report = {
        format: FORMAT, status: 'inconclusive', fatal_error: @fatal_error, error_class: error.class.name,
        runtime_pin: {binary: @binary, expected_sha256: BINARY_SHA256, observed_sha256: (sha(@binary) rescue nil)},
        source_pin: {root: @source_root, expected_revision: SOURCE_REVISION},
        helper_pin: @full_matrix ? {path: @helper, expected_sha256: @helper_expected_sha, observed_sha256: (sha(@helper) rescue nil)} : nil,
        invocations: @invocations, stock: @stock, generated: @generated, evidence_root: @root,
        claim_boundary: 'A native admission/type/value/path/metadata/CHECK mismatch or process/pin mismatch is inconclusive, never a positive String1 compatibility conclusion.',
      }
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(report) + "\n") unless File.exist?(File.join(@root, 'summary.json'))
    rescue StandardError
      nil
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  options = {
    binary: ProbeCompactContextStringWriterW277::BINARY,
    source_root: ProbeCompactContextStringWriterW277::SOURCE_ROOT,
    evidence_root: nil, stock_only: false, full_matrix: false, helper: nil, helper_sha256: nil,
  }
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/probe_compact_context_string_writer_w277.rb (--stock-only | --full-matrix --helper PREBUILT --helper-sha256 SHA256) --evidence-root EMPTY_DIR [--binary PINNED_CLICKHOUSE] [--source-root PINNED_UPSTREAM]'
    parser.on('--stock-only', 'Run all 16 independent stock/native cells; never starts the Crystal helper') { options[:stock_only] = true }
    parser.on('--full-matrix', 'Run 16 stock cells first, then local stock reads and 16 generated/native ATTACH/CHECK cells') { options[:full_matrix] = true }
    parser.on('--helper PATH', 'Prebuilt W277 Crystal helper; required only with --full-matrix') { |value| options[:helper] = value }
    parser.on('--helper-sha256 SHA256', 'Exact lowercase SHA-256 for the prebuilt helper') { |value| options[:helper_sha256] = value }
    parser.on('--evidence-root EMPTY_DIR', 'Existing empty direct child of /private/tmp') { |value| options[:evidence_root] = value }
    parser.on('--binary PATH', 'Pinned ClickHouse runtime executable; distinct from source checkout') { |value| options[:binary] = value }
    parser.on('--source-root PATH', 'Separately pinned upstream ClickHouse checkout') { |value| options[:source_root] = value }
  end.parse!

  unless options[:stock_only] != options[:full_matrix] && options[:evidence_root]
    warn 'W277: select exactly one of --stock-only or --full-matrix and provide --evidence-root'
    exit 2
  end
  if options[:stock_only] && (options[:helper] || options[:helper_sha256])
    warn 'W277: --helper and --helper-sha256 are valid only with --full-matrix'
    exit 2
  end
  if options[:full_matrix] && (!options[:helper] || !options[:helper_sha256])
    warn 'W277: --full-matrix requires --helper and --helper-sha256'
    exit 2
  end
  probe = ProbeCompactContextStringWriterW277::Probe.new(**options)
  exit(probe.run ? 0 : 1)
end
