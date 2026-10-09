#!/usr/bin/env ruby
# Stock-only feasibility probe for nominal Custom Geo descriptors, scalar
# RowBinary values, and native Wide-part metadata. Expected bytes come from
# custom_geo_w238_fixtures.rb, not from ClickHouse output or Crystal codecs.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'optparse'
require_relative 'recheck_aggregate_recursive_w224'
require_relative 'custom_geo_w238_fixtures'

module ProbeCustomGeoW238
  extend self

  R = RecheckAggregateRecursiveW224
  F = CustomGeoW238Fixtures
  SOURCE_REVISION = 'f25eb93a0b890a3b87df05eb34e2af1f933b4089'.freeze
  SOURCE_PREFIX = '/private/tmp/crystal-click-w238.'.freeze
  OUTPUT_PREFIX = '/private/tmp/crystal-click-w238-stock.'.freeze
  MATRIX_FORMAT = 'custom_geo_recursive_w238_stock_v1'.freeze
  SUMMARY_FORMAT = 'custom_geo_recursive_w238_probe_summary_v1'.freeze
  CHECK_OUTPUT = "all_1_1_0\t1\t\n".freeze
  PROFILE_COUNT = 13

  SOURCE_SHA256 = {
    'src/DataTypes/DataTypeCustomGeo.cpp' => 'c143892a4fc3ea684d10da6a703919ced96d5e149eb188fcc270eb15acf02182',
    'src/DataTypes/DataTypesBinaryEncoding.cpp' => '78ba394f20ccd2a00f5be6b8c4d470fafb1c91a6f87bb27c301c2d3203f28f87',
    'src/DataTypes/IDataType.cpp' => 'b4535a47d35b79fb142db828ae202d610b97055a06f5a782f4adcf7d66c593b0',
  }.freeze

  STOCK_SETTINGS = [
    'index_granularity=2', 'index_granularity_bytes=10485760',
    'enable_mixed_granularity_parts=1', 'min_rows_for_wide_part=0',
    'min_bytes_for_wide_part=0', 'min_level_for_wide_part=0',
    'compress_marks=0', 'compress_primary_key=0', 'min_compress_block_size=0',
    'max_compress_block_size=4096', 'ratio_of_defaults_for_sparse_serialization=1.0',
    "default_compression_codec='LZ4'", "nullable_serialization_version='basic'",
    "serialization_info_version='with_types'", 'propagate_types_serialization_versions_to_nested_types=1',
    'flatten_nested=0', 'use_compact_variant_discriminators_serialization=0',
  ].freeze

  def fail!(message)
    raise ArgumentError, message
  end

  def require_true(condition, message)
    fail!(message) unless condition
  end

  def write_new(path, bytes)
    R.write_new(path, bytes)
  end

  def write_json(path, object)
    R.write_json(path, object)
  end

  def clean_process(record)
    record.reject { |key, _| %w[stdout stderr path].include?(key) }
  end

  def successful?(record)
    record.fetch('classification') == 'process_success' && record.fetch('exitstatus') == 0 &&
      !record.fetch('signaled') && !record.fetch('timed_out') && !record.fetch('spawn_error')
  end

  def sql_quote(value)
    "'#{value.gsub("'", "''")}'"
  end

  def marker_section(stdout, start_marker, end_marker, label)
    lines = stdout.force_encoding(Encoding::UTF_8).scrub.lines
    start = lines.index { |line| line.chomp == start_marker }
    finish = lines.index { |line| line.chomp == end_marker }
    require_true(start && finish && finish > start, "raw stdout markers missing for #{label}")
    lines[(start + 1)...finish].join
  end

  def stock_table(profile)
    "w238_stock_#{profile.fetch('id')}"
  end

  def create_sql(profile)
    type = profile.fetch('declared_type')
    table = stock_table(profile)
    settings = STOCK_SETTINGS.join(', ')
    rows = F::ROW_KEYS.zip(profile.fetch('values')).map do |key, value|
      "(#{key}, #{F.sql_expression(profile, value)})"
    end
    "CREATE TABLE default.#{table} (pk UInt64, payload #{type}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings};\n" \
      "INSERT INTO default.#{table} (pk, payload) VALUES #{rows.join(', ')}"
  end

  def inventory(part)
    full = File.expand_path(part)
    require_true(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full,
      "part is absent, symlinked, or noncanonical: #{full}")
    rows = []
    Find.find(full) do |path|
      next if path == full
      require_true(!File.symlink?(path), "part contains a symlink: #{path}")
      next if File.directory?(path)
      require_true(File.file?(path), "part contains a non-regular file: #{path}")
      rows << { 'path' => path[(full.length + 1)..-1], 'bytes' => File.size(path),
        'sha256' => Digest::SHA256.file(path).hexdigest }
    end
    rows.sort_by { |row| row.fetch('path') }
  end

  def part_metadata(part)
    files = inventory(part)
    result = { 'inventory' => files }
    {
      'columns_txt' => 'columns.txt', 'serialization_json' => 'serialization.json',
      'metadata_version_txt' => 'metadata_version.txt', 'default_compression_codec_txt' => 'default_compression_codec.txt',
      'checksums_txt' => 'checksums.txt',
    }.each do |key, filename|
      path = File.join(part, filename)
      next unless File.file?(path) && !File.symlink?(path)
      bytes = File.binread(path)
      item = { 'path' => filename, 'bytes' => bytes.bytesize,
        'sha256' => Digest::SHA256.hexdigest(bytes) }
      if key == 'serialization_json'
        item['parsed'] = JSON.parse(bytes.force_encoding(Encoding::UTF_8))
      else
        item['text'] = bytes.force_encoding(Encoding::UTF_8).scrub
      end
      result[key] = item
    end
    result
  rescue JSON::ParserError => error
    fail!("native serialization.json is invalid: #{error.message}")
  end

  class Probe
    include ProbeCustomGeoW238

    def initialize(options)
      @binary = R.validate_binary!(options.fetch(:clickhouse))
      @source_root = validate_source_root(options.fetch(:source_root))
      @output_root = R.validate_root(options.fetch(:output_root), OUTPUT_PREFIX, 'W238 output root')
      @store = File.join(@output_root, 'stores', 'main')
      @records = []
      @profile_records = []
      @refusal_records = []
      @fatal = nil
      @source_pin = nil
      @runtime_pin = nil
      @recorder = nil
    end

    def run
      prepare_layout
      pin_source
      pin_runtime
      capture_positive_roster
      capture_refusals
      write_matrix
      classification = final_classification
      write_summary(classification)
      puts "W238 stock-only Custom Geo profiles=#{@profile_records.length}; evidence=#{@output_root}"
      classification == 'stock_custom_geo_profiles_observed' ? true : false
    rescue StandardError => error
      @fatal ||= "#{error.class}: #{error.message}"
      write_matrix rescue nil
      write_summary('stock_probe_failed_or_diverged') rescue nil
      warn "W238 stock-only probe failure; raw native status is preserved: #{@fatal}"
      false
    end

    private

    def validate_source_root(path)
      full = File.expand_path(path)
      require_true(File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full,
        "pinned source checkout is missing, symlinked, or noncanonical: #{full}")
      require_true(full.start_with?(SOURCE_PREFIX) && File.basename(full) == 'clickhouse' &&
        File.dirname(File.dirname(full)) == File.realpath('/private/tmp'),
        'pinned source checkout must be the W238 direct /private/tmp checkout')
      full
    end

    def prepare_layout
      %w[invocations stores captures stock-parts fixtures pins].each do |name|
        Dir.mkdir(File.join(@output_root, name), 0o700)
      end
      Dir.mkdir(@store, 0o700)
      @recorder = R::Recorder.new(@output_root, @binary)
    end

    def process(label, sql, input: nil, argv: nil)
      record = @recorder.run(label, @store, sql, input: input, argv: argv)
      @records << record
      record
    end

    def pin_source
      stdout, stderr, status = Open3.capture3('git', '-C', @source_root, 'rev-parse', 'HEAD')
      write_new(File.join(@output_root, 'pins', 'source-revision.stdout'), stdout.b)
      write_new(File.join(@output_root, 'pins', 'source-revision.stderr'), stderr.b)
      require_true(status.success? && stdout.strip == SOURCE_REVISION,
        "source reference revision mismatch: #{stdout.inspect} #{stderr.inspect}")
      hashes = SOURCE_SHA256.map do |relative, expected|
        path = File.join(@source_root, relative)
        require_true(File.file?(path) && !File.symlink?(path), "source anchor is absent or symlinked: #{relative}")
        actual = Digest::SHA256.file(path).hexdigest
        { 'path' => relative, 'expected_sha256' => expected, 'actual_sha256' => actual,
          'matches' => actual == expected }
      end
      require_true(hashes.all? { |row| row.fetch('matches') }, 'a pinned W238 source anchor hash differs')
      @source_pin = {
        'checkout' => @source_root, 'revision' => SOURCE_REVISION,
        'runtime_built_from_this_source_not_asserted' => true,
        'source_scope' => 'shallow DataTypes/Core source reference; not runtime provenance',
        'file_hashes' => hashes,
      }
      write_json(File.join(@output_root, 'pins', 'source-pin.json'), @source_pin)
    end

    def pin_runtime
      version = process('runtime-version-pin', 'SELECT version() FORMAT TSVRaw')
      require_true(successful?(version) && version.fetch('stdout').strip == R::VERSION,
        'native runtime version differs from exact 26.10.1.1201 pin')
      build = process('runtime-build-pin',
        "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw")
      require_true(successful?(build) && build.fetch('stdout').strip == "VERSION_GITHASH=#{R::BUILD_HASH}",
        'native runtime build hash differs from exact pinned build')
      @runtime_pin = {
        'version' => R::VERSION, 'build_hash' => R::BUILD_HASH,
        'sha256' => Digest::SHA256.file(@binary).hexdigest,
        'binary' => @binary, 'source_correlation' => 'not_asserted',
      }
      write_json(File.join(@output_root, 'pins', 'runtime-pin.json'), @runtime_pin)
    end

    def capture_positive_roster
      F.profiles.each do |profile|
        row = {
          'id' => profile.fetch('id'), 'requested_type' => profile.fetch('declared_type'),
          'declared_type' => profile.fetch('declared_type'),
          'descriptor_hex' => F.descriptor_hex(profile.fetch('declared_type')),
          'values_hex' => F.values_hex(profile), 'rowbinary_windows_literal_hex' =>
            F.rowbinary_windows(profile).transform_values { |bytes| bytes.unpack1('H*') },
        }
        table = stock_table(profile)
        create = process("stock-create-insert-#{profile.fetch('id')}", create_sql(profile))
        row['create_insert_process'] = clean_process(create)
        unless successful?(create)
          row['classification'] = 'positive_constructor_or_insert_failure'
          row['diagnostic'] = (create.fetch('stdout') + create.fetch('stderr')).force_encoding(Encoding::UTF_8).scrub
          @profile_records << row
          next
        end

        capture_schema_and_part(profile, row, table)
        capture_binary_output(profile, row, table)
        capture_rowbinary_windows(profile, row, table)
        row['classification'] = classify_profile(row)
        @profile_records << row
      rescue StandardError => error
        row ||= { 'id' => profile.fetch('id'), 'requested_type' => profile.fetch('declared_type') }
        row['classification'] = 'capture_or_oracle_error'
        row['error'] = "#{error.class}: #{error.message}"
        @profile_records << row
      end
    end

    def capture_schema_and_part(profile, row, table)
      id = profile.fetch('id')
      sql = [
        "SELECT 'W238_SCHEMA_BEGIN_#{id}' FORMAT TSVRaw",
        "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw",
        "SELECT 'W238_SCHEMA_END_#{id}' FORMAT TSVRaw",
        "SELECT 'W238_PART_BEGIN_#{id}' FORMAT TSVRaw",
        "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw",
        "SELECT 'W238_PART_END_#{id}' FORMAT TSVRaw",
        "SELECT 'W238_CHECK_BEGIN_#{id}' FORMAT TSVRaw",
        "CHECK TABLE default.#{table} FORMAT TSVRaw",
        "SELECT 'W238_CHECK_END_#{id}' FORMAT TSVRaw",
      ].join(";\n")
      record = process("stock-schema-part-check-#{id}", sql)
      row['schema_part_check_process'] = clean_process(record)
      unless successful?(record)
        row['schema_part_check_diagnostic'] = (record.fetch('stdout') + record.fetch('stderr')).force_encoding(Encoding::UTF_8).scrub
        return
      end

      schema = marker_section(record.fetch('stdout'), "W238_SCHEMA_BEGIN_#{id}", "W238_SCHEMA_END_#{id}", "schema #{id}")
      schema_rows = schema.lines.map(&:chomp)
      row['schema_rows'] = schema_rows
      row['observed_declared_type'] = schema_rows.find { |line| line.start_with?("payload\t") }&.split("\t", 2)&.last
      part_output = marker_section(record.fetch('stdout'), "W238_PART_BEGIN_#{id}", "W238_PART_END_#{id}", "part #{id}")
      part_rows = part_output.lines.map(&:chomp)
      row['part_census_rows'] = part_rows
      check = marker_section(record.fetch('stdout'), "W238_CHECK_BEGIN_#{id}", "W238_CHECK_END_#{id}", "CHECK #{id}")
      row['check_output'] = check
      return unless part_rows.length == 1

      fields = part_rows.first.split("\t", -1)
      row['part_census'] = fields
      return unless fields.length == 5 && fields[0] == 'all_1_1_0'

      source_part = File.expand_path(fields[4])
      require_true(source_part.start_with?(@store + File::SEPARATOR) && File.directory?(source_part) &&
        !File.symlink?(source_part) && File.realpath(source_part) == source_part,
        "native part path escaped isolated stock store: #{source_part}")
      destination = File.join(@output_root, 'stock-parts', id, 'all_1_1_0')
      FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
      require_true(!File.exist?(destination) && !File.symlink?(destination), "stock capture destination exists: #{destination}")
      FileUtils.cp_r(source_part, destination)
      row['stock_part_path'] = destination
      row['source_system_parts_path'] = source_part
      row['physical'] = part_metadata(destination)
    end

    def capture_binary_output(profile, row, table)
      id = profile.fetch('id')
      sql = "SELECT payload FROM default.#{table} ORDER BY pk " \
        "SETTINGS output_format_binary_encode_types_in_binary_format=1, print_pretty_type_names=0, " \
        "flatten_nested=0 FORMAT RowBinaryWithNamesAndTypes"
      record = process("stock-rbnwt-#{id}", sql)
      row['rbnwt_process'] = clean_process(record)
      unless successful?(record)
        row['rbnwt_diagnostic'] = (record.fetch('stdout') + record.fetch('stderr')).force_encoding(Encoding::UTF_8).scrub
        return
      end
      actual = record.fetch('stdout').b
      expected = F.rowbinary_with_names_and_types(profile)
      path = File.join(@output_root, 'captures', "#{id}.rowbinary-with-names-and-types")
      write_new(path, actual)
      row['rbnwt'] = {
        'path' => path, 'bytes' => actual.bytesize, 'sha256' => Digest::SHA256.hexdigest(actual),
        'expected_hex' => expected.unpack1('H*'), 'observed_hex' => actual.unpack1('H*'),
        'matches_independent_descriptor_and_values' => actual == expected,
      }
    end

    def capture_rowbinary_windows(profile, row, table)
      id = profile.fetch('id')
      paths = %w[full middle zero].to_h do |window|
        [window, File.join(@output_root, 'captures', "#{id}-#{window}.rowbinary")]
      end
      paths.each_value do |path|
        require_true(!File.exist?(path) && !File.symlink?(path), "refusing to overwrite RowBinary capture #{path}")
      end
      predicates = { 'full' => '', 'middle' => ' WHERE pk BETWEEN 22 AND 44', 'zero' => ' WHERE pk > 55' }
      sql = predicates.map do |window, predicate|
        "SELECT pk, payload FROM default.#{table}#{predicate} ORDER BY pk " \
          "INTO OUTFILE #{sql_quote(paths.fetch(window))} FORMAT RowBinary"
      end.join(";\n")
      record = process("stock-rowbinary-windows-#{id}", sql)
      row['rowbinary_windows_process'] = clean_process(record)
      unless successful?(record)
        row['rowbinary_windows_diagnostic'] = (record.fetch('stdout') + record.fetch('stderr')).force_encoding(Encoding::UTF_8).scrub
        return
      end
      row['rowbinary_windows'] = paths.to_h do |window, path|
        require_true(File.file?(path) && !File.symlink?(path), "successful native export did not create #{path}")
        actual = File.binread(path)
        expected = F.rowbinary_windows(profile).fetch(window)
        [window, { 'path' => path, 'bytes' => actual.bytesize,
          'sha256' => Digest::SHA256.hexdigest(actual), 'expected_hex' => expected.unpack1('H*'),
          'observed_hex' => actual.unpack1('H*'), 'matches_independent_literal' => actual == expected }]
      end
    end

    def classify_profile(row)
      checks = [
        row.fetch('schema_rows', []).length == 2 && row.fetch('schema_rows').first == "pk\tUInt64",
        row.fetch('observed_declared_type') == row.fetch('requested_type'),
        row.fetch('check_output') == CHECK_OUTPUT,
        row.fetch('part_census', [])[0] == 'all_1_1_0' && row.fetch('part_census', [])[1] == '5' &&
          row.fetch('part_census', [])[2] == '4' && row.fetch('part_census', [])[3] == 'Wide',
        row.fetch('rbnwt', {}).fetch('matches_independent_descriptor_and_values', false),
        row.fetch('rowbinary_windows', {}).length == 3 && row.fetch('rowbinary_windows').values.all? { |item| item.fetch('matches_independent_literal') },
      ]
      checks.all? ? 'stock_profile_observed' : 'stock_profile_observed_with_divergence'
    end

    def refusal_status(record)
      record.fetch('classification') == 'process_nonzero_or_signaled_exit' &&
        record.fetch('exitstatus') && record.fetch('exitstatus').positive? &&
        !record.fetch('signaled') && !record.fetch('timed_out') && !record.fetch('spawn_error')
    end

    def capture_refusals
      F.source_refusal_cases.each do |item|
        table = "w238_refused_#{item.fetch('id')}"
        sql = "CREATE TABLE default.#{table} (payload #{item.fetch('type')}) ENGINE=Memory"
        record = process("constructor-refusal-#{item.fetch('id')}", sql)
        diagnostic = (record.fetch('stdout') + record.fetch('stderr')).force_encoding(Encoding::UTF_8).scrub
        expected = refusal_status(record) && diagnostic.match?(item.fetch('diagnostic'))
        @refusal_records << {
          'id' => item.fetch('id'), 'requested_type' => item.fetch('type'),
          'classification' => expected ? 'expected_normal_constructor_refusal' : 'unexpected_constructor_outcome',
          'process' => clean_process(record), 'diagnostic' => diagnostic,
        }
      end

      unknown_name = 'CustomGeoW238Unknown'
      descriptor = "\x2c".b + F.rb_string(unknown_name)
      input = F.varuint(1) + F.rb_string('payload') + descriptor
      input_path = File.join(@output_root, 'fixtures', 'unknown-custom-descriptor.rowbinary-with-names-and-types')
      write_new(input_path, input)
      sql = 'INSERT INTO default.w238_stock_point (payload) FORMAT RowBinaryWithNamesAndTypes'
      argv = [@binary, 'local', '--path', @store, '--session_timezone=UTC', '--max_threads=1',
        '--max_insert_threads=1', '--max_execution_time=30', "--max_memory_usage=#{R::MEMORY_LIMIT_BYTES}",
        '--print_pretty_type_names=0', '--input_format_binary_decode_types_in_binary_format=1',
        '--query', sql]
      record = process('unknown-custom-descriptor-decode', sql, input: input, argv: argv)
      diagnostic = (record.fetch('stdout') + record.fetch('stderr')).force_encoding(Encoding::UTF_8).scrub
      expected = refusal_status(record) && diagnostic.match?(/Unknown|CustomGeoW238Unknown/i)
      @refusal_records << {
        'id' => 'unknown_custom_descriptor', 'requested_type' => unknown_name,
        'descriptor_hex' => descriptor.unpack1('H*'), 'input_path' => input_path,
        'classification' => expected ? 'expected_normal_descriptor_refusal' : 'unexpected_descriptor_outcome',
        'process' => clean_process(record), 'diagnostic' => diagnostic,
      }
    end

    def write_matrix
      return unless @output_root && File.directory?(@output_root) && !File.exist?(File.join(@output_root, 'stock-matrix.json'))
      profiles = @profile_records.map do |row|
        {
          'id' => row.fetch('id'), 'declared_type' => row.fetch('requested_type'),
          'observed_declared_type' => row['observed_declared_type'],
          'descriptor_hex' => row.fetch('descriptor_hex'), 'values_hex' => row.fetch('values_hex'),
          'stock_part_path' => row['stock_part_path'],
          'rowbinary_windows' => row['rowbinary_windows'],
          'rbnwt' => row['rbnwt'],
        }
      end
      matrix = {
        'format' => MATRIX_FORMAT, 'row_keys' => F::ROW_KEYS, 'mark_rows' => F::MARK_ROWS,
        'profile_count' => profiles.length, 'coverage' => coverage_manifest,
        'profiles' => profiles, 'profile_evidence' => @profile_records,
        'source_root' => @source_root, 'source_pin' => @source_pin, 'runtime_pin' => @runtime_pin,
        'refusal_observations' => @refusal_records, 'stock_settings' => STOCK_SETTINGS,
        'output_settings' => [
          'output_format_binary_encode_types_in_binary_format=1',
          'print_pretty_type_names=0', 'flatten_nested=0',
        ],
        'matrix_lineage' => 'All descriptor/value/window literals are independently authored in scripts/custom_geo_w238_fixtures.rb before native execution.',
      }
      write_json(File.join(@output_root, 'stock-matrix.json'), matrix)
      @matrix_sha256 = Digest::SHA256.file(File.join(@output_root, 'stock-matrix.json')).hexdigest
    end

    def coverage_manifest
      {
        'roster_method' => 'finite source-valid representative whitelist; no Cartesian expansion',
        'custom_geo_name_count' => F::GEO_NAMES.length,
        'profile_count' => F.profiles.length,
        'profiles' => F.profiles.map { |profile| { 'id' => profile.fetch('id'), 'declared_type' => profile.fetch('declared_type') } },
        'wrapper_families' => %w[Nullable Array Tuple Map Nested Variant],
        'refusal_only' => F.source_refusal_cases.map { |item| item.fetch('type') } + ['unknown Custom descriptor name'],
        'geometry_local_guard' => 'not tested in native probe; Geometry is a distinct fixed-order Variant-backed Custom owner',
        'known_scope_limit' => 'Source-valid representative literals and one stock runtime; not all values, nesting depths, aliases, part settings, or runtime versions.',
      }
    end

    def final_classification
      positives = @profile_records.length == PROFILE_COUNT && @profile_records.all? { |row| row.fetch('classification') == 'stock_profile_observed' }
      refusals = @refusal_records.length == F.source_refusal_cases.length + 1 &&
        @refusal_records.all? { |row| row.fetch('classification').start_with?('expected_normal_') }
      positives && refusals ? 'stock_custom_geo_profiles_observed' : 'stock_probe_incomplete_or_diverged'
    end

    def write_summary(classification)
      return unless @output_root && File.directory?(@output_root) && !File.exist?(File.join(@output_root, 'summary.json'))
      process_rows = @records.map { |record| clean_process(record) }
      counts = {
        'profiles_expected' => PROFILE_COUNT,
        'profiles_observed' => @profile_records.count { |row| row.fetch('classification') == 'stock_profile_observed' },
        'profiles_diverged_or_incomplete' => @profile_records.count { |row| row.fetch('classification') != 'stock_profile_observed' },
        'expected_refusals' => @refusal_records.count { |row| row.fetch('classification').start_with?('expected_normal_') },
        'refusal_cases' => @refusal_records.length, 'native_processes' => process_rows.length,
      }
      write_json(File.join(@output_root, 'summary.json'), {
        'format' => SUMMARY_FORMAT, 'classification' => classification,
        'success' => classification == 'stock_custom_geo_profiles_observed', 'error' => @fatal,
        'output_root' => @output_root, 'matrix_path' => File.join(@output_root, 'stock-matrix.json'),
        'matrix_sha256' => @matrix_sha256, 'source_pin' => @source_pin, 'runtime_pin' => @runtime_pin,
        'coverage' => coverage_manifest, 'counts' => counts,
        'profile_observations' => @profile_records, 'refusal_observations' => @refusal_records,
        'processes' => process_rows,
        'process_status_counts' => {
          'success_exit0' => process_rows.count { |row| row.fetch('classification') == 'process_success' },
          'normal_nonzero_or_signaled' => process_rows.count { |row| row.fetch('classification') == 'process_nonzero_or_signaled_exit' },
          'timeout' => process_rows.count { |row| row.fetch('classification') == 'process_timeout' },
          'spawn_failure' => process_rows.count { |row| row.fetch('classification') == 'spawn_failure' },
        },
      })
    end
  end

  def main(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: ruby scripts/probe_custom_geo_w238.rb --clickhouse BIN --source-root /private/tmp/crystal-click-w238.*/clickhouse --output-root EMPTY_STOCK_ROOT'
      opts.on('--clickhouse PATH') { |value| options[:clickhouse] = value }
      opts.on('--source-root PATH') { |value| options[:source_root] = value }
      opts.on('--output-root PATH') { |value| options[:output_root] = value }
    end
    parser.parse!(argv)
    require_true(argv.empty? && %i[clickhouse source_root output_root].all? { |key| options.key?(key) }, parser.to_s)
    Probe.new(options).run
  rescue StandardError => error
    warn "W238 stock probe setup failure: #{error.class}: #{error.message}"
    false
  end
end

exit(ProbeCustomGeoW238.main(ARGV) ? 0 : 1) if $PROGRAM_NAME == __FILE__
