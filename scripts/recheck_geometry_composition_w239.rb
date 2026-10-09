#!/usr/bin/env ruby
# Paired native ClickHouse and Crystal qualification for nominal Geometry
# recursive values. Expected literals originate in the independent stock probe.

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require_relative 'recheck_aggregate_recursive_w224'
require_relative 'probe_geometry_composition_w239'
require_relative 'check_custom_geo_recursive_evidence_w238'

module RecheckGeometryCompositionW239
  extend self

  R = RecheckAggregateRecursiveW224
  P = ProbeGeometryCompositionW239
  A = CheckCustomGeoRecursiveEvidenceW238
  EVIDENCE_PREFIX = '/private/tmp/crystal-click-w239-evidence.'.freeze
  GENERATED_PREFIX = '/private/tmp/crystal-click-w239-generated.'.freeze
  SUMMARY_FORMAT = 'geometry_composition_w239_summary_v1'.freeze
  HELPER_FORMAT = 'geometry_composition_w239_helper_v1'.freeze
  HELPER_LABEL = 'w239-geometry-library-writer-reader'.freeze
  HELPER_TIMEOUT_SECONDS = 600
  PROCESS_TIMEOUT_SECONDS = 90
  CHECK_OUTPUT = "all_1_1_0\t1\t\n".freeze
  INVALIDATED_FILE = A::W::INVALIDATED_FILE
  INVALIDATED_NAMES = A::W::INVALIDATED_NAMES
  STOCK_SETTINGS = P::STOCK_SETTINGS

  def fail!(message)
    raise ArgumentError, message
  end

  def require_true(condition, message)
    fail!(message) unless condition
  end

  def write_new(path, bytes)
    R.write_new(path, bytes)
  end

  def write_json(path, value)
    R.write_json(path, value)
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
    lines = stdout.dup.force_encoding(Encoding::UTF_8).scrub.lines
    starts = lines.each_index.select { |index| lines[index].chomp == start_marker }
    finishes = lines.each_index.select { |index| lines[index].chomp == end_marker }
    require_true(starts.length == 1 && finishes.length == 1 && finishes.first > starts.first,
      "raw stdout marker pair missing or duplicated for #{label}")
    lines[(starts.first + 1)...finishes.first].join
  end

  def profile_keys(profile)
    profile.fetch('keys')
  end

  def profile_values_hex(profile)
    profile.fetch('values').map { |value| P.value_body(profile, value).unpack1('H*') }
  end

  def expected_mark_rows(profile)
    profile.fetch('id') == 'geometry' ? [2, 2, 2, 2, 2] : [2, 2, 1]
  end

  def expected_reader(id, values)
    marks = id == 'geometry' ? [2, 2, 2, 2, 2] : [2, 2, 1]
    middle_mark_count = id == 'geometry' ? 2 : 1
    middle_start = marks.take(1).sum
    middle_count = marks.drop(1).take(middle_mark_count).sum
    {
      'row_count' => values.length, 'mark_rows' => marks,
      'full_values_hex' => values,
      'middle_values_hex' => values[middle_start, middle_count],
      'final_values_hex' => values[-marks.last, marks.last],
      'eof_empty' => true,
    }
  end

  def expected_consumer(id, values)
    {
      'keys' => profile_keys(P::PROFILES.find { |profile| profile.fetch('id') == id }),
      'values_hex' => values, 'full_values_hex' => values,
      'middle_window_values_hex' => values[1, 3], 'eof_callbacks' => 0,
    }
  end

  def expected_legacy_geometry(values)
    tags = values.map { |hex| [hex].pack('H*').getbyte(0) }
    { 'keys' => profile_keys(P::PROFILES.first), 'tags' => tags.map(&:to_i), 'null_count' => tags.count(255) }
  end

  def canonical_stock_root(matrix_path)
    full_matrix = File.expand_path(matrix_path)
    require_true(File.file?(full_matrix) && !File.symlink?(full_matrix) && File.realpath(full_matrix) == full_matrix,
      'stock matrix must be a canonical regular file')
    root = File.dirname(full_matrix)
    require_true(File.directory?(root) && !File.symlink?(root) && File.realpath(root) == root &&
      File.dirname(root) == File.realpath('/private/tmp') && root.start_with?(P::OUTPUT_PREFIX) &&
      File.basename(full_matrix) == P::MATRIX_FILE,
      'stock matrix must be in a canonical direct W239 /private/tmp root')
    [root, full_matrix]
  end

  def table_name(profile, suffix = 'native')
    "w239_#{suffix}_#{profile.fetch('id')}"
  end

  def create_sql(profile)
    "CREATE TABLE default.#{table_name(profile)} (pk UInt64, payload #{profile.fetch('declared_type')}) " \
      "ENGINE=MergeTree ORDER BY pk SETTINGS #{STOCK_SETTINGS.join(', ')}"
  end

  def expected_native_labels
    %w[runtime-version-pin runtime-build-pin native-create-all native-attach-all native-capture-all]
  end

  class Probe
    include RecheckGeometryCompositionW239

    def initialize(options)
      @binary = R.validate_binary!(options.fetch(:clickhouse))
      @helper = R.validate_program!(options.fetch(:helper), 'prebuilt W239 Crystal helper')
      @helper_sha256 = R.validate_sha256_pin!(options.fetch(:helper_sha256), 'expected W239 helper SHA-256')
      @helper_sha256_start = Digest::SHA256.file(@helper).hexdigest
      require_true(@helper_sha256_start == @helper_sha256, 'prebuilt helper differs from supplied SHA-256')
      @stock_root, @matrix_path = canonical_stock_root(options.fetch(:stock_matrix))
      @evidence_root = R.validate_root(options.fetch(:output_root), EVIDENCE_PREFIX, 'W239 evidence root')
      @generated_root = R.validate_root(options.fetch(:generated_root), GENERATED_PREFIX, 'W239 generated root')
      @matrix_bytes = File.binread(@matrix_path)
      @matrix_sha256 = Digest::SHA256.hexdigest(@matrix_bytes)
      @matrix = JSON.parse(@matrix_bytes.force_encoding(Encoding::UTF_8))
      @profiles = P::PROFILES.map(&:dup)
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
        'helper changed during paired capture')
      require_true(Digest::SHA256.file(@matrix_path).hexdigest == @matrix_sha256,
        'stock matrix changed during paired capture')
      write_summary('paired_geometry_composition_observed')
      puts "W239 paired Geometry profiles=#{@profile_records.length}; evidence=#{@evidence_root}"
      true
    rescue StandardError => error
      @fatal ||= "#{error.class}: #{error.message}"
      write_summary('paired_probe_failed_or_diverged') rescue nil
      warn "W239 paired probe failure; raw status is preserved: #{@fatal}"
      false
    end

    private

    def validate_matrix!
      require_true(@matrix.fetch('format') == P::MATRIX_FORMAT, 'W239 stock matrix format differs')
      source_pin = @matrix.fetch('source_pin')
      require_true(source_pin.fetch('checkout').start_with?(P::SOURCE_PREFIX) &&
        source_pin.fetch('revision') == P::SOURCE_REVISION &&
        source_pin.fetch('runtime_built_from_this_source_not_asserted') == true,
        'separately pinned W239 source identity/source-runtime boundary differs')
      source_hashes = source_pin.fetch('file_hashes')
      require_true(source_hashes.length == P::SOURCE_SHA256.length && source_hashes.all? { |row| row.fetch('matches') },
        'W239 source anchor hash census is incomplete or divergent')
      runtime = @matrix.fetch('runtime_pin')
      require_true(runtime.fetch('version') == R::VERSION && runtime.fetch('build_hash') == R::BUILD_HASH &&
        runtime.fetch('sha256') == R::RUNTIME_SHA256 && Digest::SHA256.file(@binary).hexdigest == R::RUNTIME_SHA256,
        'stock matrix runtime differs from the separately pinned native binary')
      require_true(runtime.fetch('source_correlation') == 'not_asserted',
        'stock matrix unexpectedly asserts source/runtime build provenance')
      observed = @matrix.fetch('profiles')
      require_true(observed.length == @profiles.length, 'W239 stock profile roster is incomplete')
      @profiles.each_with_index do |profile, index|
        row = observed.fetch(index)
        id = profile.fetch('id')
        type = profile.fetch('declared_type')
        values = profile_values_hex(profile)
        require_true(row.fetch('id') == id && row.fetch('requested_type') == type &&
          row.fetch('classification') == 'constructor_and_scalar_observed' &&
          row.fetch('keys') == profile_keys(profile) && row.fetch('row_count') == profile.fetch('values').length &&
          row.fetch('rowbinary_values_hex') == values &&
          row.fetch('descriptor_hex') == P.type_descriptor(profile).unpack1('H*') &&
          row.fetch('expected_rbnwt_hex') == P.expected_rbnwt(profile).unpack1('H*'),
          "W239 matrix identity or independent literals differ for #{id}")
        require_true(row.fetch('nominal_schema_matches') == true &&
          row.fetch('observed_schema_rows') == ["pk\tUInt64", "payload\t#{type}"],
          "W239 stock nominal schema differs for #{id}")
        census = row.fetch('part_census')
        # ClickHouse's stock MergeTree parts include one terminal EOF mark in
        # system.parts; the library reader exposes only the five/three data
        # marks and validates EOF separately.
        marks = id == 'geometry' ? 6 : 4
        require_true(census.fetch('name') == 'all_1_1_0' && census.fetch('rows') == profile.fetch('values').length &&
          census.fetch('marks') == marks && census.fetch('part_type') == 'Wide',
          "W239 stock part physical axes differ for #{id}")
        path = File.expand_path(row.fetch('stock_part_path'))
        expected_prefix = File.join(@stock_root, 'store') + File::SEPARATOR
        require_true(path.start_with?(expected_prefix) && path == File.expand_path(census.fetch('path')),
          "W239 stock part path escaped its canonical isolated store for #{id}")
        inventory = A.inventory(path)
        rbnwt = row.fetch('rbnwt')
        rbnwt_path = File.expand_path(rbnwt.fetch('path'))
        require_true(rbnwt_path == File.join(@stock_root, 'captures', "#{id}.rowbinary-with-names-and-types") &&
          A.read_regular(rbnwt_path) == P.expected_rbnwt(profile).b &&
          rbnwt.fetch('matches_independent_descriptor_and_values') == true &&
          rbnwt.fetch('observed_hex') == P.expected_rbnwt(profile).unpack1('H*'),
          "W239 stock captured RBNWT differs from independent descriptor/value bytes for #{id}")
        profile['stock_part_path'] = path
        profile['stock_inventory'] = inventory
        profile['stock_matrix_profile'] = row
      end
      refusals = @matrix.fetch('refusal_observations')
      require_true(refusals.length == P::REFUSALS.length + 1 &&
        refusals.all? { |row| row.fetch('classification').start_with?('expected_normal_') },
        'W239 constructor/descriptor refusal controls are incomplete')
    rescue KeyError => error
      fail!("W239 stock matrix is missing a required field: #{error.message}")
    end

    def prepare_layout
      %w[invocations stores captures parts pins].each { |name| Dir.mkdir(File.join(@evidence_root, name), 0o700) }
      Dir.mkdir(File.join(@evidence_root, 'stores', 'native'), 0o700)
      Dir.mkdir(File.join(@evidence_root, 'captures', 'native-rowbinary'), 0o700)
      Dir.mkdir(File.join(@evidence_root, 'parts', 'native'), 0o700)
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
        'version' => R::VERSION, 'build_hash' => R::BUILD_HASH, 'binary' => @binary,
        'sha256' => Digest::SHA256.file(@binary).hexdigest, 'source_correlation' => 'not_asserted',
      }
    end

    def run_helper
      argv = [@helper, '--stock-matrix', @matrix_path, '--output-root', @generated_root]
      base = File.join(@evidence_root, 'invocations', 'helper')
      write_new(base + '.argv.json', JSON.pretty_generate({
        'label' => HELPER_LABEL, 'argv' => argv, 'environment' => { 'TZ' => 'UTC' },
        'timeout_seconds' => HELPER_TIMEOUT_SECONDS,
      }) + "\n")
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
      require_true(Digest::SHA256.file(@helper).hexdigest == @helper_sha256, 'helper SHA differs before invocation')
      record = run_helper
      @helper_process = clean_process(record)
      checked_success!(record, 'W239 Crystal helper')
      require_true(Digest::SHA256.file(@helper).hexdigest == @helper_sha256, 'helper SHA changed during invocation')
      @helper_stdout_sha256 = Digest::SHA256.hexdigest(record.fetch('stdout'))
      output = JSON.parse(record.fetch('stdout').force_encoding(Encoding::UTF_8))
      require_true(output.fetch('format') == HELPER_FORMAT && output.fetch('matrix_path') == @matrix_path &&
        output.fetch('matrix_sha256') == @matrix_sha256 && output.fetch('output_root') == @generated_root,
        'W239 helper stdout provenance differs')
      observed = output.fetch('profiles')
      require_true(observed.length == @profiles.length, 'W239 helper profile roster is incomplete')
      @profiles.each_with_index do |profile, index|
        helper = observed.fetch(index)
        id = profile.fetch('id')
        type = profile.fetch('declared_type')
        values = profile_values_hex(profile)
        keys = profile_keys(profile)
        marks = expected_mark_rows(profile)
        require_true(helper.fetch('id') == id && helper.fetch('declared_type') == type &&
          helper.fetch('descriptor_hex') == P.type_descriptor(profile).unpack1('H*') &&
          helper.fetch('values_hex') == values && helper.fetch('row_keys') == keys &&
          helper.fetch('mark_rows') == marks && File.expand_path(helper.fetch('stock_part_path')) == profile.fetch('stock_part_path'),
          "W239 helper profile identity/type/literal differs for #{id}")
        writer = helper.fetch('writer')
        require_true(writer == {
          'api' => 'WidePartWriter.write_uint64_custom_geo_bulk_part', 'rows_per_mark' => 2,
          'profile' => 'with_size_stream', 'frame_bytes' => 4096, 'granule_row_counts' => marks,
        }, "W239 library writer contract differs for #{id}")
        expected_read = expected_reader(id, values)
        %w[stock_direct_reader direct_reader].each do |key|
          reader = helper.fetch(key)
          require_true(reader.fetch('schema_declaration') == type && reader.fetch('source_declaration') == type &&
            reader.fetch('row_count') == expected_read.fetch('row_count') && reader.fetch('mark_rows') == marks &&
            reader.fetch('mark_count') == marks.length && reader.fetch('full_values_hex') == values &&
            reader.fetch('middle_values_hex') == expected_read.fetch('middle_values_hex') &&
            reader.fetch('final_values_hex') == expected_read.fetch('final_values_hex') && reader.fetch('eof_empty') == true &&
            reader.fetch('physical_stream_names').is_a?(Array) && !reader.fetch('physical_stream_names').empty? &&
            reader.fetch('selected_checksum_names').is_a?(Array) && !reader.fetch('selected_checksum_names').empty?,
            "W239 helper #{key} direct-reader evidence differs for #{id}")
        end
        if profile.fetch('id') == 'geometry'
          expected_legacy = expected_legacy_geometry(values)
          %w[stock_typed_consumer typed_consumer].each do |key|
            consumer = helper.fetch(key)
            require_true(consumer.fetch('keys') == expected_legacy.fetch('keys') &&
              consumer.fetch('tags') == expected_legacy.fetch('tags') &&
              consumer.fetch('null_count') == expected_legacy.fetch('null_count'),
              "W239 legacy bare Geometry consumer differs for #{id}/#{key}")
          end
        else
          expected_typed = expected_consumer(id, values)
          %w[stock_typed_consumer typed_consumer].each do |key|
            consumer = helper.fetch(key)
            require_true(consumer.fetch('keys') == expected_typed.fetch('keys') &&
              consumer.fetch('values_hex') == values && consumer.fetch('full_values_hex') == values &&
              consumer.fetch('middle_window_values_hex') == expected_typed.fetch('middle_window_values_hex') &&
              consumer.fetch('eof_callbacks') == 0,
              "W239 recursive typed consumer differs for #{id}/#{key}")
          end
        end
        path = File.expand_path(helper.fetch('library_part_path'))
        require_true(path == File.join(@generated_root, 'generated', id, 'all_1_1_0'),
          "W239 helper output path differs for #{id}")
        profile['library_part_path'] = path
        profile['library_inventory_before_attach'] = A.inventory(path)
        profile['helper_profile'] = helper
      end
      @helper_output = output
    rescue JSON::ParserError, KeyError => error
      fail!("W239 helper stdout does not satisfy its contract: #{error.message}")
    end

    def native_create_sql
      statements = []
      @profiles.each do |profile|
        id = profile.fetch('id')
        statements << create_sql(profile)
        statements << "SELECT 'W239_NATIVE_DATA_PATH_BEGIN_#{id}' FORMAT TSVRaw"
        statements << "SELECT arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name='#{table_name(profile)}' FORMAT TSVRaw"
        statements << "SELECT 'W239_NATIVE_DATA_PATH_END_#{id}' FORMAT TSVRaw"
      end
      statements.join(";\n")
    end

    def create_native_targets
      record = process('native-create-all', native_create_sql)
      checked_success!(record, 'native table creation')
      @profiles.each do |profile|
        id = profile.fetch('id')
        text = marker_section(record.fetch('stdout'), "W239_NATIVE_DATA_PATH_BEGIN_#{id}",
          "W239_NATIVE_DATA_PATH_END_#{id}", "native data path #{id}")
        lines = text.lines.map(&:chomp)
        require_true(lines.length == 1 && !lines.first.empty? && !lines.first.include?("\t"),
          "native data path result malformed for #{id}")
        path = File.expand_path(lines.first)
        store = File.join(@evidence_root, 'stores', 'native')
        require_true(path.start_with?(store + File::SEPARATOR) && File.directory?(path) &&
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
        require_true(!File.exist?(detached_part) && !File.symlink?(detached_part), "detached destination is not fresh for #{id}")
        generated = A.inventory(profile.fetch('library_part_path'))
        require_true(generated == profile.fetch('library_inventory_before_attach'), "generated part changed before copy for #{id}")
        FileUtils.cp_r(profile.fetch('library_part_path'), detached_part)
        detached_inventory = A.inventory(detached_part)
        require_true(detached_inventory == generated, "detached copy differs byte-for-byte for #{id}")
        snapshot_root = File.join(@evidence_root, 'parts', 'native', id)
        require_true(!File.exist?(snapshot_root) && !File.symlink?(snapshot_root), "snapshot destination is not fresh for #{id}")
        Dir.mkdir(snapshot_root, 0o700)
        snapshot_part = File.join(snapshot_root, 'all_1_1_0')
        FileUtils.cp_r(detached_part, snapshot_part)
        require_true(A.inventory(snapshot_part) == detached_inventory, "preserved detached snapshot differs for #{id}")
        profile['detached_part_path'] = detached_part
        profile['detached_inventory_before_attach'] = detached_inventory
        profile['detached_snapshot_path'] = snapshot_part
      end
    end

    def native_attach_sql
      @profiles.map { |profile| "ALTER TABLE default.#{table_name(profile)} ATTACH PART 'all_1_1_0'" }.join(";\n")
    end

    def attach_library_parts
      checked_success!(process('native-attach-all', native_attach_sql), 'native ATTACH PART')
    end

    def native_capture_sql
      statements = []
      @profiles.each do |profile|
        id = profile.fetch('id')
        table = table_name(profile)
        statements.concat([
          "SELECT 'W239_NATIVE_CHECK_BEGIN_#{id}' FORMAT TSVRaw",
          "CHECK TABLE default.#{table} FORMAT TSVRaw",
          "SELECT 'W239_NATIVE_CHECK_END_#{id}' FORMAT TSVRaw",
          "SELECT 'W239_NATIVE_SCHEMA_BEGIN_#{id}' FORMAT TSVRaw",
          "SELECT name, type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw",
          "SELECT 'W239_NATIVE_SCHEMA_END_#{id}' FORMAT TSVRaw",
          "SELECT 'W239_NATIVE_PART_BEGIN_#{id}' FORMAT TSVRaw",
          "SELECT name, toString(rows), toString(marks), part_type, path FROM system.parts WHERE database='default' AND table='#{table}' AND active ORDER BY name FORMAT TSVRaw",
          "SELECT 'W239_NATIVE_PART_END_#{id}' FORMAT TSVRaw",
        ])
        { 'full' => '', 'middle' => ' WHERE pk BETWEEN 22 AND 44', 'zero' => ' WHERE pk > 111' }.each do |window, predicate|
          path = File.join(@evidence_root, 'captures', 'native-rowbinary', "#{id}-#{window}.rowbinary")
          statements << "SELECT pk, payload FROM default.#{table}#{predicate} ORDER BY pk INTO OUTFILE #{sql_quote(path)} FORMAT RowBinary"
        end
      end
      statements.join(";\n")
    end

    def compare_attached_inventory!(profile, attached_path)
      generated = profile.fetch('library_inventory_before_attach')
      attached = A.inventory(attached_path)
      generated_by_path = generated.to_h { |entry| [entry.fetch('path'), entry] }
      attached_by_path = attached.to_h { |entry| [entry.fetch('path'), entry] }
      removed = (generated_by_path.keys - attached_by_path.keys).sort
      changed = generated_by_path.keys.select do |path|
        attached_by_path.key?(path) && generated_by_path.fetch(path) != attached_by_path.fetch(path)
      end.sort
      added = (attached_by_path.keys - generated_by_path.keys).sort
      require_true(removed.empty? && changed.empty? && [[], [INVALIDATED_FILE]].include?(added),
        "ATTACH inventory differs outside exact invalidated-system-columns allowance for #{profile.fetch('id')}")
      invalidated = if added == [INVALIDATED_FILE]
                      bytes = A.read_regular(File.join(attached_path, INVALIDATED_FILE))
                      allowed = ["#{INVALIDATED_NAMES[0]}\n#{INVALIDATED_NAMES[1]}\n",
                        "#{INVALIDATED_NAMES[1]}\n#{INVALIDATED_NAMES[0]}\n"]
                      require_true(allowed.include?(bytes), 'invalidated_system_columns.txt has unexpected exact bytes')
                      bytes
                    end
      require_true(A.inventory(profile.fetch('library_part_path')) == generated,
        "ATTACH modified original generated part for #{profile.fetch('id')}")
      { 'generated_inventory' => generated, 'attached_inventory' => attached,
        'removed' => removed, 'changed' => changed, 'added' => added,
        'invalidated_system_columns_hex' => invalidated&.unpack1('H*') }
    end

    def capture_native_profiles
      record = process('native-capture-all', native_capture_sql)
      checked_success!(record, 'native CHECK/schema/RowBinary capture')
      @profiles.each do |profile|
        id = profile.fetch('id')
        type = profile.fetch('declared_type')
        path = profile.fetch('native_data_path')
        attached = File.join(path, 'all_1_1_0')
        check = marker_section(record.fetch('stdout'), "W239_NATIVE_CHECK_BEGIN_#{id}",
          "W239_NATIVE_CHECK_END_#{id}", "native CHECK #{id}")
        require_true(check == CHECK_OUTPUT, "native CHECK did not report exactly one valid part for #{id}")
        schema = marker_section(record.fetch('stdout'), "W239_NATIVE_SCHEMA_BEGIN_#{id}",
          "W239_NATIVE_SCHEMA_END_#{id}", "native schema #{id}").lines.map(&:chomp)
        require_true(schema == ["pk\tUInt64", "payload\t#{type}"], "native nominal schema differs for #{id}")
        part_text = marker_section(record.fetch('stdout'), "W239_NATIVE_PART_BEGIN_#{id}",
          "W239_NATIVE_PART_END_#{id}", "native part #{id}")
        part_rows = part_text.lines.map(&:chomp)
        require_true(part_rows.length == 1, "native part census is not singular for #{id}")
        fields = part_rows.first.split("\t", -1)
        expected_rows = profile.fetch('values').length
        # ClickHouse's attached part census includes its terminal EOF mark.
        # The independent writer/helper mark schedule remains five/three data
        # marks; the extra census mark is not a reader granule.
        expected_marks = id == 'geometry' ? 6 : 4
        require_true(fields.length == 5 && fields[0] == 'all_1_1_0' && fields[1].to_i == expected_rows &&
          fields[2].to_i == expected_marks && fields[3] == 'Wide' && File.expand_path(fields[4]) == attached,
          "native part row/mark/path differs for #{id}")
        require_true(File.directory?(attached) && !File.symlink?(attached) && File.realpath(attached) == attached,
          "attached part path is absent or noncanonical for #{id}")
        detached = profile.fetch('detached_part_path')
        require_true(!File.exist?(detached) && !File.symlink?(detached), "ATTACH did not consume detached source for #{id}")
        comparison = compare_attached_inventory!(profile, attached)
        values = profile_values_hex(profile)
        windows = %w[full middle zero].to_h do |window|
          capture = File.join(@evidence_root, 'captures', 'native-rowbinary', "#{id}-#{window}.rowbinary")
          actual = A.read_regular(capture)
          expected = case window
                     when 'full' then P.expected_insert_rows(profile)
                     when 'middle' then profile.fetch('keys').zip(profile.fetch('values')).select { |key, _value| key >= 22 && key <= 44 }.map { |key, value| P.u64(key) + P.value_body(profile, value) }.join.b
                     else ''.b
                     end
          require_true(actual == expected, "native #{window} RowBinary differs from independent keys/values for #{id}")
          [window, { 'path' => capture, 'bytes' => actual.bytesize,
            'sha256' => Digest::SHA256.hexdigest(actual), 'literal_hex' => expected.unpack1('H*'),
            'observed_hex' => actual.unpack1('H*'), 'matches' => true }]
        end
        @profile_records << {
          'id' => id, 'declared_type' => type, 'descriptor_hex' => P.type_descriptor(profile).unpack1('H*'),
          'values_hex' => values, 'stock_part_path' => profile.fetch('stock_part_path'),
          'library_part_path' => profile.fetch('library_part_path'), 'native_data_path' => path,
          'detached_part_path' => detached, 'attached_part_path' => attached,
          'detached_inventory_before_attach' => profile.fetch('detached_inventory_before_attach'),
          'detached_snapshot_path' => profile.fetch('detached_snapshot_path'),
          'helper_profile' => profile.fetch('helper_profile'),
          'native_check_output' => check, 'native_schema_rows' => schema,
          'native_part_census' => fields, 'inventory_comparison' => comparison,
          'rowbinary_windows' => windows,
        }
      end
    end

    def write_summary(classification)
      path = File.join(@evidence_root, 'summary.json')
      return if File.exist?(path)
      write_json(path, {
        'format' => SUMMARY_FORMAT, 'classification' => classification,
        'success' => classification == 'paired_geometry_composition_observed', 'error' => @fatal,
        'evidence_root' => @evidence_root, 'stock_root' => @stock_root,
        'stock_matrix_path' => @matrix_path, 'stock_matrix_sha256' => @matrix_sha256,
        'generated_root' => @generated_root, 'helper_path' => @helper,
        'helper_sha256' => @helper_sha256, 'helper_sha256_at_start' => @helper_sha256_start,
        'helper_stdout_sha256' => @helper_stdout_sha256,
        'helper_process' => @helper_process, 'helper_output_path' => File.join(@evidence_root, 'invocations', 'helper.stdout'),
        'runtime_pin' => @runtime_observed, 'profile_count_expected' => @profiles.length,
        'profile_count_observed' => @profile_records.length, 'profiles' => @profile_records,
        'processes' => @records.map { |record| clean_process(record) },
        'matrix_lineage' => 'Stock literal descriptors and values originate in probe_geometry_composition_w239.rb; runtime source correlation is not asserted. The raw auditor checks consistency, not immutable execution provenance.',
      })
    end
  end

  def main(argv)
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = <<~USAGE
        Usage:
          ruby scripts/recheck_geometry_composition_w239.rb --clickhouse BIN --stock-matrix PATH --output-root EMPTY_EVIDENCE_ROOT --generated-root EMPTY_GENERATED_ROOT --helper BIN --helper-sha256 HEX
      USAGE
      opts.on('--clickhouse PATH') { |value| options[:clickhouse] = value }
      opts.on('--stock-matrix PATH') { |value| options[:stock_matrix] = value }
      opts.on('--output-root PATH') { |value| options[:output_root] = value }
      opts.on('--generated-root PATH') { |value| options[:generated_root] = value }
      opts.on('--helper PATH') { |value| options[:helper] = value }
      opts.on('--helper-sha256 HEX') { |value| options[:helper_sha256] = value }
    end
    parser.parse!(argv)
    required = %i[clickhouse stock_matrix output_root generated_root helper helper_sha256]
    require_true(argv.empty? && required.all? { |key| options.key?(key) }, parser.to_s)
    Probe.new(options).run
  rescue StandardError => error
    warn "W239 paired runner setup failure: #{error.class}: #{error.message}"
    false
  end
end

exit(RecheckGeometryCompositionW239.main(ARGV) ? 0 : 1) if $PROGRAM_NAME == __FILE__
