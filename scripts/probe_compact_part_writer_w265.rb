#!/usr/bin/env ruby
# Bounded stock ClickHouse acceptance probe for the static Compact MRK4 writer.
# The independent native INSERT is the value oracle; the Crystal helper only
# reports physical/logical structure and is never used to invent expected rows.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require_relative 'probe_object_shared_json_interop_w241'

module ProbeCompactPartWriterW265
  W241 = ProbeObjectSharedJSONInteropW241
  FORMAT = 'compact_part_writer_w265_native_probe_v1'.freeze
  HELPER_FORMAT = 'compact_part_writer_w265_helper_v1'.freeze
  PART_NAME = 'all_1_1_0'.freeze
  HELPER_SOURCE = File.expand_path('compact_part_writer_w265_helper.cr', __dir__).freeze
  FIXTURE_SOURCE = File.expand_path('../spec/support/compact_part_writer_w265_fixture.cr', __dir__).freeze
  W264_FIXTURE_SOURCE = File.expand_path('../spec/support/compact_part_writer_w264_fixture.cr', __dir__).freeze
  W241_SOURCE = File.expand_path('probe_object_shared_json_interop_w241.rb', __dir__).freeze
  MAX_PART_FILES = 128
  MAX_PART_BYTES = 64 * 1024 * 1024
  MARK_ROWS = [2, 2, 2, 2, 0].freeze
  SCHEMA = [
    ['pk', 'UInt64'], ['u', 'UInt64'], ['text', 'String'],
    ['maybe', 'Nullable(UInt64)'], ['gap', 'Array(Nullable(UInt64))'],
    ['arr', 'Array(Nullable(UInt64))'], ['pair', 'Tuple(String, Nullable(UInt64))'],
    ['lookup', 'Map(String, UInt64)'],
  ].map(&:freeze).freeze
  VALUE_COLUMNS = SCHEMA.drop(1).map(&:first).freeze
  TAG = {
    pin: '__W265_PIN__', schema: '__W265_SCHEMA__', path: '__W265_PATH__',
    part: '__W265_PART__', check_begin: '__W265_CHECK_BEGIN__',
    check_end: '__W265_CHECK_END__', rows: '__W265_ROWS__', empty: '__W265_EMPTY__',
  }.freeze
  SLOT_ROSTER_MRK4 = [
    ['pk', 'pk'], ['u', 'u'], ['text', 'text'], ['maybe', 'maybe.null'], ['maybe', 'maybe'],
    ['gap', 'gap.size0'], ['gap', 'gap.null'], ['gap', 'gap'],
    ['arr', 'arr.size0'], ['arr', 'arr.null'], ['arr', 'arr'],
    ['pair', 'pair%2E1'], ['pair', 'pair%2E2.null'], ['pair', 'pair%2E2'],
    ['lookup', 'lookup.size0'], ['lookup', 'lookup%2Ekeys'], ['lookup', 'lookup%2Evalues'],
  ].map(&:freeze).freeze
  SLOT_ROSTER_MRK3 = SCHEMA.map { |name, _type| [name, nil].freeze }.freeze

  # Independent literal native fixture. These are not loaded from either
  # Crystal fixture or a helper response. Binary text is only compared as hex;
  # tuple/map labels remain valid UTF-8 because native JSON encodes them.
  ROWS = [
    {pk: 101, u: 0, maybe: nil, text: ''.b, gap: [], arr: [], pair: ['a', 0], map: []},
    {pk: 102, u: 1, maybe: 0, text: 'alpha'.b, gap: [], arr: [nil], pair: ['b', nil], map: [['alpha', 1]]},
    {pk: 103, u: 18_446_744_073_709_551_615, maybe: 1, text: "utf8-λ".b,
     gap: [0, 7], arr: [0, nil, 5], pair: ['c', 3], map: []},
    {pk: 104, u: 42, maybe: nil, text: "contains\0nul".b, gap: [], arr: [], pair: ['', nil],
     map: [['zero', 0], ['max', 99]]},
    {pk: 105, u: 9_007_199_254_740_993, maybe: 50, text: ['00ff8041'].pack('H*'),
     gap: [nil, 9], arr: [50], pair: ['tuple-tail', 9], map: [['one', 7]]},
    {pk: 106, u: 7, maybe: 42, text: ('crystal-' * 1024).b,
     gap: [], arr: [nil, 0], pair: ['λ', 1], map: []},
    {pk: 107, u: 123_456_789, maybe: nil, text: 'tail'.b,
     gap: [42], arr: [42, 42, 42], pair: ["NUL\0key", 42], map: [['left', 4], ['right', 9]]},
    {pk: 108, u: 108, maybe: 7, text: 'last'.b, gap: [], arr: [1], pair: ['last', 0], map: [['last', 108]]},
  ].map(&:freeze).freeze

  class Failure < StandardError; end

  class Probe
    def initialize(binary:, helper:, evidence_root:)
      @binary = validate_executable(binary, 'pinned ClickHouse')
      @helper = validate_executable(helper, 'prebuilt W265 helper')
      @root = validate_root(evidence_root)
      @repo = File.realpath(File.expand_path('..', __dir__))
      @runner = W241::Probe.new(@binary, @helper, @root)
      @invocations = @runner.instance_variable_get(:@invocations)
      @token = Digest::SHA256.hexdigest(@root)[0, 8]
      @tables = {}
      @stages = {}
      @sources = [__FILE__, HELPER_SOURCE, FIXTURE_SOURCE, W264_FIXTURE_SOURCE, W241_SOURCE]
        .map { |path| File.realpath(path) }.uniq.sort
    end

    def run
      prepare!
      write_and_audit_mrk3_default!
      write_and_audit_mrk4!
      capture_native_reference!
      compare_reference_and_generated_tapes!
      attach_and_read_default_mrk3!
      attach_and_read_generated!
      capture_mutation_sensitivity!
      verify_source_pins!
      summary = build_summary('observed')
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      write_new(File.join(@root, 'summary.md'), render_summary(summary))
      puts "W265 status=default_mrk3_and_explicit_mrk4_native_attach_observed; rows=8; marks=4+EOF; slots=17; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      persist_inconclusive(error)
      warn "W265 native interoperability probe inconclusive: #{@fatal_error}"
      false
    end

    private

    def fail!(message)
      raise Failure, "W265: #{message}"
    end

    def validate_root(path)
      fail!('evidence root is required') unless path && !path.empty?
      expanded = File.expand_path(path)
      fail!('evidence root must be a direct child of /private/tmp') unless
        File.dirname(expanded) == File.realpath('/private/tmp')
      fail!('evidence root must already exist, be empty, and not be symlinked') unless
        File.directory?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded && Dir.children(expanded).empty?
      expanded
    end

    def validate_executable(path, label)
      fail!("#{label} is absent, non-executable, or symlinked") unless
        path && File.file?(File.expand_path(path)) && File.executable?(File.expand_path(path)) && !File.symlink?(File.expand_path(path))
      File.realpath(path)
    end

    def prepare!
      %w[invocations stores parts generated].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
      @binary_sha_before = binary_sha
      @helper_sha_before = helper_sha
      fail!('pinned ClickHouse SHA differs before capture') unless @binary_sha_before == W241::BINARY_SHA256
      @source_hashes_before = @sources.to_h { |path| [path.delete_prefix(@repo + File::SEPARATOR), sha(path)] }
    end

    def binary_sha
      Digest::SHA256.file(@binary).hexdigest
    end

    def helper_sha
      Digest::SHA256.file(@helper).hexdigest
    end

    def sha(path)
      Digest::SHA256.file(path).hexdigest
    end

    def write_new(path, bytes)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes) }
    end

    def native(label, store, sql)
      pinned = [@runner.send(:pin_sql), sql].join("\n")
      @runner.send(:native, label, store, pinned)
    end

    def classify_native!(result, label)
      record = result.fetch(:record)
      fail!("#{label} timed out or had an infrastructure error: #{record.inspect}") unless
        !record[:timed_out] && record[:spawn_error].nil? && record[:stdin_write_error].nil? &&
        record[:stdout_read_error].nil? && record[:stderr_read_error].nil? && result[:status] && result[:status].termsig.nil?
      state = result.fetch(:classification)
      fail!("#{label} was not a bounded native success/refusal: #{record.inspect}") unless %w[success server_exception].include?(state)
      if state == 'success'
        @runner.send(:assert_native_success!, result, label)
      else
        fail!("#{label} native executable identity changed") unless record[:binary_sha_after] == W241::BINARY_SHA256
      end
      state
    end

    def native_success!(label, store, sql)
      result = native(label, store, sql)
      state = classify_native!(result, label)
      fail!("#{label} was refused: #{result[:record].inspect}") unless state == 'success'
      @runner.send(:assert_pin!, result[:stdout], label)
      result
    end

    def native_lines(result, label)
      @runner.send(:assert_pin!, result[:stdout], label)
      text = result[:stdout].dup.force_encoding(Encoding::UTF_8)
      fail!("#{label} stdout is not valid UTF-8/newline terminated") unless text.valid_encoding? && text.end_with?("\n")
      text.lines.map(&:chomp)
    end

    def tag(kind, case_name = nil, window = nil)
      suffix = case_name ? "_#{case_name.upcase}" : ''
      suffix += "_#{window.upcase}" if window
      "__W265_#{kind.to_s.upcase}#{suffix}__"
    end

    def tagged(lines, expected, width)
      lines.select { |line| line.start_with?(expected + "\t") }.map do |line|
        fields = line.split("\t", -1)
        fail!("malformed #{expected} TSV row") unless fields.size == width
        fields
      end
    end

    def table_name(case_name)
      "w265_#{@token}_#{case_name}"
    end

    def store_path(case_name)
      File.join(@root, 'stores', 'native', case_name)
    end

    def declarations
      SCHEMA.map { |name, type| "`#{name}` #{type}" }.join(', ')
    end

    def settings(mark_layout)
      [
        'index_granularity=2', 'index_granularity_bytes=10485760', 'enable_mixed_granularity_parts=1',
        'min_rows_for_wide_part=1000000', 'min_bytes_for_wide_part=104857600', 'min_level_for_wide_part=0',
        'compress_marks=0', 'compress_primary_key=0', "write_marks_for_substreams_in_compact_parts=#{mark_layout}",
        'min_compress_block_size=0', 'max_compress_block_size=4096',
        'ratio_of_defaults_for_sparse_serialization=1.0', "default_compression_codec='LZ4'",
        "serialization_info_version='with_types'", 'propagate_types_serialization_versions_to_nested_types=true',
        "string_serialization_version='single_stream'", "nullable_serialization_version='basic'",
        "map_serialization_version='basic'", "map_serialization_version_for_zero_level_parts='basic'",
      ].join(', ')
    end

    def create_sql(table, mark_layout)
      "CREATE TABLE default.#{table} (#{declarations}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings(mark_layout)};\n"
    end

    def schema_query(table, case_name)
      "SELECT '#{tag(:schema, case_name)}', name, type FROM system.columns " \
        "WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;\n"
    end

    def table_path_query(table, case_name)
      "SELECT '#{tag(:path, case_name)}', arrayElement(data_paths, 1) FROM system.tables " \
        "WHERE database='default' AND name='#{table}' FORMAT TSVRaw;\n"
    end

    def part_query(table, case_name)
      "SELECT '#{tag(:part, case_name)}', table, name, path, part_type, toString(rows), toString(marks) " \
        "FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;\n"
    end

    def create_table!(case_name, mark_layout)
      table = table_name(case_name)
      @tables[case_name] = table
      store = store_path(case_name)
      result = native_success!("#{case_name}_create", store,
                               create_sql(table, mark_layout) + schema_query(table, case_name) + table_path_query(table, case_name))
      lines = native_lines(result, "#{case_name} create")
      observed_schema = tagged(lines, tag(:schema, case_name), 3).map { |row| row.drop(1) }
      fail!("#{case_name} schema differs") unless observed_schema == SCHEMA
      paths = tagged(lines, tag(:path, case_name), 2)
      fail!("#{case_name} table data path is absent") unless paths.size == 1 && paths.first[1] && !paths.first[1].empty?
      data_path = safe_native_path(paths.first[1])
      @stages[case_name] = {create: result[:record], table_path: data_path}
      [table, store, data_path]
    end

    def safe_native_path(path)
      expanded = File.expand_path(path)
      native_root = File.join(@root, 'stores', 'native')
      fail!("native path escaped isolated stores: #{path}") unless expanded.start_with?(native_root + File::SEPARATOR)
      current = native_root
      expanded.delete_prefix(native_root + File::SEPARATOR).split(File::SEPARATOR).each do |part|
        current = File.join(current, part)
        fail!("symlink in native path: #{current}") if File.symlink?(current)
      end
      expanded
    end

    def sql_bytes(value)
      "unhex('#{value.b.unpack1('H*')}')"
    end

    def sql_nullable(value)
      value.nil? ? "CAST(NULL, 'Nullable(UInt64)')" : "toUInt64(#{value})"
    end

    def sql_array(values)
      return "CAST([], 'Array(Nullable(UInt64))')" if values.empty?
      "[#{values.map { |value| sql_nullable(value) }.join(', ')}]"
    end

    def sql_map(values)
      return "CAST([], 'Map(String, UInt64)')" if values.empty?
      "map(#{values.flat_map { |key, value| [sql_bytes(key), "toUInt64(#{value})"] }.join(', ')})"
    end

    def sql_tuple(value)
      "tuple(#{sql_bytes(value[0])}, #{sql_nullable(value[1])})"
    end

    def insert_sql(table)
      rows = ROWS.map do |row|
        values = [row[:pk].to_s, "toUInt64(#{row[:u]})", sql_bytes(row[:text]), sql_nullable(row[:maybe]),
                  sql_array(row[:gap]), sql_array(row[:arr]), sql_tuple(row[:pair]), sql_map(row[:map])]
        "(#{values.join(', ')})"
      end
      "INSERT INTO default.#{table} VALUES\n#{rows.join(",\n")};\n"
    end

    def capture_native_reference!
      @reference_table, @reference_store, @reference_data_path = create_table!('stock_mrk4_reference', 1)
      result = native_success!('stock_reference_insert', @reference_store, insert_sql(@reference_table))
      @stages['stock_mrk4_reference'][:insert] = result[:record]
      part_result = native_success!('stock_reference_part', @reference_store, part_query(@reference_table, 'stock_mrk4_reference'))
      rows = tagged(native_lines(part_result, 'stock reference part'), tag(:part, 'stock_mrk4_reference'), 7)
      fail!('stock reference did not produce one Compact part with 8 rows and 5 marks') unless
        rows.size == 1 && rows.first.values_at(1, 2, 4, 5, 6) == [@reference_table, PART_NAME, 'Compact', '8', '5']
      @reference_part = safe_native_path(rows.first[3])
      @reference_inventory = tree_inventory(@reference_part)
      @reference_audit = helper('stock_reference_audit', 'audit', @reference_part)
      validate_helper_report!(@reference_audit, 'mrk4', 'fresh native stock reference')
      run_check!('stock_reference', @reference_table, @reference_store)
      @reference_windows = run_all_windows!('stock_reference', @reference_table, @reference_store)
      require_payload_unchanged!(@reference_part, @reference_inventory, 'fresh native reference after reads')
    end

    def write_and_audit_mrk3_default!
      @mrk3_path = File.join(@root, 'parts', 'generated_mrk3', PART_NAME)
      Dir.mkdir(File.dirname(@mrk3_path), 0o700)
      @mrk3_write = helper('write_default_mrk3', 'write-default', @mrk3_path)
      validate_helper_report!(@mrk3_write, 'mrk3', 'default MRK3 writer output')
      @mrk3_inventory = tree_inventory(@mrk3_path)
      fail!('writer default unexpectedly emitted MRK4 sidecar') if File.exist?(File.join(@mrk3_path, 'data.mrk4'))
      fail!('default MRK3 output unexpectedly emitted MRK4 substreams sidecar') if File.exist?(File.join(@mrk3_path, 'columns_substreams.txt'))
    end

    def write_and_audit_mrk4!
      @generated_path = File.join(@root, 'parts', 'generated_mrk4', PART_NAME)
      Dir.mkdir(File.dirname(@generated_path), 0o700)
      @generated_write = helper('write_explicit_mrk4', 'write', @generated_path, 'mrk4')
      validate_helper_report!(@generated_write, 'mrk4', 'Crystal MRK4 output')
      @generated_inventory = tree_inventory(@generated_path)
    end

    def helper(label, *arguments, expected_statuses: ['ok'])
      result = @runner.send(:run_process, label, [@helper] + arguments, ''.b, 'crystal-helper',
                            expected_sha: @helper_sha_before, binary_path: @helper)
      record = result.fetch(:record)
      fail!("#{label} helper exceeded bounds or had infrastructure failure: #{record.inspect}") unless
        !record[:timed_out] && record[:spawn_error].nil? && record[:stdin_write_error].nil? &&
        record[:stdout_read_error].nil? && record[:stderr_read_error].nil? && result[:status] && result[:status].termsig.nil?
      fail!("#{label} helper returned an application error: #{record.inspect}") unless
        result[:classification] == 'success' && result[:status].success? && result[:stderr].empty?
      parsed = JSON.parse(result[:stdout].force_encoding(Encoding::UTF_8))
      fail!("#{label} helper envelope differs") unless parsed.is_a?(Hash) && parsed['format'] == HELPER_FORMAT &&
        parsed['action'] == arguments.first && expected_statuses.include?(parsed['status'])
      parsed
    rescue JSON::ParserError => error
      raise Failure, "#{label} helper output is not JSON: #{error.message}"
    end

    def validate_helper_report!(report, mode, label)
      fail!("#{label} writer mode differs") unless report['mode'] == mode
      fail!("#{label} row count/mark rows differ") unless report['row_count'] == 8 && report['mark_rows'] == [2, 2, 2, 2]
      expected_roster = mode == 'mrk4' ? SLOT_ROSTER_MRK4 : SLOT_ROSTER_MRK3
      roster = report.fetch('physical_roster').map { |slot| [slot.fetch('column'), slot.fetch('stream')] }
      fail!("#{label} slot roster differs") unless roster == expected_roster
      substreams_file = report.fetch('files').find { |entry| entry.fetch('path') == 'columns_substreams.txt' }
      substreams_checksummed = report.fetch('checksum_entries').any? do |entry|
        entry.fetch('name') == 'columns_substreams.txt'
      end
      if mode == 'mrk4'
        fail!("#{label} MRK4 substream sidecar is missing or empty") unless
          substreams_file && substreams_file.fetch('size').positive?
        fail!("#{label} MRK4 substream sidecar must not have a checksums.txt entry") if substreams_checksummed
      else
        fail!("#{label} MRK3 unexpectedly contains the MRK4 substream sidecar") if substreams_file
        fail!("#{label} MRK3 unexpectedly checksums the MRK4 substream sidecar") if substreams_checksummed
      end
      tape = report.fetch('physical_mark_tape')
      slots = expected_roster.size
      width = slots * 16 + 8
      expected_bytes = 5 * width
      expected_file = mode == 'mrk4' ? 'data.mrk4' : 'data.mrk3'
      fail!("#{label} raw mark header/size/record width differs") unless
        tape.fetch('header_bytes') == 0 && tape.fetch('file') == expected_file && tape.fetch('slot_count') == slots &&
        tape.fetch('record_width') == width && tape.fetch('byte_size') == expected_bytes
      fail!("#{label} data.bin is not independently proven multiframe") unless
        tape.fetch('independent_frame_count') > 1
      records = tape.fetch('records')
      fail!("#{label} mark record count differs") unless records.size == MARK_ROWS.size
      records.each_with_index do |record, mark|
        fail!("#{label} mark row count differs at #{mark}") unless record.fetch('mark') == mark &&
          record.fetch('row_count').to_i == MARK_ROWS.fetch(mark) && record.fetch('pairs').size == slots
        record.fetch('pairs').each_with_index do |pair, slot|
          fail!("#{label} mark slot order differs at #{mark}/#{slot}") unless pair.fetch('slot') == slot &&
            pair.fetch('column') == expected_roster.fetch(slot)[0] && pair.fetch('stream') == expected_roster.fetch(slot)[1]
        end
      end
      terminal = records.last.fetch('pairs')
      fail!("#{label} terminal mark is not all-slot raw EOF") unless terminal.all? do |pair|
        pair.fetch('compressed_offset').to_i == report.fetch('files').find { |entry| entry['path'] == 'data.bin' }.fetch('size') &&
          pair.fetch('decompressed_offset').to_i == 0 && pair.fetch('logical_position').to_i == report.fetch('data_bin_raw_size')
      end
      fail!("#{label} value-reader signatures differ from independent writer output") unless
        report.fetch('columns').map { |column| column.fetch('name') } == VALUE_COLUMNS
      saved = report.fetch('data_bin_saved_uncompressed_hash_words')
      computed = report.fetch('data_bin_computed_uncompressed_hash_words')
      fail!("#{label} folded raw-data hash differs") unless saved == computed
      data = report.fetch('checksum_entries').find { |entry| entry.fetch('name') == 'data.bin' }
      fail!("#{label} compressed data.bin checksum declaration differs") unless data && data.fetch('compressed') &&
        data.fetch('uncompressed_size').to_i == report.fetch('data_bin_raw_size') &&
        data.fetch('uncompressed_hash_words').map(&:to_s) == computed
      report
    end

    def run_check!(case_name, table, store)
      begin_tag = tag(:check_begin, case_name)
      end_tag = tag(:check_end, case_name)
      sql = "SELECT '#{begin_tag}' FORMAT TSVRaw;\nCHECK TABLE default.#{table} FORMAT TSV;\nSELECT '#{end_tag}' FORMAT TSVRaw;\n"
      result = native_success!("#{case_name}_check", store, sql)
      lines = native_lines(result, "#{case_name} CHECK")
      active = false
      rows = []
      lines.each do |line|
        if line == begin_tag
          fail!('nested CHECK output marker') if active
          active = true
        elsif line == end_tag
          fail!('CHECK end marker without begin') unless active
          active = false
        elsif active
          rows << line
        end
      end
      fail!('CHECK output marker did not close') if active
      fail!('CHECK result is not exact one-row success') unless rows == ["#{PART_NAME}\t1\t"]
      (@stages[case_name] ||= {})[:check] = result[:record]
      rows
    end

    def expected_rows(rows)
      rows.map do |row|
        {
          pk: row[:pk], u: row[:u], text_hex: row[:text].b.unpack1('H*').downcase,
          maybe: row[:maybe], gap: row[:gap], arr: row[:arr], pair: row[:pair],
          map_keys: row[:map].map(&:first), map_values: row[:map].map(&:last),
        }
      end
    end

    def parse_native_rows(rows, label)
      rows.map do |fields|
        fail!("#{label} row width differs") unless fields.size == 10
        {
          pk: Integer(fields[1], 10), u: Integer(fields[2], 10),
          text_hex: fields[3].downcase,
          maybe: fields[4] == 'NULL' ? nil : Integer(fields[4], 10),
          gap: parse_json_hex(fields[5], "#{label} empty-child Array"),
          arr: parse_json_hex(fields[6], "#{label} Array"),
          pair: parse_json_hex(fields[7], "#{label} Tuple"),
          map_keys: parse_json_hex(fields[8], "#{label} Map keys"),
          map_values: parse_json_hex(fields[9], "#{label} Map values"),
        }
      end
    end

    def parse_json_hex(value, label)
      fail!("#{label} is not even-length hex") unless value.match?(/\A(?:[0-9a-fA-F]{2})*\z/)
      JSON.parse([value].pack('H*').force_encoding(Encoding::UTF_8))
    rescue JSON::ParserError => error
      raise Failure, "#{label} is not JSON: #{error.message}"
    end

    def rows_query(table, case_name, window)
      predicate = case window
                  when 'full' then ''
                  when 'middle' then ' WHERE pk BETWEEN 103 AND 106'
                  when 'last' then ' WHERE pk = 108'
                  else raise Failure, "unknown W265 window #{window}"
                  end
      expressions = [
        'toString(pk)', 'toString(u)', 'hex(text)', "if(isNull(maybe), 'NULL', toString(maybe))",
        'hex(toJSONString(gap))', 'hex(toJSONString(arr))', 'hex(toJSONString(pair))',
        'hex(toJSONString(mapKeys(lookup)))', 'hex(toJSONString(mapValues(lookup)))',
      ]
      "SELECT '#{tag(:rows)}', #{expressions.join(', ')} FROM default.#{table}#{predicate} " \
        "ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;\n"
    end

    def empty_query(table, case_name)
      "SELECT '#{tag(:empty, case_name)}', toString(count()) FROM default.#{table} WHERE pk > 108 " \
        "SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;\n"
    end

    def run_window!(case_name, table, store, window)
      sql = if window == 'empty'
              empty_query(table, case_name)
            else
              rows_query(table, case_name, window)
            end
      result = native_success!("#{case_name}_select_#{window}", store, sql)
      lines = native_lines(result, "#{case_name} #{window} SELECT")
      expected = case window
                 when 'full' then expected_rows(ROWS)
                 when 'middle' then expected_rows(ROWS[2, 4])
                 when 'last' then expected_rows(ROWS.last(1))
                 when 'empty' then [[tag(:empty, case_name), '0'].join("\t")]
                 end
      actual = if window == 'empty'
                 tagged(lines, tag(:empty, case_name), 2).map { |fields| fields.join("\t") }
               else
                 parse_native_rows(tagged(lines, tag(:rows), 10), "#{case_name} #{window} SELECT")
               end
      fail!("#{case_name} #{window} rows differ from independent literals") unless actual == expected
      (@stages[case_name] ||= {})["select_#{window}".to_sym] = result[:record]
      expected_digest = Digest::SHA256.hexdigest(JSON.generate(expected))
      {state: 'exact_values', rows: actual.size, expected_sha256: expected_digest}
    end

    def run_all_windows!(case_name, table, store)
      %w[full middle last empty].to_h { |window| [window, run_window!(case_name, table, store, window)] }
    end

    def attach_part!(source, data_path, case_name)
      @runner.send(:attach_part!, source, data_path)
      detached = File.join(data_path, 'detached', PART_NAME)
      source_inventory = tree_inventory(source)
      detached_inventory = tree_inventory(detached)
      fail!("#{case_name} detached copy differs from source") unless source_inventory == detached_inventory
      @stages[case_name][:detached_source_inventory] = source_inventory
      detached
    end

    def active_part!(case_name, table, store)
      result = native_success!("#{case_name}_active_part", store, part_query(table, case_name))
      rows = tagged(native_lines(result, "#{case_name} active part"), tag(:part, case_name), 7)
      fail!("#{case_name} did not produce one active Compact part") unless rows.size == 1 &&
        rows.first.values_at(1, 2, 4, 5, 6) == [table, PART_NAME, 'Compact', '8', '5']
      path = safe_native_path(rows.first[3])
      inventory = tree_inventory(path)
      @stages[case_name][:active_part_path] = path
      @stages[case_name][:active_part_inventory] = inventory
      path
    end

    def attach_and_observe!(case_name, table, store, data_path, part_path, expect_values:)
      attach_part!(part_path, data_path, case_name)
      detached_payload = payload_from_inventory(@stages.fetch(case_name).fetch(:detached_source_inventory))
      attach = native("#{case_name}_attach", store, "ALTER TABLE default.#{table} ATTACH PART '#{PART_NAME}';\n")
      state = classify_native!(attach, "#{case_name} ATTACH")
      @stages[case_name][:attach] = attach[:record]
      if state == 'success'
        @runner.send(:assert_pin!, attach[:stdout], "#{case_name} ATTACH")
        active = active_part!(case_name, table, store)
        @stages[case_name][:active_payload_matches_detached] = payload_inventory(active) == detached_payload
        if expect_values
          fail!('native ATTACH changed generated data/marks payload') unless @stages[case_name][:active_payload_matches_detached]
        end
        @stages[case_name][:check] = check_outcome!(case_name, table, store)
        @stages[case_name][:selects] = {}
        %w[full middle last empty].each do |window|
          begin
            @stages[case_name][:selects][window] = run_window!(case_name, table, store, window)
          rescue Failure => error
            raise if expect_values
            @stages[case_name][:selects][window] = {state: 'application_oracle_mismatch', detail: error.message}
          end
        end
      else
        @stages[case_name][:active_part] = 'not_run_attach_refusal'
        @stages[case_name][:check] = 'not_run_attach_refusal'
        @stages[case_name][:selects] = 'not_run_attach_refusal'
        fail!("#{case_name} ATTACH was refused") if expect_values
      end
    end

    def check_outcome!(case_name, table, store)
      begin_tag = tag(:check_begin, case_name)
      end_tag = tag(:check_end, case_name)
      result = native("#{case_name}_check", store,
                      "SELECT '#{begin_tag}' FORMAT TSVRaw;\nCHECK TABLE default.#{table} FORMAT TSV;\nSELECT '#{end_tag}' FORMAT TSVRaw;\n")
      state = classify_native!(result, "#{case_name} CHECK")
      record = {state: state, invocation: result[:record]}
      if state == 'success'
        @runner.send(:assert_pin!, result[:stdout], "#{case_name} CHECK")
        lines = result[:stdout].force_encoding(Encoding::UTF_8).lines.map(&:chomp)
        rows = check_rows(lines, begin_tag, end_tag)
        record[:rows] = rows
        record[:exact_success] = rows == ["#{PART_NAME}\t1\t"]
      end
      if case_name.start_with?('generated_')
        fail!("#{case_name} CHECK did not report the exact healthy part") unless
          state == 'success' && record[:exact_success]
      end
      record
    end

    def check_rows(lines, begin_tag, end_tag)
      active = false
      rows = []
      lines.each do |line|
        if line == begin_tag
          fail!('nested CHECK markers') if active
          active = true
        elsif line == end_tag
          fail!('CHECK end without begin') unless active
          active = false
        elsif active
          rows << line
        end
      end
      fail!('unterminated CHECK markers') if active
      rows
    end

    def attach_and_read_default_mrk3!
      table, store, data_path = create_table!('generated_mrk3_default', 0)
      attach_and_observe!('generated_mrk3_default', table, store, data_path, @mrk3_path, expect_values: true)
      @generated_mrk3_windows = @stages['generated_mrk3_default'][:selects]
    end

    def attach_and_read_generated!
      table, store, data_path = create_table!('generated_mrk4', 1)
      attach_and_observe!('generated_mrk4', table, store, data_path, @generated_path, expect_values: true)
      @generated_windows = @stages['generated_mrk4'][:selects]
    end

    def payload_inventory(path)
      payload_from_inventory(tree_inventory(path))
    end

    def payload_from_inventory(entries)
      %w[data.bin data.mrk3 data.mrk4].to_h do |name|
        [name, entries[name]]
      end.reject { |_name, item| item.nil? }
    end

    def tree_inventory(path)
      fail!("part is missing or symlinked: #{path}") unless File.directory?(path) && !File.symlink?(path)
      entries = {}
      total = 0
      Find.find(path) do |item|
        next if item == path
        stat = File.lstat(item)
        fail!("part contains symlink or special file: #{item}") unless !stat.symlink? && (stat.directory? || stat.file?)
        next if stat.directory?
        relative = item.delete_prefix(path + File::SEPARATOR)
        total += stat.size
        fail!('part inventory exceeds bounded file/byte count') unless entries.size < MAX_PART_FILES && total <= MAX_PART_BYTES
        entries[relative] = {size: stat.size, sha256: sha(item)}
      end
      entries
    end

    def require_payload_unchanged!(path, before, label)
      after = tree_inventory(path)
      selected = %w[data.bin data.mrk3 data.mrk4].to_h { |name| [name, before[name]] }.reject { |_name, value| value.nil? }
      actual = payload_inventory(path)
      fail!("#{label} changed data or mark payload bytes") unless actual == selected
      true
    end

    def compare_reference_and_generated_tapes!
      @tape_comparison = {
        stock_raw_sha256: @reference_audit.fetch('data_bin_raw_sha256'),
        crystal_raw_sha256: @generated_write.fetch('data_bin_raw_sha256'),
        stock_raw_bytes: @reference_audit.fetch('data_bin_raw_size'),
        crystal_raw_bytes: @generated_write.fetch('data_bin_raw_size'),
        default_mrk3_raw_sha256: @mrk3_write.fetch('data_bin_raw_sha256'),
        default_mrk3_raw_bytes: @mrk3_write.fetch('data_bin_raw_size'),
        equal_logical_mark_coordinates: false,
        compressed_coordinate_bytes_compared: false,
      }
      fail!('native stock and Crystal raw data.bin tapes differ') unless
        @reference_audit.fetch('data_bin_raw_sha256') == @generated_write.fetch('data_bin_raw_sha256') &&
        @reference_audit.fetch('data_bin_raw_size') == @generated_write.fetch('data_bin_raw_size')
      fail!('default MRK3 and native raw data.bin tapes differ') unless
        @reference_audit.fetch('data_bin_raw_sha256') == @mrk3_write.fetch('data_bin_raw_sha256') &&
        @reference_audit.fetch('data_bin_raw_size') == @mrk3_write.fetch('data_bin_raw_size')
      fail!('native and Crystal decoded value signatures differ') unless
        @reference_audit.fetch('columns').map { |column| column.fetch('signatures') } ==
        @generated_write.fetch('columns').map { |column| column.fetch('signatures') }
      fail!('default MRK3 and native decoded value signatures differ') unless
        @reference_audit.fetch('columns').map { |column| column.fetch('signatures') } ==
        @mrk3_write.fetch('columns').map { |column| column.fetch('signatures') }
      native_positions = logical_positions(@reference_audit)
      crystal_positions = logical_positions(@generated_write)
      fail!('native/Crystal logical callback positions differ') unless native_positions == crystal_positions
      @tape_comparison[:equal_logical_mark_coordinates] = true
      @tape_comparison[:native_logical_coordinates] = native_positions
    end

    def logical_positions(report)
      report.fetch('physical_mark_tape').fetch('records').map do |record|
        record.fetch('pairs').map { |pair| pair.fetch('logical_position') }
      end
    end

    def literal_rows_for_summary
      ROWS.map do |row|
        {
          pk: row[:pk], u: row[:u], text_hex: row[:text].b.unpack1('H*'),
          maybe: row[:maybe], gap: row[:gap], arr: row[:arr], pair: row[:pair],
          map_keys: row[:map].map(&:first), map_values: row[:map].map(&:last),
        }
      end
    end

    def capture_mutation_sensitivity!
      @mutations = {}
      %w[stale fold child roster].each do |kind|
        source = @generated_path
        destination = File.join(@root, 'parts', "mutant_#{kind}", PART_NAME)
        Dir.mkdir(File.dirname(destination), 0o700)
        before = tree_inventory(source)
        mutation = helper("copy_mutant_#{kind}", 'copy-mutant', kind, source, destination)
        @mutations[kind] = {helper: mutation, changed_files: changed_file_names(before, tree_inventory(destination))}
        validate_mutation!(kind, source, destination, before, mutation)
        selected_column = kind == 'stale' ? 'pk' : 'gap'
        outcome = helper("local_inspect_mutant_#{kind}", 'inspect-outcome', destination, selected_column,
                         expected_statuses: %w[accepted rejected])
        @mutations[kind][:local_reader] = outcome
        if %w[child roster stale].include?(kind)
          fail!("local reader accepted #{kind} mutant") unless outcome['status'] == 'rejected'
        end
        if kind == 'stale'
          unselected = helper('local_inspect_mutant_stale_unselected_gap', 'inspect-outcome', destination, 'gap',
                              expected_statuses: %w[accepted rejected])
          @mutations[kind][:unselected_gap_reader] = unselected
          fail!('gap reader unexpectedly touched the stale pk-only frame') unless unselected['status'] == 'accepted'
        end
        @mutations[kind][:native] = run_mutant_native_case(kind, destination)
      end
      stale = @mutations.fetch('stale').fetch(:native)
      stale_rows = stale[:check_rows]
      stale_fields = stale_rows.is_a?(Array) && stale_rows.size == 1 ? stale_rows.first.split("\t", -1) : []
      fail!('native stale CHECK did not report the exact data.bin checksum failure') unless
        stale[:attach_state] == 'success' && stale[:check_state] == 'success' &&
        stale_fields.size == 3 && stale_fields[0] == PART_NAME && stale_fields[1] == '0' &&
        stale_fields[2].include?('Checksum mismatch for file data.bin') &&
        stale_fields[2].include?('(CHECKSUM_DOESNT_MATCH)')
      @mutations.fetch('stale')[:interpretation] =
        'The selected pk read rejects its touched stale frame; gap accepts because its first selected frame is later. Native CHECK independently reports the stale data.bin checksum as 0.'
      fold = @mutations.fetch('fold').fetch(:native)
      fail!('native fold-only sensitivity control did not preserve exact values') unless
        fold[:attach_state] == 'success' && fold[:check_state] == 'success' && fold[:check_rows] == ["#{PART_NAME}\t1\t"] &&
        fold[:selects].values.all? { |item| item[:state] == 'exact_values' }
      @mutations.fetch('fold')[:interpretation] = 'Pinned native CHECK/read confirms this runtime does not qualify the saved uncompressed fold as a verifier.'
    end

    def changed_file_names(before, after)
      (before.keys | after.keys).select { |name| before[name] != after[name] }.sort
    end

    def validate_mutation!(kind, source, destination, before, report)
      source_inventory = normalize_helper_inventory(report.fetch('source_files'))
      mutant_inventory = normalize_helper_inventory(report.fetch('mutant_files'))
      fail!("#{kind} mutator source inventory differs") unless source_inventory == before
      fail!("#{kind} mutator did not report its copied result") unless mutant_inventory == tree_inventory(destination)
      changed = changed_file_names(source_inventory, mutant_inventory)
      expected = case kind
                 when 'stale' then %w[data.bin]
                 when 'fold' then %w[checksums.txt]
                 when 'child' then %w[checksums.txt data.mrk4]
                 when 'roster' then %w[columns_substreams.txt]
                 end
      fail!("#{kind} mutant changed unexpected physical files: #{changed.inspect}") unless changed == expected
      if kind == 'roster'
        original_checksums = File.binread(File.join(source, 'checksums.txt'))
        mutant_checksums = File.binread(File.join(destination, 'checksums.txt'))
        fail!('roster-only mutant changed checksums.txt bytes') unless original_checksums == mutant_checksums
      end
      if kind == 'child'
        original = File.binread(File.join(source, 'data.mrk4'))
        changed_mark = File.binread(File.join(destination, 'data.mrk4'))
        offsets = original.bytes.zip(changed_mark.bytes).each_index.select { |index| original.getbyte(index) != changed_mark.getbyte(index) }
        pair_start = 2 * 280 + 7 * 16
        fail!('child mutant did not change a nonempty byte within only the selected pair') unless
          !offsets.empty? && offsets.all? { |offset| (pair_start...pair_start + 16).cover?(offset) }
        null_start = 2 * 280 + 6 * 16
        fail!('child mutant did not bind the gap value pair to the authenticated gap.null pair') unless
          read_u64(changed_mark, pair_start) == read_u64(original, null_start) &&
          read_u64(changed_mark, pair_start + 8) == read_u64(original, null_start + 8)
      end
    end

    def normalize_helper_inventory(entries)
      entries.to_h { |entry| [entry.fetch('path'), {size: entry.fetch('size'), sha256: entry.fetch('sha256')}] }
    end

    def read_u64(bytes, offset)
      bytes.byteslice(offset, 8).unpack1('Q<')
    end

    def run_mutant_native_case(kind, part)
      case_name = "mutant_#{kind}"
      table, store, data_path = create_table!(case_name, 1)
      attach_part!(part, data_path, case_name)
      attach = native("#{case_name}_attach", store, "ALTER TABLE default.#{table} ATTACH PART '#{PART_NAME}';\n")
      attach_state = classify_native!(attach, "#{case_name} ATTACH")
      stage = {attach_state: attach_state, attach_record: attach[:record], check_state: 'not_run', selects: {}}
      if attach_state == 'success'
        @runner.send(:assert_pin!, attach[:stdout], "#{case_name} ATTACH")
        active_part!(case_name, table, store)
        check = native("#{case_name}_check", store,
                       "SELECT '#{tag(:check_begin, case_name)}' FORMAT TSVRaw;\nCHECK TABLE default.#{table} FORMAT TSV;\nSELECT '#{tag(:check_end, case_name)}' FORMAT TSVRaw;\n")
        check_state = classify_native!(check, "#{case_name} CHECK")
        stage[:check_state] = check_state
        stage[:check_record] = check[:record]
        if check_state == 'success'
          @runner.send(:assert_pin!, check[:stdout], "#{case_name} CHECK")
          stage[:check_rows] = check_rows(check[:stdout].force_encoding(Encoding::UTF_8).lines.map(&:chomp),
                                          tag(:check_begin, case_name), tag(:check_end, case_name))
        end
      end
      %w[full middle last empty].each do |window|
        result = native("#{case_name}_select_#{window}", store,
                        window == 'empty' ? empty_query(table, case_name) : rows_query(table, case_name, window))
        state = classify_native!(result, "#{case_name} #{window} SELECT")
        if state == 'server_exception'
          stage[:selects][window] = {state: 'server_exception', invocation: result[:record]}
          next
        end
        lines = native_lines(result, "#{case_name} #{window} SELECT")
        expected = case window
                   when 'full' then expected_rows(ROWS)
                   when 'middle' then expected_rows(ROWS[2, 4])
                   when 'last' then expected_rows(ROWS.last(1))
                   when 'empty' then [[tag(:empty, case_name), '0'].join("\t")]
                   end
        actual = if window == 'empty'
                   tagged(lines, tag(:empty, case_name), 2).map { |fields| fields.join("\t") }
                 else
                   parse_native_rows(tagged(lines, tag(:rows), 10), "#{case_name} #{window} SELECT")
                 end
        stage[:selects][window] = {
          state: actual == expected ? 'exact_values' : 'value_mismatch',
          rows: actual.size,
          invocation: result[:record],
        }
      end
      stage
    end

    def verify_source_pins!
      @binary_sha_after = binary_sha
      @helper_sha_after = helper_sha
      @source_hashes_after = @sources.to_h { |path| [path.delete_prefix(@repo + File::SEPARATOR), sha(path)] }
      fail!('pinned native executable changed during the probe') unless @binary_sha_after == W241::BINARY_SHA256
      fail!('helper executable changed during the probe') unless @helper_sha_after == @helper_sha_before
      fail!('a hashed W265/W241 source changed during the probe') unless @source_hashes_after == @source_hashes_before
      require_payload_unchanged!(@reference_part, @reference_inventory, 'native stock reference')
      require_payload_unchanged!(@mrk3_path, @mrk3_inventory, 'Crystal default-MRK3 source')
      require_payload_unchanged!(@generated_path, @generated_inventory, 'Crystal-generated MRK4 source')
    end

    def build_summary(status)
      {
        format: FORMAT,
        status: status,
        fatal_error: @fatal_error,
        runtime: {path: @binary, sha256_expected: W241::BINARY_SHA256,
                  sha256_before: @binary_sha_before, sha256_after: @binary_sha_after},
        helper: {path: @helper, sha256_before: @helper_sha_before, sha256_after: @helper_sha_after},
        source_hashes_before: @source_hashes_before,
        source_hashes_after: @source_hashes_after,
        fixture: {schema: SCHEMA, rows: literal_rows_for_summary, mark_rows: MARK_ROWS},
        mrk3_default: @mrk3_write,
        mrk4_generated: @generated_write,
        stock_reference: {part: @reference_part, audit: @reference_audit, stages: @stages['stock_mrk4_reference']},
        tape_comparison: @tape_comparison,
        generated_mrk3_native: @stages['generated_mrk3_default'],
        generated_mrk3_windows: @generated_mrk3_windows,
        generated_native: @stages['generated_mrk4'],
        generated_windows: @generated_windows,
        stock_windows: @reference_windows,
        mutation_sensitivity: @mutations,
        invocations: @invocations,
        evidence_root: @root,
        interpretation: {
          native_value_oracle: 'Independent literal INSERT and exact full/middle/last/empty SELECT rows are primary value evidence; helper signatures are cross-checks only.',
          physical_mark_oracle: 'Raw MRK3/MRK4 records are headerless exact-width tapes; every named slot pair is resolved against an independent compressed-frame census and cross-checked with the authenticated physical context, including explicit terminal EOF.',
          fold_sensitivity: 'A checksums-only uncompressed-fold mutant is expected to retain native CHECK and values on this pinned runtime; this is a measured sensitivity gap, not a corruption claim.',
          compressed_coordinates: 'Stock and Crystal compressed-frame pairs need not be byte-equal; the comparison is over decoded logical positions and exact decompressed data.bin bytes.',
          failure_policy: 'Infrastructure failure is inconclusive. Native ATTACH, CHECK, and SELECT are recorded as distinct stages for each copy-only mutant.',
        },
      }
    end

    def render_summary(summary)
      [
        '# W265 native Compact writer probe', '',
        "- Status: `#{summary[:status]}`",
        "- Evidence root: `#{@root}`",
        "- Native value oracle: independent INSERT + exact full/middle/last/empty SELECTs.",
        "- Physical mark contracts: default plain MRK3 and explicit 17-slot MRK4, each with four two-row records and an EOF record.",
        "- Fold control: recorded as a native CHECK sensitivity gap, never as evidence that CHECK verifies the uncompressed fold.",
        '', 'Detailed invocations and per-stage records are in `summary.json` and `invocations/`.', '',
      ].join("\n")
    end

    def persist_inconclusive(error)
      return if File.exist?(File.join(@root, 'summary.json'))
      @binary_sha_after = binary_sha rescue nil
      @helper_sha_after = helper_sha rescue nil
      summary = if @binary_sha_before
                  build_summary('inconclusive')
                else
                  {format: FORMAT, status: 'inconclusive', fatal_error: "#{error.class}: #{error.message}", evidence_root: @root}
                end
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
    rescue StandardError => summary_error
      warn "W265 inconclusive summary persistence failed: #{summary_error.class}: #{summary_error.message}"
    end
  end
end

def main
  options = {binary: ProbeCompactPartWriterW265::W241::BINARY}
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/probe_compact_part_writer_w265.rb --evidence-root EMPTY_CHILD_OF_PRIVATE_TMP --crystal-helper EXECUTABLE [--clickhouse CLICKHOUSE]'
    parser.on('--clickhouse PATH') { |value| options[:binary] = value }
    parser.on('--crystal-helper PATH') { |value| options[:helper] = value }
    parser.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
  end.parse!
  raise 'evidence root is required via --evidence-root' unless options[:evidence_root]
  raise 'prebuilt Crystal helper is required via --crystal-helper' unless options[:helper]
  exit(ProbeCompactPartWriterW265::Probe.new(binary: options[:binary], helper: options[:helper],
                                              evidence_root: options[:evidence_root]).run ? 0 : 1)
end

main if $PROGRAM_NAME == __FILE__
