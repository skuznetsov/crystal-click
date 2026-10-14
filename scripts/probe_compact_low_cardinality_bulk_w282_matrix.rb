#!/usr/bin/env ruby
# Stock-first native oracle for LowCardinality inside recursive JSON. The
# RowBinary input and expected signatures below are independent Ruby literals.

require 'json'
require 'optparse'
require_relative 'probe_compact_static_bulk_w281_matrix'

module ProbeCompactLowCardinalityBulkW282Matrix
  W281M = ProbeCompactStaticBulkW281Matrix
  W280M = W281M::W280M
  W280 = W281M::W280
  W277 = W281M::W277

  FORMAT = 'compact_low_cardinality_bulk_w282_matrix_v1'.freeze
  HELPER_FORMAT = 'compact_low_cardinality_bulk_w282_helper_v1'.freeze
  PROBE_SOURCE = File.expand_path(__FILE__).freeze
  HELPER_SOURCE = File.expand_path('compact_low_cardinality_bulk_w282_helper.cr', __dir__).freeze
  FIXTURE_SOURCE = File.expand_path('../spec/support/compact_part_writer_w282_fixture.cr', __dir__).freeze

  CASE = 'stock_bulk'.freeze
  COLUMN = 'recursive_lc_w282'.freeze
  JSON_DECLARATION = 'JSON(max_dynamic_types=0, max_dynamic_paths=0, id UInt64)'.freeze
  TYPE = "Tuple(#{JSON_DECLARATION}, Array(Tuple(LowCardinality(String), LowCardinality(Nullable(String)))), " \
         "#{JSON_DECLARATION}, Tuple(Map(String, LowCardinality(UInt16)), Array(LowCardinality(String)), " \
         'Nested(label LowCardinality(String), code LowCardinality(UInt16))))'.freeze
  SCHEMAS = {CASE => [['pk', 'UInt64'], [COLUMN, TYPE]].map(&:freeze).freeze}.freeze

  MARK_FORMATS = %w[mrk3 mrk4].freeze
  PROFILES = %w[s0 s1].freeze
  ROW_COUNT = 8
  ROWS_PER_MARK = 2
  DATA_MARK_COUNT = 4
  RAW_MARK_ROWS = [2, 2, 2, 2, 0].freeze
  PUBLIC_MARK_ROWS = [2, 2, 2, 2].freeze
  WINDOWS = {
    'full' => nil, 'middle' => 'pk BETWEEN 3 AND 6',
    'last' => 'pk BETWEEN 7 AND 8', 'eof' => 'pk > 8',
  }.freeze
  PHYSICAL_WINDOWS = {'full' => [0, 4], 'middle' => [1, 2], 'last' => [3, 1], 'eof' => [4, 0]}.freeze
  TYPED_WINDOWS = {'full' => [0, 8], 'middle' => [2, 4], 'last' => [6, 2], 'eof' => [8, 0]}.freeze

  # Site names and order are the serializer DFS through the literal outer
  # Tuple: JSON, Bulk A's Array/Tuple, JSON, then Bulk B's Tuple/Map/Array/Nested.
  LC_SITE_DFS = %w[
    bulk_a_array_tuple_first_string
    bulk_a_array_tuple_second_nullable_string
    bulk_b_map_value_uint16
    bulk_b_array_string
    bulk_b_nested_label_string
    bulk_b_nested_code_uint16
  ].freeze
  EMPTY_LC_SITE = 'bulk_b_array_string'.freeze

  INVALID_BYTES = [0x00, 0xff, 0x80, 0x41].pack('C*').b.freeze
  ROWS = [
    [1, [], 101, [], [], []],
    [2, [], 102, [], [], []],
    [3, [["a\0".b, "n\0".b], [INVALID_BYTES, nil]], 103,
      [["m\0".b, 10], [INVALID_BYTES, 11]], [], [["n\0".b, 65_535]]],
    [4, [['x'.b, ''.b]], 104, [['k'.b, 12]], [], [['bad'.b, 0], ['tail'.b, 42]]],
    [5, [], 105, [], [], []],
    [6, [], 106, [], [], []],
    [7, [['end'.b, 'last'.b]], 107, [['a'.b, 4]], [], [[''.b, 7]]],
    [8, [[''.b, nil], [INVALID_BYTES, "z\0".b]], 108,
      [['b'.b, 5], ['c'.b, 6]], [], [["final\0".b, 8]]],
  ].map { |row| row.freeze }.freeze

  class Failure < StandardError; end

  def self.hex(bytes)
    bytes.unpack1('H*')
  end

  def self.nullable_string_signature(value)
    value.nil? ? 'N' : "V#{hex(value)}"
  end

  def self.row_signature(row)
    left_id, array_a, right_id, map_b, array_b, nested_b = row
    array_a_sig = array_a.map { |text, nullable| "#{hex(text)},#{nullable_string_signature(nullable)}" }.join(';')
    map_b_sig = map_b.map { |key, value| "#{hex(key)}=#{[value].pack('S<').unpack1('H*')}" }.join(';')
    array_b_sig = array_b.map { |value| hex(value) }.join(';')
    nested_b_sig = nested_b.map { |label, code| "#{hex(label)}=#{[code].pack('S<').unpack1('H*')}" }.join(';')
    "#{left_id}|A[#{array_a_sig}]|#{right_id}|M[#{map_b_sig}]|E[#{array_b_sig}]|N[#{nested_b_sig}]"
  end

  def self.literal_lc_occurrences_per_mark
    per_site = LC_SITE_DFS.to_h { |site| [site, []] }
    ROWS.each_slice(ROWS_PER_MARK) do |mark_rows|
      bulk_a_count = mark_rows.sum { |row| row.fetch(1).size }
      map_value_count = mark_rows.sum { |row| row.fetch(3).size }
      bulk_b_array_count = mark_rows.sum { |row| row.fetch(4).size }
      nested_count = mark_rows.sum { |row| row.fetch(5).size }
      per_site.fetch(LC_SITE_DFS.fetch(0)) << bulk_a_count
      per_site.fetch(LC_SITE_DFS.fetch(1)) << bulk_a_count
      per_site.fetch(LC_SITE_DFS.fetch(2)) << map_value_count
      per_site.fetch(LC_SITE_DFS.fetch(3)) << bulk_b_array_count
      per_site.fetch(LC_SITE_DFS.fetch(4)) << nested_count
      per_site.fetch(LC_SITE_DFS.fetch(5)) << nested_count
    end
    per_site
  end

  EXPECTED_SIGNATURES = ROWS.map { |row| row_signature(row) }.freeze
  LC_OCCURRENCES_PER_MARK = {
    'bulk_a_array_tuple_first_string' => [0, 3, 0, 3],
    'bulk_a_array_tuple_second_nullable_string' => [0, 3, 0, 3],
    'bulk_b_map_value_uint16' => [0, 3, 0, 3],
    'bulk_b_array_string' => [0, 0, 0, 0],
    'bulk_b_nested_label_string' => [0, 3, 0, 2],
    'bulk_b_nested_code_uint16' => [0, 3, 0, 2],
  }.freeze

  class Probe < W281M::Probe
    def initialize(binary:, source_root:, evidence_root:, stock_only: false, full_matrix: false,
                   helper: nil, helper_sha256: nil)
      @stock_only = stock_only
      @full_matrix = full_matrix
      @helper_argument = helper
      @helper_sha_argument = helper_sha256
      @active_profile = 's0'
      super(binary: binary, source_root: source_root, evidence_root: evidence_root,
        stock_only: stock_only, full_matrix: full_matrix, helper: helper, helper_sha256: helper_sha256)
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
        PROFILES.each do |profile|
          @active_profile = profile
          id = "#{CASE}_#{mark_format}_#{profile}"
          begin
            @cases[id] = capture_case!(id, CASE, mark_format, profile)
          rescue StandardError => error
            @cases[id] = {case_id: id, schema_kind: CASE, mark_format: mark_format,
                          string_profile: profile, status: 'probe_error',
                          error: "#{error.class}: #{error.message}"}
          end
        end
      end

      if @full_matrix
        @cases.each do |id, entry|
          next unless entry.fetch(:status) == 'exact_native_values'
          @active_profile = entry.fetch(:string_profile)
          entry[:library_stock_read] = capture_helper_read!("#{id}_helper_stock", id, CASE,
            entry.fetch(:mark_format), entry.fetch(:string_profile), entry.dig(:schema_part, :part, :path))
        end
        MARK_FORMATS.each do |mark_format|
          PROFILES.each do |profile|
            @active_profile = profile
            id = "#{CASE}_#{mark_format}_#{profile}"
            begin
              @cases.fetch(id)[:library_generated] = capture_generated!(id, CASE, mark_format)
            rescue StandardError => error
              @cases.fetch(id)[:library_generated] = {status: 'probe_error',
                error: "#{error.class}: #{error.message}"}
            end
          end
        end
      end

      validate_process_evidence!
      validate_pins!
      summary = build_summary
      send(:write_new, File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      send(:write_new, File.join(@root, 'summary.md'), render_summary(summary))
      puts "W282 recursive LowCardinality matrix status=#{summary.fetch(:status)}; " \
           "cases=#{@cases.size}; invocations=#{@invocations.size}; evidence=#{@root}"
      %w[stock_native_matrix_exact stock_schema_rejection_captured
         generated_native_interop_matrix_exact generated_admission_rejection_captured].include?(summary.fetch(:status))
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      persist_inconclusive(error)
      warn "W282 recursive LowCardinality matrix inconclusive: #{@fatal_error}"
      false
    end

    private

    def validate_literals!
      fail!('W282 must retain one exact recursive JSON schema and exactly MRK3/MRK4 × S0/S1') unless
        CASE == 'stock_bulk' && COLUMN == 'recursive_lc_w282' &&
        SCHEMAS.keys == [CASE] && MARK_FORMATS == %w[mrk3 mrk4] && PROFILES == %w[s0 s1]
      fail!('W282 must retain the exact bounded MAP0/BASIC/V3 JSON declarations') unless
        JSON_DECLARATION == 'JSON(max_dynamic_types=0, max_dynamic_paths=0, id UInt64)' &&
        TYPE == "Tuple(#{JSON_DECLARATION}, Array(Tuple(LowCardinality(String), LowCardinality(Nullable(String)))), " \
          "#{JSON_DECLARATION}, Tuple(Map(String, LowCardinality(UInt16)), Array(LowCardinality(String)), " \
          'Nested(label LowCardinality(String), code LowCardinality(UInt16))))'
      fail!('W282 corpus must contain eight rows in four two-row marks plus the zero-row EOF mark') unless
        ROW_COUNT == 8 && ROWS_PER_MARK == 2 && DATA_MARK_COUNT == 4 &&
        RAW_MARK_ROWS == [2, 2, 2, 2, 0] && PUBLIC_MARK_ROWS == [2, 2, 2, 2] && ROWS.size == ROW_COUNT
      fail!('W282 must retain all six LC sites in serializer DFS order') unless
        LC_SITE_DFS.size == 6 && LC_SITE_DFS.uniq == LC_SITE_DFS &&
        LC_OCCURRENCES_PER_MARK.keys == LC_SITE_DFS &&
        LC_OCCURRENCES_PER_MARK.values.all? { |counts| counts.size == DATA_MARK_COUNT }
      derived_occurrences = ProbeCompactLowCardinalityBulkW282Matrix.literal_lc_occurrences_per_mark
      nonempty_lc_sites = LC_SITE_DFS - [EMPTY_LC_SITE]
      zero_nonzero_zero_nonzero = nonempty_lc_sites.all? do |site|
        counts = derived_occurrences.fetch(site)
        counts[0].zero? && counts[1].positive? && counts[2].zero? && counts[3].positive?
      end
      q_differs_from_p = nonempty_lc_sites.any? do |site|
        derived_occurrences.fetch(site).any? { |q| q.positive? && q != ROWS_PER_MARK }
      end
      fail!('W282 mark schedule must derive zero/nonzero occurrences, preserve the empty lane, and include Q != P') unless
        derived_occurrences == LC_OCCURRENCES_PER_MARK &&
        derived_occurrences.fetch(EMPTY_LC_SITE) == [0, 0, 0, 0] &&
        zero_nonzero_zero_nonzero && q_differs_from_p
      fail!('W282 nullable LC values must include NULL, empty, NUL, and invalid UTF-8 bytes') unless
        ROWS.any? { |row| row[1].any? { |_text, nullable| nullable.nil? } } &&
        ROWS.any? { |row| row[1].flatten(1).include?(''.b) } &&
        ROWS.any? { |row| row[1].flatten(1).include?(INVALID_BYTES) }
      fail!('W282 independent signatures must cover each row and differ across identifiers') unless
        EXPECTED_SIGNATURES.size == ROW_COUNT && EXPECTED_SIGNATURES.uniq.size == ROW_COUNT &&
        EXPECTED_SIGNATURES == ROWS.map { |row| ProbeCompactLowCardinalityBulkW282Matrix.row_signature(row) }
      true
    end

    def prepare!
      super
      owned_sources = [PROBE_SOURCE, FIXTURE_SOURCE]
      owned_sources << HELPER_SOURCE if @full_matrix
      @local_source_paths = (@local_source_paths + owned_sources).uniq.sort
      @local_source_hashes_before = @local_source_paths.to_h do |path|
        fail!("matrix/helper/fixture source is missing or symlinked: #{path}") unless File.file?(path) && !File.symlink?(path)
        [File.realpath(path), sha(path)]
      end
    end

    def table_name(id)
      "w282m_#{@token}_#{id}"
    end

    def schema_for(kind)
      SCHEMAS.fetch(kind) { fail!("unknown W282 schema kind #{kind.inspect}") }
    end

    def encode_string(value)
      send(:rowbinary_string, value.to_s.b)
    end

    def encode_nullable_string(value)
      value.nil? ? "\x01".b : "\x00".b + encode_string(value)
    end

    def encode_array(values)
      send(:rowbinary_var_uint, values.size) + values.join.b
    end

    def encode_bulk_a(entries)
      encode_array(entries.map { |text, nullable| encode_string(text) + encode_nullable_string(nullable) })
    end

    def encode_bulk_b_map(entries)
      encode_array(entries.map { |key, value| encode_string(key) + [value].pack('S<').b })
    end

    def encode_bulk_b_nested(entries)
      encode_array(entries.map { |label, code| encode_string(label) + [code].pack('S<').b })
    end

    def row_values(kind)
      fail!("RowBinary is only defined for #{CASE}") unless kind == CASE
      ROWS.map do |left_id, array_a, right_id, map_b, array_b, nested_b|
        json_left = send(:rowbinary_json, {'id' => left_id})
        json_right = send(:rowbinary_json, {'id' => right_id})
        bulk_b = encode_bulk_b_map(map_b) + encode_array(array_b.map { |text| encode_string(text) }) + encode_bulk_b_nested(nested_b)
        [left_id].pack('Q<').b + json_left + encode_bulk_a(array_a) + json_right + bulk_b
      end
    end

    def literal_rows(kind)
      fail!("literal oracle is only defined for #{CASE}") unless kind == CASE
      EXPECTED_SIGNATURES
    end

    def expected_signatures(kind = CASE)
      fail!("signature oracle is only defined for #{CASE}") unless kind == CASE
      EXPECTED_SIGNATURES
    end

    def string_hex_sql(expression)
      "lower(hex(#{expression}))"
    end

    def nullable_string_sql(expression)
      "if(isNull(#{expression}), 'N', concat('V', #{string_hex_sql("assumeNotNull(#{expression})")}))"
    end

    def raw_scalar_sql(expression)
      "lower(hex(reinterpretAsFixedString(#{expression})))"
    end

    def native_projection_sql
      root = "`#{COLUMN}`"
      left_id = "tupleElement(#{root}, 1).id"
      array_a = "tupleElement(#{root}, 2)"
      right_id = "tupleElement(#{root}, 3).id"
      bulk_b = "tupleElement(#{root}, 4)"
      map_b = "tupleElement(#{bulk_b}, 1)"
      array_b = "tupleElement(#{bulk_b}, 2)"
      nested_b = "tupleElement(#{bulk_b}, 3)"
      array_a_item = "tupleElement(w282_a, 1)"
      nullable_a_item = "tupleElement(w282_a, 2)"
      nested_label = "tupleElement(w282_nested, 1)"
      nested_code = "tupleElement(w282_nested, 2)"
      "concat(toString(#{left_id}), '|A[', " \
        "arrayStringConcat(arrayMap(w282_a -> concat(#{string_hex_sql(array_a_item)}, ',', " \
        "#{nullable_string_sql(nullable_a_item)}), #{array_a}), ';'), ']|', " \
        "toString(#{right_id}), '|M[', " \
        "arrayStringConcat(arrayMap((w282_map_key, w282_map_value) -> " \
        "concat(#{string_hex_sql('w282_map_key')}, '=', #{raw_scalar_sql('w282_map_value')}), " \
        "mapKeys(#{map_b}), mapValues(#{map_b})), ';'), ']|E[', " \
        "arrayStringConcat(arrayMap(w282_e -> #{string_hex_sql('w282_e')}, #{array_b}), ';'), ']|N[', " \
        "arrayStringConcat(arrayMap(w282_nested -> " \
        "concat(#{string_hex_sql(nested_label)}, '=', #{raw_scalar_sql(nested_code)}), " \
        "#{nested_b}), ';'), ']')"
    end

    def native_projection_tokens(row)
      EXPECTED_SIGNATURES.fetch(row)
    end

    def values_sql(id, table, window)
      tag = send(:marker, 'values', id, window)
      predicate = WINDOWS.fetch(window)
      if window == 'eof'
        return "SELECT '#{tag}', toString(count()) FROM default.#{table} WHERE #{predicate} FORMAT TSVRaw;\n"
      end
      where = predicate ? " WHERE #{predicate}" : ''
      "SELECT '#{tag}', toString(pk), #{native_projection_sql} " \
        "FROM default.#{table}#{where} ORDER BY pk SETTINGS " \
        "output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;\n"
    end

    def read_window!(id, table, store, kind, window)
      result = execute_sql!("#{id}_values_#{window}", store, values_sql(id, table, window))
      return {state: send(:result_class, result), invocation: send(:stage_summary, result)} unless send(:success?, result)
      lines = send(:pinned_lines, result, "#{id}/#{window} recursive LowCardinality native values")
      tag = send(:marker, 'values', id, window)
      if window == 'eof'
        rows = send(:tagged, lines, tag, 2)
        exact = rows == [[tag, '0']] && lines.size == 1
        return {state: exact ? 'exact_values' : 'oracle_mismatch', rows: rows,
          expected_rows: [[tag, '0']], invocation: send(:stage_summary, result)}
      end
      rows = send(:tagged, lines, tag, 3)
      actual = rows.map { |row| {pk: Integer(row.fetch(1), 10), signature: row.fetch(2)} }
      indexes = case window
                when 'full' then (0...ROW_COUNT).to_a
                when 'middle' then (2...6).to_a
                when 'last' then (6...8).to_a
                else fail!("non-value window #{window.inspect}")
                end
      expected = indexes.map { |index| {pk: index + 1, signature: EXPECTED_SIGNATURES.fetch(index)} }
      exact = actual == expected && lines.size == rows.size && rows.size == expected.size
      {state: exact ? 'exact_values' : 'oracle_mismatch', rows: actual,
        expected_rows: expected, raw_rows: rows, invocation: send(:stage_summary, result)}
    rescue ArgumentError, KeyError => error
      {state: 'parse_error', error: "#{error.class}: #{error.message}"}
    end

    def native_callback_roster!(id, part, mark_format, kind)
      roster = super
      roster[:expected_low_cardinality_sites] = LC_SITE_DFS
      if mark_format == 'mrk4'
        events = []
        roster.fetch(:sections).each do |column, streams|
          streams.each_with_index do |stream, index|
            next unless stream.end_with?('.dict_prefix')
            events << {column: column, stream: stream, section_slot: index}
          end
        end
        fail!("#{id} expected six observed MRK4 LowCardinality prefix slots; observed #{events.size}") unless
          events.size == LC_SITE_DFS.size
        roster[:low_cardinality_prefix_events] = events.each_with_index.map do |event, index|
          event.merge(inferred_site_dfs: LC_SITE_DFS.fetch(index), observed_slot_ordinal: index)
        end
        roster[:low_cardinality_prefix_slot_ordinals] = events.map do |event|
          roster.fetch(:roster).index { |slot| slot[1] == event.fetch(:column) && slot[2] == event.fetch(:stream) }
        end
        fail!("#{id} MRK4 LowCardinality prefix event slots are absent or unordered") unless
          roster.fetch(:low_cardinality_prefix_slot_ordinals).all? &&
          roster.fetch(:low_cardinality_prefix_slot_ordinals) == roster.fetch(:low_cardinality_prefix_slot_ordinals).sort
        roster[:low_cardinality_prefix_event_basis] =
          'observed native callback slot order; per-site DFS labels are inferred from schema traversal and are not independently emitted by ClickHouse'
      else
        roster[:low_cardinality_prefix_events] = 'MRK3 has one physical slot per top-level column; nested callbacks are not individually named'
        roster[:low_cardinality_prefix_event_basis] = 'no per-site MRK3 callback order is observed'
        roster[:low_cardinality_prefix_slot_ordinals] = []
      end
      roster
    end

    def capture_case!(id, kind, mark_format, profile)
      entry = super
      entry[:settings_exact] = {
        profile: profile, clickhouse_settings: settings(mark_format),
        allow_suspicious_low_cardinality_types: 1,
        object_serialization_version: 'v3', object_shared_data_serialization_version: 'map',
        object_shared_data_buckets_for_compact_part: 1, variant_discriminator_mode: 'basic',
        mark_format: mark_format, mark_compression: 'plain',
      }
      entry
    end

    def invoke_helper(label, action, kind, mark_format, *arguments)
      if arguments.size == 1
        profile = @active_profile
        part = arguments.fetch(0)
      elsif arguments.size == 2
        profile, part = arguments
      else
        fail!("#{label} helper invocation arguments differ")
      end
      argv = [@helper, action, mark_format, profile, part]
      send(:register_expected!, label, argv, ''.b, 'crystal-helper', @helper,
        @helper_sha_before, nil)
      result = @runner.send(:run_process, label, argv, ''.b, 'crystal-helper',
        expected_sha: @helper_sha_before, binary_path: @helper)
      record = result.fetch(:record)
      process_ok = !record[:timed_out] && record[:spawn_error].nil? && record[:stdin_write_error].nil? &&
        record[:stdout_read_error].nil? && record[:stderr_read_error].nil? && result[:status] &&
        result[:status].termsig.nil?
      parsed = begin
        text = result.fetch(:stdout).dup.force_encoding(Encoding::UTF_8)
        raise JSON::ParserError, 'helper stdout is not valid UTF-8' unless text.valid_encoding?
        JSON.parse(text)
      rescue JSON::ParserError => error
        {parse_error: "#{error.class}: #{error.message}"}
      end
      state = if !process_ok
                'infrastructure_failure'
              elsif result[:classification] == 'success' && result[:status].success? &&
                    parsed.is_a?(Hash) && parsed['status'] == 'ok'
                'success'
              elsif parsed.is_a?(Hash) && parsed['status'] == 'error'
                'application_error'
              else
                'process_failure'
              end
      {state: state, report: parsed, error: state == 'success' ? nil : result[:stderr],
       invocation: send(:stage_summary, result)}
    end

    def validate_helper_report!(invocation, case_id, kind, mark_format, action,
                                expected_part_path:, profile: @active_profile)
      unless invocation[:state] == 'success'
        error = invocation[:report] || invocation[:error]
        return {status: classify_helper_error(invocation), error: error,
          invocation: invocation[:invocation]}
      end
      report = invocation.fetch(:report)
      expected_origin = action == 'read' ? 'stock' : 'generated'
      fail!("#{case_id} helper report envelope differs") unless
        report.fetch('format') == HELPER_FORMAT && report.fetch('action') == action &&
        report.fetch('mark_format') == mark_format && report.fetch('string_profile') == profile &&
        report.fetch('status') == 'ok' && report.fetch('row_count') == ROW_COUNT &&
        report.fetch('data_mark_count') == DATA_MARK_COUNT &&
        report.fetch('part_origin') == expected_origin &&
        report.fetch('public_reader_grid') == 'nonempty_data_marks' &&
        report.fetch('public_reader_mark_count') == DATA_MARK_COUNT &&
        report.fetch('public_reader_mark_rows') == PUBLIC_MARK_ROWS &&
        report.fetch('part_path') == expected_part_path &&
        report.fetch('schema').gsub(/\s+/, '') == TYPE.gsub(/\s+/, '')
      expected_windows = {
        'full' => EXPECTED_SIGNATURES,
        'middle' => EXPECTED_SIGNATURES.drop(2).take(4),
        'last' => EXPECTED_SIGNATURES.drop(6).take(2),
        'eof' => [],
      }
      recursive = report.fetch('recursive_windows')
      fail!("#{case_id} helper recursive-window roster differs") unless recursive.keys.sort == expected_windows.keys.sort
      expected_windows.each do |window, expected|
        actual = recursive.fetch(window)
        fail!("#{case_id}/#{window} recursive helper signatures or coordinates differ") unless
          actual.fetch('signatures') == expected &&
          actual.fetch('first_mark') == PHYSICAL_WINDOWS.fetch(window)[0] &&
          actual.fetch('mark_count') == PHYSICAL_WINDOWS.fetch(window)[1]
      end
      {status: 'exact_public_recursive_reads', report: report,
       invocation: invocation.fetch(:invocation)}
    rescue KeyError, TypeError, NoMethodError => error
      fail!("#{case_id} helper report is incomplete: #{error.class}: #{error.message}")
    end

    def build_summary
      stock_exact = @cases.size == MARK_FORMATS.size * PROFILES.size &&
        @cases.values.all? { |entry| entry.fetch(:status) == 'exact_native_values' }
      all_create_rejections = @cases.size == MARK_FORMATS.size * PROFILES.size &&
        @cases.values.all? { |entry| entry.fetch(:status) == 'create_server_exception' }
      infrastructure_failure = @cases.values.any? do |entry|
        entry[:status].to_s.include?('infrastructure_failure') ||
          entry.dig(:library_stock_read, :status).to_s.include?('infrastructure_failure') ||
          entry.dig(:library_generated, :status).to_s.include?('infrastructure_failure')
      end
      reads_exact = stock_exact && @cases.values.all? do |entry|
        entry.dig(:library_stock_read, :status) == 'exact_public_recursive_reads'
      end
      generated_exact = @full_matrix && reads_exact && @cases.values.all? do |entry|
        entry.dig(:library_generated, :status) == 'exact_generated_native_interop'
      end
      all_generated_admission_rejections = @full_matrix && reads_exact && @cases.values.all? do |entry|
        entry.dig(:library_generated, :status) == 'library_admission_rejection_captured'
      end
      status = if generated_exact
                 'generated_native_interop_matrix_exact'
               elsif all_generated_admission_rejections
                 'generated_admission_rejection_captured'
               elsif !@full_matrix && stock_exact
                 'stock_native_matrix_exact'
               elsif all_create_rejections
                 'stock_schema_rejection_captured'
               elsif infrastructure_failure
                 'probe_infrastructure_failure'
               else
                 'incomplete_or_discrepant'
               end
      {
        format: FORMAT, status: status,
        execution_scope: 'Stock-only mode first captures exactly one canonical recursive JSON declaration at MRK3/MRK4 × S0/S1 from independent Ruby RowBinary input. Full mode repeats those four controls before four generated-part cells; no root LowCardinality substitute is used.',
        runtime_pin: {binary: @binary, expected_sha256: W280::BINARY_SHA256,
          sha256_before: @binary_sha_before, sha256_after: @binary_sha_after,
          version: W280::VERSION, build: W280::BUILD},
        source_pin: {root: @source_root, revision_expected: W280::SOURCE_REVISION,
          revision_before: @source_revision_before, revision_after: @source_revision_after,
          source_sha256_before: @upstream_hashes_before, source_sha256_after: @upstream_hashes_after},
        helper_pin: @full_matrix ? {path: @helper, expected_sha256: @helper_sha_argument,
          sha256_before: @helper_sha_before, sha256_after: @helper_sha_after,
          source: HELPER_SOURCE} : nil,
        matrix_source_pins: {sha256_before: @local_source_hashes_before,
          sha256_after: @local_source_hashes_after},
        schema_parameters: {
          object_serialization_version: 'v3', object_shared_data_serialization_version: 'map',
          map_layout_value: 0, object_shared_data_buckets_for_compact_part: 1,
          string_profiles: {'s0' => 'single_stream', 's1' => 'with_size_stream'},
          mark_compression: 'plain', variant_discriminator_mode: 'basic',
          allow_suspicious_low_cardinality_types: 1, mark_formats: MARK_FORMATS,
        },
        fixture: {
          schema: SCHEMAS.fetch(CASE), json_declaration: JSON_DECLARATION,
          literal_signatures: EXPECTED_SIGNATURES, row_count: ROW_COUNT,
          rows_per_mark: ROWS_PER_MARK, data_marks: DATA_MARK_COUNT,
          raw_mark_file_rows: RAW_MARK_ROWS, public_reader_mark_rows: PUBLIC_MARK_ROWS,
          native_windows: WINDOWS, physical_windows: PHYSICAL_WINDOWS,
          low_cardinality_site_serializer_dfs_hypothesis: LC_SITE_DFS,
          low_cardinality_occurrences_per_mark: LC_OCCURRENCES_PER_MARK,
          low_cardinality_prefix_callbacks_expected: LC_SITE_DFS.size,
          low_cardinality_prefix_callback_claim: 'MRK4 slot order is observed; the per-site DFS labels are inferred from schema traversal and are not independently emitted by ClickHouse. Callback count/order alone is not semantic evidence; exact native and public-reader value windows provide the value oracle.',
          oracle_input: 'independent literal Ruby values encoded as RowBinary; expected signatures are derived from those literals and never from Crystal output',
        },
        cases: @cases,
        invocation_roster: @invocations.map do |record|
          {label: record.fetch(:label), process_kind: record.fetch(:process_kind),
            binary_path: record.fetch(:binary_path), store_path: record.fetch(:store_path),
            argv: record.fetch(:argv), stdin_file: record.fetch(:stdin_file),
            argv_file: record.fetch(:argv_file), stdout_file: record.fetch(:stdout_file),
            stderr_file: record.fetch(:stderr_file), record_file: "#{record.fetch(:label)}.json"}
        end,
        evidence_root: @root,
        claim_boundary: 'Finite eight-row, four-data-mark evidence for the exact recursive JSON/Tuple declaration only, under MAP0/BASIC/V3 and MRK3/MRK4 × S0/S1. A stock schema rejection is a blocked native-compatibility probe, not permission to substitute a root LC or easier wrapper. Generated success is limited to this composition and requires exact public-reader windows plus byte-preserving ATTACH, CHECK, native windows, callback sidecars, and pinned source/runtime/helper identities.',
      }
    end

    def render_summary(summary)
      lines = [
        '# W282 recursive LowCardinality Compact matrix', '',
        "Status: `#{summary.fetch(:status)}`",
        "Runtime: `#{W280::VERSION}` build `#{W280::BUILD}` SHA-256 `#{W280::BINARY_SHA256}`.",
        "Source: `#{W280::SOURCE_REVISION}` at `#{W280::SOURCE_ROOT}` (separate pin).",
        'Stock schema is captured before any helper read or generated write; exactly four stock cells are MRK3/MRK4 × S0/S1.',
      ]
      @cases.each do |id, entry|
        lines << "- #{id}: native `#{entry.fetch(:status)}`; public recursive read `#{entry.dig(:library_stock_read, :status) || 'not run'}`; generated `#{entry.dig(:library_generated, :status) || 'not run'}`."
      end
      lines.concat(['', summary.fetch(:claim_boundary), ''])
      lines.join("\n")
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  options = {
    binary: ProbeCompactStaticBulkW281Matrix::W280M::W280::BINARY,
    source_root: ProbeCompactStaticBulkW281Matrix::W280M::W280::SOURCE_ROOT,
    evidence_root: nil, stock_only: false, full_matrix: false, helper: nil, helper_sha256: nil,
  }
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/probe_compact_low_cardinality_bulk_w282_matrix.rb (--stock-only | --full-matrix --helper PREBUILT --helper-sha256 SHA256) --evidence-root EMPTY_DIR'
    parser.on('--stock-only', 'Capture exactly four independent stock/native controls') { options[:stock_only] = true }
    parser.on('--full-matrix', 'Capture stock first, then public-reader/generated-writer/native interop') { options[:full_matrix] = true }
    parser.on('--helper PATH', 'Prebuilt W282 Crystal helper; full-matrix only') { |value| options[:helper] = value }
    parser.on('--helper-sha256 SHA256', 'Exact lowercase SHA-256 of the prebuilt helper') { |value| options[:helper_sha256] = value }
    parser.on('--evidence-root EMPTY_DIR', 'Existing empty direct child of /private/tmp') { |value| options[:evidence_root] = value }
    parser.on('--binary PATH', 'Separately pinned ClickHouse runtime executable') { |value| options[:binary] = value }
    parser.on('--source-root PATH', 'Separately pinned upstream ClickHouse checkout') { |value| options[:source_root] = value }
  end.parse!
  unless options[:evidence_root] && options[:stock_only] != options[:full_matrix]
    warn 'W282 recursive LowCardinality matrix: choose exactly one mode and provide --evidence-root'
    exit 2
  end
  if options[:full_matrix] && (!options[:helper] || !options[:helper_sha256])
    warn 'W282 recursive LowCardinality matrix: --full-matrix requires --helper and --helper-sha256'
    exit 2
  end
  if options[:stock_only] && (options[:helper] || options[:helper_sha256])
    warn 'W282 recursive LowCardinality matrix: helper options are valid only with --full-matrix'
    exit 2
  end
  exit(ProbeCompactLowCardinalityBulkW282Matrix::Probe.new(**options).run ? 0 : 1)
end
