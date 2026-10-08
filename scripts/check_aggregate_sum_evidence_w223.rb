#!/usr/bin/env ruby
# Read-only raw-evidence audit for W223. This checks recorded process truth and
# bytes against the pinned finite manifest; it does not run ClickHouse/Crystal.

require 'digest'
require 'find'
require 'json'

module CheckAggregateSumEvidenceW223
  extend self

  SOURCE_ROOT = '/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1'.freeze
  SOURCE_REVISION = '0ca8150d9b1d0886edb2e3b4ab65eebb768d0357'.freeze
  VERSION = '26.10.1.1201'.freeze
  BUILD_HASH = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  CLICKHOUSE_SHA256 = 'bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2'.freeze
  SOURCE_PREFIX = '/private/tmp/crystal-click-w223-physical.'.freeze
  EVIDENCE_PREFIX = '/private/tmp/crystal-click-w223-bulk.'.freeze
  ROW_KEYS = [11, 22, 33, 44, 55].freeze
  MARK_ROWS = [2, 2, 1].freeze
  AUXILIARY_NAMES = %w[_block_number _block_offset].freeze
  STOCK_SERIALIZATION_METADATA = {
    'columns' => [], 'propagate_types_serialization_versions_to_nested_types' => true,
    'types_serialization_versions' => {'string' => 1}, 'version' => 1,
  }.freeze
  SUM_LIBRARY_SERIALIZATION_METADATA = {
    'columns' => [{'exact_num_defaults' => true, 'kind' => 'Default', 'name' => 'pk', 'num_defaults' => 0, 'num_rows' => 5}],
    'propagate_types_serialization_versions_to_nested_types' => true,
    'types_serialization_versions' => {'string' => 0}, 'version' => 1,
  }.freeze
  COUNT_LIBRARY_SERIALIZATION_METADATA = {
    'columns' => [], 'propagate_types_serialization_versions_to_nested_types' => true,
    'types_serialization_versions' => {'string' => 1}, 'version' => 1,
  }.freeze
  METADATA_POLICY = {
    'stock_source' => 'columns empty; types_serialization_versions.string=1; serialization.json version=1; metadata_version.txt=0; propagate=true',
    'sum_library_writer' => 'Sum-family generic writer: Default pk record; types_serialization_versions.string=0; serialization.json version=1; metadata_version.txt=0; propagate=true',
    'count_compatibility_writer' => 'Count legacy writer uses PartSchemaMetadata.serialization_metadata (src/crystal_click/wide_part_writer/staged_aggregate_count_part_validator.cr:34): columns empty; types_serialization_versions.string=1; serialization.json version=1; metadata_version.txt=0; propagate=true',
    'difference' => 'stock/Count omitted-default string setting is 1; Sum generic writer single_stream is 0; the two writer paths are intentionally distinct',
  }.freeze
  ATTACHMENT_INVENTORY_POLICY = {
    'scope' => 'native ATTACH preserves every original generated file path, size, and SHA-256; only the exact observed auxiliary file may be added',
    'allowed_added_file' => 'invalidated_system_columns.txt',
    'exact_line_set' => AUXILIARY_NAMES,
    'source_basis' => 'pinned-runtime ATTACH inventory observation; source implementation is not asserted as proof',
    'source_path_scope' => '/Users/sergey/SrcArchives/clickhouse-2026-10-07-depth1@0ca8150d9b1d0886edb2e3b4ab65eebb768d0357:src/Storages/MergeTree/MergeTreeData.cpp#loadPartAndFixMetadataImpl (context only; not hash-pinned)',
  }.freeze
  SOURCE_HASHES = {
    'src/AggregateFunctions/AggregateFunctionSum.cpp' => 'db1bb5a1501bf31bad3f6b48b0942762062733241cd2ba33abb9a43e76d272a6',
    'src/AggregateFunctions/AggregateFunctionSum.h' => '1ced4e3ee877780fd5b5c3547bd6bdd4f4e8c09559702e91838b15871bb9a94d',
    'src/AggregateFunctions/Helpers.h' => '1ef65dadd04fcf968998f35db36f300877550d7732c88d25b8e0fe8109857892',
    'src/DataTypes/DataTypeDomainBool.cpp' => '3de0e1b9e943e381270216d676c46ab8a5cf19bd70f7c41b52831ef0fa9a8d68',
    'src/DataTypes/DataTypeNumberBase.h' => '277d1f9233b3ec0c58a02f8865b28f75320dc09587fe303a0425be47297d54e0',
    'src/DataTypes/DataTypeInterval.h' => '5ad4cc9f20ea828d13f531f25a6d4cfacc8669ea54e26bc1f4fd06d866d6d8a7',
  }.freeze

  def fail!(message)
    raise ArgumentError, message
  end

  def json(path)
    JSON.parse(File.binread(path))
  rescue JSON::ParserError => error
    fail!("invalid JSON #{path}: #{error.message}")
  end

  def sha(path)
    Digest::SHA256.file(path).hexdigest
  end

  def canonical_file!(path, base = nil)
    expanded = File.expand_path(path)
    fail!("path is absent or symlinked: #{expanded}") unless File.file?(expanded) && !File.symlink?(expanded)
    fail!("path has symlinked ancestor or is noncanonical: #{expanded}") unless File.realpath(expanded) == expanded
    if base
      root = File.realpath(base)
      fail!("path escaped expected root: #{expanded}") unless expanded.start_with?(root + File::SEPARATOR)
    end
    expanded
  end

  def safe_root!(path, prefix)
    root = File.expand_path(path)
    fail!("evidence root must be canonical direct child of /private/tmp: #{root}") unless
      File.directory?(root) && !File.symlink?(root) && File.realpath(root) == root &&
      File.dirname(root) == File.realpath('/private/tmp') && root.start_with?(prefix)
    root
  end

  def safe_relative_file!(root, relative)
    fail!("unsafe relative path: #{relative.inspect}") unless relative.is_a?(String) &&
      !relative.empty? && !relative.start_with?('/') && !relative.split('/').include?('..')
    canonical_file!(File.join(root, relative), root)
  end

  def inventory(part)
    full = File.expand_path(part)
    fail!("part directory is missing/symlinked/noncanonical: #{full}") unless
      File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full
    files = []
    Find.find(full) do |path|
      next if path == full
      fail!("symlink inside part: #{path}") if File.symlink?(path)
      next if File.directory?(path)
      fail!("non-file entry inside part: #{path}") unless File.file?(path)
      files << {'path' => path[(full.length + 1)..-1], 'size' => File.size(path), 'sha256' => sha(path)}
    end
    files.sort_by { |item| item.fetch('path') }
  end

  def profile_specs
    rows = [
      ['sum_uint8', 'sum', 'UInt8'], ['sum_uint64', 'sum', 'UInt64'], ['sum_int16', 'sum', 'Int16'],
      ['sum_int128', 'sum', 'Int128'], ['sum_uint256', 'sum', 'UInt256'], ['sum_float32', 'sum', 'Float32'],
      ['sum_float64', 'sum', 'Float64'], ['sum_bfloat16', 'sum', 'BFloat16'], ['sum_bool', 'sum', 'Bool'],
      ['sum_enum8', 'sum', "Enum8('zero' = 0, 'one' = 1)"], ['sum_enum16', 'sum', "Enum16('zero' = 0, 'one' = 1)"],
      ['sum_decimal32', 'sum', 'Decimal(9, 2)'], ['sum_decimal64', 'sum', 'Decimal(18, 4)'],
      ['sum_decimal128', 'sum', 'Decimal(38, 8)'], ['sum_decimal256', 'sum', 'Decimal(76, 12)'],
      ['sum_interval_nanosecond', 'sum', 'IntervalNanosecond'], ['sum_interval_day', 'sum', 'IntervalDay'],
      ['sum_interval_year', 'sum', 'IntervalYear'], ['overflow_uint8', 'sumWithOverflow', 'UInt8'],
      ['overflow_uint128', 'sumWithOverflow', 'UInt128'], ['overflow_uint256', 'sumWithOverflow', 'UInt256'],
      ['overflow_bool', 'sumWithOverflow', 'Bool'], ['overflow_enum8', 'sumWithOverflow', "Enum8('zero' = 0, 'one' = 1)"],
      ['overflow_decimal32', 'sumWithOverflow', 'Decimal(9, 2)'], ['overflow_interval_day', 'sumWithOverflow', 'IntervalDay'],
      ['kahan_float32', 'sumKahan', 'Float32'], ['kahan_float64', 'sumKahan', 'Float64'],
      ['kahan_bfloat16', 'sumKahan', 'BFloat16'], ['kahan_bool', 'sumKahan', 'Bool'],
      ['kahan_enum8', 'sumKahan', "Enum8('zero' = 0, 'one' = 1)"], ['kahan_decimal64', 'sumKahan', 'Decimal(18, 4)', 'sum'],
      ['kahan_interval_day', 'sumKahan', 'IntervalDay', 'sum'], ['sum_nullable_uint64', 'sum', 'Nullable(UInt64)'],
      ['sum_nullable_decimal64', 'sum', 'Nullable(Decimal(18, 4))'],
      ['sum_nullable_enum8', 'sum', "Nullable(Enum8('zero' = 0, 'one' = 1))"],
      ['sum_lc_uint8', 'sum', 'LowCardinality(UInt8)'], ['sum_lc_nullable_uint8', 'sum', 'LowCardinality(Nullable(UInt8))'],
      ['sum_lc_interval_day', 'sum', 'LowCardinality(IntervalDay)'],
      ['sum_lc_nullable_interval_day', 'sum', 'LowCardinality(Nullable(IntervalDay))'],
      ['overflow_nullable_bool', 'sumWithOverflow', 'Nullable(Bool)'], ['kahan_nullable_float64', 'sumKahan', 'Nullable(Float64)'],
      ['kahan_lc_nullable_float32', 'sumKahan', 'LowCardinality(Nullable(Float32))'],
    ]
    rows.map do |id, source, argument, canonical|
      canonical ||= source
      {'id' => id, 'kind' => 'sum', 'source_function' => source, 'canonical_function' => canonical,
        'argument_type' => argument, 'declared_type' => "AggregateFunction(#{canonical}, #{argument})"}
    end << {'id' => 'count_compatibility', 'kind' => 'count', 'source_function' => 'count',
      'canonical_function' => 'count', 'argument_type' => nil, 'declared_type' => 'AggregateFunction(count)'}
  end

  def base_types
    %w[UInt8 UInt16 UInt32 UInt64 UInt128 UInt256 Int8 Int16 Int32 Int64 Int128 Int256 Float32 Float64 BFloat16] +
      ['Bool', "Enum8('zero' = 0, 'one' = 1)", "Enum16('zero' = 0, 'one' = 1)", 'Decimal(9, 2)',
       'Decimal(18, 4)', 'Decimal(38, 8)', 'Decimal(76, 12)', 'IntervalNanosecond', 'IntervalMicrosecond',
       'IntervalMillisecond', 'IntervalSecond', 'IntervalMinute', 'IntervalHour', 'IntervalDay', 'IntervalWeek',
       'IntervalMonth', 'IntervalQuarter', 'IntervalYear']
  end

  def safe_label(text)
    text.gsub(/[^A-Za-z0-9_.-]/, '_').downcase
  end

  def construction_specs
    rows = []
    base_types.each do |argument|
      label = safe_label(argument)
      rows << ['construct_sum_' + label, 'sum', argument]
      rows << ['construct_overflow_' + label, 'sumWithOverflow', argument]
    end
    [
      ['construct_kahan_float32', 'Float32'], ['construct_kahan_float64', 'Float64'],
      ['construct_kahan_bfloat16', 'BFloat16'], ['construct_kahan_uint8', 'UInt8'],
      ['construct_kahan_uint256', 'UInt256'], ['construct_kahan_bool', 'Bool'],
      ['construct_kahan_enum8', "Enum8('zero' = 0, 'one' = 1)"], ['construct_kahan_decimal32', 'Decimal(9, 2)'],
      ['construct_kahan_decimal256', 'Decimal(76, 12)'], ['construct_kahan_interval_nano', 'IntervalNanosecond'],
      ['construct_kahan_interval_year', 'IntervalYear'], ['construct_kahan_nullable_float64', 'Nullable(Float64)'],
    ].each { |id, argument| rows << [id, 'sumKahan', argument] }
    rows.map do |id, source, argument|
      canonical = source == 'sumKahan' && argument.match?(/\A(?:Decimal|Interval)/) ? 'sum' : source
      {'id' => id, 'source_function' => source, 'canonical_function' => canonical,
        'argument_type' => argument, 'input_type' => "AggregateFunction(#{source}, #{argument})",
        'expected_storage_type' => "AggregateFunction(#{canonical}, #{argument})"}
    end
  end

  def expected_rowbinary(profile, indices)
    states = profile.fetch('literal_state_hex')
    fail!("invalid literal state hex for #{profile['id']}") unless states.length == 5 &&
      states.all? { |hex| hex.is_a?(String) && hex.match?(/\A(?:[0-9a-f]{2})*\z/) }
    indices.map { |index| [ROW_KEYS.fetch(index)].pack('Q<') + [states.fetch(index)].pack('H*') }.join.b
  end

  def expected_invocation_record(root, label, argv_path)
    argv_record = json(argv_path)
    stem = argv_path.sub(/\.argv\.json\z/, '')
    status = json(stem + '.status.json')
    {
      'label' => label, 'stem' => stem[(root.length + 1)..-1], 'role' => argv_record.fetch('role'),
      'status' => status, 'argv_sha256' => sha(argv_path), 'stdout_sha256' => sha(stem + '.stdout'),
      'stderr_sha256' => sha(stem + '.stderr'),
    }
  end

  class Auditor
    include CheckAggregateSumEvidenceW223

    def initialize(root)
      @root = CheckAggregateSumEvidenceW223.safe_root!(root, EVIDENCE_PREFIX)
      @summary = json(File.join(@root, 'summary.json'))
      @source_root = CheckAggregateSumEvidenceW223.safe_root!(@summary.fetch('source_root'), SOURCE_PREFIX)
      @invocations = {}
    end

    def run
      audit_pins!
      audit_matrix!
      audit_processes!
      audit_profiles!
      audit_construction!
      puts JSON.pretty_generate({'result' => 'raw_evidence_consistent', 'physical_profiles' => 43,
        'construction_cases' => 78, 'successful_invocations' => @invocations.length,
        'evidence_root' => @root, 'source_root' => @source_root})
      true
    rescue StandardError => error
      warn "W223 evidence audit failed: #{error.class}: #{error.message}"
      false
    end

    private

    def file(path, base = @root)
      CheckAggregateSumEvidenceW223.canonical_file!(path, base)
    end

    def json_file(path, base = @root)
      CheckAggregateSumEvidenceW223.json(file(path, base))
    end

    def source_json(path)
      CheckAggregateSumEvidenceW223.json(file(path, @source_root))
    end

    def audit_pins!
      fail!('summary classification is not successful') unless @summary.fetch('format') == 'aggregate_sum_w223_summary_v1' &&
        @summary.fetch('classification') == 'paired_sum_family_bulk_observed' && @summary.fetch('success') == true && @summary['error'].nil?
      fail!('summary completion counts differ') unless @summary.fetch('counts').fetch('expected_profiles') == 43 &&
        @summary.fetch('counts').fetch('expected_construction_cases') == 78 &&
        @summary.fetch('counts').fetch('construction_observed') == 78 &&
        @summary.fetch('counts').fetch('stock_observed') == 43 &&
        @summary.fetch('counts').fetch('generic_helper_observed') == 43 &&
        @summary.fetch('counts').fetch('native_attached_observed') == 43
      @manifest = json_file(File.join(@root, 'manifest.json'))
      @runtime = json_file(File.join(@root, 'runtime_pin.json'))
      fail!('manifest Sum/Count serialization policy differs from exact source-backed expectations') unless
        @manifest.fetch('metadata_policy') == METADATA_POLICY
      fail!('runtime/source pin mismatch') unless @manifest.fetch('runtime_expected') ==
        {'version' => VERSION, 'build_hash' => BUILD_HASH, 'sha256' => CLICKHOUSE_SHA256} &&
        @runtime.fetch('runtime').fetch('version') == VERSION && @runtime.fetch('runtime').fetch('build_hash') == BUILD_HASH &&
        @runtime.fetch('runtime').fetch('sha256') == CLICKHOUSE_SHA256 &&
        @runtime.fetch('source_comparison_pin') == "#{SOURCE_ROOT}@#{SOURCE_REVISION}" &&
        @runtime.fetch('runtime_source_correlation') == 'not_asserted'
      clickhouse = canonical_file!(@runtime.fetch('runtime').fetch('path'))
      helper = canonical_file!(@runtime.fetch('prebuilt_helper').fetch('path'))
      fail!('pinned executable hashes differ') unless sha(clickhouse) == CLICKHOUSE_SHA256 &&
        sha(helper) == @runtime.fetch('prebuilt_helper').fetch('sha256')
      fail!('helper unexpectedly claims in-run compilation') unless @runtime.fetch('prebuilt_helper').fetch('compiled_by_this_runner') == false
      fail!('manifest source root differs') unless @manifest.fetch('source_root') == @source_root
      fail!('manifest ATTACH inventory policy differs from the exact observed policy') unless
        @manifest.fetch('attachment_inventory_policy') == ATTACHMENT_INVENTORY_POLICY
      fail!('pinned ClickHouse source directory is missing') unless File.directory?(SOURCE_ROOT) && File.realpath(SOURCE_ROOT) == SOURCE_ROOT
      @runtime.fetch('source_hashes').each do |relative, record|
        expected = SOURCE_HASHES.fetch(relative) { fail!("unexpected pinned source file #{relative}") }
        actual = sha(File.join(SOURCE_ROOT, relative))
        fail!("pinned source file changed: #{relative}") unless actual == expected &&
          record.fetch('sha256') == expected && record.fetch('expected_sha256') == expected
      end
      fail!('pinned source hash roster differs') unless @runtime.fetch('source_hashes').keys.sort == SOURCE_HASHES.keys.sort
    end

    def audit_matrix!
      source_matrix_path = @summary.fetch('source_matrix_path')
      matrix_file = file(source_matrix_path, @source_root)
      matrix_hash = sha(matrix_file)
      fail!('source matrix digest differs from summary') unless matrix_hash == @summary.fetch('source_matrix_sha256')
      fail!('manifest source matrix pin differs') unless @manifest.fetch('source_matrix') ==
        {'path' => matrix_file, 'sha256' => matrix_hash, 'profiles' => 43}
      @matrix = source_json(matrix_file)
      fail!('source matrix format/pins differ') unless @matrix.fetch('format') == 'aggregate_sum_physical_w223_matrix_v1' &&
        @matrix.fetch('case_count') == 43 && @matrix.fetch('stock_physical_observed') == 43 &&
        @matrix.fetch('physical_mismatches') == 0 && @matrix.fetch('probe_failures') == 0 && @matrix.fetch('construction_mismatches') == 0 &&
        @matrix.fetch('source_pin').fetch('source_reference') == "#{SOURCE_ROOT}@#{SOURCE_REVISION}" &&
        @matrix.fetch('runtime_pin').fetch('runtime_sha256') == CLICKHOUSE_SHA256 &&
        @matrix.fetch('runtime_pin').fetch('runtime_version') == VERSION && @matrix.fetch('runtime_pin').fetch('runtime_build_hash') == BUILD_HASH
      source_files = @matrix.fetch('source_pin').fetch('file_hashes')
      fail!('source matrix source-file hash roster differs') unless source_files.map { |item| item.fetch('path') }.sort == SOURCE_HASHES.keys.sort
      source_files.each do |item|
        expected_hash = SOURCE_HASHES.fetch(item.fetch('path'))
        fail!("#{item.fetch('path')} matrix source hash differs") unless item.fetch('expected_sha256') == expected_hash &&
          item.fetch('actual_sha256') == expected_hash && item.fetch('matches') == true
      end
      @profiles = @matrix.fetch('matrix')
      expected = profile_specs
      fail!('finite physical profile roster or ordering differs') unless @profiles.map { |item| item.fetch('id') } == expected.map { |item| item.fetch('id') }
      @profiles.each_with_index do |profile, index|
        law = expected.fetch(index)
        %w[id kind source_function canonical_function argument_type declared_type].each do |key|
          fail!("#{profile['id']} differs from independently frozen #{key}") unless profile[key] == law[key]
        end
      end
      projected = @profiles.map { |item| item.slice('id', 'kind', 'source_function', 'canonical_function', 'argument_type', 'declared_type') }
      fail!('manifest profile projection differs from pinned roster') unless @manifest.fetch('profiles') == projected
      fail!('manifest row/mark grid differs') unless @manifest.fetch('rows').fetch('keys') == ROW_KEYS &&
        @manifest.fetch('rows').fetch('row_count') == 5 && @manifest.fetch('rows').fetch('real_mark_rows') == MARK_ROWS &&
        @manifest.fetch('rows').fetch('RowBinary_windows') == ['full', 'middle keys 22..44', 'empty where pk=0']
    end

    def audit_processes!
      invocation_dir = File.join(@root, 'invocations')
      fail!('invocation directory missing or noncanonical') unless File.directory?(invocation_dir) &&
        !File.symlink?(invocation_dir) && File.realpath(invocation_dir) == invocation_dir
      argv_paths = Dir.glob(File.join(invocation_dir, '*.argv.json')).sort
      fail!('invocation inventory count differs from summary') unless argv_paths.length == @summary.fetch('counts').fetch('invocations')
      runtime_path = @runtime.fetch('runtime').fetch('path')
      helper_path = @runtime.fetch('prebuilt_helper').fetch('path')
      argv_paths.each do |argv_path|
        file(argv_path)
        record = json_file(argv_path)
        label = record.fetch('label')
        fail!("duplicate process label #{label}") if @invocations.key?(label)
        stem = argv_path.sub(/\.argv\.json\z/, '')
        %w[stdout stderr status.json].each { |suffix| file(stem + '.' + suffix) }
        status = json_file(stem + '.status.json')
        stdout = File.binread(stem + '.stdout')
        stderr = File.binread(stem + '.stderr')
        role = record.fetch('role')
        expected_binary = role == 'clickhouse' ? runtime_path : (role == 'crystal_helper' ? helper_path : nil)
        fail!("unexpected process role #{role.inspect}") unless expected_binary
        fail!("#{label} executable argv differs") unless record.fetch('argv').first == expected_binary
        fail!("#{label} process did not exit successfully") unless status.fetch('success') == true &&
          status.fetch('exitstatus') == 0 && status.fetch('signaled') == false && status.fetch('termsig').nil? &&
          status.fetch('timed_out') == false && !status.key?('spawn_error')
        found_codes = (stdout + stderr).scan(/(?:^|[^A-Za-z0-9_])Code:[\x09-\x0d\x20]*([0-9]+)(?![A-Za-z0-9_])/n).flatten.map(&:to_i).uniq
        fail!("#{label} ClickHouse diagnostic code record differs") unless status.fetch('reported_clickhouse_codes') == found_codes
        fail!("#{label} expected-positive invocation reported a ClickHouse diagnostic code") unless found_codes.empty?
        if role == 'clickhouse'
          sql_path = stem + '.sql'
          file(sql_path)
          query_index = record.fetch('argv').index('--query')
          fail!("#{label} SQL sidecar differs from argv") unless query_index && record.fetch('argv')[query_index + 1] == File.binread(sql_path)
        else
          fail!('helper invocation unexpectedly has a SQL sidecar') if File.exist?(stem + '.sql')
        end
        invocation_record = expected_invocation_record(@root, label, argv_path)
        @invocations[label] = {'argv' => record, 'status' => status, 'stdout' => stdout,
          'stderr' => stderr, 'stem' => stem, 'record' => invocation_record}
      end
      required = ['runtime-version', 'runtime-build', 'generic-stock-read-library-write-read']
      @profiles.each do |profile|
        id = profile.fetch('id')
        required.concat(%W[stock-create-#{id} stock-rowbinary-insert-#{id} stock-schema-#{id} stock-type-name-#{id}
          stock-state-hex-#{id} stock-table-path-#{id} stock-part-census-#{id}
          stock-rowbinary-#{id}-full stock-rowbinary-#{id}-middle stock-rowbinary-#{id}-empty
          native-create-#{id} native-data-path-#{id} native-attach-#{id} native-check-#{id}
          native-active-part-#{id} native-schema-#{id} native-type-name-#{id} native-state-hex-#{id}
          native-rowbinary-#{id}-full native-rowbinary-#{id}-middle native-rowbinary-#{id}-empty])
      end
      construction_specs.each { |item| required << "construction-create-and-schema-#{item.fetch('id')}" }
      fail!('process label inventory differs from the exact qualification protocol') unless
        @invocations.keys.sort == required.sort && required.uniq.length == required.length
      fail!('runtime version/build raw query differs') unless @invocations.fetch('runtime-version').fetch('stdout').strip == VERSION &&
        @invocations.fetch('runtime-build').fetch('stdout').strip == "VERSION_GITHASH=#{BUILD_HASH}"
      helper_record = json_file(File.join(@root, 'generated', 'helper-process.json'))
      fail!('saved helper process record differs from actual sidecars') unless
        helper_record == @invocations.fetch('generic-stock-read-library-write-read').fetch('record')
      actual_success = @invocations.values.count { |item| item.fetch('status').fetch('success') && item.fetch('status').fetch('exitstatus') == 0 }
      fail!('summary process status counts differ') unless @summary.fetch('process_status_counts').fetch('success_exit0') == actual_success &&
        @summary.fetch('process_status_counts').fetch('failed_timed_out_or_spawn_error') == 0 && actual_success == @invocations.length
    end

    def check_reference!(label, saved)
      fail!("#{label} saved process record differs from sidecars") unless saved == @invocations.fetch(label).fetch('record')
    end

    def audit_profiles!
      @profiles.each do |profile|
        id = profile.fetch('id')
        source = profile.fetch('physical')
        declared = profile.fetch('declared_type')
        states = profile.fetch('literal_state_hex')
        fail!("#{id} row-key/mark grid differs") unless profile.fetch('row_keys') == ROW_KEYS && profile.fetch('mark_rows') == MARK_ROWS
        fail!("#{id} literal state hex list differs") unless source.fetch('observed_state_hex') == states
        fail!("#{id} nominal type output differs") unless source.fetch('to_type_name') == declared
        stock_schema = @invocations.fetch("stock-schema-#{id}").fetch('stdout').force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp)
        native_schema = @invocations.fetch("native-schema-#{id}").fetch('stdout').force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp)
        expected_schema = ["pk\tUInt64", "v\t#{declared}"]
        fail!("#{id} stock/native schema mismatch") unless stock_schema == expected_schema && native_schema == expected_schema
        stock_hex = @invocations.fetch("stock-state-hex-#{id}").fetch('stdout').force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp).map(&:downcase)
        native_hex = @invocations.fetch("native-state-hex-#{id}").fetch('stdout').force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp).map(&:downcase)
        fail!("#{id} stock/native raw state bytes differ from literal matrix") unless stock_hex == states && native_hex == states
        fail!("#{id} stock type name output differs") unless @invocations.fetch("stock-type-name-#{id}").fetch('stdout').strip == declared
        fail!("#{id} native type name output differs") unless @invocations.fetch("native-type-name-#{id}").fetch('stdout').strip == declared

        original = source.fetch('original_part_path')
        copied = source.fetch('source_part_path')
        fail!("#{id} stock part roots escaped capture") unless original.start_with?(@source_root + File::SEPARATOR) && copied.start_with?(@source_root + File::SEPARATOR)
        stock_data_path = File.expand_path(@invocations.fetch("stock-table-path-#{id}").fetch('stdout').strip)
        census_lines = @invocations.fetch("stock-part-census-#{id}").fetch('stdout').force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp)
        census_fields = census_lines.length == 1 ? census_lines.first.split("\t", -1) : []
        fail!("#{id} raw stock part census/data path differs") unless stock_data_path == File.dirname(original) &&
          census_fields.length == 5 && census_fields[0] == 'all_1_1_0' && census_fields[1] == '5' &&
          census_fields[2] == '4' && census_fields[3] == 'Wide' && File.expand_path(census_fields[4]) == original
        original_inventory = inventory(original)
        copied_inventory = inventory(copied)
        fail!("#{id} stock copied/original inventories differ") unless original_inventory == copied_inventory &&
          copied_inventory == source.fetch('part_file_inventory') && original_inventory == source.fetch('original_part_file_inventory')
        stock_serialization = json_file(File.join(copied, 'serialization.json'), @source_root)
        stock_metadata_version = File.binread(File.join(copied, 'metadata_version.txt')).strip
        fail!("#{id} stock serialization metadata differs") unless stock_serialization == STOCK_SERIALIZATION_METADATA &&
          source.fetch('serialization_json') == STOCK_SERIALIZATION_METADATA && stock_metadata_version == '0' &&
          source.fetch('metadata_version_txt') == '0'
        stock_case = json_file(File.join(@root, 'cases', 'profiles', "#{id}-stock.json"))
        fail!("#{id} stock case identity/inventory differs") unless stock_case.fetch('id') == id &&
          stock_case.fetch('source_inventory') == copied_inventory && stock_case.fetch('source_part_path') == copied &&
          stock_case.fetch('original_part_path') == original
        stock_processes = stock_case.fetch('processes')
        stock_labels = %W[stock-create-#{id} stock-rowbinary-insert-#{id} stock-schema-#{id} stock-type-name-#{id}
          stock-state-hex-#{id} stock-table-path-#{id} stock-part-census-#{id}
          stock-rowbinary-#{id}-full stock-rowbinary-#{id}-middle stock-rowbinary-#{id}-empty]
        fail!("#{id} stock process references differ") unless stock_processes.map { |item| item.fetch('label') }.sort == stock_labels.sort
        stock_processes.each { |item| check_reference!(item.fetch('label'), item) }
        fail!("#{id} RowBinary input stdin differs") unless @invocations.fetch("stock-rowbinary-insert-#{id}").fetch('argv').fetch('stdin_sha256') ==
          Digest::SHA256.hexdigest(ROW_KEYS.each_with_index.map { |key, index| [key].pack('Q<') + [states.fetch(index)].pack('H*') }.join.b)

        {'full' => [0, 1, 2, 3, 4], 'middle' => [1, 2, 3], 'empty' => []}.each do |window, indices|
          expected_bytes = expected_rowbinary(profile, indices)
          metadata = source.fetch('rowbinary').fetch(window)
          evidence = safe_relative_file!(@source_root, metadata.fetch('path'))
          fail!("#{id}/#{window} source RowBinary evidence differs") unless File.binread(evidence) == expected_bytes &&
            metadata.fetch('absolute_path') == evidence && metadata.fetch('bytes') == expected_bytes.bytesize &&
            metadata.fetch('sha256') == Digest::SHA256.hexdigest(expected_bytes) && metadata.fetch('matches_independent_literal') == true
          fail!("#{id}/#{window} stock RowBinary process differs") unless @invocations.fetch("stock-rowbinary-#{id}-#{window}").fetch('stdout') == expected_bytes
          native_label = "native-rowbinary-#{id}-#{window}"
          fail!("#{id}/#{window} attached RowBinary process differs") unless @invocations.fetch(native_label).fetch('stdout') == expected_bytes
        end

        helper_output ||= json_file(File.join(@root, 'generated', 'helper-output.json'))
        helper_profile = helper_output.fetch('profiles').find { |item| item.fetch('id') == id }
        fail!("#{id} helper profile missing/mismatched") unless helper_profile && helper_profile.fetch('declared_type') == declared &&
          helper_profile.fetch('literal_state_hex') == states && helper_profile.fetch('classification') == 'physical_observed'
        valid_grids = %w[source library].all? { |side|
          helper_profile.fetch(side).fetch('row_count') == 5 && helper_profile.fetch(side).fetch('mark_row_counts') == MARK_ROWS
        }
        fail!("#{id} helper exact row/mark grid differs") unless valid_grids
        if profile.fetch('kind') == 'sum'
          schedule = [[0, 0, 2], [1, 2, 2], [2, 4, 1]]
          valid_schedule = %w[source_public_scan library_public_scan].all? { |side|
            helper_profile.fetch(side).fetch('batch_schedule') == schedule
          }
          fail!("#{id} public scan schedule differs") unless valid_schedule
        end
        library_part = helper_profile.fetch('library_part_path')
        fail!("#{id} generated library path escaped evidence root") unless library_part.start_with?(@root + File::SEPARATOR)
        lib_inventory = inventory(library_part)
        fail!("#{id} generated library inventory differs") unless helper_profile.fetch('library_part_inventory') == lib_inventory
        expected_library_serialization = profile.fetch('kind') == 'count' ?
          COUNT_LIBRARY_SERIALIZATION_METADATA : SUM_LIBRARY_SERIALIZATION_METADATA
        library_serialization = json_file(File.join(library_part, 'serialization.json'))
        library_metadata_version = File.binread(File.join(library_part, 'metadata_version.txt')).strip
        fail!("#{id} generated library serialization metadata differs") unless
          library_serialization == expected_library_serialization && library_metadata_version == '0'

        native = json_file(File.join(@root, 'cases', 'profiles', "#{id}-native.json"))
        fail!("#{id} native case identity/type/state differs") unless native.fetch('id') == id &&
          native.fetch('declared_type') == declared && native.fetch('literal_state_hex') == states && native.fetch('native_state_hex') == states
        check_reference!("native-check-#{id}", native.fetch('check_table_invocation'))
        fail!("#{id} detached/generated file inventory differs") unless native.fetch('generated_inventory_before_attach') == lib_inventory &&
          native.fetch('detached_inventory_before_attach') == lib_inventory
        attached = native.fetch('attached_part_path')
        fail!("#{id} attached part path escaped evidence root") unless attached.start_with?(@root + File::SEPARATOR)
        native_census_lines = @invocations.fetch("native-active-part-#{id}").fetch('stdout').force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp)
        native_census = native_census_lines.length == 1 ? native_census_lines.first.split("\t", -1) : []
        check_text = @invocations.fetch("native-check-#{id}").fetch('stdout')
        fail!("#{id} exact TSVRaw CHECK TABLE output differs") unless check_text == "all_1_1_0\t1\t\n"
        fail!("#{id} raw ATTACH/CHECK part identity differs") unless
          native_census.length == 5 && native_census[0] == 'all_1_1_0' && native_census[1] == '5' &&
          native_census[2] == '4' && native_census[3] == 'Wide' && File.expand_path(native_census[4]) == attached
        attached_inventory = inventory(attached)
        fail!("#{id} attached part inventory differs") unless attached_inventory == native.fetch('attached_inventory_after_attach')
        attached_serialization = json_file(File.join(attached, 'serialization.json'))
        attached_metadata_version = File.binread(File.join(attached, 'metadata_version.txt')).strip
        fail!("#{id} stock/library serialization metadata evidence differs") unless
          native.fetch('source_stock_serialization_json') == STOCK_SERIALIZATION_METADATA &&
          native.fetch('attached_library_serialization_json') == expected_library_serialization &&
          attached_serialization == expected_library_serialization && attached_metadata_version == '0' &&
          native.fetch('metadata_version_txt') == '0'
        before = lib_inventory.each_with_object({}) { |item, map| map[item.fetch('path')] = item }
        after = attached_inventory.each_with_object({}) { |item, map| map[item.fetch('path')] = item }
        fail!("#{id} ATTACH changed or removed original files") unless (before.keys - after.keys).empty? &&
          before.keys.all? { |path| before.fetch(path) == after.fetch(path) }
        added = after.keys - before.keys
        fail!("#{id} ATTACH added unexpected auxiliary files") unless added == ['invalidated_system_columns.txt']
        auxiliary = File.binread(File.join(attached, added.first))
        names = auxiliary.split("\n", -1)
        fail!("#{id} ATTACH auxiliary content/hash differs") unless names.pop == '' && names.sort == AUXILIARY_NAMES.sort &&
          after.fetch(added.first).fetch('size') == auxiliary.bytesize && after.fetch(added.first).fetch('sha256') == Digest::SHA256.hexdigest(auxiliary)
      end
      helper_raw = JSON.parse(@invocations.fetch('generic-stock-read-library-write-read').fetch('stdout'))
      saved_helper = json_file(File.join(@root, 'generated', 'helper-output.json'))
      normalized = JSON.parse(JSON.generate(saved_helper))
      normalized.fetch('profiles').each { |item| item.delete('library_part_inventory') }
      fail!('saved helper output differs from its raw stdout except post-run inventory augmentation') unless helper_raw == normalized
      fail!('helper format/roster/count differs') unless saved_helper.fetch('format') == 'aggregate_sum_w223_helper_v1' &&
        saved_helper.fetch('mismatch_count') == 0 && saved_helper.fetch('physical_observed') == 43 && saved_helper.fetch('profile_count') == 43 &&
        saved_helper.fetch('profiles').map { |item| item.fetch('id') } == @profiles.map { |item| item.fetch('id') }
    end

    def audit_construction!
      census = @matrix.fetch('construction_census')
      expected = construction_specs
      actual = census.fetch('cases')
      fail!('construction census does not represent the independent 78-case roster') unless census.fetch('expected_count') == 78 &&
        census.fetch('observed_count') == 78 && actual.length == 78 && expected.length == 78 &&
        actual.map { |item| item.fetch('id') } == expected.map { |item| item.fetch('id') }
      @manifest_scope = @manifest.fetch('construction_law_scope')
      fail!('manifest construction scope/count differs') unless @manifest_scope.fetch('sum_argument_count') == 33 &&
        @manifest_scope.fetch('sum_with_overflow_argument_count') == 33 &&
        @manifest_scope.fetch('targeted_sum_kahan_argument_count') == 12 && @manifest_scope.fetch('observed_construction_count') == 78 &&
        @manifest_scope.fetch('ordinary_sum_and_overflow_arguments') == base_types
      fail!('source construction argument arrays differ') unless census.fetch('base_type_count') == 33 &&
        census.fetch('sum_arguments') == base_types && census.fetch('sum_with_overflow_arguments') == base_types &&
        census.fetch('targeted_sum_kahan_arguments') == expected.select { |item| item.fetch('source_function') == 'sumKahan' }.map { |item| item.fetch('argument_type') }
      expected.each_with_index do |law, index|
        record = actual.fetch(index)
        %w[id source_function canonical_function argument_type input_type expected_storage_type].each do |key|
          fail!("#{law['id']} construction #{key} differs") unless record.fetch(key) == law[key]
        end
        fail!("#{law['id']} construction classification/schema differs") unless record.fetch('classification') == 'strict_stock_construction_observed' &&
          record.fetch('observed_schema') == ["v\t#{law.fetch('expected_storage_type')}"]
        label = "construction-create-and-schema-#{law.fetch('id')}"
        construction_processes = record.fetch('processes')
        fail!("#{law['id']} construction process roster differs") unless construction_processes.length == 1 &&
          construction_processes.map { |item| item.fetch('label') } == [label]
        check_reference!(label, construction_processes.fetch(0))
        fail!("#{law['id']} construction raw SQL schema differs") unless
          @invocations.fetch(label).fetch('stdout').force_encoding(Encoding::UTF_8).scrub.lines.map(&:chomp) == record.fetch('observed_schema')
        saved = json_file(File.join(@root, 'cases', 'construction', "#{law.fetch('id')}.json"))
        fail!("#{law['id']} saved construction record differs") unless saved == record
      end
    end
  end

  def main(argv)
    fail!('usage: check_aggregate_sum_evidence_w223.rb EVIDENCE_ROOT') unless argv.length == 1
    exit(Auditor.new(argv.fetch(0)).run ? 0 : 1)
  rescue StandardError => error
    warn "W223 evidence audit setup failed: #{error.class}: #{error.message}"
    exit 2
  end
end

CheckAggregateSumEvidenceW223.main(ARGV)
