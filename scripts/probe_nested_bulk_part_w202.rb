#!/usr/bin/env ruby
# Bounded, root-run stock/library ATTACH qualification for the public nominal
# Nested complete-part API. This runner uses only supplied pinned executables;
# it neither builds ClickHouse nor compiles the Crystal helper.

require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'optparse'
require_relative 'check_array_json_parts_w185'

module ProbeNestedBulkPartW202
  W185 = CheckArrayJSONPartsW185
  W180 = JsonBinaryKernelW180Probe
  BINARY = W185::BINARY
  BINARY_SHA256 = W185::BINARY_SHA256
  VERSION = '26.10.1.1201'.freeze
  BUILD = 'd9bcb5ab007f0f6299f7f973f2642245bab3d028'.freeze
  MEMORY = W185::MEMORY
  TIMEOUT = W185::TIMEOUT
  GRACE = W185::GRACE
  OUTER_RUN_SAFE_LIMIT = W185::OUTER_RUN_SAFE_LIMIT

  FORMAT_INPUT = 'nested_bulk_part_w202_input_v1'.freeze
  FORMAT_OUTPUT = 'nested_bulk_part_w202_helper_v1'.freeze
  PROFILE_IDS = %w[single_stream with_size_stream].freeze
  TYPE = 'Nested(label LowCardinality(Nullable(String)), choice Variant(String, UInt64), text String)'.freeze
  ROWBINARY_TYPE = TYPE.freeze
  VARIANT_TYPE = 'Array(Variant(String, UInt64))'.freeze
  TABLES = PROFILE_IDS.to_h { |profile| [profile, ["source_#{profile}", "library_#{profile}"]] }.freeze

  # Independently-authored native/RowBinary literals. Kept separate from the
  # Crystal helper's fixture so neither path takes expected values from the
  # other's readback.
  ROWS = [
    {pk: 1, records: []},
    {pk: 2, records: []},
    {pk: 3, records: [
      {label: nil, choice: [:string, 'after-empty'], text: 'after-empty'},
      {label: 'x', choice: [:uint64, 701], text: 'num-first'},
    ]},
    {pk: 4, records: [
      {label: 'x', choice: [:string, 'repeat'], text: 'repeat'},
      {label: '', choice: [:null, nil], text: ''},
    ]},
    {pk: 5, records: [
      {label: '', choice: [:uint64, 0], text: 'default-label'},
      {label: nil, choice: [:uint64, 42], text: 'null-label'},
    ]},
    {pk: 6, records: []},
    {pk: 7, records: [
      {label: 'novel', choice: [:string, 'last'], text: 'final'},
      {label: 'x', choice: [:uint64, 999], text: 'final-num'},
    ]},
    {pk: 8, records: [
      {label: 'x', choice: [:null, nil], text: 'tail'},
      {label: 'novel', choice: [:string, 'repeat'], text: 'repeat'},
    ]},
  ].freeze

  SETTINGS = [
    'index_granularity=2', 'index_granularity_bytes=10485760',
    'enable_mixed_granularity_parts=1', 'min_rows_for_wide_part=0',
    'min_bytes_for_wide_part=0', 'compress_marks=0', 'compress_primary_key=0',
    'min_compress_block_size=0', 'max_compress_block_size=4096',
    "default_compression_codec='LZ4'", "serialization_info_version='with_types'",
    'propagate_types_serialization_versions_to_nested_types=1',
    'use_compact_variant_discriminators_serialization=0',
  ].join(', ').freeze

  class Probe
    def initialize(binary, crystal_helper, evidence_root)
      @binary = validate_executable(binary, 'ClickHouse')
      @helper = validate_executable(crystal_helper, 'prebuilt Crystal helper')
      @root = validate_root(evidence_root)
      @executor = W185::Probe.new(@binary, @helper, @root)
      @invocations = []
      @source_parts = {}
      @source_snapshots = {}
      @library_parts = {}
      @library_snapshots = {}
      @data_paths = {}
      @fatal_error = nil
    end

    def run
      prepare_layout!
      @binary_sha_before = binary_sha
      fail!('pinned ClickHouse executable SHA-256 mismatch before probe') unless @binary_sha_before == BINARY_SHA256
      @helper_sha_before = helper_sha
      fail!('Crystal helper SHA changed before probe') unless @helper_sha_before == helper_sha

      PROFILE_IDS.each do |profile|
        write_new(File.join(@root, 'inputs', "#{profile}.rowbinary"), rowbinary)
        Dir.mkdir(File.join(@root, 'generated', profile), 0o700)
      end

      initial = run_clickhouse('native_sources', initial_sql)
      assert_native_invocation!(initial)
      native = parse_native(initial[:stdout])
      assert_pin!(native)
      assert_initial_native!(native)

      helper_input = build_helper_input(native)
      input_path = File.join(@root, 'generated', 'helper-input.json')
      write_new(input_path, JSON.pretty_generate(helper_input) + "\n")
      helper = run_helper(input_path)
      assert_helper_output!(helper[:data])
      attach_library_parts!

      attached = run_clickhouse('attach_and_check', attached_sql)
      assert_native_invocation!(attached)
      attached_native = parse_native(attached[:stdout])
      assert_pin!(attached_native)
      assert_attached_native!(attached_native)

      @source_parts.each do |table, path|
        fail!("stock source part changed during ATTACH/SELECT: #{table}") unless snapshot_part(path) == @source_snapshots.fetch(table)
      end
      @library_parts.each do |profile, path|
        fail!("published library part changed during ATTACH/SELECT: #{profile}") unless snapshot_part(path) == @library_snapshots.fetch(profile)
      end
      @binary_sha_after = binary_sha
      @helper_sha_after = helper_sha
      fail!('pinned ClickHouse executable SHA changed during probe') unless @binary_sha_after == BINARY_SHA256
      fail!('prebuilt Crystal helper SHA changed during probe') unless @helper_sha_after == @helper_sha_before

      write_summary(
        status: 'paired_nested_bulk_part_observed', source: native,
        helper: helper[:data], helper_invocation: helper[:record],
        initial_invocation: initial[:record], attached: attached_native,
        attached_invocation: attached[:record], source_part_snapshots: @source_snapshots,
        library_part_snapshots: @library_snapshots,
      )
      puts "W202 paired Nested complete parts profiles=#{PROFILE_IDS.size}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @binary_sha_after = binary_sha rescue nil
      @helper_sha_after = helper_sha rescue nil
      write_summary(status: 'runner_failure_or_observations_differ', fatal_error: @fatal_error) rescue nil
      warn "W202 probe failure (process failure is not format evidence): #{@fatal_error}"
      false
    end

    private

    def validate_root(path)
      fail!('evidence root is required') unless path && !path.empty?
      expanded = File.expand_path(path)
      fail!('evidence root must be a direct child of /private/tmp') unless File.dirname(expanded) == File.realpath('/private/tmp')
      fail!('evidence root must be an existing empty non-symlink directory') unless
        File.directory?(expanded) && !File.symlink?(expanded) && File.realpath(expanded) == expanded && Dir.children(expanded).empty?
      expanded
    rescue Errno::ENOENT
      fail!('evidence root must already exist')
    end

    def validate_executable(path, label)
      fail!("#{label} path is required") unless path && !path.empty?
      full = File.expand_path(path)
      fail!("#{label} is missing, non-executable, or symlinked") unless
        File.file?(full) && File.executable?(full) && !File.symlink?(full)
      full
    end

    def prepare_layout!
      %w[invocations inputs stores generated].each { |name| Dir.mkdir(File.join(@root, name), 0o700) }
      Dir.mkdir(File.join(@root, 'stores', 'native'), 0o700)
    end

    def binary_sha
      Digest::SHA256.file(@binary).hexdigest
    end

    def helper_sha
      Digest::SHA256.file(@helper).hexdigest
    end

    def table(profile, origin)
      "#{origin}_#{profile}"
    end

    def initial_sql
      statements = [
        'SET flatten_nested=0;',
        'SET allow_suspicious_low_cardinality_types=1;',
        "SELECT '__W202_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
      ]
      PROFILE_IDS.each do |profile|
        string_profile = profile
        settings = "#{SETTINGS}, string_serialization_version='#{string_profile}'"
        [table(profile, 'source'), table(profile, 'library')].each do |name|
          statements << "CREATE TABLE default.#{name} (pk UInt64, payload #{TYPE}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings};"
        end
        input_path = File.join(@root, 'inputs', "#{profile}.rowbinary").gsub("'", "\\'")
        statements << "INSERT INTO default.#{table(profile, 'source')} SELECT * FROM file('#{input_path}', 'RowBinary', 'pk UInt64, payload #{ROWBINARY_TYPE}') SETTINGS flatten_nested=0, allow_suspicious_low_cardinality_types=1;"
        statements << check_sql(table(profile, 'source'), profile)
      end
      names = all_tables.map { |name| "'#{name}'" }.join(',')
      statements << "SELECT '__W202_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{names}) ORDER BY table, position FORMAT TSVRaw;"
      statements << "SELECT '__W202_DATA_PATH__', name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name IN (#{names}) ORDER BY name FORMAT TSVRaw;"
      statements << parts_sql(source_tables)
      PROFILE_IDS.each { |profile| statements.concat(value_queries(table(profile, 'source'), profile)) }
      statements.join("\n") + "\n"
    end

    def attached_sql
      statements = [
        'SET flatten_nested=0;',
        'SET allow_suspicious_low_cardinality_types=1;',
        "SELECT '__W202_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
      ]
      PROFILE_IDS.each do |profile|
        target = table(profile, 'library')
        statements << "ALTER TABLE default.#{target} ATTACH PART 'all_1_1_0';"
        statements << check_sql(table(profile, 'source'), profile)
        statements << check_sql(target, profile)
      end
      names = all_tables.map { |name| "'#{name}'" }.join(',')
      statements << "SELECT '__W202_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{names}) ORDER BY table, position FORMAT TSVRaw;"
      statements << parts_sql(all_tables)
      all_tables.each do |name|
        profile = PROFILE_IDS.find { |candidate| TABLES.fetch(candidate).include?(name) }
        statements.concat(value_queries(name, profile))
      end
      statements.join("\n") + "\n"
    end

    def all_tables
      PROFILE_IDS.flat_map { |profile| [table(profile, 'source'), table(profile, 'library')] }
    end

    def source_tables
      PROFILE_IDS.map { |profile| table(profile, 'source') }
    end

    def check_sql(table_name, profile)
      [
        "SELECT '__W202_CHECK_BEGIN__', '#{table_name}', '#{profile}' FORMAT TSVRaw;",
        "CHECK TABLE default.#{table_name} FORMAT TSV;",
        "SELECT '__W202_CHECK_END__', '#{table_name}', '#{profile}' FORMAT TSVRaw;",
      ].join("\n")
    end

    def parts_sql(tables)
      names = tables.map { |name| "'#{name}'" }.join(',')
      "SELECT '__W202_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table IN (#{names}) AND active ORDER BY table,name FORMAT TSVRaw;"
    end

    def value_queries(table_name, profile)
      windows = {
        'FULL' => '',
        'FIRST_EMPTY' => ' WHERE pk BETWEEN 1 AND 2',
        'LATER' => ' WHERE pk BETWEEN 3 AND 4',
        'FINAL' => ' WHERE pk BETWEEN 7 AND 8',
        'ZERO' => ' WHERE pk > 8',
      }
      windows.flat_map do |window, predicate|
        tag = "__W202_VALUES_#{window}__"
        query = "SELECT '#{tag}', '#{table_name}', toString(pk), hex(toJSONString(payload.label)), hex(toJSONString(payload.choice)), hex(toJSONString(payload.text)), toTypeName(payload), toTypeName(payload.choice) FROM default.#{table_name}#{predicate} ORDER BY pk FORMAT TSVRaw;"
        if window == 'ZERO'
          ["SELECT '__W202_ZERO_BEGIN__', '#{table_name}', '#{profile}', 'values' FORMAT TSVRaw;", query,
           "SELECT '__W202_ZERO_END__', '#{table_name}', '#{profile}', 'values' FORMAT TSVRaw;"]
        else
          [query]
        end
      end
    end

    def run_clickhouse(label, sql)
      sql_bytes = sql.b
      write_new(File.join(@root, 'invocations', "#{label}.stdin.sql"), sql_bytes)
      argv = [@binary, 'local', '--path', File.join(@root, 'stores', 'native'), '--session_timezone=UTC',
              '--max_threads=1', "--max_memory_usage=#{MEMORY}", '--multiquery']
      before = binary_sha
      fail!('pinned ClickHouse executable SHA mismatch before native invocation') unless before == BINARY_SHA256
      invocation = @executor.send(:execute_record, label, argv, sql_bytes, 'clickhouse local', BINARY_SHA256, @binary)
      invocation[:record][:binary_sha_before] = before
      invocation[:record][:binary_sha_after] = binary_sha
      fail!('pinned ClickHouse executable SHA changed during invocation') unless invocation[:record][:binary_sha_after] == BINARY_SHA256
      @invocations << invocation[:record]
      invocation
    end

    def run_helper(input_path)
      before = helper_sha
      argv = [@helper, input_path, File.join(@root, 'generated')]
      invocation = @executor.send(:execute_record, 'crystal_helper', argv, ''.b,
                                  'prebuilt Crystal helper', before, @helper)
      fail!('Crystal helper process failed; not a native format rejection') unless successful?(invocation)
      fail!('Crystal helper emitted stderr') unless invocation[:stderr].empty?
      fail!('Crystal helper SHA changed during invocation') unless helper_sha == before
      lines = invocation[:stdout].lines.map(&:chomp).reject(&:empty?)
      fail!('Crystal helper must emit exactly one JSON record') unless lines.size == 1
      data = JSON.parse(lines.fetch(0))
      fail!('Crystal helper output format differs') unless data['format'] == FORMAT_OUTPUT
      @invocations << invocation[:record]
      {data: data, record: invocation[:record]}
    end

    def successful?(invocation)
      invocation[:classification] == 'success' && invocation[:status]&.success? && invocation[:status]&.termsig.nil?
    end

    def assert_native_invocation!(invocation)
      fail!('ClickHouse process did not exit successfully') unless successful?(invocation)
      fail!('ClickHouse stderr is not empty') unless invocation[:stderr].empty?
    end

    def assert_pin!(native)
      expected = "__W202_PIN__\t#{VERSION}\t#{BUILD}"
      fail!("runtime version/build/SHA scope differs: #{native[:pin].inspect}") unless native[:pin] == expected
    end

    def parse_native(stdout)
      lines = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      records = ->(prefix) { lines.select { |line| line.start_with?("#{prefix}\t") }.map { |line| line.split("\t", -1) } }
      known_tags = %w[
        __W202_PIN__ __W202_SCHEMA__ __W202_DATA_PATH__ __W202_PART__
        __W202_CHECK_BEGIN__ __W202_CHECK_END__ __W202_ZERO_BEGIN__ __W202_ZERO_END__
      ] + %w[FULL FIRST_EMPTY LATER FINAL ZERO].map { |window| "__W202_VALUES_#{window}__" }
      unknown_tags = lines.each_with_object([]) do |line, tags|
        next unless line.start_with?('__W202_')
        tag = line.split("\t", 2).first
        tags << tag unless known_tags.include?(tag)
      end
      fail!("unknown W202 marker tags: #{unknown_tags.uniq.inspect}") unless unknown_tags.empty?
      check_blocks = {}
      active = nil
      lines.each do |line|
        if line.start_with?("__W202_CHECK_BEGIN__\t")
          fields = line.split("\t", -1)
          fail!('CHECK begin boundary malformed or nested') unless fields.size == 3 && !active
          active = [fields[1], fields[2]]
          fail!('duplicate CHECK block') if check_blocks.key?(active)
          check_blocks[active] = []
        elsif line.start_with?("__W202_CHECK_END__\t")
          fields = line.split("\t", -1)
          fail!('CHECK end boundary malformed') unless fields.size == 3 && active == [fields[1], fields[2]]
          active = nil
        elsif active
          check_blocks[active] << line
        end
      end
      fail!('unterminated CHECK block') if active

      pin_rows = records.call('__W202_PIN__')
      fail!('runtime pin must occur exactly once') unless pin_rows.size == 1 && pin_rows.first.size == 3
      schemas = records.call('__W202_SCHEMA__').map do |fields|
        fail!('schema record has wrong width') unless fields.size == 4
        fields.drop(1)
      end
      data_path_rows = records.call('__W202_DATA_PATH__')
      fail!('duplicate data-path record') unless data_path_rows.map { |fields| fields[1] }.uniq.size == data_path_rows.size
      data_paths = data_path_rows.to_h do |fields|
        fail!('data-path record has wrong width') unless fields.size == 3
        [fields[1], fields[2]]
      end
      part_rows = records.call('__W202_PART__')
      fail!('duplicate active part record') unless part_rows.map { |fields| fields[1] }.uniq.size == part_rows.size
      parts = part_rows.to_h do |fields|
        fail!('part record has wrong width') unless fields.size == 7
        [fields[1], {name: fields[2], path: fields[3], type: fields[4], rows: fields[5], marks: fields[6]}]
      end
      value_rows = lines.select { |line| line.start_with?('__W202_VALUES_') }
                        .map { |line| line.split("\t", -1) }
                        .each_with_object({}) do |fields, output|
        fail!('value row has wrong width') unless fields.size == 8
        window = fields[0].delete_prefix('__W202_VALUES_').delete_suffix('__')
        table_name = fields[1]
        (output[[table_name, window]] ||= []) << fields.drop(2)
      end
      zero_events = lines.select { |line| line.start_with?("__W202_ZERO_BEGIN__\t") || line.start_with?("__W202_ZERO_END__\t") }
                         .map { |line| line.split("\t", -1) }
      {
        pin: lines.find { |line| line.start_with?("__W202_PIN__\t") },
        checks: check_blocks, schemas: schemas, data_paths: data_paths,
        parts: parts, value_rows: value_rows, zero_events: zero_events,
      }
    end

    def assert_initial_native!(native)
      expected_checks = source_tables.to_h do |name|
        profile = PROFILE_IDS.find { |candidate| name == table(candidate, 'source') }
        [[name, profile], ["all_1_1_0\t1\t"]]
      end
      fail!("native source CHECK result differs: #{native[:checks].inspect}") unless native[:checks] == expected_checks
      expected_schemas = all_tables.sort.flat_map { |name| [[name, 'pk', 'UInt64'], [name, 'payload', TYPE]] }
      fail!("native source/empty-target schema differs: #{native[:schemas].inspect}") unless native[:schemas] == expected_schemas
      fail!('native source data paths do not cover the exact table roster') unless native[:data_paths].keys.sort == all_tables.sort
      native[:data_paths].each_value { |path| validate_store_path!(path) }
      @data_paths = native[:data_paths].dup
      expected_zero = source_tables.flat_map do |name|
        profile = PROFILE_IDS.find { |candidate| name == table(candidate, 'source') }
        [["__W202_ZERO_BEGIN__", name, profile, 'values'], ["__W202_ZERO_END__", name, profile, 'values']]
      end
      fail!('native stock zero-window boundary roster differs') unless native[:zero_events] == expected_zero
      fail!('native stock source part roster differs') unless native[:parts].keys.sort == source_tables.sort
      expected_value_keys = source_tables.product(%w[FULL FIRST_EMPTY LATER FINAL]).sort
      fail!('native stock selected-value query roster differs') unless native[:value_rows].keys.sort == expected_value_keys
      PROFILE_IDS.each do |profile|
        name = table(profile, 'source')
        part = native[:parts].fetch(name)
        fail!("#{name} is not one eight-row Wide part with four marks plus end sentinel") unless
          part[:name] == 'all_1_1_0' && part[:type] == 'Wide' && part[:rows] == '8' && part[:marks] == '5'
        path = validate_source_part!(part[:path])
        @source_parts[name] = path
        @source_snapshots[name] = snapshot_part(path)
        assert_value_windows!(native, name)
      end
    end

    def assert_attached_native!(native)
      expected_checks = all_tables.to_h do |name|
        profile = PROFILE_IDS.find { |candidate| TABLES.fetch(candidate).include?(name) }
        [[name, profile], ["all_1_1_0\t1\t"]]
      end
      fail!("native source/attached CHECK results differ: #{native[:checks].inspect}") unless native[:checks] == expected_checks
      expected_schemas = all_tables.sort.flat_map { |name| [[name, 'pk', 'UInt64'], [name, 'payload', TYPE]] }
      fail!("attached schema roster differs: #{native[:schemas].inspect}") unless native[:schemas] == expected_schemas
      fail!('attached native part roster differs') unless native[:parts].keys.sort == all_tables.sort
      expected_value_keys = all_tables.product(%w[FULL FIRST_EMPTY LATER FINAL]).sort
      fail!('attached selected-value query roster differs') unless native[:value_rows].keys.sort == expected_value_keys
      PROFILE_IDS.each do |profile|
        source = table(profile, 'source')
        library = table(profile, 'library')
        [source, library].each do |name|
          part = native[:parts].fetch(name)
          fail!("#{name} part identity/grid differs") unless
            part[:name] == 'all_1_1_0' && part[:type] == 'Wide' && part[:rows] == '8' && part[:marks] == '5'
          assert_value_windows!(native, name)
        end
      end
      expected_zero = all_tables.flat_map do |name|
        profile = PROFILE_IDS.find { |candidate| TABLES.fetch(candidate).include?(name) }
        [["__W202_ZERO_BEGIN__", name, profile, 'values'], ["__W202_ZERO_END__", name, profile, 'values']]
      end
      fail!('native zero-window boundary roster differs') unless native[:zero_events] == expected_zero
    end

    def assert_value_windows!(native, table_name)
      wanted = {
        'FULL' => ROWS,
        'FIRST_EMPTY' => ROWS[0, 2],
        'LATER' => ROWS[2, 2],
        'FINAL' => ROWS[6, 2],
        'ZERO' => [],
      }
      wanted.each do |window, rows|
        actual = native[:value_rows].fetch([table_name, window], [])
        expected = rows.map do |row|
          labels = row[:records].map { |record| record[:label] }
          choices = row[:records].map do |record|
            kind, value = record[:choice]
            kind == :null ? nil : value
          end
          texts = row[:records].map { |record| record[:text] }
          [row[:pk].to_s, labels, choices, texts, TYPE, VARIANT_TYPE]
        end
        decoded = actual.map do |fields|
          [fields[0], json_hex(fields[1]), json_hex(fields[2]), json_hex(fields[3]), fields[4], fields[5]]
        end
        fail!("#{table_name} #{window} selected-value rows differ from independent literals: #{decoded.inspect}") unless decoded == expected
      end
    end

    def json_hex(hex)
      fail!('SELECT returned malformed JSON hex') unless hex.match?(/\A(?:[0-9A-Fa-f]{2})*\z/)
      JSON.parse([hex].pack('H*'))
    rescue JSON::ParserError => error
      fail!("SELECT JSON hex did not decode: #{error.message}")
    end

    def assert_helper_output!(data)
      fail!('Crystal helper output keys or format differ') unless data.keys.sort == %w[format profile_ids profiles] && data['format'] == FORMAT_OUTPUT
      fail!('Crystal helper profile roster/order differs') unless data['profile_ids'] == PROFILE_IDS
      fail!('Crystal helper did not report both source and library consumers') unless data['profiles'].is_a?(Array) && data['profiles'].size == PROFILE_IDS.size
      data['profiles'].each_with_index do |profile_data, index|
        profile = PROFILE_IDS.fetch(index)
        fail!("helper profile #{profile} key/identity differs") unless
          profile_data.keys.sort == %w[library library_part_path profile_id source] && profile_data['profile_id'] == profile
        %w[source library].each do |origin|
          side = profile_data.fetch(origin)
          fail!("helper #{profile}/#{origin} metadata or windows differs") unless
            side.keys.sort == %w[logical_stream_roles mark_count mark_row_counts ordinary_profile physical_stream_names row_count schema_declaration windows] &&
            side['schema_declaration'] == TYPE && side['row_count'] == 8 && side['mark_count'] == 4 &&
            side['mark_row_counts'] == [2, 2, 2, 2] && side['ordinary_profile'] == profile &&
            side['windows'] == %w[full first_empty_mark later_populated_mark final_populated_mark zero_end_window]
        streams = side['physical_stream_names']
        fail!("helper #{profile}/#{origin} physical basename roster is empty/duplicated") unless
          streams.is_a?(Array) && !streams.empty? && streams.uniq == streams
        roles = side['logical_stream_roles']
        fail!("helper #{profile}/#{origin} logical role roster is empty/duplicated") unless
          roles.is_a?(Array) && !roles.empty? && roles.uniq == roles
        size_roles = roles.count { |name| name.end_with?('.string_sizes') }
        expected_size_roles = profile == 'single_stream' ? 0 : 2
        fail!("helper #{profile}/#{origin} String profile discriminator differs") unless size_roles == expected_size_roles
        physical_size_lanes = streams.count { |name| name.end_with?('.size') }
        fail!("helper #{profile}/#{origin} physical String-size lane roster differs") unless physical_size_lanes == expected_size_roles
      end
        expected_path = File.join(@root, 'generated', profile, 'all_1_1_0')
        fail!("helper #{profile} library path escaped its fixed output") unless File.expand_path(profile_data['library_part_path']) == expected_path
        @library_parts[profile] = expected_path
        @library_snapshots[profile] = snapshot_part(expected_path)
      end
    end

    def build_helper_input(native)
      capture_root = File.realpath(File.join(@root, 'stores', 'native'))
      profiles = PROFILE_IDS.map do |profile|
        source = table(profile, 'source')
        {
          'profile_id' => profile,
          'capture_root' => capture_root,
          'source_part' => @source_parts.fetch(source),
          'library_part' => File.join(@root, 'generated', profile, 'all_1_1_0'),
        }
      end
      {'format' => FORMAT_INPUT, 'capture_root' => capture_root, 'profiles' => profiles}
    end

    def attach_library_parts!
      PROFILE_IDS.each do |profile|
        library = table(profile, 'library')
        path = @library_parts.fetch(profile)
        validate_generated_part!(path, profile)
        @executor.send(:attach_part!, path, validate_store_path!(@data_paths.fetch(library)))
      end
    end

    def validate_store_path!(path)
      fail!('native table data path is absent') unless path && !path.empty?
      full = File.expand_path(path)
      store = File.join(@root, 'stores', 'native')
      fail!("native table path escaped evidence store: #{path}") unless full.start_with?(store + File::SEPARATOR)
      ensure_plain_chain!(full)
      full
    end

    def validate_source_part!(path)
      full = File.expand_path(path)
      store = File.join(@root, 'stores', 'native')
      fail!('stock part path escaped native store') unless full.start_with?(store + File::SEPARATOR)
      fail!('stock source part is absent, symlinked, or noncanonical') unless
        File.directory?(full) && !File.symlink?(full) && File.realpath(full) == full
      validate_plain_tree!(full)
      full
    end

    def validate_generated_part!(path, profile)
      expected = File.join(@root, 'generated', profile, 'all_1_1_0')
      fail!("generated library part path differs for #{profile}") unless File.expand_path(path) == expected
      fail!("generated library part absent for #{profile}") unless File.directory?(expected) && !File.symlink?(expected)
      validate_plain_tree!(expected)
      expected
    end

    def ensure_plain_chain!(path)
      current = File::SEPARATOR
      File.expand_path(path).delete_prefix(File::SEPARATOR).split(File::SEPARATOR).each do |component|
        current = File.join(current, component)
        next unless File.exist?(current) || File.symlink?(current)
        fail!("symlink in native path: #{current}") if File.lstat(current).symlink?
        fail!("non-directory native path component: #{current}") unless File.directory?(current)
      end
    end

    def validate_plain_tree!(path)
      Find.find(path) do |entry|
        stat = File.lstat(entry)
        fail!("symlink in part tree: #{entry}") if stat.symlink?
        fail!("non-regular part tree entry: #{entry}") unless stat.directory? || stat.file?
      end
      true
    end

    def snapshot_part(path)
      validate_plain_tree!(path)
      Find.find(path).sort.each_with_object({}) do |entry, output|
        next if entry == path
        relative = entry.delete_prefix(path + File::SEPARATOR)
        stat = File.lstat(entry)
        output[relative] = if stat.directory?
                             {type: 'directory'}
                           else
                             {type: 'file', size: stat.size, sha256: Digest::SHA256.file(entry).hexdigest}
                           end
      end
    end

    def rowbinary
      ROWS.map do |row|
        body = varuint(row[:records].size) + row[:records].map { |record| rowbinary_record(record) }.join.b
        [row[:pk]].pack('Q<') + body
      end.join.b
    end

    def rowbinary_record(record)
      label = record[:label].nil? ? "\x01".b : "\x00".b + wire_string(record[:label])
      kind, value = record[:choice]
      variant = case kind
                when :string then "\x00".b + wire_string(value)
                when :uint64 then "\x01".b + [value].pack('Q<')
                when :null then "\xff".b
                else fail!("unknown literal Variant arm #{kind.inspect}")
                end
      label + variant + wire_string(record[:text])
    end

    def varuint(value)
      result = +''.b
      loop do
        byte = value & 0x7f
        value >>= 7
        byte |= 0x80 unless value.zero?
        result << byte
        break if value.zero?
      end
      result
    end

    def wire_string(value)
      bytes = value.b
      varuint(bytes.bytesize) + bytes
    end

    def write_summary(data)
      summary = {
        probe: 'W202 paired public nominal Nested complete-part qualification',
        status: data[:status], fatal_error: data[:fatal_error],
        runtime: {path: @binary, expected_sha256: BINARY_SHA256,
                  sha256_before: @binary_sha_before, sha256_after: @binary_sha_after,
                  expected_version: VERSION, expected_build: BUILD},
        helper: {path: @helper, sha256_before: @helper_sha_before, sha256_after: @helper_sha_after},
        limits: {max_threads: 1, local_max_memory_usage_bytes: MEMORY,
                 required_outer_run_safe_memory_limit_bytes: OUTER_RUN_SAFE_LIMIT,
                 timeout_seconds: TIMEOUT, termination_grace_seconds: GRACE,
                 executor: 'JsonBinaryKernelW180Probe#execute'},
        profiles: PROFILE_IDS, evidence_root: @root, invocations: @invocations,
      }.merge(data.reject { |key, _| %i[status fatal_error].include?(key) })
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      write_new(File.join(@root, 'summary.md'), [
        '# W202 paired public nominal Nested complete-part qualification', '',
        "Status: `#{summary[:status]}`", '',
        'Scope: two String profiles; top-level Nested with LowCardinality(Nullable(String)), Variant(String, UInt64), and direct String; BASIC Variant discriminator serialization only. Dynamic is explicitly outside this probe. Native CHECK is supplementary; literal selected-value reads are the semantic oracle.', '',
        "Runtime: #{VERSION} / #{BUILD} / SHA256 `#{BINARY_SHA256}`", '',
        "Evidence root: `#{@root}`", '',
      ].join("\n"))
    end

    def write_new(path, bytes)
      fail!("refusing to overwrite evidence: #{path}") if File.exist?(path) || File.symlink?(path)
      File.open(path, 'wbx', 0o600) { |file| file.write(bytes) }
    end

    def fail!(message)
      raise RuntimeError, "W202 Nested complete-part oracle: #{message}"
    end
  end

  def self.self_test!
    probe = Probe.allocate
    rows = probe.send(:rowbinary)
    raise 'W202 fixture row count/width changed' unless rows.bytesize == ROWS.sum { |row| 8 + 1 + row[:records].sum { |record| probe.send(:rowbinary_record, record).bytesize } }
    raise 'W202 empty first mark bytes changed' unless rows.byteslice(8, 1).bytes == [0]
    raise 'W202 string Variant literal bytes changed' unless probe.send(:rowbinary_record, ROWS[2][:records][0]).unpack1('H*') == '01000b61667465722d656d7074790b61667465722d656d707479'
    raise 'W202 UInt64 Variant literal bytes changed' unless probe.send(:rowbinary_record, ROWS[2][:records][1]).unpack1('H*') == '00017801bd02000000000000096e756d2d6669727374'
    raise 'W202 Variant NULL/default literal bytes changed' unless probe.send(:rowbinary_record, ROWS[3][:records][1]).unpack1('H*') == '0000ff00'

    tab = "\t"
    pin = "__W202_PIN__#{tab}#{VERSION}#{tab}#{BUILD}"
    table = 'source_single_stream'
    profile = 'single_stream'
    base = [pin,
            "__W202_CHECK_BEGIN__#{tab}#{table}#{tab}#{profile}",
            "all_1_1_0#{tab}1#{tab}",
            "__W202_CHECK_END__#{tab}#{table}#{tab}#{profile}",
            "__W202_DATA_PATH__#{tab}#{table}#{tab}/tmp/store/#{table}/",
            "__W202_PART__#{tab}#{table}#{tab}all_1_1_0#{tab}/tmp/store/#{table}/all_1_1_0/#{tab}Wide#{tab}8#{tab}5",
            "__W202_ZERO_BEGIN__#{tab}#{table}#{tab}#{profile}#{tab}values",
            "__W202_ZERO_END__#{tab}#{table}#{tab}#{profile}#{tab}values"].join("\n")
    parsed = probe.send(:parse_native, base)
    raise 'W202 TSV pin/check/path/part/zero parsing changed' unless
      parsed[:pin] == pin && parsed[:checks] == {[table, profile] => ["all_1_1_0#{tab}1#{tab}"]} &&
      parsed[:data_paths] == {table => "/tmp/store/#{table}/"} && parsed[:parts].keys == [table] &&
      parsed[:zero_events].size == 2

    reject = lambda do |label, &operation|
      begin
        operation.call
      rescue StandardError
        next
      end
      raise "W202 #{label} was accepted"
    end
    reject.call('duplicate data path') { probe.send(:parse_native, [base, "__W202_DATA_PATH__#{tab}#{table}#{tab}/tmp/other"].join("\n")) }
    reject.call('duplicate active part') { probe.send(:parse_native, [base, "__W202_PART__#{tab}#{table}#{tab}all_2_2_0#{tab}/tmp/other#{tab}Wide#{tab}8#{tab}5"].join("\n")) }
    reject.call('duplicate runtime pin') { probe.send(:parse_native, [base, pin].join("\n")) }
    reject.call('duplicate CHECK block') do
      probe.send(:parse_native, [base,
        "__W202_CHECK_BEGIN__#{tab}#{table}#{tab}#{profile}",
        "__W202_CHECK_END__#{tab}#{table}#{tab}#{profile}"].join("\n"))
    end
    reject.call('unknown marker') { probe.send(:parse_native, [base, "__W202_UNKNOWN__#{tab}x"].join("\n")) }

    value_rows = {}
    {'FULL' => ROWS, 'FIRST_EMPTY' => ROWS[0, 2], 'LATER' => ROWS[2, 2], 'FINAL' => ROWS[6, 2], 'ZERO' => []}.each do |window, selected|
      value_rows[[table, window]] = selected.map do |row|
        labels = row[:records].map { |record| record[:label] }
        choices = row[:records].map do |record|
          kind, value = record[:choice]
          kind == :null ? nil : value
        end
        texts = row[:records].map { |record| record[:text] }
        [row[:pk].to_s, JSON.generate(labels).unpack1('H*'), JSON.generate(choices).unpack1('H*'),
         JSON.generate(texts).unpack1('H*'), TYPE, VARIANT_TYPE]
      end
    end
    native_values = {value_rows: value_rows}
    probe.send(:assert_value_windows!, native_values, table)
    native_values[:value_rows][[table, 'FULL']][2][1] = JSON.generate(['corrupted', 'x']).unpack1('H*')
    reject.call('corrupted selected-value literal') { probe.send(:assert_value_windows!, native_values, table) }
    true
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    if ARGV == ['--self-test']
      ProbeNestedBulkPartW202.self_test!
      puts 'W202 literal fixture self-test passed'
      exit 0
    end
    options = {binary: ProbeNestedBulkPartW202::BINARY, helper: nil, root: nil}
    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby scripts/probe_nested_bulk_part_w202.rb --crystal-helper PREBUILT --evidence-root EMPTY_/private/tmp_CHILD [--clickhouse PINNED]'
      parser.on('--clickhouse PATH', 'Pinned ClickHouse 26.10.1.1201 executable') { |value| options[:binary] = value }
      parser.on('--crystal-helper PATH', 'Prebuilt Crystal helper; this runner never compiles it') { |value| options[:helper] = value }
      parser.on('--evidence-root PATH', 'Existing empty direct child of /private/tmp') { |value| options[:root] = value }
    end.parse!
    abort 'W202: --crystal-helper and --evidence-root are required' unless options[:helper] && options[:root]
    exit(ProbeNestedBulkPartW202::Probe.new(options[:binary], options[:helper], options[:root]).run ? 0 : 1)
  rescue StandardError => error
    warn "W202 runner error: #{error.class}: #{error.message}"
    exit 1
  end
end
