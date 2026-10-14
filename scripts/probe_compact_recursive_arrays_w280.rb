#!/usr/bin/env ruby
# Stock-first native falsifier for Compact JSON beneath independently empty
# sibling Array paths in a named Tuple. Inputs and the row-domain oracle are
# fixed here and are never read from the Crystal fixtures or helpers.

require 'digest'
require 'find'
require 'json'
require 'open3'
require 'optparse'
require_relative 'probe_compact_child_json_writer_w279'

module ProbeCompactRecursiveArraysW280
  W279 = ProbeCompactChildJsonWriterW279
  W278 = W279::W278
  W277 = W279::W277
  W276 = W279::W276
  W241 = W279::W241

  FORMAT = 'compact_recursive_arrays_w280_stock_probe_v1'.freeze
  CONCLUSIVE_STATUSES = %w[
    main_and_control_exact_native_values
    main_stock_create_rejection_control_exact
    main_insert_server_exception_control_exact
  ].freeze
  PROBE_SOURCE = File.expand_path(__FILE__).freeze
  PROBE_SOURCES = [
    PROBE_SOURCE, W279::PROBE_SOURCE, W278::PROBE_SOURCE, W277::PROBE_SOURCE,
    W276::PROBE_SOURCE, W276::W241_SOURCE, W276::W271_SOURCE,
    W276::W273_SOURCE, W276::W264_SOURCE,
  ].uniq.freeze

  # The executable and upstream checkout are separate, independently pinned
  # inputs. These intentionally do not inherit W279's older defaults.
  BINARY = '/private/tmp/crystal-click-w263-runtime-recovery.B9uAPX/clickhouse-stripped'.freeze
  BINARY_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  VERSION = '26.10.1.1201'.freeze
  BUILD = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  SOURCE_ROOT = '/private/tmp/clickhouse-w254-upstream.AqeqyC'.freeze
  SOURCE_REVISION = 'ed30948f095ecb70679986d7d60e27ad770ae27a'.freeze
  SOURCE_FILES = W279::SOURCE_FILES

  PART_NAME = W277::PART_NAME
  ROW_COUNT = 8
  ROWS_PER_MARK = 2
  DATA_MARK_COUNT = 4
  PHYSICAL_MARK_ROWS_WITH_EOF = [2, 2, 2, 2, 0].freeze
  WINDOWS = {
    'full' => nil,
    'middle' => 'pk BETWEEN 3 AND 6',
    'eof' => 'pk > 8',
  }.freeze
  PHYSICAL_WINDOWS = {'full' => [0, 4], 'middle' => [1, 2], 'eof' => [4, 0]}.freeze

  JSON_TYPE = 'JSON(max_dynamic_types=1,max_dynamic_paths=0,id UInt64,state Dynamic(max_types=1))'.freeze
  MAIN_TYPE = "Tuple(left Array(#{JSON_TYPE}),right Array(#{JSON_TYPE}))".freeze
  CONTROL_TYPE = "Array(#{JSON_TYPE})".freeze
  SCHEMAS = {
    'main' => [['pk', 'UInt64'], ['json_pair', MAIN_TYPE]].map(&:freeze).freeze,
    'array_control' => [['pk', 'UInt64'], ['json_array', CONTROL_TYPE]].map(&:freeze).freeze,
  }.freeze

  # `state` is a typed Dynamic path. The input corpus preserves missing,
  # explicit-null, and empty-String encodings; the native value oracle does not
  # assume missing and explicit NULL remain distinguishable after ingestion.
  # Unique typed ids make every JSON occurrence observable across both arrays.
  STATES = %i[missing null empty].freeze
  MAIN_ROWS = [
    {left: [{id: 1101, state: :missing}, {id: 1102, state: :null}, {id: 1103, state: :empty}], right: []},
    {left: [], right: [{id: 2201, state: :missing}]},
    {left: [{id: 1301, state: :null}], right: []},
    {left: [], right: [{id: 2401, state: :empty}, {id: 2402, state: :null}]},
    {left: [{id: 1501, state: :empty}, {id: 1502, state: :missing}], right: []},
    {left: [], right: [{id: 2601, state: :null}, {id: 2602, state: :empty}]},
    {left: [{id: 1701, state: :missing}], right: []},
    {left: [], right: [{id: 2801, state: :missing}, {id: 2802, state: :null}, {id: 2803, state: :empty}]},
  ].map(&:freeze).freeze
  CONTROL_ROWS = [
    {id: 3001, state: :missing}, {id: 3002, state: :null},
    {id: 3003, state: :empty}, {id: 3004, state: :missing},
    {id: 3005, state: :null}, {id: 3006, state: :empty},
    {id: 3007, state: :missing}, {id: 3008, state: :empty},
  ].map(&:freeze).freeze

  MARK_CASES = %w[mrk3 mrk4].freeze
  ARRAY_CASE = 'array_control'.freeze
  MEMORY_LIMIT = W241::MEMORY
  MAX_RAW_FILE_BYTES = W277::MAX_RAW_FILE_BYTES
  MAX_PART_FILES = W277::MAX_PART_FILES
  MAX_PART_BYTES = W277::MAX_PART_BYTES
  MAX_REPORT_BYTES = W277::MAX_REPORT_BYTES

  class Failure < StandardError; end

  class Probe < W279::Probe
    def initialize(binary:, source_root:, evidence_root:)
      @binary = send(:validate_executable, binary, 'pinned ClickHouse runtime')
      @source_root = File.expand_path(source_root)
      fail!('source root differs from the separately pinned upstream checkout') unless @source_root == SOURCE_ROOT
      @root = send(:validate_root, evidence_root)
      @token = Digest::SHA256.hexdigest(@root)[0, 8]
      @invocations = []
      @expected_processes = {}
      @runner = W241::Probe.allocate
      @runner.instance_variable_set(:@binary, @binary)
      @runner.instance_variable_set(:@root, @root)
      @runner.instance_variable_set(:@invocations, @invocations)
      @cases = {}
      validate_literals!
    end

    def run
      prepare!
      MARK_CASES.each do |mark|
        [
          ["main_#{mark}", 'main', mark],
          ["array_control_#{mark}", ARRAY_CASE, mark],
        ].each do |id, kind, selected_mark|
          begin
            @cases[id] = capture_case!(id, kind, selected_mark)
          rescue StandardError => error
            @cases[id] = {case_id: id, schema_kind: kind, mark_format: selected_mark,
                          status: 'probe_error', error: "#{error.class}: #{error.message}"}
          end
        end
      end
      validate_process_evidence!
      validate_pins!
      summary = build_summary
      send(:write_new, File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      send(:write_new, File.join(@root, 'summary.md'), render_summary(summary))
      puts "W280 status=#{summary.fetch(:status)}; cases=#{@cases.size}; invocations=#{@invocations.size}; evidence=#{@root}"
      CONCLUSIVE_STATUSES.include?(summary.fetch(:status))
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      persist_inconclusive(error)
      warn "W280 probe inconclusive: #{@fatal_error}"
      false
    end

    private

    def fail!(message)
      raise Failure, "W280: #{message}"
    end

    def validate_literals!
      fail!('main and array-control literals must each contain eight rows and four two-row marks') unless
        MAIN_ROWS.size == ROW_COUNT && CONTROL_ROWS.size == ROW_COUNT &&
        MAIN_ROWS.each_slice(ROWS_PER_MARK).to_a.size == DATA_MARK_COUNT
      fail!('main branches must alternate independently between populated and empty') unless
        MAIN_ROWS.each_with_index.all? do |row, index|
          (index.even? && !row.fetch(:left).empty? && row.fetch(:right).empty?) ||
            (index.odd? && row.fetch(:left).empty? && !row.fetch(:right).empty?)
        end
      fail!('literal corpus must distinguish missing, explicit null, and empty String') unless
        (MAIN_ROWS.flat_map { |row| row.fetch(:left) + row.fetch(:right) }.map { |doc| doc.fetch(:state) } +
          CONTROL_ROWS.map { |doc| doc.fetch(:state) }).uniq.sort == STATES.sort
      fail!('stock schema must retain the named Tuple(Array(JSON), Array(JSON)) target and one-Array control') unless
        SCHEMAS.fetch('main').last.last == MAIN_TYPE && SCHEMAS.fetch(ARRAY_CASE).last.last == CONTROL_TYPE
      true
    end

    def prepare!
      %w[invocations stores source-inventories raw-records parts].each do |name|
        Dir.mkdir(File.join(@root, name), 0o700)
      end
      @binary_sha_before = sha(@binary)
      fail!('ClickHouse executable differs from its W280 runtime SHA-256') unless @binary_sha_before == BINARY_SHA256
      revision, stderr, status = Open3.capture3('git', '-C', @source_root, 'rev-parse', 'HEAD')
      fail!("pinned upstream revision check failed: #{stderr.strip}") unless status.success? && revision.strip == SOURCE_REVISION
      @source_revision_before = revision.strip
      @upstream_hashes_before = SOURCE_FILES.to_h do |relative|
        path = File.join(@source_root, relative)
        fail!("pinned upstream source is missing or symlinked: #{relative}") unless File.file?(path) && !File.symlink?(path)
        [relative, sha(path)]
      end
      @probe_hashes_before = PROBE_SOURCES.map { |path| File.realpath(path) }.uniq.sort.to_h do |path|
        [path, sha(path)]
      end
    end

    def validate_pins!
      @binary_sha_after = sha(@binary)
      fail!('ClickHouse executable changed during capture') unless @binary_sha_after == BINARY_SHA256
      revision, stderr, status = Open3.capture3('git', '-C', @source_root, 'rev-parse', 'HEAD')
      fail!("pinned upstream revision recheck failed: #{stderr.strip}") unless status.success?
      @source_revision_after = revision.strip
      fail!('pinned upstream revision changed during capture') unless @source_revision_after == SOURCE_REVISION
      @upstream_hashes_after = SOURCE_FILES.to_h do |relative|
        path = File.join(@source_root, relative)
        fail!("pinned upstream source disappeared or became symlinked: #{relative}") unless File.file?(path) && !File.symlink?(path)
        [relative, sha(path)]
      end
      fail!('pinned upstream source bytes changed during capture') unless @upstream_hashes_after == @upstream_hashes_before
      @probe_hashes_after = @probe_hashes_before.keys.to_h { |path| [path, sha(path)] }
      fail!('W280 or inherited probe source changed during capture') unless @probe_hashes_after == @probe_hashes_before
    end

    def sha(path)
      Digest::SHA256.file(path).hexdigest
    end

    def table_name(id)
      "w280_#{@token}_#{id}"
    end

    def schema_for(kind)
      SCHEMAS.fetch(kind) { fail!("unknown schema kind #{kind.inspect}") }
    end

    def settings(mark_format)
      substream_marks = mark_format == 'mrk4' ? 1 : 0
      [
        'index_granularity=2', 'index_granularity_bytes=10485760', 'enable_mixed_granularity_parts=1',
        'min_rows_for_wide_part=1000000', 'min_bytes_for_wide_part=104857600', 'min_level_for_wide_part=0',
        'compress_marks=0', "marks_compression_codec='LZ4'", 'compress_primary_key=0', 'write_final_mark=1',
        "write_marks_for_substreams_in_compact_parts=#{substream_marks}",
        'min_compress_block_size=0', 'max_compress_block_size=4096',
        'ratio_of_defaults_for_sparse_serialization=1.0', "default_compression_codec='LZ4'",
        "serialization_info_version='with_types'", 'propagate_types_serialization_versions_to_nested_types=true',
        "string_serialization_version='single_stream'", "object_serialization_version='v3'",
        "object_shared_data_serialization_version='map'",
        "object_shared_data_serialization_version_for_zero_level_parts='map'",
        'object_shared_data_buckets_for_compact_part=1', 'object_shared_data_target_chunk_rows=1',
        "dynamic_serialization_version='v3'", 'use_compact_variant_discriminators_serialization=0',
        'allow_suspicious_low_cardinality_types=1',
      ].join(', ')
    end

    def pin_sql
      "SELECT '__W280_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;\n"
    end

    def create_sql(table, kind, mark_format)
      declarations = schema_for(kind).map { |name, type| "`#{name}` #{type}" }.join(', ')
      "SET flatten_nested=0;\nSET allow_suspicious_low_cardinality_types=1;\nSET use_variant_as_common_type=1;\n" \
        "CREATE TABLE default.#{table} (#{declarations}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings(mark_format)};\n"
    end

    def rowbinary_var_uint(value)
      fail!('RowBinary VarUInt must be a non-negative integer') unless value.is_a?(Integer) && value >= 0
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

    def rowbinary_state(state)
      case state
      when :null then "\x00".b
      when :empty then "\x15".b + rowbinary_string(''.b)
      else fail!("state #{state.inspect} has no Dynamic encoding")
      end
    end

    def rowbinary_json(document)
      state = document.fetch(:state)
      fail!("unknown JSON state #{state.inspect}") unless STATES.include?(state)
      paths = [['id', [Integer(document.fetch(:id))].pack('Q<').b]]
      paths << ['state', rowbinary_state(state)] unless state == :missing
      rowbinary_var_uint(paths.size) + paths.map { |path, bytes| rowbinary_string(path) + bytes }.join.b
    end

    # Small generic RowBinary encoder. The same Array/Tuple/JSON recursion can
    # carry the later nested Array(Tuple(...)) basis without using a fixture.
    TypeDef = Struct.new(:kind, :child, :fields, keyword_init: true)
    JSON_VALUE = TypeDef.new(kind: :json).freeze
    UINT64_VALUE = TypeDef.new(kind: :uint64).freeze
    MAIN_VALUE = TypeDef.new(kind: :tuple, fields: [
      [:left, TypeDef.new(kind: :array, child: JSON_VALUE).freeze],
      [:right, TypeDef.new(kind: :array, child: JSON_VALUE).freeze],
    ].freeze).freeze
    CONTROL_VALUE = TypeDef.new(kind: :array, child: JSON_VALUE).freeze

    def encode_value(type, value)
      case type.kind
      when :uint64
        [Integer(value)].pack('Q<').b
      when :uint8
        [Integer(value)].pack('C').b
      when :json
        rowbinary_json(value)
      when :array
        rowbinary_var_uint(value.size) + value.map { |child| encode_value(type.child, child) }.join.b
      when :tuple
        type.fields.map do |name, field_type|
          child = value.is_a?(Hash) ? value.fetch(name) : value.fetch(type.fields.index { |entry| entry.first == name })
          encode_value(field_type, child)
        end.join.b
      else
        fail!("unsupported RowBinary type node #{type.kind.inspect}")
      end
    end

    def row_values(kind)
      source = kind == 'main' ? MAIN_ROWS : CONTROL_ROWS.map { |document| [document] }
      type = kind == 'main' ? MAIN_VALUE : CONTROL_VALUE
      source.each_with_index.map do |value, index|
        [[index + 1].pack('Q<').b + encode_value(type, value)].join.b
      end
    end

    def insert_query(table)
      "INSERT INTO default.#{table} FORMAT RowBinary"
    end

    def register_process!(label, argv, input, store, encoding)
      fail!("duplicate or unsafe process label #{label.inspect}") unless
        label.match?(/\A[a-z0-9_.-]+\z/) && !@expected_processes.key?(label)
      @expected_processes[label] = {
        argv: argv, stdin: input, process_kind: 'clickhouse-local', binary_path: @binary,
        expected_sha256: BINARY_SHA256, store_path: store, stdin_encoding: encoding,
      }
    end

    def execute_sql!(label, store, sql)
      input = (pin_sql + sql).b
      argv = [@binary, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
              "--max_memory_usage=#{MEMORY_LIMIT}", '--multiquery']
      register_process!(label, argv, input, store, 'sql')
      @runner.send(:run_process, label, argv, input, 'clickhouse-local', expected_sha: BINARY_SHA256,
                   binary_path: @binary, store: store)
    end

    def execute_rowbinary!(label, store, table, kind)
      input_rows = row_values(kind)
      input = input_rows.join.b
      query = insert_query(table)
      argv = [@binary, 'local', '--path', store, '--session_timezone=UTC', '--max_threads=1',
              "--max_memory_usage=#{MEMORY_LIMIT}", '--input_format_binary_read_json_as_string=0', '--query', query]
      register_process!(label, argv, input, store, 'rowbinary')
      result = @runner.send(:run_process, label, argv, input, 'clickhouse-local', expected_sha: BINARY_SHA256,
                            binary_path: @binary, store: store)
      send(:rename_binary_stdin_sidecar!, label)
      result[:literal_input] = {
        schema_kind: kind, row_count: input_rows.size,
        rows: literal_rows(kind).each_with_index.map do |row, index|
          {pk: index + 1, values: row, rowbinary_hex: input_rows.fetch(index).unpack1('H*')}
        end,
        stdin_file: result.fetch(:record).fetch(:stdin_file),
        stdin_bytes: input.bytesize, stdin_sha256: Digest::SHA256.hexdigest(input),
        query: query,
      }
      result
    end

    def literal_rows(kind)
      kind == 'main' ? MAIN_ROWS : CONTROL_ROWS
    end

    def capture_case!(id, kind, mark_format)
      table = table_name(id)
      store = send(:store_path, id)
      create = execute_sql!("#{id}_create", store, create_sql(table, kind, mark_format))
      insert = if success?(create)
                 execute_rowbinary!("#{id}_insert", store, table, kind)
               end
      physical = success?(create) ? inspect_schema_part!(id, table, store, kind, mark_format) : nil
      windows = if success?(create)
                  WINDOWS.keys.to_h do |window|
                    begin
                      [window, read_window!(id, table, store, kind, window)]
                    rescue StandardError => error
                      [window, {state: 'probe_error', error: "#{error.class}: #{error.message}"}]
                    end
                  end
                else
                  WINDOWS.keys.to_h { |window| [window, {state: 'unavailable_create_rejected'}] }
                end
      insert_literal = insert && insert.fetch(:literal_input)
      outcome = if !success?(create)
                  result_class(create) == 'server_exception' ? 'create_server_exception' : 'create_infrastructure_failure'
                elsif insert && !success?(insert)
                  result_class(insert) == 'server_exception' ? 'insert_server_exception' : 'insert_infrastructure_failure'
                elsif physical && physical[:part] && windows.values.all? { |item| item[:state] == 'exact_values' }
                  'exact_native_values'
                elsif insert && success?(insert)
                  'inserted_but_physical_oracle_incomplete'
                else
                  'incomplete'
                end
      {
        case_id: id, schema_kind: kind, table: table, store: store, mark_format: mark_format,
        profile: 's0', object_shared_data_layout: 'map', object_shared_data_layout_value: 0,
        mark_compression: 'plain', variant_discriminator_mode: 'basic',
        status: outcome, create: stage_summary(create), insert: insert && stage_summary(insert),
        literal_input: insert_literal, schema_part: physical, windows: windows,
      }
    end

    def success?(result)
      result && result[:classification] == 'success' && result[:status]&.success? && result[:status]&.termsig.nil?
    end

    def result_class(result)
      result && result[:classification]
    end

    def stage_summary(result)
      record = result.fetch(:record)
      {
        label: record.fetch(:label), classification: result.fetch(:classification),
        exit: record.fetch(:exit), signal: record.fetch(:signal),
        stdout_file: record.fetch(:stdout_file), stdout_bytes: record.fetch(:stdout_bytes),
        stdout_sha256: record.fetch(:stdout_sha256), stderr_file: record.fetch(:stderr_file),
        stderr_bytes: record.fetch(:stderr_bytes), stderr_sha256: record.fetch(:stderr_sha256),
        argv_file: record.fetch(:argv_file), argv: record.fetch(:argv),
        stdin_file: record.fetch(:stdin_file), stdin_bytes: record.fetch(:stdin_bytes),
        stdin_sha256: record.fetch(:stdin_sha256), record_file: "#{record.fetch(:label)}.json",
      }
    end

    def inspect_schema_part!(id, table, store, kind, mark_format)
      schema_tag = marker('schema', id)
      part_tag = marker('part', id)
      path_tag = marker('table_path', id)
      sql = "SELECT '#{schema_tag}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;\n" \
            "SELECT '#{part_tag}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;\n" \
            "SELECT '#{path_tag}', arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw;\n"
      result = execute_sql!("#{id}_schema_part", store, sql)
      return {state: result_class(result), invocation: stage_summary(result)} unless success?(result)
      lines = pinned_lines(result, "#{id} schema/part")
      schema = tagged(lines, schema_tag, 3).map { |row| [row[1], row[2].gsub(/\s+/, '')] }
      expected_schema = schema_for(kind).map { |name, type| [name, type.gsub(/\s+/, '')] }
      fail!("#{id} native schema differs: #{schema.inspect}") unless schema == expected_schema
      parts = tagged(lines, part_tag, 7)
      paths = tagged(lines, path_tag, 2)
      fail!("#{id} table path query did not return one row") unless paths.size == 1
      table_path = paths.first[1]
      physical_part = nil
      raw_capture = nil
      unless parts.empty?
        fail!("#{id} expected one active eight-row Compact part with five physical marks") unless parts.size == 1 &&
          parts.first.values_at(1, 2, 4, 5, 6) == [table, PART_NAME, 'Compact', ROW_COUNT.to_s, '5']
        part_path = send(:safe_native_path, parts.first.fetch(3), store, "#{id} part")
        safe_table_path = send(:safe_native_path, table_path, store, "#{id} table")
        fail!("#{id} part path is not directly under the table data path") unless File.dirname(part_path) == safe_table_path
        mark_file = send(:mark_filename, mark_format, 'plain')
        fail!("#{id} expected physical mark file is absent") unless File.file?(File.join(part_path, mark_file))
        inventory = send(:tree_inventory, part_path)
        roster = send(:native_callback_roster!, id, part_path, mark_format, kind)
        metadata_path = File.join(part_path, 'serialization.json')
        metadata_raw = if File.file?(metadata_path) && !File.symlink?(metadata_path) && File.size(metadata_path) <= MAX_RAW_FILE_BYTES
                         File.binread(metadata_path)
                       end
        metadata = metadata_raw && JSON.parse(metadata_raw)
        snapshot = send(:save_part_snapshot!, id, part_path, inventory, roster,
                        {raw: metadata_raw, raw_sha256: metadata_raw && Digest::SHA256.hexdigest(metadata_raw)})
        raw_capture = {
          inventory: inventory, snapshot: snapshot, mark_file: mark_file,
          mark_bytes: File.size(File.join(part_path, mark_file)),
          mark_sha256: sha(File.join(part_path, mark_file)),
          mark_raw_file: "raw-records/#{id}.#{mark_file}",
          serialization_metadata: metadata,
          serialization_metadata_sha256: metadata_raw && Digest::SHA256.hexdigest(metadata_raw),
          serialization_metadata_raw_file: metadata_raw ? "raw-records/#{id}.serialization.json" : nil,
          callback_roster: roster,
        }
        fail!("#{id} part inventory changed during snapshot capture") unless send(:tree_inventory, part_path) == inventory
        physical_part = {path: part_path, row: parts.first, raw_capture: raw_capture}
      end
      {
        state: 'observed', schema: schema, expected_schema: expected_schema,
        active_parts: parts, table_data_path: table_path,
        part: physical_part, invocation: stage_summary(result),
      }
    rescue JSON::ParserError => error
      fail!("#{id} serialization metadata is malformed: #{error.message}")
    end

    def marker(kind, id, window = nil)
      suffix = window ? "_#{window.upcase}" : ''
      "__W280_#{kind.upcase}_#{id.upcase}#{suffix}__"
    end

    def state_token_sql(expression)
      state = "#{expression}.state"
      "if(isNull(#{state}), 'NULL', concat(dynamicType(#{state}), ':', lower(hex(dynamicElement(#{state}, 'String')))))"
    end

    def array_token_sql(expression)
      "lower(hex(toJSONString(arrayMap(w280_doc -> concat(toString(w280_doc.id), ':', #{state_token_sql('w280_doc')}), #{expression}))))"
    end

    def values_sql(id, table, kind, window)
      tag = marker('values', id, window)
      predicate = WINDOWS.fetch(window)
      if window == 'eof'
        return "SELECT '#{tag}', toString(count()) FROM default.#{table} WHERE #{predicate} FORMAT TSVRaw;\n"
      end
      fields = ["'#{tag}'", 'toString(pk)']
      if kind == 'main'
        fields << array_token_sql("tupleElement(json_pair, 'left')")
        fields << array_token_sql("tupleElement(json_pair, 'right')")
      else
        fields << array_token_sql('json_array')
      end
      where = predicate ? " WHERE #{predicate}" : ''
      "SELECT #{fields.join(', ')} FROM default.#{table}#{where} ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;\n"
    end

    def read_window!(id, table, store, kind, window)
      result = execute_sql!("#{id}_values_#{window}", store, values_sql(id, table, kind, window))
      return {state: result_class(result), invocation: stage_summary(result)} unless success?(result)
      lines = pinned_lines(result, "#{id}/#{window} value query")
      tag = marker('values', id, window)
      rows = tagged(lines, tag, window == 'eof' ? 2 : (kind == 'main' ? 4 : 3))
      if window == 'eof'
        exact = rows == [[tag, '0']] && lines.size == 1
        return {state: exact ? 'exact_values' : 'oracle_mismatch', rows: rows, expected_rows: [[tag, '0']], invocation: stage_summary(result)}
      end
      actual = rows.map do |row|
        pk = Integer(row.fetch(1), 10)
        if kind == 'main'
          {pk: pk, left: decode_hex_json(row.fetch(2)), right: decode_hex_json(row.fetch(3))}
        else
          {pk: pk, items: decode_hex_json(row.fetch(2))}
        end
      end
      expected = expected_rows(kind, window)
      exact = actual == expected && lines.size == rows.size
      {state: exact ? 'exact_values' : 'oracle_mismatch', rows: actual, expected_rows: expected,
       raw_rows: rows, invocation: stage_summary(result)}
    rescue ArgumentError, JSON::ParserError, KeyError => error
      {state: 'parse_error', error: "#{error.class}: #{error.message}"}
    end

    def expected_rows(kind, window)
      indexes = window == 'full' ? (0...ROW_COUNT).to_a : (2...6).to_a
      source = kind == 'main' ? MAIN_ROWS : CONTROL_ROWS
      indexes.map do |index|
        row = source.fetch(index)
        if kind == 'main'
          {pk: index + 1, left: row.fetch(:left).map { |document| document_token(document) },
           right: row.fetch(:right).map { |document| document_token(document) }}
        else
          {pk: index + 1, items: [document_token(row)]}
        end
      end
    end

    def document_token(document)
      "#{document.fetch(:id)}:#{state_token(document.fetch(:state))}"
    end

    def state_token(state)
      case state
      when :missing, :null then 'NULL'
      when :empty then 'String:'
      else fail!("unknown oracle state #{state.inspect}")
      end
    end

    def decode_hex_json(value)
      fail!('native value is not even-length lowercase hex') unless value.match?(/\A(?:[0-9a-f]{2})+\z/)
      JSON.parse([value].pack('H*'))
    end

    def pinned_lines(result, label)
      text = result.fetch(:stdout).dup.force_encoding(Encoding::UTF_8)
      fail!("#{label} stdout is not newline-terminated UTF-8") unless text.valid_encoding? && text.end_with?("\n")
      lines = text.lines.map(&:chomp)
      pins = lines.select { |line| line.start_with?("__W280_PIN__\t") }
      expected = "__W280_PIN__\t#{VERSION}\t#{BUILD}"
      fail!("#{label} runtime version/build pin differs: #{pins.inspect}") unless pins == [expected]
      lines.reject { |line| line == expected }
    end

    def tagged(lines, tag, width)
      lines.select { |line| line.start_with?(tag + "\t") }.map do |line|
        fields = line.split("\t", -1)
        fail!("#{tag} TSV width differs") unless fields.size == width
        fields
      end
    end

    def validate_process_evidence!
      fail!('process invocation roster differs from registered commands') unless
        @invocations.map { |item| item.fetch(:label) }.sort == @expected_processes.keys.sort
      expected_files = []
      @invocations.each do |record|
        label = record.fetch(:label)
        expected = @expected_processes.fetch(label)
        base = File.join(@root, 'invocations')
        stdin_name = "#{label}.stdin.#{expected.fetch(:stdin_encoding) == 'rowbinary' ? 'bin' : 'sql'}"
        argv_name = "#{label}.argv.json"
        stdout_name = "#{label}.stdout"
        stderr_name = "#{label}.stderr"
        record_name = "#{label}.json"
        expected_files.concat([stdin_name, argv_name, stdout_name, stderr_name, record_name])
        argv_bytes = JSON.pretty_generate(expected.fetch(:argv)) + "\n"
        fail!("#{label} argv sidecar differs") unless File.binread(File.join(base, argv_name)) == argv_bytes &&
          record.fetch(:argv) == expected.fetch(:argv) && record.fetch(:argv_sha256) == Digest::SHA256.hexdigest(argv_bytes)
        stdin = File.binread(File.join(base, stdin_name))
        fail!("#{label} stdin sidecar differs") unless stdin == expected.fetch(:stdin) &&
          record.fetch(:stdin_bytes) == stdin.bytesize && record.fetch(:stdin_sha256) == Digest::SHA256.hexdigest(stdin)
        stdout = File.binread(File.join(base, stdout_name))
        stderr = File.binread(File.join(base, stderr_name))
        fail!("#{label} stdout/stderr sidecars differ") unless
          record.fetch(:stdout_bytes) == stdout.bytesize && record.fetch(:stdout_sha256) == Digest::SHA256.hexdigest(stdout) &&
          record.fetch(:stderr_bytes) == stderr.bytesize && record.fetch(:stderr_sha256) == Digest::SHA256.hexdigest(stderr)
        fail!("#{label} process binary identity differs") unless
          record.fetch(:process_kind) == expected.fetch(:process_kind) && record.fetch(:binary_path) == @binary &&
          record.fetch(:expected_binary_sha256) == BINARY_SHA256 && record.fetch(:binary_sha_before) == BINARY_SHA256 &&
          record.fetch(:binary_sha_after) == BINARY_SHA256 && record.fetch(:store_path) == expected.fetch(:store_path)
        saved = JSON.parse(File.binread(File.join(base, record_name)))
        fail!("#{label} persisted process record differs") unless saved == JSON.parse(JSON.generate(record))
      end
      fail!('invocation sidecar directory has unexpected files') unless
        Dir.children(File.join(@root, 'invocations')).sort == expected_files.sort
      true
    end

    def build_summary
      main = @cases.values.select { |entry| entry[:schema_kind] == 'main' }
      controls = @cases.values.select { |entry| entry[:schema_kind] == ARRAY_CASE }
      main_create_rejections = main.select { |entry| entry[:status] == 'create_server_exception' }
      main_insert_rejections = main.select { |entry| entry[:status] == 'insert_server_exception' }
      controls_exact = controls.size == 2 && controls.all? { |entry| entry[:status] == 'exact_native_values' }
      main_exact = main.size == 2 && main.all? { |entry| entry[:status] == 'exact_native_values' }
      status = if controls_exact && main_create_rejections.size == 2
                 'main_stock_create_rejection_control_exact'
               elsif controls_exact && main_insert_rejections.any?
                 'main_insert_server_exception_control_exact'
               elsif controls_exact && main_exact
                 'main_and_control_exact_native_values'
               elsif @cases.values.any? { |entry| entry[:status].to_s.include?('infrastructure_failure') }
                 'probe_infrastructure_failure'
               else
                 'incomplete_or_discrepant'
               end
      {
        format: FORMAT, status: status,
        execution_scope: 'Stock clickhouse-local only; no Crystal binary, helper, fixture, or production code is invoked.',
        runtime_pin: {binary: @binary, sha256_expected: BINARY_SHA256, sha256_before: @binary_sha_before,
                      sha256_after: @binary_sha_after, version: VERSION, build: BUILD},
        source_pin: {root: @source_root, revision_expected: SOURCE_REVISION,
                     revision_before: @source_revision_before,
                     revision_after: @source_revision_after, source_sha256_before: @upstream_hashes_before,
                     source_sha256_after: @upstream_hashes_after},
        probe_source_pins: {sha256_before: @probe_hashes_before, sha256_after: @probe_hashes_after},
        schema_parameters: {object_serialization_version: 'v3', object_shared_data_serialization_version: 'map',
                            map_layout_value: 0, object_shared_data_buckets_for_compact_part: 1,
                            string_serialization_version: 'single_stream (S0)', dynamic_serialization_version: 'v3',
                            mark_compression: 'plain', variant_discriminator_mode: 'basic'},
        fixture: {rows: ROW_COUNT, rows_per_mark: ROWS_PER_MARK, data_marks: DATA_MARK_COUNT,
                  physical_mark_rows_with_eof: PHYSICAL_MARK_ROWS_WITH_EOF,
                  windows: PHYSICAL_WINDOWS, json_type: JSON_TYPE, main_schema: SCHEMAS.fetch('main'),
                  control_schema: SCHEMAS.fetch(ARRAY_CASE), main_literal_rows: MAIN_ROWS,
                  array_control_literal_rows: CONTROL_ROWS,
                  state_oracle: {
                    input_encoding: {missing: 'id only; state path omitted', null: 'id plus typed Dynamic NULL',
                                     empty_string: 'id plus typed Dynamic empty String'},
                    observed_projection: {missing_and_null: 'NULL (may collapse)', empty_string: 'String:'}}},
        cases: @cases, invocation_roster: @invocations.map { |record| stage_summary({record: record, classification: record.fetch(:process_classification)}) },
        evidence_root: @root,
        claim_boundary: 'Finite eight-row stock-native witness for the named Tuple(Array(JSON), Array(JSON)) schema and an Array(JSON) positive control in MAP0/S0/plain MRK3 and MRK4. A captured server exception is classified at its exact stage and retained with raw stderr and argv; the control separates type admission from process or SQL instrumentation failure. No writer implementation, arbitrary Tuple topology, all JSON paths, or performance claim is made.',
      }
    end

    def render_summary(summary)
      lines = [
        '# W280 Compact recursive Array(JSON) stock probe', '',
        "Status: `#{summary.fetch(:status)}`",
        "Runtime: `#{VERSION}` build `#{BUILD}` SHA-256 `#{BINARY_SHA256}`.",
        "Source: `#{SOURCE_REVISION}` at `#{SOURCE_ROOT}` (separate pin).",
        'The main case alternates populated left and right arrays over eight rows; JSON literals distinguish a missing state path, present null, and present empty String. Both main schema and one-Array positive control are attempted in plain S0/MAP0 under MRK3 and MRK4.',
      ]
      @cases.each do |id, entry|
        lines << "- #{id}: `#{entry.fetch(:status)}`."
      end
      lines.concat(['', summary.fetch(:claim_boundary), ''])
      lines.join("\n")
    end

    def persist_inconclusive(error)
      return unless @root && File.directory?(File.join(@root, 'invocations'))
      report = {
        format: FORMAT, status: 'inconclusive', fatal_error: @fatal_error,
        error_class: error.class.name, runtime_pin: {binary: @binary, expected_sha256: BINARY_SHA256},
        source_pin: {root: @source_root, expected_revision: SOURCE_REVISION},
        cases: @cases, invocations: @invocations, evidence_root: @root,
      }
      send(:write_new, File.join(@root, 'summary.json'), JSON.pretty_generate(report) + "\n") unless File.exist?(File.join(@root, 'summary.json'))
    rescue StandardError
      nil
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  options = {
    binary: ProbeCompactRecursiveArraysW280::BINARY,
    source_root: ProbeCompactRecursiveArraysW280::SOURCE_ROOT,
    evidence_root: nil,
  }
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/probe_compact_recursive_arrays_w280.rb --evidence-root EMPTY_DIR [--binary PINNED_CLICKHOUSE] [--source-root PINNED_UPSTREAM]'
    parser.on('--evidence-root EMPTY_DIR', 'Existing empty direct child of /private/tmp') { |value| options[:evidence_root] = value }
    parser.on('--binary PATH', 'Pinned ClickHouse runtime executable, distinct from source checkout') { |value| options[:binary] = value }
    parser.on('--source-root PATH', 'Separately pinned upstream ClickHouse source checkout') { |value| options[:source_root] = value }
  end.parse!
  unless options[:evidence_root]
    warn 'W280: provide --evidence-root'
    exit 2
  end
  exit(ProbeCompactRecursiveArraysW280::Probe.new(**options).run ? 0 : 1)
end
