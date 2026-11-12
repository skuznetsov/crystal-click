#!/usr/bin/env ruby
# Stock-first, independent native oracle and generated-part interop matrix for
# recursive Compact JSON values. The Ruby literals below are not read from the
# Crystal fixture/helper; only the helper's observed signatures are compared to
# this oracle.

require 'digest'
require 'json'
require 'open3'
require 'optparse'
require_relative 'probe_compact_recursive_arrays_w280'

module ProbeCompactRecursiveArraysW280Matrix
  W280 = ProbeCompactRecursiveArraysW280
  W279 = W280::W279
  W278 = W280::W278
  W277 = W280::W277
  W276 = W280::W276
  W241 = W280::W241

  FORMAT = 'compact_recursive_arrays_w280_matrix_v1'.freeze
  HELPER_FORMAT = 'compact_recursive_arrays_w280_helper_v3'.freeze
  PROBE_SOURCE = File.expand_path(__FILE__).freeze
  HELPER_SOURCE = File.expand_path('compact_recursive_arrays_w280_helper.cr', __dir__).freeze
  FIXTURE_SOURCE = File.expand_path('../spec/support/compact_part_writer_w280_fixture.cr', __dir__).freeze

  CASES = %w[array_json named_sibling_arrays four_sibling_objects nested_five_sites positional_uint8].freeze
  MARK_FORMATS = %w[mrk3 mrk4].freeze
  ROW_COUNT = 8
  ROWS_PER_MARK = 2
  DATA_MARK_COUNT = 4
  RAW_MARK_FILE_ROWS = [2, 2, 2, 2, 0].freeze
  PUBLIC_READER_MARK_ROWS = [2, 2, 2, 2].freeze
  ATTACHED_NATIVE_SIDECAR_PATH = 'invalidated_system_columns.txt'.freeze
  ATTACHED_NATIVE_SIDECAR_BYTES = "_block_offset\n_block_number\n".b.freeze
  ATTACHED_NATIVE_SIDECAR_ENTRY = {
    path: ATTACHED_NATIVE_SIDECAR_PATH,
    size: 28,
    sha256: '7409424ab45090c1261e622f7423393905102e7e8cba36a6db88eb513ce1e06c',
  }.freeze
  ATTACHED_INVENTORY_CONTRACT_STATE = 'generated_files_byte_preserved_with_exact_native_sidecar'.freeze
  WINDOWS = {
    'full' => nil,
    'middle' => 'pk BETWEEN 3 AND 6',
    'last' => 'pk BETWEEN 7 AND 8',
    'eof' => 'pk > 8',
  }.freeze
  PHYSICAL_WINDOWS = {'full' => [0, 4], 'middle' => [1, 2], 'last' => [3, 1], 'eof' => [4, 0]}.freeze
  TYPED_WINDOWS = {'full' => [0, 8], 'middle' => [2, 4], 'last' => [6, 2], 'eof' => [8, 0]}.freeze

  JSON_TYPE = 'JSON(max_dynamic_types=0,max_dynamic_paths=0,id UInt64)'.freeze
  ARRAY_JSON_TYPE = "Array(#{JSON_TYPE})".freeze
  NESTED_ITEM_TYPE = "Tuple(Array(#{JSON_TYPE}),UInt8,#{JSON_TYPE})".freeze
  SCHEMAS = {
    'array_json' => [['pk', 'UInt64'], ['recursive_json_w280', ARRAY_JSON_TYPE]],
    'named_sibling_arrays' => [
      ['pk', 'UInt64'],
      ['recursive_json_w280', "Tuple(left Array(#{JSON_TYPE}),right Array(#{JSON_TYPE}))"],
    ],
    'four_sibling_objects' => [
      ['pk', 'UInt64'],
      ['recursive_json_w280', "Tuple(Tuple(#{JSON_TYPE},#{JSON_TYPE}),Tuple(#{JSON_TYPE},#{JSON_TYPE}))"],
    ],
    'nested_five_sites' => [
      ['pk', 'UInt64'],
      ['recursive_json_w280', "Tuple(Array(#{NESTED_ITEM_TYPE}),Array(#{NESTED_ITEM_TYPE}),#{JSON_TYPE})"],
    ],
    'positional_uint8' => [
      ['pk', 'UInt64'],
      ['recursive_json_w280', "Tuple(UInt8,#{JSON_TYPE},Array(UInt8),UInt8,#{JSON_TYPE},Array(#{JSON_TYPE}),UInt8)"],
    ],
  }.transform_values { |schema| schema.map(&:freeze).freeze }.freeze

  TypeDef = Struct.new(:kind, :child, :fields, keyword_init: true)
  JSON_VALUE = TypeDef.new(kind: :json).freeze
  UINT8_VALUE = TypeDef.new(kind: :uint8).freeze
  ARRAY_JSON_VALUE = TypeDef.new(kind: :array, child: JSON_VALUE).freeze
  NESTED_ITEM_VALUE = TypeDef.new(kind: :tuple, fields: [
    [0, TypeDef.new(kind: :array, child: JSON_VALUE).freeze], [1, UINT8_VALUE], [2, JSON_VALUE],
  ].freeze).freeze
  TYPE_DEFS = {
    'array_json' => ARRAY_JSON_VALUE,
    'named_sibling_arrays' => TypeDef.new(kind: :tuple, fields: [
      ['left', ARRAY_JSON_VALUE], ['right', ARRAY_JSON_VALUE],
    ].freeze).freeze,
    'four_sibling_objects' => TypeDef.new(kind: :tuple, fields: [
      [0, TypeDef.new(kind: :tuple, fields: [[0, JSON_VALUE], [1, JSON_VALUE]].freeze).freeze],
      [1, TypeDef.new(kind: :tuple, fields: [[0, JSON_VALUE], [1, JSON_VALUE]].freeze).freeze],
    ].freeze).freeze,
    'nested_five_sites' => TypeDef.new(kind: :tuple, fields: [
      [0, TypeDef.new(kind: :array, child: NESTED_ITEM_VALUE).freeze],
      [1, TypeDef.new(kind: :array, child: NESTED_ITEM_VALUE).freeze],
      [2, JSON_VALUE],
    ].freeze).freeze,
    'positional_uint8' => TypeDef.new(kind: :tuple, fields: [
      [0, UINT8_VALUE], [1, JSON_VALUE], [2, TypeDef.new(kind: :array, child: UINT8_VALUE).freeze],
      [3, UINT8_VALUE], [4, JSON_VALUE], [5, ARRAY_JSON_VALUE], [6, UINT8_VALUE],
    ].freeze).freeze,
  }.freeze

  def self.json_doc(id)
    {'id' => id}
  end

  # Independent literal rows. Each table's pk is assigned by row position;
  # JSON ids distinguish every structural site and detect swapped branches.
  ROWS = {
    'array_json' => [
      [json_doc(1), json_doc(2)], [], [json_doc(3)], [json_doc(4), json_doc(5)],
      [], [json_doc(6)], [], [json_doc(7), json_doc(8)],
    ],
    'named_sibling_arrays' => [
      [[json_doc(11), json_doc(12)], [json_doc(101)]],
      [[], [json_doc(102), json_doc(103)]],
      [[json_doc(13)], []],
      [[json_doc(14), json_doc(15)], [json_doc(104)]],
      [[], [json_doc(105), json_doc(106)]],
      [[json_doc(16)], [json_doc(107)]],
      [[json_doc(17), json_doc(18)], []],
      [[], [json_doc(108)]],
    ],
    'four_sibling_objects' => [
      [[json_doc(1), json_doc(101)], [json_doc(2), json_doc(102)]],
      [[json_doc(3), json_doc(103)], [json_doc(4), json_doc(104)]],
      [[json_doc(5), json_doc(105)], [json_doc(6), json_doc(106)]],
      [[json_doc(7), json_doc(107)], [json_doc(8), json_doc(108)]],
      [[json_doc(9), json_doc(109)], [json_doc(10), json_doc(110)]],
      [[json_doc(11), json_doc(111)], [json_doc(12), json_doc(112)]],
      [[json_doc(13), json_doc(113)], [json_doc(14), json_doc(114)]],
      [[json_doc(15), json_doc(115)], [json_doc(16), json_doc(116)]],
    ],
    'nested_five_sites' => [
      [
        [[[json_doc(201), json_doc(202)], 1, json_doc(301)], [[], 2, json_doc(302)]],
        [[[json_doc(401)], 3, json_doc(501)]], json_doc(601),
      ],
      [[], [[[json_doc(402), json_doc(403)], 4, json_doc(502)]], json_doc(602)],
      [[[[json_doc(203)], 5, json_doc(303)]], [], json_doc(603)],
      [
        [[[], 6, json_doc(304)]],
        [[[], 7, json_doc(503)], [[json_doc(404)], 8, json_doc(504)]], json_doc(604),
      ],
      [[], [], json_doc(605)],
      [
        [[[json_doc(204), json_doc(205)], 9, json_doc(305)]],
        [[[json_doc(405)], 10, json_doc(505)]], json_doc(606),
      ],
      [[[[json_doc(206)], 11, json_doc(306)]], [], json_doc(607)],
      [[], [[[], 12, json_doc(506)]], json_doc(608)],
    ],
    'positional_uint8' => [
      [1, json_doc(11), [2, 3], 4, json_doc(21), [json_doc(31), json_doc(32)], 5],
      [2, json_doc(12), [], 5, json_doc(22), [], 6],
      [3, json_doc(13), [4], 6, json_doc(23), [json_doc(33)], 7],
      [4, json_doc(14), [5, 6], 7, json_doc(24), [json_doc(34), json_doc(35)], 8],
      [5, json_doc(15), [], 8, json_doc(25), [], 9],
      [6, json_doc(16), [7], 9, json_doc(26), [json_doc(36)], 10],
      [7, json_doc(17), [8, 9], 10, json_doc(27), [json_doc(37), json_doc(38)], 11],
      [8, json_doc(18), [], 11, json_doc(28), [], 12],
    ],
  }.transform_values { |rows| rows.map { |row| row.freeze }.freeze }.freeze

  JSON_SITE_COUNTS = {
    'array_json' => 1, 'named_sibling_arrays' => 2, 'four_sibling_objects' => 4,
    'nested_five_sites' => 5, 'positional_uint8' => 3,
  }.freeze
  CONCLUSIVE_STOCK_STATUSES = %w[stock_native_matrix_exact stock_type_rejection_control_exact].freeze
  SUCCESS_STATUSES = (CONCLUSIVE_STOCK_STATUSES + %w[generated_native_interop_matrix_exact]).freeze

  class Failure < StandardError; end

  class Probe < W280::Probe
    def initialize(binary:, source_root:, evidence_root:, stock_only: false, full_matrix: false,
                   helper: nil, helper_sha256: nil)
      @stock_only = stock_only
      @full_matrix = full_matrix
      @helper_argument = helper
      @helper_sha_argument = helper_sha256
      super(binary: binary, source_root: source_root, evidence_root: evidence_root)
      fail!('select exactly one of --stock-only or --full-matrix') unless @stock_only != @full_matrix
      if @full_matrix
        fail!('--full-matrix requires a helper path and exact SHA-256') unless helper && helper_sha256
      elsif helper || helper_sha256
        fail!('--helper and --helper-sha256 require --full-matrix')
      end
    end

    def run
      prepare!
      MARK_FORMATS.each do |mark_format|
        CASES.each do |kind|
          id = "#{kind}_#{mark_format}"
          begin
            @cases[id] = capture_case!(id, kind, mark_format)
          rescue StandardError => error
            @cases[id] = {case_id: id, schema_kind: kind, mark_format: mark_format,
                          status: 'probe_error', error: "#{error.class}: #{error.message}"}
          end
        end
      end

      if @full_matrix
        @cases.each do |id, entry|
          next unless entry.fetch(:status) == 'exact_native_values'
          entry[:library_stock_read] = capture_helper_read!("#{id}_helper_stock", id, entry.fetch(:schema_kind),
                                                            entry.fetch(:mark_format), entry.dig(:schema_part, :part, :path))
        end
        MARK_FORMATS.each do |mark_format|
          CASES.each do |kind|
            id = "#{kind}_#{mark_format}"
            begin
              @cases[id][:library_generated] = capture_generated!(id, kind, mark_format)
            rescue StandardError => error
              @cases[id][:library_generated] = {status: 'probe_error', error: "#{error.class}: #{error.message}"}
            end
          end
        end
      end

      validate_process_evidence!
      validate_pins!
      summary = build_summary
      send(:write_new, File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      send(:write_new, File.join(@root, 'summary.md'), render_summary(summary))
      puts "W280 matrix status=#{summary.fetch(:status)}; cases=#{@cases.size}; invocations=#{@invocations.size}; evidence=#{@root}"
      SUCCESS_STATUSES.include?(summary.fetch(:status))
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      persist_inconclusive(error)
      warn "W280 matrix inconclusive: #{@fatal_error}"
      false
    end

    def self.self_test!
      probe = allocate
      probe.send(:validate_literals!)
      probe.send(:self_test_attached_inventory_contract!)
      bytes_by_case = {}
      CASES.each do |kind|
        rowbinary = probe.send(:row_values, kind)
        raise Failure, "#{kind} did not encode eight independent RowBinary rows" unless rowbinary.size == ROW_COUNT
        raise Failure, "#{kind} produced an empty RowBinary row" unless rowbinary.all? { |row| !row.empty? }
        raise Failure, "#{kind} RowBinary keys are not the literal row ordinals" unless
          rowbinary.each_with_index.all? { |row, index| row.byteslice(0, 8).unpack1('Q<') == index + 1 }
        bytes_by_case[kind] = rowbinary.sum(&:bytesize)
        expected = probe.send(:expected_signatures, kind)
        raise Failure, "#{kind} oracle does not cover all eight rows" unless expected.size == ROW_COUNT
        probe.send(:validate_helper_report!,
                   {state: 'success', report: probe.send(:helper_report_for_test, kind, action: 'write'), invocation: {}},
                   "self_test_#{kind}", kind, 'mrk3', 'write',
                   expected_part_path: '/tmp/w280-self-test/part')
      end
      probe.send(:self_test_rejects_malformed_helper_reports!)
      puts "W280 matrix Ruby oracle self-test passed; cases=#{CASES.size}; rowbinary_bytes=#{bytes_by_case.inspect}"
      true
    end

    private

    def fail!(message)
      raise Failure, "W280 matrix: #{message}"
    end

    def validate_literals!
      fail!('matrix must retain exactly the five requested structural shapes') unless CASES == SCHEMAS.keys && CASES == ROWS.keys
      fail!('literal recursive type definitions differ from the five schema cases') unless CASES == TYPE_DEFS.keys
      fail!('every native literal must contain eight rows and four two-row marks') unless
        CASES.all? { |kind| ROWS.fetch(kind).size == ROW_COUNT && ROWS.fetch(kind).each_slice(ROWS_PER_MARK).count == DATA_MARK_COUNT }
      fail!('raw mark files must include one zero-row EOF record after four data marks') unless
        RAW_MARK_FILE_ROWS == [2, 2, 2, 2, 0] && RAW_MARK_FILE_ROWS.size == DATA_MARK_COUNT + 1
      fail!('public recursive readers must expose only the four nonempty data marks') unless
        PUBLIC_READER_MARK_ROWS == [2, 2, 2, 2] && PUBLIC_READER_MARK_ROWS.size == DATA_MARK_COUNT
      fail!('raw mark-file and public-reader grids must remain distinct') if RAW_MARK_FILE_ROWS == PUBLIC_READER_MARK_ROWS
      fail!('declared JSON-site counts differ from recursive type topology') unless
        CASES.all? { |kind| count_json_sites(TYPE_DEFS.fetch(kind)) == JSON_SITE_COUNTS.fetch(kind) }
      fail!('Array(JSON) control declaration changed') unless SCHEMAS.fetch('array_json').last.last == ARRAY_JSON_TYPE
      fail!('named sibling arrays must retain named Tuple fields') unless
        SCHEMAS.fetch('named_sibling_arrays').last.last.start_with?('Tuple(left Array(') &&
        SCHEMAS.fetch('named_sibling_arrays').last.last.include?(',right Array(')
      fail!('four sibling Object sites must remain four independent positions') unless JSON_SITE_COUNTS.fetch('four_sibling_objects') == 4
      fail!('nested five-site shape must retain unequal nested domains and an empty parent row') unless
        JSON_SITE_COUNTS.fetch('nested_five_sites') == 5 && ROWS.fetch('nested_five_sites')[4].values_at(0, 1) == [[], []] &&
        json_site_domain_counts('nested_five_sites').values.uniq.size > 1
      positional = SCHEMAS.fetch('positional_uint8').last.last
      fail!('positional basis must preserve UInt8 before, between, after JSON and Array(UInt8)') unless
        positional.start_with?('Tuple(UInt8,') && positional.include?('Array(UInt8),UInt8,') && positional.end_with?(',UInt8)')
      fail!('positional Array(UInt8) literals must include nonempty and empty values') unless
        ROWS.fetch('positional_uint8').any? { |row| !row.fetch(2).empty? } &&
        ROWS.fetch('positional_uint8').any? { |row| row.fetch(2).empty? }
      CASES.each do |kind|
        array_domains = array_domain_observations(kind)
        fail!("#{kind} Array sites must each observe empty and populated domains") unless
          array_domains.values.all? { |sizes| sizes.any?(&:zero?) && sizes.any?(&:positive?) }
      end
      fail!('fixture includes only distinct JSON id values') unless
        CASES.all? { |kind| flatten_json_ids(ROWS.fetch(kind)).uniq == flatten_json_ids(ROWS.fetch(kind)) }
      true
    end

    def count_json_sites(type)
      case type.kind
      when :json then 1
      when :uint8 then 0
      when :array then count_json_sites(type.child)
      when :tuple then type.fields.sum { |_name, child_type| count_json_sites(child_type) }
      else raise Failure, "unknown JSON-site type #{type.kind.inspect}"
      end
    end

    def array_domain_observations(kind)
      observed = Hash.new { |hash, path| hash[path] = [] }
      ROWS.fetch(kind).each do |row|
        accumulate_array_domains(TYPE_DEFS.fetch(kind), row, 'root', observed)
      end
      observed
    end

    def accumulate_array_domains(type, value, path, observed)
      case type.kind
      when :json, :uint8
        nil
      when :array
        observed[path] << value.size
        value.each { |child| accumulate_array_domains(type.child, child, "#{path}/array[0]", observed) }
      when :tuple
        type.fields.each_with_index do |(name, child_type), index|
          child = value.is_a?(Hash) ? value.fetch(name) : value.fetch(index)
          accumulate_array_domains(child_type, child, "#{path}/tuple[#{index}]", observed)
        end
      else
        raise Failure, "unknown Array-domain type #{type.kind.inspect}"
      end
      observed
    end

    def flatten_json_ids(value)
      case value
      when Hash
        value.key?('id') ? [value.fetch('id')] : value.values.flat_map { |child| flatten_json_ids(child) }
      when Array
        value.flat_map { |child| flatten_json_ids(child) }
      else
        []
      end
    end

    def json_site_domain_counts(kind)
      counts = Hash.new(0)
      type = TYPE_DEFS.fetch(kind)
      ROWS.fetch(kind).each { |value| accumulate_json_domains(type, value, 'root', counts) }
      counts.sort.to_h
    end

    def accumulate_json_domains(type, value, path, counts)
      case type.kind
      when :json
        counts[path] += 1
      when :uint8
        nil
      when :array
        value.each { |child| accumulate_json_domains(type.child, child, "#{path}/array[0]", counts) }
      when :tuple
        type.fields.each_with_index do |(name, child_type), index|
          child = value.is_a?(Hash) ? value.fetch(name) : value.fetch(index)
          accumulate_json_domains(child_type, child, "#{path}/tuple[#{index}]", counts)
        end
      else
        raise Failure, "unknown JSON-domain oracle type #{type.kind.inspect}"
      end
      counts
    end

    def prepare!
      super
      @local_source_paths = [PROBE_SOURCE, HELPER_SOURCE, FIXTURE_SOURCE].map do |path|
        fail!("matrix source is missing or symlinked: #{path}") unless File.file?(path) && !File.symlink?(path)
        File.realpath(path)
      end.uniq.sort
      @local_source_hashes_before = @local_source_paths.to_h { |path| [path, sha(path)] }
      if @full_matrix
        @helper = send(:validate_executable, @helper_argument, 'pinned W280 Crystal helper')
        @helper_sha_before = sha(@helper)
        fail!('helper executable differs from --helper-sha256') unless @helper_sha_before == @helper_sha_argument
      end
    end

    def validate_pins!
      super
      @local_source_hashes_after = @local_source_hashes_before.keys.to_h { |path| [path, sha(path)] }
      fail!('matrix Ruby/helper/fixture source bytes changed during capture') unless
        @local_source_hashes_after == @local_source_hashes_before
      if @full_matrix
        @helper_sha_after = sha(@helper)
        fail!('prebuilt helper executable changed during capture') unless @helper_sha_after == @helper_sha_before
      end
    end

    def sha(path)
      Digest::SHA256.file(path).hexdigest
    end

    def table_name(id)
      "w280m_#{@token}_#{id}"
    end

    def schema_for(kind)
      SCHEMAS.fetch(kind) { fail!("unknown schema kind #{kind.inspect}") }
    end

    def create_sql(table, kind, mark_format)
      declarations = schema_for(kind).map { |name, type| "`#{name}` #{type}" }.join(', ')
      "SET flatten_nested=0;\nSET allow_suspicious_low_cardinality_types=1;\nSET use_variant_as_common_type=1;\n" \
        "CREATE TABLE default.#{table} (#{declarations}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings(mark_format)};\n"
    end

    def rowbinary_json(document)
      paths = [['id', [Integer(document.fetch('id'))].pack('Q<').b]]
      rowbinary_var_uint(paths.size) + paths.map { |path, bytes| rowbinary_string(path) + bytes }.join.b
    end

    def row_values(kind)
      type = TYPE_DEFS.fetch(kind)
      ROWS.fetch(kind).each_with_index.map do |value, index|
        [index + 1].pack('Q<').b + encode_value(type, value)
      end
    end

    def literal_rows(kind)
      ROWS.fetch(kind)
    end

    def marker(kind, id, window = nil)
      suffix = window ? "_#{window.upcase}" : ''
      "__W280M_#{kind.to_s.upcase}_#{id.upcase}#{suffix}__"
    end

    def capture_case!(id, kind, mark_format)
      table = table_name(id)
      store = send(:store_path, id)
      create = execute_sql!("#{id}_create", store, create_sql(table, kind, mark_format))
      insert = send(:success?, create) ? execute_rowbinary!("#{id}_insert", store, table, kind) : nil
      physical = send(:success?, create) ? inspect_schema_part!(id, table, store, kind, mark_format) : nil
      check = nil
      windows = WINDOWS.keys.to_h { |window| [window, {state: 'unavailable'}] }
      if insert && send(:success?, insert) && physical&.dig(:part)
        begin
          check = send(:check!, "#{id}_native", table, store)
          windows = WINDOWS.keys.to_h do |window|
            begin
              [window, read_window!(id, table, store, kind, window)]
            rescue StandardError => error
              [window, {state: 'probe_error', error: "#{error.class}: #{error.message}"}]
            end
          end
        rescue StandardError => error
          check = {state: 'probe_error', error: "#{error.class}: #{error.message}"}
        end
      end

      status = if !send(:success?, create)
                 send(:result_class, create) == 'server_exception' ? 'create_server_exception' : 'create_infrastructure_failure'
               elsif !insert || !send(:success?, insert)
                 send(:result_class, insert) == 'server_exception' ? 'insert_server_exception' : 'insert_infrastructure_failure'
               elsif !physical&.dig(:part)
                 'inserted_without_active_compact_part'
               elsif check && check[:state] == 'healthy' && windows.values.all? { |entry| entry[:state] == 'exact_values' }
                 'exact_native_values'
               else
                 'native_oracle_incomplete'
               end
      {
        case_id: id, schema_kind: kind, table: table, store: store, mark_format: mark_format,
        schema_parameters: {object_serialization_version: 'v3', object_shared_data_serialization_version: 'map',
                            map_layout_value: 0, buckets: 1, string_serialization_version: 'single_stream (S0)',
                            mark_compression: 'plain', variant_discriminator_mode: 'basic'},
        status: status, create: send(:stage_summary, create), insert: insert && send(:stage_summary, insert),
        literal_input: insert && insert[:literal_input], schema_part: physical, check: check, windows: windows,
      }
    end

    def values_sql(id, table, window)
      tag = marker('values', id, window)
      predicate = WINDOWS.fetch(window)
      if window == 'eof'
        return "SELECT '#{tag}', toString(count()) FROM default.#{table} WHERE #{predicate} FORMAT TSVRaw;\n"
      end
      where = predicate ? " WHERE #{predicate}" : ''
      "SELECT '#{tag}', toString(pk), lower(hex(toJSONString(recursive_json_w280))) " \
        "FROM default.#{table}#{where} ORDER BY pk SETTINGS " \
        "output_format_json_named_tuples_as_objects=0, output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;\n"
    end

    def read_window!(id, table, store, kind, window)
      result = execute_sql!("#{id}_values_#{window}", store, values_sql(id, table, window))
      return {state: send(:result_class, result), invocation: send(:stage_summary, result)} unless send(:success?, result)
      lines = pinned_lines(result, "#{id}/#{window} matrix native value query")
      tag = marker('values', id, window)
      if window == 'eof'
        rows = tagged(lines, tag, 2)
        exact = rows == [[tag, '0']] && lines.size == 1
        return {state: exact ? 'exact_values' : 'oracle_mismatch', rows: rows,
                expected_rows: [[tag, '0']], invocation: send(:stage_summary, result)}
      end
      rows = tagged(lines, tag, 3)
      actual = rows.map { |row| {pk: Integer(row.fetch(1), 10), value: decode_hex_json(row.fetch(2))} }
      expected = expected_native_rows(kind, window)
      exact = actual == expected && rows.size == expected.size && lines.size == rows.size
      {state: exact ? 'exact_values' : 'oracle_mismatch', rows: actual, expected_rows: expected,
       raw_rows: rows, invocation: send(:stage_summary, result)}
    rescue ArgumentError, JSON::ParserError, KeyError => error
      {state: 'parse_error', error: "#{error.class}: #{error.message}"}
    end

    def decode_hex_json(value)
      fail!('native JSON projection is not even-length lowercase hex') unless value.match?(/\A(?:[0-9a-f]{2})+\z/)
      JSON.parse([value].pack('H*'))
    end

    def expected_native_rows(kind, window)
      indexes = case window
                when 'full' then (0...ROW_COUNT).to_a
                when 'middle' then (2...6).to_a
                when 'last' then (6...8).to_a
                else fail!("non-value window #{window.inspect}")
                end
      indexes.map { |index| {pk: index + 1, value: ROWS.fetch(kind).fetch(index)} }
    end

    def typed_signature(type, value)
      case type.kind
      when :json
        "J#{value.fetch('id')}"
      when :uint8
        "U#{Integer(value)}"
      when :array
        "A[#{value.map { |child| typed_signature(type.child, child) }.join(',')}]"
      when :tuple
        children = type.fields.map do |name, child_type|
          child = value.is_a?(Hash) ? value.fetch(name) : value.fetch(type.fields.index { |entry| entry.first == name })
          typed_signature(child_type, child)
        end
        "T(#{children.join(',')})"
      else
        fail!("unknown oracle type #{type.kind.inspect}")
      end
    end

    def expected_signatures(kind)
      ROWS.fetch(kind).map { |value| typed_signature(TYPE_DEFS.fetch(kind), value) }
    end

    def capture_helper_read!(label, case_id, kind, mark_format, part_path)
      return {status: 'unavailable_stock_part'} unless part_path
      invocation = invoke_helper(label, 'read', kind, mark_format, part_path)
      validate_helper_report!(invocation, case_id, kind, mark_format, 'read', expected_part_path: part_path)
    end

    def capture_generated!(id, kind, mark_format)
      part = File.join(@root, 'parts', id, W277::PART_NAME)
      Dir.mkdir(File.dirname(part), 0o700)
      write = invoke_helper("#{id}_helper_write", 'write', kind, mark_format, part)
      unless write[:state] == 'success'
        return {
          status: classify_helper_error(write), error: write[:report] || write[:error],
          invocation: write[:invocation], partial_inventory: safe_partial_inventory(part),
        }
      end
      report_check = validate_helper_report!(write, id, kind, mark_format, 'write', expected_part_path: part)
      inventory = send(:tree_inventory, part)
      expected_mark = send(:mark_filename, mark_format, 'plain')
      fail!("#{id} generated part lacks expected plain #{mark_format} marks") unless
        inventory.fetch(:files).any? { |file| file.fetch(:path) == expected_mark } &&
        !inventory.fetch(:files).any? { |file| %w[data.cmrk3 data.cmrk4].include?(file.fetch(:path)) }
      roster = send(:native_callback_roster!, "#{id}_generated", part, mark_format, kind)
      metadata = raw_serialization_metadata!("#{id}_generated", part)
      snapshot = send(:save_part_snapshot!, "#{id}_generated", part, inventory, roster, metadata)
      target = create_target!(id, kind, mark_format)
      unless target[:state] == 'ready'
        return {
          status: target.fetch(:status), helper_report: report_check, helper_invocation: write[:invocation],
          part_path: part, inventory: inventory, part_snapshot: snapshot, callback_roster: roster,
          serialization_metadata: metadata, native_target: target,
        }
      end
      attached = send(:attach_candidate!, id, part, inventory, target)
      unless attached[:state] == 'attached'
        return {
          status: 'generated_attach_rejection_captured', helper_report: report_check,
          helper_invocation: write[:invocation], part_path: part, inventory: inventory,
          part_snapshot: snapshot, callback_roster: roster, serialization_metadata: metadata,
          native_target: target, attach: attached,
        }
      end
      check = send(:check!, "#{id}_attached", target.fetch(:table), target.fetch(:store))
      active = inspect_schema_part!("#{id}_attached", target.fetch(:table), target.fetch(:store), kind, mark_format)
      active_part = active[:part]
      fail!("#{id} generated ATTACH has no active part") unless active_part
      active_inventory = active_part.dig(:raw_capture, :inventory)
      sidecar_path = File.join(active_part.fetch(:path), ATTACHED_NATIVE_SIDECAR_PATH)
      fail!("#{id} pinned native ATTACH sidecar is absent, non-regular, or symlinked") unless
        File.file?(sidecar_path) && !File.symlink?(sidecar_path)
      attached_inventory_contract = validate_attached_inventory_contract!(
        id, inventory, active_inventory, File.binread(sidecar_path)
      )
      native_windows = WINDOWS.keys.to_h do |window|
        [window, read_window!("#{id}_attached", target.fetch(:table), target.fetch(:store), kind, window)]
      end
      fail!("#{id} source part changed during ATTACH/CHECK/native reads") unless send(:tree_inventory, part) == inventory
      native_exact = active.dig(:part) && check.fetch(:state) == 'healthy' &&
        native_windows.values.all? { |entry| entry[:state] == 'exact_values' }
      {
        status: native_exact ? 'exact_generated_native_interop' : 'generated_native_interop_incomplete',
        helper_report: report_check, helper_invocation: write[:invocation], part_path: part,
        inventory: inventory, part_snapshot: snapshot, callback_roster: roster,
        serialization_metadata: metadata, native_target: target, attach: attached, check: check,
        active_part: active, attached_inventory_contract: attached_inventory_contract,
        native_windows: native_windows,
      }
    end

    def safe_partial_inventory(part)
      return nil unless File.directory?(part) && !File.symlink?(part)
      send(:tree_inventory, part)
    rescue StandardError => error
      {error: "#{error.class}: #{error.message}"}
    end

    def validate_attached_inventory_contract!(id, generated_inventory, attached_inventory, sidecar_bytes)
      generated_files = inventory_files_by_path!(id, generated_inventory, 'generated')
      attached_files = inventory_files_by_path!(id, attached_inventory, 'attached')

      generated_files.each do |path, entry|
        fail!("#{id} ATTACH changed or omitted generated file #{path.inspect}") unless attached_files[path] == entry
      end

      extra_paths = attached_files.keys - generated_files.keys
      fail!("#{id} ATTACH added files outside the pinned native sidecar: #{extra_paths.inspect}") unless
        extra_paths == [ATTACHED_NATIVE_SIDECAR_PATH]
      fail!("#{id} ATTACH native sidecar inventory entry differs") unless
        attached_files.fetch(ATTACHED_NATIVE_SIDECAR_PATH) == ATTACHED_NATIVE_SIDECAR_ENTRY
      fail!("#{id} ATTACH native sidecar bytes differ") unless sidecar_bytes == ATTACHED_NATIVE_SIDECAR_BYTES

      {
        state: ATTACHED_INVENTORY_CONTRACT_STATE,
        generated_file_count: generated_files.size,
        native_sidecar: ATTACHED_NATIVE_SIDECAR_ENTRY,
      }
    rescue KeyError, TypeError, NoMethodError => error
      fail!("#{id} ATTACH inventory contract is incomplete: #{error.class}: #{error.message}")
    end

    def inventory_files_by_path!(id, inventory, origin)
      fail!("#{id} #{origin} inventory is malformed") unless inventory.is_a?(Hash) &&
        inventory.fetch(:files).is_a?(Array) && inventory.fetch(:total_bytes).is_a?(Integer)
      files = inventory.fetch(:files)
      paths = files.map do |entry|
        fail!("#{id} #{origin} inventory entry is malformed") unless entry.is_a?(Hash) &&
          entry.keys.sort == %i[path sha256 size].sort && entry.fetch(:path).is_a?(String) &&
          entry.fetch(:size).is_a?(Integer) && entry.fetch(:size) >= 0 &&
          entry.fetch(:sha256).match?(/\A[0-9a-f]{64}\z/)
        entry.fetch(:path)
      end
      fail!("#{id} #{origin} inventory paths are duplicated or not canonical") unless paths.uniq == paths && paths == paths.sort
      fail!("#{id} #{origin} inventory byte total differs") unless inventory.fetch(:total_bytes) == files.sum { |entry| entry.fetch(:size) }
      files.to_h { |entry| [entry.fetch(:path), entry] }
    rescue KeyError, TypeError, NoMethodError => error
      fail!("#{id} #{origin} inventory is incomplete: #{error.class}: #{error.message}")
    end

    def self_test_attached_inventory_contract!
      fail!('pinned native sidecar bytes do not match their size/hash') unless
        ATTACHED_NATIVE_SIDECAR_BYTES.bytesize == ATTACHED_NATIVE_SIDECAR_ENTRY.fetch(:size) &&
        Digest::SHA256.hexdigest(ATTACHED_NATIVE_SIDECAR_BYTES) == ATTACHED_NATIVE_SIDECAR_ENTRY.fetch(:sha256)

      generated = {
        files: [
          {path: 'count.txt', size: 1, sha256: 'a' * 64},
          {path: 'data.bin', size: 8, sha256: 'b' * 64},
        ],
        total_bytes: 9,
      }
      attached = {
        files: (generated.fetch(:files) + [ATTACHED_NATIVE_SIDECAR_ENTRY]).sort_by { |entry| entry.fetch(:path) },
        total_bytes: generated.fetch(:total_bytes) + ATTACHED_NATIVE_SIDECAR_ENTRY.fetch(:size),
      }
      valid = validate_attached_inventory_contract!('self_test_valid', generated, attached,
                                                     ATTACHED_NATIVE_SIDECAR_BYTES)
      fail!('valid generated-byte preservation/native-sidecar seed was rejected') unless
        valid.fetch(:state) == ATTACHED_INVENTORY_CONTRACT_STATE && valid.fetch(:generated_file_count) == 2

      missing = Marshal.load(Marshal.dump(attached))
      missing[:files].delete_if { |entry| entry.fetch(:path) == 'data.bin' }
      missing[:total_bytes] -= 8
      self_test_reject_inventory!('missing generated file') do
        validate_attached_inventory_contract!('self_test_missing', generated, missing, ATTACHED_NATIVE_SIDECAR_BYTES)
      end

      mutated = Marshal.load(Marshal.dump(attached))
      mutated[:files].find { |entry| entry.fetch(:path) == 'data.bin' }[:sha256] = 'c' * 64
      self_test_reject_inventory!('mutated generated file entry') do
        validate_attached_inventory_contract!('self_test_mutated', generated, mutated, ATTACHED_NATIVE_SIDECAR_BYTES)
      end

      unexpected = Marshal.load(Marshal.dump(attached))
      unexpected[:files] << {path: 'unexpected.txt', size: 1, sha256: 'd' * 64}
      unexpected[:files].sort_by! { |entry| entry.fetch(:path) }
      unexpected[:total_bytes] += 1
      self_test_reject_inventory!('unexpected attached extra') do
        validate_attached_inventory_contract!('self_test_extra', generated, unexpected, ATTACHED_NATIVE_SIDECAR_BYTES)
      end

      altered_sidecar = Marshal.load(Marshal.dump(attached))
      altered_sidecar[:files].find { |entry| entry.fetch(:path) == ATTACHED_NATIVE_SIDECAR_PATH }[:sha256] = 'e' * 64
      self_test_reject_inventory!('altered native sidecar entry') do
        validate_attached_inventory_contract!('self_test_sidecar_entry', generated, altered_sidecar,
                                              ATTACHED_NATIVE_SIDECAR_BYTES)
      end
      self_test_reject_inventory!('altered native sidecar bytes') do
        validate_attached_inventory_contract!('self_test_sidecar_bytes', generated, attached,
                                              ATTACHED_NATIVE_SIDECAR_BYTES + 'x')
      end
      true
    end

    def self_test_reject_inventory!(label)
      yield
    rescue Failure
      true
    else
      fail!("attachment inventory self-test accepted #{label}")
    end

    def classify_helper_error(invocation)
      report = invocation[:report]
      error = report.is_a?(Hash) ? "#{report['error_class']} #{report['error']}" : invocation[:error].to_s
      if error.match?(/UnsupportedFormatError|outside (the )?(captured|admitted)|not admitted/i)
        'library_admission_rejection_captured'
      elsif invocation[:state] == 'infrastructure_failure'
        'helper_infrastructure_failure'
      else
        'library_writer_or_reader_rejection_captured'
      end
    end

    def invoke_helper(label, action, kind, mark_format, part)
      argv = [@helper, action, kind, mark_format, part]
      send(:register_expected!, label, argv, ''.b, 'crystal-helper', @helper, @helper_sha_before, nil)
      result = @runner.send(:run_process, label, argv, ''.b, 'crystal-helper',
                            expected_sha: @helper_sha_before, binary_path: @helper)
      record = result.fetch(:record)
      process_ok = !record[:timed_out] && record[:spawn_error].nil? && record[:stdin_write_error].nil? &&
        record[:stdout_read_error].nil? && record[:stderr_read_error].nil? && result[:status] && result[:status].termsig.nil?
      parsed = begin
        text = result.fetch(:stdout).dup.force_encoding(Encoding::UTF_8)
        raise JSON::ParserError, 'helper stdout is not valid UTF-8' unless text.valid_encoding?
        JSON.parse(text)
      rescue JSON::ParserError => error
        {parse_error: "#{error.class}: #{error.message}"}
      end
      state = if !process_ok
                'infrastructure_failure'
              elsif result[:classification] == 'success' && result[:status].success? && parsed.is_a?(Hash) && parsed['status'] == 'ok'
                'success'
              elsif parsed.is_a?(Hash) && parsed['status'] == 'error'
                'application_error'
              else
                'process_failure'
              end
      {state: state, report: parsed, error: state == 'success' ? nil : result[:stderr],
       invocation: send(:stage_summary, result)}
    end

    def validate_helper_report!(invocation, case_id, kind, mark_format, action, expected_part_path:)
      unless invocation[:state] == 'success'
        return {status: classify_helper_error(invocation), error: invocation[:report] || invocation[:error],
                invocation: invocation[:invocation]}
      end
      report = invocation.fetch(:report)
      expected_schema = schema_for(kind).last.last.gsub(/\s+/, '')
      expected_part_origin = action == 'read' ? 'stock' : 'generated'
      fail!("#{case_id} helper report envelope differs") unless report.fetch('format') == HELPER_FORMAT &&
        report.fetch('action') == action && report.fetch('case') == kind && report.fetch('mark_format') == mark_format &&
        report.fetch('status') == 'ok' && report.fetch('row_count') == ROW_COUNT &&
        report.fetch('data_mark_count') == DATA_MARK_COUNT && report.fetch('part_origin') == expected_part_origin &&
        report.fetch('public_reader_grid') == 'nonempty_data_marks' &&
        report.fetch('public_reader_mark_count') == DATA_MARK_COUNT &&
        report.fetch('public_reader_mark_rows') == PUBLIC_READER_MARK_ROWS &&
        report.fetch('part_path') == expected_part_path &&
        report.fetch('schema').gsub(/\s+/, '') == expected_schema
      signatures = expected_signatures(kind)
      windows = {
        'full' => signatures,
        'middle' => signatures.drop(2).take(4),
        'last' => signatures.drop(6).take(2),
        'eof' => [],
      }
      recursive = report.fetch('recursive_windows')
      typed = report.fetch('typed_windows')
      fail!("#{case_id} helper returned a different recursive-window roster") unless recursive.keys.sort == windows.keys.sort
      fail!("#{case_id} helper returned a different typed-window roster") unless typed.keys.sort == windows.keys.sort
      windows.each do |window, expected|
        recursive_entry = recursive.fetch(window)
        typed_entry = typed.fetch(window)
        fail!("#{case_id}/#{window} recursive public reader differs from the independent oracle") unless
          recursive_entry.fetch('signatures') == expected && recursive_entry.fetch('first_mark') == PHYSICAL_WINDOWS.fetch(window)[0] &&
          recursive_entry.fetch('mark_count') == PHYSICAL_WINDOWS.fetch(window)[1]
        fail!("#{case_id}/#{window} typed facade differs from the independent oracle") unless
          typed_entry.fetch('signatures') == expected && typed_entry.fetch('start_row') == TYPED_WINDOWS.fetch(window)[0] &&
          typed_entry.fetch('row_count') == expected.size
      end
      {status: 'exact_public_recursive_and_typed_reads', report: report, invocation: invocation.fetch(:invocation)}
    rescue KeyError, TypeError, NoMethodError => error
      fail!("#{case_id} helper report is incomplete: #{error.class}: #{error.message}")
    end

    def helper_report_for_test(kind, action:)
      signatures = expected_signatures(kind)
      recursive_windows = PHYSICAL_WINDOWS.to_h do |window, (first_mark, mark_count)|
        selected = case window
                   when 'full' then signatures
                   when 'middle' then signatures.drop(2).take(4)
                   when 'last' then signatures.drop(6).take(2)
                   else []
                   end
        [window, {'signatures' => selected, 'first_mark' => first_mark, 'mark_count' => mark_count}]
      end
      typed_windows = TYPED_WINDOWS.to_h do |window, (start_row, _max_rows)|
        selected = case window
                   when 'full' then signatures
                   when 'middle' then signatures.drop(2).take(4)
                   when 'last' then signatures.drop(6).take(2)
                   else []
                   end
        [window, {'signatures' => selected, 'start_row' => start_row, 'row_count' => selected.size}]
      end
      {
        'format' => HELPER_FORMAT, 'action' => action, 'case' => kind, 'mark_format' => 'mrk3',
        'status' => 'ok', 'row_count' => ROW_COUNT, 'data_mark_count' => DATA_MARK_COUNT,
        'part_origin' => action == 'read' ? 'stock' : 'generated',
        'public_reader_grid' => 'nonempty_data_marks',
        'public_reader_mark_count' => DATA_MARK_COUNT,
        'public_reader_mark_rows' => PUBLIC_READER_MARK_ROWS,
        'part_path' => '/tmp/w280-self-test/part',
        'schema' => schema_for(kind).last.last, 'recursive_windows' => recursive_windows,
        'typed_windows' => typed_windows,
      }
    end

    def self_test_rejects_malformed_helper_reports!
      %w[read write].each do |action|
        seed = helper_report_for_test('nested_five_sites', action: action)
        valid = validate_helper_report!({state: 'success', report: seed, invocation: {}},
                                        "self_test_valid_#{action}", 'nested_five_sites', 'mrk3', action,
                                        expected_part_path: seed.fetch('part_path'))
        fail!("Ruby validator rejected valid #{action} helper grid") unless
          valid.fetch(:status) == 'exact_public_recursive_and_typed_reads'

        wrong_public_grid = JSON.parse(JSON.generate(seed))
        wrong_public_grid['public_reader_grid'] = 'raw_mark_file_including_eof'
        wrong_public_grid['public_reader_mark_count'] = RAW_MARK_FILE_ROWS.size
        wrong_public_grid['public_reader_mark_rows'] = RAW_MARK_FILE_ROWS
        begin
          validate_helper_report!({state: 'success', report: wrong_public_grid, invocation: {}},
                                  "self_test_raw_public_grid_confusion_#{action}", 'nested_five_sites', 'mrk3', action,
                                  expected_part_path: seed.fetch('part_path'))
        rescue Failure
          next
        end
        raise Failure, "Ruby validator accepted raw mark-file rows as public reader rows for #{action}"
      end

      seed = helper_report_for_test('nested_five_sites', action: 'write')
      mutations = {
        'envelope' => ->(report) { report['format'] = 'wrong_format' },
        'part path' => ->(report) { report['part_path'] = '/tmp/w280-self-test/other-part' },
        'window roster' => ->(report) { report['recursive_windows'].delete('eof') },
        'physical window coordinates' => ->(report) { report['recursive_windows']['middle']['first_mark'] = 0 },
        'recursive signature' => ->(report) { report['recursive_windows']['full']['signatures'][0] = 'T(A[],A[],Jwrong)' },
        'typed signature' => ->(report) { report['typed_windows']['last']['signatures'][0] = 'T(A[],A[],Jwrong)' },
        'EOF output cardinality' => ->(report) { report['typed_windows']['eof']['row_count'] = 1 },
      }
      mutations.each do |label, mutate|
        report = JSON.parse(JSON.generate(seed))
        mutate.call(report)
        begin
          validate_helper_report!({state: 'success', report: report, invocation: {}},
                                  "self_test_#{label.gsub(/\W+/, '_')}", 'nested_five_sites', 'mrk3', 'write',
                                  expected_part_path: seed.fetch('part_path'))
        rescue Failure
          next
        end
        raise Failure, "Ruby validator accepted malformed helper #{label}"
      end
      true
    end

    # These overrides keep matrix-native calls on the independently pinned
    # W280 runtime and pin parser; inherited W276 methods use its stale pin.
    def check!(id, table, store)
      begin_tag = marker('check_begin', id)
      end_tag = marker('check_end', id)
      sql = "SELECT '#{begin_tag}' FORMAT TSVRaw;\nCHECK TABLE default.#{table} FORMAT TSV;\nSELECT '#{end_tag}' FORMAT TSVRaw;\n"
      result = execute_sql!("#{id}_check", store, sql)
      unless send(:success?, result)
        return {state: send(:result_class, result), invocation: send(:stage_summary, result)}
      end
      lines = pinned_lines(result, "#{id} matrix CHECK")
      expected = [begin_tag, "#{W280::PART_NAME}\t1\t", end_tag]
      fail!("#{id} CHECK output differs: #{lines.inspect}") unless lines == expected
      {state: 'healthy', rows: [expected[1]], invocation: send(:stage_summary, result)}
    end

    def attach_candidate!(id, part, inventory, target)
      @runner.send(:attach_part!, part, target.fetch(:data_path))
      detached = File.join(target.fetch(:data_path), 'detached', W280::PART_NAME)
      detached_inventory = send(:tree_inventory, detached)
      fail!("#{id} detached copy differs from immutable candidate") unless detached_inventory == inventory
      sql = "ALTER TABLE default.#{target.fetch(:table)} ATTACH PART '#{W280::PART_NAME}';\n"
      result = execute_sql!("#{id}_attach", target.fetch(:store), sql)
      return {state: send(:result_class, result), invocation: send(:stage_summary, result),
              source_inventory: inventory, detached_inventory: detached_inventory} unless send(:success?, result)
      lines = pinned_lines(result, "#{id} matrix ATTACH")
      fail!("#{id} ATTACH emitted unexpected output: #{lines.inspect}") unless lines.empty?
      {state: 'attached', invocation: send(:stage_summary, result),
       source_inventory: inventory, detached_inventory: detached_inventory}
    end

    def create_target!(id, kind, mark_format)
      table = table_name("target_#{id}")
      store = send(:store_path, "target_#{id}")
      schema_tag = marker('target_schema', id)
      path_tag = marker('target_path', id)
      sql = create_sql(table, kind, mark_format) +
        "SELECT '#{schema_tag}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;\n" \
        "SELECT '#{path_tag}', arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw;\n"
      result = execute_sql!("#{id}_target_create", store, sql)
      unless send(:success?, result)
        captured_pin = begin
          pinned_lines(result, "#{id} rejected generated target")
        rescue StandardError => error
          {pin_error: "#{error.class}: #{error.message}"}
        end
        return {state: send(:result_class, result),
                status: send(:result_class, result) == 'server_exception' ? 'generated_native_target_rejection_captured' : 'generated_native_target_infrastructure_failure',
                output: captured_pin, create: send(:stage_summary, result), table: table, store: store}
      end
      lines = pinned_lines(result, "#{id} generated target")
      schema = tagged(lines, schema_tag, 3).map { |row| [row[1], row[2].gsub(/\s+/, '')] }
      expected_schema = schema_for(kind).map { |name, type| [name, type.gsub(/\s+/, '')] }
      fail!("#{id} native target schema differs") unless send(:success?, result) && schema == expected_schema
      paths = tagged(lines, path_tag, 2)
      fail!("#{id} target table path is not unique") unless paths.size == 1 && !paths.first[1].empty?
      data_path = send(:safe_native_path, paths.first[1], store, "#{id} generated target")
      {state: 'ready', table: table, store: store, data_path: data_path, create: send(:stage_summary, result)}
    end

    def raw_serialization_metadata!(id, part)
      path = File.join(part, 'serialization.json')
      fail!("#{id} serialization metadata is missing, symlinked, or oversized") unless
        File.file?(path) && !File.symlink?(path) && File.size(path) <= W277::MAX_RAW_FILE_BYTES
      raw = File.binread(path)
      parsed = JSON.parse(raw)
      {raw: raw, raw_sha256: Digest::SHA256.hexdigest(raw), parsed: parsed}
    rescue JSON::ParserError => error
      fail!("#{id} serialization metadata is malformed: #{error.message}")
    end

    def build_summary
      stock_exact = @cases.size == CASES.size * MARK_FORMATS.size &&
        @cases.values.all? { |entry| entry.fetch(:status) == 'exact_native_values' }
      control_exact = MARK_FORMATS.all? { |mark| @cases.fetch("array_json_#{mark}")[:status] == 'exact_native_values' }
      only_rejections = @cases.values.all? do |entry|
        %w[exact_native_values create_server_exception insert_server_exception].include?(entry[:status])
      end
      stock_rejection_control = !stock_exact && control_exact && only_rejections &&
        @cases.values.any? { |entry| entry[:status] == 'create_server_exception' || entry[:status] == 'insert_server_exception' }
      generated_exact = @full_matrix && @cases.size == CASES.size * MARK_FORMATS.size &&
        @cases.values.all? do |entry|
          entry[:status] == 'exact_native_values' && entry.dig(:library_stock_read, :status) == 'exact_public_recursive_and_typed_reads' &&
            entry.dig(:library_generated, :status) == 'exact_generated_native_interop'
        end
      all_generated_admission_rejections = @full_matrix && @cases.values.all? do |entry|
        entry.dig(:library_generated, :status) == 'library_admission_rejection_captured'
      end
      status = if generated_exact
                 'generated_native_interop_matrix_exact'
               elsif @full_matrix && all_generated_admission_rejections
                 'generated_admission_rejection_captured'
               elsif !@full_matrix && stock_exact
                 'stock_native_matrix_exact'
               elsif !@full_matrix && stock_rejection_control
                 'stock_type_rejection_control_exact'
               elsif @cases.values.any? { |entry| entry[:status].to_s.include?('infrastructure_failure') }
                 'probe_infrastructure_failure'
               else
                 'incomplete_or_discrepant'
               end
      {
        format: FORMAT, status: status,
        execution_scope: 'Stock-only mode uses independently declared Ruby RowBinary values. Full-matrix mode captures every stock case first, then reads stock parts with both public Crystal readers, writes independent generated parts with the public Compact writer, and validates generated-file byte preservation plus the exact pinned native ATTACH sidecar, CHECK, and value windows.',
        runtime_pin: {binary: @binary, expected_sha256: W280::BINARY_SHA256, sha256_before: @binary_sha_before,
                      sha256_after: @binary_sha_after, version: W280::VERSION, build: W280::BUILD},
        source_pin: {root: @source_root, revision_expected: W280::SOURCE_REVISION,
                     revision_before: @source_revision_before, revision_after: @source_revision_after,
                     source_sha256_before: @upstream_hashes_before, source_sha256_after: @upstream_hashes_after},
        helper_pin: @full_matrix ? {path: @helper, expected_sha256: @helper_sha_argument,
                                    sha256_before: @helper_sha_before, sha256_after: @helper_sha_after,
                                    source: HELPER_SOURCE} : nil,
        matrix_source_pins: {sha256_before: @local_source_hashes_before, sha256_after: @local_source_hashes_after},
        schema_parameters: {object_serialization_version: 'v3', object_shared_data_serialization_version: 'map',
                            map_layout_value: 0, object_shared_data_buckets_for_compact_part: 1,
                            string_serialization_version: 'single_stream (S0)', mark_compression: 'plain',
                            variant_discriminator_mode: 'basic', mark_formats: MARK_FORMATS},
        fixture: {schemas: SCHEMAS, json_site_counts: JSON_SITE_COUNTS,
                  json_site_domain_counts: CASES.to_h { |kind| [kind, json_site_domain_counts(kind)] }, literal_rows: ROWS,
                  row_count: ROW_COUNT, rows_per_mark: ROWS_PER_MARK, data_marks: DATA_MARK_COUNT,
                  raw_mark_file_rows: RAW_MARK_FILE_ROWS,
                  public_reader_mark_rows: PUBLIC_READER_MARK_ROWS,
                  native_windows: WINDOWS, physical_windows: PHYSICAL_WINDOWS, typed_windows: TYPED_WINDOWS,
                  rowbinary_input: 'UInt64 pk followed by independently encoded recursive JSON/Array/Tuple/UInt8 values; JSON contains only typed id UInt64'},
        cases: @cases,
        invocation_roster: @invocations.map do |record|
          {label: record.fetch(:label), process_kind: record.fetch(:process_kind), binary_path: record.fetch(:binary_path),
           store_path: record.fetch(:store_path), argv: record.fetch(:argv), stdin_file: record.fetch(:stdin_file),
           argv_file: record.fetch(:argv_file), stdout_file: record.fetch(:stdout_file), stderr_file: record.fetch(:stderr_file),
           record_file: "#{record.fetch(:label)}.json"}
        end,
        evidence_root: @root,
        claim_boundary: 'Finite five-shape, eight-row, four-data-mark evidence in plain/S0/MAP0/basic under MRK3 and MRK4. Stock create/insert rejection remains a classified native observation; only the Array(JSON) case is a positive control. Full generated success requires helper reports for recursive and typed reads at full/middle/last/EOF, exact generated source inventory/callback/metadata snapshots, byte-for-byte preservation of every generated file through ATTACH, exactly one pinned native invalidated_system_columns.txt sidecar with exact bytes, and matching native CHECK/value projections. A captured helper admission rejection is RED and does not admit the schema or implementation. No arbitrary type-topology or performance claim.',
      }
    end

    def render_summary(summary)
      lines = [
        '# W280 Compact recursive Array JSON matrix', '',
        "Status: `#{summary.fetch(:status)}`",
        "Runtime: `#{W280::VERSION}` build `#{W280::BUILD}` SHA-256 `#{W280::BINARY_SHA256}`.",
        "Source: `#{W280::SOURCE_REVISION}` at `#{W280::SOURCE_ROOT}` (separate pin).",
        'Stock cases are captured before any helper reads or generated writes; every case has eight rows and four two-row data marks.',
      ]
      @cases.each do |id, entry|
        generated = entry[:library_generated]&.fetch(:status, nil)
        lines << "- #{id}: stock `#{entry.fetch(:status)}`; generated `#{generated || 'not run'}`."
      end
      lines.concat(['', summary.fetch(:claim_boundary), ''])
      lines.join("\n")
    end

    def validate_process_evidence!
      fail!('process invocation roster differs from registered commands') unless
        @invocations.map { |item| item.fetch(:label) }.sort == @expected_processes.keys.sort
      expected_files = []
      @invocations.each do |record|
        label = record.fetch(:label)
        expected = @expected_processes.fetch(label)
        base = File.join(@root, 'invocations')
        encoding = expected.fetch(:stdin_encoding, expected.fetch(:process_kind) == 'clickhouse-local' ? 'sql' : 'binary')
        stdin_name = "#{label}.stdin.#{encoding == 'sql' ? 'sql' : encoding == 'rowbinary' ? 'bin' : 'bin'}"
        argv_name = "#{label}.argv.json"
        stdout_name = "#{label}.stdout"
        stderr_name = "#{label}.stderr"
        record_name = "#{label}.json"
        expected_files.concat([stdin_name, argv_name, stdout_name, stderr_name, record_name])
        argv_bytes = JSON.pretty_generate(expected.fetch(:argv)) + "\n"
        fail!("#{label} argv sidecar differs") unless File.binread(File.join(base, argv_name)) == argv_bytes &&
          record.fetch(:argv) == expected.fetch(:argv) && record.fetch(:argv_sha256) == Digest::SHA256.hexdigest(argv_bytes)
        stdin = File.binread(File.join(base, stdin_name))
        fail!("#{label} exact stdin sidecar differs") unless stdin == expected.fetch(:stdin) &&
          record.fetch(:stdin_bytes) == stdin.bytesize && record.fetch(:stdin_sha256) == Digest::SHA256.hexdigest(stdin)
        stdout = File.binread(File.join(base, stdout_name))
        stderr = File.binread(File.join(base, stderr_name))
        fail!("#{label} stdout/stderr sidecar checksums differ") unless
          record.fetch(:stdout_bytes) == stdout.bytesize && record.fetch(:stdout_sha256) == Digest::SHA256.hexdigest(stdout) &&
          record.fetch(:stderr_bytes) == stderr.bytesize && record.fetch(:stderr_sha256) == Digest::SHA256.hexdigest(stderr)
        expected_binary = expected.fetch(:binary_path)
        expected_sha = expected.fetch(:expected_sha256)
        fail!("#{label} process identity differs from the registered binary") unless
          record.fetch(:process_kind) == expected.fetch(:process_kind) && record.fetch(:binary_path) == expected_binary &&
          record.fetch(:expected_binary_sha256) == expected_sha && record.fetch(:binary_sha_before) == expected_sha &&
          record.fetch(:binary_sha_after) == expected_sha && record.fetch(:store_path) == expected.fetch(:store_path)
        saved = JSON.parse(File.binread(File.join(base, record_name)))
        fail!("#{label} persisted process record differs") unless saved == JSON.parse(JSON.generate(record))
      end
      fail!('invocation sidecar directory has unregistered files') unless
        Dir.children(File.join(@root, 'invocations')).sort == expected_files.sort
      true
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  options = {
    binary: ProbeCompactRecursiveArraysW280Matrix::W280::BINARY,
    source_root: ProbeCompactRecursiveArraysW280Matrix::W280::SOURCE_ROOT,
    evidence_root: nil, stock_only: false, full_matrix: false, helper: nil, helper_sha256: nil,
    self_test: false,
  }
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/probe_compact_recursive_arrays_w280_matrix.rb (--stock-only | --full-matrix --helper PREBUILT --helper-sha256 SHA256) --evidence-root EMPTY_DIR'
    parser.on('--stock-only', 'Capture the independent stock/native matrix only') { options[:stock_only] = true }
    parser.on('--full-matrix', 'Run stock-first public-reader/generated-writer/native interop matrix') { options[:full_matrix] = true }
    parser.on('--helper PATH', 'Prebuilt W280 Crystal helper; full-matrix only') { |value| options[:helper] = value }
    parser.on('--helper-sha256 SHA256', 'Exact lowercase SHA-256 of the prebuilt helper') { |value| options[:helper_sha256] = value }
    parser.on('--evidence-root EMPTY_DIR', 'Existing empty direct child of /private/tmp') { |value| options[:evidence_root] = value }
    parser.on('--binary PATH', 'Separately pinned ClickHouse runtime executable') { |value| options[:binary] = value }
    parser.on('--source-root PATH', 'Separately pinned upstream ClickHouse checkout') { |value| options[:source_root] = value }
    parser.on('--self-test', 'Run only Ruby literal/schema/RowBinary oracle checks; no native or Crystal processes') { options[:self_test] = true }
  end.parse!

  if options[:self_test]
    exit(ProbeCompactRecursiveArraysW280Matrix::Probe.self_test! ? 0 : 1)
  end
  unless options[:evidence_root] && options[:stock_only] != options[:full_matrix]
    warn 'W280 matrix: choose exactly one mode and provide --evidence-root'
    exit 2
  end
  if options[:full_matrix] && (!options[:helper] || !options[:helper_sha256])
    warn 'W280 matrix: --full-matrix requires --helper and --helper-sha256'
    exit 2
  end
  if options[:stock_only] && (options[:helper] || options[:helper_sha256])
    warn 'W280 matrix: helper options are valid only with --full-matrix'
    exit 2
  end
  exit(ProbeCompactRecursiveArraysW280Matrix::Probe.new(**options.reject { |key, _| key == :self_test }).run ? 0 : 1)
end
