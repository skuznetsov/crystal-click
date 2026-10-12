#!/usr/bin/env ruby
# Bounded native falsifier for recursive Compact Variant writing. The native
# stock INSERT and the literal Ruby rows are the semantic oracle; the Crystal
# helper only reports physical bytes and local-reader observations.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require_relative 'probe_object_shared_json_interop_w241'

module ProbeCompactPartWriterW267
  W241 = ProbeObjectSharedJSONInteropW241
  FORMAT = 'compact_part_writer_w267_native_probe_v1'.freeze
  HELPER_FORMAT = 'compact_part_writer_w267_helper_v1'.freeze
  PART_NAME = 'all_1_1_0'.freeze
  HELPER_SOURCE = File.expand_path('compact_part_writer_w267_helper.cr', __dir__).freeze
  FIXTURE_SOURCE = File.expand_path('../spec/support/compact_part_writer_w267_fixture.cr', __dir__).freeze
  W241_SOURCE = File.expand_path('probe_object_shared_json_interop_w241.rb', __dir__).freeze
  MAX_PART_FILES = 128
  MAX_PART_BYTES = 64 * 1024 * 1024
  ROWS_PER_MARK = 2
  MARK_ROWS = [2, 2, 2, 2, 0].freeze
  KEY_NAME = 'pk'.freeze
  PAYLOAD_TYPE = 'Variant(Array(LowCardinality(String)), String, Tuple(LowCardinality(String), UInt64))'.freeze
  DIRECT_TYPE = 'Variant(Array(UInt8), String, UInt64)'.freeze
  TUPLE_TYPE = 'Tuple(label LowCardinality(String), direct Variant(Array(UInt8), String, UInt64), lists Array(Variant(Array(UInt8), String, UInt64)))'.freeze
  LIST_TYPE = 'Array(Variant(Array(UInt8), String, UInt64))'.freeze
  SCHEMA = [
    ['pk', 'UInt64'], ['payload', PAYLOAD_TYPE], ['ctx', TUPLE_TYPE],
  ].map(&:freeze).freeze
  COLUMN_NAMES = %w[payload ctx].freeze
  WINDOWS = {
    'full' => [0, 4], 'middle' => [1, 2], 'last' => [3, 1], 'empty' => [4, 0],
  }.transform_values(&:freeze).freeze
  WINDOW_PREDICATES = {
    'full' => '1', 'middle' => 'pk BETWEEN 103 AND 106',
    'last' => 'pk >= 107', 'empty' => 'pk > 108',
  }.freeze

  # These rows are independent of the Crystal fixture and never loaded from a
  # helper response. Strings are stored as literal hex so raw NUL/invalid UTF-8
  # bytes survive SQL construction and expected-value comparison.
  ROWS = [
    {pk: 101, payload: [:array, ['610062', 'ff8041']], label: '610062', direct: [:string, '630064'], lists: [[:string, '6c3000']]},
    {pk: 102, payload: [:array, ['ff8041', '']], label: '610062', direct: [:uint64, 7], lists: [[:string, '6c31']]},
    {pk: 103, payload: [:array, ['ff8041', '']], label: '6c32', direct: [:array, [0, 255, 128]], lists: []},
    {pk: 104, payload: [:null, nil], label: '6c33', direct: [:array, [255, 0]], lists: []},
    {pk: 105, payload: [:tuple, ['6e6f727468', 10]], label: '', direct: [:uint64, 18_446_744_073_709_551_615], lists: [[:uint64, 33]]},
    {pk: 106, payload: [:string, '00ff41'], label: '610062', direct: [:string, 'ff8041'], lists: [[:array, [0, 255]]]},
    {pk: 107, payload: [:null, nil], label: '6c7a', direct: [:null, nil], lists: [[:null, nil]]},
    {pk: 108, payload: [:null, nil], label: '6c7a', direct: [:null, nil], lists: [[:null, nil]]},
  ].map(&:freeze).freeze

  # Exact local public-reader signatures, written independently from the
  # fixture constructor and the callback encoder.
  LOCAL_SIGNATURES = {
    'payload' => [
      'V0:[S:610062,S:ff8041]', 'V0:[S:ff8041,S:]', 'V0:[S:ff8041,S:]', 'VNULL',
      'V2:(S:6e6f727468,U:10)', 'V1:S:00ff41', 'VNULL', 'VNULL',
    ].freeze,
    'ctx' => [
      '(S:610062,V1:S:630064,[V1:S:6c3000])',
      '(S:610062,V2:U:7,[V1:S:6c31])',
      '(S:6c32,V0:[B:0,B:255,B:128],[])',
      '(S:6c33,V0:[B:255,B:0],[])',
      '(S:,V2:U:18446744073709551615,[V2:U:33])',
      '(S:610062,V1:S:ff8041,[V0:[B:0,B:255]])',
      '(S:6c7a,VNULL,[VNULL])', '(S:6c7a,VNULL,[VNULL])',
    ].freeze,
  }.freeze

  SLOT_ROSTER_MRK4 = [
    ['pk', 'pk'],
    ['payload', 'payload.variant_discr_prefix'],
    ['payload', 'payload.Array%28LowCardinality%28String%29%29.dict_prefix'],
    ['payload', 'payload.Tuple%28LowCardinality%28String%29%2C%20UInt64%29%2E1.dict_prefix'],
    ['payload', 'payload.variant_discr'],
    ['payload', 'payload.Array%28LowCardinality%28String%29%29.size0'],
    ['payload', 'payload.Array%28LowCardinality%28String%29%29.dict'],
    ['payload', 'payload.Array%28LowCardinality%28String%29%29'],
    ['payload', 'payload.String'],
    ['payload', 'payload.Tuple%28LowCardinality%28String%29%2C%20UInt64%29%2E1.dict'],
    ['payload', 'payload.Tuple%28LowCardinality%28String%29%2C%20UInt64%29%2E1'],
    ['payload', 'payload.Tuple%28LowCardinality%28String%29%2C%20UInt64%29%2E2'],
    ['ctx', 'ctx%2Elabel.dict_prefix'],
    ['ctx', 'ctx%2Edirect.variant_discr_prefix'],
    ['ctx', 'ctx%2Elists.variant_discr_prefix'],
    ['ctx', 'ctx%2Elabel.dict'], ['ctx', 'ctx%2Elabel'],
    ['ctx', 'ctx%2Edirect.variant_discr'],
    ['ctx', 'ctx%2Edirect.Array%28UInt8%29.size0'], ['ctx', 'ctx%2Edirect.Array%28UInt8%29'],
    ['ctx', 'ctx%2Edirect.String'], ['ctx', 'ctx%2Edirect.UInt64'],
    ['ctx', 'ctx%2Elists.size0'],
    ['ctx', 'ctx%2Elists.variant_discr'], ['ctx', 'ctx%2Elists.Array%28UInt8%29.size1'],
    ['ctx', 'ctx%2Elists.Array%28UInt8%29'], ['ctx', 'ctx%2Elists.String'],
    ['ctx', 'ctx%2Elists.UInt64'],
  ].map(&:freeze).freeze
  SLOT_ROSTER_MRK3 = SCHEMA.map { |name, _type| [name, nil].freeze }.freeze

  VARIANT_EXPECTED = [
    {
      column: 'payload', prefix: 'payload.variant_discr_prefix', body: 'payload.variant_discr',
      basic: ['0000', '00ff', '0201', 'ffff'], compact: ['020100', '020000ff', '02000201', '0201ff'],
    }.freeze,
    {
      column: 'ctx', prefix: 'ctx%2Edirect.variant_discr_prefix', body: 'ctx%2Edirect.variant_discr',
      basic: ['0102', '0000', '0201', 'ffff'], compact: ['02000102', '020100', '02000201', '0201ff'],
    }.freeze,
    {
      column: 'ctx', prefix: 'ctx%2Elists.variant_discr_prefix', body: 'ctx%2Elists.variant_discr',
      basic: ['0101', '', '0200', 'ffff'], compact: ['020101', '', '02000200', '0201ff'],
    }.freeze,
  ].freeze

  # Per-granule AdditionalKeysOnly expectations: ClickHouse reserves empty
  # String at dictionary index 0, then assigns keys in first-seen order. There
  # is no part-global union. Each key is the raw String hex.
  LC_EXPECTED = [
    {
      prefix: 'payload.Array%28LowCardinality%28String%29%29.dict_prefix',
      marks: [
        {keys: ['', '610062', 'ff8041'], indexes: [1, 2, 2, 0]},
        {keys: ['', 'ff8041'], indexes: [1, 0]},
        {keys: [], indexes: []}, {keys: [], indexes: []},
      ],
    }.freeze,
    {
      prefix: 'payload.Tuple%28LowCardinality%28String%29%2C%20UInt64%29%2E1.dict_prefix',
      marks: [
        {keys: [], indexes: []}, {keys: [], indexes: []},
        {keys: ['', '6e6f727468'], indexes: [1]}, {keys: [], indexes: []},
      ],
    }.freeze,
    {
      prefix: 'ctx%2Elabel.dict_prefix',
      marks: [
        {keys: ['', '610062'], indexes: [1, 1]},
        {keys: ['', '6c32', '6c33'], indexes: [1, 2]},
        {keys: ['', '610062'], indexes: [0, 1]},
        {keys: ['', '6c7a'], indexes: [1, 1]},
      ],
    }.freeze,
  ].freeze

  class Failure < StandardError; end

  class Probe
    def initialize(binary:, helper:, evidence_root:)
      @binary = validate_executable(binary, 'pinned ClickHouse')
      @helper = validate_executable(helper, 'prebuilt W267 helper')
      @root = validate_root(evidence_root)
      @runner = W241::Probe.new(@binary, @helper, @root)
      @invocations = @runner.instance_variable_get(:@invocations)
      @token = Digest::SHA256.hexdigest(@root)[0, 8]
      @source_files = [__FILE__, HELPER_SOURCE, FIXTURE_SOURCE, W241_SOURCE].map { |path| File.realpath(path) }.uniq.sort
      @tables = {}
    end

    def run
      prepare!
      stock = %w[basic compact].to_h { |mode| [mode, capture_stock!(mode)] }
      generated = {}
      %w[basic compact].each do |variant_mode|
        %w[mrk3 mrk4].each do |mark_format|
          key = "#{variant_mode}_#{mark_format}"
          generated[key] = qualify_generated!(variant_mode, mark_format)
        end
      end
      compare_mark_format_twins!(generated)
      poison = qualify_poison!(generated.fetch('compact_mrk4').fetch(:part_path))
      verify_pins!
      summary = {
        format: FORMAT, status: 'stock_basic_compact_and_generated_four_cell_matrix_observed',
        runtime: {path: @binary, sha256: W241::BINARY_SHA256, version: W241::VERSION, build: W241::BUILD,
                  sha256_before: @binary_sha_before, sha256_after: binary_sha},
        schema: SCHEMA, fixture: ROWS.map { |row| public_row(row) }, mark_rows: MARK_ROWS,
        stock_native_mrk4: stock, generated_matrix: generated, poisoned_middle_prefix: poison,
        source_hashes: @source_hashes_before, invocations: @invocations, evidence_root: @root,
        claim_boundary: 'Two native stock MRK4 modes and four generated MRK3/MRK4 by BASIC/COMPACT cells were independently attached/read. Native CHECK and literal SELECT outcomes are recorded separately. The copy-only poison changes one discriminator-prefix byte and reseals data checksums; native poison outcomes are observations, not assumed rejection.',
      }
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      write_new(File.join(@root, 'summary.md'), render_summary(summary))
      puts "W267 status=#{summary.fetch(:status)}; rows=8; marks=4+EOF; variants=3-sites; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      persist_inconclusive(error)
      warn "W267 Compact Variant probe inconclusive: #{@fatal_error}"
      false
    end

    private

    def fail!(message)
      raise Failure, "W267: #{message}"
    end

    def validate_root(path)
      fail!('evidence root must already exist, be an empty direct child of /private/tmp') unless path && File.directory?(File.expand_path(path)) && !File.symlink?(File.expand_path(path))
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
      %w[invocations stores parts].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      @binary_sha_before = binary_sha
      @helper_sha_before = helper_sha
      fail!('ClickHouse binary differs from the W241 runtime pin') unless @binary_sha_before == W241::BINARY_SHA256
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
      output = result[:stdout].dup.force_encoding(Encoding::UTF_8)
      fail!("#{label} output is not UTF-8/newline-terminated") unless output.valid_encoding? && output.end_with?("\n")
      output.lines.map(&:chomp)
    end

    def settings(mark_layout, variant_mode)
      mode_value = variant_mode == 'compact' ? 1 : 0
      [
        'index_granularity=2', 'index_granularity_bytes=10485760', 'enable_mixed_granularity_parts=1',
        'min_rows_for_wide_part=1000000', 'min_bytes_for_wide_part=104857600', 'min_level_for_wide_part=0',
        'compress_marks=0', 'compress_primary_key=0', "write_marks_for_substreams_in_compact_parts=#{mark_layout}",
        'min_compress_block_size=0', 'max_compress_block_size=4096',
        'ratio_of_defaults_for_sparse_serialization=1.0', "default_compression_codec='LZ4'",
        "serialization_info_version='with_types'", 'propagate_types_serialization_versions_to_nested_types=true',
        "string_serialization_version='single_stream'", "nullable_serialization_version='basic'",
        "use_compact_variant_discriminators_serialization=#{mode_value}",
        'allow_suspicious_low_cardinality_types=1',
      ].join(', ')
    end

    def declarations
      SCHEMA.map { |name, type| "`#{name}` #{type}" }.join(', ')
    end

    def table_name(case_name)
      "w267_#{@token}_#{case_name}"
    end

    def store_path(case_name)
      path = File.join(@root, 'stores', case_name)
      Dir.mkdir(path, 0o700) unless Dir.exist?(path)
      path
    end

    def tag(kind, case_name, window = nil)
      suffix = case_name.upcase
      suffix += "_#{window.upcase}" if window
      "__W267_#{kind.to_s.upcase}_#{suffix}__"
    end

    def sql_string_hex(hex)
      "CAST(unhex('#{hex}'), 'String')"
    end

    def sql_lc_string_hex(hex)
      "CAST(unhex('#{hex}'), 'LowCardinality(String)')"
    end

    def sql_uint8_array(values)
      body = values.map { |value| "toUInt8(#{value})" }.join(', ')
      "CAST([#{body}], 'Array(UInt8)')"
    end

    def sql_payload(value)
      case value.fetch(0)
      when :array
        items = value.fetch(1).map { |hex| sql_lc_string_hex(hex) }.join(', ')
        array = "CAST([#{items}], 'Array(LowCardinality(String))')"
        "CAST(#{array}, '#{PAYLOAD_TYPE}')"
      when :string
        "CAST(#{sql_string_hex(value.fetch(1))}, '#{PAYLOAD_TYPE}')"
      when :tuple
        label_hex, number = value.fetch(1)
        tuple = "CAST(tuple(#{sql_lc_string_hex(label_hex)}, toUInt64(#{number})), 'Tuple(LowCardinality(String), UInt64)')"
        "CAST(#{tuple}, '#{PAYLOAD_TYPE}')"
      when :null
        "CAST(NULL, '#{PAYLOAD_TYPE}')"
      else
        fail!("unknown payload arm #{value.inspect}")
      end
    end

    def sql_direct(value)
      case value.fetch(0)
      when :array then "CAST(#{sql_uint8_array(value.fetch(1))}, '#{DIRECT_TYPE}')"
      when :string then "CAST(#{sql_string_hex(value.fetch(1))}, '#{DIRECT_TYPE}')"
      when :uint64 then "CAST(toUInt64(#{value.fetch(1)}), '#{DIRECT_TYPE}')"
      when :null then "CAST(NULL, '#{DIRECT_TYPE}')"
      else fail!("unknown direct Variant arm #{value.inspect}")
      end
    end

    def sql_list_item(value)
      case value.fetch(0)
      when :array then "CAST(#{sql_uint8_array(value.fetch(1))}, '#{DIRECT_TYPE}')"
      when :string then "CAST(#{sql_string_hex(value.fetch(1))}, '#{DIRECT_TYPE}')"
      when :uint64 then "CAST(toUInt64(#{value.fetch(1)}), '#{DIRECT_TYPE}')"
      when :null then "CAST(NULL, '#{DIRECT_TYPE}')"
      else fail!("unknown list Variant arm #{value.inspect}")
      end
    end

    def sql_context(row)
      values = row.fetch(:lists).map { |value| sql_list_item(value) }.join(', ')
      lists = "CAST([#{values}], '#{LIST_TYPE}')"
      tuple = "tuple(#{sql_lc_string_hex(row.fetch(:label))}, #{sql_direct(row.fetch(:direct))}, #{lists})"
      "CAST(#{tuple}, '#{TUPLE_TYPE}')"
    end

    def insert_sql(table)
      rows = ROWS.map { |row| "(toUInt64(#{row.fetch(:pk)}), #{sql_payload(row.fetch(:payload))}, #{sql_context(row)})" }
      "INSERT INTO default.#{table} VALUES\n#{rows.join(",\n")};\n"
    end

    def type_signature_sql(expression, type_name)
      "variantType(#{expression}) = '#{type_name}'"
    end

    def payload_signature_sql
      array_arm = 'Array(LowCardinality(String))'
      tuple_arm = 'Tuple(LowCardinality(String), UInt64)'
      array_value = "concat('A:', lower(hex(toJSONString(arrayMap(x -> lower(hex(x)), variantElement(payload, '#{array_arm}'))))))"
      string_value = "concat('S:', lower(hex(variantElement(payload, 'String'))))"
      tuple_value = "concat('T:', lower(hex(tupleElement(variantElement(payload, '#{tuple_arm}'), 1))), ':', toString(tupleElement(variantElement(payload, '#{tuple_arm}'), 2)))"
      "multiIf(#{type_signature_sql('payload', array_arm)}, #{array_value}, #{type_signature_sql('payload', 'String')}, #{string_value}, #{type_signature_sql('payload', tuple_arm)}, #{tuple_value}, 'N')"
    end

    def direct_signature_sql(expression)
      array_value = "concat('A:', lower(hex(toJSONString(variantElement(#{expression}, 'Array(UInt8)')))))"
      string_value = "concat('S:', lower(hex(variantElement(#{expression}, 'String'))))"
      uint_value = "concat('U:', toString(variantElement(#{expression}, 'UInt64')))"
      "multiIf(#{type_signature_sql(expression, 'Array(UInt8)')}, #{array_value}, #{type_signature_sql(expression, 'String')}, #{string_value}, #{type_signature_sql(expression, 'UInt64')}, #{uint_value}, 'N')"
    end

    def list_signatures_sql
      expression = "tupleElement(ctx, 'lists')"
      item = "multiIf(variantType(x) = 'Array(UInt8)', concat('A:', lower(hex(toJSONString(variantElement(x, 'Array(UInt8)'))))), variantType(x) = 'String', concat('S:', lower(hex(variantElement(x, 'String')))), variantType(x) = 'UInt64', concat('U:', toString(variantElement(x, 'UInt64'))), 'N')"
      "lower(hex(toJSONString(arrayMap(x -> #{item}, #{expression}))))"
    end

    def native_window_sql(case_name, window, table)
      marker = tag('native', case_name, window)
      predicate = WINDOW_PREDICATES.fetch(window)
      if window == 'empty'
        return "SELECT '#{marker}', toString(count()) FROM default.#{table} WHERE #{predicate} FORMAT TSVRaw;\n"
      end
      "SELECT '#{marker}', toString(pk), variantType(payload), #{payload_signature_sql}, " \
        "lower(hex(tupleElement(ctx, 'label'))), variantType(tupleElement(ctx, 'direct')), " \
        "#{direct_signature_sql("tupleElement(ctx, 'direct')")}, #{list_signatures_sql} " \
        "FROM default.#{table} WHERE #{predicate} ORDER BY pk FORMAT TSVRaw;\n"
    end

    def tagged(lines, marker, width)
      lines.select { |line| line.start_with?(marker + "\t") }.map do |line|
        fields = line.split("\t", -1)
        fail!("malformed tagged output for #{marker}") unless fields.size == width
        fields
      end
    end

    def public_row(row)
      {pk: row.fetch(:pk), payload: row.fetch(:payload), label_hex: row.fetch(:label), direct: row.fetch(:direct), lists: row.fetch(:lists)}
    end

    def payload_type(row)
      case row.fetch(:payload).fetch(0)
      when :array then 'Array(LowCardinality(String))'
      when :string then 'String'
      when :tuple then 'Tuple(LowCardinality(String), UInt64)'
      when :null then 'None'
      end
    end

    def direct_type(row)
      case row.fetch(:direct).fetch(0)
      when :array then 'Array(UInt8)'
      when :string then 'String'
      when :uint64 then 'UInt64'
      when :null then 'None'
      end
    end

    def payload_expected(row)
      kind, value = row.fetch(:payload)
      case kind
      when :array then "A:#{JSON.generate(value).unpack1('H*')}"
      when :string then "S:#{value}"
      when :tuple then "T:#{value.fetch(0)}:#{value.fetch(1)}"
      when :null then 'N'
      end
    end

    def direct_expected(row)
      kind, value = row.fetch(:direct)
      case kind
      when :array then "A:#{JSON.generate(value).unpack1('H*')}"
      when :string then "S:#{value}"
      when :uint64 then "U:#{value}"
      when :null then 'N'
      end
    end

    def lists_expected(row)
      entries = row.fetch(:lists).map do |kind, value|
        case kind
        when :array then "A:#{JSON.generate(value).unpack1('H*')}"
        when :string then "S:#{value}"
        when :uint64 then "U:#{value}"
        when :null then 'N'
        end
      end
      JSON.generate(entries).unpack1('H*')
    end

    def expected_native_row(row)
      [row.fetch(:pk).to_s, payload_type(row), payload_expected(row), row.fetch(:label),
       direct_type(row), direct_expected(row), lists_expected(row)]
    end

    def parse_native_windows(lines, case_name, strict:, only: nil)
      observed = {}
      (only || WINDOWS.keys).each do |window|
        marker = tag('native', case_name, window)
        if window == 'empty'
          rows = tagged(lines, marker, 2)
          exact = rows == [[marker, '0']]
          fail!("#{case_name} native empty SELECT differs") if strict && !exact
          observed[window] = strict ? [] : {state: exact ? 'exact_values' : 'value_mismatch', rows: rows.map(&:last)}
          next
        end
        rows = tagged(lines, marker, 8).map { |fields| fields.drop(1) }
        selection = ROWS_FOR_WINDOW.fetch(window).map { |row| expected_native_row(row) }
        exact = rows == selection
        fail!("#{case_name} native #{window} SELECT differs from independent literal rows") if strict && !exact
        observed[window] = strict ? selection : {state: exact ? 'exact_values' : 'value_mismatch', rows: rows}
      end
      observed
    end

    ROWS_FOR_WINDOW = {
      'full' => ROWS,
      'middle' => ROWS[2, 4],
      'last' => ROWS[6, 2],
      'empty' => [],
    }.freeze

    def stock_sql(mode, table)
      setup = "CREATE TABLE default.#{table} (#{declarations}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings(1, mode)};\n"
      setup + insert_sql(table)
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

    def check_observation!(case_name, table, store, strict:)
      result = native("#{case_name}_check", check_sql(case_name, table), store)
      record = {state: result.fetch(:classification), invocation: result.fetch(:record)}
      if result.fetch(:classification) == 'success'
        lines = native_lines(result, "#{case_name} CHECK")
        first = lines.index(tag('check_begin', case_name))
        last = lines.index(tag('check_end', case_name))
        rows = first && last && last > first ? lines[(first + 1)...last] : nil
        record[:rows] = rows
        record[:exact_success] = rows == ["#{PART_NAME}\t1\t"]
      end
      if strict
        fail!("#{case_name} native CHECK refused") unless record[:state] == 'success'
        fail!("#{case_name} native CHECK did not report exactly one healthy part") unless record[:exact_success]
      end
      record
    end

    def native_selects!(case_name, table, store, strict:)
      WINDOWS.keys.to_h do |window|
        result = native("#{case_name}_select_#{window}", native_window_sql(case_name, window, table), store)
        if result.fetch(:classification) != 'success'
          fail!("#{case_name} native #{window} SELECT refused") if strict
          next [window, {state: result.fetch(:classification), invocation: result.fetch(:record)}]
        end
        begin
          rows = parse_native_windows(native_lines(result, "#{case_name} #{window} SELECT"), case_name,
                                      strict: strict, only: [window]).fetch(window)
          observation = strict ? {state: 'exact_values', rows: window == 'empty' ? 0 : rows.size} : rows
          [window, observation.merge(invocation: result.fetch(:record))]
        rescue StandardError => error
          raise if strict
          [window, {state: 'oracle_parse_error', detail: "#{error.class}: #{error.message}", invocation: result.fetch(:record)}]
        end
      end
    end

    def safe_native_path(path, store)
      real = File.realpath(path)
      root = File.realpath(store)
      fail!("native path escaped isolated store: #{path}") unless real.start_with?(root + File::SEPARATOR)
      fail!('native part path is not a directory') unless File.directory?(real) && !File.symlink?(path)
      real
    end

    def native_part!(case_name, table, store)
      result = native("#{case_name}_schema_and_part", part_sql(case_name, table), store)
      fail!("#{case_name} schema/part query refused") unless result.fetch(:classification) == 'success'
      lines = native_lines(result, "#{case_name} schema/part")
      schemas = tagged(lines, tag('schema', case_name), 3).map { |fields| fields.drop(1) }
      fail!("#{case_name} native schema differs") unless schemas == SCHEMA
      parts = tagged(lines, tag('part', case_name), 7)
      fail!("#{case_name} native part is not one 8-row/four-real-mark Compact part") unless
        parts.size == 1 && parts.first.values_at(1, 2, 4, 5, 6) == [table, PART_NAME, 'Compact', '8', '5']
      safe_native_path(parts.first[3], store)
    end

    def capture_stock!(mode)
      case_name = "stock_#{mode}"
      store = store_path(case_name)
      table = table_name(case_name)
      insert = native("#{case_name}_create_insert", stock_sql(mode, table), store)
      fail!("#{case_name} stock CREATE/INSERT refused") unless insert.fetch(:classification) == 'success'
      part = native_part!(case_name, table, store)
      inventory = tree_inventory(part)
      check = check_observation!(case_name, table, store, strict: true)
      selects = native_selects!(case_name, table, store, strict: true)
      report = helper("#{case_name}_physical_audit", 'audit', part)
      local = validate_report!(report, 'mrk4', case_name, inventory, variant_mode: mode)
      {mode: mode, table: table, store: store, part_path: part, insert: insert.fetch(:record),
       inventory: inventory, check: check, selects: selects, physical_and_local_audit: local}
    end

    def helper(label, *arguments, expected_statuses: ['ok'])
      result = @runner.send(:run_process, label, [@helper] + arguments, ''.b, 'crystal-helper',
                            expected_sha: @helper_sha_before, binary_path: @helper)
      record = result.fetch(:record)
      fail!("#{label} helper failed or exceeded bounds: #{record.inspect}") unless
        !record[:timed_out] && record[:spawn_error].nil? && record[:stdin_write_error].nil? &&
        record[:stdout_read_error].nil? && record[:stderr_read_error].nil? && result[:status] &&
        result[:status].termsig.nil? && result[:classification] == 'success' && result[:status].success? && result[:stderr].empty?
      report = JSON.parse(result[:stdout].dup.force_encoding(Encoding::UTF_8))
      fail!("#{label} helper envelope differs") unless report.is_a?(Hash) && report['format'] == HELPER_FORMAT &&
        report['action'] == arguments.first && expected_statuses.include?(report['status'])
      report
    rescue JSON::ParserError => error
      raise Failure, "W267: #{label} helper output is not JSON: #{error.message}"
    end

    def tree_inventory(path)
      entries = []
      total = 0
      Find.find(path) do |entry|
        next if entry == path
        stat = File.lstat(entry)
        fail!("symlink in part: #{entry}") if stat.symlink?
        next if stat.directory?
        fail!("non-regular part entry: #{entry}") unless stat.file?
        total += stat.size
        fail!('native part file-count bound exceeded') if entries.size >= MAX_PART_FILES
        fail!('native part byte bound exceeded') if total > MAX_PART_BYTES
        entries << {path: entry.delete_prefix(path + File::SEPARATOR), size: stat.size,
                    sha256: Digest::SHA256.file(entry).hexdigest}
      end
      {files: entries.sort_by { |item| item.fetch(:path) }, total_bytes: total}
    end

    def validate_mark_tape!(report, mode, label, inventory)
      tape = report.fetch('physical_mark_tape')
      roster = mode == 'mrk4' ? SLOT_ROSTER_MRK4 : SLOT_ROSTER_MRK3
      filename = mode == 'mrk4' ? 'data.mrk4' : 'data.mrk3'
      width = roster.size * 16 + 8
      fail!("#{label} mark tape dimensions differ") unless tape.fetch('file') == filename &&
        tape.fetch('slot_count') == roster.size && tape.fetch('record_width') == width &&
        tape.fetch('byte_size') == width * 5 && tape.fetch('records').size == 5 &&
        tape.fetch('real_mark_rows') == [2, 2, 2, 2]
      records = tape.fetch('records')
      fail!("#{label} physical row-count records differ") unless records.map { |record| record.fetch('row_count') } == MARK_ROWS
      raw_size = tape.fetch('raw_size')
      compressed_size = tape.fetch('compressed_size')
      fail!("#{label} raw frame census is empty or oversized") unless raw_size.positive? && raw_size <= MAX_PART_BYTES
      data_entry = inventory.fetch(:files).find { |entry| entry.fetch(:path) == 'data.bin' }
      fail!("#{label} data.bin compressed EOF differs from raw marks") unless data_entry && data_entry.fetch(:size) == compressed_size
      records.each_with_index do |record, mark|
        pairs = record.fetch('pairs')
        fail!("#{label} mark #{mark} slot count differs") unless pairs.size == roster.size
        positions = pairs.map { |pair| pair.fetch('logical_position') }
        fail!("#{label} mark #{mark} logical positions leave raw data bounds") unless positions.all? { |position| position >= 0 && position <= raw_size }
      end
      eof = records.last.fetch('pairs')
      fail!("#{label} terminal record is not all-slot physical EOF") unless eof.all? do |pair|
        pair.fetch('compressed_offset') == compressed_size && pair.fetch('decompressed_offset').zero? && pair.fetch('logical_position') == raw_size
      end
      data_hex = report.fetch('raw_data_hex')
      fail!("#{label} raw data hex does not match independent frame census size") unless data_hex.is_a?(String) && data_hex.match?(/\A(?:[0-9a-f]{2})*\z/) && data_hex.bytesize == raw_size * 2
      true
    end

    def validate_shards!(report, mode, label)
      shards = report.fetch('callback_shards')
      fail!("#{label} physical shard roster is empty") if shards.empty?
      shards.each do |shard|
        bytes_hex = shard.fetch('bytes_hex')
        fail!("#{label} shard has malformed hex or byte count") unless bytes_hex.match?(/\A(?:[0-9a-f]{2})*\z/) && bytes_hex.bytesize == shard.fetch('byte_count') * 2
        fail!("#{label} shard logical range differs from byte count") unless shard.fetch('logical_end') - shard.fetch('logical_start') == shard.fetch('byte_count')
        if mode == 'mrk4'
          expected = SLOT_ROSTER_MRK4.fetch(shard.fetch('slot'))
          fail!("#{label} shard slot mapping differs") unless [shard.fetch('column'), shard.fetch('stream')] == expected
        else
          expected = SLOT_ROSTER_MRK3.fetch(shard.fetch('slot'))
          fail!("#{label} MRK3 shard slot mapping differs") unless [shard.fetch('column'), shard.fetch('stream')] == expected
        end
      end
      true
    end

    def validate_variant_sites!(report, variant_mode, label)
      sites = report.fetch('variant_sites')
      fail!("#{label} three recursive Variant sites are not audited") unless sites.size == VARIANT_EXPECTED.size
      prefix_value = variant_mode == 'compact' ? 1 : 0
      sites.zip(VARIANT_EXPECTED).each do |site, expected|
        fail!("#{label} Variant callback names differ") unless
          site.fetch('column') == expected.fetch(:column) && site.fetch('prefix_stream') == expected.fetch(:prefix) && site.fetch('body_stream') == expected.fetch(:body)
        expected_bodies = expected.fetch(variant_mode.to_sym)
        marks = site.fetch('marks')
        fail!("#{label} Variant site does not have four real marks") unless marks.size == 4
        marks.each_with_index do |mark, index|
          expected_prefix = [prefix_value].pack('Q<').unpack1('H*')
          fail!("#{label} Variant mark #{index} prefix/body differs from literal frame") unless
            mark.fetch('mark') == index && mark.fetch('prefix_value') == prefix_value &&
            mark.fetch('prefix_hex') == expected_prefix && mark.fetch('body_hex') == expected_bodies.fetch(index)
        end
      end
      true
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

    def decode_lc_body(hex, label)
      fail!("#{label} index body is malformed hex") unless hex.is_a?(String) && hex.match?(/\A(?:[0-9a-f]{2})*\z/)
      bytes = [hex].pack('H*').b
      return {flags: nil, keys: [], indexes: []} if bytes.empty?
      fail!("#{label} body is shorter than flags") if bytes.bytesize < 24
      flags = read_u64_le(bytes, 0, label)
      fail!("#{label} lacks ADDITIONAL+UPDATE or has GLOBAL flags") unless (flags & 0x100).zero? && (flags & 0x600) == 0x600 && (flags & ~0x7ff).zero?
      width = {0 => 1, 1 => 2, 2 => 4, 3 => 8}[flags & 0xff]
      fail!("#{label} has invalid LowCardinality index width") unless width
      cursor = 8
      key_count = read_u64_le(bytes, cursor, label)
      cursor += 8
      fail!("#{label} key count exceeds fixture bound") if key_count > 4096
      keys = Array.new(key_count) do |index|
        length, cursor = read_var_uint(bytes, cursor, "#{label} key #{index} length")
        fail!("#{label} key #{index} exceeds body") if length > bytes.bytesize - cursor
        key = bytes.byteslice(cursor, length).unpack1('H*')
        cursor += length
        key
      end
      rows = read_u64_le(bytes, cursor, label)
      cursor += 8
      fail!("#{label} index row count exceeds fixture bound") if rows > 64 || rows * width > bytes.bytesize - cursor
      indexes = Array.new(rows) do
        index = bytes.byteslice(cursor, width).unpack1({1 => 'C', 2 => 'v', 4 => 'V', 8 => 'Q<'}.fetch(width))
        cursor += width
        fail!("#{label} index #{index} exceeds dictionary size") if index >= key_count
        index
      end
      fail!("#{label} body has trailing bytes") unless cursor == bytes.bytesize
      {flags: flags, keys: keys, indexes: indexes}
    end

    def validate_lc_sites!(report, label)
      sites = report.fetch('low_cardinality_sites')
      fail!("#{label} does not expose three recursive LC callback sites") unless sites.size == LC_EXPECTED.size
      sites.zip(LC_EXPECTED).each do |site, expected|
        fail!("#{label} LowCardinality callback name differs") unless site.fetch('prefix_stream') == expected.fetch(:prefix)
        marks = site.fetch('marks')
        fail!("#{label} LowCardinality callback is not present in all four marks") unless marks.size == 4
        marks.each_with_index do |mark, index|
          want = expected.fetch(:marks).fetch(index)
          fail!("#{label} LC prefix/dictionary reset differs at mark #{index}") unless
            mark.fetch('mark') == index && mark.fetch('prefix_version') == 1 &&
            mark.fetch('prefix_hex') == '0100000000000000' && mark.fetch('dictionary_hex') == ''
          decoded = decode_lc_body(mark.fetch('index_hex'), "#{label} #{expected.fetch(:prefix)} mark #{index}")
          fail!("#{label} LC per-mark keys/indexes differ at mark #{index}") unless
            decoded.fetch(:keys) == want.fetch(:keys) && decoded.fetch(:indexes) == want.fetch(:indexes)
          next if decoded.fetch(:flags).nil?
          fail!("#{label} LC flags differ at mark #{index}") unless mark.fetch('flags') == decoded.fetch(:flags)
        end
      end
      true
    end

    def validate_local_windows!(report, label)
      windows = report.fetch('windows')
      WINDOWS.each do |name, (first, count)|
        actual = windows.fetch(name)
        expected_rows = ROWS_FOR_WINDOW.fetch(name)
        fail!("#{label} #{name} local column roster differs") unless actual.keys.sort == %w[ctx payload pk]
        expected_keys = expected_rows.map { |row| row.fetch(:pk).to_s }
        fail!("#{label} #{name} local keys differ") unless actual.fetch('pk') == expected_keys
        %w[payload ctx].each do |column|
          expected = expected_rows.map.with_index { |row, index| LOCAL_SIGNATURES.fetch(column).fetch(first * ROWS_PER_MARK + index) }
          fail!("#{label} #{name} local #{column} values differ from independent signatures") unless actual.fetch(column) == expected
        end
        fail!("#{label} #{name} local selection does not match exact row window") unless count * ROWS_PER_MARK == expected_rows.size
      end
      true
    end

    def validate_report!(report, mode, label, inventory, variant_mode:)
      fail!("#{label} helper status differs") unless report.fetch('status') == 'ok'
      fail!("#{label} part dimensions differ") unless report.fetch('row_count') == 8 && report.fetch('granule_count') == 4 && report.fetch('mark_rows') == [2, 2, 2, 2]
      expected_roster = mode == 'mrk4' ? SLOT_ROSTER_MRK4 : SLOT_ROSTER_MRK3
      observed_roster = report.fetch('physical_roster').map { |slot| [slot.fetch('column'), slot['stream']] }
      fail!("#{label} callback roster differs from pinned native path literals") unless observed_roster == expected_roster
      validate_mark_tape!(report, mode, label, inventory)
      validate_shards!(report, mode, label)
      validate_local_windows!(report, label)
      if mode == 'mrk4'
        validate_variant_sites!(report, variant_mode, label)
        validate_lc_sites!(report, label)
      else
        fail!("#{label} MRK3 unexpectedly exposes substream callbacks") unless report.fetch('variant_sites').empty? && report.fetch('low_cardinality_sites').empty?
      end
      {report: report, inventory: inventory}
    end

    def create_native_target!(case_name, mark_layout, variant_mode)
      store = store_path(case_name)
      table = table_name(case_name)
      sql = "CREATE TABLE default.#{table} (#{declarations}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings(mark_layout, variant_mode)};\n" \
        "SELECT '#{tag('path', case_name)}', arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw;\n"
      result = native("#{case_name}_create_target", sql, store)
      fail!("#{case_name} native target CREATE refused") unless result.fetch(:classification) == 'success'
      rows = tagged(native_lines(result, "#{case_name} CREATE"), tag('path', case_name), 2)
      fail!("#{case_name} native target path is not unique") unless rows.size == 1 && !rows.first[1].empty?
      data_path = safe_native_path(rows.first[1], store)
      {table: table, store: store, data_path: data_path, create: result.fetch(:record)}
    end

    def attach_part!(case_name, source, target)
      before = tree_inventory(source)
      @runner.send(:attach_part!, source, target.fetch(:data_path))
      detached = File.join(target.fetch(:data_path), 'detached', PART_NAME)
      copied = tree_inventory(detached)
      fail!("#{case_name} detached copy differs from generated source") unless before == copied
      attached = native("#{case_name}_attach", "ALTER TABLE default.#{target.fetch(:table)} ATTACH PART '#{PART_NAME}';\n", target.fetch(:store))
      {state: attached.fetch(:classification), invocation: attached.fetch(:record), source_inventory: before, detached_inventory: copied}
    end

    def active_part!(case_name, target, source_inventory, strict:)
      result = native("#{case_name}_active_schema_part", part_sql(case_name, target.fetch(:table)), target.fetch(:store))
      state = result.fetch(:classification)
      observation = {state: state, invocation: result.fetch(:record)}
      if state != 'success'
        fail!("#{case_name} active schema/part query refused") if strict
        return observation
      end
      lines = native_lines(result, "#{case_name} active schema/part")
      schemas = tagged(lines, tag('schema', case_name), 3).map { |fields| fields.drop(1) }
      parts = tagged(lines, tag('part', case_name), 7)
      exact = parts.size == 1 && parts.first.values_at(1, 2, 4, 5, 6) == [target.fetch(:table), PART_NAME, 'Compact', '8', '5']
      observation[:schema_rows] = schemas
      observation[:part_rows] = parts
      observation[:exact_schema] = schemas == SCHEMA
      observation[:exact_compact_part] = exact
      if exact
        path = safe_native_path(parts.first[3], target.fetch(:store))
        observation[:active_inventory] = tree_inventory(path)
        observation[:payload_matches_detached] = payload_identity(observation[:active_inventory]) == payload_identity(source_inventory)
      end
      if strict
        fail!("#{case_name} active schema differs") unless observation[:exact_schema]
        fail!("#{case_name} attached Compact part identity differs") unless observation[:exact_compact_part] && observation[:payload_matches_detached]
      end
      observation
    rescue StandardError => error
      raise if strict
      {state: 'oracle_parse_error', detail: "#{error.class}: #{error.message}", invocation: result && result[:record]}
    end

    def payload_identity(inventory)
      inventory.fetch(:files).select { |entry| %w[data.bin data.mrk3 data.mrk4].include?(entry.fetch(:path)) }
        .map { |entry| entry.slice(:path, :size, :sha256) }
    end

    def qualify_generated!(variant_mode, mark_format)
      case_name = "generated_#{variant_mode}_#{mark_format}"
      part = File.join(@root, 'parts', case_name, PART_NAME)
      Dir.mkdir(File.dirname(part), 0o700)
      write = helper("#{case_name}_write", 'write-only', part, mark_format, variant_mode)
      fail!("#{case_name} helper wrote wrong format/mode") unless write.fetch('mark_format') == mark_format && write.fetch('variant_discriminator_mode') == variant_mode
      inventory = tree_inventory(part)
      report = helper("#{case_name}_audit", 'audit', part)
      local = validate_report!(report, mark_format, case_name, inventory, variant_mode: variant_mode)
      target = create_native_target!(case_name, mark_format == 'mrk4' ? 1 : 0, variant_mode)
      attach = attach_part!(case_name, part, target)
      fail!("#{case_name} native ATTACH refused") unless attach.fetch(:state) == 'success'
      active = active_part!(case_name, target, inventory, strict: true)
      check = check_observation!(case_name, target.fetch(:table), target.fetch(:store), strict: true)
      selects = native_selects!(case_name, target.fetch(:table), target.fetch(:store), strict: true)
      final_inventory = tree_inventory(part)
      fail!("#{case_name} generated source changed after native attach/read") unless final_inventory == inventory
      {variant_mode: variant_mode, mark_format: mark_format, part_path: part, write: write,
       local: local, inventory: inventory, native_target: target, attach: attach,
       active_schema_part: active, check: check, selects: selects}
    end

    def shards_by_mark_column(report)
      report.fetch('callback_shards').group_by { |shard| [shard.fetch('column'), shard.fetch('mark')] }.transform_values do |shards|
        shards.sort_by { |shard| shard.fetch('logical_start') }.map { |shard| shard.fetch('bytes_hex') }.join
      end
    end

    def compare_mark_format_twins!(generated)
      %w[basic compact].each do |mode|
        mrk3 = generated.fetch("#{mode}_mrk3").fetch(:local).fetch(:report)
        mrk4 = generated.fetch("#{mode}_mrk4").fetch(:local).fetch(:report)
        fail!("#{mode} MRK3/MRK4 raw data.bin bytes differ") unless mrk3.fetch('raw_data_hex') == mrk4.fetch('raw_data_hex')
        fail!("#{mode} MRK3 granule-column shard bytes differ from corresponding MRK4 callback concatenation") unless
          shards_by_mark_column(mrk3) == shards_by_mark_column(mrk4)
      end
      true
    end

    def validate_poison_copy!(source, mutant, result)
      source_inventory = tree_inventory(source)
      mutant_inventory = tree_inventory(mutant)
      source_map = source_inventory.fetch(:files).to_h { |entry| [entry.fetch(:path), entry] }
      mutant_map = mutant_inventory.fetch(:files).to_h { |entry| [entry.fetch(:path), entry] }
      changed = (source_map.keys | mutant_map.keys).sort.select { |name| source_map[name] != mutant_map[name] }
      fail!('poison copy changed anything except checksums.txt and data.bin') unless changed == %w[checksums.txt data.bin]
      fail!('poison copy changed data or mark physical sizes') unless source_map.fetch('data.bin').fetch(:size) == mutant_map.fetch('data.bin').fetch(:size) &&
        %w[data.mrk3 data.mrk4].all? { |name| source_map[name] == mutant_map[name] }
      fail!('poison helper mutation metadata differs') unless result.fetch('changed_files').sort == changed &&
        result.fetch('poisoned_mark') == 1 && result.fetch('poisoned_column') == 'payload' &&
        result.fetch('prefix_value_before') == 1 && result.fetch('prefix_value_after') == 2 &&
        result.fetch('raw_changed_offsets').size == 1 && result.fetch('frame_count').positive? &&
        result.fetch('compressed_size') == source_map.fetch('data.bin').fetch(:size) &&
        result.fetch('raw_size').positive?
      {changed_files: changed, source_inventory: source_inventory, mutant_inventory: mutant_inventory,
       prefix_logical_offset: result.fetch('prefix_logical_offset'), raw_changed_offsets: result.fetch('raw_changed_offsets')}
    end

    def local_outcome!(label, part, column, first, count)
      helper(label, 'inspect-outcome', part, column, first.to_s, count.to_s,
             expected_statuses: %w[accepted rejected])
    end

    def assert_local_poison_reject!(outcome, label)
      fail!("#{label} did not reject the invalid selected prefix") unless outcome.fetch('status') == 'rejected' &&
        outcome.fetch('error_class') == 'CrystalClick::UnsupportedFormatError' &&
        outcome.fetch('error_message', '').match?(/unsupported Compact Variant discriminator mode/)
    end

    def qualify_poison!(source)
      source_before = tree_inventory(source)
      mutant = File.join(@root, 'parts', 'poison_compact_mrk4', PART_NAME)
      Dir.mkdir(File.dirname(mutant), 0o700)
      mutation = helper('poison_copy_middle_payload_prefix', 'copy-mutant', 'prefix', source, mutant)
      copy_audit = validate_poison_copy!(source, mutant, mutation)
      fail!('prefix poison modified original generated source') unless tree_inventory(source) == source_before

      local_full = local_outcome!('poison_local_payload_full', mutant, 'payload', 0, 4)
      local_middle = local_outcome!('poison_local_payload_middle', mutant, 'payload', 1, 2)
      assert_local_poison_reject!(local_full, 'local full payload read')
      assert_local_poison_reject!(local_middle, 'local middle payload read')
      local_last = local_outcome!('poison_local_payload_late_control', mutant, 'payload', 3, 1)
      local_pk = local_outcome!('poison_local_pk_middle_control', mutant, 'pk', 1, 1)
      fail!('unselected local pk middle-mark control differs') unless local_pk.fetch('status') == 'accepted' &&
        local_pk.fetch('first_mark') == 1 && local_pk.fetch('mark_count') == 1 &&
        local_pk.fetch('row_count') == 2 && local_pk.fetch('key_values') == %w[103 104]
      if local_last.fetch('status') == 'accepted'
        fail!('accepted local late payload control returned wrong literal rows') unless
          local_last.fetch('row_count') == 2 && local_last.fetch('signatures') == LOCAL_SIGNATURES.fetch('payload').last(2)
      end

      case_name = 'poison_compact_mrk4'
      target = create_native_target!(case_name, 1, 'compact')
      attach = attach_part!(case_name, mutant, target)
      active = active_part!(case_name, target, copy_audit.fetch(:mutant_inventory), strict: false) if attach.fetch(:state) == 'success'
      check = check_observation!(case_name, target.fetch(:table), target.fetch(:store), strict: false)
      native = {}
      if attach.fetch(:state) == 'success' && active && active.fetch(:exact_compact_part)
        native = native_selects!(case_name, target.fetch(:table), target.fetch(:store), strict: false)
        fail!('native late-window positive control was not literal exact') unless native.fetch('last').fetch(:state) == 'exact_values'
        fail!('native empty-window positive control was not literal exact') unless native.fetch('empty').fetch(:state) == 'exact_values'
      else
        native = %w[full middle last empty].to_h { |window| [window, {state: 'not_run_no_active_attached_part'}] }
      end
      fail!('poisoned source changed during native trial') unless tree_inventory(source) == source_before
      {copy_audit: copy_audit, local_full_selected: local_full, local_middle_selected: local_middle,
       local_late_window_observation: local_last, local_unselected_pk_control: local_pk,
       native_target: target, native_attach: attach, native_active_part: active, native_check: check,
       native_selects: native}
    end

    def verify_pins!
      fail!('ClickHouse binary SHA changed during capture') unless binary_sha == W241::BINARY_SHA256
      fail!('prebuilt helper SHA changed during capture') unless helper_sha == @helper_sha_before
      @source_hashes_before.each do |path, expected|
        fail!("probe source changed during capture: #{path}") unless sha(path) == expected
      end
    end

    def render_summary(summary)
      <<~MD
        # W267 Compact Variant native probe

        - Status: `#{summary.fetch(:status)}`
        - Runtime: ClickHouse #{summary.fetch(:runtime).fetch(:version)} (pinned SHA256 #{summary.fetch(:runtime).fetch(:sha256)})
        - Fixture: 8 rows, 4 real marks of 2 rows, recursive Variant and LowCardinality sites.
        - Matrix: native stock BASIC/COMPACT MRK4 plus generated BASIC/COMPACT × MRK3/MRK4.
        - Native `CHECK TABLE` and literal window `SELECT`s are recorded separately.
        - The poisoned prefix is a copy-only, one-byte mutation with unchanged data/mark sizes and resealed checksums; native outcomes are observational.
        - Evidence root: `#{summary.fetch(:evidence_root)}`
      MD
    end

    def persist_inconclusive(error)
      path = File.join(@root, 'summary.json')
      return if File.exist?(path)
      summary = {format: FORMAT, status: 'inconclusive', fatal_error: "#{error.class}: #{error.message}",
                 evidence_root: @root, invocations: @invocations}
      write_new(path, JSON.pretty_generate(summary) + "\n")
    rescue StandardError => summary_error
      warn "W267 inconclusive summary persistence failed: #{summary_error.class}: #{summary_error.message}"
    end
  end

  def self.main
    options = {binary: W241::BINARY}
    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby scripts/probe_compact_part_writer_w267.rb --evidence-root EMPTY_DIRECT_CHILD_OF_PRIVATE_TMP --crystal-helper PREBUILT_HELPER [--clickhouse PINNED_CLICKHOUSE]'
      parser.on('--clickhouse PATH', 'Pinned ClickHouse runtime') { |value| options[:binary] = value }
      parser.on('--crystal-helper PATH', 'Prebuilt W267 helper; this driver never compiles it') { |value| options[:helper] = value }
      parser.on('--evidence-root PATH', 'Existing empty direct child of /private/tmp') { |value| options[:evidence_root] = value }
    end.parse!
    abort 'W267: --crystal-helper and --evidence-root are required' unless options[:helper] && options[:evidence_root]
    ok = Probe.new(binary: options[:binary], helper: options[:helper], evidence_root: options[:evidence_root]).run
    exit(ok ? 0 : 1)
  rescue StandardError => error
    warn "W267 runner error: #{error.class}: #{error.message}"
    exit 1
  end
end

if $PROGRAM_NAME == __FILE__
  ProbeCompactPartWriterW267.main
end
