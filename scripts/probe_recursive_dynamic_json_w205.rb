#!/usr/bin/env ruby
# Bounded whole-part Q=0 stock/library ATTACH check. Consumes only the supplied
# pinned ClickHouse executable and prebuilt Crystal helper; it never compiles.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require_relative 'probe_recursive_dynamic_json_w204'

module ProbeRecursiveDynamicJSONW205
  W204 = ProbeRecursiveDynamicJSONW204
  W202 = W204::W202
  BINARY = W204::BINARY
  BINARY_SHA256 = W204::BINARY_SHA256
  VERSION = W204::VERSION
  BUILD = W204::BUILD
  MEMORY = W204::MEMORY
  TIMEOUT = W204::TIMEOUT
  GRACE = W204::GRACE
  OUTER_RUN_SAFE_LIMIT = W204::OUTER_RUN_SAFE_LIMIT
  SOURCE_ARCHIVE_COMMIT = 'ef037e60fc7f5654c8c80eefb8be82e3c56f9a67'.freeze

  CASE_ID = 'whole_zero_q_array_tuple'.freeze
  PROFILE_IDS = %w[single_stream with_size_stream].freeze
  FORMAT_INPUT = 'recursive_dynamic_json_w205_input_v1'.freeze
  FORMAT_OUTPUT = 'recursive_dynamic_json_w205_helper_v1'.freeze
  JSON_TYPE = 'JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8)'.freeze
  DYNAMIC_TYPE = 'Dynamic(max_types=1)'.freeze
  TYPE = "Array(Tuple(doc #{JSON_TYPE}, d #{DYNAMIC_TYPE}))".freeze
  DYNAMIC_SITE = 'root/array[0]/tuple[1]'.freeze
  SETTINGS = W204::SETTINGS
  WINDOWS = %w[FULL FIRST LATER MIDDLE FINAL ZERO].freeze

  # Independent literals for the two writers. The stock source has no Dynamic
  # actuals; the library writer deliberately persists an unused UInt64 arm.
  # Do not normalize one roster to the other.
  SOURCE_BASE_STREAMS = %w[
    payload.size0
    payload%2Edoc.object_structure
    payload%2Edoc.t
    payload%2Edoc.object_shared_data.size1
    payload%2Edoc.object_shared_data%2Epaths
    payload%2Edoc.object_shared_data%2Evalues
    payload%2Ed.dynamic_structure
    payload%2Ed.variant_discr
    payload%2Ed.SharedVariant
  ].freeze
  LIBRARY_BASE_STREAMS = %w[
    payload.size0
    payload%2Edoc.object_structure
    payload%2Edoc.t
    payload%2Edoc.object_shared_data.size1
    payload%2Edoc.object_shared_data%2Epaths
    payload%2Edoc.object_shared_data%2Evalues
    payload%2Ed.dynamic_structure
    payload%2Ed.variant_discr
    payload%2Ed.SharedVariant
    payload%2Ed.UInt64
  ].freeze
  SOURCE_SIZE_STREAMS = %w[payload%2Ed.SharedVariant.size].freeze
  LIBRARY_SIZE_STREAMS = %w[payload%2Ed.SharedVariant.size].freeze

  def self.table(profile, origin)
    "#{origin}_whole_zero_q_#{profile}"
  end

  def self.expected_streams(origin, profile)
    names = case origin
            when 'source' then SOURCE_BASE_STREAMS.dup
            when 'library' then LIBRARY_BASE_STREAMS.dup
            else raise ArgumentError, "unknown W205 stream origin: #{origin.inspect}"
            end
    case profile
    when 'single_stream'
      # Base roster only.
    when 'with_size_stream'
      names.concat(origin == 'source' ? SOURCE_SIZE_STREAMS : LIBRARY_SIZE_STREAMS)
    else
      raise ArgumentError, "unknown W205 String profile: #{profile.inspect}"
    end
    names.sort
  end

  def self.values
    (1..8).map { |key| [key.to_s, []] }
  end

  def self.marks
    values.each_slice(2).to_a
  end

  def self.sql_quote(value)
    "'#{value.to_s.gsub(/[\\']/) { |character| "\\#{character}" }}'"
  end

  def self.empty_array_sql
    "CAST([], #{sql_quote(TYPE)})"
  end

  def self.sql_windows(table_name, profile)
    predicates = {
      'FULL' => '',
      'FIRST' => ' WHERE pk BETWEEN 1 AND 2',
      'LATER' => ' WHERE pk BETWEEN 3 AND 4',
      'MIDDLE' => ' WHERE pk BETWEEN 5 AND 6',
      'FINAL' => ' WHERE pk BETWEEN 7 AND 8',
      'ZERO' => ' WHERE pk > 8',
    }
    predicates.flat_map do |window, predicate|
      tag = "__W205_VALUES_#{window}__"
      query = "SELECT '#{tag}', '#{table_name}', toString(pk), hex(toJSONString(payload)), " \
              "toString(length(payload)), toTypeName(payload) " \
              "FROM default.#{table_name}#{predicate} ORDER BY pk " \
              "SETTINGS print_pretty_type_names=0 FORMAT TSVRaw;"
      if window == 'ZERO'
        ["SELECT '__W205_ZERO_BEGIN__', '#{table_name}', '#{profile}', 'values' FORMAT TSVRaw;",
         query,
         "SELECT '__W205_ZERO_END__', '#{table_name}', '#{profile}', 'values' FORMAT TSVRaw;"]
      else
        [query]
      end
    end
  end

  class Probe < W202::Probe
    def initialize(binary, crystal_helper, evidence_root)
      super
      @source_parts = {}
      @source_snapshots = {}
      @library_parts = {}
      @library_snapshots = {}
      @attached_library_snapshots = {}
      @data_paths = {}
      @table_identity = {}
      @roster_evidence = {}
      @source_manifest_observations = {}
      @fatal_error = nil
    end

    def run
      prepare_layout!
      @binary_sha_before = binary_sha
      fail!('pinned ClickHouse executable SHA-256 mismatch before probe') unless @binary_sha_before == BINARY_SHA256
      @helper_sha_before = helper_sha
      fail!('prebuilt Crystal helper SHA changed before probe') unless @helper_sha_before == helper_sha

      initial = run_clickhouse('native_sources', initial_sql)
      assert_native_invocation!(initial)
      native = parse_native(initial[:stdout])
      assert_pin!(native)
      assert_initial_native!(native)

      helper_input = build_helper_input
      input_path = File.join(@root, 'generated', 'helper-input.json')
      input_bytes = JSON.pretty_generate(helper_input) + "\n"
      write_new(input_path, input_bytes)
      @helper_input = {path: input_path, bytes: input_bytes.bytesize, sha256: Digest::SHA256.hexdigest(input_bytes)}
      helper = run_helper(input_path)
      assert_helper_output!(helper[:data])
      attach_library_parts!

      attached = run_clickhouse('attach_and_check', attached_sql)
      assert_native_invocation!(attached)
      attached_native = parse_native(attached[:stdout])
      assert_pin!(attached_native)
      assert_attached_native!(attached_native)

      @source_parts.each do |profile, path|
        fail!("stock source part changed during ATTACH/SELECT: #{profile}") unless snapshot_part(path) == @source_snapshots.fetch(profile)
      end
      @library_parts.each do |profile, path|
        fail!("published library part changed during ATTACH/SELECT: #{profile}") unless snapshot_part(path) == @library_snapshots.fetch(profile)
      end
      @binary_sha_after = binary_sha
      @helper_sha_after = helper_sha
      fail!('pinned ClickHouse executable SHA changed during probe') unless @binary_sha_after == BINARY_SHA256
      fail!('prebuilt Crystal helper SHA changed during probe') unless @helper_sha_after == @helper_sha_before

      write_evidence(status: 'paired_whole_part_zero_q_observed', source: native,
                     helper: helper[:data], helper_invocation: helper[:record],
                     initial_invocation: initial[:record], attached: attached_native,
                     attached_invocation: attached[:record])
      puts "W205 whole-part zero-Q recursive Array/Tuple profiles=#{PROFILE_IDS.size}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @binary_sha_after = binary_sha rescue nil
      @helper_sha_after = helper_sha rescue nil
      write_evidence(status: 'runner_failure_or_observations_differ', fatal_error: @fatal_error) rescue nil
      warn "W205 probe failure (process failure is not format evidence): #{@fatal_error}"
      false
    end

    private

    def fail!(message)
      raise RuntimeError, "W205 whole-part zero-Q oracle: #{message}"
    end

    def prepare_layout!
      %w[invocations inputs stores generated].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
      PROFILE_IDS.each do |profile|
        profile_root = File.join(@root, 'generated', profile)
        Dir.mkdir(profile_root, 0o700)
        Dir.mkdir(File.join(profile_root, CASE_ID), 0o700)
        %w[source library].each do |origin|
          name = table(profile, origin)
          @table_identity[name] = [profile, origin]
        end
      end
    end

    def table(profile, origin)
      ProbeRecursiveDynamicJSONW205.table(profile, origin)
    end

    def source_tables
      PROFILE_IDS.map { |profile| table(profile, 'source') }
    end

    def all_tables
      PROFILE_IDS.flat_map { |profile| %w[source library].map { |origin| table(profile, origin) } }
    end

    def initial_sql
      statements = [
        'SET flatten_nested=0;', 'SET allow_suspicious_low_cardinality_types=1;',
        'SET output_format_json_named_tuples_as_objects=1;', 'SET print_pretty_type_names=0;',
        "SELECT '__W205_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
      ]
      PROFILE_IDS.each do |profile|
        settings = "#{SETTINGS}, string_serialization_version='#{profile}'"
        source = table(profile, 'source')
        library = table(profile, 'library')
        [source, library].each do |name|
          statements << "CREATE TABLE default.#{name} (pk UInt64, payload #{TYPE}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings};"
        end
        values = (1..8).map { |key| "(#{key}, #{ProbeRecursiveDynamicJSONW205.empty_array_sql})" }
        statements << "INSERT INTO default.#{source} VALUES\n#{values.join(",\n")};"
        statements << check_sql(source, profile)
      end
      names = all_tables.map { |name| "'#{name}'" }.join(',')
      statements << "SELECT '__W205_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{names}) ORDER BY table, position FORMAT TSVRaw;"
      statements << "SELECT '__W205_DATA_PATH__', name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name IN (#{names}) ORDER BY name FORMAT TSVRaw;"
      statements << parts_sql(source_tables)
      source_tables.each do |name|
        profile = @table_identity.fetch(name)[0]
        statements.concat(ProbeRecursiveDynamicJSONW205.sql_windows(name, profile))
      end
      statements.join("\n") + "\n"
    end

    def attached_sql
      statements = [
        'SET flatten_nested=0;', 'SET allow_suspicious_low_cardinality_types=1;',
        'SET output_format_json_named_tuples_as_objects=1;', 'SET print_pretty_type_names=0;',
        "SELECT '__W205_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
      ]
      PROFILE_IDS.each do |profile|
        library = table(profile, 'library')
        statements << "ALTER TABLE default.#{library} ATTACH PART 'all_1_1_0';"
        statements << check_sql(table(profile, 'source'), profile)
        statements << check_sql(library, profile)
      end
      names = all_tables.map { |name| "'#{name}'" }.join(',')
      statements << "SELECT '__W205_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{names}) ORDER BY table, position FORMAT TSVRaw;"
      statements << parts_sql(all_tables)
      all_tables.each do |name|
        profile = @table_identity.fetch(name)[0]
        statements.concat(ProbeRecursiveDynamicJSONW205.sql_windows(name, profile))
      end
      statements.join("\n") + "\n"
    end

    def check_sql(name, profile)
      ["SELECT '__W205_CHECK_BEGIN__', '#{name}', '#{profile}' FORMAT TSVRaw;",
       "CHECK TABLE default.#{name} FORMAT TSV;",
       "SELECT '__W205_CHECK_END__', '#{name}', '#{profile}' FORMAT TSVRaw;"].join("\n")
    end

    def parts_sql(tables)
      names = tables.map { |name| "'#{name}'" }.join(',')
      "SELECT '__W205_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table IN (#{names}) AND active ORDER BY table,name FORMAT TSVRaw;"
    end

    def parse_native(stdout)
      lines = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      records = ->(prefix) { lines.select { |line| line.start_with?("#{prefix}\t") }.map { |line| line.split("\t", -1) } }
      known = %w[__W205_PIN__ __W205_SCHEMA__ __W205_DATA_PATH__ __W205_PART__
                 __W205_CHECK_BEGIN__ __W205_CHECK_END__ __W205_ZERO_BEGIN__ __W205_ZERO_END__] +
        WINDOWS.map { |window| "__W205_VALUES_#{window}__" }
      unknown = lines.each_with_object([]) do |line, tags|
        next unless line.start_with?('__W205_')
        tag = line.split("\t", 2).first
        tags << tag unless known.include?(tag)
      end
      fail!("unknown native marker tags: #{unknown.uniq.inspect}") unless unknown.empty?

      checks = {}
      active = nil
      lines.each do |line|
        if line.start_with?("__W205_CHECK_BEGIN__\t")
          fields = line.split("\t", -1)
          fail!('malformed or nested CHECK begin') unless fields.size == 3 && !active
          active = fields.drop(1)
          fail!('duplicate CHECK block') if checks.key?(active)
          checks[active] = []
        elsif line.start_with?("__W205_CHECK_END__\t")
          fields = line.split("\t", -1)
          fail!('malformed or mismatched CHECK end') unless fields.size == 3 && active == fields.drop(1)
          active = nil
        elsif active
          checks.fetch(active) << line
        end
      end
      fail!('unterminated CHECK block') if active

      pin = records.call('__W205_PIN__')
      fail!('runtime pin must occur exactly once') unless pin.size == 1 && pin.first.size == 3
      schemas = records.call('__W205_SCHEMA__').map do |fields|
        fail!('schema record width differs') unless fields.size == 4
        fields.drop(1)
      end
      paths = records.call('__W205_DATA_PATH__').to_h do |fields|
        fail!('data-path record width differs') unless fields.size == 3
        [fields[1], fields[2]]
      end
      fail!('duplicate table data path') unless paths.size == records.call('__W205_DATA_PATH__').size
      parts = records.call('__W205_PART__').to_h do |fields|
        fail!('part record width differs') unless fields.size == 7
        [fields[1], {name: fields[2], path: fields[3], type: fields[4], rows: fields[5], marks: fields[6]}]
      end
      part_rows = records.call('__W205_PART__')
      fail!('duplicate active part record') unless parts.size == part_rows.size
      values = lines.select { |line| line.start_with?('__W205_VALUES_') }
                     .map { |line| line.split("\t", -1) }
                     .each_with_object({}) do |fields, output|
        fail!('selected-value record width differs') unless fields.size == 6
        window = fields[0].delete_prefix('__W205_VALUES_').delete_suffix('__')
        (output[[fields[1], window]] ||= []) << fields.drop(2)
      end
      zero_events = lines.select { |line| line.start_with?("__W205_ZERO_BEGIN__\t") || line.start_with?("__W205_ZERO_END__\t") }
                         .map { |line| line.split("\t", -1) }
      {pin: pin.first.join("\t"), checks: checks, schemas: schemas, data_paths: paths,
       parts: parts, value_rows: values, zero_events: zero_events}
    end

    def assert_pin!(native)
      expected = "__W205_PIN__\t#{VERSION}\t#{BUILD}"
      fail!("runtime version/build differs: #{native[:pin].inspect}") unless native[:pin] == expected
    end

    def expected_schemas
      all_tables.sort.flat_map { |name| [[name, 'pk', 'UInt64'], [name, 'payload', TYPE]] }
    end

    def expected_check_blocks(tables)
      tables.to_h do |name|
        profile = @table_identity.fetch(name)[0]
        [[name, profile], ["all_1_1_0\t1\t"]]
      end
    end

    def assert_initial_native!(native)
      fail!("stock CHECK results differ: #{native[:checks].inspect}") unless native[:checks] == expected_check_blocks(source_tables)
      fail!('stock schema roster differs from exact declarations') unless native[:schemas] == expected_schemas
      fail!('initial data-path roster differs') unless native[:data_paths].keys.sort == all_tables.sort
      native[:data_paths].each_value { |path| validate_store_path!(path) }
      @data_paths = native[:data_paths].dup
      fail!('stock source active part roster differs') unless native[:parts].keys.sort == source_tables.sort
      source_tables.each do |name|
        profile = @table_identity.fetch(name)[0]
        part = native[:parts].fetch(name)
        fail!("#{name} is not one eight-row Wide part with four marks plus EOF") unless
          part[:name] == 'all_1_1_0' && part[:type] == 'Wide' && part[:rows] == '8' && part[:marks] == '5'
        path = validate_source_part!(part[:path])
        @source_parts[profile] = path
        @source_snapshots[profile] = snapshot_part(path)
        @source_manifest_observations[profile] = parse_manifest(path, "stock/#{profile}")
        assert_native_values!(native, name)
      end
      fail!('stock zero-window boundary roster differs') unless native[:zero_events] == zero_events(source_tables)
    end

    def assert_attached_native!(native)
      fail!("stock/attached CHECK results differ: #{native[:checks].inspect}") unless native[:checks] == expected_check_blocks(all_tables)
      fail!('attached schema roster differs') unless native[:schemas] == expected_schemas
      fail!('attached part roster differs') unless native[:parts].keys.sort == all_tables.sort
      all_tables.each do |name|
        part = native[:parts].fetch(name)
        fail!("#{name} parent P grid/part identity differs") unless
          part[:name] == 'all_1_1_0' && part[:type] == 'Wide' && part[:rows] == '8' && part[:marks] == '5'
        profile, origin = @table_identity.fetch(name)
        if origin == 'library'
          data_path = validate_store_path!(@data_paths.fetch(name))
          expected_active_path = File.expand_path(File.join(data_path, 'all_1_1_0'))
          active_path = validate_source_part!(part[:path])
          fail!("#{name} active part path differs from its target data_path/all_1_1_0") unless active_path == expected_active_path
          active_snapshot = snapshot_part(active_path)
          published_snapshot = @library_snapshots.fetch(profile)
          @attached_library_snapshots[profile] = {path: active_path, files: active_snapshot}
          assert_published_snapshot!(active_path, active_snapshot, published_snapshot, "#{profile}/library")
        end
        assert_native_values!(native, name)
      end
      fail!('attached zero-window boundary roster differs') unless native[:zero_events] == zero_events(all_tables)
    end

    def assert_published_snapshot!(active_path, active_snapshot, published_snapshot, label)
      sidecar_name = 'invalidated_system_columns.txt'
      fail!("#{label} generated part unexpectedly contains stock ATTACH metadata") if published_snapshot.key?(sidecar_name)
      sidecar = active_snapshot[sidecar_name]
      if sidecar
        fail!("#{label} ATTACH metadata is not a bounded plain file") unless sidecar[:type] == 'file' && sidecar[:size] <= 128
        contents = File.binread(File.join(active_path, sidecar_name))
        accepted = ["_block_number\n_block_offset\n", "_block_offset\n_block_number\n"]
        fail!("#{label} ATTACH metadata contents differ") unless accepted.include?(contents)
      end
      unless same_published_snapshot?(active_snapshot, published_snapshot)
        fail!("#{label} attached active tree differs from the exact published library part")
      end
    end

    def same_published_snapshot?(active_snapshot, published_snapshot)
      sidecar_name = 'invalidated_system_columns.txt'
      return false if published_snapshot.key?(sidecar_name)
      active_snapshot.reject { |relative, _entry| relative == sidecar_name } == published_snapshot
    end

    def zero_events(tables)
      tables.flat_map do |name|
        profile = @table_identity.fetch(name)[0]
        [["__W205_ZERO_BEGIN__", name, profile, 'values'], ["__W205_ZERO_END__", name, profile, 'values']]
      end
    end

    def assert_native_values!(native, name)
      expected_indexes = {
        'FULL' => (0...8).to_a, 'FIRST' => (0...2).to_a, 'LATER' => (2...4).to_a,
        'MIDDLE' => (4...6).to_a, 'FINAL' => (6...8).to_a, 'ZERO' => [],
      }
      expected_indexes.each do |window, indexes|
        actual = native[:value_rows].fetch([name, window], [])
        expected = indexes.map { |index| [(index + 1).to_s, [], '0', TYPE] }
        decoded = actual.map do |fields|
          fail!("#{name}/#{window} payload JSON hex malformed") unless fields[1].match?(/\A(?:[0-9A-Fa-f]{2})*\z/)
          [fields[0], JSON.parse([fields[1]].pack('H*')), fields[2], fields[3]]
        end
        fail!("#{name}/#{window} exact rows/value/layout differ: #{decoded.inspect}") unless decoded == expected
      end
      expected_keys = expected_indexes.keys.reject { |window| window == 'ZERO' }.map { |window| [name, window] }.sort
      fail!("#{name} selected window roster differs") unless native[:value_rows].keys.select { |key| key[0] == name }.sort == expected_keys
    rescue JSON::ParserError => error
      fail!("#{name} selected payload is not JSON: #{error.message}")
    end

    def build_helper_input
      capture_root = File.realpath(File.join(@root, 'stores', 'native'))
      profiles = PROFILE_IDS.map do |profile|
        {'case_id' => CASE_ID, 'profile_id' => profile, 'capture_root' => capture_root,
         'source_part' => @source_parts.fetch(profile),
         'library_part' => File.join(@root, 'generated', profile, CASE_ID, 'all_1_1_0')}
      end
      {'format' => FORMAT_INPUT, 'capture_root' => capture_root, 'cases' => profiles}
    end

    def run_helper(input_path)
      before = helper_sha
      fail!('prebuilt helper changed before invocation') unless before == @helper_sha_before
      argv = [@helper, input_path, File.join(@root, 'generated')]
      invocation = @executor.send(:execute_record, 'crystal_helper', argv, ''.b,
                                  'prebuilt Crystal helper', before, @helper)
      fail!('prebuilt helper failed; not a native format rejection') unless successful?(invocation)
      fail!('prebuilt helper emitted stderr') unless invocation[:stderr].empty?
      fail!('prebuilt helper SHA changed during invocation') unless helper_sha == before
      lines = invocation[:stdout].lines.map(&:chomp).reject(&:empty?)
      fail!('prebuilt helper must emit exactly one JSON record') unless lines.size == 1
      data = JSON.parse(lines.first)
      fail!('helper output format differs') unless data['format'] == FORMAT_OUTPUT
      @invocations << invocation[:record]
      {data: data, record: invocation[:record]}
    end

    def assert_helper_output!(data)
      fail!('helper output keys/format differ') unless
        data.keys.sort == %w[case_id cases format profile_ids] && data['format'] == FORMAT_OUTPUT && data['case_id'] == CASE_ID
      fail!('helper profile roster/order differs') unless data['profile_ids'] == PROFILE_IDS
      fail!('helper result profile count differs') unless data['cases'].is_a?(Array) && data['cases'].size == PROFILE_IDS.size
      data['cases'].each_with_index do |result, index|
        profile = PROFILE_IDS.fetch(index)
        expected_keys = %w[case_id library_part_path library_prepared_actual_roster library_reader library_table_rows profile_id schema_declaration stock_reader stock_table_rows]
        fail!("helper #{profile} result fields/identity differ") unless
          result.keys.sort == expected_keys && result['case_id'] == CASE_ID && result['profile_id'] == profile &&
          result['schema_declaration'] == TYPE && result['library_prepared_actual_roster'] == ['UInt64']
        part_path = File.join(@root, 'generated', profile, CASE_ID, 'all_1_1_0')
        fail!("helper #{profile} library path escaped fixed output") unless File.expand_path(result['library_part_path']) == part_path
        fail!("helper #{profile} generated part absent/noncanonical") unless
          File.directory?(part_path) && !File.symlink?(part_path) && File.realpath(part_path) == part_path
        send(:validate_plain_tree!, part_path)
        @library_parts[profile] = part_path
        @library_snapshots[profile] = snapshot_part(part_path)
        expected_rows = ProbeRecursiveDynamicJSONW205.values
        %w[stock_table_rows library_table_rows].each do |field|
          fail!("#{profile}/#{field} differs from independent empty-array/key literals") unless result[field] == expected_rows
        end
        assert_reader!(result.fetch('stock_reader'), profile, 'source')
        assert_reader!(result.fetch('library_reader'), profile, 'library')
        source_streams = ProbeRecursiveDynamicJSONW205.expected_streams('source', profile)
        library_streams = ProbeRecursiveDynamicJSONW205.expected_streams('library', profile)
        fail!("#{profile} source roster was normalized to library roster") if source_streams == library_streams
        assert_roster_files!(profile, 'source', @source_parts.fetch(profile), result.fetch('stock_reader'), source_streams)
        assert_roster_files!(profile, 'library', part_path, result.fetch('library_reader'), library_streams)
        fail!("#{profile} source Dynamic manifest observation differs from literal") unless
          @source_manifest_observations.fetch(profile) == source_streams
      end
      assert_profile_delta!(data)
    end

    def expected_reader_windows
      marks = ProbeRecursiveDynamicJSONW205.marks
      {'full' => marks, 'first' => marks[0, 1], 'later' => marks[1, 1],
       'middle' => marks[2, 1], 'final' => marks[3, 1], 'end_zero' => []}
    end

    def assert_reader!(reader, profile, origin)
      expected_keys = %w[schema_declaration source_declaration row_count mark_row_counts dynamic_site_keys physical_stream_names selected_checksum_names occurrence_counts_by_parent_mark dynamic_site_occurrences_by_parent_mark windows]
      fail!("#{profile}/#{origin} reader metadata fields differ") unless reader.keys.sort == expected_keys.sort
      fail!("#{profile}/#{origin} declaration/P grid differs") unless
        reader['schema_declaration'] == TYPE && reader['source_declaration'] == TYPE &&
        reader['row_count'] == 8 && reader['mark_row_counts'] == [2, 2, 2, 2]
      fail!("#{profile}/#{origin} Dynamic structural site roster differs") unless reader['dynamic_site_keys'] == [DYNAMIC_SITE]
      fail!("#{profile}/#{origin} all-zero occurrence grid differs") unless
        reader['occurrence_counts_by_parent_mark'] == Array.new(4) {{'object' => 0, 'dynamic' => 0}} &&
        reader['dynamic_site_occurrences_by_parent_mark'] == Array.new(4) {{"#{DYNAMIC_SITE}::root" => 0}}
      fail!("#{profile}/#{origin} full/middle/final/end-zero windows differ") unless reader['windows'] == expected_reader_windows
      expected = ProbeRecursiveDynamicJSONW205.expected_streams(origin, profile)
      streams = reader['physical_stream_names']
      fail!("#{profile}/#{origin} exact physical stream literal differs") unless streams.is_a?(Array) && streams.sort == expected
      checksums = reader['selected_checksum_names']
      fail!("#{profile}/#{origin} checksum file roster is empty/duplicated") unless checksums.is_a?(Array) && checksums.uniq == checksums
    end

    def assert_roster_files!(profile, origin, part_path, reader, expected_streams)
      manifest_names = parse_manifest(part_path, "#{origin}/#{profile}")
      fail!("#{profile}/#{origin} columns_substreams differs from independent literal") unless manifest_names == expected_streams
      fail!("#{profile}/#{origin} reader names differ from manifest literal") unless reader['physical_stream_names'].sort == expected_streams
      file_entries = Dir.children(part_path)
      stream_files = file_entries.select { |name| name.end_with?('.bin') || name.end_with?('.mrk2') }
      fail!("#{profile}/#{origin} malformed hashed stream filename") unless stream_files.all? { |name| /\A[0-9a-f]{32}\.(?:bin|mrk2)\z/.match?(name) }
      expected_count = (expected_streams.size + 1) * 2 # payload roster plus fixed pk stream
      fail!("#{profile}/#{origin} payload+pk file count differs from manifest") unless stream_files.size == expected_count
      selected = reader['selected_checksum_names']
      fail!("#{profile}/#{origin} selected checksum names do not resolve to payload files") unless
        selected.size == expected_streams.size * 2 && selected.all? { |name| stream_files.include?(name) }
      residual = stream_files - selected
      fail!("#{profile}/#{origin} selected checksum roster does not leave exactly the pk pair") unless residual.size == 2
      stems = selected.map { |name| name.sub(/\.(?:bin|mrk2)\z/, '') }
      fail!("#{profile}/#{origin} selected checksum basenames lack exact .bin/.mrk2 pairs") unless
        stems.uniq.size == expected_streams.size && stems.size == expected_streams.size * 2
      @roster_evidence[[profile, origin]] = {
        literal_physical_stream_names: expected_streams,
        observed_columns_substreams: manifest_names,
        selected_checksum_names: selected.sort,
        residual_primary_key_files: residual.sort,
      }
    end

    def parse_manifest(part_path, label)
      @w204_parser ||= W204::Probe.allocate
      @w204_parser.send(:parse_substreams, part_path, label)
    end

    def assert_profile_delta!(data)
      data['cases'].each do |result|
        profile = result['profile_id']
        %w[source library].each do |origin|
          reader = result.fetch(origin == 'source' ? 'stock_reader' : 'library_reader')
          streams = reader.fetch('physical_stream_names').sort
          expected = ProbeRecursiveDynamicJSONW205.expected_streams(origin, profile)
          fail!("#{profile}/#{origin} stream names differ from per-origin literal") unless streams == expected
        end
      end
      %w[source library].each do |origin|
        small = ProbeRecursiveDynamicJSONW205.expected_streams(origin, 'single_stream')
        sized = ProbeRecursiveDynamicJSONW205.expected_streams(origin, 'with_size_stream')
        fail!("#{origin} String profile delta differs from literal size lane") unless
          (sized - small) == ['payload%2Ed.SharedVariant.size'] && (small - sized).empty?
      end
    end

    def attach_library_parts!
      PROFILE_IDS.each do |profile|
        target = table(profile, 'library')
        path = @library_parts.fetch(profile)
        @executor.send(:attach_part!, path, validate_store_path!(@data_paths.fetch(target)))
      end
    end

    def build_summary(data)
      {
        probe: 'W205 whole-part all-zero-Q recursive Array/Tuple compatibility',
        status: data[:status], fatal_error: data[:fatal_error],
        source_archive: {path: '/Users/sergey/SrcArchives/clickhouse-2026-10-05-depth1-ef037e60',
                         audited_commit: SOURCE_ARCHIVE_COMMIT,
                         disclaimer: 'read-only source archive; not the native runtime'},
        runtime: {path: @binary, expected_sha256: BINARY_SHA256,
                  sha256_before: @binary_sha_before, sha256_after: @binary_sha_after,
                  expected_version: VERSION, expected_build: BUILD},
        helper: {path: @helper, sha256_before: @helper_sha_before, sha256_after: @helper_sha_after},
        limits: {max_threads: 1, local_max_memory_usage_bytes: MEMORY,
                 required_outer_run_safe_memory_limit_bytes: OUTER_RUN_SAFE_LIMIT,
                 timeout_seconds: TIMEOUT, termination_grace_seconds: GRACE},
        schema: TYPE, P_rows: [2, 2, 2, 2], Q_rows: [0, 0, 0, 0],
        profiles: PROFILE_IDS, evidence_root: @root, helper_input: @helper_input,
        source_manifest_observations: @source_manifest_observations,
        source_part_snapshots: @source_snapshots, library_part_snapshots: @library_snapshots,
        attached_library_part_snapshots: @attached_library_snapshots,
        roster_evidence: @roster_evidence, invocations: @invocations,
      }.merge(data.reject { |key, _| %i[status fatal_error].include?(key) })
    end

    def write_evidence(data)
      summary = build_summary(data)
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      write_new(File.join(@root, 'summary.md'), [
        '# W205 whole-part zero-Q recursive Array/Tuple probe', '',
        "Status: `#{summary[:status]}`", '',
        'Scope: two String profiles; parent P=8 rows across four two-row marks; every outer Array child schedule has Q=0. The stock source roster and explicit library UInt64 roster are independent literals. Selected-value reads, checksums and exact physical substream manifests supplement CHECK; no JSON actual is stored in Dynamic.', '',
        "Source archive commit: `#{SOURCE_ARCHIVE_COMMIT}` (not runtime).",
        "Runtime: #{VERSION} / #{BUILD} / SHA256 `#{BINARY_SHA256}`.",
        "Evidence root: `#{@root}`", '',
      ].join("\n"))
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    if ARGV == ['--self-test']
      raise 'W205 profile roster changed' unless ProbeRecursiveDynamicJSONW205::PROFILE_IDS == %w[single_stream with_size_stream]
      raise 'W205 parent fixture changed' unless ProbeRecursiveDynamicJSONW205.values == (1..8).map { |key| [key.to_s, []] }
      raise 'W205 stock/library rosters must remain distinct' if
        ProbeRecursiveDynamicJSONW205.expected_streams('source', 'single_stream') ==
        ProbeRecursiveDynamicJSONW205.expected_streams('library', 'single_stream')
      %w[source library].each do |origin|
        one = ProbeRecursiveDynamicJSONW205.expected_streams(origin, 'single_stream')
        sized = ProbeRecursiveDynamicJSONW205.expected_streams(origin, 'with_size_stream')
        raise "W205 #{origin} profile size delta changed" unless sized - one == ['payload%2Ed.SharedVariant.size'] && (one - sized).empty?
      end
      [['origin', -> { ProbeRecursiveDynamicJSONW205.expected_streams('unknown', 'single_stream') }],
       ['profile', -> { ProbeRecursiveDynamicJSONW205.expected_streams('source', 'unknown') }]].each do |label, operation|
        rejected = false
        begin
          operation.call
        rescue ArgumentError
          rejected = true
        end
        raise "W205 malformed #{label} was accepted by stream oracle" unless rejected
      end
      probe = ProbeRecursiveDynamicJSONW205::Probe.allocate
      published = {
        'columns_substreams.txt' => {type: 'file', size: 42, sha256: 'manifest'},
        'payload%2Ed.dynamic_structure.bin' => {type: 'file', size: 8, sha256: 'structure'},
      }
      attached = published.merge('invalidated_system_columns.txt' => {type: 'file', size: 31, sha256: 'sidecar'})
      raise 'W205 optional ATTACH sidecar changed exact published-tree comparison' unless
        probe.send(:same_published_snapshot?, attached, published)
      raise 'W205 seeded dropped Dynamic structure stream was accepted' if
        probe.send(:same_published_snapshot?, attached.reject { |name, _| name == 'payload%2Ed.dynamic_structure.bin' }, published)
      raise 'W205 seeded dropped substream roster was accepted' if
        probe.send(:same_published_snapshot?, attached.reject { |name, _| name == 'columns_substreams.txt' }, published)
      puts 'W205 Ruby fixture/oracle self-test passed'
      exit 0
    end
    options = {binary: ProbeRecursiveDynamicJSONW205::BINARY, helper: nil, root: nil}
    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby scripts/probe_recursive_dynamic_json_w205.rb --crystal-helper PREBUILT --evidence-root EMPTY_/private/tmp_CHILD [--clickhouse PINNED]'
      parser.on('--clickhouse PATH', 'Pinned ClickHouse 26.10.1.1201 executable') { |value| options[:binary] = value }
      parser.on('--crystal-helper PATH', 'Prebuilt Crystal helper; this runner never compiles it') { |value| options[:helper] = value }
      parser.on('--evidence-root PATH', 'Existing empty direct child of /private/tmp') { |value| options[:root] = value }
    end.parse!
    abort 'W205: --crystal-helper and --evidence-root are required' unless options[:helper] && options[:root]
    exit(ProbeRecursiveDynamicJSONW205::Probe.new(options[:binary], options[:helper], options[:root]).run ? 0 : 1)
  rescue StandardError => error
    warn "W205 runner error: #{error.class}: #{error.message}"
    exit 1
  end
end
