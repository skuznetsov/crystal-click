#!/usr/bin/env ruby
# Stock-first W268 Compact Dynamic oracle. This file intentionally implements
# native stock is always captured first. Generated-writer cells, when enabled,
# follow that independent stock oracle. This script never compiles a helper;
# the optional prebuilt reader/writer helper is a separate bounded process.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require_relative 'probe_object_shared_json_interop_w241'

module ProbeCompactPartWriterW268
  W241 = ProbeObjectSharedJSONInteropW241
  FORMAT = 'compact_part_writer_w268_native_probe_v1'.freeze
  HELPER_FORMAT = 'compact_part_writer_w268_helper_v1'.freeze
  PART_NAME = 'all_1_1_0'.freeze
  HELPER_SOURCE = File.expand_path('compact_part_writer_w268_helper.cr', __dir__).freeze
  W241_SOURCE = File.expand_path('probe_object_shared_json_interop_w241.rb', __dir__).freeze
  BINARY = '/private/tmp/crystal-click-w263-runtime-recovery.B9uAPX/clickhouse-stripped'.freeze
  BINARY_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  SOURCE_ROOT = '/private/tmp/clickhouse-w254-upstream.AqeqyC'.freeze
  SOURCE_REVISION = 'ed30948f095ecb70679986d7d60e27ad770ae27a'.freeze
  MAX_PART_FILES = 128
  MAX_PART_BYTES = 64 * 1024 * 1024
  ROWS_PER_MARK = 2
  MARK_ROWS_WITH_EOF = [2, 2, 2, 2, 2, 2, 0].freeze
  SCHEMA = [
    ['pk', 'UInt64'],
    ['root', 'Dynamic(max_types=1)'],
    ['ctx', 'Tuple(label String, items Array(Dynamic(max_types=1)))'],
  ].map(&:freeze).freeze
  WINDOWS = {
    'full' => [0, 6], 'middle' => [2, 2], 'last' => [5, 1], 'empty' => [6, 0],
  }.transform_values(&:freeze).freeze
  WINDOW_PREDICATES = {
    'full' => '1', 'middle' => 'pk BETWEEN 5 AND 8',
    'last' => 'pk BETWEEN 11 AND 12', 'empty' => 'pk > 12',
  }.freeze
  EXPECTED_ROSTER = [
    ['pk', 'pk'],
    ['root', 'root.dynamic_structure'],
    ['root', 'root.variant_discr_prefix'],
    ['root', 'root.variant_discr'],
    ['root', 'root.SharedVariant'],
    ['root', 'root.UInt8'],
    ['ctx', 'ctx%2Eitems.dynamic_structure'],
    ['ctx', 'ctx%2Eitems.variant_discr_prefix'],
    ['ctx', 'ctx%2Elabel'],
    ['ctx', 'ctx%2Eitems.size0'],
    ['ctx', 'ctx%2Eitems.variant_discr'],
    ['ctx', 'ctx%2Eitems.SharedVariant'],
    ['ctx', 'ctx%2Eitems.UInt16'],
  ].map(&:freeze).freeze

  # Literal native inputs. The SQL encoder below explicitly casts every
  # Dynamic value, including NULL; these rows are not loaded from a Crystal
  # fixture or helper response.
  ROWS = [
    {pk: 1, root: [:uint8, 11], label: 'r01', items: [[:uint16, 101]]},
    {pk: 2, root: [:uint8, 12], label: 'r02', items: [[:uint16, 102]]},
    {pk: 3, root: [:string, 'r3'], label: 'r03', items: [[:uint16, 103], [:string, 'n4']]},
    {pk: 4, root: [:uint64, 9001], label: 'r04', items: [[:uint64, 19001]]},
    {pk: 5, root: [:uint8, 13], label: 'r05', items: [[:string, 'n5']]},
    {pk: 6, root: [:string, 'r6'], label: 'r06', items: [[:uint16, 104], [:uint16, 105]]},
    {pk: 7, root: [:null, nil], label: 'r07', items: []},
    {pk: 8, root: [:null, nil], label: 'r08', items: []},
    {pk: 9, root: [:string, 'r9'], label: 'r09', items: [[:uint64, 19002]]},
    {pk: 10, root: [:uint64, 9002], label: 'r10', items: [[:string, 'n10'], [:uint16, 106]]},
    {pk: 11, root: [:uint8, 14], label: 'r11', items: [[:uint16, 107], [:string, 'tail']]},
    {pk: 12, root: [:uint8, 15], label: 'r12', items: [[:null, nil]]},
  ].map(&:freeze).freeze
  ROWS_FOR_WINDOW = WINDOWS.to_h do |name, (first_mark, mark_count)|
    [name, ROWS.slice(first_mark * ROWS_PER_MARK, mark_count * ROWS_PER_MARK) || []]
  end.freeze

  class Failure < StandardError; end

  class Probe
    def initialize(binary:, helper:, evidence_root:, generated_matrix:)
      @binary = validate_executable(binary, 'pinned ClickHouse')
      @helper = helper && validate_executable(helper, 'prebuilt W268 reader helper')
      @generated_matrix = generated_matrix
      fail!('--generated-matrix requires a prebuilt W268 helper') if @generated_matrix && !@helper
      @root = validate_root(evidence_root)
      @invocations = []
      @token = Digest::SHA256.hexdigest(@root)[0, 8]
      @source_files = [__FILE__, W241_SOURCE].map { |path| File.realpath(path) }
      @source_files << File.realpath(HELPER_SOURCE) if @helper
      @runner = W241::Probe.allocate
      @runner.instance_variable_set(:@binary, @binary)
      @runner.instance_variable_set(:@root, @root)
      @runner.instance_variable_set(:@invocations, @invocations)
    end

    def run
      prepare!
      stock = %w[basic compact].to_h { |mode| [mode, capture_stock!(mode)] }
      generated = @generated_matrix ? capture_generated_matrix!(stock) : nil
      poison_source = if generated
                        generated.fetch('mrk4_compact').fetch(:part_path)
                      elsif @helper
                        stock.fetch('compact').fetch(:part_path)
                      end
      poison = poison_source ? qualify_poison!(poison_source) :
        {state: 'deferred_no_prebuilt_reader_helper'}
      verify_pins!
      status = if generated
                 'stock_oracle_generated_matrix_and_copy_only_mutant_captured'
               elsif @helper
                 'stock_native_reader_and_copy_only_mutant_captured'
               else
                 'stock_native_only_captured'
               end
      summary = {
        format: FORMAT, status: status, stock_native_mrk4: stock,
        generated_matrix: generated, poisoned_nested_middle_prefix: poison, invocations: @invocations,
        runtime: {path: @binary, sha256: BINARY_SHA256, version: W241::VERSION, build: W241::BUILD,
                  sha256_before: @binary_sha_before, sha256_after: binary_sha},
        source_revision: {path: SOURCE_ROOT, revision: SOURCE_REVISION},
        source_hashes: @source_hashes_before, evidence_root: @root,
        claim_boundary: 'Native stock INSERTs are the literal oracle for this profile. The stock roster is parsed from columns_substreams.txt before the Crystal helper is consulted. CHECK and SQL empty selection are separate observations, not semantic or EOF-traversal proofs. The Crystal public reader freezes the whole mark grid; no granule-only I/O claim is made.',
      }
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      write_new(File.join(@root, 'summary.md'), render_summary(summary))
      generated_status = generated ? 'four_cells_captured' : 'not_requested'
      puts "W268 status=#{status}; rows=12; marks=6+EOF; generated=#{generated_status}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      persist_inconclusive(error)
      warn "W268 Compact Dynamic probe inconclusive: #{@fatal_error}"
      false
    end

    private

    def fail!(message)
      raise Failure, "W268: #{message}"
    end

    def validate_root(path)
      fail!('evidence root must already exist and be an empty direct child of /private/tmp') unless path && File.directory?(File.expand_path(path)) && !File.symlink?(File.expand_path(path))
      expanded = File.expand_path(path)
      fail!('evidence root must be a direct child of /private/tmp') unless File.dirname(expanded) == File.realpath('/private/tmp')
      fail!('evidence root must be canonical and empty') unless File.realpath(expanded) == expanded && Dir.children(expanded).empty?
      expanded
    rescue Errno::ENOENT
      fail!('evidence root must already exist')
    end

    def validate_executable(path, label)
      fail!("#{label} is absent, non-executable, or symlinked") unless path && File.file?(File.expand_path(path)) && File.executable?(File.expand_path(path)) && !File.symlink?(File.expand_path(path))
      File.realpath(path)
    end

    def prepare!
      %w[invocations stores parts source-inventories raw-records].each do |name|
        Dir.mkdir(File.join(@root, name), 0o700)
      end
      @binary_sha_before = binary_sha
      fail!('ClickHouse executable differs from the W268 native pin') unless @binary_sha_before == BINARY_SHA256
      @helper_sha_before = helper_sha if @helper
      @source_hashes_before = @source_files.to_h { |path| [path, sha(path)] }
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

    def pin_sql
      @runner.send(:pin_sql)
    end

    def native(label, sql, store)
      result = @runner.send(:native, label, store, [pin_sql, sql].join("\n"))
      record = result.fetch(:record)
      fail!("#{label} timed out or had process infrastructure failure: #{record.inspect}") unless
        !record[:timed_out] && record[:spawn_error].nil? && record[:stdin_write_error].nil? &&
        record[:stdout_read_error].nil? && record[:stderr_read_error].nil? && result[:status] && result[:status].termsig.nil?
      fail!("#{label} was not a bounded native success/refusal: #{record.inspect}") unless
        %w[success server_exception].include?(result[:classification])
      if result[:classification] == 'success'
        @runner.send(:assert_native_success!, result, label)
        @runner.send(:assert_pin!, result[:stdout], label)
      else
        fail!("#{label} native executable identity changed") unless record[:binary_sha_after] == BINARY_SHA256
      end
      result
    end

    def native_lines(result, label)
      output = result[:stdout].dup.force_encoding(Encoding::UTF_8)
      fail!("#{label} output is not UTF-8/newline-terminated") unless output.valid_encoding? && output.end_with?("\n")
      output.lines.map(&:chomp)
    end

    def settings(variant_mode, mark_format: 'mrk4')
      mode_value = variant_mode == 'compact' ? 1 : 0
      substream_marks = mark_format == 'mrk4' ? 1 : 0
      [
        'index_granularity=2', 'index_granularity_bytes=10485760', 'enable_mixed_granularity_parts=1',
        'min_rows_for_wide_part=1000000', 'min_bytes_for_wide_part=104857600', 'min_level_for_wide_part=0',
        'compress_marks=0', 'compress_primary_key=0', 'write_final_mark=1',
        "write_marks_for_substreams_in_compact_parts=#{substream_marks}",
        'min_compress_block_size=0', 'max_compress_block_size=4096',
        'ratio_of_defaults_for_sparse_serialization=1.0', "default_compression_codec='LZ4'",
        "serialization_info_version='with_types'", 'propagate_types_serialization_versions_to_nested_types=true',
        "string_serialization_version='single_stream'", "nullable_serialization_version='basic'",
        "dynamic_serialization_version='v3'", "use_compact_variant_discriminators_serialization=#{mode_value}",
        'allow_suspicious_low_cardinality_types=1',
      ].join(', ')
    end

    def declarations
      SCHEMA.map { |name, type| "`#{name}` #{type}" }.join(', ')
    end

    def table_name(case_name)
      "w268_#{@token}_#{case_name}"
    end

    def store_path(case_name)
      path = File.join(@root, 'stores', case_name)
      Dir.mkdir(path, 0o700) unless Dir.exist?(path)
      path
    end

    def tag(kind, case_name, window = nil)
      suffix = case_name.upcase
      suffix += "_#{window.upcase}" if window
      "__W268_#{kind.to_s.upcase}_#{suffix}__"
    end

    def sql_dynamic(value)
      kind, item = value
      expression = case kind
                   when :uint8 then "toUInt8(#{item})"
                   when :uint16 then "toUInt16(#{item})"
                   when :uint64 then "toUInt64(#{item})"
                   when :string then "CAST('#{item.gsub("'", "\\\\'")}', 'String')"
                   when :null then 'NULL'
                   else fail!("unknown Dynamic literal kind #{kind.inspect}")
                   end
      "CAST(#{expression}, 'Dynamic(max_types=1)')"
    end

    def sql_context(row)
      items = row.fetch(:items).map { |item| sql_dynamic(item) }.join(', ')
      array = "CAST([#{items}], 'Array(Dynamic(max_types=1))')"
      tuple = "tuple(CAST('#{row.fetch(:label)}', 'String'), #{array})"
      "CAST(#{tuple}, 'Tuple(label String, items Array(Dynamic(max_types=1)))')"
    end

    def insert_sql(table)
      values = ROWS.map do |row|
        "(toUInt64(#{row.fetch(:pk)}), #{sql_dynamic(row.fetch(:root))}, #{sql_context(row)})"
      end
      "INSERT INTO default.#{table} VALUES\n#{values.join(",\n")};\n"
    end

    def stock_sql(mode, table)
      "SET flatten_nested=0;\nSET allow_suspicious_low_cardinality_types=1;\n" \
        "CREATE TABLE default.#{table} (#{declarations}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings(mode)};\n" \
        + insert_sql(table)
    end

    def dynamic_signature_sql(expression)
      "if(isNull(#{expression}), 'D:NULL', multiIf(" \
        "dynamicType(#{expression})='UInt8', concat('D:UInt8:U8:', toString(dynamicElement(#{expression}, 'UInt8'))), " \
        "dynamicType(#{expression})='UInt16', concat('D:UInt16:U16:', toString(dynamicElement(#{expression}, 'UInt16'))), " \
        "dynamicType(#{expression})='UInt64', concat('D:UInt64:U64:', toString(dynamicElement(#{expression}, 'UInt64'))), " \
        "dynamicType(#{expression})='String', concat('D:String:S:', lower(hex(dynamicElement(#{expression}, 'String')))), " \
        "concat('D:UNEXPECTED:', dynamicType(#{expression}))))"
    end

    def context_signature_sql
      items = "tupleElement(ctx, 'items')"
      mapped = "arrayMap(x -> #{dynamic_signature_sql('x')}, #{items})"
      "concat('T:(S:', lower(hex(tupleElement(ctx, 'label'))), ',A:[', " \
        "arrayStringConcat(#{mapped}, ','), '])')"
    end

    def native_window_sql(case_name, window, table, columns: %w[pk root ctx])
      marker = tag('native', case_name, window)
      predicate = WINDOW_PREDICATES.fetch(window)
      return "SELECT '#{marker}', toString(count()) FROM default.#{table} WHERE #{predicate} FORMAT TSVRaw;\n" if window == 'empty'

      fields = ["'#{marker}'", 'toString(pk)']
      fields << dynamic_signature_sql('root') if columns.include?('root')
      fields << context_signature_sql if columns.include?('ctx')
      "SELECT #{fields.join(', ')} FROM default.#{table} WHERE #{predicate} ORDER BY pk FORMAT TSVRaw;\n"
    end

    def check_sql(case_name, table)
      begin_tag = tag('check_begin', case_name)
      end_tag = tag('check_end', case_name)
      "SELECT '#{begin_tag}' FORMAT TSVRaw;\nCHECK TABLE default.#{table} FORMAT TSV;\nSELECT '#{end_tag}' FORMAT TSVRaw;\n"
    end

    def part_sql(case_name, table)
      schema_tag = tag('schema', case_name)
      part_tag = tag('part', case_name)
      "SELECT '#{schema_tag}', name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;\n" \
        "SELECT '#{part_tag}', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts " \
        "WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;\n"
    end

    def tagged(lines, marker, width)
      lines.select { |line| line.start_with?(marker + "\t") }.map do |line|
        fields = line.split("\t", -1)
        fail!("malformed tagged output for #{marker}") unless fields.size == width
        fields
      end
    end

    def normalize_type(type)
      type.gsub(/\s+/, '')
    end

    def safe_native_path(path, store)
      real = File.realpath(path)
      root = File.realpath(store)
      fail!("native part path escaped isolated store: #{path}") unless real.start_with?(root + File::SEPARATOR)
      fail!('native part path is not a canonical directory') unless File.directory?(real) && !File.symlink?(path)
      real
    end

    def native_part!(case_name, table, store, mark_format: 'mrk4')
      result = native("#{case_name}_schema_and_part", part_sql(case_name, table), store)
      fail!("#{case_name} native schema/part query refused") unless result[:classification] == 'success'
      lines = native_lines(result, "#{case_name} schema/part")
      schemas = tagged(lines, tag('schema', case_name), 3).map { |fields| fields.drop(1) }
      normalized = schemas.map { |name, type| [name, normalize_type(type)] }
      expected = SCHEMA.map { |name, type| [name, normalize_type(type)] }
      fail!("#{case_name} native schema differs: #{schemas.inspect}") unless normalized == expected
      parts = tagged(lines, tag('part', case_name), 7)
      fail!("#{case_name} is not exactly one 12-row/six-real-mark Compact part") unless
        parts.size == 1 && parts.first.values_at(1, 2, 4, 5, 6) == [table, PART_NAME, 'Compact', '12', '7']
      path = safe_native_path(parts.first[3], store)
      wanted_mark = mark_format == 'mrk4' ? 'data.mrk4' : 'data.mrk3'
      other_mark = mark_format == 'mrk4' ? 'data.mrk3' : 'data.mrk4'
      fail!("#{case_name} active Compact part has the wrong mark format") unless
        File.file?(File.join(path, wanted_mark)) && !File.exist?(File.join(path, other_mark))
      path
    end

    def check_observation!(case_name, table, store)
      result = native("#{case_name}_check", check_sql(case_name, table), store)
      fail!("#{case_name} CHECK refused") unless result[:classification] == 'success'
      lines = native_lines(result, "#{case_name} CHECK")
      first = lines.index(tag('check_begin', case_name))
      last = lines.index(tag('check_end', case_name))
      rows = first && last && last > first ? lines[(first + 1)...last] : nil
      {state: 'success', rows: rows, exact_success: rows == ["#{PART_NAME}\t1\t"], invocation: result[:record]}
    end

    def validate_unsealed_checksum_observation!(case_name, check)
      rows = check.fetch(:rows)
      fail!("#{case_name} CHECK did not return exactly one failed part row") unless
        check.fetch(:state) == 'success' && rows.is_a?(Array) && rows.size == 1
      fields = rows.first.split("\t", -1)
      fail!("#{case_name} CHECK failure row does not identify the expected part") unless
        fields.size == 3 && fields.fetch(0) == PART_NAME && fields.fetch(1) == '0'
      diagnostic = fields.fetch(2)
      fail!("#{case_name} CHECK failure is not the explicit data.bin checksum mismatch") unless
        diagnostic.match?(/\ACode:\s*40\b/) && diagnostic.include?('Checksum mismatch for file data.bin') &&
        diagnostic.include?('(CHECKSUM_DOESNT_MATCH)')

      {state: 'data_bin_checksum_mismatch', part_name: fields.fetch(0), success_flag: fields.fetch(1),
       error_code: 40, file: 'data.bin', diagnostic: diagnostic, row: rows.first,
       invocation: check.fetch(:invocation)}
    end

    def dynamic_expected(value)
      kind, item = value
      case kind
      when :uint8 then "D:UInt8:U8:#{item}"
      when :uint16 then "D:UInt16:U16:#{item}"
      when :uint64 then "D:UInt64:U64:#{item}"
      when :string then "D:String:S:#{item.unpack1('H*')}"
      when :null then 'D:NULL'
      else fail!("unknown expected Dynamic kind #{kind.inspect}")
      end
    end

    def expected_row(row, columns: %w[pk root ctx])
      values = [row.fetch(:pk).to_s]
      values << dynamic_expected(row.fetch(:root)) if columns.include?('root')
      if columns.include?('ctx')
        items = row.fetch(:items).map { |item| dynamic_expected(item) }.join(',')
        values << "T:(S:#{row.fetch(:label).unpack1('H*')},A:[#{items}])"
      end
      values
    end

    def native_select!(case_name, table, store, window, columns: %w[pk root ctx], strict: true)
      result = native("#{case_name}_select_#{columns.join('_')}_#{window}",
                      native_window_sql(case_name, window, table, columns: columns), store)
      if result[:classification] != 'success'
        fail!("#{case_name} #{columns.join('+')} #{window} SELECT refused") if strict
        return {state: result[:classification], invocation: result[:record]}
      end
      lines = native_lines(result, "#{case_name} #{window} SELECT")
      if window == 'empty'
        rows = tagged(lines, tag('native', case_name, window), 2)
        exact = rows == [[tag('native', case_name, window), '0']]
      else
        width = 2 + columns.count('root') + columns.count('ctx')
        rows = tagged(lines, tag('native', case_name, window), width).map { |fields| fields.drop(1) }
        expected = ROWS_FOR_WINDOW.fetch(window).map { |row| expected_row(row, columns: columns) }
        exact = rows == expected
      end
      fail!("#{case_name} native #{window} SELECT differs from independent literal Dynamic values") if strict && !exact
      {state: exact ? 'exact_values' : 'value_mismatch', rows: window == 'empty' ? 0 : rows,
       invocation: result[:record]}
    end

    def native_selects!(case_name, table, store)
      WINDOWS.keys.to_h do |window|
        [window, native_select!(case_name, table, store, window)]
      end
    end

    def tree_inventory(path)
      entries = []
      total = 0
      Find.find(path) do |entry|
        next if entry == path
        stat = File.lstat(entry)
        fail!("symlink in native part: #{entry}") if stat.symlink?
        next if stat.directory?
        fail!("non-regular native part entry: #{entry}") unless stat.file?
        total += stat.size
        fail!('native part file-count bound exceeded') if entries.size >= MAX_PART_FILES
        fail!('native part byte bound exceeded') if total > MAX_PART_BYTES
        entries << {path: entry.delete_prefix(path + File::SEPARATOR), size: stat.size,
                    sha256: Digest::SHA256.file(entry).hexdigest}
      end
      {files: entries.sort_by { |item| item.fetch(:path) }, total_bytes: total}
    end

    def validate_attached_native_inventory!(case_name, active_part, active_inventory, source_inventory)
      source_files = source_inventory.fetch(:files).to_h { |entry| [entry.fetch(:path), entry] }
      active_files = active_inventory.fetch(:files).to_h { |entry| [entry.fetch(:path), entry] }
      missing = source_files.keys - active_files.keys
      extra = active_files.keys - source_files.keys
      fail!("#{case_name} native ATTACH removed source files: #{missing.sort.inspect}") unless missing.empty?
      fail!("#{case_name} native ATTACH added unexpected files: #{extra.sort.inspect}") unless
        extra == ['invalidated_system_columns.txt']

      changed = source_files.keys.sort.select { |name| source_files[name] != active_files[name] }
      fail!("#{case_name} native ATTACH changed generated source files: #{changed.inspect}") unless changed.empty?

      sidecar_path = File.join(active_part, 'invalidated_system_columns.txt')
      sidecar_bytes = File.binread(sidecar_path)
      sidecar_content = sidecar_bytes.dup.force_encoding(Encoding::UTF_8)
      fail!("#{case_name} native ATTACH sidecar is not valid UTF-8") unless sidecar_content.valid_encoding?
      sidecar_lines = sidecar_content.split("\n", -1)
      terminal_newline = sidecar_lines.pop == ''
      fail!("#{case_name} native ATTACH sidecar contents differ") unless
        terminal_newline && sidecar_lines.sort == %w[_block_number _block_offset] && sidecar_lines.size == 2
      fail!("#{case_name} native ATTACH total byte count differs") unless
        active_inventory.fetch(:total_bytes) == source_inventory.fetch(:total_bytes) + sidecar_bytes.bytesize

      {path: 'invalidated_system_columns.txt', content: sidecar_content,
       size: sidecar_bytes.bytesize, sha256: Digest::SHA256.hexdigest(sidecar_bytes)}
    end

    def parse_columns_substreams!(text, label)
      lines = text.split("\n", -1)
      fail!("#{label} columns_substreams lacks terminal newline") unless lines.pop == ''
      fail!("#{label} columns_substreams version differs") unless lines.shift == 'columns substreams version: 1'
      header = lines.shift
      fail!("#{label} columns_substreams column count differs") unless header == '3 columns:'
      sections = []
      until lines.empty?
        match = /\A(0|[1-9][0-9]*) substreams for column `([a-z][a-z0-9_]*)`:\z/.match(lines.shift)
        fail!("#{label} malformed columns_substreams section") unless match
        count = Integer(match[1], 10)
        fail!("#{label} substream count exceeds fixed witness bound") unless count <= 16 && lines.length >= count
        names = count.times.map do
          stream = /\A\t([A-Za-z0-9_.%]+)\z/.match(lines.shift)
          fail!("#{label} malformed physical callback name") unless stream
          stream[1]
        end
        sections << [match[2], names]
        fail!("#{label} extra columns_substreams section") if sections.size > 3
      end
      roster = sections.flat_map { |column, streams| streams.map { |stream| [column, stream] } }
      fail!("#{label} stock callback order differs from pinned source/callback traversal: #{roster.inspect}") unless
        sections.map(&:first) == %w[pk root ctx] && roster == EXPECTED_ROSTER
      roster
    end

    def capture_source_inventory!(case_name, part)
      inventory = tree_inventory(part)
      columns_path = File.join(part, 'columns_substreams.txt')
      fail!("#{case_name} stock columns_substreams.txt is absent or symlinked") unless File.file?(columns_path) && !File.symlink?(columns_path)
      columns_text = File.binread(columns_path)
      roster = parse_columns_substreams!(columns_text, case_name)
      record = {case_name: case_name, source_part_path: part, inventory: inventory,
                parsed_stock_roster: roster, columns_substreams_sha256: Digest::SHA256.hexdigest(columns_text)}
      write_new(File.join(@root, 'source-inventories', "#{case_name}.columns_substreams.txt"), columns_text)
      write_new(File.join(@root, 'source-inventories', "#{case_name}.json"), JSON.pretty_generate(record) + "\n")
      %w[data.bin data.mrk4].each do |name|
        source = File.join(part, name)
        fail!("#{case_name} raw file #{name} is absent or symlinked") unless File.file?(source) && !File.symlink?(source)
        write_new(File.join(@root, 'raw-records', "#{case_name}.#{name}"), File.binread(source))
      end
      record
    end

    def copy_stock_part!(case_name, source)
      destination = File.join(@root, 'parts', case_name)
      fail!("#{case_name} stock evidence destination already exists") if File.exist?(destination) || File.symlink?(destination)
      FileUtils.cp_r(source, destination, preserve: true)
      source_inventory = tree_inventory(source)
      copied_inventory = tree_inventory(destination)
      fail!("#{case_name} copied stock evidence differs from native source") unless copied_inventory == source_inventory
      destination
    end

    def helper(label, *arguments, expected_statuses: ['ok'])
      fail!('no prebuilt reader helper was supplied') unless @helper
      result = @runner.send(:run_process, label, [@helper] + arguments, ''.b, 'crystal-helper',
                            expected_sha: @helper_sha_before, binary_path: @helper)
      record = result.fetch(:record)
      fail!("#{label} helper process failed or exceeded bounds: #{record.inspect}") unless
        !record[:timed_out] && record[:spawn_error].nil? && record[:stdin_write_error].nil? &&
        record[:stdout_read_error].nil? && record[:stderr_read_error].nil? && result[:status] &&
        result[:status].termsig.nil? && result[:classification] == 'success' && result[:status].success? && result[:stderr].empty?
      report = JSON.parse(result[:stdout].dup.force_encoding(Encoding::UTF_8))
      fail!("#{label} helper envelope differs") unless report.is_a?(Hash) && report['format'] == HELPER_FORMAT &&
        report['action'] == arguments.first && expected_statuses.include?(report['status'])
      report
    rescue JSON::ParserError => error
      raise Failure, "W268: #{label} helper stdout is not JSON: #{error.message}"
    end

    def validate_helper_report!(report, mode, label, inventory, source_roster)
      validate_generated_report!(report, 'mrk4', mode, label, inventory, source_roster)
    end

    def validate_generated_report!(report, mark_format, mode, label, inventory, source_roster)
      fail!("#{label} helper status differs") unless report.fetch('status') == 'ok'
      fail!("#{label} dimensions differ") unless report.fetch('mark_format') == mark_format &&
        report.fetch('row_count') == 12 && report.fetch('granule_count') == 6 && report.fetch('mark_rows') == [2] * 6
      physical = report.fetch('physical_roster').map { |item| [item.fetch('column'), item.fetch('stream')] }
      expected_physical = mark_format == 'mrk4' ? source_roster : [['pk', ''], ['root', ''], ['ctx', '']]
      fail!("#{label} Crystal physical roster differs from format/source contract") unless physical == expected_physical
      tape = report.fetch('physical_mark_tape')
      data_entry = inventory.fetch(:files).find { |entry| entry.fetch(:path) == 'data.bin' }
      slot_count = mark_format == 'mrk4' ? 13 : 3
      mark_file = "data.#{mark_format}"
      mark_entry = inventory.fetch(:files).find { |entry| entry.fetch(:path) == mark_file }
      other_mark = mark_format == 'mrk4' ? 'data.mrk3' : 'data.mrk4'
      fail!("#{label} part inventory lacks its selected mark file or contains the other format") unless
        mark_entry && inventory.fetch(:files).none? { |entry| entry.fetch(:path) == other_mark }
      expected_width = slot_count * 16 + 8
      fail!("#{label} #{mark_format.upcase} record dimensions differ") unless tape.fetch('file') == mark_file &&
        tape.fetch('slot_count') == slot_count && tape.fetch('record_width') == expected_width &&
        tape.fetch('byte_size') == expected_width * 7 && tape.fetch('records').size == 7 &&
        tape.fetch('records').map { |record| record.fetch('row_count') } == MARK_ROWS_WITH_EOF &&
        tape.fetch('byte_size') == mark_entry.fetch(:size) && tape.fetch('compressed_size') == data_entry.fetch(:size) &&
        tape.fetch('raw_size').positive?
      tape.fetch('records').each_with_index do |record, mark|
        fail!("#{label} mark #{mark} slot count differs") unless record.fetch('mark') == mark && record.fetch('pairs').size == slot_count
        record.fetch('pairs').each_with_index do |pair, slot|
          fail!("#{label} mark #{mark} pair ordinal differs") unless pair.fetch('slot') == slot
          fail!("#{label} mark #{mark} coordinate escaped data.bin") unless
            pair.fetch('compressed_offset') >= 0 && pair.fetch('compressed_offset') <= tape.fetch('compressed_size') &&
            pair.fetch('decompressed_offset') >= 0 &&
            pair.fetch('logical_position') >= 0 && pair.fetch('logical_position') <= tape.fetch('raw_size')
        end
      end
      slot_count.times do |slot|
        positions = tape.fetch('records').map { |record| record.fetch('pairs').fetch(slot).fetch('logical_position') }
        fail!("#{label} slot #{slot} logical mark positions move backwards") if positions.each_cons(2).any? { |left, right| left > right }
      end
      eof = tape.fetch('records').last.fetch('pairs')
      fail!("#{label} #{mark_format.upcase} terminal record is not all-slot EOF") unless eof.all? do |pair|
        pair.fetch('compressed_offset') == tape.fetch('compressed_size') &&
          pair.fetch('decompressed_offset').zero? && pair.fetch('logical_position') == tape.fetch('raw_size')
      end
      raw_hex = report.fetch('raw_data_hex')
      fail!("#{label} helper raw-data census differs") unless raw_hex.match?(/\A(?:[0-9a-f]{2})*\z/) && raw_hex.bytesize == tape.fetch('raw_size') * 2
      validate_helper_shards!(report, label, mark_format, expected_physical, raw_hex)
      validate_dynamic_structures!(report, label)
      expected_mode = mode == 'compact' ? 1 : 0
      prefixes = report.fetch('variant_prefixes')
      expected_variant_sites = ['root.variant_discr_prefix', 'ctx%2Eitems.variant_discr_prefix']
      variant_sites_complete = expected_variant_sites.all? do |stream|
        prefixes.select { |item| item.fetch('stream') == stream }.map { |item| item.fetch('mark') } == (0...6).to_a
      end
      fail!("#{label} root/nested Variant prefix census differs") unless prefixes.size == 12 &&
        prefixes.all? { |item| item.fetch('mode') == expected_mode && expected_variant_sites.include?(item.fetch('stream')) } &&
        variant_sites_complete
      validate_local_windows!(report, label)
      {status: 'ok', mode: mode, mark_format: mark_format, physical_roster: physical, mark_tape: tape,
       dynamic_structures: report.fetch('dynamic_structures'), variant_prefixes: prefixes,
       windows: report.fetch('windows'), checksum_claim: report.fetch('checksum_claim')}
    end

    def validate_helper_shards!(report, label, mark_format, expected_roster, raw_hex)
      shards = report.fetch('callback_shards')
      slots = mark_format == 'mrk4' ? 13 : 3
      raw_bytes = [raw_hex].pack('H*')
      fail!("#{label} callback shard census differs") unless shards.size == 6 * slots
      fail!("#{label} callback marks differ") unless shards.map { |shard| shard.fetch('mark') }.uniq.sort == (0...6).to_a
      ordered_callbacks = []
      shards.group_by { |shard| shard.fetch('mark') }.each do |mark, per_mark|
        ordered = per_mark.sort_by { |shard| shard.fetch('slot') }
        roster = ordered.map { |shard| [shard.fetch('column'), shard.fetch('stream')] }
        fail!("#{label} mark #{mark} callback order differs") unless ordered.size == slots && roster == expected_roster
        fail!("#{label} mark #{mark} callback slot ordinals differ") unless ordered.map { |shard| shard.fetch('slot') } == (0...slots).to_a
        ordered_callbacks[mark] = ordered
        ordered.each do |shard|
          bytes = shard.fetch('bytes_hex')
          fail!("#{label} mark #{mark} callback bytes are malformed") unless bytes.match?(/\A(?:[0-9a-f]{2})*\z/) && bytes.bytesize == shard.fetch('byte_count') * 2
          fail!("#{label} mark #{mark} callback logical bounds differ") unless
            shard.fetch('logical_start') >= 0 && shard.fetch('logical_end') >= shard.fetch('logical_start') &&
            shard.fetch('logical_end') <= raw_bytes.bytesize &&
            shard.fetch('logical_end') - shard.fetch('logical_start') == shard.fetch('byte_count')
          raw_slice = raw_bytes.byteslice(shard.fetch('logical_start'), shard.fetch('byte_count'))
          fail!("#{label} mark #{mark} callback bytes differ from decoded data.bin") unless
            raw_slice == [bytes].pack('H*')
        end
      end
      flat = ordered_callbacks.flatten
      fail!("#{label} callbacks do not cover decoded data.bin from start to EOF") unless
        flat.first.fetch('logical_start').zero? && flat.last.fetch('logical_end') == raw_bytes.bytesize &&
        flat.each_cons(2).all? { |left, right| left.fetch('logical_end') == right.fetch('logical_start') }
    end

    def validate_dynamic_structures!(report, label)
      structures = report.fetch('dynamic_structures')
      expected_streams = ['root.dynamic_structure', 'ctx%2Eitems.dynamic_structure']
      sites_complete = expected_streams.all? do |stream|
        structures.select { |item| item.fetch('stream') == stream }.map { |item| item.fetch('mark') } == (0...6).to_a
      end
      fail!("#{label} Dynamic structure census differs") unless structures.size == 12 && sites_complete
      structures.each do |item|
        stream = item.fetch('stream')
        mark = item.fetch('mark')
        root = stream == 'root.dynamic_structure'
        fail!("#{label} unknown Dynamic structure site") unless root || expected_streams.include?(stream)
        type = root ? 'UInt8' : 'UInt16'
        fail!("#{label} Dynamic wire version/ordinary roster differs") unless
          item.fetch('version') == 4 && item.fetch('ordinary_types') == [type]
        expected_flag = mark.zero? ? 1 : 0
        fail!("#{label} Dynamic V3 statistics flag differs") unless item.fetch('statistics_flag') == expected_flag
        if mark.zero?
          expected_counts = root ? [5, 5] : [6, 7]
          expected_shared = root ? [['String', 3], ['UInt64', 2]] : [['String', 4], ['UInt64', 2]]
          stats = item.fetch('statistics')
          actual_shared = stats.fetch('shared').map { |entry| [entry.fetch('name_hex'), entry.fetch('count')] }
          expected_shared_hex = expected_shared.map { |name, count| [name.unpack1('H*'), count] }.sort
          fail!("#{label} first Dynamic statistics differ from literal occurrence census") unless
            stats.fetch('counts') == expected_counts && actual_shared.sort == expected_shared_hex
        else
          fail!("#{label} later Dynamic prefix is not statistics-empty") unless item.fetch('statistics').nil?
        end
      end
      true
    end

    def expected_signatures(column, window)
      ROWS_FOR_WINDOW.fetch(window).map do |row|
        case column
        when 'pk' then row.fetch(:pk).to_s
        when 'root' then dynamic_expected(row.fetch(:root))
        when 'ctx' then expected_row(row, columns: %w[ctx]).fetch(1)
        else fail!("unknown W268 local column #{column}")
        end
      end
    end

    def validate_local_windows!(report, label)
      windows = report.fetch('windows')
      WINDOWS.each_key do |name|
        actual = windows.fetch(name)
        fail!("#{label} #{name} local column set differs") unless actual.keys.sort == %w[ctx pk root]
        %w[pk root ctx].each do |column|
          fail!("#{label} #{name} local #{column} reader differs from native literals") unless
            actual.fetch(column) == expected_signatures(column, name)
        end
      end
      true
    end

    def capture_generated_matrix!(stock)
      %w[mrk3 mrk4].product(%w[basic compact]).to_h do |mark_format, mode|
        key = "#{mark_format}_#{mode}"
        [key, capture_generated_cell!(mark_format, mode, stock.fetch(mode))]
      end
    end

    def capture_generated_source_inventory!(case_name, part, mark_format, write_report, audit_report)
      inventory = tree_inventory(part)
      required = ['data.bin', "data.#{mark_format}"]
      present = inventory.fetch(:files).map { |entry| entry.fetch(:path) }
      fail!("#{case_name} generated part is missing required data/mark files") unless required.all? { |name| present.include?(name) }
      record = {case_name: case_name, source_part_path: part, mark_format: mark_format,
                variant_mode: write_report.fetch('variant_discriminator_mode'), inventory: inventory,
                writer_report: write_report, audit_report: audit_report}
      write_new(File.join(@root, 'source-inventories', "#{case_name}.json"), JSON.pretty_generate(record) + "\n")
      %w[data.bin].push("data.#{mark_format}").each do |name|
        source = File.join(part, name)
        fail!("#{case_name} raw file #{name} is absent or symlinked") unless File.file?(source) && !File.symlink?(source)
        write_new(File.join(@root, 'raw-records', "#{case_name}.#{name}"), File.binread(source))
      end
      record
    end

    def capture_generated_cell!(mark_format, mode, stock)
      case_name = "generated_#{mark_format}_#{mode}"
      part = File.join(@root, 'parts', case_name)
      write_report = helper("#{case_name}_write", 'write-generated', part, mark_format, mode)
      fail!("#{case_name} writer declaration differs") unless
        write_report.fetch('part_path') == part && write_report.fetch('row_count') == 12 &&
        write_report.fetch('mark_format') == mark_format &&
        write_report.fetch('variant_discriminator_mode') == (mode == 'compact' ? 1 : 0) &&
        write_report.fetch('dynamic_context_sites') == ['root', 'root.field.1.elements']
      inventory = tree_inventory(part)
      audit_report = helper("#{case_name}_audit", 'audit', part)
      source_roster = stock.fetch(:source_inventory).fetch(:parsed_stock_roster)
      local = validate_generated_report!(audit_report, mark_format, mode, case_name, inventory, source_roster)
      checksum = helper("#{case_name}_checksum_data", 'verify-checksum', part, 'data.bin', expected_statuses: ['accepted'])
      fail!("#{case_name} full data.bin checksum hash differs") unless checksum.fetch('file_hash_matches')
      source_inventory = capture_generated_source_inventory!(case_name, part, mark_format, write_report, audit_report)

      target = create_native_target!(case_name, mode, mark_format: mark_format)
      attach = attach_copy!(case_name, part, target)
      fail!("#{case_name} native ATTACH refused") unless attach.fetch(:state) == 'success'
      active_part = native_part!(case_name, target.fetch(:table), target.fetch(:store), mark_format: mark_format)
      active_inventory = tree_inventory(active_part)
      native_owned_sidecar = validate_attached_native_inventory!(case_name, active_part, active_inventory,
                                                                 source_inventory.fetch(:inventory))
      check = check_observation!(case_name, target.fetch(:table), target.fetch(:store))
      fail!("#{case_name} native CHECK did not report one healthy part") unless check.fetch(:exact_success)
      selects = native_selects!(case_name, target.fetch(:table), target.fetch(:store))
      fail!("#{case_name} native SELECTs differ from independent literal oracle") unless
        selects.values.all? { |value| value.fetch(:state) == 'exact_values' }
      fail!("#{case_name} generated source part changed during native cross-read") unless
        tree_inventory(part) == source_inventory.fetch(:inventory)

      {mark_format: mark_format, mode: mode, part_path: part, source_inventory: source_inventory,
       crystal_reader_audit: local, data_bin_checksum: checksum, native_target: target,
       native_attach: attach,
       active_native_part: {path: active_part, inventory: active_inventory,
                            native_owned_sidecar: native_owned_sidecar},
       native_check: check, native_literal_selects: selects}
    end

    def create_native_target!(case_name, variant_mode, mark_format: 'mrk4')
      store = store_path(case_name)
      table = table_name(case_name)
      sql = "CREATE TABLE default.#{table} (#{declarations}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings(variant_mode, mark_format: mark_format)};\n" \
        "SELECT '#{tag('path', case_name)}', arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw;\n"
      result = native("#{case_name}_create_target", sql, store)
      fail!("#{case_name} native target CREATE refused") unless result[:classification] == 'success'
      rows = tagged(native_lines(result, "#{case_name} CREATE"), tag('path', case_name), 2)
      fail!("#{case_name} target data path is not unique") unless rows.size == 1 && !rows.first[1].empty?
      path = safe_native_path(rows.first[1], store)
      {table: table, store: store, data_path: path, create_invocation: result[:record]}
    end

    def attach_copy!(case_name, source, target)
      source_inventory = tree_inventory(source)
      @runner.send(:attach_part!, source, target.fetch(:data_path))
      detached = File.join(target.fetch(:data_path), 'detached', PART_NAME)
      copied = tree_inventory(detached)
      fail!("#{case_name} detached copy differs from source mutant") unless copied == source_inventory
      result = native("#{case_name}_attach", "ALTER TABLE default.#{target.fetch(:table)} ATTACH PART '#{PART_NAME}';\n", target.fetch(:store))
      {state: result[:classification], invocation: result[:record], source_inventory: source_inventory,
       detached_inventory: copied}
    end

    def mutant_select!(case_name, target, window, columns, expect_exact: false)
      result = native_select!(case_name, target.fetch(:table), target.fetch(:store), window,
                              columns: columns, strict: false)
      if expect_exact && result.fetch(:state) != 'exact_values'
        fail!("#{case_name} required positive control was not literal exact: #{result.inspect}")
      end
      result
    end

    def validate_mutation_inventory!(source_inventory, mutant_inventory, mutation, resealed:, label:)
      source_map = source_inventory.fetch(:files).to_h { |entry| [entry.fetch(:path), entry] }
      mutant_map = mutant_inventory.fetch(:files).to_h { |entry| [entry.fetch(:path), entry] }
      changed = (source_map.keys | mutant_map.keys).sort.select { |name| source_map[name] != mutant_map[name] }
      expected_changed = resealed ? %w[checksums.txt data.bin] : ['data.bin']
      fail!("#{label} copy mutation changed unexpected files: #{changed.inspect}") unless changed == expected_changed
      fail!("#{label} mutation changed data.bin size or MRK4") unless
        source_map.fetch('data.bin').fetch(:size) == mutant_map.fetch('data.bin').fetch(:size) &&
        source_map.fetch('data.mrk4') == mutant_map.fetch('data.mrk4')
      fail!("#{label} helper did not report one byte 4-to-3 mutation") unless
        mutation.fetch('stream') == 'ctx%2Eitems.dynamic_structure' && mutation.fetch('mark') == 2 &&
        mutation.fetch('version_before') == 4 && mutation.fetch('version_after') == 3 &&
        mutation.fetch('raw_changed_offsets').size == 1 &&
        mutation.fetch('compressed_size_before') == mutation.fetch('compressed_size_after') &&
        mutation.fetch('frame_count').positive? && mutation.fetch('checksums_resealed') == resealed
      {changed_files: changed, source_inventory: source_inventory, mutant_inventory: mutant_inventory,
       version: [mutation.fetch('version_before'), mutation.fetch('version_after')],
       raw_changed_offsets: mutation.fetch('raw_changed_offsets')}
    end

    def qualify_poison!(source)
      source_before = tree_inventory(source)
      mutants = {}
      %w[resealed unsealed].each do |mode|
        name = "poison_#{mode}"
        path = File.join(@root, 'parts', name)
        mutation = helper("#{name}_copy", 'copy-mutant', mode, source, path, 'ctx', '2')
        inventory = tree_inventory(path)
        mutants[mode] = {path: path, mutation: mutation,
                         audit: validate_mutation_inventory!(source_before, inventory, mutation,
                                                             resealed: mode == 'resealed', label: name)}
        fail!('copy-only Dynamic poison modified its original source part') unless tree_inventory(source) == source_before
      end

      unsealed_checksum = helper('poison_unsealed_checksum', 'verify-checksum', mutants.fetch('unsealed').fetch(:path), 'data.bin',
                                 expected_statuses: ['rejected'])
      fail!('unresealed same-size data.bin drift matched the part file hash') if unsealed_checksum.fetch('file_hash_matches')
      unsealed_case = 'poison_unsealed_compact'
      unsealed_target = create_native_target!(unsealed_case, 'compact')
      unsealed_attach = attach_copy!(unsealed_case, mutants.fetch('unsealed').fetch(:path), unsealed_target)
      fail!('native ATTACH did not admit the unsealed checksum-control copy') unless
        unsealed_attach.fetch(:state) == 'success'
      unsealed_check = check_observation!(unsealed_case, unsealed_target.fetch(:table), unsealed_target.fetch(:store))
      native_unsealed_checksum_observation = validate_unsealed_checksum_observation!(unsealed_case, unsealed_check)

      resealed = mutants.fetch('resealed').fetch(:path)
      local = {
        ctx_middle: helper('poison_local_ctx_middle', 'read', resealed, 'ctx', '2', '2', expected_statuses: ['rejected']),
        root_middle: helper('poison_local_root_middle_control', 'read', resealed, 'root', '2', '2', expected_statuses: ['accepted']),
        pk_middle: helper('poison_local_pk_middle_control', 'read', resealed, 'pk', '2', '2', expected_statuses: ['accepted']),
      }
      fail!('Crystal selected nested middle read did not reject poisoned Dynamic structure') unless
        local.fetch(:ctx_middle).fetch('status') == 'rejected'
      fail!('Crystal root Dynamic reader control did not preserve literal middle values') unless
        local.fetch(:root_middle).fetch('signatures') == expected_signatures('root', 'middle')
      fail!('Crystal UInt64 key control did not preserve literal middle values') unless
        local.fetch(:pk_middle).fetch('signatures') == expected_signatures('pk', 'middle')

      case_name = 'poison_resealed_compact'
      target = create_native_target!(case_name, 'compact')
      attach = attach_copy!(case_name, resealed, target)
      fail!('resealed malformed Dynamic prefix copy was not accepted by native ATTACH') unless attach.fetch(:state) == 'success'
      check = check_observation!(case_name, target.fetch(:table), target.fetch(:store))
      fail!('resealed malformed Dynamic prefix unexpectedly failed native structural CHECK') unless check.fetch(:exact_success)
      native_observations = {}
      native_observations[:ctx_middle] = mutant_select!(case_name, target, 'middle', %w[pk ctx])
      native_observations[:root_middle] = mutant_select!(case_name, target, 'middle', %w[pk root], expect_exact: true)
      native_observations[:pk_middle] = mutant_select!(case_name, target, 'middle', %w[pk], expect_exact: true)
      native_observations[:ctx_last] = mutant_select!(case_name, target, 'last', %w[pk ctx], expect_exact: true)
      native_observations[:ctx_empty] = mutant_select!(case_name, target, 'empty', %w[pk ctx], expect_exact: true)
      fail!('native key-only middle control did not preserve literal rows') unless
        native_observations.fetch(:pk_middle).fetch(:state) == 'exact_values'
      fail!('native root-only middle control did not preserve literal rows') unless
        native_observations.fetch(:root_middle).fetch(:state) == 'exact_values'
      fail!('native clean last-window control did not preserve literal values') unless
        native_observations.fetch(:ctx_last).fetch(:state) == 'exact_values'
      fail!('native empty-window control did not preserve the zero-row result') unless
        native_observations.fetch(:ctx_empty).fetch(:state) == 'exact_values'
      fail!('resealed nested middle SELECT was not semantically refused') unless
        native_observations.fetch(:ctx_middle).fetch(:state) == 'server_exception'
      fail!('copy-only mutation modified its generated source part') unless tree_inventory(source) == source_before

      {mutation: mutants, unsealed_file_hash_observation: unsealed_checksum,
       native_unsealed_checksum_observation: {target: unsealed_target, attach: unsealed_attach,
                                              check: native_unsealed_checksum_observation},
       local_selected_reads: local, native_target: target, native_attach: attach,
       native_check_nonsemantic_observation: check, native_selected_reads: native_observations,
       locality_boundary: 'Crystal reader freezes and validates the whole mark grid; local outside-window success is not claimed. Native key/root middle controls and nested last/empty controls are independently literal-exact; empty is a zero-row SQL selection, not terminal-mark traversal.'}
    end

    def capture_stock!(mode)
      case_name = "stock_#{mode}"
      store = store_path(case_name)
      table = table_name(case_name)
      insert = native("#{case_name}_create_insert", stock_sql(mode, table), store)
      fail!("#{case_name} native stock CREATE/INSERT refused") unless insert[:classification] == 'success'
      source_part = native_part!(case_name, table, store)
      source_inventory = capture_source_inventory!(case_name, source_part)
      part = copy_stock_part!(case_name, source_part)
      check = check_observation!(case_name, table, store)
      fail!("#{case_name} native CHECK did not report one healthy part") unless check.fetch(:exact_success)
      selects = native_selects!(case_name, table, store)
      fail!("#{case_name} SELECTs differ from literal stock oracle") unless selects.values.all? { |value| value.fetch(:state) == 'exact_values' }
      local = nil
      if @helper
        report = helper("#{case_name}_physical_audit", 'audit', part)
        local = validate_helper_report!(report, mode, case_name, source_inventory.fetch(:inventory), source_inventory.fetch(:parsed_stock_roster))
        checksum = helper("#{case_name}_checksum_data", 'verify-checksum', part, 'data.bin', expected_statuses: ['accepted'])
        fail!("#{case_name} data.bin full-file checksum hash differs") unless checksum.fetch('file_hash_matches')
        local[:data_bin_checksum] = checksum
      end
      fail!("#{case_name} source part changed during stock capture") unless tree_inventory(source_part) == source_inventory.fetch(:inventory)
      {mode: mode, table: table, store: store, part_path: part, native_source_path: source_part,
       insert: insert.fetch(:record), source_inventory: source_inventory, check: check,
       native_literal_selects: selects, crystal_reader_audit: local}
    end

    def verify_pins!
      fail!('ClickHouse executable SHA changed during capture') unless binary_sha == BINARY_SHA256
      fail!('prebuilt Crystal helper SHA changed during capture') if @helper && helper_sha != @helper_sha_before
      @source_hashes_before.each do |path, expected|
        fail!("probe source changed during capture: #{path}") unless sha(path) == expected
      end
      true
    end

    def render_summary(summary)
      <<~MD
        # W268 stock-first Compact Dynamic probe

        - Status: `#{summary.fetch(:status)}`.
        - Native pin: ClickHouse #{W241::VERSION} / `#{W241::BUILD}` / SHA-256 `#{BINARY_SHA256}`.
        - Source comparison pin: `#{SOURCE_REVISION}` at `#{SOURCE_ROOT}`; distinct from the native binary revision.
        - Witness: 12 literal rows, six two-row marks plus EOF; BASIC and COMPACT Variant discriminator modes; explicit Dynamic v3 casts.
        - Stock callback roster is parsed from each native part's `columns_substreams.txt` and compared with the independently transcribed source traversal order before helper output is inspected.
        - Native CHECK is recorded separately from native literal full/middle/last/empty SELECTs. Empty is a zero-row SQL selection, not a proof of EOF traversal.
        - Crystal's reader freezes the whole mark grid. No granule-only IO claim is made.
        - Generated writer matrix: #{summary[:generated_matrix] ? 'MRK3/MRK4 × BASIC/COMPACT' : 'not requested'}.
        - Evidence: `#{@root}`.
      MD
    end

    def persist_inconclusive(error)
      path = File.join(@root, 'summary.json')
      return if File.exist?(path)
      summary = {format: FORMAT, status: 'inconclusive', fatal_error: "#{error.class}: #{error.message}",
                 evidence_root: @root, invocations: @invocations}
      write_new(path, JSON.pretty_generate(summary) + "\n")
    rescue StandardError => summary_error
      warn "W268 inconclusive summary persistence failed: #{summary_error.class}: #{summary_error.message}"
    end
  end

  def self.main
    options = {binary: BINARY}
    selected_mode = nil
    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby scripts/probe_compact_part_writer_w268.rb (--stock-only | --generated-matrix) --evidence-root EMPTY_DIRECT_CHILD_OF_PRIVATE_TMP [--crystal-helper PREBUILT_HELPER] [--clickhouse PINNED_CLICKHOUSE]'
      parser.on('--stock-only', 'Capture independent native stock truth; helper is optional') do
        abort 'W268: select exactly one run mode' if selected_mode
        selected_mode = :stock_only
      end
      parser.on('--generated-matrix', 'Capture stock first, then all four generated mark/mode cells; requires a prebuilt helper') do
        abort 'W268: select exactly one run mode' if selected_mode
        selected_mode = :generated_matrix
      end
      parser.on('--clickhouse PATH', 'Pinned ClickHouse native executable') { |value| options[:binary] = value }
      parser.on('--crystal-helper PATH', 'Optional prebuilt W268 reader/poison helper; this script never compiles it') { |value| options[:helper] = value }
      parser.on('--evidence-root PATH', 'Existing empty direct child of /private/tmp') { |value| options[:evidence_root] = value }
    end.parse!
    abort 'W268: choose --stock-only or --generated-matrix and provide --evidence-root' unless selected_mode && options[:evidence_root]
    abort 'W268: --generated-matrix requires --crystal-helper' if selected_mode == :generated_matrix && !options[:helper]
    ok = Probe.new(binary: options[:binary], helper: options[:helper], evidence_root: options[:evidence_root],
                   generated_matrix: selected_mode == :generated_matrix).run
    exit(ok ? 0 : 1)
  rescue StandardError => error
    warn "W268 runner error: #{error.class}: #{error.message}"
    exit 1
  end
end

if $PROGRAM_NAME == __FILE__
  ProbeCompactPartWriterW268.main
end
