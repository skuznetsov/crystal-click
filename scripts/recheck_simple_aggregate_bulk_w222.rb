#!/usr/bin/env ruby
# Paired stock/native and Crystal generic-bulk qualification for the frozen
# W222 recursive SimpleAggregateFunction roster. This runner consumes only
# externally built executables and captured stock parts; it never builds them.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'optparse'

module RecheckSimpleAggregateBulkW222
  extend self

  VERSION = '26.10.1.1201'.freeze
  BUILD_HASH = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  CLICKHOUSE_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  SOURCE_ROOT = '/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1'.freeze
  SOURCE_REVISION = '0ca8150d9b1d0886edb2e3b4ab65eebb768d0357'.freeze
  SOURCE_PREFIX = '/private/tmp/crystal-click-w222-physical.'.freeze
  EVIDENCE_PREFIX = '/private/tmp/crystal-click-w222-bulk.'.freeze
  FORMAT_INPUT = 'simple_aggregate_bulk_w222_input_v1'.freeze
  FORMAT_HELPER = 'simple_aggregate_bulk_w222_helper_v1'.freeze
  PROCESS_TIMEOUT_SECONDS = 90
  HELPER_TIMEOUT_SECONDS = 360
  TERM_GRACE_SECONDS = 2
  MEMORY_LIMIT_BYTES = 1_073_741_824
  ROW_KEYS = [11, 22, 33, 44, 55].freeze
  REAL_MARK_ROWS = [2, 2, 1].freeze
  INVALIDATED_FILE = 'invalidated_system_columns.txt'.freeze
  INVALIDATED_NAMES = %w[_block_number _block_offset].freeze
  STRING_VERSIONS = {'single_stream' => 0, 'with_size_stream' => 1}.freeze
  STRING_MODES = %w[single_stream with_size_stream].freeze

  # Independent expected construction roster. String-bearing values expand to
  # both measured native profiles; all other rows have exactly one profile.
  SPECS = [
    ['sumMap_map_i32_i64', 'sumMap', 'sumMap', 'Map(Int32, Int64)', 'map'],
    ['minMap_map_i32_i64', 'minMap', 'minMap', 'Map(Int32, Int64)', 'map'],
    ['maxMap_map_i32_i64', 'maxMap', 'maxMap', 'Map(Int32, Int64)', 'map'],
    ['sumMappedArrays_tuple_canonicalizes', 'sumMappedArrays', 'sumMap', 'Tuple(Array(Int32), Array(Int64))', 'mapped_arrays'],
    ['minMappedArrays_tuple_canonicalizes', 'minMappedArrays', 'minMap', 'Tuple(Array(Int32), Array(Int64))', 'mapped_arrays'],
    ['maxMappedArrays_tuple_canonicalizes', 'maxMappedArrays', 'maxMap', 'Tuple(Array(Int32), Array(Int64))', 'mapped_arrays'],
    ['sumMap_tuple_arrays', 'sumMap', 'sumMap', 'Tuple(Array(Int32), Array(Int64))', 'mapped_arrays'],
    ['sumMappedArrays_three_arrays', 'sumMappedArrays', 'sumMap', 'Tuple(Array(Int32), Array(Int64), Array(Int64))', 'mapped_arrays'],
    ['groupArrayArray_uint64', 'groupArrayArray', 'groupArrayArray', 'Array(UInt64)', 'array'],
    ['groupArrayArray_uint64_capped', 'groupArrayArray(3)', 'groupArrayArray(3)', 'Array(UInt64)', 'array_parameter'],
    ['groupArrayArray_capped_string', 'groupArrayArray(3)', 'groupArrayArray(3)', 'Array(String)', 'array_parameter'],
    ['array_concat_agg_alias', 'array_concat_agg', 'groupArrayArray', 'Array(UInt64)', 'canonical_alias'],
    ['groupArrayArray_nested_array', 'groupArrayArray', 'groupArrayArray', 'Array(Array(UInt64))', 'recursive_array'],
    ['groupArrayLastArray_cap5', 'groupArrayLastArray(5)', 'groupArrayLastArray(5)', 'Array(UInt64)', 'array_required_parameter'],
    ['groupUniqArrayArray_uint64', 'groupUniqArrayArray', 'groupUniqArrayArray', 'Array(UInt64)', 'array'],
    ['groupUniqArrayArray_capped_string', 'groupUniqArrayArray(7)', 'groupUniqArrayArray(7)', 'Array(String)', 'array_parameter'],
    ['groupUniqArrayArrayMap_map_i32_array_i64', 'groupUniqArrayArrayMap', 'groupUniqArrayArrayMap', 'Map(Int32, Array(Int64))', 'map_array'],
    ['groupUniqArrayArrayMap_capped_map_string_array_u8', 'groupUniqArrayArrayMap(4)', 'groupUniqArrayArrayMap(4)', 'Map(String, Array(UInt8))', 'map_array_parameter'],
    ['timeSeriesGroupArray_u32_f64', 'timeSeriesGroupArray', 'timeSeriesGroupArray', 'Array(Tuple(UInt32, Float64))', 'time_series'],
    ['timeSeriesGroupArray_datetime64_f32', 'timeSeriesGroupArray', 'timeSeriesGroupArray', "Array(Tuple(DateTime64(3, 'UTC'), Float32))", 'time_series'],
    ['timeSeriesGroupArray_datetime_f64', 'timeSeriesGroupArray', 'timeSeriesGroupArray', "Array(Tuple(DateTime('UTC'), Float64))", 'time_series'],
    ['any_map_string_u64', 'any', 'any', 'Map(String, UInt64)', 'existing_any'],
    ['anyLast_array_u64', 'anyLast', 'anyLast', 'Array(UInt64)', 'existing_anyLast'],
    ['anyLast_named_tuple', 'anyLast', 'anyLast', 'Tuple(key UInt64, value String)', 'existing_named_tuple'],
    ['any_respect_nullable_u64', 'any_respect_nulls', 'any_respect_nulls', 'Nullable(UInt64)', 'existing_inner_nullable'],
    ['anyLast_respect_nullable_u64', 'anyLast_respect_nulls', 'anyLast_respect_nulls', 'Nullable(UInt64)', 'existing_inner_nullable'],
    ['min_array_nested', 'min', 'min', 'Array(Array(UInt64))', 'existing_min_recursive'],
    ['min_map_i32_i64', 'min', 'min', 'Map(Int32, Int64)', 'existing_min_recursive'],
    ['max_map_i32_array_i64', 'max', 'max', 'Map(Int32, Array(Int64))', 'existing_max_recursive'],
    ['min_array_named_tuple', 'min', 'min', 'Array(Tuple(key UInt64, value String))', 'existing_nested_array_tuple'],
    ['min_nullable_i64', 'min', 'min', 'Nullable(Int64)', 'existing_inner_nullable'],
    ['max_nullable_string', 'max', 'max', 'Nullable(String)', 'existing_inner_nullable'],
  ].freeze

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
      @matrix_path = validate_source_matrix(options.fetch(:source_matrix))
      @source_root = File.dirname(@matrix_path)
      @root = validate_evidence_root(options.fetch(:evidence_root))
      @source_matrix_sha = Digest::SHA256.file(@matrix_path).hexdigest
      @sequence = 0
      @invocations = []
      @profiles = []
      @helper_profiles = []
      @target_paths = {}
      @generated_parts = {}
      @records = []
      @fatal = nil
      @clickhouse_pin = nil
      @helper_sha = nil
      @recorder = Recorder.new(self)
    end

    def run
      prepare_layout!
      read_source_matrix!
      write_manifest!
      pin_executables!
      write_helper_input!
      invoke_helper!
      create_native_targets!
      attach_and_verify_all!
      verify_pins!
      write_summary('paired_recursive_simple_aggregate_bulk_observed')
      puts "W222 paired generic bulk matrix profiles=#{@profiles.length}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal ||= "#{error.class}: #{error.message}"
      write_summary('runner_failure_or_observations_differ') rescue nil
      warn "W222 paired bulk probe failure (not a ClickHouse type-law refusal): #{@fatal}"
      false
    end

    attr_reader :root

    def write_new(path, bytes)
      File.open(path, 'wbx', 0o600) { |file| file.write(bytes) }
    rescue Errno::EEXIST
      raise ArgumentError, "refusing to overwrite W222 evidence: #{path}"
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
      fail!("#{label} is absent, non-executable, or symlinked: #{full}") unless
        File.file?(full) && File.executable?(full) && !File.symlink?(full) && File.realpath(full) == full
      full
    end

    def validate_source_matrix(path)
      full = File.expand_path(path)
      fail!('source matrix must be a plain matrix.json') unless File.file?(full) && !File.symlink?(full) && File.basename(full) == 'matrix.json'
      parent = File.dirname(full)
      fail!('source matrix must be a canonical direct child of the W222 physical evidence root') unless
        File.realpath(parent) == parent && parent.start_with?(SOURCE_PREFIX) && File.dirname(parent) == '/private/tmp'
      fail!('source matrix file is not canonical') unless File.realpath(full) == full
      full
    rescue Errno::ENOENT
      fail!('source matrix is missing')
    end

    def validate_evidence_root(path)
      full = File.expand_path(path)
      fail!('evidence root must be a direct /private/tmp child') unless File.dirname(full) == File.realpath('/private/tmp')
      fail!('evidence root must be an existing empty non-symlink directory') unless
        File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full && Dir.children(full).empty?
      fail!('evidence root name does not use the fixed W222 bulk prefix') unless full.start_with?(EVIDENCE_PREFIX)
      full
    rescue Errno::ENOENT
      fail!('evidence root must already exist')
    end

    def prepare_layout!
      %w[invocations generated cases stores].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'generated', 'parts'), 0o700)
      Dir.mkdir(File.join(@root, 'cases', 'profiles'), 0o700)
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
    end

    def safe_label(value)
      value.gsub(/[^A-Za-z0-9_.-]/, '_')
    end

    def expected_profiles
      result = []
      SPECS.each do |base, source_function, canonical_function, storage_type, category|
        modes = storage_type.match?(/(?:^|[^A-Za-z0-9_])String(?:[^A-Za-z0-9_]|$)/) ? STRING_MODES : [nil]
        modes.each do |mode|
          suffix = mode ? "_#{mode}" : ''
          result << {
            'id' => base + suffix,
            'source_function' => source_function,
            'canonical_function' => canonical_function,
            'storage_type' => storage_type,
            'category' => category,
            'string_serialization_mode' => mode,
          }
        end
      end
      fail!('independent expected W222 roster is not exactly 39') unless result.length == 39
      fail!('independent expected W222 roster contains duplicate ids') unless result.map { |row| row.fetch('id') }.uniq.length == 39
      result
    end

    def validate_inventory(part, label)
      fail!("#{label} part is absent, symlinked, or noncanonical: #{part}") unless
        File.directory?(part) && !File.symlink?(part) && File.realpath(part) == part
      files = []
      Find.find(part) do |path|
        next if path == part
        fail!("symlink in #{label} part: #{path}") if File.symlink?(path)
        next if File.directory?(path)
        fail!("non-file entry in #{label} part: #{path}") unless File.file?(path)
        files << {'path' => path[(part.length + 1)..-1], 'size' => File.size(path),
          'sha256' => Digest::SHA256.file(path).hexdigest}
      end
      files.sort_by { |entry| entry.fetch('path') }
    end

    def read_source_matrix!
      matrix = JSON.parse(File.binread(@matrix_path))
      fail!('source matrix case count is not 39') unless matrix.fetch('case_count') == 39 && matrix.fetch('matrix').length == 39
      fail!('stock physical matrix contains any non-positive classification') unless
        matrix.fetch('stock_physical_observed') == 39 && matrix.fetch('stock_construction_mismatches') == 0 &&
        matrix.fetch('physical_mismatches') == 0 && matrix.fetch('probe_failures') == 0
      source_pin = matrix.fetch('source_pin')
      fail!('source comparison pin differs from W222 task pin') unless
        source_pin.fetch('source_reference') == "#{SOURCE_ROOT}@#{SOURCE_REVISION}" &&
        source_pin.fetch('runtime_built_from_this_snapshot_not_asserted') == true
      expected_source_hashes = {
        'src/DataTypes/DataTypeCustomSimpleAggregateFunction.cpp' => '6c4502cdd659d59cc83b953a03399fa37d491f097ca38f445bfa74b1654e877d',
        'src/DataTypes/DataTypesBinaryEncoding.h' => '92c3362477dc283302fc84713413f45fd6c92c7273309c6efb41425d22c5485f',
        'src/DataTypes/DataTypesBinaryEncoding.cpp' => '78ba394f20ccd2a00f5be6b8c4d470fafb1c91a6f87bb27c301c2d3203f28f87',
      }
      observed_source_hashes = source_pin.fetch('file_hashes').each_with_object({}) do |entry, hashes|
        hashes[entry.fetch('path')] = entry.fetch('actual_sha256')
        fail!("source anchor mismatch for #{entry.fetch('path')}") unless
          entry.fetch('expected_sha256') == entry.fetch('actual_sha256') && entry.fetch('matches') == true
      end
      fail!('source anchor roster/hash differs from the W222 source pin') unless observed_source_hashes == expected_source_hashes
      runtime = matrix.fetch('runtime_pin')
      fail!('stock fixture runtime differs from the separately pinned W222 runtime') unless
        runtime.fetch('runtime_sha256') == CLICKHOUSE_SHA256 && runtime.fetch('runtime_version') == VERSION &&
        runtime.fetch('runtime_build_hash') == BUILD_HASH

      expected = expected_profiles
      actual_profiles = matrix.fetch('matrix')
      fail!('stock matrix id order/roster differs from independently expected W222 roster') unless
        actual_profiles.map { |item| item.fetch('id') } == expected.map { |item| item.fetch('id') }
      actual_profiles.each_with_index do |actual, index|
        law = expected.fetch(index)
        declared = "SimpleAggregateFunction(#{law.fetch('canonical_function')}, #{law.fetch('storage_type')})"
        source_type = "SimpleAggregateFunction(#{law.fetch('source_function')}, #{law.fetch('storage_type')})"
        fail!("stock profile #{law.fetch('id')} is not the independently expected positive witness") unless
          actual.fetch('classification') == 'stock_physical_observed' && actual.fetch('id') == law.fetch('id') &&
          actual.fetch('source_function') == law.fetch('source_function') &&
          actual.fetch('canonical_function') == law.fetch('canonical_function') &&
          actual.fetch('category') == law.fetch('category') && actual.fetch('source_type') == source_type &&
          actual.fetch('declared_type') == declared && actual.fetch('storage_type') == law.fetch('storage_type') &&
          actual.fetch('row_keys') == ROW_KEYS && actual.fetch('mark_rows') == REAL_MARK_ROWS &&
          actual.fetch('construction_expectation') == 'strict_stock_construction_positive; failure is not skipped'
        physical = actual.fetch('physical')
        part = File.expand_path(physical.fetch('copied_part_path'))
        fail!("stock copied part for #{law.fetch('id')} escaped its exact source root") unless
          part.start_with?(File.join(@source_root, 'parts') + File::SEPARATOR)
        source_part = File.expand_path(physical.fetch('source_part_path'))
        fail!("stock original part for #{law.fetch('id')} escaped its exact source stores root") unless
          source_part.start_with?(File.join(@source_root, 'stores') + File::SEPARATOR)
        expected_inventory = physical.fetch('part_file_inventory')
        source_inventory = validate_inventory(source_part, "stock original #{law.fetch('id')}")
        copied_inventory = validate_inventory(part, "stock copy #{law.fetch('id')}")
        fail!("stock original part inventory differs from its captured manifest for #{law.fetch('id')}") unless
          source_inventory == expected_inventory
        fail!("stock copied part inventory differs from its original for #{law.fetch('id')}") unless
          copied_inventory == source_inventory
        validate_source_rowbinary!(actual)
      end
      @source_manifest = matrix
      @profiles = actual_profiles
      @expected_profiles = expected
    rescue JSON::ParserError => error
      fail!("source matrix JSON is invalid: #{error.message}")
    end

    def decode_hex(hex, label)
      fail!("#{label} is not even lowercase hexadecimal") unless hex.is_a?(String) && hex.bytesize.even? && hex.match?(/\A(?:[0-9a-f]{2})*\z/)
      [hex].pack('H*').b
    end

    def varuint(value)
      fail!('negative RowBinary VarUInt') unless value >= 0
      output = +''.b
      remaining = value
      while remaining >= 0x80
        output << ((remaining & 0x7f) | 0x80)
        remaining >>= 7
      end
      output << remaining
    end

    def encode_value(spec, value)
      case spec.fetch('kind')
      when 'fixed'
        bytes = decode_hex(value.fetch('raw_hex'), spec.fetch('name'))
        fail!("#{spec.fetch('name')} literal width differs") unless bytes.bytesize == spec.fetch('width')
        bytes
      when 'string'
        bytes = decode_hex(value.fetch('raw_hex'), 'String literal')
        varuint(bytes.bytesize) + bytes
      when 'array'
        fail!("#{spec.fetch('name')} literal is not an array") unless value.is_a?(Array)
        varuint(value.length) + value.map { |child| encode_value(spec.fetch('child'), child) }.join.b
      when 'tuple'
        fail!("#{spec.fetch('name')} Tuple arity differs") unless value.is_a?(Array) && value.length == spec.fetch('children').length
        spec.fetch('children').each_with_index.map { |child, index| encode_value(child, value.fetch(index)) }.join.b
      when 'map'
        fail!("#{spec.fetch('name')} literal is not entry array") unless value.is_a?(Array)
        pairs = value.map do |pair|
          fail!('Map literal pair arity differs') unless pair.is_a?(Array) && pair.length == 2
          encode_value(spec.fetch('key'), pair.fetch(0)) + encode_value(spec.fetch('value'), pair.fetch(1))
        end
        varuint(pairs.length) + pairs.join.b
      when 'nullable'
        value.nil? ? "\x01".b : "\x00".b + encode_value(spec.fetch('child'), value)
      else
        fail!("unlisted literal type shape #{spec.fetch('kind').inspect}")
      end
    end

    def expected_rowbinary(profile, indices)
      output = +''.b
      spec = profile.fetch('storage_spec')
      indices.each do |index|
        row = profile.fetch('rowbinary_values').fetch(index)
        value_bytes = encode_value(spec, row.fetch('value'))
        fail!("literal W222 row bytes differ from source manifest for #{profile.fetch('id')}/#{index}") unless
          value_bytes.unpack1('H*') == row.fetch('value_rowbinary_hex')
        output << [row.fetch('key')].pack('Q<') << value_bytes
      end
      output
    end

    def validate_source_rowbinary!(profile)
      physical = profile.fetch('physical')
      {'full' => (0...5).to_a, 'middle' => [1, 2, 3], 'empty' => []}.each do |window, indices|
        expected = expected_rowbinary(profile, indices)
        record = physical.fetch('rowbinary').fetch(window)
        path = File.expand_path(record.fetch('path'), @source_root)
        fail!("source #{window} RowBinary path escapes evidence for #{profile.fetch('id')}") unless
          path.start_with?(File.join(@source_root, 'evidence') + File::SEPARATOR) && File.file?(path) && !File.symlink?(path)
        actual = File.binread(path)
        fail!("source #{window} RowBinary literal differs for #{profile.fetch('id')}") unless
          actual == expected && record.fetch('matches_independent_literal') == true &&
          record.fetch('bytes') == expected.bytesize && record.fetch('sha256') == Digest::SHA256.hexdigest(expected)
      end
    end

    def write_manifest!
      @manifest = {
        'suite' => 'W222 paired recursive SimpleAggregateFunction source/library/native Wide-part qualification',
        'runtime_expected' => {'version' => VERSION, 'build_hash' => BUILD_HASH, 'sha256' => CLICKHOUSE_SHA256},
        'comparison_source' => "#{SOURCE_ROOT}@#{SOURCE_REVISION}",
        'source_and_runtime_correlation_asserted' => false,
        'source_matrix' => {'path' => @matrix_path, 'sha256' => @source_matrix_sha, 'profiles' => 39},
        'case_roster' => @expected_profiles,
        'expected_rows' => {'keys' => ROW_KEYS, 'row_count' => 5, 'real_mark_rows' => REAL_MARK_ROWS,
          'native_marks_include_terminal' => 4, 'RowBinary_windows' => ['full', 'middle keys 22..44', 'empty where pk=0']},
        'writer_profile_policy' => 'String-bearing explicit source mode is selected for the library part; non-String/omitted profile uses library single_stream.',
        'metadata_policy' => {'library_columns' => 'exact key Default record for pk, 0 defaults, 5 rows',
          'library_types_serialization_versions' => 'string: 0 for single_stream, 1 for with_size_stream',
          'nullable_specific_serialization_key' => 'none', 'metadata_version' => 'copied from corresponding stock part'},
        'attachment_inventory_policy' => {'original_files' => 'all copied library-part files retain exact path, size, and SHA-256',
          'only_allowed_added_file' => INVALIDATED_FILE, 'added_file_exact_line_set' => INVALIDATED_NAMES,
          'source_basis' => [
            "#{SOURCE_ROOT}@#{SOURCE_REVISION}:src/Storages/MergeTree/MergeTreeData.cpp loadPartAndFixMetadataImpl writes invalidated system columns during ATTACH",
            "#{SOURCE_ROOT}@#{SOURCE_REVISION}:src/Storages/MergeTree/IMergeTreeDataPart.cpp returns _block_number and _block_offset",
          ]},
        'physical_scope' => '39 exact native-constructed profiles; not a Cartesian closure over arbitrary recursive descriptors or all parameter Field types.',
        'process_policy' => {'timeout_seconds' => PROCESS_TIMEOUT_SECONDS,
          'helper_timeout_seconds' => HELPER_TIMEOUT_SECONDS,
          'children' => 'inherit outer process group; timeout TERM/KILL targets positive child PID',
          'timeouts/nonzero/spawn errors' => 'probe failures, never construction law refusals'},
      }
      write_json(File.join(@root, 'manifest.json'), @manifest)
    end

    def pin_executables!
      sha = Digest::SHA256.file(@binary).hexdigest
      fail!('ClickHouse executable hash differs from fixed W222 runtime pin') unless sha == CLICKHOUSE_SHA256
      @clickhouse_pin = {'version' => VERSION, 'build_hash' => BUILD_HASH, 'sha256' => sha}
      version = @recorder.run_clickhouse('pin-version', File.join(@root, 'stores', 'native'), 'SELECT version() FORMAT TSVRaw')
      assert_success!(version, 'runtime version pin')
      fail!('ClickHouse version output differs from task pin') unless version.fetch(:stdout).strip == VERSION
      build = @recorder.run_clickhouse('pin-build', File.join(@root, 'stores', 'native'),
        "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw")
      assert_success!(build, 'runtime build pin')
      fail!('ClickHouse build hash output differs from task pin') unless build.fetch(:stdout).strip == "VERSION_GITHASH=#{BUILD_HASH}"
      @helper_sha = Digest::SHA256.file(@helper).hexdigest
      write_json(File.join(@root, 'runtime_pin.json'), {
        'runtime' => @clickhouse_pin, 'helper' => {'path' => @helper, 'sha256' => @helper_sha, 'prebuilt' => true},
        'comparison_source' => "#{SOURCE_ROOT}@#{SOURCE_REVISION}", 'runtime_source_correlation' => 'not_asserted',
      })
    end

    def verify_pins!
      fail!('ClickHouse executable changed during the run') unless Digest::SHA256.file(@binary).hexdigest == CLICKHOUSE_SHA256
      fail!('prebuilt Crystal helper changed during the run') unless Digest::SHA256.file(@helper).hexdigest == @helper_sha
    end

    def helper_input_profile(profile, index)
      explicit_mode = profile['string_serialization_mode'] == 'omitted_default' ? nil : profile['string_serialization_mode']
      source_version = profile.fetch('physical').fetch('serialization_json').fetch('types_serialization_versions').fetch('string')
      expected_source_mode = profile.fetch('source_string_serialization_mode')
      fail!("source profile serialization setting differs from metadata for #{profile.fetch('id')}") unless
        source_version == STRING_VERSIONS.fetch(expected_source_mode)
      expected_library_mode = explicit_mode || 'single_stream'
      part_parent = File.join(@root, 'generated', 'parts', format('%03d-%s', index, safe_label(profile.fetch('id'))))
      Dir.mkdir(part_parent, 0o700)
      {
        'id' => profile.fetch('id'), 'canonical_function' => profile.fetch('canonical_function'),
        'source_function' => profile.fetch('source_function'), 'category' => profile.fetch('category'),
        'declared_type' => profile.fetch('declared_type'), 'storage_type' => profile.fetch('storage_type'),
        'storage_spec' => profile.fetch('storage_spec'),
        'source_profile' => expected_source_mode, 'library_profile' => expected_library_mode,
        'metadata_version' => profile.fetch('physical').fetch('metadata_version_txt'),
        'source_part' => profile.fetch('physical').fetch('copied_part_path'),
        'library_part' => File.join(part_parent, 'all_1_1_0'),
        'rowbinary_values' => profile.fetch('rowbinary_values'),
      }
    end

    def write_helper_input!
      input = {'format' => FORMAT_INPUT, 'capture_root' => @source_root,
        'profiles' => @profiles.each_with_index.map { |profile, index| helper_input_profile(profile, index) }}
      @helper_input_path = File.join(@root, 'generated', 'helper-input.json')
      write_json(@helper_input_path, input)
      @helper_input_sha = Digest::SHA256.file(@helper_input_path).hexdigest
    end

    def invoke_helper!
      result = @recorder.run_helper('generic-stock-read-library-write-read', @helper_input_path,
        File.join(@root, 'generated'), @source_root)
      assert_success!(result, 'generic Crystal stock/library reader-writer helper')
      fail!('Crystal helper stdout is empty') if result.fetch(:stdout).strip.empty?
      parsed = JSON.parse(result.fetch(:stdout))
      fail!('Crystal helper output format differs') unless parsed.fetch('format') == FORMAT_HELPER
      fail!('Crystal helper profile count/roster differs') unless parsed.fetch('profile_count') == 39 && parsed.fetch('profiles').length == 39
      fail!('Crystal helper profile order differs from frozen manifest') unless
        parsed.fetch('profiles').map { |item| item.fetch('id') } == @profiles.map { |item| item.fetch('id') }
      parsed.fetch('profiles').each_with_index do |item, index|
        source = @profiles.fetch(index)
        fail!("generic source/library reader-writer failed for #{item.fetch('id')}") unless
          item.fetch('classification') == 'physical_observed' && item.fetch('declared_type') == source.fetch('declared_type')
        expected_library_mode = source['string_serialization_mode'] == 'omitted_default' ? 'single_stream' : source['string_serialization_mode']
        fail!("library ordinary profile differs for #{item.fetch('id')}") unless
          item.fetch('library_profile') == expected_library_mode && item.fetch('library').fetch('ordinary_profile') == expected_library_mode
        expected_source_mode = source.fetch('source_string_serialization_mode')
        fail!("stock ordinary profile differs for #{item.fetch('id')}") unless
          item.fetch('source_profile') == expected_source_mode && item.fetch('source').fetch('ordinary_profile') == expected_source_mode
        expected_windows = %w[full first middle final_short first_zero eof_zero]
        %w[source library].each do |side|
          reader = item.fetch(side)
          fail!("#{side} reader row/mark schedule differs for #{item.fetch('id')}") unless
            reader.fetch('row_count') == 5 && reader.fetch('real_mark_count') == 3 &&
            reader.fetch('real_mark_row_counts') == [2, 2, 1] && reader.fetch('windows') == expected_windows
        end
      fail!("source/library physical stream roster differs for #{item.fetch('id')}") unless
        item.fetch('source').fetch('physical_stream_names') == item.fetch('library').fetch('physical_stream_names')
      expected_public_schedule = [[0, 0, 2], [1, 2, 2], [2, 4, 1]]
      %w[source_public_scan library_public_scan].each do |side|
        scan = item.fetch(side)
        fail!("#{side} public scan schedule differs for #{item.fetch('id')}") unless
          scan.fetch('rows') == 5 && scan.fetch('batch_rows') == 2 && scan.fetch('exact_recursive_values') == true &&
          scan.fetch('batch_schedule') == expected_public_schedule
      end
        generated = File.expand_path(item.fetch('library_part_path'))
        expected_parent = File.join(@root, 'generated', 'parts') + File::SEPARATOR
        fail!("generated part escaped authorized root for #{item.fetch('id')}") unless generated.start_with?(expected_parent)
        fail!("generated part is absent/noncanonical for #{item.fetch('id')}") unless
          File.directory?(generated) && !File.symlink?(generated) && File.realpath(generated) == generated
        item['library_part_inventory'] = validate_inventory(generated, "library #{item.fetch('id')}")
        fail!("library part inventory is empty for #{item.fetch('id')}") if item['library_part_inventory'].empty?
        @generated_parts[item.fetch('id')] = generated
      end
      @helper_profiles = parsed.fetch('profiles')
      write_json(File.join(@root, 'generated', 'helper-output.json'), parsed)
      write_json(File.join(@root, 'generated', 'helper-process.json'), result.fetch(:record))
    rescue JSON::ParserError => error
      fail!("Crystal helper stdout was not one JSON value: #{error.message}")
    end

    def create_native_targets!
      statements = []
      @profiles.each do |profile|
        table = table_name(profile)
        settings = STOCK_SETTINGS.dup
        mode = profile['string_serialization_mode']
        settings << "string_serialization_version='#{mode}'" if mode && mode != 'omitted_default'
        statements << "CREATE TABLE default.#{table} (pk UInt64, v #{profile.fetch('declared_type')}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings.join(', ')};"
      end
      names = @profiles.map { |profile| "'#{table_name(profile)}'" }.join(',')
      statements << "SELECT '__W222_TARGET__', name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name IN (#{names}) ORDER BY name FORMAT TSVRaw;"
      statements << "SELECT '__W222_SCHEMA__', table, name, type, toString(position) FROM system.columns WHERE database='default' AND table IN (#{names}) ORDER BY table, position FORMAT TSVRaw;"
      result = @recorder.run_clickhouse('create-39-native-targets', File.join(@root, 'stores', 'native'),
        statements.join("\n") + "\n", multiquery: true,
        extra_args: ['--enable_time_series_aggregate_functions=1'])
      assert_success!(result, '39 native target CREATE statements')
      target_rows = tagged_rows(result.fetch(:stdout), '__W222_TARGET__')
      fail!("native target path count differs: #{target_rows.length}") unless target_rows.length == 39
      target_rows.each do |row|
        fail!("malformed native target path row: #{row.inspect}") unless row.length == 3
        profile = @profiles.find { |item| table_name(item) == row[1] } || fail!("unexpected native target table #{row[1].inspect}")
        @target_paths[profile.fetch('id')] = contained_path(row[2], File.join(@root, 'stores', 'native'), 'native target table path')
      end
      fail!('not all native targets were discovered') unless @target_paths.length == 39
      schema_rows = tagged_rows(result.fetch(:stdout), '__W222_SCHEMA__')
      expected = []
      @profiles.each do |profile|
        table = table_name(profile)
        expected << ['__W222_SCHEMA__', table, 'pk', 'UInt64', '1']
        expected << ['__W222_SCHEMA__', table, 'v', profile.fetch('declared_type'), '2']
      end
      expected.sort_by! { |row| [row[1], row[4]] }
      fail!('native system.columns roster does not preserve every exact canonical nominal type') unless schema_rows == expected
      @native_creation_record = result.fetch(:record)
      write_json(File.join(@root, 'native-targets.json'), {'table_count' => 39, 'schema_rows' => schema_rows.length,
        'table_paths' => @target_paths, 'invocation' => @native_creation_record})
    end

    def table_name(profile)
      'saf_w222_' + safe_label(profile.fetch('id')).downcase
    end

    def attach_and_verify_all!
      @profiles.each_with_index do |profile, index|
        puts "W222 native case #{index + 1}/39: #{profile.fetch('id')}"
        @records << attach_and_verify(profile, index)
      end
      write_json(File.join(@root, 'cases', 'matrix.json'), {
        'case_count' => @records.length,
        'observed' => @records.count { |item| item.fetch('classification') == 'physical_observed' },
        'mismatches' => @records.count { |item| item.fetch('classification') != 'physical_observed' },
        'matrix' => @records,
      })
      fail!('not all 39 native attach/check/RowBinary cases passed') unless
        @records.length == 39 && @records.all? { |item| item.fetch('classification') == 'physical_observed' }
    end

    def attach_and_verify(profile, index)
      id = profile.fetch('id')
      table = table_name(profile)
      data_path = @target_paths.fetch(id)
      case_dir = File.join(@root, 'cases', 'profiles', format('%03d-%s', index, safe_label(id)))
      Dir.mkdir(case_dir, 0o700)
      native_root = File.realpath(File.join(@root, 'stores', 'native'))
      fail!("target data path escaped its native root for #{id}") unless
        data_path.start_with?(native_root + File::SEPARATOR) && File.realpath(data_path) == data_path
      detached = File.join(data_path, 'detached')
      if File.exist?(detached) || File.symlink?(detached)
        fail!("target detached path is not a canonical nonsymlink directory for #{id}") unless
          File.directory?(detached) && !File.symlink?(detached) && File.realpath(detached) == detached
        fail!("target detached path escaped its exact data path for #{id}") unless
          File.dirname(File.realpath(detached)) == data_path
        fail!("target detached directory is not empty for #{id}") unless Dir.children(detached).empty?
      else
        Dir.mkdir(detached, 0o700)
      end
      detached_real = File.realpath(detached)
      fail!("detached directory escaped target for #{id}") unless
        detached_real == detached && File.dirname(detached_real) == data_path
      part_path = File.join(detached_real, 'all_1_1_0')
      active_part_path = File.join(data_path, 'all_1_1_0')
      fail!("target detached part path already exists for #{id}") if File.exist?(part_path) || File.symlink?(part_path)
      fail!("target active part path already exists for #{id}") if File.exist?(active_part_path) || File.symlink?(active_part_path)
      generated = @generated_parts.fetch(id)
      before = validate_inventory(generated, "generated library #{id}")
      FileUtils.cp_r(generated, part_path)
      copied = validate_inventory(part_path, "detached library copy #{id}")
      fail!("detached library copy differs before attach for #{id}") unless copied == before

      outputs = {}
      %w[full middle empty].each do |window|
        path = File.join(case_dir, "rowbinary-#{window}.bin")
        fail!("refusing to overwrite native RowBinary output #{path}") if File.exist?(path) || File.symlink?(path)
        outputs[window] = path
      end
      escape = lambda { |path| path.gsub("'", "\\'") }
      sql = [
        "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0';",
        "CHECK TABLE default.#{table} FORMAT TSV;",
        "SELECT '__W222_SCHEMA__', name, type, toString(position) FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw;",
        "SELECT '__W222_TYPE__', toTypeName(pk), toTypeName(v) FROM default.#{table} LIMIT 1 FORMAT TSVRaw;",
        "SELECT '__W222_PART__', name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw;",
        "SELECT pk, v FROM default.#{table} ORDER BY pk INTO OUTFILE '#{escape.call(outputs.fetch('full'))}' FORMAT RowBinary;",
        "SELECT pk, v FROM default.#{table} WHERE pk BETWEEN 22 AND 44 ORDER BY pk INTO OUTFILE '#{escape.call(outputs.fetch('middle'))}' FORMAT RowBinary;",
        "SELECT pk, v FROM default.#{table} WHERE pk=0 ORDER BY pk INTO OUTFILE '#{escape.call(outputs.fetch('empty'))}' FORMAT RowBinary;",
      ].join("\n") + "\n"
      result = @recorder.run_clickhouse("#{id}-attach-check-rowbinary", File.join(@root, 'stores', 'native'),
        sql, multiquery: true, extra_args: ['--enable_time_series_aggregate_functions=1'])
      assert_success!(result, "native attach/check/RowBinary for #{id}")
      stdout = result.fetch(:stdout)
      active = active_part_path!(stdout, data_path, id)
      after = validate_inventory(active, "attached native #{id}")
      attachment_delta = validate_attachment_delta!(before, after, active, id)
      generated_after = validate_inventory(generated, "generated library after attach #{id}")
      fail!("attach mutated the immutable generated part for #{id}") unless generated_after == before
      native_metadata = validate_native_metadata!(profile, active, stdout)
      rowbinary = validate_rowbinary!(profile, outputs)
      expected_schema = [['__W222_SCHEMA__', 'pk', 'UInt64', '1'], ['__W222_SCHEMA__', 'v', profile.fetch('declared_type'), '2']]
      schema = tagged_rows(stdout, '__W222_SCHEMA__')
      fail!("attached exact schema differs for #{id}: #{schema.inspect}") unless schema == expected_schema
      type = tagged_rows(stdout, '__W222_TYPE__')
      fail!("attached exact toTypeName differs for #{id}: #{type.inspect}") unless type == [['__W222_TYPE__', 'UInt64', profile.fetch('declared_type')]]
      record = {
        'id' => id, 'table_name' => table, 'declared_type' => profile.fetch('declared_type'),
        'source_function' => profile.fetch('source_function'), 'canonical_function' => profile.fetch('canonical_function'),
        'category' => profile.fetch('category'), 'storage_type' => profile.fetch('storage_type'),
        'classification' => 'physical_observed', 'generated_part_path' => generated,
        'generated_part_inventory_before_attach' => before, 'generated_part_inventory_after_attach' => generated_after,
        'detached_part_inventory_before_attach' => copied, 'attached_part_path' => active,
        'attached_part_inventory_after_operations' => after, 'attachment_inventory_delta' => attachment_delta,
        'native_metadata' => native_metadata, 'rowbinary' => rowbinary,
        'invocation' => result.fetch(:record), 'process_status' => result.fetch(:status),
      }
      @recorder.write_case(case_dir, record)
      record
    rescue StandardError => error
      record = {'id' => profile.fetch('id'), 'declared_type' => profile.fetch('declared_type'),
        'classification' => 'probe_failure', 'not_a_type_law_refusal' => true,
        'error' => "#{error.class}: #{error.message}"}
      record['invocation'] = result.fetch(:record) if result
      record['process_status'] = result.fetch(:status) if result
      @recorder.write_case(case_dir, record) if case_dir && File.directory?(case_dir) && !File.exist?(File.join(case_dir, 'case.json'))
      record
    end

    def active_part_path!(stdout, data_path, id)
      rows = tagged_rows(stdout, '__W222_PART__')
      fail!("active part census differs for #{id}: #{rows.inspect}") unless rows.length == 1 && rows.first.length == 6
      name, row_count, marks, part_type, path = rows.first.drop(1)
      fail!("active part identity/grid differs for #{id}") unless name == 'all_1_1_0' && row_count == '5' && marks == '4' && part_type == 'Wide'
      full = File.expand_path(path)
      fail!("active part path differs from target for #{id}") unless full == File.join(data_path, 'all_1_1_0') && File.directory?(full) && !File.symlink?(full)
      full
    end

    def validate_native_metadata!(profile, part, stdout)
      names = part_inventory_paths(part)
      required = %w[columns.txt columns_substreams.txt count.txt checksums.txt serialization.json default_compression_codec.txt metadata_version.txt primary.idx]
      fail!("native attached part lacks required metadata for #{profile.fetch('id')}: #{(required - names).inspect}") unless (required - names).empty?
      columns = File.binread(File.join(part, 'columns.txt')).force_encoding(Encoding::UTF_8).scrub
      expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`v` #{profile.fetch('declared_type')}\n"
      fail!("native columns.txt declaration differs for #{profile.fetch('id')}") unless columns == expected_columns
      substreams = File.binread(File.join(part, 'columns_substreams.txt')).force_encoding(Encoding::UTF_8).scrub
      helper = @helper_profiles.fetch(@profiles.index { |item| item.fetch('id') == profile.fetch('id') })
      value_roster = helper.fetch('library').fetch('physical_stream_names').sort
      substream_roster = parse_substreams(substreams, profile.fetch('id'))
      fail!("native selected physical stream roster differs for #{profile.fetch('id')}: #{substream_roster.inspect}") unless
        substream_roster == {'pk' => ['pk'], 'v' => value_roster}
      serialization_text = File.binread(File.join(part, 'serialization.json')).force_encoding(Encoding::UTF_8).scrub
      serialization = JSON.parse(serialization_text)
      mode = profile['string_serialization_mode']
      library_mode = mode.nil? || mode == 'omitted_default' ? 'single_stream' : mode
      expected_serialization = {
        'columns' => [{'exact_num_defaults' => true, 'kind' => 'Default', 'name' => 'pk', 'num_defaults' => 0, 'num_rows' => 5}],
        'propagate_types_serialization_versions_to_nested_types' => true,
        'types_serialization_versions' => {'string' => STRING_VERSIONS.fetch(library_mode)},
        'version' => 1,
      }
      fail!("native library serialization metadata differs from exact recursive-writer policy for #{profile.fetch('id')}") unless serialization == expected_serialization
      source_serialization = profile.fetch('physical').fetch('serialization_json')
      source_mode = profile.fetch('source_string_serialization_mode')
      fail!("stock source metadata law differs for #{profile.fetch('id')}") unless
        source_serialization.fetch('columns') == [] &&
        source_serialization.fetch('propagate_types_serialization_versions_to_nested_types') == true &&
        source_serialization.fetch('types_serialization_versions') == {'string' => STRING_VERSIONS.fetch(source_mode)} &&
        source_serialization.fetch('version') == 1
      fail!("unexpected Nullable serialization version key for #{profile.fetch('id')}") if serialization.keys.any? { |key| key.downcase.include?('nullable') }
      codec = File.binread(File.join(part, 'default_compression_codec.txt')).strip
      metadata_version = File.binread(File.join(part, 'metadata_version.txt')).strip
      count = File.binread(File.join(part, 'count.txt')).strip
      fail!("native codec/count/version differs for #{profile.fetch('id')}") unless codec == 'CODEC(LZ4)' && count == '5' && metadata_version == profile.fetch('physical').fetch('metadata_version_txt')
      check_rows = stdout.force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp).select { |line| line.start_with?("all_1_1_0\t") }
      fail!("CHECK TABLE did not report exactly one checked part for #{profile.fetch('id')}") unless check_rows == ["all_1_1_0\t1\t"]
      {
        'columns_txt' => columns, 'columns_substreams_txt' => substreams,
        'columns_substreams_validation' => {'expected' => {'pk' => ['pk'], 'v' => value_roster}, 'observed' => substream_roster,
          'membership_order_ignored' => true},
        'source_stock_serialization_json' => source_serialization,
        'attached_library_serialization_json' => serialization,
        'source_library_columns_difference' => {'stock' => source_serialization.fetch('columns'), 'library' => serialization.fetch('columns')},
        'source_library_string_profile' => {'stock_source' => source_mode, 'library_writer' => library_mode,
          'stock_version' => source_serialization.fetch('types_serialization_versions').fetch('string'),
          'library_version' => serialization.fetch('types_serialization_versions').fetch('string')},
        'metadata_version_txt' => metadata_version, 'default_compression_codec_txt' => codec,
        'count_txt' => count, 'serialization_json_sha256' => Digest::SHA256.hexdigest(serialization_text.b),
        'checksums_txt_sha256' => Digest::SHA256.file(File.join(part, 'checksums.txt')).hexdigest,
        'columns_txt_exact_type' => true, 'stock_and_library_metadata_are_not_claimed_identical' => true,
      }
    rescue JSON::ParserError => error
      fail!("native serialization JSON invalid for #{profile.fetch('id')}: #{error.message}")
    end

    def part_inventory_paths(part)
      validate_inventory(part, 'native attached').map { |entry| entry.fetch('path') }
    end

    def parse_substreams(text, id)
      fail!("columns_substreams.txt is not newline terminated for #{id}") unless text.end_with?("\n")
      fail!("columns_substreams.txt has carriage return for #{id}") if text.include?("\r")
      lines = text.lines.map(&:chomp)
      fail!("columns_substreams version/header differs for #{id}") unless lines.shift == 'columns substreams version: 1' && lines.shift == '2 columns:'
      roster = {}
      %w[pk v].each do |column|
        match = /\A([1-9][0-9]*) substreams for column `([^`]+)`:\z/.match(lines.shift.to_s)
        fail!("malformed substream count/header for #{id}/#{column}") unless match && match[2] == column
        count = Integer(match[1], 10)
        maximum = column == 'pk' ? 1 : 64
        fail!("substream count outside finite bound for #{id}/#{column}") unless count <= maximum
        names = []
        count.times do
          item = /\A\t([^\t\r\n]+)\z/.match(lines.shift.to_s)
          fail!("malformed substream name for #{id}/#{column}") unless item
          names << item[1]
        end
        fail!("duplicate substream name for #{id}/#{column}") unless names.uniq.length == names.length
        roster[column] = names.sort
      end
      fail!("trailing substream metadata for #{id}") unless lines.empty?
      roster
    rescue ArgumentError => error
      fail!("substream count is invalid for #{id}: #{error.message}")
    end

    def validate_attachment_delta!(before, after, part, id)
      before_by = before.each_with_object({}) { |entry, result| result[entry.fetch('path')] = entry }
      after_by = after.each_with_object({}) { |entry, result| result[entry.fetch('path')] = entry }
      removed = before_by.keys - after_by.keys
      changed = before_by.keys.select { |path| after_by.key?(path) && before_by.fetch(path) != after_by.fetch(path) }
      added = after_by.keys - before_by.keys
      fail!("ATTACH removed/changed original part file(s) for #{id}: removed=#{removed.inspect} changed=#{changed.inspect}") unless removed.empty? && changed.empty?
      fail!("ATTACH added files beyond the exact source-backed auxiliary for #{id}: #{added.inspect}") unless added == [INVALIDATED_FILE]
      bytes = File.binread(File.join(part, INVALIDATED_FILE))
      lines = bytes.split("\n", -1)
      fail!("invalidated_system_columns.txt bytes are not exactly two newline-terminated lines for #{id}") unless lines.pop == '' && lines.length == 2
      fail!("invalidated_system_columns.txt names differ for #{id}") unless lines.uniq.sort == INVALIDATED_NAMES.sort
      aux = after_by.fetch(INVALIDATED_FILE)
      fail!("invalidated system columns inventory differs from its exact bytes for #{id}") unless
        aux.fetch('size') == bytes.bytesize && aux.fetch('sha256') == Digest::SHA256.hexdigest(bytes)
      {'removed_paths' => removed, 'changed_original_paths' => changed, 'added_paths' => added,
        'added_file' => {'path' => INVALIDATED_FILE, 'bytes' => bytes.bytesize,
          'sha256' => Digest::SHA256.hexdigest(bytes), 'lines_unordered' => lines.sort},
        'all_original_files_preserved_exactly' => true, 'only_allowed_source_backed_auxiliary_added' => true}
    end

    def validate_rowbinary!(profile, outputs)
      result = {}
      {'full' => (0...5).to_a, 'middle' => [1, 2, 3], 'empty' => []}.each do |window, indices|
        path = outputs.fetch(window)
        fail!("ClickHouse did not create native #{window} RowBinary output for #{profile.fetch('id')}") unless File.file?(path) && !File.symlink?(path)
        actual = File.binread(path)
        expected = expected_rowbinary(profile, indices)
        fail!("native #{window} RowBinary differs from independent literal bytes for #{profile.fetch('id')}") unless actual == expected
        result[window] = {'path' => path.delete_prefix(@root + File::SEPARATOR), 'bytes' => actual.bytesize,
          'sha256' => Digest::SHA256.hexdigest(actual), 'expected_bytes' => expected.bytesize,
          'expected_sha256' => Digest::SHA256.hexdigest(expected), 'matches_independent_literal' => true}
      end
      result
    end

    def tagged_rows(stdout, tag)
      stdout.dup.force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp).map do |line|
        fields = line.split("\t", -1)
        fields if fields.first == tag
      end.compact
    end

    def contained_path(path, base, label)
      base_real = File.realpath(base)
      full = File.expand_path(path, base)
      real = File.realpath(full)
      fail!("#{label} escaped its root: #{real}") unless real.start_with?(base_real + File::SEPARATOR)
      real
    rescue Errno::ENOENT, Errno::EACCES => error
      fail!("cannot resolve #{label}: #{error.message}")
    end

    def assert_success!(result, label)
      status = result.fetch(:status)
      fail!("#{label} failed (probe failure, not a law refusal): #{status.inspect}") unless
        status.fetch('success') == true && status.fetch('exitstatus') == 0 && status.fetch('timed_out') == false &&
        status.fetch('signaled') == false && status['spawn_error'].nil? && status.fetch('reported_clickhouse_codes', []).empty?
    end

    def write_summary(classification)
      return unless @root && Dir.exist?(@root) && !File.exist?(File.join(@root, 'summary.json'))
      write_json(File.join(@root, 'summary.json'), {
        'format' => 'simple_aggregate_bulk_w222_summary_v1', 'classification' => classification,
        'success' => classification == 'paired_recursive_simple_aggregate_bulk_observed', 'error' => @fatal,
        'evidence_root' => @root, 'source_matrix_path' => @matrix_path,
        'source_matrix_sha256' => @source_matrix_sha,
        'runtime_pin' => @clickhouse_pin,
        'helper' => {'path' => @helper, 'sha256' => @helper_sha},
        'counts' => {'expected_profiles' => 39, 'stock_profiles_validated' => @profiles.length,
          'generic_helper_profiles' => @helper_profiles.length, 'library_parts' => @generated_parts.length,
          'native_cases' => @records.length,
          'native_observed' => @records.count { |item| item.fetch('classification', '') == 'physical_observed' },
          'invocations' => @invocations.length},
        'partial_evidence_locations' => {'invocations' => 'invocations/', 'generated' => 'generated/', 'cases' => 'cases/'},
      })
    end
  end

  class Recorder
    def initialize(probe)
      @probe = probe
      @root = probe.root
      @sequence = 0
    end

    def write_case(directory, record)
      @probe.write_json(File.join(directory, 'case.json'), record)
    end

    def run_clickhouse(label, store, sql, input: nil, multiquery: false, extra_args: [])
      argv = [@probe.instance_variable_get(:@binary), 'local', '--path', store, '--session_timezone=UTC',
        '--enable_time_time64_type=1', '--max_threads=1', '--max_insert_threads=1',
        '--max_execution_time=30', "--max_memory_usage=#{MEMORY_LIMIT_BYTES}"]
      argv << '--multiquery' if multiquery
      argv.concat(extra_args)
      argv.concat(['--query', sql])
      run(label, argv, input, PROCESS_TIMEOUT_SECONDS, {'TZ' => 'UTC'}, 'clickhouse', sql_record: sql)
    end

    def run_helper(label, input_path, output_root, capture_root)
      argv = [@probe.instance_variable_get(:@helper), input_path, output_root, capture_root]
      run(label, argv, nil, HELPER_TIMEOUT_SECONDS, {'TZ' => 'UTC'}, 'crystal_helper')
    end

    private

    def run(label, argv, input, timeout, environment, role, sql_record: nil)
      @sequence += 1
      stem = format('%05d-%s', @sequence, label.gsub(/[^A-Za-z0-9_.-]/, '_'))
      prefix = File.join(@root, 'invocations', stem)
      @probe.write_new(prefix + '.sql', sql_record || input || "#{role}: #{argv.join(' ')}\n") if role == 'clickhouse'
      @probe.write_new(prefix + '.argv.json', JSON.pretty_generate({'argv' => argv, 'environment' => environment,
        'timeout_seconds' => timeout, 'process_group' => 'inherited', 'role' => role,
        'stdin_bytes' => input && input.bytesize, 'stdin_sha256' => input && Digest::SHA256.hexdigest(input)}) + "\n")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stdout_bytes = ''.b
      stderr_bytes = ''.b
      status = nil
      timed_out = false
      spawn_error = nil
      waiter = nil
      readers = []
      stdin = stdout = stderr = nil
      begin
        # Preserve the outer run_safe group. Bounded termination targets only
        # the positive child pid so the guard retains ownership of descendants.
        stdin, stdout, stderr, waiter = Open3.popen3(environment, *argv)
        [stdin, stdout, stderr].each(&:binmode)
        readers = [Thread.new { stdout.read }, Thread.new { stderr.read }]
        stdin.write(input.b) if input
        stdin.close
        unless waiter.join(timeout)
          timed_out = true
          terminate_child(waiter)
        end
        status = waiter.value
        stdout_bytes = readers[0].value
        stderr_bytes = readers[1].value
      rescue StandardError => error
        spawn_error = "#{error.class}: #{error.message}"
      ensure
        terminate_child(waiter) if waiter && waiter.alive?
        waiter.join if waiter
        [stdin, stdout, stderr].compact.each do |pipe|
          pipe.close unless pipe.closed?
        rescue IOError
          nil
        end
        readers.each(&:join)
      end
      codes = (stdout_bytes + stderr_bytes).scan(/(?:^|[^A-Za-z0-9_])Code:[\x09-\x0d\x20]*([0-9]+)(?![A-Za-z0-9_])/n).flatten.map(&:to_i).uniq
      process_status = {'success' => status && status.success? || false, 'exitstatus' => status && status.exitstatus,
        'signaled' => status && status.signaled? || false, 'termsig' => status && status.termsig,
        'timed_out' => timed_out, 'duration_ms' => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
        'reported_clickhouse_codes' => codes}
      process_status['spawn_error'] = spawn_error if spawn_error
      @probe.write_new(prefix + '.stdout', stdout_bytes)
      @probe.write_new(prefix + '.stderr', stderr_bytes)
      @probe.write_json(prefix + '.status.json', process_status)
      record = {'stem' => prefix.delete_prefix(@root + File::SEPARATOR), 'role' => role,
        'status' => process_status, 'argv_sha256' => Digest::SHA256.file(prefix + '.argv.json').hexdigest,
        'stdout_sha256' => Digest::SHA256.hexdigest(stdout_bytes), 'stderr_sha256' => Digest::SHA256.hexdigest(stderr_bytes)}
      @probe.instance_variable_get(:@invocations) << record
      {stdout: stdout_bytes, stderr: stderr_bytes, status: process_status, record: record, prefix: prefix}
    end

    def terminate_child(waiter)
      return unless waiter && waiter.alive?
      begin
        Process.kill('TERM', waiter.pid)
      rescue Errno::ESRCH
        nil
      end
      unless waiter.join(TERM_GRACE_SECONDS)
        begin
          Process.kill('KILL', waiter.pid)
        rescue Errno::ESRCH
          nil
        end
        waiter.join
      end
    end
  end

  def main
    options = {}
    parser = OptionParser.new do |args|
      args.banner = 'Usage: ruby scripts/recheck_simple_aggregate_bulk_w222.rb --clickhouse PATH --crystal-helper PATH --source-matrix PATH --evidence-root FRESH_ROOT'
      args.on('--clickhouse PATH') { |value| options[:clickhouse] = value }
      args.on('--crystal-helper PATH') { |value| options[:crystal_helper] = value }
      args.on('--source-matrix PATH') { |value| options[:source_matrix] = value }
      args.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
    end
    parser.parse!(ARGV)
    raise OptionParser::MissingArgument, 'unexpected positional arguments' unless ARGV.empty?
    %i[clickhouse crystal_helper source_matrix evidence_root].each do |key|
      raise OptionParser::MissingArgument, "--#{key.to_s.tr('_', '-')} is required" unless options[key]
    end
    Probe.new(options).run ? 0 : 1
  rescue StandardError => error
    warn "W222 bulk runner could not establish a paired observation: #{error.class}: #{error.message}"
    2
  end
end

exit(RecheckSimpleAggregateBulkW222.main)
