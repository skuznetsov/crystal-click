#!/usr/bin/env ruby
# Independent raw-evidence audit for the finite W222 recursive SAF qualification.
# This reads captured evidence only; it never invokes ClickHouse or the helper.

require 'digest'
require 'find'
require 'json'
require 'optparse'

module CheckSimpleAggregateEvidenceW222
  extend self

  VERSION = '26.10.1.1201'.freeze
  BUILD_HASH = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  CLICKHOUSE_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  SOURCE_ROOT = '/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1'.freeze
  SOURCE_REVISION = '0ca8150d9b1d0886edb2e3b4ab65eebb768d0357'.freeze
  SOURCE_HASHES = {
    'src/DataTypes/DataTypeCustomSimpleAggregateFunction.cpp' => '6c4502cdd659d59cc83b953a03399fa37d491f097ca38f445bfa74b1654e877d',
    'src/DataTypes/DataTypesBinaryEncoding.h' => '92c3362477dc283302fc84713413f45fd6c92c7273309c6efb41425d22c5485f',
    'src/DataTypes/DataTypesBinaryEncoding.cpp' => '78ba394f20ccd2a00f5be6b8c4d470fafb1c91a6f87bb27c301c2d3203f28f87',
  }.freeze
  SOURCE_PREFIX = '/private/tmp/crystal-click-w222-physical.'.freeze
  EVIDENCE_PREFIX = '/private/tmp/crystal-click-w222-bulk.'.freeze
  INVALIDATED_FILE = 'invalidated_system_columns.txt'.freeze
  INVALIDATED_NAMES = %w[_block_number _block_offset].freeze
  STOCK_TABLE_SETTINGS = [
    'index_granularity=2', 'index_granularity_bytes=10485760', 'enable_mixed_granularity_parts=1',
    'min_rows_for_wide_part=0', 'min_bytes_for_wide_part=0', 'min_level_for_wide_part=0',
    'compress_marks=0', 'compress_primary_key=0', 'min_compress_block_size=0', 'max_compress_block_size=4096',
    'ratio_of_defaults_for_sparse_serialization=1.0', "default_compression_codec='LZ4'",
    "nullable_serialization_version='basic'", "serialization_info_version='with_types'",
    'propagate_types_serialization_versions_to_nested_types=1',
  ].freeze
  ROW_KEYS = [11, 22, 33, 44, 55].freeze
  WINDOWS = {
    'full' => (0...5).to_a,
    'middle' => [1, 2, 3],
    'empty' => [],
  }.freeze
  STRING_VERSION = {'single_stream' => 0, 'with_size_stream' => 1}.freeze
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

  def fail!(message)
    raise ArgumentError, message
  end

  def plain_file(path, label)
    fail!("#{label} is missing, symlinked, or not a regular file: #{path}") unless File.file?(path) && !File.symlink?(path)
    path
  end

  def read_json(path, label)
    plain_file(path, label)
    fail!("#{label} exceeds the 64 MiB evidence bound") if File.size(path) > 64 * 1024 * 1024
    JSON.parse(File.binread(path))
  rescue JSON::ParserError => error
    fail!("#{label} is invalid JSON: #{error.message}")
  end

  def sha256(path)
    Digest::SHA256.file(plain_file(path, 'hash input')).hexdigest
  end

  def executable(path, expected_hash, label)
    full = File.expand_path(path)
    fail!("#{label} is absent, symlinked, or non-executable: #{full}") unless
      File.file?(full) && File.executable?(full) && !File.symlink?(full) && File.realpath(full) == full
    fail!("#{label} hash differs from its external pin") unless sha256(full) == expected_hash
    full
  end

  def inventory(part, label)
    fail!("#{label} part is missing, symlinked, or noncanonical: #{part}") unless
      File.directory?(part) && !File.symlink?(part) && File.realpath(part) == part
    files = []
    Find.find(part) do |path|
      next if path == part
      fail!("symlink in #{label} part: #{path}") if File.symlink?(path)
      next if File.directory?(path)
      fail!("non-file entry in #{label} part: #{path}") unless File.file?(path)
      files << {'path' => path[(part.length + 1)..-1], 'size' => File.size(path), 'sha256' => sha256(path)}
    end
    files.sort_by { |entry| entry.fetch('path') }
  end

  def path_under(root, relative, label)
    fail!("#{label} path is not relative") unless relative.is_a?(String) && !relative.empty? && !relative.start_with?('/')
    full = File.expand_path(relative, root)
    prefix = root + File::SEPARATOR
    fail!("#{label} escapes its root") unless full.start_with?(prefix)
    cursor = root
    relative.split(File::SEPARATOR).each_with_index do |component, index|
      fail!("#{label} has invalid path components") if component.empty? || component == '.' || component == '..'
      cursor = File.join(cursor, component)
      stat = File.lstat(cursor)
      fail!("#{label} has a symlink component") if stat.symlink?
      if index < relative.split(File::SEPARATOR).length - 1
        fail!("#{label} has a non-directory parent") unless stat.directory?
      else
        fail!("#{label} is not a regular file") unless stat.file?
      end
    end
    fail!("#{label} path is noncanonical") unless File.realpath(full) == full
    full
  rescue Errno::ENOENT, Errno::EACCES => error
    fail!("#{label} cannot be resolved: #{error.message}")
  end

  def expected_profiles
    result = []
    SPECS.each do |base, source_function, canonical_function, storage_type, category|
      modes = storage_type.match?(/(?:^|[^A-Za-z0-9_])String(?:[^A-Za-z0-9_]|$)/) ? %w[single_stream with_size_stream] : [nil]
      modes.each do |mode|
        result << {
          'id' => base + (mode ? "_#{mode}" : ''), 'source_function' => source_function,
          'canonical_function' => canonical_function, 'storage_type' => storage_type,
          'category' => category, 'string_serialization_mode' => mode || 'omitted_default',
          'source_string_serialization_mode' => mode || 'with_size_stream',
        }
      end
    end
    fail!('independent W222 auditor roster is not exactly 39') unless result.length == 39
    fail!('independent W222 auditor roster contains duplicate ids') unless result.map { |item| item.fetch('id') }.uniq.length == 39
    result
  end

  def declared_type(profile)
    "SimpleAggregateFunction(#{profile.fetch('canonical_function')}, #{profile.fetch('storage_type')})"
  end

  def source_type(profile)
    "SimpleAggregateFunction(#{profile.fetch('source_function')}, #{profile.fetch('storage_type')})"
  end

  def spec_name(spec, depth = 0)
    fail!('literal storage spec exceeds the depth bound') if depth > 32
    case spec.fetch('kind')
    when 'fixed', 'string'
      spec.fetch('name')
    when 'array', 'nullable'
      "#{spec.fetch('kind') == 'array' ? 'Array' : 'Nullable'}(#{spec_name(spec.fetch('child'), depth + 1)})"
    when 'tuple'
      children = spec.fetch('children')
      names = spec.fetch('field_names')
      fail!('Tuple field-name count differs') unless names.empty? || names.length == children.length
      fields = children.each_with_index.map do |child, index|
        child_name = spec_name(child, depth + 1)
        names.empty? ? child_name : "#{names.fetch(index)} #{child_name}"
      end
      "Tuple(#{fields.join(', ')})"
    when 'map'
      "Map(#{spec_name(spec.fetch('key'), depth + 1)}, #{spec_name(spec.fetch('value'), depth + 1)})"
    else
      fail!("unlisted storage spec kind #{spec.fetch('kind').inspect}")
    end
  end

  def decode_hex(hex, label)
    fail!("#{label} is not even lowercase hex") unless hex.is_a?(String) && hex.bytesize.even? && hex.match?(/\A(?:[0-9a-f]{2})*\z/)
    [hex].pack('H*').b
  end

  def varuint(value)
    fail!('negative RowBinary length') unless value >= 0
    output = +''.b
    remaining = value
    while remaining >= 0x80
      output << ((remaining & 0x7f) | 0x80)
      remaining >>= 7
    end
    output << remaining
  end

  def encode_value(spec, value, depth = 0)
    fail!('literal value exceeds the depth bound') if depth > 32
    case spec.fetch('kind')
    when 'fixed'
      bytes = decode_hex(value.fetch('raw_hex'), spec.fetch('name'))
      fail!("#{spec.fetch('name')} literal width differs") unless bytes.bytesize == spec.fetch('width')
      bytes
    when 'string'
      bytes = decode_hex(value.fetch('raw_hex'), 'String literal')
      varuint(bytes.bytesize) + bytes
    when 'array'
      fail!('Array row literal is not an Array') unless value.is_a?(Array) && value.length <= 1_000_000
      varuint(value.length) + value.map { |child| encode_value(spec.fetch('child'), child, depth + 1) }.join.b
    when 'tuple'
      children = spec.fetch('children')
      fail!('Tuple row arity differs') unless value.is_a?(Array) && value.length == children.length
      children.each_with_index.map { |child, index| encode_value(child, value.fetch(index), depth + 1) }.join.b
    when 'map'
      fail!('Map row literal is not an entry Array') unless value.is_a?(Array) && value.length <= 1_000_000
      pairs = value.map do |pair|
        fail!('Map row entry is not a key/value pair') unless pair.is_a?(Array) && pair.length == 2
        encode_value(spec.fetch('key'), pair.fetch(0), depth + 1) + encode_value(spec.fetch('value'), pair.fetch(1), depth + 1)
      end
      varuint(pairs.length) + pairs.join.b
    when 'nullable'
      value.nil? ? "\x01".b : "\x00".b + encode_value(spec.fetch('child'), value, depth + 1)
    else
      fail!("unlisted row literal kind #{spec.fetch('kind').inspect}")
    end
  end

  def expected_rowbinary(profile, indices)
    output = +''.b
    spec = profile.fetch('storage_spec')
    indices.each do |index|
      row = profile.fetch('rowbinary_values').fetch(index)
      value_bytes = encode_value(spec, row.fetch('value'))
      fail!("independent literal encoding differs from hex field for #{profile.fetch('id')}/#{index}") unless
        value_bytes.unpack1('H*') == row.fetch('value_rowbinary_hex')
      output << [row.fetch('key')].pack('Q<') << value_bytes
    end
    output
  end

  def process_ok!(status, label)
    fail!("#{label} is not an actual successful process: #{status.inspect}") unless
      status.fetch('success') == true && status.fetch('exitstatus') == 0 &&
      status.fetch('timed_out') == false && status.fetch('signaled') == false &&
      status['spawn_error'].nil? && status.fetch('reported_clickhouse_codes', []).empty?
  end

  def invocation(root, stem, clickhouse, helper, expected_executable, require_inherited: true)
    argv_path = path_under(root, stem + '.argv.json', "#{stem} argv")
    status_path = path_under(root, stem + '.status.json', "#{stem} status")
    stdout_path = path_under(root, stem + '.stdout', "#{stem} stdout")
    stderr_path = path_under(root, stem + '.stderr', "#{stem} stderr")
    argv = read_json(argv_path, "#{stem} argv")
    status = read_json(status_path, "#{stem} status")
    process_ok!(status, stem)
    fail!("#{stem} process used a non-pinned executable") unless argv.fetch('argv').first == expected_executable && [clickhouse, helper].include?(expected_executable)
    process_policy_ok = argv.fetch('environment') == {'TZ' => 'UTC'}
    process_policy_ok &&= argv.fetch('process_group') == 'inherited' if require_inherited
    fail!("#{stem} process policy differs") unless process_policy_ok
    stdout = File.binread(stdout_path)
    File.binread(stderr_path)
    sql_path = stem + '.sql'
    sql = File.file?(File.join(root, sql_path)) ? File.binread(path_under(root, sql_path, "#{stem} SQL")) : nil
    [argv, status, stdout, sql]
  end

  def tagged_rows(stdout, tag)
    stdout.dup.force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp).each_with_object([]) do |line, result|
      fields = line.split("\t", -1)
      result << fields if fields.first == tag
    end
  end

  def parse_substreams(text, label)
    fail!("#{label} columns_substreams is not newline terminated") unless text.end_with?("\n")
    lines = text.lines.map(&:chomp)
    fail!("#{label} columns_substreams header differs") unless lines.shift == 'columns substreams version: 1' && lines.shift == '2 columns:'
    result = {}
    %w[pk v].each do |column|
      match = /\A([1-9][0-9]*) substreams for column `([^`]+)`:\z/.match(lines.shift.to_s)
      fail!("#{label} substream count/header differs for #{column}") unless match && match[2] == column
      count = Integer(match[1], 10)
      fail!("#{label} substream count exceeds the three-lane bound") unless count <= (column == 'pk' ? 1 : 64)
      names = []
      count.times do
        entry = /\A\t([^\t\r\n]+)\z/.match(lines.shift.to_s)
        fail!("#{label} has a malformed substream name") unless entry
        names << entry[1]
      end
      fail!("#{label} has duplicate substream names") unless names.uniq.length == names.length
      result[column] = names.sort
    end
    fail!("#{label} has trailing substream metadata") unless lines.empty?
    result
  rescue ArgumentError => error
    fail!("#{label} substream metadata is invalid: #{error.message}")
  end

  def validate_source!(source_path, clickhouse)
    full = File.expand_path(source_path)
    source_root = File.dirname(full)
    fail!('source matrix is not a canonical W222 physical root child') unless
      File.basename(full) == 'matrix.json' && File.file?(full) && !File.symlink?(full) && File.realpath(full) == full &&
      source_root.start_with?(SOURCE_PREFIX) && File.dirname(source_root) == '/private/tmp' && File.realpath(source_root) == source_root
    matrix = read_json(full, 'stock source matrix')
    manifest = read_json(File.join(source_root, 'manifest.json'), 'stock source manifest')
    expected = expected_profiles
    profiles = matrix.fetch('matrix')
    fail!('stock physical matrix is not the exact 39-positive source witness') unless
      matrix.fetch('case_count') == 39 && matrix.fetch('stock_physical_observed') == 39 &&
      matrix.fetch('stock_construction_mismatches') == 0 && matrix.fetch('physical_mismatches') == 0 &&
      matrix.fetch('probe_failures') == 0 && profiles.length == 39
    pin = matrix.fetch('source_pin')
    expected_source = "#{SOURCE_ROOT}@#{SOURCE_REVISION}"
    fail!('stock source snapshot pin differs') unless pin.fetch('source_reference') == expected_source &&
      pin.fetch('source_revision_from_task_context_not_git_revalidated') == SOURCE_REVISION &&
      pin.fetch('runtime_built_from_this_snapshot_not_asserted') == true
    actual_hashes = pin.fetch('file_hashes').each_with_object({}) do |entry, result|
      fail!("stock source anchor differs: #{entry.fetch('path')}") unless
        entry.fetch('matches') == true && entry.fetch('expected_sha256') == entry.fetch('actual_sha256') &&
        SOURCE_HASHES[entry.fetch('path')] == entry.fetch('actual_sha256')
      result[entry.fetch('path')] = entry.fetch('actual_sha256')
    end
    fail!('stock source anchor roster differs') unless actual_hashes == SOURCE_HASHES
    runtime = matrix.fetch('runtime_pin')
    fail!('stock source fixture has a different runtime pin') unless
      runtime.fetch('runtime_sha256') == CLICKHOUSE_SHA256 && runtime.fetch('runtime_version') == VERSION &&
      runtime.fetch('runtime_build_hash') == BUILD_HASH && runtime.fetch('runtime_source_correlation') == 'not_asserted'
    fail!('stock source manifest source/runtime distinction differs') unless
      manifest.fetch('source_pin').fetch('source_reference') == expected_source &&
      manifest.fetch('runtime_pin_expected') == {'version' => VERSION, 'build_hash' => BUILD_HASH, 'sha256' => CLICKHOUSE_SHA256} &&
      manifest.fetch('runtime_built_from_comparison_source_not_asserted') == true && manifest.fetch('case_count') == 39
    fail!('stock source manifest roster differs') unless manifest.fetch('case_roster').map { |item| item.fetch('id') } == expected.map { |item| item.fetch('id') }
    fail!('stock source roster order differs from independent list') unless profiles.map { |item| item.fetch('id') } == expected.map { |item| item.fetch('id') }

    profiles.each_with_index do |profile, index|
      law = expected.fetch(index)
      declared = "SimpleAggregateFunction(#{law.fetch('canonical_function')}, #{law.fetch('storage_type')})"
      source_declared = "SimpleAggregateFunction(#{law.fetch('source_function')}, #{law.fetch('storage_type')})"
      spec = profile.fetch('storage_spec')
      fail!("stock profile law differs for #{law.fetch('id')}") unless
        profile.fetch('classification') == 'stock_physical_observed' && profile.fetch('source_function') == law.fetch('source_function') &&
        profile.fetch('canonical_function') == law.fetch('canonical_function') && profile.fetch('category') == law.fetch('category') &&
        profile.fetch('source_type') == source_declared && profile.fetch('declared_type') == declared &&
        profile.fetch('storage_type') == law.fetch('storage_type') && spec_name(spec) == law.fetch('storage_type') &&
        profile.fetch('string_serialization_mode') == law.fetch('string_serialization_mode') &&
        profile.fetch('source_string_serialization_mode') == law.fetch('source_string_serialization_mode') &&
        profile.fetch('row_keys') == ROW_KEYS && profile.fetch('mark_rows') == [2, 2, 1] &&
        profile.fetch('construction_expectation') == 'strict_stock_construction_positive; failure is not skipped'
      fail!("stock row count differs for #{law.fetch('id')}") unless profile.fetch('rowbinary_values').length == 5
      physical = profile.fetch('physical')
      copied_part = File.expand_path(physical.fetch('copied_part_path'))
      source_part = File.expand_path(physical.fetch('source_part_path'))
      copied_prefix = File.join(source_root, 'parts') + File::SEPARATOR
      source_prefix = File.join(source_root, 'stores') + File::SEPARATOR
      fail!("stock copied part escaped the physical evidence root for #{law.fetch('id')}") unless copied_part.start_with?(copied_prefix)
      fail!("stock original part escaped its isolated source store for #{law.fetch('id')}") unless source_part.start_with?(source_prefix)
      recorded_part_inventory = physical.fetch('part_file_inventory')
      fail!("stock original/copied part inventory differs for #{law.fetch('id')}") unless
        inventory(copied_part, "#{law.fetch('id')} copied part") == recorded_part_inventory &&
        inventory(source_part, "#{law.fetch('id')} original part") == recorded_part_inventory
      fail!("stock physical type/grid differs for #{law.fetch('id')}") unless
        physical.fetch('canonical_declared_type') == declared && physical.fetch('source_type') == source_declared &&
        physical.fetch('row_count') == 5 && physical.fetch('native_mark_count_with_terminal') == 4 && physical.fetch('real_mark_rows_expected') == [2, 2, 1]
      WINDOWS.each do |window, indices|
        expected_bytes = expected_rowbinary(profile, indices)
        record = physical.fetch('rowbinary').fetch(window)
        path = path_under(source_root, record.fetch('path'), "#{law.fetch('id')} source #{window} RowBinary")
        actual = File.binread(path)
        fail!("stock #{window} RowBinary differs from independent literal bytes for #{law.fetch('id')}") unless
          actual == expected_bytes && record.fetch('matches_independent_literal') == true &&
          record.fetch('bytes') == actual.bytesize && record.fetch('sha256') == Digest::SHA256.hexdigest(actual)
      end
      %w[create insert inspect].each do |phase|
        stem = profile.fetch('processes').fetch(phase)
        argv, status, stdout, sql = invocation(source_root, stem, clickhouse, clickhouse, clickhouse, require_inherited: false)
        fail!("stock #{phase} argv is not a ClickHouse local process") unless argv.fetch('argv')[1] == 'local'
        fail!("stock #{phase} has an unexpected nonempty stderr") unless File.size(path_under(source_root, stem + '.stderr', 'source stderr')) == 0
        table = 'saf_w222_' + law.fetch('id').gsub(/[^A-Za-z0-9_.-]/, '_')
        argv_values = argv.fetch('argv')
        ts_enabled = law.fetch('category') == 'time_series'
        fail!("stock #{phase} experimental setting differs for #{law.fetch('id')}") unless
          argv_values.include?('--enable_time_series_aggregate_functions=1') == ts_enabled
        if phase == 'create'
          ddl_settings = STOCK_TABLE_SETTINGS.dup
          mode = law.fetch('string_serialization_mode')
          ddl_settings << "string_serialization_version='#{mode}'" unless mode == 'omitted_default'
          expected_ddl = "CREATE TABLE default.#{table} (pk UInt64, v #{source_declared}) ENGINE=MergeTree ORDER BY pk SETTINGS #{ddl_settings.join(', ')};"
          fail!("stock CREATE SQL differs from the independently declared source type/settings for #{law.fetch('id')}") unless sql && sql.strip == expected_ddl
        elsif phase == 'insert'
          input = profile.fetch('rowbinary_input')
          input_path = path_under(source_root, input.fetch('path'), "#{law.fetch('id')} source INSERT RowBinary")
          input_bytes = File.binread(input_path)
          expected_input = expected_rowbinary(profile, [0, 1, 2, 3, 4])
          fail!("stock INSERT RowBinary differs from independent literal bytes for #{law.fetch('id')}") unless
            input_bytes == expected_input && input.fetch('bytes') == input_bytes.bytesize &&
            input.fetch('sha256') == Digest::SHA256.hexdigest(input_bytes) &&
            argv.fetch('stdin_bytes') == input_bytes.bytesize && argv.fetch('stdin_sha256') == Digest::SHA256.hexdigest(input_bytes) &&
            sql && sql.strip == "INSERT INTO default.#{table} FORMAT RowBinary"
        else
          rowbinary = physical.fetch('rowbinary')
          expected_queries = {
            'full' => "SELECT pk, v FROM default.#{table} ORDER BY pk INTO OUTFILE '#{File.expand_path(rowbinary.fetch('full').fetch('path'), source_root)}' FORMAT RowBinary;",
            'middle' => "SELECT pk, v FROM default.#{table} WHERE pk BETWEEN 22 AND 44 ORDER BY pk INTO OUTFILE '#{File.expand_path(rowbinary.fetch('middle').fetch('path'), source_root)}' FORMAT RowBinary;",
            'empty' => "SELECT pk, v FROM default.#{table} WHERE pk=0 INTO OUTFILE '#{File.expand_path(rowbinary.fetch('empty').fetch('path'), source_root)}' FORMAT RowBinary;",
          }
          sql_lines = sql.to_s.lines.map(&:chomp)
          fail!("stock inspect query does not target the recorded RowBinary windows for #{law.fetch('id')}") unless
            expected_queries.values.all? { |query| sql_lines.include?(query) } &&
            sql_lines.include?("CHECK TABLE default.#{table} FORMAT TabSeparated;")
        end
      end
    end
    pins = {
      'evidence/processes/00001-pin-version' => ['SELECT version() FORMAT TSVRaw', VERSION],
      'evidence/processes/00002-pin-build' => [
        "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw",
        "VERSION_GITHASH=#{BUILD_HASH}",
      ],
    }
    pins.each do |stem, (expected_sql, expected_stdout)|
      argv, _status, stdout, sql = invocation(source_root, stem, clickhouse, clickhouse, clickhouse, require_inherited: false)
      fail!("stock source pin invocation is not a ClickHouse local query: #{stem}") unless
        argv.fetch('argv')[1] == 'local' && sql == expected_sql + "\n" && argv.fetch('argv').last(2) == ['--query', expected_sql] &&
        stdout.strip == expected_stdout
    end
    status_files = Dir.glob(File.join(source_root, 'evidence', 'processes', '*.status.json'))
    fail!('stock source process census differs from 119 actual successful invocations') unless status_files.length == 119
    [full, source_root, matrix, expected]
  end

  def expected_invocations(expected)
    roles = {
      'invocations/00001-pin-version' => 'clickhouse',
      'invocations/00002-pin-build' => 'clickhouse',
      'invocations/00003-generic-stock-read-library-write-read' => 'crystal_helper',
      'invocations/00004-create-39-native-targets' => 'clickhouse',
    }
    expected.each_with_index do |profile, index|
      label = "#{profile.fetch('id')}-attach-check-rowbinary".gsub(/[^A-Za-z0-9_.-]/, '_')
      roles[File.join('invocations', format('%05d-%s', index + 5, label))] = 'clickhouse'
    end
    roles
  end

  def check_inventory_delta!(before, after, part, id, record)
    before_by = before.each_with_object({}) { |entry, hash| hash[entry.fetch('path')] = entry }
    after_by = after.each_with_object({}) { |entry, hash| hash[entry.fetch('path')] = entry }
    removed = before_by.keys - after_by.keys
    changed = (before_by.keys & after_by.keys).select { |path| before_by.fetch(path) != after_by.fetch(path) }
    added = after_by.keys - before_by.keys
    fail!("ATTACH changed original part files for #{id}") unless removed.empty? && changed.empty?
    fail!("ATTACH addition set differs for #{id}") unless added == [INVALIDATED_FILE]
    auxiliary_path = File.join(part, INVALIDATED_FILE)
    bytes = File.binread(plain_file(auxiliary_path, "#{id} invalidated system columns"))
    names = bytes.split("\n", -1)
    fail!("#{id} invalidation auxiliary is not exactly two newline-terminated names") unless names.pop == '' && names.length == 2 && names.uniq.sort == INVALIDATED_NAMES.sort
    auxiliary = after_by.fetch(INVALIDATED_FILE)
    fail!("#{id} invalidation auxiliary size/hash differs") unless auxiliary.fetch('size') == bytes.bytesize && auxiliary.fetch('sha256') == Digest::SHA256.hexdigest(bytes)
    fail!("#{id} recorded attachment delta differs") unless
      record.fetch('removed_paths') == [] && record.fetch('changed_original_paths') == [] &&
      record.fetch('added_paths') == [INVALIDATED_FILE] && record.fetch('all_original_files_preserved_exactly') == true &&
      record.fetch('only_allowed_source_backed_auxiliary_added') == true &&
      record.fetch('added_file').fetch('path') == INVALIDATED_FILE && record.fetch('added_file').fetch('bytes') == bytes.bytesize &&
      record.fetch('added_file').fetch('sha256') == auxiliary.fetch('sha256') && record.fetch('added_file').fetch('lines_unordered') == INVALIDATED_NAMES.sort
    {'added_path' => INVALIDATED_FILE, 'bytes' => bytes.bytesize, 'sha256' => auxiliary.fetch('sha256'), 'lines' => INVALIDATED_NAMES.sort}
  end

  def check_native_metadata!(profile, case_record, helper_profile, part, inventory_after)
    id = profile.fetch('id')
    metadata = case_record.fetch('native_metadata')
    declared = declared_type(profile)
    columns = File.binread(File.join(part, 'columns.txt'))
    expected_columns = "columns format version: 1\n2 columns:\n`pk` UInt64\n`v` #{declared}\n"
    fail!("native columns.txt differs for #{id}") unless columns == expected_columns && metadata.fetch('columns_txt') == columns
    substreams = File.binread(File.join(part, 'columns_substreams.txt'))
    roster = parse_substreams(substreams, id)
    value_names = helper_profile.fetch('library').fetch('physical_stream_names').sort
    fail!("native substream membership differs for #{id}") unless roster == {'pk' => ['pk'], 'v' => value_names}
    fail!("metadata substream record differs for #{id}") unless metadata.fetch('columns_substreams_txt') == substreams &&
      metadata.fetch('columns_substreams_validation').fetch('observed') == roster && metadata.fetch('columns_substreams_validation').fetch('expected') == {'pk' => ['pk'], 'v' => value_names}

    library_mode = profile.fetch('string_serialization_mode') == 'omitted_default' ? 'single_stream' : profile.fetch('string_serialization_mode')
    source_mode = profile.fetch('source_string_serialization_mode')
    library_json = JSON.parse(File.binread(File.join(part, 'serialization.json')))
    expected_json = {
      'columns' => [{'exact_num_defaults' => true, 'kind' => 'Default', 'name' => 'pk', 'num_defaults' => 0, 'num_rows' => 5}],
      'propagate_types_serialization_versions_to_nested_types' => true,
      'types_serialization_versions' => {'string' => STRING_VERSION.fetch(library_mode)},
      'version' => 1,
    }
    fail!("library serialization JSON differs for #{id}") unless library_json == expected_json
    fail!("Nullable serialization metadata key unexpectedly exists for #{id}") if library_json.keys.any? { |key| key.downcase.include?('nullable') }
    source_json = profile.fetch('physical').fetch('serialization_json')
    fail!("stock source serialization metadata differs for #{id}") unless
      source_json.fetch('columns') == [] && source_json.fetch('propagate_types_serialization_versions_to_nested_types') == true &&
      source_json.fetch('types_serialization_versions') == {'string' => STRING_VERSION.fetch(source_mode)} && source_json.fetch('version') == 1
    expected_codec = 'CODEC(LZ4)'
    codec = File.binread(File.join(part, 'default_compression_codec.txt')).strip
    metadata_version = File.binread(File.join(part, 'metadata_version.txt')).strip
    count = File.binread(File.join(part, 'count.txt')).strip
    fail!("native codec/count/metadata version differs for #{id}") unless
      codec == expected_codec && count == '5' && metadata_version == profile.fetch('physical').fetch('metadata_version_txt')
    fail!("recorded native metadata values differ for #{id}") unless
      metadata.fetch('default_compression_codec_txt') == codec && metadata.fetch('count_txt') == count &&
      metadata.fetch('metadata_version_txt') == metadata_version && metadata.fetch('attached_library_serialization_json') == library_json &&
      metadata.fetch('source_stock_serialization_json') == source_json && metadata.fetch('stock_and_library_metadata_are_not_claimed_identical') == true
    true
  rescue JSON::ParserError => error
    fail!("#{id} native serialization JSON is invalid: #{error.message}")
  end

  def check_case!(root, index, profile, helper_profile, record, targets, clickhouse, helper)
    id = profile.fetch('id')
    declared = declared_type(profile)
    table = 'saf_w222_' + id.gsub(/[^A-Za-z0-9_.-]/, '_').downcase
    fail!("native case identity/type/table differs for #{id}") unless
      record.fetch('id') == id && record.fetch('classification') == 'physical_observed' &&
      record.fetch('declared_type') == declared && record.fetch('table_name') == table &&
      record.fetch('category') == profile.fetch('category') && record.fetch('storage_type') == profile.fetch('storage_type')
    fail!("helper record identity/type differs for #{id}") unless helper_profile.fetch('id') == id &&
      helper_profile.fetch('classification') == 'physical_observed' && helper_profile.fetch('declared_type') == declared
    %w[source library].each do |side|
      side_record = helper_profile.fetch(side)
      fail!("#{id} #{side} source/schema declaration differs") unless
        side_record.fetch('schema_declaration') == declared && side_record.fetch('source_declaration') == declared &&
        side_record.fetch('row_count') == 5
      fail!("#{id} #{side} reader mark schedule differs") unless
        side_record.fetch('real_mark_count') == 3 && side_record.fetch('real_mark_row_counts') == [2, 2, 1] &&
        side_record.fetch('windows') == %w[full first middle final_short first_zero eof_zero]
    end
    expected_library_mode = profile.fetch('string_serialization_mode') == 'omitted_default' ? 'single_stream' : profile.fetch('string_serialization_mode')
    fail!("#{id} source/library ordinary profiles differ") unless
      helper_profile.fetch('source_profile') == profile.fetch('source_string_serialization_mode') &&
      helper_profile.fetch('library_profile') == expected_library_mode &&
      helper_profile.fetch('source').fetch('ordinary_profile') == profile.fetch('source_string_serialization_mode') &&
      helper_profile.fetch('library').fetch('ordinary_profile') == expected_library_mode
    fail!("#{id} generic public scans differ") unless %w[source_public_scan library_public_scan].all? do |key|
      public_scan = helper_profile.fetch(key)
      public_scan.fetch('rows') == 5 && public_scan.fetch('batch_rows') == 2 &&
        public_scan.fetch('batch_schedule') == [[0, 0, 2], [1, 2, 2], [2, 4, 1]] &&
        public_scan.fetch('exact_recursive_values') == true
    end
    fail!("#{id} stock/library physical streams differ") unless
      helper_profile.fetch('source').fetch('physical_stream_names') == helper_profile.fetch('library').fetch('physical_stream_names') &&
      helper_profile.fetch('source').fetch('selected_checksum_names') == helper_profile.fetch('library').fetch('selected_checksum_names')

    invocation_stem = File.join('invocations', format('%05d-%s', index + 5,
      "#{id}-attach-check-rowbinary".gsub(/[^A-Za-z0-9_.-]/, '_')))
    invocation_record = record.fetch('invocation')
    fail!("#{id} case invocation stem differs") unless invocation_record.fetch('stem') == invocation_stem
    argv, status, stdout, sql = invocation(root, invocation_stem, clickhouse, helper, clickhouse)
    fail!("#{id} case process record/status differs") unless status == record.fetch('process_status') &&
      invocation_record.fetch('status') == status && invocation_record.fetch('argv_sha256') == sha256(File.join(root, invocation_stem + '.argv.json')) &&
      invocation_record.fetch('stdout_sha256') == Digest::SHA256.hexdigest(stdout) &&
      invocation_record.fetch('stderr_sha256') == Digest::SHA256.file(File.join(root, invocation_stem + '.stderr')).hexdigest
    fail!("#{id} SQL sidecar is absent or not the executed query") unless sql && argv.fetch('argv').last(2) == ['--query', sql]
    fail!("#{id} attach/check/type SQL differs") unless
      sql.include?("ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0';") &&
      sql.include?("CHECK TABLE default.#{table} FORMAT TSV;") &&
      sql.include?("SELECT '__W222_TYPE__', toTypeName(pk), toTypeName(v) FROM default.#{table} LIMIT 1 FORMAT TSVRaw;")
    expected_queries = {
      'full' => "SELECT pk, v FROM default.#{table} ORDER BY pk INTO OUTFILE ",
      'middle' => "SELECT pk, v FROM default.#{table} WHERE pk BETWEEN 22 AND 44 ORDER BY pk INTO OUTFILE ",
      'empty' => "SELECT pk, v FROM default.#{table} WHERE pk=0 ORDER BY pk INTO OUTFILE ",
    }
    outputs = record.fetch('rowbinary')
    expected_queries.each do |window, prefix|
      output_path = path_under(root, outputs.fetch(window).fetch('path'), "#{id} #{window} RowBinary")
      query = sql.lines.map(&:chomp).find { |line| line.start_with?(prefix) }
      fail!("#{id} executed SQL does not name exact #{window} RowBinary output") unless query && query.include?(output_path) && query.end_with?(' FORMAT RowBinary;')
      bytes = File.binread(output_path)
      expected_bytes = expected_rowbinary(profile, WINDOWS.fetch(window))
      result = outputs.fetch(window)
      fail!("#{id} #{window} RowBinary differs from literal bytes") unless bytes == expected_bytes &&
        result.fetch('bytes') == bytes.bytesize && result.fetch('sha256') == Digest::SHA256.hexdigest(bytes) &&
        result.fetch('expected_bytes') == expected_bytes.bytesize && result.fetch('expected_sha256') == Digest::SHA256.hexdigest(expected_bytes) &&
        result.fetch('matches_independent_literal') == true
    end
    fail!("#{id} native schema/tagged results differ") unless
      tagged_rows(stdout, '__W222_SCHEMA__') == [['__W222_SCHEMA__', 'pk', 'UInt64', '1'], ['__W222_SCHEMA__', 'v', declared, '2']] &&
      tagged_rows(stdout, '__W222_TYPE__') == [['__W222_TYPE__', 'UInt64', declared]]
    part_rows = tagged_rows(stdout, '__W222_PART__')
    target = File.realpath(targets.fetch('table_paths').fetch(id))
    attached = File.realpath(record.fetch('attached_part_path'))
    fail!("#{id} attached part path/grid differs") unless attached == File.join(target, 'all_1_1_0') &&
      part_rows.length == 1 && part_rows.first == ['__W222_PART__', 'all_1_1_0', '5', '4', 'Wide', attached + File::SEPARATOR]
    check_rows = stdout.dup.force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp).select { |line| line.start_with?("all_1_1_0\t") }
    fail!("#{id} CHECK TABLE did not validate the attached part") unless check_rows == ["all_1_1_0\t1\t"]

    generated = File.realpath(record.fetch('generated_part_path'))
    generated_expected = File.join(root, 'generated', 'parts') + File::SEPARATOR
    fail!("#{id} library part escaped generated output root") unless generated.start_with?(generated_expected)
    generated_inventory = inventory(generated, "#{id} generated library")
    before = record.fetch('generated_part_inventory_before_attach')
    detached = record.fetch('detached_part_inventory_before_attach')
    generated_after = record.fetch('generated_part_inventory_after_attach')
    fail!("#{id} original library bytes changed or copied differently") unless
      generated_inventory == before && detached == before && generated_after == before &&
      helper_profile.fetch('library_part_inventory') == before
    attached_inventory = inventory(attached, "#{id} attached part")
    fail!("#{id} attached inventory differs from record") unless attached_inventory == record.fetch('attached_part_inventory_after_operations')
    delta = check_inventory_delta!(before, attached_inventory, attached, id, record.fetch('attachment_inventory_delta'))
    check_native_metadata!(profile, record, helper_profile, attached, attached_inventory)
    case_path = File.join(root, 'cases', 'profiles', format('%03d-%s', index,
      id.gsub(/[^A-Za-z0-9_.-]/, '_')), 'case.json')
    fail!("#{id} per-case record differs from matrix") unless read_json(case_path, "#{id} case record") == record
    {'id' => id, 'declared_type' => declared, 'rowbinary_windows' => outputs.keys.sort,
      'original_files_preserved' => true, 'attach_auxiliary' => delta.fetch('added_path')}
  end

  def audit(options)
    root = File.expand_path(options.fetch(:evidence_root))
    fail!('W222 evidence root is not a canonical direct /private/tmp child') unless
      File.directory?(root) && !File.symlink?(root) && File.realpath(root) == root &&
      root.start_with?(EVIDENCE_PREFIX) && File.dirname(root) == '/private/tmp'
    clickhouse = executable(options.fetch(:clickhouse), CLICKHOUSE_SHA256, 'ClickHouse')
    helper = executable(options.fetch(:crystal_helper), options.fetch(:helper_sha256), 'prebuilt Crystal helper')
    source_path, source_root, source, expected = validate_source!(options.fetch(:source_matrix), clickhouse)
    source_sha = sha256(source_path)
    summary = read_json(File.join(root, 'summary.json'), 'W222 summary')
    fail!('W222 run is not a successful paired observation') unless
      summary.fetch('format') == 'simple_aggregate_bulk_w222_summary_v1' && summary.fetch('success') == true &&
      summary.fetch('classification') == 'paired_recursive_simple_aggregate_bulk_observed' &&
      File.expand_path(summary.fetch('evidence_root')) == root && File.expand_path(summary.fetch('source_matrix_path')) == source_path &&
      summary.fetch('source_matrix_sha256') == source_sha
    expected_runtime = {'version' => VERSION, 'build_hash' => BUILD_HASH, 'sha256' => CLICKHOUSE_SHA256}
    runtime_pin = read_json(File.join(root, 'runtime_pin.json'), 'W222 runtime pin')
    fail!('W222 runtime/helper pins differ') unless runtime_pin.fetch('runtime') == expected_runtime &&
      runtime_pin.fetch('helper').fetch('path') == helper && runtime_pin.fetch('helper').fetch('sha256') == options.fetch(:helper_sha256) &&
      runtime_pin.fetch('comparison_source') == "#{SOURCE_ROOT}@#{SOURCE_REVISION}" &&
      runtime_pin.fetch('runtime_source_correlation') == 'not_asserted'
    fail!('summary runtime pin differs') unless summary.fetch('runtime_pin') == expected_runtime
    fail!('summary helper pin differs') unless summary.fetch('helper').fetch('path') == helper &&
      summary.fetch('helper').fetch('sha256') == options.fetch(:helper_sha256)

    manifest = read_json(File.join(root, 'manifest.json'), 'W222 run manifest')
    fail!('manifest source/runtime identity differs') unless manifest.fetch('source_matrix').fetch('path') == source_path &&
      manifest.fetch('source_matrix').fetch('sha256') == source_sha && manifest.fetch('runtime_expected') == expected_runtime &&
      manifest.fetch('comparison_source') == "#{SOURCE_ROOT}@#{SOURCE_REVISION}" &&
      manifest.fetch('source_and_runtime_correlation_asserted') == false && manifest.fetch('case_roster').map { |row| row.fetch('id') } == expected.map { |row| row.fetch('id') }
    fail!('run manifest overstates physical scope') unless manifest.fetch('physical_scope').include?('39 exact native-constructed profiles') &&
      manifest.fetch('physical_scope').include?('not a Cartesian closure')

    helper_output = read_json(File.join(root, 'generated', 'helper-output.json'), 'generic helper output')
    fail!('generic helper output count/classification differs') unless helper_output.fetch('format') == 'simple_aggregate_bulk_w222_helper_v1' &&
      helper_output.fetch('profile_count') == 39 && helper_output.fetch('physical_observed') == 39 &&
      helper_output.fetch('mismatch_count') == 0 && helper_output.fetch('profiles').length == 39
    helper_profiles = helper_output.fetch('profiles')
    fail!('generic helper roster differs from independent roster') unless helper_profiles.map { |row| row.fetch('id') } == expected.map { |row| row.fetch('id') }
    cases = read_json(File.join(root, 'cases', 'matrix.json'), 'native case matrix')
    fail!('native case matrix is not 39/39 physical') unless cases.fetch('case_count') == 39 &&
      cases.fetch('observed') == 39 && cases.fetch('mismatches') == 0 && cases.fetch('matrix').length == 39
    targets = read_json(File.join(root, 'native-targets.json'), 'native target inventory')
    fail!('native target count/table roster differs') unless targets.fetch('table_count') == 39 &&
      targets.fetch('schema_rows') == 78 && targets.fetch('table_paths').keys.sort == expected.map { |row| row.fetch('id') }.sort

    roles = expected_invocations(expected)
    invocation_dir = File.join(root, 'invocations')
    status_paths = Dir.glob(File.join(invocation_dir, '*.status.json')).sort
    fail!('actual process count differs from 43 required invocations') unless status_paths.length == 43 && summary.fetch('counts').fetch('invocations') == 43
    observed_stems = status_paths.map { |path| path.sub(/\.status\.json\z/, '')[(root.length + 1)..-1] }
    fail!('actual invocation roster differs') unless observed_stems.sort == roles.keys.sort
    roles.each do |stem, role|
      executable_path = role == 'clickhouse' ? clickhouse : helper
      argv, status, stdout, sql = invocation(root, stem, clickhouse, helper, executable_path)
      fail!("#{stem} role differs") unless argv.fetch('role') == role
      fail!("#{stem} stdin accounting differs") unless argv['stdin_bytes'].nil? && argv['stdin_sha256'].nil?
      if role == 'clickhouse'
        fail!("#{stem} SQL sidecar is missing or not the actual --query") unless sql && argv.fetch('argv').last(2) == ['--query', sql]
      else
        fail!("#{stem} helper invocation does not use the fixed input/output paths") unless
          argv.fetch('argv').length == 4 && argv.fetch('argv')[1] == File.join(root, 'generated', 'helper-input.json') &&
          argv.fetch('argv')[2] == File.join(root, 'generated') && argv.fetch('argv')[3] == source_root
        raw_helper_output = JSON.parse(stdout)
        persisted_helper_output = helper_output.dup
        persisted_helper_output['profiles'] = helper_profiles.map do |item|
          item.reject { |key, _value| key == 'library_part_inventory' }
        end
        fail!('persisted helper output differs from actual helper stdout before inventory augmentation') unless
          raw_helper_output == persisted_helper_output
      end
      expected_process = {'stem' => stem, 'role' => role, 'status' => status,
        'argv_sha256' => sha256(File.join(root, stem + '.argv.json')),
        'stdout_sha256' => Digest::SHA256.hexdigest(stdout),
        'stderr_sha256' => Digest::SHA256.file(File.join(root, stem + '.stderr')).hexdigest}
      if stem == 'invocations/00001-pin-version'
        fail!('ClickHouse version command/output differs') unless sql.strip == 'SELECT version() FORMAT TSVRaw' && stdout.strip == VERSION
      elsif stem == 'invocations/00002-pin-build'
        expected_sql = "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw"
        fail!('ClickHouse build command/output differs') unless sql.strip == expected_sql && stdout.strip == "VERSION_GITHASH=#{BUILD_HASH}"
      elsif stem == 'invocations/00003-generic-stock-read-library-write-read'
        helper_record = read_json(File.join(root, 'generated', 'helper-process.json'), 'helper process record')
        fail!('helper process sidecar record differs') unless helper_record == expected_process
      elsif stem == 'invocations/00004-create-39-native-targets'
        fail!('native target invocation record differs') unless targets.fetch('invocation') == expected_process
        expected.each_with_index do |profile, index|
          table = 'saf_w222_' + profile.fetch('id').gsub(/[^A-Za-z0-9_.-]/, '_').downcase
          ddl = "CREATE TABLE default.#{table} (pk UInt64, v #{declared_type(profile)}) ENGINE=MergeTree ORDER BY pk SETTINGS "
          fail!("native target SQL lacks exact type for #{profile.fetch('id')}") unless sql.include?(ddl)
        end
      end
    end
    helper_status_path = File.join(root, 'invocations', '00003-generic-stock-read-library-write-read.status.json')
    helper_status = read_json(helper_status_path, 'helper status')
    fail!('helper status differs from summary process status') unless summary.fetch('counts').fetch('generic_helper_profiles') == 39 && helper_status.fetch('success') == true

    results = []
    expected.each_with_index do |profile, index|
      helper_profile = helper_profiles.fetch(index)
      record = cases.fetch('matrix').fetch(index)
      %w[source_function canonical_function category storage_type].each do |key|
        fail!("case/helper/source law mismatch for #{profile.fetch('id')}/#{key}") unless
          record.fetch(key) == profile.fetch(key) && helper_profile.fetch(key) == profile.fetch(key)
      end
      fail!("stock declared type differs for #{profile.fetch('id')}") unless source.fetch('matrix').fetch(index).fetch('declared_type') == declared_type(profile)
      results << check_case!(root, index, source.fetch('matrix').fetch(index), helper_profile, record, targets, clickhouse, helper)
    end
    summary_counts = summary.fetch('counts')
    fail!('summary counts differ from raw evidence census') unless summary_counts.fetch('expected_profiles') == 39 &&
      summary_counts.fetch('stock_profiles_validated') == 39 && summary_counts.fetch('generic_helper_profiles') == 39 &&
      summary_counts.fetch('library_parts') == 39 && summary_counts.fetch('native_cases') == 39 &&
      summary_counts.fetch('native_observed') == 39 && summary_counts.fetch('invocations') == 43
    puts "W222 evidence audit passed: 39 exact profiles, 43 successful recorded processes, independent literal RowBinary windows, original-file preservation, and the one exact ATTACH auxiliary."
    true
  end

  def parse_options(argv)
    options = {}
    parser = OptionParser.new do |args|
      args.banner = 'Usage: ruby scripts/check_simple_aggregate_evidence_w222.rb --evidence-root PATH --source-matrix PATH --clickhouse PATH --crystal-helper PATH --helper-sha256 SHA256'
      args.on('--evidence-root PATH') { |value| options[:evidence_root] = value }
      args.on('--source-matrix PATH') { |value| options[:source_matrix] = value }
      args.on('--clickhouse PATH') { |value| options[:clickhouse] = value }
      args.on('--crystal-helper PATH') { |value| options[:crystal_helper] = value }
      args.on('--helper-sha256 SHA256') { |value| options[:helper_sha256] = value }
    end
    parser.parse!(argv)
    %i[evidence_root source_matrix clickhouse crystal_helper helper_sha256].each do |key|
      raise OptionParser::MissingArgument, "--#{key.to_s.tr('_', '-')}" unless options[key]
    end
    raise OptionParser::InvalidArgument, '--helper-sha256 must be 64 lowercase hex characters' unless options.fetch(:helper_sha256).match?(/\A[0-9a-f]{64}\z/)
    raise OptionParser::InvalidArgument, 'unexpected positional arguments' unless argv.empty?
    options
  end

  def main(argv)
    audit(parse_options(argv)) ? 0 : 1
  rescue StandardError => error
    warn "W222 evidence audit failed: #{error.class}: #{error.message}"
    1
  end
end

exit(CheckSimpleAggregateEvidenceW222.main(ARGV))
