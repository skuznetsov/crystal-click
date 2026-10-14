#!/usr/bin/env ruby
# Stock-first native oracle and bidirectional interop matrix for a broad static
# Binary Bulk island beneath a root JSON value. The Ruby RowBinary corpus and
# value oracle are literal and independent of the Crystal fixture/helper.

require 'digest'
require 'json'
require 'open3'
require 'optparse'
require_relative 'probe_compact_recursive_arrays_w280_matrix'

module ProbeCompactStaticBulkW281Matrix
  W280M = ProbeCompactRecursiveArraysW280Matrix
  W280 = W280M::W280
  W277 = W280M::W277

  FORMAT = 'compact_static_bulk_w281_matrix_v1'.freeze
  HELPER_FORMAT = 'compact_static_bulk_w281_helper_v1'.freeze
  PROBE_SOURCE = File.expand_path(__FILE__).freeze
  HELPER_SOURCE = File.expand_path('compact_static_bulk_w281_helper.cr', __dir__).freeze
  FIXTURE_SOURCE = File.expand_path('../spec/support/compact_part_writer_w281_fixture.cr', __dir__).freeze

  CASE = 'stock_bulk'.freeze
  COLUMN = 'stock_bulk_w281'.freeze
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

  ENUM_TYPE = "Enum8(#{(0...71).map { |n| "'v#{n}' = #{n}" }.join(', ')})".freeze
  ENUM16_TYPE = "Enum16(#{(0...71).map { |n| "'v#{n}' = #{n}" }.join(', ')})".freeze
  FIXED_FIELDS = [
    ['u8', 'UInt8', 1], ['u16', 'UInt16', 2], ['u32', 'UInt32', 4],
    ['u64', 'UInt64', 8], ['u128', 'UInt128', 16], ['u256', 'UInt256', 32],
    ['i8', 'Int8', 1], ['i16', 'Int16', 2], ['i32', 'Int32', 4],
    ['i64', 'Int64', 8], ['i128', 'Int128', 16], ['i256', 'Int256', 32],
    ['f32', 'Float32', 4], ['f64', 'Float64', 8], ['bf16', 'BFloat16', 2],
    ['date', 'Date', 2], ['date32', 'Date32', 4],
    ['datetime', 'DateTime', 4], ['datetime_utc', "DateTime('UTC')", 4],
    ['datetime64', 'DateTime64(3)', 8], ['datetime64_utc', "DateTime64(6, 'UTC')", 8],
    ['time', 'Time', 4], ['time64', 'Time64(3)', 8], ['truth', 'Bool', 1],
    ['enum8', ENUM_TYPE, 1], ['enum16', ENUM16_TYPE, 2],
    ['decimal32', 'Decimal(9, 2)', 4], ['decimal64', 'Decimal(18, 2)', 8],
    ['decimal128', 'Decimal(38, 2)', 16], ['decimal256', 'Decimal(76, 2)', 32],
    ['uuid', 'UUID', 16], ['ipv4', 'IPv4', 4], ['ipv6', 'IPv6', 16],
    ['interval_day', 'IntervalDay', 8], ['fixed4', 'FixedString(4)', 4],
  ].map(&:freeze).freeze
  FIXED_NAMES = FIXED_FIELDS.map(&:first).freeze
  FIXED_TYPES = FIXED_FIELDS.each_with_object({}) do |(name, type, _width), types|
    types[name] = type
  end.freeze

  ROOT_JSON_TYPE = 'JSON(max_dynamic_types=0, max_dynamic_paths=0, id UInt64)'.freeze
  WRAPPER_FIELDS = [
    ['empty_tuple', 'Tuple()'], ['text', 'String'], ['text_runs', 'Array(String)'],
    ['empty_texts', 'Array(String)'], ['maybe_text', 'Nullable(String)'],
    ['maybe_u16', 'Nullable(UInt16)'],
    ['array_pairs', 'Array(Tuple(UInt16, Nullable(String)))'],
    ['lookup', 'Map(String, Nullable(String))'],
    ['nested_labels', 'Nested(label String, maybe_code Nullable(UInt8))'],
    ['plain_tuple', 'Tuple(UInt32, String)'], ['point', 'Point'],
    ['multipoint', 'MultiPoint'], ['maybe_point', 'Nullable(Point)'],
    ['sum_state', 'SimpleAggregateFunction(sum, UInt64)'],
  ].map(&:freeze).freeze
  STOCK_FIELDS = (FIXED_FIELDS.map { |name, type, _width| [name, type] } + WRAPPER_FIELDS).map(&:freeze).freeze
  STOCK_BULK_TYPE = "Tuple(#{STOCK_FIELDS.map { |name, type| "#{name} #{type}" }.join(', ')})".freeze
  STOCK_TYPE = "Tuple(#{ROOT_JSON_TYPE}, #{STOCK_BULK_TYPE})".freeze
  BROAD_FIELDS = (FIXED_FIELDS.map { |name, type, _width| [name, type] } +
                  [['nothing', 'Nothing']] + WRAPPER_FIELDS).map(&:freeze).freeze
  BROAD_BULK_TYPE = "Tuple(#{BROAD_FIELDS.map { |name, type| "#{name} #{type}" }.join(', ')})".freeze
  BROAD_TYPE = "Tuple(#{ROOT_JSON_TYPE}, #{BROAD_BULK_TYPE})".freeze
  SCHEMAS = {CASE => [['pk', 'UInt64'], [COLUMN, STOCK_TYPE]].map(&:freeze).freeze}.freeze

  FieldValue = Struct.new(:name, :kind, :value, keyword_init: true)
  class Failure < StandardError; end

  def self.text_for_row(row)
    case row
    when 0, 4, 5 then ''.b
    when 1 then "nul\0tail".b
    when 2, 7 then [0x00, 0xff, 0x80, 0x41].pack('C*').b
    when 3, 6 then ('long:' + ('x' * 256)).b
    else raise Failure, "unknown independent row #{row}"
    end
  end

  def self.invalid_bytes
    [0x00, 0xff, 0x80, 0x41].pack('C*').b
  end

  def self.long_bytes
    ('long:' + ('x' * 256)).b
  end

  def self.raw_width(value, width)
    bytes = value.to_i.digits(256).map(&:to_i)
    (bytes + Array.new(width, 0)).first(width).pack('C*').b
  end

  # Deliberately repeats the fixture's value schedule as Ruby literals rather
  # than importing or querying the Crystal fixture.
  def self.fixed_payload(name, row)
    index = FIXED_NAMES.index(name) || raise(Failure, "unknown fixed field #{name.inspect}")
    width = FIXED_FIELDS.fetch(index).fetch(2)
    seed = row * 5 + index + 1
    case name
    when 'truth'
      [row.even? ? 1 : 0].pack('C').b
    when 'f32'
      [0x3f80_0000 + seed].pack('L<').b
    when 'f64'
      [0x3ff0_0000_0000_0000 + seed].pack('Q<').b
    when 'bf16'
      [0x3f80 + seed].pack('S<').b
    when 'fixed4'
      [0x41, seed & 0xff, 0, 0xff].pack('C*').b
    when 'ipv4'
      [127, 0, 0, seed & 0xff].pack('C*').b
    when 'ipv6'
      bytes = Array.new(16, 0)
      bytes[0, 4] = [0x20, 0x01, 0x0d, 0xb8]
      bytes[15] = seed & 0xff
      bytes.pack('C*').b
    when 'uuid'
      bytes = Array.new(16, 0)
      bytes[0, 4] = [0x12, 0x34, 0x56, 0x78]
      bytes[15] = seed & 0xff
      bytes.pack('C*').b
    else
      raw_width(seed, width)
    end
  end

  def self.fixed_hex(name, row)
    fixed_payload(name, row).unpack1('H*')
  end

  def self.nullable_text_for_row(row)
    case row
    when 0, 3, 6 then nil
    when 1, 4 then ''.b
    when 2 then "nullable\0tail".b
    when 5 then invalid_bytes
    else long_bytes
    end
  end

  def self.string_runs_for_row(row)
    case row
    when 0, 1 then []
    when 2 then [''.b, "inside\0tail".b]
    when 3 then [invalid_bytes]
    when 4 then []
    when 5 then [long_bytes]
    when 6 then ['tail'.b]
    when 7 then []
    else raise Failure, "unknown String-array row #{row}"
    end
  end

  def self.pair_rows_for_row(row)
    case row
    when 0, 1, 4, 5 then []
    when 2 then [[11, ''.b], [12, nil]]
    when 3 then [[21, "inside\0tail".b], [22, invalid_bytes]]
    when 6 then [[61, long_bytes]]
    when 7 then [[71, nil]]
    else raise Failure, "unknown pair-array row #{row}"
    end
  end

  def self.map_rows_for_row(row)
    case row
    when 0, 1, 4, 5, 7 then []
    when 2 then [[''.b, ''.b], ["n\0key".b, nil]]
    when 3 then [['raw'.b, invalid_bytes]]
    when 6 then [['long'.b, long_bytes]]
    else raise Failure, "unknown Map row #{row}"
    end
  end

  def self.nested_rows_for_row(row)
    case row
    when 0, 1, 4, 5 then []
    when 2 then [['nested'.b, nil]]
    when 3 then [[''.b, [2].pack('C').b]]
    when 6 then [[long_bytes, [6].pack('C').b], ["tail\0label".b, nil]]
    when 7 then [[invalid_bytes, [7].pack('C').b]]
    else raise Failure, "unknown Nested row #{row}"
    end
  end

  def self.point_for_row(row)
    [raw_width(0x3ff0_0000_0000_0000 + row * 5 + 43, 8),
     raw_width(0x3ff0_0000_0000_0000 + row * 5 + 44, 8)]
  end

  def self.row_model(row)
    values = {}
    FIXED_NAMES.each { |name| values[name] = fixed_payload(name, row) }
    values.merge!(
      'empty_tuple' => [], 'text' => text_for_row(row),
      'text_runs' => string_runs_for_row(row), 'empty_texts' => [],
      'maybe_text' => nullable_text_for_row(row),
      'maybe_u16' => row.even? ? raw_width(row * 5 + 45, 2) : nil,
      'array_pairs' => pair_rows_for_row(row), 'lookup' => map_rows_for_row(row),
      'nested_labels' => nested_rows_for_row(row),
      'plain_tuple' => [raw_width(row * 5 + 41 + 1, 4), text_for_row(row)],
      'point' => [raw_width(0x3ff0_0000_0000_0000 + row * 5 + 43, 8),
                  raw_width(0x3ff0_0000_0000_0000 + row * 5 + 44, 8)],
      'multipoint' => if row == 2 || row == 6
                        [[raw_width(0x3ff0_0000_0000_0000 + row * 5 + 43, 8), raw_width(0x3ff0_0000_0000_0000 + row * 5 + 44, 8)],
                         [raw_width(0x3ff0_0000_0000_0000 + (row + 1) * 5 + 43, 8), raw_width(0x3ff0_0000_0000_0000 + (row + 1) * 5 + 44, 8)]]
                      elsif row == 7
                        [[raw_width(0x3ff0_0000_0000_0000 + row * 5 + 43, 8), raw_width(0x3ff0_0000_0000_0000 + row * 5 + 44, 8)]]
                      else
                        []
                      end,
      'maybe_point' => row.even? ? [raw_width(0x3ff0_0000_0000_0000 + row * 5 + 43, 8),
                                   raw_width(0x3ff0_0000_0000_0000 + row * 5 + 44, 8)] : nil,
      'sum_state' => [row + 501].pack('Q<').b,
    )
    values
  end

  def self.signature(type, bytes = ''.b, null = false, children = [])
    type = type.to_s
    hex = bytes.unpack1('H*')
    payload = null || !children.empty? || bytes.empty? ? '' : hex
    children_text = children.map { |child| "#{child.bytesize}:#{child};" }.join
    "#{type.bytesize}:#{type}:#{null ? 'N' : 'V'}:#{payload.bytesize}:#{payload}:#{children.size}[#{children_text}]"
  end

  def self.string_signature(bytes)
    signature('String', bytes)
  end

  def self.nullable_signature(type, bytes_or_nil, leaf_type = nil)
    return signature("Nullable(#{type})", ''.b, true) if bytes_or_nil.nil?
    child = if leaf_type
              signature(leaf_type, bytes_or_nil)
            else
              string_signature(bytes_or_nil)
            end
    signature("Nullable(#{type})", ''.b, false, [child])
  end

  def self.expected_row_signature(row)
    values = row_model(row)
    children = FIXED_FIELDS.map { |name, type, _width| signature(type, values.fetch(name)) }
    children << signature('Tuple()')
    children << string_signature(values.fetch('text'))
    children << signature('Array(String)', ''.b, false, values.fetch('text_runs').map { |item| string_signature(item) })
    children << signature('Array(String)')
    children << nullable_signature('String', values.fetch('maybe_text'))
    children << nullable_signature('UInt16', values.fetch('maybe_u16'), 'UInt16')
    pair_type = 'Tuple(UInt16, Nullable(String))'
    pair_children = values.fetch('array_pairs').map do |key, text|
      signature(pair_type, ''.b, false, [signature('UInt16', [key].pack('S<').b), nullable_signature('String', text)])
    end
    children << signature('Array(Tuple(UInt16, Nullable(String)))', ''.b, false, pair_children)
    map_children = values.fetch('lookup').flat_map do |key, text|
      [string_signature(key), nullable_signature('String', text)]
    end
    children << signature('Map(String, Nullable(String))', ''.b, false, map_children)
    nested_record_type = 'Tuple(label String, maybe_code Nullable(UInt8))'
    nested_children = values.fetch('nested_labels').map do |label, code|
      signature(nested_record_type, ''.b, false, [string_signature(label), nullable_signature('UInt8', code, 'UInt8')])
    end
    children << signature('Nested(label String, maybe_code Nullable(UInt8))', ''.b, false, nested_children)
    children << signature('Tuple(UInt32, String)', ''.b, false,
                          [signature('UInt32', values.fetch('plain_tuple')[0]), string_signature(values.fetch('plain_tuple')[1])])
    point_children = lambda do |point|
      signature('Point', ''.b, false, [signature('Tuple(Float64, Float64)', ''.b, false,
        [signature('Float64', point[0]), signature('Float64', point[1])])])
    end
    children << point_children.call(values.fetch('point'))
    multi_array = signature('Array(Point)', ''.b, false, values.fetch('multipoint').map { |point| point_children.call(point) })
    children << signature('MultiPoint', ''.b, false, [multi_array])
    maybe_point = values.fetch('maybe_point')
    children << if maybe_point
                  signature('Nullable(Point)', ''.b, false, [point_children.call(maybe_point)])
                else
                  signature('Nullable(Point)', ''.b, true)
                end
    children << signature('SimpleAggregateFunction(sum, UInt64)', ''.b, false,
                          [signature('UInt64', values.fetch('sum_state'))])
    bulk_type = STOCK_BULK_TYPE
    bulk = signature(bulk_type, ''.b, false, children)
    "T(J#{row + 1},#{bulk})"
  end

  def self.expected_signatures
    (0...ROW_COUNT).map { |row| expected_row_signature(row) }
  end

  GUARD_SCHEMA = [
    ['pk', 'UInt64'], ['nothing_only_w281', 'Nothing'],
  ].map(&:freeze).freeze
  SUCCESS_STATUSES = %w[
    stock_native_matrix_exact
    generated_native_interop_matrix_exact
    generated_admission_rejection_captured
  ].freeze

  class Probe < W280M::Probe
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

      @nothing_guard = capture_nothing_guard!

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
      puts "W281 static Bulk matrix status=#{summary.fetch(:status)}; cases=#{@cases.size}; " \
           "invocations=#{@invocations.size}; evidence=#{@root}"
      SUCCESS_STATUSES.include?(summary.fetch(:status))
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      persist_inconclusive(error)
      warn "W281 static Bulk matrix inconclusive: #{@fatal_error}"
      false
    end

    private

    def validate_literals!
      fail!('stock matrix must use one stock schema and exactly MRK3/MRK4 × S0/S1') unless
        CASE == 'stock_bulk' && MARK_FORMATS == %w[mrk3 mrk4] && PROFILES == %w[s0 s1] &&
        SCHEMAS.keys == [CASE]
      fail!('native RowBinary corpus must retain eight rows and four two-row marks') unless
        ROW_COUNT == 8 && ROWS_PER_MARK == 2 && DATA_MARK_COUNT == 4 &&
        RAW_MARK_ROWS == [2, 2, 2, 2, 0] && PUBLIC_MARK_ROWS == [2, 2, 2, 2]
      fail!('stock declaration must exclude only bare Nothing') unless
        STOCK_FIELDS.map(&:first).include?('interval_day') && STOCK_FIELDS.map(&:first).include?('empty_tuple') &&
        STOCK_FIELDS.map(&:first).include?('sum_state') && !STOCK_FIELDS.map(&:first).include?('nothing') &&
        BROAD_FIELDS.map(&:first) == STOCK_FIELDS.map(&:first).take(FIXED_FIELDS.size) + ['nothing'] +
          STOCK_FIELDS.map(&:first).drop(FIXED_FIELDS.size)
      fail!('String coverage must include a wholly-empty lane and an empty-first-mark lane') unless
        WRAPPER_FIELDS.assoc('text_runs')&.last == 'Array(String)' &&
        WRAPPER_FIELDS.assoc('empty_texts')&.last == 'Array(String)' &&
        (0..1).all? { |row| ProbeCompactStaticBulkW281Matrix.string_runs_for_row(row).empty? } &&
        (0...ROW_COUNT).all? { |row| ProbeCompactStaticBulkW281Matrix.row_model(row).fetch('empty_texts').empty? } &&
        (2...ROW_COUNT).any? { |row| !ProbeCompactStaticBulkW281Matrix.string_runs_for_row(row).empty? }
      fail!('independent row model must cover all stock signatures') unless
        ProbeCompactStaticBulkW281Matrix.expected_signatures.size == ROW_COUNT
      fail!('literal row binary input must retain all eight distinct UInt64 keys') unless
        row_values(CASE).each_with_index.all? { |bytes, index| bytes.byteslice(0, 8).unpack1('Q<') == index + 1 }
      true
    end

    def prepare!
      super
      @local_source_paths = [PROBE_SOURCE, HELPER_SOURCE, FIXTURE_SOURCE].map do |path|
        fail!("matrix source is missing or symlinked: #{path}") unless File.file?(path) && !File.symlink?(path)
        File.realpath(path)
      end.uniq.sort
      @local_source_hashes_before = @local_source_paths.to_h { |path| [path, sha(path)] }
      if @full_matrix
        @helper = send(:validate_executable, @helper_argument, 'pinned W281 Crystal helper')
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
      "w281m_#{@token}_#{id}"
    end

    def schema_for(kind)
      return SCHEMAS.fetch(CASE) if kind == CASE
      return GUARD_SCHEMA if kind == 'nothing_guard'
      fail!("unknown schema kind #{kind.inspect}")
    end

    def settings(mark_format)
      substream_marks = mark_format == 'mrk4' ? 1 : 0
      string_serialization = @active_profile == 's1' ? 'with_size_stream' : 'single_stream'
      [
        'index_granularity=2', 'index_granularity_bytes=10485760', 'enable_mixed_granularity_parts=1',
        'min_rows_for_wide_part=1000000', 'min_bytes_for_wide_part=104857600', 'min_level_for_wide_part=0',
        'compress_marks=0', "marks_compression_codec='LZ4'", 'compress_primary_key=0', 'write_final_mark=1',
        "write_marks_for_substreams_in_compact_parts=#{substream_marks}",
        'min_compress_block_size=0', 'max_compress_block_size=4096',
        'ratio_of_defaults_for_sparse_serialization=1.0', "default_compression_codec='LZ4'",
        "serialization_info_version='with_types'", 'propagate_types_serialization_versions_to_nested_types=true',
        "string_serialization_version='#{string_serialization}'", "object_serialization_version='v3'",
        "object_shared_data_serialization_version='map'",
        "object_shared_data_serialization_version_for_zero_level_parts='map'",
        'object_shared_data_buckets_for_compact_part=1', 'object_shared_data_target_chunk_rows=1',
        "dynamic_serialization_version='v3'", 'use_compact_variant_discriminators_serialization=0',
        'allow_suspicious_low_cardinality_types=1',
      ].join(', ')
    end

    def encode_string(value)
      send(:rowbinary_string, value.to_s.b)
    end

    def encode_nullable_string(value)
      value.nil? ? "\x01".b : "\x00".b + encode_string(value)
    end

    def encode_nullable_fixed(value)
      value.nil? ? "\x01".b : "\x00".b + value
    end

    def encode_array(values)
      send(:rowbinary_var_uint, values.size) + values.join.b
    end

    def encode_point(point)
      point.fetch(0) + point.fetch(1)
    end

    def encode_stock_bulk(row)
      values = ProbeCompactStaticBulkW281Matrix.row_model(row)
      fixed = FIXED_FIELDS.map { |name, _type, _width| values.fetch(name) }
      wrappers = [
        ''.b, # Tuple() has zero elements and consumes no RowBinary bytes.
        encode_string(values.fetch('text')),
        encode_array(values.fetch('text_runs').map { |text| encode_string(text) }),
        encode_array([]),
        encode_nullable_string(values.fetch('maybe_text')),
        encode_nullable_fixed(values.fetch('maybe_u16')),
        encode_array(values.fetch('array_pairs').map do |key, text|
          [key].pack('S<').b + encode_nullable_string(text)
        end),
        encode_array(values.fetch('lookup').map do |key, text|
          encode_string(key) + encode_nullable_string(text)
        end),
        encode_array(values.fetch('nested_labels').map do |label, code|
          encode_string(label) + encode_nullable_fixed(code)
        end),
        values.fetch('plain_tuple').fetch(0) + encode_string(values.fetch('plain_tuple').fetch(1)),
        encode_point(values.fetch('point')),
        encode_array(values.fetch('multipoint').map { |point| encode_point(point) }),
        encode_nullable_fixed(values.fetch('maybe_point') && encode_point(values.fetch('maybe_point'))),
        values.fetch('sum_state'),
      ]
      (fixed + wrappers).join.b
    end

    def row_values(kind)
      fail!("RowBinary is only defined for #{CASE}") unless kind == CASE
      (0...ROW_COUNT).map do |row|
        pk = [row + 1].pack('Q<').b
        document = send(:rowbinary_json, {'id' => row + 1})
        pk + document + encode_stock_bulk(row)
      end
    end

    # Keep the process report JSON-safe: literal values are independent
    # signatures, while exact binary stdin remains in the hashed .bin sidecar.
    def literal_rows(kind)
      fail!("literal oracle is only defined for #{CASE}") unless kind == CASE
      expected_signatures
    end

    def expected_signatures(kind = CASE)
      fail!("signature oracle is only defined for #{CASE}") unless kind == CASE
      ProbeCompactStaticBulkW281Matrix.expected_signatures
    end

    def bulk_expr
      "tupleElement(`#{COLUMN}`, 2)"
    end

    def bulk_field_expr(name)
      index = STOCK_FIELDS.index { |field| field.fetch(0) == name }
      fail!("unknown stock Bulk field #{name.inspect}") unless index
      "tupleElement(#{bulk_expr}, #{index + 1})"
    end

    def raw_scalar_sql(expression)
      "lower(hex(reinterpretAsFixedString(#{expression})))"
    end

    def string_token_sql(expression)
      "concat(toString(length(#{expression})), ':', lower(hex(#{expression})))"
    end

    def nullable_string_token_sql(expression)
      "if(isNull(#{expression}), 'N', concat('V', #{string_token_sql("ifNull(#{expression}, '')")}))"
    end

    def point_token_sql(expression)
      "concat(#{raw_scalar_sql("tupleElement(#{expression}, 1)")}, '/', " \
        "#{raw_scalar_sql("tupleElement(#{expression}, 2)")})"
    end

    def native_projection_sql
      projections = FIXED_FIELDS.map do |name, _type, _width|
        "concat('#{name}:', #{raw_scalar_sql(bulk_field_expr(name))})"
      end
      projections << "'empty_tuple:Tuple()'"
      projections << "concat('text:S', #{string_token_sql(bulk_field_expr('text'))})"
      text_runs = bulk_field_expr('text_runs')
      projections << "concat('text_runs:A', toString(length(#{text_runs})), '[', " \
        "arrayStringConcat(arrayMap(item -> #{string_token_sql('item')}, #{text_runs}), ';'), ']')"
      empty_texts = bulk_field_expr('empty_texts')
      projections << "concat('empty_texts:A', toString(length(#{empty_texts})), '[', " \
        "arrayStringConcat(arrayMap(item -> #{string_token_sql('item')}, #{empty_texts}), ';'), ']')"
      maybe_text = bulk_field_expr('maybe_text')
      projections << "concat('maybe_text:', #{nullable_string_token_sql(maybe_text)})"
      maybe_u16 = bulk_field_expr('maybe_u16')
      projections << "if(isNull(#{maybe_u16}), 'maybe_u16:N', " \
        "concat('maybe_u16:V', #{raw_scalar_sql("assumeNotNull(#{maybe_u16})")}))"
      pairs = bulk_field_expr('array_pairs')
      projections << "concat('array_pairs:A', toString(length(#{pairs})), '[', " \
        "arrayStringConcat(arrayMap(item -> concat(toString(tupleElement(item, 1)), '/', " \
        "#{nullable_string_token_sql('tupleElement(item, 2)')}), #{pairs}), ';'), ']')"
      lookup = bulk_field_expr('lookup')
      projections << "concat('lookup:A', toString(length(mapKeys(#{lookup}))), '[', " \
        "arrayStringConcat(arrayMap((key, value) -> concat(#{string_token_sql('key')}, '/', " \
        "#{nullable_string_token_sql('value')}), mapKeys(#{lookup}), mapValues(#{lookup})), ';'), ']')"
      nested = bulk_field_expr('nested_labels')
      projections << "concat('nested_labels:A', toString(length(#{nested})), '[', " \
        "arrayStringConcat(arrayMap(item -> concat(#{string_token_sql('tupleElement(item, 1)')}, '/', " \
        "if(isNull(tupleElement(item, 2)), 'N', concat('V', toString(assumeNotNull(tupleElement(item, 2)))))), " \
        "#{nested}), ';'), ']')"
      tuple = bulk_field_expr('plain_tuple')
      projections << "concat('plain_tuple:', #{raw_scalar_sql("tupleElement(#{tuple}, 1)")}, '/', " \
        "#{string_token_sql("tupleElement(#{tuple}, 2)")})"
      point = bulk_field_expr('point')
      projections << "concat('point:', #{point_token_sql(point)})"
      multipoint = bulk_field_expr('multipoint')
      projections << "concat('multipoint:A', toString(length(#{multipoint})), '[', " \
        "arrayStringConcat(arrayMap(item -> #{point_token_sql('item')}, #{multipoint}), ';'), ']')"
      maybe_point = bulk_field_expr('maybe_point')
      projections << "if(isNull(#{maybe_point}), 'maybe_point:N', " \
        "concat('maybe_point:V', #{point_token_sql("assumeNotNull(#{maybe_point})")}))"
      sum_state = bulk_field_expr('sum_state')
      projections << "concat('sum_state:', toString(#{sum_state}))"
      projections
    end

    def string_token(bytes)
      "#{bytes.bytesize}:#{bytes.unpack1('H*')}"
    end

    def nullable_string_token(bytes)
      bytes.nil? ? 'N' : "V#{string_token(bytes)}"
    end

    def point_token(point)
      "#{point.fetch(0).unpack1('H*')}/#{point.fetch(1).unpack1('H*')}"
    end

    def native_projection_tokens(row)
      values = ProbeCompactStaticBulkW281Matrix.row_model(row)
      tokens = FIXED_FIELDS.map { |name, _type, _width| "#{name}:#{values.fetch(name).unpack1('H*')}" }
      tokens << 'empty_tuple:Tuple()'
      tokens << "text:S#{string_token(values.fetch('text'))}"
      runs = values.fetch('text_runs')
      tokens << "text_runs:A#{runs.size}[#{runs.map { |text| string_token(text) }.join(';')}]"
      tokens << 'empty_texts:A0[]'
      tokens << "maybe_text:#{nullable_string_token(values.fetch('maybe_text'))}"
      maybe_u16 = values.fetch('maybe_u16')
      tokens << "maybe_u16:#{maybe_u16 ? "V#{maybe_u16.unpack1('H*')}" : 'N'}"
      pairs = values.fetch('array_pairs')
      tokens << "array_pairs:A#{pairs.size}[#{pairs.map { |key, text| "#{key}/#{nullable_string_token(text)}" }.join(';')}]"
      map = values.fetch('lookup')
      tokens << "lookup:A#{map.size}[#{map.map { |key, text| "#{string_token(key)}/#{nullable_string_token(text)}" }.join(';')}]"
      nested = values.fetch('nested_labels')
      tokens << "nested_labels:A#{nested.size}[#{nested.map { |label, code| "#{string_token(label)}/#{code.nil? ? 'N' : "V#{code.unpack1('C')}"}" }.join(';')}]"
      plain_tuple = values.fetch('plain_tuple')
      tokens << "plain_tuple:#{plain_tuple.fetch(0).unpack1('H*')}/#{string_token(plain_tuple.fetch(1))}"
      point = values.fetch('point')
      tokens << "point:#{point_token(point)}"
      multipoint = values.fetch('multipoint')
      tokens << "multipoint:A#{multipoint.size}[#{multipoint.map { |item| point_token(item) }.join(';')}]"
      maybe_point = values.fetch('maybe_point')
      tokens << "maybe_point:#{maybe_point ? "V#{point_token(maybe_point)}" : 'N'}"
      tokens << "sum_state:#{row + 501}"
      tokens
    end

    def capture_case!(id, kind, mark_format, profile)
      fail!("unknown native case #{kind.inspect}") unless kind == CASE
      @active_profile = profile
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
        string_profile: profile,
        schema_parameters: {object_serialization_version: 'v3', object_shared_data_serialization_version: 'map',
          map_layout_value: 0, object_shared_data_buckets_for_compact_part: 1,
          string_serialization_version: profile == 's1' ? 'with_size_stream' : 'single_stream',
          mark_compression: 'plain', variant_discriminator_mode: 'basic'},
        status: status, create: send(:stage_summary, create),
        insert: insert && send(:stage_summary, insert), literal_input: insert && insert[:literal_input],
        schema_part: physical, check: check, windows: windows,
      }
    end

    def values_sql(id, table, window)
      tag = send(:marker, 'values', id, window)
      predicate = WINDOWS.fetch(window)
      if window == 'eof'
        return "SELECT '#{tag}', toString(count()) FROM default.#{table} WHERE #{predicate} FORMAT TSVRaw;\n"
      end
      where = predicate ? " WHERE #{predicate}" : ''
      "SELECT '#{tag}', toString(pk), lower(hex(toJSONString([#{native_projection_sql.join(', ')}]))) " \
        "FROM default.#{table}#{where} ORDER BY pk SETTINGS output_format_json_named_tuples_as_objects=0 FORMAT TSVRaw;\n"
    end

    def read_window!(id, table, store, kind, window)
      result = execute_sql!("#{id}_values_#{window}", store, values_sql(id, table, window))
      return {state: send(:result_class, result), invocation: send(:stage_summary, result)} unless send(:success?, result)
      lines = send(:pinned_lines, result, "#{id}/#{window} static Bulk native value query")
      tag = send(:marker, 'values', id, window)
      if window == 'eof'
        rows = send(:tagged, lines, tag, 2)
        exact = rows == [[tag, '0']] && lines.size == 1
        return {state: exact ? 'exact_values' : 'oracle_mismatch', rows: rows,
          expected_rows: [[tag, '0']], invocation: send(:stage_summary, result)}
      end
      rows = send(:tagged, lines, tag, 3)
      actual = rows.map do |row|
        {pk: Integer(row.fetch(1), 10), fields: send(:decode_hex_json, row.fetch(2))}
      end
      indexes = case window
                when 'full' then (0...ROW_COUNT).to_a
                when 'middle' then (2...6).to_a
                when 'last' then (6...8).to_a
                else fail!("non-value window #{window.inspect}")
                end
      expected = indexes.map { |index| {pk: index + 1, fields: native_projection_tokens(index)} }
      exact = actual == expected && lines.size == rows.size && rows.size == expected.size
      {state: exact ? 'exact_values' : 'oracle_mismatch', rows: actual,
        expected_rows: expected, raw_rows: rows, invocation: send(:stage_summary, result)}
    rescue ArgumentError, JSON::ParserError, KeyError => error
      {state: 'parse_error', error: "#{error.class}: #{error.message}"}
    end

    def capture_nothing_guard!
      id = 'nothing_schema_guard'
      @active_profile = 's0'
      table = table_name(id)
      store = send(:store_path, id)
      sql = create_sql(table, 'nothing_guard', 'mrk3')
      result = execute_sql!(id, store, sql)
      stderr = result.fetch(:stderr).dup.force_encoding(Encoding::UTF_8)
      server_code = stderr[/\bCode: ([0-9]+)\b/, 1]&.to_i
      status = if send(:result_class, result) == 'server_exception' && server_code == 370
                 'rejected_expected_code_370'
               elsif send(:success?, result)
                 'unexpectedly_admitted'
               else
                 'guard_infrastructure_or_unexpected_server_failure'
               end
      {status: status, schema: GUARD_SCHEMA, expected_server_code: 370,
        observed_server_code: server_code, invocation: send(:stage_summary, result)}
    rescue StandardError => error
      {status: 'guard_probe_error', error: "#{error.class}: #{error.message}"}
    end

    def capture_helper_read!(label, case_id, kind, mark_format, profile, part_path)
      return {status: 'unavailable_stock_part'} unless part_path
      invocation = invoke_helper(label, 'read', kind, mark_format, profile, part_path)
      validate_helper_report!(invocation, case_id, kind, mark_format, 'read',
        expected_part_path: part_path, profile: profile)
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
      argv = [@helper, action, kind, mark_format, profile, part]
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

    def classify_helper_error(invocation)
      return 'helper_infrastructure_failure' if invocation[:state] == 'infrastructure_failure'

      report = invocation[:report]
      error = report.is_a?(Hash) ? "#{report['error_class']} #{report['error']}" : invocation[:error].to_s
      if error.match?(/UnsupportedFormatError|outside (the )?(captured|admitted)|not admitted/i)
        'library_admission_rejection_captured'
      else
        'library_writer_or_reader_rejection_captured'
      end
    end

    def validate_helper_report!(invocation, case_id, kind, mark_format, action,
                                expected_part_path:, profile: @active_profile)
      unless invocation[:state] == 'success'
        return {status: classify_helper_error(invocation), error: invocation[:report] || invocation[:error],
          invocation: invocation[:invocation]}
      end
      report = invocation.fetch(:report)
      expected_schema = schema_for(kind).last.last.gsub(/\s+/, '')
      expected_origin = action == 'read' ? 'stock' : 'generated'
      fail!("#{case_id} helper report envelope differs") unless
        report.fetch('format') == HELPER_FORMAT && report.fetch('action') == action &&
        report.fetch('case') == kind && report.fetch('mark_format') == mark_format &&
        report.fetch('string_profile') == profile && report.fetch('status') == 'ok' &&
        report.fetch('row_count') == ROW_COUNT && report.fetch('data_mark_count') == DATA_MARK_COUNT &&
        report.fetch('part_origin') == expected_origin && report.fetch('public_reader_grid') == 'nonempty_data_marks' &&
        report.fetch('public_reader_mark_count') == DATA_MARK_COUNT &&
        report.fetch('public_reader_mark_rows') == PUBLIC_MARK_ROWS &&
        report.fetch('part_path') == expected_part_path && report.fetch('schema').gsub(/\s+/, '') == expected_schema
      signatures = expected_signatures(kind)
      windows = {
        'full' => signatures,
        'middle' => signatures.drop(2).take(4),
        'last' => signatures.drop(6).take(2),
        'eof' => [],
      }
      recursive = report.fetch('recursive_windows')
      typed = report.fetch('typed_windows')
      fail!("#{case_id} helper recursive-window roster differs") unless recursive.keys.sort == windows.keys.sort
      fail!("#{case_id} helper typed-window roster differs") unless typed.keys.sort == windows.keys.sort
      windows.each do |window, expected|
        recursive_entry = recursive.fetch(window)
        typed_entry = typed.fetch(window)
        fail!("#{case_id}/#{window} recursive reader differs from independent signatures") unless
          recursive_entry.fetch('signatures') == expected &&
          recursive_entry.fetch('first_mark') == PHYSICAL_WINDOWS.fetch(window)[0] &&
          recursive_entry.fetch('mark_count') == PHYSICAL_WINDOWS.fetch(window)[1]
        fail!("#{case_id}/#{window} typed facade differs from independent signatures") unless
          typed_entry.fetch('signatures') == expected &&
          typed_entry.fetch('start_row') == TYPED_WINDOWS.fetch(window)[0] &&
          typed_entry.fetch('row_count') == expected.size
      end
      {status: 'exact_public_recursive_and_typed_reads', report: report,
        invocation: invocation.fetch(:invocation)}
    rescue KeyError, TypeError, NoMethodError => error
      fail!("#{case_id} helper report is incomplete: #{error.class}: #{error.message}")
    end

    def build_summary
      stock_exact = @cases.size == MARK_FORMATS.size * PROFILES.size &&
        @cases.values.all? { |entry| entry.fetch(:status) == 'exact_native_values' }
      guard_exact = @nothing_guard && @nothing_guard.fetch(:status) == 'rejected_expected_code_370'
      generated_exact = @full_matrix && stock_exact && guard_exact &&
        @cases.values.all? do |entry|
          entry.dig(:library_stock_read, :status) == 'exact_public_recursive_and_typed_reads' &&
            entry.dig(:library_generated, :status) == 'exact_generated_native_interop'
        end
      all_writer_admission_rejections = @full_matrix && stock_exact && guard_exact &&
        @cases.values.all? do |entry|
          entry.dig(:library_stock_read, :status) == 'exact_public_recursive_and_typed_reads' &&
            entry.dig(:library_generated, :status) == 'library_admission_rejection_captured'
        end
      infrastructure_failure = @cases.values.any? do |entry|
        entry[:status].to_s.include?('infrastructure_failure') ||
          entry.dig(:library_stock_read, :status).to_s.include?('infrastructure_failure') ||
          entry.dig(:library_generated, :status).to_s.include?('infrastructure_failure')
      end || @nothing_guard&.fetch(:status, '').to_s.include?('infrastructure')
      status = if generated_exact
                 'generated_native_interop_matrix_exact'
               elsif all_writer_admission_rejections
                 'generated_admission_rejection_captured'
               elsif !@full_matrix && stock_exact && guard_exact
                 'stock_native_matrix_exact'
               elsif infrastructure_failure
                 'probe_infrastructure_failure'
               else
                 'incomplete_or_discrepant'
               end
      {
        format: FORMAT, status: status,
        execution_scope: 'Stock-only mode sends independently encoded Ruby RowBinary rows to the pinned native runtime. Full mode then uses the public Crystal reader/writer helper; helper admission failures are recorded as RED and do not establish compatibility.',
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
        schema_parameters: {object_serialization_version: 'v3', object_shared_data_serialization_version: 'map',
          map_layout_value: 0, object_shared_data_buckets_for_compact_part: 1,
          string_profiles: {'s0' => 'single_stream', 's1' => 'with_size_stream'},
          mark_compression: 'plain', variant_discriminator_mode: 'basic', mark_formats: MARK_FORMATS},
        fixture: {schema: SCHEMAS.fetch(CASE), stock_fields: STOCK_FIELDS,
          local_only_fields: ['bare Nothing is separately guarded and omitted from stock_bulk'],
          literal_signatures: expected_signatures, row_count: ROW_COUNT, rows_per_mark: ROWS_PER_MARK,
          data_marks: DATA_MARK_COUNT, raw_mark_file_rows: RAW_MARK_ROWS,
          public_reader_mark_rows: PUBLIC_MARK_ROWS, native_windows: WINDOWS,
          physical_windows: PHYSICAL_WINDOWS, typed_windows: TYPED_WINDOWS,
          string_edge_cases: ['empty', 'embedded NUL', 'invalid UTF-8 bytes', '261-byte value',
            'Array(String) empty in the first data mark, populated later',
            'Array(String) empty in every row'],
          independent_input: 'Ruby literals encoded as RowBinary; expected native projections are tokenized from those literals and compared against SELECT output.'},
        nothing_guard: @nothing_guard, cases: @cases,
        invocation_roster: @invocations.map do |record|
          {label: record.fetch(:label), process_kind: record.fetch(:process_kind),
            binary_path: record.fetch(:binary_path), store_path: record.fetch(:store_path),
            argv: record.fetch(:argv), stdin_file: record.fetch(:stdin_file),
            argv_file: record.fetch(:argv_file), stdout_file: record.fetch(:stdout_file),
            stderr_file: record.fetch(:stderr_file), record_file: "#{record.fetch(:label)}.json"}
        end,
        evidence_root: @root,
        claim_boundary: 'Finite eight-row, four-data-mark evidence for this declared static Bulk island only, under plain/MAP0/BASIC/V3 and MRK3/MRK4 × S0/S1. Success requires native schema/part capture, CHECK, independent full/middle/last/EOF value windows, the explicit Nothing rejection guard, and (in full mode) public reader signatures plus byte-preserving generated-part ATTACH with only the exact pinned invalidated_system_columns.txt sidecar. This does not establish all BinaryDataType tags, arbitrary type trees, QBit, Variant, Dynamic, or AggregateFunction support.',
      }
    end

    def render_summary(summary)
      lines = [
        '# W281 Compact static Bulk matrix', '',
        "Status: `#{summary.fetch(:status)}`",
        "Runtime: `#{W280::VERSION}` build `#{W280::BUILD}` SHA-256 `#{W280::BINARY_SHA256}`.",
        "Source: `#{W280::SOURCE_REVISION}` at `#{W280::SOURCE_ROOT}` (separate pin).",
        'Stock cases are captured before any helper reads or generated writes; the matrix is MRK3/MRK4 × S0/S1.',
      ]
      @cases.each do |id, entry|
        generated = entry.dig(:library_generated, :status)
        read = entry.dig(:library_stock_read, :status)
        lines << "- #{id}: native `#{entry.fetch(:status)}`; public read `#{read || 'not run'}`; generated `#{generated || 'not run'}`."
      end
      lines << "- bare Nothing schema guard: `#{@nothing_guard&.fetch(:status, 'not run')}`."
      lines.concat(['', summary.fetch(:claim_boundary), ''])
      lines.join("\n")
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  options = {
    binary: ProbeCompactRecursiveArraysW280Matrix::W280::BINARY,
    source_root: ProbeCompactRecursiveArraysW280Matrix::W280::SOURCE_ROOT,
    evidence_root: nil, stock_only: false, full_matrix: false, helper: nil, helper_sha256: nil,
  }
  OptionParser.new do |parser|
    parser.banner = 'Usage: ruby scripts/probe_compact_static_bulk_w281_matrix.rb (--stock-only | --full-matrix --helper PREBUILT --helper-sha256 SHA256) --evidence-root EMPTY_DIR'
    parser.on('--stock-only', 'Capture only the independent stock/native matrix') { options[:stock_only] = true }
    parser.on('--full-matrix', 'Capture stock first, then public-reader/generated-writer/native interop') { options[:full_matrix] = true }
    parser.on('--helper PATH', 'Prebuilt W281 Crystal helper; full-matrix only') { |value| options[:helper] = value }
    parser.on('--helper-sha256 SHA256', 'Exact lowercase SHA-256 of the prebuilt helper') { |value| options[:helper_sha256] = value }
    parser.on('--evidence-root EMPTY_DIR', 'Existing empty direct child of /private/tmp') { |value| options[:evidence_root] = value }
    parser.on('--binary PATH', 'Separately pinned ClickHouse runtime executable') { |value| options[:binary] = value }
    parser.on('--source-root PATH', 'Separately pinned upstream ClickHouse checkout') { |value| options[:source_root] = value }
  end.parse!
  unless options[:evidence_root] && options[:stock_only] != options[:full_matrix]
    warn 'W281 static Bulk matrix: choose exactly one mode and provide --evidence-root'
    exit 2
  end
  if options[:full_matrix] && (!options[:helper] || !options[:helper_sha256])
    warn 'W281 static Bulk matrix: --full-matrix requires --helper and --helper-sha256'
    exit 2
  end
  if options[:stock_only] && (options[:helper] || options[:helper_sha256])
    warn 'W281 static Bulk matrix: helper options are valid only with --full-matrix'
    exit 2
  end
  exit(ProbeCompactStaticBulkW281Matrix::Probe.new(**options).run ? 0 : 1)
end
