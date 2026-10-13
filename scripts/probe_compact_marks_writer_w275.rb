#!/usr/bin/env ruby
# Bounded native oracle for compressed Compact marks. Stock native parts are
# captured first; only then may the prebuilt local writer helper be exercised.

require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require_relative 'probe_compact_part_writer_w264'
require_relative 'probe_compact_part_writer_w273'

module ProbeCompactMarksWriterW275
  W264 = ProbeCompactPartWriterW264
  W273 = ProbeCompactPartWriterW273
  W241 = W273::W241

  FORMAT = 'compact_marks_writer_w275_native_probe_v1'.freeze
  HELPER_FORMAT = 'compact_marks_writer_w275_helper_v1'.freeze
  PROBE_SOURCE = File.expand_path(__FILE__).freeze
  HELPER_SOURCE = File.expand_path('compact_marks_writer_w275_helper.cr', __dir__).freeze
  LOCAL_REPO_ROOT = File.realpath(File.expand_path('..', __dir__)).freeze
  W264_SOURCE = File.expand_path('probe_compact_part_writer_w264.rb', __dir__).freeze
  W264_FIXTURE_SOURCE = File.expand_path('../spec/support/compact_part_writer_w264_fixture.cr', __dir__).freeze
  W273_SOURCE = W273::PROBE_SOURCE
  W273_HELPER_SOURCE = W273::HELPER_SOURCE
  W273_NATIVE_FIXTURE_SOURCE = W273::NATIVE_FIXTURE_SOURCE
  W273_LOCAL_FIXTURE_SOURCE = W273::LOCAL_FIXTURE_SOURCE
  PART_NAME = 'all_1_1_0'.freeze
  MARK_FORMATS = %w[mrk3 mrk4].freeze
  MODES = %w[basic compact].freeze
  LAYOUTS = %w[static json].freeze
  COMPRESSED_MARK_SUFFIX = {'mrk3' => 'cmrk3', 'mrk4' => 'cmrk4'}.freeze
  PLAIN_MARK_SUFFIX = {'mrk3' => 'mrk3', 'mrk4' => 'mrk4'}.freeze
  JSON_COLUMN = W273::COLUMN
  JSON_DECLARATION = W273::DECLARATION
  JSON_ROWS = [
    [[11, 12], [13]], nil, nil, nil, [], [[]], nil, [[81], [82, 83], []],
  ].freeze
  ROWS_PER_MARK = 2
  ROW_COUNT = 8
  MARK_ROWS = [2, 2, 2, 2, 0].freeze
  MAX_RAW_FILE_BYTES = 16 * 1024 * 1024
  LOCAL_JSON_WINDOWS = {'full' => [0, 4], 'middle' => [1, 2], 'eof' => [4, 0]}.freeze
  SOURCE_LOCAL_FILES = %w[
    src/crystal_click.cr
    src/crystal_click/compact_mark_format.cr
    src/crystal_click/compact_mark_file_adapter.cr
    src/crystal_click/compact_mark_index.cr
    src/crystal_click/compact_part_writer.cr
    src/crystal_click/compact_part_writer/compact_part_metadata.cr
    src/crystal_click/compact_part_writer/compact_part_operation.cr
    src/crystal_click/compact_physical_mark_output.cr
    src/crystal_click/compact_static_writer.cr
    src/crystal_click/compressed_mark_files.cr
    src/crystal_click/compressed_mark_reader.cr
    src/crystal_click/compressed_mark_writer.cr
    src/crystal_click/part_checksums.cr
    src/crystal_click/part_writer_infrastructure/part_checksums_writer.cr
  ].freeze

  class Failure < StandardError; end

  class Probe
    def initialize(binary:, source_root:, evidence_root:, stock_only:, full_matrix:,
                   helper: nil, helper_sha256: nil)
      raise Failure, 'select exactly one of --stock-only or --full-matrix' unless stock_only != full_matrix
      @stock_only = stock_only
      @full_matrix = full_matrix
      @helper = full_matrix ? validate_executable(helper, 'prebuilt W275 helper') : nil
      @helper_expected_sha = helper_sha256
      if full_matrix && !@helper_expected_sha.to_s.match?(/\A[0-9a-f]{64}\z/)
        raise Failure, '--helper-sha256 must be a lowercase SHA-256 in full-matrix mode'
      end
      if stock_only && (helper || helper_sha256)
        raise Failure, 'stock-only mode does not accept a helper executable or hash'
      end
      @root = validate_root(evidence_root)
      @token = Digest::SHA256.hexdigest(@root)[0, 8]
      @base = W273::Probe.new(
        binary: binary, source_root: source_root, evidence_root: evidence_root,
        depth: 2, stock_only: stock_only, full_matrix: full_matrix,
        helper: @helper, helper_sha256: @helper_expected_sha,
      )
      @runner = @base.instance_variable_get(:@runner)
      @invocations = @base.instance_variable_get(:@invocations)
      @parts = {}
      @stock = {}
      @generated = {}
      @fatal_error = nil
    end

    def run
      prepare!
      stock_matrix!
      if @full_matrix
        generated_matrix!
        compare_pairs!
      end
      @base.send(:validate_pins!)
      summary = build_summary
      @base.send(:write_new, File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      @base.send(:write_new, File.join(@root, 'summary.md'), render_summary(summary))
      puts "W275 status=#{summary.fetch(:status)}; stock=#{@stock.size}; generated=#{@generated.size}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      persist_inconclusive(error)
      warn "W275 probe inconclusive: #{@fatal_error}"
      false
    end

    private

    def validate_root(path)
      raise Failure, 'evidence root is required' unless path && !path.empty?
      expanded = File.expand_path(path)
      raise Failure, 'evidence root must be a direct child of /private/tmp' unless
        File.dirname(expanded) == File.realpath('/private/tmp')
      raise Failure, 'evidence root must already exist, be canonical, non-symlinked, and empty' unless
        File.directory?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded && Dir.children(expanded).empty?
      expanded
    rescue Errno::ENOENT
      raise Failure, 'evidence root and /private/tmp must already exist'
    end

    def validate_executable(path, label)
      raise Failure, "#{label} path is required" unless path && !path.empty?
      expanded = File.expand_path(path)
      raise Failure, "#{label} is absent, non-executable, symlinked, or noncanonical" unless
        File.file?(expanded) && File.executable?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded
      expanded
    end

    def prepare!
      @base.send(:prepare!)
      FileUtils.mkdir_p(File.join(@root, 'parts', 'stock'), mode: 0o700)
      FileUtils.mkdir_p(File.join(@root, 'parts', 'generated'), mode: 0o700)
      local_sources = [PROBE_SOURCE, HELPER_SOURCE, W264_SOURCE, W264_FIXTURE_SOURCE,
                       W273_SOURCE, W273_HELPER_SOURCE, W273_NATIVE_FIXTURE_SOURCE,
                       W273_LOCAL_FIXTURE_SOURCE]
      local_sources.concat(SOURCE_LOCAL_FILES.map { |path| File.join(LOCAL_REPO_ROOT, path) })
      sources = @base.instance_variable_get(:@probe_sources)
      sources.concat(local_sources.map { |path| File.realpath(path) })
      sources.uniq!
      @base.instance_variable_set(:@probe_hashes_before, sources.to_h { |path| [path, sha(path)] })
      @helper_sha_before = sha(@helper) if @full_matrix
      raise Failure, 'prebuilt W275 helper differs from its command-line hash' if
        @full_matrix && @helper_sha_before != @helper_expected_sha
    end

    def sha(path)
      Digest::SHA256.file(path).hexdigest
    end

    def id_for(layout, mark_format, mode = nil, compressed = true)
      [layout, mark_format, mode, compressed ? 'compressed' : 'plain'].compact.join('_')
    end

    def table_name(id)
      "w275_#{@token}_#{id}"
    end

    def store_path(id)
      @base.send(:store_path, "w275_#{id}")
    end

    def native(label, store, sql)
      @base.send(:native, label, store, sql)
    end

    def native_lines(result, label)
      @base.send(:native_lines, result, label)
    end

    def tagged(lines, tag, width, label)
      @base.send(:tagged, lines, tag, width, label)
    end

    def tag(kind, id, suffix = nil)
      suffix_text = suffix ? "_#{suffix.to_s.upcase}" : ''
      "__W275_#{kind.to_s.upcase}_#{id.to_s.upcase}#{suffix_text}__"
    end

    def sql_string(value)
      @base.send(:sql_string, value)
    end

    def compressed_settings(settings, compressed)
      setting = compressed ? "compress_marks=1, marks_compression_codec='LZ4'" : 'compress_marks=0'
      settings.sub('compress_marks=0', setting)
    end

    def static_create_sql(table, mark_format, compressed)
      probe = W264::Probe.allocate
      sql = probe.send(:create_sql, table)
      sql = compressed_settings(sql, compressed)
      substream_marks = mark_format == 'mrk4' ? 1 : 0
      sql.sub('write_marks_for_substreams_in_compact_parts=0',
              "write_marks_for_substreams_in_compact_parts=#{substream_marks}")
    end

    def json_create_sql(mode, table, mark_format, compressed)
      settings = @base.send(:settings, mode, mark_format: mark_format)
      settings = compressed_settings(settings, compressed)
      "SET flatten_nested=0;\nCREATE TABLE default.#{table} (pk UInt64, `#{JSON_COLUMN}` #{JSON_DECLARATION}) " \
        "ENGINE=MergeTree ORDER BY pk SETTINGS #{settings};\n"
    end

    def static_rows_sql(table, id, window)
      predicate = case window
                  when 'full' then ''
                  when 'middle' then ' WHERE pk BETWEEN 103 AND 106'
                  else raise Failure, "unknown static native window #{window}"
                  end
      probe = W264::Probe.allocate
      suffix = window
      marker = probe.send(:tag, :rows, id, suffix)
      expressions = [
        'toString(pk)', 'toString(u)', 'hex(text)',
        "if(isNull(maybe), 'NULL', toString(maybe))", 'hex(toJSONString(gap))',
        'hex(toJSONString(arr))', 'hex(toJSONString(pair))',
        'hex(toJSONString(mapKeys(lookup)))', 'hex(toJSONString(mapValues(lookup)))',
      ]
      "SELECT '#{marker}', #{expressions.join(', ')} FROM default.#{table}#{predicate} " \
        "ORDER BY pk SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;\n"
    end

    def static_eof_sql(table, id)
      probe = W264::Probe.allocate
      "SELECT '#{probe.send(:tag, :empty, id)}', toString(count()) FROM default.#{table} WHERE pk > 108 " \
        "SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;\n"
    end

    def json_window_sql(table, id, window)
      marker = @base.send(:marker, 'window_values', "#{id}_#{window}")
      if window == 'eof'
        return "SELECT '#{marker}', toString(count()) FROM default.#{table} WHERE pk > 8 FORMAT TSVRaw;\n"
      end
      predicate = window == 'full' ? '' : ' WHERE pk BETWEEN 3 AND 6'
      dynamic = "`#{JSON_COLUMN}`.payload"
      actual = "dynamicElement(#{dynamic}, #{sql_string('Array(Array(JSON))')})"
      leaf_types = @base.send(:leaf_types_expression, actual, 2)
      sizes = (0...2).map do |level|
        @base.send(:recursive_sizes_expression, actual, level)
      end
      null_hex = W273::BINARY_JSON_NULL
      fields = [
        "'#{marker}'", 'toString(pk)',
        "if(isNull(#{dynamic}), 'None', dynamicType(#{dynamic}))",
        "if(isNull(#{dynamic}), 'false', if(isDynamicElementInSharedData(#{dynamic}), 'true', 'false'))",
        "if(isNull(#{dynamic}), '#{null_hex}', hex(toJSONString(#{actual})))",
        "if(isNull(#{dynamic}), '#{null_hex}', hex(toJSONString(#{leaf_types})))",
      ] + sizes.map { |expr| "if(isNull(#{dynamic}), '#{null_hex}', hex(toJSONString(#{expr})))" }
      "SELECT #{fields.join(', ')} FROM default.#{table}#{predicate} ORDER BY pk " \
        "SETTINGS output_format_json_quote_64bit_integers=0 FORMAT TSVRaw;\n"
    end

    def common_tail_sql(layout, table, id, mark_format, compressed)
      check_begin = tag(:check_begin, id)
      check_end = tag(:check_end, id)
      schema_tag = tag(:schema, id)
      part_tag = tag(:part, id)
      sql = "SELECT '#{check_begin}' FORMAT TSVRaw;\nCHECK TABLE default.#{table} FORMAT TSV;\n" \
        "SELECT '#{check_end}' FORMAT TSVRaw;\n" \
        "SELECT '#{schema_tag}', name, type FROM system.columns WHERE database='default' AND table='#{table}' " \
        "ORDER BY position FORMAT TSVRaw;\n" \
        "SELECT '#{part_tag}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts " \
        "WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;\n"
      if layout == 'static'
        sql << static_rows_sql(table, id, 'full')
        sql << static_rows_sql(table, id, 'middle')
        sql << static_eof_sql(table, id)
      else
        sql << json_window_sql(table, id, 'full')
        sql << json_window_sql(table, id, 'middle')
        sql << json_window_sql(table, id, 'eof')
      end
      sql
    end

    def prepare_stock_cell!(layout, mark_format, mode = nil)
      id = id_for(layout, mark_format, mode, true)
      table = layout == 'json' ? @base.send(:table_name, id) : table_name(id)
      store = store_path("stock_#{id}")
      create_sql = if layout == 'static'
                     probe = W264::Probe.allocate
                     static_create_sql(table, mark_format, true) + probe.send(:reference_insert_sql, table)
                   else
                     compressed_settings(@base.send(:create_and_insert_sql, mode, id, mark_format: mark_format), true)
                   end
      result = native("w275_stock_#{id}_create_check_read", store,
                      create_sql + common_tail_sql(layout, table, id, mark_format, true))
      source_observation = if layout == 'json'
                             @base.send(:observe_source!, id, result)
                           end
      raise Failure, "stock typed JSON source literals differ for #{id}" if
        source_observation && !source_observation.fetch(:matches_expected_semantics)
      readback = validate_native_output!(layout, id, table, store, result, mark_format, true)
      path = readback.fetch(:part_path)
      physical = @base.send(:tree_inventory, path)
      raw_files = capture_raw_files!(id, path, physical, mark_format, true, evidence_scope: 'stock')
      @stock[id] = {
        origin: 'pinned ClickHouse stock INSERT before any generated part',
        layout: layout, mark_format: mark_format, discriminator_mode: mode,
        compressed_marks: true, table: table, store: store, native_source: path,
        typed_source_observation: source_observation,
        native_readback: readback, source_inventory: physical, raw_files: raw_files,
        create_check_read_invocation: result.fetch(:record),
      }
    end

    def stock_matrix!
      MARK_FORMATS.each do |mark_format|
        prepare_stock_cell!('static', mark_format)
        prepare_stock_cell!('json', mark_format, 'basic')
      end
    end

    def validate_native_output!(layout, id, table, store, result, mark_format, compressed)
      lines = native_lines(result, "#{id} native readback")
      check = check_rows!(lines, id)
      schema = tagged(lines, tag(:schema, id), 3, id).map { |row| row.drop(1) }
      expected_schema = if layout == 'static'
                          W264::SCHEMA
                        else
                          [['pk', 'UInt64'], [JSON_COLUMN, JSON_DECLARATION]]
                        end
      normalized = schema.map { |name, type| [name, @base.send(:normalized_type, type)] }
      expected_schema = expected_schema.map { |name, type| [name, @base.send(:normalized_type, type)] }
      raise Failure, "#{id} native schema differs: #{normalized.inspect}" unless normalized == expected_schema
      parts = tagged(lines, tag(:part, id), 7, id)
      raise Failure, "#{id} must have exactly one active Compact part with 8 rows/5 marks" unless
        parts.size == 1 && parts.first.values_at(1, 2, 4, 5, 6) == [table, PART_NAME, 'Compact', '8', '5']
      path = safe_native_path(parts.first.fetch(3), store, id)
      mark_file = "data.#{compressed ? COMPRESSED_MARK_SUFFIX.fetch(mark_format) : PLAIN_MARK_SUFFIX.fetch(mark_format)}"
      expected_mark_files = [mark_file]
      observed_mark_files = Dir.children(path).grep(/\Adata\.(?:c?mrk[34])\z/).sort
      raise Failure, "#{id} physical mark layout differs: #{observed_mark_files.inspect}" unless observed_mark_files == expected_mark_files
      raise Failure, "#{id} expected mark file missing or symlinked" unless
        File.file?(File.join(path, mark_file)) && !File.symlink?(File.join(path, mark_file))
      windows = if layout == 'static'
                  validate_static_windows!(lines, id)
                else
                  validate_json_windows!(lines, id)
                end
      {
        state: 'CHECK_and_native_literal_windows_exact', check: check,
        schema: normalized, part_row: parts.first, part_path: path,
        marks_file: mark_file, mark_file_size: File.size(File.join(path, mark_file)),
        marks: 'physical filename matches compressed/plain MRK3/MRK4 expectation; rows=8, marks=5',
        windows: windows,
      }
    end

    def check_rows!(lines, id)
      begin_tag = tag(:check_begin, id)
      end_tag = tag(:check_end, id)
      first = lines.index(begin_tag)
      last = lines.index(end_tag)
      body = first && last && last > first ? lines[(first + 1)...last] : nil
      expected = ["#{PART_NAME}\t1\t"]
      raise Failure, "#{id} native CHECK was not exactly CHECK=1: #{body.inspect}" unless body == expected
      {state: 'healthy', rows: body}
    end

    def validate_static_windows!(lines, id)
      probe = W264::Probe.allocate
      full_tag = probe.send(:tag, :rows, id, 'full')
      middle_tag = probe.send(:tag, :rows, id, 'middle')
      eof_tag = probe.send(:tag, :empty, id)
      full = tagged(lines, full_tag, 10, id)
      middle = tagged(lines, middle_tag, 10, id)
      eof = tagged(lines, eof_tag, 2, id)
      full_rows = probe.send(:parse_native_rows, full, "#{id}/full")
      middle_rows = probe.send(:parse_native_rows, middle, "#{id}/middle")
      expected = probe.send(:expected_native_rows)
      raise Failure, "#{id} static full native literals differ" unless full_rows == expected
      raise Failure, "#{id} static middle native literals differ" unless middle_rows == expected[2, 4]
      raise Failure, "#{id} static EOF count differs" unless eof == [[eof_tag, '0']]
      {full: {rows: full_rows.size, literals: 'exact independent W264 keys/values'},
       middle: {rows: middle_rows.size, literals: 'exact independent W264 rows 103..106'}, eof: {rows: 0}}
    end

    def validate_json_windows!(lines, id)
      expected_by_window = {
        'full' => (1..8).to_a,
        'middle' => (3..6).to_a,
      }
      result = {}
      expected_by_window.each do |window, expected_pks|
        marker = @base.send(:marker, 'window_values', "#{id}_#{window}")
        rows = tagged(lines, marker, 8, id)
        expected = expected_pks.map do |pk|
          value = JSON_ROWS.fetch(pk - 1)
          [pk, value.nil? ? 'None' : 'Array(Array(JSON))', false,
           @base.send(:expected_payload_for, value), @base.send(:expected_leaf_types_for, value),
           value.nil? ? [nil, nil] : @base.send(:size_vectors_for, value)]
        end
        actual = rows.map do |fields|
          raise Failure, "#{id}/#{window} native Dynamic shared flag differs" unless %w[true false].include?(fields[3])
          payload = fields[4] == W273::BINARY_JSON_NULL ? nil : @base.send(:decode_hex_json, fields[4], "#{id}/#{window}/payload")
          types = fields[5] == W273::BINARY_JSON_NULL ? nil : @base.send(:decode_hex_json, fields[5], "#{id}/#{window}/types")
          sizes = fields.drop(6).map do |hex|
            hex == W273::BINARY_JSON_NULL ? nil : @base.send(:flatten_numbers, @base.send(:decode_hex_json, hex, "#{id}/#{window}/sizes"))
          end
          [Integer(fields[1], 10), @base.send(:normalized_type, fields[2]), fields[3] == 'true', payload, types, sizes]
        end
        raise Failure, "#{id}/#{window} native JSON/Dynamic literals, inferred types, or shapes differ" unless actual == expected
        result[window] = {rows: actual.size, pks: expected_pks, literals: 'exact independent W273 depth-2 rows; inferred Int64 leaf paths'}
      end
      eof_marker = @base.send(:marker, 'window_values', "#{id}_eof")
      eof = tagged(lines, eof_marker, 2, id)
      raise Failure, "#{id} JSON/Dynamic EOF count differs" unless eof == [[eof_marker, '0']]
      result['eof'] = {rows: 0}
      result
    end

    def safe_native_path(raw, store, id)
      raise Failure, "#{id} native part path is not absolute" unless raw.is_a?(String) && raw.start_with?(File::SEPARATOR)
      path = File.expand_path(raw)
      root = File.realpath(store)
      raise Failure, "#{id} native part escaped isolated store" unless path.start_with?(root + File::SEPARATOR)
      raise Failure, "#{id} native part path is noncanonical or symlinked" unless
        File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path
      path
    end

    def capture_raw_files!(id, path, inventory, mark_format, compressed, evidence_scope:)
      raise Failure, "#{id} has an unknown raw evidence scope: #{evidence_scope.inspect}" unless
        %w[stock candidate].include?(evidence_scope)
      evidence_id = "w275_#{evidence_scope}_#{id}"
      marks_name = "data.#{compressed ? COMPRESSED_MARK_SUFFIX.fetch(mark_format) : PLAIN_MARK_SUFFIX.fetch(mark_format)}"
      names = %w[data.bin serialization.json checksums.txt] + [marks_name]
      names << 'columns_substreams.txt' if mark_format == 'mrk4'
      files = names.to_h do |name|
        source = File.join(path, name)
        raise Failure, "#{id} raw evidence file missing or symlinked: #{name}" unless File.file?(source) && !File.symlink?(source)
        stat = File.stat(source)
        raise Failure, "#{id}/#{name} exceeds raw evidence bound" if stat.size > MAX_RAW_FILE_BYTES
        bytes = File.binread(source)
        raise Failure, "#{id}/#{name} changed size while being captured" unless bytes.bytesize == stat.size
        target = File.join(@root, 'raw-records', "#{evidence_id}.#{name}")
        @base.send(:write_new, target, bytes)
        [name, {path: target, size: bytes.bytesize, sha256: Digest::SHA256.hexdigest(bytes)}]
      end
      record = {evidence_id: evidence_id, semantic_case_id: id, part_path: path, inventory: inventory, raw_files: files}
      @base.send(:write_new, File.join(@root, 'source-inventories', "#{evidence_id}.json"), JSON.pretty_generate(record) + "\n")
      files
    end

    def helper(label, *arguments)
      result = @runner.send(:run_process, label, [@helper] + arguments, ''.b, 'crystal-helper',
                            expected_sha: @helper_sha_before, binary_path: @helper)
      record = result.fetch(:record)
      unless !record[:timed_out] && record[:spawn_error].nil? && record[:stdin_write_error].nil? &&
             record[:stdout_read_error].nil? && record[:stderr_read_error].nil? && result[:status] &&
             result[:status].termsig.nil? && result[:status].success? && result[:stderr].empty?
        raise Failure, "#{label} helper did not complete successfully: #{record.inspect}"
      end
      raise Failure, "#{label} helper response exceeded report bound" if result[:stdout].bytesize > W273::MAX_REPORT_BYTES
      output = result[:stdout].dup.force_encoding(Encoding::UTF_8)
      raise Failure, "#{label} helper response is not UTF-8" unless output.valid_encoding?
      report = JSON.parse(output)
      unless report.is_a?(Hash) && report['format'] == HELPER_FORMAT && report['action'] == arguments.first
        raise Failure, "#{label} helper envelope differs"
      end
      report
    rescue JSON::ParserError => error
      raise Failure, "#{label} helper output is invalid JSON: #{error.message}"
    end

    def validate_helper_report!(report, action, id)
      expected_status = action == 'read-json' ? 'accepted' : 'ok'
      raise Failure, "#{id} helper #{action} status differs" unless report['status'] == expected_status
    end

    def write_generated!(layout, mark_format, mode = nil, compressed = false)
      id = id_for(layout, mark_format, mode, compressed)
      destination = File.join(@root, 'parts', 'generated', id, PART_NAME)
      Dir.mkdir(File.dirname(destination), 0o700)
      action = layout == 'static' ? 'write-static' : 'write-json'
      args = if layout == 'static'
               [action, destination, mark_format, compressed ? '1' : '0']
             else
               [action, destination, '2', mark_format, mode, compressed ? '1' : '0']
             end
      written = helper("w275_#{id}_write", *args)
      validate_helper_report!(written, action, id)
      unless written['part_path'] == destination && written['layout'] == mark_format &&
             written['compressed_marks'] == compressed
        raise Failure, "#{id} helper writer metadata differs"
      end
      if layout == 'json'
        unless written['depth'] == 2 && written['discriminator_mode'] == mode &&
               written['expected_mark_rows'] == [2, 2, 2, 2, 0] && written['literals'] == JSON_ROWS
          raise Failure, "#{id} JSON helper fixture description differs from independent literals"
        end
      end
      inventory = @base.send(:tree_inventory, destination)
      marks = helper("w275_#{id}_marks", 'marks', destination)
      validate_helper_report!(marks, 'marks', id)
      expected_suffix = compressed ? COMPRESSED_MARK_SUFFIX.fetch(mark_format) : PLAIN_MARK_SUFFIX.fetch(mark_format)
      unless marks['marks_file'] == "data.#{expected_suffix}" && marks['layout'] == mark_format &&
             marks['compressed'] == compressed && marks['mark_rows_with_terminal'] == MARK_ROWS
        raise Failure, "#{id} helper physical/canonical marks metadata differs"
      end
      local = {}
      if layout == 'json'
        LOCAL_JSON_WINDOWS.each do |window, (first, count)|
          read = helper("w275_#{id}_local_#{window}", 'read-json', destination, '2', first.to_s, count.to_s)
          validate_helper_report!(read, 'read-json', id)
          expected_literals = JSON_ROWS.slice(first * ROWS_PER_MARK, count * ROWS_PER_MARK)
          unless read['first_mark'] == first && read['mark_count'] == count &&
                 read['literals'] == expected_literals && read['recursive_literals_by_mark'] == read['static_literals_by_mark']
            raise Failure, "#{id} local #{window} recursive/static literal readback differs"
          end
          local[window] = {first_mark: first, mark_count: count, literals: expected_literals, reader_agreement: true}
        end
      end
      raw_files = capture_raw_files!(id, destination, inventory, mark_format, compressed, evidence_scope: 'candidate')
      {
        id: id, layout: layout, mark_format: mark_format, discriminator_mode: mode,
        compressed_marks: compressed, writer_report: written, local_mark_report: marks,
        local_json_windows: local, source_part: destination, source_inventory: inventory,
        raw_files: raw_files,
      }
    end

    def generated_target!(cell)
      id = cell.fetch(:id)
      layout = cell.fetch(:layout)
      mark_format = cell.fetch(:mark_format)
      mode = cell.fetch(:discriminator_mode)
      compressed = cell.fetch(:compressed_marks)
      table = table_name("target_#{id}")
      store = store_path("target_#{id}")
      path_tag = tag(:data_path, id)
      create = if layout == 'static'
                 sql = static_create_sql(table, mark_format, compressed)
               else
                 sql = json_create_sql(mode, table, mark_format, compressed)
               end
      create << "SELECT '#{path_tag}', arrayElement(data_paths, 1) FROM system.tables " \
        "WHERE database='default' AND name='#{table}' FORMAT TSVRaw;\n"
      created = native("w275_#{id}_target_create", store, create)
      paths = tagged(native_lines(created, "#{id} target path"), path_tag, 2, id)
      raise Failure, "#{id} target data path is not unique" unless paths.size == 1 && !paths.first[1].empty?
      data_path = safe_native_path(paths.first[1], store, id + '_target')
      source = cell.fetch(:source_part)
      source_inventory = cell.fetch(:source_inventory)
      raise Failure, "#{id} generated source changed before detached copy" unless @base.send(:tree_inventory, source) == source_inventory
      @runner.send(:attach_part!, source, data_path)
      detached = File.join(data_path, 'detached', PART_NAME)
      detached_inventory = @base.send(:tree_inventory, detached)
      raise Failure, "#{id} detached immutable copy differs from generated source" unless detached_inventory == source_inventory
      attach_sql = "ALTER TABLE default.#{table} ATTACH PART '#{PART_NAME}';\n" +
        common_tail_sql(layout, table, id, mark_format, compressed)
      attached = native("w275_#{id}_attach_check_read", store, attach_sql)
      readback = validate_native_output!(layout, id, table, store, attached, mark_format, compressed)
      active_inventory = @base.send(:tree_inventory, readback.fetch(:part_path))
      active_files = active_inventory.fetch(:files).to_h { |entry| [entry.fetch(:path), entry] }
      source_files = source_inventory.fetch(:files).to_h { |entry| [entry.fetch(:path), entry] }
      unless source_files.all? { |name, entry| active_files[name] == entry } &&
             (active_files.keys - source_files.keys).all? { |name| name == 'invalidated_system_columns.txt' }
        raise Failure, "#{id} attached active part differs from immutable generated source"
      end
      raise Failure, "#{id} immutable generated source changed after native consumers" unless
        @base.send(:tree_inventory, source) == source_inventory
      cell.merge(
        target: {table: table, store: store, data_path: data_path, create_invocation: created.fetch(:record)},
        immutable_lineage: {
          source_path: source, source_inventory: source_inventory,
          detached_inventory: detached_inventory,
          active_path: readback.fetch(:part_path), active_inventory: active_inventory,
          source_unchanged_after_native: true,
        },
        attach_check_read_invocation: attached.fetch(:record), native_readback: readback,
      )
    end

    def generated_matrix!
      # All independent stock SQL controls above complete before the first
      # generated helper invocation.
      MARK_FORMATS.each do |mark_format|
        [false, true].each do |compressed|
          cell = write_generated!('static', mark_format, nil, compressed)
          @generated[cell.fetch(:id)] = generated_target!(cell)
        end
        MODES.each do |mode|
          [false, true].each do |compressed|
            cell = write_generated!('json', mark_format, mode, compressed)
            @generated[cell.fetch(:id)] = generated_target!(cell)
          end
        end
      end
      raise Failure, "generated matrix cardinality differs: #{@generated.size}" unless @generated.size == 12
    end

    def compare_pairs!
      pairs = {}
      @generated.each_value do |cell|
        key = [cell.fetch(:layout), cell.fetch(:mark_format), cell.fetch(:discriminator_mode)].compact.join('_')
        pairs[key] ||= {}
        pairs[key][cell.fetch(:compressed_marks) ? 'compressed' : 'plain'] = cell
      end
      raise Failure, 'expected six plain/compressed candidate pairs' unless pairs.size == 6
      @pair_comparisons = pairs.to_h do |key, pair|
        plain = pair.fetch('plain')
        compressed = pair.fetch('compressed')
        plain_bin = plain.fetch(:raw_files).fetch('data.bin')
        compressed_bin = compressed.fetch(:raw_files).fetch('data.bin')
        plain_marks = plain.fetch(:local_mark_report)
        compressed_marks = compressed.fetch(:local_mark_report)
        same_bin = plain_bin.fetch(:sha256) == compressed_bin.fetch(:sha256) &&
          plain_bin.fetch(:size) == compressed_bin.fetch(:size)
        same_marks = plain_marks.fetch('canonical_marks_hex') == compressed_marks.fetch('canonical_marks_hex') &&
          plain_marks.fetch('canonical_size') == compressed_marks.fetch('canonical_size')
        raise Failure, "#{key} data.bin differs between plain/compressed marks" unless same_bin
        raise Failure, "#{key} decoded canonical MRK bytes differ between plain/compressed marks" unless same_marks
        [key, {
          data_bin_byte_identical: true, data_bin_size: plain_bin.fetch(:size),
          data_bin_sha256: plain_bin.fetch(:sha256), canonical_marks_byte_identical_after_decode: true,
          canonical_mark_bytes: plain_marks.fetch('canonical_size'),
          canonical_mark_sha256: plain_marks.fetch('canonical_sha256'),
        }]
      end
    end

    def build_summary
      {
        format: FORMAT,
        status: @full_matrix ? 'stock_controls_and_12_generated_cells_exact' : 'stock_compressed_mark_controls_exact',
        execution_mode: @full_matrix ? 'stock_first_then_prebuilt_helper_generated_matrix' : 'stock_only_no_helper_invoked',
        runtime_pin: {
          binary: @base.instance_variable_get(:@binary), sha256: @base.instance_variable_get(:@binary_sha_after),
          version: W273::VERSION, build: W273::BUILD,
        },
        upstream_source_pin: {
          root: @base.instance_variable_get(:@source_root), revision: W273::SOURCE_REVISION,
          sha256_by_file: @base.instance_variable_get(:@upstream_hashes),
        },
        probe_and_local_source_pins: @base.instance_variable_get(:@probe_hashes_after),
        helper_binary_pin: @full_matrix ? {
          path: @helper, sha256_before: @helper_sha_before, sha256_after: @base.instance_variable_get(:@helper_sha_after),
        } : {invoked: false, reason: 'stock-only native semantics do not depend on the candidate helper'},
        matrix: {
          stock_native_compressed_controls: @stock,
          generated_candidate_cells: @generated,
          plain_vs_compressed_candidate_pairs: @pair_comparisons,
        },
        invocations: @invocations,
        evidence_root: @root,
        claim_boundary: 'Finite evidence only: stock native LZ4 mark compression and independent W264 static / W273 depth-2 inferred-Int64 JSON-in-Dynamic literals for MRK3/MRK4; when full mode is used, twelve generated cells cover W264 bounded static plus W273 BASIC/COMPACT depth-2 JSON/Dynamic, MRK3/MRK4, plain/LZ4-compressed marks. Exact data.bin bytes and decoded canonical mark bytes are paired only within those six candidate profiles. This does not claim support for all types, profiles, depths, codecs, or writer settings.',
      }
    end

    def render_summary(summary)
      [
        '# W275 Compact compressed-marks native probe', '',
        "Status: `#{summary.fetch(:status)}`",
        "Execution: `#{summary.fetch(:execution_mode)}`",
        "Runtime: #{W273::VERSION} / #{W273::BUILD} / SHA256 `#{summary.dig(:runtime_pin, :sha256)}`.",
        "Source: `#{W273::SOURCE_REVISION}` at `#{W273::SOURCE_ROOT}` (separately pinned).",
        "Stock native compressed controls: `#{@stock.size}`; generated cells: `#{@generated.size}`.",
        @full_matrix ? "Plain/compressed equality pairs: `#{@pair_comparisons.size}` (data.bin bytes and decoded canonical mark bytes)." : nil,
        '', summary.fetch(:claim_boundary), '',
      ].compact.join("\n")
    end

    def persist_inconclusive(error)
      return unless File.directory?(File.join(@root, 'invocations'))
      report = {
        format: FORMAT, status: 'inconclusive', fatal_error: @fatal_error,
        error_class: error.class.name, stock_cells_completed: @stock.keys,
        generated_cells_completed: @generated.keys,
        runtime_pin: {path: @base.instance_variable_get(:@binary), expected_sha256: W273::BINARY_SHA256,
                      observed_sha256: (sha(@base.instance_variable_get(:@binary)) rescue nil)},
        upstream_source_pin: {root: @base.instance_variable_get(:@source_root), revision: W273::SOURCE_REVISION},
        invocations: @invocations, evidence_root: @root,
        claim_boundary: 'A process failure, native rejection, output mismatch, or incomplete matrix is inconclusive and does not establish writer compatibility.',
      }
      @base.send(:write_new, File.join(@root, 'summary.json'), JSON.pretty_generate(report) + "\n") unless File.exist?(File.join(@root, 'summary.json'))
    rescue StandardError
      nil
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = {
    binary: ProbeCompactMarksWriterW275::W273::BINARY,
    source_root: ProbeCompactMarksWriterW275::W273::SOURCE_ROOT,
    evidence_root: nil, stock_only: false, full_matrix: false,
    helper: nil, helper_sha256: nil,
  }
  parser = OptionParser.new do |opts|
    opts.banner = 'Usage: ruby scripts/probe_compact_marks_writer_w275.rb (--stock-only | --full-matrix --helper PREBUILT --helper-sha256 SHA256) --evidence-root EMPTY_DIR [--binary PINNED_CLICKHOUSE] [--source-root PINNED_UPSTREAM]'
    opts.on('--stock-only', 'Capture compressed native MRK3/MRK4 static and JSON/Dynamic controls; never invoke the candidate helper') { options[:stock_only] = true }
    opts.on('--full-matrix', 'Capture the stock controls, then 12 generated writer cells and six plain/compressed equality pairs') { options[:full_matrix] = true }
    opts.on('--helper PATH', 'Prebuilt W275 Crystal helper executable; required only for --full-matrix') { |value| options[:helper] = value }
    opts.on('--helper-sha256 SHA256', 'Exact lowercase SHA-256 of the prebuilt helper') { |value| options[:helper_sha256] = value }
    opts.on('--evidence-root EMPTY_DIR', 'Existing empty direct child of /private/tmp') { |value| options[:evidence_root] = value }
    opts.on('--binary PATH', 'Pinned clickhouse-local executable') { |value| options[:binary] = value }
    opts.on('--source-root PATH', 'Separately pinned upstream ClickHouse source checkout') { |value| options[:source_root] = value }
  end
  begin
    parser.parse!
    unless options[:stock_only] != options[:full_matrix] && options[:evidence_root]
      raise OptionParser::ParseError, 'select exactly one mode and provide --evidence-root'
    end
    if options[:stock_only] && (options[:helper] || options[:helper_sha256])
      raise OptionParser::ParseError, 'stock-only mode does not accept --helper or --helper-sha256'
    end
    if options[:full_matrix] && (!options[:helper] || !options[:helper_sha256])
      raise OptionParser::ParseError, 'full-matrix mode requires --helper and --helper-sha256'
    end
    success = ProbeCompactMarksWriterW275::Probe.new(**options).run
    exit(success ? 0 : 1)
  rescue OptionParser::ParseError => error
    warn error.message
    warn parser
    exit 2
  rescue StandardError => error
    warn "W275 probe setup failed: #{error.class}: #{error.message}"
    exit 1
  end
end
