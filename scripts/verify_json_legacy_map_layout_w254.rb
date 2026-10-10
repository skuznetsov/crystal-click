#!/usr/bin/env ruby
# Bounded reciprocal native qualification for complete root Object V1/V2 MAP
# parts. Reuses W202/W185's process owner and does not build either executable.

require 'digest'
require 'json'
require 'optparse'
require_relative 'probe_nested_bulk_part_w202'

module VerifyJSONLegacyMapLayoutW254
  W202 = ProbeNestedBulkPartW202
  W185 = W202::W185

  FORMAT = 'json_legacy_map_layout_w254_capture_v1'.freeze
  VERSION = W202::VERSION
  BUILD = W202::BUILD
  BINARY = W202::BINARY
  BINARY_SHA256 = W202::BINARY_SHA256
  MEMORY = W202::MEMORY
  TIMEOUT = W202::TIMEOUT
  GRACE = W202::GRACE
  OUTER_RUN_SAFE_LIMIT = W202::OUTER_RUN_SAFE_LIMIT

  TYPE = 'JSON(max_dynamic_types=1, max_dynamic_paths=1, tags Array(String), title String)'.freeze
  ROWS = [
    {pk: 1, title: 'title-1', tags: [], counter: 1001, spill: 'spill-1'},
    {pk: 2, title: '', tags: %w[tag-2 common], counter: 1002, spill: nil},
    {pk: 3, title: 'title-3', tags: %w[tag-3], counter: 1003, spill: 'spill-3'},
    {pk: 4, title: 'title-4', tags: [], counter: 1004, spill: nil},
    {pk: 5, title: 'title-5', tags: %w[tag-5 common tag-5b], counter: 'counter-five', spill: 'spill-5'},
    {pk: 6, title: 'title-6', tags: %w[tag-6], counter: nil, spill: nil},
  ].map(&:freeze).freeze
  EXPECTED_SIGNATURES = [
    'title-1||Int64:1001|spill-1',
    '|tag-2,common|Int64:1002|ABSENT',
    'title-3|tag-3|Int64:1003|spill-3',
    'title-4||Int64:1004|ABSENT',
    'title-5|tag-5,common,tag-5b|String:counter-five|spill-5',
    'title-6|tag-6|NULL|ABSENT',
  ].freeze
  SOURCE_FILES = %w[
    scripts/verify_json_legacy_map_layout_w254.rb
    scripts/check_json_legacy_map_layout_w254.cr
    scripts/probe_nested_bulk_part_w202.rb
    scripts/check_array_json_parts_w185.rb
    scripts/check_array_json_parts_w185.cr
    scripts/check_json_binary_kernel_w180.rb
    scripts/check_json_binary_kernel_w180.cr
    scripts/probe_json_array_storage_w183.rb
  ].map { |path| File.expand_path(path, File.expand_path('..', __dir__)) }.freeze

  class Probe < W202::Probe
    def initialize(binary, crystal_helper, evidence_root, object_version, helper_mode)
      super(binary, crystal_helper, evidence_root)
      fail_w254!('Object version must be v1 or v2') unless %w[v1 v2].include?(object_version)
      fail_w254!('helper mode must be debug or release') unless %w[debug release].include?(helper_mode)
      @object_version_name = object_version
      @object_version_wire = object_version == 'v1' ? 0 : 2
      @helper_mode = helper_mode
      @object_table_names = ["source_#{object_version}", "library_#{object_version}"].freeze
      @source_native = nil
      @attached_native = nil
      @helper_data = nil
      @helper_invocation = nil
      @attached_library_snapshot = nil
    end

    def run
      send(:prepare_layout!)
      Dir.mkdir(File.join(@root, 'generated', "library_#{@object_version_name}"), 0o700)
      @binary_sha_before = send(:binary_sha)
      fail_w254!('pinned ClickHouse executable SHA mismatch before probe') unless @binary_sha_before == BINARY_SHA256
      @helper_sha_before = send(:helper_sha)
      @source_pins_before = source_pins

      initial = send(:run_clickhouse, 'native_sources', initial_sql)
      send(:assert_native_invocation!, initial)
      @source_native = parse_native(initial[:stdout])
      assert_pin!(@source_native)
      assert_initial_native!(@source_native)

      source_table, library_table = @object_table_names
      source_part = @source_parts.fetch(source_table)
      library_part = File.join(@root, 'generated', "library_#{@object_version_name}", 'all_1_1_0')
      argv = [@helper, source_part, library_part, @object_version_name]
      helper = run_helper(argv)
      @helper_data = helper.fetch(:data)
      @helper_invocation = helper.fetch(:record)
      assert_helper!(@helper_data, source_part, library_part)
      @library_parts[@object_version_name] = library_part
      @library_snapshots[@object_version_name] = send(:snapshot_part, library_part)

      target_data_path = @data_paths.fetch(library_table)
      @executor.send(:attach_part!, library_part, send(:validate_store_path!, target_data_path))
      attached = send(:run_clickhouse, 'attach_and_check', attached_sql)
      send(:assert_native_invocation!, attached)
      @attached_native = parse_native(attached[:stdout])
      assert_pin!(@attached_native)
      assert_attached_native!(@attached_native)

      fail_w254!('stock source part changed during ATTACH/SELECT') unless
        send(:snapshot_part, @source_parts.fetch(source_table)) == @source_snapshots.fetch(source_table)
      fail_w254!('library-generated original changed during ATTACH/SELECT') unless
        send(:snapshot_part, library_part) == @library_snapshots.fetch(@object_version_name)
      attached_part = @attached_native.fetch(:parts).fetch(library_table).fetch(:path)
      attached_part = send(:validate_source_part!, attached_part)
      @attached_library_snapshot = send(:snapshot_part, attached_part)

      @binary_sha_after = send(:binary_sha)
      @helper_sha_after = send(:helper_sha)
      fail_w254!('pinned ClickHouse executable SHA changed during probe') unless @binary_sha_after == BINARY_SHA256
      fail_w254!('prebuilt Crystal helper SHA changed during probe') unless @helper_sha_after == @helper_sha_before
      @source_pins_after = source_pins
      fail_w254!('runner or reused W202 source changed during probe') unless @source_pins_after == @source_pins_before

      write_summary('paired_object_legacy_map_observed')
      puts "W254 Object #{@object_version_name}/#{@helper_mode}; evidence=#{@root}"
      true
    rescue StandardError => error
      @fatal_error ||= "#{error.class}: #{error.message}"
      @binary_sha_after = send(:binary_sha) rescue nil
      @helper_sha_after = send(:helper_sha) rescue nil
      @source_pins_after = source_pins rescue nil
      write_summary('runner_failure_or_observations_differ') rescue nil
      warn "W254 probe failure (process failure is not format evidence): #{@fatal_error}"
      false
    end

    private

    def fail_w254!(message)
      raise "W254 Object legacy MAP oracle: #{message}"
    end

    def source_pins
      SOURCE_FILES.map do |path|
        fail_w254!("pinned harness source is missing or symlinked: #{path}") unless File.file?(path) && !File.symlink?(path)
        {path: path, sha256: Digest::SHA256.file(path).hexdigest}
      end
    end

    def settings
      object_version = @object_version_name
      [
        'index_granularity=2', 'index_granularity_bytes=10485760',
        'enable_mixed_granularity_parts=1', 'min_rows_for_wide_part=0',
        'min_bytes_for_wide_part=0', 'compress_marks=0', 'compress_primary_key=0',
        'min_compress_block_size=0', 'max_compress_block_size=4096',
        'ratio_of_defaults_for_sparse_serialization=1', "default_compression_codec='LZ4'",
        "string_serialization_version='with_size_stream'", "dynamic_serialization_version='v3'",
        "object_serialization_version='#{object_version}'",
        "object_shared_data_serialization_version='map'",
        "object_shared_data_serialization_version_for_zero_level_parts='map'",
        'propagate_types_serialization_versions_to_nested_types=1',
        "map_serialization_version='basic'", "map_serialization_version_for_zero_level_parts='basic'",
      ].join(', ').freeze
    end

    def table(name)
      name
    end

    def insert_sql
      values = ROWS.map do |row|
        payload = {
          'title' => row.fetch(:title),
          'tags' => row.fetch(:tags),
          'counter' => row[:counter],
        }
        payload['spill'] = row[:spill] if row[:spill]
        json = JSON.generate(payload).gsub("'", "\\'")
        "(#{row.fetch(:pk)}, CAST('#{json}', '#{TYPE}'))"
      end
      "INSERT INTO default.#{@object_table_names.fetch(0)} VALUES #{values.join(', ')};"
    end

    def initial_sql
      source, library = @object_table_names
      statements = [
        'SET merge_tree_use_v1_object_and_dynamic_serialization=0;',
        'SET flatten_nested=0;',
        "SELECT '__W254_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
        "CREATE TABLE default.#{table(source)} (pk UInt64, payload #{TYPE}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings};",
        "CREATE TABLE default.#{table(library)} (pk UInt64, payload #{TYPE}) ENGINE=MergeTree ORDER BY pk SETTINGS #{settings};",
        insert_sql,
        check_sql(source),
        schemas_sql,
        data_paths_sql,
        parts_sql([source]),
        value_query(source),
      ]
      statements.join("\n") + "\n"
    end

    def attached_sql
      source, library = @object_table_names
      [
        'SET merge_tree_use_v1_object_and_dynamic_serialization=0;',
        'SET flatten_nested=0;',
        "SELECT '__W254_PIN__', version(), (SELECT value FROM system.build_options WHERE name='VERSION_GITHASH') FORMAT TSVRaw;",
        "ALTER TABLE default.#{library} ATTACH PART 'all_1_1_0';",
        check_sql(source),
        check_sql(library),
        schemas_sql,
        data_paths_sql,
        parts_sql([source, library]),
        value_query(source),
        value_query(library),
      ].join("\n") + "\n"
    end

    def check_sql(name)
      [
        "SELECT '__W254_CHECK_BEGIN__', '#{name}' FORMAT TSVRaw;",
        "CHECK TABLE default.#{name} FORMAT TSV;",
        "SELECT '__W254_CHECK_END__', '#{name}' FORMAT TSVRaw;",
      ].join("\n")
    end

    def schemas_sql
      names = @object_table_names.map { |name| "'#{name}'" }.join(',')
      "SELECT '__W254_SCHEMA__', table, name, type FROM system.columns WHERE database='default' AND table IN (#{names}) ORDER BY table, position FORMAT TSVRaw;"
    end

    def data_paths_sql
      names = @object_table_names.map { |name| "'#{name}'" }.join(',')
      "SELECT '__W254_DATA_PATH__', name, arrayElement(data_paths, 1) FROM system.tables WHERE database='default' AND name IN (#{names}) ORDER BY name FORMAT TSVRaw;"
    end

    def parts_sql(tables)
      names = tables.map { |name| "'#{name}'" }.join(',')
      "SELECT '__W254_PART__', table, name, path, part_type, toString(rows), toString(marks) FROM system.parts WHERE database='default' AND table IN (#{names}) AND active ORDER BY table,name FORMAT TSVRaw;"
    end

    def value_query(name)
      "SELECT '__W254_VALUE__', '#{name}', toString(pk), hex(toJSONString(payload.title)), " \
        "hex(toJSONString(payload.tags)), if(isNull(payload.counter), 'NULL', dynamicType(payload.counter)), " \
        "if(isNull(payload.counter), '-', hex(toJSONString(payload.counter))), " \
        "if(isNull(payload.spill), 'NULL', dynamicType(payload.spill)), " \
        "if(isNull(payload.spill), '-', hex(toJSONString(payload.spill))) " \
        "FROM default.#{name} ORDER BY pk FORMAT TSVRaw;"
    end

    def run_helper(argv)
      before = send(:helper_sha)
      fail_w254!('prebuilt Crystal helper changed before invocation') unless before == @helper_sha_before
      invocation = @executor.send(:execute_record, 'crystal_helper', argv, ''.b,
                                  'prebuilt Crystal helper', before, @helper)
      fail_w254!('Crystal helper failed; not a ClickHouse format rejection') unless
        invocation[:record][:process_classification] == 'success' && invocation[:record][:exit] == 0 && invocation[:record][:signal].nil?
      fail_w254!('Crystal helper emitted stderr') unless invocation[:stderr].empty?
      fail_w254!('Crystal helper SHA changed during invocation') unless send(:helper_sha) == before
      lines = invocation[:stdout].lines.map(&:chomp).reject(&:empty?)
      fail_w254!('Crystal helper must emit exactly one JSON record') unless lines.size == 1
      data = JSON.parse(lines.fetch(0))
      fail_w254!('Crystal helper output format differs') unless data['format'] == 'json_legacy_map_layout_w254_helper_v1'
      @invocations << invocation[:record]
      {data: data, record: invocation[:record]}
    end

    def parse_native(stdout)
      lines = stdout.force_encoding(Encoding::UTF_8).lines.map(&:chomp)
      records = ->(prefix) { lines.select { |line| line.start_with?("#{prefix}\t") }.map { |line| line.split("\t", -1) } }
      known = %w[
        __W254_PIN__ __W254_SCHEMA__ __W254_DATA_PATH__ __W254_PART__ __W254_VALUE__
        __W254_CHECK_BEGIN__ __W254_CHECK_END__
      ]
      unknown = lines.each_with_object([]) do |line, result|
        next unless line.start_with?('__W254_')
        tag = line.split("\t", 2).first
        result << tag unless known.include?(tag)
      end
      fail_w254!("unknown marker tags: #{unknown.uniq.inspect}") unless unknown.empty?

      checks = {}
      active = nil
      lines.each do |line|
        if line.start_with?("__W254_CHECK_BEGIN__\t")
          fields = line.split("\t", -1)
          fail_w254!('malformed/nested CHECK begin') unless fields.size == 2 && active.nil?
          active = fields.fetch(1)
          fail_w254!("duplicate CHECK block for #{active}") if checks.key?(active)
          checks[active] = []
        elsif line.start_with?("__W254_CHECK_END__\t")
          fields = line.split("\t", -1)
          fail_w254!('malformed CHECK end') unless fields.size == 2 && active == fields.fetch(1)
          active = nil
        elsif active
          checks.fetch(active) << line
        end
      end
      fail_w254!('unterminated CHECK block') unless active.nil?

      pins = records.call('__W254_PIN__')
      fail_w254!('runtime pin must occur exactly once') unless pins.size == 1 && pins.first.size == 3
      schemas = records.call('__W254_SCHEMA__').map do |fields|
        fail_w254!('schema row width differs') unless fields.size == 4
        fields.drop(1)
      end
      data_paths = records.call('__W254_DATA_PATH__').to_h do |fields|
        fail_w254!('data path row width differs') unless fields.size == 3
        [fields.fetch(1), fields.fetch(2)]
      end
      fail_w254!('duplicate data path row') unless data_paths.size == records.call('__W254_DATA_PATH__').size
      parts = records.call('__W254_PART__').to_h do |fields|
        fail_w254!('part row width differs') unless fields.size == 7
        [fields.fetch(1), {name: fields.fetch(2), path: fields.fetch(3), type: fields.fetch(4), rows: fields.fetch(5), marks: fields.fetch(6)}]
      end
      fail_w254!('duplicate active part row') unless parts.size == records.call('__W254_PART__').size
      values = records.call('__W254_VALUE__').each_with_object({}) do |fields, result|
        fail_w254!('value row width differs') unless fields.size == 9
        (result[fields.fetch(1)] ||= []) << fields.drop(2)
      end
      {
        pin: lines.find { |line| line.start_with?("__W254_PIN__\t") },
        checks: checks, schemas: schemas, data_paths: data_paths,
        parts: parts, values: values,
      }
    end

    def assert_pin!(native)
      expected = "__W254_PIN__\t#{VERSION}\t#{BUILD}"
      fail_w254!("runtime version/build differs: #{native[:pin].inspect}") unless native[:pin] == expected
    end

    def expected_schemas
      @object_table_names.sort.flat_map { |name| [[name, 'pk', 'UInt64'], [name, 'payload', TYPE]] }
    end

    def assert_checks!(native, tables)
      expected = tables.to_h { |name| [name, ["all_1_1_0\t1\t"]] }
      fail_w254!("native CHECK result differs: #{native[:checks].inspect}") unless native[:checks] == expected
    end

    def assert_native_common!(native, tables)
      assert_checks!(native, tables)
      fail_w254!("native schema differs: #{native[:schemas].inspect}") unless native[:schemas] == expected_schemas
      fail_w254!('native data-path table roster differs') unless native[:data_paths].keys.sort == @object_table_names.sort
      native[:data_paths].each_value { |path| send(:validate_store_path!, path) }
      fail_w254!("native selected-value table roster differs: #{native[:values].keys.sort.inspect}") unless
        native[:values].keys.sort == tables.sort
      native[:values].each { |name, rows| assert_native_rows!(name, rows) }
    end

    def assert_initial_native!(native)
      source, library = @object_table_names
      assert_checks!(native, [source])
      fail_w254!('initial schemas differ') unless native[:schemas] == expected_schemas
      fail_w254!('initial data paths differ') unless native[:data_paths].keys.sort == @object_table_names.sort
      native[:data_paths].each_value { |path| send(:validate_store_path!, path) }
      fail_w254!('initial stock part roster differs') unless native[:parts].keys == [source]
      part = native[:parts].fetch(source)
      fail_w254!('stock source is not the exact six-row Wide part') unless
        part[:name] == 'all_1_1_0' && part[:type] == 'Wide' && part[:rows] == '6' && part[:marks] == '4'
      @source_parts[source] = send(:validate_source_part!, part[:path])
      @source_snapshots[source] = send(:snapshot_part, @source_parts.fetch(source))
      fail_w254!('initial selected-value table roster differs') unless native[:values].keys == [source]
      assert_native_rows!(source, native[:values].fetch(source))
      @data_paths = native[:data_paths].dup
    end

    def assert_attached_native!(native)
      source, library = @object_table_names
      assert_native_common!(native, [source, library])
      fail_w254!('attached native part roster differs') unless native[:parts].keys.sort == [source, library].sort
      [source, library].each do |name|
        part = native[:parts].fetch(name)
        fail_w254!("#{name} part identity/grid differs") unless
          part[:name] == 'all_1_1_0' && part[:type] == 'Wide' && part[:rows] == '6' && part[:marks] == '4'
      end
    end

    def assert_native_rows!(table, rows)
      fail_w254!("#{table} native row count differs") unless rows.size == ROWS.size
      decoded = rows.map do |fields|
        [fields.fetch(0), json_hex(fields.fetch(1)), json_hex(fields.fetch(2)),
         fields.fetch(3), nullable_json_hex(fields.fetch(4)),
         fields.fetch(5), nullable_json_hex(fields.fetch(6))]
      end
      expected = ROWS.map do |row|
        counter_type, counter_value = if row[:counter].nil?
                                        ['NULL', nil]
                                      elsif row[:counter].is_a?(Integer)
                                        ['Int64', row[:counter]]
                                      else
                                        ['String', row[:counter]]
                                      end
        spill_type = row[:spill] ? 'String' : 'NULL'
        [row[:pk].to_s, row[:title], row[:tags], counter_type, counter_value, spill_type, row[:spill]]
      end
      fail_w254!("#{table} literal selected values differ: #{decoded.inspect}") unless decoded == expected
    end

    def json_hex(hex)
      fail_w254!('native SELECT returned malformed JSON hex') unless hex.match?(/\A(?:[0-9A-Fa-f]{2})*\z/)
      JSON.parse([hex].pack('H*'))
    rescue JSON::ParserError => error
      fail_w254!("native JSON hex did not decode: #{error.message}")
    end

    def nullable_json_hex(hex)
      hex == '-' ? nil : json_hex(hex)
    end

    def assert_helper!(data, source_part, library_part)
      expected_keys = %w[format object_version source_part library_part expected_rows source library].sort
      fail_w254!('helper top-level schema differs') unless data.keys.sort == expected_keys
      fail_w254!('helper version/part paths differ') unless
        data['object_version'] == @object_version_name &&
        File.expand_path(data['source_part']) == source_part && File.expand_path(data['library_part']) == library_part
      fail_w254!('helper independent row literals differ') unless data['expected_rows'] == EXPECTED_SIGNATURES
      %w[source library].each do |side_name|
        side = data.fetch(side_name)
        expected_side_keys = %w[
          mark_row_counts schema_declaration object_wire_version object_legacy_max_dynamic_paths
          object_dynamic_paths object_statistics_counts object_shared_statistics counter_dynamic_version
          counter_ordinary_types counter_statistics_counts direct_rows public_table_rows public_table_keys
          offline_values physical_stream_names selected_checksum_names
        ].sort
        fail_w254!("helper #{side_name} report schema differs") unless side.keys.sort == expected_side_keys
        expected_wire = @object_version_wire
        expected_legacy = @object_version_name == 'v1' ? 1 : nil
        fail_w254!("helper #{side_name} selected Object wire version/legacy field differs") unless
          side['object_wire_version'] == expected_wire && side['object_legacy_max_dynamic_paths'] == expected_legacy
        fail_w254!("helper #{side_name} Object roster/statistics differ") unless
          side['object_dynamic_paths'] == ['counter'] && side['object_statistics_counts'] == [5] &&
          side['object_shared_statistics'] == [{'name' => 'spill', 'count' => 3}]
        fail_w254!("helper #{side_name} Dynamic child roster/statistics differ") unless
          side['counter_dynamic_version'] == 4 && side['counter_ordinary_types'] == ['Int64'] &&
          side['counter_statistics_counts'] == [4, 1]
        fail_w254!("helper #{side_name} consumer values differ") unless
          side['direct_rows'] == EXPECTED_SIGNATURES && side['public_table_rows'] == EXPECTED_SIGNATURES &&
          side['public_table_keys'] == (1..6).to_a && side['offline_values'] == EXPECTED_SIGNATURES
        fail_w254!("helper #{side_name} physical mark grid differs") unless side['mark_row_counts'] == [2, 2, 2]
        fail_w254!("helper #{side_name} schema declaration differs") unless side['schema_declaration'] == TYPE
        %w[physical_stream_names selected_checksum_names].each do |key|
          values = side.fetch(key)
          fail_w254!("helper #{side_name} #{key} is empty/duplicated") unless values.is_a?(Array) && !values.empty? && values.uniq == values
        end
      end
    end

    def write_summary(status)
      data = {
        format: FORMAT,
        status: status,
        fatal_error: @fatal_error,
        scope: {object_version: @object_version_name, helper_mode: @helper_mode,
                object_type: TYPE, row_count: ROWS.size, parent_mark_row_counts: [2, 2, 2],
                inferred_counter_roster: ['Int64', 'SharedVariant'], shared_spill_rows: 3},
        runtime: {path: @binary, expected_sha256: BINARY_SHA256,
                  sha256_before: @binary_sha_before, sha256_after: @binary_sha_after,
                  expected_version: VERSION, expected_build: BUILD},
        helper: {path: @helper, sha256_before: @helper_sha_before, sha256_after: @helper_sha_after},
        source_pins_before: @source_pins_before,
        source_pins_after: @source_pins_after,
        limits: {max_threads: 1, local_max_memory_usage_bytes: MEMORY,
                 required_outer_run_safe_memory_limit_bytes: OUTER_RUN_SAFE_LIMIT,
                 timeout_seconds: TIMEOUT, termination_grace_seconds: GRACE,
                 executor: 'JsonBinaryKernelW180Probe#execute'},
        evidence_root: @root,
        invocations: @invocations,
        native_source: @source_native,
        helper_output: @helper_data,
        helper_invocation: @helper_invocation,
        native_attached: @attached_native,
        source_part_snapshots: @source_snapshots,
        library_generated_snapshots: @library_snapshots,
        attached_library_snapshot: @attached_library_snapshot,
      }
      send(:write_new, File.join(@root, 'summary.json'), JSON.pretty_generate(data) + "\n")
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    options = {binary: VerifyJSONLegacyMapLayoutW254::BINARY}
    OptionParser.new do |parser|
      parser.banner = 'Usage: ruby scripts/verify_json_legacy_map_layout_w254.rb --object-version v1|v2 --helper-mode debug|release --crystal-helper PREBUILT --evidence-root EMPTY_CHILD [--clickhouse PINNED]'
      parser.on('--object-version VERSION', 'Selected complete Object V1 or V2') { |value| options[:object_version] = value }
      parser.on('--helper-mode MODE', 'Prebuilt helper profile: debug or release') { |value| options[:helper_mode] = value }
      parser.on('--clickhouse PATH', 'Pinned ClickHouse 26.10.1.1201 executable') { |value| options[:binary] = value }
      parser.on('--crystal-helper PATH', 'Prebuilt Crystal helper; this runner never compiles it') { |value| options[:helper] = value }
      parser.on('--evidence-root PATH', 'Existing empty direct child of /private/tmp') { |value| options[:root] = value }
    end.parse!
    abort 'W254: all of --object-version, --helper-mode, --crystal-helper, and --evidence-root are required' unless
      options[:object_version] && options[:helper_mode] && options[:helper] && options[:root]
    ok = VerifyJSONLegacyMapLayoutW254::Probe.new(
      options[:binary], options[:helper], options[:root], options[:object_version], options[:helper_mode],
    ).run
    exit(ok ? 0 : 1)
  rescue StandardError => error
    warn "W254 runner error: #{error.class}: #{error.message}"
    exit 1
  end
end
