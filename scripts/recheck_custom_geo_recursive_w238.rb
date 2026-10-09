#!/usr/bin/env ruby
# Paired native ClickHouse and Crystal qualification for nominal Custom Geo
# values. All expected descriptors, scalar bytes, and RowBinary windows are
# authored independently in custom_geo_w238_fixtures.rb.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'optparse'
require_relative 'recheck_aggregate_recursive_w224'
require_relative 'custom_geo_w238_fixtures'
require_relative 'probe_custom_geo_w238'

module RecheckCustomGeoRecursiveW238
  extend self

  R = RecheckAggregateRecursiveW224
  F = CustomGeoW238Fixtures
  P = ProbeCustomGeoW238
  EVIDENCE_PREFIX = '/private/tmp/crystal-click-w238-evidence.'.freeze
  GENERATED_PREFIX = '/private/tmp/crystal-click-w238-generated.'.freeze
  SUMMARY_FORMAT = 'custom_geo_recursive_w238_summary_v1'.freeze
  HELPER_FORMAT = 'custom_geo_recursive_w238_helper_v1'.freeze
  HELPER_LABEL = 'w238-custom-geo-library-writer-reader'.freeze
  INVALIDATED_FILE = 'invalidated_system_columns.txt'.freeze
  INVALIDATED_NAMES = %w[_block_number _block_offset].freeze
  HELPER_TIMEOUT_SECONDS = 600
  PROCESS_TIMEOUT_SECONDS = 90
  TERM_GRACE_SECONDS = 2
  MEMORY_LIMIT_BYTES = 1_073_741_824
  CHECK_OUTPUT = "all_1_1_0\t1\t\n".freeze

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

  def checked_success!(record, label)
    require_true(record.fetch('classification') == 'process_success' && record.fetch('exitstatus') == 0 &&
      !record.fetch('signaled') && !record.fetch('timed_out') && !record.fetch('spawn_error'),
      "#{label} did not complete successfully; inspect its raw status sidecar")
    record
  end

  def sql_quote(value)
    "'#{value.gsub("'", "''")}'"
  end

  def marker_section(stdout, start_marker, end_marker, label)
    lines = stdout.force_encoding(Encoding::UTF_8).scrub.lines
    starts = lines.each_index.select { |index| lines[index].chomp == start_marker }
    finishes = lines.each_index.select { |index| lines[index].chomp == end_marker }
    require_true(starts.length == 1 && finishes.length == 1 && finishes.first > starts.first,
      "raw stdout markers missing or duplicated for #{label}")
    lines[(starts.first + 1)...finishes.first].join
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
      bytes = File.binread(path)
      rows << { 'path' => path[(full.length + 1)..-1], 'bytes' => bytes.bytesize,
        'sha256' => Digest::SHA256.hexdigest(bytes) }
    end
    rows.sort_by { |row| row.fetch('path') }
  end

  def make_dir(path)
    Dir.mkdir(path, 0o700)
  rescue Errno::EEXIST
    fail!("refusing to reuse W238 evidence directory: #{path}")
  end

  def canonical_stock_root(matrix_path)
    full_matrix = File.expand_path(matrix_path)
    require_true(File.file?(full_matrix) && !File.symlink?(full_matrix) && File.realpath(full_matrix) == full_matrix,
      'stock matrix must be a canonical regular file')
    root = File.dirname(full_matrix)
    require_true(File.directory?(root) && !File.symlink?(root) && File.realpath(root) == root &&
      File.dirname(root) == File.realpath('/private/tmp') && root.start_with?(P::OUTPUT_PREFIX),
      'stock matrix must be inside a canonical W238 direct /private/tmp stock root')
    require_true(File.basename(full_matrix) == 'stock-matrix.json', 'stock matrix filename differs')
    [root, full_matrix]
  end

  def table_name(profile, suffix = 'native')
    "w238_#{suffix}_#{profile.fetch('id')}"
  end

  def create_sql(profile)
    table = table_name(profile)
    type = profile.fetch('declared_type')
    "CREATE TABLE default.#{table} (pk UInt64, payload #{type}) ENGINE=MergeTree ORDER BY pk SETTINGS #{STOCK_SETTINGS.join(', ')}"
  end

  def expected_native_labels
    %w[runtime-version-pin runtime-build-pin native-create-all native-attach-all native-capture-all]
  end

  class Probe
    include RecheckCustomGeoRecursiveW238

    def initialize(options)
      @binary = R.validate_binary!(options.fetch(:clickhouse))
      @helper = R.validate_program!(options.fetch(:helper), 'prebuilt W238 Crystal helper')
      @helper_sha256 = R.validate_sha256_pin!(options.fetch(:helper_sha256), 'expected W238 helper SHA-256')
      @helper_sha256_start = Digest::SHA256.file(@helper).hexdigest
      require_true(@helper_sha256_start == @helper_sha256, 'prebuilt helper does not match supplied SHA-256')
      @stock_root, @matrix_path = canonical_stock_root(options.fetch(:stock_matrix))
      @evidence_root = R.validate_root(options.fetch(:output_root), EVIDENCE_PREFIX, 'W238 evidence root')
      @generated_root = R.validate_root(options.fetch(:generated_root), GENERATED_PREFIX, 'W238 generated root')
      @matrix_bytes = File.binread(@matrix_path)
      @matrix_sha256 = Digest::SHA256.hexdigest(@matrix_bytes)
      @matrix = JSON.parse(@matrix_bytes.force_encoding(Encoding::UTF_8))
      @profiles = F.profiles.map(&:dup)
      @records = []
      @profile_records = []
      @native_data_paths = {}
      @fatal = nil
      @helper_process = nil
      @helper_stdout_sha256 = nil
      @recorder = nil
      validate_matrix!
    rescue JSON::ParserError => error
      fail!("stock matrix JSON is malformed: #{error.message}")
    end

    def run
      prepare_layout
      pin_runtime
      invoke_helper
      create_native_targets
      prepare_detached_parts
      attach_library_parts
      capture_native_profiles
      require_true(Digest::SHA256.file(@helper).hexdigest == @helper_sha256,
        'helper changed during paired evidence capture')
      require_true(Digest::SHA256.file(@matrix_path).hexdigest == @matrix_sha256,
        'stock matrix changed during paired evidence capture')
      write_summary('paired_custom_geo_profiles_observed')
      puts "W238 paired Custom Geo profiles=#{@profile_records.length}; evidence=#{@evidence_root}"
      true
    rescue StandardError => error
      @fatal ||= "#{error.class}: #{error.message}"
      write_summary('paired_probe_failed_or_diverged') rescue nil
      warn "W238 paired probe failure; raw native status is preserved: #{@fatal}"
      false
    end

    private

    def validate_matrix!
      require_true(@matrix.fetch('format') == P::MATRIX_FORMAT &&
        @matrix.fetch('row_keys') == F::ROW_KEYS && @matrix.fetch('mark_rows') == F::MARK_ROWS &&
        @matrix.fetch('profile_count') == F.profiles.length,
        'W238 stock matrix format or axes differ')
      source_pin = @matrix.fetch('source_pin')
      require_true(source_pin.fetch('checkout').start_with?(P::SOURCE_PREFIX) &&
        source_pin.fetch('revision') == P::SOURCE_REVISION &&
        source_pin.fetch('runtime_built_from_this_source_not_asserted') == true,
        'stock source pin or source/runtime separation differs')
      hashes = source_pin.fetch('file_hashes')
      require_true(hashes.length == P::SOURCE_SHA256.length && hashes.all? { |row| row.fetch('matches') },
        'stock matrix does not contain all pinned W238 source file hashes')
      runtime = @matrix.fetch('runtime_pin')
      require_true(runtime.fetch('version') == R::VERSION && runtime.fetch('build_hash') == R::BUILD_HASH &&
        runtime.fetch('sha256') == R::RUNTIME_SHA256 && Digest::SHA256.file(@binary).hexdigest == runtime.fetch('sha256'),
        'stock matrix runtime pin differs from the supplied native binary')

      observed = @matrix.fetch('profiles')
      details = @matrix.fetch('profile_evidence')
      require_true(observed.length == @profiles.length && details.length == @profiles.length,
        'stock matrix positive roster is incomplete')
      @profiles.each_with_index do |profile, index|
        core = observed.fetch(index)
        detail = details.fetch(index)
        id = profile.fetch('id')
        type = profile.fetch('declared_type')
        descriptor = F.descriptor_hex(type)
        values = F.values_hex(profile)
        require_true(core.fetch('id') == id && core.fetch('declared_type') == type &&
          core.fetch('observed_declared_type') == type && core.fetch('descriptor_hex') == descriptor &&
          core.fetch('values_hex') == values,
          "stock matrix profile or independent literal differs for #{id}")
        require_true(detail.fetch('id') == id && detail.fetch('requested_type') == type &&
          detail.fetch('classification') == 'stock_profile_observed' && detail.fetch('observed_declared_type') == type &&
          detail.fetch('descriptor_hex') == descriptor && detail.fetch('values_hex') == values &&
          detail.fetch('check_output') == CHECK_OUTPUT,
          "stock profile detail/classification differs for #{id}")
        census = detail.fetch('part_census')
        require_true(census[0, 4] == ['all_1_1_0', '5', '4', 'Wide'], "stock part census differs for #{id}")
        require_true(core.fetch('stock_part_path') == detail.fetch('stock_part_path'),
          "stock part path cross-reference differs for #{id}")
        path = File.expand_path(core.fetch('stock_part_path'))
        expected_prefix = File.join(@stock_root, 'stock-parts', id, 'all_1_1_0')
        require_true(path == expected_prefix, "stock part path is outside its canonical profile location: #{id}")
        stock_inventory = inventory(path)
        require_true(detail.fetch('physical').fetch('inventory') == stock_inventory,
          "stock part inventory differs from matrix evidence for #{id}")
        validate_stock_capture_files!(profile, detail)
        profile['stock_part_path'] = path
        profile['stock_inventory'] = stock_inventory
        profile['stock_detail'] = detail
      end
      refusal_observations = @matrix.fetch('refusal_observations')
      require_true(refusal_observations.length == F.source_refusal_cases.length + 1 &&
        refusal_observations.all? { |item| item.fetch('classification').start_with?('expected_normal_') },
        'stock constructor refusal census is incomplete or unexpected')
    rescue KeyError => error
      fail!("W238 stock matrix missing required field: #{error.message}")
    end

    def validate_stock_capture_files!(profile, detail)
      id = profile.fetch('id')
      rbnwt = detail.fetch('rbnwt')
      expected_rbnwt = F.rowbinary_with_names_and_types(profile)
      path = File.expand_path(rbnwt.fetch('path'))
      require_true(path == File.join(@stock_root, 'captures', "#{id}.rowbinary-with-names-and-types") &&
        File.file?(path) && !File.symlink?(path), "stock RBNWT capture path is invalid for #{id}")
      actual = File.binread(path)
      require_true(actual == expected_rbnwt && rbnwt.fetch('matches_independent_descriptor_and_values') == true &&
        rbnwt.fetch('observed_hex') == expected_rbnwt.unpack1('H*'), "stock descriptor/value bytes differ for #{id}")
      windows = detail.fetch('rowbinary_windows')
      expected_windows = F.rowbinary_windows(profile)
      require_true(windows.keys.sort == %w[full middle zero], "stock RowBinary window roster differs for #{id}")
      windows.each do |window, evidence|
        expected_path = File.join(@stock_root, 'captures', "#{id}-#{window}.rowbinary")
        file_path = File.expand_path(evidence.fetch('path'))
        bytes = File.binread(file_path)
        require_true(file_path == expected_path && File.file?(file_path) && !File.symlink?(file_path) &&
          bytes == expected_windows.fetch(window) && evidence.fetch('matches_independent_literal') == true &&
          evidence.fetch('observed_hex') == bytes.unpack1('H*'), "stock #{window} RowBinary differs for #{id}")
      end
    end

    def prepare_layout
      %w[invocations stores captures parts pins].each { |name| make_dir(File.join(@evidence_root, name)) }
      make_dir(File.join(@evidence_root, 'stores', 'native'))
      make_dir(File.join(@evidence_root, 'captures', 'native-rowbinary'))
      make_dir(File.join(@evidence_root, 'parts', 'native'))
      @recorder = R::Recorder.new(@evidence_root, @binary)
      write_json(File.join(@evidence_root, 'stock-matrix-reference.json'), {
        'path' => @matrix_path, 'sha256' => @matrix_sha256,
        'format' => P::MATRIX_FORMAT, 'stock_root' => @stock_root,
      })
    end

    def process(label, sql, input: nil, argv: nil)
      record = @recorder.run(label, File.join(@evidence_root, 'stores', 'native'), sql,
        input: input, timeout: PROCESS_TIMEOUT_SECONDS, argv: argv)
      @records << record
      record
    end

    def pin_runtime
      version = process('runtime-version-pin', 'SELECT version() FORMAT TSVRaw')
      checked_success!(version, 'native version pin')
      require_true(version.fetch('stdout').strip == R::VERSION, 'native version differs from exact runtime pin')
      build = process('runtime-build-pin',
        "SELECT concat(name, '=', value) FROM system.build_options WHERE name='VERSION_GITHASH' FORMAT TSVRaw")
      checked_success!(build, 'native build pin')
      require_true(build.fetch('stdout').strip == "VERSION_GITHASH=#{R::BUILD_HASH}",
        'native build hash differs from exact runtime pin')
      @runtime_observed = {
        'version' => version.fetch('stdout').strip,
        'build_hash' => build.fetch('stdout').strip.split('=', 2).last,
        'binary' => @binary, 'sha256' => Digest::SHA256.file(@binary).hexdigest,
        'source_correlation' => 'not_asserted',
      }
    end

    def run_helper
      argv = [@helper, '--stock-matrix', @matrix_path, '--output-root', @generated_root]
      base = File.join(@evidence_root, 'invocations', 'helper')
      write_new(base + '.argv.json', JSON.pretty_generate({ 'label' => HELPER_LABEL, 'argv' => argv,
        'environment' => { 'TZ' => 'UTC' }, 'timeout_seconds' => HELPER_TIMEOUT_SECONDS }) + "\n")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stdout_data = ''.b
      stderr_data = ''.b
      spawn_error = nil
      timed_out = false
      status = nil
      stdin = stdout = stderr = waiter = nil
      readers = []
      begin
        stdin, stdout, stderr, waiter = Open3.popen3({ 'TZ' => 'UTC' }, *argv)
        [stdin, stdout, stderr].each(&:binmode)
        readers = [Thread.new { stdout.read }, Thread.new { stderr.read }]
        stdin.close
        unless waiter.join(HELPER_TIMEOUT_SECONDS)
          timed_out = true
          R.terminate_child(waiter)
        end
        status = waiter.value
        stdout_data = readers[0].value
        stderr_data = readers[1].value
      rescue StandardError => error
        spawn_error = "#{error.class}: #{error.message}"
      ensure
        R.terminate_child(waiter) if waiter && waiter.alive?
        [stdin, stdout, stderr].compact.each { |pipe| pipe.close unless pipe.closed? rescue nil }
        readers.each(&:join)
      end
      record = {
        'label' => HELPER_LABEL,
        'classification' => if spawn_error then 'spawn_failure' elsif timed_out then 'process_timeout' elsif status && status.success? then 'process_success' else 'process_nonzero_or_signaled_exit' end,
        'exitstatus' => status && status.exitstatus, 'signaled' => status && status.signaled? || false,
        'termsig' => status && status.termsig, 'timed_out' => timed_out,
        'duration_ms' => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
        'spawn_error' => spawn_error, 'stdout_bytes' => stdout_data.bytesize, 'stderr_bytes' => stderr_data.bytesize,
      }
      write_new(base + '.stdout', stdout_data)
      write_new(base + '.stderr', stderr_data)
      write_new(base + '.status.json', JSON.pretty_generate(record) + "\n")
      record.merge('stdout' => stdout_data, 'stderr' => stderr_data, 'argv' => argv)
    end

    def invoke_helper
      require_true(Digest::SHA256.file(@helper).hexdigest == @helper_sha256,
        'helper SHA changed before invocation')
      record = run_helper
      @helper_process = clean_process(record)
      checked_success!(record, 'W238 Crystal helper')
      require_true(Digest::SHA256.file(@helper).hexdigest == @helper_sha256,
        'helper SHA changed during invocation')
      @helper_stdout_sha256 = Digest::SHA256.hexdigest(record.fetch('stdout'))
      output = JSON.parse(record.fetch('stdout').force_encoding(Encoding::UTF_8))
      require_true(output.fetch('format') == HELPER_FORMAT && output.fetch('matrix_path') == @matrix_path &&
        output.fetch('matrix_sha256') == @matrix_sha256 && output.fetch('output_root') == @generated_root &&
        output.fetch('row_keys') == F::ROW_KEYS && output.fetch('mark_rows') == F::MARK_ROWS,
        'W238 helper output provenance or physical axes differ')
      observed = output.fetch('profiles')
      require_true(observed.length == @profiles.length, 'W238 helper returned an incomplete profile roster')
      @profiles.each_with_index do |profile, index|
        helper = observed.fetch(index)
        id = profile.fetch('id')
        type = profile.fetch('declared_type')
        require_true(helper.fetch('id') == id && helper.fetch('declared_type') == type &&
          helper.fetch('type_shape') == F.expected_type_shape(type) &&
          helper.fetch('descriptor_hex') == F.descriptor_hex(type) && helper.fetch('values_hex') == F.values_hex(profile) &&
          File.expand_path(helper.fetch('stock_part_path')) == profile.fetch('stock_part_path'),
          "W238 helper profile identity/type/literal differs for #{id}")
        require_true(helper.fetch('writer') == {
          'api' => 'WidePartWriter.write_uint64_custom_geo_bulk_part',
          'rows_per_mark' => 2, 'profile' => 'with_size_stream',
          'granule_row_counts' => F::MARK_ROWS,
        }, "W238 helper writer metadata/profile differs for #{id}")
        path = File.expand_path(helper.fetch('library_part_path'))
        expected_path = File.join(@generated_root, 'generated', id, 'all_1_1_0')
        require_true(path == expected_path, "W238 helper part path differs for #{id}")
        generated_inventory = inventory(path)
        expected_values = F.values_hex(profile)
        %w[stock_direct_reader direct_reader].each do |reader_key|
          reader = helper.fetch(reader_key)
          require_true(reader.fetch('schema_declaration') == type && reader.fetch('source_declaration') == type &&
            reader.fetch('row_count') == F::ROW_KEYS.length && reader.fetch('mark_rows') == F::MARK_ROWS &&
            reader.fetch('mark_count') == F::MARK_ROWS.length &&
            reader.fetch('full_values_hex') == expected_values &&
            reader.fetch('middle_values_hex') == expected_values[2, 2] &&
            reader.fetch('final_short_values_hex') == expected_values[4, 1] &&
            reader.fetch('eof_empty') == true &&
            reader.fetch('physical_stream_names').is_a?(Array) && !reader.fetch('physical_stream_names').empty? &&
            reader.fetch('selected_checksum_names').is_a?(Array) && !reader.fetch('selected_checksum_names').empty?,
            "W238 helper #{reader_key} evidence differs for #{id}")
        end
        if F::TYPED_CONSUMER_IDS.include?(id)
          %w[stock_typed_consumer typed_consumer].each do |consumer_key|
            consumer = helper.fetch(consumer_key)
            require_true(consumer.fetch('values_hex') == expected_values &&
              consumer.fetch('keys') == F::ROW_KEYS && consumer.fetch('full_values_hex') == expected_values &&
              consumer.fetch('middle_window_values_hex') == expected_values[1, 3] && consumer.fetch('eof_callbacks') == 0,
              "W238 helper #{consumer_key} witness differs for #{id}")
          end
        else
          require_true(helper.fetch('stock_typed_consumer').nil? && helper.fetch('typed_consumer').nil?,
            "unexpected typed-consumer output for bare profile #{id}")
        end
        profile['library_part_path'] = path
        profile['library_inventory_before_attach'] = generated_inventory
        profile['helper_profile'] = helper
      end
      @helper_output = output
    rescue JSON::ParserError, KeyError => error
      fail!("W238 helper stdout does not satisfy its JSON contract: #{error.message}")
    end

    def native_create_sql
      statements = []
      @profiles.each do |profile|
        id = profile.fetch('id')
        table = table_name(profile)
        statements << create_sql(profile)
        statements << "SELECT 'W238_NATIVE_DATA_PATH_BEGIN_#{id}' FORMAT TSVRaw"
        statements << "SELECT arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw"
        statements << "SELECT 'W238_NATIVE_DATA_PATH_END_#{id}' FORMAT TSVRaw"
      end
      statements.join(";\n")
    end

    def create_native_targets
      record = process('native-create-all', native_create_sql)
      checked_success!(record, 'native table creation')
      @profiles.each do |profile|
        id = profile.fetch('id')
        path_text = marker_section(record.fetch('stdout'), "W238_NATIVE_DATA_PATH_BEGIN_#{id}",
          "W238_NATIVE_DATA_PATH_END_#{id}", "native data path #{id}")
        lines = path_text.lines.map(&:chomp)
        require_true(lines.length == 1 && !lines.first.empty? && !lines.first.include?("\t"),
          "native system.tables.data_paths result malformed for #{id}")
        path = File.expand_path(lines.first)
        native_store = File.join(@evidence_root, 'stores', 'native')
        require_true(path.start_with?(native_store + File::SEPARATOR) && File.directory?(path) &&
          !File.symlink?(path) && File.realpath(path) == path,
          "native data path escaped isolated evidence store for #{id}")
        profile['native_data_path'] = path
        @native_data_paths[id] = path
      end
    end

    def prepare_detached_parts
      @profiles.each do |profile|
        id = profile.fetch('id')
        data_path = profile.fetch('native_data_path')
        detached_dir = File.join(data_path, 'detached')
        require_true(File.directory?(detached_dir) && !File.symlink?(detached_dir) && File.realpath(detached_dir) == detached_dir,
          "native detached directory is absent/noncanonical for #{id}")
        detached_part = File.join(detached_dir, 'all_1_1_0')
        require_true(!File.exist?(detached_part) && !File.symlink?(detached_part),
          "native detached destination is not fresh for #{id}")
        before = inventory(profile.fetch('library_part_path'))
        require_true(before == profile.fetch('library_inventory_before_attach'),
          "helper part changed before copy for #{id}")
        FileUtils.cp_r(profile.fetch('library_part_path'), detached_part)
        detached_inventory = inventory(detached_part)
        require_true(detached_inventory == before, "detached copy differs byte-for-byte for #{id}")
        snapshot_root = File.join(@evidence_root, 'parts', 'native', id)
        require_true(!File.exist?(snapshot_root) && !File.symlink?(snapshot_root),
          "native detached-copy evidence destination is not fresh for #{id}")
        Dir.mkdir(snapshot_root, 0o700)
        snapshot_part = File.join(snapshot_root, 'all_1_1_0')
        FileUtils.cp_r(detached_part, snapshot_part)
        snapshot_inventory = inventory(snapshot_part)
        require_true(snapshot_inventory == detached_inventory,
          "preserved detached-copy evidence differs before ATTACH for #{id}")
        profile['detached_part_path'] = detached_part
        profile['detached_inventory_before_attach'] = detached_inventory
        profile['detached_snapshot_path'] = snapshot_part
      end
    end

    def native_attach_sql
      @profiles.map { |profile| "ALTER TABLE default.#{table_name(profile)} ATTACH PART 'all_1_1_0'" }.join(";\n")
    end

    def attach_library_parts
      record = process('native-attach-all', native_attach_sql)
      checked_success!(record, 'native ATTACH PART')
    end

    def native_capture_sql
      statements = []
      @profiles.each do |profile|
        id = profile.fetch('id')
        table = table_name(profile)
        statements.concat([
          "SELECT 'W238_NATIVE_CHECK_BEGIN_#{id}' FORMAT TSVRaw",
          "CHECK TABLE default.#{table} FORMAT TSVRaw",
          "SELECT 'W238_NATIVE_CHECK_END_#{id}' FORMAT TSVRaw",
          "SELECT 'W238_NATIVE_SCHEMA_BEGIN_#{id}' FORMAT TSVRaw",
          "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw",
          "SELECT 'W238_NATIVE_SCHEMA_END_#{id}' FORMAT TSVRaw",
          "SELECT 'W238_NATIVE_PART_BEGIN_#{id}' FORMAT TSVRaw",
          "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw",
          "SELECT 'W238_NATIVE_PART_END_#{id}' FORMAT TSVRaw",
        ])
        %w[full middle zero].each do |window|
          predicate = { 'full' => '', 'middle' => ' WHERE pk BETWEEN 22 AND 44', 'zero' => ' WHERE pk > 55' }.fetch(window)
          path = File.join(@evidence_root, 'captures', 'native-rowbinary', "#{id}-#{window}.rowbinary")
          statements << "SELECT pk, payload FROM default.#{table}#{predicate} ORDER BY pk INTO OUTFILE #{sql_quote(path)} FORMAT RowBinary"
        end
      end
      statements.join(";\n")
    end

    def compare_attached_inventory!(profile, attached_path)
      id = profile.fetch('id')
      generated = profile.fetch('library_inventory_before_attach')
      attached = inventory(attached_path)
      by_path_generated = generated.to_h { |entry| [entry.fetch('path'), entry] }
      by_path_attached = attached.to_h { |entry| [entry.fetch('path'), entry] }
      removed = (by_path_generated.keys - by_path_attached.keys).sort
      changed = by_path_generated.keys.select do |path|
        by_path_attached.key?(path) && by_path_generated.fetch(path) != by_path_attached.fetch(path)
      end.sort
      added = (by_path_attached.keys - by_path_generated.keys).sort
      require_true(removed.empty? && changed.empty? && [[], [INVALIDATED_FILE]].include?(added),
        "ATTACH changed generated inventory outside the exact invalidated-column allowance for #{id}")
      invalidated = nil
      if added == [INVALIDATED_FILE]
        invalidated_path = File.join(attached_path, INVALIDATED_FILE)
        invalidated = File.binread(invalidated_path)
        require_true(["_block_number\n_block_offset\n", "_block_offset\n_block_number\n"].include?(invalidated),
          "native invalidated_system_columns.txt has unexpected exact bytes for #{id}")
      end
      require_true(inventory(profile.fetch('library_part_path')) == generated,
        "native ATTACH modified original generated part for #{id}")
      { 'generated_inventory' => generated, 'attached_inventory' => attached,
        'removed' => removed, 'changed' => changed, 'added' => added,
        'invalidated_system_columns_hex' => invalidated&.unpack1('H*') }
    end

    def capture_native_profiles
      record = process('native-capture-all', native_capture_sql)
      checked_success!(record, 'native CHECK/schema/RowBinary capture')
      @profiles.each do |profile|
        id = profile.fetch('id')
        check = marker_section(record.fetch('stdout'), "W238_NATIVE_CHECK_BEGIN_#{id}",
          "W238_NATIVE_CHECK_END_#{id}", "native CHECK #{id}")
        require_true(check == CHECK_OUTPUT, "native CHECK did not report exact partsum=1 for #{id}: #{check.inspect}")
        schema = marker_section(record.fetch('stdout'), "W238_NATIVE_SCHEMA_BEGIN_#{id}",
          "W238_NATIVE_SCHEMA_END_#{id}", "native schema #{id}").lines.map(&:chomp)
        require_true(schema == ["pk\tUInt64", "payload\t#{profile.fetch('declared_type')}"],
          "native schema/nominal type differs for #{id}: #{schema.inspect}")
        part_text = marker_section(record.fetch('stdout'), "W238_NATIVE_PART_BEGIN_#{id}",
          "W238_NATIVE_PART_END_#{id}", "native part #{id}")
        part_rows = part_text.lines.map(&:chomp)
        require_true(part_rows.length == 1, "native attached part census is not singular for #{id}")
        fields = part_rows.first.split("\t", -1)
        require_true(fields.length == 5 && fields[0] == 'all_1_1_0' && fields[1] == '5' &&
          fields[2] == '4' && fields[3] == 'Wide', "native part identity/grid differs for #{id}: #{fields.inspect}")
        attached_part = File.join(profile.fetch('native_data_path'), 'all_1_1_0')
        require_true(File.expand_path(fields.fetch(4)) == attached_part && File.directory?(attached_part) &&
          !File.symlink?(attached_part) && File.realpath(attached_part) == attached_part,
          "native system.parts path differs from observed system.tables.data_paths for #{id}")
        detached = profile.fetch('detached_part_path')
        require_true(!File.exist?(detached) && !File.symlink?(detached),
          "ATTACH did not consume detached source for #{id}")
        inventory_comparison = compare_attached_inventory!(profile, attached_part)
        expected_windows = F.rowbinary_windows(profile)
        windows = %w[full middle zero].to_h do |window|
          path = File.join(@evidence_root, 'captures', 'native-rowbinary', "#{id}-#{window}.rowbinary")
          require_true(File.file?(path) && !File.symlink?(path), "native RowBinary output missing for #{id}/#{window}")
          actual = File.binread(path)
          expected = expected_windows.fetch(window)
          require_true(actual == expected, "native #{window} RowBinary differs from independent literal for #{id}")
          [window, { 'path' => path, 'bytes' => actual.bytesize, 'sha256' => Digest::SHA256.hexdigest(actual),
            'literal_hex' => expected.unpack1('H*'), 'observed_hex' => actual.unpack1('H*'), 'matches' => true }]
        end
        @profile_records << {
          'id' => id, 'declared_type' => profile.fetch('declared_type'),
          'descriptor_hex' => F.descriptor_hex(profile.fetch('declared_type')),
          'values_hex' => F.values_hex(profile), 'stock_part_path' => profile.fetch('stock_part_path'),
          'library_part_path' => profile.fetch('library_part_path'),
          'native_data_path' => profile.fetch('native_data_path'),
          'detached_part_path' => detached, 'attached_part_path' => attached_part,
          'detached_inventory_before_attach' => profile.fetch('detached_inventory_before_attach'),
          'detached_snapshot_path' => profile.fetch('detached_snapshot_path'),
          'helper_profile' => profile.fetch('helper_profile'),
          'native_check_output' => check, 'native_schema_rows' => schema,
          'native_part_census' => fields, 'inventory_comparison' => inventory_comparison,
          'rowbinary_windows' => windows,
        }
      end
    end

    def write_summary(classification)
      path = File.join(@evidence_root, 'summary.json')
      return if File.exist?(path)
      write_json(path, {
        'format' => SUMMARY_FORMAT, 'classification' => classification,
        'success' => classification == 'paired_custom_geo_profiles_observed', 'error' => @fatal,
        'evidence_root' => @evidence_root, 'stock_root' => @stock_root, 'stock_matrix_path' => @matrix_path,
        'stock_matrix_sha256' => @matrix_sha256, 'generated_root' => @generated_root,
        'helper_path' => @helper, 'helper_sha256' => @helper_sha256,
        'helper_sha256_at_start' => @helper_sha256_start, 'helper_stdout_sha256' => @helper_stdout_sha256,
        'helper_process' => @helper_process, 'helper_output_path' => File.join(@evidence_root, 'invocations', 'helper.stdout'),
        'runtime_pin' => @runtime_observed, 'profile_count_expected' => F.profiles.length,
        'profile_count_observed' => @profile_records.length,
        'profiles' => @profile_records,
        'processes' => @records.map { |record| clean_process(record) },
        'raw_invocation_directory' => File.join(@evidence_root, 'invocations'),
        'matrix_lineage' => 'Expected descriptors, scalar bytes, and RowBinary windows are independently authored by custom_geo_w238_fixtures.rb; helper and native outputs are compared to those literals.',
      })
    end
  end

  def main(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = <<~USAGE
        Usage:
          ruby scripts/recheck_custom_geo_recursive_w238.rb --clickhouse BIN --stock-matrix PATH --output-root EMPTY_EVIDENCE_ROOT --generated-root EMPTY_GENERATED_ROOT --helper BIN --helper-sha256 HEX
      USAGE
      opts.on('--clickhouse PATH') { |value| options[:clickhouse] = value }
      opts.on('--stock-matrix PATH') { |value| options[:stock_matrix] = value }
      opts.on('--output-root PATH') { |value| options[:output_root] = value }
      opts.on('--generated-root PATH') { |value| options[:generated_root] = value }
      opts.on('--helper PATH') { |value| options[:helper] = value }
      opts.on('--helper-sha256 HEX') { |value| options[:helper_sha256] = value }
    end
    parser.parse!(argv)
    expected = %i[clickhouse stock_matrix output_root generated_root helper helper_sha256]
    require_true(argv.empty? && expected.all? { |key| options.key?(key) }, parser.to_s)
    Probe.new(options).run
  rescue StandardError => error
    warn "W238 paired runner setup failure: #{error.class}: #{error.message}"
    false
  end
end

exit(RecheckCustomGeoRecursiveW238.main(ARGV) ? 0 : 1) if $PROGRAM_NAME == __FILE__
