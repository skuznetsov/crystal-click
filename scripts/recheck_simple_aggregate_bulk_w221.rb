#!/usr/bin/env ruby
# Pinned stock-Wide / generic SimpleAggregateFunction bulk reader-writer check.
# This consumes prebuilt executables and previously captured stock parts; it
# does not build ClickHouse or compile Crystal.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'optparse'

module RecheckSimpleAggregateBulkW221
  extend self

  VERSION = '26.10.1.1201'.freeze
  BUILD_HASH = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  CLICKHOUSE_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  SOURCE_ROOT = '/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1'.freeze
  SOURCE_REVISION = '0ca8150d9b1d0886edb2e3b4ab65eebb768d0357'.freeze
  SOURCE_PREFIX = '/private/tmp/crystal-click-w221-physical.'.freeze
  EVIDENCE_PREFIX = '/private/tmp/crystal-click-w221-bulk.'.freeze

  FORMAT_INPUT = 'simple_aggregate_bulk_w221_input_v1'.freeze
  FORMAT_HELPER = 'simple_aggregate_bulk_w221_helper_v1'.freeze
  PROCESS_TIMEOUT_SECONDS = 90
  HELPER_TIMEOUT_SECONDS = 240
  TERM_GRACE_SECONDS = 2
  MEMORY_LIMIT_BYTES = 1_073_741_824
  ROW_KEYS = [11, 22, 33, 44, 55].freeze
  NULL_ROW_INDEX = 1
  TARGET_FUNCTIONS = %w[any_respect_nulls anyLast_respect_nulls].freeze
  SHAPES = %w[scalar inner_nullable outer_nullable].freeze
  STRING_MODES = %w[single_stream with_size_stream].freeze
  STRING_SETTINGS = {
    'single_stream' => 0,
    'with_size_stream' => 1,
  }.freeze
  ATTACHMENT_AUXILIARY_FILE = 'invalidated_system_columns.txt'.freeze
  ATTACHMENT_INVALIDATED_SYSTEM_COLUMNS = %w[_block_number _block_offset].freeze

  Leaf = Struct.new(:key, :sql, :family, keyword_init: true)

  LEAVES = begin
    leaves = []
    %w[UInt8 UInt16 UInt32 UInt64 UInt128 UInt256].each do |name|
      leaves << Leaf.new(key: name.downcase, sql: name, family: 'integer')
    end
    %w[Int8 Int16 Int32 Int64 Int128 Int256].each do |name|
      leaves << Leaf.new(key: name.downcase, sql: name, family: 'integer')
    end
    leaves.concat([
      Leaf.new(key: 'float32', sql: 'Float32', family: 'float32'),
      Leaf.new(key: 'float64', sql: 'Float64', family: 'float64'),
      Leaf.new(key: 'bfloat16', sql: 'BFloat16', family: 'bfloat16'),
      Leaf.new(key: 'string', sql: 'String', family: 'string'),
      Leaf.new(key: 'fixedstring3', sql: 'FixedString(3)', family: 'fixed_string'),
    ])
    [[9, 2], [18, 3], [38, 5], [76, 7]].each do |precision, scale|
      leaves << Leaf.new(key: "decimal_p#{precision}_s#{scale}",
        sql: "Decimal(#{precision}, #{scale})", family: 'decimal')
    end
    leaves.concat([
      Leaf.new(key: 'date', sql: 'Date', family: 'temporal'),
      Leaf.new(key: 'date32', sql: 'Date32', family: 'temporal'),
      Leaf.new(key: 'time', sql: 'Time', family: 'temporal'),
      Leaf.new(key: 'time64_s3', sql: 'Time64(3)', family: 'temporal'),
      Leaf.new(key: 'datetime_utc', sql: "DateTime('UTC')", family: 'temporal'),
      Leaf.new(key: 'datetime64_s3_utc', sql: "DateTime64(3, 'UTC')", family: 'temporal'),
      Leaf.new(key: 'datetime_long_zone', sql: "DateTime('America/Argentina/ComodRivadavia')", family: 'temporal'),
      Leaf.new(key: 'datetime64_s3_long_zone',
        sql: "DateTime64(3, 'America/Argentina/ComodRivadavia')", family: 'temporal'),
    ])
    raise 'W221 exact leaf roster changed' unless leaves.length == 29
    leaves.freeze
  end

  STOCK_SETTINGS = [
    'index_granularity=2',
    'index_granularity_bytes=10485760',
    'enable_mixed_granularity_parts=1',
    'min_rows_for_wide_part=0',
    'min_bytes_for_wide_part=0',
    'min_level_for_wide_part=0',
    'compress_marks=0',
    'compress_primary_key=0',
    'min_compress_block_size=0',
    'max_compress_block_size=4096',
    'ratio_of_defaults_for_sparse_serialization=1.0',
    "default_compression_codec='LZ4'",
    "nullable_serialization_version='basic'",
    "serialization_info_version='with_types'",
    'propagate_types_serialization_versions_to_nested_types=1',
  ].freeze

  class Probe
    def initialize(options)
      @binary = validate_executable(options.fetch(:clickhouse), 'ClickHouse')
      @helper = validate_executable(options.fetch(:crystal_helper), 'prebuilt Crystal helper')
      @source_matrix_path = validate_source_matrix_path(options.fetch(:source_matrix))
      @source_root = File.dirname(@source_matrix_path)
      @root = validate_evidence_root(options.fetch(:evidence_root))
      @invocation_sequence = 0
      @invocations = []
      @profiles = []
      @table_by_id = {}
      @target_paths = {}
      @generated_parts = {}
      @generated_inventories = {}
      @target_inventories = {}
      @case_records = []
      @fatal_error = nil
      @helper_profiles = []
      @helper_invocation_record = nil
      @helper_status = nil
      @store = File.join(@root, 'stores', 'native')
      @recorder = Recorder.new(self, @root, @binary)
    end

    attr_reader :root

    def run
      prepare_layout!
      read_and_validate_source_matrix!
      write_run_manifest!
      pin_clickhouse!
      pin_helper!
      build_helper_input!
      invoke_crystal_helper!
      unless @helper_profiles.all? { |profile| profile.fetch('classification') == 'physical_observed' }
        fail!('one or more of 186 stock/library generic bulk checks failed; no ClickHouse attach was attempted')
      end

      create_native_targets!
      attach_and_verify_all!
      verify_executable_pins!
      write_summary('paired_simple_aggregate_bulk_observed')
      puts "W221 generic SimpleAggregateFunction bulk matrix profiles=#{@profiles.length}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      write_summary('runner_failure_or_observations_differ', @fatal_error) rescue nil
      warn "W221 bulk probe failure (not classified as a ClickHouse type-law refusal): #{@fatal_error}"
      false
    end

    def write_new(path, bytes)
      File.open(path, 'wbx', 0o600) { |file| file.write(bytes) }
    rescue Errno::EEXIST
      fail!("refusing to overwrite W221 bulk evidence: #{path}")
    end

    def write_json(path, object)
      write_new(path, JSON.pretty_generate(object) + "\n")
    end

    def recorder
      @recorder
    end

    private

    def fail!(message)
      raise ArgumentError, message
    end

    def validate_executable(path, label)
      fail!("#{label} path is required") unless path && !path.empty?
      full = File.expand_path(path)
      fail!("#{label} is missing, non-executable, or symlinked: #{full}") unless
        File.file?(full) && File.executable?(full) && !File.symlink?(full)
      full
    end

    def validate_source_matrix_path(path)
      fail!('source matrix path is required') unless path && !path.empty?
      full = File.expand_path(path)
      fail!('source matrix must be a plain matrix.json file') unless File.file?(full) && !File.symlink?(full) && File.basename(full) == 'matrix.json'
      root = File.dirname(full)
      fail!('source matrix must be below the fixed W221 stock evidence prefix') unless
        File.realpath(root) == root && root.start_with?(SOURCE_PREFIX) && File.dirname(root) == '/private/tmp'
      fail!('source matrix path is not canonical') unless File.realpath(full) == full
      full
    rescue Errno::ENOENT
      fail!('source matrix path does not exist')
    end

    def validate_evidence_root(path)
      fail!('evidence root is required') unless path && !path.empty?
      expanded = File.expand_path(path)
      fail!('evidence root must be a direct child of /private/tmp') unless File.dirname(expanded) == File.realpath('/private/tmp')
      fail!('evidence root must be an existing empty non-symlink directory') unless
        File.directory?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded && Dir.children(expanded).empty?
      fail!('evidence root name does not use the fixed W221 prefix') unless expanded.start_with?(EVIDENCE_PREFIX)
      expanded
    rescue Errno::ENOENT
      fail!('evidence root must already exist')
    end

    def prepare_layout!
      %w[invocations generated stores cases].each do |name|
        Dir.mkdir(File.join(@root, name), 0o700)
      end
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
      Dir.mkdir(File.join(@root, 'generated', 'parts'), 0o700)
      Dir.mkdir(File.join(@root, 'cases', 'profiles'), 0o700)
    end

    def make_dir(path)
      Dir.mkdir(path, 0o700)
    rescue Errno::EEXIST
      fail!("refusing to reuse W221 directory: #{path}")
    end

    def safe_label(value)
      value.gsub(/[^A-Za-z0-9_.-]/, '_')
    end

    def leaf_by_key(key)
      LEAVES.find { |leaf| leaf.key == key } || fail!("unlisted W221 leaf key #{key.inspect}")
    end

    def expected_profiles
      profiles = []
      TARGET_FUNCTIONS.each do |function|
        LEAVES.each do |leaf|
          modes = leaf.family == 'string' ? STRING_MODES : [nil]
          SHAPES.each do |shape|
            modes.each do |mode|
              suffix = mode ? "_#{mode}" : ''
              profiles << {
                'id' => "#{function}_#{leaf.key}_#{shape}#{suffix}",
                'kind' => 'matrix',
                'function' => function,
                'leaf_key' => leaf.key,
                'leaf_type' => leaf.sql,
                'shape' => shape,
                'string_serialization_mode' => mode,
              }
            end
          end
        end
      end
      [
        ['min', 'uint64'],
        ['sum', 'uint64'],
        ['sumWithOverflow', 'decimal_p38_s5'],
        ['groupBitAnd', 'int32'],
        ['groupBitOr', 'int32'],
        ['groupBitXor', 'int32'],
      ].each do |function, key|
        leaf = leaf_by_key(key)
        profiles << {
          'id' => "control_#{function}_#{leaf.key}_inner_nullable",
          'kind' => 'control',
          'function' => function,
          'leaf_key' => leaf.key,
          'leaf_type' => leaf.sql,
          'shape' => 'inner_nullable',
          'string_serialization_mode' => nil,
        }
      end
      fail!('internal W221 target roster is not exactly 186 cases') unless profiles.length == 186
      profiles
    end

    def aggregate_type(profile)
      storage = profile.fetch('shape') == 'inner_nullable' ? "Nullable(#{profile.fetch('leaf_type')})" : profile.fetch('leaf_type')
      "SimpleAggregateFunction(#{profile.fetch('function')}, #{storage})"
    end

    def declared_type(profile)
      aggregate = aggregate_type(profile)
      profile.fetch('shape') == 'outer_nullable' ? "Nullable(#{aggregate})" : aggregate
    end

    def runtime_pin_expected
      {
        'version' => VERSION,
        'build_hash' => BUILD_HASH,
        'sha256' => CLICKHOUSE_SHA256,
      }
    end

    def read_and_validate_source_matrix!
      @source_matrix = JSON.parse(File.binread(@source_matrix_path))
      manifest_path = File.join(@source_root, 'manifest.json')
      fail!('source manifest is missing or symlinked') unless File.file?(manifest_path) && !File.symlink?(manifest_path)
      @source_manifest = JSON.parse(File.binread(manifest_path))
      fail!('source matrix manifest digest is unavailable') unless Digest::SHA256.file(@source_matrix_path).hexdigest.match?(/\A[0-9a-f]{64}\z/)
      fail!('stock source snapshot differs from the pinned W221 source') unless
        @source_manifest.fetch('source_snapshot') == "#{SOURCE_ROOT}@#{SOURCE_REVISION}"
      fail!('source probe must not assert that its executable was built from this source snapshot') unless
        @source_manifest.fetch('source_snapshot_is_not_asserted_to_build_runtime') == true
      fail!('source runtime pin differs from the task-scoped executable') unless
        @source_manifest.fetch('runtime_pin_expected') == runtime_pin_expected

      law = @source_manifest.fetch('stock_construction_law')
      expected_law = {
        'total_cases' => 1283,
        'accepted' => 717,
        'refused' => 566,
        'result_mismatches' => 0,
        'probe_failures' => 0,
        'selected_physical_products_expected_admitted' => 186,
      }
      fail!('selected stock-construction law does not match the measured 1283/717/566 roster') unless law == expected_law

      fail!('source physical matrix count is not 186') unless @source_matrix.fetch('case_count') == 186 && @source_matrix.fetch('matrix').length == 186
      counts = {
        'physical_observed' => 186,
        'observed_type_refusals' => 0,
        'admission_mismatches' => 0,
        'probe_failures' => 0,
        'physical_mismatches' => 0,
      }
      counts.each do |key, expected|
        fail!("source physical matrix #{key} differs") unless @source_matrix.fetch(key) == expected
      end

      observed = {}
      @source_matrix.fetch('matrix').each do |record|
        id = record.fetch('id')
        fail!("duplicate stock physical case #{id}") if observed.key?(id)
        observed[id] = record
      end
      expected = expected_profiles
      fail!('stock profile IDs/order differ from the independent expected roster') unless
        @source_matrix.fetch('matrix').map { |record| record.fetch('id') } == expected.map { |profile| profile.fetch('id') }

      @profiles = expected.each_with_index.map do |profile, profile_index|
        stock = observed.fetch(profile.fetch('id'))
        profile.each do |key, value|
          fail!("stock profile #{profile.fetch('id')} disagrees on #{key}") unless stock.fetch(key) == value
        end
        expected_declared = declared_type(profile)
        fail!("stock profile #{profile.fetch('id')} declaration differs from independent shape law") unless stock.fetch('declared_type') == expected_declared
        validate_stock_case!(profile, stock)
        stock['table_name'] = format('safw221_t%03d', profile_index)
        stock['expected_declared_type'] = expected_declared
        @table_by_id[profile.fetch('id')] = stock.fetch('table_name')
        stock
      end

      @source_pin_record = {
        'source_matrix_path' => @source_matrix_path,
        'source_matrix_sha256' => Digest::SHA256.file(@source_matrix_path).hexdigest,
        'source_manifest_path' => File.join(@source_root, 'manifest.json'),
        'source_manifest_sha256' => Digest::SHA256.file(manifest_path).hexdigest,
        'source_snapshot' => "#{SOURCE_ROOT}@#{SOURCE_REVISION}",
        'runtime_identity' => @source_manifest.fetch('runtime_pin_expected'),
        'source_snapshot_is_not_asserted_to_build_runtime' => true,
      }
    end

    def validate_stock_case!(profile, record)
      fail!("stock profile #{profile.fetch('id')} is not physical_observed") unless record.fetch('classification') == 'physical_observed'
      fail!("stock profile #{profile.fetch('id')} row keys differ") unless record.fetch('row_keys') == ROW_KEYS
      expected_null_index = profile.fetch('shape') == 'scalar' ? nil : NULL_ROW_INDEX
      fail!("stock profile #{profile.fetch('id')} nullable row index differs") unless record.fetch('nullable_row_index') == expected_null_index
      rows = record.fetch('rowbinary_values')
      fail!("stock profile #{profile.fetch('id')} does not contain five raw rows") unless rows.length == ROW_KEYS.length
      rows.each_with_index do |row, index|
        fail!("stock profile #{profile.fetch('id')} row key differs") unless row.fetch('key') == ROW_KEYS.fetch(index)
        is_null = expected_null_index == index
        fail!("stock profile #{profile.fetch('id')} NULL placement differs") unless row.fetch('is_null') == is_null
        leaf_hex = row['leaf_value_rowbinary_hex']
        if is_null
          fail!("stock profile #{profile.fetch('id')} NULL row contains a leaf payload") unless leaf_hex.nil?
          value_bytes = "\x01".b
        else
          fail!("stock profile #{profile.fetch('id')} lacks a literal leaf value") unless leaf_hex.is_a?(String) && valid_hex?(leaf_hex)
          raw = [leaf_hex].pack('H*')
          value_bytes = if expected_null_index.nil?
                          raw
                        else
                          "\x00".b + raw
                        end
        end
        fail!("stock profile #{profile.fetch('id')} RowBinary bytes disagree with raw leaf/null literals") unless
          row.fetch('value_rowbinary_hex') == value_bytes.unpack1('H*')
      end

      physical = record.fetch('physical')
      fail!("stock profile #{profile.fetch('id')} is not a five-row Wide part") unless
        physical.fetch('rows') == 5 && physical.fetch('marks') == 4 && physical.fetch('part_type') == 'Wide'
      fail!("stock profile #{profile.fetch('id')} source metadata version is outside {0,1}") unless
        %w[0 1].include?(physical.fetch('metadata_version_txt'))
      fail!("stock profile #{profile.fetch('id')} source codec differs") unless physical.fetch('default_compression_codec_txt') == 'CODEC(LZ4)'
      expected_columns = "columns format version: 1\n2 columns:\n`k` UInt64\n`v` #{record.fetch('declared_type')}\n"
      fail!("stock profile #{profile.fetch('id')} columns.txt differs") unless physical.fetch('columns_txt') == expected_columns
      fail!("stock profile #{profile.fetch('id')} columns_substreams header differs") unless
        physical.fetch('columns_substreams_txt').start_with?("columns substreams version: 1\n2 columns:\n")
      serialization = physical.fetch('serialization_json')
      string_mode = profile['string_serialization_mode']
      expected_string_version = string_mode ? STRING_SETTINGS.fetch(string_mode).to_i : 1
      fail!("stock profile #{profile.fetch('id')} serialization propagation differs") unless
        serialization.fetch('propagate_types_serialization_versions_to_nested_types') == true
      fail!("stock profile #{profile.fetch('id')} native columns metadata differs") unless serialization.fetch('columns') == []
      fail!("stock profile #{profile.fetch('id')} String serialization version differs") unless
        serialization.fetch('types_serialization_versions') == {'string' => expected_string_version}
      fail!("stock profile #{profile.fetch('id')} Nullable-specific serialization metadata unexpectedly exists") if
        serialization.keys.any? { |key| key.downcase.include?('nullable') }
      fail!("stock profile #{profile.fetch('id')} serialization metadata version differs") unless serialization.fetch('version') == 1

      stock_part = File.join(@source_root, 'parts', profile.fetch('id'), 'all_1_1_0')
      fail!("stock physical path differs for #{profile.fetch('id')}") unless File.expand_path(physical.fetch('copied_part_path')) == stock_part
      fail!("stock copied part is absent/noncanonical for #{profile.fetch('id')}") unless
        File.directory?(stock_part) && !File.symlink?(stock_part) && File.realpath(stock_part) == stock_part
      actual_inventory = part_inventory(stock_part)
      fail!("stock copied part inventory differs from its matrix record for #{profile.fetch('id')}") unless
        actual_inventory == physical.fetch('part_file_inventory')
      fail!("stock profile #{profile.fetch('id')} has no compressed marks") unless actual_inventory.any? { |item| item.fetch('path').end_with?('.mrk2') }
      fail!("stock profile #{profile.fetch('id')} has unexpected legacy marks") if actual_inventory.any? { |item| item.fetch('path').match?(/\.mrk(?:\.|\z)/) }
      record['stock_part_path'] = stock_part
      record['stock_part_inventory_verified'] = true
      record['expected_source_string_version'] = expected_string_version
    end

    def valid_hex?(value)
      value.is_a?(String) && value.match?(/\A(?:[0-9a-f]{2})+\z/)
    end

    def part_inventory(part)
      files = []
      Find.find(part) do |path|
        next if path == part
        fail!("symbolic link in immutable W221 part: #{path}") if File.symlink?(path)
        next if File.directory?(path)
        fail!("unexpected non-file in immutable W221 part: #{path}") unless File.file?(path)
        files << {
          'path' => path.delete_prefix(part + File::SEPARATOR),
          'size' => File.size(path),
          'sha256' => Digest::SHA256.file(path).hexdigest,
        }
      end
      files.sort_by { |entry| entry.fetch('path') }
    end

    def write_run_manifest!
      manifest = {
        'suite' => 'W221 generic SimpleAggregateFunction Wide-part bulk compatibility',
        'source' => @source_pin_record,
        'runtime_expected' => runtime_pin_expected,
        'source_snapshot_is_not_asserted_to_build_runtime' => true,
        'coverage' => {
          'target_functions' => TARGET_FUNCTIONS,
          'leaf_count' => LEAVES.length,
          'selected_shapes' => SHAPES,
          'string_profiles' => STRING_MODES,
          'controls' => [
            'SimpleAggregateFunction(min, Nullable(UInt64))',
            'SimpleAggregateFunction(sum, Nullable(UInt64))',
            'SimpleAggregateFunction(sumWithOverflow, Nullable(Decimal(38, 5)))',
            'SimpleAggregateFunction(groupBitAnd, Nullable(Int32))',
            'SimpleAggregateFunction(groupBitOr, Nullable(Int32))',
            'SimpleAggregateFunction(groupBitXor, Nullable(Int32))',
          ],
          'case_count' => @profiles.length,
        },
        'stock_construction_law' => @source_manifest.fetch('stock_construction_law'),
        'input_parts_are_verified_against_stock_matrix_inventory' => true,
        'attachment_inventory_policy' => {
          'original_files' => 'every copied/generated part file must remain present and retain exact size and SHA-256 after ATTACH/CHECK/SELECT',
          'only_allowed_added_file' => ATTACHMENT_AUXILIARY_FILE,
          'added_file_exact_line_set' => ATTACHMENT_INVALIDATED_SYSTEM_COLUMNS,
          'added_file_line_order' => 'not constrained; ClickHouse serializes a NameSet',
          'source_basis' => [
            "#{SOURCE_ROOT}@#{SOURCE_REVISION}:src/Storages/MergeTree/MergeTreeData.cpp loadPartAndFixMetadataImpl calls writeInvalidatedSystemColumnsFile during ATTACH",
            "#{SOURCE_ROOT}@#{SOURCE_REVISION}:src/Storages/MergeTree/IMergeTreeDataPart.cpp getColumnsToInvalidate returns _block_number and _block_offset; writer emits one escaped name per line",
          ],
        },
        'expected_rows' => {
          'keys' => ROW_KEYS,
          'row_count' => 5,
          'reader_real_mark_rows' => [2, 2, 1],
          'native_clickhouse_marks_include_terminal_mark' => 4,
          'rowbinary_windows' => ['full', 'middle keys 22..44', 'empty where k=0'],
        },
        'metadata_law' => {
          'nullable_serialization' => 'basic',
          'propagate_types_serialization_versions_to_nested_types' => true,
          'library_types_serialization_versions' => {'string' => '0 for single_stream, 1 for with_size_stream'},
          'stock_native_string_serialization_version_by_profile_mode' => {
            'single_stream' => 0,
            'with_size_stream' => 1,
            'setting_omitted' => 1,
          },
          'library_string_serialization_version_when_profile_is_omitted' => 0,
          'nullable_specific_serialization_version_key' => 'not present',
          'stock_native_columns_metadata' => [],
          'library_columns_metadata' => [
            {'exact_num_defaults' => true, 'kind' => 'Default', 'name' => 'k', 'num_defaults' => 0, 'num_rows' => 5},
          ],
          'source_library_differences' => [
            'library serialization metadata includes the exact key-column Default entry; stock native metadata has an empty columns array',
            'when no string_serialization_version setting is supplied, stock native metadata reports string:1 while the library single_stream profile reports string:0',
            'explicit single_stream and with_size_stream String profiles match their native string serialization versions exactly',
          ],
          'metadata_version' => 'copied per profile from native metadata_version.txt (0 or 1)',
        },
        'process_policy' => {
          'clickhouse_timeout_seconds' => PROCESS_TIMEOUT_SECONDS,
          'helper_timeout_seconds' => HELPER_TIMEOUT_SECONDS,
          'child_process_group' => 'inherited from caller; direct child PID TERM/KILL only',
          'probe_or_library_failure_is_not_a_type_law_refusal' => true,
        },
      }
      write_json(File.join(@root, 'manifest.json'), manifest)
    end

    def classification_counts(records)
      records.each_with_object({}) do |record, counts|
        classification = record.fetch('classification', 'unclassified')
        counts[classification] = counts.fetch(classification, 0) + 1
      end
    end

    def write_summary(classification, error = nil)
      summary = {
        'format' => 'simple_aggregate_bulk_w221_summary_v1',
        'classification' => classification,
        'success' => classification == 'paired_simple_aggregate_bulk_observed',
        'error' => error || @fatal_error,
        'evidence_root' => @root,
        'source_matrix_path' => @source_matrix_path,
        'source_snapshot' => @source_pin_record && @source_pin_record['source_snapshot'],
        'source_matrix_sha256' => @source_pin_record && @source_pin_record['source_matrix_sha256'],
        'runtime_expected' => runtime_pin_expected,
        'runtime_observed' => @clickhouse_pin,
        'helper' => {
          'path' => @helper,
          'sha256_before' => @helper_sha_before,
          'sha256_after' => @helper_sha_after,
          'invocation_record' => @helper_invocation_record,
          'status' => @helper_status,
        },
        'counts' => {
          'expected_profiles' => 186,
          'validated_stock_profiles' => @profiles.length,
          'helper_profiles' => @helper_profiles.length,
          'helper_classifications' => classification_counts(@helper_profiles),
          'generated_library_parts' => @generated_parts.length,
          'native_target_tables' => @target_paths.length,
          'native_cases' => @case_records.length,
          'native_classifications' => classification_counts(@case_records),
          'recorded_process_invocations' => @recorder ? @recorder.invocation_count : 0,
        },
        'partial_failure_evidence' => {
          'invocations_directory' => 'invocations/',
          'generated_directory' => 'generated/',
          'cases_directory' => 'cases/',
          'case_records_written_as_they_complete' => true,
          'summary_uses_exclusive_create' => true,
        },
      }
      write_json(File.join(@root, 'summary.json'), summary)
    end

    def binary_sha(path)
      Digest::SHA256.file(path).hexdigest
    end

    def pin_clickhouse!
      actual_sha = binary_sha(@binary)
      fail!('ClickHouse executable SHA-256 differs from task-scoped runtime pin') unless actual_sha == CLICKHOUSE_SHA256
      version_store = File.join(@root, 'stores', 'native')
      version_result = @recorder.run_clickhouse('pin-version', version_store, 'SELECT version() FORMAT TSVRaw')
      assert_process_success!(version_result, 'ClickHouse version pin')
      version = version_result.fetch(:stdout).strip
      fail!("ClickHouse version differs: #{version.inspect}") unless version == VERSION
      build_result = @recorder.run_clickhouse('pin-build', version_store,
        "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw")
      assert_process_success!(build_result, 'ClickHouse build pin')
      build = build_result.fetch(:stdout).strip
      fail!("ClickHouse build differs: #{build.inspect}") unless build == "VERSION_GITHASH=#{BUILD_HASH}"
      @clickhouse_pin = {'version' => version, 'build_hash' => BUILD_HASH, 'sha256' => actual_sha}
      write_json(File.join(@root, 'runtime_pin.json'), {
        'runtime' => @clickhouse_pin,
        'source_snapshot' => "#{SOURCE_ROOT}@#{SOURCE_REVISION}",
        'source_snapshot_is_not_asserted_to_build_runtime' => true,
      })
    end

    def pin_helper!
      @helper_sha_before = binary_sha(@helper)
      write_json(File.join(@root, 'helper_pin.json'), {
        'path' => @helper,
        'sha256_before' => @helper_sha_before,
        'prebuilt' => true,
        'compiled_by_this_runner' => false,
      })
    end

    def verify_executable_pins!
      fail!('ClickHouse executable SHA changed during the run') unless binary_sha(@binary) == @clickhouse_pin.fetch('sha256')
      @helper_sha_after = binary_sha(@helper)
      fail!('prebuilt Crystal helper SHA changed during the run') unless @helper_sha_after == @helper_sha_before
    end

    def helper_input_profile(profile, index)
      mode = profile['string_serialization_mode'] || 'single_stream'
      source_version = profile.fetch('physical').fetch('serialization_json').fetch('types_serialization_versions').fetch('string')
      validated_source_version = profile.fetch('expected_source_string_version')
      fail!("stock String serialization version differs from its validated matrix record for #{profile.fetch('id')}") unless source_version == validated_source_version
      source_mode = STRING_SETTINGS.key(source_version)
      expected_source_mode = profile['string_serialization_mode'] || 'with_size_stream'
      fail!("validated stock String serialization version is outside {0,1} for #{profile.fetch('id')}") unless source_mode
      fail!("stock String serialization mode differs from validated metadata for #{profile.fetch('id')}") unless source_mode == expected_source_mode
      profile_root = File.join(@root, 'generated', 'parts', format('%03d-%s', index, safe_label(profile.fetch('id'))))
      Dir.mkdir(profile_root, 0o700)
      values = profile.fetch('rowbinary_values').map do |row|
        leaf_hex = row['leaf_value_rowbinary_hex']
        {
          'key' => row.fetch('key'),
          'is_null' => row.fetch('is_null'),
          'value_rowbinary_hex' => row.fetch('value_rowbinary_hex'),
          'leaf_value_rowbinary_hex' => leaf_hex || '',
        }
      end
      {
        'id' => profile.fetch('id'),
        'kind' => profile.fetch('kind'),
        'function' => profile.fetch('function'),
        'leaf_key' => profile.fetch('leaf_key'),
        'leaf_type' => profile.fetch('leaf_type'),
        'shape' => profile.fetch('shape'),
        'string_serialization_mode' => mode,
        'source_string_serialization_mode' => source_mode,
        'declared_type' => profile.fetch('expected_declared_type'),
        'metadata_version' => profile.fetch('physical').fetch('metadata_version_txt'),
        'source_part' => profile.fetch('stock_part_path'),
        'library_part' => File.join(profile_root, 'all_1_1_0'),
        'rowbinary_values' => values,
      }
    end

    def build_helper_input!
      input = {
        'format' => FORMAT_INPUT,
        'capture_root' => @source_root,
        'profiles' => @profiles.each_with_index.map { |profile, index| helper_input_profile(profile, index) },
      }
      @helper_input_path = File.join(@root, 'generated', 'helper-input.json')
      write_json(@helper_input_path, input)
      @helper_input_sha = Digest::SHA256.file(@helper_input_path).hexdigest
    end

    def invoke_crystal_helper!
      result = @recorder.run_helper('generic-stock-read-library-write-read', @helper_input_path,
        File.join(@root, 'generated'), @source_root)
      @helper_invocation_record = result.fetch(:record)
      @helper_status = result.fetch(:status)
      fail!('prebuilt Crystal helper did not return its structured output') if result.fetch(:stdout).strip.empty?
      begin
        parsed = JSON.parse(result.fetch(:stdout))
      rescue JSON::ParserError => error
        fail!("prebuilt Crystal helper stdout was not one JSON value: #{error.message}")
      end
      fail!('Crystal helper output format differs') unless parsed.fetch('format') == FORMAT_HELPER
      fail!('Crystal helper did not report exactly 186 cases') unless parsed.fetch('profile_count') == 186 && parsed.fetch('profiles').length == 186
      @helper_profiles = parsed.fetch('profiles')
      expected_ids = @profiles.map { |profile| profile.fetch('id') }
      fail!('Crystal helper profile roster/order differs') unless @helper_profiles.map { |profile| profile.fetch('id') } == expected_ids
      @helper_profiles.each_with_index do |profile, index|
        if profile.fetch('classification') == 'physical_observed'
          expected_source = @profiles.fetch(index)
          expected_source_mode = STRING_SETTINGS.key(expected_source.fetch('expected_source_string_version'))
          expected_library_mode = expected_source['string_serialization_mode'] || 'single_stream'
          fail!("validated stock String serialization version is outside {0,1} for #{profile.fetch('id')}") unless expected_source_mode
          stock = profile.fetch('stock')
          library = profile.fetch('library')
          fail!("helper stock source mode differs for #{profile.fetch('id')}") unless
            profile.fetch('source_string_serialization_mode') == expected_source_mode
          fail!("helper library mode differs for #{profile.fetch('id')}") unless
            profile.fetch('string_serialization_mode') == expected_library_mode
          fail!("stock reader ordinary profile differs for #{profile.fetch('id')}") unless
            stock.fetch('ordinary_profile') == expected_source_mode
          fail!("library writer/reader ordinary profile differs for #{profile.fetch('id')}") unless
            library.fetch('ordinary_profile') == expected_library_mode
          profile['ordinary_profile_evidence'] = {
            'stock_source_expected' => expected_source_mode,
            'stock_source_observed' => stock.fetch('ordinary_profile'),
            'stock_expectation_basis' => "validated stock serialization.json string version #{expected_source.fetch('expected_source_string_version')}",
            'library_writer_reader_expected' => expected_library_mode,
            'library_writer_reader_observed' => library.fetch('ordinary_profile'),
            'library_expectation_basis' => 'selected library writer profile',
            'profiles_differ' => expected_source_mode != expected_library_mode,
          }
          source_streams = stock.fetch('physical_stream_names')
          library_streams = library.fetch('physical_stream_names')
          fail!("helper source/library stream roster differs for #{profile.fetch('id')}") unless source_streams == library_streams
          generated = File.expand_path(profile.fetch('library_part_path'))
          fail!("helper library path escaped generated output for #{profile.fetch('id')}") unless generated.start_with?(File.join(@root, 'generated') + File::SEPARATOR)
          fail!("helper library part is absent/noncanonical for #{profile.fetch('id')}") unless File.directory?(generated) && !File.symlink?(generated) && File.realpath(generated) == generated
          @generated_parts[profile.fetch('id')] = generated
          @generated_inventories[profile.fetch('id')] = part_inventory(generated)
          fail!("generated part has no inventory for #{profile.fetch('id')}") if @generated_inventories.fetch(profile.fetch('id')).empty?
          profile['library_part_inventory'] = @generated_inventories.fetch(profile.fetch('id'))
          profile['library_part_sha256_by_file'] = @generated_inventories.fetch(profile.fetch('id'))
        end
      end
      write_json(File.join(@root, 'generated', 'helper-output.json'), parsed)
      write_json(File.join(@root, 'generated', 'helper-process.json'), {
        'invocation_record' => @helper_invocation_record,
        'status' => @helper_status,
      })
      fail!('Crystal helper process failed despite structured output') unless
        @helper_status.fetch('success') && !@helper_status.fetch('timed_out') && !@helper_status.fetch('signaled') && !@helper_status['spawn_error']
      fail!('one or more source/library bulk cases did not physically validate') unless @helper_profiles.all? { |profile| profile.fetch('classification') == 'physical_observed' }
    end

    def create_native_targets!
      statements = []
      @profiles.each do |profile|
        table = profile.fetch('table_name')
        settings = STOCK_SETTINGS.dup
        mode = profile['string_serialization_mode']
        settings << "string_serialization_version='#{mode}'" if mode
        statements << "CREATE TABLE default.#{table} (k UInt64, v #{profile.fetch('expected_declared_type')}) ENGINE=MergeTree ORDER BY k SETTINGS #{settings.join(', ')};"
      end
      tables = @profiles.map { |profile| "'#{profile.fetch('table_name')}'" }.join(',')
      statements << "SELECT '__W221_TARGET_PATH__', name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name IN (#{tables}) ORDER BY name FORMAT TSVRaw;"
      statements << "SELECT '__W221_SCHEMA__', table, name, type, toString(position) FROM system.columns WHERE database='default' AND table IN (#{tables}) ORDER BY table, position FORMAT TSVRaw;"
      result = @recorder.run_clickhouse('create-186-native-targets', @store, statements.join("\n") + "\n", multiquery: true)
      assert_process_success!(result, 'native target table creation')
      path_rows = tagged_rows(result.fetch(:stdout), '__W221_TARGET_PATH__')
      fail!("expected 186 native target data paths, got #{path_rows.length}") unless path_rows.length == @profiles.length
      path_rows.each do |row|
        fail!("malformed native target data path row: #{row.inspect}") unless row.length == 3
        table = row[1]
        profile = @profiles.find { |candidate| candidate.fetch('table_name') == table } || fail!("unexpected target table #{table.inspect}")
        path = contained_path(row[2], @store, "native table path for #{table}")
        @target_paths[profile.fetch('id')] = path
      end
      fail!('not every native target table path was discovered') unless @target_paths.length == 186

      schema_rows = tagged_rows(result.fetch(:stdout), '__W221_SCHEMA__')
      expected_schema = []
      @profiles.each do |profile|
        table = profile.fetch('table_name')
        expected_schema << ['__W221_SCHEMA__', table, 'k', 'UInt64', '1']
        expected_schema << ['__W221_SCHEMA__', table, 'v', profile.fetch('expected_declared_type'), '2']
      end
      expected_schema.sort_by! { |row| [row[1], row[4]] }
      fail!('native system.columns declarations differ from the exact 186 stock declarations') unless schema_rows == expected_schema
      write_json(File.join(@root, 'native-targets.json'), {
        'table_count' => @profiles.length,
        'table_paths' => @target_paths,
        'system_columns_rows' => schema_rows.length,
        'invocation' => result.fetch(:record),
      })
    end

    def attach_and_verify_all!
      @profiles.each_with_index do |profile, index|
        puts "W221 generic bulk case #{index + 1}/#{@profiles.length}: #{profile.fetch('id')}"
        @case_records << attach_and_verify_case(profile)
      end
      write_json(File.join(@root, 'cases', 'matrix.json'), {
        'case_count' => @case_records.length,
        'observed' => @case_records.count { |record| record.fetch('classification') == 'physical_observed' },
        'mismatches' => @case_records.count { |record| record.fetch('classification') != 'physical_observed' },
        'matrix' => @case_records,
      })
      fail!('not all 186 native attach/RowBinary checks passed') unless
        @case_records.length == 186 && @case_records.all? { |record| record.fetch('classification') == 'physical_observed' }
    end

    def attach_and_verify_case(profile)
      id = profile.fetch('id')
      table = profile.fetch('table_name')
      before = nil
      after = nil
      attachment_delta = nil
      generated_after = nil
      active_path = nil
      result = nil
      data_path = @target_paths.fetch(id)
      case_dir = File.join(@root, 'cases', 'profiles', format('%03d-%s', @case_records.length, safe_label(id)))
      Dir.mkdir(case_dir, 0o700)
      detached = File.join(data_path, 'detached')
      if File.exist?(detached)
        fail!("target detached directory already exists for #{id}") if File.symlink?(detached) || !File.directory?(detached)
      else
        Dir.mkdir(detached, 0o700)
      end
      detached_real = File.realpath(detached)
      fail!("detached directory escaped table root for #{id}") unless detached_real.start_with?(data_path + File::SEPARATOR)
      detached_part = File.join(detached_real, 'all_1_1_0')
      active_expected = File.join(data_path, 'all_1_1_0')
      fail!("refusing to replace a target detached part for #{id}") if File.exist?(detached_part) || File.symlink?(detached_part)
      fail!("active part path already exists before attach for #{id}") if File.exist?(active_expected) || File.symlink?(active_expected)
      source_part = @generated_parts.fetch(id)
      FileUtils.cp_r(source_part, detached_part)
      detached_part = File.realpath(detached_part)
      before = part_inventory(detached_part)
      fail!("copied target part differs from generated library part for #{id}") unless before == @generated_inventories.fetch(id)
      @target_inventories[id] = before

      outputs = {
        'full' => File.join(case_dir, 'rowbinary-full.bin'),
        'middle' => File.join(case_dir, 'rowbinary-middle.bin'),
        'empty' => File.join(case_dir, 'rowbinary-empty.bin'),
      }
      outputs.each_value do |path|
        fail!("refusing to overwrite RowBinary output #{path}") if File.exist?(path) || File.symlink?(path)
      end
      escaped = lambda { |path| path.gsub("'", "\\'") }
      sql = [
        "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0';",
        "CHECK TABLE default.#{table} FORMAT TSV;",
        "SELECT '__W221_SCHEMA__', name, type, toString(position) FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;",
        "SELECT '__W221_TYPE__', toTypeName(k), toTypeName(v) FROM default.#{table} LIMIT 1 FORMAT TSVRaw;",
        "SELECT '__W221_PART__', name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;",
        "SELECT k, v FROM default.#{table} ORDER BY k INTO OUTFILE '#{escaped.call(outputs.fetch('full'))}' FORMAT RowBinary;",
        "SELECT k, v FROM default.#{table} WHERE k BETWEEN 22 AND 44 ORDER BY k INTO OUTFILE '#{escaped.call(outputs.fetch('middle'))}' FORMAT RowBinary;",
        "SELECT k, v FROM default.#{table} WHERE k=0 ORDER BY k INTO OUTFILE '#{escaped.call(outputs.fetch('empty'))}' FORMAT RowBinary;",
      ].join("\n") + "\n"
      result = @recorder.run_clickhouse("#{id}-attach-check-rowbinary", @store, sql, multiquery: true)
      assert_process_success!(result, "native attach/check for #{id}")
      active_path = attached_part_path!(result.fetch(:stdout), active_expected, id)
      after = part_inventory(active_path)
      attachment_delta = validate_attachment_inventory_delta!(before, after, active_path, id)
      generated_after = part_inventory(source_part)
      fail!("generated library part changed during attach for #{id}") unless generated_after == @generated_inventories.fetch(id)
      observed = validate_attached_output!(profile, result.fetch(:stdout), outputs, active_expected, active_path)
      record = {
        'id' => id,
        'table_name' => table,
        'declared_type' => profile.fetch('expected_declared_type'),
        'classification' => 'physical_observed',
        'generated_part_path' => source_part,
        'attached_part_path' => active_path,
        'generated_part_inventory_before_attach' => @generated_inventories.fetch(id),
        'generated_part_inventory_after_attach' => generated_after,
        'copied_part_inventory_before_attach' => before,
        'attached_part_inventory_after_operations' => after,
        'attachment_inventory_delta' => attachment_delta,
        'native_metadata' => observed.fetch(:metadata),
        'rowbinary' => observed.fetch(:rowbinary),
        'invocation' => result.fetch(:record),
        'process_status' => result.fetch(:status),
      }
      write_json(File.join(case_dir, 'case.json'), record)
      record
    rescue StandardError => error
      record = {
        'id' => profile.fetch('id'),
        'table_name' => profile.fetch('table_name'),
        'declared_type' => profile.fetch('expected_declared_type'),
        'classification' => 'probe_failure',
        'not_a_type_law_refusal' => true,
        'error' => "#{error.class}: #{error.message}",
      }
      record['generated_part_path'] = @generated_parts[id] if @generated_parts[id]
      record['attached_part_path'] = active_path if active_path
      record['generated_part_inventory_before_attach'] = @generated_inventories[id] if @generated_inventories[id]
      record['generated_part_inventory_after_attach'] = generated_after if generated_after
      record['copied_part_inventory_before_attach'] = before if before
      record['attached_part_inventory_after_operations'] = after if after
      record['attachment_inventory_delta'] = attachment_delta if attachment_delta
      record['invocation'] = result.fetch(:record) if result
      record['process_status'] = result.fetch(:status) if result
      if File.directory?(case_dir) && !File.exist?(File.join(case_dir, 'case.json'))
        write_json(File.join(case_dir, 'case.json'), record)
      end
      record
    end

    def attached_part_path!(stdout, target_part, id)
      part_rows = tagged_rows(stdout, '__W221_PART__')
      fail!("expected one active part for #{id}: #{part_rows.inspect}") unless part_rows.length == 1 && part_rows.first.length == 6
      part_name, rows_text, marks_text, part_type, path_text = part_rows.first.drop(1)
      fail!("attached part census differs for #{id}") unless part_name == 'all_1_1_0' && rows_text == '5' && marks_text == '4' && part_type == 'Wide'
      check_lines = stdout.force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp).select { |line| line.start_with?("all_1_1_0\t") }
      fail!("CHECK TABLE did not report a clean attached part for #{id}: #{check_lines.inspect}") unless check_lines == ["all_1_1_0\t1\t"]
      active_path = contained_path(path_text, @store, "active part path for #{id}")
      fail!("active part path differs from just-attached path for #{id}") unless active_path == target_part
      active_path
    end

    def validate_attachment_inventory_delta!(before, after, part, id)
      before_by_path = before.each_with_object({}) { |entry, result| result[entry.fetch('path')] = entry }
      after_by_path = after.each_with_object({}) { |entry, result| result[entry.fetch('path')] = entry }
      fail!("duplicate file path in pre-attach inventory for #{id}") unless before_by_path.length == before.length
      fail!("duplicate file path in attached inventory for #{id}") unless after_by_path.length == after.length
      removed = before_by_path.keys - after_by_path.keys
      added = after_by_path.keys - before_by_path.keys
      changed = (before_by_path.keys & after_by_path.keys).select do |path|
        before_by_path.fetch(path) != after_by_path.fetch(path)
      end
      fail!("ATTACH removed part files for #{id}: #{removed.inspect}") unless removed.empty?
      fail!("ATTACH changed original part files for #{id}: #{changed.inspect}") unless changed.empty?
      fail!("ATTACH added files outside the exact invalidation policy for #{id}: #{added.inspect}") unless
        added == [ATTACHMENT_AUXILIARY_FILE]
      aux = after_by_path.fetch(ATTACHMENT_AUXILIARY_FILE)
      bytes = File.binread(File.join(part, ATTACHMENT_AUXILIARY_FILE))
      fail!("invalidated system columns file lacks one final newline for #{id}") unless bytes.end_with?("\n")
      lines = bytes.split("\n", -1)
      fail!("invalidated system columns file is not exactly two terminated names for #{id}") unless lines.pop == '' && lines.length == 2
      fail!("invalidated system columns file has unexpected or duplicate names for #{id}: #{lines.inspect}") unless
        lines.uniq.sort == ATTACHMENT_INVALIDATED_SYSTEM_COLUMNS.sort
      actual_aux = {
        'path' => ATTACHMENT_AUXILIARY_FILE,
        'size' => bytes.bytesize,
        'sha256' => Digest::SHA256.hexdigest(bytes),
        'content_utf8' => bytes.dup.force_encoding(Encoding::UTF_8).scrub,
        'lines_unordered' => lines.sort,
      }
      fail!("invalidated system columns inventory differs from its bytes for #{id}") unless aux == actual_aux.reject { |key, _value| key == 'content_utf8' || key == 'lines_unordered' }
      {
        'removed_paths' => removed,
        'changed_original_paths' => changed,
        'added_paths' => added,
        'added_file' => actual_aux,
        'all_preexisting_file_hashes_and_sizes_preserved' => true,
        'only_source_backed_auxiliary_addition' => true,
      }
    end

    def validate_attached_output!(profile, stdout, outputs, target_part, active_path)
      id = profile.fetch('id')
      table = profile.fetch('table_name')
      declared = profile.fetch('expected_declared_type')
      schema = tagged_rows(stdout, '__W221_SCHEMA__')
      expected_schema = [
        ['__W221_SCHEMA__', 'k', 'UInt64', '1'],
        ['__W221_SCHEMA__', 'v', declared, '2'],
      ]
      fail!("attached system.columns declaration differs for #{id}: #{schema.inspect}") unless schema == expected_schema
      type = tagged_rows(stdout, '__W221_TYPE__')
      fail!("attached runtime toTypeName differs for #{id}: #{type.inspect}") unless type == [['__W221_TYPE__', 'UInt64', declared]]
      fail!("active part path differs from just-attached path for #{id}") unless active_path == target_part

      native_metadata = inspect_part_metadata(profile, active_path)
      outputs_expected = {
        'full' => (0...ROW_KEYS.length).to_a,
        'middle' => [1, 2, 3],
        'empty' => [],
      }
      rowbinary = {}
      outputs_expected.each do |window, indices|
        path = outputs.fetch(window)
        fail!("ClickHouse did not create #{window} RowBinary output for #{id}") unless File.file?(path) && !File.symlink?(path)
        actual = File.binread(path)
        expected = expected_rowbinary(profile, indices)
        mismatch = compare_binary(actual, expected)
        fail!("#{window} RowBinary differs for #{id}: #{mismatch}") if mismatch
        rowbinary[window] = {
          'path' => path.delete_prefix(@root + File::SEPARATOR),
          'bytes' => actual.bytesize,
          'sha256' => Digest::SHA256.hexdigest(actual),
          'expected_bytes' => expected.bytesize,
          'expected_sha256' => Digest::SHA256.hexdigest(expected),
          'matches_independent_raw_leaf_manifest' => true,
        }
      end
      {active_path: active_path, metadata: native_metadata, rowbinary: rowbinary}
    end

    def expected_library_serialization(profile)
      expected_string_version = STRING_SETTINGS.fetch(profile['string_serialization_mode'] || 'single_stream').to_i
      {
        'columns' => [
          {'exact_num_defaults' => true, 'kind' => 'Default', 'name' => 'k', 'num_defaults' => 0, 'num_rows' => 5},
        ],
        'propagate_types_serialization_versions_to_nested_types' => true,
        'types_serialization_versions' => {'string' => expected_string_version},
        'version' => 1,
      }
    end

    def parse_columns_substreams(text, id, label)
      fail!("#{label} columns_substreams.txt is not newline-terminated for #{id}") unless text.end_with?("\n")
      fail!("#{label} columns_substreams.txt contains a carriage return for #{id}") if text.include?("\r")
      lines = text.lines.map(&:chomp)
      fail!("#{label} columns_substreams.txt version/header differs for #{id}") unless
        lines.shift == 'columns substreams version: 1' && lines.shift == '2 columns:'
      roster = {}
      %w[k v].each do |expected_column|
        header = lines.shift
        match = /\A([1-3]) substreams for column `([^`]+)`:\z/.match(header.to_s)
        fail!("#{label} columns_substreams.txt has malformed column header for #{id}: #{header.inspect}") unless match
        count = Integer(match[1], 10)
        column = match[2]
        fail!("#{label} columns_substreams.txt column order/name differs for #{id}: #{column.inspect}") unless column == expected_column
        max_count = column == 'k' ? 1 : 3
        fail!("#{label} columns_substreams.txt has excessive stream count for #{id}/#{column}: #{count}") unless count <= max_count
        names = Array.new(count) do
          line = lines.shift
          entry = /\A\t([^\t\r\n]+)\z/.match(line.to_s)
          fail!("#{label} columns_substreams.txt has malformed substream entry for #{id}: #{line.inspect}") unless entry
          entry[1]
        end
        fail!("#{label} columns_substreams.txt has duplicate entries for #{id}/#{column}") unless names.uniq.length == names.length
        roster[column] = names.sort
      end
      fail!("#{label} columns_substreams.txt has trailing records for #{id}: #{lines.inspect}") unless lines.empty?
      roster
    rescue ArgumentError => error
      fail!("#{label} columns_substreams.txt count is malformed for #{id}: #{error.message}")
    end

    def inspect_part_metadata(profile, part)
      physical = profile.fetch('physical')
      id = profile.fetch('id')
      inventory = part_inventory(part)
      names = inventory.map { |item| item.fetch('path') }
      required = %w[columns.txt columns_substreams.txt count.txt checksums.txt serialization.json default_compression_codec.txt metadata_version.txt primary.idx]
      missing = required - names
      fail!("attached native part metadata is missing #{missing.inspect} for #{id}") unless missing.empty?
      columns = File.binread(File.join(part, 'columns.txt')).force_encoding(Encoding::UTF_8).scrub
      substreams = File.binread(File.join(part, 'columns_substreams.txt')).force_encoding(Encoding::UTF_8).scrub
      serialization_text = File.binread(File.join(part, 'serialization.json')).force_encoding(Encoding::UTF_8).scrub
      serialization = JSON.parse(serialization_text)
      codec = File.binread(File.join(part, 'default_compression_codec.txt')).strip
      metadata_version = File.binread(File.join(part, 'metadata_version.txt')).strip
      count = File.binread(File.join(part, 'count.txt')).strip
      checksums_text = File.binread(File.join(part, 'checksums.txt')).force_encoding(Encoding::UTF_8).scrub
      fail!("attached columns.txt differs from the native source for #{id}") unless columns == physical.fetch('columns_txt')
      stock_value_substreams = profile.fetch('shape') == 'scalar' ? %w[v] : %w[v v.null]
      library_value_substreams = stock_value_substreams.dup
      if profile.fetch('leaf_type') == 'String'
        stock_string_mode = STRING_SETTINGS.key(profile.fetch('expected_source_string_version'))
        library_string_mode = profile['string_serialization_mode'] || 'single_stream'
        fail!("stock String serialization mode is not independently mapped for #{id}") unless stock_string_mode
        stock_value_substreams << 'v.size' if stock_string_mode == 'with_size_stream'
        library_value_substreams << 'v.size' if library_string_mode == 'with_size_stream'
      end
      expected_stock_substreams = {'k' => %w[k], 'v' => stock_value_substreams.sort}
      expected_library_substreams = {'k' => %w[k], 'v' => library_value_substreams.sort}
      source_substreams = parse_columns_substreams(physical.fetch('columns_substreams_txt'), id, 'stock source')
      attached_substreams = parse_columns_substreams(substreams, id, 'attached library part')
      fail!("stock source substream roster differs from the independently expected shape/profile for #{id}: #{source_substreams.inspect}") unless source_substreams == expected_stock_substreams
      fail!("attached substream roster differs from the exact shape/profile roster for #{id}: #{attached_substreams.inspect}") unless attached_substreams == expected_library_substreams
      expected_serialization = expected_library_serialization(profile)
      fail!("attached library serialization metadata differs from the independently declared writer policy for #{id}") unless
        serialization == expected_serialization
      fail!("attached serialization metadata unexpectedly adds Nullable version for #{id}") if serialization.keys.any? { |key| key.downcase.include?('nullable') }
      source_serialization = physical.fetch('serialization_json')
      source_without_columns = source_serialization.reject { |key, _value| key == 'columns' }
      library_without_columns = serialization.reject { |key, _value| key == 'columns' }
      string_mode_omitted = profile['string_serialization_mode'].nil?
      if string_mode_omitted
        source_without_string_version = source_without_columns.reject { |key, _value| key == 'types_serialization_versions' }
        library_without_string_version = library_without_columns.reject { |key, _value| key == 'types_serialization_versions' }
        fail!("serialization metadata beyond the measured omitted-setting String default differs for #{id}") unless
          source_without_string_version == library_without_string_version
        fail!("omitted-setting source/library String version difference differs for #{id}") unless
          source_serialization.fetch('types_serialization_versions') == {'string' => 1} &&
          serialization.fetch('types_serialization_versions') == {'string' => 0}
      else
        fail!("non-columns serialization metadata differs from native source for #{id}") unless
          source_without_columns == library_without_columns
      end
      fail!("native source columns metadata was not the measured empty array for #{id}") unless source_serialization.fetch('columns') == []
      fail!("attached metadata_version.txt differs from the native source for #{id}") unless metadata_version == physical.fetch('metadata_version_txt')
      fail!("attached codec differs for #{id}") unless codec == 'CODEC(LZ4)' && codec == physical.fetch('default_compression_codec_txt')
      fail!("attached count.txt differs for #{id}") unless count == '5'
      {
        'columns_txt' => columns,
        'columns_substreams_txt' => substreams,
        'columns_substreams_validation' => {
          'expected_stock_roster' => expected_stock_substreams,
          'expected_library_roster' => expected_library_substreams,
          'stock_source_roster' => source_substreams,
          'attached_library_roster' => attached_substreams,
          'stock_source_text' => physical.fetch('columns_substreams_txt'),
          'attached_library_text' => substreams,
          'line_order_is_not_part_of_roster_equality' => true,
          'text_order_differs' => physical.fetch('columns_substreams_txt') != substreams,
        },
        'source_serialization_json' => source_serialization,
        'expected_library_serialization_json' => expected_serialization,
        'serialization_json' => serialization,
        'serialization_json_sha256' => Digest::SHA256.hexdigest(serialization_text.b),
        'source_library_serialization_columns' => {
          'source' => source_serialization.fetch('columns'),
          'library' => serialization.fetch('columns'),
        },
        'source_library_string_serialization_versions' => {
          'source' => source_serialization.fetch('types_serialization_versions'),
          'library' => serialization.fetch('types_serialization_versions'),
          'expected_omitted_setting_difference' => string_mode_omitted,
        },
        'non_columns_fields_except_measured_omitted_string_default_match_source' => true,
        'metadata_version_txt' => metadata_version,
        'default_compression_codec_txt' => codec,
        'count_txt' => count,
        'checksums_sha256' => Digest::SHA256.hexdigest(checksums_text.b),
        'file_inventory' => inventory,
        'source_columns_match' => true,
        'source_substreams_match' => true,
        'source_library_serialization_metadata_exact_match' => false,
      }
    end

    def expected_rowbinary(profile, indices)
      values = profile.fetch('rowbinary_values')
      output = +''.b
      indices.each do |index|
        row = values.fetch(index)
        key = row.fetch('key')
        output << [key].pack('Q<')
        leaf_hex = row['leaf_value_rowbinary_hex']
        if row.fetch('is_null')
          value_bytes = "\x01".b
        else
          raw_leaf = [leaf_hex].pack('H*')
          value_bytes = profile.fetch('shape') == 'scalar' ? raw_leaf : "\x00".b + raw_leaf
        end
        fail!("independent RowBinary composition differs from source literal for #{profile.fetch('id')}/#{index}") unless
          value_bytes.unpack1('H*') == row.fetch('value_rowbinary_hex')
        output << value_bytes
      end
      output
    end

    def compare_binary(actual, expected)
      return nil if actual.b == expected.b
      shared = [actual.bytesize, expected.bytesize].min
      mismatch = (0...shared).find { |index| actual.getbyte(index) != expected.getbyte(index) } || shared
      wanted = mismatch < expected.bytesize ? expected.getbyte(mismatch).to_s(16).rjust(2, '0') : '<eof>'
      observed = mismatch < actual.bytesize ? actual.getbyte(mismatch).to_s(16).rjust(2, '0') : '<eof>'
      "expected #{expected.bytesize} bytes, observed #{actual.bytesize}; first difference at #{mismatch}: expected #{wanted}, got #{observed}"
    end

    def contained_path(path, root, label)
      root_real = File.realpath(root)
      expanded = File.expand_path(path, root)
      real = File.realpath(expanded)
      fail!("#{label} escaped the native store: #{real}") unless real.start_with?(root_real + File::SEPARATOR)
      real
    rescue Errno::ENOENT, Errno::EACCES => error
      fail!("cannot resolve #{label} safely: #{error.message}")
    end

    def tagged_rows(stdout, tag)
      stdout.dup.force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp).map do |line|
        fields = line.split("\t", -1)
        fields if fields.first == tag
      end.compact
    end

    def assert_process_success!(result, label)
      status = result.fetch(:status)
      fail!("#{label} failed; timeout/spawn/nonzero is not a type refusal: #{status.inspect}; #{output_excerpt(result.fetch(:stdout) + result.fetch(:stderr))}") unless
        status.fetch('success') && !status.fetch('timed_out') && !status.fetch('signaled') && !status['spawn_error']
    end

    def output_excerpt(bytes)
      bytes.dup.force_encoding(Encoding::UTF_8).scrub.lines.map(&:strip).reject(&:empty?).first(6).join(' | ')
    end
  end

  class Recorder
    def initialize(probe, root, binary)
      @probe = probe
      @root = root
      @binary = binary
      @sequence = 0
    end

    def invocation_count
      @sequence
    end

    def run_clickhouse(label, store, sql, multiquery: false)
      argv = [@binary, 'local', '--path', store, '--session_timezone=UTC', '--enable_time_time64_type=1',
        '--max_threads=1', '--max_insert_threads=1', '--max_execution_time=60',
        "--max_memory_usage=#{RecheckSimpleAggregateBulkW221::MEMORY_LIMIT_BYTES}"]
      argv << '--multiquery' if multiquery
      argv.concat(['--query', sql])
      run_recorded(label, argv, timeout: RecheckSimpleAggregateBulkW221::PROCESS_TIMEOUT_SECONDS, sql: sql)
    end

    def run_helper(label, input_path, output_root, capture_root)
      argv = [@probe.instance_variable_get(:@helper), input_path, output_root, capture_root]
      run_recorded(label, argv, timeout: RecheckSimpleAggregateBulkW221::HELPER_TIMEOUT_SECONDS,
        extra: {'input_path' => input_path, 'input_sha256' => Digest::SHA256.file(input_path).hexdigest})
    end

    private

    def run_recorded(label, argv, timeout:, sql: nil, extra: {})
      @sequence += 1
      stem = format('%05d-%s', @sequence, label.gsub(/[^A-Za-z0-9_.-]/, '_'))
      prefix = File.join(@root, 'invocations', stem)
      @probe.write_new(prefix + '.argv.json', JSON.pretty_generate({
        'argv' => argv,
        'environment' => {'TZ' => 'UTC'},
        'timeout_seconds' => timeout,
        'process_group' => 'inherited',
      }.merge(extra)) + "\n")
      @probe.write_new(prefix + '.sql', (sql.end_with?("\n") ? sql : sql + "\n").b) if sql
      result = run_bounded(argv, timeout: timeout)
      @probe.write_new(prefix + '.stdout', result.fetch(:stdout))
      @probe.write_new(prefix + '.stderr', result.fetch(:stderr))
      @probe.write_new(prefix + '.status.json', JSON.pretty_generate(result.fetch(:status)) + "\n")
      {stdout: result.fetch(:stdout), stderr: result.fetch(:stderr), status: result.fetch(:status), record: prefix.delete_prefix(@root + File::SEPARATOR)}
    end

    def run_bounded(argv, timeout:)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stdin = stdout = stderr = nil
      waiter = nil
      readers = []
      stdout_bytes = ''.b
      stderr_bytes = ''.b
      timed_out = false
      spawn_error = nil
      status = nil
      begin
        # No pgroup/session option: children remain in run_safe's workload group.
        stdin, stdout, stderr, waiter = Open3.popen3({'TZ' => 'UTC'}, *argv)
        stdin.close
        stdout.binmode
        stderr.binmode
        readers << Thread.new { stdout.read }
        readers << Thread.new { stderr.read }
        unless waiter.join(timeout)
          timed_out = true
          terminate_child!(waiter)
        end
        status = waiter.value
        stdout_bytes = readers[0].value
        stderr_bytes = readers[1].value
      rescue StandardError => error
        spawn_error = "#{error.class}: #{error.message}"
      ensure
        terminate_child!(waiter) if waiter && waiter.alive?
        waiter.join if waiter
        [stdin, stdout, stderr].compact.each do |pipe|
          begin
            pipe.close unless pipe.closed?
          rescue IOError
            nil
          end
        end
        readers.each(&:join)
        if readers.length == 2
          begin
            stdout_bytes = readers[0].value if stdout_bytes.empty?
            stderr_bytes = readers[1].value if stderr_bytes.empty?
          rescue StandardError => error
            spawn_error ||= "output drain #{error.class}: #{error.message}"
          end
        end
      end
      codes = (stdout_bytes + stderr_bytes).scan(/(?:^|[^A-Za-z0-9_])Code:[\x09-\x0d\x20]*([0-9]+)(?![A-Za-z0-9_])/n).flatten.map(&:to_i).uniq
      {
        stdout: stdout_bytes,
        stderr: stderr_bytes,
        status: {
          'success' => status&.success? || false,
          'exitstatus' => status&.exitstatus,
          'signaled' => status&.signaled? || false,
          'termsig' => status&.termsig,
          'timed_out' => timed_out,
          'spawn_error' => spawn_error,
          'duration_ms' => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
          'reported_clickhouse_codes' => codes,
        },
      }
    end

    def terminate_child!(waiter)
      return unless waiter && waiter.alive?
      begin
        Process.kill('TERM', waiter.pid)
      rescue Errno::ESRCH
        nil
      end
      unless waiter.join(RecheckSimpleAggregateBulkW221::TERM_GRACE_SECONDS)
        begin
          Process.kill('KILL', waiter.pid)
        rescue Errno::ESRCH
          nil
        end
        waiter.join
      end
    end
  end

  def self.parse_options(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/recheck_simple_aggregate_bulk_w221.rb --source-matrix PATH --clickhouse PATH --crystal-helper PATH --evidence-root PATH'
      opts.on('--source-matrix PATH', 'W221 physical matrix.json from the pinned stock probe') { |value| options[:source_matrix] = value }
      opts.on('--clickhouse PATH', 'Pinned local ClickHouse executable') { |value| options[:clickhouse] = value }
      opts.on('--crystal-helper PATH', 'Prebuilt W221 Crystal bulk helper') { |value| options[:crystal_helper] = value }
      opts.on('--evidence-root PATH', 'Existing empty direct /private/tmp child created by the guarded root runner') { |value| options[:evidence_root] = value }
    end
    parser.parse!(argv)
    raise OptionParser::MissingArgument, '--source-matrix' unless options[:source_matrix]
    raise OptionParser::MissingArgument, '--clickhouse' unless options[:clickhouse]
    raise OptionParser::MissingArgument, '--crystal-helper' unless options[:crystal_helper]
    raise OptionParser::MissingArgument, '--evidence-root' unless options[:evidence_root]
    raise OptionParser::InvalidArgument, 'unexpected positional arguments' unless argv.empty?
    options
  end

  def self.main(argv)
    options = parse_options(argv)
    Probe.new(options).run ? 0 : 1
  rescue StandardError => error
    warn "W221 bulk runner setup failure (not a type-law refusal): #{error.class}: #{error.message}"
    2
  end
end

exit(RecheckSimpleAggregateBulkW221.main(ARGV))
