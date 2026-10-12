#!/usr/bin/env ruby
# Capture native Compact LowCardinality per-mark state before asking the
# Crystal reader to consume it. Native literals are intentionally independent
# of the Crystal fixture.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require_relative 'probe_object_shared_json_interop_w241'

module ProbeCompactPartWriterW266
  W241 = ProbeObjectSharedJSONInteropW241
  FORMAT = 'compact_part_writer_w266_qualification_v1'.freeze
  HELPER_FORMAT = 'compact_part_writer_w266_helper_v1'.freeze
  PART_NAME = 'all_1_1_0'.freeze
  HELPER_SOURCE = File.expand_path('compact_part_writer_w266_helper.cr', __dir__).freeze
  FIXTURE_SOURCE = File.expand_path('../spec/support/compact_part_writer_w266_fixture.cr', __dir__).freeze
  W241_SOURCE = File.expand_path('probe_object_shared_json_interop_w241.rb', __dir__).freeze
  MAX_PART_FILES = 128
  MAX_PART_BYTES = 64 * 1024 * 1024
  SCHEMA = [
    ['pk', 'UInt64'],
    ['root', 'LowCardinality(String)'],
    ['maybe', 'LowCardinality(Nullable(String))'],
    ['items', 'Array(LowCardinality(Nullable(String)))'],
  ].map(&:freeze).freeze
  WINDOWS = {
    'full' => [0, 4], 'middle' => [1, 2], 'last' => [3, 1], 'empty' => [4, 0],
  }.transform_values(&:freeze).freeze
  SLOT_ROSTER_MRK4 = [
    ['pk', 'pk'], ['root', 'root.dict_prefix'], ['root', 'root.dict'], ['root', 'root'],
    ['maybe', 'maybe.dict_prefix'], ['maybe', 'maybe.dict'], ['maybe', 'maybe'],
    ['items', 'items.dict_prefix'], ['items', 'items.size0'], ['items', 'items.dict'], ['items', 'items'],
  ].map(&:freeze).freeze
  SLOT_ROSTER_MRK3 = SCHEMA.map { |name, _type| [name, nil].freeze }.freeze
  TAG = {
    schema: '__W266_SCHEMA__', part: '__W266_PART__',
    check_begin: '__W266_CHECK_BEGIN__', check_end: '__W266_CHECK_END__',
  }.freeze

  # Native oracle. This does not load the Crystal fixture or helper response.
  ROWS = [
    {pk: 101, root: 'red'.b, maybe: 'red'.b, items: ['red'.b]},
    {pk: 102, root: 'blue'.b, maybe: nil, items: [nil, ''.b]},
    {pk: 103, root: 'cyan'.b, maybe: nil, items: []},
    {pk: 104, root: 'gold'.b, maybe: ''.b, items: []},
    {pk: 105, root: 'red'.b, maybe: 'blue'.b, items: ["\xff\x80A".b]},
    {pk: 106, root: 'blue'.b, maybe: 'red'.b, items: ['red'.b, nil]},
    {pk: 107, root: "\xff\x80A".b, maybe: ''.b, items: ['green'.b]},
    {pk: 108, root: ''.b, maybe: "\xff\x80A".b, items: [''.b, "\0".b, nil]},
  ].map(&:freeze).freeze

  class Failure < StandardError; end

  class Probe
    def initialize(binary:, helper:, evidence_root:)
      @binary = validate_executable(binary, 'pinned ClickHouse')
      @helper = validate_executable(helper, 'prebuilt W266 helper')
      @root = validate_root(evidence_root)
      @runner = W241::Probe.new(@binary, @helper, @root)
      @invocations = @runner.instance_variable_get(:@invocations)
      @token = Digest::SHA256.hexdigest(@root)[0, 8]
      @table = "w266_#{@token}_stock"
      @store = File.join(@root, 'stores', 'native')
    end

    def run(capture_only: false)
      prepare!
      capture_stock_first!
      compare_crystal_windows!
      forward = nil
      unless capture_only
        forward = qualify_forward_parts!
      end
      verify_pins!
      summary = {
        format: FORMAT, status: capture_only ? 'stock_mrk4_capture_observed' : 'mrk3_mrk4_forward_qualification_observed',
        runtime: {path: @binary, sha256: W241::BINARY_SHA256, version: W241::VERSION, build: W241::BUILD,
                  sha256_before: @binary_sha_before, sha256_after: binary_sha},
        fixture: ROWS.map { |row| expected_row(row) },
        source: {part_path: @part_path, part_name: PART_NAME, schema: SCHEMA, part_inventory: @part_inventory},
        source_hashes: @source_hashes_before,
        stock_lifecycle: @stock_observation,
        crystal_reader: @crystal_observation,
        forward_qualification: forward,
        invocations: @invocations, evidence_root: @root,
        qualification_boundary: capture_only ?
          'Capture-only: no Crystal-produced part is attached to ClickHouse; MRK3/MRK4 forward-write qualification and poison negative are not included in this mode.' :
          'Full mode writes and locally reads Crystal MRK3/MRK4 parts, then independently attempts native ATTACH/CHECK/literal windows; the copy-only poison case records native outcomes without assuming rejection.',
      }
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      puts "W266 status=#{summary.fetch(:status)}; rows=8; real_marks=4; lc_sites=3; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      persist_inconclusive(error)
      warn "W266 Compact LowCardinality capture inconclusive: #{@fatal_error}"
      false
    end

    private

    def fail!(message)
      raise Failure, "W266: #{message}"
    end

    def validate_root(path)
      fail!('evidence root must already exist, be empty, and be a direct child of /private/tmp') unless
        path && File.directory?(File.expand_path(path)) && !File.symlink?(File.expand_path(path))
      expanded = File.expand_path(path)
      fail!('evidence root must be a direct child of /private/tmp') unless File.dirname(expanded) == File.realpath('/private/tmp')
      fail!('evidence root must be empty and canonical') unless File.realpath(expanded) == expanded && Dir.children(expanded).empty?
      expanded
    rescue Errno::ENOENT
      fail!('evidence root must already exist')
    end

    def validate_executable(path, label)
      fail!("#{label} is absent, non-executable, or symlinked") unless
        path && File.file?(File.expand_path(path)) && File.executable?(File.expand_path(path)) && !File.symlink?(File.expand_path(path))
      File.realpath(path)
    end

    def prepare!
      %w[invocations stores parts].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(@store, 0o700)
      @binary_sha_before = binary_sha
      @helper_sha_before = helper_sha
      fail!('ClickHouse binary differs from the W241 pin') unless @binary_sha_before == W241::BINARY_SHA256
      @source_hashes_before = [__FILE__, HELPER_SOURCE, FIXTURE_SOURCE, W241_SOURCE].to_h do |path|
        [File.realpath(path), Digest::SHA256.file(path).hexdigest]
      end
    end

    def binary_sha
      Digest::SHA256.file(@binary).hexdigest
    end

    def helper_sha
      Digest::SHA256.file(@helper).hexdigest
    end

    def write_new(path, bytes)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes) }
    end

    def pin_sql
      # Keep the shared runner's literal marker: assert_pin! validates it.
      @runner.send(:pin_sql)
    end

    def native(label, sql, store = @store)
      result = @runner.send(:native, label, store, [pin_sql, sql].join("\n"))
      record = result.fetch(:record)
      fail!("#{label} timed out or had an infrastructure failure: #{record.inspect}") unless
        !record[:timed_out] && record[:spawn_error].nil? && record[:stdin_write_error].nil? &&
        record[:stdout_read_error].nil? && record[:stderr_read_error].nil? && result[:status] && result[:status].termsig.nil?
      fail!("#{label} was not a bounded native success/refusal: #{record.inspect}") unless
        %w[success server_exception].include?(result[:classification])
      if result[:classification] == 'success'
        @runner.send(:assert_native_success!, result, label)
        @runner.send(:assert_pin!, result[:stdout], label)
      else
        fail!("#{label} native executable identity changed") unless record[:binary_sha_after] == W241::BINARY_SHA256
      end
      result
    end

    def native_lines(result, label)
      text = result[:stdout].dup.force_encoding(Encoding::UTF_8)
      fail!("#{label} output is not UTF-8/newline-terminated") unless text.valid_encoding? && text.end_with?("\n")
      text.lines.map(&:chomp)
    end

    def settings(mark_layout = 1)
      [
        'index_granularity=2', 'index_granularity_bytes=10485760', 'enable_mixed_granularity_parts=1',
        'min_rows_for_wide_part=1000000', 'min_bytes_for_wide_part=104857600', 'min_level_for_wide_part=0',
        'compress_marks=0', 'compress_primary_key=0', "write_marks_for_substreams_in_compact_parts=#{mark_layout}",
        'min_compress_block_size=0', 'max_compress_block_size=4096',
        'ratio_of_defaults_for_sparse_serialization=1.0', "default_compression_codec='LZ4'",
        "serialization_info_version='with_types'", 'propagate_types_serialization_versions_to_nested_types=true',
        "string_serialization_version='single_stream'", "nullable_serialization_version='basic'",
      ].join(', ')
    end

    def declarations
      SCHEMA.map { |name, type| "`#{name}` #{type}" }.join(', ')
    end

    def table_name(case_name)
      "w266_#{@token}_#{case_name}"
    end

    def store_path(case_name)
      File.join(@root, 'stores', 'native', case_name)
    end

    def case_tag(kind, case_name, window = nil)
      suffix = "_#{case_name.upcase}"
      suffix += "_#{window.upcase}" if window
      "__W266_#{kind.to_s.upcase}#{suffix}__"
    end

    def sql_bytes(value)
      "unhex('#{value.b.unpack1('H*')}')"
    end

    def sql_nullable(value)
      value.nil? ? "CAST(NULL, 'Nullable(String)')" : "CAST(#{sql_bytes(value)}, 'Nullable(String)')"
    end

    def sql_array(values)
      return "CAST([], 'Array(Nullable(String))')" if values.empty?
      "CAST([#{values.map { |value| sql_nullable(value) }.join(', ')}], 'Array(Nullable(String))')"
    end

    def insert_sql
      rows = ROWS.map do |row|
        "(#{row.fetch(:pk)}, #{sql_bytes(row.fetch(:root))}, #{sql_nullable(row.fetch(:maybe))}, #{sql_array(row.fetch(:items))})"
      end
      "INSERT INTO default.#{@table} VALUES\n#{rows.join(",\n")};\n"
    end

    def native_window_sql(name, predicate, table = @table, case_name = nil)
      tag = case_name ? "__W266_NATIVE_#{case_name.upcase}_#{name.upcase}__" : "__W266_NATIVE_#{name.upcase}__"
      if name == 'empty'
        return "SELECT '#{tag}', toString(count()) FROM default.#{table} WHERE #{predicate} FORMAT TSVRaw;\n"
      end
      "SELECT '#{tag}', toString(pk), lower(hex(root)), " \
        "if(isNull(maybe), 'N', concat('S:', lower(hex(ifNull(maybe, ''))))), " \
        "lower(hex(toJSONString(arrayMap(x -> if(isNull(x), CAST(NULL, 'Nullable(String)'), concat('S:', lower(hex(ifNull(x, ''))))), items)))) " \
        "FROM default.#{table} WHERE #{predicate} ORDER BY pk FORMAT TSVRaw;\n"
    end

    def stock_sql
      schema = "SELECT '#{TAG.fetch(:schema)}', name, type FROM system.columns " \
        "WHERE database='default' AND table='#{@table}' ORDER BY position FORMAT TSVRaw;"
      part = "SELECT '#{TAG.fetch(:part)}', table, name, path, part_type, toString(rows), toString(marks) " \
        "FROM system.parts WHERE database='default' AND table='#{@table}' AND active ORDER BY name FORMAT TSVRaw;"
      checks = "SELECT '#{TAG.fetch(:check_begin)}' FORMAT TSVRaw;\n" \
        "CHECK TABLE default.#{@table} FORMAT TSV;\n" \
        "SELECT '#{TAG.fetch(:check_end)}' FORMAT TSVRaw;"
      windows = [
        native_window_sql('full', '1'),
        native_window_sql('middle', 'pk BETWEEN 103 AND 106'),
        native_window_sql('last', 'pk >= 107'),
        native_window_sql('empty', 'pk > 108'),
      ].join
      "CREATE TABLE default.#{@table} (#{declarations}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings};\n" \
        "#{insert_sql}#{checks}\n#{schema}\n#{part}\n#{windows}"
    end

    def capture_stock_first!
      # This is deliberately the first data production action in the evidence root.
      result = native('stock_insert_and_windows', stock_sql)
      fail!('native stock INSERT/CHECK/SELECT invocation was refused') unless result[:classification] == 'success'
      lines = native_lines(result, 'stock insert and windows')
      check_rows = delimited(lines, TAG.fetch(:check_begin), TAG.fetch(:check_end))
      fail!('stock CHECK result is not exact one-row success') unless check_rows == ["#{PART_NAME}\t1\t"]
      schemas = tagged(lines, TAG.fetch(:schema), 3)
      fail!('stock schema differs from the independent W266 contract') unless
        schemas.map { |fields| fields.values_at(1, 2) } == SCHEMA
      parts = tagged(lines, TAG.fetch(:part), 7)
      fail!('native INSERT did not create one expected Compact part') unless parts.size == 1 &&
        parts.first.values_at(1, 2, 4, 5, 6) == [@table, PART_NAME, 'Compact', '8', '5']
      @part_path = safe_native_path(parts.first[3])
      @part_inventory = tree_inventory(@part_path)
      @native_windows = parse_native_windows(lines)
      @stock_observation = {
        invocation: result[:record], check_rows: check_rows,
        schema_rows: schemas, part_row: parts.first,
        windows: @native_windows,
      }
    end

    def safe_native_path(path)
      real = File.realpath(path)
      root = File.realpath(@store)
      fail!("native part escaped isolated store: #{path}") unless real.start_with?(root + File::SEPARATOR)
      fail!('native part path is not a directory') unless File.directory?(real) && !File.symlink?(path)
      real
    end

    def tagged(lines, tag, width)
      lines.select { |line| line.start_with?(tag + "\t") }.map do |line|
        fields = line.split("\t", -1)
        fail!("malformed tagged output for #{tag}") unless fields.size == width
        fields
      end
    end

    def delimited(lines, begin_tag, end_tag)
      start = lines.index(begin_tag)
      finish = lines.index(end_tag)
      fail!('stock CHECK output markers are missing or inverted') unless start && finish && finish > start
      lines[(start + 1)...finish]
    end

    def parse_native_windows(lines, case_name: nil, strict: true, only: nil)
      result = {}
      (only || WINDOWS.keys).each do |name|
        tag = case_name ? "__W266_NATIVE_#{case_name.upcase}_#{name.upcase}__" : "__W266_NATIVE_#{name.upcase}__"
        if name == 'empty'
          rows = tagged(lines, tag, 2)
          exact = rows == [[tag, '0']]
          fail!("native #{case_name || 'stock'} empty-window count is not exactly zero") if strict && !exact
          result[name] = strict ? [] : {state: exact ? 'exact_values' : 'value_mismatch', rows: rows.map(&:last)}
        else
          rows = tagged(lines, tag, 5).map { |fields| parse_native_row(fields.drop(1), name) }
          expected = ROWS_FOR_WINDOW.fetch(name).map { |row| expected_row(row) }
          exact = rows == expected
          fail!("native #{case_name || 'stock'} #{name} SELECT differs from independent literal rows") if strict && !exact
          result[name] = strict ? rows : {state: exact ? 'exact_values' : 'value_mismatch', rows: rows}
        end
      end
      result
    end

    ROWS_FOR_WINDOW = {
      'full' => ROWS,
      'middle' => ROWS[2, 4],
      'last' => ROWS[6, 2],
      'empty' => [],
    }.freeze

    def parse_native_row(fields, label)
      fail!("#{label} native row width differs") unless fields.size == 4
      array_json = begin
        JSON.parse([fields[3]].pack('H*').force_encoding(Encoding::UTF_8))
      rescue JSON::ParserError => error
        fail!("#{label} array wire is not JSON: #{error.message}")
      end
      fail!("#{label} array value is not a JSON array") unless array_json.is_a?(Array)
      fail!("#{label} array contains a non-string non-null value") unless array_json.all? { |value| value.nil? || value.is_a?(String) }
      {
        pk: Integer(fields[0], 10), root: "S:#{fields[1].downcase}",
        maybe: fields[2],
        items: array_json.map { |value| value.nil? ? 'N' : value },
      }
    end

    def expected_row(row)
      {
        pk: row.fetch(:pk), root: "S:#{row.fetch(:root).b.unpack1('H*')}",
        maybe: nullable_signature(row.fetch(:maybe)),
        items: row.fetch(:items).map { |value| nullable_signature(value) },
      }
    end

    def nullable_signature(value)
      value.nil? ? 'N' : "S:#{value.b.unpack1('H*')}"
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

    def helper(label, *arguments, expected_statuses: ['ok'])
      result = @runner.send(:run_process, label, [@helper] + arguments, ''.b, 'crystal-helper',
                            expected_sha: @helper_sha_before, binary_path: @helper)
      record = result.fetch(:record)
      fail!("#{label} helper failed or exceeded bounds: #{record.inspect}") unless
        !record[:timed_out] && record[:spawn_error].nil? && record[:stdin_write_error].nil? &&
        record[:stdout_read_error].nil? && record[:stderr_read_error].nil? && result[:status] && result[:status].termsig.nil? &&
        result[:classification] == 'success' && result[:status].success? && result[:stderr].empty?
      report = JSON.parse(result[:stdout].dup.force_encoding(Encoding::UTF_8))
      fail!("#{label} helper report envelope differs") unless report.is_a?(Hash) &&
        report['format'] == HELPER_FORMAT && report['action'] == arguments.first && expected_statuses.include?(report['status'])
      report
    rescue JSON::ParserError => error
      raise Failure, "W266: #{label} helper output is not JSON: #{error.message}"
    end

    def compare_crystal_windows!
      report = helper('stock_part_audit_and_windows', 'audit', @part_path)
      fail!('stock helper did not identify Compact MRK4') unless report['mode'] == 'mrk4'
      fail!('stock helper row/granule dimensions differ') unless report['row_count'] == 8 &&
        report['granule_count'] == 4 && report['mark_rows'] == [2, 2, 2, 2]
      roster = report.fetch('physical_roster').map { |slot| [slot.fetch('column'), slot.fetch('stream')] }
      expected_roster = [
        ['pk', 'pk'], ['root', 'root.dict_prefix'], ['root', 'root.dict'], ['root', 'root'],
        ['maybe', 'maybe.dict_prefix'], ['maybe', 'maybe.dict'], ['maybe', 'maybe'],
        ['items', 'items.dict_prefix'], ['items', 'items.size0'], ['items', 'items.dict'], ['items', 'items'],
      ]
      fail!('stock physical callback roster differs') unless roster == expected_roster
      validate_mark_tape!(report, 'mrk4', 'stock helper')
      @stock_lc_dictionaries = audit_low_cardinality!(report.fetch('low_cardinality_sites'), 'stock helper')
      crystal_windows = report.fetch('windows')
      WINDOWS.each do |name, (first_mark, mark_count)|
        actual = crystal_windows.fetch(name)
        expected_columns = %w[items maybe pk root]
        expected_rows = ROWS_FOR_WINDOW.fetch(name).map { |row| expected_row(row) }
        fail!("Crystal #{name} selected-window column roster differs") unless actual.keys.sort == expected_columns
        actual.each do |column, values|
          fail!("Crystal #{name} #{column} window length differs") unless values.is_a?(Array) && values.size == expected_rows.size
        end
        observed_rows = (0...expected_rows.size).map do |index|
          {
            pk: Integer(actual.fetch('pk').fetch(index), 10),
            root: actual.fetch('root').fetch(index),
            maybe: actual.fetch('maybe').fetch(index),
            items: parse_item_signature(actual.fetch('items').fetch(index), "Crystal #{name} row #{index}"),
          }
        end
        fail!("Crystal #{name} selected-window rows differ from independent literals") unless observed_rows == expected_rows
        fail!("stock-to-Crystal #{name} selected-window values differ") unless @native_windows.fetch(name) == observed_rows
        fail!("Crystal #{name} mark selection metadata changed") unless WINDOWS.fetch(name) == [first_mark, mark_count]
      end
      @crystal_observation = {helper_sha256: @helper_sha_before, report: report,
                              stock_part_inventory_after_read: tree_inventory(@part_path)}
      fail!('Crystal reader mutated the native source part') unless @part_inventory == @crystal_observation[:stock_part_inventory_after_read]
    end

    def audit_low_cardinality!(sites, label)
      expected_columns = %w[root maybe items]
      fail!("#{label} LC site inventory differs") unless sites.map { |site| site.fetch('column') } == expected_columns
      sites.each do |site|
        marks = site.fetch('marks')
        fail!("#{label} #{site.fetch('column')} LC mark count differs") unless marks.size == 4
        marks.each_with_index do |mark, index|
          fail!("#{label} #{site.fetch('column')} mark #{index} prefix/body differs") unless
            mark.fetch('mark') == index && mark.fetch('prefix_version') == 1 &&
            mark.fetch('prefix_bytes') == 8 && mark.fetch('dictionary_bytes') == 0 &&
            mark.fetch('dictionary_hex') == '' && mark.fetch('index_hex').bytesize == mark.fetch('index_bytes') * 2
          next if mark.fetch('index_bytes').zero?
          flags = mark.fetch('flags')
          fail!("#{label} #{site.fetch('column')} mark #{index} does not encode ADDITIONAL+UPDATE without GLOBAL") unless
            flags && (flags & 0x100).zero? && (flags & 0x600) == 0x600
        end
      end
      empty_items_mark = sites.fetch(2).fetch('marks').fetch(1)
      fail!("#{label} middle Array(LC Nullable(String)) granule is not an empty dictionary-index body") unless
        empty_items_mark.fetch('index_bytes').zero? && empty_items_mark.fetch('flags').nil?
      sites.each_with_index.map do |site, site_index|
        nullable = site_index != 0
        decoded_marks = site.fetch('marks').each_with_index.map do |mark, mark_index|
          expected = expected_lc_values(site.fetch('column'), mark_index)
          decoded = decode_lc_body(mark.fetch('index_hex'), nullable: nullable,
                                   label: "#{label} #{site.fetch('column')} mark #{mark_index}")
          fail!("#{label} #{site.fetch('column')} mark #{mark_index} dictionary indexes differ from literal values") unless
            decoded.fetch(:values) == expected.map { |value| nullable_signature(value) }
          decoded
        end
        {column: site.fetch('column'), marks: decoded_marks}
      end
    end

    def expected_lc_values(column, mark_index)
      rows = ROWS[mark_index * 2, 2]
      case column
      when 'root' then rows.map { |row| row.fetch(:root).b }
      when 'maybe' then rows.map { |row| row.fetch(:maybe)&.b }
      when 'items' then rows.flat_map { |row| row.fetch(:items).map { |value| value&.b } }
      else fail!("unknown LC dictionary site #{column}")
      end
    end

    def decode_lc_body(hex, nullable:, label:)
      fail!("#{label} index body is not canonical hex") unless hex.is_a?(String) && hex.match?(/\A(?:[0-9a-f]{2})*\z/)
      bytes = [hex].pack('H*').b
      if bytes.empty?
        return {flags: nil, keys: [], indexes: [], values: []}
      end
      fail!("#{label} index body is shorter than the flags word") if bytes.bytesize < 8
      flags = bytes.byteslice(0, 8).unpack1('Q<')
      fail!("#{label} flags differ from ADDITIONAL+UPDATE/no-GLOBAL") unless
        (flags & 0x100).zero? && (flags & 0x600) == 0x600 && (flags & ~0x7ff).zero?
      index_type = flags & 0xff
      index_width = {0 => 1, 1 => 2, 2 => 4, 3 => 8}[index_type]
      fail!("#{label} index width type is invalid") unless index_width
      cursor = 8
      key_count = read_u64_le(bytes, cursor, "#{label} key count")
      cursor += 8
      fail!("#{label} key count exceeds the bounded dictionary") if key_count > 4096
      keys = Array.new(key_count) do |index|
        length, cursor = read_var_uint(bytes, cursor, "#{label} key #{index} length")
        fail!("#{label} key #{index} exceeds index body") if length > bytes.bytesize - cursor
        value = bytes.byteslice(cursor, length).b
        cursor += length
        nullable_signature(nullable && index.zero? ? nil : value)
      end
      row_count = read_u64_le(bytes, cursor, "#{label} row count")
      cursor += 8
      fail!("#{label} row count exceeds fixture bound") if row_count > 64
      fail!("#{label} indexes exceed index body") if row_count * index_width > bytes.bytesize - cursor
      indexes = Array.new(row_count) do
        value = bytes.byteslice(cursor, index_width).unpack1({1 => 'C', 2 => 'v', 4 => 'V', 8 => 'Q<'}.fetch(index_width))
        cursor += index_width
        fail!("#{label} index #{value} exceeds dictionary count #{key_count}") if value >= key_count
        value
      end
      fail!("#{label} index body has trailing bytes") unless cursor == bytes.bytesize
      {flags: flags, keys: keys, indexes: indexes, values: indexes.map { |index| keys.fetch(index) }}
    end

    def read_u64_le(bytes, offset, label)
      fail!("#{label} is truncated") if offset.negative? || offset > bytes.bytesize - 8
      bytes.byteslice(offset, 8).unpack1('Q<')
    end

    def read_var_uint(bytes, offset, label)
      value = 0
      shift = 0
      loop do
        fail!("#{label} is truncated") if offset >= bytes.bytesize || shift > 63
        byte = bytes.getbyte(offset)
        offset += 1
        fail!("#{label} overflows UInt64") if shift == 63 && byte > 1
        value |= (byte & 0x7f) << shift
        return [value, offset] if (byte & 0x80).zero?
        shift += 7
      end
    end

    def parse_item_signature(signature, label)
      fail!("#{label} nested signature is not bracketed") unless signature.is_a?(String) && signature.start_with?('[') && signature.end_with?(']')
      body = signature[1...-1]
      return [] if body.empty?
      items = body.split(',', -1)
      fail!("#{label} nested signature contains an invalid item") unless items.all? { |item| item.match?(/\A(?:N|S:(?:[0-9a-f]{2})*)\z/) }
      items
    end

    def validate_mark_tape!(report, mode, label, inventory = nil)
      fail!("#{label} mode differs") unless report.fetch('mode') == mode
      tape = report.fetch('physical_mark_tape')
      slots = mode == 'mrk4' ? SLOT_ROSTER_MRK4.size : SLOT_ROSTER_MRK3.size
      mark_file = mode == 'mrk4' ? 'data.mrk4' : 'data.mrk3'
      width = slots * 16 + 8
      fail!("#{label} mark filename/slot count/record width differs") unless
        tape.fetch('file') == mark_file && tape.fetch('slot_count') == slots && tape.fetch('record_width') == width
      fail!("#{label} mark tape does not contain four real marks plus EOF") unless
        tape.fetch('byte_size') == width * 5 && tape.fetch('real_mark_rows') == [2, 2, 2, 2] && tape.fetch('records').size == 5
      records = tape.fetch('records')
      fail!("#{label} physical mark row counts differ") unless records.map { |record| record.fetch('row_count') } == [2, 2, 2, 2, 0]
      compressed_size = tape.fetch('compressed_size')
      raw_size = tape.fetch('raw_size')
      terminal_ok = records.last.fetch('pairs').size == slots && records.last.fetch('pairs').all? do |pair|
        pair.fetch('compressed_offset') == compressed_size && pair.fetch('decompressed_offset').zero? &&
          pair.fetch('logical_position') == raw_size
      end
      fail!("#{label} terminal mark is not the all-slot compressed/raw EOF") unless terminal_ok
      if inventory
        data_entry = inventory.fetch(:files).find { |entry| entry.fetch(:path) == 'data.bin' }
        fail!("#{label} data.bin is absent from inventory") unless data_entry
        fail!("#{label} compressed mark coordinates disagree with data.bin physical EOF") unless
          compressed_size == data_entry.fetch(:size)
      end
      true
    end

    def validate_local_report!(report, mode, label, inventory)
      fail!("#{label} helper status differs") unless report.fetch('status') == 'ok'
      fail!("#{label} row/granule dimensions differ") unless
        report.fetch('row_count') == 8 && report.fetch('granule_count') == 4 && report.fetch('mark_rows') == [2, 2, 2, 2]
      expected_roster = mode == 'mrk4' ? SLOT_ROSTER_MRK4 : SLOT_ROSTER_MRK3
      roster = report.fetch('physical_roster').map { |slot| [slot.fetch('column'), slot['stream']] }
      fail!("#{label} callback roster differs") unless roster == expected_roster
      validate_mark_tape!(report, mode, label, inventory)
      dictionaries = mode == 'mrk4' ? audit_low_cardinality!(report.fetch('low_cardinality_sites'), label) : nil
      WINDOWS.each do |name, _selection|
        columns = report.fetch('windows').fetch(name)
        expected_rows = ROWS_FOR_WINDOW.fetch(name).map { |row| expected_row(row) }
        fail!("#{label} #{name} column roster differs") unless columns.keys.sort == %w[items maybe pk root]
        columns.each do |column, values|
          fail!("#{label} #{name} #{column} length differs") unless values.is_a?(Array) && values.size == expected_rows.size
        end
        rows = (0...expected_rows.size).map do |index|
          {pk: Integer(columns.fetch('pk').fetch(index), 10), root: columns.fetch('root').fetch(index),
           maybe: columns.fetch('maybe').fetch(index), items: parse_item_signature(columns.fetch('items').fetch(index), "#{label} #{name} row #{index}")}
        end
        fail!("#{label} #{name} local-reader values differ from independent literals") unless rows == expected_rows
      end
      {report: report, lc_dictionaries: dictionaries, inventory: inventory}
    end

    def write_and_readback!(case_name, mode)
      part = File.join(@root, 'parts', case_name, PART_NAME)
      FileUtils.mkdir_p(File.dirname(part), mode: 0o700)
      write = helper("#{case_name}_write", 'write-only', part, mode)
      fail!("#{case_name} helper did not write requested mark format") unless write.fetch('mark_format') == mode
      inventory_before = tree_inventory(part)
      report = helper("#{case_name}_local_readback", 'audit', part)
      local = validate_local_report!(report, mode, case_name, inventory_before)
      inventory_after = tree_inventory(part)
      fail!("#{case_name} local readback mutated the source part") unless inventory_before == inventory_after
      {part_path: part, write: write, local: local, inventory: inventory_before}
    end

    def schema_query(table, case_name)
      "SELECT '#{case_tag('schema', case_name)}', name, type FROM system.columns " \
        "WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;\n"
    end

    def table_path_query(table, case_name)
      "SELECT '#{case_tag('path', case_name)}', arrayElement(data_paths, 1) FROM system.tables " \
        "WHERE database='default' AND name='#{table}' FORMAT TSVRaw;\n"
    end

    def part_query(table, case_name)
      "SELECT '#{case_tag('part', case_name)}', table, name, path, part_type, toString(rows), toString(marks) " \
        "FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;\n"
    end

    def create_native_table!(case_name, mark_layout)
      table = table_name(case_name)
      store = store_path(case_name)
      sql = "CREATE TABLE default.#{table} (#{declarations}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings(mark_layout)};\n" \
        "#{schema_query(table, case_name)}#{table_path_query(table, case_name)}"
      result = native("#{case_name}_create", sql, store)
      fail!("#{case_name} native CREATE was refused") unless result.fetch(:classification) == 'success'
      lines = native_lines(result, "#{case_name} CREATE")
      schemas = tagged(lines, case_tag('schema', case_name), 3).map { |fields| fields.drop(1) }
      fail!("#{case_name} created schema differs from independent contract") unless schemas == SCHEMA
      paths = tagged(lines, case_tag('path', case_name), 2)
      fail!("#{case_name} table path output is not unique") unless paths.size == 1 && !paths.first[1].empty?
      data_path = safe_native_path(paths.first[1])
      {table: table, store: store, data_path: data_path, create: result[:record], schema: schemas}
    end

    def payload_hashes(inventory)
      entries = inventory.fetch(:files).select { |entry| %w[data.bin data.mrk3 data.mrk4].include?(entry.fetch(:path)) }
      entries.to_h { |entry| [entry.fetch(:path), {size: entry.fetch(:size), sha256: entry.fetch(:sha256)}] }
    end

    def check_rows(lines, begin_tag, end_tag)
      first = lines.index(begin_tag)
      last = lines.index(end_tag)
      return nil unless first && last && last > first
      lines[(first + 1)...last]
    end

    def check_native!(case_name, table, store, strict:)
      begin_tag = case_tag('check_begin', case_name)
      end_tag = case_tag('check_end', case_name)
      sql = "SELECT '#{begin_tag}' FORMAT TSVRaw;\nCHECK TABLE default.#{table} FORMAT TSV;\nSELECT '#{end_tag}' FORMAT TSVRaw;\n"
      result = native("#{case_name}_check", sql, store)
      state = result.fetch(:classification)
      record = {state: state, invocation: result.fetch(:record)}
      if state == 'success'
        begin
          rows = check_rows(native_lines(result, "#{case_name} CHECK"), begin_tag, end_tag)
          record[:rows] = rows
          record[:exact_success] = rows == ["#{PART_NAME}\t1\t"]
        rescue StandardError => error
          raise if strict
          return {state: 'oracle_parse_error', invocation: result.fetch(:record), detail: "#{error.class}: #{error.message}"}
        end
      end
      if strict
        fail!("#{case_name} native CHECK was refused") unless state == 'success'
        fail!("#{case_name} native CHECK did not return exactly one healthy part") unless record[:exact_success]
      end
      record
    end

    def run_native_window!(case_name, table, store, window, strict:)
      predicates = {'full' => '1', 'middle' => 'pk BETWEEN 103 AND 106', 'last' => 'pk >= 107', 'empty' => 'pk > 108'}
      predicate = predicates.fetch(window) { fail!("unknown native window #{window}") }
      result = native("#{case_name}_select_#{window}", native_window_sql(window, predicate, table, case_name), store)
      state = result.fetch(:classification)
      if state != 'success'
        fail!("#{case_name} native #{window} SELECT was refused") if strict
        return {state: state, invocation: result.fetch(:record)}
      end
      begin
        lines = native_lines(result, "#{case_name} #{window} SELECT")
        parsed = parse_native_windows(lines, case_name: case_name, strict: strict, only: [window]).fetch(window)
        observation = if strict
                        {state: 'exact_values', rows: window == 'empty' ? 0 : parsed.size}
                      else
                        {state: parsed.fetch(:state), rows: parsed.fetch(:rows)}
                      end
        observation.merge(invocation: result.fetch(:record))
      rescue StandardError => error
        raise if strict
        {state: 'oracle_parse_error', detail: "#{error.class}: #{error.message}", invocation: result.fetch(:record)}
      end
    end

    def attach_generated_part!(case_name, part_path, target, strict:)
      @runner.send(:attach_part!, part_path, target.fetch(:data_path))
      detached = File.join(target.fetch(:data_path), 'detached', PART_NAME)
      source_inventory = tree_inventory(part_path)
      detached_inventory = tree_inventory(detached)
      fail!("#{case_name} detached copy differs from generated source") unless source_inventory == detached_inventory
      attach = native("#{case_name}_attach", "ALTER TABLE default.#{target.fetch(:table)} ATTACH PART '#{PART_NAME}';\n", target.fetch(:store))
      state = attach.fetch(:classification)
      attach_observation = {state: state, invocation: attach.fetch(:record)}
      if strict
        fail!("#{case_name} native ATTACH was refused") unless state == 'success'
      end
      attach_observation
    end

    def active_part_observation!(case_name, target, source_inventory, strict:)
      sql = schema_query(target.fetch(:table), case_name) + part_query(target.fetch(:table), case_name)
      result = native("#{case_name}_active_schema_part", sql, target.fetch(:store))
      state = result.fetch(:classification)
      observation = {state: state, invocation: result.fetch(:record)}
      if state != 'success'
        fail!("#{case_name} active schema/part query was refused") if strict
        return observation
      end
      begin
        lines = native_lines(result, "#{case_name} active schema/part")
        schemas = tagged(lines, case_tag('schema', case_name), 3).map { |fields| fields.drop(1) }
        parts = tagged(lines, case_tag('part', case_name), 7)
        exact_part = parts.size == 1 && parts.first.values_at(1, 2, 4, 5, 6) ==
          [target.fetch(:table), PART_NAME, 'Compact', '8', '5']
      rescue StandardError => error
        raise if strict
        return observation.merge(state: 'oracle_parse_error', detail: "#{error.class}: #{error.message}")
      end
      observation[:schema_rows] = schemas
      observation[:part_rows] = parts
      observation[:exact_schema] = schemas == SCHEMA
      observation[:exact_compact_part] = exact_part
      if exact_part
        active_path = safe_native_path(parts.first[3])
        active_inventory = tree_inventory(active_path)
        observation[:active_inventory] = active_inventory
        observation[:payload_matches_detached] = payload_hashes(active_inventory) == payload_hashes(source_inventory)
      end
      if strict
        fail!("#{case_name} active schema differs") unless observation[:exact_schema]
        fail!("#{case_name} did not expose one active 8-row/5-mark Compact part") unless observation[:exact_compact_part]
        fail!("#{case_name} active data/mark payload differs from detached source") unless observation[:payload_matches_detached]
      end
      observation
    end

    def qualify_positive_part!(case_name, part_case, mode, mark_layout)
      local = write_and_readback!(part_case, mode)
      target = create_native_table!(case_name, mark_layout)
      inventory_before_attach = tree_inventory(local.fetch(:part_path))
      attach = attach_generated_part!(case_name, local.fetch(:part_path), target, strict: true)
      active = active_part_observation!(case_name, target, local.fetch(:inventory), strict: true)
      check = check_native!(case_name, target.fetch(:table), target.fetch(:store), strict: true)
      selects = WINDOWS.keys.to_h do |window|
        [window, run_native_window!(case_name, target.fetch(:table), target.fetch(:store), window, strict: true)]
      end
      inventory_after = tree_inventory(local.fetch(:part_path))
      fail!("#{case_name} native qualification mutated generated source part") unless inventory_after == inventory_before_attach
      {mark_format: mode, generated_part: local, native_target: target, attach: attach,
       active_schema_part: active, check: check, selects: selects,
       generated_source_inventory_after_native: inventory_after}
    end

    def validate_poison_copy!(source, mutant, helper_result)
      before = tree_inventory(source)
      after = tree_inventory(mutant)
      changed = (before.fetch(:files).map { |entry| entry.fetch(:path) } | after.fetch(:files).map { |entry| entry.fetch(:path) }).sort.select do |name|
        before.fetch(:files).find { |entry| entry.fetch(:path) == name } != after.fetch(:files).find { |entry| entry.fetch(:path) == name }
      end
      fail!('prefix poison copy did not change exactly checksums.txt and data.bin') unless changed == %w[checksums.txt data.bin]
      source_map = before.fetch(:files).to_h { |entry| [entry.fetch(:path), entry] }
      mutant_map = after.fetch(:files).to_h { |entry| [entry.fetch(:path), entry] }
      fail!('prefix poison changed physical data.bin size') unless source_map.fetch('data.bin').fetch(:size) == mutant_map.fetch('data.bin').fetch(:size)
      fail!('prefix poison unexpectedly changed MRK3/MRK4 coordinates') unless
        %w[data.mrk3 data.mrk4].all? { |name| source_map[name] == mutant_map[name] }
      fail!('prefix poison copy reports unexpected mutation metadata') unless helper_result.fetch('changed_files').sort == changed &&
        helper_result.fetch('poisoned_mark') == 1 && helper_result.fetch('poisoned_column') == 'root' && helper_result.fetch('prefix_version') == 2
      prefix_offset = helper_result.fetch('prefix_logical_offset')
      fail!('prefix poison did not change exactly the selected one-byte prefix') unless
        helper_result.fetch('prefix_byte_before') == 1 && helper_result.fetch('prefix_byte_after') == 2 &&
        helper_result.fetch('raw_changed_offsets') == [prefix_offset] && helper_result.fetch('raw_size').positive? &&
        prefix_offset >= 0 && prefix_offset + 8 <= helper_result.fetch('raw_size') && helper_result.fetch('frame_count').positive? &&
        helper_result.fetch('compressed_size') == source_map.fetch('data.bin').fetch(:size)
      {changed_files: changed, source_inventory: before, mutant_inventory: after}
    end

    def qualify_poisoned_prefix!(source_part)
      source_before = tree_inventory(source_part)
      mutant = File.join(@root, 'parts', 'poison_mrk4', PART_NAME)
      FileUtils.mkdir_p(File.dirname(mutant), mode: 0o700)
      mutation = helper('poison_copy_prefix', 'copy-mutant', 'prefix', source_part, mutant)
      copy_audit = validate_poison_copy!(source_part, mutant, mutation)
      fail!('prefix poison changed original MRK4 source') unless tree_inventory(source_part) == source_before
      selected = helper('poison_local_middle_root_reader', 'inspect-outcome', mutant, 'root', '1', '1',
                        expected_statuses: %w[accepted rejected])
      fail!('selected Crystal reader accepted poisoned middle-granule LC prefix') unless selected.fetch('status') == 'rejected'
      fail!('poisoned LC prefix rejection did not identify unsupported version state') unless
        selected.fetch('error_class', '') == 'CrystalClick::UnsupportedFormatError' &&
        selected.fetch('error_message', '').match?(/unsupported Compact LowCardinality state-prefix version/)
      unselected = helper('poison_local_middle_pk_control', 'inspect-outcome', mutant, 'pk', '1', '1',
                          expected_statuses: %w[accepted rejected])
      fail!('unselected pk control did not retain exact middle-granule keys') unless
        unselected.fetch('status') == 'accepted' && unselected.fetch('first_mark') == 1 &&
        unselected.fetch('mark_count') == 1 && unselected.fetch('row_count') == 2 &&
        unselected.fetch('key_values') == %w[103 104]

      target = create_native_table!('poison_mrk4', 1)
      @runner.send(:attach_part!, mutant, target.fetch(:data_path))
      detached = File.join(target.fetch(:data_path), 'detached', PART_NAME)
      detached_inventory = tree_inventory(detached)
      fail!('poison native detached copy differs') unless detached_inventory == copy_audit.fetch(:mutant_inventory)
      attach = native('poison_mrk4_attach', "ALTER TABLE default.#{target.fetch(:table)} ATTACH PART '#{PART_NAME}';\n", target.fetch(:store))
      attach_observation = {state: attach.fetch(:classification), invocation: attach.fetch(:record)}
      active = active_part_observation!('poison_mrk4', target, copy_audit.fetch(:mutant_inventory), strict: false)
      check = check_native!('poison_mrk4', target.fetch(:table), target.fetch(:store), strict: false)
      selects = WINDOWS.keys.to_h do |window|
        [window, run_native_window!('poison_mrk4', target.fetch(:table), target.fetch(:store), window, strict: false)]
      end
      fail!('prefix poison changed original MRK4 source after native trial') unless tree_inventory(source_part) == source_before
      {copy_audit: copy_audit, local_selected_reader: selected, local_unselected_pk_control: unselected, native_target: target,
       native_attach: attach_observation, native_active_schema_part: active, native_check: check,
       native_selects: selects, original_source_inventory_after: tree_inventory(source_part)}
    end

    def qualify_forward_parts!
      mrk3 = qualify_positive_part!('generated_mrk3', 'generated_mrk3', 'mrk3', 0)
      mrk4 = qualify_positive_part!('generated_mrk4', 'generated_mrk4', 'mrk4', 1)
      poison = qualify_poisoned_prefix!(mrk4.fetch(:generated_part).fetch(:part_path))
      {mrk3: mrk3, mrk4: mrk4, poisoned_middle_prefix: poison}
    end

    def verify_pins!
      fail!('ClickHouse SHA changed during capture') unless binary_sha == W241::BINARY_SHA256
      @source_hashes_before.each do |path, sha|
        fail!("probe source changed during run: #{path}") unless Digest::SHA256.file(path).hexdigest == sha
      end
      fail!('Crystal helper SHA changed during capture') unless helper_sha == @helper_sha_before
    end

    def persist_inconclusive(error)
      return if File.exist?(File.join(@root, 'summary.json'))
      summary = {format: FORMAT, status: 'inconclusive', fatal_error: "#{error.class}: #{error.message}",
                 evidence_root: @root, invocations: @invocations}
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
    rescue StandardError => summary_error
      warn "W266 inconclusive summary persistence failed: #{summary_error.class}: #{summary_error.message}"
    end
  end

  def self.main
    options = {binary: W241::BINARY, capture_only: false}
    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby scripts/probe_compact_part_writer_w266.rb --evidence-root EMPTY_CHILD_OF_PRIVATE_TMP --crystal-helper EXECUTABLE [--clickhouse CLICKHOUSE] [--capture-only]'
      parser.on('--clickhouse PATH') { |value| options[:binary] = value }
      parser.on('--crystal-helper PATH') { |value| options[:helper] = value }
      parser.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
      parser.on('--capture-only', 'capture and read the independent native MRK4 stock part only') { options[:capture_only] = true }
    end.parse!
    raise 'evidence root is required via --evidence-root' unless options[:evidence_root]
    raise 'prebuilt Crystal helper is required via --crystal-helper' unless options[:helper]
    exit(Probe.new(binary: options[:binary], helper: options[:helper], evidence_root: options[:evidence_root])
      .run(capture_only: options[:capture_only]) ? 0 : 1)
  rescue OptionParser::ParseError => error
    warn error.message
    exit 2
  end
end

ProbeCompactPartWriterW266.main if $PROGRAM_NAME == __FILE__
