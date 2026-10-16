#!/usr/bin/env ruby
# Stock-first W283 native matrix. Input bytes and expected signatures are
# independent Ruby literals; neither is derived from the Crystal fixture.

require 'json'
require 'optparse'
require_relative 'compact_variant_bulk_w283_paths'
require_relative 'probe_compact_low_cardinality_bulk_w282_matrix'

module ProbeCompactVariantBulkW283Matrix
  W282M = ProbeCompactLowCardinalityBulkW282Matrix
  W281M = W282M::W281M
  W280M = W281M::W280M
  W280 = W281M::W280
  PATHS = CompactVariantBulkW283Paths

  BINARY = '/opt/mldata_ssd/cache/crystal-click-w283.PDWAiK/recovery/runtime/clickhouse'.freeze
  RUNTIME_PIN = {sha256: '5bb43958f4c0806cc363b84b9858e7206e56ac80263a24acc704271322e531ae'.freeze,
    bytes: 919_123_095, version: '26.10.1.1201'.freeze,
    build: 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze}.freeze

  FORMAT = 'compact_variant_bulk_w283_matrix_v1'.freeze
  HELPER_FORMAT = 'compact_variant_bulk_w283_helper_v1'.freeze
  HELPER_SOURCE = File.expand_path('compact_variant_bulk_w283_helper.cr', __dir__).freeze
  PATHS_SOURCE = File.expand_path('compact_variant_bulk_w283_paths.rb', __dir__).freeze
  CASE = 'stock_bulk'.freeze
  COLUMN = 'recursive_variant_w283'.freeze
  JSON_DECLARATION = 'JSON(max_dynamic_types=0, max_dynamic_paths=0, id UInt64)'.freeze
  VARIANT_DECLARATION = 'Variant(Array(UInt8), String, UInt64)'.freeze
  TYPE = "Tuple(#{JSON_DECLARATION}, Array(Tuple(#{VARIANT_DECLARATION}, LowCardinality(String))), " \
         "#{JSON_DECLARATION}, Tuple(LowCardinality(String), #{VARIANT_DECLARATION}, " \
         "Map(String, #{VARIANT_DECLARATION}), Nested(choice #{VARIANT_DECLARATION}, " \
         'label LowCardinality(String))))'.freeze
  SCHEMAS = {CASE => [['pk', 'UInt64'], [COLUMN, TYPE]].map(&:freeze).freeze}.freeze

  MARK_FORMATS = %w[mrk3 mrk4].freeze
  PROFILES = %w[s0 s1].freeze
  MODES = %w[basic compact].freeze
  MODE_VALUES = {'basic' => 0, 'compact' => 1}.freeze
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

  # Literal variant representation: [:null, nil], [:array, [UInt8...]],
  # [:string, binary String], or [:uint64, Integer]. Array entries are
  # [Variant, LC label]; map entries are [String key, Variant]; Nested entries
  # are [Variant, LC label].
  INVALID_BYTES = [0x00, 0xff, 0x80, 0x41].pack('C*').b.freeze
  ROWS = [
    {left: 1, array: [], right: 101, root_lc: 'root-lc-0'.b, root_variant: [:null, nil], map: [], nested: []},
    {left: 2, array: [], right: 102, root_lc: 'root-lc-1'.b, root_variant: [:null, nil], map: [], nested: []},
    {left: 3, array: [[[:null, nil], 'null-2'.b]], right: 103, root_lc: 'root-lc-2'.b,
      root_variant: [:null, nil], map: [['null-2'.b, [:null, nil]]], nested: [[[:null, nil], 'null-2'.b]]},
    {left: 4, array: [[[:null, nil], 'null-3'.b]], right: 104, root_lc: 'root-lc-3'.b,
      root_variant: [:null, nil], map: [['null-3'.b, [:null, nil]]], nested: [[[:null, nil], 'null-3'.b]]},
    {left: 5, array: [
        [[:array, []], 'empty-array'.b], [[:string, ''.b], 'empty-string'.b],
        [[:uint64, 0], 'zero-u64'.b],
      ], right: 105, root_lc: 'root-lc-4'.b, root_variant: [:array, []],
      map: [['empty'.b, [:array, []]], ['null'.b, [:null, nil]]],
      nested: [[[:array, []], 'empty'.b], [[:null, nil], 'null'.b]]},
    {left: 6, array: [
        [[:null, nil], 'null-5'.b], [[:array, [0, 255]], 'bytes-5'.b],
        [[:string, "middle\0".b], 'middle'.b],
      ], right: 106, root_lc: 'root-lc-5'.b, root_variant: [:string, "root\0".b],
      map: [['middle'.b, [:string, "map\0".b]]],
      nested: [[[:string, "nested\0".b], 'middle'.b]]},
    {left: 7, array: [
        [[:string, INVALID_BYTES], 'late-binary'.b],
        [[:uint64, 0x0102_0304_0506_0708], 'late-u64'.b],
      ], right: 107, root_lc: 'root-lc-6'.b, root_variant: [:uint64, 0xdead_beef_cafe_babe],
      map: [['late-u64'.b, [:uint64, 0x1122_3344_5566_7788]]],
      nested: [[[:uint64, 0x8877_6655_4433_2211], 'late-u64'.b]]},
    {left: 8, array: [
        [[:array, [255, 0, 127]], 'tail-bytes'.b],
        [[:uint64, 0xfedc_ba98_7654_3210], 'tail-u64'.b],
        [[:string, "tail\0".b], 'tail-string'.b],
      ], right: 108, root_lc: 'root-lc-7'.b, root_variant: [:string, INVALID_BYTES],
      map: [['late-binary'.b, [:string, INVALID_BYTES]]],
      nested: [[[:string, INVALID_BYTES], 'late-binary'.b]]},
  ].map(&:freeze).freeze

  def self.hex(bytes)
    bytes.to_s.b.unpack1('H*')
  end

  def self.variant_signature(value)
    arm, payload = value
    case arm
    when :null then 'N'
    when :array then "A[#{payload.map { |byte| format('%02x', byte) }.join(',')}]"
    when :string then "S#{hex(payload)}"
    when :uint64 then "U#{Integer(payload)}"
    else raise ArgumentError, "unknown literal Variant arm #{arm.inspect}"
    end
  end

  def self.row_signature(row)
    array = row.fetch(:array).map { |variant, label| "#{variant_signature(variant)}/#{hex(label)}" }
    map = row.fetch(:map).map { |key, value| "#{hex(key)}=#{variant_signature(value)}" }
    nested = row.fetch(:nested).map { |variant, label| "#{variant_signature(variant)}/#{hex(label)}" }
    "#{row.fetch(:left)}|A[#{array.join(';')}]|#{row.fetch(:right)}|" \
      "B(#{hex(row.fetch(:root_lc))}|#{variant_signature(row.fetch(:root_variant))}|" \
      "M[#{map.join(';')}]|N[#{nested.join(';')}])"
  end

  EXPECTED_SIGNATURES = ROWS.map { |row| row_signature(row) }.freeze

  class Failure < StandardError; end

  class Probe < W282M::Probe
    def initialize(binary:, source_root:, evidence_root:, stock_only: false, full_matrix: false,
                   helper: nil, helper_sha256: nil)
      @active_profile = 's0'
      @active_variant_mode = 'basic'
      super
      fail!('select exactly one of --stock-only or --full-matrix') unless stock_only != full_matrix
      if full_matrix
        fail!('--full-matrix requires a helper path and exact SHA-256') unless helper && helper_sha256
      elsif helper || helper_sha256
        fail!('--helper and --helper-sha256 require --full-matrix')
      end
    end

    def validate_root(path)
      PATHS.validate_evidence_root(path, purpose: :probe)
    end

    def validate_source_root(path)
      PATHS.validate_source_root(path)
    end

    def validate_executable(path, label)
      canonical = PATHS.validate_task_file(path)
      super(canonical, label)
    end

    def run
      prepare!
      MODES.each do |mode|
        MARK_FORMATS.each do |mark_format|
          PROFILES.each do |profile|
            @active_variant_mode = mode
            @active_profile = profile
            id = "#{CASE}_#{mode}_#{mark_format}_#{profile}"
            begin
              @cases[id] = capture_case!(id, CASE, mark_format, profile)
            rescue StandardError => error
              @cases[id] = {case_id: id, schema_kind: CASE, mark_format: mark_format,
                string_profile: profile, variant_discriminator_mode: mode, status: 'probe_error',
                error: "#{error.class}: #{error.message}"}
            end
          end
        end
      end
      if @full_matrix
        @cases.each do |id, entry|
          next unless entry.fetch(:status) == 'exact_native_values'
          @active_variant_mode = entry.fetch(:variant_discriminator_mode)
          @active_profile = entry.fetch(:string_profile)
          entry[:library_stock_read] = capture_helper_read!("#{id}_helper_stock", id, CASE,
            entry.fetch(:mark_format), entry.fetch(:string_profile), entry.dig(:schema_part, :part, :path))
        end
        MODES.each do |mode|
          MARK_FORMATS.each do |mark_format|
            PROFILES.each do |profile|
              @active_variant_mode = mode
              @active_profile = profile
              id = "#{CASE}_#{mode}_#{mark_format}_#{profile}"
              begin
                @cases.fetch(id)[:library_generated] = capture_generated!(id, CASE, mark_format)
              rescue StandardError => error
                @cases.fetch(id)[:library_generated] = {status: 'probe_error',
                  error: "#{error.class}: #{error.message}"}
              end
            end
          end
        end
      end
      validate_process_evidence!
      validate_pins!
      summary = build_summary
      send(:write_new, File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      send(:write_new, File.join(@root, 'summary.md'), render_summary(summary))
      puts "W283 Variant/Bulk matrix status=#{summary.fetch(:status)}; " \
        "cells=#{@cases.size}; invocations=#{@invocations.size}; evidence=#{@root}"
      %w[stock_native_matrix_exact stock_schema_rejection_captured
         generated_native_interop_matrix_exact generated_admission_rejection_captured].include?(summary.fetch(:status))
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      persist_inconclusive(error)
      warn "W283 stock Variant/Bulk matrix inconclusive: #{@fatal_error}"
      false
    end

    private

    def runtime_pin
      RUNTIME_PIN
    end

    def validate_literals!
      fail!('W283 must use the exact recursive JSON / nested Variant / LC declaration') unless
        COLUMN == 'recursive_variant_w283' &&
        JSON_DECLARATION == 'JSON(max_dynamic_types=0, max_dynamic_paths=0, id UInt64)' &&
        VARIANT_DECLARATION == 'Variant(Array(UInt8), String, UInt64)' &&
        TYPE == "Tuple(#{JSON_DECLARATION}, Array(Tuple(#{VARIANT_DECLARATION}, LowCardinality(String))), " \
          "#{JSON_DECLARATION}, Tuple(LowCardinality(String), #{VARIANT_DECLARATION}, " \
          "Map(String, #{VARIANT_DECLARATION}), Nested(choice #{VARIANT_DECLARATION}, " \
          'label LowCardinality(String))))'
      fail!('W283 must retain all eight BASIC/COMPACT × MRK3/MRK4 × S0/S1 cells') unless
        MODES == %w[basic compact] && MARK_FORMATS == %w[mrk3 mrk4] && PROFILES == %w[s0 s1] &&
        ROWS.size == ROW_COUNT && ROWS_PER_MARK == 2 && DATA_MARK_COUNT == 4 &&
        RAW_MARK_ROWS == [2, 2, 2, 2, 0] && PUBLIC_MARK_ROWS == [2, 2, 2, 2]
      fail!('W283 Ruby literals must preserve zero-Q, all-NULL, empty Array arm, mixed arms and late binary/U64') unless
        ROWS.take(2).all? { |row| row[:array].empty? && row[:map].empty? && row[:nested].empty? } &&
        ROWS.values_at(2, 3).all? { |row| row[:array].all? { |variant, _label| variant.first == :null } &&
          row[:root_variant].first == :null && row[:map].all? { |_key, variant| variant.first == :null } &&
          row[:nested].all? { |variant, _label| variant.first == :null } } &&
        ROWS.fetch(4)[:array].any? { |variant, *_| variant == [:array, []] } &&
        ROWS.fetch(4)[:array].any? { |variant, *_| variant == [:string, ''.b] } &&
        ROWS.fetch(4)[:array].any? { |variant, *_| variant == [:uint64, 0] } &&
        ROWS.drop(5).any? { |row| row.values.flatten(8).include?(INVALID_BYTES) } &&
        ROWS.drop(5).any? { |row| row.values.flatten(6).include?(0xfedc_ba98_7654_3210) }
      fail!('W283 expected signatures must be eight independent row literals') unless
        EXPECTED_SIGNATURES.size == ROW_COUNT && EXPECTED_SIGNATURES.uniq.size == ROW_COUNT &&
        EXPECTED_SIGNATURES == ROWS.map { |row| ProbeCompactVariantBulkW283Matrix.row_signature(row) }
      true
    end

    def prepare!
      super
      extra = [W280::PROBE_SOURCE, File.expand_path(__FILE__), PATHS_SOURCE,
        File.expand_path('verify_compact_variant_bulk_w283_runtime_pin.rb', __dir__),
        File.expand_path('../spec/support/compact_part_writer_w283_fixture.cr', __dir__)]
      extra << HELPER_SOURCE if @full_matrix
      extra.each do |path|
        fail!("W283 matrix/fixture source is missing or symlinked: #{path}") unless File.file?(path) && !File.symlink?(path)
      end
      @local_source_paths = (@local_source_paths + extra.map { |path| File.realpath(path) }).uniq.sort
      @local_source_hashes_before = @local_source_paths.to_h { |path| [path, sha(path)] }
      if @full_matrix
        @helper = send(:validate_executable, @helper_argument, 'pinned W283 Crystal helper')
        @helper_sha_before = sha(@helper)
        fail!('prebuilt W283 helper differs from --helper-sha256') unless @helper_sha_before == @helper_sha_argument
      end
    end

    def validate_pins!
      super
      @local_source_hashes_after = @local_source_hashes_before.keys.to_h { |path| [path, sha(path)] }
      fail!('W283 matrix/fixture source bytes changed during stock capture') unless
        @local_source_hashes_after == @local_source_hashes_before
      if @full_matrix
        @helper_sha_after = sha(@helper)
        fail!('prebuilt W283 helper changed during capture') unless @helper_sha_after == @helper_sha_before
      end
    end

    def table_name(id)
      "w283m_#{@token}_#{id}"
    end

    def schema_for(kind)
      SCHEMAS.fetch(kind) { fail!("unknown W283 schema kind #{kind.inspect}") }
    end

    def settings(mark_format)
      base = super
      needle = 'use_compact_variant_discriminators_serialization=0'
      fail!('parent BASIC Variant setting must occur exactly once before mode substitution') unless base.scan(needle).size == 1
      base.sub(needle, "use_compact_variant_discriminators_serialization=#{MODE_VALUES.fetch(@active_variant_mode)}")
    end

    def rowbinary_variant(value)
      arm, payload = value
      case arm
      when :null then "\xff".b
      when :array then "\x00".b + encode_array(payload.map { |byte| [byte].pack('C').b })
      when :string then "\x01".b + encode_string(payload)
      when :uint64 then "\x02".b + [Integer(payload)].pack('Q<').b
      else fail!("unknown W283 RowBinary Variant arm #{arm.inspect}")
      end
    end

    def encode_string(value)
      send(:rowbinary_string, value.to_s.b)
    end

    def encode_array(values)
      send(:rowbinary_var_uint, values.size) + values.join.b
    end

    def rowbinary_bulk(row)
      array = encode_array(row.fetch(:array).map do |variant, label|
        rowbinary_variant(variant) + encode_string(label)
      end)
      bulk = encode_string(row.fetch(:root_lc)) + rowbinary_variant(row.fetch(:root_variant))
      bulk << encode_array(row.fetch(:map).map { |key, variant| encode_string(key) + rowbinary_variant(variant) })
      bulk << encode_array(row.fetch(:nested).map do |variant, label|
        rowbinary_variant(variant) + encode_string(label)
      end)
      [array, bulk]
    end

    def row_values(kind)
      fail!("W283 RowBinary is only defined for #{CASE}") unless kind == CASE
      ROWS.map do |row|
        left = send(:rowbinary_json, {'id' => row.fetch(:left)})
        right = send(:rowbinary_json, {'id' => row.fetch(:right)})
        array, bulk = rowbinary_bulk(row)
        [row.fetch(:left)].pack('Q<').b + left + array + right + bulk
      end
    end

    def literal_rows(kind)
      fail!("W283 oracle is only defined for #{CASE}") unless kind == CASE
      EXPECTED_SIGNATURES
    end

    def expected_signatures(kind = CASE)
      fail!("W283 oracle is only defined for #{CASE}") unless kind == CASE
      EXPECTED_SIGNATURES
    end

    def variant_sql(expression)
      array_arm = "concat('A[', arrayStringConcat(arrayMap(w283_byte -> " \
        "lower(hex(reinterpretAsFixedString(w283_byte))), variantElement(#{expression}, 'Array(UInt8)')), ','), ']')"
      string_arm = "concat('S', lower(hex(variantElement(#{expression}, 'String'))))"
      uint_arm = "concat('U', toString(variantElement(#{expression}, 'UInt64')))"
      "multiIf(variantType(#{expression}) = 'Array(UInt8)', #{array_arm}, " \
        "variantType(#{expression}) = 'String', #{string_arm}, " \
        "variantType(#{expression}) = 'UInt64', #{uint_arm}, 'N')"
    end

    def native_projection_sql
      root = "`#{COLUMN}`"
      left_id = "tupleElement(#{root}, 1).id"
      array = "tupleElement(#{root}, 2)"
      right_id = "tupleElement(#{root}, 3).id"
      bulk = "tupleElement(#{root}, 4)"
      root_lc = "tupleElement(#{bulk}, 1)"
      root_variant = "tupleElement(#{bulk}, 2)"
      map = "tupleElement(#{bulk}, 3)"
      nested = "tupleElement(#{bulk}, 4)"
      "concat(toString(#{left_id}), '|A[', " \
        "arrayStringConcat(arrayMap(w283_a -> concat(#{variant_sql('tupleElement(w283_a, 1)')}, '/', " \
        "lower(hex(tupleElement(w283_a, 2)))), #{array}), ';'), ']|', " \
        "toString(#{right_id}), '|B(', lower(hex(#{root_lc})), '|', #{variant_sql(root_variant)}, '|M[', " \
        "arrayStringConcat(arrayMap((w283_key, w283_value) -> concat(lower(hex(w283_key)), '=', " \
        "#{variant_sql('w283_value')}), mapKeys(#{map}), mapValues(#{map})), ';'), ']|N[', " \
        "arrayStringConcat(arrayMap(w283_nested -> concat(#{variant_sql('tupleElement(w283_nested, 1)')}, '/', " \
        "lower(hex(tupleElement(w283_nested, 2)))), #{nested}), ';'), '])')"
    end

    def native_projection_tokens(row)
      EXPECTED_SIGNATURES.fetch(row)
    end

    def values_sql(id, table, window)
      tag = send(:marker, 'values', id, window)
      predicate = WINDOWS.fetch(window)
      return "SELECT '#{tag}', toString(count()) FROM default.#{table} WHERE #{predicate} FORMAT TSVRaw;\n" if window == 'eof'
      where = predicate ? " WHERE #{predicate}" : ''
      "SELECT '#{tag}', toString(pk), #{native_projection_sql} FROM default.#{table}#{where} " \
        "ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;\n"
    end

    def read_window!(id, table, store, kind, window)
      result = execute_sql!("#{id}_values_#{window}", store, values_sql(id, table, window))
      return {state: send(:result_class, result), invocation: send(:stage_summary, result)} unless send(:success?, result)
      lines = send(:pinned_lines, result, "#{id}/#{window} recursive Variant/Bulk native values")
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
                else fail!("unknown W283 value window #{window.inspect}")
                end
      expected = indexes.map { |index| {pk: index + 1, signature: EXPECTED_SIGNATURES.fetch(index)} }
      exact = actual == expected && lines.size == rows.size && rows.size == expected.size
      {state: exact ? 'exact_values' : 'oracle_mismatch', rows: actual,
        expected_rows: expected, raw_rows: rows, invocation: send(:stage_summary, result)}
    rescue ArgumentError, KeyError => error
      {state: 'parse_error', error: "#{error.class}: #{error.message}"}
    end

    def native_callback_roster!(id, part, mark_format, kind)
      method = W280M::W277::Probe.instance_method(:native_callback_roster!)
      method.bind(self).call(id, part, mark_format, kind)
    end

    def capture_case!(id, kind, mark_format, profile)
      entry = super
      entry[:variant_discriminator_mode] = @active_variant_mode
      entry[:settings_exact] = {
        profile: profile, clickhouse_settings: settings(mark_format),
        object_serialization_version: 'v3', object_shared_data_serialization_version: 'map',
        map_layout_value: 0, object_shared_data_buckets_for_compact_part: 1,
        variant_discriminator_mode: @active_variant_mode,
        allow_suspicious_low_cardinality_types: 1,
        mark_format: mark_format, mark_compression: 'plain',
      }
      entry[:schema_parameters] = entry.fetch(:schema_parameters).merge(variant_discriminator_mode: @active_variant_mode)
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
      argv = [@helper, action, @active_variant_mode, mark_format, profile, part]
      send(:register_expected!, label, argv, ''.b, 'crystal-helper', @helper, @helper_sha_before, nil)
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
      expected_schema = TYPE.gsub(/\s+/, '')
      fail!("#{case_id} helper report envelope differs") unless
        report.fetch('format') == HELPER_FORMAT && report.fetch('action') == action &&
        report.fetch('variant_discriminator_mode') == @active_variant_mode &&
        report.fetch('mark_format') == mark_format && report.fetch('string_profile') == profile &&
        report.fetch('reader_ordinary_profile') == profile &&
        report.fetch('reader_ordinary_profile_matches_requested') == true &&
        report.fetch('status') == 'ok' && report.fetch('row_count') == ROW_COUNT &&
        report.fetch('data_mark_count') == DATA_MARK_COUNT && report.fetch('part_origin') == expected_origin &&
        report.fetch('public_reader_grid') == 'nonempty_data_marks' &&
        report.fetch('public_reader_mark_count') == DATA_MARK_COUNT &&
        report.fetch('public_reader_mark_rows') == PUBLIC_MARK_ROWS &&
        report.fetch('part_path') == expected_part_path && report.fetch('schema').gsub(/\s+/, '') == expected_schema
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
        fail!("#{case_id}/#{window} helper signatures or coordinates differ") unless
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
      pin = runtime_pin
      cell_count = MODES.size * MARK_FORMATS.size * PROFILES.size
      stock_exact = @cases.size == cell_count &&
        @cases.values.all? { |entry| entry.fetch(:status) == 'exact_native_values' }
      stock_rejected = @cases.size == cell_count &&
        @cases.values.all? { |entry| %w[create_server_exception insert_server_exception].include?(entry[:status]) }
      reads_exact = stock_exact && @cases.values.all? do |entry|
        entry.dig(:library_stock_read, :status) == 'exact_public_recursive_reads'
      end
      generated_exact = @full_matrix && reads_exact && @cases.values.all? do |entry|
        entry.dig(:library_generated, :status) == 'exact_generated_native_interop'
      end
      generated_rejected = @full_matrix && reads_exact && @cases.values.all? do |entry|
        entry.dig(:library_generated, :status) == 'library_admission_rejection_captured'
      end
      infra = @cases.values.any? do |entry|
        entry[:status].to_s.include?('infrastructure_failure') ||
          entry.dig(:library_stock_read, :status).to_s.include?('infrastructure_failure') ||
          entry.dig(:library_generated, :status).to_s.include?('infrastructure_failure')
      end
      status = if generated_exact
                 'generated_native_interop_matrix_exact'
               elsif generated_rejected
                 'generated_admission_rejection_captured'
               elsif !@full_matrix && stock_exact
                 'stock_native_matrix_exact'
               elsif stock_rejected
                 'stock_schema_rejection_captured'
               elsif infra
                 'probe_infrastructure_failure'
               else
                 'incomplete_or_discrepant'
               end
      {
        format: FORMAT, status: status,
        execution_scope: 'Stock-only captures the exact recursive JSON / Variant / LowCardinality declaration across BASIC/COMPACT × MRK3/MRK4 × S0/S1 before helper use. Full mode repeats all stock controls, reads their parts, then writes generated parts and checks native ATTACH/reopen. Ruby RowBinary and signatures are independent literals; no root-Variant substitute is used.',
        runtime_pin: {binary: @binary, expected_sha256: pin.fetch(:sha256),
          sha256_before: @binary_sha_before, sha256_after: @binary_sha_after,
          expected_bytes: pin.fetch(:bytes), bytes_before: @binary_bytes_before,
          bytes_after: @binary_bytes_after, version: pin.fetch(:version), build: pin.fetch(:build)},
        source_pin: {root: @source_root, revision_expected: W280::SOURCE_REVISION,
          revision_before: @source_revision_before, revision_after: @source_revision_after,
          source_sha256_before: @upstream_hashes_before, source_sha256_after: @upstream_hashes_after},
        helper_pin: @full_matrix ? {path: @helper, expected_sha256: @helper_sha_argument,
          sha256_before: @helper_sha_before, sha256_after: @helper_sha_after,
          source: HELPER_SOURCE} : nil,
        matrix_source_pins: {sha256_before: @local_source_hashes_before,
          sha256_after: @local_source_hashes_after},
        schema_parameters: {object_serialization_version: 'v3', object_shared_data_serialization_version: 'map',
          map_layout_value: 0, object_shared_data_buckets_for_compact_part: 1,
          string_profiles: {'s0' => 'single_stream', 's1' => 'with_size_stream'},
          mark_compression: 'plain', variant_discriminator_modes: MODE_VALUES,
          mark_formats: MARK_FORMATS, allow_suspicious_low_cardinality_types: 1},
        fixture: {schema: SCHEMAS.fetch(CASE), literal_signatures: EXPECTED_SIGNATURES,
          row_count: ROW_COUNT, rows_per_mark: ROWS_PER_MARK, data_marks: DATA_MARK_COUNT,
          raw_mark_file_rows: RAW_MARK_ROWS, public_reader_mark_rows: PUBLIC_MARK_ROWS,
          native_windows: WINDOWS, physical_windows: PHYSICAL_WINDOWS,
          oracle_input: 'independent Ruby literal ROWS encoded as RowBinary; expected signatures never derive from Crystal output',
          variant_alternatives: {'0' => 'Array(UInt8)', '1' => 'String', '2' => 'UInt64', '255' => 'NULL'},
          coverage: ['zero-Q', 'positive-Q all-NULL', 'empty selected Array distinct from NULL',
            'all non-NULL alternatives', 'late binary String and large UInt64']},
        cases: @cases,
        invocation_roster: @invocations.map do |record|
          {label: record.fetch(:label), process_kind: record.fetch(:process_kind),
            binary_path: record.fetch(:binary_path), store_path: record.fetch(:store_path),
            argv: record.fetch(:argv), stdin_file: record.fetch(:stdin_file),
            argv_file: record.fetch(:argv_file), stdout_file: record.fetch(:stdout_file),
            stderr_file: record.fetch(:stderr_file), record_file: "#{record.fetch(:label)}.json"}
        end,
        evidence_root: @root,
        claim_boundary: 'Finite eight-row, four-data-mark evidence for this exact recursive JSON/Tuple declaration only, under MAP0/BASIC/V3 and BASIC/COMPACT × MRK3/MRK4 × S0/S1. A stock schema rejection is a blocked native-compatibility probe, not permission to substitute a root Variant or easier wrapper. Generated success is limited to this composition and requires exact public-reader windows plus byte-preserving ATTACH, CHECK, native windows, raw sidecars, and pinned source/runtime/helper identities.',
      }
    end

    def render_summary(summary)
      pin = runtime_pin
      lines = ['# W283 Variant/Bulk matrix', '', "Status: `#{summary.fetch(:status)}`",
        "Runtime: `#{pin.fetch(:version)}` build `#{pin.fetch(:build)}`; " \
          "#{pin.fetch(:bytes)} bytes; SHA-256 `#{pin.fetch(:sha256)}`; " \
          "source revision: `#{W280::SOURCE_REVISION}`."]
      @cases.each do |id, entry|
        lines << "- #{id}: `#{entry.fetch(:status)}` (CHECK `#{entry.dig(:check, :state) || 'not run'}`)."
      end
      lines.concat(['', summary.fetch(:claim_boundary), ''])
      lines.join("\n")
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  options = {
    binary: ProbeCompactVariantBulkW283Matrix::BINARY,
    source_root: nil,
    evidence_root: nil, stock_only: false, full_matrix: false,
    helper: nil, helper_sha256: nil,
  }
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/probe_compact_variant_bulk_w283_matrix.rb (--stock-only | --full-matrix --helper PREBUILT --helper-sha256 SHA256) [--binary FULL_SSD_CLICKHOUSE] --source-root SSD_PINNED_UPSTREAM --evidence-root EMPTY_SSD_CHILD'
    parser.on('--stock-only', 'Capture eight stock/native controls without invoking a Crystal helper') { options[:stock_only] = true }
    parser.on('--full-matrix', 'Capture stock controls, helper reads, and generated writer/native interop') { options[:full_matrix] = true }
    parser.on('--helper PATH', 'Prebuilt W283 Crystal helper; full-matrix only') { |value| options[:helper] = value }
    parser.on('--helper-sha256 SHA256', 'Exact lowercase SHA-256 of the prebuilt helper') { |value| options[:helper_sha256] = value }
    parser.on('--evidence-root EMPTY_DIR', 'Existing empty direct child of an owned /opt/mldata_ssd/cache/crystal-click-w283.<suffix> task root') { |value| options[:evidence_root] = value }
    parser.on('--binary PATH', 'Full pinned ClickHouse runtime file below the owned SSD task root; defaults to the W283 full runtime') { |value| options[:binary] = value }
    parser.on('--source-root PATH', 'Pinned ClickHouse checkout below the owned SSD task root') { |value| options[:source_root] = value }
  end.parse!
  unless options[:evidence_root] && options[:binary] && options[:source_root] && (options[:stock_only] != options[:full_matrix])
    warn 'W283 matrix: --source-root, --evidence-root, and exactly one of --stock-only/--full-matrix are required'
    exit 2
  end
  exit(ProbeCompactVariantBulkW283Matrix::Probe.new(**options).run ? 0 : 1)
end
